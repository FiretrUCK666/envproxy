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

# 安装时快照原值（只记一次）：卸载时按快照还原，用户原来的配置不丢。
# 快照时属于我们自己的值视为空（升级路径下安装时代理正开着，不能把刚写的值当成用户的）。
snapshot_prev_env() {
    [ -f "$PREV_ENV" ] && return 0
    mkdir -p "$ENVPROXY_HOME" 2>/dev/null || true
    _sntmp="$PREV_ENV.tmp.$$"
    {
        for _v in HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy; do
            _cur=$(launchctl getenv "$_v" 2>/dev/null || echo "")
            is_owned_proxy_value "$_cur" 2>/dev/null && _cur=""
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
        [ "$_cur" = "1" ] && _cur=""
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
    # proxy.env 整个文件是我们的，直接删；launchctl 那一路要按项回收——
    # 代理变量只删本机地址（归属判定），用户或公司工具写的其他地址不动；
    # NO_PROXY 用"减掉我们加的默认项"的方式回收（用户原本就有 NO_PROXY 时，
    # 按"整份等于默认集"判断会让我们加的那几项永远留在他的值里）；
    # NODE_USE_ENV_PROXY 只有值是我们写的 1 才清。
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
    rm -f "$PROXY_ENV" 2>/dev/null || true
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
    if [ -f "$PROXY_ENV" ] && grep -qE '^export (HTTP_PROXY|http_proxy)=' "$PROXY_ENV" 2>/dev/null; then return 0; fi
    for _v in HTTP_PROXY http_proxy; do
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
