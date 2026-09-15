# vibetrail

用 Claude Code 的 hook，把每个会话的两路数据自动传上云：**全量**（原始 transcript 逐字节副本，加 transcript 没有的 hook 事件与 git 状态）
和**人机分歧**（打断、拒绝的索引）。机器级装一次，被观测仓里零写入。

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
     门控（只采登记过的项目）→ transcript 增量副本 + 分歧提取 + 事件头 + git 状态
     ──▶ ~/.vibetrail/spool/<项目>/<sid>/   ──push（HTTP，分块、gzip、幂等）──▶ 云端，ack 即删
```

被观测仓里不写 settings、不装 git hook、不放运行时、不进 git。现阶段云端还没有，spool 里的文件就是将来 push 的内容。

## 状态

2026-09-14 需求与设计定稿，未开工。已有并沿用的是人机分歧判据（755 会话实测精确率 100%，裸 grep 只有 10.5%）。
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
- [third-party/](third-party/)：teamai、LoongSuite Pilot、paas-coding-hook 协议的分析与实跑样例。

## 边界

本项目只出**工具**。采集数据不进任何仓：本机 outbox 过手，push 到云端。首个观测对象是 agentDock，但本项目不属于它，也不假设只服务它。
审计记录那条线（`vibetrail-audit`）仍落在被观测仓里、仍靠 git hook 写锚，与本项目的零写入原则不一致，去向另定。
