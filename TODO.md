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
命中的是精确归属；Bash 改的只能列出命令里出现过这个文件名的会话作候选（spec §4.5 第二档，原话是「哪些 session
碰过这个文件」）；人改的无从归属。

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
d=$(mktemp -d); cp -p "$(git rev-parse --git-path index)" "$d/index"
GIT_INDEX_FILE=$d/index git add -A && GIT_INDEX_FILE=$d/index git write-tree; rm -rf "$d"
```

- 不碰真 index、不碰工作树；没改的文件复用已有 blob，只新增改过的内容。
- 从真 index 起步：已跟踪但匹配 `.gitignore` 的文件不会漏（从空 index 起步会漏），stat 缓存也是热的。
- 每次一份副本：并发的快照不抢同一个 `index.lock`（共用一份时实测会撞锁失败）。
- `cp` 必须带 `-p`：git 靠 index 文件自身的 mtime 判断哪些条目得重读内容（racy-git），副本的 mtime 变成「现在」，
  就会漏掉「`git add` 之后同一秒内被改成同样长度」的文件（demo 边界 11）。
- 不需要常驻进程，不存 prompt。PostToolUse 的 stdin 实测直接给 `session_id` 与 `tool_use_id`
  （[DESIGN §2.1](DESIGN.md)）；PreToolUse 的字段集、以及怎么区分子 agent，**待实测**。

**② 每一段差分归给当时进行中的工具调用。** 上一个快照到这个快照之间的差分：

| 这段时间里进行中的工具调用 | 归给 |
|---|---|
| 没有 | **gap**：不是任何 agent 工具调用做的。多半是人手改，也可能是 IDE 格式化、文件监听、别的进程 |
| 一个 | 这次调用。Edit 和 Bash 一视同仁 |
| 多个 | 并列（歧义），不硬猜 |

「进行中」怎么维护：

- pre 登记、post 只注销自己那一次，按 tool_use_id 配对，**不看相邻顺序**，同一线程里的调用重叠也不会互相关掉。
- 配不上 pre 的 post（pre 那次快照丢了，比如 hook 失败）：这一步标「起点不明」，不能落成 gap。
- 被打断的调用等不到 post，也未必等得到同线程的下一个 pre（子 agent、会话就此结束），所以在**一轮结束时**关：
  下一次 UserPromptSubmit、Stop、SubagentStop、SessionEnd 到来时先拍一次，把到此为止的改动记给它、标「未完成」，
  再注销。被打断时 Stop 是否触发待实测。
- 登记表放在 `git rev-parse --git-path` 解析出的本 worktree 私有目录里，每个 worktree 一份。

**③ 影子历史每个 worktree 一条、跨提交连续，post-commit 时只报本 commit 的行。**

- 每次快照与末端不同，就往 `refs/worktree/vibetrail/shadow` 上接一个影子提交（`git commit-tree`，作者名 =
  这一步归给谁）。`refs/worktree/` 是每个 worktree 各一份的命名空间——各 worktree 共用一条 ref 时，
  别的 worktree 的快照会交替接进来，把改动冲成 gap（审计实测）。别的 worktree 要读，用
  `worktrees/<名>/refs/worktree/…` 或 `main-worktree/refs/worktree/…`。默认 refspec 不推送它。
- 第一个快照是根，其中已有的内容记为「快照开始前已在工作树里」。
- **不在每次提交时从父提交重开**——否则上一次提交没带走、留在工作树里的改动，会在下一次提交里被当成 gap。
- post-commit 时，末端临时接上真 commit 的 tree：最后一个快照到提交之间的差额，归给此刻进行中的调用
  （agent 在工具调用里提交就是那次调用，人在终端提交就是 gap）。
- 落在这段差额上的行要再往回找一次：先暂存、后又改时，提交进去的是暂存区里的旧版本，它在更早的快照里就有。
  沿影子历史往回找最近一个含这一行的版本，在那里 blame；找不到才真是最后一个快照之后写的（demo 边界 6）。
  按行内容找，重复行（空行、`}`）会找错位置，是启发式。
- 只报本 commit 相对父提交新增或改动的行：一次 `git diff -M -U0` 拿全部文件的新侧行号（`-M` 认改名，纯改名
  没有新侧行；`core.quotePath=false`、不经 shell 拆词，带空格和中文的文件名不丢）。部分暂存时被「改回去」的行
  不在 diff 里，不会被报；删掉的文件没有新侧行。
- 每行给两个答案：**放置者**（不带 `-M` / `-C` 的 blame：这一行是谁放到这里的）与**内容来源**（带 `-M` / `-C`：
  认出的移动或复制的出处）。不同就都标上——复制别人的代码，放置者负责把它放在这里，内容却出自原作者（demo 边界 9）。
  `-M` / `-C` 是带阈值的启发式。

**④ 落盘只存指针。** 文件、行范围、行内容哈希、会话、tool_use_id，锚在 `Vibetrail-Id` trailer 上——
与审计记录同锚，rebase / cherry-pick 下不变（[spec §4.0](spec/trace-v1.md)）。每个 commit KB 级，符合 D2。
影子历史和 transcript 一样只留本机。

### 5. 验证：demo（2026-09-11）

脚本 [experiments/attrib-demo.sh](experiments/attrib-demo.sh)：在临时目录建一次性仓库，不碰当前仓库，本机十秒以内。

主场景（BASE 之前还有历史，分两次提交）：

1. 会话 A：Edit 给 `calc.py` 的 `div` 加零检查（A1）；Bash 里用 `python3` 新建 `report.py`（A2）；
   Edit 给 `util.py` 的 `clamp` 加 docstring（A3）；然后**只提交 `calc.py`**（A4），另两处改动留在工作树；
2. 人在 IDE 里把 `clamp` 改错，不触发任何 hook；
3. 会话 B 用 `sed -i` 把 `calc.py` 的 `add` 改错（B1）；
4. 会话 C 用 Edit 给 `util.py` 加函数（C1），然后删掉 `legacy.py`、提交全部（C2）。

第二次提交的 trailer 上只会有 C。另有 11 个边界场景，每个对应两轮审计抓到的一类错（§11）。输出（`←` 之后是注释）：

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

######## 边界 5：两个 worktree 各有各的影子历史，另一个 worktree 的快照不串进来
== human commit in wt1 —— 本 commit 新增或改动的行 ==
f.txt      L1   A:A1     A-by-A1

######## 边界 6：先暂存、后又改，提交的是暂存区里的旧版本 → 仍归给写它的调用
== commit the staged v1 —— 本 commit 新增或改动的行 ==
f.txt      L1   A:A1     v1

######## 边界 7：调用被打断（有 pre 没 post），到这一轮结束时关掉并标未完成；之后的人手改归 gap
== human commit —— 本 commit 新增或改动的行 ==
f.txt      L1   S:S1(未完成) A-by-S1
f.txt      L2   gap      B-by-human

######## 边界 8：pre 那次快照丢了（hook 失败），只有 post → 标起点不明，不记成 gap
== human commit —— 本 commit 新增或改动的行 ==
f.txt      L1   A:A1(起点不明) A-by-A1

######## 边界 9：复制——这一行是谁放进来的（放置者）与内容最早出自谁（-M / -C）分开标
== f and g —— 本 commit 新增或改动的行 ==
m.py       L1   A:A1     def f(items):
m.py       L2   A:A1         total = compute_total(items, discount_rate)
m.py       L4   B:B1     def g(items):
m.py       L5   B:B1(内容同 A:A1)     total = compute_total(items, discount_rate)

######## 边界 10：改名（纯改名不算新增）+ 文件名带空格和中文
== rename and append —— 本 commit 新增或改动的行 ==
说明 b.txt L4   A:A1     four

######## 边界 11：复制 index 要带 -p（racy-git）：add 之后同一秒改成同长度，隔一秒再拍
cp 不带-p → 快照里是 return a * b（工作树里是 return a - b）
cp -p     → 快照里是 return a - b（工作树里是 return a - b）
```

