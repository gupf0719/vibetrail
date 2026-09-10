# LoongSuite Pilot 采集清单

> 三方项目分析，**不是**本项目的一部分。配套文档：[loongsuite-pilot.md](loongsuite-pilot.md)（项目分析）、
> [teamai-cli-vs-vibetrail.md](teamai-cli-vs-vibetrail.md)（三方对比）。
>
> 快照 HEAD `d4ab8b6d`（2026-09-08），仓在 `/Users/gupengfei/program/go/src/loongsuite-pilot`，行号均指向该快照，
> **引用请带日期**。除 §1.2b 那次用它的解析器离线跑本机 transcript 之外，全部读码所得；本机未装 Pilot（`~/.loongsuite-pilot` 不存在，`~/.claude/settings.json`
> 里没有它的 hook），没有实机数据可对照。
>
> 无前缀的行号指 `assets/hooks/claude-code-hook-processor.mjs`；其余均带文件名。

本文只回答一个问题：**它采了什么、落在哪、什么出本机。** 与本项目和 teamai 的三方对比见
[teamai-cli-vs-vibetrail.md](teamai-cli-vs-vibetrail.md)，此处不重复。

## 0. 一句话

**采的是完整对话内容 —— 完整 prompt、完整模型输出、完整工具参数与工具结果，正文零截断，而且默认开、默认不脱敏。**

这是与 teamai 最根本的口径差：teamai 采「计数 + 少量截断文本」（200 / 500 / 160 字三档），Pilot 采**全文**。

两个默认值是全文的前提：

```
src/core/config-loader.ts:510   captureMessageContent = parseOptionalBool(...) ?? true   ← 默认采完整内容
src/core/config-loader.ts:563   未配置 mask 时 return { mode: 'none', types: [] }        ← 默认不脱敏
```

官方文档没有直说「默认开」，但 `docs/zh-CN/masking.md:149` 的措辞印证了方向：「**只有当**分析确实需要完整
Prompt、Completion、工具参数或工具结果……才建议使用 `captureMessageContent: true`」——整篇推荐配置都在教怎么关。

「零截断」是逐字段核实的，不是推断（Claude Code 链路，行号见 §1.2）：prompt 全文、input delta 全文、
output text 与 thinking 全文、tool arguments 全文、tool result 全文。整条链路上**唯一**的长度截断是
`error.message` 的 500 字符——而它恰好是绕过内容开关的那一条，见 §5.2。
**但「零截断」说的是取到的字段，不是每条记录都取到了**：本机实测，工具调用、工具结果、模型回复全采；
人类这一侧会漏掉没等到真实回复的整轮 prompt 和轮末的消息，中断标记几乎全丢；同一回复里的多个 thinking 块只留最长的（§1.2b）。

分四层看：

| 层 | 内容 | 去向 |
|---|---|---|
| 内容 | `gen_ai.input.messages` / `messages_delta`、`gen_ai.output.messages`（含 reasoning）、`gen_ai.system_instructions`、`gen_ai.tool.call.arguments`、`gen_ai.tool.call.result` | 本机 JSONL 默认开；配了 SLS / HTTP / OTLP 就**整份出本机** |
| 计数与指标 | token 五项 + 四项成本、TTFT、工具耗时、finish reason、请求/响应模型名、`messages_hash` | 同上 |
| 身份与环境 | `user.id`（**默认取 hostname**）、`workspace.path`（cwd 绝对路径）、`git.repo` / `git.branch` / `git.domain`；hostname：Qoder / Qoder CN、Wukong、Hermes 的事件里有 `host.name` 字段，Claude Code 链路没有、只作为 OTLP resource `host.name` 与 SLS `__hostname__` 标签随出站；配了 SLS 时每批还带本机 IP（`__source__`，`src/flushers/sls-flusher.ts:340,423,522`；User-Agent 里也有，`src/utils/network-utils.ts:20`）；`host.ip` 字段只有类型定义，无人写入 | 同上，且**关掉内容采集也不删**（§5.4）；Claude Code 的 `git.*` / `workspace.*` 由 daemon 读入时富化，hook 侧那份没有（§2.1） |
| 运行状态指纹 | `ip`、`hostname`、`os_detail`、`version`、`cpu`、`mem`、`instance_id`（可逆，含 hostname、`user.id` 与数据目录路径）、`metric_json` | **daemon 每次启动发一条、之后每 12 小时一条，直发阿里云 SLS，无条件、无开关、文档零提及**（§3.5） |

注意最后一行造成的反差：**默认配置下会话内容一个字都不出本机，但主机指纹每次启动、之后每 12 小时出去一次。**
前者要显式配远端才出，后者写死在代码里。

## 1. 入口：四类，比 teamai 深一层

teamai 只有一类入口（harness 生命周期 hook）。Pilot 有四类，其中两类是 teamai 完全没有的形态。

| 类别 | 机制 | 覆盖的 Agent |
|---|---|---|
| harness hook | 写各家 settings，装 hook 脚本 | Claude Code、Codex、Cursor、Qoder 系、Qwen 系（Qwen Code CLI / Qwen Work CN）、Kiro CLI、Grok Build、WorkBuddy |
| 插件 / 扩展注入 | 往宿主配置加插件条目，插件把原生事件写本地 JSONL | OpenClaw、OpenCode、MiMo Code、Pi Coding Agent、DeepSeek Harness、Hermes Agent |
| **进程内 fetch 拦截** | `BUN_OPTIONS --preload` 注入 Claude Code 进程，拦 `/v1/messages`（Qoder CLI、Qoder Work 系另有各自的 preload / 运行时 wrapper 拦 token 与 system prompt，见 §2.4 / §5.2） | Claude Code |
| 本地数据轮询 | 读 transcript / SQLite / CLI API | Codex（`~/.codex/sessions`）、Qoder Work、Qoder IDE、Wukong、Kiro CLI、WorkBuddy 兜底 |

`agents.d/*.json` 是声明式 agent 定义（20 个文件，Wukong 走运行时发现不在其中），一个 JSON 描述检测路径、
部署方式、hook 事件与输入源。

### 1.1 Claude Code：hook 注册与分工

`agents.d/claude-code.json`：

| 项 | 值 |
|---|---|
| 部署 | `deployMode: "hook"`，写 `~/.claude/settings.json`（`:10`） |
| hook 事件 | `PreToolUse`（matcher 限 `Bash`）、`Stop`、`SubagentStart`、**`SubagentStop`**（`:11-16,20-22`） |
| hook 命令 | `$PILOT_DATA/hooks/claude-code-loongsuite-pilot-hook.sh`（`:17`） |
| 输入源 | `type: "hook-jsonl"`，落 `$PILOT_DATA/logs/claude-code`（`:29-32`） |
| 迁移 | `replaceHookCommands` 列了 `otel-claude-hook` 与 `.cache/opentelemetry.instrumentation.claude` 两类条目（`:24-27`），按命令全文精确匹配；真正按子串清掉它们的是部署前先跑的迁移（`src/deployment/plugin-migration.ts:85-88`，只在 `~/.cache/opentelemetry.instrumentation.claude/` 还在时跑）。两者清的都是 Pilot **自家上一代** Claude 插件的残留（`plugin-migration.ts:2`「清理老 Claude/Codex plugin 残留」；卸载脚本也把 `otel-claude-hook` 算作 `isOurs`，`deploy/installer-opensource.sh:1737`），不是清理别家 |

