# ------------------------------------------------------------------------------
#  probe.sh — 探测层：端口发现、CONNECT 握手、真实节点连通、当前状态判定
#  判决三层缺一不可；只做快筛的表不影响覆盖面。
# ------------------------------------------------------------------------------

# 这个主机名/地址是不是本机回环。
# 判据只认回环，不看别的——写成"非本机就排除"会把局域网里合法的自建代理一起排掉，
# 而那种确实该放过（用户自己搭的）。
is_loopback_host() {
    case "$1" in
        ''|*[!A-Za-z0-9.:\[\]]*) return 1 ;;
    esac
    _ilh=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    case "$_ilh" in
        '[::1]'|'::1') return 0 ;;
        'localhost')   return 0 ;;
    esac
    # 127.0.0.0/8 整段都算回环（不只是 127.0.0.1）：写法会变，语义不变。
    case "$_ilh" in
        127.*) return 0 ;;
    esac
    return 1
}

# 系统代理里登记的本机端口（不带任何软件名，只回答"系统认为对外的是哪个口"）。
#
# 为什么这个信号是通用的：任何翻墙软件要让浏览器走它的代理，**必须**把自己对外
# 的那个口写进系统代理设置——这是操作系统层面的协议，与软件叫什么、谁做的、
# 什么版本无关。反之，一个端口如果从不出现在系统代理里，它要么不是代理，
# 要么是**内部端口**（内核/子进程之间通信用，浏览器根本不需要知道）。
#
# 以**第一个启用且指向回环的**服务为准：macOS 的系统代理是每个网络服务各存一份，
# 而真正在生效的是"主服务"那一份。不按服务名写死（Wi-Fi 之类），因为用户的
# 主服务可能叫别的名字、也可能是雷雳网桥/有线。拿不到主服务时逐个服务读，
# 取第一个能用的——宁可多读几次也不写死名字。
#
# 这里**不调用 doctor 层**：doctor 是叶子层（只依赖 base+probe），
# probe 反过来依赖它就成了环。
get_system_proxy_loopback_ports() {
    _gspl_out=""
    # -listallnetworkservices 第一行是说明文字，以 * 开头的是被停用的服务。
    _gspl_svcs=$(networksetup -listallnetworkservices 2>/dev/null | sed '1d' | grep -v '^\*' || true)
    [ -n "$_gspl_svcs" ] || return 1
    for _gspl_svc in $_gspl_svcs; do
        for _gspl_kind in web secureweb; do
            case "$_gspl_kind" in
                web)       _gspl_raw=$(networksetup -getwebproxy "$_gspl_svc" 2>/dev/null) ;;
                secureweb) _gspl_raw=$(networksetup -getsecurewebproxy "$_gspl_svc" 2>/dev/null) ;;
            esac
            [ -n "$_gspl_raw" ] || continue
            _gspl_en=$(printf '%s\n' "$_gspl_raw" | awk -F': *' '/^Enabled/ {print $2; exit}')
            [ "$_gspl_en" = "Yes" ] || continue
            _gspl_host=$(printf '%s\n' "$_gspl_raw" | awk -F': *' '/^Server/ {print $2; exit}')
            _gspl_port=$(printf '%s\n' "$_gspl_raw" | awk -F': *' '/^Port/ {print $2; exit}')
            case "$_gspl_port" in ''|*[!0-9]*) continue ;; esac
            [ "$_gspl_port" -gt 0 ] 2>/dev/null || continue
            is_loopback_host "$_gspl_host" || continue
            case " $_gspl_out " in *" $_gspl_port "*) continue ;; esac
            _gspl_out="$_gspl_out $_gspl_port"
        done
    done
    [ -n "$_gspl_out" ] || return 1
    printf '%s' "$_gspl_out" | sed 's/^ //'
}

# 本层创建的临时物前缀。创建与清扫必须用同一套前缀——
# 这是"临时物的创建基址与清扫基址必须同一个"那条不变量的落实处。
PROBE_TMP_PREFIX="envproxy_probe_"

# 清掉超过一天以前留下的探测临时物。
#
# 为什么需要：本层有几处并发探测要落地（批量握手的结果目录、端点并发目录、
# 进程表快照），正常路径各自会删，但被 Ctrl-C / 被杀 / 断电打断时来不及删。
# macOS 的 /tmp 不会定期清理，于是一次中断留一个目录，日积月累。
#
# 判据是修改时间而不是创建时间：目录里的文件被改过就说明它还在用。
# 与 update 层的 remove_stale_update_temp 同一套做法（那边清 envproxy_update.*）。
probe_clean_stale_temp() {
    local _pct_base _pct_now
    _pct_base="${TMPDIR:-/tmp}"
    [ -d "$_pct_base" ] || return 0
    _pct_now=$(date +%s 2>/dev/null || echo 0)
    [ "$_pct_now" -gt 0 ] 2>/dev/null || return 0
    for _pct_p in "$_pct_base/$PROBE_TMP_PREFIX"*; do
        [ -e "$_pct_p" ] || continue
        _pct_m=$(stat -f '%m' "$_pct_p" 2>/dev/null || stat -c '%Y' "$_pct_p" 2>/dev/null || echo "")
        [ -n "$_pct_m" ] || continue
        [ "$_pct_now" -gt "$_pct_m" ] 2>/dev/null || continue
        [ $((_pct_now - _pct_m)) -ge 86400 ] 2>/dev/null || continue
        rm -rf "$_pct_p" 2>/dev/null || true
    done
    return 0
}


# 常见翻墙软件的默认本地代理端口（快速扫描用）。可自行增删。
# 注意：只做快筛，不做判决——判决永远是 CONNECT 握手 + 真实连通。
# 收录标准：能过 CONNECT 门、且可能拿去注入（http:// 方案）的口才值得收；
# 纯 SOCKS 口刻意不收（过不了握手门，只是白扫）。已在表内的不动（判决走握手门，无害）。
# 客户端目录：**端口与进程名的单一数据源**（与 Windows 侧 $ClientCatalog 同结构同语义）。
# 每行用 | 分隔：Id|Name|端口(空格分)|进程名特征(空格分)
#
# 原来端口一份、进程名一份，散在两处靠门禁比字面量硬撑，必然漂移。
# 收敛到这里之后，**加一个客户端支持 = 表里加一行**，两张旧表自动派生。
#
# 端口数字来自一手源码/官方文档核实，但**只影响识别速度，不参与授权**：
# v2rayN 的端口是「基址+枚举偏移」（改基址整套跟着变），Clash Nyanpasu 可设随机端口，
# 所以按端口号认客户端从根上有天花板。
CLIENT_CATALOG="
monocloud|MonoCloud|7078|monocloud
clash|Clash 系|7890 7891 7892 7897 7898 7899 9090|clash mihomo verge nyanpasu party
v2ray|v2ray 系|10808 10809 10810 10811 10812 10813 10814 10801 1080|v2ray xray nekoray nekobox
singbox|sing-box|2080 2081 7890|sing-box singbox
hiddify|Hiddify|12334 2334|hiddify
ss|Shadowsocks 系|1080 1086 1087 1089 8118|shadowsocks ss-local trojan hysteria
surge|Surge / Stash|6152 6153|surge stash quantumult
netch|Netch|2801 2802|netch
outline|Outline|8888|outline
devtools|调试代理|8888 8889 8080 9090|fiddler charles proxyman mitmproxy mitmdump
"

# 从目录派生（不要手写第二份）
KNOWN_PORTS=$(printf '%s\n' "$CLIENT_CATALOG" | awk -F'|' 'NF>=3 {print $3}' | tr -s ' ' '\n' | grep -v '^$' | sort -un | tr '\n' ' ' | sed 's/ *$//')
PATTERNS=$(printf '%s\n' "$CLIENT_CATALOG" | awk -F'|' 'NF>=4 {print $4}' | tr -s ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ *$//')

# 翻墙软件进程名特征（只影响速度不影响覆盖面）。可自行扩展。
# 不认品牌、不认版本：mihomo-party/flclash 已被 mihomo/clash 命中；Stash/Quantumult X 默认 Network Extension 模式、不产生本地口，故不单列。


# 验证端点（与 Windows 版一致：跨厂商/跨域段，快路优先 + 失败并行兜底）。
# 端点池的两条硬要求，缺一不可：
#   1) 跨厂商/跨域段——单个域段被干扰时其余端点仍能证明节点活着；
#   2) 响应体"零字节或极小"——探针发 HEAD 请求（--head），只收响应头、不收正文。
#      现有 6 个端点：5 个 /generate_204（0 字节 204）+ 1 个重定向类兜底。
# 新增端点必须同时满足这两条，否则"每次不足 1KB"的流量口径立刻失真。
# 端点表：三张平行字符串（host / path / expect）必须逐项对齐，条数由门禁 6 核对。
#
# 收录标准有两条，缺一不可（缺了第一条这个端点就废了）：
#   1. **必须翻墙才到得了**。直连也能回的端点证明不了"经代理能出去"，
#      它会让判决在直连状态下也报"通"。实测反例：
#      cp.cloudflare.com/generate_204 与 connectivitycheck.platform.hicloud.com/generate_204
#      直连都回 204（后者是给国内手机判断 Wi-Fi 用的，设计上就必须国内可达），都不能收。
#   2. 响应体零字节或极小（探针只读响应头、不读正文）。
#
# 已经删掉的：twitter.com —— 实测一律回 520，既非 204 也非 3xx，
# 占着"跨域段兜底"的名额却永远判死，还每轮白等一次 6 秒超时。
# 端点表：一条记录就是一个端点，三件事写在一起——主机 | 路径 | 期望应答。
#
# 为什么不是三张平行的字符串：原来是 CHECK_HOSTS / CHECK_PATHS / CHECK_EXPECTS 三条
# 按空格对齐的串，取值靠三次 `cut -f$n`。三条串的"第 n 项"必须指同一个端点，
# 而这件事没有任何东西在保证——把第 3 个 path 和第 4 个写反、或者只删掉其中一条的
# 某一项，门禁只比条数，看不出来；症状是某些端点永远判不通，而屏幕上看不出原因。
# 写成一条记录后，"哪个主机配哪个路径"在一处，不会错位。Windows 侧一直是这个形状
# （$CheckEndpoints 里每项是 @{Host;Path;Expect}），这里与它对齐。
#
# /generate_204 类只认 204：被强制门户劫持时会回 200 或 302，那都不是「通」。
# wikipedia 只认 3xx：它的正常应答就是重定向，按 204 判会让这个跨域段兜底端点
# 永远判死、端点池退化成纯 Google 段——那正是它存在的意义所在。
CHECK_ENDPOINTS=(
    'clients3.google.com|/generate_204|204'
    'connectivitycheck.gstatic.com|/generate_204|204'
    'www.gstatic.com|/generate_204|204'
    'youtubei.googleapis.com|/generate_204|204'
    'www.google.com|/generate_204|204'
    'www.wikipedia.org|/|3xx'
)

# 取第 N 个端点（1 起）的某一字段：1=主机 2=路径 3=期望应答。
# 越界返回空串（调用方据此判"这一轮没有可用端点"，不用先数长度）。
check_endpoint_field() {
    local _cef_field _cef_i _cef_want
    _cef_want="$1"
    _cef_field="$2"
    _cef_i=0
    for _cef_rec in "${CHECK_ENDPOINTS[@]}"; do
        _cef_i=$((_cef_i + 1))
        [ "$_cef_i" -eq "$_cef_want" ] || continue
        _cef_rest=${_cef_rec#*|}
        case "$_cef_field" in
            1) printf '%s' "${_cef_rec%%|*}" ;;
            2) printf '%s' "${_cef_rest%%|*}" ;;
            3) printf '%s' "${_cef_rest#*|}" ;;
        esac
        return 0
    done
    return 0
}

