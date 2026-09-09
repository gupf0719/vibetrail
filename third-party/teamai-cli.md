# teamai-cli 项目分析

> 三方项目分析，**不是**本项目的一部分。配套文档：
> [teamai-cli-vs-vibetrail.md](teamai-cli-vs-vibetrail.md)（与本项目对比）、
> [teamai-cli-collection.md](teamai-cli-collection.md)（采集清单：采什么、落哪、什么出本机）。
>
> 扫描对象：`/Users/gupengfei/program/go/src/teamai-cli`，HEAD `224c0c4`（2026-09-09）。
> 本文所有数字均来自该快照，**引用请带这个日期**——它是个每天都在动的仓。

## 0. 一句话

**把团队的 AI 配置和团队的经验，用 git 分发到每个人的每个 AI 工具里。**

不是留痕工具，是**分发 + 知识库**工具。它读会话流水，但读的目的是「这次会话值不值得
写成团队经验」，不是「这个 commit 是怎么来的」。

## 1. 基本盘

| 项 | 值 |
|---|---|
| 归属 | Tencent 开源，MIT，`npm i -g teamai-cli` |
| 版本 | `package.json` 0.22.0；CHANGELOG 最新已发布 0.23.0（2026-09-08），另有 Unreleased 段 |
| 规模 | src 非测试 TypeScript **62,514 行**；测试 **228 个文件 / 57,145 行**（测试与实现近 1:1） |
| 历史 | 685 commit，39 位贡献者 |
| 形态 | 单个 npm CLI（`teamai`），commander + tsup + vitest |
| 内置资源 | 2 个 skill（`teamai-share-learnings`、`team-wiki-codebase`）、1 个 agent（`teamai-recall`）、一组内置 rules（`src/builtin-rules.ts`，recall 规则注入块，随 recall 开关部署） |

## 2. 产品三层

README 自述的架构，本文沿用，因为代码目录确实按这三层聚类：

| 层 | 目标 | 状态 | 主要命令 |
|---|---|---|---|
| **Team Execution** | 让每个 agent 按团队的方式干活 | 正式 | `init` / `pull` / `push` / `status` / `packages` |
| **Team Context** | 让每个 agent 懂团队 | beta | `recall` / `import` / `codebase` |
| **Team Improvement** | 让每次执行反哺团队 | beta | `contribute` / `session save` / `digest` / `dashboard` / `recall promote` |

**与本项目重叠的只有第三层，且只有其中读 transcript 的那一小块。**

## 3. 功能清单

### 3.1 Team Execution（分发）

核心是一条**用 git 当真相源**的分发链：

```
teamai push → 建分支 + 开 MR → reviewer 审核合并
                                    ↓
              SessionStart hook → teamai pull → 落到本地各 AI 工具
```

分发的资源类型：skills、rules、docs、agents、culture.md、CLAUDE.md、env、hooks、
MCP、packages（npm 包与 Claude Code plugin）。

git 之外另有一条**非 git 的 HTTP 后端模式**（`teamai init --http <baseUrl> --token`）：
只读消费者，`push` / `contribute` 不可用，skills/rules 走 report → sync → ack 生命周期按
session 下发，服务端还能下发模型配置（`apply_model_config`）；也可在 git 主仓之上附加一个
HTTP 源（`teamai source add-http`）。HTTP 团队会被过滤掉所有 `gitOnly` 的 hook handler
（contribute 提示、votes 同步、MR 提示），但 dashboard 的 transcript 扫描仍在跑。

分发的控制面：

| 能力 | 命令 | 作用 |
|---|---|---|
| Roles | `teamai roles` | 角色 → 命名空间映射，每人只同步自己角色的 skill |
| Tags | `teamai tags` | 给 skill/rule 打标签，成员按标签订阅 |
| Sources | `teamai source` | 订阅别的团队 / 组织内公共仓的 skill |
| Exclude | `teamai skill exclude` | 本地排除不想要的 skill |
| Projects（Unreleased） | `teamai init --project <ids>` | 与 role 正交的第二维：`manifest/projects.yaml` 声明逻辑项目，目录取 role ∪ project 的并集，`learnings/<project-id>/` 只对该项目可见；`projects set/members` 子命令尚未落地 |

