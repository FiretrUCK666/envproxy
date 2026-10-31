# ------------------------------------------------------------------------------
#  test-mac-pure.sh — mac 侧的纯函数与沙箱回归（envproxy.sh self-test 的执行体）
#
#  由入口在 self-test 子命令里 source，然后调用 self_test()。不独立执行：
#  它要用 base/probe/env/runtime/package 各层的函数，那些由入口先加载好。
#
#  为什么单独一个文件：它是"沙箱里跑断言"的自检，体量超过任何一个运行时库。
#  放成独立文件，install/status/uninstall 就不用每次先把它解析一遍；
#  而且它与 Windows 侧的 tests\test-win-pure.ps1 结构对齐（那边也是独立文件）。
#  它必须在安装包里（self-test 是文档里写明的子命令）。**必须放在 mac/ 直属**，
#  不能放子目录：包校验器只放行平台目录直接下级的脚本，放进子目录会让每一版更新
#  都被自己的校验器拒收（而且旧版本的校验器也认这个规则，放子目录等于永久自锁）。
#
#  只碰沙箱 HOME 与沙箱 ENVPROXY_HOME，不碰真实用户文件。失败返回非零。
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

# 注意下面的 launchctl() 桩件是**函数内定义**，只在本函数执行期间生效，
# 不会污染生产路径——不要在别处加同名的函数。
# 加载代价实测可忽略：全部运行时库点源一遍只要几十毫秒（shell 只解析函数定义，不执行函数体）。

