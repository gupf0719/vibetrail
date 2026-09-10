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
#   真实场景里 snap 由 PreToolUse / PostToolUse hook 调用，endturn 由 UserPromptSubmit / Stop /
#   SubagentStop / SessionEnd 调用，attribute 由 post-commit hook 调用；这里手工调用。
#   只打印不断言——改成回归测试是 G11 的拆解项之一。
#
# 主场景之外的十个边界场景，每个对应两轮独立审计（2026-09-11）抓到的一类错，见 TODO.md G11 §11。
# 2026-09-11 在 macOS（git 2.39.5、/bin/bash 3.2）实测，输出见 TODO.md G11 §5。

set -euo pipefail
unset CLAUDE_CODE_SESSION_ID   # agent 起的 shell 自带这个变量；demo 不依赖它，去掉免得混淆
tmp=${TMPDIR:-/tmp}; WORK=$(mktemp -d "${tmp%/}/attrib-demo.XXXXXX")
[ "${KEEP:-}" = 1 ] || trap 'rm -rf "$WORK"' EXIT
SHADOW=refs/worktree/vibetrail/shadow   # 影子历史：refs/worktree/ 是每个 worktree 各一份的命名空间，默认不推送
US=$'\037'                              # 字段分隔符：不用 tab，免得 read 把连续的 tab 并掉

newrepo() { # name → 在 $WORK/<name> 建一个空仓并进入
    mkdir -p "$WORK/$1"; cd "$WORK/$1"
    git init -q -b main .; git config user.name dev; git config user.email dev@example.com
}
open_file() { git rev-parse --git-path vibetrail-open; }   # 进行中的工具调用，每行「线程 线程:调用」；落在本 worktree 的私有 git 目录
mkc() { # tree parent label → 影子提交（作者名 = 这一步归给谁）
    GIT_AUTHOR_NAME="$3" GIT_AUTHOR_EMAIL=x GIT_COMMITTER_NAME=x GIT_COMMITTER_EMAIL=x \
        git commit-tree "$1" ${2:+-p "$2"} -m "$3"
}
in_progress() { # 此刻进行中的工具调用；一个都没有就是 gap（不是任何 agent 工具调用做的），多个就并列
    local o; o=$(open_file)
    if [ -s "$o" ]; then cut -d' ' -f2 "$o" | sort | paste -sd'|' -; else echo gap; fi
}

# 快照：复制一份真 index 当起点，add -A 后 write-tree。不碰真 index、不碰工作树。
# 从真 index 起步，已跟踪但匹配 .gitignore 的文件不会漏，stat 缓存也是热的；每次一份副本，并发不抢锁。
# cp 要带 -p：git 靠 index 文件自身的 mtime 判断哪些条目得重读内容（racy-git），副本的 mtime 变成「现在」
# 就会漏掉同一秒内被改成同样长度的文件。
snaptree() {
    local d t; d=$(mktemp -d)
    cp -p "$(git rev-parse --git-path index)" "$d/index" 2>/dev/null || true
    t=$(GIT_INDEX_FILE=$d/index git add -A && GIT_INDEX_FILE=$d/index git write-tree) || { rm -rf "$d"; return 1; }
    rm -rf "$d"; echo "$t"
}
# 拍快照；与影子历史末端不同就接一步，归给 label。真实实现里「拍快照 → 算标签 → 追加 → 改登记」要整段加锁，
# 或 update-ref 带旧值校验、失败就重拍重算；demo 是串行的，省了。
step() { # label
    local t tip; t=$(snaptree); tip=$(git rev-parse -q --verify "$SHADOW" || true)
    if [ -z "$tip" ]; then git update-ref "$SHADOW" "$(mkc "$t" "" 快照开始前已在工作树里)"
    elif [ "$(git rev-parse "$tip^{tree}")" != "$t" ]; then git update-ref "$SHADOW" "$(mkc "$t" "$tip" "$1")"; fi
}
# pre / post 按调用号配对，不看相邻顺序：post 只关自己这一次。配不上 pre 的 post（pre 那次快照丢了）
# 标「起点不明」，不能让这一步落成 gap。
snap() { # pre|post 线程 调用
    local o label; o=$(open_file); touch "$o"; label=$(in_progress)
    if [ "$1" = post ] && ! grep -qx "$2 $2:$3" "$o"; then
        label="$2:$3(起点不明)$([ "$label" = gap ] || echo "|$label")"
    fi
    step "$label"
    if [ "$1" = pre ]; then echo "$2 $2:$3" >> "$o"
    else grep -vx "$2 $2:$3" "$o" > "$o.new" || true; mv "$o.new" "$o"; fi
}
# 一个线程的一轮结束：先拍一次，把到此为止的改动记给还在进行中的调用（本线程没等到 post 的标未完成），
# 再把它们关掉。被打断的调用等不到 post，也等不到同线程的下一个 pre（子 agent、会话结束），只能靠这里关。
endturn() { # 线程
    local o; o=$(open_file); touch "$o"
    step "$(in_progress | tr '|' '\n' | sed "s/^\($1:.*\)$/\1(未完成)/" | paste -sd'|' -)"
    grep -v "^$1 " "$o" > "$o.new" || true; mv "$o.new" "$o"
}

