# vibetrail 演示：安装 → 选仓 → 采集 → 看本地数据

> 2026-09-16。现在只落本机，push 还没做。原理与取舍见 [DESIGN.md](DESIGN.md)。

## 1. 先在沙箱里看一遍（不碰真实环境）

```bash
bash experiments/collect-demo/demo.sh
```

在临时目录里装一次、登记一个演示仓、回放一段示例会话（含一次提交、一次被拒、一轮被别的 Stop hook 拦停后补完），
最后打印采到的事件、自检结果和报告路径。沙箱里的数据在 `<沙箱>/home/.vibetrail/spool/`。真实的 `~/.claude`、`~/.vibetrail` 都不动。

## 2. 在自己机器上装

在哪个目录跑都行，`init` 不会登记任何仓：

```bash
cd <vibetrail 仓的目录>
bash tools/vibetrail init
```

| 写到哪 | 是什么 |
|---|---|
| `~/.claude/settings.json` | 加 13 个事件的 hook 条目（命令里带 `vibetrail-hook`；只登记本机 Claude Code 都认识的事件），别的设置原样保留。写之前核对文件没被别人改过，写完自检，不对就自动还原 |
| `~/.vibetrail/backup/` | settings 的备份：`settings.json.before-vibetrail` 是第一次装之前的原样（只存一次、永不覆盖；原来没有 settings 就没有它），另外每次改动前存一份带时间的（留最近 10 份）。重跑 `init` 没有变化时不写也不备份 |
| `~/.vibetrail/bin/` | 运行时 |
| `~/.vibetrail/config` | scope（默认 project，只采登记过的仓）、jq 路径等 |
| `~/.vibetrail/projects/` | 登记的仓（`init` 不自动加） |

`init` 最后会列出登记表和「用过 Claude Code、还没登记的仓」。被观测的仓里什么都不写。

## 3. 选要采的仓

默认只采登记过的仓（连同它的所有 worktree），要采哪些你自己选：

```bash
~/.vibetrail/bin/vibetrail projects pick
```

列出你用过 Claude Code 的仓（✓ = 已登记，带会话数与最近活跃时间）。输编号登记，编号前加 `-` 去掉，比如 `2 -1` 是登记第 2 个、去掉第 1 个；直接回车不改。
也可以在要采的仓里跑 `projects add`；`projects list` 看登记表，里面标着每个仓 spool 里还有几块没发出去。

不再采某个仓：`pick` 里 `-编号`，或者：

```bash
~/.vibetrail/bin/vibetrail projects remove <仓的路径>
```

去掉后，它已采、还没发出去的数据默认还留在 spool，将来 push 时照样发。连这些也不要：加 `--drop`，数据挪到 `~/.vibetrail/removed/`，不再发，一天后自动删掉。

全都采（不看登记表）：`bash tools/vibetrail init --scope user`。

## 4. 采集

在登记过的仓里正常用 Claude Code，desktop、CLI 都行。settings 热加载，已经开着的会话从下一句话起就采。
装了或升级了 CLI 之后重跑一次 `init`：它按本机每个 Claude Code 版本核对能登记哪些事件，有版本不认识的事件会让那个版本把整份 settings 跳过。

## 5. 看采了什么

```bash
~/.vibetrail/bin/vibetrail show
```

按会话、按时间一行一条；模型调用那几行是元数据，比如「模型 claude-opus-5　入/缓存/出 11.9k/47.1k/317　tool_use → Bash　用时 6s」。其他看法：

```bash
~/.vibetrail/bin/vibetrail list
```

```bash
~/.vibetrail/bin/vibetrail show --json
```

`list` 列出每个文件的位置、条数、大小；`show --json` 输出原始协议事件，也可以 `--session <会话 id 前缀>`、`--type turn` 过滤。
想马上看到登记过的仓以前的会话（装之前开的那些），跑 `~/.vibetrail/bin/vibetrail sync` 补采一遍；平时下次开会话时会自动补。
空闲超过一小时的会话，补采时连最后一轮一起关掉；最近一小时内还在用的，最后一轮要等它下次答完（或空闲满一小时）才出 `turn.end`，不是漏采。

**数据文件在** `~/.vibetrail/spool/<项目目录名>-<hash>/<会话 id>/`，每个文件是一次 hook 产出的一块，文件名 `<UTC 时间>-<pid>-<来源>.jsonl`，
来源是 `hook-<事件名小写>`（hook 当场给的，如 `hook-userpromptsubmit`）、`main`（解析主会话 transcript 得出的）或 `agent-<id>`（子 agent 的 transcript）。每行一条 paas-coding-hook 协议 1.0 事件，直接 `cat` 就能看。
这就是将来要 push 的全部内容：分歧事件带被拒的命令、被打断的回复、之后人的下一句，其余只有元数据。

