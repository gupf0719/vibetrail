#!/bin/bash
# vibetrail 运行时共用函数：vibetrail-hook 与将来的 vibetrail init / push / doctor 都 source 它。只定义函数，不执行。
#
# 本机目录（DESIGN §3.3、§5），根目录 ${VT_HOME}（默认 ~/.vibetrail，测试时指到临时目录）：
#   config                     key=value：scope=project|user（默认 project）、jq=<jq 绝对路径>、endpoint=…、token=…
#   projects/<key>             登记表（scope=project 的开关）：文件名是主 checkout 路径的 sha1 前 16 位，内容是路径
#   state/<sid>/               每个会话一份：<名>.json（每份 transcript 的 lines / consumed_bytes / checkpoint_*）、
#                              <名>.seen（触发记录与人话记录的 uuid<TAB>行号，认回放副本）、ids（已写进 spool 的 event_id）、.lock
#   spool/<项目>/<sid>/*.jsonl  outbox 块：每次产出一块，临时文件 + rename 写入；push ack 后整块删（DESIGN §4）
#   logs/errors.log            失败日志，只留元数据（时间、事件、会话、阶段、退出码），不留 payload
: "${VT_HOME:=${VIBETRAIL_HOME:-$HOME/.vibetrail}}"

vt_conf(){ # vt_conf <key> [default] → 读 config 里的值
    local v=""
    [ -f "$VT_HOME/config" ] && v=$(sed -n "s/^$1=//p" "$VT_HOME/config" | tail -1)
    printf '%s' "${v:-${2:-}}"
}

vt_sha(){ # vt_sha <字符串> → sha1 前 16 位
    if command -v sha1sum >/dev/null 2>&1; then printf '%s' "$1" | sha1sum | cut -c1-16
    else printf '%s' "$1" | shasum -a 1 | cut -c1-16; fi
}

