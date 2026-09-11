#!/bin/bash
# EnvProxy macOS 卸载入口（终端执行）。双击用户请用 3-一键恢复.command。
# 加 --purge 则连日志一起删、不询问：bash uninstall.sh --purge
cd "$(dirname "$0")" || exit 1
exec bash ./envproxy.sh uninstall "$@"
