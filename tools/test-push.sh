#!/bin/bash
# 回归：push（TODO G7 的 push 一项、DESIGN §4 / D6）。临时目录当 ~/.vibetrail，对手是 tools/push-stub.mjs（只听 127.0.0.1）。
# spool 块直接按协议形状手搭（gen），hook 触发点用真实的 hook 入口跑（Stop / SessionStart / SessionEnd，登记过的临时仓）。
# 断言尽量用 node，不依赖 jq。
export LC_ALL=C
set -uo pipefail
cd "$(dirname "$0")"; SELF=$PWD
T=$(mktemp -d "${TMPDIR:-/tmp}/vibetrail-test-push.XXXXXX")
STUB_PID=''
cleanup(){ [ -n "$STUB_PID" ] && { kill "$STUB_PID"; wait "$STUB_PID"; } 2>/dev/null; [ -n "${VT_KEEP:-}" ] && echo "留着：$T" || rm -rf "$T"; }
trap cleanup EXIT
fail=0; pass=0
if python3 -c 'import jsonschema' 2>/dev/null; then HAVE_SCHEMA=1; else HAVE_SCHEMA=0; fi
skipped_schema=0
schema_ok(){ if [ "$HAVE_SCHEMA" = 1 ]; then python3 "$SELF/schema-check.py" >/dev/null 2>&1; else cat >/dev/null; skipped_schema=$((skipped_schema+1)); true; fi; }
ok(){ pass=$((pass+1)); }
ko(){ fail=$((fail+1)); printf '  ✗ %s\n' "$*"; }
check(){ if eval "$2"; then ok; else ko "$1"; fi; }

export VIBETRAIL_HOME=$T/vt VIBETRAIL_CLAUDE_PROJECTS=$T/claude/projects VIBETRAIL_CLAUDE_SETTINGS=$T/claude/settings.json \
  VIBETRAIL_CODEX_HOME=$T/codex VIBETRAIL_CURSOR_HOME=$T/cursor VIBETRAIL_CLAUDE_BINARIES=/nonexistent \
  VIBETRAIL_STABLE_WAIT=0 VIBETRAIL_FOREGROUND=1 VIBETRAIL_STOP_WAIT=0 VIBETRAIL_BACKFILL_DAYS=all
VT=$VIBETRAIL_HOME
S=$T/stub
vt(){ node "$SELF/vibetrail.mjs" "$@"; }
REPO=$T/proj; mkdir -p "$REPO" "$T/claude/projects"; REPO=$(cd "$REPO" && pwd -P)
( cd "$REPO" && git init -q -b main && git config user.email t@t && git config user.name t && echo init > README && git add -A && git commit -q -m init )
hook(){ printf '{"session_id":"%s","transcript_path":"","cwd":"%s","hook_event_name":"%s","source":"startup","reason":"other"}' "$2" "$REPO" "$1" | node "$SELF/vibetrail.mjs" hook "$1"; }

