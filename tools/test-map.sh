#!/bin/bash
# 回归：协议映射（分歧一路）。钉四件事——
#   1. 每份 fixture 的事件与 golden（fixtures-map/expect/<名>.jsonl）整条一致；关键字段另有显式断言，golden 漂了也说得出是哪一项
#   2. 每条事件过协议 1.0 schema（schema-check.py，仓内原件）；event_id 唯一且两次运行一致
#   3. A2 进出对账：提取器单独跑出的每类命中数 == 映射出的对应事件数（人拒 → decided_by user，分类器 → policy，
#      链路 → system，打断 → turn.end / subagent.end，for-tool-use → 吸收 + 未配对）
#   4. 增量等价：对每个切点 L，「前 L 行全量扫」∪「全文从 L 起扫」== 「全文全量扫」——派生事件跟触发记录走、去重不看门控，
#      这两条不成立时这里会红；再加一路「从前段账本给的 checkpoint_line（本轮开头）读起」，钉住 U11 的按轮增量
# 用法：test-map.sh [--update [--accept-rule-digest]]   --update 重新生成 golden（先看 diff 再提交）
#   K19 钉子：expect/RULE-DIGESTS 记着每个 rule_version 的输出摘要，golden 变了而版本号没升就红——--update 也不放过，
#   得先升 map.mjs 的 RULE_VERSIONS；确认只是 fixture 变了、映射规则没变时才加 --accept-rule-digest
# 固定 C locale：macOS 自带的 bash 3.2 在 UTF-8 locale 下会把紧跟在变量名后的中文字符首字节算进变量名（变量名后紧跟「）」时，bash 找的是「V 加上「）」的首字节」这个变量），
# 开了 set -u 就报 unbound variable（用户 09-15 的终端踩到），没开就悄悄展开成空；tr / sort 的结果也随 locale 变。放在最前面，后面的解析都按 C
export LC_ALL=C
set -uo pipefail
cd "$(dirname "$0")"; SELF=$PWD; FX=$SELF/fixtures-map
FILES=("$FX"/*.jsonl "$FX"/fx-*/subagents/agent-*.jsonl)
T=$(mktemp -d "${TMPDIR:-/tmp}/vibetrail-test-map.XXXXXX"); trap 'rm -rf "$T"' EXIT
# 映射器的默认 workspace_id 会按第一次见到的工作区生成并持久化到 $VIBETRAIL_HOME/workspaces（K17）：测试一律指到临时目录，不碰真实的 ~/.vibetrail
export VIBETRAIL_HOME=$T/vt; mkdir -p "$VIBETRAIL_HOME"
update=0; accept=0
for a in "$@"; do case "$a" in --update) update=1;; --accept-rule-digest) accept=1;; *) echo "✗ 不认识的参数：$a" >&2; exit 2;; esac; done
fail=0; pass=0
# 协议 schema 校验要 python3 + jsonschema（只在测试里用）；本机没装就跳过这几项并在末尾说明，不算失败
if python3 -c 'import jsonschema' 2>/dev/null; then HAVE_SCHEMA=1; else HAVE_SCHEMA=0; fi
skipped_schema=0
schema_check(){ if [ "$HAVE_SCHEMA" = 1 ]; then python3 "$SELF/schema-check.py"; else cat >/dev/null; skipped_schema=$((skipped_schema+1)); echo "(跳过)"; fi; }
ok(){ pass=$((pass+1)); }
ko(){ fail=$((fail+1)); printf '  ✗ %s\n' "$*"; }
# 断言：jq 表达式对 events 文件（-s 整体）求值必须是 true
check(){ local r; r=$(jq -s "$2" "$3" 2>&1); if [ "$r" = "true" ]; then ok; else ko "$1 （得到 ${r}）"; fi; }
run(){ # run <名> <transcript> [额外参数…] → $T/<名>.events / .ledger；stderr 必须为空
    # project_id / workspace_id 显式给定（后面的参数可以覆盖）：K17 之后默认的 workspace_id 是随机生成的 UUID，golden 钉不住
    local n=$1 f=$2; shift 2
    bash "$SELF/vibetrail-map" "$f" --no-turns --capture-content "${CAP:-0}" --project-id fx --workspace-id ws-fixture --workspace-roots /tmp/fx \
        --ledger "$T/$n.ledger" "$@" > "$T/$n.events" 2> "$T/$n.err" \
        || { ko "$n: vibetrail-map 退出码非零: $(head -c 200 "$T/$n.err")"; return 1; }
    [ -s "$T/$n.err" ] && ko "$n: stderr 非空: $(head -c 200 "$T/$n.err")"
    return 0
}
sids(){ jq -r '.event_id' "$1" | sort; }

echo "════ 1. scenario.json 回放（CAPABILITIES §2.3 那段示例会话）════"
jq -c '.steps[] | select(.append) | .append' "$SELF/../experiments/collect-demo/scenario.json" > "$T/scenario.jsonl"
if run scenario "$T/scenario.jsonl" --sid 11111111-2222-4333-8444-555555555555 --project-id demo --workspace-id /tmp/demo-proj; then
    e=$T/scenario.events
    check "scenario: 恰好 3 条事件" 'length == 3' "$e"
    check "scenario: 被拒的 Bash 带原命令" '[.[] | select(.type=="tool.request")] | length == 1 and .[0].payload.tool_name == "Bash" and (.[0].payload.input.command | startswith("sed -i"))' "$e"
    check "scenario: permission.decision 人拒、拒绝原文、call_id 对上" '[.[] | select(.type=="permission.decision")][0] | .payload.decided_by == "user" and .payload.decision == "deny" and .payload.call_id == "toolu_demo_bash_2" and (.payload.reason | startswith("The user doesn'"'"'t want to proceed"))' "$e"
    check "scenario: 拒绝后人的下一句带上，指回拒绝与打断两条记录" '[.[] | select(.type=="message.user")][0] | .payload.text == "别改 add，那是故意留的" and .payload.author_type == "user" and (.extensions["vibetrail.after"] | length == 2) and .turn_id == "prompt-3"' "$e"
    check "scenario: 会话 / 项目 / 工作区 id 照传入" 'all(.[]; .session_id == "11111111-2222-4333-8444-555555555555" and .project_id == "demo" and .workspace_id == "/tmp/demo-proj")' "$e"
    check "scenario: for-tool-use 被吸收、不另发事件" '.[0]' <(jq -c '.absorbed_for_tool_use == 1 and .unpaired_for_tool_use == 0 and (.events["turn.end"] // 0) == 0' "$T/scenario.ledger")
    schema_check < "$e" > "$T/schema.out" && ok || ko "scenario: $(cat "$T/schema.out")"
fi

echo "════ 2. fixtures：断言 + schema + golden ════"
for f in "${FILES[@]}"; do
    n=$(basename "$f" .jsonl)
    run "$n" "$f" || continue
    e=$T/$n.events; lg=$T/$n.ledger
    schema_check < "$e" > "$T/schema.out" && ok || ko "$n: $(cat "$T/schema.out")"
    # event_id 唯一、且是 v5 形状
    check "$n: event_id 唯一且为 UUIDv5" '(map(.event_id) | length == (unique | length)) and all(.[]; .event_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))' "$e"
    # golden
    g=$FX/expect/$n.jsonl; mkdir -p "$FX/expect"
    jq -S -c . "$e" > "$T/$n.norm"
    if [ $update -eq 1 ]; then cp "$T/$n.norm" "$g"; echo "  ↻ 已更新 $(basename "$g")"
    elif [ ! -f "$g" ]; then ko "$n: 缺 golden $(basename "$g")（跑 --update 生成）"
    elif ! cmp -s "$T/$n.norm" "$g"; then ko "$n: 与 golden 不一致："; diff "$g" "$T/$n.norm" | head -6 | sed 's/^/      /'
    else ok; fi
done


