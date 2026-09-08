# vibetrail 功能与实现原理

> 与另两份文档的分工：[DESIGN.md](DESIGN.md) 记**为什么这么做**（问题定义、决策、否决理由），
> [spec/trace-v1.md](spec/trace-v1.md) 是**数据格式的规范**，本文记**有哪些功能、怎么实现的、
> 还缺什么**。

## 0. 一句话

把 Claude Code 已经在写的会话流水，提炼成能随代码走的工程留痕，用来回答两个问题：
**这个 commit 是怎么来的**，以及**出问题时人和 agent 在哪一步对不上**。

## 1. 功能清单

| 功能 | 状态 | 实现 |
|---|---|---|
| 人机分歧提取 | ✅ **已实现** | `tools/extract-diverge.jq` |
| 分歧判据回归测试 | ✅ **已实现** | `tools/fixtures.jsonl` + `tools/test-extract.sh` |
| hook 机制探针 | ✅ **已实现** | `experiments/hook-probe.sh` |
| commit ↔ session 接链 | 🔶 **机制已实测，未落地** | `prepare-commit-msg` + 环境变量 |
| 审计过程留痕 | ⬜ 未实现 | 改 `mark-audit.sh` |
| 查询 / 复盘 | ⬜ **未实现，最大缺口** | 见 §3.1 |
| 接入引导 | ⬜ 未实现 | 见 §3.4 |
| 行级归属 | ❌ **已否决** | 见 [DESIGN.md §2.5](DESIGN.md) |

## 2. 实现原理

### 2.1 采集：不自建，复用 Claude Code 的流水

**不写采集层**。Claude Code 本来就把每轮对话、思考全文、每次 Edit 的 diff、
每条命令的 stdout/stderr、子 agent 的独立 transcript 写进
`~/.claude/projects/<cwd-slug>/<sessionId>.jsonl`。

代价是它**不入仓、体量数百 MB、换机器即失**。所以我们做的是**投影**而非采集：
把其中跨会话仍有价值的部分固化成 KB 级的索引，正文留在原地靠 uuid 指针跳回。

### 2.2 人机分歧提取（已实现）

`tools/extract-diverge.jq` 从 transcript 提取四类事件，每条带 `human` 布尔区分
「人的决定」与「机器/基础设施行为」——混计会让「人拒了多少次」被分类器和链路故障污染。

| kind | human | 一句话 |
|---|---|---|
| `interrupt` | ✅ | 人打断了 agent |
| `permission_denied` | ✅ | 人拒绝了一次工具调用 |
| `classifier_blocked` | ❌ | auto mode 分类器拒的 |
| `permission_infra_fail` | ❌ | 权限链路自身失败 |

判据的精确定义**只在 [spec §3.1](spec/trace-v1.md) 维护一份**，这里不复述，避免两份漂移
（曾经漂过：这里的版本漏了字符串正文与 `with this tool use`）。

**核心原理是「只读字段，不 grep 原文」**。会话自身会讨论这些标记（本项目的调研会话就是），
grep 原文会把「讨论」当成「发生」。实测对照：以本项目调研会话为靶，裸 grep 命中 19 条、
本规则命中 2 条，人工核对真实中断正是 2 次——**精确率 100% vs 10.5%**。

全语料实测（755 会话 / 674MB）：`interrupt` 277、`permission_denied` 90、
`permission_infra_fail` 6、`classifier_blocked` 1。判据细节与踩过的坑见
[spec §3.3](spec/trace-v1.md)。

### 2.3 commit ↔ session 接链（机制已实测）

`.githooks/prepare-commit-msg` 读**环境变量** `CLAUDE_CODE_SESSION_ID`
（实测逐字等于 transcript 文件名），注入 `Claude-Session:` trailer。

选环境变量而非状态文件，因为它是**进程级**的：多 worktree 并发各有各的值，
人工提交时变量根本不存在所以不会被误记成 agent 的。实测矩阵见 [spec §2.0](spec/trace-v1.md)：
最初五条（agent 提交带 / 人工不带 / amend 幂等 / worktree 生效 / 并发不串）加三轮审计补的六条
（agent rebase、cherry-pick 人工 commit 不沾 / 非编辑器路径 merge 可解析 / 已有 `Co-Authored-By`
等 trailer 保留 / 空消息仍被拒 / 编辑器路径不注入）全过。最初的 4 行版在补测的每一处都静默出错，
最重的一处：agent 一次 `git rebase main` 会把分支上所有人工 commit 记成 agent 的。

**trailer 活过历史重写**：rebase ✅ cherry-pick ✅ ff-only ✅ no-ff merge ✅；squash ❌——
`rebase -i` squash 只留最后一个被 squash 的 commit 的 trailer，`merge --squash` 原会话丢失、
记成执行者（agentDock 1760 个 commit 里 0 次 squash，不受影响）。

### 2.4 回归保护