set_conf(){ node -e 'const fs=require("fs");const [f,k,v]=process.argv.slice(1);let t="";try{t=fs.readFileSync(f,"utf8")}catch{};const ls=t.split("\n").filter((l)=>l&&!l.startsWith(k+"="));ls.push(k+"="+v);fs.writeFileSync(f,ls.join("\n")+"\n")' "$VT/config" "$1" "$2"; }
restart_stub(){
  [ -n "$STUB_PID" ] && { kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; }
  rm -rf "$S"; mkdir -p "$S"
  node "$SELF/push-stub.mjs" "$S" & STUB_PID=$!
  for _ in $(seq 100); do [ -s "$S/port" ] && break; sleep 0.05; done
  PORT=$(cat "$S/port"); set_conf endpoint "http://127.0.0.1:$PORT"
}
reset_push(){ rm -rf "$VT/spool" "$VT/state/push" "$VT/logs/push.log"; }
reqs(){ [ -f "$S/requests.jsonl" ] && wc -l < "$S/requests.jsonl" | tr -d ' ' || echo 0; }
got(){ [ -f "$S/events.jsonl" ] && wc -l < "$S/events.jsonl" | tr -d ' ' || echo 0; }
pending(){ cat "$VT"/spool/*/*/*.jsonl 2>/dev/null | wc -l | tr -d ' '; }             # 块里的全部行（含已 ack、还没删的部分）
rejected(){ cat "$VT"/spool/.rejected/*/*/*.jsonl 2>/dev/null | wc -l | tr -d ' '; }
rq(){ node -e 'const fs=require("fs");let R=[];try{R=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map((l)=>JSON.parse(l))}catch{};console.log(eval(process.argv[2]))' "$S/requests.jsonl" "$1"; }
st(){ node -e 'const fs=require("fs");let S={};try{S=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch{};console.log(eval(process.argv[2]))' "$VT/state/push/state.json" "$1"; }
stamp_ago(){ node -e 'console.log(new Date(Date.now()-Number(process.argv[1])*1000).toISOString().replace(/[-:]/g,"").replace(/\.\d+Z$/,"Z"))' "$1"; }
cat > "$T/gen.mjs" <<'EOF'
// gen --pkey P --sid S --stamp T --n N [--patch '{"3": {...}}'] [--seed X]：往 spool 写一块协议形状的 message.user；event_id 由 seed（默认 sid）与序号算，重跑相同
import fs from 'node:fs'; import path from 'node:path'; import crypto from 'node:crypto';
const argv = process.argv.slice(2); const a = {};
for (let i = 0; i < argv.length; i += 2) a[argv[i].replace(/^--/, '')] = argv[i + 1];
const patch = a.patch ? JSON.parse(a.patch) : {}; const seed = a.seed ?? a.sid;
const uuid = (s) => { const h = crypto.createHash('sha1').update(s).digest('hex'); return `${h.slice(0, 8)}-${h.slice(8, 12)}-5${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`; };
const dir = path.join(process.env.VIBETRAIL_HOME, 'spool', a.pkey, a.sid); fs.mkdirSync(dir, { recursive: true });
const lines = [];
for (let i = 0; i < Number(a.n); i++) {
  let e = { event_id: uuid(`${seed}|${i}`), occurred_at: new Date(Date.UTC(2026, 8, 17, 1, Math.floor(i / 60) % 60, i % 60)).toISOString(), type: 'message.user',
    agent: { name: 'claude-code', version: '2.1.270', surface: 'cli' }, project_id: 'demo', workspace_id: '4041e77c-65d8-4dcb-a476-e544d715ee82',
    session_id: a.sid, turn_id: 'turn-1', agent_instance_id: 'main', provenance: { kind: 'hook', source_event: 'UserPromptSubmit' },
    payload: { text: `hello ${i}`, author_type: 'human', delivery: 'direct' } };
  const p = patch[String(i)];
  if (p) { const { __text_bytes, ...rest } = p; e = { ...e, ...rest }; if (__text_bytes) e.payload = { ...e.payload, text: 'x'.repeat(Number(__text_bytes)) }; }
  lines.push(JSON.stringify(e));
}
let f = path.join(dir, `${a.stamp}-${process.pid}-main.jsonl`);
for (let k = 2; fs.existsSync(f); k++) f = path.join(dir, `${a.stamp}-${process.pid}_${k}-main.jsonl`);
fs.writeFileSync(f, lines.join('\n') + '\n');
EOF
gen(){ node "$T/gen.mjs" "$@"; }
now(){ stamp_ago 0; }

echo "════ 0. 准备：init、登记临时仓 ════"
vt init --agents claude >/dev/null 2>&1
( cd "$REPO" && vt projects add >/dev/null 2>&1 )
check "init 装了 lib/push.mjs、MANIFEST 列着它" '[ -f "$VT/bin/lib/push.mjs" ] && grep -q " lib/push.mjs$" "$VT/bin/MANIFEST"'
check "config 有 device_id 与两个门槛，endpoint 为空" 'grep -q "^device_id=" "$VT/config" && grep -q "^push_max_age=3600$" "$VT/config" && grep -q "^push_max_events=100$" "$VT/config" && grep -q "^endpoint=$" "$VT/config"'

echo "════ 1. 端点没配：不发，spool 原样 ════"
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(stamp_ago 7200)" --n 150
out=$(vt push 2>&1); rc=$?
check "vibetrail push：退出码 1、说端点没配置" '[ $rc -eq 1 ] && grep -q "端点没配置" <<<"$out"'
hook Stop sess-hook
check "Stop（门槛早就满了）也不发：spool 还是 150 条、没有 state/push" '[ "$(pending)" = 150 ] && [ ! -e "$VT/state/push/state.json" ]'
out=$(vt push --list 2>&1)
check "push --list：待发 150 条、「端点没配，不推」" 'grep -q "共 1 个会话、1 块、150 条" <<<"$out" && grep -q "端点没配，不推" <<<"$out"'
out=$(vt doctor 2>&1)
check "doctor：端点没配置" 'grep -q "端点没配置" <<<"$out"'

