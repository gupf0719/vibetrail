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
| 人机分歧判据 | ✅ 已实现，755 会话实测精确率 100% | `tools/diverge-rules.jq`（jq 模块）+ 入口 `tools/extract-diverge.jq`（调用要带 `-L tools`），规范 [spec/diverge-v1.md](spec/diverge-v1.md) |
| 判据回归 | ✅ | `tools/fixtures.jsonl` + `tools/test-extract.sh`（27 条正负例，比对整条输出并查 jq 报错） |
| 协议映射（分歧一路） | ✅ 2026-09-15 | `tools/lib/map.mjs`（含判据，D12 移植自 map-events.jq + diverge-rules.jq）+ `tools/vibetrail-map`（`event_id` UUIDv5、账本、只读到最后一个换行、按字节偏移从本轮开头读、回放副本不上报）；五类 kind → `permission.decision` / `turn.end(interrupted)` / `subagent.end(cancelled)`，带被拒调用的 `tool.request`、被打断的回复、之后人的下一句（含斜杠命令）；规则 [DESIGN §4.2](DESIGN.md) |
| 映射回归 | ✅ | `tools/test-map.sh`：11 份 fixtures（`tools/fixtures-map/`，golden 在 `expect/`）+ scenario 回放；断言 + golden + 每条过协议 schema（`tools/schema-check.py`，python3 + jsonschema，只在测试用）+ A2 对账（提取器命中按记录去重后 == 事件数）+ 每个切点的增量等价（从头读、从 checkpoint 读两路）+ 半行 + 幂等 + event_id 用 python 重算，246 项（09-17 数，含 K19 的 rule_version 摘要钉子、A11 计数、坏行占位、子 agent 文件与 workflow）；调用带 `--no-turns`，只钉分歧那部分；python 缺 jsonschema 时 schema 项跳过并在末尾说明 |
| 分歧一路挂 hook | ✅ 2026-09-15 | `tools/vibetrail-hook` + `tools/lib/hook.mjs`：Stop / SessionEnd / SessionStart 补做时读 transcript（09-16 起不挂 SubagentStop，子 agent 文件在 Stop 时一起读，D13），UserPromptSubmit 不读 transcript（U11）；scope 门控、会话锁、按 transcript 分文件的 state、spool 块文件、失败日志只留元数据；DESIGN §3.1、§3.3 |
| hook 分发入口：会话 / 轮次起止 | ✅ 2026-09-15，**09-16 只挂 5 个**（D13） | `tools/vibetrail-hook`（sh 包装）+ `tools/lib/hook.mjs`：SessionStart / UserPromptSubmit / Stop / SessionEnd / PermissionRequest——`session.start` / `session.end`、`turn.start`（HEAD / 分支 / 脏否）、`ext.claude.permission_request`（K7 的弹框证据）。原来的另外 8 个（SubagentStart / SubagentStop / PostToolUseFailure / Notification / PermissionDenied / StopFailure / InstructionsLoaded / CwdChanged）不再登记，旧条目调进来入口直接忽略；同步 hook 读完 stdin 就丢后台、约 0.02 s 退出；desktop 2.1.266 真实 payload 实跑过（09-15）；DESIGN §3.1、§4.1 |
| 轮次元数据：turn.end | ✅ 2026-09-15 | `tools/lib/map.mjs` 主会话按 promptId 切轮，**模型答完就发 `turn.end`**：Stop hook 先等 Claude Code 的答完标记 `stop_hook_summary` 落盘（config `stop_wait` 默认 10 s，本机实测它比最后一条回复晚 2～4 秒）再按它关轮，别的 Stop hook 拦下时不发、等模型补完再 Stop；等不到标记才按 Stop 当场关、被拦下后再 Stop 时补发一条 `vibetrail.stops` 更大的（D7、K24 09-16 改）；拒绝停下在拒绝处发；status completed / denied / hook_stopped / unknown / error（打断的由分歧一路发，打断没有 hook，要等下一个 hook；按停止打断正在跑的工具按弹没弹过权限框分成 `interrupt_tool` 与拒绝，D9）；用量按 message.id 去重、vcs 与 commits 取 hook 快照；与分歧同一条事件流，`vibetrail-map --no-turns` 只出分歧；DESIGN §4.1、§4.2 |
| 调用 trace | ✅ 2026-09-15 | `tools/lib/map.mjs` 的 trace 部分（rule_version `call-v2`，09-16 随 K19 升；四路版本号集中在 `RULE_VERSIONS`）：每次模型调用一条 `message.assistant`（content omitted，model、token、stop_reason、调了哪些工具、请求起止）、每次工具调用一条 `tool.end`（工具名、状态、耗时；09-16 起 `vibetrail.duration_kind` 标耗时是工具自报的 `reported` 还是记录时间差 `wall_clock`，K15②），子 agent 同样出；照 Pilot 的粒度、不带正文（D8） |
| 从 transcript 推原先靠 hook 的事件 | ✅ 2026-09-16（D13） | `tools/lib/map.mjs`，Stop 时与 trace 同一遍：`subagent.start`（子 agent 文件第一条记录；后台派出的看父会话里的 `isAsync` 启动结果）/ `subagent.end`（同步 agent 的调用结果带 status、耗时、token；后台的 `<task-notification>`，user 记录与 `queued_command` 附件两种形态）；API 出错结束的轮 `turn.end` 状态取 `isApiErrorMessage` 的 `error`；`ext.claude.instructions_loaded`（`attachment/instructions` 与 `nested_memory`，路径、sha256、字节数，全采时带正文）；`ext.claude.cwd_changed`（相邻记录的 cwd）。子 agent「写完了」看父会话里完成信号的时间（`state/<sid>/agents.json`）。09-16 第二批：workflow 起的 agent（K11，`subagents/workflows/<runId>/`，按 runId 挂回 Workflow 调用、journal 判完成、带 `vibetrail.workflow`）、被子 agent 派出的按 meta 的 toolUseId 认结束、子 agent 自己改读的文件进它的 `subagent.end.files[]` 并进那一轮；hook 先映射子 agent 文件、再映射主会话 |
| commit ↔ 轮次推导 | ✅ 2026-09-15 | `vt_git_snapshot` / `vt_commits`（`tools/vibetrail-lib.sh`）：轮起 / 轮止快照在 `state/<sid>/turns/`，本轮 commit = rev-list 起..止 + 本轮 reflog 里新建的提交；`GIT_OPTIONAL_LOCKS=0` 保证不写被观测仓的 `.git/index`；DESIGN §3.5 |
| 机器级安装 / 卸载 / 登记 | ✅ 2026-09-15 | `tools/vibetrail init / uninstall / projects / token`（09-16：init 在终端里引导填上报 token，存 `~/.vibetrail/token` 600、不回显；命令行包装先查 node ≥ 20）：运行时拷到 `~/.vibetrail/bin/`（MANIFEST 校验）、HOME settings 写 hook 条目（按命令认自家条目、改前备份）、config（scope、node 绝对路径、device_id）；只登记本机每个 Claude Code 都认识的事件（有错的 settings 会被整个跳过）；写 settings 前核对、写后自检、不对就还原，运行时在临时目录时不写真实 settings；init 不登记任何仓，`projects pick / add / remove [--drop]` 自己加减（--drop 挪出的待发数据留一天）；被观测仓零写入；DESIGN §5、D11 |
| 本地查看与自检 | ✅ 2026-09-15 | `vibetrail list`（spool 里的块）、`vibetrail show`（按会话、按时间一行一条，`--json` 原样）、`vibetrail doctor`（运行时 MANIFEST、node 与映射器探针、条目、全局开关、重复挂载、事件兼容、scope 与登记、积压、落后、错误日志、完整性汇总）；`show` 的 `subagent.end` 显示改 / 读了几个文件与 workflow；G9 的本地预览先由它承担 |
| hook 回归 | ✅ | `tools/test-hook-flow.sh`：scenario 在临时仓里真实回放，134 项（09-17 数）——未登记零写入、spool 里的分歧事件等于全量分歧映射、重复触发、锁、半行、回放副本、子 agent、文件重写与 offset 信任检查、补做别的会话、scope=user、压缩时重写的旧结果、连续调用的请求开始、init / uninstall 与 doctor 的写保护 / 全局开关 / 重复挂载、K7 分拒绝与按停止、退役的 hook 事件不做事 / API 重试 / origin.kind / 插话、项目级多仓与 projects pick、init 只登 5 个与清旧条目（第 18 段）、上报 token 与 node 版本（第 19、20 段）、K24 等答完标记（第 21 段）、嵌套与 workflow 子 agent / 子 agent 改的文件 / 扫描范围 / 完整性计数与 doctor / 路径不出本机 / 轮次成对与一轮多 commit / 同一次 hook 里 spool 块不互相覆盖（第 22 段）；python 缺 jsonschema 时 schema 项跳过并在末尾说明 |
| 沙箱演示 | ✅ 2026-09-15 | `experiments/collect-demo/demo.sh`：临时目录里 init → 按 scenario 回放（hook 用 settings 里写下的命令触发、第 1 轮中途真的提交一次）→ list / show / doctor → 核对零写入；不碰真实的 `~/.claude` 与 `~/.vibetrail` |
| hook 机制探针 | ✅ | `experiments/hook-probe.sh`（DESIGN §6.1 的实证来源） |
| 采集回放样本 | ✅ | `experiments/collect-demo/scenario.json`：同一段示例会话，Pilot / teamai 实跑样例就是用它截的；G7 的回归输入 |