shell 脚本只做 fail-open 分发：认 4 个 subcommand（`claude-code-loongsuite-pilot-hook.sh:20-27`），
选 Node ≥ 18（`:60-156`），STDIN 原样管道给 processor（`:166`）；任何失败写
`logs/claude-code/errors/`（`:29-45`）后输出 `{}` 并 exit 0（`:12` 写明的约定，各退出点照做）——不阻断宿主。

processor 是**同步**处理，且**不落原始 hook payload**，直接产出已归一化的 GenAI 事件：

| 事件 | 实际行为 |
|---|---|
| `PreToolUse`(Bash) | **不采集任何数据**——它是写侧：打开链路传播时往 Bash 命令前注入 trace 上下文或资源属性，默认关，见 §1.4（`:298-335`） |
| `SubagentStart` / `SubagentStop` | 把元数据 append 进 `state/claude-code/sessions/<sid>.json`（`:451-458,491-508`）。payload 里的 token 数等**从不被 `exportSession` 读取**，`:550` 直接清空。`SubagentStop` 还有一个实际作用：父 `Stop` 时还没跑完的**后台子 agent**，它那一轮挂在 `pending_subagent_turns` 里，每个子 agent 的 `SubagentStop` 到了就补解析它那一份，同一轮的后台子 agent 全到齐才写盘（`:510` → `:712-757`，`completed_subagents` 做门控，`:488`） |
| `Stop` | 同步解析 transcript，写归一化事件到 `logs/claude-code/claude-code-YYYY-MM-DD.jsonl`（`:913`，`shared/event-emitter.mjs:88-94`） |

**采集发生在 `Stop`，后台子 agent 那部分延到它自己的 `SubagentStop`；数据源都是 transcript。**

### 1.2 transcript 怎么读：增量、有上限、正文零截断

- **增量**：byte offset checkpoint 存在 `state.transcript_offset`（`:784,546-549,809`；
  `claude-code/transcript-parser.mjs:137-185`，`nextOffset = fileSize`）。
- **单次上限**：待读超过 50 MB 时只读文件**尾部** 50 MB（`transcript-parser.mjs:26,155-167`）。
- **首次运行**：无 `turn_count` 且 offset 为 0 时只导出最后一个 turn（`:820-824`），不回溯历史。
- **正文零截断**：

| 字段 | 取法 | 行号 |
|---|---|---|
| 用户 prompt | 全文 | `:976-978` |
| input delta | 全文 | `:1071` |
| 模型输出 text / thinking | 全文 | `claude-code/message-converter.mjs:226,237` |
| `gen_ai.tool.call.arguments` | tool_use block 的完整 `input`（含 Bash 命令原文） | `:1169` |
| `gen_ai.tool.call.result` | tool_result 的 `content \|\| output \|\| result` 全文 | `:1185`，`transcript-parser.mjs:319-325` |

`sanitizeObject` 也没有长度上限（`agent-event-normalizer.mjs:131-144`）。全链路唯一的长度截断是
`error.message` 取 tool result 前 500 字符（`:1191-1193`）。

**工具正文覆盖所有工具，不只 Bash。** `PreToolUse` 的 matcher 限 Bash 只影响 §1.4 的注入，
采集侧从 transcript 拿全部工具的参数与结果。

### 1.2b 实测：它到底采全了没有

**结论：模型和工具这一侧采全了，人类这一侧会漏。** 拿 Pilot 自己的 `parseClaudeTranscript`，离线跑本机 50 MB 以下的
全部 transcript（主会话 37 个、子 agent 738 个；唯一一份 111 MB 的主会话超过它单次 50 MB 的读取上限，单独说），
逐类比对原始记录和解析结果里会被转成事件的字段：

| 记录类别 | 主会话·原始 | 主会话·进了事件 | 子 agent·原始 | 子 agent·进了事件 |
|---|---:|---:|---:|---:|
| 工具调用 | 15,325 | 15,325 | 42,738 | 42,738 |
| 工具结果 | 15,599 | 15,599 | 42,737 | 42,737 |
| 模型回复（按 `message.id`） | 13,996 | 13,996 | 33,769 | 33,769 |
| 模型输出文本块 | 9,275 | 9,273 | 12,697 | 12,696 |
| thinking 块 | 9,689 | 9,564 | 18,087 | 17,739 |
| 每轮第一条人类输入 | 1,599 | 1,445 | 738 | 731 |
| 同一轮里的后续人类输入 | 162 | 133 | — | — |
| 中断标记 | 213 | 5 | 26 | 9 |

漏的地方来自三种机制，都能在代码里找到：

1. **整轮没有真实模型回复，就连 prompt 一起丢。** 解析器按 user 记录自带的 `promptId` 切分轮次
   （`transcript-parser.mjs:264-267`），组装时没有模型调用的轮次直接跳过（`transcript-parser.mjs:530`）；
   Claude Code 合成的回复（`model` 为 `<synthetic>`）不算模型调用（`transcript-parser.mjs:71-73,214-216`）。
   主会话丢的 154 条 prompt 全是这一类：多数是发完就在模型回复前打断（91 轮），其余是撞上会话额度上限、
   API 报错、prompt 过长、本地斜杠命令，或紧接着就开了下一轮。
2. **排在一轮最后一次模型调用之后的人类消息不进事件。** 人类消息攒在该轮历史里，只在同一轮的下一次真实模型调用里
   作为输入增量带出去（`transcript-parser.mjs:365-460`）；用户 prompt 事件只取该轮第一条非元数据文本
   （`transcript-parser.mjs:498-510`）。中断标记正是这样丢的。按「之后同一轮里还有什么」分类，正好对上：

   | 中断记录之后，同一轮里 | 条数 | 进了事件 |
   |---|---:|---:|
   | 再没有模型回复 | 240 | 否 |
   | 只有 Claude Code 合成的「No response requested.」，被解析器跳过 | 20 | 否 |
   | 还有真实的模型回复 | 5 | 是 |

   这张表覆盖全部 27 个含中断的主会话，包括 111 MB 那份；分类按原始记录算，不受读取上限影响。
3. **同一条模型回复里有多个文本块或 thinking 块时，各只留最长的一个。** 合并内容块时，解析器把同一
   `message.id` 的多条记录当成流式快照，文本和 thinking 各保留最长的那个（`transcript-parser.mjs:570-605`）。
   一条回复里真有几个不同的 thinking 块时，其余的就丢了：主会话 21 条、子 agent 152 条非空 thinking 块是这样没的；
   另有 105 条与 196 条 thinking 块正文本来就是空的，只有签名，没有内容可丢。

另外两处限定：

- **单次待读超过 50 MB 只读尾部**（`transcript-parser.mjs:26,155-167`）。那份 111 MB 的 transcript 从头解析时，前段整个
  被跳过，其中 4 条拒绝工具调用的记录就这样没了。装机运行时每次 `Stop` 从上次的偏移处读，只有两次解析之间新增
  超过 50 MB 才会触发。
- **按设计不采的**：元数据类人类消息（主会话 166 条）、合成回复（109 条），以及 `attachment`、`system`、
  `queue-operation` 等非对话记录类型（主会话里合计三万多条；`attachment` 里具体装了什么本次没细查）。

拒绝工具调用的记录属于工具结果，按 tool_use id 单独收（`transcript-parser.mjs:318-324`），不受轮次分组影响，
所以都在，只是和机器失败一样记成 `error.type=ToolError`（`:1189-1193`）。

