#!/bin/bash
# 回归：hook 分发入口 + 分歧一路挂 hook（TODO G7 第 2 步）。用 experiments/collect-demo/scenario.json 在临时目录里真实回放：
# 临时 git 仓当被观测项目，临时目录当 ~/.vibetrail 与 ~/.claude/projects，逐步追加 transcript、逐个触发 hook。
# 断言：A4 未登记零写入；登记后 spool == 对最终 transcript 的一次全量映射；stdout 永远为空、exit 0；重复触发不重复写；
# 锁被占时跳过、之后补上；半行等写完再读；文件被重写后不重复；打断后没有 Stop 也不漏；子 agent（还在跑的不写半截调用）；回放副本；SessionStart 补做别的会话；scope=user；压缩时重写的旧工具结果不重发 tool.end；连续调用的请求开始；init 重跑不动 settings；K7 分拒绝与按停止；内部 agent、API 重试、origin.kind、轮里插话；项目级多仓各记各的、projects pick。
# 固定 C locale：macOS 自带的 bash 3.2 在 UTF-8 locale 下会把紧跟在变量名后的中文字符首字节算进变量名（变量名后紧跟「）」时，bash 找的是「V 加上「）」的首字节」这个变量），
# 开了 set -u 就报 unbound variable（用户 09-15 的终端踩到），没开就悄悄展开成空；tr / sort 的结果也随 locale 变。放在最前面，后面的解析都按 C
export LC_ALL=C
set -uo pipefail
cd "$(dirname "$0")"; SELF=$PWD
T=$(mktemp -d "${TMPDIR:-/tmp}/vibetrail-test-hook.XXXXXX"); trap 'rm -rf "$T"' EXIT
fail=0; pass=0
# 协议 schema 校验要 python3 + jsonschema（只在测试里用）；本机没装就跳过这几项并在末尾说明，不算失败
if python3 -c 'import jsonschema' 2>/dev/null; then HAVE_SCHEMA=1; else HAVE_SCHEMA=0; fi
skipped_schema=0
schema_check(){ if [ "$HAVE_SCHEMA" = 1 ]; then python3 "$SELF/schema-check.py"; else cat >/dev/null; skipped_schema=$((skipped_schema+1)); echo "(跳过)"; fi; }
ok(){ pass=$((pass+1)); }
ko(){ fail=$((fail+1)); printf '  ✗ %s\n' "$*"; }
check(){ if eval "$2"; then ok; else ko "$1"; fi; }

REPO=$T/demo-proj; mkdir -p "$REPO"; REPO=$(cd "$REPO" && pwd -P)
( cd "$REPO" && git init -q -b main && git config user.email t@t && git config user.name t \
  && printf 'def add(a, b):\n    return a + b\n' > calc.py && git add -A && git commit -q -m init )
