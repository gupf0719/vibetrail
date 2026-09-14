# vibetrail 实际输出样例：同一段示例会话过一遍 vibetrail

> 只放实跑输出与字段说明。格式的定义与理由以 [trace-v1.md](trace-v1.md) 为准；Pilot 对同一段会话的输出见
> [third-party/loongsuite-pilot-collection-output.md](../third-party/loongsuite-pilot-collection-output.md)。
>
> - **输入**：与 Pilot 那份相同的示例会话（[experiments/collect-demo/scenario.json](../experiments/collect-demo/scenario.json)，会话 id
>   `11111111-2222-4333-8444-555555555555`）：给 `calc.py` 的 `div` 加零检查、跑测试；要把 `add` 改成减法时人拒了那次调用，并打断；
>   然后说「别改 add，那是故意留的」。
> - **演示仓**按这段剧情提交三个 commit：人工初始化 → 会话自己提交零检查 → 人工改 README。
> - **怎么跑的**：2026-09-14 在 C02FM 上，本仓 `tools/` 下的工具原样跑——`prepare-commit-msg` 拷进演示仓的 `.git/hooks/`，
>   agent 提交时环境里带 `CLAUDE_CODE_SESSION_ID`；之后跑 `vibetrail-sync`、`vibetrail-audit record` 与查询端。HOME 指向假目录。
> - **动过什么**：演示仓与假 HOME 实际在临时目录，文中写成示例会话原本的 `/tmp/demo-proj` 与 `~`；JSON 做了缩进。
>   审计的 findings 是编的——`vibetrail-audit` 只负责落盘，findings 由审计 agent 给。

## 0. 一条链怎么连起来

```
commit 35f35dc ──trailer Claude-Session──▶ 会话 11111111… ──▶ 原始 transcript（只在本机）
   │                                          └──▶ .claude/trace/sessions/<会话id>.jsonl（入仓：会话头、人机分歧、收尾）
   ├──git 自带──▶ 改了哪些文件：M calc.py（相对路径，我们不另存）
   └──trailer Vibetrail-Id──▶ .claude/trace/audits/<Vibetrail-Id>.jsonl（入仓：审计记录）
```

会话 → 文件不单独记：会话 → commit 靠 trailer，commit → 文件是 git 自己的 diff。所以一个会话改过哪些文件，
只算它**提交进去的**；改了没提交的、别的会话提交的，不在这条链上（见 [TODO.md](../TODO.md) G11）。

## 1. commit 上的 trailer（`prepare-commit-msg` 写）

```
$ git log --format='=== %h %s%n%B'
=== 005a03a readme: 说明 add 故意保持加法
readme: 说明 add 故意保持加法

Vibetrail-Id: c70b8dcf-7f69-4f43-8c68-397283c1ac3b

=== 35f35dc div: 除数为 0 时抛错
div: 除数为 0 时抛错

Vibetrail-Id: 0c0d0b3f-af3d-4ca0-850d-ba31b254ec39
Claude-Session: 11111111-2222-4333-8444-555555555555

=== f64ce68 init: calc 与 README
init: calc 与 README

Vibetrail-Id: 4568b5d4-0ddf-4c7c-9852-facdf596e3d0
```

| trailer | 什么时候有 | 含义 |
|---|---|---|
| `Claude-Session` | 只有 agent 提交：环境里有 `CLAUDE_CODE_SESSION_ID` | **哪个会话执行了这次 `git commit`**，不是「改动出自哪个会话」 |
| `Vibetrail-Id` | 每个 commit，人工提交也有 | 审计记录的锚；在 message 里，rebase / cherry-pick / amend 下原样保留 |

## 2. commit 改了哪些文件（git 自带）

```
$ git show --name-status 35f35dc
35f35dc div: 除数为 0 时抛错

M	calc.py
```

## 3. 会话流水：`.claude/trace/sessions/11111111-2222-4333-8444-555555555555.jsonl`（`vibetrail-sync` 投影）

4 条，首行是会话头，其后是人机分歧，末行收尾。原样：

**#1** `session`

```json
{
  "t": "session",
  "version": "1",
  "id": "11111111-2222-4333-8444-555555555555",
  "timestamp": "2026-09-11T03:00:07.000Z",
  "tool": {
    "name": "claude-code",
    "version": "2.1.260"
  },
  "vcs": {
    "type": "git",
    "revision": null
  },
  "entrypoint": "cli",
  "cwd": "/tmp/demo-proj",
  "branch": "main"
}
```

