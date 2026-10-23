# ------------------------------------------------------------------------------
#  ops.sh — 动作层：菜单背后的安装、停止、卸载、状态编排
#  把下面各层拼成使用者点得到的行为。
#  自检（沙箱回归）不在本文件里，是 mac/test-mac-pure.sh（必须放 mac/ 直属：
#  包校验器只放行平台目录直接下级的脚本，放进子目录会让每版更新都被自己拒收），
#  由入口的 self-test 子命令加载——它不属于运行时逻辑。
# ------------------------------------------------------------------------------
# 更新收尾不需要单独的子命令：覆盖完成后由更新入口 exec 安装根里的新脚本跑 install
# （从安装根执行，路径记录/自启动/监控才会落在安装根）。

# ------------------------------------------------------------------------------
# 10. 子命令
# ------------------------------------------------------------------------------
install_envproxy() {
    style_out title "======== EnvProxy 安装 ========"
    if [ "$(id -u 2>/dev/null)" = "0" ]; then echo "当前是 root 身份：接下来改的会是 root 这个账号的配置。日常使用请用普通终端重来一次。"; fi
    # 先说清楚要动什么、不动什么，再说"正在做"——用户在按完编号之后得先知道会发生什么，
    # 而不是盯着静止的屏幕猜。
    style_out text "会改这 4 处：开机自启、终端配置、环境变量、后台监控。"
    style_out text "不会动你的其他设置。"
    echo ""
    # 首次安装的判据要在写路径记录**之前**取：写完这台机器上就有记录了，再判永远是"重装"。
    # 差别在于本机地址的代理变量算谁的——首次安装时它只可能是使用者自己的。
    if [ -f "$PATH_CONF" ]; then _first=0; else _first=1; fi
    # 先快照用户原值：之后卸载时按它还原，覆盖前留底。
    snapshot_prev_env "$_first" || true
    style_out text "[1/4] 正在写开机自启……"
    if set_autorun; then
        style_out ok "[1/4] 开机自启动：已写入"
    else
        style_out warn "[1/4] 开机自启动：写入失败，请检查 ~/Library/LaunchAgents 是否可写"
    fi
    # 编号必须与 Windows 侧同一含义（自启 → 监控 → 变量 → 终端同步）。
    # 早先两端 [2/4] 和 [3/4] 各指另一件事，用户按编号念给客服或照 README 对照排查时，
    # 「[3/4] 环境变量」在 mac 上其实还没开始。四步之间没有功能上的先后约束
    # （终端同步只写配置文件、与代理状态无关；变量对齐只要在监控启动之后即可），
    # 所以两种顺序都成立——既然都成立，就不该保留差异：`[n/4]` 是给用户数进度的，
    # 含义不固定的编号等于没有编号。
    style_out text "[2/4] 正在启动后台监控……"
    if start_monitor 1; then
        style_out ok "[2/4] 监控进程：已启动"
    else
        style_out warn "[2/4] 监控进程：未能确认运行，原因见上面那两行"
    fi
    update_path_record
    # 枚举失败时这一轮是"不知道"：不动环境变量（与监控主循环同一条规则）。
    # 不管成没成就按预设的 off 去应用，等于把"读不出来"当成"代理没了"。
    # 这一步也要报进度：它是"会改这 4 处"里的第 4 处（环境变量），
    # 不报的话用户只数到 3 步，会以为环境变量那步被跳过了。
    style_out text "[3/4] 正在确认翻墙软件在不在（有端口、是代理、真能连出去）……"
    # 两种失败必须分开说：判不出状态（正常，会自动重试）与判出来了却写不进去
    # （磁盘满、~/.envproxy 不可写、被安全软件挡住——要人动手解决）。
    # 原来两者共用一句"没读到本机端口"，写失败的人会一直以为只是运气不好。
    _asr=0
    align_state_once >/dev/null 2>&1 || _asr=$?
    if [ "$_asr" = "0" ]; then
        style_out ok "[3/4] 环境变量：已按当前状态校正"
    elif [ "$_asr" = "2" ]; then
        style_out warn "[3/4] 环境变量：写不进去（$ENVPROXY_HOME 不可写，或磁盘已满）。"
        style_out dim "      检查一下这个目录的权限和剩余空间，然后重跑一次安装。"
    else
        # 读不出来 ≠ 没有代理：这一轮什么都没改，如实说明（与 Windows 侧同口径）。
        style_out warn "[3/4] 环境变量：这一轮没读到本机端口，所以没有改动任何设置（正常，会自动重试）。"
    fi
    style_out text "[4/4] 正在写终端配置……"
    if insert_shell_hooks; then
        style_out ok "[4/4] 终端同步：已在终端的启动配置里写入（zsh/bash，新开终端生效；fish 不支持）"
    else
        style_out warn "[4/4] 终端同步：写入失败，请检查 ~/.zshenv 是否可写"
    fi
    echo ""
    # 联网对比版本要一两秒：先说一声，别让最后这一步又变成静默等待。
    # 这里不联网：版本号取自监控写的缓存（状态页只读、永不联网）。见 Windows 侧同句。
    style_out text "正在看当前状态（版本号取自监控缓存，不联网）……"
    show_status
    echo ""
    # 左边那一列按最长条目补齐，不靠手敲空格：改一个字就整列歪掉，
    # 而"歪一格"这种事只有人眼看得出来。与 Windows 侧同一套做法。
    style_out ok "装好了。之后怎么用："
    # 每一行三格：左列标签（暗）/ 右列说明（正文色）/ 要照抄的命令（命令色）。
    # 整行一个颜色就没有层次：用户看不出哪一段能复制。命令单独列一格，
    # 而不是靠正则从整行里认——"在它里面执行  export ..." 开头不是命令，
    # 会被整行判成说明。与 Windows 侧同一套三格结构。
    _tip_a1="新开的终端 / 程序"
    _tip_a2="一直开着的窗口"
    _tip_a3="装之前就开着的窗口"
    _tip_a4="想让某个窗口固定直连"
    _tip_a5="改回跟着翻墙软件走"
    _tip_a6="忘了怎么用"
    _tip_w=$(printf '%s\n' "$_tip_a1" "$_tip_a2" "$_tip_a3" "$_tip_a4" "$_tip_a5" "$_tip_a6" | _max_width_of)
    _tip_pad=$(printf '%*s' "$_tip_w" '')
    # $1=左列 $2=说明 $3=命令（可空）
    # 三段各上各的色，所以要拼成**一行**再输出：style_out 一次是一整行，
    # 分开调两次就成了两行（标签一行、说明一行），版面会散掉。
    # 这里手工拼转义序列，与 _seg 的判据同源（style_color 一个来源）。
    _tip_row() {
        # 入口开着 set -u：$3 是可选的（多数行没有命令），必须带默认值，
        # 否则任何一次两参调用都会 "unbound variable" 整屏崩掉。
        _tr_label="${1:-}"; _tr_note="${2:-}"; _tr_cmdline="${3:-}"
        _tr_left=$(if [ -n "$_tr_label" ]; then _menu_cell_pad "$_tr_label" "$_tip_w"; else printf '%s' "$_tip_pad"; fi)
        if [ ! -t 1 ]; then
            # 不是终端就纯文本，别往日志里塞控制字符（与 style_out 同一判据）
            if [ -n "$_tr_cmdline" ]; then printf '   %s   %s  %s\n' "$_tr_left" "$_tr_note" "$_tr_cmdline"
            else printf '   %s   %s\n' "$_tr_left" "$_tr_note"; fi
            return 0
        fi
        _tr_dim=$(style_color dim)
        _tr_c = $(style_color cmd)
        printf '\033[%sm   %s   \033[0m%s' "$_tr_dim" "$_tr_left" "$_tr_note"
        if [ -n "$_tr_cmdline" ]; then printf '  \033[%sm%s\033[0m\n' "$_tr_c" "$_tr_cmdline"; else printf '\n'; fi
    }
    _tip_row "$_tip_a1" "自动就是对的，什么都不用做。" ""
    _tip_row "$_tip_a2" "敲一下回车就跟上。" ""
    _tip_row "$_tip_a3" "重开一个，或者手动加载一次" ""
    _tip_row "" "菜单选 4（帮助）第 2 条，有现成命令。" ""
    _tip_row "$_tip_a4" "在它里面执行" "export ENVPROXY_TERM=off"
    _tip_row "$_tip_a5" "在它里面执行" "unset ENVPROXY_TERM"
    _tip_row "$_tip_a6" "菜单选 4（帮助）。" ""
}