echo "════ 2. 手动 push：全机混批、每批 ≤ 100 条、从最早的块发、发完删块、带 token ════"
restart_stub
TOKEN=tok-0123456789abcdef-XYZ
printf '%s\n' "$TOKEN" > "$VT/token"; chmod 600 "$VT/token"; printf '%s' "$TOKEN" > "$S/token"
gen --pkey pb-0000000000000002 --sid sess-b --stamp "$(stamp_ago 9000)" --n 30
out=$(vt push 2>&1); rc=$?
check "退出码 0、「发完」" '[ $rc -eq 0 ] && grep -q "发完" <<<"$out"'
check "桩收到 180 条、两批 100 + 80、都带 token、都是 200" '[ "$(got)" = 180 ] && [ "$(rq "R.map((r)=>r.count+\":\"+r.status+\":\"+r.has_token).join()")" = "100:200:true,80:200:true" ]'
check "第一批先是更早的块（sess-b 30 条）再接 sess-a：混批" '[ "$(node -e "const fs=require(\"fs\");const E=fs.readFileSync(\"$S/events.jsonl\",\"utf8\").trim().split(\"\\n\").map(JSON.parse);console.log(E[0].session_id+\",\"+E[30].session_id)")" = "sess-b,sess-a" ]'
check "spool 清空、游标清空、累计 180 条新收" '[ "$(pending)" = 0 ] && [ "$(st "Object.keys(S.cursors).length+\",\"+S.totals.events+\",\"+S.totals.accepted")" = "0,180,180" ]'
check "batch_id 是 UUID，同一组事件重算相同" '[ "$(rq "R.every((r)=>/^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(r.batch_id))")" = true ]'
check "收到的事件全部过协议 schema" 'schema_ok < "$S/events.jsonl"'
check "token 只在 token 文件里：state、logs、spool 都没有" '! grep -r -q "$TOKEN" "$VT/state" "$VT/logs" "$VT/spool" 2>/dev/null'
check "logs/push.log 记了一行计数，没有 token" '[ "$(wc -l < "$VT/logs/push.log" | tr -d " ")" = 1 ] && grep -q "\"accepted\":180" "$VT/logs/push.log"'
out=$(vt push 2>&1)
check "再推一次：没有待发、不发请求" 'grep -q "没有待发的事件" <<<"$out" && [ "$(reqs)" = 2 ]'
rm -f "$S/token"

echo "════ 3. 按字节拆批：请求体不超上限 ════"
restart_stub; reset_push
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 40 --patch "$(node -e 'const p={};for(let i=0;i<40;i++)p[i]={__text_bytes:1500};console.log(JSON.stringify(p))')"
VIBETRAIL_PUSH_MAX_REQUEST_BYTES=20000 vt push >/dev/null 2>&1
check "40 条全收到、每个请求 ≤ 20000 字节、至少 3 批" '[ "$(got)" = 40 ] && [ "$(rq "R.every((r)=>r.bytes<=20000)&&R.length>=3")" = true ]'

echo "════ 4. Stop 看门槛：不满不发；全机满 100 条或最早的超 1 小时就推全机；一次最多 push_max_batches 批 ════"
restart_stub; reset_push
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 60
hook Stop sess-hook
check "60 条、刚写的：Stop 不发" '[ "$(reqs)" = 0 ] && [ "$(pending)" = 60 ]'
gen --pkey pb-0000000000000002 --sid sess-b --stamp "$(now)" --n 40
hook Stop sess-hook
check "两个项目合起来满 100 条：Stop 推，全发完" '[ "$(got)" = 100 ] && [ "$(pending)" = 0 ]'
restart_stub
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(stamp_ago 7200)" --n 3
hook Stop sess-hook
check "只有 3 条、但最早的块是两小时前：Stop 推" '[ "$(got)" = 3 ] && [ "$(pending)" = 0 ]'
restart_stub
set_conf push_max_events 1000; set_conf push_max_batches 2
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(stamp_ago 7200)" --n 250
hook Stop sess-hook
check "push_max_batches=2：Stop 只发两批，游标停在 200、块还在" '[ "$(got)" = 200 ] && [ "$(reqs)" = 2 ] && [ "$(st "Object.values(S.cursors).join()")" = 200 ] && [ "$(pending)" = 250 ]'
out=$(vt push --list 2>&1)
check "push --list 只算没发的 50 条" 'grep -q "共 1 个会话、1 块、50 条" <<<"$out"'
hook Stop sess-hook
check "下一次 Stop 从 200 接着发，剩下 50 条收齐、块删掉、没有重复" '[ "$(got)" = 250 ] && [ "$(pending)" = 0 ] && [ "$(rq "R.reduce((s,r)=>s+r.count,0)")" = 250 ]'
set_conf push_max_events 100; set_conf push_max_batches 10

