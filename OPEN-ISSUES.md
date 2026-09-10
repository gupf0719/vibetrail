# 审计遗留问题（2026-09-08）

> 三轮审计（一轮自审 + 两轮独立 agent）里**发现了但没有动**的问题。与另几份文档的分工：
> [DESIGN.md §5](DESIGN.md) 记设计层未决项（O1–O7），本文记审计遗留——待核的数字、
> 单方面定下需要确认的决策、已知未修的缺口。**修掉一条删一条，本文为空即可删除。**
>
> 每条写四样：在哪、现状、为什么没动、要动需要什么。
>
> **K6 / G6 / G7 不来自那三轮**：K6 / G6 是 2026-09-09 扫三方项目 teamai-cli、并对那两份文档做
> 对抗性审计时反照出来的（见 [third-party/](third-party/teamai-cli-vs-vibetrail.md)）；
> G7 / G8 / G9 是同日用户看完对比后直接提的需求。G11 是 2026-09-10 用户看完三方对比后提的需求，
> 方案细节另记在 [TODO.md](TODO.md)，本表只记它的一句话与状态。
> 又一次印证 §D 第一条：**盲区要靠换个视角才照得出来**——这次的「视角」是拿别人的
> 实现当镜子，成本比再起一轮审计低得多。

## A. ~~需要在有 agentDock 与语料的机器上重数的数字~~ —— 已解决（2026-09-09）

在有 agentDock 与完整语料的机器上重数完毕，**四组全部不是统计错误**：

| 原记 | 结论 |
|---|---|
| 402 次调用 vs 570+18=588 | **两种口径**：含 `mark-audit.sh` 的 Bash 命令 **405 条**，`mark-audit.sh` 出现 **619 处**（一条命令可含多处）。承重的是「带显式 sha 仅 18 处」，未变 |
| 可恢复性表合计 304 ≠ 294 | **表格结构错**：10（显式 sha）与其余三行**不互斥**，是横切的另一次测量。互斥划分 123+48+123=294。已重排 |
| 637 vs 294 | **口径未写明**：637 = 294 `*.audit.done` + 292 `*.crossverify.done` + 51 `*.commentaudit.done`。已加口径说明 |
| 53+39=92 ≠ 90 | **测量时点不同**，非统计错误。那 2 条是 09-08 测量之后本人在会话里拒绝的两次工具调用（时间戳可查）。⚠️ 曾归因为「数组形态漏计」，**是错的**——见新 §C 表 M1 |

**一条比数字更重要的教训**：语料是**活的**。同一批量 09-08 测 402/277/90，09-09 测
405/282/92——我们工作时它一直在增长。**所有语料级数字必须带测量日期**，
已在 DESIGN.md D3 与 CAPABILITIES.md §2.2 加注。

⚠️ **第二条教训（现场又栽一次）**：上面那个 +2 最初被归因为「审计刚修的数组形态缺陷
恢复了 2 条」——**听起来合理，但是错的**。实测全语料 1145 个 `is_error` 块**全部是字符串
形态、数组形态 0 个**，那个修复是纯防御性的、没恢复任何东西。真因是语料增长。
**把差值归给「刚修好的那个 bug」是最省力的解释，也正因为省力所以危险**——
差值的归因必须单独验证，不能顺手挂在最近的改动上。

2026-09-09 重测的完整口径与命令见 DESIGN.md D3 的口径说明。


## B. ~~我单方面定的、需要确认的决策~~ —— 已拍板（2026-09-09）

四条经三方对照 + 实测后定为 **B / A / A / A**：

### B1 空 patchId 的读方语义 → **改为分档**（唯一推翻原提案的一条）

原提案「一律告警放行」会让**有冲突解决的 merge 整个溜过闸门**，而那是真有人写了代码的。

- 三方：git-ai 标准 §2.2 只豁免**无冲突**的 merge（*"MAY have an empty authorship log"*），
  并要求 merge 的归属 *"MUST only contain attributions for conflict resolution changes"*。
- 实测排除了备选：`diff-tree -m --first-parent` 的退化锚 patch-id **与被合入 commit 的完全相同**，
  会让两者共用一条审计记录。
- 实测发现的解：锚统一改为 `git diff-tree -p --cc --root`。加 `--cc` 后普通与根 commit
  结果**逐字不变**，而有冲突的 merge 变为非空、内容恰为冲突解决部分。**读方无需分支判断。**

