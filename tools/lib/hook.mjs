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
import { mapRecords, RULE_VERSIONS, displayDir, BAD_LINE, BLANK_LINE } from './map.mjs';

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
// 上报 token（push 时放进 Onepaas-Api-Access-Token 请求头，服务端按它认人）。单独一个文件、权限 600，不放 config——
// config 常被整份贴出来问问题；用户 09-16 要 init 引导填
export const tokenPath = () => path.join(VT_HOME, 'token');
export const vtToken = () => (readText(tokenPath()) || '').trim();
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
// 登记表 projects/<sha>：第一行是主 checkout 路径（所有读它的地方都只取第一行），之后可选 project_id=<名>（K17 的显式配置，projects add --name）
export function vtRegister(dir, name = '') {
  const m = vtMainCheckout(dir);
  if (!m) return null;
  mkdirp(path.join(VT_HOME, 'projects'));
  const f = path.join(VT_HOME, 'projects', vtSha(m));
  const extra = (readText(f) || '').split('\n').slice(1).filter((l) => l !== '' && !(name && l.startsWith('project_id=')));
  fs.writeFileSync(f, [m, ...(name ? [`project_id=${name}`] : []), ...extra].join('\n') + '\n');
  return m;
}
// K17（采集端协议「项目和工作区标识」，09-16 对照核出，push 前必须改）：
//   project_id   简单可读的项目名：登记表里显式写的（projects add --name）> origin 远端的仓库名（git@host:team/payment-service.git → payment-service）
//                > 主 checkout 的目录名。不得含用户名、token、本机完整路径。09-16 以前发的是 github.com/acme/xxx 这种主机加路径、没远端时是本机路径
//   workspace_id 不透明的稳定字符串：第一次见到这个工作区时生成 UUID，持久化在 ~/.vibetrail/workspaces/<sha1 前 16 位(主 checkout 路径)>，
//                collector 不解析它、按 user + workspace_id + agent + session 关联会话——推出去之后再换，同一个仓的历史在云端分成两份。
//                按主 checkout 一个（worktree 共享，与登记表、spool 的分区键一致；每个 worktree 一个会把 desktop 每次开的 worktree 都碎成新工作区），接 collector 时再确认。
//                uninstall 像 ids 一样留着（重装后不换）；--purge 才删。两家三方都没有这一层：teamai 报完整路径加服务端分配的数字 id，Pilot 报 owner/repo 加完整路径
export const repoNameOf = (url) => {
  const u = String(url || '').trim().replace(/\/+$/, '').replace(/\.git$/i, '').replace(/\/+$/, '');
  return u.split(/[/:\\]/).filter(Boolean).pop() || '';
};
export function vtProjectName(workspace) {
  const reg = readText(path.join(VT_HOME, 'projects', vtSha(workspace)));
  if (reg) for (const l of reg.split('\n').slice(1)) if (l.startsWith('project_id=') && l.slice(11).trim() !== '') return l.slice(11).trim().slice(0, 256);
  const origin = git(workspace, ['remote', 'get-url', 'origin']);
  const name = (origin ? repoNameOf(origin) : '') || path.basename(workspace) || 'unknown';
  return name.slice(0, 256);
}
export const workspaceIdPath = (workspace) => path.join(VT_HOME, 'workspaces', vtSha(workspace));
const isUuid = (v) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(v || ''));
export function vtWorkspaceId(workspace) {
  const f = workspaceIdPath(workspace);
  const cur = (readText(f) || '').split('\n')[0].trim();
  if (isUuid(cur)) return cur;
  mkdirp(path.dirname(f));
  const id = crypto.randomUUID();
  try { fs.writeFileSync(f, `${id}\n${workspace}\n`, { flag: 'wx' }); return id; }   // 两个 hook 同时第一次见到：只有一个写成，另一个读它的
  catch {
    const again = (readText(f) || '').split('\n')[0].trim();
    return isUuid(again) ? again : eventId('workspace', workspace);   // 写不进去（只读的 home）：退到按路径算的 UUIDv5，至少稳定
  }
}
export function vtWorktrees(workspace) {     // 主 checkout 在前，之后是它的每个 worktree（K22 的文件路径按这些根算相对路径）
  const out = [workspace];
  const wl = git(workspace, ['worktree', 'list', '--porcelain']) || '';
  for (const l of wl.split('\n')) if (l.startsWith('worktree ')) { const p = vtRealpath(l.slice(9)); if (!out.includes(p)) out.push(p); }
  return out;
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
  // 同一进程同一秒再写同一来源时块名会撞上，rename 会把前一块整个盖掉——前一块的 event_id 已经记进 ids，那些事件就永远丢了。
  // 子 agent 文件在一次 hook 里会映射两遍（先写起止与调用，收到完成信号再补最后一次回答），所以很常见（09-17 端到端测试发现）。撞名时 pid 后面加 _2、_3
  let chunk = `${stamp}-${process.pid}-${name}.jsonl`;
  for (let n = 2; exists(path.join(dest, chunk)); n++) chunk = `${stamp}-${process.pid}_${n}-${name}.jsonl`;
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
//   workflows  {runId: {call_id, task_id}}：Workflow 调用的启动结果（K11），workflow 起的 agent 靠它挂回主会话那次调用
//   files      {agentId: {相对路径: create|modify|read}}、files_outside {agentId: 根外的次数}：子 agent 自己改读的文件（K22 子 agent 部分）
// 只增不改：launched / workflows 已有的不覆盖，时间取较晚的，文件取最重的操作
const objOr = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? v : {});
const OP_RANK = { create: 3, modify: 2, read: 1 };
export const vtAgents = (sid) => {
  const v = objOr(readJson(path.join(VT_HOME, 'state', sid, 'agents.json'), {}));
  return { launched: objOr(v.launched), done: objOr(v.done), calls_done: objOr(v.calls_done), workflows: objOr(v.workflows),
    files: objOr(v.files), files_outside: objOr(v.files_outside) };
};
export function vtAgentsSave(sid, fresh, agentFiles = null, agentFilesOutside = null) {
  if (!fresh && !agentFiles) return true;
  const cur = vtAgents(sid);
  let changed = false;
  for (const m of ['launched', 'workflows']) {
    for (const [k, v] of Object.entries(objOr(fresh?.[m]))) if (!(k in cur[m])) { cur[m][k] = v; changed = true; }
  }
  for (const m of ['done', 'calls_done']) {
    for (const [k, v] of Object.entries(objOr(fresh?.[m]))) if (typeof v === 'string' && !(typeof cur[m][k] === 'string' && cur[m][k] >= v)) { cur[m][k] = v; changed = true; }
  }
  for (const [aid, files] of Object.entries(objOr(agentFiles))) {
    const have = objOr(cur.files[aid]);
    for (const [p, op] of Object.entries(objOr(files))) {
      if (OP_RANK[op] === undefined) continue;
      if (have[p] === undefined || OP_RANK[op] > OP_RANK[have[p]]) { have[p] = op; changed = true; }
    }
    if (Object.keys(have).length > 0) cur.files[aid] = have;
  }
  for (const [aid, n] of Object.entries(objOr(agentFilesOutside))) {
    if (typeof n === 'number' && n > (cur.files_outside[aid] ?? 0)) { cur.files_outside[aid] = n; changed = true; }
  }
  if (!changed) return true;
  try { vtWriteJson(path.join(VT_HOME, 'state', sid, 'agents.json'), cur); return true; } catch { return false; }
}