**统计口径**：中断标记只数整条消息就是标记本身的 user 记录，不算命令或代码里顺带提到这串文字的地方。「进了事件」
指出现在解析结果里会被转成事件的字段——该轮的 prompt、模型调用的输入增量与输出、工具调用和带结果时间戳的工具结果——
没有跑写 JSONL 的那一步。子 agent 文件是逐个单独解析的，而实际运行时 Pilot 只展开一级、只认 `toolUseResult.agentId`
链上的那些，所以子 agent 两列是上限。这是这份清单里**唯一的实测**：跑的是它的解析器，不是装机运行
（装机后的 hook 在 `Stop` 时从字节偏移处增量解析，分组逻辑相同，但没实测）。

### 1.3 subagent：它读独立文件

这是与 teamai 差距最大的一处。`resolveSubagentTranscriptPath` 拼出路径（`:113-143`）：

```
<dirname(父 transcript)>/<父 sessionId>/subagents/agent-<id>.jsonl
```

正是本项目 [DESIGN.md](../DESIGN.md):27 记录、[teamai-cli-vs-vibetrail.md](teamai-cli-vs-vibetrail.md) §3.2
实测过的那 728 个文件所在的布局。`buildSubagentRecords` 以 **offset 0 每次全量重解析**（`:641`），
子事件全部改写为父级 `trace_id` / `turn_id`，并打三个标记（`:669-685`）：

```
gen_ai.agent.scope = "subagent"
depth = 1
gen_ai.subagent.parent_tool_call.id = <父工具调用 id>
```

两条限定：

- **只展开一级**，孙级不递归（`:867-868` 注释）。
- 发现子 agent 靠 transcript 里的 `toolUseResult.agentId`（`transcript-parser.mjs:326-337`）
  加 `collectSubagentLinks`（`:145-163`），**不使用 `isSidechain`**——该字段只在 `qoderwork`、`qwen-code-cli`、`qwen-work-cn`
  三个处理器（及 `qwen-code-cli/transcript-parser.mjs`）里出现，`src/` 内为零。
  本项目 OPEN-ISSUES K1 的去重方案走 `isSidechain` / `agentId` 分层，与它的 `agentId` 路径一致。

**teamai 完全看不到这些文件**（无 `SubagentStop`、无遍历 `subagents/` 的代码路径）。
[teamai-cli-vs-vibetrail.md](teamai-cli-vs-vibetrail.md) §3.2 实测本机语料里 58% 的人类拒绝发生在子 agent 里——
Pilot 在采集范围上没有这个缺口，那节的结论只对 teamai 成立。

### 1.4 `PreToolUse` 是写侧：开了链路传播，它就改写你的 Bash 命令

**这不是采集，是注入，而且默认关。** 两个开关 `upstreamLink.enabled` 与 `upstreamLink.propagateToTools` 必须同时为 `true`
（两者默认都是 `false`，`src/core/config-loader.ts:318-322`；README 第 167 行也写 disabled），且只处理主 agent 的
`Bash` 调用（`:298-311`）。之后分两路：有可传播的 trace 上下文——进程环境里带上游的 `TRACEPARENT`（只用于第一轮，
`Stop` 后标记为已消费），或另开默认关的 `generateTraceWhenMissing`（`claude-code/tool-context.mjs:267-278`）——
就拼 `TRACEPARENT` / `TRACESTATE`，ACP 管着的会话不拼（`claude-code/tool-context.mjs:325`）；Claude Code 进程带着
`LOONGSUITE_PILOT_RESOURCE_ATTRIBUTES` 时还会拼 `OTEL_RESOURCE_ATTRIBUTES`，这一路不需要 trace 上下文（`:322-326`）。
有一样要拼，就把 `tool_input.command` 改写后回写 `updatedInput`（`claude-code/tool-context.mjs:428-447`）：

```javascript
command: `${exports.join('; ')};\n${toolInput.command}`
// exports = export TRACEPARENT='...'; export TRACESTATE='...'; export OTEL_RESOURCE_ATTRIBUTES='...'
```

值经 `shellSingleQuote()` 转义。目的是让 Bash 里启动的下游进程继承 W3C trace 上下文，把链路接起来
（`docs/zh-CN/claude-code-downstream-trace-propagation.md`）。它不产生任何事件，只在
`$PILOT_DATA/acp-correlate/` 落 trace 上下文 JSON：每次工具调用一份，必要时再加一份 turn 级的（`tool-context.mjs:36-52`）。

**记在这里是因为介入程度**：teamai 的 hook 全部是只读旁路，明确不碰用户的提交流程
（[teamai-cli.md](teamai-cli.md) §4.4）。Pilot 打开这两个开关后会修改用户即将执行的命令行。这是能力更强的必然代价，
但性质不同——它在被观测者的执行路径上。好在默认关，README 也把它写成了显式的可选项。

### 1.5 fetch 拦截：teamai 没有的形态

`assets/hooks/claude-code-fetch-intercept.mjs` 经 `BUN_OPTIONS="--preload=<file>" claude` 注入 Claude Code 进程，
拦截出站 `/v1/messages` 请求，一次 LLM 调用写一个文件到
`~/.loongsuite-pilot/intercept/claude-code/<session_id>/<response_id>.json`（`:1-4`）。本节前三段的无前缀行号都指这个拦截器文件。

取三样（`:6-18`）：

- `system_instructions` —— 从**出站请求 body** 的 `system` 字段解析，滤掉首个计费头标记块。
  **transcript 里没有这个东西**，只有拦流量才拿得到。
- `response_id` —— 首个 SSE `message_start` 的 `message.id`，与 hook 侧 1:1 join。
- `ttft_ns` —— 首个 `content_block_delta` 到达时刻。

**公平地说这个拦截器本身是有节制的**：注释明写「拿到 response_id 和 ttft_ns 之后就停止解析，透传剩余流，
保持内存有界」（`:23-24`），整体包在 try/catch 里，「这里的异常绝不能打断 Claude Code 自己的 fetch 流」
（`:25-26`）。它没有把整个请求/响应体存下来。但机制建立了——**这是一条能看到全部出站流量的通道**，
取多取少是当前实现的选择。
它也不读 Pilot 的任何配置：system prompt 全文照写，不看 `captureMessageContent`（§5.2）。

**它怎么被装上去的**：改用户的 shell rc，写进去的是一个**覆盖 `claude` 命令的 shell 函数**：

```sh
# loongsuite-pilot BEGIN claude-code-intercept
if ! alias claude >/dev/null 2>&1 && ! typeset -f claude >/dev/null 2>&1; then
  eval 'claude() { BUN_OPTIONS="--preload=<数据目录>/hooks/claude-code-fetch-intercept.mjs ${BUN_OPTIONS}" command claude "$@"; }'
fi
# loongsuite-pilot END claude-code-intercept
```

安装器只写 `$SHELL` 对应的那一个文件：zsh 写 `~/.zshrc`，其余写 `~/.bashrc`
（`deploy/installer-opensource.sh:1565-1631`）。watchdog 则两个都查，修复时往已存在的每一个里追加
（`src/core/hook-watchdog.ts:863-928`），理由写在注释里：daemon 由 launchd 启动，它的 `$SHELL` 未必等于用户交互 shell。
同形状的块一共三个：Claude Code、qodercli、qoderclicn（`hook-watchdog.ts:646-713`）。

几条限定：

- **克制的部分**：`hook-watchdog.ts:914` 「never create rc files」——rc 文件不存在就跳过，不新建；增删都靠 BEGIN/END marker 做幂等；
  用户自己已有 `claude` 的 alias 或函数时，guard 直接跳过，不覆盖。
