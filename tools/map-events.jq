# vibetrail：把一份 transcript（主会话或子 agent 文件）的记录流映射成 paas-coding-hook 协议 1.0 事件
# ——分歧一路（DESIGN §4.1 / §4.2）。判据 include 自 diverge-rules.jq，本文件只做映射。
#
# 用法（由 vibetrail-map 调）：
#   jq -n -c -L tools --arg sid … --arg project_id … --arg workspace_id … --argjson from_line N \
#         --argjson meta <子 agent 的 meta.json 或 null> --arg vt_version … --arg rule_version diverge-v1 \
#         -f map-events.jq < transcript.jsonl
# 输出：每行一个协议事件（event_id 为 null、多一个 _key，由 vibetrail-map 算 UUIDv5 后填上并删掉 _key），
#      最后一行 {"_ledger": …} 账本（进出条数、反查方式、跳过的记录）。
#
# 增量：整个文件从头读一遍（索引 tool_use、parentUuid 链、当前轮），但只对**触发记录行号 > $from_line**
#      的分歧发事件。派生事件（被拒调用的 tool.request、被打断的回复、打断后的人话）跟着触发记录走，
#      所以「先扫到一半、再扫全文」发出的事件集合与一次扫全文完全相同（test-map.sh 逐个切点钉着）。
#
# 状态都有上界：tool_use 索引 500 条、记录链 400 条——分歧引用的永远是最近几条记录。
# 铁律见 diverge-rules.jq 头部；本文件同样只读字段，任何多态字段先判 type。

include "diverge-rules";

def opt($k; $v): if $v == null then {} else {($k): $v} end;
def codeOk: type == "string" and test("^[a-z][a-z0-9]*([._-][a-z0-9]+)*$");
def clean: with_entries(select(.value != null));