# 逐份的显式断言（golden 之外，说得出是哪一项漂了）
e=$T/interrupt-text.events
check "interrupt-text: 三条——被打断的回复、turn.end、人的下一句" 'map(.type) == ["message.assistant","turn.end","message.user"]' "$e"
check "interrupt-text: 回复正文与 model，指回打断记录" '.[0].payload.text == "我看了一下，问题在 div：" and .[0].payload.model == "claude-opus-5" and .[0].payload.author_type == "agent" and .[0].extensions["vibetrail.trigger"] == "i1" and .[0].content_state == "included"' "$e"
check "interrupt-text: turn.end 状态、用量按 message.id 去重（U12：入含缓存读，total = 入 + 出）、分支" '.[1].payload.status == {code:"interrupted",category:"cancellation",detail:"[Request interrupted by user]"} and .[1].payload.usage == {input_tokens:115,cached_input_tokens:100,output_tokens:20,reasoning_tokens:8,total_tokens:135} and .[1].payload.vcs.branch == "main" and .[1].turn_id == "p1" and .[1].provenance == {kind:"transcript",rule_version:"diverge-v2",source_event_id:"i1"}' "$e"
check "interrupt-text: 人的下一句去掉 system-reminder 块，只留人写的" '.[2].payload.text == "先别看 div" and .[2].extensions["vibetrail.after"] == ["i1"] and .[2].extensions["vibetrail.after_kind"] == "interrupt"' "$e"
check "interrupt-text: raw 里保留提取器原始命中" '.[1].raw.event_name == "diverge.interrupt" and .[1].raw.data.kind == "interrupt" and .[1].raw.data.turn == "i1"' "$e"
e=$T/interrupt-tool.events
check "interrupt-tool: 在跑的工具调用进 tool.request，没有 message.assistant" 'map(.type) == ["tool.request","turn.end","message.user"] and .[0].payload.input.command == "sleep 100" and .[0].payload.call_id == "toolu_1" and .[0].extensions["vibetrail.kind"] == "interrupt"' "$e"
check "interrupt-tool: 沿 parentUuid 越过 tool_result 与 attachment 找到回复" '.[1].extensions["vibetrail.interrupted_uuid"] == "a1" and .[1].payload.model == "claude-opus-5"' "$e"
e=$T/denials.events
check "denials: 8 条 permission.decision——人拒 6、分类器 1、链路 1" '[.[] | select(.type=="permission.decision") | .payload.decided_by] | (map(select(.=="user"))|length) == 6 and (map(select(.=="policy"))|length) == 1 and (map(select(.=="system"))|length) == 1' "$e"
check "denials: 链路故障 decision=error，其余 deny" 'all(.[] | select(.type=="permission.decision"); (.payload.decided_by == "system") == (.payload.decision == "error"))' "$e"
check "denials: 6 个 tool_use 各一条 tool.request，含多行命令" '[.[] | select(.type=="tool.request")] | length == 6 and any(.[]; .payload.input.command == "git push\n# 注释\ngit push --force")' "$e"
check "denials: tool_name 三种来路——索引 6、regex 1（Edit）、缺失 1（unknown）" '[.[] | select(.type=="permission.decision")] | (map(select(.extensions["vibetrail.tool_lookup"]=="index"))|length) == 6 and any(.[]; .extensions["vibetrail.tool_lookup"]=="regex" and .payload.tool_name=="Edit") and any(.[]; .extensions["vibetrail.tool_lookup"]=="missing" and .payload.tool_name=="unknown")' "$e"
check "denials: 三条并行拒绝配一条 for-tool-use，人的下一句指回四条记录" '[.[] | select(.type=="message.user")] | length == 2 and .[0].payload.text == "别开 agent，自己做" and .[0].extensions["vibetrail.after"] == ["d1","d2","d3","f1"] and .[1].payload.text == "对，不要 push" and .[1].extensions["vibetrail.after"] == ["d4"] and .[1].extensions["vibetrail.after_kind"] == "permission_denied"' "$e"
check "denials: 没有 turn.end（for-tool-use 被吸收）" 'all(.[]; .type != "turn.end")' "$e"
check "denials: surface 取自 entrypoint" 'all(.[]; .agent == {name:"claude-code",version:"2.1.260",surface:"claude-desktop"})' "$e"
check "denials: 账本" '.[0]' <(jq -c '.absorbed_for_tool_use == 1 and .lookup == {index:6,regex:1,missing:1} and .in == {permission_denied:6,interrupt_for_tool_use:1,classifier_blocked:1,permission_infra_fail:1}' "$T/denials.ledger")
e=$T/agent-a1.events
check "subagent: 会话 id 取自路径、实例 id 是 agentId、父实例 main、parent_call_id 取 meta" 'all(.[]; .session_id == "fx-sub" and .agent_instance_id == "a1" and .parent_agent_instance_id == "main" and .parent_call_id == "toolu_parent_1")' "$e"
check "subagent: 打断映射成 subagent.end(cancelled)，带 agent_type，不带 usage / vcs" '[.[] | select(.type=="subagent.end")] | length == 1 and .[0].payload == {status:{code:"cancelled",category:"cancellation",detail:"[Request interrupted by user]"},agent_type:"general-purpose"}' "$e"
check "subagent: 拒绝 + 被拒命令 + 被打断的回复都在；派活与注入消息不算人的下一句" 'map(.type) == ["tool.request","permission.decision","message.assistant","subagent.end"] and (.[2].payload.text == "测试跑不了，我读代码。")' "$e"
e=$T/no-promptid.events
check "no-promptid: 没有 promptId 的打断按位置推轮次，provenance 标 inferred" '[.[] | select(.type=="turn.end")] | length == 2 and .[0].turn_id == "i0" and .[0].provenance.kind == "inferred" and .[1].turn_id == "p1" and .[1].provenance.kind == "inferred" and .[1].provenance.rule_version == "diverge-v2"' "$e"
check "no-promptid: 派生事件跟触发记录的轮次走" '[.[] | select(.type=="message.assistant")][0] | .turn_id == "p1" and .provenance.kind == "inferred"' "$e"
check "no-promptid: 两句人话各指回各自的打断" '[.[] | select(.type=="message.user")] | map(.extensions["vibetrail.after"]) == [["i0"],["i1"]]' "$e"
e=$T/unpaired.events
check "unpaired: 没配对的 for-tool-use 不丢——按打断发 turn.end，detail 标明" '[.[] | select(.type=="turn.end")] | length == 1 and (.[0].payload.status.detail | startswith("unpaired interrupt_for_tool_use")) and .[0].extensions["vibetrail.kind"] == "interrupt_for_tool_use"' "$e"
check "unpaired: 账本" '.[0]' <(jq -c '.unpaired_for_tool_use == 1 and .absorbed_for_tool_use == 0' "$T/unpaired.ledger")
e=$T/denied-then-interrupt.events
check "denied-then-interrupt: 拒绝后紧接打断，同一个 tool_use 只发一条 tool.request（去重），回复正文照发" 'map(.type) == ["tool.request","permission.decision","message.assistant","turn.end","message.user"] and .[0].extensions["vibetrail.trigger"] == "d1" and .[2].payload.text == "推了。" and .[3].extensions["vibetrail.interrupted_uuid"] == "a1"' "$e"
check "denied-then-interrupt: 人的下一句指回拒绝与打断" '.[4].extensions["vibetrail.after"] == ["d1","i1"] and .[4].extensions["vibetrail.after_kind"] == "interrupt"' "$e"
check "denied-then-interrupt: 账本记到 1 次去重" '.[0]' <(jq -c '.dedup == 1' "$T/denied-then-interrupt.ledger")
e=$T/noise.events
check "noise: 非对象行、字符串 message、缺字段的块都不炸；只出一条 turn.end" 'length == 1 and .[0].type == "turn.end" and .[0].turn_id == "p1"' "$e"
check "noise: 账本计数" '.[0]' <(jq -c '.skipped_non_object == 3 and .skipped_no_uuid == 1 and .records == 5' "$T/noise.ledger")
check "noise: 没有 parentUuid 的打断按本轮顺序兜底找到回复（曾因行号全是 null 从未生效）" '.[0].extensions["vibetrail.interrupted_uuid"] == "m3"' "$e"
e=$T/edge-cases.events
check "edge: 越过合成记录找到真实回复，model 与用量不含合成记录" '.[0].type == "message.assistant" and .[0].payload.text == "我先删掉安装那一节。" and .[1].payload.model == "claude-opus-5" and .[1].payload.usage == {input_tokens:44,cached_input_tokens:40,output_tokens:9,total_tokens:53} and .[1].extensions["vibetrail.interrupted_uuid"] == "a1"' "$e"
check "edge: 斜杠命令规范成一句发出，标 slash_command，不结束等待" '.[2].type == "message.user" and .[2].payload.text == "/model claude-opus-5" and .[2].extensions["vibetrail.slash_command"] == true and .[2].extensions["vibetrail.after"] == ["i1"]' "$e"
check "edge: 之后打的字照样发，指回同一次打断；本地命令输出不算人话" '.[3].payload.text == "换个模型再试，只删安装那一节" and .[3].extensions["vibetrail.after"] == ["i1"] and (.[3].extensions | has("vibetrail.slash_command") | not) and all(.[]; .payload.text != "<local-command-stdout>Set model to claude-opus-5</local-command-stdout>")' "$e"
check "edge: 缺 message.id 时按 requestId 去重，断链时按本轮顺序兜底" '.[5].type == "turn.end" and .[5].payload.usage == {input_tokens:66,cached_input_tokens:60,output_tokens:12,total_tokens:78} and .[5].extensions["vibetrail.interrupted_uuid"] == "a3" and .[4].payload.text == "好，只删安装一节，其余不动。"' "$e"
check "edge: 共 7 条事件，没认出的新拒绝措辞不发事件" 'length == 7 and all(.[]; .type != "permission.decision")' "$e"
check "edge: 哨兵——有 User rejected tool use 标记而判据没认出，账本记 1；checkpoint 是最后一轮开头" '.[0]' <(jq -c '.sentinel == {marker:1, marker_without_hit:1} and .checkpoint_line == 12' "$T/edge-cases.ledger")
e=$T/injected.events
check "injected: 回复拆成文字与 tool_use 两条记录，按 message.id 拼回——文字与在跑的调用都发" '.[0].type == "message.assistant" and .[0].payload.text == "我先读一下 README。" and .[1].type == "tool.request" and .[1].payload.call_id == "jt1" and .[2].extensions["vibetrail.interrupted_uuid"] == "j-a1b"' "$e"
check "injected: 同一 message.id 先 30 后 10，用量留大的（照 ccusage）" '.[2].payload.usage.output_tokens == 30' "$e"
check "injected: Stop hook 反馈、会话续接摘要不算人话，IDE 标签（独立块、夹在句中）剥掉只留人打的字" '[.[] | select(.type == "message.user") | .payload.text] == ["只改第一段", "还有这里也改"]' "$e"
e=$T/split-reply.events
check "split-reply: 逐步变长的快照留完整的，互不包含的段接起来——不重复也不丢（语料 212 条多段文字里 210 条是快照）" '.[0].type == "message.assistant" and .[0].payload.text == "我先看一下测试日志\n同时看一下最近的改动"' "$e"
check "split-reply: 同一条回复里的两个工具调用都发 tool.request，用量取这条消息里最大的 output" '([.[] | select(.type == "tool.request") | .payload.call_id] | sort) == ["kt1", "kt2"] and ([.[] | select(.type == "turn.end")][0].payload.usage.output_tokens == 31)' "$e"
e=$T/replay.events
check "replay: 回放副本整条跳过，原来的事实各报一次" 'length == 9 and ([.[] | .event_id] | length == (unique | length)) and ([.[] | select(.type == "turn.end")] | map(.provenance.source_event_id) == ["r-i1", "r-i9"])' "$e"
check "replay: 副本里的旧人话不会被当成打断后的下一句；回放后人打的第一句挂在原来的打断上" '[.[] | select(.type == "message.user") | [.payload.text, .extensions["vibetrail.after"]]] == [["先别跑测试，直接看代码", ["r-d1","r-f1"]], ["接着昨天的继续", ["r-i1"]], ["够了", ["r-i9"]]]' "$e"
check "replay: 账本记 7 条副本（所有记录都查，assistant 副本也跳过——trace 与轮次用得到它们），交给下一次的清单是全部 11 条记录的 uuid + 行号" '.[0]' <(jq -c '.replayed == 7 and (.sources | length) == 11 and (.sources | map(.[0]) | index("r-i1") != null) and ([.sources[] | select(.[0] == "r-u1")] == [["r-u1", 1]])' "$T/replay.ledger")
e=$T/agent-b2.events
check "nest: 被子 agent 派出的子 agent，父实例是派它的 b1，不是 main" 'length == 2 and all(.[]; .agent_instance_id == "b2" and .parent_agent_instance_id == "b1" and .parent_call_id == "toolu_spawn_b2" and .session_id == "fx-nest") and .[1].payload.agent_type == "Explore"' "$e"
check "nest: 一级子 agent 的父实例仍是 main" '.[0]' <(jq -c '.parent_instance == "main"' "$T/agent-b1.ledger")

echo "════ 3. A2 对账：提取器单独跑 == 映射出的事件 ════"
for f in "${FILES[@]}" "$T/scenario.jsonl"; do
    n=$(basename "$f" .jsonl); e=$T/$n.events; lg=$T/$n.ledger
    # 提取器逐行判、不认回放副本，按 (记录 uuid, kind) 去重后才是「发生过几次」
    hits=$(jq -c -L "$SELF" -f "$SELF/extract-diverge.jq" "$f" 2>/dev/null | jq -S -s -c 'unique_by([.turn, .kind]) | group_by(.kind) | map({key: .[0].kind, value: length}) | from_entries')
    got=$(jq -S -s -c --argjson lg "$(cat "$lg")" '{
        permission_denied: ([.[] | select(.type=="permission.decision" and .payload.decided_by=="user")] | length),
        classifier_blocked: ([.[] | select(.type=="permission.decision" and .payload.decided_by=="policy")] | length),
        permission_infra_fail: ([.[] | select(.type=="permission.decision" and .payload.decided_by=="system")] | length),
        interrupt: ([.[] | select((.type=="turn.end" or .type=="subagent.end") and .extensions["vibetrail.kind"]=="interrupt")] | length),
        interrupt_for_tool_use: ($lg.absorbed_for_tool_use + $lg.unpaired_for_tool_use)
      } | with_entries(select(.value > 0))' "$e")
    if [ "$hits" = "$got" ]; then ok; else ko "$n: 提取器 $hits ≠ 映射 $got"; fi
    # 提取器命中与 raw.data 逐字一致（A3）
    raws=$(jq -c 'select(.raw != null) | .raw.data' "$e" | jq -s -c 'unique_by(.turn) | sort_by(.turn)')
    want=$(jq -c -L "$SELF" -f "$SELF/extract-diverge.jq" "$f" 2>/dev/null | jq -s -c --argjson lg "$(cat "$lg")" '[.[] | select(.kind != "interrupt_for_tool_use" or $lg.unpaired_for_tool_use > 0)] | unique_by([.turn, .kind]) | sort_by(.turn)')
    if [ "$raws" = "$want" ]; then ok; else ko "$n: raw.data 与提取器输出不一致"; fi
done

echo "════ 4. 增量等价：每个切点 L，前 L 行 ∪ 从 L 起 == 全量 ════"
for f in "${FILES[@]}" "$T/scenario.jsonl"; do
    n=$(basename "$f" .jsonl); N=$(wc -l < "$f" | tr -d ' '); full=$T/$n.norm
    [ -f "$full" ] || jq -S -c . "$T/$n.events" > "$full"
    bad=0
    sid=$(jq -r .sid "$T/$n.ledger"); pid=$(jq -r '.[0].project_id // "x"' -s "$T/$n.events"); wid=$(jq -r '.[0].workspace_id // "x"' -s "$T/$n.events")
    meta=(); [ -f "${f%.jsonl}.meta.json" ] && meta=(--meta "${f%.jsonl}.meta.json")
    par=$(jq -r .parent_instance "$T/$n.ledger")   # 切出来的前段在临时目录里，查不到兄弟文件，父实例照全量那次给
    common=(--no-turns --capture-content 0 --sid "$sid" --parent-instance "$par" --project-id "$pid" --workspace-id "$wid" ${meta[@]+"${meta[@]}"})
    sort "$full" > "$T/full.sorted"; badc=0
    for L in $(seq 1 $((N-1))); do
        head -n "$L" "$f" > "$T/cut.jsonl"
        rm -f "$T/cut.src"
        bash "$SELF/vibetrail-map" "$T/cut.jsonl" "${common[@]}" --ledger "$T/cut.ledger" --sources-out "$T/cut.src" > "$T/a.events" 2> "$T/a.err" || { echo "    $n 切点 ${L}：前段失败 $(head -c 120 "$T/a.err")"; }
        bash "$SELF/vibetrail-map" "$f" "${common[@]}" --from-line "$L" --ledger "$T/b.ledger" > "$T/b.events" 2> "$T/b.err" || { echo "    $n 切点 ${L}：后段失败 $(head -c 120 "$T/b.err")"; }
        cat "$T/a.events" "$T/b.events" | jq -S -c . | sort > "$T/ab.norm"
        if ! cmp -s "$T/ab.norm" "$T/full.sorted"; then bad=$((bad+1)); [ $bad -le 2 ] && { echo "    $n 切点 ${L}："; diff "$T/full.sorted" "$T/ab.norm" | head -4 | cut -c1-160 | sed 's/^/      /'; }; fi
        # U11：后段改从前段账本的 checkpoint_line 读起
        C=$(jq -r .checkpoint_line "$T/cut.ledger"); CB=$(jq -r .checkpoint_byte "$T/cut.ledger")
        bash "$SELF/vibetrail-map" "$f" "${common[@]}" --start-line "$C" --start-byte "$CB" --from-line "$L" --seen-uuids "$T/cut.src" --ledger "$T/c.ledger" > "$T/c.events" 2> "$T/c.err" || { echo "    $n 切点 ${L}：checkpoint 段失败 $(head -c 120 "$T/c.err")"; }
        cat "$T/a.events" "$T/c.events" | jq -S -c . | sort > "$T/ac.norm"
        if ! cmp -s "$T/ac.norm" "$T/full.sorted"; then badc=$((badc+1)); [ $badc -le 2 ] && { echo "    $n 切点 ${L}（从第 $C 行读）："; diff "$T/full.sorted" "$T/ac.norm" | head -4 | cut -c1-160 | sed 's/^/      /'; }; fi
    done
    if [ $bad -eq 0 ]; then ok; else ko "$n: $bad 个切点不等价（共 $((N-1)) 个）"; fi
    if [ $badc -eq 0 ]; then ok; else ko "$n: 从 checkpoint 读起时 $badc 个切点不等价（共 $((N-1)) 个）"; fi
done

