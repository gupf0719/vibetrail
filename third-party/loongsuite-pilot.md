# LoongSuite Pilot 项目分析

> 三方项目分析，**不是**本项目的一部分。配套文档：
> [loongsuite-pilot-collection.md](loongsuite-pilot-collection.md)（采集清单：采什么、落哪、什么出本机）、
> [teamai-cli-vs-vibetrail.md](teamai-cli-vs-vibetrail.md)（与 teamai-cli、本项目的三方对比）。
>
> 扫描对象：`/Users/gupengfei/program/go/src/loongsuite-pilot`，HEAD `d4ab8b6d`（2026-09-08）。
> 本文所有数字均来自该快照，**引用请带这个日期**——它是个高频迭代的仓：快照前 30 天（08-09 至 09-08）148 个 commit。
> 全部读码所得，本机未装，无实机数据可对照。

## 0. 一句话

**把 21 家 AI Coding Agent 的活动，统一成一套 OpenTelemetry GenAI 事件，送到你指定的地方。**

它是**采集器**，不是分析工具。README 自述「面向 AI Coding Agent 的本地遥测采集器」，
它列出要回答的问题全是「哪些 Agent 在用」「发生了哪些调用」「数据送哪去」——
**没有一个是价值判断**。这一点决定了它和 teamai 的根本分野：teamai 读会话是为了判断「这次值不值得
写成经验」，Pilot 读会话是为了「原样搬运」。

对本项目的意义：它是三方里**采集范围**最宽的（扫子 agent、拿 system prompt、取到的字段零截断），
但会在记录层静默漏东西：没等到真实回复的整轮连 prompt 一起丢，轮末的中断记录几乎全丢（采集清单 §1.2b 实测）。
它也**不做分歧判定**：`cancelled` 在不少链路里出现，只是 turn 或工具的终止状态，没有分歧的分类；
Claude Code 链路连「中止」这种终止状态都没有。详见对比文档 §1。

## 1. 基本盘

| 项 | 值 |
|---|---|
| 归属 | Alibaba 开源（`alibaba/loongsuite-pilot`），**Apache-2.0** |
| 发布 | npm 包 `loongsuite-pilot` + 阿里云 OSS 托管的 `installer.sh` / `.ps1` + GitHub Release |
| 版本 | **工作树的 `package.json` 停在 1.2.0**（最后改动 2026-08-14），最新 tag **v1.8.0**（2026-09-09，commit `280e3d51`，是 HEAD 的直接子提交）。v1.3.0–v1.8.0 的版本号只存在于 `release/*` 分支的发布提交里——**按工作树的 package.json 判断版本会错 6 个小版本** |
| 规模 | `src/` 非测试 TypeScript **210 文件 / 61,154 行** |
| 测试 | 全部在 `tests/`（`src/` 内 0 个测试文件）：**342 文件 / 99,966 行**，3,899 个 `it`/`test`、747 个 `describe`。测试:实现 ≈ **1.63:1** |
| 历史 | **376 commit / 29 贡献者**，首提 **2026-06-09**（三个月的项目），快照前 30 天 148 个；月度 76→119→142→39 |
| CHANGELOG | **无**。发布说明靠 `gh release --generate-notes` |
| 形态 | 单个 npm CLI（`loongsuite-pilot`）+ 常驻 daemon + 本机 Dashboard（默认 `127.0.0.1:8765`） |
| 工具链 | esbuild 0.28（5 个入口，非单文件）、`tsc --noEmit` 只做类型检查、vitest 1.6.1 |
| 支持 Agent | `agents.d/` 下 **20 个** JSON 定义 + Wukong（纯 TS，无 JSON）= 21 家；README 与 docs 列 21–22，见 §6 末尾 |

三个月、376 commit、29 人、近 10 万行测试——这是个投入很重、推进很快的项目。
`fix:feat = 181:82`（约 2.2:1）说明**大部分工程量在补真实故障，不在做功能**，这与「对着 21 家
第三方 agent 做适配」的处境一致：每家的落盘格式、hook 机制、版本兼容都得单独伺候。

## 2. 数据流：部署一条线，采集一条线

仓里没有 `ARCHITECTURE.md`，最权威的描述是 `AGENTS.md:73-84` 的依赖图。实际代码里是两条线：

```
部署线   agents.d/*.json → DeploymentManager → 按 deployMode 装 hook / 插件 / patch
采集线   AgentDiscoveryService → InputManager → 各 Input 实例（归一化在 Input 内部完成）
                                     ↓
                              10 步串行管线
                                     ↓
                              MultiFlusher 扇出到 4 个 sink
```

