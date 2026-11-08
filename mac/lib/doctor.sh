# ==============================================================================
#  doctor.sh — 体检层：系统代理各层的读取、判定与修复（macOS 侧）
#  由入口 envproxy.sh 按固定顺序 source，不单独运行。
#
#  职责边界（改这个文件前先读这一段）：
#    可以有 —— 探测系统代理各层、按判据给结论、修复、读写备份
#    不许有 —— 打印任何屏幕内容、读用户输入、进菜单循环、改环境变量
  #  界面住在 help / ops（菜单与提示），这一层只产出数据。
  #  这样它只依赖 base，不反向调菜单与提示层，不产生新的依赖环。判活用 bash 内建的 /dev/tcp。
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

# 判定结论词（与 Windows 侧 $FindingKinds 逐字同形，门禁 6 核对）
#
# **所有检查器共用**这套词，名字叫 FINDING 而不是 SYSPROXY：它描述的是
# 「某一层网络设置出了什么事」，不再只服务于系统代理。多一层检查器不需要、
# 也不许新增词——七个词表达的是「有没有东西 / 东西归谁 / 能不能修」，与层无关。
FINDING_KIND_CLEAN="clean"                  # 压根没设
FINDING_KIND_BLOCKING="residue-blocking"    # 手动代理指向死端口：真断网，最高优先级
FINDING_KIND_SLOWING="residue-slowing"      # 自动配置脚本指向死端口：能上网但会卡几秒
FINDING_KIND_ALIVE="alive"                  # 回环地址 + 端口活着：翻墙软件正在用，不动
FINDING_KIND_FOREIGN="foreign"              # 不是回环：公司/学校代理，工具不碰
FINDING_KIND_MANAGED="managed"              # 被描述文件/策略管着：改了也会被改回，不动
# 读不出来：networksetup 被拦、权限不足、输出认不出来。
# **必须与 foreign 分开**——foreign 断言「这是别人的代理」，而读不出来时
# 我们连地址都没拿到，说成 foreign 就是编的。
# 它不可修，也不进「不能动」那一组的计数（那组的意思是「东西在那儿，但不归我碰」）。
# 少了这个词，读失败的那一层会在清单里**整层消失**：使用者报上不了网，
# 工具却说「没发现问题」——最难被当成故障的一类失效。
FINDING_KIND_UNREADABLE="unreadable"

# 「哪个结论允许被修」只有一处：**只有 residue 两类**。
# 界面要判断「这项能不能修」时调这个，不许自己写字符串比较——
# 那样加一类结论就会漏掉界面那一处。旧名保留成同一个实现，不许变成第二份判据。
finding_fixable() {
    case "${1:-}" in
        "$FINDING_KIND_BLOCKING"|"$FINDING_KIND_SLOWING") return 0 ;;
    esac
    return 1
}