- **但这个跳过是静默的**：安装器只在终端打一行警告，之后 system prompt 与 TTFT 这一路就缺了，hook 那一路不受影响。
  按机制推断，不经过交互 shell 启动的 Claude Code（IDE 插件、桌面端、脚本里的非交互 shell）也拿不到这个函数——
  本机未装 Pilot，没有实测。
- **watchdog 会自动修复**：手工删掉那个块，下一轮检查发现哪个 rc 里都没有块，就重新追加（`hook-watchdog.ts:898-928`）；
  按内容（`signature`）判断的那一步是为了把旧版块迁移成新版（`hook-watchdog.ts:889-891`）。rc 块的修复两次至少隔 10 分钟、
  每天最多 3 次（`hook-watchdog.ts:16,590-600`；计数只在内存里，daemon 重启就清零）。要彻底移除，得在 `config.json` 里把
  `agents.claude-code.enabled` 设为 `false`（watchdog 会顺手清掉块，`hook-watchdog.ts:556-573`）；或关掉整个 watchdog
  （`hookWatchdog.enabled: false`，`src/core/config-loader.ts:660`），此后手工删掉的块就不会再回来；或走卸载流程。
- **面向用户的文档零提及**：README 与 `docs/` 里搜不到 `zshrc`、`bashrc`、`BUN_OPTIONS`、`preload`。随包分发的运维 Skill
  倒写了（`assets/skills/loongsuite-pilot-ops/references/claude-code-diagnostics.md:121-146`），但那是写给 agent 排障用的；
  用户能看到的只有安装时终端里打印的「配置 claude-code fetch 拦截」「已写入 ~/.zshrc」两行。

## 2. 本机落盘：`~/.loongsuite-pilot/` 清单

默认数据目录 `~/.loongsuite-pilot/`（`LOONGSUITE_PILOT_DATA_DIR` 可覆盖）。

### 2.1 两份事件流

| 路径 | 内容 | 谁写 |
|---|---|---|
| `logs/<agent-id>/<agent-id>-YYYY-MM-DD.jsonl` | 已归一化的 GenAI 事件（**不是**原始 hook payload） | hook processor，同步 |
| `logs/output/<agent-id>-YYYY-MM-DD.jsonl` | 规范化事件，保留原生 JSON 类型 | JSONL flusher，**默认开**（`config-loader.ts:1148`） |

前者是 daemon 的输入源，后者是输出。两份都含内容与计数；身份与环境这层不对称——Claude Code 的 hook 侧只有 `user.id`
和原始 cwd（`agent.claude-code.cwd`，`:953-966`），`git.*` / `workspace.*` 是 daemon 读入时富化进去的
（`src/inputs/base/hook-record-transform.ts:71` → `src/normalization/enrich-git-context.ts`），所以只出现在
output 那份和出站数据里。

注入型插件（DSH、OpenClaw 等）写的是 append-only 原生事件，POSIX 上目录 `0700` / 文件 `0600`
（`docs/zh-CN/agents.md:87-88,209-211`）。

### 2.2 拦截与状态

| 路径 | 内容 |
|---|---|
| `intercept/claude-code/<session_id>/<response_id>.json` | 一次 LLM 调用一个文件，含 system prompt 全文，**不受 `captureMessageContent` 约束**；见 §1.5 / §5.2 |
| `state/claude-code/sessions/<sid>.json` | subagent 元数据；`pending_subagent_turns` 存**完整事件正文**（`:896-903`） |
| `acp-correlate/` | trace 关联记录：Bash 注入的上下文（`tool-context.mjs:36-52`，默认关），以及进程环境里带合法 `TRACEPARENT` 时各 hook 写的 session 级记录（hook 侧 `shared/upstream-context.mjs:41-60`，OpenCode 插件自带一份 `assets/plugins/opencode/plugin.mjs:446-465`） |
| `logs/input-state.json` | 各输入源的 offset / checkpoint |

### 2.3 其他

| 路径 | 内容 |
|---|---|
| `config.json` | 主配置。**SLS apiKey / AK 明文写这里**，文档自己提示「确保文件权限合适，不要分享」（`docs/zh-CN/configuration.md:58`） |
| `agent-control.json` | 每个 agent 的 `on` / `off` / `auto` 准入 |
| `deployed-agents.json` | 已部署的 hook 与插件记录 |
| `hooks/` `plugins/` | 安装的 hook 脚本与插件资产 |
| `logs/sls-failed-logs/` | SLS 上传失败诊断 —— **只有 endpoint、错误摘要、batch 条数与字节数估算，不含 payload、消息正文、请求头、凭证**，明确「不能用于重放失败数据」（`docs/zh-CN/sls-output.md:154`） |
| `logs/otlp-failed/` `logs/otlp-debug/` `logs/metric_alarm/` | OTLP 失败 / 调试、指标告警 |
| `versions/` `current` | 版本目录与回滚指针 |
| `token-usage-state.json` | 覆盖写状态，不参与清理 |

`logs/sls-failed-logs/` 那条是**设计亮点，且正好是 teamai 的反面**：teamai 的 `reporter/errors.jsonl` 在
HTTP 上报失败时把整个 context（含 `promptSummary`、`stoppedOutput`、`transcriptPath`、`cwd`）原样写盘
（[teamai-cli-collection.md](teamai-cli-collection.md) §2.8）。同一个「失败要留证据」的需求，一个存了内容，
一个明确不存。

### 2.4 保留策略：覆盖不全

`retention` 七类，默认各 7 天（`src/types/index.ts:377-383`，`docs/zh-CN/configuration.md:205-233`）。
容量水位：单个 output 文件 > 512 MiB 且超 2 天可提前清理；`logs/output` > 2 GiB 从旧日期删起；
当天与昨天始终保留。

⚠️ **Claude Code 那份 hook 事件流不被任何保留策略覆盖。** `CATEGORY_DIR_MAP` 只认
history / errors / debug / output / sls-failed-logs / otlp-failed / metric_alarm
（`src/core/log-retention-service.ts:49-57`）；`logs/claude-code/` 走 `cleanSubdirectories`（`:130-134,148-170`）
**只清这几个名字的子目录**，根下的 `claude-code-YYYY-MM-DD.jsonl` **永不删除**——而那正是含完整对话正文的文件。
daemon 侧只推进 offset，不删文件（`src/inputs/base/base-hook-input.ts:66-131`）。
同目录的 `errors/` 反而有 7 天保留。

这个洞按**文件写在哪**分，不是每家都有：

| 写在哪 | 谁 | 清理 |
|---|---|---|
| `logs/<agent>/` 根下 | Claude Code、Kiro CLI、Grok Build、Qwen Code CLI；插件注入型的 OpenCode、OpenClaw、MiMo Code、Pi Coding Agent、DSH | **永不删除** |
| `logs/hermes-agent/` 根下 | Hermes Agent | 插件自己按 mtime 删 7 天前的（`assets/plugins/hermes-agent/loongsuite-pilot/__init__.py:38,921-929`） |
| `logs/<agent>/history/` | Qoder、Qoder CN、Qoder Work、Qoder Work CN、Qwen Work CN、Cursor | `hookHistoryDays`，默认 7 天 |
| `logs/` 根下的 `*-intercept.jsonl` | Qoder CLI（`qodercli-` / `qoderclicn-`）与 Qoder Work 系（`qoderwork-` / `qoderworkcn-` / `qwenworkcn-`）的拦截文件，含 system prompt 与 token 记录（§5.2） | 保留服务不管，它只处理 `logs/` 下的目录（`log-retention-service.ts:120-123`）；读取方在文件超过 10 MB 时轮转一次、删掉上一份 `.old`（`src/inputs/qoder-trace/intercept-token-reader.ts:45-51`），所以有体积上限、没有时间上限。**`qoderworkcn-intercept.jsonl` 在 `src/` 里没有读取方**，连这个轮转也没有 |

