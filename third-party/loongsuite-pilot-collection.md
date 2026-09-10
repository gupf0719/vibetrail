# LoongSuite Pilot 采集清单

> 三方项目分析，**不是**本项目的一部分。配套文档：[loongsuite-pilot.md](loongsuite-pilot.md)（项目分析）、
> [teamai-cli-vs-vibetrail.md](teamai-cli-vs-vibetrail.md)（三方对比）。
>
> 快照 HEAD `d4ab8b6d`（2026-09-08），仓在 `/Users/gupengfei/program/go/src/loongsuite-pilot`，行号均指向该快照，
> **引用请带日期**。全部读码所得；本机未装 Pilot（`~/.loongsuite-pilot` 不存在，`~/.claude/settings.json`
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

分三层看：

| 层 | 内容 | 去向 |
|---|---|---|
| 内容 | `gen_ai.input.messages` / `messages_delta`、`gen_ai.output.messages`（含 reasoning）、`gen_ai.system_instructions`、`gen_ai.tool.call.arguments`、`gen_ai.tool.call.result` | 本机 JSONL 默认开；配了 SLS / HTTP / OTLP 就**整份出本机** |
| 计数与指标 | token 五项 + 四项成本、TTFT、工具耗时、finish reason、请求/响应模型名、`messages_hash` | 同上 |
| 身份与环境 | `user.id`（**默认取 hostname**）、`host.name` / `host.ip`、`workspace.path`（cwd 绝对路径）、`git.repo` / `git.branch` / `git.domain` | 同上，且**关掉内容采集也不删**（§5.4） |
| 运行状态指纹 | `ip`、`hostname`、`os_detail`、`version`、`instance_id`（可逆，含数据目录路径）、`metric_json` | **每 12 小时直发阿里云 SLS，无条件、无开关、文档零提及**（§3.5） |

注意最后一行造成的反差：**默认配置下会话内容一个字都不出本机，但主机指纹每 12 小时出去一次。**
前者要显式配远端才出，后者写死在代码里。

## 1. 入口：四类，比 teamai 深一层

teamai 只有一类入口（harness 生命周期 hook）。Pilot 有四类，其中两类是 teamai 完全没有的形态。

| 类别 | 机制 | 覆盖的 Agent |
|---|---|---|
| harness hook | 写各家 settings，装 hook 脚本 | Claude Code、Codex、Cursor、Qoder 系、Qwen Code CLI、Kiro CLI、Grok Build、WorkBuddy |
| 插件 / 扩展注入 | 往宿主配置加插件条目，插件把原生事件写本地 JSONL | OpenClaw、OpenCode、MiMo Code、Pi Coding Agent、DeepSeek Harness、Hermes Agent |
| **进程内 fetch 拦截** | `BUN_OPTIONS --preload` 注入 Claude Code 进程，拦 `/v1/messages` | Claude Code |
| 本地数据轮询 | 读 transcript / SQLite / CLI API | Qoder Work、Qoder IDE、Wukong、Kiro CLI、WorkBuddy 兜底 |

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
| 抢占 | `replaceHookCommands` 会**替换掉** `otel-claude-hook` 与 `.cache/opentelemetry.instrumentation.claude` 两类既有条目（`:24-27`） |

shell 脚本只做 fail-open 分发：认 4 个 subcommand（`claude-code-loongsuite-pilot-hook.sh:20-27`），
选 Node ≥ 18（`:60-156`），STDIN 原样管道给 processor（`:166`）；任何失败写
`logs/claude-code/errors/` 后输出 `{}` 并 exit 0（`:29-45`）——不阻断宿主。

processor 是**同步**处理，且**不落原始 hook payload**，直接产出已归一化的 GenAI 事件：

| 事件 | 实际行为 |
|---|---|
| `PreToolUse`(Bash) | **不采集任何数据**——它是写侧：注入 trace 上下文，见 §1.4（`:298-335`） |
| `SubagentStart` / `SubagentStop` | 只把元数据 append 进 `state/claude-code/sessions/<sid>.json`（`:451-458,491-508`）。payload 里的 token 数等**从不被 `exportSession` 读取**，`:550` 直接清空；唯一实际作用是 `completed_subagents` 门控后台补采（`:488,712-740`） |
| `Stop` | 同步解析 transcript，写归一化事件到 `logs/claude-code/claude-code-YYYY-MM-DD.jsonl`（`:913`，`shared/event-emitter.mjs:88-94`） |

