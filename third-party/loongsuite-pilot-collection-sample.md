# LoongSuite Pilot 采集样例：同一段示例会话，它记下了什么

> **入库说明**（2026-09-11）：输入是两家共用的示例会话 [experiments/collect-demo/scenario.json](../experiments/collect-demo/scenario.json)，内容全是编的，不含真实会话。实跑在第六轮审计所在的机器 C02FM 上做，回放脚本与产物写死了那台机器的临时路径，留在那里没有入库。入库时另把一个假 GitLab 令牌换成了 `glpat-<假令牌>`：它的格式和真令牌一样，推到 GitHub 会被推送保护拦下。

> **生成方式**：hook 侧**实跑**——Pilot 的 `assets/hooks/` 原样拷进假 HOME 的 `~/.loongsuite-pilot/hooks/`（安装布局），按 `scenario.json` 25 步回放，hook 脚本自选 `/opt/homebrew/bin/node` v21.4.0 执行。daemon 侧**大部分实跑**——本机 PATH 上已有一个 nvm 装的 node v24.14.1（没下载、没装任何东西），用 `--experimental-transform-types` 直接加载 Pilot 的 `src/*.ts`，按 `orchestrator.ts` 的装配方式跑了配置加载、hook 日志读取、归一化、git 富化、JSONL 输出、SLS（webtracking）与 HTTP 出站、日志保留清理；仓里缺的 npm 包用桩代替，出站的网络层换成只记录请求的桩（详见 §2.3 开头）。**按源码推演**：OTLP trace 出站、SLS 的 AK/apiKey 信封、运行状态回传报文、本次没触发的文件。另做了三轮**补充实跑**，不属于 scenario 本身、单独标出：B 用假 `fetch` 驱动真实的 fetch 拦截器（§2.5），C 关掉 `captureMessageContent` 重跑（§2.6），D 开 `mask.mode=all` 重跑 daemon（§3.2）。全部 Pilot 代码都在 `sandbox-exec -p '(version 1)(allow default)(deny network*)'` 下、`HOME` 指向 scratch、`env -i` 干净环境中执行（daemon 与补充轮另加 `(deny file-write* (subpath "$HOME"))`）；断网实测有效（沙箱内 `connect` 返回 `EPERM`）。没有写 `~/.claude`、真实 HOME 与 Pilot 仓（只读执行了 `~/.nvm` 里已有的 node v24）。
>
> **源码版本**：`d4ab8b6d`（`package.json` version `1.2.0`）。
>
> **假设的配置**：新装默认，照 `deploy/installer-opensource.sh` `write_config()`（:998-1143）在不带参数、提示处直接回车时的产物：`{"enabled":true,"dataDir":"~/.loongsuite-pilot","dashboard":{"port":8765},"agents":{"claude-code":{"enabled":true}}}`（真实安装时 `agents` 下还会列出其他探测到的 agent，与本例无关）。没有 `userId`、`sls`、`http`、`otlpTrace`、`cms`、`mask`。原文与 `loadConfig()` 实跑结果见 §2.0。
>
> **日期**：2026-09-11。事件时间取自 transcript（03:00:07–03:01:31 UTC）。
>
> **展示约定**：代码块里做了纯文本替换——scratch 前缀换回 scenario 原值 `/tmp/demo-proj`、`/tmp/demo-home`（便于与 teamai 那份对照），本机 hostname 换成 `<本机hostname>`，本机 IP 换成 `<本机IP>`；`gen_ai.input.messages_hash` 是按替换前的内容算的。没有超长字段，均未截断。原始产物在 `collect-demo/pilot/`（目录说明见文末）。无前缀的 `:行号` 指 `assets/hooks/claude-code-hook-processor.mjs`。

## 1. 示例会话

**第 1 轮**：用户让 Claude 给 `calc.py` 的 `div` 加零检查再跑测试。Claude 用 Edit 改文件，用 Bash 跑 `pytest`，输出里混着一个假密钥 `sk-demo-…`，然后回复「改好了」。
**第 2 轮**：用户让「顺便把 add 改成减法」。Claude 的 Bash（`sed`）调用被用户拒绝，transcript 里带 interrupt 记录。用户纠正「别改 add，那是故意留的」，Claude 回复「好的，add 不动」，然后 SessionEnd。

## 2. 本机落盘的文件

### 2.0 前提：配置，以及 Claude Code 实际调用了 Pilot 几次（实跑）

写进假 HOME 的 `~/.loongsuite-pilot/config.json`：

```json
{
  "enabled": true,
  "dataDir": "/tmp/demo-home/.loongsuite-pilot",
  "dashboard": {
    "port": 8765
  },
  "agents": {
    "claude-code": {
      "enabled": true
    }
  }
}
```

用真实 `loadConfig()`（`src/core/config-loader.ts`）读它，有效配置节选：

```json
{
  "userId": "<本机hostname>",
  "collectLog": true,
  "collectTrace": true,
  "otlpTrace": null,
  "cms": {
    "enabled": false
  },
  "agents": {
    "claude-code": {
      "enabled": true,
      "captureMessageContent": true
    }
  },
  "mask": {
    "mode": "none",
    "types": []
  },
  "flushers.sls.enabled": false,
  "flushers.sls.endpoints": [],
  "flushers.http.enabled": false,
  "flushers.jsonl": {
    "enabled": true,
    "outputDir": "/tmp/demo-home/.loongsuite-pilot/logs/output",
    "rotateDaily": true,
    "maxFileSizeMb": 100
  },
  "upstreamLink": {
    "enabled": false,
    "propagateToTools": false,
    "generateTraceWhenMissing": false,
    "ttlMs": 86400000
  },
  "retention": {
    "enabled": true,
    "intervalMs": 21600000,
    "hookHistoryDays": 7,
    "hookErrorDays": 7,
    "hookDebugDays": 7,
    "outputDays": 7,
    "slsFailedDays": 7,
    "otlpFailedDays": 7,
    "metricAlarmDays": 7
  }
}
```

即：`user.id` 取本机 hostname（`config-loader.ts:274`），内容全采（`:510`），不脱敏（`:560-563`），只开本机 JSONL（`:1146-1155`）。`collectTrace` 虽为 `true`，但没有任何 trace 端点，不会建 OTLP flusher（`src/core/orchestrator.ts:767-775`）。

Pilot 往 `~/.claude/settings.json` 只注册 4 个事件（`agents.d/claude-code.json:11-22`）：`PreToolUse`（matcher `Bash`）、`Stop`、`SubagentStart`、`SubagentStop`，命令是「hook 脚本路径 + kebab 子命令」（`src/deployment/hook-strategy.ts:39-41,72-82`）。scenario 25 步里有 12 个 hook 事件（另 13 步是 transcript 追加），Claude Code 只会把其中 4 个交给 Pilot：

| 步 | scenario 动作 | Pilot 是否收到 | 结果 |
|---:|---|---|---|
| 1 | hook SessionStart | 否 | settings.json 里 Pilot 没有注册 SessionStart |
| 2 | hook UserPromptSubmit | 否 | settings.json 里 Pilot 没有注册 UserPromptSubmit |
| 3 | transcript 追加：user prompt（prompt-1） | —（hook 不监听文件，Stop 时才读） | |
| 4 | transcript 追加：assistant msg_demo_3ff7c188：thinking | —（hook 不监听文件，Stop 时才读） | |
| 5 | transcript 追加：assistant msg_demo_398d81be：tool_use Edit | —（hook 不监听文件，Stop 时才读） | |
| 6 | hook PreToolUse（Edit） | 否 | PreToolUse matcher 是 "Bash"，工具 Edit 不匹配 |
| 7 | transcript 追加：user tool_result toolu_demo_edit_1 | —（hook 不监听文件，Stop 时才读） | |
| 8 | hook PostToolUse（Edit） | 否 | settings.json 里 Pilot 没有注册 PostToolUse |
| 9 | transcript 追加：assistant msg_demo_7b11e90c：tool_use Bash | —（hook 不监听文件，Stop 时才读） | |
| 10 | hook PreToolUse（Bash） | **是**（`claude-code-loongsuite-pilot-hook.sh pre-tool-use`） | stdout `{}`，142 ms；未写任何文件 |
| 11 | transcript 追加：user tool_result toolu_demo_bash_1 | —（hook 不监听文件，Stop 时才读） | |
| 12 | hook PostToolUse（Bash） | 否 | settings.json 里 Pilot 没有注册 PostToolUse |
| 13 | transcript 追加：assistant msg_demo_f3215ee5：text | —（hook 不监听文件，Stop 时才读） | |
| 14 | hook Stop | **是**（`claude-code-loongsuite-pilot-hook.sh stop`） | stdout `{}`，453 ms；写 `logs/claude-code/…jsonl` 与 `state/…/<sid>.json` |
| 15 | hook UserPromptSubmit | 否 | settings.json 里 Pilot 没有注册 UserPromptSubmit |
| 16 | transcript 追加：user prompt（prompt-2） | —（hook 不监听文件，Stop 时才读） | |
| 17 | transcript 追加：assistant msg_demo_16a3091b：tool_use Bash | —（hook 不监听文件，Stop 时才读） | |
| 18 | hook PreToolUse（Bash） | **是**（`claude-code-loongsuite-pilot-hook.sh pre-tool-use`） | stdout `{}`，116 ms；未写任何文件 |
| 19 | transcript 追加：user tool_result toolu_demo_bash_2（is_error，拒绝） | —（hook 不监听文件，Stop 时才读） | |
| 20 | transcript 追加：user「[Request interrupted by user for tool use]」 | —（hook 不监听文件，Stop 时才读） | |
| 21 | hook UserPromptSubmit | 否 | settings.json 里 Pilot 没有注册 UserPromptSubmit |
| 22 | transcript 追加：user prompt（prompt-3） | —（hook 不监听文件，Stop 时才读） | |
| 23 | transcript 追加：assistant msg_demo_a7db0399：text | —（hook 不监听文件，Stop 时才读） | |
| 24 | hook Stop | **是**（`claude-code-loongsuite-pilot-hook.sh stop`） | stdout `{}`，433 ms；写 `logs/claude-code/…jsonl` 与 `state/…/<sid>.json` |
| 25 | hook SessionEnd | 否 | settings.json 里 Pilot 没有注册 SessionEnd |

要点：

- **只在 `Stop` 采集，数据全部来自 transcript**。Pilot 收不到 `UserPromptSubmit`、`PostToolUse`、`SessionStart/End`，hook payload 里的 `prompt`、`tool_response` 它一概不用。
- `PreToolUse`(Bash) 不写任何东西：链路传播 `upstreamLink` 默认关，处理器在 `:310-311` 直接返回 `{}`。
- Pilot 按 transcript 里 user 记录的 `promptId` 切 turn（`claude-code/transcript-parser.mjs:264-268,527-544`）：prompt-1 → `t1`，prompt-2（被拒的那次）→ `t2`，prompt-3（用户纠正）→ `t3`。scenario 的「第 2 轮」在 Pilot 数据里是两个 turn。
- 第 1 次 `Stop` 是这个 session 的首次导出（无 `turn_count`、offset 0），规则是只导出最后一个 turn（`:820-824`）；此刻 transcript 里只有 1 个 turn，所以没有东西被跳过。

本次落盘一览：

| 路径（`~/.loongsuite-pilot/` 下） | 谁写 | 何时写 | 保留多久 | 本次 |
|---|---|---|---|---|
| `logs/claude-code/claude-code-2026-09-11.jsonl` | hook | 每次 `Stop` 追加 | **永不删除**（实跑验证） | 实跑，21 条 |
| `state/claude-code/sessions/<sid>.json` | hook | 每次 `Stop` 覆盖 | 永不删除（实跑验证） | 实跑，1 个 |
| `logs/output/claude-code-2026-09-11.jsonl` | daemon | 每 30 s 轮询后追加 | 7 天（实跑验证） | 实跑，24 条 |
| `logs/input-state.json` | daemon | 每个轮询周期 | 覆盖写，不清理 | 实跑 |
| `intercept/claude-code/<sid>/<response_id>.json` | fetch 拦截器 | 每次 LLM 调用 | `Stop` 合并后删 | 补充实跑 B，6 个 |
| 其他（错误日志、指标、看板汇总、daemon 日志、settings.json、shell rc） | 见 §2.7 | | | 按源码推演 |

Pilot 没有单独的 spool 目录：hook 侧那份 JSONL 就是 daemon 的输入队列，daemon 读完只在 `logs/input-state.json` 里推进 offset，不删不改原文件。本次 4 次 hook 调用都正常退出，没有产生 `logs/claude-code/errors/`，也没有 `acp-correlate/`。

### 2.1 hook 侧事件流：`logs/claude-code/claude-code-2026-09-11.jsonl`（实跑）

- **路径**：`~/.loongsuite-pilot/logs/claude-code/claude-code-YYYY-MM-DD.jsonl`，日期取 hook 进程的本地时区（`shared/event-emitter.mjs:76-94`）。
- **何时写**：每次 `Stop` 同步解析 transcript 自上次 offset 起的新增部分，已归一化的事件追加写入（`:769-919`，写盘在 `:913`）；原始 hook payload 不落盘。本次第 1 次 `Stop`（步 14）写 13 条，第 2 次（步 24）写 8 条。
- **保留多久**：**永不删除**。保留服务只清 `logs/<agent>/` 下叫 `errors`、`history` 等名字的子目录，不碰根下文件（`src/core/log-retention-service.ts:49-57,148-170`）；daemon 读完只推进 offset。在一份拷贝目录上跑真实的 `LogRetentionService.runCleanup()`（默认保留配置，文件日期设为 40 天前）：

```text
retention config: {"enabled":true,"intervalMs":21600000,"hookHistoryDays":7,"hookErrorDays":7,"hookDebugDays":7,"outputDays":7,"slsFailedDays":7,"otlpFailedDays":7,"metricAlarmDays":7}
runCleanup: {"deleted":2,"errors":0}
KEPT    intercept/claude-code/old-session/msg_old.json
KEPT    logs/claude-code/claude-code-2026-08-01.jsonl
DELETED logs/claude-code/errors/claude-code-error-2026-08-01.jsonl
KEPT    logs/input-state.json
DELETED logs/output/claude-code-2026-08-01.jsonl
KEPT    state/claude-code/sessions/old-session.json
```

