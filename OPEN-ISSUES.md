# 审计遗留问题（2026-09-08）

> 三轮审计（一轮自审 + 两轮独立 agent）里**发现了但没有动**的问题。与另几份文档的分工：
> [DESIGN.md §10](DESIGN.md) 只留指针，本文记全部未完成项——待核的数字、
> 单方面定下需要确认的决策、已知未修的缺口。**修掉一条删一条，本文为空即可删除。**
>
> 每条写四样：在哪、现状、为什么没动、要动需要什么。
>
> **K6、G6–G11 不来自那三轮**：K6 / G6 是 2026-09-09 扫三方项目 teamai-cli、并对那两份文档做
> 对抗性审计时反照出来的（见 [third-party/](third-party/teamai-cli-vs-vibetrail.md)）；
> G7 / G8 / G9 是同日用户看完对比后直接提的需求。G10 是 2026-09-10 扫 LoongSuite Pilot、把对比扩为三方时反照出来的。
> G11 是 2026-09-10 用户看完三方对比后提的需求。**G7 已于 2026-09-14 定稿进 [DESIGN.md](DESIGN.md)**，它的未定项拆成本表 U1–U10，
> 随旧方案（仓内投影、`Claude-Session` trailer）退役的条目同日关闭；2026-09-15 D5（不传 transcript 原文件、云端定协议 1.0、30 天够用）关 U3 / U10 / K1，G5 升前置；G11 的方案细节另记在 [TODO.md](TODO.md)，本表只记一句话与状态。
> 又一次印证 §D 第一条：**盲区要靠换个视角才照得出来**——这次的「视角」是拿别人的
> 实现当镜子，成本比再起一轮审计低得多。

## A–B. 已解决的两批（2026-09-09），只留一句话

**A 四组待核数字**：重数后全部不是统计错误（两种口径、表格结构、口径未写明、测量时点不同）。
**B 五条单方面决策**：B1 审计锚（后又改为 `Vibetrail-Id` trailer，见 [spec/trace-v1.md §2](spec/trace-v1.md)）、B2 编辑器路径不注入 trailer、
B4 `.gitattributes` 的 `merge=union`、B5 删 `.gitignore:9` 引用——B2 随 `Claude-Session` trailer 退役（2026-09-14，D4），B4 只剩审计线在用；
B3 删掉 `user_edited_after_agent` 进了 [spec/diverge-v1.md §2.1](spec/diverge-v1.md)。两批的教训并入 §D。



## C. 中心表：所有未完成项

> **这是唯一的未完成项清单。** DESIGN.md §10 与 CAPABILITIES.md §3 只留指针，不重复描述——
> 三处各记一份是上一版的实际状态，其中至少三组是同一件事（hook 无引导 / 提取器去重 /
> `core.hooksPath`），正是「必须与 X 保持一致」那类会漂的拷贝。

