#!/bin/bash
# 沙箱演示：安装 → 采集 → 在本地文件里看采了什么。全程在一个临时目录里，不碰真实的 ~/.claude 与 ~/.vibetrail。
#
#   bash experiments/collect-demo/demo.sh [沙箱目录]
#
# 1. 在沙箱里建一个 git 仓当被观测项目，跑 vibetrail init（写沙箱的 settings.json；init 不登记任何仓），再 projects add 登记它
# 2. 按 scenario.json 回放一段会话：往沙箱的 transcript 追加记录；轮到 hook 时，用沙箱 settings.json 里 init 真实写下的那条命令去跑，
#    stdin 给 Claude Code 同样形状的 payload（prompt_id 取当轮的 promptId）。第 1 轮中途在仓里真的提交一次，演示 commit ↔ 轮次。
#    每次 Stop 之后再写一条 stop_hook_summary：Claude Code 的「答完」标记，desktop 要等下一句人话才把它落盘（09-15 核过），所以 turn.end 不等它，Stop 时就发（DESIGN D7）。
#    会话结束前再加一轮：第一次 Stop 被别的 Stop hook 拦下（拦停反馈先落盘），模型补完再 Stop——这一轮只出一条 turn.end，带两次提交
# 3. vibetrail list / show / doctor，最后列出 spool 目录与被观测仓的 git status（零写入），再用 report.sh 生成一份 markdown 报告
# 跑完沙箱留着，想翻原始文件就进去看；不想留就 rm -rf 它。
# 固定 C locale：macOS 自带的 bash 3.2 在 UTF-8 locale 下会把紧跟在变量名后的中文字符首字节算进变量名（变量名后紧跟「）」时，bash 找的是「V 加上「）」的首字节」这个变量），
# 开了 set -u 就报 unbound variable（用户 09-15 的终端踩到），没开就悄悄展开成空；tr / sort 的结果也随 locale 变。放在最前面，后面的解析都按 C
export LC_ALL=C
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TOOLS=$(cd "$HERE/../../tools" && pwd); SC=$HERE/scenario.json
D=${1:-$(mktemp -d "${TMPDIR:-/tmp}/vibetrail-demo.XXXXXX")}; mkdir -p "$D"; D=$(cd "$D" && pwd -P)
export VIBETRAIL_HOME=$D/home/.vibetrail VIBETRAIL_CLAUDE_SETTINGS=$D/home/.claude/settings.json \
       VIBETRAIL_CLAUDE_PROJECTS=$D/home/.claude/projects VIBETRAIL_STABLE_WAIT=0 VIBETRAIL_FOREGROUND=1
unset CLAUDE_CODE_SESSION_ID AI_AGENT          # 在 Claude Code 里跑本脚本时别把外层会话的环境带进来
export CLAUDE_CODE_ENTRYPOINT=cli
hr(){ printf '\n\033[1m━━ %s\033[0m\n' "$*"; }

REPO=$D/demo-proj; SID=11111111-2222-4333-8444-555555555555
rm -rf "$REPO"; mkdir -p "$REPO" "$(dirname "$VIBETRAIL_CLAUDE_SETTINGS")"
( cd "$REPO" && git init -q -b main && git config user.email demo@example.com && git config user.name demo \
  && jq -r '.files["calc.py"]' "$SC" > calc.py && git add -A && git commit -q -m "init" \
  && git remote add origin git@example.com:demo/demo-proj.git )
printf '{\n  "permissions": {"allow": ["Bash(ls:*)"]}\n}\n' > "$VIBETRAIL_CLAUDE_SETTINGS"   # 用户原有的 settings，装卸都不能动它

hr "1. 安装：跑一次 vibetrail init，再登记要采的仓（init 不会自己加）"
( cd "$REPO" && bash "$TOOLS/vibetrail" init && bash "$TOOLS/vibetrail" projects add )
echo; echo "沙箱 settings.json 里现在的 hook 事件（原有的 permissions 原样保留）："
jq -c '{permissions, hook_events: (.hooks | keys)}' "$VIBETRAIL_CLAUDE_SETTINGS"
echo "其中 Stop 那一条："; jq -c '.hooks.Stop' "$VIBETRAIL_CLAUDE_SETTINGS"

