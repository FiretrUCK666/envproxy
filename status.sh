#!/bin/bash
# EnvProxy macOS 状态入口（终端执行）。双击用户请用 4-查看状态.command。
cd "$(dirname "$0")" || exit 1
exec bash ./envproxy.sh status "$@"
