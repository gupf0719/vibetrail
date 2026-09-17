# 待办：已有方案、尚未开工的需求

> 与 [OPEN-ISSUES.md](OPEN-ISSUES.md) 的分工：OPEN-ISSUES §C 中心表仍是**唯一的未完成项清单**，
> 每条的一句话与状态只记在那里；本文记其中**已经有方案、还没开工**的需求的细节——
> 需求原话、方案、验证、限制、拆解。做完一条就删掉它的小节，并在中心表关闭对应 ID。

## G7 hook 采两路数据：人机分歧（带正文）+ 轮次元数据（当前先做）

需求与设计 2026-09-14 定稿、09-15 D5 修正采什么与去哪，全文在 [DESIGN.md](DESIGN.md)（用户原话 §0、采什么 §2、怎么采 §3、去哪与映射 §4、安装 §5、验收 §9）；
未定项只在 [OPEN-ISSUES.md](OPEN-ISSUES.md) U1、U2、U4–U9。本节只留拆解，做完一条勾一条；全部做完删掉本节并在中心表关 G7。

### 拆解

- [x] 定 U1 默认 scope：可配，默认 `project`（用户 09-15）。U4 只剩端点与 token，可以最晚定：端点没配之前 push 不发。服务端 schema 已进仓：`third-party/collection-batch-1.0.schema.json`。
  默认值：`client.name` 照填 `paas-coding-hook`，`policy_version` 填 `none-0`（DESIGN §4.1）。
> **09-15 用户定的顺序**：「push，回归这些都先不急着做，先把hook分发入口，轮次元数据采集和安装这些做了」「让我可以先演示安装，采集以及在本地文件看一下采集了哪些东西」；
> 「两个数据以后推的接口是一个，可以不用特意分的特别开」——分歧与轮次元数据是同一条事件流，代码里只按来源分（hook 当场给的 / 解析 transcript 得出的）。
> 同日做完下面前四项，演示见 README「演示」一节与 `experiments/collect-demo/demo.sh`。

- [x] 机器级安装（09-15）：`tools/vibetrail init [--scope project|user] [--no-register] [--events auto|core|all]`——`~/.vibetrail/bin`（MANIFEST）+ HOME settings 条目
  （按命令里的 `vibetrail-hook` 认，改前备份）+ `config`（scope、jq 绝对路径、device_id、turn_idle_close、push 两个门槛）+ 登记本仓（09-16 起 init 不再登记，`projects pick / add` 自己加）；`uninstall [--purge]`；`projects`；
  `doctor`（运行时、jq、条目、事件兼容、scope 与登记、积压、落后、错误日志）。**只登记本机每个 Claude Code 都认识的事件**：有错的 settings 会被整个跳过（DESIGN §5）。
  被观测仓零写入（A8）：demo.sh 与 desktop 实跑都核过。doctor 还缺 `stop_hook_summary` 证据与未知类型告警（随完整性钉子）。
- [x] hook 分发入口（09-15）：`vibetrail-hook` 接 12 个事件（09-15 加 PermissionRequest 成 13 个），发 session / turn.start / subagent 起止与 `ext.claude.*` 事件头，git 状态（`vt_git_snapshot`），
  事件构造在 `tools/hook-events.jq`；同步 hook 读完 stdin 就丢后台、约 0.02 s 退出。desktop 2.1.266 上用项目级 settings.local.json 挂到沙箱实跑：
  PostToolUseFailure、SubagentStart / SubagentStop、Stop 的真实 payload 都正确落盘（agent.version 取 `AI_AGENT`、`parent_call_id` 取 meta.json）。
- [x] 分歧一路第 1 步——提取器扩展与协议映射（09-15）：判据拆成 `diverge-rules.jq` 模块、命中多带 `call_id`；`map-events.jq` + `vibetrail-map` 把五类 kind 映射成
  `permission.decision` / `turn.end(interrupted)` / `subagent.end(cancelled)`，`tool_name` / `input` 按 `tool_use_id` 反查（G5 关），带被打断的回复与之后人的下一句，
  `event_id` UUIDv5；`test-map.sh` 8 份 fixtures + scenario 回放 + schema + A2 对账 + 每个切点增量等价，89 项全绿。细则 DESIGN §4.2。
- [x] 第 1 步补强（09-15，对照 Pilot / teamai 后改，不照搬）：从本轮开头读（`--start-line` / `--start-byte`，账本给 `checkpoint_line` / `checkpoint_byte`，U11 定）；
  回放副本不上报（本次读取内按 uuid、跨次按 `[uuid, 行号]` 清单 `--seen-uuids` / `--sources-out`）；嵌套子 agent 的父实例查兄弟文件；斜杠命令算人的动作；
  越过合成记录；缺 message.id 退到 requestId；字段哨兵；修掉行号全是 null 的错；命名空间常量改成真正的 uuid5(NS_URL, "vibetrail")。
  `test-map.sh` 11 份 fixtures 139 项全绿；本机 44 个主会话各三个切点实跑与全量一致，750 条事件全过 schema。
- [x] 分歧一路第 2 步——挂 hook（09-15）：`tools/vibetrail-hook`（共用函数 `tools/vibetrail-lib.sh`）在 Stop / SubagentStop / SessionEnd / SessionStart 补做时
  调 `vibetrail-map`，**不挂 UserPromptSubmit**（U11）；state 按 transcript 分文件记 checkpoint 与 `[uuid, 行号]` 清单，会话级记已发 event_id；会话锁、已在跑就跳过；
  Stop 先等 transcript 写稳；文件变短时清 state 从 0 重读；子 agent 按 `<sid>/subagents/` 目录扫；spool 改成块文件（DESIGN §3.3）。
  回归 `tools/test-hook-flow.sh` 21 项：scenario 回放 + 未登记零写入、重复触发、锁、半行、回放副本、子 agent、重写、补做别的会话、scope=user；
  两个变异（去掉会话锁、ids 去重换回 `NR == FNR`）都被抓到。
- [x] 借鉴开源调研（09-15，[third-party/open-source-survey.md](third-party/open-source-survey.md)，不照抄）：
  - [x] 人话排除清单补「This session is being continued」「Stop hook feedback:」两类前缀，IDE 标签只剥不整条排除（照 agentsview）；本机语料上的条数没量成（命令被拦），下个会话补
  - [x] 同一 message.id 的用量留 output 大的那份（照 ccusage）；本机同一 id 用量全部一致，纯防御
  - [x] 对照时查出的真问题：被打断的回复只取了最近一条记录，按 message.id 拼回整条，快照留完整的、真多段接起来（两家都会丢段，DESIGN §4.2）；回复 22 → 97 条
  - [x] offset 信任检查：state 记「inode : 开头 4 KB : 消费位置前 4 KB」指纹，对不上从 0 重读、`rewrites` 计次（照 agentsview 的思路、不哈希整个前缀）；
    `test-hook-flow.sh` 25 项，含换 inode、原地改开头、什么都没变三个场景，去掉哈希的变异被抓到
  - push 的退避与永久失败记账随 push 一项做（D6 已写进 DESIGN §4）。
- [x] 轮次元数据（09-15）：`turn.start`（hook 当场发；hook 没跑的轮由映射层按 promptId 补位）、`turn.end`（映射层按 promptId 切轮，**模型答完就发**：
  Stop hook 当场关轮，被别的 Stop hook 拦下后再 Stop 时补发一条 `stops` 更大的（Claude Code 的答完标记 `stop_hook_summary` desktop 要等下一句人话才落盘，09-15 真实环境实测，不能等它）；拒绝停下在拒绝处发；打断的由分歧一路发（打断没有 hook，desktop 实测按停止什么 hook 都不来，要等下一个 hook）；
  没有标记的退到下一轮开始 / 会话结束 / 空闲补做，补做扫所有登记的仓）、`InstructionsLoaded` 只记路径、sha256、字节数。上午第一版是「等轮确定结束才发」，
  用户指出「如果用户隔了很久才问新问题，那最后一个turn你会一直不push」「排查的时候就会缺失最后一个turn」，下午先改成认 stop_hook_summary，
  装到真实环境后发现它晚一轮才落盘，再改成 Stop 时当场关（DESIGN D7）。演示用的 markdown 报告 `experiments/collect-demo/report.sh`（三块：轮次元数据 / 人机分歧 / commit ↔ 会话，上线用不到）。
  hook 的 prompt_id 与记录的 promptId 是同一个值（探针实测）。本机 10 份真 transcript 30 个切点增量等价逐条一致；demo.sh 加了一轮「第一次 Stop 被拦、补完再 Stop」。
  09-15 请用户按停止实测：没有任何 hook、没有 `idle_prompt`；按停止打断正在跑的工具被记成拒绝（OPEN-ISSUES K7，区分方案待定）。
- [x] 调用 trace（09-15，用户：「trace是不是没采，genai那些」「参考下pilot，它全采了」）：每次模型调用、每次工具调用各一条，照 Pilot 的粒度、不带正文（DESIGN D8）；
  演示报告第一块下面有每个会话的调用明细。
  重采后核出 5 处（重写副本、连续调用的开始时间、工具结果夹在调用中间、子 agent 读到半截、起读行越过未写出的调用），逐条对照 Pilot 与 teamai 后修掉（DESIGN D8 表）。
- [x] settings 备份照 Pilot 改（09-15，用户问「backup的目的是啥」）：没变化不写、写前核对没被别人改过、装之前的原样只存一次永不覆盖。
- [x] 项目级选项目（09-16，用户：「init后好像没选项目」「一个项目都不会加，等用户自己add」）：init 不登记也不问，只列出登记表与用过 Claude Code 的仓；
  `projects pick` 选（编号前加 - 去掉）、`projects remove --drop` 连待发数据挪出 spool（留一天，用户：「不要7天，一天吧」）；
  补采按各自的仓记（登记两个仓会记错，加多选时查出）；写 settings 两道保险——临时运行时写真实 settings 拒绝、写完自检不对就还原（DESIGN D11）。
- [x] commit ↔ 轮次推导（09-15）：轮起 / 轮止快照（`state/<sid>/turns/`），本轮 commit = `rev-list 起..止` + 本轮 reflog 里新建的提交，归因看 transcript 里 agent 有没有跑
  `git commit`（DESIGN §3.5）；demo.sh 第 1 轮中途真的提交一次，turn.end 带上了。原写的「`vibetrail show` 按 commit 查改走它」不做了：按 commit 查是读取端的事（D5），
  现在的 `vibetrail show` 是本地预览。Bash stdout 里短 sha 的旁证还没做。
- [x] **init 引导填上报 token、使用前的准备**（2026-09-16，用户「Init要引导用户填token」「项目使用的文档提示一下使用前的准备，比如node版本这些」）：token 存 `~/.vibetrail/token`（600），
  终端里跑 init 没填过就问一次（不回显，回车 / Ctrl-C 跳过），`vibetrail token [--status | --clear]`，doctor 报填没填、权限过宽告警；DEMO §0 列 node ≥ 20、git、Claude Code 版本、系统、hook 开关、token、演示与测试另要的 jq / python3；
  命令行 sh 包装先查 node 版本。顺手修 `projects pick` 在终端里敲回车不返回（原先读到 EOF）。pty 回归在 test-hook-flow 第 19、20 段。
- [x] **只挂 5 个 hook**（2026-09-16，DESIGN D13，关 OPEN-ISSUES U16、K15②）：SessionStart / UserPromptSubmit / Stop / SessionEnd / PermissionRequest；子 agent 起止（同步的调用结果、后台的启动结果与 `<task-notification>`）、API 出错结束的轮、
  CLAUDE.md 加载、切目录改在 Stop 时从 transcript 推，子 agent「写完了」看父会话里完成信号的时间（`state/<sid>/agents.json`）；`tool.end` 标耗时来源。init 只登 5 个、清旧条目，doctor 点名还挂着的旧事件；
  test-map 198 项、test-hook-flow 94 项、test-extract 27 项全绿，五处变异各自变红。
- [x] **运行时换成 Node 单文件 `.mjs`、去掉 jq**（2026-09-16 移植完毕：①`0bb521b` ②`b3985be` ③`e404b67` ④`aeda56b`；test-map / test-hook-flow / test-extract 全绿，12 份真实 transcript 7 万条事件两引擎逐条一致，106 MB 那份 63 s → 21 s）（用户 09-16 定：「node硬依赖问题不大，把jq全换成mjs吧」；DESIGN D12；换语言不换设计，磁盘上的一切不变）。
  **jq 版从此冻结**：只修 🔴，别的会话别再往 `.jq` 里加东西。估两到三天。
  1. 布局：`tools/vibetrail-hook`、`tools/vibetrail` 各留一个 ≤ 30 行的 POSIX sh 包装（读 config 的 `node=`，`exec node vibetrail.mjs …`；找不到 node 也 exit 0、只记 errors.log）；
     `tools/vibetrail.mjs` 入口按 argv 分发 hook / cli / push；`tools/lib/` 下 `map.mjs`（原 map-events.jq + diverge-rules.jq + hook-events.jq）、`hook.mjs`（原 vibetrail-hook + vibetrail-lib.sh + vibetrail-map）、
     `cli.mjs`（原 vibetrail）、`push.mjs`（新）、`schema.mjs`（手写结构校验，约 150 行）。ESM 相对 import，不构建、不引 npm 包，只用 fs / path / crypto / child_process / fetch，node ≥ 20。
     settings 里的命令改成 `sh '<路径>/vibetrail-hook' <事件> 2>/dev/null || true`（K16 一并做），`settings_ok` / doctor 的命令解析同步改。
  2. 顺序与验收（每步单独提交，移植与修补分开）：
     ① map 模块 1:1 移植：test-map 158 项全绿，golden 按键排序逐字节相同；再拿本机真实语料对拍——同一批 transcript 新旧两版跑出的 event_id 集合与每条事件（去掉 `occurred_at` 取 now 的 hook 事件）相同。
        每条记录一个 try/catch，坏记录只丢自己、账本计数；jq 的 `test(…; "m")` 对应 JS 正则的 `s` 标志，多态字段照样先判类型。
     ② hook 入口 + 共用函数：同步 hook 读完 stdin `spawn` detached 子进程（`stdio: 'ignore'`、`unref()`）再退出；git 用 `execFileSync` 带 `timeout: 3000` 与 `GIT_OPTIONAL_LOCKS=0`；
        会话锁、state、spool 块、UUIDv5（`crypto`）逐一对应。test-hook-flow 70 项全绿、demo.sh 跑通、被观测仓零写入照旧。
     ③ CLI：init 改记 `node=`（config 里的优先、其次 PATH、再 nvm / volta / brew 的常见路径，记绝对路径，像现在找 jq）；doctor 探针从「jq 跑映射器」换成「node ≥ 20 且能 import map.mjs」，
        并查 config 里的 node 路径还在不在（nvm 升级后会失效，提示重跑 init）；VERSION 记 node 版本；MANIFEST 列全部 .mjs。第 13、16 段全绿。
     ④ 老文件归档到 `old/jq/`；README、DESIGN §5.3、CAPABILITIES、DEMO 的 jq 说法同步改；本机 `~/.vibetrail` 重跑 init 后 doctor 全绿、再跑一轮真实会话看 spool 照常长。
     ⑤ 之后才在 JS 里做下面「09-16 复核核出的修补」，再写 push。
  3. 测试：第一步 bash 回归脚本不动，只把被测程序换掉（断言处的 jq 只在开发机用，运行时不再依赖 jq）；第二步换 `node:test`。fixtures / golden / scenario.json 原样沿用。
  4. 风险要盯：行为漂移（靠 golden 与 hook 回归兜）；同步 hook 从 20 ms 变 70～135 ms；desktop 启动的 hook 没有 PATH（包装只用 config 里的绝对路径）；两套并存期间别的会话往 jq 里加东西（冻结）。
