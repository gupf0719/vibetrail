# 人机分歧判据 v1

> 从 transcript 里判定「人在哪一步不同意机器」的规则。**判据只在本文维护一份**：实现在
> `tools/diverge-rules.jq`（jq 模块，只有函数定义），命令行入口 `tools/extract-diverge.jq`
> （`jq -c -L tools -f tools/extract-diverge.jq <transcript>`，jq 1.6 按 cwd 找模块，`-L` 不能省），
> 正负例在 `tools/fixtures.jsonl`，由 `tools/test-extract.sh` 跑。把命中映射成协议事件是它之后的一步
> （`tools/map-events.jq`，规则见 [DESIGN.md §4.2](../DESIGN.md)），本文不管。
> 本文原是 [trace-v1.md](trace-v1.md) §3，2026-09-14 随 G7 独立成文；仓内 `sessions/` 那个落点已退役
> （[DESIGN.md D4](../DESIGN.md)），判据与实测数字不变。

## 0. 是什么

Claude Code 的 transcript 里没有任何结构化字段标「人打断了」「人拒绝了」，只有英文正文。三个业内实现读下来：
SpecStory 只认 interrupt（一行前缀匹配），git-ai 与 claude-story 一个都不认——**字符串匹配就是现有水平，没有结构化字段可用**。

分歧**落在对话侧，不在文件侧**：`userModified` / `staleRecovered` 两个文件侧字段都不可用（§5）。本工作流里人不碰文件——
人指挥、Claude 动手——所以能抓的只有打断与拒绝。

## 1. 记录形态

提取器原始输出，每行一个 JSON 对象：

```json
{"t":"diverge","kind":"interrupt","at":"…","turn":"<uuid>","human":true,"branch":"main","sid":"<sessionId>"}
{"t":"diverge","kind":"permission_denied","at":"…","turn":"<uuid>","human":true,"branch":"main","sid":"<sessionId>","call_id":"toolu_…"}
```

- `turn`：transcript 里那条消息的 `uuid`——**指针，不是内容**。transcript 在就能跳回去看上下文，不在就只剩「某时刻发生过一次中断」。
- `human`：`true` 才计入人机分歧，`false` 是机器 / 基础设施行为。混在一起统计会让「人拒了多少次」被分类器和链路故障污染。
- `branch`：事件发生时的 `gitBranch`，可选。
- `sid`：所属会话，路由键。
- `call_id`：三类 `is_error` kind 带，是命中块的 `tool_use_id`（块没带就是 null）。2026-09-15 起产出，可选字段，不升版本。
  被拒工具的 `name` / `input` **不在本记录里**——映射层按 `call_id` 反查前面 assistant 记录的 `tool_use` 块
  （OPEN-ISSUES G5 已关）；反查不到时退回 `Permission to use (\S+)` 捕获，再不行标 `unknown`，来路记在事件的 extensions 里。

## 2. `kind` 取值与判据

| kind | human | 判据 |
|---|---|---|
| `interrupt` | ✅ | 去前导空白后 `startswith("[Request interrupted by user")` **且不含** `for tool use`——人主动打断 |
| `interrupt_for_tool_use` | ✅ | 同上但**含** `for tool use`——人拒绝工具调用时伴随的打断，**总是**与一条 `permission_denied` 同时出现 |
| `permission_denied` | ✅ | `is_error` 块正文 `^Permission to use .* has been denied`（带 `m` 标志）或 `^The user doesn't want to proceed with this tool use` |
| `classifier_blocked` | ❌ | 正文含 `denied by the Claude Code auto mode classifier` 或 `Blocked by classifier`——auto mode 分类器拒的，不是人 |
| `permission_infra_fail` | ❌ | 正文含 `Tool permission request failed` 或 `Tool permission stream closed`——链路故障，不是任何人的决定 |

