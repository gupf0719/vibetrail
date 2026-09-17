// vibetrail：Cursor 的采集（TODO G12）。~/.cursor/hooks.json 里挂的是 `vibetrail-hook cursor <事件>`。
//
// **这一版只用 hook 入参，不读 transcript。** Cursor 的 transcript（入参里的 transcript_path）格式与位置官方文档没写、本机没有样本，
// 和 Claude、Codex 的会话记录都不是一种东西，拿到样本前不猜格式（G12 §3 问题 4、§4 待实测）。
// 字段依据：Cursor 3.20.21 bundle 里的 hook 请求定义（extensions/cursor-local-agent-runtime）与官方 hooks 文档（09-17）。
// 每个事件都是 Cursor 同步等的：读完 stdin 先写应答、再丢后台，自己立刻退出。
import fs from 'node:fs';
import path from 'node:path';
import { VT_HOME, vtGitSnapshot, vtWriteJson } from './hook.mjs';
import { displayDir } from './map.mjs';
import {
  readText, readJson, isFile, isDir, mkdirp, nowIso, isObj, opt, sha256, capture, validSid, codeify, agentEnabled,
  gate, baseEvent, emit, vcsOf, commitsOf, turnStart, turnStop, turnGap, relFile, noteFile, filesOf,
  detach, hookCommand, isOurs, readHostJson, writeHostJson, sameJson,
} from './agents.mjs';

export const RULE = 'cursor-v1';
export const CURSOR_EVENTS = ['sessionStart', 'sessionEnd', 'beforeSubmitPrompt', 'stop', 'afterAgentResponse',
  'postToolUse', 'postToolUseFailure', 'afterFileEdit', 'subagentStart', 'subagentStop'];
const TIMEOUT = 10;
// usage 不声明：stop / afterAgentResponse 的请求定义里有 input / output / cache_read / cache_write 四个数，但缓存算不算在 input 里没核，
// 先原样放 extensions（cursor.usage_raw），实测定口径后再填 payload.usage
const CAPS = ['session.start', 'session.end', 'turn.start', 'turn.end', 'message.user', 'message.assistant', 'tool.request', 'tool.end',
  'subagent.start', 'subagent.end', 'vcs', 'file.relation'];

export const cursorHome = () => process.env.VIBETRAIL_CURSOR_HOME || path.join(process.env.HOME || '', '.cursor');
export const cursorPresent = () => isDir(cursorHome()) || (!process.env.VIBETRAIL_CURSOR_HOME && isDir('/Applications/Cursor.app'));
const hooksFile = () => path.join(cursorHome(), 'hooks.json');

const num = (x) => (typeof x === 'number' && Number.isFinite(x) && x >= 0 ? Math.round(x) : null);
const usageRaw = (p) => {
  const o = {};
  for (const k of ['input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens']) if (num(p[k]) !== null) o[k] = num(p[k]);
  return Object.keys(o).length ? o : null;
};
const safe = (s) => String(s).replace(/[^A-Za-z0-9._-]/g, '_').replace(/^\./, '_');

// 一轮里改过的文件：每次 afterFileEdit 一个小文件（并发的 hook 不互相覆盖），关轮时汇总
const filesDir = (sid, turn) => path.join(VT_HOME, 'state', sid, 'cursor-files', safe(turn));
function turnFiles(sid, turn) {
  const files = {};
  let names = []; try { names = fs.readdirSync(filesDir(sid, turn)); } catch { return null; }
  for (const n of names) {
    const [op, rel] = String(readText(path.join(filesDir(sid, turn), n)) || '').split('\t');
    if (rel) noteFile(files, rel.trim(), op);
  }
  return filesOf(files, 'hook');
}

