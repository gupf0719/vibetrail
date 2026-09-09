# 开发过程留痕与审计方案

> **状态**：L3 已实现（提取器 + 755 会话实测），L1 机制已实测待落地，L2 待实现。
> 本文记录问题定义、实测结论与已定决策；落盘格式见 [spec/trace-v1.md](spec/trace-v1.md)。
> **目标**：任何一个 commit 都能追回「它是怎么来的」；复盘时能定位人机在哪一步对不上。
>
> **两样东西，两个去处——别混**：
> - **工具**（本项目）住在这里，独立于任何被观测的仓库。它不是某个产品的特性，
>   而是开发流程的基建，因此有自己的版本与生命周期。
> - **留痕数据**落在**被开发的那个仓**里（如 `<repo>/.claude/trace/`），随代码走。
>   这是 D1 的全部意义——clone 下来就能看到「这个 commit 怎么来的」，
>   数据离开它描述的代码就失去价值。
>
> 首个观测对象是 agentDock，但本项目**不属于 agentDock**，也不应假设只服务它。

## 1. 问题：不是没记，是三处断链

Claude Code 已经在写完整流水，无需自建采集层。以下实测数据均取自**首个观测对象 agentDock**
（2026-09-08），不是本项目自身：

| 记录 | 位置 / 字段 |
|---|---|
| 每轮对话 | `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl`；`uuid` + `parentUuid`（DAG）、`timestamp`、`gitBranch`、`cwd`、`permissionMode`、`model`、`usage`、`requestId` |
| 模型思考 | `thinking` block 全文 |
| 文件改动 | `structuredPatch` + `oldString` / `newString` / `originalFile`（另有 `userModified` / `staleRecovered`，见 §2.4 —— 都不可用）|
| 命令执行 | `stdout` / `stderr` / `interrupted` / `returnCodeInterpretation` |
| 子 agent | `<sessionId>/subagents/agent-*.jsonl` 独立完整 transcript + `.meta.json`（`agentType` / `description` / `toolUseId`；2.1.202 实测。2.1.85 的样本里只有前两项，2.1.260 另多 `spawnDepth`——字段集随版本变） |
| 人的动作 | `queue-operation`（排队、中断）、`Request interrupted by user`、`origin.kind` |

体量：agentDock 的 transcript 已累积 406MB，单 session 最大 106MB / 49341 行。

**断链一：commit ↔ session 无关联。** 实测 agentDock 全仓 0 个 session trailer
（`git log --all --format=%B | grep -cE "^(Claude-Session|Session-Id|Transcript):"` → 0）。
拿到一个 commit 无法反查产出它的对话。`git blame` 只到行，到不了意图。

**断链二：audit marker 是 0 字节布尔值。** `.claude/audit/` 下 637 个文件，总字节数 0
（`mark-audit.sh` 只 `touch`）。CLAUDE.md 里「命中率 33-43%」「R29 揭露 6 真 finding」
这类数字是人肉从对话里数出来的，而对话会被 compact。
这与 `feedback_persist_decisions_to_doc`（决策当场写回文档别留对话）是同一个病，
只是发生在 audit 维度——CLAUDE.md 自己已写「marker 不带理由，假标记比没标记更坏」，
问题被识别了但没被解决。

**断链三：人机分歧点没索引。** 复盘要找的是「人在哪儿不同意机器」——打断、
拒绝工具调用这些信号确实存在于 transcript 里，但埋在 106MB 中没有索引。

> 本条最初写的是「`userModified: true` 是机器可判的硬信号」。**该说法已被实测推翻**，
> 见 §2.4。分歧信号在这个工作流里落在**对话侧**而非文件侧，L3 据此实现。

（次要：transcript 在 `~/.claude/projects/`，在任何仓库之外、不入 git，换机器即丢。
此处原写「`.gitignore:9` 排除 `.claude/projects/`」——仓库的 .gitignore 管不到 home 目录，因果不成立，已删。）

## 2. 实测结论（2026-09-08，本机 + 本 worktree）

### 2.1 机制层：hook 在 desktop app 下可用 —— 这是全部结论的地基

向 `.claude/settings.local.json` 注入 `PostToolUse` 探针后立即生效（**热加载，无需重启**），
捕获到的 stdin 含：

```
session_id, transcript_path, cwd, permission_mode, prompt_id,
hook_event_name, tool_name, tool_input, tool_response, tool_use_id, duration_ms
```

**`transcript_path` 直接给出本会话 JSONL 的绝对路径**——不需要做 ID 映射。
（注：desktop 侧 MCP 报的 sessionId 形如 `local_<uuid>`，与 transcript 文件名**不是同一个
ID 空间**，实测一例对不上。但 hook 直接给路径，绕开了这个问题。）

