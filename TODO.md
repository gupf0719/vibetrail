# 待办：已有方案、尚未开工的需求

> 与 [OPEN-ISSUES.md](OPEN-ISSUES.md) 的分工：OPEN-ISSUES §C 中心表仍是**唯一的未完成项清单**，
> 每条的一句话与状态只记在那里；本文记其中**已经有方案、还没开工**的需求的细节——
> 需求原话、方案、验证、限制、拆解。做完一条就删掉它的小节，并在中心表关闭对应 ID。

## G11 多个会话改、一个会话提交：追回每一行出自哪个会话

### 1. 需求

用户原话（2026-09-10，看完三方对比后提出）：

> 如果 pilot 数据全采的话，能实现根据错误 commit 找到具体哪个 session 提交的吗，然后找到对应的聊天内容看是
> 模型出错的还是开发人员出的错。……session 和 commit 的 1 对 1 关系我们自己已经实现了，现在说的是多个 session
> 改了多个代码，然后在最后一个 session 提交了 commit，有办法复盘回溯到当时那个 session 么

拆成两问：

1. **归属**：一个 commit 里的每一行，出自哪个会话的哪一次工具调用，还是根本不是 agent 写的。
2. **判责**：拿到那次工具调用之后，回到对话里判断是模型错了还是人错了。

### 2. 现状：trailer 只答「谁提交」

`Claude-Session` trailer 的语义是**哪个会话执行了 `git commit`**，不是**改动出自哪个会话**
（[spec §2](spec/trace-v1.md)）。会话 A、B 改、C 提交，trailer 上只有 C。
[spec §4.5](spec/trace-v1.md) 列了原始 transcript 里的三档还原能力，结论是「本格式不提供代码归属」，
查询端最多给出「碰过这个文件的 session」作候选。

### 3. Pilot 全采能补多少

按源码核对：本机 `~/program/code/loongsuite-pilot`，HEAD `4e59a5bc`（2026-09-10）。它比
[三方文档](third-party/loongsuite-pilot-collection.md)的快照 `d4ab8b6d` 新 7 个 commit，但下列文件在两者之间没有改动，
行号两边一致。无前缀的行号指 `assets/hooks/claude-code-hook-processor.mjs`。以下说的都是 **Claude Code 链路**。

| 能给 | 出处 |
|---|---|
| 每次工具调用的完整参数：Edit 的 `old_string` / `new_string`、Write 的全文、Bash 的命令原文 | `:1169`，`toolBlock.input` 原样写入 |
| 工具结果正文（回给模型的那段文字，Bash 即命令输出） | `:1185`，取自 `claude-code/transcript-parser.mjs:323` |
| tool_use id、调用与结果时间戳、`gen_ai.session.id` | `:1168`、`:1160` / `:1176`、`:955` |

| 缺 | 出处与后果 |
|---|---|
| **Bash 改的文件只有命令和输出，没有改后的文件内容** | sed / python3 / heredoc 写进文件的内容不在任何字段里。spec §4.5 实测的那一个会话里这是大头（10 次 Edit 对 318 条改文件的 Bash）；全工作流的比例待 §9 测量 |
| **Edit 没有位置** | transcript 里带行号的 `toolUseResult.structuredPatch` / `originalFile` 不采：parser 读 `toolUseResult` 只为了子 agent 的 `agentId` / `agentType` / `status` / `isAsync`（`transcript-parser.mjs:326-335`）。别的链路不同：Qoder 与 Qwen Work CN 把整块 `toolUseResult` 收进工具结果（`agent-event-normalizer.mjs:507`，经 `shared/hook-processor-base.mjs:357-359`；`qwen-work-cn-hook-processor.mjs:387`） |
| **人手改的看不到** | Pilot 只观察 agent，IDE 里的编辑不经过任何 agent 事件 |
| **没有 git 状态** | `src/utils/git-context.ts:48-51` 只取仓根、分支名、`remote.origin.url`，没有 HEAD sha、没有工作树状态；提交事件 `GitHookEvent`（`src/types/events.ts:190-200`）仍然零引用。cwd 取自 hook 事件、存进会话 state（`:448-449,474-475,534-535`），不是逐次工具调用的 |

所以只靠 Pilot 能做的是**内容匹配**：拿 commit 的新增行去匹配各会话 Edit / Write 的 `new_string` 与全文。
命中的是精确归属；Bash 改的只能给「命令里提到过这个文件的会话」作候选（spec §4.5 第二档）；人改的无从归属。

判责要用的对话证据，Pilot 在人类这一侧也会漏（[采集清单 §1.2b](third-party/loongsuite-pilot-collection.md)）：
主会话的中断记录 265 条（含 111 MB 那份）只进了 5 条；50 MB 以下的 37 个主会话里，每轮第一条人类输入
1,599 条丢了 154 条，都是没等到真实回复的整轮。