# 端点个数（各处要遍历时用它，不写死数字）。
check_endpoint_count() { printf '%s' "${#CHECK_ENDPOINTS[@]}"; }

# 三态，不是两态。
#
# 两态（walled / reachable）是这一层出过事的地方：它把「直连没拿到期望应答」整个当成
# 「被墙」，于是 DNS 一挂、强制门户一拦、网慢一超时，全都变成「这个端点被墙了」——
# 合格证恒真，新判据退化成旧判据，而且屏幕上看不出任何异常。
#
# 三态的分界线是**我们到底证明了什么**：
#   blocked   直连确定打不开：域名解析得出、直连本身也能上网，但这个站点拿不到应答。
#             只有这一种能当证据——它的「通」确实是代理挣来的。
#   reachable 直连就能拿到期望应答：证明不了代理，不能当证据。
#   unknown   问不出来：解析失败、整条直连都不通、拿到个不是它该回的应答。
#             「不知道」**绝不许**被当成「被墙」——那是把它变成免费合格证。
ENDPOINT_PROOF_BLOCKED="blocked"
ENDPOINT_PROOF_REACHABLE="reachable"
ENDPOINT_PROOF_UNKNOWN="unknown"

# 缓存：每个端点一条记录 "索引|结论|单调秒|网络指纹"。
# 用空格分隔的记录串而不是关联数组——bash 3.2 没有关联数组。
ENDPOINT_PROOF_CACHE=""
# 直连那一侧的单次上限（秒）。比经代理的 6 秒短：被墙的地址多半是"连上没人应"
# 或直接被 RST，两秒半够用；这条路径只在首次遇到某个端点时走，不参与稳态探测。
# 取值必须与 Windows 侧一致（${EndpointDirectTimeoutMs}）：这个数是"直连算不算通"的
# 分界线，两侧不同就会出现"同一个网站在 Mac 上算被墙、在 Windows 上算直连可达"，
# 同一个代理被两台机器判成相反结论。门禁 6 逐值核对。
# curl 的秒级粒度里表示 2.5 秒只能用小数；--connect-timeout 与 --max-time 都接受小数。
ENDPOINT_DIRECT_TIMEOUT=2.5
# 合格证有效期（秒）。它描述的是「本机网络 × 客户端分流规则」，而这两样都会变
# （换 Wi-Fi、插拔网线、开关 TUN、改分流）。永久缓存等于把开机那一瞬间的判断
# 钉死一辈子。
ENDPOINT_PROOF_TTL_SEC=600
# 直连基线的有效期，比合格证短：它是判"打不开"的前提，前提过期比结论过期更危险。
DIRECT_BASELINE_TTL_SEC=60
# 网络指纹的缓存时长。它只在"要不要重问合格证"这一处用，不值得每轮枚举网卡。
NETWORK_FP_TTL_SEC=30
# 兜底阶段给合格证判定的总预算（秒）。命中一个就返回，通常用不满。
ENDPOINT_PROOF_SWEEP_BUDGET_SEC=8
# 直连基线的对照站点池：只用来回答"直连还能不能上网"，不参与端点表。
#
# **为什么是一个池而不是一个域名**：这台机器在不在线的判据，不能押在某一家身上。
# 海外分支、海外云主机、严格管控的企业内网都可能让某一个站点超时或根本不放行；
# 一旦唯一裁判不回话，"本机直连不通"就会被当成事实，合格证全变成 unknown，
# 于是一个好好的节点被判死、变量被删掉——用户以为工具坏了，其实只是裁判掉线了。
#
# 判据宽松且方向正确：**任一条拿到任何 HTTP 应答就算在线**。
# 这里问的只是"路通不通"，不问哪个站点通；三个站点分属不同骨干/不同用途，
# 单点被墙、被门户劫持、DNS 抽风都不会同时灭掉三个。
#
# 顺序固定、逐个试，第一个应答就返回。单条上限比端点取证短（2 秒），
# 最坏 3×2 秒仍在兜底总预算之内。
# 两侧必须逐条相同（门禁 6 核对）：同一个网络在 Windows 上判"在线"、
# 在 Mac 上判"离线"，会让同一个代理被两台机器判成相反结论。
# 格式：主机|路径，一行一条，顺序即尝试顺序。
DIRECT_BASELINE_POOL='www.baidu.com|/
detectportal.firefox.com|/success.txt
www.qq.com|/'
# 单条基线的上限（秒）。与 ENDPOINT_DIRECT_TIMEOUT 分开：那个是"判一个端点被没被墙"，
# 这个是"判这台机器还能不能上网"，后者三条串行，单条必须更短。
DIRECT_BASELINE_TIMEOUT=2
# 直连基线 / 网络指纹的进程内缓存
DIRECT_BASELINE_STATE=""     # "活/死|单调秒|指纹"
NETWORK_FP_VALUE=""
NETWORK_FP_AT=""
# 本轮是不是"合格证整体失效、已退回旧判据"。由 test_real_connectivity 每轮重置。
PROOF_DEGRADED=0

# 本机的网络指纹：默认网关 + 各网卡的本机地址。
# 换 Wi-Fi / 插拔网线 / 开关虚拟网卡都会让它变，而这三件事恰好都会推翻
# 「这个端点会不会被墙」的结论。
# 只用系统命令（route -n get default 在 macOS 上有，Linux 上缺），取不到就退回空串：
# 空串会让缓存键一致，但有效期还在，不会永久钉死。
network_fingerprint() {
    local _nf_now _nf_age _nf_gw _nf_ips
    monotonic_now; _nf_now=$MONO_NOW
    if [ -n "$NETWORK_FP_VALUE" ] && [ -n "$NETWORK_FP_AT" ]; then
        _nf_age=$((_nf_now - NETWORK_FP_AT))
        if [ "$_nf_age" -ge 0 ] && [ "$_nf_age" -lt "$NETWORK_FP_TTL_SEC" ]; then
            NETWORK_FP="$NETWORK_FP_VALUE"
            return 0
        fi
    fi
    _nf_gw=""
    _nf_gw=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2; exit}')
    _nf_ips=$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | sort -u | tr '\n' ',')
    NETWORK_FP_VALUE="gw:${_nf_gw:-none},ip:${_nf_ips:-none}"
    NETWORK_FP_AT="$_nf_now"
    NETWORK_FP="$NETWORK_FP_VALUE"
    return 0
}