# ------------------------------------------------------------------------------
# 统一诊断记录（Finding）：所有检查器的输出只有这一种形状
# ------------------------------------------------------------------------------
# 为什么必须统一：界面的职责是「把可修的东西列出来、把不归我碰的东西列出来」，
# 那与具体是哪一层毫无关系。只要每层的输出同构，界面就永远不用改——
# 加一层检查器不需要碰界面一个字，这是「不堆补丁」在这里的具体含义。
#
# 输出是**一行一条、TAB 分列**（与 sysproxy_layers 的既有形状一致：Mac 侧
# 一直靠管道 + read 传结构，引入数组会撞 bash 3.2 的坑）：
#   Id <TAB> Kind <TAB> Subject <TAB> Where <TAB> Value <TAB> Reason <TAB> Advice <TAB> Repairable
# 字段里不许出现 TAB（值都是地址、路径、短句；万一有，写入前由 finding_new 替换成空格）。
finding_new() {
    _fn_id="${1:-}"; _fn_kind="${2:-}"; _fn_subject="${3:-}"; _fn_where="${4:-}"
    _fn_value="${5:-}"; _fn_reason="${6:-}"; _fn_advice="${7:-}"
    # 第 8 列：这一条记录自己说「这股形态能不能安全改」。1 = 能 / 0 = 只报告 / 空 = 没声明。
    # **它不是「用哪个函数修」**（那由检查器表的 Fix 列回答，存一份就是第二个真相）。
    # 它回答的是另一件事：同一条 cli-proxy 层里，`.npmrc` 删一行是安全的，
    # `settings.xml` 的 <proxy> 块删一半会留下坏配置——只有看得见文件格式的那一层
    # 能回答这件事。界面通过 finding_repairable 的第 3 个参数读它；
    # 与 Windows 侧的 Finding.Data.Repairable 同义。
    _fn_fix="${8:-}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(printf '%s' "$_fn_id" | tr '\t' ' ')" \
        "$_fn_kind" \
        "$(printf '%s' "$_fn_subject" | tr '\t' ' ')" \
        "$(printf '%s' "$_fn_where" | tr '\t' ' ')" \
        "$(printf '%s' "$_fn_value" | tr '\t' ' ')" \
        "$(printf '%s' "$_fn_reason" | tr '\t' ' ')" \
        "$(printf '%s' "$_fn_advice" | tr '\t' ' ')" \
        "$_fn_fix"
    return 0
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
    [ "$_spv_managed" = "1" ] && { printf '%s' "$FINDING_KIND_MANAGED"; return 0; }
    [ -z "$_spv_url" ] && [ "$_spv_port" -le 0 ] 2>/dev/null && { printf '%s' "$FINDING_KIND_CLEAN"; return 0; }
    # 不是本机回环：公司/学校代理，工具不碰
    is_loopback_url "$_spv_url" || { printf '%s' "$FINDING_KIND_FOREIGN"; return 0; }
    [ "$_spv_alive" = "unknown" ] && { printf '%s' "$FINDING_KIND_FOREIGN"; return 0; }
    [ "$_spv_alive" = "alive" ] && { printf '%s' "$FINDING_KIND_ALIVE"; return 0; }
    if [ "$_spv_layer" = "pac" ]; then
        printf '%s' "$FINDING_KIND_SLOWING"
    else
        printf '%s' "$FINDING_KIND_BLOCKING"
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
# 判活委托给 probe 层的 port_alive_bounded：同一件事只许有一处判据。
# 那个函数用的就是 bash 内建的 `/dev/tcp/`——只 connect()，不可能是隧道。
# 依赖方向是单向的：doctor 用 probe，probe 不用 doctor。
sysproxy_port_state() {
    _sps_addr="${1:-}"; _sps_port="${2:-0}"
    [ -n "$_sps_addr" ] && [ "$_sps_port" -gt 0 ] 2>/dev/null || { printf 'unknown'; return 0; }
    if port_alive_bounded "$_sps_addr" "$_sps_port"; then
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
# 全量模式额外采第 7 列（握手类），quick 留空——那一列要真连一次端口，
# 状态页每 2 秒刷新时不能付这个代价。参数保留更主要是为了与 Windows 侧同形：
# 两边调用方式一样，界面那一层不用为平台写分支。
sysproxy_layers() {
    _gspl_quick="${1:-}"
    _gspl_managed=$(sysproxy_managed)
    sysproxy_list_services | while IFS= read -r _gspl_svc; do
        [ -n "$_gspl_svc" ] || continue
        for _gspl_kind in web secureweb socksfirewall autoproxy; do
            # 读失败**不许静默跳过**：跳过意味着那一层从清单里消失，
            # 界面上就成了「这个服务没有任何代理设置」，而真相是「读不出来」。
            # 两者对使用者的含义完全相反：前者是没事，后者是"工具也看不见，得人工查"。
            # 所以产出一条 unreadable 记录，字段填占位值，让界面能如实说一句。
            if ! _gspl_raw=$(_sysproxy_read_one "$_gspl_svc" "$_gspl_kind"); then
                printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "unknown" "$_gspl_svc" "$FINDING_KIND_UNREADABLE" "" "" "$_gspl_kind"
                continue
            fi
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
# 3. 备份：事务日志（每次修复一个还原点，能撤销最近一次）
# ------------------------------------------------------------------------------
# 落在 monitor/ 下，与 state.snapshot 同一个运行时目录：卸载时会一起清掉。
#
# **为什么从单槽位（doctor.bak）改成日志**：单槽位只有一个还原点，而且「只写一次」。
# 一旦可修的层不止一处（系统代理 + 终端工具配置），这条规则立刻自相矛盾：
# 修完 A 再修 B，槽位里存的仍是 A 之前的原样，用户按「还原」以为撤掉的是刚才那次，
# 实际撤掉的是很久以前那次——而屏幕上只说「已经改回去了」。
#
# 格式与 Windows 侧逐字同形（门禁 6 核对）：三行一段，追加写。
#   --- op <utc> <op-id> <result>
#   <key>=<escaped value>
#   --- end
DOCTOR_JOURNAL_KEEP=5

doctor_journal_path() {
    printf '%s' "$MONITOR_DIR/doctor.journal"
}
# 旧版单槽位备份的位置。**仍然读、不再写**：升级前修过的人手里有它，
# 直接丢掉等于把他们唯一的一次还原机会删了。
sysproxy_backup_path() {
    printf '%s' "$MONITOR_DIR/doctor.bak"
}

# 值编码：与 Windows 侧 ConvertTo-DoctorBakValue 逐字同形。
# 只需要挡住换行与 = 两个字符（换行会让一条记录裂成两行；= 会让键值解析错位）。
# 转义用 % 领头（与 URL 编码同形），% 自己先转，避免二次解码。
#
# 换行单独处理：sed 是逐行工作的，它永远看不见换行符，所以「把换行变成 %0A」
# 只能靠 awk 在**行与行之间**插。这里用 printf 拼字面量 %0A——
# 写成 awk 的 printf 格式串（"%0A"）会被当成格式指令，实测报
# "not enough arguments to satisfy format string" 并把整条值截断。
_bak_enc() {
    _be_s="${1:-}"
    [ -n "$_be_s" ] || { printf ''; return 0; }
    printf '%s' "$_be_s" | sed -e 's/%/%25/g' -e 's/\r/%0D/g' -e 's/=/%3D/g' \
        | awk 'BEGIN{ORS=""} {if (NR>1) printf "%s", "%0A"; printf "%s", $0}'
}
_bak_dec() {
    _bd_s="${1:-}"
    [ -n "$_bd_s" ] || { printf ''; return 0; }
    printf '%s' "$_bd_s" | sed -e 's/%3D/=/g' -e 's/%0A/\n/g' -e 's/%0D/\r/g' -e 's/%25/%/g'
}

# 造一个还原点的正文。$2 是「键=值」的行，按调用方给的顺序原样写。
_finding_entry_body() {
    _feb_op="$1"; shift
    _feb_result="${1:-applied}"; shift
    printf -- '--- op %s %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$_feb_op" "$_feb_result"
    for _feb_line in "$@"; do
        printf '%s\n' "$_feb_line"
    done
    printf -- '--- end\n'
}

# 追加一个还原点。$1 = op-id，$2.. = "key=value"（值由调用方先编码）。
# 返回 0 = 确实落盘了。**写不下来就返回非零，调用方据此不动手**。
# 丢掉最近一段（撤销成功后调用）。
#
# 与 add_doctor_journal_entry 分开：那个是"追加并裁到保留条数"，
# 这个是"少一段"。删除只能靠整份重写——按字节截会把段截成半截，
# 下次读出来是一条无效记录。
drop_last_doctor_journal_entry() {
    _ddje_path=$(doctor_journal_path)
    [ -f "$_ddje_path" ] || return 0
    # 用 awk 找到最后一个 "--- op" 的行号，只保留它之前的内容。
    _ddje_keep=$(_ddje_path="$_ddje_path" awk '
        /^--- op / { last = NR }
        { lines[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                if (i < last) print lines[i]
            }
        }' "$_ddje_path" 2>/dev/null)
    if [ -z "$_ddje_keep" ]; then
        rm -f "$_ddje_path" 2>/dev/null || true
    else
        # 原子写回：同目录临时文件 + mv，中途失败时旧文件还在。
        _ddje_tmp="$_ddje_path.tmp.$$"
        printf '%s\n' "$_ddje_keep" > "$_ddje_tmp" 2>/dev/null || { rm -f "$_ddje_tmp" 2>/dev/null; return 1; }
        mv -f "$_ddje_tmp" "$_ddje_path" 2>/dev/null || { rm -f "$_ddje_tmp" 2>/dev/null; return 1; }
    fi
    return 0
}
add_doctor_journal_entry() {
    _aje_op="$1"; shift
    ensure_monitor_paths || return 1
    _aje_path=$(doctor_journal_path)
    _aje_new=$(_finding_entry_body "$_aje_op" applied "$@") || return 1
    # 保留最近 N 段：超了就整份重写（而不是截断）。
    # 按字节截会把最后一段截成半截，下次读出来是一条无效记录。
    _aje_tmp="$_aje_path.tmp.$$"
    {
        _aje_count=$(doctor_journal_count)
        _aje_keep=$((DOCTOR_JOURNAL_KEEP - 1))
        if [ "$_aje_count" -gt "$_aje_keep" ]; then
            # 只要最后 keep 段：用 awk 数「--- op」出现的位置，从第 (count-keep+1) 段起输出。
            _aje_skip=$((_aje_count - _aje_keep))
            awk -v skip="$_aje_skip" '
                /^--- op / { n++ }
                { if (n > skip) print }
            ' "$_aje_path"
        else
            [ -f "$_aje_path" ] && cat "$_aje_path"
        fi
        printf '%s\n' "$_aje_new"
    } > "$_aje_tmp" 2>/dev/null || { rm -f "$_aje_tmp" 2>/dev/null; return 1; }
    mv -f "$_aje_tmp" "$_aje_path" 2>/dev/null || { rm -f "$_aje_tmp" 2>/dev/null; return 1; }
    [ -s "$_aje_path" ]
}

# 日志里有几段还原点。没有文件时输出 0。
doctor_journal_count() {
    _djc_path=$(doctor_journal_path)
    [ -f "$_djc_path" ] || { printf '0'; return 0; }
    grep -c '^--- op ' "$_djc_path" 2>/dev/null || printf '0'
}

# 有没有能撤销的记录。界面据此决定要不要印「输 r 还原」那一行：
# 备份在就允许还原，与「当下有没有可修项」是两件事。
doctor_journal_has_restore() {
    [ "$(doctor_journal_count)" -gt 0 ] && return 0
    # 旧单槽位备份也算：升级前修过的人**第一天就能还原**，不需要先再修一次。
    [ -f "$(sysproxy_backup_path)" ] && return 0
    return 1
}

# 把日志拆成若干段，供还原时定位「最近一条」。
# 输出：每段一行，字段 TAB 分：Stamp <TAB> OpId <TAB> Result <TAB> 字段行（用 0x01 连接）
doctor_journal_ops() {
    _djo_path=$(doctor_journal_path)
    [ -f "$_djo_path" ] || return 0
    awk '
        /^--- op / {
            if (cur != "") print cur
            stamp=$3; opid=$4; res=$5
            cur = stamp "\t" opid "\t" res "\t"
            next
        }
        /^--- end/ {
            if (cur != "") { print cur; cur="" }
            next
        }
        {
            if (cur != "") {
                if (substr(cur, length(cur), 1) != "\t") cur = cur "\001"
                cur = cur $0
            }
        }
        END { if (cur != "") print cur }
    ' "$_djo_path" 2>/dev/null
}

# 取最近一条还原点的某个字段。$1 = 字段名（inspector / path / content …）
# 取不到时输出空。**只在有日志时才有效**。
#
# 注意读取循环用的是 `IFS= read -r x || [ -n "$x" ]`：字段串的最后一段没有换行，
# 光靠 `while read` 会把最后一行丢掉——而「最后一个字段」恰好是最常被问的那个
# （content 永远排在最后）。这个写法与别处读多行内容的循环一致。
doctor_journal_last_field() {
    _djf_want="$1"
    _djf_last=$(doctor_journal_ops | tail -n 1)
    [ -n "$_djf_last" ] || { printf ''; return 1; }
    _djf_fields=$(printf '%s' "$_djf_last" | cut -f4-)
    printf '%s' "$_djf_fields" | tr '\001' '\n' | while IFS= read -r _djf_line || [ -n "$_djf_line" ]; do
        case "$_djf_line" in
            "$_djf_want"=*)
                _djf_val=${_djf_line#*=}
                _bak_dec "$_djf_val"
                return 0 ;;
        esac
    done
    return 0
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
        finding_fixable "$_spr_kind" || continue
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

    # 还原点：记「这次动之前，每个服务的四个勾选框各是什么」。
    # 记的是**全部被启用的项**，不是只记可修的那几项：还原要能复原现场，
    # 而不是只复原我们动过的。
    #
    # 为什么写成一行一条、TAB 分列：一条还原点要同时装下多个服务的多项设置，
    # 折叠成「键=值」会让服务名里的空格与 = 都被卷进来。
    # 这里用「一行一个字段」的形式塞进 content 字段，由 _bak_enc 负责转义换行。
    _spr_snap=""
    _spr_scan=$(sysproxy_layers)
    while IFS="$(printf '\t')" read -r _ss_l _ss_svc _ss_kind _ss_url _ss_port _ss_box _ss_hs; do
        [ -n "$_ss_svc" ] || continue
        _ss_en="No"
        [ -n "$_ss_url" ] && _ss_en="Yes"
        _spr_snap="$_spr_snap${_ss_svc}	${_ss_box}	${_ss_en}	${_ss_url}	${_ss_port}
"
    done <<EOF
$_spr_scan
EOF
    if ! add_doctor_journal_entry 'sysproxy' \
            "inspector=sysproxy" \
            "services=$(_bak_enc "$_spr_snap")"; then
        printf 'nobackup'; return 0
    fi

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
        finding_fixable "$_spr_k2" && _spr_left=$((_spr_left + 1))
    done <<EOF
$_spr_after
EOF
    [ "$_spr_left" -eq 0 ] && printf 'fixed' || printf 'failed'
    return 0
}

# 从快照里的地址取出**该写进 networksetup 的主机名**。
#
# 快照第 4 列有两种形状，两种都要认：
#   · 手动代理层：sysproxy_layers 的第 4 列是整条 URL（http://127.0.0.1:7078）；
#   · 旧单槽位备份（doctor.bak）：第 4 列是裸主机（127.0.0.1）。
# networksetup 要的是**裸主机**。喂它整条 URL，它会把 "http://127.0.0.1:7078"
# 原样当成服务器名写进系统设置，浏览器随后拿着一个坏地址去连——
# 而屏幕上报的是「已经改回上一次修复之前的样子」。实测过：这条命令本身就返回 0，
# 只看退出码永远发现不了。
_sysproxy_restore_host() {
    case "${1:-}" in
        *://*) _srh_h=$(_url_host "$1") ;;
        *)     _srh_h=${1:-} ;;
    esac
    printf '%s' "$_srh_h"
}

# 一条还原命令。$1 服务  $2 勾选框  $3 快照里的地址  $4 快照里的端口
# 输出一行命令；这一条没法还原（地址空、端口不是数字）时返回 1，
# 由调用方计入「没还原」——静默跳过会让"撤了但没撤干净"看起来像成功。
_sysproxy_restore_cmd() {
    _src_svc="$1"; _src_box="$2"; _src_val="${3:-}"; _src_port="${4:-}"
    # 每次进来先清空：这个函数有多条 return 1 的早退路径，而 _src_cmd 是全局变量
    # （mac 的 bash 3.2 里没有 local，项目统一用前缀区分作用域）。
    # 不清空的话，一条坏记录早退后调用方会读到**上一条留下的命令**并再执行一遍——
    # 屏幕上一切正常，而那条设置被写了两遍。
    _src_cmd=""
    [ -n "$_src_val" ] || return 1
    _src_q=$(printf '%s' "$_src_svc" | sed "s/'/'\\\\''/g")
    case "$_src_box" in
        web|secureweb|socksfirewall)
            _src_host=$(_sysproxy_restore_host "$_src_val")
            [ -n "$_src_host" ] || return 1
            case "$_src_port" in ''|*[!0-9]*) return 1 ;; esac
            [ "$_src_port" -gt 0 ] 2>/dev/null || return 1
            case "$_src_box" in
                web)           _src_cmd="networksetup -setwebproxy '$_src_q' '$_src_host' '$_src_port' on" ;;
                secureweb)     _src_cmd="networksetup -setsecurewebproxy '$_src_q' '$_src_host' '$_src_port' on" ;;
                socksfirewall) _src_cmd="networksetup -setsocksfirewallproxy '$_src_q' '$_src_host' '$_src_port' on" ;;
            esac
            ;;
        autoproxy)
            # `-setautoproxyurl` 只收 <服务名> <url> 两个参数（多给一个 on 会被判为无效，
            # 整串 set -e 就此中断）；地址与状态是两条命令，**状态那一条不能省**：
            # 修复时是用 -setautoproxystate off 关掉的，只写回地址而不打开，
            # 用户的 PAC 就永远停在"关着"——屏幕上却说改回去了。
            _src_cmd="networksetup -setautoproxyurl '$_src_q' '$_src_val'; networksetup -setautoproxystate '$_src_q' on"
            ;;
        *) return 1 ;;
    esac
    printf '%s' "$_src_cmd"
    return 0
}

