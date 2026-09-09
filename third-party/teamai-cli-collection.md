# teamai-cli 采集清单

> 三方项目分析，**不是**本项目的一部分。配套文档：[teamai-cli.md](teamai-cli.md)（项目分析）、
> [teamai-cli-vs-vibetrail.md](teamai-cli-vs-vibetrail.md)（与本项目对比）。
>
> 快照 HEAD `224c0c4`（2026-09-09），行号均指向该快照，**引用请带日期**。全部读码所得；
> 本机未装 teamai（`~/.teamai` 不存在），没有实机数据可对照。

本文只回答一个问题：**它采了什么、落在哪、什么出本机。** 摩擦判据的精度问题不在这里重复，
见 [teamai-cli.md §4.1](teamai-cli.md) 与 [对比文档 §3](teamai-cli-vs-vibetrail.md)。

## 0. 一句话

**采的是「会话行为计数 + 少量截断文本」。** 入口只有它注入的 4 个 harness hook；先落
`~/.teamai/`；计数类随 `teamai pull` 自动 git 直推团队仓；文本类默认不出本机。

分三层看：

| 层 | 内容 | 去向 |
|---|---|---|
| 计数 | 工具调用数、skill 使用数、人打断 / 拒绝 / 纠偏 / 工具报错数、真人轮数、token 四桶、recall 命中与采纳 | 本机 → 团队仓 `stats/<user>.yaml`、`votes/<user>.yaml` |
| 截断文本 | 每条 prompt 前 200 字、每次 Stop 时最后一条 AI 输出前 500 字、首个 prompt 脱敏后 160 字 | **只在本机**（`--include-prompt` 例外） |
| 身份与环境 | 用户名、cwd 绝对路径、transcript 路径、AI 工具主进程 PID、主机名 / OS / 机器 ID 哈希（HTTP 模式） | cwd 随 `session save --push` 出本机；主机信息只在 HTTP 模式出 |

## 1. 入口：4 个 hook 事件

`teamai init` 往各 harness 注入 4 类 hook（`src/builtin-hooks.ts:222-227`），全部经
`teamai hook-dispatch <event>` 一个入口分发到注册表（`src/hook-handlers.ts:450`
`buildHandlerRegistry()`，共 19 条注册）。与采集有关的：

| hook 事件 | handler | 采什么 | 前/后台 |
|---|---|---|---|
| SessionStart | `dashboard-report` | 记 `session_start`；解析 AI 工具主进程 PID | 前台 |
| SessionStart | `local-agent-sync` | HTTP 模式：POST report + sync（§3.3） | 前台 |
| PostToolUse `*` | `dashboard-report` | 每次工具调用记 `tool_use`，**只记工具名，不记参数** | 前台 |
| PostToolUse `Skill` | `track` | skill 名 → `usage.jsonl`；Cursor 靠 `Read` 到 `SKILL.md` 识别 | 前台 |
| UserPromptSubmit | `dashboard-report` | 记 `prompt_submit`，存 prompt **前 200 字** | 前台 |
| UserPromptSubmit | `track-slash` | 以 `/` 开头的 prompt，取第一个词作 skill 名（`:181`） | 前台 |
| Stop | `dashboard-report` | 全量扫 transcript：打断 / 拒绝 / 报错计数、token、真人轮数；另存最后一条 AI 输出前 500 字 | **后台** |
| Stop | `contribute-check` | 读 events 算摩擦分，写 contribute 状态（含首个 prompt 摘要） | 前台，gitOnly |
| Stop | `votes-sync` | 扫 transcript 里的 recall 标记，记 learning 采纳票 | 前台，gitOnly |
| Stop | `update` | 后台查 npm registry 有无新版，只发包名 | 后台 |

三个口径：

- `gitOnly` 的 handler 在 HTTP 团队源下被整体过滤（`:510` `filterHandlersForConfig()`）；
  `dashboard-report` 不带这个标记，所以 **HTTP 模式下本机采集照常，只是不往 git 仓上报**。
- 开关：`sharing.contributeHint.enabled: false` 关掉整个 `contribute-check`；`TEAMAI_RECALL_DISABLED=1`
  关掉 `votes-sync`。**`dashboard-report` 本次 grep 未见任何开关**，要彻底不采只能 `teamai hooks remove`。
- 没有 `SubagentStop`，子 agent 的 transcript 一律看不到。已在
  [teamai-cli.md §4.1.1](teamai-cli.md) 展开，此处不重复。

