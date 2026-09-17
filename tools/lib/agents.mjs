// vibetrail：Codex / Cursor 两家共用的部分（TODO G12）。Claude Code 的路径不经过这里，hook.mjs / map.mjs 一行没动。
// 三家的会话记录格式完全不同，这里只放与格式无关的东西：门控、事件头、超限去正文、写 spool、轮次证据、文件相对路径、改宿主的 hooks.json。
//
// 纪律同 DESIGN §3.4：永远 exit 0、失败只往 errors.log 记元数据；scope=project 时未登记的仓什么都不写（A8）。
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import {
  VT_HOME, VT_RUNTIME_VERSION, vtConf, vtMainCheckout, vtRegistered, vtRealpath, vtProjectName, vtWorkspaceId, vtWorktrees,
  vtProjectKey, vtFillIds, vtSpoolWrite, vtLogError, vtCommits, vtTurnFile, vtWriteJson,
} from './hook.mjs';

// ---------- 小工具（hook.mjs 里同名的没导出，照抄） ----------
export const readText = (p) => { try { return fs.readFileSync(p, 'utf8'); } catch { return null; } };
export const readJson = (p, dflt) => { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return dflt; } };
export const isFile = (p) => { try { return fs.statSync(p).isFile(); } catch { return false; } };
export const isDir = (p) => { try { return fs.statSync(p).isDirectory(); } catch { return false; } };
export const mkdirp = (p) => { try { fs.mkdirSync(p, { recursive: true }); return true; } catch { return false; } };
export const nowIso = () => new Date().toISOString();
export const epochSec = () => Math.floor(Date.now() / 1000);
export const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
export const opt = (k, v) => (v === null || v === undefined || v === '' ? {} : { [k]: v });
export const sha256 = (s, n = 64) => crypto.createHash('sha256').update(String(s)).digest('hex').slice(0, n);
export const capture = () => vtConf('capture_content', '1') !== '0';
// init 时选了哪几家（config 的 agents=，逗号分隔）；没有这一行（老安装）只当 Claude 在采
export const KNOWN_AGENTS = ['claude', 'codex', 'cursor'];
export const selectedAgents = () => {
  const v = String(vtConf('agents', '')).trim();
  return v === '' ? ['claude'] : v.split(',').map((x) => x.trim()).filter((x) => KNOWN_AGENTS.includes(x));
};
export const agentEnabled = (name) => selectedAgents().includes(name);
export const validSid = (s) => typeof s === 'string' && s !== '' && s.length <= 128 && !s.includes('/') && !s.startsWith('.');
export const sleepSync = (ms) => { try { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); } catch { } };

export const codeOk = (v) => typeof v === 'string' && /^[a-z][a-z0-9]*([._-][a-z0-9]+)*$/.test(v);
export const codeify = (v) => {                       // 与 hook.mjs 同一写法：协议的 code 型取值
  const s = String(v).replace(/[A-Z]/g, (c) => c.toLowerCase()).replace(/[^a-z0-9._-]+/g, '_')
    .replace(/^[^a-z]+/, '').replace(/[._-]+$/, '').replace(/[._-]{2,}/g, '_');
  return s === '' ? 'unknown' : [...s].slice(0, 128).join('');
};

// ---------- 门控 ----------
// 候选目录按顺序试（Codex 给 cwd，Cursor 给 workspace_roots），第一个过门控的就是这个会话的工作区；都不过返回 null，什么都不写
export function gate(dirs) {
  const scope = vtConf('scope', 'project');
  for (const d of dirs) {
    if (typeof d !== 'string' || d === '' || !isDir(d)) continue;
    const main = vtMainCheckout(d);
    if (scope === 'project' && !(main && vtRegistered(main))) continue;
    const ws = main || vtRealpath(d);
    const roots = main ? vtWorktrees(main) : [ws];
    return { dir: d, workspace: ws, project_id: vtProjectName(ws), workspace_id: vtWorkspaceId(ws), roots, pkey: vtProjectKey(ws) };
  }
  return null;
}

// ---------- 事件 ----------
export function baseEvent(agent, ctx, { sid, type, at, turn = null, instance = 'main', parentInstance = null, parentCall = null, provenance }) {
  return {
    event_id: null, occurred_at: at, type,
    agent: { name: agent.name, ...opt('version', agent.version), ...(codeOk(agent.surface) ? { surface: agent.surface } : {}) },
    project_id: ctx.project_id, workspace_id: ctx.workspace_id, session_id: sid,
    ...(turn ? { turn_id: turn } : {}),
    agent_instance_id: instance,
    ...(parentInstance ? { parent_agent_instance_id: parentInstance } : {}),
    ...(parentCall ? { parent_call_id: parentCall } : {}),
    provenance, payload: {},
    extensions: { 'vibetrail.version': VT_RUNTIME_VERSION },
  };
}

