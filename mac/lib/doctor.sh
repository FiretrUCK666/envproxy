# ==============================================================================
#  doctor.sh — 体检层：系统代理各层的读取、判定与修复（macOS 侧）
#  由入口 envproxy.sh 按固定顺序 source，不单独运行。
#
#  职责边界（改这个文件前先读这一段）：
#    可以有 —— 探测系统代理各层、按判据给结论、修复、读写备份
#    不许有 —— 打印任何屏幕内容、读用户输入、进菜单循环、改环境变量
#  界面住在 ops（菜单）里，这一层只产出数据。
#  这样它只依赖 base（+ probe 的 _port_alive），不反向调 ops，不产生新的依赖环。
#
#  DIVERGE(Mac): 三处与 Windows 必然不同，原因写在各处。
#    1) 系统代理是「每个网络服务一份」（Wi-Fi、有线、VPN 各存一份），不是全机一份。
#       所以必须遍历全部服务，不能只查当前位置。
#    2) 改它需要管理员权限，走系统密码框（osascript），不走 sudo。
#    3) 没有 WinHTTP 那一层。
#
#  判据（唯一一处，见 sysproxy_verdict）：与 Windows 侧逐条同形（门禁 6 核对）。
#    地址是本机回环 + 端口连不上 = 可修；其余一律不动。
#    回环这条判据站得住：公司/学校代理的地址一定是真实 IP 或域名，不可能写成
#    127.0.0.1（那是「我自己这台机器」的意思）。所以「回环」= 「某个本机程序写的」，
#    「端口死」= 「写它的程序不在了」。两条客观事实叠加，不是猜。
# ==============================================================================

# 判定结论词（与 Windows 侧 $SysProxyKinds 逐字同形，门禁 6 核对）
SYSPROXY_KIND_CLEAN="clean"                  # 压根没设代理
SYSPROXY_KIND_BLOCKING="residue-blocking"    # 手动代理指向死端口：真断网，最高优先级
SYSPROXY_KIND_SLOWING="residue-slowing"      # 自动配置脚本指向死端口：能上网但会卡几秒
SYSPROXY_KIND_ALIVE="alive"                  # 回环地址 + 端口活着：翻墙软件正在用，不动
SYSPROXY_KIND_FOREIGN="foreign"              # 不是回环：公司/学校代理，工具不碰
SYSPROXY_KIND_MANAGED="managed"              # 被描述文件/策略管着：改了也会被改回，不动

# 「哪个结论允许被修」只有一处：**只有 residue 两类**。
# 界面要判断「这项能不能修」时调这个，不许自己写字符串比较——
# 那样加一类结论就会漏掉界面那一处。
sysproxy_fixable() {
    case "${1:-}" in
        "$SYSPROXY_KIND_BLOCKING"|"$SYSPROXY_KIND_SLOWING") return 0 ;;
    esac
    return 1
}

# ------------------------------------------------------------------------------
# 1. 纯判据：给定事实，说出结论（不碰系统、不碰网络，便于回归）
# ------------------------------------------------------------------------------
#   $1 地址     $2 端口（0 = 未知）    $3 死活：alive / dead / unknown
#   $4 被策略管着：1 / 0              $5 层：manual / pac
#
# 「说不清」(unknown) 必须归到不许动的结论里：拿不准的时候不动，是这一层唯一安全的默认。
# 判成可修然后删掉一个其实在用的代理，代价是用户唯一的上网路径没了——两个方向的代价
# 不对称，判据就不许对称。
sysproxy_verdict() {
    _spv_url="${1:-}"; _spv_port="${2:-0}"; _spv_alive="${3:-unknown}"
    _spv_managed="${4:-0}"; _spv_layer="${5:-manual}"
    [ "$_spv_managed" = "1" ] && { printf '%s' "$SYSPROXY_KIND_MANAGED"; return 0; }
    [ -z "$_spv_url" ] && [ "$_spv_port" -le 0 ] 2>/dev/null && { printf '%s' "$SYSPROXY_KIND_CLEAN"; return 0; }
    # 不是本机回环：公司/学校代理，工具不碰
    is_loopback_url "$_spv_url" || { printf '%s' "$SYSPROXY_KIND_FOREIGN"; return 0; }
    [ "$_spv_alive" = "unknown" ] && { printf '%s' "$SYSPROXY_KIND_FOREIGN"; return 0; }
    [ "$_spv_alive" = "alive" ] && { printf '%s' "$SYSPROXY_KIND_ALIVE"; return 0; }
    if [ "$_spv_layer" = "pac" ]; then
        printf '%s' "$SYSPROXY_KIND_SLOWING"
    else
        printf '%s' "$SYSPROXY_KIND_BLOCKING"
    fi
    return 0
}

