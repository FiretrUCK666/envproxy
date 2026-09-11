#!/bin/bash
# EnvProxy macOS 更新入口（终端执行）。双击用户请用 5-检查更新.command。
cd "$(dirname "$0")" || exit 1
exec bash ./envproxy.sh update "$@"
