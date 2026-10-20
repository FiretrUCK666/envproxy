# ------------------------------------------------------------------------------
#  probe.sh — 探测层：端口发现、CONNECT 握手、真实节点连通、当前状态判定
#  判决三层缺一不可；只做快筛的表不影响覆盖面。
# ------------------------------------------------------------------------------

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
#      现有 7 个端点：5 个 /generate_204（0 字节 204）+ 2 个被墙站点（重定向或 KB 级响应）。
# 新增端点必须同时满足这两条，否则"每次不足 1KB"的流量口径立刻失真。
CHECK_HOSTS="clients3.google.com connectivitycheck.gstatic.com www.gstatic.com youtubei.googleapis.com www.google.com www.wikipedia.org twitter.com"
CHECK_PATHS="/generate_204 /generate_204 /generate_204 /generate_204 /generate_204 / /"

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
    _bdir=$(mktemp -d /tmp/envproxy_found.XXXXXX 2>/dev/null) || return 1
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
    printf '%s' "$_glp_out" | awk '/LISTEN/ {print $4}' | sed 's/.*\.//' | grep -E '^[0-9]+$' | sort -nu
    return 0
}

# 可疑进程端口表（排序去重，无状态，可安全用于命令替换）。
# 解析只用一次 awk：pid→comm 映射与监听行匹配在同一次扫描里完成，
# 不再对每一行各起 awk/grep/head（原来每行 6–7 个进程，空转时最费电的就是它）。
get_suspect_ports() {
    _psmap=$(mktemp /tmp/envproxy_ps.XXXXXX 2>/dev/null) || return 0
    _lsofout=$(mktemp /tmp/envproxy_lsof.XXXXXX 2>/dev/null) || { rm -f "$_psmap" 2>/dev/null || true; return 0; }
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
# get_active_proxy_port（取第一个）。
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
        curl --disable -s -D - -o /dev/null --head --connect-timeout 5 --max-time 6 -x "http://127.0.0.1:$_port" "http://$_host$_path" 2>/dev/null)
    [ -n "$_out" ] || return 1
    printf '%s' "$_out" | grep -qi "Connection Established" && return 1
    _first=$(printf '%s' "$_out" | head -n 1)
    _code=$(printf '%s' "$_first" | grep -oE ' [0-9]{3} ' | tr -cd '0-9')
    case "$_code" in
        # 与 Windows 侧同一口径：只认"正常响应"——200 / 204（连通性检查端点）与 3xx 重定向。
        # 不把 2xx 全收进来：其它 2xx 语义不明，宁可判"断"——错判"通"会把终端流量送进坏节点，
        # 错判"断"只是不注入（终端走直连），两个代价不对称。
        200|204|30[0-9]) return 0;;
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
    _tmpdir=$(mktemp -d /tmp/envproxy_conn.XXXXXX 2>/dev/null) || return 1
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
# 节流缓存只认"同一端口"（单槽位：bash 3.2 无关联数组）。
# 同端口节流内直接给缓存结论；换端口一律重验——多候选试活时不会读到别的端口的旧结论。
# DIVERGE(Mac): Win 侧用哈希表按端口分槽（LastCheck / Alive / FailCount 各一份，见 Test-NodeAlive），
# Mac 侧单槽；失败计数随之也是全局的，差异与代价写在计数更新那一处（test_node_alive 内）。
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
    # DIVERGE(Mac): 计数只有一个槽（Windows 侧按端口分槽）。macOS 自带的 bash 是 3.2，
    # 没有关联数组，分槽要么退化成一串手工变量、要么引入外部命令；而代价只在
    # "同时有多个候选端口交替出现"时体现（计数会被不同端口的结果共同推进，
    # 可能提前一次失败判"断"，最多早约 15 秒）。单代理与换端口这两条主路径不受影响。
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
        _cands=$(find_candidate_ports 1)
        _rc=$?
        if [ $_rc -ne 0 ]; then
            # 端口枚举失败：这一轮不知道。不判 off——判 off 会删掉用户的代理变量，
            # 而真实情况可能只是这一次没读到。返回非 0，交给主循环"沿用上一状态"。
            log_msg "端口枚举失败 -> 本轮沿用上一状态，不动环境变量"
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
    if [ $((ROUND % 10)) -eq 0 ]; then _full=1; else _full=0; fi
    _cands=$(find_candidate_ports "$_full")
    _rc=$?
    if [ $_rc -ne 0 ]; then
        # 端口枚举失败：这一轮不知道。不判 off（理由同上）。
        log_msg "端口枚举失败 -> 本轮沿用上一状态，不动环境变量"
        return 1
    fi
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
