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
# 主场景之外的 14 个边界场景，每个对应三轮独立审计（2026-09-11）抓到的一类错，见 TODO.md G11 §11。
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
# 下面两个文件落在 git rev-parse --git-path 解析出的本 worktree 私有目录里，每个 worktree 一份
open_file() { git rev-parse --git-path vibetrail-open; }   # 进行中的工具调用，每行「线程 线程:调用」
log_file()  { git rev-parse --git-path vibetrail-log; }    # 每次快照一行「影子历史末端 暂存区的tree 这一段的标签」
mkc() { # tree parent label → 影子提交（作者名 = 这一步归给谁）
    GIT_AUTHOR_NAME="$3" GIT_AUTHOR_EMAIL=x GIT_COMMITTER_NAME=x GIT_COMMITTER_EMAIL=x \
        git commit-tree "$1" ${2:+-p "$2"} -m "$3"
}
in_progress() { # 此刻进行中的工具调用；一个都没有就是 gap（不是任何 agent 工具调用做的），多个就并列
    local o; o=$(open_file)
    if [ -s "$o" ]; then cut -d' ' -f2 "$o" | sort | paste -sd'|' -; else echo gap; fi
}

# 快照 → 「工作树的 tree 暂存区的 tree」。复制一份真 index：先原样 write-tree 得到暂存区，
# 再 add -A、write-tree 得到工作树。不碰真 index、不碰工作树。
# 从真 index 起步，已跟踪但匹配 .gitignore 的文件不会漏，stat 缓存也是热的；每次一份副本，并发不抢锁。
# cp 要带 -p：git 靠 index 文件自身的 mtime 判断哪些条目得重读内容（racy-git），副本的 mtime 变成「现在」
# 就会漏掉同一秒内被改成同样长度的文件。
snaptree() {
    local d w i; d=$(mktemp -d)
    cp -p "$(git rev-parse --git-path index)" "$d/index" 2>/dev/null || true
    i=$(GIT_INDEX_FILE=$d/index git write-tree 2>/dev/null || echo -)      # 有冲突时写不出，记 -
    w=$(GIT_INDEX_FILE=$d/index git add -A && GIT_INDEX_FILE=$d/index git write-tree) || { rm -rf "$d"; return 1; }
    rm -rf "$d"; echo "$w $i"
}
# 拍快照；工作树与影子历史末端不同就接一步，归给 label；变没变都记一行日志。快照失败就跳过（fail-open）。
# 真实实现里「拍快照 → 算标签 → 追加 → 改登记」要整段加锁，或 update-ref 带旧值校验、失败就重拍重算；
# demo 是串行的，省了。
step() { # label
    local out w i tip; out=$(snaptree) || return 0; w=${out% *}; i=${out#* }
    tip=$(git rev-parse -q --verify "$SHADOW" || true)
    if [ -z "$tip" ]; then tip=$(mkc "$w" "" 快照开始前已在工作树里); git update-ref "$SHADOW" "$tip"
    elif [ "$(git rev-parse "$tip^{tree}")" != "$w" ]; then tip=$(mkc "$w" "$tip" "$1"); git update-ref "$SHADOW" "$tip"; fi
    printf '%s %s %s\n' "$tip" "$i" "$1" >> "$(log_file)"
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
line_out() { # rev file line → 一行归属。放置者：这一行是谁放到这里的（不带 -M / -C）；
             # 内容来源：带 -M / -C 认出的移动或复制的出处。不同就都标上
    local sha placer text origin label
    IFS=$US read -r sha placer text < <(blame1 "$1" "$2" "$3")
    IFS=$US read -r _ origin _ < <(blame1 "$1" "$2" "$3" "-M -C")
    label=$placer; [ "$origin" = "$placer" ] || label="$placer(内容同 $origin)"
    printf '%-10s L%-3s %-8s %s\n' "$2" "$3" "$label" "$text"
}
# 一个文件：先定出「提交进去的这一版是从哪个时刻的工作树暂存出来的」，在那里接上真 commit 的 tree 再 blame。
# 按 blob 找：日志里最后一段连续「暂存区里已经是这一版」的快照，它前面那个快照的工作树就是暂存时的出发点，
# 差出来的行归给那一段进行中的调用。暂存区在最后一个快照时还不是这一版（提交前一刻才 add 的，或 commit -a），
# 出发点就是最后一个快照，差出来的行归给此刻进行中的调用。不按行文本搜，同内容的行不会被认到别人头上。
attr_file() { # commit parent 状态 旧路径 新路径
    local c=$1 p=$2 st=$3 old=$4 f=$5 b oldspec base="" label="" prev="" tip idx lab s n
    b=$(git rev-parse "$c:$f")
    case $st in A*) oldspec=$(git hash-object -w -t blob /dev/null) ;; *) oldspec="$p:$old" ;; esac
    while read -r tip idx lab; do
        if [ "$idx" != - ] && [ "$(git rev-parse -q --verify "$idx:$f" 2>/dev/null || true)" = "$b" ]; then
            if [ -z "$base" ]; then
                if [ -n "$prev" ]; then base=$prev; label=$lab; else base=$tip; label=快照开始前已在暂存区里; fi
            fi
        else base=; fi
        prev=$tip
    done < "$(log_file)"
    if [ -z "$base" ]; then base=$(git rev-parse "$SHADOW"); label=$(in_progress); fi
    tip=$(mkc "$(git rev-parse "$c^{tree}")" "$base" "$label")
    # 行号用 blob 对 blob 的 diff 取：不解析带路径的 +++ 行，文件名里有什么字符都不影响
    git diff -U0 "$oldspec" "$c:$f" | sed -nE 's/^@@ -[0-9,]+ \+([0-9]+)(,([0-9]+))? @@.*/\1 \3/p' |
    while read -r s n; do
        n=${n:-1}
        while [ "$n" -gt 0 ]; do line_out "$tip" "$f" "$s"; s=$((s + 1)); n=$((n - 1)); done
    done
}
# post-commit：只报本 commit 相对父提交新增或改动的行。路径从 -z 的 name-status 取：NUL 分隔、从不加引号；
# 改名与复制带新旧两个路径，-M 认改名（纯改名没有新侧行）；删掉的文件没有新侧行。单个文件出错只跳过它。
attribute() { # commit
    local c=$1 p st old f
    p=$(git rev-parse "$c^")
    echo "== $(git log -1 --format=%s "$c") —— 本 commit 新增或改动的行 =="
    git rev-parse -q --verify "$SHADOW" > /dev/null || { echo "（这个 worktree 还没有快照）"; return 0; }
    git diff -M -z --name-status "$p" "$c" | while IFS= read -r -d '' st; do
        IFS= read -r -d '' f; old=$f
        case $st in R*|C*) IFS= read -r -d '' f ;; esac
        case $st in D*) continue ;; esac
        ( attr_file "$c" "$p" "$st" "$old" "$f" ) < /dev/null || printf '%s  （这个文件归属失败，跳过）\n' "$f"
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