uninstall_envproxy() {
    _purge="$1"
    _un_yes="${2:-}"
    style_out title "======== EnvProxy 卸载（一键恢复原状）========"
    if [ "$(id -u 2>/dev/null)" = "0" ]; then echo "当前是 root 身份：接下来改的会是 root 这个账号的配置。日常使用请用普通终端重来一次。"; fi
    # 先问一句再动手。这是整个工具里**唯一不可逆**的动作：会删开机自启、摘终端配置、
    # 清掉代理变量。而它在菜单里紧挨着「5 停止监控」（那个是可逆的）。
    # 原来全函数里唯一的提问是"日志要不要保留"——那时监控已停、自启已删、配置已摘，问什么都晚了。
    # 默认不卸载：危险动作的默认必须是"不做"。与 Windows 侧同一口径。
    if [ "$_un_yes" = "1" ]; then
        style_out dim "已确认（--yes）：开始卸载。"
    elif [ -t 0 ]; then
        echo "卸载后会删掉开机自启、终端配置和代理变量，恢复成没装之前的样子。"
        printf '确定要卸载吗？输入 y 回车确认，直接回车 = 取消: '
        _un_ans=""
        read -r _un_ans || _un_ans=""
        case "$_un_ans" in
            y|Y|yes|YES|是) ;;
            *) style_out dim "已取消，什么都没改。"; return 0 ;;
        esac
    else
        # 没有可交互的终端：不能问，也不能替使用者答应。
        # "问不到人就直接做"等于没有确认（Windows 侧实测过一次：管道里跑直接把工具卸干净了）。
        style_out warn "这里没法问你要不要卸载（没有可交互的终端），所以什么都不会做。"
        style_out dim "  真的要卸载，请双击 打开菜单.command 选 6；"
        style_out dim "  或者确认无误后加 --yes：bash envproxy.sh uninstall --yes"
        return 0
    fi
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
        if read -r _choice 2>/dev/null < /dev/tty; then :; else _choice=""; fi
        case "$_choice" in [Nn]*) _remove_log=1;; *) _remove_log=0;; esac
    fi
    if [ $_remove_log -eq 1 ]; then
        rm -rf "$MONITOR_DIR" 2>/dev/null || true
    else
        rm -f "$PID_FILE" "$STOP_FLAG" "$STOP_INTENT" 2>/dev/null || true
        if [ -d "$MONITOR_DIR" ] && [ -z "$(ls -A "$MONITOR_DIR" 2>/dev/null)" ]; then
            rm -f "$PID_FILE" "$STOP_FLAG" "$STOP_INTENT" 2>/dev/null || true
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
    # 每条残留都带上**具体路径**。只写"路径记录仍在"再加一句"手动删除上述位置"，
    # 用户看着空白不知道删什么——提示得能照着做才算提示。
    _dirty=""
    if launchctl list 2>/dev/null | grep -qF "$PLIST_LABEL"; then _dirty="$_dirty 开机自启动项仍在（launchctl 里的 $PLIST_LABEL）；"; fi
    if [ -f "$PLIST_PATH" ]; then _dirty="$_dirty 自启动文件仍在（$PLIST_PATH）；"; fi
    if [ -f "$ENVPROXY_HOME/prompt-sync.sh" ]; then _dirty="$_dirty 终端同步脚本仍在（$ENVPROXY_HOME/prompt-sync.sh）；"; fi
    if [ -f "$LOCATOR_PATH" ]; then _dirty="$_dirty 定位脚本仍在（$LOCATOR_PATH）；"; fi
    if [ -f "$PROXY_ENV" ]; then _dirty="$_dirty 代理变量文件仍在（$PROXY_ENV）；"; fi
    if [ -f "$PREV_ENV" ]; then _dirty="$_dirty 变量快照仍在（$PREV_ENV）；"; fi
    # owned.env 上面删过，但复检原来没查它——删失败时报"已完成"，而它记着
    # "我们写下的值"，留着会让终端钩子继续认为代理是我们设的。
    # 复检项必须与删除项一一对应，删了不查等于没删。
    if [ -f "$OWNED_ENV" ]; then _dirty="$_dirty 归属记录仍在（$OWNED_ENV）；"; fi
    if [ -f "$PATH_CONF" ]; then _dirty="$_dirty 路径记录仍在（$PATH_CONF）；"; fi
    if [ -f "$ENVPROXY_HOME/monitor.stdout.log" ] || [ -f "$ENVPROXY_HOME/monitor.stderr.log" ]; then _dirty="$_dirty 自启动重定向残留；"; fi
    # hook 名单与 remove_shell_hooks 同一份（改一边必须改另一边）：残留整块即脏。
    for _rc in $(rc_check_files); do
        if _hook_marker_present "$_rc" "$HOOK_START"; then _dirty="$_dirty 终端同步的配置块还在（$_rc）；"; break; fi
    done
    if proxy_vars_present 2>/dev/null; then _dirty="$_dirty 代理变量仍在；"; fi
    if [ -n "$(get_monitor_pid || true)" ]; then _dirty="$_dirty 监控进程仍在；"; fi
    if [ $_remove_log -eq 1 ] && [ -f "$LOG_FILE" ]; then _dirty="$_dirty 历史日志未能删除；"; fi
    if [ -z "$_dirty" ]; then
        style_out ok "[完成] 监控已停，开机自启、代理变量和定位用的小脚本都已删除。"
        if [ $_remove_log -eq 1 ]; then
            style_out dim "        历史日志已一并彻底删除。"
        else
            style_out dim "        历史日志保留在 monitor/monitor.log（黑匣子，供日后排查）。"
        fi
        style_out dim "        电脑已恢复到安装前的状态，无需重启。"
    else
        style_out warn "[未完成] 这几处没清干净："
        style_out warn "        $_dirty"
        style_out warn "        再跑一次 uninstall 试一次；还不行就照上面列出的位置手动删。"
    fi
}

# 单个地址上试一次 TCP 连接，只回答"这个端口还在不在"。
# 状态页用它判三件事：注入的代理变量指向的端口、系统代理指向的端口。
# 与 Windows 侧 Test-TcpAlive 同一判据（那边按地址族建套接字，这边同样只连一次）。
_port_alive() {
    _pa_addr="$1"; _pa_port="$2"
    [ -n "$_pa_addr" ] && [ -n "$_pa_port" ] || return 1
    # 大括号加 2>/dev/null 包住：nc/curl 在端口没人听时会往 stderr 写一行，
    # 那行不是错误、只是噪声，不该出现在状态页上。
    if nc_supports_G; then
        if printf '' | nc -z -G 1 -w 1 "$_pa_addr" "$_pa_port" 2>/dev/null; then return 0; fi
        return 1
    fi
    # 降级：用 curl 探连通。
    # 与 probe 层同一个坑：--noproxy '' 是绕过代理直连目标，'*' 语义正好相反；
    # 不加 -p 时 curl 发的是普通 GET，任何回 200 的服务都会被当成代理。
    #
    # 注释必须写在命令**上方**：续行（行尾反斜杠）中间夹一行注释，bash 会把
    # 整行注释丢弃、续行到此结束，后面的参数变成一条独立命令去执行——
    # 实测 curl 只收到前四个参数、URL 全丢，报 "no URL specified"，
    # 于是判断永远是"死了"，状态页每次都打印假警告。
    if env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy \
        curl --disable -s -o /dev/null --connect-timeout 1 --max-time 2 \
        --noproxy '' -p -x "http://$_pa_addr:$_pa_port" "http://127.0.0.1:9/" 2>/dev/null; then
        return 0
    fi
    return 1
}

# 当前注入的代理地址：**整条**读回来，不只取端口。
# 只取端口再拼 127.0.0.1 是错的：注入值可能是 http://[::1]:7078，
# 那样屏幕上会显示一个本机根本不成立的地址，而用户完全可能照抄去填别的工具。
# 与 write_off_sentinel 里同一套"整条 URL"取法。
get_current_proxy_url() {
    [ -f "$PROXY_ENV" ] || return 1
    _gpu_line=$(grep -E '^export HTTP_PROXY=' "$PROXY_ENV" 2>/dev/null | head -n 1)
    [ -n "$_gpu_line" ] || return 1
    printf '%s' "$_gpu_line" | sed -E 's/^export HTTP_PROXY="?([^"]*)"?$/\1/'
}