- [x] **09-16 复核核出的修补**（2026-09-16：K8 / K12 / K13 `51f8716`，K14 / K15①③ / K16 `4235fca`，K15④⑤ `bbca2fd` / `296a08d`，K15② 与 U16 随 D13 `0d4fa7d`；各带回归，全部关闭）（本机 124,666 条真实事件 + teamai / Pilot 源码对照，见 OPEN-ISSUES；都小，**移植完在 JS 里做**，顺序按影响排）：
  K8 复制历史按记录 `sessionId` 跳过（🔴，7.6% 的事件在复制的轮上、trace 翻倍）→ K13 打断的 turn.end 补 `closed_by` / `stops`、打断后置 closed →
  K12 只在人话 / 斜杠命令处开轮或打 `turn_kind` → K15 ①③（capabilities 加 `tool.end`、state 目录清理）→ K14 uninstall 留 ids → K16 命令串 `2>/dev/null || true` 与 stdin 超时。
  每条各补一个回归用例（见下面「回归」）。U16 用户 09-16 定只挂 5 个 hook（D13）。
- [x] **push 之前先对齐采集端协议**（2026-09-16 核出、同日改完，`a34bbf5`；详见 OPEN-ISSUES 各条与 DESIGN §4.1 的表）：
  1. K17：`project_id` = 登记表 `projects add --name` > origin 仓库名 > 主 checkout 目录名；`workspace_id` = 第一次见到时生成、持久化在 `~/.vibetrail/workspaces/` 的 UUID，按主 checkout 一个（worktree 共享），uninstall 留着；doctor 报两个标识。
  2. K18：分类 `error` → `failure`，`tool.end` 的 code `succeeded` / `failed` / `cancelled`；来源自己的状态留在 code。goldens 与断言改了。
  3. U12：input 含缓存创建与缓存读、cached 是 input 的子集、total = input + output、来源没给的字段不填；`show` 与报告列成「入（其中缓存）/ 出」。
  4. K24：Stop 时先等答完标记或拦停反馈落盘（config `stop_wait` 默认 10 s，本机实测标记晚 2～4 秒），拦停了不发；等不到才走 D7 老路。测试与演示 `VIBETRAIL_STOP_WAIT=0`。
  5. K19：四路 `rule_version` 升到 v2 基线（`RULE_VERSIONS`）；钉子 test-map 第 10 节：按 rule_version 算输出摘要记在 `expect/RULE-DIGESTS`，变了没升版本就红（`--update` 也红，`--accept-rule-digest` 才放）。
  本机 11 个会话重映射 5,536 条事件全部过 schema；两家三方都没做 K17 那一层（teamai 报完整路径加服务端数字 id，Pilot 报 owner/repo 加完整路径），U12 与 Pilot 同式。
- [x] **push**（2026-09-17，`tools/lib/push.mjs`；回归 `tools/test-push.sh` 14 节 68 项，8 个变异各自变红；用户 09-15「先不急着做」，09-17「采集数据已经基本完成了……开始写push了」）：`vibetrail push [--list | --show [--json] | --requeue]`，
  Stop 看门槛，SessionStart 补做后 / SessionEnd / `vibetrail sync` 不看门槛，都看退避（D6、DESIGN §4）；端点从 config 的 `endpoint=` 读（写到端口即可），token 从 `~/.vibetrail/token` 读、只进请求头。
  09-16 复核的修正照做：批是 ack 单位（`state/push/state.json` 每块记已了结的行数，批 ack 推进、块到头才删）；token 不上命令行（用 node 的 `fetch`，没有子进程）；`batch_id` 用首末 event_id 算 UUIDv5；`client.device_id` 取 config；K14 已先修。
  **与原计划不同的四处**（对照 collector 源码 `BatchValidator` / `IndexStore` / `CollectionErrorHandler` 与 09-17 对联调端点的实测）：
  1. **被拒收只隔离那几条，不隔离整批**：422 `INVALID_EVENT` 的 message 列出错位置（`/events/N/…`，最多 10 处，实测是 JSON Pointer）、409 / 413 带 event_id，按它们挑出来、其余重发；不带位置的（`INVALID_TIME`）二分。批次外壳的错（`/client/…`）一条都不隔离、按暂时失败退避。
  2. **可重试集合按 collector 实际返回改**：400（请求体没读完整）、408、429、5xx、连不上、超时算暂时；401 / 403 暂时但 doctor 点名 token；3xx、404、405、415 算配置问题、也只退避——原写的「其余 4xx 永久」在端点路径写错时会把数据全隔离掉。
  3. **不写 `lib/schema.mjs`**：本地只挡服务端必拒又没法定位的（不是 JSON 对象、没有合法 event_id、单条超 1 MiB），其余交给服务端判、按位置隔离。手写一份会与服务端漂移（后端 09-16 刚加了 `message.reasoning` / `instruction.loaded`，OPEN-ISSUES K28）；完整 schema 校验留在测试里，`third-party/` 的 schema 原件 09-17 同步到后端最新版。
  4. **同一批里同一个 event_id 只发第一条**：内容不同时服务端整批 409；本机 spool 里 09-16 的旧块与 09-17 重采的块有 3,007 个这样的 id（OPEN-ISSUES U20）。
  门槛默认值（U17，仍暂不定）用现有取值：`push_max_age` 3600、`push_max_events` 100、Stop 一次最多 `push_max_batches` 10 批；后台兜底与 sync 按 09-16 的倾向不限批数、限时 `push_budget_s` 60 s。
  已测：端点没配不发；混批、从最早的块发；按字节拆批；门槛不满不发、满条数 / 满时间就推全机、最多 N 批后下次续传；兜底不看门槛；503 退避、翻倍封顶、退避期内兜底也不发、手动 push 不看退避；401 / 连不上 / 超时 / 404 不动数据；
  422 按位置、INVALID_TIME 二分、409、413、本地超 1 MiB、坏行都只隔离那几条；外壳错误不隔离；批内重复 id；ack 之后被杀只重发一批；两个 push 同时跑；`--requeue`；`--show --json` 过 schema；token 不落盘；sync 补完接着推。
  **还没做**：拿真实端点推——U20 09-17 定了①，09-16 的 125,083 条旧格式数据挪到 `~/.vibetrail/legacy/20260916-pre-k17/`、不推，spool 剩 9,110 条；用户定先把 push 合进 main、再让 Codex 分支（`3bfc5e4`，现装的运行时就是它）合，之后装新版、先推 1 批看服务端返回再推完——现在直接从 push 分支装会把本机的 codex-v2～v4 退回去；SessionEnd 的后台进程在 `-p` 与 desktop 关会话时活不活（DESIGN §3.1，没实测）；Codex / Cursor 的 hook 也接了 push，没有单独的回归。
- [x] **全采与协议补齐**（2026-09-16 核出、同日做完 K20–K23，`a34bbf5`）：K20 排队的人话全采时发 `message.user`（`delivery: queued`，本机这台 35 条）；K21 按停止打断工具补 `tool.end(cancelled)`；K22 `turn.end.files[]`（量过：有改动的轮平均 3.5 个文件、最多 10 个、路径约 100 字节，每条 turn.end 不到 1 KB；根外的只计数）；K23 `capture_content=0` 时 `subagent.start` 不带 `task`。
  **还开着**：~~K11 workflow 子 agent~~（09-16 第二批做了）；~~K25 DESIGN 补全采的决策条目~~（09-17 补了 D14，另立 U18：单次读 50 MB 上限与 §3.3 相反，待定）；~~子 agent 自己改的文件没进任何 `files[]`~~（09-16 第二批做了，见 K22）。
- [x] **分段读完、补采老会话最多两天**（2026-09-17 用户定，关 OPEN-ISSUES U18）：一段最多 50 MB，写完这一段的 spool 就接着读，一次 hook 读太久（默认 60 s）剩下的下次接着读，不再丢最早那段；
  每段开始前从 agents.json 重新取已知的子 agent。从没读过的会话只补最后修改在两天内的、从两天内的第一条记录读起（config `backfill_days`，`all` 不限）；在采的会话照读。
  本机 106 MB 的真实 transcript 每段 5 / 20 / 50 MB 与一次读完逐条一致（29,890 条）；回归 test-hook-flow 第 23 节。
- [x] **09-16 第二批与 09-17 收尾**（`6cb3786` / `f81ff53` / `f9f8dd6` / `03847f8`）：K11 workflow 子 agent（递归扫 `subagents/`、按 runId 挂回 Workflow 调用、journal 判完成）；K22 的子 agent 部分（子 agent 自己改读的文件进它的 `subagent.end` 与那一轮的 `files[]`，hook 改成子 agent 文件先映射）；A11 运行时计数与 doctor；路径不出本机（`vibetrail.cwd` / `vibetrail.worktree` / `cwd_changed` 相对主 checkout，`instructions_loaded` 相对工作区根，根外换成 `~` 形）；rule_version 升到 diverge / turn / ext v3；坏行、空行占行号。09-17 收尾：test-hook-flow 的版本号改从 `RULE_VERSIONS` 读，新第 22 节走 hook 的端到端，修掉同一次 hook 里 spool 块互相覆盖（K26，会丢数据），登记 `auto_mode_exit`；沙箱里对本机 20 个会话真实补采，16,697 条全过 schema、没有错误日志。
- [x] **完整性钉子**（运行时部分 2026-09-16 第二批 `6cb3786` / `f81ff53`，09-17 `03847f8` 补端到端）：映射账本加 `new` 计数，只数新读到的行，恒等式 seen = 进映射 + 坏行 + 不是对象 + 没 uuid + 回放副本 + 复制来的历史；hook 按文件累计进 `state/<sid>/integrity.json`（文件被重写时那份清零）；doctor 汇总读过多少条，点名恒等式破了、坏行、拒绝标记没认出、不认识的记录类型 / 附件类型 / system 子类型、超 1 MiB 去正文、单次读超 50 MB 截断。坏行、空行占行号（以前直接丢，中间有坏行时 checkpoint 换算成字节会错一行）。09-17 本机 20 个会话真实补采：54 份 transcript 恒等式全成立。**还没做**：~~服务端拒收的计数~~（09-17 随 push 做了，doctor 按 code 计数）；doctor 看最近会话的 `stop_hook_summary` 有没有跑过我们的命令。原记：完整性钉子：每类记录条数进出相等、映射后事件全部过 schema（这两条测试期已在 `test-map.sh` 钉住；运行时要进账本与 doctor）、超 1 MiB 被拒计数、未知记录类型 / 事件名告警（A11；G10、G6）。
  **09-16**：映射账本里 in / out / replayed / skipped_no_uuid / sentinel 已有，K8 修后再加 inherited；缺的是把它们按会话累计进 state、由 doctor 汇总（哪个会话 `marker_without_hit` > 0、`skipped_*` > 0、replayed 异常多），
  并在 test-hook-flow 里做成恒等式断言（记录数 = 出事件的 + 跳过的 + 不产事件的）——Pilot 的恒等式只写在文档里、测试 grep 不到，正是要避免的（G10）。
  **09-16 补**：D13 之后没有 hook 侧的类型化事件可以对账（DESIGN §3.2），「已知清单之外的记录类型 / attachment 类型」告警更要紧；超过 1 MiB 现在是去掉正文照发（`vibetrail.content_dropped` = size），条数进 doctor。
- [ ] 回归（用户 09-15：先不急着做）：两路各有带断言的测试，输入用 [experiments/collect-demo/scenario.json](experiments/collect-demo/scenario.json) 回放，补上 SessionStart 补做、
  打断后无 Stop、后台子 agent 晚于父 Stop、一轮多 commit、端点未配置 / 配置后断网五个场景。分歧一路已有 `test-hook-flow.sh`，其中补做与打断后无 Stop 已覆盖；
  轮次元数据一路现在只有 demo.sh 端到端跑一遍、没有断言。（09-16 起本机装了 jsonschema，两套回归里的 schema 项不再跳过。）
  **09-16 已补**：K8 / K12 / K13（test-map 第 7 段）、K14 / K16（test-hook-flow 第 17 段）、后台子 agent 晚于父 Stop（test-hook-flow 第 7 段，D13）。**09-16 / 09-17 又补**：答完标记与 Stop 两条路只留一条 turn.end（test-hook-flow 第 21 节，K24 改成 Stop 时等标记）；两轮 turn.start / turn.end 成对、status、一轮两次提交按顺序进 commits、嵌套与 workflow 子 agent、子 agent 改的文件（第 22 节）。~~**还缺**：端点未配置 / 配置后断网~~（09-17 由 `tools/test-push.sh` 第 1、7 节钉住）；push 的见上。
- [ ] 查询端只留 push 前本地预览（G9，读取不归本项目）：`vibetrail list / show` 已做（09-15），`push --list / --show` 09-17 随 push 做了；然后 OPEN-ISSUES 关 G7。
  退役脚本 09-15 已按用户要求归档到 `old/`（`old/README.md`），审计线的几份随 U6 定去留。
  **09-16 加**：`vibetrail show --bodies` 只列 `content_state = included` 的事件（被拒调用的 `tool.request.input`、被打断的回复、之后人的下一句），
  就是 G9 原话「让开发放心没有侵犯隐私」要的那份「什么正文出了本机」，几十行。
  **09-16 作废**：全采正文之后出本机的几乎是全部正文，按条列没有意义，改成按事件类型汇总条数与正文大小、能抽看某一条（OPEN-ISSUES G9）。

## G11 多个会话改、一个会话提交：追回每一行出自哪个会话

> 顺序：2026-09-11 用户定先做 G7 的两路采集（上一节），G11 往后排。
> **2026-09-14 注**：G7 定稿后 `Claude-Session` trailer 退役（DESIGN D4），本节里「装 trailer」「trailer 只答谁提交」这些前提改为
> DESIGN §3.5 的推导映射（每轮起止 HEAD + `rev-list`）；方案本身（worktree + 规矩 + 接手时拍一次快照）不受影响，动工前按 D4 复核一遍。

### 1. 需求

用户原话（2026-09-10，看完三方对比后提出）：

> 如果 pilot 数据全采的话，能实现根据错误 commit 找到具体哪个 session 提交的吗，然后找到对应的聊天内容看是
> 模型出错的还是开发人员出的错。……session 和 commit 的 1 对 1 关系我们自己已经实现了，现在说的是多个 session
> 改了多个代码，然后在最后一个 session 提交了 commit，有办法复盘回溯到当时那个 session 么

拆成两问：

1. **归属**：一个 commit 里的每一行，出自哪个会话的哪一次工具调用，还是根本不是 agent 写的。
2. **判责**：拿到那次工具调用之后，回到对话里判断是模型错了还是人错了。

### 2. 现状：会话归属只答「谁提交」

commit ↔ session 的对应（原来是 `Claude-Session` trailer，2026-09-14 起改为 G7 从每轮起止的 HEAD 推出，DESIGN §3.5）
语义都是**哪个会话执行了 `git commit`**，不是**改动出自哪个会话**。会话 A、B 改、C 提交，对应上只有 C。

原始 transcript 里的还原能力分三档（实测数据；原记在旧 spec §4.5，随该节退役移到这里）：

| 档 | 能答什么 | 覆盖率 |
|---|---|---|
| `Edit` / `Write` 工具记录 | 精确到文件 + 行范围 + diff + sessionId | **只覆盖走工具的改动**。实测某会话 10 次 Edit vs 318 条含改文件动作的 Bash——约 3%（调用次数之比，不是行覆盖率，也只来自一个会话） |
| Bash 命令文本 | 文件名出现在命令里 ⟹ 可反查「哪些 session 碰过这个文件」。实测某文件收敛到 3 个候选 | 高，但**「提到」≠「改了」**（`cat` / `grep` 也提到），是候选过滤器不是归属 |
| 全文检索 | 按错误串 / 符号定位到会话 | 全量，但无结构 |

要做到「任何改动都能精确归属」，必须在每次工具调用前后快照工作树自己算 diff——那是 git-ai 用常驻守护进程做的事，按代价否决过
（DESIGN §7）。所以 G7 的采集只提供会话归属，不提供代码归属；查询端最多给出「碰过这个文件的 session」作候选。

### 3. Pilot 全采能补多少

按源码核对：MacBook 上的 `~/program/code/loongsuite-pilot`，HEAD `4e59a5bc`（2026-09-10；机器名见 §4 开头）。它比
[三方文档](third-party/loongsuite-pilot-collection.md)的快照 `d4ab8b6d` 新 7 个 commit，但下列文件在两者之间没有改动，
行号两边一致（第六轮在 C02FM 的 `~/program/go/src/loongsuite-pilot` @ `d4ab8b6d` 上逐行复核，14 处全部对上）。无前缀的行号指 `assets/hooks/claude-code-hook-processor.mjs`。以下说的都是 **Claude Code 链路**。

