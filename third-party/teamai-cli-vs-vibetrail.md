# 三方对比：teamai-cli / LoongSuite Pilot / vibetrail

> 配套文档：[teamai-cli.md](teamai-cli.md) 与 [teamai-cli-collection.md](teamai-cli-collection.md)（腾讯 teamai-cli）、
> [loongsuite-pilot.md](loongsuite-pilot.md) 与 [loongsuite-pilot-collection.md](loongsuite-pilot-collection.md)
> （阿里云 LoongSuite Pilot）。
>
> teamai-cli 快照 HEAD `6ae0619`（2026-09-09；第一版基于同日的 `224c0c4`，之间 10 个 commit，影响本文的只有 ZCode、
> multi-project P3、self 模式瘦身三项，见附录第 9 条）。LoongSuite Pilot 快照 HEAD `d4ab8b6d`（2026-09-08），
> 全部读码所得、本机未装，第 11 条并入。判据实测于 **2026-09-09**，语料 **762 个 transcript 文件**。
>
> 本文原名「teamai-cli vs vibetrail」，2026-09-10 扩为三方；文件名保持不变以免打断交叉引用。

## 1. 结论先行

**三个项目在同一条链路上取不同的段，两两之间基本不重叠。**

最有用的一句话是三方各自**存什么**：

| | 存什么 | 后果 |
|---|---|---|
| teamai-cli | **存结论** —— 判据跑完只留计数，文本截断到 200 / 500 / 160 字 | 数字可用于阈值，反推不回原文 |
| LoongSuite Pilot | **存原料** —— 完整 prompt / 输出 / 工具参数与结果，正文零截断，但**不做任何分歧判定** | 什么都能反推，自己一个结论都不给 |
| vibetrail | **存证据** —— 判据 + 每条带原始消息 uuid 的回跳指针 | 既是计数，又能回现场 |

| | teamai-cli | LoongSuite Pilot | vibetrail |
|---|---|---|---|
| 一句话 | 把团队的 AI 配置和经验分发到每个人 | 把各家 Agent 的活动统一采集上报 | 拿到一个 commit，追回它是怎么来的 |
| 时间方向 | **向前**：让下一次会话干得更好 | **横向**：让此刻正在发生的事可观测 | **向后**：让出问题时能查回去 |
| 主体 | 团队（多人多仓多工具） | Agent 运行时（多 harness） | 代码（一个仓的提交历史） |
| 数据归属 | 机器本地 + 独立的团队知识仓 | 机器本地 + **可配置的云端**（SLS / HTTP / OTLP） | **随被观测的代码走**（`<repo>/.claude/trace/`） |
| 内容采集 | 截断文本，默认留本机 | **完整正文，默认开、默认不脱敏** | 结构化字段 + 部分自由文本 |
| 分歧判定 | ✅ 有判据（4 类信号 + 阈值） | ❌ **完全没有** | ✅ 有判据（6 类 kind） |
| 规模 | 63.4K 行 TS，695 commit，40 人 | 434 个 TS 源文件，21 个 harness | 一组 shell/jq 工具 |

两处重叠，性质完全不同：

- **与 teamai 的重叠在判据层**：都读 Claude Code 的 transcript，都从里面提取人机分歧信号。
  这是唯一的正面对撞，§3 是逐条实测对比。
- **与 Pilot 的重叠在采集层**：都要决定扫哪些文件、采多少内容、落在哪。但它**不判定分歧**——
  `STOP_REASON_MAP`（`assets/hooks/claude-code/message-converter.mjs:20-30`）只有 6 种映射，
  没有「用户中断」这一类，`cancelled` 只在 Grok / Qoder 链路出现。它把
  `[Request interrupted by user]` 当普通用户消息全文存下来：**内容在，标记不在**。
  所以两边在 §3 那张判据表上无从对撞，对照在 §3.2（采集范围）和 §4（落点）。

一个有意思的推论：**Pilot 的数据理论上能反推出本项目的全部判据**（全文都在），
但它自己不做；teamai 的数据反推不出来（内容已截断）。这正好说明「采集范围」和「判据精度」
是两个正交维度——§7 第 2 条的教训在三方语料上都成立。

## 2. 功能面对照

