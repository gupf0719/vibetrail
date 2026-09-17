#!/bin/bash
# 回归：Codex / Cursor 的采集（TODO G12）。临时目录当 ~/.vibetrail、~/.codex、~/.cursor，临时 git 仓当被观测项目。
# Codex：逐步追加 rollout、逐个触发 hook；Cursor：只喂 hook 入参（这一版不读 Cursor 的 transcript）。
# **fixture 是照源码与本机桌面版的记录形状手搭的**：打断、拒绝、子 agent 还没有真实样本（G12 §4），拿到样本后换成真记录。
# jq 断言按 jq 1.6 写（本机是 1.6）。
export LC_ALL=C
set -uo pipefail
cd "$(dirname "$0")"; SELF=$PWD
T=$(mktemp -d "${TMPDIR:-/tmp}/vibetrail-test-agents.XXXXXX"); trap '[ -n "${VT_KEEP:-}" ] && echo "留着：$T" || rm -rf "$T"' EXIT
fail=0; pass=0
if python3 -c 'import jsonschema' 2>/dev/null; then HAVE_SCHEMA=1; else HAVE_SCHEMA=0; fi
skipped_schema=0
schema_ok(){ if [ "$HAVE_SCHEMA" = 1 ]; then python3 "$SELF/schema-check.py" >/dev/null 2>&1; else cat >/dev/null; skipped_schema=$((skipped_schema+1)); true; fi; }
ok(){ pass=$((pass+1)); }
ko(){ fail=$((fail+1)); printf '  ✗ %s\n' "$*"; }
check(){ if eval "$2"; then ok; else ko "$1"; fi; }

# 真实配置的指纹：测试不许动它们
real_sum(){ for f in "$HOME/.codex/hooks.json" "$HOME/.codex/config.toml" "$HOME/.cursor/hooks.json" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; do { cat "$f" 2>/dev/null || echo "(无)"; } | cksum; done; }
REAL_SUM=$(real_sum)

export VIBETRAIL_HOME=$T/vt VIBETRAIL_CLAUDE_PROJECTS=$T/claude/projects VIBETRAIL_CLAUDE_SETTINGS=$T/claude/settings.json \
  VIBETRAIL_CODEX_HOME=$T/codex VIBETRAIL_CURSOR_HOME=$T/cursor VIBETRAIL_CLAUDE_BINARIES=/nonexistent \
  VIBETRAIL_STABLE_WAIT=0 VIBETRAIL_FOREGROUND=1 VIBETRAIL_STOP_WAIT=0 VIBETRAIL_BACKFILL_DAYS=all   # 夹具的时间是写死的，别让补采窗口（U18）过两天把它们挡掉
VT=$VIBETRAIL_HOME
vt(){ node "$SELF/vibetrail.mjs" "$@"; }
hook(){ printf '%s' "$3" | node "$SELF/vibetrail.mjs" hook "$1" "$2"; }
spool(){ cat "$VT"/spool/*/*/*.jsonl 2>/dev/null; }
q(){ spool | jq -s -c "$1"; }
TS(){ node -e 'console.log(new Date(Date.now() + Number(process.argv[1])).toISOString())' -- "$1"; }   # 现在 + $1 毫秒                           # 对全部 spool 事件跑一个 jq 表达式

REPO=$T/proj; mkdir -p "$REPO"; REPO=$(cd "$REPO" && pwd -P)
( cd "$REPO" && git init -q -b main && git config user.email t@t && git config user.name t && echo init > README && git add -A && git commit -q -m init )
OTHER=$T/other; mkdir -p "$OTHER"; OTHER=$(cd "$OTHER" && pwd -P)
( cd "$OTHER" && git init -q -b main && git config user.email t@t && git config user.name t && echo x > x && git add -A && git commit -q -m init )

echo "════ 1. init 选装哪几家（照 teamai）：--agents 指定、别人的条目原样留着、重跑不改、去掉一家就删它的条目 ════"
mkdir -p "$T/codex" "$T/cursor"
printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/true","timeout":3}]}]}}' > "$T/codex/hooks.json"
printf '%s\n' '{"version":1,"hooks":{"postToolUse":[],"stop":[{"command":"./mine.sh"}]}}' > "$T/cursor/hooks.json"
out=$(vt init --agents claude,codex,cursor 2>&1)
check "init 成功" '[ $? -eq 0 ] && grep -q "采集的工具：Claude Code、Codex、Cursor" <<<"$out"'
check "config 记下 agents" 'grep -q "^agents=claude,codex,cursor$" "$VT/config"'
check "Codex：5 个事件各挂一条，Stop 是 async，别人的 Stop 条目在前面原样留着" \
  '[ "$(jq -c "[.hooks | to_entries[] | select(any(.value[].hooks[]; .command | test(\"vibetrail-hook\")))] | map(.key) | sort" "$T/codex/hooks.json")" = "[\"PermissionRequest\",\"SessionEnd\",\"SessionStart\",\"Stop\",\"UserPromptSubmit\"]" ] &&
   [ "$(jq -c ".hooks.Stop[0].hooks[0].command, .hooks.Stop[1].hooks[0].async" "$T/codex/hooks.json" | tr -d "\n")" = "\"/usr/bin/true\"true" ]'
check "Codex：SessionEnd 超时不超过 Codex 的上限 3 秒（超了设置里报加载问题，用户 09-17 截图）" '[ "$(jq ".hooks.SessionEnd[0].hooks[0].timeout" "$T/codex/hooks.json")" -le 3 ]'
check "Codex：命令带家名参数（vibetrail-hook codex <事件>）" 'jq -e ".hooks.SessionStart[0].hooks[0].command | test(\"vibetrail-hook'"'"' codex SessionStart\")" "$T/codex/hooks.json" >/dev/null'
check "Cursor：10 个事件、version 1，别人的 stop 条目与空数组都留着" \
  '[ "$(jq "[.hooks[][] | select(.command | test(\"vibetrail-hook\"))] | length" "$T/cursor/hooks.json")" = 10 ] &&
   [ "$(jq -c "[.version, .hooks.stop[0].command, (.hooks.postToolUse | length)]" "$T/cursor/hooks.json")" = "[1,\"./mine.sh\",1]" ]'
sum1=$(cksum < "$T/codex/hooks.json"); sum2=$(cksum < "$T/cursor/hooks.json")
out=$(vt init 2>&1)
check "重跑 init 沿用上次的选择、不改两份 hooks.json（Codex 的信任哈希不变）" \
  '[ "$(cksum < "$T/codex/hooks.json")" = "$sum1" ] && [ "$(cksum < "$T/cursor/hooks.json")" = "$sum2" ] && grep -q "Codex 的 hook 条目已是最新" <<<"$out"'