五种 commit 的锚与读方语义已写入 [spec §4.0](spec/trace-v1.md)。

### B2 编辑器路径不注入 trailer → **维持**

git 自身惯例相反（`commit -s` 在编辑器前就写入、不判空），但 agent 恒带 `-m`、从不开编辑器，
所以判空守卫的代价为零；去掉它则 `git commit -m ''` 会被 trailer 填成非空而提交成功。
**差异已在 spec §2.0 写明是有意的。**

### B3 删掉 `user_edited_after_agent` → **维持删除**

保留为哨兵的收益是「我们不用的客户端可能有信号」，成本是永久维护一条死规则及其类型守卫，
且与 spec §3.1「已删除的 kind」自相矛盾。将来换客户端时再加。

### B4 `.gitattributes` 声明 `merge=union` → **维持要求**

实测：两分支追加**相同**记录时普通合并即解决、不重复；追加**不同**记录时两边都留。
唯一副作用是文件内顺序可能非时序，而记录带 `at` 时间戳、读方不依赖文件内顺序。
git 自身也为 notes 提供 `union` / `cat_sort_uniq`。一行配置换掉一类人工解冲突。

### B5 删掉 `.gitignore:9` 引用 → **确认删对了**

原文说它「排除 `.claude/projects/` 导致换机器即丢」，但 transcript 在 `~/.claude/projects/`
（home 目录），仓库的 .gitignore 管不到它，因果不成立。


## C. 中心表：所有未完成项

> **这是唯一的未完成项清单。** DESIGN.md §5 与 CAPABILITIES.md §3 只留指针，不重复描述——
> 三处各记一份是上一版的实际状态，其中至少三组是同一件事（hook 无引导 / 提取器去重 /
> `core.hooksPath`），正是「必须与 X 保持一致」那类会漂的拷贝。

