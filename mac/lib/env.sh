# ------------------------------------------------------------------------------
#  env.sh — 环境变量层：终端路 proxy.env 与 GUI 路 launchctl 的写入、删除、归属、还原
#  双路同进同退；只回收本工具写下的本机地址。
# ------------------------------------------------------------------------------
PROXY_ENV="$ENVPROXY_HOME/proxy.env"
# 我们写下的那套值（变量名 TAB 值），只由 on 态写入，**永远不会被 off 哨兵覆盖**。
# 为什么单独存：off 哨兵要写成"值仍等于我们写下的那个才清"，而那个值不能从 proxy.env 里
# 反推——哨兵本身已经把 export 行替换掉了。从被覆盖的文件里反推，第二次进 off 就再也
# 推不出守卫值，已开着的窗口从此清不掉（实测会退化成只有 # off + true 的空哨兵）。
OWNED_ENV="$ENVPROXY_HOME/owned.env"
PREV_ENV="$ENVPROXY_HOME/prev.env"

# 读已存在的 NO_PROXY（终端路取自 proxy.env，GUI 路取自 launchctl）。
# 带参数则读指定变量名，不带则读大写那份，供合并用。
get_existing_no_proxy() {
    _name="${1:-NO_PROXY}"
    _v=""
    if [ -f "$PROXY_ENV" ]; then
        _v=$(grep -E "^export ${_name}=" "$PROXY_ENV" 2>/dev/null | head -n 1 | sed 's/^export [A-Za-z_]*=//; s/^"//; s/"$//' | sed "s/^'//; s/'\$//")
    fi
    if [ -z "$_v" ]; then _v=$(launchctl getenv "$_name" 2>/dev/null || echo ""); fi
    printf '%s' "$_v"
}

get_current_proxy_port() {
    [ -f "$PROXY_ENV" ] || return 1
    _line=$(grep -E '^export HTTP_PROXY=' "$PROXY_ENV" 2>/dev/null | head -n 1)
    [ -n "$_line" ] || return 1
    # 取**最后**一段端口，不能取第一个匹配：注入值可能是 http://[::1]:7078，
    # 而 ':[0-9]+' 会先命中 "::1" 里的 ":1"，于是返回 1。
    # 调用方把结果拼成 http://127.0.0.1:<端口>，就会显示 "已注入 (127.0.0.1:1)"——
    # 对只绑 ::1 的代理，那是一条看起来正常、实则完全错的结论。
    printf '%s' "$_line" | sed -nE 's/.*:([0-9]+)"?$/\1/p' | head -n 1
}