| 能力 | teamai-cli | LoongSuite Pilot | vibetrail | 说明 |
|---|---|---|---|---|
| 团队资源分发（skill/rule/MCP/hook/agent） | ✅ 成熟 | ❌ 不做 | ❌ 不做 | teamai 的主业 |
| 多 harness 适配 | ✅ 11 个 | ✅ **21 个** | ❌ 只 Claude Code | Pilot 覆盖面最大 |
| 多 git provider（6 类）+ 非 git 的 HTTP 后端模式 | ✅ | — 不涉及 | ❌ 只本地 git | |
| 团队知识库 + 检索（BM25 + 图） | ✅ beta | ❌ 不做 | ❌ 不做 | |
| 代码知识图谱（tree-sitter AST） | ✅ beta | ❌ 不做 | ❌ 不做 | |
| **读 transcript 提取人机分歧** | ✅ | ❌ **读但不判** | ✅ | **teamai 与本项目的唯一正面重叠，见 §3** |
| 纠正话术识别（`correction`） | ✅ 启发式 | ❌ | ❌ 已主动搁置 | 见 §3.4 |
| 敏感信息脱敏 | ✅ 出口处 `redact()`（本地事件流仍明文） | ⚠️ 有 9 类规则但**默认 `none`** | ❌ **已落自由文本，无脱敏** | 见 §6.1 |
| 团队看板 / 周报 | ✅ | ✅ 本机 Dashboard + 云端 AgentLoop | ❌ 不做 | |
| learning 投票飞轮 + 晋升 | ✅ | ❌ 不做 | ❌ 不做 | |
| CI 上从 MR 提知识（`ci extract-mr`） | ✅ | ❌ 不做 | ❌ 不做 | MR → 知识，非 commit → 会话，见 §5.1 |
| **commit ↔ session 关联** | ❌ | ⚠️ 仅 Qoder 云端 API 链路 | ✅ trailer 注入 | 见 §5.1 |
| **行级 AI 代码归属** | ❌ | ⚠️ 仅 Qoder 云端 API 链路 | ❌ | `committed_ai_lines_edit`，见 §5.1 |
| **审计过程留痕** | ❌ | ❌ | ✅ `vibetrail-audit` | 见 §5.2 |
| 单事件可回跳原文（uuid 指针） | ❌ 只存计数 | ⚠️ 无原文锚点，但**存了全文副本** | ✅ `turn` 字段 | 见 §5.3 |
| 留痕随代码走 | ❌ 默认反向；self 模式知识随 main 走 | ❌ 反向（本机 + 云端） | ✅ D2 | 见 §4 |

Pilot 有而另两家都没有的，单列一组：

| 能力 | teamai-cli | LoongSuite Pilot | vibetrail | 出处 |
|---|---|---|---|---|
| 完整对话正文采集（零截断） | ❌ 截断 200/500/160 字 | ✅ | ❌ | [采集清单](loongsuite-pilot-collection.md) §1.2 |
| 子 agent transcript | ❌ 看不到 | ✅ `SubagentStop` + 读独立文件 | ✅ 扫全量 | §3.2 |
| system prompt 采集 | ❌ | ✅ 进程内拦 `/v1/messages` | ❌ | 采集清单 §1.5 |
| 工具参数与结果正文 | ❌ 明确不采 | ✅ 全文 | ❌ | 采集清单 §1.2 |
| 图片等多模态 | ❌ | ✅ 传对象存储（仅 Codex/Qoder） | ❌ | 采集清单 §3.4 |
| **修改用户即将执行的命令** | ❌ | ✅ 注入 `TRACEPARENT` 到 Bash | ❌ | 采集清单 §1.4 |

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

**⚠️ 这一节的结论只对 teamai 成立，不能推广到「三方工具都看不到子 agent」。**
LoongSuite Pilot 装了 `SubagentStop`（`agents.d/claude-code.json:11-16`），
并且 `resolveSubagentTranscriptPath`（`assets/hooks/claude-code-hook-processor.mjs:113-143`）
拼的正是 `<dirname(父 transcript)>/<父 sessionId>/subagents/agent-<id>.jsonl` 这个布局，
子事件改写为父级 `trace_id` / `turn_id` 后带 `gen_ai.agent.scope=subagent` 标记（`:669-685`）。

三方在这一维度上的位置：

| | 看得到子 agent 文件 | 从中提取分歧信号 |
|---|---|---|
| teamai-cli | ❌ 无 `SubagentStop`，无遍历代码 | ❌ 因此漏掉 58% 的人拒 |
| LoongSuite Pilot | ✅ 读独立文件，只展开一级（`:869`） | ❌ **它不判分歧**，全文存下来但不标记 |
| vibetrail | ✅ 按 worktree 聚合扫全量 | ✅ 6 类 kind |

Pilot 与本项目在发现子 agent 的**手段**上略有不同：它靠 transcript 里的 `toolUseResult.agentId`
（`transcript-parser.mjs:326-337`），不使用 `isSidechain`；本项目 OPEN-ISSUES K1 的去重方案走
`isSidechain` / `agentId` 分层，两者在 `agentId` 这一路上一致。

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
「会话自主性」的人均干预率排行，并说它「可用于验证某个 skill / rule 上线后干预率是否下降」。

用本语料算（且假设它能扫到全部文件，实际还要再打个对折）：
它会报 `285 + 44 = 329` 次干预，真实的人类分歧动作是 **342** 次
（250 主动打断 + 92 拒绝，配对记录合并计一次）。329 vs 342 只差 4%，
**但这个「准」是假的**：由 **+35 虚增**和 **−48 漏计**抵消而来。语料构成一变，抵消就没了。

**结论**：判据的精度要求由用途决定。对方按阈值造，我们按计数造，
**对方的数字不能直接拿来当计数用**——这是这次对比最有价值的一条。

### 3.5 方法论上两边是同源的

不能只讲差异。teamai 做对了两件业内没普及的事，和本项目独立收敛到了同一处：

1. **只读 JSON 字段，不 grep 整行原文。** 它锚定 `type === "user"` 的记录、逐块判
   `is_error`，没有裸 grep（`:233-241` 有一个整行 `includes('"user"')` 式的预筛，但只用来跳行，
   产生不了命中）。本项目 spec §3.3 第 1 条讲的是同一件事
   （裸 grep 在对抗样本上精确率仅 10.5%）。
2. **区分人的决定与机器的行为。** 它分 `toolReject`（人拒）/ `toolError`（机器），
   我们用 `human` 布尔。**这个区分本身是对的**，两边只是分界线画的位置不同。