# 采集状态页需要的事实。**只读**：不写文件、不提问、不联网（版本缓存由监控写）。
# 结果留在全局变量里（本项目不用 local），由 show_status 负责显示。
#
# 为什么分两层：这一段原来与渲染混在同一个 358 行的函数里，读的人要在几十行
# 显示语句之间翻找"这个值从哪来"。Windows 侧早就是 Get-StatusSnapshot /
# Show-StatusSnapshot 两层，这里与它对齐。分开之后还有一个结构性的好处：
# "状态页只读"不再靠自觉——采集函数里没有一句显示，渲染函数里没有一处探测。
get_status_snapshot() {
    _m=$(get_monitor_pid || true)
    # 只看"launchd 里有这个 label"会说谎：卸载不彻底、或用户手删过 ~/.envproxy/ 时，
    # plist 还在、它要启动的 locator.sh 已经不在了，登录时什么都不会起来，
    # 状态页却仍报"已启用"。判据要和"能不能真的启动"一致：注册在，且那个文件真的存在。
    # 与 Windows 侧同口径（那边查的是 Run 键指向的脚本是否存在）。
    _autorun_reg=0
    launchctl list 2>/dev/null | grep -qF "$PLIST_LABEL" && _autorun_reg=1
    _autorun_ok=0
    if [ "$_autorun_reg" = "1" ] && [ -f "$LOCATOR_PATH" ]; then _autorun_ok=1; fi

    # 端口枚举读不出来 = 这一轮不知道有没有代理在运行，不能说成"没有代理"。
    # 状态页要回答"我此刻正常吗"，所以必须**看得见用户真正在用的那个端口**。
    #
    # 只做快扫（find_candidate_ports 0）的问题是它只认"常见端口表 + 进程名"：
    # 用户把端口改成表外的值（如 7099）后，快扫返回空，屏幕打"未检测到"；
    # 而同一屏的"代理变量"那行读的是真实值、试连还通着 —— 两行自相矛盾。
    # 与 Windows 侧 Get-InUseProxyPort 同一套顺序、同一套理由：
    #   1) 先直接验注入值指向的那个端口（我们自己写的，就是用户此刻在用的），
    #      命中即返回，一次 TCP，毫秒级；
    #   2) 没命中才退到候选集，且用**全扫**——状态页一天点不了几次，
    #      "慢一点"远比"说谎"便宜。
    _port=""
    _port_unknown=0
    _port=$(get_in_use_proxy_port) || _port_unknown=1

    # 终端同步到底有没有在生效。光看「块写进去了」不算数：块不成对同样能让
    # 「看起来装好了，实则每次开窗口都不同步」。与 Win 侧 Get-TerminalSyncState 同语义。
    _ts_state="missing"
    _ts_hits=0
    _ts_unpaired=0
    _ts_stale=0
    _ts_badline=""
    for _ts_p in $(rc_check_files); do
        [ -f "$_ts_p" ] || continue
        # 先看有没有我们的标记：连标记都没有的文件不是「不成对」，是「没装过」，不计数。
        _ts_has_s=0
        _hook_marker_present "$_ts_p" "$HOOK_START" && _ts_has_s=1
        _ts_has_e=0
        _hook_marker_present "$_ts_p" "$HOOK_END" && _ts_has_e=1
        [ "$_ts_has_s" = "0" ] && [ "$_ts_has_e" = "0" ] && continue
        if ! _hook_block_paired "$_ts_p"; then
            _ts_unpaired=$((_ts_unpaired + 1))
            # 顺带记下孤立标记的行号：状态页要能告诉用户"删哪一行"。
            # 只说"标记不成对"等于让用户自己去几千行里找。
            [ -z "$_ts_badline" ] && _ts_badline=$(grep -nxF -e "$HOOK_START" -e "$HOOK_END" "$_ts_p" 2>/dev/null | head -n 1 | cut -d: -f1)
            continue
        fi
        # 成对了还要看钩子行是不是当前版本：标记在、钩子行被改过就不算生效。
        if _hook_marker_present "$_ts_p" "$HOOK_LINE"; then
            _ts_hits=$((_ts_hits + 1))
        else
            # 块成对、但不是当前版本：这是"过期"，不是"没有块"。
            # 报成 missing 会让用户以为从没装过；而它其实装过、只是那段代码旧了。
            # 与 Windows 侧 stale 同一口径（安装会按当前版本重写，不用用户动手）。
            _ts_stale=$((_ts_stale + 1))
        fi
    done
    if [ "$_ts_hits" -gt 0 ]; then
        _ts_state="ok"
    elif [ "$_ts_unpaired" -gt 0 ]; then
        _ts_state="unpaired"
    elif [ "$_ts_stale" -gt 0 ]; then
        _ts_state="stale"
    fi

    # 代理变量：整条地址读回来（不只端口），再试连看它指向的端口还在不在。
    _cur=$(get_current_proxy_url 2>/dev/null || true)
    # 三态：1 = 活着、0 = 端口不在、"" = 说不清（值不是合法地址）。
    #
    # 初值必须是""，不能是 1。原来是 1，于是"取不出端口"时整个 if 被跳过、
    # 1 留在原处变成了结论——屏幕上说"已注入"、结论行说"一切正常"。
    # 这条路径真实可达：proxy.env 被别的工具改坏、或写进了半个地址就会命中。
    # 拿不准时默认必须是"不知道"：说不知道最多让人多查一眼，说"正常"会让人不去查。
    _cur_alive=""
    _cur_addr=""
    _cur_port=""
    if [ -n "$_cur" ]; then
        # 从 URL 里取主机与端口：IPv6 形态是 http://[::1]:7078，直接按最后一个冒号切。
        _cur_hostport=$(printf '%s' "$_cur" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##')
        _cur_port=$(printf '%s' "$_cur_hostport" | sed -nE 's/.*:([0-9]+)$/\1/p')
        _cur_addr=$(printf '%s' "$_cur_hostport" | sed -E 's/^\[([^]]*)\]:[0-9]+$/\1/; t; s/:[0-9]+$//')
        if [ -n "$_cur_port" ]; then
            _cur_alive=1
            _port_alive "$_cur_addr" "$_cur_port" || _cur_alive=0
        fi
    fi

    # 系统代理：浏览器的世界，不是我们写的，但用户常把它的毛病算到我们头上。
    # 若它指向本机死端口，浏览器全挂而终端正常——提醒一句，绝不动它。
    # 与 Win 侧 HKCU Internet Settings 那段同语义（读系统设置 → 试连 → 只在连不上时提醒）。
    _sp_bad=0
    _sp_info=$(scutil --proxy 2>/dev/null || true)
    if [ -n "$_sp_info" ]; then
        _sp_enable=$(printf '%s' "$_sp_info" | awk '/HTTPEnable *: *1/ {print 1; exit}')
        _sp_host=$(printf '%s' "$_sp_info" | awk '/HTTPProxy *: */ {sub(/.*: */, ""); print; exit}')
        _sp_port=$(printf '%s' "$_sp_info" | awk '/HTTPPort *: */ {sub(/.*: */, ""); print; exit}')
        if [ "$_sp_enable" = "1" ] && [ "$_sp_host" = "127.0.0.1" ] && [ -n "$_sp_port" ]; then
            # "在听"还不够：多数翻墙软件的断开按钮不停内核，端口仍会应答。
            # 真连一次才分得清"活着"与"占着不放"（与 Win 侧 Test-TcpAlive 同口径）。
            _port_alive "127.0.0.1" "$_sp_port" || _sp_bad=1
        fi
    fi

    # 版本信息（只读：查不到只提示，不写文件、不提问）
    _local_ver=$(get_local_version || true)
    return 0
}

# 状态页的一行：左列标签固定一种颜色，右侧内容按状态取角色。
# 与 Windows 侧 Write-StatusRow 同一套判据。
# 为什么不一整行一个颜色：标签（「监控进程」「翻墙代理」）是固定名词，
# 不该随状态变色。整行同色时状态好的行整行绿、状态无的行整行灰，
# 用户扫一眼看到"有的绿有的灰"，却分不清哪段是名字、哪段是结论。
# 标签统一 key（与帮助左列、菜单名字同色），内容按状态 ok/warn/dim/text。
_status_row() {
    _sr_label="$1"; _sr_value="$2"; _sr_role="${3:-text}"
    if [ ! -t 1 ]; then printf '%s : %s\n' "$_sr_label" "$_sr_value"; return 0; fi
    _sr_lc=$(style_color key)
    _sr_vc=$(style_color "$_sr_role")
    if [ -z "$_sr_vc" ]; then
        printf '\033[%sm%s : \033[0m%s\n' "$_sr_lc" "$_sr_label" "$_sr_value"
    else
        printf '\033[%sm%s : \033[0m\033[%sm%s\033[0m\n' "$_sr_lc" "$_sr_label" "$_sr_vc" "$_sr_value"
    fi
    return 0
}

show_status() {
    style_out title "======== EnvProxy 状态 ========"
    # ---- 先把结论算出来：这一屏只回答一个问题"我现在正常吗" ----
    # 读完 8 行再自己合成判断，是这屏原来最大的问题；正常项与异常项也不再同构平铺。
    get_status_snapshot

    # ---- 结论行 ----
    # 这台机器上到底装过没装过。判据是安装时写下的路径记录——它只在安装时写、卸载时删。
    # 用途是避免把"从没装过"说成"崩溃/被强制退出"：后者是故障语气，
    # 而首次打开的人看到的应该是"还没装，按 1 就好"，不是"你的东西坏了"。
    # 必须算在结论行**之前**：结论行要用它。
    if [ -f "$PATH_CONF" ]; then _never_installed=0; else _never_installed=1; fi
    _pb=""
    if [ -z "$_m" ]; then
        if [ -f "$STOP_INTENT" ]; then _pb="$_pb监控按你的选择停着
"; elif [ "$_never_installed" = "1" ]; then _pb="$_pb还没安装
"; else _pb="$_pb监控进程不在了（可能被强制退出或崩溃）
"; fi
    fi
    [ "$_autorun_ok" = "0" ] && _pb="$_pb开机自启没生效
"
    [ "$_port_unknown" = "1" ] && _pb="$_pb这一轮没读到本机端口，无法判断代理
"
    if [ -n "$_cur" ] && [ -z "$_cur_alive" ]; then _pb="$_pb代理变量里不是合法地址
"
    elif [ -n "$_cur" ] && [ "$_cur_alive" = "0" ]; then _pb="$_pb代理变量指向的端口已经不在
"; fi
    case "$_ts_state" in ok) : ;; *) _pb="$_pb终端同步没生效
