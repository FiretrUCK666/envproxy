# ------------------------------------------------------------------------------
#  ops.sh — 动作层：菜单背后的安装、停止、卸载、状态编排，以及自检沙箱
#  把下面各层拼成使用者点得到的行为。
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# 自检回归：沙箱里跑，断言 hook 成对护栏、合并语义、归属判定与注入回收往返。
# 只碰沙箱 HOME 与沙箱 ENVPROXY_HOME，不碰真实用户文件。CI 门禁调用，失败返回非零。
# ------------------------------------------------------------------------------
_selftest_fails=0

_selftest_assert_eq() {
    _name="$1"; _want="$2"; _have="$3"
    if [ "$_want" = "$_have" ]; then
        echo "  PASS $_name"
    else
        echo "  FAIL $_name（期望 [$_want]，实际 [$_have]）"
        _selftest_fails=$((_selftest_fails + 1))
    fi
}

_selftest_assert_file_eq() {
    _name="$1"; _want="$2"; _file="$3"
    _have=$(cat "$_file" 2>/dev/null || echo "__MISSING__")
    if [ "$_want" = "$_have" ]; then
        echo "  PASS $_name"
    else
        echo "  FAIL $_name（文件内容不符，实际：）"
        printf '%s\n' "$_have" | sed 's/^/    |/'
        _selftest_fails=$((_selftest_fails + 1))
    fi
}

# 断言一段文字里含有某个片段（用于提示文案必须包含关键动作）。
# 比"整串相等"更适合文案：文案会变，但"必须提到手动下载"这件事不能变。
_selftest_assert_contains() {
    _name="$1"; _needle="$2"; _hay="$3"
    case "$_hay" in
        *"$_needle"*)
            echo "  PASS $_name"
            ;;
        *)
            echo "  FAIL $_name（应包含 [$_needle]，实际：）"
            printf '%s\n' "$_hay" | sed 's/^/    |/'
            _selftest_fails=$((_selftest_fails + 1))
            ;;
    esac
}

# 自检为什么住在 ops 库里（而不是像 Windows 那样放 tests\）:
#   Windows 侧的自检在 tests\test-win-pure.ps1，Mac 侧没有对应的独立文件——
#   两侧布局不同是既有现状，不是遗漏。真要搬走，得同时改 CORE_LIBS、门禁 10 的调用步骤
#   和安装包范围，三处一起动；收益只是"文件更干净"，风险大于收益，所以保持现状。
# 注意下面的 launchctl() 桩件是**函数内定义**，只在本函数执行期间生效，
# 不会污染生产路径——不要在别处加同名的函数。
# 加载代价实测可忽略：7 个库全部点源共 40ms（shell 只解析函数定义，不执行函数体）。

