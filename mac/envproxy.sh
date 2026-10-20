#!/bin/bash
# ==============================================================================
#  envproxy.sh — 命令行自动翻墙（macOS 原生，零依赖，通用版）
# ------------------------------------------------------------------------------
#  用法（双击"打开菜单"，或在终端里运行）：
#     bash envproxy.sh menu        打开菜单（安装/状态/停止/恢复/更新）
#     bash envproxy.sh install     一键安装
#     bash envproxy.sh stop        停止监控
#     bash envproxy.sh uninstall   一键恢复（加 --purge 彻底删除日志，不询问）
#     bash envproxy.sh status      查看状态
#     bash envproxy.sh update      检查更新（一键升级，问过才装；加 --yes 跳过确认）
#     无参数（由 LaunchAgent 调用 locator.sh 间接触发）进入监控模式
#
#  运行环境：macOS 12+ 自带 /bin/bash、curl、lsof、netstat、nc、ps、awk、sed、
#  od、stat、find、tr、cut、tar、cmp、launchctl。（检查更新会用到 git——只在当前
#  文件夹是 git 工作树时才走那条路，普通安装副本不需要它。）
#  不需要 Homebrew/Python/Node/管理员，不写任何系统目录。
#
#  行为保证（与 Windows 同语义）：
#     - 翻墙软件断开/重连/退出/重启/换端口/换软件 → 监控自动跟随，无需任何操作
#     - 退出翻墙软件后约 5 秒删除代理变量；"断开连接"（内核仍活着）以流量真相判定，约 30 秒
#       （本地代理响应挂起、探测跑满超时时最坏约 45 秒）
#     - 停止监控就是真的停止（自启动只在登录时拉起一次，不会把停掉的监控再拉回来）
#     - 整个文件夹移动 → 监控自退 + 下次登录定位器自动重新定位（可搜索范围同 Windows）
#
#  原理（通用，不绑定任何特定翻墙软件，与 Windows 版一致）：
#     监控进程每 2-3 秒探测一次"本机是否有 HTTP 代理端口正在监听"。
#     发现来源（两层，只认端口本身）：
#       1) 快路径：常见翻墙软件默认端口扫描（KNOWN_PORTS，可自行增删）
#       2) 万能路径：全端口扫描 + CONNECT 握手探测（进程名预筛提速）
#           → 随便改端口、随便换软件，都能自动发现，不写死任何东西
#     状态翻转（开/关/换端口）时才写一次用户级环境变量 + launchctl。
#     状态稳定时什么都不写。
#
#  macOS 与 Windows 的差异（为什么必须双路写入）：
#     Windows 写一次注册表 HKCU\Environment + 广播即全局生效。
#     macOS 没有全局用户环境变量：GUI App（Dock/Spotlight 启动）只认
#     launchd 会话环境（launchctl setenv，会话级、重启即清）；终端 shell
#     只认 rc 文件。因此必须双路同时写，缺一路都会"有的程序有、有的没有"。
#     持久化不需要单独的 setenv plist：监控本身 RunAtLoad，启动立即对齐一次，
#     重启后自动重放两路（与 Windows 启动对齐同语义）。
# ==============================================================================

set -u

