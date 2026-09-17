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

// K19：映射规则的版本号，四路各一个，进每条事件的 provenance.rule_version。协议：「适配器升级映射规则时更新 rule_version，
// 不得改写已经接收的历史事件」——event_id 不含它，重读出来的 event_id 不变、云端按重复收下，所以升版本不改写历史。
// 09-16 push 前统一升到 v2 定成基线（09-15 定 v1 之后改过 K8 / K12 / K13 / D13 / K15② / 全采 / K18 / U12 / K20–K23，版本号一直没动）。
// 之后每改一次映射规则就升对应的一路；test-map.sh 钉着：golden 变了而版本号没升就红
// 09-16 第二批（同日）：子 agent 自己改的文件进 subagent.end / 被打断的 subagent.end / 那一轮的 files[]、workflow agent 挂回主会话、
// 同步 agent 按 meta 的 toolUseId 认结束 → turn-v3、diverge-v3；cwd_changed / instructions_loaded 的路径改相对 → ext-v3。call 没变
export const RULE_VERSIONS = { diverge: 'diverge-v4', turn: 'turn-v4', call: 'call-v2', ext: 'ext-v3' };
// 调用方（hook.mjs 的 mapFile）按物理行喂记录：解析不了的行、空行也占一个位置，行号才与字节 checkpoint 对得上（以前直接丢掉，
// 中间出现坏行时 checkpoint 换算成字节会错位，下次从错的地方读）；坏行计进 A11 的 bad_json
export const BAD_LINE = Symbol.for('vibetrail.bad_line');
export const BLANK_LINE = Symbol.for('vibetrail.blank_line');

// K22：turn.end.files[] 的路径要相对工作区根、不能 .. 、不能以 / 开头、不能有 \ 与控制字符（schema 的 path 正则）
const PATH_OK = /^(?!\/)(?![A-Za-z]:)(?!.*\\)(?!.*(?:^|\/)\.{1,2}(?:\/|$))(?!.*\/\/)(?![\s\S]*[\x00-\x1f])[^/]+(?:\/[^/]+)*$/;
const stripPrivate = (p) => String(p).replace(/^\/private(\/(?:tmp|var)(?:\/|$))/, '$1');   // macOS：/private/tmp 与 /tmp 是同一处
const FILE_TOOLS = { Edit: 'modify', MultiEdit: 'modify', NotebookEdit: 'modify', Write: 'modify', Read: 'read' };
const OP_RANK = { create: 3, modify: 2, read: 1 };
// 本机路径不出本机（用户 09-16 定「相对路径」）：工作区内的目录 / 文件按根算相对路径（根本身是 .），根外的把 /Users/<名> 或 /home/<名> 换成 ~，
// 不看当前 HOME（fixture 里别人的家目录也一样处理）。用在 ext.claude.cwd_changed、instructions_loaded 的 path 上；tool.request 的参数是正文（K6），不动
const tilde = (p) => String(p).replace(/^\/(?:(?:Users|home)\/[^/]+|root)(?=\/|$)/, '~');
// 目录类字段（cwd、worktree）的写法：主 checkout 里的相对主 checkout（本身是 .，desktop 的 worktree 是 .claude/worktrees/<名>，保留是哪个 worktree），
// 其余换成 ~ 形。roots 的第一个是主 checkout（hook 传 vtWorktrees 的结果）
export function displayDir(abs, roots) {
  if (!isStr(abs) || abs === '') return abs;
  const p = stripPrivate(abs).replace(/\/+$/, '') || '/';
  const main = (isArr(roots) ? roots : []).filter(isStr).map((r) => stripPrivate(r).replace(/\/+$/, '')).find((r) => r !== '');
  if (main) {
    if (p === main) return '.';
    if (p.startsWith(main + '/')) return p.slice(main.length + 1);
  }
  return tilde(p);
}
// A11 完整性钉子：认识的记录类型 / 附件类型 / system 子类型（2026-09-16 本机 34 份文件实测 + 代码里用到的；09-17 真实数据补采报出 auto_mode_exit，只有 bashFirst / steerOnly 两个开关，登记）。清单之外的计进账本 new.unknown_types，
// doctor 告警——不认识不等于错，Claude Code 每个版本都会加类型；D13 去掉 8 个 hook 之后没有 hook 侧对账了，这是唯一的「有新东西」哨兵
const KNOWN_TYPES = new Set(['user', 'assistant', 'system', 'attachment', 'summary', 'progress', 'queue-operation', 'last-prompt', 'custom-title',
  'bridge-session', 'atis-latch', 'file-history-snapshot', 'file-history-delta', 'mode']);
const KNOWN_ATTACHMENTS = new Set(['deferred_tools_delta', 'deferred_tools_record', 'skill_listing', 'remote_session_change', 'agent_listing_delta',
  'mcp_instructions_delta', 'auto_mode', 'auto_mode_exit', 'total_tokens_reminder', 'batching_reminder_sent', 'queued_command', 'silent_turn_reminder', 'edited_text_file',
  'edited_image_file', 'environment', 'model', 'instructions', 'nested_memory', 'session_context', 'date', 'date_change', 'prompt_snapshot',
  'read_truncation_notice', 'thinking_stripped', 'compact_file_reference', 'file', 'directory', 'hook_blocking_error', 'hook_additional_context',
  'async_hook_response', 'todo_reminder', 'plan_mode', 'output_style', 'diagnostics', 'lsp_diagnostics', 'ide_selection', 'ide_opened_file',
  'opened_file_in_ide', 'selected_lines_in_ide', 'command_permissions', 'invoked_skills', 'ultramemory_context', 'trigger_reminder']);
const KNOWN_SYSTEM = new Set(['stop_hook_summary', 'api_error', 'compact_boundary', 'turn_duration', 'local_command', 'informational', 'bridge_status']);

