# vibetrail 功能与状态

> 分工：[DESIGN.md](DESIGN.md) 记**为什么与怎么做**；本文记**有什么、什么状态、沿用部分怎么实现的**；
> [spec/diverge-v1.md](spec/diverge-v1.md) 是判据规范；未完成项只在 [OPEN-ISSUES.md](OPEN-ISSUES.md)，拆解在 [TODO.md](TODO.md)。
> 2026-09-14 重整：上一版的接入 / 提交 / 投影 / 读取五段流程随 D4 退役，本文按「沿用 / 待做 / 退役 / 另一条线」四栏重排。

## 0. 一句话

用 Claude Code 的 hook，把每个会话的两路数据自动传上云——**人机分歧**（打断、拒绝，带最小正文）和**轮次元数据**（会话 / 轮次 / 子 agent 起止、
每轮起止的 HEAD 与 commit、状态，不带正文）——映射成 paas-coding-hook 事件协议 1.0，不传 transcript 原文件（DESIGN D5）。用来回答**这个 commit 是怎么来的**，以及**出问题时人和 agent 在哪一步对不上**。

## 1. 功能清单

### 沿用

| 功能 | 状态 | 实现 |
|---|---|---|
| 人机分歧判据 | ✅ 已实现，755 会话实测精确率 100% | `tools/extract-diverge.jq`，规范 [spec/diverge-v1.md](spec/diverge-v1.md) |
| 判据回归 | ✅ | `tools/fixtures.jsonl` + `tools/test-extract.sh`（26 条正负例，比对整条输出并查 jq 报错） |
| hook 机制探针 | ✅ | `experiments/hook-probe.sh`（DESIGN §6.1 的实证来源） |
| 采集回放样本 | ✅ | `experiments/collect-demo/scenario.json`：同一段示例会话，Pilot / teamai 实跑样例就是用它截的；G7 的回归输入 |

### 待做（G7，拆解见 TODO）

| 功能 | 状态 | 形态 |
|---|---|---|
| `vibetrail init` / `uninstall` | ❌ | 机器级装一次：`~/.vibetrail/bin`、HOME settings 条目（带 marker）、scope 配置、登记；DESIGN §5 |
| hook 分发入口 `vibetrail-hook <事件>` | ❌ | 读 stdin、按 scope 门控、发 session / turn / subagent 起止事件与 `ext.claude.*` 事件头，写 `events.jsonl`；DESIGN §3.1、§4.1 |
| 增量解析 | ❌ | 每个 transcript 文件一个 byte offset、截到最后一个换行、子 agent 按目录扫、原子写；不复制文件；DESIGN §3.3 |
| 分歧提取挂 hook + 协议映射 | ❌ | 现有 jq 在 UserPromptSubmit / Stop / SessionEnd / SessionStart 补做时跑；命中映射成 `permission.decision` / `turn.end(interrupted)` / `subagent.end(cancelled)`，`tool_name` / `input` 按 `tool_use_id` 反查（G5）；DESIGN §4.1 |
| commit ↔ session 推导 | ❌ | 每轮起止 HEAD + `rev-list`；DESIGN §3.5 |
| `vibetrail push [--list \| --show]` | ❌ | 端点没配不发；配了按协议打批、每条过 schema、`event_id` 幂等、ack 即删；DESIGN §4 |
| doctor 扩展 | 🔁 | 现有 `tools/vibetrail-doctor` 查的是退役的 git hook 与仓内 vendor，要改成 DESIGN §5 的自检项 |
| 本地预览 | 🔁 | 现有 `tools/vibetrail`（show / log / session / diverge）读仓内 `sessions/` 与 `Claude-Session` trailer，两者都退役；只留 push 前预览（`push --list / --show`），读取与分析不归本项目（D5） |
| 完整性钉子 | ❌ | 每类记录条数进出相等、映射后事件全部过 schema、超 1 MiB 被拒计数、未知类型 / 事件名告警（G10、G6） |

### 退役（2026-09-14，D4；代码在 G7 落地时删）

| 功能 | 原实现 | 为什么退 |
|---|---|---|
| 每个 clone 接入 | `tools/vibetrail-install`：装 git hook、vendor 运行时到 `.claude/vibetrail/`、写 `.gitattributes`、建 `.claude/trace/` | 被观测仓零写入；机器级装一次 |
| commit ↔ session 的 `Claude-Session` trailer | `tools/prepare-commit-msg` + `tools/test-hook.sh`（12 场景回归 + 5 组变异） | 不装 git hook；改从每轮起止 HEAD 推（DESIGN §3.5）。同一个 hook 还写审计线的 `Vibetrail-Id`，见下 |
| 会话流水投影进仓 | `tools/vibetrail-sync`（按 worktree 清单认领会话、整份重生成） | 两路数据不进 git；它的归属判据（`git worktree list` + realpath）沿用到 hook 的门控 |
| 仓内 vendor 运行时与 MANIFEST | `vibetrail-install` 的一部分 | 运行时只在 `~/.vibetrail/bin/` 一份 |