echo "════ 5. SessionStart / SessionEnd 兜底不看门槛 ════"
restart_stub; reset_push
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 3
hook SessionStart sess-5
check "SessionStart：3 条 + 它自己的 session.start 都推了" '[ "$(got)" = 4 ] && [ "$(pending)" = 0 ] && grep -q "\"session.start\"" "$S/events.jsonl"'
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 2 --seed sess-a-2
hook SessionEnd sess-5
check "SessionEnd：2 条 + session.end 都推了" '[ "$(got)" = 7 ] && [ "$(pending)" = 0 ] && grep -q "\"session.end\"" "$S/events.jsonl"'
check "hook 发出的事件也过 schema" 'schema_ok < "$S/events.jsonl"'
hook UserPromptSubmit sess-5
check "UserPromptSubmit 不触发 push" '[ "$(reqs)" = 2 ]'

echo "════ 6. 暂时失败：记失败与退避、数据不动；退避期内兜底也不发；手动 push 不看退避；成功后清零 ════"
restart_stub; reset_push
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 5
echo 503 > "$S/plan"
hook SessionEnd sess-6
check "503：发了 1 次、数据原样、failures=1、下一次在 45～75 秒后" '[ "$(reqs)" = 1 ] && [ "$(pending)" = 6 ] && [ "$(st "S.failures===1&&S.next_at-Date.now()>40000&&S.next_at-Date.now()<76000")" = true ]'
check "last_error 记 server / 503 / INDEX_UNAVAILABLE，不记正文" '[ "$(st "[S.last_error.kind,S.last_error.status,S.last_error.code].join()")" = "server,503,INDEX_UNAVAILABLE" ]'
hook SessionStart sess-6
hook Stop sess-6
check "退避期内 SessionStart、Stop 都不发请求" '[ "$(reqs)" = 1 ]'
out=$(vt doctor 2>&1)
check "doctor 点名连续失败、说几点之前不推" 'grep -q "push 连续失败 1 次" <<<"$out" && grep -q "之前自动触发都不推" <<<"$out"'
first_ids=$(rq "R[0].ids.join()")
out=$(vt push 2>&1); rc=$?
check "手动 push 不看退避：发完、failures / next_at 清零" '[ $rc -eq 0 ] && [ "$(pending)" = 0 ] && [ "$(st "S.failures+\",\"+S.next_at")" = "0,0" ]'
check "重发用的是同一批 event_id" '[ "$(rq "\"$first_ids\".split(\",\").every((i)=>R[1].ids.includes(i))")" = true ]'
for n in 1 2 3 4 5 6 7 8; do echo 503; done > "$S/plan"
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 1 --seed backoff
for n in 1 2 3 4 5 6 7 8; do vt push >/dev/null 2>&1; done
check "连续失败退避翻倍、封顶 1 小时（带抖动）" '[ "$(st "S.failures===8&&S.next_at-Date.now()<=3600000&&S.next_at-Date.now()>2800000")" = true ]'
rm -f "$S/plan"