| 能给 | 出处 |
|---|---|
| 每次工具调用的完整参数：Edit 的 `old_string` / `new_string`、Write 的全文、Bash 的命令原文 | `:1169`，`toolBlock.input` 原样写入 |
| 工具结果正文（回给模型的那段文字，Bash 即命令输出） | `:1185`，取自 `claude-code/transcript-parser.mjs:323` |
| tool_use id、调用与结果时间戳、`gen_ai.session.id` | `:1168`、`:1160` / `:1176`、`:955` |

| 缺 | 出处与后果 |
|---|---|
| **Bash 改的文件只有命令和输出，没有改后的文件内容** | sed / python3 / heredoc 写进文件的内容不在任何字段里。§2 那张表实测的那一个会话里这是大头（10 次 Edit 对 318 条改文件的 Bash）；全工作流的比例待 §9 测量 |
| **Edit 没有位置** | transcript 里带行号的 `toolUseResult.structuredPatch` / `originalFile` 不采：parser 读 `toolUseResult` 只为了子 agent 的 `agentId` / `agentType` / `status` / `isAsync`（`transcript-parser.mjs:326-335`）。别的链路不同：Qoder 与 Qwen Work CN 把整块 `toolUseResult` 收进工具结果（`agent-event-normalizer.mjs:507`，经 `shared/hook-processor-base.mjs:357-359`；`qwen-work-cn-hook-processor.mjs:387`） |
| **人手改的看不到** | Pilot 只观察 agent，IDE 里的编辑不经过任何 agent 事件 |
| **没有 git 状态** | `src/utils/git-context.ts:48-51` 只取仓根、分支名、`remote.origin.url`，没有 HEAD sha、没有工作树状态；提交事件 `GitHookEvent`（`src/types/events.ts:190-200`）仍然零引用。cwd 取自 hook 事件、存进会话 state（`:448-449,474-475,534-535`），不是逐次工具调用的 |

所以只靠 Pilot 能做的是**内容匹配**：拿 commit 的新增行去匹配各会话 Edit / Write 的 `new_string` 与全文。
命中的是精确归属；Bash 改的只能列出命令里出现过这个文件名的会话作候选（§2 表第二档，原话是「哪些 session
碰过这个文件」）；人改的无从归属。

**按文件找会话，第六轮审计实际碰到五个问题。**4.1 里「接手前已有」的行、装 hook 之前的老 commit、§9 的测量脚本，
走的都是这条路：从 commit 改到的文件出发，找改过这些文件的会话。

1. **同名文件。** 只比相对路径，别的 worktree、别的 clone 里改同名文件的会话也会被算进来，`d298f87` 那个误报就是这么来的
   （§11 第六轮错 2）。要按绝对路径比，再用 reflog 定出这个 commit 是在哪个工作目录里提交的。
2. **时间窗从哪算起。** 没提交的改动可能是几天前留下的。从父提交算起，最典型的「A 改了没提交、B 后来一起提交」会整个漏掉；
   窗口放宽，候选又变多。
3. **失败的调用也会算进来。** 失败、被拒、改了又改回的 Edit 都在 transcript 里，也都会成为候选。C02FM 上 Edit / Write
   共 5081 次，失败 166 次、没有结果 11 次（2026-09-11 重数，主会话加子 agent；审计时是 4925 次里 167 次失败）。
4. **transcript 找不全。** 会话存放的目录不一定是它干活的目录：agentDock 26 个会话里有 10 个中途离开了启动目录（4.1 末）；
   从别的仓启动的会话，transcript 存在那个仓的目录下（本仓最近 40 个 commit 里 19 个出自这样的会话）；CLI 起的会话
   默认 30 天就被清掉（§10）。
5. **同一个目录里几个会话同时改同一批文件，按文件分不开是谁。** 不用 worktree 时，同时开着的几个会话必然共用一个目录。
   C02FM 上 agentDock 主 checkout 的 9 个会话，两两比起止时间，重叠的有 17 对（desktop 会话一开就是几周），所以按会话的
   起止时间当窗口分不开，得看每次调用的时间戳。其中 2 对改过同一个文件，但前后相隔一个多月，还没抓到真正同一时段
   改同一文件的实例。

判责要用的对话证据，Pilot 在人类这一侧也会漏（[采集清单 §1.2b](third-party/loongsuite-pilot-collection.md)，语料在 C02FM 上）：
主会话的中断记录 265 条（含 111 MB 那份）只进了 5 条；50 MB 以下的 37 个主会话里，每轮第一条人类输入
1,599 条丢了 154 条，都是没等到真实回复的整轮。

### 4. 方案

**第六轮审计之后改（2026-09-11，用户：「按审计结果改 TODO 吧」）：主方案走「worktree + 规矩 + 接手时拍一次快照」（4.1），
逐次工具调用前后拍快照（原来的主方案，4.2）降为可选加强。**理由三条：

1. **要的是会话。** §1 的原话是「回溯到当时那个 session」。一个会话一个 worktree、改动由它自己提交时，G7 推出的 commit ↔ session 对应就是
   会话级的归属；要到轮、到调用，只翻这一个会话的 transcript：Edit / Write 直接对上，Bash 只在这一个会话的命令里找，
   候选很少。
2. **原先说 worktree 管不到串行，依据看错了。** 旧 §10 拿「main 上 09-09 一天有 5 个会话先后在同一条分支上提交」论证
   同一分支多会话串行是常态。main 的 reflog 显示，那天 15 次直接提交全出自一个会话，另外 4 个会话各在自己的 worktree
   分支里提交，再快进合进 main 6 次——恰好说明 worktree 隔离起了作用（§11 第六轮错 1）。
3. **4.2 还有 7 处错没修**：影子历史会被别的 worktree 的 gc 回收，快照失败时会贴错，打断与权限被拒都没有结束事件，
   删行的起点、merge、跨仓都会归错；代价也只在干净工作树上量过（§11 第六轮）。

下文「MacBook」指写前五轮的那台机器（提交作者 `@gupengfeideMacBook-Pro.local`），「C02FM」指第六轮审计所在的这台
（hostname `C02FM3DTQ05N`）。两台的语料不同，数字不能混用。

#### 4.1 主方案：worktree + 规矩 + 接手检测

**规矩**，要写进团队约定：

1. **一件事一个 worktree。** desktop 给每个新会话自动开一个；CLI 要显式 `claude -w <名字>`。官方文档把 worktree
   列为「并行跑多个会话」的做法，不是默认。
2. **同一件事接着干，用 resume**，沿用原会话的 session id。fork 也可以：fork 带着父会话的全部历史（C02FM 上 agentDock
   的 `eb44dfd4` 被 fork 两次，两个 fork 各带着它的 1405 条记录），commit 对应到的是 fork 会话，翻 fork 的 transcript 照样找得到
   父会话写的那几次 Edit；只是父子别同时在一个 worktree 里改。
3. **会话的改动由它自己提交。**
4. **不把会话挪进别的 worktree 接着干**；要挪，先把那边的改动提交掉。
5. **不在已有 worktree 里切分支**——没提交的改动会跟着带到新分支上。

**接手检测**，代替逐次快照：SessionStart 与 CwdChanged（hooks 文档：给 `old_cwd` / `new_cwd`）时，如果所在 worktree
有未提交的改动、而且最后一个在这里活动的不是本会话（resume 回到自己的会话不算接手），就按 4.2① 的做法拍一次快照，
记下「接手时已在工作树里」，并提醒一句。提交时把「父提交 → 接手快照 → 本 commit」接成三步的影子历史跑 blame：
接手快照里已有、父提交里没有的行标「接手前已有」，之后才变的行归 commit 对应的会话（G7 推导）。「接手前已有」的行再按时间回到
上一个在这个 worktree 里干活的会话，用 Edit / Write 内容匹配定位。每个会话每进一个 worktree 最多拍一次，代价可以忽略。
影子提交挂在共享命名空间 `refs/vibetrail/…` 下，不用 `refs/worktree/`（第六轮错 4）。它写进被观测仓的 `.git`，与 G7 零写入的冲突及替代见 §10 第一条。

**前置**：agentDock 先跑上 G7——commit ↔ session 改从每轮起止 HEAD 推出（DESIGN §3.5），2026-09-14 前这里写的「先装 trailer」已退役。
C02FM 上 agentDock 当前分支 1608 个 commit 没有一个能对上会话（2026-09-11 查，当时按 trailer 数）。

**实际用法离规矩有多远**（C02FM 上的 transcript，按每条消息记的 cwd 与分支算，2026-09-11）：vibetrail 的 10 个会话，
启动目录、实际 cwd、分支三者全对得上。agentDock 的 26 个会话（全是 desktop）里，9 个直接跑在主 checkout；10 个中途
离开了启动目录，多数进了别的会话开的 worktree；11 个干活的 worktree 目录里签出的分支与目录名对不上，也就是在已有
worktree 里切过或新建过分支；`core-code-review-checklist-01abed` 这一个目录前后有 5 个会话、4 个分支在里面干过活。
所以规矩要写下来，接手检测不能省。

#### 4.2 可选加强：逐次工具调用前后快照，在影子历史上跑 `git blame`

原来的主方案。现在只在要「到调用」、或要把会话之内的人手改分出来时才做。**第六轮实测出的 7 处错都还没修**，做之前
先修：影子历史的 ref、快照失败、打断、权限被拒、删行起点、merge、跨仓（§11 第六轮错 4–10）。下面的文字与 demo
保持一致，只改了事实性的说法，并在出错的地方标了第六轮的编号。

§2 末写过这条路：「要做到『任何改动都能精确归属』，必须在每次工具调用前后快照工作树自己算 diff」。
思路与 git-ai 的 checkpoint 相同，当时按 git-ai 的代价否掉了
（[DESIGN §7](DESIGN.md) 否掉的替代品：833MB 常驻库、完整 prompt 排队待上传、跑一次二进制就起守护进程）。
其中上传 prompt 与常驻守护进程都不是快照必需的；占盘快照也有，要实测（§7）。否决的另一半理由是价值，见 §8。

**① 快照。** PreToolUse / PostToolUse hook 里，复制一份真 index，先原样 `write-tree` 得到**暂存区**的 tree，
再把整个工作树加进去、`write-tree` 得到**工作树**的 tree：

```bash
d=$(mktemp -d); cp -p "$(git rev-parse --git-path index)" "$d/index"
GIT_INDEX_FILE=$d/index git write-tree                                        # 暂存区
GIT_INDEX_FILE=$d/index git add -A && GIT_INDEX_FILE=$d/index git write-tree  # 工作树
rm -rf "$d"
```

- 不碰真 index、不碰工作树；没改的文件复用已有 blob，只新增改过的内容。
- 从真 index 起步：已跟踪但匹配 `.gitignore` 的文件不会漏（从空 index 起步会漏），stat 缓存也是热的。
- 每次一份副本：并发的快照不抢同一个 `index.lock`（共用一份时实测会撞锁失败）。
- `cp` 必须带 `-p`：git 靠 index 文件自身的 mtime 判断哪些条目得重读内容（racy-git），副本的 mtime 变成「现在」，
  就会漏掉「`git add` 之后同一秒内被改成同样长度」的文件（demo 边界 14）。
- 暂存区那份 tree 是给 ③ 定「提交进去的那一版是什么时候暂存的」用的。合并冲突时暂存区写不出 tree，
  就在副本里去掉未合并的路径（它们本来就没有暂存版）再写，别的文件照常记（demo 边界 15）。
- 不需要常驻进程，不存 prompt。PostToolUse 的 stdin 实测直接给 `session_id` 与 `tool_use_id`
  （[DESIGN §6.1](DESIGN.md)）。PreToolUse 的字段集与子 agent 的区分，官方 hooks 文档（2026-09-11 查）有答案、
  **一手实测还没做**：两个事件都给 `tool_use_id` 与 `prompt_id`（后者是所有事件共有的字段，指「当前这句人话」）；
  字段集并不相同，PostToolUse 另有 `tool_response`、`duration_ms`，PostToolUseFailure 给 `error`、`is_interrupt`、
  `duration_ms`，没有 `tool_response`（第六轮不准 5）；子 agent 里的工具调用触发同一套 hook，只有 `agent_id` 能说明
  是子 agent（主线程用 `--agent` 启动时也带 `agent_type`）；PreToolUse 在权限确认**之前**触发。嵌套起一个 `claude -p`
  去实测，desktop 附带的二进制脱离宿主没有登录态，跑不起来；一手证据按 [experiments/hook-probe.sh](experiments/hook-probe.sh)
  的路子注入 PreToolUse 探针即可。
- 快照用到的 `add` / `write-tree` / `commit-tree` / `update-ref` 本身不会触发 gc（第六轮用 `GIT_TRACE` 实测），原先
  「都带 `-c gc.auto=0`，别让快照顺手触发 gc」的理由不成立。反过来，快照堆出的松散对象会让用户下一次 commit
  触发 `gc --auto`，影子对象要定期打包或截断（第六轮不准 7）。

**② 每一段差分归给当时进行中的工具调用。** 上一个快照到这个快照之间的差分：

| 这段时间里进行中的工具调用 | 归给 |
|---|---|
| 没有 | **gap**：不是任何 agent 工具调用做的。多半是人手改，也可能是 IDE 格式化、文件监听、别的进程 |
| 一个 | 这次调用。Edit 和 Bash 一视同仁 |
| 多个 | 并列（歧义），不硬猜 |

「进行中」怎么维护：

- pre 登记、post 只注销自己那一次，按 tool_use_id 配对，**不看相邻顺序**，同一线程里的调用重叠也不会互相关掉
  （demo 边界 3）。前提是 PreToolUse 也给 tool_use_id（待实测）；不给的话只能按线程配对，同线程重叠就分不开。
- 配不上 pre 的 post（pre 那次快照丢了，比如 hook 失败）：这一步标「起点不明」，不能落成 gap。例外：第一个快照
  就是这样的 post 时，没有更早的快照可比，这次调用的改动并进根里，标成「快照开始前已在工作树里」。
  **第六轮错 5**：demo 里快照失败时登记、注销照做——一个读不了的未跟踪文件就能让 `add -A` 失败。pre 那次快照丢了，
  post 找得到登记，不会标起点不明，之前的人手改记给了这次调用；post 那次丢了，调用的改动在下一次快照里落成 gap。
  要在快照失败时留标记，下一次成功的快照把受影响的调用带上、标起点或终点不明；`add -A --ignore-errors` 能让一个
  读不了的文件不拖垮整次快照。
- 被打断的调用等不到 post，也未必等得到同线程的下一个 pre（子 agent、会话就此结束），所以在**一轮结束时**关：
  下一次 UserPromptSubmit、Stop、StopFailure（API 出错结束的轮只发它）、SubagentStop、SessionEnd 到来时先拍一次，
  把到此为止的改动记给它、标「未完成」，再注销。只关本线程的：主线程的事件只关没有 `agent_id` 的调用，SubagentStop
  只关那个子 agent 的——后台子 agent 会活过主线程的 Stop（第六轮不准 5）。**用户打断时 Stop 不触发**（hooks 文档：
  用户中断造成的停止不跑 Stop；C02FM 上的 Claude Code 2.1.260 里中断直接返回，PostToolUseFailure 也不发），被打断的调用
  要挂到下一次 UserPromptSubmit，人打断之后去手改的那段全记给它（第六轮错 6）。
- **失败的调用没有 PostToolUse。** 文档写 PostToolUse 只在工具成功后触发，失败另有 `PostToolUseFailure`。
  Bash 非零退出走它（`error` 首行是 `Exit code N`），测试失败很常见；但 grep、rg、find、diff、test 与 `git diff` 退出码
  为 1 不算失败。只挂 PostToolUse 的话失败的调用会一直「进行中」到一轮结束，同一轮里后面所有调用的改动都被标成
  与它并列，所以两个事件都要挂。**权限被拒两者都不发**：手动拒绝、命中 deny 规则、被别的 hook 拦下，都只有
  PreToolUse；`PermissionDenied` 只在 auto 模式发。要加挂它与 PostToolBatch——后者在下一次调用模型前发，列出本批
  每个 tool_use_id 及结果，含被拒的（第六轮错 7）。
- 每次快照顺手记下 HEAD：agent 在工具调用里 checkout / rebase / pull 时工作树整片变化，看日志时能把这类步骤
  与真正的改动分开（demo 没覆盖，见 §5）。
