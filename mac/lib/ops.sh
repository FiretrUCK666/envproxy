# ------------------------------------------------------------------------------
#  ops.sh — 动作层：菜单背后的安装、停止、卸载、状态编排
#  把下面各层拼成使用者点得到的行为。
#  自检（沙箱回归）不在本文件里，搬到 mac\tests\test-mac-pure.sh，
#  由入口的 self-test 子命令加载——它不属于运行时逻辑。
# ------------------------------------------------------------------------------
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
    # 左边那一列按最长条目补齐，不靠手敲空格：改一个字就整列歪掉，
    # 而"歪一格"这种事只有人眼看得出来。与 Windows 侧同一套做法。
    echo "装好了。之后怎么用："
    _tip_a1="新开的终端 / 程序"
    _tip_a2="一直开着的窗口"
    _tip_a3="装之前就开着的窗口"
    _tip_a4="想让某个窗口固定直连"
    _tip_a5="改回跟着翻墙软件走"
    _tip_a6="忘了怎么用"
    _tip_w=0
    for _tip_t in "$_tip_a1" "$_tip_a2" "$_tip_a3" "$_tip_a4" "$_tip_a5" "$_tip_a6"; do
        _tip_n=$(_menu_cell_width "$_tip_t")
        [ "$_tip_n" -gt "$_tip_w" ] && _tip_w="$_tip_n"
    done
    echo "   $(_menu_cell_pad "$_tip_a1" "$_tip_w")   自动就是对的，什么都不用做。"
    echo "   $(_menu_cell_pad "$_tip_a2" "$_tip_w")   敲一下回车就跟上。"
    echo "   $(_menu_cell_pad "$_tip_a3" "$_tip_w")   重开一个，或者手动加载一次"
    echo "   $(printf '%*s' "$_tip_w" '')   菜单选 4（帮助）第 2 条，有现成命令。"
    echo "   $(_menu_cell_pad "$_tip_a4" "$_tip_w")   在它里面执行  export ENVPROXY_TERM=off"
    echo "   $(_menu_cell_pad "$_tip_a5" "$_tip_w")   unset ENVPROXY_TERM"
    echo "   $(_menu_cell_pad "$_tip_a6" "$_tip_w")   菜单选 4（帮助）。"
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
    # 每条残留都带上**具体路径**。只写"路径记录仍在"再加一句"手动删除上述位置"，
    # 用户看着空白不知道删什么——提示得能照着做才算提示。
    _dirty=""
    if launchctl list 2>/dev/null | grep -qF "$PLIST_LABEL"; then _dirty="$_dirty 开机自启动项仍在（launchctl 里的 $PLIST_LABEL）；"; fi
    if [ -f "$PLIST_PATH" ]; then _dirty="$_dirty 自启动文件仍在（$PLIST_PATH）；"; fi
    if [ -f "$ENVPROXY_HOME/prompt-sync.sh" ]; then _dirty="$_dirty 终端同步脚本仍在（$ENVPROXY_HOME/prompt-sync.sh）；"; fi
    if [ -f "$LOCATOR_PATH" ]; then _dirty="$_dirty 定位脚本仍在（$LOCATOR_PATH）；"; fi
    if [ -f "$PROXY_ENV" ]; then _dirty="$_dirty 代理变量文件仍在（$PROXY_ENV）；"; fi
    if [ -f "$PREV_ENV" ]; then _dirty="$_dirty 变量快照仍在（$PREV_ENV）；"; fi
    if [ -f "$PATH_CONF" ]; then _dirty="$_dirty 路径记录仍在（$PATH_CONF）；"; fi
    if [ -f "$ENVPROXY_HOME/monitor.stdout.log" ] || [ -f "$ENVPROXY_HOME/monitor.stderr.log" ]; then _dirty="$_dirty 自启动重定向残留；"; fi
    # hook 名单与 remove_shell_hooks 同一份（改一边必须改另一边）：残留整块即脏。
    for _rc in "$HOME/.zshenv" "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zlogin" "$HOME/.bash_profile" "$HOME/.bashrc"; do
        if grep -qxF "$HOOK_START" "$_rc" 2>/dev/null; then _dirty="$_dirty 终端同步的配置块还在（$_rc）；"; break; fi
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
        echo "[未完成] 这几处没清干净："
        echo "        $_dirty"
        echo "        再跑一次 uninstall 试一次；还不行就照上面列出的位置手动删。"
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
    # 终端同步到底有没有在生效。光看「块写进去了」不算数：块不成对同样能让
    # 「看起来装好了，实则每次开窗口都不同步」。与 Win 侧 Get-TerminalSyncState 同语义。
    _ts_state="missing"
    _ts_hits=0
    _ts_unpaired=0
    for _ts_p in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
        [ -f "$_ts_p" ] || continue
        # 先看有没有我们的标记：连标记都没有的文件不是「不成对」，是「没装过」，不计数。
        _ts_has_s=0
        grep -qxF "$HOOK_START" "$_ts_p" 2>/dev/null && _ts_has_s=1
        _ts_has_e=0
        grep -qxF "$HOOK_END" "$_ts_p" 2>/dev/null && _ts_has_e=1
        [ "$_ts_has_s" = "0" ] && [ "$_ts_has_e" = "0" ] && continue
        if ! _hook_block_paired "$_ts_p"; then _ts_unpaired=$((_ts_unpaired + 1)); continue; fi
        # 成对了还要看钩子行是不是当前版本：标记在、钩子行被改过就不算生效。
        grep -qxF "$HOOK_LINE" "$_ts_p" 2>/dev/null && _ts_hits=$((_ts_hits + 1))
    done
    if [ "$_ts_hits" -gt 0 ]; then
        _ts_state="ok"
    elif [ "$_ts_unpaired" -gt 0 ]; then
        _ts_state="unpaired"
    fi
    case "$_ts_state" in
        ok)       echo "终端同步 : 已生效（已开着的窗口敲回车即跟上）" ;;
        unpaired) echo "终端同步 : 配置文件里的标记不成对，未改动它（重跑一次安装可修复）" ;;
        *)        echo "终端同步 : 配置文件里没有同步块（重跑一次安装可修复）" ;;
    esac
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
            # 这里只管"能不能连上"，所以两种写法都做同一件事：连一次看成功与否。
            # nc 不认 -G 时（Homebrew 的 GNU netcat 抢占 PATH）改用 curl 探连通。
            if nc_supports_G; then
                if printf '' | nc -z -G 1 -w 1 127.0.0.1 "$_sp_port" 2>/dev/null; then _sp_alive=1; fi
            else
                if env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy \
                    curl --disable -s -o /dev/null --connect-timeout 1 --max-time 2 \
                    # 与 probe 层同一个坑：'*' 是绕过代理直连目标，语义正好相反；
                    # 而且不加 -p 时 curl 发的是普通 GET，任何回 200 的服务都会被当成代理。
                    --noproxy '' -p -x "http://127.0.0.1:$_sp_port" "http://127.0.0.1:9/" 2>/dev/null; then _sp_alive=1; fi
            fi
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
                    echo "更新状态 : 发现新版，打开菜单选 3（检查更新）即可升级"
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
HELP_TOPIC_KEYS=(1 2 3 4 5 6 7 8)
_help_topic_short() {
    case "$1" in
        1) echo "用处" ;;
        2) echo "装完" ;;
        3) echo "窗口" ;;
        4) echo "代理" ;;
        5) echo "命令" ;;
        6) echo "菜单" ;;
        7) echo "连不上" ;;
        8) echo "不行" ;;
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
        3) echo "这个窗口固定直连 / 恢复自动" ;;
        4) echo "这个窗口走公司代理" ;;
        5) echo "我要让某条命令不走代理" ;;
        6) echo "菜单每一项是干什么的" ;;
        7) echo "装了还是连不上网 / 状态不对" ;;
        8) echo "还是不行 / 想删掉它" ;;
        *) echo "" ;;
    esac
    return 0
}

