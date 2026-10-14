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

self_test() {
    _selftest_fails=0
    _sandbox=$(mktemp -d /tmp/envproxy_selftest.XXXXXX 2>/dev/null) || { echo "自检失败：沙箱建不起"; return 1; }
    # 运行期改道：HOME 管 hook 落点，ENVPROXY_HOME 管 proxy.env/快照，MONITOR_DIR 管日志。
    HOME="$_sandbox"
    ENVPROXY_HOME="$_sandbox/.envproxy"
    PROXY_ENV="$ENVPROXY_HOME/proxy.env"
    PREV_ENV="$ENVPROXY_HOME/prev.env"
    MONITOR_DIR="$ENVPROXY_HOME/monitor"
    LOG_FILE="$MONITOR_DIR/monitor.log"
    export HOME ENVPROXY_HOME
    mkdir -p "$ENVPROXY_HOME" "$MONITOR_DIR" 2>/dev/null || true

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

    echo "[2] 合并与归属"
    _selftest_assert_eq "补默认项、留用户条目" "localhost,127.0.0.1,::1,example.com" "$(merge_no_proxy 'localhost,example.com,::1' "$DEFAULT_NO_PROXY")"
    _selftest_assert_eq "含单引号条目丢弃" "localhost,127.0.0.1,::1,ok.example" "$(merge_no_proxy "ok.example,a'b" "$DEFAULT_NO_PROXY")"
    if is_owned_proxy_value "http://127.0.0.1:7890"; then _o1=1; else _o1=0; fi
    if is_owned_proxy_value "http://corp:8080"; then _o2=1; else _o2=0; fi
    _selftest_assert_eq "本机地址算我们的" "1" "$_o1"
    _selftest_assert_eq "公司地址不算我们的" "0" "$_o2"
    _selftest_assert_eq "转义幂等" "'a'" "$(shell_escape_sq 'a')"
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
    mkdir -p "$_pkg/win/lib" "$_pkg/mac" 2>/dev/null || true
    printf '9.9.9' > "$_pkg/VERSION" 2>/dev/null || true
    printf '\357\273\277# entry\n' > "$_pkg/win/envproxy.ps1" 2>/dev/null || true
    printf '\357\273\277# lib\n' > "$_pkg/win/lib/base.ps1" 2>/dev/null || true
    printf '#!/bin/bash\n' > "$_pkg/mac/envproxy.sh" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p1=1; else _p1=0; fi
    _selftest_assert_eq "结构完整的包被接受" "1" "$_p1"
    if verify_package "$_pkg" "1.2.3" "mac"; then _p2=1; else _p2=0; fi
    _selftest_assert_eq "版本不符被拒绝" "0" "$_p2"
    printf '# lib\n' > "$_pkg/win/lib/base.ps1" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p3=1; else _p3=0; fi
    _selftest_assert_eq "库缺 BOM 被拒绝" "0" "$_p3"
    printf '\357\273\277# lib\n' > "$_pkg/win/lib/base.ps1" 2>/dev/null || true
    printf '#!/bin/bash\r\n' > "$_pkg/mac/envproxy.sh" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p4=1; else _p4=0; fi
    _selftest_assert_eq "壳含 CRLF 被拒绝" "0" "$_p4"
    printf '#!/bin/bash\n' > "$_pkg/mac/envproxy.sh" 2>/dev/null || true
    printf '\357\273\277' > "$_pkg/win/lib/empty.ps1" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p5=1; else _p5=0; fi
    _selftest_assert_eq "只剩 BOM 的截断文件被拒绝" "0" "$_p5"
    rm -f "$_pkg/win/lib/empty.ps1" 2>/dev/null || true
    rm -f "$_pkg/win/envproxy.ps1" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p6=1; else _p6=0; fi
    _selftest_assert_eq "缺另一平台入口照样接受" "1" "$_p6"
    printf '\357\273\277# entry\n' > "$_pkg/win/envproxy.ps1" 2>/dev/null || true
    rm -f "$_pkg/mac/envproxy.sh" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p7=1; else _p7=0; fi
    _selftest_assert_eq "只缺自己平台入口也被拒绝" "0" "$_p7"

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

    echo "[9] 菜单分派"
    # menu 子命令必须在入口分派里存在，show_menu 必须已定义；
    # 菜单列出的每个子命令都必须能在入口分派里找到（壳调回来的路不断）。
    if [ "$(type -t show_menu 2>/dev/null || true)" = "function" ]; then _l4=1; else _l4=0; fi
    _selftest_assert_eq "show_menu 已定义" "1" "$_l4"
    if grep -qE '^[[:space:]]*menu\)' "$SCRIPT_DIR/envproxy.sh" 2>/dev/null; then _l5=1; else _l5=0; fi
    _selftest_assert_eq "menu 在入口分派里存在" "1" "$_l5"
    for _ms in install status stop uninstall update; do
        if grep -qE "^[[:space:]]*$_ms\\)" "$SCRIPT_DIR/envproxy.sh" 2>/dev/null; then _l6=1; else _l6=0; fi
        _selftest_assert_eq "菜单子命令 $_ms 在入口分派里存在" "1" "$_l6"
    done

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
    if [ "$(id -u 2>/dev/null)" = "0" ]; then echo "当前是 root 身份：动的将是 root 的配置，日常使用请用普通终端重做一遍。"; fi
    # 先快照用户原值：之后卸载时按它还原，覆盖前留底。
    snapshot_prev_env || true
    if set_autorun; then
        echo "[1/3] 开机自启动：已写入（LaunchAgent + 固定定位器）"
    else
        echo "[1/3] 开机自启动：写入失败，请检查 ~/Library/LaunchAgents 是否可写"
    fi
    if insert_shell_hooks; then
        echo "[2/3] 终端集成：已写入 shell hook（zsh/bash，新开终端生效；fish 暂不支持，见故障排查）"
    else
        echo "[2/3] 终端集成：写入失败，请检查 ~/.zshenv 是否可写"
    fi
    update_path_record
    if start_monitor 1; then
        echo "[3/3] 监控进程：已启动"
    else
        echo "[3/3] 监控进程：未能确认运行，请用菜单"查看状态"核对"
        echo "      一台电脑只留一份安装；另一个副本的监控在跑时会占住单实例锁。"
    fi
    CURRENT_STATE="off"
    get_current_state || true
    apply_state "$CURRENT_STATE" || true
    sleep 1
    echo ""
    show_status
    echo ""
    echo "提示：之后【新打开】的终端/程序自动获得代理；"
    echo "      已经开着的旧窗口不会自动变化，重开一个即可。"
}