self_test() {
    _selftest_fails=0
    _sandbox=$(mktemp -d /tmp/envproxy_selftest.XXXXXX 2>/dev/null) || { echo "自检失败：沙箱建不起"; return 1; }
    # 运行期改道：HOME 管 hook 落点，ENVPROXY_HOME 管 proxy.env/快照，MONITOR_DIR 管日志。
    HOME="$_sandbox"
    ENVPROXY_HOME="$_sandbox/.envproxy"
    PROXY_ENV="$ENVPROXY_HOME/proxy.env"
    PREV_ENV="$ENVPROXY_HOME/prev.env"
    # owned.env 必须一并改道：它记的是"我们写下的值"，真实路径在 ~/.envproxy。
    # 漏了这一个，自检里的 set_user_env_vars 会往使用者的真实目录写字。
    OWNED_ENV="$ENVPROXY_HOME/owned.env"
    MONITOR_DIR="$ENVPROXY_HOME/monitor"
    LOG_FILE="$MONITOR_DIR/monitor.log"
    export HOME ENVPROXY_HOME
    mkdir -p "$ENVPROXY_HOME" "$MONITOR_DIR" 2>/dev/null || true
    # launchctl 必须桩掉：HOME / ENVPROXY_HOME 只能改道文件，管不到 launchctl——
    # 它是系统级的，`launchctl setenv` 写的是当前登录会话的真实环境。
    # 下面 [3] 段会跑 set_user_env_vars / remove_user_env_vars，若不桩掉，
    # 使用者敲一次 `envproxy.sh self-test` 就会把自己的公司代理变量清空且不还原。
    # 桩成"只记不写"：自检仍然验证调用顺序与参数，但一个字节都不落到真实环境。
    # getenv 要模拟"已经写进去了"：否则自检里 set 之后立刻 get 拿到空串，
    # env_vars_in_sync 会判"不齐"，断言失败——那是桩的假象，不是代码的错。
    _selftest_launchctl_log="$ENVPROXY_HOME/launchctl.log"
    _selftest_launchctl_env="$ENVPROXY_HOME/launchctl.env"
    : > "$_selftest_launchctl_env" 2>/dev/null || true
    launchctl() {
        case "${1:-}" in
            setenv)
                # 同一个名字后写的覆盖先写的（与真实 launchctl 一致）
                if [ -f "$_selftest_launchctl_env" ]; then
                    grep -v "^${2}	" "$_selftest_launchctl_env" > "$_selftest_launchctl_env.t" 2>/dev/null || true
                    mv "$_selftest_launchctl_env.t" "$_selftest_launchctl_env" 2>/dev/null || true
                fi
                printf '%s\t%s\n' "${2:-}" "${3:-}" >> "$_selftest_launchctl_env" 2>/dev/null || true
                printf 'setenv %s\n' "${2:-}" >> "$_selftest_launchctl_log" 2>/dev/null || true
                ;;
            unsetenv)
                if [ -f "$_selftest_launchctl_env" ]; then
                    grep -v "^${2}	" "$_selftest_launchctl_env" > "$_selftest_launchctl_env.t" 2>/dev/null || true
                    mv "$_selftest_launchctl_env.t" "$_selftest_launchctl_env" 2>/dev/null || true
                fi
                printf 'unsetenv %s\n' "${2:-}" >> "$_selftest_launchctl_log" 2>/dev/null || true
                ;;
            getenv)
                awk -F'\t' -v k="${2:-}" '$1 == k { print $2; exit }' "$_selftest_launchctl_env" 2>/dev/null || true
                ;;
            *) return 0 ;;
        esac
        return 0
    }

    echo "[1] hook 成对护栏"
    printf '%s\n' 'export PATH=/x' '# >>> EnvProxy >>>' 'OLD-HOOK' '# <<< EnvProxy <<<' 'alias ll="ls"' > "$HOME/.zshenv"
    _normalize_hook_block "$HOME/.zshenv" || true
    _selftest_assert_file_eq "旧块被清理、用户行保留" "$(printf '%s\n' 'export PATH=/x' 'alias ll="ls"')" "$HOME/.zshenv"

    printf '%s\n' 'export PATH=/x' '# >>> EnvProxy >>>' 'HOOK' 'alias ll="ls"' > "$HOME/.zshenv"
    _before=$(cat "$HOME/.zshenv" 2>/dev/null)
    _normalize_hook_block "$HOME/.zshenv" || true
    _selftest_assert_eq "缺结束行时一个字节都不改" "$_before" "$(cat "$HOME/.zshenv" 2>/dev/null)"

    printf '%s\n' 'export PATH=/x' '# >>> EnvProxy >>>' 'HOOK' '# <<< EnvProxy <<< ' 'alias ll="ls"' > "$HOME/.zshenv"
    _before=$(cat "$HOME/.zshenv" 2>/dev/null)
    remove_shell_hooks 2>/dev/null || true
    _selftest_assert_eq "结束行尾随空格时不截断" "$_before" "$(cat "$HOME/.zshenv" 2>/dev/null)"

    printf '%s\n' 'export PATH=/x' '# >>> EnvProxy >>>' "$HOOK_LINE" '# <<< EnvProxy <<<' 'alias ll="ls"' > "$HOME/.zshenv"
    remove_shell_hooks 2>/dev/null || true
    _selftest_assert_file_eq "成对时正常移除" "$(printf '%s\n' 'export PATH=/x' 'alias ll="ls"')" "$HOME/.zshenv"

    echo "[1c] 终端同步：不碰使用者的设置，且随时能接管"
    # prompt-sync.sh 是使用者 shell 去 source 的独立脚本（不进 CORE_LIBS、不被入口加载）。
    # 路径当场算出来：子 shell 里不会因为变量没导出而丢掉。
    _ps_file=$(cd "$SCRIPT_DIR" 2>/dev/null && pwd)/prompt-sync.sh
    [ -r "$_ps_file" ] || _ps_file="$SCRIPT_DIR/prompt-sync.sh"
    if [ -r "$_ps_file" ]; then
        _ps_env="$ENVPROXY_HOME/proxy.env"
        _ps_owned="$ENVPROXY_HOME/owned.env"
        _ps_bak=""
        [ -f "$_ps_env" ] && _ps_bak="$_ps_bak $(cat "$_ps_env" 2>/dev/null)" || true
        # owned.env 记着"我们写下的值"，接管开关与 off 哨兵都靠它。
        # 内容必须由**真实写入端**生成，不能手写：手写的话，写入端漏记某个变量
        # 这件事永远不会被这些断言发现（测试造的比生产多，绿得毫无意义）。
        # 真实链路：set_user_env_vars 写 on 态 + owned.env，这里把它跑一遍。
        _ps_saved_env_path="$PROXY_ENV"; _ps_saved_owned_path="$OWNED_ENV"
        PROXY_ENV="$_ps_env"; OWNED_ENV="$_ps_owned"
        set_user_env_vars 7078 >/dev/null 2>&1 || true
        PROXY_ENV="$_ps_saved_env_path"; OWNED_ENV="$_ps_saved_owned_path"
        # 断言"owned.env 覆盖了整张变量表"——漏一个就等于那个变量永远清不掉。
        _ps_owned_missing=""
        for _ps_v in $PROXY_VAR_NAMES; do
            grep -q "^$_ps_v	" "$_ps_owned" 2>/dev/null || _ps_owned_missing="$_ps_owned_missing $_ps_v"
        done
        _selftest_assert_eq "owned.env 覆盖整张变量表（漏一个就清不掉）" "" "$_ps_owned_missing"
        # on 态文件
        printf '%s\n' '# envproxy-state: on 7078' \
            'export HTTP_PROXY="http://127.0.0.1:7078"' \
            'export HTTPS_PROXY="http://127.0.0.1:7078"' \
            'export NO_PROXY="localhost,127.0.0.1,::1"' \
            'export NODE_USE_ENV_PROXY="1"' > "$_ps_env"
        # 1) 正常注入
        _ps_r=$( unset HTTP_PROXY HTTPS_PROXY NO_PROXY NODE_USE_ENV_PROXY ENVPROXY_TERM _ENVPROXY_SYNC_READY
                 . "$_ps_file"
                 printf '%s' "${HTTPS_PROXY-}" )
        _selftest_assert_eq "同步：代理开着时注入" "http://127.0.0.1:7078" "$_ps_r"
        # 2) 使用者自己的代理：off 态时一字不动（判据是值相等，不是长得像本机地址）
        printf '%s\n' '# envproxy-state: off' \
            '[ "${HTTPS_PROXY-}" = "http://127.0.0.1:7078" ] && unset HTTPS_PROXY' 'true' > "$_ps_env"
        _ps_r=$( export HTTPS_PROXY="http://corp-proxy:8080"
                 unset ENVPROXY_TERM _ENVPROXY_SYNC_READY
                 . "$_ps_file"
                 printf '%s' "${HTTPS_PROXY-}" )
        _selftest_assert_eq "同步：off 态不碰使用者的公司代理" "http://corp-proxy:8080" "$_ps_r"
        # 3) 他本机上自己的 mitmproxy 也不算我们的
        _ps_r=$( export HTTPS_PROXY="http://127.0.0.1:8080"
                 unset ENVPROXY_TERM _ENVPROXY_SYNC_READY
                 . "$_ps_file"
                 printf '%s' "${HTTPS_PROXY-}" )
        _selftest_assert_eq "同步：off 态不碰使用者的本机 8080" "http://127.0.0.1:8080" "$_ps_r"
        # 3b) on 态：按契约覆盖（安装时已快照原值、卸载还原，这是功能本身）
        printf '%s\n' '# envproxy-state: on 7078' \
            'export HTTPS_PROXY="http://127.0.0.1:7078"' > "$_ps_env"
        _ps_r=$( export HTTPS_PROXY="http://corp-proxy:8080"
                 unset ENVPROXY_TERM _ENVPROXY_SYNC_READY
                 . "$_ps_file"
                 printf '%s' "${HTTPS_PROXY-}" )
        _selftest_assert_eq "同步：on 态按快照契约覆盖（卸载会还原）" "http://127.0.0.1:7078" "$_ps_r"
        # 4) ENVPROXY_TERM=off：这个终端固定直连，不清使用者的值
        _ps_r=$( export ENVPROXY_TERM=off
                 export HTTPS_PROXY="http://corp-proxy:8080"
                 unset _ENVPROXY_SYNC_READY
                 . "$_ps_file"
                 printf '%s' "${HTTPS_PROXY-}" )
        _selftest_assert_eq "接管开关：固定直连时不清使用者的值" "http://corp-proxy:8080" "$_ps_r"
        # 5) ENVPROXY_TERM=off 且值是我们的：清干净
        _ps_r=$( export ENVPROXY_TERM=off
                 export HTTPS_PROXY="http://127.0.0.1:7078"
                 unset _ENVPROXY_SYNC_READY
                 . "$_ps_file"
                 printf '%s' "${HTTPS_PROXY-}" )
        _selftest_assert_eq "接管开关：固定直连时清掉我们的值" "" "$_ps_r"
        # 6) off 态哨兵：只清我们写下的那个值
        printf '%s\n' '# envproxy-state: off' \
            '[ "${HTTPS_PROXY-}" = "http://127.0.0.1:7078" ] && unset HTTPS_PROXY' 'true' > "$_ps_env"
        _ps_r=$( export HTTPS_PROXY="http://127.0.0.1:8080"
                 unset ENVPROXY_TERM _ENVPROXY_SYNC_READY
                 . "$_ps_file"
                 printf '%s' "${HTTPS_PROXY-}" )
        _selftest_assert_eq "off 哨兵：不误清使用者的 8080" "http://127.0.0.1:8080" "$_ps_r"
        # 7) off 态哨兵 + 值是我们的：清掉
        _ps_r=$( export HTTPS_PROXY="http://127.0.0.1:7078"
                 unset ENVPROXY_TERM _ENVPROXY_SYNC_READY
                 . "$_ps_file"
                 printf '%s' "${HTTPS_PROXY-}" )
        _selftest_assert_eq "off 哨兵：清掉我们写下的值" "" "$_ps_r"
        # 8) 哨兵让重复 source 不重复注册
        _ps_r=$( unset _ENVPROXY_SYNC_READY ENVPROXY_TERM PROMPT_COMMAND
                 . "$_ps_file"; _a="${PROMPT_COMMAND-}"
                 . "$_ps_file" 2>/dev/null || true
                 [ "${PROMPT_COMMAND-}" = "$_a" ] && printf same || printf doubled )
        _selftest_assert_eq "重复 source 不重复注册" "same" "$_ps_r"
        # 8b) zsh 兜底分支（没有 add-zsh-hook 的老 zsh）重复 source 也不能叠成多份。
        #     直接验证那段剔除逻辑本身：它只用数组展开与 [ ] 比较，bash 下跑得出同样结论。
        _ps_r=$( _f=_envproxy_prompt_sync
                 precmd_functions=(kept_other)
                 for _round in 1 2 3; do
                     _ep_keep=()
                     for _ep_fn in ${precmd_functions[@]}; do
                         [ "$_ep_fn" = "$_f" ] || _ep_keep+=("$_ep_fn")
                     done
                     precmd_functions=(${_ep_keep[@]} "$_f")
                 done
                 _n=0
                 for _ep_fn in "${precmd_functions[@]}"; do
                     [ "$_ep_fn" = "$_f" ] && _n=$((_n + 1))
                 done
                 printf '%s:%s' "$_n" "${precmd_functions[0]}" )
        _selftest_assert_eq "zsh 兜底分支重复 source 只注册一次" "1:kept_other" "$_ps_r"
        # 9) 钩子永不返回非零（返回非零会让使用者的主题提示符跟着崩）
        # 用固定路径传值，不用 $( )：命令替换会重置 $?，测的就不是钩子的行为了。
        _ps_tmp="$ENVPROXY_HOME/.selftest_rc"
        rm -f "$_ps_tmp" 2>/dev/null || true
        # 关键：false 与调用之间不能有任何语句——$? 会被它们重置。
        _ps_rc=""
        unset _ENVPROXY_SYNC_READY ENVPROXY_TERM 2>/dev/null || true
        . "$_ps_file" 2>/dev/null || true
        if type _envproxy_prompt_sync >/dev/null 2>&1; then
            false; _envproxy_prompt_sync; _ps_rc=$?
        else
            _ps_rc="NOFUNC"
        fi
        _selftest_assert_eq "钩子保住上一个命令的退出码" "1" "$_ps_rc"
        rm -f "$_ps_tmp" 2>/dev/null || true
        # 还原 proxy.env
        if [ -n "$_ps_bak" ]; then printf '%s\n' "$_ps_bak" | sed '/^$/d' > "$_ps_env"; else rm -f "$_ps_env"; fi
        # 固定位置副本：安装/自愈靠它把实现送到 ~/.envproxy，rc 里那一行只认这个路径。
        if install_prompt_sync; then _ps_cp1=1; else _ps_cp1=0; fi
        _selftest_assert_eq "固定位置副本已就位" "1" "$_ps_cp1"
        _selftest_assert_eq "副本与模板内容一致" "same" "$(cmp -s "$_ps_file" "$ENVPROXY_HOME/prompt-sync.sh" && echo same || echo diff)"
        # 幂等：再装一次不重写（内容相同就直接返回）。
        # mtime 的取法要能同时应付 BSD（macOS）与 GNU（Linux 容器）。
        # 不能用 ls -l --time-style（GNU 专有，macOS 上静默失败 → 断言退化成"空 == 空"）；
        # 也不能 stat -f %m（GNU stat 的 -f 是"显示文件系统"，它不报错、而是输出一大段
        # 文件系统信息后又失败返回非零，于是 || 不会走到后备分支，变量里是一堆废话）。
        # 所以先判断 stat 是哪一个：GNU 认 --version，BSD 不认。
        _mt_of() {
            if stat --version >/dev/null 2>&1; then
                stat -c %Y "$1" 2>/dev/null
            else
                stat -f %m "$1" 2>/dev/null
            fi
        }
        _ps_mt=$(_mt_of "$ENVPROXY_HOME/prompt-sync.sh")
        install_prompt_sync >/dev/null 2>&1 || true
        _ps_mt2=$(_mt_of "$ENVPROXY_HOME/prompt-sync.sh")
        # 先确认取到的是"一串数字"，否则这条断言是空转（两个空/两堆废话也能相等）。
        case "$_ps_mt" in
            ''|*[!0-9]*) _selftest_assert_eq "取得到副本的 mtime（断言不是空转）" "数字" "$_ps_mt" ;;
            *) _selftest_assert_eq "取得到副本的 mtime（断言不是空转）" "数字" "数字" ;;
        esac
        _selftest_assert_eq "内容一致时不重写副本" "$_ps_mt" "$_ps_mt2"
        # 模板变了要更新（模拟升级：改一个字节）
        printf '\n# changed\n' >> "$ENVPROXY_HOME/prompt-sync.sh"
        install_prompt_sync >/dev/null 2>&1 || true
        _selftest_assert_eq "内容不一致时更新副本" "same" "$(cmp -s "$_ps_file" "$ENVPROXY_HOME/prompt-sync.sh" && echo same || echo diff)"
        rm -f "$ENVPROXY_HOME/prompt-sync.sh" 2>/dev/null || true
        rm -f "$_ps_owned" 2>/dev/null || true
    else
        echo "  SKIP 终端同步（找不到 prompt-sync.sh）"
    fi

    echo "[2] 合并与归属"
    _selftest_assert_eq "补默认项、留用户条目" "localhost,127.0.0.1,::1,example.com" "$(merge_no_proxy 'localhost,example.com,::1' "$DEFAULT_NO_PROXY")"
    _selftest_assert_eq "含单引号条目丢弃" "localhost,127.0.0.1,::1,ok.example" "$(merge_no_proxy "ok.example,a'b" "$DEFAULT_NO_PROXY")"
    if is_owned_proxy_value "http://127.0.0.1:7890"; then _o1=1; else _o1=0; fi
    if is_owned_proxy_value "http://corp:8080"; then _o2=1; else _o2=0; fi
    _selftest_assert_eq "本机地址算我们的" "1" "$_o1"
    _selftest_assert_eq "公司地址不算我们的" "0" "$_o2"
    _selftest_assert_eq "转义幂等" "'a'" "$(shell_escape_sq 'a')"
    # 归属的第二层：安装快照（prev.env）里本来就记着的值，哪怕长得像我们的，也是使用者的。
    # 没有这一层，用户自己写的 NO_PROXY=localhost、或自挂的 mitmproxy 会在 off 态被定时删掉。
    _s1_bak=$(mktemp /tmp/envproxy_prev.XXXXXX 2>/dev/null) || _s1_bak=""
    if [ -n "$_s1_bak" ]; then
        _s1_old_prev="$PREV_ENV"
        PREV_ENV="$_s1_bak"
        # 必须按**真实格式**造快照：写入端是 snapshot_prev_env 的「变量名 TAB 值」，
        # 值用 shell_escape_sq 的结果（可能带单引号）。手搓成 "NAME='value'" 的写法会
        # 与真实格式不一致，于是解析端的格式错误被照成"全绿"——两道保护实际都没生效。
        { printf 'NO_PROXY\t%s\n' "'localhost'"; printf 'HTTP_PROXY\t%s\n' "'http://127.0.0.1:8080'"; } > "$PREV_ENV"
        if is_owned_proxy_value "http://127.0.0.1:8080"; then _s1a=1; else _s1a=0; fi
        if is_owned_proxy_value "http://127.0.0.1:7897"; then _s1b=1; else _s1b=0; fi
        if no_proxy_entry_in_snapshot "localhost"; then _s1c=1; else _s1c=0; fi
        if no_proxy_entry_in_snapshot "127.0.0.1"; then _s1d=1; else _s1d=0; fi
        # 不带单引号的裸值也要认（快照里 NO_PROXY 有可能没被转义）。
        { printf 'NO_PROXY\tlocalhost,corp.example\n'; } > "$PREV_ENV"
        if no_proxy_entry_in_snapshot "corp.example"; then _s1e=1; else _s1e=0; fi
        rm -f "$PREV_ENV" 2>/dev/null || true
        PREV_ENV="$_s1_old_prev"
        _selftest_assert_eq "快照里有的本机代理地址判为使用者的" "0" "$_s1a"
        _selftest_assert_eq "快照里没有的本机代理地址仍归我们回收" "1" "$_s1b"
        _selftest_assert_eq "快照里有的 NO_PROXY 项判为使用者的" "1" "$_s1c"
        _selftest_assert_eq "快照里没有的默认项仍归我们回收" "0" "$_s1d"
        _selftest_assert_eq "快照里裸写的 NO_PROXY 条目也认得" "1" "$_s1e"
    else
        echo "  SKIP 快照归属判定（建不出临时文件）"
    fi
    # compare_versions 结果走 stdout（exit 恒 0），直接取输出断言。
    _selftest_assert_eq "版本逐段数值比" "1" "$(compare_versions "1.0.10" "1.0.9")"

    echo "[3] 注入核对回收往返"
    set_user_env_vars "17890" || true
    if env_vars_in_sync "17890"; then _s1=1; else _s1=0; fi
    _selftest_assert_eq "注入后判就位" "1" "$_s1"
    if proxy_vars_present; then _s2=1; else _s2=0; fi
    _selftest_assert_eq "注入后判有痕迹" "1" "$_s2"
    # shellcheck disable=SC1090
    . "$PROXY_ENV" 2>/dev/null || true
    _selftest_assert_eq "proxy.env 可被 source" "http://127.0.0.1:17890" "$HTTP_PROXY"
    remove_user_env_vars || true
    if [ -f "$PROXY_ENV" ]; then _s3=1; else _s3=0; fi
    _selftest_assert_eq "回收后文件消失" "0" "$_s3"
    if proxy_vars_present; then _s4=1; else _s4=0; fi
    _selftest_assert_eq "回收后无痕迹" "0" "$_s4"
    unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy NODE_USE_ENV_PROXY 2>/dev/null || true

    echo "[4] 快照还原"
    snapshot_prev_env || true
    if [ -f "$PREV_ENV" ]; then _s5=1; else _s5=0; fi
    _selftest_assert_eq "快照文件生成" "1" "$_s5"
    restore_prev_env || true
    if [ -f "$PREV_ENV" ]; then _s6=1; else _s6=0; fi
    _selftest_assert_eq "还原后快照删除" "0" "$_s6"

    echo "[4b] 快照归属判定"
    # "像我们写的"不够——还要机器上本来就有本工具的安装记录，才可能是我们留下的。
    # 首次安装时把使用者的手设变量当成我们的跳过，卸载时会被删掉又无从还原。
    if snapshot_skip_value HTTP_PROXY 'http://127.0.0.1:7890' 1; then _sk1=1; else _sk1=0; fi
    _selftest_assert_eq "首次安装：本机地址要快照" "0" "$_sk1"
    if snapshot_skip_value NODE_USE_ENV_PROXY 1 1; then _sk2=1; else _sk2=0; fi
    _selftest_assert_eq "首次安装：NODE_USE_ENV_PROXY=1 要快照" "0" "$_sk2"
    if snapshot_skip_value https_proxy 'http://127.0.0.1:7890' 0; then _sk3=1; else _sk3=0; fi
    _selftest_assert_eq "重装：本机地址是我们上次写的，跳过" "1" "$_sk3"
    if snapshot_skip_value NODE_USE_ENV_PROXY 1 0; then _sk4=1; else _sk4=0; fi
    _selftest_assert_eq "重装：NODE_USE_ENV_PROXY=1 是我们写的，跳过" "1" "$_sk4"
    if snapshot_skip_value HTTP_PROXY 'http://10.0.0.1:8080' 0; then _sk5=1; else _sk5=0; fi
    _selftest_assert_eq "别人的代理地址从来不跳过" "0" "$_sk5"
    if snapshot_skip_value HTTP_PROXY '' 0; then _sk6=1; else _sk6=0; fi
    _selftest_assert_eq "空值不跳过" "0" "$_sk6"

    echo "[5] 源码包判据与清理"
    _fakeroot="$_sandbox/fakeroot"
    mkdir -p "$_fakeroot/.github" "$_fakeroot/tests" 2>/dev/null || true
    printf 'dev\n' > "$_fakeroot/AGENTS.md" 2>/dev/null || true
    printf 'mine\n' > "$_fakeroot/my-notes.txt" 2>/dev/null || true
    printf 't\n' > "$_fakeroot/tests/t.txt" 2>/dev/null || true
    printf '/AGENTS.md  export-ignore\n/.github/  export-ignore\n/tests/  export-ignore\n/.gitattributes  export-ignore\n' > "$_fakeroot/.gitattributes" 2>/dev/null || true
    if is_source_copy "$_fakeroot"; then _t1=1; else _t1=0; fi
    _selftest_assert_eq "有.github无.git判源码包" "1" "$_t1"
    mkdir -p "$_sandbox/fakegit/.git" 2>/dev/null || true
    if is_source_copy "$_sandbox/fakegit"; then _t2=1; else _t2=0; fi
    _selftest_assert_eq "有.git不判源码包" "0" "$_t2"
    if is_source_copy "$_sandbox"; then _t3=1; else _t3=0; fi
    _selftest_assert_eq "两者都没有不判源码包" "0" "$_t3"
    clean_source_files "$_fakeroot" || true
    if [ -e "$_fakeroot/.github" ] || [ -e "$_fakeroot/tests" ] || [ -e "$_fakeroot/AGENTS.md" ] || [ -e "$_fakeroot/.gitattributes" ]; then _t4=1; else _t4=0; fi
    _selftest_assert_eq "清理删掉源码文件" "0" "$_t4"
    if [ -f "$_fakeroot/my-notes.txt" ]; then _t5=1; else _t5=0; fi
    _selftest_assert_eq "用户自己的文件保留" "1" "$_t5"
    if is_source_copy "$_fakeroot"; then _t6=1; else _t6=0; fi
    _selftest_assert_eq "清理后不再判源码包" "0" "$_t6"

    echo "[6] 安装包结构校验"
    _pkg="$_sandbox/pkg"
    mkdir -p "$_pkg/win/lib" "$_pkg/mac/lib" 2>/dev/null || true
    printf '9.9.9' > "$_pkg/VERSION" 2>/dev/null || true
    # 本平台（mac）的包必须完整：入口自己声明库清单，目录里只放入口 + 菜单壳 + 定位器 + 声明的库。
    printf 'CORE_LIBS="base probe"\n' > "$_pkg/mac/envproxy.sh" 2>/dev/null || true
    printf '# menu\n' > "$_pkg/mac/打开菜单.command" 2>/dev/null || true
    printf '# locator\n' > "$_pkg/mac/locator.sh" 2>/dev/null || true
    printf '# lib\n' > "$_pkg/mac/lib/base.sh" 2>/dev/null || true
    printf '# lib\n' > "$_pkg/mac/lib/probe.sh" 2>/dev/null || true
    # 另一平台目录只是陪衬：校验只看本平台目录的文件集，但编码红线会扫全树。
    printf '\357\273\277# entry\n' > "$_pkg/win/envproxy.ps1" 2>/dev/null || true
    printf '\357\273\277# lib\n' > "$_pkg/win/lib/base.ps1" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p1=1; else _p1=0; fi
    _selftest_assert_eq "结构完整的包被接受" "1" "$_p1"
    if verify_package "$_pkg" "1.2.3" "mac"; then _p2=1; else _p2=0; fi
    _selftest_assert_eq "版本不符被拒绝" "0" "$_p2"
    printf '# lib\n' > "$_pkg/win/lib/base.ps1" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p3=1; else _p3=0; fi
    _selftest_assert_eq "库缺 BOM 被拒绝" "0" "$_p3"
    printf '\357\273\277# lib\n' > "$_pkg/win/lib/base.ps1" 2>/dev/null || true
    printf 'CORE_LIBS="base probe"\r\n' > "$_pkg/mac/envproxy.sh" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p4=1; else _p4=0; fi
    _selftest_assert_eq "壳含 CRLF 被拒绝" "0" "$_p4"
    printf 'CORE_LIBS="base probe"\n' > "$_pkg/mac/envproxy.sh" 2>/dev/null || true
    printf '\357\273\277' > "$_pkg/win/lib/empty.ps1" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p5=1; else _p5=0; fi
    _selftest_assert_eq "只剩 BOM 的截断文件被拒绝" "0" "$_p5"
    rm -f "$_pkg/win/lib/empty.ps1" 2>/dev/null || true
    rm -f "$_pkg/win/envproxy.ps1" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p6=1; else _p6=0; fi
    _selftest_assert_eq "缺另一平台入口照样接受" "1" "$_p6"
    printf '\357\273\277# entry\n' > "$_pkg/win/envproxy.ps1" 2>/dev/null || true
    # 内容集：缺一个声明的库、或多一个没声明的文件，都必须拒收——否则覆盖时
    # 删除循环会把缺的库当旧版残留删空，安装区变空壳还报成功。
    rm -f "$_pkg/mac/lib/probe.sh" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p7=1; else _p7=0; fi
    _selftest_assert_eq "缺一个声明的库被拒绝" "0" "$_p7"
    printf '# lib\n' > "$_pkg/mac/lib/probe.sh" 2>/dev/null || true
    printf '# x\n' > "$_pkg/mac/lib/backdoor.sh" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p8=1; else _p8=0; fi
    _selftest_assert_eq "多一个未声明的文件被拒绝" "0" "$_p8"
    rm -f "$_pkg/mac/lib/backdoor.sh" 2>/dev/null || true
    rm -f "$_pkg/mac/envproxy.sh" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p9=1; else _p9=0; fi
    _selftest_assert_eq "只缺自己平台入口也被拒绝" "0" "$_p9"

    echo "[6b] 分包作用域（覆盖 legacy 全量树）"
    _leg="$_sandbox/legacy"; _spk="$_sandbox/split"; _stg="$_sandbox/stage"
    mkdir -p "$_leg/win" "$_leg/mac/lib" "$_leg/release-notes" "$_spk/mac/lib" "$_spk/release-notes" "$_stg" 2>/dev/null || true
    printf '9.9.9' > "$_leg/VERSION" 2>/dev/null || true
    printf '9.9.9' > "$_spk/VERSION" 2>/dev/null || true
    printf '#!/bin/bash\n# mac OLD\n' > "$_leg/mac/envproxy.sh" 2>/dev/null || true
    printf '#!/bin/bash\n# lib OLD\n' > "$_leg/mac/lib/base.sh" 2>/dev/null || true
    printf 'stale\n' > "$_leg/mac/old.sh" 2>/dev/null || true
    printf '# win OLD\n' > "$_leg/win/envproxy.ps1" 2>/dev/null || true
    printf 'stale\n' > "$_leg/win/old.ps1" 2>/dev/null || true
    printf '#!/bin/bash\n# mac NEW\n' > "$_spk/mac/envproxy.sh" 2>/dev/null || true
    printf '#!/bin/bash\n# lib NEW\n' > "$_spk/mac/lib/base.sh" 2>/dev/null || true
    printf 'notes\n' > "$_spk/release-notes/v9.md" 2>/dev/null || true
    if install_package "$_spk" "$_leg" "$_stg" "mac release-notes assets"; then _q0=1; else _q0=0; fi
    _selftest_assert_eq "作用域覆盖成功" "1" "$_q0"
    _selftest_assert_file_eq "本平台入口被更新" "$(printf '#!/bin/bash\n# mac NEW\n')" "$_leg/mac/envproxy.sh"
    if [ ! -f "$_leg/mac/old.sh" ]; then _q1=1; else _q1=0; fi
    _selftest_assert_eq "本平台残留被删" "1" "$_q1"
    _selftest_assert_file_eq "另一平台入口原样不动" "$(printf '# win OLD\n')" "$_leg/win/envproxy.ps1"
    if [ -f "$_leg/win/old.ps1" ]; then _q2=1; else _q2=0; fi
    _selftest_assert_eq "另一平台残留原样保留" "1" "$_q2"
    _selftest_assert_eq "共享 VERSION 落位" "9.9.9" "$(tr -d ' \t\r\n' < "$_leg/VERSION" 2>/dev/null)"
    # 写失败必须大声失败：目标只读时一个字节都写不进去，且返回非零。
    # root 不受权限位限制，且 Windows 的 git-bash 下 chmod 拦不住写——这段只在真 POSIX 非 root 跑
    #（CI 的 ubuntu 与日常的 macOS，本地 Windows 跑门禁时跳过并记一笔）。
    _q3=0
    if [ "$(id -u 2>/dev/null)" != "0" ]; then
        case "$(uname -s 2>/dev/null)" in
            MINGW*|MSYS*|CYGWIN*) echo "  SKIP 写不进去就报失败（非 POSIX 环境）";;
            *)
                chmod -w "$_leg/mac" 2>/dev/null || true
                if install_package "$_spk" "$_leg" "$_stg" "mac release-notes assets"; then _q3=1; else _q3=0; fi
                chmod +w "$_leg/mac" 2>/dev/null || true;;
        esac
    fi
    _selftest_assert_eq "写不进去就报失败" "0" "$_q3"

    echo "[7] 库清单与库实现"
    # 空壳库（只有注释、没有函数）在语法上完全合法，却会让整个 mac 侧起不来——
    # 装上去之后监控第一次调用就挂。这里逐个查"存在、非空、至少有一个函数定义"。
    for _lib in $CORE_LIBS; do
        _lf="$LIB_DIR/$_lib.sh"
        if [ -s "$_lf" ]; then _l0=1; else _l0=0; fi
        _selftest_assert_eq "库 $_lib.sh 存在且非空" "1" "$_l0"
        if grep -qE '^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{' "$_lf" 2>/dev/null; then _l1=1; else _l1=0; fi
        _selftest_assert_eq "库 $_lib.sh 里有函数定义" "1" "$_l1"
    done
    # 每个库的代表入口函数必须真的被定义出来（改名或写空壳都会在这里露出来）。
    for _pair in "base:merge_no_proxy" "probe:get_current_state" "env:apply_state" "runtime:run_monitor_loop" "package:install_package" "update:update_envproxy" "ops:install_envproxy"; do
        _lib="${_pair%%:*}"; _fn="${_pair##*:}"
        if [ "$(type -t "$_fn" 2>/dev/null || true)" = "function" ]; then _l2=1; else _l2=0; fi
        _selftest_assert_eq "库 $_lib 的代表函数 $_fn 已定义" "1" "$_l2"
    done

    echo "[8] 监控启动目标"
    # 监控必须从入口脚本启动：库不得自行推算"我在哪"——在库里 $0 / BASH_SOURCE 指的是库文件
    # 自己，拿它启动等于去跑一个跑不起来的文件（装完没有监控，日志里连一行都不会有）。
    if [ -n "$SCRIPT_PATH" ] && [ "$SCRIPT_PATH" = "$SCRIPT_DIR/envproxy.sh" ] && [ -f "$SCRIPT_PATH" ]; then _l3=1; else _l3=0; fi
    _selftest_assert_eq "入口公布的 SCRIPT_PATH 指向入口脚本本身" "1" "$_l3"

    echo "[8b] 运行时加固"
    # 监控的判据必须看**参数位**，不是看命令行里有没有 install/stop 这些字。
    # 装在名字带 install 的目录里的监控，用子串匹配会被当成一次性命令：
    # 于是"监控没在跑"→ 又起一个，停的时候也停不掉。
    if is_monitor_args "/bin/bash /Users/me/Downloads/install/mac/envproxy.sh"; then _r1=1; else _r1=0; fi
    _selftest_assert_eq "路径里带 install 的监控仍然算监控" "1" "$_r1"
    if is_monitor_args "/bin/bash /Users/me/mac/envproxy.sh"; then _r2=1; else _r2=0; fi
    _selftest_assert_eq "不带子命令的算监控" "1" "$_r2"
    if is_monitor_args "/bin/bash /Users/me/mac/envproxy.sh install"; then _r3=0; else _r3=1; fi
    _selftest_assert_eq "带 install 子命令的不算监控" "1" "$_r3"
    if is_monitor_args "/bin/bash /Users/me/mac/envproxy.sh status"; then _r4=0; else _r4=1; fi
    _selftest_assert_eq "带 status 子命令的不算监控" "1" "$_r4"
    if is_monitor_args "/usr/bin/sleep 100"; then _r5=0; else _r5=1; fi
    _selftest_assert_eq "别的进程不算监控" "1" "$_r5"

    # 操作锁：拿锁必须原子的。分两步（先 mkdir 再写 pid）会留一个空窗——
    # 中间那个空窗里另一个进程读到空的 pid，会把锁当成陈旧的接管掉，
    # 两个安装同时跑就互相覆盖文件。现在用 ln：锁一出现就是完整的。
    _rlock="$_sandbox/.op.lock.test"
    if acquire_op_lock "$_rlock" >/dev/null 2>&1; then _r6=1; else _r6=0; fi
    _selftest_assert_eq "第一次拿锁成功" "1" "$_r6"
    if [ -f "$_rlock" ]; then _r7=1; else _r7=0; fi
    _selftest_assert_eq "锁文件存在" "1" "$_r7"
    if acquire_op_lock "$_rlock" >/dev/null 2>&1; then _r8=0; else _r8=1; fi
    _selftest_assert_eq "持锁者还在时第二个拿不到" "1" "$_r8"
    # 陈旧锁（持有者已经不在）必须能被接管——否则一次崩溃就把用户锁死在门外。
    rm -f "$_rlock" 2>/dev/null || true
    printf '999999\n' > "$_rlock" 2>/dev/null || true
    if acquire_op_lock "$_rlock" >/dev/null 2>&1; then _r9=1; else _r9=0; fi
    _selftest_assert_eq "陈旧的锁能被接管" "1" "$_r9"
    rm -f "$_rlock" 2>/dev/null || true
    # 锁内容必须就是持有者的 pid：读出来才能判断"持有者还在不在"。
    _rlock2="$_sandbox/.op.lock.test2"
    acquire_op_lock "$_rlock2" >/dev/null 2>&1 || true
    _r10=$(cat "$_rlock2" 2>/dev/null | tr -d ' \t\r\n')
    _selftest_assert_eq "锁里写的是持有者的 pid" "$$" "$_r10"
    rm -f "$_rlock2" 2>/dev/null || true

    # hook 改写必须原子：就地截断重写一旦中途失败或被杀，
    # 用户的 .zshrc 就停在半截上，shell 一开就报错。
    _rcf="$_sandbox/rc-test"
    _rcsrc="$_sandbox/rc-src"
    printf 'old content\n' > "$_rcf" 2>/dev/null || true
    printf 'new content\n' > "$_rcsrc" 2>/dev/null || true
    if _write_rc_atomic "$_rcsrc" "$_rcf" 2>/dev/null; then _r11=1; else _r11=0; fi
    _selftest_assert_eq "原子写成功" "1" "$_r11"
    _selftest_assert_file_eq "内容换成了新的" "$(printf 'new content')" "$_rcf"
    # 软链不能被换成普通文件：mv 是原子的，但直接 mv 会把软链换成实体文件。
    # 有些环境（Windows 的 git-bash）建不出真软链——ln -s 会退化成复制，
    # 那时这条测不了，跳过并记一笔（真 macOS 与 CI 的 ubuntu 都测得到）。
    _rctarget="$_sandbox/rc-target"
    _rclink="$_sandbox/rc-link"
    printf 'target old\n' > "$_rctarget" 2>/dev/null || true
    printf 'target new\n' > "$_rcsrc" 2>/dev/null || true
    if ln -sf "$_rctarget" "$_rclink" 2>/dev/null && [ -L "$_rclink" ]; then
        _write_rc_atomic "$_rcsrc" "$_rclink" 2>/dev/null || true
        if [ -L "$_rclink" ]; then _r12=1; else _r12=0; fi
        _selftest_assert_eq "软链还是软链" "1" "$_r12"
        _selftest_assert_file_eq "软链指向的文件内容更新了" "$(printf 'target new')" "$_rctarget"
    else
        echo "  SKIP 软链改写（本机建不出真软链）"
    fi

    # 权限位要照原文件带过去（用户可能特意设过）。
    # Windows 的 git-bash 上 chmod 是空操作（MSYS 不实现 POSIX 权限），
    # 那时权限测不了，跳过并记一笔。
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) echo "  SKIP 权限位与快照权限（非 POSIX 环境）";;
        *)
            chmod 600 "$_rcf" 2>/dev/null || true
            printf 'again\n' > "$_rcsrc" 2>/dev/null || true
            _write_rc_atomic "$_rcsrc" "$_rcf" 2>/dev/null || true
            _rperm=$(_perm_of "$_rcf")
            _selftest_assert_eq "权限位保持不变" "600" "$_rperm"
            # 快照里是用户原来的代理地址，可能带账号密码。默认权限（同 umask，通常 0644）
            # 是同机其他用户都能读——凭据就这么漏出去了。
            rm -f "$PREV_ENV" 2>/dev/null || true
            snapshot_prev_env >/dev/null 2>&1 || true
            _rperm2=$(_perm_of "$PREV_ENV")
            _selftest_assert_eq "快照文件的权限是 600" "600" "$_rperm2"
            ;;
    esac

    # 自愈不许杀正在跑的监控：bootout 会给监控发 SIGTERM，
    # 而紧接着启的新监控可能抢不到单实例锁——于是"自愈"的结果是监控没了。
    if autorun_reload_needed 1; then _r13=1; else _r13=0; fi
    _selftest_assert_eq "明确要求时才重载代理" "1" "$_r13"
    if grep -q 'autorun_reload_needed' "$LIB_DIR/runtime.sh" 2>/dev/null; then _r14=1; else _r14=0; fi
    _selftest_assert_eq "set_autorun 走的是这个判据" "1" "$_r14"

    # 判"断"要同时满足"次数"和"时长"（与 Win 侧 Test-NodeVerdict 同形）。
    # 只数次数时，判据的时长是「次数 × 节流间隔」的乘积：改节流（省流量）会直接变成
    # 判"断"的耗时。拆开后两种失败都要被拦住——次数够时间不够、时间够次数不够。
    echo "[9b] 迟滞的双条件与自适应节流（与 Win 侧同形）"
    node_verdict 3 4 "$NODE_FAIL_THRESHOLD" "$NODE_FAIL_DWELL_SEC"
    _selftest_assert_eq "双条件：3 次但只横跨 4 秒不判断" "0" "$NODE_VERDICT"
    node_verdict 2 30 "$NODE_FAIL_THRESHOLD" "$NODE_FAIL_DWELL_SEC"
    _selftest_assert_eq "双条件：2 次即使横跨 30 秒也不判断" "0" "$NODE_VERDICT"
    node_verdict 3 10 "$NODE_FAIL_THRESHOLD" "$NODE_FAIL_DWELL_SEC"
    _selftest_assert_eq "双条件：3 次且横跨满 dwell 才判断" "1" "$NODE_VERDICT"
    node_verdict 3 9 "$NODE_FAIL_THRESHOLD" "$NODE_FAIL_DWELL_SEC"
    _selftest_assert_eq "双条件：差一点点也不行" "0" "$NODE_VERDICT"
    node_verdict 5 40 "$NODE_FAIL_THRESHOLD" "$NODE_FAIL_DWELL_SEC"
    _selftest_assert_eq "双条件：更多次、更久当然判断" "1" "$NODE_VERDICT"

    # 采样间隔跟着"有没有结论"走：稳定态省流量，正在收集证据和刚下结论时加密。
    node_probe_interval 0 "$NODE_FAIL_THRESHOLD" 0 1000 "$NODE_CHECK_THROTTLE_SEC" "$NODE_FAST_SEC"
    _selftest_assert_eq "间隔：稳定态用稳定间隔" "$NODE_CHECK_THROTTLE_SEC" "$NODE_PROBE_INTERVAL"
    node_probe_interval 1 "$NODE_FAIL_THRESHOLD" 0 1000 "$NODE_CHECK_THROTTLE_SEC" "$NODE_FAST_SEC"
    _selftest_assert_eq "间隔：有失败未达阈值时加密" "$NODE_FAST_SEC" "$NODE_PROBE_INTERVAL"
    node_probe_interval 0 "$NODE_FAIL_THRESHOLD" 1030 1000 "$NODE_CHECK_THROTTLE_SEC" "$NODE_FAST_SEC"
    _selftest_assert_eq "间隔：刚下完结论时加密" "$NODE_FAST_SEC" "$NODE_PROBE_INTERVAL"
    node_probe_interval 0 "$NODE_FAIL_THRESHOLD" 999 1000 "$NODE_CHECK_THROTTLE_SEC" "$NODE_FAST_SEC"
    _selftest_assert_eq "间隔：加密窗口过了就回到稳定档" "$NODE_CHECK_THROTTLE_SEC" "$NODE_PROBE_INTERVAL"

    if [ "$NODE_FAST_SEC" -lt "$NODE_CHECK_THROTTLE_SEC" ]; then _r15=1; else _r15=0; fi
    _selftest_assert_eq "加密间隔确实比稳定态快" "1" "$_r15"

    # 死态必须回到稳定档：只按"有没有失败"决定间隔的话，节点一直死时计数无界增长、
    # 间隔永远钉在快速档（实测流量是承诺值的 2.5 倍）。
    node_probe_interval "$NODE_FAIL_THRESHOLD" "$NODE_FAIL_THRESHOLD" 0 1000 \
        "$NODE_CHECK_THROTTLE_SEC" "$NODE_FAST_SEC"
    _selftest_assert_eq "失败已达阈值（结论已定）回到稳定档" "$NODE_CHECK_THROTTLE_SEC" "$NODE_PROBE_INTERVAL"
    node_probe_interval 999 "$NODE_FAIL_THRESHOLD" 0 1000 \
        "$NODE_CHECK_THROTTLE_SEC" "$NODE_FAST_SEC"
    _selftest_assert_eq "失败远超阈值也仍是稳定档" "$NODE_CHECK_THROTTLE_SEC" "$NODE_PROBE_INTERVAL"

    # 换端口必须重新判定，不能沿用上个端口的结论——Mac 单槽曾因此把死端口报成"通"。
    # 用替身驱动真实 test_node_alive（只换掉网络那一层）。
    if [ "$(type -t test_node_alive 2>/dev/null || true)" = "function" ]; then
        _s2_saved_port="$NODE_CACHE_PORT"; _s2_saved_alive="$NODE_ALIVE"
        _s2_saved_cnt="$NODE_FAIL_COUNT"; _s2_saved_ffa="$NODE_FIRST_FAIL_AT"
        _s2_saved_until="$NODE_FAST_UNTIL"; _s2_saved_lc="$LAST_NODE_CHECK"
        _s2_real=$(declare -f test_real_connectivity 2>/dev/null || true)
        # 替身用 eval 定义，不写成 test_xxx() { ... }：门禁 1 会扫源码文本找重名函数，
        # 而 probe 层已有同名真实实现，写成函数定义会被判成"重名覆盖"。
        eval 'test_real_connectivity() { [ "$1" = "7078" ]; }'
        NODE_CACHE_PORT=""; NODE_ALIVE=0; NODE_FAIL_COUNT=0; NODE_FIRST_FAIL_AT=0
        NODE_FAST_UNTIL=0; LAST_NODE_CHECK=0
        test_node_alive 7078 0; _s2a=$?
        test_node_alive 7897 0; _s2b=$?
        _selftest_assert_eq "换端口前：7078 判为通" "0" "$_s2a"
        _selftest_assert_eq "换到死端口首次探测就判为断（不沿用上个端口的通）" "1" "$_s2b"
        if [ -n "$_s2_real" ]; then eval "$_s2_real"; else unset -f test_real_connectivity 2>/dev/null || true; fi
        NODE_CACHE_PORT="$_s2_saved_port"; NODE_ALIVE="$_s2_saved_alive"
        NODE_FAIL_COUNT="$_s2_saved_cnt"; NODE_FIRST_FAIL_AT="$_s2_saved_ffa"
        NODE_FAST_UNTIL="$_s2_saved_until"; LAST_NODE_CHECK="$_s2_saved_lc"
    fi

    echo "[9] 菜单分派"
    # menu 子命令必须在入口分派里存在，show_menu 必须已定义；
    # 菜单列出的每个子命令都必须能在入口分派里找到（壳调回来的路不断）。
    if [ "$(type -t show_menu 2>/dev/null || true)" = "function" ]; then _l4=1; else _l4=0; fi
    _selftest_assert_eq "show_menu 已定义" "1" "$_l4"
    # 光断言"函数存在"是不够的：它曾经因为分组取错段而渲染出一张**空菜单**——
    # 函数在、键位也能用，屏幕上却一个条目都没有，而自检全绿。
    # 所以这里真的渲染一次、真的数条目。
    _lm=0
    for _lmi in "${MENU_ITEMS[@]}"; do _lm=$((_lm + 1)); done
    _selftest_assert_eq "菜单表非空" "1" "$([ "$_lm" -gt 0 ] && echo 1 || echo 0)"
    _lmt=$(format_menu_text 2>/dev/null || true)
    _lmlines=$(printf '%s\n' "$_lmt" | grep -cE '^    [0-9]  ' || true)
    # 渲染出来的条目数必须等于表里的条目数：加一项时这里自动跟上，不会留下写死的旧数字。
    _selftest_assert_eq "渲染出的条目数与表一致" "$_lm" "$_lmlines"
    case "$_lmt" in *日常*) _lmg=1;; *) _lmg=0;; esac
    _selftest_assert_eq "菜单渲染出分组名" "1" "$_lmg"
    # 每一行的分组字段必须是 日常/维护/退出，不能是子命令名（取错段就会变成 install）。
    for _lmi in "${MENU_ITEMS[@]}"; do
        _lmgv=${_lmi%|*}; _lmgv=${_lmgv##*|}
        case "$_lmgv" in
            日常|维护|退出) _lmgok=1;;
            *) _lmgok=0;;
        esac
        _selftest_assert_eq "分组字段是分组不是子命令（${_lmi%%|*}）" "1" "$_lmgok"
    done
    # 表里每个非退出项的子命令都要能取出来，且和入口分派里的名字对得上。
    for _lmi in "${MENU_ITEMS[@]}"; do
        _lmk=${_lmi%%|*}
        _lms=$(_menu_switch_for "$_lmk" 2>/dev/null || true)
        case "$_lmk" in
            0) _selftest_assert_eq "退出项没有子命令" "" "$_lms";;
            *) case "$_lms" in
                   '') _selftest_assert_eq "条目 $_lmk 有子命令" "0" "1";;
                   *) _selftest_assert_eq "条目 $_lmk 子命令可解析" "1" "1";;
               esac;;
        esac
    done
    # 帮助：函数必须存在、入口分派里必须有 help 子命令、内容必须真的讲清三件事。
    # 只断言"存在"是不够的——帮助文本被改成一句废话也照样"存在"，那就不帮任何人了。
    if [ "$(type -t show_help 2>/dev/null || true)" = "function" ]; then _lh=1; else _lh=0; fi
    _selftest_assert_eq "show_help 已定义" "1" "$_lh"
    if grep -qE '^[[:space:]]*help\)' "$SCRIPT_DIR/envproxy.sh" 2>/dev/null; then _lhh=1; else _lhh=0; fi
    _selftest_assert_eq "help 在入口分派里存在" "1" "$_lhh"
    _ht=$(show_help 2>/dev/null || true)
    case "$_ht" in *回车*) _lh1=1;; *) _lh1=0;; esac
    _selftest_assert_eq "帮助讲了'回车'这个时机" "1" "$_lh1"
    case "$_ht" in *"安装 / 修复"*) _lh2=1;; *) _lh2=0;; esac
    _selftest_assert_eq "帮助讲了'安装 / 修复'这条万能修复" "1" "$_lh2"
    case "$_ht" in *ENVPROXY_TERM*) _lh3=1;; *) _lh3=0;; esac
    _selftest_assert_eq "帮助给了逐窗口接管的命令" "1" "$_lh3"
    # 帮助页也要认 q 和 0：菜单里它们是退出，刚学会的人进到帮助再按就被判成
    # "没有这一条"，会以为帮助坏了。这条钉住两端行为一致。
    if grep -qE '^[[:space:]]*q\|Q\|0\)' "$SCRIPT_DIR/lib/ops.sh" 2>/dev/null; then _lq=1; else _lq=0; fi
    _selftest_assert_eq "帮助页认 q 和 0（与菜单同义）" "1" "$_lq"
    # 屏幕形状：和 Windows 侧同一类防护。文案层的坏法（整屏超长、重复行、
    # 超宽行、写死绝对路径、命令残缺）靠"关键词还在不在"查不出来，只能量形状。
    # 两端各有一份，改文案时两边一起被守住——这是"行为改动双侧同改"的落地。
    for _sk in "${HELP_TOPIC_KEYS[@]}"; do
        _sr=$(format_help_topic "$_sk")
        # 1) 一屏放得下：超出的部分会被终端切掉，常被切掉的正是底部的"怎么退出"。
        _sn=$(printf '%s\n' "$_sr" | wc -l | tr -d ' ')
        if [ "$_sn" -le 30 ]; then _s1=1; else _s1=0; fi
        _selftest_assert_eq "主题 $_sk 在 30 行内" "1" "$_s1"
        # 2) 相邻两行一模一样 = 编辑留下的重复段。
        _s2=1
        _sprev=""
        _sfirst=1
        while IFS= read -r _sline; do
            if [ "$_sfirst" = "0" ] && [ -n "$_sline" ] && [ "$_sline" = "$_sprev" ]; then _s2=0; fi
            _sprev="$_sline"; _sfirst=0
        done <<EOF