set_user_env_vars() {
    # DIVERGE(Mac): 写 9 个变量——5 个规范拼写再加 4 个小写拼写。macOS 的变量名真大小写敏感，
    #   有的工具只认小写；Windows 的命名空间大小写不敏感，写小写只会互相覆盖，所以那边只写 5 个。
    # DIVERGE(Mac): 双路写入——终端读 ~/.envproxy/proxy.env（由 shell hook 加载），
    #   Dock 启动的 App 读 launchctl setenv；Windows 侧是注册表 + 全系统广播。
    _port="$1"
    # 地址现场探测：只绑 ::1 的代理在 IPv4 上连不上，写死 127.0.0.1 会注入一个用不了的地址——
    # 终端里每条命令 ECONNREFUSED，而状态页显示"已注入、正常"，比检测不到更糟。
    proxy_url_for_port "$_port"
    _http="$PROXY_URL_HIT"
    _np=$(merge_no_proxy "$(get_existing_no_proxy)" "$DEFAULT_NO_PROXY")
    _npq=$(shell_escape_sq "$_np")
    mkdir -p "$ENVPROXY_HOME" 2>/dev/null || true
    _tmp="$PROXY_ENV.tmp.$$"
    {
        # 状态标记行：hook 侧据此区分 on/off，不必自己猜。
        # 放第一行，且用 # 注释——即使被当成普通 shell 源码执行也无害。
        printf '# envproxy-state: on %s\n' "$_port"
        printf 'export HTTP_PROXY="%s"\n' "$_http"
        printf 'export http_proxy="%s"\n' "$_http"
        printf 'export HTTPS_PROXY="%s"\n' "$_http"
        printf 'export https_proxy="%s"\n' "$_http"
        printf 'export ALL_PROXY="%s"\n' "$_http"
        printf 'export all_proxy="%s"\n' "$_http"
        printf 'export NO_PROXY=%s\n' "$_npq"
        printf 'export no_proxy=%s\n' "$_npq"
        printf 'export NODE_USE_ENV_PROXY="1"\n'
    } > "$_tmp" 2>/dev/null && mv "$_tmp" "$PROXY_ENV" 2>/dev/null || rm -f "$_tmp" 2>/dev/null || true
    # 把"我们写下的值"另存一份：off 哨兵要据此写守卫，而 proxy.env 那时已经被替换成哨兵了。
    # 这份文件与 on 态同生，永不参与 on/off 切换——它记的是"我们拥有哪些值"，不是"当前状态"。
    # 必须把**整张变量表**都记下来：少记一个，那个变量在 off/固定直连时就永远清不掉，
    # 用户会看到"以为直连了、curl 还在走代理"。名单从 PROXY_VAR_NAMES 遍历，不手写。
    _otmp="$OWNED_ENV.tmp.$$"
    {
        for _v in $PROXY_VAR_NAMES; do
            case "$_v" in
                NO_PROXY|no_proxy) printf '%s\t%s\n' "$_v" "$_npq" ;;
                NODE_USE_ENV_PROXY) printf '%s\t%s\n' "$_v" "1" ;;
                *) printf '%s\t%s\n' "$_v" "$_http" ;;
            esac
        done
    } > "$_otmp" 2>/dev/null && mv "$_otmp" "$OWNED_ENV" 2>/dev/null || rm -f "$_otmp" 2>/dev/null || true
    # 与上面写 owned.env 用**同一张表、同一套取值规则**：手抄一份的话，新增变量时
    # 上面那个循环会自动跟上、下面这份不会，于是 owned.env 里有记录、launchctl 里没值，
    # 而归属判定认为"这是我们的"、同步检查认为"不齐"，两个结论互相矛盾。
    for _v in $PROXY_VAR_NAMES; do
        case "$_v" in
            NO_PROXY|no_proxy) launchctl setenv "$_v" "$_np" 2>/dev/null || true ;;
            NODE_USE_ENV_PROXY) launchctl setenv "$_v" "1" 2>/dev/null || true ;;
            *) launchctl setenv "$_v" "$_http" 2>/dev/null || true ;;
        esac
    done
    # 写没写成由**复读**决定，不由"我执行了 mv"决定。
    # 上面每一处 `|| true` 都是必要的容错（launchctl 在无 GUI 会话里必然失败，
    # 而终端路才是主路），但它们把"两个文件一个都没写出来"这种真故障也一起吞了。
    # 复读判据只问一件事：终端路的两份文件（当前值 + 归属记录）在不在、有没有内容。
    # 这是真正会让人连不上网的那条路；launchctl 那条缺失只影响 Dock 启动的 App，
    # 由状态页的终端同步那项单独体现，不在这里混为一谈。
    [ -s "$PROXY_ENV" ] && [ -s "$OWNED_ENV" ]
}