export function runCursorHook(event, raw) {
  const p = (() => { try { return JSON.parse(raw); } catch { return null; } })();
  if (!isObj(p) || !CURSOR_EVENTS.includes(event)) return;
  const conv = String(p.conversation_id ?? p.session_id ?? '');
  if (!validSid(conv)) return;
  // 子 agent 自己会话里来的事件挂回父会话（subagentStart 时记下的指向；子 agent 的 hook 里 conversation_id 是谁的，待实测）
  const own = readJson(path.join(VT_HOME, 'state', conv, 'cursor.json'), {});
  const sid = own.parent && validSid(own.parent) ? own.parent : conv;
  const instance = own.parent ? (own.instance || conv) : 'main';
  const parentInstance = own.parent ? (own.parent_instance || 'main') : null;
  const SD = path.join(VT_HOME, 'state', sid);
  const sess = readJson(path.join(SD, 'cursor.json'), {});
  const roots = [...(Array.isArray(p.workspace_roots) ? p.workspace_roots : []), p.cwd].filter((x) => typeof x === 'string' && x);
  // 多根工作区：会话第一次见到时取第一个过门控的根，之后一直用它（G12 §7 暂定）
  const ctx = gate(sess.root ? [sess.root] : roots);
  if (!ctx) return;
  if (!mkdirp(SD)) return;
  if (!sess.root) vtWriteJson(path.join(SD, 'cursor.json'), { ...sess, agent: 'cursor', root: ctx.dir, updated_at: nowIso() });

  const agent = { name: 'cursor', version: p.cursor_version ?? null, surface: p.is_background_agent === true ? 'cloud' : null };
  const now = nowIso();
  const cap = capture();
  const dir = ctx.dir;
  const payloadKey = sha256(raw, 16);                  // hook 不重发：同一份入参到两次就是同一件事
  const lastTurn = () => (readText(path.join(SD, 'last_turn')) || '').trim();
  const gen = String(p.generation_id ?? '');
  const mk = (type, turn, extra = {}) => baseEvent(agent, ctx, { sid, type, at: now, turn: turn || null, instance, parentInstance,
    provenance: { kind: 'hook', source_event: event }, ...extra });
  const out = (events) => emit(ctx.pkey, sid, 'hook-' + event.toLowerCase(), events, event);
  // 没等到 stop 的轮（崩溃、关窗）：下一轮开始或会话结束时按 unknown 关
  const closeGap = (prev, snap) => {
    if (!prev) return [];
    const rec = turnGap(sid, prev, dir, snap, event);
    if (!rec) return [];
    const e = baseEvent(agent, ctx, { sid, type: 'turn.end', at: now, turn: prev, provenance: { kind: 'inferred', rule_version: RULE, source_event: event } });
    e.payload = { status: { code: 'unknown', category: 'unknown' }, ...opt('vcs', vcsOf(rec.vcs)) };
    const c = commitsOf(rec); if (c) e.commits = c;
    const files = turnFiles(sid, prev); if (files) e.files = files;
    e.extensions['vibetrail.end_evidence'] = event;
    e._key = `${prev}|turn.end`;
    return [e];
  };

  switch (event) {
    case 'sessionStart': {
      if (instance !== 'main') break;
      const snap = vtGitSnapshot(dir);
      const e = mk('session.start', null);
      e.payload = { source: 'startup', capabilities: CAPS };
      e.extensions = { ...e.extensions, ...opt('cursor.session_id', p.session_id !== conv ? p.session_id : null), ...opt('cursor.composer_mode', p.composer_mode),
        ...opt('cursor.model', p.model), ...opt('vibetrail.vcs', vcsOf(snap)), ...opt('vibetrail.cwd', displayDir(dir, ctx.roots)) };
      e._key = `session.start|${payloadKey}`;
      out([e]);
      break;
    }
    case 'beforeSubmitPrompt': {
      if (!gen) break;
      const evs = [];
      const again = isFile(path.join(VT_HOME, 'state', sid, 'turns', `${safe(gen)}.start.json`));
      if (instance === 'main') {
        const snap = vtGitSnapshot(dir);
        const prev = lastTurn();
        if (prev && prev !== gen) evs.push(...closeGap(prev, snap));
        turnStart(sid, gen, snap);
        fs.writeFileSync(path.join(SD, 'last_turn'), gen + '\n');
        const e = mk('turn.start', gen);
        e.payload = { ...opt('model', p.model), ...opt('vcs', vcsOf(snap)) };
        e.extensions = { ...e.extensions, ...opt('cursor.composer_mode', p.composer_mode), ...opt('vibetrail.dirty_files', snap?.dirty_files) };
        e._key = `${gen}|turn.start`;
        evs.push(e);
      }
      const prompt = typeof p.prompt === 'string' ? p.prompt : '';
      const m = mk('message.user', gen);
      const inc = cap && prompt.length > 0;
      m.content_state = inc ? 'included' : 'omitted';
      m.payload = { author_type: instance === 'main' ? 'human' : 'agent', delivery: instance !== 'main' ? 'injected' : again ? 'queued' : 'direct', ...(inc ? { text: prompt } : {}) };
      if (Array.isArray(p.attachments) && p.attachments.length) m.extensions['cursor.attachments'] = p.attachments.length;
      m._key = `${gen}|message.user|${payloadKey}`;
      evs.push(m);
      out(evs);
      break;
    }
    case 'afterAgentResponse': {
      const turn = gen || lastTurn();
      if (!turn) break;
      const text = typeof p.text === 'string' ? p.text : '';
      const e = mk('message.assistant', turn);
      const inc = cap && text.length > 0;
      e.content_state = inc ? 'included' : 'omitted';
      e.payload = { author_type: 'agent', ...opt('model', p.model), ...(inc ? { text } : {}) };
      e.extensions['vibetrail.call'] = { kind: 'llm', ...opt('usage_raw', usageRaw(p)) };
      e._key = `${turn}|llm|${payloadKey}`;
      out([e]);
      break;
    }
    case 'postToolUse': case 'postToolUseFailure': {
      const turn = gen || lastTurn();
      if (!turn) break;
      const cid = String(p.tool_use_id ?? '') || `nocall-${payloadKey}`;
      const name = String(p.tool_name ?? 'unknown');
      const evs = [];
      if (cap && p.tool_input !== undefined && p.tool_input !== null) {
        const r = mk('tool.request', turn);
        r.content_state = 'included';
        r.payload = { tool_name: name, call_id: cid, input: p.tool_input };
        r._key = `${cid}|tool.request`;
        evs.push(r);
      }
      const failure = event === 'postToolUseFailure';
      const d = num(p.duration_ms ?? p.duration);
      const output = failure ? p.error_message : p.tool_output;
      const e = mk('tool.end', turn);
      e.content_state = cap ? 'included' : 'omitted';
      // is_interrupt 是按停止打断的调用；failure_type 取值没核（人在审批框里拒绝走不走这里，待实测），原样放 extensions，不据此判人拒
      e.payload = { tool_name: name, call_id: cid,
        status: !failure ? { code: 'succeeded', category: 'success' } : p.is_interrupt === true ? { code: 'cancelled', category: 'cancellation' } : { code: 'failed', category: 'failure' },
        ...opt('duration_ms', d), ...(cap && output !== undefined && output !== null && output !== '' ? { output } : {}) };
      if (d !== null) e.extensions['vibetrail.duration_kind'] = 'reported';
      if (failure) e.extensions = { ...e.extensions, ...opt('cursor.failure_type', p.failure_type), ...(p.is_interrupt === true ? { 'cursor.is_interrupt': true } : {}) };
      e._key = `${cid}|tool.end`;
      evs.push(e);
      out(evs);
      break;
    }
    case 'afterFileEdit': {
      const turn = gen || lastTurn();
      const rel = relFile(p.file_path, ctx.roots, dir);
      if (!turn || !rel) break;                         // 根外的文件没有协议表达法（K2），不记
      mkdirp(filesDir(sid, turn));
      try { fs.writeFileSync(path.join(filesDir(sid, turn), sha256(rel, 16)), `modify\t${rel}\n`); } catch {}
      break;
    }
    case 'subagentStart': {
      const child = String(p.subagent_id ?? '');
      const turn = gen || lastTurn();
      if (!validSid(child) || !turn) break;
      vtWriteJson(path.join(VT_HOME, 'state', child, 'cursor.json'), { agent: 'cursor', parent: sid, instance: child, parent_instance: instance, turn, updated_at: now });
      const task = typeof p.task === 'string' ? p.task : '';
      const e = baseEvent(agent, ctx, { sid, type: 'subagent.start', at: now, turn, instance: child, parentInstance: instance,
        parentCall: p.tool_call_id ?? null, provenance: { kind: 'hook', source_event: event } });
      e.content_state = cap && task ? 'included' : 'omitted';
      e.payload = { agent_type: String(p.subagent_type ?? 'unknown'), ...(cap && task ? { task } : {}) };
      e.extensions = { ...e.extensions, ...opt('cursor.subagent_model', p.subagent_model), ...(p.is_parallel_worker === true ? { 'cursor.parallel_worker': true } : {}) };
      e._key = `${child}|subagent.start`;
      out([e]);
      break;
    }
    case 'subagentStop': {
      const child = String(p.subagent_id ?? '');
      if (!validSid(child)) break;
      const cs = readJson(path.join(VT_HOME, 'state', child, 'cursor.json'), {});
      const turn = cs.turn || gen || lastTurn();
      if (!turn) break;
      const st = String(p.status ?? '').toLowerCase();
      const summary = typeof p.summary === 'string' ? p.summary : '';
      const e = baseEvent(agent, ctx, { sid, type: 'subagent.end', at: now, turn, instance: child, parentInstance: cs.parent_instance || 'main',
        provenance: { kind: 'hook', source_event: event } });
      e.content_state = cap && summary ? 'included' : 'omitted';
      e.payload = { ...opt('agent_type', p.subagent_type),
        status: st === 'completed' ? { code: 'completed', category: 'success' }
          : st === 'aborted' || st === 'cancelled' ? { code: 'cancelled', category: 'cancellation', detail: st }
          : st === 'error' || st === 'failed' ? { code: 'failed', category: 'failure' } : { code: st ? codeify(st) : 'unknown', category: 'unknown' },
        ...(cap && summary ? { last_message: summary } : {}) };
      const files = {};
      for (const f of Array.isArray(p.modified_files) ? p.modified_files : []) noteFile(files, relFile(typeof f === 'string' ? f : f?.path, ctx.roots, dir), 'modify');
      const fl = filesOf(files, 'hook'); if (fl) e.files = fl;
      e.extensions = { ...e.extensions, ...opt('cursor.duration_ms', num(p.duration_ms)), ...opt('cursor.tool_call_count', num(p.tool_call_count)), ...opt('cursor.message_count', num(p.message_count)) };
      e._key = `${child}|subagent.end|${payloadKey}`;
      out([e]);
      break;
    }
    case 'stop': {
      if (instance !== 'main') break;                   // 子 agent 的结束由 subagentStop 表达
      const turn = gen || lastTurn();
      if (!turn) break;
      const snap = vtGitSnapshot(dir);
      const rec = turnStop(sid, turn, dir, snap, { status: p.status ?? null });
      const st = String(p.status ?? '').toLowerCase();
      const e = mk('turn.end', turn);
      // aborted 是不是人按了停止没核，先不标分歧（G12 §4）
      e.payload = { status: st === 'completed' ? { code: 'completed', category: 'success' } : st === 'aborted' ? { code: 'aborted', category: 'cancellation' }
        : st === 'error' ? { code: 'error', category: 'failure' } : { code: 'unknown', category: 'unknown' }, ...opt('model', p.model), ...opt('vcs', vcsOf(snap)) };
      const c = commitsOf(rec); if (c) e.commits = c;
      const files = turnFiles(sid, turn); if (files) e.files = files;
      e.extensions = { ...e.extensions, 'vibetrail.end_evidence': 'stop', ...opt('cursor.loop_count', num(p.loop_count)), ...opt('cursor.usage_raw', usageRaw(p)),
        ...opt('vibetrail.commit_method', rec?.commit_method) };
      e._key = `${turn}|turn.end`;                      // 同一轮再来 stop（别的 hook 让它续跑）时先写的留下
      out([e]);
      break;
    }
    case 'sessionEnd': {
      if (instance !== 'main') break;
      const snap = vtGitSnapshot(dir);
      const evs = closeGap(lastTurn(), snap);
      const fsx = String(p.final_status ?? '').toLowerCase();
      const e = mk('session.end', null);
      e.payload = { reason: codeify(p.reason ?? 'unknown'),
        status: fsx === 'error' || fsx === 'failed' ? { code: 'failed', category: 'failure' } : fsx === 'aborted' || fsx === 'cancelled' ? { code: 'cancelled', category: 'cancellation' } : { code: 'completed', category: 'success' } };
      e.extensions = { ...e.extensions, ...opt('cursor.duration_ms', num(p.duration_ms)), ...opt('vibetrail.vcs', vcsOf(snap)) };
      e._key = `session.end|${payloadKey}`;
      evs.push(e);
      out(evs);
      break;
    }
    default: break;
  }
  return ['sessionStart', 'stop', 'sessionEnd'].includes(event) ? `cursor:${event}` : '';   // 这三处跑完就推（autoPush，D15）；调工具的那几个 hook 不推
}

