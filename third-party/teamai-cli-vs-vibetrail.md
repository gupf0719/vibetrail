# teamai-cli vs vibetrail

> 配套文档：[teamai-cli.md](teamai-cli.md)（对方项目本身的分析）、
> [teamai-cli-collection.md](teamai-cli-collection.md)（对方的采集清单）。
> 对方快照 HEAD `224c0c4`（2026-09-09）。判据实测于 **2026-09-09**，语料 **762 个 transcript 文件**。

## 1. 结论先行

**两个项目基本不重叠，重叠的那一处我们做得更准，但对方在他们自己的用途上不需要那么准。**

| | teamai-cli | vibetrail |
|---|---|---|
| 一句话 | 把团队的 AI 配置和经验分发到每个人 | 拿到一个 commit，追回它是怎么来的 |
| 时间方向 | **向前**：让下一次会话干得更好 | **向后**：让出问题时能查回去 |
| 主体 | 团队（多人多仓多工具） | 代码（一个仓的提交历史） |
| 数据归属 | 机器本地 + 独立的团队知识仓 | **随被观测的代码走**（`<repo>/.claude/trace/`） |
| 规模 | 62.5K 行 TS，685 commit，39 人 | 一组 shell/jq 工具 |

唯一的正面重叠：**都读 Claude Code 的 transcript，都从里面提取人机分歧信号**
（它的扫描器还兼读 CodeBuddy `index.json` 与 Codex rollout，Cursor 无 transcript 只算
`correction`——判据是几种 harness 的最小公分母，见分析文档 §4.1）。
下面 §3 是这一处的逐条实测对比。

## 2. 功能面对照

| 能力 | teamai-cli | vibetrail | 说明 |
|---|---|---|---|
| 团队资源分发（skill/rule/MCP/hook/agent） | ✅ 成熟 | ❌ 不做 | 对方的主业 |
| 多 harness 适配（README 矩阵 10 个，代码另有 JoyCode） | ✅ | ❌ 只 Claude Code | |
| 多 git provider（6 类）+ 非 git 的 HTTP 后端模式 | ✅ | ❌ 只本地 git | |
| 团队知识库 + 检索（BM25 + 图） | ✅ beta | ❌ 不做 | |
| 代码知识图谱（tree-sitter AST） | ✅ beta | ❌ 不做 | |
| **读 transcript 提取人机分歧** | ✅ | ✅ | **唯一重叠，见 §3** |
| 纠正话术识别（`correction`） | ✅ 启发式 | ❌ 已主动搁置 | 见 §3.4 |
| 敏感信息脱敏 | ✅ 出口处 `redact()`（本地事件流仍明文） | ❌ **已落自由文本，无脱敏** | 见 §6.1 |
| 团队看板 / 周报 | ✅ | ❌ 不做 | |
| learning 投票飞轮 + 晋升（votes / `recall promote`） | ✅ | ❌ 不做 | |
| CI 上从 MR 提知识（`ci extract-mr`） | ✅ | ❌ 不做 | MR → 知识，非 commit → 会话，见 §5.1 |
| **commit ↔ session 关联** | ❌ | ✅ trailer 注入 | 见 §5.1 |
| **审计过程留痕** | ❌ | ✅ `vibetrail-audit` | 见 §5.2 |
| 单事件可回跳原文（uuid 指针） | ❌ 只存计数 | ✅ `turn` 字段 | |
| 留痕随代码走 | ❌ 默认反向；self 模式知识随 main 走 | ✅ D2 | 见 §4 |

## 3. 正面对撞：同一份语料，两套判据

**方法**：把 teamai `scanTranscriptStop()` 的判据逐条复刻成 jq，与
`tools/extract-diverge.jq` 跑同一批语料，再按记录 uuid 做交叉表。
两侧 jq stderr 均为 0 行（没有静默抛错污染结果）。

**语料**（2026-09-09）：`~/.claude/projects/` 全量 **762 个 transcript 文件**，
分属 **34 个 sessionId**——这个「文件 ≠ 会话」的关系是本次对比的关键，见 §3.2。
（测量期间文件数在 762–764 间浮动——语料在我们工作时一直在写。以 762 复测，
上下两组判据的命中数**逐项不变**。）