### 待做（G7，拆解见 TODO）

| 功能 | 状态 | 形态 |
|---|---|---|
| 运行时移植到 Node 单文件 `.mjs`、去掉 jq | ✅ 2026-09-16（DESIGN D12） | 两个 ≤ 30 行的 sh 包装 + 每次 hook 一个 node 进程；`tools/lib/` 下 map / hook / cli / push / schema 五个 `.mjs`，只用内建模块、不构建；磁盘上的一切不变，golden 与 hook 回归原样验移植；移植期间 jq 版冻结只修 🔴；拆解见 TODO |
| push 之前对齐采集端协议 | ✅ 2026-09-16 | `project_id` 简单项目名（登记表 `projects add --name` > origin 仓库名 > 目录名）、`workspace_id` 第一次见到时生成并持久化在 `~/.vibetrail/workspaces/` 的 UUID、uninstall 留着（K17）；`tool.end` code succeeded / failed / cancelled、分类 `error` → `failure`（K18）；四路 `rule_version` 升到 v2 基线，test-map 钉着「输出变了没升版本就红」（K19）；Stop 时等答完标记落盘再关轮、拦停不提前发（K24，config `stop_wait` 默认 10 s）；用量 input 含缓存读、total = input + output、没给的不填（U12）。`vibetrail doctor` 报本仓的两个标识；清单见 DESIGN §4.1「协议文档里 schema 管不到的规矩」。本机 11 个会话 5,536 条事件重映射全部过 schema |
| 全采与协议补齐 | ✅ 2026-09-16 | 排队的人话全采时发 `message.user`（delivery queued，K20）、按停止打断工具补 `tool.end(cancelled)`（K21）、`turn.end.files[]`（Edit / Write / Read 成功的结果，相对主 checkout 或 worktree 根，根外只计数，K22）、关掉全采时 `subagent.start` 不带 `task`（K23）；回归在 test-map 第 9 节、test-hook-flow 第 14 / 16 / 17 / 21 节。K11（workflow 子 agent 的目录）仍等样本 |
| `vibetrail push [--list \| --show]` | ❌ 用户 09-15 定往后放；09-16 定在 D12 移植之后用 JS 写 | token 从 `~/.vibetrail/token` 读（09-16 init 已引导填）；门槛默认值待定（U17）；端点没配不发；配了按协议打批、每条过 schema、`event_id` 幂等、ack 即删、门槛与退避（D6）；DESIGN §4。本地看待发内容现在用 `vibetrail list / show` |
| doctor 余项 | 🔁 | 已做的见上表；还缺最近会话的 `stop_hook_summary` 里有没有跑过我们的命令（未知记录类型 / 附件类型 09-16 第二批随完整性计数做了） |
| 完整性钉子 | ✅ 运行时部分 2026-09-16 第二批 | 映射账本 `new` 计数 → `state/<sid>/integrity.json` 按文件累计 → doctor 汇总（恒等式、坏行、判据没认出的拒绝标记、不认识的类型、超 1 MiB 去正文、50 MB 截断）；扫描范围由 test-hook-flow 第 22 节钉住（G10）；还缺服务端拒收的计数（随 push） |
| 补充回归场景 | 🔁 | 09-17 test-hook-flow 第 22 节补了轮次成对与 status、一轮多 commit、嵌套与 workflow 子 agent；后台子 agent 晚于父 Stop 09-16 由第 7 段钉住；还缺端点未配置 / 配置后断网（随 push） |