- **读下面 21 条之前的要点**：
  - **prompt 全文，每条 2 份**：`other`（#1/#14/#19）和同一轮第一次 `llm.request` 的输入增量（#2/#15/#20）。
  - **模型输出全文**进 `llm.response`；同一轮里不是最后一次的输出，还会作为下一次 `llm.request` 的输入增量再出现一次（`claude-code/transcript-parser.mjs:454-461`）。thinking 也是：#3 的 `reasoning` 在 #4 又出现。
  - **工具参数、工具结果全文**：`tool.call` 带完整参数（Edit 的 `old_string`/`new_string`、Bash 的 `command`/`description`），`tool.result` 带完整结果，结果又进下一次 `llm.request`。所以 Edit 文本、Bash 命令在本文件里各 3 份，**sk-demo 2 份（#11、#12），全是明文**——hook 侧没有任何脱敏代码。
  - **Edit 的结果只有一句 “has been updated successfully”**：transcript 里 `toolUseResult` 带着的 `originalFile`（改前整份文件）和 `structuredPatch` 都没取（`transcript-parser.mjs:323` 只取 `tool_result.content`；`toolUseResult` 只读 `agentId`，`:326-337`）。
  - **被拒绝的 Bash**（#16–#18）：模型发出的命令照记；`tool.result.status="error"`、`error.type="ToolError"`，`error.message` 是拒绝提示的前 500 字（本例 225 个字符，没截断，`:1189-1194`）。从数据上看不出是用户拒绝还是执行失败，`toolUseResult: "User rejected tool use"` 没被读取。
  - **interrupt 记录 `[Request interrupted by user for tool use]` 不在任何一条里**：它排在 t2 最后一次模型调用之后，只进了该轮的历史，要等同轮下一次模型调用才会作为输入增量带出，而 t2 没有下一次（`transcript-parser.mjs:382-387,454-461`）。
  - **身份与路径**：每条都有 `user.id`（= hostname）和 `agent.claude-code.cwd`（cwd 绝对路径，`:961`）；没有 git 信息。
  - **id**：`gen_ai.session.id` 与 `gen_ai.agent.id` 都是 session id；`gen_ai.turn.id` = `<sid>:t<n>`（`:935`）；`gen_ai.response.id` = Anthropic `message.id`；`gen_ai.tool.call.id` = `tool_use_id`；`trace_id`（每 turn 一个）和 `span_id`/`parent_span_id` 随机生成（`shared/event-emitter.mjs:29-35`）。transcript 的 `uuid`、`promptId`、`requestId`、`version`、`gitBranch` 都没进事件。
  - **token**：`gen_ai.usage.input_tokens` = `input_tokens + cache_read + cache_creation`（#3：900+1200+0=2100，`:1082-1088`），另有 output、cache_read、cache_creation、total；没有成本字段。`gen_ai.input.messages` 全量从不写（输入一律按增量，`transcript-parser.mjs:441-442`）。

| # | 写入于 | event.name | turn / step | 时间（transcript） | 要点 |
|---:|---|---|---|---|---|
| 1 | 第 1 次 Stop（步 14） | other | t1 | 03:00:07 | prompt 全文（messages_delta） |
| 2 | 第 1 次 Stop（步 14） | llm.request | t1 / s1 | 03:00:07 | 输入增量：user[text] |
| 3 | 第 1 次 Stop（步 14） | llm.response | t1 / s1 | 03:00:14 | 输出 reasoning；token 2100/40 |
| 4 | 第 1 次 Stop（步 14） | llm.request | t1 / s2 | 03:00:14 | 输入增量：assistant[reasoning] |
| 5 | 第 1 次 Stop（步 14） | llm.response | t1 / s2 | 03:00:21 | 输出 tool_call:Edit；token 1250/80 |
| 6 | 第 1 次 Stop（步 14） | tool.call | t1 / s2 | 03:00:21 | Edit 参数全文 |
| 7 | 第 1 次 Stop（步 14） | llm.request | t1 / s3 | 03:00:28 | 输入增量：assistant[tool_call] + tool[tool_call_response] |
| 8 | 第 1 次 Stop（步 14） | tool.result | t1 / s2 | 03:00:28 | Edit 结果全文，status=success |
| 9 | 第 1 次 Stop（步 14） | llm.response | t1 / s3 | 03:00:35 | 输出 tool_call:Bash；token 1250/80 |
| 10 | 第 1 次 Stop（步 14） | tool.call | t1 / s3 | 03:00:35 | Bash 参数全文 |
| 11 | 第 1 次 Stop（步 14） | llm.request | t1 / s4 | 03:00:42 | 输入增量：assistant[tool_call] + tool[tool_call_response] |
| 12 | 第 1 次 Stop（步 14） | tool.result | t1 / s3 | 03:00:42 | Bash 结果全文，status=success |
| 13 | 第 1 次 Stop（步 14） | llm.response | t1 / s4 | 03:00:49 | 输出 text；token 1250/30 |
| 14 | 第 2 次 Stop（步 24） | other | t2 | 03:00:56 | prompt 全文（messages_delta） |
| 15 | 第 2 次 Stop（步 24） | llm.request | t2 / s1 | 03:00:56 | 输入增量：user[text] |
| 16 | 第 2 次 Stop（步 24） | llm.response | t2 / s1 | 03:01:03 | 输出 tool_call:Bash；token 1250/80 |
| 17 | 第 2 次 Stop（步 24） | tool.call | t2 / s1 | 03:01:03 | Bash 参数全文 |
| 18 | 第 2 次 Stop（步 24） | tool.result | t2 / s1 | 03:01:10 | Bash 结果全文，status=error，ToolError |
| 19 | 第 2 次 Stop（步 24） | other | t3 | 03:01:24 | prompt 全文（messages_delta） |
| 20 | 第 2 次 Stop（步 24） | llm.request | t3 / s1 | 03:01:24 | 输入增量：user[text] |
| 21 | 第 2 次 Stop（步 24） | llm.response | t3 / s1 | 03:01:31 | 输出 text；token 1250/12 |

```jsonl
{
  "time_unix_nano": "1789095607000000000",
  "event.id": "b34eb683-3b18-4e26-a767-fffca7269098",
  "event.name": "other",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "gen_ai.input.messages_delta": [
    {
      "role": "user",
      "parts": [
        {
          "type": "text",
          "content": "给 calc.py 的 div 加零检查，然后跑一下测试"
        }
      ]
    }
  ]
}

{
  "time_unix_nano": "1789095607000000000",
  "event.id": "1aa661d4-20ba-4341-9589-bed313a50993",
  "event.name": "llm.request",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "2c6e3cb61c1781b4",
  "parent_span_id": "46bd8cb637f9e61d",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s1",
  "gen_ai.response.id": "msg_demo_3ff7c188",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.input.messages_hash": "df4bff81f1f4d305652949f54649e6f5",
  "gen_ai.input.messages_delta": [
    {
      "role": "user",
      "parts": [
        {
          "type": "text",
          "content": "给 calc.py 的 div 加零检查，然后跑一下测试"
        }
      ]
    }
  ]
}

{
  "time_unix_nano": "1789095614000000000",
  "event.id": "b1057dc9-451f-470b-8ea6-fbc83c0cd703",
  "event.name": "llm.response",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "2c6e3cb61c1781b4",
  "parent_span_id": "46bd8cb637f9e61d",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s1",
  "gen_ai.response.id": "msg_demo_3ff7c188",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.response.model": "claude-opus-5",
  "gen_ai.response.finish_reasons": [
    "tool_call"
  ],
  "gen_ai.usage.input_tokens": 2100,
  "gen_ai.usage.output_tokens": 40,
  "gen_ai.usage.cache_read.input_tokens": 1200,
  "gen_ai.usage.cache_creation.input_tokens": 0,
  "gen_ai.usage.total_tokens": 2140,
  "gen_ai.output.messages": [
    {
      "role": "assistant",
      "parts": [
        {
          "type": "reasoning",
          "content": "用户要给 div 加零检查。先用 Edit 改 calc.py，再跑 pytest 确认。"
        }
      ],
      "finish_reason": "tool_call"
    }
  ]
}

{
  "time_unix_nano": "1789095614000000000",
  "event.id": "97111fbc-1af0-480b-b578-6d6641e26a11",
  "event.name": "llm.request",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "3993c1c3f7c21c36",
  "parent_span_id": "435dd82377df37b8",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s2",
  "gen_ai.response.id": "msg_demo_398d81be",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.input.messages_hash": "4112c376a2c7ef339466879a37b60034",
  "gen_ai.input.messages_delta": [
    {
      "role": "assistant",
      "parts": [
        {
          "type": "reasoning",
          "content": "用户要给 div 加零检查。先用 Edit 改 calc.py，再跑 pytest 确认。"
        }
      ]
    }
  ]
}

{
  "time_unix_nano": "1789095621000000000",
  "event.id": "72d7b6b2-c576-4d5f-b0f4-e1fb56e07fc7",
  "event.name": "llm.response",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "3993c1c3f7c21c36",
  "parent_span_id": "435dd82377df37b8",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s2",
  "gen_ai.response.id": "msg_demo_398d81be",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.response.model": "claude-opus-5",
  "gen_ai.response.finish_reasons": [
    "tool_call"
  ],
  "gen_ai.usage.input_tokens": 1250,
  "gen_ai.usage.output_tokens": 80,
  "gen_ai.usage.cache_read.input_tokens": 1200,
  "gen_ai.usage.cache_creation.input_tokens": 0,
  "gen_ai.usage.total_tokens": 1330,
  "gen_ai.output.messages": [
    {
      "role": "assistant",
      "parts": [
        {
          "type": "tool_call",
          "id": "toolu_demo_edit_1",
          "name": "Edit",
          "arguments": {
            "file_path": "/tmp/demo-proj/calc.py",
            "old_string": "    return a / b",
            "new_string": "    if b == 0:\n        raise ZeroDivisionError(\"b is 0\")\n    return a / b"
          }
        }
      ],
      "finish_reason": "tool_call"
    }
  ]
}

{
  "time_unix_nano": "1789095621000000000",
  "event.id": "1a11dc84-7410-4527-82de-835b6cba10f0",
  "event.name": "tool.call",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "237b21ec30c08ae4",
  "parent_span_id": "435dd82377df37b8",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s2",
  "gen_ai.tool.name": "Edit",
  "gen_ai.tool.call.id": "toolu_demo_edit_1",
  "gen_ai.tool.call.arguments": {
    "file_path": "/tmp/demo-proj/calc.py",
    "old_string": "    return a / b",
    "new_string": "    if b == 0:\n        raise ZeroDivisionError(\"b is 0\")\n    return a / b"
  }
}

{
  "time_unix_nano": "1789095628000000000",
  "event.id": "40b24182-564c-4b2a-8c3b-8e2bdc220f72",
  "event.name": "llm.request",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "a3169be08c6ccd1c",
  "parent_span_id": "e18a336844e2b076",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s3",
  "gen_ai.response.id": "msg_demo_7b11e90c",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.input.messages_hash": "a4a932a40120cbc58c25eb38578d9df6",
  "gen_ai.input.messages_delta": [
    {
      "role": "assistant",
      "parts": [
        {
          "type": "tool_call",
          "id": "toolu_demo_edit_1",
          "name": "Edit",
          "arguments": {
            "file_path": "/tmp/demo-proj/calc.py",
            "old_string": "    return a / b",
            "new_string": "    if b == 0:\n        raise ZeroDivisionError(\"b is 0\")\n    return a / b"
          }
        }
      ]
    },
    {
      "role": "tool",
      "parts": [
        {
          "type": "tool_call_response",
          "id": "toolu_demo_edit_1",
          "response": "The file /tmp/demo-proj/calc.py has been updated successfully."
        }
      ]
    }
  ]
}

{
  "time_unix_nano": "1789095628000000000",
  "event.id": "a0fd0c80-7636-4f63-bced-4ed03899a810",
  "event.name": "tool.result",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "237b21ec30c08ae4",
  "parent_span_id": "435dd82377df37b8",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s2",
  "gen_ai.tool.name": "Edit",
  "gen_ai.tool.call.id": "toolu_demo_edit_1",
  "gen_ai.tool.call.result": "The file /tmp/demo-proj/calc.py has been updated successfully.",
  "tool.result.status": "success"
}

{
  "time_unix_nano": "1789095635000000000",
  "event.id": "234f835e-da64-4a7d-872b-c9d6a3e40df0",
  "event.name": "llm.response",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "a3169be08c6ccd1c",
  "parent_span_id": "e18a336844e2b076",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s3",
  "gen_ai.response.id": "msg_demo_7b11e90c",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.response.model": "claude-opus-5",
  "gen_ai.response.finish_reasons": [
    "tool_call"
  ],
  "gen_ai.usage.input_tokens": 1250,
  "gen_ai.usage.output_tokens": 80,
  "gen_ai.usage.cache_read.input_tokens": 1200,
  "gen_ai.usage.cache_creation.input_tokens": 0,
  "gen_ai.usage.total_tokens": 1330,
  "gen_ai.output.messages": [
    {
      "role": "assistant",
      "parts": [
        {
          "type": "tool_call",
          "id": "toolu_demo_bash_1",
          "name": "Bash",
          "arguments": {
            "command": "python3 -m pytest -q",
            "description": "Run tests"
          }
        }
      ],
      "finish_reason": "tool_call"
    }
  ]
}

{
  "time_unix_nano": "1789095635000000000",
  "event.id": "ae2b2150-96f3-4df9-9d75-d922a576551c",
  "event.name": "tool.call",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "6f3d46ee1299f841",
  "parent_span_id": "e18a336844e2b076",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s3",
  "gen_ai.tool.name": "Bash",
  "gen_ai.tool.call.id": "toolu_demo_bash_1",
  "gen_ai.tool.call.arguments": {
    "command": "python3 -m pytest -q",
    "description": "Run tests"
  }
}

{
  "time_unix_nano": "1789095642000000000",
  "event.id": "b0b4f373-a8f8-4f15-8bd7-0685c8dbe1a8",
  "event.name": "llm.request",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "03adf78ba863c5fd",
  "parent_span_id": "fcf7407adb384258",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s4",
  "gen_ai.response.id": "msg_demo_f3215ee5",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.input.messages_hash": "2eed387e1a094f027162e2a9c48f81b6",
  "gen_ai.input.messages_delta": [
    {
      "role": "assistant",
      "parts": [
        {
          "type": "tool_call",
          "id": "toolu_demo_bash_1",
          "name": "Bash",
          "arguments": {
            "command": "python3 -m pytest -q",
            "description": "Run tests"
          }
        }
      ]
    },
    {
      "role": "tool",
      "parts": [
        {
          "type": "tool_call_response",
          "id": "toolu_demo_bash_1",
          "response": "...\n3 passed in 0.02s\n(debug) OPENAI_API_KEY=sk-demo-1234567890abcdef1234"
        }
      ]
    }
  ]
}

{
  "time_unix_nano": "1789095642000000000",
  "event.id": "5b22e5b6-3b21-4a9e-8f3a-b09dc38e2767",
  "event.name": "tool.result",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "6f3d46ee1299f841",
  "parent_span_id": "e18a336844e2b076",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s3",
  "gen_ai.tool.name": "Bash",
  "gen_ai.tool.call.id": "toolu_demo_bash_1",
  "gen_ai.tool.call.result": "...\n3 passed in 0.02s\n(debug) OPENAI_API_KEY=sk-demo-1234567890abcdef1234",
  "tool.result.status": "success"
}

{
  "time_unix_nano": "1789095649000000000",
  "event.id": "4258c966-3e20-43be-b218-03503ee785aa",
  "event.name": "llm.response",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "03adf78ba863c5fd",
  "parent_span_id": "fcf7407adb384258",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s4",
  "gen_ai.response.id": "msg_demo_f3215ee5",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.response.model": "claude-opus-5",
  "gen_ai.response.finish_reasons": [
    "stop"
  ],
  "gen_ai.usage.input_tokens": 1250,
  "gen_ai.usage.output_tokens": 30,
  "gen_ai.usage.cache_read.input_tokens": 1200,
  "gen_ai.usage.cache_creation.input_tokens": 0,
  "gen_ai.usage.total_tokens": 1280,
  "gen_ai.output.messages": [
    {
      "role": "assistant",
      "parts": [
        {
          "type": "text",
          "content": "改好了：div 在 b 为 0 时抛 ZeroDivisionError，3 个测试都通过。"
        }
      ],
      "finish_reason": "stop"
    }
  ]
}

{
  "time_unix_nano": "1789095656000000000",
  "event.id": "1fed439d-f743-4038-9eb3-5d0e0b79c598",
  "event.name": "other",
  "trace_id": "09e4d05018372f9603644ff32c1af38c",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t2",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "gen_ai.input.messages_delta": [
    {
      "role": "user",
      "parts": [
        {
          "type": "text",
          "content": "顺便把 add 改成减法"
        }
      ]
    }
  ]
}

{
  "time_unix_nano": "1789095656000000000",
  "event.id": "e27398c1-a634-468b-a060-79beb489259d",
  "event.name": "llm.request",
  "trace_id": "09e4d05018372f9603644ff32c1af38c",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t2",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "fcf9bde4522918d1",
  "parent_span_id": "3c7114e9b32ccd29",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t2:s1",
  "gen_ai.response.id": "msg_demo_16a3091b",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.input.messages_hash": "9a06cb2eec2f00b760d3236791207557",
  "gen_ai.input.messages_delta": [
    {
      "role": "user",
      "parts": [
        {
          "type": "text",
          "content": "顺便把 add 改成减法"
        }
      ]
    }
  ]
}

{
  "time_unix_nano": "1789095663000000000",
  "event.id": "d22efdbd-fb82-46da-8c82-983bd0f064ca",
  "event.name": "llm.response",
  "trace_id": "09e4d05018372f9603644ff32c1af38c",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t2",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "fcf9bde4522918d1",
  "parent_span_id": "3c7114e9b32ccd29",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t2:s1",
  "gen_ai.response.id": "msg_demo_16a3091b",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.response.model": "claude-opus-5",
  "gen_ai.response.finish_reasons": [
    "tool_call"
  ],
  "gen_ai.usage.input_tokens": 1250,
  "gen_ai.usage.output_tokens": 80,
  "gen_ai.usage.cache_read.input_tokens": 1200,
  "gen_ai.usage.cache_creation.input_tokens": 0,
  "gen_ai.usage.total_tokens": 1330,
  "gen_ai.output.messages": [
    {
      "role": "assistant",
      "parts": [
        {
          "type": "tool_call",
          "id": "toolu_demo_bash_2",
          "name": "Bash",
          "arguments": {
            "command": "sed -i '' 's/a + b/a - b/' calc.py",
            "description": "Change add to subtract"
          }
        }
      ],
      "finish_reason": "tool_call"
    }
  ]
}

{
  "time_unix_nano": "1789095663000000000",
  "event.id": "5c4ff065-10be-42a5-aa1c-5511f263d93a",
  "event.name": "tool.call",
  "trace_id": "09e4d05018372f9603644ff32c1af38c",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t2",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "c8a7f2da3dfa2bc0",
  "parent_span_id": "3c7114e9b32ccd29",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t2:s1",
  "gen_ai.tool.name": "Bash",
  "gen_ai.tool.call.id": "toolu_demo_bash_2",
  "gen_ai.tool.call.arguments": {
    "command": "sed -i '' 's/a + b/a - b/' calc.py",
    "description": "Change add to subtract"
  }
}

{
  "time_unix_nano": "1789095670000000000",
  "event.id": "7f317345-168b-4d7e-a608-43e1b174df44",
  "event.name": "tool.result",
  "trace_id": "09e4d05018372f9603644ff32c1af38c",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t2",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "c8a7f2da3dfa2bc0",
  "parent_span_id": "3c7114e9b32ccd29",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t2:s1",
  "gen_ai.tool.name": "Bash",
  "gen_ai.tool.call.id": "toolu_demo_bash_2",
  "gen_ai.tool.call.result": "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.",
  "tool.result.status": "error",
  "error.type": "ToolError",
  "error.message": "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed."
}

{
  "time_unix_nano": "1789095684000000000",
  "event.id": "7c52dc80-740e-4e1d-844c-011f24120663",
  "event.name": "other",
  "trace_id": "e5ff996ee48e7cc37a0ab17b2e5b1aaf",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t3",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "gen_ai.input.messages_delta": [
    {
      "role": "user",
      "parts": [
        {
          "type": "text",
          "content": "别改 add，那是故意留的"
        }
      ]
    }
  ]
}

{
  "time_unix_nano": "1789095684000000000",
  "event.id": "892d5345-4980-420e-927b-8117d3d11f4f",
  "event.name": "llm.request",
  "trace_id": "e5ff996ee48e7cc37a0ab17b2e5b1aaf",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t3",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "d7ab80582218f2ba",
  "parent_span_id": "bb0c44bf634e7cd1",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t3:s1",
  "gen_ai.response.id": "msg_demo_a7db0399",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.input.messages_hash": "c3df22d98f15fd0496faa54e10d7d8e6",
  "gen_ai.input.messages_delta": [
    {
      "role": "user",
      "parts": [
        {
          "type": "text",
          "content": "别改 add，那是故意留的"
        }
      ]
    }
  ]
}

{
  "time_unix_nano": "1789095691000000000",
  "event.id": "72e94227-e450-4331-91a3-c11dae0b8919",
  "event.name": "llm.response",
  "trace_id": "e5ff996ee48e7cc37a0ab17b2e5b1aaf",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t3",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "d7ab80582218f2ba",
  "parent_span_id": "bb0c44bf634e7cd1",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t3:s1",
  "gen_ai.response.id": "msg_demo_a7db0399",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.response.model": "claude-opus-5",
  "gen_ai.response.finish_reasons": [
    "stop"
  ],
  "gen_ai.usage.input_tokens": 1250,
  "gen_ai.usage.output_tokens": 12,
  "gen_ai.usage.cache_read.input_tokens": 1200,
  "gen_ai.usage.cache_creation.input_tokens": 0,
  "gen_ai.usage.total_tokens": 1262,
  "gen_ai.output.messages": [
    {
      "role": "assistant",
      "parts": [
        {
          "type": "text",
          "content": "好的，add 不动。"
        }
      ],
      "finish_reason": "stop"
    }
  ]
}
```

