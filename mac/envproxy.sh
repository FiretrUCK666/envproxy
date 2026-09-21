#!/bin/bash
# ==============================================================================
#  envproxy.sh — 命令行自动翻墙（macOS 原生，零依赖，通用版）
# ------------------------------------------------------------------------------
#  用法（双击配套 .command，或在终端里运行）：
#     bash envproxy.sh install     一键安装
#     bash envproxy.sh stop        停止监控
#     bash envproxy.sh uninstall   一键恢复（加 --purge 彻底删除日志，不询问）
#     bash envproxy.sh status      查看状态
#     bash envproxy.sh update      检查更新（一键升级，问过才装；加 --yes 跳过确认）
#     无参数（由 LaunchAgent 调用 locator.sh 间接触发）进入监控模式
#
#  运行环境：macOS 12+ 自带 /bin/bash、curl、lsof、netstat、nc、ps、awk、tar、cmp、launchctl。
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
# 0. 路径与常量（全部动态推导，不写死用户名/磁盘）
# ------------------------------------------------------------------------------
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
MONITOR_DIR="$SCRIPT_DIR/monitor"
PID_FILE="$MONITOR_DIR/monitor.pid"
STOP_FLAG="$MONITOR_DIR/stop.flag"
LOG_FILE="$MONITOR_DIR/monitor.log"

ENVPROXY_HOME="$HOME/.envproxy"
PROXY_ENV="$ENVPROXY_HOME/proxy.env"
PATH_CONF="$ENVPROXY_HOME/path.conf"
LOCATOR_PATH="$ENVPROXY_HOME/locator.sh"
PLIST_LABEL="com.envproxy.monitor"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

# 更新源默认与 README 克隆地址同源；有 .git 时优先从 git remote 解析
# （fork 后 git-clone 的机器自动跟自己的 Release 走）。
UPDATE_REPO_DEFAULT="FiretrUCK666/envproxy"

# 常见翻墙软件的默认本地代理端口（快速扫描用）。可自行增删。
# 注意：只做快筛，不做判决——判决永远是 CONNECT 握手 + 真实连通。
# 因此本表按"常见入站口"收，不按协议收：列入纯 SOCKS 口不会误判，只会多一次本机握手。
KNOWN_PORTS="7078 7890 7897 10808 10809 10801 2080 2081 1080 8118 8080 6152 8888 12334"  # 12334 = Hiddify-Next 默认

# 翻墙软件进程名特征（只影响速度不影响覆盖面）。可自行扩展。
PATTERNS="monocloud clash mihomo verge v2ray xray sing-box singbox hiddify shadowsocks ss-local trojan hysteria neko netch surge outline"

# 验证端点（与 Windows 版一致：跨厂商/跨域段，快路优先 + 失败并行兜底）。
# 端点池的两条硬要求，缺一不可：
#   1) 跨厂商/跨域段——单个域段被干扰时其余端点仍能证明节点活着；
#   2) 响应体"零字节或极小"——Mac 侧探针是 curl：它没有"读到响应头就停"的开关，
#      只能把正文收下再丢弃（-o /dev/null），所以正文字节数直接等于流量预算。
#      现有 7 个端点：5 个 /generate_204（0 字节 204）+ 2 个被墙站点（重定向或 KB 级响应）。
# 新增端点必须同时满足这两条，否则"每次不足 1KB"的流量口径立刻失真。
CHECK_HOSTS="clients3.google.com connectivitycheck.gstatic.com www.gstatic.com youtubei.googleapis.com www.google.com www.wikipedia.org twitter.com"
CHECK_PATHS="/generate_204 /generate_204 /generate_204 /generate_204 /generate_204 / /"

# shell hook 标记（幂等插入/精确移除的依据）
HOOK_START="# >>> EnvProxy >>>"
HOOK_END="# <<< EnvProxy <<<"
HOOK_LINE='[ -f "$HOME/.envproxy/proxy.env" ] && . "$HOME/.envproxy/proxy.env"'

# 监控状态（进程内变量，不落地）
LAST_GOOD_ENDPOINT=0
LAST_NODE_CHECK=0
NODE_CACHE_PORT=""
NODE_ALIVE=0
NODE_FAIL_COUNT=0
CACHED_PORT=""
LAST_SEEN_SET=""
LAST_ALIVE_PORT=""
ROUND=0
CURRENT_STATE="off"

# 可调阈值（改行为只改这里，机制不动）
NODE_CHECK_THROTTLE_SEC=15   # 真实探测节流：每端口 15 秒最多一次（流量预算靠它）
NODE_FAIL_THRESHOLD=3        # 连续失败几次才判"断"（与 Win 侧 $NodeFailThreshold 对齐）

# ------------------------------------------------------------------------------
# 1. 日志（只记状态翻转；超过 200KB 截断为最近 200 行）
# ------------------------------------------------------------------------------
log_msg() {
    mkdir -p "$MONITOR_DIR" 2>/dev/null || true
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || return 0
    _size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    _size=$(printf '%s' "$_size" | tr -cd '0-9')
    if [ -n "$_size" ] && [ "$_size" -gt 204800 ] 2>/dev/null; then
        tail -n 200 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || rm -f "$LOG_FILE.tmp" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# 2. 环境变量读写（终端路 proxy.env + GUI 路 launchctl，双路同进同退）
# ------------------------------------------------------------------------------
# 本机地址直连的默认例外集，写法遵循 NO_PROXY 的通行规范：IPv6 地址**裸写**。
# 裸写是各家的共同要求——httpx 的规范示例就是 `NO_PROXY=example.com,::1,localhost,...`，
# 而且它会自己给 IPv6 补上方括号去构造内部模式；预先写成 `[::1]` 会被当成普通域名，
# 生成非法模式，反而让每一次请求都抛 `InvalidURL: Invalid port: ':1]'`。
# 也就是说方括号属于 URL 字面量的写法，在 NO_PROXY 里是写错了位置。
DEFAULT_NO_PROXY="localhost,127.0.0.1,::1"

# 读已存在的 NO_PROXY（终端路取自 proxy.env，GUI 路取自 launchctl）。
# 带参数则读指定变量名，不带则读大写那份，供合并用。
get_existing_no_proxy() {
    _name="${1:-NO_PROXY}"
    _v=""
    if [ -f "$PROXY_ENV" ]; then
        _v=$(grep -E "^export ${_name}=" "$PROXY_ENV" 2>/dev/null | head -n 1 | sed 's/^export [A-Za-z_]*="//; s/"$//')
    fi
    if [ -z "$_v" ]; then _v=$(launchctl getenv "$_name" 2>/dev/null || echo ""); fi
    printf '%s' "$_v"
}

# NO_PROXY 只增不减：已存在的条目原样保留，缺失的默认条目补上。
# 环境变量是共享资源——用户自己加的例外（公司内网等）与别的工具写下的例外都必须留着，
# 本工具只负责"本机地址一定直连"这一件事。
# 取值用 sed 而非 tr -d ' '：条目里可能有空格，整体删空格会改掉别人写的值。
merge_no_proxy() {
    _existing="$1"; _default="$2"
    _out=""
    _lower=$(printf '%s' "$_default" | tr 'A-Z' 'a-z')
    _old=$IFS; IFS=','
    for _p in $_default; do
        _out="${_out:+$_out,}$_p"
    done
    for _p in $_existing; do
        _pt=$(printf '%s' "$_p" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -n "$_pt" ] || continue
        _pl=$(printf '%s' "$_pt" | tr 'A-Z' 'a-z')
        case ",$_lower," in
            *",$_pl,"*) ;;
            *) _out="${_out:+$_out,}$_pt"; _lower="${_lower},${_pl}" ;;
        esac
    done
    IFS=$_old
    printf '%s' "$_out"
}

