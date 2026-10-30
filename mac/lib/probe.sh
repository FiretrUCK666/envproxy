# ------------------------------------------------------------------------------
#  probe.sh — 探测层：端口发现、CONNECT 握手、真实节点连通、当前状态判定
#  判决三层缺一不可；只做快筛的表不影响覆盖面。
# ------------------------------------------------------------------------------

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
KNOWN_PORTS="7078 7890 7897 10808 10809 10801 2080 2081 1080 8118 8080 6152 8888 12334"  # 12334 = Hiddify-Next 默认

# 翻墙软件进程名特征（只影响速度不影响覆盖面）。可自行扩展。
# 不认品牌、不认版本：mihomo-party/flclash 已被 mihomo/clash 命中；Stash/Quantumult X 默认 Network Extension 模式、不产生本地口，故不单列。
PATTERNS="monocloud clash mihomo verge v2ray xray sing-box singbox hiddify shadowsocks ss-local trojan hysteria neko netch surge outline"

# 验证端点（与 Windows 版一致：跨厂商/跨域段，快路优先 + 失败并行兜底）。
# 端点池的两条硬要求，缺一不可：
#   1) 跨厂商/跨域段——单个域段被干扰时其余端点仍能证明节点活着；
#   2) 响应体"零字节或极小"——探针发 HEAD 请求（--head），只收响应头、不收正文。
#      现有 6 个端点：5 个 /generate_204（0 字节 204）+ 1 个被墙站点（重定向）。
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
    _mn=""
    if command -v perl >/dev/null 2>&1; then
        _mn=$(perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e 'printf "%d", clock_gettime(CLOCK_MONOTONIC)' 2>/dev/null)
    fi
    case "$_mn" in
        ''|*[!0-9]*) _mn=$(date +%s 2>/dev/null || echo 0) ;;
    esac
    _MONO_LAST="$_mn"
    _MONO_READY=1
    return 0
}

# 取"现在"，结果放进 $MONO_NOW。
#
# **不 printf 输出**，因为任何 `x=$(monotonic_now)` 都会开子 shell：
# 子 shell 读不到父 shell 的 $_MONO_LAST，于是每次都真去 fork 一个 perl。
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
# 结果进 $NODE_PROBE_INTERVAL（本侧 bash 3.2 无 $(...) 之外的方便返回手段，统一走全局）。
node_probe_interval() {
    _np_fail="$1"; _np_thr="$2"; _np_until="$3"; _np_now="$4"; _np_steady="$5"; _np_fast="$6"
    if [ "$_np_fail" -gt 0 ] && [ "$_np_fail" -lt "$_np_thr" ]; then NODE_PROBE_INTERVAL="$_np_fast"; return 0; fi
    if [ "$_np_now" -lt "$_np_until" ]; then NODE_PROBE_INTERVAL="$_np_fast"; return 0; fi
    NODE_PROBE_INTERVAL="$_np_steady"
}

# 这一轮能不能判"断"（纯函数）：次数与时长两个条件都满足才算。
# 用"首次失败时刻"算时长而不是累加间隔——间隔会随上面那个函数变化，累加会漂。
# 结论进 $NODE_VERDICT（0 = 还不算断，1 = 可以判断）。
node_verdict() {
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
test_port_listening() {
    lsof -iTCP:"$1" -sTCP:LISTEN -n -P >/dev/null 2>&1
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
    case "$NC_HAS_G" in
        1) return 0 ;;
        0) return 1 ;;
    esac
    NC_HAS_G=0
    # 拿一个必然连不上的端口探语法：认 -G 的 nc 会安静失败（退出码非 0 但没有 usage 报错），
    # 不认的会打印 "invalid option" 之类。判据是"错误输出里有没有提到 G"。
    _ncg_err=$(printf '' | nc -G 1 -w 1 127.0.0.1 1 2>&1 >/dev/null)
    case "$_ncg_err" in
        *[Ii]nvalid*|*[Ii]llegal*|*[Uu]nknown*|*usage*|*Usage*) NC_HAS_G=0 ;;
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