// 子 agent 的 transcript：<sid>/subagents/agent-<id>.jsonl；workflow 起的在 <sid>/subagents/workflows/<runId>/agent-<id>.jsonl（K11，09-16 用 Workflow 实测；
// 同目录还有 journal.jsonl，不是 transcript）。被子 agent 派出的子 agent 与一级的同层，meta 里 spawnDepth = 2、parentAgentId 是派它的 agent
export const subagentRootOf = (file) => { const i = String(file).lastIndexOf('/subagents/'); return i >= 0 ? String(file).slice(0, i + '/subagents'.length) : ''; };
export const workflowRunOf = (file) => { const m = String(file).match(/\/subagents\/workflows\/([^/]+)\/agent-[^/]+\.jsonl$/); return m ? m[1] : null; };
const readMeta = (jsonl) => objOr(readJson(jsonl.replace(/\.jsonl$/, '.meta.json'), {}));
// 一个会话的全部子 agent 文件（递归，最多往下 3 层），[{file, name, aid, depth, run}]：深的在前——父 agent 映射时要用到子 agent 已经记下的文件与结束
export function vtSubagentFiles(subRoot) {
  const out = [];
  const walk = (dir, level) => {
    if (level > 3) return;
    let names = []; try { names = fs.readdirSync(dir); } catch { return; }
    for (const f of names.sort()) {
      const p = path.join(dir, f);
      if (/^agent-.+\.jsonl$/.test(f)) {
        if (!isFile(p)) continue;
        const meta = readMeta(p);
        out.push({ file: p, name: f.replace(/\.jsonl$/, ''), aid: f.replace(/^agent-/, '').replace(/\.jsonl$/, ''),
          depth: Number(meta.spawnDepth) > 0 ? Number(meta.spawnDepth) : 1, run: workflowRunOf(p) });
      } else if (!f.endsWith('.json') && !f.endsWith('.jsonl') && isDir(p)) walk(p, level + 1);
    }
  };
  walk(subRoot, 0);
  return out.sort((a, b) => b.depth - a.depth || (a.file < b.file ? -1 : a.file > b.file ? 1 : 0));
}
// 一个会话里的子 agent：{agentId: {call_id, agent_type, parent_agent, workflow_run}}（meta.json 的 toolUseId / agentType / parentAgentId；没有 meta 的只有 id）
export function vtKnownAgents(subRoot) {
  const out = {};
  const walk = (dir, level) => {
    if (level > 3) return;
    let names = []; try { names = fs.readdirSync(dir); } catch { return; }
    for (const f of names.sort()) {
      const p = path.join(dir, f);
      const m = f.match(/^agent-(.+)\.(jsonl|meta\.json)$/);
      if (!m) { if (!f.includes('.') && isDir(p)) walk(p, level + 1); continue; }
      const a = (out[m[1]] ||= {});
      const run = workflowRunOf(p.replace(/\.meta\.json$/, '.jsonl'));
      if (run) a.workflow_run = run;
      if (m[2] !== 'meta.json') continue;
      const mm = objOr(readJson(p, {}));
      if (typeof mm.toolUseId === 'string' && mm.toolUseId) a.call_id = mm.toolUseId;
      if (typeof mm.agentType === 'string' && mm.agentType) a.agent_type = mm.agentType;
      if (typeof mm.parentAgentId === 'string' && mm.parentAgentId) a.parent_agent = mm.parentAgentId;
    }
  };
  walk(subRoot, 0);
  return out;
}
// 一个会话的 workflow run：{runId: {task_id, agents: {agentId: {status, result, label, phase, agent_type}}}}。
// 每个 agent 跑完没有看 journal.jsonl（started / result 两种行，实测）：有 result 是 completed；带 agentId 的其他终态行按名字归到 failed / cancelled；
// 只有 started 的是还在跑（status 为 null）。taskId 在 <sid>/workflows/<runId>.json（与 subagents 同级）
export function vtWorkflowRuns(subRoot) {
  const out = {};
  const wfDir = path.join(subRoot, 'workflows');
  let runs = []; try { runs = fs.readdirSync(wfDir).filter((d) => isDir(path.join(wfDir, d))); } catch { return out; }
  for (const rid of runs.sort()) {
    const run = { agents: {} };
    const rj = objOr(readJson(path.join(path.dirname(subRoot), 'workflows', `${rid}.json`), {}));
    if (typeof rj.taskId === 'string' && rj.taskId) run.task_id = rj.taskId;
    for (const line of (readText(path.join(wfDir, rid, 'journal.jsonl')) || '').split('\n')) {
      if (!line) continue;
      let j; try { j = JSON.parse(line); } catch { continue; }
      if (!j || typeof j.agentId !== 'string' || !j.agentId) continue;
      const a = (run.agents[j.agentId] ||= { status: null });
      if (typeof j.label === 'string') a.label = j.label;
      if (typeof j.phase === 'string') a.phase = j.phase;
      const t = String(j.type ?? '');
      if (t === 'started' || t === 'launched') continue;
      if (t === 'result') {
        a.status = 'completed';
        if (j.result !== undefined && j.result !== null) a.result = typeof j.result === 'string' ? j.result : JSON.stringify(j.result);
      } else a.status = /cancel|skip|abort|kill|stop/i.test(t) ? 'cancelled' : /error|fail/i.test(t) ? 'failed' : 'unknown';
    }
    for (const [aid, a] of Object.entries(run.agents)) {
      const meta = readMeta(path.join(wfDir, rid, `agent-${aid}.jsonl`));
      if (typeof meta.agentType === 'string' && meta.agentType) a.agent_type = meta.agentType;
    }
    out[rid] = run;
  }
  return out;
}
// workflow agent 文件比主会话先映射（为了让主会话收到通知时已经知道子 agent 改了哪些文件），第一次见到一个 run 时 agents.json 里还没有它的启动结果：
// 直接在主会话 transcript 里找 "runId":"<runId>" 那一行，取它的 tool_use_id。只在第一次找，找到就存进 agents.json
export function vtWorkflowLaunch(mainT, runId) {
  const txt = readText(mainT);
  if (!txt) return null;
  const at = txt.indexOf(`"runId":"${runId}"`);
  if (at < 0) return null;
  const line = txt.slice(txt.lastIndexOf('\n', at) + 1, (txt.indexOf('\n', at) + 1 || txt.length + 1) - 1);
  let r; try { r = JSON.parse(line); } catch { return null; }
  const block = (Array.isArray(r?.message?.content) ? r.message.content : []).find((b) => b && b.type === 'tool_result');
  const tres = objOr(r?.toolUseResult);
  if (!block || typeof block.tool_use_id !== 'string') return null;
  return { call_id: block.tool_use_id, ...(typeof tres.taskId === 'string' ? { task_id: tres.taskId } : {}) };
}