**适配 10 个 agent harness**（README 矩阵的行数）：Claude Code、Codex、Cursor、CodeBuddy、
WorkBuddy、OpenCode、OpenClaw、Hermes、DeepSeek Harness、Qoder。代码的 `toolPaths` 还多出
**JoyCode**（0.23.0 列为一等支持，但它没有 hook 机制，只能手动 `teamai pull`）和 4 个内部变体
（`claude-internal` / `codex-internal` / `tclaude` / `tcodex`），矩阵没列。
**适配 6 类 git provider**：GitHub、GitLab、GitCode、CNB、TGit、私有 git
（`src/providers/` 下一个目录一个）；再加上文的 HTTP 后端模式。

### 3.2 Team Context（知识库）

- **learnings**：会话经验文档，落在团队仓 `learnings/`。
- **codebase 知识图谱**：`teamai import` / `teamai codebase --extract` 把源码仓解析成
  `teamwiki/` 下的结构化图（组件、接口、配置、跨仓 import 边）。
- **recall**：BM25 + 图加权重排的检索，默认**关闭**，`teamai recall enable` 打开后
  `pull` 会把 `teamai-recall` subagent 装进各工具的 `agents/`，由 AI 在任务前自行调用。
  subagent 先跑一次相关性预检（`teamai recall --check`），不相关就整个跳过检索。

图谱的边有两条轨道并行，重叠时 AST 优先：

- **AST 轨**（TS/JS、Python、Go）：`web-tree-sitter` 的 WASM parser 解析
  `import`/`require`、调用点、TS `implements`，产出文件级
  `DEPENDS_ON` / `REFERENCES` / `IMPLEMENTS` 边，带置信度权重。
- **启发式轨**（全语言，含 Java/Rust）：正则抽取，兜住 AST 轨不覆盖的语言。

WASM 是纯 JS 依赖，不需要本地工具链；加载失败自动退回启发式并记 `AST_UNAVAILABLE` gap。
`TEAMAI_SKIP_AST=1` 可强制只走启发式。**这个降级设计是个亮点**——AST 解析是最容易
在别人机器上装不上的一环，它没让这一环变成硬依赖。

### 3.3 Team Improvement（观测与反哺）

这是与本项目重叠的一层。

| 能力 | 命令 | 产出 |
|---|---|---|
| 会话摘要 | `teamai session save` | 脱敏的单会话摘要（工具序列、prompt 轮数、干预数），按月归档成 markdown |
| 团队周报 | `teamai digest` | token 用量、会话量、干预率 |
| 实时看板 | `teamai dashboard` | 网页看板：成员会话状态、干预数、token |
| 知识库健康 | `dashboard` → KB Health | 覆盖率、被召回最多 / 从未被召回的条目、召回趋势 |
| 库存维护 | `teamai recall maintenance` | 归档低置信 learning，标记过期 skill/rule/doc |
| 知识飞轮 | `recall` 命中自动 upvote → `votes/<user>.yaml` → Stop 时 `votesSyncHandler` 同步 | learning 的**置信度**由此而来，上一行的「低置信」指的就是它 |
| 晋升 | `teamai recall promote` | learning → skill / rule / doc；门槛四项：置信度 ≥ 0.90、≥ 5 upvote、≥ 2 贡献者、存在 ≥ 14 天 |
| CI 接入 | `teamai ci extract-mr` / `import --from-mr` | MR 打开时把知识建议发成评论、reviewer 👎 拒绝、合并后 `--mode write` 写库；方向是 **MR → 知识**，不是 commit → 会话 |

`docs/designs/git-native-memory.md` 还记了第三层 **Reflect**（LLM 对 learnings 做元分析）——
推迟到知识库积累 20+ 篇之后。

以及**贡献提示**（`contribute`）：Stop hook 给会话打一个 friction 分，够高就在会话结束时
提示「这次会话可能值得写成团队经验，考虑跑 `/teamai-share-learnings`」。

## 4. 值得细看的实现