# 端口死活的三态判定。
#
# **不调 ops 层的 _port_alive**：那会让 doctor 反向依赖 ops，门禁 1 会拦
# （依赖不成环）。这里只做一次直连，判据与它一致：连得上 = alive。
# 用 curl 而不是 nc：base 层已经有 curl_direct（探测层也用同一条路），
# 而 nc -G 在部分 macOS 版本上不支持，得先探——那是 probe 层的事，这里不重复。
sysproxy_port_state() {
    _sps_addr="${1:-}"; _sps_port="${2:-0}"
    [ -n "$_sps_addr" ] && [ "$_sps_port" -gt 0 ] 2>/dev/null || { printf 'unknown'; return 0; }
    if curl_direct --disable -s -o /dev/null --connect-timeout 1 --max-time 2 \
        --noproxy '' -p -x "http://$_sps_addr:$_sps_port" "http://127.0.0.1:9/" 2>/dev/null; then
        printf 'alive'
    else
        printf 'dead'
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 2. 读出全部网络服务的代理设置
# ------------------------------------------------------------------------------
# 每个网络服务一份，形状固定（networksetup 的输出）：
#   Enabled: Yes / No
#   Server: 127.0.0.1
#   Port: 7078
#
# **必须遍历全部服务**：研究里的真实案例是「公司 VPN 上残留了代理、Wi-Fi 上没有」，
# 只查当前那个就会漏。服务名从 listallnetworkservices 动态取，不写死 "Wi-Fi"
# ——用户的网卡可能叫「雷雳以太网」「USB 10/100/1000 LAN」。
#
# 带 * 前缀的是被停用的服务，跳过：改停用的服务没有意义，
# 而它的名字里带 *，传回 networksetup 会报参数无效。
sysproxy_list_services() {
    networksetup -listallnetworkservices 2>/dev/null | while IFS= read -r _sls_l; do
        case "$_sls_l" in
            ''|'*'*) continue ;;
            'An asterisk'*|'一个星号'*) continue ;;
        esac
        printf '%s\n' "$_sls_l"
    done
}

# 读一个服务的一类代理。输出三行：enabled / host / port。
# $1 服务名  $2 类型（web / secureweb / socksfirewall / autoproxy）
_sysproxy_read_one() {
    _sro_svc="$1"; _sro_kind="$2"
    case "$_sro_kind" in
        web)         _sro_out=$(networksetup -getwebproxy "$_sro_svc" 2>/dev/null) ;;
        secureweb)   _sro_out=$(networksetup -getsecurewebproxy "$_sro_svc" 2>/dev/null) ;;
        socksfirewall) _sro_out=$(networksetup -getsocksfirewallproxy "$_sro_svc" 2>/dev/null) ;;
        autoproxy)   _sro_out=$(networksetup -getautoproxyurl "$_sro_svc" 2>/dev/null) ;;
        *) return 1 ;;
    esac
    [ -n "$_sro_out" ] || return 1
    # 英文与本地化输出都认：Enabled 行只关心开头是不是 Yes。
    _sro_en=$(printf '%s\n' "$_sro_out" | awk -F': *' '/^Enabled/ {print $2; exit}')
    _sro_host=""
    _sro_port=""
    if [ "$_sro_kind" = "autoproxy" ]; then
        # 自动配置脚本只有 URL 一行，没有独立的 Port
        _sro_host=$(printf '%s\n' "$_sro_out" | awk -F': *' '/^URL/ {print $2; exit}')
    else
        _sro_host=$(printf '%s\n' "$_sro_out" | awk -F': *' '/^Server/ {print $2; exit}')
        _sro_port=$(printf '%s\n' "$_sro_out" | awk -F': *' '/^Port/ {print $2; exit}')
    fi
    printf '%s\n%s\n%s\n' "${_sro_en:-No}" "${_sro_host:-}" "${_sro_port:-}"
    return 0
}