get_current_proxy_port() {
    [ -f "$PROXY_ENV" ] || return 1
    _line=$(grep -E '^export HTTP_PROXY=' "$PROXY_ENV" 2>/dev/null | head -n 1)
    [ -n "$_line" ] || return 1
    printf '%s' "$_line" | grep -oE ':[0-9]+' | tr -d ':' | head -n 1
}

set_user_env_vars() {
    _port="$1"
    _http="http://127.0.0.1:$_port"
    _np=$(merge_no_proxy "$(get_existing_no_proxy)" "$DEFAULT_NO_PROXY")
    mkdir -p "$ENVPROXY_HOME" 2>/dev/null || true
    _tmp="$PROXY_ENV.tmp.$$"
    {
        printf 'export HTTP_PROXY="%s"\n' "$_http"
        printf 'export http_proxy="%s"\n' "$_http"
        printf 'export HTTPS_PROXY="%s"\n' "$_http"
        printf 'export https_proxy="%s"\n' "$_http"
        printf 'export ALL_PROXY="%s"\n' "$_http"
        printf 'export all_proxy="%s"\n' "$_http"
        printf 'export NO_PROXY="%s"\n' "$_np"
        printf 'export no_proxy="%s"\n' "$_np"
        printf 'export NODE_USE_ENV_PROXY="1"\n'
    } > "$_tmp" 2>/dev/null && mv "$_tmp" "$PROXY_ENV" 2>/dev/null || rm -f "$_tmp" 2>/dev/null || true
    launchctl setenv HTTP_PROXY "$_http" 2>/dev/null || true
    launchctl setenv http_proxy "$_http" 2>/dev/null || true
    launchctl setenv HTTPS_PROXY "$_http" 2>/dev/null || true
    launchctl setenv https_proxy "$_http" 2>/dev/null || true
    launchctl setenv ALL_PROXY "$_http" 2>/dev/null || true
    launchctl setenv all_proxy "$_http" 2>/dev/null || true
    launchctl setenv NO_PROXY "$_np" 2>/dev/null || true
    launchctl setenv no_proxy "$_np" 2>/dev/null || true
    launchctl setenv NODE_USE_ENV_PROXY "1" 2>/dev/null || true
}

# 整套变量是否都已就位（幂等判据不看单项）：只看代理地址会让"地址对、别的变量漂移"的
# 半代理状态永远无人纠正。返回 0 = 已就位（无需动手）。
env_vars_in_sync() {
    _port="$1"
    [ -f "$PROXY_ENV" ] || return 1
    _http="http://127.0.0.1:$_port"
    _np=$(merge_no_proxy "$(get_existing_no_proxy)" "$DEFAULT_NO_PROXY")
    for _v in HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy; do
        grep -qxF "export $_v=\"$_http\"" "$PROXY_ENV" 2>/dev/null || return 1
    done
    grep -qxF "export NO_PROXY=\"$_np\"" "$PROXY_ENV" 2>/dev/null || return 1
    grep -qxF "export no_proxy=\"$_np\"" "$PROXY_ENV" 2>/dev/null || return 1
    grep -qxF 'export NODE_USE_ENV_PROXY="1"' "$PROXY_ENV" 2>/dev/null || return 1
    return 0
}

# 幂等同步：不齐就补齐，齐了则什么都不做、零写入。
sync_user_env_vars() {
    _port="$1"
    env_vars_in_sync "$_port" && return 0
    set_user_env_vars "$_port"
    return 0
}

remove_user_env_vars() {
    # 只回收**本工具自己写下的** NO_PROXY / no_proxy / NODE_USE_ENV_PROXY。
    # 环境变量是共享资源，用户或别的工具可能把这几项用于自己的用途；
    # 值不是我们写的那一个，就说明不是我们的东西，一律不动。
    _ours=$(printf '%s' "$DEFAULT_NO_PROXY" | tr -d ' ' | tr 'A-Z' 'a-z')
    for _v in no_proxy NO_PROXY; do
        _cur=$(get_existing_no_proxy "$_v" | tr -d ' ' | tr 'A-Z' 'a-z')
        if [ "$_cur" = "$_ours" ]; then launchctl unsetenv "$_v" 2>/dev/null || true; fi
    done
    _node=$(launchctl getenv NODE_USE_ENV_PROXY 2>/dev/null || echo "")
    if [ "$_node" = "1" ]; then launchctl unsetenv NODE_USE_ENV_PROXY 2>/dev/null || true; fi
    rm -f "$PROXY_ENV" 2>/dev/null || true
    for _v in HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy; do
        launchctl unsetenv "$_v" 2>/dev/null || true
    done
}

# 幂等：整套变量都已就位就什么都不做（只看单项会让"地址对、别的漂移"的半代理状态无人纠正）
apply_state() {
    _state="$1"
    if [ "$_state" = "off" ]; then
        if get_current_proxy_port >/dev/null 2>&1; then
            remove_user_env_vars
            log_msg "代理已关闭 -> 已删除代理变量，恢复直连"
        fi
    else
        _port=$(printf '%s' "$_state" | sed 's/^on://')
        if ! env_vars_in_sync "$_port"; then
            set_user_env_vars "$_port"
            log_msg "检测到本地代理端口 $_port -> 已注入代理 http://127.0.0.1:$_port"
        fi
    fi
}

# ------------------------------------------------------------------------------
# 3. 代理端口发现（不绑定品牌/端口号，只认"谁真的在提供代理服务"）
# ------------------------------------------------------------------------------
test_port_listening() {
    lsof -iTCP:"$1" -sTCP:LISTEN -n -P >/dev/null 2>&1
}

# 单端口 CONNECT 握手：只有真正的 HTTP 代理才回 "200"
test_http_proxy() {
    _p="$1"
    _resp=$(printf 'CONNECT 127.0.0.1:9 HTTP/1.1\r\nHost: 127.0.0.1:9\r\n\r\n' | nc -G 1 -w 2 127.0.0.1 "$_p" 2>/dev/null | head -n 1)
    printf '%s' "$_resp" | grep -qE '^HTTP/1\.[01] +200'
}

# 批量探测 worker（参数展开在父进程完成，避免后台子 shell 闭包竞态）
_probe_proxy_one() {
    _pp="$1"; _found="$2"
    _r=$(printf 'CONNECT 127.0.0.1:9 HTTP/1.1\r\nHost: 127.0.0.1:9\r\n\r\n' | nc -G 1 -w 2 127.0.0.1 "$_pp" 2>/dev/null | head -n 1)
    if printf '%s' "$_r" | grep -qE '^HTTP/1\.[01] +200'; then
        printf '%s' "$_pp" > "$_found" 2>/dev/null || true
    fi
}

