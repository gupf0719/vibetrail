# 审计遗留问题（2026-09-08）

> 三轮审计（一轮自审 + 两轮独立 agent）里**发现了但没有动**的问题。与另几份文档的分工：
> [DESIGN.md §5](DESIGN.md) 记设计层未决项（O1–O7），本文记审计遗留——待核的数字、
> 单方面定下需要确认的决策、已知未修的缺口。**修掉一条删一条，本文为空即可删除。**
>
> 每条写四样：在哪、现状、为什么没动、要动需要什么。
>
> **K6 / G6 / G7 不来自那三轮**：K6 / G6 是 2026-09-09 扫三方项目 teamai-cli、并对那两份文档做
> 对抗性审计时反照出来的（见 [third-party/](third-party/teamai-cli-vs-vibetrail.md)）；
> G7 是同日用户看完对比后直接提的需求。
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
| **K6** | 已知缺陷 | 🔴 | **trace 已落自由文本，且一处脱敏都没有**——`audits/*.jsonl` 的 `findings[].claim`（审计结论正文，**由审计 agent 生成**，正文里完全可能带上被审代码片段、路径、密钥样本）与 `agents[].perspective`；`sessions/*.jsonl` 的 `end.subagents[].desc` 与 `session.cwd`（绝对路径，带用户名与项目名）。这些**随代码入仓**，推远端即团队可见。三方对照：teamai-cli 的对等字段（`promptSummary` / `firstPrompt`）**全部强制过 `redactWithEnv()`**，且团队推送默认只推计数与工具名、自由文本要显式 opt-in。要动：把「trace 落自由文本前必须过脱敏」写进 [spec §5 稳定面](spec/trace-v1.md)，并给 `claim` / `desc` 补脱敏环节。**原 K4（分支名）是本条的子集，已并入** |
| **G3** | 功能缺口 | 🟡 | **没有「保证每人跑过 install」的机制**——脚本已有（`vibetrail-install` / `-doctor`，见 [CAPABILITIES §2.5](CAPABILITIES.md)），但 git 不允许仓库自动装 hook。业内解法是搭车在人本来就跑的步骤上（husky 挂 `npm install`）；agentDock 可搭 `Makefile`，**未做** |
| **K5** | ~~已知缺陷~~ | ✅ | ~~一次「拒绝工具调用」被记两条~~ —— **已修**：`for tool use` 变体拆成独立 kind。实测 35 = 35 精确对上（见 spec §3.1）|
| **K1** | 已知缺陷 | 🟡 | **提取器重复计数未去重**——方案已定（同 sid + 同 kind + ≤10 秒，靠 `isSidechain`/`agentId` 分层），但 `hit` 还没输出这两个字段 |
| **G6** | 功能缺口 | 🟡 | **判据 fixture 是照「见过的形态」手搭的，没见过的第三种形态对测试不可见**——`tools/fixtures.jsonl` 26 条覆盖两种拒绝正文（`Permission to use …` 六个变体含多行命令 + `The user doesn't want to proceed …`），这次核过没有镜像盲区；但**机制上挡不住新形态**。三方实测的反例值得警惕：teamai-cli 的判据测试与我们同级完备（13 个测试文件涉及判据，含一条把两个 interrupt 变体钉成预期的用例），却因全套件里 `Permission to use` 出现 **0 次**，对它自己 52% 的人拒漏判**恒绿**——测试不是缺失，是靠 fixture 选择恒绿。这正是 [CAPABILITIES §2.4](CAPABILITIES.md) 记的「假绿」模式。要动：fixture 来源从「见过的」换成「从全语料聚类出的 `is_error` / interrupt 正文形态」 |
| ~~**G4**~~ | 功能缺口 | ✅ | ~~没有留痕自检~~ —— **已实现** `tools/vibetrail-doctor` |
| **G7** | 需求 | 🔴 | **「做成和 teamai 一样：装一次就行，然后 Claude 每次对话写代码的时候自动上报两路信息」**（用户原话，2026-09-09）。它把 G2 剩下的一半（sessions 谁写、何时写）和 G3（保证每人跑过 install）合成一件事。**现状**：git 的 `prepare-commit-msg` 每个 clone 手跑一次 `vibetrail-install`；`vibetrail-sync` 完全手动；Stop 侧只有审计闸门（`tools/fixtures/check-audit-stop.sh`）。**teamai 的做法**（[分析文档 §4.4](third-party/teamai-cli.md)）：一次 `init` 把 SessionStart / Stop / PostToolUse / UserPromptSubmit 写进各工具 settings，全部经 `teamai hook-dispatch <event>` 一个入口分发；其 self 模式更进一步——把 `.claude/settings.json` 连 hooks **提交到 main**，队友 clone 即得，SessionStart 再自愈式 bootstrap 本机侧。**要动需要什么**：① 在 `.claude/settings.json`（可入仓，不像 git hook）里挂 SessionStart → 幂等跑 `vibetrail-install`（G3 由此消失）、Stop → 投影当前会话（G2 由此消失）；hook stdin 直接给 `transcript_path` / `session_id`，不需要 ID 映射（[DESIGN §2.1](DESIGN.md)）；② 投影仍须按 `git worktree list` 聚合而不是只扫 hook 递来的那一个文件——teamai 正是栽在这一步，58% 的人拒在子 agent 文件里（[对比 §3.2](third-party/teamai-cli-vs-vibetrail.md)）；③ 每次 Stop 都重投影的成本要量（单会话 transcript 最大 106MB，`vibetrail-sync` 是整份重生成）；④ 入仓的项目级 hooks 在 Claude Code 里是否要用户确认一次，**待实测**。**先记录、暂不定**（用户 09-09：等需求和功能完善后再定）：「两路」具体指哪两路——最可能是 FLOW ④ 的两条投影流 `sessions/`（会话摘要 + 人机分歧）与 `audits/`（审计记录）；另一种读法是 sessions 与 commit 归属 trailer（后者装完 git hook 后已自动）。定了再拆任务 |
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
