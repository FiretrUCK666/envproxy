#!/bin/bash
# EnvProxy 检查更新（双击运行）。若双击被拦截：终端执行 bash update.sh
cd "$(dirname "$0")" || exit 1
bash ./update.sh
echo ""
read -p "按回车关闭窗口..." -r