# 并行批量 CONNECT 探测：多个端口同时握手，~2 秒内出结果
test_http_proxy_batch() {
    [ $# -eq 0 ] && return 1
    _found="/tmp/envproxy_found.$$"
    rm -f "$_found" 2>/dev/null || true
    for _p in "$@"; do
        _probe_proxy_one "$_p" "$_found" &
    done
    _i=0
    while [ $_i -lt 30 ]; do
        [ -f "$_found" ] && break
        sleep 0.1
        _i=$((_i + 1))
    done
    wait 2>/dev/null || true
    if [ -f "$_found" ]; then
        cat "$_found" 2>/dev/null
        rm -f "$_found" 2>/dev/null || true
        return 0
    fi
    rm -f "$_found" 2>/dev/null || true
    return 1
}

# 本机监听端口表（排序去重，无状态，可安全用于命令替换）
get_listening_ports() {
    _ports=$(lsof -a -PiTCP -sTCP:LISTEN -n -P 2>/dev/null | grep -oE ':[0-9]+ \(LISTEN\)' | grep -oE '[0-9]+' | sort -nu)
    if [ -z "$_ports" ]; then
        _ports=$(netstat -anvp tcp 2>/dev/null | awk '/LISTEN/ {print $4}' | sed 's/.*\.//' | grep -E '^[0-9]+$' | sort -nu)
    fi
    printf '%s' "$_ports"
}

# 可疑进程端口表（排序去重，无状态，可安全用于命令替换）
get_suspect_ports() {
    _psmap="/tmp/envproxy_ps.$$"
    _lsofout="/tmp/envproxy_lsof.$$"
    ps -ax -o pid=,comm= 2>/dev/null | tr '[:upper:]' '[:lower:]' > "$_psmap" 2>/dev/null || true
    if ! lsof -a -PiTCP -sTCP:LISTEN -n -P 2>/dev/null > "$_lsofout"; then
        rm -f "$_psmap" "$_lsofout" 2>/dev/null || true
        printf ''
        return 0
    fi
    _suspect=""
    while IFS= read -r _line; do
        case "$_line" in COMMAND*) continue;; esac
        _pid=$(printf '%s' "$_line" | awk '{print $2}')
        _port=$(printf '%s' "$_line" | grep -oE ':[0-9]+ \(LISTEN\)' | grep -oE '[0-9]+' | head -n 1)
        [ -n "$_pid" ] && [ -n "$_port" ] || continue
        _comm=$(grep -E "^ *$_pid " "$_psmap" 2>/dev/null | head -n 1 | awk '{print $2}')
        if [ -n "$_comm" ]; then
            for _pat in $PATTERNS; do
                case "$_comm" in *"$_pat"*) _suspect="$_suspect $_port"; break;; esac
            done
        fi
    done < "$_lsofout"
    rm -f "$_psmap" "$_lsofout" 2>/dev/null || true
    printf '%s' "$_suspect" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -nu | tr '\n' ' ' | sed 's/ $//'
}

# 成员判断：$1 在空格分隔表 $2 里则返回 0
_in_list() {
    case " $2 " in *" $1 "*) return 0;; *) return 1;; esac
}

# 候选集发现（有序去重，本机零流量）：先已知端口（按表顺序），再可疑进程端口
# （数字排序），最后按需追加全端口批量探测的尾巴。全部过 CONNECT 握手门——
# 握手不过的（开发服务器、纯 SOCKS 口、认证口）进不了集合。
# 输出空格分隔的端口表（可能为空串，无状态，可安全用于命令替换）。
# 状态机按集合签名判断变化并逐个试活；只要首选不要全集的调用方继续用
# get_active_proxy_port（取第一个）。
find_candidate_ports() {
    _full="$1"
    _cands=""
    _ports=$(get_listening_ports || true)
    # 来源 1（快路径）：已知端口按表顺序，逐个过门
    for _kp in $KNOWN_PORTS; do
        if printf '%s\n' "$_ports" | grep -qx "$_kp"; then
            if ! _in_list "$_kp" "$_cands"; then
                if test_http_proxy "$_kp"; then _cands="$_cands $_kp"; fi
            fi
        fi
    done
    # 来源 2 第一轮：可疑进程端口（数字排序，逐个过门）
    for _sp in $(get_suspect_ports || true); do
        if ! _in_list "$_sp" "$_cands"; then
            if test_http_proxy "$_sp"; then _cands="$_cands $_sp"; fi
        fi
    done
    # 来源 2 第二轮：兜底——全端口并行批量握手（进程名无特征也能发现）。
    # 仅在 _full=1 时执行（约 1 秒，off 状态降频调用以省资源）。
    # 尾巴保持 early-exit 单答案：未知工具独占时它是唯一的候选，
    # 已知候选在前时它只是补充——两种情形试活层都能正确收敛。
    if [ "$_full" = "1" ]; then
        _rest=""
        for _p in $_ports; do
            if ! _in_list "$_p" "$_cands"; then _rest="$_rest $_p"; fi
        done
        if [ -n "$_rest" ]; then
            # shellcheck disable=SC2086
            _tail=$(test_http_proxy_batch $_rest || true)
            if [ -n "$_tail" ] && ! _in_list "$_tail" "$_cands"; then _cands="$_cands $_tail"; fi
        fi
    fi
    printf '%s' "$_cands" | sed 's/^ //'
}

# 组合发现（薄封装）：只要首选不要全集的调用方（状态显示等）继续调这个，
# 语义与平台无关（第一个候选或空）。状态机走集合 + 试活，不调这个。
# _full 控制是否启用全端口批量尾巴（off 状态降频用）。
get_active_proxy_port() {
    _full="$1"
    _c=$(find_candidate_ports "$_full" 2>/dev/null || true)
    [ -n "$_c" ] || return 1
    printf '%s' "$_c" | awk '{print $1}'
}

# ------------------------------------------------------------------------------
# 4. 真实节点连通性（快路优先 + 失败并行兜底；有状态，直接调用禁命令替换）
# ------------------------------------------------------------------------------
test_single_endpoint() {
    _port="$1"; _host="$2"; _path="$3"
    # --disable（= -q）：不读用户 ~/.curlrc——否则用户配过的 proxy 会劫持这次探测，判据作废。
    _out=$(env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy -u NO_PROXY -u no_proxy \
        curl --disable -s -D - -o /dev/null --connect-timeout 5 --max-time 6 -x "http://127.0.0.1:$_port" "http://$_host$_path" 2>/dev/null)
    [ -n "$_out" ] || return 1
    printf '%s' "$_out" | grep -qi "Connection Established" && return 1
    _first=$(printf '%s' "$_out" | head -n 1)
    _code=$(printf '%s' "$_first" | grep -oE ' [0-9]{3} ' | tr -cd '0-9')
    case "$_code" in
        204|200|301|302|303|304|307|308) return 0;;
        *) return 1;;
    esac
}

_probe_endpoint_one() {
    _port="$1"; _h="$2"; _pa="$3"; _idx="$4"; _dir="$5"
    if test_single_endpoint "$_port" "$_h" "$_pa"; then
        printf '%s' "$_idx" > "$_dir/win" 2>/dev/null || true
    fi
}