对照本项目 spec §3.1 记的业内水平（SpecStory 只认 interrupt 一行前缀匹配、
git-ai 与 claude-story 一个都不认），**teamai 是本项目见过的三方实现里最强的一个**，
spec 该节的「三个实现读下来」应当补上它。

## 4. 最根本的分歧：数据落在哪

这不是实现差异，是**目标冲突**，三方都写进了设计文档。

| | teamai-cli | LoongSuite Pilot | vibetrail |
|---|---|---|---|
| 设计目标 | **业务仓零残留** | **统一采集，送到你指定的地方** | **数据随代码走** |
| 落点 | `~/.teamai/projects/<slug>/` + 独立团队知识仓 | `~/.loongsuite-pilot/` + 可配置远端（SLS / HTTP / OTLP） | `<repo>/.claude/trace/` |
| 理由 | 机器数据实测占业务仓 18 MB，污染工作区、worktree 读不到、多项目混淆 | 数据是给可观测性后端消费的，落点由部署方决定 | 数据离开它描述的代码就失去价值（D2） |
| 出处 | `docs/designs/data-directory-layout.md` | `docs/zh-CN/overview.md` 输出目标一节 | `DESIGN.md` D2 |

Pilot 在这个轴上离本项目**最远**：它连「跟着人走」都不是，是「跟着可观测性平台走」。
数据的归属方既不是代码也不是个人，而是配置了 endpoint 的那个组织。

一条必须补的限定：**Pilot 有一路数据不受这个选择控制。** 默认配置下会话内容一个字都不出本机，
但 `src/internal/statistic.ts` 每 12 小时把主机指纹（`ip` / `hostname` / `os_detail` /
可逆的 `instance_id`）直发固定的阿里云 SLS，无条件、无 opt-out、文档零提及
（[loongsuite-pilot-collection.md](loongsuite-pilot-collection.md) §3.5）。
所以「落点由部署方决定」这句话对**业务数据**成立，对**主机标识**不成立。

两边都对，因为**描述的对象不同**：teamai 存的是「团队现在的配置和经验」——它跟着人和
团队走，放进某个业务仓反而是错的；我们存的是「这段代码是怎么来的」——它跟着代码走，
放在机器本地则换台机器就没了。

**一条必须加的限定：上表说的是采集数据与机器数据，两种模式都不随代码走；self 模式的特殊之处只在知识资产。**
单仓模式（self mode，`teamai init .`）下**知识资产是随代码走的**：skills / rules / docs /
learnings 和 `teamai.yaml` 提交在业务仓 main 的 `.teamai/` 里，clone 即得；会话与摩擦上报
（members / sessions / votes / stats）推到同一 origin 的 `teamai-reports` 孤儿分支——同仓、
但独立历史；机器数据（config / state / 搜索索引 / env 备份 / MCP manifest / workspaces）自 P2 瘦身
（`b5435b3`，HEAD 已含）起也搬进 `~/.teamai/projects/<slug>/`，`.teamai/` 里只剩提交到 main 的知识和
gitignore 的临时 worktree——第二轮写的「零残留只是默认模式的目标」在 HEAD 上已不成立，两种模式都零残留。
所以「目标冲突」准确说是**采集数据两边都不随代码走、知识资产 self 模式随代码走**：它让「团队现在的
配置和经验」跟着代码走了，但「这段代码是怎么来的」这类会话数据仍不在代码的提交历史里，
与本项目的分歧在这一层没变。

有意思的是**两边都被 worktree 咬过，解法相反**：

- teamai：`git worktree list --porcelain` 取**第一条**当 `projectAnchor`，作为稳定的
  项目身份来分区；同时资源必须写 `workspaceRoot`（当前 checkout），因为所有 AI 工具
  都只从启动目录往上扫到当前仓根。
- vibetrail：`vibetrail-sync` 按 `git worktree list` **聚合全部** worktree 根来归属会话
  （比 SpecStory 的 cwd 1:1 反查宽，否则在 worktree 里 sync 不到主仓的会话）。

同一个 API，一个用它收敛成单一身份，一个用它扩散成全集。

## 5. 我们有而两家都没有的（已 grep 核实）

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

**这是两个项目最大的能力差，且方向上不可互换**——它不碰用户的 git hook：全仓没有安装 git hook
或写 `core.hooksPath` 的代码（grep 核实）。`src/utils/git.ts:30-31` 那句「不写 `core.hooksPath`，不改变用户
平常的 `git commit`」说的是它自己在隔离 worktree 里提交知识 / 上报时 `--no-verify` 的作用域，不是关于用户
hook 的政策宣示——「自觉的边界选择」是本文的推断，不是它的自述；结论（不是没做完）不变。

**LoongSuite Pilot 的情况不一样，值得单独说 —— 它识别到了这个需求，写了类型，然后停在那里。**

`src/types/events.ts:190-201`：

```typescript
/** Git hook event from post-commit / pre-push hooks. */
export interface GitHookEvent {
  eventType: 'post-commit' | 'pre-push';
  repoRoot: string;
  commitHash: string;
  branchName: string;
  changedFiles: string[];
  timestamp: number;
}
```

**全仓零引用**（grep 核实），没有任何实现，也没有装 git hook 或改 `core.hooksPath` 的代码——
它与 git 的唯一交互是 `src/utils/git-context.ts:68` 的 `execFile`，**只读**。

