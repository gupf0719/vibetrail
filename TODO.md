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
  （[DESIGN §2.1](DESIGN.md)）。PreToolUse 的字段集与子 agent 的区分，官方 hooks 文档（2026-09-11 查）有答案、
  **一手实测还没做**：PreToolUse 与 PostToolUse 字段集相同，都给 `tool_use_id` 与 `prompt_id`；子 agent 里的工具调用
  触发同一套 hook，stdin 多 `agent_id` / `agent_type`；PreToolUse 在权限确认**之前**触发。嵌套起一个 `claude -p` 去实测，
  desktop 附带的二进制脱离宿主没有登录态，跑不起来；一手证据按 [experiments/hook-probe.sh](experiments/hook-probe.sh)
  的路子注入 PreToolUse 探针即可。
- hook 里跑的 git 命令都带 `-c gc.auto=0`，别让快照顺手触发一次 gc 把工具调用卡住。

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
- 被打断的调用等不到 post，也未必等得到同线程的下一个 pre（子 agent、会话就此结束），所以在**一轮结束时**关：
  下一次 UserPromptSubmit、Stop、SubagentStop、SessionEnd 到来时先拍一次，把到此为止的改动记给它、标「未完成」，
  再注销。被打断时 Stop 是否触发待实测。
- **失败的调用没有 PostToolUse。** 文档写 PostToolUse 只在工具成功后触发，失败另有 `PostToolUseFailure`（字段集相同）。
  Bash 非零退出很常见（grep 无命中、测试失败都是），只挂 PostToolUse 的话这些调用会一直「进行中」到一轮结束，
  同一轮里后面所有调用的改动都被标成与它并列。两个事件都要挂；Bash 非零退出算不算这里的「失败」待实测。
- 每次快照顺手记下 HEAD：agent 在工具调用里 checkout / rebase / pull 时工作树整片变化，看日志时能把这类步骤
  与真正的改动分开（demo 没覆盖，见 §5）。
- 登记表与快照日志都放在 `git rev-parse --git-path` 解析出的本 worktree 私有目录里，每个 worktree 一份。

**③ 影子历史每个 worktree 一条、跨提交连续，post-commit 时只报本 commit 的行。**

- 每次快照与末端不同，就往 `refs/worktree/vibetrail/shadow` 上接一个影子提交（`git commit-tree`，作者名 =
  这一步归给谁）。`refs/worktree/` 是每个 worktree 各一份的命名空间；各 worktree 共用一条 ref、或共用登记表时，
  别的 worktree 的快照或调用会串进来贴错标签（demo 边界 6 的标题写了两种串法各自贴成什么，已实测）。
  别的 worktree 要读，用 `main-worktree/refs/worktree/…` 或 `worktrees/<id>/refs/worktree/…`——`<id>` 是
  worktree 的 id（`.git/worktrees/` 下的目录名），不一定等于它的目录名。默认 refspec 不推送这些 ref。
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
- 每行给两个答案：**放置者**（不带 `-M` / `-C` 的 blame：这一行是谁放到这里的）与**内容来源**（带 `-M` / `-C`：
  认出的移动或复制的出处）。不同就都标上——复制别人的代码，放置者负责把它放在这里，内容却出自原作者（边界 12）。
  `-M` / `-C` 是带阈值的启发式。
- **删掉的行也要出记录。** 上面只报新侧的行，「B 删掉了零检查」这类改动在记录里没有对应项，而删检查正是典型 bug。
  `git blame --reverse <根>..<末端> -- <文件>` 给出根版本每一行最后出现在哪一步，它在影子历史上的子提交就是删它的
  那次调用（边界 16 实测）；落地时对本 commit diff 里的 `-` 行也走这一条，出发点与上面相同。

**④ 落盘只存指针。** 文件、行范围、行内容哈希、会话、tool_use_id，锚在 `Vibetrail-Id` trailer 上——
与审计记录同锚，rebase / cherry-pick 下不变（[spec §4.0](spec/trace-v1.md)）。每个 commit KB 级，符合 D2。
影子历史和快照日志与 transcript 一样只留本机。