## 2. 本机落盘：`~/.teamai/` 清单

采集类数据全部在 `~/.teamai/` 顶层，**不按项目分区**；teamai-cli.md §4.3 说的
`~/.teamai/projects/<slug>/` 分区只装团队仓 clone 与资源缓存。也就是说多项目的会话事件混在同一个
`events.jsonl` 里，靠每条的 `cwd` 事后过滤（§3.1 的作用域过滤即基于此）。

### 2.1 `dashboard/events.jsonl`：主数据流

`parseHookEvent()`（`src/dashboard-collector.ts:785`）把 hook 的 STDIN JSON 折成一条
`DashboardEvent`（`src/types.ts:849`）追加写入。每条都有的字段：

| 字段 | 来源 |
|---|---|
| `type` | `session_start` / `tool_use` / `prompt_submit` / `stop`；看板进程另会补 `process_exit`（`src/dashboard.ts:87-104`） |
| `timestamp` | hook 触发时刻，不是 transcript 里的时间 |
| `sessionId` | hook 的 `session_id` > `CLAUDE_SESSION_ID` > `pid-<ppid>-<cwd>` 兜底（`src/utils/session-id.ts`） |
| `tool` | harness 名：claude / codex / cursor / codebuddy … |
| `cwd` | hook 的 `cwd`，Cursor 取 `workspace_roots` 第一项；**绝对路径** |

按事件类型追加的字段：

| 事件 | 字段 | 内容 | 出处 |
|---|---|---|---|
| `session_start` | `monitorPid` | 沿进程树向上找第一个非 shell 祖先的 PID，macOS 靠 `ps` | `:830`，`src/pid-monitor.ts:84` |
| `tool_use` | `toolName` | 归一化后的工具名。**没有 `tool_input`** | `:822` |
| `prompt_submit` | `promptSummary` | `prompt.slice(0, 200)`，**未脱敏** | `:841` |
| `stop` | `transcriptPath` | hook 递来的 transcript 绝对路径 | `:846` |
| `stop` | `stoppedOutput` | 读 transcript 末尾 10 KB，取最后一条 assistant 文本，`redactWithEnv()` 后截 500 字 | `:65-113` |
| `stop` | `interventions` | `{interrupt, toolReject, toolError}`，全量扫 transcript 的累计快照；三者全 0 时不写 | `:854-860` |
| `stop` | `tokens` | `{input, output, cacheRead, cacheCreation}`，全 0 时不写；Codex 另带 `tokenScope` | `:861-865` |
| `stop` | `prompts` | 真人轮数：有真实文本的 user 记录，排除打断 / tool_result / `isMeta` / `isSidechain` / `<task-notification>` | `:286-333` |

Stop 时那次全量扫描（`scanTranscriptStop()`，`:167`）的判据：

- `interrupt`：user 文本块 `startsWith('[Request interrupted by user')`（`:311`）
- `toolReject`：`tool_result.is_error === true` 且正文含 `The tool use was rejected` 或
  `doesn't want to proceed with this tool use`（`:323`）
- `toolError`：`is_error === true` 但不匹配上面两个串（`:327`）
- token：Claude 按 `message.id` 去重后累加 `message.usage` 四项（`:276-282`）；Codex 取最新的
  `token_usage_record`；CodeBuddy 读 `index.json` 的 `requests[].usage`（`:509`）；Cursor 没有
  transcript，token 恒 0
- 单文件上限 50 MB（`src/types.ts:976`），超过记一条 warn 后返回全 0

生命周期：超过 5,000 行触发压缩（`:1219`），**只保留活跃会话**（30 分钟内有活动，或刚停不到
30 秒）的事件，其余整段丢弃。原始事件流是短命的，长期留下的只有 §2.6 的上报水位和团队仓里的累计值。

### 2.2 `usage.jsonl` 与 `known-skills.json`

- `usage.jsonl`：一行一条 `{skill, timestamp, tool}`（`src/types.ts:723`）。只有三种来源：
  `Skill` 工具调用、Cursor `Read` 到 `SKILL.md`、`/xxx` 开头的 prompt。上报成功后截断
  （`src/usage-tracker.ts:197`）。
- `known-skills.json`：用过的 skill 名集合，不随截断丢失。

### 2.3 `sessions/<sid>.json`：contribute 状态

`ContributeState`（`src/types.ts:1016`），Stop 时由 `contribute-check` 写：

