// vibetrail：hook 分发入口与共用函数（DESIGN D12 ② 的移植）。
// 由 vibetrail-hook（362 行）+ vibetrail-lib.sh（219 行）+ vibetrail-map（176 行）+ hook-events.jq（101 行）1:1 翻译而来。
// **换语言不换设计**：磁盘上的一切不变——spool 块文件名、state 的每个字段、config、登记表、event_id 的算法、协议事件的每个字段。
//
// 纪律（DESIGN §3.4，照旧）：stdout 永远为空、永远 exit 0、失败只往 errors.log 记元数据；
// scope=project 时未登记的仓什么都不写（A8 零写入）。
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync, spawn } from 'node:child_process';
import { mapRecords } from './map.mjs';

export const VT_RUNTIME_VERSION = '0.2.0-dev';
const VT_NS = '6c90e594-0cb4-59d0-9186-740d215c8b7f';   // uuid5(NS_URL, "vibetrail")，DESIGN §4.2
const MAX_READ_BYTES = 50 * 1024 * 1024;                // 单次最多读 50 MB（照 Pilot 的 MAX_TRANSCRIPT_BYTES，全采后更要紧）

export const VT_HOME = process.env.VIBETRAIL_HOME || path.join(process.env.HOME || '', '.vibetrail');
const claudeDir = () => process.env.CLAUDE_CONFIG_DIR || path.join(process.env.HOME || '', '.claude');
export const settingsPath = () => process.env.VIBETRAIL_CLAUDE_SETTINGS || path.join(claudeDir(), 'settings.json');
export const claudeProjects = () => process.env.VIBETRAIL_CLAUDE_PROJECTS || path.join(claudeDir(), 'projects');

// ---------- 小工具 ----------
const readText = (p) => { try { return fs.readFileSync(p, 'utf8'); } catch { return null; } };
const readJson = (p, dflt) => { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return dflt; } };
const exists = (p) => { try { fs.accessSync(p); return true; } catch { return false; } };
const isFile = (p) => { try { return fs.statSync(p).isFile(); } catch { return false; } };
const isDir = (p) => { try { return fs.statSync(p).isDirectory(); } catch { return false; } };
const mkdirp = (p) => { try { fs.mkdirSync(p, { recursive: true }); return true; } catch { return false; } };
const sha1 = (buf) => crypto.createHash('sha1').update(buf).digest('hex');
const nowIso = () => new Date().toISOString();                       // 与 jq 版同形状：毫秒 + Z
const epochSec = () => Math.floor(Date.now() / 1000);

export function vtConf(key, dflt = '') {
  const txt = readText(path.join(VT_HOME, 'config'));
  if (txt === null) return dflt;
  let v = '';
  for (const line of txt.split('\n')) if (line.startsWith(key + '=')) v = line.slice(key.length + 1);
  return v === '' ? dflt : v;
}
export const vtSha = (s) => sha1(Buffer.from(String(s), 'utf8')).slice(0, 16);
export const vtSlug = (p) => String(p).replace(/[^A-Za-z0-9]/g, '-');
export const vtRealpath = (p) => { try { return fs.realpathSync(p); } catch { return p; } };

const git = (dir, args, { timeout = 0 } = {}) => {
  try {
    return execFileSync('git', ['-C', dir, ...args], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
      env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' },   // git status 会写回 .git/index，被观测仓零写入不许
      ...(timeout ? { timeout } : {}),
    }).replace(/\n$/, '');
  } catch { return null; }
};

export function vtMainCheckout(dir) {          // git worktree list 第一条；不在 git 仓里返回 null
  const out = git(dir, ['worktree', 'list', '--porcelain']);
  if (out === null) return null;
  const m = out.split('\n').find((l) => l.startsWith('worktree '));
  return m ? vtRealpath(m.slice('worktree '.length)) : null;
}
export const vtProjectKey = (main) => `${path.basename(main).replace(/[^A-Za-z0-9._-]/g, '_')}-${vtSha(main)}`;
export const vtRegistered = (main) => isFile(path.join(VT_HOME, 'projects', vtSha(main)));
export function vtRegister(dir) {
  const m = vtMainCheckout(dir);
  if (!m) return null;
  mkdirp(path.join(VT_HOME, 'projects'));
  fs.writeFileSync(path.join(VT_HOME, 'projects', vtSha(m)), m + '\n');
  return m;
}
export function vtUnregister(dir) {
  const m = vtMainCheckout(dir);
  if (!m) return null;
  try { fs.unlinkSync(path.join(VT_HOME, 'projects', vtSha(m))); } catch {}
  return m;
}
export function vtLogError(event, sid, stage, rc = 0) {   // 只记元数据，不留 payload
  try {
    mkdirp(path.join(VT_HOME, 'logs'));
    fs.appendFileSync(path.join(VT_HOME, 'logs', 'errors.log'),
      JSON.stringify({ time: new Date().toISOString().replace(/\.\d+Z$/, 'Z'), event, session_id: sid, stage, rc }) + '\n');
  } catch {}
}
export function vtLock(dir) {                  // mkdir 原子锁；陈旧 300 s 回收
  const l = path.join(dir, '.lock');
  try { fs.mkdirSync(l); return true; } catch {}
  let age = 0;
  try { age = epochSec() - Math.floor(fs.statSync(l).mtimeMs / 1000); } catch { age = 0; }
  if (age > 300) { try { fs.rmdirSync(l); fs.mkdirSync(l); return true; } catch {} }
  return false;
}
export const vtUnlock = (dir) => { try { fs.rmdirSync(path.join(dir, '.lock')); } catch {} };

export function vtFprint(file, n) {            // "inode:开头 4 KB 的 sha1:消费位置前 4 KB 的 sha1"（offset 信任检查）
  let ino;
  try { ino = fs.statSync(file).ino; } catch { return null; }
  const fd = fs.openSync(file, 'r');
  try {
    const s1 = n > 4096 ? 4096 : n;
    const b1 = Buffer.alloc(Math.max(s1, 0));
    if (s1 > 0) fs.readSync(fd, b1, 0, s1, 0);
    const off = n > 4096 ? n - 4096 : 0;
    const len = n - off;
    const b2 = Buffer.alloc(Math.max(len, 0));
    if (len > 0) fs.readSync(fd, b2, 0, len, off);
    return `${ino}:${sha1(b1)}:${sha1(b2)}`;
  } finally { fs.closeSync(fd); }
}