其余三处的清理情况：

- `intercept/`：只有**机会性清理**——Stop 时删已合并的（`:208-214`）、删同 session 目录内 mtime > 1h 的
  （`:222-235`）。session 不再触发 Stop 时残留无人清；`src/` 内无任何 intercept 清理代码。
- `state/claude-code/sessions/`：`state.mjs:141` 注释称供 hook-watchdog 清理，但 `src/` 内**无调用者**；hook 自己只在
  `SubagentStop` 时删子 agent 的 state（`state.mjs:129-139`）——主会话 state 未确认有清理。
- `acp-correlate/`：有专门的清理服务（`src/core/upstream-link/acp-correlate-retention-service.ts`，按 mtime，
  6 小时扫一次，TTL 默认 24 小时，`config-loader.ts:316`），但**只在 `upstreamLink.enabled` 时启动**
  （`orchestrator.ts:227-234`）。写入方却不看这个开关：Claude Code、Codex、Qwen Code CLI、Qoder 的 hook 和 OpenCode 插件
  只要进程环境里有合法的 `TRACEPARENT`，就写一份 session 级关联记录（hook 侧 `shared/upstream-context.mjs:41-60`，
  OpenCode 插件自带一份 `assets/plugins/opencode/plugin.mjs:446-465`）。
  默认配置下这种情况少见，一旦发生就是有写无删。

## 3. 出本机的部分

默认**不出本机**：JSONL 是唯一默认开的输出，SLS / HTTP / OTLP 都要显式配置。但企业接阿里云 AgentLoop 控制台（外部资料；仓内只在 `solutions/` 看板模板的 SLS project 占位名 `agentloop-xxx` 里出现）的场景
就是配了，配上之后出去的是**整份规范化事件**，不是摘要。

### 3.1 SLS（阿里云日志服务）—— 主通道

`src/flushers/sls-flusher.ts`。三种鉴权：WebTracking、AK/SK、API Key（protobuf 直写
`POST /logstores/{logstore}/shards/lb`）。支持数组配置同时发多个目标。
开关 `collectLog` / `LOONGSUITE_PILOT_COLLECT_LOG=false`。

出站只有一道裁剪 `dropAgentScopedFields: true`（`:205`），丢的是 agent 私有扩展字段。
**内容字段全部原样送出**，原因见 §5.1。

### 3.2 HTTP 自定义端点

`src/flushers/http-flusher.ts:77` —— `axios.post(url, { topic, ...payload })`，整条事件进 body。
配了 `url` 就自动开（`config-loader.ts:1169` `enabled ?? !!url`），批量 20 条 / 5 秒。

### 3.3 OTLP Trace

`src/flushers/otlp-trace-flusher.ts:581-584`：`captureMessageContent !== false` 时设
`OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = 'SPAN_ONLY'`，消息内容进 span 属性。开关 `collectTrace`。

### 3.4 多模态对象存储 —— 图片真出本机

开启后（默认 `uploadMode: none`）把消息与工具结果里的图片上传到 OSS 或 SLS，事件里只留
`oss://bucket/prefix/YYYYMMDD/<sha256>.ext`。

**当前只有 `codex` 和 `qoder`（IDE 与 CLI）实现**，Claude Code 配了也不生效（`docs/zh-CN/multimodal.md:21`）。
Qoder 那条链路会**读本地磁盘上的图片文件**（`pathToUri`），范围限定在 `allowedRootPaths` 白名单加各 agent 默认根。

上传是写时乐观的：事件先带 `uri`，上传异步进行，队列满 / 失败 / 进程关停超时（约 1.5s）都可能导致对象永远不存在，
且**不会重放补传**（`multimodal.md:169-181`）。文档对这个取舍写得很坦白。

### 3.5 Pilot 自身有一条未声明的回传 —— 而且是开源版专属

⚠️ **本文第一版写的「Pilot 自身不回传」是错的，已推翻。** 那次只 grep 了 `src/updater/` 与 `src/core/`，
漏了 `src/internal/` 与 `src/metrics/`——范围太窄就下结论，和 teamai 那三份文档附录里记的第 1、8 条同款错误。
台账见 §7。

事实（`src/internal/statistic.ts`）：

```
:3-5    ENDPOINT  = https://cn-shanghai.log.aliyuncs.com
        PROJECT   = loongsuite-community-edition
        LOGSTORE  = loongsuite-online
:10     SEND_INTERVAL_COUNT = 72   // L1 每 10 分钟一次 → 每 12 小时发一条；计数从 0 起，启动即发
:12-21  SELECTED_FIELDS = cpu, mem, version, instance_id, ip, hostname, os_detail, metric_json
:35-38  POST __topic__: 'pilot_running_status'
```

调用点 `src/metrics/metrics-writer.ts:177` —— `sendRunningStatus(flattenToStrings(metrics))`，
**无条件执行**。全仓 grep 不到任何环境变量或配置键能关掉它。

发送节奏要补一句：`callCount` 从 0 起算（`statistic.ts:23-26`），而 `MetricsWriter.start()` 启动时就立即跑一次 L1
（`metrics-writer.ts:113`），所以**每次 daemon 启动先发一条**，之后才是每 12 小时一条——升级、重启越频繁，发得越多。
代码注释并不讳言这条外发：`src/core/orchestrator.ts:349` 写着「→ local JSONL + remote via sender.ts」。

`instance_id` 的构造（`src/metrics/metrics-collector.ts:494-500`）注释自陈可逆：

```javascript
this.instanceId = `${this.hostname}_${opts.userId}_${dataDirEncoded}`;
// dataDir is base64url-encoded (not plaintext) but remains reversible: strip the
// `${hostname}_${userId}_` prefix and base64url-decode to recover the path.
```

它还嵌了 `user.id`：没配时就是 hostname，配了就是你填的员工标识。`user_id` 本身不在 `SELECTED_FIELDS` 里，
经 `instance_id` 照样出去。

**「开源版专属」这一点要说清楚**，因为它反直觉。`src/internal/sender.ts:7-19` 按构建模式二选一：

| 构建 | `sendRunningStatus` 走哪个 | 实际行为 |
|---|---|---|
| `BUILD_MODE=proprietary` | `statistic.internal.js` | 闭源实现；`build.mjs:22-25` 的 stub 只 filter `/statistic\.internal/`，对它生效 |
| **开源（默认）** | `statistic.js` | **上面那段真实现** |

也就是说 stub 插件 stub 的是闭源分支，而开源构建根本不 import 那个分支。同目录的
`alarm-sender.ts`（开源版）两个函数**都是空的**：

```javascript
export function sendAlarm(_topic, _data) {}
export function sendStatus(_topic, _data) {}
```

**告警和状态上报在开源版都被清空了，唯独留下了 `sendRunningStatus`。** 这不像疏漏，像选择。

公平地说：payload 里只有计数与尺寸指标，**不含任何会话内容、prompt、代码或仓库信息**。
但它是**主机标识级别**的回传——IP、hostname、OS 详情，加一个能还原出本机数据目录路径的 id。