| ID | 类型 | 优先级 | 一句话 |
|---|---|---|---|
| ~~**G1**~~ | 功能缺口 | ✅ | ~~查询端完全缺失~~ —— **已实现** `tools/vibetrail`。做完当场照出一个写入端缺陷（见 K5）|
| **G2** | 功能缺口 | 🔴 | **session 流水的写入者未定义**——spec §3 定了格式，没说谁写、何时写（§2 的 trailer 写入者已解决） |
| **K6** | 已知缺陷 | 🔴 | **trace 已落自由文本，且一处脱敏都没有**——`audits/*.jsonl` 的 `findings[].claim`（审计结论正文，**由审计 agent 生成**，正文里完全可能带上被审代码片段、路径、密钥样本）与 `agents[].perspective`；`sessions/*.jsonl` 的 `end.subagents[].desc` 与 `session.cwd`（绝对路径，带用户名与项目名）。这些**随代码入仓**，推远端即团队可见。三方对照：teamai-cli 的对等字段（`promptSummary` / `firstPrompt`）**全部强制过 `redactWithEnv()`**，且团队推送默认只推计数与工具名、自由文本要显式 opt-in。要动：把「trace 落自由文本前必须过脱敏」写进 [spec §5 稳定面](spec/trace-v1.md)，并给 `claim` / `desc` 补脱敏环节。**原 K4（分支名）是本条的子集，已并入**。**LoongSuite Pilot 提供了更完整的样板与三条教训**（[采集清单 §5 / §6](third-party/loongsuite-pilot-collection.md)）：模型上它把「采不采」（`captureMessageContent`）与「擦不擦」（`mask`）拆成管线里两个独立步骤，比单一开关表达力强；字段准入实际是**三层**——白名单（`DEFAULT_RESOURCE_ENV_FIELD_MAP` 只放行 2 个 env）+ **按 key 名拒绝整个字段**（`SENSITIVE_FIELD_NAME_RE = /(^\|[_.-])(TOKEN\|SECRET\|PASSWORD\|CREDENTIAL\|COOKIE)([_.-]\|$)\|^(API_KEY\|API_HEADER)$/i`，用分隔符做词边界所以 `TOKENIZER` 不误伤，`assets/hooks/shared/resource-context.mjs:5`）+ 值长度上限 512。**「按 key 名拒绝」这一层我们完全没有**，而它比按值匹配更可靠。三条教训都是我们可能犯的：① **出口那层要有测试守着**——它的出站兜底 `redactCodeGenerationFields()` 删的是大部分内容字段（清单里漏了 system prompt、工具定义和多模态元数据，也没有 `error.message`），又因 `endpoint.redact` 全仓硬编码 `false` 而永不执行，写了、合理、就是不生效；② **字段清单要有单一真相源**——它的内容策略有两份 `MESSAGE_CONTENT_FIELDS`（hook 侧 14 项 / daemon 侧 17 项），已经分叉，且**两份都漏了 `error.message`**（工具失败时的结果正文前 500 字符），于是关掉内容采集它照样出本机；③ **默认值决定实际效果**——两层设计得再好，默认 `true` + `none` 就是「全采不脱」。另有一条直接对上我们 `session.cwd` 的硬闸：`docs/agent-onboarding.md:368` 规定 fixture **不得含**真实 prompt、transcript、用户名、home 路径、仓库路径、session ID、凭据 |
| **G3** | 功能缺口 | 🟡 | **没有「保证每人跑过 install」的机制**——脚本已有（`vibetrail-install` / `-doctor`，见 [CAPABILITIES §2.5](CAPABILITIES.md)），但 git 不允许仓库自动装 hook。业内解法是搭车在人本来就跑的步骤上（husky 挂 `npm install`）；agentDock 可搭 `Makefile`，**未做** |
| **K5** | ~~已知缺陷~~ | ✅ | ~~一次「拒绝工具调用」被记两条~~ —— **已修**：`for tool use` 变体拆成独立 kind。实测 35 = 35 精确对上（见 spec §3.1）|
| **K1** | 已知缺陷 | 🟡 | **提取器重复计数未去重**——方案已定（同 sid + 同 kind + ≤10 秒，靠 `isSidechain`/`agentId` 分层），但 `hit` 还没输出这两个字段。⚠️ **方案里的「≤10 秒」需要复核**：LoongSuite Pilot 在同一个问题上（子 agent 记录并入父 trace）的结论是 `docs/codex-subagent-fusion.md:9-21`——① 去重键必须用**父侧的 tool-call id**，`agent_path`（≈ 我们的 agent 名 / 目录）**明确不得做去重键**，因为它会被多次 spawn 复用；② **`time_order` 只有诊断权**，「可以在关联快照和日志里解释一个可能的关系，但不能创建融合候选、不能捕获子终态、不能延迟父终态」（原文 fusion candidate：把子记录并进父 trace 的候选，对应我们的合并去重）。我们的「≤10 秒」正是这一类信号：结构性键（`agentId` / 记录 uuid）分层是对的，时间窗若**单独**决定合并，两次真实独立的同类分歧（例如用户连续拒绝两个同名工具调用）会被并成一条，而且不会报错。③ 它的降级规则同样值得抄：匹配不上的子记录**独立发一次而不是丢弃**——去重宁可留重复，不可丢事件（`:51-65`）。落地前先确认时间窗在我们的判据下是必需项还是可去掉 |
| **G6** | 功能缺口 | 🟡 | **判据 fixture 是照「见过的形态」手搭的，没见过的第三种形态对测试不可见**——`tools/fixtures.jsonl` 26 条覆盖两种拒绝正文（`Permission to use …` 六个变体含多行命令 + `The user doesn't want to proceed …`），这次核过没有镜像盲区；但**机制上挡不住新形态**。三方实测的反例值得警惕：teamai-cli 的判据测试与我们同级完备（13 个测试文件涉及判据，含一条把两个 interrupt 变体钉成预期的用例），却因全套件里 `Permission to use` 出现 **0 次**，对它自己 52% 的人拒漏判**恒绿**——测试不是缺失，是靠 fixture 选择恒绿。这正是 [CAPABILITIES §2.4](CAPABILITIES.md) 记的「假绿」模式。要动：fixture 来源从「见过的」换成「从全语料聚类出的 `is_error` / interrupt 正文形态」。**扫完 LoongSuite Pilot 后结论不变：业内仍然没人解。** 它整个仓里没有任何聚类或语料抽样方法；唯一沾边的是一个**方向性**证明——`docs/codex-aborted-turn-recovery.md:11-12,64-67` 判「用户打断」用的是类型化记录 `event_msg:turn_aborted` 而**不是** UI 字符串，输出再归一到固定词表。也就是说：**能拿到类型化信号的 harness 就不该匹配字符串**。Claude Code 的 transcript 在这一点上不给类型（`[Request interrupted by user` 只有正文），所以我们和它们一样被迫吃字符串——但这条提醒值得记：每次上游更新都该先查一遍有没有新增的类型化字段可以替换掉硬编码串 |
| **G10** | 功能缺口 | 🟡 | **采集范围没有回归钉子**——判据有 `tools/test-extract.sh` 守着，「扫过哪些文件」**一条断言都没有**。现状是对的（`vibetrail-sync` 按 `git worktree list` 聚合，实测覆盖 762 个 transcript = 主会话 34 + 子 agent 728），但没有任何测试会在它变窄时失败：范围一缩，判据测试**全绿**，数字静默减半。这是 G6 的姊妹问题——G6 是判据盲区，本条是范围盲区，且**本条更隐蔽**（G6 至少会在新形态出现时错，本条连错都不会报）。三方实测的反例：teamai-cli 的判据方法论与我们同源，实际差距的一多半却来自「只扫了 hook 递来的那一个文件」这种与判据无关的地方（[对比 §3.2 / §7 第 2 条](third-party/teamai-cli-vs-vibetrail.md)）；LoongSuite Pilot 是反过来的样本：它装了 `SubagentStop`，**提取层还有测试钉着**——`tests/unit/hooks/claude-code/hook-processor.test.mjs` 的「claude-code 一级子 Agent 上报」一组用例（`:725` 起）断言导出记录里必须有 `gen_ai.agent.scope = subagent`，删掉子 agent 展开就红；它缺的是部署层，没有测试断言 `agents.d/claude-code.json` 必须注册 `SubagentStop`（Codex 那边有，`tests/unit/hooks/codex/hook-processor.test.mjs:52-61`）。三方里我们和 teamai 两层都没有。Pilot 还顺带给了一个**文件级钉子抓不到的反例**：它扫到了文件，但解析器按 promptId 分组，把轮末的中断记录静默丢了——用它自己的解析器离线跑本机语料，265 条中断记录只有 5 条进了事件，它的子 agent 测试照样全绿（[采集清单 §1.2b](third-party/loongsuite-pilot-collection.md)）。所以钉子不能只钉「扫了哪些文件」，还要钉「每类记录走到输出的条数」。**要动需要什么**：LoongSuite Pilot 有三种钉子分别对应三种成因（[对比 §6.2b](third-party/teamai-cli-vs-vibetrail.md) 有摘要，行号以本条为准）：① **改代码改缩了** —— `tests/performance/trace-runtime.perf.mjs` 用 esbuild 插件把 import 重定向到 `git show <baseline>:<path>`，baseline 与 modified 各打一个包，同一份输入在独立子进程里轮流跑（`:114`），要求两边的 `eventDigest` / `traceDigest` 两个 sha256 与条数完全一致（插件 `:98-104`，比对 `:124-125`；`:113` 按 `run % 2` 交替先后顺序，消除预热偏差）；② **运行时环境变了** —— `input-runtime-metrics` 四阶段漏斗（`raw_read_*` → `raw_in_*` → `parse_*` → `in_events`），105 行纯标量、payload-free、维度不含 session_id 与文件路径所以基数不随数据量增长；③ **I/O 静默吞掉** —— 要求扫描器返回显式的 scan-completeness 信号，「空结果不等于删除」（`docs/agent-onboarding.md:270-274`）。**对我们最便宜的是 ①**：钉一份语料，HEAD 与基线 ref 各跑一次提取器，diff 的不是判据结果而是**扫过的文件路径排序后的摘要**（`find \| sort \| sha256sum` 即可），范围一缩摘要立刻变；② 等 G7 落成 hook 之后再说。⚠️ 抄的时候注意：Pilot 那条漏斗恒等式（`parse_success + parse_failed = raw_in_records`）在它 `tests/` 里 **grep 不到断言**，只是文档口径——我们要做成断言，别把「写在文档里」当成「守住了」 |
| ~~**G4**~~ | 功能缺口 | ✅ | ~~没有留痕自检~~ —— **已实现** `tools/vibetrail-doctor` |
| **G7** | 需求 | 🔴 | **「做成和 teamai 一样：装一次就行，然后 Claude 每次对话写代码的时候自动上报两路信息」**（用户原话，2026-09-09）。它把 G2 剩下的一半（sessions 谁写、何时写）和 G3（保证每人跑过 install）合成一件事。**现状**：git 的 `prepare-commit-msg` 每个 clone 手跑一次 `vibetrail-install`；`vibetrail-sync` 完全手动；Stop 侧只有审计闸门（`tools/fixtures/check-audit-stop.sh`）。**teamai 的做法**（[分析文档 §4.4](third-party/teamai-cli.md)）：一次 `init` 把 SessionStart / Stop / PostToolUse / UserPromptSubmit 写进各工具 settings，全部经 `teamai hook-dispatch <event>` 一个入口分发；其 self 模式更进一步——把 `.claude/settings.json` 连 hooks **提交到 main**，队友 clone 即得，SessionStart 再自愈式 bootstrap 本机侧。**要动需要什么**：① 在 `.claude/settings.json`（可入仓，不像 git hook）里挂 SessionStart → 幂等跑 `vibetrail-install`（G3 由此消失）、Stop → 投影当前会话（G2 由此消失）；hook stdin 直接给 `transcript_path` / `session_id`，不需要 ID 映射（[DESIGN §2.1](DESIGN.md)）；② 投影仍须按 `git worktree list` 聚合而不是只扫 hook 递来的那一个文件——teamai 正是栽在这一步，58% 的人拒在子 agent 文件里（[对比 §3.2](third-party/teamai-cli-vs-vibetrail.md)）；③ 每次 Stop 都重投影的成本要量（单会话 transcript 最大 106MB，`vibetrail-sync` 是整份重生成）；④ 入仓的项目级 hooks 在 Claude Code 里是否要用户确认一次，**待实测**。**LoongSuite Pilot 在同一件事上踩过的坑更多，四条直接可用**（[分析文档 §4.4](third-party/loongsuite-pilot.md)、[采集清单 §1](third-party/loongsuite-pilot-collection.md)）：⑤ **hook 事件用 spool 模式**——排他创建临时文件 + 原子 rename，采集端只读已发布的文件，所以**永远读不到半条**；hook 侧 fail-open 不阻断宿主；只在下游 checkpoint 推进之后才删源文件（`docs/agent-onboarding.md:299-323`）。我们 Stop 时重投影同样有「写到一半被读」的窗口。⑥ **升级要清自家旧条目，被删要能自愈**——Pilot 每次部署前先跑一遍迁移，按子串删掉 settings 里含 `otel-claude-hook` 或 `.cache/opentelemetry.instrumentation.claude` 的条目（`src/deployment/plugin-migration.ts:85-88`，只在 `~/.cache/opentelemetry.instrumentation.claude/` 还在时才跑，`:166-170`；`agents.d/claude-code.json:24-27` 的 `replaceHookCommands` 也列了这两类，但按命令全文精确匹配，`src/hooks/hook-manager.ts:627-633`），清的都是它**自家上一代** Claude 插件的残留（`plugin-migration.ts:2`「清理老 Claude/Codex plugin 残留」；卸载脚本也把 `otel-claude-hook` 算作 `isOurs`，`deploy/installer-opensource.sh:1737`）；它还配了 watchdog，默认每 5 分钟查一次，某个事件下找不到命令里含它脚本名的条目就重新注入，两次修复至少隔 10 分钟、**不设每日上限**（`src/core/hook-watchdog.ts:326-411,447-476`、`src/core/config-loader.ts:658-669`；每天最多 3 次那套只管 rc 块等「拦截类」目标）。本条第一版把这两类条目读成「别家的」，推出「`.claude/settings.json` 是多方争抢的位置」——**撤回**：Pilot 只写用户级 `~/.claude/settings.json`，删的也只是自己的旧条目，碰不到我们计划用的项目级 `.claude/settings.json`，争抢在它这里没有证据。能借的是两个做法：`vibetrail-install` 升级时按 marker 清掉自己的旧条目；`vibetrail-doctor` 能查出条目被删了。⑦ **装卸要对称**：Pilot 的卸载会清理写进各 agent 配置的全部接入内容，`--purge` 才连数据目录一起删（`docs/zh-CN/installation.md:243`）。`vibetrail-install` 目前没有对称的 uninstall。⑧ **别依赖用户的运行时环境**：它为「用户切换/删除 node 导致采集中断」专门下载并固定一份托管 node，三级回退都不硬失败（`installation.md:97-127`）——我们是 shell/jq，对应的风险是 `jq` 版本与 `PATH`，`vibetrail-doctor` 应当把这条纳入自检。**先记录、暂不定**（用户 09-09：等需求和功能完善后再定）：「两路」具体指哪两路——最可能是 FLOW ④ 的两条投影流 `sessions/`（会话摘要 + 人机分歧）与 `audits/`（审计记录）；另一种读法是 sessions 与 commit 归属 trailer（后者装完 git hook 后已自动）。09-10 用户又提了第三种：「全量数据」和「人机分歧这些关键数据」分两路上传，或者在云上从全量数据里扫出分歧。对照 LoongSuite Pilot 实测（[采集清单 §1.2b](third-party/loongsuite-pilot-collection.md)）：全量这一路若直接用 Pilot 的事件，人主动打断这类分歧的记录根本没上传，云上扫不出来；工具报错那三类能扫出来。所以分歧这一路应当在本机从原始 transcript 提取，两路按 Claude Code 会话 id 关联（本项目 trailer 的 `Claude-Session` 与 Pilot 的 `gen_ai.session.id` 是同一个值）。定了再拆任务 |
| **G8** | 需求 | 🔴 | **「采集能限制在指定项目，就像 teamai 一样」**（用户原话，2026-09-09）。**现状**：`vibetrail-sync` 按 `git worktree list` 只认领本仓的会话，天然按仓隔离；但没有「这台机器上哪些项目开了采集」的开关，G7 落成 harness hook 之后尤其要有——hook 写在 HOME 的工具设置里就是全局的。**teamai 的做法**（[分析文档 §4.3 / §4.4](third-party/teamai-cli.md)，09-09 对照源码复核后改）：hook 挂在 HOME，`hook-dispatch` 只用传入的 `cwd` 选 config、**不做门控**——config 取不到时注释自称 fail-open，19 条 handler 照跑，`dashboard-report` 在没 init 过的目录一样把事件写进本机 `events.jsonl`（`src/hook-dispatch-cli.ts:185`、`src/hook-handlers.ts:503-517`）；「限定」只发生在上报环节，`filterEventsByScope` 按 cwd 是否在 projectRoot 下决定哪个团队仓收哪些会话（[采集清单 §1 / §3.1](third-party/teamai-cli-collection.md)）。也就是说 teamai 有的是「上报限定」，不是「采集限定」，第一版写的「其余目录一律早退」不成立；分区键用 `git worktree list` 第一条当稳定身份。**要动需要什么**：一份机器级的项目清单（按主 checkout 分区，worktree 共享），分发入口先查清单再干活，`doctor` 报「本仓在不在清单里」。**先记录、暂不定**：清单粒度（仓 / 目录 / 分支）与开关方式（install 时登记还是单独命令），等需求和功能完善后再定 |
| **G9** | 需求 | 🔴 | **「要在本地能展示一份采集的内容，让开发放心没有侵犯隐私」**（用户原话，2026-09-09）。**现状**：查询端 `vibetrail show / log / session / diverge` 读的是同一份数据，但没有面向「我被记了什么」的视图；而 K6 已证明 trace 里确有自由文本（`claim` / `desc` / `cwd`），先展示出来的会是问题本身。**teamai 的做法**（[分析文档 §3.3](third-party/teamai-cli.md)、[对比 §6.1](third-party/teamai-cli-vs-vibetrail.md)）：`session save` 先在本地落一份脱敏摘要，团队推送默认只推计数与工具名，prompt 文本要显式 `--include-prompt`；dashboard 只在本地起；文档明写「只统计次数」（本地事件流其实是明文，见对比 §6.1）。**要动需要什么**：一条命令把「即将 / 已经进仓的记录」原样列出，并明说**不采什么**（prompt 正文、thinking、代码 diff——D2 只存指针与摘要），`vibetrail-sync --dry-run` 先预览再落盘；**依赖 K6 先补脱敏**。**LoongSuite Pilot 在这条上没有完整答案，值得记下来免得下次再去翻**：它有本机 Dashboard（`127.0.0.1:8765`，只读 `logs/metrics-summary.json`）和 `input-runtime-metrics` 四阶段漏斗，但两者回答的都是「**多少**」（Dashboard 是 token、会话、请求、工具调用、模型与仓库的用量汇总，漏斗是读了几次、几条、产出几个事件），**不是「里面有什么」**。它文档化的「看」是一份默认开的本地 JSONL 副本：`docs/zh-CN/overview.md:91` 说没配远端时 JSONL 默认开启、「方便本地验证采集是否生效」，`docs/zh-CN/sls-output.md:158-162` 教的是 `tail -f ~/.loongsuite-pilot/logs/output/*.jsonl`——能看，但得自己翻原始事件，没有任何命令或视图按「我被记了什么」汇总；想少暴露，文档给的路是 `captureMessageContent: false` 让它**不采**，再加脱敏（`docs/zh-CN/masking.md:7-12` 建议两者同时用）。所以 G9 要的那种「给开发看、让开发放心」的视图在两家三方实现里都没有先例，我们要自己设计；可借的只有分层展示的口径（teamai 的「计数 / 截断文本 / 路径类信息」三分法，见 [teamai 采集清单 §6](third-party/teamai-cli-collection.md)）。**先记录、暂不定**：展示形态（CLI 表格 / markdown / 本地网页）与是否连带展示 commit trailer，等需求和功能完善后再定 |
| **G11** | 需求 | 🔴 | **多个会话改、最后一个会话提交时，追回每一行出自哪个会话的哪次工具调用，再回到对话里判断是模型错还是人错**（用户 2026-09-10 提出）。已有方案与 demo，未开工；下一步先在 agentDock 上量不拍快照时的覆盖率与单次快照耗时。需求原话、方案、验证、限制、拆解见 [TODO.md](TODO.md) |
| **D1** | 待定决策 | 🟡 | **归属语义三处不一致**：`cherry-pick -n` 之后的 commit 与 `revert` 按执行者记；agent amend 人工 commit 记成 agent。都实测过、都写明了，但「该不该这样」没定 |
| **D2** | 待定决策 | 🟢 | **SpecStory 留不留人类可读副本**（原 DESIGN O2；`brew trust` 随它自动定） |
| **K2** | 已知缺陷 | 🟢 | **跨仓归属未定义**——一个会话可跨多仓，本项目开发会话即反例（`cwd` 在 agentDock、commit 在 vibetrail） |
| **G5** | 功能缺口 | 🟢 | **`tool` 字段未产出**——被拒的工具名可从 `Permission to use (\S+)` 捕获，可选字段不升版本 |
| **K3** | 已知缺陷 | 🟢 | **空消息守卫假设 `core.commentChar` 为 `#`**——改了注释符的仓退化为不判空（不崩溃） |
| **M1** | ~~未量~~ | ✅ | ~~`is_error` 数组形态在语料里有多少~~ —— **已量（09-09）：1145 个 `is_error` 块全部字符串形态，数组形态 0 个**。铁律五的修复是纯防御，未恢复任何漏计 |
| **M2** | 未量 | 🟢 | **召回率绝对基线未测**——现有基线是无锚子串候选集；`permission_denied` 的「人工核对候选集」口径没记 |
| **M3** | 未量 | 🟢 | **`.meta.json` 字段集随版本变**——2.1.85 两项 / 2.1.202 三项 / 2.1.260 四项。将来写 `end.subagents` 要按缺失容错 |

