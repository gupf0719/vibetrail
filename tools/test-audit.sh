#!/bin/bash
# vibetrail-audit 回归。重点钉两件事：锚取自 Vibetrail-Id trailer 且与 spec §4 一致；
# 没有锚的 commit 拒写记录（fail-closed）。
set -uo pipefail
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else printf '  ✗ %-30s 期望[%s] 实得[%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

cd "$T"; git init -q -b main; git config user.name t; git config user.email t@t
# 锚来自 prepare-commit-msg 写的 trailer，fixture 必须装 hook，否则 commit 没有锚、
# record 会按 fail-closed 拒绝 —— 那测的是「没装 hook」不是「记录写得对不对」。
mkdir -p "$(git rev-parse --git-path hooks)"
cp "$SELF/prepare-commit-msg" "$(git rev-parse --git-path hooks)/prepare-commit-msg"
chmod +x "$(git rev-parse --git-path hooks)/prepare-commit-msg"
echo a > f; git add f; git commit -q -m base
echo b >> f; git add f; git commit -q -m normal

F='{"agents":[{"type":"x","perspective":"p","findings":2}],"findings":[
 {"id":"A","severity":"HIGH","claim":"c1","verdict":"confirmed"},
 {"id":"B","severity":"LOW","claim":"c2","verdict":"false-positive"}]}'

printf '%s' "$F" | "$SELF/vibetrail-audit" record HEAD audit >/dev/null 2>&1
ck "普通 commit 写出记录" "1" "$(ls .claude/trace/audits/*.jsonl 2>/dev/null | wc -l | tr -d ' ')"
ck "记录带 t=audit" "audit" "$(cat .claude/trace/audits/*.jsonl | jq -r .t)"
ck "finding 数正确" "2" "$(cat .claude/trace/audits/*.jsonl | jq '.findings|length')"
ck "命中率算得对" "50%" "$("$SELF/vibetrail-audit" stats | jq -r '.["命中率"]')"

# 锚必须与 spec §4 的命令逐字一致
# 只从 §4 那一节取读取命令：spec 里含 Vibetrail-Id 的地方不止一处（§2.0 内嵌了
# 写入侧的 hook 源码），按全文 grep -m1 会抓到写入语句而不是读取命令。
SPEC=$(sed -n '/^## 4\. 审计记录/,/^### 4\.0/p' "$SELF/../spec/trace-v1.md" | grep -m1 'git log -1')
EXPECT=$(eval "${SPEC//<sha>/HEAD}")
ck "锚与 spec §4 一致" "$EXPECT" "$(basename "$(ls .claude/trace/audits/*.jsonl)" .jsonl)"

# 有冲突解决的 merge：锚必须非空 —— 这是唯一能验出 --cc 的场景。
# 普通 commit 上 --cc 与不加**结果逐字相同**，所以只用普通 commit 的断言是假绿
# （实测：去掉 --cc 后原测试照样通过）。
git checkout -q -b conf; printf 'C\n' > f; git add f; git commit -q -m c
git checkout -q main; printf 'M\n' > f; git add f; git commit -q -m m
git merge conf >/dev/null 2>&1; printf 'R\n' > f; git add f; git commit -q --no-edit
CONF_ANCHOR=$(git diff-tree -p --cc --root HEAD | git patch-id --stable | awk 'NR==1{print $1}')
ck "有冲突 merge 锚非空" "yes" "$([ -n "$CONF_ANCHOR" ] && echo yes || echo no)"
before2=$(ls .claude/trace/audits/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$F" | "$SELF/vibetrail-audit" record HEAD audit >/dev/null 2>&1
ck "有冲突 merge 写出记录" "$((before2+1))" "$(ls .claude/trace/audits/*.jsonl 2>/dev/null | wc -l | tr -d ' ')"

# 无冲突 merge：锚为空，不该写记录
git checkout -q -b side; echo s > s; git add s; git commit -q -m side
git checkout -q main; echo m > m; git add m; git commit -q -m m
git merge -q --no-edit --no-ff side >/dev/null 2>&1
# merge 现在**有**锚（hook 对 merge 同样写 trailer），与上一版 patch-id 机制相反：
# 那时多父 commit 的 patch-id 为空串、record 跳过。spec §7 已同步改过。
before=$(ls .claude/trace/audits/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$F" | "$SELF/vibetrail-audit" record HEAD audit >/dev/null 2>&1
ck "merge 有锚，写出记录" "$((before+1))" "$(ls .claude/trace/audits/*.jsonl 2>/dev/null | wc -l | tr -d ' ')"

# 没有锚的 commit 必须拒写（fail-closed）——把 hook 摘掉再提交
rm -f "$(git rev-parse --git-path hooks)/prepare-commit-msg"
echo noanchor > na; git add na; git commit -q -m "无锚 commit"
before=$(ls .claude/trace/audits/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$F" | "$SELF/vibetrail-audit" record HEAD audit >/dev/null 2>&1
ck "没有锚 → 拒写记录" "$before" "$(ls .claude/trace/audits/*.jsonl 2>/dev/null | wc -l | tr -d ' ')"

echo
if [ $fail -eq 0 ]; then echo "  ✅ $pass/$((pass+fail)) 通过"; else echo "  ❌ $fail/$((pass+fail)) 失败"; exit 1; fi