out=$(vt init --agents claude 2>&1)
check "去掉 Codex / Cursor：自家条目删掉，别人的留着" \
  '! grep -q vibetrail-hook "$T/codex/hooks.json" && ! grep -q vibetrail-hook "$T/cursor/hooks.json" && grep -q /usr/bin/true "$T/codex/hooks.json" && grep -q mine.sh "$T/cursor/hooks.json"'
out=$(vt init --agents codex 2>&1)
check "只选 Codex：Claude 的 settings 里不留自家条目" '! grep -q vibetrail-hook "$VIBETRAIL_CLAUDE_SETTINGS" 2>/dev/null && grep -q vibetrail-hook "$T/codex/hooks.json"'
out=$(vt init --agents foo 2>&1)
check "--agents 不认识的值报错" '[ $? -ne 0 ] || grep -q "只认" <<<"$out"'
vt init --agents claude,codex,cursor >/dev/null 2>&1
( cd "$REPO" && vt projects add >/dev/null 2>&1 )
out=$(vt doctor 2>&1)
check "doctor：报采集的工具、Codex 的 hook 还没信任" 'grep -q "采集的工具：Claude Code、Codex、Cursor" <<<"$out" && grep -q "还没在 Codex 里信任" <<<"$out"'
# 照 Codex 的算法写信任记录（codex-v3 的 doctor 核对哈希，Codex 09-17 意见 3）；$1 是故意写错哈希的那个事件
mk_trust(){ node --input-type=module -e '
import fs from "node:fs"; import { codexHookHash, codexTrustKey } from "./lib/codex.mjs";
const doc = JSON.parse(fs.readFileSync(process.env.VIBETRAIL_CODEX_HOME + "/hooks.json", "utf8"));
let out = "[hooks.state]\n";
for (const [ev, groups] of Object.entries(doc.hooks)) groups.forEach((g, gi) => (g.hooks || []).forEach((h, hi) => {
  if (!String(h.command).includes("vibetrail-hook")) return;
  out += "\n[hooks.state.\"" + codexTrustKey(ev, gi, hi) + "\"]\ntrusted_hash = \"" + (ev === process.argv[1] ? "sha256:00" : codexHookHash(ev, g, h)) + "\"\n";
}));
fs.writeFileSync(process.env.VIBETRAIL_CODEX_HOME + "/config.toml", out);' "$1"; }
mk_trust Stop; out=$(vt doctor 2>&1)
check "doctor 按哈希核信任：Stop 的记录与当前条目对不上 → 报改过；其余 4 条哈希对上，不报没信任" 'grep -q "Stop 信任之后条目改过" <<<"$out" && ! grep -q "还没在 Codex 里信任" <<<"$out"'
mk_trust ""; out=$(vt doctor 2>&1)
check "doctor：5 条哈希都对上 → 报都已信任" 'grep -q "5 条 hook 都已信任，哈希与当前条目一致" <<<"$out"'
# codex-v4 把信任检查挪进 codexTrustStatus 时删了 doctor 里的 toml，最后的 [features] 检查抛 ReferenceError，doctor 崩在 Codex 这段（09-17 装 push 前发现）；
# 上面几条只 grep 崩之前打出来的行，所以一直是绿的
check "doctor 跑到最后一行（不崩在 Codex 那段）" 'grep -q -E "采集工作正常|能用，有告警|有致命项" <<<"$out"'
printf '\n[features]\nhooks = false\n' >> "$T/codex/config.toml"; out=$(vt doctor 2>&1)
check "doctor：config.toml 里 [features] hooks = false → 报 hook 整个关着" 'grep -q "hook 整个关着" <<<"$out"'
mk_trust ""

# init 引导信任（用户 09-17 定）：不在终端里、没带参数只提示；--trust-codex-hooks 才写，只加我们的表、用户原来的内容留着；不再选 Codex 时删掉
printf '# 我的 Codex 配置\nmodel = "gpt-5"\n\n[projects."/tmp/x"]\ntrust_level = "trusted"\n' > "$T/codex/config.toml"
out=$(vt init 2>&1)
check "init 不在终端里、没带 --trust-codex-hooks：不写 config.toml，提示去设置里信任" 'grep -q "还没信任，不会跑" <<<"$out" && ! grep -q "hooks.state" "$T/codex/config.toml"'
out=$(vt init --trust-codex-hooks 2>&1)
check "init --trust-codex-hooks：只加我们的 5 张信任表，用户原来的注释与设置原样留着；doctor 按哈希核全对" \
  'grep -q "记为已信任" <<<"$out" && [ "$(grep -c "^\[hooks\.state\." "$T/codex/config.toml")" = 5 ] && grep -q "^# 我的 Codex 配置" "$T/codex/config.toml" && grep -q "^trust_level = \"trusted\"" "$T/codex/config.toml" && grep -q "5 条 hook 都已信任" <<<"$(vt doctor 2>&1)"'
sum3=$(cksum < "$T/codex/config.toml"); out=$(vt init --trust-codex-hooks 2>&1)
check "再跑一次：都已信任，config.toml 一个字节都不改" '[ "$(cksum < "$T/codex/config.toml")" = "$sum3" ] && grep -q "Codex 的 hook 都已信任" <<<"$out"'
out=$(vt init --agents claude,cursor 2>&1)
check "不再选 Codex：删掉我们的 5 张信任表与 hooks.json 里的条目，用户自己的配置留着" \
  '[ "$(grep -c "^\[hooks\.state\." "$T/codex/config.toml")" = 0 ] && grep -q "^# 我的 Codex 配置" "$T/codex/config.toml" && ! grep -q vibetrail-hook "$T/codex/hooks.json"'
vt init --agents claude,codex,cursor >/dev/null 2>&1

echo "════ 2. Codex：未登记的仓零写入 ════"
SID0=019a0000-0000-7000-8000-00000000aaaa
hook codex SessionStart "$(jq -n -c --arg cwd "$OTHER" --arg sid "$SID0" '{session_id: $sid, cwd: $cwd, transcript_path: "", hook_event_name: "SessionStart", model: "gpt-5-codex", source: "startup"}')"
check "未登记的仓：没有 state、没有 spool" '[ ! -d "$VT/state/$SID0" ] && [ -z "$(spool)" ]'

echo "════ 3. Codex：一整段会话（轮中提交、apply_patch、子 agent、人拒绝、插话、打断、没有证据的拒绝、会话结束） ════"
SID=019a0000-0000-7000-8000-000000000001; CHILD=019a0000-0000-7000-8000-000000000002
DAY=$T/codex/sessions/2026/09/17; mkdir -p "$DAY"
R=$DAY/rollout-2026-09-17T10-00-00-$SID.jsonl; RC=$DAY/rollout-2026-09-17T10-00-05-$CHILD.jsonl
add(){ printf '%s\n' "$1" >> "$R"; }
P(){ jq -n -c --arg sid "$SID" --arg tp "$R" --arg cwd "$REPO" "{session_id: \$sid, transcript_path: \$tp, cwd: \$cwd, model: \"gpt-5-codex\", permission_mode: \"default\"} + $1"; }
add "$(jq -n -c --arg sid "$SID" --arg cwd "$REPO" '{timestamp: "2026-09-17T02:00:00.000Z", type: "session_meta", payload: {id: $sid, session_id: $sid, cwd: $cwd, originator: "codex_cli_rs", cli_version: "0.154.0", source: "cli", history_mode: "paginated", base_instructions: "You are Codex."}}')"
hook codex SessionStart "$(P '{hook_event_name: "SessionStart", source: "startup"}')"
# 第 1 轮
hook codex UserPromptSubmit "$(P '{hook_event_name: "UserPromptSubmit", turn_id: "t1", prompt: "加一个 a.txt"}')"
add '{"timestamp":"2026-09-17T02:00:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1","started_at":1}}'
add "$(jq -n -c --arg cwd "$REPO" '{timestamp: "2026-09-17T02:00:01.100Z", type: "turn_context", payload: {turn_id: "t1", cwd: $cwd, model: "gpt-5-codex", approval_policy: "on-request"}}')"
add '{"timestamp":"2026-09-17T02:00:01.200Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>注入的，不是人话</environment_context>"}]}}'
add '{"timestamp":"2026-09-17T02:00:01.300Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"t1","item":{"type":"UserMessage","id":"u1","content":[{"type":"text","text":"加一个 a.txt"}]}}}'
add '{"timestamp":"2026-09-17T02:00:02.000Z","type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"先看看目录"}]}}'
add '{"timestamp":"2026-09-17T02:00:02.100Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"ls\"]}","call_id":"call_1"}}'
add '{"timestamp":"2026-09-17T02:00:02.200Z","type":"token_usage_record","payload":{"turn_id":"t1","response_id":"resp_1","usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50,"reasoning_output_tokens":20,"total_tokens":1050},"turn_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50,"reasoning_output_tokens":20}}}'
add '{"timestamp":"2026-09-17T02:00:02.700Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"README"}}'
add '{"timestamp":"2026-09-17T02:00:03.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","call_id":"call_2","input":"*** Begin Patch\n*** Add File: a.txt\n+hi\n*** End Patch"}}'
add '{"timestamp":"2026-09-17T02:00:03.200Z","type":"token_usage_record","payload":{"turn_id":"t1","response_id":"resp_2","usage":{"input_tokens":1200,"cached_input_tokens":1000,"output_tokens":30,"reasoning_output_tokens":0},"turn_token_usage":{"input_tokens":2200,"cached_input_tokens":1800,"output_tokens":80,"reasoning_output_tokens":20}}}'
add '{"timestamp":"2026-09-17T02:00:03.500Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_2","output":{"content":"Success. Updated the following files:\nA a.txt","success":true}}}'
add '{"timestamp":"2026-09-17T02:00:03.600Z","type":"response_item","payload":{"type":"function_call","name":"spawn_agent","arguments":"{\"task_name\":\"explorer\",\"message\":\"看看 a.txt 写对没有\"}","call_id":"call_s1"}}'
add '{"timestamp":"2026-09-17T02:00:03.700Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_s1","output":"{\"task_name\":\"/root/explorer\"}"}}'
add '{"timestamp":"2026-09-17T02:00:03.800Z","type":"response_item","payload":{"type":"web_search_call","id":"ws_1","status":"completed","action":{"type":"search","query":"codex hooks"}}}'
# 子 agent：独立 rollout，source 指回父线程，root_turn_id 是父会话这一轮
printf '%s\n' "$(jq -n -c --arg id "$CHILD" --arg sid "$SID" --arg cwd "$REPO" '{timestamp: "2026-09-17T02:00:04.000Z", type: "session_meta", payload: {id: $id, cwd: $cwd, originator: "codex_cli_rs", cli_version: "0.154.0", history_mode: "paginated", source: {subagent: {thread_spawn: {parent_thread_id: $sid, depth: 1, agent_role: "explorer", agent_path: "/root/explorer"}}}}}')" > "$RC"
# 桌面版多 agent 的子 agent 文件：自己的 session_meta 后面抄了一份父会话的 meta 与历史（Pilot 夹具的结构），这些不能再发一遍（codex-v4）
printf '%s\n' "$(jq -n -c --arg sid "$SID" --arg cwd "$REPO" '{timestamp: "2026-09-17T02:00:00.000Z", type: "session_meta", payload: {id: $sid, cwd: $cwd, originator: "codex_cli_rs", cli_version: "0.154.0", history_mode: "paginated", source: "cli", base_instructions: "You are Codex."}}')" >> "$RC"
for l in '{"timestamp":"2026-09-17T02:00:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}' \
         '{"timestamp":"2026-09-17T02:00:01.300Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"t1","item":{"type":"UserMessage","id":"u1","content":[{"type":"text","text":"加一个 a.txt"}]}}}' \
         '{"timestamp":"2026-09-17T02:00:02.100Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"ls\"]}","call_id":"call_1"}}' \
         '{"timestamp":"2026-09-17T02:00:02.200Z","type":"token_usage_record","payload":{"turn_id":"t1","response_id":"resp_1","usage":{"input_tokens":1000,"output_tokens":50}}}' \
         '{"timestamp":"2026-09-17T02:00:02.700Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"README"}}'; do printf '%s\n' "$l" >> "$RC"; done
for l in '{"timestamp":"2026-09-17T02:00:04.100Z","type":"event_msg","payload":{"type":"task_started","turn_id":"c1"}}' \
         '{"timestamp":"2026-09-17T02:00:04.200Z","type":"turn_context","payload":{"turn_id":"c1","root_turn_id":"t1","model":"gpt-5-codex-mini"}}' \
         '{"timestamp":"2026-09-17T02:00:04.300Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"c1","item":{"type":"UserMessage","id":"cu1","content":[{"type":"text","text":"看看 a.txt 写对没有"}]}}}' \
         '{"timestamp":"2026-09-17T02:00:04.400Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"写对了"}]}}' \
         '{"timestamp":"2026-09-17T02:00:04.500Z","type":"token_usage_record","payload":{"turn_id":"c1","response_id":"resp_c1","usage":{"input_tokens":300,"output_tokens":10}}}' \
         '{"timestamp":"2026-09-17T02:00:04.600Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"c1","last_agent_message":"写对了"}}'; do printf '%s\n' "$l" >> "$RC"; done
( cd "$REPO" && echo hi > a.txt && git add -A && git commit -q -m "add a.txt" )
add '{"timestamp":"2026-09-17T02:00:05.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"加好了"}]}}'
add '{"timestamp":"2026-09-17T02:00:05.100Z","type":"token_usage_record","payload":{"turn_id":"t1","response_id":"resp_3","usage":{"input_tokens":1300,"cached_input_tokens":1200,"output_tokens":10},"turn_token_usage":{"input_tokens":3500,"cached_input_tokens":3000,"output_tokens":90,"reasoning_output_tokens":20}}}'
add '{"timestamp":"2026-09-17T02:00:05.200Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"加好了","duration_ms":4200}}'
hook codex Stop "$(P '{hook_event_name: "Stop", turn_id: "t1", stop_hook_active: false, last_assistant_message: "加好了"}')"
T1END=$(q 'map(select(.type == "turn.end" and .turn_id == "t1"))')
check "t1：turn.start 是 hook 发的、带轮起 HEAD" '[ "$(q "map(select(.type == \"turn.start\" and .turn_id == \"t1\")) | map([.provenance.kind, (.payload.vcs.head_sha | length)])")" = "[[\"hook\",40]]" ]'
check "t1：turn.end completed，用量取 turn_token_usage（input 含缓存、total = input + output）" \
  '[ "$(jq -c "map([.payload.status.code, .payload.usage.input_tokens, .payload.usage.cached_input_tokens, .payload.usage.total_tokens, .payload.model])" <<<"$T1END")" = "[[\"completed\",3500,3000,3590,\"gpt-5-codex\"]]" ]'
check "t1：轮中那次提交进 commits，apply_patch 新建的 a.txt 进 files（evidence tool_result）" \
  '[ "$(jq -c "map([(.commits | length), .files])" <<<"$T1END")" = "[[1,[{\"path\":\"a.txt\",\"operation\":\"create\",\"evidence\":\"tool_result\"}]]]" ]'
check "t1：三次模型响应各一条 message.assistant，带用量与调了哪些工具；reasoning 进 extensions 不当正文" \
  '[ "$(q "map(select(.type == \"message.assistant\" and .turn_id == \"t1\" and .agent_instance_id == \"main\")) | map([.extensions[\"vibetrail.call\"].usage.input_tokens, .extensions[\"vibetrail.call\"].tool_calls, (.payload.text // null), (.extensions[\"vibetrail.reasoning\"] // null)])")" = "[[1000,[\"shell\"],null,\"先看看目录\"],[1200,[\"apply_patch\"],null,null],[1300,[\"spawn_agent\",\"web_search\"],\"加好了\",null]]" ]'
check "t1：人话只认 UserMessage（注入的 environment_context 不算），delivery direct" \
  '[ "$(q "map(select(.type == \"message.user\" and .agent_instance_id == \"main\" and .turn_id == \"t1\")) | map([.payload.author_type, .payload.delivery, .payload.text])")" = "[[\"human\",\"direct\",\"加一个 a.txt\"]]" ]'
check "web_search_call 没有单独的结果记录：照发 tool.end succeeded，不编耗时（codex-v4）" '[ "$(q "map(select(.type == \"tool.end\" and .payload.call_id == \"ws_1\")) | map([.payload.tool_name, .payload.status.code, (.payload.duration_ms // null)])")" = "[[\"web_search\",\"succeeded\",null]]" ]'
check "t1：四次工具调用（含 spawn_agent 与 web_search_call）各一条 tool.request（全采带参数）与 tool.end（succeeded）" \
  '[ "$(q "[(map(select(.type == \"tool.request\" and .turn_id == \"t1\")) | length), (map(select(.type == \"tool.end\" and .turn_id == \"t1\" and .agent_instance_id == \"main\")) | map(.payload.status.code))]")" = "[4,[\"succeeded\",\"succeeded\",\"succeeded\",\"succeeded\"]]" ]'
check "子 agent：挂父会话、父实例 main、轮次 t1、类型取 agent_role、派活 injected；parent_call_id 按 agent_path 对上 spawn_agent 调用；抄来的父会话历史一条不发（codex-v4）" \
  '[ "$(q "map(select(.agent_instance_id == \"'"$CHILD"'\")) | map([.type, .session_id == \"'"$SID"'\", .parent_agent_instance_id, .turn_id, (.parent_call_id // null), (.payload.agent_type // .payload.delivery // .payload.author_type)])")" = "[[\"subagent.start\",true,\"main\",\"t1\",\"call_s1\",\"explorer\"],[\"message.user\",true,\"main\",\"t1\",\"call_s1\",\"injected\"],[\"message.assistant\",true,\"main\",\"t1\",\"call_s1\",\"agent\"],[\"subagent.end\",true,\"main\",\"t1\",\"call_s1\",\"explorer\"]]" ]'
check "system prompt：ext.codex.base_instructions 一条，带 sha256 与正文" \
  '[ "$(q "map(select(.type == \"ext.codex.base_instructions\" and .agent_instance_id == \"main\")) | map([.provenance.source_event, (.payload.sha256 | length), .extensions[\"codex.base_instructions\"]])")" = "[[\"session_meta\",64,\"You are Codex.\"]]" ]'
n1=$(spool | wc -l | tr -d ' ')
hook codex Stop "$(P '{hook_event_name: "Stop", turn_id: "t1", stop_hook_active: false}')"
check "同一个 Stop 再来一次：不多写一条" '[ "$(spool | wc -l | tr -d " ")" = "$n1" ]'

# 第 2 轮：人拒绝（弹过审批框 + 输出 rejected by user）→ 插话 → 按停止打断
hook codex UserPromptSubmit "$(P '{hook_event_name: "UserPromptSubmit", turn_id: "t2", prompt: "删掉 README"}')"
add '{"timestamp":"2026-09-17T02:00:59.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"两轮之间的孤儿回复"}]}}'
add '{"timestamp":"2026-09-17T02:01:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t2"}}'
add '{"timestamp":"2026-09-17T02:01:00.100Z","type":"turn_context","payload":{"turn_id":"t2","model":"gpt-5-codex","approval_policy":"on-request"}}'
add '{"timestamp":"2026-09-17T02:01:00.200Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"t2","item":{"type":"UserMessage","id":"u2","content":[{"type":"text","text":"删掉 README"}]}}}'
add "$(jq -n -c --arg ts "$(TS -1000)" '{timestamp: $ts, type: "response_item", payload: {type: "function_call", name: "shell", arguments: "{\"command\":[\"rm\",\"README\"]}", call_id: "call_3"}}')"
hook codex PermissionRequest "$(P '{hook_event_name: "PermissionRequest", turn_id: "t2", tool_name: "Bash", tool_input: {command: "rm README"}}')"
add "$(jq -n -c --arg ts "$(TS 1000)" '{timestamp: $ts, type: "response_item", payload: {type: "function_call_output", call_id: "call_3", output: "exec command rejected by user"}}')"
add '{"timestamp":"2026-09-17T02:01:04.000Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"t2","item":{"type":"UserMessage","id":"u3","content":[{"type":"text","text":"别删，改名成 README.bak"}]}}}'
add '{"timestamp":"2026-09-17T02:01:05.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"sleep\",\"100\"]}","call_id":"call_4"}}'
add '{"timestamp":"2026-09-17T02:01:06.000Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t2","reason":"interrupted"}}'
# 第 3 轮：没有弹框证据的拒绝（不判人拒）
hook codex UserPromptSubmit "$(P '{hook_event_name: "UserPromptSubmit", turn_id: "t3", prompt: "改名"}')"
check "UserPromptSubmit 时顺带补读（codex-v6）：上一轮按停止打断、没有 Stop，下一句话一提交它的 turn.end 就写出来，不等下一次 Stop" '[ "$(q "map(select(.type == \"turn.end\" and .turn_id == \"t2\")) | map(.payload.status.code)")" = "[\"interrupted\"]" ]'
add '{"timestamp":"2026-09-17T02:02:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t3"}}'
add '{"timestamp":"2026-09-17T02:02:00.100Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"t3","item":{"type":"UserMessage","id":"u4","content":[{"type":"text","text":"改名"}]}}}'
add '{"timestamp":"2026-09-17T02:02:01.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","call_id":"call_5","input":"*** Begin Patch\n*** Delete File: README\n*** End Patch"}}'
add '{"timestamp":"2026-09-17T02:02:02.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_5","output":{"content":"patch rejected by user","success":false}}}'
# 09-17 桌面版实测的误判：读源码的输出里夹着拒绝的字样，不是拒绝（codex-v2 只认整条输出）
add '{"timestamp":"2026-09-17T02:02:02.500Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"call_6","input":"sed -n 1,20p tools/lib/codex.mjs"}}'
add '{"timestamp":"2026-09-17T02:02:02.600Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_6","output":"Script completed\nOutput:\n// 输出是 exec command rejected by user 时算拒绝\nwriting outside of the project; rejected by user approval settings"}}'
add '{"timestamp":"2026-09-17T02:02:03.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t3"}}'
hook codex Stop "$(P '{hook_event_name: "Stop", turn_id: "t3", stop_hook_active: false}')"
check "t2：人拒绝发 permission.decision（decided_by user、is_divergence、证据两条），被拒的调用不发 tool.end" \
  '[ "$(q "[(map(select(.type == \"permission.decision\" and .payload.call_id == \"call_3\")) | map([.payload.decided_by, .is_divergence, .extensions[\"vibetrail.denial_evidence\"]])), (map(select(.type == \"tool.end\" and .payload.call_id == \"call_3\")) | length)]")" = "[[[\"user\",true,[\"output_text\",\"permission_request_in_window\"]]],0]" ]'