### 5. 验证：demo（2026-09-11）

脚本 [experiments/attrib-demo.sh](experiments/attrib-demo.sh)：在临时目录建一次性仓库，不碰当前仓库，本机十几秒。

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
（demo 是串行的）；hook 里怎么区分子 agent、PreToolUse 给哪些字段（文档答案见 §4①，一手未测）；`PostToolUseFailure` 是否覆盖 Bash 非零退出；
真实仓库规模下的耗时与占盘（本机初量见 §7，agentDock 未量）；删掉的行还没做进 attribute（边界 16 只演示了反向 blame）。
场景是照已知的错搭的，没见过的错照样测不到。它也只打印、不断言。

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
| 归属为 gap | 不是 agent 工具调用做的。本工作流里人基本不碰文件（[DESIGN §2.4](DESIGN.md)），先排除格式化器、文件监听、后台进程（§7），再归人或人跑的工具 |
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
- **调用进行中的人手改会记给这次调用。** 快照只看得出「这段时间里谁在跑」，看不出是谁动的手；PreToolUse 在权限确认之前触发，人在等确认时的手改也算进这次调用；被打断的调用
  到一轮结束之前一直算进行中，其间的人手改同样记给它（边界 10 标了「未完成」，要按歧义看待）。暂存也一样：
  §4③ 里出发点的工作树还没有、暂存时才带进来的那些行，归给暂存那一段进行中的调用，它未必是写这几行的人
  （出发点工作树里已有的行照常往前追，边界 7 的 v1 归给写它的 A1，不是暂存它的 A2）。
- **改走又改回。** A2 暂存了 v，B1 在工作树里改走，B2 又改回 v，然后 `commit -a`：暂存区一直是 v，按 §4③ 会记给
  最早写 v 的 A1；只看工作树历史的话，放置者是最后改回来的 B2。内容相同，偏差只在「记给谁」（第四轮审计实测）。
- **搬运。** `git stash pop`、`cherry-pick -n`、从别的 worktree `cp` 过来的改动，会记在执行搬运的那次调用上。
  要追到源头，得按行内容哈希在各 worktree 的影子历史里找最早出现的地方：它们共享同一个对象库（git-common-dir），
  ref 按 §4③ 的写法跨 worktree 可读，做得到，要多写一段。
- **后台运行的 Bash。** `run_in_background` 的命令在 PostToolUse 之后还在写文件，之后的改动会落进 gap 或记给下一次调用。
  快照日志里给这类调用打标，它之后同一轮里的 gap 按歧义看。
- **快照看不见的改动。** 复制真 index 会连带 `assume-unchanged` / `skip-worktree` 标记，这类文件的改动快照看不到（少见）。
- **代价只在本机初量过，agentDock 未量。** 2026-09-11，本机 SSD，工作树干净、index 热，进程内计时取 10 次平均：

  | 仓 | 跟踪文件 | `add -A` | `write-tree` | 对照 `git status` | 首次冷 `add -A` |
  |---|---:|---:|---:|---:|---:|
  | cadvisor | 2658 | 22ms | 11ms | 21ms | 188ms |
  | loongsuite-pilot | 928 | 14ms | 11ms | 15ms | 152ms |
  | 合成 30k 文件 | 30000 | 56ms | 12ms | 54ms | 2.2s |

  热态一次快照（两次 `write-tree` 加一次 `add -A`）约等于两次 `git status`，工具调用前后各一次；冷的只有第一次。
  影子历史跨提交连续，要定截断策略，中间 blob 堆在本地 `.git/objects`，截断后让 gc 回收。没进 `.gitignore` 的
  未跟踪文件（比如 `.env`）也会写进本地对象库——不出本机，但要知道。
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