test_real_connectivity() {
    _port="$1"
    # 快路端点按索引取值（cut 实现，避免 set -- 篡改位置参数；索引越界则回退并行）
    _fast_host=$(printf '%s' "$CHECK_HOSTS" | cut -d' ' -f$((LAST_GOOD_ENDPOINT + 1)) 2>/dev/null)
    _fast_path=$(printf '%s' "$CHECK_PATHS" | cut -d' ' -f$((LAST_GOOD_ENDPOINT + 1)) 2>/dev/null)
    if [ -n "$_fast_host" ] && [ -n "$_fast_path" ] \
        && test_single_endpoint "$_port" "$_fast_host" "$_fast_path"; then
        return 0
    fi
    _tmpdir="/tmp/envproxy_conn.$$"
    mkdir -p "$_tmpdir" 2>/dev/null || true
    # 逐个按索引展开 host/path，避免后台闭包竞态（参数在父进程展开后传值）
    _idx=0
    for _h in $CHECK_HOSTS; do
        _pa_for_idx=$(printf '%s' "$CHECK_PATHS" | cut -d' ' -f$((_idx + 1)) 2>/dev/null)
        if [ $_idx -ne $LAST_GOOD_ENDPOINT ] && [ -n "$_pa_for_idx" ]; then
            _probe_endpoint_one "$_port" "$_h" "$_pa_for_idx" "$_idx" "$_tmpdir" &
        fi
        _idx=$((_idx + 1))
    done
    _waited=0
    while [ $_waited -lt 70 ]; do
        if [ -f "$_tmpdir/win" ]; then
            LAST_GOOD_ENDPOINT=$(cat "$_tmpdir/win" 2>/dev/null || echo "$LAST_GOOD_ENDPOINT")
            rm -rf "$_tmpdir" 2>/dev/null || true
            wait 2>/dev/null || true
            return 0
        fi
        sleep 0.1
        _waited=$((_waited + 1))
    done
    rm -rf "$_tmpdir" 2>/dev/null || true
    wait 2>/dev/null || true
    return 1
}

# 15 秒节流 + 连续 NODE_FAIL_THRESHOLD 次失败才判死（恢复 1 次即判活并清零计数）
# 迟滞必须不对称（这不是可调口味，是判据本身）：判"断"的代价是「删变量 + 通知所有应用
# 重读环境」，影响机器上每一个应用；误留代理变量的代价只是多等一会儿。两个代价不对称，
# 判据就不许对称——一次探测不通不等于代理没了。反向约束同样成立："通"要快（1 次成功即认），
# 否则重连后要白等一个迟滞窗口。
# 节流缓存只认“同一端口”（单槽位：bash 3.2 无关联数组）。
# 同端口节流内直接给缓存结论；换端口一律重验——多候选试活时，
# 绝不会读到别的端口的旧结论（全局单槽在此会串味）。
# DIVERGE(Mac): Win 侧用哈希表按端口分槽（LastCheck / Alive / FailCount 各一份，见 Test-NodeAlive）；
# Mac 侧只有一个槽位（bash 3.2 无关联数组），因此失败计数也是全局的——别的端口失败会累计进
# 同一个计数。用户可见行为不变：判死只在"首选端口 + 非 Force"这条稳态路径上受计数影响，
# 候选试活一律 Force 单次判定，双轮去抖会把这点差异吸收掉。
test_node_alive() {
    _port="$1"; _force="${2:-0}"
    _now=$(date +%s)
    if [ "$_force" != "1" ] && [ "$_port" = "$NODE_CACHE_PORT" ]; then
        _age=$((_now - LAST_NODE_CHECK))
        if [ $_age -lt "$NODE_CHECK_THROTTLE_SEC" ]; then
            [ "$NODE_ALIVE" = "1" ] && return 0 || return 1
        fi
    fi
    LAST_NODE_CHECK="$_now"
    NODE_CACHE_PORT="$_port"
    if test_real_connectivity "$_port"; then
        NODE_FAIL_COUNT=0
        NODE_ALIVE=1
        return 0
    else
        NODE_FAIL_COUNT=$((NODE_FAIL_COUNT + 1))
        if [ "$_force" = "1" ] || [ $NODE_FAIL_COUNT -ge "$NODE_FAIL_THRESHOLD" ]; then
            NODE_ALIVE=0
        fi
        [ "$NODE_ALIVE" = "1" ] && return 0 || return 1
    fi
}

# 有序试活：按候选顺序逐个验证，首个真活的进 $CONFIRM_HIT，否则空（只读，不写状态）。
# 规则只有两条：
#   1) $2（上次验活过、仍在集合里）先用缓存结论试（节流窗口内零新增探测）；
#   2) 其余一律当场验（force=1）。集合抖动但首选仍活时，不烧探测、不改状态。
# 有状态：直接调用，结果进 $CONFIRM_HIT，禁止 $(...) 包裹。
CONFIRM_HIT=""

confirm_candidate_port() {
    _cands="$1"; _pref="$2"
    CONFIRM_HIT=""
    [ -n "$_cands" ] || return 0
    case "$_pref" in
        "") ;;
        *) if _in_list "$_pref" "$_cands"; then
               if test_node_alive "$_pref" 0; then CONFIRM_HIT="$_pref"; return 0; fi
           fi;;
    esac
    for _p in $_cands; do
        [ "$_p" = "$_pref" ] && continue
        if test_node_alive "$_p" 1; then CONFIRM_HIT="$_p"; return 0; fi
    done
    return 0
}

# 当前真实状态（有状态：直接调用，结果进 $CURRENT_STATE，禁止 $(...) 包裹）
get_current_state() {
    ROUND=$((ROUND + 1))
    if [ -n "$CACHED_PORT" ]; then
        if test_port_listening "$CACHED_PORT"; then
            # 在位复核（约每 10 轮一次，本机零流量）：代理退出后若有别的程序
            # 占了同一端口，握手不过立即丢缓存，不等 15 秒节点节流。
            # 置 off 后照常进主循环双轮去抖，不会单轮抖动。
            if [ $((ROUND % 10)) -eq 0 ]; then
                if ! test_http_proxy "$CACHED_PORT"; then
                    CACHED_PORT=""
                    CURRENT_STATE="off"
                    return 0
                fi
            fi
            if test_node_alive "$CACHED_PORT" 0; then
                CURRENT_STATE="on:$CACHED_PORT"
            else
                CACHED_PORT=""
                CURRENT_STATE="off"
            fi
            return 0
        fi
        sleep 2
        _cands=$(find_candidate_ports 1 || true)
        LAST_SEEN_SET="$_cands"
        confirm_candidate_port "$_cands" ""
        if [ -n "$CONFIRM_HIT" ]; then
            # 过渡后首个验活：立即采用（不等节流），改端口/换软件秒级恢复
            CACHED_PORT="$CONFIRM_HIT"
            LAST_ALIVE_PORT="$CONFIRM_HIT"
            CURRENT_STATE="on:$CONFIRM_HIT"
        else
            CACHED_PORT=""
            CURRENT_STATE="off"
        fi
        return 0
    fi
    if [ $((ROUND % 10)) -eq 0 ]; then _full=1; else _full=0; fi
    _cands=$(find_candidate_ports "$_full" || true)
    if [ "$_cands" != "$LAST_SEEN_SET" ]; then
        # 集合变化 = 强信号（新到、离开、换端口、增减成员）：走一遍有序试活。
        # 上次验活的仍在就认回它（缓存结论，零新增探测）；新面孔当场验 → 秒级收敛。
        LAST_SEEN_SET="$_cands"
        _pref="$LAST_ALIVE_PORT"
        if [ -n "$_pref" ] && ! _in_list "$_pref" "$_cands"; then _pref=""; fi
        confirm_candidate_port "$_cands" "$_pref"
        if [ -n "$CONFIRM_HIT" ]; then
            CACHED_PORT="$CONFIRM_HIT"
            LAST_ALIVE_PORT="$CONFIRM_HIT"
            CURRENT_STATE="on:$CONFIRM_HIT"
        else
            CURRENT_STATE="off"
        fi
    else
        # 集合稳定：节流单查（上次验活的优先，否则第一个），防抖优先。
        # 不变量：on 只可能来自本轮候选集——候选集是过了"监听 + CONNECT 握手"两道门的，
        # 从集合之外挑端口（例如沿用上轮记住的端口）会给已经消失的端口报 on：
        # 既违反三层判据，又会在端口消失后反复清零调用方的去抖计数，
        # 把"退出软件后秒级删变量"拖成几十秒。故候选集为空 = 本机没有代理在监听，
        # 节点结论无从谈起，直接 off。
        _check=""
        if [ -n "$_cands" ]; then
            _check="$LAST_ALIVE_PORT"
            if [ -z "$_check" ] || ! _in_list "$_check" "$_cands"; then
                _check=$(printf '%s' "$_cands" | awk '{print $1}')
            fi
        fi
        if [ -n "$_check" ]; then
            if test_node_alive "$_check" 0; then
                CACHED_PORT="$_check"
                LAST_ALIVE_PORT="$_check"
                CURRENT_STATE="on:$_check"
            else
                CURRENT_STATE="off"
            fi
        else
            CURRENT_STATE="off"
        fi
    fi
}

