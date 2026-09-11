#!/bin/bash
# EnvProxy 一键恢复（双击运行，彻底卸载）。若双击被拦截：终端执行 bash uninstall.sh
cd "$(dirname "$0")" || exit 1
bash ./uninstall.sh
echo ""
read -p "按回车关闭窗口..." -r