# 直连（不经任何代理）能不能上网：拿一个国内稳定站点试，拿到任何 HTTP 应答就算能。
# 它存在只为一件事：把「这个站点打不开」和「整台机器都出不去」分开。
# 没有它的话，断网、DNS 全挂、刚开机网卡还没起来——全都会被读成「所有端点都被墙」，
# 于是每个端点都发一张合格证，而那时候根本没有任何东西被证明。
direct_baseline_alive() {
    local _db_now _db_age _db_fp _db_rec _db_alive _db_at _db_stored_fp _db_out
    monotonic_now; _db_now=$MONO_NOW
    network_fingerprint; _db_fp="$NETWORK_FP"
    if [ -n "$DIRECT_BASELINE_STATE" ]; then
        _db_alive=${DIRECT_BASELINE_STATE%%|*}
        _db_rec=${DIRECT_BASELINE_STATE#*|}
        _db_at=${_db_rec%%|*}
        _db_stored_fp=${_db_rec#*|}
        if [ "$_db_stored_fp" = "$_db_fp" ]; then
            _db_age=$((_db_now - _db_at))
            if [ "$_db_age" -ge 0 ] && [ "$_db_age" -lt "$DIRECT_BASELINE_TTL_SEC" ]; then
                [ "$_db_alive" = "1" ] && return 0 || return 1
            fi
        fi
    fi
    # --noproxy '*'：这一侧问的是"直连还能不能出去"，走了代理就答非所问。
    # 拿到任何 HTTP 应答就够——状态码是什么无所谓，这里问的是"路通不通"。
    # **任一条通即返回**：通常只付一次往返；三条都不通才付满 3×2 秒。
    _db_alive=0
    while IFS='|' read -r _db_host _db_path; do
        [ -n "$_db_host" ] || continue
        _db_out=$(curl_direct --disable -s -D - -o /dev/null --head \
            --noproxy '*' --connect-timeout 2 --max-time "$DIRECT_BASELINE_TIMEOUT" \
            "http://$_db_host$_db_path" 2>/dev/null | head -n 1)
        case "$_db_out" in
            HTTP/*) _db_alive=1; break ;;
        esac
    done <<EOF
$DIRECT_BASELINE_POOL
EOF
    DIRECT_BASELINE_STATE="$_db_alive|$_db_now|$_db_fp"
    [ "$_db_alive" = "1" ] && return 0 || return 1
}

# 直连（不经任何代理）问一次这个端点，输出三态之一。
# 判据与 test_single_endpoint 共用 test_endpoint_status，只是不经过代理端口。
test_endpoint_direct() {
    local _ed_host _ed_path _ed_exp _ed_code _ed_first _ed_out
    _ed_host="$1"; _ed_path="$2"; _ed_exp="${3:-204}"

    # 第一关：解析得出吗。解析不出来是「不知道」，不是「被墙」——
    # 把 DNS 故障读成被墙，等于给每个端点免费发一张合格证。
    # dscacheutil 是 macOS 自带；取不到就跳过这一关（宁可少一层，不能误判）。
    if command -v dscacheutil >/dev/null 2>&1; then
        _ed_out=$(dscacheutil -q host -a name "$_ed_host" 2>/dev/null | grep -c '^ip_address')
        case "$_ed_out" in
            ''|*[!0-9]*) : ;;          # 数不出来就不下结论，交给下面那一步
            0) printf '%s' "$ENDPOINT_PROOF_UNKNOWN"; return 0 ;;
        esac
    fi

    # --noproxy '*' 让 curl 完全不看代理设置（含环境变量与系统代理）。
    # 这一项是整条判据的根——漏了它，这里问到的就是"代理那一侧"，
    # 与经代理的探测同源，两边永远一致，任何端点都当不成证据（表现为永远判不通）。
    # 用 GET 而不是 HEAD：部分端点对 HEAD 回 405，那会把"这一问没结果"错读成"被墙"。
    _ed_out=$(curl_direct --disable -s -D - -o /dev/null \
        --noproxy '*' --connect-timeout 2 --max-time "$ENDPOINT_DIRECT_TIMEOUT" \
        "http://$_ed_host$_ed_path" 2>/dev/null)
    if [ -z "$_ed_out" ]; then
        # 一个字节都没拿到：只有在「直连本身能上网」的前提下，才轮得到说这个站点打不开。
        if direct_baseline_alive; then
            printf '%s' "$ENDPOINT_PROOF_BLOCKED"
        else
            printf '%s' "$ENDPOINT_PROOF_UNKNOWN"
        fi
        return 0
    fi
    _ed_first=$(printf '%s' "$_ed_out" | head -n 1)
    _ed_code=$(printf '%s' "$_ed_first" | sed -n 's/^HTTP\/[0-9.]*[[:space:]]\{1,\}\([0-9]\{3\}\).*/\1/p')
    if [ -z "$_ed_code" ]; then
        printf '%s' "$ENDPOINT_PROOF_UNKNOWN"
        return 0
    fi
    if test_endpoint_status "$_ed_code" "$_ed_exp"; then
        printf '%s' "$ENDPOINT_PROOF_REACHABLE"
    else
        # 拿到了应答但不是它该回的（门户劫持回 200、405、403）：
        # 这说明不了这个站点"被墙"，只说明这一问没结果。
        printf '%s' "$ENDPOINT_PROOF_UNKNOWN"
    fi
    return 0
}

# 这个端点的合格证（带有效期 + 网络指纹，每个端点问一次就够）。
# 结果放进 PROOF_KIND。索引越界一律 unknown，不许静默发证。
endpoint_proof() {
    local _ep_idx _ep_now _ep_fp _ep_rec _ep_hit _ep_kind _ep_at _ep_fp2
    _ep_idx="$1"
    PROOF_KIND="$ENDPOINT_PROOF_UNKNOWN"
    case "$_ep_idx" in ''|*[!0-9]*) return 0 ;; esac
    [ "$_ep_idx" -lt "$(check_endpoint_count)" ] || return 0

    monotonic_now; _ep_now=$MONO_NOW
    network_fingerprint; _ep_fp="$NETWORK_FP"

    _ep_hit=""
    for _ep_rec in $ENDPOINT_PROOF_CACHE; do
        [ "${_ep_rec%%|*}" = "$_ep_idx" ] || continue
        _ep_rec=${_ep_rec#*|}
        _ep_kind=${_ep_rec%%|*}
        _ep_rec=${_ep_rec#*|}
        _ep_at=${_ep_rec%%|*}
        _ep_fp2=${_ep_rec#*|}
        if [ "$_ep_fp2" = "$_ep_fp" ]; then
            if [ $((_ep_now - _ep_at)) -ge 0 ] && [ $((_ep_now - _ep_at)) -lt "$ENDPOINT_PROOF_TTL_SEC" ]; then
                _ep_hit="$_ep_kind"
            fi
        fi
        break
    done
    if [ -n "$_ep_hit" ]; then
        PROOF_KIND="$_ep_hit"
        return 0
    fi

    # 过期，或者换了网络：这个结论不再描述现在，丢掉重问。
    local _ep_newcache _ep_drop
    _ep_newcache=""
    for _ep_drop in $ENDPOINT_PROOF_CACHE; do
        [ "${_ep_drop%%|*}" = "$_ep_idx" ] || _ep_newcache="$_ep_newcache $_ep_drop"
    done
    ENDPOINT_PROOF_CACHE="$_ep_newcache"

    _ep_kind=$(test_endpoint_direct "$(check_endpoint_field $((_ep_idx + 1)) 1)" \
                                   "$(check_endpoint_field $((_ep_idx + 1)) 2)" \
                                   "$(check_endpoint_field $((_ep_idx + 1)) 3)")
    PROOF_KIND="${_ep_kind:-$ENDPOINT_PROOF_UNKNOWN}"
    # Unknown 不入缓存：它回答的是"这一次没问出来"，不是这个端点的性质。
    # 缓存它等于把一次瞬时故障钉成永久结论。
    if [ "$PROOF_KIND" != "$ENDPOINT_PROOF_UNKNOWN" ]; then
        ENDPOINT_PROOF_CACHE="$ENDPOINT_PROOF_CACHE $_ep_idx|$PROOF_KIND|$_ep_now|$_ep_fp"
    fi
    return 0
}

# 一条端点证据算不算数（唯一的判据实现）。
# 只有 blocked 算——reachable 证明不了代理，unknown 什么都不证明。
endpoint_proof_counts() {
    [ "${1:-}" = "$ENDPOINT_PROOF_BLOCKED" ] && return 0 || return 1
}

# 端点表里还有没有"确定被墙"的端点。全都没有时判据在本机不可用。
any_endpoint_blocked() {
    local _ab_i
    _ab_i=0
    while [ "$_ab_i" -lt "$(check_endpoint_count)" ]; do
        endpoint_proof "$_ab_i"
        if endpoint_proof_counts "$PROOF_KIND"; then return 0; fi
        _ab_i=$((_ab_i + 1))
    done
    return 1
}

# 六个端点是不是**每一个**都直连可达。
#
# 这是"本机直连被整体接管"的签名（TUN、透明代理、全局 VPN）：流量根本没走真实网络，
# 走的是那台内核，所以每个端点都能"直连"拿到正确应答。这时合格证这套判据在本机
# 是恒真的，它证明不了任何事——既不能说代理好，也不能说代理坏。
#
# 为什么要跟"全是 unknown"分开：那是另一件事，说明本机根本问不出来（DNS 挂了、
# 整条直连断了）。那时的正确回答是"没法证明"，不是"退回旧判据"——退回旧判据
# 恰好会让一个死节点靠随便一个 204 重新骗过判决，也就是这次要修的那个事故。
all_endpoints_reachable() {
    local _ar_i
    _ar_i=0
    while [ "$_ar_i" -lt "$(check_endpoint_count)" ]; do
        endpoint_proof "$_ar_i"
        [ "$PROOF_KIND" = "$ENDPOINT_PROOF_REACHABLE" ] || return 1
        _ar_i=$((_ar_i + 1))
    done
    return 0
}

# 经代理问一个端点，再判它的应答能不能当证据。**三条探测路径都只调用它**：
#   -AlreadyAnswered 给并行兜底用：那一侧请求已经发出去了，再打一次是白花流量。
# 直连合格证只在**端点真的应答了**之后才去问：没应答就无从谈起，白问一次是净损失。
test_proxy_endpoint_evidence() {
    local _pe_idx _pe_port _pe_answered
    _pe_port="$1"; _pe_idx="$2"; _pe_answered="${3:-0}"
    if [ "$_pe_answered" != "1" ]; then
        case "$_pe_idx" in ''|*[!0-9]*) return 1 ;; esac
        test_single_endpoint "$_pe_port" \
            "$(check_endpoint_field $((_pe_idx + 1)) 1)" \
            "$(check_endpoint_field $((_pe_idx + 1)) 2)" \
            "$(check_endpoint_field $((_pe_idx + 1)) 3)" || return 1
    fi
    endpoint_proof "$_pe_idx"
    endpoint_proof_counts "$PROOF_KIND"
}


# 监控状态（进程内变量，不落地）
LAST_GOOD_ENDPOINT=0
LAST_NODE_CHECK=0
NODE_CACHE_PORT=""
NODE_ALIVE=0
NODE_FAIL_COUNT=0
# 判定用的"当前时刻"（秒）。**必须单调**，不能用墙上时钟：
#   NTP 校时 / 夏令时 / 休眠唤醒都会让 date +%s 跳变；
#   向后跳 -> (now - last) 为负 -> "还不到探测间隔"恒成立 -> 停止探测（实测冻结）；
#   向前跳 -> 失败计数被 IdleReset 清零 -> 判据永远凑不够。
# 注意 epoch 秒变量（zsh 5.0+/bash 5+）与 date +%s 是**同一个墙上时钟**，
# 解决不了跳变——实测两者差值恒为 0。
# 这里用 CLOCK_MONOTONIC：perl 是 macOS 自带的，一次 fork 约 15ms。
# 这个开销放在**监控进程**里（每 2-3 秒一轮，占 0.5%~0.75%），
# 不在终端回车热路径上，所以不影响"敲回车不卡"那条契约。
# 取不到时退回 date +%s：宁可保留跳变风险，也不能让监控起不来。
# 一次 fork 约 15ms（macOS），一轮里多处要"现在"时不能各算一次——
# 用 $_MONO_LAST 做轮内缓存：同一个调用者（同一轮）复用同一个读数。
# 每轮开始由调用方执行 mono_tick 明确刷新一次，之后 monotonic_now 直接复用，
# 于是每轮至多一次 fork，而不是每个判定点一次。
_MONO_LAST=""
_MONO_READY=0

# 刷新一次单调钟，**只写全局、不输出**。
#
# 不输出是刻意的：任何 `x=$(mono_tick)` 都跑在子 shell 里，函数里的全局赋值出不来，
# 于是缓存永远建不起来、每个判定点各 fork 一次。这正是之前那份实现的实际状态——
# 注释承诺"每轮至多一次 fork"，代码里 mono_tick 被 $( ) 包着，缓存从没生效过。
# 现在改成"调用方直接调它（不包 $( )），之后一律用 monotonic_now 取"。
mono_tick() {
    local _mn
    _mn=""
    if command -v perl >/dev/null 2>&1; then
        _mn=$(perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e 'printf "%d", clock_gettime(CLOCK_MONOTONIC)' 2>/dev/null)
    fi
    case "$_mn" in
        ''|*[!0-9]*)
            # 退回墙上时钟：**只在第一次记一条**。这不是灾难（没装 perl 的机器只能这样），
            # 但它是判定时刻的正确性降级：NTP 校时/夏令时/休眠唤醒都会让"两时刻相减"出错。
            # 不记的话，出问题时没人知道这台机器上用的根本不是单调钟。
            _mn=$(date +%s 2>/dev/null || echo 0)
            if [ "${_MONO_FALLBACK_LOGGED:-0}" != "1" ]; then
                _MONO_FALLBACK_LOGGED=1
                log_msg "单调时钟不可用（perl 缺失或调用失败）：已退回墙上时钟，判定时刻可能受系统校时影响。" 2>/dev/null || true
            fi ;;
    esac
    _MONO_LAST="$_mn"
    _MONO_READY=1
    return 0
}

# 取"现在"，结果放进 ${MONO_NOW}。
#
# **不 printf 输出**，因为任何 `x=$(monotonic_now)` 都会开子 shell：
# 子 shell 读不到父 shell 的 ${_MONO_LAST}，于是每次都真去 fork 一个 perl。
# 实测那样写 100 次取用要 1583ms（等于没缓存）；改成"直接调 + 读 $MONO_NOW"
# 之后是 24ms，快 66 倍。调用方一律写成：
#     monotonic_now; _t=$MONO_NOW
monotonic_now() {
    if [ "$_MONO_READY" != "1" ] || [ -z "$_MONO_LAST" ]; then mono_tick; fi
    MONO_NOW="$_MONO_LAST"
    return 0
}

NODE_FIRST_FAIL_AT=0     # 本轮连续失败的起点（单调秒），成功后清零
NODE_FAST_UNTIL=0        # 刚下结论后的加密观察窗口截止时刻（epoch 秒）
CACHED_PORT=""
# 刚丢掉缓存时置 1：下一轮立刻深扫（与 Windows 侧 $script:NeedDeepScan 同义）。
NEED_DEEP_SCAN=0
# 是否做过至少一次**成功的**全扫。它与 NEED_DEEP_SCAN 是两件事：
# 后者是"下一轮要不要特意全扫"，一次性、用完清零；
# 这个是"有没有确认过全集"，做过就永不回退。用它当"首轮必须全扫"的判据，
# 才不会被"签名恒为空"这种巧合反复触发全扫（Windows 侧同名 $script:EverFullScanned）。
EVER_FULL_SCANNED=0
LAST_SEEN_SET=""
LAST_ALIVE_PORT=""
ROUND=0
CURRENT_STATE="off"

# 可调阈值（改行为只改这里，机制不动；取值与 Win 侧同形，门禁 6 核对）
# 采样间隔：稳定态多久探一次。它只决定"流量"和"发现异常的快慢"，不再决定判"断"要多久。
NODE_CHECK_THROTTLE_SEC=15
# 过渡态采样间隔：正在收集证据（有失败、但还没凑够判据）或刚下完结论时用这个值。
# 注意不是"有失败就用"：失败已达阈值说明结论已定，那时要回稳定档，否则节点一直死时
# 计数会无界增长、间隔永远钉在快档（实测流量是承诺值的 2.5 倍）。
NODE_FAST_SEC=5
# 下完结论后继续加密观察多久（判错了能在这段时间里自己改回来）。
NODE_FAST_WINDOW_SEC=60
# 判"断"的双条件：至少这么多次，且失败必须已经持续这么久。
NODE_FAIL_THRESHOLD=3
NODE_FAIL_DWELL_SEC=10
# 槽位闲置多久就丢弃旧失败起点：判定的节奏是快档（NODE_FAST_SEC），正常失败时远达不到这个门限，
# 只有"端口消失很久后又回来"才会撞上。独立常量，不与节流档位绑定。
NODE_IDLE_RESET_SEC=30

# 这一轮该隔多久再探（纯函数，不碰网络、不读时钟，便于回归）：
#   正在收集证据（有失败、还没凑够判据）  -> 快速间隔（问勤一点才可能尽快下结论）
#   刚下完结论（可能判错，需要能马上纠正） -> 快速间隔
#   结论已经稳定（失败已达阈值、或一切正常） -> 稳定间隔（省流量）
# 第三条是关键：只按"有没有失败"决定间隔的话，节点一直死时失败计数会无界增长、
# 间隔永远钉在快速档——实测 3600 秒探测次数是承诺值的 2.5 倍。
# 结果进 ${NODE_PROBE_INTERVAL}（本侧 bash 3.2 无 $(...) 之外的方便返回手段，统一走全局）。
node_probe_interval() {
    local _np_fail
    _np_fail="$1"; _np_thr="$2"; _np_until="$3"; _np_now="$4"; _np_steady="$5"; _np_fast="$6"
    if [ "$_np_fail" -gt 0 ] && [ "$_np_fail" -lt "$_np_thr" ]; then NODE_PROBE_INTERVAL="$_np_fast"; return 0; fi
    if [ "$_np_now" -lt "$_np_until" ]; then NODE_PROBE_INTERVAL="$_np_fast"; return 0; fi
    NODE_PROBE_INTERVAL="$_np_steady"
}

# 这一轮能不能判"断"（纯函数）：次数与时长两个条件都满足才算。
# 用"首次失败时刻"算时长而不是累加间隔——间隔会随上面那个函数变化，累加会漂。
# 结论进 ${NODE_VERDICT}（0 = 还不算断，1 = 可以判断）。
node_verdict() {
    local _nv_fail
    _nv_fail="$1"; _nv_span="$2"; _nv_thr="$3"; _nv_dwell="$4"
    if [ "$_nv_fail" -ge "$_nv_thr" ] && [ "$_nv_span" -ge "$_nv_dwell" ]; then
        NODE_VERDICT=1
    else
        NODE_VERDICT=0
    fi
}

# ------------------------------------------------------------------------------
# 3. 代理端口发现（不绑定品牌/端口号，只认"谁真的在提供代理服务"）
# ------------------------------------------------------------------------------
# 某个端口现在是否在监听。**三态**：
#   0 = 在监听   1 = 没在监听（确定）   2 = 不知道（读不出来）
#
# 为什么必须是三态：原来是一句 `lsof ... >/dev/null 2>&1`，把"命令不存在"、
# "权限不足"、"其它用户的 socket 看不到"全部读成"端口停了"。
# 上层据此清掉 CACHED_PORT、多睡 2 秒、重新枚举——每轮白烧 2 秒，
# 而且违反"读不出来 ≠ 没有"（这条在枚举层已经做对了，这里漏了）。
# 与 Windows 侧同一条契约：端口三态的第三态永远是"不知道"，不许塌缩。
test_port_listening() {
    lsof -iTCP:"$1" -sTCP:LISTEN -n -P >/dev/null 2>&1
    case $? in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

# ------------------------------------------------------------------------------
# nc 的能力探测（只做一次，结果缓存）。
#
# macOS 自带的 /usr/bin/nc 是 BSD 版，支持 -G <conntimeout>；
# 但 Homebrew 的 netcat（GNU 版）**没有 -G**，而且它在 PATH 里可能排在 /usr/bin 前面。
# 那种情况下 nc 会直接报错退出，错误被 2>/dev/null 吞掉 -> 握手永远失败 ->
# 候选集永远为空 -> 工具整个失效，而且不报任何错。
#
# 所以先探一次"这台机器的 nc 认不认 -G"，不认就换成等价写法：
# 用 curl 的 --connect-timeout 完成同一个 CONNECT 握手（curl 两边都有、参数一致）。
# ------------------------------------------------------------------------------
NC_HAS_G=""
# 缓存必须按值分派，不能按"非空"判断。反面写法 `[ -n "$NC_HAS_G" ] && { ... }` 错在：
# "0" 是非空字符串，所以那一行成立、进块，内层判等为假，可后面那句 return 0 **无条件执行**
# ——于是"这台机器的 nc 不认 -G"这个结论从第二次调用起被读成"认 -G"。
# 后果不是少一次降级，而是：第一次握手走 curl（对），之后全部退回 nc -G（错）→ 握手永远失败
# → 候选集永远为空 → 工具彻底失效，而且不报任何错。这正是这段能力探测本来要防的事。
nc_supports_G() {
    local _ncg_err
    case "$NC_HAS_G" in
        1) return 0 ;;
        0) return 1 ;;
    esac
    NC_HAS_G=0
    # **先确认 nc 这个命令存在**。少了这一步，"机器上根本没有 nc"会被判成"支持 -G"：
    # 那时 stderr 是 "command not found"，一个 invalid/usage 之类的词都没有，
    # 于是落进下面的通路当成"认 -G"，后续每次判活都 rc=127 → 活端口全被判死。
    # 这个判错方向很要命：'没装工具' 与 '工具不认这个开关' 必须分开处理。
    if ! command -v nc >/dev/null 2>&1; then
        # 没有 nc 就是"不支持 -G"（上面已置 0）——这一支不必再比较一次。
        # 原来写的是 [ "$NC_HAS_G" = "1" ]，恒假，看着像"想改回 1"的半截开关。
        return 1
    fi
    # 拿一个必然连不上的端口探语法：认 -G 的 nc 会安静失败（非 0 但没有 usage 报错），
    # 不认的会打印 "invalid option" 之类。判据是"错误输出里有没有提到 invalid/usage"。
    _ncg_err=$(printf '' | nc -G 1 -w 1 127.0.0.1 1 2>&1 >/dev/null)
    case "$_ncg_err" in
        *[Ii]nvalid*|*[Ii]llegal*|*[Uu]nknown*|*usage*|*Usage*|*not\ found*) NC_HAS_G=0 ;;
        *) NC_HAS_G=1 ;;
    esac
    unset _ncg_err 2>/dev/null || true
    [ "$NC_HAS_G" = "1" ]
}