### 4.1 friction 打分：读会话流水的那一段

**这是与本项目正面重叠的唯一一处代码**，所以单独展开。

入口 `src/dashboard-collector.ts` 的 `scanTranscriptStop()`，流式逐行读 transcript，
只看 `type === "user"` 的记录，在 `message.content` 数组里逐块判：

| 信号 | 判据（`src/types.ts` 常量） | 语义 |
|---|---|---|
| `interrupt` | text 块 `startsWith("[Request interrupted by user")` | 人打断 |
| `toolReject` | `is_error === true` 的块正文 `includes` `"The tool use was rejected"` 或 `"doesn't want to proceed with this tool use"` | 人拒绝工具调用 |
| `toolError` | `is_error === true` 但**不匹配上面两个串** | AI 自己搞不定工具 |
| `correction` | 一次 Stop 之后 60s 内的新 prompt，且命中纠正词表 | 人在纠偏 |
| `prompts` | 有真实文本的 user 记录，排除 interrupt / tool_result / meta / sidechain / `<task-notification>` 前缀 | 真人轮数 |

纠正词表（`CORRECTION_KEYWORDS`）是中英日三语硬编码：`不对`/`错了`/`重来`/`撤销`、
`wrong`/`redo`/`undo`/`instead`、`違う`/`やり直`/`勝手に` 等。每个 Stop 只被下一个
prompt 消费一次，再往后的 prompt 算新任务。

**这个扫描器不只读 Claude Code。** 同一个入口按文件名分流：CodeBuddy 的 `index.json` 走
`scanCodebuddyIndex()`，Codex 的 rollout 文件另取会话级 `token_usage_record`；Cursor 没有
transcript，只算 `correction`，token 记 N/A。判据取的是几种 harness 的最小公分母，
这是它只认两个拒绝串的一部分原因。

**方法论上和本项目同源：只读 JSON 字段，不 grep 整行原文**，并且把「人拒」
（`toolReject`）和「机器失败」（`toolError`）分开——这两点是对的，业内不是所有工具
都做到了。差异在判据的覆盖面与分桶粒度，见对比文档。

打分分两个函数，别当成一个公式：

```
computeSmartScore()          20×interrupt + 20×toolReject + 20×correction
                           + toolError 分档（≥8 → 25，≥5 → 18，≥3 → 10）
                           + skill 加成 + 工具多样性加成（注释自述「never triggers alone」）
applyPhase2Adjustments()   + 知识缺口加成（recall 一次没命中 → 20；命中但质量低 → 10）
                           − git commit 降权：**权重常量为 0**（`CONTRIBUTE_GIT_COMMIT_DOWNWEIGHT`，
                             注释「neutral, no bonus, no penalty」），只剩一个 hasGitCommit 标志
```

阈值 20（`score < 20` 才不提示），所以分数上**任何单个强信号——一次打断、一次拒绝、一次纠正
——就够**。但提示还有一道**与分数无关的硬门槛**：`toolCount >= CONTRIBUTE_BASE_THRESHOLD`（15），
代码注释的原话是「a single rejected command」这种几乎没干活的会话不值得记录。两个条件同时满足
才提示，每个会话最多一次（`state.hinted`）。

分层短路做得细：第一层只看 `toolCount` 与 5 分钟 TTL，不读任何事件文件；第二层才
读 `events.jsonl` 算分，且带缓存。

⚠️ **注意别被它自己的注释带偏**：`src/types.ts` 里那段流程注释写的是
「exit early (~1ms per PostToolUse)」，但 `src/hook-handlers.ts` 的注册表里
`contributeCheckHandler` **只挂在 `stop` 上**（`prompt-submit` 上挂的是投递
延迟提示的 `pendingHintHandler`）。那句注释描述的是更早的架构，**已过时**。官方 `docs/usage-guide.md` 的 Hooks 表
（中英两版）也写着 PostToolUse 做「知识贡献检测」，而同一份文档「贡献知识」一节又说是 Stop
——两处都别信，以 `hook-handlers.ts` 的注册表为准。本文第一版照抄了注释，审计时才发现
——记在这里提醒后来读这份代码的人。

