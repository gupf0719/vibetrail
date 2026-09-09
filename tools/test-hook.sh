#!/bin/bash
# prepare-commit-msg 的回归。三条高危曾全部出在这段 hook 上，且**失效全是静默的**
# ——不报错，只是归属错了或 trailer 区被破坏。所以每个场景都断言具体取值。
set -uo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SELF_DIR/prepare-commit-msg"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0

ck(){ # ck <名称> <期望> <实得>
    if [ "$2" = "$3" ]; then pass=$((pass+1))
    else printf '  ✗ %-34s 期望[%s] 实得[%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
newrepo(){ # newrepo <目录名> → 建仓并装 hook
    local d="$T/$1"; mkdir -p "$d"; cd "$d"
    git init -q -b main; git config user.name t; git config user.email t@t
    mkdir -p .git/hooks; cp "$HOOK" .git/hooks/prepare-commit-msg
    chmod +x .git/hooks/prepare-commit-msg
    echo base > f; git add f; env -u CLAUDE_CODE_SESSION_ID git commit -q -m base
}
sess(){ git log -1 --format='%(trailers:key=Claude-Session,valueonly,separator=)' "$@"; }

# 1 agent 提交注入
newrepo t1; echo a >> f; git add f
CLAUDE_CODE_SESSION_ID=S1 git commit -q -m "agent 提交"
ck "agent 提交注入" "S1" "$(sess)"

# 2 人工提交不注入
echo b >> f; git add f; env -u CLAUDE_CODE_SESSION_ID git commit -q -m "人工提交"
ck "人工提交不注入" "" "$(sess)"

# 3 amend 幂等
CLAUDE_CODE_SESSION_ID=S1 git commit -q --amend --no-edit
ck "amend 幂等" "1" "$(git log -1 --format='%B' | grep -c '^Claude-Session:')"

# 4 Co-Authored-By 不被挤出 trailer 区
newrepo t4; echo a >> f; git add f
CLAUDE_CODE_SESSION_ID=S4 git commit -q -F - <<'M'
feat: 带协作者

正文。

Co-Authored-By: someone <s@x.com>
M
ck "Co-Authored-By 保留" "someone <s@x.com>" "$(git log -1 --format='%(trailers:key=Co-Authored-By,valueonly,separator=)')"
ck "同时也有 Claude-Session" "S4" "$(sess)"

# 5 cherry-pick 重放：不改归属
newrepo t5; git checkout -q -b src; echo h > h; git add h
env -u CLAUDE_CODE_SESSION_ID git commit -q -m "别人写的"
S=$(git rev-parse HEAD); git checkout -q main
CLAUDE_CODE_SESSION_ID=S5 git cherry-pick "$S" >/dev/null 2>&1
ck "cherry-pick 不改归属" "" "$(sess)"

# 6 冲突 rebase --continue：不改归属
newrepo t6; git checkout -q -b feat; printf 'F\n' > f; git add f
env -u CLAUDE_CODE_SESSION_ID git commit -q -m "别人写的"
git checkout -q main; printf 'M\n' > f; git add f
env -u CLAUDE_CODE_SESSION_ID git commit -q -m "main 改同一行"
git checkout -q feat
CLAUDE_CODE_SESSION_ID=S6 git rebase main >/dev/null 2>&1
printf 'R\n' > f; git add f
CLAUDE_CODE_SESSION_ID=S6 git -c core.editor=true rebase --continue >/dev/null 2>&1
ck "冲突 rebase 不改归属" "" "$(sess)"

# 7 merge --no-edit：trailer 不粘进 subject
newrepo t7; git checkout -q -b side; echo s > s; git add s
env -u CLAUDE_CODE_SESSION_ID git commit -q -m side
git checkout -q main; echo m > m; git add m
env -u CLAUDE_CODE_SESSION_ID git commit -q -m main
CLAUDE_CODE_SESSION_ID=S7 git merge --no-edit side >/dev/null 2>&1
ck "merge subject 不被污染" "Merge branch 'side'" "$(git log -1 --format='%s')"
ck "merge 仍有归属" "S7" "$(sess)"

# 8 空消息：git 照常拒绝
newrepo t8; echo x >> f; git add f
if CLAUDE_CODE_SESSION_ID=S8 git commit -q -m '' 2>/dev/null; then r=accepted; else r=rejected; fi
ck "空消息仍被拒绝" "rejected" "$r"

# 9 worktree 沿用共享 hook
newrepo t9; git config core.hooksPath "$T/t9/.git/hooks"
git worktree add -q wt -b wtb 2>/dev/null
printf '[core]\n\thooksPath = %s/t9/.git/hooks\n' "$T" > .git/worktrees/wt/config.worktree
cd "$T/t9/wt"; echo w > w; git add w
CLAUDE_CODE_SESSION_ID=S9 git commit -q -m "worktree 提交"
ck "worktree 生效" "S9" "$(sess)"

# 10 spec 代码块与文件逐字一致
cd "$SELF_DIR/.."
EX=$(python3 - <<'PY'
import pathlib, re
m = re.search(r'### 2\.0 谁写、什么时候写\n\n`\.githooks/prepare-commit-msg`.*?\n\n```bash\n(.*?)\n```\n',
              pathlib.Path("spec/trace-v1.md").read_text(), re.S)
print(m.group(1) if m else "<未定位>")
PY
)
ck "spec 代码块与文件一致" "$(cat "$HOOK")" "$EX"

echo
if [ $fail -eq 0 ]; then echo "  ✅ $pass/$((pass+fail)) 通过"; else echo "  ❌ $fail/$((pass+fail)) 失败"; exit 1; fi