对照本项目 CAPABILITIES §2.2 的 09-09 记录（`interrupt` 248 / `permission_denied` 92，
主会话 39 + 子 agent 53）：本次复测除 `interrupt` 248→250（语料在我们工作时仍在增长，
本项目文档已就此立过规矩）外**逐项吻合**，两侧数据可交叉验证。

### 3.1 判据层对比（两套规则跑全量语料）

| teamai kind | 命中 | | vibetrail kind | 命中 |
|---|---:|---|---|---:|
| `interrupt` | **285** | | `interrupt` | 250 |
| | | | `interrupt_for_tool_use` | 35 |
| `toolReject` | **44** | | `permission_denied` | **92** |
| `toolError` | **1118** | | `classifier_blocked` | 1 |
| | | | `permission_infra_fail` | 6 |

记录级交叉表（按 uuid 对齐，这是硬结论）：

| vibetrail 判定 | teamai 判定 | 条数 | 差异性质 |
|---|---|---:|---|
| `interrupt`（人主动打断） | `interrupt` | 250 | ✅ 一致 |
| `interrupt_for_tool_use`（拒绝时的伴随打断） | `interrupt` | **35** | ⚠️ 相对我们**双计**（它有意如此，见 ①） |
| `permission_denied`（人拒） | `toolReject` | 44 | ✅ 一致 |
| `permission_denied`（人拒） | **`toolError`** | **48** | 🔴 **人机颠倒** |
| `classifier_blocked`（分类器拒，非人） | `toolError` | 1 | ⚠️ 归错桶 |
| `permission_infra_fail`（链路故障，非人） | `toolError` | 6 | ⚠️ 归错桶 |

**① 拒绝工具调用被记两次——而且是它有意为之。** teamai 的前缀
`'[Request interrupted by user'` 不带右括号，同时命中 `[Request interrupted by user]` 与
`[...for tool use]` 两个变体。

**这不是疏漏**：`src/__tests__/dashboard-collector.test.ts` 有一条用例就叫
`counts user interrupts (both variants)`，喂进两个变体、`expect(iv.interrupt).toBe(2)`
——两个变体都算 interrupt 是**被回归测试钉死的预期行为**。

按它的语义（「模型的执行被人打断了几次」）这是自洽的；按我们的语义
（「人主动打断了几次」）就不能用：后者与权限拒绝是**同一个人类动作的两条记录**，
它的 285 对应我们的 250，**虚高 14%**。这是分类学差异，不是它的 bug。

**② 52% 的人类拒绝被归成了机器失败。** 92 条人拒里 **48 条**落进 `toolError` 桶——
那个桶的语义是「AI 自己搞不定工具，只好绕」。**语义符号是反的**。

原因在判据覆盖面：`TRANSCRIPT_REJECT_MARKERS` 只有两个串
（`The tool use was rejected` / `doesn't want to proceed with this tool use`），
**不含** `Permission to use ... has been denied`。抽样确认这 48 条正是后一种形态：

```
Permission to use Bash with command cd /Users/…/worktrees/great-pascal-a9287f
# 造合并 commit：tree=8f2131f(v0.1.…
```

正文里嵌了多行命令。本项目 spec §3.3 第 3 条记过这个坑的另一面（jq 的 dotall 标志是
`m` 不是 `s`，不加会漏掉全部多行命令的拒绝，实测漏 2/90）——teamai 是从另一个方向掉进
同一个洞：它的匹配串压根没覆盖这一类消息。

**③ 两种拒绝形态是两条独立的链路。** 按（会话，秒）把人拒与 `interrupt_for_tool_use` 配对：

| 人拒 | teamai 判定 | 条数 |
|---|---|---:|
| 有配对的伴随打断 | `toolReject` | **42（全部）** |
| 无配对的伴随打断 | `toolError` | **48（全部）** |
| 无配对 | `toolReject` | 2 |

相关性接近完美：`The tool use was rejected` 形态**总是**伴随一条
`[...for tool use]` 打断，而 `Permission to use ... has been denied` 形态在本语料里
**48/48 全部不伴随**（"从不" 是本语料的观察，不是对该协议的断言）。
这是 Claude Code 里两条不同的拒绝链路，teamai 只覆盖了其中一条。

