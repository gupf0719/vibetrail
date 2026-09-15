# 同类开源项目调研：Claude Code 会话采集与分析

> 2026-09-15。用户要求「业内有其他类似的开源项目，靠谱稳定的，看看」，并强调「不是照抄」。
> 由调研 agent 只读查阅 GitHub 源码、README、issue 与 Claude Code 官方文档所得，**没有在本机复核**：
> 标 [源码] 的是 agent 读过源码，标 [文档] / [README] / [issue] 的只是那里的说法。行号不稳，所以写函数名，自己 grep。
> 想在本机语料上核的三条（Stop hook 反馈、会话续接摘要、同一消息的用量先小后大）这次会话被安全检查拦了，留到下个会话。
> 已单独深读、这里不重复的：LoongSuite Pilot（[loongsuite-pilot.md](loongsuite-pilot.md)）、teamai-cli（[teamai-cli.md](teamai-cli.md)）；已知的 SpecStory、git-ai、claude-story 见 DESIGN §7。

## 1. 哪些靠谱

| 项目 | ★ | 最近提交 | 发版 | 测试 | 许可 | 贡献者 | 判断 |
|---|---|---|---|---|---|---|---|
| [ccusage](https://github.com/ccusage/ccusage) | 18.6k | 09-15 | 每月几次 | 有 | MIT | 77 | token 计算的事实标准，只管用量 |
| [agentsview](https://github.com/kenn-io/agentsview) | 5.9k | 09-15 | 约两周一次 | 很全 | MIT | 144 | 读取与上传最严谨，代码量大 |
| [Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor) | 8.7k | 07-05 | 停了 11 个月后刚发 | 有 | MIT | 6 | 流行但简单 |
| [claude-code-log](https://github.com/daaain/claude-code-log) | 1.2k | 09-13 | 约每月 | 有 | MIT | 20 | 回放记录处理得细，没有上传 |
| [claude-code-history-viewer](https://github.com/jhlee0409/claude-code-history-viewer) | 2.2k | 09-04 | 频繁 | 部分 | MIT | 54 | 查看器 |
| [Langfuse claude-observability-plugin](https://github.com/langfuse/claude-observability-plugin) | 23 | 09-14 | 09-09 | 有，带样例 transcript | MIT | 8 | 形态最像我们，但很新、用户少 |
| [Entire CLI](https://github.com/entireio/cli) | 5.1k | 09-15 | nightly | 有 | MIT | 61 | commit 关联最好，但往仓里写 |
| [vibe-log-cli](https://github.com/vibe-log/vibe-log-cli) | 340 | 04-19 | 停了 | 有 | MIT | 5 | 只看它的 hook 安装写法 |

不值得看：Opcode / Claudia（AGPL，2025-10 后没动）、claude-trace（没许可，往工作目录写 `.claude-trace/`）、sniffly（2025-08 后没动）、cc-sessions（工作流工具不是采集器）。
「靠谱稳定」的只有 ccusage 与 agentsview 两家；其余要么停更，要么用户太少。

## 2. 对照我们这次碰到的问题

| 问题 | 最好的做法（出处） | 比我们好吗 | 我们怎么办 |
|---|---|---|---|
| 增量读取 | agentsview：信任 offset 前先查三件事——同一个文件、没变短、offset 之前那段的哈希没变，任一不满足就整份重读；新读到的记录接不上上次最后一个 uuid 时也整份重读 [源码 `assessCapture`、`claudeParseSessionFrom`] | **是**：我们只查「变短」，同样大小的原地重写查不出来 | 借：state 多记 inode 与 checkpoint 之前一小段（如 4 KB）的哈希，对不上从 0 重读；只哈希一小段是我们的改法，agentsview 哈希整个前缀 |
| 会话锁 | agentsview 非阻塞 `flock`；Langfuse `LOCK_NB` 等 2 s [源码] | 持平 | 我们用 mkdir 锁，bash 里等价；vibe-log 先查后写的锁有竞态，别学 |
| 回放副本 | claude-code-log 按 uuid 留第一份，时间戳相同的兄弟记录当回放 [源码 `build_message_index`]；agentsview 按 uuid 重叠裁掉后台 fork 的回放 [源码] | 否，没人处理「promptId 被改写」 | 维持按 uuid + 行号跳过。两个 Claude Code issue 说 `saved_hook_context` 会共用 uuid、`file-history-snapshot` 的 messageId 会撞 uuid [issue]——我们只对触发记录与人话记录去重，正好避开 |
| 打断与拒绝 | 各家都是字符串前缀加 `is_error` [源码]；没人拿 `toolUseResult` 对账 | 否 | 维持判据 + 字段哨兵。更硬的信号在 Claude Code 自己：`PermissionDenied` hook（auto mode 拒绝，带 `tool_use_id` 与 reason）、`PostToolUseFailure` 的 `is_interrupt`、OTel 的 `tool_decision` 事件（`decision_source` 分 user_reject / user_abort / config / hook）[文档]，列进 U8 / G6 做对账候选。新版 transcript 的 `toolDenialKind` 在内部会话重置时也会出现 [issue]，只能当提示 |
| 人话与注入 | agentsview 的排除清单比我们多三类：「This session is being continued」开头的续接摘要、「Stop hook feedback:」、IDE 标签；排队的 `queued_command` 按时间并进人话 [源码 `classifyClaudeSystemMessage`、`extractQueuedCommand`] | **是**，清单更全 | **已借**（09-15）：两类前缀不算人话，IDE 标签只剥不整条排除（它常和人打的字在一起）；fixture 钉着，本机语料上的条数没量成（命令被拦）。排队人话本机语料里从没当过分歧后的第一句，暂不做 |
| token 用量 | ccusage 按 message.id + requestId 去重，同一键留 token 总数更大的那份，结果与读取顺序无关；早期流式记录的计数可能是占位值 [源码 `should_replace_deduped_entry`，issue #866 / #888] | 本机没这个问题 | **已借**（09-15）：同一 message.id 留 output 大的。本机 24243 条消息里同一 id 各记录用量全部一致，纯防御。写缓存可再按 `ephemeral_5m` / `ephemeral_1h` 拆，协议没有对应字段，暂不拆 |
| 一条回复拆成几条记录 | Pilot 按 message.id 合并，多段文字只留最长一段 [源码 `deduplicateContentBlocks`]；teamai 知道会拆（测试注释），只在用量上去重，Stop 时取末尾 10 KB 里最后一条带文字的记录 [源码 `readLastAssistantOutput`] | 否，两家都会丢段 | 自己的规则（09-15 在本机语料上量了再定）：七成回复拆成 ≥2 条，212 条多段文字里 210 条是快照、2 条是真多段——快照留完整的、真多段接起来。被打断的回复从 22 条找回到 97 条（DESIGN §4.2） |
| 子 agent | Langfuse 读 `meta.json` 的 `toolUseId` 挂父调用，嵌套的在同一个 `subagents/` 目录里递归解析；后台子 agent 等到 task-notification 才关轮 [源码] | 持平 | 我们已按兄弟文件找父实例。后台子 agent 那套是为了拼整棵 trace，我们事件各自独立，不需要 |
| 上传 | agentsview：本地 SQLite outbox 存不变的快照、按内容哈希幂等、先问服务端缺哪些再批量传、服务端 ack 才推进、临时失败 1 分钟到 1 小时退避、永久失败记下不再重试 [源码 `rawupload`、`rawcheckpoint`] | 是，push 还没写 | 做 push 时借：ack 才删块（已定）、退避、永久失败单独记账不重试；幂等键用我们的 UUIDv5 event_id |
| 安装与范围 | vibe-log 按命令前缀认自家 hook、把 `$CLAUDE_PROJECT_DIR` 传给全局 hook 做按项目开关 [源码]；git-ai 每天复查一次 hook 在不在 [README] | 部分 | 我们已用 marker 认条目。`$CLAUDE_PROJECT_DIR` 比 payload 里的 cwd 稳（cwd 会随 CwdChanged 变），装机时考虑；「定期复查」放进 doctor |
| commit 关联 | Entire 写 `Entire-Checkpoint` trailer 加独立 ref [README]，要往仓里装 hook；Claude Code 自己的 OTel `tool_result` 在成功的 `git commit` 上带 `git_commit_id`（2.1.269 起，要开 `OTEL_LOG_TOOL_DETAILS=1`）[文档]；从 Bash 输出里抠 hash 不可靠，`git commit -q` 不打印 hash [issue] | 否 | 维持每轮起止 HEAD + `rev-list`（DESIGN §3.5）；OTel 的 `git_commit_id` 可作将来的对账旁证 |

## 3. 不学的

- **Entire 往仓里写**（`.entire/`、仓内 `.claude/settings.json`、git hook），违反被观测仓零写入（A8）。
- **50 MB 之类的上限**：Pilot、teamai 都有，都会丢分歧（DESIGN §3.3）。
- **随机 id**：Pilot 的 span id 随机；协议要求重发幂等，我们用确定性的 UUIDv5。
- **vibe-log 的锁**：先查文件在不在再写，两个进程能同时拿到。