check "t2：轮中插的第二句人话是 queued" '[ "$(q "map(select(.type == \"message.user\" and .turn_id == \"t2\")) | map(.payload.delivery)")" = "[\"direct\",\"queued\"]" ]'
check "t2：打断 → turn.end interrupted + is_divergence，vcs 取下一轮开始时补的快照；跑着的调用补 tool.end(cancelled)" \
  '[ "$(q "[(map(select(.type == \"turn.end\" and .turn_id == \"t2\")) | map([.payload.status.code, .payload.status.category, .is_divergence, (.payload.vcs.head_sha | length)])), (map(select(.type == \"tool.end\" and .payload.call_id == \"call_4\")) | map(.payload.status.code))]")" = "[[[\"interrupted\",\"cancellation\",true,40]],[\"cancelled\"]]" ]'
check "t3：没有弹框证据的拒绝 decided_by unknown、不标分歧；拒掉的补丁不进 files" \
  '[ "$(q "[(map(select(.type == \"permission.decision\" and .payload.call_id == \"call_5\")) | map([.payload.decided_by, (.is_divergence // false)])), (map(select(.type == \"turn.end\" and .turn_id == \"t3\")) | map(.files // null))]")" = "[[[\"unknown\",false]],[null]]" ]'
check "输出里夹着拒绝字样的成功调用（读源码）不算拒绝：照发 tool.end succeeded，不发 permission.decision" '[ "$(q "[(map(select(.type == \"tool.end\" and .payload.call_id == \"call_6\")) | map(.payload.status.code)), (map(select(.type == \"permission.decision\" and .payload.call_id == \"call_6\")) | length)]")" = "[[\"succeeded\"],0]" ]'
check "PermissionRequest 发 ext.codex.permission_request（不带参数）" '[ "$(q "map(select(.type == \"ext.codex.permission_request\")) | map([.turn_id, .payload.tool_name, (.payload.tool_input // null)])")" = "[[\"t2\",\"Bash\",null]]" ]'
# 第 4 轮（codex-v3）：弹框证据要落在「调用发出 → 结果回来」之间，一次弹框只配一次拒绝
hook codex UserPromptSubmit "$(P '{hook_event_name: "UserPromptSubmit", turn_id: "t4", prompt: "再删一次"}')"
add '{"timestamp":"2026-09-17T02:03:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t4"}}'
add '{"timestamp":"2026-09-17T02:03:00.100Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"t4","item":{"type":"UserMessage","id":"u5","content":[{"type":"text","text":"再删一次"}]}}}'
C7=$(TS -1000); C8=$(TS -500)
hook codex PermissionRequest "$(P '{hook_event_name: "PermissionRequest", turn_id: "t4", tool_name: "Bash", tool_input: {command: "rm README"}}')"
O7=$(TS 1000); O8=$(TS 1500); C9=$(TS 60000); O9=$(TS 61000)
for x in "call_7 $C7 $O7" "call_8 $C8 $O8" "call_9 $C9 $O9"; do set -- $x
  add "$(jq -n -c --arg id "$1" --arg ts "$2" '{timestamp: $ts, type: "response_item", payload: {type: "function_call", name: "shell", arguments: "{\"command\":[\"rm\",\"README\"]}", call_id: $id}}')"
  add "$(jq -n -c --arg id "$1" --arg ts "$3" '{timestamp: $ts, type: "response_item", payload: {type: "function_call_output", call_id: $id, output: "exec command rejected by user"}}')"
