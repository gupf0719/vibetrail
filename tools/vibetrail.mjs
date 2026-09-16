#!/usr/bin/env node
// vibetrail 运行时入口（DESIGN D12）：按 argv 分发。移植期间先只有 map 一个子命令，
// hook / cli / push 随 ②③⑤ 依次搬进来。
//
//   node vibetrail.mjs map --sid … --project-id … [--from-line N] … < <transcript 的字节切片>
//
// stdin 是 vibetrail-map 按 offset 切好的那一段（整行，末尾半行由调用方裁掉），每行一条记录。
// stdout：每行一个协议事件（event_id 为 null、多一个 _key，由 vt_fill_ids 填），最后一行 {"_ledger": …}。
// 与 jq 版逐字节对齐：字段、顺序、账本都不变（golden 比对前按键排序，所以键序无关）。
import { readFileSync, writeFileSync, appendFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { mapRecords } from './lib/map.mjs';
import { runHook, detach, SYNC_EVENTS, mapFile, vtConf } from './lib/hook.mjs';
import { cli } from './lib/cli.mjs';

const argv = process.argv.slice(2);
const cmd = argv.shift();

function die(msg) { process.stderr.write(`✗ vibetrail.mjs: ${msg}\n`); process.exit(1); }

function parseArgs(rest) {
  const a = {
    sid: '', project_id: '', workspace_id: '', parent_instance: 'main',
    start_line: 1, from_line: 0, meta: null, seen_uuids: [], hook_turns: {}, hook_perms: [],
    perm_since: '', close_last: '', stop_turn: '', turns: true, vt_version: '', rule_version: 'diverge-v1',
    capture_content: '1',
  };
  const jsonFile = (p, dflt) => { try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return dflt; } };
  for (let i = 0; i < rest.length; i++) {
    const k = rest[i], v = rest[i + 1];
    switch (k) {
      case '--sid': a.sid = v; i++; break;
      case '--project-id': a.project_id = v; i++; break;
      case '--workspace-id': a.workspace_id = v; i++; break;
      case '--parent-instance': a.parent_instance = v; i++; break;
      case '--start-line': a.start_line = Number(v); i++; break;
      case '--from-line': a.from_line = Number(v); i++; break;
      // --meta 收的是 JSON 串（vibetrail-map 那边是 --argjson），也容许给文件路径
      case '--meta': {
        if (v === '' || v === 'null') a.meta = null;
        else { try { a.meta = JSON.parse(v); } catch { a.meta = jsonFile(v, null); } }
        i++; break;
      }
      case '--seen-uuids': a.seen_uuids = v === '' ? [] : jsonFile(v, []); i++; break;
      case '--hook-turns': a.hook_turns = v === '' ? {} : jsonFile(v, {}); i++; break;
      case '--hook-perms': a.hook_perms = v === '' ? [] : jsonFile(v, []); i++; break;
      case '--perm-since': a.perm_since = v; i++; break;
      case '--close-last': a.close_last = v; i++; break;
      case '--stop-turn': a.stop_turn = v; i++; break;
      case '--rule-version': a.rule_version = v; i++; break;
      case '--vt-version': a.vt_version = v; i++; break;
      case '--capture-content': a.capture_content = v; i++; break;
      case '--no-turns': a.turns = false; break;
      default: die(`未知参数 ${k}`);
    }
  }
  return a;
}