";; esac
    [ "$_sp_bad" = "1" ] && _pb="$_pb系统代理可能残留（不是本工具写的）
"
    # 上次更新是否中途死了：这个标记只有断电/被杀才会留下。
    # 那种情况下入口通常还能起来、启动自检全绿，但安装区可能新旧混合，
    # 表现为某些功能静默失效——所以必须主动说出来。
    _upd_prog=0
    [ -f "$MONITOR_DIR/update.inprogress" ] && _upd_prog=1
    [ "$_upd_prog" = "1" ] && _pb="$_pb上次更新没有完成，程序文件可能新旧混合
"
    # 计数与列表必须来自同一批条目：先切成数组，再数个数、再逐条打印。
    # 早先两边各算一遍，于是出现了"有 1 项要注意"下面一条都不显示的分叉。
    # 计数与列表同源：_pb 从一开始就是**换行分隔**，数个数与逐条打印读同一份。
    # 早先两边各算一遍（而且分隔符用的是全角分号、切分器认的是半角），
    # 于是出现过"有 1 项要注意"下面把三件事挤成一行的情况。
    _pn=0
    if [ -n "$_pb" ]; then
        _pn=$(printf '%s' "$_pb" | grep -c . || true)
    fi
    if [ "$_pn" = "0" ]; then
        style_out ok "一切正常，不用做任何事。"
    elif [ "$_never_installed" = "1" ]; then
        # 从没装过：几件"没生效"都是同一个事实（还没装），
        # 说成"有 N 项要注意"会让第一次打开的人以为机器有好几处毛病。
        style_out dim "还没开始用。打开菜单选 1（安装 / 修复）就能装上。"
    else
        style_out warn "有 $_pn 项要注意："
        printf '%s' "$_pb" | while IFS= read -r _pb1; do
            [ -n "$_pb1" ] && style_out warn "  - $_pb1"
        done
    fi
    echo ""

    # ---- 要注意的：只印有问题的那几项，每项带一句怎么办 ----
    if [ -z "$_m" ]; then
        _status_row "监控进程" "未运行" warn
        # "停止"是一个稳定状态（自启动只在登录时拉起一次，不保活）。
        # 但"未运行"有两个完全不同的原因，事后长相一样：使用者主动停的，还是进程被
        # 强制退出/崩溃了。只有执行停止的那一方留下的意图标记能分辨。
        # 与 Windows 侧 stopped.intent 同一手法：猜错的代价是把崩溃说成用户选择。
        if [ -f "$STOP_INTENT" ]; then
            if [ "$_autorun_ok" = "1" ]; then
                style_out dim "  （你点过停止。下次登录会自动恢复，或现在选 1）"
            else
                style_out warn "  （你点过停止，但开机自启记录也坏了，下次登录不会自动恢复）"
                style_out dim "  打开菜单选 1（安装 / 修复）可以一起修好。"
            fi
        elif [ "$_never_installed" = "1" ]; then
            # 从没装过：这不是问题，是起点。用"崩溃/被强制退出"描述它，
            # 第一次打开的人会以为自己的机器出了事（"我明明没装过"）。
            style_out dim "  （还没装过。装上之后它会自己常驻，不用你管）"
            style_out dim "  打开菜单选 1（安装 / 修复）开始使用。"
        else
            style_out warn "  （不是点了停止，是进程不在了：可能被强制退出，或崩溃）"
            style_out dim "  打开菜单选 1（安装 / 修复）可以让它重新跑起来。"
        fi
    fi
    if [ "$_autorun_ok" = "0" ]; then
        if [ "$_autorun_reg" = "1" ]; then
            _status_row "开机自启" "记录还在，但启动文件已不存在（登录时不会启动）" warn
            style_out dim "  记录指向：$LOCATOR_PATH"
            style_out dim "  打开菜单选 1（安装 / 修复）可以重建。"
        elif [ -f "$PLIST_PATH" ]; then
            _status_row "开机自启" "已写入但未加载" warn
            style_out dim "  打开菜单选 1（安装 / 修复）可以重建。"
        else
            _status_row "开机自启" "未启用" warn
            style_out dim "  打开菜单选 1（安装 / 修复）可以启用。"
        fi
    fi
    if [ -n "$_cur" ] && [ -z "$_cur_alive" ]; then
        _status_row "代理变量" "值不是合法地址（$_cur）" warn
        style_out dim "  多半是别的工具改写成了半个地址。选 1（安装 / 修复）会按当前代理重写一遍。"
    elif [ -n "$_cur" ] && [ "$_cur_alive" = "0" ]; then
        _status_row "代理变量" "指向的端口已不在（$_cur）" warn
        style_out warn "  终端里联网会报 ECONNREFUSED，错误里没有本工具的名字，所以你会去查网络。"
        style_out dim "  监控在跑的话几秒内会自动清掉；想立刻清掉就选 1（安装 / 修复）。"
    elif [ -n "$_cur" ] && [ -z "$_m" ]; then
        _status_row "代理变量" "已注入（$_cur），但没人维护" warn
        style_out dim "  翻墙软件断开后不会自动清掉，终端会连不上。"
        style_out dim "  打开菜单选 1 恢复监控；或选 5 把这批变量一并清掉。"
    elif [ -z "$_cur" ] && [ -n "$_port" ] && [ -z "$_m" ]; then
        # "翻墙代理有" + "代理变量无" 单独看像自相矛盾。实话是：软件在跑，
        # 但本工具没在它上面工作（多半是使用者自己停的）。补一句桥接，否则会被判定"坏了"。
        # 与 Windows 侧同一句、同一判据。
        _status_row "代理变量" "无（翻墙软件在跑，但本工具已停用，所以没往终端里设代理）" dim
    fi
    case "$_ts_state" in
        unpaired)
            _status_row "终端同步" "配置文件里的标记不成对，未改动它" warn
            if [ -n "$_ts_badline" ]; then
                style_out dim "  删掉配置文件里孤立的那行标记（第 $_ts_badline 行）再选 1。"
            else
                style_out dim "  删掉配置文件里孤立的 EnvProxy 标记行再选 1。"
            fi ;;
        stale)
            _status_row "终端同步" "同步块是旧版本的" warn
            # 内容过期不是用户的问题，也不用手工改：安装会按当前版本重写。
            style_out dim "  这不影响用，只是那段代码旧了；打开菜单选 1 会更新它。" ;;
        missing)
            _status_row "终端同步" "配置文件里没有同步块" warn
            style_out dim "  打开菜单选 1 可以写入。" ;;
        *)
            # 走到这里说明判定端又加了新状态而这里没跟上。静默跳过不行：
            # 上面的问题清单会说"终端同步没生效"，而往下整屏找不到"终端同步"
            # 四个字——用户被指向一个不存在的提示。Windows 侧真发生过一次
            # （State 叫 nohost、switch 处理的是 unknown，恰好错位）。
            _status_row "终端同步" "状态未知（$_ts_state）" warn
            style_out dim "  打开菜单选 1（安装 / 修复）重写一次。" ;;
    esac
    if [ "$_upd_prog" = "1" ]; then
        _status_row "上次更新" "没有完成（覆盖过程中断）" warn
        style_out dim "  程序文件可能新旧混合，某些功能会静默失效。"
        style_out dim "  打开菜单选 1（安装 / 修复）重做一次即可。"
    fi
    if [ "$_sp_bad" = "1" ]; then
        _status_row "系统代理" "疑似残留（指向本机死端口 127.0.0.1:$_sp_port，非本工具写入）。" warn
        style_out dim "  浏览器打不开先检查它：系统设置 → 网络 → 代理，或把翻墙软件断开重进一次。"
    fi
    [ "$_pn" != "0" ] && echo ""

    # ---- 参考信息：正常项 ----
    [ -n "$_m" ] && _status_row "监控进程" "运行中 (PID $_m)" ok
    [ "$_autorun_ok" = "1" ] && _status_row "开机自启" "已启用" ok
    if [ -n "$_port" ]; then
        _status_row "翻墙代理" "已开启（本地端口 $_port 监听中）" ok
    elif [ "$_port_unknown" = "1" ]; then
        _status_row "翻墙代理" "这一轮没读到本机端口，无法判断（正常，会自动重试）" warn
    else
        _status_row "翻墙代理" "未检测到（当前无翻墙代理在运行）" dim
    fi
    [ "$_ts_state" = "ok" ] && _status_row "终端同步" "已生效（已开着的窗口敲回车即跟上）" ok
    # 代理变量只有"已注入且活着且监控在跑"才进参考区；其余分支上半段已经说过，
    # 这里再打一遍就是同一件事说两次。
    if [ -n "$_cur" ] && [ "$_cur_alive" = "1" ] && [ -n "$_m" ]; then
        _status_row "代理变量" "已注入 ($_cur)" ok
    elif [ -z "$_cur" ] && [ -z "$_port" ]; then
        # 只有"确实没有翻墙软件在跑"时才说"直连状态"。
        # 少了 [ -z "$_port" ] 这一半，就会与上面那条"翻墙软件在跑但本工具已停用"
        # 同时命中：同一屏里"代理变量"出现两次、说法还相反。
        _status_row "代理变量" "无（直连状态）" dim
    fi

    # 版本那三行：正常时压成一行。原来"本地版本/最新版本/更新状态"各占一行、
    # 与"监控未运行"平级，等于把对普通用户没有行动价值的信息和要靠它行动的信息摆成一样重。
    #
    # 数据来自监控写的缓存，所以有三种情况，必须分开说：
    #   有且新鲜  → 正常比较版本
    #   有但很旧  → 仍然比较，但把"这是多久以前查的"一起说出来（陈旧数据不许假装是当前数据）
    #   还没有    → 说明为什么还没有（监控没在跑 / 刚装上），并给出主动查的办法
    _local_text="未知"
    [ -n "$_local_ver" ] && _local_text="v$_local_ver"
    _vc=""; _vc_age=""
    _vc_line=$(read_version_cache 2>/dev/null || true)
    if [ -n "$_vc_line" ]; then
        _vc=$(printf '%s' "$_vc_line" | cut -d' ' -f1)
        _vc_age=$(printf '%s' "$_vc_line" | cut -d' ' -f2)
    fi
    if [ -z "$_vc" ]; then
        # 还没有缓存：不联网、不猜，说清为什么 + 去哪儿主动查。
        _status_row "版本" "$_local_text（还没查过最新版；监控每 30 轮查一次，也可以选 3 立刻查）" dim
    else
        REMOTE_VERSION="$_vc"
        REMOTE_TAG="v$_vc"
        _age_text=""
        case "$_vc_age" in
            ''|*[!0-9]*) ;;
            *)
                if [ "$_vc_age" -ge 1440 ]; then _age_text="（$((_vc_age / 1440)) 天前的记录）"
                elif [ "$_vc_age" -ge 60 ]; then _age_text="（$((_vc_age / 60)) 小时前的记录）"
                fi ;;
        esac
        _state=""
        _role="ok"
        if is_dev_copy; then
            _state="开发副本（更新走 git pull，本入口不改动文件）"; _role="dim"
        elif is_source_copy; then
            _state="源码包（更新入口会先确认用途再动手）"; _role="warn"
        elif [ -z "$_local_ver" ]; then
            _state="可打开菜单选 3（检查更新）升级"; _role="warn"
        else
            _newer=$(compare_versions "$_local_ver" "$REMOTE_VERSION" || true)
            if [ "$_newer" -gt 0 ] 2>/dev/null; then
                _state="本地版本比最新发布版新"; _role="dim"
            else
                _older=$(compare_versions "$REMOTE_VERSION" "$_local_ver" || true)
                if [ "$_older" -gt 0 ] 2>/dev/null; then
                    _state="发现新版 $REMOTE_TAG，选 3（检查更新）即可升级"; _role="warn"
                else
                    _state="已是最新"; _role="dim"
                fi
            fi
        fi
        style_out "$_role" "版本 : $_local_text（$_state）$_age_text"
    fi

    style_out title "---------------- 最近日志 ----------------"
    if [ -f "$LOG_FILE" ]; then
        # 日志行按终端宽度裁：日志文件里的长行是给"搜"用的（不折行才好 grep），
        # 但状态页会把它原样打到屏幕上，长行会硬折成两三行，屏幕上就是一团乱。
        # 与 Windows 侧同一做法（那边取 [Console]::WindowWidth）。
        # 默认 80 列（多数终端的标准宽度）。80 不是随手取的：本工具自己写下的
        # 日志行最长约 80 格（"检测到本地代理端口 7078 -> 已注入代理 http://127.0.0.1:7078"
        # 正是 80）。默认值比它小，最常见的那条日志每屏都被截成 "http://127.0.0.1:7…"，
        # 而截掉的恰好是端口号——排查时最想看的那个数字。与 Windows 侧同值。
        _lg_w=80
        if [ -t 1 ]; then
            _lg_cols=$(tput cols 2>/dev/null || echo "")
            case "$_lg_cols" in ''|*[!0-9]*) ;; *) _lg_w=$((_lg_cols - 2)) ;; esac
        fi
        [ "$_lg_w" -lt 40 ] && _lg_w=40
        tail -n 3 "$LOG_FILE" 2>/dev/null | while IFS= read -r _lg_l; do
            style_out dim "  $(_truncate_width "$_lg_l" $((_lg_w - 1)))"
        done
    else
        style_out dim "  （暂无日志）"
    fi
    style_out title "=================================="
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
# 每一项在**三处**拼装：短名（_help_topic_short）、标题（_help_topic_title）、
# 帮助主题表：**一条记录就是一条主题**，编号 | 短名 | 标题。
# 为什么合起来：原来是"编号表 + short 分派 + title 分派 + body 分派"四处平行结构，
# 加一条主题要改四处、漏改不报错——症状是目录里出现空标题，或选中后是一页空白。
# Windows 侧一直是单表（Get-HelpTopics 一条记录含 Key/Title/Short/Lines），这里对齐。
# 正文（body）仍单独按编号分派：它太长，塞进这张表会把表撑得读不下去。
#
# 编号必须连续且没有重复——自检里有一条断言直接检查这张表的形状。
HELP_TOPICS=(
    '1|用处|这是干什么用的'
    '2|装完|装完之后要我做什么'
    '3|窗口|这个窗口固定直连 / 恢复自动'
    '4|代理|这个窗口走公司代理'
    '5|命令|我要让某条命令不走代理'
    '6|菜单|菜单每一项是干什么的'
    '7|连不上|装了还是连不上网 / 状态不对'
    '8|不行|还是不行 / 想删掉它'
)

