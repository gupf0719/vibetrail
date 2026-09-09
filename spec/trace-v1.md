# vibetrail trace 格式 v1

留痕数据的落盘格式。**目录位于被观测的仓库内**（`<repo>/.claude/trace/`），随代码走。

## 0. 它是什么，不是什么

**是**：本地 transcript 的**耐久投影**。原始流水（`~/.claude/projects/**.jsonl`）是真相源，
但它不入仓、体量数百 MB、且换机器即失。本格式把其中**跨会话仍有价值的那部分**固化下来。

**不是**：对话归档。正文一律不进（见 D2）。要读正文就按 `sessionId` 回原始 transcript；
transcript 没了就只剩摘要——这是**有意的取舍**，不是缺陷。

## 1. 三种记录，三个锚点

选锚点是本格式最重要的决定。三类记录的生命周期不同，硬套同一个锚会静默腐烂。

| 记录 | 锚点 | 为什么 |
|---|---|---|
| commit ↔ session 的关联 | **commit message trailer** | 见 §2 |
| 会话流水 | `sessionId` | 会话是**不可变的历史事实**，永不需要迁移 |
| 审计记录 | **`Vibetrail-Id` trailer** | 见 §4 |

### 1.1 目录

```
<repo>/.claude/trace/
├── sessions/<sessionId>.jsonl      # 会话流水
└── audits/<vibetrailId>.jsonl      # 审计记录
```

`sessions/` 下每个 session 只写**自己那个文件**，并发会话之间不会冲突，也不需要读-改-写。
`audits/` 按 patch 分文件，两个分支各审一次同一个 patch 再合并时，两侧各追加一行**必然冲突**
（实测 `CONFLICT (content)`）。被观测仓的 `.gitattributes` 须声明
`.claude/trace/audits/*.jsonl merge=union`，声明后三行齐全、无冲突（实测）。只圈 `audits/`：
`sessions/` 是整份重生成的投影，union 会静默合出两条 `end`，冲突时正解是重跑 `vibetrail-sync`
（`.gitattributes` 里有注释，故障套件 T11 / T15–T17 钉着）。
JSONL 而非单个 JSON 对象：追加即写，崩溃不会留下半个文件，配合 `merge=union` 并发追加可无冲突合并。

## 2. commit ↔ session：只用 trailer，不留第二份

commit 侧写 trailer：

```
Claude-Session: 0bf59c3d-59dc-416c-b21d-9137feef79af
```

它的语义是**「哪个会话执行了这次 `git commit`」**，不是「这次改动出自哪个会话」。
两者在「agent 改完当场提交」的工作流里重合，其他情况的缺口见 §7。

### 2.0 谁写、什么时候写

`.githooks/prepare-commit-msg`，判据是**环境变量**：

```bash
#!/bin/bash
# 写两个 trailer，条件不同：
#   Vibetrail-Id   —— 审计锚，**每个 commit 都要有**（人工提交也会被闸门要求审计）
#   Claude-Session —— 归属，只有 agent 提交才有（人工提交没有会话）
#
# 为什么锚是 trailer 而不是从内容推导：内容推导的锚（patch-id）在 rebase 改动上下文时
# 就会变，冲突 rebase 下必变——恰好是最需要它稳定的场景。trailer 在 message 里，
# git 重放时原样搬运，于是「跨重写迁移」这件事根本不存在。
g=$(git rev-parse --git-dir)                       # 重放别人的 commit（rebase / cherry-pick）不改归属
{ [ -d "$g/rebase-merge" ] || [ -d "$g/rebase-apply" ] || [ -f "$g/CHERRY_PICK_HEAD" ]; } && exit 0
sed '/^# -* >8 -*$/,$d' "$1" | grep -q -v -e '^[[:space:]]*$' -e '^#' || exit 0   # 截掉 scissors 后为空：让 git 照常拒绝（见 §2.0 注）
[ -n "$(tail -c1 "$1")" ] && echo >> "$1"          # 非编辑器路径的 merge（--no-edit / -m）没有末尾换行
newid(){                                           # 可移植的 uuid
    if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'
    elif [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid
    else printf '%s%s%s' "$(date -u +%s)" "${RANDOM}" "$$" | shasum | cut -c1-32; fi
}
# --if-exists doNothing 保证幂等：已有 id 的 message 再过一次 hook 不会被换掉
git interpret-trailers --in-place --no-divider --if-exists doNothing \
    --trailer "Vibetrail-Id=$(newid)" "$1"

[ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || exit 0     # 以下只对 agent 提交
git interpret-trailers --in-place --no-divider --if-exists doNothing \
    --trailer "Claude-Session=$CLAUDE_CODE_SESSION_ID" "$1"   # 并入已有 trailer 块；已有则不动（幂等）
```