但这个形状正是本项目需要的：`post-commit` / `pre-push` 事件，带 `commitHash` 与 `changedFiles`。
**「没人做过」和「有人写下了类型但没做」是两个不同的结论**，本文此前的判断要按后者更新。

另外 Pilot 在一条链路上**确实有** commit 关联，而且比我们多一层：
`src/pipeline/input/qoder-api/qoder-api-client.ts:278` 拉
`/v1/organizations/{orgId}/ai-code-tracking/commits`，写出的条目
（`qoder-api-input.ts:689-729,879-880`）带 `commit_hash` / `commit_ts` / `commit_message`，
以及 **`committed_ai_lines_edit` / `committed_total_lines_edit`** —— **行级 AI 代码归属**。

三条限定，缺一不可：

1. 它是从 **Qoder 组织级服务端 API 拉的**，不是本机采集——所以本质上是 Qoder 云端已经算好了，
   Pilot 只是搬运。
2. 只在 Qoder 生态内，**Claude Code 链路完全没有**。
3. 方向是 commit → 统计聚合，不是 commit → **这次会话**；`ai-code-tracking` 回答的是
   「这个组织的 AI 代码占比多少」，不是「这个 commit 是哪次会话写的」。

所以本项目 CAPABILITIES 里「commit ↔ session 关联无先例」的判断**仍然成立**，
但措辞要收紧：**行级 AI 归属有先例（Qoder 云端），commit ↔ 单次会话的关联仍然没有。**

### 5.2 审计过程留痕

teamai 的 `review-cmd` / `review-store` 名字像，实际审的是**知识库待审条目**
（`.teamai/pending-review.jsonl`，`codebase-section` / `domain-drift` /
`multi-source-conflict` 三类），与代码审计无关。

LoongSuite Pilot 连名字像的都没有：grep `code.?review` / `审查` / `评审` / `审计` / `audit` / `sast`
在 `src/` 与 `agents.d/` **零命中**。它采集 code review 工具产生的会话（如果那个工具是它支持的 21 家之一），
但不记录 review 这件事本身。

**「记录审计本身」这件事仍然没有先例**——本项目 CAPABILITIES §2.4c 的判断经这次扫描
再次确认，可以把 teamai 与 LoongSuite Pilot 都列进「审的都是代码，没有一个记审计本身」那份名单。
需要注意的是 AgentLoop（Pilot 的云端消费方）的官方材料确实讲「审计」——但那是
「agent 执行了哪些高危命令」的**安全审计**，不是「一次代码评审的过程」，两者同名不同物。

### 5.3 单事件可回跳

我们每条 diverge 带 `turn`（原始消息 uuid），transcript 还在就能跳回现场看上下文。
teamai 只存聚合计数和脱敏摘要，**没有回跳锚点**——它的用途不需要。

Pilot 是第三种情况，值得单独记：**它没有指回原始 transcript 记录的锚点**
（`event.id` 是 collector 自己生成的确定性 sha256，`gen_ai.session.id` / `turn.id` / `step.id`
也都是它自己的体系），**但它把原文整份复制了一份**。

所以「可回跳」这个需求对它不成立——不是做不到，是不需要：指针的价值在于「原文太大不便存」，
而它选择了存原文。代价写在 [采集清单](loongsuite-pilot-collection.md) §2.4：
那份含完整对话正文的 `logs/<agent-id>/*.jsonl` 不被任何保留策略覆盖，永不删除。

**三种取法对应三种成本**：teamai 存计数（最省，不可回溯）、vibetrail 存指针（省，可回溯但依赖原文还在）、
Pilot 存副本（最贵，自足但无限增长）。本项目选指针是因为 trace 要随仓走，体积是硬约束——
这个理由在 Pilot 的部署形态下不存在。

## 6. 它有而我们没有、且值得抄的

按性价比排序。**只列真正该做的，不列「它有所以我们也要有」的。**

### 6.0 装一次、之后每次会话自动上报 —— 已立为需求，见 OPEN-ISSUES G7

这条不是本文的推断，是用户看完对比后直接提的：「做成和 teamai 一样，装一次就行，
然后 Claude 每次对话写代码的时候自动上报两路信息」。对方的做法在分析文档 §4.4
（一次 `init` 写四个 harness hook、一个入口分发）和 §4.3（self 模式把 `.claude/settings.json`
连 hooks 提交到 main，clone 即得）。现状、要动什么、以及「两路」待确认，都只记在
[OPEN-ISSUES.md](../OPEN-ISSUES.md) 中心表 G7，此处不重复。同日追加的 G8（采集限定在指定项目）、
G9（本地能看采集了什么、让开发放心）同样以 teamai 为参照，也只记在中心表。参照 G8 时注意一条实测：
teamai 的 `--project`（HEAD 已落地 `projects list/set/members` 与 `push --project`）只作用于资源分发，
采集数据（`stats/` / `events.jsonl` / session 摘要）不带 project id；而且分发层 **fail-open**——没 init 过的
目录里 hook 一样把事件写进本机 `events.jsonl`（`hook-dispatch-cli.ts:185` 取不到 config 时
`filterHandlersForConfig()` 原样放行，注释自称「fail-open by design」）。它有的只是**上报限定**：
`filterEventsByScope` 按 cwd 决定哪个团队仓收哪些会话。「采集限定在指定项目」这个能力它没有，
见采集清单 §1 / §3.1；OPEN-ISSUES G8 第一版转述的「其余目录一律早退」已同日改正。

### 6.1 脱敏（`redact()`）—— 建议列入待办

