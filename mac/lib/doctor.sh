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
# **判据必须与 Windows 侧 Test-TcpAlive 完全一致：只连 TCP 端口，不建隧道、不访问目标。**
#
# 这里原来的写法是 `curl -p -x <proxy> http://127.0.0.1:9/`，它做的是
# 「让代理去连 127.0.0.1:9」——判的不是"端口在不在"，而是"代理能不能带你访问那个目标"。
# 两者不等价，而且差别是要命的那种：
#   代理端口活着、但翻墙节点刚好挂了 / 目标被墙 → 隧道失败 → 判 dead
#   → verdict 变成 residue-blocking → 救援把使用者**正在用**的代理关掉。
# 实测由子 agent 用真监听端口复现过（假代理回 502，curl 退出码非 0）。
# Windows 侧一直只做 TCP 连接，所以那边不会误判；两端判据必须同形。
#
# 用 bash 内建的 /dev/tcp 而不是 curl/nc：
#   - 零依赖、零 fork、无输出，语义就是"连得上吗"，与 Test-TcpAlive 严格对齐；
#   - nc -G 在部分 macOS 版本不存在，要探它就得先进 probe 层，那是反向依赖。
sysproxy_port_state() {
    _sps_addr="${1:-}"; _sps_port="${2:-0}"
    [ -n "$_sps_addr" ] && [ "$_sps_port" -gt 0 ] 2>/dev/null || { printf 'unknown'; return 0; }
    # IPv6 要带方括号才拼得进 /dev/tcp；裸 ::1 会被解析成别的东西。
    case "$_sps_addr" in
        *:*) _sps_host="[$_sps_addr]" ;;
        *)   _sps_host="$_sps_addr" ;;
    esac
    if (exec 3<>"/dev/tcp/${_sps_host}/${_sps_port}") 2>/dev/null; then
        exec 3<&- 2>/dev/null || true
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
        # 自动配置脚本只有 URL 一行，没有独立的 Port。
        #
        # **不能用 `-F': *'` 取第二列**：URL 自己就含冒号
        # （`URL: http://127.0.0.1:7078/proxy.pac`），按冒号切第二列拿到的是 `http`。
        # 实测后果有两层，都不是小事：
        #   ① 拿到的"地址"是 `http`，不是回环 → 判 foreign → mac 上「PAC 指向死端口、
        #      网页每次卡几秒」这一整类问题永远检测不到（residue-slowing 在 mac 侧不可能产出）；
        #   ② 备份里存下的是 `http`，用户一按还原就执行
        #      `networksetup -setautoproxyurl 'Wi-Fi' 'http' on` —— 把 PAC 地址写成字符串
        #      `http`，浏览器代理彻底损坏。
        # 取「URL: 」之后的整行，别切分。
        _sro_host=$(printf '%s\n' "$_sro_out" | sed -n 's/^URL: *//p' | head -n 1)
        # **PAC 的端口必须从 URL 里解析出来**，否则永远是 0。
        # 端口为 0 时 sysproxy_port_state 回 unknown，verdict 见 unknown 直接归 foreign —
        # 于是「PAC 指向死端口、网页每次卡几秒」这一整类问题在 mac 侧**永远检测不到**，
        # residue-slowing 成了一个永远不可能产出的死结论词。
        # 只修了取址不修端口，症状一模一样（实测：三行输出里第三行恒为空）。
        # 取端口用纯 shell，不用 sed：
        # 这段要同时处理 `http://h:7078/x.pac` 与 `http://h:7078`（带不帯路径），
        # sed 得写两个 s 命令叠一个 `t`——而 BSD sed（macOS 自带）对 `t;` 的解析比 GNU 严格，
        # 实测在不同版本上行为不一致。纯 shell 没有这个风险。
        _sro_port=""
        _sro_rest="$_sro_host"
        # **先去协议头再去路径**：`http://h:7078/x.pac` 里第一个 `/` 是协议的一部分，
        # 直接按 `/` 截会把整个地址截空（实测踩到过：port 全变成空）。
        case "$_sro_rest" in
            *://*) _sro_rest="${_sro_rest#*://}" ;;
        esac
        case "$_sro_rest" in
            */*) _sro_rest="${_sro_rest%%/*}" ;;   # 去掉路径部分
        esac
        case "$_sro_rest" in
            *:*) _sro_port="${_sro_rest##*:}" ;;   # 最后一个冒号之后是端口
        esac
        # 只接受纯数字；不是数字就当没端口（宁可不判，也不要拿错数字去判活）
        case "$_sro_port" in
            ''|*[!0-9]*) _sro_port="" ;;
        esac
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
            # 第 6 列是"这个地址来自哪个勾选框"（web/secureweb/socksfirewall/autoproxy）。
            # 必须带出来：三个勾选框各存各的地址，web 死了不代表 socks 也死。
            # 只按 layer 决定关哪个，就会把使用者正在用的那个一起关掉。
            # 前 5 列的含义不变，所有既有调用点（用 read 只取前 5 个变量）照常工作。
            # 第 7 列是握手分类，**只在 full 档采集**。
            # quick（状态页每 2–3 秒刷一次）绝不采集：握手要起 nc/curl，那是刷新开销的十倍。
            # 这列只用于**解释**（判断"端口活着但连不出去"），绝不参与可修判定。
            _gspl_hs=""
            if [ "$_gspl_quick" != "quick" ]; then
                _gspl_hs=$(handshake_kind_at "$_gspl_addr" "${_gspl_port:-0}" 2>/dev/null)
            fi
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$_gspl_layer" "$_gspl_svc" "$_gspl_verdict" "$_gspl_url" "${_gspl_port:-0}" "$_gspl_kind" "$_gspl_hs"
        done
    done
}

# 是否被描述文件（MDM）或系统策略管着。
#
# 与 Windows 侧同一意图：改了会被改回来，所以要单独说清「不是我们能改的」。
# mac 上判据是「这台机器由 MDM 管理」——家用机没有这个文件。
# 这台机器的代理设置是不是被 MDM 描述文件管着（改了会被刷回去，所以不该动）。
#
# **判据必须收敛到"确实有描述文件装着"，不能是"某个目录存在"。**
# 原来判的是 /var/db/ConfigurationProfiles/Settings 存在或 mcx.plist 存在，
# 而 /var/db/ConfigurationProfiles 在**未受管**的 Mac 上也可能存在
# （社区实测：里面只有一个 .migrated 文件）。一旦误判为真，sysproxy_repair 开头就
# `return managed`，**整个 mac 救援一条都不修**——那不是"多说一句话"，
# 是功能整体静默失效，而且伪装成"你的机器有特殊情况"。代价方向被估反了。
#
# 现在的判据：`profiles` 是 macOS 自带的、专门回答"装了哪些描述文件"的命令。
#   - 命令不存在（老系统/被裁剪）→ 退回看目录，仍保守
#   - 命令存在但没有输出 → 没有描述文件 → **明确不是被管**
#   - 有输出 → 交给上层按 managed 处理
# 这样"没装描述文件的机器"不会被一个空目录误伤成不可修。
sysproxy_managed() {
    if command -v profiles >/dev/null 2>&1; then
        _spm_out=$(profiles -P 2>/dev/null)
        case "$_spm_out" in
            ''|*'There are no configuration profiles installed'*|*'no configuration profiles'*)
                return 1 ;;
        esac
        # 有输出但读不懂（权限不足等）→ 保守按被管处理，别去动。
        return 0
    fi
    # 没有 profiles 命令：退回文件存在性，方向仍然保守。
    if [ -d /var/db/ConfigurationProfiles/Settings ] || \
       [ -f /Library/Preferences/com.apple.mcx.plist ]; then
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
        # **六个变量对应七列是错的**：sysproxy_layers 每行输出 7 个 TAB 字段
    # （层 / 服务 / 结论 / 地址 / 端口 / 勾选框 / 握手类）。少写一个变量时，
    # 最后一个变量会把剩余字段连同 TAB 一起吃掉——_spr_box 变成 "web<TAB>proxy-ok"，
    # 下面 case 匹配不上，落进 `*` 分支把计数减回去，于是可修项一律变成 none。
    # 症状：真断网（residue-blocking）一条都修不了，界面还把它说成
    # "查的时候还在、动手的时候已经没了（可能是你自己关掉了）"——把解析错误赖给用户。
    # 多出来的那一列（握手类）只用于解释，这里用 _spr_hs 接住、不使用。
    while IFS="$(printf '\t')" read -r _spr_layer _spr_svc _spr_kind _spr_url _spr_port _spr_box _spr_hs; do
        [ -n "$_spr_svc" ] || continue
        sysproxy_fixable "$_spr_kind" || continue
        _spr_count=$((_spr_count + 1))
        _spr_q=$(printf '%s' "$_spr_svc" | sed "s/'/'\\\\''/g")
        case "$_spr_layer" in
            pac)
                _spr_cmds="$_spr_cmds networksetup -setautoproxystate '$_spr_q' off;"
                ;;
            manual)
                # **只关出问题的那一个勾选框，不整组关。**
                #
                # mac 的 web / secureweb / socks 三个勾选框各存各的地址——
                # web 指向死端口时，socks 完全可能正活着在用。整组关就把使用者
                # **正在用**的代理关掉了。第 6 列带出来的就是"这条记录来自哪个勾选框"，
                # 按它精确关。
                # 勾选框名取不到时不动（宁可这次没修成，也不误关一条好的）。
                case "$_spr_box" in
                    web)           _spr_cmds="$_spr_cmds networksetup -setwebproxystate '$_spr_q' off;" ;;
                    secureweb)     _spr_cmds="$_spr_cmds networksetup -setsecurewebproxystate '$_spr_q' off;" ;;
                    socksfirewall) _spr_cmds="$_spr_cmds networksetup -setsocksfirewallproxystate '$_spr_q' off;" ;;
                    *)             _spr_count=$((_spr_count - 1)) ;;
                esac
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
        # restore 用 -set*proxy <svc> <host> <port> on：
        # 整串里的 on 会把状态一并打开（这正是还原想要的）。
        # **但注意 `-setwebproxy` 有副作用：它会顺带打开状态。**
        # 所以"修"那边绝不能走"先清地址再关状态"——那会把代理重新打开、指向一个死端口。
        # 修复侧现在的做法（只 -set*proxystate off，不动地址）是对的，别改。
        case "$_srr_kind" in
            web)           _srr_cmds="$_srr_cmds networksetup -setwebproxy '$_srr_q' '$_srr_host' '$_srr_port' on;" ;;
            secureweb)     _srr_cmds="$_srr_cmds networksetup -setsecurewebproxy '$_srr_q' '$_srr_host' '$_srr_port' on;" ;;
            socksfirewall) _srr_cmds="$_srr_cmds networksetup -setsocksfirewallproxy '$_srr_q' '$_srr_host' '$_srr_port' on;" ;;
            # -setautoproxyurl 只收 <服务名> <url> 两个参数；多给一个 on 会被判为无效，整串 set -e 就此中断。
            autoproxy)     _srr_cmds="$_srr_cmds networksetup -setautoproxyurl '$_srr_q' '$_srr_host';" ;;
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
    # 回读确认：osascript 返回 0 只代表"那串命令都返回 0"，不代表设置真的生效——
    # 描述文件（MDM）会在下一瞬间把它覆盖回去。与 sysproxy_repair 同一条道理：
    # 不确认就报成功，就是屏幕上说改回去了、实际没改。
    _srr_after=$(sysproxy_layers)
    _srr_left=0
    # 同样要读全 7 列（理由见 sysproxy_repair 里那段注释）。
    while IFS="$(printf '\t')" read -r _srr_l2 _srr_s2 _srr_k2 _srr_u2 _srr_p2 _srr_b2 _srr_h2; do
        [ -n "$_srr_s2" ] || continue
        sysproxy_fixable "$_srr_k2" && _srr_left=$((_srr_left + 1))
    done <<EOF
$_srr_after
EOF
    [ "$_srr_left" -eq 0 ] && printf 'ok' || printf 'failed'
    return 0
}
