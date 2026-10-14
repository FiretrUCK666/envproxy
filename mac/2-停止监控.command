#!/bin/bash
# EnvProxy 停止监控（双击运行，保留自启动）。若双击被拦截：终端执行 bash mac/envproxy.sh stop
cd "$(dirname "$0")" || exit 1
bash ./envproxy.sh stop
echo ""
read -p "按回车关闭窗口..." -r
