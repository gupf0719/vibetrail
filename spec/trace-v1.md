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

这是本格式**唯一没有先例可抄**的部分（调研过的工具无一记录人机分歧）。首批四个：

| kind | 判据 | 说明 |
|---|---|---|
| `interrupt` | transcript 出现 `Request interrupted by user` | 人打断了 agent |
| `user_edited_after_agent` | Edit 的 `toolUseResult.userModified == true` | **最硬的信号**：模型改完，人又手改 |
| `permission_denied` | 权限请求被拒 | 人不同意某个操作 |
| `correction` | 用户消息命中纠正话术 | ⚠️ 启发式，会误判，见 §7 |

前三个是**机器可判**的（读字段即可，无歧义）。第四个是启发式，**必须单独标注**，
不要和前三个混在一起统计——否则准确率会被它拖着走而没人知道。

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
- **`correction` 的判据是启发式**，会误判。首版把它与三个硬信号分开标注，
  准确率待实测后再定去留。
- **transcript 丢失后**指针（`turn` uuid）全部悬空。这是 D2 的既定代价。
- **同一 patch 出现在多个分支**（cherry-pick）时共用一条审计记录。
  这多半是对的（同一改动同一审计），但没有实测。