echo "════ 5. 尾部半行、幂等 ════"
f=$FX/interrupt-text.jsonl
{ cat "$f"; printf '{"type":"user","uuid":"half","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]},"promptId":"p9"'; } > "$T/half.jsonl"
run half "$T/half.jsonl" --sid interrupt-text && {
    check "半行: 只解析到最后一个换行，consumed < file" '.[0]' <(jq -c '.consumed_bytes < .file_bytes and .lines == 9' "$T/half.ledger")
    if cmp -s <(jq -S -c . "$T/half.events") "$T/interrupt-text.norm"; then ok; else ko "半行: 事件应与整行文件一致"; fi
}
run again "$FX/denials.jsonl" && { if cmp -s <(sids "$T/again.events") <(sids "$T/denials.events"); then ok; else ko "幂等: 两次运行 event_id 不同"; fi; }
# event_id 的算法用 python 独立重算一遍：UUIDv5(uuid5(NS_URL, "vibetrail"), "<sid>|<key>")，key 由事件内容还原
if python3 - "$T/denials.events" "$T/replay.events" "$T/agent-b2.events" > "$T/uuid.out" 2>&1 <<'EOF'
import json, sys, uuid
ns = uuid.uuid5(uuid.NAMESPACE_URL, "vibetrail")
bad = 0
for path in sys.argv[1:]:
    for line in open(path):
        e = json.loads(line); t = e["type"]; src = e["provenance"].get("source_event_id")
        if t == "tool.request": key = f'{src}|tool.request|{e["payload"]["call_id"]}'
        elif t == "permission.decision": key = f'{src}|permission.decision|{e["payload"].get("call_id", "")}|{e["extensions"]["vibetrail.kind"]}'
        else: key = f'{src}|{t}'
        if str(uuid.uuid5(ns, f'{e["session_id"]}|{key}')) != e["event_id"]:
            bad += 1; print("mismatch", t, key)
sys.exit(1 if bad else 0)
EOF
then ok; else ko "event_id 与 python 的 UUIDv5 不一致: $(head -3 "$T/uuid.out")"; fi

echo "════ 6. 全采正文（capture_content=1，默认；用户 09-16 推翻 D5 的「只带元数据」）════"
# 上面几节跑的是 --capture-content 0（只带元数据，开关关掉的行为）。这一节开着跑同一段 scenario，
# 断言四样正文各自进了协议自带的字段、thinking 进 extensions，以及协议的 1 MiB 单事件上限怎么兜
bash "$SELF/vibetrail-map" "$T/scenario.jsonl" --capture-content 1 --sid 11111111-2222-4333-8444-555555555555 \
    --project-id demo --workspace-id /tmp/demo-proj --ledger "$T/cap.ledger" > "$T/cap.events" 2> "$T/cap.err" \
    || ko "全采: vibetrail-map 退出码非零: $(head -c 200 "$T/cap.err")"
[ -s "$T/cap.err" ] && ko "全采: stderr 非空: $(head -c 200 "$T/cap.err")"
c=$T/cap.events
check "全采: 每句人话一条 message.user，带正文" \
    '[.[] | select(.type=="message.user")] | length >= 2 and all(.[]; (.payload.text | length) > 0 and .content_state == "included")' "$c"
check "全采: 模型输出进 message.assistant.payload.text" \
    '[.[] | select(.type=="message.assistant" and (.payload.text // "") != "")] | length >= 1 and all(.[]; .content_state == "included")' "$c"
check "全采: 每次工具调用一条 tool.request，带完整参数（Edit 的 file_path、Bash 的命令原文）" \
    '[.[] | select(.type=="tool.request")] | length == 3 and any(.[]; .payload.tool_name == "Edit" and (.payload.input.file_path | length) > 0)
     and any(.[]; .payload.tool_name == "Bash" and (.payload.input.command | length) > 0)' "$c"
check "全采: 工具结果原样进 tool.end.payload.output——假密钥既没脱敏也没截断（用户 09-16 要的就是不脱敏）" \
    '[.[] | select(.type=="tool.end")] | length >= 2 and any(.[]; (.payload.output | tostring | test("sk-demo")))' "$c"
check "全采: thinking 进 extensions.vibetrail.reasoning，不混进 assistant 正文（协议：不得把 reasoning 伪装成普通 Assistant 文本）" \
    '[.[] | select(.extensions["vibetrail.reasoning"] != null)] | length == 1 and ((.[0].extensions["vibetrail.reasoning"] | length) > 0)' "$c"
schema_check < "$c" > "$T/schema.cap" && ok || ko "全采: $(cat "$T/schema.cap")"

# 1 MiB 上限：协议说「超限内容不会被截断后保存」，所以超了要整体去正文、标 omitted，事件本身照发（event_id 不变）
{ jq -n -c '{type:"user",uuid:"bu1",parentUuid:null,promptId:"bp1",message:{role:"user",content:"把大日志打出来"},isSidechain:false,cwd:"/tmp/fx",sessionId:"fx-big",version:"2.1.266",entrypoint:"cli",gitBranch:"main",timestamp:"2026-09-16T00:00:00.000Z"}'
  jq -n -c '{type:"assistant",uuid:"ba1",parentUuid:"bu1",message:{id:"bm1",model:"claude-opus-5",role:"assistant",content:[{type:"tool_use",id:"toolu_big",name:"Bash",input:{command:"cat big.log"}}],usage:{input_tokens:5,output_tokens:5}},isSidechain:false,cwd:"/tmp/fx",sessionId:"fx-big",version:"2.1.266",entrypoint:"cli",gitBranch:"main",timestamp:"2026-09-16T00:00:01.000Z"}'
  jq -n -c '{type:"user",uuid:"br1",parentUuid:"ba1",promptId:"bp1",message:{role:"user",content:[{type:"tool_result",tool_use_id:"toolu_big",content:("x" * 1200000),is_error:false}]},isSidechain:false,cwd:"/tmp/fx",sessionId:"fx-big",version:"2.1.266",entrypoint:"cli",gitBranch:"main",timestamp:"2026-09-16T00:00:02.000Z"}'
} > "$T/big.jsonl"
bash "$SELF/vibetrail-map" "$T/big.jsonl" --capture-content 1 --sid fx-big --project-id /tmp/fx --workspace-id /tmp/fx \
    > "$T/big.events" 2> "$T/big.err" || ko "1 MiB: vibetrail-map 退出码非零: $(head -c 200 "$T/big.err")"
b=$T/big.events
check "1 MiB: 超限的 tool.end 去掉正文、标 omitted、注明是大小原因，事件本身照发" \
    '[.[] | select(.type=="tool.end")] | length == 1 and (.[0] | .payload.output == null and .content_state == "omitted"
     and .extensions["vibetrail.content_dropped"] == "size" and .payload.tool_name == "Bash" and .payload.status.code == "succeeded")' "$b"
check "1 MiB: 同一批里没超限的照常带正文（人话、工具参数）" \
    'any(.[]; .type=="message.user" and .payload.text == "把大日志打出来" and .content_state == "included")
     and any(.[]; .type=="tool.request" and .payload.input.command == "cat big.log")' "$b"
check "1 MiB: 每条事件都在协议上限内" 'all(.[]; (tojson | utf8bytelength) < 1048576)' "$b"
schema_check < "$b" > "$T/schema.big" && ok || ko "1 MiB: $(cat "$T/schema.big")"

# system prompt（≥ 2.1.258 的 transcript 自带，在 attachment/prompt_snapshot 里）：全采时一条 ext.claude.prompt_snapshot，
# 正文进 extensions、按 sha256 去重（一个会话里会重复快照几十次）；协议要求 ext.* 带 provenance.source_event
{ jq -n -c '{type:"user",uuid:"su1",parentUuid:null,promptId:"sp1",message:{role:"user",content:"改一下"},isSidechain:false,cwd:"/tmp/fx",sessionId:"fx-sys",version:"2.1.266",entrypoint:"cli",gitBranch:"main",timestamp:"2026-09-16T01:00:00.000Z"}'
  jq -n -c '{type:"attachment",uuid:"sp-a1",parentUuid:"su1",promptId:"sp1",attachment:{type:"prompt_snapshot",systemPrompt:["You are Claude Code.","工具定义……"]},isSidechain:false,cwd:"/tmp/fx",sessionId:"fx-sys",version:"2.1.266",entrypoint:"cli",gitBranch:"main",timestamp:"2026-09-16T01:00:01.000Z"}'
  jq -n -c '{type:"attachment",uuid:"sp-a2",parentUuid:"sp-a1",promptId:"sp1",attachment:{type:"prompt_snapshot",systemPrompt:["You are Claude Code.","工具定义……"]},isSidechain:false,cwd:"/tmp/fx",sessionId:"fx-sys",version:"2.1.266",entrypoint:"cli",gitBranch:"main",timestamp:"2026-09-16T01:00:02.000Z"}'
  jq -n -c '{type:"system",subtype:"api_error",uuid:"sp-e1",parentUuid:"sp-a2",promptId:"sp1",source:"request_retry",retryAttempt:1,maxRetries:3,error:"{\"message\":\"overloaded\",\"status\":529}",isSidechain:false,cwd:"/tmp/fx",sessionId:"fx-sys",version:"2.1.266",entrypoint:"cli",gitBranch:"main",timestamp:"2026-09-16T01:00:03.000Z"}'
} > "$T/sys.jsonl"
bash "$SELF/vibetrail-map" "$T/sys.jsonl" --capture-content 1 --sid fx-sys --project-id /tmp/fx --workspace-id /tmp/fx > "$T/sys.events" 2>/dev/null
y=$T/sys.events
check "system prompt: 两次快照只发一条（按正文 sha256 去重），正文进 extensions、payload 只有 bytes 与 sha256" \
    '[.[] | select(.type=="ext.claude.prompt_snapshot")] | length == 1
     and (.[0].extensions["vibetrail.system_prompt"] | test("You are Claude Code"))
     and (.[0].payload | keys | sort) == ["bytes","sha256"] and .[0].content_state == "included"' "$y"
check "ext.* 都带 provenance.source_event（协议今天更新后要求；prompt_snapshot 与 api_error 都是 transcript 出的）" \
    'all(.[] | select(.type | startswith("ext.")); .provenance.source_event != null)
     and any(.[]; .type=="ext.claude.api_error" and .provenance.source_event == "api_error")' "$y"
schema_check < "$y" > "$T/schema.sys" && ok || ko "system prompt: $(cat "$T/schema.sys")"
bash "$SELF/vibetrail-map" "$T/sys.jsonl" --capture-content 0 --sid fx-sys --project-id /tmp/fx --workspace-id /tmp/fx > "$T/sys0.events" 2>/dev/null
check "system prompt: 关掉开关就不发（api_error 照发）" \
    '([.[] | select(.type=="ext.claude.prompt_snapshot")] | length == 0) and any(.[]; .type=="ext.claude.api_error")' "$T/sys0.events"

# hook 不传 --capture-content，走的是 config：这条链路单独钉一下，三种情形（开 / 关 / 没写＝默认开）
for m in on off default; do
    mkdir -p "$T/cfg-$m"
    case $m in on) printf 'capture_content=1\n';; off) printf 'capture_content=0\n';; *) printf 'scope=project\n';; esac > "$T/cfg-$m/config"
    VIBETRAIL_HOME=$T/cfg-$m bash "$SELF/vibetrail-map" "$T/scenario.jsonl" --sid 11111111-2222-4333-8444-555555555555 --project-id p --workspace-id w \
        > "$T/cfg-$m.events" 2>/dev/null