done
add '{"timestamp":"2026-09-17T02:03:09.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t4"}}'
hook codex Stop "$(P '{hook_event_name: "Stop", turn_id: "t4", stop_hook_active: false}')"
check "t4：一次弹框只配窗口内最早那次拒绝（call_7 人拒）；同一弹框不再配给 call_8；窗口外的 call_9 不算人拒" \
  '[ "$(q "map(select(.type == \"permission.decision\" and .turn_id == \"t4\")) | sort_by(.payload.call_id) | map([.payload.call_id, .payload.decided_by, (.is_divergence // false)])")" = "[[\"call_7\",\"user\",true],[\"call_8\",\"unknown\",false],[\"call_9\",\"unknown\",false]]" ]'
# 第 5 轮（codex-v5）：自动审批（approvals_reviewer = auto_review）下，弹框证据落在窗口里也不判人拒——审批先交给 guardian 模型审
hook codex UserPromptSubmit "$(P '{hook_event_name: "UserPromptSubmit", turn_id: "t5", prompt: "自动审批下再删一次"}')"
add '{"timestamp":"2026-09-17T02:04:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t5"}}'
add '{"timestamp":"2026-09-17T02:04:00.050Z","type":"turn_context","payload":{"turn_id":"t5","model":"gpt-5-codex","approval_policy":"on-request","approvals_reviewer":"auto_review"}}'
add '{"timestamp":"2026-09-17T02:04:00.100Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"t5","item":{"type":"UserMessage","id":"u6","content":[{"type":"text","text":"自动审批下再删一次"}]}}}'
C10=$(TS -1000)
hook codex PermissionRequest "$(P '{hook_event_name: "PermissionRequest", turn_id: "t5", tool_name: "Bash", tool_input: {command: "rm README"}}')"
O10=$(TS 1000)
add "$(jq -n -c --arg ts "$C10" '{timestamp: $ts, type: "response_item", payload: {type: "function_call", name: "shell", arguments: "{\"command\":[\"rm\",\"README\"]}", call_id: "call_10"}}')"
add "$(jq -n -c --arg ts "$O10" '{timestamp: $ts, type: "response_item", payload: {type: "function_call_output", call_id: "call_10", output: "exec command rejected by user"}}')"
add '{"timestamp":"2026-09-17T02:04:09.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t5"}}'
hook codex Stop "$(P '{hook_event_name: "Stop", turn_id: "t5", stop_hook_active: false}')"
check "t5：自动审批下弹框证据在窗口里也不判人拒（decided_by unknown、不标分歧），记下 approvals_reviewer（codex-v5）" \
  '[ "$(q "map(select(.type == \"permission.decision\" and .payload.call_id == \"call_10\")) | map([.payload.decided_by, (.is_divergence // false), .extensions[\"codex.approvals_reviewer\"]])")" = "[[\"unknown\",false,\"auto_review\"]]" ]'
