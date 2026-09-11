#!/bin/bash
# 量「多个会话改、一个会话提交」在真实历史里发生得多不多——G11 值不值得做，先看这个数（TODO.md G11 §9）。
#
# ⚠️ 第六轮审计（2026-09-11）：这一版两个方向都偏，出的数不能拿来做决定，重写之前只当草稿（TODO.md G11 §9、§11）。
#   多算：只比路径后缀，别的 worktree / 别的 clone 里的同名文件都算进来；失败的 Edit 照算。
#   少算：Bash 改的看不到；只找现存 worktree 对应的项目目录，已删 worktree 目录下的、从别的仓启动的会话都漏；
#         时间窗从父提交算起，漏掉「A 改了没提交、B 后来一起提交」——正是 G11 要抓的场景。
#
# 做法：对最近 N 个 commit，取父提交到本提交的时间窗，在本仓全部 worktree 的 Claude Code transcript 里找这段时间内
# 对本 commit 改过的文件做过 Edit / Write / MultiEdit / NotebookEdit 的会话（spec §4.5 的第一档内容匹配），
# 与 commit 的 Claude-Session trailer 比：候选里有 trailer 之外的会话 → 多会话 commit。
#
# 口径：
#   - 只认 Edit / Write 这类工具的 file_path，Bash 里 sed / heredoc 改的看不到 → 这一头会少算（另一头见上）；
#   - transcript 不在本机（另一台机器提交的）→ 「无匹配」，不代表单会话；
#   - 子 agent 的 transcript（<sid>/subagents/*.jsonl）并进父会话；
#   - 多会话 = trailer 之外还有会话改过，或改过的会话不止一个；没有 trailer 又只有一个候选时比不了，单列；
#   - 时间窗前后各放宽 60s / 5s，容忍时钟与提交延迟。
# 用法：bash experiments/multi-session-commits.sh [N=40] [rev=HEAD]   在被观测仓的任一 worktree 里跑
# 2026-09-11 在 MacBook 上跑出「7 个可查、2 个确定多会话」，第六轮在 C02FM 上复现不出（多会话 0、单会话 1、无匹配 39）：
# 其中 d298f87 是跨 clone 的误报，514876d 没有 trailer、时间窗 6 小时，谈不上确定（TODO.md G11 §11 第六轮错 2）。
set -uo pipefail
N=${1:-40}; REV=${2:-HEAD}
PROJ="$HOME/.claude/projects"
command -v jq >/dev/null || { echo "✗ 需要 jq" >&2; exit 1; }
command -v python3 >/dev/null || { echo "✗ 需要 python3" >&2; exit 1; }
cd "$(git rev-parse --show-toplevel)" || exit 1

# 本仓全部 worktree → Claude 项目目录名（路径里的 / 与 . 都换成 -）；路径两侧都过 realpath（见 vibetrail-sync）
rp(){ cd "$1" 2>/dev/null && pwd -P || echo "$1"; }
DIRS=""
while IFS= read -r r; do
    [ -z "$r" ] && continue
    for p in "$r" "$(rp "$r")"; do
        d="$PROJ/$(printf '%s' "$p" | sed 's#[/.]#-#g')"
        [ -d "$d" ] && DIRS="$DIRS$d"$'\n'
    done
done < <(git worktree list --porcelain | awk '/^worktree /{print $2}')
DIRS=$(printf '%s' "$DIRS" | sort -u)
[ -z "$DIRS" ] && { echo "✗ 在 $PROJ 下找不到本仓任何 worktree 的 transcript 目录" >&2; exit 1; }

TMP=$(mktemp); trap 'rm -f "$TMP" "$TMP.log"' EXIT
n_files=0
while IFS= read -r d; do
    for tp in "$d"/*.jsonl; do
        [ -f "$tp" ] || continue
        sid=$(basename "$tp" .jsonl); n_files=$((n_files+1))
        parts="$tp"
        for s in "$d/$sid"/subagents/*.jsonl; do [ -f "$s" ] && { parts="$parts"$'\n'"$s"; n_files=$((n_files+1)); }; done
        printf '%s\n' "$parts" | while IFS= read -r f; do
            jq -r --arg sid "$sid" 'select(.type=="assistant") | .timestamp as $t
                | (.message.content // [])[]? | select(type=="object" and .type=="tool_use"
                    and (.name=="Edit" or .name=="Write" or .name=="MultiEdit" or .name=="NotebookEdit"))
                | [$sid, $t, (.input.file_path // .input.notebook_path // "")] | @tsv' "$f" 2>/dev/null
        done
    done
done <<< "$DIRS" >> "$TMP"
echo "扫了 $(printf '%s\n' "$DIRS" | wc -l | tr -d ' ') 个项目目录、$n_files 个 transcript：Edit/Write 记录 $(wc -l < "$TMP" | tr -d ' ') 条，来自 $(cut -f1 "$TMP" | sort -u | wc -l | tr -d ' ') 个会话"
echo

git log "$REV" --format='%H %ct %P|%(trailers:key=Claude-Session,valueonly,separator=)' -n "$N" > "$TMP.log"
python3 - "$TMP" "$TMP.log" <<'PY'
import sys, subprocess, datetime
edits = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    p = line.rstrip("\n").split("\t")
    if len(p) != 3 or not p[2]: continue
    try: ts = datetime.datetime.fromisoformat(p[1].replace("Z", "+00:00")).timestamp()
    except ValueError: continue
    edits.append((p[0], ts, p[2]))
def git(*a): return subprocess.run(["git", *a], capture_output=True, text=True).stdout
tot = multi = single = nomatch = nocmp = notrailer = 0
for line in open(sys.argv[2], encoding="utf-8"):
    head, _, trailer = line.rstrip("\n").partition("|")
    parts = head.split(); sha, ct, parents = parts[0], int(parts[1]), parts[2:]
    trailer = trailer.strip()
    if not parents: continue
    files = [f for f in git("diff-tree", "--no-commit-id", "--name-only", "-r", "-M", sha).split("\n") if f]
    if not files: continue
    pct = int(git("log", "-1", "--format=%ct", parents[0]).strip())
    cands = {}
    for sid, ts, path in edits:
        if pct - 60 <= ts <= ct + 5 and any(path.endswith("/" + f) for f in files):
            cands[sid] = cands.get(sid, 0) + 1
    tot += 1
    if not trailer: notrailer += 1
    others = {s: n for s, n in cands.items() if s != trailer}
    # 多会话：trailer 之外还有会话改过，或者改过的会话本来就不止一个；没有 trailer 又只有一个候选时比不了，单列
    if (trailer and others) or len(cands) >= 2: multi += 1; flag = "多会话"
    elif cands and not trailer: nocmp += 1; flag = "无trailer·单候选"
    elif cands: single += 1; flag = "单会话"
    else: nomatch += 1; flag = "无匹配"
    c = " ".join(f"{s[:8]}×{n}" for s, n in sorted(cands.items(), key=lambda x: -x[1]))
    print(f"{sha[:7]} trailer={trailer[:8] or '-':8s} {flag}  {c}")
print(f"\n有父提交且有文件改动的 commit {tot}：多会话 {multi}、单会话 {single}、无 trailer 且只有一个候选（比不了）{nocmp}、无匹配 {nomatch}；没有 trailer 的共 {notrailer}")
print("口径两头都偏：Bash 改的看不到（少算），别的 worktree / clone 的同名文件与失败的 Edit 会算进来（多算），见脚本头。")
PY
