# 审计遗留问题（2026-09-08）

> 三轮审计（一轮自审 + 两轮独立 agent）里**发现了但没有动**的问题。与另几份文档的分工：
> [DESIGN.md §5](DESIGN.md) 记设计层未决项（O1–O7），本文记审计遗留——待核的数字、
> 单方面定下需要确认的决策、已知未修的缺口。**修掉一条删一条，本文为空即可删除。**
>
> 每条写四样：在哪、现状、为什么没动、要动需要什么。

## A. ~~需要在有 agentDock 与语料的机器上重数的数字~~ —— 已解决（2026-09-09）

在有 agentDock 与完整语料的机器上重数完毕，**四组全部不是统计错误**：

| 原记 | 结论 |
|---|---|
| 402 次调用 vs 570+18=588 | **两种口径**：含 `mark-audit.sh` 的 Bash 命令 **405 条**，`mark-audit.sh` 出现 **619 处**（一条命令可含多处）。承重的是「带显式 sha 仅 18 处」，未变 |
| 可恢复性表合计 304 ≠ 294 | **表格结构错**：10（显式 sha）与其余三行**不互斥**，是横切的另一次测量。互斥划分 123+48+123=294。已重排 |
| 637 vs 294 | **口径未写明**：637 = 294 `*.audit.done` + 292 `*.crossverify.done` + 51 `*.commentaudit.done`。已加口径说明 |
| 53+39=92 ≠ 90 | **旧提取器漏计 2 条**——数组形态的 `is_error.content` 锚定永不命中（即本次审计修的铁律五）。新版重测 92，与分项一致 |

**一条比数字更重要的教训**：语料是**活的**。同一批量 09-08 测 402/277/90，09-09 测
405/282/92——我们工作时它一直在增长。**所有语料级数字必须带测量日期**，
已在 DESIGN.md D3 与 CAPABILITIES.md §2.2 加注。

2026-09-09 重测的完整口径与命令见 DESIGN.md D3 的口径说明。


## B. 我单方面定的、需要确认的决策

1. **空 patchId 的读方语义 = 告警并放行**（[spec §4](spec/trace-v1.md)）。merge commit 与
   `--allow-empty` 的 patch-id 是空串；原文只说写方跳过，读方（Stop 闸门）怎么办没写。
   我定为放行，理由是拦住会把 agent 卡死在一次 `merge --no-ff` 之后。
   备选：为 merge 定义退化锚（`diff-tree -m` 取第一父的 id）；或读方拦截、强制人工确认。
2. **编辑器路径不注入 trailer**（spec §2.0）。这是空消息守卫的副作用：`git commit` 不带 `-m`
   时 hook 跑在编辑器之前，消息尚空。agent 从不开编辑器，人在带变量的 shell 里手工提交因此
   不会被误记，方向对；但若将来 agent 走编辑器路径（如 `-t` 模板为空），也不会有 trailer。
   备选：去掉判空守卫，接受 `-m ''` 与留空的 `commit -v` 会被 trailer 填成非空提交。
3. **删掉提取器第 5 条规则 `user_edited_after_agent`**。按 spec §3.1「已删除的 kind」这个既定
   决定收口。备选：保留为哨兵——若某个客户端真把 `userModified` 置真，命中本身就是情报。
4. **`.gitattributes` 须声明 `.claude/trace/**/*.jsonl merge=union`** 已写进接入清单
   （CAPABILITIES §3.4、spec §1.1）。这是对被观测仓的新要求，agentDock 还没加。
5. **删掉了 DESIGN §1 的 `.gitignore:9` 引用**。原文说它「排除 `.claude/projects/`」，但
   transcript 在 home 目录、仓库 .gitignore 管不到，因果不成立。若原作者另有所指，请补回并写清。

## C. 已记为已知、但没修的缺口

1. **hook 只存在于 spec §2.0 的代码块里，没有成文件。** 三轮审计的三条高危全出在这段 hook 上，
   它已经过 11 个场景实测，但一旦有人从 markdown 里抄漏一行就回到原点。
   建议：`tools/prepare-commit-msg` 入仓，bootstrap 脚本负责复制到 `<repo>/.githooks/`、
   `git config core.hooksPath .githooks`、写 `.gitattributes`；回归测试里加一条
   「spec 代码块与文件逐字一致」。属 DESIGN O7 的范围，这轮没做。
2. **提取器重复计数未去重**（CAPABILITIES §3.3）。去重方案已定（同 sid + 同 kind + ≤10 秒，
   靠 `isSidechain` / `agentId` 区分层级），但 `hit` 里还没输出这两个字段，去重也没写。
3. **`tool` 字段（被拒的工具名）未产出**（spec §3）。可从
   `Permission to use (\S+)` 捕获，属可选字段、不升版本。
4. **归属语义的三处不一致未定**（spec §7）：`cherry-pick -n` 之后的 commit 与 `revert` 按
   执行者记；agent amend 人工 commit 记成 agent。都实测过、都写明了，但「该不该这样」没定。
5. **空消息守卫假设 `core.commentChar` 为默认的 `#`**。改了注释符的仓，判空与 scissors 截断都失效
   （退化为不判空，不是崩溃）。
6. **`is_error` 块 content 的数组形态在语料里有多少，未量。** 本机非 error 的 `tool_result` 里
   有数组形态，所以形态真实存在；提取器已能处理，只是修复前漏了多少不知道。
7. **召回率的基线是无锚子串候选集**（spec §3.2），绝对召回没测；`permission_denied` 那行的
   「人工核对候选集」口径没记下来。
8. **`.meta.json` 字段集随版本变**：2.1.85 两项、2.1.202 三项、2.1.260 四项（多 `spawnDepth`）。
   将来写 `end.subagents` 时要按缺失容错，别假设某个字段一定在。

## D. 三轮审计的方法教训

- **自审一条高危都没抓到，三条全是独立 agent 用实验抓的。** 自己改过的东西看不出盲区；
  「修完再起一个新 agent 从头审」应当成固定流程。
- **hook 类断言必须逐场景实测**，尤其是「某事不会发生」（人工 commit 不会被记成 agent 的）。
  这次的三条高危分别藏在 rebase 重放、merge 的非编辑器路径、trailer 块的段落规则里，
  读代码看不出来。
- **模拟「人工操作」时要 `env -u CLAUDE_CODE_SESSION_ID`。** agent 的 shell 自带这个变量，
  不去掉则「人工提交」全是假的——我第一次验证 hook 就是这样把一轮实验全污染了。