# 从 HELP_TOPICS 取第 N 段（$1=字段号，$2=主题编号）。
_help_topic_field() {
    _htf_want="$2"
    for _htf_rec in "${HELP_TOPICS[@]}"; do
        case "$_htf_rec" in
            "$_htf_want"\|*)
                _htf_rest=${_htf_rec#*|}
                case "$1" in
                    1) printf '%s' "${_htf_rest%%|*}" ;;
                    2) printf '%s' "${_htf_rest#*|}" ;;
                esac
                return 0 ;;
        esac
    done
    return 0
}
_help_topic_short() { _help_topic_field 1 "$1"; }
_help_topic_title() { _help_topic_field 2 "$1"; }

# 全部主题编号，从表里派生 —— 不再单独维护一张编号表。
# 名字保持 HELP_TOPIC_KEYS（状态页、帮助目录、底部编号行、自检都在读它），
# 但内容由 HELP_TOPICS 算出来：改表就自动同步，没有第二处要记得改。
HELP_TOPIC_KEYS=()
# 用 ${ARR[@]+"${ARR[@]}"} 而不是裸的 "${ARR[@]}"：bash 3.2（macOS 自带）
# 在 set -u 下展开"尚未赋过值"的数组会报 "unbound variable"——4.x 才修。
# 而 HELP_TOPIC_KEYS 正是先声明成空、再逐个 append，第一次 append 时
# 它就是"还没赋过值"的状态，真机上当场崩（CI 报的就是这一行）。
# 入口开着 set -u，这个坑绕不过去。
for _htk_rec in ${HELP_TOPICS[@]+"${HELP_TOPICS[@]}"}; do
    HELP_TOPIC_KEYS=(${HELP_TOPIC_KEYS[@]+"${HELP_TOPIC_KEYS[@]}"} "${_htk_rec%%|*}")