// 协议单条 1 MiB：超了去掉正文、标 omitted（DESIGN §4 体积一行），不截断
const SIZE_CAP = 1048576 - 1024;
const CONTENT_EXT = /^(vibetrail\.(reasoning|system_prompt)|codex\.base_instructions)$/;
export function fit(e) {
  if (Buffer.byteLength(JSON.stringify(e), 'utf8') <= SIZE_CAP) return e;
  const payload = { ...e.payload };
  for (const k of ['text', 'input', 'output', 'task', 'last_message']) delete payload[k];
  const out = { ...e, payload, content_state: 'omitted' };
  delete out.raw;
  out.extensions = { ...Object.fromEntries(Object.entries(e.extensions || {}).filter(([k]) => !CONTENT_EXT.test(k))), 'vibetrail.content_dropped': 'size' };
  return out;
}

export function emit(pkey, sid, name, events, ev) {  // 填 event_id → 按 state/<sid>/ids 去重 → 写一块 spool
  if (events.length === 0) return true;
  let filled;
  try { filled = vtFillIds(sid, events.map(fit)); } catch { vtLogError(ev, sid, 'event_id', 1); return false; }
  if (!vtSpoolWrite(pkey, sid, name, filled)) { vtLogError(ev, sid, 'spool:' + name, 1); return false; }
  return true;
}

export const vcsOf = (v) => {
  if (!isObj(v)) return null;
  const o = {};
  for (const k of ['head_sha', 'branch', 'dirty']) if (v[k] !== null && v[k] !== undefined) o[k] = v[k];
  return Object.keys(o).length ? o : null;
};
export const commitsOf = (rec) => (Array.isArray(rec?.commits) && rec.commits.length
  ? rec.commits.slice(0, 256).map((sha) => ({ sha, relation: 'observed', evidence: 'before_after' })) : null);

// ---------- 轮次证据（形状与 Claude 那一路的 state/<sid>/turns/ 相同） ----------
export function turnStart(sid, turnId, snap) {
  const f = vtTurnFile(sid, turnId, 'start');
  if (!isFile(f)) vtWriteJson(f, { turn_id: turnId, at: nowIso(), at_epoch: epochSec(), vcs: snap ?? null });
}
export function turnStop(sid, turnId, dir, snap, extra = {}) {
  const f = vtTurnFile(sid, turnId, 'stop'), sf = vtTurnFile(sid, turnId, 'start');
  const n = isFile(f) ? (readJson(f, {}).stops ?? 0) : 0;
  const start = isFile(sf) ? readJson(sf, {}) : {};
  const c = vtCommits(dir, start?.vcs?.head_sha ?? '', start?.at_epoch ?? '');
  const rec = { turn_id: turnId, at: nowIso(), at_epoch: epochSec(), stops: n + 1, vcs: snap ?? null,
    ...(c ? { commits: c.commits, commit_method: c.method } : {}), ...extra };
  vtWriteJson(f, rec);
  return rec;
}
export function turnGap(sid, turnId, dir, snap, by) {   // 没等到止的轮：用此刻的快照补一份
  const sf = vtTurnFile(sid, turnId, 'start'), gf = vtTurnFile(sid, turnId, 'gap');
  if (!isFile(sf) || isFile(gf) || isFile(vtTurnFile(sid, turnId, 'stop'))) return null;
  const start = readJson(sf, {});
  const c = vtCommits(dir, start?.vcs?.head_sha ?? '', start?.at_epoch ?? '');
  const rec = { turn_id: turnId, at: nowIso(), at_epoch: epochSec(), by, vcs: snap ?? null, ...(c ? { commits: c.commits, commit_method: c.method } : {}) };
  vtWriteJson(gf, rec);
  return rec;
}
export const turnEvidence = (sid, turnId) => readJson(vtTurnFile(sid, turnId, 'stop'), null) ?? readJson(vtTurnFile(sid, turnId, 'gap'), null);

