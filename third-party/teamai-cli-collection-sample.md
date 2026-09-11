# teamai-cli 采集样例（实跑）：同一段示例会话，它记下了什么

> **入库说明**（2026-09-11）：输入是两家共用的示例会话 [experiments/collect-demo/scenario.json](../experiments/collect-demo/scenario.json)，内容全是编的，不含真实会话。实跑在第六轮审计所在的机器 C02FM 上做，回放脚本与产物写死了那台机器的临时路径，留在那里没有入库。

> **生成方式**：实跑，全程断网。
> - **依赖**：用 `git archive 224c0c4` 把仓导出到 `teamai-run/src/`，在这份副本里跑 `npm ci --ignore-scripts --no-audit --no-fund`，HOME 和 npm 缓存都用单独的目录。
>   lockfile 里有 442/479 条 `resolved` 指向 `mirrors.tencent.com/npm/`。为了满足「只连 npm 默认 registry」，只在副本里把这个前缀换成 `https://registry.npmjs.org/`，sha512 integrity 一条没动，npm 仍逐包校验。
>   结果：**下载 397 个包**。http 日志里是 397 条 `GET 200`，全部来自 registry.npmjs.org，其中生产依赖 69 个、开发依赖 328 个。**node_modules 共 317 MB**：开发依赖 `opencode-ai` 的平台二进制 `opencode-darwin-arm64` 一个就占 144 MB，69 个生产依赖合计约 73 MB。npm 缓存 79 MB，用时 1 分 42 秒。另有 3 个 EBADENGINE 警告（node 21 不在 minimatch 等包的 engines 范围里），不影响运行。
> - **构建**：`npm run build`，即 tsup 8.5.1，套着断网沙箱跑。0.8 秒产出 `dist/index.js`（1.48 MB）。
> - **断网**：凡是执行 teamai 代码的命令，一律套 `sandbox-exec -p '(version 1)(allow default)(deny network*)'`，并用 `env -i` 清空环境后只给这几样：HOME、XDG_*、TMPDIR（都指到 scratch），PATH、LANG、USER、SHELL，以及 Claude Code 会给 hook 的 `CLAUDECODE=1`、`CLAUDE_CODE_ENTRYPOINT=cli`、`CLAUDE_PROJECT_DIR`。
>   事先在本机起了一个 socket 验证沙箱：沙箱里 connect 报 EPERM，DNS 报 ENOTFOUND。
> - **回放**：脚本是 `teamai-run/replay.py`。
>   - append 步：往 transcript 追加一行紧凑 JSON。遇到 Edit 的 tool_result，先把改动真的写进 calc.py，模拟 Claude Code。
>   - hook 步：按 settings.json 的 matcher 挑出要跑的命令，用 `/bin/sh -c '<settings 里的原命令>'` 执行，payload 从 stdin 喂进去。
>   - 命令里的 `teamai` 由 `teamai-run/bin/teamai` 提供。它等价于 npm 全局安装的 bin，只多做一件事：把 stderr 追加到日志文件。
>   - 每个 hook 跑完，都等它 detach 出去的后台子进程退出，再走下一步。
> - **路径**：scenario 里的 `/tmp/demo-home`、`/tmp/demo-proj` 换成 `teamai-run/state-*/home`、`…/demo-proj`，都是 `/private/tmp/…` 形式的实路径。
>   **下文把 实跑目录（那台机器临时目录下的 `collect-demo/teamai-run`）统一写成 `$RUN`。这是对实跑产物唯一的改写。** HTTP 那一节另外给本机 hostname 和 agent id 打了码，届时会注明。
>
> **源码版本**：teamai-cli `224c0c4`（0.22.0），仓在 `~/program/go/src/teamai-cli`，原仓未改。下文所有 `文件:行` 都指这个版本。
>
> **两种状态的配置**：
> - **(a) 从没 init 过**：假 HOME 里只有 `.gitconfig`（user.name=demo-user）和空的 `~/.claude/projects/`，没有 `~/.teamai`，也没有 settings.json。
>   hook 命令按 `builtin-hooks.ts:188-192` 的格式拼出来。它和 (b) 里 init 写进 settings.json 的命令逐字节相同，脚本比对过。
>   现实里对应这种情形：hook 已经在 `~/.claude/settings.json` 里（例如在别的项目做过 project scope 的 init，见 §2.6），但当前目录和 HOME 都找不到 teamai 配置。
> - **(b) 做过默认的 init**：在 demo 项目里跑 `teamai init <团队仓 URL>`。其余全用默认：project scope、git 团队仓，不带 `--http/--self/--agent/--role`；问要不要配 reviewers 时回车，即「否」。
>   - README 的默认写法是 GitHub URL，它在本机断网下走不完，本机也没装 gh（原文见 §3.1）：
>     - 不给 token：停在 `GitHub authentication unavailable`。
>     - 给个假 `GITHUB_TOKEN`：先静默请求 `api.github.com/user`，失败后停在 `gh CLI is not installed`。
>     - 两次都只留下 `~/.teamai/debug.log`。
>   - 所以 (b) 改用**通用 Git URL** `https://git.example.com/demo/team-repo.git`，并在假 HOME 的 `~/.gitconfig` 里加一条 `url."file://$RUN/state-b/remote/".insteadOf = https://git.example.com/demo/`，让 git 自己把请求改道到本地一个**空的 bare 仓**。
>     teamai 看到的、写进配置的都是那个 https 地址，clone 和 push 实际走 file://，不联网。init 完整跑通，下文的「推到团队仓」就是这个 bare 仓里真实收到的 commit。
> - 另有一个**非默认**的补充状态 **(c) HTTP 模式**：同 (a)，但设了 `TEAMAI_HTTP_ENDPOINT=https://teamai.example.com` 和一个假的 `TEAMAI_API_TOKEN`，只用来看 report 请求体（§3.4）。
>   另外还做了几项小实验：带密钥的 prompt、探针文件、未 init 目录、符号链接路径、手动 `session save`，各在用到的地方注明。
>
> **日期**：2026-09-11。产物在 `$RUN/state-{a,b,c,b0,x}/`，逐步记录在 `state-*/logs/replay-log.jsonl`。

## 1. 示例会话

**第 1 轮**：用户让 Claude 给 `calc.py` 的 `div` 加零检查再跑测试。Claude 用 Edit 改文件，用 Bash 跑 pytest，输出里夹着假密钥 `sk-demo-…`，然后回复「改好了」。
**第 2 轮**：用户说「顺便把 add 改成减法」，Claude 的 `sed` 调用被用户拒绝，transcript 里带 interrupt 记录。用户纠正「别改 add，那是故意留的」，Claude 回「好的，add 不动」，随后 SessionEnd。

回放共 25 步：13 次 transcript 追加，12 个 hook 事件。teamai 只挂了其中 8 个：SessionStart 1 个、UserPromptSubmit 3 个、PostToolUse 2 个、Stop 2 个。3 个 PreToolUse 和 SessionEnd 它没注册，Claude Code 什么也不会调。下表是每个 hook 事件在 (a)(b) 两种状态下的实测（transcript 追加和模拟 Edit 的写入不算在内）：

| 步 | hook 事件 | teamai 挂没挂 | 前台 / 后台子进程耗时（a · b） | (a) 本步写入 | (b) 本步写入 |
|---|---|---|---|---|---|
| 1 | SessionStart | `*` 那条 | 0.32s / 0.49s · 0.53s / 0.94s | +`~/.teamai/dashboard/events.jsonl`<br>+`~/.teamai/debug.log` | +`~/.teamai/dashboard/events.jsonl`<br>+`~/.teamai/dashboard/reported-interventions.json`<br>+`~/<分区>/search-index.json`<br>+`~/<分区>/team-repo/stats/demo-user.yaml`<br>~`~/.teamai/debug.log`<br>~`~/<分区>/state.json`<br>团队仓克隆 `.git/*` 更新<br>**+`demo-proj/.claude/skills/team-wiki-codebase/` 12 个文件**<br>**远端团队仓 `refs/heads/main` 前移（push）** |
| 2 | UserPromptSubmit | `*` 那条 | 0.26s / 0.02s · 0.27s / 0.02s | ~`~/.teamai/dashboard/events.jsonl`<br>~`~/.teamai/debug.log` | ~`~/.teamai/dashboard/events.jsonl`<br>~`~/.teamai/debug.log` |
| 6 | PreToolUse Edit | 不挂 | — | — | — |
| 8 | PostToolUse Edit | `*` 那条 | 0.26s / 0.25s · 0.26s / 0.25s | ~`~/.teamai/dashboard/events.jsonl`<br>~`~/.teamai/debug.log` | ~`~/.teamai/dashboard/events.jsonl`<br>~`~/.teamai/debug.log` |
| 10 | PreToolUse Bash | 不挂 | — | — | — |
| 12 | PostToolUse Bash | `*` 那条 | 0.25s / 0.25s · 0.27s / 0.25s | ~`~/.teamai/dashboard/events.jsonl`<br>~`~/.teamai/debug.log` | ~`~/.teamai/dashboard/events.jsonl`<br>~`~/.teamai/debug.log` |
| 14 | Stop | `*` 那条 | 0.33s / 5.41s · 0.33s / 5.19s | +`~/.npm/_logs/*.log`<br>+`~/.teamai/sessions/11111111-2222-4333-8444-555555555555.json`<br>~`~/.teamai/dashboard/events.jsonl`<br>~`~/.teamai/debug.log` | +`~/.npm/_logs/*.log`<br>+`~/.teamai/sessions/11111111-2222-4333-8444-555555555555.json`<br>~`~/.teamai/dashboard/events.jsonl`<br>~`~/.teamai/debug.log` |
| 15 | UserPromptSubmit | `*` 那条 | 0.27s / 0.03s · 0.26s / 0.02s | ~`~/.teamai/dashboard/events.jsonl`<br>~`~/.teamai/debug.log` | ~`~/.teamai/dashboard/events.jsonl`<br>~`~/.teamai/debug.log` |
| 18 | PreToolUse Bash | 不挂 | — | — | — |
| 21 | UserPromptSubmit | `*` 那条 | 0.26s / 0.02s · 0.25s / 0.02s | ~`~/.teamai/dashboard/events.jsonl`<br>~`~/.teamai/debug.log` | ~`~/.teamai/dashboard/events.jsonl`<br>~`~/.teamai/debug.log` |
| 24 | Stop | `*` 那条 | 0.29s / 5.37s · 0.31s / 5.36s | +`~/.npm/_logs/*.log`<br>~`~/.teamai/dashboard/events.jsonl`<br>~`~/.teamai/debug.log` | +`~/.npm/_logs/*.log`<br>~`~/.teamai/dashboard/events.jsonl`<br>~`~/.teamai/debug.log` |
| 25 | SessionEnd | 不挂 | — | — | — |

- 所有 hook 返回给 Claude Code 的 stdout 合计 **0 字节**：teamai 没往会话里注入任何内容。contribute 分数不够，也没有 recall、MR 或包提示。
- 每个 hook 执行前后都对 transcript 取了哈希。16 次 hook 执行，前后哈希全部一致（脚本判定「一致」：是），teamai 没改过 transcript。
- Stop 的后台子进程要 5 秒多，时间都花在断网时的 `npm view` 上：它等满 5 秒超时才被杀（`update.ts:29,54-76`）。联网时会快得多。