teamai 在**每个出口**强制脱敏：contribute 提示里的任务摘要、session save 的首 prompt、
Stop 时截取的 AI 输出，三处都过 `redactWithEnv()`；且团队推送默认**只推计数和工具名**，
prompt 文本要显式 opt-in（注释理由：`redact()` 是尽力而为，所以即便脱过也默认不推）。「只推计数」指的是
不推 prompt 文本——`session save --push` 的 markdown 仍带完整 sessionId 与 cwd 绝对路径，harness 不给
`session_id` 时兜底 id 里还嵌一次 cwd（采集清单 §2.1 / §3.2）。
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

**LoongSuite Pilot 在这一条上提供了更好的样板 —— 以及更值得记的三个教训。**

它把「采不采」和「擦不擦」拆成管线里两个独立步骤（`src/core/input-manager.ts:333-431`
的第 6、7 步）：

| 层 | 开关 | 语义 | 默认 |
|---|---|---|---|
| 内容策略 | `agents.<id>.captureMessageContent` | 消息正文、工具参数与结果**采不采** | `true`（采） |
| 脱敏 | `mask.mode` | 已采到的文本里，密钥与个人信息**擦不擦** | `none`（不擦） |

**这个两层模型本身是对的，比单一开关表达力强**，本项目 OPEN-ISSUES K6 值得直接借这个形状。
但它的三个教训比模型本身更值钱，因为三条我们都可能犯：

1. **出口那层要有测试守着，否则就是死代码。** 它的出站兜底 `redactCodeGenerationFields()`
   删的正好是全部内容字段，而 `endpoint.redact` 全仓硬编码 `false`——函数永不执行
   （[采集清单](loongsuite-pilot-collection.md) §5.1）。写了、也合理、就是不生效。
2. **字段清单要有单一真相源。** 内容策略有**两份** `MESSAGE_CONTENT_FIELDS`（hook 侧 14 项、
   daemon 侧 17 项），手工维护、已经分叉，而且**两份都漏了 `error.message`**——
   那是工具失败时的结果正文前 500 字符，于是关掉内容采集后它照样出本机（§5.2 / §5.3）。
   讽刺的是同一个仓里 `src/utils/data-dir.ts:4-15` 正好批评过这个模式：「**a comment is not
   a mechanism**」，那处后来换成了测试断言，内容策略这处没有。
3. **默认值决定实际效果。** 两层设计得再好，`captureMessageContent` 默认 `true` +
   `mask.mode` 默认 `none`，出厂状态就是「全采、不脱」。

本项目要抄的是形状，不是默认值。

### 6.1b 失败诊断只留元数据 —— 直接抄

同一个「上报失败要留证据」的需求，两家做法相反：

| | 失败时写什么 |
|---|---|
| teamai | `reporter/errors.jsonl` 把**整个 context** 写盘，含 `promptSummary`、`stoppedOutput`、`transcriptPath`、`cwd`（[teamai-cli-collection.md](teamai-cli-collection.md) §2.8） |
| LoongSuite Pilot | `logs/sls-failed-logs/` **只有** endpoint、错误摘要、batch 条数与字节数估算；文档明写「**不包含失败 batch payload、消息正文、请求 headers 或凭证，因此不能用于重放失败数据**」（`docs/zh-CN/sls-output.md:154`），并带 10 MiB / 50 MiB / 7 天三重上限 |

Pilot 这个做法是对的，理由不只是隐私：**失败诊断的用途是定位链路问题，不是补发数据**，
一旦存了 payload 就同时承担了保管责任。本项目将来若有上报或导出失败路径，默认应当是这个形态。

### 6.2 判据脆弱性的共同解法 —— 两边都没有，值得一起想

两边都硬编码英文消息串，上游改文案即**静默失效**。

⚠️ **本文第一版写「它的判据常量没看到等价的回归钉子，这一点比 teamai 强」，
审计时核实是错的，撤回。** teamai 有 13 个测试文件涉及这套判据（按 `toolReject` /
中断串 grep；其中 4 个把判据字面串硬编码进 fixture，**0 个** import 判据常量本身——第一版写的
「直接引用判据常量的 4 个」口径错了，第三轮改），
`dashboard-collector.test.ts` 里三条用例分别钉住「两个 interrupt 变体」「工具拒绝」
「普通工具错误不算拒绝」——**保护强度与我们的 `test-extract.sh` 同级**。

真正的发现比「谁有测试」有意思得多：**它的测试是靠 fixture 选择恒绿的。**
全套件里 `Permission to use` 出现 **0 次**——它的 is_error fixture 只有一种形态，
正是它的匹配串覆盖的那种。所以 §3.1 ② 那 52% 的缺口，**只要 fixture 集不变，它的测试就看不见**。
这正是本项目 CAPABILITIES §2.4 记的「假绿」模式：比对输出恒绿，缺的是语料形态。

我们在这一条上暂时没有镜像盲区（`tools/fixtures.jsonl` 26 条里两种拒绝形态都有，
含多行命令变体）——但**机制上的风险完全相同**：两边的 fixture 都是照见过的形态手搭的，
第三种没见过的形态对两边同样不可见。

这是本项目 spec §7 已记的已知脆弱点，扫完两家之后结论不变：**业内没人解了**。
可做的只有一件：把 fixture 的来源从「见过的」换成「从全语料里聚类出的」，
让新形态出现时至少有机会被抓到。已立为 [OPEN-ISSUES G6](../OPEN-ISSUES.md)。