**已关闭**：O1 git-ai 采纳（否决）· O3 trace schema（已定）· O5 telemetry 配置（随 O1 消失）·
O6 存量 marker 迁移（不迁移）· O7 `core.hooksPath`（并入 G3）· A 节四组数字 · B 节五条决策 ·
M1 数组形态 · G4 留痕自检 · G3 的实现部分 · **G1 查询端** · **G2 session 投影** · **K5 跨 kind 重复** ·
K4 分歧记录含分支名（并入 K6）·
**L2 审计留痕**（`vibetrail-audit`，断链二解决）。


## D. 三轮审计的方法教训

- **自审一条高危都没抓到，三条全是独立 agent 用实验抓的。** 自己改过的东西看不出盲区；
  「修完再起一个新 agent 从头审」应当成固定流程。
- **hook 类断言必须逐场景实测**，尤其是「某事不会发生」（人工 commit 不会被记成 agent 的）。
  这次的三条高危分别藏在 rebase 重放、merge 的非编辑器路径、trailer 块的段落规则里，
  读代码看不出来。
- **模拟「人工操作」时要 `env -u CLAUDE_CODE_SESSION_ID`。** agent 的 shell 自带这个变量，
  不去掉则「人工提交」全是假的——我第一次验证 hook 就是这样把一轮实验全污染了。