$_sr
EOF
        _selftest_assert_eq "主题 $_sk 无重复行" "1" "$_s2"
        # 3) 行宽：超宽会硬折行。例外是一整条命令（缩进 + 纯 ASCII），
        #    命令是给用户整条复制的，硬拆反而更难用。
        _s3=1
        _s3=1
        # wc -L 给的是显示宽度（中文算 2 列），比 awk 的 length 靠谱——
        # 后者在某些 awk 实现里按字节算，一个中文字就顶 3。
        _swide=""
        while IFS= read -r _sline; do
            _sw=$(printf '%s' "$_sline" | wc -L | tr -d ' ')
            [ -z "$_sw" ] && _sw=0
            [ "$_sw" -le 80 ] && continue
            # 例外：一整条命令（缩进 + 纯 ASCII），命令是给用户整条复制的。
            case "$_sline" in
                " "*[\!\#$%]*|[!-~]*) ;;
            esac
            if printf '%s' "$_sline" | grep -qE '^[ ]+[ -~]+$'; then continue; fi
            _swide="$_sline"; break
        done <<EOF
$_sr
EOF
        if [ -n "$_swide" ]; then _s3=0; fi
        _selftest_assert_eq "主题 $_sk 无超宽行" "1" "$_s3"
        # 4) 不许混进本机绝对路径（那一屏是给别人看的）。
        _s4=1
        case "$_sr" in *"/Users/"*|*":\\Users\\"*) _s4=0;; esac
        _selftest_assert_eq "主题 $_sk 无写死的家目录路径" "1" "$_s4"
        # 5) 命令不许残缺：反引号残留、变量名被吃成空。
        _s5=1
        case "$_sr" in *'`'*) _s5=0;; esac
        _selftest_assert_eq "主题 $_sk 无残缺命令" "1" "$_s5"
        # 正文和标题都不许空。Mac 侧主题信息分散在四个 case 里，漏改标题
        # 的后果不是报错，而是"目录出现一个空标题、选中后是一页空白"，
        # 自检的形状断言（行数/重复/超宽）全都会通过——所以这一条必须单独查。
        _st=$(_help_topic_title "$_sk")
        if [ -n "$_st" ]; then _s6=1; else _s6=0; fi
        _selftest_assert_eq "主题 $_sk 有标题" "1" "$_s6"
        _sbody=$(format_help_topic "$_sk" | sed -n "4,999p" | grep -c "[^ ]" || true)
        if [ "$_sbody" -ge 5 ]; then _s7=1; else _s7=0; fi
        _selftest_assert_eq "主题 $_sk 正文不为空" "1" "$_s7"
    done
    if grep -qE '^[[:space:]]*menu\)' "$SCRIPT_DIR/envproxy.sh" 2>/dev/null; then _l5=1; else _l5=0; fi
    _selftest_assert_eq "menu 在入口分派里存在" "1" "$_l5"
    for _ms in install status stop uninstall update; do
        if grep -qE "^[[:space:]]*$_ms\\)" "$SCRIPT_DIR/envproxy.sh" 2>/dev/null; then _l6=1; else _l6=0; fi
        _selftest_assert_eq "菜单子命令 $_ms 在入口分派里存在" "1" "$_l6"
    done

    echo "[10] 更新源表"
    # 更新入口按源表逐个试，第一个答出来的胜出。表坏了不会报错，只会悄悄退化成"只剩官方源"，
    # 直到官方源不可达那天才暴露——而那天正是最需要兜底的时刻。所以表的形状在这里钉住：
    # 每条七个字段、模板保留 @@ 占位符、优先路径合法、官方源排第一。
    _st_all=$(get_update_sources)
    if [ -n "$_st_all" ]; then _st1=1; else _st1=0; fi
    _selftest_assert_eq "源表至少有一个可用源" "1" "$_st1"
    _selftest_assert_eq "官方源排第一" "GitHub" "$(printf '%s\n' "$_st_all" | head -n 1 | cut -d'|' -f1)"
    # 模板表每条必须正好七个字段、保留 @@ 占位符、优先路径是已知值；代入后每行必须是成形地址
    # （四个地址都非空、占位符替换干净、网页路径落在 releases/latest 上、API 前缀是个 https 根）。
    # 不点名具体域名：加源是"表里加一行"，把域名写死会让以后加非 GitHub 源时自检直接失败。
    _st_tpl_ok=$(printf '%s\n' "$UPDATE_SOURCE_TABLE" | awk '
        NF != 7 { bad = 1 }
        $0 !~ /@@/ { bad = 1 }
        $3 != "Api" && $3 != "Web" { bad = 1 }
        END { print (bad ? 0 : 1) }')
    _selftest_assert_eq "源表每条七字段、模板带占位符、优先路径合法" "1" "$_st_tpl_ok"
    _st_out_ok=$(get_update_sources | awk -F'|' '
        NF != 6 { bad = 1 }
        $2 != "Api" && $2 != "Web" { bad = 1 }
        $3 == "" || $4 == "" || $5 == "" || $6 == "" { bad = 1 }
        $3 $4 $5 $6 ~ /@@/ { bad = 1 }
        $4 !~ /releases\/latest$/ { bad = 1 }
        $6 !~ /^https:\/\/[^\/]+\/./ { bad = 1 }
        END { print (bad ? 0 : 1) }')
    _selftest_assert_eq "仓库标识代入后四处地址成形、无占位符残留" "1" "$_st_out_ok"
    # 资产解析是纯函数，结果写进 ASSET_ID / ASSET_DIGEST 两个全局。
    # 样本照抄服务端真实格式：GitHub 的响应带缩进（冒号后有空格），只拿压缩 JSON 测
    # 等于钉住自己的假设，而不是钉住外部世界的事实。
    _st_asset_pretty='{
  "id": 99,
  "tag_name": "v1.2.3",
  "assets": [
    {
      "url": "https://api.github.com/repos/o/r/releases/assets/12345",
      "id": 12345,
      "name": "EnvProxy-win.zip",
      "uploader": { "login": "u", "id": 777 }
    },
    {
      "url": "https://api.github.com/repos/o/r/releases/assets/67890",
      "id": 67890,
      "name": "EnvProxy-mac.tar.gz"
    }
  ]
}'
    _st_asset_json='{"id":99,"tag_name":"v1.2.3","assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/12345","id":12345,"name":"EnvProxy-win.zip","uploader":{"login":"u","id":777}},{"url":"https://api.github.com/repos/o/r/releases/assets/67890","id":67890,"name":"EnvProxy-mac.tar.gz"}]}'
    get_asset_from_json "$_st_asset_pretty" 'EnvProxy-mac.tar.gz'
    _selftest_assert_eq "按文件名取 id（服务端缩进格式）" "67890" "$ASSET_ID"
    get_asset_from_json "$_st_asset_json" 'EnvProxy-mac.tar.gz'
    _selftest_assert_eq "按文件名取 id（压缩格式也认）" "67890" "$ASSET_ID"
    # 字段顺序是服务端的实现细节：name 在前时也必须取到**本条资产**的 id，不能取到上一条。
    _st_asset_reordered='{"assets":[{"id":111,"name":"EnvProxy-win.zip"},{"name":"EnvProxy-mac.tar.gz","id":222}]}'
    get_asset_from_json "$_st_asset_reordered" 'EnvProxy-mac.tar.gz'
    _selftest_assert_eq "字段顺序反过来仍取本条资产的 id" "222" "$ASSET_ID"
    _st_asset_space='{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/333","name":"Env Proxy mac.tar.gz"}]}'
    get_asset_from_json "$_st_asset_space" 'Env Proxy mac.tar.gz'
    _selftest_assert_eq "文件名里带空格也能匹配" "333" "$ASSET_ID"
    get_asset_from_json "$_st_asset_pretty" 'EnvProxy-nope.zip'
    _selftest_assert_eq "资产 JSON 里没有该文件时留空" "" "$ASSET_ID"
    get_asset_from_json 'not json' 'EnvProxy-win.zip'
    _selftest_assert_eq "资产 JSON 不合法时留空" "" "$ASSET_ID"
    get_asset_from_json '{"message":"API rate limit exceeded"}' 'EnvProxy-mac.tar.gz'
    _selftest_assert_eq "限流错误页不会给出 id" "" "$ASSET_ID"
    # 200 但不是 Release JSON（企业代理劫持页、错误对象）不能报"这版没提供安装包"——
    # 那是冤枉维护者，还让用户去手动下载（那里同样拿不到）。
    get_asset_from_json '<html><body>Login</body></html>' 'EnvProxy-mac.tar.gz'
    _selftest_assert_eq "HTML 页面不是 Release JSON" "other" "$ASSET_SCOPE"
    get_asset_from_json '{"message":"Bad credentials"}' 'EnvProxy-mac.tar.gz'
    _selftest_assert_eq "错误对象不是 Release JSON" "other" "$ASSET_SCOPE"
    get_asset_from_json "$_st_asset_json" 'EnvProxy-mac.tar.gz'
    _selftest_assert_eq "Release JSON 认得出来" "release" "$ASSET_SCOPE"
    get_asset_from_json "$_st_asset_json" 'EnvProxy-nope.zip'
    _selftest_assert_eq "Release JSON 里没有该文件时仍然是 Release JSON" "release" "$ASSET_SCOPE"
    # digest 的十六进制大小写两侧必须一致：对方改成大写时，不能一边验、一边静默不验。
    _st_asset_upper='{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/888","name":"EnvProxy-mac.tar.gz","digest":"sha256:1731CE10FDE048900C7B3A793D81CBA5EC8411D6E1FE82930B3C34BC82CFB4D5"}]}'
    get_asset_from_json "$_st_asset_upper" 'EnvProxy-mac.tar.gz'
    _selftest_assert_eq "大写 digest 认得出来并归一为小写" "sha256:1731ce10fde048900c7b3a793d81cba5ec8411d6e1fe82930b3c34bc82cfb4d5" "$ASSET_DIGEST"
    # 标签要编码后才拼进 URL（标签来自远端应答，不编码会拼出坏地址）。
    _selftest_assert_eq "普通标签不编码" "v1.2.3" "$(url_encode 'v1.2.3')"
    _selftest_assert_eq "标签里的空格要编码" "v1%202" "$(url_encode 'v1 2')"
    _selftest_assert_eq "标签里的斜杠要编码" "..%2F..%2Fevil" "$(url_encode '../../evil')"
    _selftest_assert_eq "标签里的问号要编码" "v1%3F2" "$(url_encode 'v1?2')"
    # 文件名必须逐字节相等：GitHub 的资产名大小写敏感，认成不敏感就会去下错文件。
    get_asset_from_json "$_st_asset_json" 'envproxy-mac.tar.gz'
    _selftest_assert_eq "文件名大小写不同不匹配" "" "$ASSET_ID"
    # 发布说明是自由文本，里面出现 },{ 或引号都不该把解析搞坏（切块式写法就会在这里翻车）。
    _st_asset_body='{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/444","id":444,"name":"EnvProxy-win.zip"}],"body":"示例 },{ 还有 \\"引号\\" 与 {花括号}"}'
    get_asset_from_json "$_st_asset_body" 'EnvProxy-win.zip'
    _selftest_assert_eq "发布说明里的 },{ 不影响取资产" "444" "$ASSET_ID"
    # 编号取自 url（那是我们真正要 GET 的端点），url 里没有才退回 id 字段。
    _st_asset_urlover='{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/555","id":999,"name":"EnvProxy-win.zip"}]}'
    get_asset_from_json "$_st_asset_urlover" 'EnvProxy-win.zip'
    _selftest_assert_eq "编号以 url 为准" "555" "$ASSET_ID"
    _st_asset_idonly='{"assets":[{"url":"https://example.invalid/x","id":666,"name":"EnvProxy-win.zip"}]}'
    get_asset_from_json "$_st_asset_idonly" 'EnvProxy-win.zip'
    _selftest_assert_eq "url 里没有编号时退回 id 字段" "666" "$ASSET_ID"
    # 编号形状不对就不认：0、前导零、二十位数都不该进 URL。
    for _st_bad in 0 007 12345678901234567890; do
        get_asset_from_json "{\"assets\":[{\"url\":\"https://api.github.com/repos/o/r/releases/assets/$_st_bad\",\"name\":\"EnvProxy-win.zip\"}]}" 'EnvProxy-win.zip'
        _selftest_assert_eq "编号 $_st_bad 不认" "" "$ASSET_ID"
    done
    # digest 是 GitHub 自己算的资产校验值：形状不对就当没有（老资产根本没这字段）。
    _st_asset_dg="sha256:$(printf 'a%.0s' $(seq 1 64))"
    _st_asset_digest="{\"assets\":[{\"url\":\"https://api.github.com/repos/o/r/releases/assets/777\",\"name\":\"EnvProxy-win.zip\",\"digest\":\"$_st_asset_dg\"}]}"
    get_asset_from_json "$_st_asset_digest" 'EnvProxy-win.zip'
    _selftest_assert_eq "digest 合法时取到" "$_st_asset_dg" "$ASSET_DIGEST"
    get_asset_from_json '{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/777","name":"EnvProxy-win.zip","digest":null}]}' 'EnvProxy-win.zip'
    _selftest_assert_eq "digest 为 null 时当作没有" "" "$ASSET_DIGEST"
    get_asset_from_json '{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/777","name":"EnvProxy-win.zip","digest":"sha256:XYZ"}]}' 'EnvProxy-win.zip'
    _selftest_assert_eq "digest 形状不对时当作没有" "" "$ASSET_DIGEST"
    # 问版本阶段的原因要分得清。解析层是纯函数，直接喂应答即可——不联网，
    # 也不用改别人的函数（在自检里重定义库函数会真的覆盖生产函数，库之间不能重名）。
    # 这些判据曾集体失效：原因写在全局、调用却套了命令替换，命令替换跑在子 shell 里，
    # 全局赋值出不来，于是限流、缺包、服务端故障全被报成"连不上"，
    # 用户会被叫去开翻墙软件（白折腾）。
    tag_from_api_response "x
429" ""
    _selftest_assert_eq "问版本：429 是配额用尽" "quota" "$TAG_FAILURE"
    tag_from_api_response "x
404" ""
    _selftest_assert_eq "问版本：404 是没这个版本" "missing" "$TAG_FAILURE"
    tag_from_api_response "x
403" "0"
    _selftest_assert_eq "问版本：403 且配额剩 0 是配额用尽" "quota" "$TAG_FAILURE"
    tag_from_api_response "x
403" "42"
    _selftest_assert_eq "问版本：403 但还有配额是被拒" "server" "$TAG_FAILURE"
    tag_from_api_response "x
500" ""
    _selftest_assert_eq "问版本：5xx 是服务端问题" "server" "$TAG_FAILURE"
    tag_from_api_response "x
200" ""
    _selftest_assert_eq "问版本：200 但内容不是 JSON 报连不上" "network" "$TAG_FAILURE"
    tag_from_api_response '{"tag_name":"v3.2.1"}
200' ""
    _selftest_assert_eq "问版本：200 且有标签时取到标签" "v3.2.1" "$TAG"
    # 网页路径：3xx 是正常应答，重定向目标里有标签就该取到。
    tag_from_web_response "302" "https://github.com/o/r/releases/tag/v1.2.3" ""
    _selftest_assert_eq "问版本：网页 302 里的标签取得到" "v1.2.3" "$TAG"
    _selftest_assert_eq "问版本：网页 302 不是失败" "" "$TAG_FAILURE"
    tag_from_web_response "302" "https://github.com/o/r/releases/latest" ""
    _selftest_assert_eq "问版本：重定向到预期之外的地方算服务端问题" "server" "$TAG_FAILURE"
    tag_from_web_response "429" "" ""
    _selftest_assert_eq "问版本：网页路 429 是配额用尽" "quota" "$TAG_FAILURE"
    # 下载到的文件要跟 GitHub 发布的资产校验值对一下。那个 digest 是查资产编号时顺带拿到的，
    # 不额外发请求也不额外下文件；老版本没有这个字段就跳过校验，不因此拦住更新。
    # 期望值用 "hello" 的已知 sha256 写死：这样测的是"对不对"，不是"某个工具算出来多少"，
    # 也不会因为本机少了 shasum 或 openssl 而测不成。
    _st_dg_file="${TMPDIR:-/tmp}/envproxy-selftest-digest.$$"
    printf 'hello' > "$_st_dg_file"
    check_asset_digest "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" "$_st_dg_file"
    _selftest_assert_eq "校验值对得上" "0" "$?"
    check_asset_digest "sha256:$(printf '0%.0s' $(seq 1 64))" "$_st_dg_file"
    _selftest_assert_eq "校验值对不上要报出来" "1" "$?"
    check_asset_digest "" "$_st_dg_file"
    _selftest_assert_eq "没有校验值就跳过" "2" "$?"
    rm -f "$_st_dg_file" 2>/dev/null || true
    # 查资产编号失败的原因也要参与挑选：否则"这条失败的路没走成"会隐形，
    # 最后只剩直连那一次的结果——直连 404 就被报成"发布方没提供安装包"，
    # 而真实原因可能是配额用尽，那是在冤枉维护者。
    asset_query_failure "429" ""
    _selftest_assert_eq "查资产编号：限流的原因带得出来" "quota" "$ASSET_FAILURE"
    _selftest_assert_eq "查资产编号：限流时不报缺包" "quota" "$(select_update_failure_kind "$ASSET_FAILURE missing")"
    asset_query_failure "200" ""
    _selftest_assert_eq "查资产编号：请求成功时先不判原因" "" "$ASSET_FAILURE"
    # 换源判据：必须比本地新，且不能比已选定的胜出版本旧。只判"比本地新"会让 1.5.0
    # 在 9.9.9 取不到包时被接受，把用户带到更旧的版本上。
    _selftest_assert_eq "换源：同版本接受" "0" "$(source_acceptable 9.9.9 9.9.9 1.0.0; echo $?)"
    _selftest_assert_eq "换源：更旧于胜出版本要拒绝" "1" "$(source_acceptable 1.5.0 9.9.9 1.0.0; echo $?)"
    _selftest_assert_eq "换源：不比本地新要拒绝" "1" "$(source_acceptable 1.0.0 9.9.9 1.0.0; echo $?)"
    _selftest_assert_eq "换源：没有胜出版本时只比本地" "0" "$(source_acceptable 2.0.0 '' 1.0.0; echo $?)"
    _selftest_assert_eq "换源：空版本要拒绝" "1" "$(source_acceptable '' 9.9.9 1.0.0; echo $?)"
    # 从重定向目标取标签必须做形态校验：仓库改名时对方会先 302 到改名后的路径，
    # 最后一段是字面量 "latest"，naive 取尾段会把垃圾当成版本号去拼下载地址。
    _selftest_assert_eq "从 tag 页重定向取标签" "v1.2.3" "$(get_tag_from_location 'https://github.com/o/r/releases/tag/v1.2.3')"
    _selftest_assert_eq "改名仓库的重定向不给标签" "" "$(get_tag_from_location 'https://github.com/new/r/releases/latest')"
    _selftest_assert_eq "含括号的标签原样保留" "v2026.09(jdk25)" "$(get_tag_from_location 'https://github.com/o/r/releases/tag/v2026.09(jdk25)')"
    # 源表展开后每条都必须带仓库标识，不能出现地址带洞的源。
    # 期望条数从表里现算，不写死：写死"1"会让以后按"加源 = 表里加一行"加第二个源时
    # 自检直接失败——那测的是"当前只有一条源"，不是行为对不对。
    _st_want=$(printf '%s\n' "$UPDATE_SOURCE_TABLE" | grep -c . || true)
    _st_one=$(printf '%s\n' "$(get_update_sources)" | grep -c . || true)
    _selftest_assert_eq "源表展开后的条数与表里一致" "$_st_want" "$_st_one"
    if [ -n "$(update_source_id official)" ]; then _st2=1; else _st2=0; fi
    _selftest_assert_eq "official 给出非空仓库标识" "1" "$_st2"
    # 仓库标识取自 git remote，每种写法都必须给出同一个答案：路径的最后两段。
    # 用 ".*github\.com[:/]([^/]+)/([^/]+)" 这种贪婪正则看着没问题，直到 remote 带端口——
    # ssh://git@ssh.github.com:443/owner/repo 会返回 "443/owner"，查询地址指着不存在的仓库，
    # 最后报"发布方没提供这个包，请手动下载"：从一个好好的发布把用户支去错的下一步。
    _selftest_assert_eq "仓库标识：https" "owner/repo" "$(repo_id_from_remote_url 'https://github.com/owner/repo.git')"
    _selftest_assert_eq "仓库标识：https 无 .git" "owner/repo" "$(repo_id_from_remote_url 'https://github.com/owner/repo')"
    _selftest_assert_eq "仓库标识：scp 写法" "owner/repo" "$(repo_id_from_remote_url 'git@github.com:owner/repo.git')"
    _selftest_assert_eq "仓库标识：带端口的 ssh" "owner/repo" "$(repo_id_from_remote_url 'ssh://git@ssh.github.com:443/owner/repo.git')"
    _selftest_assert_eq "仓库标识：尾部斜杠不算" "owner/repo" "$(repo_id_from_remote_url 'https://github.com/owner/repo/')"
    _selftest_assert_eq "仓库标识：不是 GitHub 就不算" "" "$(repo_id_from_remote_url 'https://gitlab.com/owner/repo.git')"
    _selftest_assert_eq "仓库标识：本地路径不算" "" "$(repo_id_from_remote_url '/somewhere/repo')"
    _selftest_assert_eq "仓库标识：空地址不算" "" "$(repo_id_from_remote_url '')"

    # 失败原因分类：下载失败的原因决定用户该做什么（等一小时 / 开代理 / 手动下载 / 修磁盘），
    # 全塌缩成一个"失败"字符串就等于把判断责任推给使用者。
    _selftest_assert_eq "失败分类：404 是发布没提供该文件" "missing" "$(update_failure_kind 404 '')"
    _selftest_assert_eq "失败分类：410 也是文件没了" "missing" "$(update_failure_kind 410 '')"
    _selftest_assert_eq "失败分类：429 是配额用尽" "quota" "$(update_failure_kind 429 '')"
    _selftest_assert_eq "失败分类：403 且配额剩 0 是配额用尽" "quota" "$(update_failure_kind 403 0)"
    _selftest_assert_eq "失败分类：403 但还有配额是被拒绝" "server" "$(update_failure_kind 403 42)"
    _selftest_assert_eq "失败分类：403 读不到配额头算被拒绝" "server" "$(update_failure_kind 403 '')"
    _selftest_assert_eq "失败分类：5xx 是服务端问题" "server" "$(update_failure_kind 503 '')"
    _selftest_assert_eq "失败分类：其它状态码按连不上处理" "network" "$(update_failure_kind 418 '')"
    # 多个原因里挑一个报：只有"全都是 missing"才报 missing。中间设备被墙时会对什么都回 404，
    # 404 旁边还有个超时就报"发布漏了包"等于冤枉维护者。
    _selftest_assert_eq "挑原因：单个原样报出" "missing" "$(select_update_failure_kind missing)"
    _selftest_assert_eq "挑原因：两个相同合并成一个" "missing" "$(select_update_failure_kind missing missing)"
    _selftest_assert_eq "挑原因：404 旁边的超时报超时" "network" "$(select_update_failure_kind missing network)"
    _selftest_assert_eq "挑原因：404 旁边的配额报配额" "quota" "$(select_update_failure_kind missing quota)"
    _selftest_assert_eq "挑原因：临时目录不可写比超时更该先说" "local" "$(select_update_failure_kind network local)"
    _selftest_assert_eq "挑原因：没有原因时退回连不上" "network" "$(select_update_failure_kind '')"
    # 词表的顺序就是报告优先级：加一个原因不能悄悄改掉建议的先后，
    # 而 missing（指控发布方）必须排在最后。
    _ufk_n=$(printf '%s\n' $UPDATE_FAILURE_KINDS | grep -c . || true)
    _selftest_assert_eq "失败词表：每个原因只出现一次" "6" "$(printf '%s\n' $UPDATE_FAILURE_KINDS | sort -u | grep -c . || true)"
    _selftest_assert_eq "失败词表：本机问题排第一" "local" "$(printf '%s\n' $UPDATE_FAILURE_KINDS | head -n 1)"
    _selftest_assert_eq "失败词表：缺包排最后" "missing" "$(printf '%s\n' $UPDATE_FAILURE_KINDS | tail -n 1)"
    # 提示必须给出下一步动作，否则用户还是得自己猜。
    _ufm_m=$(update_failure_message missing GitHub)
    _ufm_q=$(update_failure_message quota GitHub)
    _ufm_n=$(update_failure_message network GitHub)
    _ufm_l=$(update_failure_message local GitHub)
    _selftest_assert_contains "提示：缺包要说手动下载" "手动下载" "$_ufm_m"
    _selftest_assert_contains "提示：配额要说会随时间恢复" "重试" "$_ufm_q"
    _selftest_assert_contains "提示：连不上要说开代理" "代理" "$_ufm_n"
    _selftest_assert_contains "提示：本机问题要说磁盘与权限" "磁盘" "$_ufm_l"
    _selftest_assert_eq "提示：没有一种说法会声称成功" "0" "$(for _k in missing quota server network bad-content local; do update_failure_message "$_k" GitHub; done | grep -c '成功' || true)"

    # ==========================================================================
    # 端口枚举失败 = 这一轮不知道，不是"没有端口"
    # ==========================================================================
    # 读不出来却被当成空表，状态机会判 off -> 把用户的代理环境变量删掉。
    # 与 Windows 侧同形：枚举失败要传上去，状态机据此沿用上一状态。
    _st_broken="$_sandbox/brokenbin"
    mkdir -p "$_st_broken" 2>/dev/null || true
    printf '#!/bin/sh\nexit 127\n' > "$_st_broken/lsof" 2>/dev/null || true
    printf '#!/bin/sh\nexit 127\n' > "$_st_broken/netstat" 2>/dev/null || true
    chmod +x "$_st_broken/lsof" "$_st_broken/netstat" 2>/dev/null || true
    if [ -x "$_st_broken/lsof" ] && [ -x "$_st_broken/netstat" ]; then
        _st_oldpath="$PATH"
        PATH="$_st_broken:$PATH"
        export PATH
        _st_ports=$(get_listening_ports)
        _st_rc=$?
        _selftest_assert_eq "端口枚举读不出来时返回非 0（不能当成空表）" "1" "$_st_rc"
        # 状态判定在枚举失败时要沿用上一状态：get_current_state 返回非 0。
        # 这一步必须在坏掉的 PATH 下做（枚举要真的失败）。
        CACHED_PORT=""
        get_current_state
        _st_state_rc=$?
        # 状态对齐在枚举失败时也必须什么都不做：调用方拿到"不知道"，
        # 就不能按"没代理"去删用户的代理变量。
        _st_align_rc=0
        align_state_once >/dev/null 2>&1 || _st_align_rc=$?
        PATH="$_st_oldpath"
        export PATH
        _selftest_assert_eq "枚举失败时状态判定返回非 0（上层据此沿用上一状态）" "1" "$_st_state_rc"
        _selftest_assert_eq "枚举失败时状态对齐不做任何改动" "1" "$_st_align_rc"
    else
        echo "  SKIP 造不出坏掉的 lsof/netstat 桩（权限或文件系统不支持）"
    fi

    # 入口参数守卫：多余的参数、别处用的 --purge，都要报用法错误（退出码 2），
    # 不许静默进入监控模式。两道守卫都在分派之前触发，所以这两个调用不会真的装/删任何东西。
    _sg_rc=0
    /bin/bash "$SCRIPT_PATH" install --purge >/dev/null 2>&1 || _sg_rc=$?
    _selftest_assert_eq "入口：--purge 用在 uninstall 以外要报用法错误" "2" "$_sg_rc"
    _sg_rc=0
    /bin/bash "$SCRIPT_PATH" status extra >/dev/null 2>&1 || _sg_rc=$?
    _selftest_assert_eq "入口：多余的位置参数要报用法错误" "2" "$_sg_rc"
    # 空参数不等于"没传参数"：前者是参数写错（退出码 2），后者才是监控模式。
    _sg_rc=0
    /bin/bash "$SCRIPT_PATH" "" >/dev/null 2>&1 || _sg_rc=$?
    _selftest_assert_eq "入口：空参数要报用法错误（不能当成没传参数）" "2" "$_sg_rc"
    # 用法判定是纯函数（base 层 usage_error，两端同形），两个方向都要钉住：
    # "必须拒"不许放过，"必须放行"不许误伤。
    # "放行"这一向只能在这里测：真跑一次入口就会真的卸载或更新，副作用落在用户机器上。
    _ue_check() {
        # $1=命令 $2=命令个数 $3=开关 $4=多余参数；输出退出码（0=放行，1=拒）
        USAGE_COMMAND="$1"; USAGE_COMMAND_COUNT="$2"; USAGE_SWITCHES="$3"; USAGE_EXTRA="$4"
        usage_error >/dev/null 2>&1
        return $?
    }
    _ue_check "status" 1 "" ""; _selftest_assert_eq "用法判定：普通命令放行" "0" "$?"
    _ue_check "" 0 "" ""; _selftest_assert_eq "用法判定：无命令（监控模式）放行" "0" "$?"
    _ue_check "uninstall" 1 "purge" ""; _selftest_assert_eq "用法判定：卸载带 --purge 放行" "0" "$?"
    _ue_check "update" 1 "yes" ""; _selftest_assert_eq "用法判定：更新带 --yes 放行" "0" "$?"
    _ue_check "install" 1 "purge" ""; _selftest_assert_eq "用法判定：--purge 跟着别的命令要拒" "1" "$?"
    _ue_check "status" 1 "yes" ""; _selftest_assert_eq "用法判定：--yes 跟着别的命令要拒" "1" "$?"
    _ue_check "status" 1 "" "--foo"; _selftest_assert_eq "用法判定：不认识的参数要拒" "1" "$?"
    _ue_check "install" 2 "" ""; _selftest_assert_eq "用法判定：一次给两个命令要拒" "1" "$?"

    # 带开关的一次性命令不能被当成监控：
    # 判据是脚本路径之后的第一个词，不是最后一个词。
    _selftest_assert_eq "带开关的一次性命令不是监控: uninstall --purge" "1" "$(is_monitor_args "/bin/bash $SCRIPT_PATH uninstall --purge" && echo 0 || echo 1)"
    _selftest_assert_eq "带开关的一次性命令不是监控: update --yes" "1" "$(is_monitor_args "/bin/bash $SCRIPT_PATH update --yes" && echo 0 || echo 1)"
    _selftest_assert_eq "带开关的一次性命令不是监控: install --purge" "1" "$(is_monitor_args "/bin/bash $SCRIPT_PATH install --purge" && echo 0 || echo 1)"

    # ==========================================================================
    # 资产解析契约：同一批应答，两侧必须得出同一个结论
    # ==========================================================================
    # 用例放在 tests/asset-cases.txt（仓库内文件；安装包里没有这一份，
    # 所以找不到就跳过——自检在安装副本里也要能跑）。
    # 每一行还打印成 "contract ..."，门禁 10 把两边的这些行互相比一次：
    # 文本层面的门禁看不出行为漂移，行为层面才看得出来。
    _st_cases="$SCRIPT_DIR/../tests/asset-cases.txt"
    if [ -f "$_st_cases" ]; then
        _st_seen=0
        while IFS='|' read -r _st_name _st_scope _st_id _st_digest _st_fail _st_body; do
            case "$_st_name" in ""|'#'*) continue ;; esac
            get_asset_from_json "$_st_body" "EnvProxy-test.zip"
            _st_got_id="$ASSET_ID"
            _st_got_digest="$ASSET_DIGEST"
            _st_got_fail=""
            if [ -z "$ASSET_ID" ]; then
                _st_got_fail=$(asset_failure_from_scope "$ASSET_SCOPE")
            fi
            _selftest_assert_eq "资产契约 正文种类: $_st_name" "$_st_scope" "$ASSET_SCOPE"
            _selftest_assert_eq "资产契约 编号: $_st_name" "$_st_id" "$_st_got_id"
            _selftest_assert_eq "资产契约 校验值: $_st_name" "$_st_digest" "$_st_got_digest"
            _selftest_assert_eq "资产契约 失败原因: $_st_name" "$_st_fail" "$_st_got_fail"
            echo "contract $_st_name $ASSET_SCOPE $_st_got_id $_st_got_digest $_st_got_fail"
            _st_seen=$((_st_seen + 1))
        done < "$_st_cases"
        _selftest_assert_eq "资产契约 用例都跑到了" "20" "$_st_seen"
    else
        echo "  SKIP 找不到 tests/asset-cases.txt（仓库内的用例文件）"
    fi

    # 入口的参数与退出码：两侧同一套，门禁 10 把两边的这些行互相比一次。
    # 用例都不碰用户文件：状态只读；非法参数在动手之前就被拦下。
    _eg_case() {
        _eg_name="$1"; _eg_want="$2"; shift 2
        _eg_rc=0
        /bin/bash "$SCRIPT_PATH" "$@" >/dev/null 2>&1 || _eg_rc=$?
        _selftest_assert_eq "入口退出码: $_eg_name" "$_eg_want" "$_eg_rc"
        echo "entry $_eg_name $_eg_rc"
    }
    _eg_case unknown-arg 2 bogus
    _eg_case extra-positional 2 status extra
    _eg_case purge-misuse 2 install --purge
    _eg_case switch-without-command 2 --yes
    _eg_case unknown-switch 2 status --foo
    _eg_case two-commands 2 install uninstall

    rm -rf "$_sandbox" 2>/dev/null || true
    if [ "$_selftest_fails" -eq 0 ]; then
        echo "自检全部通过"
        return 0
    fi
    echo "自检失败：$_selftest_fails 项"
    return 1
}