# 单端口 CONNECT 握手：按序试两个回环地址，任一成功即算这个端口是代理。
# 命中的地址放进 $LOOPBACK_HIT（注入端要用它拼 URL）。
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
# 结果放进 $PROXY_URL_HIT（不 printf：$( ) 是子 shell，全局赋值出不来）。
proxy_url_for_port() {
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
    _pp="$1"; _dir="$2"
    if test_http_proxy "$_pp"; then
        # 每个 worker 写自己专属的结果文件：并行写同一文件会截断拼接，
        # 曾拼出过不存在的"端口"，还会污染失败计数。
        printf '%s' "$_pp" > "$_dir/$_pp" 2>/dev/null || true
    fi
}

# 并行批量 CONNECT 探测：多个端口同时握手，~2 秒内出结果
test_http_proxy_batch() {
    [ $# -eq 0 ] && return 1
    _bdir=$(mktemp -d "${TMPDIR:-/tmp}/${PROBE_TMP_PREFIX}found.XXXXXX" 2>/dev/null) || return 1
    for _p in "$@"; do
        _probe_proxy_one "$_p" "$_bdir" &
    done
    _i=0
    while [ $_i -lt 30 ]; do
        [ -n "$(ls -A "$_bdir" 2>/dev/null)" ] && break
        sleep 0.1
        _i=$((_i + 1))
    done
    # 有结果就收掉其余探针再返回，不空等全部跑完。
    kill $(jobs -p) 2>/dev/null || true
    wait 2>/dev/null || true
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
    _giu_known="${1:-}"
    case "$_giu_known" in
        ''|*[!0-9]*) ;;
        *)
            # 端口在听、且是 HTTP 代理（CONNECT 回 200）。不走节点的节流缓存：
            # 状态页要的是"此刻"，而且只验一个端口，代价可以接受。
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
    _full="$1"
    _cands=""
    # 端口枚举读不出来时直接失败返回：调用方据此知道"这一轮不知道"，
    # 而不是拿到一张空表当成"本机没有端口在监听"。
    _ports=$(get_listening_ports)
    _rc=$?
    if [ $_rc -ne 0 ]; then
        return 1
    fi
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
    _port="$1"; _h="$2"; _pa="$3"; _idx="$4"; _dir="$5"; _exp="$6"
    if test_single_endpoint "$_port" "$_h" "$_pa" "$_exp"; then
        printf '%s' "$_idx" > "$_dir/win" 2>/dev/null || true
    fi
}

test_real_connectivity() {
    _port="$1"
    # 先定下这个端口该走哪个回环地址（只算一次，下面所有端点共用）。
    # 只绑 ::1 的代理在 IPv4 上主动拒绝——不在这里定，下面每个端点都会连错地址。
    proxy_url_for_port "$_port"
    EP_PROXY_URL="$PROXY_URL_HIT"
    # 快路端点按索引取值（cut 实现，避免 set -- 篡改位置参数；索引越界则回退并行）
    _fast_host=$(check_endpoint_field $((LAST_GOOD_ENDPOINT + 1)) 1)
    _fast_path=$(check_endpoint_field $((LAST_GOOD_ENDPOINT + 1)) 2)
    _fast_exp=$(check_endpoint_field $((LAST_GOOD_ENDPOINT + 1)) 3)
    # 期望值必须跟着端点走：不传就吃默认 204，wikipedia（期望 3xx）会永远判死。
    if [ -n "$_fast_host" ] && [ -n "$_fast_path" ] \
        && test_single_endpoint "$_port" "$_fast_host" "$_fast_path" "${_fast_exp:-204}"; then
        return 0
    fi
    _tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/${PROBE_TMP_PREFIX}conn.XXXXXX" 2>/dev/null) || return 1
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
    _port="$1"; _force="${2:-0}"
    # 每轮开头刷新一次单调读数（一次 fork），本轮其余判定点复用。
    mono_tick            # 本轮刷新一次（不包 $( )，否则全局缓存出不来）
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
                    # 刚失去这个端口：下一轮立刻深扫一次再下结论。
                    # 否则要等第 10 轮全扫，而用户此刻多半已经换到表外的端口上了。
                    NEED_DEEP_SCAN=1
                    CURRENT_STATE="off"
                    return 0
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
        NEED_DEEP_SCAN=1
        return 0
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
