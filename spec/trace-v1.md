# vibetrail trace 格式 v1：审计记录

> **2026-09-14 起本文只管审计记录这一条线**（`<repo>/.claude/trace/audits/`，`vibetrail-audit` 写、agentDock 的 Stop 闸门读）。
> 原 §2「commit ↔ session 的 `Claude-Session` trailer」与 §3「`sessions/` 会话流水」已随 G7 退役（[DESIGN.md D4](../DESIGN.md)）：
> commit ↔ session 改从全量副本推（DESIGN §3.5），人机分歧判据独立成 [diverge-v1.md](diverge-v1.md)。
> 审计线仍依赖 `prepare-commit-msg` 写的 `Vibetrail-Id` trailer，它是否也搬出仓、是否保留这个 git hook，见 OPEN-ISSUES U6。
> 退役段落的全文在 git 历史里（`git log -p -- spec/trace-v1.md`）。

## 1. 目录

```
<repo>/.claude/trace/
└── audits/<vibetrailId>.jsonl      # 审计记录
```

`audits/` 按 patch 分文件，两个分支各审一次同一个 patch 再合并时，两侧各追加一行**必然冲突**（实测 `CONFLICT (content)`）。
被观测仓的 `.gitattributes` 须声明 `.claude/trace/audits/*.jsonl merge=union`，声明后三行齐全、无冲突（实测）。
JSONL 而非单个 JSON 对象：追加即写，崩溃不会留下半个文件，配合 `merge=union` 并发追加可无冲突合并。

## 2. 锚：commit message 里的 `Vibetrail-Id` trailer

```
Vibetrail-Id: 8cfb718c-f3d2-4945-bf58-97e8b9acdd6b
```

由 `old/prepare-commit-msg` 在每次 `git commit` 时写入（**每个 commit 都要有**——人工提交也会被闸门要求审计），
`--if-exists doNothing` 保证幂等；rebase / cherry-pick 重放期间早退，不碰重放的 message。读取：

```bash
git log -1 --format='%(trailers:key=Vibetrail-Id,valueonly)' <sha>
```

### 2.0 为什么锚在 message 里，而不是从内容算

**「跨历史重写迁移」这件事被消掉了，而不是被解决了。** trailer 在 commit message 里，git 重放（rebase / amend / cherry-pick）时原样搬运，
锚根本不变——没有「旧锚 → 新锚」的映射需要维护。

这一版之前用的是 `git patch-id`，换掉它的理由不是它有 bug，是**它在最需要稳定的场景必然失效**：

| 场景 | patch-id | trailer |
|---|---|---|
| 无冲突 rebase | 不变 | 不变 |
| **上下文行被别人改过** | **变**（实测；`git-patch-id` 文档亦如此说）| 不变 |
| **冲突 rebase** | **必变**（冲突一定伴随上下文变化）| **不变**（实测）|
| merge commit | 需 `--cc`，而 `patch-id` 不认 combined diff 的 `@@@` 头，只把文件头三行喂进哈希 ⟹ 锚 = f(首个冲突文件路径)，两个内容毫不相干的解决算出同一个值（实测）| 一视同仁 |

「跨 rebase 稳定」是当初选 patch-id 的**全部理由**，而它恰好在冲突 rebase 下不成立。git-ai 的做法（锚在 SHA 上、靠 `post-rewrite` hook
拿旧 sha → 新 sha 映射）可行但多一层机制，且留着「重写发生时 hook 没跑」的洞（另一个 clone、CI、`filter-branch`）。

### 2.1 三个必须知道的代价

| 代价 | 说明 |
|---|---|
| **cherry-pick 共用锚** | 复制 message ⟹ 两个 commit 同一个锚，审一个等于标了另一个。Gerrit 的 Change-Id 把这当**特性**（同一个逻辑变更），审计语义上也成立。哨兵 T13 钉住 |
| **`merge --squash` 丢锚** | 原 message 缩进进 body，`%(trailers:)` 解析不到。agentDock 1760 个 commit 实测 **0 次 squash**；用 squash 合流的项目不适用本节 |
| **不能追溯** | 装 hook 之前的 commit 没有锚。闸门按 fail-closed 拦住并提示装 hook（哨兵 T14），不当作「无需审计」放行 |

