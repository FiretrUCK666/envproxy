#!/bin/bash
# EnvProxy 安装（双击运行）。若双击被拦截：右键→打开，或终端执行 bash install.sh
cd "$(dirname "$0")" || exit 1
bash ./install.sh
echo ""
read -p "按回车关闭窗口..." -r