最初的版本只有 4 行（`grep` 幂等守卫 + `printf` 追加）。2026-09-08 的三轮审计在四处抓到它**静默出错**，
以下全部实测（git 2.39）：

- **agent 执行 `rebase` / `cherry-pick` 会把人的 commit 记成 agent 的。** merge 后端的 rebase
  对每个重放的 commit 都跑本 hook，`$2` 恒为 `message`，与 `commit -m` 不可区分；人的 commit
  没有 trailer，幂等守卫不生效，于是被注入当前会话。agentDock 的 rebase + ff-only 工作流天天踩：
  agent 一次 `git rebase main` 就把分支上所有人工 commit 全改成「agent 的」。修法是重放期间
  （`rebase-merge` / `rebase-apply` 目录或 `CHERRY_PICK_HEAD` 存在）一律不动；`--apply` 后端本就
  不跑此 hook，那一项属防御。代价：agent 在 rebase 中途新造的 commit 也不带 trailer，可接受。
- **非编辑器路径的 merge（`--no-edit` / `-m`）下 trailer 粘进 subject。** 这条路径把消息末尾换行
  剥掉再交给 hook，直接追加会让 trailer 与 subject 落在同一段：`%(trailers:)` 解析为空，
  `%s` 变成 `Merge branch 'x' Claude-Session: …`。修法是先补末尾换行。
- **另起一段追加会把已有 trailer 挤出 trailer 区。** git 只把消息**最后一段**当 trailer 块；原版
  无条件先空一行再追加，于是上一段的 `Co-Authored-By:`（Claude Code 默认就写）、`Signed-off-by:`
  （DCO 项目的 `-s`）、`--trailer` 加的键全部不再被 `%(trailers:)` 识别。改用
  `git interpret-trailers` 并入现有块；`--if-exists doNothing` 顺带替代了 grep 幂等守卫，
  `--no-divider` 让正文里的 `---` 行不被当分隔符。
- **`-m ''` 与留空的 `commit -v` 会绕过 git 的空消息拒绝。** hook 填入 trailer 后消息非空，subject
  变成 `Claude-Session: …`。修法：先截掉 scissors 线及其后的 diff，再判「去掉空行与注释后为空」，
  为空就退出（假设 `core.commentChar` 为默认的 `#`）。副作用是**编辑器路径一律不注入**——
  `git commit` 不带 `-m` 时 hook 运行在编辑器之前，消息尚空。agent 从不开编辑器；人在带变量的
  shell 里手工提交因此不会被记成 agent 的，方向正确。带模板（`-t` / `commit.template`）或
  `--amend` 时消息非空，照常注入。

`CLAUDE_CODE_SESSION_ID` 实测**逐字等于 transcript 文件名**，Claude Code 注入在每个
Bash 调用的环境里；子 agent 的 Bash 里拿到的也是**父会话的 id**（与子 agent transcript 内的
`sessionId` 一致），所以子 agent 提交同样归到父会话。选它而不是状态文件，是因为环境变量是
**进程级**的：

| 场景 | 状态文件 | 环境变量 |
|---|---|---|
| 多 worktree 并发会话 | ❌ 串号 | ✅ 各进程各自的值 |
| 人工手动 `git commit` | ❌ 误记成 agent 的 | ✅ 变量不存在，不注入 |

> **判空守卫与 git 自身惯例不同，这是有意的。** git 的 `commit -s` 在编辑器打开**之前**
> 就写入 `Signed-off-by`，不因消息为空而跳过。我们反过来：消息为空就不注入，
> 让 git 照常以「空消息」中止提交。代价是**编辑器路径下不会有 trailer**；
> 由于 agent 恒带 `-m`、从不开编辑器，这个代价为零。
> 去掉判空的后果是 `git commit -m ''` 会被 trailer 填成非空而提交成功。

