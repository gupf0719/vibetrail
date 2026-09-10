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
查询端最多给出「碰过这个文件的会话」作候选。

### 3. Pilot 全采能补多少

按源码核对：本机 `~/program/code/loongsuite-pilot`，HEAD `4e59a5bc`（2026-09-10）。它比
[三方文档](third-party/loongsuite-pilot-collection.md)的快照 `d4ab8b6d` 新 7 个 commit，但下列文件在两者之间没有改动，
行号两边一致。无前缀的行号指 `assets/hooks/claude-code-hook-processor.mjs`。

| 能给 | 出处 |
|---|---|
| 每次工具调用的完整参数：Edit 的 `old_string` / `new_string`、Write 的全文、Bash 的命令原文 | `:1169`，`toolBlock.input` 原样写入 |
| 工具结果正文（回给模型的那段文字） | `:1185`，取自 `claude-code/transcript-parser.mjs:323` |
| tool_use id、调用与结果时间戳、`gen_ai.session.id` | `:1168`、`:1160` / `:1176`、`:955` |

| 缺 | 出处与后果 |
|---|---|
| **Bash 改的文件只有命令，没有结果** | sed / python3 / heredoc 写进文件的内容不在任何字段里。在这个工作流里这是大头：spec §4.5 实测某会话 10 次 Edit 对 318 条改文件的 Bash |
| **Edit 没有位置** | transcript 里带行号的 `toolUseResult.structuredPatch` / `originalFile` 不采；parser 读 `toolUseResult` 只为了子 agent 的 `agentId` / `agentType` / `status` / `isAsync`（`transcript-parser.mjs:326-335`） |
| **人手改的看不到** | Pilot 只观察 agent，IDE 里的编辑不经过任何 agent 事件 |
| **没有 git 状态** | `src/utils/git-context.ts:48-51` 只取仓根、分支名、`remote.origin.url`，没有 HEAD sha、没有工作树状态；提交事件 `GitHookEvent`（`src/types/events.ts:190-200`）仍然零引用。cwd 取自 hook 事件、存进会话 state（`:448-449,474-475,534-535`），不是逐次工具调用的 |

所以只靠 Pilot 能做的是**内容匹配**：拿 commit 的新增行去匹配各会话 Edit / Write 的 `new_string` 与全文。
命中的是精确归属；Bash 改的只能给「命令里提到过这个文件的会话」作候选（spec §4.5 第二档）；人改的无从归属。

判责要用的对话证据，Pilot 在人类这一侧也会漏：中断记录 265 条只进了 5 条，没等到真实回复的整轮连 prompt 一起丢
（主会话 1,599 条丢 154 条），见[采集清单 §1.2b](third-party/loongsuite-pilot-collection.md)。

### 4. 方案：工具调用前后快照工作树，在快照链上跑 `git blame`

spec §4.5 写过这条路：「要做到任何改动都能精确归属，必须在每次工具调用前后快照工作树自己算 diff」。
思路与 git-ai 的 checkpoint 相同（[DESIGN §2.2](DESIGN.md)），当时按 git-ai 的代价否掉了
（[DESIGN §2.5](DESIGN.md)：833MB 常驻库、完整 prompt 排队待上传、跑一次二进制就起守护进程）。
那些代价都不在快照本身。

**① 快照。** PreToolUse / PostToolUse hook 里用一份独立的 index 把整个工作树写成 tree 对象：

```bash
idx=$(git rev-parse --git-dir)/vibetrail-snap.index
GIT_INDEX_FILE=$idx git add -A && GIT_INDEX_FILE=$idx git write-tree
```

不碰真 index、不碰工作树；没改的文件复用已有 blob，只新增改过的内容。日志每次一行：
会话、tool_use_id、pre / post、tree、时间。不需要常驻进程，不存 prompt。
PostToolUse 的 stdin 实测直接给 `session_id` 与 `tool_use_id`（[DESIGN §2.1](DESIGN.md)）；PreToolUse 的字段集**待实测**。

**② 差分自动分两类。**

| 差分 | 归给谁 |
|---|---|
| 同一次工具调用的 pre → post | 这次工具调用。Edit 和 Bash 一视同仁 |
| 上一次 post → 下一次 pre | **gap**：不是任何 agent 工具调用做的。多半是人手改，也可能是 IDE 格式化、文件监听、别的进程 |

**③ post-commit 时算归属。** 把父提交以来、同一工作目录上所有会话的快照按时间串成一条**影子历史**
（`git commit-tree`，每一步的作者写成造成这一步的「会话:工具调用」或 gap），末端接真 commit 的 tree
（部分暂存时二者不同，差额记为 commit-time）。然后对本 commit 改过的文件在影子历史上跑 `git blame`，
本 commit 新增或改动的每一行都得到归属。行移动、同一文件被多次改写，交给 git 自己的 blame 算法。

**④ 落盘只存指针。** 文件、行范围、行内容哈希、会话、tool_use_id，锚在 `Vibetrail-Id` trailer 上——
与审计记录同锚，rebase / cherry-pick 下不变（[spec §4.0](spec/trace-v1.md)）。每个 commit KB 级，符合 D2。
快照的 tree 与 blob 和 transcript 一样只留本机。

### 5. 验证：demo（2026-09-10）

脚本 [experiments/attrib-demo.sh](experiments/attrib-demo.sh)：在临时目录建一次性仓库，不碰当前仓库。
场景：

1. 会话 A 用 Edit 给 `calc.py` 的 `div` 加零检查（A1），又在 Bash 里用 `python3` 新建 `report.py`（A2）；
2. 人在 IDE 里把 `util.py` 的 `clamp` 改错，不触发任何 hook；
3. 会话 B 用 `sed -i` 把 `calc.py` 的 `add` 改错（B1）；
4. 会话 C 用 Edit 给 `util.py` 加函数（C1），然后在 Bash 里一次提交全部（C2）。