README 与 `docs/` **零处提及**。（搜 `community-edition` 命中的全是安装器的 OSS 下载地址
`loongcollector-community-edition.oss-cn-shanghai.aliyuncs.com`——与回传目标 SLS project
`loongsuite-community-edition` 名字相近但是两回事，别混淆。）

`src/updater/updater.ts:60,64` 那条确实只是**下载**：从
`aliyun-observability-release-cn-shanghai.oss-cn-shanghai.aliyuncs.com` 取 node 与 node-modules 依赖，不上传。

## 4. 明确不采（已 grep 核实）

| 项 | 依据 |
|---|---|
| 工作区源码文件内容 | 事件字段里没有文件内容。唯一读工作区文件的是多模态图片链路（`pathToUri`，限白名单根、限图片 magic），且仅 Codex / Qoder。注意：**工具参数与结果里天然含代码**（Read 的返回、Edit 的 old/new string），那是 transcript 内容，不算额外读盘 |
| commit hash / diff（本机链路） | 本机采集无任何 commit 字段。全仓 commit 相关只在 `src/pipeline/input/qoder-api/`——从 **Qoder 服务端 API** 拉的组织级数据，不是本机采的，见 §5.5（另有一个零引用的 `GitHookEvent` 类型，见[分析文档](loongsuite-pilot.md) §6） |
| git hook / `core.hooksPath` | 全仓无安装 git hook 或改 `core.hooksPath` 的代码 |
| 环境变量快照 | 不整体快照，读的是有名有姓的几类：自己的 `LOONGSUITE_PILOT_*`、各 agent 的 home 定位变量、白名单内的 `AGENTTEAMS_WORKER_NAME` / `AGENTTEAMS_INSTANCE_ID`（`output-event-schema.md:154` 明写其他 `AGENTTEAMS_*` 不进事件），W3C 的 `TRACEPARENT` / `TRACESTATE`（做链路关联，落 `acp-correlate/`，§2.2）、`OTEL_SPAN_ATTRIBUTES`（`src/core/config-loader.ts:466-474`），以及几个插件拿来兜底 `user.id` 的 `LOONGSUITE_USER_ID` |
| 孙级 subagent | 只展开一级（`:867-868`） |

**不在这张表里的**：Pilot 自身的运行状态回传。本文第一版把它列在这里，是错的，见 §3.5。

## 5. 六条值得单独记的

### 5.1 出站脱敏兜底是死代码

`src/normalization/entry-builder.ts:294` 有一个 `redactCodeGenerationFields()`，删的是大部分内容字段外加两个 id
（`REDACTED_FIELDS` 共 17 项，`:182-197`）：

```
gen_ai.input.messages / messages_delta / output.messages
gen_ai.tool.call.arguments / result
input.messages / messages_delta / output.messages / tool.arguments / tool.result.payload   ← 旧别名
agent.content / agent.inline_diff_message
filePath / content / inlineDiffMessage
recorduuid / distinctid                                                                    ← id，不是内容
```

这其实是**第三份**内容字段清单，和 §5.2 那两份又不一样：没有 `gen_ai.system_instructions`、`gen_ai.tool.definitions`、
`gen_ai.input.multimodal_metadata`、`error.message`——就算哪天开了，system prompt 照样出去。

唯一调用点是 `src/flushers/sls-flusher.ts:210-212`，条件是 `endpoint.redact`。而**全仓只有两处给 `redact`
赋值，都硬编码 `false`**（`config-loader.ts:951` 数组配置的 `sls-<index>`、`:1091` 单目标 `user-sls`），
没有任何从配置文件或环境变量读取的路径。

**结论：这个函数永远不执行，SLS 出站不做内容裁剪。** 内容管控实际只有入口一道
（`captureMessageContent`）——这和 teamai 正好相反：teamai 是入口不脱、出口脱
（[teamai-cli-collection.md](teamai-cli-collection.md) §2.1），Pilot 是入口能关、出口那道兜底关着。

不排除它是给服务端下发配置预留的位置。但按 HEAD `d4ab8b6d` 的代码事实，它不生效。

### 5.2 `error.message` 绕过内容开关

内容策略在两处执行，各有一份 `MESSAGE_CONTENT_FIELDS` 清单：

| 侧 | 文件 | 项数 |
|---|---|---|
| hook（落盘前） | `assets/hooks/agent-event-normalizer.mjs:7-22` | 14 |
| daemon（出站前） | `src/normalization/agent-content-policy.ts:8-26` | 17 |

**两份清单都不含 `error.message`。** 而 `:1191-1193` 在工具失败时写入
`error.message = resultContent.slice(0, 500)`——即**工具结果正文前 500 字符**。
`src/inputs/base/hook-record-transform.ts:68` 还显式透传它。

所以：设了 `captureMessageContent: false` 之后，工具**成功**时的结果不落盘，工具**失败**时仍有最多
500 字符的结果正文落盘并出本机。工具失败的正文里常常正是报错的文件路径、命令输出、堆栈——
按敏感度排序未必比成功路径低。

`docs/zh-CN/agents.md:277` 称该开关「可避免采集……工具结果」，这一条上不准确。

**同类的还有几类拦截文件，也都不看这个开关**，只是不出本机：

- Claude Code 的 fetch 拦截器（§1.5）不读任何配置，每次 LLM 调用都把 system prompt 全文写进
  `intercept/claude-code/<session_id>/<response_id>.json`。内容策略要等 `Stop` 合并时才执行（`:604`），
  合并后删文件（`:208-214`），合不上的等同一 session 下次导出时按 mtime > 1 小时清（`:222-235`）；
  session 不再触发 `Stop` 就一直留着。
- Qoder CLI 的 preload 脚本（`assets/hooks/qodercli-token-intercept.mjs:79-95`）和 Qoder Work 系（QoderWork / QoderWork CN /
  QwenWork CN）的运行时 wrapper（`assets/hooks/qoderwork-runtime-wrapper.mjs:41-60,107-118`）都在每个进程里抓一次
  system prompt，连同 token 记录追加到 `logs/` 根下的 `*-intercept.jsonl`；这些文件多数只有体积上限，`qoderworkcn-intercept.jsonl` 连这个都没有，见 §2.4。

合起来说明同一件事：**开关管的是管线里的一个环节，不是数据落盘的全部路径。**

### 5.3 两份策略清单不一致，本机与出站口径不同

daemon 侧比 hook 侧多三项：`gen_ai.input.multimodal_metadata`、`gen_ai.system_instructions`、
`gen_ai.tool.definitions`。

后果是 `gen_ai.system_instructions` 在**本机 JSONL 里键还在**（只因嵌套 `content` 被 `MESSAGE_CONTENT_SOURCE_KEYS`
删掉而剩 `[{"type":"text"}]`），只有走 daemon 出站时才整键删除。
`docs/zh-CN/output-event-schema.md:126` 称关闭内容采集时「该字段整体缺失」——对出站成立，对本机不成立。

另有一条口径差异值得区分：`docs/zh-CN/agents.md:90` 在 DSH 语境下说「`captureMessageContent` 只控制归一化输出，
不会删除源日志中的内容」——那是注入型插件（DSH、OpenClaw）的情况，它们的源日志
`logs/dsh/`、`logs/openclaw/` 里完整消息照样在。**Claude Code 相反**：策略在 hook 落盘前就执行（`:604`），
源头就不写。同一个配置项在两类接入方式下行为不同。

### 5.4 关掉内容采集也留路径与仓库身份