⚠️ **两个部署要点，漏了会静默失效**：

1. **`.githooks/` 必须提交进仓**。`core.hooksPath` 用相对路径时按**各 worktree 的根**解析，
   目录不入仓则 worktree 里根本没有这个文件——实测 worktree 提交时 hook 不触发、
   trailer 为空、**不报错**。
2. **`core.hooksPath` 是本地配置、不入仓**，每人 clone 后要跑一次
   `git config core.hooksPath .githooks`（git 出于安全故意不让仓库自动装 hook）。
   worktree 不必重复设——config 走 common dir 共享（实测）。

实测矩阵：agent 提交自动带 ✅ / 人工提交不带 ✅ / `--amend` 幂等 ✅ /
worktree 生效 ✅（前提是要点 1）/ 并发两个 session 不串 ✅ /
agent `rebase` 人工 commit 不沾 ✅ / agent `cherry-pick` 人工 commit 不沾 ✅ /
`merge --no-ff` 的 `--no-edit` 与 `-m` 路径 trailer 可解析、subject 干净 ✅ /
已有 `Co-Authored-By` / `Signed-off-by` / `--trailer` 保留 ✅ / `-m ''` 与留空的 `commit -v` 仍被 git 拒绝 ✅ /
编辑器路径不注入、不污染 subject ✅（前五条为最初实测，其余为三轮审计补测，最初的 4 行版全错）。

**trace 文件里不存 commit SHA 做关联**，哪怕那样查起来更快。理由是 SHA 在 rebase 后就变了，
而 trailer 跟着 message 走——留两份就是留一份必然漂移的拷贝。查询靠：

```bash
git log --all --format='%h %(trailers:key=Claude-Session,valueonly)' | grep <sessionId>   # session → commits
git log -1 --format='%(trailers:key=Claude-Session,valueonly)' <sha>                       # commit  → session
```

### 2.1 实测：trailer 在各种历史重写下的存活

| 操作 | 结果 |
|---|---|
| `rebase` | ✅ SHA 变、trailer 原样；没有 trailer 的人工 commit 被 agent 重放时**保持没有**（靠 §2.0 的重放判定；`--apply` 后端本就不跑此 hook） |
| `cherry-pick` | ✅ 同上 |
| `merge --ff-only` | ✅（不造新 commit） |
| `merge --no-ff` | ✅ 新 merge commit 记执行合并的会话（非编辑器路径 `--no-edit` / `-m` 靠 §2.0 的补换行，否则 trailer 粘进 subject） |
| `rebase -i` squash | ⚠️ 只留**最后一个被 squash 的 commit** 的 trailer：末尾是人工 commit 则全丢；`fixup` 反之留第一个（实测） |
| `merge --squash` | ❌ 原会话的 trailer 缩进进 body，`%(trailers:)` **解析不到**；执行 squash 的会话反而被记上——**错误归属** |

前三行覆盖 rebase + ff-only 的工作流，第四行覆盖 no-ff 合入。**用 squash 合流的项目不适用本方案的 §2**，
需要另找锚（未解，见 §7）。

## 3. 会话流水 `sessions/<sessionId>.jsonl`

首行是头，其后每行一个事件，`t` 是类型判别字段。

```json
{"t":"session","v":1,"id":"0bf59c3d-…","tool":"claude-code","toolVersion":"2.1.202",
 "entrypoint":"claude-desktop","startedAt":"2026-09-08T07:37:38Z","cwd":"…","branch":"…"}
```

```json
{"t":"diverge","kind":"interrupt","at":"…","turn":"<uuid>","human":true,"branch":"main"}
{"t":"diverge","kind":"classifier_blocked","at":"…","turn":"<uuid>","human":false,"branch":"main"}
{"t":"diverge","kind":"permission_denied","at":"…","turn":"<uuid>","human":true,"branch":"main"}
```

`branch` 是事件发生时的 `gitBranch`，可选。提取器 `tools/extract-diverge.jq` 的原始输出
另带 `sid`（所属 `sessionId`），那是写入方决定落到哪个文件的路由键，落盘后可省略。
`tool`（被拒的工具名）**尚未产出**；将来加上时按 §5 属于可选字段，不升版本。

