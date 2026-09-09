# vibetrail: 从 Claude Code transcript 提取人机分歧点
#
# 铁律一：只读 JSON 字段，绝不 grep 整行原文。会话自身可能在讨论这些字段名与消息串
#         （本项目的调研会话就是），grep 原文会把「讨论」当成「发生」。
# 铁律二：每条规则用 select(<布尔>) 而非 `X as $_ |`。后者因为 jq 中 `|` 优先级低于
#         `,`，会让后续所有规则被吸进第一条的 body，前一条不命中则整程序静默返空。
# 铁律三：条件里用 any(...) 而非 .[]? 展开，否则一条记录里多个块命中会 emit 多次。
# 铁律四：取 .toolUseResult 这类多态字段的子字段前必须先判 type=="object"。它有时是 array
#         或 string，直接索引会抛错。jq 抛错时该记录**抛错点之后的规则**全部不再求值（之前
#         已输出的命中保留），然后继续下一条输入；退出码只反映最后一条输入。实测曾有 1200 条记录触发；
#         当时出错规则排在末尾所以没丢命中，但规则顺序一变就会真丢。现在没有规则读
#         .toolUseResult 了（user_edited_after_agent 已删，见 spec §3.1），这条留给加规则的人。
# 铁律五：is_error 块的 content 可能是数组 [{"type":"text","text":…}]，直接 tostring 会以
#         "[" 开头，而 jq 的 ^ 在任何标志下都只匹配串首——锚定判据永远不命中。必须先展开。
# 铁律六：message.content[] 的元素先过 objects，.text 缺失时 // "" 兜底。数组里混入裸字符串
#         或缺字段的块会让 .is_error / sub 抛错，后果同铁律四。

def hit($kind; $human): {
  t: "diverge",
  kind: $kind,
  human: $human,          # true = 人的决定；false = 机器/基础设施，不计入人机分歧
  at: .timestamp, turn: .uuid, sid: .sessionId, branch: .gitBranch
};

def errText:             # is_error 块的 content：字符串，或 text 块数组（铁律五）
  if type == "array"
  then [.[]? | if type == "string" then . else (.text? // empty) end | strings] | join("\n")
  else tostring end;

def errTexts:            # 本条记录里所有 is_error 块的正文
  if .type == "user" and (.message.content | type) == "array"
  then [.message.content[]? | objects | select(.is_error == true) | (.content | errText)]
  else [] end;

def isClassifier: test("denied by the Claude Code auto mode classifier") or test("Blocked by classifier");
def isInfra:      test("Tool permission (request failed|stream closed)");

def isHumanDenial:
  # 必须带 "m"：真实消息是
  #   Permission to use Bash with command <多行命令> has been denied.
  # 命令正文带换行，不加会漏掉所有多行命令的拒绝（实测漏 2/90）。
  # ⚠️ jq/Oniguruma 的标志与 PCRE 相反——dotall 是 "m" 不是 "s"（"s" 在这里是单行模式）。
  #    按 PCRE 习惯写 "s" 会静默匹配失败，不报错。
  (test("^Permission to use .* has been denied"; "m") or
   test("^The user doesn't want to proceed with this tool use"))
  and (isClassifier | not) and (isInfra | not);   # 与规则 3/4 用同一对谓词，保证一条不会既算人拒又算机器拒

# ---- 1. interrupt：人打断了 agent ----
# 判据：去掉前导空白后**以标记开头**，而不是正文里含有该子串。
# 不带右括号是有意的，同时覆盖两种真实变体（本语料 244 + 33）：
#   [Request interrupted by user]
#   [Request interrupted by user for tool use]
# 用无锚子串会误收 <task-notification> 这类正文里恰好提到该短语的记录
#   （实测 278 命中里有 1 条是这种假阳；锚定后 277 条全真、一条不漏）。
# 同时只认 user 的 text 块与字符串正文，排除 tool_result——否则会话自己
#   讨论这个标记时会被当成发生过。
# 两个变体必须分开，否则一次「拒绝工具调用」会被记两条（实测 35 次，见下）：
#   [Request interrupted by user]                → 人主动打断 agent，自发
#   [Request interrupted by user for tool use]   → 人拒绝工具调用时伴随的打断
# 后者**总是**与一条 permission_denied 同时出现（同一动作、两条记录、不同 turn uuid）。
# 实测全语料：for-tool-use 变体 35 次，而「同秒同时命中两类」也恰是 35 次——精确对上。
# 合成一个 kind 会让「人打断了多少次」把拒绝也算进去。
def isInterruptText: (sub("^\\s+"; "")) | startswith("[Request interrupted by user");
def isForToolUse:    test("for tool use");
def anyText: if (.message.content | type) == "array"
             then [.message.content[]? | objects | select(.type=="text") | (.text // "")]
             elif (.message.content | type) == "string" then [.message.content]
             else [] end;

( select(.type == "user" and any(anyText[]; isInterruptText and (isForToolUse | not)))
  | hit("interrupt"; true) ),
( select(.type == "user" and any(anyText[]; isInterruptText and isForToolUse))
  | hit("interrupt_for_tool_use"; true) ),

# ---- 2. permission_denied：人拒绝了一次工具调用 ----
( select(any(errTexts[]; isHumanDenial)) | hit("permission_denied"; true) ),

# ---- 3. classifier_blocked：auto mode 分类器拒的，机器决定 ----
( select(any(errTexts[]; isClassifier)) | hit("classifier_blocked"; false) ),

# ---- 4. permission_infra_fail：权限链路本身失败，不是任何人的决定 ----
( select(any(errTexts[]; isInfra)) | hit("permission_infra_fail"; false) )

# （曾有第 5 条 user_edited_after_agent，读 .toolUseResult.userModified。已删：desktop 客户端里
#   该字段不可能为真，见 spec §3.4。fixtures 里 n6-n8 / t9-t10 保留，继续守着「不读多态字段」。）