- 登记表与快照日志都放在 `git rev-parse --git-path` 解析出的本 worktree 私有目录里，每个 worktree 一份。
  **第六轮错 10**：hook 在会话当前 cwd 所在的 worktree 拍快照。Edit / Write 用绝对路径改别的 worktree 或别的仓
  （OPEN-ISSUES K2，本项目自己就这样），那边前后都没有快照，改动记给那边碰巧在跑的别的会话、或者成 gap；执行 cd 或
  EnterWorktree 的那次调用，pre 与 post 会落进两个 worktree 的登记表。要按 `file_path` 找所在 worktree 拍快照，挂
  CwdChanged，并加一份会话级索引记下每次 pre 落在哪个 worktree。

**③ 影子历史每个 worktree 一条、跨提交连续，post-commit 时只报本 commit 的行。**

- 每次快照与末端不同，就往 `refs/worktree/vibetrail/shadow` 上接一个影子提交（`git commit-tree`，作者名 =
  这一步归给谁）。`refs/worktree/` 是每个 worktree 各一份的命名空间；各 worktree 共用一条 ref、或共用登记表时，
  别的 worktree 的快照或调用会串进来贴错标签（demo 边界 6 的标题写了两种串法各自贴成什么，已实测）。
  别的 worktree 要读，用 `main-worktree/refs/worktree/…` 或 `worktrees/<id>/refs/worktree/…`——`<id>` 是
  worktree 的 id（`.git/worktrees/` 下的目录名），不一定等于它的目录名。默认 refspec 不推送这些 ref。
  **第六轮错 4**：在一个 worktree 里跑 gc，不会把别的 worktree 的 `refs/worktree/` 当成可达的起点。别处一次
  `gc --prune=now` 就把这条影子历史的对象回收了，之后这个 worktree 里 `git gc`、`git log --all` 都报 `bad object`；
  默认 gc 下闲置两周就没了（C02FM，git 2.37.1 实测；MacBook 的 2.39.5 待复测）。`main-worktree/refs/worktree/…`
  在 2.37.1 上也解析不了。要换成共享命名空间 `refs/vibetrail/shadow/<worktree-id>`（实测 gc 之后还在），demo 还是旧写法。
- 第一个快照是根，其中已有的内容记为「快照开始前已在工作树里」。
- **不在每次提交时从父提交重开**——否则上一次提交没带走、留在工作树里的改动，会在下一次提交里被当成 gap。
- post-commit 时逐个文件做：先定一个**出发点快照**，在它后面临时接上真 commit 的 tree，出发点的工作树与提交内容
  差出来的行归给一个标签，再 blame。出发点按 blob 查快照日志里记的暂存区来定：
  - 最后一个快照时暂存区里已经是提交的这一版：往前找这一段连续「暂存区已是这一版」的起点，起点前面那个快照
    就是出发点，差出来的行归给起点那一段进行中的调用（边界 7、8）。起点就是第一个快照时，标「快照开始前已在暂存区里」。
  - 最后一个快照时暂存区还不是这一版（提交前一刻才 `git add`），出发点就是最后一个快照，差出来的行归给提交那一刻
    进行中的调用：agent 在工具调用里提交就是那次调用，人在终端提交就是 gap（边界 9）。
  - 比的是整份 blob，不按行文本搜，同内容的行不会被认到别人头上。
  - 这条规则只看快照时的暂存区，不看提交用的是哪种命令。`commit -a`、`commit <path>` 在提交时才暂存，如果暂存区里
    碰巧早就是同一版，就会按那次更早的暂存算（内容相同，只是归属对象可能不同，见 §7）。
- 只报本 commit 相对父提交新增或改动的行：路径从 `git diff -M -z --name-status` 取（NUL 分隔、从不加引号；
  `-M` 认改名，纯改名没有新侧行），行号用新旧两个 blob 之间的 `git diff -U0 --no-color --no-ext-diff` 取，
  不解析带路径的 `+++` 行，也不受用户的 `color.diff` / `diff.external` 配置影响。部分暂存时被「改回去」的行不在
  diff 里，不会被报；删掉的文件没有新侧行；二进制文件只提示、不逐行报。单个文件出错只跳过它，并打出第一行报错
  （边界 13 的子模块指针）——它在子 shell 里跑，`set -e` 不起作用，所以每一步都显式检查。
- **第六轮补的两处，未修。** 用户配置还会让输出变形：`textconv` 让 diff 与 blame 都按转换后的文本算行号（两处都要加
  `--no-textconv`），带 `-diff` 属性的文本文件被当成二进制，`blame.ignoreRevsFile` 指向不存在的文件时每个文件都归属
  失败（不准 6）。merge 只对第一父提交做 diff：冲突 merge 会把侧分支的行整片记给跑 merge 的调用，干净 merge 与 pull
  又只跑 post-merge、一行不报；要改成多父提交只报 `diff-tree --cc` 的新行，与 `vibetrail-audit` 的 `--cc` 口径一致（错 9）。
- 每行给两个答案：**放置者**（不带 `-M` / `-C` 的 blame：这一行是谁放到这里的）与**内容来源**（带 `-M` / `-C`：
  认出的移动或复制的出处）。不同就都标上——复制别人的代码，放置者负责把它放在这里，内容却出自原作者（边界 12）。
  `-M` / `-C` 是带阈值的启发式。
- **删掉的行也要出记录。** 上面只报新侧的行，「B 删掉了零检查」这类改动在记录里没有对应项，而删检查正是典型 bug。
  `git blame --reverse <根>..<末端> -- <文件>` 给出根版本每一行最后出现在哪一步，它在影子历史上的子提交就是删它的
  那次调用（边界 16 实测）。**第六轮错 8**：原先写「落地时对本 commit diff 里的 `-` 行也走这一条，出发点与上面相同」
  不成立。影子历史跨提交连续，根里未必有这个文件（`blame --reverse` 直接报 `no such path`），根之后才加、本 commit
  删掉的行也追不到；按正向的出发点起算，连边界 16 自己的 check 都不在起点里。要改成：起点取工作树里该文件还是
  父提交那一版的最后一个快照，终点取接上真 commit 的那一步，只查父版里被删的那些行（三个场景实测都找到了删它的调用）。

**④ 落盘只存指针。** 文件、行范围、行内容哈希、会话、tool_use_id，锚在 `Vibetrail-Id` trailer 上——
与审计记录同锚，rebase / cherry-pick 下不变（[spec/trace-v1.md §2](spec/trace-v1.md)；这个 trailer 由审计线的 git hook 写，去留见 OPEN-ISSUES U6，
记录落哪见 §10 第一条）。每个 commit KB 级。影子历史和快照日志与 transcript 一样只留本机。

### 5. 验证：demo（2026-09-11）

脚本 `experiments/attrib-demo.sh`（2026-09-14 列为删除：只验证降为可选的 4.2，只打印不断言，边界 10 / 14 的场景本身有错；需要时
`git show a93828c:experiments/attrib-demo.sh`）：在临时目录建一次性仓库，不碰当前仓库，MacBook 上十几秒（C02FM 约 25 秒）。
它验证的是 4.2；4.1 的接手检测还没有 demo。

主场景（BASE 之前还有历史，分两次提交）：

1. 会话 A：Edit 给 `calc.py` 的 `div` 加零检查（A1）；Bash 里用 `python3` 新建 `report.py`（A2）；
   Edit 给 `util.py` 的 `clamp` 加 docstring（A3）；然后**只提交 `calc.py`**（A4），另两处改动留在工作树；
2. 人在 IDE 里把 `clamp` 改错，不触发任何 hook；
3. 会话 B 用 `sed -i` 把 `calc.py` 的 `add` 改错（B1）；
4. 会话 C 用 Edit 给 `util.py` 加函数（C1），然后删掉 `legacy.py`、提交全部（C2）。

第二次提交的 trailer 上只会有 C。另有 16 个边界场景：1–15 各对应四轮审计抓到的一类错，16 是第五轮补的删行（§11），预期写在各自的标题里。
输出（`←` 之后是注释）：

```
######## 主场景：三个会话 + 一次人手改，分两次提交
== div: zero check —— 本 commit 新增或改动的行 ==
calc.py    L5   A:A1         if b == 0:
calc.py    L6   A:A1             raise ZeroDivisionError("b is 0")
== feature: several things —— 本 commit 新增或改动的行 ==
calc.py    L2   B:B1         return a - b                       ← sed 改的，Edit 记录里没有
report.py  L1   A:A2     def report(xs):                        ← python3 写的，上一次提交没带走
report.py  L2   A:A2         return sum(xs) / len(xs)
util.py    L2   A:A3         """Clamp x into [lo, hi]."""       ← 同样是上一次提交没带走的
util.py    L3   gap          return max(lo, min(x, lo))         ← 人手改的
util.py    L4   C:C1                                            ← 空行
util.py    L5   C:C1     def lerp(a, b, t):
util.py    L6   C:C1         return a + (b - a) * t

######## 边界 1：X 进行中时 Y 开始（如并行的子 agent），改动各归各的
== human commit —— 本 commit 新增或改动的行 ==
f.txt      L1   P:X      A-by-X
f.txt      L3   Q:Y      C-by-Y

######## 边界 2：两个调用都在进行中时发生的改动 → 标并列，不硬猜
== human commit —— 本 commit 新增或改动的行 ==
f.txt      L2   P:X|Q:Y  B-by-X-or-Y

######## 边界 3：同一线程两个调用重叠（pre A1、pre A2、post A1），按调用号配对，A1 结束不会把 A2 关掉
== human commit —— 本 commit 新增或改动的行 ==
f.txt      L2   A:A2     B-by-A2

######## 边界 4：已跟踪但匹配 .gitignore 的文件，只报改动的那一行
== bump —— 本 commit 新增或改动的行 ==
deps.lock  L1   A:A1     v2

######## 边界 5：并发快照（每次复制一份 index），30 轮 × 2 路
快照失败 0 次（其中 index.lock 冲突 0 次）

######## 边界 6：两个 worktree 交替拍快照，影子历史与登记表各管各的（共用 ref 会标成 X:X1，共用登记表会标成 B:B1）
== human commit in wt1 —— 本 commit 新增或改动的行 ==
f.txt      L2   gap      B-by-human

######## 边界 7：先暂存、后又改，提交的是暂存区里的旧版本 → 仍归给写它的调用
== commit the staged v1 —— 本 commit 新增或改动的行 ==
f.txt      L1   A:A1     v1

######## 边界 8：人改、暂存、再改，都不经过 hook，然后 agent 在工具调用里提交暂存区 → gap，不记给提交者
== agent commits the index —— 本 commit 新增或改动的行 ==
f.txt      L1   gap      v1-by-human

######## 边界 9：人在最后一个快照之后补的行，与 A1 写过的行同内容 → 仍是 gap，不认到 A1 头上
== human adds h —— 本 commit 新增或改动的行 ==
m.py       L3   A:A1     
m.py       L4   A:A1     def g():
m.py       L5   A:A1         return None
m.py       L6   gap      
m.py       L7   gap      def h():
m.py       L8   gap          return None

######## 边界 10：调用被打断（有 pre 没 post），到这一轮结束时关掉并标未完成；之后的人手改归 gap
== human commit —— 本 commit 新增或改动的行 ==
f.txt      L1   S:S1(未完成) A-by-S1
f.txt      L2   gap      B-by-human

######## 边界 11：pre 那次快照丢了（hook 失败），只有 post → 标起点不明，不记成 gap
== human commit —— 本 commit 新增或改动的行 ==
f.txt      L1   A:A1(起点不明) A-by-A1

######## 边界 12：复制——这一行是谁放进来的（放置者）与内容最早出自谁（-M / -C）分开标
== f and g —— 本 commit 新增或改动的行 ==
m.py       L1   A:A1     def f(items):
m.py       L2   A:A1         total = compute_total(items, discount_rate)
m.py       L4   B:B1     def g(items):
m.py       L5   B:B1(内容同 A:A1)     total = compute_total(items, discount_rate)

######## 边界 13：改名、怪文件名、二进制、子模块指针，开着 color.diff=always 与 diff.external；一个出问题也不拖垮别的
== rename and odd names —— 本 commit 新增或改动的行 ==
bin.dat  （二进制文件，不逐行报）
ok.txt     L2   A:A1     ok2
say"hi".txt L1   A:A1     q
sub  （这个文件归属失败，跳过：fatal: bad object HEAD:sub）
tab	here.txt L1   A:A1     t
说明 b.txt L4   A:A1     four

######## 边界 14：racy-git——add 之后同一秒改成同长度，隔一秒再拍；snaptree 要拍到工作树里的版本
snaptree 拍到：return a - b（工作树里是 return a - b）
对照：cp 不带 -p 拍到：return a * b

######## 边界 15：合并冲突时暂存区写不出 tree → 只去掉冲突的路径；干净合入的文件仍归给做合并的调用
== merge side —— 本 commit 新增或改动的行 ==
c.txt      L1   A:A5     c-resolved
f.txt      L2   A:A3     from-side

######## 边界 16：删掉的行——attribute 只报新侧的行，B 删掉的 check 没有对应项；反向 blame 找得到删它的那一步（还没做进 attribute）
== delete check —— 本 commit 新增或改动的行 ==
f.txt      L3   A:A1     more                                    ← 正向只报得出这一行
f.txt      L1   keep     最后见于 B:B1 → 仍在末端
f.txt      L2   check    最后见于 A:A1 → 删它的一步：B:B1        ← 反向 blame 找到删它的调用
f.txt      L3   rest     最后见于 B:B1 → 仍在末端
```

主场景两次提交新增或改动的行全部归对：两处 bug 分别落在 B 的 sed 和人的手改上；第一次提交没带走的改动，
在第二次提交里仍归给当初写它的 A2、A3；BASE 之前的旧行和删掉的文件都没有被报出来。边界场景的输出与标题里的预期一致；
边界 6 标题里另两种串法的结果，是把 ref 或登记表临时改成共用后实测的，不在 demo 里。

**demo 没覆盖的**：搬运（`git stash pop`、`cherry-pick -n`、跨 worktree `cp`）；agent 在工具调用里移动 HEAD
（checkout / rebase）；内容改走又改回之后 `commit -a`（§7）；子模块指针只跳过、不归属；影子历史的并发追加
（demo 是串行的）；hook 里怎么区分子 agent、PreToolUse 给哪些字段（文档答案见 4.2①，一手未测）；
真实仓库规模下的耗时与占盘（MacBook 初量与第六轮补量见 §7，agentDock 未量）；删掉的行还没做进 attribute（边界 16 只演示了反向 blame）。
场景是照已知的错搭的，没见过的错照样测不到。它也只打印、不断言。

**第六轮复跑**（C02FM，git 2.37.1）：输出与上面逐字一致。但第六轮在 demo 没搭过的路径上实测出 7 处错（§11），场景本身
也有两处问题：边界 10 演的顺序与真实相反——打断时不发 Stop，人打断后的手改发生在收尾之前，那一行会标成
`S:S1(未完成)` 而不是 gap；边界 14 的对照行依赖秒边界，跑 60 次有 1 次对不上，强制跨秒跑 8 次全对不上。

### 6. 判责：从 bug 回到对话

1. **定位出错的行。** 从修复 commit 出发：它删掉或改掉的行就是出错的行。在修复 commit 的父提交上
   对这些行跑 blame，找到引入它们的 commit（学术上叫 SZZ 算法）。
2. **查归属。** 4.1：引入 commit 对应的会话（G7 从每轮起止 HEAD 推出，DESIGN §3.5）就是会话，「接手前已有」的行按下表另查；要到调用，翻这个会话的
   transcript。做了 4.2 的话：`Vibetrail-Id` → 归属记录 → 会话 + tool_use_id，放置者与内容来源不同时两个都要看。
3. **还原现场。** 回**原始 transcript**（不用 Pilot 事件，理由见 §3 末；**留存未解决**：2026-09-15 D5 定不传 transcript 原文件，只有本机 30 天内可回，DESIGN §7 D5），沿 `parentUuid` 往上找到触发这次
   工具调用的人类消息。证据包：人的指令、模型的 thinking、工具调用本身、同会话前后的分歧事件（判据已有）、
   当时的 system prompt 与加载的 CLAUDE.md（2.1.258 起 transcript 自带快照，见 [DESIGN §6.3](DESIGN.md)）、
   这个 commit 的审计记录（`vibetrail-audit`）。