### 4.1.1 它只扫一个文件——而分歧的大头不在那个文件里

`scanTranscriptStop(hookData.transcript_path)` 扫的是 hook 递过来的**单个** transcript 文件。

Claude Code 的落盘布局是**两层**——**这一点本项目 [DESIGN.md](../DESIGN.md) 第 27 行
早已记录**（`<sessionId>/subagents/agent-*.jsonl` 独立完整 transcript + `.meta.json`），
不是本次新发现；本次新增的是**量级**与下面那条字段层的观察：

```
~/.claude/projects/<cwd-slug>/<sessionId>.jsonl                        ← 主会话，34 个
~/.claude/projects/<cwd-slug>/<sessionId>/subagents/agent-<hex>.jsonl  ← 每个子 agent 一个，728 个
```

实测（2026-09-09，本机 `~/.claude/projects/` 全量）：762 个 transcript 文件只对应
**34 个 sessionId**。子 agent 文件名是 `agent-<hex>`（728/728 全部带该前缀，
**不是** uuid），记录里带的却是**父会话的 `sessionId`**。字段层面**两套标识都在**：
子 agent 文件里每条记录都是 `"isSidechain":true` 并带 `agentId`（值等于文件名里的 hex），
主会话文件里每条都是 `"isSidechain":false`，0 个主文件含 `true`——也就是说子 agent 记录
**不再嵌在主文件里**，而是各自成文件，目录和字段任取其一都能分开。
单个 sessionId 最多横跨 **291 个文件**。

> 本文第一版把这条写成「`isSidechain` 在子 agent 文件里根本不出现，靠目录区分」。
> 复核时数了一遍：728 个文件、119,969 条记录全是 `true`。写反了，已改
> （见对比文档附录第 8 条）。本项目 OPEN-ISSUES K1 的去重方案本来就是靠
> `isSidechain` / `agentId` 分层，与此一致。

teamai 拿不到这 728 个文件：它**内置**注册的 hook 只有 `SessionStart` / `Stop` /
`PostToolUse` / `UserPromptSubmit`，**没有 `SubagentStop`**（已 grep 核实），
全仓也没有任何遍历 `subagents/` 的代码路径；而且 transcript 只在 `stop` 事件里扫
（`PostToolUse` 的 handler 只计数不读文件）。团队可以在 `hooks/hooks.yaml` 里自声明
任意事件（含 `SubagentStop`），但那只跑自定义命令，不进它的扫描器。

按判据在两类文件上分别实测（同日，同语料）：

| | 主会话 34 个文件 | 子 agent 728 个文件 |
|---|---:|---:|
| 人拒（vibetrail `permission_denied`） | 39 | **53** |
| teamai `toolReject` | 37 | 7 |

**58% 的人类拒绝发生在子 agent 里**，teamai 运行时看不到。详见对比文档 §3.2。

⚠️ **`hasGitCommitInSession()` 不是 commit ↔ session 的链接**，它是
`git log --after=<会话开始时间> -1` 的存在性判断——只回答「这段时间窗里有没有人提交过」，
不回答「哪个 commit 属于这个会话」；而且它的结果目前**不影响分数**（降权常量为 0，见 §4.1）。
全仓 grep 未见任何把 session id 写进 commit 的路径。离提交侧最近的反而是
`teamai ci extract-mr` / `import --from-mr`：从 MR 的 diff 与 commits 里提取知识建议，
方向是 **MR → 知识**，仍然不是 commit → 会话。

### 4.2 多工具配置的「key 级手术」

`src/coauthor-reconcile.ts` 和 MCP reconcile 共用一个原则，注释里写得很清楚：
目标文件**不归 teamai 所有**（`~/.codex/config.toml` 里有模型和信任设置、
`~/.cursor/cli-config.json` 有用户自己的配置），所以每次写入都是**对现有文档的
key 级手术，绝不整份重生成**；Codex 的 TOML 走文本手术以保住用户的注释。

同一个「要不要给 AI 的 commit 打 Co-Authored-By」意图，三个工具族三种表达：

