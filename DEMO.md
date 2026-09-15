# vibetrail 演示：安装 → 采集 → 看本地数据

> 2026-09-15。现在只落本机，push 还没做。原理与取舍见 [DESIGN.md](DESIGN.md)。

## 1. 先在沙箱里看一遍（不碰真实环境）

```bash
bash experiments/collect-demo/demo.sh
```

在临时目录里装一次、回放一段示例会话（含一次提交、一次被拒、一轮被别的 Stop hook 拦停后补完），最后打印采到的事件和沙箱路径。
沙箱里的数据在 `<沙箱>/home/.vibetrail/spool/`。真实的 `~/.claude`、`~/.vibetrail` 都不动。

## 2. 在自己机器上装

在要采的仓里跑一次（会顺手登记这个仓，它的所有 worktree 都算）：

```bash
cd /Users/gupengfei/program/code/vibetrail
bash tools/vibetrail init
```

| 写到哪 | 是什么 |
|---|---|
| `~/.claude/settings.json` | 加 12 个 hook 条目（命令里带 `vibetrail-hook`），别的设置原样保留 |
| `~/.vibetrail/backup/` | 改 settings 之前的备份 |
| `~/.vibetrail/bin/` | 运行时 |
| `~/.vibetrail/config` | scope（默认 project，只采登记过的仓）、jq 路径等 |
| `~/.vibetrail/projects/` | 登记的仓 |

被观测的仓里什么都不写。要多采一个仓：在那个仓里跑 `~/.vibetrail/bin/vibetrail projects add`。

## 3. 采集

在登记过的仓里正常用 Claude Code，desktop、CLI 都行。settings 热加载，已经开着的会话从下一句话起就采。

## 4. 看采了什么

```bash
~/.vibetrail/bin/vibetrail show
```

按会话、按时间一行一条。其他看法：

```bash
~/.vibetrail/bin/vibetrail list
```

```bash
~/.vibetrail/bin/vibetrail show --json
```

`list` 列出每个文件的位置、条数、大小；`show --json` 输出原始协议事件，也可以 `--session <会话 id 前缀>`、`--type turn` 过滤。
想马上看到本仓以前的会话（装之前开的那些），跑 `~/.vibetrail/bin/vibetrail sync` 补采一遍；平时下次开会话时会自动补。

**数据文件在** `~/.vibetrail/spool/<项目目录名>-<hash>/<会话 id>/`，每个文件是一次 hook 产出的一块，文件名 `<UTC 时间>-<pid>-<来源>.jsonl`，
来源是 `hook-<事件名>`（hook 当场给的）、`main`（解析主会话 transcript 得出的）或 `agent-<id>`（子 agent 的 transcript）。每行一条 paas-coding-hook 协议 1.0 事件，直接 `cat` 就能看。
这就是将来要 push 的全部内容：分歧事件带被拒的命令、被打断的回复、之后人的下一句，其余只有元数据。

| 什么时候 | 出现什么 |
|---|---|
| 会话开始 | `session.start`（来源、model、HEAD） |
| 说一句话 | `turn.start`（HEAD、分支、有没有改动） |
| 模型答完 | `turn.end`（状态、token 用量、本轮的 commit）。同一块里还有这一轮的调用 trace：每次模型调用一条 `message.assistant`（不带正文：model、token、stop_reason、调了哪些工具）、每次工具调用一条 `tool.end`（工具名、成功 / 出错 / 取消、耗时）；以及分歧事件：`permission.decision`（拒绝）、`tool.request`（被拒的命令）、`message.user`（之后人说的话） |
| 子 agent 起止 | `subagent.start` / `subagent.end` |
| 工具失败、权限弹框、CLAUDE.md 加载 | `ext.claude.*`，只有事件头 |
| 会话结束 | `session.end` |

## 5. 生成一份 markdown 报告（只供测试、演示）

```bash
bash experiments/collect-demo/report.sh
```

把采到的事件分三块整理成 `~/.vibetrail/report.md`：每一轮的全量数据（起止、用时、状态、token、模型 / 工具调用次数、HEAD 起止，每个会话下面折叠着逐次调用的 trace）、人机分歧（谁、对哪次调用、原文、之后人说了什么）、
commit ↔ 会话（每个提交归到哪个会话哪一轮，提交说明现从本机 git 查）。`-o -` 打到终端，`--session <前缀>` 只看一个会话。这个脚本不装进产品，上线用不到。

## 6. 自检与卸载

```bash
~/.vibetrail/bin/vibetrail doctor
```

```bash
~/.vibetrail/bin/vibetrail uninstall
```

卸载只去掉 settings 里自己的条目和运行时，已采的数据、配置、登记表留着；加 `--purge` 连 `~/.vibetrail` 整个删掉。

## 演示时要说清楚的

- **按停止打断的那一轮**，turn.end 要等下一个 hook 才写：打断没有 hook，desktop 里实测按停止什么 hook 都不来。
- **按停止打断正在跑的工具**，现在会被记成「拒绝」：Claude Code 写进 transcript 的与在权限框里点拒绝一模一样。区分方案待定（[OPEN-ISSUES](OPEN-ISSUES.md) K7）。
- **还没有 push**：数据只在本机 spool，端点配置之后才会发。
