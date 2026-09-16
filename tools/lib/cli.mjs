// vibetrail：机器级安装、登记与本地查看（DESIGN §5；D12 ③ 的移植，原 tools/vibetrail 685 行 bash）。
// 换语言不换设计：settings 的合并 / 备份 / 自检 / 还原、登记表、spool 的看法、doctor 的每一项都照旧。
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import {
  VT_HOME, VT_RUNTIME_VERSION, vtConf, vtSha, vtSlug, vtRealpath, vtMainCheckout, vtProjectKey,
  vtRegistered, vtRegister, vtUnregister, vtPruneRemoved, settingsPath, claudeProjects, runHook,
} from './hook.mjs';

const say = (s = '') => process.stdout.write(s + '\n');
const die = (s) => { process.stderr.write('✗ ' + s + '\n'); process.exit(1); };
const readText = (p) => { try { return fs.readFileSync(p, 'utf8'); } catch { return null; } };
const readJson = (p, d) => { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return d; } };
const isFile = (p) => { try { return fs.statSync(p).isFile(); } catch { return false; } };
const isDir = (p) => { try { return fs.statSync(p).isDirectory(); } catch { return false; } };
const mkdirp = (p) => { try { fs.mkdirSync(p, { recursive: true }); } catch {} };
const sortedJson = (o) => JSON.stringify(o, Object.keys(flatten(o)).length ? sortKeys : undefined);
function sortKeys(k, v) { return v !== null && typeof v === 'object' && !Array.isArray(v) ? Object.fromEntries(Object.keys(v).sort().map((x) => [x, v[x]])) : v; }
function flatten(o) { return o ?? {}; }
const canon = (o) => JSON.stringify(o, sortKeys);         // 按 JSON 语义比较用（键排序）
const stamp = () => new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
const SETTINGS = () => settingsPath();

const CORE_EVENTS = ['SessionStart', 'UserPromptSubmit', 'Stop', 'SubagentStop', 'SessionEnd', 'Notification'];
const OPT_EVENTS = ['SubagentStart', 'PostToolUseFailure', 'PermissionRequest', 'PermissionDenied', 'StopFailure', 'InstructionsLoaded', 'CwdChanged'];
export const RUNTIME_FILES = ['vibetrail', 'vibetrail.mjs', 'lib/map.mjs', 'lib/hook.mjs', 'lib/cli.mjs', 'vibetrail-hook'];

function confSet(key, value) {                            // 改或加一行，别的行原样留着
  mkdirp(VT_HOME);
  const f = path.join(VT_HOME, 'config');
  const cur = (readText(f) || '').split('\n').filter((l) => l !== '' && !l.startsWith(key + '='));
  fs.writeFileSync(f + '.tmp', [...cur, `${key}=${value}`].join('\n') + '\n');
  fs.renameSync(f + '.tmp', f);
}
const findNode = () => {
  const c = vtConf('node', '');
  if (c && isFile(c)) return c;
  return process.execPath;
};