```json
{"t":"end","at":"…","turns":{"user":8,"assistant":94,"tool":67},
 "models":["claude-opus-5"],"usage":{"input":…,"output":…,"cacheRead":…},
 "subagents":[{"id":"agent-ac22…","type":"general-purpose","desc":"审设计自洽性"}],
 "transcript":{"bytes":746075}}
```

`turn` 是原始 transcript 里的消息 `uuid`——**指针，不是内容**。transcript 在就能跳回去看
上下文，不在就只剩「某时刻发生过一次中断」。这是 D2 的直接后果。

### 3.1 `diverge.kind` 取值

本格式**唯一没有先例可抄**的部分。三个实现读下来：SpecStory 只认 interrupt
（一行前缀匹配），git-ai 与 claude-story 一个都不认——**字符串匹配就是这里的现有水平，
没有结构化字段可用**。

每条记录带 `human` 布尔：`true` 才计入人机分歧，`false` 是机器/基础设施行为。
混在一起统计会让「人拒了多少次」被分类器和链路故障污染。

| kind | human | 判据 |
|---|---|---|
| `interrupt` | ✅ | 去前导空白后 `startswith("[Request interrupted by user")` **且不含** `for tool use` —— 人主动打断 |
| `interrupt_for_tool_use` | ✅ | 同上但**含** `for tool use` —— 人拒绝工具调用时伴随的打断，**总是**与一条 `permission_denied` 同时出现 |
| `permission_denied` | ✅ | `is_error` 块正文 `^Permission to use .* has been denied`（带 `m` 标志）或 `^The user doesn't want to proceed with this tool use` |
| `classifier_blocked` | ❌ | 正文含 `denied by the Claude Code auto mode classifier` 或 `Blocked by classifier` —— auto mode 分类器拒的，不是人 |
| `permission_infra_fail` | ❌ | 正文含 `Tool permission request failed` 或 `Tool permission stream closed` —— 链路故障，不是任何人的决定 |

⚠️ **两个 interrupt 变体必须分开，否则一次「拒绝工具调用」被记两条。**
实测全语料：`for tool use` 变体 **35** 次，而「同一会话同一秒同时命中
`permission_denied` 与 `interrupt`」也恰是 **35** 次——精确对上。两者是**同一个人类动作
的两条记录**（turn uuid 不同）。合成一个 kind 会让「人主动打断了多少次」把拒绝也算进去。
统计「人机分歧总数」时，`interrupt_for_tool_use` 应与其配对的 `permission_denied` 计为一次。

判据全部**只读 JSON 字段**，不 grep 整行原文。`interrupt` 只认 user 消息的 text 块或字符串正文，
**不认** `tool_result` 块；其余三类**只认** `is_error == true` 的块正文（Claude Code 里只有 `tool_result`
块带 `is_error`，判据不另查 `type`）。原因见 §3.3。

`permission_denied` 的**排除子句**与规则 3 / 4 共用同一对谓词（`isClassifier` / `isInfra`）：
正文命中分类器或链路故障判据时不计为人拒，只落到对应的机器类 kind。防的是机器消息以
`Permission to use … has been denied` 开头的变体——语料里未见，属防御；fixtures t12 / t14 / t15
覆盖，保证同一条不会既算人拒又算机器拒。（第三轮审计前排除子句用的短语与规则 3 不同，
`…denied by the Claude Code auto mode classifier.` 不带 `Reason:` 时会双计，已修。）

#### 已删除的 kind

- **`user_edited_after_agent`** —— 曾被本文档称作「最硬的信号」，**该说法已被实测推翻**。
  全语料 **3507 次 `userModified` 取值全为 `false`**（755 个会话）。实测见 §3.4。
  提取器里对应的规则已于 2026-09-08 移除（此前文档说删了、代码没删，三处不一致）。
- **`correction`**（用户纠正话术的启发式）—— 未实现。现有四个 kind 都是硬信号、已有可用准确率，
  先把启发式挡在门外；要加须先有独立的准确率实测，且必须与硬信号分开统计。

### 3.2 准确率实测（2026-09-08，755 个会话 / 674MB）