**LoongSuite Pilot 也没解**，但它贡献了一条方向性的提醒：`docs/codex-aborted-turn-recovery.md:12,64-67`
判「用户打断」用的是类型化记录 `event_msg:turn_aborted`，**不是 UI 字符串**，输出再归一到固定词表。
能拿到类型化信号的 harness 就不该匹配字符串——Claude Code 的 transcript 在这一点上不给类型
（`[Request interrupted by user` 只有正文），所以三方在这条路上被迫一致。
提醒本身值得留：**每次上游更新都该查一遍有没有新增的类型化字段能替掉硬编码串。**

### 6.2b 采集范围的钉子 —— 三方全都没有，但 Pilot 有现成零件

对比文档 §7 第 2 条一直提这个问题（判据有测试、范围没有），这次在 Pilot 里找到了三种可用的形态，
分别对应「范围会怎么缩」的三种成因：改代码改缩了（基线 digest diff）、运行时环境变了（四阶段漏斗）、
I/O 失败被静默吞掉（显式的 scan-completeness 信号）。

**已立为 [OPEN-ISSUES G10](../OPEN-ISSUES.md)，细节与行号在那里，此处不重复。**
需要在这里记一句的是：Pilot 自己**也没有**钉住「必须覆盖子 agent」——它装了 `SubagentStop`
是产品选择，不是回归保护。**三方在这条上全都裸奔**，只是我们和 teamai 已经因此付过代价。

### 6.2c 两个写法 —— 建议抄进 spec 与审计台账

来自 Pilot 的 `openspec/changes/add-trace-runtime-observability/`（OpenSpec 规范驱动开发的一次性使用：
只有 1 个 change、4 个文件，且被 `.gitignore` 忽略后 `git add -f` 强行留档）。规范格式本身不特别，
值得抄的是里面两个习惯。

**① 把「怎么验证」写成一条需求，并用 SHALL NOT 约束测量本身。**

那份 spec 的 6 条 Requirement 里，最后一条是（`specs/trace-runtime-observability/spec.md:66-72`）：

> **Requirement: Performance validation uses the actual pipeline**
> The implementation SHALL reuse precomputed event sizes and **SHALL NOT add file rereads, event
> serialization, CPU profiling or heap snapshots for diagnostics.** Before delivery it SHALL compare
> baseline and modified processing on the same synthetic input through the real converter…

「验证方式」不是留给实现者临场发挥的，而是和功能需求同级写死；`SHALL NOT` 那半句约束的是
**测量不得改变被测对象**——`input-runtime-metrics` 那句「不为统计再次读取、不保存正文」正是从这里来的。
本项目 spec §5 稳定面目前只约束数据格式，不约束「这条断言该怎么验」。

另外它 10 个 Scenario **几乎全是负例与边界**：「测量不可用」「转换完成前 buffer 被移除」
「维度上限打满」「pending 范围被解读」「诊断上报失败」「两次采样之间结束的短 turn 没有 ID」。
等于把 K 系列（已知缺陷）**提前写在实现之前**，而不是等出事了再记进 OPEN-ISSUES。

**② 显式声明本次「没有」证明什么。**

`tasks.md` 末尾的 `## Scope and verification` 段落，最后一句是：

> No zero-overhead, real-Agent, installed-Pilot or online-delivery claim is made.

同段还做了三件我们应当照做的事：记基线 SHA；如实记 `4,134 passed, 58 skipped, **24 failed**`
并证明这 24 个在**未改动的 main 上同样失败**（还跑了 probe 确认根因是 Python 被 SIGKILL），
外加一句「No related tests were changed or skipped」；以及**保留不利数据**——写了五次运行的结果，
也写了更早三次运行波动更大（+3.05% CPU / +5.20 MiB）。

这和本项目已有的「审计台账」传统是互补的两件事：**台账记的是「哪些断言被推翻」，
这一段记的是「哪些结论从来没被证明过」**。前者防自己记错，后者防读者过度解读。
[loongsuite-pilot-collection.md §7](loongsuite-pilot-collection.md) 的局限说明已经是这个形状，
建议把它固化成三方文档的固定段落。

### 6.3 不建议抄的

- **`correction` 启发式**：中英日词表 + 60s 窗口，代码里没有准确率实测。
  本项目 spec §3.1 已明确把它挡在门外（「现有四个 kind 都是硬信号、已有可用准确率，
  先把启发式挡在门外；要加须先有独立的准确率实测，且必须与硬信号分开统计」）。
  **这次扫描支持维持原判**：对方的实现恰好示范了没有实测的启发式长什么样。
- **dashboard / digest**：需要团队规模才有意义，与本项目「一个仓的提交历史」的主体不符。
- **多 harness 适配**：本项目的地基（hook 在 desktop 下热加载、
  `CLAUDE_CODE_SESSION_ID` 逐字等于 transcript 文件名）是 Claude Code 特有的实测结论，
  摊到 11 个 harness 上等于重做地基。Pilot 用 21 家 × 6 种 deployMode 证明了这条路要付的价钱：
  `fix:feat = 181:82`，三分之一的代码在 `inputs/` 适配各家格式。
