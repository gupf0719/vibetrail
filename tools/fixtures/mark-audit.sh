#!/bin/bash
# 标记 commit 已做 audit / cross-verify / comment-audit。
#
# 与旧版的区别：旧版 `touch` 一个 0 字节文件，只记「审过了」，不记「审了什么、
# 报了几个、几真几假」——于是命中率这类数字只能人肉从对话里数，而对话会被压缩掉。
# 现在写结构化记录，数字由 `mark-audit.sh stats` 算出来。
#
# 锚从 sha 换成 git patch-id：sha 在 rebase 后就变（本仓 294 个旧 marker 已有 4 个失效）。
# 判据只有一处，在 .claude/vibetrail/vibetrail-audit 里，本脚本只是薄封装。
#
# 用法:
#   mark-audit.sh audit [<sha>] < findings.json     # 带 finding（推荐）
#   mark-audit.sh audit --none [<sha>]              # 显式声明本次没找到 finding
#   mark-audit.sh crossverify [<sha>] < verdicts.json
#   mark-audit.sh commentaudit [<sha>] [--none]
#   mark-audit.sh all [<sha>]                       # 三者都标（各自 --none）
#   mark-audit.sh status [<sha>]                    # 查状态
#   mark-audit.sh stats                             # 命中率等，算出来的
#
# findings.json 形状见: .claude/vibetrail/vibetrail-audit（无参数运行看帮助）

set -e
cd "$(git rev-parse --show-toplevel)"
VA=.claude/vibetrail/vibetrail-audit
[ -x "$VA" ] || { echo "ERR: 缺 $VA —— 跑一次 vibetrail-install" >&2; exit 1; }

kind=${1:-}; shift || true
none=0
args=()
for a in "$@"; do
    case "$a" in --none) none=1;; *) args+=("$a");; esac
done
sha=${args[0]:-HEAD}

record(){ # record <kind>
    local k=$1
    # 不用 [ -t 0 ] 推断意图：agent 的 Bash 工具、Stop hook、CI 下 stdin 都不是 TTY，
    # 该判据恒假，于是「不带 --none 直接跑」会去读一个空 stdin，一路静默到写出 0 字节。
    # 意图必须显式声明：要么管进 findings，要么给 --none。
    if [ "$none" = "1" ]; then
        printf '{"agents":[],"findings":[],"empty":true}' | "$VA" record "$sha" "$k"
    else
        "$VA" record "$sha" "$k"          # findings 从 stdin 透传；空 stdin 由下游报错
    fi
}

case "$kind" in
    audit|crossverify|commentaudit) record "$kind" ;;
    all)
        none=1
        for k in audit crossverify commentaudit; do record "$k"; done ;;
    status)
        full=$(git rev-parse "$sha"); short=${full:0:7}
        echo "commit: $short"
        for k in audit crossverify commentaudit; do
            if "$VA" check "$full" "$k" 2>/dev/null; then printf '  %-13s ✓ done\n' "$k"
            else printf '  %-13s ✗ missing\n' "$k"; fi
        done ;;
    stats) "$VA" stats ;;
    *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