// event_id = UUIDv5(uuid5(NS_URL, "vibetrail"), "<sid>|<_key>")。与 bash 版逐位一致（test-map 有 python uuid5 交叉验证）
export function eventId(sid, key) {
  const ns = Buffer.from(VT_NS.replace(/-/g, ''), 'hex');
  const h = sha1(Buffer.concat([ns, Buffer.from(`${sid}|${key}`, 'utf8')]));
  const variant = ((parseInt(h[16], 16) % 4) + 8).toString(16);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-5${h.slice(13, 16)}-${variant}${h.slice(17, 20)}-${h.slice(20, 32)}`;
}
export function vtFillIds(sid, events) {       // 填 event_id、删 _key；同一 _key 出现两次是映射层的错
    const seen = new Set();
    const out = [];
    for (const e of events) {
      if (e._key === undefined || e._key === null) { out.push(e); continue; }
      if (seen.has(e._key)) throw new Error(`事件 _key 重复: ${e._key}`);
      seen.add(e._key);
      const { _key, ...rest } = e;
      out.push({ ...rest, event_id: eventId(sid, _key) });
    }
    // 字段顺序照 jq 版：event_id 在最前
    return out.map((e) => (e.event_id ? { event_id: e.event_id, ...e } : e));
}

export function vtSpoolWrite(pkey, sid, name, events) {   // 去掉已写过的 event_id，余下的写成一块（临时文件 + rename）
  const sd = path.join(VT_HOME, 'state', sid);
  if (!mkdirp(sd)) return false;
  const idsFile = path.join(sd, 'ids');
  const seen = new Set((readText(idsFile) || '').split('\n').filter(Boolean));
  const fresh = events.filter((e) => !(e.event_id && seen.has(e.event_id)));
  if (fresh.length === 0) return true;
  const dest = path.join(VT_HOME, 'spool', pkey, sid);
  if (!mkdirp(dest)) return false;
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
  const chunk = `${stamp}-${process.pid}-${name}.jsonl`;
  const body = fresh.map((e) => JSON.stringify(e)).join('\n') + '\n';
  try {
    fs.writeFileSync(path.join(dest, '.' + chunk + '.tmp'), body);
    fs.renameSync(path.join(dest, '.' + chunk + '.tmp'), path.join(dest, chunk));
    fs.appendFileSync(idsFile, fresh.map((e) => e.event_id).filter(Boolean).join('\n') + '\n');
    return true;
  } catch { return false; }
}

export function vtGitSnapshot(dir) {           // {head_sha, branch, dirty, dirty_files, worktree, at_epoch}；不在 git 仓里给 null
  const top = git(dir, ['rev-parse', '--show-toplevel']);
  if (top === null) return null;
  const head = git(dir, ['rev-parse', '-q', '--verify', 'HEAD']);
  const branch = git(dir, ['symbolic-ref', '-q', '--short', 'HEAD']);
  const snap = { worktree: top, at_epoch: epochSec() };
  if (head) snap.head_sha = head;
  if (branch) snap.branch = branch;
  const stx = git(dir, ['status', '--porcelain=v1', '-z', '--untracked-files=normal'], { timeout: 3000 });  // 超时就不报脏否
  if (stx !== null) {
    const n = stx.split('\0').filter((x) => x !== '').length;
    snap.dirty = n > 0; snap.dirty_files = n;
  }
  return snap;
}

export function vtCommits(dir, startHead, since) {   // 本轮 commit（DESIGN §3.5）：rev-list 起..止，rebase / reset 靠 reflog 补
  if (!startHead) return null;
  const end = git(dir, ['rev-parse', '-q', '--verify', 'HEAD']);
  if (!end) return null;
  const reflog = git(dir, ['reflog', '--date=unix', '--format=%gd%x09%H%x09%gs', 'HEAD']) || '';
  const tips = [];
  for (const line of reflog.split('\n')) {
    if (!line) continue;
    const [gd, sha, gs] = line.split('\t');
    const t = Number(String(gd).replace(/^.*@\{/, '').replace(/\}$/, ''));
    if (!Number.isFinite(t) || t < Number(since || 0)) break;
    if (/^(commit|cherry-pick|revert|merge|rebase|pull|am)/.test(gs || '')) tips.push(sha);
  }
  const uniqTips = [...new Set(tips)].sort();
  const list = git(dir, ['rev-list', '--reverse', '-n', '256', end, ...uniqTips, '^' + startHead]);
  if (list === null) return null;
  const base = git(dir, ['rev-list', '--reverse', '-n', '256', end, '^' + startHead]);
  const method = list === base ? 'rev-list' : 'reflog';
  return { commits: list.split('\n').filter((s) => /^[0-9a-f]{40,64}$/.test(s)), method };
}

export const vtTurnFile = (sid, turnId, kind) => {
  let t = String(turnId).replace(/[^A-Za-z0-9._-]/g, '_').replace(/^\./, '');
  return path.join(VT_HOME, 'state', sid, 'turns', `${t}.${kind}.json`);
};
export function vtWriteJson(p, obj) {
  mkdirp(path.dirname(p));
  const tmp = `${p}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(obj) + '\n');
  fs.renameSync(tmp, p);
}
export function vtHookTurns(sid) {             // {<turn_id>: {start, stop, gap, fail}}
  const dir = path.join(VT_HOME, 'state', sid, 'turns');
  const out = {};
  let names = [];
  try { names = fs.readdirSync(dir).filter((f) => f.endsWith('.json')); } catch { return out; }
  for (const f of names.sort()) {
    const m = f.replace(/\.json$/, '').match(/^(?<id>.*)\.(?<k>start|stop|gap|fail)$/);
    if (!m) continue;
    const v = readJson(path.join(dir, f), null);
    if (v === null) continue;
    (out[m.groups.id] ||= {})[m.groups.k] = v;
  }
  return out;
}
export function vtHookPerms(sid) {
  const dir = path.join(VT_HOME, 'state', sid, 'perms');
  let names = [];
  try { names = fs.readdirSync(dir).filter((f) => f.endsWith('.json')); } catch { return []; }
  return names.sort().map((f) => readJson(path.join(dir, f), null)).filter((v) => v !== null && typeof v === 'object' && !Array.isArray(v));
}
// K15④：PermissionRequest 挂上过的时间段，config 里一行 permission_request_periods=<since>-<until>,<since>-（最后一段没结束就空着）。
// 老安装只有 permission_request_since=<t>：当成一段从 t 起、还没结束的
export function vtPermPeriods() {
  const raw = vtConf('permission_request_periods', '');
  if (raw) {
    return raw.split(',').map((x) => x.trim()).filter(Boolean).map((x) => {
      const [a, b] = x.split('-');
      return [Number(a), b === undefined || b === '' ? null : Number(b)];
    }).filter(([a]) => Number.isFinite(a) && a > 0);
  }
  const since = Number(vtConf('permission_request_since', ''));
  return since > 0 ? [[since, null]] : [];
}
export const formatPermPeriods = (ps) => ps.map(([a, b]) => `${a}-${b === null || b === undefined ? '' : b}`).join(',');