| 字段 | 内容 |
|---|---|
| `toolCount` / `uniqueTools` | 工具调用总数 / 种类数 |
| `smartScore` | 摩擦分，公式见 teamai-cli.md §4.1 |
| `friction` | `{interrupt, toolReject, correction, toolError}` |
| `promptSummary` | **首个 prompt**，`redactWithEnv()` + 去控制字符 + 单行化后截 160 字（`src/contribute-check.ts:81-117`） |
| `sessionStartIso` / `hasGitCommit` | 会话首事件时间；该时间之后 cwd 里有没有任何 commit（`:308`，时间窗存在性判断，不是关联） |
| `isKnowledgeGap` | recall 全 miss，或 top 分低于阈值 |
| `hinted` / `contributed` / `pendingHint` | 提示去重与暂存 |

24 小时后清理（`:204`）。同目录还有 `<sid>-recall-cache.json`（§2.4）和两个投票提示的 sidecar 文件。

### 2.4 `sessions/<sid>-recall-cache.json`：recall 质量

`RecallCache`（`src/recall-quality.ts:19`）：`count`、`hitCount`、`missCount`、`topScore`、`updatedAt`。
接口上有 `queries: string[]`，但写入路径永远给空数组（`:95`），**查询词不落盘**。24 小时 TTL。

### 2.5 `votes/<user>.yaml`：learning 的召回与采纳

每个 learning doc-id 一条 `{recalled_count, upvoted_count, last_recalled_at, last_upvoted_at}` 加待同步
delta（`src/votes.ts:71-95`）。采纳票来自 Stop 时扫 transcript 里 AI 回复末尾的
`<!-- teamai:referenced-doc-ids: [...] -->` 标记（`src/transcript-parser.ts`），且只认本会话确实召回过的 id。
git 模式在 Stop 时写进本地团队仓副本、随下次 pull 推送；单仓模式在 Stop 时直接提交推送。

另有一条 opt-in 的 A/B 日志：设了 `TEAMAI_ADOPTION_EVAL_LOG` 才写，每次 Stop 一行
`{ts, sessionId, recalled, declared, nudged}`（`src/hook-handlers.ts:355`）。

### 2.6 `dashboard/reported-*.json`：上报水位

`reported-interventions.json` 与 `reported-prompt-tokens.json`（`src/team-push.ts:134,205`）记每个会话
**已经报过**的计数，下次只报正增量。这是「事件流可以被压缩掉、团队累计值却不重复计」的机制。

### 2.7 `session-logs/YYYY-MM.md`：本地会话摘要

`teamai session save` 的产物，字段同 §3.2，本地版**总是**带脱敏首个 prompt（`src/save-session.ts:82`）。
90 天清理（`src/session-collector.ts:212`）。

### 2.8 日志类

- `debug.log`：所有 `log.debug` 常驻落盘，5 MB 轮转一次（`src/utils/logger.ts:23,36`）。里面有每条
  prompt 的**前 60 字**（`src/dashboard-collector.ts:894`）和 HTTP 模式的请求 / 响应体全文
  （`src/utils/http-log.ts:8-9`，头部脱敏、正文原样）。
- `reporter/errors.jsonl`（HTTP 模式）：report / sync 失败时把整个 context 写进去
  （`src/local-agent.ts:746,3130`）。context 里含当次 `DashboardEvent`，即 `promptSummary`、
  `stoppedOutput`、`transcriptPath`、`cwd` 一并落盘。

### 2.9 只算不存的派生指标

从 events.jsonl 现算，不单独落盘：

| 指标 | 算法 | 出处 |
|---|---|---|
| `correction` | Stop 后 60 秒内的 `prompt_submit`，且 `promptSummary` 命中中英日纠正词表；每个 Stop 只被消费一次 | `src/dashboard-collector.ts:1167`，词表 `src/types.ts:969` |
| 会话状态灯 | running / waiting_for_input / idle（5 分钟）/ stopped（PID 死亡） | `rebuildSessions()` `:951` |
| 按仓库归属 | 取 cwd 末段目录名；home / tmp / workspace 等归 `no_repo` | `src/utils/repo-attribution.ts:47` |
| 按小时活动 / 夜猫子比例 / 活跃分钟 | 事件时间戳分桶；0-6 点占比；相邻事件间隔 < 5 分钟累加 | `src/session-analytics.ts:88` |
| skill 健康分 | usage 0-60 + freshness 0-40 | `src/skill-health.ts` |

`correction` 的存在意味着 **prompt 文本是必需输入**。这是文档「不落地 prompt」说法站不住的结构性原因，见 §5。