echo "════ 7. 401、连不上、超时、404：只退避、不动数据，说清楚是哪一类 ════"
restart_stub; reset_push
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 5
echo 401 > "$S/plan"
out=$(vt push 2>&1); rc=$?
check "401：退出码 1、提示 token、数据原样、不隔离" '[ $rc -eq 1 ] && grep -q "token 无效" <<<"$out" && [ "$(pending)" = 5 ] && [ "$(rejected)" = 0 ]'
out=$(vt doctor 2>&1)
check "doctor 点名 401 与 token" 'grep -q "HTTP 401 INVALID_IDENTITY token 无效" <<<"$out"'
set_conf endpoint "http://127.0.0.1:9"
out=$(vt push 2>&1)
check "连不上：说「连不上端点」、数据原样" 'grep -q "连不上端点" <<<"$out" && [ "$(pending)" = 5 ] && [ "$(st "S.last_error.kind")" = network ]'
set_conf endpoint "http://127.0.0.1:$PORT"
echo hang > "$S/plan"
out=$(VIBETRAIL_PUSH_TIMEOUT_MS=400 vt push 2>&1)
check "超时：TIMEOUT、数据原样" 'grep -q "TIMEOUT" <<<"$out" && [ "$(pending)" = 5 ]'
set_conf endpoint "http://127.0.0.1:$PORT/wrong/"
out=$(vt push 2>&1)
check "路径不对（404）：算配置问题、数据原样" 'grep -q "HTTP 404" <<<"$out" && grep -q "端点或客户端配置不对" <<<"$out" && [ "$(pending)" = 5 ] && [ "$(rejected)" = 0 ]'
set_conf endpoint "http://127.0.0.1:$PORT/api/v1/collection/batches/"
out=$(vt push 2>&1)
check "端点写全路径（带结尾斜杠）也认" 'grep -q "发完" <<<"$out" && [ "$(got)" = 5 ]'
set_conf endpoint "ftp://127.0.0.1:$PORT"
out=$(vt push 2>&1); rc=$?
check "端点不是 http(s)：不发、说写错了" '[ $rc -eq 1 ] && grep -q "端点写错了" <<<"$out"'
set_conf endpoint "http://127.0.0.1:$PORT"