hr "2. 采集：回放 scenario.json（$(jq '.steps | length' "$SC") 步），hook 用 settings 里写下的命令触发"
TDIR=$VIBETRAIL_CLAUDE_PROJECTS/$(printf '%s' "$REPO" | sed 's/[^A-Za-z0-9]/-/g'); TR=$TDIR/$SID.jsonl
mkdir -p "$TDIR"; : > "$TR"
# 每个 hook 步骤补上 prompt_id：UserPromptSubmit 取下一条人话的 promptId，其余取最近一条 user 记录的 promptId
jq -c '.steps | to_entries as $s | $s[] | .key as $i | .value
       | if has("hook") then {hook: (.hook + {prompt_id: (
             if .hook.hook_event_name == "UserPromptSubmit"
             then ([$s[] | select(.key > $i) | .value.append? | select(.type == "user") | .promptId][0])
             else ([$s[] | select(.key < $i) | .value.append? | select(.type == "user") | .promptId] | last) end)})}
         else . end' "$SC" > "$D/steps.jsonl"
now_ms(){ jq -n -r 'now | (floor | todate | sub("Z$"; "")) + "." + ((. * 1000 | floor) % 1000 | tostring | ("00" + .)[-3:]) + "Z"'; }
append(){ # append <记录 JSON>：补上会话公共字段与此刻的时间戳，接到 transcript 末尾
    printf '%s' "$1" | jq -c --arg sid "$SID" --arg cwd "$REPO" --arg ts "$(now_ms)" \
        '. + {sessionId: $sid, cwd: $cwd, timestamp: $ts, version: "2.1.266", entrypoint: "cli", gitBranch: "main", isSidechain: false}' >> "$TR"
    sleep 0.05
}
summary(){ # summary <拦停原因，空＝没拦>：Claude Code 跑完这次 Stop 的 hook 后写的记录
    append "$(jq -n -c --arg e "${1:-}" '{type: "system", subtype: "stop_hook_summary", uuid: ("sum-" + (now | tostring)), hookCount: 2,
        hookInfos: [{command: "callback"}, {command: "vibetrail-hook Stop"}], hookErrors: (if $e == "" then [] else [$e] end),
        hookAdditionalContext: [], preventedContinuation: false, stopReason: "", hasOutput: ($e != ""), level: "suggestion"}')"
}
fire(){ # fire <事件> [额外 payload 字段 JSON]：用 settings 里写下的命令触发一次 hook
    local ev=$1 extra=${2:-} cmd out rc; [ -n "$extra" ] || extra='{}'
    cmd=$(jq -r --arg ev "$ev" '.hooks[$ev][]?.hooks[]? | select(.command | contains("vibetrail-hook")) | .command' "$VIBETRAIL_CLAUDE_SETTINGS" | head -1)
    jq -n -c --arg sid "$SID" --arg tp "$TR" --arg cwd "$REPO" --arg ev "$ev" --argjson x "$extra" \
        '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: $ev, permission_mode: "default"} + $x' > "$D/payload.json"
    out=$(sh -c "$cmd" < "$D/payload.json" 2>&1); rc=$?
    printf '  +  %-18s exit=%s stdout=%s  prompt_id=%s\n' "$ev" "$rc" "$( [ -z "$out" ] && echo 空 || echo "非空！" )" "$(jq -r '.prompt_id // "-"' "$D/payload.json")"
}
n=0
while IFS= read -r step; do
    n=$((n + 1))
    if [ "$(printf '%s' "$step" | jq -r '.hook.hook_event_name // ""')" = SessionEnd ]; then
        # ---- 会话结束前加一轮：第一次 Stop 被别的 Stop hook 拦下，模型补完再 Stop ----
        echo "  ── 加一轮：第一次 Stop 被别的 Stop hook 拦下（照 agentDock 的审计闸门），模型补完再 Stop ──"
        fire UserPromptSubmit '{"prompt":"把 README 也补一句","prompt_id":"prompt-4"}'
        append '{"type":"user","uuid":"b4-u1","parentUuid":null,"promptId":"prompt-4","message":{"role":"user","content":"把 README 也补一句"}}'
        append '{"type":"assistant","uuid":"b4-a1","parentUuid":"b4-u1","requestId":"rb1","message":{"id":"mb1","role":"assistant","model":"claude-opus-5","stop_reason":"tool_use","content":[{"type":"tool_use","id":"tb1","name":"Bash","input":{"command":"git commit -am \"README: 补一句\""}}],"usage":{"input_tokens":40,"output_tokens":20}}}'
        ( cd "$REPO" && echo "# demo" >> README.md && git add README.md && git commit -q -m "README: 补一句" && echo "     ↳ 仓里提交了一次：$(git log -1 --format='%h %s')" )
        append '{"type":"user","uuid":"b4-u2","parentUuid":"b4-a1","promptId":"prompt-4","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tb1","content":"[main] README: 补一句"}]}}'
        append '{"type":"assistant","uuid":"b4-a2","parentUuid":"b4-u2","requestId":"rb2","message":{"id":"mb2","role":"assistant","model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"补好了。"}],"usage":{"input_tokens":60,"output_tokens":8}}}'
        # 别的 Stop hook 拦下：拦停反馈先写，summary 后写（2.1.266 的顺序），模型在同一个 promptId 下接着干
        append '{"type":"attachment","uuid":"b4-h1","parentUuid":"b4-a2","attachment":{"type":"hook_blocking_error","hookName":"Stop","hookEvent":"Stop","blockingError":{"blockingError":"缺审计记录，先补一条再结束","command":"check-audit-stop.sh"}}}'
        append '{"type":"user","uuid":"b4-u3","parentUuid":"b4-h1","promptId":"prompt-4","isMeta":true,"message":{"role":"user","content":"Stop hook feedback:\n缺审计记录，先补一条再结束"}}'
        fire Stop '{"prompt_id":"prompt-4","stop_hook_active":false}'
        summary "缺审计记录，先补一条再结束"
        echo "     ↳ 第一次 Stop 被拦下之后：prompt-4 的 turn.end 有 $(cat "$VIBETRAIL_HOME"/spool/*/*/*.jsonl | jq -s '[.[] | select(.type == "turn.end" and .turn_id == "prompt-4")] | length') 条（应为 0）"
        append '{"type":"assistant","uuid":"b4-a3","parentUuid":"b4-u3","requestId":"rb3","message":{"id":"mb3","role":"assistant","model":"claude-opus-5","stop_reason":"tool_use","content":[{"type":"tool_use","id":"tb2","name":"Bash","input":{"command":"git commit -am \"audit: 补记录\""}}],"usage":{"input_tokens":80,"output_tokens":20}}}'
        ( cd "$REPO" && echo "audit ok" > AUDIT.md && git add AUDIT.md && git commit -q -m "audit: 补记录" && echo "     ↳ 仓里又提交了一次：$(git log -1 --format='%h %s')" )
        append '{"type":"user","uuid":"b4-u4","parentUuid":"b4-a3","promptId":"prompt-4","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tb2","content":"[main] audit: 补记录"}]}}'
        append '{"type":"assistant","uuid":"b4-a4","parentUuid":"b4-u4","requestId":"rb4","message":{"id":"mb4","role":"assistant","model":"claude-opus-5","stop_reason":"end_turn","content":[{"type":"text","text":"审计记录补上了。"}],"usage":{"input_tokens":90,"output_tokens":10}}}'
        fire Stop '{"prompt_id":"prompt-4","stop_hook_active":true}'
        summary ""
        echo "     ↳ 第二次 Stop 之后：prompt-4 的 turn.end 有 $(cat "$VIBETRAIL_HOME"/spool/*/*/*.jsonl | jq -s '[.[] | select(.type == "turn.end" and .turn_id == "prompt-4")] | length') 条（应为 1）"
    fi
    if [ "$(printf '%s' "$step" | jq 'has("append")')" = true ]; then
        # 记录的时间戳换成此刻（场景里写的是 09-11 的固定时间），与 hook 事件的时间对得上
        printf '%s' "$step" | jq -c --arg cwd "$REPO" \
            '.append | .cwd = $cwd | .timestamp = (now | (floor | todate | sub("Z$"; "")) + "." + ((. * 1000 | floor) % 1000 | tostring | ("00" + .)[-3:]) + "Z")' >> "$TR"
        sleep 0.05
        continue
    fi
    ev=$(printf '%s' "$step" | jq -r '.hook.hook_event_name')
    # 第 1 轮里 Edit 之后，在仓里真的提交一次（演示 turn.end 的 commits：轮起 HEAD..轮止 HEAD）
    if [ "$ev" = PostToolUse ] && [ "$(jq -r '.hook.tool_name' <<< "$step")" = Edit ]; then
        ( cd "$REPO" && printf 'def add(a, b):\n    return a + b\n\ndef div(a, b):\n    if b == 0:\n        raise ZeroDivisionError("b is 0")\n    return a / b\n' > calc.py \
          && git commit -q -am "div: 加零检查" && echo "     ↳ 仓里提交了一次：$(git log -1 --format='%h %s')" )
    fi
    cmd=$(jq -r --arg ev "$ev" '.hooks[$ev][]?.hooks[]? | select(.command | contains("vibetrail-hook")) | .command' "$VIBETRAIL_CLAUDE_SETTINGS" | head -1)
    if [ -z "$cmd" ]; then printf '  %2d %-18s （没挂 vibetrail）\n' "$n" "$ev"; continue; fi

    printf '%s' "$step" | jq -c --arg sid "$SID" --arg tp "$TR" --arg cwd "$REPO" \
        '.hook | .session_id = $sid | .transcript_path = $tp | .cwd = $cwd | if .prompt_id == null then del(.prompt_id) else . end' > "$D/payload.json"
    out=$(sh -c "$cmd" < "$D/payload.json" 2>&1); rc=$?
    printf '  %2d %-18s exit=%s stdout=%s  prompt_id=%s\n' "$n" "$ev" "$rc" "$( [ -z "$out" ] && echo 空 || echo "非空！" )" "$(jq -r '.prompt_id // "-"' "$D/payload.json")"
    if [ "$ev" = Stop ]; then   # Stop hook 跑完才有的「答完」标记（desktop 等下一句人话才落盘；场景文件是 09-11 录的，那时还没这条）
        summary ""
        echo "     ↳ 这一轮的 turn.end：$(cat "$VIBETRAIL_HOME"/spool/*/*/*.jsonl | jq -s -r --arg p "$(jq -r .prompt_id "$D/payload.json")" '[.[] | select(.type == "turn.end" and .turn_id == $p)] | length') 条（Stop 时就写了，不等 summary）"
    fi
