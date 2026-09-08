#!/bin/bash
# Claude Code hook 探针 —— 验证 hook 在目标环境下是否触发，并原样落盘它收到的 stdin。
#
# 为什么需要它：工具能否在 Claude desktop app 下工作，取决于它靠什么机制挂钩。
# hook 型和文件监听型可用，进程包装型（wrapper）不可用。本脚本用来实测第一类。
#
# 用法：
#   1. 把本脚本路径填进 <repo>/.claude/settings.local.json（该文件通常已被 gitignore）：
#        "hooks": {
#          "PostToolUse":      [{"hooks":[{"type":"command","command":"bash /abs/path/hook-probe.sh PostToolUse"}]}],
#          "UserPromptSubmit": [{"hooks":[{"type":"command","command":"bash /abs/path/hook-probe.sh UserPromptSubmit"}]}]
#        }
#   2. 让 agent 随便调一次工具。settings 是热加载的，**不需要重启**。
#   3. 读同目录下的 hook-fired.log。
#   4. 测完把 hooks 段删掉。
#
# 2026-09-08 在 Claude desktop app v2.1.202 实测通过，stdin 含：
#   session_id / transcript_path / cwd / permission_mode / prompt_id /
#   hook_event_name / tool_name / tool_input / tool_response / tool_use_id / duration_ms
#
# 其中 transcript_path 直接给出本会话 JSONL 的绝对路径 —— 不需要自己做 ID 映射
# （desktop 侧 MCP 报的 sessionId 形如 local_<uuid>，与 transcript 文件名不是同一个 ID 空间）。

set -euo pipefail
LOG="$(cd "$(dirname "$0")" && pwd)/hook-fired.log"
{
    echo "--- $(date -u +%FT%TZ) event=${1:-unknown}"
    cat
    echo
} >> "$LOG"