# ------------------------------------------------------------------------------
# 5. 自启动（LaunchAgent + 固定定位器；文件夹可任意移动）
# ------------------------------------------------------------------------------
update_path_record() {
    mkdir -p "$ENVPROXY_HOME" 2>/dev/null || true
    printf '%s\n' "$SCRIPT_PATH" > "$PATH_CONF" 2>/dev/null || true
}

# plist 的语义 = "登录时把它拉起来"，仅此而已——刻意不声明 KeepAlive。
#   对齐的依据：Windows 侧的自启动就是一个 Run 键（登录时执行一次），监控被停掉或
#   自行退出后不会复活。这里若写 KeepAlive，launchd 会在 job 主进程退出后无条件重启它，
#   而定位器末尾用 exec 把监控变成 job 主进程，于是直接破坏两件事：
#     - "2-停止监控"停不住：停止后约 10 秒（默认 ThrottleInterval）被自动拉回，
#       变量跟着重新注入，"暂停到下次登录"的承诺失效；
#     - 每个启动周期还会多一次无谓的 fork：job 被反复拉起，而定位器的单实例检查
#       立刻让它退出，如此每 10 秒一轮。
#   运行期的可靠性交给监控自身（互斥锁 + 自启动自愈），与 Windows 同语义。
#   将来若真的要"崩溃自动重启"，必须同时让"停止"能被系统表达出来（stop 里 bootout），
#   否则同一个意图会由两套机制互相打架。
get_plist_content() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$PLIST_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>$LOCATOR_PATH</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>WorkingDirectory</key><string>$ENVPROXY_HOME</string>
  <key>StandardOutPath</key><string>$ENVPROXY_HOME/monitor.stdout.log</string>
  <key>StandardErrorPath</key><string>$ENVPROXY_HOME/monitor.stderr.log</string>
</dict>
</plist>
EOF
}

set_autorun() {
    mkdir -p "$ENVPROXY_HOME" "$HOME/Library/LaunchAgents" 2>/dev/null || true
    if [ -f "$SCRIPT_DIR/locator.sh" ]; then
        cp "$SCRIPT_DIR/locator.sh" "$LOCATOR_PATH" 2>/dev/null || true
        chmod +x "$LOCATOR_PATH" 2>/dev/null || true
    fi
    get_plist_content > "$PLIST_PATH" 2>/dev/null || true
    update_path_record
    _uid=$(id -u)
    launchctl bootout "gui/$_uid/$PLIST_LABEL" 2>/dev/null || true
    if ! launchctl bootstrap "gui/$_uid" "$PLIST_PATH" 2>/dev/null; then
        launchctl load "$PLIST_PATH" 2>/dev/null || true
    fi
}

remove_autorun() {
    _uid=$(id -u)
    launchctl bootout "gui/$_uid/$PLIST_LABEL" 2>/dev/null || true
    launchctl bootout "gui/$_uid" "$PLIST_PATH" 2>/dev/null || true
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH" 2>/dev/null || true
}

# 自启动自愈：让两处固定位置的产物**与当前代码一致**——不只是"存在"。
# 判据取内容而非存在，理由是升级路径：改完脚本若没走"安装"，固定位置里留着的仍是
# 旧 plist / 旧定位器（搜索算法、参数、乃至 KeepAlive 这类语义都会停在旧值上）。
# 每次自查 = 让系统状态收敛到当前代码，不依赖用户记得重装。
repair_autorun() {
    _need=0
    [ -f "$PLIST_PATH" ] || _need=1
    [ -f "$LOCATOR_PATH" ] || _need=1
    if [ $_need -eq 0 ]; then
        # 命令替换会吃掉末尾换行，所以这里比的是"生成出来的代码"是否一致，行尾不算差异。
        _want_plist=$(get_plist_content)
        _have_plist=$(cat "$PLIST_PATH" 2>/dev/null)
        [ "$_have_plist" = "$_want_plist" ] || _need=1
        if [ -f "$SCRIPT_DIR/locator.sh" ]; then
            cmp -s "$SCRIPT_DIR/locator.sh" "$LOCATOR_PATH" || _need=1
        fi
        launchctl list 2>/dev/null | grep -qF "$PLIST_LABEL" || _need=1
    fi
    if [ $_need -eq 1 ]; then
        set_autorun || true
        log_msg "已自动修复开机自启动（定位器/自启动项缺失、损坏或与当前版本不一致）"
    fi
}

# ------------------------------------------------------------------------------
# 6. shell 集成（标记块幂等插入/精确移除）
# ------------------------------------------------------------------------------
insert_shell_hooks() {
    for _rc in "$HOME/.zshenv" "$HOME/.zshrc"; do
        touch "$_rc" 2>/dev/null || continue
        if ! grep -qF "$HOOK_START" "$_rc" 2>/dev/null; then
            printf '\n%s\n%s\n%s\n' "$HOOK_START" "$HOOK_LINE" "$HOOK_END" >> "$_rc" 2>/dev/null || true
        fi
    done
    for _rc in "$HOME/.bash_profile" "$HOME/.bashrc"; do
        [ -f "$_rc" ] || continue
        if ! grep -qF "$HOOK_START" "$_rc" 2>/dev/null; then
            printf '\n%s\n%s\n%s\n' "$HOOK_START" "$HOOK_LINE" "$HOOK_END" >> "$_rc" 2>/dev/null || true
        fi
    done
}

remove_shell_hooks() {
    for _rc in "$HOME/.zshenv" "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zlogin" "$HOME/.bash_profile" "$HOME/.bashrc"; do
        [ -f "$_rc" ] || continue
        _tmp="$_rc.tmp.$$"
        awk -v s="$HOOK_START" -v e="$HOOK_END" '$0==s{skip=1;next} $0==e{skip=0;next} !skip' "$_rc" > "$_tmp" 2>/dev/null \
            && mv "$_tmp" "$_rc" 2>/dev/null || rm -f "$_tmp" 2>/dev/null || true
    done
}