**推论**：工具按挂钩机制分三类，前两类 CLI / desktop 通用，第三类只能 CLI。

| 类型 | desktop 可用 | 代表 |
|---|---|---|
| 读 `~/.claude/projects/` 的文件监听型 | ✅（desktop 写同一目录，已实证） | claude-code-log、cc-audit-log、claude-story、`specstory sync` |
| Claude Code hook 型 | ✅（本节实证） | git-ai |
| 进程包装型 | ❌（desktop 不经过 wrapper） | `specstory run claude` |

### 2.2 工具层

| 工具 | 结论 | 证据强度 |
|---|---|---|
| **git-ai** v1.7.2 | 二进制本机可运行（checksum 校验一致）；靠 `PreToolUse`/`PostToolUse` hook 跑 `checkpoint claude --hook-input stdin`，与探针抓到的 stdin 格式一致；行级归属存 Git Notes `refs/notes/ai`，spec 定义了 rebase / squash / merge / cherry-pick / reset / stash / amend 下的迁移；worktree 下 `git-common-dir` 指主仓 ⟹ **notes 跨 worktree 共享**；有 `uninstall-hooks` 可逆 | 实测 + 读源码 + 读 spec v3.0.0 |
| **SpecStory** | `specstory sync` 按 cwd 找会话，**不需要 wrapper**，成功捡起本 desktop 会话（184K markdown，文件名自带 `claude-desktop`）；保留用户 prompt、agent 文本、工具调用、`[Request interrupted by user]` | 实测（源码构建） |
| SpecStory 的缺口 | **丢文件级证据**：Edit 只渲染成「成功消息」，`oldString` / `newString` / `structuredPatch` / `userModified` 全部不解析（源码 grep 0 命中 + 真做一次 Edit 对照验证）；且按 cwd 隔离，主仓会话在 worktree 内 sync 不到 | 实测 |
| Claude Code 自带 OTel | 本机版本 2.1.202 ≥ traces beta 起始版 2.1.121，即已具备；但 **prompt 内容默认脱敏只记长度** ⟹ 给形状不给叙事 | 官方文档（二手） |

⚠️ **一条方法论教训（现场踩到）**：第一次用 `grep -c 'userModified'` 数 SpecStory 的
保真度，得到「9 处命中」——**假阳**，命中的是我自己命令里打过的这个字面量，不是渲染结果。
换成「真做一次 Edit 再抽整段看」才得到真答案。对应 CLAUDE.md「断言选在不承重的维度上，
等于没测」。

### 2.3 业内没解的三件事

1. **阈值问题**：改几行算 AI 写的，没有原则性答案（行级归属假设了实际不存在的干净边界）。
2. **审计过程本身的留痕**：所有工具审的是**代码**，没人审**审计过程**。断链二无现成方案。
3. **对话侧的人机分歧无人索引**：SpecStory 只认中断（一行前缀匹配），
   git-ai 与 claude-story 一个都不认。权限拒绝、机器/人的区分无人做。

### 2.4 两个曾被寄予厚望的字段，都不可用

- **`userModified`**：全语料 3507 次取值**全为 `false`**。交互实测定论——desktop 客户端的
  审批面板只有 `Deny` / `Allow once`，**没有「修改提案」这个动作**，所以它不可能为真。
- **`staleRecovered`**：真会触发（21 次），语义是「Read 之后文件被改过」。但逐条回溯，
  **无一例是人改的**——16 例直接对上 Claude 自己的 `sed`/`python3`，其余 5 例放宽到
  全会话范围后同样有 Bash 碰过。根因是这个工作流里**人不碰文件**：人指挥、Claude 动手。

详见 [spec/trace-v1.md §3.4](spec/trace-v1.md)。

### 2.5 git-ai 实装评估：已否决

Q5 曾倾向采纳。**实际安装后否决**，理由是代价结构不适合推广给全体开发者：

| 实测 | 数值 |
|---|---|
| 本地库占盘 | **833MB**，持续增长 |
| `metrics-db` 内容 | 206509 行，**全部 `delivered_ts IS NULL`**（排队待上传），含**完整 prompt 正文** |
| `prompt_storage` 默认值 | `default` —— 源码注释原话 *"prompts uploaded via CAS API"* |
| 触发条件 | **光跑一次二进制**（`git-ai status`）就建库、起守护进程、开吞历史；不是 `install-hooks` 干的 |
| 额外改动 | 装了 Cursor hooks + 扩展 `git-ai.git-ai-vscode`（未要求）|
| 网络 | 守护进程当前**零对外连接**（未登录，发不出去）|

我们只需要它的一件事——commit ↔ session 关联——而那件事一个不到十行的 `prepare-commit-msg`
就能做（§3 L1）。放弃的行级归属与 `overriden_lines` 对应的是文件侧分歧，而 §2.4 已证明
该维度在本工作流接近空。**为接近空的维度付 833MB 常驻，推广不成立。**

