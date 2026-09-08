# vibetrail

AI 辅助开发的**过程留痕与复盘**工具。

目标一句话：拿到任何一个 commit，能追回「它是怎么来的」；出了问题，能定位
**人和 agent 在哪一步对不上**。

## 为什么需要

Claude Code 已经在写完整的会话流水（thinking 全文、每次 Edit 的 diff、子 agent
独立 transcript、中断与拒绝），本地单个项目就能累积数百 MB。**问题不是没记，
是记了查不到**，并且有三处断链：

1. **commit ↔ 会话无关联** —— `git blame` 只到行，到不了意图。
2. **审计过程本身没留痕** —— 「审过了」是个布尔值，「审了什么、判了几真几假」没了。
3. **人机分歧点没有索引** —— 而 `userModified`（模型改完、人又手改）
   是现成的机器可判信号，业内工具无一采用。

## 状态

见 [CAPABILITIES.md](CAPABILITIES.md)：有哪些功能、怎么实现的、还缺什么。
见 [DESIGN.md](DESIGN.md)：问题定义、实测结论、已定决策的 FAQ、未决项。
见 [spec/trace-v1.md](spec/trace-v1.md)：留痕数据的落盘格式。

已经实测确立的地基（`experiments/` 可复现）：Claude Code 的 hook 在 **desktop app
下正常触发且热加载**，stdin 直接给出 `transcript_path`。这决定了工具选型的硬约束——
只要不用「进程包装型」的方案，开发者用 CLI 还是 desktop 都留同样的痕，**不必强制二选一**。

## 边界

本项目只出**工具**。**留痕数据**落在被观测的那个仓里（`<repo>/.claude/trace/`），
随代码走——数据离开它描述的代码就失去价值。首个观测对象是 agentDock，
但本项目不属于它，也不假设只服务它。
