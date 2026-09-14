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
