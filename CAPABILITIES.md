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

全语料实测（**2026-09-09 重测**，756 个 transcript）：`interrupt` 282、
`permission_denied` 92（主会话 39 + 子 agent 53）、`permission_infra_fail` 6、
`classifier_blocked` 1。

⚠️ 09-08 测得 277 / 90，差异**全部来自语料增长**（我们工作时它一直在写）。
**引用需带测量日期。**判据细节与踩过的坑见
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

**见 [OPEN-ISSUES.md §C 中心表](OPEN-ISSUES.md)**，那里是唯一的未完成项清单，
按类型（功能缺口 / 已知缺陷 / 待定决策 / 未量）与优先级排列，带关闭记录。

本节此前重复描述过其中若干项，已删——三份文档各记一份同样的开放状态，
是「必须与 X 保持一致」那类必然会漂的拷贝。**新增未完成项请只写进中心表。**