done
check "开关走 config：capture_content=1 带正文" 'any(.[]; .type=="message.user" and (.payload.text // "") != "")' "$T/cfg-on.events"
# 关掉开关＝回到 D5：trace 不带正文，只有分歧那两条带（被拒的命令原文、拒绝之后人说的第一句）
check "开关走 config：capture_content=0 时 trace 不带正文，分歧那两条照旧带" \
    'all(.[] | select(.type=="message.assistant"); (.payload.text // null) == null)
     and all(.[] | select(.type=="tool.end"); (.payload.output // null) == null)
     and ([.[] | select(.type=="message.user")] | length == 1 and (.[0].extensions["vibetrail.after"] | length) == 2)
     and ([.[] | select(.type=="tool.request")] | length == 1 and (.[0].payload.input.command | startswith("sed -i")))' "$T/cfg-off.events"
check "开关走 config：没写这一项＝默认全采" 'any(.[]; .type=="tool.end" and .payload.output != null)' "$T/cfg-default.events"

echo "════ 7. 09-16 复核修补（K8 / K12 / K13，OPEN-ISSUES）════"
R(){ # R <uuid> <parent> <sessionId> <promptId> <type> <content JSON> [额外字段 JSON]：造一条 transcript 记录
    # 默认值别写成 ${7:-{\}}：没给第 7 个参数时它展开成 {\}，不是合法 JSON，jq 直接报错、这条记录就没造出来（先踩了一次）
    local x=${7:-}; [ -n "$x" ] || x='{}'
    jq -n -c --arg u "$1" --arg p "$2" --arg s "$3" --arg q "$4" --arg t "$5" --argjson c "$6" --argjson x "$x" \
      '{type: $t, uuid: $u, parentUuid: (if $p == "" then null else $p end), sessionId: $s, promptId: (if $q == "" then null else $q end),
        message: {role: $t, content: $c}, isSidechain: false, cwd: "/tmp/fx", version: "2.1.266", entrypoint: "cli", gitBranch: "main",
        timestamp: "2026-09-16T02:00:00.000Z"} + $x'
}
AM(){ printf '{"message":{"id":"%s","model":"claude-opus-5","role":"assistant","content":%s,"usage":{"input_tokens":5,"output_tokens":5},"stop_reason":"end_turn"}}' "$1" "$2"; }

# K8：desktop 续接会话把旧会话的开头复制进新文件——uuid、promptId 不变，sessionId 字段仍是旧会话的。复制来的整条跳过、账本记 inherited
{ R o1 ""  old-sess op1 user '"旧会话里的一句"'
  R o2 o1  old-sess op1 assistant '[]' "$(AM om1 '[{"type":"text","text":"旧回复"}]')"
  R o3 o2  old-sess op1 user '[{"type":"text","text":"[Request interrupted by user]"}]'
  R n1 o3  new-sess np1 user '"续接之后的新一句"'
  R n2 n1  new-sess np1 assistant '[]' "$(AM nm1 '[{"type":"text","text":"新回复"},{"type":"tool_use","id":"toolu_n","name":"Bash","input":{"command":"ls"}}]')"
  R n3 n2  new-sess np1 user '[{"type":"tool_result","tool_use_id":"toolu_n","content":"a.txt"}]'
} > "$T/k8.jsonl"
bash "$SELF/vibetrail-map" "$T/k8.jsonl" --sid new-sess --project-id /tmp/fx --workspace-id /tmp/fx --capture-content 1 --close-last session_end \
    --ledger "$T/k8.ledger" > "$T/k8.events" 2>/dev/null
check "K8: 复制来的旧会话记录（sessionId 不是本文件的）一条事件都不出，打断也不算" \
    'all(.[]; (.provenance.source_event_id // "") | IN("o1","o2","o3") | not) and all(.[]; .type != "turn.end" or .payload.status.code != "interrupted")' "$T/k8.events"
check "K8: 本会话自己的记录照常出（人话、回复、工具调用）" \
    'any(.[]; .type=="message.user" and .payload.text=="续接之后的新一句") and any(.[]; .type=="tool.request" and .payload.call_id=="toolu_n") and any(.[]; .type=="tool.end")' "$T/k8.events"
check "K8: 账本 inherited 记 3 条" '.[0].inherited == 3' "$T/k8.ledger"

# K12：只在人话或斜杠命令处开轮；带新 promptId 的 task-notification 不开轮、不出 turn.start
{ R k1 ""  k12 kp1 user '"第一句人话"'
  R k2 k1  k12 kp1 assistant '[]' "$(AM km1 '[{"type":"text","text":"好"}]')"
  R k3 k2  k12 kp2 user '"<task-notification>后台任务跑完了</task-notification>"'
  R k4 k3  k12 kp2 assistant '[]' "$(AM km2 '[{"type":"text","text":"收到通知"}]')"
  R k5 k4  k12 kp3 user '"第二句人话"'
} > "$T/k12.jsonl"
bash "$SELF/vibetrail-map" "$T/k12.jsonl" --sid k12 --project-id /tmp/fx --workspace-id /tmp/fx --capture-content 0 > "$T/k12.events" 2>/dev/null
check "K12: turn.start 只在两句人话处（kp1、kp3），task-notification 的 kp2 不开轮" \
    '[.[] | select(.type=="turn.start") | .turn_id] == ["kp1","kp3"] and ([.[] | select(.type=="turn.end") | .turn_id] == ["kp1"])' "$T/k12.events"

# K13：打断发的 turn.end 带 closed_by = interrupt 与 stops，打断后这一轮算关了（state 的 turn_closed 才会是 true，补做不再重读）
{ R i1 ""  k13 ip1 user '"看一下这个"'
  R i2 i1  k13 ip1 assistant '[]' "$(AM im1 '[{"type":"text","text":"我先看看"}]')"
  R i3 i2  k13 ip1 user '[{"type":"text","text":"[Request interrupted by user]"}]'
} > "$T/k13.jsonl"
bash "$SELF/vibetrail-map" "$T/k13.jsonl" --sid k13 --project-id /tmp/fx --workspace-id /tmp/fx --capture-content 0 \
    --ledger "$T/k13.ledger" > "$T/k13.events" 2>/dev/null
check "K13: 打断的 turn.end 带 vibetrail.closed_by = interrupt 与 vibetrail.stops" \
    '[.[] | select(.type=="turn.end")] | length == 1 and .[0].payload.status.code == "interrupted"
     and .[0].extensions["vibetrail.closed_by"] == "interrupt" and .[0].extensions["vibetrail.stops"] == 0' "$T/k13.events"
check "K13: 打断后这一轮算关了（账本 turns.closed = true）" '.[0].turns.open == "ip1" and .[0].turns.closed == true' "$T/k13.ledger"

echo "════ 8. 只挂 5 个 hook（用户 09-16 定）：原来靠另外 8 个 hook 给的，改从 transcript 推 ════"
: > "$T/m8.err"
M8(){ # 没给 --ledger 时账本打到 stderr：补一个 /dev/null，stderr 里只剩真的报错
    case " $* " in *" --ledger "*) bash "$SELF/vibetrail-map" "$@" 2>>"$T/m8.err";; *) bash "$SELF/vibetrail-map" "$@" --ledger /dev/null 2>>"$T/m8.err";; esac; }
AT(){ # AT <uuid> <parent> <sessionId> <promptId> <attachment JSON> [额外字段 JSON]：造一条 attachment 记录
    local x=${6:-}; [ -n "$x" ] || x='{}'
    jq -n -c --arg u "$1" --arg p "$2" --arg s "$3" --arg q "$4" --argjson a "$5" --argjson x "$x" \
      '{type: "attachment", uuid: $u, parentUuid: $p, sessionId: $s, promptId: $q, attachment: $a, isSidechain: false, cwd: "/tmp/fx",
        version: "2.1.266", entrypoint: "cli", gitBranch: "main", timestamp: "2026-09-16T02:00:00.000Z"} + $x'
}
TS(){ printf '{"timestamp":"2026-09-16T%s"}' "$1"; }
with_ts(){ jq -c --arg t "2026-09-16T$1" '. + {timestamp: $t}'; }

# StopFailure → API 出错结束一轮：Claude Code 写一条 model=<synthetic> 的回复，带 isApiErrorMessage 与 error（本机 162 条）
APIERR='{"isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,"message":{"id":"syn1","model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"API Error: Rate limit reached"}]}}'
{ R a1 ""  s8a ap1 user '"跑一下"'
  R a2 a1  s8a ap1 assistant '[]' "$(AM am1 '[{"type":"text","text":"我先跑"}]')"
  R a3 a2  s8a ap1 assistant '[]' "$APIERR"
  R a4 a3  s8a ap2 user '"继续"'
  R a5 a4  s8a ap2 assistant '[]' "$(printf '%s' "$APIERR" | jq -c '.message.id = "syn2" | .error = "server_error" | .apiErrorStatus = 500')"
  R a6 a5  s8a ap2 assistant '[]' "$(AM am2 '[{"type":"text","text":"缓过来了"}]')"
} > "$T/m8a.jsonl"
M8 "$T/m8a.jsonl" --sid s8a --project-id /tmp/fx --workspace-id /tmp/fx --capture-content 0 --close-last session_end > "$T/m8a.events"
check "API 出错结束的一轮：turn.end 状态是那个错误（code rate_limit、分类 failure——K18 推荐值，不再是 error），证据 api_error" \
    '[.[] | select(.type=="turn.end" and .turn_id=="ap1")] | length == 1 and .[0].payload.status == {code: "rate_limit", category: "failure"}
     and .[0].extensions["vibetrail.end_evidence"] == "api_error"' "$T/m8a.events"
check "出错之后同一轮里又有真回复：算缓过来了，照常 completed" \
    '[.[] | select(.type=="turn.end" and .turn_id=="ap2")] | .[0].payload.status.code == "completed"' "$T/m8a.events"

# InstructionsLoaded → attachment/instructions（files[{path,type,content}]、reason）与 nested_memory；CwdChanged → 相邻记录的 cwd 变了
{ R c1 ""  s8c cp1 user '"看看子目录"'
  AT c2 c1 s8c cp1 '{"type":"instructions","files":[{"path":"/tmp/fx/CLAUDE.md","type":"Project","content":"# 规则\n别删文件"},{"path":"/Users/x/.claude/memory/MEMORY.md","type":"AutoMem","content":"- 记住的事"}],"reason":"session_start"}'
  R c3 c2  s8c cp1 assistant '[]' "$(AM cm1 '[{"type":"text","text":"进去看"}]' | jq -c '. + {cwd: "/tmp/fx/sub"}')"
  AT c4 c3 s8c cp1 '{"type":"nested_memory","path":"/tmp/fx/sub/CLAUDE.md","content":{"path":"/tmp/fx/sub/CLAUDE.md","type":"Project","content":"子目录规则"}}' '{"cwd":"/tmp/fx/sub"}'
  R c5 c4  s8c cp2 user '"回去"'
} > "$T/m8c.jsonl"
M8 "$T/m8c.jsonl" --sid s8c --project-id /tmp/fx --workspace-id /tmp/fx --workspace-roots /tmp/fx --capture-content 1 > "$T/m8c.events"
# 路径不出本机（用户 09-16 定相对路径）：仓里的 CLAUDE.md 相对工作区根，~/.claude 下的换成 ~ 形；cwd 相对主 checkout（本身是 .）
check "CLAUDE.md 加载：一次 attachment 一条 ext.claude.instructions_loaded，payload 逐个文件 path（相对 / ~ 形）/ type / bytes / sha256，正文进 extensions" \
    '[.[] | select(.type=="ext.claude.instructions_loaded")] as $l | ($l | length) == 2
     and ($l[0].payload.files | map(.path)) == ["CLAUDE.md","~/.claude/memory/MEMORY.md"] and $l[0].payload.reason == "session_start"
     and ($l[0].payload.files[0] | .type == "Project" and .bytes == ("# 规则\n别删文件" | utf8bytelength) and (.sha256 | test("^[0-9a-f]{64}$")))
     and ($l[0].extensions["vibetrail.instructions"] | map(.path)) == ["CLAUDE.md","~/.claude/memory/MEMORY.md"]
     and $l[0].extensions["vibetrail.instructions"][1].content == "- 记住的事" and $l[0].content_state == "included"
     and $l[1].payload.reason == "nested_traversal" and $l[1].payload.files[0].path == "sub/CLAUDE.md"
     and all($l[]; .provenance.source_event == "instructions")' "$T/m8c.events"
check "切目录：cwd 变一次一条 ext.claude.cwd_changed（第一条记录不算），old / new 相对主 checkout" \
    '[.[] | select(.type=="ext.claude.cwd_changed") | [.payload.old_cwd, .payload.new_cwd, .provenance.source_event_id, .provenance.source_event]]
     == [[".","sub","c3","cwd"],["sub",".","c5","cwd"]]' "$T/m8c.events"
check "路径不出本机：这两类事件里一个以 / 开头的路径都没有" \
    '[.[] | select(.type=="ext.claude.cwd_changed" or .type=="ext.claude.instructions_loaded") | (.payload, .extensions["vibetrail.instructions"]) | .. | strings | select(startswith("/"))] == []' "$T/m8c.events"
schema_check < "$T/m8c.events" > "$T/schema.m8c" && ok || ko "instructions / cwd: $(cat "$T/schema.m8c")"
M8 "$T/m8c.jsonl" --sid s8c --project-id /tmp/fx --workspace-id /tmp/fx --workspace-roots /tmp/fx --capture-content 0 > "$T/m8c0.events"
check "CLAUDE.md 加载：关掉全采只剩元数据（路径、大小、哈希），不带正文" \
    '[.[] | select(.type=="ext.claude.instructions_loaded")] | length == 2 and all(.[]; .extensions["vibetrail.instructions"] == null and .content_state == null)' "$T/m8c0.events"

# K15②：tool.end 的耗时标来源——工具自报的（WebFetch durationMs、WebSearch durationSeconds、Agent totalDurationMs）标 reported，
# 别的是「结果记录 − 调用记录」标 wall_clock；一条记录夹几个工具结果时 toolUseResult 分不清是谁的，只用 wall_clock
{ R d1 ""  s8d dp1 user '"查资料"' "$(TS 03:00:00.000Z)"
  R d2 d1  s8d dp1 assistant '[]' "$(AM dm1 '[{"type":"tool_use","id":"toolu_f","name":"WebFetch","input":{"url":"https://example.com"}}]' | with_ts 03:00:01.000Z)"
  R d3 d2  s8d dp1 user '[{"type":"tool_result","tool_use_id":"toolu_f","content":"ok"}]' '{"timestamp":"2026-09-16T03:00:09.000Z","toolUseResult":{"code":200,"durationMs":1234,"url":"https://example.com"}}'
  R d4 d3  s8d dp1 assistant '[]' "$(AM dm2 '[{"type":"tool_use","id":"toolu_s","name":"WebSearch","input":{"query":"x"}},{"type":"tool_use","id":"toolu_b","name":"Bash","input":{"command":"sleep 1"}}]' | with_ts 03:00:10.000Z)"
  R d5 d4  s8d dp1 user '[{"type":"tool_result","tool_use_id":"toolu_s","content":"r"}]' '{"timestamp":"2026-09-16T03:00:12.500Z","toolUseResult":{"query":"x","durationSeconds":2.25}}'
  R d6 d5  s8d dp1 user '[{"type":"tool_result","tool_use_id":"toolu_b","content":"done"}]' '{"timestamp":"2026-09-16T03:00:15.000Z","toolUseResult":{"stdout":"done","interrupted":false}}'
  R d7 d6  s8d dp1 assistant '[]' "$(AM dm3 '[{"type":"tool_use","id":"toolu_g1","name":"Grep","input":{"pattern":"a"}},{"type":"tool_use","id":"toolu_g2","name":"Glob","input":{"pattern":"*"}}]' | with_ts 03:00:16.000Z)"
  R d8 d7  s8d dp1 user '[{"type":"tool_result","tool_use_id":"toolu_g1","content":"a"},{"type":"tool_result","tool_use_id":"toolu_g2","content":"b"}]' '{"timestamp":"2026-09-16T03:00:20.000Z","toolUseResult":{"durationMs":5}}'
} > "$T/m8d.jsonl"
M8 "$T/m8d.jsonl" --sid s8d --project-id /tmp/fx --workspace-id /tmp/fx --capture-content 0 > "$T/m8d.events"
check "K15②: 耗时与来源——WebFetch 1234 reported、WebSearch 2250 reported、Bash 5000 wall_clock、夹在一条里的两个 4000 wall_clock" \
    '[.[] | select(.type=="tool.end") | [.payload.call_id, .payload.duration_ms, .extensions["vibetrail.duration_kind"]]]
     == [["toolu_f",1234,"reported"],["toolu_s",2250,"reported"],["toolu_b",5000,"wall_clock"],["toolu_g1",4000,"wall_clock"],["toolu_g2",4000,"wall_clock"]]' "$T/m8d.events"