- **进程内注入**（Pilot）：`BUN_OPTIONS --preload` 注入 agent 进程、往 Bash 命令前拼
  `export TRACEPARENT=...`、往 `~/.zshrc` / `~/.bashrc` 追加 marker 块并由 watchdog 自动修复
  （[采集清单](loongsuite-pilot-collection.md) §1.4 / §1.5）。这是**进入被观测者的执行路径**，
  拿到的东西确实更多（system prompt 就只有这条路能拿），但本项目的定位是留痕，
  不该为此承担改写用户命令的风险。teamai 那条「只用 harness 生命周期 hook」的边界更适合我们。
- **存全文副本**（Pilot）：见 §5.3。trace 随仓走，体积是硬约束，存副本这条路对我们直接关闭。

## 7. 一句话总结

**teamai-cli 是「团队怎么用好 AI」，LoongSuite Pilot 是「Agent 干了什么要可观测」，
vibetrail 是「AI 写的代码怎么查回去」。**

与 teamai 撞车只在读 transcript 那一处：对方把它当**阈值信号**，做到够用就停；
我们把它当**计数与证据**，所以必须做到判据级精确。

实测证明这个精度差是真的，而且分两层：**判据层**漏 52% 的人拒（归成了机器失败），
**运行时层**再漏一次（不扫 `subagents/`，而 58% 的人拒在那里），合计只登记 40%。
同时也证明**对方并不因此有 bug**——这些误差在它自己的阈值判断里基本被吸收了，
实测没有一个有分歧的会话在分数口径上被它彻底漏掉（`toolCount` 硬门槛未建模，见 §3.4）。

与 Pilot 则**根本不在判据层撞车**：它采集范围三方最强（扫子 agent、拿 system prompt、全文零截断），
却**一个分歧信号都不判**。它把原料完整搬走，判断留给下游平台。

真正的教训不是「谁更准」，而是三条：

1. **判据的精度要求由用途决定。** 跨用途搬运数字（比如把 teamai 的干预率当干预计数）
   会静默出错——错的方向还是双向抵消的，看起来更像对的。
2. **判据对了，采集范围错了一样白搭。** teamai 的判据方法论和我们同源，
   差距的一多半却来自「只扫了一个文件」这种与判据无关的地方。
   本项目按 worktree 聚合扫全量是对的，但这条**没有回归钉子守着**——
   哪天采集范围缩了，判据测试全绿，数字静默减半。
   三方在这一条上**全都没有守卫**：Pilot 装了 `SubagentStop` 也只是恰好装了，
   同样没有测试钉住「必须覆盖子 agent」。
   **已立为 [OPEN-ISSUES G10](../OPEN-ISSUES.md)**，可用的三种钉子形态见 §6.2b。
3. **采集能力越强，治理缺口的代价越大。** Pilot 是三方里唯一采到全文的，
   于是它的每一个治理疏漏都变成实打实的暴露面：出站兜底是死代码（§6.1 教训 1）、
   内容策略两份清单分叉且都漏了 `error.message`（教训 2）、
   含完整正文的日志永不删除（[采集清单](loongsuite-pilot-collection.md) §2.4）、
   还有一条未声明的主机指纹回传（§4 末尾）。
   **teamai 犯同类错误的代价小得多，因为它手里只有 200 字截断。**
   本项目的 trace 随仓走、会推到远端，暴露面更接近 Pilot 而不是 teamai——
   所以这一条对我们是直接适用的警告，不是旁观。


## 附录：本文档的审计记录（2026-09-09 起）

初稿写完后做了一轮对抗性审计，逐条回查代码与数据，**7 处断言被推翻或需要修正**；
第二轮对照 teamai 官方 `docs/` 复核，又推翻 1 处、限定 4 处（第 8 条）；第三轮对齐到对方 HEAD `6ae0619`
逐条回查三份文档，推翻 2 处、过期 3 处、补口径 4 处（第 9 条）；第四轮抽查 OPEN-ISSUES G8 对 teamai 的转述，
推翻 1 处「其余目录一律早退」（第 10 条）。**第五轮（2026-09-10）扩为三方，加入 LoongSuite Pilot，
推翻 1 处隐含推广、收紧 1 处措辞（第 11 条）；同轮第二部分通读对方 `docs/` 剩余篇目与
`openspec/` / `solutions/`，产出 [OPEN-ISSUES G10](../OPEN-ISSUES.md) 与 §6.1b / §6.2b / §6.2c，
另有 1 处自我推翻（第 12 条）。**
均已改在正文里，此处只留台账——这份文档自己也该有留痕。