| 什么时候 | 出现什么 |
|---|---|
| 会话开始 | `session.start`（来源、model、HEAD） |
| 说一句话 | `turn.start`（HEAD、分支、有没有改动） |
| 模型答完 | `turn.end`（状态、token 用量、本轮的 commit、这一轮里插了几句话）。同一块里还有这一轮的调用 trace：每次模型调用一条 `message.assistant`（不带正文：model、token、stop_reason、调了哪些工具及其调用 id）、每次工具调用一条 `tool.end`（工具名、成功 / 出错 / 取消、耗时）、API 请求失败重试一次一条 `ext.claude.api_error` |
| 人拒绝一次工具调用 | `permission.decision`（decided_by user，注明是看权限框还是按权限模式分出来的）+ `tool.request`（被拒的命令），这一轮以「拒绝后停下」关；auto 模式的分类器拦下、权限链路故障也发 `permission.decision`，decided_by 分别是 policy、system |
| 人按停止打断 | `turn.end`（interrupted）+ 被打断的回复 `message.assistant` + 在跑的调用 `tool.request`；打断的是正在跑的工具时 kind 是 `interrupt_tool`（「按停止打断工具」） |
| 分歧之后人说的第一句话 | `message.user`，指回那次分歧 |
| 子 agent 起止 | `subagent.start` / `subagent.end`；压缩、起标题这类 Claude Code 内部 agent 只记 `ext.claude.subagent_stop`（internal） |
| 弹权限框 | `ext.claude.permission_request`（工具名、权限模式，不带参数）；用来分「人拒绝」与「按停止打断工具」 |
| 工具失败、分类器拦下、API 出错结束一轮、CLAUDE.md 加载、切换目录 | `ext.claude.*`，只有事件头 |
| 会话结束 | `session.end` |

## 6. 生成一份 markdown 报告（只供测试、演示）

在 desktop 里看要写进工作目录（它的文件查看器打不开 `~/.vibetrail` 下的文件；`out/` 不进 git）：

```bash
bash experiments/collect-demo/report.sh -o experiments/collect-demo/out/report.md
```

不带 `-o` 写到 `~/.vibetrail/report.md`，`-o -` 打到终端，`--session <前缀>` 只看一个会话。报告分三块：
- **每一轮的全量数据**：起止、用时、状态、token、模型 / 工具调用次数、HEAD 起止；每个会话下面折叠着逐次调用的 trace。
- **人机分歧**：类型（人打断、人拒绝、按停止打断工具，后两种注明依据）、谁、对哪次调用、原文、被打断的回复、之后人说了什么。
- **commit ↔ 会话**：每个提交归到哪个会话（完整会话 id）哪一轮、怎么推出来的，提交说明现从本机 git 查。

表里 8 位的 id 是会话 id、轮 id 的前 8 位。这个脚本不装进产品，上线用不到。

## 7. 自检与卸载

```bash
~/.vibetrail/bin/vibetrail doctor
```

```bash
~/.vibetrail/bin/vibetrail uninstall
```

`doctor` 查运行时、jq 版本与**映射器在这个 jq 上跑不跑得通**（拿一条假记录真跑一遍：jq 的语法错是整份文件级的，编译不过的话 transcript 那一路一条都不出，而 hook 仍然全部 exit 0）、hook 条目（包括命令指向的脚本在不在）、hook 有没有被全局开关关掉（`disableAllHooks` / 企业策略的 `allowManagedHooksOnly`）、有没有重复挂载（同一事件挂在 HOME 与项目两处会触发两遍）、登记表、有没有落后没采的会话、错误日志（映射失败单独点出条数）。
卸载只去掉 settings 里自己的条目和运行时，已采的数据、配置、登记表留着；加 `--purge` 连 `~/.vibetrail` 整个删掉。

## 演示时要说清楚的

- **按停止打断的那一轮**，`turn.end` 要等下一个 hook 才写：打断没有 hook，desktop 里实测按停止什么 hook 都不来。
- **按停止打断正在跑的工具**：Claude Code 写进 transcript 的与在权限框里点拒绝一模一样。现在单列成「按停止打断工具」：
  挂上 PermissionRequest 之后按这次调用弹没弹过权限框分，之前的按这一轮的权限模式粗分——auto 模式几乎不弹框，那里的「拒绝」按停止算（DESIGN D9）。
  desktop 里 PermissionRequest 会不会触发还没实测：要在 default 模式的会话里弹一次框、点一次拒绝。
- **desktop 续接会话**会把之前的历史复制进新会话文件，这部分会按新会话再报一遍（OPEN-ISSUES K8）；报告里已按记录合并显示，并注明「也在哪些会话」。
- **在别人公司的机器上演示**：企业托管设置（`/Library/Application Support/ClaudeCode/managed-settings.json`）里 `allowManagedHooksOnly: true` 会让 HOME 里的条目
  一律被忽略，用户设置里 `disableAllHooks: true` 则是所有 hook 都不跑（安全模式同理）。两种情况下 hook 一次都不触发，而且**看不出异常**——
  spool 不涨、也没有错误日志。先跑一次 `vibetrail doctor`，它会直接点名是哪份文件里的哪个键。
- **只采登记过的仓**：没登记的仓里开会话什么都不采；要采就 `projects pick` 选上。
- **还没有 push**：数据只在本机 spool，端点配置之后才会发。
