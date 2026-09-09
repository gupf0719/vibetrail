# vibetrail 全流程（详图）

> 概览在 [CAPABILITIES.md §2.0](CAPABILITIES.md)。本文逐步展开：每个节点对应一个脚本、
> 一道判定或一处落盘。实线已实现；唯一一条虚线是还没接上的一段（查询端尚未读 sessions 文件）。
> 圆柱是数据落点，三处里只有 transcript 不入仓。

五段：**接入**每个 clone 一次；**开发**时 Claude Code 自己写流水，并把会话 id 注入
每次 Bash 调用的环境；**提交**时 hook 把这个 id 写进 commit message；**投影**把流水里跨会话
仍有价值的部分固化进仓；**读取**按 sid 与 patch-id 把三处数据接回去——查询端答「这个 commit
是怎么来的」，闸门端答「这个 commit 审过没有」。

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TB
    subgraph S0["① 接入 —— 每个 clone 跑一次（git 不让仓库自动装 hook）"]
        IN["tools/vibetrail-install（幂等）<br/>hook 装进有效 hooks 目录<br/>主仓与全部 worktree 共享，装一次全覆盖<br/>.gitattributes 加 .claude/trace/**/*.jsonl merge=union<br/>建 &lt;repo&gt;/.claude/trace/{sessions,audits}/<br/>vendor 运行时到 &lt;repo&gt;/.claude/vibetrail/<br/>闸门不依赖没克隆的外部仓"]
        DR["接着跑 tools/vibetrail-doctor 自检<br/>失效全是静默的，不自检不会知道<br/>查 hook 装没装 · 与仓内版本一致<br/>core.hooksPath 被谁占 · 会话变量可见<br/>merge=union 在不在<br/>vendored 运行时与上游一致<br/>最近 N 个 commit 几个带归属"]
    end

    subgraph S1["② 开发 —— 一个 Claude Code 会话（CLI / desktop 留同样的痕）"]
        H(("人")) -->|"指挥；打断、拒绝工具调用<br/>分歧只落在对话侧<br/>不落在文件上"| CC["Claude Code"]
        CC -->|"持续写"| TR[("~/.claude/projects/&lt;cwd-slug&gt;/&lt;sid&gt;.jsonl<br/>每轮对话 · thinking · Edit 的 diff<br/>命令输出 · 子 agent 的 transcript<br/>真相源；不入仓、数百 MB、换机器即丢")]
        CC -->|"注入每次 Bash 调用的环境"| EV["CLAUDE_CODE_SESSION_ID = sid<br/>逐字等于 transcript 文件名<br/>进程级：多 worktree 并发不串<br/>人工 shell 里不存在"]
    end

    subgraph S2["③ 提交 —— hook 在每次 git commit 时跑"]
        GC["agent：git commit -m …<br/>环境里带 CLAUDE_CODE_SESSION_ID"]
        HM["人：git commit<br/>shell 里没有这个变量"]
        GC --> G{{"prepare-commit-msg 三道守卫，按序判<br/>1 无会话变量 → 人工提交，不留痕<br/>2 rebase / cherry-pick 重放中<br/>　→ 不改别人 commit 的归属<br/>3 去掉注释后消息为空<br/>　→ 让 git 照常拒绝"}}
        HM --> G
        G -->|"任一命中"| X["退出，不注入<br/>交还 git 照常处理"]
        G -->|"全部通过"| IT["git interpret-trailers<br/>注入 Claude-Session: &lt;sid&gt;<br/>并入已有 trailer 块；已有则不动（幂等）"]
        IT --> CM[("commit message 带 trailer<br/>commit ↔ session 唯一真相源<br/>不留第二份<br/>活过 rebase · cherry-pick · ff · no-ff<br/>squash 丢")]
    end

    subgraph S3["④ 投影 —— &lt;repo&gt;/.claude/trace/，入仓随代码走；只存指针（D2）"]
        DV["diverge 事件<br/>时间戳 + turn uuid 指针<br/>human=true：interrupt<br/>　interrupt_for_tool_use · permission_denied<br/>human=false：classifier_blocked<br/>　permission_infra_fail"]
        DV -->|"tools/vibetrail-sync 事后跑<br/>按 worktree 清单认领会话<br/>幂等，整份重生成"| SF[("sessions/&lt;sid&gt;.jsonl<br/>头 · 分歧 · end 汇总")]
        MA["tools/vibetrail-audit record<br/>审完把 findings 与判定写成记录<br/>锚 = git diff-tree -p --cc --root<br/>⇒ git patch-id --stable"] -->|"替代 0 字节 marker"| AF[("audits/&lt;patchId&gt;.jsonl<br/>stats 直接算命中率")]
    end

    subgraph S4["⑤ 读取 —— 查询 / 复盘 与 闸门；三处来源各自可缺、缺了降级"]
        Q["vibetrail show &lt;commit&gt;<br/>另有 log · session · diverge<br/>vibetrail-audit show · stats 读同一份审计记录"]
        Q --> OUT["答「这个 commit 是怎么来的」：<br/>产出它的会话 · 该会话的人机分歧<br/>同会话的其他 commit · 审计记录"]
        GT["Stop hook 闸门：vibetrail-audit check<br/>退出码即答案，判据不在调用方复制<br/>缺记录 block；空锚（无冲突 merge / 空 commit）放行"]
    end

    EV --> GC
    TR -->|"jq -f extract-diverge.jq<br/>只读字段，不 grep 原文"| DV
    CM -->|"读 trailer 得 sid<br/>git log --all 按 sid<br/>反查同会话 commit"| Q
    DV -->|"同一个 jq 现算<br/>transcript 不在本机<br/>则只剩摘要"| Q
    AF -->|"按 patch-id 找文件"| Q
    AF -->|"按 patch-id 找记录"| GT
    SF -.->|"查询端尚未读它"| Q

    IN ~~~ H
    DR ~~~ H
```

commit ↔ 会话之间只靠**一个 id** 接：Claude Code 注入进程环境的 `CLAUDE_CODE_SESSION_ID`，
被 hook 写进 trailer，又逐字等于 transcript 文件名。审计记录另按 patch-id 锚到 commit 的改动上
（[spec §4](spec/trace-v1.md)）。两把钥匙都在 commit 本身上——sid 读 trailer，patch-id 算 diff——
trace 里不存第二份关联，这就是 [spec §2](spec/trace-v1.md)「不留第二份」的由来。