`tools/test-extract.sh` 跑 24 条正负例，比对的是**整条输出**（含 `human` 与全部字段名），
不只比 kind——否则 `human` 翻转、`t`/`at`/`branch` 字段名漂移都抓不到（实测变异全绿）。
判据依赖英文消息串、Claude Code 改文案即静默失效，**这个测试是唯一的哨兵**。

它检查两件事：判定结果是否符合预期，**以及 jq 是否报错**。后者是补上去的——
jq 在某条规则上抛错时，该记录**之后的规则**不再求值、之前的命中照常输出，然后继续下一条。
所以只比对输出抓不到「末尾规则抛错」这类 bug：曾经的「去掉 `toolUseResult` 类型守卫」
就是这样——输出一条不差、只有 stderr 刷屏，比对恒绿（实测假绿）。退出码也靠不住：
jq 的退出码只反映**最后一条**输入是否出错。

## 3. 还缺什么

按我的判断排序，前两条是「不补就用不起来」。

### 3.1 🔴 查询端完全缺失

**这是最大的缺口。** 现在有了写入格式和提取器，但**没有任何「读」的工具**。
而留痕的全部目的是复盘，复盘时的实际动作是「给我看这个 commit 是怎么来的」——
现在得手工拼 `git log --format='%(trailers:...)'` 再 `jq` 翻 transcript。

至少要有：给 commit 反查会话与该会话的分歧点；给时间段出分歧汇总；
按 kind 统计趋势。**没有这一层，前面所有工作都只是把数据搬了个地方。**

### 3.2 🔴 session 流水的写入者未定义

[spec §3](spec/trace-v1.md) 定义了 `sessions/<sessionId>.jsonl` 的格式，
**但没说谁写、什么时候写**。§2 的 trailer 写入者已经解决（`prepare-commit-msg`），
**§3 这一半仍是空的**。

候选：Stop / SessionEnd hook 实时写，或事后 `sync` 命令批量生成。后者更简单且可重算
（它本就是 transcript 的投影），但需要有人记得跑。未定。

### 3.3 🟡 提取器会重复计数（已量化）

子 agent 与父会话的中断存在**传播重复**：一次人工打断同时记进两边。

实测 26 次子 agent 中断与父会话中断的时间差分布：

| 时间差 | 次数 |
|---|---|
| ≤2 秒 | 9 |
| 3-10 秒 | 4 |
| 11-60 秒 | **0（干净空档）** |
| >60 秒 | 13 |

空档说明分界清晰：**13 次是传播重复，13 次是子 agent 独有的独立事件**。
按 277 次中断算，多报 4.7%。

根因是**记录里没有「主会话 / 子 agent」这个维度**。子 agent transcript 内部的
`sessionId` 是**父会话的 id**（实测），所以归属正确，但分不出层级。
修法：记录增加 `isSidechain` 布尔与 `agentId`（transcript 里的现成字段；主会话记录上
`isSidechain` 为 false，子 agent 记录上为 true 且带 `agentId`），
去重按「同 sid + 同 kind + ≤10 秒」。

⚠️ 注意 `permission_denied` **不能同样去重**——子 agent 里有 53 次、比主会话的 39 次还多，
那是子 agent 的工具调用审批冒泡给人、每次都是独立的人工决定。
（⚠️ 53 + 39 = 92，与 §2.2 / spec §3.2 的 90 对不上，待在 agentDock 重数；不影响「不能去重」的结论。）

### 3.4 🟡 接入没有引导

`core.hooksPath` 要每人手动设一次（git 出于安全不允许仓库自动装 hook）、
`.githooks/` 要提交进仓、hook 要有可执行位、`.gitattributes` 要声明
`.claude/trace/**/*.jsonl merge=union`（否则并发审计记录一合并就冲突，见 spec §1.1）。
**任何一环漏了都是静默失效**——
实测 `.githooks` 未提交时 worktree 里 hook 不触发、trailer 为空且不报错。

推广给全体开发者必须有 bootstrap 脚本。这是 [DESIGN.md](DESIGN.md) 的 O7。

### 3.5 🟡 没有「痕真的留下了」的自检

承接上一条：漏装、装错、Claude Code 改了字段名——**所有失效形态都是静默的**。
需要一个 `doctor` 类命令回答「现在这个仓的留痕是否正常工作」：
hook 装没装、最近 N 个 commit 有几个带 trailer、提取器在最近会话上有无产出。

### 3.6 🟢 跨仓归属未定义

一个会话可以跨多个仓库——**本项目的开发会话就是反例**：`cwd` 恒为 agentDock
（1095 条记录全一样），产出的 commit 却全在 vibetrail。按现设计 session 文件
落在 agentDock、trailer 在 vibetrail 的 commit 上，**跨仓悬空指针**。

git-ai 同样把它列为已知局限（`Multi-repo root ⚠️`），业内没有现成解。
但我们连「记为已知」都还没做。

### 3.7 🟢 分歧记录含分支名

`diverge` 记录带 `branch`（事件发生时的分支名），不含文件路径。按 D2 只存索引不存正文的原则
它不算正文，但分支名本身可能带内部信息（客户名、项目代号），入仓即扩散。影响轻微，
需要时再定是否脱敏。