主场景两次提交新增或改动的行全部归对：两处 bug 分别落在 B 的 sed 和人的手改上；第一次提交没带走的改动，
在第二次提交里仍归给当初写它的 A2、A3；BASE 之前的旧行和删掉的文件都没有被报出来。边界场景各自的预期写在标题里，
输出与预期一致。

**demo 没覆盖的**：搬运（`git stash pop`、`cherry-pick -n`、跨 worktree `cp`）；agent 在工具调用里移动 HEAD
（checkout / rebase）；影子历史的并发追加（demo 是串行的）；hook 里怎么区分子 agent、PreToolUse 给哪些字段；
§4③ 往回找暂存内容时碰上重复行；真实仓库规模下的耗时与占盘。场景是照已知的错搭的，没见过的错照样测不到。
它也只打印、不断言。

### 6. 判责：从 bug 回到对话

1. **定位出错的行。** 从修复 commit 出发：它删掉或改掉的行就是出错的行。在修复 commit 的父提交上
   对这些行跑 blame，找到引入它们的 commit（学术上叫 SZZ 算法）。
2. **查归属。** 引入 commit 的 `Vibetrail-Id` → 归属记录 → 会话 + tool_use_id；放置者与内容来源不同时两个都要看。
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
  拿到，据此把并列拆开；Bash 之间的重叠拆不开。「拍快照 → 算标签 → 追加影子历史 → 改登记表」这一整段要串行：
  加一把 worktree 级的锁，或者追加时用 `update-ref` 带旧值校验、失败就重拍重算——光有旧值校验不够，登记表也得原子地改。
