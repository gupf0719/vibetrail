#!/bin/bash
# 多会话归属 demo —— 验证「工具调用前后给工作树拍快照 + 在影子历史上跑 git blame」，
# 能否把「多个会话改、一个会话提交」的 commit 逐行归属到具体会话的具体工具调用。
#
# 为什么需要它：Claude-Session trailer 记的是谁执行了 commit，不是谁写的（spec §2 / §4.5）。
# 会话 A、B 改了代码、会话 C 一起提交，trailer 上只有 C。LoongSuite Pilot 这类采集器给得出
# Edit / Write 的参数，但 Bash 改的文件（sed / python3 / heredoc）只有命令、没有改后的内容，
# 人手改的完全看不到。需求、方案与限制见 TODO.md G11。
#
# 用法：bash experiments/attrib-demo.sh
#   在临时目录里建一次性仓库，模拟工具调用、人手改和提交，每次提交后打印本 commit 每一行的归属。
#   不碰当前仓库；跑完删掉临时目录（KEEP=1 保留，路径打印在末尾）。
#   真实场景里 snap 由 PreToolUse / PostToolUse hook 调用，attribute 由 post-commit hook 调用，
#   这里手工调用。只打印不断言——改成回归测试是 G11 的拆解项之一。
#
# 主场景刻意包含第一版 demo 会出错的三种情况（2026-09-11 独立审计抓到、已复现）：BASE 之前还有历史；
# 第一次提交只带走一部分改动，剩下的留到第二次提交；第二次提交删了一个文件。另有四个边界场景，
# 对应审计抓到的另外两类错：交错与并行的工具调用、已跟踪但匹配 .gitignore 的文件、并发快照抢锁。
#
# 2026-09-11 在 macOS（git 2.39.5、/bin/bash 3.2）实测，输出见 TODO.md G11 §5。

set -euo pipefail
unset CLAUDE_CODE_SESSION_ID   # agent 起的 shell 自带这个变量；demo 不依赖它，去掉免得混淆
tmp=${TMPDIR:-/tmp}; WORK=$(mktemp -d "${tmp%/}/attrib-demo.XXXXXX")
[ "${KEEP:-}" = 1 ] || trap 'rm -rf "$WORK"' EXIT
SHADOW=refs/vibetrail/shadow   # 影子历史：本地 ref，默认 refspec 不推送它

newrepo() { # name → 在 $WORK/<name> 建一个空仓并进入。OPEN 记进行中的工具调用，每行「线程 线程:调用」，放工作树外
    mkdir -p "$WORK/$1"; cd "$WORK/$1"; OPEN=$WORK/$1.open; : > "$OPEN"
    git init -q -b main .; git config user.name dev; git config user.email dev@example.com
}
mkc() { # tree parent label → 影子提交（作者名 = 这一步归给谁）
    GIT_AUTHOR_NAME="$3" GIT_AUTHOR_EMAIL=x GIT_COMMITTER_NAME=x GIT_COMMITTER_EMAIL=x \
        git commit-tree "$1" ${2:+-p "$2"} -m "$3"
}
in_progress() { # 此刻进行中的工具调用；一个都没有就是 gap（不是任何 agent 工具调用做的），多个就并列
    if [ -s "$OPEN" ]; then cut -d' ' -f2 "$OPEN" | sort | paste -sd'|' -; else echo gap; fi
}

# 快照：复制一份真 index 当起点，add -A 后 write-tree。不碰真 index、不碰工作树。
# 从真 index 起步，已跟踪但匹配 .gitignore 的文件不会漏，stat 缓存也是热的；每次一份副本，并发不抢锁。
snaptree() {
    local d t; d=$(mktemp -d)
    cp "$(git rev-parse --git-path index)" "$d/index" 2>/dev/null || true
    t=$(GIT_INDEX_FILE=$d/index git add -A && GIT_INDEX_FILE=$d/index git write-tree) || { rm -rf "$d"; return 1; }
    rm -rf "$d"; echo "$t"
}
# 与影子历史末端不同就接一步，这一步归给「上一个快照到这个快照之间」进行中的工具调用。
# 真实实现里追加要用 update-ref 的旧值校验防并发覆盖，demo 是串行的，省了。
snap() { # pre|post 线程 调用
    local t tip; t=$(snaptree)
    tip=$(git rev-parse -q --verify "$SHADOW" || true)
    if [ -z "$tip" ]; then git update-ref "$SHADOW" "$(mkc "$t" "" 快照开始前已在工作树里)"
    elif [ "$(git rev-parse "$tip^{tree}")" != "$t" ]; then git update-ref "$SHADOW" "$(mkc "$t" "$tip" "$(in_progress)")"; fi
    # pre / post 按线程配对，不看相邻顺序；同一线程的新 pre 到来时，它上一个没等到 post 的调用视为已结束
    grep -v "^$2 " "$OPEN" > "$OPEN.new" || true; mv "$OPEN.new" "$OPEN"
    if [ "$1" = pre ]; then echo "$2 $2:$3" >> "$OPEN"; fi
}