### 2.2 hook 会话状态：`state/claude-code/sessions/11111111-2222-4333-8444-555555555555.json`（实跑）

- **何时写**：每次 `Stop`（以及 `SubagentStart/Stop`）读改写，临时文件 + rename（`claude-code/state.mjs:46-83`）。
- **内容**：transcript 路径、cwd、下次读取的字节 offset、已导出 turn 数。`start_time` 是 Pilot 第一次见到这个 session 的本机时刻，不是会话时间；`prompt`/`model`/`metrics` 是老插件留下的空字段。有子 agent 时还会存 `events` 和 `pending_subagent_turns`（后者存完整事件正文，本例没有子 agent）。
- **保留多久**：永不删除。`src/` 里没有任何代码清理 `state/claude-code/`，保留服务实跑也不碰它（见 §2.1）。

第 1 次 `Stop` 之后：

```json
{
  "session_id": "11111111-2222-4333-8444-555555555555",
  "start_time": 1789106314.311,
  "prompt": "",
  "model": "unknown",
  "transcript_path": "/tmp/demo-home/.claude/projects/-tmp-demo-proj/11111111-2222-4333-8444-555555555555.jsonl",
  "transcript_offset": 7307,
  "metrics": {
    "input_tokens": 0,
    "output_tokens": 0,
    "tools_used": 0,
    "turns": 0
  },
  "tools_used": [],
  "events": [],
  "cwd": "/tmp/demo-proj",
  "stop_time": null,
  "turn_count": 1
}
```

第 2 次 `Stop` 之后（最终）：

```json
{
  "session_id": "11111111-2222-4333-8444-555555555555",
  "start_time": 1789106314.311,
  "prompt": "",
  "model": "unknown",
  "transcript_path": "/tmp/demo-home/.claude/projects/-tmp-demo-proj/11111111-2222-4333-8444-555555555555.jsonl",
  "transcript_offset": 12034,
  "metrics": {
    "input_tokens": 0,
    "output_tokens": 0,
    "tools_used": 0,
    "turns": 0
  },
  "tools_used": [],
  "events": [],
  "cwd": "/tmp/demo-proj",
  "stop_time": null,
  "turn_count": 3
}
```

### 2.3 daemon 规范化输出：`logs/output/claude-code-2026-09-11.jsonl`（实跑，离线加载源码）

**怎么跑的**：用 node v24.14.1 `--experimental-transform-types` 加载 Pilot 源码，按 `orchestrator.ts` 的方式装配 `loadConfig()` → `StateStore(logs/input-state.json)`（`:199`）→ `ClaudeCodeLogInput` → `InputManager`（`:218-223`）→ `buildFlusher()` 在默认配置下的唯一结果 `JsonlFlusher`（`:745-794`），跑一个采集周期。为此在 scratch 里做了三件事：① resolve hook 把 `./x.js` 指到同目录的 `x.ts`；② 仓里缺的 npm 包换成桩：`pino`/`pino-roll`（日志，桩把日志行写到文件）、`uuid`（v4 = `crypto.randomUUID`，v5 按 RFC 4122 实现，与 npm 版结果一致）、`undici`（空壳）、`axios`/`@alicloud/log`/全局 `fetch`（只记录请求、返回 200，不联网）；③ 一处内存补丁：`src/checkpoints/state-store.ts:1` 的 `import { InputState }` 补上 `type`（纯类型导入，tsc 会擦除、node 不会，语义不变）。git 富化是真的调了 `git`。脚本在 `pilot/daemon-sim/`。

- **路径**：`~/.loongsuite-pilot/logs/output/<gen_ai.agent.type>-YYYY-MM-DD.jsonl`（`src/flushers/jsonl-flusher.ts:51-54`）。`jsonl.enabled` 默认 `true`，和配没配远端无关（`config-loader.ts:1148`）。
- **何时写**：daemon 每 30 s 轮询 hook 侧文件里新增的完整行（`src/inputs/claude-code-log/claude-code-log-input.ts:16`，`src/inputs/base/base-hook-input.ts:66-235`），处理完逐条追加。本次一个周期读入 21 条（首次启动：当天的 hook 文件从 0 读起，`base-hook-input.ts:325-332`），输出 24 条。`observed_time_unix_nano` 是模拟运行的时刻，真实运行时约在 `Stop` 后 30 s 内。
- **保留多久**：7 天（`outputDays`；另有单文件 512 MiB / 目录 2 GiB 水位），实跑验证见 §2.1。

经过的处理，按执行顺序：

| # | 步骤 | 出处 | 本例效果 |
|---:|---|---|---|
| 1 | `transformHookRecord`：`{...record}` 整条展开交给 `buildAgentActivityEntry`，统一别名、`finish_reasons` 数组化、`tool.result.status` 归一 | `src/inputs/base/hook-record-transform.ts:20-69`，`src/normalization/entry-builder.ts:73-162,476-497` | `tool.result.status` 由 `error` 变 `failure`；补 `observed_time_unix_nano`；`other`/`tool.*` 补 `gen_ai.provider.name` |
| 2 | git 富化：以 `agent.claude-code.cwd` 为目录跑 `git rev-parse --show-toplevel`、`rev-parse --abbrev-ref HEAD`、`config --get remote.origin.url` | `src/normalization/enrich-git-context.ts:19-35`，`src/utils/git-context.ts:41-64`；`input-manager.ts:333` 再补一遍 | 每条加 `workspace.path`、`workspace.current_root`、`git.repo`、`git.branch`、`git.domain` |
| 3 | 上游 trace 关联（`upstreamLink` 默认关） | `src/core/input-manager.ts:357-363` | 跳过 |
| 4 | 身份：配置里的 `userId` 覆盖记录里的 `user.id` | `src/normalization/invocation-identity.ts:36-55`，`input-manager.ts:365-367` | 仍是 hostname（配置缺省也取 hostname） |
| 5 | turn 边界补全：每个 turn 第一条补 `gen_ai.turn.start`，最后一条 finish_reason 为 stop 类的补 `gen_ai.turn.end` | `src/normalization/turn-boundary-processor.ts:25-75,104-106`，`input-manager.ts:370-377` | t1、t3 有 start/end；**t2（被拒的那轮）只有 start**，它唯一的模型回复 finish_reason 是 `tool_call` |
| 6 | 内容策略 `captureMessageContent`（默认 `true`） | `src/normalization/agent-content-policy.ts:35-56`，`agent-config.ts:4-6` | 不删任何字段 |
| 7 | 脱敏 `mask`（默认 `none`，整步跳过） | `input-manager.ts:384-389`，`config-loader.ts:560-572` | sk-demo 原样 |
| 8 | `expandAgentInputEvents`：每条带 prompt 的 `other` 复制出一条 `agent.input`（`event.id` 由原 id 经 uuid v5 派生） | `src/normalization/agent-input-dual-write.ts:18-43`，`input-manager.ts:391` | +3 条；**prompt 全文在输出里每条 3 份** |
| 9 | `JsonlFlusher`：`projectLogEntry(…, {dropAgentScopedFields: true})`，丢 `agent.<ns>.<x>` 形态字段和旧别名，保留原生 JSON 类型 | `jsonl-flusher.ts:23-29`，`entry-builder.ts:256-279` | 去掉 `agent.claude-code.cwd`（同一路径已在 `workspace.path`） |

