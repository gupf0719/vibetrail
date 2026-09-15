# vibetrail：把 Claude Code 给 hook 的 payload 映射成 paas-coding-hook 协议 1.0 事件——轮次元数据一路里 hook 直接给得出的那几类
# （DESIGN §3.1、§4.1）。transcript 才给得出的（分歧、turn.end 的用量与状态）在 map-events.jq。
#
# 用法（由 vibetrail-hook 调）：
#   jq -c --arg event <hook 事件名> --arg project_id … --arg workspace_id … --arg vt_version … --arg agent_version … \
#         --arg surface … --arg now <ISO 毫秒 Z> --argjson vcs <vt_git_snapshot 的输出或 null> --argjson extra <补充对象> \
#         -f hook-events.jq < payload
# 输出：每行一个事件（event_id 为 null、多一个 _key，由 vt_fill_ids 算 UUIDv5 后填上）。不认识的事件不输出。
#
# 只带元数据，不带正文（D5）：UserPromptSubmit 的 prompt、Stop / SubagentStop 的 last_assistant_message、
# PostToolUseFailure 的 error 原文（是工具输出）、Notification 的 message、会话标题都不带。
#   $extra：model（会话已知的 model）、worktree、parent_instance / parent_call_id（子 agent）、sha256 / bytes（InstructionsLoaded）

def opt($k; $v): if $v == null or $v == "" then {} else {($k): $v} end;
def codeOk: type == "string" and test("^[a-z][a-z0-9]*([._-][a-z0-9]+)*$");
# 任意字符串 → 协议的 code（小写、[a-z0-9] 与 ._- 分隔、字母开头）
def codeify: tostring | ascii_downcase | gsub("[^a-z0-9._-]+"; "_") | gsub("^[^a-z]+"; "") | gsub("[._-]+$"; "")
             | gsub("[._-]{2,}"; "_") | if . == "" then "unknown" else .[0:128] end;
def snake: gsub("(?<a>[a-z0-9])(?<b>[A-Z])"; "\(.a)_\(.b)") | ascii_downcase;
def vcsOf($v): if ($v | type) == "object"
  then ($v | {head_sha, branch, dirty} | with_entries(select(.value != null))) | if length > 0 then . else null end
  else null end;
# 协议要求 turn_id 的事件：payload 没给 prompt_id（进程里第一条人话之前）时用会话 id + 时间推一个，provenance 标 inferred
def turnId($p): if ($p.prompt_id | type) == "string" and $p.prompt_id != "" then {id: $p.prompt_id, inferred: false}
                else {id: ("inferred-" + $now), inferred: true} end;
def capabilities: ["session.start", "session.end", "turn.start", "turn.end", "subagent.start", "subagent.end",
                   "permission.decision", "tool.request", "message.user", "message.assistant", "ext.claude"];