// K15④ 方案 A：每条拒绝第一次判出的「人拒绝 / 按停止」存在 state/<sid>/splits.json，重读沿用、不重算。
// 与 ids 一样是「只写一次」的历史：uninstall 留着它（K14），补做清陈旧 state 时跟整个目录一起走
export const vtSplits = (sid) => { const v = readJson(path.join(VT_HOME, 'state', sid, 'splits.json'), {}); return v && typeof v === 'object' && !Array.isArray(v) ? v : {}; };
export function vtSplitsSave(sid, fresh) {
  if (!fresh || Object.keys(fresh).length === 0) return true;
  try {
    const cur = vtSplits(sid);
    for (const [k, v] of Object.entries(fresh)) if (!(k in cur)) cur[k] = v;   // 已有的不覆盖：结论只判一次
    vtWriteJson(path.join(VT_HOME, 'state', sid, 'splits.json'), cur);
    return true;
  } catch { return false; }
}

// 09-16 起子 agent 的起止从 transcript 推（不再挂 SubagentStart / SubagentStop）。state/<sid>/agents.json：
//   launched   {agentId: {call_id, agent_type}}：后台派出的 agent（很多没有自己的 transcript 文件，之后的 <task-notification> 靠它认）
//   done       {agentId: 完成信号的时间}；calls_done {派它的调用 id: 调用结果的时间}（同步 agent 出错时拿不到 agentId）
// 只增不改：launched 已有的不覆盖，时间取较晚的
const objOr = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? v : {});
export const vtAgents = (sid) => {
  const v = objOr(readJson(path.join(VT_HOME, 'state', sid, 'agents.json'), {}));
  return { launched: objOr(v.launched), done: objOr(v.done), calls_done: objOr(v.calls_done) };
};
export function vtAgentsSave(sid, fresh) {
  if (!fresh) return true;
  const cur = vtAgents(sid);
  let changed = false;
  for (const [k, v] of Object.entries(objOr(fresh.launched))) if (!(k in cur.launched)) { cur.launched[k] = v; changed = true; }
  for (const m of ['done', 'calls_done']) {
    for (const [k, v] of Object.entries(objOr(fresh[m]))) if (typeof v === 'string' && !(typeof cur[m][k] === 'string' && cur[m][k] >= v)) { cur[m][k] = v; changed = true; }
  }
  if (!changed) return true;
  try { vtWriteJson(path.join(VT_HOME, 'state', sid, 'agents.json'), cur); return true; } catch { return false; }
}
// 一个 subagents 目录里的子 agent：{agentId: {call_id, agent_type}}（meta.json 里的 toolUseId / agentType；没有 meta 的只有 id）
export function vtKnownAgents(subDir) {
  const out = {};
  let names = [];
  try { names = fs.readdirSync(subDir); } catch { return out; }
  for (const f of names.sort()) {
    const m = f.match(/^agent-(.+)\.(jsonl|meta\.json)$/);
    if (!m) continue;
    out[m[1]] ||= {};
    if (m[2] !== 'meta.json') continue;
    const mm = objOr(readJson(path.join(subDir, f), {}));
    if (typeof mm.toolUseId === 'string' && mm.toolUseId) out[m[1]].call_id = mm.toolUseId;
    if (typeof mm.agentType === 'string' && mm.agentType) out[m[1]].agent_type = mm.agentType;
  }
  return out;
}

export function vtPruneRemoved() {             // projects remove --drop 挪出去的数据留一天
  const dir = path.join(VT_HOME, 'removed');
  if (!isDir(dir)) return;
  const cutoff = Date.now() - 86400 * 1000;
  for (const f of fs.readdirSync(dir)) {
    const p = path.join(dir, f);
    try { if (fs.statSync(p).mtimeMs < cutoff) fs.rmSync(p, { recursive: true, force: true }); } catch {}
  }
}
export function vtAgentVersion(tpath) {        // 先看 AI_AGENT，再看 transcript 末尾
  const m = String(process.env.AI_AGENT || '').match(/^claude-code_(\d+)-(\d+)-(\d+)/);
  if (m) return `${m[1]}.${m[2]}.${m[3]}`;
  if (tpath && isFile(tpath)) {
    try {
      const size = fs.statSync(tpath).size;
      const off = Math.max(0, size - 65536);
      const fd = fs.openSync(tpath, 'r');
      const buf = Buffer.alloc(size - off);
      fs.readSync(fd, buf, 0, size - off, off);
      fs.closeSync(fd);
      const all = [...buf.toString('utf8').matchAll(/"version":"([^"]*)"/g)];
      if (all.length) return all[all.length - 1][1];
    } catch {}
  }
  return '';
}