| ID | 类型 | 优先级 | 一句话 |
|---|---|---|---|
| ~~**G1**~~ | 功能缺口 | ✅ | ~~查询端完全缺失~~ —— **已实现** `tools/vibetrail`。做完当场照出一个写入端缺陷（见 K5）|
| ~~**G2**~~ | 功能缺口 | ✅ | ~~session 流水的写入者未定义~~ —— **由 D4 关闭**（2026-09-14）：分歧由 hook 在 UserPromptSubmit / Stop / SessionEnd / SessionStart 补做时写本机 spool，仓内 `sessions/` 停用（DESIGN §3.1） |
| **K6** | 已知缺陷 | 🟡 | **2026-09-14 用户定暂缓：「暂时先不考虑脱敏」，不挡 G7 的上传，G7 落地后再定。D4 之后暴露面从「随代码入仓」变成「全量副本原样上云」；2026-09-15 D5 后再缩成「分歧事件带的几段正文原样上云」（被拒命令、被打断回复、打断后的人话，DESIGN §4 隐私行），但云端默认全公司可见，已提意见；下面原记的 `sessions/` 两处已随投影退役，`audits/` 两处仍在。** 原记：**trace 已落自由文本，且一处脱敏都没有**——`audits/*.jsonl` 的 `findings[].claim`（审计结论正文，**由审计 agent 生成**，正文里完全可能带上被审代码片段、路径、密钥样本）与 `agents[].perspective`；`sessions/*.jsonl` 的 `end.subagents[].desc` 与 `session.cwd`（绝对路径，带用户名与项目名）。这些**随代码入仓**，推远端即团队可见。三方对照：teamai-cli 的对等字段（`promptSummary` / `firstPrompt`）**全部强制过 `redactWithEnv()`**，且团队推送默认只推计数与工具名、自由文本要显式 opt-in。要动：把「落自由文本前必须过脱敏」写进 [spec/diverge-v1.md §6](spec/diverge-v1.md) 与 [spec/trace-v1.md §4](spec/trace-v1.md) 的稳定面，并给 `claim` 补脱敏环节；全量副本的出本机那层按 DESIGN §4 隐私行的三层准入做。**原 K4（分支名）是本条的子集，已并入**。**LoongSuite Pilot 提供了更完整的样板与三条教训**（[采集清单 §5 / §6](third-party/loongsuite-pilot-collection.md)）：模型上它把「采不采」（`captureMessageContent`）与「擦不擦」（`mask`）拆成管线里两个独立步骤，比单一开关表达力强；字段准入实际是**三层**——白名单（`DEFAULT_RESOURCE_ENV_FIELD_MAP` 只放行 2 个 env）+ **按 key 名拒绝整个字段**（`SENSITIVE_FIELD_NAME_RE = /(^\|[_.-])(TOKEN\|SECRET\|PASSWORD\|CREDENTIAL\|COOKIE)([_.-]\|$)\|^(API_KEY\|API_HEADER)$/i`，用分隔符做词边界所以 `TOKENIZER` 不误伤，`assets/hooks/shared/resource-context.mjs:5`）+ 值长度上限 512。**「按 key 名拒绝」这一层我们完全没有**，而它比按值匹配更可靠。三条教训都是我们可能犯的：① **出口那层要有测试守着**——它的出站兜底 `redactCodeGenerationFields()` 删的是大部分内容字段（清单里漏了 system prompt、工具定义和多模态元数据，也没有 `error.message`），又因 `endpoint.redact` 全仓硬编码 `false` 而永不执行，写了、合理、就是不生效；② **字段清单要有单一真相源**——它的内容策略有两份 `MESSAGE_CONTENT_FIELDS`（hook 侧 14 项 / daemon 侧 17 项），已经分叉，且**两份都漏了 `error.message`**（工具失败时的结果正文前 500 字符），于是关掉内容采集它照样出本机；③ **默认值决定实际效果**——两层设计得再好，默认 `true` + `none` 就是「全采不脱」。另有一条直接对上我们 `session.cwd` 的硬闸：`docs/agent-onboarding.md:368` 规定 fixture **不得含**真实 prompt、transcript、用户名、home 路径、仓库路径、session ID、凭据 |
| ~~**G3**~~ | 功能缺口 | ✅ | ~~没有「保证每人跑过 install」的机制~~ —— **前提消失**（2026-09-14，D4）：G7 不装 git hook、被观测仓零写入、机器级装一次，没有东西要每人装。审计线自己的 git hook 是否保留见 U6 |
| **K5** | ~~已知缺陷~~ | ✅ | ~~一次「拒绝工具调用」被记两条~~ —— **已修**：`for tool use` 变体拆成独立 kind。实测 35 = 35 精确对上（见 [spec/diverge-v1.md §2](spec/diverge-v1.md)）|
| ~~**K1**~~ | 已知缺陷 | ✅ | ~~提取器重复计数未去重~~ —— **由 D5 关闭**（2026-09-15）：父会话文件里的打断映射成 `turn.end(interrupted)`、子 agent 文件里的映射成 `subagent.end(cancelled)`，协议里是两个事实，不合并；统计打断只数 `turn.end`。下面的方案与 Pilot 的教训留给将来要合并的人。原记：方案已定（同 sid + 同 kind + ≤10 秒，靠 `isSidechain`/`agentId` 分层），但 `hit` 还没输出这两个字段。⚠️ **方案里的「≤10 秒」需要复核**：LoongSuite Pilot 在同一个问题上（子 agent 记录并入父 trace）的结论是 `docs/codex-subagent-fusion.md:9-21`——① 去重键必须用**父侧的 tool-call id**，`agent_path`（≈ 我们的 agent 名 / 目录）**明确不得做去重键**，因为它会被多次 spawn 复用；② **`time_order` 只有诊断权**，「可以在关联快照和日志里解释一个可能的关系，但不能创建融合候选、不能捕获子终态、不能延迟父终态」（原文 fusion candidate：把子记录并进父 trace 的候选，对应我们的合并去重）。我们的「≤10 秒」正是这一类信号：结构性键（`agentId` / 记录 uuid）分层是对的，时间窗若**单独**决定合并，两次真实独立的同类分歧（例如用户连续拒绝两个同名工具调用）会被并成一条，而且不会报错。③ 它的降级规则同样值得抄：匹配不上的子记录**独立发一次而不是丢弃**——去重宁可留重复，不可丢事件（`:51-65`）。落地前先确认时间窗在我们的判据下是必需项还是可去掉 |
| **G6** | 功能缺口 | 🟡 | **判据 fixture 是照「见过的形态」手搭的，没见过的第三种形态对测试不可见**——`tools/fixtures.jsonl` 26 条覆盖两种拒绝正文（`Permission to use …` 六个变体含多行命令 + `The user doesn't want to proceed …`），这次核过没有镜像盲区；但**机制上挡不住新形态**。三方实测的反例值得警惕：teamai-cli 的判据测试与我们同级完备（13 个测试文件涉及判据，含一条把两个 interrupt 变体钉成预期的用例），却因全套件里 `Permission to use` 出现 **0 次**，对它自己 52% 的人拒漏判**恒绿**——测试不是缺失，是靠 fixture 选择恒绿。这正是 [CAPABILITIES §2.2](CAPABILITIES.md) 记的「假绿」模式。要动：fixture 来源从「见过的」换成「从全语料聚类出的 `is_error` / interrupt 正文形态」。**扫完 LoongSuite Pilot 后结论不变：业内仍然没人解。** 它整个仓里没有任何聚类或语料抽样方法；唯一沾边的是一个**方向性**证明——`docs/codex-aborted-turn-recovery.md:11-12,64-67` 判「用户打断」用的是类型化记录 `event_msg:turn_aborted` 而**不是** UI 字符串，输出再归一到固定词表。也就是说：**能拿到类型化信号的 harness 就不该匹配字符串**。Claude Code 的 transcript 在这一点上不给类型（`[Request interrupted by user` 只有正文），所以我们和它们一样被迫吃字符串——但这条提醒值得记：每次上游更新都该先查一遍有没有新增的类型化字段可以替换掉硬编码串 |
| **G10** | 功能缺口 | 🟡 | **采集范围没有回归钉子**——判据有 `tools/test-extract.sh` 守着，「扫过哪些文件」**一条断言都没有**。现状是对的（`vibetrail-sync` 按 `git worktree list` 聚合，实测覆盖 762 个 transcript = 主会话 34 + 子 agent 728），但没有任何测试会在它变窄时失败：范围一缩，判据测试**全绿**，数字静默减半。（2026-09-14：`vibetrail-sync` 退役，钉子改钉 G7 的门控与增量副本范围，已写进 DESIGN A11。）这是 G6 的姊妹问题——G6 是判据盲区，本条是范围盲区，且**本条更隐蔽**（G6 至少会在新形态出现时错，本条连错都不会报）。三方实测的反例：teamai-cli 的判据方法论与我们同源，实际差距的一多半却来自「只扫了 hook 递来的那一个文件」这种与判据无关的地方（[对比 §3.2 / §7 第 2 条](third-party/teamai-cli-vs-vibetrail.md)）；LoongSuite Pilot 是反过来的样本：它装了 `SubagentStop`，**提取层还有测试钉着**——`tests/unit/hooks/claude-code/hook-processor.test.mjs` 的「claude-code 一级子 Agent 上报」一组用例（`:725` 起）断言导出记录里必须有 `gen_ai.agent.scope = subagent`，删掉子 agent 展开就红；它缺的是部署层，没有测试断言 `agents.d/claude-code.json` 必须注册 `SubagentStop`（Codex 那边有，`tests/unit/hooks/codex/hook-processor.test.mjs:52-61`）。三方里我们和 teamai 两层都没有。Pilot 还顺带给了一个**文件级钉子抓不到的反例**：它扫到了文件，但解析器按 promptId 分组，把轮末的中断记录静默丢了——用它自己的解析器离线跑本机语料，265 条中断记录只有 5 条进了事件，它的子 agent 测试照样全绿（[采集清单 §1.2b](third-party/loongsuite-pilot-collection.md)）。所以钉子不能只钉「扫了哪些文件」，还要钉「每类记录走到输出的条数」。**要动需要什么**：LoongSuite Pilot 有三种钉子分别对应三种成因（[对比 §6.2b](third-party/teamai-cli-vs-vibetrail.md) 有摘要，行号以本条为准）：① **改代码改缩了** —— `tests/performance/trace-runtime.perf.mjs` 用 esbuild 插件把 import 重定向到 `git show <baseline>:<path>`，baseline 与 modified 各打一个包，同一份输入在独立子进程里轮流跑（`:114`），要求两边的 `eventDigest` / `traceDigest` 两个 sha256 与条数完全一致（插件 `:98-104`，比对 `:124-125`；`:113` 按 `run % 2` 交替先后顺序，消除预热偏差）；② **运行时环境变了** —— `input-runtime-metrics` 四阶段漏斗（`raw_read_*` → `raw_in_*` → `parse_*` → `in_events`），105 行纯标量、payload-free、维度不含 session_id 与文件路径所以基数不随数据量增长；③ **I/O 静默吞掉** —— 要求扫描器返回显式的 scan-completeness 信号，「空结果不等于删除」（`docs/agent-onboarding.md:270-274`）。**对我们最便宜的是 ①**：钉一份语料，HEAD 与基线 ref 各跑一次提取器，diff 的不是判据结果而是**扫过的文件路径排序后的摘要**（`find \| sort \| sha256sum` 即可），范围一缩摘要立刻变；② 等 G7 落成 hook 之后再说。⚠️ 抄的时候注意：Pilot 那条漏斗恒等式（`parse_success + parse_failed = raw_in_records`）在它 `tests/` 里 **grep 不到断言**，只是文档口径——我们要做成断言，别把「写在文档里」当成「守住了」 |
| ~~**G4**~~ | 功能缺口 | ✅ | ~~没有留痕自检~~ —— **已实现** `tools/vibetrail-doctor` |
| **G7** | 需求 | 🔴 | **hook 采两路数据（全量 + 人机分歧），HTTP push 云端，机器级装一次，被观测仓零写入**——2026-09-14 定稿为 [DESIGN.md](DESIGN.md)（用户原话 §0、方案 §2–§5、决策 D4、验收 §9），拆解在 [TODO.md](TODO.md)，未定项拆成本表 U1–U10；2026-09-15 D5 定了采什么与去哪（不传 transcript 原文件、云端定协议 1.0），关 U3 / U10 / K1。未开工。过程记录（2026-09-09 提出、09-11 定两路、09-14 七次追加，含 teamai / Pilot 对照要点）在 git 历史里 |
| **G8** | 需求 | 🔴 | **「采集能限制在指定项目，就像 teamai 一样」**（用户原话，2026-09-09）。**现状（D4 之前）**：`vibetrail-sync` 按 `git worktree list` 只认领本仓的会话，天然按仓隔离；但没有「这台机器上哪些项目开了采集」的开关，G7 落成 harness hook 之后尤其要有——hook 写在 HOME 的工具设置里就是全局的。**teamai 的做法**（[分析文档 §4.3 / §4.4](third-party/teamai-cli.md)，09-09 对照源码复核后改）：hook 挂在 HOME，`hook-dispatch` 只用传入的 `cwd` 选 config、**不做门控**——config 取不到时注释自称 fail-open，19 条 handler 照跑，`dashboard-report` 在没 init 过的目录一样把事件写进本机 `events.jsonl`（`src/hook-dispatch-cli.ts:185`、`src/hook-handlers.ts:503-517`）；「限定」只发生在上报环节，`filterEventsByScope` 按 cwd 是否在 projectRoot 下决定哪个团队仓收哪些会话（[采集清单 §1 / §3.1](third-party/teamai-cli-collection.md)）。也就是说 teamai 有的是「上报限定」，不是「采集限定」，第一版写的「其余目录一律早退」不成立；分区键用 `git worktree list` 第一条当稳定身份。**要动需要什么**：一份机器级的项目清单（按主 checkout 分区，worktree 共享），分发入口先查清单再干活，`doctor` 报「本仓在不在清单里」。**先记录、暂不定**：清单粒度（仓 / 目录 / 分支）与开关方式（install 时登记还是单独命令），等需求和功能完善后再定。**09-14 随 G7 定了一半**：scope 可配——`project` 时机器级清单是开关、未登记不采；`user` 时全机采、用户显式选。hook 条目只在 HOME，仓里不留痕。登记方式已立 U2，默认 scope 已立 U1 |
| **G9** | 需求 | 🔴 | **「要在本地能展示一份采集的内容，让开发放心没有侵犯隐私」**（用户原话，2026-09-09）。**现状**：查询端 `vibetrail show / log / session / diverge` 读的是同一份数据，但没有面向「我被记了什么」的视图；而 K6 已证明 trace 里确有自由文本（`claim` / `desc` / `cwd`），先展示出来的会是问题本身。**teamai 的做法**（[分析文档 §3.3](third-party/teamai-cli.md)、[对比 §6.1](third-party/teamai-cli-vs-vibetrail.md)）：`session save` 先在本地落一份脱敏摘要，团队推送默认只推计数与工具名，prompt 文本要显式 `--include-prompt`；dashboard 只在本地起；文档明写「只统计次数」（本地事件流其实是明文，见对比 §6.1）。**要动需要什么（D4 之后改写）**：一条命令把「即将 push 的内容」原样列出并明说什么出了本机——现在什么都采，prompt 正文、thinking、代码 diff 都在全量副本里（D2「只存指针」已被 D4 取代），`vibetrail push --list / --show` 开启前预览；脱敏 K6 暂缓，先原样展示、如实写「什么出了本机」。**LoongSuite Pilot 在这条上没有完整答案，值得记下来免得下次再去翻**：它有本机 Dashboard（`127.0.0.1:8765`，只读 `logs/metrics-summary.json`）和 `input-runtime-metrics` 四阶段漏斗，但两者回答的都是「**多少**」（Dashboard 是 token、会话、请求、工具调用、模型与仓库的用量汇总，漏斗是读了几次、几条、产出几个事件），**不是「里面有什么」**。它文档化的「看」是一份默认开的本地 JSONL 副本：`docs/zh-CN/overview.md:91` 说没配远端时 JSONL 默认开启、「方便本地验证采集是否生效」，`docs/zh-CN/sls-output.md:158-162` 教的是 `tail -f ~/.loongsuite-pilot/logs/output/*.jsonl`——能看，但得自己翻原始事件，没有任何命令或视图按「我被记了什么」汇总；想少暴露，文档给的路是 `captureMessageContent: false` 让它**不采**，再加脱敏（`docs/zh-CN/masking.md:7-12` 建议两者同时用）。所以 G9 要的那种「给开发看、让开发放心」的视图在两家三方实现里都没有先例，我们要自己设计；可借的只有分层展示的口径（teamai 的「计数 / 截断文本 / 路径类信息」三分法，见 [teamai 采集清单 §6](third-party/teamai-cli-collection.md)）。**先记录、暂不定**：展示形态（CLI 表格 / markdown / 本地网页）与是否连带展示 commit trailer，等需求和功能完善后再定。**2026-09-14 前提变了**：G7 定了本机不存档、ack 即删（DESIGN D4），端点配置后本地没有内容副本可展示——本条改为「看发出去的清单与元数据 + 开启前预览」，内容看云端；commit trailer 已随 git hook 退役，不再有可展示的。**2026-09-15 再缩**：「读取不是我们读，我们只负责采」，云端展示由别的服务做；本条只剩 push 前的本地预览（`vibetrail push --list / --show`），且 D5 后出本机的正文只有分歧事件那几段，预览量很小 |
| **G11** | 需求 | 🔴 | **多个会话改、最后一个会话提交时，追回每一行出自哪个会话的哪次工具调用，再回到对话里判断是模型错还是人错**（用户 2026-09-10 提出）。已有方案与 demo，审过六轮；第六轮之后主方案改为「worktree + 规矩 + 接手时拍一次快照」，逐次工具调用快照降为可选（它的 7 处已知错未修）。未开工；下一步：agentDock 先装 trailer，再用重写后的测量脚本量多会话 commit 与接手的频率。快照是我们自己挂还是改造 Pilot、对话证据靠上传还是定期存 transcript，先记录、暂不定。排在 G7 的两路采集之后（用户 2026-09-11）。需求原话、方案、验证、限制、拆解见 [TODO.md](TODO.md) |
| ~~**D1**~~ | 待定决策 | ✅ | ~~归属语义三处不一致~~ —— **随 `Claude-Session` trailer 退役而消失**（2026-09-14，D4）：commit ↔ session 改从每轮起止 HEAD 推（DESIGN §3.5），归属语义在那里重新定义 |
| ~~**D2**~~ | 待定决策 | ✅ | ~~SpecStory 留不留人类可读副本~~ —— **不留**（2026-09-14）：全量副本上云后没有第二份副本的位置；SpecStory 在 DESIGN §7 已否 |
| **K2** | 已知缺陷 | 🟢 | **跨仓归属未定义**——一个会话可跨多仓，本项目开发会话即反例（`cwd` 在 agentDock、commit 在 vibetrail）。2026-09-15：协议 1.0 的 `files[].path` 必须在 `workspace_id` 的根内、不能 `..`，跨仓改动没有表达法，已提第二轮意见（file 项可选 `workspace_id`） |
| **G5** | 功能缺口 | 🔴 | **`tool` 字段未产出**，2026-09-15 D5 后升为 G7 前置：协议 `permission.decision` 的 `tool_name` 必填。不用 regex（`The user doesn't want to proceed` 形态正文里没有工具名），改用 `is_error` 块的 `tool_use_id` 反查前一条 assistant 记录里 `tool_use` 块的 `name`；同一次反查顺手取 `input`，就是分歧事件要带的正文（DESIGN §4.1）。原记：可从 `Permission to use (\S+)` 捕获，可选字段不升版本 |
| **K3** | 已知缺陷 | 🟢 | **空消息守卫假设 `core.commentChar` 为 `#`**——改了注释符的仓退化为不判空（不崩溃）。2026-09-14：这个 hook 只剩审计线在用，随 U6 一起定 |
| **M1** | ~~未量~~ | ✅ | ~~`is_error` 数组形态在语料里有多少~~ —— **已量（09-09）：1145 个 `is_error` 块全部字符串形态，数组形态 0 个**。铁律五的修复是纯防御，未恢复任何漏计 |
| **M2** | 未量 | 🟢 | **召回率绝对基线未测**——现有基线是无锚子串候选集；`permission_denied` 的「人工核对候选集」口径没记 |
| **M3** | 未量 | 🟢 | **`.meta.json` 字段集随版本变**——2.1.85 两项 / 2.1.202 三项 / 2.1.260 四项。全量副本逐字节复制它，消费方按缺失容错 |
| **U1** | 待定决策 | 🟡 | **默认 scope**：`project`（只采登记的）还是 `user`（全机采）。倾向 project——与 G8 一致，误采代价高于漏采（DESIGN §5） |
| **U2** | 待定决策 | 🟢 | **登记方式**：`vibetrail init` 在仓里跑时顺手登记 / `vibetrail projects add`，两种并存还是选一种 |
| ~~**U3**~~ | 待定决策 | ✅ | ~~全量一路的格式~~ —— **由 D5 关闭**（2026-09-15）：不传 transcript 原文件，不存 file-history；分歧映射成协议事件并带最小正文，其余只有轮次元数据（DESIGN §2、§4.1） |
| **U4** | 待定决策 | 🟡 | **端点、token、谁能看**。云端服务与 schema 已定（D5，2026-09-15）：paas-coding-hook 事件协议 1.0 的 collector，映射见 DESIGN §4.1。仍未定：端点地址；`Onepaas-Api-Access-Token` 怎么发与续期（hook 无人值守，要长期 token，放 `~/.vibetrail/` 0600）；谁能看（协议默认全公司可见，与 K6 暂不脱敏冲突，已提第二轮 [意见](third-party/paas-coding-hook-protocol-feedback.md)）。端点没配之前 push 不发，可以最晚定 |
| **U5** | 待定决策 | 🟢 | **端点未配置阶段 spool 的上限与超限策略**。本机全量 700 MB 量级；倾向只警告不丢——采全（A2）优先于少存。配置后 ack 即删已定（D4） |
| **U6** | 待定决策 | 🟡 | **审计线去向**：`audits/` 仍在被观测仓里、仍靠 `prepare-commit-msg` 写 `Vibetrail-Id` 锚、闸门仍要仓内 vendor，与 D4「零写入」不一致。搬出仓要换锚（trailer 没了）与闸门的读法；不搬则 agentDock 保留自己那份 git hook 与 vendor。在定之前两条线互不影响（DESIGN §8、[spec/trace-v1.md](spec/trace-v1.md)） |
| **U7** | 待定决策 | 🟢 | **自建 hook 还是改造 Pilot**（同 G11）。用户 09-11「肯定不止靠pilot，我知道他做不到，要改造」；默认自建 |
| **U8** | 待定决策 | 🟢 | **上游类型化信号要不要成为新 kind**：`absorbed_mid_turn`、`edited_text_file`、`hook_blocking_error`、hook 事件 `PermissionDenied` / `StopFailure` / `Notification`。先按 [spec/diverge-v1.md §3](spec/diverge-v1.md) 的方式量精确率再定 |
| **U9** | 待定决策 | 🟢 | **Codex / Cursor 要不要一起采**。默认不做：Pilot 三分之一代码在适配各家格式，地基（hook 热加载、`CLAUDE_CODE_SESSION_ID` 等于文件名）是 Claude Code 特有的实测 |
| ~~**U10**~~ | 待定决策 | ✅ | ~~云端保留期、传输层压缩格式~~ —— **由 D5 关闭**（2026-09-15）：索引保留 30 天够用（「超过一个月复盘意义不大」）；压缩待服务端支持 gzip（第二轮意见），D5 后体积 KB 级，不再是必需项 |