⚠️ **两个 interrupt 变体必须分开，否则一次「拒绝工具调用」被记两条。** 实测全语料：`for tool use` 变体 **35** 次，
而「同一会话同一秒同时命中 `permission_denied` 与 `interrupt`」也恰是 **35** 次——精确对上。两者是**同一个人类动作的两条记录**
（turn uuid 不同）。统计「人机分歧总数」时，`interrupt_for_tool_use` 应与其配对的 `permission_denied` 计为一次。

配对是 **n:1** 不是 1:1：并行发出的几个调用一起被拒时，`permission_denied` 各一条、`interrupt_for_tool_use` 只一条
（2026-09-15 实测 3:1，for-tool-use 记录的 `parentUuid` 指向最后一条拒绝）。映射层把 for-tool-use 记录吸收进同一轮前面的拒绝、
不另发事件；同一轮里没有拒绝可配的 for-tool-use（语料未见）按打断发、不丢。

判据全部**只读 JSON 字段**，不 grep 整行原文。`interrupt` 只认 user 消息的 text 块或字符串正文，**不认** `tool_result` 块；
其余三类**只认** `is_error == true` 的块正文（Claude Code 里只有 `tool_result` 块带 `is_error`，判据不另查 `type`）。原因见 §4。

`permission_denied` 的**排除子句**与规则 3 / 4 共用同一对谓词（`isClassifier` / `isInfra`）：正文命中分类器或链路故障判据时不计为人拒，
只落到对应的机器类 kind。防的是机器消息以 `Permission to use … has been denied` 开头的变体——语料里未见，属防御；fixtures t12 / t14 / t15
覆盖，保证同一条不会既算人拒又算机器拒。

### 2.1 已删除、挡在门外的 kind

- **`user_edited_after_agent`**——曾被称作「最硬的信号」，**已被实测推翻**：全语料 3507 次 `userModified` 取值全为 `false`（755 个会话），
  见 §5。提取器里对应的规则已于 2026-09-08 移除。
- **`correction`**（用户纠正话术的启发式）——未实现。现有 kind 都是硬信号、已有可用准确率，先把启发式挡在门外；
  要加须先有独立的准确率实测，且必须与硬信号分开统计。

### 2.2 候选：上游已有的类型化信号，先量再用

本机语料（2026-09-14）里有几个比字符串判据可靠的信号：`queue-operation` 的 `remove` 带 `reason: absorbed_mid_turn` 296 条
（人在模型干活时插话、被并入当前轮——没有任何字符串可匹配）；`attachment.edited_text_file` 327 条（磁盘侧改动，抽样都是 agent 自己的
Bash 改的，不是人）；`attachment.hook_blocking_error` 332 条（宿主自己的 Stop 闸门拦停）；hook 事件 `PermissionDenied`（≈ `classifier_blocked`）、
`StopFailure`、`Notification` 的 `permission_prompt`。都先按 §3 的方式量精确率，再决定加不加 kind（OPEN-ISSUES U8）。
G7 的 hook 事件流会记下它们的 `tool_use_id`，与本文的字符串判定对账——两边对不上就是判据漂了，这正是 G6 要的哨兵。

## 3. 准确率实测

2026-09-08，755 个会话 / 674 MB：

| kind | 命中 | 精确率 | 召回率 |
|---|---:|---|---|
| `interrupt` | 277 | **100%**（277/277） | 100%，无遗漏 |
| `permission_denied` | 90 | 100%（人工逐条核对候选集） | **100%**（90/90，修复后） |
| `classifier_blocked` | 1 | — | — |
| `permission_infra_fail` | 6 | — | — |

召回率的基线是**无锚子串候选集**（`interrupt` 为 278 条），含义是「相对裸 grep 不漏」，不是绝对召回——不含该子串的中断形态
（若存在）测不到（OPEN-ISSUES M2）。277 是**逐条命中数**，其中 13 条是子 agent 与父会话的传播重复（同一次打断记进两边），
作为事件数多报 4.7%；去重方案见 OPEN-ISSUES K1。