# 探测本机代理要试两个回环地址（IPv4 与 IPv6，按序）。
# 只绑 IPv6 回环的代理（mihomo / sing-box 配 bind-address: "::1"）对 IPv4 主动拒绝，
# 只试一个会让这类用户永远检测不到代理、也不报任何错——最难被发现的那种失效。
# 与 Windows 侧 $LoopbackProbes 同义。
LOOPBACK_PROBES="127.0.0.1 ::1"

# 把回环地址转成 URL 里的写法：IPv6 字面量必须加方括号，
# 否则 "http://::1:7078" 里的端口会被解析成地址的一部分，代理地址整个作废。
url_host_for() {
    case "$1" in
        *:*) printf '[%s]' "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

# 在指定地址上做一次 CONNECT 握手。$1=地址 $2=端口。只有真代理才回 200。
_handshake_at() {
    if nc_supports_G; then
        _ha_resp=$(printf 'CONNECT 127.0.0.1:9 HTTP/1.1\r\nHost: 127.0.0.1:9\r\n\r\n' | nc -G 1 -w 2 "$1" "$2" 2>/dev/null | head -n 1)
    else
        # 降级：同一个 CONNECT 握手改用 curl 做。
        # 两个参数缺一不可：
        #   --noproxy ''  让 curl 真的去连我们指定的这个代理（写 '*' 是"绕过代理直连目标"，
        #                 语义正好相反——那样 curl 去连 127.0.0.1:9，必然失败，判据恒假）。
        #   -p            让 curl 用 CONNECT 建隧道。不加它，curl 对 http 目标发的是普通 GET，
        #                 于是"任何会回 200 的 HTTP 服务"都能通过握手门，判据就认错了东西。
        _ha_resp=$(curl_direct --disable -s -o /dev/null -D - --connect-timeout 1 --max-time 2 \
            --noproxy '' -p -x "http://$(url_host_for "$1"):$2" "http://127.0.0.1:9/" 2>/dev/null | head -n 1)
    fi
    # 状态码必须**整段**是 200：写成以 200 结尾会让 "2000"、"2001" 也匹配上。
    # 逐位比对一个状态码，不该留这种模糊地带；与 Windows 侧同一判据。
    printf '%s' "$_ha_resp" | grep -qE '^HTTP/1\.[01] +200( |$)'
}

# CONNECT 握手结果的**七分类**（给救援层判"这个端口到底是什么"用）。
#
# 为什么不能沿用 _handshake_at 的布尔：它只回答"能不能拿去注入"，
# 而救援要回答"这个端口是不是真代理、它现在为什么不能用"。两者不是同一个问题。
# 最要命的一种：节点挂掉的代理对 CONNECT 会回 **502**——
#   布尔判据把它当"不是代理"，于是"端口活着但握手不 200"会被读成"可以当残留删掉"，
#   而它恰恰是使用者**正在跑**的代理，只是上游节点不通。
#   "我是代理但连不上" 与 "我根本不是 HTTP" 必须分开。
#
# 输出：proxy-ok / proxy-auth / upstream-fail / refused / not-http / silent / closed
# 与 Windows 侧同一套词，门禁 6 核对。
handshake_kind_text() {
    # $1 = 一行应答原文
    case "${1:-}" in
        '') printf 'silent'; return 0 ;;
    esac
    # 状态码整段比对：写成以 200 结尾会让 "2000" 也匹配上。
    if printf '%s' "$1" | grep -qE '^HTTP/1\.[01] +200( |$)'; then printf 'proxy-ok'; return 0; fi
    if printf '%s' "$1" | grep -qE '^HTTP/1\.[01] +407( |$)'; then printf 'proxy-auth'; return 0; fi
    if printf '%s' "$1" | grep -qE '^HTTP/1\.[01] +5[0-9][0-9]( |$)'; then printf 'upstream-fail'; return 0; fi
    # 3xx 与其余 4xx：它确实说 HTTP，但这次没答应建隧道——归「拒绝」，不归「上游坏了」。
    if printf '%s' "$1" | grep -qE '^HTTP/1\.[01] +[34][0-9][0-9]'; then printf 'refused'; return 0; fi
    # 别的状态码（1xx/2xx 里非 200），**恰好三位**：\d{3} 会放过 "2000"，那不是状态码。
    if printf '%s' "$1" | grep -qE '^HTTP/1\.[01] +[0-9]{3}( |$)'; then printf 'refused'; return 0; fi
    printf 'not-http'
}

# 对一个端口做握手，输出七分类之一。与 _handshake_at 走同一条连接路径。
handshake_kind_at() {
    case "${2:-}" in ''|0) printf 'closed'; return 0 ;; esac
    _hkres=""
    if nc_supports_G; then
        _hkres=$(printf 'CONNECT 127.0.0.1:9 HTTP/1.1\r\nHost: 127.0.0.1:9\r\n\r\n' | nc -G 1 -w 2 "$1" "$2" 2>/dev/null | head -n 1)
    else
        _hkres=$(curl_direct --disable -s -o /dev/null -D - --connect-timeout 1 --max-time 2 \
            --noproxy '' -p -x "http://$(url_host_for "$1"):$2" "http://127.0.0.1:9/" 2>/dev/null | head -n 1)
    fi
    # 一个字节都没回：可能连不上，也可能连上了不说话。这里只说"没应话"，
    # 不假装知道是哪一种——知道死活的是调用方（它已经探过 TCP 了）。
    handshake_kind_text "$_hkres"
}
# 单端口 CONNECT 握手：按序试两个回环地址，任一成功即算这个端口是代理。
# 不发 ${PROXY_URL_HIT}：这条只回答"是不是代理"，命中地址由 proxy_url_for_port 现场取。
test_http_proxy() {
    for _tp_addr in $LOOPBACK_PROBES; do
        if _handshake_at "$_tp_addr" "$1"; then
            return 0
        fi
    done
    return 1
}