| kind | 命中 | 精确率 | 召回率 |
|---|---:|---|---|
| `interrupt` | 277 | **100%**（277/277） | 100%，无遗漏 |
| `permission_denied` | 90 | 100%（人工逐条核对候选集） | **100%**（90/90，修复后） |
| `classifier_blocked` | 1 | — | — |
| `permission_infra_fail` | 6 | — | — |

召回率的基线是**无锚子串候选集**（`interrupt` 为 278 条），含义是「相对裸 grep 不漏」，
不是绝对召回——不含该子串的中断形态（若存在）测不到。

277 是**逐条命中数**。其中 13 条是子 agent 与父会话的传播重复（同一次打断记进两边），
作为事件数多报 4.7%；去重方案见 [CAPABILITIES §3.3](../CAPABILITIES.md)。

对照：**裸 grep 原文在对抗样本上精确率仅 10.5%**。以本项目的调研会话为靶
（它在命令输出里反复打印过 `Request interrupted` 字面量）：裸 grep 命中 19 条，
本规则命中 2 条，人工核对真实中断正是 2 次。

上表数字是修完 §3.3 里的坑之后才得到的。

### 3.3 实现这套判据时踩过的坑

写提取器的人必须知道这五条，否则数字会**静默错**（不报错、只是不对）：

1. **只读字段，绝不 grep 原文。** 会话自身会讨论这些标记（本项目的调研会话就是），
   grep 原文把「讨论」当成「发生」。同理 `interrupt` 判据必须排除 `tool_result` 块
   （其余三类读的就是 `is_error` 的 tool_result 块，靠锚定而非靠排除）。
2. **锚定，不要用无锚子串。** 无锚子串会误收 `<task-notification>` 这类正文里恰好
   提到该短语的记录（实测 278 命中里 1 条假阳）。SpecStory 的前缀故意不带右括号，
   正好同时覆盖 `[Request interrupted by user]` 与 `[...for tool use]` 两种变体。
3. **jq 的正则标志与 PCRE 相反**：dotall 是 `m` 不是 `s`（`s` 在这里是单行模式）。
   按 PCRE 习惯写 `s` 会**静默匹配失败**。权限拒绝的真实消息把多行命令嵌在中间
   （`Permission to use Bash with command <多行> has been denied.`），不加 `m` 会漏
   全部多行命令的拒绝——实测漏 2/90。
4. **取 `.toolUseResult` 这类多态字段的子字段前先判 `type=="object"`。** 它有时是 array 或
   string，直接索引会抛错。jq 抛错时该条记录**抛错点之后的规则**全部不再求值，之前已输出的
   命中保留，然后继续处理下一条输入；退出码只反映**最后一条**输入是否出错，中间的错误只留在
   stderr（实测）。实测曾有 1200 条记录触发此错误；
   因为出错的规则排在末尾，其他规则的命中实际没丢（去掉守卫重跑 fixtures，输出条数不变），
   但规则顺序一变、或在前面加一条读多态字段的规则，排在它后面的规则就会整条丢失。
   现在提取器已不读 `.toolUseResult`，这条留给将来加规则的人。同理 `message.content[]` 的元素
   先过 `objects`，`.text` 缺失时用 `// ""` 兜底——数组里混入裸字符串或缺字段的块同样会抛错。
5. **`is_error` 块的 `content` 可能是数组**（`[{"type":"text","text":…}]`）。直接 `tostring`
   会以 `[` 开头，而 jq 的 `^` 在任何标志下都只匹配串首，锚定判据永远不命中。提取器先把数组
   展开成各段 text 再匹配。抽样里 content 全是字符串，语料里有无数组形态未量。

判据依赖英文消息串，Claude Code 改文案即失效——**这是已知脆弱点**，见 §7。

### 3.4 `userModified` 与 `staleRecovered`：查清了什么

追查「`userModified` 什么条件下会置真」的结论：**没查到会置真的条件，但排除了最像的那个，
并顺带找到了一个真正会触发的字段**。

**排除「磁盘陈旧」假设（受控实验，决定性）**：Read 一个文件 → 用 Bash 外部改它 →
再 Edit。Claude Code 明确检测到并在结果里提示「the file had been modified on disk since
you last read it」，而该次 Edit 的记录是：