**#2** `diverge` · `permission_denied`

```json
{
  "t": "diverge",
  "kind": "permission_denied",
  "human": true,
  "at": "2026-09-11T03:01:10.000Z",
  "turn": "2f9a7107-8fb0-45a1-8d1d-d2bcf750e750",
  "sid": "11111111-2222-4333-8444-555555555555",
  "branch": "main"
}
```

**#3** `diverge` · `interrupt_for_tool_use`

```json
{
  "t": "diverge",
  "kind": "interrupt_for_tool_use",
  "human": true,
  "at": "2026-09-11T03:01:17.000Z",
  "turn": "fa0a4e0e-ee2e-4c69-9d33-f7261ea9b419",
  "sid": "11111111-2222-4333-8444-555555555555",
  "branch": "main"
}
```

**#4** `end`

```json
{
  "t": "end",
  "at": "2026-09-11T03:01:31.000Z",
  "turns": {
    "user": 7,
    "assistant": 6
  },
  "models": [
    "claude-opus-5"
  ],
  "subagents": [],
  "transcript": {
    "bytes": 12465
  }
}
```

| 记录 | 字段 | 含义 |
|---|---|---|
| `session` 会话头 | `id` | 会话 id，也是文件名 |
| | `timestamp` | 会话第一条消息的时间（取事件时间，投影可重算、逐字节一致） |
| | `tool` / `entrypoint` | Claude Code 版本；从 CLI、desktop 还是别处起的 |
| | `cwd` / `branch` | 会话启动时的目录与分支；`vcs.revision` 会话头不填 |
| `diverge` 人机分歧 | `kind` | `interrupt`、`interrupt_for_tool_use`、`permission_denied`、`classifier_blocked`、`permission_infra_fail` |
| | `human` | `true` 是人的决定，`false` 是机器或链路行为，统计人机分歧时只算 `true` |
| | `at` / `turn` | 发生时间；`turn` 是 transcript 里那条消息的 `uuid`——指针，不是内容 |
| | `sid` / `branch` | 所属会话；当时的分支 |
| `end` 收尾 | `turns` | 人和 agent 各多少条消息 |
| | `models` / `subagents` | 用过的模型；子 agent 的 id、类型、描述 |
| | `transcript.bytes` | 原始 transcript 的大小 |

## 4. 审计记录：`.claude/trace/audits/0c0d0b3f-af3d-4ca0-850d-ba31b254ec39.jsonl`（`vibetrail-audit record` 写）

文件名就是被审 commit 的 `Vibetrail-Id`。原样：

```json
{
  "t": "audit",
  "version": "1",
  "id": "892a0175-b484-4deb-96eb-f3831bf85e58",
  "timestamp": "2026-09-14T03:27:14Z",
  "tool": {
    "name": "vibetrail",
    "version": "1"
  },
  "vcs": {
    "type": "git",
    "revision": "35f35dcdef1ef0463f7f04026c447b9072ebac54"
  },
  "anchor": "0c0d0b3f-af3d-4ca0-850d-ba31b254ec39",
  "kind": "audit",
  "sessionId": "11111111-2222-4333-8444-555555555555",
  "subject": "div: 除数为 0 时抛错",
  "agents": [
    {
      "type": "general-purpose",
      "perspective": "正确性",
      "findings": 2
    }
  ],
  "findings": [
    {
      "id": "F1",
      "severity": "LOW",
      "claim": "新加的零检查没有对应的测试用例",
      "verdict": "confirmed",
      "evidence": "tests 里没有 b=0 的用例",
      "location": {
        "uri": "calc.py",
        "line": 6
      },
      "fix": "补一条 b=0 的 pytest"
    },
    {
      "id": "F2",
      "severity": "MED",
      "claim": "b 为 0.0 时零检查不生效",
      "verdict": "false-positive",
      "why": "Python 里 0.0 == 0 为真，实测会抛 ZeroDivisionError"
    }
  ]
}
```

| 字段 | 含义 |
|---|---|
| `anchor` | 被审 commit 的 `Vibetrail-Id`，与文件名相同 |
| `vcs.revision` / `subject` | 审计当时的 commit sha 与标题（sha 在 rebase 后会变，锚不会） |
| `sessionId` | 跑审计的会话 |
| `agents` | 参与审计的 agent：视角与各自报了几条 |
| `findings[]` | 每条：`severity`、`claim`、`verdict`（`confirmed` / `false-positive`）、`evidence` 或 `why`、`location`、`fix`——审计 agent 给，工具原样存 |
| `id` / `timestamp` / `tool` / `version` | 记录信封，字段名取自 Agent Trace |