**真正的采集全部发生在 `Stop`，数据源是 transcript。**

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

- **只展开一级**，孙级不递归（`:869` 注释）。
- 发现子 agent 靠 transcript 里的 `toolUseResult.agentId`（`transcript-parser.mjs:326-337`）
  加 `collectSubagentLinks`（`:145-163`），**不使用 `isSidechain`**——该字段只在 qwen / qoder 处理器里出现。
  本项目 OPEN-ISSUES K1 的去重方案走 `isSidechain` / `agentId` 分层，与它的 `agentId` 路径一致。

**teamai 完全看不到这些文件**（无 `SubagentStop`、无遍历 `subagents/` 的代码路径）。
[teamai-cli-vs-vibetrail.md](teamai-cli-vs-vibetrail.md) §3.2 实测本机语料里 58% 的人类拒绝发生在子 agent 里——
Pilot 在采集范围上没有这个缺口，那节的结论只对 teamai 成立。

### 1.4 `PreToolUse` 是写侧：它改写你的 Bash 命令

**这不是采集，是注入。** 条件是主 agent、`tool_name === 'Bash'`、且上游 link 开启并允许传播（`:302-311`），
满足则把 `tool_input.command` 改写后回写 `updatedInput`（`claude-code/tool-context.mjs:428-447`）：

```javascript
command: `${exports.join('; ')};\n${toolInput.command}`
// exports = export TRACEPARENT='...'; export TRACESTATE='...'; export OTEL_RESOURCE_ATTRIBUTES='...'
```

值经 `shellSingleQuote()` 转义。目的是让 Bash 里启动的下游进程继承 W3C trace 上下文，把链路接起来
（`docs/zh-CN/claude-code-downstream-trace-propagation.md`）。它不产生任何事件，只在
`$PILOT_DATA/acp-correlate/` 落一份 trace 上下文 JSON（`tool-context.mjs:36-52`）。

**记在这里是因为介入程度**：teamai 的 hook 全部是只读旁路，明确不碰用户的提交流程
（[teamai-cli.md](teamai-cli.md) §4.4）。Pilot 会修改用户即将执行的命令行。这是能力更强的必然代价，
但性质不同——它在被观测者的执行路径上。

### 1.5 fetch 拦截：teamai 没有的形态

`assets/hooks/claude-code-fetch-intercept.mjs` 经 `BUN_OPTIONS="--preload=<file>" claude` 注入 Claude Code 进程，
拦截出站 `/v1/messages` 请求，一次 LLM 调用写一个文件到
`~/.loongsuite-pilot/intercept/claude-code/<session_id>/<response_id>.json`（`:1-4`）。

取三样（`:6-18`）：

- `system_instructions` —— 从**出站请求 body** 的 `system` 字段解析，滤掉首个计费头标记块。
  **transcript 里没有这个东西**，只有拦流量才拿得到。
- `response_id` —— 首个 SSE `message_start` 的 `message.id`，与 hook 侧 1:1 join。
- `ttft_ns` —— 首个 `content_block_delta` 到达时刻。

**公平地说这个拦截器本身是有节制的**：注释明写「拿到 response_id 和 ttft_ns 之后就停止解析，透传剩余流，
保持内存有界」（`:22-24`），整体包在 try/catch 里，「这里的异常绝不能打断 Claude Code 自己的 fetch 流」
（`:26-27`）。它没有把整个请求/响应体存下来。但机制建立了——**这是一条能看到全部出站流量的通道**，
取多取少是当前实现的选择。

**它怎么被装上去的**：改用户的 shell rc。`src/core/hook-watchdog.ts:863-870` 往 `~/.zshrc` **和**
`~/.bashrc` 各追加一个带 marker 的块（qodercli 与 claude-code 两个 intercept 目标），由它设置
`BUN_OPTIONS`。两个 rc 都写，理由写在注释里：daemon 由 launchd 启动，它的 `$SHELL` 未必等于用户交互 shell。

两条限定，都算克制：`:914` 「never create rc files」——rc 文件不存在就跳过，不新建；增删都靠
BEGIN/END marker 做幂等。但要知道 **watchdog 会自动修复**：手工删掉那个块，下一轮健康检查会按内容
（不是按 marker）判定不健康并重新追加（`:908-920`）。要彻底移除得走卸载流程。