if (cmd === 'map') {
  const args = parseArgs(argv);
  const raw = readFileSync(0, 'utf8');
  const records = [];
  let ln = 0;
  for (const line of raw.split('\n')) {
    ln++;
    if (line.trim() === '') continue;
    try { records.push(JSON.parse(line)); }
    catch (e) { die(`第 ${ln} 行不是 JSON：${String(e.message).slice(0, 120)}`); }
  }
  const { events, ledger } = mapRecords(records, args);
  let buf = '';
  for (const e of events) buf += JSON.stringify(e) + '\n';
  buf += JSON.stringify({ _ledger: ledger }) + '\n';
  process.stdout.write(buf);
} else if (cmd === 'map-file') {
  // 与老的 bash vibetrail-map 参数一一对应（它现在是转到这里的 sh 包装）：
  // 自己按 offset 切文件、算 event_id、写账本与 sources；stdout 每行一个事件
  let f = '', ledger = '', sourcesOut = '', startByte = null;
  const o = { turns: true, capture_content: '' };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i], v = argv[i + 1];
    switch (k) {
      case '--sid': o.sid = v; i++; break;
      case '--project-id': o.project_id = v; i++; break;
      case '--workspace-id': o.workspace_id = v; i++; break;
      case '--parent-instance': o.parent_instance = v; i++; break;
      case '--start-line': o.start_line = Number(v); i++; break;
      case '--start-byte': startByte = v === '' ? null : Number(v); i++; break;
      case '--from-line': o.from_line = Number(v); i++; break;
      case '--meta': o.meta = v ? JSON.parse(readFileSync(v, 'utf8')) : null; i++; break;
      case '--seen-uuids': o.seenFile = v; i++; break;
      case '--hook-turns': o.hook_turns = v ? JSON.parse(readFileSync(v, 'utf8')) : {}; i++; break;
      case '--hook-perms': o.hook_perms = v ? JSON.parse(readFileSync(v, 'utf8')) : []; i++; break;
      case '--perm-since': o.perm_since = v; i++; break;
      case '--close-last': o.close_last = v; i++; break;
      case '--stop-turn': o.stop_turn = v; i++; break;
      case '--vt-version': o.vt_version = v; i++; break;
      case '--capture-content': o.capture_content = v; i++; break;
      case '--ledger': ledger = v; i++; break;
      case '--sources-out': sourcesOut = v; i++; break;
      case '--no-turns': o.turns = false; break;
      default:
        if (k.startsWith('-')) die(`未知参数 ${k}`);
        if (f) die('只接受一个 transcript');
        f = k;
    }
  }
  if (!f) die('缺 transcript 路径');
  if (startByte !== null) o.start_byte = startByte;
  if (!o.capture_content) o.capture_content = vtConf('capture_content', '1');
  let out;
  try { out = mapFile(f, o); } catch (e) { die(String(e.message)); }
  let buf = '';
  for (const e of out.events) buf += JSON.stringify(e) + '\n';
  process.stdout.write(buf);
  const lg = JSON.stringify(out.ledger) + '\n';
  if (ledger) writeFileSync(ledger, lg); else process.stderr.write(lg);
  if (sourcesOut) appendFileSync(sourcesOut, (out.ledger.sources || []).map(([u, n]) => `${u}\t${n}`).join('\n') + (out.ledger.sources?.length ? '\n' : ''));
  process.exit(0);
} else if (cmd === 'hook' || cmd === 'hook-run') {
  // hook：Claude Code 给的 payload 在 stdin。纪律（DESIGN §3.4）：stdout 永远为空、永远 exit 0。
  // 同步 hook（SessionStart / UserPromptSubmit / SessionEnd / PermissionRequest）读完 stdin 就丢后台，自己立刻退出，不让人等；
  // hook-run 是那个后台进程自己的入口，不再二次丢。
  const event = argv.shift() ?? '';
  // K16②（借 teamai hook-dispatch-cli.ts:36-65）：宿主写完 payload 却不关 stdin 时，裸读会一直等到 Claude Code 的 timeout
  // （同步 hook 是 10 s，人就干等 10 s）。改成流式读、1 秒没有新数据就当读完
  const readStdin = (idleMs = 1000) => new Promise((resolve) => {
    const chunks = []; let timer = null; let finished = false;
    const done = () => {
      if (finished) return; finished = true; clearTimeout(timer);
      try { process.stdin.pause(); process.stdin.destroy(); } catch {}
      resolve(Buffer.concat(chunks).toString('utf8'));
    };
    const arm = () => { clearTimeout(timer); timer = setTimeout(done, idleMs); };
    process.stdin.on('data', (c) => { chunks.push(c); arm(); });
    process.stdin.on('end', done);
    process.stdin.on('error', done);
    arm();
  });
  let payload = '';
  try { payload = await readStdin(); } catch { process.exit(0); }
  try {
    if (cmd === 'hook' && SYNC_EVENTS.has(event) && process.env.VIBETRAIL_FOREGROUND !== '1') {
      detach(fileURLToPath(import.meta.url), event, payload);
    } else {
      runHook(event, payload);
    }
  } catch { /* 失败只进 errors.log，永远 exit 0 */ }
  process.exit(0);
} else {
  // 其余全是 CLI 子命令（init / uninstall / projects / list / show / sync / doctor / version）
  const rc = await cli([cmd, ...argv].filter((x) => x !== undefined));
  process.exit(rc || 0);
}