export function mapRecords(records, args) {
  const {
    sid, project_id, workspace_id, parent_instance = 'main',
    start_line = 1, from_line = 0, meta = null,
    seen_uuids = [], hook_turns = {}, hook_perms = [], perm_since = '', perm_periods = null, split_decisions = {},
    known_agents = {}, done_ts = null,
    close_last = '', stop_turn = '', turns = true,
    vt_version = '', rule_version = RULE_VERSIONS.diverge, capture_content = '1',
    workspace_roots = null, workflow_runs = {},
  } = args;
  const capContent = capture_content !== '0';
  // K22：工作区的根（主 checkout 与它的 worktree，hook 侧给；没给就没有 files[]）。最长的根先匹配，desktop 的 worktree 在主 checkout 下面
  const roots = (isArr(workspace_roots) ? workspace_roots : []).filter((p) => isStr(p) && p !== '')
    .map((p) => stripPrivate(p).replace(/\/+$/, '')).filter((p) => p !== '').sort((a, b) => b.length - a.length);
  const relPath = (abs) => {
    if (!isStr(abs) || abs === '') return null;
    const p = stripPrivate(abs);
    for (const r of roots) {
      if (!p.startsWith(r + '/')) continue;
      // desktop 的 worktree 都在主 checkout 的 .claude/worktrees/<名>/ 下：worktree 已经删了（不在 git worktree list 里）时也按仓内路径算，
      // 否则同一个文件在 worktree 删前删后是两个路径
      const rel = p.slice(r.length + 1).replace(/^\.claude\/worktrees\/[^/]+\//, '');
      return PATH_OK.test(rel) ? rel : null;
    }
    return null;
  };
  // 「不出本机」的两种写法（用户 09-16 定相对路径）：目录（cwd）相对主 checkout；文件（CLAUDE.md 等）与 files[] 同一套相对路径，根外换成 ~ 形
  const safeDir = (abs) => displayDir(abs, workspace_roots);
  const safeFile = (abs) => (isStr(abs) ? alt(relPath(abs), displayDir(abs, workspace_roots)) : abs);

  const prior = {};
  for (const p of seen_uuids) prior[p[0]] = p[1];
  // K15④：PermissionRequest 挂上过的时间段。以前只有一个 perm_since，判定用的是「重读那一刻」的配置，
  // 重跑 init 没登记它就被清空，历史的结论跟着翻。现在按「拒绝发生那一刻挂没挂着」判
  const periods = (isArr(perm_periods) && perm_periods.length > 0) ? perm_periods
    : (Number(perm_since) > 0 ? [[Number(perm_since), null]] : []);
  const mountedAt = (ms) => ms !== null && periods.some(([a, b]) => ms >= Number(a) * 1000 && (b === null || b === undefined || ms < Number(b) * 1000));
  // 用户 09-16 定（K15④ 方案 A）：一次「拒绝」第一次判出人拒绝还是按停止，就记下来，之后重读一律沿用、不重算——
  // 否则配置变了、弹框证据过期（两周清）、uninstall 删了证据，重读都会翻结论，而两种结论发的是不同的事件（event_id 不同），
  // 云端会对同一次动作收到两条互相矛盾的记录。键是「拒绝记录 uuid|调用 id」；新判的放进账本，由调用方存进 state
  const splitsPrior = isObj(split_decisions) ? split_decisions : {};
  const splitsNew = {};
  let splitsReused = 0;

  const st = {
    ln: start_line - 1, turn: null, turn_line: 0,
    run_uuids: {}, prior,
    tools: {}, tool_order: [],
    chain: {}, chain_order: [],
    turn_usage: {}, turn_model: null,
    seen: {}, denials: [], stops: [], perm_mode: null, pending: null,
    pturn: null, call: null, calls_seen: [], prev_end_ts: null,
    agents: { launched: {}, done: {}, calls_done: {}, workflows: {} }, agent_started: false, last_cwd: null,
    // 子 agent 文件自己改 / 读的文件（整份文件一个集合，不分轮；K22 的子 agent 部分），关它的 subagent.end 时带上
    agent_files: { files: {}, files_outside: 0 }, agent_id: null,
    last_ts: null, version: null, entrypoint: null, branch: null,
    ledger: {
      in: {}, in_total: {}, out: {}, events: {}, absorbed_for_tool_use: 0, unpaired_for_tool_use: 0,
      lookup: { index: 0, regex: 0, missing: 0 }, stop_press: 0, dedup: 0, records: 0, skipped_no_uuid: 0, skipped_non_object: 0,
      sentinel: { marker: 0, marker_without_hit: 0 }, replayed: 0, inherited: 0, turns: { started: 0, ended: {} }, sources: [],
      // A11：只数这次新读到的行（ln > from_line），调用方按会话累计进 state、doctor 汇总。
      // 恒等式：seen = records + bad_json + skipped_non_object + skipped_no_uuid + replayed + inherited（空行不算 seen）
      bad_json: 0,
      new: { seen: 0, records: 0, bad_json: 0, skipped_non_object: 0, skipped_no_uuid: 0, replayed: 0, inherited: 0, content_dropped: 0,
        sentinel: { marker: 0, marker_without_hit: 0 }, unknown_types: {} },
    },
    out: [],
  };

  // ---- 事件骨架 ----
  const dropContent = (e) => {
    if (isObj(e.payload)) { delete e.payload.text; delete e.payload.input; delete e.payload.output; delete e.payload.last_message; }
    if (isObj(e.extensions)) for (const k of ['vibetrail.reasoning', 'vibetrail.system_prompt', 'vibetrail.instructions']) delete e.extensions[k];
    delete e.raw;
    e.content_state = 'omitted';
    e.extensions = { ...e.extensions, 'vibetrail.content_dropped': 'size' };
    st.ledger.new.content_dropped += 1;
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

  // U12（用户 09-16 定，按采集端协议文档「usage 是累计值，采不到的字段省略而不是传 0；cached 通常是 input 的子集、reasoning 是 output 的子集，
  // 不能把所有字段直接相加」）：input = input_tokens + cache_creation + cache_read（Claude 的 input_tokens 不含缓存，要加回去），
  // cached = cache_read（input 的子集），output 原样（thinking 已含在里面），reasoning = thinking_tokens（output 的子集），
  // total = input + output。来源一个字段都没给的就不填那一项，不再当 0 加。Pilot 的公式与此相同（hook-processor 的「token 全量公式」），
  // teamai 是四桶独立、总数四项相加——正是协议不许的算法。09-15 以前：input 不含缓存读、total 三项相加、缺的按 0
  const numOrNull = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
  const usageSum = (us) => {
    let inp = null, cc = null, cr = null, out = null, think = null;
    const add = (a, v) => (v === null ? a : (a ?? 0) + v);
    for (const u of us) {
      inp = add(inp, numOrNull(u.input_tokens)); cc = add(cc, numOrNull(u.cache_creation_input_tokens)); cr = add(cr, numOrNull(u.cache_read_input_tokens));
      out = add(out, numOrNull(u.output_tokens));
      think = add(think, isObj(u.output_tokens_details) ? numOrNull(u.output_tokens_details.thinking_tokens) : null);
    }
    const o = {};
    const input = (inp === null && cc === null && cr === null) ? null : (inp ?? 0) + (cc ?? 0) + (cr ?? 0);
    if (input !== null) o.input_tokens = input;
    if (cr !== null) o.cached_input_tokens = cr;
    if (out !== null) o.output_tokens = out;
    if (think !== null && think > 0) o.reasoning_tokens = think;
    if (input !== null || out !== null) o.total_tokens = (input ?? 0) + (out ?? 0);
    return Object.keys(o).length > 0 ? o : null;
  };
  const usageOf = (m) => { const us = Object.values(m).filter(isObj); return us.length === 0 ? null : usageSum(us); };
  const usageOne = (u) => (isObj(u) ? usageSum([u]) : null);

  // K22：这一轮改 / 读了哪些文件——Edit / MultiEdit / NotebookEdit / Write / Read 成功的结果记进当前轮（主会话文件才有轮），
  // 关轮时挂到 turn.end.files[]（协议把它与 commits[] 当成查「每轮改了哪些文件」的标准入口）。evidence 一律 tool_result（结果没报错才记）；
  // Write 的结果 type=create 记 create，其余改动记 modify；同一文件取最重的操作（create > modify > read）。
  // 路径相对工作区根，根外的（K2 跨仓，协议没有表达法）不发、只计数；超过协议上限 256 项先丢 read 再截断，都记在 extensions。
  // 本机实测（09-16，11 个会话 72 轮）：有改动的轮平均 3.5 个文件、最多 10 个，路径平均 102 字节——每条 turn.end 不到 1 KB
  const noteFile = (pt, absPath, op) => {
    if (pt === null) return;
    const rel = relPath(absPath);
    if (rel === null) { if (roots.length > 0 && isStr(absPath) && absPath !== '') pt.files_outside += 1; return; }
    const cur = pt.files[rel];
    if (cur === undefined || OP_RANK[op] > OP_RANK[cur]) pt.files[rel] = op;
  };
  const attachFiles = (e, pt) => {
    if (!pt || !isObj(pt.files)) return;
    let list = Object.entries(pt.files).map(([p, op]) => ({ path: p, operation: op, evidence: 'tool_result' }));
    let truncated = 0;
    if (list.length > 256) {
      const changed = list.filter((f) => f.operation !== 'read');
      list = changed.length > 256 ? changed.slice(0, 256) : changed;
      truncated = Object.keys(pt.files).length - list.length;
    }
    if (list.length > 0) e.files = list;
    const outside = alt(nz(pt.files_outside), 0);
    if (truncated > 0 || outside > 0) {
      e.extensions = { ...e.extensions, 'vibetrail.files_dropped': { ...(outside > 0 ? { outside_workspace: outside } : {}), ...(truncated > 0 ? { over_limit: truncated } : {}) } };
    }
  };
  // 子 agent 的文件集合：以前几次读到的（调用方从 agents.json 经 known_agents 传进来）并上这次读到的，同一文件取最重的操作
  const mergeFiles = (a, b) => {
    const out = { ...(isObj(a) ? a : {}) };
    for (const [p, op] of Object.entries(isObj(b) ? b : {})) if (out[p] === undefined || OP_RANK[op] > OP_RANK[out[p]]) out[p] = op;
    return out;
  };
  const agentHolder = (aid, own) => {
    const k = isObj(knownAgents[aid]) ? knownAgents[aid] : {};
    return { files: mergeFiles(k.files, own ? st.agent_files.files : null),
      files_outside: Math.max(alt(nz(k.files_outside), 0), own ? st.agent_files.files_outside : 0) };
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
  const openTurn = (s, kind = null) => {
    st.pturn = { id: s.promptId, line: s.ln, last_ts: s.ts, usage: {}, model: null, answered: false,
      interrupted: false, denied: false, git_commit: false, closed: false, end_turn: false, stop_blocked: false,
      block_pending: false, summary: null, queued: 0, files: {}, files_outside: 0, kind };
    if (s.ln > from_line) st.ledger.turns.started += 1;
    const h = hookTurn(s.promptId);
    const vcs = vcsMerge(st.branch, isObj(h.start) ? h.start.vcs : null);
    const e = base(s, 'turn.start', s.uuid, s.ts, { id: s.promptId, inferred: false });
    e.provenance = { kind: 'transcript', rule_version: RULE_VERSIONS.turn, source_event_id: s.uuid };
    e.payload = { ...opt('vcs', vcs) };
    if (kind !== null) e.extensions = { ...e.extensions, 'vibetrail.turn_kind': kind };
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
      : pt.api_error ? 'api_error'
      : pt.end_turn ? 'end_turn' : 'none';
    // K18：分类一律用协议推荐值（success / failure / cancellation / denial / unknown），来源自己的状态留在 code 里（协议允许）
    const status = pt.denied ? { code: 'denied', category: 'denial', detail: 'turn stopped by a permission denial' }
      : (pt.summary && pt.summary.prevented === true) ? { code: 'hook_stopped', category: 'cancellation', detail: cut(alt(pt.summary.reason, ''), 4096) }
      : (evidence === 'stop_hook_summary' || evidence === 'hook_stop' || evidence === 'end_turn') ? { code: 'completed', category: 'success' }
      : evidence === 'stop_failure' ? { code: codeify(alt(isObj(h.fail) ? nz(h.fail.error) : null, 'error')), category: 'failure' }
      : evidence === 'api_error' ? { code: codeify(pt.api_error.error), category: 'failure' }
      : { code: 'unknown', category: 'unknown' };
    const usage = usageOf(pt.usage), vcs = vcsMerge(st.branch, isObj(tend) ? tend.vcs : null), commits = commitsOf(tend);
    const e = base(s, 'turn.end', null, alt(pt.summary ? pt.summary.ts : null, alt(stop ? stop.at : null, pt.last_ts)), { id: pt.id, inferred: false });
    e.provenance = { kind: 'transcript', rule_version: RULE_VERSIONS.turn,
      ...(pt.summary !== null || stop !== null ? { source_event: 'Stop' } : {}),
      ...opt('source_event_id', pt.summary ? pt.summary.uuid : null) };
    e.payload = { status, ...opt('model', pt.model), ...opt('usage', usage), ...opt('vcs', vcs) };
    if (commits !== null) {
      e.commits = commits;
      e.extensions = { ...e.extensions, 'vibetrail.commit_method': alt(isObj(tend) ? nz(tend.commit_method) : null, 'rev-list'),
        'vibetrail.commit_attribution': pt.git_commit ? 'agent_tool' : 'inferred' };
    }
    attachFiles(e, pt);
    e.extensions = { ...e.extensions, 'vibetrail.closed_by': how,
      'vibetrail.end_evidence': pt.denied ? 'denial' : evidence,
      'vibetrail.stops': alt(stop ? nz(stop.stops) : null, 0),
      ...opt('vibetrail.dirty_files', isObj(tend) && isObj(tend.vcs) ? nz(tend.vcs.dirty_files) : null),
      ...opt('vibetrail.queued_prompts', alt(pt.queued, 0) > 0 ? pt.queued : null), ...opt('vibetrail.turn_kind', pt.kind) };
    const stops = alt(stop ? nz(stop.stops) : null, 0);
    e._key = pt.id + '|turn.end' + (stops > 1 ? '|stop' + String(stops) : '');
    if (eof) emitAlways(e); else emit(e);
    if (isNew) inc(st.ledger.turns.ended, status.code);
    st.pturn.closed = true;
  };

  // ---- K7：人拒绝 还是 按停止打断了正在跑的工具 ----
  const splitStop = (s, tu, tur) => {
    const at = epochms(s.ts);
    if (mountedAt(at)) {
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
      let cls = null;
      if (h.kind === 'permission_denied' && /^The user doesn't want to proceed with this tool use/.test(b.text)
        && !String(alt(tur, '')).startsWith('Error:')) {
        const key = `${s.uuid}|${alt(b.call_id, '')}`;
        if (isObj(splitsPrior[key])) { cls = splitsPrior[key]; splitsReused += 1; }
        else { cls = splitStop(s, tu, tur); splitsNew[key] = cls; }
      }
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
    // K29：沿父记录往上找会越过通知记录一路找进上一轮（上一轮早答完了，那条回复不是被打断的），所以只认本轮开头之后的
    const up = walkUp(s.parentUuid, 200);
    const reply = wholeReply(up !== null && up.ln >= turnStart() ? up : lastAssistantInTurn(s));
    if (reply !== null && reply.text.length > 0) {
      emit(message(s, t, reply, 'message.assistant', 'agent', { 'vibetrail.trigger': s.uuid, 'vibetrail.kind': kind }));
    }
    const stopCalls = (alt(nz(h.stop_calls), [])).filter(isStr);
    if (stopCalls.length > 0) {
      for (const cid of stopCalls) {
        const tu = alt(nz(st.tools[cid]), null);
        if (tu === null) continue;
        emit(toolRequest(s, t, cid, tu, { 'vibetrail.trigger': s.uuid, 'vibetrail.kind': kind }));
        // K21：协议「工具调用中断并导致轮次终止时，tool.end(cancelled) 与 turn.end 各发一条，不能只保留其中一条」。
        // 以前这类（K7 判成按停止的）只补发 tool.request；判成人拒绝的仍不发 tool.end（协议：执行前被拒只发 permission.decision）。
        // _key 仍是 <call_id>|tool.end：之后不会再有真结果（这次调用已经被打断），有也只留一条；耗时只能按记录时间差，标 wall_clock
        const b1 = epochms(s.ts), a1 = epochms(tu.ts);
        const wall = (b1 !== null && a1 !== null && b1 >= a1) ? b1 - a1 : null;
        const te = base(s, 'tool.end', s.uuid, s.ts, t);
        te.payload = { tool_name: alt(tu.name, 'unknown'), call_id: cid,
          status: { code: 'cancelled', category: 'cancellation', detail: 'tool call interrupted by the user (stop pressed while it was running)' },
          ...opt('duration_ms', wall) };
        te.extensions = { ...te.extensions, 'vibetrail.trigger': s.uuid, 'vibetrail.kind': kind, ...(wall !== null ? { 'vibetrail.duration_kind': 'wall_clock' } : {}) };
        te._key = cid + '|tool.end';
        emit(te);
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
    if (!sub && st.pturn !== null && st.pturn.id === t.id) attachFiles(e, st.pturn);   // K22：打断结束的轮也带 files[]
    if (sub) attachFiles(e, agentHolder(s.agent, true));                                // 子 agent 被打断：它自己改过的文件也带上
    const rawData = { ...h }; delete rawData.as_kind; delete rawData.split_by; delete rawData.permission_mode; delete rawData.stop_calls;
    e.raw = { event_name: 'diverge.' + h.kind, data: rawData };
    // K13：打断发的 turn.end 以前不带 closed_by / stops（本机 252 条全空），读的一方连「同 turn_id 取 stops 最大」都用不上
    const hstops = sub ? null : alt(nz(hookStop(hookTurn(t.id))?.stops), 0);
    e.extensions = { ...e.extensions, 'vibetrail.kind': kind, 'vibetrail.human': true,
      ...(sub ? {} : { 'vibetrail.closed_by': 'interrupt', 'vibetrail.stops': hstops }),
      ...(!sub && st.pturn !== null && st.pturn.id === t.id ? opt('vibetrail.turn_kind', st.pturn.kind) : {}),
      ...opt('vibetrail.interrupted_uuid', reply ? reply.uuid : null),
      ...opt('vibetrail.split_by', nz(h.split_by) ?? null), ...opt('vibetrail.permission_mode', nz(h.permission_mode) ?? null) };
    e._key = s.uuid + '|' + e.type;
    emit(e);
    // K13：打断结束的轮也置 closed——否则 state 里 turn_closed 一直是 false，每次 SessionStart 补做都把它重新解析一遍（本机 5 个）
    if (!sub && st.pturn !== null && st.pturn.id === t.id) { st.pturn.interrupted = true; st.pturn.closed = true; }
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
  // K20：模型干活时人插进去的话（queued_command 附件，commandMode prompt、origin 是人）。09-16 全采之后人说的话里只有这一类没发出去。
  // 协议：排队消息用 delivery=queued，「不能把排队消息当成人的实时输入」——所以不算分歧之后的下一句（那要等它真正作为 prompt 提交时的 user 记录）。
  // 正文取附件的 prompt；附件没有 promptId（本机 41 条全没有），轮次按当前轮推。关掉全采时照旧只在 turn.end 上计数
  const emitQueued = (r, s) => {
    const text = nz(r.attachment.prompt);
    if (!isStr(text) || text.length === 0) return;
    const e = base(s, 'message.user', s.uuid, s.ts, turnOf(s));
    e.payload = { text, author_type: 'user', delivery: 'queued' };
    e.content_state = 'included';
    e._key = s.uuid + '|message.user';
    emit(e);
  };

  const turnBoundary = (r, s) => {
    // K12（09-16 复核：turn.end 里 6.4% 是 unknown，106 轮一次模型调用都没有）：以前任何带新 promptId 的 user 记录都开一轮，
    // /compact 后的续接摘要、<task-notification>、只有 tool_result 的记录都被灌成了轮，且与 hook 只在 UserPromptSubmit 发 turn.start 的口径不一致。
    // 现在只在人话或斜杠命令处开轮，别的记录并入当前轮。返回开了哪种轮（human / notification / null），主循环据此把本轮用量清零
    if (!(turns && mainRec(r) && r.type === 'user' && isStr(r.promptId) && r.promptId !== alt(st.pturn ? st.pturn.id : null, null))) return null;
    if (s.human || s.slash) {
      closeTurn('next_turn', s, false);
      openTurn(s);
      return 'human';
    }
    // K29（09-17 用户看 collector 页面发现）：上一轮已经关了（答完标记、Stop、打断）之后才来的 <task-notification>，是后台 agent 跑完、
    // 模型自己接着回复的一轮——以前并进「当前轮」，可当前轮早关了：这一轮的事件挂着通知的 promptId 却没有 turn.start / turn.end（页面上「未知」），
    // 回复花的 token 哪一轮都不算；人按停止打断它时，turn.end 又拿上一轮的累计用量（本机 0dd3c55d 的 347 万记了三份）。
    // 现在单独开一轮、打 vibetrail.turn_kind = notification；上一轮还开着时来的照 K12 并进去
    if ((st.pturn === null || st.pturn.closed) && r.type === 'user'
        && ((isObj(r.origin) && r.origin.kind === 'task-notification') || /^<task-notification>/.test(alt(s.text, '')))) {
      openTurn(s, 'notification');
      return 'notification';
    }
    return null;
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
    // 09-16 起不再挂 StopFailure：API 出错结束一轮时，Claude Code 会写一条 model=<synthetic> 的回复，带 isApiErrorMessage 与
    // error（rate_limit / authentication_failed / server_error…，本机 107 条）。之后又有真回复就说明缓过来了，清掉
    if (r.type === 'assistant' && r.isApiErrorMessage === true) st.pturn.api_error = { error: isStr(r.error) && r.error !== '' ? r.error : 'api_error', status: nz(r.apiErrorStatus) };
    if (s.type === 'assistant' && !s.synthetic) {
      st.pturn.api_error = null;
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
    e.provenance = { kind: 'transcript', rule_version: RULE_VERSIONS.call, source_event_id: c.last_uuid };
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
      // K18：code 与分类用协议推荐值（tool.end：succeeded / failed / cancelled；分类 success / failure / cancellation）。
      // 09-16 以前发的是 success / error，分类 error 云端会归进 other
      const status = b.is_error !== true ? { code: 'succeeded', category: 'success' }
        : /^\[Tool call (did not complete|skipped)/.test(txt) ? { code: 'cancelled', category: 'cancellation' }
        : (isHumanDenial(txt) || isClassifier(txt) || isInfra(txt) || txt.startsWith("The user doesn't want to")) ? null
        : { code: 'failed', category: 'failure' };
      if (status === null) continue;
      // K22：成功的文件工具记进当前轮（主会话）；子 agent 文件里没有轮，记进整份文件的集合，关它的 subagent.end 时带上
      const holder = mainRec(r) ? st.pturn : (s.agent !== null ? st.agent_files : null);
      if (b.is_error !== true && holder !== null && FILE_TOOLS[tu.name] !== undefined && isObj(tu.input)) {
        const p = alt(nz(tu.input.file_path), nz(tu.input.notebook_path));
        // 新建看 toolUseResult.type；子 agent 文件里没有 toolUseResult（09-16 实测），退到结果正文「File created successfully」
        const created = tu.name === 'Write' && (isObj(r.toolUseResult) ? r.toolUseResult.type === 'create' : /^File created successfully/.test(txt));
        noteFile(holder, p, created ? 'create' : FILE_TOOLS[tu.name]);
      }
      const b1 = epochms(s.ts), a1 = epochms(tu.ts);
      const wall = (b1 !== null && a1 !== null && b1 >= a1) ? b1 - a1 : null;
      // K15②（用户 09-16 定）：Claude Code 自己记了耗时的工具（WebSearch 的 durationSeconds、WebFetch 的 durationMs、
      // Agent 的 totalDurationMs）用它，标 reported；别的只能「结果记录时间 − 调用记录时间」，标 wall_clock——
      // 后台工具、续接后才落盘的结果都会把等待算进去（本机最长 64 小时），协议要求推断出来的耗时必须标明。不设阈值。
      // Pilot 不算耗时（只发调用、结果两个时刻），teamai 不记工具耗时。一条记录夹多个工具结果时 toolUseResult 分不清是谁的，只用 wall_clock
      const tres = isObj(r.toolUseResult) && c.filter((x) => isObj(x) && x.type === 'tool_result').length === 1 ? r.toolUseResult : null;
      const rep = !tres ? null : typeof tres.durationMs === 'number' ? tres.durationMs
        : typeof tres.durationSeconds === 'number' ? tres.durationSeconds * 1000
        : typeof tres.totalDurationMs === 'number' ? tres.totalDurationMs : null;
      const d = rep !== null && rep >= 0 ? Math.round(rep) : wall;
      const dkind = rep !== null && rep >= 0 ? 'reported' : wall !== null ? 'wall_clock' : null;
      const t = { id: alt(st.turn, s.uuid), inferred: st.turn === null };
      const e = base(s, 'tool.end', s.uuid, s.ts, t);
      e.content_state = capContent ? 'included' : 'omitted';
      e.payload = { tool_name: tu.name, call_id: cid, status, ...opt('duration_ms', d),
        ...(capContent ? opt('output', alt(nz(b.content), alt(nz(b.output), alt(nz(b.result), null)))) : {}) };
      e.provenance = { kind: 'transcript', rule_version: RULE_VERSIONS.call, source_event_id: s.uuid };
      if (dkind) e.extensions = { ...e.extensions, 'vibetrail.duration_kind': dkind };
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
    e.provenance = { kind: 'transcript', rule_version: RULE_VERSIONS.call, source_event: 'api_error', source_event_id: s.uuid };
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
        e.provenance = { kind: 'transcript', rule_version: RULE_VERSIONS.call, source_event_id: s.uuid };
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
    e.provenance = { kind: 'transcript', rule_version: RULE_VERSIONS.call, source_event: 'prompt_snapshot', source_event_id: s.uuid };
    e.extensions = { ...e.extensions, 'vibetrail.system_prompt': text };
    e._key = 'ext|prompt_snapshot|' + sha.slice(0, 16);
    emit(e);
  };

  // ---- 09-16 起不再单独挂 hook 的几类：改从 transcript 推（用户 09-16 定只留 5 个 hook） ----
  // 这个会话里已知的子 agent：{agentId: {call_id, agent_type}}，调用方从 subagents/*.meta.json 与 state 里记下的后台启动凑出来
  const knownAgents = {};
  if (isArr(known_agents)) { for (const a of known_agents) if (isStr(a)) knownAgents[a] = {}; }
  else if (isObj(known_agents)) { for (const [k, v] of Object.entries(known_agents)) knownAgents[k] = isObj(v) ? v : {}; }
  const agentByCall = {};
  for (const [aid, v] of Object.entries(knownAgents)) if (isStr(v.call_id)) agentByCall[v.call_id] = aid;
  const agentKnown = (aid) => knownAgents[aid] !== undefined || st.agents.launched[aid] !== undefined;
  const agentTypeOf = (aid, cid) => {
    const k = alt(nz(st.agents.launched[aid]), alt(nz(knownAgents[aid]), {}));
    if (isStr(k.agent_type) && k.agent_type !== '') return k.agent_type;
    const tu = isStr(cid) ? nz(st.tools[cid]) : null;
    if (tu && isObj(tu.input) && isStr(tu.input.subagent_type) && tu.input.subagent_type !== '') return tu.input.subagent_type;
    return tu && (tu.name === 'Agent' || tu.name === 'Task') ? 'general-purpose' : 'unknown';   // Agent 工具不给 subagent_type 时 Claude Code 用 general-purpose
  };
  const markDone = (m, k, ts) => { if (isStr(k) && isStr(ts)) m[k] = jqMax([nz(m[k]), ts]); };
  const agentEndStatus = (v) => {
    const x = String(alt(v, 'completed'));
    if (x === 'completed') return { code: 'completed', category: 'success' };
    if (x === 'unknown') return { code: 'unknown', category: 'unknown' };
    if (/^(stopped|killed|cancelled|canceled|interrupted|aborted)$/.test(x)) return { code: codeify(x), category: 'cancellation' };
    return { code: codeify(x), category: 'failure' };   // K18：failed 等是 failure，不是 error
  };
  // 与原先 SubagentStart / SubagentStop hook 发的 _key 相同（<agentId>|subagent.start / end）：同一个 agent 只算一条，哪一路先到用哪一路
  const agentStart = (s, aid, parent, agentType, callId, task, ext = null) => {
    const e = base(s, 'subagent.start', s.uuid, s.ts, turnOf(s));
    e.agent_instance_id = aid;
    e.parent_agent_instance_id = parent;
    delete e.parent_call_id; if (isStr(callId)) e.parent_call_id = callId;
    // K23：协议把 payload.task 算正文，content_state=omitted 时必须缺失——只在全采时带，关掉时不带、标 omitted
    const withTask = capContent && isStr(task) && task !== '';
    e.payload = { agent_type: agentType, ...(withTask ? { task } : {}) };
    e.content_state = capContent ? 'included' : 'omitted';
    e.provenance = { kind: 'transcript', rule_version: RULE_VERSIONS.turn, source_event_id: s.uuid };
    if (isObj(ext)) e.extensions = { ...e.extensions, ...ext };
    e._key = `${aid}|subagent.start`;
    emit(e);
  };
  const agentEnd = (s, aid, status, agentType, callId, lastMessage, facts, ext = null) => {
    const e = base(s, 'subagent.end', s.uuid, s.ts, turnOf(s));
    e.agent_instance_id = aid;
    e.parent_agent_instance_id = alt(s.agent, 'main');             // 收到完成信号的这份文件就是父实例
    delete e.parent_call_id; if (isStr(callId)) e.parent_call_id = callId;
    const withMsg = capContent && isStr(lastMessage) && lastMessage.length > 0;
    e.payload = { agent_type: agentType, status: agentEndStatus(status), ...(withMsg ? { last_message: lastMessage } : {}) };
    if (withMsg) e.content_state = 'included';
    e.provenance = { kind: 'transcript', rule_version: RULE_VERSIONS.turn, source_event_id: s.uuid };
    if (isObj(facts) && Object.keys(facts).length > 0) e.extensions = { ...e.extensions, 'vibetrail.agent': facts };
    if (isObj(ext)) e.extensions = { ...e.extensions, ...ext };
    // K22 子 agent 部分：它自己改 / 读的文件——调用方先映射子 agent 文件、把集合存进 agents.json，再映射父文件时经 known_agents 传进来。
    // 同时并进收到结束信号的这一轮（主会话）或父 agent 的集合（子 agent 文件），「这一轮改了哪些文件」才包括子 agent 改的
    const h = agentHolder(aid, false);
    attachFiles(e, h);
    const target = s.agent === null ? (st.pturn !== null && !st.pturn.closed ? st.pturn : null) : st.agent_files;
    if (target !== null) {
      target.files = mergeFiles(target.files, h.files);
      target.files_outside = alt(nz(target.files_outside), 0) + h.files_outside;
    }
    e._key = `${aid}|subagent.end`;
    emit(e);
    // 完成信号的时间：子 agent 文件最后一条不晚于它，才算写完（SendMessage 续上的 agent 之后还会往文件里写，要等下一个信号）
    markDone(st.agents.done, aid, s.ts);
    markDone(st.agents.calls_done, callId, s.ts);
  };
  const textOfBlocks = (v) => (isStr(v) ? v : isArr(v) ? v.filter(isObj).filter((b) => b.type === 'text').map((b) => alt(nz(b.text), '')).join('\n') : '');
  const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
  // K11（09-16 用 Workflow 实测）：workflow 起的 agent 在 <sid>/subagents/workflows/<runId>/ 下，meta 里没有 toolUseId，
  // 与主会话只靠两处挂上：Workflow 调用的启动结果（toolUseResult.taskType = local_workflow，带 runId、taskId）与之后的 <task-notification>（task-id 是 taskId）。
  // 每个 agent 跑完没跑完看同目录的 journal.jsonl（调用方读好，经 workflow_runs 传进来：{runId: {task_id, call_id, agents: {agentId: {status, result, label, phase}}}}）
  const runs = isObj(workflow_runs) ? workflow_runs : {};
  const runByTask = (taskId) => {
    for (const [rid, run] of Object.entries(runs)) {
      const known = isObj(st.agents.workflows[rid]) ? st.agents.workflows[rid] : {};
      if (isObj(run) && (run.task_id === taskId || known.task_id === taskId)) return { rid, run, call_id: alt(nz(known.call_id), nz(run.call_id)) };
    }
    return null;
  };
  const subagentSignals = (r, s) => {
    // 起（同步派出的）：子 agent 文件的第一条记录；类型、任务描述、派它的调用取同名 meta.json（workflow 的 agent 由调用方补上 toolUseId 与 workflowRunId）
    if (s.agent !== null && !st.agent_started && start_line === 1) {
      st.agent_started = true;
      const wf = isObj(meta) && isStr(meta.workflowRunId) ? { 'vibetrail.workflow': { run_id: meta.workflowRunId, ...opt('phase', nz(meta.workflowPhase)) } } : null;
      agentStart(s, s.agent, parent_instance, alt(isObj(meta) && isStr(meta.agentType) && meta.agentType !== '' ? meta.agentType : null, 'unknown'),
        isObj(meta) ? nz(meta.toolUseId) : null, isObj(meta) ? nz(meta.description) : null, wf);
    }
    const results = r.type === 'user' && isArr(msgOf(r).content) ? msgOf(r).content.filter((b) => isObj(b) && b.type === 'tool_result') : [];
    const tres = isObj(r.toolUseResult) ? r.toolUseResult : null;
    const one = results.length === 1 ? results[0] : null;
    const launched = tres && (tres.isAsync === true || tres.status === 'async_launched');
    // workflow 的启动结果：记下 runId → 派它的调用、taskId（存进 agents.json，之后的通知与 workflow agent 文件都靠它挂回来）
    if (one && tres && tres.taskType === 'local_workflow' && isStr(tres.runId)) {
      st.agents.workflows[tres.runId] = { ...opt('call_id', nz(one.tool_use_id)), ...opt('task_id', nz(tres.taskId)) };
    }
    // 起（后台派出的）：调用结果当场返回 isAsync + agentId。本机 265 次后台 agent 没有自己的 transcript 文件，只能从这里知道它起了；
    // 记进账本，调用方存进 state，之后的 <task-notification> 靠它认出是子 agent
    if (one && launched && isStr(tres.agentId)) {
      const cid = nz(one.tool_use_id);
      const atype = agentTypeOf(tres.agentId, cid);
      st.agents.launched[tres.agentId] = { ...opt('call_id', cid), agent_type: atype };
      const tu = isStr(cid) ? nz(st.tools[cid]) : null;
      agentStart(s, tres.agentId, alt(s.agent, 'main'), atype, cid, alt(nz(tres.description), tu && isObj(tu.input) ? nz(tu.input.description) : null));
    }
    // 止（同步的）：调用结果里有 agentId、status、耗时、token
    if (one && tres && !launched && isStr(tres.agentId)) {
      const facts = { ...opt('duration_ms', num(tres.totalDurationMs)), ...opt('total_tokens', num(tres.totalTokens)), ...opt('tool_use_count', num(tres.totalToolUseCount)) };
      const cid = nz(one.tool_use_id);
      agentEnd(s, tres.agentId, tres.status, alt(isStr(tres.agentType) && tres.agentType !== '' ? tres.agentType : null, agentTypeOf(tres.agentId, cid)),
        cid, textOfBlocks(tres.content), facts);
    }
    // 按 meta 里的 toolUseId 认结束：同步的 agent 出错（本机 15 次）拿不到 agentId；子 agent 文件里整个没有 toolUseResult（09-16 实测：
    // 被子 agent 派出的同步 agent，结束只有一条 tool_result），以前这两种都不发 subagent.end。meta 有 toolUseId 就说明这个 agent 真的起过，
    // 调用结果就是它的结束：出错是 failed（正文像打断 / 取消的算 cancelled），否则 completed；主会话里带 toolUseResult.agentId 的上面已经发过
    for (const b of results) {
      const cid = nz(b.tool_use_id);
      if (!isStr(cid) || agentByCall[cid] === undefined) continue;
      const txt = errText(b.content);
      if ((launched && one === b) || /^Async agent launched/.test(txt)) continue;   // 后台派出的：结束看之后的 <task-notification>
      markDone(st.agents.calls_done, cid, s.ts);
      if (tres && isStr(tres.agentId) && one === b) continue;
      const aid = agentByCall[cid];
      const status = b.is_error !== true ? 'completed' : /interrupt|cancel|abort|stopped|killed/i.test(txt) ? 'cancelled' : 'failed';
      agentEnd(s, aid, status, agentTypeOf(aid, cid), cid, b.is_error !== true ? textOfBlocks(b.content) : null, {});
    }
    // 止（后台的）：<task-notification>，<task-id> 就是 agentId（偶尔一条带几个），<status> completed / failed / killed / stopped。
    // 两种形态：模型空闲时是 origin.kind = task-notification 的 user 记录，忙时是 queued_command 附件（本机 511 条，只 33 个两边都有）
    const notif = r.type === 'user' && isObj(r.origin) && r.origin.kind === 'task-notification' ? anyText(r).join('\n')
      : (r.type === 'attachment' && isObj(r.attachment) && r.attachment.type === 'queued_command'
        && r.attachment.commandMode === 'task-notification' && isStr(r.attachment.prompt)) ? r.attachment.prompt : null;
    if (notif !== null) {
      const ids = [...notif.matchAll(/<task-id>\s*([^<\s]+)\s*<\/task-id>/g)].map((m) => m[1]);
      const status = notif.match(/<status>\s*([^<\s]+)\s*<\/status>/)?.[1] ?? null;
      if (status !== null) {
        const callId = notif.match(/<tool-use-id>\s*([^<\s]+)\s*<\/tool-use-id>/)?.[1] ?? null;
        const result = notif.match(/<result>([\s\S]*?)<\/result>/)?.[1]?.trim() ?? null;
        const usage = notif.match(/<usage>([\s\S]*?)<\/usage>/)?.[1] ?? '';
        const tag = (n) => { const m = usage.match(new RegExp(`<${n}>\\s*(\\d+)\\s*</${n}>`)); return m ? Number(m[1]) : null; };
        for (const aid of ids) {
          // 后台 shell 任务、监视器也发这种通知：只认子 agent（有它的 meta / 文件，或记下过它的后台启动）与 workflow（task-id 是它的 taskId）
          if (!agentKnown(aid)) {
            const w = runByTask(aid);
            if (w === null) continue;
            // workflow 跑完：给这次 run 里跑完的每个 agent 发 subagent.end，父实例是主会话、派它的调用是那次 Workflow 调用
            for (const [wa, info] of Object.entries(isObj(w.run.agents) ? w.run.agents : {})) {
              if (!isObj(info) || !isStr(info.status)) continue;
              agentEnd(s, wa, info.status, alt(isStr(info.agent_type) && info.agent_type !== '' ? info.agent_type : null, 'workflow-subagent'),
                alt(callId, w.call_id), info.status === 'completed' && isStr(info.result) ? info.result : null, {},
                { 'vibetrail.workflow': { run_id: w.rid, ...opt('phase', nz(info.phase)), ...opt('label', nz(info.label)) } });
            }
            continue;
          }
          const k = alt(nz(st.agents.launched[aid]), alt(nz(knownAgents[aid]), {}));
          const cid = ids.length === 1 ? alt(callId, nz(k.call_id)) : nz(k.call_id);
          const facts = ids.length === 1 ? { ...opt('duration_ms', tag('duration_ms')), ...opt('total_tokens', alt(tag('subagent_tokens'), tag('total_tokens'))), ...opt('tool_use_count', tag('tool_uses')) } : {};
          agentEnd(s, aid, status, agentTypeOf(aid, cid), cid, ids.length === 1 ? result : null, facts);
        }
      }
    }
  };
  // 切目录：相邻两条记录的 cwd 不同（本机 21 份文件里 326 次）。目录按「不出本机」的写法（工作区内相对、根外 ~ 形）
  const cwdChange = (r, s) => {
    if (!isStr(r.cwd)) return;
    if (st.last_cwd !== null && r.cwd !== st.last_cwd) {
      const e = base(s, 'ext.claude.cwd_changed', s.uuid, s.ts, turnOf(s));
      e.payload = { old_cwd: safeDir(st.last_cwd), new_cwd: safeDir(r.cwd) };
      e.provenance = { kind: 'transcript', rule_version: RULE_VERSIONS.ext, source_event: 'cwd', source_event_id: s.uuid };
      e._key = `${s.uuid}|cwd_changed`;
      emit(e);
    }
    st.last_cwd = r.cwd;
  };
  // CLAUDE.md 加载：attachment/instructions 带 files[{path, type, content}] 与 reason（session_start / compaction），比原先的 hook 还全
  const instructionsLoaded = (r, s) => {
    if (!(r.type === 'attachment' && isObj(r.attachment))) return;
    const at = r.attachment;
    // 读到子目录里的文件时顺带加载的 CLAUDE.md 是 nested_memory（本机 7 条，content 是 {path, type, content}）
    const nested = at.type === 'nested_memory' && isObj(at.content);
    if (!(at.type === 'instructions' || nested)) return;
    const files = nested ? [{ path: alt(nz(at.content.path), nz(at.path)), type: nz(at.content.type), content: nz(at.content.content) }]
      : (isArr(at.files) ? at.files : []).filter(isObj);
    const e = base(s, 'ext.claude.instructions_loaded', s.uuid, s.ts, turnOf(s));
    // 路径按「不出本机」的写法：仓里的 CLAUDE.md 相对工作区根，~/.claude/ 下的换成 ~ 形
    e.payload = {
      files: files.map((f) => ({ ...opt('path', safeFile(nz(f.path))), ...opt('type', nz(f.type)),
        ...(isStr(f.content) ? { bytes: Buffer.byteLength(f.content, 'utf8'), sha256: crypto.createHash('sha256').update(f.content, 'utf8').digest('hex') } : {}) })),
      ...opt('reason', nested ? 'nested_traversal' : nz(at.reason)), ...(at.changed === true ? { changed: true } : {}),
      ...opt('removed', isArr(at.removed) ? at.removed.map((x) => safeFile(x)) : null),
    };
    if (capContent) {
      e.content_state = 'included';
      e.extensions = { ...e.extensions, 'vibetrail.instructions': files.filter((f) => isStr(f.content)).map((f) => ({ path: safeFile(nz(f.path)), content: f.content })) };
    }
    e.provenance = { kind: 'transcript', rule_version: RULE_VERSIONS.ext, source_event: 'instructions', source_event_id: s.uuid };
    e._key = `${s.uuid}|instructions_loaded`;
    emit(e);
  };

  // ---- 一条记录 ----
  const step = (r) => {
    st.out = [];
    st.ln += 1;
    const ln = st.ln;
    const isNew = ln > from_line;
    const NEW = st.ledger.new;
    if (r === BLANK_LINE) return;
    if (isNew) NEW.seen += 1;
    if (r === BAD_LINE) { st.ledger.bad_json += 1; if (isNew) NEW.bad_json += 1; return; }
    if (!isObj(r)) { st.ledger.skipped_non_object += 1; if (isNew) NEW.skipped_non_object += 1; return; }
    // A11：清单之外的记录类型 / 附件类型 / system 子类型只计数（doctor 告警），照常往下走
    if (isNew) {
      const ty = nz(r.type);
      if (!KNOWN_TYPES.has(ty)) inc(NEW.unknown_types, 'type:' + String(ty));
      else if (ty === 'attachment') { const a = isObj(r.attachment) ? nz(r.attachment.type) : null; if (!KNOWN_ATTACHMENTS.has(a)) inc(NEW.unknown_types, 'attachment:' + String(a)); }
      else if (ty === 'system') { const sb = nz(r.subtype); if (!KNOWN_SYSTEM.has(sb)) inc(NEW.unknown_types, 'system:' + String(sb)); }
    }
    if (!isStr(r.uuid)) { st.ledger.skipped_no_uuid += 1; if (isNew) NEW.skipped_no_uuid += 1; return; }
    const s = slim(r, ln);
    const hits = diverge(r);
    if (st.run_uuids[r.uuid] || (st.prior[r.uuid] !== undefined && st.prior[r.uuid] !== ln)) { st.ledger.replayed += 1; if (isNew) NEW.replayed += 1; return; }
    // K8（🔴，09-16 复核：本机 7.6% 的事件落在复制来的轮上，trace 与 token 在云端算两遍）：desktop 续接会话会把旧会话的开头
    // 原样复制进新文件，记录 uuid、promptId 都不变、只有文件换了——但每条记录的 sessionId 字段仍是原会话的。
    // 所以「记录 sessionId 与文件 sid 不同」就是复制来的历史，整条跳过、账本记 inherited；它在原会话的文件里已经报过。
    // 子 agent 文件里 sessionId 是父会话 id、与 sid 一致，不受影响；没有 sessionId 的记录（老版本）照常处理
    if (sid && isStr(r.sessionId) && r.sessionId !== sid) { st.ledger.inherited += 1; if (isNew) NEW.inherited += 1; return; }
    st.run_uuids[r.uuid] = true;
    st.ledger.records += 1;
    if (isNew) NEW.records += 1;
    if (s.agent !== null && st.agent_id === null) st.agent_id = s.agent;
    st.last_ts = alt(nz(r.timestamp), st.last_ts);
    st.version = alt(nz(r.version), st.version);
    st.entrypoint = alt(nz(r.entrypoint), st.entrypoint);
    st.branch = alt(nz(r.gitBranch), st.branch);
    if (isStr(r.promptId) && r.promptId !== st.turn) { st.turn = r.promptId; st.denials = []; st.stops = []; }
    if ((s.human || s.slash) && isStr(r.permissionMode)) st.perm_mode = r.permissionMode;
    const opened = turnBoundary(r, s);
    index(s);
    if (s.human || opened === 'notification') { st.turn_usage = {}; st.turn_model = null; st.turn_line = s.ln; }
    if (s.type === 'assistant' && s.usage !== null && !s.synthetic) {
      const uk = alt(s.mid, alt(s.rid, s.uuid));
      const cur = st.turn_usage[uk];
      if (!(alt(cur ? nz(cur.output_tokens) : null, -1) > alt(nz(s.usage.output_tokens), 0))) st.turn_usage[uk] = s.usage;
      st.turn_model = alt(s.model, st.turn_model);
    }
    turnAccumulate(r, s);
    turnStopMarker(r, s);
    promptSnapshot(r, s);
    if (turns) { traceStep(r, s); subagentSignals(r, s); cwdChange(r, s); instructionsLoaded(r, s); }
    if (ln > from_line) st.ledger.sources.push([s.uuid, ln]);
    if (isStr(r.toolUseResult) && r.toolUseResult.startsWith('User rejected tool use')) {
      st.ledger.sentinel.marker += 1;
      if (isNew) NEW.sentinel.marker += 1;
      if (!hits.some((h) => h.kind === 'permission_denied')) { st.ledger.sentinel.marker_without_hit += 1; if (isNew) NEW.sentinel.marker_without_hit += 1; }
    }
    for (const h of hits) handle(r, s, h);
    if (s.human || s.slash) {
      if (st.pending !== null) emitAfter(s);
      else if (capContent) emitPrompt(s);
    } else if (capContent && mainRec(r) && isQueuedHuman(r)) emitQueued(r, s);
  };

  const checkpoint = () => {
    const c = baseCheckpoint();
    return st.call !== null ? jqMin([c, st.call.ck]) : c;
  };

  const atEof = () => {
    st.out = [];
    // if_done：子 agent 文件。09-16 起不挂 SubagentStop，「写完了」改由父文件里的完成信号判：
    // 信号的时间不早于这份文件最后一条记录才把最后一次调用写出（SendMessage 续上的 agent 之后还会写，要等下一个信号）
    const flush = close_last === 'if_done' ? (isStr(done_ts) && isStr(st.last_ts) && done_ts >= st.last_ts) : close_last !== '';
    if (turns && st.call !== null && flush) flushCall(true);
    if (close_last === '' || close_last === 'if_done' || st.pturn === null) return;
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
    trace: { call_open: st.call !== null }, last_ts: st.last_ts,
    split_decisions_new: splitsNew, split_reused: splitsReused, agents: st.agents,
    // 子 agent 文件自己改 / 读的文件（整份文件；每次都从头读所以是全集，调用方按最重操作并进 agents.json）
    ...(st.agent_id !== null ? { agent_files: { [st.agent_id]: st.agent_files.files }, agent_files_outside: { [st.agent_id]: st.agent_files.files_outside } } : {}) };
  return { events, ledger };
}
