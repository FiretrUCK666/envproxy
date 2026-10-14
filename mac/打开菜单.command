#!/bin/bash
# EnvProxy 菜单（双击运行）。若双击被拦截：右键→打开，或终端执行 bash mac/envproxy.sh menu（在项目根目录下执行）
cd "$(dirname "$0")" || exit 1
bash ./envproxy.sh menu
echo ""
read -p "按回车关闭窗口..." -r