trailer 上只会有 C。输出（`←` 之后是注释）：

```
calc.py    L2   B:B1                 return a - b                    ← sed 改的，Edit 记录里没有
calc.py    L5   A:A1                 if b == 0:
calc.py    L6   A:A1                     raise ZeroDivisionError("b is 0")
report.py  L1   A:A2             def report(xs):                     ← python3 写的
report.py  L2   A:A2                 return sum(xs) / len(xs)
util.py    L2   gap:after-A:A2       return max(lo, min(x, lo))      ← 人手改的
util.py    L3   C:C1                                                 ← 空行
util.py    L4   C:C1             def lerp(a, b, t):
util.py    L5   C:C1                 return a + (b - a) * t
```

本 commit 新增或改动的 9 行全部归对，两处 bug 分别落在 B 的 sed 和人的手改上。

**demo 没覆盖的**：§7 的各项限制一项都没测——并发、被打断的工具调用、跨工作目录搬运、
真实仓库规模下的耗时与占盘。它也只打印、不断言。

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

- **并发。** 同一工作目录里两个工具调用同时跑（包括同一会话里并行的子 agent），pre → post 会夹进别人的改动。
  Edit / Write 的精确改动可以从 hook 的 `tool_input`（old / new string、全文）拿到并扣掉；
  Bash 之间的重叠只能标「二者之一」。会话各在自己的 worktree 时跨会话并发少见，共用主 checkout 时会发生。
- **被打断的工具调用。** 可能只有 pre 没有 post。紧跟着的那段差分要记给这次调用并标为未完成，
  **不能记成 gap**，否则会把 agent 的改动冤枉到人头上。
- **搬运。** `git stash pop`、`cherry-pick -n`、从别的 worktree `cp` 过来的改动，会记在执行搬运的那次调用上。
  要追到源头，得按行内容哈希在所有 worktree 的快照里找最早出现的地方。worktree 共享同一个对象库
  （git-common-dir），做得到，要多写一段。
- **代价没量。** 大仓里每次 `git add -A` 的耗时要在 agentDock 上实测；中间 blob 堆在本地 `.git/objects`，
  算完归属要删掉快照 ref、让 gc 回收。没进 `.gitignore` 的未跟踪文件（比如 `.env`）也会写进本地对象库——
  不出本机，但要知道。
- **gap 不等于人。** 格式化器、文件监听、构建工具在工具调用之外改的文件也会落进 gap。
- **squash 合流**下与 trailer 一样会丢（[spec §7](spec/trace-v1.md)）。

### 8. 对现有文档的影响（落地时再改，现在不动）

- [DESIGN §2.5](DESIGN.md) / Q5：否决行级归属的理由是「文件侧人机分歧这个维度在本工作流接近空」。
  「多个会话之间谁写的」是另一个维度，不空。否决的对象（git-ai 的代价结构）不变，
  但「我们只需要它的 commit ↔ session 关联」这句不再成立。
- [spec §4.5](spec/trace-v1.md) 的标题「已知做不到」与结论「本格式不提供代码归属」，以及 §7 第三条：改成指向新的归属记录。
- [spec §4.4](spec/trace-v1.md)：有了逐行归属，Agent Trace 的 `files[].conversations[].ranges[]` 填得出来了，
  「不声称合规」的理由消失，可重新评估。
- [CAPABILITIES §1](CAPABILITIES.md) 的「行级归属 ❌ 已否决」、[FLOW.md](FLOW.md) 的五段图：加上「快照 → 归属」这一段。

### 9. 拆解

- [ ] **测量（先做）**：在 agentDock 那台机器上挑几个真实的多会话 commit，只用现有 transcript 做 Edit / Write
  内容匹配，量出不拍快照能覆盖多少行——spec §4.5 的「约 3%」只来自一个会话。同时量 `git add -A` + `write-tree`
  在 agentDock 上的单次耗时。这两个数决定快照值不值得上。
- [ ] **快照 hook**：PreToolUse / PostToolUse，fail-open、不阻断宿主；定下围哪些工具（Bash / Edit / Write /
  NotebookEdit 与会写文件的 MCP 工具，还是全部）。
- [ ] **post-commit 归属**：影子历史 + blame → 归属记录，锚 `Vibetrail-Id`；和 `prepare-commit-msg` 一起由
  `vibetrail-install` 装。
- [ ] **查询**：`vibetrail blame <file>:<line>` → commit → 会话 + tool_use_id → transcript 回跳；
  另加一个从修复 commit 出发的 SZZ 入口。
- [ ] **限制处理**：并发标歧义、未完成的调用、搬运按内容哈希回溯。
- [ ] **回归**：把 demo 改成 `tools/test-*.sh` 那样带断言的测试，并补 §7 各项限制的场景。
- [ ] **回写文档**：§8 列的各处。

### 10. 待定（先记录、暂不定）

- 归属记录落哪：`.claude/trace/attributions/<vibetrailId>.jsonl`（随仓，与审计记录同锚，倾向这个），
  还是 git notes（不进 tree，但要单独配 push / fetch refspec）。
- 判责口径（§6 的表）是固化成字段，还是只作为复盘时的人工指引。
- 是否和 G7（装一次、自动上报）一起做：快照 hook 与 G7 计划的 `.claude/settings.json` hooks 是同一个挂载点。
- 是否也给 Pilot 的数据做一版纯内容匹配的归属：不拍快照、覆盖面小，但不用装任何东西。