# off 态也写这个文件，内容不是"删除"而是"带着归属守卫的 unset"。
# 目的：已经开着的终端窗口，敲回车时由 shell hook 重新 source 一遍，就能把旧变量清掉。
# （文件被删掉的话 hook 里的 [ -r ] 直接短路，旧值会一直挂在那儿——那正是"必须重开窗口"的根因。）
#
# 守卫的判据：**只有当前值仍然等于我们上次写下的那个，才清**。
#   [ "$HTTPS_PROXY" = "http://127.0.0.1:7078" ] && unset HTTPS_PROXY
# 于是这三种情况都不会误伤使用者自己的设置：
#   - 他自己本来就 export 了公司代理（值不是我们的地址）
#   - 他装上之后又手动改成本地 mitmproxy（地址像本机但不是我们写的那个端口）
#   - 他从没让我们写过（文件里没有可解析的端口，整段退化成 no-op）
# 判断权全在 monitor 侧（它有完整的归属判据与快照），hook 侧只"照做"，不猜。
write_off_sentinel() {
    mkdir -p "$ENVPROXY_HOME" 2>/dev/null || true
    # 守卫值来自 owned.env（on 态写下的那份），**不从 proxy.env 反推**：
    # 第二次进 off 时 proxy.env 已经是哨兵、没有 export 行，反推必然为空，
    # 守卫段就会整段消失，已开着的窗口从此再也清不掉。
    # 兼容旧安装：早期版本没有 owned.env，退回到从 proxy.env 里读一次。
    _oh=""
    if [ -f "$OWNED_ENV" ]; then
        _oh=$(awk -F'\t' '$1 == "HTTP_PROXY" { print $2; exit }' "$OWNED_ENV" 2>/dev/null)
    fi
    if [ -z "$_oh" ]; then
        # 整条 URL 取回来（含地址），不再只取端口再拼 127.0.0.1：注入值可能是
        # http://[::1]:port，只认 IPv4 那种写法会让这份兼容路径对它失效。
        # 用 -E（ERE）而不是 BRE 里的 \|：\| 是 GNU 扩展，macOS 自带的 BSD sed
        # 在 BRE 里把它当普通字符 |，这条兼容路径会静默失效——而它服务的正是
        # "从早期版本升级上来、没有 owned.env"的用户，失效后果是 off 哨兵写不出
        # 守卫值、已开着的窗口永远清不掉旧变量。
        _op=$(sed -nE 's/^export HTTP_PROXY="(http:\/\/(127\.0\.0\.1|\[::1\]):[0-9]+)"$/\1/p' "$PROXY_ENV" 2>/dev/null | head -n 1)
        [ -n "$_op" ] && _oh="$_op"
    fi
    _onp=""
    _onode=""
    if [ -f "$OWNED_ENV" ]; then
        _onp=$(awk -F'\t' '$1 == "NO_PROXY" { print $2; exit }' "$OWNED_ENV" 2>/dev/null)
        # NODE_USE_ENV_PROXY 的归属值同样只来自 owned.env：没有记录就不清。
        _onode=$(awk -F'\t' '$1 == "NODE_USE_ENV_PROXY" { print $2; exit }' "$OWNED_ENV" 2>/dev/null)
    fi
    if [ -z "$_onp" ]; then
        _onp=$(sed -n 's/^export NO_PROXY=//p' "$PROXY_ENV" 2>/dev/null | head -n 1)
    fi
    _tmp="$PROXY_ENV.tmp.$$"
    {
        printf '# envproxy-state: off\n'
        # NODE_USE_ENV_PROXY 的值是我们写下的 "1"，判据也是"值仍等于我们写下的那个"，
        # 不是"永远清"：它必须与其它变量共用同一套归属守卫。
        # 写在守卫外面时，没有 owned.env 的机器上（早期版本升级上来的、
        # 或从没装过时）会把使用者自己设的 1 删掉——违反"没有归属记录时一个都不动"。
        if [ -n "$_onode" ]; then
            printf '[ "${NODE_USE_ENV_PROXY-}" = "%s" ] && unset NODE_USE_ENV_PROXY\n' "$_onode"
        fi
        if [ -n "$_oh" ]; then
            # 一律写成 ${VAR-}：使用者可能开着 set -u / setopt nounset，
            # 裸写 $VAR 在变量未定义时会直接报 "unbound variable"，
            # 而这段是在他们的 shell 提示符里执行的——报错会打断他们的输入。
            for _v in $PROXY_ADDR_VAR_NAMES; do
                printf '[ "${%s-}" = "%s" ] && unset %s\n' "$_v" "$_oh" "$_v"
            done
            # NO_PROXY / no_proxy 是我们与使用者条目合并出来的，不按整值认领（会误删他的条目），
            # 只在它正好等于"默认项 + 我们那几项"时才清；判不了就不清，宁可留着让下次 on 覆盖。
            if [ -n "$_onp" ]; then
                printf '[ "${NO_PROXY-}" = %s ] && unset NO_PROXY\n' "$_onp"
                printf '[ "${no_proxy-}" = %s ] && unset no_proxy\n' "$_onp"
            fi
        fi
        # 末行恒真：source 这个文件必须返回 0。zsh 的 hook 里一旦返回非零，
        # 后面的 precmd 钩子（主题、补全等）会全部不执行。
        printf 'true\n'
    } > "$_tmp" 2>/dev/null && mv "$_tmp" "$PROXY_ENV" 2>/dev/null || rm -f "$_tmp" 2>/dev/null || true
}