// ---------- hook-events.jq：hook 直接给得出的事件 ----------
const codeOk = (v) => typeof v === 'string' && /^[a-z][a-z0-9]*([._-][a-z0-9]+)*$/.test(v);
const codeify = (v) => {
  const s = String(v).replace(/[A-Z]/g, (c) => c.toLowerCase()).replace(/[^a-z0-9._-]+/g, '_')
    .replace(/^[^a-z]+/, '').replace(/[._-]+$/, '').replace(/[._-]{2,}/g, '_');
  return s === '' ? 'unknown' : [...s].slice(0, 128).join('');
};
const snake = (s) => String(s).replace(/([a-z0-9])([A-Z])/g, '$1_$2').toLowerCase();
const opt = (k, v) => (v === null || v === undefined || v === '' ? {} : { [k]: v });
const vcsOf = (v) => {
  if (v === null || typeof v !== 'object' || Array.isArray(v)) return null;
  const o = {};
  for (const k of ['head_sha', 'branch', 'dirty']) if (v[k] !== null && v[k] !== undefined) o[k] = v[k];
  return Object.keys(o).length ? o : null;
};
// K15①：D8 加调用 trace 时漏了 tool.end
const CAPABILITIES = ['session.start', 'session.end', 'turn.start', 'turn.end', 'subagent.start', 'subagent.end',
  'permission.decision', 'tool.request', 'tool.end', 'message.user', 'message.assistant', 'ext.claude'];

// 09-16 起只挂 5 个 hook（用户定）：SessionStart / UserPromptSubmit / Stop / SessionEnd / PermissionRequest。
// 原来的 SubagentStart / SubagentStop / PostToolUseFailure / Notification / PermissionDenied / StopFailure / InstructionsLoaded / CwdChanged
// 能给的都改从 transcript 推（map.mjs），这里不再为它们出事件
export function hookEvents(event, p, ctx) {    // → [事件…]（0 或 1 条），形状与 hook-events.jq 逐字段一致
  const { project_id, workspace_id, vt_version, agent_version, surface, now, vcs, extra = {} } = ctx;
  const hname = p.hook_event_name || event;
  const b = {
    event_id: null, occurred_at: now, type: null,
    agent: { name: 'claude-code', ...opt('version', agent_version), ...(codeOk(surface) ? { surface } : {}) },
    project_id, workspace_id, session_id: p.session_id ?? null,
    agent_instance_id: p.agent_id ?? 'main',
    provenance: { kind: 'hook', source_event: hname },
    payload: {},
    extensions: { 'vibetrail.version': vt_version, ...opt('vibetrail.worktree', extra.worktree ?? (vcs && vcs.worktree) ?? null) },
  };
  const withTurn = (e) => {
    if (typeof p.prompt_id === 'string' && p.prompt_id !== '') { e.turn_id = p.prompt_id; }
    else { e.turn_id = 'inferred-' + now; e.provenance = { kind: 'inferred', rule_version: 'turn-v1', source_event: hname }; }
    return e;
  };
  const hdr = (name, payload) => {
    const e = { ...b, type: 'ext.claude.' + snake(name), payload };
    if (typeof p.prompt_id === 'string' && p.prompt_id !== '') e.turn_id = p.prompt_id;
    return e;
  };
  let e;
  switch (event) {
    case 'SessionStart':
      e = { ...b, type: 'session.start', payload: { source: codeify(p.source ?? 'startup'), capabilities: CAPABILITIES } };
      e.agent_instance_id = 'main';
      e.extensions = { ...e.extensions, ...opt('claude.model', p.model ?? extra.model ?? null), ...opt('claude.agent_type', p.agent_type ?? null),
        ...opt('vibetrail.vcs', vcsOf(vcs)), ...opt('vibetrail.cwd', p.cwd ?? null) };
      e._key = `session.start|${codeify(p.source ?? 'startup')}|${now}`;
      return [e];
    case 'UserPromptSubmit':
      e = { ...b, type: 'turn.start', payload: { ...opt('model', extra.model ?? null), ...opt('vcs', vcsOf(vcs)) } };
      e.agent_instance_id = 'main';
      withTurn(e);
      e.extensions = { ...e.extensions, ...opt('claude.prompt_source', p.source ?? null), ...opt('claude.permission_mode', p.permission_mode ?? null),
        ...opt('claude.effort', p.effort?.level ?? null), ...opt('vibetrail.dirty_files', vcs?.dirty_files ?? null) };
      e._key = `${e.turn_id}|turn.start`;
      return [e];
    case 'SessionEnd':
      e = { ...b, type: 'session.end', payload: { reason: codeify(p.reason ?? 'other'), status: { code: 'completed', category: 'success' } } };
      e.agent_instance_id = 'main';
      e.extensions = { ...e.extensions, ...opt('vibetrail.vcs', vcsOf(vcs)) };
      e._key = `session.end|${now}`;
      return [e];
    case 'PermissionRequest':
      e = hdr(event, { tool_name: p.tool_name ?? 'unknown', ...opt('permission_mode', p.permission_mode ?? null) });
      e._key = `ext|PermissionRequest|${p.tool_name ?? ''}|${now}`;
      return [e];
    default:
      return [];
  }
}