- **调用进行中的人手改会记给这次调用。** 快照只看得出「这段时间里谁在跑」，看不出是谁动的手；被打断的调用
  到一轮结束之前一直算进行中，其间的人手改同样记给它（边界 7 标了「未完成」，要按歧义看待）。
- **搬运。** `git stash pop`、`cherry-pick -n`、从别的 worktree `cp` 过来的改动，会记在执行搬运的那次调用上。
  要追到源头，得按行内容哈希在各 worktree 的影子历史里找最早出现的地方：它们共享同一个对象库（git-common-dir），
  ref 按 §4③ 的写法跨 worktree 可读，做得到，要多写一段。
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
- [ ] **快照 hook**：PreToolUse / PostToolUse，fail-open、不阻断宿主；UserPromptSubmit / Stop / SubagentStop /
  SessionEnd 关未完成的调用；定下围哪些工具（Bash / Edit / Write / NotebookEdit 与会写文件的 MCP 工具，还是全部）；
  实测 PreToolUse 的字段集、子 agent 的区分方式、被打断时 Stop 是否触发。
- [ ] **post-commit 归属**：影子历史 + blame → 归属记录，锚 `Vibetrail-Id`；和 `prepare-commit-msg` 一起由
  `vibetrail-install` 装。
- [ ] **查询**：`vibetrail blame <file>:<line>` → commit → 会话 + tool_use_id → transcript 回跳；
  另加一个从修复 commit 出发的 SZZ 入口。
- [ ] **限制处理**：整段加锁或旧值校验、搬运按内容哈希回溯、截断策略。
- [ ] **回归**：把 demo 改成 `tools/test-*.sh` 那样带断言的测试，补上 §5「demo 没覆盖的」各场景。
- [ ] **回写文档**：§8 列的各处。

### 10. 待定（先记录、暂不定）

- 归属记录落哪：`.claude/trace/attributions/<vibetrailId>.jsonl`（随仓，与审计记录同锚，倾向这个），
  还是 git notes（不进 tree，但要单独配 push / fetch refspec）。
- 影子历史保留多久、怎么截断。
- 放置者与内容来源都存，还是只存一个；判责默认看哪个。
- 判责口径（§6 的表）是固化成字段，还是只作为复盘时的人工指引。
- 是否和 G7（装一次、自动上报）一起做：快照 hook 与 G7 计划的 `.claude/settings.json` hooks 是同一个挂载点。
- 是否也给 Pilot 的数据做一版纯内容匹配的归属：不拍快照、覆盖面小，但不用装任何东西。

### 11. 审计记录

