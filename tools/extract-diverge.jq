# vibetrail: 从 Claude Code transcript 提取人机分歧点
#
# 铁律一：只读 JSON 字段，绝不 grep 整行原文。会话自身可能在讨论这些字段名与消息串
#         （本项目的调研会话就是），grep 原文会把「讨论」当成「发生」。
# 铁律二：每条规则用 select(<布尔>) 而非 `X as $_ |`。后者因为 jq 中 `|` 优先级低于
#         `,`，会让后续所有规则被吸进第一条的 body，前一条不命中则整程序静默返空。
# 铁律三：条件里用 any(...) 而非 .[]? 展开，否则一条记录里多个块命中会 emit 多次。
# 铁律四：取 .toolUseResult 的子字段前必须先判 type=="object"。它有时是 array 或 string，
#         直接索引会抛错，而 jq 抛错会丢掉**整条记录**——连带该记录上其他规则的命中
#         一起静默消失。实测这一条曾让 1200 条记录被丢弃。

def hit($kind; $human): {
  kind: $kind,
  human: $human,          # true = 人的决定；false = 机器/基础设施，不计入人机分歧
  at: .timestamp, turn: .uuid, sid: .sessionId, branch: .gitBranch
};

def errTexts:            # 本条记录里所有 is_error 块的正文
  if .type == "user" and (.message.content | type) == "array"
  then [.message.content[]? | select(.is_error == true) | (.content | tostring)]
  else [] end;

def isHumanDenial:
  # 必须带 "m"：真实消息是
  #   Permission to use Bash with command <多行命令> has been denied.
  # 命令正文带换行，不加会漏掉所有多行命令的拒绝（实测漏 2/90）。
  # ⚠️ jq/Oniguruma 的标志与 PCRE 相反——dotall 是 "m" 不是 "s"（"s" 在这里是单行模式）。
  #    按 PCRE 习惯写 "s" 会静默匹配失败，不报错。
  (test("^Permission to use .* has been denied"; "m") or
   test("^The user doesn't want to proceed with this tool use"))
  and (test("Blocked by classifier") | not)
  and (test("Tool permission (request failed|stream closed)") | not);

# ---- 1. interrupt：人打断了 agent ----
# 判据：去掉前导空白后**以标记开头**，而不是正文里含有该子串。
# 不带右括号是有意的，同时覆盖两种真实变体（本语料 244 + 33）：
#   [Request interrupted by user]
#   [Request interrupted by user for tool use]
# 用无锚子串会误收 <task-notification> 这类正文里恰好提到该短语的记录
#   （实测 278 命中里有 1 条是这种假阳；锚定后 277 条全真、一条不漏）。
# 同时只认 user 的 text 块与字符串正文，排除 tool_result——否则会话自己
#   讨论这个标记时会被当成发生过。
def isInterruptText: (sub("^\\s+"; "")) | startswith("[Request interrupted by user");
( select(.type == "user" and (
    (((.message.content | type) == "array") and
       any(.message.content[]?; .type == "text" and (.text | isInterruptText)))
    or (((.message.content | type) == "string") and (.message.content | isInterruptText))
  )) | hit("interrupt"; true) ),

# ---- 2. permission_denied：人拒绝了一次工具调用 ----
( select(any(errTexts[]; isHumanDenial)) | hit("permission_denied"; true) ),

# ---- 3. classifier_blocked：auto mode 分类器拒的，机器决定 ----
( select(any(errTexts[]; test("denied by the Claude Code auto mode classifier")))
  | hit("classifier_blocked"; false) ),

# ---- 4. permission_infra_fail：权限链路本身失败，不是任何人的决定 ----
( select(any(errTexts[]; test("Tool permission (request failed|stream closed)")))
  | hit("permission_infra_fail"; false) ),

# ---- 5. user_edited_after_agent：模型改完，人又手改 ----
( select((.toolUseResult | type) == "object" and .toolUseResult.userModified == true)
  | hit("user_edited_after_agent"; true) )