### 3.2 运行时层对比：它其实只扫一个文件

上面是**判据**的对比。teamai 的**运行时**看到的更少。

`scanTranscriptStop(hookData.transcript_path)` 只扫 hook 递过来的**单个**文件，
而 Claude Code 的落盘是两层（布局本身见本项目 [DESIGN.md](../DESIGN.md):27，早有记录；
下面的量级与字段层观察是本次实测新增）：

```
~/.claude/projects/<cwd-slug>/<sessionId>.jsonl                        ← 主会话，34 个
~/.claude/projects/<cwd-slug>/<sessionId>/subagents/agent-<hex>.jsonl  ← 子 agent，728 个
```

子 agent 文件名是 `agent-<hex>`（728/728），记录里带的是**父会话的 `sessionId`**；
每条记录 `"isSidechain":true` 且带 `agentId`（等于文件名里的 hex），主会话文件里每条都是
`false`——子 agent 记录**不再嵌在主文件里**，目录与字段两套标识都在，任取其一都能分开。
单个 sessionId 最多横跨 **291 个文件**。
（第一版把这条写成「`isSidechain` 根本不出现」，写反了，见附录第 8 条。）

teamai 拿不到这 728 个文件：它**内置**注册的 hook 里**没有 `SubagentStop`**，
全仓也没有遍历 `subagents/` 的代码路径，且 transcript 只在 `stop` 事件里扫（均已 grep 核实）。
团队自声明的 `hooks/hooks.yaml` 可以挂任意事件，但只跑自定义命令，不进扫描器。

按文件类别分别实测：

| | 主会话（34 文件） | 子 agent（728 文件） | 合计 |
|---|---:|---:|---:|
| vibetrail `permission_denied`（人拒） | 39 | **53** | 92 |
| vibetrail `interrupt`（人主动打断） | 229 | 21 | 250 |
| teamai `toolReject` | 37 | 7 | 44 |
| teamai `toolError` | 397 | 721 | 1118 |

**58% 的人类拒绝发生在子 agent 里。** 叠加 §3.1 的判据缺口，teamai 运行时实际登记为
「人拒绝了工具调用」的是 **37 / 92 = 40%**，漏掉 60%。

本项目按 `git worktree list` 聚合根目录、扫全部 transcript，两类文件都覆盖——
CAPABILITIES §2.2 里「主会话 39 + 子 agent 53」这个拆分本身就是这次实测的同一组数字。

### 3.3 一处零影响的潜在差异

teamai 处理**字符串形态**的 `message.content` 时，只把 interrupt 从 prompt 计数里排除，
**不计入 `interrupt`**；数组形态才计。本语料里字符串形态的 interrupt 实测 **0 条**，
对上面的数字无影响。记在这里是因为换一批语料可能会有。

### 3.4 公平地说：这些误差对它自己基本无害

必须讲清楚，否则上面就是稻草人。

teamai 要的是**一个阈值判断**——「这次会话值不值得提示用户写成经验」。阈值 20，
分数上单个强信号即够（interrupt / toolReject / correction 各 20 分；toolError 走分档，
≥3 → 10 分、≥5 → 18、≥8 → 25）。另有一道与判据无关的硬门槛 `toolCount >= 15`，
下面的验算**没有建模它**——它只会让 teamai 提示得更少，与判据缺口同向，不改变
「误差被阈值吸收」的结论，但「0 个跌破」是**分数口径**，不是最终提示口径。

- **那 35 次双计不改变结论**：配对的那条 `toolReject` 已经给了 20 分，早过阈值。
- **那 48 条归错桶确实掉 20 分**：它们**没有**配对打断（§3.1 ③），所以少一个强信号。

按**运行时语义**逐会话验算（teamai 侧只取主会话文件的信号，按它的权重复算
`20×interrupt + 20×toolReject + toolError 分档`）：本语料 20 个有人机分歧的会话，
**跌破阈值 20 的有 0 个**——每一个都至少有 1 次主会话打断，单这一项就正好到 20。

两条必须说明的边界：

- 这是**下界**：`correction`、skill/多样性加成、知识缺口加成没有建模，实际得分只会更高
  （git commit 降权常量为 0，不需要建模）。
