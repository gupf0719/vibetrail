// vibetrail：把一份 transcript（主会话或子 agent 文件）的记录流映射成 paas-coding-hook 协议 1.0 事件。
// DESIGN D12 的移植：由 map-events.jq（684 行）+ diverge-rules.jq（111 行）1:1 翻译而来，**换语言不换设计**——
// 事件字段、_key、账本、增量语义、上界全部照旧，golden 逐字节对得上（jq -S 排序后比较，所以键序无关）。
// 原文件里的取舍与踩坑注释留在 .jq 里（old/jq/ 归档）；这里只记翻译时必须对齐的 jq 语义：
//
//   1. `a // b` 在 a 为 null **或 false** 时取 b（JS 的 ?? 不管 false）→ alt()
//   2. null + 1 == 1、null 上的 += 也从 0 起算 → inc()
//   3. 字符串切片 .[0:n] 按**码点**数，不是 UTF-16 单元 → cut()
//   4. 正则标志与 PCRE 相反：jq 的 "m" 是 dotall，对应 JS 的 s；jq 的 ^ 只匹配串首，所以 JS 一律不加 m
//   5. ascii_downcase 只动 A-Z，不碰 Unicode（JS 的 toLowerCase 会动）
//   6. unique_by(k) 返回的是**按 k 排序后**去重的数组，顺序会影响事件发出顺序
//   7. min_by 取第一个最小元素；空数组给 null。max/min 按 jq 的排序（null 最小）
//   8. 对象 `+` 是浅合并、右边赢；del 删键；缺失的键读出来是 null

import crypto from 'node:crypto';

// ---------- jq 语义小工具 ----------
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isArr = Array.isArray;
const isStr = (v) => typeof v === 'string';
const alt = (a, b) => (a === null || a === undefined || a === false ? b : a);   // jq 的 //
const nz = (v) => (v === undefined ? null : v);                                 // 缺失键读出来是 null
const inc = (o, k, n = 1) => { o[k] = (o[k] || 0) + n; };                       // jq 的 null + 1
const cut = (s, n) => (isStr(s) && s.length > n ? [...s].slice(0, n).join('') : s);
const asciiLower = (s) => String(s).replace(/[A-Z]/g, (c) => c.toLowerCase());
const cmpJq = (a, b) => {                       // jq 的排序：null < false < true < 数字 < 字符串
  const rank = (v) => (v === null || v === undefined ? 0 : v === false ? 1 : v === true ? 2 : typeof v === 'number' ? 3 : 4);
  const ra = rank(a), rb = rank(b);
  if (ra !== rb) return ra - rb;
  if (ra === 3) return a - b;
  if (ra === 4) return a < b ? -1 : a > b ? 1 : 0;
  return 0;
};
const jqMax = (arr) => arr.reduce((m, v) => (m === undefined || cmpJq(v, m) > 0 ? v : m), undefined) ?? null;
const jqMin = (arr) => arr.reduce((m, v) => (m === undefined || cmpJq(v, m) < 0 ? v : m), undefined) ?? null;
const minBy = (arr, f) => {                     // 第一个最小；空给 null
  let best = null, bv;
  for (const x of arr) { const v = f(x); if (best === null || cmpJq(v, bv) < 0) { best = x; bv = v; } }
  return best;
};
const uniqueBy = (arr, f) => {                  // jq：先按 key 排序再去重
  const sorted = [...arr].sort((a, b) => cmpJq(f(a), f(b)));
  const out = [];
  for (const x of sorted) if (out.length === 0 || cmpJq(f(out[out.length - 1]), f(x)) !== 0) out.push(x);
  return out;
};
// 只保留值非 null / undefined 的键（jq 里那些 opt(...) 的合并）
const opt = (k, v) => (v === null || v === undefined ? {} : { [k]: v });

// ---------- diverge-rules.jq：人机分歧判据 v1（规范 spec/diverge-v1.md §2） ----------
// 铁律照旧：只读 JSON 字段不 grep 原文；多态字段先判 type；一条记录里多个块命中只出一条。
const msgOf = (r) => (isObj(r) && isObj(r.message) ? r.message : {});