# 更新收尾不需要单独的子命令：覆盖完成后由更新入口 exec 安装根里的新脚本跑 install
# （从安装根执行，路径记录/自启动/监控才会落在安装根）。

# ------------------------------------------------------------------------------
# 10. 子命令
# ------------------------------------------------------------------------------
install_envproxy() {
    echo "======== EnvProxy 安装 (macOS) ========"
    if [ "$(id -u 2>/dev/null)" = "0" ]; then echo "当前是 root 身份：接下来改的会是 root 这个账号的配置。日常使用请用普通终端重来一次。"; fi
    # 先说清楚要动什么、不动什么，再说"正在做"——用户在按完编号之后得先知道会发生什么，
    # 而不是盯着静止的屏幕猜。
    echo "会改这 4 处：开机自启、终端配置、环境变量、后台监控。"
    echo "不会动你的其他设置。"
    echo ""
    # 首次安装的判据要在写路径记录**之前**取：写完这台机器上就有记录了，再判永远是"重装"。
    # 差别在于本机地址的代理变量算谁的——首次安装时它只可能是使用者自己的。
    if [ -f "$PATH_CONF" ]; then _first=0; else _first=1; fi
    # 先快照用户原值：之后卸载时按它还原，覆盖前留底。
    snapshot_prev_env "$_first" || true
    echo "[1/4] 正在写开机自启……"
    if set_autorun; then
        echo "[1/4] 开机自启动：已写入"
    else
        echo "[1/4] 开机自启动：写入失败，请检查 ~/Library/LaunchAgents 是否可写"
    fi
    echo "[2/4] 正在写终端配置……"
    if insert_shell_hooks; then
        echo "[2/4] 终端同步：已在终端的启动配置里写入（zsh/bash，新开终端生效；fish 不支持）"
    else
        echo "[2/4] 终端同步：写入失败，请检查 ~/.zshenv 是否可写"
    fi
    update_path_record
    echo "[3/4] 正在启动后台监控……"
    if start_monitor 1; then
        echo "[3/4] 监控进程：已启动"
    else
        echo "[3/4] 监控进程：未能确认运行，原因见上面那两行"
    fi
    # 枚举失败时这一轮是"不知道"：不动环境变量（与监控主循环同一条规则）。
    # 不管成没成就按预设的 off 去应用，等于把"读不出来"当成"代理没了"。
    # 这一步也要报进度：它是"会改这 4 处"里的第 4 处（环境变量），
    # 不报的话用户只数到 3 步，会以为环境变量那步被跳过了。
    echo "[4/4] 正在确认翻墙软件在不在（有端口、是代理、真能连出去）……"
    if align_state_once >/dev/null 2>&1; then
        echo "[4/4] 环境变量：已按当前状态校正"
    else
        # 读不出来 ≠ 没有代理：这一轮什么都没改，如实说明（与 Windows 侧同口径）。
        echo "[4/4] 环境变量：这一轮没读到本机端口，所以没有改动任何设置（正常，会自动重试）。"
    fi
    echo ""
    # 联网对比版本要一两秒：先说一声，别让最后这一步又变成静默等待。
    echo "正在联网确认有没有新版本……"
    show_status
    echo ""
    echo "提示：之后新开的终端/程序自动获得代理；"
    echo "      已经开着的窗口敲一下回车就会跟上，退出翻墙软件后同样。"
    echo "      想让某个窗口固定直连：在它里面执行 export ENVPROXY_TERM=off"
    echo "      （改回跟着翻墙软件走：unset ENVPROXY_TERM）。"
}