4. **判断**，大致口径：

| 情形 | 归到 |
|---|---|
| 归属为「接手前已有」（4.1） | 不是提交它的会话写的。按时间回到上一个在这个 worktree 里干活的会话，Edit / Write 能直接对上；对不上的是那个会话的 Bash 或人 |
| 归属为 gap（4.2） | 不是 agent 工具调用做的。本工作流里人基本不碰文件（[DESIGN §6.2](DESIGN.md)），先排除格式化器、文件监听、后台进程（§7），再归人或人跑的工具 |
| 标「未完成」（4.2） | 按歧义看：被打断的调用一直挂到下一句人话，其间可能有人手改（§11 第六轮错 6） |
| 指令本身要求了错误行为 | 人 |
| 指令对、实现错 | 模型 |
| 模型提示过风险、人坚持要做 | 人的决定 |
| 审过、但审计记录里没发现 | 流程 |

这一步是判断，不是计算。可以让 LLM 按证据包先分类，由人拍板。口径本身待定（§10）。

### 7. 已知限制与处理

**主方案（4.1）的限制：**

- **规矩靠人守，只能查违规。** 接手检测只在 SessionStart 与 CwdChanged 时看；用绝对路径或 `git -C` 直接改、提交
  别的 worktree，不触发它。
- **会话之内分不出人手改。** 会话进行中人在它的 worktree 里改的，都算这个会话的。要分，就在 4.2 里按轮拍（§10）；
  但人打断 agent 之后、说下一句话之前的手改，哪种快照都分不开——打断没有任何事件（第六轮错 6）。C02FM 上 vibetrail
  的 10 个会话里 5 个有过调用中途被打断，共 12 次，从打断到下一句人话中位数约 5 分钟。
- **「接手前已有」只说明不是提交者写的。** 定到具体会话要靠内容匹配，Bash 改的对不上。
- **fork 之后 commit 对应到的是 fork 会话。** 父会话写的内容要在 fork 的 transcript 里往前翻。
- **跨仓（OPEN-ISSUES K2）。** 会话在别的仓启动、改本仓并提交，G7 的推导照样对（HEAD 按提交所在仓记）；但 scope=project 的门控
  按会话的 cwd 判登记，认不到从别的仓启动的会话（`vibetrail-sync` 时代就有的同一个问题）。

**逐次快照（4.2）另有的限制：**

- **并发。** 两个工具调用同时进行时（包括同一会话里并行的子 agent），各自独占的时段按 4.2② 归得开（demo 边界 1），
  重叠时段里的改动只能标并列（边界 2）。Edit / Write 的精确改动可以从 hook 的 `tool_input`（old / new string、全文）
  拿到，据此把并列拆开；Bash 之间的重叠拆不开。「拍快照 → 算标签 → 追加影子历史 → 改登记表」这一整段要串行：
  加一把 worktree 级的锁，或者追加时用 `update-ref` 带旧值校验、失败就重拍重算——光有旧值校验不够，登记表也得原子地改。
- **嵌套。** 如果连 Agent 工具也挂，前台子 agent 运行期间外层那次调用一直「进行中」，子 agent 的改动全和它并列，
  两次调用之间的人手改也记给它。v2.1.198 起子 agent 默认在后台跑，外层调用一启动就结束，没有这个问题。挂的话要么
  排除 Agent，要么约定内层调用优先（第六轮不准 4）。
- **调用进行中的人手改会记给这次调用。** 快照只看得出「这段时间里谁在跑」，看不出是谁动的手；PreToolUse 在权限确认之前触发，人在等确认时的手改也算进这次调用；被打断的调用
  到下一次 UserPromptSubmit 之前一直算进行中（打断时不发 Stop，第六轮错 6），其间的人手改同样记给它（边界 10 标了
  「未完成」，要按歧义看待；它演的顺序与真实相反，见 §5）。暂存也一样：
  4.2③ 里出发点的工作树还没有、暂存时才带进来的那些行，归给暂存那一段进行中的调用，它未必是写这几行的人
  （出发点工作树里已有的行照常往前追，边界 7 的 v1 归给写它的 A1，不是暂存它的 A2）。
- **改走又改回。** A2 暂存了 v，B1 在工作树里改走，B2 又改回 v，然后 `commit -a`：暂存区一直是 v，按 4.2③ 会记给
  最早写 v 的 A1；只看工作树历史的话，放置者是最后改回来的 B2。内容相同，偏差只在「记给谁」（第四轮审计实测）。
- **搬运。** `git stash pop`、`cherry-pick -n`、从别的 worktree `cp` 过来的改动，会记在执行搬运的那次调用上。
  要追到源头，得按行内容哈希在各 worktree 的影子历史里找最早出现的地方：它们共享同一个对象库（git-common-dir），
  ref 按 4.2③ 的写法跨 worktree 可读，做得到，要多写一段。
- **后台运行的 Bash。** 提前返回、进程还在跑的不止 `run_in_background`，还有用户按 Ctrl+B、超时自动转后台、为送达
  排队的消息转后台的；PostToolUse 在工具返回时就发了，之后的改动会落进 gap 或记给下一次调用。要看 PostToolUse 里的
  `tool_response.backgroundTaskId` 打标；这类任务会跨轮，歧义要一直算到它结束（看 Stop 输入里的 `background_tasks`），
  不止「同一轮里的 gap」（第六轮不准 5）。
- **快照看不见的改动。** 复制真 index 会连带 `assume-unchanged` / `skip-worktree` 标记，这类文件的改动快照看不到（少见）。
- **代价只在干净工作树上量过，agentDock 未量。** 2026-09-11，MacBook SSD，工作树干净、index 热，进程内计时取 10 次平均：

  | 仓 | 跟踪文件 | `add -A` | `write-tree` | 对照 `git status` | 首次冷 `add -A` |
  |---|---:|---:|---:|---:|---:|
  | cadvisor | 2658 | 22ms | 11ms | 21ms | 188ms |
  | loongsuite-pilot | 928 | 14ms | 11ms | 15ms | 152ms |
  | 合成 30k 文件 | 30000 | 56ms | 12ms | 54ms | 2.2s |

  热态一次快照（两次 `write-tree` 加一次 `add -A`）在 2.6k 文件的仓里约等于两次 `git status`，30k 文件时是 80ms 对
  108ms；工具调用前后各一次。**第六轮补量**（C02FM，1000 个文件的仓）：未跟踪、没被 ignore 的文件不在真 index 里，
  副本用完就丢，每次快照都要从头读、哈希一遍——加 5000 个未跟踪小文件时每次快照 0.84s（`git status` 0.02s）；
  一个 200MB 的未跟踪文件首次 4.3s、之后每次 0.19s，对象库涨 214MB；一个 20MB 的日志每步追加一行，10 次快照对象库
  涨 67MB。所以「冷的只有第一次」不成立，占盘也没系统量过。post-commit 的归属也没量过：日志 2000 行、一个 commit
  改 10 个文件各 10 行，demo 的写法要 282s，其中每个文件逐行跑 `rev-parse` 占 27s（换成一次 `cat-file --batch-check`
  只要 0.25s），逐行各跑两次 blame 也得改成每个文件一次。SessionEnd 的 hook 全部加起来只有 1.5 秒，装不下冷的 `add -A`。
  影子历史跨提交连续，要定截断策略，中间 blob 堆在本地 `.git/objects`，截断后让 gc 回收。没进 `.gitignore` 的
  未跟踪文件（比如 `.env`）也会写进本地对象库——不出本机，但要知道。
- **gap 不等于人。** 格式化器、文件监听、构建工具在工具调用之外改的文件也会落进 gap。
- **squash 合流**下会话对应会丢：squash 出来的 commit 是人在别处造的，`rev-list` 里没有它；审计线的锚同样丢（[spec/trace-v1.md §2.1](spec/trace-v1.md)）。

### 8. 对现有文档的影响（落地时再改，现在不动）

- [DESIGN §7](DESIGN.md) 否掉 git-ai 那行：否决是代价与价值两头算的。主方案（4.1）不做逐次快照，这个否决基本仍成立，
  只需补一句：「多个会话之间谁写的」是另一个维度，由规矩与接手检测管；多出的只是「接手前已有」这一类标注。做 4.2 时再按
  原来的两头重评（价值那头：文件侧分歧在本工作流接近空，DESIGN §6.2；代价那头：git-ai 的 833MB 常驻库等）。
- 本节 §2 的三档表：结论「只提供会话归属」之后补上「接手前已有」的标注与归属记录。
- [spec/trace-v1.md §3](spec/trace-v1.md)：做了 4.2 才填得出 Agent Trace 的 `files[].conversations[].ranges[]`，到那时再评估「不声称合规」。
- [CAPABILITIES §1](CAPABILITIES.md)、[DESIGN §3.6](DESIGN.md) 的流程图：加上「接手检测 → 提交时标注」这一段；做了 4.2 再加
  「快照 → 归属」。

### 9. 拆解

勾选只记拆解项做没做完，G11 整体的状态以中心表为准。

- [ ] **前置：agentDock 跑上 G7。** commit ↔ session 靠每轮起止 HEAD 的推导（DESIGN §3.5），trailer 已退役；G7 落地之前谈不上
  「commit 对应会话」，也量不了多会话。
- [ ] **重写测量脚本再量**（第六轮错 3）。旧脚本 `experiments/multi-session-commits.sh` 两个方向都偏（按文件找会话本身的问题汇总在 §3 末），
  出的数不能拿来做决定，2026-09-14 列为删除（需要时 `git show a93828c:experiments/multi-session-commits.sh`）：只比路径后缀，别的 worktree、别的 clone 里的同名文件都算进来；失败的 Edit
  照算；只找现存 worktree 对应的项目目录，存放在已删 worktree 目录下、或从别的仓启动的会话都漏；时间窗从父提交算起，
  漏掉 G11 要抓的「A 改了没提交、B 后来一起提交」。重写：像 G7 的门控那样扫全部项目目录、按每条消息记的 cwd
  归到 worktree；用 reflog 定 commit 是在哪个 worktree 提交的；只算成功的调用；时间窗取「这个 worktree 上一次提交
  之后」；「无匹配」拆成「没有 transcript」与「有 transcript 但没有 Edit」。要量的：
  1. **多会话 commit 占多少。** C02FM 上用旧脚本重跑本仓最近 40 个 commit：多会话 0、单会话 1、无匹配 39。前五轮写的
     「7 个可查、2 个确定多会话」是在 MacBook 上另一个 clone 里跑的：`d298f87` 是跨 clone 的误报，`514876d` 没有
     trailer、时间窗 6 小时，谈不上「确定」（第六轮错 2）。
  2. **接手有多频繁**：会话进入有未提交改动的 worktree 的次数。要等接手检测装上才有记录；在那之前只能从 transcript
     里的 cwd 变化估个上限（4.1 末的数）。
  3. **Edit / Write 内容匹配能对上多少行**，决定「接手前已有」的行能不能定到会话。spec §4.5 的「约 3%」是调用次数
     之比（10 次 Edit 对 318 条改文件的 Bash），不是行覆盖率，也只来自一个会话。
- [ ] **接手检测 hook**：SessionStart / CwdChanged，按 4.1 拍快照、提醒；影子提交挂 `refs/vibetrail/…`。hook 一律 `exit 0`、
  stdout 不输出任何东西——exit 2 在 PreToolUse 会拦下工具、在 UserPromptSubmit 会吞掉用户的提示、在 Stop 会阻止停止，
  而 `set -e` 下 grep 读一个不存在的文件退出码就是 2（§11 第六轮）。每个 hook 显式设 timeout。挂在哪（我们自己还是
  改造 Pilot）见 §10。
- [ ] **提交时归属**：「父提交 → 接手快照 → 本 commit」跑 blame，标「接手前已有」，其余归 commit 对应的会话。挂点原定 post-commit
  git hook，与 G7 的零写入冲突；改在 Stop 时按 `rev-list` 对本轮新 commit 补算。归属记录的锚与落点见 §10 第一条。
- [ ] **规矩写进团队约定**；`vibetrail-doctor` 报最近 N 个 commit 里有几个带「接手前已有」的行。
- [ ] **查询**：`vibetrail blame <file>:<line>` → commit → 会话（「接手前已有」的行再往前找）→ transcript 回跳；
  另加一个从修复 commit 出发的 SZZ 入口。
- [ ] **测试**：接手检测与提交时的标注，照 `tools/test-*.sh` 写带断言的测试。
- [ ] **可选：4.2 逐次快照。** 先修第六轮的 7 处错与 6 处不准；再定粒度（§10）与围哪些工具（Bash / Edit / Write /
  NotebookEdit 与会写文件的 MCP 工具，还是全部；挂 Agent 工具见 §7「嵌套」）；一手实测 PreToolUse 的字段与子 agent 的
  区分（文档答案见 4.2①）；把 demo（已列为删除，场景清单在 §5）重写成带断言的测试，补上 §5「demo 没覆盖的」；整段加锁或旧值校验、搬运按内容哈希
  回溯、截断策略。
- [ ] **回写文档**：§8 列的各处。

### 10. 待定（先记录、暂不定）

- 归属记录落哪。原来两条路：`.claude/trace/attributions/<vibetrailId>.jsonl`（随仓，与审计记录同锚）或 git notes。
  **2026-09-14 后两条都与 D4 冲突**：随仓违反零写入，git notes 也是写进被观测仓的 `.git`。第三条路：作为 G7 的一路事件走 spool → 云端，
  锚用 commit sha + 推出的会话 id，rebase 后靠 G7 记的 reflog 追。倾向改为第三条。接手快照的影子提交是同一个问题：要么放进
  `~/.vibetrail/` 下的独立对象库，要么把 DESIGN A8 的例外写明（审计线的 OPEN-ISSUES U6 同类）。
- 影子历史与快照日志保留多久、怎么截断（4.1 只有接手快照，量小；4.2 才要认真定）。
- 放置者与内容来源都存，还是只存一个；判责默认看哪个（4.2）。
- 判责口径（§6 的表）是固化成字段，还是只作为复盘时的人工指引。
- 是否和 G7（装一次、自动上报）一起做：接手检测的 SessionStart / CwdChanged hook 与 G7 的 HOME settings hook 是同一个挂载点；
  G7 定了零写入，本条的影子提交与提交时归属的挂点要另定（上一条）。
- 是否也给 Pilot 的数据做一版纯内容匹配的归属：不拍快照、覆盖面小，但不用装任何东西。
- **~~规矩还是机制~~——已定（2026-09-11）**：主方案走规矩加接手检测（4.1），逐次快照降为可选（4.2）。用户 09-11：
  「有 worktree，如果大家都规范使用的话，其实不太会出现多个 session 同时一个改一个东西」。原文认为 worktree 只消掉
  **并发**、管不到**串行**，依据是「main 上 09-09 一天有 5 个会话先后在同一条分支上提交……同一分支多会话串行是常态」，
  第六轮查实是把快进合并看错了（错 1）。串行由 4.1 的规矩 2–5 与接手检测管。还开着的只有：要不要做 4.2、做到哪一层，
  看 §9 的测量。
- **粒度：轮还是工具调用（只关 4.2）。** 判责（§6）问的是「指令对不对、实现错没错」，这是**轮**的粒度。hook 给的
  `prompt_id` 是所有事件共有的字段，指「当前这句人话」，不是这次调用出自哪一轮。UserPromptSubmit 与 Stop 各拍一次，
  能把大部分「agent 这一轮改的」与「两轮之间人改的」分开，快照次数少一到两个数量级；轮内要到具体调用时，Edit / Write
  从 transcript 直接有，只有 Bash 需要再细。原文说「§7 里并发与嵌套的问题大半消失」不对（第六轮不准 3）：§7 当时没讲
  嵌套；按轮拍时两个会话的轮一重叠，改动全标并列，轮中间的人手改也记给 agent，并发反而更重；打断时不发 Stop，后台
  子 agent 与后台 Bash 会跨轮，「Stop 到下一次 UserPromptSubmit 之间就是人」这个前提也不成立。倾向不变：做 4.2 时
  轮为默认，工具调用粒度作为 Bash 上的可选加强。
