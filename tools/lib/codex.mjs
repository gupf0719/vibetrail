// vibetrail：Codex 的采集（TODO G12）。hooks.json 里挂的是 `vibetrail-hook codex <事件>`。
//
// Codex 的会话记录（rollout，~/.codex/sessions/年/月/日/rollout-<时间>-<thread id>.jsonl）与 Claude 的 transcript 完全不是一种东西：
// 每行 {timestamp, type, payload}，type 是 session_meta / turn_context / response_item / event_msg / token_usage_record / world_state / compacted。
// 轮次起止与打断是类型化记录（event_msg 的 task_started / task_complete / turn_aborted），每次模型响应一条 token_usage_record——都不用匹配字符串。
// 依据：Codex 源码 536f86e（08-21）与本机桌面版 0.154 的两份会话记录（09-16）。**打断、拒绝、子 agent 还没有真实样本**，
// 相关判定标着「待实测」（G12 §4），拿到样本后按实况改、升 RULE。
import fs from 'node:fs';
import path from 'node:path';
import { VT_HOME, vtConf, vtGitSnapshot, vtLock, vtUnlock, vtFprint, vtWriteJson, vtBackfillCutoffMs } from './hook.mjs';
import { displayDir } from './map.mjs';
import {
  readText, readJson, isFile, isDir, mkdirp, nowIso, epochSec, isObj, opt, sha256, capture, validSid, sleepSync, codeify, agentEnabled,
  gate, baseEvent, emit, vcsOf, commitsOf, turnStart, turnStop, turnGap, turnEvidence, relFile, noteFile, filesOf,
  detach, hookCommand, isOurs, readHostJson, writeHostJson, sameJson, writeTextGuarded,
} from './agents.mjs';

export const RULE = 'codex-v5';                          // v2（09-17）：拒绝只认整条输出；v3：弹框证据按时间窗、一对一配拒绝，轮结束后到来的记录不挂上去；
                                                         // v4（同日，照 Pilot）：跳过子 agent / fork 文件里抄来的父会话历史、子 agent 补 parent_call_id、认两种搜索调用；
                                                         // v5（同日）：自动审批（auto_review）下被拒不判人拒，guardian 审批线程不采
export const CODEX_EVENTS = ['SessionStart', 'UserPromptSubmit', 'Stop', 'SessionEnd', 'PermissionRequest'];
// 超时与 async 定死不改：Codex 按整组配置算信任哈希，改一个字就要人重新信任（G12 §3 问题 1）
// SessionEnd 最多 3 秒（hooks/src/events/session_end.rs:23，超了 Codex 在设置里报「clamping SessionEnd hook timeout to 3s」，用户 09-17 截图）
const TIMEOUT = { SessionStart: 10, UserPromptSubmit: 10, Stop: 120, SessionEnd: 3, PermissionRequest: 30 };
const SYNC = new Set(['SessionStart', 'UserPromptSubmit', 'SessionEnd', 'PermissionRequest']);
const LABEL = { SessionStart: 'session_start', UserPromptSubmit: 'user_prompt_submit', Stop: 'stop', SessionEnd: 'session_end', PermissionRequest: 'permission_request' };
const CAPS = ['session.start', 'session.end', 'turn.start', 'turn.end', 'message.user', 'message.assistant', 'tool.request', 'tool.end',
  'permission.decision', 'subagent.start', 'subagent.end', 'usage', 'vcs', 'file.relation', 'ext.codex'];
const MAX_READ = () => (Number(process.env.VIBETRAIL_READ_MAX_BYTES) > 0 ? Number(process.env.VIBETRAIL_READ_MAX_BYTES) : 50 * 1024 * 1024);

export const codexHome = () => process.env.VIBETRAIL_CODEX_HOME || process.env.CODEX_HOME || path.join(process.env.HOME || '', '.codex');
export const codexPresent = () => isDir(codexHome());
const hooksFile = () => path.join(codexHome(), 'hooks.json');

// 桌面版的 originator 是「Codex Desktop」，source 却写 vscode（本机实测），所以 surface 只看 originator
export const surfaceOf = (originator) => {
  const o = String(originator ?? '').toLowerCase();
  if (o.includes('desktop')) return 'desktop';
  if (/vscode|jetbrains|ide/.test(o)) return 'ide';
  if (/cli|exec|tui/.test(o)) return 'cli';
  return null;
};

// ---------- 读 rollout ----------
const UUID_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;
const sidOfPath = (file) => { const m = path.basename(String(file)).match(/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/i); return m ? m[1].toLowerCase() : null; };
// 这份文件自己的 session_meta（codex-v4）：子 agent 与 fork 出来的会话，文件开头是自己的 session_meta、再抄一条父会话的、再抄父会话的历史
// （Pilot 照桌面版多 agent 的真实记录做的夹具与 selectOwnerSessionMetaOffset）。开头连续的几条 session_meta 里取 id 等于文件名线程 id 的那条
export function metaOf(file) {
  const want = sidOfPath(file);
  let first = null;
  try {
    const fd = fs.openSync(file, 'r');
    const buf = Buffer.alloc(2 * 1024 * 1024);
    const n = fs.readSync(fd, buf, 0, buf.length, 0);
    fs.closeSync(fd);
    let pos = 0;
    for (let i = 0; i < 16 && pos < n; i++) {
      const nl = buf.indexOf(0x0a, pos);
      if (nl < 0 || nl >= n) break;
      let r; try { r = JSON.parse(buf.subarray(pos, nl).toString('utf8')); } catch { break; }
      pos = nl + 1;
      if (!isObj(r) || r.type !== 'session_meta' || !isObj(r.payload)) break;
      const p = { ...r.payload, timestamp: r.payload.timestamp ?? r.timestamp };
      if (!first) first = p;
      if (!want || String(p.id ?? p.session_id ?? '').toLowerCase() === want) return p;
    }
  } catch {}
  return first;
}
// guardian 自动审批线程：thread_source = guardian_review，source = {subagent: {other: "guardian"}}（09-17 本机桌面版实测）
const isGuardian = (m) => isObj(m) && (String(m.thread_source ?? '').toLowerCase() === 'guardian_review'
  || String(isObj(m.source) && isObj(m.source.subagent) ? m.source.subagent.other ?? '' : '').toLowerCase() === 'guardian');
// 会抄父会话历史的文件：fork 出来的（forked_from_id）、子 agent（source 是 subagent 或 thread_source 是 subagent）
const copiesHistory = (m) => isObj(m) && Boolean(m.forked_from_id || spawnOf(m) || String(m.thread_source ?? '').toLowerCase() === 'subagent');
// Codex 的 turn id 是 UUIDv7，前 48 位是创建时刻（毫秒）
const uuidV7Ms = (id) => { const m = String(id).match(/^([0-9a-f]{8})-([0-9a-f]{4})-7[0-9a-f]{3}-/i); return m ? parseInt(m[1] + m[2], 16) : null; };
// SessionSource::SubAgent(ThreadSpawn{parent_thread_id, depth, agent_path, agent_nickname, agent_role})；序列化后的键名待实测，几种写法都认
export const spawnOf = (meta) => {
  const s = meta?.source;
  if (!isObj(s)) return null;
  const sub = s.subagent ?? s.sub_agent ?? s.subAgent;
  const t = isObj(sub) ? (sub.thread_spawn ?? sub.threadSpawn) : null;
  return isObj(t) && t.parent_thread_id ? t : null;
};
const compactMeta = (m) => (isObj(m) ? {
  ...opt('id', m.id ?? m.session_id), ...opt('cwd', m.cwd), ...opt('originator', m.originator), ...opt('cli_version', m.cli_version),
  ...opt('history_mode', m.history_mode), ...(m.source !== undefined ? { source: m.source } : {}),
  ...opt('timestamp', m.timestamp), ...opt('forked_from_id', m.forked_from_id), ...opt('thread_source', m.thread_source),
} : null);