echo; echo "######## 边界 3：同一线程两个调用重叠（pre A1、pre A2、post A1），按调用号配对，A1 结束不会把 A2 关掉"
newrepo samethread; printf 'a\nb\n' > f.txt; git add -A; git commit -qm base
snap pre A A1; snap pre A A2; snap post A A1; sub 's/^b$/B-by-A2/' f.txt; snap post A A2
git commit -qam "human commit"; attribute HEAD

echo; echo "######## 边界 4：已跟踪但匹配 .gitignore 的文件，只报改动的那一行"
newrepo ignored; printf '*.lock\n' > .gitignore; printf 'v1\nkeep\n' > deps.lock
git add .gitignore; git add -f deps.lock; git commit -qm base
snap pre A A1; sub 's/^v1$/v2/' deps.lock; snap post A A1
git commit -qam "bump"; attribute HEAD

echo; echo "######## 边界 5：并发快照（每次复制一份 index），30 轮 × 2 路"
newrepo concurrent; for i in $(seq 200); do echo "$i" > "f$i"; done; git add -A; git commit -qm base
for r in $(seq 30); do
    for k in 1 2; do ( echo "$r$k" > "f$k"; snaptree > /dev/null ) 2>> "$WORK/concurrent.err" & done
    wait
done
echo "快照失败 $(grep -c . "$WORK/concurrent.err" || true) 次（其中 index.lock 冲突 $(grep -c 'index.lock' "$WORK/concurrent.err" || true) 次）"

echo; echo "######## 边界 6：两个 worktree 交替拍快照，影子历史与登记表各管各的（共用 ref 会标成 X:X1，共用登记表会标成 B:B1）"
newrepo wt1; printf 'a\nb\n' > f.txt; printf 'x\n' > g.txt; git add -A; git commit -qm base
git worktree add -q -b side "$WORK/wt2"
snap pre Z Z0; snap post Z Z0                                   # wt1 先正常拍一次
( cd "$WORK/wt2"; snap pre B B1 )                                # wt2 的 B1 开始，还没结束
sub 's/^b$/B-by-human/' f.txt                                   # wt1 里人手改
snap pre X X1                                                   # wt1 的下一次调用开始
( cd "$WORK/wt2"; sub 's/^x$/X-by-B1/' g.txt; snap post B B1 )
snap post X X1
git commit -qam "human commit in wt1"; attribute HEAD