done
unset _htk_rec

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
# 把一组编号写成人话。连续就写「1-6」，中间有断层就逐个列出来。
# 为什么不能只取首尾：从表里删掉一项之后，首尾相减仍然给出「1-6」，
# 而那段时间里 4 已经不存在了——用户照着敲 4，得到「没有这个编号」。
# 提示的用途是告诉他能敲什么，说错比不说更糟。
format_key_list() {
    _fkl_all=""
    for _fkl_k in "$@"; do _fkl_all="$_fkl_all $_fkl_k"; done
    set -- $_fkl_all
    if [ $# -eq 0 ]; then echo ""; return 0; fi
    if [ $# -eq 1 ]; then echo "$1"; return 0; fi
    _fkl_prev=""
    _fkl_contig=1
    for _fkl_k in "$@"; do
        if [ -n "$_fkl_prev" ] && [ "$_fkl_k" -ne $((_fkl_prev + 1)) ]; then _fkl_contig=0; break; fi
        _fkl_prev=$_fkl_k
    done
    if [ "$_fkl_contig" = "1" ]; then
        echo "$1-$_fkl_prev"
    else
        echo "$*"
    fi
}

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
    _mkr_text=$(format_key_list "$@")
    if [ -n "$_mkr_quit" ]; then
        _mkr_q=$(format_key_list $_mkr_quit)
        _mkr_text="$_mkr_text 和 $_mkr_q"
    fi
    echo "$_mkr_text"
}

# 底部那一行「有 1-8」/「有 1 2 3 5 6 7 8」。
# **不能只取首尾**：从主题表里删掉一项之后，首尾相减仍然给出「1-8」，
# 而那段时间里 4 已经不存在了——用户照着敲 4，得到「没有这个编号」。
# 提示的用途是告诉他能敲什么，说错比不说更糟。
# 判据只有一处：format_key_list（它已经会处理断层），这里只加前缀。
format_help_key_range() {
    _hkr_n=${#HELP_TOPIC_KEYS[@]}
    if [ "$_hkr_n" -eq 0 ]; then echo "没有可用的编号"; return 0; fi
    if [ "$_hkr_n" -eq 1 ]; then echo "只有 ${HELP_TOPIC_KEYS[0]}"; return 0; fi
    echo "有 $(format_key_list "${HELP_TOPIC_KEYS[@]}")"
}

# 帮助里「菜单每一项是干什么的」那一屏的正文，从 MENU_ITEMS 生成。
# 为什么生成而不是手抄：手抄的那一份在改菜单时会静默过期，症状是用户照帮助里的
# 编号去敲，敲到的是另一件事（想检查更新，结果卸载了）。生成之后这份内容与菜单
# 读同一张表，改表即同步，不存在"两边都要记得改"。
_help_menu_lines() {
    _hml_w=$(for _hml_i in "${MENU_ITEMS[@]}"; do
        _hml_rest=${_hml_i#*|}
        printf '%s\n' "${_hml_rest%%|*}"
    done | _max_width_of)
    echo "t 这些编号要在主菜单里敲，不是在帮助里敲。"
    for _hml_g in $(_menu_group_order); do
        echo "b "
        if [ "$_hml_g" = "日常" ]; then
            echo "h $_hml_g（平时只会用到这些）"
        else
            echo "h $_hml_g"
        fi
        for _hml_i in "${MENU_ITEMS[@]}"; do
            _hml_rest=${_hml_i#*|}
            _hml_name=${_hml_rest%%|*}
            _hml_rest2=${_hml_rest#*|}
            _hml_hint=${_hml_rest2%%|*}
            _hml_grp=${_hml_i%|*}; _hml_grp=${_hml_grp##*|}
            [ "$_hml_grp" != "$_hml_g" ] && continue
            _hml_key=${_hml_i%%|*}
            # 三格：编号 / 名字 / 说明。名字列由渲染器按整块自动补齐，不在这里手敲空格。
            echo "m $_hml_key|$_hml_name|$_hml_hint"
        done
    done
}

# 帮助正文的角色标记。每一行自己声明"我是什么"，渲染器照着画，不再从行的形状去猜。
#
# 为什么必须这样：靠形状猜的判据是"缩进 4 格以上 + 这一行没有汉字 = 命令"，
# 而真实内容不按这个形状长——`Git Bash   source ~/.bashrc` 带了左列标签，
# `PowerShell  $env:ENVPROXY_TERM = 'off'` 只缩进 2 格，两行都是能整行复制的命令，
# 却都会被判成普通说明（灰）。同一屏里 `set HTTP_PROXY=…` 是绿的、旁边三行是灰的，
# 用户看到的就是"配色坏了"。这不是漏了哪一行，是判据本身注定会错。
#
# 标记写在行首，一个字母加一个空格（与 Windows 侧同一套，门禁 6 核对）：
#   h  小标题                         t  正文
#   t2 正文（接在编号条目下面的续行）  i  编号条目
#   w  提醒                           c  命令（整行可复制）
#   b  空行
#   r  两列：左列说"在哪儿敲"、右列是说明      rc 两列，右列是命令
#   m  三格：编号 / 名字 / 说明（菜单那一屏）
# 多列行的写法：'rc PowerShell|export ENVPROXY_TERM=off'
# 列宽由渲染器按整块自动算，不手敲空格——手敲与写死列宽是同一类毛病。
_help_indent() {
    case "$1" in
        h) echo 0 ;;
        t) echo 2 ;;
        t2) echo 6 ;;
        i) echo 4 ;;
        w) echo 2 ;;
        c) echo 6 ;;
        r|rc|m) echo 4 ;;
        *) echo 0 ;;
    esac
}

# 帮助正文的角色标记表：所有合法标记。渲染与自检都读它，加一种标记只改这里。
HELP_LINE_CODES="h t t2 i w c b r rc m"

_help_code_valid() {
    case " $HELP_LINE_CODES " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# 按角色输出一行帮助正文（带 _SEG_* 那套上色开关）。
_help_render_line() {
    _hrl_raw="$1"
    _hrl_code=${_hrl_raw%% *}
    _hrl_rest=${_hrl_raw#* }
    # 标记认不出来时按正文处理并把整行原样显示：宁可颜色不理想，也不能把内容弄丢。
    if ! _help_code_valid "$_hrl_code"; then
        _hrl_code="t"
        _hrl_rest="$_hrl_raw"
    fi
    _hrl_ind=$(_help_indent "$_hrl_code")
    _hrl_pad=$(printf '%*s' "$_hrl_ind" '')
    case "$_hrl_code" in
        b)  _line_blank ;;
        h)  _seg heading "$_hrl_pad$_hrl_rest"; _line_flush ;;
        i)  _seg item "$_hrl_pad$_hrl_rest"; _line_flush ;;
        w)  _seg warn "$_hrl_pad$_hrl_rest"; _line_flush ;;
        c)  _seg cmd "$_hrl_pad$_hrl_rest"; _line_flush ;;
        r|rc)
            _hrl_key=${_hrl_rest%%|*}
            _hrl_val=${_hrl_rest#*|}
            _hrl_kw=$(_help_block_key_width)
            _seg key "$_hrl_pad$(_menu_cell_pad "$_hrl_key" "$_hrl_kw")   "
            if [ "$_hrl_code" = "rc" ]; then _seg cmd "$_hrl_val"; else _seg text "$_hrl_val"; fi
            _line_flush ;;
        m)
            _hrl_key=${_hrl_rest%%|*}
            _hrl_rest2=${_hrl_rest#*|}
            _hrl_name=${_hrl_rest2%%|*}
            _hrl_hint=${_hrl_rest2#*|}
            [ "$_hrl_hint" = "$_hrl_name" ] && _hrl_hint=""
            _hrl_nw=$(_help_block_name_width)
            _seg cmd "$_hrl_pad$_hrl_key  "
            _seg value "$(_menu_cell_pad "$_hrl_name" "$_hrl_nw")"
            [ -n "$_hrl_hint" ] && _seg dim "   $_hrl_hint"
            _line_flush ;;
        *)  _seg text "$_hrl_pad$_hrl_rest"; _line_flush ;;
    esac
    return 0
}

