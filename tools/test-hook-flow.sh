#!/bin/bash
# 回归：hook 分发入口 + 分歧一路挂 hook（TODO G7 第 2 步）。用 experiments/collect-demo/scenario.json 在临时目录里真实回放：
# 临时 git 仓当被观测项目，临时目录当 ~/.vibetrail 与 ~/.claude/projects，逐步追加 transcript、逐个触发 hook。
# 断言：A4 未登记零写入；登记后 spool == 对最终 transcript 的一次全量映射；stdout 永远为空、exit 0；重复触发不重复写；
# 锁被占时跳过、之后补上；半行等写完再读；文件被重写后不重复；打断后没有 Stop 也不漏；子 agent；回放副本；SessionStart 补做别的会话；scope=user。
set -uo pipefail
cd "$(dirname "$0")"; SELF=$PWD
T=$(mktemp -d "${TMPDIR:-/tmp}/vibetrail-test-hook.XXXXXX"); trap 'rm -rf "$T"' EXIT
fail=0; pass=0
ok(){ pass=$((pass+1)); }
ko(){ fail=$((fail+1)); printf '  ✗ %s\n' "$*"; }
check(){ if eval "$2"; then ok; else ko "$1"; fi; }

REPO=$T/demo-proj; mkdir -p "$REPO"; REPO=$(cd "$REPO" && pwd -P)
( cd "$REPO" && git init -q -b main && git config user.email t@t && git config user.name t \
  && printf 'def add(a, b):\n    return a + b\n' > calc.py && git add -A && git commit -q -m init )
export VIBETRAIL_HOME=$T/vt VIBETRAIL_CLAUDE_PROJECTS=$T/claude/projects VIBETRAIL_STABLE_WAIT=0 VIBETRAIL_FOREGROUND=1
. "$SELF/vibetrail-lib.sh"; VT_HOME=$VIBETRAIL_HOME
SID=11111111-2222-4333-8444-555555555555
TDIR=$VIBETRAIL_CLAUDE_PROJECTS/$(vt_slug "$REPO"); TR=$TDIR/$SID.jsonl
PKEY=$(vt_project_key "$REPO"); SPOOL=$VT_HOME/spool/$PKEY/$SID
SC=$SELF/../experiments/collect-demo/scenario.json