## 2. 本机落盘的文件

总表：

| 文件 | (a) | (b) | 何时写 | 性质 |
|---|---|---|---|---|
| `~/.teamai/dashboard/events.jsonl` | 有 | 有 | 每个挂了的 hook 事件追加一行 | **会话数据主流**：prompt 原文、最后一条回复、计数、token |
| `~/.teamai/debug.log` | 有 | 有 | 任何 `log.debug/error` | 会话数据（prompt 前 60 字）＋ 运行日志 |
| `~/.teamai/sessions/<sid>.json` | 有 | 有 | 第 1 次 Stop | 会话数据：首条 prompt（脱敏）、摩擦分 |
| `~/.npm/_logs/<时刻>-debug-0.log` | 有 | 有 | 每次 Stop（teamai 起的 npm 子进程写） | npm 自己的日志，含项目路径 |
| `<项目父目录>/.TEAMAI-CASE-PROBE-<pid>-<ms>` | 瞬时 | 瞬时 | 每次 hook，写完立刻删 | 大小写探针，空文件 |
| `~/.claude/settings.json` | — | 有 | init | 6 条 hook |
| `~/.teamai/bin/teamai` | — | 有 | init | 启动包装脚本 |
| `~/.teamai/projects/demo-proj-<16位hex>/…` | — | 有 | init、每次 pull | 配置、state、团队仓克隆、检索索引 |
| `~/.teamai/dashboard/reported-*.json` | — | 有 | pull 自动上报成功后 | 按会话记的上报水位 |
| `<项目>/.claude/skills/team-wiki-codebase/` | — | **有** | SessionStart 的后台 pull | teamai 内置 skill，**写进了业务项目** |
| `~/.teamai/session-logs/2026-09.md` | — | 手动才有 | `teamai session save` | 会话摘要 |

同一段会话在 (a)(b)(c) 三种状态下写出的 events.jsonl 八行和 `sessions/<sid>.json`，去掉 timestamp、monitorPid 和路径前缀后，**逐字段相同**（脚本比对为 True）。
也就是说，「采什么」与有没有 init 无关，init 只决定「推不推到团队仓」。

### 2.1 `~/.teamai/dashboard/events.jsonl`（a、b 相同）

- **何时写**：
  - SessionStart、UserPromptSubmit、PostToolUse 由前台的 dashboard-report 追加（`hook-handlers.ts:457,476,485`）。
  - Stop 那两行由 detach 出去的后台子进程追加（`hook-handlers.ts:472`，`hook-dispatch-cli.ts:74-107,198-206`）。
  - 写入函数是 `dashboard-collector.ts:885-900`。
- **(a) 没有任何配置也照写**：分发层取不到配置时，19 条 handler 全部放行（`hook-handlers.ts:510-518`），dashboard-report 自己也不看配置。
- 实际文件是一行一条紧凑 JSON，下面每条展开。`timestamp` 是 hook 进程执行时的 `new Date()`，不是 transcript 里的时间。
- `monitorPid` 是沿进程树跳过 sh/bash 后的第一个祖先（`pid-monitor.ts:84-103`）。这次回放里它是回放脚本的 PID，真实使用时是 Claude Code 主进程。

(a) 实跑原样：

```jsonl
{
  "type": "session_start",
  "timestamp": "2026-09-11T06:17:02.318Z",
  "sessionId": "11111111-2222-4333-8444-555555555555",
  "tool": "claude",
  "cwd": "$RUN/state-a/demo-proj",
  "monitorPid": 36360
}
{
  "type": "prompt_submit",
  "timestamp": "2026-09-11T06:17:04.141Z",
  "sessionId": "11111111-2222-4333-8444-555555555555",
  "tool": "claude",
  "cwd": "$RUN/state-a/demo-proj",
  "promptSummary": "给 calc.py 的 div 加零检查，然后跑一下测试"
}
{
  "type": "tool_use",
  "timestamp": "2026-09-11T06:17:10.510Z",
  "sessionId": "11111111-2222-4333-8444-555555555555",
  "tool": "claude",
  "cwd": "$RUN/state-a/demo-proj",
  "toolName": "Edit"
}
{
  "type": "tool_use",
  "timestamp": "2026-09-11T06:17:15.062Z",
  "sessionId": "11111111-2222-4333-8444-555555555555",
  "tool": "claude",
  "cwd": "$RUN/state-a/demo-proj",
  "toolName": "Bash"
}
{
  "type": "stop",
  "timestamp": "2026-09-11T06:17:17.835Z",
  "sessionId": "11111111-2222-4333-8444-555555555555",
  "tool": "claude",
  "cwd": "$RUN/state-a/demo-proj",
  "transcriptPath": "$RUN/state-a/home/.claude/projects/-tmp-demo-proj/11111111-2222-4333-8444-555555555555.jsonl",
  "stoppedOutput": "改好了：div 在 b 为 0 时抛 ZeroDivisionError，3 个测试都通过。",
  "tokens": {
    "input": 1050,
    "output": 230,
    "cacheRead": 4800,
    "cacheCreation": 0
  },
  "prompts": 1
}
{
  "type": "prompt_submit",
  "timestamp": "2026-09-11T06:17:24.360Z",
  "sessionId": "11111111-2222-4333-8444-555555555555",
  "tool": "claude",
  "cwd": "$RUN/state-a/demo-proj",
  "promptSummary": "顺便把 add 改成减法"
}
{
  "type": "prompt_submit",
  "timestamp": "2026-09-11T06:17:30.724Z",
  "sessionId": "11111111-2222-4333-8444-555555555555",
  "tool": "claude",
  "cwd": "$RUN/state-a/demo-proj",
  "promptSummary": "别改 add，那是故意留的"
}
{
  "type": "stop",
  "timestamp": "2026-09-11T06:17:34.260Z",
  "sessionId": "11111111-2222-4333-8444-555555555555",
  "tool": "claude",
  "cwd": "$RUN/state-a/demo-proj",
  "transcriptPath": "$RUN/state-a/home/.claude/projects/-tmp-demo-proj/11111111-2222-4333-8444-555555555555.jsonl",
  "stoppedOutput": "好的，add 不动。",
  "interventions": {
    "interrupt": 1,
    "toolReject": 1,
    "toolError": 0
  },
  "tokens": {
    "input": 1150,
    "output": 322,
    "cacheRead": 7200,
    "cacheCreation": 0
  },
  "prompts": 3
}
```

对照 transcript 可以核对：
- token 按 `message.id` 去重后累加：Stop#1 是 4 条 assistant，900+50+50+50=1050 / 40+80+80+30=230 / 4×1200=4800。
- `prompts` 是有真实文本的 user 行数，打断那行和 tool_result 行不算。
- `interventions` 只出现在 Stop#2，取值为：
  - `interrupt: 1`：来自 `[Request interrupted by user for tool use]` 那行；
  - `toolReject: 1`：来自被拒 tool_result 里的 `doesn't want to proceed…`。
  - 这两个数来自**同一次**拒绝（`dashboard-collector.ts:310-324`）。
- `stoppedOutput` 是 transcript 末尾 10 KB 里最后一条 assistant 的 text，`redactWithEnv` 后截 500 字（`dashboard-collector.ts:74-121`）；`promptSummary` 是 `prompt.slice(0, 200)`，不脱敏（`:839-842`）。

**(b) 的差别**：本会话那 8 行与 (a) 相同。文件里另有补充实验留下的其他会话，同样原样列出：
- `2222…`：下一段会话的 SessionStart；
- `4444…`：从没 init 过的另一个目录；
- `5555…`：经符号链接进入项目的会话；
- `6666…`：又一次正常的 SessionStart。

```jsonl
{
  "type": "session_start",
  "timestamp": "2026-09-11T06:22:30.613Z",
  "sessionId": "22222222-3333-4444-8555-666666666666",
  "tool": "claude",
  "cwd": "$RUN/state-b/demo-proj",
  "monitorPid": 68772
}
{
  "type": "session_start",
  "timestamp": "2026-09-11T06:28:46.414Z",
  "sessionId": "44444444-5555-4666-8777-888888888888",
  "tool": "claude",
  "cwd": "$RUN/state-b/other-proj",
  "monitorPid": 3928
}
{
  "type": "prompt_submit",
  "timestamp": "2026-09-11T06:28:47.040Z",
  "sessionId": "44444444-5555-4666-8777-888888888888",
  "tool": "claude",
  "cwd": "$RUN/state-b/other-proj",
  "promptSummary": "这个目录从没 init 过，看看会不会被记下"
}
{
  "type": "session_start",
  "timestamp": "2026-09-11T06:30:56.002Z",
  "sessionId": "55555555-6666-4777-8888-999999999999",
  "tool": "claude",
  "cwd": "$RUN/state-b/link-proj",
  "monitorPid": 13016
}
{
  "type": "prompt_submit",
  "timestamp": "2026-09-11T06:30:57.131Z",
  "sessionId": "55555555-6666-4777-8888-999999999999",
  "tool": "claude",
  "cwd": "$RUN/state-b/link-proj",
  "promptSummary": "经符号链接进来的会话"
}
{
  "type": "stop",
  "timestamp": "2026-09-11T06:30:57.717Z",
  "sessionId": "55555555-6666-4777-8888-999999999999",
  "tool": "claude",
  "cwd": "$RUN/state-b/link-proj",
  "transcriptPath": "$RUN/state-b/home/.claude/projects/-link-proj/55555555-6666-4777-8888-999999999999.jsonl",
  "stoppedOutput": "收到。",
  "tokens": {
    "input": 10,
    "output": 5,
    "cacheRead": 0,
    "cacheCreation": 0
  },
  "prompts": 1
}
{
  "type": "session_start",
  "timestamp": "2026-09-11T06:31:03.091Z",
  "sessionId": "66666666-7777-4888-8999-aaaaaaaaaaaa",
  "tool": "claude",
  "cwd": "$RUN/state-b/demo-proj",
  "monitorPid": 13592
}
```

`4444…` 那两行说明：init 过以后，本机**任何目录**的 Claude Code 会话都会被记下，包括 prompt 原文。
原因有两个：hook 装在 HOME 级的 settings.json 里（§2.6），分发层又 fail-open。这些行只留本机：自动上报只收 projectRoot 下的会话（`team-push.ts:286-305`），实跑中也没被推送。

### 2.2 `~/.teamai/debug.log`

- **何时写**：所有 `log.debug` 和 `log.error` 都同步追加，与 verbose 开关无关（`utils/logger.ts:75-89,146-154`）。hook 命令把 stderr 丢进了 `/dev/null`，所以这是 hook 运行留下的唯一痕迹。
- **保留**：满 5 MB 轮转成 `.1`，没有时间上限（`utils/logger.ts:23,59-68`）。

(a) 全文，原样：

