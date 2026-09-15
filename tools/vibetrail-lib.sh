#!/bin/bash
# vibetrail 运行时共用函数：vibetrail-hook 与将来的 vibetrail init / push / doctor 都 source 它。只定义函数，不执行。
#
# 本机目录（DESIGN §3.3、§5），根目录 $VT_HOME（默认 ~/.vibetrail，测试时指到临时目录）：
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