# ---------- 记录的精简形态（进链、进索引的就是它） ----------
# text：user / assistant 记录的正文——只取 text 块（不含 thinking / tool_result），去掉 <system-reminder> 块
def textOf:
  (msg.content) as $c
  | if ($c | type) == "string" then $c
    elif ($c | type) == "array"
    then [$c[]? | objects | select(.type == "text") | (.text // "") | strings
          | select((sub("^\\s+"; "") | startswith("<system-reminder>")) | not)] | join("\n")
    else "" end;
def toolUses:
  if (msg.content | type) == "array"
  then [msg.content[]? | objects | select(.type == "tool_use") | {id: (.id // null), name: (.name // null), input: (.input // null)}]
  else [] end;
# 「人的一句话」：主会话里非注入的 user 文本记录。注入型（system-reminder、local-command-*、command-name、
# task-notification、bash-*）与 isMeta / isCompactSummary 都不算；子 agent 文件里的 user 记录是父 agent 派活，也不算。
def injectedText: sub("^\\s+"; "") | test("^<(system-reminder|local-command-[a-z]+|command-[a-z]+|task-notification|bash-[a-z]+)");
def isHumanPrompt:
  .type == "user" and (.isSidechain != true) and (.isMeta != true) and (.isCompactSummary != true)
  and (.agentId == null)
  and ((msg.content | type) == "string"
       or ((msg.content | type) == "array" and (any(msg.content[]? | objects; .type == "tool_result") | not)))
  and (textOf | length > 0 and (isInterruptText | not) and (injectedText | not));
def slim($ln): {
  uuid, parentUuid: (.parentUuid // null), type, ln: $ln,
  ts: (.timestamp // null), promptId: (.promptId // null),
  text: (if .type == "assistant" or .type == "user" then textOf else "" end),
  tools: (if .type == "assistant" then toolUses else [] end),
  human: isHumanPrompt,
  mid: (msg.id // null), model: (msg.model // null),
  usage: (if (msg.usage | type) == "object" then msg.usage else null end),
  agent: (.agentId // null)
};

# ---------- 状态 ----------
def init: {
  ln: 0, turn: null, turn_line: 0,
  tools: {}, tool_order: [],
  chain: {}, chain_order: [],
  turn_usage: {}, turn_model: null,
  seen: {},               # 已派生事件的 _key（去重）
  denials: [],            # 当前轮里 permission_denied 记录的 uuid，给 for-tool-use 配对
  pending: null,          # {after: [uuid…], kind}：等「人的下一句」
  last_ts: null, version: null, entrypoint: null, branch: null,
  ledger: {in: {}, in_total: {}, out: {}, events: {}, absorbed_for_tool_use: 0, unpaired_for_tool_use: 0,
           lookup: {index: 0, regex: 0, missing: 0}, dedup: 0, records: 0, skipped_no_uuid: 0, skipped_non_object: 0},
  out: []
};

def index($s):
  reduce $s.tools[] as $t (.;
    if $t.id == null then . else
      .tools[$t.id] = {name: $t.name, input: $t.input, uuid: $s.uuid, ts: $s.ts, ln: $s.ln} | .tool_order += [$t.id] end)
  | (if (.tool_order | length) > 500 then .tool_order[0] as $o | del(.tools[$o]) | .tool_order = .tool_order[1:] else . end)
  | .chain[$s.uuid] = ($s | del(.tools) | .tools = [$s.tools[] | {id, name}])
  | .chain_order += [$s.uuid]
  | (if (.chain_order | length) > 400 then .chain_order[0] as $o | del(.chain[$o]) | .chain_order = .chain_order[1:] else . end);

# ---------- 事件骨架 ----------
# 发事件：同一个 _key 只发一次（同一条 tool_use / 回复可能被两次分歧各派生一次，如「拒绝」之后紧接「打断」）。
# 登记不看门控——早于 $from_line 的触发记录已在上一次扫描时发过，这次只登记不发，分段扫与全量扫的集合才一致
def emit($e):
  if .seen[$e._key] then .ledger.dedup += 1 else
    .seen[$e._key] = true
    | if .ln > $from_line then .out += [$e] | .ledger.events[$e.type] += 1 else . end end;

def turnOf($s):        # 轮次 id：记录自带 promptId；没有就按位置推（最近见到的 promptId），provenance 标 inferred
  if $s.promptId != null then {id: $s.promptId, inferred: false}
  elif .turn != null then {id: .turn, inferred: true}
  else {id: $s.uuid, inferred: true} end;

def base($s; $type; $src_uuid; $ts; $t):
  {
    event_id: null,
    occurred_at: ($ts // .last_ts),
    type: $type,
    agent: ({name: "claude-code"} + opt("version"; .version) + (if (.entrypoint | codeOk) then {surface: .entrypoint} else {} end)),
    project_id: $project_id, workspace_id: $workspace_id, session_id: $sid,
    turn_id: $t.id,
    agent_instance_id: ($s.agent // "main"),
    provenance: ({kind: (if $t.inferred then "inferred" else "transcript" end), rule_version: $rule_version} + opt("source_event_id"; $src_uuid)),
    payload: {},
    extensions: ({"vibetrail.version": $vt_version} + opt("vibetrail.branch"; .branch))
  }
  + (if $s.agent != null then {parent_agent_instance_id: "main"} + opt("parent_call_id"; $meta.toolUseId) else {} end);

def toolRequest($s; $t; $cid; $tu; $ext):
  base($s; "tool.request"; $tu.uuid; $tu.ts; $t)
  | .payload = {tool_name: ($tu.name // "unknown"), call_id: $cid, input: $tu.input}
  | .content_state = "included"
  | .extensions += $ext
  | ._key = ($tu.uuid + "|tool.request|" + $cid);

def message($s; $t; $m; $type; $author; $ext):
  base($s; $type; $m.uuid; $m.ts; $t)
  | .payload = ({text: $m.text, author_type: $author, delivery: "direct"} + (if $type == "message.assistant" then opt("model"; $m.model) else {} end))
  | .content_state = "included"
  | .extensions += $ext
  | ._key = ($m.uuid + "|" + $type);

def usageSum:          # 当前轮的 token 用量：同一 message.id 的多条记录 usage 相同，按 id 去重后求和
  [.turn_usage[] | select(type == "object")] as $us
  | if ($us | length) == 0 then null else
    ($us | map((.output_tokens_details | if type == "object" then (.thinking_tokens // 0) else 0 end)) | add) as $think
    | {input_tokens: ($us | map((.input_tokens // 0) + (.cache_creation_input_tokens // 0)) | add),
       cached_input_tokens: ($us | map(.cache_read_input_tokens // 0) | add),
       output_tokens: ($us | map(.output_tokens // 0) | add)}
    | . + (if $think > 0 then {reasoning_tokens: $think} else {} end)
    | .total_tokens = (.input_tokens + .cached_input_tokens + .output_tokens)
    | with_entries(select(.value | type == "number"))
    end;

# ---------- 三类 is_error 分歧 → permission.decision（+ 被拒调用的 tool.request） ----------
def decisions($r; $s; $h):
  ($r | errBlocks | map(select(.text | kindPred($h.kind)))) as $blocks
  | turnOf($s) as $t
  | reduce $blocks[] as $b (.;
      ($b.call_id) as $cid
      | (if $cid != null then .tools[$cid] else null end) as $tu
      | (if $tu != null then {name: ($tu.name // "unknown"), how: "index"}
         elif ($b.text | test("^Permission to use \\S+")) then {name: ($b.text | capture("^Permission to use (?<n>\\S+)").n), how: "regex"}
         else {name: "unknown", how: "missing"} end) as $nm
      | .ledger.lookup[$nm.how] += 1
      | (if $tu != null then emit(toolRequest($s; $t; $cid; $tu; {"vibetrail.trigger": $s.uuid, "vibetrail.kind": $h.kind})) else . end)
      | emit( base($s; "permission.decision"; $s.uuid; $s.ts; $t)
              | .payload = ({permission_id: ($cid // $s.uuid), tool_name: $nm.name,
                             decision: (if $h.kind == "permission_infra_fail" then "error" else "deny" end),
                             decided_by: ({permission_denied: "user", classifier_blocked: "policy", permission_infra_fail: "system"}[$h.kind]),
                             reason: ($b.text | .[0:4096])} + opt("call_id"; $cid))
              | .raw = {event_name: ("diverge." + $h.kind), data: $h}
              | .extensions += {"vibetrail.kind": $h.kind, "vibetrail.human": $h.human, "vibetrail.tool_lookup": $nm.how}
              | ._key = ($s.uuid + "|permission.decision|" + ($cid // "") + "|" + $h.kind) ))
  | (if $h.human then .denials += [$s.uuid] | .pending = {after: ((.pending.after // []) + [$s.uuid]), kind: $h.kind} else . end);

# ---------- 打断 → turn.end(interrupted) / subagent.end(cancelled) + 被打断的回复 ----------
def walkUp($u; $n):    # 沿 parentUuid 回溯到最近的 assistant 记录；碰到人的提示词（轮首）或链断就停
  if $n == 0 or $u == null then null else
    (.chain[$u] // null) as $c
    | if $c == null then null
      elif $c.type == "assistant" then $c
      elif $c.human then null
      else walkUp($c.parentUuid; $n - 1) end end;
def lastAssistantInTurn($s):   # 链断了的兜底：按文件顺序取本轮里最近的 assistant 记录
  . as $st | [.chain_order[] | $st.chain[.] | select(.type == "assistant" and .ln > $st.turn_line and .ln < $s.ln)] | last;

def interrupted($r; $s; $h; $detail):
  turnOf($s) as $t
  | ((walkUp($s.parentUuid; 200)) // lastAssistantInTurn($s)) as $reply
  | (if $reply != null and ($reply.text | length) > 0
     then emit(message($s; $t; $reply; "message.assistant"; "agent"; {"vibetrail.trigger": $s.uuid, "vibetrail.kind": $h.kind}))
     else . end)
  | (if $reply != null
     then reduce $reply.tools[] as $tl (.; (if $tl.id != null then .tools[$tl.id] else null end) as $tu
            | if $tu != null then emit(toolRequest($s; $t; $tl.id; $tu; {"vibetrail.trigger": $s.uuid, "vibetrail.kind": $h.kind})) else . end)
     else . end)
  | ($s.agent != null) as $sub
  # ⚠️ emit(base(…) | …) 里管道之后的 . 是事件、不是状态：状态里的值必须先绑成变量再用
  | ($reply.model // .turn_model) as $model | usageSum as $usage | .branch as $branch
  | emit( base($s; (if $sub then "subagent.end" else "turn.end" end); $s.uuid; $s.ts; $t)
          | .payload = ({status: {code: (if $sub then "cancelled" else "interrupted" end), category: "cancellation", detail: ($detail | .[0:4096])}}
                        + (if $sub then opt("agent_type"; $meta.agentType)
                           else opt("model"; $model) + opt("usage"; $usage)
                                + (if $branch != null then {vcs: {branch: $branch}} else {} end) end))
          | .raw = {event_name: ("diverge." + $h.kind), data: $h}
          | .extensions += ({"vibetrail.kind": $h.kind, "vibetrail.human": true} + opt("vibetrail.interrupted_uuid"; $reply.uuid))
          | ._key = ($s.uuid + "|" + .type) )
  | .pending = {after: ((.pending.after // []) + [$s.uuid]), kind: $h.kind};

# for-tool-use 变体：同一轮里前面有 permission_denied 就是它的伴随记录，不另发事件（计一次）；
# 没有配对的（语料里未见）按打断处理，不丢事件
def forToolUse($r; $s; $h):
  if (.denials | length) > 0
  then .ledger.absorbed_for_tool_use += 1 | .pending = {after: ((.pending.after // []) + [$s.uuid]), kind: "interrupt_for_tool_use"}
  else .ledger.unpaired_for_tool_use += 1 | interrupted($r; $s; $h; "unpaired interrupt_for_tool_use: " + $s.text) end;

def handle($r; $s; $h):
  (if .ln > $from_line then .ledger.in[$h.kind] += 1 else . end) | .ledger.in_total[$h.kind] += 1
  | (if $h.kind == "interrupt" then interrupted($r; $s; $h; $s.text)
     elif $h.kind == "interrupt_for_tool_use" then forToolUse($r; $s; $h)
     else decisions($r; $s; $h) end)
  | (if .ln > $from_line then .ledger.out[$h.kind] += 1 else . end);

# 分歧之后人的下一句 → message.user，extensions 指回触发它的记录
def emitAfter($s):
  .pending as $p
  | emit(message($s; turnOf($s); $s; "message.user"; "user"; {"vibetrail.after": $p.after, "vibetrail.after_kind": $p.kind}))
  | .pending = null;

def step($r):
  .out = [] | .ln += 1
  | if ($r | type) != "object" then .ledger.skipped_non_object += 1
    elif ($r.uuid | type) != "string" then .ledger.skipped_no_uuid += 1
    else
      .ledger.records += 1
      | .last_ts = ($r.timestamp // .last_ts) | .version = ($r.version // .version)
      | .entrypoint = ($r.entrypoint // .entrypoint) | .branch = ($r.gitBranch // .branch)
      | (if ($r.promptId | type) == "string" and $r.promptId != .turn then .turn = $r.promptId | .denials = [] else . end)
      | ($r | slim(.ln)) as $s
      | index($s)
      | (if $s.human then .turn_usage = {} | .turn_model = null | .turn_line = $s.ln else . end)
      | (if $s.type == "assistant" and $s.usage != null then .turn_usage[($s.mid // $s.uuid)] = $s.usage | .turn_model = ($s.model // .turn_model) else . end)
      | reduce ($r | diverge) as $h (.; handle($r; $s; $h))
      | (if $s.human and .pending != null then emitAfter($s) else . end)
    end;

foreach (inputs, {"__vibetrail_eof__": true}) as $r (init;
  if $r == {"__vibetrail_eof__": true} then . else step($r) end;
  if $r == {"__vibetrail_eof__": true} then {"_ledger": (.ledger + {from_line: $from_line, lines: .ln})} else .out[] end)