# guardian 自动审批线程自己的 hook（若会触发）：不当成独立会话采（codex-v5）
GSID=019a0000-0000-7000-8000-00000000abcd; RG=$DAY/rollout-2026-09-17T10-04-00-$GSID.jsonl
printf '%s\n' "$(jq -n -c --arg id "$GSID" --arg cwd "$REPO" '{timestamp: "2026-09-17T02:04:00.500Z", type: "session_meta", payload: {id: $id, cwd: $cwd, originator: "Codex Desktop", cli_version: "0.154.0", history_mode: "paginated", thread_source: "guardian_review", source: {subagent: {other: "guardian"}}}}')" > "$RG"
for ev in SessionStart UserPromptSubmit Stop; do hook codex $ev "$(jq -n -c --arg sid "$GSID" --arg tp "$RG" --arg cwd "$REPO" --arg ev "$ev" '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: $ev, turn_id: "g1", source: "startup"}')"; done
check "guardian 自动审批线程自己的 hook：不建 state、不写 spool（codex-v5）" '[ ! -d "$VT/state/$GSID" ] && [ -z "$(cat "$VT"/spool/*/"$GSID"/*.jsonl 2>/dev/null)" ]'
hook codex SessionEnd "$(jq -n -c --arg sid "$SID" --arg tp "$R" --arg cwd "$REPO" '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionEnd", reason: "other"}')"
check "会话：session.start / session.end 各一条，agent 是 codex 0.154.0、surface cli" \
  '[ "$(q "map(select(.type | test(\"^session\\\\.\"))) | map([.type, .agent.name, .agent.version, .agent.surface])")" = "[[\"session.start\",\"codex\",\"0.154.0\",\"cli\"],[\"session.end\",\"codex\",\"0.154.0\",\"cli\"]]" ]'