# 这个端口该按哪个地址注入？现场探测，取第一个连得上的。
# 不能固定写 127.0.0.1：只绑 ::1 的代理在 IPv4 上连不上，用户会拿到一个用不了的地址，
# 终端里每条命令 ECONNREFUSED，而状态页显示"已注入、正常"——比检测不到更糟。
# 结果放进 ${PROXY_URL_HIT}（不 printf：$( ) 是子 shell，全局赋值出不来）。
proxy_url_for_port() {
    local _pufp_addr
    _pufp_addr=""
    for _pufp_a in $LOOPBACK_PROBES; do
        if _handshake_at "$_pufp_a" "$1"; then _pufp_addr="$_pufp_a"; break; fi
    done
    [ -n "$_pufp_addr" ] || _pufp_addr="$1_PLACEHOLDER"
    case "$_pufp_addr" in
        *_PLACEHOLDER) _pufp_addr=$(printf '%s' "$LOOPBACK_PROBES" | cut -d' ' -f1) ;;
    esac
    PROXY_URL_HIT="http://$(url_host_for "$_pufp_addr"):$1"
    return 0
}

# 批量探测 worker（参数展开在父进程完成，避免后台子 shell 闭包竞态）。
# 握手判据只有 test_http_proxy 一处，这里直接复用，不重复写正则。
_probe_proxy_one() {
    local _pp
    _pp="$1"; _dir="$2"
    if test_http_proxy "$_pp"; then
        # 每个 worker 写自己专属的结果文件：并行写同一文件会截断拼接，
        # 曾拼出过不存在的"端口"，还会污染失败计数。
        printf '%s' "$_pp" > "$_dir/$_pp" 2>/dev/null || true
    fi
}

# 并行批量 CONNECT 探测：多个端口同时握手，~2 秒内出结果
test_http_proxy_batch() {
    local _bdir _hit _i _bpids _bp
    [ $# -eq 0 ] && return 1
    _bdir=$(mktemp -d "${TMPDIR:-/tmp}/${PROBE_TMP_PREFIX}found.XXXXXX" 2>/dev/null) || return 1
    # 记下自己起的 worker pid。`kill $(jobs -p)` / 无参 `wait` 收拾的是**整个 shell**
    # 的后台作业——调用方（测试、别的集成）在同一个 shell 里还有别的后台进程时，
    # 这里会把它们一起杀掉或一起等，实测会把一次自检卡死二十分钟。
    _bpids=""
    for _p in "$@"; do
        _probe_proxy_one "$_p" "$_bdir" &
        _bpids="$_bpids $!"
    done
    _i=0
    while [ $_i -lt 30 ]; do
        [ -n "$(ls -A "$_bdir" 2>/dev/null)" ] && break
        sleep 0.1
        _i=$((_i + 1))
    done
    # 有结果就收掉其余 worker 再返回，不空等全部跑完。只碰自己的。
    for _bp in $_bpids; do
        kill "$_bp" 2>/dev/null || true
    done
    for _bp in $_bpids; do
        wait "$_bp" 2>/dev/null || true
    done
    _hit=$(ls "$_bdir" 2>/dev/null | head -n 1)
    rm -rf "$_bdir" 2>/dev/null || true
    if [ -n "$_hit" ]; then
        printf '%s' "$_hit"
        return 0
    fi
    return 1
}

# 本机监听端口表（排序去重，无状态）。
#
# 返回码有讲究：0 = 读到了（哪怕一个端口都没有），非 0 = 读不出来。
# 这两种必须分开：读不出来时端口表是空的，而空表会被状态机读成
# "本机没有代理在监听" -> 判 off -> 把用户的代理环境变量删掉，而全程没有一条日志。
# Windows 侧是同一件事的另一种写法（那边抛错，交给上层"重试一次 + 记一条枚举失败"）。
#
# lsof 退出码 1 = 没有匹配的进程（这是正常结果，端口表就是空的）；
# 127 = 命令不存在或跑不起来（这才是"读不出来"）。
# DIVERGE(Mac): 取监听端口只有两层（lsof -> netstat），Windows 侧有三层。
# 差的第三层是 IPGlobalProperties.GetActiveTcpListeners()——那是个**进程内**接口，
# shell 里没有任何等价物，所以这边两层都得起外部进程。这不是漏做：
# 判据（读不出来 ≠ 没有端口）与上层语义两侧完全一致，只是实现手段受平台限制。
# 代价是 mac 每轮要多起一次进程；换来的是同一个三态结论（找到 / 真没有 / 读不出来）。
get_listening_ports() {
    local _glp_ns _glp_out _glp_raw _glp_rc _glp_sure
    # lsof 优先。退出码 1 = 没有匹配的进程（这是正常结果，不是读不出来），
    # 127 = 命令不存在或跑不起来（这才是读不出来）。
    _glp_raw=$(lsof -a -PiTCP -sTCP:LISTEN -n -P 2>/dev/null)
    _glp_rc=$?
    _glp_sure=0
    if [ $_glp_rc -eq 0 ] || [ $_glp_rc -eq 1 ]; then
        _glp_ports=$(printf '%s' "$_glp_raw" | grep -oE ':[0-9]+ \(LISTEN\)' | grep -oE '[0-9]+' | sort -nu)
        if [ -n "$_glp_ports" ]; then
            printf '%s' "$_glp_ports"
            return 0
        fi
        # 一个端口都没解析出来：lsof 自己什么都没输出 = 本机真的没有监听口；
        # 输出里有东西却解析不出来 = 输出形状变了（以后 macOS 改格式就是这种）。
        if [ -z "$_glp_raw" ]; then
            _glp_sure=1
        fi
    fi
    # 退到 netstat：lsof 不可用，或形状变了。
    _glp_out=$(netstat -anvp tcp 2>/dev/null)
    _glp_rc=$?
    if [ $_glp_rc -ne 0 ]; then
        # netstat 也读不出来：只有 lsof 明确"跑起来了、什么都没说"时才敢判"没有端口"；
        # 其余情况是"读不出来"，交上去让上层沿用上一状态（别把用户的变量删了）。
        if [ $_glp_sure -eq 1 ]; then
            return 0
        fi
        return 1
    fi
    _glp_ns=$(printf '%s' "$_glp_out" | awk '/LISTEN/ {print $4}' | sed 's/.*\.//' | grep -E '^[0-9]+$' | sort -nu)
    # netstat 也没解析出端口，而 lsof 已经证明本机确实有监听口（形状变了）——
    # 这时不能把空表当成"本机没有端口"：读不出来就是读不出来，交上去让上层沿用上一状态。
    if [ -z "$_glp_ns" ] && [ $_glp_sure -eq 0 ]; then
        return 1
    fi
    printf '%s' "$_glp_ns"
    return 0
}

# 可疑进程端口表（排序去重，无状态，可安全用于命令替换）。
# 解析只用一次 awk：pid→comm 映射与监听行匹配在同一次扫描里完成，
# 不再对每一行各起 awk/grep/head（原来每行 6–7 个进程，空转时最费电的就是它）。
get_suspect_ports() {
    local _lsofout _psmap _suspect
    _psmap=$(mktemp "${TMPDIR:-/tmp}/${PROBE_TMP_PREFIX}ps.XXXXXX" 2>/dev/null) || return 0
    _lsofout=$(mktemp "${TMPDIR:-/tmp}/${PROBE_TMP_PREFIX}lsof.XXXXXX" 2>/dev/null) || { rm -f "$_psmap" 2>/dev/null || true; return 0; }
    ps -ax -o pid=,comm= 2>/dev/null | tr '[:upper:]' '[:lower:]' > "$_psmap" 2>/dev/null || true
    if ! lsof -a -PiTCP -sTCP:LISTEN -n -P 2>/dev/null > "$_lsofout"; then
        rm -f "$_psmap" "$_lsofout" 2>/dev/null || true
        printf ''
        return 0
    fi
    _suspect=$(awk -v pats="$PATTERNS" '
        NR==FNR { comm[$1]=$2; next }
        $1=="COMMAND" { next }
        {
            pid=$2
            c=comm[pid]
            if (c=="") next
            if (match($0, /:[0-9]+ \(LISTEN\)/)) {
                seg=substr($0, RSTART+1, RLENGTH)
                gsub(/[^0-9]/, "", seg)
                if (seg=="") next
                n=split(pats, pa, " ")
                for (i=1; i<=n; i++) {
                    if (index(c, pa[i])>0) { print seg; break }
                }
            }
        }' "$_psmap" "$_lsofout" 2>/dev/null | sort -nu | tr '\n' ' ' | sed 's/ $//')
    rm -f "$_psmap" "$_lsofout" 2>/dev/null || true
    printf '%s' "$_suspect"
}

# 候选集发现（有序去重，本机零流量）：先已知端口（按表顺序），再可疑进程端口
# （数字排序），最后按需追加全端口批量探测的尾巴。全部过 CONNECT 握手门——
# 握手不过的（开发服务器、纯 SOCKS 口、认证口）进不了集合。
# 输出空格分隔的端口表（可能为空串，无状态，可安全用于命令替换）。
# 状态机按集合签名判断变化并逐个试活；只要首选不要全集的调用方继续用
# 只要首选不要全集的调用方自行取第一个元素。
# 探测"现在真实在用的代理端口"，供**只读画面**（状态页）使用。
#
# 为什么不直接用 find_candidate_ports：它只能靠"常见端口表 + 进程名"去猜。
# 用户把端口改成表外的值（实测 7099）时猜不中，状态页就打"未检测到"；
# 可同一屏的"代理变量"那行读的是真实值、试连还通着 —— 两行自相矛盾。
# 与 Windows 侧 Get-InUseProxyPort 同一套顺序、同一套理由。
#
#   1) 环境变量里那个值是我们自己写下的，它指向哪个端口就先验哪个（一次 TCP，毫秒级）。
#   2) 没命中才去找候选集，且**用全扫**：状态页一年点不了几次，"慢一点"远比"说谎"便宜。
# 输出端口号；返回码就是三态，调用方一次调用即可：
#   0 = 找到了（端口打印在 stdout）
#   1 = 枚举成功、确实没有代理（"真的没有"）
#   2 = 枚举读不出来（"不知道"）
#
# 为什么把三态放进返回码，而不是让调用方再问一次枚举层：
# 原来调用方拿到 1 之后又调了一次 find_candidate_ports 去分辨这两种，
# 而 find_candidate_ports 内部本身就是一次全端口 lsof+ps+CONNECT。
# 于是"没有代理"的机器上，状态页每 2 秒要跑**两轮**全扫。
# 三态在源头分开，调用方一次即可——状态页是每 2 秒刷新的热路径。
# $1（可选）：当前注入的代理端口，由**调用方**读好传进来。
#   不让本函数自己去读：那要调 env 层的 get_current_proxy_port，于是 probe 依赖 env、
#   env 又依赖 probe 的端口函数，形成环。探测层不该知道"变量存在哪、怎么读"。
get_in_use_proxy_port() {
    local _giu_cands _giu_first _giu_known _giu_rc
    _giu_known="${1:-}"
    case "$_giu_known" in
        ''|*[!0-9]*) ;;
        *)
            # 端口在听、且是 HTTP 代理（CONNECT 回 200）。不走节点的节流缓存：
            # 状态页要的是"此刻"，而且只验一个端口，代价可以接受。
            # 三态在 && 里的语义是对的：只有"确定在听"（return 0）才继续验握手，
            # "读不出来"（return 2）落到 else 那条路 -> 退回全扫。这里不需要额外分支。
            if test_port_listening "$_giu_known" && test_http_proxy "$_giu_known"; then
                printf '%s' "$_giu_known"
                return 0
            fi
            ;;
    esac
    _giu_cands=$(find_candidate_ports 1)
    _giu_rc=$?
    if [ $_giu_rc -ne 0 ]; then
        return 2
    fi
    _giu_first=$(printf '%s' "$_giu_cands" | awk '{print $1}')
    [ -n "$_giu_first" ] || return 1
    printf '%s' "$_giu_first"
    return 0
}