## 3. 出本机的部分

### 3.1 git 团队仓：随 `teamai pull` 自动直推

`reportUsageToTeam()`（`src/team-push.ts:313`）在每次 pull 末尾跑（`src/pull.ts` 第 4 步
「Auto-report」段），直接 commit + push 到团队仓默认分支，**不走 MR**，5 秒超时，失败下次重试。写两个文件：

**`stats/<user>.yaml`**（`UserStats`，`src/types.ts:737`）：

| 字段 | 内容 | 上报口径 |
|---|---|---|
| `username` / `updatedAt` | git provider 登录名，generic git 取 git 身份（`src/init.ts:1080`） | |
| `skills.<name>` | `{count, lastUsed}` | `usage.jsonl` 聚合后累加 |
| `interventions` | `{sessions, interrupt, toolReject, correction}` | 按会话正增量累加；**`toolError` 不上报** |
| `prompts` | 真人轮数累计 | 同上 |
| `tokens` | 四桶累计 | 同上 |

**`votes/<user>.yaml`**：§2.5 的 delta 合并进远端快照。

三点口径：

- 增量幂等：靠 §2.6 的水位文件，重复 pull 不重复计。
- 作用域过滤（`:286`）：project 级团队仓只收 cwd 在 projectRoot 下的会话，user 级排除这些。
- 单仓模式（`repo.kind === 'self'`）写到 `teamai-reports` 孤儿分支的独立 worktree，不碰业务仓工作树。

HTTP 团队源不走这条（pull.ts 里 `repo.kind !== 'http'` 才进 targets），见 §3.3。

另：`teamai init` 时注册 `members/<user>.yaml`（`src/init.ts:1237-1250`），记 username / displayName
这类身份字段，无采集数据。

### 3.2 手动：`teamai session save --push`

把一个会话的事件折成 markdown 追加到团队仓 `sessions/<user>/YYYY-MM.md`（`src/save-session.ts:143,165`）。
`renderSessionMarkdown()`（`src/session-collector.ts:142`）写出的每一项：

| 行 | 内容 |
|---|---|
| HTML 注释 | **完整 sessionId**（幂等键） |
| 标题 | 日期 · sessionId 前 8 位 · harness 名 |
| Project | **cwd 绝对路径，原样**（`:157`） |
| Prompts / Tools | 真人轮数；工具总数与种类数 |
| Interventions | interrupt / toolReject / correction 三个数 |
| Top tools | 前 8 个工具名 × 次数 |
| First ask | 仅 `--include-prompt` 时；脱敏后 160 字（`:162`） |

门槛：默认只推「有价值」的会话，即有任一干预或用了 ≥ 3 种工具（`:62`），`--force` 可绕过。
`digest` 读这个目录做 Session Highlights，展示时每条只取前 120 字。

### 3.3 HTTP 企业后端：report / sync / ack

配置了 HTTP 端点（`local-agent/config.json`，或 `TEAMAI_HTTP_ENDPOINT` 等环境变量，
`src/local-agent.ts:623`）时，**每个 hook 事件**都会 POST 一次 report 加一次 sync
（`reportAndSyncLocalAgent()`，`:3024`）。

report 载荷（`buildReportPayload()`，`:1527`）：

| 字段 | 内容 |
|---|---|
| `agent_type` / `agent_version` | harness 名与版本 |
| `local_agent_id` | `sha1(agent_type + machine_id + sha1(install_path)[:8])[:16]`（`src/machine-id.ts:107`）。machine_id 取 macOS IOPlatformUUID / Windows MachineGuid / Linux `/etc/machine-id`，**只进哈希不明文上报**；`TEAMAI_LOCAL_AGENT_ID` 可覆盖 |
| `host_name` / `os` | `os.hostname()` 明文、平台名 |
| `started_at` / `last_status` | 配置创建时间；running / stopped 等 |
| `user_level` | `group_id` + 用户级已安装的 skills / rules / mcps / models 清单 |
| `workspaces[]` | 每个绑定工作区的 `path`（绝对路径）、`name`、`ide_type`、`project_id` + 项目级资源清单 |

资源清单条目只有 `slug / version / display_name / source`（`:1213`）；models 只有
`provider / model_id / name / source`（`:1352`），**不含 api_key**，api_key 只在反方向由服务端下发。
载荷里**没有用户名字段**，身份靠请求头里的 API token 和 `local_agent_id`。