// 从 from 读到最后一个换行符，分段读完、不丢最老的一段（U18，用户 09-17 定，同 hook.mjs）；每段不超过 VIBETRAIL_READ_MAX_BYTES（默认 50 MB）
function readSlice(file, from) {
  const size = fs.statSync(file).size;
  const lines = [];
  let pos = from, carry = Buffer.alloc(0);
  const fd = fs.openSync(file, 'r');
  try {
    while (pos < size) {
      const n = Math.min(MAX_READ(), size - pos);
      const chunk = Buffer.alloc(n);
      fs.readSync(fd, chunk, 0, n, pos);
      const buf = carry.length ? Buffer.concat([carry, chunk]) : chunk;
      const base = pos - carry.length;
      const last = buf.lastIndexOf(0x0a);
      let p = 0;
      while (p <= last) {
        const nl = buf.indexOf(0x0a, p);
        lines.push({ off: base + p, raw: buf.subarray(p, nl).toString('utf8') });
        p = nl + 1;
      }
      carry = buf.subarray(p);                          // 半行留到下一段接上；读到头还是半行就不算读过
      pos += n;
    }
  } finally { fs.closeSync(fd); }
  return { lines, end: Math.max(from, size - carry.length) };
}
const tailText = (file, n) => {
  try {
    const size = fs.statSync(file).size, off = Math.max(0, size - n);
    const buf = Buffer.alloc(size - off);
    const fd = fs.openSync(file, 'r'); fs.readSync(fd, buf, 0, buf.length, off); fs.closeSync(fd);
    return buf.toString('utf8');
  } catch { return ''; }
};

// ---------- 取值 ----------
const num = (x) => (typeof x === 'number' && Number.isFinite(x) && x >= 0 ? Math.round(x) : null);
// Codex 的 TokenUsage：cached_input 是 input 的子集（protocol.rs 的 non_cached_input = input − cached），与协议口径一致，直接映射；total = input + output
export function usageOf(u) {
  if (!isObj(u)) return null;
  const input = num(u.input_tokens), output = num(u.output_tokens);
  const o = { ...opt('input_tokens', input), ...opt('cached_input_tokens', num(u.cached_input_tokens)),
    ...opt('output_tokens', output), ...opt('reasoning_tokens', num(u.reasoning_output_tokens)) };
  if (input !== null && output !== null) o.total_tokens = input + output;
  return Object.keys(o).length ? o : null;
}
const addUsage = (a, u) => {
  if (!isObj(u)) return a;
  const out = { ...(a ?? {}) };
  for (const k of ['input_tokens', 'cached_input_tokens', 'output_tokens', 'reasoning_output_tokens']) if (num(u[k]) !== null) out[k] = (out[k] ?? 0) + num(u[k]);
  return out;
};
const textOf = (content) => {                          // response_item 的 content[] 与 UserMessage 的 content[] 里的文字
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content.filter(isObj).map((c) => (typeof c.text === 'string' ? c.text : '')).filter(Boolean).join('\n');
};
const outputText = (o) => {
  if (typeof o === 'string') return o;
  if (isObj(o)) {
    if (typeof o.content === 'string') return o.content;
    if (Array.isArray(o.content)) return textOf(o.content);
    if (typeof o.output === 'string') return o.output;
  }
  if (Array.isArray(o)) return textOf(o);
  return o === undefined || o === null ? '' : JSON.stringify(o);
};
const parseArgs = (a) => { if (typeof a !== 'string') return a ?? null; try { return JSON.parse(a); } catch { return a; } };
const durationMs = (d) => {
  if (typeof d === 'number' && Number.isFinite(d) && d >= 0) return d;
  if (isObj(d) && typeof d.secs === 'number') return d.secs * 1000 + Math.floor((d.nanos ?? 0) / 1e6);
  return null;
};
// apply_patch 的补丁头：*** Add File / Update File / Delete File / Move to
export function patchFiles(name, input) {
  const txt = typeof input === 'string' ? input : isObj(input) ? String(input.input ?? input.patch ?? '') : '';
  if (!/apply_patch/.test(String(name)) && !txt.includes('*** Begin Patch')) return [];
  const out = [];
  for (const m of txt.matchAll(/^\*\*\* (Add|Update|Delete) File: (.+)$/gm)) out.push([m[2].trim(), m[1] === 'Add' ? 'create' : m[1] === 'Delete' ? 'delete' : 'modify']);
  for (const m of txt.matchAll(/^\*\*\* Move to: (.+)$/gm)) out.push([m[1].trim(), 'create']);
  return out;
}

// 拒绝（G12 §3 问题 2）：审批请求不落 rollout，只有输出文字与 paginated 下 CommandExecution / FileChange 的 declined；
// 源码自己说一部分非用户的失败也走这条（core/src/tools/events.rs:436-441），所以人拒还要这一轮有 PermissionRequest hook 的证据
// 只认「整条输出就是这句话」（codex-v2）。09-17 桌面版实测：模型 sed 读 vibetrail 自己的源码，输出里夹着这串字，
// v1 在整段输出里搜，判成了策略拒绝、这次成功调用的 tool.end 也丢了——正是 diverge-v1「只读字段、不 grep 原文」的老坑
const REJECTED = /^(exec command rejected by user|patch rejected by user|rejected by user)$/i;
const POLICY = /^[^\n]{1,200}; rejected by user approval settings$/i;   // core/src/safety.rs 的两句
const PERM_SLACK_MS = 2000;                            // 弹框证据的时间窗前后各放 2 秒（hook 进程的时刻与 Codex 写记录的时刻有抖动）
const TURN_STATUS = {
  completed: { code: 'completed', category: 'success' },
  interrupted: { code: 'interrupted', category: 'cancellation' },
  replaced: { code: 'replaced', category: 'cancellation' },
  review_ended: { code: 'review_ended', category: 'success' },
  budget_limited: { code: 'budget_limited', category: 'failure' },
};