hook(){ # hook <事件> <payload>：exit 0 且 stdout 为空
    local out rc
    out=$(printf '%s' "$2" | bash "$SELF/vibetrail-hook" "$1" 2>"$T/hook.err"); rc=$?
    [ $rc -eq 0 ] || ko "$1: 退出码 $rc"
    [ -z "$out" ] || ko "$1: stdout 不为空: ${out:0:80}"
}
payload(){ # payload <事件名> [额外字段 JSON]
    local extra=${2:-}; [ -n "$extra" ] || extra='{}'   # 别写 "${2:-{\}}"：双引号里 \} 不去反斜杠，传进去的是 {\}
    jq -n -c --arg sid "$SID" --arg tp "$TR" --arg cwd "$REPO" --arg ev "$1" --argjson extra "$extra" \
        '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: $ev, permission_mode: "default"} + $extra'
}
replay(){ # 按 scenario 的步骤回放：append 追加一行（cwd 换成临时仓），hook 触发一次
    # 循环不能放在管道里：管道右边是子 shell，里面 ko 记的失败带不回来
    local step ev
    rm -rf "$TDIR"; mkdir -p "$TDIR"; : > "$TR"
    while IFS= read -r step; do
        if [ "$(printf '%s' "$step" | jq 'has("append")')" = "true" ]; then
            printf '%s' "$step" | jq -c --arg cwd "$REPO" '.append | .cwd = $cwd' >> "$TR"
        else
            ev=$(printf '%s' "$step" | jq -r '.hook.hook_event_name')
            hook "$ev" "$(payload "$ev")"
        fi
    done < <(jq -c '.steps[]' "$SC")
}
spool_events(){ cat "$SPOOL"/*.jsonl 2>/dev/null | jq -S -c . | sort; }
full_map(){ bash "$SELF/vibetrail-map" "$TR" --sid "$SID" --project-id "$REPO" --workspace-id "$REPO" --ledger /dev/null | jq -S -c . | sort; }

echo "════ 1. A4：scope=project、未登记的仓，回放整段会话，本机什么都不写 ════"
replay
check "未登记：没有 spool / state / logs" '[ ! -e "$VT_HOME/spool" ] && [ ! -e "$VT_HOME/state" ] && [ ! -e "$VT_HOME/logs" ]'

echo "════ 2. 登记后回放：spool == 对最终 transcript 的一次全量映射 ════"
vt_register "$REPO" >/dev/null
replay
check "spool 有块文件" 'ls "$SPOOL"/*.jsonl >/dev/null 2>&1'
check "spool 里的事件与全量映射逐条一致（3 条：被拒命令、人拒、之后的人话）" '[ "$(spool_events)" = "$(full_map)" ] && [ "$(spool_events | wc -l | tr -d " ")" = 3 ]'
check "每条过协议 schema" 'cat "$SPOOL"/*.jsonl | python3 "$SELF/schema-check.py" >/dev/null'
check "state 记下 checkpoint 与消费到的字节" 'jq -e ".consumed_bytes == $(wc -c < "$TR" | tr -d " ") and .checkpoint_line >= 1" "$VT_HOME/state/$SID/main.json" >/dev/null'
check "没有错误日志" '[ ! -s "$VT_HOME/logs/errors.log" ]'
check "被观测仓里零写入（A8）" '[ -z "$(git -C "$REPO" status --porcelain)" ]'

echo "════ 3. 重复触发不重复写 ════"
n0=$(ls "$SPOOL" | wc -l | tr -d ' ')
hook Stop "$(payload Stop)"; hook SessionEnd "$(payload SessionEnd '{"reason":"other"}')"
check "没有新块" '[ "$(ls "$SPOOL" | wc -l | tr -d " ")" = "$n0" ]'

rec(){ # rec <uuid> <parent> <promptId> <类型> <content JSON> [额外字段 JSON]
    local x=${6:-}; [ -n "$x" ] || x='{}'
    jq -n -c --arg u "$1" --arg p "$2" --arg pid "$3" --arg ty "$4" --argjson c "$5" --argjson x "$x" --arg sid "$SID" --arg cwd "$REPO" \
        '{type: $ty, uuid: $u, parentUuid: $p, promptId: $pid, message: {role: $ty, content: $c}, isSidechain: false, cwd: $cwd,
          sessionId: $sid, version: "2.1.266", entrypoint: "cli", gitBranch: "main", timestamp: "2026-09-15T12:00:00.000Z"} + $x
         | if $ty == "assistant" then del(.promptId) else . end'
}
echo "════ 4. 打断之后没有 Stop：下一轮的 Stop 补上；锁被占时跳过、放开后补上 ════"
rec a4 67283ce6-2633-428e-a646-464e502787d9 x assistant '[{"type":"text","text":"我再改一下 div。"}]' '{"message":{"id":"m4","model":"claude-opus-5","role":"assistant","content":[{"type":"text","text":"我再改一下 div。"}]}}' >> "$TR"
rec i4 a4 prompt-4 user '[{"type":"text","text":"[Request interrupted by user]"}]' >> "$TR"
hook UserPromptSubmit "$(payload UserPromptSubmit '{"prompt":"不用改了"}')"
check "UserPromptSubmit 不读 transcript（U11）：还没有新块" '[ "$(ls "$SPOOL" | wc -l | tr -d " ")" = "$n0" ]'
rec u5 i4 prompt-5 user '"不用改了"' >> "$TR"
mkdir "$VT_HOME/state/$SID/.lock"
hook Stop "$(payload Stop)"
check "锁被占：跳过，不写" '[ "$(ls "$SPOOL" | wc -l | tr -d " ")" = "$n0" ]'
rmdir "$VT_HOME/state/$SID/.lock"
hook Stop "$(payload Stop)"
check "放开锁后补上：打断的 turn.end、被打断的回复、之后的人话" '[ "$(spool_events)" = "$(full_map)" ] && [ "$(spool_events | wc -l | tr -d " ")" = 6 ]'
check "锁已释放" '[ ! -e "$VT_HOME/state/$SID/.lock" ]'

echo "════ 5. 半行：写到一半不读，写完再读 ════"
line=$(rec i6 u5 prompt-5 user '[{"type":"text","text":"[Request interrupted by user]"}]')
printf '%s' "${line:0:40}" >> "$TR"
hook Stop "$(payload Stop)"
check "半行不消费" '[ "$(jq -r .consumed_bytes "$VT_HOME/state/$SID/main.json")" -lt "$(wc -c < "$TR" | tr -d " ")" ] && [ "$(spool_events | wc -l | tr -d " ")" = 6 ]'
printf '%s\n' "${line:40}" >> "$TR"
hook Stop "$(payload Stop)"
check "写完后读到" '[ "$(spool_events)" = "$(full_map)" ] && [ "$(spool_events | wc -l | tr -d " ")" = 7 ]'

echo "════ 6. 回放副本不上报 ════"
head -n 8 "$TR" | jq -c '.promptId = "prompt-9"' >> "$TR"
hook Stop "$(payload Stop)"
check "追加 8 条副本后没有新事件" '[ "$(spool_events | wc -l | tr -d " ")" = 7 ]'

echo "════ 7. 子 agent 文件（SubagentStop）════"
mkdir -p "$TDIR/$SID/subagents"
printf '%s\n' '{"agentType":"general-purpose","description":"查","spawnDepth":1,"toolUseId":"toolu_x"}' > "$TDIR/$SID/subagents/agent-s1.meta.json"
{ rec s1u "" P1 user '"查一下"' '{"agentId":"s1","isSidechain":true}' | jq -c '.parentUuid = null'
  rec s1a s1u P1 assistant '[]' '{"agentId":"s1","isSidechain":true,"message":{"id":"sm1","model":"claude-sonnet-5","role":"assistant","content":[{"type":"tool_use","id":"st1","name":"Bash","input":{"command":"ls"}}]}}'
  rec s1d s1a P1 user '[{"type":"tool_result","tool_use_id":"st1","content":"Permission to use Bash with command ls has been denied.","is_error":true}]' '{"agentId":"s1","isSidechain":true}'
} > "$TDIR/$SID/subagents/agent-s1.jsonl"
hook SubagentStop "$(payload SubagentStop '{"agent_id":"s1"}')"
check "子 agent 的拒绝进 spool，实例 s1、父实例 main、parent_call_id 取 meta" 'cat "$SPOOL"/*-agent-s1.jsonl 2>/dev/null | jq -s -e "length == 2 and all(.[]; .agent_instance_id == \"s1\" and .parent_agent_instance_id == \"main\" and .parent_call_id == \"toolu_x\")" >/dev/null'

echo "════ 8. 文件被重写（变短）：从 0 重读，不重复 ════"
head -n 5 "$TR" > "$TR.tmp" && mv "$TR.tmp" "$TR"
hook Stop "$(payload Stop)"
check "state 重置到新文件" '[ "$(jq -r .consumed_bytes "$VT_HOME/state/$SID/main.json")" = "$(wc -c < "$TR" | tr -d " ")" ]'
check "spool 里没有重复的 event_id" '[ "$(cat "$SPOOL"/*.jsonl | jq -r .event_id | sort | uniq -d | wc -l | tr -d " ")" = 0 ]'

echo "════ 9. SessionStart 补做同仓里别的会话 ════"
SID2=22222222-3333-4444-8555-666666666666
{ rec b1 "" q1 user '"修 bug"' | jq -c --arg s "$SID2" '.sessionId = $s | .parentUuid = null'
  rec b2 b1 q1 assistant '[]' '{"message":{"id":"bm","model":"claude-opus-5","role":"assistant","content":[{"type":"text","text":"我先看日志。"}]}}' | jq -c --arg s "$SID2" '.sessionId = $s'
  rec b3 b2 q1 user '[{"type":"text","text":"[Request interrupted by user]"}]' | jq -c --arg s "$SID2" '.sessionId = $s'
} > "$TDIR/$SID2.jsonl"
hook SessionStart "$(payload SessionStart '{"source":"startup"}')"
check "别的会话的打断被补做进它自己的 spool 目录" 'cat "$VT_HOME/spool/$PKEY/$SID2"/*.jsonl 2>/dev/null | jq -s -e "map(.type) == [\"message.assistant\", \"turn.end\"]" >/dev/null'

echo "════ 10. scope=user：未登记的仓也采 ════"
vt_unregister "$REPO"; rm -rf "$VT_HOME/state" "$VT_HOME/spool"
replay
check "scope=project 下注销后回放：不写" '[ ! -e "$VT_HOME/spool" ]'
printf 'scope=user\n' > "$VT_HOME/config"
replay
check "scope=user：照样写" '[ "$(spool_events | wc -l | tr -d " ")" = 3 ]'

echo
if [ $fail -eq 0 ]; then echo "  ✅ $pass/$pass 通过"; else echo "  ❌ $fail 失败 / $pass 通过"; exit 1; fi