`output-event-schema.md:122` 明写：即使 `captureMessageContent: false`，`workspace.*` 和可推断的 `git.*`
**也会保留**，理由是「该上下文不属于消息内容」。`masking.md:120` 同向：「Git 分支、workspace 路径等稳定元数据
不作为密钥内容字段扫描」。

具体采法（`src/utils/git-context.ts:48-51`，1.5s 超时、TTL 缓存、逐命令 catch 允许部分成功）：

```
git rev-parse --show-toplevel        → workspace.current_root
git rev-parse --abbrev-ref HEAD      → git.branch
git config --get remote.origin.url   → git.repo + git.domain（归一化后）
```

**`remote.origin.url` 意味着团队仓库身份随每条事件出本机**，加上 `workspace.path` 的 cwd 绝对路径
（带用户名与项目名）。teamai 那边同类问题只在手动 `session save --push` 一条路径上
（[teamai-cli-collection.md](teamai-cli-collection.md) §5 第 5 条），这里是每条事件都带。

### 5.5 Qoder 链路上有 commit 级的 AI 行数归属

`src/pipeline/input/qoder-api/` 每轮拉十来个组织级接口，写出十四种记录（`usage.*` 五种、`code.*` 九种，
`qoder-api-input.ts:149-340`）。和代码归属有关的是下面三种，别混：

```
code.tracking_change   逐次 AI 改动一条：接口 …/ai-code-tracking/changes（client :251），记录 qoder-api-input.ts:647-680
  change_id / change_source / model / lines_added / lines_deleted / member_id / member_email / raw_json / metadata_json
code.tracking_commit   逐 commit 一条：接口 …/ai-code-tracking/commits（client :278），记录 qoder-api-input.ts:688-729
  commit_hash / commit_ts / commit_message / repo_name / branch_name
  member_id / member_email / raw_json
  total_added / non_ai_added / ide_agent_added / cli_agent_added / plugin_agent_added / ide_inline_chat_added …（各带 _deleted）
code.stats_overview    组织时间窗聚合：接口 …/ai-code/stats/overview（client :379-392），记录 qoder-api-input.ts:866-881
  committed_total_lines_edit / committed_ai_lines_edit / accepted_lines_edit …
```

**逐 commit 那条是 commit ↔ AI 代码行数的关联**，三方工具里只在这里见到实现。四条限定：
它是从 **Qoder 组织级服务端 API 拉的**，不是本机采集；只在 Qoder 生态内，Claude Code 链路完全没有；
归属到的是来源类别（IDE agent / CLI agent / 行内补全…）的**行数**，不是具体哪几行，也没有任何会话字段；
整条链路挂在默认关的 `PipelineManager` 下（`pipeline.enabled` 默认 `false`，`config-loader.ts:676-691`），
还要在 pipeline 配置里填组织 `OrgId` 与 `ApiKey`，默认安装不会有这批数据。
另外逐 commit 记录带着**成员邮箱与 commit message**，配了就随 SLS 出去。
详见 [teamai-cli-vs-vibetrail.md](teamai-cli-vs-vibetrail.md) §5.1。

### 5.6 `user.id` 默认是机器 hostname

`config-loader.ts:274` —— `env('LOONGSUITE_PILOT_USER_ID') ?? file?.userId ?? file?.['user.id'] ?? os.hostname()`。
`user.id` 是 schema 里的 **Required** 字段，随每条事件出本机。不配置就等于用主机名当员工标识——
在公司发的机器上，hostname 常常本身就带姓名或工号。

另外 OpenClaw 链路带 `agent.openclaw.account.id` / `channel.id` / `sender.id`，是 IM 渠道的用户身份；
`agent.openclaw.session_key` 文档明写「可能包含渠道用户/群组标识」，且**关闭内容采集不移除这项元数据**
（`output-event-schema.md:19-20`）。

## 6. 对本项目的参照

- **三分法在这里依然成立，但分界线要重画。** teamai 那份的「计数出本机、文本留本机」在 Pilot 上不适用——
  它的分界线是「配没配远端」，配了就全出去。本项目 OPEN-ISSUES K6（trace 自由文本零脱敏）值得借鉴的是
  Pilot 的**两层控制模型**：`captureMessageContent`（入口，决定采不采）与 `mask`（出口，决定密钥擦不擦）
  分开，比单一开关表达力强。但要连它的教训一起吸取——**出口那层要有测试守着，否则就是 §5.1 那种死代码；
  字段清单要有单一真相源，否则就是 §5.2 / §5.3 那种漏项与不一致。**
- **`sls-failed-logs` 的做法值得直接抄**：失败诊断只留元数据、明确写「不可用于重放」。本项目将来若有上报失败
  路径，默认应当是这个形态，而不是 teamai 那种把整个 context 写盘。
- **保留策略要按目录枚举，不能按类别映射。** §2.4 那个洞的成因是 `CATEGORY_DIR_MAP` 只认几个子目录名、
  又跳过 `logs/` 根下的文件，于是 Claude Code 等写在根下的、含完整对话正文的文件永不删除——而所有配置项看上去都配好了。本项目 trace 目录若将来加清理，
  应当默认覆盖全部子目录，新增目录不进清单就报错，而不是静默漏过。
- **采集范围要有回归钉子，Pilot 守住了一半。** Pilot 装了 `SubagentStop` 而 teamai 没有；Pilot 还有测试钉住提取层——
  `tests/unit/hooks/claude-code/hook-processor.test.mjs` 的「claude-code 一级子 Agent 上报」一组用例（`:725` 起）断言
  导出记录里必须有 `gen_ai.agent.scope = subagent`，删掉子 agent 展开就红；但 Claude Code 这边没有测试钉住部署层必须注册 `SubagentStop`（Codex 那边有，
  `tests/unit/hooks/codex/hook-processor.test.mjs:52-61`）。而且它钉的是「子 agent 展开了」，没钉「每类记录走到了输出」——
  中断记录在主会话里就被静默丢了（§1.2b），这种缩水文件级的钉子抓不到。
  teamai 与本项目两层都没有，这正是 [teamai-cli-vs-vibetrail.md](teamai-cli-vs-vibetrail.md) §7 第 2 条提的问题——
  判据有测试，范围没有（已立为 OPEN-ISSUES G10）。

## 7. 本文的审计记录（2026-09-10）

初稿写完后逐条回查代码，**2 处断言被推翻或补全**（第 1–2 条）；同日第二轮独立复核又改了 **8 处**（第 3–10 条）；第三轮对修正再做独立复核，又推翻 **2 处**（第 11–12 条）；第四轮改做逐类完整性实测，补 **1 处**（第 13 条）。
均已改在正文，此处只留台账——这份文档自己也该有留痕。