**第四轮的第二部分没跑完**：改完前九条之后照惯例（见本项目 memory「修完再全新审计」）另起了一个
独立只读 agent，对三份文档做逐 hunk 的全新复核，但会话预算耗尽，用户在它读完第一批 diff、
尚未产出结论前中止了它。**这份文档目前只经过「自己动手复核 + 抽查」，没有第 1-3 轮那种完整的
独立第二意见。** 后续如果再碰这几份文档，应当先补跑一次完整的独立复核，而不是默认第 9/10 条
已经是终态。

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
| 9 | 第三轮（对方 HEAD `6ae0619`）：①「硬门槛 / 降权为 0 / 本地明文，官方文档都有明写」；②「直接引用判据常量的 4 个测试」；③「零残留只是默认模式」；④「README 矩阵 10 个 harness」；⑤「`projects set/members` 尚未落地」 | ① **错**：只有 self 模式在官方文档里，另三条只在代码注释，指南 `:1160` 对明文这条还写的是反话；② **口径错**：0 个测试 import 判据常量，4 个是把字面串硬编码进 fixture；③ **过期**：P2 瘦身后 self 模式机器数据也入分区；④ **过期**：ZCode 加入后 11 个；⑤ **过期**：P3 已落地。另补 5 条口径：`--project` 不进采集且分发层 fail-open（没 init 的目录照采，OPEN-ISSUES G8 的「其余目录早退」同日改正）；HTTP 同步四个事件都跑；contribute 提示三级开关；`git.ts` 那句注释是 `--no-verify` 作用域而非 hook 政策；recall 命中加的是 `recalled_count` 不是 upvote | 三份 + OPEN-ISSUES G8 |
| 10 | OPEN-ISSUES G8 转述「hook-dispatch 按 cwd 门控……其余目录一律早退」 | **错**。`hook-dispatch-cli.ts:185` 取不到 config（没 init 过 / 解析失败）时 `filterHandlersForConfig()` 按注释「fail-open by design」原样放行全部 19 条 handler；`dashboardReportHandler` 本身也不查 config。teamai 有的是**上报限定**（`filterEventsByScope` 按 cwd 决定哪个团队仓收哪些会话），不是「采集限定在指定项目」这个能力 | OPEN-ISSUES G8 / 三份 |

| 11 | 第五轮（2026-09-10，加入 LoongSuite Pilot HEAD `d4ab8b6d`）：① §3.2 的行文把「看不到子 agent」写成了三方通例；② §5.1「commit ↔ session 关联无先例」 | ① **错**：Pilot 装了 `SubagentStop` 并直接读 `subagents/agent-*.jsonl`，那节结论只对 teamai 成立，已加限定表；② **措辞过宽**：Pilot 的 `GitHookEvent`（`src/types/events.ts:190-201`）定义了 `post-commit`/`pre-push` 事件带 `commitHash` 与 `changedFiles`，**零引用未实现**——「没人做过」应改为「有人写下类型但没做」；且 Qoder 云端 API 链路有 `committed_ai_lines_edit` **行级 AI 归属**，所以准确的说法是「行级归属有先例，commit ↔ 单次会话仍没有」 | §3.2 / §5.1 / §2 表 |

第 7 条连带出了本次审计**最有价值的一条**：它的测试不是缺失，是
**靠 fixture 选择恒绿**——全套件 `Permission to use` 出现 0 次。
这比「它没写测试」有意思得多，也更值得我们警惕。

| 12 | 第五轮第二部分：「Pilot 的 `resource-context.mjs` 有两份副本、注释要求保持一致，**又漂移了**」 | **错，是我想多了。** 注释要求对齐的三项（`DEFAULT_RESOURCE_ENV_FIELD_MAP`、`SENSITIVE_FIELD_NAME_RE`、`MAX_RESOURCE_FIELD_VALUE_LENGTH`）逐字相同；两份的差异是 hook 版多出 85 行按次调用属性功能，plugin 版本来就不需要。**真正分叉的只有内容策略那两份 `MESSAGE_CONTENT_FIELDS`**（14 vs 17 项），已记在 [采集清单 §5.3](loongsuite-pilot-collection.md) | 未写入正文 |

第 11 条的教训和第 4 条同款，但方向不同：第 4 条是**把已知的事当新发现**，
第 11 条是**把对一个样本的观察写成了通例**。§3.2 原文并没有明说「三方都如此」，
但「它其实只扫一个文件」这种行文，在只有一个对照物时会被读成普遍结论。
加入第二个三方实现后立刻暴露。**样本量为 1 时，结论的措辞要显式绑定到那个样本。**

第 12 条是新的一类，值得单记：**它不是没查证，是差点为了叙事工整而夸大。**
当时手上已经有「`data-dir.ts` 注释自陈 keep-in-sync 漂移过」和「内容策略两份清单确实分叉」两个实例，
再看到第三处同形状的注释，「同一个仓里又犯一次」这个说法太顺手了。核实之后是相反的结论。
**手上的叙事越顺，越要在写下之前多跑一条命令**——这次拦住了，是因为写进文档前先 diff 了一遍。

**LoongSuite Pilot 这部分的证据等级低于 teamai 部分**：全部读码所得，本机未装
（`~/.loongsuite-pilot` 不存在），**没有任何实机数据**。§3 那种「同一份语料跑两套判据」的
正面对撞对它做不了，也不需要做——它根本没有判据。所有关于它的运行时行为（发送周期、
清理时机、watchdog 修复）都是从代码推的。详见
[loongsuite-pilot-collection.md](loongsuite-pilot-collection.md) §7 的局限说明。

第 8 条的教训和第 1 条同款：第一版的「不出现」是**没数就下的结论**，数一遍只要一条 grep。
第二轮的 4 条限定里，只有 self 模式是官方文档明写的（使用指南 + `data-directory-layout.md`）；硬门槛
（`toolCount >= 15`）、降权为 0、本地 `events.jsonl` 明文三条**官方文档一个字都没有**，只在代码注释里
（`src/types.ts:1063-1067`、`:1127-1128`、`src/dashboard-collector.ts:839-841`），使用指南 `:1160` 对明文
这条写的还是反话。第二轮把这句写成「都有明写」，是**把自己读代码得来的结论记成了对方文档的自述**——
第三轮撤回。第三轮自己的教训是**快照会动**：同一天里对方推了 10 个 commit，三条断言就此过期，
所以三份文档的引用都改成带 HEAD 与日期。