10 步管线在 `src/core/input-manager.ts:333-431`，顺序是：
git 富化 → 计数 → TraceLinker → invocation identity → turn boundary → **content policy** →
**掩码** → 事件展开 → 字节计量 → dispatch。

内容管控（`captureMessageContent`）和脱敏（`mask`）是管线里两个独立的步骤——
这个两层模型是它设计上最值得借鉴的一处，见采集清单 §6。

四个 sink：`jsonl` / `sls` / `http` / `otlp-trace`（`src/flushers/`，其余 8 个文件是
transport、编解码、失败落盘）。

**另有一条完全独立的旁路**：`PipelineManager`（`src/pipeline/pipeline-manager.ts:16-78`）走
LoongCollector 式的 `input_file → flusher_sls`，**不经归一化，也不经掩码**；Qoder 组织 API 那条链路也挂在它下面
（[采集清单 §5.5](loongsuite-pilot-collection.md)）。它**默认关**：`pipeline.enabled` 默认 `false`
（`src/core/config-loader.ts:676-691`、`src/core/orchestrator.ts:335-347`），开了之后按
`configs/local/` 下的配置采指定文件或拉 Qoder 组织 API，不是 agent 会话。
读这个仓时容易漏掉它——两条路都能把数据送到 SLS，但只有主线受内容策略约束。

`src/` 20 个顶层目录，行数集中在 `inputs/`（21,607）、`deployment/`（6,714）、`core/`（6,477）、
`flushers/`（4,012）、`pipeline/`（3,699）。三分之一的代码在适配各家 Agent 的输入格式。

## 3. 功能清单

### 3.1 接入：六种 deployMode

dispatch 在 `src/deployment/deployment-manager.ts:338-355` 的 `switch (def.deployMode)`：

| 模式 | 数量 | 做法 | 代表 |
|---|---:|---|---|
| `hook` | 13 | 写进 agent 自己的 settings 文件 | claude-code、cursor、codex、qoder 系、qwen 系、workbuddy |
| `plugin-inject` | 4 | 往宿主 config 里塞 plugin spec | opencode、openclaw、mimo-code、pi-coding-agent |
| `directory-plugin` | 1 | 拷插件目录 + CLI 激活 | hermes-agent |
| `dsh-yaml-patch` | 1 | 带 marker 的 YAML 块追加 | dsh |
| `detection-only` | 1 | 只探测不写 | qoder-jetbrains |
| `plugin-probe` | 0 | 策略代码在，OSS 无定义使用（`src/inject-hooks.ts:44-46`） | — |

### 3.2 采集与归一化

统一到 OpenTelemetry GenAI 语义（`docs/zh-CN/output-event-schema.md`），
8 种 `event.name`：`llm.request` / `llm.response` / `tool.call` / `tool.result` / `skill.use` /
`tool.approve` / `agent.input` / `other`，四类核心事件对齐 GenAI audit-event 规范。

三级会话标识 `gen_ai.session.id` / `turn.id` / `step.id`，加 W3C `trace_id` / `span_id` / `parent_span_id`。
字段的必填程度沿用 OTel 分级，敏感内容一律标 `Opt-In`。

采到什么、有没有截断、什么出本机，全部在
[采集清单](loongsuite-pilot-collection.md)，本文不重复。

### 3.3 输出与控制面

| 面 | 能力 |
|---|---|
| 输出 | JSONL（默认开）、SLS（三种鉴权）、HTTP、OTLP Trace；可同时多目标 |
| 准入 | `agent-control.json` 每个 agent `on` / `off` / `auto` |
| 内容 | 按 agent 的 `captureMessageContent` |
| 脱敏 | `mask.mode` = `none`（默认）/ `all` / `custom`，9 类规则 |
| 多模态 | 按 agent 的 `uploadMode`，图片转对象存储 uri（仅 Codex / Qoder 实现） |
| 保留 | 7 类 `retention`，默认各 7 天，带容量水位 |
| 运维 | `status` / `info` / `restart`，本机 Dashboard，版本回滚 |

### 3.4 三个容易漏掉的目录

- `openspec/` —— OpenSpec 规范驱动开发目录，只有 1 个 change、4 个文件，已完成未归档。
  被 `.gitignore:62` 忽略却强制入库了。