两轮独立审计，都在合并之后跑，发现的问题都已改在正文与 demo 里；demo 的边界场景就是照这些问题搭的。

**第一轮**审第一版 `514876d`（2026-09-11 00:13）：4 处错、8 处不准、6 个小问题。

| # | 第一版的做法 | 问题（均经实验复现） | 改成 |
|---|---|---|---|
| 错 1 | blame 影子历史末端、只滤掉 BASE 本身 | BASE 之前的旧行记在更老的提交上，被当成本 commit 的改动报出来；第一版 demo 的 BASE 恰好是根提交 | 影子历史的根是无父的快照提交，只报本 commit diff 里的行 |
| 错 2 | 方案原文写「父提交以来的快照」，demo 照做 | 上一次提交没带走的 agent 改动，在下一次提交里被判成 gap | 影子历史跨提交连续（主场景 A2、A3） |
| 错 3 | 部分暂存的差额记为 commit-time，报全部非 BASE 的行 | 被「改回去」的没改的行也被报出 | 差额归给提交时进行中的调用，只报 diff 里的行 |
| 错 4 | 快照用一份共用的独立 index，从空开始 | 已跟踪但匹配 `.gitignore` 的文件漏掉 | 每次复制一份真 index（边界 3） |
| 不准 5 | 共用 index；pre 与 post 按相邻顺序配对 | 并发快照撞 `index.lock`，fail-open 的 hook 会悄悄丢快照；交错时贴错 | 每份快照一个副本（边界 4）；按调用配对（边界 1、2） |

其余 7 处不准是措辞过度或转述不准：「大头」只有一个会话的依据、「代价都不在快照本身」说满了、DESIGN 引文不是逐字、
OPEN-ISSUES 的 G11 行复述过多并把 demo 结论写成一般结论、没写行移动要靠 `-M` / `-C`、「demo 没覆盖的」漏了前提。
6 个小问题是口径与引文细节，外加删掉的文件会让 demo 直接中止。

**第二轮**审修复 `224b884`：上一轮 18 条的原症状全部不再出现，但**修法本身引入或留下了 5 处错**、4 处不准、3 个小问题。

| # | 问题（均经实验复现） | 改成 |
|---|---|---|
| 错 1 | 影子历史改成跨提交连续后，还是一条所有 worktree 共用的 ref，别的 worktree 的快照交替接进来，把改动冲成 gap | `refs/worktree/` 每个 worktree 一条，登记表放本 worktree 私有目录（边界 5） |
| 错 2 | 先暂存、后又改：提交的是暂存区里的旧版本，被记给提交者（第一轮就在，没抓到） | 落在差额上的行沿影子历史往回找（边界 6） |
| 错 3 | 改成复制真 index 时 `cp` 没带 `-p`，丢了 racy-git 保护，同一秒内的同长度改动快照漏掉 | `cp -p`（边界 11） |
| 错 4 | 按新路径逐个 `git diff -- <文件>`，改名的文件整份被当成新增 | 一次 `diff -M` 解析全部文件（边界 10） |
| 错 5 | `for f in $(git diff --name-only)` 拆词，`core.quotePath` 转义中文，这些文件的行被静默丢掉 | 同上，路径不转义、不经 shell 拆词（边界 10） |

4 处不准：文档说按 tool_use_id 配对、demo 却只按线程（边界 8 与同线程重叠）；被打断的调用「等同线程的下一个 pre」
可能永远等不到（边界 7）；`-M` 不只认移动也认复制，会把复制者写的行归给原作者（边界 9）；「demo 没覆盖的」仍漏了
上面这些情形。3 个小问题：旧值校验之外登记表也要原子地改；本台账第一版把不准 5 并进了错 4、把 514876d 的日期写成 09-10；
§3 一处引号里的字不是 spec 原文。

两轮的教训是同一条，第二轮更扎眼：**demo 的场景是照着想证明的结论搭的，恰好绕开了会出错的情形；修复也一样，
只修到了被指出的那个症状，修法自己带进来的问题（共用 ref、`cp` 丢 mtime）照样没有场景去碰。**