## 2. 本机落盘：`~/.loongsuite-pilot/` 清单

默认数据目录 `~/.loongsuite-pilot/`（`LOONGSUITE_PILOT_DATA_DIR` 可覆盖）。

### 2.1 两份事件流

| 路径 | 内容 | 谁写 |
|---|---|---|
| `logs/<agent-id>/<agent-id>-YYYY-MM-DD.jsonl` | 已归一化的 GenAI 事件（**不是**原始 hook payload） | hook processor，同步 |
| `logs/output/<agent-id>-YYYY-MM-DD.jsonl` | 规范化事件，保留原生 JSON 类型 | JSONL flusher，**默认开**（`config-loader.ts:1148`） |

前者是 daemon 的输入源，后者是输出。两份都含 §0 三层的全部字段。

注入型插件（DSH、OpenClaw 等）写的是 append-only 原生事件，POSIX 上目录 `0700` / 文件 `0600`
（`docs/zh-CN/agents.md:87-88,209-211`）。

### 2.2 拦截与状态

| 路径 | 内容 |
|---|---|
| `intercept/claude-code/<session_id>/<response_id>.json` | 一次 LLM 调用一个文件，见 §1.5 |
| `state/claude-code/sessions/<sid>.json` | subagent 元数据；`pending_subagent_turns` 存**完整事件正文**（`:896-903`） |
| `acp-correlate/` | Bash 注入的 trace 上下文（`tool-context.mjs:36-52`） |
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

⚠️ **hook 侧那份事件流不被任何保留策略覆盖。** `CATEGORY_DIR_MAP` 只认
history / errors / debug / output / sls-failed-logs / otlp-failed / metric_alarm
（`src/core/log-retention-service.ts:49-57`）；`logs/claude-code/` 走 `cleanSubdirectories`（`:130-134,148-170`）
**只清子目录**，根下的 `claude-code-YYYY-MM-DD.jsonl` **永不删除**——而那正是含完整对话正文的文件。
daemon 侧只推进 offset，不删文件（`src/inputs/base/base-hook-input.ts:66-131`）。
同目录的 `errors/` 反而有 7 天保留。

其余三处的清理情况：

- `intercept/`：只有**机会性清理**——Stop 时删已合并的（`:208-214`）、删同 session 目录内 mtime > 1h 的
  （`:222-235`）。session 不再触发 Stop 时残留无人清；`src/` 内无任何 intercept 清理代码。
- `state/claude-code/sessions/`：`state.mjs:143` 注释称供 hook-watchdog 清理，但 `src/` 内**无调用者**——未确认有清理。
- `acp-correlate/`：清理机制**未确认**。

## 3. 出本机的部分