uninstall_envproxy() {
    _purge="$1"
    echo "======== EnvProxy 卸载（一键恢复原状）========"
    if [ "$(id -u 2>/dev/null)" = "0" ]; then echo "当前是 root 身份：接下来改的会是 root 这个账号的配置。日常使用请用普通终端重来一次。"; fi
    stop_monitor || true
    remove_autorun
    # prompt-sync.sh 是我们装到固定位置的实现，卸载时一并清掉；
    # remove_shell_hooks 随后摘掉 rc 里那一行（标记块精确移除，用户其余内容不动）。
    rm -f "$LOCATOR_PATH" "$PATH_CONF" "$ENVPROXY_HOME/prompt-sync.sh" 2>/dev/null || true
    remove_shell_hooks
    _remove_log=0
    if [ "$_purge" = "1" ]; then
        _remove_log=1
    else
        printf "历史日志 monitor/monitor.log 是否保留？[Y] 保留（默认） / [N] 彻底删除: "
        _choice=""
        if read -r _choice < /dev/tty 2>/dev/null; then :; else _choice=""; fi
        case "$_choice" in [Nn]*) _remove_log=1;; *) _remove_log=0;; esac
    fi
    if [ $_remove_log -eq 1 ]; then
        rm -rf "$MONITOR_DIR" 2>/dev/null || true
    else
        rm -f "$PID_FILE" "$STOP_FLAG" 2>/dev/null || true
        if [ -d "$MONITOR_DIR" ] && [ -z "$(ls -A "$MONITOR_DIR" 2>/dev/null)" ]; then
            rm -f "$PID_FILE" "$STOP_FLAG" 2>/dev/null || true
        fi
    fi
    _ghost=$(get_monitor_pid || true)
    if [ -n "$_ghost" ]; then kill -9 "$_ghost" 2>/dev/null || true; sleep 0.5; fi
    # Mac 侧写变量无 Win 式进程内写锁：靠前面先停监控把竞态窗口收到最小（单实例文件锁另保安装互斥）。
    remove_user_env_vars
    # 按安装时的快照还用户原值（若有），还完删掉快照。
    restore_prev_env || true
    # launchd 的两个重定向文件（StandardOutPath/StandardErrorPath）是运行时管道，不是黑匣子：
    # 一律清掉，"恢复到安装前的状态"才成立。唯一的黑匣子是 monitor/monitor.log，
    # 它的去留由上面那次询问决定。
    rm -f "$ENVPROXY_HOME/monitor.stdout.log" "$ENVPROXY_HOME/monitor.stderr.log" 2>/dev/null || true
    # owned.env 记的是"我们写下的值"，卸载后没有意义；留着会让下面那句 rmdir 判不出空目录。
    rm -f "$OWNED_ENV" "$PROXY_ENV" 2>/dev/null || true
    # 非 purge 也只保留项目内日志：固定目录空了就删，不留空壳
    if [ -d "$ENVPROXY_HOME" ] && [ -z "$(ls -A "$ENVPROXY_HOME" 2>/dev/null)" ]; then
        rmdir "$ENVPROXY_HOME" 2>/dev/null || true
    fi
    # 卸载末尾回读复检：上面每一步都可能静默失败，定论必须由复读结果决定。
    # DIVERGE(Mac): 复检项按平台映射——plist 对应 Windows 的 Run 键，
    # proxy.env 对应注册表变量，其余同源。
    _dirty=""
    if launchctl list 2>/dev/null | grep -qF "$PLIST_LABEL"; then _dirty="$_dirty 开机自启动项仍在；"; fi
    if [ -f "$PLIST_PATH" ]; then _dirty="$_dirty 自启动文件仍在；"; fi
    if [ -f "$ENVPROXY_HOME/prompt-sync.sh" ]; then _dirty="$_dirty 终端同步脚本仍在；"; fi
    if [ -f "$LOCATOR_PATH" ]; then _dirty="$_dirty 定位器文件仍在；"; fi
    if [ -f "$PROXY_ENV" ]; then _dirty="$_dirty 代理变量文件仍在；"; fi
    if [ -f "$PREV_ENV" ]; then _dirty="$_dirty 变量快照仍在；"; fi
    if [ -f "$PATH_CONF" ]; then _dirty="$_dirty 路径记录仍在；"; fi
    if [ -f "$ENVPROXY_HOME/monitor.stdout.log" ] || [ -f "$ENVPROXY_HOME/monitor.stderr.log" ]; then _dirty="$_dirty 自启动重定向残留；"; fi
    # hook 名单与 remove_shell_hooks 同一份（改一边必须改另一边）：残留整块即脏。
    for _rc in "$HOME/.zshenv" "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zlogin" "$HOME/.bash_profile" "$HOME/.bashrc"; do
        if grep -qxF "$HOOK_START" "$_rc" 2>/dev/null; then _dirty="$_dirty shell hook 残留；"; break; fi
    done
    if proxy_vars_present 2>/dev/null; then _dirty="$_dirty 代理变量仍在；"; fi
    if [ -n "$(get_monitor_pid || true)" ]; then _dirty="$_dirty 监控进程仍在；"; fi
    if [ $_remove_log -eq 1 ] && [ -f "$LOG_FILE" ]; then _dirty="$_dirty 历史日志未能删除；"; fi
    if [ -z "$_dirty" ]; then
        echo "[完成] 监控已停，开机自启、代理变量和定位用的小脚本都已删除。"
        if [ $_remove_log -eq 1 ]; then
            echo "        历史日志已一并彻底删除。"
        else
            echo "        历史日志保留在 monitor/monitor.log（黑匣子，供日后排查）。"
        fi
        echo "        电脑已恢复到安装前的状态，无需重启。"
    else
        echo "[未完成] 以下残留请手动处理：$_dirty"
        echo "        可再跑一次 uninstall，或手动删除上述位置。"
    fi
}