### 4. 方案：工具调用前后快照工作树，在影子历史上跑 `git blame`

spec §4.5 写过这条路：「要做到任何改动都能精确归属，必须在每次工具调用前后快照工作树自己算 diff」。
思路与 git-ai 的 checkpoint 相同（[DESIGN §2.2](DESIGN.md)），当时按 git-ai 的代价否掉了
（[DESIGN §2.5](DESIGN.md)：833MB 常驻库、完整 prompt 排队待上传、跑一次二进制就起守护进程）。
其中上传 prompt 与常驻守护进程都不是快照必需的；占盘快照也有，要实测（§7）。否决的另一半理由是价值，见 §8。

**① 快照。** PreToolUse / PostToolUse hook 里，复制一份真 index 当起点，把整个工作树写成 tree 对象：

```bash
d=$(mktemp -d); cp "$(git rev-parse --git-path index)" "$d/index"
GIT_INDEX_FILE=$d/index git add -A && GIT_INDEX_FILE=$d/index git write-tree; rm -rf "$d"
```

- 不碰真 index、不碰工作树；没改的文件复用已有 blob，只新增改过的内容。
- 从真 index 起步：已跟踪但匹配 `.gitignore` 的文件不会漏（从空 index 起步会漏），stat 缓存也是热的。
- 每次一份副本：并发的快照不抢同一个 `index.lock`（共用一份时实测会撞锁失败）。
- 不需要常驻进程，不存 prompt。PostToolUse 的 stdin 实测直接给 `session_id` 与 `tool_use_id`
  （[DESIGN §2.1](DESIGN.md)）；PreToolUse 的字段集、以及怎么区分子 agent，**待实测**。

**② 每一段差分归给当时进行中的工具调用。** 上一个快照到这个快照之间的差分：

| 这段时间里进行中的工具调用 | 归给 |
|---|---|
| 没有 | **gap**：不是任何 agent 工具调用做的。多半是人手改，也可能是 IDE 格式化、文件监听、别的进程 |
| 一个 | 这次调用。Edit 和 Bash 一视同仁 |
| 多个 | 并列（歧义），不硬猜 |

「进行中」按线程（会话，子 agent 另算）用 tool_use_id 配对 pre / post，**不看相邻顺序**；同一线程的新 pre 到来时，
它上一个没等到 post 的调用视为已结束。

**③ 影子历史跨提交连续，post-commit 时只报本 commit 的行。**

- 每次快照与末端不同，就往一个本地 ref（如 `refs/vibetrail/shadow`，默认不推送）上接一个影子提交
  （`git commit-tree`，作者名 = 这一步归给谁）。第一个快照是根，其中已有的内容记为「快照开始前已在工作树里」。
- **不在每次提交时从父提交重开**——否则上一次提交没带走、留在工作树里的改动，会在下一次提交里被当成 gap。
- post-commit 时，末端临时接上真 commit 的 tree：最后一个快照到提交之间的差额，归给此刻进行中的调用
  （agent 在工具调用里提交就是那次调用，人在终端提交就是 gap）。
- 只对本 commit 相对父提交新增或改动的行跑 blame（`git diff -U0` 的新侧行号 → `blame -L`）。
  部分暂存时被「改回去」的行不在本 commit 的 diff 里，不会被报；删掉的文件跳过。
- blame 加 `-M` / `-C` 才认文件内的行移动与跨文件复制，二者是带阈值的启发式。

**④ 落盘只存指针。** 文件、行范围、行内容哈希、会话、tool_use_id，锚在 `Vibetrail-Id` trailer 上——
与审计记录同锚，rebase / cherry-pick 下不变（[spec §4.0](spec/trace-v1.md)）。每个 commit KB 级，符合 D2。
影子历史和 transcript 一样只留本机。

### 5. 验证：demo（2026-09-11）

脚本 [experiments/attrib-demo.sh](experiments/attrib-demo.sh)：在临时目录建一次性仓库，不碰当前仓库，约 4 秒。

主场景（BASE 之前还有历史，分两次提交）：

1. 会话 A：Edit 给 `calc.py` 的 `div` 加零检查（A1）；Bash 里用 `python3` 新建 `report.py`（A2）；
   Edit 给 `util.py` 的 `clamp` 加 docstring（A3）；然后**只提交 `calc.py`**（A4），另两处改动留在工作树；
2. 人在 IDE 里把 `clamp` 改错，不触发任何 hook；
3. 会话 B 用 `sed -i` 把 `calc.py` 的 `add` 改错（B1）；
4. 会话 C 用 Edit 给 `util.py` 加函数（C1），然后删掉 `legacy.py`、提交全部（C2）。

第二次提交的 trailer 上只会有 C。输出（`←` 之后是注释）：

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

