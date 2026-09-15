# vibetrail 演示与测试用（上线用不到，用户 09-15）：把本机 spool 里的协议事件整理成一份 markdown 报告，三类分开展示：
#   一、每一轮的全量数据：轮次元数据（turn.start / turn.end，外加会话、子 agent、事件头）+ 调用 trace（每次模型调用、每次工具调用各一条，不带正文）
#   二、人机分歧（permission.decision、打断的 turn.end / subagent.end，连同派生的被拒调用、被打断的回复、之后人说的话）
#   三、commit ↔ 会话（turn.end 的 commits：每轮起止 HEAD 与本轮 reflog 推出，DESIGN §3.5）
# 用法（由同目录的 report.sh 调）：jq -s -r --argjson subjects <{sha: 提交说明}> --arg generated <生成时间> --arg source <spool 目录>
#                                    --argjson chunks <块数> -f report.jq < 全部事件（每行一条）
# 时间都换成本机时区显示；提交说明是生成报告时从本机 git 查的，不在事件里、不上报。

def clip($n): if type == "string" then gsub("[\r\n\t]+"; " ") | gsub(" {2,}"; " ") | if length > $n then .[0:$n] + "…" else . end else "" end;
def cell: tostring | gsub("\\|"; "\\|") | gsub("[\r\n]+"; " ") | if . == "" then "–" else . end;
def code: cell | if test("`") or . == "" then . else "`" + . + "`" end;
def epoch: if type == "string" then (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) else null end;
def lt($fmt): epoch | if . == null then "–" else strflocaltime($fmt) end;
def dur($a; $b): (($b | epoch) as $y | ($a | epoch) as $x
  | if $x == null or $y == null or $y < $x then "–" else ($y - $x) as $d
      | if $d < 60 then "\($d | floor)s" elif $d < 3600 then "\($d / 60 | floor)m\($d % 60 | floor)s"
        else "\($d / 3600 | floor)h\(($d % 3600) / 60 | floor)m" end end);