// Cursor 同步等每个 hook：先写应答（beforeSubmitPrompt 要 continue，其余空对象），再丢后台。
// macOS 上 process.stdout 写管道是异步的，退出前可能没写出去，所以用 fs.writeSync
const RESPONSE = { beforeSubmitPrompt: '{"continue":true}' };
export async function hookEntry(cmd, event, payload, entry) {
  if (cmd === 'hook') { try { fs.writeSync(1, (RESPONSE[event] ?? '{}') + '\n'); } catch {} }
  if (!agentEnabled('cursor')) return;                 // init 时没选 Cursor、条目却还在（手改过）：不采
  if (cmd === 'hook' && process.env.VIBETRAIL_FOREGROUND !== '1') { detach(entry, 'cursor', event, payload); return; }
  return runCursorHook(event, payload);
}

// ---------- 安装 / 卸载 / 自检：~/.cursor/hooks.json（{version: 1, hooks: {事件: [{command, timeout}]}}） ----------
function stripOurs(doc) {
  const out = { ...doc };
  if (!isObj(doc.hooks)) return out;
  const hooks = {};
  for (const [ev, list] of Object.entries(doc.hooks)) {
    if (!Array.isArray(list)) { hooks[ev] = list; continue; }
    const kept = list.filter((h) => !isOurs(h?.command));
    if (kept.length > 0 || list.length === 0) hooks[ev] = kept;   // 别人留下的空数组原样留着
  }
  out.hooks = hooks;
  return out;
}
export function cursorInstall() {
  const f = hooksFile();
  const cur = readHostJson(f);
  if (cur === null) return { ok: false, file: f, msg: `读不懂 ${f}（不是合法的 JSON 对象），没改` };
  const next = stripOurs(structuredClone(cur));
  if (next.version === undefined) next.version = 1;
  next.hooks = isObj(next.hooks) ? next.hooks : {};
  for (const ev of CURSOR_EVENTS) next.hooks[ev] = [...(Array.isArray(next.hooks[ev]) ? next.hooks[ev] : []), { command: hookCommand('cursor', ev), timeout: TIMEOUT }];
  if (sameJson(next, cur)) return { ok: true, changed: false, file: f };
  if (!writeHostJson(f, cur, next, 'cursor-hooks.json')) return { ok: false, file: f, msg: `${f} 在这期间被改过，没写；再跑一次` };
  return { ok: true, changed: true, file: f };
}
export function cursorUninstall() {
  const f = hooksFile();
  const cur = readHostJson(f);
  if (!cur || !JSON.stringify(cur).includes('vibetrail-hook')) return { ok: true, changed: false, file: f };
  const next = stripOurs(structuredClone(cur));
  if (!writeHostJson(f, cur, next, 'cursor-hooks.json')) return { ok: false, file: f, msg: `${f} 在这期间被改过，没写；再跑一次` };
  return { ok: true, changed: true, file: f };
}
export function cursorDoctor({ ok, bad, note }) {
  const f = hooksFile();
  const doc = readHostJson(f);
  if (doc === null) { bad(`Cursor：${f} 不是合法的 JSON`); return; }
  const have = CURSOR_EVENTS.filter((ev) => (Array.isArray(doc.hooks?.[ev]) ? doc.hooks[ev] : []).some((h) => isOurs(h?.command)));
  if (have.length === 0) { note(`Cursor：${f} 里没有 vibetrail 的条目，Cursor 的会话不采（要采就重跑 vibetrail init）`); return; }
  if (have.length < CURSOR_EVENTS.length) bad(`Cursor：缺 ${CURSOR_EVENTS.filter((ev) => !have.includes(ev)).join(' ')} 的条目——重跑 vibetrail init`);
  else ok(`Cursor：${have.length} 个事件的条目都在（${f}）`);
  for (const ent of ['/Library/Application Support/Cursor/hooks.json', '/etc/cursor/hooks.json']) {
    if (!process.env.VIBETRAIL_CURSOR_HOME && isFile(ent)) note(`Cursor：有企业下发的 hook（${ent}），优先级比用户级高，留意它会不会拦下或改写我们要的事件`);
  }
}