# settings 也必须指到临时目录：09-15 第 16 段跑 init 时漏了它，把真实的 ~/.claude/settings.json 里的 hook 命令写成了临时目录（事后已恢复）
REAL_SETTINGS=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
REAL_SUM=$( { cat "$REAL_SETTINGS" 2>/dev/null || true; } | cksum)
export VIBETRAIL_HOME=$T/vt VIBETRAIL_CLAUDE_PROJECTS=$T/claude/projects VIBETRAIL_CLAUDE_SETTINGS=$T/claude/settings.json VIBETRAIL_STABLE_WAIT=0 VIBETRAIL_FOREGROUND=1
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
# spool 里分歧、轮次、hook 事件在同一条流里；这里只拿分歧那部分（rule_version diverge-v1）与全量分歧映射比。
# 打断的 turn.end 会补上 hook 记的 HEAD / 脏否 / commit，全量映射那边没有 hook 证据，比之前两边都去掉这几项
NORM='del(.payload.vcs.head_sha, .payload.vcs.dirty, .commits, .extensions["vibetrail.commit_method"], .extensions["vibetrail.commit_attribution"])'
spool_events(){ cat "$SPOOL"/*.jsonl 2>/dev/null | jq -S -c "select(.provenance.rule_version == \"diverge-v1\") | $NORM" | sort; }
full_map(){ bash "$SELF/vibetrail-map" "$TR" --no-turns --sid "$SID" --project-id "$REPO" --workspace-id "$REPO" --ledger /dev/null | jq -S -c "$NORM" | sort; }

echo "════ 0. 脚本里没有「变量名后直接跟非 ASCII 字符」，入口脚本都固定了 C locale ════"
# macOS 自带的 bash 3.2 在 UTF-8 locale 下会把紧跟变量名的中文首字节算进变量名：变量名后紧跟「）」时，找的是「V 加上「）」的首字节」这个变量（用户 09-15 装机时踩到）。
# 要把变量名用花括号包起来再接中文；入口脚本另在开头 export LC_ALL=C 兜底。.jq 文件不管：jq 的标识符只认 ASCII，不受 locale 影响
SCRIPTS="$SELF/vibetrail $SELF/vibetrail-hook $SELF/vibetrail-lib.sh $SELF/vibetrail-map $SELF/test-map.sh $SELF/test-hook-flow.sh $SELF/test-extract.sh $SELF/../experiments/collect-demo/demo.sh $SELF/../experiments/collect-demo/report.sh"
bad_vars=$(perl -ne 'if (/\$[A-Za-z_][A-Za-z0-9_]*[\x80-\xff]/) { print "$ARGV:$.\n" } close ARGV if eof' $SCRIPTS)
check "没有变量名后直接跟非 ASCII 的写法${bad_vars:+：$bad_vars}" '[ -z "$bad_vars" ]'
no_c=$(for f in $SCRIPTS; do [ "$f" = "$SELF/vibetrail-lib.sh" ] || grep -q '^export LC_ALL=C$' "$f" || echo "$f"; done)
check "入口脚本都有 export LC_ALL=C${no_c:+：$no_c}" '[ -z "$no_c" ]'

echo "════ 1. A4：scope=project、未登记的仓，回放整段会话，本机什么都不写 ════"
replay
check "未登记：没有 spool / state / logs" '[ ! -e "$VT_HOME/spool" ] && [ ! -e "$VT_HOME/state" ] && [ ! -e "$VT_HOME/logs" ]'

echo "════ 2. 登记后回放：spool == 对最终 transcript 的一次全量映射 ════"
vt_register "$REPO" >/dev/null
replay
check "spool 有块文件" 'ls "$SPOOL"/*.jsonl >/dev/null 2>&1'
check "spool 里的事件与全量映射逐条一致（3 条：被拒命令、人拒、之后的人话）" '[ "$(spool_events)" = "$(full_map)" ] && [ "$(spool_events | wc -l | tr -d " ")" = 3 ]'
check "每条过协议 schema" 'schema_check < <(cat "$SPOOL"/*.jsonl) >/dev/null'
check "state 记下 checkpoint 与消费到的字节" 'jq -e ".consumed_bytes == $(wc -c < "$TR" | tr -d " ") and .checkpoint_line >= 1" "$VT_HOME/state/$SID/main.json" >/dev/null'
check "没有错误日志" '[ ! -s "$VT_HOME/logs/errors.log" ]'
check "正常追加不算重写：state 里 rewrites 为 0、带文件指纹" 'jq -e ".rewrites == 0 and (.fprint | test(\"^[0-9]+:[0-9a-f]{40}:[0-9a-f]{40}$\"))" "$VT_HOME/state/$SID/main.json" >/dev/null'
check "被观测仓里零写入（A8）" '[ -z "$(git -C "$REPO" status --porcelain)" ]'

echo "════ 3. 重复触发不重复写 ════"
ndiv(){ spool_events | wc -l | tr -d ' '; }
nodup(){ [ "$(cat "$SPOOL"/*.jsonl | jq -r .event_id | sort | uniq -d | wc -l | tr -d ' ')" = 0 ]; }
n0=$(ndiv)
hook Stop "$(payload Stop)"; hook SessionEnd "$(payload SessionEnd '{"reason":"other"}')"
check "分歧事件不多一条、spool 里没有重复的 event_id（SessionEnd 自己会写 session.end 与最后一轮的 turn.end）" '[ "$(ndiv)" = "$n0" ] && nodup'

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
hook UserPromptSubmit "$(payload UserPromptSubmit '{"prompt":"不用改了","prompt_id":"prompt-5"}')"
check "UserPromptSubmit 不读 transcript（U11）：还没有新的分歧事件，只多一条 turn.start" '[ "$(ndiv)" = "$n0" ] && cat "$SPOOL"/*.jsonl | jq -s -e "map(select(.type == \"turn.start\" and .turn_id == \"prompt-5\")) | length == 1" >/dev/null'
rec u5 i4 prompt-5 user '"不用改了"' >> "$TR"
mkdir "$VT_HOME/state/$SID/.lock"
hook Stop "$(payload Stop)"
check "锁被占：跳过，不写" '[ "$(ndiv)" = "$n0" ]'
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
check "副本带着新 promptId 也不会凭空开出一轮、不多出 trace" '! cat "$SPOOL"/*.jsonl | jq -e "select(.turn_id == \"prompt-9\")" >/dev/null'

echo "════ 7. 子 agent 文件（SubagentStop）════"
mkdir -p "$TDIR/$SID/subagents"
printf '%s\n' '{"agentType":"general-purpose","description":"查","spawnDepth":1,"toolUseId":"toolu_x"}' > "$TDIR/$SID/subagents/agent-s1.meta.json"
{ rec s1u "" P1 user '"查一下"' '{"agentId":"s1","isSidechain":true}' | jq -c '.parentUuid = null'
  rec s1a s1u P1 assistant '[]' '{"agentId":"s1","isSidechain":true,"message":{"id":"sm1","model":"claude-sonnet-5","role":"assistant","content":[{"type":"tool_use","id":"st1","name":"Bash","input":{"command":"ls"}}]}}'
  rec s1d s1a P1 user '[{"type":"tool_result","tool_use_id":"st1","content":"Permission to use Bash with command ls has been denied.","is_error":true}]' '{"agentId":"s1","isSidechain":true}'
} > "$TDIR/$SID/subagents/agent-s1.jsonl"
hook SubagentStop "$(payload SubagentStop '{"agent_id":"s1","agent_type":"general-purpose"}')"
check "子 agent 的拒绝进 spool，实例 s1、父实例 main、parent_call_id 取 meta" 'cat "$SPOOL"/*-agent-s1.jsonl 2>/dev/null | jq -s -e "map(select(.provenance.rule_version == \"diverge-v1\")) | length == 2 and all(.[]; .agent_instance_id == \"s1\" and .parent_agent_instance_id == \"main\" and .parent_call_id == \"toolu_x\")" >/dev/null'
check "子 agent 的那次模型调用有 trace：实例 s1、不带正文；被拒的调用不伪造 tool.end" 'cat "$SPOOL"/*-agent-s1.jsonl 2>/dev/null | jq -s -e "map(select(.provenance.rule_version == \"call-v1\")) | length == 1 and .[0].type == \"message.assistant\" and .[0].agent_instance_id == \"s1\" and .[0].content_state == \"omitted\" and (.[0].payload | has(\"text\") | not) and .[0].extensions[\"vibetrail.call\"].tool_calls == [\"Bash\"]" >/dev/null'

# 并行的另一个子 agent s2 还在跑，它的一次调用只写了一半（2.1.260 边生成边执行工具：tool_use 一个一个写，结果夹在中间）
printf '%s\n' '{"agentType":"general-purpose","description":"并行","spawnDepth":1,"toolUseId":"toolu_y"}' > "$TDIR/$SID/subagents/agent-s2.meta.json"
{ rec s2u "" P1 user '"并行查"' '{"agentId":"s2","isSidechain":true}' | jq -c '.parentUuid = null'
  rec s2a s2u P1 assistant '[]' '{"agentId":"s2","isSidechain":true,"message":{"id":"sm2","model":"claude-sonnet-5","role":"assistant","content":[{"type":"tool_use","id":"s2t1","name":"Read","input":{"file_path":"calc.py"}}]}}'
  rec s2r s2a P1 user '[{"type":"tool_result","tool_use_id":"s2t1","content":"def add"}]' '{"agentId":"s2","isSidechain":true}'
} > "$TDIR/$SID/subagents/agent-s2.jsonl"
hook Notification "$(payload Notification '{"notification_type":"idle_prompt"}')"   # 任何一次解析都会顺带读到 s2
check "还在跑的子 agent：读到一半的那次调用先不写，工具结果照写" 'cat "$SPOOL"/*-agent-s2.jsonl 2>/dev/null | jq -s -e "map(select(.provenance.rule_version == \"call-v1\") | .type) == [\"tool.end\"]" >/dev/null'
{ rec s2b s2r P1 assistant '[]' '{"agentId":"s2","isSidechain":true,"message":{"id":"sm2","model":"claude-sonnet-5","role":"assistant","content":[{"type":"tool_use","id":"s2t2","name":"Grep","input":{"pattern":"add"}}]}}'
  rec s2s s2b P1 user '[{"type":"tool_result","tool_use_id":"s2t2","content":"calc.py:1"}]' '{"agentId":"s2","isSidechain":true}'
  rec s2c s2s P1 assistant '[]' '{"agentId":"s2","isSidechain":true,"message":{"id":"sm3","model":"claude-sonnet-5","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"查完了。"}]}}'
} >> "$TDIR/$SID/subagents/agent-s2.jsonl"
hook SubagentStop "$(payload SubagentStop '{"agent_id":"s2","agent_type":"general-purpose"}')"
check "s2 结束后：夹着工具结果的那次调用仍是一条、两个工具都在，最后一次回答也写出" 'cat "$SPOOL"/*-agent-s2.jsonl 2>/dev/null | jq -s -e "map(select(.type == \"message.assistant\" and .provenance.rule_version == \"call-v1\") | .extensions[\"vibetrail.call\"].tool_calls) == [[\"Read\", \"Grep\"], []]" >/dev/null'
# s2 被续上（SendMessage）又开始写：结束标记记的是当时的文件大小，文件长了就不算结束，续上的那次调用写一半时不写出
{ rec s2v s2c P1 user '"再查一个"' '{"agentId":"s2","isSidechain":true}'
  rec s2w s2v P1 assistant '[]' '{"agentId":"s2","isSidechain":true,"message":{"id":"sm4","model":"claude-sonnet-5","role":"assistant","content":[{"type":"thinking","thinking":"…"}]}}'
} >> "$TDIR/$SID/subagents/agent-s2.jsonl"
hook Notification "$(payload Notification '{"notification_type":"idle_prompt"}')"
check "s2 被续上、调用写了一半：不写出" '! cat "$SPOOL"/*-agent-s2.jsonl | jq -e "select(.extensions[\"vibetrail.call\"].response_id == \"sm4\")" >/dev/null'
rec s2x s2w P1 assistant '[]' '{"agentId":"s2","isSidechain":true,"message":{"id":"sm4","model":"claude-sonnet-5","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"也查完了。"}]}}' >> "$TDIR/$SID/subagents/agent-s2.jsonl"
hook SubagentStop "$(payload SubagentStop '{"agent_id":"s2","agent_type":"general-purpose"}')"
check "续上的这段结束后：那次调用完整写出（thinking 与回答合成一条）" 'cat "$SPOOL"/*-agent-s2.jsonl | jq -s -e "map(select(.extensions[\"vibetrail.call\"].response_id == \"sm4\")) | length == 1 and .[0].extensions[\"vibetrail.call\"].stop_reason == \"end_turn\" and .[0].extensions[\"vibetrail.call\"].thinking == true" >/dev/null'

echo "════ 8. 文件被重写（变短）：从 0 重读，不重复 ════"
head -n 5 "$TR" > "$TR.tmp" && mv "$TR.tmp" "$TR"
hook Stop "$(payload Stop)"
check "state 重置到新文件" '[ "$(jq -r .consumed_bytes "$VT_HOME/state/$SID/main.json")" = "$(wc -c < "$TR" | tr -d " ")" ]'
check "spool 里没有重复的 event_id" '[ "$(cat "$SPOOL"/*.jsonl | jq -r .event_id | sort | uniq -d | wc -l | tr -d " ")" = 0 ]'

echo "════ 8b. offset 信任检查（照 agentsview）：换 inode、原地改开头都算重写；什么都没变不算 ════"
rw(){ jq -r .rewrites "$VT_HOME/state/$SID/main.json"; }
nev(){ cat "$SPOOL"/*.jsonl | wc -l | tr -d ' '; }
r0=$(rw); e0=$(nev)
hook Stop "$(payload Stop)"
check "什么都没变：不算重写" '[ "$(rw)" = "$r0" ]'
cp "$TR" "$TR.new" && mv "$TR.new" "$TR"
hook Stop "$(payload Stop)"
check "内容不变、换了 inode：算重写，从 0 重读，spool 不多一条" '[ "$(rw)" = "$((r0 + 1))" ] && [ "$(nev)" = "$e0" ]'
{ rec zz "" q0 user '"在开头插进来的一行"' | jq -c '.parentUuid = null'; cat "$TR"; } > "$TR.new"
cat "$TR.new" > "$TR"; rm -f "$TR.new"
hook Stop "$(payload Stop)"
check "inode 不变、开头被改、文件变长：靠开头的哈希认出重写，spool 里没有重复的 event_id" '[ "$(rw)" = "$((r0 + 2))" ] && [ "$(cat "$SPOOL"/*.jsonl | jq -r .event_id | sort | uniq -d | wc -l | tr -d " ")" = 0 ]'

echo "════ 9. SessionStart 补做同仓里别的会话 ════"
SID2=22222222-3333-4444-8555-666666666666
{ rec b1 "" q1 user '"修 bug"' | jq -c --arg s "$SID2" '.sessionId = $s | .parentUuid = null'
  rec b2 b1 q1 assistant '[]' '{"message":{"id":"bm","model":"claude-opus-5","role":"assistant","content":[{"type":"text","text":"我先看日志。"}]}}' | jq -c --arg s "$SID2" '.sessionId = $s'
  rec b3 b2 q1 user '[{"type":"text","text":"[Request interrupted by user]"}]' | jq -c --arg s "$SID2" '.sessionId = $s'
} > "$TDIR/$SID2.jsonl"
hook SessionStart "$(payload SessionStart '{"source":"startup"}')"
check "别的会话的打断被补做进它自己的 spool 目录" 'cat "$VT_HOME/spool/$PKEY/$SID2"/*.jsonl 2>/dev/null | jq -s -e "map(select(.provenance.rule_version == \"diverge-v1\") | .type) == [\"message.assistant\", \"turn.end\"]" >/dev/null'

echo "════ 10. scope=user：未登记的仓也采 ════"
vt_unregister "$REPO"; rm -rf "$VT_HOME/state" "$VT_HOME/spool"
replay
check "scope=project 下注销后回放：不写" '[ ! -e "$VT_HOME/spool" ]'
printf 'scope=user\n' > "$VT_HOME/config"
replay
check "scope=user：照样写" '[ "$(spool_events | wc -l | tr -d " ")" = 3 ]'

echo "════ 11. 压缩时重写的旧工具结果（原 uuid、新 promptId）：增量解析不再发一次 tool.end ════"
R=$T/rewrite.jsonl
{ rec r1 "" P1 user '"跑一下"' | jq -c '.parentUuid = null'
  rec r2 r1 P1 assistant '[]' '{"message":{"id":"rm1","model":"claude-opus-5","role":"assistant","content":[{"type":"tool_use","id":"rt1","name":"Bash","input":{"command":"ls"}}]}}'
  rec r3 r2 P1 user '[{"type":"tool_result","tool_use_id":"rt1","content":"calc.py"}]'
  rec r4 r3 P1 assistant '[]' '{"message":{"id":"rm2","model":"claude-opus-5","role":"assistant","content":[{"type":"text","text":"好了。"}],"stop_reason":"end_turn"}}'
  rec r5 r4 P2 user '"再看看"'
  rec r6 r5 P2 assistant '[]' '{"message":{"id":"rm3","model":"claude-opus-5","role":"assistant","content":[{"type":"text","text":"看过了。"}],"stop_reason":"end_turn"}}'
  rec r3 r2 P2 user '[{"type":"tool_result","tool_use_id":"rt1","content":"calc.py"}]'
} > "$R"
map_r(){ bash "$SELF/vibetrail-map" "$@" --sid "$SID" --project-id p --workspace-id w 2>/dev/null; }
head -n 6 "$R" > "$T/rewrite-a.jsonl"
map_r "$T/rewrite-a.jsonl" --ledger "$T/rw-a.l" --sources-out "$T/rw-a.src" > "$T/rw-a.ev"
map_r "$R" --start-line "$(jq -r .checkpoint_line "$T/rw-a.l")" --start-byte "$(jq -r .checkpoint_byte "$T/rw-a.l")" --from-line 6 \
    --seen-uuids "$T/rw-a.src" --ledger /dev/null > "$T/rw-b.ev"
check "整份解析：rt1 只有一条 tool.end，工具名是 Bash" 'map_r "$R" --ledger /dev/null | jq -s -e "map(select(.type == \"tool.end\")) | length == 1 and .[0].payload.tool_name == \"Bash\"" >/dev/null'
check "分两次解析：后一次不再发 rt1 的 tool.end，两次合起来没有重复的 event_id" '! grep -q "\"tool.end\"" "$T/rw-b.ev" && [ "$(cat "$T/rw-a.ev" "$T/rw-b.ev" | jq -r .event_id | sort | uniq -d | wc -l | tr -d " ")" = 0 ]'

echo "════ 12. 连着几次模型调用、中间没有 user 记录（连续撞 max_tokens）：后一次的请求开始是前一次的结尾 ════"
R2=$T/maxtok.jsonl
{ rec q1 "" P1 user '"想一想"' '{"timestamp":"2026-09-15T12:00:00.000Z"}' | jq -c '.parentUuid = null'
  rec c1 q1 P1 assistant '[]' '{"timestamp":"2026-09-15T12:10:00.000Z","message":{"id":"mc1","model":"claude-opus-5","role":"assistant","stop_reason":"max_tokens","content":[{"type":"thinking","thinking":"…"}]}}'
  rec c2 c1 P1 assistant '[]' '{"timestamp":"2026-09-15T12:20:00.000Z","message":{"id":"mc2","model":"claude-opus-5","role":"assistant","stop_reason":"max_tokens","content":[{"type":"thinking","thinking":"…"}]}}'
  rec c3 c2 P1 assistant '[]' '{"timestamp":"2026-09-15T12:20:05.000Z","message":{"id":"mc3","model":"claude-opus-5","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"想好了。"}]}}'
} > "$R2"
check "三次调用的请求开始依次是人话、第一次的结尾、第二次的结尾" 'map_r "$R2" --ledger /dev/null --close-last stop --stop-turn P1 | jq -s -e "map(select(.type == \"message.assistant\") | .extensions[\"vibetrail.call\"].started_at) == [\"2026-09-15T12:00:00.000Z\", \"2026-09-15T12:10:00.000Z\", \"2026-09-15T12:20:00.000Z\"]" >/dev/null'

R3=$T/interleave.jsonl
{ rec i1 "" P1 user '"看两个文件"' | jq -c '.parentUuid = null'
  rec i2 i1 P1 assistant '[]' '{"message":{"id":"mi1","model":"claude-opus-5","role":"assistant","content":[{"type":"tool_use","id":"it1","name":"Read","input":{"file_path":"a"}}]}}'
  rec i3 i2 P1 user '[{"type":"tool_result","tool_use_id":"it1","content":"a"}]'
  rec i4 i3 P1 assistant '[]' '{"message":{"id":"mi1","model":"claude-opus-5","role":"assistant","content":[{"type":"tool_use","id":"it2","name":"Read","input":{"file_path":"b"}}]}}'
  rec i5 i4 P1 user '[{"type":"tool_result","tool_use_id":"it2","content":"b"}]'
  rec i6 i5 P1 assistant '[]' '{"message":{"id":"mi2","model":"claude-opus-5","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"看完了。"}]}}'
} > "$R3"
check "同一次调用的记录中间夹着工具结果（2.1.260 边生成边执行）：仍是一条，两个工具都在" 'map_r "$R3" --ledger /dev/null --close-last stop --stop-turn P1 | jq -s -e "map(select(.type == \"message.assistant\") | .extensions[\"vibetrail.call\"].tool_calls) == [[\"Read\", \"Read\"], []]" >/dev/null'

R4=$T/pending.jsonl
{ rec p1 "" P1 user '"第一问"' '{"timestamp":"2026-09-15T12:00:00.000Z"}' | jq -c '.parentUuid = null'
  rec p2 p1 P1 assistant '[]' '{"timestamp":"2026-09-15T12:00:30.000Z","message":{"id":"mp1","model":"claude-opus-5","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"答一。"}]}}'
  rec p3 p2 P2 user '"第二问"' '{"timestamp":"2026-09-15T12:05:00.000Z"}'
  rec p4 p3 P2 assistant '[]' '{"timestamp":"2026-09-15T12:05:20.000Z","message":{"id":"mp2","model":"claude-opus-5","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"答二。"}]}}'
} > "$R4"
head -n 3 "$R4" > "$T/pending-a.jsonl"     # 上一次读到第二问为止，上一轮没经过 Stop 关（第一问的回答还没写出）
map_r "$T/pending-a.jsonl" --ledger "$T/pd-a.l" --sources-out "$T/pd-a.src" > "$T/pd-a.ev"
map_r "$R4" --start-line "$(jq -r .checkpoint_line "$T/pd-a.l")" --start-byte "$(jq -r .checkpoint_byte "$T/pd-a.l")" --from-line 3 \
    --seen-uuids "$T/pd-a.src" --ledger /dev/null > "$T/pd-b.ev"
check "起读行不越过还没写出的调用：第一问的回答照样写出，归第一轮、请求开始是第一问" 'cat "$T/pd-a.ev" "$T/pd-b.ev" | jq -s -e "map(select(.type == \"message.assistant\" and .extensions[\"vibetrail.call\"].response_id == \"mp1\")) | length == 1 and .[0].turn_id == \"P1\" and .[0].extensions[\"vibetrail.call\"].started_at == \"2026-09-15T12:00:00.000Z\"" >/dev/null'

echo "════ 13. init：别的设置原样保留；重跑没有变化就不动 settings、不多一份备份；uninstall 只去掉自己的 ════"
IS=$T/init-home; mkdir -p "$IS/.claude"; printf '{\n    "model": "opus"\n}\n' > "$IS/.claude/settings.json"
vcli(){ ( cd "$REPO" && VIBETRAIL_HOME=$IS/.vibetrail VIBETRAIL_CLAUDE_SETTINGS=$IS/.claude/settings.json bash "$SELF/vibetrail" "$@" >/dev/null 2>&1 ); }
nhook(){ jq '[.. | objects | select(has("command")) | .command | select(test("vibetrail-hook"))] | length' "$IS/.claude/settings.json"; }
vcli init --no-register; n1=$(nhook); vcli init --no-register
check "两次 init：model 还在、条目没翻倍；第二次没变化，不写也不多备份；装之前的原样另存了一份" '[ "$(nhook)" = "$n1" ] && [ "$n1" -gt 0 ] && jq -e ".model == \"opus\"" "$IS/.claude/settings.json" >/dev/null && [ "$(ls "$IS/.vibetrail/backup"/settings.json.2* | wc -l | tr -d " ")" = 1 ] && jq -e ". == {model: \"opus\"}" "$IS/.vibetrail/backup/settings.json.before-vibetrail" >/dev/null 2>&1'
IS2=$T/init-home2; mkdir -p "$IS2/.claude"
check "在 git 仓里跑 init：不登记任何仓（免得在哪个目录跑一下就误加），并明说现在什么都不会采" \
    'out=$( cd "$REPO" && VIBETRAIL_HOME=$IS2/.vibetrail VIBETRAIL_CLAUDE_SETTINGS=$IS2/.claude/settings.json bash "$SELF/vibetrail" init 2>&1 ); [ -z "$(ls "$IS2/.vibetrail/projects" 2>/dev/null)" ] && printf "%s" "$out" | grep -q "还没有登记任何仓"'
mkdir -p "$IS2/.vibetrail/removed/old-x" "$IS2/.vibetrail/removed/new-y"; perl -e 'utime(time - 2*86400, time - 2*86400, $ARGV[0])' "$IS2/.vibetrail/removed/old-x"
check "projects remove --drop 挪出去的数据留一天：两天前的清掉，刚挪进去的留着" \
    'VIBETRAIL_HOME=$IS2/.vibetrail VIBETRAIL_CLAUDE_SETTINGS=$IS2/.claude/settings.json bash "$SELF/vibetrail" projects list >/dev/null 2>&1; [ ! -e "$IS2/.vibetrail/removed/old-x" ] && [ -d "$IS2/.vibetrail/removed/new-y" ]'
IS3=$T/init-home3; mkdir -p "$IS3/.claude"
check "全新机器（原来没有 settings.json）：init 说新建了一份，不说「备份在」（没有可备份的）" \
    'out=$( cd "$REPO" && VIBETRAIL_HOME=$IS3/.vibetrail VIBETRAIL_CLAUDE_SETTINGS=$IS3/.claude/settings.json bash "$SELF/vibetrail" init 2>&1 ); printf "%s" "$out" | grep -q "新建了一份" && ! printf "%s" "$out" | grep -q "备份在"'
mkdir -p "$T/g/home/.claude"; printf '{"model": "opus"}\n' > "$T/g/home/.claude/settings.json"; g0=$(cksum < "$T/g/home/.claude/settings.json")
check "运行时在临时目录、settings 不在（模拟测试漏设 VIBETRAIL_CLAUDE_SETTINGS）：init 拒绝写，settings 一字不动" \
    '! ( cd "$REPO" && VIBETRAIL_HOME=$T/g/tmpvt VIBETRAIL_CLAUDE_SETTINGS=$T/g/home/.claude/settings.json VIBETRAIL_TMP_ROOTS=$T/g/tmpvt bash "$SELF/vibetrail" init --no-register --no-pick >/dev/null 2>&1 ) && [ "$(cksum < "$T/g/home/.claude/settings.json")" = "$g0" ]'
# 重复挂载：Claude Code 把 HOME / 项目 / 企业策略几层的 hooks 合起来跑，同一事件挂两处就触发两遍
# （teamai 的 src/hooks.ts:1009 踩过同一个坑：老版本在 HOME 之外还往项目目录写了一份，升级后每次会话开始触发两次）
vdoc(){ ( cd "$REPO" && VIBETRAIL_HOME=$IS/.vibetrail VIBETRAIL_CLAUDE_SETTINGS=$IS/.claude/settings.json bash "$SELF/vibetrail" doctor 2>&1 ); }
check "doctor：只有 HOME 挂着时说「只挂在一处」；Notification 的两个 matcher（permission_prompt / idle_prompt）不算重复" \
    'o=$(vdoc); printf "%s" "$o" | grep -q "hook 只挂在一处" && ! printf "%s" "$o" | grep -q "重复挂载"'
mkdir -p "$REPO/.claude"; jq '{hooks: {Stop: .hooks.Stop}}' "$IS/.claude/settings.json" > "$REPO/.claude/settings.local.json"
check "doctor：项目级 settings 里也挂了一份 Stop → 报重复挂载，并把两份文件都点名" \
    'o=$(vdoc); printf "%s" "$o" | grep -q "hook 重复挂载：Stop（2 条" && printf "%s" "$o" | grep -q "$REPO/.claude/settings.local.json"'
rm -f "$REPO/.claude/settings.local.json"; rmdir "$REPO/.claude" 2>/dev/null
check "doctor：同一份 settings 里同一事件挂了两条（同 matcher）也算重复" \
    'jq ".hooks.Stop += .hooks.Stop" "$IS/.claude/settings.json" > "$IS/.claude/s.tmp" && cp "$IS/.claude/settings.json" "$IS/.claude/s.bak" \
     && mv "$IS/.claude/s.tmp" "$IS/.claude/settings.json"; o=$(vdoc); mv "$IS/.claude/s.bak" "$IS/.claude/settings.json"
     printf "%s" "$o" | grep -q "hook 重复挂载：Stop（2 条"'
vcli uninstall
check "uninstall 之后回到原样，原样那份备份没被覆盖" 'jq -e ". == {model: \"opus\"}" "$IS/.claude/settings.json" >/dev/null && jq -e ". == {model: \"opus\"}" "$IS/.vibetrail/backup/settings.json.before-vibetrail" >/dev/null 2>&1'

echo "════ 14. K7：「User rejected tool use」是人拒绝还是按停止——先按 permissionMode 粗分，挂上 PermissionRequest 后看弹没弹过框 ════"
# 场景：人问一句 → 模型跑一个 Bash → 该调用得到「The user doesn't want to proceed…」→ 「[Request interrupted by user for tool use]」→ Stop。
# 两种来历写进 transcript 的逐字一样；时间戳取「现在」前后，PermissionRequest 的证据（hook 当场记的时间）才落在时间窗里
k7case(){ # k7case <会话后缀> <permissionMode> <permission_request_since：空=没挂上> <弹没弹过框 0/1>
    local sid0=$SID tr0=$TR t0 t1 t2
    SID=77777777-0000-4000-8000-00000000000$1; TR=$TDIR/$SID.jsonl; K7SPOOL=$VT_HOME/spool/$PKEY/$SID
    t0=$(jq -n -r 'now - 3 | todate'); t1=$(jq -n -r 'now - 1 | todate'); t2=$(jq -n -r 'now | todate')
    grep -v '^permission_request_since=' "$VT_HOME/config" > "$VT_HOME/config.tmp"; mv "$VT_HOME/config.tmp" "$VT_HOME/config"
    [ -n "$3" ] && printf 'permission_request_since=%s\n' "$3" >> "$VT_HOME/config"
    { rec k1 "" pk7 user '"跑一下测试"' "$(jq -n -c --arg m "$2" --arg t "$t0" '{permissionMode: $m, timestamp: $t}')" | jq -c '.parentUuid = null'
      rec k2 k1 pk7 assistant '[]' "$(jq -n -c --arg t "$t0" '{timestamp: $t, message: {id: "mk7", model: "claude-opus-5", role: "assistant", content: [{type: "tool_use", id: "tk7", name: "Bash", input: {command: "sleep 100"}}]}}')"
    } > "$TR"
    [ "$4" = 1 ] && hook PermissionRequest "$(payload PermissionRequest '{"tool_name":"Bash","tool_input":{"command":"sleep 100"}}')"
    { rec k3 k2 pk7 user '[{"type":"tool_result","tool_use_id":"tk7","is_error":true,"content":"The user doesn'"'"'t want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed."}]' "$(jq -n -c --arg t "$t1" '{timestamp: $t, toolUseResult: "User rejected tool use"}')"
      rec k4 k3 pk7 user '[{"type":"text","text":"[Request interrupted by user for tool use]"}]' "$(jq -n -c --arg t "$t2" '{timestamp: $t}')"
    } >> "$TR"
    hook Stop "$(payload Stop '{"prompt_id":"pk7"}')"
    SID=$sid0; TR=$tr0
}
k7ev(){ cat "$K7SPOOL"/*.jsonl 2>/dev/null | jq -S -s -c "$1"; }
stopped='map(select(.type == "turn.end" and .extensions["vibetrail.kind"] == "interrupt_tool"))'
k7case 1 auto "" 0
check "auto、没挂 PermissionRequest：按停止——不发 permission.decision，发 turn.end(interrupted)、kind = interrupt_tool，被打断的 Bash 照发 tool.request" \
    '[ "$(k7ev "[(map(select(.type == \"permission.decision\")) | length), ($stopped | length), ($stopped | .[0].payload.status.code), ($stopped | .[0].extensions[\"vibetrail.split_by\"]), ($stopped | .[0].extensions[\"vibetrail.permission_mode\"]), (map(select(.type == \"tool.request\" and .payload.call_id == \"tk7\")) | length)]")" = "[0,1,\"interrupted\",\"permission_mode\",\"auto\",1]" ]'
k7case 2 default "" 0
check "default、没挂 PermissionRequest：仍算拒绝，注明按 permissionMode 分的" \
    '[ "$(k7ev "[(map(select(.type == \"permission.decision\")) | .[0].extensions | [.[\"vibetrail.split_by\"], .[\"vibetrail.permission_mode\"]]), ($stopped | length)]")" = "[[\"permission_mode\",\"default\"],0]" ]'
k7case 3 default "$(( $(date +%s) - 60 ))" 1
check "挂上了、弹过框：是拒绝，prompt_shown = true；PermissionRequest 记了事件头（不带参数）" \
    '[ "$(k7ev "[(map(select(.type == \"permission.decision\")) | .[0].extensions | [.[\"vibetrail.split_by\"], .[\"vibetrail.prompt_shown\"]]), ($stopped | length), (map(select(.type == \"ext.claude.permission_request\")) | .[0].payload)]")" = "[[\"permission_request\",true],0,{\"permission_mode\":\"default\",\"tool_name\":\"Bash\"}]" ]'
k7case 4 default "$(( $(date +%s) - 60 ))" 0
check "挂上了、没弹过框：default 模式也是按停止" \
    '[ "$(k7ev "[(map(select(.type == \"permission.decision\")) | length), ($stopped | .[0].extensions[\"vibetrail.split_by\"])]")" = "[0,\"permission_request\"]" ]'

echo "════ 15. 两家都没解决、我们自己修的：内部 agent（K9）、K7 两处补充、API 重试与 origin.kind（U15）、轮里插话（K10）、调用 id ════"
hook SubagentStop "$(payload SubagentStop '{"agent_id":"ainternal1","agent_type":""}')"
check "内部 agent（agent_type 为空）：只记 ext.claude.subagent_stop（internal），不发 subagent.end" \
    '[ "$(cat "$SPOOL"/*.jsonl | jq -s -c "[(map(select(.type == \"ext.claude.subagent_stop\")) | .[0].payload), (map(select(.type == \"subagent.end\" and .agent_instance_id == \"ainternal1\")) | length)]")" = "[{\"agent_id\":\"ainternal1\",\"internal\":true},0]" ]'
REJ='The user doesn'"'"'t want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.'
mkdir -p "$T/k15/$SID/subagents"; SUBF=$T/k15/$SID/subagents/agent-x9.jsonl
{ rec x1 "" P1 user '"查一下"' '{"agentId":"x9","isSidechain":true}' | jq -c '.parentUuid = null'
  rec x2 x1 P1 assistant '[]' '{"agentId":"x9","isSidechain":true,"message":{"id":"xm1","model":"claude-sonnet-5","role":"assistant","content":[{"type":"tool_use","id":"xt1","name":"Bash","input":{"command":"sleep 9"}}]}}'
  rec x3 x2 P1 user "$(jq -n -c --arg t "$REJ" '[{type: "tool_result", tool_use_id: "xt1", is_error: true, content: $t}]')" '{"agentId":"x9","isSidechain":true,"toolUseResult":"User rejected tool use"}'
  rec x4 x3 P1 user '[{"type":"text","text":"[Request interrupted by user for tool use]"}]' '{"agentId":"x9","isSidechain":true}'
} > "$SUBF"
check "子 agent 文件里的 User rejected tool use：按停止，发 subagent.end(cancelled)、kind = interrupt_tool、split_by = subagent_rejected，不发 permission.decision" \
    '[ "$(map_r "$SUBF" --ledger /dev/null --parent-instance main | jq -s -c "[(map(select(.type == \"permission.decision\")) | length), (map(select(.type == \"subagent.end\")) | .[0] | [.payload.status.code, .extensions[\"vibetrail.kind\"], .extensions[\"vibetrail.split_by\"]])]")" = "[0,[\"cancelled\",\"interrupt_tool\",\"subagent_rejected\"]]" ]'
R5=$T/k15-main.jsonl
{ rec m1 "" P1 user '"跑一下"' '{"permissionMode":"auto","origin":{"kind":"human"}}' | jq -c '.parentUuid = null'
  rec m2 m1 P1 assistant '[]' '{"timestamp":"2026-09-15T12:00:05.000Z","message":{"id":"mm1","model":"claude-opus-5","role":"assistant","content":[{"type":"tool_use","id":"mt1","name":"Bash","input":{"command":"rm -rf build"}}]}}'
  # 两次重试发生在请求发出（12:00:00）与回复到达（12:00:05）之间，但记录要等之后才落盘（真实顺序：写在它那次调用之后；后一条的父记录是前一条）
  jq -n -c --arg sid "$SID" '{type: "system", subtype: "api_error", uuid: "m1e1", parentUuid: "m1", retryInMs: 600, retryAttempt: 1, maxRetries: 10, source: "request_retry", error: "{\"message\":\"Connection error.\",\"formatted\":\"Connection dropped (ECONNRESET)\"}", sessionId: $sid, timestamp: "2026-09-15T12:00:01.000Z"}'
  jq -n -c --arg sid "$SID" '{type: "system", subtype: "api_error", uuid: "m1e2", parentUuid: "m1e1", retryInMs: 1200, retryAttempt: 2, maxRetries: 10, source: "request_retry", sessionId: $sid, timestamp: "2026-09-15T12:00:03.000Z"}'
  rec m3 m2 P1 user "$(jq -n -c --arg t "$REJ" '[{type: "tool_result", tool_use_id: "mt1", is_error: true, content: $t}]')" '{"toolUseResult":"Error: The user doesn'"'"'t want to proceed with this tool use.","userFeedback":"别删 build"}'
  rec m4 m3 P1 user '[{"type":"text","text":"[Request interrupted by user for tool use]"}]'
  rec m5 m4 P2 user '"后台任务跑完了"' '{"origin":{"kind":"task-notification"}}'
  rec m6 m5 P3 user '"换成 make clean"' '{"permissionMode":"auto","origin":{"kind":"human"}}'
  jq -n -c --arg sid "$SID" '{type: "attachment", uuid: "m6q", parentUuid: "m6", sessionId: $sid, timestamp: "2026-09-15T12:00:09.000Z", attachment: {type: "queued_command", prompt: "顺便看下日志", commandMode: "prompt", origin: {kind: "human"}}}'
  rec m7 m6q P3 assistant '[]' '{"message":{"id":"mm2","model":"claude-opus-5","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"好。"}]}}'
} > "$R5"
k15(){ map_r "$R5" --ledger /dev/null --close-last stop --stop-turn P3 | jq -S -s -c "$1"; }
check "toolUseResult 以 Error: 开头（带了拒绝理由）：auto 模式下也仍是拒绝" '[ "$(k15 "[(map(select(.type == \"permission.decision\")) | length), (map(select(.extensions[\"vibetrail.kind\"] == \"interrupt_tool\")) | length)]")" = "[1,0]" ]'
check "API 重试两次：各发一条 ext.claude.api_error（第几次、等多久、错误类型），按时间挂回那次调用 mm1；调用带上它发起的工具调用 id" \
    '[ "$(k15 "[(map(select(.type == \"ext.claude.api_error\")) | map([.payload.retry_attempt, .payload.retry_in_ms, .extensions[\"vibetrail.response_id\"]])), (map(select(.type == \"ext.claude.api_error\")) | .[0].payload.error), (map(select(.type == \"message.assistant\" and .extensions[\"vibetrail.call\"].response_id == \"mm1\")) | .[0].extensions[\"vibetrail.call\"].tool_call_ids)]")" = "[[[1,600,\"mm1\"],[2,1200,\"mm1\"]],\"Connection dropped (ECONNRESET)\",[\"mt1\"]]" ]'
check "origin 是 task-notification 的不算人话（不当拒绝之后的下一句）；origin 是人的算" \
    '[ "$(k15 "[map(select(.type == \"message.user\")) | .[].payload.text]")" = "[\"换成 make clean\"]" ]'
check "轮里插了一句话：turn.end 记 vibetrail.queued_prompts = 1（只计数、不带正文）" \
    '[ "$(k15 "map(select(.type == \"turn.end\" and .turn_id == \"P3\")) | .[0].extensions[\"vibetrail.queued_prompts\"]")" = "1" ] && ! k15 "." | grep -q "顺便看下日志"'

R6=$T/k15-par.jsonl
{ rec n1 "" P1 user '"读一下再跑"' '{"permissionMode":"auto","origin":{"kind":"human"}}' | jq -c '.parentUuid = null'
  rec n2 n1 P1 assistant '[]' '{"message":{"id":"nm1","model":"claude-opus-5","role":"assistant","content":[{"type":"tool_use","id":"nt1","name":"Read","input":{"file_path":"a"}}]}}'
  rec n3 n2 P1 assistant '[]' '{"message":{"id":"nm1","model":"claude-opus-5","role":"assistant","content":[{"type":"tool_use","id":"nt2","name":"Bash","input":{"command":"sleep 60"}}]}}'
  rec n4 n2 P1 user '[{"type":"tool_result","tool_use_id":"nt1","content":"a"}]'
  rec n5 n3 P1 user "$(jq -n -c --arg t "$REJ" '[{type: "tool_result", tool_use_id: "nt2", is_error: true, content: $t}]')" '{"toolUseResult":"User rejected tool use"}'
  rec n6 n5 P1 user '[{"type":"text","text":"[Request interrupted by user for tool use]"}]'
} > "$R6"
check "按停止打断时只发真正被打断的那次调用：同一条回复里已经跑完的 Read 不算" \
    '[ "$(map_r "$R6" --ledger /dev/null | jq -s -c "[.[] | select(.type == \"tool.request\") | .payload.call_id]")" = "[\"nt2\"]" ]'

echo "════ 16. 项目级：两个登记的仓各记各的（补采按那个仓算）；删掉的 desktop worktree 留下的会话照样补；projects pick 选仓；init 列登记表 ════"
REPO2=$T/second-proj; mkdir -p "$REPO2"; REPO2=$(cd "$REPO2" && pwd -P)
( cd "$REPO2" && git init -q -b main && git config user.email t@t && git config user.name t && git remote add origin git@github.com:acme/second.git \
  && printf 'x\n' > a.txt && git add -A && git commit -q -m init )
grep -v '^scope=' "$VT_HOME/config" > "$VT_HOME/config.tmp"; printf 'scope=project\n' >> "$VT_HOME/config.tmp"; mv "$VT_HOME/config.tmp" "$VT_HOME/config"
vt_register "$REPO"; vt_unregister "$REPO2" 2>/dev/null
TD2=$VIBETRAIL_CLAUDE_PROJECTS/$(vt_slug "$REPO2"); TDG=$VIBETRAIL_CLAUDE_PROJECTS/$(vt_slug "$REPO2")--claude-worktrees-gone; mkdir -p "$TD2" "$TDG"
SIDA=33333333-0000-4000-8000-00000000000a; SIDB=33333333-0000-4000-8000-00000000000b
{ rec a1 "" qa user '"第二个仓里问一句"' | jq -c --arg s "$SIDA" --arg c "$REPO2" '.sessionId = $s | .cwd = $c | .parentUuid = null'
  rec a2 a1 qa assistant '[]' '{"message":{"id":"am1","model":"claude-opus-5","role":"assistant","content":[{"type":"text","text":"我先看看。"}]}}' | jq -c --arg s "$SIDA" --arg c "$REPO2" '.sessionId = $s | .cwd = $c'
  rec a3 a2 qa user '[{"type":"text","text":"[Request interrupted by user]"}]' | jq -c --arg s "$SIDA" --arg c "$REPO2" '.sessionId = $s | .cwd = $c'
} > "$TD2/$SIDA.jsonl"
{ rec g1 "" qg user '"worktree 里问一句"' | jq -c --arg s "$SIDB" --arg c "$REPO2/.claude/worktrees/gone" '.sessionId = $s | .cwd = $c | .parentUuid = null'
  rec g2 g1 qg assistant '[]' '{"message":{"id":"gm1","model":"claude-opus-5","role":"assistant","content":[{"type":"text","text":"好。"}]}}' | jq -c --arg s "$SIDB" --arg c "$REPO2/.claude/worktrees/gone" '.sessionId = $s | .cwd = $c'
  rec g3 g2 qg user '[{"type":"text","text":"[Request interrupted by user]"}]' | jq -c --arg s "$SIDB" --arg c "$REPO2/.claude/worktrees/gone" '.sessionId = $s | .cwd = $c'
} > "$TDG/$SIDB.jsonl"
PK2=$(vt_project_key "$REPO2")
hook SessionStart "$(payload SessionStart '{"source":"startup"}')"
check "第二个仓没登记：补采不碰它" '[ ! -e "$VT_HOME/spool/$PK2" ]'
check "projects pick：候选里有第二个仓（删掉的 worktree 并到主仓），选 a 全部登记" \
    'out=$(printf "a\n" | bash "$SELF/vibetrail" projects pick 2>&1); [ "$(printf "%s\n" "$out" | grep -E "^ *[0-9]+\. " | grep -c "$REPO2")" = 1 ] && vt_registered "$REPO2"'
hook SessionStart "$(payload SessionStart '{"source":"startup"}')"
check "在第一个仓里开会话、补采到第二个仓的会话：记在第二个仓的 spool 目录，project_id / workspace_id 是第二个仓的" \
    '[ "$(cat "$VT_HOME/spool/$PK2/$SIDA"/*.jsonl 2>/dev/null | jq -s -c "[length > 0, (map(.project_id) | unique), (map(.workspace_id) | unique)]")" = "[true,[\"github.com/acme/second\"],[\"$REPO2\"]]" ] && [ ! -e "$VT_HOME/spool/$PKEY/$SIDA" ]'
check "删掉的 desktop worktree 留下的会话照样补，归主仓" '[ -n "$(cat "$VT_HOME/spool/$PK2/$SIDB"/*.jsonl 2>/dev/null)" ]'
check "init（不在终端里跑，不问）：最后列出登记表，两个仓都在" \
    'out=$( cd "$REPO" && bash "$SELF/vibetrail" init --no-register 2>&1 ); printf "%s" "$out" | grep -q "只采下面这些登记过的仓" && printf "%s" "$out" | grep -q "$REPO2" && printf "%s" "$out" | grep -qF "· $REPO"'

n2=$(printf '\n' | bash "$SELF/vibetrail" projects pick 2>/dev/null | grep -F "$REPO2" | sed -n 's/^ *\([0-9][0-9]*\)\..*/\1/p' | head -1)
check "projects pick 编号前加 - 去掉：第二个仓不再登记，它已采的数据留在 spool" \
    'printf -- "-%s\n" "$n2" | bash "$SELF/vibetrail" projects pick >/dev/null 2>&1; ! vt_registered "$REPO2" && [ -d "$VT_HOME/spool/$PK2" ]'
check "pick 里去掉一个本来就没登记的：明说「本来就没登记」，不是只给一句去掉 0 个" \
    'out=$(printf -- "-%s\n" "$n2" | bash "$SELF/vibetrail" projects pick 2>&1); printf "%s" "$out" | grep -q "第 $n2 个本来就没登记"'
vt_register "$REPO2"
check "projects remove --drop：不再登记，它已采、还没发出去的数据挪出 spool（到 removed/，不删）" \
    'bash "$SELF/vibetrail" projects remove "$REPO2" --drop >/dev/null 2>&1; ! vt_registered "$REPO2" && [ ! -e "$VT_HOME/spool/$PK2" ] && ls -d "$VT_HOME/removed/$PK2"-* >/dev/null 2>&1'
check "测试没有动真实的 settings.json（${REAL_SETTINGS}）" '[ "$( { cat "$REAL_SETTINGS" 2>/dev/null || true; } | cksum)" = "$REAL_SUM" ]'
echo
[ "$skipped_schema" -gt 0 ] && echo "  ⚠ 本机 python3 没有 jsonschema，协议 schema 校验跳过 $skipped_schema 处（pip install jsonschema 后重跑）"
if [ $fail -eq 0 ]; then echo "  ✅ $pass/$pass 通过"; else echo "  ❌ $fail 失败 / $pass 通过"; exit 1; fi
