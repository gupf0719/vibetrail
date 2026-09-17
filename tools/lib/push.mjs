// vibetrail push：把本机 spool 按协议 1.0 批量推给 collector（DESIGN §4、D15；TODO G7 的 push 一项）。
//
// - 什么时候推（用户 09-17 定，D15，推翻 D6 的门槛）：会话开始补做完、每轮答完（Stop）、会话结束这三个 hook 跑完就推，不攒、不另起常驻进程——
//   攒门槛会让最后几轮一直留在本机。一次限时 60 s，推不完下一次接着推；锁被占着就等它放开，已经有人在等就直接走（autoPush）。
// - 批是 ack 单位，不是块（09-16 复核）：每块在 state/push/state.json 里记已了结到第几行（cursors），按批发、批 ack 推进，
//   到末尾才删块；进程在 ack 与推进之间被杀最多重发一批，event_id 幂等兜住（服务端记 duplicate）。
// - 一批最多 100 条、请求体不超 16 MiB，可以混多个项目、多个会话；从最早的块发起。同一批里同一个 event_id 只发第一条——
//   内容不同时服务端整批 409（本机 09-16 的旧块与 09-17 重采的块就有 3,007 个这样的 id）。
// - 被拒收只隔离那几条，同批其余照发：422 带出错位置（/events/N/…，服务端最多列 10 处）、409 / 413 带 event_id，
//   不带位置的（INVALID_TIME 等）二分找出来。隔离 = 原样挪进 spool/.rejected/，原因只记元数据，`vibetrail push --requeue` 放回。
// - 端点、token、网络、5xx 这类问题不动数据，只退避：1 分钟起指数到 1 小时封顶、带抖动；所有自动触发点都看退避，手动 vibetrail push 不看。
// - token 只进请求头：不进命令行、日志、state；fetch 抛的错只记 code，不记 message（header 值非法时 message 里带着值）。
import fs from 'node:fs';
import path from 'node:path';
import { VT_HOME, VT_RUNTIME_VERSION, vtConf, vtToken, vtLogError, eventId, vtRedactToken } from './hook.mjs';

export const API_PATH = '/api/v1/collection/batches';
const MAX_BATCH_EVENTS = 100;                                   // 协议：每批 1～100 条
const MAX_EVENT_BYTES = 1024 * 1024;                            // 协议：单条 ≤ 1 MiB（超了服务端整批 413）
const envNum = (k, d) => (Number(process.env[k]) > 0 ? Number(process.env[k]) : d);
const MAX_REQUEST_BYTES = envNum('VIBETRAIL_PUSH_MAX_REQUEST_BYTES', 16 * 1024 * 1024);   // 协议：整个请求 ≤ 16 MiB；测试调小
const TIMEOUT_MS = envNum('VIBETRAIL_PUSH_TIMEOUT_MS', 30000);  // 每个请求 30 s（DESIGN §4）；测试调小
const DIE_AFTER_ACK = envNum('VIBETRAIL_PUSH_DIE_AFTER_ACK', 0); // 测试：第 N 次 ack 之后、记账之前直接退出，模拟被杀
const BUDGET_MS = envNum('VIBETRAIL_PUSH_BUDGET_MS', 60000);    // hook 触发的一次推送最多跑多久；测试调小
const LOCK_WAIT_MS = envNum('VIBETRAIL_PUSH_LOCK_WAIT_MS', 90000); // 锁被占着时最多等多久：限时 60 s + 一个请求的超时 30 s
const WAITER_STALE_S = 150;                                     // 等锁的人的标记多久没刷新就算死了
const STALE_PENDING_MS = 3600 * 1000;                           // doctor：待发的最早一块超过这么久就告警（说明一直没有 hook 触发或一直失败）
const LOCK_STALE_S = 600;                                       // 机器级锁的陈旧阈值（DESIGN §4）；每发一个请求刷新一次，跑得久的手动 push 不会被当成陈旧
const BACKOFF_BASE_S = 60, BACKOFF_CAP_S = 3600;
const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const UUID_G = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/g;
const STAMP_RE = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z-/;

const say = (s = '') => process.stdout.write(s + '\n');
const readJson = (p, d) => { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return d; } };
const readdir = (d) => { try { return fs.readdirSync(d).sort(); } catch { return []; } };
const mkdirp = (p) => { try { fs.mkdirSync(p, { recursive: true }); return true; } catch { return false; } };
const objOr = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? v : {});
const num = (v, d = 0) => (typeof v === 'number' && Number.isFinite(v) && v >= 0 ? v : d);
const isoNow = () => new Date().toISOString();
export const maskToken = (t) => (t.length >= 16 ? `末 4 位 ${t.slice(-4)}` : `${t.length} 个字符`);   // 短的一位都不露

const pushDir = () => path.join(VT_HOME, 'state', 'push');
const statePath = () => path.join(pushDir(), 'state.json');
const rejectLog = () => path.join(pushDir(), 'rejected.jsonl');
export const rejectedDir = () => path.join(VT_HOME, 'spool', '.rejected');