. as $p
| ($p.hook_event_name // $event) as $hname
| {
    event_id: null,
    occurred_at: $now,
    type: null,
    agent: ({name: "claude-code"} + opt("version"; $agent_version) + (if ($surface | codeOk) then {surface: $surface} else {} end)),
    project_id: $project_id, workspace_id: $workspace_id, session_id: $p.session_id,
    agent_instance_id: ($p.agent_id // "main"),
    provenance: {kind: "hook", source_event: $hname},
    payload: {},
    extensions: ({"vibetrail.version": $vt_version} + opt("vibetrail.worktree"; ($extra.worktree // $vcs.worktree // null)))
  } as $b
| def withTurn: turnId($p) as $t | .turn_id = $t.id
    | if $t.inferred then .provenance = {kind: "inferred", rule_version: "turn-v1", source_event: $hname} else . end;
  def hdr($name; $payload): $b + {type: ("ext.claude." + ($name | snake)), payload: $payload}
    | (if ($p.prompt_id | type) == "string" and $p.prompt_id != "" then .turn_id = $p.prompt_id else . end);
  if $event == "SessionStart" then
    $b + {type: "session.start", payload: {source: (($p.source // "startup") | codeify), capabilities: capabilities}}
    | .agent_instance_id = "main"
    | .extensions += opt("claude.model"; ($p.model // $extra.model)) + opt("claude.agent_type"; $p.agent_type)
                     + opt("vibetrail.vcs"; vcsOf($vcs)) + opt("vibetrail.cwd"; $p.cwd)
    | ._key = ("session.start|" + (($p.source // "startup") | codeify) + "|" + $now)
  elif $event == "UserPromptSubmit" then
    $b + {type: "turn.start", payload: (opt("model"; $extra.model) + opt("vcs"; vcsOf($vcs)))}
    | .agent_instance_id = "main"
    | withTurn
    | .extensions += opt("claude.prompt_source"; $p.source) + opt("claude.permission_mode"; $p.permission_mode)
                     + opt("claude.effort"; $p.effort.level) + opt("vibetrail.dirty_files"; $vcs.dirty_files)
    | ._key = (.turn_id + "|turn.start")
  elif $event == "SubagentStart" or $event == "SubagentStop" then
    ($p.agent_id // "unknown") as $aid
    | $b + {type: (if $event == "SubagentStart" then "subagent.start" else "subagent.end" end),
            agent_instance_id: $aid, parent_agent_instance_id: ($extra.parent_instance // "main"),
            payload: ({agent_type: ($p.agent_type // "unknown")}
                      + (if $event == "SubagentStop" then {status: {code: "completed", category: "success"}} else {} end))}
    + opt("parent_call_id"; $extra.parent_call_id)
    | withTurn
    | ._key = ($aid + "|" + .type)
  elif $event == "SessionEnd" then
    $b + {type: "session.end", payload: {reason: (($p.reason // "other") | codeify), status: {code: "completed", category: "success"}}}
    | .agent_instance_id = "main"
    | .extensions += opt("vibetrail.vcs"; vcsOf($vcs))
    | ._key = ("session.end|" + $now)
  elif $event == "PostToolUseFailure" then
    hdr($event; {tool_use_id: $p.tool_use_id, tool_name: $p.tool_name}
                + opt("is_interrupt"; $p.is_interrupt) + opt("duration_ms"; $p.duration_ms)
                + {error_bytes: (($p.error // "") | tostring | utf8bytelength)})
    | ._key = ("ext|PostToolUseFailure|" + ($p.tool_use_id // $now))
  elif $event == "PermissionDenied" then
    hdr($event; {tool_use_id: $p.tool_use_id, tool_name: $p.tool_name} + opt("reason"; (($p.reason // "") | tostring | .[0:1024])))
    | ._key = ("ext|PermissionDenied|" + ($p.tool_use_id // $now))
  elif $event == "StopFailure" then
    hdr($event; {error: (($p.error // "unknown") | tostring)} + opt("error_details"; (($p.error_details // "") | tostring | .[0:512])))
    | ._key = ("ext|StopFailure|" + $now)
  elif $event == "Notification" then
    hdr($event; {notification_type: ($p.notification_type // "unknown")})
    | ._key = ("ext|Notification|" + $now)
  elif $event == "InstructionsLoaded" then
    hdr($event; {file_path: $p.file_path} + opt("memory_type"; $p.memory_type) + opt("load_reason"; $p.load_reason)
                + opt("parent_file_path"; $p.parent_file_path) + opt("trigger_file_path"; $p.trigger_file_path)
                + opt("sha256"; $extra.sha256) + opt("bytes"; $extra.bytes))
    | ._key = ("ext|InstructionsLoaded|" + ($p.file_path // "") + "|" + $now)
  elif $event == "CwdChanged" then
    hdr($event; {old_cwd: $p.old_cwd, new_cwd: $p.new_cwd})
    | ._key = ("ext|CwdChanged|" + $now)
  else empty end