# 一个主题里两列行的左列宽度（只按两列行算，别的行不参与——
# 否则一段长正文会把列撑得很宽）。当前正在渲染的主题由 _HELP_BLOCK 指定。
_help_block_key_width() {
    # 取所有两列行（r / rc）的左列，求最宽。喂给 _max_width_of 而不是自己数——
    # "宽度怎么算"只该有 _display_width 一个答案。
    _hbk_w=$(printf '%s\n' "$_HELP_BLOCK" | while IFS= read -r _hbk_l; do
        _hbk_c=${_hbk_l%% *}
        case "$_hbk_c" in r|rc) : ;; *) continue ;; esac
        _hbk_rest=${_hbk_l#* }
        printf '%s\n' "${_hbk_rest%%|*}"
    done | _max_width_of)
    printf '%s' "$_hbk_w"
}

# 一个主题里 m 行的名字列宽度。
_help_block_name_width() {
    # 取所有 m 行（菜单屏）的名字列，求最宽。
    _hbn_w=$(printf '%s\n' "$_HELP_BLOCK" | while IFS= read -r _hbn_l; do
        _hbn_c=${_hbn_l%% *}
        [ "$_hbn_c" = "m" ] || continue
        _hbn_rest=${_hbn_l#* }
        _hbn_rest2=${_hbn_rest#*|}
        printf '%s\n' "${_hbn_rest2%%|*}"
    done | _max_width_of)
    printf '%s' "$_hbn_w"
}

# 单个主题的正文。用 cat 输出，与 Windows 侧 Get-HelpTopics 的 Lines 一一对应。
_help_topic_body() {
    case "$1" in
    1) cat <<'TOPIC'
h 它做什么
t 翻墙软件一开，终端里的 git、npm、curl 就能翻墙；
t 一关，它们自动恢复直连。不用记任何开关。
b 
h 它怎么判断你现在在翻墙
t 每 2 到 3 秒看一次。要同时满足三条才算：
i 1. 本机有端口在监听；
i 2. 它确实是个代理，会回应握手；
i 3. 它确实连得通外面，试 6 个端点任意一个通就算。
t 三条全过才写变量。所以本机开着网页服务、开发服务器都不会被误判。
t 它不认品牌、不认进程名、不认端口号，那些只用来加快扫描。
TOPIC
    ;;
    2) cat <<'TOPIC'
h 装完之后，按窗口分三种情况
b 
i 1. 装完之后才打开的窗口
t2 启动时读到的就是当前状态，什么都不用做。
b 
i 2. 装完之后打开的窗口，后来代理又变了
t2 按一次回车即可。cmd 窗口没有这个机制，只能重开。
b 
i 3. 装之前就已经开着的窗口
t2 同步代码还没装进去。在那个窗口里敲下面这一条，或者重开窗口：
b 
rc zsh / bash|. ~/.envproxy/prompt-sync.sh
rc cmd|Windows 的 cmd 窗口没有这条命令，只能重开
b 
t 开头的点号和后面的空格都不能少；fish 不支持。
b 
h 为什么要按一次回车
t 每个程序只在启动那一刻读一次环境变量，读完就固定了。之后系统改了，
t 已经在跑的窗口不会跟着变。EnvProxy 挑的时机是每次命令跑完、
t 等你回到能打字的状态时同步——你本来就一直在敲命令，不用专门做什么。
TOPIC
    ;;
    3) cat <<'TOPIC'
h 一、让这个窗口一直直连
b 
rc zsh / bash|export ENVPROXY_TERM=off
b 
t 敲完下一次回到提示符时生效。你自己设的值（比如公司代理）不会被删。
t fish 不支持：它不读这些配置文件，这个开关对它无效。
b 
w 别只 unset 一个拼写：mac 上大写和小写是两个变量，各写一份。
t 只清大写的话，小写那份还在，curl 照样走代理——两个都要清。
b 
h 二、改回自动跟随
b 
rc zsh / bash|unset ENVPROXY_TERM
b 
t 上面两节都只对这个窗口有效，窗口一关就没了。
TOPIC
    ;;
    4) cat <<'TOPIC'
t 先做第 3 条（固定直连），再设地址。顺序反了等于没设。
b 
h 一、设地址（换成公司给的）
b 
rc zsh / bash|export HTTPS_PROXY=http://你的地址:端口
b 
h 二、看现在走不走代理（有值 = 走，空的 = 直连）
b 
rc zsh / bash|echo $HTTPS_PROXY
b 
t 端口是你公司给的，问 IT 要（通常会给一份代理设置说明）。
w 注意：这里不是翻墙软件那个端口，别去那儿找。
t 你手设的值不会被删，只清和工具写入值相同的那些。
TOPIC
    ;;
    5) cat <<'TOPIC'
h 不同工具写法不一样，没有通用的一条命令
b 
h curl
c curl --noproxy '*' https://example.com
b 
h git
c git -c http.proxy= -c https.proxy= clone https://github.com/git/git.git
t 等号后留空，这条就不用代理；写别的值，就改用那个代理。
b 
h npm
c npm --noproxy=registry.npmjs.org install typescript
w 注意：只认具体网址，写 * 没用，而且不报错，请求照常走代理。
t 写成 --no-proxy 会被理解成关闭代理，也不是你要的效果。
t 另外 npm 只认 HTTPS_PROXY，不认 HTTP_PROXY。
b 
h wget
t Mac 不自带 wget，自己装过才用得上这一条：
c wget --no-proxy https://example.com
b 
h docker
t 没有单条命令的写法，改 Docker 自己的设置（Settings 里的 Proxies）。
TOPIC
    ;;
    6) _help_menu_lines
    ;;
    7) cat <<'TOPIC'
h 连不上网，按这个顺序查
i 1. 在那个窗口里看变量有没有值。终端输入：
c echo $HTTPS_PROXY
t2 空的就是没注入，重开一个窗口就好。
b 
i 2. 有值还是连不上：看菜单顶上「监控」写的是运行中还是未运行。
t2 未运行就选 1（安装 / 修复）。
b 
i 3. npm 只认 HTTPS_PROXY，不认 HTTP_PROXY；你自己清过它就不走了。
b 
h 状态页怎么读
r 监控进程|后台程序在不在跑
r 开机自启|下次登录会不会自动起来
r 翻墙代理|本机有没有翻墙软件在监听端口
r 终端同步|已经开着的窗口会不会跟着变
r 代理变量|这个工具往终端里设代理了没有
t 「翻墙代理」有、「代理变量」无 = 翻墙在跑、工具被你停了，不是坏了。
t 其余几行是系统代理、版本号、更新状态。
b 
h 日志和 AI 排查
t 日志在 mac/monitor/monitor.log，反馈附最后 20 行。
t AI 报 ECONNREFUSED 127.0.0.1:端口号 = 变量指向了已关闭的端口，
t 不是网络坏了。菜单选 2 看「代理变量」那行会直接说清。
t 它只管 HTTP/HTTPS 变量；ping、游戏、BT 这类走自己协议的
t 不认——那些要开翻墙软件的 TUN 模式。
TOPIC
    ;;
    8) cat <<'TOPIC'
h 大部分问题都可以用「安装 / 修复」解决
t 打开菜单选 1。它不会重复安装，不会中断网络，也不会丢失你的设置。
b 
h 还是不行
t 菜单选 2 把状态截图，再选 1 修复一次。反馈时附上 mac/monitor/monitor.log
t 最后 20 行，能省很多来回。
b 
h 想彻底删掉它
t 菜单选 6（一键恢复）。会问你要不要留日志。
b 
h 不开菜单也能用（适合写脚本，或远程连过来）
r 开关|install  status  stop  uninstall  update  help  menu  self-test
r 补充|--yes    跳过确认（检查和卸载时问的那句）
r 补充|--purge  卸载时连历史日志一起删
r 补充|repair-profile  摘掉配置文件里孤立的标记（会先备份）
t --purge 连日志一起删，只配 uninstall 用。完整写法：
c bash envproxy.sh status
t self-test 是 mac 独有（Windows 的同等检查不进安装包，由开发侧跑）。
t 不碰你的 ~/.zshrc 和环境变量，只报告自检结果或指出哪一项不对。
TOPIC
    ;;

    esac
    return 0
}