// ---------- 一份 transcript：从 checkpoint 起映射（原 vibetrail-map 的编排） ----------
export function mapFile(file, opts) {
  // sid / meta / 父实例从路径推（原 vibetrail-map 的这一段）：
  // 子 agent 文件是 …/<sid>/subagents/agent-<id>.jsonl，meta 是同名 .meta.json；
  // 被子 agent 派出的子 agent（spawnDepth ≥ 2），派它的调用在上一层子 agent 的文件里
  const subdir = file.includes('/subagents/') ? path.dirname(file) : '';
  if (!opts.sid) opts = { ...opts, sid: subdir ? path.basename(path.dirname(subdir)) : path.basename(file).replace(/\.jsonl$/, '') };
  if (opts.meta === undefined || opts.meta === null) {
    const mf = file.replace(/\.jsonl$/, '') + '.meta.json';
    const m = isFile(mf) ? readJson(mf, null) : null;
    opts = { ...opts, meta: m !== null && typeof m === 'object' && !Array.isArray(m) ? m : null };
  }
  if (!opts.parent_instance) {
    let parent = 'main';
    const tid = opts.meta?.toolUseId ?? '';
    if (subdir && tid) {
      let names = [];
      try { names = fs.readdirSync(subdir).filter((f) => /^agent-.*\.jsonl$/.test(f) && path.join(subdir, f) !== file); } catch {}
      for (const f of names.sort()) {
        const txt = readText(path.join(subdir, f));
        if (txt && txt.includes(`"id":"${tid}"`)) { parent = f.replace(/^agent-/, '').replace(/\.jsonl$/, ''); break; }
      }
    }
    opts = { ...opts, parent_instance: parent };
  }
  // project_id / workspace_id 没给就取第一条带 cwd 记录的 cwd（原 vibetrail-map 的默认值）
  if (!opts.project_id || !opts.workspace_id) {
    let cwd = '';
    try {
      const head = fs.readFileSync(file, 'utf8').slice(0, 1024 * 1024);
      for (const line of head.split('\n')) {
        if (!line) continue;
        try { const r = JSON.parse(line); if (r && typeof r === 'object' && typeof r.cwd === 'string') { cwd = r.cwd; break; } } catch {}
      }
    } catch {}
    if (!cwd) cwd = 'unknown';
    opts = { ...opts, project_id: opts.project_id || cwd, workspace_id: opts.workspace_id || cwd };
  }
  const {
    sid, project_id, workspace_id, parent_instance = 'main', meta = null,
    start_line = 1, start_byte = null, from_line = 0, seenFile = '', hook_turns = {}, hook_perms = [],
    perm_since = '', perm_periods = null, split_decisions = {}, close_last = '', stop_turn = '', turns = true, capture_content = '1', vt_version = VT_RUNTIME_VERSION,
    done_ts = null,
  } = opts;
  // 这个会话已知的子 agent：没给就看同目录（子 agent 文件）或 <sid>/subagents（主文件）
  const known_agents = opts.known_agents ?? vtKnownAgents(subdir || path.join(path.dirname(file), sid, 'subagents'));
  const total = fs.statSync(file).size;

  // 只读到最后一个换行符
  let consumed = total;
  if (total > 0) {
    const fd = fs.openSync(file, 'r');
    const last = Buffer.alloc(1);
    fs.readSync(fd, last, 0, 1, total - 1);
    if (last[0] !== 0x0a) {
      const back = Math.min(total, 1024 * 1024);
      const buf = Buffer.alloc(back);
      fs.readSync(fd, buf, 0, back, total - back);
      const idx = buf.lastIndexOf(0x0a);
      consumed = idx >= 0 ? total - back + idx + 1 : 0;
    }
    fs.closeSync(fd);
  }

  // 起读偏移：给了就用，没给就数前 S-1 行
  let sb = start_byte;
  if (sb === null || sb === undefined || sb === '') {
    sb = 0;
    if (start_line > 1) {
      const buf = fs.readFileSync(file);
      let n = 0, i = 0;
      while (n < start_line - 1) { const j = buf.indexOf(0x0a, i); if (j < 0) { i = buf.length; break; } i = j + 1; n++; }
      sb = i;
    }
  }
  if (sb > consumed) throw new Error(`起读偏移 ${sb} 超过文件可读长度 ${consumed}（文件被重写过？从 0 重读）`);

  // 单次最多读 50 MB（照 Pilot）：超了从尾部读，并对齐到行首——宁可丢最老的，也不让一次 hook 吃满内存
  let readFrom = sb, truncated = 0;
  if (consumed - sb > MAX_READ_BYTES) { readFrom = consumed - MAX_READ_BYTES; truncated = readFrom - sb; }
  const fd = fs.openSync(file, 'r');
  const slice = Buffer.alloc(consumed - readFrom);
  if (slice.length > 0) fs.readSync(fd, slice, 0, slice.length, readFrom);
  fs.closeSync(fd);
  let text = slice.toString('utf8');
  let firstLine = start_line;
  if (truncated > 0) {
    const nl = text.indexOf('\n');
    text = nl >= 0 ? text.slice(nl + 1) : '';
    // 丢掉的行数要补进行号，否则 from_line 的门控会错位
    const dropped = (() => { const b = fs.readFileSync(file); let c = 0; for (let i = sb; i < readFrom + (text ? 0 : 0); i++) if (b[i] === 0x0a) c++; return c; })();
    firstLine = start_line + dropped + 1;
  }

  const records = [];
  for (const line of text.split('\n')) {
    if (line.trim() === '') continue;
    try { records.push(JSON.parse(line)); } catch { /* 半行 / 坏行：整条跳过，账本按跳过计 */ }
  }
  const { events, ledger } = mapRecords(records, {
    sid, project_id, workspace_id, parent_instance, start_line: firstLine, from_line, meta,
    seen_uuids: seenFile && isFile(seenFile)
      ? readText(seenFile).split('\n').filter(Boolean).map((l) => { const [u, n] = l.split('\t'); return [u, Number(n)]; })
      : [],
    hook_turns, hook_perms, perm_since, perm_periods, split_decisions, known_agents, done_ts, close_last, stop_turn, turns, vt_version, rule_version: 'diverge-v1', capture_content,
  });

  // 下次的起读字节：checkpoint 行的偏移
  let ckByte = sb;
  if (ledger.checkpoint_line > firstLine) {
    const buf = fs.readFileSync(file);
    let n = 0, i = 0;
    while (n < ledger.checkpoint_line - 1) { const j = buf.indexOf(0x0a, i); if (j < 0) { i = buf.length; break; } i = j + 1; n++; }
    ckByte = i;
  } else if (ledger.checkpoint_line <= firstLine && truncated > 0) ckByte = readFrom;

  const full = { ...ledger, file, sid, parent_instance, start_byte: sb, checkpoint_byte: ckByte,
    consumed_bytes: consumed, file_bytes: total, ...(truncated > 0 ? { truncated_bytes: truncated } : {}) };
  return { events: vtFillIds(sid, events), ledger: full };
}

// ---------- hook 分发（原 vibetrail-hook） ----------
// CatchUp 是 vibetrail sync 用的内部事件，不是 Claude Code 的 hook
export const HOOK_EVENTS = ['SessionStart', 'UserPromptSubmit', 'Stop', 'SessionEnd', 'PermissionRequest'];
const HANDLED_EVENTS = new Set([...HOOK_EVENTS, 'CatchUp']);
const sleepSync = (ms) => { try { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); } catch { } };

