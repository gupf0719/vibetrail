# vibetrail：把一份 transcript（主会话或子 agent 文件）的记录流映射成 paas-coding-hook 协议 1.0 事件
# ——分歧一路（DESIGN §4.1 / §4.2）。判据 include 自 diverge-rules.jq，本文件只做映射。
#
# 用法（由 vibetrail-map 调）：
#   jq -n -c -L tools --arg sid … --arg project_id … --arg workspace_id … --arg parent_instance main \
#         --argjson start_line S --argjson from_line N --argjson meta <子 agent 的 meta.json 或 null> \
#         --slurpfile seen_uuids <前几次记下的 [uuid, 行号] 数组> --slurpfile hook_turns <hook 记的轮次证据> \
#         --argjson turns <true|false> --arg close_last <""|stop|session_end|resume|idle> --arg stop_turn <Stop 的 prompt_id> \
#         --arg vt_version … --arg rule_version diverge-v1 -f map-events.jq < 从第 S 行起的 transcript
# 输出：每行一个协议事件（event_id 为 null、多一个 _key，由 vibetrail-map 算 UUIDv5 后填上并删掉 _key），
#      最后一行 {"_ledger": …} 账本（进出条数、反查方式、跳过的记录、下次的起读行 checkpoint_line）。
#
# 增量（U11，DESIGN §4.2）：从 $start_line 读起（上次账本给的 checkpoint_line＝本轮开头），行号保持绝对值；
#      只对**触发记录行号 > $from_line** 的分歧发事件。映射要回看的东西都在同一轮里（被拒的 tool_use、
#      被打断的回复、本轮用量、拒绝配对），所以从本轮开头读与从文件头读发出的事件相同（test-map.sh 逐个切点钉着）。
#      派生事件（被拒调用的 tool.request、被打断的回复、之后人的下一句）跟着触发记录走。
#
# 状态都有上界：tool_use 索引 500 条、记录链 400 条——分歧引用的永远是最近几条记录。
# 铁律见 diverge-rules.jq 头部；本文件同样只读字段，任何多态字段先判 type。
# 回放副本（09-15 语料 43 个主会话里 4 个有）：Claude Code 会把旧记录原样再追加进同一个文件，uuid、时间戳不变，
#      只把 promptId 改成回放时那一轮的（常常是还没出现人话的下一轮）；压缩上下文时也会把早先一条并行工具的结果这样再写一遍（09-15 本机）。
#      副本不上报（用户 09-15）。所有带 uuid 的记录都查，副本整条跳过——不触发、不结束等待、不开轮、不算用量、不出 trace：
#        · 本次读取里同一 uuid 已经出现过；
#        · uuid 在 $seen_uuids 里、但行号对不上（前几次记下的 [uuid, 行号]）。行号对得上的是从 checkpoint 起的正常重读。
#      以前只查触发记录与人话记录（其余不产生事件）；09-15 加了轮次与 trace，assistant、工具结果的副本会凭空开出一轮、重复算用量、
#      把正在累计的调用提前结束，改成全查（teamai、Pilot 两份核对都这么建议）。代价：首次整读 65 MB 4.9 s → 7.1 s、本机最大的 9 MB 0.61 → 0.65 s；
#      增量读时 $seen_uuids 1.5 万条多 0.06 s。
#      不用「时间戳倒退」判：真实触发记录 405 条从不倒退，但真实 user 记录有 63 条倒退超过一分钟（09-15 语料），会误伤。
#      Pilot / teamai 都不按 uuid 去重（09-15 两份核对）：Pilot 只给同一次读到调用的结果发 tool.result，teamai 的打断 / 拒绝 / 出错 / 人话计数会重复算。
# ⚠️ jq 的函数参数在调用处的输入上求值：`$r | slim(.ln)` 里的 .ln 是 $r.ln（null），不是状态的行号。
#    状态里的值一律先 `as $x` 绑定再往下传（这里曾让所有记录的行号都是 null，断链兜底从未生效）。
#
# 轮次元数据（DESIGN §3.1、§4.1，09-15 加；与分歧同一条事件流，$turns 默认 true，只有分歧判据的回归传 false）：
#      主会话文件按 promptId 切轮——hook 的 prompt_id 与记录的 promptId 是同一个值
#      （09-15 本机探针实测），轮中插话不换 promptId。每轮开头发 turn.start（hook 已经发过的同 event_id 在写 spool 前被拦下，
#      这里是 hook 没跑时的补位）。**turn.end 在模型答完的那一刻发**（DESIGN D7，09-15 按用户意见改）：Stop hook 解析时带 $close_last = stop
#      与 $stop_turn = 这次 Stop 的 prompt_id，读到文件末尾就把这一轮关掉——Claude Code 自己的答完标记 system/stop_hook_summary 虽然也有，
#      但 desktop 要等下一句人话进来才把它写进文件（09-15 本机三个版本、全部会话核过），等它就晚一轮。别的 Stop hook 拦停时同一轮会再来一次 Stop：
#      那次再发一条 turn.end，_key 带 |stopN（event_id 不同），commits 与用量都从本轮开头累计，同一 turn_id 取 vibetrail.stops 最大的那条。
#      拦停反馈（attachment hook_blocking_error、hook_additional_context，或 isMeta 的「Stop hook feedback:」人话）已经落盘时，这次 Stop 不关。
#      之后重读到 summary、它前面没有拦停反馈时也会关（closed_by = summary，与 Stop 时发的同一个 event_id，被 hook 按 id 拦下）。
#      拒绝后停下的轮在 for-tool-use 打断记录处关（denied）；被打断的轮由分歧一路发 turn.end(interrupted)。没有这些标记时退到兜底：
#      下一轮开始、或 $close_last（会话结束 / 恢复 / 空闲）。只跑了本地命令（/model 之类，没有模型回复）的轮不在 Stop 时关。
#      status：summary 或 hook 记到的 Stop 是 completed；summary 里 preventedContinuation 是 hook_stopped；只有 StopFailure 是 error；
#      什么证据都没有是 unknown。vcs / commits 来自 $hook_turns（Stop 时 hook 按轮起 HEAD 算好的，DESIGN §3.5）；
#      用量是本轮 assistant 记录按 message.id 去重求和（与打断同一定义）。子 agent 文件不切轮：子 agent 的起止由 SubagentStart / SubagentStop hook 发。
#
# trace（rule_version call-v1；09-15 用户要，照 Pilot 的粒度、不带正文，DESIGN D8）：每次模型调用一条 message.assistant（content_state = omitted，extensions.vibetrail.call
#      带 response_id、request_id、stop_reason、这次调用的 token、请求开始时间、调了哪些工具、有没有 thinking），在这次调用结束时发——另一个 message.id
#      出现（工具结果可能夹在同一次调用中间，不算结束），或者带 $close_last 读到文件末尾；每个工具结果一条 tool.end（工具名、call_id、success / error / cancelled、耗时）。
#      执行前就被拒的调用只有 permission.decision，不伪造 tool.end（协议）；按停止打断正在跑的工具写成与拒绝一样的记录，也归到这里（K7）。
#      Pilot 每次调用各有请求 / 响应两条、工具各有调用 / 结果两条，且带全文；我们一次调用一条、只有元数据。

