#!/bin/bash
# 回归：提取规则对固定正负例的判定必须与 _expect 一致。
# 判据依赖英文消息串，Claude Code 改文案即失效——这个测试是唯一的哨兵。
#
# ⚠️ 必须同时检查 jq 是否报错：jq 抛错时输出为空，与「正确地判为无命中」不可区分。
#    只比对输出的版本对「去掉 toolUseResult 类型守卫」这个真 bug 是恒真的（实测假绿）。
set -uo pipefail
cd "$(dirname "$0")"
fail=0; n=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    n=$((n+1))
    want=$(printf '%s' "$line" | jq -r '._expect')
    uuid=$(printf '%s' "$line" | jq -r '.uuid')
    err=$(printf '%s' "$line" | jq -c -f extract-diverge.jq 2>&1 >/dev/null)
    got=$(printf '%s' "$line" | jq -c -f extract-diverge.jq 2>/dev/null | jq -r '.kind' | paste -sd, -)
    if [ -n "$err" ]; then
        printf '  ✗ %-6s jq 报错（记录被整条丢弃）: %s\n' "$uuid" "${err:0:60}"
        fail=$((fail+1))
    elif [ "$got" != "$want" ]; then
        printf '  ✗ %-6s 期望[%s] 实得[%s]\n' "$uuid" "$want" "$got"
        fail=$((fail+1))
    fi
done < fixtures.jsonl
if [ $fail -eq 0 ]; then echo "  ✅ $n/$n 通过"; else echo "  ❌ $fail/$n 失败"; exit 1; fi
