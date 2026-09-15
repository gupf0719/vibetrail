# vibetrail: 从 Claude Code transcript 提取人机分歧点——命令行入口。
# 判据全部在 diverge-rules.jq（jq 模块，只有函数定义；六条铁律也写在那里）。
# 用法：jq -c -L <tools 目录> -f extract-diverge.jq <transcript.jsonl>
#   ⚠️ jq 1.6 按 cwd 找模块，-L 不能省（除非 cwd 就是 tools/）。
include "diverge-rules";
diverge