- `solutions/` —— 一个 SLS 看板交付工作区（72 文件，含两套 skill 与两个案例）。
- `assets/skills/loongsuite-pilot-ops/` —— 给 AI agent 用的中文运维 Skill（SKILL.md 354 行 +
  18 个 references 共 4,359 行），随包分发并由 postinstall 拷到 `~/.loongsuite-pilot/skills/`。

前两个都不进 npm 包（`files` 只有 `dist/ assets/ scripts/ agents.d/`）。

那个运维 Skill 里有一条值得单拎出来：`SKILL.md:103-126` **明令禁止 agent 代执行含 AK/SK 的安装命令**，
只允许免凭证的 WebTracking 变体。**这是把凭证边界写进了给 AI 看的指令里**——在「让 agent 帮你运维」
逐渐普及的当下，这个做法本身值得记一笔。

## 4. 值得细看的实现

### 4.1 半声明式：部署是 JSON，采集是硬编码

`agents.d/*.json` 看上去是完整的插件式接入点，`README.md:104` 也说「You can add new agents without
changing the deployment framework」。**只对部署侧成立。**

JSON 里的 `input` 块是**死元数据**：`AgentInputConfig` 全仓只在 `src/types/deployment.ts:144,256`
出现，没有任何代码读取它；30 个 input 全部硬编码注册在 `src/core/orchestrator.ts`。
`docs/agent-onboarding.md:63-72` 自己列明了新增一个 agent 需要六项：agents.d 定义、hook / 插件 / 轮询源、
Input 实现、ClientType、启动路径注册、测试——JSON 只是六项之一。

所以 README 那句容易被读成「纯 JSON 接入」，实际不是。Wukong 更直接——**根本没有 agents.d 文件**，
纯 TS（`orchestrator.ts:1557`）。

### 4.2 「不猜测」是落到代码的规则，不是口号

这是全仓最一致的一条工程价值观，而且每处都写了**为什么**：

| 场景 | 做法 | 出处 |
|---|---|---|
| 未知 `finish_reason` | **丢弃**，而不是降级成 `stop` —— 猜成 stop 会让 turn 提前 flush 把 trace 打碎 | `src/normalization/finish-reason.ts:38-41` |
| source 不暴露 `cache_creation` | 留空，不写 0 | `qoder-trace/token-enricher.ts:354` |
| scope / key 不唯一 | 整个不打 session key | `otlp-trace-flusher.ts:1343-1347` |
| 从文件路径推 agent 身份 | **明确禁止**，并解释现有那处能工作纯属 `-cn/` 子串巧合 | `qoder-cn-trace/sqlite-token-reader.ts:109-114` |
| 字节计量 | 带 `bytes_basis`（measured / estimated），注释：「估算行适合看趋势，不适合计费」 | `metrics-collector.ts:186-189` |

对比文档 §3 记过 teamai 在判据上「够用就停」的取舍。Pilot 这套「宁缺毋滥」是另一种取向——
它不判分歧，但凡是它给出的字段，它不愿意填一个猜的值。

### 4.3 注释记录真实事故，而且写症状

好注释的密度很高，特点是**连观测到的症状一起写下来**，方便未来只有症状的人 grep 到：

- `src/utils/data-dir.ts:4-15` —— 三处各自抄了一份 dataDir 优先级链，靠注释保持同步；
  一句「**A comment is not a mechanism**」，然后说明 drift 之后 `isHookInstalled` 会把所有 hook
  判为未安装并重复追加。现在靠测试断言两边一致。
- `src/native-deps-guard.ts:1-23` —— sqlite3 在 musl 上加载失败导致 daemon 启动即死，
  而这个崩溃「**invisible twice over**」：发生在 `initFileLogging` 之前，且 spawner 把 stderr 重定向到
  `/dev/null`，用户只看到「没有遥测」。
- `src/utils/win-archive.ts:5-26` —— 两个 Windows 陷阱，连原始报错字符串都抄了下来，
  末尾一句「Never pass `--force-local` to bsdtar」。
- `src/deployment/deployment-manager.ts:322-327` —— 返回 `{success:false}` 的策略以前被吞掉，
  「`deployAll complete {failed:1}`」就是 dsh 每轮失败的全部记录。
- `assets/hooks/claude-code-fetch-intercept.mjs:20-22` —— 「滑动窗口正则先试过，会静默损坏长 preamble
  ——**不要改回去**」。

「把 keep-in-sync 的注释换成测试」这个模式在仓里重复出现（`finish-reason.ts:7-8`、
`inject-hooks.ts:163-164`）。这是被真实故障教过的痕迹。