### 退役（2026-09-14，D4；2026-09-15 代码归档到 `old/`，见 `old/README.md`）

| 功能 | 原实现 | 为什么退 |
|---|---|---|
| 每个 clone 接入 | `old/vibetrail-install`：装 git hook、vendor 运行时到 `.claude/vibetrail/`、写 `.gitattributes`、建 `.claude/trace/` | 被观测仓零写入；机器级装一次 |
| commit ↔ session 的 `Claude-Session` trailer | `old/prepare-commit-msg` + `old/test-hook.sh`（12 场景回归 + 5 组变异） | 不装 git hook；改从每轮起止 HEAD 推（DESIGN §3.5）。同一个 hook 还写审计线的 `Vibetrail-Id`，见下 |
| 会话流水投影进仓 | `old/vibetrail-sync`（按 worktree 清单认领会话、整份重生成） | 两路数据不进 git；它的归属判据（`git worktree list` + realpath）沿用到 hook 的门控 |
| 仓内 vendor 运行时与 MANIFEST | `vibetrail-install` 的一部分 | 运行时只在 `~/.vibetrail/bin/` 一份 |

### 另一条线：审计记录（不属 G7）

| 功能 | 状态 | 实现 |
|---|---|---|
| 审计过程留痕 | ✅ | `old/vibetrail-audit`（record / show / stats / check），写 `<repo>/.claude/trace/audits/<vibetrailId>.jsonl`，格式 [spec/trace-v1.md](spec/trace-v1.md) |
| 审计回归 | ✅ | `old/test-audit.sh` |
| 闸门故障注入套件 | ✅ | `old/test-faults.sh`：每条注入一个故障，断言闸门 / 自检必须 fail-closed（vendored 运行时缺失、丢 +x、缺 jq、`merge=union`、doctor 假绿等）。它依赖 `vibetrail-install` 的 vendor 与 MANIFEST，所以这两样随审计线一起等 U6，不随 G7 退役 |
| Stop 闸门 | ✅ | `old/fixtures/check-audit-stop.sh`（agentDock 的三个 Stop hook 之一）：缺记录 block，空锚放行 |
| 锚 | ✅ | `Vibetrail-Id` trailer，由 `old/prepare-commit-msg` 写——**这条线仍依赖 git hook、仍落在被观测仓里**，去向暂不定（OPEN-ISSUES U6） |
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