check "轮次成对：五轮 turn.start / turn.end 各五条" '[ "$(q "[(map(select(.type == \"turn.start\")) | length), (map(select(.type == \"turn.end\")) | length)]")" = "[5,5]" ]'
check "event_id 不重复" '[ "$(q "map(.event_id) | (length == (unique | length))")" = true ]'
check "Codex 的全部事件过协议 1.0 schema" 'spool | schema_ok'
check "两轮之间才到的回复不挂到已经结束的轮上：不发，计数 1（codex-v3）" '[ "$(q "map(select(.type == \"message.assistant\" and ((.payload.text // \"\") | test(\"孤儿\")))) | length")" = 0 ] && [ "$(jq .orphan_items "$VT/state/$SID/codex-main.json")" = 1 ]'
check "state 里记了 rollout 的消费进度，没有还开着的轮" '[ "$(jq -c "[.consumed_bytes == $(wc -c < "$R" | tr -d " "), .open_turn]" "$VT/state/$SID/codex-main.json")" = "[true,null]" ]'

echo "════ 3b. U18 同款：从没读过的 rollout 第一次只读补采窗口内的记录；分段读完（每段 200 字节也不丢不重） ════"
SIDB=019a0000-0000-7000-8000-00000000bbbb; RB=$DAY/rollout-2026-09-01T10-00-00-$SIDB.jsonl
OLD=$(node -e 'console.log(new Date(Date.now() - 10 * 86400000).toISOString())'); NEW=$(node -e 'console.log(new Date(Date.now() - 3600000).toISOString())')
for l in "{\"timestamp\":\"$OLD\",\"type\":\"session_meta\",\"payload\":{\"id\":\"$SIDB\",\"cwd\":\"$REPO\",\"originator\":\"codex_cli_rs\",\"cli_version\":\"0.154.0\",\"history_mode\":\"paginated\"}}" \
         "{\"timestamp\":\"$OLD\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"old1\"}}" \
         "{\"timestamp\":\"$OLD\",\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"turn_id\":\"old1\",\"item\":{\"type\":\"UserMessage\",\"id\":\"o1\",\"content\":[{\"type\":\"text\",\"text\":\"十天前的一句话，第一次读时不补\"}]}}}" \
         "{\"timestamp\":\"$OLD\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"old1\"}}" \
         "{\"timestamp\":\"$NEW\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"new1\"}}" \
         "{\"timestamp\":\"$NEW\",\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"turn_id\":\"new1\",\"item\":{\"type\":\"UserMessage\",\"id\":\"n1\",\"content\":[{\"type\":\"text\",\"text\":\"一小时前的一句话，要读\"}]}}}" \
         "{\"timestamp\":\"$NEW\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"new1\"}}"; do printf '%s\n' "$l" >> "$RB"; done
