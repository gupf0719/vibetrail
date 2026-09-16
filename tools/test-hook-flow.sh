#!/bin/bash
# 回归：hook 分发入口 + 分歧一路挂 hook（TODO G7 第 2 步）。用 experiments/collect-demo/scenario.json 在临时目录里真实回放：
# 临时 git 仓当被观测项目，临时目录当 ~/.vibetrail 与 ~/.claude/projects，逐步追加 transcript、逐个触发 hook。
# 断言：A4 未登记零写入；登记后 spool == 对最终 transcript 的一次全量映射；stdout 永远为空、exit 0；重复触发不重复写；
# 锁被占时跳过、之后补上；半行等写完再读；文件被重写后不重复；打断后没有 Stop 也不漏；子 agent（起止与「写完了」看父会话里的信号，还在跑的不写半截调用）；只挂 5 个 hook（退役事件不做事、init 清旧条目）；上报 token（init 引导、不回显、600）与终端里的交互输入；回放副本；SessionStart 补做别的会话；scope=user；压缩时重写的旧工具结果不重发 tool.end；连续调用的请求开始；init 重跑不动 settings；K7 分拒绝与按停止；内部 agent、API 重试、origin.kind、轮里插话；项目级多仓各记各的、projects pick。
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
# 全采正文默认开（用户 09-16）。下面这一大批断言钉的是「只带元数据」那个形态——它现在是 capture_content=0 的行为，
# 仍然是支持的模式，显式关掉开关跑；全采的端到端在最后一节单测
mkdir -p "$VT_HOME"; printf 'capture_content=0\n' > "$VT_HOME/config"
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

echo "════ 7. 子 agent 文件：09-16 起不挂 SubagentStart / SubagentStop，起止与「写完了」都看父会话里的信号（Stop 时一起读）════"
mkdir -p "$TDIR/$SID/subagents"
printf '%s\n' '{"agentType":"general-purpose","description":"查","spawnDepth":1,"toolUseId":"toolu_x"}' > "$TDIR/$SID/subagents/agent-s1.meta.json"
{ rec s1u "" P1 user '"查一下"' '{"agentId":"s1","isSidechain":true}' | jq -c '.parentUuid = null'
  rec s1a s1u P1 assistant '[]' '{"agentId":"s1","isSidechain":true,"message":{"id":"sm1","model":"claude-sonnet-5","role":"assistant","content":[{"type":"tool_use","id":"st1","name":"Bash","input":{"command":"ls"}}]}}'
  rec s1d s1a P1 user '[{"type":"tool_result","tool_use_id":"st1","content":"Permission to use Bash with command ls has been denied.","is_error":true}]' '{"agentId":"s1","isSidechain":true}'
} > "$TDIR/$SID/subagents/agent-s1.jsonl"
hook Stop "$(payload Stop)"
check "子 agent 的拒绝进 spool，实例 s1、父实例 main、parent_call_id 取 meta" 'cat "$SPOOL"/*-agent-s1.jsonl 2>/dev/null | jq -s -e "map(select(.provenance.rule_version == \"diverge-v1\")) | length == 2 and all(.[]; .agent_instance_id == \"s1\" and .parent_agent_instance_id == \"main\" and .parent_call_id == \"toolu_x\")" >/dev/null'
check "子 agent 起：文件第一条记录出 subagent.start（类型、任务取 meta）；父会话里还没有它的调用结果，那次模型调用先不写出" \
    'cat "$SPOOL"/*-agent-s1.jsonl 2>/dev/null | jq -s -e "(map(select(.type == \"subagent.start\")) | length == 1 and .[0].payload == {agent_type: \"general-purpose\", task: \"查\"} and .[0].parent_call_id == \"toolu_x\") and (map(select(.type == \"message.assistant\")) | length == 0)" >/dev/null'
# 同步 agent 结束：父会话里出现派它的那次 Agent 调用的结果（带 agentId、status、耗时、token）
rec s1done u5 prompt-5 user '[{"type":"tool_result","tool_use_id":"toolu_x","content":[{"type":"text","text":"查不了"}]}]' \
    '{"toolUseResult":{"status":"completed","agentId":"s1","agentType":"general-purpose","content":[{"type":"text","text":"查不了"}],"totalDurationMs":1200,"totalTokens":300,"totalToolUseCount":1}}' >> "$TR"
hook Stop "$(payload Stop)"
check "父会话里有了调用结果：subagent.end 记在主会话那一块（实例 s1、父 main、调用 toolu_x、completed、耗时与 token）" \
    'cat "$SPOOL"/*-main.jsonl | jq -s -e "map(select(.type == \"subagent.end\" and .agent_instance_id == \"s1\")) | length == 1 and .[0].parent_call_id == \"toolu_x\" and .[0].payload.status.code == \"completed\" and .[0].extensions[\"vibetrail.agent\"] == {duration_ms: 1200, total_tokens: 300, tool_use_count: 1}" >/dev/null'