- 有 **3 个会话正好卡在 20 分**（只有 1 次打断、`toolError` 不足 3 条）。
  判据再退一步就会掉下去，余量并不厚。

**它的误差在阈值判断上基本被吸收了。对方的设计对它自己的用途是够的。**

误差真正显形的地方是**把这些数字当数字用**——而 teamai 恰好这么用，且是官方使用指南
明写的用法：`teamai dashboard` 的成员「干预数」（原话「干预越少，说明 agent 一次把事做对的
能力越强」），随 `pull` 聚合进团队仓 `stats/<user>.yaml`，再由 `teamai digest` 出
「会话自主性」的人均干预率排行，并建议用它「验证某个 skill / rule 上线后干预率是否下降」。

用本语料算（且假设它能扫到全部文件，实际还要再打个对折）：
它会报 `285 + 44 = 329` 次干预，真实的人类分歧动作是 **342** 次
（250 主动打断 + 92 拒绝，配对记录合并计一次）。329 vs 342 只差 4%，
**但这个「准」是假的**：由 **+35 虚增**和 **−48 漏计**抵消而来。语料构成一变，抵消就没了。

**结论**：判据的精度要求由用途决定。对方按阈值造，我们按计数造，
**对方的数字不能直接拿来当计数用**——这是这次对比最有价值的一条。

### 3.5 方法论上两边是同源的

不能只讲差异。teamai 做对了两件业内没普及的事，和本项目独立收敛到了同一处：

1. **只读 JSON 字段，不 grep 整行原文。** 它锚定 `type === "user"` 的记录、逐块判
   `is_error`，没有裸 grep。本项目 spec §3.3 第 1 条讲的是同一件事
   （裸 grep 在对抗样本上精确率仅 10.5%）。
2. **区分人的决定与机器的行为。** 它分 `toolReject`（人拒）/ `toolError`（机器），
   我们用 `human` 布尔。**这个区分本身是对的**，两边只是分界线画的位置不同。

对照本项目 spec §3.1 记的业内水平（SpecStory 只认 interrupt 一行前缀匹配、
git-ai 与 claude-story 一个都不认），**teamai 是本项目见过的三方实现里最强的一个**，
spec 该节的「三个实现读下来」应当补上它。

## 4. 最根本的分歧：数据落在哪

这不是实现差异，是**目标冲突**，两边都写进了设计文档。

| | teamai-cli | vibetrail |
|---|---|---|
| 设计目标 | **业务仓零残留** | **数据随代码走** |
| 落点 | `~/.teamai/projects/<slug>/` + 独立团队知识仓 | `<repo>/.claude/trace/` |
| 理由 | 机器数据实测占业务仓 18 MB，污染工作区、worktree 读不到、多项目混淆 | 数据离开它描述的代码就失去价值（D2） |
| 出处 | `docs/designs/data-directory-layout.md` | `DESIGN.md` D2 |

两边都对，因为**描述的对象不同**：teamai 存的是「团队现在的配置和经验」——它跟着人和
团队走，放进某个业务仓反而是错的；我们存的是「这段代码是怎么来的」——它跟着代码走，
放在机器本地则换台机器就没了。

**一条必须加的限定：上表是 teamai 的默认模式（独立团队仓）。** 它还有一个单仓模式
（self mode，`teamai init .`），在这个模式下**知识资产是随代码走的**：skills / rules / docs /
learnings 和 `teamai.yaml` 提交在业务仓 main 的 `.teamai/` 里，clone 即得；会话与摩擦上报
（members / sessions / votes / stats）推到同一 origin 的 `teamai-reports` 孤儿分支——同仓、
但独立历史。所以「目标冲突」准确说是**默认模式冲突、self 模式部分重合**：它让「团队现在的
配置和经验」跟着代码走了，但「这段代码是怎么来的」这类会话数据仍不在代码的提交历史里，
与本项目的分歧在这一层没变。

有意思的是**两边都被 worktree 咬过，解法相反**：

- teamai：`git worktree list --porcelain` 取**第一条**当 `projectAnchor`，作为稳定的
  项目身份来分区；同时资源必须写 `workspaceRoot`（当前 checkout），因为所有 AI 工具
  都只从启动目录往上扫到当前仓根。
