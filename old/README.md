# 旧代码归档

2026-09-15 按用户要求把 G7 之前的代码和测试挪到这里，`tools/` 只留 G7 新写的采集代码与它依赖的判据。

| 文件 | 是什么 | 状态 |
|---|---|---|
| `vibetrail` / `vibetrail-sync` | 查询端、会话流水投影进仓 | 退役（DESIGN D4） |
| `vibetrail-install` / `vibetrail-doctor` / `prepare-commit-msg` / `test-hook.sh` | 每个 clone 接入、`Claude-Session` trailer、自检 | 退役（D4）；doctor 已按 DESIGN §5 重写成 `tools/vibetrail doctor`（09-15） |
| `vibetrail-audit` / `test-audit.sh` / `test-faults.sh` / `fixtures/` | 审计记录线与它的闸门、故障注入 | 仍在用，去向未定（OPEN-ISSUES U6） |

测试照旧可跑：`bash old/test-hook.sh`、`bash old/test-audit.sh`、`bash old/test-faults.sh`。
归档前后结果相同：test-hook 与 test-audit 各有 1 项失败，是 spec/trace-v1 精简后的文档漂移，归档之前就存在；test-faults 22 项全绿。
判据文件留在 `tools/`，这里的脚本先找同目录、找不到再找 `../tools`，所以被 vendor 进观测仓时照样能用。