find_candidate_ports() {
    local _cands _full _ports _rc
    _full="$1"
    _cands=""
    # 端口枚举读不出来时直接失败返回：调用方据此知道"这一轮不知道"，
    # 而不是拿到一张空表当成"本机没有端口在监听"。
    _ports=$(get_listening_ports)
    _rc=$?
    if [ $_rc -ne 0 ]; then
        return 1
    fi
    # 来源 0（最优先）：系统代理里登记的本机端口。
    #
    # 为什么它排在"已知端口表"和"可疑进程"前面：它是**软件自己声明的对外端口**。
    # 凡是能被浏览器用的翻墙软件，都必须把对外那个口写进系统代理——这是操作系统
    # 层面的协议，与软件叫什么、谁做的、什么版本无关。而同一个软件往往还有别的口
    # 在听（内核/子进程之间的内部通道），那些口也过得了握手、也真能出去，
    # 只是用户在自己的界面上永远看不到它们。挑中那种口，用户就会觉得"你搞错了"。
    #
    # 实测过一台 MonoCloud（Windows 侧）：界面公告 10801，内核另开 51081，
    # 两个口都能翻墙、出口 IP 都一样。原来先扫已知端口、再用进程名提速，
    # 结果 51081 被选中并记住，此后每轮都复用。这类"同一软件多个可用口、该用哪个"
    # 的问题与具体软件无关，所以判据也不能写在某个软件名下：
    # **软件自己告诉系统用哪个，就用哪个。**
    #
    # 只是提到队首，不是跳过验证：它照样要过握手与节点两道门。
    # 读不出来（系统代理没开、是公司代理）就当没有这一条，不影响其余来源。
    for _dp in $(get_system_proxy_loopback_ports); do
        if printf '%s\n' "$_ports" | grep -qx "$_dp"; then
            if ! _in_list "$_dp" "$_cands"; then
                if test_http_proxy "$_dp"; then _cands="$_cands $_dp"; fi
            fi
        fi
    done
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
    # 批量探测有结果就结束轮询（本轮已启动的探针仍会收掉），所以一次只带回一个端口：
    # 候选集里有它，试活层就能收敛到它。覆盖面上限是"同时开两个都不在常见表里的
    # 代理软件，只认其中一个"——够用，因为只要有一个可用端口，注入就是正确的。
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



# ------------------------------------------------------------------------------
# 4. 真实节点连通性（快路优先 + 失败并行兜底；有状态，直接调用禁命令替换）
# ------------------------------------------------------------------------------
# 端点应答的状态码判定（唯一的判据实现，与 Windows 侧 Test-EndpointStatus 同义）。
# $1 = 状态码，$2 = 该端点声明的期望值（204 / 3xx）。
# 只认端点自己声明的那种应答：/generate_204 只认 204（被强制门户劫持时回 200 或 302，
# 那两种都不是"节点通"）；wikipedia 只认 3xx（它的正常应答就是重定向，
# 收 204 会让这两个跨域段兜底端点永远判死、端点池退化成纯 Google 段）。
test_endpoint_status() {
    case "$2" in
        204) [ "$1" = "204" ] && return 0; return 1;;
        3xx) [ "$1" -ge 300 ] 2>/dev/null && [ "$1" -le 399 ] 2>/dev/null && return 0; return 1;;
        *) return 1;;
    esac
}

test_single_endpoint() {
    local _code _first _out _port _px
    _port="$1"; _host="$2"; _path="$3"; _expect="${4:-204}"
    # 走哪个回环地址由调用方算好放在 $EP_PROXY_URL 里（每个端口探一次，不是每个端点探一次）。
    # 不设时退回 127.0.0.1：只绑 ::1 的代理在 IPv4 上连不上，写死会让端点探测对它永远失败。
    _px="${EP_PROXY_URL:-http://127.0.0.1:$_port}"
    # --disable（= -q）：不读用户 ~/.curlrc——否则用户配过的 proxy 会劫持这次探测，判据作废。
    _out=$(curl_direct --disable -s -D - -o /dev/null --head --connect-timeout 5 --max-time 6 -x "$_px" "http://$_host$_path" 2>/dev/null)
    [ -n "$_out" ] || return 1
    printf '%s' "$_out" | grep -qi "Connection Established" && return 1
    _first=$(printf '%s' "$_out" | head -n 1)
    # 只取第一行里的三位数字：不要求状态码前后都有空格。
    # 以前用 ' [0-9]{3} ' 要求尾部空格，服务端偶尔不发原因短语（"HTTP/1.1 204"）就解析成空 -> 误判断。
    _code=$(printf '%s' "$_first" | sed -n 's/^HTTP\/[0-9.]*[[:space:]]\{1,\}\([0-9]\{3\}\).*/\1/p')
    [ -n "$_code" ] || return 1
    test_endpoint_status "$_code" "$_expect"
}

_probe_endpoint_one() {
    local _port
    _port="$1"; _h="$2"; _pa="$3"; _idx="$4"; _dir="$5"; _exp="$6"
    if test_single_endpoint "$_port" "$_h" "$_pa" "$_exp"; then
        printf '%s' "$_idx" > "$_dir/answered.$_idx" 2>/dev/null || true
    fi
}

test_real_connectivity() {
    local _ep_n _fast_exp _fast_host _fast_path _idx _port _tmpdir _waited _pick _hw _probe_pids
    local _answered _k _sweep_deadline
    _port="$1"
    PROOF_DEGRADED=0
    # 先定下这个端口该走哪个回环地址（只算一次，下面所有端点共用）。
    # 只绑 ::1 的代理在 IPv4 上主动拒绝——不在这里定，下面每个端点都会连错地址。
    proxy_url_for_port "$_port"
    EP_PROXY_URL="$PROXY_URL_HIT"
    # 快路端点按索引取值（cut 实现，避免 set -- 篡改位置参数；索引越界则回退并行）
    _fast_host=$(check_endpoint_field $((LAST_GOOD_ENDPOINT + 1)) 1)
    _fast_path=$(check_endpoint_field $((LAST_GOOD_ENDPOINT + 1)) 2)
    _fast_exp=$(check_endpoint_field $((LAST_GOOD_ENDPOINT + 1)) 3)
    # 期望值必须跟着端点走：不传就吃默认 204，wikipedia（期望 3xx）会永远判死。
    # 快路也要过合格证：只加在兜底那边会让"上次命中的正是直连也通的端点"变成后门，
    # 而它恰恰是最常走的路径。
    if [ -n "$_fast_host" ] && [ -n "$_fast_path" ] \
        && test_proxy_endpoint_evidence "$_port" "$LAST_GOOD_ENDPOINT"; then
        return 0
    fi
    _tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/${PROBE_TMP_PREFIX}conn.XXXXXX" 2>/dev/null) || return 1
    _probe_pids=""
    # 逐个按索引展开 host/path，避免后台闭包竞态（参数在父进程展开后传值）
    _idx=0
    _ep_n=0
    while [ "$_ep_n" -lt "$(check_endpoint_count)" ]; do
        _ep_n=$((_ep_n + 1))
        _h=$(check_endpoint_field "$_ep_n" 1)
        _pa_for_idx=$(check_endpoint_field $((_idx + 1)) 2)
        _exp_for_idx=$(check_endpoint_field $((_idx + 1)) 3)
        if [ $_idx -ne $LAST_GOOD_ENDPOINT ] && [ -n "$_pa_for_idx" ]; then
            _probe_endpoint_one "$_port" "$_h" "$_pa_for_idx" "$_idx" "$_tmpdir" "${_exp_for_idx:-204}" &
            # 记下自己起的探针 pid：只等这些。无参 wait 会把 shell 里所有后台作业一起等，
            # 一旦调用方（测试、别的集成）在同一个 shell 里还有别的后台进程，就会永远等不到头。
            _probe_pids="$_probe_pids $!"
        fi
        _idx=$((_idx + 1))
    done
    # 收集阶段：并行探针只报"这个端点应答了"，合格证由父 shell 判。
    #
    # 为什么不在子进程里顺手判：合格证要写缓存（ENDPOINT_PROOF_CACHE），
    # 而 `&` 起的子 shell 里赋值出不来——每个端点会被反复重问一遍直连，
    # 正是这条缓存要省掉的开销。判据本身也因此只有一处实现。
    #
    # 收集窗口用**单调钟**算截止时刻，不数循环次数：`sleep 0.1` 在忙机器上
    # 实测每次可到 190ms，数 70 次就成了 24 秒，把整轮探测拖垮。
    mono_tick
    monotonic_now; _sweep_deadline=$((MONO_NOW + 7))
    while :; do
        monotonic_now
        [ "$MONO_NOW" -lt "$_sweep_deadline" ] || break
        for _pick in "$_tmpdir"/answered.*; do
            [ -f "$_pick" ] || continue
            _idx=$(cat "$_pick" 2>/dev/null || echo "")
            case "$_idx" in ''|*[!0-9]*) continue;; esac
            endpoint_proof "$_idx"
            if endpoint_proof_counts "$PROOF_KIND"; then
                LAST_GOOD_ENDPOINT="$_idx"
                rm -rf "$_tmpdir" 2>/dev/null || true
                # 只收掉**自己起的**那几个探针：无参 wait 会把 shell 里所有后台作业
                # （包括调用方的）一起等，一旦有别的东西在跑就永远等不到头（实测卡死）。
                # 也不能等全部探针——还在跑的那些各自最长 6 秒，会把一次"判通"白等十几秒。
                for _hw in $_probe_pids; do
                    wait "$_hw" 2>/dev/null || true
                done
                return 0
            fi
        done
        sleep 0.1
    done
    # 窗口耗尽：把并行探针收干净，然后**只用已拿到的应答**判证据，不再重发经代理请求。
    # 只等自己起的那几个——无参会连调用方的后台作业一起等。
    for _hw in $_probe_pids; do
        wait "$_hw" 2>/dev/null || true
    done
    _answered=""
    for _pick in "$_tmpdir"/answered.*; do
        [ -f "$_pick" ] || continue
        _idx=$(cat "$_pick" 2>/dev/null || echo "")
        case "$_idx" in ''|*[!0-9]*) continue;; esac
        _answered="$_answered $_idx"
    done
    rm -rf "$_tmpdir" 2>/dev/null || true

    # 判定阶段：请求都发完了，这里只做本地判断，另给自己的预算。
    if [ -n "$_answered" ]; then
        mono_tick
        monotonic_now; _sweep_deadline=$((MONO_NOW + ENDPOINT_PROOF_SWEEP_BUDGET_SEC))
        for _k in $_answered; do
            monotonic_now
            [ "$MONO_NOW" -lt "$_sweep_deadline" ] || break
            endpoint_proof "$_k"
            if endpoint_proof_counts "$PROOF_KIND"; then
                LAST_GOOD_ENDPOINT="$_k"
                return 0
            fi
        done
    fi

    # ---- 走到这里说明：代理对端点有应答，但没有一个端点的「通」能证明代理真能出去 ----
    #
    # 三种情况必须分开处置，混在一起就是这次事故的根源：
    #   ① 有"确定被墙"的端点 -> 判据可用，是代理真连不出去 -> 返回不通（正常路径）
    #   ② 六个端点全部直连可达 -> 本机直连被整体接管（TUN / 透明代理），判据在这里恒真、
    #      证明不了任何事。判"不通"会让一个正常工作的代理永远被判死且不自愈，
    #      所以退回旧判据（有应答就算通），并标记 PROOF_DEGRADED 让上层记一笔。
    #   ③ 其余（全是 Unknown，或混着） -> 本机问不出来，正确回答是"没法证明"。
    #      这时**不许**退回旧判据：那恰好会让一个死节点靠随便一个 204 重新骗过判决。
    if any_endpoint_blocked; then return 1; fi
    if all_endpoints_reachable; then
        PROOF_DEGRADED=1
        if [ -n "$_answered" ]; then
            set -- $_answered
            LAST_GOOD_ENDPOINT="$1"
        fi
        return 0
    fi
    return 1
}