show_status() {
    echo "======== EnvProxy 状态 (macOS) ========"
    _m=$(get_monitor_pid || true)
      # 只看"launchd 里有这个 label"会说谎：卸载不彻底、或用户手删过 ~/.envproxy/ 时，
      # plist 还在、它要启动的 locator.sh 已经不在了，登录时什么都不会起来，
      # 状态页却仍报"已启用"。判据要和"能不能真的启动"一致：注册在，且那个文件真的存在。
      # 与 Windows 侧同口径（那边查的是 Run 键指向的脚本是否存在）。
      _autorun_ok=0
      if launchctl list 2>/dev/null | grep -qF "$PLIST_LABEL" && [ -f "$LOCATOR_PATH" ]; then
          _autorun_ok=1
      fi
    if [ -n "$_m" ]; then
        echo "监控进程 : 运行中 (PID $_m)"
    else
        echo "监控进程 : 未运行"
        # "停止"是一个稳定状态（自启动只在登录时拉起一次，不保活）。
        # 不说清这一点，用户会看到"自启已启用"和"监控未运行"并列，以为装坏了。
        [ "$_autorun_ok" = "1" ] && echo "           （已按你的选择停止，下次登录会自动恢复）"
    fi
      if launchctl list 2>/dev/null | grep -qF "$PLIST_LABEL"; then
          if [ "$_autorun_ok" = "1" ]; then
              echo "开机自启 : 已启用"
          else
              echo "开机自启 : 记录还在，但启动文件已不存在（登录时不会启动）"
              echo "           记录指向：$LOCATOR_PATH"
              echo "           打开菜单选 1（安装 / 修复）可以重建。"
          fi
      else
          if [ -f "$PLIST_PATH" ]; then echo "开机自启 : 已写入但未加载"; else echo "开机自启 : 未启用"; fi
      fi
    # 端口枚举读不出来 = 这一轮不知道有没有代理在运行，不能说成"没有代理"。
    # 只枚举一次（枚举两次之间状态可能变，两次结论可能自相矛盾）；
    # 深度与 Windows 侧一致：都只做快扫（全端口扫留给监控与诊断入口）。
    _cands=""
    _crc=0
    _cands=$(find_candidate_ports 0) || _crc=$?
    if [ "$_crc" -ne 0 ]; then
        echo "翻墙代理 : 这一轮没读到本机端口，无法判断（正常，会自动重试）"
    else
        _port=$(printf '%s' "$_cands" | awk '{print $1}')
        if [ -n "$_port" ]; then
            echo "翻墙代理 : 已开启（本地端口 $_port 监听中）"
        else
            echo "翻墙代理 : 未检测到（当前无翻墙代理在运行）"
        fi
    fi
    _cur=$(get_current_proxy_port 2>/dev/null || true)
    if [ -n "$_cur" ]; then echo "代理变量 : 已注入 (http://127.0.0.1:$_cur)"; else echo "代理变量 : 无（直连状态）"; fi
    # 只读提示：系统代理是浏览器的世界，不是我们写的，但用户常把它的毛病算到我们头上。
    # 若它指向本机死端口，浏览器全挂而终端正常——提醒一句，绝不动它。
    # 与 Win 侧 HKCU Internet Settings 那段同语义（读系统设置 → 试连 → 只在连不上时提醒）。
    _sp_info=$(scutil --proxy 2>/dev/null || true)
    if [ -n "$_sp_info" ]; then
        _sp_enable=$(printf '%s' "$_sp_info" | awk '/HTTPEnable *: *1/ {print 1; exit}')
        _sp_host=$(printf '%s' "$_sp_info" | awk '/HTTPProxy *: */ {sub(/.*: */, ""); print; exit}')
        _sp_port=$(printf '%s' "$_sp_info" | awk '/HTTPPort *: */ {sub(/.*: */, ""); print; exit}')
        if [ "$_sp_enable" = "1" ] && [ "$_sp_host" = "127.0.0.1" ] && [ -n "$_sp_port" ]; then
            # "在听"还不够：多数翻墙软件的断开按钮不停内核，端口仍会应答。
            # 真连一次才分得清"活着"与"占着不放"（与 Win 侧 TcpClient 试连同口径）。
            _sp_alive=0
            if printf '' | nc -z -G 1 -w 1 127.0.0.1 "$_sp_port" 2>/dev/null; then _sp_alive=1; fi
            if [ "$_sp_alive" = "0" ]; then
                echo "系统代理 : 疑似残留（指向本机死端口 127.0.0.1:$_sp_port，非本工具写入）"
                echo "      浏览器打不开先检查它：系统设置 → 网络 → 代理，或把翻墙软件断开重进一次。"
            fi
        fi
    fi
    # 版本信息（只读：查不到只提示，不写文件、不提问）
    _local_ver=$(get_local_version || true)
    if [ -n "$_local_ver" ]; then echo "本地版本 : v$_local_ver"; else echo "本地版本 : 未知"; fi
    if get_remote_version; then
        echo "最新版本 : $REMOTE_TAG"
        if is_dev_copy; then
            echo "更新状态 : 开发副本（更新走 git pull，本入口不改动文件）"
        elif is_source_copy; then
            echo "更新状态 : 源码包（更新入口会先确认用途再动手）"
        elif [ -z "$_local_ver" ]; then
            echo "更新状态 : 可打开菜单选 3（检查更新）升级"
        else
            _newer=$(compare_versions "$_local_ver" "$REMOTE_VERSION" || true)
            if [ "$_newer" -gt 0 ] 2>/dev/null; then
                echo "更新状态 : 本地版本比最新发布版新"
            else
                _older=$(compare_versions "$REMOTE_VERSION" "$_local_ver" || true)
                if [ "$_older" -gt 0 ] 2>/dev/null; then
                    echo "更新状态 : 发现新版，用菜单 检查更新 可升级"
                else
                    echo "更新状态 : 已是最新"
                fi
            fi
        fi
    else
        # 状态显示也要说清是哪一类失败：笼统说"都不可达"会让用户以为是网络问题，
        # 而限流（等一小时）、缺包（手动下载）要做的动作完全不同。
        echo "最新版本 : 检查失败（$(update_failure_message "${REMOTE_FAILURE_KIND:-network}" "所有更新源")）"
        echo "更新状态 : 未知"
    fi
    echo "---------------- 最近日志 ----------------"
    if [ -f "$LOG_FILE" ]; then
        tail -n 3 "$LOG_FILE" 2>/dev/null | sed 's/^/  /' || echo "  （暂无日志）"
    else
        echo "  （暂无日志）"
    fi
    echo "=================================="
}