######## 边界 3：已跟踪但匹配 .gitignore 的文件，只报改动的那一行
== bump —— 本 commit 新增或改动的行 ==
deps.lock  L1   A:A1     v2

######## 边界 4：并发快照（每次复制一份 index），30 轮 × 2 路
快照失败 0 次（其中 index.lock 冲突 0 次）
```

两次提交新增或改动的行全部归对：两处 bug 分别落在 B 的 sed 和人的手改上；第一次提交没带走的改动，
在第二次提交里仍归给当初写它的 A2、A3；BASE 之前的旧行和删掉的文件都没有被报出来。

**demo 没覆盖的**：被打断的工具调用（只有 pre 没有 post）；搬运（`git stash pop`、`cherry-pick -n`、跨 worktree `cp`）；
agent 在工具调用里移动 HEAD（checkout / rebase）；行移动（`-M` / `-C` 开着但场景里没有）；影子历史的并发追加
（demo 是串行的）；hook 里怎么区分子 agent；真实仓库规模下的耗时与占盘。它也只打印、不断言。

### 6. 判责：从 bug 回到对话

1. **定位出错的行。** 从修复 commit 出发：它删掉或改掉的行就是出错的行。在修复 commit 的父提交上
   对这些行跑 blame，找到引入它们的 commit（学术上叫 SZZ 算法）。
2. **查归属。** 引入 commit 的 `Vibetrail-Id` → 归属记录 → 会话 + tool_use_id。
3. **还原现场。** 回**原始 transcript**（不用 Pilot 事件，理由见 §3 末），沿 `parentUuid` 往上找到触发这次
   工具调用的人类消息。证据包：人的指令、模型的 thinking、工具调用本身、同会话前后的分歧事件（L3 已有）、
   这个 commit 的审计记录（`vibetrail-audit`）。
4. **判断**，大致口径：

| 情形 | 归到 |
|---|---|
| 归属为 gap | 不是 agent 写的，基本是人，或人跑的工具 |
| 指令本身要求了错误行为 | 人 |
| 指令对、实现错 | 模型 |
| 模型提示过风险、人坚持要做 | 人的决定 |
| 审过、但审计记录里没发现 | 流程 |

这一步是判断，不是计算。可以让 LLM 按证据包先分类，由人拍板。口径本身待定（§10）。

### 7. 已知限制与处理

- **并发。** 两个工具调用同时进行时（包括同一会话里并行的子 agent），各自独占的时段按 §4② 归得开（demo 边界 1），
  重叠时段里的改动只能标并列（边界 2）。Edit / Write 的精确改动可以从 hook 的 `tool_input`（old / new string、全文）
  拿到，据此把并列拆开；Bash 之间的重叠拆不开。往影子历史追加要用 `update-ref` 的旧值校验，防两个 hook 同时追加
  互相覆盖。
- **被打断的工具调用。** 只有 pre 没有 post 时，它一直算进行中，直到同一线程的下一个 pre。这段时间里的改动
  （包括其间的人手改）都会记给它，要标为未完成、按歧义看待。反过来，**不能把它的改动记成 gap**，否则会冤枉到人头上。
- **搬运。** `git stash pop`、`cherry-pick -n`、从别的 worktree `cp` 过来的改动，会记在执行搬运的那次调用上。
  要追到源头，得按行内容哈希在所有 worktree 的影子历史里找最早出现的地方。worktree 共享同一个对象库
  （git-common-dir），做得到，要多写一段。
- **快照看不见的改动。** 复制真 index 会连带 `assume-unchanged` / `skip-worktree` 标记，这类文件的改动快照看不到（少见）。
- **代价没量。** 大仓里每次 `add -A` + `write-tree` 的耗时要在 agentDock 上实测。影子历史跨提交连续，要定截断策略，
  中间 blob 堆在本地 `.git/objects`，截断后让 gc 回收。没进 `.gitignore` 的未跟踪文件（比如 `.env`）
  也会写进本地对象库——不出本机，但要知道。
- **gap 不等于人。** 格式化器、文件监听、构建工具在工具调用之外改的文件也会落进 gap。
- **squash 合流**下与 trailer 一样会丢（[spec §7](spec/trace-v1.md)）。

### 8. 对现有文档的影响（落地时再改，现在不动）

- [DESIGN §2.5](DESIGN.md)：否决行级归属是代价与价值两头算的。价值那头的理由是，行级归属对应的文件侧分歧
  在本工作流接近空（§2.4 实测）；而「多个会话之间谁写的」是另一个维度，不空。代价那头（git-ai 的 833MB 常驻库等）
  不变，但 Q5 里「我们只需要它的 commit ↔ session 关联」这句不再成立。
- [spec §4.5](spec/trace-v1.md) 的标题「已知做不到」与结论「本格式不提供代码归属」，以及 §7 第三条：改成指向新的归属记录。
- [spec §4.4](spec/trace-v1.md)：有了逐行归属，Agent Trace 的 `files[].conversations[].ranges[]` 填得出来了，
  「不声称合规」的理由消失，可重新评估。
- [CAPABILITIES §1](CAPABILITIES.md) 的「行级归属 ❌ 已否决」、[FLOW.md](FLOW.md) 的五段图：加上「快照 → 归属」这一段。

### 9. 拆解

勾选只记拆解项做没做完，G11 整体的状态以中心表为准。

- [ ] **测量（先做）**：在 agentDock 那台机器上挑几个真实的多会话 commit，只用现有 transcript 做 Edit / Write
  内容匹配，量出不拍快照能覆盖多少行——spec §4.5 的「约 3%」只来自一个会话。同时量 `add -A` + `write-tree`
  在 agentDock 上的单次耗时。这两个数决定快照值不值得上。
- [ ] **快照 hook**：PreToolUse / PostToolUse，fail-open、不阻断宿主；定下围哪些工具（Bash / Edit / Write /
  NotebookEdit 与会写文件的 MCP 工具，还是全部）；实测 PreToolUse 的字段集与子 agent 的区分方式。
- [ ] **post-commit 归属**：影子历史 + blame → 归属记录，锚 `Vibetrail-Id`；和 `prepare-commit-msg` 一起由
  `vibetrail-install` 装。
- [ ] **查询**：`vibetrail blame <file>:<line>` → commit → 会话 + tool_use_id → transcript 回跳；
  另加一个从修复 commit 出发的 SZZ 入口。
- [ ] **限制处理**：影子历史并发追加的旧值校验、未完成的调用、搬运按内容哈希回溯、截断策略。
- [ ] **回归**：把 demo 改成 `tools/test-*.sh` 那样带断言的测试，补上 §5「demo 没覆盖的」各场景。
- [ ] **回写文档**：§8 列的各处。

### 10. 待定（先记录、暂不定）

- 归属记录落哪：`.claude/trace/attributions/<vibetrailId>.jsonl`（随仓，与审计记录同锚，倾向这个），
  还是 git notes（不进 tree，但要单独配 push / fetch refspec）。
- 影子历史保留多久、怎么截断。
- 判责口径（§6 的表）是固化成字段，还是只作为复盘时的人工指引。
- 是否和 G7（装一次、自动上报）一起做：快照 hook 与 G7 计划的 `.claude/settings.json` hooks 是同一个挂载点。
- 是否也给 Pilot 的数据做一版纯内容匹配的归属：不拍快照、覆盖面小，但不用装任何东西。

### 11. 审计记录

第一版（`514876d`，2026-09-10）合并后由独立 agent 审计，找出 4 处错、8 处不准、6 个小问题，均已改在正文与 demo 里。
错的 4 处都在 demo 的归属逻辑，第一版 demo 的场景恰好把它们全盖住了：

| # | 第一版的做法 | 问题（均经实验复现） | 现在 |
|---|---|---|---|
| 1 | blame 影子历史末端、只滤掉 BASE 本身 | BASE 之前的旧行记在更老的提交上，被当成本 commit 的改动报出来；第一版 demo 的 BASE 恰好是根提交 | 影子历史的根是无父的快照提交，只报本 commit diff 里的行（§4③） |
| 2 | 影子历史从父提交重开 | 上一次提交没带走的 agent 改动，在下一次提交里被判成 gap，冤枉到人头上 | 影子历史跨提交连续（§4③；主场景 A2、A3） |
| 3 | 部分暂存的差额记为 commit-time，报全部非 BASE 的行 | 被「改回去」的没改的行也被报出；最后一次快照后人手改再人提交的部分记成 commit-time 而不是 gap | 差额归给提交时进行中的调用，只报 diff 里的行（§4③） |
| 4 | 快照用一份共用的独立 index，从空开始 | 已跟踪但匹配 `.gitignore` 的文件漏掉；并发快照撞 `index.lock`，fail-open 的 hook 会悄悄丢快照；pre 与 post 按相邻顺序配对，交错时贴错 | 每次复制一份真 index；按线程配对 pre / post（§4① / ②；边界 1–4） |

不准的 8 处是措辞过度或转述不准：「大头」只有一个会话的依据、「代价都不在快照本身」说满了、DESIGN 引文不是逐字、
OPEN-ISSUES 的 G11 行复述过多并把 demo 结论写成一般结论，等等。小问题 6 处是口径与引文细节。
demo 碰到删掉的文件会直接中止，也在其中。

教训和本仓以往几份文档的台账同一类：**demo 的场景是照着想证明的结论搭的，恰好绕开了会出错的情形**——
「9 行全部归对」对的是那个场景，不是那套逻辑。