- [ ] **测量（先做）**，三个数，在 agentDock 那台机器上量：
  1. **这件事发生得多不多**：commit 的文件在父提交到本提交的窗口内被 trailer 之外的会话 Edit / Write 过的比例，
     [experiments/multi-session-commits.sh](experiments/multi-session-commits.sh) 直接出（第一档内容匹配，Bash 改的看不到，
     是下界）。本机语料只有 6 个主会话，只能看个样子：本仓最近 40 个 commit 里有 transcript 可查的 7 个，2 个确定多会话
     （`514876d` 被 3 个会话改过；`d298f87` 的 trailer 会话与改文件的会话不同），5 个没有 trailer 比不了——最新的 6 个
     commit 都是从本机这个没装 hook 的 clone 提交的（`vibetrail-doctor` 报致命）。这个数决定 §10 里走规矩还是走机制。
  2. 不拍快照、只做 Edit / Write 内容匹配能覆盖多少行——spec §4.5 的「约 3%」只来自一个会话。
  3. 一次快照（两次 `write-tree` 加一次 `add -A`）在 agentDock 上的耗时，本机初量见 §7。
- [ ] **快照 hook**：PreToolUse / PostToolUse / **PostToolUseFailure**，fail-open、不阻断宿主；UserPromptSubmit / Stop /
  SubagentStop / SessionEnd 关未完成的调用；先定粒度（§10）；定下围哪些工具（Bash / Edit / Write / NotebookEdit 与会写文件的
  MCP 工具，还是全部）；一手实测 PreToolUse 的字段集与子 agent 的区分方式（文档答案见 §4①）、被打断时 Stop 是否触发、
  Bash 非零退出走哪个事件。
- [ ] **post-commit 归属**：影子历史 + 快照日志 + blame → 归属记录，锚 `Vibetrail-Id`；删掉的行走 `blame --reverse`（§4③）；
  和 `prepare-commit-msg` 一起由 `vibetrail-install` 装。
- [ ] **查询**：`vibetrail blame <file>:<line>` → commit → 会话 + tool_use_id → transcript 回跳；
  另加一个从修复 commit 出发的 SZZ 入口。
- [ ] **限制处理**：整段加锁或旧值校验、搬运按内容哈希回溯、截断策略。
- [ ] **回归**：把 demo 改成 `tools/test-*.sh` 那样带断言的测试，补上 §5「demo 没覆盖的」各场景。
- [ ] **回写文档**：§8 列的各处。

### 10. 待定（先记录、暂不定）

- 归属记录落哪：`.claude/trace/attributions/<vibetrailId>.jsonl`（随仓，与审计记录同锚，倾向这个），
  还是 git notes（不进 tree，但要单独配 push / fetch refspec）。两条路都要过一关：post-commit 写出的记录要到下一个
  commit 才入仓，与 sessions 投影「事后写」是同一个问题（`vibetrail-sync` 头注释）；随 sync 一起落，或者 notes 直接挂在 commit 上。
- 影子历史与快照日志保留多久、怎么截断。
- 放置者与内容来源都存，还是只存一个；判责默认看哪个。
- 判责口径（§6 的表）是固化成字段，还是只作为复盘时的人工指引。
- 是否和 G7（装一次、自动上报）一起做：快照 hook 与 G7 计划的 `.claude/settings.json` hooks 是同一个挂载点。
- 是否也给 Pilot 的数据做一版纯内容匹配的归属：不拍快照、覆盖面小，但不用装任何东西。
- **规矩还是机制。** 用户 2026-09-11：「有 worktree，如果大家都规范使用的话，其实不太会出现多个 session 同时一个改一个东西」。
  worktree 规范消掉的是**并发**那一类（§7 第一条的跨会话部分随之消失，同一会话里并行的子 agent 还在）；G11 的原始场景
  是**串行**的——同一个 worktree 上一条分支活过几个会话（compact、重开、隔天接着做），最后一个提交——worktree 管不到，
  能管到的是另一条规矩：**会话结束前把自己的改动提交掉**。立了这条，trailer 就是归属，G11 缩成检测违规：Stop / SessionEnd
  时工作树脏就提醒，doctor 报最近 N 个 commit 里几个的文件被别的会话改过，比快照便宜两个数量级。本仓自己的样本：
  main 上 09-09 一天有 5 个会话先后在同一条分支上提交（两个会话交替出现），同一分支多会话串行是常态；一个 commit 里
  混几个会话改动的有多少，看 §9 第 1 个数，它决定走哪条。
