#!/bin/bash
# EnvProxy macOS 停止入口（终端执行）。双击用户请用 2-停止监控.command。
cd "$(dirname "$0")" || exit 1
exec bash ./envproxy.sh stop "$@"