# ------------------------------------------------------------------------------
# 7. 监控进程管理（PID 文件 + 命令行校验 + 优雅停止）
# ------------------------------------------------------------------------------
get_monitor_pid() {
    if [ -f "$PID_FILE" ]; then
        _pid=$(tr -cd '0-9' < "$PID_FILE" 2>/dev/null)
        if [ -n "$_pid" ] && [ "$_pid" != "$$" ]; then
            if kill -0 "$_pid" 2>/dev/null; then
                _args=$(ps -p "$_pid" -o args= 2>/dev/null)
                case "$_args" in
                    *envproxy.sh*)
                        case "$_args" in
                            *install*|*stop*|*uninstall*|*status*|*purge*) ;;
                            *) printf '%s' "$_pid"; return 0;;
                        esac
                        ;;
                esac
            fi
        fi
    fi
    if command -v pgrep >/dev/null 2>&1; then
        for _pid in $(pgrep -f "envproxy\.sh$" 2>/dev/null); do
            [ "$_pid" != "$$" ] || continue
            printf '%s' "$_pid"
            return 0
        done
    else
        _found=$(ps ax -o pid=,args= 2>/dev/null | grep -E "envproxy\.sh$" | grep -v grep | head -n 1 | awk '{print $1}')
        if [ -n "$_found" ] && [ "$_found" != "$$" ]; then printf '%s' "$_found"; return 0; fi
    fi
    return 1
}

start_monitor() {
    _force="$1"
    _existing=$(get_monitor_pid || true)
    if [ -n "$_existing" ]; then
        _args=$(ps -p "$_existing" -o args= 2>/dev/null || echo "")
        _same=0
        case "$_args" in *"$SCRIPT_PATH"*) _same=1;; esac
        if [ "$_force" != "1" ] && [ "$_same" = "1" ]; then
            echo "监控进程已在运行（路径一致），跳过启动。"
            return 0
        fi
        if [ "$_force" = "1" ]; then echo "正在重启监控以加载当前最新代码..."; else echo "检测到旧位置的监控进程，正在迁移到当前路径..."; fi
        stop_monitor || true
    fi
    nohup bash "$SCRIPT_PATH" >/dev/null 2>&1 < /dev/null &
    # shellcheck disable=SC2312
    disown 2>/dev/null || true
    echo "监控进程已启动。"
}

stop_monitor() {
    _existing=$(get_monitor_pid || true)
    if [ -z "$_existing" ]; then echo "监控进程未在运行。"; return 0; fi
    _args=$(ps -p "$_existing" -o args= 2>/dev/null || echo "")
    _target_dir="$MONITOR_DIR"
    _from_args=$(printf '%s' "$_args" | grep -oE '/[^ ]*envproxy\.sh' | head -n 1)
    if [ -n "$_from_args" ]; then
        _target_dir="$(dirname "$_from_args")/monitor"
    fi
    mkdir -p "$_target_dir" 2>/dev/null || true
    printf 'stop\n' > "$_target_dir/stop.flag" 2>/dev/null || true
    _i=0
    while [ $_i -lt 60 ]; do
        get_monitor_pid >/dev/null 2>&1 || break
        sleep 0.1
        _i=$((_i + 1))
    done
    _again=$(get_monitor_pid || true)
    if [ -n "$_again" ]; then
        kill "$_again" 2>/dev/null || true
        sleep 1
        _ghost=$(get_monitor_pid || true)
        [ -n "$_ghost" ] && kill -9 "$_ghost" 2>/dev/null || true
        sleep 0.5
    fi
    rm -f "$_target_dir/stop.flag" "$STOP_FLAG" 2>/dev/null || true
    if [ "$_target_dir" != "$MONITOR_DIR" ] && [ -d "$_target_dir" ]; then
        if [ -z "$(ls -A "$_target_dir" 2>/dev/null)" ]; then rmdir "$_target_dir" 2>/dev/null || true; fi
    fi
    echo "监控进程已停止。"
}

# ------------------------------------------------------------------------------
# 8. 监控主循环（双轮确认去抖；任何单轮异常都不致命）
# ------------------------------------------------------------------------------
run_monitor_loop() {
    _lockdir="/tmp/envproxy_monitor.lock"
    if ! mkdir "$_lockdir" 2>/dev/null; then
        _e=$(get_monitor_pid || true)
        [ -n "$_e" ] && return 0
        rmdir "$_lockdir" 2>/dev/null || true
        mkdir "$_lockdir" 2>/dev/null || return 0
    fi
    # shellcheck disable=SC2064
    trap "rmdir \"$_lockdir\" 2>/dev/null || true" EXIT
    _e=$(get_monitor_pid || true)
    if [ -n "$_e" ]; then rmdir "$_lockdir" 2>/dev/null || true; trap - EXIT; return 0; fi

    rm -f "$STOP_FLAG" 2>/dev/null || true
    mkdir -p "$MONITOR_DIR" 2>/dev/null || true
    printf '%s\n' "$$" > "$PID_FILE" 2>/dev/null || true
    update_path_record
    log_msg "==== 监控启动 ===="

    CURRENT_STATE="off"
    get_current_state || true
    apply_state "$CURRENT_STATE" || true
    _last="$CURRENT_STATE"
    _pending=""
    _pending_n=0
    _repair=0
    _self=0

    while [ ! -f "$STOP_FLAG" ]; do
        if [ ! -f "$SCRIPT_PATH" ]; then _self=1; break; fi
        get_current_state || CURRENT_STATE="$_last"
        _st="$CURRENT_STATE"
        if [ "$_st" != "$_last" ]; then
            if [ "$_st" = "$_pending" ]; then _pending_n=$((_pending_n + 1)); else _pending="$_st"; _pending_n=1; fi
            if [ $_pending_n -ge 2 ]; then
                apply_state "$_st" || true
                _last="$_st"
                _pending=""; _pending_n=0
            fi
        else
            _pending=""; _pending_n=0
        fi
        _repair=$((_repair + 1))
        # 每 30 轮自愈一次（轮间隔 on 2 秒 / off 3 秒 → 约 60–90 秒一次）。
        # 按轮计数而不是按秒：轮询节奏本身就是可变配置，写死秒数会随节奏改动而失准。
        if [ $_repair -ge 30 ]; then
            _repair=0
            repair_autorun || true
            # 变量自检：apply_state 只在状态翻转时动手，稳态下它永远不会被调用，
            # 于是"别的东西改坏了变量"没人纠正。这里按同一周期整表核对，不齐就补回来
            # （幂等，齐了则零写入）。只核对我们本该持有的那几个，与用户自己的变量无关。
            case "$_last" in
                on:*) sync_user_env_vars "${_last#on:}" || true ;;
            esac
        fi
        if [ "$_last" = "off" ]; then sleep 3; else sleep 2; fi
    done

    if [ "$_self" = "1" ]; then
        rm -rf "$MONITOR_DIR" 2>/dev/null || true
        if [ -d "$SCRIPT_DIR" ] && [ -z "$(ls -A "$SCRIPT_DIR" 2>/dev/null)" ]; then
            rmdir "$SCRIPT_DIR" 2>/dev/null || true
        fi
    else
        log_msg "==== 监控退出（收到停止信号）===="
        rm -f "$PID_FILE" "$STOP_FLAG" 2>/dev/null || true
    fi
    rmdir "$_lockdir" 2>/dev/null || true
    trap - EXIT
}

# ------------------------------------------------------------------------------
# 9. 在线更新（检查更新 + 一键升级；状态显示只读，动手只在这里）
# ------------------------------------------------------------------------------
# 更新源：GitHub Release（releases/latest → 标签源码包整包覆盖）。
#   不用 git pull（用户机器未必有 git）、不用单文件拉取（新版增删文件会漏）。
#   校验通过才覆盖：包内 VERSION 与目标一致 + 核心文件存在，否则中止且不动现版。

get_project_root() {
    dirname "$SCRIPT_DIR"
}