// A11 完整性钉子的运行时部分：每份 transcript 新读到的记录走到了哪（映射账本的 new 计数），按会话累计在 state/<sid>/integrity.json，doctor 汇总。
// 与 main.json 一样随 uninstall 删、文件被重写时这份文件的计数清零（从头重读，不重复计）。恒等式：seen = records + bad_json + skipped_non_object + skipped_no_uuid + replayed + inherited
const INTEGRITY_KEYS = ['seen', 'records', 'bad_json', 'skipped_non_object', 'skipped_no_uuid', 'replayed', 'inherited', 'content_dropped', 'marker', 'marker_without_hit', 'truncated_bytes'];
export const vtIntegrity = (sid) => objOr(readJson(path.join(VT_HOME, 'state', sid, 'integrity.json'), {}));
export function vtIntegrityAdd(sid, name, nw, { reset = false, truncatedBytes = 0 } = {}) {
  try {
    const cur = vtIntegrity(sid);
    const files = objOr(cur.files);
    const f = reset ? {} : objOr(files[name]);
    const n = objOr(nw);
    const add = (k, v) => { if (typeof v === 'number' && v > 0) f[k] = (f[k] ?? 0) + v; };
    for (const k of ['seen', 'records', 'bad_json', 'skipped_non_object', 'skipped_no_uuid', 'replayed', 'inherited', 'content_dropped']) add(k, n[k]);
    add('marker', objOr(n.sentinel).marker); add('marker_without_hit', objOr(n.sentinel).marker_without_hit);
    add('truncated_bytes', truncatedBytes);
    const ut = objOr(f.unknown_types);
    for (const [k, v] of Object.entries(objOr(n.unknown_types))) if (typeof v === 'number') ut[k] = (ut[k] ?? 0) + v;
    if (Object.keys(ut).length > 0) f.unknown_types = ut;
    files[name] = f;
    vtWriteJson(path.join(VT_HOME, 'state', sid, 'integrity.json'), { files, updated_at: nowIso() });
    return true;
  } catch { return false; }
}
export const integrityKeys = INTEGRITY_KEYS;

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
  const { project_id, workspace_id, vt_version, agent_version, surface, now, vcs, extra = {}, roots = null } = ctx;
  const hname = p.hook_event_name || event;
  // 本机路径不出本机（用户 09-16 定相对路径）：worktree 与 cwd 相对主 checkout（主 checkout 本身是 .，desktop 的 worktree 是 .claude/worktrees/<名>），其余换成 ~ 形
  const dir = (v) => (typeof v === 'string' && v !== '' ? displayDir(v, roots) : null);
  const b = {
    event_id: null, occurred_at: now, type: null,
    agent: { name: 'claude-code', ...opt('version', agent_version), ...(codeOk(surface) ? { surface } : {}) },
    project_id, workspace_id, session_id: p.session_id ?? null,
    agent_instance_id: p.agent_id ?? 'main',
    provenance: { kind: 'hook', source_event: hname },
    payload: {},
    extensions: { 'vibetrail.version': vt_version, ...opt('vibetrail.worktree', dir(extra.worktree ?? (vcs && vcs.worktree) ?? null)) },
  };
  const withTurn = (e) => {
    if (typeof p.prompt_id === 'string' && p.prompt_id !== '') { e.turn_id = p.prompt_id; }
    else { e.turn_id = 'inferred-' + now; e.provenance = { kind: 'inferred', rule_version: RULE_VERSIONS.turn, source_event: hname }; }
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
        ...opt('vibetrail.vcs', vcsOf(vcs)), ...opt('vibetrail.cwd', dir(p.cwd ?? null)) };
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
  // 子 agent 文件是 …/<sid>/subagents/agent-<id>.jsonl，workflow 起的在 …/<sid>/subagents/workflows/<runId>/agent-<id>.jsonl（K11），meta 是同名 .meta.json；
  // 被子 agent 派出的子 agent（spawnDepth ≥ 2）：新版 meta 直接给 parentAgentId（09-16 实测），老版本没有就去别的子 agent 文件里找派它的那次调用
  const subRoot = subagentRootOf(file);
  if (!opts.sid) opts = { ...opts, sid: subRoot ? path.basename(path.dirname(subRoot)) : path.basename(file).replace(/\.jsonl$/, '') };
  const run = workflowRunOf(file);
  if (opts.meta === undefined || opts.meta === null) {
    const mf = file.replace(/\.jsonl$/, '') + '.meta.json';
    const m = isFile(mf) ? readJson(mf, null) : null;
    opts = { ...opts, meta: m !== null && typeof m === 'object' && !Array.isArray(m) ? m : null };
  }
  if (run) opts = { ...opts, meta: { ...(opts.meta ?? {}), workflowRunId: run } };
  if (!opts.parent_instance) {
    let parent = 'main';
    const tid = opts.meta?.toolUseId ?? '';
    const depth = Number(opts.meta?.spawnDepth);
    if (typeof opts.meta?.parentAgentId === 'string' && opts.meta.parentAgentId) parent = opts.meta.parentAgentId;
    else if (subRoot && tid && !run && depth !== 1) {
      for (const x of vtSubagentFiles(subRoot)) {
        if (x.file === file) continue;
        const txt = readText(x.file);
        if (txt && txt.includes(`"id":"${tid}"`)) { parent = x.aid; break; }
      }
    }
    opts = { ...opts, parent_instance: parent };
  }
  // project_id / workspace_id / 工作区根没给（map-file 命令行、测试）：按第一条带 cwd 记录的 cwd 推——cwd 在本机的 git 仓里就与 hook 同一套
  // （主 checkout 的项目名、持久化的工作区 UUID、它的 worktree 当根），不在就用 cwd 的目录名、按 cwd 这个字符串持久化的 UUID、cwd 当根（K17 / K22）
  if (!opts.project_id || !opts.workspace_id || !opts.workspace_roots) {
    let cwd = '';
    try {
      const head = fs.readFileSync(file, 'utf8').slice(0, 1024 * 1024);
      for (const line of head.split('\n')) {
        if (!line) continue;
        try { const r = JSON.parse(line); if (r && typeof r === 'object' && typeof r.cwd === 'string') { cwd = r.cwd; break; } } catch {}
      }
    } catch {}
    if (!cwd) cwd = 'unknown';
    const main = cwd !== 'unknown' && isDir(cwd) ? vtMainCheckout(cwd) : null;
    opts = { ...opts,
      project_id: opts.project_id || (main ? vtProjectName(main) : (path.basename(cwd) || 'unknown')),
      workspace_id: opts.workspace_id || vtWorkspaceId(main || cwd),
      workspace_roots: opts.workspace_roots || (main ? vtWorktrees(main) : [cwd]) };
  }
  const {
    sid, project_id, workspace_id, workspace_roots = null, parent_instance = 'main', meta = null,
    start_line = 1, start_byte = null, from_line = 0, seenFile = '', hook_turns = {}, hook_perms = [],
    perm_since = '', perm_periods = null, split_decisions = {}, close_last = '', stop_turn = '', turns = true, capture_content = '1', vt_version = VT_RUNTIME_VERSION,
    done_ts = null,
  } = opts;
  // 这个会话已知的子 agent 与 workflow run：没给就看这个会话的 subagents 目录（递归）
  const sessionSubRoot = subRoot || path.join(path.dirname(file), sid, 'subagents');
  const known_agents = opts.known_agents ?? vtKnownAgents(sessionSubRoot);
  const workflow_runs = opts.workflow_runs ?? (subRoot ? {} : vtWorkflowRuns(sessionSubRoot));
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

  // 按物理行喂：坏行、空行也占位（BAD_LINE / BLANK_LINE），映射器的行号才与这里按换行符换算的字节 checkpoint 一致（09-16 修：以前直接丢，
  // 中间一出现坏行，checkpoint 换算成字节就错位一行）。text 停在最后一个换行符之后，split 出来的最后一段是空串，不是一行
  const records = [];
  const parts = text.split('\n');
  if (parts.length > 0 && parts[parts.length - 1] === '') parts.pop();
  for (const line of parts) {
    if (line.trim() === '') { records.push(BLANK_LINE); continue; }
    try { records.push(JSON.parse(line)); } catch { records.push(BAD_LINE); }
  }
  const { events, ledger } = mapRecords(records, {
    sid, project_id, workspace_id, workspace_roots, parent_instance, start_line: firstLine, from_line, meta,
    seen_uuids: seenFile && isFile(seenFile)
      ? readText(seenFile).split('\n').filter(Boolean).map((l) => { const [u, n] = l.split('\t'); return [u, Number(n)]; })
      : [],
    hook_turns, hook_perms, perm_since, perm_periods, split_decisions, known_agents, workflow_runs, done_ts, close_last, stop_turn, turns, vt_version, rule_version: RULE_VERSIONS.diverge, capture_content,
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
  // K17：project_id 是简单项目名、workspace_id 是持久化的 UUID（见 vtProjectName / vtWorkspaceId）；workspace 仍是主 checkout 路径，
  // 只用来分区 spool、找 transcript 目录、算 K22 的相对路径（roots = 主 checkout + 它的 worktree），不再进事件
  const setProject = (workspace) => {
    ctx = { ...ctx, workspace, project_id: vtProjectName(workspace), workspace_id: vtWorkspaceId(workspace), roots: vtWorktrees(workspace), pkey: vtProjectKey(workspace) };
  };
  setProject(main || vtRealpath(cwd || '.'));
  const SD = path.join(VT_HOME, 'state', sid);
  const agentVersion = vtAgentVersion(tpath);
  const surface = process.env.CLAUDE_CODE_ENTRYPOINT || '';

  const emitHook = (name, vcs, extra = {}) => {
    const events = hookEvents(name, p, { project_id: ctx.project_id, workspace_id: ctx.workspace_id, vt_version: VT_RUNTIME_VERSION,
      agent_version: agentVersion, surface, now: nowIso(), vcs, extra, roots: ctx.roots });
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
  const processFile = (s2, sd, f, name, close = '', stopTurn = '', subRoot = '', mainT = '') => {
    let size;
    try { size = fs.statSync(f).size; } catch { return; }
    const stFile = path.join(sd, `${name}.json`), seenFile = path.join(sd, `${name}.seen`);
    // 子 agent 文件只在它结束后才把最后一次调用写出。结束信号（09-16 起）在父文件里：同步 agent 的调用结果、后台 agent 的
    // <task-notification>，映射父文件时记进 agents.json；映射器拿它与这份文件最后一条记录的时间比（close_last = if_done）。
    // workflow 起的 agent（K11）看同目录 journal.jsonl 里它有没有终态行；<name>.done 是老版本 SubagentStop hook 留下的（记的是当时的文件大小），升级过渡期照认
    const aid = name.replace(/^agent-/, '');
    const ag = vtAgents(s2);
    const known = subRoot ? vtKnownAgents(subRoot) : {};
    for (const [k, v] of Object.entries(ag.launched)) known[k] = { ...objOr(v), ...objOr(known[k]) };
    for (const [k, v] of Object.entries(ag.files)) known[k] = { ...objOr(known[k]), files: objOr(v), files_outside: ag.files_outside[k] ?? 0 };
    const runs = subRoot ? vtWorkflowRuns(subRoot) : {};
    for (const [rid, w] of Object.entries(ag.workflows)) if (runs[rid]) runs[rid] = { ...objOr(w), ...runs[rid], ...(w.call_id ? { call_id: w.call_id } : {}) };
    const run = workflowRunOf(f);
    let doneTs = null, meta;
    if (name !== 'main') {
      const tid = known[aid]?.call_id;
      doneTs = [ag.done[aid], tid ? ag.calls_done[tid] : null].filter((x) => typeof x === 'string').sort().pop() ?? null;
      if (!['session_end', 'resume', 'idle'].includes(close)) {
        const wfDone = run && typeof runs[run]?.agents?.[aid]?.status === 'string';
        close = (readText(path.join(sd, `${name}.done`)) || '').trim() === String(size) || wfDone ? 'stop' : doneTs ? 'if_done' : '';
      }
      if (run) {
        // workflow agent 的 meta 没有 toolUseId：补上那次 Workflow 调用的 id（agents.json 里没有就去主会话找一次、存下来）
        let w = objOr(ag.workflows[run]);
        if (!w.call_id && mainT) {
          const found = vtWorkflowLaunch(mainT, run);
          if (found) { vtAgentsSave(s2, { workflows: { [run]: found } }); w = found; }
        }
        meta = { ...readMeta(f), ...(w.call_id ? { toolUseId: w.call_id } : {}) };
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
    let rewritten = false;
    if (consumed > 0 && (size < consumed || (fpOld !== '' && vtFprint(f, consumed) !== fpOld))) {
      try { fs.unlinkSync(stFile); } catch {}
      try { fs.unlinkSync(seenFile); } catch {}
      lines = 0; consumed = 0; ckl = 1; ckb = 0; rewrites += 1; rewritten = true;
    }
    let out;
    try {
      out = mapFile(f, { sid: s2, project_id: ctx.project_id, workspace_id: ctx.workspace_id, workspace_roots: ctx.roots,
        start_line: ckl, start_byte: ckb, from_line: lines, seenFile,
        hook_turns: name === 'main' ? vtHookTurns(s2) : {},
        hook_perms: vtHookPerms(s2), perm_periods: vtPermPeriods(), split_decisions: vtSplits(s2),
        close_last: name === 'main' || close ? close : '', stop_turn: name === 'main' ? stopTurn : '',
        known_agents: known, workflow_runs: name === 'main' ? runs : {}, ...(meta ? { meta } : {}),
        done_ts: doneTs, capture_content: vtConf('capture_content', '1') });
    } catch (e) { vtLogError(ev, s2, `map:${name}`, 2); return; }
    // 结论先落盘再写 spool：反过来的话，spool 写进去了、结论没存上，下次重读就可能判出另一种、发出矛盾的事件
    if (!vtSplitsSave(s2, out.ledger.split_decisions_new)) { vtLogError(ev, s2, `splits:${name}`, 1); return; }
    if (!vtAgentsSave(s2, out.ledger.agents, out.ledger.agent_files, out.ledger.agent_files_outside)) vtLogError(ev, s2, `agents:${name}`, 1);
    if (!vtSpoolWrite(ctx.pkey, s2, name, out.events)) { vtLogError(ev, s2, `spool:${name}`, 1); return; }
    const srcLines = (out.ledger.sources || []).map(([u, n]) => `${u}\t${n}`).join('\n');
    if (srcLines) { try { fs.appendFileSync(seenFile, srcLines + '\n'); } catch {} }
    const fp = vtFprint(f, out.ledger.consumed_bytes) ?? '';
    const stNew = { lines: out.ledger.lines, consumed_bytes: out.ledger.consumed_bytes, file_bytes: out.ledger.file_bytes,
      checkpoint_line: out.ledger.checkpoint_line, checkpoint_byte: out.ledger.checkpoint_byte,
      parent_instance: out.ledger.parent_instance, fprint: fp, rewrites,
      turn_open: out.ledger.turns.open ?? null, turn_closed: out.ledger.turns.closed ?? false,
      call_open: out.ledger.trace?.call_open ?? false, last_ts: out.ledger.last_ts ?? null, updated_at: new Date().toISOString().replace(/\.\d+Z$/, 'Z') };
    let stateOk = true;
    try { fs.writeFileSync(stFile + '.tmp', JSON.stringify(stNew) + '\n'); fs.renameSync(stFile + '.tmp', stFile); } catch { stateOk = false; }
    // A11：state 推进了才记这次新读到的行（写不进 state 的话下次会重读，先记就重复计）；文件被重写从头读的，先把这份文件的计数清零
    if (stateOk && !vtIntegrityAdd(s2, name, out.ledger.new, { reset: rewritten, truncatedBytes: out.ledger.truncated_bytes ?? 0 })) vtLogError(ev, s2, `integrity:${name}`, 1);
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
      // 顺序（09-16 改）：子 agent 文件先（深的在前），再主会话，信号变了再把子 agent 文件过一遍——
      // 父文件发子 agent 的 subagent.end、关这一轮时要用到子 agent 自己改了哪些文件（K22）；子 agent「写完了」又要看父文件里的结束信号，所以最后补一遍（没变的文件直接跳过）
      const subRoot = path.join(path.dirname(mainT), s2, 'subagents');
      const subs = vtSubagentFiles(subRoot);
      const signals = () => { const a = vtAgents(s2); return JSON.stringify([a.launched, a.done, a.calls_done, a.workflows]); };
      const before = signals();
      for (const x of subs) processFile(s2, sd, x.file, x.name, close, '', subRoot, mainT);
      if (isFile(mainT)) processFile(s2, sd, mainT, 'main', close, stopTurn, subRoot, mainT);
      if (subs.length > 0 && signals() !== before) {
        for (const x of subs) processFile(s2, sd, x.file, x.name, close, '', subRoot, mainT);
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
  // K24（协议「Stop hook 阻止 Agent 停止时，轮次仍在继续，不得提前发送 turn.end」）：Stop 时先等 Claude Code 自己的答完标记
  // （system/stop_hook_summary，写在全部 Stop hook 跑完之后）或拦停反馈（hook_blocking_error 附件、「Stop hook feedback:」）落盘，再解析：
  // 有标记就按标记关轮（拦停了就不关），等不到（默认上限 stop_wait=10 s，config 可改）才走 D7 的老路——按 Stop 当场关，被拦下后再 Stop 时补一条 stops 更大的。
  // 本机实测（09-16，52 轮）标记落盘比最后一条回复晚 p50 1.9 s、最大 3.9 s，10 s 上限足够；我们的 Stop hook 是 async、不拖慢别人，
  // 多等这几秒人感觉不到。看的是主会话文件末尾 1 MB：最后一条真回复之后有标记就算到了
  const stopMarkerState = (f) => {                 // 'summary' | 'blocked' | 'none'
    let size; try { size = fs.statSync(f).size; } catch { return 'none'; }
    const off = Math.max(0, size - 1024 * 1024);
    let txt;
    try { const fd = fs.openSync(f, 'r'); const buf = Buffer.alloc(size - off); fs.readSync(fd, buf, 0, size - off, off); fs.closeSync(fd); txt = buf.toString('utf8'); }
    catch { return 'none'; }
    const lines = txt.split('\n');
    if (off > 0) lines.shift();                    // 第一段多半是半行
    let asst = -1, summary = -1, blocked = -1;
    for (let i = 0; i < lines.length; i++) {
      if (!lines[i]) continue;
      let r; try { r = JSON.parse(lines[i]); } catch { continue; }
      if (!r || typeof r !== 'object' || r.isSidechain === true || r.agentId) continue;
      if (r.type === 'assistant' && r.message?.model !== '<synthetic>') asst = i;
      else if (r.type === 'system' && r.subtype === 'stop_hook_summary') summary = i;
      else if ((r.type === 'attachment' && /^hook_(blocking_error|additional_context)$/.test(String(r.attachment?.type ?? '')) && /^(Stop|SubagentStop)$/.test(String(r.attachment?.hookEvent ?? '')))
        || (r.type === 'user' && JSON.stringify(r.message?.content ?? '').includes('Stop hook feedback:'))) blocked = i;
    }
    if (summary > asst && summary >= blocked) return 'summary';
    if (blocked > asst) return 'blocked';
    return 'none';
  };
  const waitStopMarker = (f) => {
    const limit = Number(process.env.VIBETRAIL_STOP_WAIT ?? vtConf('stop_wait', '10'));
    if (!(limit > 0)) return 'off';
    const deadline = Date.now() + limit * 1000;
    for (;;) {
      const s = stopMarkerState(f);
      if (s !== 'none') return s;
      if (Date.now() >= deadline) return 'timeout';
      sleepSync(250);
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
      if (isFile(tpath)) { waitStable(tpath); waitStopMarker(tpath); processSession(sid, tpath, 'stop', promptId); }
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