# SubagentStart / SubagentStop → 父文件里的信号：同步 agent 的调用结果（agentId、status、耗时、token），后台 agent 的启动结果（isAsync）
# 与之后的 <task-notification>（user 记录或 queued_command 附件）。子 agent 靠 subagents/*.meta.json 与这次读到的后台启动认
PJ=$T/m8-proj; SA=$PJ/s8s/subagents; mkdir -p "$SA"
printf '%s\n' '{"agentType":"Explore","description":"找入口","spawnDepth":1,"toolUseId":"toolu_sync"}' > "$SA/agent-asy1.meta.json"
printf '%s\n' '{"agentType":"general-purpose","description":"会出错","spawnDepth":1,"toolUseId":"toolu_err"}' > "$SA/agent-aerr1.meta.json"
{ R u1 ""  s8s sp1 user '"找入口"' '{"agentId":"asy1","isSidechain":true,"timestamp":"2026-09-16T04:00:01.000Z"}'
  R u2 u1  s8s sp1 assistant '[]' "$(AM um1 '[{"type":"text","text":"入口在 main.go"}]' | jq -c '. + {agentId: "asy1", isSidechain: true, timestamp: "2026-09-16T04:00:05.000Z"}')"
} > "$SA/agent-asy1.jsonl"
NOTE_BG='<task-notification>
<task-id>abg1</task-id>
<tool-use-id>toolu_bg</tool-use-id>
<status>killed</status>
<summary>Agent "后台跑测试" was stopped</summary>
<result>跑到一半被停了</result>
<usage><subagent_tokens>900</subagent_tokens><tool_uses>7</tool_uses><duration_ms>60000</duration_ms></usage>
</task-notification>'
{ R m1 ""  s8s sp1 user '"派两个 agent"' "$(TS 04:00:00.000Z)"
  R m2 m1  s8s sp1 assistant '[]' "$(AM mm1 '[{"type":"tool_use","id":"toolu_sync","name":"Agent","input":{"subagent_type":"Explore","description":"找入口","prompt":"找"}},{"type":"tool_use","id":"toolu_bg","name":"Agent","input":{"description":"后台跑测试","prompt":"跑","run_in_background":true}},{"type":"tool_use","id":"toolu_err","name":"Agent","input":{"description":"会出错","prompt":"x"}}]' | with_ts 04:00:00.500Z)"
  R m3 m2  s8s sp1 user '[{"type":"tool_result","tool_use_id":"toolu_bg","content":"Async agent launched"}]' '{"timestamp":"2026-09-16T04:00:01.000Z","toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"abg1","description":"后台跑测试","outputFile":"/tmp/abg1.output"}}'
  R m4 m3  s8s sp1 user '[{"type":"tool_result","tool_use_id":"toolu_sync","content":[{"type":"text","text":"入口在 main.go"}]}]' '{"timestamp":"2026-09-16T04:00:06.000Z","toolUseResult":{"status":"completed","agentId":"asy1","agentType":"Explore","content":[{"type":"text","text":"入口在 main.go"}],"totalDurationMs":4000,"totalTokens":1500,"totalToolUseCount":3}}'
  R m5 m4  s8s sp1 user '[{"type":"tool_result","tool_use_id":"toolu_err","is_error":true,"content":"Agent failed"}]' '{"timestamp":"2026-09-16T04:00:07.000Z","toolUseResult":"Error: Agent failed"}'
  AT m6 m5 s8s sp1 '{"type":"queued_command","commandMode":"task-notification","prompt":"<task-notification>\n<task-id>bsh1</task-id>\n<status>completed</status>\n<summary>Background command done</summary>\n</task-notification>"}' "$(TS 04:00:08.000Z)"
  R m7 m6  s8s sp2 user "$(jq -n -c --arg t "$NOTE_BG" '$t')" '{"origin":{"kind":"task-notification"},"timestamp":"2026-09-16T04:01:00.000Z"}'
} > "$PJ/s8s.jsonl"
M8 "$PJ/s8s.jsonl" --sid s8s --project-id /tmp/fx --workspace-id /tmp/fx --capture-content 1 --ledger "$T/m8s.ledger" > "$T/m8s.events"
check "子 agent（同步）：调用结果出 subagent.end——实例 asy1、父 main、派它的调用、类型、最后的回答、耗时 / token / 工具次数" \
    '[.[] | select(.type=="subagent.end" and .agent_instance_id=="asy1")] | length == 1
     and (.[0] | .parent_agent_instance_id == "main" and .parent_call_id == "toolu_sync" and .payload.agent_type == "Explore"
       and .payload.status == {code: "completed", category: "success"} and .payload.last_message == "入口在 main.go"
       and .extensions["vibetrail.agent"] == {duration_ms: 4000, total_tokens: 1500, tool_use_count: 3})' "$T/m8s.events"
check "子 agent（后台）：启动结果出 subagent.start（没给 subagent_type 就是 general-purpose，全采时带 task、标 included），通知出 subagent.end（killed 算取消，带用量）" \
    '([.[] | select(.type=="subagent.start" and .agent_instance_id=="abg1")] | length == 1 and (.[0] | .parent_call_id == "toolu_bg"
       and .payload == {agent_type: "general-purpose", task: "后台跑测试"} and .content_state == "included"))
     and ([.[] | select(.type=="subagent.end" and .agent_instance_id=="abg1")] | length == 1 and (.[0] | .parent_call_id == "toolu_bg"
       and .payload.status == {code: "killed", category: "cancellation"} and .payload.last_message == "跑到一半被停了"
       and .extensions["vibetrail.agent"] == {duration_ms: 60000, total_tokens: 900, tool_use_count: 7}))' "$T/m8s.events"
check "后台 shell 任务的通知不算子 agent" 'all(.[]; .agent_instance_id != "bsh1")' "$T/m8s.events"
# 09-16 第二批：同步 agent 出错拿不到 agentId，但它的 meta 里有 toolUseId（真起过），调用结果就是它的结束——以前不发，现在发 failed
check "同步 agent 出错：按 meta 的 toolUseId 认出是 aerr1，发 subagent.end（failed / failure，不带最后的回答）" \
    '[.[] | select(.type=="subagent.end" and .agent_instance_id=="aerr1")] | length == 1
     and (.[0] | .parent_call_id == "toolu_err" and .payload.status == {code: "failed", category: "failure"} and (.payload | has("last_message") | not) and .payload.agent_type == "general-purpose")' "$T/m8s.events"
check "账本：后台启动记下（之后的通知靠它认），完成信号按 agentId 与调用 id 各记一份（出错的同步 agent 也有了 agentId）" \
    '.[0].agents.launched == {abg1: {call_id: "toolu_bg", agent_type: "general-purpose"}}
     and .[0].agents.done == {asy1: "2026-09-16T04:00:06.000Z", aerr1: "2026-09-16T04:00:07.000Z", abg1: "2026-09-16T04:01:00.000Z"}
     and .[0].agents.calls_done == {toolu_sync: "2026-09-16T04:00:06.000Z", toolu_err: "2026-09-16T04:00:07.000Z", toolu_bg: "2026-09-16T04:01:00.000Z"}' "$T/m8s.ledger"
schema_check < "$T/m8s.events" > "$T/schema.m8s" && ok || ko "subagent: $(cat "$T/schema.m8s")"
M8 "$PJ/s8s.jsonl" --sid s8s --project-id /tmp/fx --workspace-id /tmp/fx --capture-content 0 > "$T/m8s0.events"
check "子 agent：关掉全采不带最后的回答" 'all(.[] | select(.type=="subagent.end"); .payload.last_message == null)' "$T/m8s0.events"
check "K23: 关掉全采时 subagent.start 不带 task、标 omitted（协议把 task 算正文）" \
    '[.[] | select(.type=="subagent.start")] | length >= 1 and all(.[]; (.payload | has("task") | not) and .content_state == "omitted")' "$T/m8s0.events"
schema_check < "$T/m8s0.events" > "$T/schema.m8s0" && ok || ko "K23: $(cat "$T/schema.m8s0")"
# 子 agent 文件自己：第一条记录出 subagent.start（类型、任务、派它的调用取 meta）；最后一次调用只在完成信号不早于文件最后一条时写出
M8 "$SA/agent-asy1.jsonl" --project-id /tmp/fx --workspace-id /tmp/fx --capture-content 0 --close-last if_done --done-ts 2026-09-16T04:00:06.000Z \
    --ledger "$T/m8u.ledger" > "$T/m8u.events"
check "子 agent 文件：第一条记录出 subagent.start，父 main、派它的调用与类型取 meta（关掉全采不带 task，K23）；完成信号晚于最后一条 → 最后一次调用写出" \
    '([.[] | select(.type=="subagent.start")] | length == 1 and (.[0] | .agent_instance_id == "asy1" and .parent_agent_instance_id == "main"
       and .parent_call_id == "toolu_sync" and .payload == {agent_type: "Explore"} and .content_state == "omitted"))
     and ([.[] | select(.type=="message.assistant")] | length == 1)' "$T/m8u.events"
M8 "$SA/agent-asy1.jsonl" --project-id /tmp/fx --workspace-id /tmp/fx --capture-content 1 --close-last if_done --done-ts 2026-09-16T04:00:06.000Z \
    --ledger /dev/null > "$T/m8u1.events"
check "子 agent 文件：全采时 subagent.start 带 meta 里的任务描述、标 included" \
    '[.[] | select(.type=="subagent.start")][0] | .payload == {agent_type: "Explore", task: "找入口"} and .content_state == "included"' "$T/m8u1.events"
M8 "$SA/agent-asy1.jsonl" --project-id /tmp/fx --workspace-id /tmp/fx --capture-content 0 --close-last if_done --done-ts 2026-09-16T04:00:03.000Z \
    --ledger "$T/m8v.ledger" > "$T/m8v.events"
check "子 agent 文件：完成信号早于最后一条（SendMessage 续上后又写了）→ 那次调用先不写出" \
    '[.[] | select(.type=="message.assistant")] | length == 0' "$T/m8v.events"
check "子 agent 文件：账本带最后一条记录的时间（hook 拿它判续上之后有没有新的完成信号）" '.[0].last_ts == "2026-09-16T04:00:05.000Z" and .[0].trace.call_open == true' "$T/m8v.ledger"
if [ ! -s "$T/m8.err" ]; then ok; else ko "这一节的映射有报错: $(head -c 300 "$T/m8.err")"; fi

echo "════ 9. push 前对齐采集端协议（OPEN-ISSUES K18 / U12 / K20 / K21 / K22，2026-09-16）════"
: > "$T/m9.err"
M9(){ bash "$SELF/vibetrail-map" "$@" --ledger /dev/null 2>>"$T/m9.err"; }
# K18：tool.end 的 code / 分类用推荐值；subagent.end 的 failed 是 failure。U12：用量算法
{ R e1 ""  s9e ep1 user '"跑"' "$(TS 05:00:00.000Z)"
  R e2 e1  s9e ep1 assistant '[]' "$(AM em1 '[{"type":"tool_use","id":"toolu_ok","name":"Bash","input":{"command":"true"}},{"type":"tool_use","id":"toolu_bad","name":"Bash","input":{"command":"false"}}]' \
      | jq -c '.message.usage = {input_tokens: 10, cache_creation_input_tokens: 5, cache_read_input_tokens: 100, output_tokens: 20, output_tokens_details: {thinking_tokens: 8}}' | with_ts 05:00:01.000Z)"
  R e3 e2  s9e ep1 user '[{"type":"tool_result","tool_use_id":"toolu_ok","content":"ok"},{"type":"tool_result","tool_use_id":"toolu_bad","content":"boom","is_error":true}]' "$(TS 05:00:02.000Z)"
  R e4 e3  s9e ep1 assistant '[]' "$(AM em2 '[{"type":"tool_use","id":"toolu_ag","name":"Agent","input":{"description":"会失败","prompt":"y"}}]' | jq -c '.message.usage = {output_tokens: 7}' | with_ts 05:00:03.000Z)"
  R e5 e4  s9e ep1 user '[{"type":"tool_result","tool_use_id":"toolu_ag","content":[{"type":"text","text":"炸了"}]}]' '{"timestamp":"2026-09-16T05:00:05.000Z","toolUseResult":{"status":"failed","agentId":"ag9","agentType":"general-purpose","content":[{"type":"text","text":"炸了"}]}}'
  R e6 e5  s9e ep1 assistant '[]' "$(AM em3 '[{"type":"text","text":"完事"}]' | jq -c 'del(.message.usage)' | with_ts 05:00:06.000Z)"
} > "$T/k18.jsonl"
M9 "$T/k18.jsonl" --sid s9e --project-id fx --workspace-id ws --capture-content 0 --close-last session_end > "$T/k18.events"
check "K18: tool.end 的 code 是 succeeded / failed、分类 success / failure（09-16 以前是 success / error，分类 error 云端会归进 other）" \
    '[.[] | select(.type=="tool.end") | [.payload.call_id, .payload.status.code, .payload.status.category]] == [["toolu_ok","succeeded","success"],["toolu_bad","failed","failure"],["toolu_ag","succeeded","success"]]' "$T/k18.events"
check "K18: 子 agent 失败的 subagent.end 分类 failure；来源自己的状态留在 code" \
    '[.[] | select(.type=="subagent.end")] | length == 1 and .[0].payload.status == {code: "failed", category: "failure"}' "$T/k18.events"