self_test() {
    # 自检**不能**跑在 `set -eu` 下面。
    #
    # 入口为了自己在运行期"任何意外都别硬撑"开了 set -u；但同一套选项套在测试上就变成
    # 反效果：任何一处意外的非零——包括某个被测函数内部的临时失败——都会让**整个套件
    # 静默中止**，日志停在一句 PASS 后面，既没有 FAIL 也没有错误信息。真实症状：
    # CI 上跑到一半就 exit 1，本地（Git Bash）却全绿，两边都看不出是哪一步出的问题。
    # 测试的职责是把问题**报出来**，不是自己先倒下。所以这里显式关掉，并且留一个
    # 兜底 trap：真有人再让 shell 中途退出，也要在日志里点出是哪一行。
    set +eu
    _selftest_done=0
    # shellcheck disable=SC2064
    trap 'if [ "${_selftest_done:-0}" != "1" ]; then echo "  FAIL 自检在第 ${LINENO} 行意外中止（退出码 $?）"; fi' EXIT
    _selftest_fails=0
    # 把 mac/lib 下所有库的源码合并成一段文本。
#
# 用途：那些"某个词在整个库里出现/不该出现"的断言。它们关心的是**整个库集合**，
# 不是某个具体文件。写死文件名的话，把库拆开就要来改一遍测试——而拆分不该改变
# 任何被测行为的结论。
all_lib_source() {
    cat "$SCRIPT_DIR"/lib/*.sh 2>/dev/null
}
_sandbox=$(mktemp -d "${TMPDIR:-/tmp}/envproxy_selftest.XXXXXX" 2>/dev/null) || { echo "自检失败：沙箱建不起"; return 1; }
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
    PID_FILE="$MONITOR_DIR/monitor.pid"
    STOP_FLAG="$MONITOR_DIR/stop.flag"
    # 这三个也必须在**库里求值之前**改道。它们（runtime.sh 第 9/10/13 行）是
    # 被 source 时求值一次的普通赋值，之后再改 HOME / ENVPROXY_HOME 它们不跟着变——
    # 当下没有用例调用会写它们的东西，所以还没真出事；但谁给 set_autorun /
    # repair_autorun / update_path_record 加一条用例，就会往使用者的真实
    # ~/.envproxy/ 与 ~/Library/LaunchAgents/ 写东西。这是"一改测试就踩"的地雷。
    # self_test 在库加载之后运行，所以这里直接覆盖它们即可（PLIST_PATH 本来就写成
    # ${PLIST_PATH:-...}，说明覆盖是受支持的）。
    PATH_CONF="$ENVPROXY_HOME/path.conf"
    LOCATOR_PATH="$ENVPROXY_HOME/locator.sh"
    PLIST_PATH="$_sandbox/Library/LaunchAgents/$PLIST_LABEL.plist"
    mkdir -p "$(dirname "$PLIST_PATH")" 2>/dev/null || true
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
    # 替身定义在 self_test 内部，但 **bash 的函数定义是全局的**：self_test 返回后
    # 它仍然活着，一直到进程结束。这会污染后面所有用到它的代码——
    # env_vars_in_sync 里 `command -v launchctl` 会恒真，"launchd 那一路是否就位"
    # 全程跑在替身上，真实行为一次都没验过。
    # 所以 self_test 收尾处必须 `unset -f launchctl` 把它撤掉（见函数末尾）。
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

    # 结束行尾随空格：**要认得出来并正常移除**，不能当成"没这个标记"。
    # 为什么改了判据：原来这里断言"一个字节都不改"，那等于把"标记带空格就看不见"
    # 固定成行为。而这个盲目与"标记在不在"的其它四处（状态页、修复入口、安装、卸载）
    # 各用一套严格度时，同一个文件会给出互相矛盾的结论——状态页说"没有同步块"、
    # 修复入口说"没有需要修的"，那条补救路就是死的（实测过）。
    # 判据已统一成"去首尾空白后逐字节相等"，所以这里改成断言真的摘干净。
    printf '%s\n' 'export PATH=/x' '# >>> EnvProxy >>>' 'HOOK' '# <<< EnvProxy <<< ' 'alias ll="ls"' > "$HOME/.zshenv"
    remove_shell_hooks 2>/dev/null || true
    _selftest_assert_file_eq "结束行尾随空格也能正常移除" "$(printf '%s\n' 'export PATH=/x' 'alias ll="ls"')" "$HOME/.zshenv"

    printf '%s\n' 'export PATH=/x' '# >>> EnvProxy >>>' "$HOOK_LINE" '# <<< EnvProxy <<<' 'alias ll="ls"' > "$HOME/.zshenv"
    remove_shell_hooks 2>/dev/null || true
    _selftest_assert_file_eq "成对时正常移除" "$(printf '%s\n' 'export PATH=/x' 'alias ll="ls"')" "$HOME/.zshenv"

        # 显示宽度：判据必须与"码位 > 0x2E80 占两格"等价，不能只看 UTF-8 字节数。
    # 实测过的坑：… / → / — 都是 3 字节，按"3 字节就算两格"会判成 2，
    # 而它们在终端里只有 1 格——于是含省略号或箭头的行比 Windows 多占一格，
    # 两列对齐跟着歪（日志裁剪、菜单两列、帮助两列都吃这个判据）。
    _selftest_assert_eq "宽度：… 占一格" "1" "$(_display_width "…")"
    _selftest_assert_eq "宽度：→ 占一格" "1" "$(_display_width "→")"
    _selftest_assert_eq "宽度：— 占一格" "1" "$(_display_width "—")"
    _selftest_assert_eq "宽度：中 占两格" "2" "$(_display_width "中")"
    _selftest_assert_eq "宽度：全角 Ａ 占两格" "2" "$(_display_width "Ａ")"
    _selftest_assert_eq "宽度：混合行 中+… 共 3 格" "3" "$(_display_width "中…")"
    # 分界线本身：U+2E80（CJK 部首补充区起点，真宽 2）与 U+2026（…，真宽 1）
    # 的 UTF-8 首字节都是 E2，只看首字节判不出差别——这条钉住"看第二字节"。
    _selftest_assert_eq "宽度：U+2E80 占两格" "2" "$(_display_width "$(printf '\xe2\xba\x80')")"
    _selftest_assert_eq "宽度：U+2E7F 占一格" "1" "$(_display_width "$(printf '\xe2\xb9\xbf')")"
    # 4 字节序列（补充平面）：码位必然 > U+2E80，占两格。
    # 这一条挡的是"推进量只认 1/2/3 字节"那类错——它会让截断点落在半个字符中间。
    _selftest_assert_eq "宽度：😀 占两格" "2" "$(_display_width "😀")"
    _selftest_assert_eq "宽度：混合 中文😀 共 6 格" "6" "$(_display_width "中文😀")"
    # ANSI 颜色序列不占格子。Windows 侧 Get-DisplayWidth 会先剥掉再算，
    # 这里不剥就会把一行 34 格的标题算成 51 格，"这帧太宽画不下"而白白降级。
    _selftest_assert_eq "宽度：ANSI 转义不占格" "11" \
        "$(_display_width "$(printf '\033[36m版本 v2.0.0\033[0m')")"

    # 截断：结果宽度**不超过**上限（含补上的省略号）。
    # 若按"截到上限再补…"算，实际宽度是上限+1：日志行正好顶满终端宽度而自动折行，
    # 而状态页按绝对行号画，折行会把后面每一行往下推。
    _tw_ok=1
    for _tw_m in 1 2 5 6 10 20 40; do
        _tw_o=$(_truncate_width "检测到本地代理端口 7078 已注入代理" "$_tw_m")
        _tw_w=$(_display_width "$_tw_o")
        [ "$_tw_w" -le "$_tw_m" ] || _tw_ok=0
    done
    _selftest_assert_eq "截断：结果宽度不超过上限" "1" "$_tw_ok"
    # 放得下就原样返回，一个字节都不动、不加省略号。
    _selftest_assert_eq "截断：放得下时原样返回" "中中中" "$(_truncate_width "中中中" 6)"
    # 截断点不许落在字符中间：4 字节字符必须按 4 字节推进，按 3 推进会把剩下的
    # 1 个孤儿字节拼进结果——输出不是合法 UTF-8，屏幕上是一个乱码方块。
    _selftest_assert_eq "截断：不劈开 4 字节字符" \
        "$(printf '\xf0\x9f\x98\x80\xe2\x80\xa6')" "$(_truncate_width "😀中中中" 4)"
    # LC_ALL=C 必须留在函数里：不写 local 时它会把调用方的 locale 改掉，
    # 之后所有 ${#x} 从"字符数"变成"字节数"，两列表格按字节数对齐就会歪。
    _tw_loc=${LC_ALL-<unset>}
    _truncate_width "很长的中文日志行需要截断" 10 > /dev/null
    _selftest_assert_eq "截断：不泄漏 locale 到调用方" "$_tw_loc" "${LC_ALL-<unset>}"

    # 畸形状态串必须被拒，不许静默当成功。与 Windows 侧同一判据。
    # 为什么能安全地测：apply_state 对畸形输入在动任何东西之前就返回了。
    _bad_states_ok=1
    for _bs in "on:" "garbage" "on:abc" "on:0" "on:70000" "on:-1"; do
        if apply_state "$_bs" >/dev/null 2>&1; then _bad_states_ok=0; fi
    done
    _selftest_assert_eq "畸形状态串一律被拒" "1" "$_bad_states_ok"
    _good_states_ok=1
    for _gs in "off" "unknown" ""; do
        apply_state "$_gs" >/dev/null 2>&1 || _good_states_ok=0
    done
    _selftest_assert_eq "合法状态串一律放行" "1" "$_good_states_ok"

    # 帮助主题表的形状：编号必须连续、不重复，每条的三个字段都不能空。
    # 代码注释里一直写着"自检里有一条断言直接检查这张表的形状"，而这条断言
    # 之前并不存在——把表改成 1,3,3 也全绿。假承诺比没有承诺更糟：
    # 下一个人会相信已经有人看着了。
    _ht_recs=${#HELP_TOPICS[@]}
    _selftest_assert_eq "帮助主题表非空" "1" "$([ "$_ht_recs" -gt 0 ] && echo 1 || echo 0)"
    _ht_expect=1
    _ht_bad=0
    for _ht_rec in "${HELP_TOPICS[@]}"; do
        _ht_key=${_ht_rec%%|*}
        _ht_rest=${_ht_rec#*|}
        _ht_short=${_ht_rest%%|*}
        _ht_title=${_ht_rest#*|}
        if [ "$_ht_key" != "$_ht_expect" ]; then _ht_bad=1; fi
        if [ -z "$_ht_short" ] || [ -z "$_ht_title" ]; then _ht_bad=1; fi
        case "$_ht_title" in *"|"*) _ht_bad=1 ;; esac
        _ht_expect=$((_ht_expect + 1))
    done
    _selftest_assert_eq "帮助主题表编号连续且三个字段都非空" "0" "$_ht_bad"
    # 编号表必须与主表同长同序（它是派生出来的，但不能保证永远派生得对）
    _ht_keys=${#HELP_TOPIC_KEYS[@]}
    _selftest_assert_eq "帮助编号表与主表条数一致" "$_ht_recs" "$_ht_keys"
    # 每条主题都必须有正文页（body 仍单独分派，漏一条就是"选中后是一页空白"）
    _ht_nobody=0
    for _ht_k in "${HELP_TOPIC_KEYS[@]}"; do
        if [ -z "$(format_help_topic "$_ht_k" 2>/dev/null | tr -d '[:space:]')" ]; then _ht_nobody=1; fi
    done
    _selftest_assert_eq "每条帮助主题都有正文页" "0" "$_ht_nobody"

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
        # launchd 那一路（GUI 程序看到的那份）必须与 proxy.env 同进同退。
        #
        # 替身把每次 setenv 记进 launchctl.log，但在此之前**没人读过它**——
        # 也就是说 env.sh 里那 9 行 `launchctl setenv` 删掉任意几行，自检照样全绿。
        # 那 9 行（5 个大写 + 4 个小写拼写）决定 Dock 启动的 GUI 程序能否读到代理，
        # 是 macOS 的第二路注入，没有第二条路能发现它坏掉。
        _ps_lc_missing=""
        for _ps_v in $PROXY_VAR_NAMES; do
            grep -qx "setenv $_ps_v" "$_selftest_launchctl_log" 2>/dev/null \
                || _ps_lc_missing="$_ps_lc_missing $_ps_v"
        done
        _selftest_assert_eq "launchd 注入覆盖整张变量表（漏一个 GUI 就拿不到）" "" "$_ps_lc_missing"
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
                         [ "$_ep_fn" = "$_f" ] || _ep_keep=(${_ep_keep[@]+"${_ep_keep[@]}"} "$_ep_fn")
                     done
                     precmd_functions=(${_ep_keep[@]+"${_ep_keep[@]}"} "$_f")
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
    # 「装了才认领」与「这值是不是本机地址」是两件独立的事实，各自要有用例。
    # 先造安装记录：下面这两条测的是"装好之后的注入值归我们回收"；
    # 没有安装记录时它会被正确判成"不知道"，那是紧接着单独测的另一件事。
    if [ ! -f "$PATH_CONF" ]; then printf '%s\n' "$SCRIPT_PATH" > "$PATH_CONF" 2>/dev/null || true; fi
    if is_owned_proxy_value "http://127.0.0.1:7890"; then _o1=1; else _o1=0; fi
    if is_owned_proxy_value "http://corp:8080"; then _o2=1; else _o2=0; fi
    _selftest_assert_eq "本机地址算我们的" "1" "$_o1"
    _selftest_assert_eq "公司地址不算我们的" "0" "$_o2"
    # 没有安装记录 = 这台机器从没装过本工具：那个本机代理是使用者自己挂的
    # （mitmproxy、内网跳板都长这样），一个字节都不许动。
    # 少了这条，在一台从没装过的机器上执行 stop 就会删掉他的配置，且无快照可还原。
    if [ -f "$PATH_CONF" ]; then
        _nr_bak="$PATH_CONF.bak_$$"
        if mv "$PATH_CONF" "$_nr_bak" 2>/dev/null; then
            if is_owned_proxy_value "http://127.0.0.1:7890"; then _nr=1; else _nr=0; fi
            mv "$_nr_bak" "$PATH_CONF" 2>/dev/null || true
            _selftest_assert_eq "没有安装记录时不认领本机地址（那是使用者自己挂的）" "0" "$_nr"
        fi
    fi
    # 快照文件存在、但一个代理变量都没读出内容 = 这份快照不可用（截断 / 权限 / 格式坏）。
    # 此时不许认领：认错了会把这个本机地址删掉，而那可能正是使用者自己挂的 mitmproxy；
    # 不认领最多多留一个值（下一轮还会再判）。两个方向的代价不对称。
    # 与 Windows 侧 Test-SnapshotRecorded 三态化是同一条判据。
    _s0_bak=$(mktemp "${TMPDIR:-/tmp}/envproxy_prev_empty.XXXXXX" 2>/dev/null) || _s0_bak=""
    if [ -n "$_s0_bak" ]; then
        _s0_old_prev="$PREV_ENV"
        PREV_ENV="$_s0_bak"
        : > "$PREV_ENV"
        if is_owned_proxy_value "http://127.0.0.1:7890"; then _s0a=1; else _s0a=0; fi
        _selftest_assert_eq "空快照不认领本机地址（读不出来不等于我们的）" "0" "$_s0a"
        rm -f "$PREV_ENV" 2>/dev/null || true
        PREV_ENV="$_s0_old_prev"
    fi
    _selftest_assert_eq "转义幂等" "'a'" "$(shell_escape_sq 'a')"
    # 归属的第二层：安装快照（prev.env）里本来就记着的值，哪怕长得像我们的，也是使用者的。
    # 没有这一层，用户自己写的 NO_PROXY=localhost、或自挂的 mitmproxy 会在 off 态被定时删掉。
    _s1_bak=$(mktemp "${TMPDIR:-/tmp}/envproxy_prev.XXXXXX" 2>/dev/null) || _s1_bak=""
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

        # classify_no_proxy_entry 是回收循环真正用的那个判据（返回 1=使用者自己的、0=我们加的、2=无关）。
        # 上面几条测的是它内部的两个判据，这一段测它自己——回收循环里那一行
        # `classify_no_proxy_entry "$_pt"; [ $? -eq 0 ] && continue` 就是靠这三个返回值分工的。
        # 这三个分支一旦接错（比如 1 和 0 反了），用户的条目会被摘掉、我们的反而留着。
        { printf 'NO_PROXY\t%s\n' "'localhost'"; } > "$PREV_ENV"
        classify_no_proxy_entry "localhost"; _s1f=$?
        classify_no_proxy_entry "127.0.0.1"; _s1g=$?
        classify_no_proxy_entry "corp.example"; _s1h=$?
        rm -f "$PREV_ENV" 2>/dev/null || true
        PREV_ENV="$_s1_old_prev"
        _selftest_assert_eq "分类：快照里的项判为使用者的（1）" "1" "$_s1f"
        _selftest_assert_eq "分类：默认项但不在快照判为我们加的（0）" "0" "$_s1g"
        _selftest_assert_eq "分类：无关条目原样留（2）" "2" "$_s1h"
    else
        echo "  SKIP 快照归属判定（建不出临时文件）"
    fi
    # compare_versions 结果走 stdout（exit 恒 0），直接取输出断言。
    _selftest_assert_eq "版本逐段数值比" "1" "$(compare_versions "1.0.10" "1.0.9")"

    # ----------------------------------------------------------------------
    # [2c] 判决第二三层：真起一个假代理，验 CONNECT 握手与端点应答
    # ----------------------------------------------------------------------
    #
    # 这一段之前是完全空白的：test_http_proxy / test_http_proxy_batch /
    # _handshake_at / test_endpoint_status / test_single_endpoint 在自检里
    # **引用次数全为 0**。也就是说把握手判据改成恒真、或改坏状态码解析正则，
    # mac 侧的自检照样全绿——而这三个函数决定"要不要给用户的终端注入代理"，
    # 是这个工具的核心判决。win 侧一直有正向覆盖（真起 TcpListener 验握手），
    # 两侧对等性上这是最大的一处失衡。
    #
    # 假代理用 perl 起（macOS 系统自带，不破坏零依赖）；客户端用 curl
    # （同样是系统自带）。不用 nc：macOS 各版本 nc 参数不一致，
    # 而本机实测 Git Bash 根本没有 nc —— 那会让这段测试在别的机器上随机红。
    _fp_port=""
    for _fp_try in 19000 19001 19002 19003 19004 19005; do
        if ( : < /dev/null ) 2>/dev/null; then :; fi
        # 挑一个没人监听的端口：能连上就说明被占了，换下一个
        if ! (exec 9<>/dev/tcp/127.0.0.1/$_fp_try) 2>/dev/null; then
            _fp_port=$_fp_try; break
        fi
        exec 9<&- 2>/dev/null || true
    done
    if [ -n "$_fp_port" ] && command -v perl >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
        _fp_respond() {
            # $1 = 端口, $2 = 应答首行（如 'HTTP/1.1 200 Connection established'）
            perl -e '
              use IO::Socket::INET;
              my ($port, $line) = @ARGV;
              my $srv = IO::Socket::INET->new(LocalAddr=>"127.0.0.1", LocalPort=>$port,
                                              Listen=>8, ReuseAddr=>1) or exit 1;
              my $n = 0;
              while ($n++ < 6) {
                my $c = $srv->accept() or next;
                my $buf = "";
                while (my $l = <$c>) { $buf .= $l; last if $l =~ /^\r?\n$/; }
                print $c "$line\r\n\r\n";
                close $c;
              }
            ' "$1" "$2" &
            _fp_pid=$!
            # 等它真的监听起来：固定 sleep 在忙的机器上不够（会随机红）。
            _fp_wait=0
            while [ $_fp_wait -lt 50 ]; do
                if (exec 9<>/dev/tcp/127.0.0.1/"$1") 2>/dev/null; then
                    exec 9<&- 2>/dev/null || true
                    return 0
                fi
                _fp_wait=$((_fp_wait + 1))
                sleep 0.1
            done
            return 1
        }

        # 1) 真代理：回 "200 Connection established" 的端口必须judged 为代理
        if _fp_respond "$_fp_port" 'HTTP/1.1 200 Connection established'; then
            _fp_bak="$(printf '%s' "$NC_HAS_G")"
            NC_HAS_G=0   # 强制走 curl 那条路：本机可能没有 nc
            if test_http_proxy "$_fp_port"; then _fp_a=1; else _fp_a=0; fi
            _selftest_assert_eq "判决：真代理端口认得出来（CONNECT 200）" "1" "$_fp_a"
            NC_HAS_G="$_fp_bak"
            kill $_fp_pid 2>/dev/null || true
            wait $_fp_pid 2>/dev/null || true
        else
            echo "  SKIP 判决：真代理（假代理起不来）"
        fi

        # 2) 非代理：回 "404" 的服务不能被当成代理
        #    这是"任何回 200 的 HTTP 服务都会被当成代理"那个坑的反面验证。
        if _fp_respond "$_fp_port" 'HTTP/1.1 404 Not Found'; then
            _fp_bak="$(printf '%s' "$NC_HAS_G")"
            NC_HAS_G=0
            if test_http_proxy "$_fp_port"; then _fp_b=1; else _fp_b=0; fi
            _selftest_assert_eq "判决：回 404 的普通服务不算代理" "0" "$_fp_b"
            NC_HAS_G="$_fp_bak"
            kill $_fp_pid 2>/dev/null || true
            wait $_fp_pid 2>/dev/null || true
        else
            echo "  SKIP 判决：404 服务（假代理起不来）"
        fi

        # 3) 关闭的端口不能被当成代理
        if test_http_proxy 9; then _fp_c=1; else _fp_c=0; fi
        _selftest_assert_eq "判决：关闭的端口不算代理" "0" "$_fp_c"
    else
        echo "  SKIP 判决第二层（没有 perl 或 curl，或挑不到空闲端口）"
    fi

    # 端点应答的三态判定：纯函数，不碰网络。
    # 这三条钉住"什么算通"：generate_204 类只认 204（强制门户劫持回 200/302 都不算），
    # 跨域段兜底端点只认 3xx（收 204 会让它们永远判死）。
    if test_endpoint_status 204 204; then _ep_a=1; else _ep_a=0; fi
    _selftest_assert_eq "端点判据：204 对 204 算通" "1" "$_ep_a"
    if test_endpoint_status 200 204; then _ep_b=1; else _ep_b=0; fi
    _selftest_assert_eq "端点判据：204 类收到 200 不算通（门户劫持）" "0" "$_ep_b"
    if test_endpoint_status 302 204; then _ep_c=1; else _ep_c=0; fi
    _selftest_assert_eq "端点判据：204 类收到 302 不算通" "0" "$_ep_c"
    if test_endpoint_status 302 3xx; then _ep_d=1; else _ep_d=0; fi
    _selftest_assert_eq "端点判据：3xx 类收到 302 算通" "1" "$_ep_d"
    if test_endpoint_status 204 3xx; then _ep_e=1; else _ep_e=0; fi
    _selftest_assert_eq "端点判据：3xx 类收到 204 不算通" "0" "$_ep_e"
    if test_endpoint_status 404 3xx; then _ep_f=1; else _ep_f=0; fi
    _selftest_assert_eq "端点判据：3xx 类收到 404 不算通" "0" "$_ep_f"

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

    # ----------------------------------------------------------------------
    # [3b] off 哨兵：内容是对"已开窗口敲回车就跟上"的唯一凭据
    # ----------------------------------------------------------------------
    #
    # 这一段之前完全没有直接覆盖（write_off_sentinel 引用次数为 0）。
    # 它写出的文件会被使用者的 shell 在**每次提示符**处 source，所以格式错一点都不行：
    #   - 写成裸 $VAR 会在开了 nounset 的 shell 里报 unbound variable，打断用户输入；
    #   - 守卫值写错会让旧变量永远清不掉（"固定直连了但 curl 还走代理"）；
    #   - 末行不是 true 会让 zsh 后续 precmd 钩子全部不执行（连主题都会崩）。
    _wos_saved_proxy="$PROXY_ENV"; _wos_saved_owned="$OWNED_ENV"
    PROXY_ENV="$_sandbox/wos_proxy.env"
    OWNED_ENV="$_sandbox/wos_owned.env"
    # 造一份"我们写下过的值"（格式与真实 owned.env 一致：名字 TAB 值）
    { printf 'HTTP_PROXY\thttp://127.0.0.1:7078\n'
      printf 'NO_PROXY\tlocalhost,127.0.0.1,::1\n'
      printf 'NODE_USE_ENV_PROXY\t1\n'; } > "$OWNED_ENV"
    write_off_sentinel >/dev/null 2>&1
    _wos_body=$(cat "$PROXY_ENV" 2>/dev/null || true)
    case "$_wos_body" in
        *'# envproxy-state: off'*) _wos_a=1;;
        *) _wos_a=0;;
    esac
    _selftest_assert_eq "off 哨兵：首行标明状态" "1" "$_wos_a"
    # 每个地址变量都要有自己那一行 unset
    _wos_miss=""
    for _wos_v in $PROXY_ADDR_VAR_NAMES; do
        printf '%s' "$_wos_body" | grep -q "unset $_wos_v" || _wos_miss="$_wos_miss $_wos_v"
    done
    _selftest_assert_eq "off 哨兵：覆盖每一个地址变量" "" "$_wos_miss"
    # NODE_USE_ENV_PROXY 也要有守卫行（它是"使用者自己设的 1 不许删"那条契约）
    printf '%s' "$_wos_body" | grep -q 'unset NODE_USE_ENV_PROXY' && _wos_b=1 || _wos_b=0
    _selftest_assert_eq "off 哨兵：含 NODE_USE_ENV_PROXY 守卫" "1" "$_wos_b"
    # 必须是 ${VAR-} 形式：裸 $VAR 在 nounset 下会报错
    printf '%s' "$_wos_body" | grep -q '\[ "\${HTTP_PROXY-}"' && _wos_c=1 || _wos_c=0
    _selftest_assert_eq "off 哨兵：用 \${VAR-} 而不是裸变量（nounset 安全）" "1" "$_wos_c"
    # 末行必须是 true：source 返回非零会打断 zsh 后续钩子
    _wos_last=$(printf '%s' "$_wos_body" | tail -n 1)
    _selftest_assert_eq "off 哨兵：末行恒真（source 返回 0）" "true" "$_wos_last"
    # 真的能清掉：在子 shell 里 source 一遍，看变量有没有被 unset
    _wos_after=$( ( export HTTP_PROXY="http://127.0.0.1:7078"
                     export HTTPS_PROXY="http://127.0.0.1:7078"
                     export NODE_USE_ENV_PROXY=1
                     . "$PROXY_ENV" >/dev/null 2>&1
                     printf '%s|%s|%s' "${HTTP_PROXY-unset}" "${HTTPS_PROXY-unset}" "${NODE_USE_ENV_PROXY-unset}" ) )
    _selftest_assert_eq "off 哨兵：source 后变量确实被清掉" "unset|unset|unset" "$_wos_after"
    # 反向：值不是我们写的（使用者自己的代理）时一个都不许动
    _wos_keep=$( ( export HTTP_PROXY="http://corp-proxy:8080"
                    . "$PROXY_ENV" >/dev/null 2>&1
                    printf '%s' "${HTTP_PROXY-unset}" ) )
    _selftest_assert_eq "off 哨兵：不碰使用者自己的代理值" "http://corp-proxy:8080" "$_wos_keep"
    rm -f "$PROXY_ENV" "$OWNED_ENV" 2>/dev/null || true
    PROXY_ENV="$_wos_saved_proxy"; OWNED_ENV="$_wos_saved_owned"

    echo "[4] 快照还原"
    snapshot_prev_env || true
    if [ -f "$PREV_ENV" ]; then _s5=1; else _s5=0; fi
    _selftest_assert_eq "快照文件生成" "1" "$_s5"
    restore_prev_env || true
    if [ -f "$PREV_ENV" ]; then _s6=1; else _s6=0; fi
    _selftest_assert_eq "还原后快照删除" "0" "$_s6"

    echo "[4b] 快照归属判定"
    # "像我们写的"不够——还要能分辨"这到底是不是我们写下的"。
    # 判据有两条，优先级由硬到软：
    #   1) 归属记录（owned.env）里逐字记着这个值  → 一定是我们的，永远不进快照
    #   2) 机器上已有安装记录 + 形状像本机地址      → 可能是我们上次写下的，跳过
    # 第 1 条排在最前，因为第 2 条的推断前提（"首次安装时机器上还没有我们的东西"）
    # 在卸载没清干净时不成立——残留值会在下一次全新安装时被当成使用者的、存进快照、
    # 再按快照还原，于是永远清不掉（Windows 侧实测踩过，这边同一套机制同一个洞）。
    #
    # 这一组必须在**已知的 owned.env 状态**下跑：先记下真实文件、单独造一份受控的，
    # 跑完还原。不这样做的话，同一条断言在"装过的机器"和"干净的机器"上会得出相反结论。
    _sk_owned_backup=""
    if [ -f "$OWNED_ENV" ]; then
        _sk_owned_backup="$OWNED_ENV.testbak.$$"
        cp "$OWNED_ENV" "$_sk_owned_backup" 2>/dev/null || _sk_owned_backup=""
    fi
    mkdir -p "$ENVPROXY_HOME" 2>/dev/null || true
    # 空记录：首次安装时，形状像本机地址的也得进快照（否则把使用者的手设值删掉）
    : > "$OWNED_ENV" 2>/dev/null
    if snapshot_skip_value HTTP_PROXY 'http://127.0.0.1:7890' 1; then _sk1=1; else _sk1=0; fi
    _selftest_assert_eq "首次安装且无记录：本机地址要快照" "0" "$_sk1"
    if snapshot_skip_value NODE_USE_ENV_PROXY 1 1; then _sk2=1; else _sk2=0; fi
    _selftest_assert_eq "首次安装且无记录：NODE_USE_ENV_PROXY=1 要快照" "0" "$_sk2"
    # 有记录：那个值是我们的，即使是首次安装也不进快照
    printf 'HTTP_PROXY\thttp://127.0.0.1:7890\nNODE_USE_ENV_PROXY\t1\n' > "$OWNED_ENV" 2>/dev/null
    if snapshot_skip_value HTTP_PROXY 'http://127.0.0.1:7890' 1; then _sk2b=1; else _sk2b=0; fi
    _selftest_assert_eq "首次安装但有记录：那个值不进快照" "1" "$_sk2b"
    if snapshot_skip_value NODE_USE_ENV_PROXY 1 1; then _sk2c=1; else _sk2c=0; fi
    _selftest_assert_eq "首次安装但有记录：NODE_USE_ENV_PROXY=1 不进快照" "1" "$_sk2c"
    # 重装（非首次）：形状像本机地址的跳过
    if snapshot_skip_value https_proxy 'http://127.0.0.1:7890' 0; then _sk3=1; else _sk3=0; fi
    _selftest_assert_eq "重装：本机地址是我们上次写的，跳过" "1" "$_sk3"
    # 还原真实文件
    rm -f "$OWNED_ENV" 2>/dev/null || true
    if [ -n "$_sk_owned_backup" ] && [ -f "$_sk_owned_backup" ]; then
        mv "$_sk_owned_backup" "$OWNED_ENV" 2>/dev/null || true
    fi
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
    # 必须数**调用点**，不能只 grep 名字存在。
    # `autorun_reload_needed` 的定义就在 runtime.sh 里，grep 名字必然命中——
    # 那是自证：把 set_autorun 里唯一的调用点删掉，这条断言照样通过。
    # 所以判据是"调用点恰好一个"，删掉它这里立刻红。
    _r14=$(grep -c 'if autorun_reload_needed ' "$LIB_DIR/runtime.sh" 2>/dev/null || printf '0')
    _selftest_assert_eq "set_autorun 真的调用了这个判据（调用点恰好 1 处）" "1" "$_r14"

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

    # 代理地址变了要不要提醒：判据必须与 Windows 侧 Test-ProxyShouldNotify 逐条一致。
    # 两端用户看到的是同一件事，一边提醒一边不提醒就是行为漂移。
    _pn() { if proxy_should_notify "$1" "$2"; then echo 1; else echo 0; fi; }
    _selftest_assert_eq "提醒：端口变了要提醒" "1" "$(_pn on:7078 on:7890)"
    _selftest_assert_eq "提醒：同一个端口不提醒" "0" "$(_pn on:7078 on:7078)"
    _selftest_assert_eq "提醒：代理关掉要提醒" "1" "$(_pn on:7078 off)"
    _selftest_assert_eq "提醒：从无到有不提醒（旧程序照旧直连能通）" "0" "$(_pn off on:7078)"
    _selftest_assert_eq "提醒：一直直连不提醒" "0" "$(_pn off off)"
    _selftest_assert_eq "提醒：不知道时不提醒（提示等于谎报）" "0" "$(_pn unknown on:7078)"
    _selftest_assert_eq "提醒：不知道时不提醒（反向）" "0" "$(_pn on:7078 unknown)"
    _selftest_assert_eq "提醒：空状态不提醒" "0" "$(_pn "" on:7078)"

    # 快扫什么都没看见 ≠ 本机没有代理。
    # 这是会删掉使用者代理变量的一类错误：用户把端口改成表外的值时，
    # 快扫每轮都返回空；若当成"集合变空"就判 off、删变量，终端突然断网。
    # 判据：快扫(_full=0) + 候选集空 + 上次全扫记得有端口 -> 本轮不下结论。
    if [ "$(type -t get_current_state 2>/dev/null || true)" = "function" ]; then
        _gs_saved_round="$ROUND"; _gs_saved_full="$NEED_DEEP_SCAN"; _gs_saved_efs="$EVER_FULL_SCANNED"
        _gs_saved_seen="$LAST_SEEN_SET"; _gs_saved_alive="$LAST_ALIVE_PORT"; _gs_saved_state="$CURRENT_STATE"
        _gs_saved_fcp="$(type -t find_candidate_ports 2>/dev/null || true)"
        # 桩：快扫返回空（模拟"端口不在常见表里"），且不是全扫轮
        find_candidate_ports() { return 0; }
        # 显式声明"已经做过全扫"：不声明的话首轮会走"必须全扫"那条路
        # （EVER_FULL_SCANNED=0 -> _need_first=1），而这条用例要测的是**快扫**行为。
        # 顺手也当一条回归：少了 EVER_FULL_SCANNED 时这里是红的——
        # 说明"首轮强制全扫"那个机制真的接上了，不是写着好看的。
        ROUND=3; NEED_DEEP_SCAN=0; EVER_FULL_SCANNED=1
        LAST_SEEN_SET="7099"; LAST_ALIVE_PORT="7099"; CURRENT_STATE="on:7099"
        _gs_before="$LAST_SEEN_SET"
        if get_current_state >/dev/null 2>&1; then :; fi
        _selftest_assert_eq "快扫空结果不清签名（不当成集合变空）" "$_gs_before" "$LAST_SEEN_SET"
        _selftest_assert_eq "快扫空结果不改判 off" "on:7099" "$CURRENT_STATE"
        # 还原
        ROUND="$_gs_saved_round"; NEED_DEEP_SCAN="$_gs_saved_full"; EVER_FULL_SCANNED="$_gs_saved_efs"
        LAST_SEEN_SET="$_gs_saved_seen"; LAST_ALIVE_PORT="$_gs_saved_alive"; CURRENT_STATE="$_gs_saved_state"
        if [ -n "$_gs_saved_fcp" ]; then eval "find_candidate_ports() { $(declare -f find_candidate_ports | sed -n '2,$p'); }" 2>/dev/null || true; fi
        unset -f find_candidate_ports 2>/dev/null || true

    # 握手判定：什么才算"这是个代理端口"。
    # 这是区分"代理端口"与"其他服务端口"的唯一判据，不依赖进程名/端口号猜测。
    # 判错两个方向都致命：把开发服务器当成代理 -> 注入死代理、终端全断；
    # 把真代理漏掉 -> 使用者以为工具坏了。
    # 判据是纯文本比较，直接喂字符串，不必真连网络。与 Windows 侧同一批用例。
    if [ "$(type -t _ha_is_connect_ok 2>/dev/null || true)" = "function" ] || true; then
        # 用**生产代码里那条正则**，不在这里另抄一份——抄一份就等于自己测自己，
        # 改了 probe.sh 的判据而测试仍绿，那种绿是假的。从源码抽出来再求值。
        _ha_pat=$(grep -oE '\^HTTP/1\\\.\[01\] \+200\( \|\$\)' "${SCRIPT_DIR:-mac}/lib/probe.sh" 2>/dev/null | head -n 1)
        if [ -z "$_ha_pat" ]; then _ha_pat=$(grep -oE '\^HTTP/1\\\.\[01\] \+200\( \|\$\)' "$(dirname "$0")/lib/probe.sh" 2>/dev/null | head -n 1); fi
        _selftest_assert_eq "握手：能从 probe.sh 里抽到那条判据正则" "yes" "$(if [ -n "$_ha_pat" ]; then echo yes; else echo no; fi)"
        _ha_check() {
            if printf '%s' "$1" | grep -qE "$_ha_pat"; then echo "yes"; else echo "no"; fi
        }
        _selftest_assert_eq "握手：标准 200 算代理" "yes" "$(_ha_check "HTTP/1.1 200 Connection established")"
        _selftest_assert_eq "握手：1.0 的 200 也算" "yes" "$(_ha_check "HTTP/1.0 200 OK")"
        _selftest_assert_eq "握手：只有状态码没有原因短语也算" "yes" "$(_ha_check "HTTP/1.1 200")"
        _selftest_assert_eq "握手：404 不算" "no" "$(_ha_check "HTTP/1.1 404 Not Found")"
        _selftest_assert_eq "握手：403 不算" "no" "$(_ha_check "HTTP/1.1 403 Forbidden")"
        _selftest_assert_eq "握手：500 不算" "no" "$(_ha_check "HTTP/1.1 500 Internal Server Error")"
        _selftest_assert_eq "握手：2000 不算（只认 200 本身，不许前缀匹配放过）" "no" "$(_ha_check "HTTP/1.1 2000 OK")"
        _selftest_assert_eq "握手：2001 不算" "no" "$(_ha_check "HTTP/1.1 2001")"
        _selftest_assert_eq "握手：204 不算（不是 CONNECT 成功）" "no" "$(_ha_check "HTTP/1.1 204 No Content")"
        _selftest_assert_eq "握手：空应答不算" "no" "$(_ha_check "")"
        _selftest_assert_eq "握手：非 HTTP 应答不算" "no" "$(_ha_check "SSH-2.0-OpenSSH_8.9")"
        unset -f _ha_check 2>/dev/null || true
    fi
    fi

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
            日常|进阶|维护|支持|退出) _lmgok=1;;
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
                   *)
                       # 真去核一遍：这个子命令必须出现在入口的 case 分派里。
                       # 原来这里写的是 assert_eq "1" "1" —— 期望与实际都是常量，
                       # 数学上不可能失败，等于一条什么都不测的断言（而它的名字
                       # 还声称"子命令可解析"，很容易被当成"这块有覆盖"）。
                       if grep -qE "^[[:space:]]*${_lms}\)" "$SCRIPT_DIR/envproxy.sh" 2>/dev/null; then
                           _lmsok=1
                       else
                           _lmsok=0
                       fi
                       _selftest_assert_eq "条目 $_lmk 的子命令 $_lms 在入口分派里" "1" "$_lmsok"
                       ;;
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
    if all_lib_source | grep -qE '^[[:space:]]*q\|Q\|0\)' 2>/dev/null; then _lq=1; else _lq=0; fi
    _selftest_assert_eq "帮助页认 q 和 0（与菜单同义）" "1" "$_lq"
    # 配色：颜色由内容自己声明（行首标记），不再从行的形状去猜。
    # 为什么改：猜的判据是"缩进 4 格 + 无汉字 = 命令"，而真实内容不按这个形状长——
    # `Git Bash  source ~/.bashrc` 带左列标签、`PowerShell  $env:...` 只缩进 2 格，
    # 两行都是能整行复制的命令却判成灰。这不是漏了哪一行，是判据注定会错。
    # 现在断言的是**渲染结果**：标成 c / rc 的行必须出命令色 32，标成 t / w 的必须不是。
    for _cl_case in "c curl --noproxy '*' https://example.com" \
                    "c git -c http.proxy= -c https.proxy= clone https://github.com/git/git.git" \
                    "c echo \$HTTPS_PROXY" \
                    "rc zsh / bash|export ENVPROXY_TERM=off" \
                    "t 窗口一关就失效，只有 zsh 和 bash 管用。" \
                    "w 注意：只认具体网址，写 * 没用。"; do
        _cl_code=${_cl_case%% *}
        # 行首标记必须原样带进渲染函数：去掉它，第一格就变成正文内容，
        # 整行会被当成标记认不出的正文（灰）——这条测试最初就是这么假绿的。
        # 取的是**实际打印出来的那一段**（命令替换捕获），不是累加器变量：
        # 累加器在 flush 之后就被清空了，拿它比对会一律"没有颜色"——
        # 那会让 t/w 那几条假通过（它们本来就不该有颜色）。
        _cl_esc=$(printf '\033')
        _cl_got=$(
            _SEG_COLORED=1
            _SEG_LINE=""
            _help_render_line "$_cl_case"
        )
        # 命令色**从配色表读**，不写死 32：颜色是可调的，写死数字会让"换一个颜色"
        # 变成"改一处代码 + 改一条测试"。要断言的是行为——"标成 c/rc 的行出命令色，
        # 别的行不出"，不是"命令色必须是 32"。
        _cl_color=$(style_color cmd)
        case "$_cl_code:$_cl_got" in
            c:*"$_cl_esc[${_cl_color}m"*|rc:*"$_cl_esc[${_cl_color}m"*) _cl_ok=1 ;;
            c:*|rc:*) _cl_ok=0 ;;
            *"$_cl_esc[${_cl_color}m"*) _cl_ok=0 ;;
            *) _cl_ok=1 ;;
        esac
        _selftest_assert_eq "配色: $_cl_case" "1" "$_cl_ok"
    done
    # 配色契约：命令色必须一眼可辨。
    #
    # 上面那组只验"标了 c/rc 的行出命令色"，是行为层面的同义反复——
    # 把 cmd 改成与标题相同的青色，它照样全绿（实测：一条都不红）。
    # 缺的正是用户实际感受到的那件事：能整行复制的命令，颜色必须与其他角色都不同。
    _cc_cmd=$(style_color cmd)
    _selftest_assert_eq "配色: 命令色有值（不是默认前景）" "1" "$([ -n "$_cc_cmd" ] && echo 1 || echo 0)"
    _selftest_assert_eq "配色: 命令色不等于标题色" "1" "$([ "$_cc_cmd" != "$(style_color title)" ] && echo 1 || echo 0)"
    _selftest_assert_eq "配色: 命令色不等于段标题色" "1" "$([ "$_cc_cmd" != "$(style_color heading)" ] && echo 1 || echo 0)"
    _cc_clash=""
    for _cc_r in item key value warn dim text; do
        if [ "$_cc_cmd" = "$(style_color "$_cc_r")" ]; then _cc_clash="$_cc_clash $_cc_r"; fi
    done
    _selftest_assert_eq "配色: 命令色不与其余角色撞色" "" "$_cc_clash"
    # 每个角色的颜色名都要在映射表里：写错一个名字不会报错，只会静默变默认色——
    # 那正是"这一行怎么没颜色"这类毛病的来源。
    _cc_missing=""
    for _cc_r in $STYLE_ROLES; do
        _cc_n=$(style_color_of_role "$_cc_r")
        case " $STYLE_COLOR_NAMES " in
            *" $_cc_n "*) ;;
            *) _cc_missing="$_cc_missing $_cc_r=$_cc_n" ;;
        esac
    done
    _selftest_assert_eq "配色: 每个角色的颜色名都在映射表里" "" "$_cc_missing"
    # 状态页的行结构：标签固定 key 色，内容按状态取角色。
    # 原来每一行把「标签 : 内容」整行套一个角色，于是"代理变量 : 无"整行变灰、
    # 标签也跟着灰——用户最先看的恰恰是标签。这条钉住"标签走 _status_row"这个结构。
    _sr_bad=""
    for _sr_lbl in 监控进程 开机自启 翻墙代理 终端同步 代理变量 版本; do
        all_lib_source | grep -q "_status_row \"$_sr_lbl\"" || _sr_bad="$_sr_bad $_sr_lbl(缺)"
        # 不许再有"整行同色 + 标签 : 内容"的老写法
        if all_lib_source | grep -qE "style_out (ok|warn|dim) \"$_sr_lbl : "; then
            _sr_bad="$_sr_bad $_sr_lbl(整行同色)"
        fi
    done
    _selftest_assert_eq "状态页: 每行都走分段渲染" "" "$_sr_bad"
    # 卸载必须把运行时状态清干净：漏一个就"没恢复到装之前"，而屏幕照样报"已完成"。
    # 具体后果（都实际发生过或差点发生）：
    #   version.cache  -> 重装后状态页显示上一次安装留下的版本号；
    #   update.inprogress -> 被读成"上次更新没完成"，其实是上一次安装的经历；
    #   stopped.intent -> 重装后状态页说"你点过停止"而监控正在跑；
    #   .lock 空目录   -> 新监控 mkdir 失败，多绕一圈接管分支。
    # 这里抽源码核对，判据是**结构**而不是"这些名字出现过"：
    #   ① 卸载函数必须走那份共用清单（monitor_runtime_files）去删；
    #   ② 那份清单必须逐项点到下面这些文件。
    # 为什么分两步：原来删除处内联一串 rm -f、复检处一个都没查，删失败也报"已完成"。
    # 抽成一份清单后，删除、复检、以及这条用例看的是同一个来源——
    # 将来漏加一个文件，这里会红；而"删了忘了查"在结构上就不可能再发生。
    _un_body=$(all_lib_source | sed -n "/^uninstall_envproxy()/,/^}/p")
    # 用 grep -q 而不是 `case` 套在命令替换里：后者在 macOS 自带的 bash 3.2 上
    # 表现与新版 bash 不同（实测 CI 报出的是半截 case 正文），而这条用例
    # 要在真机上跑，不能用「本地能过」当标准。
    if printf '%s' "$_un_body" | grep -q 'monitor_runtime_files'; then _un_uses=1; else _un_uses=0; fi
    _selftest_assert_eq "卸载: 删除走共用清单（不内联重列）" "1" "$_un_uses"
    _un_files=$(all_lib_source | sed -n "/^monitor_runtime_files()/,/^}/p")
    _un_bad=""
    for _un_f in 'VERSION_CACHE' 'update.inprogress' 'STOP_INTENT' 'PID_FILE' 'STOP_FLAG' 'SNAPSHOT_FILE' 'notify.last'; do
        case "$_un_files" in
            *"$_un_f"*) ;;
            *) _un_bad="$_un_bad $_un_f(缺)" ;;
        esac
    done
    _selftest_assert_eq "卸载: 共用清单逐项点到（删了必查）" "" "$_un_bad"
    # 目录只删空的：使用者在 ~/.envproxy 里自己放的东西一个字节都不许动。
    case "$_un_body" in
        *'rmdir "$ENVPROXY_HOME"'*) _un_rmdir=1 ;;
        *) _un_rmdir=0 ;;
    esac
    _selftest_assert_eq "卸载: 工具目录只在空时才删（不碰使用者的东西）" "1" "$_un_rmdir"
    _selftest_assert_eq "状态页: 标签色就是 key 色" "97" "$(style_color key)"
    # 颜色名清单只是"枚举源"，真正决定渲染的是 style_code_of_name 的 case 分支。
    # 只比清单的话，把 case 标签写错一个字母（darkgray -> darkgrey）不会有任何断言红，
    # 而那一档颜色会静默变成"无色"——实测确认过这一点。
    # 所以这里逐个名字去求编码，要求非空（none 本来就该是空）。
    _cc_bad=""
    for _cc_n in $STYLE_COLOR_NAMES; do
        [ "$_cc_n" = "none" ] && continue
        if [ -z "$(style_code_of_name "$_cc_n")" ]; then _cc_bad="$_cc_bad $_cc_n"; fi
    done
    _selftest_assert_eq "配色: 每个颜色名都能查出编码" "" "$_cc_bad"
    # 反过来也要查：角色表用到的每一个颜色名，都必须真的解析成非空编码。
    # 这一条是"清单对、角色对、case 错"的唯一拦法。
    _cc_unresolved=""
    for _cc_r in $STYLE_ROLES; do
        _cc_n=$(style_color_of_role "$_cc_r")
        [ "$_cc_n" = "none" ] && continue
        if [ -z "$(style_code_of_name "$_cc_n")" ]; then _cc_unresolved="$_cc_unresolved $_cc_r=$_cc_n"; fi
    done
    _selftest_assert_eq "配色: 每个角色都能解析出编码" "" "$_cc_unresolved"

    # 从 proxy.env 取端口：IPv6 地址必须取对。
    #
    # 判据是"取最后一段数字"，不是"第一个 :数字"。注入值可能是
    # http://[::1]:7078，而 grep -oE ':[0-9]+' 会先命中 "::1" 里的 ":1"，
    # 返回 1 —— 调用方把它拼成 http://127.0.0.1:<端口>，状态页就会显示
    # "已注入 (127.0.0.1:1)"。对只绑 ::1 的代理，那是一条看起来正常、
    # 实则完全错的结论（比检测不到更糟）。
    _pp_saved="$PROXY_ENV"
    PROXY_ENV="$_sandbox/getport.env"
    # 用变量拼内容，不写字面量 `printf 'export HTTP_PROXY=...'`：
    # 门禁 6 用 `^\s*printf 'export ([A-Za-z_]+)=` 从**整份 mac 语料**里提取变量名清单，
    # 而 mc/*.sh 的通配把本文件也算进去了——这里每写一次字面量，就会被当成一次"变量定义"，
    # 于是"macOS 变量数不是 9"。
    _pp_k='HTTP_PROXY'
    for _pp_case in "http://127.0.0.1:7078:7078" "http://[::1]:7078:7078" "http://127.0.0.1:9999:9999"; do
        _pp_url=${_pp_case%:*}
        _pp_want=${_pp_case##*:}
        printf 'export %s="%s"\n' "$_pp_k" "$_pp_url" > "$PROXY_ENV"
        _selftest_assert_eq "取端口：$_pp_url" "$_pp_want" "$(get_current_proxy_port)"
    done
    rm -f "$PROXY_ENV" 2>/dev/null || true
    PROXY_ENV="$_pp_saved"

    # 快照归属：归属记录里有的值，即使是"首次安装"也不该进快照。
    #
    # 为什么：首次安装的推断前提是"机器上还没有我们的东西"，而卸载没清干净时
    # 那个前提不成立——残留的本机地址代理值会在下一次全新安装时被当成使用者的、
    # 存进快照、再按快照还原，于是永远清不掉（Windows 侧实测踩过，
    # ALL_PROXY 与 NODE_USE_ENV_PROXY 活过了两次卸载）。两边同一套机制，同一个洞。
    #
    # 这一组要在受控的 owned.env 下跑：先备份真实文件、单独造一份，跑完还原。
    # 不这样做的话，同一条断言在"装过的机器"和"干净的机器"上会得出相反结论。
    _ss_owned_backup=""
    if [ -f "$OWNED_ENV" ]; then
        _ss_owned_backup="$OWNED_ENV.testbak.$$"
        cp "$OWNED_ENV" "$_ss_owned_backup" 2>/dev/null || _ss_owned_backup=""
    fi
    mkdir -p "$ENVPROXY_HOME" 2>/dev/null || true
    printf 'HTTP_PROXY\thttp://127.0.0.1:7890\nNODE_USE_ENV_PROXY\t1\n' > "$OWNED_ENV" 2>/dev/null
    if snapshot_skip_value HTTP_PROXY "http://127.0.0.1:7890" 1; then _ss1=1; else _ss1=0; fi
    _selftest_assert_eq "首次安装：归属记录里有的值不进快照" "1" "$_ss1"
    if snapshot_skip_value NODE_USE_ENV_PROXY "1" 1; then _ss2=1; else _ss2=0; fi
    _selftest_assert_eq "首次安装：NODE_USE_ENV_PROXY=1 在记录里，不进快照" "1" "$_ss2"
    # 记录里没有的值：首次安装时只可能是使用者自己设的，必须进快照（否则丢配置）。
    if snapshot_skip_value HTTPS_PROXY "http://127.0.0.1:9999" 1; then _ss3=1; else _ss3=0; fi
    _selftest_assert_eq "首次安装：记录里没有的本机地址仍算使用者的" "0" "$_ss3"
    # 别人的代理地址从来不跳过。
    if snapshot_skip_value HTTP_PROXY "http://10.0.0.1:8080" 0; then _ss4=1; else _ss4=0; fi
    _selftest_assert_eq "别人的代理地址从来不跳过" "0" "$_ss4"
    # 还原真实文件。
    rm -f "$OWNED_ENV" 2>/dev/null || true
    if [ -n "$_ss_owned_backup" ] && [ -f "$_ss_owned_backup" ]; then
        mv "$_ss_owned_backup" "$OWNED_ENV" 2>/dev/null || true
    fi

    # 失败后要不要"换个出口再试一次"，判据只有一条：这个失败是不是由出口决定的。
    # 与 Windows 侧 Test-RetryWithProxy 同一批结论（门禁 6 再核一次两侧同形）。
    # 判错的代价不对称：该换不换（quota）只能去走更慢的兜底——实测直连配额用尽时
    # 同地址经代理 468ms 就通，兜底要 8.7 秒；不该换却换（missing/server）白等一轮，
    # 还把真实原因盖掉。两种都是"看起来能跑、其实慢或误导"，只有断言看得见。
    for _re_case in "network:1" "quota:1" "server:0" "missing:0" "bad-content:0" "local:0"; do
        _re_k=${_re_case%%:*}
        _re_want=${_re_case#*:}
        if retry_with_other_exit "$_re_k"; then _re_got=1; else _re_got=0; fi
        _selftest_assert_eq "换出口判据: $_re_k" "$_re_want" "$_re_got"
    done
    # README 抄了一份菜单表和帮助目录，必须与代码逐项一致。抄的那一份一旦脱节，
    # 后果不是"文档旧了"，而是用户照 README 的编号去敲、敲到另一件事。这类错误
    # 没人会当场发现——文档看着很正常。Windows 侧同一道断言在 [21]，两侧都要有：
    # 只在 Mac 本地跑 self-test 时，这条路径上同样要能查出来。
    _rm_dir=$(cd "$SCRIPT_DIR/.." && pwd)
    for _rm_pair in "README.md" "README.en.md"; do
        _rm_f="$_rm_dir/$_rm_pair"
        if [ ! -f "$_rm_f" ]; then
            _selftest_assert_eq "$_rm_pair 存在" "1" "0"
            continue
        fi
        # 菜单表：左侧是 **编号 名称**，收集编号序列再与 MENU_ITEMS 比。
        # 标注「仅 Windows」的行不算：那一项在这个平台上不存在，README 必须能写出来
        # （不写就等于隐瞒了一个平台差异），但它不该被当成"文档与代码不一致"。
        _rm_doc_keys=$(grep -vE '^\|\s*\*\*[0-9]+ .*(（仅 Windows）|Windows only)' "$_rm_f" | grep -oE '^\|\s*\*\*[0-9]+ ' | tr -cd '0-9\n' | tr '\n' ',' )
        _rm_code_keys=$(for _rm_i in "${MENU_ITEMS[@]}"; do printf '%s\n' "${_rm_i%%|*}"; done | tr '\n' ',')
        _selftest_assert_eq "$_rm_pair 菜单表编号与代码一致" "$_rm_code_keys" "$_rm_doc_keys"
        # 帮助目录表：表头「编号 / No.」，取每行第一格。
        _rm_help_keys=$(awk '/^\| *(编号|No\.) *\|/{f=1;next} f&&/^\|/{print}' "$_rm_f" | grep -oE '^\|\s*[0-9]+' | tr -cd '0-9\n' | tr '\n' ',')
        _rm_code_help=$(printf '%s\n' "${HELP_TOPIC_KEYS[@]}" | tr '\n' ',')
        _selftest_assert_eq "$_rm_pair 帮助目录编号与代码一致" "$_rm_code_help" "$_rm_help_keys"
    done
    # 中文那份还要比名字：编号对上但名字配错，照样把人指到另一个动作上。
    _rm_zh="$_rm_dir/README.md"
    if [ -f "$_rm_zh" ]; then
        for _rm_i in "${MENU_ITEMS[@]}"; do
            _rm_key=${_rm_i%%|*}
            _rm_rest=${_rm_i#*|}
            _rm_name=${_rm_rest%%|*}
            if grep -qF "**$_rm_key $_rm_name**" "$_rm_zh"; then _rm_ok=1; else _rm_ok=0; fi
            _selftest_assert_eq "README 菜单 $_rm_key 写作 $_rm_name" "1" "$_rm_ok"
        done
        for _rm_k in "${HELP_TOPIC_KEYS[@]}"; do
            _rm_t=$(_help_topic_title "$_rm_k")
            if grep -qF "| $_rm_k | $_rm_t |" "$_rm_zh"; then _rm_ok2=1; else _rm_ok2=0; fi
            _selftest_assert_eq "README 帮助 $_rm_k 写作 $_rm_t" "1" "$_rm_ok2"
        done
    fi
    # 屏幕形状：和 Windows 侧同一类防护。文案层的坏法（整屏超长、重复行、
    # 超宽行、写死绝对路径、命令残缺）靠"关键词还在不在"查不出来，只能量形状。
    # 两端各有一份，改文案时两边一起被守住——这是"行为改动双侧同改"的落地。
    for _sk in "${HELP_TOPIC_KEYS[@]}"; do
        # 0) 渲染过程不许有 shell 报错。实测踩过：把"求最宽列宽"收敛成公共函数时，
        #    取到的不是宽度而是字符串，于是 $((宽 - 长)) 把 "zsh / bash" 里的斜杠
        #    当成除号，屏幕上直接打出 division by 0。文案断言全绿、形状断言也全绿，
        #    只有真的渲染一次才看得见——所以把"stderr 必须为空"钉住。
        _sr_err=$(format_help_topic "$_sk" 2>&1 >/dev/null)
        _s0=1; [ -n "$_sr_err" ] && _s0=0
        _selftest_assert_eq "主题 $_sk 渲染时没有 shell 报错" "1" "$_s0"
        _sr=$(format_help_topic "$_sk")
        # 1) 一屏放得下：超出的部分会被终端切掉，常被切掉的正是底部的"怎么退出"。
        _sn=$(printf '%s\n' "$_sr" | wc -l | tr -d ' ')
        if [ "$_sn" -le "$HELP_MAX_LINES" ]; then _s1=1; else _s1=0; fi
        _selftest_assert_eq "主题 $_sk 在 $HELP_MAX_LINES 行内" "1" "$_s1"
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
        # 只有这一行：原来这里连着写了两遍同样的赋值，删掉重复的那一遍即可，
        # 不能两行都删——_s3 是下面那条断言的初值（超宽时会被置 0）。
        _s3=1
        # wc -L 给的是显示宽度（中文算 2 列），比 awk 的 length 靠谱——
        # 后者在某些 awk 实现里按字节算，一个中文字就顶 3。
        _swide=""
        while IFS= read -r _sline; do
            # 不能用 wc -L：那是 GNU 扩展，macOS 自带的 BSD wc 只支持 -clmw。
            # 在 macOS 上它会报 illegal option、输出为空，而下面那句 `-z && _sw=0`
            # 会把空值兜成 0——于是"主题无超宽行"这条断言在 macOS 上永远绿，
            # 实际什么都没测。用 base 层的 _display_width：纯 shell、零 fork、已处理 CJK 宽度。
            _sw=$(_display_width "$_sline")
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
    if [ -n "$(get_update_repo)" ]; then _st2=1; else _st2=0; fi
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
    # 接线：重试之后必须走挑选规则，不许把后一次的原因直接盖上去。
    #
    # 这条防的是一个真实发生过的 bug：挑选函数与它的断言都在，但调用方
    # 直接拿重试那次的结论覆盖了整个规则。于是"第一次 quota（配额用尽，等一小时）、
    # 重试后 server（对方故障）"时报了 server——用户照着等一会儿，怎么等都没用。
    # 断言测函数怎么挑，测不出"没人调它"，只能读源码看调用点。
    _ftt_src=$(sed -n '/^fetch_update_text()/,/^}/p' "$SCRIPT_DIR/lib/update.sh")
    _ftt_line=$(printf '%s\n' "$_ftt_src" | grep -c 'select_update_failure_kind')
    _selftest_assert_eq "接线：问版本的重试路径走挑选规则" "1" "$_ftt_line"
    # 回环地址不该经代理重试：给 127.0.0.1 设代理没有意义，只会让本机服务忽好忽坏。
    _selftest_assert_eq "接线：重试前先判是不是回环地址" "1" "$(printf '%s\n' "$_ftt_src" | grep -c 'is_loopback_url')"
    _selftest_assert_eq "回环判据: http://127.0.0.1:7078" "True" "$(is_loopback_url 'http://127.0.0.1:7078' && echo True || echo False)"
    _selftest_assert_eq "回环判据: http://[::1]:7078" "True" "$(is_loopback_url 'http://[::1]:7078' && echo True || echo False)"
    _selftest_assert_eq "回环判据: http://localhost:8080/" "True" "$(is_loopback_url 'http://localhost:8080/' && echo True || echo False)"
    _selftest_assert_eq "回环判据: http://LOCALHOST:7890" "True" "$(is_loopback_url 'http://LOCALHOST:7890' && echo True || echo False)"
    _selftest_assert_eq "回环判据: http://127.0.0.2:7890" "True" "$(is_loopback_url 'http://127.0.0.2:7890' && echo True || echo False)"
    _selftest_assert_eq "回环判据: http://user:pw@localhost:7890" "True" "$(is_loopback_url 'http://user:pw@localhost:7890' && echo True || echo False)"
    _selftest_assert_eq "回环判据: https://api.github.com/repos/o/r" "False" "$(is_loopback_url 'https://api.github.com/repos/o/r' && echo True || echo False)"
    _selftest_assert_eq "回环判据: http://192.168.1.5:7078/" "False" "$(is_loopback_url 'http://192.168.1.5:7078/' && echo True || echo False)"
    _selftest_assert_eq "回环判据: http://[2001:db8::1]:8080/" "False" "$(is_loopback_url 'http://[2001:db8::1]:8080/' && echo True || echo False)"
    _selftest_assert_eq "回环判据: http://localhost.:7890" "False" "$(is_loopback_url 'http://localhost.:7890' && echo True || echo False)"
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
    # 判据是"有没有给出下一步可做动作"，不是"有没有出现某个具体词"。
    # 原来钉的是"必须含『代理』"——那会逼着文案写机制词，与门禁 14（面向用户不许用
    # 机制词）直接冲突；正确的做法是钉用户能照做的动作，措辞怎么换都成立。
    _selftest_assert_contains "提示：连不上要给出下一步动作" "重试" "$_ufm_n"
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
    # 卸载带 --yes 必须放行：问不到人时它会拒绝执行，--yes 是那种场合唯一的出路。
    # 这条判据之前只有 update 一条断言，所以 AGENTS.md 里 "-Yes 只配 -Update" 那句
    # 错的约定一直没人发现——改窄了不会有任何东西红。
    _ue_check "uninstall" 1 "yes" ""; _selftest_assert_eq "用法判定：卸载带 --yes 放行" "0" "$?"
    _ue_check "uninstall" 1 "yes purge" ""; _selftest_assert_eq "用法判定：卸载带 --yes --purge 放行" "0" "$?"
    _ue_check "install" 1 "purge" ""; _selftest_assert_eq "用法判定：--purge 跟着别的命令要拒" "1" "$?"
    _ue_check "status" 1 "yes" ""; _selftest_assert_eq "用法判定：--yes 跟着别的命令要拒" "1" "$?"
    _ue_check "status" 1 "" "--foo"; _selftest_assert_eq "用法判定：不认识的参数要拒" "1" "$?"
    _ue_check "install" 2 "" ""; _selftest_assert_eq "用法判定：一次给两个命令要拒" "1" "$?"
    # 光秃秃的横线：入口用 sed 剥前缀，`-`/`--`/`---` 都会归一化成空串，
    # 而命令个数仍是 1。不拒的话它会落到分派的 "" 分支——那是监控模式，
    # 于是"敲错一个横线"变成"在后台起了个常驻进程"，屏幕上还没有任何报错。
    _ue_check "" 1 "" ""; _selftest_assert_eq "用法判定：只有一个空命令要拒（不许当成监控模式）" "1" "$?"
    # 对照：真没传参数（个数 0）必须继续放行，否则监控模式就彻底起不来了。
    _ue_check "" 0 "" ""; _selftest_assert_eq "用法判定：真无参数仍放行（监控模式）" "0" "$?"

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

    # --------------------------------------------------------------------------
    # 接线（源码级）：这些地方"删掉一行就静默失效"
    # --------------------------------------------------------------------------
    # 与 Windows 侧同一套理由：破坏测试发现这套门禁擅长拦格式与常量，不擅长拦"减法"——
    # 删掉一行关键调用，所有门禁照绿，产品却彻底不能用。这里读源码确认调用还在。
    # 只验接线，不验行为；行为由上面的纯函数用例负责。
    # 只用 POSIX 可移植写法：grep -c -F 数字面量、sed 取函数体、shell 算术。
    # 不用 awk：GNU awk 与 BSD awk 对动态正则、转义、区间表达式的处理不一致，
    # 结果是"在 Git Bash 上通过、在真正的 macOS 上失败"——测试本身成了故障源。
    _wiring_count() { # 文件 字面量
        _wc=$(grep -c -F -- "$2" "$1" 2>/dev/null || true)
        [ -n "$_wc" ] || _wc=0
        echo "$_wc"
    }
    _wiring_fn_count() { # 文件 函数名 字面量
        _fc=$(sed -n "/^$2 *() *{/,/^}/p" "$1" 2>/dev/null | grep -c -F -- "$3" || true)
        [ -n "$_fc" ] || _fc=0
        echo "$_fc"
    }
    # 装配：入口无参数时必须进监控主循环（开机自启走的就是这条路）。
    _w1=$(_wiring_count "$SCRIPT_DIR/envproxy.sh" run_monitor_loop)
    _selftest_assert_eq "接线：入口会进入监控主循环" 1 "$([ "$_w1" -ge 1 ] && echo 1 || echo 0)"
    # 装配：候选端口确认必须过"真实节点连通"，两个分支各一次。
    # 只数函数体里的命中：整文件计数会漏判（probe.sh 里另有几处同名调用）。
    _w2=$(_wiring_fn_count "$SCRIPT_DIR/lib/probe.sh" confirm_candidate_port test_node_alive)
    _selftest_assert_eq "接线：候选确认会验证真实节点（两处分支）" 1 "$([ "$_w2" -ge 2 ] && echo 1 || echo 0)"
    # 装配：清理门槛会被真正调用（apply-state 与监控自愈各一处）。
    # 只数**真正的调用**：_wiring_count 数全文命中，而 env.sh 里 proxy_vars_present
    # 还在函数定义那一行、以及两句解释性注释里出现——把两个真实调用点全删掉，
    # 命中数照样够，断言照样绿。判据改成"剥掉注释行、去掉函数定义行"。
    _w3=0
    for _w3f in "$SCRIPT_DIR/lib/env.sh" "$SCRIPT_DIR/lib/runtime.sh"; do
        _w3=$((_w3 + $(sed -e 's/^[[:space:]]*#.*//' -e '/^[[:space:]]*proxy_vars_present()[[:space:]]*{/d' "$_w3f" 2>/dev/null | grep -c -F 'proxy_vars_present' || true)))
    done
    _selftest_assert_eq "接线：清理门槛被至少两处调用" 1 "$([ "$_w3" -ge 2 ] && echo 1 || echo 0)"
    # 装配：门槛本身必须真的去问归属记录。
    _w4=$(_wiring_count "$SCRIPT_DIR/lib/env.sh" is_owned_proxy_value)
    _selftest_assert_eq "接线：清理门槛会问归属记录" 1 "$([ "$_w4" -ge 1 ] && echo 1 || echo 0)"
    # 装配：状态去抖必须比的是常量，不是字面量。
    # 判据是"比较的是那个常量"，不是"文件里出现过它"——定义那一行也会出现，
    # 只数出现次数的话，把比较改成字面量 1 照样通过。
    _w5=$(_wiring_count "$SCRIPT_DIR/lib/runtime.sh" '-ge "$STATE_DEBOUNCE_ROUNDS"')
    _selftest_assert_eq "接线：去抖比的是常量" 1 "$([ "$_w5" -ge 1 ] && echo 1 || echo 0)"

    # ---- 赋值语句不许有空格 ----
    # `x = $(cmd)` 在 shell 里不是赋值，是"运行 x 命令、参数是 = 和 $(cmd)"：
    # 结果是变量没被赋上、还往 stderr 刷一条 command not found。
    # ops.sh 里真发生过一次（`_tr_c = $(style_color cmd)`），后果是安装结尾那几行
    # 提示在终端里一行都打不出来、退出码变 1——而 `bash -n` 完全看不出问题，
    # 因为它在语法上是合法的。所以只能靠扫源码形状来挡。
    #
    # 两种写法都要挡：`x =$(...)` 与 `x= $(...)`。只查"="后面跟空格的话，
    # 前者（"="前面有空格、后面紧贴 $(）会漏过去——而它一样不是赋值。
    # 判据：名字后面出现空白再跟"="，就一定是错的（真赋值不许有空白）。
    #
    # **必须排除引号里的内容**：awk/sed 的程序体常写成跨多行的单引号字符串，
    # 里面的 `n = NF`、`host = $(n - 2)` 是 awk 语法、完全合法，不是 shell 赋值。
    # 早先这条只扫 ops.sh（那里恰好没有 awk），所以一直是绿的；改成扫全库后
    # 立刻命中了 31 处 awk 赋值——那说明判据本身不够准，不是代码坏了。
    #
    # 做法：先用一个小状态机把**所有单引号字符串**（可跨行）整体抹掉，再在剩下的
    # shell 代码里查。跨行是关键——逐行正则做不到，实测会漏。
    _sp_stripped=$(all_lib_source | awk '
        BEGIN { inq = 0 }
        {
            line = $0; out = ""; i = 1
            while (i <= length(line)) {
                c = substr(line, i, 1)
                if (inq == 0) {
                    if (c == "\047") { inq = 1; out = out "QUOTED"; i++; continue }
                    out = out c; i++
                } else {
                    if (c == "\047") { inq = 0 }
                    i++
                }
            }
            print out
        }')
    _sp_assign=$(printf '%s\n' "$_sp_stripped" | grep -cE '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]+=' 2>/dev/null)
    _selftest_assert_eq "接线：库里没有带空格的 shell 赋值语句（引号内的 awk 程序体除外）" "0" "$_sp_assign"

    # ---- 状态分支必须覆盖 ok ----
    # show_status 的 `case "$_ts_state"` 只管"有问题的几种"，正常态由后面单独打一行。
    # 漏掉 ok 时最正常的状态会落进 `*)`，于是每个装对了的人都看到
    # 「终端同步 : 状态未知（ok）」——同一屏两行说法相反，比不报还糟。
    # 这里直接数 case 里有没有 ok) 这一支，缺了就红。
    _ts_ok_branch=$(all_lib_source | sed -n '/case "\$_ts_state" in/,/^    esac$/p' | grep -cE '^[[:space:]]+ok\)')
    _selftest_assert_eq "接线：状态 case 覆盖 ok 分支" "1" "$([ "$_ts_ok_branch" -ge 1 ] && echo 1 || echo 0)"

    # ---- 安装收尾必须清掉"更新中断"标记 ----
    # 那个标记的语义是"我正在改安装区"。它只在覆盖成功路径上被删，
    # 于是备份失败（一个文件都没改）时标记留在磁盘上，状态页永久报
    # 「上次更新没有完成」，并让用户「选 1 重做一次」——重做真的成功了，
    # 标记还在，屏幕上是同一句警告：一条自己都说错了怎么修的指引。
    # 两处都要：package.sh 里挪到备份成功之后写；install 收尾兜一次。
    _ip_in_install=$(all_lib_source | sed -n '/^install_envproxy()/,/^}/p' | grep -c 'update\.inprogress')
    _selftest_assert_eq "接线：安装收尾会清更新中断标记" "1" "$([ "$_ip_in_install" -ge 1 ] && echo 1 || echo 0)"

    # ---- 标记的写入必须在备份成功之后 ----
    # 数 package.sh 里"备份完整性检查"与"写标记"的先后：写标记的行号必须更大。
    _ip_mark_ln=$(grep -n 'update\.inprogress' "$SCRIPT_DIR/lib/package.sh" | head -n 1 | cut -d: -f1)
    _ip_bak_ln=$(grep -n '拒绝更新：覆盖前的备份没有完整做成' "$SCRIPT_DIR/lib/package.sh" | head -n 1 | cut -d: -f1)
    _ip_marker_write_ln=$(grep -n 'printf .%s.n. .\$(date -u' "$SCRIPT_DIR/lib/package.sh" | head -n 1 | cut -d: -f1)
    _ip_ok=0
    if [ -n "$_ip_marker_write_ln" ] && [ -n "$_ip_bak_ln" ] && [ "$_ip_marker_write_ln" -gt "$_ip_bak_ln" ]; then _ip_ok=1; fi
    _selftest_assert_eq "接线：更新标记在备份成功之后才写" "1" "$_ip_ok"

    # ---- 版本行必须走 _status_row ----
    # 「标签固定色、内容按状态变色」是状态页的硬契约（与 Win 侧同形）。
    # 版本行曾用 style_out "$_role" 整行套色，标签也跟着变；而旧的自检正则
    # 把角色写死成 ok|warn|dim，那个写法它匹配不到，于是假绿。
    #
    # 判据要数**两处**（"没查过最新版" 与 "查过"），只数 >=1 的话，
    # 把其中一处改回整行套色、另一处仍在，断言照样绿——它只管住了"至少一处"，
    # 没有管住"每一处"。同时直接禁掉整行套色那种写法：只要出现
    # `style_out ... "版本 : ` 就是错的（"版本 : " 里那个空格是全角冒号前的空格，
    # 只有整行套色那版才会这么拼）。
    _ver_row=$(all_lib_source | grep -c '_status_row "版本"')
    _selftest_assert_eq "接线：版本行两处都走分段渲染" "2" "$_ver_row"
    _ver_bad=$(all_lib_source | grep -cE 'style_out .*"版本 : ' 2>/dev/null)
    _selftest_assert_eq "接线：版本行没有整行套色写法" "0" "$_ver_bad"

    # ---- 子命令表必须与入口分派一致 ----
    # is_monitor_args 用来复核 pid 文件里的进程是不是监控。它的子命令清单
    # 与入口分派是两份手写清单，漂移后会把"带子命令的进程"认成监控。
    _sub_in_args=$(sed -n '/^is_monitor_args()/,/^}/p' "$SCRIPT_DIR/lib/runtime.sh" | grep -oE 'install\|stop[^)]*' | head -n 1)
    _sub_missing=""
    for _sub in install stop uninstall status repair-profile update menu help self-test; do
        case "$_sub_in_args" in *"$_sub"*) : ;; *) _sub_missing="$_sub_missing $_sub";; esac
    done
    _selftest_assert_eq "接线：监控识别覆盖全部入口子命令" "" "$_sub_missing"

    # ------------------------------------------------------------------------------
    echo "[11] 自启动语义：登录时拉起一次，不保活"
    # 契约（AGENTS.md「自启动 = 登录时拉起一次，不保活」）：
    #   RunAtLoad 必须有 —— 否则登录后监控不会起来，用户重开电脑就失去代理；
    #   KeepAlive 必须没有 —— 写了它，launchd 会在 job 主进程退出后无条件重启，
    #   而监控平时由 nohup 起、自己管生命周期，两者叠加就是每 10 秒 fork 一次。
    # 这条以前没有任何断言，改 plist 模板时写错一个字就能让"停止"变成"停不掉"。
    _pl=$(get_plist_content 2>/dev/null || true)
    _pl_run=0; _pl_keep=0
    case "$_pl" in *"<key>RunAtLoad</key><true/>"*) _pl_run=1;; esac
    case "$_pl" in *"<key>KeepAlive</key>"*) _pl_keep=1;; esac
    _selftest_assert_eq "plist 声明 RunAtLoad（登录时拉起一次）" "1" "$_pl_run"
    _selftest_assert_eq "plist 不声明 KeepAlive（不接管生命周期）" "0" "$_pl_keep"
    # plist 必须是合法 XML 骨架：缺 <plist> 或 <dict> 会让 launchctl 静默拒收，
    # 而屏幕上"已写进 LaunchAgents"照样打印——用户以为装好了，实际从没起来过。
    _pl_ok=0
    case "$_pl" in
      *"<plist version=\"1.0\">"*"</plist>"*) case "$_pl" in *"<dict>"*"</dict>"*) _pl_ok=1;; esac;;
    esac
    _selftest_assert_eq "plist 有完整的 plist/dict 骨架" "1" "$_pl_ok"

    # ------------------------------------------------------------------------------
    echo "[12] 运行时目录能重建且幂等"
    # 契约：目录被清理工具整份删掉后，进程还在干活、pid 文件却写不出来，
    # 状态页就报"未运行"，用户再点安装起第二份、被锁挡掉——再也起不来监控。
    # 所以主循环每轮开头都要能无条件重建目录（幂等）。
    _ed_dir="$_sandbox/monitor_ensure_test"
    rm -rf "$_ed_dir" 2>/dev/null || true
    _ed_1=0; mkdir -p "$_ed_dir" 2>/dev/null && [ -d "$_ed_dir" ] && _ed_1=1
    _selftest_assert_eq "运行时目录能建出来" "1" "$_ed_1"
    _ed_2=0; mkdir -p "$_ed_dir" 2>/dev/null && _ed_2=1
    _selftest_assert_eq "重复创建是幂等的（每轮都调不会失败）" "1" "$_ed_2"

    echo "[13] 系统代理判据表（doctor）"
    # 判据表就是「不能误删」这条底线的机械证明：只有"本机回环 + 端口不通"才允许修。
    # 与 Windows 侧同一张表、同一批结论词（门禁 6 核对）。
    _selftest_assert_eq "判据：压根没设代理" "clean" "$(sysproxy_verdict '' 0 unknown 0 manual)"
    _selftest_assert_eq "判据：回环死端口可修（真断网）" "residue-blocking" "$(sysproxy_verdict 'http://127.0.0.1:7078' 7078 dead 0 manual)"
    _selftest_assert_eq "判据：回环活端口不动" "alive" "$(sysproxy_verdict 'http://127.0.0.1:7078' 7078 alive 0 manual)"
    _selftest_assert_eq "判据：localhost 也算回环" "residue-blocking" "$(sysproxy_verdict 'http://localhost:7890' 7890 dead 0 manual)"
    _selftest_assert_eq "判据：方括号 IPv6 也算回环" "residue-blocking" "$(sysproxy_verdict 'http://[::1]:10808' 10808 dead 0 manual)"
    _selftest_assert_eq "判据：PAC 死端口是卡不是断" "residue-slowing" "$(sysproxy_verdict 'http://127.0.0.1:7078/pac' 7078 dead 0 pac)"
    _selftest_assert_eq "判据：公司代理永远不碰" "foreign" "$(sysproxy_verdict 'http://10.0.0.8:8080' 8080 dead 0 manual)"
    _selftest_assert_eq "判据：域名代理永远不碰" "foreign" "$(sysproxy_verdict 'http://proxy.corp.com:3128' 3128 dead 0 manual)"
    _selftest_assert_eq "判据：被策略管着优先于一切" "managed" "$(sysproxy_verdict 'http://127.0.0.1:7078' 7078 dead 1 manual)"
    _selftest_assert_eq "判据：说不清就不动" "foreign" "$(sysproxy_verdict 'http://127.0.0.1:7078' 7078 unknown 0 manual)"
    _k=0; sysproxy_fixable residue-blocking && _k=1
    _selftest_assert_eq "可修：blocking" "1" "$_k"
    _k=0; sysproxy_fixable residue-slowing && _k=1
    _selftest_assert_eq "可修：slowing" "1" "$_k"
    for _nk in alive foreign managed clean; do
        _k=0; sysproxy_fixable "$_nk" && _k=1
        _selftest_assert_eq "不可修：$_nk" "0" "$_k"
    done

    echo "[13b] 判活只连端口，不建隧道（与 Windows 侧同判据）"
    # 这条防的是「把用户正在用的代理关掉」：代理端口活着、但翻墙节点挂了/目标被墙时，
    # 如果用"能不能访问目标"来判活，就会判成 dead → residue-blocking → 救援误删。
    # 实测由子 agent 用真监听端口复现过。判据必须只看 TCP 端口在不在。
    if (exec 3<>"/dev/tcp/127.0.0.1/9") 2>/dev/null; then
        _selftest_assert_eq "自检环境里 127.0.0.1:9 不该有人听（端口挑选前提）" "0" "1"
    else
        _selftest_assert_eq "没人听的端口判 dead" "dead" "$(sysproxy_port_state 127.0.0.1 9)"
    fi
    _selftest_assert_eq "端口 0 判 unknown（不是 dead）" "unknown" "$(sysproxy_port_state 127.0.0.1 0)"
    _selftest_assert_eq "空地址判 unknown（不是 dead）" "unknown" "$(sysproxy_port_state '' 17099)"
    # 用一个临时监听端口验证"活着"这一侧：连得上就必须判 alive。
    (exec 3<>/dev/tcp/127.0.0.1/9) 2>/dev/null || true
    _li_port=""
    for _li_try in 17511 17512 17513 17514 17515; do
        if ! (exec 3<>"/dev/tcp/127.0.0.1/$_li_try") 2>/dev/null; then _li_port="$_li_try"; break; fi
    done
    if [ -n "$_li_port" ]; then
        # 验"端口活着"这一侧。**不用 nc**：macOS 自带的 nc 各版本 -l 的参数顺序不一致
        # （有的要 `-l -p PORT`、有的要 `-l ADDR PORT`），BSD 与 GNU 又不同；
        # 自检依赖它就会在某一版系统上随机红。
        # 改用 python3 起一个纯监听——macOS 12+ 自带 python3（Command Line Tools），
        # 拿不到就跳过这一条，绝不让环境差异变成假红。
        if command -v python3 >/dev/null 2>&1; then
            python3 -c "