```text
2026-09-11T06:17:02.346Z [DEBUG] mr-hint: unrecognized remote URL: git@example.com:demo/demo-proj.git
2026-09-11T06:17:02.359Z [DEBUG] dashboard: recorded session_start for session 11111111-2222-43
2026-09-11T06:17:02.627Z [DEBUG] No user-scope config found, skipping user pull
2026-09-11T06:17:04.143Z [DEBUG] dashboard: recorded prompt_submit for session 11111111-2222-43 [prompt=给 calc.py 的 div 加零检查，然后跑一下测试]
2026-09-11T06:17:10.512Z [DEBUG] dashboard: recorded tool_use for session 11111111-2222-43 [tool=Edit]
2026-09-11T06:17:15.064Z [DEBUG] dashboard: recorded tool_use for session 11111111-2222-43 [tool=Bash]
2026-09-11T06:17:17.650Z [DEBUG] contribute-check: session 11111111-2222-43 friction score = 5 (interrupt=0, reject=0, correction=0, toolError=0, threshold=20)
2026-09-11T06:17:17.670Z [DEBUG] contribute-check: score below threshold, skipping hint
2026-09-11T06:17:17.845Z [DEBUG] dashboard: recorded stop for session 11111111-2222-43
2026-09-11T06:17:22.847Z [ERROR] Version check failed: Command failed: npm view teamai-cli version --registry=https://registry.npmjs.org

2026-09-11T06:17:24.362Z [DEBUG] dashboard: recorded prompt_submit for session 11111111-2222-43 [prompt=顺便把 add 改成减法]
2026-09-11T06:17:30.727Z [DEBUG] dashboard: recorded prompt_submit for session 11111111-2222-43 [prompt=别改 add，那是故意留的]
2026-09-11T06:17:34.070Z [DEBUG] contribute-check: fast-path skip (toolCount 2 < 15, debounce fresh)
2026-09-11T06:17:34.270Z [DEBUG] dashboard: recorded stop for session 11111111-2222-43
2026-09-11T06:17:39.269Z [ERROR] Version check failed: Command failed: npm view teamai-cli version --registry=https://registry.npmjs.org
```

每行的来历：
- `recorded prompt_submit … [prompt=…]`：prompt **前 60 字**，未脱敏（`dashboard-collector.ts:891-896`）。
- `mr-hint: unrecognized remote URL: …`：**业务仓 origin 的 URL 原样写入**。remote 既不是 github.com 也不是 git.woa.com 时才写（`mr-hint.ts:425-435`）。
- `Version check failed: … npm view teamai-cli version …`：Stop 后台查新版本，被沙箱拦下（`update.ts:54-76`）。
- `No user-scope config found`：(a) 下后台 pull 什么也没做。

(b) 同一时段的行。init 部分在 §2.6，pull 输出的那些 `Skipping … tool not installed` 按段折叠：

```text
2026-09-11T06:21:00.083Z [DEBUG] mr-hint: unrecognized remote URL: git@example.com:demo/demo-proj.git
2026-09-11T06:21:00.096Z [DEBUG] dashboard: recorded session_start for session 11111111-2222-43
2026-09-11T06:21:00.341Z [DEBUG] Seeded project agent root for claude: $RUN/state-b/demo-proj/.claude
2026-09-11T06:21:00.461Z [DEBUG] [project] Built multi-category search index in 1ms
……（此处省略 14 行「Skipping built-in skill deployment for <tool>: tool not installed」）
2026-09-11T06:21:00.471Z [DEBUG] [project] Deployed 1 built-in skill(s)
……（此处省略 12 行「Skipping built-in rules for <tool>: tool not installed」）
2026-09-11T06:21:00.476Z [DEBUG] teamai hooks already up-to-date in $RUN/state-b/home/.claude/settings.json
2026-09-11T06:21:00.478Z [DEBUG] teamai hooks already up-to-date in $RUN/state-b/demo-proj/.claude/settings.json
……（此处省略 5 行「Skipping MCP sync for <tool>: tool not installed」）
2026-09-11T06:21:00.832Z [DEBUG] Reported intervention delta (1 new sessions) to team repo
2026-09-11T06:21:02.362Z [DEBUG] dashboard: recorded prompt_submit for session 11111111-2222-43 [prompt=给 calc.py 的 div 加零检查，然后跑一下测试]
2026-09-11T06:21:08.824Z [DEBUG] dashboard: recorded tool_use for session 11111111-2222-43 [tool=Edit]
2026-09-11T06:21:13.459Z [DEBUG] dashboard: recorded tool_use for session 11111111-2222-43 [tool=Bash]
2026-09-11T06:21:16.075Z [DEBUG] contribute-check: session 11111111-2222-43 friction score = 5 (interrupt=0, reject=0, correction=0, toolError=0, threshold=20)
2026-09-11T06:21:16.093Z [DEBUG] contribute-check: score below threshold, skipping hint
2026-09-11T06:21:16.273Z [DEBUG] dashboard: recorded stop for session 11111111-2222-43
2026-09-11T06:21:21.270Z [ERROR] Version check failed: Command failed: npm view teamai-cli version --registry=https://registry.npmjs.org
2026-09-11T06:21:22.563Z [DEBUG] dashboard: recorded prompt_submit for session 11111111-2222-43 [prompt=顺便把 add 改成减法]
2026-09-11T06:21:29.012Z [DEBUG] dashboard: recorded prompt_submit for session 11111111-2222-43 [prompt=别改 add，那是故意留的]
2026-09-11T06:21:32.431Z [DEBUG] contribute-check: fast-path skip (toolCount 2 < 15, debounce fresh)
2026-09-11T06:21:32.630Z [DEBUG] dashboard: recorded stop for session 11111111-2222-43
2026-09-11T06:21:37.629Z [ERROR] Version check failed: Command failed: npm view teamai-cli version --registry=https://registry.npmjs.org
```

(b) 比 (a) 多出的内容都来自 SessionStart 的后台 pull：
- 项目 realpath（`Seeded project agent root …`，`project-agent-root.ts:65`）；
- 部署内置 skill（§2.7）；
- 自动上报回执（`Reported intervention delta …`，`team-push.ts:495,500`）。

补充实验时段（未 init 目录、符号链接会话）的行，供 §3.2 引用：

```text
2026-09-11T06:28:46.439Z [DEBUG] mr-hint: no git remote, skipping
2026-09-11T06:28:46.450Z [DEBUG] dashboard: recorded session_start for session 44444444-5555-46
2026-09-11T06:28:46.682Z [DEBUG] No user-scope config found, skipping user pull
2026-09-11T06:28:47.042Z [DEBUG] dashboard: recorded prompt_submit for session 44444444-5555-46 [prompt=这个目录从没 init 过，看看会不会被记下]
2026-09-11T06:30:56.025Z [DEBUG] mr-hint: unrecognized remote URL: git@example.com:demo/demo-proj.git
2026-09-11T06:30:56.038Z [DEBUG] dashboard: recorded session_start for session 55555555-6666-47
2026-09-11T06:30:56.302Z [DEBUG] Seeded project agent root for claude: $RUN/state-b/demo-proj/.claude
2026-09-11T06:30:56.432Z [DEBUG] [project] Built multi-category search index in 0ms
……（此处省略 14 行「Skipping built-in skill deployment for <tool>: tool not installed」）
2026-09-11T06:30:56.443Z [DEBUG] [project] Deployed 1 built-in skill(s)
……（此处省略 12 行「Skipping built-in rules for <tool>: tool not installed」）
2026-09-11T06:30:56.450Z [DEBUG] teamai hooks already up-to-date in $RUN/state-b/home/.claude/settings.json
2026-09-11T06:30:56.451Z [DEBUG] teamai hooks already up-to-date in $RUN/state-b/demo-proj/.claude/settings.json
……（此处省略 5 行「Skipping MCP sync for <tool>: tool not installed」）
2026-09-11T06:30:56.610Z [DEBUG] No usage events or votes to report
2026-09-11T06:30:57.133Z [DEBUG] dashboard: recorded prompt_submit for session 55555555-6666-47 [prompt=经符号链接进来的会话]
2026-09-11T06:30:57.527Z [DEBUG] contribute-check: session 55555555-6666-47 friction score = 0 (interrupt=0, reject=0, correction=0, toolError=0, threshold=20)
2026-09-11T06:30:57.546Z [DEBUG] contribute-check: score below threshold, skipping hint
2026-09-11T06:30:57.728Z [DEBUG] dashboard: recorded stop for session 55555555-6666-47
2026-09-11T06:31:02.730Z [ERROR] Version check failed: Command failed: npm view teamai-cli version --registry=https://registry.npmjs.org
2026-09-11T06:31:03.114Z [DEBUG] mr-hint: unrecognized remote URL: git@example.com:demo/demo-proj.git
2026-09-11T06:31:03.126Z [DEBUG] dashboard: recorded session_start for session 66666666-7777-48
2026-09-11T06:31:03.384Z [DEBUG] Seeded project agent root for claude: $RUN/state-b/demo-proj/.claude
……（此处省略 12 行「Skipping built-in rules for <tool>: tool not installed」；14 行「Skipping built-in skill deployment for <tool>: tool not installed」）
2026-09-11T06:31:03.513Z [DEBUG] teamai hooks already up-to-date in $RUN/state-b/home/.claude/settings.json
2026-09-11T06:31:03.515Z [DEBUG] teamai hooks already up-to-date in $RUN/state-b/demo-proj/.claude/settings.json
……（此处省略 5 行「Skipping MCP sync for <tool>: tool not installed」）
2026-09-11T06:31:03.868Z [DEBUG] Reported intervention delta (1 new sessions) to team repo
```

### 2.3 `~/.teamai/sessions/11111111-2222-4333-8444-555555555555.json`（a、b 相同）

- **何时写**：Stop#1 时前台的 contribute-check 写（`hook-handlers.ts:210-232`，`contribute-check.ts:636-659`）。(a) 没 init 也写：取不到配置时开关按「开」处理（`hook-handlers.ts:199-208`）。
- **Stop#2 没有更新它**：工具数 2 小于 15，而且距上次评估不到 5 分钟，走 fast-path 直接返回（`contribute-check.ts:553-561`，`types.ts:1057,1105`），debug.log 里有对应那行。
  所以 `friction` 停在 Stop#1 的全 0，第 2 轮的打断和拒绝都没进来。
- 24 小时后清理。

```json
{
  "contributed": false,
  "smartScore": 5,
  "toolCount": 2,
  "uniqueTools": 2,
  "lastEvaluated": 1789107437644,
  "sessionStartIso": "2026-09-11T06:17:02.318Z",
  "isKnowledgeGap": false,
  "hasGitCommit": false,
  "friction": {
    "interrupt": 0,
    "toolReject": 0,
    "correction": 0,
    "toolError": 0
  },
  "promptSummary": "给 calc.py 的 div 加零检查，然后跑一下测试"
}
```

- `promptSummary` 是首条 prompt，经 `redactWithEnv`、去控制字符、压成单行后截 160 字（`contribute-check.ts:104-117`）。
- `smartScore` 5 分全部来自工具多样性，要 ≥20 分且工具数 ≥15 才提示（`contribute-check.ts:628`）。

### 2.4 `~/.npm/_logs/<时刻>-debug-0.log`（a、b 都有，不是 teamai 自己的文件）

- **何时写**：每次 Stop，后台 update handler 用 `execFile('npm', ['view', 'teamai-cli', 'version', '--registry=…'])` 起一个 npm 子进程（`update.ts:54-76`）。npm 在 HOME 下写自己的日志。
- **内容**：命令行、项目路径（npm 会去读 `<cwd>/.npmrc`）、HOME 路径。断网时 npm 卡在取包信息这一步，5 秒后被 teamai 的 execFile 超时杀掉，所以日志停在第 31 行。
- 本会话 2 次 Stop，就是 2 个文件。下面是第 1 个，原样：