# 从 URL 里取主机与端口（纯 shell，不用外进程）。
# IPv6 形态是 http://[::1]:7078，直接按最后一个冒号切会错，先剥方括号。
sysproxy_split_url() {
    _ssu_url="${1:-}"
    printf '%s' "$_ssu_url" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##'
}

# 读出全部层，装配成清单。每行一条，字段用 TAB 分隔：
#   layer<TAB>service<TAB>kind<TAB>url<TAB>port
#
# $1 = quick 时只查手动代理（web/secureweb/socks）与自动配置脚本；
# 全量模式目前与 quick 相同（mac 没有 WinHTTP 那一层），保留参数是为了与
# Windows 侧同形——两边调用方式一样，界面那一层不用为平台写分支。
sysproxy_layers() {
    _gspl_quick="${1:-}"
    _gspl_managed=$(sysproxy_managed)
    sysproxy_list_services | while IFS= read -r _gspl_svc; do
        [ -n "$_gspl_svc" ] || continue
        for _gspl_kind in web secureweb socksfirewall autoproxy; do
            _gspl_raw=$(_sysproxy_read_one "$_gspl_svc" "$_gspl_kind") || continue
            _gspl_en=$(printf '%s\n' "$_gspl_raw" | sed -n '1p')
            _gspl_host=$(printf '%s\n' "$_gspl_raw" | sed -n '2p')
            _gspl_port=$(printf '%s\n' "$_gspl_raw" | sed -n '3p')
            [ "$_gspl_en" = "Yes" ] || continue
            [ -n "$_gspl_host" ] || continue
            _gspl_layer="manual"
            [ "$_gspl_kind" = "autoproxy" ] && _gspl_layer="pac"
            # socks 也归「手动代理」一类：它在系统里是独立的勾选框，但后果一样
            _gspl_url="$_gspl_host"
            case "$_gspl_kind" in
                web|secureweb|socksfirewall)
                    [ -n "$_gspl_port" ] && _gspl_url="http://${_gspl_host}:${_gspl_port}"
                    ;;
            esac
            _gspl_addr=$(sysproxy_split_url "$_gspl_url")
            # IPv6 方括号：http://[::1]:7078 → 取方括号里的内容再去端口
            _gspl_addr=$(printf '%s' "$_gspl_addr" | sed -E 's/^\[([^]]*)\]:[0-9]+$/\1/; t; s/:[0-9]+$//')
            _gspl_alive=$(sysproxy_port_state "$_gspl_addr" "${_gspl_port:-0}")
            _gspl_verdict=$(sysproxy_verdict "$_gspl_url" "${_gspl_port:-0}" \
                "$_gspl_alive" "$_gspl_managed" "$_gspl_layer")
            printf '%s\t%s\t%s\t%s\t%s\n' \
                "$_gspl_layer" "$_gspl_svc" "$_gspl_verdict" "$_gspl_url" "${_gspl_port:-0}"
        done
    done
}