| 族 | 落点 | 可靠性 |
|---|---|---|
| Claude 系 | `settings.json` 的 `attribution.{commit,pr}` | 确定 |
| Codex 系 | `~/.codex/config.toml` 的 `commit_attribution` | 尽力而为（还需 `codex_git_commit=true`，它不强开） |
| Cursor | `~/.cursor/cli-config.json` 的 `attribution.attributeCommitsToAgent` | 尽力而为（已知上游 bug 可能忽略） |

**只写不删**：团队之后撤销策略时不回滚，因为用户可能已经依赖那条 trailer 了。
上次写入的意图记在 `state.coAuthorManaged` 里保证幂等。

这是全仓工程判断最成熟的一处：明确区分了「我拥有的文件」和「我借住的文件」。

### 4.3 数据落点：业务仓零残留

`docs/designs/data-directory-layout.md` 记了一次重构：机器本地数据原先落在
`<repo>/.teamai/`，实测一个真实 checkout 里**占 18 MB**（团队仓 clone 12 MB +
skill 资源 4.1 MB + 搜索索引 1.8 MB）。三个问题：污染业务仓工作区、worktree 里读不到
（gitignore 的目录不随 worktree 走）、多项目数据混在一起。

改成 `~/.teamai/projects/<slug>/` 分区，目标是**业务仓零残留**。

两条限定：

- **零残留只是独立团队仓模式的目标。单仓模式（self mode，`teamai init .`）刻意反着来**：
  skills / rules / docs / learnings 和 `teamai.yaml` 提交在业务仓 **main** 上的 `.teamai/`，
  随 `git clone` 走；members / sessions / votes / stats 推到同一 origin 的 `teamai-reports`
  **孤儿分支**（独立历史）；只有 config / token / state 留本机（gitignore）。
  `data-directory-layout.md` 把 self 模式列为迁移的硬 no-op，理由就是「its `.teamai/` is
  team knowledge committed to main」。
- **旧安装自动迁移**（Unreleased）：首次 `init` / `pull` / `push` 把 `<repo>/.teamai/`
  复制 → 校验 → 原子切换进分区，旧目录保留为 `.teamai.bak/` 作人工回滚；只读命令与
  `hook-dispatch` 永不触发迁移，迁移后不支持降级。

分区键用「双锚」模型：

```
projectAnchor  = git worktree list --porcelain 的第一条（主 checkout）
                 → 稳定的项目身份，机器数据按它分区
workspaceRoot  = git rev-parse --show-toplevel（当前 checkout）
                 → 项目级 AI 工具资源必须写这里
```

资源必须落 `workspaceRoot` 的原因：所有 AI 工具都是从启动目录往上扫到**当前**仓根来
发现项目资源的，没有一个会跟到主 checkout 去。

⚠️ **这条设计（默认模式）与本项目的 D2 决策方向相反**，是两边最根本的架构分歧；self 模式
让知识随代码走，与我们部分重合，但会话/摩擦数据仍在代码提交历史之外。见对比文档 §4。

### 4.4 hook 策略：只用 harness 生命周期 hook，不碰 git hook

装的是 AI 工具自己的 hook（`src/builtin-hooks.ts`）：

| 事件 | 挂的 handler（`hook-handlers.ts` 注册表） | 超时* |
|---|---|---|
| `SessionStart` | pull（后台）、dashboard 上报、MR 提示、包声明提示、HTTP 后端同步 | 15s |
| `Stop` | 更新检查（后台）、votes 同步、**contribute 检查**、dashboard 上报（含 transcript 扫描）、HTTP 后端同步 | 15s |
| `PostToolUse`（`*` / `Skill` / `TodoWrite`） | dashboard 计数、Skill 埋点、TodoWrite 的 recall 提醒 | 10s / 10s / 3s |
| `UserPromptSubmit` | 延迟提示投递、包提示投递、slash 命令埋点、dashboard 上报 | 10s |