| # | 初稿的说法 | 核实结果 | 落在 |
|---|---|---|---|
| 1 | 「Pilot 自身不回传，没有安装遥测或版本上报」 | **错，且方向相反**。`src/internal/statistic.ts` 每 12 小时向固定阿里云 SLS 发 `ip` / `hostname` / `os_detail` / `instance_id`（可逆，含数据目录路径），无条件、无 opt-out、文档零提及；而且是**开源版专属**（闭源版走 `.internal` 分支）。初稿只 grep 了 `src/updater/` 与 `src/core/`，漏了 `src/internal/` 与 `src/metrics/` | §0 三层表 / §3.5 / §4 |
| 2 | 「`intercept/` 与 `logs/<agent-id>/` 的清理路径未在本次扫描中确认」 | 已查明：`logs/claude-code/` 根下的 jsonl **永不删除**（`CATEGORY_DIR_MAP` 漏了该目录，`cleanSubdirectories` 只清子目录）；`intercept/` 只有 Stop 时的机会性清理；`state/` 与 `acp-correlate/` 仍未确认 | §2.4 |
| 3 | 第二轮：「`PreToolUse` 改写你的 Bash 命令」，写成装上就有 | **漏了默认值**：`upstreamLink.enabled` 与 `propagateToTools` 默认都 `false`，两个都开才注入。初稿回查过注入代码，没查决定它会不会发生的开关 | §1.1 / §1.4 |
| 4 | 同轮：「真正的采集全部发生在 `Stop`」 | 不全：父 `Stop` 时还没跑完的后台子 agent，要等这些后台子 agent 的 `SubagentStop` 都到了才补齐、写盘 | §1.1 |
| 5 | 同轮：「hook 侧那份事件流永不删除」写成通例；「`acp-correlate/` 清理机制未确认」 | 前者只对写在 `logs/<agent>/` 根下的那些 agent 成立，Qoder 系、Qwen Work CN、Cursor 写在 `history/`，受 `hookHistoryDays` 管；另查出 Qoder CLI、Qoder Work 系落在 `logs/` 根下的拦截文件不归保留服务管，只靠读取方 10 MB 轮转，`qoderworkcn-intercept.jsonl` 连轮转都没有；Hermes 插件自己删 7 天前的日志。后者有清理服务，但只在 `upstreamLink.enabled` 时启动，写入方不看这个开关 | §2.4 |
| 6 | 同轮：身份层列了 `host.name` / `host.ip`，并称两份事件流「都含 §0 三层的全部字段」 | `host.ip` 全仓无人写入；Claude Code 的事件里没有 `host.name`，hostname 走 OTLP resource 与 SLS 标签；Claude Code 的 `git.*` / `workspace.*` 由 daemon 富化，hook 侧那份没有；另补：配了 SLS 时每批还带本机 IP | §0 / §2.1 |
| 7 | 同轮：回传「每 12 小时发一条」；`instance_id`「含数据目录路径」 | 计数从 0 起、启动即跑一次 L1，所以每次启动先发一条；`instance_id` 还含 `user.id` | §0 / §3.5 |
| 8 | 同轮：rc 块「往 `~/.zshrc` 和 `~/.bashrc` 各追加」「qodercli 与 claude-code 两个目标」、删块后「按内容判定不健康」 | 安装器只写 `$SHELL` 对应的一个，watchdog 修复时才两个都写；目标是三个；删块是按「块不在」判的，按内容那步是迁移旧版块。另补：用户已有 `claude` alias 时静默跳过；三类拦截文件不受内容开关约束；面向用户的文档零提及，只有随包的运维 Skill 写了 | §1.5 / §5.2 |
| 9 | 同轮：Qoder 链路「条目带 `commit_hash` … 以及 `committed_ai_lines_edit`」「行级归属」 | 混了两种记录：逐 commit 那条是分来源的增删行数，`committed_*_lines_edit` 在组织时间窗聚合里；归属的是行数不是「哪几行」；两种记录来自两个接口；整条链路默认关 | §5.5 |
| 10 | 同轮：§1.1 把 `replaceHookCommands` 写成「抢占」别家的 `otel-claude-hook` 等条目 | **错**：那是 Pilot 自家上一代 Claude 插件的残留（`plugin-migration.ts:2`「清理老 Claude/Codex plugin 残留」，卸载脚本也把它算作 `isOurs`），是迁移不是抢占。OPEN-ISSUES G7 ⑥ 据此推出的「settings 是多方争抢的位置」同日撤回 | §1.1 |
| 11 | 第三轮：§6「两边都没有测试守住采集范围」 | **错**：Pilot 有提取层测试（`hook-processor.test.mjs:725` 起），Codex 还有部署层测试钉住 `SubagentStop`；Claude Code 缺的只是部署层 | §6 |
| 12 | 同轮：「正文零截断」「采的是完整对话内容」，隐含每条记录都进了事件 | **不全，而且漏的正好是本项目关心的**：解析器按 promptId 分组，轮末的中断记录大多不进事件。拿它的解析器离线跑本机语料，265 条中断记录只进了 5 条（之后同一轮里再没有模型回复的 240 条、只跟了被跳过的合成回复的 20 条都没进）；拒绝工具调用的 45 条进了 41 条 | §0 / §1.2b |
| 13 | 第四轮（按用户要求改用 50 MB 以下的数据，逐类测完整性）：第 12 条只查了中断和拒绝两类 | 扩到全部记录类型后又找到两种漏法：整轮没有真实回复就连 prompt 一起丢（主会话 1,599 条 prompt 丢 154 条），同一回复里多个文本 / thinking 块只留最长的；第 12 条里拒绝记录「45 条进了 41 条」差的 4 条是那份 111 MB 的文件撞上读取上限，50 MB 以下的语料里工具结果一条不差 | §0 / §1.2b |

另有十来处行号与小项顺手改了：`:869` 实为 `:867-868`、`state.mjs:143` 实为 `:141`、拦截器注释 `:23-24` / `:25-26`、
`statistic.ts` POST `:35-38`、`isSidechain` 实际出现在哪三个处理器、`REDACTED_FIELDS` 是 17 项含两个 id、
入口表补 Codex 与 Qwen Work CN、环境变量补 `TRACEPARENT` / `TRACESTATE`、fail-open 的行号。

第 1 条的教训和 teamai 那三份文档附录里的第 1、8 条同款：**范围没扫全就下结论**。
「grep 不到」只有在 grep 覆盖了全仓时才是证据——初稿把两个目录的 grep 结果当成了全仓结论。
代价是这条恰好是全文最重的发现之一，差点写反。

第 3、7、8 条是另一类错：**读到机制就写进结论，没顺手查它的开关默认值、触发时机和作用范围**。
第 3 条最典型——初稿的局限说明里原本写着「关键断言（TRACEPARENT 注入……）由我逐条回查原文」，查的是注入代码本身，
恰恰漏了决定它会不会发生的那两个开关。第 5 条则是**把一条链路写成全体**：Claude Code 的日志在根目录，
就默认 21 家都在根目录。第 10 条是**没查出处就定性**：看到它删别的条目就当成抢占，没去翻那两个字符串是谁的。

第 12 条是这份清单分量最重的一次推翻，也是第一次靠**跑代码**而不是读代码推翻的。前两轮都逐字段核了
「prompt 全文」「input delta 全文」这些取值点，却没人问：哪些记录根本走不到这些取值点？读码能证明一个字段取了什么，
证明不了分组逻辑漏掉了哪些记录。**逐字段核对不等于逐记录核对。**

**这份文档的局限**：除 §1.2b 那次离线跑解析器之外全部读码所得，本机未装 Pilot，没有实机数据可对照——所有关于运行时行为的结论
（发送周期、清理时机、watchdog 修复）都是从代码推的，没有实测。
初稿的核实方式是两个独立 agent 分头扫代码，关键断言由我逐条回查原文。第二轮补上了独立复核：
三个 agent 分头逐行核对三份 Pilot 文档的行号、数字与行为断言，改进正文前我逐条回查了源码。
复核本身也出过一处错：它一度认定「卸载清单漏了 Grok」，实际安装器另有一段单独清理 Grok
（`installer-opensource.sh:2347-2403`），没有写进正文。