默认**不出本机**：JSONL 是唯一默认开的输出，SLS / HTTP / OTLP 都要显式配置。但企业接 AgentLoop 控制台的场景
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
:10     SEND_INTERVAL_COUNT = 72   // L1 每 10 分钟一次 → 每 12 小时发一条
:12-21  SELECTED_FIELDS = cpu, mem, version, instance_id, ip, hostname, os_detail, metric_json
:34-37  POST __topic__: 'pilot_running_status'
```

调用点 `src/metrics/metrics-writer.ts:177` —— `sendRunningStatus(flattenToStrings(metrics))`，
**无条件执行**。全仓 grep 不到任何环境变量或配置键能关掉它。

`instance_id` 的构造（`src/metrics/metrics-collector.ts:494-500`）注释自陈可逆：

```javascript
this.instanceId = `${this.hostname}_${opts.userId}_${dataDirEncoded}`;
// dataDir is base64url-encoded (not plaintext) but remains reversible: strip the
// `${hostname}_${userId}_` prefix and base64url-decode to recover the path.
```

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
| commit hash / diff（本机链路） | 本机采集无任何 commit 字段。全仓 commit 相关只在 `src/pipeline/input/qoder-api/`——从 **Qoder 服务端 API** 拉的组织级数据，不是本机采的，见 §5.5 |
| git hook / `core.hooksPath` | 全仓无安装 git hook 或改 `core.hooksPath` 的代码 |
| 环境变量快照 | 只读自己的 `LOONGSUITE_PILOT_*`、各 agent 的 home 定位变量、白名单内的 `AGENTTEAMS_WORKER_NAME` / `AGENTTEAMS_INSTANCE_ID`（`output-event-schema.md:154` 明写其他 `AGENTTEAMS_*` 不进事件） |
| 孙级 subagent | 只展开一级（`:869`） |

**不在这张表里的**：Pilot 自身的运行状态回传。本文第一版把它列在这里，是错的，见 §3.5。

## 5. 六条值得单独记的

### 5.1 出站脱敏兜底是死代码

`src/normalization/entry-builder.ts:294` 有一个 `redactCodeGenerationFields()`，删的正好是全部内容字段
（`REDACTED_FIELDS`，`:182-197`）：

```
gen_ai.input.messages / messages_delta / output.messages
gen_ai.tool.call.arguments / result
agent.content / agent.inline_diff_message
filePath / content / inlineDiffMessage
```

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

### 5.5 Qoder 链路上有 commit 关联和行级归属

`src/pipeline/input/qoder-api/qoder-api-client.ts:278` 拉
`/v1/organizations/{orgId}/ai-code-tracking/commits`，写出的日志条目（`qoder-api-input.ts:689-729,879-880`）带：

```
commit_hash / commit_ts / commit_message
committed_total_lines_edit / committed_ai_lines_edit
```

**这是 commit ↔ AI 代码行数的关联**，本项目关心的能力里唯一在三方工具中见到实现的一次。两条限定：
它是从 **Qoder 组织级服务端 API 拉的**，不是本机采集；且只在 Qoder 生态内，Claude Code 链路完全没有。
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
- **保留策略要按目录枚举，不能按类别映射。** §2.4 那个洞的成因是 `CATEGORY_DIR_MAP` 漏了一类目录，
  于是含完整对话正文的文件永不删除——而所有配置项看上去都配好了。本项目 trace 目录若将来加清理，
  应当默认覆盖全部子目录，新增目录不进清单就报错，而不是静默漏过。
- **采集范围没有回归钉子，是三方共同的缺口。** Pilot 装了 `SubagentStop` 而 teamai 没有，两边都没有测试
  守住「采集范围」这件事。这正是 [teamai-cli-vs-vibetrail.md](teamai-cli-vs-vibetrail.md) §7 第 2 条提的问题——
  判据有测试，范围没有。本项目同样缺。

## 7. 本文的审计记录（2026-09-10）

初稿写完后逐条回查代码，**2 处断言被推翻或补全**。均已改在正文，此处只留台账——这份文档自己也该有留痕。

| # | 初稿的说法 | 核实结果 | 落在 |
|---|---|---|---|
| 1 | 「Pilot 自身不回传，没有安装遥测或版本上报」 | **错，且方向相反**。`src/internal/statistic.ts` 每 12 小时向固定阿里云 SLS 发 `ip` / `hostname` / `os_detail` / `instance_id`（可逆，含数据目录路径），无条件、无 opt-out、文档零提及；而且是**开源版专属**（闭源版走 `.internal` 分支）。初稿只 grep 了 `src/updater/` 与 `src/core/`，漏了 `src/internal/` 与 `src/metrics/` | §0 三层表 / §3.5 / §4 |
| 2 | 「`intercept/` 与 `logs/<agent-id>/` 的清理路径未在本次扫描中确认」 | 已查明：`logs/claude-code/` 根下的 jsonl **永不删除**（`CATEGORY_DIR_MAP` 漏了该目录，`cleanSubdirectories` 只清子目录）；`intercept/` 只有 Stop 时的机会性清理；`state/` 与 `acp-correlate/` 仍未确认 | §2.4 |

第 1 条的教训和 teamai 那三份文档附录里的第 1、8 条同款：**范围没扫全就下结论**。
「grep 不到」只有在 grep 覆盖了全仓时才是证据——初稿把两个目录的 grep 结果当成了全仓结论。
代价是这条恰好是全文最重的发现之一，差点写反。

**这份文档的局限**：全部读码所得，本机未装 Pilot，没有实机数据可对照——所有关于运行时行为的结论
（发送周期、清理时机、watchdog 修复）都是从代码推的，没有实测。
核实方式是两个独立 agent 分头扫代码，关键断言（TRACEPARENT 注入、`error.message` 绕过、
`endpoint.redact` 死代码、`sender.ts` 的构建分支）由我逐条回查原文。
**没有做 teamai 那三份文档第 1-3 轮那种完整的独立第二意见复核**，后续如果再碰这份文档，
应当先补跑一次。