# post-commit：影子历史末端临时接上真 commit 的 tree（最后一个快照到提交之间的差额，归给此刻进行中的调用），
# 只对本 commit 相对父提交新增或改动的行跑 blame。影子历史跨提交连续、不在每次提交时重开，所以上一次
# 提交没带走的改动仍归给当初写它的调用；部分暂存时被「改回去」的行不在本 commit 的 diff 里，不会被报。
attribute() { # commit
    local c=$1 p tip f ranges
    p=$(git rev-parse "$c^"); tip=$(git rev-parse "$SHADOW")
    [ "$(git rev-parse "$c^{tree}")" = "$(git rev-parse "$tip^{tree}")" ] ||
        tip=$(mkc "$(git rev-parse "$c^{tree}")" "$tip" "$(in_progress)")
    echo "== $(git log -1 --format=%s "$c") —— 本 commit 新增或改动的行 =="
    for f in $(git diff --name-only --diff-filter=d "$p" "$c"); do      # 删掉的文件没有新侧的行
        ranges=$(git diff -U0 "$p" "$c" -- "$f" |
            sed -nE 's/^@@ -[0-9,]+ \+([0-9]+)(,([0-9]+))? @@.*/\1 \3/p' |
            awk '{ n = ($2 == "") ? 1 : $2; if (n > 0) printf " -L %d,+%d", $1, n }')
        [ -n "$ranges" ] || continue
        # -M / -C：认同文件内的行移动与跨文件复制（带阈值的启发式）
        git blame --line-porcelain -M -C $ranges "$tip" -- "$f" | awk -v f="$f" '
            /^[0-9a-f]+ [0-9]+ [0-9]+/ { ln = $3 }
            /^author /                 { a = substr($0, 8) }
            /^\t/                      { printf "%-10s L%-3s %-8s %s\n", f, ln, a, substr($0, 2) }'
    done
}
sub() { sed -i.bak "$1" "$2" && rm "$2.bak"; }   # 可移植的 sed -i（BSD 与 GNU 都认 -i.bak）

echo "######## 主场景：三个会话 + 一次人手改，分两次提交"
newrepo main
# 历史：BASE 之前还有提交（归属不能假设 BASE 是根提交）
printf '# demo\n' > README.md; git add -A; git commit -qm init
printf 'def add(a, b):\n    return a + b\n\ndef div(a, b):\n    return a / b\n' > calc.py
printf 'def clamp(x, lo, hi):\n    return max(lo, min(x, hi))\n' > util.py
printf 'def old():\n    pass\n' > legacy.py
git add -A; git commit -qm base
# 会话 A
snap pre A A1    # Edit：给 div 加零检查
printf 'def add(a, b):\n    return a + b\n\ndef div(a, b):\n    if b == 0:\n        raise ZeroDivisionError("b is 0")\n    return a / b\n' > calc.py
snap post A A1
snap pre A A2    # Bash 里用 python3 写新文件（Edit 记录里不会有它）
python3 -c 'open("report.py","w").write("def report(xs):\n    return sum(xs) / len(xs)\n")'
snap post A A2
snap pre A A3    # Edit：给 clamp 加 docstring
printf 'def clamp(x, lo, hi):\n    """Clamp x into [lo, hi]."""\n    return max(lo, min(x, hi))\n' > util.py
snap post A A3
snap pre A A4    # Bash：只提交 calc.py；report.py 与 util.py 的改动留在工作树
git add calc.py; git commit -qm "div: zero check"; attribute HEAD     # ← post-commit hook
snap post A A4
# 人在 IDE 里手改（不触发任何 hook）：把 clamp 改错
sub 's/min(x, hi)/min(x, lo)/' util.py
# 会话 B
snap pre B B1    # Bash sed -i：把 add 改错
sub 's/return a + b/return a - b/' calc.py
snap post B B1
# 会话 C
snap pre C C1    # Edit：给 util.py 加函数
printf '\ndef lerp(a, b, t):\n    return a + (b - a) * t\n' >> util.py
snap post C C1
snap pre C C2    # Bash：删掉 legacy.py、提交全部。装了 prepare-commit-msg 的话 trailer 只会记 C
git rm -q legacy.py; git add -A; git commit -qm "feature: several things"; attribute HEAD
snap post C C2

echo; echo "######## 边界 1：X 进行中时 Y 开始（如并行的子 agent），改动各归各的"
newrepo interleave; printf 'a\nb\nc\n' > f.txt; git add -A; git commit -qm base
snap pre P X; sub 's/^a$/A-by-X/' f.txt
snap pre Q Y; snap post P X; sub 's/^c$/C-by-Y/' f.txt; snap post Q Y
git commit -qam "human commit"; attribute HEAD

echo; echo "######## 边界 2：两个调用都在进行中时发生的改动 → 标并列，不硬猜"
newrepo overlap; printf 'a\nb\n' > f.txt; git add -A; git commit -qm base
snap pre P X; snap pre Q Y; sub 's/^b$/B-by-X-or-Y/' f.txt; snap post P X; snap post Q Y
git commit -qam "human commit"; attribute HEAD

echo; echo "######## 边界 3：已跟踪但匹配 .gitignore 的文件，只报改动的那一行"
newrepo ignored; printf '*.lock\n' > .gitignore; printf 'v1\nkeep\n' > deps.lock
git add .gitignore; git add -f deps.lock; git commit -qm base
snap pre A A1; sub 's/^v1$/v2/' deps.lock; snap post A A1
git commit -qam "bump"; attribute HEAD

echo; echo "######## 边界 4：并发快照（每次复制一份 index），30 轮 × 2 路"
newrepo concurrent; for i in $(seq 200); do echo "$i" > "f$i"; done; git add -A; git commit -qm base
for r in $(seq 30); do
    for k in 1 2; do ( echo "$r$k" > "f$k"; snaptree > /dev/null ) 2>> "$WORK/concurrent.err" & done
    wait
done
echo "快照失败 $(grep -c . "$WORK/concurrent.err" || true) 次（其中 index.lock 冲突 $(grep -c 'index.lock' "$WORK/concurrent.err" || true) 次）"

[ "${KEEP:-}" = 1 ] && echo "临时目录保留在 $WORK"
exit 0