**已关闭**：O1 git-ai 采纳（否决）· O3 trace schema（已定）· O5 telemetry 配置（随 O1 消失）·
O6 存量 marker 迁移（不迁移）· O7 `core.hooksPath`（并入 G3）· A 节四组数字 · B 节五条决策 ·
M1 数组形态 · G4 留痕自检 · G3 的实现部分 · **G1 查询端** · **G2 session 投影** · **K5 跨 kind 重复** ·
K4 分歧记录含分支名（并入 K6）·
**L2 审计留痕**（`vibetrail-audit`，断链二解决）·
**G2 写入者 / G3 / D1 / D2**（2026-09-14 随 D4 关闭：hook 写 spool、机器级装一次、trailer 退役、不留 SpecStory 副本）·
**U3 / U10 / K1**（2026-09-15 随 D5 关闭：不传 transcript 原文件、30 天够用、父子打断是两个事实不去重）。


## D. 三轮审计的方法教训

- **自审一条高危都没抓到，三条全是独立 agent 用实验抓的。** 自己改过的东西看不出盲区；
  「修完再起一个新 agent 从头审」应当成固定流程。
- **hook 类断言必须逐场景实测**，尤其是「某事不会发生」（人工 commit 不会被记成 agent 的）。
  这次的三条高危分别藏在 rebase 重放、merge 的非编辑器路径、trailer 块的段落规则里，
  读代码看不出来。
- **模拟「人工操作」时要 `env -u CLAUDE_CODE_SESSION_ID`。** agent 的 shell 自带这个变量，
  不去掉则「人工提交」全是假的——我第一次验证 hook 就是这样把一轮实验全污染了。
- **语料是活的，所有语料级数字必须带测量日期。** 同一批量 09-08 测 402/277/90，09-09 测 405/282/92——我们工作时它一直在增长。
- **差值的归因必须单独验证，不能顺手挂在最近的改动上。** 那个 +2 曾被归因为「刚修的数组形态缺陷恢复了 2 条」，听起来合理但是错的：
  1145 个 `is_error` 块全是字符串形态，修复是纯防御，真因是语料增长。「刚修好的那个 bug」是最省力的解释，也正因为省力所以危险。