### 另一条线：审计记录（不属 G7）

| 功能 | 状态 | 实现 |
|---|---|---|
| 审计过程留痕 | ✅ | `tools/vibetrail-audit`（record / show / stats / check），写 `<repo>/.claude/trace/audits/<vibetrailId>.jsonl`，格式 [spec/trace-v1.md](spec/trace-v1.md) |
| 审计回归 | ✅ | `tools/test-audit.sh` |
| 闸门故障注入套件 | ✅ | `tools/test-faults.sh`：每条注入一个故障，断言闸门 / 自检必须 fail-closed（vendored 运行时缺失、丢 +x、缺 jq、`merge=union`、doctor 假绿等）。它依赖 `vibetrail-install` 的 vendor 与 MANIFEST，所以这两样随审计线一起等 U6，不随 G7 退役 |
| Stop 闸门 | ✅ | `tools/fixtures/check-audit-stop.sh`（agentDock 的三个 Stop hook 之一）：缺记录 block，空锚放行 |
| 锚 | ✅ | `Vibetrail-Id` trailer，由 `tools/prepare-commit-msg` 写——**这条线仍依赖 git hook、仍落在被观测仓里**，去向暂不定（OPEN-ISSUES U6） |
| 行级归属 | ❌ 已否决 | DESIGN §7 |

## 2. 沿用部分的实现原理

### 2.1 人机分歧提取

从 transcript 提取 5 类事件，每条带 `human` 布尔区分「人的决定」与「机器 / 基础设施行为」。判据的精确定义**只在
[spec/diverge-v1.md §2](spec/diverge-v1.md) 维护一份**，这里不复述，避免两份漂移（曾经漂过：这里的版本漏了字符串正文与 `with this tool use`）。

**核心原理是「只读字段，不 grep 原文」**。会话自身会讨论这些标记（本项目的调研会话就是），grep 原文会把「讨论」当成「发生」。
实测对照：以本项目调研会话为靶，裸 grep 命中 19 条、本规则命中 2 条，人工核对真实中断正是 2 次——精确率 100% vs 10.5%。

全语料实测（2026-09-09，756 个 transcript）：`interrupt` 248、`interrupt_for_tool_use` 35、`permission_denied` 92（主会话 39 + 子 agent 53）、
`permission_infra_fail` 6、`classifier_blocked` 1。09-08 测得 277 / 90，差异全部来自语料增长——**引用需带测量日期**。

### 2.2 回归保护

`tools/test-extract.sh` 跑 26 条正负例，比对的是**整条输出**（含 `human` 与全部字段名），不只比 kind——否则 `human` 翻转、字段名漂移都抓不到
（实测变异全绿）。判据依赖英文消息串、Claude Code 改文案即静默失效，**这个测试是唯一的哨兵**。

它检查两件事：判定结果是否符合预期，**以及 jq 是否报错**。后者是补上去的——jq 在某条规则上抛错时，该记录之后的规则不再求值、之前的命中照常输出，
然后继续下一条。只比对输出抓不到「末尾规则抛错」这类 bug（实测假绿）；退出码也靠不住，jq 的退出码只反映最后一条输入是否出错。

⚠️ 一条方法论教训：第一次用 `grep -c 'userModified'` 数 SpecStory 的保真度，得到「9 处命中」——假阳，命中的是自己命令里打过的字面量。
换成「真做一次 Edit 再抽整段看」才得到真答案。断言选在不承重的维度上，等于没测。

### 2.3 采集回放样本

`experiments/collect-demo/scenario.json` 是一段编出来的示例会话的回放脚本，25 步：三轮对话、一次 Edit、一次被拒的 Bash、一次输出里带假密钥的 Bash、
一次打断；没有子 agent。Pilot 与 teamai 的实跑样例
（[third-party/](third-party/)）就是拿它喂出来的，同一份输入三家对比。G7 的回归要在它上面补：SessionStart 补做、打断后无 Stop、后台子 agent
晚于父 Stop、一轮多 commit、端点未配置 / 配置后断网。

## 3. 还缺什么

**见 [OPEN-ISSUES.md §C 中心表](OPEN-ISSUES.md)**，那里是唯一的未完成项清单。新增未完成项只写进中心表。