check "U12: input 含缓存创建与缓存读（10+5+100）、cached 是 input 的子集、reasoning 是 output 的子集、total = input + output；只给了 output 的那次照加" \
    '[.[] | select(.type=="turn.end")][0].payload.usage == {input_tokens: 115, cached_input_tokens: 100, output_tokens: 27, reasoning_tokens: 8, total_tokens: 142}' "$T/k18.events"
check "U12: 每次调用的用量同一算法；来源没给的字段不填（不再当 0）" \
    '([.[] | select(.type=="message.assistant" and .extensions["vibetrail.call"].response_id == "em1")][0].extensions["vibetrail.call"].usage == {input_tokens: 115, cached_input_tokens: 100, output_tokens: 20, reasoning_tokens: 8, total_tokens: 135})
     and ([.[] | select(.type=="message.assistant" and .extensions["vibetrail.call"].response_id == "em2")][0].extensions["vibetrail.call"].usage == {output_tokens: 7, total_tokens: 7})
     and ([.[] | select(.type=="message.assistant" and .extensions["vibetrail.call"].response_id == "em3")][0].extensions["vibetrail.call"] | has("usage") | not)' "$T/k18.events"
schema_check < "$T/k18.events" > "$T/schema.k18" && ok || ko "K18/U12: $(cat "$T/schema.k18")"

# K20：模型干活时人插进去的话（queued_command 附件）全采时发 message.user（delivery queued）；task-notification 形态的附件不算人话；关掉全采只计数
{ R q1 ""  s9q qp1 user '"先做这个"' "$(TS 06:00:00.000Z)"
  R q2 q1  s9q qp1 assistant '[]' "$(AM qm1 '[{"type":"text","text":"做着"}]' | with_ts 06:00:01.000Z)"
  AT q3 q2 s9q qp1 '{"type":"queued_command","commandMode":"prompt","prompt":"顺便把日志也看了","origin":{"kind":"human"}}' "$(TS 06:00:02.000Z)" | jq -c 'del(.promptId)'
  AT q4 q3 s9q qp1 '{"type":"queued_command","commandMode":"task-notification","prompt":"<task-notification><task-id>bsh</task-id><status>completed</status></task-notification>"}' "$(TS 06:00:03.000Z)" | jq -c 'del(.promptId)'
  R q5 q4  s9q qp1 assistant '[]' "$(AM qm2 '[{"type":"text","text":"好了"}]' | with_ts 06:00:04.000Z)"
} > "$T/k20.jsonl"
M9 "$T/k20.jsonl" --sid s9q --project-id fx --workspace-id ws --capture-content 1 --close-last session_end > "$T/k20.events"
check "K20: 排队的人话一条 message.user——正文、author_type user、delivery queued、挂在当前轮、带正文标 included；通知形态的附件不算" \
    '[.[] | select(.type=="message.user" and .payload.delivery == "queued")] | length == 1
     and (.[0] | .payload.text == "顺便把日志也看了" and .payload.author_type == "user" and .turn_id == "qp1" and .content_state == "included" and .provenance.source_event_id == "q3")' "$T/k20.events"
check "K20: 它不算分歧之后的下一句（没有 vibetrail.after），turn.end 照旧计数 queued_prompts = 1" \
    '([.[] | select(.type=="message.user" and .payload.delivery == "queued")][0].extensions | has("vibetrail.after") | not)
     and ([.[] | select(.type=="turn.end")][0].extensions["vibetrail.queued_prompts"] == 1)' "$T/k20.events"
schema_check < "$T/k20.events" > "$T/schema.k20" && ok || ko "K20: $(cat "$T/schema.k20")"
M9 "$T/k20.jsonl" --sid s9q --project-id fx --workspace-id ws --capture-content 0 --close-last session_end > "$T/k20-0.events"
check "K20: 关掉全采：不发排队的正文，turn.end 仍计数" \
    '([.[] | select(.type=="message.user")] | length == 0) and ([.[] | select(.type=="turn.end")][0].extensions["vibetrail.queued_prompts"] == 1)' "$T/k20-0.events"

# K21：按停止打断正在跑的工具（K7 判成按停止的那类）：tool.end(cancelled) 与 turn.end(interrupted) 各一条；判成人拒绝的仍不发 tool.end
REJ9='The user doesn'"'"'t want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.'
{ R t1 ""  s9t tp1 user '"跑一下"' '{"permissionMode":"auto","timestamp":"2026-09-16T07:00:00.000Z"}'
  R t2 t1  s9t tp1 assistant '[]' "$(AM tm1 '[{"type":"tool_use","id":"toolu_run","name":"Bash","input":{"command":"sleep 100"}}]' | with_ts 07:00:01.000Z)"
  R t3 t2  s9t tp1 user "$(jq -n -c --arg t "$REJ9" '[{type: "tool_result", tool_use_id: "toolu_run", is_error: true, content: $t}]')" '{"timestamp":"2026-09-16T07:00:31.000Z","toolUseResult":"User rejected tool use"}'
  R t4 t3  s9t tp1 user '[{"type":"text","text":"[Request interrupted by user for tool use]"}]' "$(TS 07:00:31.000Z)"
} > "$T/k21.jsonl"
M9 "$T/k21.jsonl" --sid s9t --project-id fx --workspace-id ws --capture-content 0 > "$T/k21.events"
check "K21: 被打断的调用一条 tool.end——cancelled / cancellation、耗时按记录时间差标 wall_clock；turn.end(interrupted) 也在；不发 permission.decision" \
    '([.[] | select(.type=="tool.end")] | length == 1 and (.[0] | .payload.call_id == "toolu_run" and .payload.status.code == "cancelled" and .payload.status.category == "cancellation"
       and .payload.duration_ms == 30000 and .extensions["vibetrail.duration_kind"] == "wall_clock" and .extensions["vibetrail.kind"] == "interrupt_tool"))
     and ([.[] | select(.type=="turn.end")] | length == 1 and .[0].payload.status.code == "interrupted")
     and ([.[] | select(.type=="permission.decision")] | length == 0)' "$T/k21.events"
check "K21: event_id 唯一（tool.request 与 tool.end 是两条）" '(map(.event_id) | length == (unique | length)) and any(.[]; .type=="tool.request" and .payload.call_id == "toolu_run")' "$T/k21.events"
M9 "$T/k21.jsonl" --sid s9t --project-id fx --workspace-id ws --capture-content 0 --no-turns > "$T/k21-nt.events"
check "K21: 只跑分歧一路（--no-turns）也发这条 tool.end（它是分歧派生的事实）" '[.[] | select(.type=="tool.end")] | length == 1' "$T/k21-nt.events"
schema_check < "$T/k21.events" > "$T/schema.k21" && ok || ko "K21: $(cat "$T/schema.k21")"
jq -n -c '[{at: "2026-09-16T07:00:02.000Z", tool_name: "Bash", agent_id: null, prompt_id: "tp1", permission_mode: "default"}]' > "$T/k21.perms"
M9 "$T/k21.jsonl" --sid s9t --project-id fx --workspace-id ws --capture-content 0 --perm-periods "1-" --hook-perms "$T/k21.perms" > "$T/k21-deny.events"
check "K21: 弹过权限框的是人拒绝：只发 permission.decision，不伪造 tool.end（协议：执行前被拒只发 decision）" \
    '([.[] | select(.type=="permission.decision")] | length == 1) and ([.[] | select(.type=="tool.end")] | length == 0)' "$T/k21-deny.events"

# K22：turn.end.files[]——Edit / Write / Read 成功的结果记进这一轮；路径相对工作区根（主 checkout 与 worktree，最长的根先匹配，/private/tmp 与 /tmp 一样）；
# 根外的不发只计数；失败的调用不记；同一文件取最重的操作
{ R f1 ""  s9f fp1 user '"改文件"' "$(TS 08:00:00.000Z)"
  R f2 f1  s9f fp1 assistant '[]' "$(AM fm1 '[{"type":"tool_use","id":"toolu_r","name":"Read","input":{"file_path":"/tmp/fx/src/a.js"}},{"type":"tool_use","id":"toolu_e","name":"Edit","input":{"file_path":"/tmp/fx/src/a.js","old_string":"x","new_string":"y"}},{"type":"tool_use","id":"toolu_w","name":"Write","input":{"file_path":"/private/tmp/fx/docs/new.md","content":"hi"}},{"type":"tool_use","id":"toolu_wt","name":"Edit","input":{"file_path":"/tmp/fx/.claude/worktrees/w1/lib/b.js","old_string":"1","new_string":"2"}},{"type":"tool_use","id":"toolu_out","name":"Edit","input":{"file_path":"/Users/x/.claude/memory/MEMORY.md","old_string":"1","new_string":"2"}},{"type":"tool_use","id":"toolu_bad","name":"Edit","input":{"file_path":"/tmp/fx/src/c.js","old_string":"1","new_string":"2"}},{"type":"tool_use","id":"toolu_r2","name":"Read","input":{"file_path":"/tmp/fx/README.md"}}]' | with_ts 08:00:01.000Z)"
  R f3 f2  s9f fp1 user '[{"type":"tool_result","tool_use_id":"toolu_r","content":"..."}]' '{"timestamp":"2026-09-16T08:00:02.000Z","toolUseResult":{"type":"text","file":{"filePath":"/tmp/fx/src/a.js"}}}'
  R f4 f3  s9f fp1 user '[{"type":"tool_result","tool_use_id":"toolu_e","content":"ok"}]' '{"timestamp":"2026-09-16T08:00:03.000Z","toolUseResult":{"filePath":"/tmp/fx/src/a.js","structuredPatch":[]}}'
  R f5 f4  s9f fp1 user '[{"type":"tool_result","tool_use_id":"toolu_w","content":"ok"}]' '{"timestamp":"2026-09-16T08:00:04.000Z","toolUseResult":{"type":"create","filePath":"/private/tmp/fx/docs/new.md"}}'
  R f6 f5  s9f fp1 user '[{"type":"tool_result","tool_use_id":"toolu_wt","content":"ok"}]' '{"timestamp":"2026-09-16T08:00:05.000Z","toolUseResult":{"filePath":"/tmp/fx/.claude/worktrees/w1/lib/b.js"}}'
  R f7 f6  s9f fp1 user '[{"type":"tool_result","tool_use_id":"toolu_out","content":"ok"}]' '{"timestamp":"2026-09-16T08:00:06.000Z","toolUseResult":{"filePath":"/Users/x/.claude/memory/MEMORY.md"}}'
  R f8 f7  s9f fp1 user '[{"type":"tool_result","tool_use_id":"toolu_bad","content":"File has not been read yet","is_error":true}]' "$(TS 08:00:07.000Z)"
  R f9 f8  s9f fp1 user '[{"type":"tool_result","tool_use_id":"toolu_r2","content":"# fx"}]' '{"timestamp":"2026-09-16T08:00:08.000Z","toolUseResult":{"type":"text","file":{"filePath":"/tmp/fx/README.md"}}}'
  R fa f9  s9f fp1 assistant '[]' "$(AM fm2 '[{"type":"tool_use","id":"toolu_gone","name":"Edit","input":{"file_path":"/tmp/fx/.claude/worktrees/gone/lib/b.js","old_string":"2","new_string":"3"}}]' | with_ts 08:00:09.000Z)"
  R fb fa  s9f fp1 user '[{"type":"tool_result","tool_use_id":"toolu_gone","content":"ok"}]' '{"timestamp":"2026-09-16T08:00:10.000Z","toolUseResult":{"filePath":"/tmp/fx/.claude/worktrees/gone/lib/b.js"}}'
  R fc fb  s9f fp1 assistant '[]' "$(AM fm3 '[{"type":"text","text":"改完"}]' | with_ts 08:00:11.000Z)"
} > "$T/k22.jsonl"
M9 "$T/k22.jsonl" --sid s9f --project-id fx --workspace-id ws --workspace-roots /tmp/fx,/tmp/fx/.claude/worktrees/w1 --capture-content 0 --close-last session_end > "$T/k22.events"
check "K22: turn.end.files[]——a.js 读过又改了记 modify、Write 新建记 create（/private/tmp 归到根）、worktree 里的按 worktree 根算（已删的 desktop worktree 也去掉 .claude/worktrees/<名>/ 前缀，同一个文件一个路径）、只读的记 read；根外的与失败的不记" \
    '[.[] | select(.type=="turn.end")][0] | .files == [{path: "src/a.js", operation: "modify", evidence: "tool_result"}, {path: "docs/new.md", operation: "create", evidence: "tool_result"},
       {path: "lib/b.js", operation: "modify", evidence: "tool_result"}, {path: "README.md", operation: "read", evidence: "tool_result"}]
     and .extensions["vibetrail.files_dropped"] == {outside_workspace: 1}' "$T/k22.events"
check "K22: 路径没有以 / 开头的、没有 .. 的（schema 的 path 正则）" \
    '[.[] | select(.type=="turn.end")][0].files | all(.[]; .path | test("^[^/]") and (test("(^|/)\\.\\.?(/|$)") | not))' "$T/k22.events"
schema_check < "$T/k22.events" > "$T/schema.k22" && ok || ko "K22: $(cat "$T/schema.k22")"
M9 "$T/k22.jsonl" --sid s9f --project-id fx --workspace-id ws --workspace-roots "" --capture-content 0 --close-last session_end > "$T/k22-noroot.events"
check "K22: 没给工作区根就不发 files[]、也不计根外" '[.[] | select(.type=="turn.end")][0] | (has("files") | not) and (.extensions | has("vibetrail.files_dropped") | not)' "$T/k22-noroot.events"
# 打断结束的轮也带 files[]
{ head -n 5 "$T/k22.jsonl"
  R fi f5 s9f fp1 user '[{"type":"text","text":"[Request interrupted by user]"}]' "$(TS 08:00:05.000Z)"
} > "$T/k22i.jsonl"
M9 "$T/k22i.jsonl" --sid s9f --project-id fx --workspace-id ws --workspace-roots /tmp/fx --capture-content 0 > "$T/k22i.events"
check "K22: 打断结束的轮 turn.end(interrupted) 也带 files[]" \
    '[.[] | select(.type=="turn.end")][0] | .payload.status.code == "interrupted" and (.files | map(.path)) == ["src/a.js", "docs/new.md"]' "$T/k22i.events"