### 4.4 watchdog 自愈：能力与介入边界

`src/core/hook-watchdog.ts`（本节无前缀行号都指它）默认每 5 分钟检查一次（`src/core/config-loader.ts:658-669`），
修复被删掉的 settings hook 条目、插件配置、shell rc 拦截块等。两类目标的规则不一样，别混：

| 目标 | 怎么判健康 | 修复节奏 |
|---|---|---|
| settings 里的 hook 条目（hook 模式各家，Grok 除外） | 每个事件下有没有一条命令含它的脚本名（marker 子串，`:447-476`） | 两次至少隔 10 分钟，**不设每日上限**（`:388-411`） |
| 「拦截类」目标：shell rc 块、Qoder Work 的 launchctl / Windows 环境变量、Grok 的 hook 文件、插件注入 / 目录插件 / DSH 的配置 | 各自的 `check()`；rc 块另按**内容**（`signature`）判是不是旧版，旧版就迁移（`:889-904`） | 10 分钟冷却，且**每天最多 3 次**（`:16,551-611`） |

克制的部分在拦截类目标上：每日上限让它不会和用户的手工删除无限对抗（计数只在内存里，按 UTC 日期清零，
daemon 重启也清零，`:615-621`）；在 `config.json` 里把某个 agent 的 `agents.<id>.enabled` 设为 `false`，
它还会顺手把 rc 块等清掉（`:556-573`）。settings 里的 hook 条目没有上限——用户手工删掉，几分钟到十几分钟内
就会回来，除非同样把这个 agent 关掉。

但要清楚它的介入面比 teamai 大一档：

| | teamai-cli | LoongSuite Pilot |
|---|---|---|
| 改 agent settings | ✅ | ✅ |
| 改 shell rc（`~/.zshrc` / `~/.bashrc`） | ❌ | ✅ 追加覆盖 `claude`、`qodercli`、`qoderclicn` 命令的 shell 函数，对应 agent 启用且 hook 脚本在时才加（只在文件已存在时，`:914` 「never create rc files」；README 与 docs 零提及） |
| 注入进 agent 进程 | ❌ | ✅ `BUN_OPTIONS --preload` |
| 改用户即将执行的命令 | ❌ | ⚠️ 可选，默认关：`upstreamLink.enabled` 与 `propagateToTools` 都开，且有可传播的上下文（环境里的上游 `TRACEPARENT`，或另开 `generateTraceWhenMissing`）时，Bash 命令前拼 `export TRACEPARENT=...`；Claude Code 进程带着 `LOONGSUITE_PILOT_RESOURCE_ATTRIBUTES` 时还会拼 `export OTEL_RESOURCE_ATTRIBUTES=...`，这一路不需要 trace 上下文 |
| 装 git hook | ❌ | ❌（但定义了类型，见 §6） |

teamai 的边界是「只用 harness 生命周期 hook，不碰用户的 git、不碰用户的 shell」
（[teamai-cli.md](teamai-cli.md) §4.4）。Pilot 为了拿到更完整的链路，选择进入被观测者的执行路径。
**这是能力换介入，不是谁对谁错**——但用之前应该知道装了什么。

### 4.5 开源版与闭源版的分叉 —— 以及唯一没被 stub 掉的那个

`build.mjs:10-27` 的 `internalStubPlugin` 在非 `BUILD_MODE=proprietary` 时，
把 `alarm-sender.internal` 与 `statistic.internal` 替换成空函数。仓里只有这两个模块的 `.d.ts`，
没有实现——**存在一个能力更强的闭源分支**。

真正要看的是 `src/internal/sender.ts:7-19` 的二选一：

```javascript
if (PROPRIETARY_BUILD) {  用 ./alarm-sender.internal.js + ./statistic.internal.js  }
else                   {  用 ./alarm-sender.js        + ./statistic.js            }
```

stub 插件 filter 的是 `.internal`，而**开源构建根本不 import 那条分支**。开源版走的是同目录的
另外两个文件，它们的实际内容是：

- `alarm-sender.ts` —— `sendAlarm` 与 `sendStatus` **都是空函数**。
- `statistic.ts` —— **真实现**：daemon 每次启动时发一条、之后每 12 小时一条，向固定的阿里云 SLS
  （`loongsuite-community-edition` / `loongsuite-online`）POST `pilot_running_status`，
  含 `ip`、`hostname`、`os_detail`、`version`、`cpu`、`mem`、`instance_id`、`metric_json`。