// ---------- 映射：一段 rollout 记录 → 协议事件 ----------
// o: { sid（事件与 state 的会话 id；子 agent 用根会话的）, ctx, meta, fileKey（main / agent-<thread id>），child（null 或 {instance, parentInstance, agentType}），
//      perms（这个会话的 PermissionRequest 证据）, parentTurn, close（'' / session_end / idle / resume）, cap, usageRecords（这份文件出现过 token_usage_record）}
export function mapRollout(lines, o) {
  const out = [], keys = new Set(), usedPerms = new Set();
  let meta = o.meta ?? null;
  let usageRecords = o.usageRecords === true || lines.some((l) => l.raw.includes('"token_usage_record"'));
  const turns = new Map();
  let cur = null, lastAt = null;
  const ledger = { records: 0, bad_json: 0, types: {}, unknown: {}, orphan_items: 0, copied_meta: 0, copied_events: 0 };
  const paginated = () => String(meta?.history_mode ?? '').toLowerCase() === 'paginated';
  const agent = () => ({ name: 'codex', version: meta?.cli_version ?? null, surface: surfaceOf(meta?.originator) });
  const turnIdOf = (t) => (o.child ? (t.root ?? o.parentTurn ?? t.id) : t.id);
  const mk = (type, at, t, prov = { kind: 'transcript', rule_version: RULE }) => {
    const e = baseEvent(agent(), o.ctx, {
      sid: o.sid, type, at, turn: t ? turnIdOf(t) : null,
      instance: o.child ? o.child.instance : 'main', parentInstance: o.child ? o.child.parentInstance : null,
      parentCall: o.child ? (o.child.parentCall ?? null) : null, provenance: prov,
    });
    if (t && t.copied) e._copied = true;
    return e;
  };
  const push = (e, key) => { if (e._copied) { ledger.copied_events++; return; } if (keys.has(key)) return; keys.add(key); e._key = key; out.push(e); };
  // 抄来的父会话历史（codex-v4，照 Pilot 的 isCopiedParentTurnByTime）：turn id 的 UUIDv7 时刻（不是 UUIDv7 就用这一轮第一条记录的时间）早于这份文件自己 session_meta 的，
  // 是父会话的轮，不再发一遍
  const ownerMs = o.ownerCopies ? Date.parse(o.ownerCreatedAt ?? '') : NaN;
  const copiedTurn = (id, at) => Number.isFinite(ownerMs) && (uuidV7Ms(id) ?? Date.parse(at)) < ownerMs;
  const spawns = [];

  const turnOf = (id, off, at) => {
    if (typeof id !== 'string' || id === '') return cur;
    let t = turns.get(id);
    if (!t) {
      t = { id, off, at, root: null, model: null, approval: null, cwd: null, users: 0, userKinds: new Map(), calls: new Map(), items: new Map(),
        files: {}, usage: null, acc: null, buf: null, closed: false, subStarted: false, task: null, copied: copiedTurn(id, at) };
      turns.set(id, t);
    }
    cur = t;
    return t;
  };
  const bufOf = (t, at) => (t.buf ??= { texts: [], reasoning: [], tools: [], ids: [], started_at: at });

  const subStart = (t, at) => {
    if (!o.child || t.subStarted) return;
    t.subStarted = true;
    const e = mk('subagent.start', at, t);
    const inc = o.cap && typeof t.task === 'string' && t.task.length > 0;
    e.content_state = inc ? 'included' : 'omitted';
    e.payload = { agent_type: o.child.agentType || 'unknown', ...(inc ? { task: t.task } : {}) };
    e.extensions = { ...e.extensions, ...opt('codex.agent_path', o.child.agentPath), ...opt('codex.agent_nickname', o.child.nickname), ...opt('vibetrail.parent_link', o.child.link) };
    push(e, `${o.fileKey}|${t.id}|subagent.start`);
  };

  const flushCall = (t, key, usage, at) => {           // 一次模型响应一条 message.assistant（照 Claude 那一路的 trace 形状）
    const b = t.buf;
    if (!b && !isObj(usage)) return;
    const bb = b ?? { texts: [], reasoning: [], tools: [], ids: [], started_at: at };
    t.buf = null;
    const txt = bb.texts.filter(Boolean).join('\n\n'), think = bb.reasoning.filter(Boolean).join('\n\n');
    const e = mk('message.assistant', at, t);
    const inc = o.cap && txt.length > 0;
    e.content_state = inc ? 'included' : 'omitted';
    e.payload = { author_type: 'agent', ...opt('model', t.model), ...(inc ? { text: txt } : {}) };
    if (o.cap && think.length > 0) e.extensions['vibetrail.reasoning'] = think;
    e.extensions['vibetrail.call'] = { kind: 'llm', tool_calls: bb.tools, tool_call_ids: bb.ids,
      ...opt('response_id', typeof key === 'string' && !key.includes('@') ? key : null), ...opt('usage', usageOf(usage)), ...opt('started_at', bb.started_at) };
    if (isObj(usage) && num(usage.cache_write_input_tokens)) e.extensions['codex.cache_write_input_tokens'] = num(usage.cache_write_input_tokens);
    push(e, `${o.fileKey}|${key}|llm.call`);
  };

  const userMessage = (t, text, at, off, kind) => {
    if (!t) return;
    const h = sha256(text, 16);
    const seenKind = t.userKinds.get(h);
    if (seenKind && seenKind !== kind) return;         // 同一句话两种记录都写了（旧版本过渡期），只发一次
    t.userKinds.set(h, kind);
    t.users += 1;
    if (o.child && t.task === null) t.task = text;
    subStart(t, at);
    const e = mk('message.user', at, t);
    const inc = o.cap && text.length > 0;
    e.content_state = inc ? 'included' : 'omitted';
    // 子 agent 收到的是父 agent 的派活（协议：author agent、delivery injected）；主会话一轮里第二句起是轮中插话（steer），待实测
    e.payload = { author_type: o.child ? 'agent' : 'human', delivery: o.child ? 'injected' : t.users === 1 ? 'direct' : 'queued', ...(inc ? { text } : {}) };
    if (!o.child && t.users > 1) e.extensions['codex.mid_turn'] = true;
    push(e, `${o.fileKey}@${off}|message.user`);
  };

  const toolEnd = (t, cid, output, at) => {
    if (!cid) return;
    const c = t.calls.get(cid) ?? { name: 'unknown', input: null, at: null, done: false };
    c.done = true;
    const text = outputText(output);
    const item = t.items.get(cid);
    const itemStatus = String(item?.status ?? '').toLowerCase();
    const whole = text.trim();
    if (POLICY.test(whole) || REJECTED.test(whole) || itemStatus === 'declined') {
      const policy = POLICY.test(whole);
      // 人拒绝要有弹框证据落在「调用发出 → 结果回来」之间，而且一次弹框只配一次拒绝（codex-v3）。v2 只要同一轮弹过框就算，
      // 一轮里一次允许的弹框加一次非人为的拒绝就会误标成人拒（Codex 09-17 自己提的意见 1）
      // 自动审批（turn_context.approvals_reviewer = auto_review）下，审批先交给 Codex 的 guardian 模型审，拒掉的不一定是人：
      // 弹框证据在窗口里也不判人拒、不标分歧，只记下审批方式（codex-v5，09-17 用户桌面版上发现开着自动审批）
      const autoReview = String(t.reviewer ?? '').toLowerCase() === 'auto_review';
      const lo = Date.parse(c.at ?? at) - PERM_SLACK_MS, hi = Date.parse(at) + PERM_SLACK_MS;
      const perm = policy || autoReview ? null : (o.perms ?? []).find((x) => !usedPerms.has(x._id) && (x.turn_id === t.id || (t.root && x.turn_id === t.root))
        && Date.parse(x.at) >= lo && Date.parse(x.at) <= hi);
      if (perm) usedPerms.add(perm._id);
      const human = Boolean(perm);
      const e = mk('permission.decision', at, t);
      e.payload = { permission_id: cid, tool_name: c.name, call_id: cid, decision: 'deny',
        decided_by: policy ? 'policy' : human ? 'user' : 'unknown', ...opt('reason', text.slice(0, 4096)) };
      if (human) e.is_divergence = true;
      e.extensions['vibetrail.denial_evidence'] = [...(itemStatus === 'declined' ? ['item_declined'] : []),
        ...(REJECTED.test(whole) || POLICY.test(whole) ? ['output_text'] : []), ...(human ? ['permission_request_in_window'] : [])];
      if (t.reviewer) e.extensions['codex.approvals_reviewer'] = t.reviewer;
      push(e, `${cid}|permission.decision`);
      return;
    }
    const exit = typeof item?.exit_code === 'number' ? item.exit_code : isObj(output) && typeof output.exit_code === 'number' ? output.exit_code : null;
    const failed = itemStatus === 'failed' || (isObj(output) && output.success === false) || (exit !== null && exit !== 0);
    const reported = durationMs(item?.duration)
      ?? (item && typeof item.completed_at_ms === 'number' && typeof item.started_at_ms === 'number' ? item.completed_at_ms - item.started_at_ms : null);
    const wall = c.at && c.at !== at ? Date.parse(at) - Date.parse(c.at) : NaN;   // 调用与结果是同一条记录（web_search_call）时没有耗时
    const d = reported ?? (Number.isFinite(wall) && wall >= 0 ? wall : null);
    const e = mk('tool.end', at, t);
    e.content_state = o.cap ? 'included' : 'omitted';
    e.payload = { tool_name: c.name, call_id: cid, status: failed ? { code: 'failed', category: 'failure' } : { code: 'succeeded', category: 'success' },
      ...opt('duration_ms', d === null ? null : Math.round(d)), ...(o.cap && text !== '' ? { output: text } : {}) };
    if (d !== null) e.extensions['vibetrail.duration_kind'] = reported !== null ? 'reported' : 'wall_clock';
    if (exit !== null) e.extensions['codex.exit_code'] = exit;
    push(e, `${cid}|tool.end`);
    if (!failed) for (const [p, op] of patchFiles(c.name, c.input)) noteFile(t.files, relFile(p, o.ctx.roots, t.cwd ?? meta?.cwd ?? ''), op);
    // 派子 agent 的调用（codex-v4）：记下它返回的子线程 id（源码里 SpawnAgentResult 是 {agent_id, nickname}）与 agent_path
    // （桌面版多 agent v2 返回 {task_name: "/root/…"}，Pilot 夹具），映射子 agent 文件时用来补 parent_call_id
    if (!failed && !t.copied && c.name === 'spawn_agent') {
      let j = null; try { j = JSON.parse(text); } catch {}
      spawns.push({ call_id: cid, turn_id: turnIdOf(t), by: o.child ? o.child.instance : 'main',
        ...opt('agent_path', typeof j?.task_name === 'string' ? j.task_name : null),
        ids: [...new Set((text.match(UUID_RE) || []).map((x) => x.toLowerCase()))] });
    }
  };

  const closeTurn = (t, reason, at, p = {}, by = null) => {
    if (t.closed) return;
    t.closed = true;
    if (t.buf) flushCall(t, `${t.id}@end`, null, at);
    const rs = codeify(reason);
    if (rs !== 'completed') {                           // K21 同款：轮没正常结束时，还没结果的调用补 tool.end(cancelled)
      for (const [cid, c] of t.calls) {
        if (c.done) continue;
        c.done = true;
        const e = mk('tool.end', at, t);
        e.content_state = 'omitted';
        e.payload = { tool_name: c.name, call_id: cid, status: { code: 'cancelled', category: 'cancellation' } };
        push(e, `${cid}|tool.end`);
      }
    }
    const status = TURN_STATUS[rs] ?? { code: rs, category: 'unknown' };
    const files = filesOf(t.files, 'tool_result');
    if (o.child) {
      subStart(t, at);
      const lm = typeof p.last_agent_message === 'string' ? p.last_agent_message : '';
      const inc = o.cap && lm.length > 0;
      const e = mk('subagent.end', at, t);
      e.content_state = inc ? 'included' : 'omitted';
      e.payload = { agent_type: o.child.agentType || 'unknown',
        status: rs === 'completed' ? { code: 'completed', category: 'success' } : status.category === 'cancellation' ? { code: 'cancelled', category: 'cancellation', detail: rs } : { code: rs, category: status.category },
        ...(inc ? { last_message: lm } : {}) };
      if (files) e.files = files;
      if (by) e.extensions['vibetrail.end_evidence'] = by;
      push(e, `${o.fileKey}|${t.id}|subagent.end`);
      return;
    }
    const hook = turnEvidence(o.sid, t.id);
    const e = mk('turn.end', at, t);
    e.payload = { status, ...opt('model', t.model), ...opt('usage', usageOf(t.usage ?? t.acc)), ...opt('vcs', vcsOf(hook?.vcs)) };
    const commits = commitsOf(hook);
    if (commits) e.commits = commits;
    if (files) e.files = files;
    if (rs === 'interrupted') e.is_divergence = true;   // 人按停止（Op::Interrupt）；replaced / budget_limited 不是人发起的
    e.extensions['vibetrail.end_evidence'] = by ?? (rs === 'completed' ? 'task_complete' : 'turn_aborted');
    if (hook?.commit_method) e.extensions['vibetrail.commit_method'] = hook.commit_method;
    if (num(p.duration_ms) !== null) e.extensions['codex.duration_ms'] = num(p.duration_ms);
    push(e, `${t.id}|turn.end`);
  };

  const startTurn = (t, at) => {
    for (const x of turns.values()) if (x !== t && !x.closed) closeTurn(x, 'unknown', at, {}, 'next_turn');   // 上一轮没有终态记录（崩溃）
    if (o.child) return;
    const e = mk('turn.start', at, t);
    push(e, `${t.id}|turn.start`);                      // 与 UserPromptSubmit 发的同一个 key：先写的留下（hook 那条带 vcs）
  };

  for (const { off, raw } of lines) {
    let r;
    try { r = JSON.parse(raw); } catch { ledger.bad_json++; continue; }
    if (!isObj(r)) { ledger.bad_json++; continue; }
    ledger.records++;
    const p = isObj(r.payload) ? r.payload : {};
    const at = typeof r.timestamp === 'string' ? r.timestamp : (lastAt ?? nowIso());
    lastAt = at;
    const kind = r.type === 'event_msg' || r.type === 'response_item' ? `${r.type}/${p.type}` : String(r.type);
    ledger.types[kind] = (ledger.types[kind] ?? 0) + 1;
    switch (r.type) {
      case 'session_meta': {
        const mid = String(p.id ?? p.session_id ?? '').toLowerCase();
        if (o.ownerId && mid && mid !== o.ownerId) { ledger.copied_meta++; break; }   // 抄来的父会话 meta：不换 meta、不发（codex-v4）
        meta = p;
        const bi = typeof p.base_instructions === 'string' ? p.base_instructions : typeof p.base_instructions?.text === 'string' ? p.base_instructions.text : '';
        if (bi) {                                       // system prompt：按 sha256 去重，正文只在全采时带（同 Claude 的 prompt_snapshot）
          const h = sha256(bi);
          const e = mk('ext.codex.base_instructions', at, null, { kind: 'transcript', rule_version: RULE, source_event: 'session_meta' });
          e.content_state = o.cap ? 'included' : 'omitted';
          e.payload = { sha256: h, bytes: Buffer.byteLength(bi, 'utf8') };
          if (o.cap) e.extensions['codex.base_instructions'] = bi;
          push(e, `${o.fileKey}|base_instructions|${h}`);
        }
        break;
      }
      case 'turn_context': {
        const t = turnOf(p.turn_id, off, at);
        if (!t) break;
        t.model = p.model ?? t.model; t.approval = p.approval_policy ?? t.approval; t.cwd = p.cwd ?? t.cwd; t.root = p.root_turn_id ?? t.root;
        t.reviewer = p.approvals_reviewer ?? t.reviewer;   // user / auto_review（审批先交给 guardian 模型审）
        break;
      }
      case 'token_usage_record': {
        const t = turnOf(p.turn_id, off, at);
        if (!t) break;
        flushCall(t, typeof p.response_id === 'string' && p.response_id ? p.response_id : `${t.id}@${off}`, p.usage, at);
        if (isObj(p.turn_token_usage)) t.usage = p.turn_token_usage;
        break;
      }
      case 'event_msg': {
        switch (p.type) {
          case 'task_started': { const t = turnOf(p.turn_id, off, at); if (t) startTurn(t, at); break; }
          case 'user_message': if (!paginated()) userMessage(turnOf(p.turn_id, off, at), typeof p.message === 'string' ? p.message : textOf(p.message), at, off, 'event'); break;
          case 'item_completed': {
            const t = turnOf(p.turn_id, off, at);
            const it = isObj(p.item) ? p.item : null;
            if (!t || !it) break;
            if (it.type === 'UserMessage') userMessage(t, textOf(it.content), at, off, 'item');
            else if (it.id !== undefined) t.items.set(String(it.id), { ...it, started_at_ms: p.started_at_ms, completed_at_ms: p.completed_at_ms });
            break;
          }
          case 'token_count': {                         // 老版本没有 token_usage_record 时，退到每次响应后的 last_token_usage
            if (usageRecords || !cur) break;
            const u = p.info?.last_token_usage;
            if (isObj(u)) { flushCall(cur, `${cur.id}@${off}`, u, at); cur.acc = addUsage(cur.acc, u); }
            break;
          }
          case 'task_complete': { const t = turnOf(p.turn_id, off, at); if (t) closeTurn(t, 'completed', at, p); break; }
          case 'turn_aborted': { const t = turnOf(p.turn_id, off, at); if (t) closeTurn(t, String(p.reason ?? 'unknown'), at, p); break; }
          default: break;
        }
        break;
      }
      case 'response_item': {
        const t = cur;
        // response_item 自己不带 turn_id，只能按顺序归到当前轮。轮已经结束（task_complete / turn_aborted 之后、下一轮开始之前）就不挂上去、只计数（codex-v3）：
        // 否则回复进了已关的轮的缓冲、再也发不出去（Codex 09-17 意见 5 顺带照出来的）。只数这次新读到的字节，重读不重复计
        if (!t || t.closed) { if (off >= (o.newFrom ?? 0)) ledger.orphan_items++; break; }
        switch (p.type) {
          case 'message':                               // user / developer 角色是注入与人话的原样（AGENTS.md、环境信息），人话只认 UserMessage / user_message
            if (p.role === 'assistant') bufOf(t, at).texts.push(textOf(p.content));
            break;
          case 'reasoning': {
            const s = Array.isArray(p.summary) ? p.summary.filter(isObj).map((x) => x.text).filter((x) => typeof x === 'string').join('\n') : '';
            bufOf(t, at);
            if (s) t.buf.reasoning.push(s);
            break;
          }
          case 'function_call': case 'custom_tool_call': case 'local_shell_call': {
            const cid = String(p.call_id ?? p.id ?? `${o.fileKey}@${off}`);
            const name = String(p.name ?? (p.type === 'local_shell_call' ? 'local_shell' : p.type));
            const input = p.type === 'function_call' ? parseArgs(p.arguments) : p.type === 'custom_tool_call' ? (p.input ?? null) : (p.action ?? null);
            if (!t.calls.has(cid)) t.calls.set(cid, { name, input, at, done: false });
            const b = bufOf(t, at);
            b.tools.push(name); b.ids.push(cid);
            if (o.cap && input !== null && input !== undefined) {
              const e = mk('tool.request', at, t);
              e.content_state = 'included';
              e.payload = { tool_name: name, call_id: cid, input };
              push(e, `${cid}|tool.request`);
            }
            break;
          }
          case 'function_call_output': case 'custom_tool_call_output':
            toolEnd(t, String(p.call_id ?? ''), p.output, at);
            break;
          // 两种搜索调用（codex-v4，照 Pilot 的 codex-aborted-turn-extractor）：web_search_call 没有单独的结果记录，状态就在调用上；
          // tool_search_call 与 tool_search_output 按 call_id 配
          case 'web_search_call': case 'tool_search_call': {
            const cid = String(p.call_id ?? p.id ?? `${o.fileKey}@${off}`);
            const name = p.type === 'web_search_call' ? 'web_search' : 'tool_search';
            const input = p.type === 'web_search_call' ? (p.action ?? null) : (p.arguments ?? null);
            if (!t.calls.has(cid)) t.calls.set(cid, { name, input, at, done: false });
            const b = bufOf(t, at);
            b.tools.push(name); b.ids.push(cid);
            if (o.cap && input !== null && input !== undefined) {
              const e = mk('tool.request', at, t);
              e.content_state = 'included';
              e.payload = { tool_name: name, call_id: cid, input };
              push(e, `${cid}|tool.request`);
            }
            const st = String(p.status ?? '').toLowerCase();
            if (p.type === 'web_search_call' && /^(completed|failed|incomplete)$/.test(st)) toolEnd(t, cid, { content: '', success: st === 'completed' }, at);
            break;
          }
          case 'tool_search_output':
            toolEnd(t, String(p.call_id ?? ''), { content: JSON.stringify(p.tools ?? []), success: String(p.status ?? '').toLowerCase() !== 'failed' }, at);
            break;
          default: break;
        }
        break;
      }
      case 'world_state': case 'compacted': break;
      default: ledger.unknown[String(r.type)] = (ledger.unknown[String(r.type)] ?? 0) + 1;
    }
  }

  // 兜底关轮：会话结束、同会话恢复、空闲超过 turn_idle_close 时，没有终态记录的轮按 unknown 关
  if (o.close) for (const t of turns.values()) if (!t.closed) closeTurn(t, 'unknown', lastAt ?? nowIso(), {}, o.close);
  const open = [...turns.values()].filter((t) => !t.closed && !t.copied);   // 抄来的历史截在半轮也不卡住读取进度
  return {
    events: out, meta,
    ledger: { ...ledger, spawns, usage_records: usageRecords, open_off: open.length ? Math.min(...open.map((t) => t.off)) : null, open_turn: open.length ? open[open.length - 1].id : null },
  };
}