- **快照挂在哪：我们自己挂，还是改造 Pilot。** 用户 2026-09-11：「肯定不止靠pilot，我知道他做不到，要改造」。
  这是上面「是否和 G7 一起做」的另一种答案。主方案改成 4.1 之后，要挂的只剩 SessionStart / CwdChanged（与 G7 同挂点）和提交时的归属计算（G7 定了不装 git hook，
  改在 Stop 时按 `rev-list` 补算），改造的量比原先小得多；下面按要做 4.2 的情形列。Pilot 缺的不是字段，是看工作树的
  能力（§3 的「缺」表：Bash 改了什么、人改了什么，事件里本来就没有，只能拍快照）。改造要加：4.2① 的快照与一轮收尾时的关闭；跨 hook 事件的调用登记表，
  每个 worktree 一份、加锁；每次快照记 HEAD 与所在 worktree；归属计算，挂 post-commit，或者不挂、事后按快照里记的
  HEAD 找出 commit 落在哪两次快照之间再离线算（推出来的，未验证）；只上传归属记录；补上 §3 末人这一侧的漏采。
  会多出来的问题：影子历史写进被观测仓的 `.git`，等于采集器往用户仓里写对象和 ref，放 Pilot 自己的目录则要实测
  对象复用、会不会被仓的 gc 连累——放在被观测仓里也一样会被连累，`refs/worktree/` 会被别的 worktree 的 gc 回收
  （第六轮错 4），只能用共享命名空间；pre 那次快照要拍完工具才开始跑，每次工具调用都多出这段耗时（§7）；`Vibetrail-Id`
  要装我们的 `prepare-commit-msg`，没装的仓只能锚 commit sha 一类，rebase 后会变；只对工具调用前后有同步 hook 的
  agent 成立，靠事后读日志接入的拍不到调用前后的快照。
- **对话证据怎么留——09-14 曾定为逐字节副本上云（D4），2026-09-15 D5 撤销**：不传 transcript 原文件，正文只随分歧事件走；§6 第 3 步在本机 30 天内可回原始 transcript，
  之外没有来源。要补正文时走协议的 message.* / tool.* 事件（DESIGN §2「有必要再补充」的口子），本条重新打开、暂不定。以下为原记。用户 2026-09-11：「为什么要会话还在，不是会全采上传么，或者我们干脆把transcript也定期保存一份呢」。
  §6 第 3 步回原始 transcript，它只在开发者本机。C02FM 上 Claude Code 2.1.260 的设置说明（2026-09-11 查）：transcript
  按 `cleanupPeriodDays` 清理、默认 30 天；desktop 与 Cowork 创建或最后写入的不在其内，另由
  `desktopSessionCleanupPeriodDays` 管，默认 0、不设上限。两条路：Pilot 全采上传，前提是先补上 §3 末的漏采——
  中断记录与每轮第一条人类输入正是判责最要紧的证据；或者定期把原始 transcript 存一份，最全，要连
  `<会话id>/subagents/` 一起存，单个能到上百 MB，含代码与 thinking 全文，存到哪、谁能看与 G9 是同一个问题，
  且得赶在清理之前。

### 11. 审计记录

四轮独立审计，都在合并之后跑，每轮的发现在下一轮之前改进正文与 demo；demo 的边界场景就是照这些发现搭的。
另有一轮与之并行的独立复核（第五轮）；第六轮换到另一台机器上，把全部六个 commit 审了一遍（见末尾）。前五轮都在 MacBook 上。
下面的「改成」写的是**那一轮修完时**的做法，后一轮又改过的另行标出。前五轮说的 §4①–④，第六轮之后是 4.2①–④。

**第一轮**审第一版 `514876d`（2026-09-11 00:13）：4 处错、8 处不准、6 个小问题。

| # | 第一版的做法 | 问题（均经实验复现） | 改成 |
|---|---|---|---|
| 错 1 | blame 影子历史末端、只滤掉 BASE 本身 | BASE 之前的旧行记在更老的提交上，被当成本 commit 的改动报出来；第一版 demo 的 BASE 恰好是根提交 | 影子历史的根是无父的快照提交，只报本 commit diff 里的行 |
| 错 2 | 方案原文写「父提交以来的快照」，demo 照做 | 上一次提交没带走的 agent 改动，在下一次提交里被判成 gap | 影子历史跨提交连续（主场景 A2、A3） |
| 错 3 | 部分暂存的差额记为 commit-time，报全部非 BASE 的行 | 被「改回去」的没改的行也被报出 | 差额归给提交时进行中的调用，只报 diff 里的行——第三轮改为按暂存区快照定出发点 |
| 错 4 | 快照用一份共用的独立 index，从空开始 | 已跟踪但匹配 `.gitignore` 的文件漏掉 | 每次复制一份真 index（边界 4） |
| 不准 5 | 共用 index；pre 与 post 按相邻顺序配对 | 并发快照撞 `index.lock`，fail-open 的 hook 会悄悄丢快照；交错时贴错 | 每份快照一个副本（边界 5）；按线程配对（边界 1、2）——第二轮改为按调用配对（边界 3） |

其余 7 处不准是措辞过度或转述不准：「大头」只有一个会话的依据、「代价都不在快照本身」说满了、DESIGN 引文不是逐字、
OPEN-ISSUES 的 G11 行复述过多并把 demo 结论写成一般结论、没写行移动要靠 `-M` / `-C`、「demo 没覆盖的」漏了前提。
6 个小问题是口径与引文细节，删掉的文件会让 demo 直接中止也在其中。

**第二轮**审修复 `224b884`：上一轮 18 条的原症状全部不再出现，但**修法本身引入或留下了 5 处错**、4 处不准、3 个小问题。

| # | 问题（均经实验复现） | 改成 |
|---|---|---|
| 错 1 | 影子历史改成跨提交连续后，还是一条所有 worktree 共用的 ref，别的 worktree 的快照交替接进来，把改动冲成 gap | `refs/worktree/` 每个 worktree 一条，登记表放本 worktree 私有目录。当时的验证场景证明不了这一条，第三轮换成边界 6 |
| 错 2 | 先暂存、后又改：提交的是暂存区里的旧版本，被记给提交者（第一轮就在，没抓到） | 差额上的行按行文本沿影子历史往回找——**修错了**，第三轮改为按 blob 查暂存区快照 |
| 错 3 | 改成复制真 index 时 `cp` 没带 `-p`，丢了 racy-git 保护，同一秒内的同长度改动快照漏掉 | `cp -p`（边界 14；第三轮改为直接测 snaptree） |
| 错 4 | 按新路径逐个 `git diff -- <文件>`，改名的文件整份被当成新增 | 一次 `diff -M` 解析全部文件 |
| 错 5 | `for f in $(git diff --name-only)` 拆词，`core.quotePath` 转义中文，这些文件的行被静默丢掉 | 同上，解析 `+++` 行——只修到空格与中文，第三轮改为 `-z` 取路径 |

4 处不准：文档说按 tool_use_id 配对、demo 却只按线程；被打断的调用「等同线程的下一个 pre」可能永远等不到（边界 10）；
`-M` 不只认移动也认复制，会把复制者写的行归给原作者（边界 12）；「demo 没覆盖的」仍漏了上面这些情形。
3 个小问题：旧值校验之外登记表也要原子地改；本台账第一版的四处毛病（把不准 5 并进了错 4、说 4 处错「都在 demo 的
归属逻辑」而错 2 其实在方案原文、「均已改」说满了、把 514876d 的日期写成 09-10）；§3 一处引号里的字不是 spec 原文。

**第三轮**审修复 `2f6c3a5`：第二轮 12 条里改名、`cp -p`、配对、打断、复制等 9 条修对了；错 2、错 5 **修错了**，
错 1 修对但验证场景不成立。另有 3 处错、3 处不准、5 个小问题。