# 回读确认：这条记录是不是已经回到快照里记的样子。$1 服务  $2 勾选框  $3 地址  $4 端口
#
# **判据是"与快照一致"，不是"现在还有没有可修项"。** 撤销干的正是把当初被关掉的
# 死端口代理重新打开，所以撤完之后 sysproxy_layers 必然又报 residue-blocking——
# 拿 finding_fixable 当判据，这个函数就永远返回 failed，屏幕上恒报「[未完成] 没能改回去」。
_sysproxy_restored_ok() {
    _sro2_svc="$1"; _sro2_box="$2"; _sro2_val="${3:-}"; _sro2_want_port="${4:-}"
    _sro2_raw=$(_sysproxy_read_one "$_sro2_svc" "$_sro2_box" 2>/dev/null) || return 1
    _sro2_en=$(printf '%s\n' "$_sro2_raw" | sed -n '1p')
    _sro2_host=$(printf '%s\n' "$_sro2_raw" | sed -n '2p')
    _sro2_port=$(printf '%s\n' "$_sro2_raw" | sed -n '3p')
    [ "$_sro2_en" = "Yes" ] || return 1
    case "$_sro2_box" in
        autoproxy)
            # PAC 存的就是整条 URL，逐字比。
            [ "$_sro2_host" = "$_sro2_val" ] || return 1
            ;;
        *)
            [ "$_sro2_host" = "$(_sysproxy_restore_host "$_sro2_val")" ] || return 1
            [ "$_sro2_port" = "$_sro2_want_port" ] || return 1
            ;;
    esac
    return 0
}