// ---- 本机的 Claude Code 可执行文件与它们认识的事件 ----
function claudeBinaries() {
  if (process.env.VIBETRAIL_CLAUDE_BINARIES) return process.env.VIBETRAIL_CLAUDE_BINARIES.split(':').filter(Boolean);
  const out = [];
  const home = process.env.HOME || '';
  const globs = [
    path.join(home, 'Library/Application Support/Claude/claude-code'),
    path.join(home, '.local/share/claude/versions'),
  ];
  for (const g of globs) {
    try {
      for (const d of fs.readdirSync(g)) {
        const c1 = path.join(g, d, 'claude.app/Contents/MacOS/claude');
        if (isFile(c1)) out.push(c1); else if (isFile(path.join(g, d))) out.push(path.join(g, d));
      }
    } catch {}
  }
  const local = path.join(home, '.claude/local/node_modules/@anthropic-ai/claude-code/cli.js');
  if (isFile(local)) out.push(local);
  try {
    let r = execFileSync('command', ['-v', 'claude'], { encoding: 'utf8', shell: '/bin/sh' }).trim();
    while (r) { const st = fs.lstatSync(r); if (!st.isSymbolicLink()) break; const l = fs.readlinkSync(r); r = path.resolve(path.dirname(r), l); }
    if (r && isFile(r)) out.push(r);
  } catch {}
  return [...new Set(out)].sort();
}
function knownEventsOf(bin) {                             // 二进制里那个事件名数组（约 1.2 s，按大小:修改时间:路径 缓存）
  let st; try { st = fs.statSync(bin); } catch { return ''; }
  const key = `${st.size}:${Math.floor(st.mtimeMs / 1000)}:${bin}`;
  const cacheFile = path.join(VT_HOME, 'state', 'claude-events.cache');
  for (const line of (readText(cacheFile) || '').split('\n')) {
    const [k, v] = line.split('\t');
    if (k === key && v) return v;
  }
  let out = '';
  const fd = fs.openSync(bin, 'r');
  try {
    const CH = 4 * 1024 * 1024, OVER = 4096;
    const buf = Buffer.alloc(CH + OVER);
    let pos = 0, carry = 0;
    while (pos < st.size) {
      const n = fs.readSync(fd, buf, carry, CH, pos);
      if (n <= 0) break;
      const hay = buf.slice(0, carry + n).toString('latin1');
      const m = hay.match(/\["PreToolUse","PostToolUse"[^\]]*\]/);
      if (m) { out = ' ' + m[0].replace(/[[\]"]/g, '').split(',').join(' ') + ' '; break; }
      const keep = Math.min(OVER, carry + n);
      buf.copy(buf, 0, carry + n - keep, carry + n);
      carry = keep; pos += n;
    }
  } finally { fs.closeSync(fd); }
  if (!out) {                                             // 老版本数组形状不同：逐个找
    const txt = (() => { try { return fs.readFileSync(bin).toString('latin1'); } catch { return ''; } })();
    const hits = [...CORE_EVENTS, ...OPT_EVENTS].filter((e) => txt.includes(`"${e}"`));
    if (hits.length) out = ' ' + hits.join(' ') + ' ';
  }
  if (out) {
    mkdirp(path.join(VT_HOME, 'state'));
    const keep = (readText(cacheFile) || '').split('\n').filter((l) => l && !l.includes(`\t${bin}\t`) && !l.includes(`:${bin}\t`));
    try { fs.writeFileSync(cacheFile + '.tmp', [...keep, `${key}\t${out}`].join('\n') + '\n'); fs.renameSync(cacheFile + '.tmp', cacheFile); } catch {}
  }
  return out;
}
function eventsFor(mode) {
  if (mode === 'core') return [...CORE_EVENTS];
  if (mode === 'all') return [...CORE_EVENTS, ...OPT_EVENTS];
  const bins = claudeBinaries();
  if (bins.length === 0) return [...CORE_EVENTS];
  const sets = bins.map((b) => knownEventsOf(b) || ` ${CORE_EVENTS.join(' ')} `);
  return [...CORE_EVENTS, ...OPT_EVENTS.filter((ev) => sets.every((k) => k.includes(` ${ev} `)))];
}

// ---- settings 条目 ----
// K16①（借 teamai builtin-hooks.ts:191）：运行时被删、包装冒错时，Claude Code 不会在每个事件上弹 hook 错误。
// 包装是 POSIX sh，用 sh 调；老版本写的是 /bin/bash '…' <事件>，解析两种都认，重跑 init 会换成新写法
const hookCommand = (ev) => `sh '${path.join(VT_HOME, 'bin', 'vibetrail-hook').replace(/'/g, "'\\''")}' ${ev} 2>/dev/null || true`;
const hookScriptOf = (cmd) => {
  const m = String(cmd).match(/^[^']*'(.*)' [A-Za-z]+(?: 2>\/dev\/null \|\| true)?$/);
  return m ? m[1].replace(/'\\''/g, "'") : '';
};
function entriesJson(events) {                            // 每个事件一个 matcher 组（Notification 两组），timeout 显式给（§3.4）
  const out = [];
  for (const ev of events) {
    let t = 30, a = true, ms = [''];
    if (ev === 'SessionStart' || ev === 'UserPromptSubmit') { t = 10; a = false; }
    else if (ev === 'SessionEnd') { t = 5; a = false; }
    else if (ev === 'Stop' || ev === 'SubagentStop') { t = 120; }
    else if (ev === 'Notification') { ms = ['permission_prompt', 'idle_prompt']; }
    for (const m of ms) {
      out.push({ event: ev, group: { ...(m ? { matcher: m } : {}),
        hooks: [{ type: 'command', command: hookCommand(ev), timeout: t, ...(a ? { async: true } : {}) }] } });
    }
  }
  return out;
}
const isOurs = (h) => String(h?.command ?? '').includes('vibetrail-hook');
function stripOurs(s) {                                   // 去掉自家条目（命令里含 vibetrail-hook），空组、空事件一并清掉
  if (!s.hooks || typeof s.hooks !== 'object' || Array.isArray(s.hooks)) return s;
  const hooks = {};
  for (const [ev, groups] of Object.entries(s.hooks)) {
    if (!Array.isArray(groups)) { hooks[ev] = groups; continue; }
    const kept = groups.map((g) => (g && typeof g === 'object' && Array.isArray(g.hooks) ? { ...g, hooks: g.hooks.filter((h) => !isOurs(h)) } : g))
      .filter((g) => !(g && typeof g === 'object' && Array.isArray(g.hooks)) || g.hooks.length > 0);
    if (kept.length > 0) hooks[ev] = kept;
  }
  const out = { ...s };
  if (Object.keys(hooks).length === 0) delete out.hooks; else out.hooks = hooks;
  return out;
}
function settingsRead() {
  const p = SETTINGS();
  if (!isFile(p) || fs.statSync(p).size === 0) return {};
  const v = readJson(p, undefined);
  if (v === undefined || v === null || typeof v !== 'object' || Array.isArray(v)) {
    die(`读不了 ${p}（不是合法的 JSON 对象）。先修好它再装，vibetrail 不会去改一份读不懂的 settings`);
  }
  return v;
}
const settingsSame = (expect) => canon(isFile(SETTINGS()) && fs.statSync(SETTINGS()).size > 0 ? readJson(SETTINGS(), {}) : {}) === canon(expect);
function underTmp(p) {                                    // 在临时目录下（测试用 VIBETRAIL_TMP_ROOTS 覆盖）
  const roots = (process.env.VIBETRAIL_TMP_ROOTS || `${process.env.TMPDIR || '/tmp'}:/tmp:/private/tmp:/var/folders:/private/var/folders`).split(':').filter(Boolean);
  const real = isDir(p) ? vtRealpath(p) : path.join(vtRealpath(path.dirname(p)), path.basename(p));
  for (let r of roots) {
    r = r.replace(/\/$/, '');
    const rr = vtRealpath(r);
    for (const x of [p, real]) if ((x + '/').startsWith(r + '/') || (x + '/').startsWith(rr + '/')) return true;
  }
  return false;
}
function settingsOk() {                                   // 刚写的：是 JSON 对象，且每条自家命令指向的脚本都在
  const s = readJson(SETTINGS(), undefined);
  if (s === undefined || typeof s !== 'object' || Array.isArray(s) || s === null) return false;
  for (const groups of Object.values(s.hooks ?? {})) {
    for (const g of Array.isArray(groups) ? groups : []) {
      for (const h of g?.hooks ?? []) {
        if (!isOurs(h)) continue;
        const p = hookScriptOf(h.command);
        if (!p || !isFile(p)) return false;
      }
    }
  }
  return true;
}
function settingsWrite(expect, next) {                    // 照 Pilot 的原子写：写前后各查一次没被别人改过；备份；临时文件 + rename
  mkdirp(path.join(VT_HOME, 'backup'));
  mkdirp(path.dirname(SETTINGS()));
  if (!settingsSame(expect)) { say(`⚠ ${SETTINGS()} 在这期间被改过，没写；再跑一次即可`); return false; }
  if (isFile(SETTINGS()) && fs.statSync(SETTINGS()).size > 0) {
    const before = path.join(VT_HOME, 'backup', 'settings.json.before-vibetrail');
    if (!fs.existsSync(before) && !(readText(SETTINGS()) || '').includes('vibetrail-hook')) fs.copyFileSync(SETTINGS(), before);
    fs.copyFileSync(SETTINGS(), path.join(VT_HOME, 'backup', `settings.json.${stamp()}-${process.pid}`));
    const olds = fs.readdirSync(path.join(VT_HOME, 'backup')).filter((f) => /^settings\.json\.2/.test(f))
      .map((f) => ({ f, t: fs.statSync(path.join(VT_HOME, 'backup', f)).mtimeMs })).sort((a, b) => b.t - a.t).slice(10);
    for (const o of olds) { try { fs.unlinkSync(path.join(VT_HOME, 'backup', o.f)); } catch {} }
  }
  const tmp = SETTINGS() + '.vibetrail.tmp';
  fs.writeFileSync(tmp, JSON.stringify(next, null, 2) + '\n');
  if (!settingsSame(expect)) { try { fs.unlinkSync(tmp); } catch {} say(`⚠ ${SETTINGS()} 在这期间被改过，没写；再跑一次即可`); return false; }
  fs.renameSync(tmp, SETTINGS());
  return true;
}

// ---- 登记表与候选仓 ----
const chunks = () => {                                    // spool 里的块文件（.rejected 不算）
  const out = [];
  const walk = (d) => {
    let names = []; try { names = fs.readdirSync(d); } catch { return; }
    for (const n of names.sort()) {
      const p = path.join(d, n);
      if (isDir(p)) { if (p !== path.join(VT_HOME, 'spool', '.rejected')) walk(p); }
      else if (n.endsWith('.jsonl') && !n.startsWith('.')) out.push(p);
    }
  };
  walk(path.join(VT_HOME, 'spool'));
  return out.sort();
};
const pendingChunks = (main) => {
  const d = path.join(VT_HOME, 'spool', vtProjectKey(main));
  return chunks().filter((f) => f.startsWith(d + path.sep)).length;
};
const fmtEpoch = (e) => {
  const d = new Date(Number(e) * 1000);
  const p = (n) => String(n).padStart(2, '0');
  return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
};
function candidateProjects() {                            // 用过 Claude Code 的 git 仓，按最近活跃排
  const byRepo = new Map();
  let dirs = []; try { dirs = fs.readdirSync(claudeProjects()); } catch { return []; }
  for (const d of dirs) {
    const full = path.join(claudeProjects(), d);
    if (!isDir(full)) continue;
    let files = [];
    try { files = fs.readdirSync(full).filter((f) => f.endsWith('.jsonl')).map((f) => ({ f: path.join(full, f), t: fs.statSync(path.join(full, f)).mtimeMs })); } catch { continue; }
    if (files.length === 0) continue;
    files.sort((a, b) => b.t - a.t);
    const head = (readText(files[0].f) || '').slice(0, 65536);
    const m = head.match(/"cwd":"([^"]*)"/);
    if (!m) continue;
    let cwd = m[1];
    if (!isDir(cwd)) cwd = cwd.replace(/\/\.claude\/worktrees\/.*$/, '');   // desktop 的 worktree 删了：找回主仓
    if (!isDir(cwd)) continue;
    const main = vtMainCheckout(cwd);
    if (!main) continue;
    const cur = byRepo.get(main) || { mt: 0, n: 0 };
    byRepo.set(main, { mt: Math.max(cur.mt, Math.floor(files[0].t / 1000)), n: cur.n + files.length });
  }
  return [...byRepo.entries()].map(([p, v]) => ({ p, ...v })).sort((a, b) => b.mt - a.mt);
}
function showRegistered() {
  say('scope=project：只采下面这些登记过的仓（连同它们的所有 worktree）：');
  let n = 0;
  let names = []; try { names = fs.readdirSync(path.join(VT_HOME, 'projects')).sort(); } catch {}
  for (const f of names) {
    const p = (readText(path.join(VT_HOME, 'projects', f)) || '').split('\n')[0];
    if (!p) continue;
    n++;
    const k = pendingChunks(p);
    say(`  · ${p}${isDir(p) ? '' : '   ⚠ 目录不在了'}${k > 0 ? `   （spool 待发 ${k} 块）` : ''}`);
  }
  if (n === 0) say(`  ⚠ 还没有登记任何仓，现在什么都不会采。选：${VT_HOME}/bin/vibetrail projects pick；或在要采的仓里跑 ${VT_HOME}/bin/vibetrail projects add`);
  say('  （改：vibetrail projects pick / add / remove [--drop]；全都采：vibetrail init --scope user）');
}

// ---- init ----
export function cmdInit(argv) {
  let scope = '', mode = 'auto';
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--scope') { scope = argv[++i] ?? ''; }
    else if (a === '--events') { mode = argv[++i] ?? ''; }
    else if (a === '--no-register' || a === '--no-pick') { /* 老参数，留着不报错 */ }
    else die(`init 不认识的参数：${a}`);
  }
  if (!['', 'project', 'user'].includes(scope)) die('--scope 只能是 project 或 user');
  if (!['auto', 'core', 'all'].includes(mode)) die('--events 只能是 auto / core / all');
  try { execFileSync('git', ['--version'], { stdio: 'ignore' }); } catch { die('没找到 git'); }
  const cur = settingsRead();
  const SELF = path.dirname(path.dirname(new URL(import.meta.url).pathname));   // tools/

  // 1. 运行时
  for (const d of ['spool', 'state', 'projects', 'logs']) mkdirp(path.join(VT_HOME, d));
  if (vtRealpath(SELF) !== vtRealpath(path.join(VT_HOME, 'bin'))) {
    const bin = path.join(VT_HOME, 'bin.new');
    fs.rmSync(bin, { recursive: true, force: true });
    mkdirp(bin);
    for (const a of RUNTIME_FILES) {
      mkdirp(path.join(bin, path.dirname(a)));
      try { fs.copyFileSync(path.join(SELF, a), path.join(bin, a)); } catch { die(`拷不了 ${path.join(SELF, a)}`); }
    }
    for (const x of ['vibetrail', 'vibetrail-hook', 'vibetrail.mjs']) { try { fs.chmodSync(path.join(bin, x), 0o755); } catch {} }
    let srcRev = 'unknown';
    try { srcRev = execFileSync('git', ['-C', SELF, 'rev-parse', '--short', 'HEAD'], { encoding: 'utf8' }).trim(); } catch {}
    fs.writeFileSync(path.join(bin, 'VERSION'),
      `version=${VT_RUNTIME_VERSION}\nsource=${SELF}\nsource_rev=${srcRev}\ninstalled_at=${new Date().toISOString().replace(/\.\d+Z$/, 'Z')}\n`
      + `node=${process.execPath}\nnode_version=${process.version}\n`);
    const manifest = RUNTIME_FILES.map((a) => `${crypto.createHash('sha256').update(fs.readFileSync(path.join(bin, a))).digest('hex')} ${a}`).join('\n');
    fs.writeFileSync(path.join(bin, 'MANIFEST'), manifest + '\n');
    fs.rmSync(path.join(VT_HOME, 'bin.old'), { recursive: true, force: true });
    if (isDir(path.join(VT_HOME, 'bin'))) fs.renameSync(path.join(VT_HOME, 'bin'), path.join(VT_HOME, 'bin.old'));
    fs.renameSync(bin, path.join(VT_HOME, 'bin'));
    fs.rmSync(path.join(VT_HOME, 'bin.old'), { recursive: true, force: true });
  }
  say(`✓ 运行时 → ${VT_HOME}/bin/（${RUNTIME_FILES.length} 个文件，版本 ${VT_RUNTIME_VERSION}）`);

  // 2. 配置：已有的值不动，只补缺的
  if (scope) confSet('scope', scope);
  if (!vtConf('scope', '')) confSet('scope', 'project');
  confSet('node', process.execPath);
  if (!vtConf('device_id', '')) confSet('device_id', crypto.randomUUID());
  if (!vtConf('turn_idle_close', '')) confSet('turn_idle_close', '3600');
  if (!vtConf('push_max_age', '')) confSet('push_max_age', '3600');
  if (!vtConf('push_max_events', '')) confSet('push_max_events', '100');
  if (!(readText(path.join(VT_HOME, 'config')) || '').split('\n').some((l) => l.startsWith('endpoint='))) confSet('endpoint', '');
  try { fs.chmodSync(path.join(VT_HOME, 'config'), 0o600); } catch {}
  say(`✓ 配置 → ${VT_HOME}/config（scope=${vtConf('scope', 'project')}，node=${process.execPath}）`);
  if (vtConf('capture_content', '1') === '0') say('  采集内容：只带元数据（capture_content=0）');
  else say('  采集内容：全采正文——prompt、模型输出、thinking、工具参数与结果原样上报，不脱敏（capture_content=0 可只留元数据）');

  // 3. settings 条目
  const events = eventsFor(mode);
  const bins = claudeBinaries();
  let next = stripOurs(structuredClone(cur));
  for (const x of entriesJson(events)) {
    next.hooks = next.hooks ?? {};
    next.hooks[x.event] = [...(next.hooks[x.event] ?? []), x.group];
  }
  let written = false, existed = isFile(SETTINGS()) && fs.statSync(SETTINGS()).size > 0;
  if (canon(next) === canon(cur)) {
    say(`✓ hook 条目已是最新（${SETTINGS()} 没动，${events.length} 个事件：${events.join(' ')}）`);
  } else {
    // 运行时在临时目录、settings 却不在：多半是测试漏设了 VIBETRAIL_CLAUDE_SETTINGS——不写
    if (underTmp(VT_HOME) && !underTmp(SETTINGS())) {
      die(`VIBETRAIL_HOME（${VT_HOME}）在临时目录里，却要把 hook 命令写进 ${SETTINGS()}：多半是测试或实验漏设了 VIBETRAIL_CLAUDE_SETTINGS。没写`);
    }
    if (!settingsWrite(cur, next)) die(`写不了 ${SETTINGS()}`);
    if (!settingsOk()) {                                  // 写完自检没过：还原成改之前
      let bk = null;
      try {
        bk = fs.readdirSync(path.join(VT_HOME, 'backup')).filter((f) => f.endsWith('-' + process.pid))
          .map((f) => path.join(VT_HOME, 'backup', f)).sort().pop();
      } catch {}
      if (bk) fs.copyFileSync(bk, SETTINGS()); else if (!existed) { try { fs.unlinkSync(SETTINGS()); } catch {} }
      die(`写完的 ${SETTINGS()} 自检没过（不是合法 JSON，或 hook 命令指向的脚本不在），已还原成改之前`);
    }
    written = true;
    say(`✓ hook 条目 → ${SETTINGS()}（${events.length} 个事件：${events.join(' ')}）`);
  }
  if (mode === 'auto') {
    if (bins.length) say(`  按本机 ${bins.length} 个 Claude Code 可执行文件都认识的事件登记（--events all 可全登记）`);
    else say('  ⚠ 没找到 Claude Code 可执行文件，只登记老版本也有的 6 个事件');
  }
  if (written) {
    if (existed) say(`  改之前的备份在 ${VT_HOME}/backup/${fs.existsSync(path.join(VT_HOME, 'backup', 'settings.json.before-vibetrail')) ? '（装之前的原样是 settings.json.before-vibetrail）' : ''}`);
    else say(`  原来没有 ${SETTINGS()}，新建了一份（没有可备份的）`);
    say('  settings 热加载，已开着的会话从下一次 hook 起生效');
  }
  // PermissionRequest 挂上的时刻（K7）
  if (events.includes('PermissionRequest')) { if (!vtConf('permission_request_since', '')) confSet('permission_request_since', String(Math.floor(Date.now() / 1000))); }
  else confSet('permission_request_since', '');

  // 4. 不登记任何仓，只列出登记表与候选
  if (vtConf('scope', 'project') === 'project') {
    say(''); showRegistered();
    const c = candidateProjects().filter((x) => !vtRegistered(x.p));
    if (c.length) {
      say('用过 Claude Code、还没登记的仓（要采就 vibetrail projects pick 选，或在那个仓里 projects add）：');
      for (const x of c) say(`  · ${x.p}   （${x.n} 个会话，最近 ${fmtEpoch(x.mt)}）`);
    }
  } else say('  scope=user：本机所有目录的会话都采，不看登记表');
  say('');
  say(`看采了什么：${VT_HOME}/bin/vibetrail show     文件在 ${VT_HOME}/spool/<项目>/<会话>/*.jsonl`);
  say(`自检：${VT_HOME}/bin/vibetrail doctor          卸载：${VT_HOME}/bin/vibetrail uninstall`);
}

export function cmdUninstall(argv) {
  const purge = argv[0] === '--purge';
  if (isFile(SETTINGS())) {
    const cur = settingsRead();
    if (JSON.stringify(cur).includes('vibetrail-hook')) {
      if (!settingsWrite(cur, stripOurs(structuredClone(cur)))) die(`写不了 ${SETTINGS()}`);
      say(`✓ 已从 ${SETTINGS()} 去掉 vibetrail 的 hook 条目（原文件备份在 ${VT_HOME}/backup/）`);
    } else say(`  ${SETTINGS()} 里没有 vibetrail 的条目`);
  }
  if (purge) { fs.rmSync(VT_HOME, { recursive: true, force: true }); say(`✓ 已删除 ${VT_HOME}（含 spool 里还没发出去的数据）`); }
  else {
    for (const d of ['bin', 'logs']) fs.rmSync(path.join(VT_HOME, d), { recursive: true, force: true });
    // K14：spool 留着，已写进 spool 的 event_id 清单（state/<sid>/ids）也得留——否则重装后 SessionStart 补做把老会话整个再生成一遍，
    // spool 里同 event_id 出现两块，list / show 的数字翻倍。state 里别的（offset、seen、轮次证据）删掉，重装后从头读、按 ids 挡掉重复
    let kept = 0;
    try {
      for (const sid of fs.readdirSync(path.join(VT_HOME, 'state'))) {
        const dir = path.join(VT_HOME, 'state', sid);
        if (!isDir(dir)) { fs.rmSync(dir, { force: true }); continue; }
        for (const f of fs.readdirSync(dir)) if (f !== 'ids') fs.rmSync(path.join(dir, f), { recursive: true, force: true });
        if (isFile(path.join(dir, 'ids'))) kept++; else fs.rmSync(dir, { recursive: true, force: true });
      }
    } catch {}
    say(`✓ 已删除 ${VT_HOME}/bin、logs，以及 state 里除 ids 之外的内容`);
    say(`  留着：spool（还没发出去的数据）、${kept} 个会话已写入的 event_id 清单（重装后不重复写）、config、登记表、settings 备份；连它们一起删用 --purge`);
  }
  say('  被观测的仓里本来就没写过东西，不用还原');
}

// ---- projects ----
function pickProjects() {
  const cands = candidateProjects();
  if (cands.length === 0) { say(`  没在 ${claudeProjects()} 下找到用过 Claude Code 的 git 仓；在要采的仓里跑 ${VT_HOME}/bin/vibetrail projects add`); return; }
  say('用过 Claude Code 的仓（按最近活跃排，✓ = 已登记）：');
  cands.forEach((x, i) => say(`  ${String(i + 1).padStart(2)}. ${vtRegistered(x.p) ? '✓' : ' '} ${x.p}   （${x.n} 个会话，最近 ${fmtEpoch(x.mt)}）`));
  process.stdout.write('输编号登记，编号前加 - 去掉（空格分隔，如 2 -1），a 全部登记，直接回车不改：');
  let ans = '';
  try { ans = fs.readFileSync(0, 'utf8').split('\n')[0] ?? ''; } catch { ans = ''; }
  ans = ans.trim();
  if (!ans) { say(''); return; }
  if (ans === 'a' || ans === 'A') ans = cands.map((_, i) => String(i + 1)).join(' ');
  let added = 0, removed = 0;
  for (let k of ans.split(/\s+/).filter(Boolean)) {
    const neg = k.startsWith('-');
    if (neg) k = k.slice(1);
    if (!/^\d+$/.test(k)) { say(`  ⚠ 不认识的编号：${neg ? '-' : ''}${k}`); continue; }
    const x = cands[Number(k) - 1];
    if (!x) { say(`  ⚠ 没有第 ${k} 个`); continue; }
    if (neg) {
      if (!vtRegistered(x.p)) { say(`  · 第 ${k} 个本来就没登记，不用去掉：${x.p}`); continue; }
      vtUnregister(x.p); removed++; say(`  ✓ 去掉 ${x.p}：以后不再采`);
      const n = pendingChunks(x.p);
      if (n > 0) say(`    它已采、还没发出去的 ${n} 块还在 spool，将来 push 时照样发；不想发：vibetrail projects remove ${x.p} --drop`);
    } else {
      if (vtRegistered(x.p)) { say(`  · 第 ${k} 个已经登记过：${x.p}`); continue; }
      vtRegister(x.p); added++; say(`  ✓ 登记 ${x.p}`);
    }
  }
  say(`  新登记 ${added} 个，去掉 ${removed} 个`);
}

export function cmdProjects(argv) {
  const sub = argv[0] ?? 'list';
  if (sub === 'list') {
    let names = []; try { names = fs.readdirSync(path.join(VT_HOME, 'projects')).sort(); } catch {}
    if (names.length === 0) { say(`（没有登记的项目；scope=${vtConf('scope', 'project')}）`); return; }
    for (const f of names) {
      const p = (readText(path.join(VT_HOME, 'projects', f)) || '').split('\n')[0];
      if (!p) continue;
      const k = pendingChunks(p);
      say(`${p}${isDir(p) ? '' : '   ⚠ 目录不在了'}${k > 0 ? `   （spool 待发 ${k} 块）` : ''}`);
    }
  } else if (sub === 'add') {
    const d = argv[1] || process.cwd();
    const m = vtRegister(d);
    if (m) say(`✓ 已登记 ${m}`); else die(`不在 git 仓里：${d}`);
  } else if (sub === 'remove' || sub === 'rm') {
    let drop = false, d = '';
    for (const a of argv.slice(1)) { if (a === '--drop') drop = true; else d = a; }
    d = d || process.cwd();
    const m = vtMainCheckout(d);
    if (!m) die(`不在 git 仓里：${d}`);
    vtUnregister(d);
    say(`✓ 已去掉 ${m}：以后不再采（它的所有 worktree 都算）`);
    const k = pendingChunks(m);
    if (k > 0 && drop) {
      const to = path.join(VT_HOME, 'removed', `${vtProjectKey(m)}-${stamp()}`);
      mkdirp(path.join(VT_HOME, 'removed'));
      try {
        fs.renameSync(path.join(VT_HOME, 'spool', vtProjectKey(m)), to);
        fs.utimesSync(to, new Date(), new Date());
        say(`  它已采、还没发出去的 ${k} 块挪到了 ${to}，不会再发，一天后自动删掉（挪错了在这一天里挪回 spool/ 即可）`);
      } catch {}
    } else if (k > 0) {
      say(`  它已采、还没发出去的 ${k} 块还在 spool，将来 push 时照样发；不想发：vibetrail projects remove ${m} --drop`);
    }
  } else if (sub === 'pick') pickProjects();
  else die('projects 只认 list / add / remove / pick');
}

// ---- list / show ----
export function cmdList() {
  if (!isDir(path.join(VT_HOME, 'spool'))) { say(`（spool 为空：${VT_HOME}/spool）`); return; }
  const pad = (s, n) => { const t = String(s); return t.length > n ? t.slice(0, n) : t + ' '.repeat(n - t.length); };
  const padl = (s, n) => String(s).padStart(n);
  say(`${pad('项目', 40)} ${pad('会话', 38)} ${pad('块', 46)} ${padl('条数', 6)} ${padl('字节', 8)}`);
  let n = 0, ev = 0, bytes = 0;
  for (const f of chunks()) {
    const body = readText(f) || '';
    const c = body.split('\n').filter((l) => l !== '').length;
    const b = Buffer.byteLength(body, 'utf8');
    say(`${pad(path.basename(path.dirname(path.dirname(f))), 40)} ${pad(path.basename(path.dirname(f)), 38)} ${pad(path.basename(f), 46)} ${padl(c, 6)} ${padl(b, 8)}`);
    n++; ev += c; bytes += b;
  }
  say('');
  say(`共 ${n} 块、${ev} 条事件、${bytes} 字节，都在 ${VT_HOME}/spool/ 下，每行一条协议事件，可以直接打开看。`);
  say(`端点：${vtConf('endpoint', '') || '没配置（push 不发，这些文件就是将来要推的内容）'}`);
}

const clip = (s, n) => (typeof s === 'string' ? (s.replace(/\s+/g, ' ').length > n ? s.replace(/\s+/g, ' ').slice(0, n) + '…' : s.replace(/\s+/g, ' ')) : s);
const short = (s) => (typeof s === 'string' ? s.slice(0, 8) : '-');
const kn = (v) => (typeof v === 'number' ? (v >= 1e6 ? `${Math.floor(v / 1e5) / 10}M` : v >= 1000 ? `${Math.floor(v / 100) / 10}k` : String(v)) : '-');
const dur = (v) => (typeof v !== 'number' ? '' : v < 1000 ? `${Math.floor(v)}ms` : v < 60000 ? `${Math.floor(v / 100) / 10}s` : `${Math.floor(v / 60000)}m${Math.floor((v % 60000) / 1000)}s`);
const secs = (s) => (typeof s === 'string' ? Date.parse(s.replace(/\.\d+Z$/, 'Z')) / 1000 : null);
function describe(e) {
  const vcs = e.payload?.vcs && typeof e.payload.vcs === 'object'
    ? `${e.payload.vcs.branch ?? '?'}@${String(e.payload.vcs.head_sha ?? '-').slice(0, 7)}${e.payload.vcs.dirty === true ? ' 有改动' : ''}` : '';
  const usage = e.payload?.usage && typeof e.payload.usage === 'object' ? `tokens ${e.payload.usage.total_tokens ?? '?'}` : '';
  let d = '';
  const t = e.type;
  if (t === 'session.start') {
    const v = e.extensions?.['vibetrail.vcs'] ?? {};
    d = `source=${e.payload.source} model=${e.extensions?.['claude.model'] ?? '?'} ${v.branch ?? ''}@${String(v.head_sha ?? '').slice(0, 7)}`;
  } else if (t === 'session.end') d = `reason=${e.payload.reason}`;
  else if (t === 'turn.start') d = `${vcs} ${e.payload.model ? 'model=' + e.payload.model : ''} ${e.provenance?.kind === 'transcript' ? '(transcript 补位)' : ''}`;
  else if (t === 'turn.end') d = `${e.payload.status.code} ${usage} ${vcs}${e.commits ? ' commits=' + e.commits.map((c) => c.sha.slice(0, 7)).join(',') : ''} ${e.extensions?.['vibetrail.closed_by'] ? '关轮:' + e.extensions['vibetrail.closed_by'] : ''}`;
  else if (t === 'permission.decision') d = `${e.payload.decision} by ${e.payload.decided_by} ${e.payload.tool_name} “${clip(e.payload.reason, 80)}”`;
  else if (t === 'tool.request') {
    const inp = e.payload.input;
    const s = inp && typeof inp === 'object' ? (inp.command ?? inp.file_path ?? inp.pattern ?? JSON.stringify(inp)) : JSON.stringify(inp);
    d = `${e.payload.tool_name} ${clip(String(s), 100)}`;
  } else if (t === 'message.assistant' && e.content_state === 'omitted') {
    const c = e.extensions?.['vibetrail.call'] ?? {};
    d = `模型 ${e.payload.model ?? '?'}  入/缓存/出 ${kn(c.usage?.input_tokens)}/${kn(c.usage?.cached_input_tokens)}/${kn(c.usage?.output_tokens)}  ${c.stop_reason ?? '-'}`
      + ((c.tool_calls ?? []).length ? ' → ' + c.tool_calls.join(',') : '') + (c.thinking ? '（有 thinking）' : '')
      + (c.started_at ? '  用时 ' + dur((secs(e.occurred_at) - secs(c.started_at)) * 1000) : '');
  } else if (t === 'tool.end') {
    const m = { success: '成功', error: '出错', cancelled: '取消' };
    d = `${e.payload.tool_name} ${m[e.payload.status.code] ?? e.payload.status.code}  ${dur(e.payload.duration_ms)}`;
  } else if (t === 'message.user' || t === 'message.assistant') d = `“${clip(e.payload.text, 100)}”`;
  else if (t === 'subagent.start') d = `${e.payload.agent_type} 父=${e.parent_agent_instance_id}`;
  else if (t === 'subagent.end') d = `${e.payload.status.code} ${e.payload.agent_type ?? ''}`;
  else if (String(t).startsWith('ext.')) { const p = { ...e.payload }; delete p.tool_input; d = clip(JSON.stringify(p), 100); }
  const ts = String(e.occurred_at).replace(/\.\d+Z$/, 'Z').replace('T', ' ').replace(/Z$/, '');
  const typ = t + ' '.repeat(Math.max(22 - t.length, 1));
  const inst = e.agent_instance_id === 'main' ? 'main    ' : String(e.agent_instance_id).slice(0, 8);
  return `${ts}  ${typ}turn ${short(e.turn_id)}  ${inst}  ${d}`;
}

export function cmdShow(argv) {
  let sess = '', typ = '', last = 0, raw = false;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--session') sess = argv[++i] ?? '';
    else if (a === '--type') typ = argv[++i] ?? '';
    else if (a === '--last') last = Number(argv[++i] ?? 0);
    else if (a === '--json') raw = true;
    else die(`show 不认识的参数：${a}`);
  }
  const files = chunks();
  if (files.length === 0) { say(`（spool 为空：${VT_HOME}/spool。装好后在登记过的仓里开一个 Claude Code 会话，说一句话就会有）`); return; }
  let all = [];
  for (const f of files) for (const l of (readText(f) || '').split('\n')) { if (l) { try { all.push(JSON.parse(l)); } catch {} } }
  all = all.filter((e) => (sess === '' || String(e.session_id).startsWith(sess)) && (typ === '' || String(e.type).startsWith(typ)))
    .sort((a, b) => (a.occurred_at < b.occurred_at ? -1 : a.occurred_at > b.occurred_at ? 1 : a.type < b.type ? -1 : a.type > b.type ? 1 : 0));
  if (last > 0) all = all.slice(-last);
  if (raw) { for (const e of all) say(JSON.stringify(e)); return; }
  const bySession = new Map();
  for (const e of all) { if (!bySession.has(e.session_id)) bySession.set(e.session_id, []); bySession.get(e.session_id).push(e); }
  for (const [sid, evs] of [...bySession.entries()].sort((a, b) => (a[1][0].occurred_at < b[1][0].occurred_at ? -1 : 1))) {
    say(`══ 会话 ${sid}  项目 ${evs[0].project_id}  ${evs.length} 条`);
    for (const e of evs) say(describe(e));
    say('');
  }
  say('（按会话、按时间排；原始事件：vibetrail show --json，文件：vibetrail list）');
}

export function cmdSync() {
  let repo = vtMainCheckout(process.cwd());
  if (!repo) {
    try {
      const f = fs.readdirSync(path.join(VT_HOME, 'projects')).sort()[0];
      repo = f ? (readText(path.join(VT_HOME, 'projects', f)) || '').split('\n')[0] : '';
    } catch {}
  }
  if (!repo) die('当前目录不在 git 仓里，也没有登记过的仓');
  const before = chunks().length;
  runHook('CatchUp', JSON.stringify({ session_id: 'vibetrail-sync', cwd: repo, hook_event_name: 'CatchUp' }));
  say(`✓ 补采完：spool 从 ${before} 块到 ${chunks().length} 块（vibetrail show / list 看结果）`);
}

// ---- doctor ----
function managedSettings() {                              // 企业托管设置（org policy）；VIBETRAIL_CLAUDE_MANAGED 覆盖（测试用）
  if (process.env.VIBETRAIL_CLAUDE_MANAGED) return process.env.VIBETRAIL_CLAUDE_MANAGED.split(':').filter(Boolean);
  return ['/Library/Application Support/ClaudeCode/managed-settings.json', '/etc/claude-code/managed-settings.json'];
}
function settingsLayers() {                               // 本机所有可能挂着 vibetrail hook 的 settings
  const out = [SETTINGS(), SETTINGS().replace(/\.json$/, '.local.json'), ...managedSettings()];
  const repos = [];
  const here = vtMainCheckout(process.cwd());
  if (here) repos.push(here);
  try { for (const f of fs.readdirSync(path.join(VT_HOME, 'projects'))) {
    const r = (readText(path.join(VT_HOME, 'projects', f)) || '').split('\n')[0];
    if (r) repos.push(r);
  } } catch {}
  for (const repo of [...new Set(repos)]) {
    if (!isDir(repo)) continue;
    let wl = '';
    try { wl = execFileSync('git', ['-C', repo, 'worktree', 'list', '--porcelain'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }); } catch { continue; }
    for (const l of wl.split('\n')) if (l.startsWith('worktree ')) {
      const wt = l.slice(9);
      out.push(path.join(wt, '.claude/settings.json'), path.join(wt, '.claude/settings.local.json'));
    }
  }
  return [...new Set(out)];
}

export async function cmdDoctor() {
  let fatal = 0, warn = 0;
  const ok = (s) => say('  ✓ ' + s);
  const bad = (s) => { say('  ✗ ' + s); fatal = 1; };
  const note = (s) => { say('  ⚠ ' + s); warn = 1; };
  say(`vibetrail doctor（VT_HOME=${VT_HOME}）`);

  // 运行时（MANIFEST 逐个校验）
  const manifest = readText(path.join(VT_HOME, 'bin', 'MANIFEST'));
  const verLines = (readText(path.join(VT_HOME, 'bin', 'VERSION')) || '').split('\n');
  const verOf = (k) => verLines.find((l) => l.startsWith(k + '='))?.slice(k.length + 1) ?? '';
  if (manifest) {
    let drift = 0, miss = 0;
    const rows = manifest.split('\n').filter(Boolean);
    for (const line of rows) {
      const [h, f] = line.split(/\s+/);
      const p = path.join(VT_HOME, 'bin', f);
      if (!isFile(p)) { miss++; continue; }
      if (crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex') !== h) drift++;
    }
    if (drift + miss === 0) ok(`运行时完好（${verOf('version')}，${rows.length} 个文件校验通过）`);
    else bad(`运行时：缺 ${miss} 个、内容变了 ${drift} 个——重跑 vibetrail init`);
  } else bad(`运行时不在 ${VT_HOME}/bin（没装，或被删了）——跑 vibetrail init`);

  // node（D12 ③：探针从「jq 跑映射器」换成「node ≥ 20 且能 import map.mjs」）
  const major = Number(process.version.replace(/^v/, '').split('.')[0]);
  if (major >= 20) ok(`node：${process.execPath}（${process.version}）`);
  else bad(`node 版本太低：${process.version}，要 ≥ 20`);
  const confNode = vtConf('node', '');
  if (confNode && !isFile(confNode)) note(`config 里记的 node 不在了：${confNode}——hook 会退回 PATH 找；重跑 vibetrail init 更新（nvm / volta 升级后常见）`);
  if (verOf('node_version') && verOf('node_version') !== process.version) note(`node 换过：装的时候是 ${verOf('node_version')}，现在是 ${process.version}——下面的映射器一项才是判据`);

  // 映射器：真 import + 拿一条假记录跑一遍
  try {
    const { mapRecords } = await import('./map.mjs');
    const r = { type: 'user', uuid: 'doctor-probe', sessionId: 'doctor-probe', cwd: '/', timestamp: '1970-01-01T00:00:00.000Z', message: { role: 'user', content: 'probe' } };
    const out = mapRecords([r], { sid: 'doctor-probe', project_id: 'p', workspace_id: 'w' });
    if (!out?.ledger || out.ledger.records !== 1) throw new Error('映射器没有正常吃下一条记录');
    ok('映射器跑得通（lib/map.mjs：import 得了、吃得下记录）');
  } catch (e) {
    bad(`映射器跑不起来：${String(e.message).slice(0, 160)}——transcript 那一路（turn.end、人机分歧、调用 trace）一条都不会出，而 hook 仍然全部 exit 0`);
  }

  // settings 条目
  const s = isFile(SETTINGS()) ? readJson(SETTINGS(), null) : null;
  if (s && typeof s === 'object' && !Array.isArray(s)) {
    const have = Object.entries(s.hooks ?? {}).filter(([, gs]) => (Array.isArray(gs) ? gs : []).some((g) => (g?.hooks ?? []).some(isOurs))).map(([k]) => k).sort();
    if (have.length === 0) bad(`${SETTINGS()} 里没有 vibetrail 的 hook 条目——跑 vibetrail init`);
    else {
      const missEv = CORE_EVENTS.filter((e) => !have.includes(e));
      if (missEv.length === 0) ok(`hook 条目：${have.join(' ')} `);
      else bad(`hook 条目缺核心事件: ${missEv.join(' ')}`);
      const wrong = [];
      for (const gs of Object.values(s.hooks ?? {})) for (const g of Array.isArray(gs) ? gs : []) for (const h of g?.hooks ?? []) {
        if (!isOurs(h)) continue;
        const p = hookScriptOf(h.command);
        if (p && !isFile(p)) wrong.push(p);
      }
      if (wrong.length) bad(`条目指向的运行时不存在：${[...new Set(wrong)].join(' ')}`);
      const bins = claudeBinaries();
      if (bins.length) {
        const unk = [];
        for (const b of bins) { const kb = knownEventsOf(b); for (const e of have) if (kb && !kb.includes(` ${e} `)) unk.push(`${e}（${b}）`); }
        if (unk.length === 0) ok(`本机 ${bins.length} 个 Claude Code 都认识这些事件`);
        else bad(`有 Claude Code 不认识登记的事件: ${unk.join(' ')}——它会把整份 settings 跳过；重跑 vibetrail init（默认按本机版本登记）`);
      }
    }
  } else bad(`读不了 ${SETTINGS()}`);

  // 全局开关：为真时挂得再对也一条都不触发，且从我们这边看不出来
  const sw = [];
  for (const f of [...new Set([SETTINGS(), SETTINGS().replace(/\.json$/, '.local.json'), ...managedSettings()])]) {
    if (!isFile(f)) continue;
    const v = readJson(f, null);
    if (v?.disableAllHooks === true) sw.push(['disableAllHooks', f]);
    if (v?.allowManagedHooksOnly === true) sw.push(['allowManagedHooksOnly', f]);
  }
  if (sw.length === 0) ok('没有全局开关挡着（disableAllHooks / allowManagedHooksOnly）');
  else for (const [k, f] of sw) {
    if (k === 'disableAllHooks') bad(`本机 hook 被全局关掉（${k}：${f}）——条目挂得再对也一条都不触发，spool 不会涨、也不会有错误日志`);
    else bad(`只跑托管 hook（${k}：${f}）——HOME 里的条目一律被忽略；要采得让管理员把 vibetrail 的条目写进托管设置。安全模式（safe mode）是同样的效果，从文件上看不出来`);
  }

  // 重复挂载：按「事件 + matcher」分组数（同一事件下不同 matcher 各一条是正常的）
  const counts = new Map();
  for (const f of settingsLayers()) {
    if (!isFile(f)) continue;
    const v = readJson(f, null);
    for (const [ev, gs] of Object.entries(v?.hooks ?? {})) for (const g of Array.isArray(gs) ? gs : []) {
      const n = (g?.hooks ?? []).filter(isOurs).length;
      if (n === 0) continue;
      const key = `${ev}\u001f${g?.matcher ?? '*'}`;
      const cur = counts.get(key) ?? { n: 0, files: [] };
      cur.n += n;
      if (!cur.files.includes(f)) cur.files.push(f);
      counts.set(key, cur);
    }
  }
  const dup = [...counts.entries()].filter(([, v]) => v.n > 1);
  if (dup.length === 0) ok(`hook 只挂在一处（${SETTINGS()}）`);
  else {
    for (const [key, v] of dup) {
      const [evn, m] = key.split('\u001f');
      note(`hook 重复挂载：${evn}${m === '*' ? '' : ' matcher=' + m}（${v.n} 条：${v.files.map((f) => f.replace((process.env.HOME || '') + '/', '~/')).join('、')}）`);
    }
    say('     · 后果：这些事件每触发一次跑两遍 hook；session.start / session.end / ext.claude.* 会各多一份（它们的幂等键里带时间），');
    say('       轮次与分歧那几类按 event_id 在本机 ids 就挡掉了。去掉多余的那份（init 只往 HOME 写，项目级的是人手加的）');
  }

  // 采什么
  if (vtConf('capture_content', '1') === '0') say('  · 只带元数据（capture_content=0）：正文只在分歧那几条里带（被拒的命令、被打断的回复、之后人的第一句）');
  else {
    say('  · 全采正文（capture_content=1，默认）：人的 prompt、模型输出、thinking、工具参数与结果原样进事件，不脱敏');
    say(`       只要元数据：在 ${VT_HOME}/config 里写 capture_content=0`);
  }

  // scope 与登记
  const scope = vtConf('scope', 'project');
  const here = vtMainCheckout(process.cwd());
  if (scope === 'user') ok('scope=user：本机所有目录都采');
  else {
    let np = 0; try { np = fs.readdirSync(path.join(VT_HOME, 'projects')).length; } catch {}
    if (np > 0) ok(`scope=project，登记了 ${np} 个项目`);
    else note('scope=project 但一个项目都没登记——什么都不会采（vibetrail projects pick 选，或 projects add）');
    if (here) {
      if (vtRegistered(here)) ok(`本仓已登记：${here}`);
      else say(`  · 本仓没登记，这个仓里的会话不采（要采：vibetrail projects add）：${here}`);
    }
  }

  // 采集证据
  let nst = 0; try { nst = fs.readdirSync(path.join(VT_HOME, 'state')).filter((d) => isDir(path.join(VT_HOME, 'state', d))).length; } catch {}
  const cf = chunks();
  let nev = 0;
  for (const f of cf) nev += (readText(f) || '').split('\n').filter(Boolean).length;
  const oldest = cf.map((f) => path.basename(f).slice(0, 16)).sort()[0];
  ok(`采过 ${nst} 个会话；spool 待发 ${cf.length} 块 / ${nev} 条${oldest ? '，最早一块 ' + oldest : ''}`);
  let rw = 0;
  try {
    for (const d of fs.readdirSync(path.join(VT_HOME, 'state'))) {
      const dir = path.join(VT_HOME, 'state', d);
      if (!isDir(dir)) continue;
      for (const f of fs.readdirSync(dir)) if (f.endsWith('.json')) rw += readJson(path.join(dir, f), {})?.rewrites ?? 0;
    }
  } catch {}
  if (rw > 0) note(`有 ${rw} 次 transcript 被重写后从头重读（offset 信任检查，DESIGN §3.3）`);

  // 落后的 transcript
  let lag = 0;
  const now = Math.floor(Date.now() / 1000);
  try {
    for (const pf of fs.readdirSync(path.join(VT_HOME, 'projects'))) {
      const repo = (readText(path.join(VT_HOME, 'projects', pf)) || '').split('\n')[0];
      if (!isDir(repo)) continue;
      let wl = '';
      try { wl = execFileSync('git', ['-C', repo, 'worktree', 'list', '--porcelain'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }); } catch { continue; }
      for (const l of wl.split('\n')) {
        if (!l.startsWith('worktree ')) continue;
        const dir = path.join(claudeProjects(), vtSlug(l.slice(9)));
        let names = []; try { names = fs.readdirSync(dir).filter((x) => x.endsWith('.jsonl')); } catch { continue; }
        for (const t of names) {
          const full = path.join(dir, t);
          const size = fs.statSync(full).size;
          const c = readJson(path.join(VT_HOME, 'state', t.replace(/\.jsonl$/, ''), 'main.json'), {})?.consumed_bytes ?? 0;
          const mt = Math.floor(fs.statSync(full).mtimeMs / 1000);
          if (c < size && now - mt > 600) lag++;
        }
      }
    }
  } catch {}
  if (lag === 0) ok('登记的仓里没有落后的 transcript');
  else note(`${lag} 份 transcript 没采完（下一次在该仓开会话时 SessionStart 会补做）`);

  // 错误日志（映射失败单独点出来）
  const errLog = readText(path.join(VT_HOME, 'logs', 'errors.log'));
  if (errLog && errLog.trim() !== '') {
    const lines = errLog.split('\n').filter(Boolean);
    const nm = lines.filter((l) => l.includes('"stage":"map')).length;
    note(`errors.log 有 ${lines.length} 条（只记元数据）${nm > 0 ? `，其中 ${nm} 条是映射失败（map:*）` : ''}，最近一条：${lines[lines.length - 1]}`);
  } else ok('没有错误日志');

  const ep = vtConf('endpoint', '');
  if (ep) ok(`端点：${ep}`);
  else say('  · 端点没配置：只落本机 spool、不发（push 还没做，DESIGN §4）');

  say('');
  if (fatal) { say('✗ 有致命项，采集当前不工作'); return 1; }
  if (warn) say('⚠ 能用，有告警'); else say('✓ 采集工作正常');
  return 0;
}

export const USAGE = `vibetrail：机器级安装、登记与本地查看（DESIGN §5）

  vibetrail init [--scope project|user] [--events auto|core|all]
  vibetrail uninstall [--purge]
  vibetrail projects [list | add [目录] | remove [目录] [--drop] | pick]
  vibetrail list
  vibetrail show [--session SID] [--type 前缀] [--last N] [--json]
  vibetrail sync
  vibetrail doctor
  vibetrail version`;

export async function cli(argv) {
  vtPruneRemoved();                                       // projects remove --drop 挪出去的数据留一天
  const cmd = argv[0] ?? '';
  const rest = argv.slice(1);
  switch (cmd) {
    case 'init': cmdInit(rest); return 0;
    case 'uninstall': cmdUninstall(rest); return 0;
    case 'projects': cmdProjects(rest); return 0;
    case 'list': cmdList(); return 0;
    case 'show': cmdShow(rest); return 0;
    case 'sync': cmdSync(); return 0;
    case 'doctor': return await cmdDoctor();
    case 'version': case '--version': case '-v': {
      say(`vibetrail ${VT_RUNTIME_VERSION}`);
      const v = readText(path.join(VT_HOME, 'bin', 'VERSION'));
      if (v) process.stdout.write(v);
      return 0;
    }
    case '': case 'help': case '--help': case '-h': say(USAGE); return 0;
    default: die(`不认识的命令：${cmd}\n${USAGE}`);
  }
}