# 整套变量是否都已就位（幂等判据不看单项）：只看代理地址会让"地址对、别的变量漂移"的
# 半代理状态永远无人纠正。返回 0 = 已就位（无需动手）。
env_vars_in_sync() {
    _port="$1"
    [ -f "$PROXY_ENV" ] || return 1
    # 与写入端同源：判"已就位"用的地址必须就是当初写下去的那个。
    proxy_url_for_port "$_port"
    _http="$PROXY_URL_HIT"
    _np=$(merge_no_proxy "$(get_existing_no_proxy)" "$DEFAULT_NO_PROXY")
    _npq=$(shell_escape_sq "$_np")
    for _v in $PROXY_ADDR_VAR_NAMES; do
        grep -qxF "export $_v=\"$_http\"" "$PROXY_ENV" 2>/dev/null || return 1
    done
    # 剩下的几个变量也逐项核，列表从同一张变量表来：
    # 手抄的话，新增变量时前面那个循环会跟上、这里不会，于是"齐不齐"的判据永远漏一个。
    for _v in $PROXY_VAR_NAMES; do
        case "$_v" in
            NO_PROXY|no_proxy) grep -qxF "export $_v=$_npq" "$PROXY_ENV" 2>/dev/null || return 1 ;;
            NODE_USE_ENV_PROXY) grep -qxF "export $_v=\"1\"" "$PROXY_ENV" 2>/dev/null || return 1 ;;
            HTTP_PROXY|http_proxy|HTTPS_PROXY|https_proxy|ALL_PROXY|all_proxy) continue ;;
            *) return 1 ;;
        esac
    done
    # launchd 的会话环境是易失的（每次登录/重启清空），而 proxy.env 一直存在——只比对它就等于
    # 认为"第二路也齐了"，重启后那 9 个 setenv 一次都不会重放。两条腿都要核：任一条不符就判"不齐"，
    # 调用方据此决定要不要 set_user_env_vars 整体重写——apply_state、安装、自愈
    # 三处都读这一个判据，所以"齐不齐"只有一种答案。
    if command -v launchctl >/dev/null 2>&1; then
        # 逐个核，列表与取值规则同写入端（同一张 PROXY_VAR_NAMES、同一套 case 分派）：
        # 小写拼写也是我们写下的那一份，少核一个就是真的漏（macOS 大小写敏感）。
        for _v in $PROXY_VAR_NAMES; do
            case "$_v" in
                NO_PROXY|no_proxy) _want="$_np" ;;
                NODE_USE_ENV_PROXY) _want="1" ;;
                *) _want="$_http" ;;
            esac
            [ "$(launchctl getenv "$_v" 2>/dev/null)" = "$_want" ] || return 1
        done
    fi
    # 第三条腿：owned.env 记着"我们写下的值"，终端同步与 off 哨兵全靠它判归属。
    # 它丢了就等于归属判据消失——ENVPROXY_TERM=off 会静默失效、off 哨兵写不出守卫。
    # 而它不在这个判据里的话，sync 会以为"齐了"直接返回，永远不重建（30 轮自愈也修不了，
    # 因为自愈走的正是这个函数）。所以必须把它当成"齐不齐"的一部分。
    if [ ! -f "$OWNED_ENV" ]; then return 1; fi
    # 整张表都要在：少记一个变量，它就在 off/固定直连时永远清不掉。
    # 列表从同一张表来，不手抄——手抄的那份在加变量时会静默漏掉。
    for _v in $PROXY_VAR_NAMES; do
        grep -q "^$_v	" "$OWNED_ENV" 2>/dev/null || return 1
    done
    return 0
}