| # | 问题（均经实验复现） | 改成 |
|---|---|---|
| 错 1 | 第二轮加的「按行文本往回找」对差额上的每一行都做：人在最后一个快照之后补的空行、`return None`，只要历史里出现过同样的行，就被记给别人——gap 被翻成 agent，比第一轮修完时还差 | 删掉按行文本搜；按 blob 查快照日志里的暂存区，定出暂存时的出发点（§4③；边界 9） |
| 错 2 | 暂存的那一版从没被快照拍到（人改、暂存、再改，都不经过 hook）时，仍记给提交者 | 同上：每次快照顺手记暂存区的 tree（边界 8） |
| 错 3 | 文件名含 `"`、`\`、tab 时 git 照样加引号，awk 取错路径，`set -e` 让整次归属中止，同一 commit 其他文件的行也丢 | 路径从 `-z` 的 name-status 取，行号用 blob 对 blob 的 diff 取，单个文件放进子 shell——「出错只跳过它」其实没做到，第四轮补上显式检查 |

3 处不准：边界 5（当时编号）证明不了 worktree 那条修法，换成现在的边界 6，并实测了两种串法各贴成什么；第一轮台账「不准 5」的
「改成」写成了第二轮之后的状态；本台账说「都已改在正文与 demo 里」又说满了。5 个小问题：第一个快照就是没有 pre 的 post 时
「起点不明」被根吞掉（已写进 §4②）；racy-git 场景没走 snaptree（改为直接测 snaptree）；按 tool_use_id 配对的前提是
PreToolUse 也给它（已写进 §4②）；`worktrees/<名>` 的「名」其实是 worktree id；demo 头注释的边界场景数写错。
（修复提交 `e2abcd4` 的说明里写「12 条修对 9 条，错 2、错 5 修错了」，漏数了「错 1 修对但验证场景不成立」这一条。）

**第四轮**审修复 `e2abcd4`（第一次跑时审计 agent 的输出超长被截断、没有结果，重跑一次）：第三轮 11 条全部修对，
其中错 2 在合并冲突下复发。另有 2 处错、3 处不准、3 个小问题，数量明显少了，且都在边角。

| # | 问题（均经实验复现） | 改成 |
|---|---|---|
| 错 1 | 合并冲突时整份暂存区记成 `-`，打断「暂存区已是这一版」那一段，干净合入的文件又被记给提交者 | 副本里只去掉未合并的路径再 write-tree（§4①；边界 15） |
| 错 2 | 第三轮改用 blob 对 blob 的 diff 时丢了 `--no-color --no-ext-diff`，用户开了 `color.diff=always` 或 `diff.external` 就一行都不报，也没有提示 | 加回来；边界 13 开着这两项配置跑 |

3 处不准：「单个文件出错只跳过它」只在最后那条管道失败时成立——子 shell 里 `set -e` 不起作用，前面的步骤失败会打出空行，
改为每步显式检查，并在边界 13 加了一个必然失败的子模块指针来走这条路；§4③ 写的「或 `commit -a`」与代码不符，代码只看
快照时的暂存区，已改写规则描述，并把改走又改回的偏差写进 §7；第一轮错 3 的「改成」后来又被替换过却没标出（已补标）。
3 个小问题：§7「按『暂存发生在哪一段』归属」说宽了，只有出发点工作树里没有的行才归给那一段（已改）；标签「快照开始前已在
暂存区里」TODO 里没提（已写进 §4③）；`e2abcd4` 说明的漏数（见上）。另补：二进制文件原来静默不报，现在给一行提示。

四轮的教训是同一条，一轮比一轮扎眼：**demo 的场景是照着想证明的结论搭的，恰好绕开了会出错的情形；修复也一样，
只修到了被指出的那个症状，修法自己带进来的问题（共用 ref、`cp` 丢 mtime、按行文本搜、丢掉的 diff 选项）照样没有场景去碰。**
第三轮的错 1 最典型：它不是没修，是修的时候为了让新场景通过，引入了一个比原问题更坏的启发式。第四轮的发现少了、
且都在边角；还没搭过场景的情形见 §5「demo 没覆盖的」，那里照样可能藏着错。

**第五轮**（另一会话从第一版 `514876d` 独立起审，与前四轮并行，2026-09-11 上午；修到 `02e3685` 后再对表）：
4 条与前四轮重合、已被修掉（父提交重开、部分暂存、共用 index 撞锁、并发窗口），另有 2 处错、6 处补充，都已写进正文。

| # | 问题 | 改成 |
|---|---|---|
| 错 1 | 失败的工具调用没有 PostToolUse（文档：失败走 `PostToolUseFailure`）。Bash 非零退出很常见，只挂 PostToolUse 会让它们一直「进行中」，同一轮后面的改动全被标并列 | 两个事件都挂（§4②、§9）——第六轮：打断与权限被拒两者都不发（错 6、7） |
| 错 2 | 只报新侧的行，删掉的行没有记录，而删检查正是典型 bug | `blame --reverse` 找删它的那一步（§4③；边界 16 实测）——第六轮：起点不对（错 8） |
| 补 1 | 后台运行的 Bash 在 PostToolUse 之后还在写文件，改动落进 gap | 打标、之后的 gap 按歧义看（§7） |
| 补 2 | PreToolUse 字段集、子 agent 区分、权限前触发：官方文档有答案，一手未测 | §4①、§7——第六轮：「字段集相同」不对（不准 5） |
| 补 3 | 代价初量：热态一次快照约等于两次 `git status`（2.6k 文件 ~45ms，30k 文件 ~80ms），冷只在第一次 | §7 表——第六轮：只在干净工作树上成立（不准 2、11） |
| 补 4 | 先量「多会话 commit 有多少」再决定走规矩还是走机制（用户提的 worktree 规范）；本仓样本 2/7 确定多会话、5 个没 trailer 比不了 | §9 第 1 个数、§10——第六轮：样本不成立（错 1、2），脚本两头偏（错 3） |
| 补 5 | 粒度可能选细了：判责要的是轮，UserPromptSubmit + Stop 就够分「agent 改的」与「人改的」 | §10——第六轮：「并发与嵌套大半消失」说错了（不准 3） |
| 补 6 | §6「不是 agent 写的，基本是人」与 §7「gap 不等于人」口径不一；归属记录 post-commit 写、下个 commit 才入仓 | §6 表、§10——第六轮：「事后写」不是 sync 的原话，notes 也没有这一关（不准 9） |

**第六轮**（2026-09-11 下午，在另一台机器 C02FM 上；四路并行：demo 与算法、测量脚本与样本、hook 文档、引文与台账）
审 `514876d`–`26a21d1` 全部六个 commit：错 10 处、不准 11 处、小问题 8 个，都经实验或一手出处复现——demo 类在 C02FM
的 git 2.37.1 上跑，hook 类对 hooks 文档（code.claude.com/docs/en/hooks）与 C02FM 上的 Claude Code 2.1.260。
**处理**：前 3 处错动摇的是「要不要做快照」，主方案随之改为 4.1；4.2 的 7 处错先记在这里，做 4.2 时再修，正文只改了
事实性的说法，demo 没动。

| # | 问题 | 处理 |
|---|---|---|
| 错 1 | 旧 §10「main 上 09-09 一天有 5 个会话先后在同一条分支上提交……同一分支多会话串行是常态」：main 的 reflog 是 15 次直接提交（全出自一个会话）加 6 次从 `claude/*` worktree 分支快进合并，另外 4 个会话各在自己的 worktree 里提交 | 删掉，改作 worktree 隔离起作用的证据（§4 开头） |
| 错 2 | 旧 §9「7 个可查、2 个确定多会话」复现不出：数出自 MacBook 上另一个 clone；`d298f87` 在 C02FM 上是单会话（`3962d775`×33），那边把父提交时间窗里另一个 clone 同名文件的改动算了进来；`514876d` 没有 trailer、窗口 6 小时 | 改写（§9）；C02FM 重跑：多会话 0、单会话 1、无匹配 39 |
| 错 3 | 测量脚本两个方向都偏，不是下界：别的 worktree / clone 的同名文件、失败的 Edit（C02FM 上 4925 次 Edit / Write 里 167 次失败）都算；从别处启动的会话扫不到（最近 40 个 commit 里 19 个出自这样的会话）；窗口从父提交算起，漏掉 G11 的核心场景；C02FM 上 32 个有 transcript 的 commit 只命中 1 个（多数改动走 Bash） | 脚本头与输出里的错话已改；重写列进 §9 |
| 错 4 | `refs/worktree/` 上的影子历史会被别的 worktree 的 gc 回收，之后那边 `git gc`、`git log --all` 报 `bad object`；`main-worktree/refs/worktree/…` 在 2.37.1 上解析不了 | 4.1 用共享命名空间 `refs/vibetrail/…`（实测 gc 后还在）；4.2 未改，MacBook 的 2.39.5 待复测 |
| 错 5 | 快照失败时登记照做：pre 那次失败，之前的人手改记给这次调用、不标起点不明；post 那次失败，调用的改动落成 gap | 未修（4.2② 写了改法） |
| 错 6 | 用户打断时 Stop 不触发、PostToolUseFailure 也不发，被打断的调用挂到下一次 UserPromptSubmit，人打断后的手改全记给它；边界 10 演的顺序正好相反。C02FM 上 vibetrail 10 个会话里 5 个有过调用中途被打断，共 12 次，到下一句人话中位数约 5 分钟 | 事实已改进 4.2②、§5、§7；demo 未改 |
| 错 7 | 权限被拒（手动拒绝、deny 规则、别的 hook 拦下）只有 PreToolUse，没有任何结束事件，这一轮后面的改动全变并列；`PermissionDenied` 只在 auto 模式发 | 未修（4.2②：加挂 PermissionDenied 与 PostToolBatch） |
| 错 8 | 删行的反向 blame 从影子历史的根起算：根里没有这个文件就报错，根之后才加、本 commit 删掉的行追不到；「出发点与上面相同」连边界 16 自己都过不了 | 未修（4.2③ 写了改法，三个场景实测通过） |
| 错 9 | merge 只对第一父提交做 diff：冲突 merge 把侧分支的行整片记给跑 merge 的调用；干净 merge 与 pull 只跑 post-merge，一行不报 | 未修（4.2③：多父提交只报 `diff-tree --cc` 的新行） |
| 错 10 | 跨仓、跨 worktree 的改动（OPEN-ISSUES K2，本项目自己就这样）记给那边碰巧在跑的别的会话、或成 gap、或那边根本没快照 | 4.1 的限制写进 §7；4.2 未修（4.2② 写了改法） |

11 处不准：① 旧 §9「在 agentDock 上量」——agentDock 当前分支没有 trailer，比不出「trailer 之外的会话」（§9 前置）；
② §7 代价表只在干净工作树上量，未跟踪文件每次快照都重哈希，冷的不只第一次，占盘与 post-commit 归属都没量（§7 已补数）；
③ §10「按轮拍，§7 里并发与嵌套的问题大半消失」——§7 当时没讲嵌套，按轮拍时两个会话的轮一重叠就全并列（已改）；
④ 挂 Agent 工具时，前台子 agent 的改动全和外层调用并列（§7 已补「嵌套」）；⑤ hook 字段与事件：「字段集相同」不对，
Bash 非零退出文档已答、grep 类退出码 1 不算失败，收尾事件漏了 StopFailure，后台任务不止 `run_in_background`，轮末只能
关本线程的（4.2 已改）；⑥ 用户的 git 配置仍会让输出变形：textconv、`-diff` 属性、`blame.ignoreRevsFile`（4.2③ 已记）；
⑦ `-c gc.auto=0` 的理由反了（已改）；⑧「最新的 6 个 commit 都是从本机这个没装 hook 的 clone 提交的（vibetrail-doctor
报致命）」——doctor 报致命是因为本仓从来没有 vendored 运行时，与 hook 无关；「本机」时指 MacBook、时指 C02FM（已标明）；
⑨ §10「与 sessions 投影『事后写』是同一个问题」——sync 头注释的原话是「事后投影」，是有意的选择，notes 也没有
「下个 commit 才入仓」（已改）；⑩ §9 把 spec §4.5 的「约 3%」当行覆盖率，原文是调用次数之比（已改）；
⑪「约等于两次 git status」只在小仓成立，30k 文件时是 80ms 对 108ms（已改）。

8 个小问题：引号里的字不逐字 3 处（§4 引 spec §4.5 丢了内层引号，第四轮、第五轮台账各一处转述，已改）；「符合 D2」
指的是 DESIGN 的 D2（已改）；OPEN-ISSUES 引言漏了 G10（已改）；第一轮台账「外加」应为「也在其中」（已改）；边界 14 的
对照行依赖秒边界（§5 已记）；在根提交上跑 attribute 直接中止（`HEAD^` 报错）；测量脚本的目录名映射（Claude Code 把
所有非字母数字字符换成 `-`，超过 200 字符截断）、merge 被跳过、改名只看新路径；hook 实现要点——`exit 0` 且不输出、
显式超时、SessionEnd 只有 1.5 秒、子 agent 只看 `agent_id`（已写进 §9、4.2）。

核过没有问题的：demo 输出与 §5 逐字一致；§3 的 14 处 Pilot 行号（C02FM 的 `~/program/go/src/loongsuite-pilot` @
`d4ab8b6d`，`d4ab8b6d...4e59a5bc` 只改了 4 个 qoder-trace 文件）；DESIGN §2.1–2.5 与 Q5、spec 各节、采集清单 §1.2b
的数字；前五轮的计数；所有「边界 N」的指向。

第六轮的教训和前四轮是同一个毛病换了地方：前五轮都在一台机器上，**样本结论没在另一台机器上复现过就进了决策依据**；
测量脚本也从没拿它要量的那个场景（同一个 worktree 里 A 改、B 提交）试过——「照想证明的结论搭场景」从 demo 挪到了测量上。

## G12 加 Codex / Cursor 支持：调研、方案与第一版实现（2026-09-17）

> 用户原话（09-17）：「根据现在已完成的采集，去teamai和pilot看一下，要增加对codex和cursor的支持，先做个调研，看看有没有什么问题并写个方案」；
> U9 原先默认不做的理由（同日补）：「原定不做适配是打算把采集的内容先确定以及流程打通再去做其他企业的，这样会快不少」。
> 现状：采集内容 09-16 已对齐协议（K17–K24）、全采已定（DESIGN D14）；**流程还没打通，push 没做**（G7 拆解）。
> 依据：Codex 源码（`~/program/go/src/codex` @ `536f86e`，08-21）、本机 ChatGPT.app 内置的 `codex-cli 0.154.0-alpha.6.2` 二进制字符串、本机 2 个桌面版会话（09-16）；
> Cursor 3.20.21 的 app bundle 与官方 hooks 文档（09-17 取）。teamai / Pilot 的做法只用了 `third-party/` 里已有的分析，没重读两家源码。
> 两家都**还没有打断、拒绝、子 agent 的真实样本**，标「待实测」的都要先过 §4。

### 0. 实现状态（09-17 第一版，还没实测）

用户 09-17：「接下来去实现codex和cursor的采集。至于数据的push，另一个对话完成claude的push，他们可以直接用」（U19 关）；
「codex和cursor的transcript内容和格式和cluade应该是不一样的」；「如果用户电脑同时拥有claude，codex和cursor，我觉得要让他们判断下装哪个，teamai怎么做的」。

- **不拆 Claude 的代码**（与 §5「结构」原计划不同）：push 那个对话同时在改 `cli.mjs` / `hook.mjs`，两家加在新文件里，共用文件只插几行，少冲突。Claude 那一路一行没动，test-map 246/246、test-hook-flow 145/145（与 U18 合并后）原样全绿。
- `tools/lib/agents.mjs`：两家共用、与格式无关的部分（门控、事件头、超 1 MiB 去正文、写 spool、轮次证据、文件相对路径、改宿主 hooks.json 的原子写与备份、`agents=` 选择）。
- `tools/lib/codex.mjs`：挂 5 个 hook 写 `~/.codex/hooks.json`；Stop / SessionEnd / SessionStart 补做时按 rollout 自己的记录类型映射（§5「Codex 怎么采」），子 agent 按日期目录找 `source` 指回父线程的 rollout；拒绝按 §3 问题 2 的双条件判；doctor 查信任记录与特性开关。
  本机 2 份真实会话映射出 28 条事件全部过 schema，条数与记录对得上。读取照 U18：分段读完，从没读过的 rollout 第一次只读补采窗口（`backfill_days`）内的记录。
- `tools/lib/cursor.mjs`：**只用 hook 入参、不读 transcript**（格式没样本），挂 10 个事件写 `~/.cursor/hooks.json`；每个 hook 先写应答（beforeSubmitPrompt 放行、其余 `{}`）再丢后台；`user_email` 不出本机；token 原样放 `cursor.usage_raw`、不填 `payload.usage`。
- **init 选装哪几家**（照 teamai `init.ts:592` 的 `promptForSelfModeAgents`）：`--agents claude,codex,cursor` 指定 > 不在终端里就挂本机检测到的 > 终端里第一次列出来选（回车 = 检测到的全部）；选择记进 config 的 `agents=`，重跑 init 沿用；没选的那家把自家条目删掉；uninstall 三家都清；doctor 按选择分家报。运行时在临时目录时不碰真实的 `~/.codex`、`~/.cursor`（同 settings 的保护）。
- 回归 `tools/test-agents.sh` 44 项（含 U18 同款的补采窗口与分段读）：init 选择与装卸对称、未登记零写入、Codex 一整段会话（轮中提交、apply_patch 的 files、子 agent、人拒绝 / 没证据的拒绝、插话、打断补 cancelled、幂等、schema）、Cursor 一整段（应答、工具、子 agent、files、commit、没等到 stop 的轮、邮箱不出本机、schema）、真实配置没被动过。**fixture 是照源码与本机桌面版的形状手搭的**，§4 实测后换成真记录。
- **09-17 本机实测（Codex CLI 0.154 的 `exec`，vibetrail 仓里跑一个只读小任务）**：真装（`init --agents claude,codex`）后跑一次，`--dangerously-bypass-hook-trust` 只对这一次调用跳过信任、不写信任记录。SessionStart / UserPromptSubmit / Stop / SessionEnd 都触发了，出 10 条事件：会话起止与 turn.start 是 hook 发的（turn.start 带轮起 HEAD），message.user、tool.request / tool.end、2 条 message.assistant、带用量与 vcs 的 turn.end、base_instructions 从 rollout 推，全部过 schema；hook 的 `turn_id` 与 rollout 的相同；surface 是 cli。另把本机 09-16 桌面版的真实会话在沙箱里走了一遍 hook 路径：25 条过 schema、65 条记录全读、没有不认识的类型。**还没测**：拒绝、打断、插话、子 agent（exec 下做不出来，要人在桌面版或 CLI 交互里操作），桌面版里 hook 跑不跑。**信任入口**（用户 09-17 截图）：桌面版「设置 → 钩子 → 用户配置」里逐条点「信任」；那里还报了加载问题「clamping SessionEnd hook timeout to 3s」——Codex 的 SessionEnd 超时最多 3 秒（`hooks/src/events/session_end.rs:23`），已改成 3，SessionEnd 那一条要重新信任一次（超时也算进信任哈希）。
- **09-17 桌面版实测**（用户在 vibetrail 仓续接旧会话：一轮正常、一轮 3 秒后按停止、重发后轮中插一句）：桌面版里 UserPromptSubmit / Stop 都触发，turn.start 带轮起 HEAD；按停止 → `turn_aborted`（interrupted）→ `turn.end` interrupted + 分歧、vcs 取下一轮补的 gap 快照；插话是同一轮第二条 UserMessage → `message.user` queued（§7 的假设成立）；用量逐次与整轮都对。**发现一处误判并修了（codex-v2）**：模型 `sed` 读 vibetrail 自己的源码，输出里夹着 `rejected by user approval settings`，v1 在整段输出里搜，判成策略拒绝、这次成功调用的 `tool.end` 也丢了（diverge-v1「只读字段、不 grep 原文」的老坑）；v2 只认整条输出就是那几句，回归加了一条（旧代码上会红）。**还没看到**：续接的旧会话没有 session.start（会话在信任之前就开着，待开新会话再看）；拒绝、子 agent。另：新版 Codex 的 `exec` 工具里跑的命令另有 id（`exec-<uuid>`），与调用 id 对不上，所以耗时只能按记录时间差、退出码和 `declined` 挂不上调用——人拒绝的判定要等拒绝样本再定（可能按时间窗口关联）。
- **codex-v3（09-17，采纳 Codex 在桌面版测试会话里给的意见 1、3、5）**：① 人拒绝要有弹框证据落在「调用发出 → 结果回来」之间（前后各放 2 秒），一次弹框只配一次拒绝——v2 只要同一轮弹过框就算；③ doctor 照 Codex 的算法核信任哈希（`{event_name, matcher?, hooks:[handler，async 缺省补 false]}` 键名排序、紧凑 JSON、sha256，拿本机刚信任的 5 条真实记录核过），分「被关掉 / 没信任 / 改过」报，原来只看有没有记录；⑤ 轮结束后、下一轮开始前到来的 response_item 不再挂到已关的轮上，只计数（state 的 `orphan_items`）。意见 2（子 agent 的 hook）等样本；意见 4（真实验证不够）属实，文档一直标着；另发现桌面版代码模式下人拒绝可能整条输出匹配不上（漏报），等拒绝样本。回归 50 项，新断言在 v2 上挂 6 条。本机那个桌面版会话 09-17 按用户要求清掉由 rollout 推出的块、用 v2 重采（93 条过 schema、假拒绝没了、丢的 tool.end 补回）。
- 还没做：§4 实测三遍；K27；Codex 桌面版的信任入口；`projects pick` 的候选仓算上 Codex 的 cwd；DESIGN 的「多家」一节（实测后写）。

### 1. 结论

- **Codex 能做到和 Claude Code 同一套内容，几处比 Claude 还好。** 它的 hook 就是照 Claude 做的（`features/src/lib.rs:96`「Claude-style lifecycle hooks」），事件名和入参几乎一样；
  会话记录（rollout）里轮次起止、打断、每次模型调用的 token 都是类型化记录，不用匹配字符串。两个硬坑：**用户级 hook 要人在 Codex 里信任过才跑**；**人拒绝审批没有类型化记录**。
- **Cursor 能做会话、轮次、工具调用、子 agent、改了哪些文件；分歧和 token 做不全。** hook 事件多、每个都带 `transcript_path`，但 hook 里没有 token，
  人在审批框里拒绝没有 hook；transcript 的格式和位置文档没写，本机没有样本。
- **代码约一半能共用**：门控、spool、event_id、git 快照与本轮 commit、锁、offset 信任检查、补做调度。按家分开的是 hook 入参、会话记录映射、装 hook 的配置文件、doctor、补做时去哪找会话文件。

### 2. 两家能给什么（对照现在从 Claude Code 采的）

| 采集项 | Claude Code（现状） | Codex | Cursor |
|---|---|---|---|
| hook 配置 | `~/.claude/settings.json`，热加载 | `~/.codex/hooks.json` 或 `config.toml` 的 `[hooks]`；特性 `hooks` 是 Stable、默认开（`features/src/lib.rs:1038-1040`）；**用户级 hook 没被信任不跑**（问题 1）；热加载待实测 | `~/.cursor/hooks.json`；项目级 `.cursor/hooks.json` 要工作区被信任；企业 MDM / 团队下发优先；文档说热加载 |
| 事件 | 挂 5 个 | 11 个：SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / PermissionRequest / Stop / SessionEnd / PreCompact / PostCompact / SubagentStart / SubagentStop（`hooks/schema/generated/`；抽查的几个装的 0.154 里都在） | bundle 里搜到 20 个：sessionStart / sessionEnd / beforeSubmitPrompt / stop / afterAgentResponse / afterAgentThought / preToolUse / postToolUse / postToolUseFailure / before·afterShellExecution / before·afterMCPExecution / beforeReadFile / afterFileEdit / preCompact / subagentStart / subagentStop / 两个 Tab 事件；文档另有 workspaceOpen 等应用级事件 |
| 会话 / 轮次 / 会话记录 | `session_id` / `prompt_id` / `transcript_path` | `session_id` / `turn_id` / `transcript_path`，每个事件都带（SessionEnd 没有 `turn_id`） | `conversation_id` / `generation_id` / `transcript_path`（关了 transcript 时是 null）；sessionStart / End 另有 `session_id`。`generation_id` 是一轮还是一次模型调用，待实测 |
| 工作目录 | `cwd` | `cwd`；rollout 的 `turn_context.workspace_roots` | `workspace_roots`（可能多根）；工具事件带 `cwd` |
| 打断 | 没有 hook；transcript 里只有正文 `[Request interrupted by user`（diverge-v1） | 类型化的 `turn_aborted`，reason `interrupted` / `replaced` / `review_ended` / `budget_limited`，始终落盘（`rollout/src/policy.rs:99-105`、`protocol/src/protocol.rs:3988`） | `stop.status` = `aborted`（按停止时 stop 来不来文档没写，待实测）；`postToolUseFailure.is_interrupt` |
| 人拒绝审批 | 字符串判据 + PermissionRequest 分「拒绝」与「按停止」（D9） | **没有类型化记录**（问题 2） | **没有 hook**（问题 2） |
| 一轮答完 | Stop + 等 `stop_hook_summary`（K24） | `task_complete`（`duration_ms`、`last_agent_message`），只在真答完时写，Stop 被别的 hook 拦下不会提前出现 | `stop.status` = `completed` / `error`，`loop_count` |
| token | assistant 记录的 `usage` | 每次模型响应一条 `token_usage_record`（`usage` / `turn_token_usage` / `thread_token_usage`）；cached 是 input 的子集（`protocol.rs:2245` 的 `non_cached_input` = input − cached），与协议口径一致；`cache_write_input_tokens` 算不算在 input 里待核 | 文档说 hook 里没有（只有 preCompact 给上下文占用）；**09-17 实现时查 3.20 bundle：stop / afterAgentResponse 的请求定义带 `input_tokens` / `output_tokens` / `cache_read_tokens` / `cache_write_tokens`**，缓存算不算在 input 里没核，第一版原样放 extensions |
| 调用 trace | assistant 记录 + tool_result | 桌面版记录里每项 `item_completed` 带 `started_at_ms` / `completed_at_ms`，命令执行带 `status` / `exit_code` / `duration` | preToolUse / postToolUse（带 `duration`）/ postToolUseFailure；shell / MCP / 文件的专用事件与通用工具事件重复，按 `tool_use_id` 去重（协议兼容表也这么要求） |
| 子 agent | `subagents/agent-<id>.jsonl` + meta | 独立 rollout，`session_meta.source` = `SubAgent(ThreadSpawn{parent_thread_id, depth, agent_path, agent_nickname, agent_role})`（`protocol.rs:2658`）；hook 有 SubagentStart / Stop（带 `agent_transcript_path`） | subagentStart（`subagent_id` / `subagent_type` / `task` / `parent_conversation_id` / `tool_call_id`）、subagentStop（`status` / `duration_ms` / `modified_files` / `agent_transcript_path`） |
| system prompt | `prompt_snapshot` 附件 | `session_meta.base_instructions`（本机样本有） | 没有 |
| 改了哪些文件 | Edit / Write / Read 的结果 | apply_patch 调用；桌面版记录里的形态待实测 | `afterFileEdit`（`file_path` / `edits`）、subagentStop 的 `modified_files` |
| 运行形态 | CLI、desktop | CLI、`exec`、桌面版、IDE 扩展；hook 在 core 里调（`core/src/hook_runtime.rs`），按理各形态都跑，桌面版待实测。本机桌面版 `originator` 是 `Codex Desktop`、`source` 却是 `vscode` | IDE、CLI；云端 agent 只跑部分 hook（没有 sessionStart / End）；Tab 只有两个 Tab 事件 |

### 3. 问题

1. **Codex 的用户级 hook 要人信任才跑，改一个字就要重新信任**（最大的坑）。`hooks/src/engine/discovery.rs:655-700`：非托管的 hook，要 config 里
   `[hooks.state."<文件路径>:<事件>:<组序号>:<条序号>"]` 的 `trusted_hash` 与当前哈希相同才进执行列表；哈希算的是事件名加整组配置（命令、超时、async 都算），
   对不上是 Modified，同样不跑。后果：init 写完 hooks.json 什么都不会发生，要人去 Codex 里信任；升级改了命令串或超时就静默停采；别的工具在同一事件里往我们前面插一组，序号变了 key 就变，也会停。
   对策：**不替人写 `trusted_hash`**（那是 Codex 给人的安全确认，自己算好写进去等于绕过它）；命令串与超时定死、永远不改，升级只换 `~/.vibetrail/bin` 里的文件；
   条目追加在每个事件末尾；init 明说要去 Codex 里信任这几条；doctor 按同一算法算哈希，报「未信任 / 已改动 / 被 `[features] hooks = false` 关掉」。
2. **人拒绝审批，两家都没有可靠的类型化信号**，而这是人机分歧那一路的核心。
   - Codex：审批请求事件不落 rollout（`policy.rs:155-183` 归在不持久化那组）；拒绝只体现在工具输出 `exec command rejected by user` / `patch rejected by user`，
     而源码注释自己说一部分非用户的失败也走这条（`core/src/tools/events.rs:436-441`，带 TODO）。PermissionRequest hook 能证明「弹过框」，但入参没有 `tool_use_id`。
     对策：同一轮里「PermissionRequest 记到同名工具」且「输出是 rejected by user」才判人拒，发 `permission.decision`（decided_by user）；只满足一条的发 `tool.end(failed)`、不标分歧——
     宁漏不错，与 diverge-v1「只认字段」一致；`turn_context.approval_policy` 为 `never` 的轮不可能有人拒。协议不许按工具名硬关联 `call_id`，这种判定不带 `call_id`。
   - Cursor：人在审批框里拒绝没有 hook；hook 自己返回 deny 时 after* 不来。`postToolUseFailure` 有自由字符串 `failure_type` 与 `is_interrupt`，拒绝时来不来、取什么值要实测；
     拿不到就在 `capabilities` 里不声明 `permission.decision`，不猜。
3. **Codex 的会话记录格式在换代**：有 legacy 与 paginated 两种 history mode，源码默认 legacy（`protocol.rs:711-715`），本机桌面版 0.154 写的是 paginated（`item_completed` 带 TurnItem），
   两种模式落盘的事件不一样（`policy.rs:88-134`）。CLI 写哪种待实测。
4. **Cursor 的 transcript 是黑盒；token 口径没核**（09-17 实现时补：3.20 bundle 里 stop / afterAgentResponse 的请求定义带 token 数，文档没写，缓存算不算在 input 里要实测；下文「token 只可能在本地 SQLite」作废）。文档不写 `transcript_path` 的格式与位置，本机 `~/.cursor/projects/` 下没有 agent-transcripts；token 只可能在本地 SQLite（`state.vscdb`，原地改写的 KV）里，
   读 SQLite 要 `node:sqlite`（node 22.5 起才有，本机是 21.4），不符合「只依赖 node ≥ 20、只用内建模块」（D12），退路是调 macOS 自带的 `/usr/bin/sqlite3`。
5. **Cursor 的轮次怎么切还不确定**：`conversation_id` 与 sessionStart 的 `session_id` 是否同值、`generation_id` 是一轮还是一次模型调用、按停止时 stop 来不来，决定 turn.start / turn.end 能不能成对（A2）。
6. **`agent.name` 与协议推荐值不一致**：我们发 `claude-code`，协议推荐 `claude` / `codex` / `cursor`，collector 按 user + workspace + `agent.name` + `session_id` 关联会话。
   push 前改不花钱，推出去再改同一会话会分成两份。立 K27。
7. **没有语料，准确率量不了**。Claude 的判据是 755 个会话实测精确率 100%；Codex 本机只有 2 个会话（没有打断、拒绝、子 agent），Cursor 是 0。
   两家的判据只能先照源码 / 文档写、拿人造场景验，文档里标「未量」，攒够真实会话再量。
8. **代码要拆**：`runHook` 里通用部分与 Claude 专有部分（Stop 等答完标记、`subagents/` 目录、`~/.claude/projects` 补做）在一个函数里；`map.mjs` 约 1200 行全是 Claude transcript；
   `cli.mjs` 的 init / doctor / projects pick 只认 `~/.claude`。

能直接借的（`third-party/` 已有分析）：Pilot 判 Codex 打断用类型化的 `turn_aborted`、不匹配字符串（`docs/codex-aborted-turn-recovery.md`）；Pilot 对 Codex 是 hook 加轮询 `~/.codex/sessions`
两条入口，轮询出的事件用确定性 id 去重；teamai 的 Codex token 读 rollout 的 `token_usage_record`，改 `~/.codex/config.toml` 用文本手术保注释（我们写 `hooks.json`，不碰 TOML）。
别学的：teamai 把 Cursor 的 `workspace_roots` 第一项当 cwd（多根工作区会归错）；Pilot 的 `cursor-cli` 声明了 hook 模式但 `events: []`。

### 4. 先做实测（每家一遍人工演示，用户在场）

装一个只把 stdin 落盘的探针（照 `experiments/hook-probe.sh`；要写 `~/.codex/hooks.json` / `~/.cursor/hooks.json`，测完卸掉），Codex 桌面版、Codex CLI、Cursor IDE 各走一遍同一个脚本：
普通一轮 → 轮中提交一次 → 拒绝一次命令 → 拒绝一次改文件 → 工具跑到一半按停止 → 排队或插话一句 → 起一个子 agent → 手动压缩 → 退出。会话记录拷进 fixtures。要回答：

- Codex：桌面版在哪信任 hook、改命令后是否真停；hooks.json 是否热加载；拒绝与按停止在 paginated 记录里的样子；子 agent 的派活调用 id 在哪；apply_patch 与 AGENTS.md 的形态；CLI 写哪种 history mode。
- Cursor：`transcript_path` 的位置、格式、是否只追加；按停止时 stop 来不来、status 是什么；拒绝时 postToolUseFailure 来不来、`failure_type` 取值；`generation_id` 与轮的关系；
  before* 事件什么都不输出时是否照常放行。

### 5. 方案

**顺序**（U19，**09-17 用户定：push 由另一个对话做完 Claude 的，两家直接复用；适配现在就做**，见 §0）。原先的倾向是先打通 push → Codex → Cursor，理由是用户说的「先把内容定下来、流程打通」：
push 打通后采集端要是还要改内容，在一家上改比在三家上改便宜。Codex 在前：hook 与 Claude 同构、记录类型化，成本低；Cursor 分歧与 token 拿不全，等实测结论再定映射。

**结构**：一个运行时，按家分适配层，不做插件、不构建（照 D12）。
- `lib/hook.mjs` 只留通用部分：门控（cwd → 主 checkout → 登记表）、会话锁、spool、event_id、git 快照与本轮 commit、轮次证据文件、offset 信任检查、补做调度。
- 新增 `lib/agents/{claude,codex,cursor}.mjs`，每家导出同一组东西：入参归一（会话 / 轮次 / 会话记录路径 / cwd / 事件名）、挂哪些事件与超时、配置文件读写、
  会话记录映射（Claude 的就是现在的 `map.mjs`）、补做时去哪找会话文件、doctor 检查项、`agent.name` / version / surface。
- hook 命令多一个家名参数：`vibetrail-hook codex Stop`；Claude 的老条目不带，照旧当 Claude，不用重跑 init。
- Claude 的 state、spool 路径与 event_id 算法不改（已有数据与 golden 不动、不升 rule_version）；新两家的 `_key` 前面加家名。会话 id 都是 UUID，state 目录不另分家。
- 拆的时候先只挪 Claude 的代码、不改行为：test-map 的 golden 与 test-hook-flow 原样全绿才算挪完（D12 移植同一个办法）。

**Codex 怎么采**：
- 挂和 Claude 同名的 5 个：SessionStart / UserPromptSubmit / Stop / SessionEnd / PermissionRequest，写 `~/.codex/hooks.json`；SubagentStart / Stop 不挂，子 agent 从 rollout 推（照 D13）。
  同步的丢后台立刻退出、stdout 为空（照 DESIGN §3.4）。
- 轮次：`turn_id` 直接当 turn_id；UserPromptSubmit 发 `turn.start`、记轮起快照；Stop 时读 rollout 到 `task_complete` / `turn_aborted` 再关轮，要不要等、等多久照 K24 的办法实测。
- 打断：`turn_aborted`（interrupted）→ `turn.end`（code `interrupted` / category `cancellation`），带被打断的回复与之后人的下一句（规则同 Claude）；`replaced` / `budget_limited` 这类不是人发起的，不标分歧。
- 拒绝：问题 2 的双条件。
- trace：每条 `token_usage_record` 一条 `message.assistant`（usage 按协议字段直接映射）；每个命令 / patch / MCP 的 `item_completed` 一条 `tool.end`。
- 子 agent：独立 rollout 按 `parent_thread_id` 挂回父会话，照协议兼容表「子 Agent 使用独立实例关系」用 `agent_instance_id` 区分；字段细节等样本。
- system prompt：`session_meta.base_instructions` → `ext.codex.base_instructions`，按 sha256 去重（同 Claude 的 `prompt_snapshot`）。
- 补做：SessionStart 时扫 `~/.codex/sessions/<年>/<月>/<日>/` 最近的 rollout，按 `session_meta.cwd` 归仓；不读 `state_5.sqlite`。
- surface 看 `session_meta.originator`，不看 `source`。

**Cursor 怎么采**（映射等 §4 的结论）：
- transcript 够用（有正文、有工具调用、只追加）：只挂生命周期那几个（sessionStart / beforeSubmitPrompt / stop / sessionEnd），其余从 transcript 推，与 Claude 同形。
- 不够用：再挂 preToolUse / postToolUse / postToolUseFailure / subagentStart / subagentStop / afterFileEdit，按 `tool_use_id` 去重；代价是每次工具调用多起一个进程（D13 不挂 Claude 的 PreToolUse / PostToolUse 就是为这个）。
- before* 一律不输出决定、exit 0，不影响放行。token 不填；分歧只报确认拿得到的；`capabilities` 按实测如实声明。
- 多根工作区：每个根分别门控、分别分配 workspace_id（协议要求），会话挂在哪个根暂不定。

**安装与自检**：init 看本机装了哪几家（`~/.codex`、`/Applications/Cursor.app` 或 `~/.cursor`）就挂哪几家，`--agents claude,codex,cursor` 可指定；每家各自备份、各自卸载。
doctor 分家报：Codex 的信任状态与特性开关；Cursor 有没有企业 / 团队 hook 盖过、`transcript_path` 是不是 null。`projects pick` 的候选仓把 Codex rollout 里的 `cwd` 也算上。

### 6. 拆解

- [ ] push（另一个对话做，两家复用；U19 关）
- [ ] K27：`agent.name` 改成 `claude`（push 前）
- [ ] §4 实测三遍，会话记录进 fixtures，按实况改判定、升 `codex-v1` / `cursor-v1`
- [x] ~~拆适配层~~ 改为不拆：两家加在新文件里（§0，与 push 并行少冲突）；Claude 的回归原样全绿
- [x] Codex 第一版（09-17）：rollout 映射、拒绝双条件、hooks.json 读写、信任记录检查、补做、doctor；回归在 `tools/test-agents.sh`
- [x] Cursor 第一版（09-17）：只用 hook 入参；实测后再定要不要改成读 transcript
- [x] init 选装哪几家（照 teamai）、uninstall 三家都清、doctor 分家报
- [ ] ~~Codex 桌面版的信任入口~~（设置 → 钩子，09-17）；`projects pick` 算上 Codex 的 cwd；Cursor 的 token 口径
- [ ] 文档：DESIGN 加「多家」一节（实测后）；README / DEMO 同步；中心表关 G12

### 7. 待定（先记录、暂不定）

- ~~先打通 push 还是先做适配（U19，倾向先 push）~~ 09-17 用户定：并行，push 由另一个对话做。
- ~~Cursor 要不要读本地 SQLite 补 token~~ 不用读：hook 请求里就有 token 数（§2），只剩口径待实测。
- 实测要核的实现假设（第一版按这些写的）：~~Codex 的 hook `turn_id` 与 rollout 的 `turn_id` 同值~~（09-17 CLI exec 实测成立）；子 agent 线程自己的 hook 触发不触发、入参里的 `session_id` 是谁的；
  子 rollout 的 `source` 序列化键名；paginated 下 CommandExecution 的 `id` 是不是 `call_id`；~~一轮里第二句 UserMessage 是 steer 插话~~（09-17 桌面版实测成立）。
  Cursor 的 `generation_id` 是一轮；子 agent 的 hook 里 `conversation_id` 是谁的；stop 在按停止时来、`aborted` 是人发起的；同一轮会不会来两次 stop。
- Cursor 多根工作区的会话挂哪个根（倾向第一个登记过的根）。
- Codex 的 legacy history mode 做到什么程度（倾向只出会话、轮次、打断、token）。