if [ ! -s "$T/m9.err" ]; then ok; else ko "这一节的映射有报错: $(head -c 300 "$T/m9.err")"; fi

echo "════ 9b. 09-16 第二批：A11 计数、坏行占位、子 agent 自己改的文件、workflow 子 agent（K11）════"
: > "$T/m9b.err"
M9B(){ bash "$SELF/vibetrail-map" "$@" 2>>"$T/m9b.err"; }
# A11：一份什么都有的 transcript——不是对象、坏行、空行、不认识的记录 / 附件 / system 类型、没 uuid、复制来的历史、判据没认出的拒绝标记、回放副本
{ printf '[1,2]\n'; printf 'not json at all\n'; printf '\n'
  R a1 ""  s9a ap1 user '"说一句"' "$(TS 09:00:00.000Z)"
  jq -n -c '{type: "brand-new-type", uuid: "nt1", sessionId: "s9a", timestamp: "2026-09-16T09:00:01.000Z"}'
  AT a2 a1 s9a ap1 '{"type":"shiny_new_attachment"}' "$(TS 09:00:02.000Z)"
  jq -n -c '{type: "system", subtype: "new_subtype", uuid: "ns1", sessionId: "s9a", timestamp: "2026-09-16T09:00:03.000Z"}'
  jq -n -c '{type: "user", sessionId: "s9a", message: {role: "user", content: "no uuid"}}'
  R x1 ""  other-sess op1 user '"复制来的"' "$(TS 09:00:04.000Z)"
  R a3 a1  s9a ap1 user '[{"type":"tool_result","tool_use_id":"t9","content":"a brand new rejection wording","is_error":true}]' '{"timestamp":"2026-09-16T09:00:05.000Z","toolUseResult":"User rejected tool use"}'
  R a1 ""  s9a ap1 user '"说一句"' "$(TS 09:00:06.000Z)"
} > "$T/a11.jsonl"
M9B "$T/a11.jsonl" --sid s9a --project-id fx --workspace-id ws --workspace-roots /tmp/fx --capture-content 0 --ledger "$T/a11.ledger" > "$T/a11.events"
check "A11: 新读到的记录全部有去处——seen 10 = 进映射 5 + 坏行 1 + 不是对象 1 + 没 uuid 1 + 复制来的 1 + 回放副本 1（空行不算）" \
    '.[0].new | .seen == 10 and .records == 5 and .bad_json == 1 and .skipped_non_object == 1 and .skipped_no_uuid == 1 and .inherited == 1 and .replayed == 1
     and .seen == (.records + .bad_json + .skipped_non_object + .skipped_no_uuid + .inherited + .replayed)' "$T/a11.ledger"
check "A11: 不认识的记录类型、附件类型、system 子类型各计一次；判据没认出的拒绝标记计进 marker_without_hit" \
    '.[0].new | .unknown_types == {"type:brand-new-type": 1, "attachment:shiny_new_attachment": 1, "system:new_subtype": 1} and .sentinel == {marker: 1, marker_without_hit: 1}' "$T/a11.ledger"
check "坏行、空行占行号：账本的 lines 是物理行数 11" '.[0].lines == 11' "$T/a11.ledger"
M9B "$T/a11.jsonl" --sid s9a --project-id fx --workspace-id ws --workspace-roots /tmp/fx --capture-content 0 --from-line 4 --ledger "$T/a11b.ledger" > "$T/a11b.events"
check "A11: 只数 from_line 之后的——第 5～11 行：seen 7 = 进映射 4 + 没 uuid 1 + 复制来的 1 + 回放副本 1" \
    '.[0].new | .seen == 7 and .records == 4 and .bad_json == 0 and .skipped_non_object == 0 and .skipped_no_uuid == 1 and .inherited == 1 and .replayed == 1' "$T/a11b.ledger"
# 坏行夹在中间时的增量等价：以前坏行不占行号，checkpoint 换算成字节会错位一行；这里前段 + 从 checkpoint 起的后段 == 全量
{ R b1 ""  s9c bp1 user '"第一轮"' "$(TS 09:10:00.000Z)"
  R b2 b1  s9c bp1 assistant '[]' "$(AM bm1 '[{"type":"text","text":"一"}]' | with_ts 09:10:01.000Z)"
  printf '{"type":"user","uuid":"broken\n'
  R b3 b2  s9c bp2 user '"第二轮"' "$(TS 09:10:02.000Z)"
  R b4 b3  s9c bp2 assistant '[]' "$(AM bm2 '[{"type":"text","text":"二"}]' | with_ts 09:10:03.000Z)"
  R b5 b4  s9c bp3 user '"第三轮"' "$(TS 09:10:04.000Z)"
  R b6 b5  s9c bp3 assistant '[]' "$(AM bm3 '[{"type":"text","text":"三"}]' | with_ts 09:10:05.000Z)"
} > "$T/badmid.jsonl"
BM=(--sid s9c --project-id fx --workspace-id ws --workspace-roots /tmp/fx --capture-content 1)
M9B "$T/badmid.jsonl" "${BM[@]}" --ledger /dev/null | jq -S -c . | sort > "$T/badmid.full"
head -n 4 "$T/badmid.jsonl" > "$T/badmid-a.jsonl"
M9B "$T/badmid-a.jsonl" "${BM[@]}" --ledger "$T/badmid-a.ledger" --sources-out "$T/badmid-a.src" > "$T/badmid-a.events"
M9B "$T/badmid.jsonl" "${BM[@]}" --start-line "$(jq -r .checkpoint_line "$T/badmid-a.ledger")" --start-byte "$(jq -r .checkpoint_byte "$T/badmid-a.ledger")" \
    --from-line 4 --seen-uuids "$T/badmid-a.src" --ledger /dev/null > "$T/badmid-b.events"
check "坏行夹在中间：前段 + 从 checkpoint 起读的后段 == 全量（checkpoint 行号与字节对得上）" \
    '[ "$(cat "$T/badmid-a.events" "$T/badmid-b.events" | jq -S -c . | sort)" = "$(cat "$T/badmid.full")" ] && [ "$(wc -l < "$T/badmid.full" | tr -d " ")" -gt 0 ]'

# K22 子 agent 部分（按 09-16 真跑的子 agent 仿的形态：子 agent 文件里没有 toolUseResult，Write 新建只能看结果正文）
SFP=$T/sf-proj; mkdir -p "$SFP/s9s/subagents"
printf '%s\n' '{"agentType":"general-purpose","description":"改两个文件","toolUseId":"toolu_sf1","spawnDepth":1}' > "$SFP/s9s/subagents/agent-sf1.meta.json"
printf '%s\n' '{"agentType":"Explore","description":"写文档","toolUseId":"toolu_nest","parentAgentId":"sf1","spawnDepth":2}' > "$SFP/s9s/subagents/agent-np2.meta.json"
SUBX='{"agentId":"sf1","isSidechain":true}'
{ R s1 ""  s9s sp1 user '"改两个文件"' "$(printf '%s' "$SUBX" | jq -c '. + {timestamp: "2026-09-16T10:00:00.000Z"}')"
  R s2 s1  s9s sp1 assistant '[]' "$(AM sm1 '[{"type":"tool_use","id":"st_r","name":"Read","input":{"file_path":"/tmp/fx/README.md"}},{"type":"tool_use","id":"st_e","name":"Edit","input":{"file_path":"/tmp/fx/src/a.js","old_string":"1","new_string":"2"}},{"type":"tool_use","id":"st_w","name":"Write","input":{"file_path":"/tmp/fx/src/new.js","content":"x"}},{"type":"tool_use","id":"st_o","name":"Write","input":{"file_path":"/Users/x/elsewhere/o.txt","content":"x"}}]' | jq -c --argjson x "$SUBX" '. + $x + {timestamp: "2026-09-16T10:00:01.000Z"}')"
  R s3 s2  s9s sp1 user '[{"type":"tool_result","tool_use_id":"st_r","content":"# fx"},{"type":"tool_result","tool_use_id":"st_e","content":"The file /tmp/fx/src/a.js has been updated successfully."},{"type":"tool_result","tool_use_id":"st_w","content":"File created successfully at: /tmp/fx/src/new.js"},{"type":"tool_result","tool_use_id":"st_o","content":"File created successfully at: /Users/x/elsewhere/o.txt"}]' "$(printf '%s' "$SUBX" | jq -c '. + {timestamp: "2026-09-16T10:00:02.000Z"}')"
  R s4 s3  s9s sp1 assistant '[]' "$(AM sm2 '[{"type":"tool_use","id":"toolu_nest","name":"Agent","input":{"description":"写文档","prompt":"写"}}]' | jq -c --argjson x "$SUBX" '. + $x + {timestamp: "2026-09-16T10:00:03.000Z"}')"
  R s5 s4  s9s sp1 user '[{"type":"tool_result","tool_use_id":"toolu_nest","content":[{"type":"text","text":"写好了 docs/n.md"}]}]' "$(printf '%s' "$SUBX" | jq -c '. + {timestamp: "2026-09-16T10:00:09.000Z"}')"
  R s6 s5  s9s sp1 assistant '[]' "$(AM sm3 '[{"type":"text","text":"两个文件都改了"}]' | jq -c --argjson x "$SUBX" '. + $x + {timestamp: "2026-09-16T10:00:10.000Z"}')"
} > "$SFP/s9s/subagents/agent-sf1.jsonl"
jq -n -c '{np2: {call_id: "toolu_nest", agent_type: "Explore", parent_agent: "sf1", files: {"docs/n.md": "create"}}}' > "$T/sf-known-sub.json"
M9B "$SFP/s9s/subagents/agent-sf1.jsonl" --project-id fx --workspace-id ws --workspace-roots /tmp/fx --capture-content 1 --close-last stop \
    --known-agents "$T/sf-known-sub.json" --ledger "$T/sf-sub.ledger" > "$T/sf-sub.events"
check "子 agent 文件：自己改读的文件记成集合（Write 新建靠结果正文认出 create），根外的只计数；被它派出的 np2 的文件并进来" \
    '.[0].agent_files == {sf1: {"README.md": "read", "src/a.js": "modify", "src/new.js": "create", "docs/n.md": "create"}} and .[0].agent_files_outside == {sf1: 1}' "$T/sf-sub.ledger"
check "子 agent 文件里没有 toolUseResult：被它派出的同步 agent np2 按 meta 的 toolUseId 认出结束——subagent.end 父实例 sf1、completed、带 np2 自己的文件与最后的回答" \
    '[.[] | select(.type=="subagent.end" and .agent_instance_id=="np2")] | length == 1
     and (.[0] | .parent_agent_instance_id == "sf1" and .parent_call_id == "toolu_nest" and .payload.status.code == "completed"
       and .payload.last_message == "写好了 docs/n.md" and .payload.agent_type == "Explore" and .files == [{path: "docs/n.md", operation: "create", evidence: "tool_result"}])' "$T/sf-sub.events"
check "子 agent 文件：session_id 取路径上 subagents 的上一层，subagent.start 父 main、调用取 meta" \
    '[.[] | select(.type=="subagent.start")] | length == 1 and (.[0] | .session_id == "s9s" and .agent_instance_id == "sf1" and .parent_agent_instance_id == "main" and .parent_call_id == "toolu_sf1")' "$T/sf-sub.events"
jq -c '.[0] | {sf1: {call_id: "toolu_sf1", agent_type: "general-purpose", files: .agent_files.sf1, files_outside: .agent_files_outside.sf1}}' -s "$T/sf-sub.ledger" > "$T/sf-known-main.json"
{ R m1 ""  s9s mp1 user '"派一个 agent 改文件，我自己也改一个"' "$(TS 10:00:00.000Z)"
  R m2 m1  s9s mp1 assistant '[]' "$(AM mm1 '[{"type":"tool_use","id":"toolu_sf1","name":"Agent","input":{"description":"改两个文件","prompt":"改"}},{"type":"tool_use","id":"toolu_me","name":"Edit","input":{"file_path":"/tmp/fx/src/main.js","old_string":"a","new_string":"b"}}]' | with_ts 10:00:00.500Z)"
  R m3 m2  s9s mp1 user '[{"type":"tool_result","tool_use_id":"toolu_me","content":"ok"}]' '{"timestamp":"2026-09-16T10:00:01.000Z","toolUseResult":{"filePath":"/tmp/fx/src/main.js"}}'
  R m4 m3  s9s mp1 user '[{"type":"tool_result","tool_use_id":"toolu_sf1","content":[{"type":"text","text":"两个文件都改了"}]}]' '{"timestamp":"2026-09-16T10:00:11.000Z","toolUseResult":{"status":"completed","agentId":"sf1","agentType":"general-purpose","content":[{"type":"text","text":"两个文件都改了"}],"totalDurationMs":11000,"totalTokens":900,"totalToolUseCount":6}}'
  R m5 m4  s9s mp1 assistant '[]' "$(AM mm2 '[{"type":"text","text":"都改好了"}]' | with_ts 10:00:12.000Z)"
} > "$SFP/s9s.jsonl"
M9B "$SFP/s9s.jsonl" --project-id fx --workspace-id ws --workspace-roots /tmp/fx --capture-content 0 --close-last session_end \
    --known-agents "$T/sf-known-main.json" --ledger /dev/null > "$T/sf-main.events"
