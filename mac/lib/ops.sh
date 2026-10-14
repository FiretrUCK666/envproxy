# ------------------------------------------------------------------------------
#  ops.sh — 动作层：四个按钮背后的安装、停止、卸载、状态编排，以及自检沙箱
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
    if compare_versions "1.0.10" "1.0.9" >/dev/null 2>&1; then _c1=$(compare_versions "1.0.10" "1.0.9"); else _c1="?"; fi
    _selftest_assert_eq "版本逐段数值比" "1" "$_c1"

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
    if verify_package "$_pkg" "9.9.9"; then _p1=1; else _p1=0; fi
    _selftest_assert_eq "结构完整的包被接受" "1" "$_p1"
    if verify_package "$_pkg" "1.2.3"; then _p2=1; else _p2=0; fi
    _selftest_assert_eq "版本不符被拒绝" "0" "$_p2"
    printf '# lib\n' > "$_pkg/win/lib/base.ps1" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9"; then _p3=1; else _p3=0; fi
    _selftest_assert_eq "库缺 BOM 被拒绝" "0" "$_p3"
    printf '\357\273\277# lib\n' > "$_pkg/win/lib/base.ps1" 2>/dev/null || true
    printf '#!/bin/bash\r\n' > "$_pkg/mac/envproxy.sh" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9"; then _p4=1; else _p4=0; fi
    _selftest_assert_eq "壳含 CRLF 被拒绝" "0" "$_p4"
    printf '#!/bin/bash\n' > "$_pkg/mac/envproxy.sh" 2>/dev/null || true
    printf '\357\273\277' > "$_pkg/win/lib/empty.ps1" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9"; then _p5=1; else _p5=0; fi
    _selftest_assert_eq "只剩 BOM 的截断文件被拒绝" "0" "$_p5"
    rm -f "$_pkg/win/lib/empty.ps1" 2>/dev/null || true
    rm -f "$_pkg/mac/envproxy.sh" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9"; then _p6=1; else _p6=0; fi
    _selftest_assert_eq "缺平台入口被拒绝" "0" "$_p6"

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
    # 先快照用户原值：之后卸载时按它还原，覆盖前留底。
    snapshot_prev_env || true
    if set_autorun; then
        echo "[1/3] 开机自启动：已写入（LaunchAgent + 固定定位器）"
    else
        echo "[1/3] 开机自启动：写入失败，请检查 ~/Library/LaunchAgents 是否可写"
    fi
    if insert_shell_hooks; then
        echo "[2/3] 终端集成：已写入 shell hook（zsh/bash，新开终端生效）"
    else
        echo "[2/3] 终端集成：写入失败，请检查 ~/.zshenv 是否可写"
    fi
    update_path_record
    if start_monitor 1; then
        echo "[3/3] 监控进程：已启动"
    else
        echo "[3/3] 监控进程：启动失败，请重试 1-安装"
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
            echo "更新状态 : 可用 5-检查更新 升级"
        else
            _newer=$(compare_versions "$_local_ver" "$REMOTE_VERSION" || true)
            if [ "$_newer" -gt 0 ] 2>/dev/null; then
                echo "更新状态 : 本地版本比最新发布版新"
            else
                _older=$(compare_versions "$REMOTE_VERSION" "$_local_ver" || true)
                if [ "$_older" -gt 0 ] 2>/dev/null; then
                    echo "更新状态 : 发现新版，用 5-检查更新 可升级"
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