check "子 agent 的那次模型调用这时写出：实例 s1、不带正文；被拒的调用不伪造 tool.end" 'cat "$SPOOL"/*-agent-s1.jsonl 2>/dev/null | jq -s -e "map(select(.provenance.rule_version == \"call-v1\")) | length == 1 and .[0].type == \"message.assistant\" and .[0].agent_instance_id == \"s1\" and .[0].content_state == \"omitted\" and (.[0].payload | has(\"text\") | not) and .[0].extensions[\"vibetrail.call\"].tool_calls == [\"Bash\"]" >/dev/null'
check "完成信号记进 state/<sid>/agents.json" 'jq -e ".done.s1 == \"2026-09-15T12:00:00.000Z\" and .calls_done.toolu_x != null" "$VT_HOME/state/$SID/agents.json" >/dev/null'

# 并行的另一个子 agent s2 是后台派出的（调用结果当场返回 isAsync），它的一次调用只写了一半（2.1.260 边生成边执行工具：tool_use 一个一个写，结果夹在中间）
printf '%s\n' '{"agentType":"general-purpose","description":"并行","spawnDepth":1,"toolUseId":"toolu_y"}' > "$TDIR/$SID/subagents/agent-s2.meta.json"
rec s2launch s1done prompt-5 user '[{"type":"tool_result","tool_use_id":"toolu_y","content":"Async agent launched"}]' \
    '{"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"s2","description":"并行","outputFile":"/tmp/s2.output"}}' >> "$TR"
{ rec s2u "" P1 user '"并行查"' '{"agentId":"s2","isSidechain":true}' | jq -c '.parentUuid = null'
  rec s2a s2u P1 assistant '[]' '{"agentId":"s2","isSidechain":true,"message":{"id":"sm2","model":"claude-sonnet-5","role":"assistant","content":[{"type":"tool_use","id":"s2t1","name":"Read","input":{"file_path":"calc.py"}}]}}'
  rec s2r s2a P1 user '[{"type":"tool_result","tool_use_id":"s2t1","content":"def add"}]' '{"agentId":"s2","isSidechain":true}'
} > "$TDIR/$SID/subagents/agent-s2.jsonl"
hook Stop "$(payload Stop)"
check "还在跑的子 agent：读到一半的那次调用先不写，工具结果照写" 'cat "$SPOOL"/*-agent-s2.jsonl 2>/dev/null | jq -s -e "map(select(.provenance.rule_version == \"call-v1\") | .type) == [\"tool.end\"]" >/dev/null'
check "后台派出的 s2：subagent.start 只有一条（父会话的启动结果与子 agent 文件第一条是同一个事件，先到的算）" \
    'cat "$SPOOL"/*.jsonl | jq -s -e "map(select(.type == \"subagent.start\" and .agent_instance_id == \"s2\")) | length == 1 and .[0].parent_call_id == \"toolu_y\" and .[0].payload.task == \"并行\"" >/dev/null'
{ rec s2b s2r P1 assistant '[]' '{"agentId":"s2","isSidechain":true,"message":{"id":"sm2","model":"claude-sonnet-5","role":"assistant","content":[{"type":"tool_use","id":"s2t2","name":"Grep","input":{"pattern":"add"}}]}}'
  rec s2s s2b P1 user '[{"type":"tool_result","tool_use_id":"s2t2","content":"calc.py:1"}]' '{"agentId":"s2","isSidechain":true}'
  rec s2c s2s P1 assistant '[]' '{"agentId":"s2","isSidechain":true,"message":{"id":"sm3","model":"claude-sonnet-5","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"查完了。"}]}}'
} >> "$TDIR/$SID/subagents/agent-s2.jsonl"
check "后台 agent 还没发完成通知：Stop 时它最后那次回答先不写出" \
    'hook Stop "$(payload Stop)"; ! cat "$SPOOL"/*-agent-s2.jsonl | jq -e "select(.extensions[\"vibetrail.call\"].response_id == \"sm3\")" >/dev/null'
# 后台 agent 跑完：父会话里来一条 <task-notification>（模型空闲时是 origin.kind = task-notification 的 user 记录）
NOTE_S2=$(jq -n -c '"<task-notification>\n<task-id>s2</task-id>\n<tool-use-id>toolu_y</tool-use-id>\n<status>completed</status>\n<summary>Agent \"并行\" completed</summary>\n<result>查完了。</result>\n</task-notification>"')
rec s2note s2launch prompt-5 user "$NOTE_S2" '{"origin":{"kind":"task-notification"}}' >> "$TR"
hook Stop "$(payload Stop)"
check "s2 结束后：夹着工具结果的那次调用仍是一条、两个工具都在，最后一次回答也写出" 'cat "$SPOOL"/*-agent-s2.jsonl 2>/dev/null | jq -s -e "map(select(.type == \"message.assistant\" and .provenance.rule_version == \"call-v1\") | .extensions[\"vibetrail.call\"].tool_calls) == [[\"Read\", \"Grep\"], []]" >/dev/null'
check "通知出 subagent.end（实例 s2、调用 toolu_y、completed）" \
    'cat "$SPOOL"/*.jsonl | jq -s -e "map(select(.type == \"subagent.end\" and .agent_instance_id == \"s2\")) | length == 1 and .[0].parent_call_id == \"toolu_y\" and .[0].payload.status.code == \"completed\"" >/dev/null'