// ---------- 一份 rollout：增量读 → 映射 → 写 spool → 推进 state ----------
const permsOf = (sid) => {                             // 按弹框时刻排好序；_id 是证据文件名（一次弹框只配一次拒绝）
  const d = path.join(VT_HOME, 'state', sid, 'perms');
  let names = []; try { names = fs.readdirSync(d); } catch { return []; }
  return names.filter((n) => n.endsWith('.json')).map((n) => ({ ...readJson(path.join(d, n), {}), _id: n }))
    .filter((x) => typeof x.at === 'string').sort((a, b) => (a.at < b.at ? -1 : a.at > b.at ? 1 : 0));
};

export function processFile(sid, ctx, file, fileKey, { child = null, close = '', ev = '', parentTurn = null } = {}) {
  const SD = path.join(VT_HOME, 'state', sid);
  const stFile = path.join(SD, `codex-${fileKey}.json`);
  let st = readJson(stFile, {});
  let size; try { size = fs.statSync(file).size; } catch { return null; }
  let consumed = st.consumed_bytes ?? 0, ck = st.checkpoint_byte ?? 0;
  let ino = null; try { ino = fs.statSync(file).ino; } catch {}
  if (size === consumed && (!st.fprint || String(st.fprint).split(':')[0] === String(ino)) && !(close && st.open_turn)) return st;
  if (consumed > 0 && (size < consumed || (st.fprint && vtFprint(file, consumed) !== st.fprint))) {   // 被重写过：从 0 重读，ids 挡重复
    st = { rewrites: (st.rewrites ?? 0) + 1 }; consumed = 0; ck = 0;
  }
  const slice = readSlice(file, ck);
  // 补采老会话最多补两天（U18，同 hook.mjs）：从没读过的文件从窗口内的第一条记录读起；已经在跟的每次都读，不按天截
  let skippedOld = 0;
  const firstRead = !isFile(stFile) && ck === 0;
  const cutoff = firstRead ? vtBackfillCutoffMs() : null;
  if (cutoff !== null && slice.lines.length) {
    const i = slice.lines.findIndex((l) => { const m = l.raw.match(/"timestamp":"([^"]+)"/); const t = m ? Date.parse(m[1]) : NaN; return !Number.isFinite(t) || t >= cutoff; });
    const k = i < 0 ? slice.lines.length : i;
    if (k > 0) { skippedOld = (k < slice.lines.length ? slice.lines[k].off : slice.end) - slice.lines[0].off; slice.lines = slice.lines.slice(k); }
  }
  const meta = st.meta?.timestamp ? st.meta : (metaOf(file) ?? st.meta ?? null);   // v4 之前的 state 里 meta 不带 timestamp：重取一次
  const res = mapRollout(slice.lines, { sid, ctx, meta, fileKey, child, perms: permsOf(sid), parentTurn, close, cap: capture(), usageRecords: st.usage_records === true, newFrom: consumed,
    ownerId: sidOfPath(file), ownerCopies: copiesHistory(meta), ownerCreatedAt: meta?.timestamp ?? null });
  if (!emit(ctx.pkey, sid, `codex-${fileKey}`, res.events, ev)) return null;
  if (res.ledger.spawns.length) {                      // 派子 agent 的调用，给子 agent 文件补 parent_call_id 用
    const spF = path.join(SD, 'codex-spawns.json');
    const all = readJson(spF, {});
    for (const s of res.ledger.spawns) all[s.call_id] = s;
    vtWriteJson(spF, all);
  }
  const nst = {
    consumed_bytes: slice.end, checkpoint_byte: res.ledger.open_off ?? slice.end, fprint: vtFprint(file, slice.end) ?? '',
    meta: compactMeta(res.meta ?? meta), usage_records: res.ledger.usage_records, open_turn: res.ledger.open_turn,
    records: res.ledger.records, bad_json: res.ledger.bad_json, unknown: res.ledger.unknown, rewrites: st.rewrites ?? 0,
    orphan_items: (st.orphan_items ?? 0) + res.ledger.orphan_items,
    ...((st.skipped_old_bytes ?? 0) + skippedOld > 0 ? { skipped_old_bytes: (st.skipped_old_bytes ?? 0) + skippedOld } : {}), updated_at: nowIso(),
  };
  vtWriteJson(stFile, nst);
  return nst;
}

// 子 agent 是独立的 rollout，session_meta.source 指回父线程。按日期目录找（父会话文件所在的那天、今天、昨天），第一行读过的记下来不再读
function childRollouts(sid, mainFile) {
  const idxFile = path.join(VT_HOME, 'state', sid, 'codex-children.json');
  const idx = readJson(idxFile, { checked: {}, children: {} });
  const dirs = new Set([path.dirname(mainFile)]);
  for (const t of [Date.now(), Date.now() - 86400000]) {
    const d = new Date(t);
    dirs.add(path.join(codexHome(), 'sessions', String(d.getFullYear()), String(d.getMonth() + 1).padStart(2, '0'), String(d.getDate()).padStart(2, '0')));
  }
  let changed = false;
  const cands = [];
  for (const d of dirs) {
    let names = []; try { names = fs.readdirSync(d).filter((n) => n.startsWith('rollout-') && n.endsWith('.jsonl')); } catch { continue; }
    for (const n of names) {
      const f = path.join(d, n);
      if (f === mainFile) continue;
      if (!(f in idx.checked)) {
        const m = metaOf(f);
        if (!m) continue;                               // 第一行还没写完：下次再看
        const sp = spawnOf(m);
        idx.checked[f] = sp ? { id: String(m.id ?? m.session_id ?? ''), parent: String(sp.parent_thread_id), role: sp.agent_role ?? sp.agent_type ?? m.agent_role ?? null,
          path: sp.agent_path ?? m.agent_path ?? null, nickname: sp.agent_nickname ?? m.agent_nickname ?? null } : null;
        changed = true;
      }
      if (idx.checked[f]) cands.push([f, idx.checked[f]]);
    }
  }
  const known = new Set([sid, ...Object.keys(idx.children)]);
  for (let grew = true; grew;) {
    grew = false;
    for (const [f, c] of cands) {
      if (c.id && !known.has(c.id) && known.has(c.parent)) {
        known.add(c.id);
        idx.children[c.id] = { file: f, parent: c.parent === sid ? 'main' : c.parent, role: c.role, path: c.path ?? null, nickname: c.nickname ?? null };
        grew = true; changed = true;
      }
    }
  }
  if (changed) vtWriteJson(idxFile, idx);
  return Object.entries(idx.children).map(([id, c]) => ({ id, ...c })).filter((c) => isFile(c.file));
}

// 子 agent ↔ 派它的 spawn_agent 调用（codex-v4，照 Pilot 的 codex-subagent-linker：只认可靠的两种，对上多个就不认）：
// 子线程 id 只出现在一次 spawn 的结果里；或者子 agent 的 agent_path 只等于一次 spawn 返回的 task_name。按时间先后猜的不用
function linkSpawn(spawns, c) {
  const pool = spawns.filter((s) => (s.by ?? 'main') === c.parent);
  const byId = pool.filter((s) => Array.isArray(s.ids) && s.ids.includes(String(c.id).toLowerCase()));
  if (byId.length === 1) return { call_id: byId[0].call_id, turn_id: byId[0].turn_id ?? null, how: 'explicit_id' };
  if (byId.length > 1 || !c.path) return null;
  const byPath = pool.filter((s) => s.agent_path === c.path);
  return byPath.length === 1 ? { call_id: byPath[0].call_id, turn_id: byPath[0].turn_id ?? null, how: 'agent_path' } : null;
}

export function processSession(sid, ctx, mainFile, { close = '', ev = '' } = {}) {
  const SD = path.join(VT_HOME, 'state', sid);
  if (!mkdirp(SD) || !vtLock(SD)) return;               // 同一会话已在跑：跳过，下一次 hook 补上
  try {
    // 先主会话、再子 agent（codex-v4）：子 agent 的 parent_call_id 要用主会话里 spawn_agent 调用的结果
    processFile(sid, ctx, mainFile, 'main', { close, ev });
    const parentTurn = (readText(path.join(SD, 'last_turn')) || '').trim() || null;
    const spawns = Object.values(readJson(path.join(SD, 'codex-spawns.json'), {})).filter(isObj);
    for (const c of childRollouts(sid, mainFile)) {
      const link = linkSpawn(spawns, c);
      processFile(sid, ctx, c.file, `agent-${c.id}`, { child: { instance: c.id, parentInstance: c.parent, agentType: c.role ?? 'unknown',
        parentCall: link?.call_id ?? null, link: link?.how ?? null, agentPath: c.path ?? null, nickname: c.nickname ?? null }, close, ev, parentTurn: link?.turn_id ?? parentTurn });
    }
  } finally { vtUnlock(SD); }
}

// Stop 时等这一轮的终态记录落盘（Stop hook 是 async，Codex 随后才写 task_complete）；等不到不强关——
// 协议要求 Stop 被拦下时不得提前发 turn.end，Codex 只在真结束时写 task_complete，所以留给下一次 hook 读到
function waitTurnEnd(file, turnId) {
  const limit = Number(process.env.VIBETRAIL_STOP_WAIT ?? vtConf('stop_wait', '10'));
  if (!turnId || !(limit > 0)) return;
  const needle = `"turn_id":"${turnId}"`;
  const deadline = Date.now() + limit * 1000;
  for (;;) {
    for (const line of tailText(file, 1024 * 1024).split('\n')) {
      if ((line.includes('"task_complete"') || line.includes('"turn_aborted"')) && line.includes(needle)) return;
    }
    if (Date.now() >= deadline) return;
    sleepSync(250);
  }
}

// SessionStart 补做：hook 见过的 Codex 会话里，文件落后于 state 的各补一次；别的会话空闲超过 turn_idle_close 的把最后一轮关掉
function catchUp(currentSid, resume) {
  const idle = Number(vtConf('turn_idle_close', '3600'));
  let sids = []; try { sids = fs.readdirSync(path.join(VT_HOME, 'state')); } catch { return; }
  for (const s of sids) {
    const sess = readJson(path.join(VT_HOME, 'state', s, 'codex.json'), null);
    if (!isObj(sess) || !sess.transcript_path || !isFile(sess.transcript_path)) continue;
    const ctx = gate([sess.cwd, sess.workspace]);
    if (!ctx) continue;
    let close = '';
    if (s === currentSid) close = resume ? 'resume' : '';
    else {
      let mt = epochSec(); try { mt = Math.floor(fs.statSync(sess.transcript_path).mtimeMs / 1000); } catch {}
      if (epochSec() - mt >= idle) close = 'idle';
    }
    processSession(s, ctx, sess.transcript_path, { close, ev: 'SessionStart' });
  }
}

// ---------- hook ----------
export function runCodexHook(event, raw) {
  const p = (() => { try { return JSON.parse(raw); } catch { return null; } })();
  if (!isObj(p) || !CODEX_EVENTS.includes(event)) return;
  const sid = String(p.session_id ?? '');
  if (!validSid(sid)) return;
  const cwd = String(p.cwd ?? '');
  const ctx = gate([cwd]);
  if (!ctx) return;                                     // 未登记的仓：什么都不写
  const SD = path.join(VT_HOME, 'state', sid);
  const sessFile = path.join(SD, 'codex.json');
  const sess = readJson(sessFile, {});
  const tp = String(p.transcript_path ?? '');
  const file = tp && isFile(tp) ? tp : (sess.transcript_path && isFile(sess.transcript_path) ? sess.transcript_path : '');
  const meta = file ? (readJson(path.join(SD, 'codex-main.json'), {}).meta ?? metaOf(file)) : null;
  // 子 agent 线程自己的 hook（若会触发）：它的一切从父会话那边的子 rollout 推，这里不发会话 / 轮次事件（待实测）；
  // guardian 自动审批线程（codex-v5）：是模型在审审批、不是人的会话，不采
  if (spawnOf(meta) || isGuardian(meta)) return;
  if (!mkdirp(SD)) return;                              // 跳过的线程连空的 state 目录都不留
  vtWriteJson(sessFile, { ...sess, agent: 'codex', workspace: ctx.workspace, cwd, ...(file ? { transcript_path: file } : {}), ...opt('model', p.model), updated_at: nowIso() });
  const agent = { name: 'codex', version: meta?.cli_version ?? null, surface: surfaceOf(meta?.originator) };
  const now = nowIso();
  const turnId = String(p.turn_id ?? '');
  const hookEv = (type, turn) => baseEvent(agent, ctx, { sid, type, at: now, turn, provenance: { kind: 'hook', source_event: event } });
  const out = (events) => emit(ctx.pkey, sid, 'hook-' + event.toLowerCase(), events, event);
  const lastTurn = () => (readText(path.join(SD, 'last_turn')) || '').trim();

  switch (event) {
    case 'SessionStart': {
      const snap = vtGitSnapshot(cwd);
      const src = codeify(p.source ?? 'startup');
      const e = hookEv('session.start', null);
      e.payload = { source: src, capabilities: CAPS };
      e.extensions = { ...e.extensions, ...opt('codex.model', p.model), ...opt('codex.permission_mode', p.permission_mode),
        ...opt('vibetrail.vcs', vcsOf(snap)), ...opt('vibetrail.cwd', displayDir(cwd, ctx.roots)) };
      e._key = `session.start|${src}|${now}`;
      out([e]);
      catchUp(sid, p.source === 'resume');
      break;
    }
    case 'UserPromptSubmit': {
      if (!turnId) break;
      const snap = vtGitSnapshot(cwd);
      const prev = lastTurn();
      if (prev && prev !== turnId) turnGap(sid, prev, cwd, snap, 'UserPromptSubmit');
      turnStart(sid, turnId, snap);
      fs.writeFileSync(path.join(SD, 'last_turn'), turnId + '\n');
      const e = hookEv('turn.start', turnId);
      e.payload = { ...opt('model', p.model), ...opt('vcs', vcsOf(snap)) };
      e.extensions = { ...e.extensions, ...opt('codex.permission_mode', p.permission_mode), ...opt('vibetrail.dirty_files', snap?.dirty_files) };
      e._key = `${turnId}|turn.start`;
      out([e]);
      break;
    }
    case 'PermissionRequest': {                         // 弹过审批框的证据（入参没有 tool_use_id，只按轮对）；不带参数
      mkdirp(path.join(SD, 'perms'));
      try {
        fs.writeFileSync(path.join(SD, 'perms', `${epochSec()}-${process.pid}.json`), JSON.stringify({ at: now, turn_id: turnId || null,
          tool_name: p.tool_name ?? null, agent_id: p.agent_id ?? null, permission_mode: p.permission_mode ?? null }) + '\n');
      } catch {}
      const e = hookEv('ext.codex.permission_request', turnId || null);
      e.payload = { tool_name: String(p.tool_name ?? 'unknown'), ...opt('permission_mode', p.permission_mode), ...opt('agent_type', p.agent_type) };
      e._key = `ext|PermissionRequest|${turnId}|${p.tool_name ?? ''}|${now}`;
      out([e]);
      break;
    }
    case 'Stop': {
      if (turnId) turnStop(sid, turnId, cwd, vtGitSnapshot(cwd), { stop_hook_active: p.stop_hook_active === true });
      if (file) { waitTurnEnd(file, turnId); processSession(sid, ctx, file, { ev: event }); }
      break;
    }
    case 'SessionEnd': {
      const snap = vtGitSnapshot(cwd);
      const prev = lastTurn();
      if (prev) turnGap(sid, prev, cwd, snap, 'SessionEnd');
      if (file) processSession(sid, ctx, file, { close: 'session_end', ev: event });
      const e = hookEv('session.end', null);
      e.payload = { reason: codeify(p.reason ?? 'other'), status: { code: 'completed', category: 'success' } };
      e.extensions = { ...e.extensions, ...opt('vibetrail.vcs', vcsOf(snap)) };
      e._key = `session.end|${now}`;
      out([e]);
      break;
    }
    default: break;
  }
  return event === 'Stop' ? 'threshold' : event === 'SessionStart' || event === 'SessionEnd' ? 'force' : '';   // 交给 autoPush（D6）
}

// vibetrail.mjs 调进来：同步的 hook 读完 stdin 就丢后台、自己立刻退出（stdout 为空，SessionStart / UserPromptSubmit 的输出会进模型上下文）
export async function hookEntry(cmd, event, payload, entry) {
  if (!agentEnabled('codex')) return;                  // init 时没选 Codex、条目却还在（手改过）：不采
  if (cmd === 'hook' && SYNC.has(event) && process.env.VIBETRAIL_FOREGROUND !== '1') { detach(entry, 'codex', event, payload); return; }
  return runCodexHook(event, payload);
}

// ---------- 安装 / 卸载 / 自检：~/.codex/hooks.json ----------
function stripOurs(doc) {
  const out = { ...doc };
  if (!isObj(doc.hooks)) return out;
  const hooks = {};
  for (const [ev, groups] of Object.entries(doc.hooks)) {
    if (!Array.isArray(groups)) { hooks[ev] = groups; continue; }
    const kept = groups.map((g) => (isObj(g) && Array.isArray(g.hooks) ? { ...g, hooks: g.hooks.filter((h) => !isOurs(h?.command)) } : g))
      .filter((g) => !(isObj(g) && Array.isArray(g.hooks)) || g.hooks.length > 0);
    if (kept.length > 0) hooks[ev] = kept;
  }
  if (Object.keys(hooks).length) out.hooks = hooks; else delete out.hooks;
  return out;
}
export function codexInstall() {
  const f = hooksFile();
  const cur = readHostJson(f);
  if (cur === null) return { ok: false, file: f, msg: `读不懂 ${f}（不是合法的 JSON 对象），没改` };
  const next = stripOurs(structuredClone(cur));
  next.hooks = isObj(next.hooks) ? next.hooks : {};
  // 自家条目追加在每个事件末尾：信任记录的 key 带组序号，插到别人前面会让别人的信任失效
  for (const ev of CODEX_EVENTS) {
    next.hooks[ev] = [...(Array.isArray(next.hooks[ev]) ? next.hooks[ev] : []),
      { hooks: [{ type: 'command', command: hookCommand('codex', ev), timeout: TIMEOUT[ev], ...(ev === 'Stop' ? { async: true } : {}) }] }];
  }
  if (sameJson(next, cur)) return { ok: true, changed: false, file: f };
  if (!writeHostJson(f, cur, next, 'codex-hooks.json')) return { ok: false, file: f, msg: `${f} 在这期间被改过，没写；再跑一次` };
  return { ok: true, changed: true, file: f };
}
export function codexUninstall() {
  const f = hooksFile();
  const cur = readHostJson(f);
  if (!cur || !JSON.stringify(cur).includes('vibetrail-hook')) return { ok: true, changed: false, file: f };
  const next = stripOurs(structuredClone(cur));
  if (!writeHostJson(f, cur, next, 'codex-hooks.json')) return { ok: false, file: f, msg: `${f} 在这期间被改过，没写；再跑一次` };
  return { ok: true, changed: true, file: f };
}
// 信任记录的 key 与哈希，照 Codex：hooks/src/lib.rs 的 hook_key；hooks/src/engine/discovery.rs 的 hook_hash + config/src/fingerprint.rs 的 version_for_toml——
// {event_name, matcher?, hooks: [这一条 handler，async 缺省补 false]} 按键名递归排序、紧凑 JSON、sha256。09-17 拿本机用户刚信任的 5 条真实记录核过，全部对上
export const codexTrustKey = (ev, gi, hi) => `${hooksFile()}:${LABEL[ev] ?? ev}:${gi}:${hi}`;
const canonJson = (v) => (Array.isArray(v) ? v.map(canonJson) : isObj(v) ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, canonJson(v[k])])) : v);
export function codexHookHash(ev, group, handler) {
  const identity = { event_name: LABEL[ev] ?? ev, ...(typeof group?.matcher === 'string' ? { matcher: group.matcher } : {}), hooks: [{ async: false, ...handler }] };
  return 'sha256:' + sha256(JSON.stringify(canonJson(identity)));
}
function trustStateOf(toml, key) {                    // [hooks.state."<key>"] 这张表里的 trusted_hash 与 enabled
  const i = toml.indexOf(`[hooks.state."${key}"]`);
  if (i < 0) return {};
  const body = [];
  for (const l of toml.slice(i).split('\n').slice(1)) { if (/^\s*\[/.test(l)) break; body.push(l); }
  const txt = body.join('\n');
  const th = txt.match(/^\s*trusted_hash\s*=\s*"([^"]*)"/m), en = txt.match(/^\s*enabled\s*=\s*(true|false)/m);
  return { ...(th ? { trusted_hash: th[1] } : {}), ...(en ? { enabled: en[1] === 'true' } : {}) };
}
// 我们在 hooks.json 里每一条在 Codex 里的信任状态：trusted / untrusted / modified（信任过、条目改过）/ disabled（在 Codex 里被关掉）
export function codexTrustStatus() {
  const doc = readHostJson(hooksFile());
  if (!doc || !isObj(doc.hooks)) return [];
  const toml = readText(path.join(codexHome(), 'config.toml')) || '';
  const out = [];
  for (const [ev, groups] of Object.entries(doc.hooks)) {
    (Array.isArray(groups) ? groups : []).forEach((g, gi) => (Array.isArray(g?.hooks) ? g.hooks : []).forEach((h, hi) => {
      if (!isOurs(h?.command)) return;
      const key = codexTrustKey(ev, gi, hi), hash = codexHookHash(ev, g, h), st = trustStateOf(toml, key);
      out.push({ ev, key, hash, command: h.command,
        state: st.enabled === false ? 'disabled' : !st.trusted_hash ? 'untrusted' : st.trusted_hash === hash ? 'trusted' : 'modified' });
    }));
  }
  return out;
}