与 hook 侧逐条对比（按 `event.id` 对齐，实跑统计）：21 条都新增了 `observed_time_unix_nano`、`workspace.path`、`workspace.current_root`、`git.repo`、`git.branch`、`git.domain`；9 条新增 `gen_ai.provider.name`；3 条新增 `gen_ai.turn.start`、2 条新增 `gen_ai.turn.end`；21 条去掉 `agent.claude-code.cwd`；1 条 `tool.result.status` 改值。内容字段一个字没变。

| # | event.name | turn / step | 边界标记 | 对应 hook 侧 |
|---:|---|---|---|---|
| 1 | other | t1 | turn.start | #1 |
| 2 | agent.input | t1 |  | （daemon 派生，event.id 为 uuid v5） |
| 3 | llm.request | t1 / s1 |  | #2 |
| 4 | llm.response | t1 / s1 |  | #3 |
| 5 | llm.request | t1 / s2 |  | #4 |
| 6 | llm.response | t1 / s2 |  | #5 |
| 7 | tool.call | t1 / s2 |  | #6 |
| 8 | llm.request | t1 / s3 |  | #7 |
| 9 | tool.result | t1 / s2 |  | #8 |
| 10 | llm.response | t1 / s3 |  | #9 |
| 11 | tool.call | t1 / s3 |  | #10 |
| 12 | llm.request | t1 / s4 |  | #11 |
| 13 | tool.result | t1 / s3 |  | #12 |
| 14 | llm.response | t1 / s4 | turn.end | #13 |
| 15 | other | t2 | turn.start | #14 |
| 16 | agent.input | t2 |  | （daemon 派生，event.id 为 uuid v5） |
| 17 | llm.request | t2 / s1 |  | #15 |
| 18 | llm.response | t2 / s1 |  | #16 |
| 19 | tool.call | t2 / s1 |  | #17 |
| 20 | tool.result | t2 / s1 |  | #18 |
| 21 | other | t3 | turn.start | #19 |
| 22 | agent.input | t3 |  | （daemon 派生，event.id 为 uuid v5） |
| 23 | llm.request | t3 / s1 |  | #20 |
| 24 | llm.response | t3 / s1 | turn.end | #21 |

```jsonl
{
  "time_unix_nano": "1789095607000000000",
  "event.id": "b34eb683-3b18-4e26-a767-fffca7269098",
  "event.name": "other",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "gen_ai.input.messages_delta": [
    {
      "role": "user",
      "parts": [
        {
          "type": "text",
          "content": "给 calc.py 的 div 加零检查，然后跑一下测试"
        }
      ]
    }
  ],
  "observed_time_unix_nano": "1789106870121000000",
  "gen_ai.provider.name": "anthropic",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj",
  "gen_ai.turn.start": true
}

{
  "time_unix_nano": "1789095607000000000",
  "event.id": "158c307a-eb38-5a93-9e67-7a18a23ce50d",
  "event.name": "agent.input",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "gen_ai.input.messages_delta": [
    {
      "role": "user",
      "parts": [
        {
          "type": "text",
          "content": "给 calc.py 的 div 加零检查，然后跑一下测试"
        }
      ]
    }
  ],
  "observed_time_unix_nano": "1789106870121000000",
  "gen_ai.provider.name": "anthropic",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095607000000000",
  "event.id": "1aa661d4-20ba-4341-9589-bed313a50993",
  "event.name": "llm.request",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "2c6e3cb61c1781b4",
  "parent_span_id": "46bd8cb637f9e61d",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s1",
  "gen_ai.response.id": "msg_demo_3ff7c188",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.input.messages_hash": "df4bff81f1f4d305652949f54649e6f5",
  "gen_ai.input.messages_delta": [
    {
      "role": "user",
      "parts": [
        {
          "type": "text",
          "content": "给 calc.py 的 div 加零检查，然后跑一下测试"
        }
      ]
    }
  ],
  "observed_time_unix_nano": "1789106870890000000",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095614000000000",
  "event.id": "b1057dc9-451f-470b-8ea6-fbc83c0cd703",
  "event.name": "llm.response",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "2c6e3cb61c1781b4",
  "parent_span_id": "46bd8cb637f9e61d",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s1",
  "gen_ai.response.id": "msg_demo_3ff7c188",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.response.model": "claude-opus-5",
  "gen_ai.response.finish_reasons": [
    "tool_call"
  ],
  "gen_ai.usage.input_tokens": 2100,
  "gen_ai.usage.output_tokens": 40,
  "gen_ai.usage.cache_read.input_tokens": 1200,
  "gen_ai.usage.cache_creation.input_tokens": 0,
  "gen_ai.usage.total_tokens": 2140,
  "gen_ai.output.messages": [
    {
      "role": "assistant",
      "parts": [
        {
          "type": "reasoning",
          "content": "用户要给 div 加零检查。先用 Edit 改 calc.py，再跑 pytest 确认。"
        }
      ],
      "finish_reason": "tool_call"
    }
  ],
  "observed_time_unix_nano": "1789106870891000000",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095614000000000",
  "event.id": "97111fbc-1af0-480b-b578-6d6641e26a11",
  "event.name": "llm.request",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "3993c1c3f7c21c36",
  "parent_span_id": "435dd82377df37b8",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s2",
  "gen_ai.response.id": "msg_demo_398d81be",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.input.messages_hash": "4112c376a2c7ef339466879a37b60034",
  "gen_ai.input.messages_delta": [
    {
      "role": "assistant",
      "parts": [
        {
          "type": "reasoning",
          "content": "用户要给 div 加零检查。先用 Edit 改 calc.py，再跑 pytest 确认。"
        }
      ]
    }
  ],
  "observed_time_unix_nano": "1789106870891000000",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095621000000000",
  "event.id": "72d7b6b2-c576-4d5f-b0f4-e1fb56e07fc7",
  "event.name": "llm.response",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "3993c1c3f7c21c36",
  "parent_span_id": "435dd82377df37b8",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s2",
  "gen_ai.response.id": "msg_demo_398d81be",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.response.model": "claude-opus-5",
  "gen_ai.response.finish_reasons": [
    "tool_call"
  ],
  "gen_ai.usage.input_tokens": 1250,
  "gen_ai.usage.output_tokens": 80,
  "gen_ai.usage.cache_read.input_tokens": 1200,
  "gen_ai.usage.cache_creation.input_tokens": 0,
  "gen_ai.usage.total_tokens": 1330,
  "gen_ai.output.messages": [
    {
      "role": "assistant",
      "parts": [
        {
          "type": "tool_call",
          "id": "toolu_demo_edit_1",
          "name": "Edit",
          "arguments": {
            "file_path": "/tmp/demo-proj/calc.py",
            "old_string": "    return a / b",
            "new_string": "    if b == 0:\n        raise ZeroDivisionError(\"b is 0\")\n    return a / b"
          }
        }
      ],
      "finish_reason": "tool_call"
    }
  ],
  "observed_time_unix_nano": "1789106870891000000",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095621000000000",
  "event.id": "1a11dc84-7410-4527-82de-835b6cba10f0",
  "event.name": "tool.call",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "237b21ec30c08ae4",
  "parent_span_id": "435dd82377df37b8",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s2",
  "gen_ai.tool.name": "Edit",
  "gen_ai.tool.call.id": "toolu_demo_edit_1",
  "gen_ai.tool.call.arguments": {
    "file_path": "/tmp/demo-proj/calc.py",
    "old_string": "    return a / b",
    "new_string": "    if b == 0:\n        raise ZeroDivisionError(\"b is 0\")\n    return a / b"
  },
  "observed_time_unix_nano": "1789106870891000000",
  "gen_ai.provider.name": "anthropic",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095628000000000",
  "event.id": "40b24182-564c-4b2a-8c3b-8e2bdc220f72",
  "event.name": "llm.request",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "a3169be08c6ccd1c",
  "parent_span_id": "e18a336844e2b076",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s3",
  "gen_ai.response.id": "msg_demo_7b11e90c",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.input.messages_hash": "a4a932a40120cbc58c25eb38578d9df6",
  "gen_ai.input.messages_delta": [
    {
      "role": "assistant",
      "parts": [
        {
          "type": "tool_call",
          "id": "toolu_demo_edit_1",
          "name": "Edit",
          "arguments": {
            "file_path": "/tmp/demo-proj/calc.py",
            "old_string": "    return a / b",
            "new_string": "    if b == 0:\n        raise ZeroDivisionError(\"b is 0\")\n    return a / b"
          }
        }
      ]
    },
    {
      "role": "tool",
      "parts": [
        {
          "type": "tool_call_response",
          "id": "toolu_demo_edit_1",
          "response": "The file /tmp/demo-proj/calc.py has been updated successfully."
        }
      ]
    }
  ],
  "observed_time_unix_nano": "1789106870891000000",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095628000000000",
  "event.id": "a0fd0c80-7636-4f63-bced-4ed03899a810",
  "event.name": "tool.result",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "237b21ec30c08ae4",
  "parent_span_id": "435dd82377df37b8",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s2",
  "gen_ai.tool.name": "Edit",
  "gen_ai.tool.call.id": "toolu_demo_edit_1",
  "gen_ai.tool.call.result": "The file /tmp/demo-proj/calc.py has been updated successfully.",
  "tool.result.status": "success",
  "observed_time_unix_nano": "1789106870891000000",
  "gen_ai.provider.name": "anthropic",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095635000000000",
  "event.id": "234f835e-da64-4a7d-872b-c9d6a3e40df0",
  "event.name": "llm.response",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "a3169be08c6ccd1c",
  "parent_span_id": "e18a336844e2b076",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s3",
  "gen_ai.response.id": "msg_demo_7b11e90c",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.response.model": "claude-opus-5",
  "gen_ai.response.finish_reasons": [
    "tool_call"
  ],
  "gen_ai.usage.input_tokens": 1250,
  "gen_ai.usage.output_tokens": 80,
  "gen_ai.usage.cache_read.input_tokens": 1200,
  "gen_ai.usage.cache_creation.input_tokens": 0,
  "gen_ai.usage.total_tokens": 1330,
  "gen_ai.output.messages": [
    {
      "role": "assistant",
      "parts": [
        {
          "type": "tool_call",
          "id": "toolu_demo_bash_1",
          "name": "Bash",
          "arguments": {
            "command": "python3 -m pytest -q",
            "description": "Run tests"
          }
        }
      ],
      "finish_reason": "tool_call"
    }
  ],
  "observed_time_unix_nano": "1789106870891000000",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095635000000000",
  "event.id": "ae2b2150-96f3-4df9-9d75-d922a576551c",
  "event.name": "tool.call",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "6f3d46ee1299f841",
  "parent_span_id": "e18a336844e2b076",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s3",
  "gen_ai.tool.name": "Bash",
  "gen_ai.tool.call.id": "toolu_demo_bash_1",
  "gen_ai.tool.call.arguments": {
    "command": "python3 -m pytest -q",
    "description": "Run tests"
  },
  "observed_time_unix_nano": "1789106870891000000",
  "gen_ai.provider.name": "anthropic",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095642000000000",
  "event.id": "b0b4f373-a8f8-4f15-8bd7-0685c8dbe1a8",
  "event.name": "llm.request",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "03adf78ba863c5fd",
  "parent_span_id": "fcf7407adb384258",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s4",
  "gen_ai.response.id": "msg_demo_f3215ee5",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.input.messages_hash": "2eed387e1a094f027162e2a9c48f81b6",
  "gen_ai.input.messages_delta": [
    {
      "role": "assistant",
      "parts": [
        {
          "type": "tool_call",
          "id": "toolu_demo_bash_1",
          "name": "Bash",
          "arguments": {
            "command": "python3 -m pytest -q",
            "description": "Run tests"
          }
        }
      ]
    },
    {
      "role": "tool",
      "parts": [
        {
          "type": "tool_call_response",
          "id": "toolu_demo_bash_1",
          "response": "...\n3 passed in 0.02s\n(debug) OPENAI_API_KEY=sk-demo-1234567890abcdef1234"
        }
      ]
    }
  ],
  "observed_time_unix_nano": "1789106870891000000",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095642000000000",
  "event.id": "5b22e5b6-3b21-4a9e-8f3a-b09dc38e2767",
  "event.name": "tool.result",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "6f3d46ee1299f841",
  "parent_span_id": "e18a336844e2b076",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s3",
  "gen_ai.tool.name": "Bash",
  "gen_ai.tool.call.id": "toolu_demo_bash_1",
  "gen_ai.tool.call.result": "...\n3 passed in 0.02s\n(debug) OPENAI_API_KEY=sk-demo-1234567890abcdef1234",
  "tool.result.status": "success",
  "observed_time_unix_nano": "1789106870891000000",
  "gen_ai.provider.name": "anthropic",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095649000000000",
  "event.id": "4258c966-3e20-43be-b218-03503ee785aa",
  "event.name": "llm.response",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "03adf78ba863c5fd",
  "parent_span_id": "fcf7407adb384258",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s4",
  "gen_ai.response.id": "msg_demo_f3215ee5",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.response.model": "claude-opus-5",
  "gen_ai.response.finish_reasons": [
    "stop"
  ],
  "gen_ai.usage.input_tokens": 1250,
  "gen_ai.usage.output_tokens": 30,
  "gen_ai.usage.cache_read.input_tokens": 1200,
  "gen_ai.usage.cache_creation.input_tokens": 0,
  "gen_ai.usage.total_tokens": 1280,
  "gen_ai.output.messages": [
    {
      "role": "assistant",
      "parts": [
        {
          "type": "text",
          "content": "改好了：div 在 b 为 0 时抛 ZeroDivisionError，3 个测试都通过。"
        }
      ],
      "finish_reason": "stop"
    }
  ],
  "observed_time_unix_nano": "1789106870891000000",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj",
  "gen_ai.turn.end": true
}

{
  "time_unix_nano": "1789095656000000000",
  "event.id": "1fed439d-f743-4038-9eb3-5d0e0b79c598",
  "event.name": "other",
  "trace_id": "09e4d05018372f9603644ff32c1af38c",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t2",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "gen_ai.input.messages_delta": [
    {
      "role": "user",
      "parts": [
        {
          "type": "text",
          "content": "顺便把 add 改成减法"
        }
      ]
    }
  ],
  "observed_time_unix_nano": "1789106870891000000",
  "gen_ai.provider.name": "anthropic",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj",
  "gen_ai.turn.start": true
}

{
  "time_unix_nano": "1789095656000000000",
  "event.id": "b9a6d8b2-5885-53b2-ba9a-64368d8da483",
  "event.name": "agent.input",
  "trace_id": "09e4d05018372f9603644ff32c1af38c",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t2",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "gen_ai.input.messages_delta": [
    {
      "role": "user",
      "parts": [
        {
          "type": "text",
          "content": "顺便把 add 改成减法"
        }
      ]
    }
  ],
  "observed_time_unix_nano": "1789106870891000000",
  "gen_ai.provider.name": "anthropic",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095656000000000",
  "event.id": "e27398c1-a634-468b-a060-79beb489259d",
  "event.name": "llm.request",
  "trace_id": "09e4d05018372f9603644ff32c1af38c",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t2",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "fcf9bde4522918d1",
  "parent_span_id": "3c7114e9b32ccd29",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t2:s1",
  "gen_ai.response.id": "msg_demo_16a3091b",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.input.messages_hash": "9a06cb2eec2f00b760d3236791207557",
  "gen_ai.input.messages_delta": [
    {
      "role": "user",
      "parts": [
        {
          "type": "text",
          "content": "顺便把 add 改成减法"
        }
      ]
    }
  ],
  "observed_time_unix_nano": "1789106870891000000",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095663000000000",
  "event.id": "d22efdbd-fb82-46da-8c82-983bd0f064ca",
  "event.name": "llm.response",
  "trace_id": "09e4d05018372f9603644ff32c1af38c",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t2",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "fcf9bde4522918d1",
  "parent_span_id": "3c7114e9b32ccd29",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t2:s1",
  "gen_ai.response.id": "msg_demo_16a3091b",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.response.model": "claude-opus-5",
  "gen_ai.response.finish_reasons": [
    "tool_call"
  ],
  "gen_ai.usage.input_tokens": 1250,
  "gen_ai.usage.output_tokens": 80,
  "gen_ai.usage.cache_read.input_tokens": 1200,
  "gen_ai.usage.cache_creation.input_tokens": 0,
  "gen_ai.usage.total_tokens": 1330,
  "gen_ai.output.messages": [
    {
      "role": "assistant",
      "parts": [
        {
          "type": "tool_call",
          "id": "toolu_demo_bash_2",
          "name": "Bash",
          "arguments": {
            "command": "sed -i '' 's/a + b/a - b/' calc.py",
            "description": "Change add to subtract"
          }
        }
      ],
      "finish_reason": "tool_call"
    }
  ],
  "observed_time_unix_nano": "1789106870891000000",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095663000000000",
  "event.id": "5c4ff065-10be-42a5-aa1c-5511f263d93a",
  "event.name": "tool.call",
  "trace_id": "09e4d05018372f9603644ff32c1af38c",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t2",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "c8a7f2da3dfa2bc0",
  "parent_span_id": "3c7114e9b32ccd29",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t2:s1",
  "gen_ai.tool.name": "Bash",
  "gen_ai.tool.call.id": "toolu_demo_bash_2",
  "gen_ai.tool.call.arguments": {
    "command": "sed -i '' 's/a + b/a - b/' calc.py",
    "description": "Change add to subtract"
  },
  "observed_time_unix_nano": "1789106870891000000",
  "gen_ai.provider.name": "anthropic",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095670000000000",
  "event.id": "7f317345-168b-4d7e-a608-43e1b174df44",
  "event.name": "tool.result",
  "trace_id": "09e4d05018372f9603644ff32c1af38c",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t2",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "c8a7f2da3dfa2bc0",
  "parent_span_id": "3c7114e9b32ccd29",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t2:s1",
  "gen_ai.tool.name": "Bash",
  "gen_ai.tool.call.id": "toolu_demo_bash_2",
  "gen_ai.tool.call.result": "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.",
  "tool.result.status": "failure",
  "error.type": "ToolError",
  "error.message": "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.",
  "observed_time_unix_nano": "1789106870892000000",
  "gen_ai.provider.name": "anthropic",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095684000000000",
  "event.id": "7c52dc80-740e-4e1d-844c-011f24120663",
  "event.name": "other",
  "trace_id": "e5ff996ee48e7cc37a0ab17b2e5b1aaf",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t3",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "gen_ai.input.messages_delta": [
    {
      "role": "user",
      "parts": [
        {
          "type": "text",
          "content": "别改 add，那是故意留的"
        }
      ]
    }
  ],
  "observed_time_unix_nano": "1789106870892000000",
  "gen_ai.provider.name": "anthropic",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj",
  "gen_ai.turn.start": true
}

{
  "time_unix_nano": "1789095684000000000",
  "event.id": "91e0d074-6e03-5836-ae63-c72f8b9b1fec",
  "event.name": "agent.input",
  "trace_id": "e5ff996ee48e7cc37a0ab17b2e5b1aaf",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t3",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "gen_ai.input.messages_delta": [
    {
      "role": "user",
      "parts": [
        {
          "type": "text",
          "content": "别改 add，那是故意留的"
        }
      ]
    }
  ],
  "observed_time_unix_nano": "1789106870892000000",
  "gen_ai.provider.name": "anthropic",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095684000000000",
  "event.id": "892d5345-4980-420e-927b-8117d3d11f4f",
  "event.name": "llm.request",
  "trace_id": "e5ff996ee48e7cc37a0ab17b2e5b1aaf",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t3",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "d7ab80582218f2ba",
  "parent_span_id": "bb0c44bf634e7cd1",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t3:s1",
  "gen_ai.response.id": "msg_demo_a7db0399",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.input.messages_hash": "c3df22d98f15fd0496faa54e10d7d8e6",
  "gen_ai.input.messages_delta": [
    {
      "role": "user",
      "parts": [
        {
          "type": "text",
          "content": "别改 add，那是故意留的"
        }
      ]
    }
  ],
  "observed_time_unix_nano": "1789106870892000000",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095691000000000",
  "event.id": "72e94227-e450-4331-91a3-c11dae0b8919",
  "event.name": "llm.response",
  "trace_id": "e5ff996ee48e7cc37a0ab17b2e5b1aaf",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t3",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "d7ab80582218f2ba",
  "parent_span_id": "bb0c44bf634e7cd1",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t3:s1",
  "gen_ai.response.id": "msg_demo_a7db0399",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.response.model": "claude-opus-5",
  "gen_ai.response.finish_reasons": [
    "stop"
  ],
  "gen_ai.usage.input_tokens": 1250,
  "gen_ai.usage.output_tokens": 12,
  "gen_ai.usage.cache_read.input_tokens": 1200,
  "gen_ai.usage.cache_creation.input_tokens": 0,
  "gen_ai.usage.total_tokens": 1262,
  "gen_ai.output.messages": [
    {
      "role": "assistant",
      "parts": [
        {
          "type": "text",
          "content": "好的，add 不动。"
        }
      ],
      "finish_reason": "stop"
    }
  ],
  "observed_time_unix_nano": "1789106870892000000",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj",
  "gen_ai.turn.end": true
}
```

