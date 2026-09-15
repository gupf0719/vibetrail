# vibetrail

用 Claude Code 的 hook，把每个会话的两路数据自动传上云：**人机分歧**（打断、拒绝，带能判责的最小正文）和**轮次元数据**
（会话 / 轮次 / 子 agent 起止、每轮起止的 HEAD 与 commit、状态，每次模型调用与工具调用各一条 trace，不带正文），映射成 paas-coding-hook 事件协议 1.0。不传 transcript 原文件。
机器级装一次，被观测仓里零写入。

目标一句话：拿到任何一个 commit，能追回「它是怎么来的」；出了问题，能定位**人和 agent 在哪一步对不上**。

## 为什么需要

Claude Code 已经在写完整的会话流水（thinking 全文、每次 Edit 的 diff、子 agent 独立 transcript、中断与拒绝），本地单个项目就能累积数百 MB。
**问题不是没记**：

1. 它只在本机——不入仓、换机器即丢、默认 30 天清理。
2. 几百 MB 没有索引——「人在哪一步不同意机器」的信号就在里面，但业内工具最多只认「中断」一种。
3. commit 与会话没有关联——`git blame` 只到行，到不了意图。

## 怎么工作

```
vibetrail init（每台机器一次）
  └─ ~/.claude/settings.json 里挂 hook（只在 HOME），~/.vibetrail/ 放运行时与 outbox

每个会话
  SessionStart / UserPromptSubmit / Stop / … ──▶ vibetrail-hook
     门控（只采登记过的项目）→ 增量解析 transcript → 分歧事件（带正文）+ 轮次元数据 + git 状态
     ──▶ ~/.vibetrail/spool/<项目>/<sid>/events.jsonl   ──push（HTTP 批次，event_id 幂等）──▶ paas-coding-hook collector，ack 即删
```

被观测仓里不写 settings、不装 git hook、不放运行时、不进 git。现阶段云端还没有，spool 里的文件就是将来 push 的内容。

## 演示：安装 → 采集 → 看本地文件

简明步骤与数据路径见 [DEMO.md](DEMO.md)。

先在沙箱里看一遍（临时目录，不碰真实的 `~/.claude` 与 `~/.vibetrail`；回放一段示例会话，第 1 轮中途真的提交一次）：

```bash
bash experiments/collect-demo/demo.sh
```

在自己机器上装（在哪个目录跑都行，不会登记任何仓；默认 scope=project，只采登记过的仓），再选要采的仓：

```bash
bash tools/vibetrail init
```

```bash
~/.vibetrail/bin/vibetrail projects pick
```

之后在这个仓里正常用 Claude Code（CLI 或 desktop 都行，settings 热加载，已开着的会话从下一次 hook 起生效）。看采了什么：

```bash
~/.vibetrail/bin/vibetrail show
```

- `vibetrail list` 列出 spool 里的每个块文件，文件在 `~/.vibetrail/spool/<项目>/<会话>/*.jsonl`，每行一条协议事件，直接 `cat` 就能看。
- `vibetrail doctor` 自检；`vibetrail uninstall` 卸载（只去掉 settings 里自己的条目，spool 留着，`--purge` 才全删）。
- 什么时候出现什么：说一句话就有 `turn.start`（带 HEAD）；模型答完（Stop）后，这一轮的 `turn.end`（状态、用量、本轮 commit）、每次模型调用的 `message.assistant` 与每次工具调用的 `tool.end`（trace，不带正文，DESIGN D8）、分歧事件一起落盘。
  Stop hook 触发就是模型答完，当场写；别的 Stop hook 把这次 Stop 拦下时，模型补完再 Stop 会再写一条更新的（DESIGN D7）。
  你按停止打断的轮要等下一个 hook 才写（打断没有 hook，desktop 实测）；打断正在跑的工具现在会被记成「拒绝」，见 OPEN-ISSUES K7。

## 状态

2026-09-14 需求与设计定稿、09-15 定不传 transcript 原文件并选定云端协议（DESIGN D5）；同日做完：分歧映射成协议 1.0 事件（`tools/vibetrail-map`）、
hook 分发入口（`tools/vibetrail-hook`：会话 / 轮次 / 子 agent 起止、`ext.claude.*` 事件头、git 状态、commit ↔ 轮次推导）、
机器级安装与本地查看（`tools/vibetrail`：init / uninstall / projects / doctor / list / show / sync）、照 Pilot 粒度的调用 trace。人机分歧与轮次元数据是同一条事件流。
push 与五个补充回归场景按用户 09-15 的要求往后放。G7 之前的代码与测试已归档到 `old/`。已有并沿用的是人机分歧判据（755 会话实测精确率 100%，裸 grep 只有 10.5%）。
上一版设计（留痕投影进被观测仓、git hook 写 trailer）已退役，理由与替代见 [DESIGN.md §7](DESIGN.md)。

已实测确立的地基（`experiments/` 可复现）：Claude Code 的 hook 在 **desktop app 下正常触发且热加载**，stdin 直接给出 `transcript_path`；
新版 transcript 自带 system prompt 快照。只要不用「进程包装型」的方案，开发者用 CLI 还是 desktop 都留同样的痕。

## 文档地图

- [DESIGN.md](DESIGN.md)：要解决的问题、采什么、怎么采、去哪、安装与范围、实测地基、决策记录、验收。
- [CAPABILITIES.md](CAPABILITIES.md)：有哪些功能、什么状态（沿用 / 待做 / 退役 / 审计线）、沿用部分怎么实现的。
- [spec/diverge-v1.md](spec/diverge-v1.md)：人机分歧判据、准确率、踩过的坑。
- [spec/trace-v1.md](spec/trace-v1.md)：审计记录线的格式（仍在仓内，去向暂不定）。
- [OPEN-ISSUES.md](OPEN-ISSUES.md)：唯一的未完成项清单——未定决策、已知缺陷、未量。
- [TODO.md](TODO.md)：拆解（G7）与下一项需求的方案（G11）。
- [DEMO.md](DEMO.md)：演示——怎么装、采到的数据在哪、怎么看。
- [third-party/](third-party/)：teamai、LoongSuite Pilot、paas-coding-hook 协议的分析与实跑样例。

## 边界

本项目只出**工具**。采集数据不进任何仓：本机 outbox 过手，push 到云端。首个观测对象是 agentDock，但本项目不属于它，也不假设只服务它。
审计记录那条线（`vibetrail-audit`）仍落在被观测仓里、仍靠 git hook 写锚，与本项目的零写入原则不一致，去向另定。