// init 引导信任（用户 09-17 定：选了 Codex 就在 init 里问，同意了才写）。只加或替换我们自己那几张 [hooks.state."<key>"] 表里的 trusted_hash，
// config.toml 其余内容与注释原样留着。表头的写法认不出来（带注释、写成内联表）就不写——宁可不写，也不能写出重复的键把 Codex 的配置弄坏
const tomlHeader = (key) => `[hooks.state."${key}"]`;
function tomlTable(text, key) {                        // 表头那一行到下一个表头之前
  const lines = text.split('\n');
  const i = lines.findIndex((l) => l.trim() === tomlHeader(key));
  let j = i + 1;
  if (i >= 0) while (j < lines.length && !/^\s*\[/.test(lines[j])) j++;
  return { lines, i, j };
}
export function codexWriteTrust(entries) {
  const file = path.join(codexHome(), 'config.toml');
  const before = readText(file) ?? '';
  let text = before;
  for (const x of entries) {
    const { lines, i, j } = tomlTable(text, x.key);
    if (i < 0) {
      if (text.includes(`"${x.key}"`)) return { ok: false, file, msg: `${file} 里 ${x.ev} 的信任记录写法认不出来，没写；到「设置 → 钩子」里信任` };
      text = `${text}${text === '' || text.endsWith('\n') ? '' : '\n'}\n${tomlHeader(x.key)}\ntrusted_hash = "${x.hash}"\n`;
      continue;
    }
    const k = lines.slice(i + 1, j).findIndex((l) => /^\s*trusted_hash\s*=/.test(l));
    if (k >= 0) lines[i + 1 + k] = `trusted_hash = "${x.hash}"`; else lines.splice(i + 1, 0, `trusted_hash = "${x.hash}"`);
    text = lines.join('\n');
  }
  if (text === before) return { ok: true, changed: false, file };
  if (!writeTextGuarded(file, before, text, 'codex-config.toml')) return { ok: false, file, msg: `${file} 在这期间被改过（Codex 开着时也会写它），没写；再跑一次` };
  return { ok: true, changed: true, file };
}
// 卸载或不再选 Codex 时删掉我们的信任记录：只删哈希与我们当前条目对得上的那几张表，要在删 hooks.json 条目之前调
export function codexRemoveTrust() {
  const file = path.join(codexHome(), 'config.toml');
  const before = readText(file);
  if (before === null) return { ok: true, changed: false, file };
  let text = before;
  for (const x of codexTrustStatus()) {
    if (x.state !== 'trusted') continue;
    const { lines, i, j } = tomlTable(text, x.key);
    if (i < 0) continue;
    const from = i > 0 && lines[i - 1].trim() === '' ? i - 1 : i;
    lines.splice(from, j - from);
    text = lines.join('\n');
  }
  if (text === before) return { ok: true, changed: false, file };
  if (!writeTextGuarded(file, before, text, 'codex-config.toml')) return { ok: false, file, msg: `${file} 在这期间被改过，没改；再跑一次` };
  return { ok: true, changed: true, file };
}

export function codexDoctor({ ok, bad, note }) {
  if (!codexPresent()) return;
  const f = hooksFile();
  const doc = readHostJson(f);
  if (doc === null) { bad(`Codex：${f} 不是合法的 JSON，Codex 会整份跳过它`); return; }
  const mine = [];
  for (const [ev, groups] of Object.entries(isObj(doc.hooks) ? doc.hooks : {})) {
    (Array.isArray(groups) ? groups : []).forEach((g, gi) => (Array.isArray(g?.hooks) ? g.hooks : []).forEach((h, hi) => { if (isOurs(h?.command)) mine.push({ ev, gi, hi, h }); }));
  }
  if (mine.length === 0) { note(`Codex：${f} 里没有 vibetrail 的条目，Codex 的会话不采（要采就重跑 vibetrail init）`); return; }
  const missing = CODEX_EVENTS.filter((ev) => !mine.some((m) => m.ev === ev));
  if (missing.length) bad(`Codex：缺 ${missing.join(' ')} 的条目——重跑 vibetrail init`);
  const drift = mine.filter((m) => m.h.command !== hookCommand('codex', m.ev) || m.h.timeout !== TIMEOUT[m.ev]);
  if (drift.length) note(`Codex：${drift.length} 条命令或超时与这一版不同（改过的条目要在 Codex 里重新信任）`);
  // 信任（hooks/src/engine/discovery.rs:655-700）：config.toml 的 [hooks.state."<hooks.json 路径>:<事件>:<组>:<条>"] 里 trusted_hash 与当前条目的哈希一致、
  // 且没被关掉（enabled = false）才跑。哈希照 Codex 自己的算法算（codexHookHash），不再只看「有没有记录」（Codex 09-17 意见 3）
  const status = codexTrustStatus();
  const pick = (s) => status.filter((x) => x.state === s).map((x) => x.ev);
  const disabled = pick('disabled'), untrusted = pick('untrusted'), modified = pick('modified');
  if (disabled.length) bad(`Codex：${disabled.join(' ')} 在 Codex 里被关掉了（enabled = false），不会跑`);
  if (untrusted.length) bad(`Codex：${untrusted.join(' ')} 还没在 Codex 里信任，不会跑——桌面版在「设置 → 钩子」里逐条点「信任」，CLI 里用 /hooks`);
  if (modified.length) bad(`Codex：${modified.join(' ')} 信任之后条目改过（哈希对不上），Codex 不会跑——到「设置 → 钩子」重新信任`);
  if (!disabled.length && !untrusted.length && !modified.length) ok(`Codex：${mine.length} 条 hook 都已信任，哈希与当前条目一致`);
  const feat = (toml.match(/^\[features\]\s*$([\s\S]*?)(?=^\[|(?![\s\S]))/m) || [])[1] || '';
  if (/^\s*(codex_)?hooks\s*=\s*false/m.test(feat)) bad('Codex：config.toml 里 [features] hooks = false，hook 整个关着');
}