```text
0 verbose cli /opt/homebrew/Cellar/node/21.4.0/bin/node /opt/homebrew/bin/npm
1 info using npm@10.2.5
2 info using node@v21.4.0
3 timing npm:load:whichnode Completed in 1ms
4 timing config:load:defaults Completed in 1ms
5 timing config:load:file:/opt/homebrew/lib/node_modules/npm/npmrc Completed in 4ms
6 timing config:load:builtin Completed in 4ms
7 timing config:load:cli Completed in 2ms
8 timing config:load:env Completed in 0ms
9 timing config:load:file:$RUN/state-a/demo-proj/.npmrc Completed in 0ms
10 timing config:load:project Completed in 2ms
11 timing config:load:file:$RUN/state-a/home/.npmrc Completed in 0ms
12 timing config:load:user Completed in 0ms
13 timing config:load:file:/opt/homebrew/etc/npmrc Completed in 0ms
14 timing config:load:global Completed in 0ms
15 timing config:load:setEnvs Completed in 1ms
16 timing config:load Completed in 11ms
17 timing npm:load:configload Completed in 11ms
18 timing config:load:flatten Completed in 1ms
19 timing npm:load:mkdirpcache Completed in 1ms
20 timing npm:load:mkdirplogs Completed in 0ms
21 verbose title npm view teamai-cli version
22 verbose argv "view" "teamai-cli" "version" "--registry" "https://registry.npmjs.org"
23 timing npm:load:setTitle Completed in 2ms
24 timing npm:load:display Completed in 0ms
25 verbose logfile logs-max:10 dir:$RUN/state-a/home/.npm/_logs/2026-09-11T06_17_18_079Z-
26 verbose logfile $RUN/state-a/home/.npm/_logs/2026-09-11T06_17_18_079Z-debug-0.log
27 timing npm:load:logFile Completed in 6ms
28 timing npm:load:timers Completed in 0ms
29 timing npm:load:configScope Completed in 0ms
30 timing npm:load Completed in 28ms
31 silly logfile done cleaning log files
```

### 2.5 瞬时文件：`<项目父目录>/.TEAMAI-CASE-PROBE-<pid>-<毫秒>`（a、b 都有）

- **何时写**：每次 hook 都会在 `detectProjectConfig` 里算项目分区名（`hook-dispatch-cli.ts:185` → `config.ts:256-288` → `utils/partition.ts:105-112`）。
  其中 `isCaseInsensitiveFs` 会在**项目的父目录**里建一个空文件探测大小写，建完马上删（`utils/partition.ts:44-64,78-85`）。父目录不可写时静默跳过。
- **怎么证实的**：文件建完即删，事后看不到。另开一个状态 `state-x`，用沙箱规则 `(deny file-write* (regex #"TEAMAI-CASE-PROBE"))` 跑一次 UserPromptSubmit，macOS 统一日志里记下了这次被拒的写入：

```text
2026-09-11 14:27:56.269 E  kernel[0:1addc6ef] (Sandbox) Sandbox: node(98978) deny(1) file-write-create $RUN/state-x/.TEAMAI-CASE-PROBE-98978-1789108076267
```

`$RUN/state-x/` 就是 `demo-proj` 的父目录。换成真实环境，就是在用户放项目的目录（例如 `~/code/`）里反复建、删这个文件。

### 2.6 (b) 独有：init 写下的文件

init 的完整输出，原样：

```text
ℹ Initializing teamai...
ℹ Scope: project ($RUN/state-b/demo-proj)
ℹ   config    → $RUN/state-b/demo-proj/.teamai/config.yaml
ℹ   resources → $RUN/state-b/demo-proj/.claude/skills, ...
ℹ   Tip: run with `--scope user` to install under your home directory (~/)
ℹ Clone path: $RUN/state-b/home/.teamai/projects/demo-proj-eaf65786bf4082bb/team-repo
⚠ teamai.yaml not found in repo. Creating default config...
✔ Registered as team member: demo-user
✔ Member registration pushed to team repo
✔ Local config saved to $RUN/state-b/home/.teamai/projects/demo-proj-eaf65786bf4082bb/config.yaml
✔ Updated teamai hooks in $RUN/state-b/home/.claude/settings.json
✔ teamai initialized successfully!
ℹ Built-in skills (e.g. team-wiki-codebase) are ready to use in your IDE now.
ℹ Skills, rules, env and docs will auto-sync on each session start (via hooks).
ℹ Run `teamai status` to check current config.
--- stderr ---
- Checking Git identity...
✔ Using Git identity demo-user
- Cloning team repo...
✔ Team repo cloned
```

init 在项目里什么也没写，业务项目在 init 前后哈希一致。但它打印的 `config → $RUN/state-b/demo-proj/.teamai/config.yaml` 与实际不符：
这行由 `init.ts:248-261` 的 `getConfigPath()` 打印，是旧路径；配置实际写进了 HOME 下的分区（`init.ts:1011-1013,1348-1350`）。

**`~/.claude/settings.json`**：HOME 级。project scope 的 hook 也写这里（`types.ts:1497-1503`），所以本机所有目录的会话都会触发它（见 §2.1 的 `4444…`）。

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash -lc \"teamai hook-dispatch session-start --tool claude 2>/dev/null\" || true"
          }
        ],
        "description": "[teamai] Hook dispatch session-start"
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash -lc \"teamai hook-dispatch stop --tool claude 2>/dev/null\" || true"
          }
        ],
        "description": "[teamai] Hook dispatch stop"
      }
    ],
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash -lc \"teamai hook-dispatch post-tool-use --tool claude 2>/dev/null\" || true"
          }
        ],
        "description": "[teamai] Hook dispatch post-tool-use wildcard"
      },
      {
        "matcher": "Skill",
        "hooks": [
          {
            "type": "command",
            "command": "bash -lc \"teamai hook-dispatch post-tool-use --tool claude --matcher Skill 2>/dev/null\" || true"
          }
        ],
        "description": "[teamai] Hook dispatch post-tool-use Skill"
      },
      {
        "matcher": "TodoWrite",
        "hooks": [
          {
            "type": "command",
            "command": "bash -lc \"teamai hook-dispatch post-tool-use --tool claude --matcher TodoWrite 2>/dev/null\" || true"
          }
        ],
        "description": "[teamai] Hook dispatch post-tool-use TodoWrite"
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash -lc \"teamai hook-dispatch prompt-submit --tool claude 2>/dev/null\" || true"
          }
        ],
        "description": "[teamai] Hook dispatch prompt-submit"
      }
    ]
  }
}
```

**`~/.teamai/bin/teamai`**：init 为 WorkBuddy/CodeBuddy 准备的包装脚本。这两个工具本机都没装，但只要团队配置里列了它们就会写（`builtin-hooks.ts:149-174`，`hooks.ts:915-919`）。

```sh
#!/bin/sh
# Auto-generated by teamai — do not edit.
# Wrapper that invokes teamai CLI with a known Node binary so hooks
# work in environments without PATH (e.g. WorkBuddy GUI subprocess).
exec "/opt/homebrew/Cellar/node/21.4.0/bin/node" "$RUN/src/dist/index.js" "$@"
```

**`~/.teamai/projects/demo-proj-eaf65786bf4082bb/config.yaml`**：分区名是 `项目目录名-sha256(项目 realpath 规范化)前 16 位`（`utils/partition.ts:105-121`）。

```yaml
repo:
  localPath: $RUN/state-b/home/.teamai/projects/demo-proj-eaf65786bf4082bb/team-repo
  remote: https://git.example.com/demo/team-repo.git
username: demo-user
scope: project
projectRoot: $RUN/state-b/demo-proj
additionalRoles: []
projects: []
```

**同目录 `.gitignore`**：（`init.ts:1352-1375`）

```text
# teamai local config (do not commit)
config.yaml
state.json
token
teamai.lock
.update-lock
env
env.sh
sessions/
dashboard/
usage.jsonl
known-skills.json
learnings/
search-index.json
votes/
```

**同目录 `state.json`**：init 刚写完时是下面第一段，经过几次 pull 后变成第二段：

```json
{
  "lastPush": null,
  "lastPull": null,
  "lastPullRev": null,
  "pushedRules": [],
  "pushedSkills": [],
  "pushedEnvVars": [],
  "pendingPushes": [],
  "lastUpdateCheck": null,
  "availableUpdate": null
}
```

```json
{
  "lastPush": null,
  "lastPull": "2026-09-11T06:30:56.446Z",
  "lastPullRev": "e2db047",
  "lastPullTargets": [
    "claude"
  ],
  "pushedRules": [],
  "pushedSkills": [],
  "pushedEnvVars": [],
  "pendingPushes": [],
  "lastUpdateCheck": null,
  "availableUpdate": null
}
```

**团队仓克隆 `team-repo/.git/config`**：只配了 `user.name`，email 为空，于是 commit 用全局 git 配置里的邮箱（`utils/git.ts:69-89`）。`teamai.yaml`、`members/demo-user.yaml` 的内容见 §3.1 的 init commit。

```ini
[core]
	repositoryformatversion = 0
	filemode = true
	bare = false
	logallrefupdates = true
	ignorecase = true
	precomposeunicode = true