\* 超时只渲染给 Cursor / WorkBuddy / CodeBuddy（`builtinHookDefs()` 里 `withTimeout` 的三个分支），
**Claude Code 与 Codex 的条目不带 timeout**。全部经 `teamai hook-dispatch <event>` 一个入口分发；
团队还能在 `hooks/hooks.yaml` 里自声明任意事件的 hook（文档示例就是 `PreToolUse`），
并禁用或覆盖内置 hook 的超时。

**全仓不装 git hook，也不设 `core.hooksPath`**。`src/utils/git.ts` 里唯一相关的一处是
`commitSkippingHooks()`——它在自己管理的 worktree 里用 `--no-verify` 跳过用户的
husky，注释明确写「`--no-verify` 只作用于这个 git 进程，不写 `core.hooksPath`，
不改变用户平常的 `git commit`」。

**这是个自觉的边界**：它不介入用户的提交流程。代价是它拿不到任何提交侧的信息。

## 5. 工程质量观察

**好的：**

- 测试与实现近 1:1（57K vs 62K 行），且有独立的 e2e 套件（`vitest.e2e.config.ts`），
  包含对真实 GitLab / GitCode / CNB provider 的 live 测试。
- 注释写「为什么」不写「是什么」。`coauthor-reconcile.ts` 开头那段
  「目标文件不归 teamai 所有」、`contribute-check.ts` 开头的 ASCII 数据流图，都是
  能直接回答审计问题的注释。
- 防御性解析成体系：`sanitizeSessionId()` 修过一个真实 bug（PID 兜底 id 里的 `/`
  造出了永远回收不掉的嵌套目录）；`parseSessionFriction()` 把畸形缓存当 cache miss 处理；
  `isValidDocId()` 挡掉文档示例里的 `<id1>` 占位符。这些都是**被真实故障教过**的痕迹。
- 降级路径明确：AST 挂了退启发式并记 gap，不是静默失败。

**需要留意的：**

- 判据依赖英文消息串硬编码（`'[Request interrupted by user'` 等），上游改文案即静默失效。
  这是**本项目的同款脆弱点**，两边都没解。
- 脱敏发生在**出口**而非入口：UserPromptSubmit 把 prompt 前 200 字符**原样**写进本机
  `~/.teamai/dashboard/events.jsonl`（`parseHookEvent()`），`redactWithEnv()` 只在 contribute
  提示、session save 的首 prompt、Stop 时截取的 AI 输出三处调用。使用指南写的
  「不落地任何 prompt 原文」不准——明文不出机器，但确实落了盘。
- friction 判据的覆盖面有洞（见对比文档 §3），但因为它只服务一个阈值，影响被稀释了。
- `correction` 是纯启发式（词表 + 60s 窗口），代码里没看到准确率实测；中英日词表在
  多语言混用的会话里的行为未知。
- beta 层的能力（recall / codebase / dashboard）在 README 里明确标 beta，
  10 个 harness × 13 种能力的矩阵里有不少 `—`，OpenCode / OpenClaw / Hermes / DSH
  整个 Team Improvement 列都是空的。

## 6. 它明确不做什么

对照本项目关心的问题，逐条列清楚（全部经 grep 核实，非推断）：

| 能力 | teamai-cli | 依据 |
|---|---|---|
| commit ↔ session 关联 | ❌ 无 | 全仓无写 session id 进 commit 的路径；`hasGitCommitInSession` 只做时间窗存在性判断（且权重为 0）；`ci extract-mr` / `import --from-mr` 是 MR → 知识，方向不同 |
| 行级 / 代码归属 | ❌ 无 | — |
| 审计过程留痕 | ❌ 无 | `review-cmd` / `review-store` 审的是**知识库待审条目**（`.teamai/pending-review.jsonl`），不是代码审计 |
| 留痕数据随代码走 | ❌ 默认模式反向设计 | `data-directory-layout.md` 的目标就是业务仓零残留；**self 模式例外**：知识资产随 main 走，会话/摩擦上报走同仓孤儿分支（§4.3） |
| 单事件可回溯（指针回原文） | ❌ 无 | 只存聚合计数与脱敏摘要，不存回跳锚点 |

这些不是缺陷——**它不是干这个的**。列在这里是为了让对比文档有个准确的基线。
