# vibetrail 演示与测试用（上线用不到，用户 09-15）：把本机 spool 里的协议事件整理成一份 markdown 报告，三类分开展示：
#   一、每一轮的元数据（turn.start / turn.end，外加会话、子 agent、事件头）
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
def kind_label: {permission_denied: "人拒绝", classifier_blocked: "分类器拦截", permission_infra_fail: "权限链路故障", interrupt: "人打断", interrupt_for_tool_use: "人打断（拒绝时）"}[.] // .;
def vcs_s: if type == "object" then "\(.head_sha | sha7)\(if .dirty == true then "*" else "" end)" else "–" end;
def call_s: (.payload.tool_name // "?") + " " + ((.payload.input | if type == "object" then (.command // .file_path // .pattern // .url // tojson) else tojson end) | clip(90) | code);
# 同一轮有多条 turn.end（被别的 Stop hook 拦下后又 Stop 一次）取 vibetrail.stops 最大的那条（DESIGN D7）
def latest_end: max_by(.extensions["vibetrail.stops"] // 0);
def is_trigger: .type == "permission.decision" or ((.type == "turn.end" or .type == "subagent.end") and .provenance.rule_version == "diverge-v1");

map(select(type == "object")) as $ev
| ($ev | group_by(.session_id) | map({sid: .[0].session_id, project: .[0].project_id, events: ., first: (map(.occurred_at) | min)}) | sort_by(.first)) as $sessions
| ($ev | map(select(is_trigger))) as $triggers
| ($ev | map(select(.type == "turn.end")) | group_by([.session_id, .turn_id]) | map(latest_end) | map(select((.commits // []) | length > 0))) as $commit_turns
| [
  "# vibetrail 采集报告",
  "",
  "生成于 \($generated) · 数据来自 `\($source)`，\($chunks) 块、\($ev | length) 条事件 · 只在本机，还没有 push",
  "",
  "| 会话 | 项目 | 开始 | 轮数 | 人机分歧 | commit |",
  "|---|---|---|---|---|---|",
  ($sessions[] | . as $s
    | "| `\($s.sid | short)` | \($s.project | cell) | \($s.first | lt("%m-%d %H:%M")) | \([$s.events[] | select(.type == "turn.start" or .type == "turn.end") | .turn_id] | unique | length) | \([$triggers[] | select(.session_id == $s.sid)] | length) | \([$commit_turns[] | select(.session_id == $s.sid) | .commits[]] | length) |"),
  "",
  "## 一、每一轮的元数据",
  "",
  "来源：`turn.start`（说一句话时 hook 当场记，transcript 补位）与 `turn.end`（模型答完时关轮），不含对话正文。HEAD 后面带 `*` 表示工作区当时有未提交的改动。",
  "",
  ($sessions[] | . as $s
    | ($s.events | map(select(.type == "turn.start")) | group_by(.turn_id) | map(sort_by(if .provenance.kind == "hook" then 0 else 1 end) | .[0])) as $starts
    | ($s.events | map(select(.type == "turn.end")) | group_by(.turn_id) | map(latest_end)) as $ends
    | ([$starts[].turn_id, $ends[].turn_id] | unique) as $ids
    | ($ids | map(. as $id | {id: $id, s: ([$starts[] | select(.turn_id == $id)][0]), e: ([$ends[] | select(.turn_id == $id)][0])})
           | sort_by(.s.occurred_at // .e.occurred_at)) as $turns
    | ($s.events | map(select(.agent.version != null)) | .[0].agent // {}) as $agent
    | "### 会话 `\($s.sid | short)` · \($s.project | cell) · Claude Code \($agent.version // "?")\(if $agent.surface then "（" + $agent.surface + "）" else "" end)",
      "",
      "| # | 轮 | 开始 | 结束 | 用时 | 状态 | 依据 · 何时关 | 模型 | tokens 入 / 缓存 / 出 | HEAD 起 → 止 | 分歧 | commit |",
      "|---|---|---|---|---|---|---|---|---|---|---|---|",
      ($turns | to_entries[] | .key as $i | .value as $t
        | ($t.e.payload.usage // {}) as $u
        | "| \($i + 1) | `\($t.id | short)` | \($t.s.occurred_at | lt("%H:%M:%S")) | \($t.e.occurred_at | lt("%H:%M:%S")) | \(dur($t.s.occurred_at; $t.e.occurred_at)) | \(if $t.e then ($t.e.payload.status.code | status_label) else "进行中" end) | \(if $t.e then (($t.e.extensions["vibetrail.end_evidence"] | evidence_label) + " · " + ($t.e.extensions["vibetrail.closed_by"] | closed_label)) else "–" end) | \($t.e.payload.model // $t.s.payload.model // "–") | \($u.input_tokens | k) / \($u.cached_input_tokens | k) / \($u.output_tokens | k) | \($t.s.payload.vcs | vcs_s) → \($t.e.payload.vcs | vcs_s) | \([$triggers[] | select(.session_id == $s.sid and .turn_id == $t.id)] | length) | \(($t.e.commits // []) | length) |"),
      "",
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
  "注意：用户按停止打断正在跑的工具时，Claude Code 写进 transcript 的与拒绝一模一样，现在会显示成「人拒绝」（OPEN-ISSUES K7）。",
  "",
  (if ($triggers | length) == 0 then "这段时间内没有人机分歧。", "" else
    "| # | 时间 | 会话 · 轮 | 类型 | 谁决定 | 对哪次调用 | 原文 | 被打断的回复 | 之后人说 |",
    "|---|---|---|---|---|---|---|---|---|",
    ($triggers | sort_by(.occurred_at) | to_entries[] | .key as $i | .value as $t
      | ($t.provenance.source_event_id // "") as $tid
      | ([$ev[] | select(.session_id == $t.session_id and .type == "tool.request" and .extensions["vibetrail.trigger"] == $tid)]) as $calls
      | ([$ev[] | select(.session_id == $t.session_id and .type == "message.assistant" and .extensions["vibetrail.trigger"] == $tid)][0]) as $reply
      | ([$ev[] | select(.session_id == $t.session_id and .type == "message.user" and ((.extensions["vibetrail.after"] // []) | index($tid)))] | sort_by(.occurred_at)) as $after
      | "| \($i + 1) | \($t.occurred_at | lt("%m-%d %H:%M:%S")) | `\($t.session_id | short)` · `\($t.turn_id | short)` | \($t.extensions["vibetrail.kind"] | kind_label)\(if $t.type == "subagent.end" then "（子 agent）" else "" end) | \($t.payload.decided_by // (if $t.extensions["vibetrail.human"] then "user" else "–" end)) | \(if ($calls | length) > 0 then ([$calls[] | call_s] | join("<br>")) elif $t.payload.tool_name then ($t.payload.tool_name | cell) else "–" end) | \(($t.payload.reason // $t.payload.status.detail // "") | clip(80) | cell) | \(($reply.payload.text // "") | clip(80) | cell) | \(if ($after | length) > 0 then ([$after[] | (.payload.text | clip(80) | cell)] | join("<br>")) else "–" end) |"),
    "" end),
  "## 三、commit ↔ 会话",
  "",
  "来源：每轮开始与结束时的 HEAD，加上这一轮 reflog 里新建的提交（DESIGN §3.5），挂在 `turn.end` 的 `commits` 上；不靠 commit trailer。",
  "归因「agent 自己提交」＝这一轮 transcript 里 agent 用 Bash 跑过 `git commit`；「推断」＝这段时间里出现的提交，可能是人在别的终端提的。提交说明是生成报告时从本机 git 查的。",
  "",
  (if ($commit_turns | length) == 0 then "这段时间内没有观察到哪一轮新增了 commit。", "" else
    "| commit | 提交说明 | 会话 | 轮 | 这一轮结束 | 归因 | 怎么推出来的 |",
    "|---|---|---|---|---|---|---|",
    ($commit_turns | sort_by(.occurred_at)[] | . as $t | .commits[]
      | "| `\(.sha | sha7)` | \(($subjects[.sha] // "（本机查不到）") | clip(60) | cell) | `\($t.session_id | short)` | `\($t.turn_id | short)` | \($t.occurred_at | lt("%m-%d %H:%M:%S")) | \(if $t.extensions["vibetrail.commit_attribution"] == "agent_tool" then "agent 自己提交" else "推断" end) | \(if $t.extensions["vibetrail.commit_method"] == "reflog" then "reflog" else "HEAD 起..止" end) |"),
    "" end)
  ]
| .[]