# ------------------------------------------------------------------------------
# 菜单（唯一双击入口"打开菜单"背后：编号→现有子命令，不新增行为）
# 菜单只做三件事：打印、读编号、起子进程跑对应子命令后回到菜单。
# 每个动作都走一遍入口子命令的完整路径（含操作锁）：菜单自己不拿锁，
# 所以菜单里的 bug 最多影响菜单显示，动不了安装区。每个选项与入口子命令一一对应。
# 非交互环境（stdin 不是终端）直接退出并提示，不死循环。
# 帮助：纯打印，不改任何状态。给"忘了怎么用"的时候看。
# 内容与 Windows 侧 Show-Help 同形（两端同文案，只换命令写法），自检会查关键词。
# 帮助的内容表：每个主题一屏放得下，进帮助先看目录，选一个只看那一段。
# 为什么这么分：一次性把十几屏内容全刷出来，看到后面已经忘了前面讲什么；
# 按"我此刻想解决什么"分主题，再配一个固定的返回行，用户随时能退回来换一段看。
# 每一项用目录（dir）/ 正文（topic 函数）两处拼装，键与标题只写一次。
HELP_TOPIC_KEYS=(1 2 3 4 5 6 7)
_help_topic_short() {
    case "$1" in
        1) echo "用处" ;;
        2) echo "装完" ;;
        3) echo "窗口" ;;
        4) echo "命令" ;;
        5) echo "菜单" ;;
        6) echo "连不上" ;;
        7) echo "不行" ;;
        *) echo "" ;;
    esac
    return 0
}

# 主题页底部那一行：把全部编号和短名并排列出来，当前这条用方括号标。
# 为什么需要它：用户在主题里只看到「输编号看别的」，却不知道别的编号是几号——
# 那句话等于白说。列出来既回答了"编号是什么"，也顺手回答了"还有哪几条"。
# 编号与短名都从 HELP_TOPIC_KEYS 取，加一条主题时这里自动跟上。
format_help_nav_line() {
    _hnl_cur="$1"
    _hnl_out="  "
    for _hnl_k in "${HELP_TOPIC_KEYS[@]}"; do
        if [ "$_hnl_k" = "$_hnl_cur" ]; then
            _hnl_out="$_hnl_out[$_hnl_k]$(_help_topic_short "$_hnl_k")  "
        else
            _hnl_out="$_hnl_out$_hnl_k $(_help_topic_short "$_hnl_k")  "
        fi
    done
    printf "%s\n" "${_hnl_out%  }"
}

# 可用的编号范围，从表里算：加一条主题就自动变成 "有 1-8"，不会留下写死的旧范围。
# 菜单可用的编号，从表里算：加一项就自动变成 "1-6 和 0"，不会留下写死的旧范围。
# 和帮助的 format_help_key_range 同一个思路——改数字的地方只该有一处。
get_menu_key_range() {
    _mkr_keys=""
    _mkr_quit=""
    for _mkr_i in "${MENU_ITEMS[@]}"; do
        _mkr_k=${_mkr_i%%|*}
        _mkr_sw=${_mkr_i##*|}
        if [ -n "$_mkr_sw" ]; then
            _mkr_keys="$_mkr_keys $_mkr_k"
        else
            _mkr_quit="$_mkr_quit $_mkr_k"
        fi
    done
    set -- $_mkr_keys
    if [ $# -eq 0 ]; then echo "没有可用的编号"; return 0; fi
    _mkr_first=$1
    eval "_mkr_last=\${$#}"
    _mkr_text="$_mkr_first-$_mkr_last"
    if [ -n "$_mkr_quit" ]; then _mkr_text="$_mkr_text 和$_mkr_quit"; fi
    echo "$_mkr_text"
}

format_help_key_range() {
    _hkr_n=${#HELP_TOPIC_KEYS[@]}
    if [ "$_hkr_n" -eq 0 ]; then echo "没有可用的编号"; return 0; fi
    if [ "$_hkr_n" -eq 1 ]; then echo "只有 ${HELP_TOPIC_KEYS[0]}"; return 0; fi
    echo "有 ${HELP_TOPIC_KEYS[0]}-${HELP_TOPIC_KEYS[$((_hkr_n - 1))]}"
}
_help_topic_title() {
    case "$1" in
        1) echo "这是干什么用的" ;;
        2) echo "装完之后要我做什么" ;;
        3) echo "我要单独设置某个窗口" ;;
        4) echo "我要让某条命令不走代理" ;;
        5) echo "菜单每一项是干什么的" ;;
        6) echo "装了还是连不上网 / 状态不对" ;;
        7) echo "还是不行 / 想删掉它" ;;
        *) echo "" ;;
    esac
    return 0
}

# 单个主题的正文。用 cat 输出，与 Windows 侧 Get-HelpTopics 的 Lines 一一对应。
_help_topic_body() {
    case "$1" in
    1) cat <<'TOPIC'
它做什么
  翻墙软件一开，终端里的 git、npm、curl 就能翻墙；
  一关，它们自动恢复直连。不用记任何开关。

它怎么判断你现在在翻墙
  每 2 到 3 秒看一次。要同时满足三条才算：
    1. 本机有端口在监听；
    2. 它确实是个代理，会回应握手；
    3. 它确实连得通外面，试 7 个站点任意一个通就算。
  三条全过才写变量。所以本机开着网页服务、开发服务器都不会被误判。
  它不认品牌、不认进程名、不认端口号，那些只用来加快扫描。
TOPIC
    ;;
    2) cat <<'TOPIC'
装完之后，按窗口分三种情况

  1. 装完之后才打开的窗口
     启动时读到的就是当前状态，什么都不用做。

  2. 装完之后打开的窗口，后来代理又变了
     按一次回车即可。

  3. 装之前就已经开着的窗口
     同步代码还没装进去。输入下面这条，或者重开窗口：
         . ~/.envproxy/prompt-sync.sh

为什么要按一次回车
  每个程序只在启动那一刻读一次环境变量，读完就固定了。之后系统改了，
  已经在跑的窗口不会跟着变。EnvProxy 挑的时机是每次命令跑完、
  等你回到能打字的状态时同步——你本来就一直在敲命令，不用专门做什么。
TOPIC
    ;;
    3) cat <<'TOPIC'
Mac 只有一个终端（默认 zsh，bash 也行）。fish 不支持：它不读 .zshenv。

一、让这个窗口固定直连（不再自动跟随）
      export ENVPROXY_TERM=off
  窗口一关就失效。想恢复自动跟随，输入：
      unset ENVPROXY_TERM

二、走公司代理（两步，顺序不能反）
  1. 先按上面固定直连。
  2. 再设地址，输入：
      export HTTPS_PROXY=http://127.0.0.1:7890
  不停掉自动跟随的话，翻墙软件一有变化就会覆盖你刚设的地址。

三、看这个窗口现在走不走代理
      echo $HTTPS_PROXY

四、让已经开着的窗口立刻跟上，输入：
      . ~/.envproxy/prompt-sync.sh
  四点注意：
    1. 开头的点号和后面的空格都不能少
    2. 只对 zsh 和 bash 有效（fish 不支持）
    3. 只影响这一个窗口，别的已开窗口要各自执行，或者重开
    4. 从没装过 EnvProxy 的窗口里这个文件不存在，看到「找不到」是正常的。
       重开窗口就行。
TOPIC
    ;;
    4) cat <<'TOPIC'
不同工具写法不一样，没有通用的一条命令

curl
      curl --noproxy '*' 网址

git
      git -c http.proxy= -c https.proxy= clone 仓库地址
  等号后留空 = 这条不用代理；写别的值 = 改用那个代理。

npm
      npm --noproxy=registry.npmjs.org install 包名
  注意：noproxy 只认域名，写 * 没用，而且不报错，请求照常走代理。
  写成 --no-proxy 会被理解成 --proxy=false，也不是你要的效果。
  另外 npm 只认 HTTPS_PROXY，不认 HTTP_PROXY。

wget
      wget --no-proxy 网址

docker
  没有单条命令的写法，改 Docker 自己的设置（Docker Desktop 里的 Proxies）。
TOPIC
    ;;
    5) cat <<'TOPIC'
这些编号要在主菜单里敲，不是在帮助里敲。

日常（平时只会用到这四个）
  1  安装 / 修复    第一次用选它；觉得不对劲也选它
  2  查看状态      现在什么情况，一眼看清
  3  检查更新      有新版先告诉你改了什么，同意才装
  4  帮助          就是这里

维护（要动它之前才用）
  5  停止监控      先停掉，下次开机自己回来
  6  一键恢复      彻底卸载，回到没装之前

退出
  0  退出          什么都不做。直接按回车等于选 2
TOPIC
    ;;
    6) cat <<'TOPIC'
连不上网，按这个顺序查
  1. 先在那个窗口里看变量有没有值：echo $HTTPS_PROXY
     空的就是没注入——多半是那个窗口在装之前就开着了，重开一个窗口。
  2. 有值还是连不上：看菜单顶上的「监控」是不是未运行。
     未运行就选 1（安装 / 修复）。
  3. npm 不认 HTTP_PROXY，只认 HTTPS_PROXY。EnvProxy 两个都写，
     但你要是自己清过变量，npm 就不走了。

状态页那几行怎么读
  监控进程    本工具的后台程序在不在跑。
  开机自启    下次登录会不会自动起来（和上面那行是两件事）。
  翻墙代理    本机有没有翻墙软件在监听端口。
  代理变量    这个工具有没有往终端里设代理。
  后两行可能一个「有」一个「无」：翻墙软件在跑、但本工具被你停了，
  就是这个样子，不是坏了。

日志和 AI 排查
       mac/monitor/monitor.log（上限 200KB，只留最近 200 行）。看不懂可以不看，
  反馈时附上最后 20 行就行。

  AI 可能报 ECONNREFUSED 127.0.0.1:端口号。那是变量指向了一个已关闭的端口，
  不是网络坏了。菜单选 2 看「代理变量」那行，它会直接说清是不是这里的问题。

  本工具只管 HTTP/HTTPS 变量。git、npm、curl、pip、docker 都认；
  ping、游戏、BT 这类走自己协议的不认——那些要开翻墙软件的 TUN 模式。
TOPIC
    ;;
    7) cat <<'TOPIC'
大部分问题都可以用「安装 / 修复」解决
  打开菜单选 1。它不会重复安装，不会中断网络，也不会丢失你的设置。

还是不行
  菜单选 2 把状态截图，再选 1 修复一次。反馈时附上 mac/monitor/monitor.log
  最后 20 行，能省很多来回。

想彻底删掉它
  菜单选 6（一键恢复）。会问你要不要留日志。

不开菜单也能用（适合写脚本，或远程连过来）
      install    status     stop        uninstall
      update     help       menu        uninstall --purge
  --purge 表示连日志一起删。完整写法：
      bash envproxy.sh status
TOPIC
    ;;
    esac
    return 0
}

# 帮助目录：只列标题，一屏放得下。
format_help_index() {
    _hi_hv=$(get_local_version 2>/dev/null || true)
    [ -z "$_hi_hv" ] && _hi_hv="未知"
    echo "================ EnvProxy 帮助 ================"
    echo ""
    echo "  按你遇到的问题挑一条："
    echo ""
    for _hi_k in "${HELP_TOPIC_KEYS[@]}"; do
        echo "    $_hi_k  $(_help_topic_title "$_hi_k")"
    done
    echo ""
    echo "  本机版本 v$_hi_hv"
    echo ""
    echo "  输编号查看    直接回车 = 回主菜单"
}

# 单个主题：正文前后各留一行，底部固定给返回方式。
format_help_topic() {
    _ht_title=$(_help_topic_title "$1")
    [ -z "$_ht_title" ] && return 1
    echo "================ 帮助 $1 · $_ht_title ================"
    echo ""
    _help_topic_body "$1"
    echo ""
    format_help_nav_line "$1"
    echo "  输编号看别的    直接回车 = 回目录"
    return 0
}

# 屏幕刷新：菜单与帮助都是"一屏一页"，切换时清屏。
# 只在真有终端时清：没有终端时 clear 会往输出里塞控制字符，把日志刷脏。
clear_screen_safe() {
    [ -t 1 ] || return 0
    clear 2>/dev/null || true
}

# 判断一行该用什么颜色。只看行的形状，文案改了配色自动跟上。
#   顶格且短 -> 小标题（青）
#   缩进 4 格以上且像命令 -> 命令（绿）
#   以 注意/为什么/必须 开头 -> 提醒（黄）
#   其余 -> 正文（默认色，终端里就是灰白）
_help_line_color() {
    _hlc_line="$1"
    [ -z "$_hlc_line" ] && { echo ""; return 0; }
    # 数前导空格
    _hlc_ind=0
    _hlc_rest="$_hlc_line"
    while [ "${_hlc_rest# }" != "$_hlc_rest" ]; do
        _hlc_ind=$((_hlc_ind + 1))
        _hlc_rest="${_hlc_rest# }"
    done
        if [ "$_hlc_ind" -eq 0 ]; then
            # 顶格、且不像一句完整的话 = 小标题。
            # 判据用结构而不是长度：${#var} 与 wc -m 数的是字节还是字符取决于 locale，
            # C locale 下一个汉字顶 3，同一条标题会一会儿上色一会儿不上色。
            # 句末有标点、或句中有句号，说明它是正文而不是标题——与 Win 侧同一判据。
            case "$_hlc_rest" in
                *。|*；|*，) echo ""; return 0;;
                *。*) echo ""; return 0;;
            esac
            echo "36"
            return 0
        fi
    case "$_hlc_rest" in
        注意*|别*|不要*|小心*) echo "33"; return 0;;
    esac
    # 命令行 = 缩进 4 格以上，且这一行没有任何中日韩字符。
    # 判据不能是"看起来像不像命令"：只要允许中英混排，「cmd 和 Git Bash 没这个开关」
    # 这种说明就会因为开头是字母而被染成命令色。颜色一错，整屏就显得乱，而且会
    # 把"能整行复制去跑的一行"和"只是提到命令的一行"混成同一种视觉。
    # 反过来这条也给内容立了规矩：命令行必须能整行复制去跑，中文说明另起一行。
    if [ "$_hlc_ind" -ge 4 ]; then
        # 白名单：命令行只该由 ASCII 字母、数字和常用命令标点组成。
        # 用黑名单（找非 ASCII）在 Git Bash / 各种 locale 下不可靠——同一个
        # 判断在 LC_ALL=C 与 UTF-8 下结果不同，纯 ASCII 行会被误判成含中文。
        if ! printf '%s' "$_hlc_rest" | grep -qvE "^[A-Za-z0-9 _./\\\\:=\$\x27\"*&;<>|?~,+%#@!()\-]*$"; then
            echo "32"; return 0
        fi
    fi
    echo "90"
    return 0
}