# 幂等同步：不齐就补齐，齐了则什么都不做、零写入。
# 快照时这个值要不要当成"我们写的"跳过（纯函数，不碰任何状态，可单测）。
# 用法：snapshot_skip_value 变量名 变量值 是否首次安装（1 = 是）
# "像我们写的"不够——还要机器上本来就有本工具的安装记录，才可能是我们留下的。
# 首次安装时机器上还没有我们的任何东西：此刻本机地址的代理变量、
# 以及 NODE_USE_ENV_PROXY=1，都是使用者自己的配置。把它们当我们的跳过，
# 卸载时会被删掉又无从还原——用了几年的手设配置就这么凭空没了。
snapshot_skip_value() {
    [ -n "$2" ] || return 1
    # 归属记录里逐字记着这个值 = 这就是我们自己写下的，永远不是使用者的原值。
    # 这一条必须排在"首次安装"之前，因为它比那个推断更硬：
    # 首次安装的推断前提是"机器上还没有我们的东西"，而**卸载没清干净时那个前提不成立**——
    # 残留的本机地址代理值会在下一次全新安装时被当成使用者的、存进快照、再按快照还原，
    # 于是永远清不掉。Windows 侧实测踩过（ALL_PROXY 与 NODE_USE_ENV_PROXY 活过了两次卸载），
    # 这边是同一套机制，同一个洞。
    # 与 Windows 侧 Test-IsOurOwnedValue 同判据：查 owned.env，不是查快照。
    # 查快照会问错问题——那问的是"使用者的地盘里有没有这个名字"，拿它判归属
    # 会把使用者的公司代理也判成我们的，那样他就永久丢了自己的配置。
    _ssv_owned=$(awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$OWNED_ENV" 2>/dev/null)
    if [ -n "$_ssv_owned" ]; then
        [ "$_ssv_owned" = "$2" ] && return 0
    fi
    [ "$3" = "1" ] && return 1
    case "$1" in
        NODE_USE_ENV_PROXY) [ "$2" = "1" ] && return 0 ;;
        HTTP_PROXY|http_proxy|HTTPS_PROXY|https_proxy|ALL_PROXY|all_proxy)
            case "$2" in http://127.0.0.1:*|http://\[::1\]:*) return 0 ;; esac ;;
    esac
    return 1
}

