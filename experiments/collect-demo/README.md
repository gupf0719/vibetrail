# 采集样例用的示例会话

`scenario.json` 是一段编出来的 Claude Code 会话，不含任何真实会话。共两轮：第 1 轮用 Edit 给 `calc.py` 的 `div`
加零检查，再用 Bash 跑 pytest，输出里夹着一个假密钥 `sk-demo-…`；第 2 轮一次 Bash 被用户拒绝（带 interrupt 记录），
用户随后纠正。

`steps` 按时间排，每步二选一：`{"append": …}` 是 Claude Code 往 transcript 追加的一行；`{"hook": …}` 表示此刻触发
一个 hook 事件，内容就是 Claude Code 喂给 hook 的 stdin。回放时把 `/tmp/demo-proj`、`/tmp/demo-home` 换成自己的临时目录。

用它跑出来的两份样例（2026-09-11，断网实跑）：[LoongSuite Pilot](../../third-party/loongsuite-pilot-collection-sample.md)、
[teamai-cli](../../third-party/teamai-cli-collection-sample.md)。回放脚本写死了跑的那台机器的路径，没有入库。