# 带配色地打一个主题。与 format_help_topic 分工：那个给纯文本（非交互与测试用），
# 这个负责上色。两者读同一份内容，不会出现"屏幕上有、文档里没有"。
show_help_topic_colored() {
    # 同 show_menu_colored：没终端就不上色，直接给纯文本。
    if [ ! -t 1 ]; then format_help_topic "$1"; return $?; fi
    _sht_title=$(_help_topic_title "$1")
    [ -z "$_sht_title" ] && return 1
    printf '\033[36m%s\033[0m\n' "================ 帮助 $1 · $_sht_title ================"
    echo ""
    _help_topic_body "$1" | while IFS= read -r _sht_l; do
        _sht_c=$(_help_line_color "$_sht_l")
        if [ -z "$_sht_c" ]; then
            printf '%s\n' "$_sht_l"
        else
            printf '\033[%sm%s\033[0m\n' "$_sht_c" "$_sht_l"
        fi
    done
    echo ""
    printf '\033[90m%s\033[0m\n' "$(format_help_nav_line "$1")"
    printf '\033[90m%s\033[0m\n' "  输编号看别的    直接回车 = 回目录"
    return 0
}

# 全文：把所有主题按顺序拼起来，一个字不少。
# 非交互调用（help 子命令被脚本/管道调用）走这条：调用方要的是一份完整文档，
# 分页导航对没有终端的场景没有意义。
format_help_all() {
    format_help_index
    for _ha_k in "${HELP_TOPIC_KEYS[@]}"; do
        echo ""
        format_help_topic "$_ha_k"
    done
}

# 帮助入口。
# 交互只有两种操作，和菜单完全一样：
#   输数字 = 去看那一条；直接回车 = 回上一级。
# 不用 n / p / m / a 这些字母：用户记不住哪个键管哪件事，
# 而"输编号"和"按回车"不需要学。条目不多，一屏列得下，也就没有翻页的必要。
# 非交互：直接给全文（与 Windows 侧 Show-Help -All 同一判据）。
show_help() {
    if [ ! -t 0 ]; then
        format_help_all
        return 0
    fi
    # $_hs_cur 为空 = 当前在目录页；非空 = 正在看那一条。
    # 用一种状态表达两页，换主题时才不会跳回目录。
    _hs_cur=""
    while true; do
        if [ -z "$_hs_cur" ]; then
            clear_screen_safe
            format_help_index
        fi
        printf "输编号，或直接回车："
        if ! IFS= read -r _hs_sel; then
            echo ""
            return 0
        fi
        _hs_sel=$(printf '%s' "$_hs_sel" | tr -d '[:space:]')
        if [ -z "$_hs_sel" ]; then
            # 回车：在主题里回目录，在目录里回主菜单。
            if [ -n "$_hs_cur" ]; then
                _hs_cur=""
                continue
            fi
            return 0
        fi
        # q 和 0 与「直接回车」同义：菜单里 q/0 都是退出，刚在菜单学会按 q 的人，
        # 进到帮助再按就被判成"没有这一条"，会以为帮助坏了。不写进屏幕，只是别拒绝他。
        case "$_hs_sel" in
            q|Q|0)
                if [ -n "$_hs_cur" ]; then _hs_cur=""; continue; fi
                return 0;;
        esac
        # 先查表、有效才清屏：输错时把当前这屏留在屏幕上，用户还能照着挑。
        if ! _help_key_valid "$_hs_sel"; then
            echo "没有这一条：$_hs_sel（$(format_help_key_range)）"
            continue
        fi
        clear_screen_safe
        show_help_topic_colored "$_hs_sel"
        _hs_cur="$_hs_sel"
    done
}

# 这个编号有没有对应的帮助主题。输错时用它来决定"要不要清屏"：
# 无效就保留当前屏（用户还要照着挑），有效才换屏。
_help_key_valid() {
    for _hkv_k in "${HELP_TOPIC_KEYS[@]}"; do
        [ "$_hkv_k" = "$1" ] && return 0
    done
    return 1
}

# 菜单表：编号 | 名称 | 说明 | 分组 | 子命令。打印与分派共用它，加一项就一定会显示出来。
# 分组只影响打印顺序；编号按使用频率从上往下连续排（1-4 日常、5-6 维护、0 退出）。
# 子命令为空表示"不跑任何东西"（退出项）。分派直接读这一列，
# 不许再另写一份 case——两份清单必然漂移，症状是"表里加了、点了没反应"。
# 格式固定为五个字段、四条竖线；少一条竖线字段会静默错位（菜单照常打印、不报错，
# 用户看到的却是错的内容）。所以下面带一道加载期校验，格式不对就当场报错。
MENU_ITEMS=(
    '1|安装 / 修复|第一次用选它；觉得不对劲也选它|日常|install'
    '2|查看状态|现在什么情况，一眼看清|日常|status'
    '3|检查更新|有新版先告诉改了什么，同意才装|日常|update'
    '4|帮助|忘了怎么用就看它|日常|help'
    '5|停止监控|先停掉，下次开机自己回来|维护|stop'
    '6|一键恢复|彻底卸载，回到没装之前|维护|uninstall'
    '0|退出||退出|'
)
# 加载期校验：每条必须恰好四条竖线，且键、名字、分组非空。不合格就报错（不静默降级）。
# 分组顺序从表里按首次出现推导，不再写死数组：加一个分组只改表。
# 打印与分派读同一份顺序。写死会在"表里有、数组里没有"时静默漏印一项，
# 而分派不看分组、照样能敲到它——用户看见的菜单和能敲的菜单就不是同一件事。
_menu_group_order() {
    _mgo_seen=""
    for _mgo_i in "${MENU_ITEMS[@]}"; do
        _mgo_g=$(printf '%s' "$_mgo_i" | cut -d'|' -f4)
        [ -z "$_mgo_g" ] && continue
        case " $_mgo_seen " in
            *" $_mgo_g "*) ;;
            *) _mgo_seen="$_mgo_seen $_mgo_g" ;;
        esac
    done
    printf '%s\n' "$_mgo_seen"
}

_menu_items_valid() {
    for _mv in "${MENU_ITEMS[@]}"; do
        # 数竖线：把非竖线字符全删掉，剩下的长度就是个数
        _bars=$(printf '%s' "$_mv" | tr -cd '|' | wc -c | tr -d ' ')
        if [ "$_bars" -ne 4 ]; then
            printf '菜单表格式错误（%s 个竖线，应为 4）：%s\n' "$_bars" "$_mv" >&2
            return 1
        fi
        case "${_mv%%|*}" in
            '') printf '菜单表格式错误（键为空）：%s\n' "$_mv" >&2; return 1 ;;
        esac
    done
    return 0
}

# 按编号从表里取出子命令。空表示退出项。取不到返回非零（调用方据此报"没有这个编号"）。
_menu_switch_for() {
    _msf_key="$1"
    for _msf_i in "${MENU_ITEMS[@]}"; do
        _msf_k=${_msf_i%%|*}
        [ "$_msf_k" != "$_msf_key" ] && continue
        _msf_rest=${_msf_i#*|}
        _msf_rest=${_msf_rest#*|}
        _msf_rest=${_msf_rest#*|}
        printf '%s' "${_msf_rest#*|}"
        return 0
    done
    return 1
}
_menu_cell_width() {
    _mcw_s="$1"
    _mcw_all=$(printf '%s' "$_mcw_s" | wc -c)
    _mcw_ascii=$(printf '%s' "$_mcw_s" | LC_ALL=C tr -dc '\000-\177' | wc -c)
    _mcw_multi=$((_mcw_all - _mcw_ascii))
    # 多字节字节数 / 3 得到汉字个数（本项目文案里没有 2 字节或 4 字节字符）
    _mcw_han=$((_mcw_multi / 3))
    _mcw_rest=$((_mcw_multi - _mcw_han * 3))
    printf '%s' $((_mcw_ascii + _mcw_han * 2 + _mcw_rest))
}

# 把文字补齐到指定宽度（按上面的显示宽度算）。
_menu_cell_pad() {
    _mcp_text="$1"
    _mcp_width="$2"
    _mcp_len=$(_menu_cell_width "$_mcp_text")
    _mcp_pad=$((_mcp_width - _mcp_len))
    [ "$_mcp_pad" -lt 0 ] && _mcp_pad=0
    printf '%s%*s' "$_mcp_text" "$_mcp_pad" ''
}

# 渲染整张菜单。打印与测试共用它：表里有什么，屏幕就有什么。
format_menu_text() {
    _fmt_w=0
    for _fi in "${MENU_ITEMS[@]}"; do
        _frest=${_fi#*|}
        _fname=${_frest%%|*}
        _fw=$(_menu_cell_width "$_fname")
        [ "$_fw" -gt "$_fmt_w" ] && _fmt_w="$_fw"
    done
    _fhpid=$(get_monitor_pid || true)
    _fhver=$(get_local_version || true)
    [ -z "$_fhver" ] && _fhver="未知"
    if [ -n "$_fhpid" ]; then _fhmon="运行中 (PID $_fhpid)"; else _fhmon="未运行"; fi
    echo "======== EnvProxy 菜单 (macOS) ========"
    echo "  监控 $_fhmon    版本 v$_fhver"
    # 分组顺序从表里按首次出现推导，不再写死：加一个分组只改表。
    _fg_groups=$(_menu_group_order)
    for _fg in $_fg_groups; do
        _fgfirst=1
        for _fi in "${MENU_ITEMS[@]}"; do
            _frest=${_fi#*|}
            _fname=${_frest%%|*}
            _frest2=${_frest#*|}
            _fhint=${_frest2%%|*}
            _fgrp=${_fi%|*}; _fgrp=${_fgrp##*|}
            [ "$_fgrp" != "$_fg" ] && continue
            if [ "$_fgfirst" = "1" ]; then
                echo ""
                echo "  $_fg"
                _fgfirst=0
            fi
            _fkey=${_fi%%|*}
            if [ -n "$_fhint" ]; then
                echo "    $_fkey  $(_menu_cell_pad "$_fname" "$_fmt_w")   $_fhint"
            else
                echo "    $_fkey  $_fname"
            fi
        done
    done
    echo ""
    echo "  输编号后回车执行    直接回车 = 查看状态"
}

# 带配色地打菜单。与 format_menu_text 分工：那个返回纯文本（非交互与测试用），
# 这个负责上色。两者读同一份 MENU_ITEMS，不会出现"屏幕上有、测试里没有"。
show_menu_colored() {
    # stdout 不是终端就退回纯文本：管道/重定向时转义序列会原样写进日志（实测 ^[[36m），
    # 既弄脏日志也没法给人看。纯文本版本本来就为这种场合准备（也在自检里被断言）。
    if [ ! -t 1 ]; then format_menu_text; return 0; fi
    _smc_w=0
    for _smc_i in "${MENU_ITEMS[@]}"; do
        _smc_rest=${_smc_i#*|}
        _smc_name=${_smc_rest%%|*}
        _smc_fw=$(_menu_cell_width "$_smc_name")
        [ "$_smc_fw" -gt "$_smc_w" ] && _smc_w="$_smc_fw"
    done
    _smc_pid=$(get_monitor_pid || true)
    _smc_ver=$(get_local_version || true)
    [ -z "$_smc_ver" ] && _smc_ver="未知"
    printf '\033[36m%s\033[0m\n' "======== EnvProxy 菜单 (macOS) ========"
    if [ -n "$_smc_pid" ]; then
        printf '\033[90m  监控 运行中 (PID %s)    版本 v%s\033[0m\n' "$_smc_pid" "$_smc_ver"
    else
        printf '\033[90m  监控 未运行    版本 v%s\033[0m\n' "$_smc_ver"
    fi
    for _smc_g in $(_menu_group_order); do
        _smc_first=1
        for _smc_i in "${MENU_ITEMS[@]}"; do
            _smc_rest=${_smc_i#*|}
            _smc_name=${_smc_rest%%|*}
            _smc_rest2=${_smc_rest#*|}
            _smc_hint=${_smc_rest2%%|*}
            _smc_grp=${_smc_i%|*}; _smc_grp=${_smc_grp##*|}
            [ "$_smc_grp" != "$_smc_g" ] && continue
            if [ "$_smc_first" = "1" ]; then
                echo ""
                printf '\033[36m  %s\033[0m\n' "$_smc_g"
                _smc_first=0
            fi
            _smc_key=${_smc_i%%|*}
            # 编号亮色（要敲的东西），名字白，说明灰：三层区分让"敲哪个"一眼看出来。
            case "$_smc_key" in
                0) _smc_kc=90;;
                *) _smc_kc=32;;
            esac
            if [ -n "$_smc_hint" ]; then
                printf '\033[%sm    %s\033[0m  \033[97m%s\033[0m   \033[90m%s\033[0m\n' \
                    "$_smc_kc" "$_smc_key" "$(_menu_cell_pad "$_smc_name" "$_smc_w")" "$_smc_hint"
            else
                printf '\033[%sm    %s\033[0m  \033[97m%s\033[0m\n' "$_smc_kc" "$_smc_key" "$_smc_name"
            fi
        done
    done
    echo ""
    printf '\033[90m%s\033[0m\n' "  输编号后回车执行    直接回车 = 查看状态"
}

show_menu() {
    if [ ! -t 0 ]; then
        echo "菜单需要双击 打开菜单.command 使用，管道调用请直接用 install/status/stop/uninstall/update/help 子命令。"
        # 返回 0：这是"用错了调用方式"的提示，不是失败。与 Windows 侧退出码对齐
        # （Windows 非交互调用菜单也返回 0），避免同一个用法在两端报不同的结果。
        return 0
    fi
    # 表格式校验放在这里，不放加载期：放加载期时表一写错，整个程序还没定义完
    # 函数就 exit 了，用户看到的是"双击没反应"，连原因都没有。
    if ! _menu_items_valid; then
        echo "菜单数据损坏，无法显示。请重新下载安装包解压覆盖这个文件夹。"
        return 1
    fi
    # 两轮两种画法：重画整张菜单（首次进入、子命令结束后），或者什么都不画
    # （输错编号那一轮）。之前用布尔量只能表达"清不清屏"，所以输错时仍会重画
    # 整张菜单，连错几次屏幕就滚得找不到位置——而注释里承诺的恰恰相反。
    _mode="menu"
    while true; do
        if [ "$_mode" = "menu" ]; then clear_screen_safe; show_menu_colored; fi
        printf "输入编号："
        if ! IFS= read -r _choice; then
            echo ""
            echo "菜单需要双击 打开菜单.command 使用。"
            return 0
        fi
        # 首尾空格不算输错（与 Windows 侧 .Trim() 同语义）。
        _choice=$(printf '%s' "$_choice" | tr -d '[:space:]')
        [ -z "$_choice" ] && _choice="2"
        # q 与 0 同义：很多人下意识打 q 想退出，报"没有这个编号"只会让人以为程序坏了。
        case "$_choice" in
            q|Q) _choice="0";;
        esac
        # 分派从表里读子命令，不另写一份 case：两份清单必然漂移。
        _msub_ok=1
        if _msub=$(_menu_switch_for "$_choice"); then _msub_ok=0; fi
        if [ "$_msub_ok" = "1" ]; then
            # 输错只补一行，菜单本身留在原位：重画一遍会让屏幕不停往下滚，
            # 连错几次就再也找不到自己在哪了（ADHD 用户尤其受不了）。
            echo "没有这个编号：$_choice（可用的有 $(get_menu_key_range)）"
            _mode="none"
            continue
        fi
        # 空子命令 = 退出项。
        [ -z "$_msub" ] && return 0
        # 帮助留在本进程里跑：它要回到菜单，起子进程就回不来了。
        if [ "$_msub" = "help" ]; then
            show_help
            _mode="menu"
            continue
        fi
        # 子进程跑完整子命令：与入口子命令走的是同一条路（含锁、确认、复检）。
        /bin/bash "$SCRIPT_PATH" "$_msub" || echo "启动失败（退出码 $?）。"
        # 子命令跑完，等用户看一眼再回菜单：否则清屏会立刻把它的输出抹掉。
        printf "按回车回菜单："
        IFS= read -r _dummy || true
        _mode="menu"
    done
}