```
staleRecovered: true      ← 陈旧是由这个字段承载的
userModified:   false     ← 不是它
```

所以 **`staleRecovered` 才是「Read 之后文件被改过」的信号**，它只在为真时出现（否则字段缺失），
全语料 21 次。`userModified` 与陈旧无关。

**`staleRecovered` 也不是人机分歧信号**：把 21 次逐条回溯，**没有一例是确认的人工修改**。
16 例能直接对上 Claude 自己的 `sed`/`python3`/`tee` 命令；剩下 5 例放宽到全会话范围后，
同样都有 Bash 命令碰过该文件（2~156 条）。根因是本工作流里 Claude 大量经 Bash 改文件，
而**人基本不直接碰文件**——人指挥、Claude 动手。

**为何在 desktop 客户端不可达（交互实验，已定论）**：`userModified` 只由写文件的工具
（Edit / Write）产出，不出现在 Bash / Read / Task 上。语料的 212413 条记录里
`entrypoint` **100% 是 `claude-desktop`**，`permissionMode` 只有 `acceptEdits`(1213)
与 `auto`(1039)——两者都自动接受编辑，从未出现过「编辑需人审批」的流程。

于是装了一道 `PreToolUse` 闸门强制返回 `permissionDecision: "ask"`，逐档实测：

| 权限模式 | 闸门返回 ask | 是否弹审批 | `userModified` |
|---|---|---|---|
| `acceptEdits` | ✅ | ✅ 弹出（截图确认） | false |
| `default`（UI 名 Manual） | ✅ | ✅ 弹出（截图确认） | false |
| `auto` | ✅ | 未确认 | false |

**hook 返回的 `ask` 能穿透 `acceptEdits`。** 所以语料里 3507 次全为 `false` 的原因
**不是**「模式压掉了弹窗」，而是没有任何 hook 强制 ask，而这两档模式本身就自动接受编辑。

弹出的审批面板**一律只有 `Deny` 与 `Allow once` 两个按钮**，附一段 diff 预览，
**没有任何修改提案的操作面**。

> ⚠️ 这张表的前两行曾写成「被模式盖过、不弹窗」，是错的。错因不是判据写错，
> 而是**拿「我没观察到弹窗」当成了「弹窗没出现」**——审批弹窗根本不出现在
> agent 的工具结果里，agent 没有观察它的通道。凡是「某事没发生」的断言，
> 先问一句「我有没有能观察到它发生的通道」。

**结论：在 Claude desktop 客户端里 `userModified` 不可能为真**——不是没触发到条件，
是这个客户端不提供「改动 Claude 提出的编辑」这个动作。该字段大概率服务于提供该能力的
其他客户端（IDE 扩展一类），不在本环境的取值范围内。

**对本格式的结论**：两个字段都不能用作人机分歧信号。这不是字段的问题，是这个工作流
的形状——**人不碰文件，所以分歧不落在文件上，只落在对话上**（打断、拒绝工具调用）。
现有四个 kind 恰好覆盖的就是对话侧，这个负结果反过来支持了当前设计。

## 4. 审计记录 `audits/<vibetrailId>.jsonl`

锚是 commit message 里的 trailer：

```
Vibetrail-Id: 8cfb718c-f3d2-4945-bf58-97e8b9acdd6b
```

由 `prepare-commit-msg` 写入（与 `Claude-Session` 同一个 hook），读取：

```bash
git log -1 --format='%(trailers:key=Vibetrail-Id,valueonly)' <sha>
```

### 4.0 为什么锚在 message 里，而不是从内容算

**「跨历史重写迁移」这件事被消掉了，而不是被解决了。** trailer 在 commit message 里，
git 重放（rebase / amend / cherry-pick）时原样搬运，锚根本不变——没有「旧锚 → 新锚」
的映射需要维护。

这一版之前用的是 `git patch-id`，换掉它的理由不是它有 bug，是**它在最需要稳定的场景
必然失效**：

| 场景 | patch-id | trailer |
|---|---|---|
| 无冲突 rebase | 不变 | 不变 |
| **上下文行被别人改过** | **变**（实测；`git-patch-id` 文档亦如此说）| 不变 |
| **冲突 rebase** | **必变**（冲突一定伴随上下文变化）| **不变**（实测）|
| merge commit | 需 `--cc`，而 `patch-id` 不认 combined diff 的 `@@@` 头，只把文件头三行喂进哈希 ⟹ 锚 = f(首个冲突文件路径)，两个内容毫不相干的解决算出同一个值（实测）| 一视同仁 |