VIBETRAIL_BACKFILL_DAYS=2 VIBETRAIL_READ_MAX_BYTES=200 hook codex Stop "$(jq -n -c --arg sid "$SIDB" --arg tp "$RB" --arg cwd "$REPO" '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "Stop", turn_id: "new1"}')"
check "第一次读：十天前那一轮不补，一小时前那一轮读到（turn.start / message.user / turn.end 各一条）" \
  '[ "$(q "map(select(.session_id == \"'"$SIDB"'\")) | map([.type, .turn_id])")" = "[[\"turn.start\",\"new1\"],[\"message.user\",\"new1\"],[\"turn.end\",\"new1\"]]" ]'
check "state 记了跳过的老字节数，分段读到了文件末尾" '[ "$(jq -c "[(.skipped_old_bytes > 0), (.consumed_bytes == $(wc -c < "$RB" | tr -d " "))]" "$VT/state/$SIDB/codex-main.json")" = "[true,true]" ]'

echo "════ 3c. fork 出来的会话：开头抄了父会话的历史（forked_from_id），只发自己的轮（codex-v4，照 Pilot 按 turn id 的 UUIDv7 时刻判） ════"
U7(){ node -e 'const h=Number(process.argv[1]).toString(16).padStart(12,"0");console.log(h.slice(0,8)+"-"+h.slice(8,12)+"-7abc-8def-0123456789ab")' -- "$1"; }
FORK=019a0000-0000-7000-8000-00000000f0f0; RF=$DAY/rollout-2026-09-17T11-00-00-$FORK.jsonl
T0=$(node -e 'console.log(Date.parse("2026-09-17T03:00:00.000Z"))'); OLDT=$(U7 $((T0 - 60000))); NEWT=$(U7 $((T0 + 30000)))
{ jq -n -c --arg id "$FORK" --arg sid "$SID" --arg cwd "$REPO" '{timestamp: "2026-09-17T03:00:00.000Z", type: "session_meta", payload: {id: $id, forked_from_id: $sid, cwd: $cwd, originator: "codex_cli_rs", cli_version: "0.154.0", history_mode: "paginated", source: "cli"}}'
  jq -n -c --arg sid "$SID" --arg cwd "$REPO" '{timestamp: "2026-09-17T02:00:00.000Z", type: "session_meta", payload: {id: $sid, cwd: $cwd, originator: "codex_cli_rs", cli_version: "0.154.0", history_mode: "paginated", source: "cli"}}'
  for tid in "$OLDT" "$NEWT"; do   # 两轮的记录时间一样，只有 turn id 里的时刻不同：钉的是「按 UUIDv7 时刻判」
    jq -n -c --arg t "$tid" '{timestamp: "2026-09-17T03:00:31.000Z", type: "event_msg", payload: {type: "task_started", turn_id: $t}}'
    jq -n -c --arg t "$tid" '{timestamp: "2026-09-17T03:00:31.100Z", type: "event_msg", payload: {type: "item_completed", turn_id: $t, item: {type: "UserMessage", id: ("u-" + $t), content: [{type: "text", text: ("这一轮是 " + $t)}]}}}'
    jq -n -c --arg t "$tid" '{timestamp: "2026-09-17T03:00:32.000Z", type: "event_msg", payload: {type: "task_complete", turn_id: $t}}'
  done; } > "$RF"
hook codex Stop "$(jq -n -c --arg sid "$FORK" --arg tp "$RF" --arg cwd "$REPO" --arg t "$NEWT" '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "Stop", turn_id: $t}')"
check "fork：抄来的父会话那一轮（turn id 的时刻早于自己的 session_meta）不发，只发自己的那一轮" \
  '[ "$(q "map(select(.session_id == \"$FORK\")) | map([.type, .turn_id])")" = "[[\"turn.start\",\"$NEWT\"],[\"message.user\",\"$NEWT\"],[\"turn.end\",\"$NEWT\"]]" ]'