同一周期里 daemon 自己打的日志（桩按 pino 的 msg + meta 记下的同一批日志行；真实文件是 `logs/loongsuite-pilot-service.log`，pino-roll 按天滚动、保留 10 个，`src/index.ts:56`，`src/utils/logger.ts:54-83`）——只有计数，没有内容：

```jsonl
{"level":"INFO","time":"2026-09-11T06:07:50.109Z","tag":"ConfigLoader","msg":"loaded config file","path":"/tmp/demo-home/.loongsuite-pilot/config.json"}
{"level":"INFO","time":"2026-09-11T06:07:50.118Z","tag":"InputManager","msg":"input registered","id":"claude-code-log"}
{"level":"INFO","time":"2026-09-11T06:07:50.119Z","tag":"ClaudeCodeLogInput","msg":"starting"}
{"level":"INFO","time":"2026-09-11T06:07:50.895Z","tag":"InputManager","msg":"dispatching entries","inputId":"claude-code-log","count":24}
{"level":"INFO","time":"2026-09-11T06:07:50.897Z","tag":"InputManager","msg":"input started","id":"claude-code-log"}
{"level":"INFO","time":"2026-09-11T06:07:50.897Z","tag":"ClaudeCodeLogInput","msg":"stopped"}
{"level":"INFO","time":"2026-09-11T06:07:50.902Z","tag":"InputManager","msg":"input stopped","id":"claude-code-log"}
```

### 2.4 daemon 输入偏移：`logs/input-state.json`（实跑）

每个轮询周期后覆盖写（`src/inputs/base/base-input.ts:111`，`base-hook-input.ts:95-109`），保留服务不清理。

```json
{
  "claude-code-log": {
    "lastFile": "claude-code-2026-09-11.jsonl",
    "lastOffset": 24186,
    "extra": {
      "hookLogOffsets": {
        "claude-code-2026-09-11.jsonl": 24186
      }
    }
  }
}
```

### 2.5 fetch 拦截文件：`intercept/claude-code/<session_id>/<response_id>.json`（补充实跑 B）

- **怎么来的**：安装器选中 claude-code 且找得到 `claude` 命令时，往 `$SHELL` 对应的 rc 文件写一个覆盖 `claude` 的函数，启动时加 `BUN_OPTIONS=--preload=…/hooks/claude-code-fetch-intercept.mjs`（`deploy/installer-opensource.sh:1565-1631`）。从交互 shell 启动的 Claude Code，每次调 `/v1/messages` 都经过它。scenario 没有 API 请求，所以主回放没有这一路；补充轮在每条 assistant 记录追加之前，用假 `fetch`（不联网，返回构造的 SSE：`message_start` 带真实的 `message.id`，300 ms 后给第一个 delta）驱动**真实的**拦截器文件发一次请求。请求 `system` 字段是占位文本；真实请求里是 Claude Code 的整份系统提示词，拦截器注释自估每个文件最坏约 27 KB（`claude-code-fetch-intercept.mjs:118`）。
- **何时写**：每次 LLM 调用一个文件，请求头带 `x-claude-code-session-id` 才写（`claude-code-fetch-intercept.mjs:163-182,203-212`）。
- **保留多久**：`Stop` 合并进事件后立即删（`:208-214,917-918`）；没合并上的，等同一 session 下次 `Stop` 时删掉 mtime 超过 1 小时的（`:222-235`）；session 不再有 `Stop` 就一直留着，保留服务不管这个目录（§2.1 实跑）。
- 拦截器不读任何配置，内容开关关掉也照写（§2.6 实跑）。

第 1 次 `Stop` 之前，目录里有：

```text
intercept/claude-code/11111111-2222-4333-8444-555555555555/msg_demo_398d81be.json  (263 B)
intercept/claude-code/11111111-2222-4333-8444-555555555555/msg_demo_3ff7c188.json  (263 B)
intercept/claude-code/11111111-2222-4333-8444-555555555555/msg_demo_7b11e90c.json  (263 B)
intercept/claude-code/11111111-2222-4333-8444-555555555555/msg_demo_f3215ee5.json  (263 B)
```

其中一个文件：

```json
{
  "session_id": "11111111-2222-4333-8444-555555555555",
  "response_id": "msg_demo_3ff7c188",
  "ttft_ns": 323127208,
  "system_instructions": [
    {
      "type": "text",
      "content": "<Claude Code 系统提示词全文（此处为示例占位，真实请求里是整份 system prompt）>"
    }
  ]
}
```

`Stop` 合并后，hook 侧对应的 `llm.request` / `llm.response`（这是另一轮回放，随机生成的 id 与 §2.1 不同；除此之外与 §2.1 的 #2、#3 相比，只多了最后一个字段）：

```jsonl
{
  "time_unix_nano": "1789095607000000000",
  "event.id": "835b8c1a-9548-426a-9369-12cb9ab61d3c",
  "event.name": "llm.request",
  "trace_id": "fb4c6b6c636c531019ca1e0c94102758",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "29c4d6ec04ad384e",
  "parent_span_id": "4807b4df8f2f0fa8",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s1",
  "gen_ai.response.id": "msg_demo_3ff7c188",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.input.messages_hash": "df4bff81f1f4d305652949f54649e6f5",
  "gen_ai.input.messages_delta": [
    {
      "role": "user",
      "parts": [
        {
          "type": "text",
          "content": "给 calc.py 的 div 加零检查，然后跑一下测试"
        }
      ]
    }
  ],
  "gen_ai.system_instructions": [
    {
      "type": "text",
      "content": "<Claude Code 系统提示词全文（此处为示例占位，真实请求里是整份 system prompt）>"
    }
  ]
}

{
  "time_unix_nano": "1789095614000000000",
  "event.id": "b2b9c7a7-46d5-46ce-81a0-55c278a5e6fc",
  "event.name": "llm.response",
  "trace_id": "fb4c6b6c636c531019ca1e0c94102758",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "29c4d6ec04ad384e",
  "parent_span_id": "4807b4df8f2f0fa8",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s1",
  "gen_ai.response.id": "msg_demo_3ff7c188",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.response.model": "claude-opus-5",
  "gen_ai.response.finish_reasons": [
    "tool_call"
  ],
  "gen_ai.usage.input_tokens": 2100,
  "gen_ai.usage.output_tokens": 40,
  "gen_ai.usage.cache_read.input_tokens": 1200,
  "gen_ai.usage.cache_creation.input_tokens": 0,
  "gen_ai.usage.total_tokens": 2140,
  "gen_ai.output.messages": [
    {
      "role": "assistant",
      "parts": [
        {
          "type": "reasoning",
          "content": "用户要给 div 加零检查。先用 Edit 改 calc.py，再跑 pytest 确认。"
        }
      ],
      "finish_reason": "tool_call"
    }
  ],
  "gen_ai.response.time_to_first_token": 323127208
}
```