echo; echo "######## 边界 7：先暂存、后又改，提交的是暂存区里的旧版本 → 仍归给写它的调用"
newrepo staged; printf 'v0\n' > f.txt; git add -A; git commit -qm base
snap pre A A1; sub 's/^v0$/v1/' f.txt; snap post A A1
snap pre A A2; git add f.txt; snap post A A2
snap pre B B1; sub 's/^v1$/v2/' f.txt; snap post B B1
git commit -qm "commit the staged v1"; attribute HEAD

echo; echo "######## 边界 8：人改、暂存、再改，都不经过 hook，然后 agent 在工具调用里提交暂存区 → gap，不记给提交者"
newrepo stagedhuman; printf 'v0\n' > f.txt; git add -A; git commit -qm base
snap pre Z Z0; snap post Z Z0
sub 's/^v0$/v1-by-human/' f.txt; git add f.txt; sub 's/^v1-by-human$/v2-by-human/' f.txt
snap pre C C2; git commit -qm "agent commits the index"; attribute HEAD; snap post C C2

echo; echo "######## 边界 9：人在最后一个快照之后补的行，与 A1 写过的行同内容 → 仍是 gap，不认到 A1 头上"
newrepo late; printf 'def f():\n    pass\n' > m.py; git add -A; git commit -qm base
snap pre A A1; printf 'def f():\n    pass\n\ndef g():\n    return None\n' > m.py; snap post A A1
printf '\ndef h():\n    return None\n' >> m.py
git commit -qam "human adds h"; attribute HEAD

echo; echo "######## 边界 10：调用被打断（有 pre 没 post），到这一轮结束时关掉并标未完成；之后的人手改归 gap"
newrepo interrupted; printf 'a\nb\n' > f.txt; git add -A; git commit -qm base
snap pre S S1; sub 's/^a$/A-by-S1/' f.txt     # 这次调用被打断，没有 post
endturn S                                    # ← 下一次 UserPromptSubmit（或 Stop / SubagentStop / SessionEnd）
sub 's/^b$/B-by-human/' f.txt
git commit -qam "human commit"; attribute HEAD

echo; echo "######## 边界 11：pre 那次快照丢了（hook 失败），只有 post → 标起点不明，不记成 gap"
newrepo nopre; printf 'a\n' > f.txt; git add -A; git commit -qm base
snap pre Z Z0; snap post Z Z0                # 之前一次正常的调用，影子历史从这里开始
sub 's/^a$/A-by-A1/' f.txt; snap post A A1
git commit -qam "human commit"; attribute HEAD

echo; echo "######## 边界 12：复制——这一行是谁放进来的（放置者）与内容最早出自谁（-M / -C）分开标"
newrepo copy; printf 'def f():\n    pass\n\ndef g():\n    pass\n' > m.py; git add -A; git commit -qm base
snap pre A A1; printf 'def f(items):\n    total = compute_total(items, discount_rate)\n\ndef g():\n    pass\n' > m.py; snap post A A1
snap pre B B1; printf 'def f(items):\n    total = compute_total(items, discount_rate)\n\ndef g(items):\n    total = compute_total(items, discount_rate)\n' > m.py; snap post B B1
git commit -qam "f and g"; attribute HEAD

echo; echo "######## 边界 13：改名（纯改名不算新增）+ 文件名带空格、中文、双引号、tab，一个出问题也不拖垮别的"
newrepo rename; printf 'one\ntwo\nthree\n' > a.txt; printf 'ok\n' > ok.txt; git add -A; git commit -qm base
snap pre A A1
git mv a.txt "说明 b.txt"; printf 'four\n' >> "说明 b.txt"
printf 'q\n' > 'say"hi".txt'; printf 't\n' > "$(printf 'tab\there.txt')"; printf 'ok2\n' >> ok.txt
snap post A A1
git add -A; git commit -qm "rename and odd names"; attribute HEAD

echo; echo "######## 边界 14：racy-git——add 之后同一秒改成同长度，隔一秒再拍；snaptree 要拍到工作树里的版本"
newrepo racy; printf 'return a + b\n' > f; git add f; git commit -qm base
printf 'return a * b\n' > f; git add f; printf 'return a - b\n' > f; sleep 1
w=$(snaptree); echo "snaptree 拍到：$(git show "${w% *}:f")（工作树里是 return a - b）"
d=$(mktemp -d); cp "$(git rev-parse --git-path index)" "$d/index"   # 对照：复制时不带 -p
t=$(GIT_INDEX_FILE=$d/index git add -A && GIT_INDEX_FILE=$d/index git write-tree); rm -rf "$d"
echo "对照：cp 不带 -p 拍到：$(git show "$t:f")"

[ "${KEEP:-}" = 1 ] && echo "临时目录保留在 $WORK"
exit 0
