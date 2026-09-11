#!/bin/bash
# EnvProxy 查看状态（双击运行）。若双击被拦截：终端执行 bash status.sh
cd "$(dirname "$0")" || exit 1
bash ./status.sh
echo ""
read -p "按回车关闭窗口..." -r