echo "════ 8. 拒收只隔离那几条：422 带位置、INVALID_TIME 二分、409 / 413 带 id、本地超 1 MiB 不发、批次外壳出错不隔离 ════"
restart_stub; reset_push
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 10 --patch '{"3":{"type":"BAD TYPE","payload":{"text":"SECRET-MARKER-3","author_type":"human"}},"7":{"occurred_at":"2026-09-17T09:00:07.000+08:00"}}'
out=$(vt push 2>&1); rc=$?
check "422：8 条收下、2 条隔离、退出码 0、块删掉" '[ $rc -eq 0 ] && [ "$(got)" = 8 ] && [ "$(rejected)" = 2 ] && [ "$(pending)" = 0 ]'
check "隔离的是原样那两行（放在 .rejected/<项目>/<会话>/<块名>）" 'grep -q "SECRET-MARKER-3" "$VT"/spool/.rejected/pa-0000000000000001/sess-a/*.jsonl && grep -q "+08:00" "$VT"/spool/.rejected/pa-0000000000000001/sess-a/*.jsonl'
check "原因只有元数据：INVALID_EVENT、/type 与 /occurred_at、行号，没有正文" '[ "$(node -e "const L=require(\"fs\").readFileSync(\"$VT/state/push/rejected.jsonl\",\"utf8\").trim().split(\"\\n\").map(JSON.parse);console.log(L.map((x)=>x.code+x.where+\"@\"+x.line).sort().join())")" = "INVALID_EVENT/occurred_at@8,INVALID_EVENT/type@4" ] && ! grep -q SECRET-MARKER "$VT/state/push/rejected.jsonl"'
restart_stub; reset_push
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 20 --patch '{"13":{"occurred_at":"0999-01-01T00:00:00.000Z"}}'
vt push >/dev/null 2>&1
check "INVALID_TIME 不带位置：二分找出那一条，19 条收下、1 条隔离、请求不超过 12 个" '[ "$(got)" = 19 ] && [ "$(rejected)" = 1 ] && grep -q "0999-01-01" "$VT"/spool/.rejected/*/*/*.jsonl && [ "$(reqs)" -le 12 ]'
restart_stub; reset_push
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 5 --patch '{"2":{"extensions":{"test.owner":"other"}}}'
vt push >/dev/null 2>&1
check "409 已归属别的用户：按 message 里的 event_id 只隔离那一条" '[ "$(got)" = 4 ] && [ "$(rejected)" = 1 ] && grep -q "\"code\":\"EVENT_CONFLICT\"" "$VT/state/push/rejected.jsonl"'
restart_stub; reset_push
echo 3000 > "$S/event_limit"
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 4 --patch '{"1":{"__text_bytes":4000}}'
vt push >/dev/null 2>&1
check "413 EVENT_TOO_LARGE（服务端按规范化后算）：只隔离那一条" '[ "$(got)" = 3 ] && [ "$(rejected)" = 1 ] && grep -q "\"code\":\"EVENT_TOO_LARGE\"" "$VT/state/push/rejected.jsonl"'
restart_stub; reset_push
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 3 --patch '{"0":{"__text_bytes":1100000}}'
big_id=$(head -1 "$VT"/spool/pa-0000000000000001/sess-a/*.jsonl | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).event_id)')
vt push >/dev/null 2>&1
check "本地就超 1 MiB：不发、直接隔离（LOCAL_EVENT_TOO_LARGE），其余照发" '[ "$(got)" = 2 ] && [ "$(rejected)" = 1 ] && [ "$(rq "R.some((r)=>r.ids.includes(\"$big_id\"))")" = false ] && grep -q LOCAL_EVENT_TOO_LARGE "$VT/state/push/rejected.jsonl"'
restart_stub; reset_push
mkdir -p "$VT/spool/pa-0000000000000001/sess-a"; printf 'not json\n\n' > "$VT/spool/pa-0000000000000001/sess-a/20260917T000000Z-1-main.jsonl"
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 2
vt push >/dev/null 2>&1
check "坏行隔离（LOCAL_BAD_JSON）、空行跳过，好的照发、两块都删掉" '[ "$(got)" = 2 ] && [ "$(rejected)" = 1 ] && [ "$(pending)" = 0 ] && grep -q LOCAL_BAD_JSON "$VT/state/push/rejected.jsonl"'
restart_stub; reset_push
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 5
echo envelope > "$S/plan"
out=$(vt push 2>&1)
check "批次外壳 422（/client/…）：一条都不隔离、停下退避、说是外壳的问题" '[ "$(rejected)" = 0 ] && [ "$(pending)" = 5 ] && grep -q "批次外壳不对" <<<"$out" && [ "$(st "S.failures")" = 1 ]'
set_conf device_id not-a-uuid
out=$(vt push 2>&1)
check "config 的 device_id 坏了：不发请求、说重跑 init" '[ "$(reqs)" = 1 ] && grep -q "BAD_DEVICE_ID" <<<"$out"'
set_conf device_id 30adead5-2cc6-4d51-b515-12bfb1af341d

echo "════ 9. 同一批里同一个 event_id 内容不同：只发第一条，不吃整批 409 ════"
restart_stub; reset_push
gen --pkey pa-0000000000000001 --sid sess-old --stamp "$(stamp_ago 60)" --n 3 --seed same
gen --pkey pa-0000000000000001 --sid sess-new --stamp "$(now)" --n 3 --seed same --patch '{"1":{"payload":{"text":"newer","author_type":"human"}}}'
vt push >/dev/null 2>&1
check "一批 3 条、200、没有 409；两块都删掉；留下的是先写的那份" '[ "$(rq "R.map((r)=>r.count+\":\"+r.status).join()")" = "3:200" ] && [ "$(pending)" = 0 ] && ! grep -q newer "$S/events.jsonl"'

echo "════ 10. 块超 100 条按批 ack：中途失败游标停在已 ack 处、续传不重不丢；ack 之后被杀最多重发一批 ════"
restart_stub; reset_push
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 250
printf 'ok\n503\n' > "$S/plan"
vt push >/dev/null 2>&1
check "第一批收下、第二批 503：游标 100、块还在" '[ "$(got)" = 100 ] && [ "$(st "Object.values(S.cursors).join()")" = 100 ] && [ "$(pending)" = 250 ]'
vt push >/dev/null 2>&1
check "续传：250 条收齐、没有一个请求带重复（duplicate 0）、块删掉" '[ "$(got)" = 250 ] && [ "$(st "S.totals.duplicate")" = 0 ] && [ "$(pending)" = 0 ]'
restart_stub; reset_push
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 250
VIBETRAIL_PUSH_DIE_AFTER_ACK=1 vt push >/dev/null 2>&1
check "ack 之后、记账之前被杀：游标没推进、锁还在" '[ "$(got)" = 100 ] && [ "$(st "Object.keys(S.cursors||{}).length")" = 0 ] && [ -d "$VT/state/push/.lock" ]'
out=$(vt push 2>&1)
check "锁不到 600 秒：这次不发" 'grep -q "已有一个 push 在跑" <<<"$out" && [ "$(reqs)" = 1 ]'
touch -t 202001010000 "$VT/state/push/.lock"
vt push >/dev/null 2>&1
check "锁过期后接着发：250 条都收到、只重发了被杀那一批（duplicate 100）、块删掉" '[ "$(got)" = 250 ] && [ "$(st "S.totals.duplicate")" = 100 ] && [ "$(pending)" = 0 ] && [ ! -d "$VT/state/push/.lock" ]'

echo "════ 11. 两个 push 同时跑：一个发、一个跳过，不重不丢 ════"
restart_stub; reset_push
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 300
printf 'slow\nslow\nslow\n' > "$S/plan"
( vt push > "$T/c1.out" 2>&1 ) & p1=$!
( vt push > "$T/c2.out" 2>&1 ) & p2=$!
wait "$p1" "$p2"
check "恰好一个说已有 push 在跑；300 条各收一次、请求 3 个" '[ "$(cat "$T/c1.out" "$T/c2.out" | grep -c "已有一个 push 在跑")" = 1 ] && [ "$(got)" = 300 ] && [ "$(reqs)" = 3 ]'

echo "════ 12. --requeue：隔离的放回待发，修好之后发得出去 ════"
restart_stub; reset_push
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 5 --patch '{"2":{"extensions":{"test.owner":"other"}}}'
vt push >/dev/null 2>&1
out=$(vt doctor 2>&1)
check "doctor：隔离着 1 条、按 code 计数、提示 --requeue" 'grep -q "隔离着 1 条" <<<"$out" && grep -q "409 EVENT_CONFLICT 1" <<<"$out" && grep -q "push --requeue" <<<"$out"'
touch "$S/accept_all"
out=$(vt push --requeue 2>&1)
check "放回 1 条、.rejected 清空、原因记录挪进 history" 'grep -q "放回待发 1 条" <<<"$out" && [ "$(rejected)" = 0 ] && [ "$(pending)" = 1 ] && [ ! -f "$VT/state/push/rejected.jsonl" ] && [ -s "$VT/state/push/rejected.history.jsonl" ]'
vt push >/dev/null 2>&1
check "重发收下、spool 清空" '[ "$(got)" = 5 ] && [ "$(pending)" = 0 ]'

echo "════ 13. --show / --show --json / --list / doctor ════"
restart_stub; reset_push
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 120
out=$(vt push --show 2>&1)
check "--show：下一批 100 条、类型分布" 'grep -q "下一批：100 条" <<<"$out" && grep -q "message.user 100" <<<"$out"'
vt push --show --json > "$T/body.json"
check "--show --json 是合法批次：100 条、batch_id 是 UUID、device_id 取 config" '[ "$(node -e "const b=JSON.parse(require(\"fs\").readFileSync(\"$T/body.json\",\"utf8\"));console.log(b.events.length+\",\"+/^[0-9a-f-]{36}$/.test(b.batch_id)+\",\"+b.client.device_id+\",\"+b.client.name)")" = "100,true,30adead5-2cc6-4d51-b515-12bfb1af341d,paas-coding-hook" ]'
check "--show --json 的事件过 schema" 'node -e "for (const e of JSON.parse(require(\"fs\").readFileSync(\"$T/body.json\",\"utf8\")).events) console.log(JSON.stringify(e))" | schema_ok'
check "--show 不发请求、不写 state" '[ "$(reqs)" = 0 ] && [ ! -e "$VT/state/push/state.json" ]'
vt push >/dev/null 2>&1
out=$(vt doctor 2>&1)
check "doctor：上次推送成功、累计发出 120 条" 'grep -q "上次推送成功" <<<"$out" && grep -q "累计发出 120 条：新收 120" <<<"$out"'
out=$(vt push --list 2>&1)
check "push --list：没有待发、上次成功" 'grep -q "待发：没有" <<<"$out" && grep -q "上次成功" <<<"$out"'
out=$(vt list 2>&1)
check "vibetrail list 的端点一行指向 push --list" 'grep -q "push --list" <<<"$out"'

echo "════ 14. sync 补采完接着推 ════"
restart_stub; reset_push
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 7
out=$(cd "$REPO" && vt sync 2>&1); rc=$?
check "sync：补采、推送 7 条" '[ $rc -eq 0 ] && grep -q "补采完" <<<"$out" && grep -q "推送 1 批：新收 7" <<<"$out" && [ "$(got)" = 7 ]'

echo "════ 15. token 不出本机：写 spool 之前换成占位，push 发之前再查一遍（接入指南：本地缓存与请求正文不能有 Token） ════"
restart_stub; reset_push
printf '%s\n' "$TOKEN" > "$VT/token"
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 3 --patch "{\"1\":{\"payload\":{\"text\":\"我的 token 是 $TOKEN 帮我填上\",\"author_type\":\"human\"}}}"
vt push >/dev/null 2>&1
check "push：老块里带着的 token 发出去之前换成占位，3 条都收下、仍过 schema" '[ "$(got)" = 3 ] && ! grep -q "$TOKEN" "$S/events.jsonl" && grep -q "已去掉上报 token" "$S/events.jsonl" && schema_ok < "$S/events.jsonl"'
node --input-type=module -e '
import { vtSpoolWrite, vtRedactToken } from "'"$SELF"'/lib/hook.mjs";
const t = process.argv[1];
vtSpoolWrite("pa-0000000000000001", "sess-w", "hook-test", [{ event_id: "11111111-2222-5333-a444-555555555555", type: "message.user", payload: { text: "贴进来的 " + t + " 与转义的 " + JSON.stringify({ t }) } }]);
const q = "a\"b\\c-0123456789";                                   // 带引号与反斜杠的 token：JSON 转义后的写法也要换掉
if (vtRedactToken(JSON.stringify({ x: "前 " + q + " 后" }), q).includes("0123456789")) process.exit(1);
' "$TOKEN"
check "写 spool 之前就换掉：块文件里没有 token（原文与 JSON 转义的都没有），有占位" '[ $? -eq 0 ] && ! grep -rq -- "$TOKEN" "$VT/spool" && grep -rq "已去掉上报 token" "$VT/spool/pa-0000000000000001/sess-w"'
rm -f "$VT/token"

echo "════ 16. 503 IDENTITY_UNAVAILABLE：照样只退避，提示说出「token 可能不属于这个环境」；连着 3 次点名先换 token；换一种错或推成功就从头数 ════"
restart_stub; reset_push
gen --pkey pa-0000000000000001 --sid sess-a --stamp "$(now)" --n 5
echo identity > "$S/plan"
out=$(vt push 2>&1); rc=$?
check "一次：退出码 1、数据原样、不隔离，提示 token 可能不属于这个环境、给出 vibetrail token" '[ $rc -eq 1 ] && [ "$(pending)" = 5 ] && [ "$(rejected)" = 0 ] && grep -q "token 不属于这个环境" <<<"$out" && grep -q "vibetrail token" <<<"$out" && [ "$(st "S.last_error.kind+\",\"+S.same_error")" = "server,1" ]'
out=$(vt doctor 2>&1)
check "doctor：一次时说明可能是 token，但还不点名先换 token" 'grep -q "校验 token 没成" <<<"$out" && ! grep -q "先换 token" <<<"$out"'
printf 'identity\nidentity\n' > "$S/plan"; vt push >/dev/null 2>&1; out=$(vt push 2>&1)
check "连着 3 次：push 输出、doctor、push --list 都点名先换 token 再手动推" '[ "$(st "S.same_error")" = 3 ] && grep -q "连着 3 次都是服务端校验 token 没成：先换 token" <<<"$out" && grep -q "先换 token" <<<"$(vt doctor 2>&1)" && grep -q "先换 token" <<<"$(vt push --list 2>&1)"'
echo 503 > "$S/plan"; vt push >/dev/null 2>&1
check "换成别的错（503 INDEX_UNAVAILABLE）：从 1 重新数，不再点名换 token" '[ "$(st "S.same_error+\",\"+S.failures")" = "1,4" ] && ! grep -q "先换 token" <<<"$(vt doctor 2>&1)"'
vt push >/dev/null 2>&1
check "推成功：计数与失败次数清零、5 条收下" '[ "$(st "S.same_error+\",\"+S.failures")" = "0,0" ] && [ "$(got)" = 5 ]'

echo
[ "$skipped_schema" -gt 0 ] && echo "（没装 python jsonschema，跳过 $skipped_schema 项 schema 校验）"
echo "通过 $pass 项，失败 $fail 项"
[ "$fail" -eq 0 ]