# 帮助目录屏的内容。整屏只有这一份：纯文本与彩屏都走它，
# 于是"改一个字只改一处"，也不可能出现"屏幕上有、测试里没有"。
#
# 编号用命令色、标题用强调色、底部说明用灰：与主菜单同一套三层区分，
# 用户在两个页面之间切换时不用重新认一遍。
# 参数 = 1 上色，= 0 纯文本；内容只有这一份。
_render_help_index() {
    _rhi_colored="$1"
    _rhi_ver=$(get_local_version 2>/dev/null || true)
    [ -z "$_rhi_ver" ] && _rhi_ver="未知"
    _SEG_COLORED="$_rhi_colored"
    _SEG_LINE=""
    _seg title "================ EnvProxy 帮助 ================"
    _line_flush
    _line_blank
    _seg text "  按你遇到的问题挑一条："
    _line_flush
    for _rhi_k in "${HELP_TOPIC_KEYS[@]}"; do
        _seg cmd "    $_rhi_k"
        _seg value "  $(_help_topic_title "$_rhi_k")"
        _line_flush
    done
    _line_blank
    _seg dim "  本机版本 v$_rhi_ver"
    _line_flush
    _line_blank
    _seg dim "  输编号查看    直接回车 = 回主菜单"
    _line_flush
}

# 帮助目录屏（带配色）。
show_help_index_colored() {
    _render_help_index 1
}

# 帮助目录的纯文本（非交互与自检用）。与彩屏同一份内容，只差上不上色。
format_help_index() {
    _render_help_index 0
}

# 单个主题：正文前后各留一行，底部固定给返回方式。
format_help_topic() {
    _ht_title=$(_help_topic_title "$1")
    [ -z "$_ht_title" ] && return 1
    _SEG_COLORED=0
    _SEG_LINE=""
    echo "================ 帮助 $1 · $_ht_title ================"
    echo ""
    _HELP_BLOCK=$(_help_topic_body "$1")
    while IFS= read -r _ht_l; do
        _help_render_line "$_ht_l"
    done <<EOF
$_HELP_BLOCK
EOF
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

# 带配色地打一个主题。与 format_help_topic 同一个渲染函数，只差上不上色。
show_help_topic_colored() {
    # 没终端就不上色，直接给纯文本（与菜单同一判据）。
    if [ ! -t 1 ]; then format_help_topic "$1"; return $?; fi
    _sht_title=$(_help_topic_title "$1")
    [ -z "$_sht_title" ] && return 1
    _SEG_COLORED=1
    _SEG_LINE=""
    _seg title "================ 帮助 $1 · $_sht_title ================"
    _line_flush
    _line_blank
    _HELP_BLOCK=$(_help_topic_body "$1")
    while IFS= read -r _sht_l; do
        _help_render_line "$_sht_l"
    done <<EOF
$_HELP_BLOCK
EOF
    _line_blank
    _seg dim "$(format_help_nav_line "$1")"
    _line_flush
    _seg dim "  输编号看别的    直接回车 = 回目录"
    _line_flush
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
            show_help_index_colored
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
# 用户看到的却是错的内容）。所以下面带一道校验，格式不对就当场报错。
MENU_ITEMS=(
    '1|安装 / 修复|第一次用选它；觉得不对劲也选它|日常|install'
    '2|查看状态|现在什么情况，一眼看清|日常|status'
    '3|检查更新|有新版先告诉改了什么，同意才装|日常|update'
    '4|帮助|忘了怎么用就看它|日常|help'
    '5|停止监控|先停掉，下次开机自己回来|维护|stop'
    '6|一键恢复|彻底卸载，回到没装之前|维护|uninstall'
    '0|退出|关掉这个窗口|退出|'
)

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

# 输出一段带颜色的文字到当前行（不换行）。
# _SEG_COLORED=1 时按角色上色，=0 时原样输出——纯文本与彩屏共用同一段渲染代码，
# 于是"屏幕上有、测试里没有"不可能发生。
# DIVERGE(Mac): Windows 侧把渲染结果做成对象再分别输出，这里用"一个开关 + 一个累加器"。
#   原因是 shell 没有对象：用分隔符拼中间格式会在含制表符/空格的内容上出错，
#   而把上色与否塞进同一个渲染函数既不会出错，也不多一份内容。
_SEG_COLORED=1
_SEG_LINE=""
_seg() {
    _seg_role="$1"
    _seg_text="$2"
    if [ "$_SEG_COLORED" = "1" ]; then
        _seg_c=$(style_color "$_seg_role")
        if [ -n "$_seg_c" ]; then
            _SEG_LINE="$_SEG_LINE$(printf '\033[%sm%s\033[0m' "$_seg_c" "$_seg_text")"
            return 0
        fi
    fi
    _SEG_LINE="$_SEG_LINE$_seg_text"
    return 0
}
_line_flush() {
    printf '%s\n' "$_SEG_LINE"
    _SEG_LINE=""
}
_line_blank() {
    printf '\n'
    _SEG_LINE=""
}

# 渲染整张菜单。colored=1 上色，=0 纯文本；内容只有这一份。
_render_menu() {
    _rm_colored="$1"
    # 名字列宽度：从表里抽第二列，交给唯一的"求最宽"函数。
    _rm_w=$(for _rm_i in "${MENU_ITEMS[@]}"; do
        _rm_rest=${_rm_i#*|}
        printf '%s\n' "${_rm_rest%%|*}"
    done | _max_width_of)
    _rm_pid=$(get_monitor_pid || true)
    _rm_ver=$(get_local_version || true)
    [ -z "$_rm_ver" ] && _rm_ver="未知"
    if [ -n "$_rm_pid" ]; then _rm_mon="运行中 (PID $_rm_pid)"; else _rm_mon="未运行"; fi
    _SEG_COLORED="$_rm_colored"
    _SEG_LINE=""
    _seg title "======== EnvProxy 菜单 ========"
    _line_flush
    # 抬头是这一屏最该被看到的一行：用户打开菜单九成的目的是"我现在正常吗"，
    # 答案就在这里（监控在跑 = 正常，未运行 = 有问题）。
    # 早先整行用 dim（暗灰），等于把答案压到最暗、还给它贴了"背景信息"的标签；
    # 而"怎么修"的编号反而是亮绿——优先级是反的。
    # 现在拆两段：标签用灰（它确实是背景），**状态值用 ok/warn**（与状态页同一套语义）。
    if [ -n "$_rm_pid" ]; then _rm_mr="ok"; else _rm_mr="warn"; fi
    _seg dim "  监控 "
    _seg "$_rm_mr" "$_rm_mon"
    _seg dim "    版本 v$_rm_ver"
    _line_flush
    # 未运行时补一句可执行的话：打开菜单 → 第一行就知道好不好 → 坏了直接告诉按哪个键。
    if [ -z "$_rm_pid" ]; then
        _seg dim "        按 1 可以让它重新跑起来"
        _line_flush
    fi
    for _rm_g in $(_menu_group_order); do
        _rm_first=1
        for _rm_i in "${MENU_ITEMS[@]}"; do
            _rm_rest=${_rm_i#*|}
            _rm_name=${_rm_rest%%|*}
            _rm_rest2=${_rm_rest#*|}
            _rm_hint=${_rm_rest2%%|*}
            _rm_grp=${_rm_i%|*}; _rm_grp=${_rm_grp##*|}
            [ "$_rm_grp" != "$_rm_g" ] && continue
            if [ "$_rm_first" = "1" ]; then
                _line_blank
                _seg heading "  $_rm_g"
                _line_flush
                _rm_first=0
            fi
            _rm_key=${_rm_i%%|*}
            _rm_sw=${_rm_i##*|}
            # 退出项没有动作，编号跟着变暗：亮绿色的编号会让人以为"它跟别的项一样要跑个什么"。
            if [ -n "$_rm_sw" ]; then _rm_kr="cmd"; else _rm_kr="dim"; fi
            _seg "$_rm_kr" "    $_rm_key"
            _seg value "  $(_menu_cell_pad "$_rm_name" "$_rm_w")"
            [ -n "$_rm_hint" ] && _seg dim "   $_rm_hint"
            _line_flush
        done
    done
    _line_blank
    _seg dim "  输编号后回车执行    直接回车 = 查看状态"
    _line_flush
}

# 渲染整张菜单（纯文本）。打印与测试共用，表里有什么，屏幕就有什么。
format_menu_text() {
    _render_menu 0
}

# 带配色地打菜单。与 format_menu_text 同一个渲染函数，只差上不上色。
show_menu_colored() {
    # stdout 不是终端就退回纯文本：管道/重定向时转义序列会原样写进日志（实测 ^[[36m），
    # 既弄脏日志也没法给人看。纯文本版本本来就为这种场合准备（也在自检里被断言）。
    if [ ! -t 1 ]; then format_menu_text; return 0; fi
    _render_menu 1
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
    # （输错编号那一轮）。所以它是三态的字符串而不是布尔量：布尔量只能表达"清不清屏"，
    # 输错时仍会重画整张菜单，连错几次屏幕就滚得找不到位置。
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
