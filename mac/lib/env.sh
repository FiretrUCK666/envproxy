# ------------------------------------------------------------------------------
#  env.sh — 环境变量层：终端路 proxy.env 与 GUI 路 launchctl 的写入、删除、归属、还原
#  双路同进同退；只回收本工具写下的本机地址。
# ------------------------------------------------------------------------------
PROXY_ENV="$ENVPROXY_HOME/proxy.env"
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
    printf '%s' "$_line" | grep -oE ':[0-9]+' | tr -d ':' | head -n 1
}

set_user_env_vars() {
    # DIVERGE(Mac): 写 9 个变量——5 个规范拼写再加 4 个小写拼写。macOS 的变量名真大小写敏感，
    #   有的工具只认小写；Windows 的命名空间大小写不敏感，写小写只会互相覆盖，所以那边只写 5 个。
    # DIVERGE(Mac): 双路写入——终端读 ~/.envproxy/proxy.env（由 shell hook 加载），
    #   Dock 启动的 App 读 launchctl setenv；Windows 侧是注册表 + 全系统广播。
    _port="$1"
    _http="http://127.0.0.1:$_port"
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
    # 端口从**现有文件**里读：它就是我们上一次写下的值，也就是"守卫要认的那个值"。
    _op=$(sed -n 's/^export HTTP_PROXY="http:\/\/127\.0\.0\.1:\([0-9][0-9]*\)"$/\1/p' "$PROXY_ENV" 2>/dev/null | head -n 1)
    _tmp="$PROXY_ENV.tmp.$$"
    {
        printf '# envproxy-state: off\n'
        if [ -n "$_op" ]; then
            _oh="http://127.0.0.1:$_op"
            # 一律写成 ${VAR-}：使用者可能开着 set -u / setopt nounset，
            # 裸写 $VAR 在变量未定义时会直接报 "unbound variable"，
            # 而这段是在他们的 shell 提示符里执行的——报错会打断他们的输入。
            for _v in HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy; do
                printf '[ "${%s-}" = "%s" ] && unset %s\n' "$_v" "$_oh" "$_v"
            done
            # NO_PROXY / no_proxy 是我们与使用者条目合并出来的，不按整值认领（会误删他的条目），
            # 只在它正好等于"默认项 + 我们那几项"时才清；判不了就不清，宁可留着让下次 on 覆盖。
            _onp=$(sed -n 's/^export NO_PROXY=//p' "$PROXY_ENV" 2>/dev/null | head -n 1)
            if [ -n "$_onp" ]; then
                printf '[ "${NO_PROXY-}" = %s ] && unset NO_PROXY\n' "$_onp"
                printf '[ "${no_proxy-}" = %s ] && unset no_proxy\n' "$_onp"
            fi
            printf '[ "${NODE_USE_ENV_PROXY-}" = "1" ] && unset NODE_USE_ENV_PROXY\n'
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
    _http="http://127.0.0.1:$_port"
    _np=$(merge_no_proxy "$(get_existing_no_proxy)" "$DEFAULT_NO_PROXY")
    _npq=$(shell_escape_sq "$_np")
    for _v in HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy; do
        grep -qxF "export $_v=\"$_http\"" "$PROXY_ENV" 2>/dev/null || return 1
    done
    grep -qxF "export NO_PROXY=$_npq" "$PROXY_ENV" 2>/dev/null || return 1
    grep -qxF "export no_proxy=$_npq" "$PROXY_ENV" 2>/dev/null || return 1
    grep -qxF 'export NODE_USE_ENV_PROXY="1"' "$PROXY_ENV" 2>/dev/null || return 1
    # launchd 的会话环境是易失的（每次登录/重启清空），而 proxy.env 一直存在——只比对它就等于
    # 认为"第二路也齐了"，重启后那 9 个 setenv 一次都不会重放。两条腿都要核：任一条不符就判"不齐"，
    # 交给 sync_user_env_vars 整体重写（apply_state、安装、自愈因此共用同一个判据）。
    if command -v launchctl >/dev/null 2>&1; then
        [ "$(launchctl getenv HTTP_PROXY 2>/dev/null)" = "$_http" ] || return 1
        [ "$(launchctl getenv HTTPS_PROXY 2>/dev/null)" = "$_http" ] || return 1
        [ "$(launchctl getenv ALL_PROXY 2>/dev/null)" = "$_http" ] || return 1
        [ "$(launchctl getenv NO_PROXY 2>/dev/null)" = "$_np" ] || return 1
        [ "$(launchctl getenv NODE_USE_ENV_PROXY 2>/dev/null)" = "1" ] || return 1
        # 小写拼写也是我们写下的那一份：只核 5 个大写变量，等于放任 4 个小写变量漂移，
        # 而"齐了"的判定一旦撒谎，自愈就永远不修（macOS 大小写敏感，少一个就是真的少）。
        [ "$(launchctl getenv http_proxy 2>/dev/null)" = "$_http" ] || return 1
        [ "$(launchctl getenv https_proxy 2>/dev/null)" = "$_http" ] || return 1
        [ "$(launchctl getenv all_proxy 2>/dev/null)" = "$_http" ] || return 1
        [ "$(launchctl getenv no_proxy 2>/dev/null)" = "$_np" ] || return 1
    fi
    return 0
}

# 幂等同步：不齐就补齐，齐了则什么都不做、零写入。
sync_user_env_vars() {
    _port="$1"
    env_vars_in_sync "$_port" && return 0
    set_user_env_vars "$_port"
    return 0
}

# 快照时这个值要不要当成"我们写的"跳过（纯函数，不碰任何状态，可单测）。
# 用法：snapshot_skip_value 变量名 变量值 是否首次安装（1 = 是）
# "像我们写的"不够——还要机器上本来就有本工具的安装记录，才可能是我们留下的。
# 首次安装时机器上还没有我们的任何东西：此刻本机地址的代理变量、
# 以及 NODE_USE_ENV_PROXY=1，都是使用者自己的配置。把它们当我们的跳过，
# 卸载时会被删掉又无从还原——用了几年的手设配置就这么凭空没了。
snapshot_skip_value() {
    [ -n "$2" ] || return 1
    [ "$3" = "1" ] && return 1
    case "$1" in
        NODE_USE_ENV_PROXY) [ "$2" = "1" ] && return 0 ;;
        HTTP_PROXY|http_proxy|HTTPS_PROXY|https_proxy|ALL_PROXY|all_proxy)
            case "$2" in http://127.0.0.1:*) return 0 ;; esac ;;
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
        for _v in HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy; do
            _cur=$(launchctl getenv "$_v" 2>/dev/null || echo "")
            snapshot_skip_value "$_v" "$_cur" "$_sn_first" && _cur=""
            case "$_cur" in *"