// endpoint= 可以只写到端口（http://10.78.73.4:8080），也可以写全路径
export function pushEndpoint() {
  const raw = vtConf('endpoint', '').trim();
  if (!raw) return { url: '', error: '' };
  let u;
  try { u = new URL(raw); } catch { return { url: '', error: `不是合法的 URL：${raw}` }; }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return { url: '', error: `只支持 http / https：${raw}` };
  if (u.username || u.password) return { url: '', error: '地址里别带用户名密码，token 用 vibetrail token 填' };
  const base = raw.replace(/\/+$/, '');
  return { url: base.endsWith(API_PATH) ? base : base + API_PATH, error: '' };
}

// ---------- spool 里的块与进度 ----------
// 块：spool/<项目键>/<会话>/<UTC 时间>-<pid>-<名>.jsonl，写入后不变（DESIGN §3.3）；.rejected 与 .xxx.tmp 不算。按块名里的时间从早到晚
export function listBlocks() {
  const root = path.join(VT_HOME, 'spool');
  const out = [];
  for (const pkey of readdir(root)) {
    if (pkey.startsWith('.')) continue;
    for (const sid of readdir(path.join(root, pkey))) {
      if (sid.startsWith('.')) continue;
      for (const name of readdir(path.join(root, pkey, sid))) {
        if (name.startsWith('.') || !name.endsWith('.jsonl')) continue;
        const abs = path.join(root, pkey, sid, name);
        const m = name.match(STAMP_RE);
        let at = m ? Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]) : NaN;
        if (!Number.isFinite(at)) { try { at = fs.statSync(abs).mtimeMs; } catch { continue; } }
        out.push({ rel: `${pkey}/${sid}/${name}`, abs, at, pkey, sid, name });
      }
    }
  }
  return out.sort((a, b) => a.at - b.at || (a.rel < b.rel ? -1 : a.rel > b.rel ? 1 : 0));
}
function readLines(abs) {
  const lines = fs.readFileSync(abs, 'utf8').split('\n');
  if (lines[lines.length - 1] === '') lines.pop();
  return lines;
}
function countLines(abs) {                                      // 与 readLines 的条数一致，不解码
  let b;
  try { b = fs.readFileSync(abs); } catch { return 0; }
  let n = 0;
  for (let i = b.indexOf(10); i !== -1; i = b.indexOf(10, i + 1)) n++;
  return b.length > 0 && b[b.length - 1] !== 10 ? n + 1 : n;
}