对照：**裸 grep 原文在对抗样本上精确率仅 10.5%**。以本项目的调研会话为靶（它在命令输出里反复打印过 `Request interrupted` 字面量）：
裸 grep 命中 19 条，本规则命中 2 条，人工核对真实中断正是 2 次。

2026-09-09 重测（756 个 transcript）：`interrupt` 248（人主动打断）、`interrupt_for_tool_use` 35（伴随拒绝）、`permission_denied` 92
（主会话 39 + 子 agent 53）、`permission_infra_fail` 6、`classifier_blocked` 1。与 09-08 的差异**全部来自语料增长**——我们工作时它一直在写。
**引用语料级数字必须带测量日期。**

上表数字是修完 §4 里的坑之后才得到的。

## 4. 踩过的坑：写提取器的人必读

以下五条不知道就会**静默错**（不报错、只是不对）：

1. **只读字段，绝不 grep 原文。** 会话自身会讨论这些标记（本项目的调研会话就是），grep 原文把「讨论」当成「发生」。同理 `interrupt`
   判据必须排除 `tool_result` 块（其余三类读的就是 `is_error` 的 tool_result 块，靠锚定而非靠排除）。
2. **锚定，不要用无锚子串。** 无锚子串会误收 `<task-notification>` 这类正文里恰好提到该短语的记录（实测 278 命中里 1 条假阳）。
   SpecStory 的前缀故意不带右括号，正好同时覆盖 `[Request interrupted by user]` 与 `[...for tool use]` 两种变体。
3. **jq 的正则标志与 PCRE 相反**：dotall 是 `m` 不是 `s`（`s` 在这里是单行模式）。按 PCRE 习惯写 `s` 会**静默匹配失败**。权限拒绝的真实消息
   把多行命令嵌在中间（`Permission to use Bash with command <多行> has been denied.`），不加 `m` 会漏全部多行命令的拒绝——实测漏 2/90。
4. **取 `.toolUseResult` 这类多态字段的子字段前先判 `type=="object"`。** 它有时是 array 或 string，直接索引会抛错。jq 抛错时该条记录
   **抛错点之后的规则**全部不再求值，之前已输出的命中保留，然后继续下一条；退出码只反映**最后一条**输入是否出错，中间的错误只留在 stderr。
   实测曾有 1200 条记录触发此错误；因为出错的规则排在末尾，其他规则的命中没丢，但规则顺序一变就会整条丢失。现在提取器已不读 `.toolUseResult`，
   这条留给将来加规则的人。同理 `message.content[]` 的元素先过 `objects`，`.text` 缺失时用 `// ""` 兜底。
5. **`is_error` 块的 `content` 可能是数组**（`[{"type":"text","text":…}]`）。直接 `tostring` 会以 `[` 开头，而 jq 的 `^` 在任何标志下都只匹配串首，
   锚定判据永远不命中。提取器先把数组展开成各段 text 再匹配。09-09 量过：1145 个 `is_error` 块全部字符串形态、数组形态 0 个，这条是纯防御。
6. **`.message` 也是多态的。** 一律经 `msg`（`type=="object"` 才取）读 `content` / `id` / `usage`，别直接 `.message.content`——
   `.message` 是字符串时抛错，后果同第 4 条。语料里未见非对象（09-15 抽 8 个文件），纯防御；fixture n11 钉着。

回归测试比对的是**整条输出**（含 `human` 与全部字段名），不只比 kind；并且检查 jq 有没有报错——只比对输出抓不到「末尾规则抛错」（实测假绿）。

## 5. `userModified` 与 `staleRecovered`：查清了什么

追查「`userModified` 什么条件下会置真」的结论：**没查到会置真的条件，但排除了最像的那个，并顺带找到了一个真正会触发的字段**。