**告警和状态上报在开源版都被清空了，唯独留下了这一条。** 无条件调用（`metrics-writer.ts:177`），
无 opt-out，README 与 docs 零处提及——代码注释倒不讳言，`src/core/orchestrator.ts:349` 写着
「→ local JSONL + remote via sender.ts」。详细字段与 `instance_id` 的可逆性见
[采集清单 §3.5](loongsuite-pilot-collection.md)。

## 5. 工程质量观察

**好的：**

- **测试量真实**：99,966 行测试 vs 61,154 行实现（1.63:1），3,899 个用例。e2e 分两级，
  L2 需要真实环境——真 SLS project/AK、各家 agent 的真 API key（`.env.e2e.example:14-38`）。
- **降级路径分得清**：fail-open 是默认，但有例外且都写了理由——`single-instance-lock.ts:241`
  明确 fail closed，`win-archive.ts:187` 明确故意致命，`deploy-command.ts:128-132` 明确不吞上报错误。
- **容量上限到处是硬常量**：file-tailer 4 MiB / 100 文件 / 队列 20；multimodal 10 parts / 30 MiB /
  1 GiB pending；日志保留 2 GiB。背压时**不推进窗口**以便下轮重采（`qoder-api-pipeline.ts:163-165`）。
- **幂等与去重成体系**：Codex、Qoder Work SQLite 等轮询类输入用确定性 `event.id`（sha256；Qoder API 是同样确定性的
  `event_id`）；Qoder IDE 两个输入另有 7 天 highWatermark 快照（`src/checkpoints/`，经 `base-ide-input.ts`）；
  Claude Code 这类 hook 链路的 `event.id` 是 `randomUUID()`，幂等靠 transcript 的字节 offset；marker 块增删幂等；
  auth 失败直接熔断停止轮询。
- **CI 有安全意识**：secret-scan 用 gitleaks，pin 了 action SHA 与二进制 SHA256
  （`.github/workflows/secret-scan.yml:21-27`）。
- `src/` 下 **TODO / FIXME / HACK / XXX 为 0**；近 30 个 commit 里 26 个是 PR 合并。

**需要留意的：**

- **未声明的主机指纹回传**（§4.5）。这是本次扫描分量最重的一条。
- **覆盖率阈值的适用面被悄悄收窄**：80% 的四项阈值只作用于
  `src/inputs|checkpoints|normalization|flushers|core`（`vitest.config.ts:13-30`）。
  `deployment/`（6,714 行）、`updater/`、`pipeline/`、`multimodal/` **都不在内**——
  而 `deployment/` 正是往用户机器上写东西的那部分。
- **出站脱敏兜底是死代码**：`endpoint.redact` 全仓硬编码 `false`，
  `redactCodeGenerationFields()` 永不执行（采集清单 §5.1）。
- **内容策略有两份清单且不一致**，且都漏了 `error.message`（采集清单 §5.2 / §5.3）。
  同一个语义分散在两个文件手工维护——正是 `data-dir.ts` 那句「a comment is not a mechanism」
  批评过的模式，只是这次没有测试守着。
- **保留策略按类别映射而非按目录枚举**，导致写在日志根目录的那几家（Claude Code 在内）含完整对话正文的
  `logs/<agent-id>/*.jsonl` 永不删除；写在 `history/` 子目录的六家和自己清理的 Hermes 不受影响（采集清单 §2.4）。
- **卸载目标是手工维护的重复清单，好在有测试兜着**：`deploy/installer-opensource.sh:2268-2280` 硬编码 11 个
  配置文件路径，Grok 另写一段（`:2347-2403`）；`tests/unit/deploy/installer-uninstall-cleanup.test.mjs:159-179`
  从 `agents.d/` 推出全部 hook 配置路径，逐个断言两个安装脚本里都出现过——只查字符串在不在，但漂移会报错。
- 零碎的：143 处 `homedir()` / `~` 路径拼接；`cursor-cli` 名义上是 hook 模式但 `events: []`
  实际不写文件；`package.json:30` 声明 `types: dist/index.d.ts` 但 build 只跑 esbuild 不产 `.d.ts`；
  根 `SKILL.md` 是**没填的模板占位符**（`:14-16` 仍是 `# TODO: Add quick start commands`）却随仓库分发。
- **文档与代码的六处偏离**见 §6 末尾。

## 6. 它明确不做什么（全部 grep 核实）