## 5. 查询端（原样输出）

### `vibetrail log 5`：最近几个 commit 各归哪个会话

```
  commit    subject                                session
  005a03a   readme: 说明 add 故意保持加法          
  35f35dc   div: 除数为 0 时抛错                   11111111
  f64ce68   init: calc 与 README                   
```

### `vibetrail show 35f35dc`：agent 提交的 commit 是怎么来的

```
── commit ────────────────────────────────────
  35f35dc  div: 除数为 0 时抛错
  dev  2026-09-11

── 产出它的会话 ──────────────────────────────
  session: 11111111-2222-4333-8444-555555555555
  transcript: ~/.claude/projects/demo/11111111-2222-4333-8444-555555555555.jsonl ( 16K)

── 该会话的人机分歧 ──────────────────────────
  2026-09-11T03:01:10  人  permission_denied
  2026-09-11T03:01:17  人  interrupt_for_tool_use

── 同会话产出的其他 commit ───────────────────

── 审计记录 ──────────────────────────────────
  audit  finding 2 条  by 11111111…
```

### `vibetrail show HEAD`：人工提交

```
── commit ────────────────────────────────────
  005a03a  readme: 说明 add 故意保持加法
  dev  2026-09-11

── 产出它的会话 ──────────────────────────────
  （无 Claude-Session trailer）
  可能是人工提交，或提交时 hook 未安装 —— 跑 vibetrail-doctor 确认

── 审计记录 ──────────────────────────────────
  无（锚 c70b8dcf-7f6…）
```

### `vibetrail session 11111111-…`：这个会话做了什么

```
── 会话 11111111-2222-4333-8444-555555555555 ──
  transcript: ~/.claude/projects/demo/11111111-2222-4333-8444-555555555555.jsonl

  产出的 commit:
    35f35dc  2026-09-11  div: 除数为 0 时抛错

  人机分歧:
    2026-09-11T03:01:10  人  permission_denied
    2026-09-11T03:01:17  人  interrupt_for_tool_use
```

### `vibetrail diverge 5`：最近几个 commit 涉及会话的分歧汇总

```
  最近 5 个 commit 涉及的会话，其人机分歧汇总：
      1 permission_denied
      1 interrupt_for_tool_use
```

### `vibetrail-audit show 35f35dc` 与 `vibetrail-audit stats`

```
── audit  2026-09-14T03:27:14Z  by 11111111…
   agents: 正确性(2)
   [LOW] confirmed  新加的零检查没有对应的测试用例
   [MED] false-positive  b 为 0.0 时零检查不生效
{
  "审计次数": 1,
  "覆盖 commit 数": 1,
  "finding 总数": 2,
  "按判定": {
    "confirmed": 1,
    "false-positive": 1
  },
  "按严重度": {
    "LOW": 1,
    "MED": 1
  },
  "命中率": "50%"
}
```

## 6. 实跑顺带发现的问题

1. **`vibetrail show` 找不到审计记录（已修，2026-09-14）。**它曾按 patch-id 拼文件名去找 `audits/<patch-id>.jsonl`，
   而 `vibetrail-audit` 按 `Vibetrail-Id` 写盘，于是永远显示「无」；此前没有任何测试调过 `vibetrail show`。
   现在按 `Vibetrail-Id` 找（第 5 节是修好后的输出），`test-audit.sh` 加了 3 条断言钉住，旧代码下这 3 条全红。
2. **trace-v1 §3 的示例是旧字段。**会话头示例写 `v`、`"tool":"claude-code"`、`toolVersion`、`startedAt`，实际写的是信封的
   `version`、`tool{name,version}`、`timestamp`；示例说 `sid` 落盘后可省略，实际留着。
3. **收尾记录没有用量。**trace-v1 §3 的 `end` 示例带 `usage` 与 `turns.tool`，`vibetrail-sync` 都不产出——示例 transcript 里
   每条回复都带 `usage`，它没读。
4. **仓里现存的那条审计记录是旧格式。**`.claude/trace/audits/a49ea15a….jsonl`（2026-09-09）按 patch-id 命名、字段是
   `v` / `patchId` / `at` / `shaAtTime`，早于锚改成 `Vibetrail-Id`；按现在的锚两个工具都找不到它。