# s2 被续上（SendMessage）又开始写：记录时间晚于上一次完成信号，续上的那次调用写一半时不写出。SendMessage 自己的结果（resumedAgentId）不是完成信号
{ rec s2v s2c P1 user '"再查一个"' '{"agentId":"s2","isSidechain":true,"timestamp":"2026-09-15T12:05:00.000Z"}'
  rec s2w s2v P1 assistant '[]' '{"agentId":"s2","isSidechain":true,"timestamp":"2026-09-15T12:05:01.000Z","message":{"id":"sm4","model":"claude-sonnet-5","role":"assistant","content":[{"type":"thinking","thinking":"…"}]}}'
} >> "$TDIR/$SID/subagents/agent-s2.jsonl"
rec smsg s2note prompt-5 user '[{"type":"tool_result","tool_use_id":"toolu_sm","content":"sent"}]' \
    '{"timestamp":"2026-09-15T12:05:00.000Z","toolUseResult":{"success":true,"message":"再查一个","resumedAgentId":"s2"}}' >> "$TR"
hook Stop "$(payload Stop)"
check "s2 被续上、调用写了一半：不写出" '! cat "$SPOOL"/*-agent-s2.jsonl | jq -e "select(.extensions[\"vibetrail.call\"].response_id == \"sm4\")" >/dev/null'
rec s2x s2w P1 assistant '[]' '{"agentId":"s2","isSidechain":true,"timestamp":"2026-09-15T12:05:30.000Z","message":{"id":"sm4","model":"claude-sonnet-5","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"也查完了。"}]}}' >> "$TDIR/$SID/subagents/agent-s2.jsonl"
# 这次的完成通知赶上模型在忙：是 queued_command 附件的形态
jq -n -c --arg sid "$SID" --arg cwd "$REPO" '{type: "attachment", uuid: "s2note2", parentUuid: "smsg", sessionId: $sid, cwd: $cwd, timestamp: "2026-09-15T12:06:00.000Z",
    attachment: {type: "queued_command", commandMode: "task-notification", prompt: "<task-notification>\n<task-id>s2</task-id>\n<tool-use-id>toolu_y</tool-use-id>\n<status>completed</status>\n</task-notification>"}}' >> "$TR"
hook Stop "$(payload Stop)"
check "续上的这段结束后：那次调用完整写出（thinking 与回答合成一条）" 'cat "$SPOOL"/*-agent-s2.jsonl | jq -s -e "map(select(.extensions[\"vibetrail.call\"].response_id == \"sm4\")) | length == 1 and .[0].extensions[\"vibetrail.call\"].stop_reason == \"end_turn\" and .[0].extensions[\"vibetrail.call\"].thinking == true" >/dev/null'
check "两次完成通知，subagent.end 仍只有一条；state 里记的是较晚那次" \
    '[ "$(cat "$SPOOL"/*.jsonl | jq -s "map(select(.type == \"subagent.end\" and .agent_instance_id == \"s2\")) | length")" = 1 ] && jq -e ".done.s2 == \"2026-09-15T12:06:00.000Z\"" "$VT_HOME/state/$SID/agents.json" >/dev/null'
check "子 agent 这一节没有错误日志" '[ ! -s "$VT_HOME/logs/errors.log" ]'

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
printf 'scope=user\ncapture_content=0\n' > "$VT_HOME/config"
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
check "doctor：只有 HOME 挂着时说「只挂在一处」" \
    'o=$(vdoc); printf "%s" "$o" | grep -q "hook 只挂在一处" && ! printf "%s" "$o" | grep -q "重复挂载"'
mkdir -p "$REPO/.claude"; jq '{hooks: {Stop: .hooks.Stop}}' "$IS/.claude/settings.json" > "$REPO/.claude/settings.local.json"
check "doctor：项目级 settings 里也挂了一份 Stop → 报重复挂载，并把两份文件都点名" \
    'o=$(vdoc); printf "%s" "$o" | grep -q "hook 重复挂载：Stop（2 条" && printf "%s" "$o" | grep -q "$REPO/.claude/settings.local.json"'
rm -f "$REPO/.claude/settings.local.json"; rmdir "$REPO/.claude" 2>/dev/null
check "doctor：同一份 settings 里同一事件挂了两条（同 matcher）也算重复" \
    'jq ".hooks.Stop += .hooks.Stop" "$IS/.claude/settings.json" > "$IS/.claude/s.tmp" && cp "$IS/.claude/settings.json" "$IS/.claude/s.bak" \
     && mv "$IS/.claude/s.tmp" "$IS/.claude/settings.json"; o=$(vdoc); mv "$IS/.claude/s.bak" "$IS/.claude/settings.json"
     printf "%s" "$o" | grep -q "hook 重复挂载：Stop（2 条"'
# 全局开关：这两个为真时 hook 一次都不触发，而且从我们这边看不出来（spool 不涨、也没有错误日志）
check "doctor：用户设置里 disableAllHooks: true → 致命项" \
    'cp "$IS/.claude/settings.json" "$IS/.claude/s.bak" && jq ". + {disableAllHooks: true}" "$IS/.claude/s.bak" > "$IS/.claude/settings.json"
     o=$(vdoc); cp "$IS/.claude/s.bak" "$IS/.claude/settings.json"; rm -f "$IS/.claude/s.bak"
     printf "%s" "$o" | grep -q "本机 hook 被全局关掉" && printf "%s" "$o" | grep -q "有致命项"'