# 是否被描述文件（MDM）或系统策略管着。
#
# 与 Windows 侧同一意图：改了会被改回来，所以要单独说清「不是我们能改的」。
# mac 上判据是「这台机器由 MDM 管理」——家用机没有这个文件。
sysproxy_managed() {
    if [ -d /var/db/ConfigurationProfiles/Settings ] || \
       [ -f /Library/Preferences/com.apple.mcx.plist ]; then
        # 有描述文件目录不等于必然管着代理，但这是最接近的判据。
        # 判成 managed 只会让工具「不修」，代价是多说一句话；
        # 判错成「可以修」则会去改一台公司机器，代价大得多——所以这里偏保守。
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------
# 3. 备份：动手之前先把原样记下来，能还原
# ------------------------------------------------------------------------------
# 落在 monitor/ 下，与 state.snapshot 同一个运行时目录：卸载时会一起清掉。
# 格式：每条一行，字段用 TAB；服务名里可能有空格，所以不用空格当分隔。
#
# 为什么必须能还原：修系统代理是整个工具里除了卸载之外唯一会动「别人写的设置」的地方。
sysproxy_backup_path() {
    printf '%s' "$MONITOR_DIR/doctor.bak"
}

# 写备份。**只写一次**：每次覆盖就失效（用户第一次修之前的原样才是要还原的那个）。
sysproxy_backup() {
    ensure_monitor_paths || return 1
    _spb_path=$(sysproxy_backup_path)
    [ -f "$_spb_path" ] && return 0
    _spb_tmp="$_spb_path.tmp.$$"
    : > "$_spb_tmp" 2>/dev/null || return 1
    sysproxy_layers > /dev/null 2>&1
    # 记的是「全部被启用的项」，不是只记可修的那几项：
    # 还原要能复原现场，不是只复原我们动过的。
    sysproxy_list_services | while IFS= read -r _spb_svc; do
        [ -n "$_spb_svc" ] || continue
        for _spb_kind in web secureweb socksfirewall autoproxy; do
            _spb_raw=$(_sysproxy_read_one "$_spb_svc" "$_spb_kind") || continue
            _spb_en=$(printf '%s\n' "$_spb_raw" | sed -n '1p')
            _spb_host=$(printf '%s\n' "$_spb_raw" | sed -n '2p')
            _spb_port=$(printf '%s\n' "$_spb_raw" | sed -n '3p')
            printf '%s\t%s\t%s\t%s\t%s\n' \
                "$_spb_svc" "$_spb_kind" "$_spb_en" "$_spb_host" "$_spb_port" >> "$_spb_tmp"
        done
    done
    mv -f "$_spb_tmp" "$_spb_path" 2>/dev/null || { rm -f "$_spb_tmp" 2>/dev/null; return 1; }
    [ -s "$_spb_path" ]
}

# ------------------------------------------------------------------------------
# 4. 修复：批量的「关掉」，一次密码框
# ------------------------------------------------------------------------------
# 改 networksetup 需要管理员。两种做法：
#   sudo networksetup ...        终端里要用户敲密码，看不见输入，非技术用户以为卡死
#   osascript ... with administrator privileges   弹系统标准密码框，跟装软件时一样
# 选第二种。osascript 是 macOS 自带，零依赖。with prompt 让它别显示成
# 「osascript 想要进行更改」——用户不知道 osascript 是谁，会以为是病毒。
#
# **所有要改的命令打包成一次调用**：每个服务弹一次框，用户会以为出问题了。
sysproxy_repair() {
    _spr_managed=$(sysproxy_managed) && { printf 'managed'; return 0; }
    _spr_layers=$(sysproxy_layers)
    [ -n "$_spr_layers" ] || { printf 'none'; return 0; }

    # 收集要关的项；同时确认有没有可修的
    _spr_cmds=""
    _spr_count=0
    while IFS="$(printf '\t')" read -r _spr_layer _spr_svc _spr_kind _spr_url _spr_port; do
        [ -n "$_spr_svc" ] || continue
        sysproxy_fixable "$_spr_kind" || continue
        _spr_count=$((_spr_count + 1))
        _spr_q=$(printf '%s' "$_spr_svc" | sed "s/'/'\\\\''/g")
        case "$_spr_layer" in
            pac)
                _spr_cmds="$_spr_cmds networksetup -setautoproxystate '$_spr_q' off;"
                ;;
            manual)
                # 三个勾选框都要关：只关 web 不关 secureweb，浏览器照旧走死端口。
                _spr_cmds="$_spr_cmds networksetup -setwebproxystate '$_spr_q' off;"
                _spr_cmds="$_spr_cmds networksetup -setsecurewebproxystate '$_spr_q' off;"
                _spr_cmds="$_spr_cmds networksetup -setsocksfirewallproxystate '$_spr_q' off;"
                ;;
        esac
    done <<EOF