import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $_li_port)); s.listen(1)
sys.stderr.write('ready\n'); sys.stderr.flush()
s.settimeout(5)
try: s.accept()
except Exception: pass
" >/dev/null 2>&1 &
            _li_pid=$!
            sleep 1
            _selftest_assert_eq "有人在听 → 判 alive" "alive" "$(sysproxy_port_state 127.0.0.1 "$_li_port")"
            kill "$_li_pid" 2>/dev/null || true
            wait "$_li_pid" 2>/dev/null || true
        else
            echo "  SKIP 没有 python3，跳过'有人在听 → alive'那一条"
        fi
    fi

    echo "[14] 网络救援的备份只写一次，且能读回"
    # 「只写一次」是契约：每次覆盖就失效——用户第一次修之前的原样才是要还原的那个。
    _bk_saved="$MONITOR_DIR"
    MONITOR_DIR="$_sandbox/rescue_bak"
    mkdir -p "$MONITOR_DIR" 2>/dev/null || true
    # 用替身顶掉真实的 networksetup：自检不该读也不该改使用者的系统代理设置。
    networksetup() {
        case "$1" in
            -listallnetworkservices) printf 'An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n' ;;
            -getwebproxy) printf 'Enabled: Yes\nServer: 127.0.0.1\nPort: 7078\nAuthenticated Proxy Enabled: 0\n' ;;
            -getsecurewebproxy|-getsocksfirewallproxy) printf 'Enabled: No\nServer: \nPort: 0\n' ;;
            -getautoproxyurl) printf 'URL: (null)\nEnabled: No\n' ;;
            *) return 0 ;;
        esac
    }
    _bk_1=0; sysproxy_backup >/dev/null 2>&1 && _bk_1=1
    _selftest_assert_eq "备份能写出来" "1" "$_bk_1"
    _selftest_assert_eq "备份文件在" "1" "$([ -f "$MONITOR_DIR/doctor.bak" ] && echo 1 || echo 0)"
    _bk_first=$(cat "$MONITOR_DIR/doctor.bak" 2>/dev/null)
    printf 'Wi-Fi\tweb\tNo\t9.9.9.9\t1\n' > "$MONITOR_DIR/doctor.bak"
    sysproxy_backup >/dev/null 2>&1
    _bk_second=$(cat "$MONITOR_DIR/doctor.bak" 2>/dev/null)
    _selftest_assert_eq "已有备份不被覆盖（只写一次）" "Wi-Fi	web	No	9.9.9.9	1" "$_bk_second"
    unset -f networksetup 2>/dev/null || true
    MONITOR_DIR="$_bk_saved"

    echo "[15] PAC 端口解析、裸 IPv6、地址形态"
    # 三条都对应"永远修不好"或"误判"的真实缺陷。
    # ① PAC 的端口必须从 URL 里解析出来，否则 port=0 → unknown → foreign，
    #    residue-slowing 成了永远不可能产出的死结论词（实测：只修取址不修端口，症状一样）。
    # 先装桩再调用：真机上先调一次真实 networksetup 会读到真值，
    # 而下面几条断言依赖桩的固定输出——那在 CI 上必然红。
    unset -f networksetup 2>/dev/null || true
    networksetup() {
        case "$1" in
            -getautoproxyurl) printf 'URL: http://127.0.0.1:7078/proxy.pac\nEnabled: Yes\n' ;;
            *) return 0 ;;
        esac
    }
    _pp_lines=$(_sysproxy_read_one "Wi-Fi" autoproxy)
    _pp_host=$(printf '%s\n' "$_pp_lines" | sed -n '2p')
    _pp_port=$(printf '%s\n' "$_pp_lines" | sed -n '3p')
    _selftest_assert_eq "PAC 地址取整行（不是切成 http）" "http://127.0.0.1:7078/proxy.pac" "$_pp_host"
    _selftest_assert_eq "PAC 端口从 URL 里解析出来（不是空）" "7078" "$_pp_port"
    _selftest_assert_eq "PAC 回环+死端口 -> residue-slowing" "residue-slowing" "$(sysproxy_verdict "http://127.0.0.1:7078/proxy.pac" 7078 dead 0 pac)"
    _selftest_assert_eq "PAC 回环+活端口 -> alive" "alive" "$(sysproxy_verdict "http://127.0.0.1:7078/proxy.pac" 7078 alive 0 pac)"
    _selftest_assert_eq "PAC 非回环 -> foreign" "foreign" "$(sysproxy_verdict "http://10.0.0.8:8080/x.pac" 8080 dead 0 pac)"
    # 边界：带路径 / 不带路径 / 无端口 / file:// —— 每种都要正确取（或不取）端口。
    # 这条防的是"先按 / 截路径、把 http:// 的协议斜杠也截掉"，那会让端口全变空。

    unset -f networksetup 2>/dev/null || true
    networksetup() { case "$1" in -getautoproxyurl) printf 'URL: http://127.0.0.1:7078\nEnabled: Yes\n' ;; *) return 0 ;; esac; }
    _selftest_assert_eq "PAC 不带路径也能取端口" "7078" "$(_sysproxy_read_one 'Wi-Fi' autoproxy | sed -n '3p')"
    unset -f networksetup 2>/dev/null || true
    networksetup() { case "$1" in -getautoproxyurl) printf 'URL: file:///Users/x/p.pac\nEnabled: Yes\n' ;; *) return 0 ;; esac; }
    _selftest_assert_eq "file:// 的 PAC 没有端口（不是乱取一个）" "" "$(_sysproxy_read_one 'Wi-Fi' autoproxy | sed -n '3p')"
    unset -f networksetup 2>/dev/null || true

    # ② 裸 IPv6（无方括号）：${x%%:*} 会在第一个冒号处切断，::1 直接变空串。
    _selftest_assert_eq "裸 IPv6 能取出主机" "::1" "$(_url_host 'http://::1:7890')"
    _selftest_assert_eq "裸 IPv6 判为本机" "1" "$(is_loopback_url 'http://::1:7890' && echo 1 || echo 0)"
    _selftest_assert_eq "方括号 IPv6 仍正确" "::1" "$(_url_host 'http://[::1]:7890')"
    _selftest_assert_eq "主机名仍正确" "proxy.corp.com" "$(_url_host 'http://proxy.corp.com:3128')"
    _selftest_assert_eq "公网 IPv6 不是本机" "0" "$(is_loopback_url 'http://[2001:db8::1]:8080' && echo 1 || echo 0)"
    _selftest_assert_eq "localhost 判为本机（SSX-NG 的 PAC 就用它）" "1" "$(is_loopback_url 'http://localhost:1089/x.pac' && echo 1 || echo 0)"

    echo "[16] 握手五分类与「节点问题」那一档"
    # 这三件事守的都是"说错方向"：把"节点挂了"说成"设置坏了"，
    # 用户就会去动系统代理——而删掉设置并不恢复网络（程序还在跑、还占着端口），
    # 只会把他能用的路径删掉。与 Windows 侧同一套词（门禁 6 核对）。
    _selftest_assert_eq "握手：200 是 proxy-ok" "proxy-ok" "$(handshake_kind_text 'HTTP/1.1 200 Connection established')"
    _selftest_assert_eq "握手：407 是 proxy-auth" "proxy-auth" "$(handshake_kind_text 'HTTP/1.1 407 Proxy Authentication Required')"
    _selftest_assert_eq "握手：502 是 upstream-fail（不能当成「不是代理」）" "upstream-fail" "$(handshake_kind_text 'HTTP/1.1 502 Bad Gateway')"
    _selftest_assert_eq "握手：403 也是 upstream-fail" "upstream-fail" "$(handshake_kind_text 'HTTP/1.0 403 Forbidden')"
    _selftest_assert_eq "握手：SSH 横幅是 not-http" "not-http" "$(handshake_kind_text 'SSH-2.0-OpenSSH_9.0')"
    _selftest_assert_eq "握手：没回话是 silent" "silent" "$(handshake_kind_text '')"
    _selftest_assert_eq "握手：2000 绝不能被读成 200" "upstream-fail" "$(handshake_kind_text 'HTTP/1.1 2000 weird')"

    # 救援页那一档必须同时要求「活着」+「握手说上游失败」。
    _rp_src=$(all_lib_source)
    case "$_rp_src" in
        *"_rs_alivebroken"*) _selftest_assert_eq "救援页：节点那一档存在" "1" "1" ;;
        *) _selftest_assert_eq "救援页：节点那一档存在" "1" "0" ;;
    esac
    case "$_rp_src" in
        *"upstream-fail"*) _selftest_assert_eq "救援页：它要握手证据" "1" "1" ;;
        *) _selftest_assert_eq "救援页：它要握手证据" "1" "0" ;;
    esac
    case "$_rp_src" in
        *"多半是节点的问题"*) _selftest_assert_eq "救援页：台词指向节点" "1" "1" ;;
        *) _selftest_assert_eq "救援页：台词指向节点" "1" "0" ;;
    esac

    # quick 档不采集握手，所以状态页永远不会误报这一档。
    # **不真的去调 sysproxy_layers**：那会调 networksetup 读使用者真实的系统代理，
    # 自检不该碰它，而且没有网络服务的机器上（含 CI 的 Linux）返回空、断言会"假过"。
    # 改成直接看源码里那条判断：只有非 quick 才采集。
    _doc_src=$(cat "$SCRIPT_DIR/lib/doctor.sh" 2>/dev/null || echo "")
    case "$_doc_src" in
        *'_gspl_quick" != "quick"'*) _selftest_assert_eq "quick 档不采集握手（看源码判据）" "1" "1" ;;
        *) _selftest_assert_eq "quick 档不采集握手（看源码判据）" "1" "0" ;;
    esac

    echo "[17] 快照的握手字段与状态页提示"
    # ① 快照能往返，且**老快照不许被判损坏**（升级瞬间那份旧数据必须还能用）。
    # SNAPSHOT_FILE 在库加载时就由 MONITOR_DIR 派生好了；自检换了沙箱目录之后
    # 必须**跟着重算**，否则写到沙箱外，读的又是另一处——看起来像"字段丢了"。
    SNAPSHOT_FILE="$MONITOR_DIR/state.snapshot"
    _sn_file="$_sandbox/snap-hs.txt"
    # 断言前先把落点打出来：远端失败时，第一个要问的问题就是"它到底写到哪去了"。
    # 不打这一行，排查只能靠猜。
    [ -d "$MONITOR_DIR" ] || echo "  诊断：MONITOR_DIR 不存在 -> $MONITOR_DIR"
    write_state_snapshot "on:7078" "off" "" "0" "ok" "" "yes" "ok" "5" "1234" "upstream-fail"
    [ -f "$SNAPSHOT_FILE" ] || echo "  诊断：快照没写出来 -> $SNAPSHOT_FILE"
    read_state_snapshot
    _selftest_assert_eq "快照：握手字段能往返" "upstream-fail" "$SNAP_NODE_HANDSHAKE"
    _selftest_assert_eq "快照：状态是 ok" "ok" "$SNAP_STATUS"
    # 老版本写的快照：**没有** node_handshake 这个字段。
    # 直接写到 SNAPSHOT_FILE，不经中间文件再 cp：多一步就多一个可能失败的地方，
    # 而这一步要验的只是"读函数对缺字段的反应"，与文件怎么来的无关。
    {
        printf '%s\n' '# envproxy-snapshot 1'
        printf '%s\n' "written=2026-10-31T10:00:00Z"
        printf '%s\n' 'round=5'
        printf '%s\n' 'pid=1234'
        printf '%s\n' 'state=on:7078'
        printf '%s\n' 'prev_state=off'
        printf '%s\n' 'pending_state='
        printf '%s\n' 'pending_count=0'
        printf '%s\n' 'port_enumeration=ok'
        printf '%s\n' 'port_reason='
        printf '%s\n' 'vars_match=yes'
        printf '%s\n' 'apply_result=ok'
        printf '%s\n' 'log_tail=hi'
    } > "$SNAPSHOT_FILE" 2>/dev/null
    read_state_snapshot
    _selftest_assert_eq "快照：老快照不被判损坏" "ok" "$SNAP_STATUS"
    _selftest_assert_eq "快照：缺字段读成「不知道」而不是「没问题」" "" "$SNAP_NODE_HANDSHAKE"

    # ② 状态页那条提示只在拿到 upstream-fail 证据时出现。
    _ops_src2=$(all_lib_source)
    case "$_ops_src2" in
        *'SNAP_NODE_HANDSHAKE:-}" = "upstream-fail"'*) _selftest_assert_eq "状态页：提示由握手证据触发" "1" "1" ;;
        *) _selftest_assert_eq "状态页：提示由握手证据触发" "1" "0" ;;
    esac
    case "$_ops_src2" in
        *"多半是节点问题"*) _selftest_assert_eq "状态页：台词指向节点" "1" "1" ;;
        *) _selftest_assert_eq "状态页：台词指向节点" "1" "0" ;;
    esac

    # ③ 高级功能页的编号必须单独上色（与 Windows 侧同规则）。
    case "$_ops_src2" in
        *'style_out_nonewline cmd "    ${_adm_k}"'*) _selftest_assert_eq "高级功能：编号单独上色" "1" "1" ;;
        *) _selftest_assert_eq "高级功能：编号单独上色" "1" "0" ;;
    esac

    rm -rf "$_sandbox" 2>/dev/null || true
    _selftest_done=1
    # 撤掉 launchctl 替身：bash 的函数定义是全局的，留着它会让本进程后面
    # 每一次 launchctl 调用都拿到假结果（details 见替身定义处的说明）。
    unset -f launchctl 2>/dev/null || true
    trap - EXIT
    if [ "$_selftest_fails" -eq 0 ]; then
        echo "自检全部通过"
        return 0
    fi
    echo "自检失败：$_selftest_fails 项"
    return 1
}