include "diverge-rules";

def opt($k; $v): if $v == null then {} else {($k): $v} end;
# ISO 时间 → 毫秒（trace 的耗时、K7 的权限框时间窗）
def epochms: if type != "string" then null else
  (capture("^(?<b>[^.Z]+)(?<f>\\.[0-9]+)?Z$")? // null) as $m
  | if $m == null then null else ((($m.b + "Z") | fromdateiso8601) * 1000 + (("0" + ($m.f // ".0")) | tonumber * 1000 | floor)) end end;
def codeOk: type == "string" and test("^[a-z][a-z0-9]*([._-][a-z0-9]+)*$");

# ---------- 记录的精简形态（进链、进索引的就是它） ----------
# text：user / assistant 记录的正文——只取 text 块（不含 thinking / tool_result），去掉 <system-reminder> 块；
# IDE 扩展注入的 <ide_opened_file> / <ide_selection> 之类标签常和人打的字混在同一条消息里，只剥标签、不整条排除（照 agentsview，09-15 调研）
def stripIde: gsub("<ide_[a-z_]+>.*?</ide_[a-z_]+>"; ""; "m") | sub("^\\s+"; "") | sub("\\s+$"; "");
# 完整的 system-reminder 块只剥块、不整条排除：desktop 把它和人打的字塞进同一个字符串——worktree 会话的第一句人话就是
# "<system-reminder>…</system-reminder>\n\npull main"（09-15 本机实测），原先整条当注入，这一轮的开头就认不出来
def stripReminders: gsub("<system-reminder>.*?</system-reminder>"; ""; "m");
def textOf:
  (msg.content) as $c
  | if ($c | type) == "string" then ($c | stripReminders | stripIde)
    elif ($c | type) == "array"
    then [$c[]? | objects | select(.type == "text") | (.text // "") | strings | stripReminders
          | select((sub("^\\s+"; "") | (startswith("<system-reminder>") or startswith("<ide_"))) | not)
          | stripIde | select(length > 0)] | join("\n")
    else "" end;
def toolUses:
  if (msg.content | type) == "array"
  then [msg.content[]? | objects | select(.type == "tool_use") | {id: (.id // null), name: (.name // null), input: (.input // null)}]
  else [] end;
def mainUser:          # 主会话里人发出的 user 记录的公共条件：子 agent 文件里的 user 记录是父 agent 派活，不算
  .type == "user" and (.isSidechain != true) and (.isMeta != true) and (.isCompactSummary != true) and (.agentId == null)
  and ((msg.content | type) == "string"
       or ((msg.content | type) == "array" and (any(msg.content[]? | objects; .type == "tool_result") | not)));
# 「人的一句话」：注入型（system-reminder、local-command-*、command-*、task-notification、bash-*）都不算；
# 另有两类纯文本注入（照 agentsview 的排除清单，09-15 调研）：Stop hook 拦停时回灌的「Stop hook feedback:」、压缩后续接的「This session is being continued」摘要
def injectedText: sub("^\\s+"; "")
  | test("^<(system-reminder|local-command-[a-z]+|command-[a-z]+|task-notification|bash-[a-z]+)")
    or startswith("Stop hook feedback") or startswith("This session is being continued");
# 2.1.26x 的人话记录带 origin.kind（human / task-notification）：有就以它为准，没有（老版本、斜杠命令、本地命令输出、压缩摘要、打断标记）走文本排除清单（U15）
def isHumanPrompt: mainUser and (textOf | length > 0 and (isInterruptText | not))
  and ((.origin | if type == "object" then .kind else null end) as $k
       | if ($k | type) == "string" then $k == "human" else (textOf | injectedText | not) end);
# 人在模型干活时插的话（desktop 排队消息）：attachment / queued_command，commandMode = prompt、origin 是人。不开轮、不带正文，只在 turn.end 上计数（K10）
def isQueuedHuman($r): $r.type == "attachment" and ($r.attachment | type) == "object" and $r.attachment.type == "queued_command"
  and (($r.attachment.commandMode // "prompt") == "prompt")
  and ((($r.attachment.origin | if type == "object" then .kind else null end) // "human") == "human");
# 斜杠命令是人敲的（Pilot 也把 <command-name> 当人的动作，transcript-parser.mjs:34），不是注入。
# 规范成 "/model claude-opus-5" 这样的一句；/model、/compact 常在分歧之后出现（09-15 语料 17 / 272）
def slashText:
  (textOf) as $t
  | ($t | capture("<command-name>\\s*(?<n>[^<]*?)\\s*</command-name>")? // null) as $n
  | if $n == null then null else
      ((($t | capture("<command-args>(?<a>[^<]*)</command-args>")?) // {}) | (.a // "") | sub("^\\s+"; "") | sub("\\s+$"; "")) as $a
      | ($n.n | if startswith("/") then . else "/" + . end) + (if $a == "" then "" else " " + $a end) end;
def isSlashCommand: mainUser and (textOf | sub("^\\s+"; "") | startswith("<command-name>"));
def slim($ln): (isSlashCommand) as $slash | {
  uuid, parentUuid: (.parentUuid // null), type, ln: $ln,
  ts: (.timestamp // null), promptId: (.promptId // null),
  text: (if $slash then (slashText // textOf) elif .type == "assistant" or .type == "user" then textOf else "" end),
  tools: (if .type == "assistant" then toolUses else [] end),
  human: isHumanPrompt, slash: $slash,
  # 合成记录（model "<synthetic>"：No response requested.、额度用尽、API 报错）不是模型回复，不当被打断的回复、不计用量
  # （Pilot 同样跳过，transcript-parser.mjs:71）
  synthetic: (.type == "assistant" and msg.model == "<synthetic>"),
  mid: (msg.id // null), rid: (.requestId // null), model: (msg.model // null),
  usage: (if (msg.usage | type) == "object" then msg.usage else null end),
  agent: (.agentId // null)
};

# ---------- 状态 ----------
def init: {
  ln: ($start_line - 1), turn: null, turn_line: 0,
  run_uuids: {},          # 本次读取见过的记录 uuid（同一次读取内的副本）
  prior: (($seen_uuids[0] // []) | map({(.[0]): .[1]}) | add // {}),   # 前几次记下的 uuid → 行号（跨次的副本）
  tools: {}, tool_order: [],
  chain: {}, chain_order: [],
  turn_usage: {}, turn_model: null,
  seen: {},               # 已派生事件的 _key（去重）
  denials: [],            # 当前轮里 permission_denied 记录的 uuid，给 for-tool-use 配对
  stops: [],              # 当前轮里判成「按停止打断正在跑的工具」的那几条 user-rejected（K7）：{uuid, call_id, by, mode}
  perm_mode: null,        # 最近一条人话记录的 permissionMode（K7 粗分用）
  pending: null,          # {after: [uuid…], kind, since}：等「人的下一句」；since＝第一个触发所在轮的开头行
  pturn: null,            # 按 promptId 切的当前轮（轮次元数据一路）：{id, line, last_ts, usage, model, interrupted, denied, git_commit, closed}
  call: null,             # trace：正在累计的这次模型调用（同一 message.id 的几条记录）
  calls_seen: [],         # trace：最近 200 次调用的 {mid, turn, started_at, first_ts}——api_error 按时间挂回它那次调用
  prev_end_ts: null,      # trace：下一次模型调用的请求开始＝最近一条 user 记录与上一次模型调用结尾里晚的那个（Pilot 只看工具结果，
                          #   连着几次调用之间没有工具结果时——如连续撞 max_tokens——会一直停在最早那条上，耗时越算越长）
  last_ts: null, version: null, entrypoint: null, branch: null,
  ledger: {in: {}, in_total: {}, out: {}, events: {}, absorbed_for_tool_use: 0, unpaired_for_tool_use: 0,
           lookup: {index: 0, regex: 0, missing: 0}, stop_press: 0, dedup: 0, records: 0, skipped_no_uuid: 0, skipped_non_object: 0,
           # G6 哨兵：被拒记录的 toolUseResult 是 "User rejected tool use"，与正文判据是两个独立字段（09-15 语料逐条吻合）。
           # marker_without_hit > 0 ＝ 有这个标记、判据却没认出人拒——判据漂了
           sentinel: {marker: 0, marker_without_hit: 0},
           replayed: 0,       # 跳过的回放副本条数
           turns: {started: 0, ended: {}},   # 轮次元数据一路：本次新开的轮、按 status.code 数的关轮
           sources: []},      # 本次新读到的记录的 [uuid, 行号]——交给下一次当 $seen_uuids
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
def emitAlways($e):    # 不看门控：文件末尾关轮（$close_last）时用，上一次可能已经读到了末尾；重复的由 hook 按 event_id 拦下
  if .seen[$e._key] then .ledger.dedup += 1 else .seen[$e._key] = true | .out += [$e] | .ledger.events[$e.type] += 1 end;

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
  # 父实例：一级子 agent 是 main；被子 agent 派出的（meta.spawnDepth ≥ 2）是派它的那个子 agent，由 vibetrail-map 查兄弟文件得出
  + (if $s.agent != null then {parent_agent_instance_id: $parent_instance} + opt("parent_call_id"; $meta.toolUseId) else {} end);

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

def usageOf($m):       # 一轮的 token 用量：同一 message.id 的多条记录 usage 相同，按 id 去重后求和
  [$m[] | select(type == "object")] as $us
  | if ($us | length) == 0 then null else
    ($us | map((.output_tokens_details | if type == "object" then (.thinking_tokens // 0) else 0 end)) | add) as $think
    | {input_tokens: ($us | map((.input_tokens // 0) + (.cache_creation_input_tokens // 0)) | add),
       cached_input_tokens: ($us | map(.cache_read_input_tokens // 0) | add),
       output_tokens: ($us | map(.output_tokens // 0) | add)}
    | . + (if $think > 0 then {reasoning_tokens: $think} else {} end)
    | .total_tokens = (.input_tokens + .cached_input_tokens + .output_tokens)
    | with_entries(select(.value | type == "number"))
    end;
def usageSum: usageOf(.turn_usage);

# ---------- 轮次元数据：hook 记的证据（$hook_turns，vibetrail-hook 从 state/<sid>/turns/ 拼的） ----------
def hookTurn($id): (($hook_turns[0] // {}) | if type == "object" then .[$id] else null end) // {};
# 本轮的「止」：本轮开始之后的最后一次 Stop 快照；没有 Stop 就用下一轮开始 / 会话结束时补的那份（gap）
def hookStop($h): if $h.stop != null and (($h.stop.at_epoch // 0) >= ($h.start.at_epoch // 0)) then $h.stop else null end;
def hookEnd($h): hookStop($h) // $h.gap // null;
def vcsMerge($branch; $hv):
  ((if $branch != null then {branch: $branch} else {} end)
   + (if ($hv | type) == "object" then ($hv | {head_sha, branch, dirty} | with_entries(select(.value != null))) else {} end))
  | if length > 0 then . else null end;
def codeify: tostring | ascii_downcase | gsub("[^a-z0-9._-]+"; "_") | gsub("^[^a-z]+"; "") | gsub("[._-]+$"; "")
             | gsub("[._-]{2,}"; "_") | if . == "" then "unknown" else .[0:128] end;
def commitsOf($end): if ($end.commits | type) == "array" and ($end.commits | length) > 0
  then [$end.commits[] | select(type == "string") | {sha: ., relation: "observed", evidence: "before_after"}] else null end;
def mainRec($r): ($r.isSidechain != true) and ($r.agentId == null);

# ---------- 轮次元数据：开轮 / 关轮 / 累计（DESIGN §3.1、§4.1） ----------
def openTurn($s):
  .pturn = {id: $s.promptId, line: $s.ln, last_ts: $s.ts, usage: {}, model: null, answered: false,
            interrupted: false, denied: false, git_commit: false, closed: false, end_turn: false, stop_blocked: false,
            block_pending: false, summary: null, queued: 0}
  | (if $s.ln > $from_line then .ledger.turns.started += 1 else . end)
  | hookTurn($s.promptId) as $h | vcsMerge(.branch; $h.start.vcs) as $vcs
  | emit( base($s; "turn.start"; $s.uuid; $s.ts; {id: $s.promptId, inferred: false})
          | .provenance = {kind: "transcript", rule_version: "turn-v1", source_event_id: $s.uuid}
          | .payload = opt("vcs"; $vcs)
          | ._key = ($s.promptId + "|turn.start") );

def closeTurn($how; $s; $eof):
  if .pturn == null or .pturn.closed or .pturn.interrupted then .
  else
    .pturn as $pt | hookTurn($pt.id) as $h | hookStop($h) as $stop | hookEnd($h) as $end
    | ($eof or .ln > $from_line) as $new
    # 结束的依据按强弱排：stop_hook_summary（Claude Code 自己写的答完标记）> hook 记到的 Stop > 最后一条模型回复 stop_reason 是 end_turn
    # （模型自己说完了，但 Stop hook 的判定没落盘，比如会话紧接着被关掉，09-15 本机语料里见过）
    | (if $how == "stop" and $stop != null then "hook_stop" elif $pt.summary != null then "stop_hook_summary" elif $stop != null then "hook_stop"
     elif $h.fail != null then "stop_failure" elif $pt.end_turn then "end_turn" else "none" end) as $evidence
    | (if $pt.denied then {code: "denied", category: "denial", detail: "turn stopped by a permission denial"}
       elif $pt.summary.prevented == true then {code: "hook_stopped", category: "cancellation", detail: (($pt.summary.reason // "") | .[0:4096])}
       elif $evidence == "stop_hook_summary" or $evidence == "hook_stop" or $evidence == "end_turn" then {code: "completed", category: "success"}
       elif $evidence == "stop_failure" then {code: (($h.fail.error // "error") | codeify), category: "error"}
       else {code: "unknown", category: "unknown"} end) as $status
    | usageOf($pt.usage) as $usage | vcsMerge(.branch; $end.vcs) as $vcs | commitsOf($end) as $commits
    | (base($s; "turn.end"; null; ($pt.summary.ts // $stop.at // $pt.last_ts); {id: $pt.id, inferred: false})
       | .provenance = ({kind: "transcript", rule_version: "turn-v1"}
                        + (if $pt.summary != null or $stop != null then {source_event: "Stop"} else {} end)
                        + opt("source_event_id"; $pt.summary.uuid))
       | .payload = ({status: $status} + opt("model"; $pt.model) + opt("usage"; $usage) + opt("vcs"; $vcs))
       | (if $commits != null
          then .commits = $commits
               | .extensions += {"vibetrail.commit_method": ($end.commit_method // "rev-list"),
                                 "vibetrail.commit_attribution": (if $pt.git_commit then "agent_tool" else "inferred" end)}
          else . end)
       | .extensions += ({"vibetrail.closed_by": $how, "vibetrail.end_evidence": (if $pt.denied then "denial" else $evidence end),
                          "vibetrail.stops": ($stop.stops // 0)} + opt("vibetrail.dirty_files"; $end.vcs.dirty_files)
                         + opt("vibetrail.queued_prompts"; (if ($pt.queued // 0) > 0 then $pt.queued else null end)))
       # 被别的 Stop hook 拦停、同一轮第 N 次 Stop 时发的那条换一个 event_id（|stopN），读的一方同一 turn_id 取 vibetrail.stops 最大的
       | ._key = ($pt.id + "|turn.end" + (if (($stop.stops // 0) > 1) then "|stop" + ($stop.stops | tostring) else "" end))) as $e
    | (if $eof then emitAlways($e) else emit($e) end)
    | (if $new then .ledger.turns.ended[$status.code] += 1 else . end)
    | .pturn.closed = true
  end;

def turnStart: if .turn_line > 0 then .turn_line else $start_line end;
def addPending($uuid; $kind):
  turnStart as $ts
  | .pending = {after: ((.pending.after // []) + [$uuid]), kind: $kind, since: (.pending.since // $ts)};

# ---------- K7：「The user doesn't want to proceed with this tool use」是人拒绝，还是按停止打断了正在跑的工具 ----------
# 按停止时 Claude Code 给还没跑完的工具写的合成结果与在权限框里点拒绝逐字一样（二进制 createSyntheticErrorMessage），后面同样跟
# 「[Request interrupted by user for tool use]」。能分开的只有「这次调用弹没弹过权限框」（用户 09-15 定：先按 permissionMode 粗分，挂上 PermissionRequest）：
#   1. 拒绝的时刻 PermissionRequest 已经挂上（$perm_since 之后）：调用与拒绝之间弹过同名工具的框（前后各放 5 s）是拒绝，没弹过是按停止。
#      按工具名与时间对，不比参数：hook 的 tool_input 与 transcript 里的 input 不保证逐字一样，比参数反而会把真拒绝判成停止
#   2. 没挂上：看这一轮人话记录的 permissionMode——auto / bypassPermissions / dontAsk 几乎不弹框，算按停止；别的仍算拒绝
#   3. 子 agent 文件：toolUseResult 是「User rejected tool use」就是按停止——子 agent 里点拒绝记的是「Error: …」加 userFeedback（2.1.266 二进制，Pilot 核对读出，本机没有样本）
#   4. 都没有（老版本没有 permissionMode）：仍算拒绝
# 「Permission to use … has been denied」是权限流程写的、toolUseResult 以「Error:」开头的带了拒绝理由，都只会是拒绝，不走这里。
# ⚠️ 别用 index/1：本文件自己定义了 index($s)（给记录建索引），会盖掉内建的
def noPromptMode: . as $m | any(("auto", "bypassPermissions", "dontAsk"); . == $m);
def splitStop($s; $tu; $tur):
  ($s.ts | epochms) as $at
  | ((($perm_since | tonumber?) // 0) * 1000) as $since
  | if $since > 0 and $at != null and $at >= $since then
      ((($tu.ts // null) | epochms) // ($at - 600000)) as $from
      | ([($hook_perms[0] // [])[] | objects
          | select(($tu == null or .tool_name == $tu.name) and (.agent_id == null or .agent_id == $s.agent))
          | (.at | epochms) as $pa | select($pa != null and $pa >= $from - 5000 and $pa <= $at + 5000)] | length > 0) as $shown
      | {stop: ($shown | not), by: "permission_request", prompt_shown: $shown, mode: .perm_mode}
    elif $s.agent != null and $tur == "User rejected tool use" then {stop: true, by: "subagent_rejected"}
    elif .perm_mode != null then {stop: (.perm_mode | noPromptMode), by: "permission_mode", mode: .perm_mode}
    else {stop: false, by: "none"} end;

# ---------- 三类 is_error 分歧 → permission.decision（+ 被拒调用的 tool.request） ----------
def decisions($r; $s; $h):
  ($r | errBlocks | map(select(.text | kindPred($h.kind)))) as $blocks
  | turnOf($s) as $t
  | . as $st | ($r.toolUseResult | if type == "string" then . else null end) as $tur
  | [$blocks[] | . as $b | (if $b.call_id != null then $st.tools[$b.call_id] else null end) as $tu
     | {b: $b, tu: $tu,
        cls: (if $h.kind == "permission_denied" and ($b.text | test("^The user doesn't want to proceed with this tool use")) and (($tur // "") | startswith("Error:") | not)
              then ($st | splitStop($s; $tu; $tur)) else null end)}] as $items
  | reduce $items[] as $it (.;
      if $it.cls.stop == true then   # 按停止打断：这里不发，等紧跟的 for-tool-use 记录按打断发（forToolUse）
        .stops += [{uuid: $s.uuid, call_id: $it.b.call_id, by: $it.cls.by, mode: $it.cls.mode}] | .ledger.stop_press += 1
      else
      $it.b as $b | ($b.call_id) as $cid | $it.tu as $tu
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
              | .extensions += ({"vibetrail.kind": $h.kind, "vibetrail.human": $h.human, "vibetrail.tool_lookup": $nm.how}
                                + (if ($it.cls.by // "none") != "none"
                                   then {"vibetrail.split_by": $it.cls.by} + opt("vibetrail.permission_mode"; $it.cls.mode)
                                        + opt("vibetrail.prompt_shown"; $it.cls.prompt_shown)
                                   else {} end))
              | ._key = ($s.uuid + "|permission.decision|" + ($cid // "") + "|" + $h.kind) )
      end)
  | (if $h.human and any($items[]; .cls.stop != true) then .denials += [$s.uuid] | addPending($s.uuid; $h.kind) else . end);

# ---------- 打断 → turn.end(interrupted) / subagent.end(cancelled) + 被打断的回复 ----------
def walkUp($u; $n):    # 沿 parentUuid 回溯到最近的真实 assistant 记录；越过合成记录；碰到人的提示词（轮首）或链断就停
  if $n == 0 or $u == null then null else
    (.chain[$u] // null) as $c
    | if $c == null then null
      elif $c.type == "assistant" and ($c.synthetic | not) then $c
      elif $c.human or $c.slash then null
      else walkUp($c.parentUuid; $n - 1) end end;
def lastAssistantInTurn($s):   # 链断了的兜底：按文件顺序取本轮里最近的真实 assistant 记录
  . as $st | turnStart as $from
  | [.chain_order[] | $st.chain[.] | select(.type == "assistant" and (.synthetic | not) and .ln >= $from and .ln < $s.ln)] | last;

# 同一条模型回复会拆成几条记录（thinking / text / tool_use 各一条，共用 message.id；09-15 语料 24048 条回复七成拆成 ≥2 条）。
# 离打断最近的那条常是 tool_use，只取它会丢掉回复的文字——把本轮里同一 message.id、不晚于它的记录拼起来，工具调用合在一起。
# 文字不能简单接：有 ≥2 段文字的 212 条里 210 条是逐步变长的快照（后一段以前一段开头），只有 2 条是互不包含的几段。
# 所以快照换成长的、互不包含的才接起来。Pilot 只留最长一段（丢那 2 条的短段），teamai 只取最后一条带文字的记录（同样丢，还只看末尾 10 KB）
# ⚠️ `$x | startswith(.[-1])` 里的 .[-1] 在 $x 上求值（同 slim(.ln) 的坑），先把末项绑成变量
def mergeTexts: reduce (.[] | select(length > 0)) as $x ([];
  if length == 0 then [$x]
  else .[-1] as $last
    | if ($x | startswith($last)) then .[:-1] + [$x]    # 新的是旧的变长快照：换掉
      elif ($last | startswith($x)) then .              # 新的是落后的快照：不要
      else . + [$x] end end) | join("\n");
def wholeReply($near):
  if $near == null or $near.mid == null then $near else
    . as $st | turnStart as $from
    | [.chain_order[] | $st.chain[.] | select(.type == "assistant" and (.synthetic | not) and .mid == $near.mid and .ln >= $from and .ln <= $near.ln)] as $grp
    | if ($grp | length) <= 1 then $near
      else $near + {text: ([$grp[] | .text] | mergeTexts), tools: ([$grp[] | .tools[]] | unique_by(.id))} end end;

def interrupted($r; $s; $h; $detail):
  turnOf($s) as $t | ($h.as_kind // $h.kind) as $kind
  | wholeReply((walkUp($s.parentUuid; 200)) // lastAssistantInTurn($s)) as $reply
  | (if $reply != null and ($reply.text | length) > 0
     then emit(message($s; $t; $reply; "message.assistant"; "agent"; {"vibetrail.trigger": $s.uuid, "vibetrail.kind": $kind}))
     else . end)
  | (if $reply != null
     then reduce $reply.tools[] as $tl (.; (if $tl.id != null then .tools[$tl.id] else null end) as $tu
            | if $tu != null then emit(toolRequest($s; $t; $tl.id; $tu; {"vibetrail.trigger": $s.uuid, "vibetrail.kind": $kind})) else . end)
     else . end)
  | ($s.agent != null) as $sub
  # ⚠️ emit(base(…) | …) 里管道之后的 . 是事件、不是状态：状态里的值必须先绑成变量再用
  | ($reply.model // .turn_model) as $model | usageSum as $usage | .branch as $branch
  # 主会话的打断轮：hook 记过这一轮的 HEAD 就补上（打断时 Stop 不来，「止」取下一轮开始或会话结束时补的快照，DESIGN §3.5）
  | (if $sub then null else hookEnd(hookTurn($t.id)) end) as $hend
  | vcsMerge($branch; $hend.vcs) as $vcs | commitsOf($hend) as $commits | (.pturn.git_commit // false) as $gc
  | emit( base($s; (if $sub then "subagent.end" else "turn.end" end); $s.uuid; $s.ts; $t)
          | .payload = ({status: {code: (if $sub then "cancelled" else "interrupted" end), category: "cancellation", detail: ($detail | .[0:4096])}}
                        + (if $sub then opt("agent_type"; $meta.agentType)
                           else opt("model"; $model) + opt("usage"; $usage) + opt("vcs"; $vcs) end))
          | (if $commits != null
             then .commits = $commits
                  | .extensions += {"vibetrail.commit_method": ($hend.commit_method // "rev-list"),
                                    "vibetrail.commit_attribution": (if $gc then "agent_tool" else "inferred" end)}
             else . end)
          | .raw = {event_name: ("diverge." + $h.kind), data: ($h | del(.as_kind, .split_by, .permission_mode))}
          | .extensions += ({"vibetrail.kind": $kind, "vibetrail.human": true} + opt("vibetrail.interrupted_uuid"; $reply.uuid)
                            + opt("vibetrail.split_by"; $h.split_by) + opt("vibetrail.permission_mode"; $h.permission_mode))
          | ._key = ($s.uuid + "|" + .type) )
  | (if ($sub | not) and .pturn != null and .pturn.id == $t.id then .pturn.interrupted = true else . end)
  | addPending($s.uuid; $kind);

# for-tool-use 变体：同一轮里前面有 permission_denied 就是它的伴随记录，不另发事件（计一次）；
# 没有配对的（语料里未见）按打断处理，不丢事件
def forToolUse($r; $s; $h):
  if (.denials | length) > 0
  then .ledger.absorbed_for_tool_use += 1 | addPending($s.uuid; "interrupt_for_tool_use")
       # 这一轮是被拒绝停下的：当场关轮，status 记 denied（不算打断，打断只数 turn.end(interrupted)，K5）
       | (if .pturn != null and .pturn.id == turnOf($s).id then .pturn.denied = true | closeTurn("denied"; $s; false) else . end)
  elif (.stops | length) > 0 then   # 前面的 user-rejected 判成了按停止（K7）：这一条就是那次打断，按打断发
    .stops[0] as $sp | interrupted($r; $s; $h + {as_kind: "interrupt_tool", split_by: $sp.by, permission_mode: $sp.mode}; $s.text)
  else .ledger.unpaired_for_tool_use += 1 | interrupted($r; $s; $h; "unpaired interrupt_for_tool_use: " + $s.text) end;

def handle($r; $s; $h):
  (if .ln > $from_line then .ledger.in[$h.kind] += 1 else . end) | .ledger.in_total[$h.kind] += 1
  | (if $h.kind == "interrupt" then interrupted($r; $s; $h; $s.text)
     elif $h.kind == "interrupt_for_tool_use" then forToolUse($r; $s; $h)
     else decisions($r; $s; $h) end)
  | (if .ln > $from_line then .ledger.out[$h.kind] += 1 else . end);

# 分歧之后人的动作 → message.user，extensions 指回触发它的记录。
# 斜杠命令发一条但不结束等待——判责要的那句话通常是之后打的字；打字才结束等待
def emitAfter($s):
  .pending as $p
  | emit(message($s; turnOf($s); $s; "message.user"; "user";
         {"vibetrail.after": $p.after, "vibetrail.after_kind": $p.kind} + (if $s.slash then {"vibetrail.slash_command": true} else {} end)))
  | (if $s.human then .pending = null else . end);

def turnBoundary($r; $s):   # 主会话里 promptId 换了：上一轮关、这一轮开
  if $turns and mainRec($r) and $r.type == "user" and ($r.promptId | type) == "string" and $r.promptId != (.pturn.id // null)
  then closeTurn("next_turn"; $s; false) | openTurn($s)
  else . end;

# agent 自己用 Bash 跑了 git commit：本轮观察到的 commit 归因标 agent_tool，否则 inferred（人可能在别的终端提交，DESIGN §3.5）
def gitCommitCmd: type == "string" and test("(^|[;&|(\\s])git(\\s+-[Cc]\\s+\\S+|\\s+--no-pager)*\\s+commit(\\s|$)");
# 别的 Stop hook 拦停的痕迹：写在这次 Stop 的 stop_hook_summary 之前（2.1.266 二进制核过顺序），模型随后在同一轮接着干
def stopFeedback($r; $s):
  ($r.type == "attachment" and ($r.attachment | type) == "object"
     and (($r.attachment.type // "") | test("^hook_(blocking_error|additional_context)$"))
     and (($r.attachment.hookEvent // "") | test("^(Stop|SubagentStop)$")))
  or ($r.type == "user" and ($s.text | test("^(Stop|SubagentStop) hook feedback:")));

# 模型答完的标记：Claude Code 跑完这次 Stop 的 hook 写的 stop_hook_summary。前面没有拦停痕迹就当场关轮。
# 只关已经有过模型回复的轮：desktop 等下一句人话进来才把上一轮的 summary 落盘，它会落在下一轮开头的本地命令记录（/model 之类，与下一句人话共用一个 promptId）
# 之后——09-15 本机就这样把下一轮在开头错关了，整轮的用量都丢了
def turnStopMarker($r; $s):
  if .pturn != null and (.pturn.closed | not) and .pturn.answered and mainRec($r) and $r.type == "system" and $r.subtype == "stop_hook_summary"
  then if (.pturn.stop_blocked // false) then .pturn.stop_blocked = false | .pturn.block_pending = true   # 这次 Stop 被拦下，模型要接着干
       else .pturn.summary = {uuid: $s.uuid, ts: $s.ts, prevented: ($r.preventedContinuation == true), reason: ($r.stopReason // "")}
            | closeTurn("summary"; $s; false) end
  else . end;

def turnAccumulate($r; $s):
  if .pturn == null or (mainRec($r) | not) then .
  else .pturn.last_ts = ($s.ts // .pturn.last_ts)
    | (if $s.type == "assistant" and ($s.synthetic | not)
       then .pturn.stop_blocked = false | .pturn.block_pending = false | .pturn.answered = true
            | .pturn.end_turn = (($r.message | if type == "object" then .stop_reason else null end) == "end_turn")
       else . end)
    | (if stopFeedback($r; $s) then .pturn.stop_blocked = true else . end)
    | (if isQueuedHuman($r) then .pturn.queued += 1 else . end)
    | (if $s.type == "assistant" and $s.usage != null and ($s.synthetic | not)
       then ($s.mid // $s.rid // $s.uuid) as $uk
            | (if ((.pturn.usage[$uk].output_tokens // -1) > ($s.usage.output_tokens // 0)) then . else .pturn.usage[$uk] = $s.usage end)
            | .pturn.model = ($s.model // .pturn.model)
       else . end)
    | (if any($s.tools[]; .name == "Bash" and ((.input | if type == "object" then .command else null end) | gitCommitCmd))
       then .pturn.git_commit = true else . end)
  end;

# 下次的起读行：本轮开头；还有没等到人话的分歧时，退到那个分歧所在轮的开头；还没关的 promptId 轮从它开头读（关轮时用量才完整）
def baseCheckpoint: turnStart as $ts
  | (if .pending != null then ([.pending.since, $ts] | min) else $ts end) as $c
  | if .pturn != null then ([$c, .pturn.line] | min) else $c end;

# ---------- trace：每次模型调用、每次工具调用各一条，不带正文 ----------
def usageOne($u): if ($u | type) != "object" then null else
  ({input_tokens: (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0)), cached_input_tokens: ($u.cache_read_input_tokens // 0),
    output_tokens: ($u.output_tokens // 0)}
   + (($u.output_tokens_details | if type == "object" then (.thinking_tokens // 0) else 0 end) as $t | if $t > 0 then {reasoning_tokens: $t} else {} end))
  | .total_tokens = (.input_tokens + .cached_input_tokens + .output_tokens) end;
def stopReasonOf($r): ($r.message | if type == "object" then .stop_reason else null end);
def thinkingIn($r): ($r | msg.content | if type == "array" then any(.[]?; type == "object" and .type == "thinking") else false end);

def flushCall($eof):
  if .call == null then . else
    .call as $c
    | (base({agent: $c.agent}; "message.assistant"; $c.last_uuid; $c.last_ts; $c.turn)
       | .content_state = "omitted"
       | .payload = ({author_type: "agent"} + opt("model"; $c.model))
       | .provenance = {kind: "transcript", rule_version: "call-v1", source_event_id: $c.last_uuid}
       | .extensions += {"vibetrail.call": ({kind: "llm", stop_reason: $c.stop_reason, tool_calls: $c.tools, tool_call_ids: ($c.tool_ids // []), thinking: $c.thinking}
                          + opt("response_id"; $c.mid) + opt("request_id"; $c.rid) + opt("usage"; usageOne($c.usage))
                          + opt("started_at"; if $c.started_at != null and $c.last_ts != null and $c.started_at > $c.last_ts then $c.last_ts else $c.started_at end))}   # 开始不晚于结束（照 Pilot 的 normalizeRequestStart）
       | ._key = ($c.key + "|llm.call")) as $e
    | (if $eof then emitAlways($e) else emit($e) end)
    | .prev_end_ts = ([.prev_end_ts, $c.last_ts] | max) | .call = null end;

def toolEnds($r; $s):
  reduce ($r | msg.content | if type == "array" then .[] else empty end | objects | select(.type == "tool_result")) as $b (.;
    ($b.tool_use_id // null) as $cid
    # 这次没读到调用的结果不发（叫不出工具名）：结果与调用同在一轮，增量解析从当前轮开头读起，正常的都读得到。
    # 重写的旧结果已经按 uuid 整条跳过，这里是再兜一层（seen 清单丢了也不发出 unknown）；Pilot 也只给同一次读到调用的结果发 tool.result
    | if $cid == null or .tools[$cid] == null then . else
        .tools[$cid] as $tu
        | ($b.content | errText) as $txt
        | (if $b.is_error != true then {code: "success", category: "success"}
           elif ($txt | test("^\\[Tool call (did not complete|skipped)")) then {code: "cancelled", category: "cancellation"}
           elif ($txt | (isHumanDenial or isClassifier or isInfra)) or ($txt | startswith("The user doesn't want to")) then null   # 执行前被拒：只有 permission.decision
           else {code: "error", category: "error"} end) as $st
        | (($s.ts | epochms) as $b1 | ($tu.ts | epochms) as $a1 | if $b1 != null and $a1 != null and $b1 >= $a1 then $b1 - $a1 else null end) as $d
        | ({id: (.turn // $s.uuid), inferred: (.turn == null)}) as $t
        | if $st == null then . else
            emit( base($s; "tool.end"; $s.uuid; $s.ts; $t)
                  | .content_state = "omitted"
                  | .payload = ({tool_name: $tu.name, call_id: $cid, status: $st} + opt("duration_ms"; $d))
                  | .provenance = {kind: "transcript", rule_version: "call-v1", source_event_id: $s.uuid}
                  | ._key = ($cid + "|tool.end") ) end end);

# API 请求失败、Claude Code 重试（system / api_error，source request_retry）：每条发一条 ext.claude.api_error，只带元数据，挂回那次调用的 response_id（U15）。
# 这类记录要等这一轮结束、下一句人话前才一起落盘（与 stop_hook_summary 一样），总在它那次调用之后、有时晚几十行——不能挂在调用事件上（Stop 时调用已经发了）。
# 按时间挂：失败时刻落在「请求发出（started_at）之后、回复第一条记录之前」的那次调用里最早的一个。不按父记录链——一起落盘的几条，
# 后一条的父记录是前一条，会把一轮里几次调用各自的失败都算到第一次头上（09-15 本机 aeb3a412 相隔 11 分钟的三次断网）
def apiError($r; $s):
  if $r.type == "system" and $r.subtype == "api_error" then
    ($s.ts // "") as $at
    | ([.calls_seen[] | select(.started_at != null and .first_ts != null and .started_at <= $at and .first_ts >= $at)] | min_by(.first_ts)) as $req
    | (($r.error | if type == "string" then (fromjson? // {}) elif type == "object" then . else {} end)) as $err
    | ({id: ($req.turn.id // .turn // $s.uuid), inferred: ($req.turn.inferred // (.turn == null))}) as $t
    | emit( base($s; "ext.claude.api_error"; $s.uuid; $s.ts; $t)
            | .content_state = "omitted"
            | .payload = ({} + opt("retry_attempt"; $r.retryAttempt) + opt("retry_in_ms"; $r.retryInMs) + opt("max_retries"; $r.maxRetries)
                         + opt("source"; $r.source) + opt("error"; (($err.formatted // $err.message // null) | if type == "string" then .[0:200] else null end))
                         + opt("status"; ($err.status // null)))
            | .provenance = {kind: "transcript", rule_version: "call-v1", source_event_id: $s.uuid}
            | .extensions += opt("vibetrail.response_id"; $req.mid)
            | ._key = ($s.uuid + "|api_error") )
  else . end;

def traceStep($r; $s):
  # user 记录不结束这次调用：2.1.260 边生成边执行工具，工具结果会夹在同一次调用的几条记录中间（09-15 本机 96 次调用曾因此被拆开）
  (if $s.type == "user" then toolEnds($r; $s) | .prev_end_ts = ([.prev_end_ts, $s.ts] | max) else . end)   # 只往后走：重写的旧记录带着旧时间
  | apiError($r; $s)
  | (if $s.type == "assistant" and ($s.synthetic | not) then
       ($s.mid // $s.rid // $s.uuid) as $k
       | (if .call != null and .call.key != $k then flushCall(false) else . end)
       | if .call == null
         then .call = {key: $k, mid: $s.mid, rid: $s.rid, model: $s.model, usage: $s.usage, stop_reason: stopReasonOf($r),
                       tools: [$s.tools[] | .name], tool_ids: [$s.tools[] | .id | strings], thinking: thinkingIn($r), last_ts: $s.ts, last_uuid: $s.uuid, ck: baseCheckpoint,
                       started_at: .prev_end_ts, agent: $s.agent, turn: {id: (.turn // $s.uuid), inferred: (.turn == null)}}
              | .calls_seen += [{mid: $k, turn: .call.turn, started_at: .call.started_at, first_ts: $s.ts}]
              | (if (.calls_seen | length) > 200 then .calls_seen = .calls_seen[1:] else . end)
         else .call.last_ts = ($s.ts // .call.last_ts) | .call.last_uuid = $s.uuid
              | .call.stop_reason = (stopReasonOf($r) // .call.stop_reason)
              | .call.tools += [$s.tools[] | .name] | .call.tool_ids += [$s.tools[] | .id | strings] | .call.thinking = (.call.thinking or thinkingIn($r))
              | (if $s.usage != null and (($s.usage.output_tokens // 0) >= (.call.usage.output_tokens // -1)) then .call.usage = $s.usage else . end) end
     else . end);

def step($r):
  .out = [] | .ln += 1 | .ln as $ln
  | if ($r | type) != "object" then .ledger.skipped_non_object += 1
    elif ($r.uuid | type) != "string" then .ledger.skipped_no_uuid += 1
    else
      ($r | slim($ln)) as $s | [$r | diverge] as $hits
      | if (.run_uuids[$r.uuid] or (.prior[$r.uuid] != null and .prior[$r.uuid] != $ln)) then .ledger.replayed += 1
    else
      .run_uuids[$r.uuid] = true
      | .ledger.records += 1
      | .last_ts = ($r.timestamp // .last_ts) | .version = ($r.version // .version)
      | .entrypoint = ($r.entrypoint // .entrypoint) | .branch = ($r.gitBranch // .branch)
      | (if ($r.promptId | type) == "string" and $r.promptId != .turn then .turn = $r.promptId | .denials = [] | .stops = [] else . end)
      | (if ($s.human or $s.slash) and ($r.permissionMode | type) == "string" then .perm_mode = $r.permissionMode else . end)
      | turnBoundary($r; $s)
      | index($s)
      | (if $s.human then .turn_usage = {} | .turn_model = null | .turn_line = $s.ln else . end)
      # 同一 message.id 留 output_tokens 最大的那份（照 ccusage：早期流式记录可能是占位值，取最大与读取顺序无关）
      | (if $s.type == "assistant" and $s.usage != null and ($s.synthetic | not)
         then ($s.mid // $s.rid // $s.uuid) as $uk
              | (if ((.turn_usage[$uk].output_tokens // -1) > ($s.usage.output_tokens // 0)) then . else .turn_usage[$uk] = $s.usage end)
              | .turn_model = ($s.model // .turn_model) else . end)
      | turnAccumulate($r; $s)
      | turnStopMarker($r; $s)
      | (if $turns then traceStep($r; $s) else . end)
      | (if $ln > $from_line then .ledger.sources += [[$s.uuid, $ln]] else . end)
      | (if ($r.toolUseResult | type) == "string" and ($r.toolUseResult | startswith("User rejected tool use"))
         then .ledger.sentinel.marker += 1
              | (if any($hits[]; .kind == "permission_denied") then . else .ledger.sentinel.marker_without_hit += 1 end)
         else . end)
      | reduce $hits[] as $h (.; handle($r; $s; $h))
      | (if ($s.human or $s.slash) and .pending != null then emitAfter($s) else . end)
    end
    end;

# 还没写出的那次模型调用：从它所在那一轮的起读行读起（上一轮最后一次调用要等下一个 message.id 才写，起读行不能越过它；
# 也不能落在它那一轮中间——assistant 记录不带 promptId，从中间读认不出轮，请求开始时间也要靠它前面那条）
def checkpoint: baseCheckpoint as $c | if .call != null then ([$c, .call.ck] | min) else $c end;

# 文件末尾：$close_last 非空（会话结束 / 恢复 / 空闲）就把最后一轮也关掉
def atEof:
  .out = []
  # trace：最后一次模型调用在关轮时一起写出（后面没有另一个 message.id 来结束它）；不带 $close_last 不写——文件可能还在长，
  # 写出去的会是半截，完整的那条之后按 event_id 被拦下。子 agent 文件由 hook 在它结束后（SubagentStop 记下的大小没变，或会话结束 / 恢复 / 空闲）带上
  | (if $turns and .call != null and $close_last != "" then flushCall(true) else . end)
  | if $close_last == "" or .pturn == null then .
    elif $close_last == "stop" then   # Stop hook：这次 Stop 的那一轮、有过模型回复、没看到拦停反馈，就当场关
      (if .pturn.id == $stop_turn and .pturn.answered and (.pturn.block_pending | not) and (.pturn.stop_blocked | not)
       then closeTurn("stop"; {agent: null, uuid: null, ts: null}; true) else . end)
    else closeTurn($close_last; {agent: null, uuid: null, ts: null}; true) end;

foreach (inputs, {"__vibetrail_eof__": true}) as $r (init;
  if $r == {"__vibetrail_eof__": true} then atEof else step($r) end;
  if $r == {"__vibetrail_eof__": true}
  then (.out[]),
       {"_ledger": (.ledger + {start_line: $start_line, from_line: $from_line, lines: .ln, checkpoint_line: checkpoint,
                               sources: .ledger.sources,
                               turns: (.ledger.turns + {open: (.pturn.id // null), open_line: (.pturn.line // null),
                                                        closed: (.pturn.closed // false), model: (.pturn.model // .turn_model)}),
                               trace: {call_open: (.call != null)}})}
  else .out[] end)
