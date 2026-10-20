# ==============================================================================
#  prompt-sync.sh — 让"已经开着的终端窗口"跟着代理状态走，且随时能让使用者接管
#  由 shell 启动时加载一次（rc 里那一行）；它自己再去注册"每次提示符前重读"的钩子。
#
#  为什么需要它：环境变量只在进程启动那一刻从父进程复制，已经开着的窗口拿不到新值。
#  唯一可靠的时机是"每次回到提示符、准备执行下一条命令之前"。
#
#  ------------------------------------------------------------------------------
#  三条设计原则（决定了它不会和使用者打架）
#  ------------------------------------------------------------------------------
#  1) 只动"我们自己写下的那一个值"。
#     只有当前值仍等于 proxy.env 里记的值，才允许清除；覆盖前也先看这一条。
#     于是使用者自己设的公司代理、本地 mitmproxy、socks5 地址一律不碰——
#     判据是"值相等"，不是"长得像本机地址"（后者会把他自己的 127.0.0.1:8080 误认成我们的）。
#
#  2) 使用者随时可以接管，命令只有两条（不用记参数）：
#       export ENVPROXY_TERM=off     这个终端固定直连（翻墙开着也不注入）
#       unset  ENVPROXY_TERM         恢复自动跟随
#     想固定走别的代理就直接 export，我们会把它当"使用者的值"，永不覆盖、永不清除。
#
#  3) 热路径不启动任何外部进程。
#     只用 shell 内建（case / [ / read / export / unset），实测单次约 0.3 毫秒。
#     不用 launchctl getenv、不用 sed/grep——那些每次要 fork 一个进程，
#     8 次就够让人感觉到每次回车都卡（实测差 100 倍以上）。
#
#  钩子里一旦报错，后面所有钩子都不执行（连使用者的主题提示符都会崩），
#  所以本文件：永不输出、永不返回非零、所有外部不确定性都吞掉。
# ==============================================================================

if [ -z "${_ENVPROXY_SYNC_READY-}" ]; then
    _ENVPROXY_SYNC_READY=1

    # 数据来源：与 rc 里那一行的口径保持一致（ENVPROXY_HOME 可被运行期改道，自检用）。
    # 每个函数自己算，不依赖模块级变量——本文件在子 shell 里被重新 source 时
    # 哨兵会挡住模块级赋值，函数却还活着，靠模块级变量就会读不到（set -u 下直接报错）。
    _envproxy_home() {
        printf '%s' "${ENVPROXY_HOME:-$HOME/.envproxy}"
    }

    # 只清"我们写下的那些值"。判据是确切相等，不是形状相似。
    # 记录来源：proxy.env 里 on 态那几行 export（monitor 写的就是我们要认的值）。
    _envproxy_clear_ours() {
        _ep_f="$(_envproxy_home)/proxy.env"
        [ -r "$_ep_f" ] || return 0
        _ep_line=""
        while IFS= read -r _ep_line; do
            case "$_ep_line" in
                'export '*=*)
                    _ep_name="${_ep_line#export }"; _ep_name="${_ep_name%%=*}"
                    _ep_want="${_ep_line#*=}"
                    # 去掉两侧的双引号（monitor 写的是 export X="Y"）
                    case "$_ep_want" in
                        \"*\") _ep_want="${_ep_want#\"}"; _ep_want="${_ep_want%\"}" ;;
                    esac
                    eval "_ep_cur=\"\${$_ep_name-}\""
                    if [ -n "$_ep_want" ] && [ "$_ep_cur" = "$_ep_want" ]; then
                        unset "$_ep_name"
                    fi
                    ;;
            esac
        done < "$_ep_f"
        unset _ep_f _ep_line _ep_name _ep_want _ep_cur 2>/dev/null || true
        return 0
    }

    # --------------------------------------------------------------------------
    #  同步一次：把状态文件应用到当前 shell
    #  proxy.env 由 monitor 原子写入，两种形态：
    #    on  : "# envproxy-state: on <端口>" + 9 行 export
    #    off : "# envproxy-state: off" + 守卫式 unset（"值仍等于我们写的才清"）
    #  本函数不判断"该不该翻墙"，只执行文件说的——判断权全在 monitor。
    # --------------------------------------------------------------------------
    _envproxy_apply() {
        # 使用者要求这个终端固定直连：先把我们设的清掉，再什么都不注入。
        if [ "${ENVPROXY_TERM-}" = "off" ]; then
            _envproxy_clear_ours
            return 0
        fi
        [ -r "$(_envproxy_home)/proxy.env" ] && . "$(_envproxy_home)/proxy.env"
        return 0
    }

    # ---- zsh ----
    # 用官方 add-zsh-hook（与 Oh My Zsh / Starship 同一个 precmd_functions 数组，互不覆盖）。
    # 不直接改数组：Powerlevel10k 会主动重排 precmd_functions，自己插进去会被它挪走。
    if [ -n "${ZSH_VERSION-}" ]; then
        _envproxy_prompt_sync() {
            emulate -L zsh 2>/dev/null
            _envproxy_apply
            return 0
        }
        if command -v add-zsh-hook >/dev/null 2>&1; then
            add-zsh-hook precmd _envproxy_prompt_sync 2>/dev/null || true
        else
            # 极老的 zsh 没有 add-zsh-hook：退回手写数组，不覆盖别人已有的项。
            precmd_functions=(${precmd_functions[@]} _envproxy_prompt_sync) 2>/dev/null || true
        fi

    # ---- bash ----
    # 两个注意点：
    #   1) macOS 自带 bash 3.2 不支持数组形式的 PROMPT_COMMAND，只能用分号串；
    #   2) bash 会用它覆盖上一个命令的 $?，必须自己存起来再还回去。
    elif [ -n "${BASH_VERSION-}" ]; then
        _envproxy_prompt_sync() {
            local _ep_prev=$?
            _envproxy_apply
            return $_ep_prev
        }
        case "${PROMPT_COMMAND-};" in
            *_envproxy_prompt_sync*) ;;
            *) PROMPT_COMMAND="_envproxy_prompt_sync${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
        esac
        export PROMPT_COMMAND 2>/dev/null || true
    fi

    # 启动时先同步一次：新开的终端立刻拿到当前状态，不用等第一次回车。
    _envproxy_apply
fi