- vibetrail：`vibetrail-sync` 按 `git worktree list` **聚合全部** worktree 根来归属会话
  （比 SpecStory 的 cwd 1:1 反查宽，否则在 worktree 里 sync 不到主仓的会话）。

同一个 API，一个用它收敛成单一身份，一个用它扩散成全集。

## 5. 我们有而它没有的（已 grep 核实）

### 5.1 commit ↔ session 关联

teamai **完全没有**。它离得最近的是两条：`hasGitCommitInSession()`——
`git log --after=<会话开始时间> -1`，只回答「这个时间窗里有没有人提交过」，本意是给 friction
分降权，但降权常量当前为 0，只剩一个标志；以及 `teamai ci extract-mr` / `import --from-mr`——
从已合并 MR 的 diff 与 commits 里提取知识建议，方向是 **MR → 知识**。
两条都不回答、也无意回答「哪个 commit 属于哪个会话」。

它的 `coauthor-reconcile` 只是**替团队开关各工具原生的 `Co-Authored-By` 策略**，
写的是「AI 参与过」这个布尔，不是**哪一次会话**。

我们走 `prepare-commit-msg` 注入 `Claude-Session:` trailer，读进程级环境变量
`CLAUDE_CODE_SESSION_ID`，实测覆盖 11 个场景（含 rebase / cherry-pick / worktree 并发）。