- **粒度：轮还是工具调用。** 判责（§6）问的是「指令对不对、实现错没错」，这是**轮**的粒度，hook 给 `prompt_id`。
  UserPromptSubmit 与 Stop 各拍一次，就把「agent 这一轮改的」和「两轮之间人改的」分开，快照次数少一到两个数量级，
  §7 里并发与嵌套的问题大半消失；轮内要到具体调用时，Edit / Write 从 transcript 直接有，只有 Bash 需要再细。
  倾向：轮为默认，工具调用粒度作为 Bash 上的可选加强。

### 11. 审计记录

四轮独立审计，都在合并之后跑，每轮的发现在下一轮之前改进正文与 demo；demo 的边界场景就是照这些发现搭的。
另有一轮与之并行的独立复核（第五轮，见末尾）。
下面的「改成」写的是**那一轮修完时**的做法，后一轮又改过的另行标出。

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
6 个小问题是口径与引文细节，外加删掉的文件会让 demo 直接中止。

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
3 个小问题：§7「按暂存发生在哪一段归属」说宽了，只有出发点工作树里没有的行才归给那一段（已改）；标签「快照开始前已在
暂存区里」TODO 里没提（已写进 §4③）；`e2abcd4` 说明的漏数（见上）。另补：二进制文件原来静默不报，现在给一行提示。

四轮的教训是同一条，一轮比一轮扎眼：**demo 的场景是照着想证明的结论搭的，恰好绕开了会出错的情形；修复也一样，
只修到了被指出的那个症状，修法自己带进来的问题（共用 ref、`cp` 丢 mtime、按行文本搜、丢掉的 diff 选项）照样没有场景去碰。**
第三轮的错 1 最典型：它不是没修，是修的时候为了让新场景通过，引入了一个比原问题更坏的启发式。第四轮的发现少了、
且都在边角；还没搭过场景的情形见 §5「demo 没覆盖的」，那里照样可能藏着错。

**第五轮**（另一会话从第一版 `514876d` 独立起审，与前四轮并行，2026-09-11 上午；修到 `02e3685` 后再对表）：
4 条与前四轮重合、已被修掉（父提交重开、部分暂存、共用 index 撞锁、并发窗口），另有 2 处错、6 处补充，都已写进正文。

| # | 问题 | 改成 |
|---|---|---|
| 错 1 | 失败的工具调用没有 PostToolUse（文档：失败走 `PostToolUseFailure`）。Bash 非零退出很常见，只挂 PostToolUse 会让它们一直「进行中」，同一轮后面的改动全被标并列 | 两个事件都挂（§4②、§9） |
| 错 2 | 只报新侧的行，删掉的行没有记录，而删检查正是典型 bug | `blame --reverse` 找删它的那一步（§4③；边界 16 实测） |
| 补 1 | 后台运行的 Bash 在 PostToolUse 之后还在写文件，改动落进 gap | 打标、之后的 gap 按歧义看（§7） |
| 补 2 | PreToolUse 字段集、子 agent 区分、权限前触发：官方文档有答案，一手未测 | §4①、§7 |
| 补 3 | 代价初量：热态一次快照约等于两次 `git status`（2.6k 文件 ~45ms，30k 文件 ~80ms），冷只在第一次 | §7 表 |
| 补 4 | 先量「多会话 commit 有多少」再决定走规矩还是走机制（用户提的 worktree 规范）；本仓样本 2/7 确定多会话、5 个没 trailer 比不了 | §9 第 1 个数、§10 |
| 补 5 | 粒度可能选细了：判责要的是轮，UserPromptSubmit + Stop 就够分「agent 改的」与「人改的」 | §10 |
| 补 6 | §6「gap 基本是人」与 §7「gap 不等于人」口径不一；归属记录 post-commit 写、下个 commit 才入仓 | §6 表、§10 |