### 2.2 锚有两道独立防护

1. hook 在 rebase / cherry-pick 时**早退**，不碰重放的 message；
2. `git interpret-trailers --if-exists doNothing` **幂等**，已有 id 不覆写。

两道各自都能保住锚。代价是**单独破坏任何一道，测试都不会红**——sanity-revert 时必须两道同时破坏才见得到 T7 / T13 转红（实测）。
这是「双层防护遮蔽」的实例，改这段代码时留意。

git hook 本身的四个静默坑（rebase 重放把人的 commit 记成 agent 的、非编辑器路径的 merge 把 trailer 粘进 subject、另起一段追加会把已有
trailer 挤出 trailer 区、`-m ''` 绕过空消息拒绝）与十二场景实测矩阵，见 `old/test-hook.sh` 与 git 历史里的旧 §2.0。

## 3. 记录信封：对齐 Agent Trace 的字段名，但**不声称合规**

字段名取自 [Agent Trace](https://agent-trace.dev/) RFC v0.1.0：

| 字段 | 含义 |
|---|---|
| `version` | 本格式版本 |
| `id` | 该条记录自身的 UUID |
| `timestamp` | RFC 3339 UTC。**取事件发生时间，不取「此刻」**——落盘必须确定性，否则每次都改文件、弄脏工作树，而脏工作树会让闸门跳过 |
| `tool` | `{name, version}` |
| `vcs` | `{type, revision}` |

**为什么不声称合规**：Agent Trace 的核心是**行级代码归属**，必填 `files[]` → `conversations[].ranges[]` 带 `start_line` / `end_line`。
我们不做行级归属（DESIGN §7 否掉 git-ai），**没有任何东西能填进 `files[]`**。硬造一个填不出内容的必填字段，就是本文档反复在修的那类毛病。
所以只借语义真正吻合的信封字段，不写 conformant。

审计记录的正文形态（`findings[]` 带 `claim` / `severity` / 可选 SARIF 形状的 `location`，`agents[]` 带 `perspective`，判定与命中率由
`vibetrail-audit stats` 现算）见 [CAPABILITIES.md](../CAPABILITIES.md) §1 审计线。severity 到 SARIF `level` 的映射：HIGH→error / MED→warning / LOW→note。

## 4. 稳定面

以下属于公开约定，**变更需要升 `v`**：

- 目录布局：`audits/<vibetrailId>.jsonl`
- 每行一个 JSON 对象，`t` 为类型判别字段；已定义的 `t` 取值：`audit`
- 审计锚取自 commit message 的 `Vibetrail-Id` trailer

以下**不属于**稳定面，可随时增补而不升版本：任何记录里的新增可选字段（消费方必须忽略不认识的字段）、`findings[].severity` 的取值集合。

## 5. 版本

`v` 出现在**每个文件的首条记录**上，是**文件级**版本，后续行不重复携带。整数，只在**破坏性变更**时递增（删字段、改字段语义、改目录布局）。
消费方读到更高的 `v` 应当拒绝解析而不是猜。字段名一旦发布就**不再改拼写**。

## 6. 已知不解决

- **没有锚的 commit 无法记录审计**：装 hook 之前的 commit、以及 message 被手改删掉 trailer 的 commit。闸门按 fail-closed 拦住并提示装 hook，不放行。
- **squash 合流**下锚丢失（§2.1）。agentDock 的工作流是 rebase + ff-only，暂不受影响。
- **同一 patch 出现在多个分支**（cherry-pick）时共用一条审计记录。这多半是对的（同一改动同一审计），但没有实测。
- **审计记录仍落在被观测仓里、仍靠 git hook 写锚**，与 G7「被观测仓零写入」不一致。是否也搬出仓、换锚，暂不定（OPEN-ISSUES U6）。