"*) _cur="";; esac
            printf '%s\t%s\n' "$_v" "$_cur"
        done
        for _v in NO_PROXY no_proxy; do
            _cur=$(launchctl getenv "$_v" 2>/dev/null || echo "")
            case "$_cur" in *"
"*) _cur="";; esac
            printf '%s\t%s\n' "$_v" "$_cur"
        done
        _cur=$(launchctl getenv NODE_USE_ENV_PROXY 2>/dev/null || echo "")
        snapshot_skip_value NODE_USE_ENV_PROXY "$_cur" "$_sn_first" && _cur=""
        printf '%s\t%s\n' "NODE_USE_ENV_PROXY" "$_cur"
    } > "$_sntmp" 2>/dev/null && mv "$_sntmp" "$PREV_ENV" 2>/dev/null || rm -f "$_sntmp" 2>/dev/null || true
    # 快照里是用户**原来**的代理地址，可能带账号密码（http://user:pass@host:port）。
    # 默认权限（同 umask，通常 0644）是同机其他用户都能读——凭据就这么漏出去了。
    # 收紧到 0600：只有自己能读。
    [ -f "$PREV_ENV" ] && chmod 600 "$PREV_ENV" 2>/dev/null || true
    return 0
}

# 卸载时按快照还原用户原值，还原完删掉快照。无快照时什么都不做。
restore_prev_env() {
    [ -f "$PREV_ENV" ] || return 0
    while IFS='	' read -r _k _v; do
        [ -n "$_k" ] || continue
        if [ -n "$_v" ]; then launchctl setenv "$_k" "$_v" 2>/dev/null || true
        else launchctl unsetenv "$_k" 2>/dev/null || true; fi
    done < "$PREV_ENV" 2>/dev/null || true
    rm -f "$PREV_ENV" 2>/dev/null || true
    return 0
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
    _ours_default="$(printf '%s' "$DEFAULT_NO_PROXY" | tr -d ' ' | tr 'A-Z' 'a-z')"
    for _v in no_proxy NO_PROXY; do
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
            # 快照里本来就有的条目是使用者的，哪怕它正好等于默认项也不许减。
            if no_proxy_entry_in_snapshot "$_pt"; then _keep="${_keep:+$_keep,}$_pt"; continue; fi
            if is_default_no_proxy_entry "$_pt"; then continue; fi
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
    for _v in HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy; do
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
    for _v in HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy; do
        _cur=$(launchctl getenv "$_v" 2>/dev/null || echo "")
        if is_owned_proxy_value "$_cur"; then return 0; fi
    done
    for _v in NO_PROXY no_proxy; do
        _cur=$(launchctl getenv "$_v" 2>/dev/null || echo "")
        [ -n "$_cur" ] || continue
        _old=$IFS; IFS=','
        # 同 remove_user_env_vars：条目不关 glob，*.corp 会被展开成文件名，判据就失真了。
        _had_f=0; case $- in *f*) _had_f=1;; esac
        set -f
        for _p in $_cur; do
            _pt=$(printf '%s' "$_p" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            [ -n "$_pt" ] || continue
            # 与 remove_user_env_vars 同口径：快照里本来就有的条目不算我们的痕迹。
            if no_proxy_entry_in_snapshot "$_pt"; then continue; fi
            if is_default_no_proxy_entry "$_pt"; then
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
    if [ "$_state" = "off" ]; then
        if proxy_vars_present; then
            # sentinel：留一份守卫式 unset 给已开着的终端，敲回车就能把旧变量清掉。
            remove_user_env_vars sentinel
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
