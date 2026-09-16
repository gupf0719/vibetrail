#!/bin/bash
# 回归：协议映射（分歧一路）。钉四件事——
#   1. 每份 fixture 的事件与 golden（fixtures-map/expect/<名>.jsonl）整条一致；关键字段另有显式断言，golden 漂了也说得出是哪一项
#   2. 每条事件过协议 1.0 schema（schema-check.py，仓内原件）；event_id 唯一且两次运行一致
#   3. A2 进出对账：提取器单独跑出的每类命中数 == 映射出的对应事件数（人拒 → decided_by user，分类器 → policy，
#      链路 → system，打断 → turn.end / subagent.end，for-tool-use → 吸收 + 未配对）
#   4. 增量等价：对每个切点 L，「前 L 行全量扫」∪「全文从 L 起扫」== 「全文全量扫」——派生事件跟触发记录走、去重不看门控，
#      这两条不成立时这里会红；再加一路「从前段账本给的 checkpoint_line（本轮开头）读起」，钉住 U11 的按轮增量
# 用法：test-map.sh [--update]   --update 重新生成 golden（先看 diff 再提交）
# 固定 C locale：macOS 自带的 bash 3.2 在 UTF-8 locale 下会把紧跟在变量名后的中文字符首字节算进变量名（变量名后紧跟「）」时，bash 找的是「V 加上「）」的首字节」这个变量），
# 开了 set -u 就报 unbound variable（用户 09-15 的终端踩到），没开就悄悄展开成空；tr / sort 的结果也随 locale 变。放在最前面，后面的解析都按 C
export LC_ALL=C
set -uo pipefail
cd "$(dirname "$0")"; SELF=$PWD; FX=$SELF/fixtures-map
FILES=("$FX"/*.jsonl "$FX"/fx-*/subagents/agent-*.jsonl)
T=$(mktemp -d "${TMPDIR:-/tmp}/vibetrail-test-map.XXXXXX"); trap 'rm -rf "$T"' EXIT
update=0; [ "${1:-}" = "--update" ] && update=1
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
    local n=$1 f=$2; shift 2
    bash "$SELF/vibetrail-map" "$f" --no-turns --capture-content "${CAP:-0}" --ledger "$T/$n.ledger" "$@" > "$T/$n.events" 2> "$T/$n.err" \
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
check "interrupt-text: turn.end 状态、用量按 message.id 去重、分支" '.[1].payload.status == {code:"interrupted",category:"cancellation",detail:"[Request interrupted by user]"} and .[1].payload.usage == {input_tokens:15,cached_input_tokens:100,output_tokens:20,reasoning_tokens:8,total_tokens:135} and .[1].payload.vcs.branch == "main" and .[1].turn_id == "p1" and .[1].provenance == {kind:"transcript",rule_version:"diverge-v1",source_event_id:"i1"}' "$e"
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
check "no-promptid: 没有 promptId 的打断按位置推轮次，provenance 标 inferred" '[.[] | select(.type=="turn.end")] | length == 2 and .[0].turn_id == "i0" and .[0].provenance.kind == "inferred" and .[1].turn_id == "p1" and .[1].provenance.kind == "inferred" and .[1].provenance.rule_version == "diverge-v1"' "$e"
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
check "edge: 越过合成记录找到真实回复，model 与用量不含合成记录" '.[0].type == "message.assistant" and .[0].payload.text == "我先删掉安装那一节。" and .[1].payload.model == "claude-opus-5" and .[1].payload.usage == {input_tokens:4,cached_input_tokens:40,output_tokens:9,total_tokens:53} and .[1].extensions["vibetrail.interrupted_uuid"] == "a1"' "$e"
check "edge: 斜杠命令规范成一句发出，标 slash_command，不结束等待" '.[2].type == "message.user" and .[2].payload.text == "/model claude-opus-5" and .[2].extensions["vibetrail.slash_command"] == true and .[2].extensions["vibetrail.after"] == ["i1"]' "$e"
check "edge: 之后打的字照样发，指回同一次打断；本地命令输出不算人话" '.[3].payload.text == "换个模型再试，只删安装那一节" and .[3].extensions["vibetrail.after"] == ["i1"] and (.[3].extensions | has("vibetrail.slash_command") | not) and all(.[]; .payload.text != "<local-command-stdout>Set model to claude-opus-5</local-command-stdout>")' "$e"
check "edge: 缺 message.id 时按 requestId 去重，断链时按本轮顺序兜底" '.[5].type == "turn.end" and .[5].payload.usage == {input_tokens:6,cached_input_tokens:60,output_tokens:12,total_tokens:78} and .[5].extensions["vibetrail.interrupted_uuid"] == "a3" and .[4].payload.text == "好，只删安装一节，其余不动。"' "$e"
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
     and .extensions["vibetrail.content_dropped"] == "size" and .payload.tool_name == "Bash" and .payload.status.code == "success")' "$b"
check "1 MiB: 同一批里没超限的照常带正文（人话、工具参数）" \
    'any(.[]; .type=="message.user" and .payload.text == "把大日志打出来" and .content_state == "included")
     and any(.[]; .type=="tool.request" and .payload.input.command == "cat big.log")' "$b"
check "1 MiB: 每条事件都在协议上限内" 'all(.[]; (tojson | utf8bytelength) < 1048576)' "$b"
schema_check < "$b" > "$T/schema.big" && ok || ko "1 MiB: $(cat "$T/schema.big")"

# hook 不传 --capture-content，走的是 config：这条链路单独钉一下，三种情形（开 / 关 / 没写＝默认开）
for m in on off default; do
    mkdir -p "$T/cfg-$m"
    case $m in on) printf 'capture_content=1\n';; off) printf 'capture_content=0\n';; *) printf 'scope=project\n';; esac > "$T/cfg-$m/config"
    VIBETRAIL_HOME=$T/cfg-$m bash "$SELF/vibetrail-map" "$T/scenario.jsonl" --sid s --project-id p --workspace-id w \
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

echo
[ "$skipped_schema" -gt 0 ] && echo "  ⚠ 本机 python3 没有 jsonschema，协议 schema 校验跳过 $skipped_schema 处（pip install jsonschema 后重跑）"
if [ $fail -eq 0 ]; then echo "  ✅ $pass/$pass 通过"; else echo "  ❌ $fail 失败 / $pass 通过"; exit 1; fi