已完整卸载并逐项核对还原（hooks / 二进制 / 本地库 / 全局 settings / Cursor 侧）。

## 3. 分层方案

| # | 内容 | 状态 |
|---|---|---|
| L1 | commit ↔ session 接链：`.githooks/prepare-commit-msg` 读 `CLAUDE_CODE_SESSION_ID` 注入 trailer | **机制已实测，待落地** |
| L2 | audit marker 内容化：`mark-audit.sh` 从 `touch` 改为写结构化记录 | 待实现 |
| L3 | 人机分歧提取器：`tools/extract-diverge.jq` | **已完成**（755 会话实测，精确率 100%）|
| L4 | 可视化 / trace 导出 | 暂缓，见 Q4 |

落盘格式见 [spec/trace-v1.md](spec/trace-v1.md)。

L1、L2 解决断链一与断链二，改动小。L3 是业内空白，已自建。
行级归属曾考虑交给 git-ai，**已否决**，见 §2.5。

## 4. FAQ / 决策记录

### D1 — 留痕数据落在仓内 `.claude/trace/` 并入 git

**定于** 2026-09-08。

工程留痕的核心诉求是**随代码走、team 可见、换机器不丢**，只有入 git 满足。
前提是只存摘要（见 D2），否则 406MB 撑爆仓库。

⚠️ **这里说的「仓」是被观测的那个仓，不是本项目**。本项目只出工具；
每个接入的仓在自己的 `.claude/trace/` 下留自己的痕。工具与数据同仓会让
「换个仓用」变成复制粘贴。

否掉的选项与理由：

| 选项 | 否掉理由 |
|---|---|
| 本地 SQLite 库 | 聚合查询方便，但不随仓走，换机器 / 清理即丢，team 看不到 |
| 独立 sidecar git 仓 | 不污染主仓，但要自己记得同步；且 commit ↔ trace 的对应只能靠时间戳，而非同仓提交保证 |
| 上报 OTel / 外部服务 | 发到任何外部服务等于发布；开发 transcript 的 stdout 可能含 API key、内部路径。需单独确认，不作默认 |

### D2 — 只存索引与摘要，正文留在本地 transcript

**定于** 2026-09-08。

存 commit ↔ session ↔ turn uuid 映射、audit 记录、人机分歧点索引（时间戳 + uuid 指针）。
正文留在 `~/.claude/projects/`，深挖时按 uuid 跳回。约 KB 级/session，无敏感内容外泄风险。

两条支撑：
- **体量**：单 session 106MB、项目 406MB，全量入 git 不可行。
- **隐私**：transcript 的 stdout 可能含密钥与内部路径，入 git 即扩散。

**这不是我们独创**：git-ai 的 spec v3.0.0 中 session record 存的是 `messages_url`
——同样是只存指针不存正文。同一判断已被 spec 化，可作旁证。

### D3 — 存量 637 个 0 字节 marker：不迁移

**定于** 2026-09-08。存量原地保留作历史布尔证据，新审计写新格式，两者不做转换。

**先量了「能恢复多少内容」再决定**，因为迁移只有在能恢复出 finding 内容时才有意义。
294 个 audit marker 的可恢复性：

294 个 `*.audit.done` 按 mtime 与 session 时间区间做**互斥划分**：

| 匹配情况 | 数量 | 可用性 |
|---|---|---|
| mtime 唯一落入某 session 区间 | 123（42%） | **弱，旁证未验证** |
| 落入 2-5 个 session，无法区分 | 48（16%） | 不可用 |
| 不落入任何 session | 123（42%） | 无 |
| 合计 | **294** | |

另有一次**横切的强证据测量**（与上表不互斥，是其中一部分）：transcript 里
`mark-audit.sh` 调用带显式 sha 的仅 **18 处**，去重后能反查出 **10 个 (session, sha) 对**
——即 294 个 marker 里只有约 3% 有直接证据可归属。

根因在脚本自身：`mark-audit.sh` 出现 **619 处**（分布在 **405 条** Bash 命令里，
一条命令可含多处），其中带显式 sha 的只有 18 处——脚本默认取 HEAD，
绝大多数调用的命令原文里根本没有 sha 可抽。

> **口径说明**：`.claude/audit/` 下共 **637** 个文件 = 294 `*.audit.done` +
> 292 `*.crossverify.done` + 51 `*.commentaudit.done`。§1 说的 637 与本节说的 294
> 是不同口径，都对。
>
> ⚠️ **语料是活的**：上述数字为 2026-09-09 重测值。同一批量在 09-08 测得 402 / 277 / 90。
> **差异全部来自语料增长**——那两条新增的 `permission_denied` 就是 09-08 测量之后
> 本人在会话里拒绝的两次工具调用（时间戳可查）。
> **引用这些数字时必须带测量日期。**