[remote "origin"]
	url = https://git.example.com/demo/team-repo.git
	fetch = +refs/heads/*:refs/remotes/origin/*
[branch "main"]
	remote = origin
	merge = refs/heads/main
[user]
	name = demo-user
```

init 时的 debug.log：

```text
2026-09-11T06:20:01.997Z [DEBUG] Detected provider: git
2026-09-11T06:20:02.133Z [DEBUG] Git user configured: demo-user (email from global git config)
2026-09-11T06:20:02.133Z [DEBUG] teamai.yaml not found in repo
2026-09-11T06:20:02.345Z [DEBUG] No roles manifest found — skipping role selection
2026-09-11T06:20:02.346Z [DEBUG] Generated .teamai/.gitignore for project scope
……（此处省略 15 行「Skipping built-in skill deployment for <tool>: tool not installed」）
```

### 2.7 (b) 独有：会话中后台 pull 写下的文件

以下文件都出自每次 SessionStart detach 出去的 `pull`（`hook-handlers.ts:84-106,456`，`pull.ts:1331-1539`）。

**`~/.teamai/dashboard/reported-interventions.json`、`reported-prompt-tokens.json`**：上报成功后的水位，只增不减（`team-push.ts:132-148,203-227,492-501`）。

- 本会话自己的 SessionStart 之后，reported-interventions.json 如下；这时 reported-prompt-tokens.json 还不存在，因为 prompts 和 tokens 的增量都是 0：

```json
{
  "11111111-2222-4333-8444-555555555555": {
    "interrupt": 0,
    "toolReject": 0,
    "correction": 0
  }
}
```

- 下一段会话（`2222…`）的 SessionStart 之后：

```json
{
  "11111111-2222-4333-8444-555555555555": {
    "interrupt": 1,
    "toolReject": 1,
    "correction": 0
  },
  "22222222-3333-4444-8555-666666666666": {
    "interrupt": 0,
    "toolReject": 0,
    "correction": 0
  }
}
```

  reported-prompt-tokens.json 在文件里是单行紧凑 JSON，这里展开：

```json
{
  "11111111-2222-4333-8444-555555555555": {
    "prompts": 3,
    "tokens": {
      "input": 1150,
      "output": 322,
      "cacheRead": 7200,
      "cacheCreation": 0
    }
  },
  "22222222-3333-4444-8555-666666666666": {
    "prompts": 0,
    "tokens": {
      "input": 0,
      "output": 0,
      "cacheRead": 0,
      "cacheCreation": 0
    }
  }
}
```

- 所有实验结束后的终态：多了 `6666…`；**没有** `4444…`（未 init 目录）和 `5555…`（符号链接路径），它们被作用域过滤掉了（§3.2）。

```json
{
  "11111111-2222-4333-8444-555555555555": {
    "interrupt": 1,
    "toolReject": 1,
    "correction": 0
  },
  "22222222-3333-4444-8555-666666666666": {
    "interrupt": 0,
    "toolReject": 0,
    "correction": 0
  },
  "66666666-7777-4888-8999-aaaaaaaaaaaa": {
    "interrupt": 0,
    "toolReject": 0,
    "correction": 0
  }
}
```

**`<分区>/search-index.json`**：团队知识检索索引。团队仓是空的，所以索引也是空的。

```json
{
  "version": 6,
  "builtAt": "2026-09-11T06:30:56.431Z",
  "elapsedMs": 0,
  "entries": [],
  "df": {}
}
```

**业务项目 `demo-proj/.claude/skills/team-wiki-codebase/`**：第一次 SessionStart 时，后台 pull 先建好 `demo-proj/.claude/`（`project-agent-root.ts:45-66`），再把 teamai 自带的 skill 部署进去。
团队仓是空的也照样部署（debug.log：`[project] Deployed 1 built-in skill(s)`）。这 12 个文件在 git 里是 untracked，业务仓的 `.gitignore` 没有忽略它们：

```text
  5435  .claude/skills/team-wiki-codebase/README.md
 38193  .claude/skills/team-wiki-codebase/SKILL.md
 12661  .claude/skills/team-wiki-codebase/references/agents/graph-rag-agent.md
 13484  .claude/skills/team-wiki-codebase/references/agents/kb-doc-generator.md
  3292  .claude/skills/team-wiki-codebase/references/methodology/phase0-collection.md
  3420  .claude/skills/team-wiki-codebase/references/methodology/phase1-reverse-engineering.md
 12605  .claude/skills/team-wiki-codebase/references/methodology/phase2-document-types.md
  5917  .claude/skills/team-wiki-codebase/references/methodology/phase3-ai-enhancement.md
  7205  .claude/skills/team-wiki-codebase/references/methodology/phase4-quality.md
  6430  .claude/skills/team-wiki-codebase/references/templates/project-overview.md
  7516  .claude/skills/team-wiki-codebase/scripts/scan_repo.py
  8781  .claude/skills/team-wiki-codebase/scripts/validate_kb.py
```

### 2.8 (b) 手动命令才写：`~/.teamai/session-logs/2026-09.md`

hook 链上不写这个文件。会话结束后手动跑 `teamai session save --session-id 1111… --push` 才写。本机这份**总是**带首条 prompt（`save-session.ts:82`），推到团队仓的那份默认不带（§3.3）。

```markdown
# Session log — 2026-09

<!-- teamai:session 11111111-2222-4333-8444-555555555555 -->
### 2026-09-11 · 11111111 · claude

- Project: `$RUN/state-b/demo-proj`
- Prompts: 3 · Tools: 2 (2 distinct)
- Interventions: interrupt 1, toolReject 1, correction 0
- Top tools: Edit×1, Bash×1
- First ask: 给 calc.py 的 div 加零检查，然后跑一下测试
```

### 2.9 有没有改 demo 项目、有没有改 transcript

- **transcript**：没改。16 次 hook 执行，前后哈希都一致，teamai 对 transcript 只读。
- **demo 项目**：
  - (a) 没改。`calc.py` 的改动是回放脚本模拟 Claude 做的 Edit。
  - (b) 由 SessionStart 的后台 pull 加了 `.claude/skills/team-wiki-codebase/`，12 个文件、148 KB，untracked。`.git/` 下没有任何变化，init 本身也没往项目里写东西。
- **项目父目录**：两种状态下，每次 hook 都在这里建、删一次探针文件（§2.5）。

## 3. 出本机的内容

| 通道 | 默认发不发 | (a) 实跑 | (b) 实跑 | 发什么 |
|---|---|---|---|---|
| git 团队仓：init 注册成员 | init 时发 | — | 推了 1 个 commit | 用户名、displayName、注册时间；团队仓是空的，所以还有 `teamai.yaml` 和 5 个 `.gitkeep`；commit 的作者、邮箱和时间 |
| git 团队仓：随 pull 自动直推 | **发**：在 init 过的项目里，每开一次会话就在 SessionStart 后台推一次 | 不发（没配置） | 推了 3 次，每次 1 个 commit，只改 `stats/demo-user.yaml` | 会话数、打断、拒绝、纠正、真人轮数、token 四桶、skill 用量；commit 的作者、邮箱和时间 |
| git 团队仓：`session save --push` | 不发，要手动 | — | 手动跑了 1 次，推 `sessions/demo-user/2026-09.md` | 完整 session_id、**cwd 绝对路径**、轮数、工具名×次数、干预数 |
| HTTP 后端 report / sync | 不发，没配 endpoint | 无请求 | 无请求 | 见 (c)：Agent 类型与版本、`local_agent_id`、**hostname 明文**、os、状态、工作区绝对路径 |
| npm registry 版本检查 | **发**：每次 Stop | 2 次，都被拦 | 2 次，都被拦 | `npm view teamai-cli version`，只带包名。发现新版且策略是默认的 auto 时，会自动 `npm install -g` |
| init 时的外连 | init 时发 | — | GitLab 探测 1 次（被拦，静默）；(b0) 用假 token 时请求 GitHub API 1 次（被拦，静默） | 探测：匿名 GET `<origin>/users/sign_in`；GitHub：`GET /user`，带 token |
| mr-hint | 业务仓 remote 是 github.com 或 git.woa.com 时，每次 SessionStart 发 | 本例 remote 认不出，不发 | 同左 | 用 `gh pr list` 或 REST 查该仓近 7 天合入的 PR（`mr-hint.ts:410-472`） |

### 3.1 init 本身

**README 默认写法（GitHub URL）在断网下停在哪**，状态 `state-b0`，原样：

不给 token：

```text
ℹ Initializing teamai...
ℹ Scope: project ($RUN/state-b0/demo-proj)
ℹ   config    → $RUN/state-b0/demo-proj/.teamai/config.yaml
ℹ   resources → $RUN/state-b0/demo-proj/.claude/skills, ...
ℹ   Tip: run with `--scope user` to install under your home directory (~/)
--- stderr ---
file://$RUN/src/dist/index.js:3898
  throw new Error(
        ^

Error: GitHub authentication unavailable.
  Option 1 (recommended): Install gh CLI — https://cli.github.com/
    macOS:   brew install gh
    Linux:   see https://github.com/cli/cli/blob/trunk/docs/install_linux.md
  Option 2: Export a personal access token — GITHUB_TOKEN=ghp_... (needs "repo" scope)
    at ensureGhAvailable (file://$RUN/src/dist/index.js:3898:9)
    at GitHubProvider.ensureInstalled (file://$RUN/src/dist/index.js:4350:15)
    at init (file://$RUN/src/dist/index.js:15281:18)
    at async Command.<anonymous> (file://$RUN/src/dist/index.js:40459:3)

Node.js v21.4.0
```

给假 `GITHUB_TOKEN`：`ghFetchLogin` 先 fetch `https://api.github.com/user`，失败后吞掉错误返回 null（`providers/github/gh-cli.ts:153-167`）；接着要走 `gh auth login`，因为没装 gh 而失败。

```text
ℹ Initializing teamai...
ℹ Scope: project ($RUN/state-b0/demo-proj)
ℹ   config    → $RUN/state-b0/demo-proj/.teamai/config.yaml
ℹ   resources → $RUN/state-b0/demo-proj/.claude/skills, ...
ℹ   Tip: run with `--scope user` to install under your home directory (~/)
--- stderr ---
- Checking authentication...
✖ Authentication failed: Cannot start interactive login: gh CLI is not installed.
Install gh from https://cli.github.com/ or export GITHUB_TOKEN.
```

两次加起来，`~/.teamai/debug.log` 的全部内容：

```text
2026-09-11T06:19:11.483Z [DEBUG] Detected provider: github
2026-09-11T06:19:29.154Z [DEBUG] Detected provider: github
2026-09-11T06:19:29.160Z [DEBUG] GITHUB_TOKEN env var detected — will use REST API directly
```

**通用 Git URL 的 init**（§2.6 有完整输出）：
- 先匿名探测该主机是不是自建 GitLab，这一步被沙箱拦下，失败是静默的（`providers/registry.ts:117-129`，`providers/gitlab/probe.ts:54-80`）；
- 然后 clone；
- 空仓时生成默认 `teamai.yaml`，写 `members/<user>.yaml`，**直推**默认分支，不走 MR（`init.ts:1210-1262`）。

bare 仓收到的第一个 commit：

```diff
commit ca1d6db36471030244d7217656e8c35448e7d742
Author: demo-user <demo-user@example.com>
Date:   2026-09-11 14:20:02 +0800

    [teamai] Register member: demo-user


diff --git a/docs/.gitkeep b/docs/.gitkeep
new file mode 100644
index 0000000..e69de29
diff --git a/env/.gitkeep b/env/.gitkeep
new file mode 100644
index 0000000..e69de29
diff --git a/members/.gitkeep b/members/.gitkeep
new file mode 100644
index 0000000..e69de29
diff --git a/members/demo-user.yaml b/members/demo-user.yaml
new file mode 100644
index 0000000..912195a
--- /dev/null
+++ b/members/demo-user.yaml
@@ -0,0 +1,3 @@
+username: demo-user
+displayName: demo-user
+registeredAt: 2026-09-11T06:20:02.138Z
diff --git a/rules/.gitkeep b/rules/.gitkeep
new file mode 100644
index 0000000..e69de29
diff --git a/skills/.gitkeep b/skills/.gitkeep
new file mode 100644
index 0000000..e69de29
diff --git a/teamai.yaml b/teamai.yaml
new file mode 100644
index 0000000..0007aa2
--- /dev/null
+++ b/teamai.yaml
@@ -0,0 +1,11 @@
+team: my-team
+description: TeamAI shared resources
+repo: https://git.example.com/demo/team-repo.git
+provider: git
+sharing:
+  rules:
+    enforced: []
+  docs:
+    localDir: ./.teamai/docs
+  env:
+    injectShellProfile: true
```

### 3.2 git 团队仓：随 pull 自动直推（默认会发）

- **触发**：SessionStart 的后台 handler 就是 `pull`。pull 的第 4 步调 `reportUsageToTeam()`（`pull.ts:1465-1515`，`team-push.ts:313-508`）。
- **做法**：reset 并 pull 团队仓克隆，写 `stats/<user>.yaml`，`git add/commit/push` 直推，限时 5 秒。
- **范围**：只收 `cwd` 以 projectRoot 开头的会话（`team-push.ts:286-305`）。

实跑中 bare 仓依次收到这两个 commit：

```diff
commit f492884ad9a43725c0e292c7348060f85efcf0da
Author: demo-user <demo-user@example.com>
Date:   2026-09-11 14:21:00 +0800

    [teamai] Update session stats for demo-user


diff --git a/stats/demo-user.yaml b/stats/demo-user.yaml
new file mode 100644
index 0000000..32ef6d4
--- /dev/null
+++ b/stats/demo-user.yaml
@@ -0,0 +1,8 @@
+username: demo-user
+updatedAt: 2026-09-11T06:21:00.632Z
+skills: {}
+interventions:
+  sessions: 1
+  interrupt: 0
+  toolReject: 0
+  correction: 0
commit a2fc23d06a4bf6c9fa4581c0b39989f115162094
Author: demo-user <demo-user@example.com>
Date:   2026-09-11 14:22:31 +0800

    [teamai] Update session stats for demo-user


diff --git a/stats/demo-user.yaml b/stats/demo-user.yaml
index 32ef6d4..6312af3 100644
--- a/stats/demo-user.yaml
+++ b/stats/demo-user.yaml
@@ -1,8 +1,14 @@
 username: demo-user
-updatedAt: 2026-09-11T06:21:00.632Z
+updatedAt: 2026-09-11T06:22:31.231Z
 skills: {}
 interventions:
-  sessions: 1
-  interrupt: 0
-  toolReject: 0
+  sessions: 2
+  interrupt: 1
+  toolReject: 1
   correction: 0
+prompts: 3
+tokens:
+  input: 1150
+  output: 322
+  cacheRead: 7200
+  cacheCreation: 0
```

逐条说明：
- **第一次推送发生在本会话自己的 SessionStart**，这时一句话都还没说。后台 pull 读 events 时，前台已经写好了本会话的 `session_start`，于是本会话被当成一个新会话，`sessions: 1`，其余全是 0。
  这是个竞态，但实跑里真实路径下的 3 次 SessionStart（`1111…`、`2222…`、`6666…`）每次都赶上了。
- **本会话的真实数字要等下一次在该项目里 pull 才出去**。这里是下一段会话 `2222…` 的 SessionStart，它自己也被顺带记成 `sessions` +1，于是变成 2。
  推出去的内容：`interrupt: 1`、`toolReject: 1`、`correction: 0`、`prompts: 3`、`tokens` 1150/322/7200/0。`toolError` 不上报。
  「别改 add」**没有**算成 correction：它前面没有 Stop，纠正词表里也没有「别改」（`dashboard-collector.ts:1162-1172`，`types.ts:969-974`）。
- **git 历史里的附带信息**：
  - 作者：`demo-user <demo-user@example.com>`，邮箱取自全局 git 配置。
  - commit 时间：就是每次开会话的时刻。
  - stats 本身是累计值，但一次 pull 一个 commit，相邻两版一减就是逐次增量。
- **只留本机、没被推的**：
  - `4444…`：从没 init 过的目录。pull 找不到配置，只写了一行 `No user-scope config found`。
  - `5555…`：经符号链接进入项目的会话，见下。

**符号链接路径的会话会被整段漏报**：
- 做法：在 `$RUN/state-b/link-proj -> demo-proj` 这个链接下，回放一段 1 轮的会话（`5555…`：SessionStart、UserPromptSubmit、Stop），hook 的 `cwd` 用链接路径；然后在真实路径下开 `6666…`。
- 结果：
  - `5555…` 自己的 SessionStart 上报时，debug.log 写的是 `No usage events or votes to report`，不推。
  - `6666…` 的 SessionStart 只把 `sessions` 从 2 加到 3，`5555…` 的 1 轮和 10/5 个 token 都**没有**上报，`reported-prompt-tokens.json` 里也没有它的键。
- 原因：projectRoot 取 realpath，过滤却用事件里原样的 cwd 做字符串前缀比较（`team-push.ts:291-294`）。
- 这次证实的是 teamai 这一侧。Claude Code 在 macOS 上报的 cwd 是 `/tmp/…` 还是 `/private/tmp/…`，本次没验证。

```diff
commit dd174ef29272d674c2501193fcde35d21f95106e
Author: demo-user <demo-user@example.com>
Date:   2026-09-11 14:31:03 +0800

    [teamai] Update session stats for demo-user


diff --git a/stats/demo-user.yaml b/stats/demo-user.yaml
index 6312af3..5ac7408 100644
--- a/stats/demo-user.yaml
+++ b/stats/demo-user.yaml
@@ -1,8 +1,8 @@
 username: demo-user
-updatedAt: 2026-09-11T06:22:31.231Z
+updatedAt: 2026-09-11T06:31:03.669Z
 skills: {}
 interventions:
-  sessions: 2
+  sessions: 3
   interrupt: 1
   toolReject: 1
   correction: 0
```

### 3.3 手动：`teamai session save --push`（默认不发）

手动跑一次后，bare 仓收到的 commit 如下。团队版没有 First ask 行，本机版有（§2.8）；但**完整 session_id 和 cwd 绝对路径都原样推出去了**（`session-collector.ts:142-165`）。

```diff
commit e2db0476704da3761c8818b17c763bcb5c5fff36
Author: demo-user <demo-user@example.com>
Date:   2026-09-11 14:28:25 +0800

    [teamai] Session summary from demo-user (2026-09)


diff --git a/sessions/demo-user/2026-09.md b/sessions/demo-user/2026-09.md
new file mode 100644
index 0000000..5987a7e
--- /dev/null
+++ b/sessions/demo-user/2026-09.md
@@ -0,0 +1,9 @@
+# Session log — 2026-09
+
+<!-- teamai:session 11111111-2222-4333-8444-555555555555 -->
+### 2026-09-11 · 11111111 · claude
+
+- Project: `$RUN/state-b/demo-proj`
+- Prompts: 3 · Tools: 2 (2 distinct)
+- Interventions: interrupt 1, toolReject 1, correction 0
+- Top tools: Edit×1, Bash×1
```

### 3.4 HTTP 企业后端：report / sync（默认不发；(c) 补充）

**默认**：(a)(b) 都没配 endpoint，`loadLocalAgentConfig()` 返回 null，handler 什么也不发（`local-agent.ts:555-634,3025-3026`）。两份 debug.log 里都没有一行 local-agent 日志。

**(c) 设了 `TEAMAI_HTTP_ENDPOINT` 之后**：本节日志里的 hostname 和 `local_agent_id` 打了码，标签里的 id 片段也一样。

- **请求次数**：8 个挂了的 hook 事件，每个都 POST 一次 `/api/local-agent/report`（`local-agent.ts:3085-3089`）。
  report 失败后，同一个 try 块里的 sync 就不再发，catch 里打出来的却是 `sync FAILED`（`:3127-3131`），所以实际 sync 次数是 0。联网时应当是每次 report 加 sync，共 16 个 POST。
- **额外的 GET**：SessionStart 时有 `GET /api/projects/mine`（工作区绑定）和 `GET /api/local-agent/get-config`（插件对账）；第一次 UserPromptSubmit 时又有一次 `/api/projects/mine`。
- **`agent_version` 的来历**：每次 report 前 teamai 都**执行一次 `claude --version`**（`agent-version.ts:43-48`）。本机 PATH 上是 `/opt/homebrew/bin/claude`，得到 2.1.12；执行时用的是假 HOME。
- **`started_at`**：用环境变量配置时，它是每次调用的当前时间，不是固定的创建时间（`local-agent.ts:628-633`）。

SessionStart 那一次的 debug.log，请求体原样记录，请求头已脱敏（`utils/http-log.ts:41-53`）：

```text
2026-09-11T06:23:35.313Z [DEBUG] mr-hint: unrecognized remote URL: git@example.com:demo/demo-proj.git
2026-09-11T06:23:35.331Z [DEBUG] dashboard: recorded session_start for session 11111111-2222-43
2026-09-11T06:23:35.403Z [DEBUG] [<id后6位>] [workbuddy] → GET https://teamai.example.com/api/projects/mine
2026-09-11T06:23:35.403Z [DEBUG] [<id后6位>] [workbuddy]   headers: {"Authorization":"Bearer ***","X-API-Token":"***"}
2026-09-11T06:23:35.441Z [DEBUG] local-agent: failed to load user projects: fetch failed
2026-09-11T06:23:35.442Z [DEBUG] [<id后6位>] [claude] run: endpoint=https://teamai.example.com
2026-09-11T06:23:35.667Z [DEBUG] No user-scope config found, skipping user pull
2026-09-11T06:23:35.677Z [DEBUG] [local-agent] [plugin-reconcile] → GET https://teamai.example.com/api/local-agent/get-config
2026-09-11T06:23:35.677Z [DEBUG] [local-agent] [plugin-reconcile]   headers: {"Authorization":"Bearer ***","X-API-Token":"***"}
2026-09-11T06:23:35.713Z [DEBUG] [local-agent] [plugin-reconcile] reconcile failed: fetch failed
2026-09-11T06:23:36.110Z [DEBUG] [agent-version] claude → "2.1.12"
2026-09-11T06:23:36.152Z [DEBUG] [<id后6位>] [claude] → POST https://teamai.example.com/api/local-agent/report
2026-09-11T06:23:36.152Z [DEBUG] [<id后6位>] [claude]   headers: {"Content-Type":"application/json","Authorization":"Bearer ***","X-API-Token":"***"}
2026-09-11T06:23:36.152Z [DEBUG] [<id后6位>] [claude]   body: {"agent_type":"claude","agent_version":"2.1.12","local_agent_id":"<local_agent_id:16位hex>","host_name":"<本机hostname>","os":"darwin","started_at":"2026-09-11T06:23:35.325Z","last_status":"running","user_level":{},"workspaces":[{"path":"$RUN/state-c/demo-proj","name":"demo-proj","ide_type":"claude"}]}
2026-09-11T06:23:36.155Z [ERROR] [<id后6位>] [claude] sync FAILED: fetch failed
```

Stop#2 那一次：

```text
2026-09-11T06:24:11.570Z [DEBUG] contribute-check: fast-path skip (toolCount 2 < 15, debounce fresh)
2026-09-11T06:24:11.766Z [DEBUG] dashboard: recorded stop for session 11111111-2222-43
2026-09-11T06:24:11.794Z [DEBUG] [<id后6位>] [claude] run: endpoint=https://teamai.example.com
2026-09-11T06:24:12.480Z [DEBUG] [agent-version] claude → "2.1.12"
2026-09-11T06:24:12.526Z [DEBUG] [<id后6位>] [claude] → POST https://teamai.example.com/api/local-agent/report
2026-09-11T06:24:12.526Z [DEBUG] [<id后6位>] [claude]   headers: {"Content-Type":"application/json","Authorization":"Bearer ***","X-API-Token":"***"}
2026-09-11T06:24:12.527Z [DEBUG] [<id后6位>] [claude]   body: {"agent_type":"claude","agent_version":"2.1.12","local_agent_id":"<local_agent_id:16位hex>","host_name":"<本机hostname>","os":"darwin","started_at":"2026-09-11T06:24:11.764Z","last_status":"stopped","user_level":{},"workspaces":[{"path":"$RUN/state-c/demo-proj","name":"demo-proj","ide_type":"claude"}]}
2026-09-11T06:24:12.552Z [ERROR] [<id后6位>] [claude] sync FAILED: fetch failed
2026-09-11T06:24:16.762Z [ERROR] Version check failed: Command failed: npm view teamai-cli version --registry=https://registry.npmjs.org
```

sync 的请求体没发出去。按源码，它只有 `agent_type`、`local_agent_id`、`status`、`workspaces[{path,name,ide_type,project_id}]`（`local-agent.ts:1609-1633`）。

**失败日志 `~/.teamai/reporter/errors.jsonl`**：本机文件，8 行，每次失败一行（`local-agent.ts:746-757`）。
每行都带完整的 `DashboardEvent`，也就是 prompt 原文、最后一条回复、transcript 路径。第一行和最后一行原样：

```json
{
  "at": "2026-09-11T06:23:36.155Z",
  "entry": {
    "error": "fetch failed",
    "context": {
      "cwd": "$RUN/state-c/demo-proj",
      "tool": "claude",
      "status": "running",
      "event": {
        "type": "session_start",
        "timestamp": "2026-09-11T06:23:35.313Z",
        "sessionId": "11111111-2222-4333-8444-555555555555",
        "tool": "claude",
        "cwd": "$RUN/state-c/demo-proj",
        "monitorPid": 74386
      }
    }
  }
}
```

```json
{
  "at": "2026-09-11T06:24:12.552Z",
  "entry": {
    "error": "fetch failed",
    "context": {
      "cwd": "$RUN/state-c/demo-proj",
      "tool": "claude",
      "status": "stopped",
      "event": {
        "type": "stop",
        "timestamp": "2026-09-11T06:24:11.755Z",
        "sessionId": "11111111-2222-4333-8444-555555555555",
        "tool": "claude",
        "cwd": "$RUN/state-c/demo-proj",
        "transcriptPath": "$RUN/state-c/home/.claude/projects/-tmp-demo-proj/11111111-2222-4333-8444-555555555555.jsonl",
        "stoppedOutput": "好的，add 不动。",
        "interventions": {
          "interrupt": 1,
          "toolReject": 1,
          "toolError": 0
        },
        "tokens": {
          "input": 1150,
          "output": 322,
          "cacheRead": 7200,
          "cacheCreation": 0
        },
        "prompts": 3
      }
    }
  }
}
```

另写了 `~/.teamai/local-agent/plugin-pull.json`：

```json
{
  "lastFailAt": 1789107815707
}
```

### 3.5 断网下的全部外连尝试（macOS 沙箱拒绝日志）

- 下表来自 `log show --predicate 'eventMessage CONTAINS "deny(1) network"'`，按每段运行的时间窗统计。
- 已剔除本机与本次无关的进程，只保留本次起的 node 进程。npm 也是 node。
- 统一日志对同一进程会合并重复报告，也看不到域名，只能看到哪个进程在什么时候试图连网。

| 时间窗 | 被拦的进程 | 对应的操作 |
|---|---|---|
| (a) 回放 | 2 个进程，各在一次 Stop 时刻 | `npm view teamai-cli version` 的 DNS 查询 |
| (b0) README 默认 init | 1 个进程 | 带假 token 时 fetch `api.github.com` |
| (b) init | 1 个进程 | GitLab 探测 fetch `git.example.com` |
| (b) 回放 | 2 个进程，各在一次 Stop 时刻 | `npm view` |
| (b) 下一会话 SessionStart、`session save --push`、未 init 目录 | **无** | 团队仓 fetch/push 被 insteadOf 改到了 file://，不经网络 |
| (b) 符号链接实验 | 1 个进程，Stop 时刻 | `npm view` |
| (c) HTTP 回放 | 6 个进程 | 各次 report/GET 与 `npm view` |

对照 `debug.log`：
- (a)(b) 的会话期间，teamai 自己发起的外连**只有每次 Stop 的 npm 版本检查**。
- 团队仓的 fetch 和 push 在真实环境里当然走网络，这次因为改道而没有出现在上表。

## 4. 一眼看完：采了什么、没采什么

先看证据。下表把 teamai 在 (a)(b)(c) 下写出的全部文件逐个 grep 了一遍，包括 (b) 远端 bare 仓里每个 commit 的每个文件。回放脚本自己写的 transcript 不算：

| 标记串 | (a) 命中的文件 | (b) 命中的文件（含远端 bare 仓） | (c) 命中的文件 |
|---|---|---|---|
| prompt 正文（3 条） | `~/.teamai/dashboard/events.jsonl`<br>`~/.teamai/debug.log`<br>`~/.teamai/sessions/11111111-2222-4333-8444-555555555555.json` | `~/.teamai/dashboard/events.jsonl`<br>`~/.teamai/debug.log`<br>`~/.teamai/session-logs/2026-09.md`<br>`~/.teamai/sessions/11111111-2222-4333-8444-555555555555.json` | `~/.teamai/dashboard/events.jsonl`<br>`~/.teamai/debug.log`<br>`~/.teamai/reporter/errors.jsonl`<br>`~/.teamai/sessions/11111111-2222-4333-8444-555555555555.json` |
| 模型回复正文（2 条） | `~/.teamai/dashboard/events.jsonl` | `~/.teamai/dashboard/events.jsonl` | `~/.teamai/dashboard/events.jsonl`<br>`~/.teamai/reporter/errors.jsonl` |
| thinking | 无 | 无 | 无 |
| Edit new_string | 无 | 无 | 无 |
| Edit old_string / 改前整份文件 | 无 | 无 | 无 |
| Bash 命令（pytest / 被拒的 sed） | 无 | 无 | 无 |
| 工具输出 | 无 | 无 | 无 |
| 假密钥 sk-demo | 无 | 无 | 无 |
| interrupt / 拒绝原文 | 无 | 无 | 无 |
| tool_use_id / message.id | 无 | 无 | 无 |
| calc.py 路径 | 无 | 无 | 无 |
| transcript 路径 | `~/.teamai/dashboard/events.jsonl` | `~/.teamai/dashboard/events.jsonl` | `~/.teamai/dashboard/events.jsonl`<br>`~/.teamai/reporter/errors.jsonl` |
| 业务仓 remote | `~/.teamai/debug.log` | `~/.teamai/debug.log` | `~/.teamai/debug.log` |
| Claude Code 版本 2.1.260 / gitBranch | 无 | 无 | 无 |
| 完整 session_id | `~/.teamai/dashboard/events.jsonl` | `~/.teamai/dashboard/events.jsonl`<br>`~/.teamai/dashboard/reported-interventions.json`<br>`~/.teamai/dashboard/reported-prompt-tokens.json`<br>`~/.teamai/session-logs/2026-09.md`<br>`~/<分区>/team-repo/sessions/demo-user/2026-09.md`<br>`远端:sessions/demo-user/2026-09.md` | `~/.teamai/dashboard/events.jsonl`<br>`~/.teamai/reporter/errors.jsonl` |
| demo 项目绝对路径 | `~/.npm/_logs/2026-09-11T06_17_18_079Z-debug-0.log`<br>`~/.npm/_logs/2026-09-11T06_17_34_467Z-debug-0.log`<br>`~/.teamai/dashboard/events.jsonl` | `~/.npm/_logs/2026-09-11T06_21_16_486Z-debug-0.log`<br>`~/.npm/_logs/2026-09-11T06_21_32_776Z-debug-0.log`<br>`~/.npm/_logs/2026-09-11T06_30_57_952Z-debug-0.log`<br>`~/.teamai/dashboard/events.jsonl`<br>`~/.teamai/debug.log`<br>`~/.teamai/session-logs/2026-09.md`<br>`~/<分区>/config.yaml`<br>`~/<分区>/team-repo/sessions/demo-user/2026-09.md`<br>`远端:sessions/demo-user/2026-09.md` | `~/.npm/_logs/2026-09-11T06_23_54_044Z-debug-0.log`<br>`~/.npm/_logs/2026-09-11T06_24_11_987Z-debug-0.log`<br>`~/.teamai/dashboard/events.jsonl`<br>`~/.teamai/debug.log`<br>`~/.teamai/reporter/errors.jsonl` |

| 内容 | 本机 | 出本机 | 出处（文件:行） |
|---|---|---|---|
| prompt 正文 | **采**。① 三条 prompt 各取前 200 字**原文**进 events.jsonl 的 `promptSummary`。② debug.log 再记前 60 字，本例等于全文。③ 首条经脱敏、单行化后截 160 字，进 `sessions/<sid>.json`。④ 手动 `session save` 时写进 session-logs。(c) 失败日志也带 | 默认不出。git 上报只有计数，`session save --push` 默认不带（加 `--include-prompt` 才带首条），HTTP 请求体不带。上报的 `correction` 计数是拿 prompt 文本算的 | `dashboard-collector.ts:839-842,891-896`；`contribute-check.ts:104-117`；`session-collector.ts:162`；`local-agent.ts:3130` |
| 模型回复正文 | **部分采**。每次 Stop 只取最后一条 assistant text，脱敏后截 500 字进 `stoppedOutput`，本例两条都是原文。其余回复不存 | 不出（(c) 的 errors.jsonl 在本机） | `dashboard-collector.ts:74-121,847-850` |
| thinking | 不采，grep 无命中。只取 `type:"text"` 块 | 不出 | `dashboard-collector.ts:97-103` |
| Edit 的新旧文本 | 不采，grep 无命中。PostToolUse 只取 `tool_name`。整份 stdin 会经管道交给后台子进程，只在内存里 | 不出 | `dashboard-collector.ts:821-823`；`hook-dispatch-cli.ts:74-107,198-206` |
| 改前的整份文件 | 不采，grep 无命中。`tool_response.originalFile` 的去向同上 | 不出 | 同上 |
| Bash 命令 | 不采：pytest 和被拒的 sed 都无命中。PreToolUse 不挂，PostToolUse 丢掉 `tool_input` | 不出 | `builtin-hooks.ts:221-228`；`dashboard-collector.ts:821-823` |
| 工具输出 | 不采，`3 passed` 无命中。扫 transcript 时只看 tool_result 的 `is_error` 和拒绝标记串 | 不出 | `dashboard-collector.ts:315-329` |
| 假密钥 sk-demo 是否被脱敏 | **本例没被采到**，任何 teamai 文件里都没有，谈不上脱敏。补充实测两种情形：<br>① 出现在最后一条回复里：用仓里的 `redact.ts` 实跑，得到 `OPENAI_API_KEY=<REDACTED:openai>`，会被脱敏。<br>② 出现在 prompt 里（`state-x`）：events.jsonl 和 debug.log **原文落盘**，见表下；只有 `sessions/<sid>.json` 那份会脱敏 | 不出 | `utils/redact.ts:53,142-144`；对照 `dashboard-collector.ts:113` 与 `:841,894` |
| 被拒绝的调用 | 命令不存。它没有 PostToolUse，所以 `tool_use` 只有 Edit、Bash 两条，`Tools: 2`。Stop#2 扫 transcript 时记 `toolReject: 1` | **计数出**：stats 的 `interventions.toolReject` 从 0 变 1 | `dashboard-collector.ts:315-324,854-860`；`team-push.ts:163-170` |
| interrupt 记录 | Stop#2 记 `interrupt: 1`。它和上一行是**同一次拒绝**，于是一次人工动作记成了两次干预 | **计数出**：stats 的 `interventions.interrupt` 从 0 变 1 | `dashboard-collector.ts:310-311`；`team-push.ts:166` |
| 文件路径与 cwd | 每条事件都带 cwd 绝对路径，Stop 事件带 transcript 绝对路径。calc.py 路径不存。(b) 的 debug.log 有项目 realpath，分区 config 里有 projectRoot。npm 子进程的日志里也有项目路径。每次 hook 还往**项目父目录**写一次探针 | git 自动上报**不带**。`session save --push` 原样带 cwd 绝对路径，实跑已推到远端。HTTP report 带 `workspaces[].path` | `dashboard-collector.ts:810-818,846`；`project-agent-root.ts:65`；`utils/partition.ts:44-64`；`session-collector.ts:157`；`local-agent.ts:1588-1593` |
| 仓库、分支、remote | 分支不采，transcript 的 `gitBranch` 不读。**业务仓 remote 原样进 debug.log**，因为 example.com 不被识别。团队仓 URL 在分区配置里 | 本例不出。remote 若是 github.com 或 git.woa.com，每次 SessionStart 会去查该仓近 7 天合入的 PR | `mr-hint.ts:410-472` |
| token 用量 | Stop 事件存累计快照：1050/230/4800/0，然后 1150/322/7200/0。`reported-prompt-tokens.json` 按会话记 | **出**：stats 的 `tokens` 四桶，要到下一次 pull 才出去 | `dashboard-collector.ts:269-283,861-865`；`team-push.ts:245-272,430-434` |
| 用户与主机身份 | (b) 用户名（git user.name 规范化后）在分区 config 里；事件带 `monitorPid`；git 模式不采主机名。另注意：真实环境的 cwd 通常是 `/Users/<账户名>/…`，OS 账户名就跟着每条事件的 cwd 走 | **出**：stats 和 members 的文件名与 `username`；每个 commit 的作者名、全局 git 邮箱和提交时刻；`session save --push` 推出去的 cwd 里带着 OS 账户名。(c) HTTP 模式另发 **hostname 明文**、os、`local_agent_id`（机器 ID 的哈希），并为此执行 `claude --version` | `team-push.ts:419`；`init.ts:1236-1262`；`utils/git.ts:69-89`；`providers/git/index.ts:27-46`；`local-agent.ts:1566-1572`；`agent-version.ts:43-48` |
| 会话 id 与 tool_use_id | 完整 session_id 出现在每条事件、`sessions/<sid>.json` 的文件名、`reported-*.json` 的键里；debug.log 记前 16 位。tool_use_id、message.id、requestId 都不采，grep 无命中 | git 自动上报不带。`session save --push` 带完整 id（写在 HTML 注释里）和前 8 位，实跑已推到远端 | `dashboard-collector.ts:809,896`；`contribute-check.ts:120-127`；`team-push.ts:494`；`session-collector.ts:154-155` |

表中 ② 的实跑原样（`state-x`，一次 UserPromptSubmit，prompt 里带假密钥）：

```jsonl
{
  "type": "prompt_submit",
  "timestamp": "2026-09-11T06:27:56.270Z",
  "sessionId": "33333333-4444-4555-8666-777777777777",
  "tool": "claude",
  "cwd": "$RUN/state-x/demo-proj",
  "promptSummary": "用这个 key 调一下：sk-demo-1234567890abcdef1234"
}
```

```text
2026-09-11T06:27:56.274Z [DEBUG] dashboard: recorded prompt_submit for session 33333333-4444-45 [prompt=用这个 key 调一下：sk-demo-1234567890abcdef1234]
```

## 5. 与采集清单文档、以及与推演版对不上的地方

### 5.1 对照采集清单 `third-party/teamai-cli-collection.md`

清单的快照是 `6ae0619`，本机没有这个提交，只能拿 `224c0c4` 核。下面只列实跑能判定的。

**实跑证实、没有出入的**：
- §1 的挂载与分发：4 类事件、6 条 hook；PreToolUse 和 SessionEnd 不挂；**fail-open**，(a) 没 init 也照记，(b) 里未 init 目录的会话照记。
- §2.1 events 的全部字段与判据：token 去重、打断和拒绝的判法、真人轮数。
- §2.3 各字段。
- §2.8 prompt 前 60 字。
- §3.1 stats 的字段，以及 `toolError` 不上报。
- §3.2 `session save --push` 带 cwd 绝对路径和完整 id。
- §3.3 report 请求体的字段。
- §4「明确不采」各项：grep 全部无命中。
- §5 表第 1、3、4、5 条。

**对不上或漏写的**：

1. **§1 表 `update`「后台查 npm registry 有无新版，只发包名」写轻了**：
   - 它不是在进程内发请求，而是起一个 `npm` 子进程。npm 在 `~/.npm/_logs/` 留日志，里面有项目路径（§2.4）。
   - 已是最新版时缓存不生效，**每次 Stop 都查**（`update.ts:348`）。
   - 查到新版、且策略是默认的 `auto` 时，Stop 的后台子进程会直接 `npm install -g teamai-cli`，再跑 `teamai hooks inject`（`update.ts:414-439`）。这是从 hook 里自动升级，清单只写成了「查版本」。
2. **§2「采集类数据全部在 `~/.teamai/` 顶层」**：就采集数据而言成立。但 hook 运行还会往外写三处，清单没提：
   - `~/.npm/_logs/`；
   - 项目父目录里的瞬时探针文件（§2.5，已用沙箱日志证实）；
   - (b) 下 SessionStart 的 pull 往**业务项目**里部署 `.claude/skills/team-wiki-codebase/`，12 个文件，untracked（§2.7）。
3. **§2.3 `sessions/<sid>.json` 不是实时值**：Stop#2 走了 fast-path，文件停在 Stop#1，`friction` 全是 0；而这段会话实际有 1 次打断、1 次拒绝（§2.3）。字段表读起来像每次 Stop 都会刷新。
4. **§2.8 debug.log 漏项**：除了 prompt 前 60 字（HTTP 模式还有请求体），实跑还记下了：
   - 业务仓 origin 的 **remote URL 原样**；
   - 项目 realpath；
   - contribute 的摩擦计数；
   - `npm view` 失败的完整命令行；
   - init 过程。
5. **§3.1「随 `teamai pull` 自动直推」没写清时机和 git 历史的含义**：
   - 本会话在**自己的** SessionStart 上就先按 0 值计进 `sessions`；真实计数要到**下一次**在该项目里开会话才推，而下一段会话又会被先按 0 值记一次。
   - 一次 pull 一个 commit，所以 git 历史里有逐次增量、全局 git 邮箱，还有 commit 时间，也就是每次开会话的时刻。
6. **§3.1 作用域过滤**：清单写的是「project 级团队仓只收 cwd 在 projectRoot 下的会话」。实跑发现，经符号链接进入项目的会话会被**整段漏报**：比较的是字符串前缀，projectRoot 却是 realpath（§3.2）。
7. **§3.1「init 时注册 `members/<user>.yaml`」**：团队仓为空时，init 还会生成并直推 `teamai.yaml`（团队名、仓地址、provider 等）和 5 个 `.gitkeep`（§3.1）。
8. **§3.3「每个 hook 事件都会 POST 一次 report 加一次 sync」**：
   - report 失败时 sync 不再发，日志却记成 `sync FAILED`。
   - 另有 `GET /api/projects/mine` 和 `GET /api/local-agent/get-config`。
   - 每次 report 前都执行一次 `claude --version`。
9. **没写出的前提：project scope 的 hook 装在 HOME 级 `~/.claude/settings.json`**（`types.ts:1497-1503`，实跑 §2.6）。「没 init 过的目录照样进 events.jsonl」之所以在现实中天天发生，就是因为这一条。
10. **行号**：清单 §1 引的 `hook-handlers.ts:474,480,487`，在 `224c0c4` 上是 `473,479,486`。清单说这个文件两版之间没动，但 `6ae0619` 无从核对，不知道是哪边错。

### 5.2 对照推演版（同日按源码推演、没有实跑的一版，没有入库）

推演版写于 14:27，写完本文时核对过，它的哈希没变。

**推演说对了、实跑逐字对上的**：
- events.jsonl 八行的每个字段和取值：tokens、prompts、interventions、stoppedOutput、promptSummary。
- `sessions/<sid>.json` 的全部取值，以及 Stop#2 走 fast-path 不更新。
- 两个 `reported-*.json` 在两个时点的内容。
- 两次 stats 推送的内容，以及「下一段会话会被按 0 值先记一次」这一注。
- commit 作者的名字取自用户名、邮箱取自全局 git。
- `session save` 的本机版和团队版全文。
- debug.log 各类行的来历。
- 「一次拒绝记两次」「别改 add 不算 correction」。

**不一样或推演没覆盖的**：

1. **前提不同**：推演假设按 README 做默认 init，GitHub provider、gh 已登录。
   - 本机没装 gh，断网下这条路停在认证（§3.1 原文），走不到 clone。
   - 所以实跑的 (b) 用的是通用 Git provider，其余选项相同。username 取自 git user.name，而不是 gh 登录名；`teamai.yaml` 里 `provider: git`。
   - 推演里 GitHub 特有的部分这次没跑到。
   - 推演也没有 (a) 这种状态。实跑表明 (a) 写出的会话数据与 (b) 完全相同，只是不推。
2. **推演 §2.6「update 检查只要真去查了 registry，就把 `lastUpdateCheck`、`availableUpdate` 写进 `~/.teamai/state.json`」**：推演给的是条件句，本次条件不满足。断网时 fetch 失败，在 `saveState` 之前就返回了，所以实跑里没有这个文件，不算矛盾。
   真正没覆盖到的是 npm 子进程在 `~/.npm/_logs/` 留下的日志（§2.4）。
3. **推演 §2.6 只说后台 pull「在 `<项目>/.claude/` 建目录」**：实跑中它还把 teamai 自带的 `team-wiki-codebase` skill（12 个文件、148 KB）部署进了业务项目。团队仓是空的也照样部署。
4. **推演没提的本机写入**：
   - init 写的 `~/.teamai/bin/teamai` 包装脚本；
   - 每次 hook 在项目父目录里建、删的探针文件（§2.5）；
   - init 打印的配置路径与实际不符（§2.6）。
5. **推演 §3.1 注 2「符号链接会被过滤掉……拿不准」**：teamai 这一侧已实跑证实，会整段漏报（§3.2）。Claude Code 在 macOS 上报哪种 cwd，仍未验证。
6. **推演 §3.1「第一次推送……大概率赶得上」**：实跑中真实路径下的 3 次 SessionStart，3 次都赶上了。
7. **推演 §3.3 HTTP 部分**：
   - 推演写「至少 16 个 POST」，这是联网时的数。断网实测是 8 次 report、0 次 sync。
   - 推演说 SessionStart 可能多出 `GET /api/projects/mine` 和插件对账请求、「具体次数拿不准」：实测两者各 1 次，另外第一次 UserPromptSubmit 也发了一次 `/api/projects/mine`，共 3 个 GET。
   - 推演写 `started_at` 取「`local-agent/config.json` 的 createdAt」，那是文件配置的情形。用环境变量配置时，它是每次调用的当前时间。
   - 推演给 `agent_version` 的占位说明对上了：实跑中它来自执行 `claude --version`，本机得到 2.1.12，不是 transcript 里的 2.1.260。
8. **推演 §2.4 所列 debug.log 的顺序**：实跑中 `mr-hint` 那行排在 `recorded session_start` 之前，因为两者是并发的前台 handler。无关紧要，只为对齐原文。