要点：计费头那块被滤掉（`claude-code-fetch-intercept.mjs:60`）；**每一次** LLM 调用的 `llm.request` 都带一份完整 `gen_ai.system_instructions`，本例 6 次调用就是 6 份；`llm.response` 多出 `gen_ai.response.time_to_first_token`（这里约 3×10⁸ ns，是假流的 300 ms 延迟造出来的）。两个字段都会进 daemon 输出：在补充轮 B 的数据上再跑一遍 daemon 链（实跑），输出里 6 条 `llm.request` 都带 `gen_ai.system_instructions`、6 条 `llm.response` 都带 TTFT（`hook-record-transform.ts:65` 显式透传前者）；配了远端就随事件出去。

### 2.6 关掉内容采集时本机还剩什么（补充实跑 C）

同样的回放（带拦截器），配置改为：

```json
{
  "enabled": true,
  "dataDir": "/tmp/demo-home/.loongsuite-pilot",
  "dashboard": {
    "port": 8765
  },
  "agents": {
    "claude-code": {
      "enabled": true,
      "captureMessageContent": false
    }
  }
}
```

结果 hook 侧 21 条、daemon 输出 21 条。hook 侧节选（`other`、`llm.request`、一条 `tool.call`、被拒的 `tool.result`）：

```jsonl
{
  "time_unix_nano": "1789095607000000000",
  "event.id": "e26d6519-df67-4932-ac80-472172cc2fab",
  "event.name": "other",
  "trace_id": "4824f0a28de7ba61d81ecad749aa63de",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095607000000000",
  "event.id": "16ca3f72-49cd-4610-84c4-87c4cbd1c0de",
  "event.name": "llm.request",
  "trace_id": "4824f0a28de7ba61d81ecad749aa63de",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "1ece7a62c565ed99",
  "parent_span_id": "14311ef4c4fc5729",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s1",
  "gen_ai.response.id": "msg_demo_3ff7c188",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.input.messages_hash": "df4bff81f1f4d305652949f54649e6f5",
  "gen_ai.system_instructions": [
    {
      "type": "text"
    }
  ]
}

{
  "time_unix_nano": "1789095635000000000",
  "event.id": "76924fd0-900d-470f-adf6-61d07953b903",
  "event.name": "tool.call",
  "trace_id": "4824f0a28de7ba61d81ecad749aa63de",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "05661d657502d903",
  "parent_span_id": "6c2b0a38e5617a9c",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s3",
  "gen_ai.tool.name": "Bash",
  "gen_ai.tool.call.id": "toolu_demo_bash_1"
}

{
  "time_unix_nano": "1789095670000000000",
  "event.id": "19cfd9e2-52ad-42ff-a55f-9d024e7cd7cb",
  "event.name": "tool.result",
  "trace_id": "188cc0588a724bddc4a392d8cfd89e40",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t2",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "a19cbc67fe8c93e7",
  "parent_span_id": "46535cac0fe41443",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t2:s1",
  "gen_ai.tool.name": "Bash",
  "gen_ai.tool.call.id": "toolu_demo_bash_2",
  "tool.result.status": "error",
  "error.type": "ToolError",
  "error.message": "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed."
}
```

daemon 输出节选：

```jsonl
{
  "time_unix_nano": "1789095607000000000",
  "event.id": "e26d6519-df67-4932-ac80-472172cc2fab",
  "event.name": "other",
  "trace_id": "4824f0a28de7ba61d81ecad749aa63de",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "observed_time_unix_nano": "1789107700362000000",
  "gen_ai.provider.name": "anthropic",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj",
  "gen_ai.turn.start": true
}

{
  "time_unix_nano": "1789095607000000000",
  "event.id": "16ca3f72-49cd-4610-84c4-87c4cbd1c0de",
  "event.name": "llm.request",
  "trace_id": "4824f0a28de7ba61d81ecad749aa63de",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "1ece7a62c565ed99",
  "parent_span_id": "14311ef4c4fc5729",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s1",
  "gen_ai.response.id": "msg_demo_3ff7c188",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.input.messages_hash": "df4bff81f1f4d305652949f54649e6f5",
  "observed_time_unix_nano": "1789107700914000000",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095670000000000",
  "event.id": "19cfd9e2-52ad-42ff-a55f-9d024e7cd7cb",
  "event.name": "tool.result",
  "trace_id": "188cc0588a724bddc4a392d8cfd89e40",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t2",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "a19cbc67fe8c93e7",
  "parent_span_id": "46535cac0fe41443",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t2:s1",
  "gen_ai.tool.name": "Bash",
  "gen_ai.tool.call.id": "toolu_demo_bash_2",
  "tool.result.status": "failure",
  "error.type": "ToolError",
  "error.message": "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.",
  "observed_time_unix_nano": "1789107700915000000",
  "gen_ai.provider.name": "anthropic",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}
```

要点：

- 删掉的：prompt、模型输出（含 thinking）、输入增量、工具参数、工具结果（hook 侧 `agent-event-normalizer.mjs:310-342`，daemon 侧 `agent-content-policy.ts:35-56`）。
- 留下的：时间戳、各种 id、工具名、模型名、token、TTFT、`tool.result.status`、cwd、`user.id`；daemon 输出还有 `git.*`、`workspace.*`。
- **被拒调用的 `error.message` 仍是拒绝提示全文**，hook 侧和输出都在——两份内容字段清单都不含 `error.message`。
- hook 侧 `llm.request` 仍留着键 `gen_ai.system_instructions: [{"type":"text"}]`（嵌套的 `content` 被删、键还在）；daemon 输出里整键删掉。
- 拦截文件照样写入 system prompt 全文，直到 `Stop` 合并时才被丢弃。
- `other` 里的 prompt 删掉后不再派生 `agent.input`，所以输出 21 条。

### 2.7 本次没触发、但默认安装会写的其他本机文件（按源码推演）

| 路径 | 内容 | 何时 | 保留 | 出处 |
|---|---|---|---|---|
| `~/.loongsuite-pilot/logs/claude-code/errors/claude-code-error-YYYY-MM-DD.jsonl` | hook 失败记录：阶段、错误类型、错误信息，不含事件正文 | hook 出错时 | 7 天 | `shared/error-logger.mjs:39-55`，`claude-code-loongsuite-pilot-hook.sh:29-45` |
| `~/.loongsuite-pilot/acp-correlate/<sid>.jsonl` 等 | 上游 trace 关联记录 | Claude Code 进程环境里有合法 `TRACEPARENT`，或开了 `upstreamLink` | 清理服务只在 `upstreamLink` 开时运行 | `shared/upstream-context.mjs:41-61`，`claude-code/tool-context.mjs` |
| `~/.loongsuite-pilot/logs/metric_alarm/pilot-metrics-YYYY-MM-DD.jsonl` | daemon L1 指标：`hostname`、`ip`、`user_id`、`instance_id`（hostname + userId + 数据目录的 base64url，可逆）、`os_detail`、版本、CPU/内存、当期事件与字节计数 | 启动时 + 每 10 分钟 | 7 天 | `src/metrics/metrics-writer.ts:17,157-185`，`src/metrics/metrics-collector.ts:494-500,510-590` |
| `~/.loongsuite-pilot/logs/metric_alarm/pilot-{agent,input,flusher}-metrics-*.jsonl`、`pilot-alarms-*.jsonl` | 按 agent / 输入 / 输出拆开的计数，告警 | 每 10 分钟 / 30 秒 | 7 天 | `metrics-writer.ts:455-506` |
| `~/.loongsuite-pilot/logs/metrics-summary.json`、`cache/metrics-*.json` | 本地看板用的聚合：token、会话数、模型占比、按 `git.repo` 的会话数与事件数；`cache` 里存 session id 列表 | 定时 | 覆盖写 | `src/status-bar/metrics-summary-writer.ts:173-176,443-470` |
| `~/.loongsuite-pilot/logs/loongsuite-pilot-service.log` | daemon 运行日志（本例只有 §2.3 那种计数行） | 持续 | pino-roll 保留 10 个 | `src/index.ts:56`，`src/utils/logger.ts:54-83` |
| `~/.claude/settings.json` 的 `hooks` | 4 条注册项，命令形如 `…/.loongsuite-pilot/hooks/claude-code-loongsuite-pilot-hook.sh stop` | 部署时、watchdog 修复时 | 卸载时移除 | `agents.d/claude-code.json:9-28`，`src/deployment/hook-strategy.ts` |
| `~/.zshrc`（`$SHELL` 为 bash 等时是 `~/.bashrc`）里的 `loongsuite-pilot BEGIN claude-code-intercept` 块 | 覆盖 `claude` 命令、挂上拦截器 | 安装时；watchdog 发现缺失会补 | 卸载或把该 agent 关掉 | `deploy/installer-opensource.sh:1565-1631`，`src/core/hook-watchdog.ts:863-928` |

## 3. 出本机的内容

### 3.1 默认安装：会话内容不出本机，运行状态回传出去

- **会话内容：不发**（实跑确认配置，按源码确认装配）。`loadConfig()` 实跑结果里 `flushers.sls.enabled=false`（没有 project/logstore 就没有端点，`config-loader.ts:991-1009,1034-1042`）、`flushers.http.enabled=false`（没有 url，`:1157-1178`）、没有 OTLP/CMS 端点；`buildFlusher()` 于是只建 `JsonlFlusher`（`orchestrator.ts:745-794`）。hook 脚本、处理器、拦截器里都没有发网络的代码，拦截器只透传 Claude Code 自己的请求。
- 托管配置 `~/.loongsuite-pilot/configs/inner/data_config.json` 如果存在，会追加 SLS 与 trace 端点（`config-loader.ts:271-272,1011-1023`）。开源仓里没有任何代码写这个文件（注释说是控制面下发，`:789`），默认安装不存在。
- **例外：运行状态回传，默认开、没有开关**（按源码推演，没有执行）。daemon 每次启动发一条，之后每 72 个 10 分钟周期即 12 小时发一条（`src/internal/statistic.ts:9-10,23-26`，`metrics-writer.ts:17,113,176-177`）；开源构建用的就是这份实现（`src/internal/sender.ts:13-18`）。按源码构造的报文如下，值为示意：

```text
POST https://loongsuite-community-edition.cn-shanghai.log.aliyuncs.com/logstores/loongsuite-online/track
x-log-apiversion: 0.6.0
x-log-bodyrawsize: <body 字节数>
Content-Type: application/json
```

```json
{
  "__topic__": "pilot_running_status",
  "__logs__": [
    {
      "cpu": "<CPU 百分比>",
      "mem": "<RSS MB>",
      "version": "<已安装版本>",
      "instance_id": "<本机hostname>_<本机hostname>_<数据目录绝对路径的 base64url>",
      "ip": "<本机IP>",
      "hostname": "<本机hostname>",
      "os_detail": "Darwin; 22.1.0; arm64",
      "metric_json": "{\"agent_count\":\"…\",\"active_agent_count\":\"…\",\"open_fd\":\"…\",\"window_ms\":\"…\",\"in_events\":\"…\",\"in_bytes\":\"…\",\"out_events\":\"…\",\"out_bytes\":\"…\",\"in_events_ps\":\"…\",…,\"disk_data_bytes\":\"…\",\"disk_logs_bytes\":\"…\"}"
    }
  ]
}
```

字段只取这 8 个（`statistic.ts:12-21`），值都转成字符串（`src/utils/record-utils.ts:1-8`）。`instance_id` 的第二段是 `user.id`，默认即 hostname；第三段解码就是数据目录路径，里面有系统用户名（`metrics-collector.ts:494-500`）。**不含任何会话内容**，但 `metric_json` 里的 `in_events`/`in_bytes`/`out_events`/`out_bytes` 是发送当期那个 10 分钟窗口的计数（`metrics-collector.ts:520-575`）：如果回传恰好落在处理这段会话的窗口里，会报出 21 条输入、24 条输出这一级别的数字（本次 `InputManager` 实跑计数：`inEvents 21`、`inBytes 36137`、`outEvents 24`）。

### 3.2 配了 SLS 时（实跑 `SlsFlusher`，传输层截获）

假设用户这样配（安装时只给 endpoint/project/logstore、不给密钥，写出来就是 webtracking 模式，`installer-opensource.sh:1057-1060`）：

```json
{
  "enabled": true,
  "dataDir": "<scratch>/daemon-sim/outbound-datadir",
  "dashboard": { "port": 8765 },
  "agents": { "claude-code": { "enabled": true } },
  "sls": { "mode": "webtracking", "endpoint": "https://cn-hangzhou.log.aliyuncs.com", "project": "demo-agent-obs", "logstore": "agent-activity" }
}
```

真实的 `loadConfig()` 得到 `enabled: true`、`mode: webtracking`、`kind: agentActivity`、`redact: false`。把 §2.3 那 24 条（`InputManager` 交给 flusher 的同一批对象）交给真实的 `SlsFlusher`，截获的请求：

```text
请求 1: POST https://demo-agent-obs.cn-hangzhou.log.aliyuncs.com/logstores/agent-activity/track  body 30803 B，__logs__ 20 条
请求 2: POST https://demo-agent-obs.cn-hangzhou.log.aliyuncs.com/logstores/agent-activity/track  body 5551 B，__logs__ 4 条
```

URL 与请求头：

```json
{
  "url": "https://demo-agent-obs.cn-hangzhou.log.aliyuncs.com/logstores/agent-activity/track",
  "method": "POST",
  "headers": {
    "x-log-apiversion": "0.6.0",
    "x-log-bodyrawsize": "30803",
    "Content-Type": "application/json",
    "user-agent": "loongsuite-pilot/1.2.0 (Darwin; 22.1.0; arm64) ip/<本机IP>"
  }
}
```