vt_realpath(){ ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s' "$1"; }

vt_main_checkout(){ # vt_main_checkout <目录> → 主 checkout 的绝对路径（git worktree list 第一条）；不在 git 仓里返回非零
    local d
    d=$(git -C "$1" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p') || return 1
    [ -n "$d" ] || return 1
    vt_realpath "$d"
}

vt_project_key(){ # vt_project_key <主 checkout 路径> → 登记表与 spool 用的键：<目录名>-<sha1 前 16 位>
    printf '%s-%s' "$(printf '%s' "$(basename "$1")" | tr -c 'A-Za-z0-9._-' '_')" "$(vt_sha "$1")"   # 先去掉 basename 的换行，否则 tr 把它换成 _
}

vt_registered(){ # vt_registered <主 checkout 路径>
    [ -f "$VT_HOME/projects/$(vt_sha "$1")" ]
}

vt_register(){ # vt_register <目录> → 登记它所在仓的主 checkout（幂等）
    local m; m=$(vt_main_checkout "$1") || { echo "✗ 不在 git 仓里：$1" >&2; return 1; }
    mkdir -p "$VT_HOME/projects" && printf '%s\n' "$m" > "$VT_HOME/projects/$(vt_sha "$m")"
}

vt_unregister(){ # vt_unregister <目录>
    local m; m=$(vt_main_checkout "$1") || return 1
    rm -f "$VT_HOME/projects/$(vt_sha "$m")"
}

vt_log_error(){ # vt_log_error <事件> <会话> <阶段> <退出码>：只记元数据
    mkdir -p "$VT_HOME/logs" 2>/dev/null || return 0
    printf '{"time":"%s","event":"%s","session_id":"%s","stage":"%s","rc":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "${4:-0}" >> "$VT_HOME/logs/errors.log" 2>/dev/null || true
}

vt_lock(){ # vt_lock <目录>：mkdir 原子锁；已被占用且不陈旧就返回非零（调用方跳过，下一次 hook 补上）
    local l="$1/.lock" age
    mkdir "$l" 2>/dev/null && return 0
    # 陈旧锁：持有者被杀（-p 模式下 async hook 会被杀）。首次整读 106 MB 约 12 s，300 s 足够宽
    age=$(( $(date +%s) - $(stat -f %m "$l" 2>/dev/null || stat -c %Y "$l" 2>/dev/null || date +%s) ))
    if [ "$age" -gt 300 ]; then rmdir "$l" 2>/dev/null; mkdir "$l" 2>/dev/null && return 0; fi
    return 1
}
vt_unlock(){ rmdir "$1/.lock" 2>/dev/null || true; }

vt_slug(){ # vt_slug <路径> → ~/.claude/projects 下的目录名（非字母数字都换成 -）
    printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'
}

vt_sha_stdin(){ if command -v sha1sum >/dev/null 2>&1; then sha1sum | cut -c1-40; else shasum -a 1 | cut -c1-40; fi; }

vt_fprint(){ # vt_fprint <文件> <已消费字节> → "inode:开头 4 KB 的 sha1:消费位置前 4 KB 的 sha1"
    # offset 信任检查（照 agentsview 的思路，09-15 调研）：只有同一个文件、开头与 checkpoint 前一段都没变，上次的 offset 才可信。
    # agentsview 哈希整个前缀；我们只哈希两小段，保住「从本轮开头读」的代价（每次多读 8 KB），代价是查不出只改了中间的原地重写
    local f=$1 n=$2 ino head tail s
    ino=$(stat -f %i "$f" 2>/dev/null || stat -c %i "$f" 2>/dev/null) || return 1
    s=$(( n > 4096 ? 4096 : n ))
    head=$(head -c "$s" "$f" | vt_sha_stdin)
    s=$(( n > 4096 ? n - 4096 : 0 ))
    tail=$(tail -c +$((s + 1)) "$f" | head -c $((n - s)) | vt_sha_stdin)
    printf '%s:%s:%s' "$ino" "$head" "$tail"
}

# ======== 以下 09-15 起为轮次元数据一路与安装加的（DESIGN §3.1、§3.5、§5） ========
# 目录补充：
#   state/<sid>/turns/<turn_id>.{start,stop,gap,fail}.json  hook 侧记的轮次证据：UserPromptSubmit 记轮起快照（start）、每次 Stop 覆盖一份
#                              轮止快照与本轮 commit（stop）、没有 Stop 的轮在下一轮开始或会话结束时补一份（gap）、StopFailure（fail）；
#                              映射层关轮时读它们（map-events.jq 的 ${hook_turns}），拼出 turn.end 的 status / vcs / commits
#   state/<sid>/last_turn      hook 最近开的一轮的 turn_id；state/<sid>/session.json  会话级：model、source
VT_RUNTIME_VERSION=0.2.0-dev   # vibetrail 自己的版本，进每条事件的 extensions.vibetrail.version
VT_NS=6c90e594-0cb4-59d0-9186-740d215c8b7f     # uuid5(NS_URL, "vibetrail")，DESIGN §4.2

vt_sha1_files(){ # 一次算完多份文件的 sha1（macOS 的 shasum 是 perl，逐个起进程慢）
    if command -v sha1sum >/dev/null 2>&1; then sha1sum "$@"; else shasum -a 1 "$@"; fi
}

vt_fill_ids(){ # vt_fill_ids <sid> < 带 _key 的事件 → 填上 event_id = UUIDv5(NS, "<sid>|<_key>")、删掉 _key
    # 同一 _key 出现两次是映射层的错（同一记录派生了两条同型事件），报错退出
    local sid=$1 tmp i key nsb
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/vibetrail-ids.XXXXXX") || return 1
    cat > "$tmp/in"
    "${JQ:-jq}" -r 'select(._key != null) | ._key' "$tmp/in" > "$tmp/keys" || { rm -rf "$tmp"; return 1; }
    nsb=$(printf '%s' "$VT_NS" | tr -d '-' | sed 's/../\\x&/g')
    mkdir "$tmp/k"; i=0
    while IFS= read -r key; do i=$((i + 1)); { printf "$nsb"; printf '%s' "$sid|$key"; } > "$tmp/k/$i"; done < "$tmp/keys"
    : > "$tmp/ids"
    if [ "$i" -gt 0 ]; then
        ( cd "$tmp/k" && seq 1 "$i" | xargs "$(command -v sha1sum >/dev/null 2>&1 && echo sha1sum || echo shasum)" ) | cut -c1-40 \
          | awk '{ h = $0; printf "%s-%s-5%s-%x%s-%s\n", substr(h,1,8), substr(h,9,4), substr(h,14,3),
                   (index("0123456789abcdef", substr(h,17,1)) - 1) % 4 + 8, substr(h,18,3), substr(h,21,12) }' \
          | paste "$tmp/keys" - > "$tmp/ids"
    fi
    if [ -n "$(cut -f1 "$tmp/ids" | sort | uniq -d | head -1)" ]; then
        echo "✗ 事件 _key 重复: $(cut -f1 "$tmp/ids" | sort | uniq -d | head -3 | tr '\n' ' ')" >&2; rm -rf "$tmp"; return 1
    fi
    "${JQ:-jq}" -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries' "$tmp/ids" > "$tmp/ids.json"
    "${JQ:-jq}" -c --slurpfile ids "$tmp/ids.json" 'select(._ledger == null) | .event_id = $ids[0][._key] | del(._key)' "$tmp/in"
    local rc=$?; rm -rf "$tmp"; return $rc
}

vt_spool_write(){ # vt_spool_write <项目键> <sid> <块名> <事件文件>：去掉已写过的 event_id，余下的写成一块（临时文件 + rename），登记 ids
    # ids 在 state/<sid>/ids；同步 hook 不拿会话锁（不能让人等），与 Stop 并发时最坏多写一条同 event_id 的事件，云端按 event_id 幂等
    local pkey=$1 sid=$2 name=$3 f=$4 sd="$VT_HOME/state/$2" dest chunk
    mkdir -p "$sd" || return 1
    touch "$sd/ids"
    # ⚠️ 不用 `NR == FNR` 读 ids：首次运行 ids 是空文件，NR == FNR 会对后一个文件也成立，事件全被当成 id 吞掉
    awk -v idsf="$sd/ids" 'BEGIN { while ((getline l < idsf) > 0) seen[l] = 1 }
         { if (match($0, /"event_id":"[0-9a-f-]+"/)) { id = substr($0, RSTART + 12, RLENGTH - 13); if (id in seen) next; seen[id] = 1 }
           print }' "$f" > "$f.new"
    if [ -s "$f.new" ]; then
        dest="$VT_HOME/spool/$pkey/$sid"
        mkdir -p "$dest" && chunk="$(date -u +%Y%m%dT%H%M%SZ)-$$-$name.jsonl"
        cp "$f.new" "$dest/.$chunk.tmp" && mv "$dest/.$chunk.tmp" "$dest/$chunk" || { rm -f "$f.new"; return 1; }
        sed -n 's/.*"event_id":"\([0-9a-f-]*\)".*/\1/p' "$f.new" >> "$sd/ids"
    fi
    rm -f "$f.new"
    return 0
}

vt_timeout(){ # vt_timeout <秒> <命令…>：到点杀掉（macOS 没有 timeout 命令）；超时返回非零
    local s=$1 pid w rc; shift
    "$@" & pid=$!
    ( sleep "$s"; kill -TERM "$pid" ) >/dev/null 2>&1 </dev/null & w=$!
    wait "$pid"; rc=$?
    kill "$w" >/dev/null 2>&1; wait "$w" 2>/dev/null
    return $rc
}

vt_git_snapshot(){ # vt_git_snapshot <目录> → 一行 JSON：{head_sha, branch, dirty, dirty_files, worktree, at_epoch}；不在 git 仓里输出 null
    # 全程 GIT_OPTIONAL_LOCKS=0：git status 会顺手刷新并写回 .git/index，被观测仓零写入（A8）不许；status 限时 3 s，超时就不报脏否
    local d=$1 top head branch n
    top=$(GIT_OPTIONAL_LOCKS=0 git -C "$d" rev-parse --show-toplevel 2>/dev/null) || { echo null; return 0; }
    head=$(GIT_OPTIONAL_LOCKS=0 git -C "$d" rev-parse -q --verify HEAD 2>/dev/null)
    branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$d" symbolic-ref -q --short HEAD 2>/dev/null)
    n=$( { vt_timeout 3 env GIT_OPTIONAL_LOCKS=0 git -C "$d" status --porcelain=v1 -z --untracked-files=normal 2>/dev/null \
           || echo "__vt_timeout__"; } | tr '\0' '\n' | grep -v '^$' | awk '/__vt_timeout__/ { t = 1 } END { if (t) print ""; else print NR }')
    "${JQ:-jq}" -n -c --arg top "$top" --arg head "$head" --arg branch "$branch" --arg n "$n" --argjson at "$(date +%s)" \
        '{worktree: $top, at_epoch: $at}
         + (if $head != "" then {head_sha: $head} else {} end)
         + (if $branch != "" then {branch: $branch} else {} end)
         + (if $n != "" then {dirty: (($n | tonumber) > 0), dirty_files: ($n | tonumber)} else {} end)'
}

vt_commits(){ # vt_commits <目录> <轮起 HEAD> <轮起时间 epoch> → 一行 JSON：{commits: [完整 sha…], method}（DESIGN §3.5）
    # 本轮的 commit = 现在的 HEAD 与本轮 reflog 里「新建提交」那几类操作留下的 sha，减去轮起 HEAD 能到的。
    # 起是止的祖先时就是 rev-list 起..止；rebase / reset / 切分支后又提交时，reflog 那一路把新提交补回来，切到已有分支不会被算进来。
    # 人在别的终端提交也会被算进当轮——区分靠映射层看 transcript 里有没有 agent 的 git commit 调用（commit_attribution）
    local d=$1 start=$2 since=$3 end tips list base method=rev-list
    [ -n "$start" ] || { echo null; return 0; }
    end=$(GIT_OPTIONAL_LOCKS=0 git -C "$d" rev-parse -q --verify HEAD 2>/dev/null) || { echo null; return 0; }
    tips=$(GIT_OPTIONAL_LOCKS=0 git -C "$d" reflog --date=unix --format='%gd%x09%H%x09%gs' HEAD 2>/dev/null | awk -F'\t' -v since="${since:-0}" '
        { t = $1; sub(/^.*@\{/, "", t); sub(/\}$/, "", t); if (t + 0 < since + 0) exit
          if ($3 ~ /^(commit|cherry-pick|revert|merge|rebase|pull|am)/) print $2 }' | sort -u)
    # shellcheck disable=SC2086
    list=$(GIT_OPTIONAL_LOCKS=0 git -C "$d" rev-list --reverse -n 256 "$end" $tips "^$start" 2>/dev/null) || { echo null; return 0; }
    base=$(GIT_OPTIONAL_LOCKS=0 git -C "$d" rev-list --reverse -n 256 "$end" "^$start" 2>/dev/null)
    [ "$list" = "$base" ] || method=reflog      # reflog 真补出了 rev-list 起..止 之外的提交（rebase、切分支后提交）才标 reflog
    printf '%s\n' "$list" | "${JQ:-jq}" -R -s -c --arg m "$method" '{commits: (split("\n") | map(select(test("^[0-9a-f]{40,64}$")))), method: $m}'
}

vt_turn_file(){ # vt_turn_file <sid> <turn_id> <start|stop|gap|fail> → 路径（turn_id 里不能当文件名的字符换成 _）
    local t; t=$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '_'); t=${t#.}
    printf '%s/state/%s/turns/%s.%s.json' "$VT_HOME" "$1" "$t" "$3"
}

vt_write_json(){ # vt_write_json <路径> < JSON：临时文件 + rename
    mkdir -p "$(dirname "$1")" && cat > "$1.$$.tmp" && mv "$1.$$.tmp" "$1"
}

vt_hook_turns(){ # vt_hook_turns <sid> → 一行 JSON：{<turn_id>: {start, stop, gap, fail}}，映射层关轮时用
    local dir="$VT_HOME/state/$1/turns"
    if ls "$dir"/*.json >/dev/null 2>&1; then
        "${JQ:-jq}" -n -c 'reduce (inputs | {f: (input_filename | sub("^.*/"; "") | sub("\\.json$"; "")), v: .}) as $x ({};
            ($x.f | capture("^(?<id>.*)\\.(?<k>start|stop|gap|fail)$")) as $m | .[$m.id][$m.k] = $x.v)' "$dir"/*.json 2>/dev/null || echo '{}'
    else echo '{}'; fi
}

vt_prune_removed(){ # projects remove --drop 挪出 spool 的数据留一天，之后删掉（用户 09-16：「不要7天，一天吧」）。hook 与 CLI 每次都顺手做
    [ -d "$VT_HOME/removed" ] || return 0
    find "$VT_HOME/removed" -mindepth 1 -maxdepth 1 -mtime +0 -exec rm -rf {} + 2>/dev/null
    return 0
}

vt_hook_perms(){ # vt_hook_perms <sid> → 一行 JSON 数组：PermissionRequest 记的权限框证据 [{at, tool_name, agent_id, prompt_id, permission_mode}]（K7）
    local dir="$VT_HOME/state/$1/perms"
    if ls "$dir"/*.json >/dev/null 2>&1; then "${JQ:-jq}" -s -c 'map(objects)' "$dir"/*.json 2>/dev/null || echo '[]'
    else echo '[]'; fi
}

vt_agent_version(){ # vt_agent_version <transcript> → Claude Code 版本：先看 hook 环境的 AI_AGENT（claude-code_2-1-266_agent），再看 transcript 末尾
    local v
    v=$(printf '%s' "${AI_AGENT:-}" | sed -n 's/^claude-code_\([0-9][0-9]*\)-\([0-9][0-9]*\)-\([0-9][0-9]*\).*/\1.\2.\3/p')
    if [ -z "$v" ] && [ -f "${1:-}" ]; then v=$(tail -c 65536 "$1" 2>/dev/null | grep -o '"version":"[^"]*"' | tail -1 | cut -d'"' -f4); fi
    printf '%s' "$v"
}

vt_settings_path(){ printf '%s' "${VIBETRAIL_CLAUDE_SETTINGS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json}"; }
vt_claude_projects(){ printf '%s' "${VIBETRAIL_CLAUDE_PROJECTS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}"; }
