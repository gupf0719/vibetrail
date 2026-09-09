#!/bin/bash
# Stop hook: 检查最近 commit 改动的 .go 注释 + .md 活文档是否有失效符号/路径/链接(drift)。
#
# comment-audit skill 第 1 层机械对账的强制执行——高风险注释 drift 未处理时 block。
# 配 marker 出口:第 1 层 ERROR 是"候选"(可能历史/对照语境假阳),用户审查后
# (真 drift 改了 / 假阳确认了) 跑 mark-audit.sh commentaudit 跳过。
#
# 跳过条件:
#   - 工作树脏(没 commit 完)
#   - 最近 commit 没改 .go 文件(排除工具自身)
#   - go build 工具失败(工具自身问题不阻塞业务)
#   - commentaudit 返 0(无 ERROR)或 2(扫描异常)
#
# 范围: -files 查本次 commit 改动的 .go + .md(增量),符号表仍按 -root . 全仓建。
# **.md 排除历史归档** doc/issue|review|code(在"已删/整文件移除"语境引用早删文件是
# 正确记录,非 drift)。只看 ERROR(.go 符号/路径 + .md file:line/链接);数字冲突 WARN 不进 gate。
#
# 使用: 配在 .claude/settings.json hooks.Stop[].command(与 check-audit-stop.sh 并列)

set -e
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0

# 工作树脏 → 没 commit 完,跳过
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    exit 0
fi

last_sha=$(git log -1 --pretty=%H 2>/dev/null) || exit 0

# 最近 commit 改动且仍存在的 .go 注释 + .md 活文档(排除工具自身 + .md 历史归档)
changed=$(git log -1 --name-only --pretty=format: "$last_sha" \
    | grep -E '\.(go|md)$' \
    | grep -v "scripts/commentaudit" \
    | grep -vE '^doc/(issue|review|code)/.*\.md$' || true)
[ -z "$changed" ] && exit 0

files=""
for f in $changed; do
    [ -f "$f" ] && files="${files:+$files,}$f"
done
[ -z "$files" ] && exit 0

# 构建工具(失败不阻塞业务——工具自身问题不该 block commit 收尾)
bin=$(mktemp 2>/dev/null) || exit 0
if ! go build -o "$bin" .claude/scripts/commentaudit/main.go 2>/dev/null; then
    rm -f "$bin"
    exit 0
fi

# 增量校验改动文件(只 ERROR,符号表全仓建)
set +e
out=$("$bin" -root . -files "$files" -warn=false 2>/dev/null)
code=$?
set -e
rm -f "$bin"

# 只有 ERROR(exit 1) 才考虑 block;0=干净 / 2=扫描异常 都放行
[ "$code" -ne 1 ] && exit 0

VA=.claude/vibetrail/vibetrail-audit
# 判不出来时必须显式发 block JSON。
# 不能靠非零退出：Claude Code 只在 exit 2 时阻断，exit 1 等是「非阻断错误」——
# 脚本崩溃会 fail open，正是要消灭的那个方向。
cannot_determine(){
    printf '{"decision":"block","reason":"留痕闸门无法判定本次是否已审：%s。这是 fail-closed —— 判不出来一律拦。修好后重试。"}\n' "$1"
    exit 0
}
[ -x "$VA" ] || cannot_determine "运行时 $VA 缺失或不可执行"                       # 缺运行时放行，由 doctor 报
"$VA" check "$last_sha" commentaudit 2>/dev/null && exit 0

n=$(echo "$out" | grep -oE 'ERROR=[0-9]+' | head -1 | grep -oE '[0-9]+')
n=${n:-若干}
cat <<EOF
{"decision":"block","reason":"最近 commit ${last_sha:0:7} 改动的 .go 注释 / .md 活文档有 ${n} 个 drift 候选 (第1层 ERROR)。请:\n1. 跑 go build -o /tmp/ca .claude/scripts/commentaudit/main.go && /tmp/ca -files ${files} -warn=false 看详情\n2. 逐个读语境判真假 (历史/对照/eino 外部语境=假阳, 不存在符号 / 失效 file:line / 失效链接=真 drift)\n3. 真 drift 改注释或文档引用; 全部处理或确认后跑: bash .claude/scripts/mark-audit.sh commentaudit\n后 Stop。详见 comment-audit skill。"}
EOF
exit 0