done < "$D/steps.jsonl"

hr "3. 看采了什么"
bash "$VIBETRAIL_HOME/bin/vibetrail" list
echo; bash "$VIBETRAIL_HOME/bin/vibetrail" show
hr "4. 自检"
( cd "$REPO" && bash "$VIBETRAIL_HOME/bin/vibetrail" doctor )
hr "5. 被观测仓里零写入（A8）"
echo "git status --porcelain：$( [ -z "$(git -C "$REPO" status --porcelain)" ] && echo '空' || git -C "$REPO" status --porcelain)"
echo "仓里的 .git/hooks：$(ls "$REPO/.git/hooks" | grep -v '\.sample$' | tr '\n' ' ')（只有 git 自带的 sample 就对了）"
hr "6. markdown 报告（只供测试、演示）：每一轮的元数据 / 人机分歧 / commit ↔ 会话 三块分开"
bash "$HERE/report.sh"
echo
echo "沙箱：$D"
echo "  spool 文件：$VIBETRAIL_HOME/spool/   直接 cat 就能看，每行一条协议事件"
echo "  卸载演示：VIBETRAIL_HOME=$VIBETRAIL_HOME VIBETRAIL_CLAUDE_SETTINGS=$VIBETRAIL_CLAUDE_SETTINGS bash $VIBETRAIL_HOME/bin/vibetrail uninstall"