# 安装时快照原值（只记一次）：卸载时按快照还原，用户原来的配置不丢。
# 重装/升级时代理正开着，我们上次写下的值不能当成使用者的（见 snapshot_skip_value）。
snapshot_prev_env() {
    _sn_first="${1:-0}"
    [ -f "$PREV_ENV" ] && return 0
    mkdir -p "$ENVPROXY_HOME" 2>/dev/null || true
    _sntmp="$PREV_ENV.tmp.$$"
    {
        for _v in $PROXY_ADDR_VAR_NAMES; do
            _cur=$(launchctl getenv "$_v" 2>/dev/null || echo "")
            snapshot_skip_value "$_v" "$_cur" "$_sn_first" && _cur=""
            case "$_cur" in *"
"*) _cur="";; esac
            printf '%s\t%s\n' "$_v" "$_cur"
        done
        for _v in $NO_PROXY_VAR_NAMES; do
            _cur=$(launchctl getenv "$_v" 2>/dev/null || echo "")
            case "$_cur" in *"
"*) _cur="";; esac
            printf '%s\t%s\n' "$_v" "$_cur"
        done
        _cur=$(launchctl getenv NODE_USE_ENV_PROXY 2>/dev/null || echo "")
        snapshot_skip_value NODE_USE_ENV_PROXY "$_cur" "$_sn_first" && _cur=""
        printf '%s\t%s\n' "NODE_USE_ENV_PROXY" "$_cur"
    } > "$_sntmp" 2>/dev/null
    # 成败由**复读**决定，不由"我执行过 mv"决定：原来那条链 `... && mv || rm -f || true`
    # 会让 mv 失败也以 0 退出，于是调用方以为记下了、实际什么都没记。
    # 这份快照是其它所有归属判据的输入，记不下来的后果是卸载时还原不回用户的原值。
    _sn_ok=1
    if [ -s "$_sntmp" ] && mv "$_sntmp" "$PREV_ENV" 2>/dev/null && [ -f "$PREV_ENV" ]; then
        _sn_ok=0
    fi
    rm -f "$_sntmp" 2>/dev/null || true
    # 快照里是用户**原来**的代理地址，可能带账号密码（http://user:pass@host:port）。
    # 默认权限（同 umask，通常 0644）是同机其他用户都能读——凭据就这么漏出去了。
    # 收紧到 0600：只有自己能读。
    [ -f "$PREV_ENV" ] && chmod 600 "$PREV_ENV" 2>/dev/null || true
    return "$_sn_ok"
}

# 卸载时按快照还原用户原值，还原完删掉快照。无快照时什么都不做。
restore_prev_env() {
    [ -f "$PREV_ENV" ] || return 0
    while IFS='	' read -r _k _v; do
        [ -n "$_k" ] || continue
        # 快照里这一条如果就是"我们写下过的那个值"，它从来不是使用者的原值——
        # 不能还原回去。老版本的快照确实可能存着这种条目（首次安装时把本机地址的
        # 代理值也一起存了），还原它等于把我们的东西当成他的配置装回去：
        # 卸载报"已恢复原状"，而值一直留着。
        # 这条判断在还原侧做，所以**已经存在的坏快照也会被自愈**，不用等用户重装。
        _rpe_owned=$(awk -F'	' -v k="$_k" '$1 == k { print $2; exit }' "$OWNED_ENV" 2>/dev/null)
        if [ -n "$_rpe_owned" ] && [ "$_rpe_owned" = "$_v" ]; then continue; fi
        if [ -n "$_v" ]; then launchctl setenv "$_k" "$_v" 2>/dev/null || true
        else launchctl unsetenv "$_k" 2>/dev/null || true; fi
    done < "$PREV_ENV" 2>/dev/null || true
    rm -f "$PREV_ENV" 2>/dev/null || true
    return 0
}

