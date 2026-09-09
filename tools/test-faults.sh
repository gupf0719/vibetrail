#!/bin/bash
# 故障注入套件：每条注入一个故障，断言「闸门/自检必须做出的反应」。
#
# 为什么需要它：15 条缺陷里有三条是同一形状——「通过」信号不是它所断言那件事的
# 函数（脚本跑到最后一行就打 ✓、哈希到文件路径就算锚非空、跟自己比就算一致）。
# 这类缺陷用「正常路径能跑通」测不出来，只能靠注入故障看它是否真的反应。
#
# 断言写的是**要求**不是现状，所以未修复时应当大面积红。
set -uo pipefail
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FIX=$SELF/fixtures
red=0; green=0
r(){ # r <id> <要求> <RED|GREEN>
    if [ "$3" = GREEN ]; then green=$((green+1)); printf "  \033[32m●\033[0m %-4s %-46s GREEN\n" "$1" "$2"
    else red=$((red+1)); printf "  \033[31m●\033[0m %-4s %-46s \033[31mRED\033[0m\n" "$1" "$2"; fi
}

mkfix(){ # 造一个装好工具、且 HEAD 是高风险 commit 的仓
    local d; d=$(mktemp -d)
    mkdir -p "$d/.claude/scripts" "$d/.claude/vibetrail" "$d/.claude/trace/audits" "$d/agent_v2"
    cp "$FIX"/*.sh "$d/.claude/scripts/"
    for f in vibetrail vibetrail-audit vibetrail-sync vibetrail-doctor prepare-commit-msg extract-diverge.jq; do
        [ -f "$SELF/$f" ] && cp "$SELF/$f" "$d/.claude/vibetrail/$f"
    done
    chmod +x "$d/.claude/scripts"/*.sh "$d/.claude/vibetrail"/* 2>/dev/null
    ( cd "$d" && git init -q -b main && git config user.email t@t && git config user.name t
      git add -A >/dev/null && git commit -q -m "装工具" )
    echo "$d"
}
risky(){ # 提交一个命中高风险模式的改动，让闸门有理由介入
    ( cd "$1" && echo "package x // sync" > agent_v2/basic_agent.go \
        && git add -A >/dev/null && git commit -q -m "高风险改动" )
}
gate(){ ( cd "$1" && echo '{}' | bash .claude/scripts/check-audit-stop.sh 2>&1 ); }
blocked(){ [ -n "$(gate "$1")" ]; }

echo "════ 闸门：任何「判不出来」都必须拦（fail-closed）════"
d=$(mkfix); risky "$d"; blocked "$d" && r T0 "基线：未审的高风险 commit 被拦" GREEN || r T0 "基线" RED; rm -rf "$d"

d=$(mkfix)
# 故障必须提交进去：留在工作区会让工作树变脏，闸门走「脏就跳过」那条既有早退，
# 测到的就不是极性而是那条早退（第一版栽在这上面）。
( cd "$d" && rm -rf .claude/vibetrail && git add -A >/dev/null && git commit -q -m "运行时缺失" ); risky "$d"
blocked "$d" && r T1 "vendored 运行时整个缺失 → 必须拦" GREEN || r T1 "vendored 运行时整个缺失 → 必须拦" RED; rm -rf "$d"

d=$(mkfix)
( cd "$d" && chmod -x .claude/vibetrail/vibetrail-audit && git add -A >/dev/null && git commit -q -m "丢 +x" ); risky "$d"
blocked "$d" && r T2 "运行时丢 +x → 必须拦" GREEN || r T2 "运行时丢 +x → 必须拦" RED; rm -rf "$d"

for tool in awk jq; do
    d=$(mkfix); risky "$d"; sb=$(mktemp -d)
    for c in git bash grep sed cat ls wc head tr cut date mktemp basename dirname awk jq; do
        [ "$c" = "$tool" ] && continue; ln -sf "$(command -v $c)" "$sb/" 2>/dev/null
    done
    o=$( cd "$d" && echo '{}' | PATH="$sb" bash .claude/scripts/check-audit-stop.sh 2>&1 )
    [ -n "$o" ] && r "T3-$tool" "缺 $tool → 必须拦" GREEN || r "T3-$tool" "缺 $tool → 必须拦" RED
    rm -rf "$d" "$sb"
done

d=$(mkfix); risky "$d"; ( cd "$d" && git status --porcelain | grep -q . )
[ $? -ne 0 ] && r T1b "T1/T2 的 fixture 必须是干净工作树" GREEN || r T1b "T1/T2 的 fixture 必须是干净工作树" RED; rm -rf "$d"

d=$(mkfix); risky "$d"
n=$( cd "$d" && git log -1 --name-only --pretty=format: | grep -cE '\.go$' )
[ "$n" -ge 1 ] && r T1c "fixture 的 HEAD 必须命中高风险模式" GREEN || r T1c "fixture 的 HEAD 必须命中高风险模式" RED; rm -rf "$d"

echo "════ 记录：空输入必须是错误，不能报成功 ════"
d=$(mkfix); risky "$d"
o=$( cd "$d" && bash .claude/scripts/mark-audit.sh audit </dev/null 2>&1 ); rc=$?
n=$(ls "$d/.claude/trace/audits/"*.jsonl 2>/dev/null | wc -l | tr -d ' ')
if [ $rc -ne 0 ] && ! echo "$o" | grep -q '✓'; then r T4 "空 stdin → 必须非零退出且不报 ✓" GREEN
else r T4 "空 stdin → 必须非零退出且不报 ✓" RED; fi
sz=0; [ "$n" -gt 0 ] && sz=$(wc -c < "$(ls "$d/.claude/trace/audits/"*.jsonl|head -1)" | tr -d ' ')
[ "$sz" = 0 ] && [ "$n" -gt 0 ] && r T5 "空输入不得落下 0 字节残骸" RED || r T5 "空输入不得落下 0 字节残骸" GREEN
rm -rf "$d"

echo "════ 锚：必须是冲突解决内容的函数 ════"
mkmerge(){ # 造一个有冲突解决的 merge，解决成 $2
    local d=$1 c=$2
    ( cd "$d" && git init -q -b main && git config user.email t@t && git config user.name t
      echo base > f.md && git add -A && git commit -q -m base
      git checkout -q -b s && echo side > f.md && git commit -q -am s
      git checkout -q main && echo mine > f.md && git commit -q -am m
      git merge s >/dev/null 2>&1; echo "$c" > f.md; git add -A && git commit -q --no-edit )
}
anchor(){ ( cd "$1" && git diff-tree -p --cc --root HEAD | git patch-id --stable | awk 'NR==1{print $1}' ); }
a=$(mktemp -d); b=$(mktemp -d); mkmerge "$a" "解决方案甲"; mkmerge "$b" "解决方案乙-完全不同"
[ "$(anchor "$a")" != "$(anchor "$b")" ] && r T6 "两个不同的冲突解决 → 锚必须不同" GREEN || r T6 "两个不同的冲突解决 → 锚必须不同" RED
c=$(mktemp -d); mkmerge "$c" "解决方案甲"
# T7 只有在 T6 绿之后才承重：现在所有冲突 merge 的锚都相同，它恒真。
[ "$(anchor "$a")" = "$(anchor "$c")" ] && r T7 "相同的冲突解决 → 锚必须相同" GREEN || r T7 "相同的冲突解决 → 锚必须相同" RED
rm -rf "$a" "$b" "$c"

echo "════ 自检：doctor 必须能发现自己被破坏 ════"
d=$(mkfix); risky "$d"; printf '\n# drift\n' >> "$d/.claude/vibetrail/vibetrail"
o=$( cd "$d" && bash .claude/vibetrail/vibetrail-doctor 1 2>&1 | grep "vendored 运行时" )
echo "$o" | grep -qE "⚠|✗" && r T8 "vendored 被改一个字节 → doctor 必须报警" GREEN || r T8 "vendored 被改一个字节 → doctor 必须报警" RED
rm -rf "$d"

d=$(mkfix); risky "$d"; rm -rf "$d/.claude/vibetrail"
o=$( cd "$d" && bash "$SELF/vibetrail-doctor" 1 2>&1 | grep "vendored 运行时" )
echo "$o" | grep -qE "⚠|✗" && r T9 "vendored 缺失 → doctor 必须报警" GREEN || r T9 "vendored 缺失 → doctor 必须报警" RED
rm -rf "$d"

d=$(mkfix); risky "$d"; chmod -x "$d/.claude/vibetrail/vibetrail-audit"
o=$( cd "$d" && bash .claude/vibetrail/vibetrail-doctor 1 2>&1 | grep "vendored 运行时" )
echo "$o" | grep -qE "⚠|✗" && r T10 "运行时丢 +x → doctor 必须报警" GREEN || r T10 "运行时丢 +x → doctor 必须报警" RED
rm -rf "$d"

echo "════ 合并：整份重生成的文件不得用 union ════"
d=$(mktemp -d); cd "$d" && git init -q -b main && git config user.email t@t && git config user.name t
mkdir -p .claude/trace/sessions
cp "$SELF/../.gitattributes" . 2>/dev/null || printf '.claude/trace/**/*.jsonl merge=union\n' > .gitattributes
S=.claude/trace/sessions/s.jsonl
printf '{"t":"session"}\n{"t":"diverge","at":"T1"}\n{"t":"end","at":"T1"}\n' > $S
git add -A && git commit -q -m base
git checkout -q -b br && printf '{"t":"session"}\n{"t":"diverge","at":"T1"}\n{"t":"diverge","at":"T2"}\n{"t":"end","at":"T2"}\n' > $S && git commit -q -am br
git checkout -q main && printf '{"t":"session"}\n{"t":"diverge","at":"T1"}\n{"t":"diverge","at":"T3"}\n{"t":"end","at":"T3"}\n' > $S && git commit -q -am m
git merge br >/dev/null 2>&1
ends=$(grep -c '"t":"end"' $S 2>/dev/null || echo 9)
[ "$ends" = 1 ] && r T11 "sessions 合并后只能有一条 end" GREEN || r T11 "sessions 合并后只能有一条 end（实得 $ends 条）" RED
cd /tmp && rm -rf "$d"

echo "════ 正向断言：通过不能靠沉默 ════"
d=$(mkfix); risky "$d"
( cd "$d" && printf '%s' '{"agents":[],"findings":[]}' | bash .claude/vibetrail/vibetrail-audit record HEAD audit >/dev/null 2>&1
  printf '%s' '{"agents":[],"findings":[]}' | bash .claude/vibetrail/vibetrail-audit record HEAD crossverify >/dev/null 2>&1 )
o=$(gate "$d")
echo "$o" | grep -qE "锚|anchor|patchId|记录" && r T12 "闸门放行时必须说出检查了什么" GREEN || r T12 "闸门放行时必须说出检查了什么" RED
rm -rf "$d"

echo
printf "  \033[32mGREEN %d\033[0m  /  \033[31mRED %d\033[0m   共 %d\n" $green $red $((green+red))
[ $red -eq 0 ]