「跨 rebase 稳定」是当初选 patch-id 的**全部理由**，而它恰好在冲突 rebase 下不成立。

### 4.1 三个必须知道的代价

| 代价 | 说明 |
|---|---|
| **cherry-pick 共用锚** | 复制 message ⟹ 两个 commit 同一个锚，审一个等于标了另一个。Gerrit 的 Change-Id 把这当**特性**（同一个逻辑变更），审计语义上也成立。哨兵 T13 钉住，防将来悄悄变 |
| **`merge --squash` 丢锚** | 原 message 缩进进 body，`%(trailers:)` 解析不到。本仓 1760 个 commit 实测 **0 次 squash**；用 squash 合流的项目不适用本节 |
| **不能追溯** | 装 hook 之前的 commit 没有锚。闸门按 fail-closed 拦住并提示装 hook（哨兵 T14），不当作「无需审计」放行 |

### 4.2 锚有两道独立防护

1. hook 在 rebase / cherry-pick 时**早退**，不碰重放的 message
2. `git interpret-trailers --if-exists doNothing` **幂等**，已有 id 不覆写

两道各自都能保住锚。代价是**单独破坏任何一道，测试都不会红**——sanity-revert 时
必须两道同时破坏才见得到 T7/T13 转红（实测）。这是「双层防护遮蔽」的实例，
改这段代码时留意。

### 4.3 为什么不照抄 git-ai 的 SHA + `post-rewrite`

git-ai 锚在 commit SHA 上，靠 `post-rewrite` hook 拿 git 给的精确「旧 sha → 新 sha」
映射（实测冲突 rebase 下映射准确）。那条路可行，但对我们多一层机制：要再装一个 hook、
要写迁移逻辑、还留着「重写发生时 hook 没跑」的洞（另一个 clone、CI、`filter-branch`）。

trailer 这条路把这三样都省掉了。代价是上面 §4.1 那三条——我们的工作流（rebase + ff-only、
0 次 squash）正好落在它的适用区间内。

## 4.4 记录信封：对齐 Agent Trace 的字段名，但**不声称合规**