| 能力 | LoongSuite Pilot | 依据 |
|---|---|---|
| 分歧信号判定 | ❌ 无 | Claude Code 链路的 `STOP_REASON_MAP`（`assets/hooks/claude-code/message-converter.mjs:20-30`）9 个 key 归到 5 个值，没有「用户中断」；被打断时写下的 `[Request interrupted by user]` 大多根本不进事件（采集清单 §1.2b 实测 265 条进了 5 条）。`cancelled` 在不少链路里出现，来源和用途都不一：有的照搬宿主记下的中止（Codex 的类型化 `turn_aborted`、Grok、DSH、OpenClaw 等），有的是 Pilot 收尾时自己补的（WorkBuddy、MiMo Code，Codex 的子 agent 也有），Wukong、Hermes 只拿它标工具结果，Qoder 只在白名单里预留。都不是分歧分类 |
| commit ↔ session 关联 | ❌ 未实现，但**设计过** | 见下 |
| 装 git hook / 改 `core.hooksPath` | ❌ 无 | 全仓 grep `core.hooksPath` / `.git/hooks` / `pre-commit` / `post-commit`，仅命中下面那个死类型 |
| 往 commit 里写 session id | ❌ 无 | 无 `git commit` / trailer / amend 相关代码；git 交互只有 `src/utils/git-context.ts:68` 一处 `execFile`，**只读** |
| 代码审计 / code review | ❌ 无 | grep `code.?review` / `审查` / `评审` / `审计` / `audit` / `sast` 在 `src/` 与 `agents.d/` **零命中** |
| 读工作区源码内容 | ❌ 无 | 所有 `readFile*` 目标是配置、状态、锁、pid、自身日志、各 agent 会话记录；工作区只取路径与 git 元数据（`src/normalization/global-attributes.ts:11-15`） |
| 团队知识分发 / 知识库 | ❌ 不做 | 与 teamai 的主业完全不重叠 |

**`GitHookEvent` 是本次扫描里最有意思的一处「不做」：**

```typescript
// src/types/events.ts:190-200
/**
 * Git hook event from post-commit / pre-push hooks.
 */
export interface GitHookEvent {
  eventType: 'post-commit' | 'pre-push';
  repoRoot: string;
  commitHash: string;
  branchName: string;
  changedFiles: string[];
  timestamp: number;
}
```

**全仓零引用**，没有任何实现。但这个形状——`post-commit` / `pre-push` 事件带 `commitHash` 与
`changedFiles`——正是「commit ↔ session 关联」需要的东西。

也就是说：三方之中有一方**识别到了这个需求并写下了类型**，然后停在这里。
这比「没人想到」有意思得多，见对比文档 §5.1。

---

**文档与代码的六处偏离**（写在这里是因为读这个仓时会踩）：

1. `AGENTS.md:37` 指向 `src/file-collection/`，**该目录不存在**——已改名为 `src/pipeline/`。
   模块清单还漏了 `mask/`、`metrics/`、`multimodal/`、`local-workers/`、`pi-sdk/`、`internal/`、`hooks/`、`cli/`、`utils/`。
2. **支持 agent 数三处不一致**：`README.md:55-78` 列 22 个，`docs/agents.md:14-38` 列 22 个，
   `docs/overview.md:23-45` 列 21 个（是 README 旧拷贝，漏了 DeepSeek Harness），实际 `agents.d/` 只有 20 个文件。
   差额可解释（Wukong 无 JSON 定义、Qoder CLI 复用 `qoder.json`）。另外 `README.md:91-99` Windows 表管它叫
   「Qoder IDE」，主表和 `agents.d/qoder.json` 叫「Qoder」——是叫法不一，不是缺 id。
3. **两个被引用的文档不存在**：`docs/E2E-REMOTE-TEST-GUIDE.md`、`docs/EVENT_LOG_TO_TRACE_SPEC.md`。
4. `README.md:104` 的「无需改动部署框架即可新增 agent」只对部署侧成立，见 §4.1。
5. **中英文档已分叉**：`docs/zh-CN/` 独有三篇，英文独有三篇。
6. **版本自述失真**：见 §1。

需要说明的是**其余抽查过的 docs 数字是准的**（WorkBuddy 30 秒轮询对应
`config-loader.ts:597` 的 `pollInterval: 30_000`；Grok Build 四个 fail-open hook 对应
`agents.d/grok-build.json:11`）。docs 整体不算失修，偏离集中在目录重命名、agent 计数、版本这三处——
以及采集清单 §5 记的那几处内容策略描述。
