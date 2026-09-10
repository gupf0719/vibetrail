#!/bin/bash
# 多会话归属 demo —— 验证「工具调用前后给工作树拍快照 + 在快照链上跑 git blame」，
# 能否把「多个会话改、一个会话提交」的 commit 逐行归属到具体会话的具体工具调用。
#
# 为什么需要它：Claude-Session trailer 记的是谁执行了 commit，不是谁写的（spec §2 / §4.5）。
# 会话 A、B 改了代码、会话 C 一起提交，trailer 上只有 C。LoongSuite Pilot 这类采集器给得出
# Edit / Write 的参数，但 Bash 改的文件（sed / python3 / heredoc）只有命令没有结果，
# 人手改的完全看不到。需求、方案与限制见 TODO.md G11。
#
# 用法：bash experiments/attrib-demo.sh
#   在临时目录里建一个一次性仓库，模拟一串工具调用和一次人手改，最后打印本 commit 每一行的归属。
#   不碰当前仓库；跑完删掉临时目录（KEEP=1 保留，路径打印在末尾）。
#   真实场景里 snap 由 PreToolUse / PostToolUse hook 调用，这里手工在每一步前后调用。
#   只打印不断言——改成回归测试是 G11 的拆解项之一。
#
# 2026-09-10 在 macOS（git 2.39.5）实测：本 commit 新增或改动的 9 行全部归对。其中 sed 改的一行
# 记给 B:B1（Edit 记录里没有它），人手改的一行记为 gap（不是任何工具调用做的）。

set -euo pipefail
unset CLAUDE_CODE_SESSION_ID   # agent 起的 shell 自带这个变量；demo 不依赖它，去掉免得混淆
tmp=${TMPDIR:-/tmp}; WORK=$(mktemp -d "${tmp%/}/attrib-demo.XXXXXX")
[ "${KEEP:-}" = 1 ] || trap 'rm -rf "$WORK"' EXIT
D=$WORK/repo; LOG=$WORK/snaplog                  # 快照日志放在工作树之外，否则它自己会被拍进快照
mkdir -p "$D"; : > "$LOG"; cd "$D"
git init -q -b main .; git config user.name dev; git config user.email dev@example.com

printf 'def add(a, b):\n    return a + b\n\ndef div(a, b):\n    return a / b\n' > calc.py
printf 'def clamp(x, lo, hi):\n    return max(lo, min(x, hi))\n' > util.py
git add -A; git commit -qm base; BASE=$(git rev-parse HEAD)

# 快照 = 用一份独立的 index 把整个工作树写成 tree 对象；不碰真 index、不碰工作树。
# 未改动的文件与上一次快照共享 blob，新增的只有改过的文件内容。
SNAPIDX=$(git rev-parse --git-dir)/vibetrail-snap.index
snap() { # phase sid tool_use_id
    local t; t=$(GIT_INDEX_FILE=$SNAPIDX git add -A && GIT_INDEX_FILE=$SNAPIDX git write-tree)
    echo "$1 $2 $3 $t" >> "$LOG"
}
sub() { sed -i.bak "$1" "$2" && rm "$2.bak"; }   # 可移植的 sed -i（BSD 与 GNU 都认 -i.bak）

# 会话 A 工具调用 A1（Edit）：给 div 加零检查
snap pre A A1
printf 'def add(a, b):\n    return a + b\n\ndef div(a, b):\n    if b == 0:\n        raise ZeroDivisionError("b is 0")\n    return a / b\n' > calc.py
snap post A A1
# 会话 A 工具调用 A2（Bash 里用 python3 写新文件——Edit 记录里不会有它）
snap pre A A2
python3 -c 'open("report.py","w").write("def report(xs):\n    return sum(xs) / len(xs)\n")'
snap post A A2
# 人在 IDE 里手改（不触发任何 hook）：把 clamp 改错
sub 's/min(x, hi)/min(x, lo)/' util.py
# 会话 B 工具调用 B1（Bash sed -i）：把 add 改错
snap pre B B1
sub 's/return a + b/return a - b/' calc.py
snap post B B1
# 会话 C 工具调用 C1（Edit）：给 util.py 加函数
snap pre C C1
printf '\ndef lerp(a, b, t):\n    return a + (b - a) * t\n' >> util.py
snap post C C1
# 会话 C 工具调用 C2（Bash）：一次提交全部。装了 prepare-commit-msg 的话 trailer 只会记 C
snap pre C C2
git add -A; git commit -qm "feature: several things"
snap post C C2
COMMIT=$(git rev-parse HEAD)

# ---- post-commit 时做的事：把快照日志重放成一条影子历史，每一步的作者 = 谁造成了这一步 ----
prev_tree=$(git rev-parse "$BASE^{tree}"); tip=$BASE; last_post="(base)"
while read -r phase sid tuid tree; do
    if [ "$phase" = pre ]; then label="gap:after-$last_post"   # 两次工具调用之间冒出来的改动 = 不是 agent 工具调用做的
    else label="$sid:$tuid"; last_post="$sid:$tuid"; fi
    [ "$tree" = "$prev_tree" ] && continue
    tip=$(GIT_AUTHOR_NAME="$label" GIT_AUTHOR_EMAIL=x GIT_COMMITTER_NAME=x GIT_COMMITTER_EMAIL=x \
          git commit-tree "$tree" -p "$tip" -m "$label"); prev_tree=$tree
done < "$LOG"
ctree=$(git rev-parse "$COMMIT^{tree}")                         # 真 commit 的 tree（部分暂存时与最后一个快照不同）
if [ "$ctree" != "$prev_tree" ]; then
    tip=$(GIT_AUTHOR_NAME=commit-time GIT_AUTHOR_EMAIL=x GIT_COMMITTER_NAME=x GIT_COMMITTER_EMAIL=x \
          git commit-tree "$ctree" -p "$tip" -m commit-time)
fi

echo "== 本 commit 新增或改动的行，逐行归属（gap = 不是任何 agent 工具调用做的）=="
for f in $(git diff --name-only "$BASE" "$COMMIT"); do
    git blame --line-porcelain "$tip" -- "$f" | awk -v f="$f" -v base="$BASE" '
        /^[0-9a-f]+ [0-9]+ [0-9]+/ { sha = $1; ln = $3 }
        /^author /                 { a = substr($0, 8) }
        /^\t/                      { if (sha != base) printf "%-10s L%-3s %-16s %s\n", f, ln, a, substr($0, 2) }'
done
[ "${KEEP:-}" = 1 ] && echo "临时仓库保留在 $D（快照日志 $LOG）"
exit 0
