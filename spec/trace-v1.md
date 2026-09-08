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
| 审计记录 | **`git patch-id --stable`** | 见 §4 |

### 1.1 目录

```
<repo>/.claude/trace/
├── sessions/<sessionId>.jsonl      # 会话流水
└── audits/<patchId>.jsonl          # 审计记录
```

每个 session 只写**自己那个文件**，所以并发会话之间不会冲突，也不需要读-改-写。
JSONL 而非单个 JSON 对象：追加即写，崩溃不会留下半个文件，git 合并 append 也更干净。

## 2. commit ↔ session：只用 trailer，不留第二份

commit 侧写 trailer：

```
Claude-Session: 0bf59c3d-59dc-416c-b21d-9137feef79af
```

**trace 文件里不存 commit SHA 做关联**，哪怕那样查起来更快。理由是 SHA 在 rebase 后就变了，
而 trailer 跟着 message 走——留两份就是留一份必然漂移的拷贝。查询靠：

```bash
git log --all --format='%h %(trailers:key=Claude-Session,valueonly)' | grep <sessionId>   # session → commits
git log -1 --format='%(trailers:key=Claude-Session,valueonly)' <sha>                       # commit  → session
```

### 2.1 实测：trailer 在各种历史重写下的存活

| 操作 | 结果 |
|---|---|
| `rebase` | ✅ SHA 变、trailer 原样 |
| `cherry-pick` | ✅ |
| `merge --ff-only` | ✅（不造新 commit） |
| `rebase -i` squash | ⚠️ **只留最后一个** session |
| `merge --squash` | ❌ 原 message 缩进进 body，`%(trailers:)` **解析不到** |

前三行覆盖 rebase + ff-only 的工作流。**用 squash 合流的项目不适用本方案的 §2**，
需要另找锚（未解，见 §7）。

## 3. 会话流水 `sessions/<sessionId>.jsonl`

首行是头，其后每行一个事件，`t` 是类型判别字段。

```json
{"t":"session","v":1,"id":"0bf59c3d-…","tool":"claude-code","toolVersion":"2.1.202",
 "entrypoint":"claude-desktop","startedAt":"2026-09-08T07:37:38Z","cwd":"…","branch":"…"}
```

```json
{"t":"diverge","kind":"interrupt","at":"…","turn":"<uuid>"}
{"t":"diverge","kind":"user_edited_after_agent","at":"…","turn":"<uuid>","path":"src/foo.go"}
{"t":"diverge","kind":"permission_denied","at":"…","turn":"<uuid>","tool":"Bash"}
```

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
| `interrupt` | ✅ | user 消息的 text 块或字符串正文，去前导空白后 `startswith("[Request interrupted by user")` |
| `permission_denied` | ✅ | `is_error` 块正文 `^Permission to use .* has been denied`（带 `m` 标志）或 `^The user doesn't want to proceed with this tool use` |
| `classifier_blocked` | ❌ | 正文含 `denied by the Claude Code auto mode classifier` —— auto mode 分类器拒的，不是人 |
| `permission_infra_fail` | ❌ | 正文含 `Tool permission request failed` / `stream closed` —— 链路故障，不是任何人的决定 |

判据全部**只读 JSON 字段**，不 grep 整行原文；`tool_result` 块一律排除。原因见 §3.3。

#### 已删除的 kind

- **`user_edited_after_agent`** —— 曾被本文档称作「最硬的信号」，**该说法已被实测推翻**。
  全语料 **3507 次 `userModified` 取值全为 `false`**（2128 次 Edit，755 个会话）。
  这个字段在本工作流下从不为真，作为信号是死的。它究竟在什么条件下会置真尚未查明，
  查明前不重新引入。
- **`correction`**（用户纠正话术的启发式）—— 未实现。三个硬信号已有可用准确率，
  先把启发式挡在门外；要加须先有独立的准确率实测，且必须与硬信号分开统计。

### 3.2 准确率实测（2026-09-08，755 个会话 / 674MB）

| kind | 命中 | 精确率 | 召回率 |
|---|---:|---|---|
| `interrupt` | 277 | **100%**（277/277） | 100%，无遗漏 |
| `permission_denied` | 90 | 100%（人工逐条核对候选集） | **100%**（90/90，修复后） |
| `classifier_blocked` | 1 | — | — |
| `permission_infra_fail` | 6 | — | — |

对照：**裸 grep 原文在对抗样本上精确率仅 10.5%**。以本项目的调研会话为靶
（它在命令输出里反复打印过 `Request interrupted` 字面量）：裸 grep 命中 19 条，
本规则命中 2 条，人工核对真实中断正是 2 次。

三个曾经出错、修复后才达到上表数字的点，都记在 §3.3。

### 3.3 实现这套判据时踩过的坑

写提取器的人必须知道这四条，否则数字会**静默错**（不报错、只是不对）：

1. **只读字段，绝不 grep 原文。** 会话自身会讨论这些标记（本项目的调研会话就是），
   grep 原文把「讨论」当成「发生」。同理必须排除 `tool_result` 块。
2. **锚定，不要用无锚子串。** 无锚子串会误收 `<task-notification>` 这类正文里恰好
   提到该短语的记录（实测 278 命中里 1 条假阳）。SpecStory 的前缀故意不带右括号，
   正好同时覆盖 `[Request interrupted by user]` 与 `[...for tool use]` 两种变体。