`tools/test-extract.sh` 跑 27 条正负例，比对的是**整条输出**（含 `human` 与全部字段名），不只比 kind——否则 `human` 翻转、字段名漂移都抓不到
（实测变异全绿）。判据依赖英文消息串、Claude Code 改文案即静默失效，**这个测试是唯一的哨兵**。

它检查两件事：判定结果是否符合预期，**以及 jq 是否报错**。后者是补上去的——jq 在某条规则上抛错时，该记录之后的规则不再求值、之前的命中照常输出，
然后继续下一条。只比对输出抓不到「末尾规则抛错」这类 bug（实测假绿）；退出码也靠不住，jq 的退出码只反映最后一条输入是否出错。

⚠️ 一条方法论教训：第一次用 `grep -c 'userModified'` 数 SpecStory 的保真度，得到「9 处命中」——假阳，命中的是自己命令里打过的字面量。
换成「真做一次 Edit 再抽整段看」才得到真答案。断言选在不承重的维度上，等于没测。

### 2.3 采集回放样本

`experiments/collect-demo/scenario.json` 是一段编出来的示例会话的回放脚本，25 步：三轮对话、一次 Edit、一次被拒的 Bash、一次输出里带假密钥的 Bash、
一次打断；没有子 agent。Pilot 与 teamai 的实跑样例
（[third-party/](third-party/)）就是拿它喂出来的，同一份输入三家对比。映射层的回归已用它（`test-map.sh` 第 1 段：1 条拒绝 + 被拒命令 + 人的纠正）；
hook 层的回归要在它上面补：SessionStart 补做、打断后无 Stop、后台子 agent 晚于父 Stop、一轮多 commit、端点未配置 / 配置后断网。