$_spr_layers
EOF
    [ "$_spr_count" -gt 0 ] || { printf 'none'; return 0; }

    sysproxy_backup || { printf 'nobackup'; return 0; }

    # 一次提权，执行整串命令。输出转成一句结果，不把 stderr 丢给用户看。
    _spr_script="set -e;$_spr_cmds"
    _spr_msg=$(osascript -e "do shell script \"$(printf '%s' "$_spr_script" | sed 's/"/\\\\"/g')\" with prompt \"EnvProxy 要修正浏览器代理设置，需要你的开机密码\" with administrator privileges" 2>&1)
    _spr_rc=$?
    if [ "$_spr_rc" -ne 0 ]; then
        # 用户点了取消。**必须如实说没改**，不许假装成功。
        case "$_spr_msg" in
            *'-128'*|*'User canceled'*|*'用户已取消'*) printf 'canceled'; return 0 ;;
        esac
        printf 'failed'
        return 0
    fi
    # 回读确认：真的关了才算修好。不确认就报成功，就是屏幕上说修好了、浏览器还是打不开。
    _spr_after=$(sysproxy_layers)
    _spr_left=0
    while IFS="$(printf '\t')" read -r _spr_l2 _spr_s2 _spr_k2 _spr_u2 _spr_p2; do
        [ -n "$_spr_s2" ] || continue
        sysproxy_fixable "$_spr_k2" && _spr_left=$((_spr_left + 1))
    done <<EOF
$_spr_after
EOF
    [ "$_spr_left" -eq 0 ] && printf 'fixed' || printf 'failed'
    return 0
}

# 从备份还原：把「原本开着、现在被我们关了」的那些重新打开。
# 返回 ok / none / canceled / failed。
sysproxy_restore() {
    _srr_path=$(sysproxy_backup_path)
    [ -f "$_srr_path" ] || { printf 'none'; return 0; }
    _srr_cmds=""
    _srr_count=0
    while IFS="$(printf '\t')" read -r _srr_svc _srr_kind _srr_en _srr_host _srr_port; do
        [ -n "$_srr_svc" ] || continue
        [ "$_srr_en" = "Yes" ] || continue
        _srr_q=$(printf '%s' "$_srr_svc" | sed "s/'/'\\\\''/g")
        case "$_srr_kind" in
            web)           _srr_cmds="$_srr_cmds networksetup -setwebproxy '$_srr_q' '$_srr_host' '$_srr_port' on;" ;;
            secureweb)     _srr_cmds="$_srr_cmds networksetup -setsecurewebproxy '$_srr_q' '$_srr_host' '$_srr_port' on;" ;;
            socksfirewall) _srr_cmds="$_srr_cmds networksetup -setsocksfirewallproxy '$_srr_q' '$_srr_host' '$_srr_port' on;" ;;
            autoproxy)     _srr_cmds="$_srr_cmds networksetup -setautoproxyurl '$_srr_q' '$_srr_host' on;" ;;
        esac
        _srr_count=$((_srr_count + 1))
    done < "$_srr_path"
    [ "$_srr_count" -gt 0 ] || { printf 'none'; return 0; }
    _srr_script="set -e;$_srr_cmds"
    _srr_msg=$(osascript -e "do shell script \"$(printf '%s' "$_srr_script" | sed 's/"/\\\\"/g')\" with prompt \"EnvProxy 要把浏览器代理设置改回原样，需要你的开机密码\" with administrator privileges" 2>&1)
    if [ $? -ne 0 ]; then
        case "$_srr_msg" in
            *'-128'*|*'User canceled'*|*'用户已取消'*) printf 'canceled'; return 0 ;;
        esac
        printf 'failed'
        return 0
    fi
    printf 'ok'
    return 0
}