sync 载荷（`:1609`）只有 `agent_type / local_agent_id / status / workspaces[{path, name, ide_type, project_id}]`，
响应里带服务端要执行的命令，执行后 ack。

**会话计数、token、干预数不经 HTTP 上报**：这条链路是资产清单 + 存活心跳，不是遥测。

### 3.4 内容类（不是指标，顺带列全）

- `/teamai-share-learnings`：AI 写 learning 文档，直推团队仓 `learnings/`。内容由模型生成，无脱敏路径。
- `teamai codebase --extract`：代码结构图（组件、接口、import 边）推 `teamwiki/`；enrich 阶段把模块名、
  文件列表、组件名喂给**本地** AI CLI（`src/enrich-with-ai.ts`，经 `src/utils/ai-client.ts` 调 claude /
  codex 命令），不经 teamai 服务端。
- CI `teamai ci extract-mr`：读 MR diff 与评论，读 👎 反应当 reject（`src/ci/read-rejections.ts`）。
- `update`：Stop 时后台查 npm registry，只发包名查版本。

## 4. 明确不采（已 grep 核实）

| 项 | 依据 |
|---|---|
| 工具参数 `tool_input` | `parseHookEvent()` 只取 `tool_name`；`track` 只从 `tool_input` 里抠 skill 名 |
| 文件内容 / diff / 代码 | 无读工作区文件的采集路径；codebase extract 是显式命令，不在 hook 链上 |
| 完整 prompt / 完整对话 | 截断为 200 / 500 / 160 字三档 |
| 子 agent transcript | 无 `SubagentStop`，无遍历 `subagents/` |
| commit ↔ session 关联 | `hasGitCommitInSession()` 只做时间窗存在性判断 |
| recall 查询词 | `queries` 永远空数组 |
| transcript 里的 assistant 文本（最后一条除外） | 扫描只碰 assistant 的 `usage` 字段与 user 记录 |

## 5. 与自述不符之处

`docs/usage-guide.zh-CN.md:1142,1155` 两处写「只统计次数 / 轮数与 token，**不落地任何 prompt 或
transcript 原文**」。代码事实：

| # | 事实 | 出处 | 出本机？ |
|---|---|---|---|
| 1 | 每条 prompt 前 200 字**未脱敏**写入 `events.jsonl`；最后一条 AI 输出前 500 字（脱敏）同文件 | `src/dashboard-collector.ts:841,113` | 否 |
| 2 | 看板把一个会话的全部 prompt 摘要聚成 `prompts[]`，经 `/api/sessions` 以 JSON 提供，绑定 `127.0.0.1` | `:1001`，`src/dashboard.ts:130-136,217` | 否，仅本机端口 |
| 3 | `debug.log` 常驻记录每条 prompt 前 60 字，按 5 MB 轮转而不随事件压缩清理 | `:894`，`src/utils/logger.ts:23` | 否 |
| 4 | HTTP 模式下 report 失败时，整个事件（含 prompt 摘要、AI 输出、transcript 路径）写入 `reporter/errors.jsonl` | `src/local-agent.ts:3130` | 否 |
| 5 | `session save --push` 把 cwd **绝对路径**原样推进团队仓 | `src/session-collector.ts:157` | **是** |

评估：1-4 都留在本机，不是泄露级问题，但「不落地任何 prompt 原文」这句话是错的，且 §2.9 说明
`correction` 指标在结构上就依赖 prompt 文本。第 5 条是真出本机，把每个人的本机目录结构带进了团队仓；
文档 `:1175` 只提了 prompt 行的 opt-in，没提路径。

`--include-prompt` 那条链路的脱敏是 `redactWithEnv()`（`src/utils/redact.ts:142`）：环境变量里像密钥的值
+ 一组厂商 token 形态正则。对比文档 §6.1 已评估过，此处不重复。

## 6. 对本项目的两点参照

- **分层是对的**：计数出本机、文本留本机、路径类信息单独审。本项目 OPEN-ISSUES 的 K6
  （trace 自由文本零脱敏）可以直接借这个三分法定边界。
- **自述以代码为准**：它的设计文档 `docs/designs/team-intelligence-platform.md`（2026-03-19）只规定了
  `usage.jsonl`「no conversation content」，并把 web 看板列为 NOT in Scope；后来加的 dashboard
  `events.jsonl` 带了 prompt 文本，用户指南的隐私声明没有随之更新。同一个坑，
  teamai-cli.md §4.1 那条过时注释已经踩过一次。