3. **jq 的正则标志与 PCRE 相反**：dotall 是 `m` 不是 `s`（`s` 在这里是单行模式）。
   按 PCRE 习惯写 `s` 会**静默匹配失败**。权限拒绝的真实消息把多行命令嵌在中间
   （`Permission to use Bash with command <多行> has been denied.`），不加 `m` 会漏
   全部多行命令的拒绝——实测漏 2/90。
4. **取 `.toolUseResult` 子字段前先判 `type=="object"`。** 它有时是 array 或 string，
   直接索引会抛错，而 jq 抛错会丢掉**整条记录**，连带该记录上其他规则的命中一起消失。
   实测这一条曾让 1200 条记录被静默跳过。

判据依赖英文消息串，Claude Code 改文案即失效——**这是已知脆弱点**，见 §7。

## 4. 审计记录 `audits/<patchId>.jsonl`

```bash
git diff-tree -p --root <sha> | git patch-id --stable | awk '{print $1}'
```

三个参数都是必需的，各挡一个坑（都实测过）：

| 参数 | 去掉会怎样 |
|---|---|
| `--stable` | 结果在不同 git 版本间不保证一致 |
| `--root` | 根 commit **静默返回空串**（不报错），整条记录锚在空 id 上 |
| `-p` | 没有 patch 正文，`patch-id` 无输入 |

写成 `<sha>^ <sha>` 也能work，但在根 commit 上 `fatal: ambiguous argument`。
`--root` 在普通 commit 上与之结果**逐字相同**（实测），所以无条件加它即可，
不需要分支判断。

```json
{"t":"audit","v":1,"patchId":"7ecde6a6…","kind":"audit","sessionId":"0bf59c3d-…",
 "at":"…","shaAtTime":"71427ba…","subject":"docs: 开发过程留痕方案",
 "agents":[{"type":"general-purpose","perspective":"并发共享态","findings":3}],
 "findings":[
   {"id":"H1","severity":"HIGH","claim":"NewSharedChildSession 共享 values 但 mu 独立",
    "verdict":"confirmed","fix":"<sha 或说明>"},
   {"id":"H2","severity":"HIGH","claim":"Resume 未校验 GraphID",
    "verdict":"false-positive","why":"上游已在 Run 入口 fail-fast"}]}
```

`shaAtTime` 是**写入当时**的 SHA，仅作人读线索，**rebase 后会失效，不要拿它做关联**。
关联一律走 `patchId`。

### 4.1 为什么换掉现在的 `<sha>.audit.done`

两个问题：

1. **它是 0 字节**。294 个 marker 总字节数 0——只记「审过」，不记「审了什么、
   报了几个、几真几假」。于是「命中率 33-43%」这类数字只能人肉从对话里数，
   而对话会被压缩掉。改成有内容后，这些数字是**算出来的**。
2. **SHA 锚会腐烂**。实测本仓 294 个 marker 中 **4 个的 SHA 已不存在**（98.6% 存活）。
   rebase + ff 的流程让腐烂很慢，但它是静默的——marker 还在，指向的 commit 没了。
   `patch-id` 实测跨 rebase 稳定（SHA 变、patch-id 不变）。

O(1) 查询保留：Stop hook 仍是一次 `[ -f audits/<patchId>.jsonl ]`，只是多一步算 patch-id。

## 5. 稳定面

以下属于公开约定，**变更需要升 `v`**：

- 目录布局：`sessions/<sessionId>.jsonl`、`audits/<patchId>.jsonl`
- 每行一个 JSON 对象，`t` 为类型判别字段
- 已定义的 `t` 取值：`session` / `diverge` / `end` / `audit`
- `Claude-Session` 这个 trailer 键名
- patch-id 用 `git patch-id --stable` 计算

以下**不属于**稳定面，可随时增补而不升版本：

- 任何记录里的新增可选字段（消费方必须忽略不认识的字段）
- `diverge.kind` 的新增取值（消费方遇到不认识的 kind 应保留并跳过，不得报错）
- `findings[].severity` 的取值集合

## 6. 版本

`v` 是整数，只在**破坏性变更**时递增（删字段、改字段语义、改目录布局）。
新增可选字段不升版本。消费方读到更高的 `v` 应当拒绝解析而不是猜。

字段名一旦发布就**不再改拼写**——哪怕拼错了。（这条是抄来的教训：
git-ai 标准里 `overriden_lines` 少了一个 d，shipped 之后成了既成事实，
要等下一个大版本才能改。）

## 7. 已知不解决

- **squash 合流**下 §2 的 trailer 关联失效（`merge --squash` 完全解析不到，
  `rebase -i` squash 只留最后一个）。本仓工作流是 rebase + ff-only，暂不受影响。
- **判据依赖英文消息串**，Claude Code 改文案即静默失效。没有结构化字段可替代
  （三个实现都这样做）。缓解只能是：判据集中在一处、配正负例回归、
  数字突变时当作信号而非当作事实。
- **`userModified` 为何恒为 `false` 未查明**。它在什么条件下会置真、是否只在
  IDE 并行编辑场景下有效，都还不知道。查明前不重新引入该 kind。
- **transcript 丢失后**指针（`turn` uuid）全部悬空。这是 D2 的既定代价。
- **同一 patch 出现在多个分支**（cherry-pick）时共用一条审计记录。
  这多半是对的（同一改动同一审计），但没有实测。