信封：

```json
{
  "__topic__": "agentActivity",
  "__source__": "<本机IP>",
  "__tags__": {
    "__hostname__": "<本机hostname>",
    "__service_name__": "loongsuite-pilot-claude-code"
  },
  "__logs__": "[…20 条，见下]"
}
```

`__logs__` 三条样例（`other`、带 sk-demo 的 `llm.request`、被拒的 `tool.result`）：

```jsonl
{
  "time_unix_nano": "1789095607000000000",
  "event.id": "b34eb683-3b18-4e26-a767-fffca7269098",
  "event.name": "other",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "gen_ai.input.messages_delta": "[{\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"content\":\"给 calc.py 的 div 加零检查，然后跑一下测试\"}]}]",
  "observed_time_unix_nano": "1789106870121000000",
  "gen_ai.provider.name": "anthropic",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj",
  "gen_ai.turn.start": "true",
  "version": "1.2.0"
}

{
  "time_unix_nano": "1789095642000000000",
  "event.id": "b0b4f373-a8f8-4f15-8bd7-0685c8dbe1a8",
  "event.name": "llm.request",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "03adf78ba863c5fd",
  "parent_span_id": "fcf7407adb384258",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s4",
  "gen_ai.response.id": "msg_demo_f3215ee5",
  "gen_ai.provider.name": "anthropic",
  "gen_ai.request.model": "claude-opus-5",
  "gen_ai.input.messages_hash": "2eed387e1a094f027162e2a9c48f81b6",
  "gen_ai.input.messages_delta": "[{\"role\":\"assistant\",\"parts\":[{\"type\":\"tool_call\",\"id\":\"toolu_demo_bash_1\",\"name\":\"Bash\",\"arguments\":{\"command\":\"python3 -m pytest -q\",\"description\":\"Run tests\"}}]},{\"role\":\"tool\",\"parts\":[{\"type\":\"tool_call_response\",\"id\":\"toolu_demo_bash_1\",\"response\":\"...\\n3 passed in 0.02s\\n(debug) OPENAI_API_KEY=sk-demo-1234567890abcdef1234\"}]}]",
  "observed_time_unix_nano": "1789106870891000000",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj",
  "version": "1.2.0"
}

{
  "time_unix_nano": "1789095670000000000",
  "event.id": "7f317345-168b-4d7e-a608-43e1b174df44",
  "event.name": "tool.result",
  "trace_id": "09e4d05018372f9603644ff32c1af38c",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t2",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "span_id": "c8a7f2da3dfa2bc0",
  "parent_span_id": "3c7114e9b32ccd29",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t2:s1",
  "gen_ai.tool.name": "Bash",
  "gen_ai.tool.call.id": "toolu_demo_bash_2",
  "gen_ai.tool.call.result": "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.",
  "tool.result.status": "failure",
  "error.type": "ToolError",
  "error.message": "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.",
  "observed_time_unix_nano": "1789106870892000000",
  "gen_ai.provider.name": "anthropic",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj",
  "version": "1.2.0"
}
```

与本机 JSONL 的差别：

- **每个值都转成字符串**：数组/对象 `JSON.stringify`，数字、布尔变字符串（`entry-builder.ts:281-292,378-382`）。每条多一个 `version`（`src/flushers/sls-flusher.ts:206`）。同样丢 `agent.<ns>.<x>` 字段（`:205`）。
- **信封带本机身份**：`__source__` 是本机 IP，`__tags__.__hostname__` 是 hostname（`:35,317-322,517-525`），`user-agent` 末尾 `ip/<本机IP>`（`src/utils/network-utils.ts:18-21`）；`__service_name__` = `loongsuite-pilot-claude-code`。
- **内容字段全部原样出去**：出站兜底 `redactCodeGenerationFields` 只在 `endpoint.redact` 为真时调用（`sls-flusher.ts:210-212`），而 `redact` 在配置加载时被写死为 `false`（`config-loader.ts:951,1091`）。
- **批量**：每个 endpoint×agent 桶满 20 条立即发，否则 2 s 定时发（`sls-flusher.ts:37-38,694-720`）。本次一次交给它 24 条，所以是 20 + 4 两个请求；真实运行时按两次 `Stop` 的节奏，大致是 14 条、10 条各一批。
- **AK / apiKey 模式**（按源码推演）：同一份字符串 map 装进 protobuf LogGroup（`src/flushers/sls-loggroup-codec.ts:14-29`），`Source` = 本机 IP、`Topic` = `agentActivity`，LogTag 同上。apiKey 模式 `POST https://<project>.<endpoint>/logstores/<logstore>/shards/lb`，头带 `Authorization: Bearer <apiKey>`（`src/flushers/sls-transport.ts:111-133`）；AK 模式走 `@alicloud/log` 的 `postLogStoreLogs`（`sls-flusher.ts:331-352`）。
- **如果用户打开脱敏**（补充实跑 D：`mask.mode: "all"`，整条 daemon 链重跑）：两处 sk-demo 变成 `[APIKEY_MASKED]`（规则 `apiKey.openaiCompatible`，`src/mask/sensitive-rules.json:32-37`），其余字段不变。mask 在 flusher 之前执行，所以本机 JSONL 和出站同时生效；**hook 侧那份本机文件始终是明文**。mask 只扫内容类字段（`src/mask/field-whitelist.ts:1-35`），`workspace.*`、`git.*` 不扫。

```json
{
  "gen_ai.tool.call.result": "...\n3 passed in 0.02s\n(debug) OPENAI_API_KEY=[APIKEY_MASKED]"
}
```

### 3.3 配了 HTTP 时（实跑 `HttpFlusher`，axios 截获）

假设配置：

```json
{
  "enabled": true,
  "dataDir": "<scratch>/daemon-sim/outbound-datadir",
  "dashboard": { "port": 8765 },
  "agents": { "claude-code": { "enabled": true } },
  "http": { "url": "https://collector.example.com/ingest", "headers": { "Authorization": "Bearer <demo-token>" } }
}
```

截获的请求（24 条一次发出）：

```json
{
  "url": "https://collector.example.com/ingest",
  "config": {
    "headers": {
      "Content-Type": "application/json",
      "Authorization": "Bearer <demo-token>"
    },
    "timeout": 10000
  },
  "body": {
    "entries": "[…24 条，见下]"
  }
}
```

`entries` 两条样例（Edit 的 `tool.call`、带 sk-demo 的 `tool.result`）：

```jsonl
{
  "time_unix_nano": "1789095621000000000",
  "event.id": "1a11dc84-7410-4527-82de-835b6cba10f0",
  "event.name": "tool.call",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "237b21ec30c08ae4",
  "parent_span_id": "435dd82377df37b8",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s2",
  "gen_ai.tool.name": "Edit",
  "gen_ai.tool.call.id": "toolu_demo_edit_1",
  "gen_ai.tool.call.arguments": "{\"file_path\":\"/tmp/demo-proj/calc.py\",\"old_string\":\"    return a / b\",\"new_string\":\"    if b == 0:\\n        raise ZeroDivisionError(\\\"b is 0\\\")\\n    return a / b\"}",
  "observed_time_unix_nano": "1789106870891000000",
  "gen_ai.provider.name": "anthropic",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}

{
  "time_unix_nano": "1789095642000000000",
  "event.id": "5b22e5b6-3b21-4a9e-8f3a-b09dc38e2767",
  "event.name": "tool.result",
  "trace_id": "9032601e75168485a90a6608051c11da",
  "gen_ai.session.id": "11111111-2222-4333-8444-555555555555",
  "gen_ai.turn.id": "11111111-2222-4333-8444-555555555555:t1",
  "gen_ai.agent.type": "claude-code",
  "gen_ai.agent.id": "11111111-2222-4333-8444-555555555555",
  "user.id": "<本机hostname>",
  "agent.claude-code.cwd": "/tmp/demo-proj",
  "span_id": "6f3d46ee1299f841",
  "parent_span_id": "e18a336844e2b076",
  "gen_ai.step.id": "11111111-2222-4333-8444-555555555555:t1:s3",
  "gen_ai.tool.name": "Bash",
  "gen_ai.tool.call.id": "toolu_demo_bash_1",
  "gen_ai.tool.call.result": "...\n3 passed in 0.02s\n(debug) OPENAI_API_KEY=sk-demo-1234567890abcdef1234",
  "tool.result.status": "success",
  "observed_time_unix_nano": "1789106870891000000",
  "gen_ai.provider.name": "anthropic",
  "workspace.path": "/tmp/demo-proj",
  "git.repo": "demo/demo-proj",
  "git.branch": "main",
  "git.domain": "example.com",
  "workspace.current_root": "/tmp/demo-proj"
}
```

与 SLS 的差别：body 是 `{"entries": […]}`（`src/flushers/http-flusher.ts:50`），值同样全是字符串，但 `serialiseLogEntry(entry)` **没传** `dropAgentScopedFields`（`:28,38`），所以 `agent.claude-code.cwd` 也一起出去；没有 `version`，也没有 IP/hostname 信封（`user.id` 仍是 hostname）。配了 `url` 就自动开（`config-loader.ts:1166-1169`）；满 20 条或每 5 s 发一次，失败整批放回队首重试（`http-flusher.ts:36-65`）。

### 3.4 配了 OTLP Trace 时（按源码推演）

这一节全部是读码所得，没有执行。转换逻辑的主体在仓外包 `@loongsuite/otel-util-genai`（`package.json:55`，`^0.1.0-beta.13`，仓里没有源码），所以下文分三种把握：**【码】**仓内代码直接可见；**【测】**仓内测试用真实转换器写的断言（只读过，没运行）；**【推】**依赖仓外包的推断。

- **默认不建**【码】。只有 `buildOtlpTraceConfig()` 返回至少一个端点才创建 OTLP flusher（`src/core/orchestrator.ts:767-776`）。端点来自这几处的并集：env `LOONGSUITE_PILOT_OTLP_ENDPOINT` 或 `otlpTrace.endpoint`；`cms` 同时配了 licenseKey 与 endpoint；托管文件 `configs/inner/data_config.json` 的 `otlp[]`/`cms[]`（`src/core/config-loader.ts:744-814`）。`collectTrace` 默认 `true`，只是闸门，设 `false` 才一定不建（`:745`）。本例实跑的有效配置里 `otlpTrace` 为空、`cms.enabled=false`，所以没有 OTLP 输出。
- **发往哪**【码】：`<endpoint>/v1/traces`（缺就补，`src/flushers/otlp-trace-flusher.ts:395-401`），http/protobuf（`OTLPTraceExporter`，`:10,403-404`），默认 gzip（`:556`）。请求头取 `otlpTrace.headers` 或 env `LOONGSUITE_PILOT_OTLP_HEADERS`；CMS 端点自动加 `x-arms-license-key`、`x-arms-project`、`x-cms-workspace`（`config-loader.ts:838-851`）。每批不超过 10 MB；发送失败时整批 span **连同全部内容**写进 `~/.loongsuite-pilot/logs/otlp-failed/<服务名>__<端点>-YYYY-MM-DD.jsonl`（`otlp-trace-flusher.ts:573,1786-1809`，保留 7 天）；开 `debug` 时转换结果写 `logs/otlp-debug/`（`:572`）。
- **resource**【码】（`:1752-1767`）：`service.name=loongsuite-pilot-claude-code`、`service.version`、`service.instance.id`（每进程随机 UUID）、`service.namespace=loongsuite-pilot`、**`host.name`=本机 hostname**、`gen_ai.agent.type=claude-code`、`gen_ai.agent.system=claude`、`gen_ai.framework=claude-code`。
- **按 turn 攒批**【码】：以 `gen_ai.turn.id` 分桶；某条 finish_reason 为 stop/end_turn/cancelled/error 时冲出该 turn（`:48,747-775`），或同一 session 的下一个 turn 到达时冲出上一个（`:692-702`）。所以 t1、t3 各自冲出，**t2（被拒的那轮）要等 t3 的第一条到了才冲出**；如果被拒后用户没再说话，它要等 daemon 停止或桶数超过 64 才发（`:704-717`）。转换前先去掉派生的 `agent.input`（`:1038-1044`）和没配对的 request/call（`:1049-1056`）。
- **固定透传**【码】：`git.repo`、`git.branch`、`git.domain`、`workspace.current_root`、`workspace.path` 总是交给转换器作为 span 属性透传（`src/normalization/global-attributes.ts:10-16`，`otlp-trace-flusher.ts:1010-1016`），`agent.*` 不透传。
- **内容**：`captureMessageContent` 不为 `false` 时，flusher 在进程环境里设 `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=SPAN_ONLY`（`??=`，已有值不覆盖，`:581-584`）【码】，消息内容进 span 属性。按测试：prompt 落在 ENTRY 与 AGENT 的 `gen_ai.input.messages`；LLM span 的 `gen_ai.input.messages`/`gen_ai.output.messages` 是 JSON 字符串，输入是按增量累积出的**完整历史**，reasoning 原样保留；用户 id 的键是 `gen_ai.user.id`；`gen_ai.system_instructions` 进 AGENT 与 LLM【测】。TOOL span 上的参数、结果、`error.*` 仓内没有断言【推】。仓内不做任何截断。默认不脱敏，所以 sk-demo 会进 Bash 的 TOOL 结果和第 4 个 LLM 的输入历史【推，默认不脱敏为码】。
- **被拒的 Bash**：flusher 只给 openclaw、grok-build 补 ERROR 状态（`:1095-1103,1456-1467,1563-1569`），claude-code 的 TOOL span 是不是 ERROR 取决于仓外转换器【推，仓内无法判定】。

第 1 个 turn 推算的 span 树（t=0 为 03:00:07Z；所有 span 带 `gen_ai.session.id`；TOOL 的 spanId 复用 hook 记录里的 `span_id`【码，`src/flushers/tool-span-id-reservation.ts:94-121`】，其余 span id 由转换器新生成）：