uninstall_envproxy() {
    _purge="$1"
    echo "======== EnvProxy 卸载（一键恢复原状）========"
    if [ "$(id -u 2>/dev/null)" = "0" ]; then echo "当前是 root 身份：动的将是 root 的配置，日常使用请用普通终端重做一遍。"; fi
    stop_monitor || true
    remove_autorun
    rm -f "$LOCATOR_PATH" "$PATH_CONF" 2>/dev/null || true
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
        echo "[完成] 监控已停、自启动已删、定位器已清、代理变量已清除。"
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
    if [ -n "$_m" ]; then echo "监控进程 : 运行中 (PID $_m)"; else echo "监控进程 : 未运行"; fi
    if launchctl list 2>/dev/null | grep -qF "$PLIST_LABEL"; then
        echo "开机自启 : 已启用"
    else
        if [ -f "$PLIST_PATH" ]; then echo "开机自启 : 已写入但未加载"; else echo "开机自启 : 未启用"; fi
    fi
    _port=$(get_active_proxy_port 1 2>/dev/null || true)
    if [ -n "$_port" ]; then
        echo "翻墙代理 : 已开启（本地端口 $_port 监听中）"
    else
        echo "翻墙代理 : 未检测到（当前无翻墙代理在运行）"
    fi
    _cur=$(get_current_proxy_port 2>/dev/null || true)
    if [ -n "$_cur" ]; then echo "代理变量 : 已注入 (http://127.0.0.1:$_cur)"; else echo "代理变量 : 无（直连状态）"; fi
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
            echo "更新状态 : 可用菜单 检查更新 升级"
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
        echo "最新版本 : 检查失败（网络不可达，稍后重试）"
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
# 所以菜单里的 bug 最多影响菜单显示，动不了安装区。五个动作与入口子命令一一对应。
# 非交互环境（stdin 不是终端）直接退出并提示，不死循环。
show_menu() {
    if [ ! -t 0 ]; then
        echo "菜单需要双击 打开菜单.command 使用，管道调用请直接用 install/status/stop/uninstall/update 子命令。"
        return 1
    fi
    while true; do
        echo ""
        echo "======== EnvProxy 菜单 (macOS) ========"
        # 抬头只读瞬时项（监控在不在、本地版本），不做网络探测，不卡菜单。
        _hm=$(get_monitor_pid || true)
        _hver=$(get_local_version || true)
        [ -z "$_hver" ] && _hver="未知"
        if [ -n "$_hm" ]; then _hmon="运行中 (PID $_hm)"; else _hmon="未运行"; fi
        echo "当前：监控$_hmon，本地版本 v$_hver（详情选 2 查看状态）"
        echo "  [1] 安装 / 修复（首次安装；觉得不对劲就点它）"
        echo "  [2] 查看状态（监控、翻墙、变量、版本）"
        echo "  [3] 停止监控（停掉并恢复直连，下次登录回来）"
        echo "  [4] 一键恢复（彻底卸载，回到没装之前）"
        echo "  [5] 检查更新（有新版先说明，同意才装）"
        echo "  [0] 退出"
        printf "选一个（回车=查看状态）："
        if ! IFS= read -r _choice; then
            echo ""
            echo "菜单需要双击 打开菜单.command 使用。"
            return 0
        fi
        # 首尾空格不算输错（与 Windows 侧 .Trim() 同语义）。
        _choice=$(printf '%s' "$_choice" | tr -d '[:space:]')
        [ -z "$_choice" ] && _choice="2"
        case "$_choice" in
            1) _msub="install";;
            2) _msub="status";;
            3) _msub="stop";;
            4) _msub="uninstall";;
            5) _msub="update";;
            0) return 0;;
            *) echo "没有这个编号，重输一个。"; continue;;
        esac
        # 子进程跑完整子命令：与入口子命令走的是同一条路（含锁、确认、复检）。
        /bin/bash "$SCRIPT_PATH" "$_msub" || echo "启动失败（退出码 $?）。"
    done
}