# 把 NO_PROXY 的一个条目归类，两个调用方必须走这同一个判据：
#   0 = 我们加的默认项（该摘掉）
#   1 = 快照里本来就有的（使用者的，原样留）
#   2 = 其余（使用者的，原样留）
# 为什么必须共用：回收变量（remove_user_env_vars）与判断"该不该清理"
# （proxy_vars_present）如果各写一遍，判据一旦有一份不同，就会出现
# "状态页说直连、实际还挂着代理"的半代理——正是这个项目最怕的状态。
# 顺序也是判据的一部分：快照优先于默认集，使用者原有的条目哪怕正好等于
# 默认项也不许摘。
classify_no_proxy_entry() {
    if no_proxy_entry_in_snapshot "$1"; then return 1; fi
    if is_default_no_proxy_entry "$1"; then return 0; fi
    return 2
}
remove_user_env_vars() {
    # 只回收**本工具自己写下的**东西。
    #
    # 参数 $1 = "sentinel" 时，proxy.env 不删而是改写成"守卫式 unset"（见 write_off_sentinel）：
    #   已开着的终端敲回车时由 shell hook 重新 source，旧变量才清得掉。
    #   这是"代理关掉"的正常路径——留一个文件不是留残留，它里面没有 export，判据不会认成"还在翻墙"。
    # 省略参数（或传别的值）= 真删文件：卸载、自退、自检这些场景要的是"干干净净不留东西"。
    #
    # launchctl 那一路要按项回收——代理变量只删本机地址（归属判定），用户或公司工具写的其他地址不动；
    # NO_PROXY 用"减掉我们加的默认项"的方式回收（用户原本就有 NO_PROXY 时，
    # 按"整份等于默认集"判断会让我们加的那几项永远留在他的值里）；
    # NODE_USE_ENV_PROXY 只有值是我们写的 1 才清。
    _rmv_mode="${1:-purge}"
    # 安装时的原值快照另存（见 snapshot_prev_env），卸载时由 restore_prev_env 还原。
    for _v in $NO_PROXY_VAR_NAMES; do
        _cur=$(launchctl getenv "$_v" 2>/dev/null || echo "")
        [ -n "$_cur" ] || continue
        _keep=""
        _old=$IFS; IFS=','
        # 关掉通配：条目里可能合法地写着 *.corp，不关会被展开成当前目录的文件名。
        _had_f=0; case $- in *f*) _had_f=1;; esac
        set -f
        for _p in $_cur; do
            _pt=$(printf '%s' "$_p" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            [ -n "$_pt" ] || continue
            # 分类交给共用判据：快照里本来就有的、以及我们没加过的条目都原样留。
            classify_no_proxy_entry "$_pt"; _cn=$?
            [ "$_cn" -eq 0 ] && continue
            _keep="${_keep:+$_keep,}$_pt"
        done
        IFS=$_old
        [ "$_had_f" -eq 1 ] || set +f
        if [ -n "$_keep" ]; then launchctl setenv "$_v" "$_keep" 2>/dev/null || true
        else launchctl unsetenv "$_v" 2>/dev/null || true; fi
    done
    _node=$(launchctl getenv NODE_USE_ENV_PROXY 2>/dev/null || echo "")
    if [ "$_node" = "1" ]; then launchctl unsetenv NODE_USE_ENV_PROXY 2>/dev/null || true; fi
    # 文件这一步必须放在"读完 launchctl"之后：write_off_sentinel 要读旧文件里的端口当守卫值，
    # 而它会把文件整个改写掉。先改后读就只剩空文件、守卫值丢了。
    if [ "$_rmv_mode" = "sentinel" ]; then
        write_off_sentinel
    else
        rm -f "$PROXY_ENV" 2>/dev/null || true
    fi
    for _v in $PROXY_ADDR_VAR_NAMES; do
        _cur=$(launchctl getenv "$_v" 2>/dev/null || echo "")
        [ -n "$_cur" ] || continue
        is_owned_proxy_value "$_cur" || continue
        launchctl unsetenv "$_v" 2>/dev/null || true
    done
}

