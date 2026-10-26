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
#     bash envproxy.sh update       检查更新（一键升级，问过才装；加 --yes 跳过确认）
#     bash envproxy.sh help         打印帮助（忘了怎么用时看）
#     无参数（由 LaunchAgent 调用 locator.sh 间接触发）进入监控模式
#
#  运行环境：macOS 12+ 自带 /bin/bash、curl、lsof、netstat、nc、ps、awk、sed、
#  od、stat、find、tr、cut、tar、cmp、launchctl。（检查更新会用到 git——只在当前
#  文件夹是 git 工作树时才走那条路，普通安装副本不需要它。）
#  不需要 Homebrew/Python/Node/管理员，不写任何系统目录。
#
#  行为保证（与 Windows 同语义）：
#     - 翻墙软件断开/重连/退出/重启/换端口/换软件 → 监控自动跟随，无需任何操作
#     - 退出翻墙软件后删掉代理变量；"断开连接"（内核仍活着）以流量真相判定，慢得多
#       （平时 15 秒探一次，发现失败后加密到 5 秒一次，连续失败满 10 秒、至少 3 次才判"断"）
#     - 断开后连回来会恢复代理变量（一次成功即认，且刚下完结论时保持加密观察）
#     - 具体秒数只有一个权威源：README 第 5 节的状态图。这里不复述，免得改常量时对不上。
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
# 开关名与命令词一样不区分大小写（Windows 的参数绑定也不区分）：
# 先小写化再比对，不要写死几种拼写——漏掉的组合会变成"参数写错"。
for _a in "$@"; do
    _al=$(printf '%s' "$_a" | tr '[:upper:]' '[:lower:]')
    case "$_al" in --purge|-purge) _PURGE="1";; esac
    case "$_al" in --yes|-yes) _YES="1";; esac
done
# shellcheck disable=SC2001
_CMD_NORM=$(printf '%s' "$_CMD" | sed 's/^--*//; s/^-//' | tr '[:upper:]' '[:lower:]')

# 用法判定（判据在 base 层的 usage_error，两端同形）：这里只负责把参数归一化后交给它。
# 用法错误要在拿操作锁**之前**判：用法错误既不改文件也不删变量，不该占着锁，
# 也不该因为"另一个安装正在进行"而报成退出码 1（那是动作冲突，不是用法错误）。
USAGE_COMMAND="$_CMD_NORM"
USAGE_COMMAND_COUNT=0
if [ -n "$_CMD" ]; then USAGE_COMMAND_COUNT=1; fi
USAGE_SWITCHES=""
if [ "$_PURGE" = "1" ]; then USAGE_SWITCHES="purge"; fi
if [ "$_YES" = "1" ]; then USAGE_SWITCHES="$USAGE_SWITCHES yes"; fi
# 多余的位置参数与不认识的开关都算"无法识别的参数"。
# 只认 --purge / --yes 两个开关名：它们本来就占一个参数位，
# 把它们也算成"多余的位置参数"的话，"uninstall --purge" 这种合法用法会被一起拒掉。
# 第一个位置参数是命令词；它为空时也要报出来——"传了个空参数"是参数写错，
# "没传参数"才是监控模式，两者不能压成同一个空串。
USAGE_EXTRA=""
_extra_first=1
for _a in "$@"; do
    _al=$(printf '%s' "$_a" | tr '[:upper:]' '[:lower:]')
    case "$_al" in
        --purge|-purge|--yes|-yes) continue ;;
    esac
    if [ $_extra_first -eq 1 ]; then
        _extra_first=0
        if [ -z "$_a" ]; then USAGE_EXTRA="''"; fi
        continue
    fi
    USAGE_EXTRA="$USAGE_EXTRA $_a"
done
_usage_err=$(usage_error)
_usage_rc=$?
if [ $_usage_rc -ne 0 ]; then
    echo "$_usage_err" >&2
    echo "用法: bash $0 {menu|install|stop|uninstall|status|update|help|self-test|repair-profile} [--purge] [--yes]" >&2
    exit 2
fi