# 自适应节流 + 双条件迟滞（与 Win 侧 Test-NodeAlive 同语义）
# 迟滞必须不对称（这不是可调口味，是判据本身）：判"断"的代价是「删变量 + 通知所有应用
# 重读环境」，影响机器上每一个应用；误留代理变量的代价只是多等一会儿。两个代价不对称，
# 判据就不许对称——一次探测不通不等于代理没了。反向约束同样成立："通"要快（1 次成功即认），
# 否则重连后要白等一个迟滞窗口。
# 为什么是"次数 + 时长"两个条件而不是只数次数：只数次数时，判据的时长是
# 「次数 × 节流间隔」的乘积，改节流省的流量会直接变成判"断"的耗时，两件事被一个旋钮绑住。
# 拆开后：防抖强度（能吸收多长的抖动）只看 dwell，流量口径只看稳定态间隔，各管各的。
# 节流缓存只认"同一端口"（单槽位：bash 3.2 无关联数组）。
# 同端口节流内直接给缓存结论；换端口一律重验——多候选试活时不会读到别的端口的旧结论。
# DIVERGE(Mac): Win 侧用哈希表按端口分槽（LastCheck / Alive / FailCount / FirstFailAt 各一份），
# Mac 侧单槽。换端口时把失败计数与起点一起清零（见下面那处），否则上一个端口留下的
# 失败起点会让新端口的 dwell 立刻满足——那条差异就从"可能早判几秒"收窄成"不成立"。
test_node_alive() {
    local _idle _now _port
    _port="$1"; _force="${2:-0}"
    # **时钟由主循环刷新（runtime.sh 每轮开头 mono_tick 一次），这里只读。**
    # 原来这里也调一次：candidate 有 N 个端口时一轮就起 N+1 次 perl（每次约 15ms）。
    # 注释当时写的"每轮至多一次 fork"因此从没成立过——而这正是它想省的。
    # monotonic_now 在缓存缺失时会自己补一次，所以单测这条路径也安全。
    monotonic_now
    _now=$MONO_NOW
    if [ "$_force" != "1" ] && [ "$_port" = "$NODE_CACHE_PORT" ]; then
        _age=$((_now - LAST_NODE_CHECK))
        node_probe_interval "$NODE_FAIL_COUNT" "$NODE_FAIL_THRESHOLD" "$NODE_FAST_UNTIL" "$_now" \
            "$NODE_CHECK_THROTTLE_SEC" "$NODE_FAST_SEC"
        if [ $_age -lt "$NODE_PROBE_INTERVAL" ]; then
            [ "$NODE_ALIVE" = "1" ] && return 0 || return 1
        fi
    fi
    # 换端口：上一个端口的失败计数与起点对新端口没有意义，必须清零再算。
    if [ "$_port" != "$NODE_CACHE_PORT" ]; then
        NODE_FAIL_COUNT=0
        NODE_FIRST_FAIL_AT=0
        # 结论也属于上一个端口。不清的话，新端口首次失败（计数才 1、未达阈值）时
        # 函数末尾会沿用上个端口的"通"，把刚探测失败的端口报成通——正是"不该写时写"。
        NODE_ALIVE=0
    fi
    # "连续"失败必须先真的连续观测：同一端口很久没探过（槽位留着旧账），那几次失败
    # 与现在不构成同一个连续段。不清零的话，跨度会把中间整段没观测的时间算进去，
    # 一回来就同时满足"≥N 次"和"≥dwell 秒"而当场判"断"——比契约激进。
    # 门限用独立常量，不借用节流档位（两者含义不同，绑一起会让调任一个都牵动另一个）。
    _idle=$((_now - LAST_NODE_CHECK))
    if [ "$NODE_FAIL_COUNT" -gt 0 ] && [ "$_idle" -gt "$NODE_IDLE_RESET_SEC" ]; then
        NODE_FAIL_COUNT=0
        NODE_FIRST_FAIL_AT=0
    fi
    LAST_NODE_CHECK="$_now"
    NODE_CACHE_PORT="$_port"
    if test_real_connectivity "$_port"; then
        NODE_FAIL_COUNT=0
        NODE_FIRST_FAIL_AT=0
        # 只在结论翻转（断->通）时开加密观察窗。若每次成功都重开，窗口永远不结束，
        # 稳态间隔就永远走不到——实测会退化成每 5-6 秒一探，流量是承诺值的 3 倍。
        [ "$NODE_ALIVE" = "1" ] || NODE_FAST_UNTIL=$((_now + NODE_FAST_WINDOW_SEC))
        NODE_ALIVE=1
        return 0
    else
        NODE_FAIL_COUNT=$((NODE_FAIL_COUNT + 1))
        [ "$NODE_FIRST_FAIL_AT" -eq 0 ] && NODE_FIRST_FAIL_AT="$_now"
        _span=$((_now - NODE_FIRST_FAIL_AT))
        node_verdict "$NODE_FAIL_COUNT" "$_span" "$NODE_FAIL_THRESHOLD" "$NODE_FAIL_DWELL_SEC"
        if [ "$_force" = "1" ] || [ "$NODE_VERDICT" = "1" ]; then
            # 只在结论翻转（通->断）时开窗：判错的话 5 秒内就能探到成功、把变量补回来。
            [ "$NODE_ALIVE" = "1" ] && NODE_FAST_UNTIL=$((_now + NODE_FAST_WINDOW_SEC))
            NODE_ALIVE=0
        fi
        [ "$NODE_ALIVE" = "1" ] && return 0 || return 1
    fi
}

# 有序试活：按候选顺序逐个验证，首个真活的进 ${CONFIRM_HIT}，否则空（只读，不写状态）。
# 规则只有两条：
#   1) $2（上次验活过、仍在集合里）先用缓存结论试（节流窗口内零新增探测）；
#   2) 其余一律当场验（force=1）。集合抖动但首选仍活时，不烧探测、不改状态。
# 有状态：直接调用，结果进 ${CONFIRM_HIT}，禁止 $(...) 包裹。
CONFIRM_HIT=""