// ---------- 文件：相对工作区根（协议：不许绝对路径、不许 ..） ----------
const PATH_OK = /^(?!\/)(?![A-Za-z]:)(?!.*\\)(?!.*(?:^|\/)\.{1,2}(?:\/|$))(?!.*\/\/)(?![\s\S]*[\x00-\x1f])[^/]+(?:\/[^/]+)*$/;
export function relFile(p, roots, cwd = '') {
  if (typeof p !== 'string' || p === '') return null;
  const abs = path.isAbsolute(p) ? path.normalize(p) : path.resolve(cwd || roots[0] || '/', p);
  for (const r of roots) {
    const rr = path.normalize(r);
    if (abs.startsWith(rr + path.sep)) {
      const rel = abs.slice(rr.length + 1).split(path.sep).join('/');
      if (PATH_OK.test(rel)) return rel;
    }
  }
  return null;
}
const OP_RANK = { read: 1, modify: 2, create: 3, delete: 4 };
export function noteFile(files, rel, op) {             // 同一文件取「动得最重」的那次
  if (!rel) return;
  if (!files[rel] || (OP_RANK[op] ?? 0) > (OP_RANK[files[rel]] ?? 0)) files[rel] = op;
}
export const filesOf = (files, evidence) => {
  const list = Object.entries(files || {}).slice(0, 256).map(([p, op]) => ({ path: p, operation: op, evidence: op === 'read' ? 'tool_argument' : evidence }));
  return list.length ? list : null;
};

// ---------- 后台运行：同步 hook 读完 stdin 就丢给脱离的子进程 ----------
export function detach(entry, agentName, event, payload) {
  const child = spawn(process.execPath, [entry, 'hook-run', agentName, event], { detached: true, stdio: ['pipe', 'ignore', 'ignore'] });
  child.stdin.write(payload);
  child.stdin.end();
  child.unref();
}

// ---------- 改宿主的 hooks.json：认自家条目、原子写、第一次改之前的原样另存（照 cli.mjs 的 settingsWrite） ----------
export const hookCommand = (agentName, ev) =>
  `sh '${path.join(VT_HOME, 'bin', 'vibetrail-hook').replace(/'/g, "'\\''")}' ${agentName} ${ev} 2>/dev/null || true`;
export const isOurs = (cmd) => String(cmd ?? '').includes('vibetrail-hook');
const canon = (v) => JSON.stringify(v, (k, x) => (isObj(x) ? Object.fromEntries(Object.keys(x).sort().map((y) => [y, x[y]])) : x));
export const sameJson = (a, b) => canon(a) === canon(b);

// 改用户的文本配置（Codex 的 config.toml）：写前后各核一次没被别人改过、改前备份（0600）、临时文件 + rename、保留原来的权限
export function writeTextGuarded(file, before, next, tag) {
  const bk = path.join(VT_HOME, 'backup');
  mkdirp(bk); mkdirp(path.dirname(file));
  if ((readText(file) ?? '') !== before) return false;
  let mode = 0o600; try { mode = fs.statSync(file).mode & 0o777; } catch {}
  if (before !== '') {
    const orig = path.join(bk, `${tag}.before-vibetrail`);
    if (!fs.existsSync(orig)) fs.writeFileSync(orig, before, { mode: 0o600 });
    fs.writeFileSync(path.join(bk, `${tag}.${new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z')}-${process.pid}`), before, { mode: 0o600 });
  }
  const tmp = `${file}.vibetrail.tmp`;
  fs.writeFileSync(tmp, next, { mode });
  try { fs.chmodSync(tmp, mode); } catch {}
  if ((readText(file) ?? '') !== before) { try { fs.unlinkSync(tmp); } catch {} return false; }
  fs.renameSync(tmp, file);
  return true;
}

export function readHostJson(file) {                   // 没有文件是 {}；读不懂返回 null（不去改一份读不懂的配置）
  if (!isFile(file) || fs.statSync(file).size === 0) return {};
  const v = readJson(file, undefined);
  return isObj(v) ? v : null;
}
export function writeHostJson(file, before, next, tag) {
  const bk = path.join(VT_HOME, 'backup');
  mkdirp(bk); mkdirp(path.dirname(file));
  const cur = readHostJson(file);
  if (cur === null || !sameJson(cur, before)) return false;           // 这期间被别人改过：不写
  if (isFile(file) && fs.statSync(file).size > 0) {
    const orig = path.join(bk, `${tag}.before-vibetrail`);
    if (!fs.existsSync(orig) && !(readText(file) || '').includes('vibetrail-hook')) fs.copyFileSync(file, orig);
    fs.copyFileSync(file, path.join(bk, `${tag}.${new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z')}-${process.pid}`));
  }
  const tmp = `${file}.vibetrail.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(next, null, 2) + '\n');
  const again = readHostJson(file);
  if (again === null || !sameJson(again, before)) { try { fs.unlinkSync(tmp); } catch {} return false; }
  fs.renameSync(tmp, file);
  return true;
}