export function runHook(event, payload) {
  const p = (() => { try { return JSON.parse(payload); } catch { return null; } })();
  if (p === null || typeof p !== 'object') return;
  const sid = String(p.session_id ?? '');
  if (sid === '' || sid.includes('/') || sid.startsWith('.')) return;    // 会话 id 要能当目录名
  const tpath = String(p.transcript_path ?? '');
  const cwd = String(p.cwd ?? '');
  const promptId = String(p.prompt_id ?? '');
  const source = String(p.source ?? '');
  const ev = p.hook_event_name && !event ? String(p.hook_event_name) : event;
  // 退役的事件（没重跑 init 的旧条目）连门控里的 git 都不跑，直接走
  if (!HANDLED_EVENTS.has(ev)) return;

  // ---- 门控（scope，DESIGN §5；G8） ----
  vtPruneRemoved();
  const scope = vtConf('scope', 'project');
  const main = cwd ? vtMainCheckout(cwd) : null;
  if (scope === 'project' && !(main && vtRegistered(main))) return;
  let ctx = {};
  const setProject = (workspace) => {
    const origin = git(workspace, ['remote', 'get-url', 'origin']);
    const project = (origin ? origin.replace(/^[a-z+]+:\/\/([^@/]*@)?/, '').replace(/^[^@/]*@/, '').replace(/:/, '/').replace(/\.git$/, '') : '') || workspace;
    ctx = { ...ctx, workspace, project, pkey: vtProjectKey(workspace) };
  };
  setProject(main || vtRealpath(cwd || '.'));
  const SD = path.join(VT_HOME, 'state', sid);
  const agentVersion = vtAgentVersion(tpath);
  const surface = process.env.CLAUDE_CODE_ENTRYPOINT || '';

  const emitHook = (name, vcs, extra = {}) => {
    const events = hookEvents(name, p, { project_id: ctx.project, workspace_id: ctx.workspace, vt_version: VT_RUNTIME_VERSION,
      agent_version: agentVersion, surface, now: nowIso(), vcs, extra });
    if (events.length === 0) return;
    let filled;
    try { filled = vtFillIds(sid, events); } catch { vtLogError(ev, sid, 'event_id', 1); return; }
    if (!vtSpoolWrite(ctx.pkey, sid, 'hook-' + name.toLowerCase(), filled)) vtLogError(ev, sid, 'spool:hook-' + name.toLowerCase(), 1);
  };
  const extraModel = () => { const s = readJson(path.join(SD, 'session.json'), null); return s && s.model ? { model: s.model } : {}; };
  // ---- 轮次证据 ----
  const closeGap = (turnId, snap, by) => {
    const sf = vtTurnFile(sid, turnId, 'start'), gf = vtTurnFile(sid, turnId, 'gap');
    if (!isFile(sf) || isFile(gf)) return;
    const stopF = vtTurnFile(sid, turnId, 'stop');
    if (isFile(stopF)) {
      const a = readJson(sf, {}), b = readJson(stopF, {});
      if ((b.at_epoch ?? 0) >= (a.at_epoch ?? 0)) return;
    }
    const start = readJson(sf, {});
    const c = vtCommits(cwd, start?.vcs?.head_sha ?? '', start?.at_epoch ?? '');
    vtWriteJson(gf, { turn_id: turnId, at: nowIso(), at_epoch: epochSec(), by, vcs: snap ?? null,
      ...(c ? { commits: c.commits, commit_method: c.method } : {}) });
  };
  const turnStart = () => {
    const snap = vtGitSnapshot(cwd);
    if (promptId) {
      mkdirp(path.join(SD, 'turns'));
      const prev = (readText(path.join(SD, 'last_turn')) || '').trim();
      if (prev && prev !== promptId) closeGap(prev, snap, 'UserPromptSubmit');
      const sf = vtTurnFile(sid, promptId, 'start');
      if (!isFile(sf)) vtWriteJson(sf, { turn_id: promptId, at: nowIso(), at_epoch: epochSec(), vcs: snap });
      fs.writeFileSync(path.join(SD, 'last_turn'), promptId + '\n');
    }
    emitHook('UserPromptSubmit', snap, extraModel());
  };
  const turnStop = () => {
    if (!promptId) return;
    const snap = vtGitSnapshot(cwd);
    const f = vtTurnFile(sid, promptId, 'stop'), sf = vtTurnFile(sid, promptId, 'start');
    const n = isFile(f) ? (readJson(f, {}).stops ?? 0) : 0;
    const start = isFile(sf) ? readJson(sf, {}) : {};
    const c = vtCommits(cwd, start?.vcs?.head_sha ?? '', start?.at_epoch ?? '');
    vtWriteJson(f, { turn_id: promptId, at: nowIso(), at_epoch: epochSec(), stops: n + 1,
      stop_hook_active: p.stop_hook_active === true, vcs: snap ?? null, ...(c ? { commits: c.commits, commit_method: c.method } : {}) });
  };
  // ---- 一份 transcript：映射 → 去重 → 写一块 spool → 推进 state ----
  const processFile = (s2, sd, f, name, close = '', stopTurn = '') => {
    let size;
    try { size = fs.statSync(f).size; } catch { return; }
    const stFile = path.join(sd, `${name}.json`), seenFile = path.join(sd, `${name}.seen`);
    // 子 agent 文件只在它结束后才把最后一次调用写出。结束信号（09-16 起）在父文件里：同步 agent 的调用结果、后台 agent 的
    // <task-notification>，映射父文件时记进 agents.json；映射器拿它与这份文件最后一条记录的时间比（close_last = if_done）。
    // <name>.done 是老版本 SubagentStop hook 留下的（记的是当时的文件大小），升级过渡期照认
    const aid = name.replace(/^agent-/, '');
    const subDir = path.dirname(f);
    const known = name === 'main' || subDir.endsWith('/subagents') ? { ...vtKnownAgents(name === 'main' ? path.join(path.dirname(f), s2, 'subagents') : subDir) } : {};
    for (const [k, v] of Object.entries(vtAgents(s2).launched)) known[k] = { ...objOr(v), ...objOr(known[k]) };
    let doneTs = null;
    if (name !== 'main') {
      const ag = vtAgents(s2);
      const tid = known[aid]?.call_id;
      doneTs = [ag.done[aid], tid ? ag.calls_done[tid] : null].filter((x) => typeof x === 'string').sort().pop() ?? null;
      if (!['session_end', 'resume', 'idle'].includes(close)) {
        close = (readText(path.join(sd, `${name}.done`)) || '').trim() === String(size) ? 'stop' : doneTs ? 'if_done' : '';
      }
    }
    let ino = null; try { ino = fs.statSync(f).ino; } catch {}
    let lines = 0, consumed = 0, ckl = 1, ckb = 0, fpOld = '', rewrites = 0, open = '', closed = false, callOpen = false, lastTs = null;
    if (isFile(stFile)) {
      const st = readJson(stFile, {});
      lines = st.lines ?? 0; consumed = st.consumed_bytes ?? 0; ckl = st.checkpoint_line ?? 1; ckb = st.checkpoint_byte ?? 0;
      fpOld = st.fprint ?? ''; rewrites = st.rewrites ?? 0;
      open = st.turn_open ?? ''; closed = st.turn_closed === true; callOpen = st.call_open === true; lastTs = st.last_ts ?? null;
    }
    // 没有新字节时只比 inode；要关最后一轮或末尾还有调用没写出的照样往下走
    if (size === consumed && (fpOld === '' || String(fpOld).split(':')[0] === String(ino))) {
      if (!close) return;
      if ((!open || closed) && !callOpen) return;
      if (close === 'if_done' && typeof lastTs === 'string' && !(doneTs >= lastTs)) return;   // 续上之后还没有新的完成信号
    }
    if (consumed > 0 && (size < consumed || (fpOld !== '' && vtFprint(f, consumed) !== fpOld))) {
      try { fs.unlinkSync(stFile); } catch {}
      try { fs.unlinkSync(seenFile); } catch {}
      lines = 0; consumed = 0; ckl = 1; ckb = 0; rewrites += 1;
    }
    let out;
    try {
      out = mapFile(f, { sid: s2, project_id: ctx.project, workspace_id: ctx.workspace,
        start_line: ckl, start_byte: ckb, from_line: lines, seenFile,
        hook_turns: name === 'main' ? vtHookTurns(s2) : {},
        hook_perms: vtHookPerms(s2), perm_periods: vtPermPeriods(), split_decisions: vtSplits(s2),
        close_last: name === 'main' || close ? close : '', stop_turn: name === 'main' ? stopTurn : '',
        known_agents: known, done_ts: doneTs, capture_content: vtConf('capture_content', '1') });
    } catch (e) { vtLogError(ev, s2, `map:${name}`, 2); return; }
    // 结论先落盘再写 spool：反过来的话，spool 写进去了、结论没存上，下次重读就可能判出另一种、发出矛盾的事件
    if (!vtSplitsSave(s2, out.ledger.split_decisions_new)) { vtLogError(ev, s2, `splits:${name}`, 1); return; }
    if (!vtAgentsSave(s2, out.ledger.agents)) vtLogError(ev, s2, `agents:${name}`, 1);
    if (!vtSpoolWrite(ctx.pkey, s2, name, out.events)) { vtLogError(ev, s2, `spool:${name}`, 1); return; }
    const srcLines = (out.ledger.sources || []).map(([u, n]) => `${u}\t${n}`).join('\n');
    if (srcLines) { try { fs.appendFileSync(seenFile, srcLines + '\n'); } catch {} }
    const fp = vtFprint(f, out.ledger.consumed_bytes) ?? '';
    const stNew = { lines: out.ledger.lines, consumed_bytes: out.ledger.consumed_bytes, file_bytes: out.ledger.file_bytes,
      checkpoint_line: out.ledger.checkpoint_line, checkpoint_byte: out.ledger.checkpoint_byte,
      parent_instance: out.ledger.parent_instance, fprint: fp, rewrites,
      turn_open: out.ledger.turns.open ?? null, turn_closed: out.ledger.turns.closed ?? false,
      call_open: out.ledger.trace?.call_open ?? false, last_ts: out.ledger.last_ts ?? null, updated_at: new Date().toISOString().replace(/\.\d+Z$/, 'Z') };
    try { fs.writeFileSync(stFile + '.tmp', JSON.stringify(stNew) + '\n'); fs.renameSync(stFile + '.tmp', stFile); } catch {}
    if (name === 'main') {
      const model = out.ledger.turns?.model;
      if (model) vtWriteJson(path.join(sd, 'session.json'), { ...readJson(path.join(sd, 'session.json'), {}), model });
    }
  };

  const processSession = (s2, mainT, close = '', stopTurn = '') => {
    const sd = path.join(VT_HOME, 'state', s2);
    if (!mkdirp(sd)) return;
    if (!vtLock(sd)) return;                       // 同一会话已在跑：跳过，下一次 hook 补上
    try {
      if (isFile(mainT)) processFile(s2, sd, mainT, 'main', close, stopTurn);
      const subDir = path.join(path.dirname(mainT), s2, 'subagents');
      let names = [];
      try { names = fs.readdirSync(subDir).filter((f) => /^agent-.*\.jsonl$/.test(f)); } catch {}
      const before = JSON.stringify(vtAgents(s2));
      for (const f of names.sort()) processFile(s2, sd, path.join(subDir, f), f.replace(/\.jsonl$/, ''), close);
      if (names.length > 1 && JSON.stringify(vtAgents(s2)) !== before) {
        for (const f of names.sort()) processFile(s2, sd, path.join(subDir, f), f.replace(/\.jsonl$/, ''), close);
      }
    } finally { vtUnlock(sd); }
  };

  const waitStable = (f) => {                      // 照 Pilot：大小连续两次不变才读，最多 1.5 s
    if (process.env.VIBETRAIL_STABLE_WAIT === '0') return;
    let prev = -1, same = 0;
    for (let i = 0; i < 10; i++) {
      let s; try { s = fs.statSync(f).size; } catch { return; }
      if (s === prev) { same++; if (same >= 2) return; } else same = 0;
      prev = s; sleepSync(150);
    }
  };
  // ---- 补做：本仓与所有登记过的仓，每个 worktree 对应的 Claude 项目目录 ----
  const catchUpDirs = () => {
    const repos = [ctx.workspace];
    try { for (const f of fs.readdirSync(path.join(VT_HOME, 'projects'))) {
      const r = (readText(path.join(VT_HOME, 'projects', f)) || '').split('\n')[0].trim();
      if (r) repos.push(r);
    } } catch {}
    const seenRepo = new Set(); const out = [];
    for (const repo of repos) {
      if (!repo || seenRepo.has(repo)) continue;
      seenRepo.add(repo);
      if (!isDir(repo) || git(repo, ['rev-parse', '--git-dir']) === null) continue;
      const dirs = [];
      const wl = git(repo, ['worktree', 'list', '--porcelain']) || '';
      for (const l of wl.split('\n')) if (l.startsWith('worktree ')) dirs.push(path.join(claudeProjects(), vtSlug(l.slice(9))));
      // 已经删掉的 desktop worktree 留下的会话目录，照样归主仓
      try {
        const prefix = vtSlug(repo) + '--claude-worktrees-';
        for (const d of fs.readdirSync(claudeProjects())) if (d.startsWith(prefix)) dirs.push(path.join(claudeProjects(), d));
      } catch {}
      const seenDir = new Set();
      for (const d of dirs) { if (seenDir.has(d) || !isDir(d)) continue; seenDir.add(d); out.push([repo, d]); }
    }
    return out;
  };
  const catchUp = () => {
    const idle = Number(vtConf('turn_idle_close', '3600'));
    const now = epochSec();
    const saved = { ...ctx };
    for (const [repo, dir] of catchUpDirs()) {
      setProject(repo);
      let names = [];
      try { names = fs.readdirSync(dir).filter((f) => f.endsWith('.jsonl')); } catch { continue; }
      for (const t of names.sort()) {
        const full = path.join(dir, t), s2 = t.replace(/\.jsonl$/, '');
        let close = '';
        if (s2 === sid) { if (source === 'resume') close = 'resume'; }
        else {
          let mt = now; try { mt = Math.floor(fs.statSync(full).mtimeMs / 1000); } catch {}
          if (now - mt >= idle) close = 'idle';
        }
        processSession(s2, full, close);
      }
    }
    ctx = saved;
    if (!main && isFile(tpath)) processSession(sid, tpath, source === 'resume' ? 'resume' : '');
    // K15③：以前只清 turns / perms，main.json / ids / seen 永不清——transcript 30 天被 Claude Code 清掉后它们还在。
    // 整个会话目录 30 天没动、且 spool 里没有它的待发块（有的话 ids 还要用来挡重复，K14）才删
    const staleCutoff = Date.now() - 30 * 86400 * 1000;
    const pendingSids = new Set();
    try {
      for (const pk of fs.readdirSync(path.join(VT_HOME, 'spool'))) {
        let sids = []; try { sids = fs.readdirSync(path.join(VT_HOME, 'spool', pk)); } catch { continue; }
        for (const s2 of sids) {
          try { if (fs.readdirSync(path.join(VT_HOME, 'spool', pk, s2)).some((f) => f.endsWith('.jsonl') && !f.startsWith('.'))) pendingSids.add(s2); } catch {}
        }
      }
    } catch {}
    try {
      for (const s2 of fs.readdirSync(path.join(VT_HOME, 'state'))) {
        const dir = path.join(VT_HOME, 'state', s2);
        if (!isDir(dir) || pendingSids.has(s2) || s2 === sid) continue;
        let newest = 0;
        try { newest = Math.max(fs.statSync(dir).mtimeMs, ...fs.readdirSync(dir).map((f) => { try { return fs.statSync(path.join(dir, f)).mtimeMs; } catch { return 0; } })); } catch {}
        if (newest > 0 && newest < staleCutoff) fs.rmSync(dir, { recursive: true, force: true });
      }
    } catch {}
    // 轮次、权限框证据留两周
    const cutoff = Date.now() - 14 * 86400 * 1000;
    try {
      for (const s2 of fs.readdirSync(path.join(VT_HOME, 'state'))) {
        for (const sub of ['turns', 'perms']) {
          const d = path.join(VT_HOME, 'state', s2, sub);
          try { for (const f of fs.readdirSync(d)) {
            const fp2 = path.join(d, f);
            if (f.endsWith('.json') && fs.statSync(fp2).mtimeMs < cutoff) fs.unlinkSync(fp2);
          } } catch {}
        }
      }
    } catch {}
  };

  // ---- 按事件干活 ----
  switch (ev) {
    case 'SessionStart': {
      const snap = vtGitSnapshot(cwd);
      mkdirp(SD);
      vtWriteJson(path.join(SD, 'session.json'), { ...readJson(path.join(SD, 'session.json'), {}),
        source: p.source ?? null, ...(p.model ? { model: p.model } : {}) });
      emitHook('SessionStart', snap, extraModel());
      catchUp();
      break;
    }
    case 'UserPromptSubmit': turnStart(); break;
    case 'Stop':
      turnStop();
      if (isFile(tpath)) { waitStable(tpath); processSession(sid, tpath, 'stop', promptId); }
      break;
    case 'SessionEnd': {
      const snap = vtGitSnapshot(cwd);
      emitHook('SessionEnd', snap, {});
      const prev = (readText(path.join(SD, 'last_turn')) || '').trim();
      if (prev) closeGap(prev, snap, 'SessionEnd');
      if (isFile(tpath)) processSession(sid, tpath, 'session_end');
      break;
    }
    case 'PermissionRequest':
      mkdirp(path.join(SD, 'perms'));
      try {
        fs.writeFileSync(path.join(SD, 'perms', `${epochSec()}-${process.pid}.json`),
          JSON.stringify({ at: nowIso(), tool_name: p.tool_name ?? null, agent_id: p.agent_id ?? null,
            prompt_id: p.prompt_id ?? null, permission_mode: p.permission_mode ?? null }) + '\n');
      } catch {}
      emitHook('PermissionRequest', null, {});
      break;
    case 'CatchUp': catchUp(); break;              // vibetrail sync：补一遍，不发事件
    // 退役的 8 个事件（见 hookEvents 上面的说明）在入口就挡掉了：它们能给的已经从 transcript 推出来，再发就是两条
    default: break;
  }
}

// 同步 hook（与可能被同步等的 PermissionRequest）：读完 stdin 就丢到脱离的子进程里，自己立刻退出
export const SYNC_EVENTS = new Set(['SessionStart', 'UserPromptSubmit', 'SessionEnd', 'PermissionRequest']);
export function detach(entry, event, payload) {
  const child = spawn(process.execPath, [entry, 'hook-run', event], { detached: true, stdio: ['pipe', 'ignore', 'ignore'] });
  child.stdin.write(payload);
  child.stdin.end();
  child.unref();
}
