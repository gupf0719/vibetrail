#!/bin/bash
# 演示与测试用（上线用不到，用户 09-15）：把本机 spool 里采到的事件整理成一份 markdown 报告，三类分开——
# 每一轮的元数据、人机分歧、commit ↔ 会话。不装进 ~/.vibetrail/bin，只在仓里跑。
#
#   bash experiments/collect-demo/report.sh [-o 输出文件] [--session 会话 id 前缀]
#
# 输出默认写到 <数据根>/report.md 并打印路径；-o - 打到终端。数据根照 VIBETRAIL_HOME（默认 ~/.vibetrail）。
# 提交说明是生成时从本机 git 现查的，只写进这份报告，不在事件里、不上报。
# 固定 C locale：macOS 自带的 bash 3.2 在 UTF-8 locale 下会把紧跟在变量名后的中文字符首字节算进变量名（见 tools/vibetrail 开头的说明）
export LC_ALL=C
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
VT_HOME=${VIBETRAIL_HOME:-$HOME/.vibetrail}
out="$VT_HOME/report.md"; sess=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--out) out=${2:-}; shift 2;;
        --session) sess=${2:-}; shift 2;;
        -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
        *) echo "✗ 不认识的参数：$1" >&2; exit 1;;
    esac
done
JQ=$(sed -n 's/^jq=//p' "$VT_HOME/config" 2>/dev/null | tail -1); [ -n "$JQ" ] && [ -x "$JQ" ] || JQ=$(command -v jq) || { echo "✗ 没找到 jq" >&2; exit 1; }
files=$(find "$VT_HOME/spool" -path "$VT_HOME/spool/.rejected" -prune -o -type f -name '*.jsonl' ! -name '.*' -print 2>/dev/null | sort)
[ -n "$files" ] || { echo "（spool 为空：$VT_HOME/spool）"; exit 0; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/vibetrail-report.XXXXXX") || exit 1; trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 cat | "$JQ" -c --arg s "$sess" 'select($s == "" or (.session_id | startswith($s)))' > "$tmp/ev"
# 提交说明：按事件里的工作区（主 checkout）去本机 git 查，查不到就算了
"$JQ" -r 'select(.type == "turn.end") | .workspace_id as $w | .commits[]? | [$w, .sha] | @tsv' "$tmp/ev" | sort -u \
  | while IFS="$(printf '\t')" read -r w sha; do
        s=$(git -C "$w" log -1 --format=%s "$sha" 2>/dev/null) && "$JQ" -n -c --arg k "$sha" --arg v "$s" '{($k): $v}'
    done | "$JQ" -s -c 'add // {}' > "$tmp/subjects"
"$JQ" -s -r --argjson subjects "$(cat "$tmp/subjects")" --arg generated "$(date '+%Y-%m-%d %H:%M')" --arg source "$VT_HOME/spool" \
    --argjson chunks "$(printf '%s\n' "$files" | wc -l | tr -d ' ')" -f "$HERE/report.jq" "$tmp/ev" > "$tmp/report.md" \
    || { echo "✗ 生成报告失败" >&2; exit 1; }
if [ "$out" = "-" ]; then cat "$tmp/report.md"; else mkdir -p "$(dirname "$out")" && cp "$tmp/report.md" "$out" && echo "✓ 报告 → $out"; fi