echo "════ 4. Cursor：只用 hook 入参；应答、会话 / 轮次 / 工具 / 子 agent / 文件 / commit；不带邮箱 ════"
CONV=cccccccc-0000-4000-8000-000000000001
C(){ jq -n -c --arg conv "$CONV" --arg root "$REPO" "{conversation_id: \$conv, cursor_version: \"3.20.21\", workspace_roots: [\$root], user_email: \"someone@example.com\", model: \"claude-4.5-sonnet\", transcript_path: null} + $1"; }
before=$(spool | wc -l | tr -d ' ')
r=$(hook cursor sessionStart "$(C '{hook_event_name: "sessionStart", session_id: "cccccccc-0000-4000-8000-000000000001", composer_mode: "agent"}')")
check "sessionStart 应答是空对象" '[ "$r" = "{}" ]'
r=$(hook cursor beforeSubmitPrompt "$(C '{hook_event_name: "beforeSubmitPrompt", generation_id: "g1", prompt: "加 b.txt", attachments: []}')")
check "beforeSubmitPrompt 应答放行（continue: true）" '[ "$r" = "{\"continue\":true}" ]'
hook cursor afterAgentResponse "$(C '{hook_event_name: "afterAgentResponse", generation_id: "g1", text: "好的", input_tokens: 10, output_tokens: 5, cache_read_tokens: 3}')" >/dev/null
hook cursor postToolUse "$(jq -n -c --arg root "$REPO" '{tool_name: "Shell", tool_input: {command: "ls"}, tool_output: "README", tool_use_id: "tu1", duration_ms: 12, cwd: $root}' | jq -c --argjson base "$(C '{hook_event_name: "postToolUse", generation_id: "g1"}')" '$base + .')" >/dev/null
hook cursor postToolUseFailure "$(C '{hook_event_name: "postToolUseFailure", generation_id: "g1", tool_name: "Shell", tool_input: {command: "sleep 100"}, tool_use_id: "tu2", error_message: "stopped", failure_type: "unknown", is_interrupt: true, duration_ms: 900}')" >/dev/null
hook cursor afterFileEdit "$(jq -n -c --arg f "$REPO/b.txt" --argjson base "$(C '{hook_event_name: "afterFileEdit", generation_id: "g1"}')" '$base + {file_path: $f, edits: []}')" >/dev/null
hook cursor afterFileEdit "$(C '{hook_event_name: "afterFileEdit", generation_id: "g1", file_path: "/etc/hosts", edits: []}')" >/dev/null
hook cursor subagentStart "$(C '{hook_event_name: "subagentStart", generation_id: "g1", subagent_id: "sub-1", subagent_type: "explore", task: "查 b.txt 的引用", parent_conversation_id: "cccccccc-0000-4000-8000-000000000001", tool_call_id: "tu3"}')" >/dev/null
hook cursor subagentStop "$(jq -n -c --arg f "$REPO/c.txt" --argjson base "$(C '{hook_event_name: "subagentStop", generation_id: "g1", subagent_id: "sub-1", subagent_type: "explore", status: "completed", summary: "没有引用", duration_ms: 3000}')" '$base + {modified_files: [$f]}')" >/dev/null
( cd "$REPO" && echo b > b.txt && git add -A && git commit -q -m "add b.txt" )
r=$(hook cursor stop "$(C '{hook_event_name: "stop", generation_id: "g1", status: "completed", loop_count: 0, input_tokens: 40, output_tokens: 20}')")
hook cursor beforeSubmitPrompt "$(C '{hook_event_name: "beforeSubmitPrompt", generation_id: "g2", prompt: "再来"}')" >/dev/null
hook cursor sessionEnd "$(C '{hook_event_name: "sessionEnd", session_id: "cccccccc-0000-4000-8000-000000000001", reason: "window_closed", final_status: "completed", duration_ms: 60000}')" >/dev/null
CQ(){ spool | jq -s -c "map(select(.agent.name == \"cursor\")) | $1"; }
check "stop 应答是空对象" '[ "$r" = "{}" ]'
check "g1：turn.start 带轮起 HEAD；人话 direct；回复带原样的 token 数（口径没核，不填 payload.usage）" \
  '[ "$(CQ "[(map(select(.type == \"turn.start\" and .turn_id == \"g1\")) | map(.payload.vcs.head_sha | length)), (map(select(.type == \"message.user\" and .turn_id == \"g1\")) | map([.payload.delivery, .payload.text])), (map(select(.type == \"message.assistant\")) | map([.payload.text, .extensions[\"vibetrail.call\"].usage_raw.input_tokens]))]")" = "[[40],[[\"direct\",\"加 b.txt\"]],[[\"好的\",10]]]" ]'
check "工具：tu1 succeeded（耗时 12，带参数与输出），tu2 按停止打断 → cancelled" \
  '[ "$(CQ "map(select(.type == \"tool.end\")) | map([.payload.call_id, .payload.status.code, (.payload.duration_ms // null)])")" = "[[\"tu1\",\"succeeded\",12],[\"tu2\",\"cancelled\",900]]" ] && [ "$(CQ "map(select(.type == \"tool.request\")) | length")" = 2 ]'
check "子 agent：实例 sub-1、父实例 main、派它的调用 tu3、轮次 g1；结束带 modified_files" \
  '[ "$(CQ "map(select(.type | test(\"^subagent\"))) | map([.type, .agent_instance_id, .parent_agent_instance_id, (.parent_call_id // null), .turn_id, .payload.status.code, (.files // null)])")" = "[[\"subagent.start\",\"sub-1\",\"main\",\"tu3\",\"g1\",null,null],[\"subagent.end\",\"sub-1\",\"main\",null,\"g1\",\"completed\",[{\"path\":\"c.txt\",\"operation\":\"modify\",\"evidence\":\"hook\"}]]]" ]'
check "g1：turn.end completed，commits 1 条，files 只有仓内的 b.txt（/etc/hosts 在根外不记），原样 token 放 extensions" \
  '[ "$(CQ "map(select(.type == \"turn.end\" and .turn_id == \"g1\")) | map([.payload.status.code, (.commits | length), .files, .extensions[\"cursor.usage_raw\"].output_tokens])")" = "[[\"completed\",1,[{\"path\":\"b.txt\",\"operation\":\"modify\",\"evidence\":\"hook\"}],20]]" ]'
check "g2 没等到 stop：会话结束时按 unknown 关（inferred）；session.end completed" \
  '[ "$(CQ "[(map(select(.type == \"turn.end\" and .turn_id == \"g2\")) | map([.payload.status.code, .provenance.kind])), (map(select(.type == \"session.end\")) | map(.payload.status.code))]")" = "[[[\"unknown\",\"inferred\"]],[\"completed\"]]" ]'
check "邮箱不出本机（spool 与 state 里都没有 user_email）" '! grep -rq "someone@example.com" "$VT/spool" "$VT/state"'
check "Cursor 的全部事件过协议 1.0 schema" 'spool | jq -c "select(.agent.name == \"cursor\")" | schema_ok'

echo "════ 5. 卸载：两份 hooks.json 只去掉自家条目；测试没动真实配置 ════"
vt uninstall >/dev/null 2>&1
check "uninstall 后两份 hooks.json 里没有 vibetrail 的条目，别人的还在" \
  '! grep -q vibetrail-hook "$T/codex/hooks.json" && ! grep -q vibetrail-hook "$T/cursor/hooks.json" && grep -q /usr/bin/true "$T/codex/hooks.json" && grep -q mine.sh "$T/cursor/hooks.json"'
check "测试没有动真实的 ~/.codex、~/.cursor、~/.claude 配置" '[ "$(real_sum)" = "$REAL_SUM" ]'

echo
[ "$skipped_schema" -gt 0 ] && echo "  ⚠ 本机 python3 没有 jsonschema，协议 schema 校验跳过 $skipped_schema 处（pip install jsonschema 后重跑）"
if [ $fail -eq 0 ]; then echo "  ✅ $pass/$pass 通过"; else echo "  ❌ $fail 失败 / $pass 通过"; exit 1; fi