# 平台守卫：这个入口只属于 macOS。
#
# 为什么需要它：`~/.envproxy/` 下那一套运行时文件（proxy.env、owned.env、prev.env）
# 是这一侧的格式，Windows 侧从不写它们、也不认识它们。可是这份脚本在 Git Bash 里
# 照样能跑——只要有人在 Windows 上执行一次 install 或 stop，就会往使用者的
# Windows 家目录里写一堆 mac 专属文件；而 Windows 侧的卸载只认 `prompt-sync.sh`
# （那是它唯一的合法产出），对别的一字节不动、也不报告。用户看到的症状就是
# "家目录里莫名多出一个 .envproxy 文件夹，一键恢复了还在"。
#
# 判据放在入口而不是各函数里：不管从哪个子命令进来，只有这一道门。
# 位置必须在用法校验**之后**：参数写错仍然要拿到退出码 2——那是动作契约，
# 不该因为平台不对就变成另一种失败。
#
# 名单写的是**放行**的那几个，不是要拦的那几个——方向反了就是个陷阱：
# 列要拦的，将来加一个新子命令而作者没想起来回来补一行，它就能在 Windows 的
# Git Bash 里照常跑，往使用者家目录写 mac 格式的 proxy.env / owned.env，
# 而 Windows 卸载只认 prompt-sync.sh——正是上面那段说的事故。
# 现在只有「只读本机、不碰用户环境」的两条放行，新增子命令默认被拦。
#
# 认不出的命令词要**放行到这里之后的分派**去判：它本来就不是平台问题，
# 而是参数写错，退出码必须是 2（两侧同一套契约，门禁 10 拿这条互相比）。
# 在本层把它改判成 1，等于让同一个错误在 Windows 上和在 macOS 上拿到不同退出码。
case "${OSTYPE:-}" in
    darwin*) ;;
    *)
        case "$_CMD_NORM" in
            help|self-test) : ;;
            menu|install|stop|uninstall|status|update|repair-profile|'')
                echo "这是 macOS 版，只能在 macOS 上运行（当前系统不是 macOS）。" >&2
                echo "Windows 请用 win 目录里的 envproxy.ps1，或双击「打开菜单」。" >&2
                exit 1
                ;;
        esac
        ;;
esac


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
    # stop 也要走哨兵模式：purge 会把 proxy.env 整个删掉，已开着的窗口下次回到提示符时
    # 读不到文件，就永远停在上一次的代理值上（契约：off 态写守卫式 unset，不删文件）。
    stop)
          # 提权提醒：install / uninstall 都有这一句，唯独 stop 没有。
          # 判据（是不是 root）与动作（改的是谁的配置）两端完全同构——
          # 以 root 跑时动的是 root 账号的变量、停的是可能属于别人的监控，
          # 而屏幕上一句提醒都没有。与 Windows 侧 -Stop 的 Test-IsElevated 同一口径。
          if [ "$(id -u)" = "0" ]; then
              echo "当前是 root 身份：动的将是 root 的配置，日常使用请用普通终端重做一遍。" >&2
          fi
          stop_monitor; remove_user_env_vars sentinel; echo "代理变量已清除，当前恢复直连。"
          # 提醒已开窗口：它们没被通知，要等下一次回到提示符才更新。
          # 这不是缺陷，是环境变量的固有物理限制（一个进程的环境在它启动时就定了），
          # 与其让人以为"工具坏了"，不如说清楚。
          echo "      已经开着的其它终端窗口，敲一下回车（或随便跑条命令）就跟上。";;
    uninstall) uninstall_envproxy "$_PURGE" "$_YES";;
    # 交互终端里走实时刷新（自己动、不用按键）；重定向/无终端/窗口太小时
    # show_status_live 会自动退回一次性静态输出，两种情况都能走这里。
    status) show_status_live;;
    # 显式修复"配置文件里标记不成对"。安装/卸载遇到它会一个字节都不改（猜必错），
    # 所以那个状态本来是死路：照文档重跑安装，每次都被拒绝。人明确说"我同意修"时要能修。
    repair-profile) repair_hook_markers; exit $?;;
    # 退出码要如实反映结果（计划任务、脚本靠它判断更新成功没有）。
    update) update_envproxy "$_YES"; exit $?;;
    menu) show_menu;;
    help) show_help;;
    report) new_problem_report;;
    # DIVERGE(Mac): self-test 只有 mac 有，Windows 侧没有对应子命令。
    #   为什么：这份自检跑在临时沙箱里（重定向 HOME、不碰真实配置），靠的是 shell 的
    #   变量替换与子进程隔离，用 bash 实现是自然的。Windows 侧的同等回归住在
    #   tests\test-win-pure.ps1 里，由 CI 跑（5.1 与 7 各一遍），不随安装包分发——
    #   随包发一份 .ps1 自检会让包内文件集多一项、而它从不被用户调用。
    #   两边都要有"能自检"这个能力，但入口形状不同是有意的，不是漏了。
    self-test)
        # 自检的正文住在一个单独的文件里，不随运行时库加载：它是"沙箱里跑断言"，体量超过任何一个库，
        # 不是使用者每次 install/status 都要解析的逻辑。Windows 侧的对应物一直是独立文件。
        _st="$SCRIPT_DIR/test-mac-pure.sh"
        if [ -f "$_st" ]; then
            . "$_st"
            self_test
        else
            echo "自检脚本缺失：$_st（安装包不完整，请到 Releases 页面重新下载覆盖）" >&2
            exit 1
        fi;;
    "") run_monitor_loop;;
    # 用法错误统一退出码 2（与 Windows 侧一致）：调用方能据此分辨"用法错了"和"动作失败"。
    *) echo "用法: bash $0 {menu|install|stop|uninstall|status|update|help|self-test|repair-profile} [--purge] [--yes]"; exit 2;;
esac
fi
