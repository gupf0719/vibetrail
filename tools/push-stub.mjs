#!/usr/bin/env node
// push 回归用的桩 collector（tools/test-push.sh；也能手动联调：node tools/push-stub.mjs <目录>）。
// 返回照 paas-coding-collector 的 BatchValidator / IndexStore / CollectionErrorHandler 抄形状：{code, message}，
// 422 INVALID_EVENT 列出错位置（JSON Pointer，去重排序最多 10 处）、409 / 413 带 event_id、INVALID_TIME 不带位置、同一 event_id 以第一次为准。
// 只查 push 要应对的那几类错，完整 schema 由测试事后拿 schema-check.py 校验收到的事件。
//
// 目录里的文件：
//   port             启动后写入监听端口
//   requests.jsonl   每个请求一行：状态码、条数、字节、batch_id、event_id 列表、带没带 token（不记 token 本身）
//   events.jsonl     新收的事件（每个 event_id 第一次收到时写一行）
//   plan             可选，每行一个动作，每个请求消耗一行：ok | 503 | 401 | 404 | 400 | hang | reset | envelope | slow
//   token            可选，有它就要求请求头 Onepaas-Api-Access-Token 与之相同，否则 401
//   event_limit      可选，单条事件的字节上限（默认 1 MiB），超了 413 EVENT_TOO_LARGE
//   accept_all       可选，有它就跳过内容检查（用来测 --requeue 之后重发）
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const dir = process.argv[2];
if (!dir) { process.stderr.write('用法：node push-stub.mjs <目录>\n'); process.exit(2); }
fs.mkdirSync(dir, { recursive: true });
const f = (n) => path.join(dir, n);
const read = (n) => { try { return fs.readFileSync(f(n), 'utf8'); } catch { return null; } };
const UUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const owners = new Map();                                         // event_id → 第一次收到的内容（规范化后）
let n = 0;

const canon = (v) => (Array.isArray(v) ? v.map(canon) : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, canon(v[k])])) : v);
const nextPlan = () => {
  const txt = read('plan');
  if (!txt) return 'ok';
  const lines = txt.split('\n').filter(Boolean);
  fs.writeFileSync(f('plan'), lines.slice(1).map((l) => l + '\n').join(''));
  return lines[0] ?? 'ok';
};

function handle(body, headers) {
  const want = read('token');
  if (want !== null && headers['onepaas-api-access-token'] !== want.trim()) return [401, { code: 'INVALID_IDENTITY', message: 'Identity resolver did not return a valid user' }];
  if (!String(headers['content-type'] ?? '').startsWith('application/json')) return [415, { code: 'UNSUPPORTED_MEDIA_TYPE', message: 'Content-Type must be application/json' }];
  if (body.length > 16 * 1024 * 1024) return [413, { code: 'REQUEST_TOO_LARGE', message: 'Request exceeds 16 MiB' }];
  let batch;
  try { batch = JSON.parse(body.toString('utf8')); } catch { return [400, { code: 'INVALID_JSON', message: 'Malformed JSON request' }]; }
  const paths = [];
  const c = batch?.client;
  if (batch?.schema_version !== '1.0') paths.push('/schema_version');
  if (!UUID.test(String(batch?.batch_id))) paths.push('/batch_id');
  if (c?.name !== 'paas-coding-hook' || typeof c?.version !== 'string' || !UUID.test(String(c?.device_id)) || typeof c?.policy_version !== 'string') paths.push('/client');
  const events = Array.isArray(batch?.events) ? batch.events : null;
  if (!events || events.length < 1 || events.length > 100) paths.push('/events');
  const lax = read('accept_all') !== null;
  if (events && !lax) {
    events.forEach((e, i) => {
      if (!UUID.test(String(e?.event_id))) paths.push(`/events/${i}`, `/events/${i}/event_id`);
      if (typeof e?.type !== 'string' || !/^[a-z]+(\.[a-z_]+)+$/.test(e.type)) paths.push(`/events/${i}`, `/events/${i}/type`);
      if (typeof e?.occurred_at !== 'string' || !/Z$/.test(e.occurred_at)) paths.push(`/events/${i}`, `/events/${i}/occurred_at`);
    });
  }
  if (paths.length > 0) return [422, { code: 'INVALID_EVENT', message: 'Schema validation failed at ' + [...new Set(paths)].sort().slice(0, 10).join(', ') }];
  const limit = Number(read('event_limit')) || 1024 * 1024;
  const inBatch = new Map();
  for (const e of events) {
    const id = e.event_id.toLowerCase();
    if (!lax && /^0\d{3}-/.test(e.occurred_at)) return [422, { code: 'INVALID_TIME', message: 'occurred_at must fit MySQL DATETIME in Asia/Shanghai (years 1000 through 9999)' }];
    const content = JSON.stringify(canon(e));
    if (Buffer.byteLength(content) > limit) return [413, { code: 'EVENT_TOO_LARGE', message: 'Event exceeds 1 MiB: ' + id }];
    if (inBatch.has(id) && inBatch.get(id) !== content) return [409, { code: 'EVENT_CONFLICT', message: 'Different content for event ' + id }];
    inBatch.set(id, content);
  }
  for (const e of events) {
    if (!lax && e.extensions?.['test.owner'] === 'other') return [409, { code: 'EVENT_CONFLICT', message: 'Event ID already belongs to a different user: ' + e.event_id.toLowerCase() }];
  }
  let accepted = 0;
  for (const [id, content] of inBatch) {
    if (owners.has(id)) continue;
    owners.set(id, content); accepted++;
    fs.appendFileSync(f('events.jsonl'), JSON.stringify(events.find((e) => e.event_id.toLowerCase() === id)) + '\n');
  }
  return [200, { batch_id: batch.batch_id, accepted_count: accepted, duplicate_count: events.length - accepted, sdk_attempted_count: accepted, sdk_failed_count: 0, content_delivery: 'best_effort' }];
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    const plan = nextPlan();
    let ids = [], count = 0, batchId = null;
    try { const b = JSON.parse(body.toString('utf8')); ids = (b.events ?? []).map((e) => e.event_id); count = ids.length; batchId = b.batch_id; } catch {}
    const rec = (status) => fs.appendFileSync(f('requests.jsonl'), JSON.stringify({ n: ++n, plan, status, url: req.url, bytes: body.length, count, batch_id: batchId, ids,
      has_token: typeof req.headers['onepaas-api-access-token'] === 'string' }) + '\n');
    const reply = (status, obj) => { rec(status); res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(obj)); };
    if (req.method !== 'POST' || req.url !== '/api/v1/collection/batches') return reply(404, { code: 'NOT_FOUND', message: 'No route' });
    if (plan === 'hang') { rec(0); setTimeout(() => { try { res.destroy(); } catch {} }, 10000); return; }
    if (plan === 'reset') { rec(0); req.socket.destroy(); return; }
    if (/^\d{3}$/.test(plan)) return reply(Number(plan), { code: plan === '503' ? 'INDEX_UNAVAILABLE' : plan === '401' ? 'INVALID_IDENTITY' : 'PLAN', message: 'planned ' + plan });
    if (plan === 'envelope') return reply(422, { code: 'INVALID_EVENT', message: 'Schema validation failed at /client/version' });
    const [status, obj] = handle(body, req.headers);
    if (plan === 'slow') { setTimeout(() => reply(status, obj), 300); return; }
    reply(status, obj);
  });
});
server.listen(0, '127.0.0.1', () => { fs.writeFileSync(f('port'), String(server.address().port)); });