三类记录共用一层信封，字段名取自 [Agent Trace](https://agent-trace.dev/) RFC v0.1.0：

| 字段 | 含义 |
|---|---|
| `version` | 本格式版本 |
| `id` | 该条记录自身的 UUID |
| `timestamp` | RFC 3339 UTC。**取事件发生时间，不取「此刻」**——投影必须确定性，否则每次 sync 都改文件、弄脏工作树，而脏工作树会让三个闸门全部跳过（§3） |
| `tool` | `{name, version}` |
| `vcs` | `{type, revision}` |

**为什么不声称合规**：Agent Trace 的核心是**行级代码归属**，必填 `files[]` →
`conversations[].ranges[]` 带 `start_line`/`end_line`。我们不做行级归属（见 §4.5），
**没有任何东西能填进 `files[]`**。硬造一个填不出内容的必填字段，就是本文档反复在修的
那类毛病。所以只借语义真正吻合的信封字段，不写 conformant。

该规范对我们最关心的问题也明确留白：*"How should I handle rebases or merge commits?"*
标注为可能影响未来版本，暂无定论——所以 §4.0 的锚仍是自己定的。

## 4.5 已知做不到：多个 session 改、一个 session 提交

session A、B 改了代码，在 session C 里一起 commit —— **锚上只会有 C**。
`Claude-Session` 记的是**谁提交**，不是**谁写的**。

原始 transcript 里的还原能力分三档（实测数据）：

| 档 | 能答什么 | 覆盖率 |
|---|---|---|
| `Edit` / `Write` 工具记录 | 精确到文件 + 行范围 + diff + sessionId | **只覆盖走工具的改动**。实测某会话 10 次 Edit vs 318 条含改文件动作的 Bash —— **约 3%** |
| Bash 命令文本 | 文件名出现在命令里 ⟹ 可反查「哪些 session 碰过这个文件」。实测某文件收敛到 3 个候选 | 高，但**「提到」≠「改了」**（`cat`/`grep` 也提到），是候选过滤器不是归属 |
| 全文检索 | 按错误串 / 符号定位到会话 | 全量，但无结构 |

**要做到「任何改动都能精确归属」，必须在每次工具调用前后快照工作树自己算 diff**——
那是 git-ai 用常驻守护进程做的事，本项目按代价否决（见 DESIGN.md）。

**因此本格式不提供代码归属，只提供会话归属与审计归属。** 查询端可以给「碰过这个文件的
session」作为候选，但那是收敛，不是答案。

## 5. 稳定面

以下属于公开约定，**变更需要升 `v`**：

- 目录布局：`sessions/<sessionId>.jsonl`、`audits/<vibetrailId>.jsonl`
- 每行一个 JSON 对象，`t` 为类型判别字段
- 已定义的 `t` 取值：`session` / `diverge` / `end` / `audit`
- `Claude-Session` 这个 trailer 键名
- 审计锚取自 commit message 的 `Vibetrail-Id` trailer

以下**不属于**稳定面，可随时增补而不升版本：

- 任何记录里的新增可选字段（消费方必须忽略不认识的字段）
- `diverge.kind` 的新增取值（消费方遇到不认识的 kind 应保留并跳过，不得报错）
- `findings[].severity` 的取值集合

## 6. 版本

`v` 出现在**每个文件的首条记录**上（`session` / `audit`），是**文件级**版本，
后续行不重复携带。它是整数，只在**破坏性变更**时递增（删字段、改字段语义、改目录布局）。
新增可选字段不升版本。消费方读到更高的 `v` 应当拒绝解析而不是猜。

字段名一旦发布就**不再改拼写**——哪怕拼错了。（这条是抄来的教训：
git-ai 标准里 `overriden_lines` 少了一个 d，shipped 之后成了既成事实，
要等下一个大版本才能改。）

## 7. 已知不解决

- **squash 合流**下 §2 的 trailer 关联失效（`merge --squash` 完全解析不到，
  `rebase -i` squash 只留最后一个被 squash 的 commit 的 trailer）。agentDock 的工作流是 rebase + ff-only，
  暂不受影响。
- **没有锚的 commit 无法记录审计**（§4）：装 hook 之前的 commit、以及 message 被手改
  删掉 trailer 的 commit。闸门对这类按 fail-closed 拦住并提示装 hook，不放行。
  （merge commit 现在**有**锚——hook 对 merge 同样写 trailer，这与上一版相反。）
- **trailer 记的是「谁执行了 commit」，不是「改动出自谁」**（§2）。人工提交 agent 写的代码
  不带 trailer；一次 commit 含多个会话的改动时只记执行提交的那个。要追「这段改动出自哪个会话」
  仍得回 transcript 按文件路径查。
- **amend 的归属取「首次提交者」**：他人 amend agent 的 commit，trailer 保留原会话（幂等守卫）；
  agent amend 人工 commit 则被记成 agent 的（原本没有 trailer，无从保留）。两者都实测；后者是否
  合理未定——agent 确实改了这个 commit。
- **`cherry-pick -n` 之后的 commit 与 `revert`** 按「谁执行了 commit」记（hook 运行时
  `CHERRY_PICK_HEAD` / `REVERT_HEAD` 都不存在），与整个 cherry-pick「不沾」的行为不一致。实测、已知。
- **判据依赖英文消息串**，Claude Code 改文案即静默失效。没有结构化字段可替代
  （三个实现里唯一处理了中断的 SpecStory 也是字符串匹配）。缓解只能是：判据集中在一处、配正负例回归、
  数字突变时当作信号而非当作事实。
- **`userModified` 在 desktop 客户端不可达**（见 §3.4，已交互实测定论）。
  它在别的客户端（提供「修改提案」能力的 IDE 扩展一类）会不会置真，超出本环境可验范围。
  本格式不依赖它。
- **transcript 丢失后**指针（`turn` uuid）全部悬空。这是 D2 的既定代价。
- **同一 patch 出现在多个分支**（cherry-pick）时共用一条审计记录。
  这多半是对的（同一改动同一审计），但没有实测。
