# ==============================================================================
#  prompt-sync.sh — 让"已经开着的终端窗口"跟着代理状态走，且随时能让使用者接管
#  由 shell 启动时加载一次（rc 里那一行）；它自己再去注册"每次提示符前重读"的钩子。
#
#  为什么需要它：环境变量只在进程启动那一刻从父进程复制，已经开着的窗口拿不到新值。
#  唯一可靠的时机是"每次回到提示符、准备执行下一条命令之前"。
#
#  DIVERGE(Mac): 机制与 Windows 侧必然不同，三处：
#    1) 挂载点——本侧用官方钩子（zsh 的 precmd、bash 的 PROMPT_COMMAND），
#       在 rc 文件里 source 本脚本即可；Win 侧要改写 $PROFILE 并包住 prompt 函数
#       （PowerShell 没有等价的官方钩子）。
#    2) 状态来源——本侧读 ~/.envproxy/proxy.env 与 owned.env 两个文件；
#       Win 侧每次实时查注册表（HKCU\Environment 与 Software\EnvProxy\Owned）。
#    3) 落点数量——本侧写 4 个 rc（.zshenv/.zshrc/存在的 .bash_profile/.bashrc）；
#       Win 写 5.1 与 7 两个版本的 profile。
#    共同点（行为契约，两侧必须一致）：只对安装之后新启动的 shell 生效；只清"值仍等于
#    我们写下的那个"；钩子永不输出、永不返回非零。
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
#     9 次就够让人感觉到每次回车都卡（实测差 100 倍以上）。
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
    # 权威来源是 owned.env（monitor 在 on 态写下的那份）：每行「变量名 TAB 我们写的值」。
    # 不从 proxy.env 的 export 行反推——那样要处理双引号/单引号/空值三种形态，
    # 而 off 态时 proxy.env 里根本没有 export 行（已经是哨兵），一条都解析不出来。
    _envproxy_clear_ours() {
        _ep_home="$(_envproxy_home)"
        # 当前文件若是 off 哨兵，就先执行它——它自带"值仍等于我们写的才清"的守卫，
        # 是 monitor 的正式清除路径。这一步不能无条件做：on 态文件会把使用者自己的
        # 值覆盖成我们的，然后再"清掉我们的"，等于把他的设置抹了（实测就是这样丢的）。
        # 判据只看首行的状态标记，不执行 on 态文件。
        _ep_state=""
        if [ -r "$_ep_home/proxy.env" ]; then
            IFS= read -r _ep_head < "$_ep_home/proxy.env" 2>/dev/null || _ep_head=""
            case "$_ep_head" in
                '# envproxy-state: off'*)
                    _ep_state=off
                    . "$_ep_home/proxy.env"
                    ;;
            esac
        fi
        _ep_f="$_ep_home/owned.env"
        [ -r "$_ep_f" ] || { unset _ep_home _ep_f _ep_state _ep_head 2>/dev/null || true; return 0; }
        _ep_line=""
        while IFS= read -r _ep_line; do
            case "$_ep_line" in
                *"	"*)
                    _ep_name="${_ep_line%%	*}"
                    _ep_want="${_ep_line#*	}"
                    # 变量名必须先过白名单再进 eval：这是唯一一处把文件内容拼进命令的地方。
                    # 不做校验的话，owned.env 被写坏（或被人恶意改写）就能执行任意命令——
                    # 实测变量名写成 x[$(touch /tmp/x)] 会真的执行。
                    # 更常见的后果是静默失效：名字带空格会让 eval 报错、本轮 while 中断，
                    # 后面的变量一条都不处理，用户以为固定直连了却还挂着代理。
                    case "$_ep_name" in
                        ''|*[!A-Za-z0-9_]*) continue ;;
                    esac
                    case "$_ep_name" in
                        [0-9]*) continue ;;
                    esac
                    # 值可能被单引号包裹（NO_PROXY 那种合并值走 shell_escape_sq）
                    case "$_ep_want" in
                        \'*\') _ep_want="${_ep_want#\'}"; _ep_want="${_ep_want%\'}" ;;
                        \"*\") _ep_want="${_ep_want#\"}"; _ep_want="${_ep_want%\"}" ;;
                    esac
                    eval "_ep_cur=\"\${$_ep_name-}\""
                    # 只认"仍然等于我们写下的那个"。空值也走这条路：留一个 VAR="" 的
                    # 空变量同样是残留（proxy_vars_present 不认为它是脏的，会永久留着）。
                    if [ "$_ep_cur" = "$_ep_want" ]; then
                        unset "$_ep_name" 2>/dev/null || true
                    fi
                    ;;
            esac
        done < "$_ep_f"
        unset _ep_home _ep_f _ep_state _ep_head _ep_line _ep_name _ep_want _ep_cur 2>/dev/null || true
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
        # 路径只算一次：$( ) 每次都是一个 fork，同一行写两次就是两个。
        # 这条在每次回车时执行，能少一个就少一个（本文件 _envproxy_clear_ours 早就这么做了）。
        _ep_p="$(_envproxy_home)/proxy.env"
        [ -r "$_ep_p" ] && . "$_ep_p"
        unset _ep_p 2>/dev/null || true
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
            # 先剔除同名项再追加，rc 被 source 多次时不会叠成多份——否则每次回车
            # 会把同一件事跑好几遍。遍历剔除而不用 ${arr[@]:#pat}，那个写法只有
            # zsh 支持，bash 3.2 会在展开时报错。
            _ep_keep=()
            for _ep_fn in ${precmd_functions[@]}; do
                [ "$_ep_fn" = "_envproxy_prompt_sync" ] || _ep_keep+=("$_ep_fn")
            done
            precmd_functions=(${_ep_keep[@]} _envproxy_prompt_sync) 2>/dev/null || true
            unset _ep_keep _ep_fn
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