# 撤销一次系统代理修复。返回 ok / failed / skip。
#
# 两种还原点都要认：
#   · 日志里的（字段 services）：按记录把每个服务的勾选框恢复到当时的样子；
#   · 旧单槽位备份 doctor.bak：那是一张「服务|勾选框|启用|地址|端口」的表，逐列同形，
#     由 restore_legacy_sysproxy_snapshot 把内容直接交给本函数（不借道日志）。
# 语义都是「推进去的命令返回 0 **且回读与快照一致**」，不许只看了 osascript 的退出码就报成功。
restore_sysproxy_snapshot() {
    # $1 可选：直接给一张 services 表就从它还原，不给才去读日志最后一段。
    #
    # 为什么要有这个入参：旧版单槽位备份（doctor.bak）不在日志里，
    # 若为了还原它先往日志追加一段临时记录，那一段会占用保留条数、
    # 把用户**另一条真实还原点挤掉**（日志只留最近 5 段，挤掉的回不来）。
    # 借道日志还要求写回是原子的，中途失败会留下半截日志、所有还原点报废。
    # 直接传内容就绕开这两件事。
    # 用 `${1:-}` 取：调用点有的写成 `restore_sysproxy_snapshot "$x"`，$x 可能是空串。
    _rss_services="${1:-}"
    [ -n "$_rss_services" ] || _rss_services=$(doctor_journal_last_field 'services')
    [ -n "$_rss_services" ] || { printf 'skip'; return 0; }

    _rss_cmds=""
    _rss_count=0
    _rss_bad=0
    while IFS="$(printf '\t')" read -r _rss_svc _rss_box _rss_en _rss_val _rss_port; do
        [ -n "$_rss_svc" ] || continue
        [ "$_rss_en" = "Yes" ] || continue
        _rss_one=$(_sysproxy_restore_cmd "$_rss_svc" "$_rss_box" "$_rss_val" "$_rss_port") || {
            # 记着、但不放弃：其余各项照样要还原。一条坏记录不该让整次撤销白做。
            _rss_bad=$((_rss_bad + 1))
            continue
        }
        _rss_cmds="$_rss_cmds $_rss_one;"
        _rss_count=$((_rss_count + 1))
    done <<EOF
$_rss_services
EOF
    [ "$_rss_count" -gt 0 ] || {
        # 一条命令都拼不出来，有两种完全不同的原因，不能混成一句：
        #   · 快照里本来就没有任何被启用的项 -> 撤销是空操作，**算成功**（否则这条还原点
        #     永远消费不掉，"输 r 撤销"这个选项一直挂着，按下去还是它）；
        #   · 快照里有项、但都还原不了（地址或端口坏了）-> 如实报失败，别把坏记录说成"没事"。
        [ "$_rss_bad" -eq 0 ] && printf 'ok' || printf 'failed'
        return 0
    }
    _rss_script="set -e;$_rss_cmds"
    _rss_msg=$(osascript -e "do shell script \"$(printf '%s' "$_rss_script" | sed 's/"/\\\\"/g')\" with prompt \"EnvProxy 要把浏览器代理设置改回原样，需要你的开机密码\" with administrator privileges" 2>&1)
    if [ $? -ne 0 ]; then
        case "$_rss_msg" in
            *'-128'*|*'User canceled'*|*'用户已取消'*) printf 'skip'; return 0 ;;
        esac
        printf 'failed'
        return 0
    fi
    # 回读确认：osascript 返回 0 只代表"那串命令都返回 0"，不代表设置真的生效——
    # 描述文件（MDM）会在下一瞬间把它覆盖回去。与 sysproxy_repair 同一条道理：
    # 不确认就报成功，就是屏幕上说改回去了、实际没改。
    #
    # 判据是**与快照逐项一致**（启用、地址、端口），不是"现在还有没有可修项"：
    # 撤销本来就是把当初关掉的死端口代理重新打开，撤完之后必然又出现可修项。
    _rss_left=$_rss_bad
    while IFS="$(printf '\t')" read -r _rss_svc2 _rss_box2 _rss_en2 _rss_val2 _rss_port2; do
        [ -n "$_rss_svc2" ] || continue
        [ "$_rss_en2" = "Yes" ] || continue
        _sysproxy_restored_ok "$_rss_svc2" "$_rss_box2" "$_rss_val2" "$_rss_port2" || _rss_left=$((_rss_left + 1))
    done <<EOF
$_rss_services
EOF
    [ "$_rss_left" -eq 0 ] && printf 'ok' || printf 'failed'
    return 0
}