def k: if type != "number" then "–" elif . >= 1000000 then "\((. / 100000 | floor) / 10)M" elif . >= 1000 then "\((. / 100 | floor) / 10)k" else tostring end;
def short: if type == "string" and length > 0 then .[0:8] else "–" end;
def sha7: if type == "string" then .[0:7] else "–" end;
def status_label: {completed: "答完", denied: "拒绝后停下", interrupted: "被打断", cancelled: "被打断", hook_stopped: "hook 叫停", unknown: "未知"}[.] // ("出错：" + .);
def evidence_label: {hook_stop: "Stop hook", stop_hook_summary: "答完标记", end_turn: "模型收尾", denial: "拒绝记录", stop_failure: "StopFailure", none: "无"}[. // "none"] // .;
def closed_label: {stop: "Stop 时", summary: "答完标记", next_turn: "下一轮开始", session_end: "会话结束", resume: "会话恢复", idle: "空闲补做", denied: "拒绝处"}[. // ""] // "–";
def kind_label: {permission_denied: "人拒绝", classifier_blocked: "分类器拦截", permission_infra_fail: "权限链路故障", interrupt: "人打断", interrupt_for_tool_use: "人打断（拒绝时）", interrupt_tool: "按停止打断工具"}[.] // .;
# 「人拒绝」与「按停止打断工具」是怎么分出来的（DESIGN D9）
def split_label: {permission_request: "看权限框", permission_mode: "按模式粗分", subagent_rejected: "子 agent 规则"}[.] // null;
def vcs_s: if type == "object" then "\(.head_sha | sha7)\(if .dirty == true then "*" else "" end)" else "–" end;
def call_s: (.payload.tool_name // "?") + " " + ((.payload.input | if type == "object" then (.command // .file_path // .pattern // .url // tojson) else tojson end) | clip(90) | code);
# 同一轮有多条 turn.end（被别的 Stop hook 拦下后又 Stop 一次）取 vibetrail.stops 最大的那条（DESIGN D7）
def latest_end: max_by(.extensions["vibetrail.stops"] // 0);
def is_trigger: .type == "permission.decision" or ((.type == "turn.end" or .type == "subagent.end") and .provenance.rule_version == "diverge-v1");
def is_llm: .type == "message.assistant" and .provenance.rule_version == "call-v1";
def is_tool: .type == "tool.end" and .provenance.rule_version == "call-v1";
def durms: if type != "number" then "–" elif . < 1000 then "\(floor)ms" elif . < 60000 then "\((. / 100 | floor) / 10)s" else "\(. / 60000 | floor)m\((. % 60000) / 1000 | floor)s" end;
# 「依据 · 何时关」一列：两者相同就只写一次；分歧一路发的打断 turn.end 没有这两个字段
def end_col: if . == null then "–" else
  (.extensions["vibetrail.end_evidence"]) as $ev | (.extensions["vibetrail.closed_by"]) as $cb
  | if $ev == null and $cb == null then (if .payload.status.code == "interrupted" or .payload.status.code == "cancelled" then "打断记录" else "–" end)
    else ($ev | evidence_label) as $a | ($cb | closed_label) as $b | if $a == $b or $b == "–" then $a else $a + " · " + $b end end end;

map(select(type == "object")) as $ev
| ($ev | group_by(.session_id) | map({sid: .[0].session_id, project: .[0].project_id, events: ., first: (map(.occurred_at) | min)}) | sort_by(.first)) as $sessions
| ($ev | map(select(is_trigger))) as $triggers
# desktop 在别的 worktree 续接会话时，会把原会话的历史整段复制进新的会话文件（记录 uuid 不变、会话 id 换了），同一段历史按每个会话各报一遍（OPEN-ISSUES K8）。
# 报告里：分歧按来源记录 uuid 只列一次、注明还出现在哪些会话；每轮表标出哪些轮与更早的会话重复
| ($sessions | map({sid, first}) ) as $order
| ($triggers | group_by(.provenance.source_event_id // .event_id) | map(sort_by(.occurred_at, .session_id) | {t: .[0], also: ([.[1:][] | .session_id] | unique)})) as $tgroups
| ($sessions | reduce .[] as $s ({seen: {}, dup: {}};
     ([$s.events[] | select(.type == "turn.start" or .type == "turn.end") | .turn_id] | unique) as $ids
     | .dup[$s.sid] = ([$ids[] as $i | select(.seen[$i] != null) | .seen[$i]] | {n: length, from: (unique)})
     | reduce $ids[] as $i (.; if .seen[$i] == null then .seen[$i] = $s.sid else . end)) | .dup) as $dups
| ($ev | map(select(.type == "turn.end")) | group_by([.session_id, .turn_id]) | map(latest_end) | map(select((.commits // []) | length > 0))) as $commit_turns
| [
  "# vibetrail 采集报告",
  "",
  "生成于 \($generated) · 数据来自 `\($source)`，\($chunks) 块、\($ev | length) 条事件 · 只在本机，还没有 push",
  "",
  "下面表里 8 位的 `ffe1c0f1` 这类是会话 id、轮 id（promptId）的前 8 位；会话总表、各会话标题与 commit 表给完整的会话 id。",
  "",
  "| 会话 id | 项目 | 开始 | 轮数 | 人机分歧 | commit |",
  "|---|---|---|---|---|---|",
  ($sessions[] | . as $s
    | "| `\($s.sid)` | \($s.project | cell) | \($s.first | lt("%m-%d %H:%M")) | \([$s.events[] | select(.type == "turn.start" or .type == "turn.end") | .turn_id] | unique | length) | \([$tgroups[] | select(.t.session_id == $s.sid)] | length)\(if ([$tgroups[] | select(.t.session_id != $s.sid and (.also | index($s.sid)))] | length) > 0 then "（另有 " + ([$tgroups[] | select(.t.session_id != $s.sid and (.also | index($s.sid)))] | length | tostring) + " 条复制来的）" else "" end) | \([$commit_turns[] | select(.session_id == $s.sid) | .commits[]] | length) |"),
  "",
  "## 一、每一轮的全量数据（轮次 + 调用 trace，不带正文）",
  "",
  "来源：`turn.start`（说一句话时 hook 当场记，transcript 补位）与 `turn.end`（模型答完时关轮）；调用 trace 照 Pilot 的粒度，每次模型调用一条 `message.assistant`、每次工具调用一条 `tool.end`，",
  "只有模型、token、耗时、状态这些元数据，不含对话与工具的正文（DESIGN D5）。HEAD 后面带 `*` 表示工作区当时有未提交的改动。",
  "",
  ($sessions[] | . as $s
    | ($s.events | map(select(.type == "turn.start")) | group_by(.turn_id) | map(sort_by(if .provenance.kind == "hook" then 0 else 1 end) | .[0])) as $starts
    | ($s.events | map(select(.type == "turn.end")) | group_by(.turn_id) | map(latest_end)) as $ends
    | ([$starts[].turn_id, $ends[].turn_id] | unique) as $ids
    | ($ids | map(. as $id | {id: $id, s: ([$starts[] | select(.turn_id == $id)][0]), e: ([$ends[] | select(.turn_id == $id)][0])})
           | sort_by(.s.occurred_at // .e.occurred_at)) as $turns
    | ($s.events | map(select(.agent.version != null)) | .[0].agent // {}) as $agent
    | "### 会话 `\($s.sid)` · \($s.project | cell) · Claude Code \($agent.version // "?")\(if $agent.surface then "（" + $agent.surface + "）" else "" end)",
      "",
      (if ($dups[$s.sid].n // 0) > 0 then "> 其中 \($dups[$s.sid].n) 轮与更早的会话 \([$dups[$s.sid].from[] | "`" + short + "`"] | join("、")) 相同：desktop 续接会话时复制过来的历史（OPEN-ISSUES K8）。", "" else empty end),
      "| # | 轮 | 开始 | 结束 | 用时 | 状态 | 依据 · 何时关 | 模型 | tokens 入 / 缓存 / 出 | 调用 模型 / 工具 | HEAD 起 → 止 | 分歧 | commit |",
      "|---|---|---|---|---|---|---|---|---|---|---|---|---|",
      ($turns | to_entries[] | .key as $i | .value as $t
        | ($t.e.payload.usage // {}) as $u
        | "| \($i + 1) | `\($t.id | short)` | \($t.s.occurred_at | lt("%H:%M:%S")) | \($t.e.occurred_at | lt("%H:%M:%S")) | \(dur($t.s.occurred_at; $t.e.occurred_at)) | \(if $t.e then ($t.e.payload.status.code | status_label) else "进行中" end) | \($t.e | end_col) | \($t.e.payload.model // $t.s.payload.model // "–") | \($u.input_tokens | k) / \($u.cached_input_tokens | k) / \($u.output_tokens | k) | \([$s.events[] | select(is_llm and .turn_id == $t.id)] | length) / \([$s.events[] | select(is_tool and .turn_id == $t.id)] | length) | \($t.s.payload.vcs | vcs_s) → \($t.e.payload.vcs | vcs_s) | \([$triggers[] | select(.session_id == $s.sid and .turn_id == $t.id)] | length) | \(($t.e.commits // []) | length) |"),
      "",
      ( [$s.events[] | select(is_llm or is_tool)] | sort_by(.occurred_at, (if is_llm then 0 else 1 end)) as $calls
        | if ($calls | length) == 0 then empty else
            "<details><summary>调用明细（trace）：模型调用 \([$calls[] | select(is_llm)] | length) 次、工具调用 \([$calls[] | select(is_tool)] | length) 次</summary>",
            "",
            "| 时间 | 轮 | 实例 | 类型 | 名称 | 耗时 | tokens 入 / 缓存 / 出 | 结果 |",
            "|---|---|---|---|---|---|---|---|",
            ($calls[] | . as $c
              | if is_llm then (.extensions["vibetrail.call"] // {}) as $x
                  | "| \(.occurred_at | lt("%H:%M:%S")) | `\(.turn_id | short)` | \(.agent_instance_id | if . == "main" then "main" else short end) | 模型 | \(.payload.model // "–") | \(if $x.started_at then (((.occurred_at | epoch) - ($x.started_at | epoch)) * 1000 | durms) else "–" end) | \($x.usage.input_tokens | k) / \($x.usage.cached_input_tokens | k) / \($x.usage.output_tokens | k) | \($x.stop_reason // "–")\(if ($x.tool_calls // []) | length > 0 then " → " + ($x.tool_calls | join("、")) else "" end)\(if $x.thinking then "（有 thinking）" else "" end) |"
                else "| \(.occurred_at | lt("%H:%M:%S")) | `\(.turn_id | short)` | \(.agent_instance_id | if . == "main" then "main" else short end) | 工具 | \(.payload.tool_name | cell) | \(.payload.duration_ms | durms) | – | \(.payload.status.code | {success: "成功", error: "出错", cancelled: "取消"}[.] // .) |" end),
            "", "</details>", "" end),
      ( [$s.events[] | select(.type == "session.start" or .type == "session.end" or .type == "subagent.start" or .type == "subagent.end" or (.type | startswith("ext.")))
         | select((.type == "subagent.end" and .provenance.rule_version == "diverge-v1") | not)] as $others
        | if ($others | length) == 0 then empty else
            "<details><summary>这个会话里的其他事件（\($others | length) 条：会话起止、子 agent、hook 事件头）</summary>",
            "",
            "| 时间 | 事件 | 轮 | 说明 |",
            "|---|---|---|---|",
            ($others | sort_by(.occurred_at)[]
              | "| \(.occurred_at | lt("%H:%M:%S")) | `\(.type)` | \(.turn_id | short) | \(
                  if .type == "session.start" then "来源 \(.payload.source)，模型 \(.extensions["claude.model"] // "?")，HEAD \(.extensions["vibetrail.vcs"] | vcs_s)"
                  elif .type == "session.end" then "原因 \(.payload.reason)"
                  elif (.type | startswith("subagent")) then "\(.payload.agent_type // "?") `\(.agent_instance_id | short)`\(if .payload.status then " " + (.payload.status.code | status_label) else "" end)"
                  else (.payload | tojson | clip(100) | cell) end) |"),
            "", "</details>", "" end)),
  "## 二、人机分歧",
  "",
  "来源：transcript 里人打断、人拒绝、分类器拦截、权限链路故障（diverge-v1 判据），只带能判责的最小正文：被拒或被打断的那次调用、拒绝原文、被打断的回复、之后人说的话。",
  "按停止打断正在跑的工具时，Claude Code 写进 transcript 的与拒绝一模一样；「按停止打断工具」与「人拒绝」是按有没有弹过权限框、没有证据时按这一轮的 permissionMode 分的（DESIGN D9），类型后面注明依据。",
  "",
  (if ($triggers | length) == 0 then "这段时间内没有人机分歧。", "" else
    "| # | 时间 | 会话 · 轮 | 类型 | 谁决定 | 对哪次调用 | 原文 | 被打断的回复 | 之后人说 |",
    "|---|---|---|---|---|---|---|---|---|",
    ($tgroups | sort_by(.t.occurred_at) | to_entries[] | .key as $i | .value.t as $t | .value.also as $also
      | ($t.provenance.source_event_id // "") as $tid
      | ([$ev[] | select(.session_id == $t.session_id and .type == "tool.request" and .extensions["vibetrail.trigger"] == $tid)]) as $calls
      | ([$ev[] | select(.session_id == $t.session_id and .type == "message.assistant" and .extensions["vibetrail.trigger"] == $tid)][0]) as $reply
      | ([$ev[] | select(.session_id == $t.session_id and .type == "message.user" and ((.extensions["vibetrail.after"] // []) | index($tid)))] | sort_by(.occurred_at)) as $after
      | "| \($i + 1) | \($t.occurred_at | lt("%m-%d %H:%M:%S")) | `\($t.session_id | short)` · `\($t.turn_id | short)`\(if ($also | length) > 0 then "<br>也在 " + ([$also[] | "`" + short + "`"] | join("、")) else "" end) | \($t.extensions["vibetrail.kind"] | kind_label)\(if $t.type == "subagent.end" then "（子 agent）" else "" end)\(($t.extensions["vibetrail.split_by"] | split_label) as $sl | if $sl then "<br>依据：" + $sl + (if $t.extensions["vibetrail.permission_mode"] then "（" + $t.extensions["vibetrail.permission_mode"] + "）" else "" end) else "" end) | \($t.payload.decided_by // (if $t.extensions["vibetrail.human"] then "user" else "–" end)) | \(if ($calls | length) > 0 then ([$calls[] | call_s] | join("<br>")) elif $t.payload.tool_name then ($t.payload.tool_name | cell) else "–" end) | \(($t.payload.reason // $t.payload.status.detail // "") | clip(80) | cell) | \(($reply.payload.text // "") | clip(80) | cell) | \(if ($after | length) > 0 then ([$after[] | (.payload.text | clip(80) | cell)] | join("<br>")) else "–" end) |"),
    "" end),
  "## 三、commit ↔ 会话",
  "",
  "来源：每轮开始与结束时的 HEAD，加上这一轮 reflog 里新建的提交（DESIGN §3.5），挂在 `turn.end` 的 `commits` 上；不靠 commit trailer。",
  "归因「agent 自己提交」＝这一轮 transcript 里 agent 用 Bash 跑过 `git commit`；「推断」＝这段时间里出现的提交，可能是人在别的终端提的。提交说明是生成报告时从本机 git 查的。",
  "",
  (if ($commit_turns | length) == 0 then "这段时间内没有观察到哪一轮新增了 commit。", "" else
    "| commit | 提交说明 | 会话 id | 轮 | 这一轮结束 | 归因 | 怎么推出来的 |",
    "|---|---|---|---|---|---|---|",
    ($commit_turns | sort_by(.occurred_at)[] | . as $t | .commits[]
      | "| `\(.sha | sha7)` | \(($subjects[.sha] // "（本机查不到）") | clip(60) | cell) | `\($t.session_id)` | `\($t.turn_id | short)` | \($t.occurred_at | lt("%m-%d %H:%M:%S")) | \(if $t.extensions["vibetrail.commit_attribution"] == "agent_tool" then "agent 自己提交" else "推断" end) | \(if $t.extensions["vibetrail.commit_method"] == "reflog" then "reflog" else "HEAD 起..止" end) |"),
    "" end)
  ]
| .[]
