#!/bin/bash
# 回归：提取规则对固定正负例的判定必须与 _expect 一致。
# _expect 是期望的**完整输出对象**（null = 不应命中）。比对整条输出而不只比 kind，
# 这样 human 标志翻转、字段名（t / at / turn / sid / branch）漂移都会被抓到——只比 kind 的
# 版本对这些变异全绿（实测）。
# 判据依赖英文消息串，Claude Code 改文案即失效——这个测试是唯一的哨兵。
#
# ⚠️ 必须同时检查 jq 是否报错：jq 在某条规则上抛错时，该记录之后的规则不再求值、之前的
#    命中照常输出，然后继续下一条；退出码只反映最后一条输入。末尾规则抛错时输出一条不差，
#    只比对输出恒绿——「去掉 toolUseResult 类型守卫」这个真 bug 就是这样漏过的（实测假绿）。
# 固定 C locale：macOS 自带的 bash 3.2 在 UTF-8 locale 下会把紧跟在变量名后的中文字符首字节算进变量名（变量名后紧跟「）」时，bash 找的是「V 加上「）」的首字节」这个变量），
# 开了 set -u 就报 unbound variable（用户 09-15 的终端踩到），没开就悄悄展开成空；tr / sort 的结果也随 locale 变。放在最前面，后面的解析都按 C
export LC_ALL=C
set -uo pipefail
cd "$(dirname "$0")"
fail=0; n=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    n=$((n+1))
    uuid=$(printf '%s' "$line" | jq -r '.uuid')
    want=$(printf '%s' "$line" | jq -S -c '._expect | select(. != null)')
    err=$(printf '%s' "$line" | jq -c -L . -f extract-diverge.jq 2>&1 >/dev/null)
    got=$(printf '%s' "$line" | jq -c -L . -f extract-diverge.jq 2>/dev/null | jq -S -c '.')
    if [ -n "$err" ]; then
        printf '  ✗ %-6s jq 报错（该记录抛错点之后的规则全部丢失）: %s\n' "$uuid" "${err:0:60}"
        fail=$((fail+1))
    elif [ "$got" != "$want" ]; then
        printf '  ✗ %-6s 期望[%s]\n           实得[%s]\n' "$uuid" "$want" "$got"
        fail=$((fail+1))
    fi
done < fixtures.jsonl
if [ $fail -eq 0 ]; then echo "  ✅ $n/$n 通过"; else echo "  ❌ $fail/$n 失败"; exit 1; fi