### 2.4 协议映射

`tools/lib/map.mjs` 把一份 transcript（主会话或子 agent 文件）一次读完，只对新的触发记录发协议 1.0 事件：`permission_denied` /
`classifier_blocked` / `permission_infra_fail` → `permission.decision`（decided_by user / policy / system），并按 `tool_use_id` 反查被拒调用发
`tool.request`；`interrupt` → `turn.end(interrupted)`（子 agent 文件里 → `subagent.end(cancelled)`），沿 `parentUuid` 回溯到被打断的回复发
`message.assistant` / `tool.request`；分歧之后人的下一句发 `message.user`。`interrupt_for_tool_use` 吸收进同一轮的拒绝、不另发。
`tools/vibetrail-map` 包一层：从路径推 sid 与 meta、只读到最后一个换行、算 UUIDv5 的 `event_id`、出账本（进出条数、反查来路、消费到的行号与字节）。

几条经验：① `emit(base(…) | .payload = …)` 里管道之后的 `.` 已经是事件不是状态——状态里的值先绑成变量再用，第一次跑真语料就在这里炸；
同一个坑的另一面：`$r | slim(.ln)` 里的 `.ln` 是 `$r.ln`，第一版所有行号都是 null，断链兜底从未生效，fixtures 的链都完整所以没测出来。
② 同一个 `tool_use` 会被两次分歧各派生一次（拒绝之后紧接打断），去重必须**不看门控**登记，否则分段扫比全量扫多一条——
fixtures 里没有这个形态时变异测试恒绿，是 106 MB 真语料照出来的，补了 `denied-then-interrupt`。
③ fixtures 全绿不等于真语料对：「从本轮开头读」在 fixtures 上等价，放到 43 个真会话上有 1 个不一致，查出来是回放副本（DESIGN §4.2）。
④ 对照三方时先量再学：两家的 50 MB 上限都会丢分歧、不学；「时间戳倒退就算副本」看着省事，量下来会误伤 63 条真实记录、不用。

## 3. 还缺什么

**见 [OPEN-ISSUES.md §C 中心表](OPEN-ISSUES.md)**，那里是唯一的未完成项清单。新增未完成项只写进中心表。
