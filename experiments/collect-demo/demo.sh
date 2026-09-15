#!/bin/bash
# 沙箱演示：安装 → 采集 → 在本地文件里看采了什么。全程在一个临时目录里，不碰真实的 ~/.claude 与 ~/.vibetrail。
#
#   bash experiments/collect-demo/demo.sh [沙箱目录]
#
# 1. 在沙箱里建一个 git 仓当被观测项目，在仓里跑 vibetrail init（写沙箱的 settings.json、登记本仓）
# 2. 按 scenario.json 回放一段会话：往沙箱的 transcript 追加记录；轮到 hook 时，用沙箱 settings.json 里 init 真实写下的那条命令去跑，
#    stdin 给 Claude Code 同样形状的 payload（prompt_id 取当轮的 promptId）。第 1 轮中途在仓里真的提交一次，演示 commit ↔ 轮次
# 3. vibetrail list / show / doctor，最后列出 spool 目录与被观测仓的 git status（零写入）
# 跑完沙箱留着，想翻原始文件就进去看；不想留就 rm -rf 它。
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

hr "1. 安装：在被观测仓里跑一次 vibetrail init"
( cd "$REPO" && bash "$TOOLS/vibetrail" init )
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
n=0
while IFS= read -r step; do
    n=$((n + 1))
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
done < "$D/steps.jsonl"

hr "3. 看采了什么"
bash "$VIBETRAIL_HOME/bin/vibetrail" list
echo; bash "$VIBETRAIL_HOME/bin/vibetrail" show
hr "4. 自检"
( cd "$REPO" && bash "$VIBETRAIL_HOME/bin/vibetrail" doctor )
hr "5. 被观测仓里零写入（A8）"
echo "git status --porcelain：$( [ -z "$(git -C "$REPO" status --porcelain)" ] && echo '空' || git -C "$REPO" status --porcelain)"
echo "仓里的 .git/hooks：$(ls "$REPO/.git/hooks" | grep -v '\.sample$' | tr '\n' ' ')（只有 git 自带的 sample 就对了）"
echo
echo "沙箱：$D"
echo "  spool 文件：$VIBETRAIL_HOME/spool/   直接 cat 就能看，每行一条协议事件"
echo "  卸载演示：VIBETRAIL_HOME=$VIBETRAIL_HOME VIBETRAIL_CLAUDE_SETTINGS=$VIBETRAIL_CLAUDE_SETTINGS bash $VIBETRAIL_HOME/bin/vibetrail uninstall"