> ⚠️ **本节三组数字待在 agentDock 上重数**（2026-09-08 审计时发现；原始统计未留档，
> 此处只标不改）：
> - 570 + 18 = 588 > 402：「调用次数」与「带 / 不带 sha 的处数」口径不同，或有一处抄错；
> - 上表四行合计 304 ≠ 294、百分比合计 103%：行与行不互斥（10 条强证据大概率同时落在
>   mtime 匹配行里），或有一处抄错；
> - marker 总数本文 §1 与 D3 标题写 637、上表与 spec §4.1 写 294，二者关系未记
>   （目录下全部文件 vs `*.audit.done`？）。
>
> 结论（不迁移）不依赖这些数字的精确值：3% 量级的强证据怎么算都不够支撑迁移。

**三个选项的实际代价**：

- **(b) 迁成「SHA + 时间」= 零信息增量。** 文件名本身就是 SHA，mtime 本身就是时间。
  转成 JSON 只是换个壳，多一份代码。
- **(c) 附带 session 指针 = 只有 3% 是实证**，42% 靠时间猜。**猜错的指针比没有指针更坏**
  ——它把将来复盘的人送到错的对话里，而对方会信。
- **(a) 不迁移 = 代价为零**（不是「低」，是零）。`check-audit-stop.sh` 只查
  `git log -1`，**永远只读最新那一个 commit**；切换后它读到的必然是新格式，
  637 个存量 marker 再也不会被读到，不构成兼容面。

**永久损失，写明**：切换之前的所有审计**没有 finding 内容，且不可恢复**——那些结论
当时只存在于对话里，从未落盘。「命中率 33-43%」这类历史数字无法重算，只能作为
CLAUDE.md 里的人工记述保留。这正是断链二要解决的问题本身，**新格式只能从今天起生效**。

⚠️ **切换时的一次性摩擦**：`mark-audit.sh` 与三个 Stop hook 脚本必须**同时改**。
改完后第一个 commit 若在改之前已标过旧 marker，新 hook 找不到会拦一次——重标一次即可。

### Q3 — 为什么不直接用 SpecStory 覆盖 D1 + D2？

它形态正确（写 `.specstory/history/` 入仓、local-first、`sync` 脱离 wrapper 可用于 desktop），
但**粒度不匹配 D2**：D2 要的是「索引 + 指针」，SpecStory 给的是「对话正文的 markdown 副本」
——既比索引重（184K/session），又比原始 transcript 轻（丢了 Edit 的 diff 与 `userModified`）。
**两头不着**：留痕想追的文件级证据它没有，不想入仓的正文它有。

未定：是否作为「人类可读副本」与索引并存。见 O2。

### Q4 — 为什么不用 Claude Code 自带的 OTel？

已具备（本机 2.1.202），但 **prompt 内容默认脱敏、只记长度**，给的是形状（token / 耗时 /
工具序列 / permission decisions）不是叙事。复盘要回答「为什么走错」，形状层答不了。
可以顺手开着当指标层，不作留痕主干。

### Q5 — git-ai 采纳与否？

**已否决**（2026-09-08，实装后）。完整实测数据与理由见 §2.5。

一句话：我们只需要它的 commit ↔ session 关联，而那件事不到十行的 hook 就能做；
它带来的 833MB 常驻本地库（含完整 prompt 正文、按待上传形状排队）对
「推广给全体开发者」这个前提不成立。

保留的判断（若将来场景变化可复用）：机制上它与 desktop 完全兼容，notes 跨 worktree 共享、
能活过全部历史重写操作，`uninstall-hooks` 可逆且实测卸载干净。技术上没问题，是代价问题。

⚠️ 评估同类工具的教训：**它的本地库不是 `install.sh` 建的，是「跑一次二进制」就建的**。
只读安装脚本会低估成本，必须实际跑一次再量占盘与进程。

### Q6 — 为什么不强制开发者在 CLI 与 desktop 间二选一？

不需要强制。§2.1 已证明前两类机制在两种形态下都工作——只要不选进程包装型
（`specstory run claude`），开发者用哪个都留同样的痕。这是选型的硬约束。

## 5. 未决项

**见 [OPEN-ISSUES.md §C 中心表](OPEN-ISSUES.md)**（唯一清单）。

本节原有的 O1–O7 已全部并入：O1 git-ai 采纳（否决，见 §2.5 / Q5）· O3 trace schema
（已定，见 [spec](spec/trace-v1.md)）· O5 telemetry 配置（随 O1 消失）· O6 存量 marker
迁移（不迁移，见 D3）· O7 `core.hooksPath`（并入中心表 G3）· O2 与 O4 合为 D2。
