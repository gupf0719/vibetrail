#!/bin/bash
# Stop hook: 检查最近 commit 是否需要 audit + cross-verify，缺则 block Claude 收尾。
#
# 强制规则（与 user memory feedback_audit_trigger_rule 对应）：
#   高风险 commit (改 sess / cp / channel / sync / agent_v2/_agent.go) 必须:
#     1. 做 audit (mark-audit.sh audit，写结构化记录而非 0 字节 marker)
#     2. 做 cross-verify (mark-audit.sh crossverify)
#   未做 → 输出 JSON decision=block 让 Claude 不能 stop
#
# 跳过条件:
#   - 工作树有未 commit 改动 → 不算"已 commit"，跳过检查
#   - 最近 commit 不涉及高风险文件 → 不需要 audit
#   - 最近 commit 只改文档/非代码 (无 .go 文件) → 不需要代码 audit
#     (高风险判定只对 .go 代码文件 — 否则 channel-engine.md / interrupt-resume.md
#      这类文档名含 channel/interrupt 会误报 block)
#
# 使用: 配在 .claude/settings.json hooks.Stop[].command

set -e
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0

# 工作树脏 → 还没 commit 完，跳过
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    exit 0
fi

# 最近 commit hash
last_sha=$(git log -1 --pretty=%H 2>/dev/null) || exit 0

# 检查是否高风险 commit (改了 session / cp / sync / 编排等 .go 代码文件)
# 先 grep '\.go$' 只留代码文件 — 文档 (.md) 即使文件名含 channel/interrupt 也不触发
risky_files=$(git log -1 --name-only --pretty=format: "$last_sha" | grep -E '\.go$' | grep -E "session\.go|checkpointer|graph_loop|_agent\.go|sync|channel|interrupt" || true)

if [ -z "$risky_files" ]; then
    # 不是高风险 commit, 通过
    exit 0
fi

# 判据只有一处，在 vibetrail-audit 里：锚是 git patch-id（跨 rebase 稳定），
# 不是 sha（本仓 294 个旧 marker 已有 4 个因 rebase 失效）。
# 缺 vendored 运行时时**放行**——闸门 fail open 好过因工具缺失卡死所有人；
# 该情形由 vibetrail-doctor 报出来。
VA=.claude/vibetrail/vibetrail-audit
# 判不出来时必须显式发 block JSON。
# 不能靠非零退出：Claude Code 只在 exit 2 时阻断，exit 1 等是「非阻断错误」——
# 脚本崩溃会 fail open，正是要消灭的那个方向。
cannot_determine(){
    printf '{"decision":"block","reason":"留痕闸门无法判定本次是否已审：%s。这是 fail-closed —— 判不出来一律拦。修好后重试。"}\n' "$1"
    exit 0
}
[ -x "$VA" ] || cannot_determine "运行时 $VA 缺失或不可执行"

# 检查 audit marker
if ! "$VA" check "$last_sha" audit 2>/dev/null; then
    cat <<EOF
{"decision":"block","reason":"高风险 commit ${last_sha:0:7} 涉及 $(echo "$risky_files" | head -3 | tr '\n' ',' | sed 's/,$//') 等需要 audit。请：\n1. spawn 多 agent 单视角并发审 (sess / 并发 / cp 等视角)\n2. grep 验证 finding (audit 命中率 33-67%)\n3. 通过后跑: bash .claude/scripts/mark-audit.sh audit\n后 Stop。"}
EOF
    exit 0
fi

# 检查 cross-verify marker (CLAUDE.md 规则: audit 报告必交叉验证)
if ! "$VA" check "$last_sha" crossverify 2>/dev/null; then
    cat <<EOF
{"decision":"block","reason":"高风险 commit ${last_sha:0:7} 已做 audit 但未交叉验证 (CLAUDE.md '审计纪律' 步骤 6)。请：\n1. spawn 第二个独立 agent 验证 audit 报告每个 finding 真假\n2. 通过后跑: bash .claude/scripts/mark-audit.sh crossverify\n后 Stop。"}
EOF
    exit 0
fi

# 全通过, allow stop
exit 0