**排除「磁盘陈旧」假设（受控实验，决定性）**：Read 一个文件 → 用 Bash 外部改它 → 再 Edit。Claude Code 明确检测到并提示
「the file had been modified on disk since you last read it」，而该次 Edit 的记录是 `staleRecovered: true`、`userModified: false`。
所以 **`staleRecovered` 才是「Read 之后文件被改过」的信号**，只在为真时出现，全语料 21 次。`userModified` 与陈旧无关。

**`staleRecovered` 也不是人机分歧信号**：21 次逐条回溯，**没有一例是确认的人工修改**——16 例直接对上 Claude 自己的 `sed` / `python3` / `tee`，
其余 5 例放宽到全会话范围后同样有 Bash 命令碰过该文件。根因是本工作流里 Claude 大量经 Bash 改文件，而**人基本不直接碰文件**。

**为何在 desktop 客户端不可达（交互实验，已定论）**：`userModified` 只由 Edit / Write 产出。语料 212413 条记录里 `entrypoint` 100% 是
`claude-desktop`，`permissionMode` 只有 `acceptEdits`(1213) 与 `auto`(1039)——都自动接受编辑。装一道 `PreToolUse` 闸门强制返回
`permissionDecision: "ask"` 后，`acceptEdits` 与 `default` 都弹出审批（截图确认），**hook 返回的 `ask` 能穿透 `acceptEdits`**；
弹出的面板**一律只有 `Deny` 与 `Allow once`**，附 diff 预览，**没有任何修改提案的操作面**。

> ⚠️ 这张表的前两行曾写成「被模式盖过、不弹窗」，是错的。错因是**拿「我没观察到弹窗」当成了「弹窗没出现」**——审批弹窗不出现在
> agent 的工具结果里，agent 没有观察它的通道。凡是「某事没发生」的断言，先问一句「我有没有能观察到它发生的通道」。

**结论：在 Claude desktop 客户端里 `userModified` 不可能为真**——这个客户端不提供「改动 Claude 提出的编辑」这个动作。两个字段都不能
用作人机分歧信号。这不是字段的问题，是这个工作流的形状——**人不碰文件，所以分歧不落在文件上，只落在对话上**。现有 kind 恰好覆盖的
就是对话侧，这个负结果反过来支持了当前设计。

## 6. 稳定面与版本

- `kind` 的取值集合可增补，不升版本；消费方遇到不认识的 kind **应保留并跳过，不得报错**。
- 记录里的新增可选字段不升版本；消费方必须忽略不认识的字段。`call_id`（09-15 加）就是这样的字段，缺失当 null。
- 字段名一旦发布就**不再改拼写**，哪怕拼错了（git-ai 的 `overriden_lines` 就是这样成了既成事实）。
- 被拒记录另有一个独立字段可对账：`toolUseResult` 是 `User rejected tool use`（或 `Error: Permission to use …` 原文）。映射账本的
  `sentinel.marker_without_hit` 记「有标记而判据没认出」的条数（2026-09-15 本机 45 个标记、0 次漏判），判据漂了会先在这里露头。
- 判据依赖英文消息串，Claude Code 改文案即**静默失效**。缓解只能是：判据集中在本文与提取器一处、配正负例回归、语料数字突变时当作信号
  而非当作事实；每次上游升级先查一遍有没有新增的类型化字段可以替换掉硬编码串（§2.2、OPEN-ISSUES G6）。

## 7. 已知不解决

- 依赖英文串（上）。
- transcript 丢失后 `turn` 指针悬空。D5 后不传原样副本，分歧事件自带判责用的最小正文（被拒调用的输入、被打断的回复、之后人的下一句），
  指针只用于本机 30 天内与 transcript 对账。
- 子 agent 与父会话的传播重复（13/277），去重见 OPEN-ISSUES K1。
- 召回率绝对基线未测（OPEN-ISSUES M2）。
- `userModified` 在别的客户端（提供「修改提案」能力的 IDE 扩展一类）会不会置真，超出本环境可验范围；本判据不依赖它。