check "主会话：sf1 的 subagent.end 带它（连同 np2）改读的文件，根外的计在 files_dropped" \
    '[.[] | select(.type=="subagent.end" and .agent_instance_id=="sf1")] | length == 1
     and ((.[0].files | map([.path, .operation]) | sort) == [["README.md","read"],["docs/n.md","create"],["src/a.js","modify"],["src/new.js","create"]])
     and .[0].extensions["vibetrail.files_dropped"] == {outside_workspace: 1}' "$T/sf-main.events"
check "主会话：这一轮的 turn.end.files[] 包括自己改的 src/main.js 与子 agent 改读的全部" \
    '[.[] | select(.type=="turn.end")] | length == 1 and ((.[0].files | map([.path, .operation]) | sort) == [["README.md","read"],["docs/n.md","create"],["src/a.js","modify"],["src/main.js","modify"],["src/new.js","create"]])' "$T/sf-main.events"
schema_check < <(cat "$T/sf-sub.events" "$T/sf-main.events") > "$T/schema.sf" && ok || ko "子 agent 文件: $(cat "$T/schema.sf")"
# 被打断的子 agent：subagent.end(cancelled) 也带它自己改过的文件
{ head -n 3 "$SFP/s9s/subagents/agent-sf1.jsonl"
  R s9 s3 s9s sp1 user '[{"type":"text","text":"[Request interrupted by user]"}]' "$(printf '%s' "$SUBX" | jq -c '. + {timestamp: "2026-09-16T10:00:03.000Z"}')"
} > "$SFP/s9s/subagents/agent-sfi.jsonl.tmp"
mkdir -p "$SFP/s9i/subagents"; sed 's/"sessionId":"s9s"/"sessionId":"s9i"/g' "$SFP/s9s/subagents/agent-sfi.jsonl.tmp" > "$SFP/s9i/subagents/agent-sf1.jsonl"; rm -f "$SFP/s9s/subagents/agent-sfi.jsonl.tmp"
cp "$SFP/s9s/subagents/agent-sf1.meta.json" "$SFP/s9i/subagents/agent-sf1.meta.json"
M9B "$SFP/s9i/subagents/agent-sf1.jsonl" --project-id fx --workspace-id ws --workspace-roots /tmp/fx --capture-content 0 --ledger /dev/null > "$T/sf-parent.events"
check "被打断的子 agent：subagent.end(cancelled) 带它打断前改读的文件" \
    '[.[] | select(.type=="subagent.end")] | length == 1 and .[0].payload.status.code == "cancelled"
     and ((.[0].files | map([.path, .operation]) | sort) == [["README.md","read"],["src/a.js","modify"],["src/new.js","create"]])' "$T/sf-parent.events"

# K11：workflow 起的 agent（按 09-16 用 Workflow 真跑的形态仿：meta 没有 toolUseId，有 workflowPhase；主会话里启动结果带 runId / taskId，完成是 task-notification）
WFP=$T/wf-proj; WD=$WFP/s9w/subagents/workflows/wf_abc; mkdir -p "$WD"
printf '%s\n' '{"agentType":"workflow-subagent","description":"wf-label","workflowPhase":"Build","spawnDepth":1}' > "$WD/agent-w1.meta.json"
WX='{"agentId":"w1","isSidechain":true}'
{ R w1u "" s9w wp1 user '"按脚本改 README"' "$(printf '%s' "$WX" | jq -c '. + {timestamp: "2026-09-16T11:00:01.000Z"}')"
  R w1a w1u s9w wp1 assistant '[]' "$(AM wm1 '[{"type":"tool_use","id":"wt_e","name":"Edit","input":{"file_path":"/tmp/fx/README.md","old_string":"a","new_string":"b"}}]' | jq -c --argjson x "$WX" '. + $x + {timestamp: "2026-09-16T11:00:02.000Z"}')"
  R w1r w1a s9w wp1 user '[{"type":"tool_result","tool_use_id":"wt_e","content":"The file /tmp/fx/README.md has been updated successfully."}]' "$(printf '%s' "$WX" | jq -c '. + {timestamp: "2026-09-16T11:00:03.000Z"}')"
  R w1b w1r s9w wp1 assistant '[]' "$(AM wm2 '[{"type":"text","text":"改好了"}]' | jq -c --argjson x "$WX" '. + $x + {timestamp: "2026-09-16T11:00:04.000Z"}')"
} > "$WD/agent-w1.jsonl"
M9B "$WD/agent-w1.jsonl" --project-id fx --workspace-id ws --workspace-roots /tmp/fx --capture-content 0 --close-last stop --ledger "$T/wf-sub.ledger" > "$T/wf-sub.events"
check "K11: workflow agent 文件（subagents/workflows/<runId>/ 下）——session_id 取 subagents 的上一层，subagent.start 父 main、带 vibetrail.workflow（run_id、phase），文件照记" \
    '([.[] | select(.type=="subagent.start")] | length == 1 and (.[0] | .session_id == "s9w" and .agent_instance_id == "w1" and .parent_agent_instance_id == "main"
       and .payload.agent_type == "workflow-subagent" and .extensions["vibetrail.workflow"] == {run_id: "wf_abc", phase: "Build"}))
     and all(.[]; .session_id == "s9w")' "$T/wf-sub.events"
check "K11: workflow agent 自己改的文件进账本" '.[0].agent_files == {w1: {"README.md": "modify"}}' "$T/wf-sub.ledger"
jq -n -c '{wf_abc: {task_id: "wtask1", agents: {w1: {status: "completed", result: "改好了", label: "wf-label", phase: "Build", agent_type: "workflow-subagent"}}}}' > "$T/wf-runs.json"
jq -n -c '{w1: {agent_type: "workflow-subagent", workflow_run: "wf_abc", files: {"README.md": "modify"}}}' > "$T/wf-known.json"
NOTE_WF=$(jq -n -c '"<task-notification>\n<task-id>wtask1</task-id>\n<tool-use-id>toolu_wf</tool-use-id>\n<status>completed</status>\n<summary>Dynamic workflow \"x\" completed</summary>\n</task-notification>"')
{ R n1 ""  s9w wp1 user '"跑个 workflow"' "$(TS 11:00:00.000Z)"
  R n2 n1  s9w wp1 assistant '[]' "$(AM nm1 '[{"type":"tool_use","id":"toolu_wf","name":"Workflow","input":{"script":"…"}}]' | with_ts 11:00:00.200Z)"
  R n3 n2  s9w wp1 user '[{"type":"tool_result","tool_use_id":"toolu_wf","content":"Workflow launched in background. Task ID: wtask1"}]' '{"timestamp":"2026-09-16T11:00:00.500Z","toolUseResult":{"status":"async_launched","taskId":"wtask1","taskType":"local_workflow","workflowName":"x","runId":"wf_abc"}}'
  R n4 n3  s9w wp1 assistant '[]' "$(AM nm2 '[{"type":"text","text":"等它跑完"}]' | with_ts 11:00:01.000Z)"
  AT n5 n4 s9w wp1 "$(jq -n -c --argjson p "$NOTE_WF" '{type: "queued_command", commandMode: "task-notification", prompt: $p}')" "$(TS 11:00:05.000Z)"
  R n6 n5  s9w wp1 assistant '[]' "$(AM nm3 '[{"type":"text","text":"跑完了"}]' | with_ts 11:00:06.000Z)"
} > "$WFP/s9w.jsonl"
M9B "$WFP/s9w.jsonl" --project-id fx --workspace-id ws --workspace-roots /tmp/fx --capture-content 1 --close-last session_end \
    --known-agents "$T/wf-known.json" --workflow-runs "$T/wf-runs.json" --ledger "$T/wf-main.ledger" > "$T/wf-main.events"
check "K11: 主会话收到 workflow 的通知——给 run 里跑完的 w1 发 subagent.end：父 main、派它的调用是那次 Workflow 调用、completed、最后的回答、文件、vibetrail.workflow" \
    '[.[] | select(.type=="subagent.end" and .agent_instance_id=="w1")] | length == 1
     and (.[0] | .parent_agent_instance_id == "main" and .parent_call_id == "toolu_wf" and .payload.status == {code: "completed", category: "success"}
       and .payload.last_message == "改好了" and .payload.agent_type == "workflow-subagent"
       and .files == [{path: "README.md", operation: "modify", evidence: "tool_result"}]
       and .extensions["vibetrail.workflow"] == {run_id: "wf_abc", phase: "Build", label: "wf-label"})' "$T/wf-main.events"
check "K11: workflow 的通知不被当成子 agent 或后台 shell（task-id 不是 agentId，不冒出实例 wtask1）；这一轮的 files[] 并进 w1 改的 README.md" \
    'all(.[]; .agent_instance_id != "wtask1") and ([.[] | select(.type=="turn.end")][0].files == [{path: "README.md", operation: "modify", evidence: "tool_result"}])' "$T/wf-main.events"
check "K11: 账本记下 run → 派它的调用与 taskId" '.[0].agents.workflows == {wf_abc: {call_id: "toolu_wf", task_id: "wtask1"}}' "$T/wf-main.ledger"
schema_check < <(cat "$T/wf-sub.events" "$T/wf-main.events") > "$T/schema.wf" && ok || ko "workflow: $(cat "$T/schema.wf")"
# 还在跑的 workflow agent（journal 里没有终态）：通知里不给它发 subagent.end
jq -n -c '{wf_abc: {task_id: "wtask1", agents: {w1: {status: null, label: "wf-label"}}}}' > "$T/wf-runs-open.json"
M9B "$WFP/s9w.jsonl" --project-id fx --workspace-id ws --workspace-roots /tmp/fx --capture-content 0 --close-last session_end \
    --known-agents "$T/wf-known.json" --workflow-runs "$T/wf-runs-open.json" --ledger /dev/null > "$T/wfi.events"
check "K11: journal 里还没有终态的 workflow agent 不发 subagent.end" 'all(.[]; .type != "subagent.end")' "$T/wfi.events"
if [ ! -s "$T/m9b.err" ]; then ok; else ko "这一节的映射有报错: $(head -c 300 "$T/m9b.err")"; fi

echo "════ 10. K19 钉子：映射规则变了就得升 rule_version ════"
# 协议「适配器升级映射规则时更新 rule_version」。把上面各节确定性的输出（fixtures 的 golden + 第 6～9 节的事件，四路 rule_version 都有）
# 按 rule_version 分别算摘要，记在 expect/RULE-DIGESTS：摘要变了而版本号还是登记过的那个 → 红。升了版本号（新名字没登记）不算错，
# --update 把新名字记进去、去掉旧的；--update 碰到「变了没升」也红，除非 --accept-rule-digest（确认只是 fixture 变了、规则没变）
DIG=$FX/expect/RULE-DIGESTS
cat "$T"/*.norm > "$T/digest.in"
for x in cap big sys sys0 cfg-on cfg-off cfg-default k8 k12 k13 m8a m8c m8c0 m8d m8s m8s0 m8u m8u1 m8v k18 k20 k20-0 k21 k21-nt k21-deny k22 k22-noroot k22i \
         a11 a11b sf-sub sf-main sf-parent wf-sub wf-main wfi; do
    [ -f "$T/$x.events" ] && jq -S -c . "$T/$x.events" >> "$T/digest.in"
done
: > "$T/digests.new"
for rv in $(jq -r '.provenance.rule_version // empty' "$T/digest.in" | sort -u); do
    sha=$(jq -c --arg rv "$rv" 'select(.provenance.rule_version == $rv)' "$T/digest.in" | sort | shasum -a 256 | cut -c1-16)
    printf '%s\t%s\n' "$rv" "$sha" >> "$T/digests.new"
done
bad_rv=""; new_rv=""
while IFS="$(printf '\t')" read -r rv sha; do
    old=$(grep "^$rv$(printf '\t')" "$DIG" 2>/dev/null | cut -f2)
    if [ -z "$old" ]; then new_rv="$new_rv $rv"; elif [ "$old" != "$sha" ]; then bad_rv="$bad_rv $rv"; fi
done < "$T/digests.new"
if [ $update -eq 1 ]; then
    if [ -n "$bad_rv" ] && [ $accept -eq 0 ]; then
        ko "K19: 映射输出变了而 rule_version 没升：${bad_rv} ——先升 tools/lib/map.mjs 的 RULE_VERSIONS 再 --update；确认只是 fixture 变了、规则没变才加 --accept-rule-digest（RULE-DIGESTS 没动）"
    else cp "$T/digests.new" "$DIG"; echo "  ↻ 已更新 RULE-DIGESTS（$(cut -f1 "$DIG" | tr '\n' ' ')）"; fi
elif [ ! -f "$DIG" ]; then ko "K19: 缺 expect/RULE-DIGESTS（跑 --update 生成）"
elif [ -n "$bad_rv" ]; then ko "K19: 映射输出变了而 rule_version 没升：${bad_rv}（改了映射规则就升 map.mjs 的 RULE_VERSIONS，再 --update）"
elif [ -n "$new_rv" ]; then ko "K19: 有没登记的 rule_version：${new_rv}（跑 --update 登记）"
else ok; fi
RV_NOW=$(node --input-type=module -e "import { RULE_VERSIONS } from '$SELF/lib/map.mjs'; console.log(JSON.stringify(Object.values(RULE_VERSIONS).sort()))")
check "K19: 四路 rule_version 都在钉子里，且与 map.mjs 的 RULE_VERSIONS 一致（${RV_NOW}）" \
    "(map(.provenance.rule_version) | unique | map(select(. != null))) == $RV_NOW" "$T/digest.in"

echo
[ "$skipped_schema" -gt 0 ] && echo "  ⚠ 本机 python3 没有 jsonschema，协议 schema 校验跳过 $skipped_schema 处（pip install jsonschema 后重跑）"
if [ $fail -eq 0 ]; then echo "  ✅ $pass/$pass 通过"; else echo "  ❌ $fail 失败 / $pass 通过"; exit 1; fi