# 帮助里「菜单每一项是干什么的」那一屏的正文，从 MENU_ITEMS 生成。
# 为什么生成而不是手抄：手抄的那一份在改菜单时会静默过期，症状是用户照帮助里的
# 编号去敲，敲到的是另一件事（想检查更新，结果卸载了）。生成之后这份内容与菜单
# 读同一张表，改表即同步，不存在"两边都要记得改"。
_help_menu_lines() {
    _hml_w=0
    # 键号列按最宽的键号补空格，而不是写死两个空格：以后键号多一位（比如到 10）
    # 就会全表错位，而"错位"这种事肉眼看得出、断言看不出来。
    _hml_kw=1
    for _hml_i in "${MENU_ITEMS[@]}"; do
        _hml_rest=${_hml_i#*|}
        _hml_name=${_hml_rest%%|*}
        _hml_nw=$(_menu_cell_width "$_hml_name")
        [ "$_hml_nw" -gt "$_hml_w" ] && _hml_w="$_hml_nw"
        _hml_k=${_hml_i%%|*}
        [ "${#_hml_k}" -gt "$_hml_kw" ] && _hml_kw="${#_hml_k}"
    done
    echo "这些编号要在主菜单里敲，不是在帮助里敲。"
    for _hml_g in $(_menu_group_order); do
        echo ""
        if [ "$_hml_g" = "日常" ]; then
            echo "$_hml_g（平时只会用到这些）"
        else
            echo "$_hml_g"
        fi
        for _hml_i in "${MENU_ITEMS[@]}"; do
            _hml_rest=${_hml_i#*|}
            _hml_name=${_hml_rest%%|*}
            _hml_rest2=${_hml_rest#*|}
            _hml_hint=${_hml_rest2%%|*}
            _hml_grp=${_hml_i%|*}; _hml_grp=${_hml_grp##*|}
            [ "$_hml_grp" != "$_hml_g" ] && continue
            _hml_key=${_hml_i%%|*}
            _hml_pad=$((_hml_kw - ${#_hml_key} + 2))
            _hml_kcell="$_hml_key$(printf '%*s' "$_hml_pad" '')"
            if [ -n "$_hml_hint" ]; then
                echo "  $_hml_kcell$(_menu_cell_pad "$_hml_name" "$_hml_w")  $_hml_hint"
            else
                echo "  $_hml_kcell$(_menu_cell_pad "$_hml_name" "$_hml_w")"
            fi
        done
    done
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
    3. 它确实连得通外面，试 7 个端点任意一个通就算。
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
     同步代码还没装进去。在那个窗口里敲一次对齐的那一条，或者重开窗口：

       zsh / bash       . ~/.envproxy/prompt-sync.sh

     开头的点号和后面的空格都不能少；fish 不支持。

为什么要按一次回车
  每个程序只在启动那一刻读一次环境变量，读完就固定了。之后系统改了，
  已经在跑的窗口不会跟着变。EnvProxy 挑的时机是每次命令跑完、
  等你回到能打字的状态时同步——你本来就一直在敲命令，不用专门做什么。
TOPIC
    ;;
    3) cat <<'TOPIC'
一、让这个窗口一直直连

  zsh / bash       export ENVPROXY_TERM=off

  敲完下一次回到提示符时生效。你自己设的值（比如公司代理）不会被删。
  fish 不支持：它不读这些配置文件，这个开关对它无效。

二、改回自动跟随

  zsh / bash       unset ENVPROXY_TERM

  上面两节都只对这个窗口有效，窗口一关就没了。
TOPIC
    ;;
    4) cat <<'TOPIC'
先做第 3 条（固定直连），再设地址。顺序反了等于没设。

一、设地址（换成公司给的）

  zsh / bash       export HTTPS_PROXY=http://你的地址:端口

二、看现在走不走代理（有值 = 走，空的 = 直连）

  zsh / bash       echo $HTTPS_PROXY

端口是你公司给的，问 IT 要（通常会给一份代理设置说明）。
注意：这里不是翻墙软件那个端口，别去那儿找。
你手设的值不会被删，只清和工具写入值相同的那些。
TOPIC
    ;;
    5) cat <<'TOPIC'
不同工具写法不一样，没有通用的一条命令

curl
      curl --noproxy '*' https://example.com

git
      git -c http.proxy= -c https.proxy= clone https://github.com/git/git.git
  等号后留空，这条就不用代理；写别的值，就改用那个代理。

npm
      npm --noproxy=registry.npmjs.org install typescript
  注意：只认具体网址，写 * 没用，而且不报错，请求照常走代理。
  写成 --no-proxy 会被理解成关闭代理，也不是你要的效果。
  另外 npm 只认 HTTPS_PROXY，不认 HTTP_PROXY。

wget
  Mac 不自带 wget，自己装过才用得上这一条：
      wget --no-proxy https://example.com

docker
  没有单条命令的写法，改 Docker 自己的设置（Settings 里的 Proxies）。
TOPIC
    ;;
    6) _help_menu_lines
    ;;
    7) cat <<'TOPIC'
连不上网，按这个顺序查
  1. 在那个窗口里看变量有没有值。终端输入：
       echo $HTTPS_PROXY
     空的就是没注入，重开一个窗口就好。

  2. 有值还是连不上：看菜单顶上「监控」是不是未运行。
     未运行就选 1（安装 / 修复）。

  3. npm 只认 HTTPS_PROXY，不认 HTTP_PROXY；你自己清过它就不走了。

状态页怎么读
  监控进程  后台程序在不在跑
  开机自启  下次登录会不会自动起来
  翻墙代理  本机有没有翻墙软件在监听端口
  终端同步  已经开着的窗口会不会跟着变
  代理变量  这个工具往终端里设代理了没有
  「翻墙代理」有、「代理变量」无 = 翻墙在跑、工具被你停了，不是坏了。
  其余几行是系统代理、版本号、更新状态。

日志和 AI 排查
  日志在 mac/monitor/monitor.log，反馈附最后 20 行。
  AI 报 ECONNREFUSED 127.0.0.1:端口号 = 变量指向了已关闭的端口，
  不是网络坏了。菜单选 2 看「代理变量」那行会直接说清。
  它只管 HTTP/HTTPS 变量；ping、游戏、BT 这类走自己协议的
  不认——那些要开翻墙软件的 TUN 模式。
TOPIC
    ;;
    8) cat <<'TOPIC'
大部分问题都可以用「安装 / 修复」解决
  打开菜单选 1。它不会重复安装，不会中断网络，也不会丢失你的设置。

还是不行
  菜单选 2 把状态截图，再选 1 修复一次。反馈时附上 mac/monitor/monitor.log
  最后 20 行，能省很多来回。

想彻底删掉它
  菜单选 6（一键恢复）。会问你要不要留日志。

不开菜单也能用（适合写脚本，或远程连过来）
  开关：install  status  stop  uninstall  update  help  menu  self-test
  --purge 连日志一起删，只配 uninstall 用。完整写法：
      bash envproxy.sh status
  self-test 是给排查问题用的：它在一个临时沙箱里跑一遍内部检查，
  不碰你的 ~/.zshrc 和环境变量，只报告「自检全部通过」或指出哪一项不对。
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
                *。*|*；*|*，*) echo ""; return 0;;
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
        # 判据与 Win 侧同形：这一行里没有任何中日韩字符，就是能整行复制去跑的命令。
        # 用 LC_ALL=C 把每个字节都当单字节看，再找"非可打印 ASCII"（[^ -~]）：
        # 中文字符的 UTF-8 字节全部落在 0x80 以上，必然命中，纯 ASCII 行一定不命中。
        # 不要用"列出允许字符的白名单"：grep -E 的方括号字符类里不支持 \x27 这类转义，
        # 写了会变成字面的 \ x 2 7 四个字符——于是含单引号的行（curl --noproxy '*'）
        # 被判成"不是命令"，屏幕上和普通说明文字同色，看起来像"只是在提 curl"。
        if ! LC_ALL=C printf '%s' "$_hlc_rest" | grep -q '[^ -~]'; then
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
    '0|退出|关掉这个窗口|退出|'
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