**这是两个项目最大的能力差，且方向上不可互换**——它主动不碰用户的 git hook
（`src/utils/git.ts` 注释明确「不写 `core.hooksPath`，不改变用户平常的 git commit`」），
这是个自觉的边界选择，不是没做完。

### 5.2 审计过程留痕

teamai 的 `review-cmd` / `review-store` 名字像，实际审的是**知识库待审条目**
（`.teamai/pending-review.jsonl`，`codebase-section` / `domain-drift` /
`multi-source-conflict` 三类），与代码审计无关。

**「记录审计本身」这件事仍然没有先例**——本项目 CAPABILITIES §2.4c 的判断经这次扫描
再次确认，可以把 teamai 也列进「审的都是代码，没有一个记审计本身」那份名单。

### 5.3 单事件可回跳

我们每条 diverge 带 `turn`（原始消息 uuid），transcript 还在就能跳回现场看上下文。
teamai 只存聚合计数和脱敏摘要，**没有回跳锚点**——它的用途不需要。

## 6. 它有而我们没有、且值得抄的

按性价比排序。**只列真正该做的，不列「它有所以我们也要有」的。**

### 6.0 装一次、之后每次会话自动上报 —— 已立为需求，见 OPEN-ISSUES G7

这条不是本文的推断，是用户看完对比后直接提的：「做成和 teamai 一样，装一次就行，
然后 Claude 每次对话写代码的时候自动上报两路信息」。对方的做法在分析文档 §4.4
（一次 `init` 写四个 harness hook、一个入口分发）和 §4.3（self 模式把 `.claude/settings.json`
连 hooks 提交到 main，clone 即得）。现状、要动什么、以及「两路」待确认，都只记在
[OPEN-ISSUES.md](../OPEN-ISSUES.md) 中心表 G7，此处不重复。同日追加的 G8（采集限定在指定项目）、
G9（本地能看采集了什么、让开发放心）同样以 teamai 为参照，也只记在中心表。

### 6.1 脱敏（`redact()`）—— 建议列入待办

teamai 在**每个出口**强制脱敏：contribute 提示里的任务摘要、session save 的首 prompt、
Stop 时截取的 AI 输出，三处都过 `redactWithEnv()`；且团队推送默认**只推计数和工具名**，
prompt 文本要显式 opt-in（注释理由：`redact()` 是尽力而为，所以即便脱过也默认不推）。
但它**不是全链路**：UserPromptSubmit 把 prompt 前 200 字符原样写进本机
`~/.teamai/dashboard/events.jsonl`，本地事件流是明文（第一版写成「全链路强制」，已改）。
差别在于它的明文不出机器，我们的会随仓推远端。

我们的 trace 落在**仓里、随代码走**，一旦推到远端就是团队可见——**脱敏缺口比它更要命**。

⚠️ **本文第一版把这条写成了「将来的风险」，审计时发现是错的：自由文本已经在落盘了。**
现有至少四处：

| 落点 | 字段 | 内容 |
|---|---|---|
| `audits/*.jsonl` | `findings[].claim` | 审计结论正文，**自由文本** |
| `audits/*.jsonl` | `agents[].perspective` | 审计视角描述，自由文本 |
| `sessions/*.jsonl` | `end.subagents[].desc` | 子 agent 任务描述（spec §3 示例即 `"审设计自洽性"`） |
| `sessions/*.jsonl` | `session.cwd` | 绝对路径——带用户名与项目名 |

`claim` 由审计 agent 生成，正文里完全可能带上被审代码的片段、路径、甚至密钥样本。
teamai 对等的字段（`promptSummary`、`firstPrompt`）**全部强制过 `redactWithEnv()`**，
且团队推送默认只推计数与工具名、自由文本要显式 opt-in。我们一条都没有。

建议：把「trace 落自由文本前必须过脱敏」写进 spec 的稳定面，并给 `claim` / `desc`
补一个脱敏环节。这已经不是预防，是补洞。

### 6.2 判据脆弱性的共同解法 —— 两边都没有，值得一起想

两边都硬编码英文消息串，上游改文案即**静默失效**。

⚠️ **本文第一版写「它的判据常量没看到等价的回归钉子，这一点比 teamai 强」，
审计时核实是错的，撤回。** teamai 有 13 个测试文件涉及这套判据（按 `toolReject` /
中断串 grep；直接引用判据常量的 4 个），
`dashboard-collector.test.ts` 里三条用例分别钉住「两个 interrupt 变体」「工具拒绝」
「普通工具错误不算拒绝」——**保护强度与我们的 `test-extract.sh` 同级**。

真正的发现比「谁有测试」有意思得多：**它的测试是靠 fixture 选择恒绿的。**
全套件里 `Permission to use` 出现 **0 次**——它的 is_error fixture 只有一种形态，
正是它的匹配串覆盖的那种。所以 §3.1 ② 那 52% 的缺口，**只要 fixture 集不变，它的测试就看不见**。
这正是本项目 CAPABILITIES §2.4 记的「假绿」模式：比对输出恒绿，缺的是语料形态。

我们在这一条上暂时没有镜像盲区（`tools/fixtures.jsonl` 26 条里两种拒绝形态都有，
含多行命令变体）——但**机制上的风险完全相同**：两边的 fixture 都是照见过的形态手搭的，
第三种没见过的形态对两边同样不可见。

这是本项目 spec §7 已记的已知脆弱点，扫完对方之后结论不变：**业内没人解了**。
可做的只有一件：把 fixture 的来源从「见过的」换成「从全语料里聚类出的」，
让新形态出现时至少有机会被抓到。建议列入 OPEN-ISSUES 中心表。

### 6.3 不建议抄的

- **`correction` 启发式**：中英日词表 + 60s 窗口，代码里没有准确率实测。
  本项目 spec §3.1 已明确把它挡在门外（「现有四个 kind 都是硬信号、已有可用准确率，
  先把启发式挡在门外；要加须先有独立的准确率实测，且必须与硬信号分开统计」）。
  **这次扫描支持维持原判**：对方的实现恰好示范了没有实测的启发式长什么样。
- **dashboard / digest**：需要团队规模才有意义，与本项目「一个仓的提交历史」的主体不符。
- **多 harness 适配**：本项目的地基（hook 在 desktop 下热加载、
  `CLAUDE_CODE_SESSION_ID` 逐字等于 transcript 文件名）是 Claude Code 特有的实测结论，
  摊到 10 个 harness 上等于重做地基。

## 7. 一句话总结

**teamai-cli 是「团队怎么用好 AI」，vibetrail 是「AI 写的代码怎么查回去」。**
撞车只在读 transcript 那一处：对方把它当**阈值信号**，做到够用就停；
我们把它当**计数与证据**，所以必须做到判据级精确。

实测证明这个精度差是真的，而且分两层：**判据层**漏 52% 的人拒（归成了机器失败），
**运行时层**再漏一次（不扫 `subagents/`，而 58% 的人拒在那里），合计只登记 40%。
同时也证明**对方并不因此有 bug**——这些误差在它自己的阈值判断里基本被吸收了，
实测没有一个有分歧的会话在分数口径上被它彻底漏掉（`toolCount` 硬门槛未建模，见 §3.4）。

真正的教训不是「谁更准」，而是两条：

1. **判据的精度要求由用途决定。** 跨用途搬运数字（比如把它的干预率当干预计数）
   会静默出错——错的方向还是双向抵消的，看起来更像对的。
2. **判据对了，采集范围错了一样白搭。** 对方的判据方法论和我们同源，
   差距的一多半却来自「只扫了一个文件」这种与判据无关的地方。
   本项目按 worktree 聚合扫全量是对的，但这条**没有回归钉子守着**——
   哪天采集范围缩了，判据测试全绿，数字静默减半。建议列入 OPEN-ISSUES 中心表。


## 附录：本文档的审计记录（2026-09-09）

初稿写完后做了一轮对抗性审计，逐条回查代码与数据，**7 处断言被推翻或需要修正**；
第二轮对照 teamai 官方 `docs/` 复核，又推翻 1 处、限定 4 处（第 8 条）。
均已改在正文里，此处只留台账——这份文档自己也该有留痕。

| # | 初稿的错误断言 | 核实结果 | 落在 |
|---|---|---|---|
| 1 | contribute-check「挂在 `PostToolUse` 上」 | 错。`hook-handlers.ts` 注册表里只挂 `stop`。我照抄了它 `types.ts` 里一句**过时注释** | 分析文档 §4.1 |
| 2 | 把打分写成一个公式 | 不准。实为 `computeSmartScore()` + `applyPhase2Adjustments()` 两阶段 | 分析文档 §4.1 |
| 3 | 「子 agent 文件名是自己的 uuid」 | 错。实为 `agent-<hex>.jsonl`，728/728 | 两份 |
| 4 | 把 `subagents/` 布局当本次新发现 | 错。本项目 DESIGN.md:27 早有记录；新的只是量级与字段层观察（第一版这里写的「`isSidechain` 缺席」本身也是错的，第 8 条推翻） | 两份 |
| 5 | 「我们的 trace 暂时没有自由文本」 | **错，且方向相反**。`findings[].claim` / `agents[].perspective` / `end.subagents[].desc` 已在落盘。脱敏不是预防，是补洞 | 对比 §6.1 |
| 6 | §3.4 用全语料算「0 个会话被漏掉」 | 口径错。teamai 运行时只见主会话文件。已按运行时语义重算：结论仍成立（0/20），但**有 3 个会话正好卡在 20 分**，余量不厚 | 对比 §3.4 |
| 7 | 「它的判据常量没有回归钉子，这点我们更强」 | **错，撤回**。它有 13 个测试文件涉及判据（第一版写 10，口径不明，已改），含一条 `counts user interrupts (both variants)` 把双计**钉成预期行为**——所以 §3.1 ① 也从「疏漏」改判为「有意的分类学差异」 | 对比 §3.1 / §6.2 |
| 8 | 「`isSidechain` 在子 agent 文件里根本不出现，靠目录区分」 | **错，方向反了**。728 个文件 119,969 条记录全是 `true` 并带 `agentId`；主会话文件全是 `false`。同轮限定了 4 条：提示还有 `toolCount >= 15` 硬门槛（§3.4 验算未建模）；git commit 降权常量为 0；脱敏在出口而非全链路（本地 events.jsonl 明文）；「业务仓零残留」只是默认模式，self 模式知识随 main 走 | 两份 §3.2 / §3.4 / §4 / §5.1 / §6.1 |

第 7 条连带出了本次审计**最有价值的一条**：它的测试不是缺失，是
**靠 fixture 选择恒绿**——全套件 `Permission to use` 出现 0 次。
这比「它没写测试」有意思得多，也更值得我们警惕。

第 8 条的教训和第 1 条同款：第一版的「不出现」是**没数就下的结论**，数一遍只要一条 grep。
第二轮的 4 条限定则都来自**只读代码、没读官方文档**——self 模式、硬门槛、降权为 0、
本地明文，官方 `docs/usage-guide.md` 和设计文档里都有明写。