# 我们该持有的那套变量现在还有没有痕迹：proxy.env 与 launchctl 任一路在就算在。
# 与 remove_user_env_vars 的回收范围对齐——两边共用一套判据，才不会出现
# "删得掉但门槛没让它删"的残留（半代理：状态显示直连，实际还挂着代理）。
# 归属与删除同口径：别人的代理地址不算我们的痕迹。
proxy_vars_present() {
    # 判据是"文件里有 export 行"，不是"文件在"：off 态会留一份守卫式 unset 的文件给已开着的终端，
    # 它没有 export、不代表还在翻墙。按"文件在"判会把自己写的哨兵当成残留，永远清不掉。
    if [ -f "$PROXY_ENV" ] && grep -qE '^export (HTTP_PROXY|http_proxy)=' "$PROXY_ENV" 2>/dev/null; then return 0; fi
    # 必须与 remove_user_env_vars 回收同一批变量（6 个代理变量），不是只看 HTTP_PROXY：
    # 只判两个的话，一旦只剩 HTTPS_PROXY/ALL_PROXY 这类残留，判据说"没痕迹"→ 不清理 →
    # 状态页报"直连"而实际还挂着代理，正是要防的那种半代理。
    for _v in $PROXY_ADDR_VAR_NAMES; do
        _cur=$(launchctl getenv "$_v" 2>/dev/null || echo "")
        if is_owned_proxy_value "$_cur"; then return 0; fi
    done
    for _v in $NO_PROXY_VAR_NAMES; do
        _cur=$(launchctl getenv "$_v" 2>/dev/null || echo "")
        [ -n "$_cur" ] || continue
        _old=$IFS; IFS=','
        # 同 remove_user_env_vars：条目不关 glob，*.corp 会被展开成文件名，判据就失真了。
        _had_f=0; case $- in *f*) _had_f=1;; esac
        set -f
        for _p in $_cur; do
            _pt=$(printf '%s' "$_p" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            [ -n "$_pt" ] || continue
            # 与 remove_user_env_vars 同一个分类判据：只有我们自己加的项才算痕迹。
            classify_no_proxy_entry "$_pt"; _cn=$?
            if [ "$_cn" -eq 0 ]; then
                IFS=$_old; [ "$_had_f" -eq 1 ] || set +f
                return 0
            fi
        done
        IFS=$_old
        [ "$_had_f" -eq 1 ] || set +f
    done
    if [ "$(launchctl getenv NODE_USE_ENV_PROXY 2>/dev/null || echo "")" = "1" ]; then return 0; fi
    return 1
}

# 幂等：整套变量都已就位就什么都不做（只看单项会让"地址对、别的漂移"的半代理状态无人纠正）
apply_state() {
    # "unknown" = 这一轮不知道（端口枚举失败），不是"不在翻墙"。绝不能拿它写变量。
    case "${1:-}" in
        ""|unknown) return 0 ;;
    esac
    _state="$1"
    # 状态串只有两种合法形状：off，或 on:<1..65535>。
    # 畸形的一律不写、也不报成功——"什么都没做却报成功"是最难查的一种故障：
    # 屏幕上一切正常，只有终端连不上网。Windows 侧同一判据（Invoke-EnvStateWrite）。
    case "$_state" in
        off) : ;;
        on:*)
            _pv_port="${_state#on:}"
            case "$_pv_port" in
                ''|*[!0-9]*) return 1 ;;
            esac
            [ "$_pv_port" -ge 1 ] && [ "$_pv_port" -le 65535 ] || return 1
            ;;
        *) return 1 ;;
    esac
    if [ "$_state" = "off" ]; then
        if proxy_vars_present; then
            # sentinel：留一份守卫式 unset 给已开着的终端，敲回车就能把旧变量清掉。
            remove_user_env_vars sentinel
            log_msg "代理已关闭 -> 已删除代理变量，恢复直连"
        fi
    else
        _port=$(printf '%s' "$_state" | sed 's/^on://')
        if ! env_vars_in_sync "$_port"; then
            if set_user_env_vars "$_port"; then
                log_msg "检测到本地代理端口 $_port -> 已注入代理 $_http"
            else
                # 写失败必须如实记，不能记"已注入"。
                # 原来这里无条件记成功：磁盘满、~/.envproxy 不可写、被安全软件挡住时，
                # 黑匣子里每 60–90 秒刷一条"已注入代理"的假消息，把 200 行历史冲干净，
                # 而屏幕上（安装第 3 步）是一句绿色的"已按当前状态校正"。
                log_msg "检测到本地代理端口 $_port -> 环境变量写入失败（见下一条）"
                return 1
            fi
        fi
    fi
    return 0
}