printf '{"allowManagedHooksOnly": true}\n' > "$T/fake-managed.json"
check "doctor：企业托管设置里 allowManagedHooksOnly: true → 致命项（HOME 里的条目一律被忽略）" \
    'o=$( cd "$REPO" && VIBETRAIL_HOME=$IS/.vibetrail VIBETRAIL_CLAUDE_SETTINGS=$IS/.claude/settings.json \
          VIBETRAIL_CLAUDE_MANAGED=$T/fake-managed.json bash "$SELF/vibetrail" doctor 2>&1 )
     printf "%s" "$o" | grep -q "只跑托管 hook" && printf "%s" "$o" | grep -q "有致命项"'
# 判据一律先把输出接住再 grep：写成 `vdoc | grep -q …` 的话，grep -q 命中就提前关掉管道，
# doctor 吃到 SIGPIPE 非零退出，pipefail 下整条被判成失败（先踩了一次）
check "doctor：两个开关都没设时说「没有全局开关挡着」，且退出码为 0" \
    'o=$(vdoc); rc=$?; printf "%s" "$o" | grep -q "没有全局开关挡着" && [ "$rc" = 0 ]'
vcli uninstall
check "uninstall 之后回到原样，原样那份备份没被覆盖" 'jq -e ". == {model: \"opus\"}" "$IS/.claude/settings.json" >/dev/null && jq -e ". == {model: \"opus\"}" "$IS/.vibetrail/backup/settings.json.before-vibetrail" >/dev/null 2>&1'