const errText = (v) => {
  if (isArr(v)) return v.map((x) => (isStr(x) ? x : isObj(x) && isStr(x.text) ? x.text : null)).filter(isStr).join('\n');
  if (v === null || v === undefined) return 'null';
  return isStr(v) ? v : JSON.stringify(v);        // jq 的 tostring
};
const errBlocks = (r) => {
  const c = msgOf(r).content;
  if (r.type !== 'user' || !isArr(c)) return [];
  return c.filter(isObj).filter((b) => b.is_error === true)
    .map((b) => ({ call_id: alt(nz(b.tool_use_id), null), text: errText(b.content) }));
};
const isClassifier = (t) => /denied by the Claude Code auto mode classifier/.test(t) || /Blocked by classifier/.test(t);
const isInfra = (t) => /Tool permission (request failed|stream closed)/.test(t);
// jq 的 "m" ＝ dotall → JS 的 s；命令正文带换行时靠它匹配
const isHumanDenial = (t) => (/^Permission to use .* has been denied/s.test(t) || /^The user doesn't want to proceed with this tool use/.test(t))
  && !isClassifier(t) && !isInfra(t);
const kindPred = (kind) => (kind === 'permission_denied' ? isHumanDenial
  : kind === 'classifier_blocked' ? isClassifier
  : kind === 'permission_infra_fail' ? isInfra : () => false);
const isInterruptText = (t) => String(t).replace(/^\s+/, '').startsWith('[Request interrupted by user');
const isForToolUse = (t) => /for tool use/.test(t);
const anyText = (r) => {
  const c = msgOf(r).content;
  if (isArr(c)) return c.filter(isObj).filter((b) => b.type === 'text').map((b) => alt(nz(b.text), ''));
  if (isStr(c)) return [c];
  return [];
};
const hit = (r, kind, human) => ({ t: 'diverge', kind, human, at: nz(r.timestamp), turn: nz(r.uuid), sid: nz(r.sessionId), branch: nz(r.gitBranch) });
const hitErr = (r, kind, human) => {
  const b = errBlocks(r).find((x) => kindPred(kind)(x.text));
  return { ...hit(r, kind, human), call_id: b ? b.call_id : null };
};
export function diverge(r) {
  const out = [];
  const texts = anyText(r);
  if (r.type === 'user' && texts.some((t) => isInterruptText(t) && !isForToolUse(t))) out.push(hit(r, 'interrupt', true));
  if (r.type === 'user' && texts.some((t) => isInterruptText(t) && isForToolUse(t))) out.push(hit(r, 'interrupt_for_tool_use', true));
  const et = errBlocks(r).map((b) => b.text);
  if (et.some(isHumanDenial)) out.push(hitErr(r, 'permission_denied', true));
  if (et.some(isClassifier)) out.push(hitErr(r, 'classifier_blocked', false));
  if (et.some(isInfra)) out.push(hitErr(r, 'permission_infra_fail', false));
  return out;
}

// ---------- 记录的精简形态 ----------
const stripIde = (s) => String(s).replace(/<ide_[a-z_]+>.*?<\/ide_[a-z_]+>/gs, '').replace(/^\s+/, '').replace(/\s+$/, '');
const stripReminders = (s) => String(s).replace(/<system-reminder>.*?<\/system-reminder>/gs, '');
const textOf = (r) => {
  const c = msgOf(r).content;
  if (isStr(c)) return stripIde(stripReminders(c));
  if (isArr(c)) {
    return c.filter(isObj).filter((b) => b.type === 'text')
      .map((b) => stripReminders(alt(nz(b.text), '')))
      .filter((t) => { const h = t.replace(/^\s+/, ''); return !(h.startsWith('<system-reminder>') || h.startsWith('<ide_')); })
      .map(stripIde).filter((t) => t.length > 0).join('\n');
  }
  return '';
};
const thinkingTextOf = (r) => {
  const c = msgOf(r).content;
  if (!isArr(c)) return '';
  return c.filter(isObj).filter((b) => b.type === 'thinking').map((b) => alt(nz(b.thinking), '')).filter(isStr).filter((t) => t.length > 0).join('\n');
};
const thinkingIn = (r) => { const c = msgOf(r).content; return isArr(c) ? c.some((b) => isObj(b) && b.type === 'thinking') : false; };
const toolUses = (r) => {
  const c = msgOf(r).content;
  if (!isArr(c)) return [];
  return c.filter(isObj).filter((b) => b.type === 'tool_use').map((b) => ({ id: alt(nz(b.id), null), name: alt(nz(b.name), null), input: alt(nz(b.input), null) }));
};
const mainUser = (r) => {
  const c = msgOf(r).content;
  return r.type === 'user' && r.isSidechain !== true && r.isMeta !== true && r.isCompactSummary !== true && nz(r.agentId) === null
    && (isStr(c) || (isArr(c) && !c.filter(isObj).some((b) => b.type === 'tool_result')));
};
const injectedText = (t) => {
  const h = String(t).replace(/^\s+/, '');
  return /^<(system-reminder|local-command-[a-z]+|command-[a-z]+|task-notification|bash-[a-z]+)/.test(h)
    || h.startsWith('Stop hook feedback') || h.startsWith('This session is being continued');
};
const isHumanPrompt = (r) => {
  if (!mainUser(r)) return false;
  const t = textOf(r);
  if (!(t.length > 0 && !isInterruptText(t))) return false;
  const k = isObj(r.origin) ? nz(r.origin.kind) : null;
  return isStr(k) ? k === 'human' : !injectedText(t);
};
const isQueuedHuman = (r) => r.type === 'attachment' && isObj(r.attachment) && r.attachment.type === 'queued_command'
  && alt(nz(r.attachment.commandMode), 'prompt') === 'prompt'
  && alt(isObj(r.attachment.origin) ? nz(r.attachment.origin.kind) : null, 'human') === 'human';
const isSlashCommand = (r) => mainUser(r) && textOf(r).replace(/^\s+/, '').startsWith('<command-name>');
const slashText = (r) => {
  const t = textOf(r);
  const n = t.match(/<command-name>\s*(?<n>[^<]*?)\s*<\/command-name>/);
  if (!n) return null;
  const a = (t.match(/<command-args>(?<a>[^<]*)<\/command-args>/)?.groups?.a ?? '').replace(/^\s+/, '').replace(/\s+$/, '');
  const name = n.groups.n.startsWith('/') ? n.groups.n : '/' + n.groups.n;
  return name + (a === '' ? '' : ' ' + a);
};
const slim = (r, ln) => {
  const slash = isSlashCommand(r);
  const m = msgOf(r);
  return {
    uuid: nz(r.uuid), parentUuid: alt(nz(r.parentUuid), null), type: nz(r.type), ln,
    ts: alt(nz(r.timestamp), null), promptId: alt(nz(r.promptId), null),
    text: slash ? alt(slashText(r), textOf(r)) : (r.type === 'assistant' || r.type === 'user' ? textOf(r) : ''),
    tools: r.type === 'assistant' ? toolUses(r) : [],
    human: isHumanPrompt(r), slash,
    synthetic: r.type === 'assistant' && m.model === '<synthetic>',
    mid: alt(nz(m.id), null), rid: alt(nz(r.requestId), null), model: alt(nz(m.model), null),
    usage: isObj(m.usage) ? m.usage : null,
    agent: alt(nz(r.agentId), null),
  };
};

// ---------- 主体 ----------
const epochms = (v) => {
  if (!isStr(v)) return null;
  const m = v.match(/^(?<b>[^.Z]+)(?<f>\.[0-9]+)?Z$/);
  if (!m) return null;
  const base = Date.parse(m.groups.b + 'Z');
  if (Number.isNaN(base)) return null;
  return base + Math.floor(parseFloat('0' + alt(m.groups.f, '.0')) * 1000);
};
const codeOk = (v) => isStr(v) && /^[a-z][a-z0-9]*([._-][a-z0-9]+)*$/.test(v);
const codeify = (v) => {
  let s = asciiLower(String(v)).replace(/[^a-z0-9._-]+/g, '_').replace(/^[^a-z]+/, '').replace(/[._-]+$/, '').replace(/[._-]{2,}/g, '_');
  return s === '' ? 'unknown' : cut(s, 128);
};
const gitCommitCmd = (v) => isStr(v) && /(^|[;&|(\s])git(\s+-[Cc]\s+\S+|\s+--no-pager)*\s+commit(\s|$)/.test(v);
const noPromptMode = (m) => ['auto', 'bypassPermissions', 'dontAsk'].includes(m);

const SIZE_CAP = 1048576 - 1024;   // 协议单条 1 MiB，留 1 KiB 余量（量的是带 _key、event_id 还是 null 的形态）

export function mapRecords(records, args) {
  const {
    sid, project_id, workspace_id, parent_instance = 'main',
    start_line = 1, from_line = 0, meta = null,
    seen_uuids = [], hook_turns = {}, hook_perms = [], perm_since = '',
    close_last = '', stop_turn = '', turns = true,
    vt_version = '', rule_version = 'diverge-v1', capture_content = '1',
  } = args;
  const capContent = capture_content !== '0';

  const prior = {};
  for (const p of seen_uuids) prior[p[0]] = p[1];

  const st = {
    ln: start_line - 1, turn: null, turn_line: 0,
    run_uuids: {}, prior,
    tools: {}, tool_order: [],
    chain: {}, chain_order: [],
    turn_usage: {}, turn_model: null,
    seen: {}, denials: [], stops: [], perm_mode: null, pending: null,
    pturn: null, call: null, calls_seen: [], prev_end_ts: null,
    last_ts: null, version: null, entrypoint: null, branch: null,
    ledger: {
      in: {}, in_total: {}, out: {}, events: {}, absorbed_for_tool_use: 0, unpaired_for_tool_use: 0,
      lookup: { index: 0, regex: 0, missing: 0 }, stop_press: 0, dedup: 0, records: 0, skipped_no_uuid: 0, skipped_non_object: 0,
      sentinel: { marker: 0, marker_without_hit: 0 }, replayed: 0, turns: { started: 0, ended: {} }, sources: [],
    },
    out: [],
  };

  // ---- 事件骨架 ----
  const dropContent = (e) => {
    if (isObj(e.payload)) { delete e.payload.text; delete e.payload.input; delete e.payload.output; }
    if (isObj(e.extensions)) delete e.extensions['vibetrail.reasoning'];
    delete e.raw;
    e.content_state = 'omitted';
    e.extensions = { ...e.extensions, 'vibetrail.content_dropped': 'size' };
    return e;
  };
  const fitSize = (e) => (capContent && Buffer.byteLength(JSON.stringify(e), 'utf8') > SIZE_CAP ? dropContent(e) : e);
  const emit = (e) => {
    if (st.seen[e._key]) { st.ledger.dedup += 1; return; }
    st.seen[e._key] = true;
    if (st.ln > from_line) { st.out.push(fitSize(e)); inc(st.ledger.events, e.type); }
  };
  const emitAlways = (e) => {
    if (st.seen[e._key]) { st.ledger.dedup += 1; return; }
    st.seen[e._key] = true;
    st.out.push(fitSize(e)); inc(st.ledger.events, e.type);
  };

  const turnOf = (s) => (s.promptId !== null ? { id: s.promptId, inferred: false }
    : st.turn !== null ? { id: st.turn, inferred: true } : { id: s.uuid, inferred: true });

  const base = (s, type, srcUuid, ts, t) => {
    const e = {
      event_id: null,
      occurred_at: alt(ts, st.last_ts),
      type,
      agent: { name: 'claude-code', ...opt('version', st.version), ...(codeOk(st.entrypoint) ? { surface: st.entrypoint } : {}) },
      project_id, workspace_id, session_id: sid,
      turn_id: t.id,
      agent_instance_id: alt(s.agent, 'main'),
      provenance: { kind: t.inferred ? 'inferred' : 'transcript', rule_version, ...opt('source_event_id', srcUuid) },
      payload: {},
      extensions: { 'vibetrail.version': vt_version, ...opt('vibetrail.branch', st.branch) },
    };
    if (s.agent !== null && s.agent !== undefined) {
      e.parent_agent_instance_id = parent_instance;
      Object.assign(e, opt('parent_call_id', isObj(meta) ? nz(meta.toolUseId) : null));
    }
    return e;
  };

  const toolRequest = (s, t, cid, tu, ext) => {
    const e = base(s, 'tool.request', tu.uuid, tu.ts, t);
    e.payload = { tool_name: alt(tu.name, 'unknown'), call_id: cid, input: tu.input };
    e.content_state = 'included';
    e.extensions = { ...e.extensions, ...ext };
    e._key = tu.uuid + '|tool.request|' + cid;
    return e;
  };
  const message = (s, t, m, type, author, ext) => {
    const e = base(s, type, m.uuid, m.ts, t);
    e.payload = { text: m.text, author_type: author, delivery: 'direct', ...(type === 'message.assistant' ? opt('model', m.model) : {}) };
    e.content_state = 'included';
    e.extensions = { ...e.extensions, ...ext };
    e._key = m.uuid + '|' + type;
    return e;
  };

  const usageOf = (m) => {
    const us = Object.values(m).filter(isObj);
    if (us.length === 0) return null;
    const think = us.reduce((a, u) => a + (isObj(u.output_tokens_details) ? alt(nz(u.output_tokens_details.thinking_tokens), 0) : 0), 0);
    const o = {
      input_tokens: us.reduce((a, u) => a + alt(nz(u.input_tokens), 0) + alt(nz(u.cache_creation_input_tokens), 0), 0),
      cached_input_tokens: us.reduce((a, u) => a + alt(nz(u.cache_read_input_tokens), 0), 0),
      output_tokens: us.reduce((a, u) => a + alt(nz(u.output_tokens), 0), 0),
    };
    if (think > 0) o.reasoning_tokens = think;
    o.total_tokens = o.input_tokens + o.cached_input_tokens + o.output_tokens;
    for (const k of Object.keys(o)) if (typeof o[k] !== 'number') delete o[k];
    return o;
  };
  const usageOne = (u) => {
    if (!isObj(u)) return null;
    const o = {
      input_tokens: alt(nz(u.input_tokens), 0) + alt(nz(u.cache_creation_input_tokens), 0),
      cached_input_tokens: alt(nz(u.cache_read_input_tokens), 0),
      output_tokens: alt(nz(u.output_tokens), 0),
    };
    const t = isObj(u.output_tokens_details) ? alt(nz(u.output_tokens_details.thinking_tokens), 0) : 0;
    if (t > 0) o.reasoning_tokens = t;
    o.total_tokens = o.input_tokens + o.cached_input_tokens + o.output_tokens;
    return o;
  };

  const hookTurn = (id) => { const h = isObj(hook_turns) ? nz(hook_turns[id]) : null; return alt(h, {}); };
  const hookStop = (h) => (isObj(h.stop) && alt(nz(h.stop.at_epoch), 0) >= alt(isObj(h.start) ? nz(h.start.at_epoch) : null, 0) ? h.stop : null);
  const hookEnd = (h) => alt(hookStop(h), alt(nz(h.gap), null));
  const vcsMerge = (branch, hv) => {
    const o = { ...(branch !== null ? { branch } : {}) };
    if (isObj(hv)) for (const k of ['head_sha', 'branch', 'dirty']) if (nz(hv[k]) !== null) o[k] = hv[k];
    return Object.keys(o).length > 0 ? o : null;
  };
  const commitsOf = (tend) => {
    const c = isObj(tend) ? tend.commits : null;
    if (!isArr(c) || c.length === 0) return null;
    return c.filter(isStr).map((sha) => ({ sha, relation: 'observed', evidence: 'before_after' }));
  };
  const mainRec = (r) => r.isSidechain !== true && nz(r.agentId) === null;

  const index = (s) => {
    for (const t of s.tools) {
      if (t.id === null) continue;
      st.tools[t.id] = { name: t.name, input: t.input, uuid: s.uuid, ts: s.ts, ln: s.ln };
      st.tool_order.push(t.id);
    }
    if (st.tool_order.length > 500) { delete st.tools[st.tool_order[0]]; st.tool_order = st.tool_order.slice(1); }
    const c = { ...s }; c.tools = s.tools.map((t) => ({ id: t.id, name: t.name }));
    st.chain[s.uuid] = c;
    st.chain_order.push(s.uuid);
    if (st.chain_order.length > 400) { delete st.chain[st.chain_order[0]]; st.chain_order = st.chain_order.slice(1); }
  };

  const turnStart = () => (st.turn_line > 0 ? st.turn_line : start_line);
  const addPending = (uuid, kind) => {
    const ts = turnStart();
    st.pending = { after: [...(st.pending ? st.pending.after : []), uuid], kind, since: st.pending && st.pending.since !== null ? st.pending.since : ts };
  };
  const baseCheckpoint = () => {
    const ts = turnStart();
    let c = st.pending !== null ? jqMin([st.pending.since, ts]) : ts;
    if (st.pturn !== null) c = jqMin([c, st.pturn.line]);
    return c;
  };

  // ---- 轮次元数据 ----
  const openTurn = (s) => {
    st.pturn = { id: s.promptId, line: s.ln, last_ts: s.ts, usage: {}, model: null, answered: false,
      interrupted: false, denied: false, git_commit: false, closed: false, end_turn: false, stop_blocked: false,
      block_pending: false, summary: null, queued: 0 };
    if (s.ln > from_line) st.ledger.turns.started += 1;
    const h = hookTurn(s.promptId);
    const vcs = vcsMerge(st.branch, isObj(h.start) ? h.start.vcs : null);
    const e = base(s, 'turn.start', s.uuid, s.ts, { id: s.promptId, inferred: false });
    e.provenance = { kind: 'transcript', rule_version: 'turn-v1', source_event_id: s.uuid };
    e.payload = { ...opt('vcs', vcs) };
    e._key = s.promptId + '|turn.start';
    emit(e);
  };

  const closeTurn = (how, s, eof) => {
    if (st.pturn === null || st.pturn.closed || st.pturn.interrupted) return;
    const pt = st.pturn;
    const h = hookTurn(pt.id), stop = hookStop(h), tend = hookEnd(h);
    const isNew = eof || st.ln > from_line;
    const evidence = (how === 'stop' && stop !== null) ? 'hook_stop'
      : pt.summary !== null ? 'stop_hook_summary'
      : stop !== null ? 'hook_stop'
      : nz(h.fail) != null ? 'stop_failure'
      : pt.end_turn ? 'end_turn' : 'none';
    const status = pt.denied ? { code: 'denied', category: 'denial', detail: 'turn stopped by a permission denial' }
      : (pt.summary && pt.summary.prevented === true) ? { code: 'hook_stopped', category: 'cancellation', detail: cut(alt(pt.summary.reason, ''), 4096) }
      : (evidence === 'stop_hook_summary' || evidence === 'hook_stop' || evidence === 'end_turn') ? { code: 'completed', category: 'success' }
      : evidence === 'stop_failure' ? { code: codeify(alt(isObj(h.fail) ? nz(h.fail.error) : null, 'error')), category: 'error' }
      : { code: 'unknown', category: 'unknown' };
    const usage = usageOf(pt.usage), vcs = vcsMerge(st.branch, isObj(tend) ? tend.vcs : null), commits = commitsOf(tend);
    const e = base(s, 'turn.end', null, alt(pt.summary ? pt.summary.ts : null, alt(stop ? stop.at : null, pt.last_ts)), { id: pt.id, inferred: false });
    e.provenance = { kind: 'transcript', rule_version: 'turn-v1',
      ...(pt.summary !== null || stop !== null ? { source_event: 'Stop' } : {}),
      ...opt('source_event_id', pt.summary ? pt.summary.uuid : null) };
    e.payload = { status, ...opt('model', pt.model), ...opt('usage', usage), ...opt('vcs', vcs) };
    if (commits !== null) {
      e.commits = commits;
      e.extensions = { ...e.extensions, 'vibetrail.commit_method': alt(isObj(tend) ? nz(tend.commit_method) : null, 'rev-list'),
        'vibetrail.commit_attribution': pt.git_commit ? 'agent_tool' : 'inferred' };
    }
    e.extensions = { ...e.extensions, 'vibetrail.closed_by': how,
      'vibetrail.end_evidence': pt.denied ? 'denial' : evidence,
      'vibetrail.stops': alt(stop ? nz(stop.stops) : null, 0),
      ...opt('vibetrail.dirty_files', isObj(tend) && isObj(tend.vcs) ? nz(tend.vcs.dirty_files) : null),
      ...opt('vibetrail.queued_prompts', alt(pt.queued, 0) > 0 ? pt.queued : null) };
    const stops = alt(stop ? nz(stop.stops) : null, 0);
    e._key = pt.id + '|turn.end' + (stops > 1 ? '|stop' + String(stops) : '');
    if (eof) emitAlways(e); else emit(e);
    if (isNew) inc(st.ledger.turns.ended, status.code);
    st.pturn.closed = true;
  };

  // ---- K7：人拒绝 还是 按停止打断了正在跑的工具 ----
  const splitStop = (s, tu, tur) => {
    const at = epochms(s.ts);
    const sinceNum = Number(perm_since);
    const since = (Number.isFinite(sinceNum) ? sinceNum : 0) * 1000;
    if (since > 0 && at !== null && at >= since) {
      const from = alt(epochms(tu ? tu.ts : null), at - 600000);
      const shown = (isArr(hook_perms) ? hook_perms : []).filter(isObj).filter((p) => {
        if (!(tu === null || tu === undefined ? true : p.tool_name === tu.name)) return false;
        if (!(nz(p.agent_id) === null || p.agent_id === s.agent)) return false;
        const pa = epochms(p.at);
        return pa !== null && pa >= from - 5000 && pa <= at + 5000;
      }).length > 0;
      return { stop: !shown, by: 'permission_request', prompt_shown: shown, mode: st.perm_mode };
    }
    if (s.agent !== null && tur === 'User rejected tool use') return { stop: true, by: 'subagent_rejected' };
    if (st.perm_mode !== null) return { stop: noPromptMode(st.perm_mode), by: 'permission_mode', mode: st.perm_mode };
    return { stop: false, by: 'none' };
  };

  // ---- 三类 is_error 分歧 → permission.decision（+ 被拒调用的 tool.request） ----
  const decisions = (r, s, h) => {
    const blocks = errBlocks(r).filter((b) => kindPred(h.kind)(b.text));
    const t = turnOf(s);
    const tur = isStr(r.toolUseResult) ? r.toolUseResult : null;
    const items = blocks.map((b) => {
      const tu = b.call_id !== null ? alt(nz(st.tools[b.call_id]), null) : null;
      const cls = (h.kind === 'permission_denied' && /^The user doesn't want to proceed with this tool use/.test(b.text)
        && !String(alt(tur, '')).startsWith('Error:')) ? splitStop(s, tu, tur) : null;
      return { b, tu, cls };
    });
    for (const it of items) {
      if (it.cls && it.cls.stop === true) {
        st.stops.push({ uuid: s.uuid, call_id: it.b.call_id, by: it.cls.by, mode: nz(it.cls.mode) ?? null });
        st.ledger.stop_press += 1;
        continue;
      }
      const b = it.b, cid = b.call_id, tu = it.tu;
      const nm = tu !== null ? { name: alt(tu.name, 'unknown'), how: 'index' }
        : /^Permission to use \S+/.test(b.text) ? { name: b.text.match(/^Permission to use (?<n>\S+)/).groups.n, how: 'regex' }
        : { name: 'unknown', how: 'missing' };
      inc(st.ledger.lookup, nm.how);
      // 全采时 trace 那一路已经为每次调用发过同一条 tool.request（_key 相同），这里不再发第二遍
      if (tu !== null && !(turns && capContent)) emit(toolRequest(s, t, cid, tu, { 'vibetrail.trigger': s.uuid, 'vibetrail.kind': h.kind }));
      const e = base(s, 'permission.decision', s.uuid, s.ts, t);
      e.payload = { permission_id: alt(cid, s.uuid), tool_name: nm.name,
        decision: h.kind === 'permission_infra_fail' ? 'error' : 'deny',
        decided_by: { permission_denied: 'user', classifier_blocked: 'policy', permission_infra_fail: 'system' }[h.kind],
        reason: cut(b.text, 4096), ...opt('call_id', cid) };
      if (h.kind === 'permission_denied') e.is_divergence = true;
      e.raw = { event_name: 'diverge.' + h.kind, data: h };
      e.extensions = { ...e.extensions, 'vibetrail.kind': h.kind, 'vibetrail.human': h.human, 'vibetrail.tool_lookup': nm.how,
        ...(alt(it.cls ? it.cls.by : null, 'none') !== 'none'
          ? { 'vibetrail.split_by': it.cls.by, ...opt('vibetrail.permission_mode', nz(it.cls.mode) ?? null), ...opt('vibetrail.prompt_shown', nz(it.cls.prompt_shown) ?? null) }
          : {}) };
      e._key = s.uuid + '|permission.decision|' + alt(cid, '') + '|' + h.kind;
      emit(e);
    }
    if (h.human && items.some((it) => !(it.cls && it.cls.stop === true))) { st.denials.push(s.uuid); addPending(s.uuid, h.kind); }
  };

  // ---- 打断 ----
  const walkUp = (u, n) => {
    if (n === 0 || u === null) return null;
    const c = alt(nz(st.chain[u]), null);
    if (c === null) return null;
    if (c.type === 'assistant' && !c.synthetic) return c;
    if (c.human || c.slash) return null;
    return walkUp(c.parentUuid, n - 1);
  };
  const lastAssistantInTurn = (s) => {
    const from = turnStart();
    const list = st.chain_order.map((u) => st.chain[u]).filter((c) => c && c.type === 'assistant' && !c.synthetic && c.ln >= from && c.ln < s.ln);
    return list.length > 0 ? list[list.length - 1] : null;
  };
  const mergeTexts = (arr) => {
    const out = [];
    for (const x of arr.filter((v) => isStr(v) && v.length > 0)) {
      if (out.length === 0) { out.push(x); continue; }
      const last = out[out.length - 1];
      if (x.startsWith(last)) out[out.length - 1] = x;
      else if (last.startsWith(x)) continue;
      else out.push(x);
    }
    return out.join('\n');
  };
  const wholeReply = (near) => {
    if (near === null || near.mid === null) return near;
    const from = turnStart();
    const grp = st.chain_order.map((u) => st.chain[u])
      .filter((c) => c && c.type === 'assistant' && !c.synthetic && c.mid === near.mid && c.ln >= from && c.ln <= near.ln);
    if (grp.length <= 1) return near;
    return { ...near, text: mergeTexts(grp.map((g) => g.text)), tools: uniqueBy(grp.flatMap((g) => g.tools), (x) => x.id) };
  };

  const interrupted = (r, s, h, detail) => {
    const t = turnOf(s);
    const kind = alt(nz(h.as_kind), h.kind);
    const reply = wholeReply(alt(walkUp(s.parentUuid, 200), lastAssistantInTurn(s)));
    if (reply !== null && reply.text.length > 0) {
      emit(message(s, t, reply, 'message.assistant', 'agent', { 'vibetrail.trigger': s.uuid, 'vibetrail.kind': kind }));
    }
    const stopCalls = (alt(nz(h.stop_calls), [])).filter(isStr);
    if (stopCalls.length > 0) {
      for (const cid of stopCalls) {
        const tu = alt(nz(st.tools[cid]), null);
        if (tu !== null) emit(toolRequest(s, t, cid, tu, { 'vibetrail.trigger': s.uuid, 'vibetrail.kind': kind }));
      }
    } else if (reply !== null) {
      for (const tl of reply.tools) {
        const tu = tl.id !== null ? alt(nz(st.tools[tl.id]), null) : null;
        if (tu !== null) emit(toolRequest(s, t, tl.id, tu, { 'vibetrail.trigger': s.uuid, 'vibetrail.kind': kind }));
      }
    }
    const sub = s.agent !== null;
    const model = alt(reply ? reply.model : null, st.turn_model);
    const usage = usageOf(st.turn_usage);
    const branch = st.branch;
    const hend = sub ? null : hookEnd(hookTurn(t.id));
    const vcs = vcsMerge(branch, isObj(hend) ? hend.vcs : null);
    const commits = commitsOf(hend);
    const gc = alt(st.pturn ? st.pturn.git_commit : null, false);
    const e = base(s, sub ? 'subagent.end' : 'turn.end', s.uuid, s.ts, t);
    e.is_divergence = true;
    e.payload = { status: { code: sub ? 'cancelled' : 'interrupted', category: 'cancellation', detail: cut(detail, 4096) },
      ...(sub ? opt('agent_type', isObj(meta) ? nz(meta.agentType) : null)
        : { ...opt('model', model), ...opt('usage', usage), ...opt('vcs', vcs) }) };
    if (commits !== null) {
      e.commits = commits;
      e.extensions = { ...e.extensions, 'vibetrail.commit_method': alt(isObj(hend) ? nz(hend.commit_method) : null, 'rev-list'),
        'vibetrail.commit_attribution': gc ? 'agent_tool' : 'inferred' };
    }
    const rawData = { ...h }; delete rawData.as_kind; delete rawData.split_by; delete rawData.permission_mode; delete rawData.stop_calls;
    e.raw = { event_name: 'diverge.' + h.kind, data: rawData };
    e.extensions = { ...e.extensions, 'vibetrail.kind': kind, 'vibetrail.human': true,
      ...opt('vibetrail.interrupted_uuid', reply ? reply.uuid : null),
      ...opt('vibetrail.split_by', nz(h.split_by) ?? null), ...opt('vibetrail.permission_mode', nz(h.permission_mode) ?? null) };
    e._key = s.uuid + '|' + e.type;
    emit(e);
    if (!sub && st.pturn !== null && st.pturn.id === t.id) st.pturn.interrupted = true;
    addPending(s.uuid, kind);
  };

  const forToolUse = (r, s, h) => {
    if (st.denials.length > 0) {
      st.ledger.absorbed_for_tool_use += 1;
      addPending(s.uuid, 'interrupt_for_tool_use');
      if (st.pturn !== null && st.pturn.id === turnOf(s).id) { st.pturn.denied = true; closeTurn('denied', s, false); }
    } else if (st.stops.length > 0) {
      const sp = st.stops[0];
      const calls = st.stops.map((x) => x.call_id).filter(isStr);
      interrupted(r, s, { ...h, as_kind: 'interrupt_tool', split_by: sp.by, permission_mode: sp.mode, stop_calls: calls }, s.text);
    } else {
      st.ledger.unpaired_for_tool_use += 1;
      interrupted(r, s, h, 'unpaired interrupt_for_tool_use: ' + s.text);
    }
  };

  const handle = (r, s, h) => {
    if (st.ln > from_line) inc(st.ledger.in, h.kind);
    inc(st.ledger.in_total, h.kind);
    if (h.kind === 'interrupt') interrupted(r, s, h, s.text);
    else if (h.kind === 'interrupt_for_tool_use') forToolUse(r, s, h);
    else decisions(r, s, h);
    if (st.ln > from_line) inc(st.ledger.out, h.kind);
  };

  const emitAfter = (s) => {
    const p = st.pending;
    emit(message(s, turnOf(s), s, 'message.user', 'user',
      { 'vibetrail.after': p.after, 'vibetrail.after_kind': p.kind, ...(s.slash ? { 'vibetrail.slash_command': true } : {}) }));
    if (s.human) st.pending = null;
  };
  const emitPrompt = (s) => emit(message(s, turnOf(s), s, 'message.user', 'user', s.slash ? { 'vibetrail.slash_command': true } : {}));

  const turnBoundary = (r, s) => {
    if (turns && mainRec(r) && r.type === 'user' && isStr(r.promptId) && r.promptId !== alt(st.pturn ? st.pturn.id : null, null)) {
      closeTurn('next_turn', s, false);
      openTurn(s);
    }
  };

  const stopFeedback = (r, s) => (r.type === 'attachment' && isObj(r.attachment)
      && /^hook_(blocking_error|additional_context)$/.test(alt(nz(r.attachment.type), ''))
      && /^(Stop|SubagentStop)$/.test(alt(nz(r.attachment.hookEvent), '')))
    || (r.type === 'user' && /^(Stop|SubagentStop) hook feedback:/.test(s.text));

  const turnStopMarker = (r, s) => {
    if (st.pturn !== null && !st.pturn.closed && st.pturn.answered && mainRec(r) && r.type === 'system' && r.subtype === 'stop_hook_summary') {
      if (alt(st.pturn.stop_blocked, false)) { st.pturn.stop_blocked = false; st.pturn.block_pending = true; }
      else {
        st.pturn.summary = { uuid: s.uuid, ts: s.ts, prevented: r.preventedContinuation === true, reason: alt(nz(r.stopReason), '') };
        closeTurn('summary', s, false);
      }
    }
  };

  const turnAccumulate = (r, s) => {
    if (st.pturn === null || !mainRec(r)) return;
    st.pturn.last_ts = alt(s.ts, st.pturn.last_ts);
    if (s.type === 'assistant' && !s.synthetic) {
      st.pturn.stop_blocked = false; st.pturn.block_pending = false; st.pturn.answered = true;
      st.pturn.end_turn = (isObj(r.message) ? nz(r.message.stop_reason) : null) === 'end_turn';
    }
    if (stopFeedback(r, s)) st.pturn.stop_blocked = true;
    if (isQueuedHuman(r)) st.pturn.queued += 1;
    if (s.type === 'assistant' && s.usage !== null && !s.synthetic) {
      const uk = alt(s.mid, alt(s.rid, s.uuid));
      const cur = st.pturn.usage[uk];
      if (!(alt(cur ? nz(cur.output_tokens) : null, -1) > alt(nz(s.usage.output_tokens), 0))) st.pturn.usage[uk] = s.usage;
      st.pturn.model = alt(s.model, st.pturn.model);
    }
    if (s.tools.some((t) => t.name === 'Bash' && gitCommitCmd(isObj(t.input) ? nz(t.input.command) : null))) st.pturn.git_commit = true;
  };

  // ---- trace ----
  const flushCall = (eof) => {
    if (st.call === null) return;
    const c = st.call;
    const txt = alt(c.text, ''), think = alt(c.reasoning, '');
    const e = base({ agent: c.agent }, 'message.assistant', c.last_uuid, c.last_ts, c.turn);
    e.content_state = (capContent && txt.length > 0) ? 'included' : 'omitted';
    e.payload = { author_type: 'agent', ...opt('model', c.model), ...(capContent && txt.length > 0 ? { text: txt } : {}) };
    e.provenance = { kind: 'transcript', rule_version: 'call-v1', source_event_id: c.last_uuid };
    if (capContent && think.length > 0) e.extensions = { ...e.extensions, 'vibetrail.reasoning': think };
    const startedAt = (c.started_at !== null && c.last_ts !== null && cmpJq(c.started_at, c.last_ts) > 0) ? c.last_ts : c.started_at;
    e.extensions = { ...e.extensions, 'vibetrail.call': {
      kind: 'llm', stop_reason: c.stop_reason, tool_calls: c.tools, tool_call_ids: alt(c.tool_ids, []), thinking: c.thinking,
      ...opt('response_id', c.mid), ...opt('request_id', c.rid), ...opt('usage', usageOne(c.usage)), ...opt('started_at', startedAt) } };
    e._key = c.key + '|llm.call';
    if (eof) emitAlways(e); else emit(e);
    st.prev_end_ts = jqMax([st.prev_end_ts, c.last_ts]);
    st.call = null;
  };

  const toolEnds = (r, s) => {
    const c = msgOf(r).content;
    if (!isArr(c)) return;
    for (const b of c.filter(isObj).filter((x) => x.type === 'tool_result')) {
      const cid = alt(nz(b.tool_use_id), null);
      if (cid === null || !st.tools[cid]) continue;
      const tu = st.tools[cid];
      const txt = errText(b.content);
      const status = b.is_error !== true ? { code: 'success', category: 'success' }
        : /^\[Tool call (did not complete|skipped)/.test(txt) ? { code: 'cancelled', category: 'cancellation' }
        : (isHumanDenial(txt) || isClassifier(txt) || isInfra(txt) || txt.startsWith("The user doesn't want to")) ? null
        : { code: 'error', category: 'error' };
      if (status === null) continue;
      const b1 = epochms(s.ts), a1 = epochms(tu.ts);
      const d = (b1 !== null && a1 !== null && b1 >= a1) ? b1 - a1 : null;
      const t = { id: alt(st.turn, s.uuid), inferred: st.turn === null };
      const e = base(s, 'tool.end', s.uuid, s.ts, t);
      e.content_state = capContent ? 'included' : 'omitted';
      e.payload = { tool_name: tu.name, call_id: cid, status, ...opt('duration_ms', d),
        ...(capContent ? opt('output', alt(nz(b.content), alt(nz(b.output), alt(nz(b.result), null)))) : {}) };
      e.provenance = { kind: 'transcript', rule_version: 'call-v1', source_event_id: s.uuid };
      e._key = cid + '|tool.end';
      emit(e);
    }
  };

  const apiError = (r, s) => {
    if (!(r.type === 'system' && r.subtype === 'api_error')) return;
    const at = alt(s.ts, '');
    const req = minBy(st.calls_seen.filter((x) => x.started_at !== null && x.first_ts !== null && cmpJq(x.started_at, at) <= 0 && cmpJq(x.first_ts, at) >= 0), (x) => x.first_ts);
    let err = {};
    if (isStr(r.error)) { try { err = JSON.parse(r.error); } catch { err = {}; } if (!isObj(err)) err = {}; }
    else if (isObj(r.error)) err = r.error;
    const t = { id: alt(req ? req.turn.id : null, alt(st.turn, s.uuid)), inferred: req ? req.turn.inferred : st.turn === null };
    const e = base(s, 'ext.claude.api_error', s.uuid, s.ts, t);
    e.content_state = 'omitted';
    const emsg = alt(nz(err.formatted), alt(nz(err.message), null));
    e.payload = { ...opt('retry_attempt', nz(r.retryAttempt)), ...opt('retry_in_ms', nz(r.retryInMs)), ...opt('max_retries', nz(r.maxRetries)),
      ...opt('source', nz(r.source)), ...opt('error', isStr(emsg) ? cut(emsg, 200) : null), ...opt('status', alt(nz(err.status), null)) };
    // 协议要求 ext.* 带 source_event（今天更新的 schema）；这一路是 transcript 出的，填来源记录的子类型
    e.provenance = { kind: 'transcript', rule_version: 'call-v1', source_event: 'api_error', source_event_id: s.uuid };
    e.extensions = { ...e.extensions, ...opt('vibetrail.response_id', req ? req.mid : null) };
    e._key = s.uuid + '|api_error';
    emit(e);
  };

  const traceStep = (r, s) => {
    if (s.type === 'user') { toolEnds(r, s); st.prev_end_ts = jqMax([st.prev_end_ts, s.ts]); }
    apiError(r, s);
    if (!(s.type === 'assistant' && !s.synthetic)) return;
    const k = alt(s.mid, alt(s.rid, s.uuid));
    if (st.call !== null && st.call.key !== k) flushCall(false);
    if (st.call === null) {
      st.call = { key: k, mid: s.mid, rid: s.rid, model: s.model, usage: s.usage, stop_reason: isObj(r.message) ? nz(r.message.stop_reason) : null,
        tools: s.tools.map((t) => t.name), tool_ids: s.tools.map((t) => t.id).filter(isStr), thinking: thinkingIn(r),
        last_ts: s.ts, last_uuid: s.uuid, ck: baseCheckpoint(), started_at: st.prev_end_ts, agent: s.agent,
        turn: { id: alt(st.turn, s.uuid), inferred: st.turn === null },
        text: capContent ? s.text : '', reasoning: capContent ? thinkingTextOf(r) : '' };
      st.calls_seen.push({ mid: k, turn: st.call.turn, started_at: st.call.started_at, first_ts: s.ts });
      if (st.calls_seen.length > 200) st.calls_seen = st.calls_seen.slice(1);
    } else {
      st.call.last_ts = alt(s.ts, st.call.last_ts);
      st.call.last_uuid = s.uuid;
      st.call.stop_reason = alt(isObj(r.message) ? nz(r.message.stop_reason) : null, st.call.stop_reason);
      st.call.tools = [...st.call.tools, ...s.tools.map((t) => t.name)];
      st.call.tool_ids = [...st.call.tool_ids, ...s.tools.map((t) => t.id).filter(isStr)];
      st.call.thinking = st.call.thinking || thinkingIn(r);
      if (capContent) {
        st.call.text = [st.call.text, s.text].filter((v) => isStr(v) && v.length > 0).join('\n');
        st.call.reasoning = [st.call.reasoning, thinkingTextOf(r)].filter((v) => isStr(v) && v.length > 0).join('\n');
      }
      if (s.usage !== null && alt(nz(s.usage.output_tokens), 0) >= alt(st.call.usage ? nz(st.call.usage.output_tokens) : null, -1)) st.call.usage = s.usage;
    }
    // 全采：每次工具调用一条 tool.request，带完整参数（_key 与分歧那一路一样，只发一条）
    if (capContent) {
      for (const tu of s.tools.filter((x) => x.id !== null)) {
        const e = base(s, 'tool.request', s.uuid, s.ts, { id: alt(st.turn, s.uuid), inferred: st.turn === null });
        e.content_state = 'included';
        e.payload = { tool_name: alt(tu.name, 'unknown'), call_id: tu.id, input: tu.input };
        e.provenance = { kind: 'transcript', rule_version: 'call-v1', source_event_id: s.uuid };
        e._key = s.uuid + '|tool.request|' + tu.id;
        emit(e);
      }
    }
  };

  // 全采：system prompt。它在 attachment/prompt_snapshot 里（≥ 2.1.258，DESIGN §6.3），一个会话里会重复快照几十次，
  // 所以按正文的 sha256 做幂等键——同一份只发一条（再次出现时 _key 相同，本机 ids 与云端都按 event_id 挡掉）。
  // 协议 1.0 没有 system_instructions 字段，且明说「不得把系统提示伪装成普通 Assistant 文本，无法标准化时使用扩展事件」，
  // 所以走扩展事件 ext.claude.prompt_snapshot，正文进 extensions["vibetrail.system_prompt"]
  const promptSnapshot = (r, s) => {
    if (!capContent) return;
    if (!(r.type === 'attachment' && isObj(r.attachment) && r.attachment.type === 'prompt_snapshot')) return;
    // 2.1.27x 给的是「分段字符串数组」（本机实测 16 段约 14 KB），老版本可能是整串或块数组：三种都吃下
    const raw = r.attachment.systemPrompt;
    const text = isStr(raw) ? raw
      : isArr(raw) ? raw.map((x) => (isStr(x) ? x : isObj(x) && isStr(x.text) ? x.text : '')).filter((x) => x.length > 0).join('\n')
      : '';
    if (text.length === 0) return;
    const sha = crypto.createHash('sha256').update(text, 'utf8').digest('hex');
    const e = base(s, 'ext.claude.prompt_snapshot', s.uuid, s.ts, { id: alt(st.turn, s.uuid), inferred: st.turn === null });
    e.content_state = 'included';
    e.payload = { bytes: Buffer.byteLength(text, 'utf8'), sha256: sha };
    e.provenance = { kind: 'transcript', rule_version: 'call-v1', source_event: 'prompt_snapshot', source_event_id: s.uuid };
    e.extensions = { ...e.extensions, 'vibetrail.system_prompt': text };
    e._key = 'ext|prompt_snapshot|' + sha.slice(0, 16);
    emit(e);
  };

  // ---- 一条记录 ----
  const step = (r) => {
    st.out = [];
    st.ln += 1;
    const ln = st.ln;
    if (!isObj(r)) { st.ledger.skipped_non_object += 1; return; }
    if (!isStr(r.uuid)) { st.ledger.skipped_no_uuid += 1; return; }
    const s = slim(r, ln);
    const hits = diverge(r);
    if (st.run_uuids[r.uuid] || (st.prior[r.uuid] !== undefined && st.prior[r.uuid] !== ln)) { st.ledger.replayed += 1; return; }
    st.run_uuids[r.uuid] = true;
    st.ledger.records += 1;
    st.last_ts = alt(nz(r.timestamp), st.last_ts);
    st.version = alt(nz(r.version), st.version);
    st.entrypoint = alt(nz(r.entrypoint), st.entrypoint);
    st.branch = alt(nz(r.gitBranch), st.branch);
    if (isStr(r.promptId) && r.promptId !== st.turn) { st.turn = r.promptId; st.denials = []; st.stops = []; }
    if ((s.human || s.slash) && isStr(r.permissionMode)) st.perm_mode = r.permissionMode;
    turnBoundary(r, s);
    index(s);
    if (s.human) { st.turn_usage = {}; st.turn_model = null; st.turn_line = s.ln; }
    if (s.type === 'assistant' && s.usage !== null && !s.synthetic) {
      const uk = alt(s.mid, alt(s.rid, s.uuid));
      const cur = st.turn_usage[uk];
      if (!(alt(cur ? nz(cur.output_tokens) : null, -1) > alt(nz(s.usage.output_tokens), 0))) st.turn_usage[uk] = s.usage;
      st.turn_model = alt(s.model, st.turn_model);
    }
    turnAccumulate(r, s);
    turnStopMarker(r, s);
    promptSnapshot(r, s);
    if (turns) traceStep(r, s);
    if (ln > from_line) st.ledger.sources.push([s.uuid, ln]);
    if (isStr(r.toolUseResult) && r.toolUseResult.startsWith('User rejected tool use')) {
      st.ledger.sentinel.marker += 1;
      if (!hits.some((h) => h.kind === 'permission_denied')) st.ledger.sentinel.marker_without_hit += 1;
    }
    for (const h of hits) handle(r, s, h);
    if (s.human || s.slash) {
      if (st.pending !== null) emitAfter(s);
      else if (capContent) emitPrompt(s);
    }
  };

  const checkpoint = () => {
    const c = baseCheckpoint();
    return st.call !== null ? jqMin([c, st.call.ck]) : c;
  };

  const atEof = () => {
    st.out = [];
    if (turns && st.call !== null && close_last !== '') flushCall(true);
    if (close_last === '' || st.pturn === null) return;
    const nullRec = { agent: null, uuid: null, ts: null };
    if (close_last === 'stop') {
      if (st.pturn.id === stop_turn && st.pturn.answered && !st.pturn.block_pending && !st.pturn.stop_blocked) closeTurn('stop', nullRec, true);
    } else closeTurn(close_last, nullRec, true);
  };

  // ---- 跑 ----
  const events = [];
  for (const r of records) { step(r); events.push(...st.out); }
  atEof();
  events.push(...st.out);

  const ledger = { ...st.ledger,
    start_line, from_line, lines: st.ln, checkpoint_line: checkpoint(),
    sources: st.ledger.sources,
    turns: { ...st.ledger.turns, open: alt(st.pturn ? st.pturn.id : null, null), open_line: alt(st.pturn ? st.pturn.line : null, null),
      closed: alt(st.pturn ? st.pturn.closed : null, false), model: alt(st.pturn ? st.pturn.model : null, st.turn_model) },
    trace: { call_open: st.call !== null } };
  return { events, ledger };
}