blame1() { # rev file line [-M -C] → 「sha␟作者␟正文」
    git blame --line-porcelain ${4:-} -L "$3,$3" "$1" -- "$2" |
        awk 'NR == 1 { sha = $1 } /^author / { a = substr($0, 8) } /^\t/ { print sha "\037" a "\037" substr($0, 2) }'
}
# post-commit：影子历史末端临时接上真 commit 的 tree（最后一个快照到提交之间的差额，归给此刻进行中的调用），
# 只对本 commit 相对父提交新增或改动的行跑 blame。影子历史跨提交连续、不在每次提交时重开，所以上一次
# 提交没带走的改动仍归给当初写它的调用；部分暂存时被「改回去」的行不在本 commit 的 diff 里，不会被报。
attribute() { # commit
    local c=$1 p tip fin
    p=$(git rev-parse "$c^"); tip=$(git rev-parse "$SHADOW"); fin=
    if [ "$(git rev-parse "$c^{tree}")" != "$(git rev-parse "$tip^{tree}")" ]; then
        fin=$(mkc "$(git rev-parse "$c^{tree}")" "$tip" "$(in_progress)"); tip=$fin
    fi
    echo "== $(git log -1 --format=%s "$c") —— 本 commit 新增或改动的行 =="
    # 一次 diff 拿全部文件的新侧行号：-M 认改名（纯改名没有新侧行）；路径不转义、不经 shell 拆词
    git -c core.quotePath=false diff -M -U0 --no-color --no-ext-diff "$p" "$c" | awk '
        /^\+\+\+ / { f = substr($0, 5); sub(/\t$/, "", f); f = (f == "/dev/null") ? "" : substr(f, 3); next }
        /^@@ / && f != "" {
            match($0, /\+[0-9]+(,[0-9]+)?/); split(substr($0, RSTART + 1, RLENGTH - 1), a, ",")
            k = (a[2] == "") ? 1 : a[2]; for (i = 0; i < k; i++) print f "\037" a[1] + i }' |
    while IFS=$US read -r f ln; do
        local rev=$tip at=$ln sha placer origin text s n label
        IFS=$US read -r sha placer text < <(blame1 "$rev" "$f" "$at")
        # 落在提交时差额上的行，未必是最后一个快照之后才写的：先暂存、后又改时，提交进去的是暂存区里的
        # 旧版本，它在更早的快照里就有。沿影子历史往回找最近一个含这一行的版本，在那里 blame；
        # 找不到才真是最后一个快照之后写的，归给提交时进行中的调用
        if [ -n "$fin" ] && [ "$sha" = "$fin" ]; then
            for s in $(git rev-list "$fin^"); do
                n=$(git show "$s:$f" 2>/dev/null | grep -nxF -- "$text" | head -1 | cut -d: -f1 || true)
                if [ -n "$n" ]; then rev=$s; at=$n; IFS=$US read -r sha placer text < <(blame1 "$rev" "$f" "$at"); break; fi
            done
        fi
        # 放置者：这一行是谁放到这里的（不带 -M / -C）；内容来源：带 -M / -C 认出的移动或复制的出处。
        # 两者不同就都标上——复制别人的代码，放置者负责放在这里，内容却出自原作者
        IFS=$US read -r _ origin _ < <(blame1 "$rev" "$f" "$at" "-M -C")
        label=$placer; [ "$origin" = "$placer" ] || label="$placer(内容同 $origin)"
        printf '%-10s L%-3s %-8s %s\n' "$f" "$ln" "$label" "$text"
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

echo; echo "######## 边界 5：两个 worktree 各有各的影子历史，另一个 worktree 的快照不串进来"
newrepo wt1; printf 'a\n' > f.txt; printf 'x\n' > g.txt; git add -A; git commit -qm base
git worktree add -q -b side "$WORK/wt2"
snap pre A A1; sub 's/^a$/A-by-A1/' f.txt; snap post A A1
( cd "$WORK/wt2"; snap pre B B1; sub 's/^x$/X-by-B1/' g.txt; snap post B B1 )
git commit -qam "human commit in wt1"; attribute HEAD

echo; echo "######## 边界 6：先暂存、后又改，提交的是暂存区里的旧版本 → 仍归给写它的调用"
newrepo staged; printf 'v0\n' > f.txt; git add -A; git commit -qm base
snap pre A A1; sub 's/^v0$/v1/' f.txt; snap post A A1
snap pre A A2; git add f.txt; snap post A A2
snap pre B B1; sub 's/^v1$/v2/' f.txt; snap post B B1
git commit -qm "commit the staged v1"; attribute HEAD

echo; echo "######## 边界 7：调用被打断（有 pre 没 post），到这一轮结束时关掉并标未完成；之后的人手改归 gap"
newrepo interrupted; printf 'a\nb\n' > f.txt; git add -A; git commit -qm base
snap pre S S1; sub 's/^a$/A-by-S1/' f.txt     # 这次调用被打断，没有 post
endturn S                                    # ← 下一次 UserPromptSubmit（或 Stop / SubagentStop / SessionEnd）
sub 's/^b$/B-by-human/' f.txt
git commit -qam "human commit"; attribute HEAD

echo; echo "######## 边界 8：pre 那次快照丢了（hook 失败），只有 post → 标起点不明，不记成 gap"
newrepo nopre; printf 'a\n' > f.txt; git add -A; git commit -qm base
snap pre Z Z0; snap post Z Z0                # 之前一次正常的调用，影子历史从这里开始
sub 's/^a$/A-by-A1/' f.txt; snap post A A1
git commit -qam "human commit"; attribute HEAD

echo; echo "######## 边界 9：复制——这一行是谁放进来的（放置者）与内容最早出自谁（-M / -C）分开标"
newrepo copy; printf 'def f():\n    pass\n\ndef g():\n    pass\n' > m.py; git add -A; git commit -qm base
snap pre A A1; printf 'def f(items):\n    total = compute_total(items, discount_rate)\n\ndef g():\n    pass\n' > m.py; snap post A A1
snap pre B B1; printf 'def f(items):\n    total = compute_total(items, discount_rate)\n\ndef g(items):\n    total = compute_total(items, discount_rate)\n' > m.py; snap post B B1
git commit -qam "f and g"; attribute HEAD

echo; echo "######## 边界 10：改名（纯改名不算新增）+ 文件名带空格和中文"
newrepo rename; printf 'one\ntwo\nthree\n' > a.txt; git add -A; git commit -qm base
snap pre A A1; git mv a.txt "说明 b.txt"; printf 'four\n' >> "说明 b.txt"; snap post A A1
git add -A; git commit -qm "rename and append"; attribute HEAD

echo; echo "######## 边界 11：复制 index 要带 -p（racy-git）：add 之后同一秒改成同长度，隔一秒再拍"
newrepo racy; printf 'return a + b\n' > f; git add f; git commit -qm base
printf 'return a * b\n' > f; git add f; printf 'return a - b\n' > f; sleep 1
for opt in "" -p; do
    d=$(mktemp -d); cp $opt "$(git rev-parse --git-path index)" "$d/index"
    t=$(GIT_INDEX_FILE=$d/index git add -A && GIT_INDEX_FILE=$d/index git write-tree); rm -rf "$d"
    printf 'cp %-6s → 快照里是 %s（工作树里是 return a - b）\n' "${opt:-不带-p}" "$(git show "$t:f")"
done

[ "${KEEP:-}" = 1 ] && echo "临时目录保留在 $WORK"
exit 0