get_local_version() {
    _vf="$(get_project_root)/VERSION"
    [ -f "$_vf" ] || return 1
    tr -d ' \t\r\n' < "$_vf" 2>/dev/null
}

get_update_repo() {
    if command -v git >/dev/null 2>&1; then
        _u=$(git config --get remote.origin.url 2>/dev/null || true)
        case "$_u" in
            *github.com*)
                _r=$(printf '%s' "$_u" | sed -E 's#.*github\.com[:/]([^/]+)/([^/]+)#\1/\2#; s#\.git$##')
                if [ -n "$_r" ]; then printf '%s' "$_r"; return 0; fi
                ;;
        esac
    fi
    printf '%s' "$UPDATE_REPO_DEFAULT"
}

# 版本比较：按 . 分段逐段数值比。输出 1（A 新）/ 0（相等）/ -1（A 旧）。
compare_versions() {
    awk -v a="$1" -v b="$2" 'BEGIN{
        na=split(a,pa,"."); nb=split(b,pb,".");
        n=(na>nb?na:nb);
        for(i=1;i<=n;i++){ xa=(i<=na?pa[i]+0:0); xb=(i<=nb?pb[i]+0:0);
            if(xa>xb){print 1; exit} if(xa<xb){print -1; exit} }
        print 0 }'
}

# 取文本：先按当前环境（含代理变量）取，失败再直连重试一次。
# DIVERGE(Mac): Win 侧走系统代理恒为直连，需显式经 127.0.0.1 重试；
# Mac 侧 curl 继承环境变量代理，这里反向补一次直连回退，两方向都覆盖。
fetch_update_text() {
    _out=$(curl -fsSL --max-time 8 -A "EnvProxyUpdate" "$1" 2>/dev/null) \
        && { printf '%s' "$_out"; return 0; }
    env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy \
        curl -fsSL --max-time 8 --noproxy '*' -A "EnvProxyUpdate" "$1" 2>/dev/null
}

fetch_update_file() {
    curl -fsSL --max-time 60 -A "EnvProxyUpdate" -o "$2" "$1" 2>/dev/null && return 0
    env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy \
        curl -fsSL --max-time 60 --noproxy '*' -A "EnvProxyUpdate" -o "$2" "$1" 2>/dev/null
}

# 查最新 Release：成功时置 REMOTE_VERSION / REMOTE_TAG 并返回 0，否则返回 1（只读）。
REMOTE_VERSION=""
REMOTE_TAG=""