```text
Resource【码】 service.name=loongsuite-pilot-claude-code  host.name=<本机hostname>  gen_ai.agent.type=claude-code ...
trace 9032601e75168485a90a6608051c11da【测：取记录的 trace_id】
ENTRY  "enter_ai_application_system"【推】  0→42s【推】
│  gen_ai.input.messages=[user "给 calc.py 的 div 加零检查，然后跑一下测试"]【测】
│  gen_ai.user.id=<本机hostname>【测+码】  workspace.path=/tmp/demo-proj  git.repo=demo/demo-proj  git.branch=main  git.domain=example.com【码：透传；落点推】
└─ AGENT "invoke_agent <默认名>"【格式测，名字推】  0→42s
   │  usage in=5850 out=230 total=6080（4 次 LLM 之和）【测：求和口径】  gen_ai.turn.id=…:t1【测】
   ├─ STEP round 1  0→7s
   │  └─ LLM "chat claude-opus-5"【推】 0→7s  response.id=msg_demo_3ff7c188  finish=["tool_call"]  usage 2100/40
   │       in=[user prompt]  out=[reasoning "用户要给 div 加零检查…"]
   ├─ STEP round 2  7→21s
   │  ├─ LLM 7→14s  in=[user, assistant(reasoning)]  out=[tool_call Edit{file_path, old_string, new_string}]
   │  └─ TOOL "execute_tool Edit"  spanId=237b21ec30c08ae4【码】  14→21s  result="The file … updated successfully."【推】
   ├─ STEP round 3  21→35s
   │  ├─ LLM 21→28s  out=[tool_call Bash{"python3 -m pytest -q"}]
   │  └─ TOOL "execute_tool Bash"【测】  spanId=6f3d46ee1299f841  28→35s  result="…3 passed…OPENAI_API_KEY=sk-demo-1234567890abcdef1234"【推】
   └─ STEP round 4  35→42s
      └─ LLM 35→42s  in=[…, tool_call Bash, tool 回包（含 sk-demo）]  out=[text "改好了：…3 个测试都通过。"]  finish=["stop"]
```

按「每次 LLM 调用一个 STEP」推算：t1 共 12 个 span，t2 共 5 个（含被拒的 `execute_tool Bash`，spanId `c8a7f2da3dfa2bc0`，状态未知），t3 共 4 个，三棵树合计 21 个 span。**不确定的**：除 TOOL/AGENT 外的 span 名与 SpanKind、主 agent 的默认名字、TOOL 上有哪些属性、`cache_creation` 是否输出、t2 各 span 的状态——都在仓外包里。

## 4. 一眼看完：采了什么、没采什么

「本机」指默认安装下的本机文件；「出本机」指会话事件，默认不出，表里写的是**配了 SLS / HTTP / OTLP 之后**出去什么。唯一默认就出本机的是 §3.1 的运行状态回传，只涉及表里的主机身份一项。

| 内容 | 本机 | 出本机 | 出处（文件:行） |
|---|---|---|---|
| prompt 正文 | **采，全文**。hook 侧每条 2 份（`other` + 同轮第一次 `llm.request` 的输入增量）；daemon 输出 3 份（再加派生的 `agent.input`）。关内容开关后两侧都删 | 默认不出。配了远端：SLS/HTTP 全文，每条 3 份（实跑）；OTLP 进 ENTRY/AGENT/LLM 的 `gen_ai.input.messages`（推演） | `:970-980,1071`；`claude-code/transcript-parser.mjs:498-510`；`src/normalization/agent-input-dual-write.ts:18-43` |
| 模型回复正文 | **采，全文**（`llm.response` 的 `gen_ai.output.messages`）；同一 turn 里非最后一次的输出，还会在下一次 `llm.request` 的输入增量里再出现一次 | 同上，全文 | `claude-code/message-converter.mjs:225-227`；`:1109-1114`；`transcript-parser.mjs:454-461` |
| thinking | **采，全文**（`type: "reasoning"`），本例 2 份；`signature` 不采；同一回复有多个 thinking 块时只留最长的 | 同上 | `message-converter.mjs:236-237`；`transcript-parser.mjs:585-588` |
| Edit 的新旧文本 | **采，全文**（`old_string`、`new_string`，连同 `file_path`）。hook 侧 3 份：`tool.call` 参数、`llm.response` 输出、下一次 `llm.request` 输入 | 同上 | `:1169`；`message-converter.mjs:228-234` |
| 改前的整份文件 | **不采**。`toolUseResult.originalFile`、`structuredPatch` 从不读取，Edit 的结果只记 “The file … has been updated successfully.” | 不出 | `transcript-parser.mjs:319-337` |
| Bash 命令 | **采，全文**（`command`、`description`），3 份；被拒的那条也在（2 份） | 同上 | `:1169` |
| 工具输出 | **采，全文**（`tool_result.content`，无截断）：`tool.result` 一份，下一次 `llm.request` 输入再一份；失败或被拒时前 500 字另存进 `error.message`。`stdout`/`stderr`/`interrupted` 等结构化字段不采 | 同上；`error.message` 关掉内容开关也照样出去（补充实跑 C） | `transcript-parser.mjs:319-325`；`:1185,1189-1194` |
| 假密钥 sk-demo 是否被脱敏 | **否**。hook 侧 2 处明文（§2.1 #11、#12），daemon 输出 2 处明文。hook 侧没有脱敏代码，daemon 默认 `mask.mode=none`。开 `mask.mode=all` 后 daemon 输出变成 `[APIKEY_MASKED]`（补充实跑 D），hook 侧仍是明文且永不删除 | 默认明文出去；开 mask 后出站也是 `[APIKEY_MASKED]` | `src/core/config-loader.ts:560-563`；`src/core/input-manager.ts:384-389`；`src/mask/sensitive-rules.json:32-37` |
| 被拒绝的调用 | **采**。`tool.call`（命令全文）+ `tool.result`（拒绝提示全文；`status` 在 hook 侧是 `error`、输出里是 `failure`；`error.type=ToolError`；`error.message` 同一段文字）。与执行失败无法区分；该 turn 没有 `gen_ai.turn.end` | 同上；OTLP 里这个 TOOL span 的状态取决于仓外包 | `:1174-1196`；`src/normalization/entry-builder.ts:476-497`；`src/normalization/turn-boundary-processor.ts:104-106` |
| interrupt 记录 | **不采**（丢失）。它排在 t2 最后一次模型调用之后，没有下一次调用把它带出来 | 不出 | `transcript-parser.mjs:382-387,454-461` |
| 文件路径与 cwd | **采**。hook 侧每条 `agent.claude-code.cwd`、工具参数里的绝对路径、state 文件里的 transcript 路径与 cwd；输出每条 `workspace.path`、`workspace.current_root`。关掉内容开关后 cwd 与 `workspace.*` 仍在 | 每条 `workspace.*`；HTTP 另带 `agent.claude-code.cwd`；OTLP 固定透传 `workspace.*` | `:961`；`src/normalization/enrich-git-context.ts:25,34`；`src/flushers/http-flusher.ts:28,38`；`src/normalization/global-attributes.ts:10-16` |
| 仓库、分支、remote | hook 侧**不采**；daemon 输出每条 `git.repo`=`demo/demo-proj`、`git.branch`=`main`、`git.domain`=`example.com`。remote 原串不存，但 https remote 里嵌的凭据会原样进 `git.domain`（实跑归一化函数，见 §5） | 每条都带；mask 不扫 `git.*`；OTLP 固定透传 | `src/utils/git-context.ts:48-53,85-95`；`src/normalization/source-context.ts:85-92` |
| token 用量 | **采**。每个 `llm.response`：input（含缓存读写）、output、cache_read、cache_creation、total；另有 `gen_ai.input.messages_hash`。没有成本字段 | 每条带；运行状态回传不带 token，只带当期事件与字节计数 | `:1082-1108` |
| 用户与主机身份 | `user.id` = hostname，每条都有（未配 userId 时）；daemon 指标文件另有 hostname、IP、`instance_id` | 会话事件：`user.id` 每条；SLS 信封加 `__hostname__`、`__source__`=IP，UA 带 IP；OTLP resource 带 `host.name`。**运行状态回传默认就出**：hostname、IP、`os_detail`、`instance_id`（可还原出数据目录路径与 userId） | `agent-event-normalizer.mjs:239-242`；`config-loader.ts:274`；`src/flushers/sls-flusher.ts:35,317-322,517-525`；`src/utils/network-utils.ts:18-21`；`src/internal/statistic.ts:12-21,35-38`；`src/metrics/metrics-collector.ts:494-500` |
| 会话 id 与 tool_use_id | **采**。`gen_ai.session.id`、`gen_ai.agent.id`（都 = session id）、`gen_ai.turn.id`（`<sid>:t<n>`）、`gen_ai.step.id`、`gen_ai.response.id`（= `message.id`）、`gen_ai.tool.call.id`（= `tool_use_id`）；`trace_id`/`span_id` 随机。transcript 的 `uuid`、`promptId`、`requestId` 不采 | 每条带 | `:935,949-966,1020-1023,1168`；`shared/event-emitter.mjs:29-35` |

表外补充：**Claude Code 的 system prompt**。默认安装经 shell rc 挂上 fetch 拦截器后，每次 LLM 调用写一份到拦截文件，`Stop` 时并进那次 `llm.request` 的 `gen_ai.system_instructions`（本例 6 次调用 6 份）；拦截文件不受内容开关约束（补充实跑 B、C）。配了远端时随事件出去。

## 5. 与采集清单文档对不上的地方

清单 `third-party/loongsuite-pilot-collection.md` 与本次实跑、读码对照，行号全部回查过，除下列各条外一致。

**对不上的（3 条）**

1. **§3.2 HTTP 出站的报文形状与行号**。清单写「`http-flusher.ts:77` —— `axios.post(url, { topic, ...payload })`，整条事件进 body」。`:77` 是 `sendRaw()`（给指标之类的原始记录用）；会话事件走 `flush()`，body 是 `{ "entries": [...] }`（`src/flushers/http-flusher.ts:50`，实跑截获确认），每条是 `serialiseLogEntry(entry)` 的全字符串 map。而且这条路径**没传** `dropAgentScopedFields`（`:28,38`），所以 HTTP 比 JSONL、SLS 多带 `agent.<ns>.*` 字段，本例即每条多一个 `agent.claude-code.cwd`。
2. **§5.3「`gen_ai.system_instructions` 在本机 JSONL 里键还在」**。实跑 C：键留着的只有 hook 侧那份 `logs/claude-code/…jsonl`（值 `[{"type":"text"}]`）；daemon 写的本机 JSONL `logs/output/…jsonl` 和出站一样整键缺失——内容策略在 `InputManager` 里、JSONL flusher 之前就执行了（`src/core/input-manager.ts:380-382`）。清单别处（§0、§2.1）说的「本机 JSONL」都指 `logs/output`，这里应改成「hook 侧那份」。结论的方向（本机与出站口径不同）不变。
3. **§0「计数与指标：token 五项 + 四项成本」**。Claude Code 链路没有任何成本字段：hook 不写，daemon 只在记录里已有时才透传（`src/normalization/entry-builder.ts:113-125`）；实跑的 21 条、24 条里都没有。成本只出现在别的 agent（如 Cursor）的链路上。

另：任务说明转述「`logs/output/*.jsonl` 没配远端时默认开启」。代码里 `jsonl.enabled` 默认 `true`，与配没配远端无关，配了 SLS 也照写（`config-loader.ts:1148`，`orchestrator.ts:755-759`）；只有所有 flusher 都关掉时才另起一个兜底 JSONL（`orchestrator.ts:783-792`）。清单本身写的是「默认开」，与代码一致。

**清单没写到、本次实跑补出来的（6 条）**

1. **https remote 里的凭据会进 `git.domain`**。`normalizeDomain()` 对 https 形式取 `://` 到第一个 `/` 之间的整段（`src/normalization/source-context.ts:85-92`）。用真实函数跑三种写法：

   ```jsonl
   {"remote":"git@example.com:demo/demo-proj.git","git.repo":"demo/demo-proj","git.domain":"example.com"}
   {"remote":"https://github.com/demo/demo-proj.git","git.repo":"demo/demo-proj","git.domain":"github.com"}
   {"remote":"https://oauth2:glpat-<假令牌>@gitlab.example.com/demo/demo-proj.git","git.repo":"demo/demo-proj","git.domain":"oauth2:glpat-<假令牌>@gitlab.example.com"}
   ```

   `git.domain` 每条事件都带、本机输出与出站都有、OTLP 固定透传，mask 也不扫 `git.*`（`src/mask/field-whitelist.ts:1-35`）。本例是 ssh 形式，不触发。清单 §5.4 只说「团队仓库身份随每条事件出本机」。
2. **OTLP 发送失败时整批 span 连内容写盘**：`logs/otlp-failed/`（`src/flushers/otlp-trace-flusher.ts:1786-1809`，保留 7 天）。清单 §2.3、§6 称赞 `sls-failed-logs` 只存元数据、「不含 payload」，OTLP 这边正相反，清单没区分。
3. **内容在输出里是成倍出现的**：hook 侧每次模型输出、工具结果都会在下一次 `llm.request` 的输入增量里再出现一次；daemon 又给每条 prompt 派生一条 `agent.input`（`src/normalization/agent-input-dual-write.ts:18-43`）。所以本例 prompt 在输出里 3 份、Edit 文本与 Bash 命令 3 份、sk-demo 2 份。清单 §1.2 只说「全文」。
4. **拦截器开着时 system prompt 按次重复**：每次 LLM 调用的 `llm.request` 都带一份完整 `gen_ai.system_instructions`（本例 6 份）。清单 §1.5 只写了拦截文件与合并。
5. **被拒的那一轮在输出里没有结束标记**：`tool.result.status` 由 `error` 归一成 `failure`（`entry-builder.ts:492-497`），而 turn 结束标记只认 stop 类的 finish_reason（`turn-boundary-processor.ts:6,104-106`），t2 只有 `tool_call`，于是没有 `gen_ai.turn.end`；OTLP 那边它要等下一个 turn 到来才被冲出（`otlp-trace-flusher.ts:692-702`）。
6. **清单标「未确认」的，本次确认**：主会话的 `state/claude-code/sessions/*.json` 没有任何清理——`src/` 里没有引用该目录的代码，保留服务实跑也不碰它（§2.1）。

---

**产物与回放脚本**：`replay.mjs`、`daemon-sim/`、各轮的假 HOME 与快照都留在跑的那台机器的临时目录里，没有入库（见文首入库说明）。