echo "════ 14. K7：「User rejected tool use」是人拒绝还是按停止——先按 permissionMode 粗分，挂上 PermissionRequest 后看弹没弹过框 ════"
# 场景：人问一句 → 模型跑一个 Bash → 该调用得到「The user doesn't want to proceed…」→ 「[Request interrupted by user for tool use]」→ Stop。
# 两种来历写进 transcript 的逐字一样；时间戳取「现在」前后，PermissionRequest 的证据（hook 当场记的时间）才落在时间窗里
k7case(){ # k7case <会话后缀> <permissionMode> <permission_request_since：空=没挂上> <弹没弹过框 0/1> [整行配置，如 permission_request_periods=…]
    local sid0=$SID tr0=$TR t0 t1 t2
    SID=77777777-0000-4000-8000-00000000000$1; TR=$TDIR/$SID.jsonl; K7SPOOL=$VT_HOME/spool/$PKEY/$SID
    t0=$(jq -n -r 'now - 3 | todate'); t1=$(jq -n -r 'now - 1 | todate'); t2=$(jq -n -r 'now | todate')
    grep -v '^permission_request_' "$VT_HOME/config" > "$VT_HOME/config.tmp"; mv "$VT_HOME/config.tmp" "$VT_HOME/config"
    [ -n "$3" ] && printf 'permission_request_since=%s\n' "$3" >> "$VT_HOME/config"
    [ -n "${5:-}" ] && printf '%s\n' "$5" >> "$VT_HOME/config"
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

# K15④ 方案 A（用户 09-16：「不重算，当时判什么就什么」）：第一次判出的结论存进 state/<sid>/splits.json，重读沿用。
# 这里把会让结论翻的三件事一起做了——配置清空（重跑 init 没登记 PermissionRequest）、弹框证据没了（两周清 / uninstall 删）、
# 迫使从头重读（像重装后补采）——同一次按停止仍然只有按停止那一条，不会冒出一条「人拒绝」
k7case 5 default "$(( $(date +%s) - 60 ))" 0
K5SID=77777777-0000-4000-8000-000000000005; K5S=$VT_HOME/state/$K5SID; K5SPOOL=$VT_HOME/spool/$PKEY/$K5SID
check "K15④: 第一次判出按停止，结论记进 splits.json" \
    '[ "$(jq -r "[.[]] | map(.by) | join(\",\")" "$K5S/splits.json" 2>/dev/null)" = "permission_request" ]'
grep -v '^permission_request_' "$VT_HOME/config" > "$VT_HOME/config.tmp"; mv "$VT_HOME/config.tmp" "$VT_HOME/config"
rm -rf "$K5S/perms" "$K5S/main.json" "$K5S/main.seen"
sid0=$SID; tr0=$TR; SID=$K5SID; TR=$TDIR/$K5SID.jsonl
hook Stop "$(payload Stop '{"prompt_id":"pk7"}')"
SID=$sid0; TR=$tr0
check "K15④: 配置清空、证据删掉、从头重读之后，仍然只有那一条按停止，没有冒出 permission.decision" \
    '[ "$(cat "$K5SPOOL"/*.jsonl | jq -s -c "[(map(select(.type == \"permission.decision\")) | length), (map(select(.type == \"turn.end\" and .extensions[\"vibetrail.kind\"] == \"interrupt_tool\")) | length)]")" = "[0,1]" ]'
# K15④：挂载时间段——PermissionRequest 挂过的那段已经结束，但拒绝发生在段内，照样按弹框证据判（老的单一 since 被清空后会退到粗猜）
now5=$(date +%s)
# 段的终点给到 30 秒之后：写成 now5 的话，拒绝记录的时间（按秒取整）跨过一秒就正好落在终点上、不算段内，测试偶发变红（09-16 踩到）
k7case 6 default "" 0 "permission_request_periods=$(( now5 - 60 ))-$(( now5 + 30 ))"
check "K15④: 段已结束、拒绝在段内：按证据判成按停止（不是 default 模式粗猜的人拒绝）" \
    '[ "$(k7ev "[(map(select(.type == \"permission.decision\")) | length), ($stopped | .[0].extensions[\"vibetrail.split_by\"])]")" = "[0,\"permission_request\"]" ]'
grep -v '^permission_request_' "$VT_HOME/config" > "$VT_HOME/config.tmp"; mv "$VT_HOME/config.tmp" "$VT_HOME/config"

echo "════ 15. 退役的 8 个 hook 事件（没重跑 init 的旧条目）什么都不做；两家都没解决、我们自己修的：K7 两处补充、API 重试与 origin.kind（U15）、轮里插话（K10）、调用 id ════"
# 用户 09-16 定只挂 5 个 hook。旧条目在重跑 init 之前还会调进来：它们能给的已经从 transcript 推出来了，再写就是两条
nsp0=$(cat "$SPOOL"/*.jsonl | wc -l | tr -d ' '); nst0=$(find "$VT_HOME/state/$SID" -type f | wc -l | tr -d ' ')
hook SubagentStart "$(payload SubagentStart '{"agent_id":"s9","agent_type":"general-purpose"}')"
hook SubagentStop "$(payload SubagentStop '{"agent_id":"s9","agent_type":"general-purpose"}')"
hook SubagentStop "$(payload SubagentStop '{"agent_id":"ainternal1","agent_type":""}')"
hook Notification "$(payload Notification '{"notification_type":"idle_prompt"}')"
hook PostToolUseFailure "$(payload PostToolUseFailure '{"tool_name":"Bash","tool_use_id":"tx","error":"boom","is_interrupt":true}')"
hook PermissionDenied "$(payload PermissionDenied '{"tool_name":"Bash","tool_use_id":"ty","reason":"classifier"}')"
hook StopFailure "$(payload StopFailure '{"error":"rate_limit","prompt_id":"prompt-5"}')"
hook InstructionsLoaded "$(payload InstructionsLoaded '{"file_path":"/tmp/CLAUDE.md","load_reason":"session_start"}')"
hook CwdChanged "$(payload CwdChanged '{"old_cwd":"/a","new_cwd":"/b"}')"
check "退役的事件：spool 不多一条、state 不多一个文件、没有错误日志" \
    '[ "$(cat "$SPOOL"/*.jsonl | wc -l | tr -d " ")" = "$nsp0" ] && [ "$(find "$VT_HOME/state/$SID" -type f | wc -l | tr -d " ")" = "$nst0" ] && [ ! -s "$VT_HOME/logs/errors.log" ]'
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
echo "════ 17. 09-16 复核修补（K14 / K15 / K16，OPEN-ISSUES）：独立沙箱 home，不依赖前面各节的状态 ════"
K=$T/k-home; KP=$K/claude/projects/$(vt_slug "$REPO"); mkdir -p "$K/.claude" "$KP"
KSID=11111111-2222-4333-8444-555555555555
jq -c --arg cwd "$REPO" '.steps[] | select(.append) | .append | .cwd = $cwd' "$SC" > "$KP/$KSID.jsonl"
kcli(){ ( cd "$REPO" && VIBETRAIL_HOME=$K/.vibetrail VIBETRAIL_CLAUDE_SETTINGS=$K/.claude/settings.json \
          VIBETRAIL_CLAUDE_PROJECTS=$K/claude/projects bash "$SELF/vibetrail" "$@" 2>&1 ); }
kevents(){ find "$K/.vibetrail/spool" -name '*.jsonl' ! -name '.*' -exec cat {} + 2>/dev/null | grep -c .; }

# K15①：session.start 的 capabilities 带 tool.end（D8 加调用 trace 时漏了）
k15a(){ node --input-type=module -e '
import { hookEvents } from "'"$SELF"'/lib/hook.mjs";
const e = hookEvents("SessionStart", { session_id: "s" }, { now: "2026-09-16T00:00:00.000Z", project_id: "p", workspace_id: "w", vt_version: "v", vcs: null });
process.exit(e.length === 1 && e[0].payload.capabilities.includes("tool.end") ? 0 : 1);'; }
check "K15①: session.start 的 capabilities 带 tool.end" 'k15a'

# K16①：条目命令写成 sh '…/vibetrail-hook' <事件> 2>/dev/null || true；老写法 /bin/bash '…' 重跑 init 换掉、不翻倍；doctor 认新写法
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/bash %s Stop","timeout":120}]}]}}\n' "'$K/.vibetrail/bin/vibetrail-hook'" > "$K/.claude/settings.json"
kcli init >/dev/null
cmds=$(jq -r '[.hooks[][]?.hooks[]?.command] | .[]' "$K/.claude/settings.json")
n_all=$(printf '%s\n' "$cmds" | grep -c vibetrail-hook); n_new=$(printf '%s\n' "$cmds" | grep -c -E "^sh '.*vibetrail-hook' [A-Za-z]+ 2>/dev/null \|\| true$")
check "K16①: 条目命令全是 sh '…' <事件> 2>/dev/null || true，老的 /bin/bash 写法被换掉而不是并存" \
    '[ "$n_all" -gt 0 ] && [ "$n_all" = "$n_new" ] && [ "$(printf "%s\n" "$cmds" | grep -c "^/bin/bash")" = 0 ]'
check "K16①: 换写法后 Stop 只挂一条（没有新旧两条并存）" \
    '[ "$(jq "[.hooks.Stop[]?.hooks[]? | select(.command | contains(\"vibetrail-hook\"))] | length" "$K/.claude/settings.json")" = 1 ]'
check "K16①: doctor 认得新写法（命令指向的脚本在、条目齐）" \
    'o=$(kcli doctor); ! printf "%s" "$o" | grep -q "条目指向的运行时不存在" && printf "%s" "$o" | grep -q "hook 条目："'

# K16②：宿主写完 payload 却不关 stdin，hook 1 秒空闲就当读完退出，不会挂到 Claude Code 的 timeout
k16b(){ python3 - "$SELF" <<'PYEOF'
import subprocess, sys, time
t = time.time()
p = subprocess.Popen(['bash', sys.argv[1] + '/vibetrail-hook', 'Notification'],
                     stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
p.stdin.write(b'{"session_id":"k16","hook_event_name":"Notification","cwd":"/nonexistent"}'); p.stdin.flush()   # 故意不关
try:
    p.wait(timeout=6); sys.exit(0 if time.time() - t < 4 else 1)
except subprocess.TimeoutExpired:
    p.kill(); sys.exit(1)
PYEOF
}
check "K16②: stdin 写完不关，hook 照样在 4 秒内退出" 'k16b'

# K14：uninstall 留下 state/*/ids；重装后补做不把老会话再写一遍，spool 条数不翻倍
kcli projects add >/dev/null; kcli sync >/dev/null
n1=$(kevents)
kcli uninstall >/dev/null
check "K14: uninstall 后 spool 与 ids 还在，state 里别的删了" \
    '[ "$(kevents)" = "$n1" ] && [ -f "$K/.vibetrail/state/$KSID/ids" ] && [ ! -e "$K/.vibetrail/state/$KSID/main.json" ]'
kcli init >/dev/null; kcli sync >/dev/null
check "K14: 重装再补做，spool 条数不变（$n1 条，没有翻倍）" '[ "$n1" -gt 0 ] && [ "$(kevents)" = "$n1" ]'

# K15③：state/<sid>/ 30 天没动、spool 里也没有它的待发块，补做时整个删掉；有待发块的留着（ids 还要挡重复）
mkdir -p "$K/.vibetrail/state/stale-sid" "$K/.vibetrail/state/kept-sid" "$K/.vibetrail/spool/x/kept-sid"
echo '{}' > "$K/.vibetrail/state/stale-sid/main.json"; echo '{}' > "$K/.vibetrail/state/kept-sid/main.json"
echo '{"type":"x"}' > "$K/.vibetrail/spool/x/kept-sid/20260801T000000Z-1-main.jsonl"
for d in stale-sid kept-sid; do perl -e 'utime(time - 40*86400, time - 40*86400, @ARGV)' "$K/.vibetrail/state/$d/main.json" "$K/.vibetrail/state/$d"; done
kcli sync >/dev/null
check "K15③: 40 天没动、没有待发块的会话目录被清掉；有待发块的留着" \
    '[ ! -e "$K/.vibetrail/state/stale-sid" ] && [ -d "$K/.vibetrail/state/kept-sid" ] && [ -d "$K/.vibetrail/state/$KSID" ]'

echo "════ 18. 只挂 5 个 hook（用户 09-16 定）：init 登记的事件、旧条目的清理、doctor 的提示 ════"
H=$T/h5-home; mkdir -p "$H/.claude"
OLD13="SessionStart UserPromptSubmit Stop SubagentStop SessionEnd Notification SubagentStart PostToolUseFailure PermissionRequest PermissionDenied StopFailure InstructionsLoaded CwdChanged"
# 老版本装出来的 settings：13 个事件，外加一条别人的 hook（要原样留着）
jq -n --arg hk "$H/.vibetrail/bin/vibetrail-hook" --arg evs "$OLD13" '
  {model: "opus", hooks: (($evs | split(" ")) | map({key: ., value: [{hooks: [{type: "command", command: ("sh '"'"'" + $hk + "'"'"' " + . + " 2>/dev/null || true"), timeout: 30, async: true}]}]}) | from_entries)}
  | .hooks.Stop += [{hooks: [{type: "command", command: "echo other-tool"}]}]' > "$H/.claude/settings.json"
hcli(){ ( cd "$REPO" && VIBETRAIL_HOME=$H/.vibetrail VIBETRAIL_CLAUDE_SETTINGS=$H/.claude/settings.json VIBETRAIL_CLAUDE_PROJECTS=$H/claude/projects bash "$SELF/vibetrail" "$@" 2>&1 ); }
hcli init --events all >/dev/null
check "init：只登记 SessionStart / UserPromptSubmit / Stop / SessionEnd / PermissionRequest，旧的 8 个事件条目去掉" \
    '[ "$(jq -c "[.hooks | to_entries[] | select(any(.value[].hooks[]; .command | contains(\"vibetrail-hook\"))) | .key] | sort" "$H/.claude/settings.json")" = "[\"PermissionRequest\",\"SessionEnd\",\"SessionStart\",\"Stop\",\"UserPromptSubmit\"]" ]'
check "init：别的设置与别人的 hook 原样留着，没有留下空的事件键" \
    'jq -e ".model == \"opus\" and ([.hooks.Stop[].hooks[].command] | index(\"echo other-tool\") != null) and (.hooks | keys | length == 5)" "$H/.claude/settings.json" >/dev/null'
check "init：Stop 仍是异步、给足 120 秒；PermissionRequest 异步" \
    'jq -e "(.hooks.Stop[] | select(any(.hooks[]; .command | contains(\"vibetrail-hook\"))) | .hooks[0] | .async == true and .timeout == 120) and (.hooks.PermissionRequest[0].hooks[0].async == true)" "$H/.claude/settings.json" >/dev/null'
o=$(hcli doctor)
check "doctor：5 个都挂上时不提旧事件" '! printf "%s" "$o" | grep -q "还挂着已不用的事件"'
jq --arg hk "$H/.vibetrail/bin/vibetrail-hook" '.hooks.CwdChanged = [{hooks: [{type: "command", command: ("sh '"'"'" + $hk + "'"'"' CwdChanged 2>/dev/null || true"), timeout: 30, async: true}]}]' \
    "$H/.claude/settings.json" > "$H/.claude/s.tmp" && mv "$H/.claude/s.tmp" "$H/.claude/settings.json"
o=$(hcli doctor)
check "doctor：还挂着旧事件（CwdChanged）→ 提示重跑 init，不算致命" \
    'printf "%s" "$o" | grep -q "还挂着已不用的事件：CwdChanged" && ! printf "%s" "$o" | grep -q "缺核心事件"'

echo "════ 19. 上报 token（用户 09-16：init 要引导填）：不在终端里只提示；vibetrail token 存成 600、不回显；终端里 init 问一次，回车 / Ctrl-C 跳过 ════"
TK=$T/token-home; mkdir -p "$TK/.claude" "$TK/projects/$(vt_slug "$REPO")"
printf '{"type":"user","uuid":"tk1","cwd":"%s","sessionId":"tk","timestamp":"2026-09-16T00:00:00.000Z","message":{"role":"user","content":"hi"}}\n' "$REPO" > "$TK/projects/$(vt_slug "$REPO")/tk.jsonl"
tkcli(){ ( cd "$REPO" && VIBETRAIL_HOME=$TK/.vibetrail VIBETRAIL_CLAUDE_SETTINGS=$TK/.claude/settings.json VIBETRAIL_CLAUDE_PROJECTS=$TK/projects bash "$SELF/vibetrail" "$@" 2>&1 ); }
TOKV=onepaas-test-token-0123456789abcdef
o=$(tkcli init --events all </dev/null)
check "不在终端里跑 init：不问，只提示用 vibetrail token 填，不建 token 文件" \
    'printf "%s" "$o" | grep -q "还没填上报 token" && printf "%s" "$o" | grep -q "vibetrail token" && [ ! -e "$TK/.vibetrail/token" ]'
o=$(printf '%s\n' "$TOKV" | tkcli token)
check "vibetrail token 从管道读：存成 600，输出里只有末 4 位、没有 token 本身" \
    '[ "$(cat "$TK/.vibetrail/token")" = "$TOKV" ] && [ "$(stat -f %Lp "$TK/.vibetrail/token" 2>/dev/null || stat -c %a "$TK/.vibetrail/token")" = 600 ] && ! printf "%s" "$o" | grep -qF "$TOKV" && printf "%s" "$o" | grep -q "末 4 位 cdef"'
o=$(printf 'has space in it\n' | tkcli token); rc=$?
check "不像 token 的（中间有空格）：不存、退出码非零，原来的 token 不动" '[ "$rc" != 0 ] && [ "$(cat "$TK/.vibetrail/token")" = "$TOKV" ]'
o=$(tkcli doctor)
check "doctor：报 token 已填，只露末 4 位" 'printf "%s" "$o" | grep -q "上报 token 已填（末 4 位 cdef）" && ! printf "%s" "$o" | grep -qF "$TOKV"'
chmod 644 "$TK/.vibetrail/token"; o=$(tkcli doctor); chmod 600 "$TK/.vibetrail/token"
check "doctor：token 文件别人也能读 → 告警" 'printf "%s" "$o" | grep -q "别人也能读（权限 644）"'
o=$(tkcli init --events all </dev/null)
check "已经填过：init 说已填，不再提示去填" 'printf "%s" "$o" | grep -q "上报 token 已填（末 4 位 cdef" && ! printf "%s" "$o" | grep -q "还没填上报 token"'
tkcli uninstall >/dev/null
check "uninstall（不带 --purge）留着 token，与 config 一样" '[ "$(cat "$TK/.vibetrail/token")" = "$TOKV" ]'
o=$(tkcli token --clear)
check "token --clear 删掉" '[ ! -e "$TK/.vibetrail/token" ]'

# 终端里：用 pty 真跑（python3 自带 pty 模块）。场景：init 问 token 时粘贴、token 时按 Ctrl-C、projects pick 敲编号回车
tk_pty(){ python3 - "$SELF" "$TK" "$REPO" "$TOKV" "$1" <<'PYEOF'
import os, pty, select, subprocess, sys, time
self_dir, home, repo, tok, scenario = sys.argv[1:6]
env = dict(os.environ, VIBETRAIL_HOME=home + '/.vibetrail', VIBETRAIL_CLAUDE_SETTINGS=home + '/.claude/settings.json',
           VIBETRAIL_CLAUDE_PROJECTS=home + '/projects')
args, wait_for, key = {
    'init': (['init', '--events', 'all'], '直接回车跳过：', tok.encode() + b'\r'),
    'ctrlc': (['token'], '直接回车跳过：', b'\x03'),
    'pick': (['projects', 'pick'], '直接回车不改：', b'1\r'),
}[scenario]
m, s = pty.openpty()
p = subprocess.Popen(['bash', self_dir + '/vibetrail', *args], stdin=s, stdout=s, stderr=s, env=env, cwd=repo, close_fds=True)
os.close(s)
out, sent, end = b'', False, time.time() + 30
while time.time() < end:
    if not sent and wait_for.encode() in out:
        os.write(m, key); sent = True
    r, _, _ = select.select([m], [], [], 0.05)
    if r:
        try:
            chunk = os.read(m, 65536)
        except OSError:
            chunk = b''
        if not chunk:
            break
        out += chunk
if p.poll() is None:
    p.kill(); print('还没退出（输入之后卡住）'); sys.exit(1)
text = out.decode('utf8', 'replace')
f = home + '/.vibetrail/token'
if not sent:
    print('没等到提示'); sys.exit(1)
if p.returncode != 0:
    print('退出码', p.returncode); sys.exit(1)
if scenario == 'init':
    ok = os.path.exists(f) and open(f).read().strip() == tok and tok not in text and (os.stat(f).st_mode & 0o777) == 0o600
elif scenario == 'ctrlc':
    ok = '没填，跳过' in text and not os.path.exists(f)
else:
    ok = '✓ 登记' in text or '已经登记过' in text
if not ok:
    print(text[-600:]); sys.exit(1)
PYEOF
}
check "终端里 init：没填过就问一次，粘贴的 token 不回显，存成 600" 'tk_pty init'
tkcli token --clear >/dev/null
check "终端里 vibetrail token 按 Ctrl-C：当跳过，退出码 0，不留文件（终端复原由 node 退出时做）" 'tk_pty ctrlc'
check "终端里 projects pick 敲编号回车就返回（原先读到 EOF 才返回，要再按 Ctrl-D）" 'tk_pty pick'

echo "════ 20. 使用前的准备（DEMO §0）：node 版本不够时命令行明说；config 里记的旧 node 不够就退到 PATH 里的 ════"
NV=$T/node-gate; mkdir -p "$NV/old/bin" "$NV/vt"
printf '#!/bin/sh\necho v18.19.0\n' > "$NV/old/bin/node"; chmod +x "$NV/old/bin/node"
o=$(VIBETRAIL_HOME=$NV/vt PATH="$NV/old/bin:/usr/bin:/bin" sh "$SELF/vibetrail" version 2>&1); rc=$?
check "PATH 里只有 node 18：退出码非零，说清是哪个 node、什么版本、要 ≥ 20" \
    '[ "$rc" != 0 ] && printf "%s" "$o" | grep -q "node 版本太低" && printf "%s" "$o" | grep -q "v18.19.0" && printf "%s" "$o" | grep -q "≥ 20"'
printf 'node=%s\n' "$NV/old/bin/node" > "$NV/vt/config"
o=$(VIBETRAIL_HOME=$NV/vt sh "$SELF/vibetrail" version 2>&1); rc=$?
check "config 里记的是旧 node、PATH 里有新的：退到 PATH 里的照常跑（否则重跑 init 也绕不出来）" \
    '[ "$rc" = 0 ] && printf "%s" "$o" | grep -q "^vibetrail "'

check "测试没有动真实的 settings.json（${REAL_SETTINGS}）" '[ "$( { cat "$REAL_SETTINGS" 2>/dev/null || true; } | cksum)" = "$REAL_SUM" ]'
echo
[ "$skipped_schema" -gt 0 ] && echo "  ⚠ 本机 python3 没有 jsonschema，协议 schema 校验跳过 $skipped_schema 处（pip install jsonschema 后重跑）"
if [ $fail -eq 0 ]; then echo "  ✅ $pass/$pass 通过"; else echo "  ❌ $fail 失败 / $pass 通过"; exit 1; fi
