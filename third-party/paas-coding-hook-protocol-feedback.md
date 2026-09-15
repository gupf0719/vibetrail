# 对 paas-coding-hook 事件协议的意见

> 第一轮（2026-09-14，针对 1.0 初版）是 §1–§3，第二版协议全部采纳，落实方式见 §4。第二轮（2026-09-15，针对 1.0 第二版：协议、collector 实现说明、Span 归档规范、schema）在 §5。
> 我们这边随之定的映射在 [DESIGN.md §4.1](../DESIGN.md)；schema 原件存 [collection-batch-1.0.schema.json](collection-batch-1.0.schema.json)。

## 1. 人机分歧需要的字段

### 1.1 tool.end、turn.end 的 status

问题：

- status 只有 success / error / cancelled / unknown。调用被拒绝、没有执行、轮次继续的情况没有值：人拒绝、策略或分类器拦下、权限系统故障。Claude Code、Codex、Cursor 都有审批环节，这三种情况每家都会出现。现在只能填 error，和真正的执行失败混在一起。
- 四个值在 tool.end 和 turn.end 上都是必填，但每个值在两种事件上各是什么意思没写。文档里 success、error 的主语是调用，cancelled 的主语是轮次。人打断一次正在执行的工具调用，是发 tool.end 一条还是 tool.end 和 turn.end 各一条，没写。

建议：

- status 加 `denied`；payload 加 `denied_by`，取 `user` / `policy` / `system`。
- 每个值写两行，一行在 tool.end 上的含义，一行在 turn.end 上的含义。写明工具调用中被打断时两条都发，打断次数只按 turn.end 统计。

### 1.2 子 agent 的 session.start：`parent_session_id`、`parent_call_id`

问题：支持子代理的 agent 会给子代理独立的 session_id 和会话记录，schema 没有字段把子会话挂到父会话和派生它的那次工具调用。子代理发起的工具调用弹出的审批仍由人回答，所以人拒绝会出现在子会话里，挂不回父会话的那一轮就归不了责。子会话的第一条「用户消息」是父 agent 的派活说明，不是人写的，不标出来会被当成人的输入。

建议：子会话的 session.start payload 带 `parent_session_id` 和 `parent_call_id`，后者是父会话里派生它的那次工具调用的 call_id，只在会话开始时带一次。Collector 按 call_id 把子会话挂到父会话对应轮次下，子会话的 message.user 按这条链接标为非人类输入。

### 1.3 tool.end、turn.end：`status_source`、`rule_version`

问题：status 有三种来路：agent 的类型化 hook 事件、客户端按字符串规则解析会话记录、客户端推断。字符串规则随 agent 版本变，事件里没有字段记录这条状态怎么得来、用的哪版规则。规则一改，新旧事件分不开；hook 给的事实和解析出来的事实也没法对账。

建议：payload 加 `status_source`，取 `hook` / `transcript` / `inferred`；加 `rule_version`。

### 1.4 session.start：`agent_version`

问题：client.version 是 hook 客户端的版本，不是 agent 的版本。各 agent 的会话记录格式、可用的类型化信号都随自身版本变，没有 agent 版本，从记录解析出来的事实没法解释。

建议：session.start payload 加 `agent_version`，一次即可。

## 2. 事件类型枚举

问题：type 是九个值的封闭枚举。各 agent 自带的类型化事件没有对应类型：Claude Code 的 PermissionDenied、StopFailure、InstructionsLoaded、CwdChanged、SubagentStart、SubagentStop、Notification；Codex 会话记录里 turn_aborted 一类类型化条目；Cursor hooks 的 beforeShellExecution、afterFileEdit 等。这些恰好是比字符串匹配可靠的信号。每出一种新信号都要双方改 schema 发新版，在那之前只能丢，服务端不知道丢了什么。

建议：加类型 `hook.event`，payload 带 `name` 和自由结构的 `data`，Collector 只存不解释，受单条 1 MiB 上限约束。或者把这些事件逐个加进枚举。两者选一。

## 3. 其他可补充的字段

| 字段 | 用途 |
|---|---|
| session.start `source`、session.end `reason` | 分会话边界 |
| turn.start / turn.end `head_sha`、`branch` | 把提交归到轮次 |
| message.user `origin`：human / queued / tool_result / system | 区分人的输入与注入内容 |

## 4. 第一轮的落实（第二版协议，2026-09-15 核）

| 第一轮提的 | 第二版怎么落的 |
|---|---|
| 1.1 status 加 `denied` / `denied_by` | 拒绝改成独立事件 `permission.decision`（`decision` deny / error，`decided_by` user / policy / system），status 加 `category` 一层含 `denial`；明写执行前被拒只发 decision、不伪造 `tool.end`；工具中断时 `tool.end(cancelled)` 与 `turn.end(cancelled)` 各发一条 |
| 1.2 子 agent 挂父会话 | 公共字段 `agent_instance_id` / `parent_agent_instance_id` / `parent_session_id` / `parent_call_id`；派活说明标 `author_type=agent`、`delivery=injected` |
| 1.3 `status_source` / `rule_version` | `provenance.kind`（hook / api / transcript / filesystem / inferred / synthetic）+ `rule_version`，transcript 与 inferred 必带 |
| 1.4 `agent_version` | `agent.version` 每条事件可带 |
| 2 事件类型封闭 | `ext.<ns>.<name>` 扩展事件 + `raw` 保留原始事件 |
| 3 其他字段 | `session.start.source`、`session.end.reason`、`turn.start/end.vcs`（branch / head_sha / dirty）、`turn.end.commits[]`、message 的 `author_type` + `delivery` 都有了 |

## 5. 第二轮意见（2026-09-15）

对象：collection-event-protocol.md 第二版、collector-implementation.md、coding-span-spec.md、collection-batch-1.0.schema.json。映射本身没有拦路的问题，以下按轻重排。

1. **请求支持 `Content-Encoding: gzip`。** 现在 415 拒。
2. **响应列出 SDK 上报失败的 `event_id`。** 现在只有 `sdk_failed_count`，客户端不知道该补哪些，只能整批重发。
3. **公布 Monitor SDK 的单条正文上限。** Span 规范说低于事件长度时记失败，客户端要按它控制单条大小。
4. **可见性。** 「记录默认对公司已登录用户可见」；分歧事件带被拒的命令与被打断的回复，含代码片段、可能含密钥，采集端暂不脱敏。需要按 user / project 控制访问，或明确开放前要经脱敏。
5. **文件关系跨工作区。** `files[].path` 必须在 `workspace_id` 的根内、不能 `..`，会话改别的仓的文件没有表达法。建议 file 项可选 `workspace_id`。
6. **`client.name` 是 const `paas-coding-hook`。** 放开成推荐值：vibetrail 是独立客户端，冒名会把两边的 `rule_version` 混在一起。小项。

不再提的：`turn.end` 的 `interrupted`（code 是自定义值，直接用）；保留期（30 天够用）；读取接口（读取分析不归采集端）。