confirm_candidate_port() {
    local _cands
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

# 当前真实状态（有状态：直接调用，结果进 ${CURRENT_STATE}，禁止 $(...) 包裹）
get_current_state() {
    local _cands _just_lost _rc _sig_changed
    ROUND=$((ROUND + 1))
    if [ -n "$CACHED_PORT" ]; then
        # 三态：0=在听、1=没在听、2=读不出来。
        # **"读不出来"不许当成"没在听"**：那会清掉缓存、多睡 2 秒、重新全扫，
        # 而真实情况可能是 lsof 权限不足、或某个用户的 socket 看不到。
        # 这时唯一安全的处置是沿用上一状态、这一轮不参与去抖。
        test_port_listening "$CACHED_PORT"
        _cpl=$?
        if [ "$_cpl" -eq 2 ]; then
            # 这一层不认识"上一状态"（那是主循环的局部变量）：按契约返回 1，
            # 由调用方沿用上一状态、且不把这一轮算进去抖。
            return 1
        fi
        if [ "$_cpl" -eq 0 ]; then
            # 在位复核（约每 10 轮一次，本机零流量）：代理退出后若有别的程序
            # 占了同一端口，握手不过立即丢缓存，不等 15 秒节点节流。
            # 置 off 后照常进主循环双轮去抖，不会单轮抖动。
            if [ $((ROUND % 10)) -eq 0 ]; then
                if ! test_http_proxy "$CACHED_PORT"; then
                    CACHED_PORT=""
                    # 刚失去这个端口：下一轮立刻深扫一次再下结论。
                    # 否则要等第 10 轮全扫，而用户此刻多半已经换到表外的端口上了。
                    NEED_DEEP_SCAN=1
                    CURRENT_STATE="off"
                    return 0
                fi
            fi
            # 优先权复核（约每 10 轮一次，纯本机读取、不联网）：现在用的这个端口
            # 还是不是"软件自己声明的那个"。
            #
            # 为什么要有这一步：端口一旦被选中就会被记住、此后每轮优先复用，于是
            # **先选错就永远错下去**。实测过一台 MonoCloud ——内核另开的 51081 先被
            # 选中并记住，界面公告的 10801 一次都没被用过，尽管它一直在候选集第一位。
            # 只把优先级排对不够，"已经记错了"这件事必须能被纠回来。
            #
            # 判据是通用的：软件把哪个口写进系统代理，那个口就是它认定的对外端口，
            # 与软件名无关。读不出来 / 是公司代理 / 系统代理没开时为空，
            # 此时**不动**——没有更好的信息就不该改变现状。
            if [ $((ROUND % 10)) -eq 0 ]; then
                _prp_declared=$(get_system_proxy_loopback_ports 2>/dev/null || true)
                if [ -n "$_prp_declared" ]; then
                    _prp_cur="$CACHED_PORT"
                    _prp_keep=0
                    for _prp_d in $_prp_declared; do
                        [ "$_prp_d" = "$_prp_cur" ] && _prp_keep=1 && break
                    done
                    if [ "$_prp_keep" = "0" ]; then
                        for _prp_d in $_prp_declared; do
                            # 两道门都要过：是 HTTP 代理，且真能翻墙。少一道就会把
                            # "另一个恰好也在监听的端口"误当成更好的选择。
                            test_port_listening "$_prp_d" || continue
                            test_http_proxy "$_prp_d" || continue
                            test_node_alive "$_prp_d" 1 || continue
                            CACHED_PORT="$_prp_d"
                            LAST_ALIVE_PORT="$_prp_d"
                            CURRENT_STATE="on:$_prp_d"
                            return 0
                        done
                    fi
                fi
            fi
            if test_node_alive "$CACHED_PORT" 0; then
                CURRENT_STATE="on:$CACHED_PORT"
            else
                CACHED_PORT=""
                # 同上：换节点/重连/改端口都会走到这里，下一轮深扫一次。
                NEED_DEEP_SCAN=1
                CURRENT_STATE="off"
            fi
            return 0
        fi
        sleep 2
        _cands=$(find_candidate_ports 1)
        _rc=$?
        if [ $_rc -ne 0 ]; then
            # 端口枚举失败：这一轮不知道。不判 off——判 off 会删掉用户的代理变量，
            # 而真实情况可能只是这一次没读到。返回非 0，交给主循环"沿用上一状态"。
            log_msg "端口枚举失败 -> 本轮沿用上一状态，不动环境变量"
            # 这次全扫没做成，但"刚丢了端口、需要深扫确认"的意图仍然成立，
            # 记下来下一轮再试——不记的话要等第 10 轮的节流点，实测多花约 6 秒。
            NEED_DEEP_SCAN=1
            return 1
        fi
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
    # 刚丢掉缓存（端口停了 / 在位复核失守 / 节点不通）时立刻全扫一次：
    # 用户改端口、换软件、断开重连都走这条路径，新端口往往不在常见表里，
    # 靠"每 10 轮才全扫"会让空窗拖到约 27 秒（off 态每轮 sleep 3）。
    # 稳态（一直 off、从没活过）仍按 10 轮节流，不白烧 CPU。
    #
    # ③ **还没做过任何一次全扫**：此时快扫的"什么都没看见"分不清"真没有"
    # 与"端口在表外"，必须全扫一次才能下结论。少了 ③，机器上已经开着翻墙软件、
    # 而它绑在表外端口时，首轮快扫会判 off，要等到第 10 轮才发现——约 27 秒里
    # 用户看着"未检测到"而代理其实好好的。Windows 侧同样有这条（needFirstFullScan）。
    #
    # ③ 的判据必须是"做过就置位、永不回退"的标记，不能用"签名是不是空"：
    # 机器上从头到尾没有代理时签名恒为空串，用它当判据会让每一轮都全扫。
    _just_lost=$NEED_DEEP_SCAN
    NEED_DEEP_SCAN=0
    if [ "$EVER_FULL_SCANNED" = "1" ]; then _need_first=0; else _need_first=1; fi
    if [ $((ROUND % 10)) -eq 0 ] || [ "$_just_lost" = "1" ] || [ "$_need_first" = "1" ]; then
        _full=1
    else
        _full=0
    fi
    _cands=$(find_candidate_ports "$_full")
    _rc=$?
    if [ $_rc -ne 0 ]; then
        # 端口枚举失败：这一轮不知道。不判 off（理由同上）。
        log_msg "端口枚举失败 -> 本轮沿用上一状态，不动环境变量"
        # 把"该深扫"的意图还回去：上面已经清掉，而这次全扫根本没做成。
        # 首轮那次也不能算数，否则 EVER_FULL_SCANNED 被误置后永不再补扫。
        if [ "$_just_lost" = "1" ] || [ "$_need_first" = "1" ]; then NEED_DEEP_SCAN=1; fi
        return 1
    fi
    # 到这里全扫是真的做成了（枚举成功）。置位那个"永不回退"的标记，
    # 让"首轮必须全扫"只在真的没扫过时成立。与 Windows 侧 30 行位置同义。
    if [ "$_full" = "1" ]; then EVER_FULL_SCANNED=1; fi
    # ① **快扫的空结果要看"上次全扫看见了什么"**，不能一律当成"本机没有代理"，
    #    也不能一律当成"不知道"：
    #    · 上次全扫也是空的 -> 两轮一致，"确实没有代理"，判 off。
    #      这是最常见的情形（翻墙软件关着）。若在这里返回"不知道"，
    #      调用方的去抖永远凑不齐"连续两轮确认"，状态会卡在旧的 on:端口 下不来，
    #      变量一直指向死端口，而屏幕上同时显示"已开启""端口已不在"，自相矛盾。
    #      Windows 侧实测就是这样卡住的（关了软件十几分钟不变）。
    #    · 上次全扫看见过端口 -> 快扫的空可能是"它搬到了表外的新端口"，
    #      不能当成没有（会删掉使用者正在用的变量）；本轮不下结论，
    #      并安排下一轮全扫去确认。
    # ② **快扫不许改写签名**。全扫记下 "7099"，下一轮快扫算出 ""，两串不同 ->
    #    判"集合变化" -> 重新试活 -> 候选集空 -> off -> 下一轮全扫又"发现变化"。
    #    "集合变化 = 强信号"会被自己的节流反复触发。故只有全扫轮更新签名。
    if [ "$_full" = "0" ] && [ -z "$_cands" ] && [ -n "$LAST_SEEN_SET" ]; then
        # 上一轮全扫记得有端口，而这一轮快扫什么都没看见：不下结论，并安排全扫。
        #
        # **必须 return 1（未判定），不能 return 0。** return 0 的语义是"判出来了"，
        # 调用方于是拿 CURRENT_STATE 里上一轮留下的值当本轮结论：
        # 去抖会把它算作一条支持证据、快照会写成"端口扫描 ok"，
        # 而 CURRENT_STATE 若恰好停在 off，两轮之后就会删掉使用者的代理变量。
        # Windows 侧这一分支返回 "unknown"（probe.ps1 同一位置），两侧必须同形。
        NEED_DEEP_SCAN=1
        return 1
    fi
    _sig_changed=0
    if [ "$_full" = "1" ]; then
        if [ "$_cands" != "$LAST_SEEN_SET" ]; then _sig_changed=1; fi
        LAST_SEEN_SET="$_cands"
    else
        # 快扫：只在"看见了东西"时才算集合变化，且不改签名。
        if [ -n "$_cands" ] && [ "$_cands" != "$LAST_SEEN_SET" ]; then _sig_changed=1; fi
    fi
    if [ "$_sig_changed" = "1" ]; then
        # 集合变化 = 强信号（新到、离开、换端口、增减成员）：走一遍有序试活。
        # 上次验活的仍在就认回它（缓存结论，零新增探测）；新面孔当场验 → 秒级收敛。
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
# TCP 判活：连得上吗？**只连端口，绝不建隧道。**
#
# 语义：0 = 活着，1 = 不在。三处都走这一个函数（见文件里的调用点），
# 同一件事只许有一处判据——否则"状态页说活着、修复页说死了"这种分叉迟早出现。
#
# ## 为什么必须只用 /dev/tcp（不许退回 curl -p / -x）
# 曾经的写法是 `curl -p -x <proxy> http://127.0.0.1:9/`，它做的是「让代理去连
# 127.0.0.1:9」——判的不是"端口在不在"，而是"代理能不能带你访问那个目标"。
# 两者不等价，差别是要命的那种：代理端口活着、但翻墙节点挂了 / 目标被墙 →
# 隧道失败 → 判 dead → 救援把使用者**正在用**的代理关掉。
# `/dev/tcp` 是 bash 内建，语义就是 connect()，零 fork、无输出、不可能是隧道。
#
# ## 超时
# `/dev/tcp` 走内核 connect()，没有自己的时限。本机死端口实测稳定在 2 秒左右
# （立刻被拒或被丢弃后回退），没有出现"卡到系统级超时"的量级。这个函数会在
# 「网络与代理修复」里被每个网络服务 × 每一层各调一次，2 秒 × 十几个调用确实
# 拖得久，但它换来的是"不可能误判"——判错的代价是删掉活着的代理。
# 要提速就减少调用次数，不是换成一个可能建隧道的实现。
# ------------------------------------------------------------------------------
# 单个地址上试一次 TCP 连接，只回答"这个端口还在不在"。
# 状态页用它判两件事：注入的代理变量指向的端口、系统代理指向的端口。
# 与 Windows 侧 Test-TcpAlive 同一判据（那边按地址族建套接字，这边同样只连一次）。
#
# 用 bash 内建的 /dev/tcp，不用 nc 也不用 curl：
#   - nc 的 -G 在部分 macOS 版本不存在（Homebrew 的 GNU netcat 就没有 -G），
#     那时旧代码会退到 curl；而 curl 那条路是 `-p -x http://addr:port http://127.0.0.1:9/`，
#     它**真的去建一条到 127.0.0.1:9 的代理隧道**——端口 9 没人听，连接被拒，
#     curl 返回非零，于是活着的代理端口被判成死的。判活只该连端口，不该建隧道。
#   - /dev/tcp 零依赖、零 fork、无输出，语义就是"连得上吗"。
#   - 与 doctor 层 sysproxy_port_state 同一套实现：同一件事不许有两套判据。
#
# IPv6 要带方括号才拼得进 /dev/tcp；裸 ::1 会被解析成别的东西（冒号当分隔符）。
port_alive_bounded() {
    _pab_addr="$1"; _pab_port="$2"
    [ -n "$_pab_addr" ] && [ -n "$_pab_port" ] || return 1
    case "$_pab_addr" in
        *:*) _pab_host="[$_pab_addr]" ;;
        *)   _pab_host="$_pab_addr" ;;
    esac
    if (exec 3<>"/dev/tcp/${_pab_host}/${_pab_port}") 2>/dev/null; then
        { exec 3<&-; } 2>/dev/null || true
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------
# 只认 SOCKS 的端口（体检页用；不进主循环）
# ------------------------------------------------------------------------------
# 解决的是最气人的一种"不管用"：客户端只开了 SOCKS 口（Surge 的 socks-port、
# mihomo 的 socks-port、ssh -D），本工具的三层判据里第二层（CONNECT 握手）
# 必然不过，于是状态页说"没检测到代理"，而终端里也确实没被设成代理。
# 用户看不出这是"端口协议不对"，只会觉得工具坏了。
#
# 这里做的是**解释**，不是判决：只回答"本机是不是有一个只认 SOCKS 的端口"。
# 判决照旧走三层，绝不因为"发现了 SOCKS 口"就把它当代理注入——
# 那会让 ALL_PROXY 指向一个只认 HTTP 的工具不认的端口。
#
# 候选集只取客户端目录里的默认端口：全端口扫一遍再逐个握手会把体检页拖到几十秒，
# 而"用户自己改到表外端口的纯 SOCKS 口"本来就不是这个检查器能负责的事。
#
# 这条与 Windows 侧 Test-Socks5Port 判据同形：3 字节问候（05 01 00），
# 只看回包的**版本字节**（0x05）。方法字节不看——00「无需认证」与 FF「没有可接受的方法」
# 都说明"这里是 SOCKS5 服务端"。
test_socks5_port() {
    _ts5_port="${1:-}"
    case "$_ts5_port" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_ts5_port" -gt 0 ] 2>/dev/null || return 1
    # 花括号分组 + 组上重定向：exec 自己的 2>/dev/null 不会生效（重定向按序处理，
    # 打开 /dev/tcp 失败时它还没轮到），而分组不是子 shell，fd 3 留在当前 shell 里。
    if ! { exec 3<>"/dev/tcp/127.0.0.1/$_ts5_port"; } 2>/dev/null; then
        return 1
    fi
    printf '\005\001\000' >&3 2>/dev/null || { exec 3<&- 2>/dev/null; return 1; }
    _ts5_r=''
    IFS= read -r -n 1 -t 1 _ts5_r <&3 2>/dev/null || true
    { exec 3<&-; } 2>/dev/null || true
    [ "$_ts5_r" = "$(printf '\005')" ] && return 0
    return 1
}

# 找出「在监听、但只认 SOCKS5」的端口。输出 "端口|客户端名" 一行一个。
# 混合端口（HTTP 与 SOCKS5 都应答）不算：它们能正常注入，没有可抱怨的地方。
socks_only_ports() {
    _sop_map=$(printf '%s\n' "$CLIENT_CATALOG" | awk -F'|' '
        NF >= 3 {
            n = split($3, p, " ")
            for (i = 1; i <= n; i++) {
                if (p[i] == "" || (p[i] in seen)) continue
                seen[p[i]] = 1
                print p[i] "|" $2
            }
        }')
    # **先问"在不在听"，再动手**：一次监听枚举约几十毫秒，而逐个端口做握手，
    # 每个不开的端口都要白等到超时（Windows 侧实测四十个候选串行握手花了 25 秒）。
    # 顺序也是性能决定：先发 3 字节 SOCKS 问候（最坏 1 秒），只有它应话了才做
    # CONNECT 握手去排除混合端口——混合端口两种协议都应答，属于"能用"，不报。
    _sop_listen=" $(get_listening_ports 2>/dev/null | tr '\n' ' ') "
    while IFS='|' read -r _sop_port _sop_name; do
        [ -n "$_sop_port" ] || continue
        case "$_sop_listen" in *" $_sop_port "*) : ;; *) continue ;; esac
        test_socks5_port "$_sop_port" || continue
        _sop_kind=$(handshake_kind_at 127.0.0.1 "$_sop_port")
        case "$_sop_kind" in
            silent|not-http) : ;;
            *) continue ;;
        esac
        printf '%s|%s\n' "$_sop_port" "$_sop_name"
    done <<EOF
$_sop_map
EOF
    return 0
}