export function loadPushState() {
  const s = objOr(readJson(statePath(), {}));
  return { ...s, failures: num(s.failures), next_at: num(s.next_at), cursors: objOr(s.cursors), totals: objOr(s.totals) };
}
function savePushState(st) {
  mkdirp(pushDir());
  const tmp = `${statePath()}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(st) + '\n');
  fs.renameSync(tmp, statePath());
}

// 机器级 mkdir 锁（DESIGN §4）：省请求、账好对；两个 push 真撞上也只是多发一批、服务端记 duplicate
function pushLock() {
  if (!mkdirp(pushDir())) return false;
  const l = path.join(pushDir(), '.lock');
  try { fs.mkdirSync(l); return true; } catch {}
  let age = 0;
  try { age = (Date.now() - fs.statSync(l).mtimeMs) / 1000; } catch { return false; }
  if (age > LOCK_STALE_S) { try { fs.rmdirSync(l); fs.mkdirSync(l); return true; } catch {} }
  return false;
}
const touchLock = () => { try { const t = new Date(); fs.utimesSync(path.join(pushDir(), '.lock'), t, t); } catch {} };
const pushUnlock = () => { try { fs.rmdirSync(path.join(pushDir(), '.lock')); } catch {} };
// 等锁的人也用一把 mkdir 锁，全机最多一个在等：Cursor 每次调工具都有 hook，一串 hook 撞上一次慢推送时不会堆出一串等着的 node 进程
function waiterLock() {
  if (!mkdirp(pushDir())) return false;
  const l = path.join(pushDir(), '.waiter');
  try { fs.mkdirSync(l); return true; } catch {}
  let age = 0;
  try { age = (Date.now() - fs.statSync(l).mtimeMs) / 1000; } catch { return false; }
  if (age > WAITER_STALE_S) { try { fs.rmdirSync(l); fs.mkdirSync(l); return true; } catch {} }
  return false;
}
const touchWaiter = () => { try { const t = new Date(); fs.utimesSync(path.join(pushDir(), '.waiter'), t, t); } catch {} };
const waiterUnlock = () => { try { fs.rmdirSync(path.join(pushDir(), '.waiter')); } catch {} };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 按块、按行往后读；游标到头还没删的块（上次删之前被杀）与空块记进 stale，随下一次记账删掉
class Queue {
  constructor(blocks, cursors) {
    this.blocks = blocks; this.cursors = cursors;
    this.i = -1; this.cur = null; this.lines = []; this.pos = 0; this.stale = [];
    this.open();
  }
  open() {
    for (this.i++; this.i < this.blocks.length; this.i++) {
      const b = this.blocks[this.i];
      try { this.lines = readLines(b.abs); } catch { continue; }            // 读的时候被挪走（projects remove --drop）：跳过
      b.total = this.lines.length;
      this.pos = Math.min(num(this.cursors[b.rel]), b.total);
      if (this.pos >= b.total) { this.stale.push(b); continue; }
      this.cur = b;
      return;
    }
    this.cur = null; this.lines = [];
  }
  peek() {
    if (this.cur && this.pos >= this.lines.length) this.open();
    return this.cur ? { block: this.cur, idx: this.pos, text: this.lines[this.pos] } : null;
  }
  take() { this.pos++; }
}

const clientOf = () => {
  const device = vtConf('device_id', '');
  // client.name 照填、policy_version = none-0 表示暂不脱敏（DESIGN §4.1）
  return UUID_RE.test(device) ? { name: 'paas-coding-hook', version: VT_RUNTIME_VERSION, device_id: device, policy_version: 'none-0' } : null;
};
const envelope = (batchId, client) => `{"schema_version":"1.0","batch_id":"${batchId}","client":${JSON.stringify(client)},"events":[`;
const envelopeBytes = (client) => Buffer.byteLength(envelope('00000000-0000-0000-0000-000000000000', client)) + 2;

// 本地就能断定发不出去的：不是 JSON 对象、没有合法的 event_id（没法去重与 ack）、超 1 MiB。别的交给服务端判
function localProblem(e, bytes) {
  if (e === null || typeof e !== 'object' || Array.isArray(e)) return 'LOCAL_BAD_JSON';
  if (typeof e.event_id !== 'string' || !UUID_RE.test(e.event_id)) return 'LOCAL_BAD_EVENT_ID';
  if (bytes > MAX_EVENT_BYTES) return 'LOCAL_EVENT_TOO_LARGE';
  return '';
}

// → { items: 要发的, settled: 不发也算了结的（空行、批内重复 id）, local: 本地不合格、要隔离的 }。
// 每行先把当前的 token 换成占位（老版本写进 spool 的块里可能有，hook.mjs 的 vtRedactToken），字节按换过的算
function takeBatch(q, envBytes, token) {
  const b = { items: [], settled: [], local: [] };
  const ids = new Set();
  let size = envBytes;
  for (let raw = q.peek(); raw; raw = q.peek()) {
    const it = { ...raw, text: vtRedactToken(raw.text, token) };
    if (it.text.trim() === '') { b.settled.push(it); q.take(); continue; }
    const bytes = Buffer.byteLength(it.text, 'utf8');
    let e = null;
    try { e = JSON.parse(it.text); } catch {}
    const why = localProblem(e, bytes);
    if (why) {
      b.local.push({ ...it, code: why, id: typeof e?.event_id === 'string' ? e.event_id.toLowerCase() : null, type: typeof e?.type === 'string' ? e.type : null });
      q.take(); continue;
    }
    const id = e.event_id.toLowerCase();
    if (ids.has(id)) { b.settled.push(it); q.take(); continue; }
    if (b.items.length >= MAX_BATCH_EVENTS || (b.items.length > 0 && size + 1 + bytes > MAX_REQUEST_BYTES)) break;
    size += bytes + (b.items.length > 0 ? 1 : 0);
    b.items.push({ ...it, bytes, id, type: typeof e.type === 'string' ? e.type : null });
    ids.add(id);
    q.take();
  }
  return b;
}

async function post(url, token, body) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers['Onepaas-Api-Access-Token'] = token;
  let res;
  try {
    res = await fetch(url, { method: 'POST', headers, body, redirect: 'manual', signal: AbortSignal.timeout(TIMEOUT_MS) });
  } catch (err) {
    const code = err?.name === 'TimeoutError' || err?.name === 'AbortError' ? 'TIMEOUT'
      : err?.cause ? String(err.cause.code ?? err.cause.name ?? 'NETWORK').slice(0, 40)
      : 'CLIENT_SETUP';                                          // 没有 cause 的 TypeError：请求没组出来（比如 token 文件被手改坏）
    return { status: 0, code, json: null };
  }
  let text = '';
  try { text = await res.text(); } catch {}
  let json = null;
  try { json = JSON.parse(text); } catch {}
  return { status: res.status, code: typeof json?.code === 'string' ? json.code.slice(0, 60) : '', json };
}

// 失败分类（DESIGN §4 的暂时 / 永久，按 collector 实际返回细化）：只有 content 动数据，其余都只退避
function classify(r) {
  if (r.status === 0) return r.code === 'CLIENT_SETUP' ? 'config' : 'network';
  if (r.status === 401 || r.status === 403) return 'auth';
  if (r.status === 409 || r.status === 413 || r.status === 422) return 'content';
  if (r.status === 400 || r.status === 408 || r.status === 429 || r.status >= 500) return 'server';   // 400 是请求体没读完整（UNREADABLE_REQUEST）
  return 'config';                                              // 3xx、404、405、415……端点或客户端不对，隔离数据没有用
}
// 被拒收的是哪几条：→ { reject: [{it, where}] } | { split: true } | { envelope: true }
function contentVerdict(r, items) {
  const msg = String(r.json?.message ?? '');
  if (r.code === 'REQUEST_TOO_LARGE') return { split: true };
  if (r.code === 'INVALID_EVENT') {
    const locs = msg.replace(/^[\s\S]*?failed at\s*/, '').split(',').map((x) => x.trim()).filter(Boolean);
    const bad = new Map();
    for (const l of locs) {
      const m = l.match(/^\/events\/(\d+)(\/.*)?$/);
      if (!m || Number(m[1]) >= items.length) return { envelope: true };   // 批次外壳（client、batch_id）出错：不是哪一条的问题
      bad.set(Number(m[1]), [...(bad.get(Number(m[1])) ?? []), m[2] ?? '']);
    }
    if (bad.size === 0) return { envelope: true };
    return { reject: [...bad].map(([k, ws]) => ({ it: items[k], where: [...new Set(ws.filter(Boolean))].join(',') })) };
  }
  const ids = new Set([...msg.matchAll(UUID_G)].map((m) => m[0].toLowerCase()));   // EVENT_CONFLICT / EVENT_TOO_LARGE 带 event_id
  const hit = items.filter((it) => ids.has(it.id));
  return hit.length > 0 ? { reject: hit.map((it) => ({ it, where: '' })) } : { split: true };
}

async function deliver(run, st, items) {
  const out = { acked: [], rejected: [], stop: null, unsent: [] };
  const stack = [items];
  while (stack.length > 0) {
    const cur = stack.pop();
    if (cur.length === 0) continue;
    // 同一组事件重发时 batch_id 不变，服务端排查方便（TODO push 的 09-16 修正）
    const batchId = eventId('batch', `${cur[0].id}|${cur[cur.length - 1].id}|${cur.length}`);
    const r = await post(run.url, run.token, envelope(batchId, run.client) + cur.map((it) => it.text).join(',') + ']}');
    run.requests++;
    touchLock();                                                // 二分重发可能一批里发很多次，每个请求都刷新，别被当成陈旧锁
    if (r.status === 200) {
      const a = r.json?.accepted_count, d = r.json?.duplicate_count;
      for (const [k, v] of [['accepted', a], ['duplicate', d], ['sdk_failed', r.json?.sdk_failed_count]]) {
        run.sum[k] += num(v); st.totals[k] = num(st.totals[k]) + num(v);
      }
      if (num(a, -1) + num(d, -1) !== cur.length) { run.sum.count_mismatch++; st.totals.count_mismatch = num(st.totals.count_mismatch) + 1; }
      out.acked.push(...cur);
      if (DIE_AFTER_ACK && ++run.acks >= DIE_AFTER_ACK) process.exit(0);
      continue;
    }
    const kind = classify(r);
    if (kind === 'content') {
      const v = contentVerdict(r, cur);
      if (v.reject) {
        const bad = new Set(v.reject.map((x) => x.it));
        out.rejected.push(...v.reject.map((x) => ({ ...x, status: r.status, code: r.code || `HTTP_${r.status}` })));
        stack.push(cur.filter((it) => !bad.has(it)));
        continue;
      }
      if (v.split) {
        if (cur.length === 1) { out.rejected.push({ it: cur[0], where: '', status: r.status, code: r.code || `HTTP_${r.status}` }); continue; }
        const mid = Math.ceil(cur.length / 2);
        stack.push(cur.slice(mid), cur.slice(0, mid));
        continue;
      }
      out.stop = { kind: 'client', status: r.status, code: r.code };
    } else out.stop = { kind, status: r.status, code: r.code };
    out.unsent = [cur, ...stack.reverse()].flat();
    return out;
  }
  return out;
}

// 记账：先隔离、再推进游标落盘、最后删发完的块（删之前被杀，下次看到游标到头照删）
function commit(run, st, batch, res, q) {
  const rej = [...batch.local.map((it) => ({ it, where: '', status: 0, code: it.code })), ...res.rejected];
  if (rej.length > 0) {
    const byFile = new Map();
    for (const x of rej) { const f = path.join(rejectedDir(), x.it.block.rel); byFile.set(f, (byFile.get(f) ?? '') + x.it.text + '\n'); }
    for (const [f, txt] of byFile) { mkdirp(path.dirname(f)); fs.appendFileSync(f, txt); }
    mkdirp(pushDir());
    fs.appendFileSync(rejectLog(), rej.map((x) => JSON.stringify({ at: isoNow(), block: x.it.block.rel, line: x.it.idx + 1, event_id: x.it.id ?? null,
      type: x.it.type ?? null, status: x.status, code: x.code, ...(x.where ? { where: x.where } : {}) })).join('\n') + '\n');
    run.sum.rejected += rej.length;
    st.totals.rejected = num(st.totals.rejected) + rej.length;
  }
  const open = new Set(res.unsent);
  const span = new Map();                                       // 块 → [本批拿到哪一行为止, 第一条没了结的行]
  for (const it of [...batch.items, ...batch.settled, ...batch.local]) {
    const [end, first] = span.get(it.block) ?? [0, Infinity];
    span.set(it.block, [Math.max(end, it.idx + 1), open.has(it) ? Math.min(first, it.idx) : first]);
  }
  const done = q.stale.splice(0);
  for (const [b, [end, first]] of span) {
    st.cursors[b.rel] = Math.min(end, first);
    if (st.cursors[b.rel] >= b.total) done.push(b);
  }
  for (const b of done) st.cursors[b.rel] = b.total;
  if (res.acked.length > 0) { run.sum.events += res.acked.length; st.totals.events = num(st.totals.events) + res.acked.length; }
  savePushState(st);
  for (const b of done) {
    try { fs.unlinkSync(b.abs); } catch {}
    delete st.cursors[b.rel];
  }
}

function backoff(st, stop) {
  st.failures += 1;
  // 同一种错误连着出现几次：IDENTITY_UNAVAILABLE 连着 IDENTITY_STREAK 次就点名换 token（identityHint）；换一种错、推成功都从头数
  const same = st.failures > 1 && st.last_error?.status === stop.status && st.last_error?.code === stop.code;
  st.same_error = same ? num(st.same_error, 1) + 1 : 1;
  const s = Math.min(BACKOFF_BASE_S * 2 ** Math.min(st.failures - 1, 12), BACKOFF_CAP_S) * (0.8 + Math.random() * 0.4);
  st.next_at = Date.now() + Math.round(Math.min(s, BACKOFF_CAP_S) * 1000);
  st.last_error = { at: isoNow(), kind: stop.kind, status: stop.status, code: stop.code };
}

function logRun(rec) {                                          // logs/push.log：每次真发过请求或失败的 push 一行，只有计数与状态码
  try {
    const dir = path.join(VT_HOME, 'logs'), f = path.join(dir, 'push.log');
    mkdirp(dir);
    try { if (fs.statSync(f).size > 1024 * 1024) fs.renameSync(f, f + '.1'); } catch {}
    fs.appendFileSync(f, JSON.stringify(rec) + '\n');
  } catch {}
}

// 一次 push：扫全机 spool、混批、循环发。maxBatches / budgetMs 管这一次发多少（DESIGN §4、OPEN-ISSUES U17）
// onLocked：拿到锁之后、列块之前调（autoPush 的等锁人在这里放开等锁标记，保证之后写的块都在它列的范围里）
export async function pushRun({ trigger = 'manual', maxBatches = Infinity, budgetMs = Infinity, ignoreBackoff = false, onBatch = null, onLocked = null } = {}) {
  const ep = pushEndpoint();
  if (!ep.url) return { result: ep.error ? 'bad_endpoint' : 'no_endpoint', error: ep.error };
  if (!ignoreBackoff && loadPushState().next_at > Date.now()) return { result: 'backoff' };
  if (!pushLock()) return { result: 'locked' };
  if (onLocked) onLocked();
  const t0 = Date.now();
  const run = { url: ep.url, token: vtToken(), client: clientOf(), requests: 0, acks: 0,
    sum: { batches: 0, events: 0, accepted: 0, duplicate: 0, rejected: 0, sdk_failed: 0, count_mismatch: 0 } };
  let stop = null;
  try {
    const st = loadPushState();
    if (!run.client) stop = { kind: 'client', status: 0, code: 'BAD_DEVICE_ID' };
    else {
      const blocks = listBlocks();
      const live = new Set(blocks.map((b) => b.rel));
      for (const k of Object.keys(st.cursors)) if (!live.has(k)) delete st.cursors[k];
      const q = new Queue(blocks, st.cursors);
      const envBytes = envelopeBytes(run.client);
      while (run.sum.batches < maxBatches && Date.now() - t0 < budgetMs) {
        const batch = takeBatch(q, envBytes, run.token);
        if (batch.items.length + batch.settled.length + batch.local.length === 0) break;
        const res = batch.items.length > 0 ? await deliver(run, st, batch.items) : { acked: [], rejected: [], stop: null, unsent: [] };
        if (batch.items.length > 0) run.sum.batches++;
        commit(run, st, batch, res, q);
        touchLock();
        if (onBatch) onBatch(run.sum);
        if (res.stop) { stop = res.stop; break; }
      }
      if (!stop && q.stale.length > 0) commit(run, st, { items: [], settled: [], local: [] }, { acked: [], rejected: [], unsent: [] }, q);
    }
    if (stop) backoff(st, stop);
    else if (run.requests > 0) { st.failures = 0; st.same_error = 0; st.next_at = 0; st.last_ok_at = isoNow(); }
    if (stop || run.requests > 0) {
      savePushState(st);
      logRun({ at: isoNow(), trigger, ms: Date.now() - t0, requests: run.requests, ...run.sum, ...(stop ? { stop } : {}) });
    }
  } catch {
    vtLogError('push', '', `push:${trigger}`, 1);
    return { result: 'error', sum: run.sum };
  } finally { pushUnlock(); }
  return { result: stop ? 'stopped' : 'ok', stop, sum: run.sum, ms: Date.now() - t0 };
}

// hook 跑完之后调（D15：SessionStart / Stop / SessionEnd，trigger 是触发它的 hook 名，只进 push.log）。端点没配、在退避期、spool 里没有块就什么都不做。
// 锁被占着：已经有人在等就直接走——那人拿到锁之后才列块，我们刚写的块一定在里面；没人等就自己等到锁放开再推，
// 不然最后一轮的 Stop 撞上别的会话正在推，这一轮又留在本机（锁里那个推送开始时就列好了块，看不到后写的）
export async function autoPush(trigger = 'hook') {
  try {
    if (!pushEndpoint().url) return;
    if (loadPushState().next_at > Date.now()) return;
    if (listBlocks().length === 0) return;
    const first = await pushRun({ trigger, budgetMs: BUDGET_MS });
    if (first.result !== 'locked' || !waiterLock()) return;
    let released = false;
    const release = () => { if (!released) { released = true; waiterUnlock(); } };
    try {
      for (const until = Date.now() + LOCK_WAIT_MS; Date.now() < until;) {
        await sleep(200);
        touchWaiter();
        const r = await pushRun({ trigger: `${trigger}(等锁)`, budgetMs: BUDGET_MS, onLocked: release });
        if (r.result !== 'locked') return;
      }
    } finally { release(); }
  } catch { vtLogError('push', '', `push:${trigger}`, 1); }
}

// ---------- 看账：vibetrail push --list、doctor ----------
export function pendingBySession() {
  const cursors = loadPushState().cursors;
  const sessions = new Map();
  let events = 0, blocks = 0, oldest = null;
  for (const b of listBlocks()) {
    const n = Math.max(countLines(b.abs) - num(cursors[b.rel]), 0);
    if (n === 0) continue;
    const k = `${b.pkey}/${b.sid}`;
    const s = sessions.get(k) ?? { pkey: b.pkey, sid: b.sid, blocks: 0, events: 0, bytes: 0, oldest: b.at };
    let size = 0; try { size = fs.statSync(b.abs).size; } catch {}
    s.blocks++; s.events += n; s.bytes += size; s.oldest = Math.min(s.oldest, b.at);
    sessions.set(k, s);
    blocks++; events += n; oldest = oldest === null ? b.at : Math.min(oldest, b.at);
  }
  return { sessions: [...sessions.values()], blocks, events, oldest };
}
export function rejectedSummary() {
  let events = 0;
  const walk = (d) => { for (const n of readdir(d)) { const p = path.join(d, n); if (n.endsWith('.jsonl')) events += countLines(p); else walk(p); } };
  walk(rejectedDir());
  const codes = {};
  try {
    for (const l of fs.readFileSync(rejectLog(), 'utf8').split('\n')) {
      if (!l) continue;
      try { const r = JSON.parse(l); const k = r.status ? `${r.status} ${r.code}` : r.code; codes[k] = (codes[k] ?? 0) + 1; } catch {}
    }
  } catch {}
  return { events, codes };
}
const KIND_TEXT = {
  auth: 'token 无效、过期或没有权限（重填：vibetrail token）', network: '连不上端点', server: '服务端暂时不可用',
  config: '端点或客户端配置不对（地址、路径？）', client: '批次外壳不对（client / device_id，重跑 vibetrail init）',
};
// 后端把「账户服务挂了」与「账户服务不认这个 token」都回成 503 IDENTITY_UNAVAILABLE（AccountUserIdentityResolver：401 / 403 以外的非 2xx 与异常都算不可用），
// 客户端从响应里分不出来，照接入指南按暂时失败退避，但提示里要把 token 这种可能说出来——09-17 本机原先的 token 就是这样，换成测试环境的才推通（用户会请后端改成 401）
const CODE_TEXT = {
  IDENTITY_UNAVAILABLE: '服务端校验 token 没成：可能是账户服务出了问题，也可能是 token 不属于这个环境——一直这样就换 token（vibetrail token）',
};
const IDENTITY_STREAK = 3;
export const describeStop = (e) => `${e.status ? `HTTP ${e.status} ` : ''}${e.code ? `${e.code} ` : ''}${CODE_TEXT[e.code] ?? KIND_TEXT[e.kind] ?? e.kind}`;
export const identityHint = (st) => (st.failures > 0 && st.last_error?.code === 'IDENTITY_UNAVAILABLE' && num(st.same_error) >= IDENTITY_STREAK
  ? `连着 ${num(st.same_error)} 次都是服务端校验 token 没成：先换 token（vibetrail token），再手动推一次（vibetrail push）；换了还这样，就是账户服务或 Collector 的配置问题，找后端` : '');
const fmtAt = (ms) => `${new Date(ms).toISOString().slice(5, 16).replace('T', ' ')}Z`;
const fmtAgo = (ms) => { const s = Math.max(Math.round((Date.now() - ms) / 1000), 0); return s < 90 ? `${s} 秒` : s < 5400 ? `${Math.round(s / 60)} 分钟` : s < 172800 ? `${Math.round(s / 3600)} 小时` : `${Math.round(s / 86400)} 天`; };
const fmtBytes = (n) => (n >= 1048576 ? `${(n / 1048576).toFixed(1)} MB` : n >= 1024 ? `${(n / 1024).toFixed(1)} KB` : `${n} B`);
const codesText = (codes) => Object.entries(codes).sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k} ${v}`).join('、');

export function pushDoctor({ ok, note }) {
  const ep = pushEndpoint();
  if (ep.error) note(`端点写错了：${ep.error}（${VT_HOME}/config 的 endpoint=）——push 不发`);
  else if (!ep.url) say(`  · 端点没配置：只落本机 spool、不发（在 ${VT_HOME}/config 里写 endpoint=http://…）`);
  else ok(`端点：${ep.url}`);
  const st = loadPushState();
  if (st.failures > 0 && st.last_error) {
    note(`push 连续失败 ${st.failures} 次，最近一次 ${st.last_error.at}：${describeStop(st.last_error)}；`
      + `${st.next_at > Date.now() ? `${fmtAt(st.next_at)} 之前自动触发都不推` : '下一次 hook 再试'}，手动重试：vibetrail push`);
    if (identityHint(st)) note(identityHint(st));
  } else if (st.last_ok_at) {
    const t = st.totals;
    ok(`上次推送成功 ${st.last_ok_at}；累计发出 ${num(t.events)} 条：新收 ${num(t.accepted)}、重复 ${num(t.duplicate)}、隔离 ${num(t.rejected)}`
      + `${num(t.sdk_failed) > 0 ? `、正文投递失败 ${num(t.sdk_failed)}（服务端尽力投递，重发补不回）` : ''}`);
    if (num(t.count_mismatch) > 0) note(`有 ${num(t.count_mismatch)} 批服务端回的 accepted + duplicate 与发出的条数对不上`);
  }
  if (ep.url) {
    const p = pendingBySession();
    if (p.events > 0 && Date.now() - p.oldest > STALE_PENDING_MS) note(`待发 ${p.events} 条，最早的已等 ${fmtAgo(p.oldest)}——之后一直失败，或者再没有答完过一轮、开关过会话（这几处才推）；立即推：vibetrail push`);
    else if (p.events > 0) say(`  · 待发 ${p.events} 条，最早的 ${fmtAgo(p.oldest)} 前（vibetrail push --list）`);
  }
  const r = rejectedSummary();
  if (r.events > 0) note(`隔离着 ${r.events} 条被拒收 / 本地不合格的事件（${codesText(r.codes) || '原因记录已清'}），在 ${rejectedDir()}；修好之后 vibetrail push --requeue 放回待发`);
}

function pushList() {
  const ep = pushEndpoint(), tok = vtToken(), st = loadPushState();
  say(`端点：${ep.url || (ep.error ? `写错了（${ep.error}），不发` : `没配置，不发（${VT_HOME}/config 里写 endpoint=）`)}`);
  say(`token：${tok ? `已填（${maskToken(tok)}）` : '没填（服务端开着联调默认用户时记到默认用户）'}`);
  const p = pendingBySession();
  if (p.events === 0) say('待发：没有');
  else {
    say('待发：');
    const pad = (s, n) => { const t = String(s); return t.length >= n ? t.slice(0, n) : t + ' '.repeat(n - t.length); };
    say(`  ${pad('项目', 28)} ${pad('会话', 10)} ${'块'.padStart(5)} ${'条数'.padStart(8)} ${'块文件'.padStart(9)}  最早`);
    for (const s of p.sessions.sort((a, b) => a.oldest - b.oldest)) {
      say(`  ${pad(s.pkey.replace(/-[0-9a-f]{16}$/, ''), 28)} ${pad(s.sid.slice(0, 8), 10)} ${String(s.blocks).padStart(5)} ${String(s.events).padStart(8)} ${fmtBytes(s.bytes).padStart(9)}  ${fmtAt(s.oldest)}`);
    }
    say(`  共 ${p.sessions.length} 个会话、${p.blocks} 块、${p.events} 条`);
    say(`最早的 ${fmtAgo(p.oldest)} 前写的 → ${!ep.url ? '端点没配，不推' : st.next_at > Date.now() ? `退避中，${fmtAt(st.next_at)} 之前 hook 都不推` : '下一次答完一轮、开会话或关会话就推（D15）'}`);
  }
  if (st.failures > 0 && st.last_error) say(`退避：连续失败 ${st.failures} 次（${describeStop(st.last_error)}），${st.next_at > Date.now() ? `${fmtAt(st.next_at)} 之前自动触发都不推` : '已过退避期'}`);
  if (identityHint(st)) say(`  ${identityHint(st)}`);
  if (st.last_ok_at) say(`上次成功：${st.last_ok_at}；累计发出 ${num(st.totals.events)} 条：新收 ${num(st.totals.accepted)}、重复 ${num(st.totals.duplicate)}、隔离 ${num(st.totals.rejected)}`);
  const r = rejectedSummary();
  if (r.events > 0) say(`隔离：${r.events} 条（${codesText(r.codes) || '原因记录已清'}），在 ${rejectedDir()}，原因 ${rejectLog()}；放回待发：vibetrail push --requeue`);
  say('立即推：vibetrail push；下一批的内容：vibetrail push --show [--json]');
  return 0;
}

function pushShow(json) {
  const client = clientOf();
  if (!client) { process.stderr.write('✗ config 里的 device_id 不是 UUID，重跑 vibetrail init\n'); return 1; }
  const q = new Queue(listBlocks(), loadPushState().cursors);
  const b = takeBatch(q, envelopeBytes(client), vtToken());
  if (b.items.length === 0) {
    say(b.local.length > 0 ? `没有能发的事件；有 ${b.local.length} 条本地就不合格，下次 push 会隔离` : '没有待发的事件');
    return 0;
  }
  const batchId = eventId('batch', `${b.items[0].id}|${b.items[b.items.length - 1].id}|${b.items.length}`);
  const body = envelope(batchId, client) + b.items.map((it) => it.text).join(',') + ']}';
  if (json) { process.stdout.write(body + '\n'); return 0; }
  const count = (f) => Object.entries(b.items.reduce((m, it) => { const k = f(it); m[k] = (m[k] ?? 0) + 1; return m; }, {})).sort((x, y) => y[1] - x[1]).map(([k, v]) => `${k} ${v}`).join('、');
  say(`下一批：${b.items.length} 条、请求体 ${fmtBytes(Buffer.byteLength(body))}，batch_id ${batchId}`);
  say(`  类型：${count((it) => it.type)}`);
  say(`  会话：${count((it) => `${it.block.pkey.replace(/-[0-9a-f]{16}$/, '')}/${it.block.sid.slice(0, 8)}`)}`);
  if (b.settled.length > 0) say(`  另有 ${b.settled.length} 行不发：空行或本批里重复的 event_id（只发第一条）`);
  if (b.local.length > 0) say(`  另有 ${b.local.length} 条本地就不合格（${[...new Set(b.local.map((x) => x.code))].join('、')}），push 时隔离`);
  say('（完整请求体：vibetrail push --show --json；请求头只有 Content-Type 与 Onepaas-Api-Access-Token）');
  return 0;
}

export function requeueRejected() {
  if (!pushLock()) return { result: 'locked' };
  try {
    let files = 0, events = 0;
    const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
    const root = rejectedDir();
    for (const pkey of readdir(root)) {
      for (const sid of readdir(path.join(root, pkey))) {
        for (const name of readdir(path.join(root, pkey, sid))) {
          if (!name.endsWith('.jsonl')) continue;
          const src = path.join(root, pkey, sid, name), dest = path.join(VT_HOME, 'spool', pkey, sid);
          if (!mkdirp(dest)) continue;
          events += countLines(src);
          fs.renameSync(src, path.join(dest, `${stamp}-${process.pid}-requeue-${name}`));   // 当作新块排到队尾
          files++;
        }
        try { fs.rmdirSync(path.join(root, pkey, sid)); } catch {}
      }
      try { fs.rmdirSync(path.join(root, pkey)); } catch {}
    }
    try { fs.rmdirSync(root); } catch {}
    try { fs.appendFileSync(path.join(pushDir(), 'rejected.history.jsonl'), fs.readFileSync(rejectLog())); fs.unlinkSync(rejectLog()); } catch {}
    return { result: 'ok', files, events };
  } finally { pushUnlock(); }
}

export async function cmdPush(argv) {
  let mode = 'run', json = false;
  for (const a of argv) {
    if (a === '--list') mode = 'list';
    else if (a === '--show') mode = 'show';
    else if (a === '--json') json = true;
    else if (a === '--requeue') mode = 'requeue';
    else { process.stderr.write(`✗ push 不认识的参数：${a}（vibetrail push [--list | --show [--json] | --requeue]）\n`); return 1; }
  }
  if (mode === 'list') return pushList();
  if (mode === 'show') return pushShow(json);
  if (mode === 'requeue') {
    const r = requeueRejected();
    if (r.result === 'locked') { say('· 有 push 正在跑，等它跑完再放回'); return 1; }
    say(r.events > 0 ? `✓ 放回待发 ${r.events} 条（${r.files} 个文件），下次 push 重发` : '没有隔离着的事件');
    return 0;
  }
  const ep = pushEndpoint();
  if (!ep.url) { process.stderr.write(`✗ ${ep.error ? `端点写错了：${ep.error}` : `端点没配置：在 ${VT_HOME}/config 里写 endpoint=http://…`}\n`); return 1; }
  const tok = vtToken();
  say(`推到 ${ep.url}（${tok ? `带 token，${maskToken(tok)}` : '不带 token：服务端开着联调默认用户时记到默认用户'}）`);
  let shown = Date.now();
  const r = await pushRun({ trigger: 'manual', ignoreBackoff: true,
    onBatch: (s) => { if (Date.now() - shown >= 2000) { shown = Date.now(); say(`  … 已发 ${s.batches} 批：新收 ${s.accepted}、重复 ${s.duplicate}、隔离 ${s.rejected}`); } } });
  if (r.result === 'locked') { say('· 已有一个 push 在跑（hook 触发的或另一个终端），这次不发'); return 0; }
  if (r.result === 'error') { say('✗ push 出错，只记了 errors.log（元数据）'); return 1; }
  const s = r.sum;
  const line = `${s.batches} 批、${s.events + s.rejected} 条：新收 ${s.accepted}、重复 ${s.duplicate}、隔离 ${s.rejected}${s.sdk_failed > 0 ? `、正文投递失败 ${s.sdk_failed}` : ''}，用时 ${(r.ms / 1000).toFixed(1)} s`;
  const left = pendingBySession().events;
  if (r.result === 'stopped') {
    say(`✗ 停下了：${describeStop(r.stop)}。已发 ${line}；还剩 ${left} 条，已经发出去的不会重发`);
    say('  自动推送按退避再试（1 分钟起、翻倍到 1 小时）；修好后可以直接再跑 vibetrail push');
    const hint = identityHint(loadPushState());
    if (hint) say(`  ${hint}`);
    return 1;
  }
  say(s.batches === 0 && s.rejected === 0 ? '没有待发的事件' : `✓ 发完 ${line}${left > 0 ? `；又来了 ${left} 条待发` : ''}`);
  if (s.rejected > 0) say(`  隔离的在 ${rejectedDir()}，原因：vibetrail push --list`);
  return 0;
}