get_remote_version() {
    _repo=$(get_update_repo)
    _json=$(fetch_update_text "https://api.github.com/repos/$_repo/releases/latest" || true)
    [ -n "$_json" ] || return 1
    _tag=$(printf '%s' "$_json" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
    [ -n "$_tag" ] || return 1
    REMOTE_TAG="$_tag"
    REMOTE_VERSION=$(printf '%s' "$_tag" | sed -E 's/^v//')
    [ -n "$REMOTE_VERSION" ] || return 1
    return 0
}

update_envproxy() {
    _yes="$1"
    echo "======== EnvProxy 检查更新 ========"
    _local=$(get_local_version || true)
    if [ -n "$_local" ]; then echo "本地版本 : v$_local"; else echo "本地版本 : 未知"; fi
    echo "正在检查最新版本（最多等几秒）..."
    if ! get_remote_version; then
        echo "最新版本 : 检查失败（网络不可达或 GitHub API 限流）"
        echo "请稍后重试；翻墙开/关换个状态再试一次也常有效。"
        return 0
    fi
    echo "最新版本 : $REMOTE_TAG"
    _cmp=$(compare_versions "$REMOTE_VERSION" "$_local" || true)
    if [ -n "$_local" ] && [ "$_cmp" -le 0 ] 2>/dev/null; then
        echo "已是最新，无需更新。"
        return 0
    fi
    # 防呆：点的是备份文件夹时警告（正式路径以 path.conf 记录为准）
    _reg=""
    [ -f "$PATH_CONF" ] && _reg=$(head -n 1 "$PATH_CONF" 2>/dev/null | tr -d '\r\n' || true)
    if [ -n "$_reg" ] && [ "$_reg" != "$SCRIPT_PATH" ]; then
        echo "注意：你现在点的是 [$SCRIPT_PATH]，"
        echo "但正式安装在 [$_reg]。"
        echo "继续会更新【当前这个文件夹】并把它切换为正式安装。"
    fi
    if [ "$_yes" != "1" ]; then
        printf "发现新版 %s，是否更新？[y/N]: " "$REMOTE_TAG"
        _ans=""
        if read -r _ans < /dev/tty 2>/dev/null; then :; else _ans=""; fi
        case "$_ans" in [Yy]*) ;; *) echo "已取消，未做任何改动。"; return 0;; esac
    fi
    # 下载标签源码包（整包，防漏文件）
    _repo=$(get_update_repo)
    _url="https://codeload.github.com/$_repo/tar.gz/refs/tags/$REMOTE_TAG"
    # DIVERGE(Mac): Mac 取 tar.gz + tar；Win 取 zip + Expand-Archive（见 envproxy.ps1）。
    _safe_tag=$(printf '%s' "$REMOTE_TAG" | tr -c 'A-Za-z0-9._-' '_')
    _tgz="/tmp/envproxy_update-$_safe_tag.tar.gz"
    _exdir="/tmp/envproxy_update-$_safe_tag-src"
    echo "正在下载新版..."
    rm -f "$_tgz" 2>/dev/null || true
    rm -rf "$_exdir" 2>/dev/null || true
    mkdir -p "$_exdir" 2>/dev/null || { echo "更新失败：临时目录建不起，未做任何改动。"; return 0; }
    if ! fetch_update_file "$_url" "$_tgz"; then
        echo "更新失败：下载失败（网络不可达），未做任何改动。"
        rm -f "$_tgz" 2>/dev/null || true
        rm -rf "$_exdir" 2>/dev/null || true
        return 0
    fi
    echo "正在解压并校验..."
    if ! tar -xzf "$_tgz" -C "$_exdir" 2>/dev/null; then
        echo "更新失败：解压失败，未做任何改动。"
        rm -f "$_tgz" 2>/dev/null || true
        rm -rf "$_exdir" 2>/dev/null || true
        return 0
    fi
    _top=$(find "$_exdir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n 1)
    if [ -n "$_top" ]; then _src="$_top"; else _src="$_exdir"; fi
    _srcver=$(tr -d ' \t\r\n' < "$_src/VERSION" 2>/dev/null || true)
    if [ -z "$_srcver" ] || [ "$_srcver" != "$REMOTE_VERSION" ]; then
        echo "更新失败：校验失败（包内 VERSION 与目标版本不一致），未做任何改动。"
        rm -f "$_tgz" 2>/dev/null || true
        rm -rf "$_exdir" 2>/dev/null || true
        return 0
    fi
    if [ ! -f "$_src/mac/envproxy.sh" ]; then
        echo "更新失败：校验失败（包内缺核心文件），未做任何改动。"
        rm -f "$_tgz" 2>/dev/null || true
        rm -rf "$_exdir" 2>/dev/null || true
        return 0
    fi
    # 停监控 → 字节覆盖（跳过 monitor，保日志）→ 走一次万能修复收尾
    echo "正在安装新版（保留日志，原监控先停）..."
    stop_monitor >/dev/null 2>&1 || true
    _root=$(get_project_root)
    _copy_ok=1
    for _e in "$_src"/* "$_src"/.[!.]*; do
        [ -e "$_e" ] || continue
        _b=$(basename "$_e" 2>/dev/null || echo "")
        case "$_b" in .git) continue;; esac
        if [ -f "$_e" ]; then
            cp -p "$_e" "$_root/" 2>/dev/null || _copy_ok=0
        elif [ -d "$_e" ]; then
            mkdir -p "$_root/$_b" 2>/dev/null || { _copy_ok=0; continue; }
            for _c in "$_e"/* "$_e"/.[!.]*; do
                [ -e "$_c" ] || continue
                _cb=$(basename "$_c" 2>/dev/null || echo "")
                # mac/monitor 与 win/monitor：本机运行时黑匣子，永不覆盖
                [ "$_cb" = "monitor" ] && continue
                cp -pR "$_c" "$_root/$_b/" 2>/dev/null || _copy_ok=0
            done
        fi
    done
    rm -f "$_tgz" 2>/dev/null || true
    rm -rf "$_exdir" 2>/dev/null || true
    if [ "$_copy_ok" != "1" ]; then
        echo "更新失败：文件写入失败。请点一次 1-安装 修复后重试。"
        return 0
    fi
    install_envproxy
    echo "已更新到 $REMOTE_TAG。"
}

# ------------------------------------------------------------------------------
# 10. 子命令
# ------------------------------------------------------------------------------
install_envproxy() {
    echo "======== EnvProxy 安装 (macOS) ========"
    set_autorun
    echo "[1/3] 开机自启动：已写入（LaunchAgent + 固定定位器）"
    insert_shell_hooks
    echo "[2/3] 终端集成：已写入 shell hook（zsh/bash，新开终端生效）"
    update_path_record
    start_monitor 1
    echo "[3/3] 监控进程：已启动"
    CURRENT_STATE="off"
    get_current_state || true
    apply_state "$CURRENT_STATE" || true
    sleep 1
    echo ""
    show_status
    echo ""
    echo "提示：之后【新打开】的终端/程序自动获得代理；"
    echo "      已经开着的旧窗口不会自动变化，重开一个即可。"
}

uninstall_envproxy() {
    _purge="$1"
    echo "======== EnvProxy 卸载（一键恢复原状）========"
    stop_monitor || true
    remove_autorun
    rm -f "$LOCATOR_PATH" "$PATH_CONF" 2>/dev/null || true
    remove_shell_hooks
    _remove_log=0
    if [ "$_purge" = "1" ]; then
        _remove_log=1
    else
        printf "历史日志 monitor/monitor.log 是否保留？[Y] 保留（默认） / [N] 彻底删除: "
        _choice=""
        if read -r _choice < /dev/tty 2>/dev/null; then :; else _choice=""; fi
        case "$_choice" in [Nn]*) _remove_log=1;; *) _remove_log=0;; esac
    fi
    if [ $_remove_log -eq 1 ]; then
        rm -rf "$MONITOR_DIR" 2>/dev/null || true
    else
        rm -f "$PID_FILE" "$STOP_FLAG" 2>/dev/null || true
        if [ -d "$MONITOR_DIR" ] && [ -z "$(ls -A "$MONITOR_DIR" 2>/dev/null)" ]; then
            rm -rf "$MONITOR_DIR" 2>/dev/null || true
        fi
    fi
    _ghost=$(get_monitor_pid || true)
    if [ -n "$_ghost" ]; then kill -9 "$_ghost" 2>/dev/null || true; sleep 0.5; fi
    remove_user_env_vars
    # launchd 的两个重定向文件（StandardOutPath/StandardErrorPath）是运行时管道，不是黑匣子：
    # 一律清掉，"恢复到安装前的状态"才成立。唯一的黑匣子是 monitor/monitor.log，
    # 它的去留由上面那次询问决定。
    rm -f "$ENVPROXY_HOME/monitor.stdout.log" "$ENVPROXY_HOME/monitor.stderr.log" 2>/dev/null || true
    # 非 purge 也只保留项目内日志：固定目录空了就删，不留空壳
    if [ -d "$ENVPROXY_HOME" ] && [ -z "$(ls -A "$ENVPROXY_HOME" 2>/dev/null)" ]; then
        rmdir "$ENVPROXY_HOME" 2>/dev/null || true
    fi
    echo "[完成] 监控已停、自启动已删、定位器已清、代理变量已清除。"
    if [ $_remove_log -eq 1 ]; then
        echo "        历史日志已一并彻底删除。"
    else
        echo "        历史日志保留在 monitor/monitor.log（黑匣子，供日后排查）。"
    fi
    echo "        电脑已恢复到安装前的状态，无需重启。"
}

show_status() {
    echo "======== EnvProxy 状态 (macOS) ========"
    _m=$(get_monitor_pid || true)
    if [ -n "$_m" ]; then echo "监控进程 : 运行中 (PID $_m)"; else echo "监控进程 : 未运行"; fi
    if launchctl list 2>/dev/null | grep -qF "$PLIST_LABEL"; then
        echo "开机自启 : 已启用"
    else
        if [ -f "$PLIST_PATH" ]; then echo "开机自启 : 已写入但未加载"; else echo "开机自启 : 未启用"; fi
    fi
    _port=$(get_active_proxy_port 1 2>/dev/null || true)
    if [ -n "$_port" ]; then
        echo "翻墙代理 : 已开启（本地端口 $_port 监听中）"
    else
        echo "翻墙代理 : 未检测到（当前无翻墙代理在运行）"
    fi
    _cur=$(get_current_proxy_port 2>/dev/null || true)
    if [ -n "$_cur" ]; then echo "代理变量 : 已注入 (http://127.0.0.1:$_cur)"; else echo "代理变量 : 无（直连状态）"; fi
    # 版本信息（只读：查不到只提示，不写文件、不提问）
    _local_ver=$(get_local_version || true)
    if [ -n "$_local_ver" ]; then echo "本地版本 : v$_local_ver"; else echo "本地版本 : 未知"; fi
    if get_remote_version; then
        echo "最新版本 : $REMOTE_TAG"
        _cmp=$(compare_versions "$REMOTE_VERSION" "$_local_ver" || true)
        if [ -n "$_local_ver" ] && [ "$_cmp" -le 0 ] 2>/dev/null; then
            echo "更新状态 : 已是最新"
        elif [ -n "$_local_ver" ]; then
            echo "更新状态 : 发现新版，用 5-检查更新 可升级"
        else
            echo "更新状态 : 可用 5-检查更新 升级"
        fi
    else
        echo "最新版本 : 检查失败（网络不可达，稍后重试）"
        echo "更新状态 : 未知"
    fi
    echo "---------------- 最近日志 ----------------"
    if [ -f "$LOG_FILE" ]; then
        tail -n 3 "$LOG_FILE" 2>/dev/null | sed 's/^/  /' || echo "  （暂无日志）"
    else
        echo "  （暂无日志）"
    fi
    echo "=================================="
}

# ------------------------------------------------------------------------------
# 11. 入口分派（兼容大小写与 --/— 前缀，方便 Windows 用户迁移）
# ------------------------------------------------------------------------------
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
    install) install_envproxy;;
    stop) stop_monitor; remove_user_env_vars; echo "代理变量已清除，当前恢复直连。";;
    uninstall) uninstall_envproxy "$_PURGE";;
    status) show_status;;
    update) update_envproxy "$_YES";;
    "") run_monitor_loop;;
    *) echo "用法: bash $0 {install|stop|uninstall|status|update} [--purge] [--yes]"; exit 1;;
esac