# ------------------------------------------------------------------------------
#  文件结构（入口只做四件事：解析子命令、挂操作锁、加载自检、分派）
#     envproxy.sh       入口（本文件）
#     lib/base.sh       契约常量、纯函数助手
#     lib/probe.sh      端口发现、握手、节点连通、状态判定
#     lib/env.sh        代理变量双路写入/删除/归属/快照还原
#     lib/runtime.sh    日志、监控进程、主循环、自启动定位器、shell 集成
#     lib/package.sh    覆盖安装区、备份与回滚
#     lib/update.sh     版本检查、下载校验、确认流程
#     lib/ops.sh        安装/停止/卸载/状态编排、自检沙箱
#   库清单的唯一权威处是下面的 CORE_LIBS；门禁会核对它与 lib/ 实际内容一致。
# ------------------------------------------------------------------------------
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
# ------------------------------------------------------------------------------
# 加载核心库（顺序固定：契约常量与纯函数必须先就位）
# ------------------------------------------------------------------------------
# 只有入口推算自身目录：lib/ 里的脚本被 source 后不能靠自身位置推路径，
# 所以 SCRIPT_DIR 由入口算好，各库一律用这个全局。
LIB_DIR="$SCRIPT_DIR/lib"
# 库清单是唯一权威处：新增或改名库只改这里，门禁核对它与 lib/ 实际内容一致。
CORE_LIBS="base probe env runtime package update ops"
# 加载前先验完整性：缺文件时说人话，而不是抛一句看不懂的语法错误。
_missing_lib=""
for _lib_name in $CORE_LIBS; do
    _lib_path="$LIB_DIR/$_lib_name.sh"
    if [ ! -f "$_lib_path" ] || [ ! -s "$_lib_path" ]; then _missing_lib="$_missing_lib $_lib_name.sh"; fi
done
if [ -n "$_missing_lib" ]; then
    echo "安装不完整，缺少程序文件：$_missing_lib"
    echo "这个文件夹没有完整拷过来，或者文件被删掉了。"
    echo "到 Releases 页面重新下载安装包，解压后覆盖这个文件夹即可（缺文件时打开菜单也修不了——它自己就要用到这些文件）。"
    exit 1
fi
for _lib_name in $CORE_LIBS; do . "$LIB_DIR/$_lib_name.sh"; done

# ------------------------------------------------------------------------------
# 11. 入口分派（兼容大小写与 '-' 前缀，方便 Windows 用户迁移）
# ------------------------------------------------------------------------------
# 直接执行才分派：被 source（测试加载）时只定义函数、不跑监控。
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
_CMD="${1:-}"
_PURGE="0"
_YES="0"
if [ $# -gt 0 ]; then
for _a in "$@"; do
    case "$_a" in --purge|--Purge|-Purge|-purge) _PURGE="1";; esac
    case "$_a" in --yes|--Yes|-Yes|-yes) _YES="1";; esac
done
fi
# shellcheck disable=SC2001
_CMD_NORM=$(printf '%s' "$_CMD" | sed 's/^--*//; s/^-//' | tr '[:upper:]' '[:lower:]')

case "$_CMD_NORM" in
    install|update|stop|uninstall)
        # 操作锁：这四个动作都会改文件或删变量，同一时刻只允许一个在跑。撞上就提示退出、不做任何改动。
        # 陈旧锁（持有者已经不在）会被接管；子进程收尾前会把锁交出去（见 update_envproxy）。
        # 拿锁用 ln 而不是 mkdir（理由见 runtime 层的 acquire_op_lock）：
        # mkdir 成功到"把 pid 写进去"之间有个空窗，那个空窗里另一个进程
        # 读到空的 pid，会把锁当成陈旧的接管掉——两个安装同时跑就互相覆盖文件。
        mkdir -p "$MONITOR_DIR" 2>/dev/null || true
        OP_LOCK="$MONITOR_DIR/.op.lock"
        acquire_op_lock "$OP_LOCK" || exit 1
        # shellcheck disable=SC2064
        trap 'rm -f "$OP_LOCK" 2>/dev/null || true' EXIT
        ;;
esac

case "$_CMD_NORM" in
    install) install_envproxy;;
    stop) stop_monitor; remove_user_env_vars; echo "代理变量已清除，当前恢复直连。";;
    uninstall) uninstall_envproxy "$_PURGE";;
    status) show_status;;
    # 退出码要如实反映结果（计划任务、脚本靠它判断更新成功没有）。
    update) update_envproxy "$_YES"; exit $?;;
    menu) show_menu;;
    self-test) self_test;;
    "") run_monitor_loop;;
    # 用法错误统一退出码 2（与 Windows 侧一致）：调用方能据此分辨"用法错了"和"动作失败"。
    *) echo "用法: bash $0 {menu|install|stop|uninstall|status|update|self-test} [--purge] [--yes]"; exit 2;;
esac
fi
