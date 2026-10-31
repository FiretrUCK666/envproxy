# ==============================================================================
#  ops.sh — 编排层：安装、卸载、日常操作的编排
#  只做「按顺序调用别的层」这件事，自己不实现判定与渲染。
#
#  状态页与报告住在 pages 层，菜单、帮助与高级功能住在 help 层：
#  它们各有各的变更原因（安装流程因安全要求变、状态页因要说清而变化、
#  菜单帮助因文案变），混在一个文件里会让改一处时碰到另外两处。
# ==============================================================================

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
    # 判据走 base 层的 has_install_record（那条事实的唯一权威处），不在这里内联。
    if has_install_record; then _first=0; else _first=1; fi
    # 先快照用户原值：之后卸载时按它还原，覆盖前留底。
    # 成败要收下来：这份快照是**其它所有归属判据的输入**，记不下来的话，
    # 卸载时就还原不回用户的配置——那是安装时最该喊出来的一句话。
    _snapshot_ok=1
    if ! snapshot_prev_env "$_first"; then _snapshot_ok=0; fi
    style_out text "[1/4] 正在写开机自启……"
    # 四步里哪几步真的做成了，要一路记到函数末尾：入口靠这个退出码判断
    # 「这次安装到底成没成」，脚本里写 `envproxy.sh install && ...` 的人也靠它。
    # 原来这个函数无条件 return 0，于是"监控没起来""变量写不进去"这类
    # 明确的失败在退出码上是看不见的——用户只能靠肉眼读屏幕。
    _inst_ok=0
    if set_autorun; then
        style_out ok "[1/4] 开机自启动：已写入"
    else
        style_out warn "[1/4] 开机自启动：写入失败，请检查 ~/Library/LaunchAgents 是否可写"
        _inst_ok=1
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
        _inst_ok=1
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
        _inst_ok=1
    else
        # 读不出来 ≠ 没有代理：这一轮什么都没改，如实说明（与 Windows 侧同口径）。
        style_out warn "[3/4] 环境变量：这一轮没读到本机端口，所以没有改动任何设置（正常，会自动重试）。"
    fi
    # 快照没记下就要说出来：它决定"卸载时能不能还原你原来的配置"。
    # 不说的话，用户卸载后发现自己原来的公司代理没了，而安装时屏幕上一切正常。
    if [ "$_snapshot_ok" = "0" ]; then
        style_out warn "      没能记下你原来的代理设置（写入被拦住），卸载时可能还原不回来。"
        style_out warn "      如果原本自己设过代理，请先抄一份；再点一次菜单$(menu_ref install)重试。"
    fi
    style_out text "[4/4] 正在写终端配置……"
    if insert_shell_hooks; then
        style_out ok "[4/4] 终端同步：已在终端的启动配置里写入（zsh/bash，新开终端生效；fish 不支持）"
    else
        style_out warn "[4/4] 终端同步：写入失败，请检查 ~/.zshenv 是否可写"
        _inst_ok=1
    fi
    echo ""
    # 联网对比版本要一两秒：先说一声，别让最后这一步又变成静默等待。
    # 这里不联网：版本号取自监控写的缓存（状态页只读、永不联网）。见 Windows 侧同句。
    style_out text "正在看当前状态（版本号取自监控写的缓存，不联网）……"
    # 安装到了收尾这一步，就说明覆盖已经成功后落过、文件都是新的——
    # 那条「上次更新没有完成」的警报到此已经不再成立，必须撤掉。
    # 不撤的后果是死循环：状态页说「选 1 重做一次即可」，用户照做、
    # 覆盖也真的成功了，可标记还在，屏幕上是同一句警告——
    # 一条自己都说错了怎么修的指引，比不提示更糟。
    rm -f "$MONITOR_DIR/update.inprogress" 2>/dev/null || true
    show_status
    echo ""
    # 左边那一列按最长条目补齐，不靠手敲空格：改一个字就整列歪掉，
    # 而"歪一格"这种事只有人眼看得出来。与 Windows 侧同一套做法。
    # 有步骤没做成时不许说"装好了"——那是这台机器上最容易被当成"已经没事了"的一句话。
    if [ "$_inst_ok" = "0" ]; then
        style_out ok "装好了。之后怎么用："
    else
        style_out warn "装是装了，但有步骤没做成（见上面带「失败 / 未能」的那几行）。"
        style_out warn "先把它们解决掉，再点一次菜单$(menu_ref install)重跑；否则某些功能会时好时坏。"
        echo ""
        style_out dim "之后怎么用："
    fi
    # 每一行三格：左列标签（暗）/ 右列说明（正文色）/ 要照抄的命令（命令色）。
    # 整行一个颜色就没有层次：用户看不出哪一段能复制。命令单独列一格，
    # 而不是靠正则从整行里认——"在它里面执行  export ..." 开头不是命令，
    # 会被整行判成说明。与 Windows 侧同一套三格结构。
    _tip_a1="新开的终端 / 程序"
    _tip_a2="一直开着的窗口"
    _tip_a3="装之前就开着的窗口"
    _tip_a4="想让某个窗口不翻墙"
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
        _tr_c=$(style_color cmd)
        printf '\033[%sm   %s   \033[0m%s' "$_tr_dim" "$_tr_left" "$_tr_note"
        if [ -n "$_tr_cmdline" ]; then printf '  \033[%sm%s\033[0m\n' "$_tr_c" "$_tr_cmdline"; else printf '\n'; fi
    }
    _tip_row "$_tip_a1" "自动就是对的，什么都不用做。" ""
    _tip_row "$_tip_a2" "敲一下回车就跟上。" ""
    _tip_row "$_tip_a3" "重开一个，或者手动加载一次" ""
    _tip_row "" "菜单$(menu_ref help)第 2 条，有现成命令。" ""
    _tip_row "$_tip_a4" "在它里面执行" "export ENVPROXY_TERM=off"
    _tip_row "$_tip_a5" "在它里面执行" "unset ENVPROXY_TERM"
    _tip_row "$_tip_a6" "菜单$(menu_ref help)。" ""
    # 退出码如实反映这次安装成没成：入口靠它，脚本里 `install && ...` 也靠它。
    # 不能像原来那样靠"最后一条命令"隐式决定——最后一条是 printf，永远是 0，
    # 于是这条路上的每一次失败在退出码上都等于成功。
    return "$_inst_ok"
}

# 卸载时要清掉的运行时文件清单——**删除与复检的唯一来源**。
#
# 为什么要抽出来：这两件事原来各写一份，删除列了 7 个、复检一个都没查。
# 删失败（权限、被占用、杀软锁住）时仍然报"[完成] 已恢复到安装前的状态"，
# 而重装后状态页会读到上一份留下的 version.cache / state.snapshot。
# 同一份清单只有一处，就不会再出现"删了忘了查"。
# 与 Windows 侧 ops.ps1 卸载分支同一套文件（那边逐项 Remove-Item）。
monitor_runtime_files() {
    # doctor.bak 也在这里：它是网络救援动手前留下的原样，卸载之后没有任何组件会再用它。
    # 漏掉的后果不是"多留一个文件"——它记着使用者当时的系统代理设置，留着就是留了份
    # 没人管理、也没人知道该不该删的配置副本。
    printf '%s\n' "$PID_FILE" "$STOP_FLAG" "$STOP_INTENT" \
        "$VERSION_CACHE" "$SNAPSHOT_FILE" \
        "$MONITOR_DIR/update.inprogress" "$MONITOR_DIR/notify.last" \
        "$MONITOR_DIR/doctor.bak"
}

uninstall_envproxy() {
    _purge="$1"
    _un_yes="${2:-}"
    style_out title "======== EnvProxy 卸载（一键恢复原状）========"
    if [ "$(id -u 2>/dev/null)" = "0" ]; then echo "当前是 root 身份：接下来改的会是 root 这个账号的配置。日常使用请用普通终端重来一次。"; fi
    # 先问一句再动手。这是整个工具里**唯一不可逆**的动作：会删开机自启、摘终端配置、
    # 清掉代理变量。而它在菜单里紧挨着「6 停止监控」（那个是可逆的）。
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
        style_out dim "  真的要卸载，请双击 打开菜单.command $(menu_ref uninstall)；"
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
        # 卸载 = 恢复成没装过：所有运行时状态都不该活过它，唯一保留的是黑匣子日志。
        # 漏掉任何一个的后果都很具体：version.cache 会让重装后的状态页显示上一次的版本号；
        # update.inprogress 会被读成"上次更新没完成"（那是上一次安装的经历）；
        # 强杀留下的 .lock 空目录会让新监控的 mkdir 失败、多绕一圈接管分支。
        # 状态快照不删的后果与 version.cache 一字不差：重装后状态页会读到上一份
        # 安装留下的结论，而那是已经不存在的状态。
        # notify.last 也必须删：它记的是"上次提示过代理变了"。
        # 留着它，重装后第一次真实的端口变化会被上一份安装留下的值吃掉——
        # 使用者换了端口却什么提示都没有，而那些程序正连着旧地址。
        # Windows 侧同一位置也删它（ops.ps1 卸载分支），两侧行为必须一致。
        # 运行时文件清单从这里取，删除与复检**共用同一份**。
        # 原来删除列了 7 个、复检一个都没查：删失败（权限、被占用、杀软锁住）时
        # 仍然报"[完成] 电脑已恢复到安装前的状态"，而重装后状态页会读到上一份的
        # version.cache / state.snapshot——正是上面那段注释自己点名的后果，只是没人验。
        # 按行读、逐个删，不用 `rm -f $(monitor_runtime_files)`：
        # 后者靠**词拆分**把清单拆成参数，而安装路径里完全可能有空格（"我的 工具"），
        # 于是一个文件被拆成两段、两段都不存在，rm -f 静默成功——卸载看着完成，文件还在。
        # monitor_runtime_files 本来就是按行输出的（printf '%s\n'），这里就该按行消费。
        monitor_runtime_files 2>/dev/null | while IFS= read -r _urf; do
            [ -n "$_urf" ] && rm -f "$_urf" 2>/dev/null
        done || true
        rmdir "$MONITOR_DIR/.lock" 2>/dev/null || true
        if [ -d "$MONITOR_DIR" ] && [ -z "$(ls -A "$MONITOR_DIR" 2>/dev/null)" ]; then
            rmdir "$MONITOR_DIR" 2>/dev/null || true
        fi
    fi
    _ghost=$(get_monitor_pid || true)
    if [ -n "$_ghost" ]; then kill -9 "$_ghost" 2>/dev/null || true; sleep 0.5; fi
    # Mac 侧写变量无 Win 式进程内写锁：靠前面先停监控把竞态窗口收到最小（单实例文件锁另保安装互斥）。
    remove_user_env_vars
    # 按安装时的快照还用户原值（若有），还完删掉快照。
    # 成败要收下来：还原没写成时**不能**照常往下清账（下面会 rm 掉 prev.env），
    # 否则用户原值和唯一副本一起消失，而卸载还提示他"手动删"——
    # 数据已经丢了，处置建议却指向"再删一次"。这种情况停下来，让用户先手动处理。
    if ! restore_prev_env; then
        style_out warn "[未完成] 你原来的代理设置没能写回去（可能被安全软件或权限拦住了）。"
        style_out warn "        备份还留着（$PREV_ENV），没有再删任何东西。"
        style_out warn "        请先手动把原来的设置加回去，再点一次菜单$(menu_ref uninstall)收尾。"
        return 1
    fi
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
    # 运行时文件逐个查：删除清单与这里**同源**（monitor_runtime_files）。
    # 只加一处清单、不在这里重列：重列就会再次出现"删了忘了查"。
    while IFS= read -r _rf; do
        [ -z "$_rf" ] && continue
        if [ -f "$_rf" ]; then _dirty="$_dirty 运行时文件仍在（$_rf）；"; fi
    done <<EOF_RUNTIME_FILES
$(monitor_runtime_files)
EOF_RUNTIME_FILES
    if [ -f "$OWNED_ENV" ]; then _dirty="$_dirty 归属记录仍在（$OWNED_ENV）；"; fi
    if [ -f "$PATH_CONF" ]; then _dirty="$_dirty 路径记录仍在（$PATH_CONF）；"; fi
    if [ -f "$ENVPROXY_HOME/monitor.stdout.log" ] || [ -f "$ENVPROXY_HOME/monitor.stderr.log" ]; then _dirty="$_dirty 自启动重定向残留；"; fi
    # hook 名单与 remove_shell_hooks 同一份（改一边必须改另一边）：残留整块即脏。
    # 按行读而不是 `for x in $(...)`：后者靠词拆分，路径含空格就会被拆坏。
    # 用 here-doc 而不是管道：管道会起子 shell，里面改的 _dirty 传不回来。
    while IFS= read -r _rc; do
        [ -n "$_rc" ] || continue
        if _hook_marker_present "$_rc" "$HOOK_START"; then _dirty="$_dirty 终端同步的配置块还在（$_rc）；"; break; fi
    done <<EOF
$(rc_check_files)
EOF
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
        # 退出码必须跟着结论走：只打印"[未完成]"而返回 0，
        # 脚本里的 `envproxy.sh uninstall && 认为已卸干净` 就成立——屏幕上说没清完、
        # 退出码说成功了，两个信号互相矛盾，调用方只会信后者。
        return 1
    fi
}

# 单个地址上试一次 TCP 连接，只回答"这个端口还在不在"。
# 状态页用它判两件事：注入的代理变量指向的端口、系统代理指向的端口。
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
    if curl_direct --disable -s -o /dev/null --connect-timeout 1 --max-time 2 \
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
    # 优先读监控写下的结论快照，读不到或太旧才自己现场探测。
    #
    # 为什么不一律现场探测：最坏情况（代理刚换端口、变量指向的旧端口已死）要走
    # 全端口扫描，而监控每 2–3 秒就在做同一件事、结论它早就有了。
    # 读快照是个位数毫秒，且两边结论同源——不会再出现"状态页说没代理、监控还在用某个端口"
    # 这种自相矛盾。这与 Windows 侧读 state.snapshot 是同一套做法，两端终于同形。
    #
    # 降级由 read_state_snapshot 的 SNAP_STATUS 表达：ok 用快照；
    # none / unreadable / damaged / 太旧 退回实时探测。任何情况下都不许把
    # "读不出来"当成"没有代理"——那会删掉用户的变量，方向与保留相反。
    read_state_snapshot
    _snap_ok=0
    if [ "$SNAP_STATUS" = "ok" ]; then
        # 时间戳比现在晚 60 秒以上 = 系统时间被调过，不许当"刚写的"
        if [ "$SNAP_AGE" -lt -60 ]; then
            _snap_ok=0
        elif [ "$SNAP_AGE" -le "$SNAPSHOT_STALE_SEC" ]; then
            _snap_ok=1
        fi
    fi
    if [ "$_snap_ok" = "1" ]; then
        case "$SNAP_STATE" in
            on:*) _port="${SNAP_STATE#on:}" ;;
            *)    _port="" ;;
        esac
        if [ "$SNAP_PORT_ENUMERATION" = "failed" ]; then _port_unknown=1; fi
    else
        # 三态直接由返回码给出（0 找到 / 1 确实没有 / 2 读不出来），**不要再问一次枚举层**。
        # 曾经是"拿到 1 之后再调一次 find_candidate_ports 去分辨"，而那个函数内部
        # 本身就是一次全端口 lsof+ps+CONNECT——于是没有代理的机器上，每 2 秒刷新的
        # 状态页要跑两轮全扫。三态在源头分开，这里一次即可。
        # 注入的端口由这里读好再传进去：probe 层只管探测，不该反过来调 env 层的读值函数
        # （那会让 probe 依赖 env、env 又依赖 probe 的端口函数，形成环）。
        _p=$(get_in_use_proxy_port "$(get_current_proxy_port 2>/dev/null || echo "")")
        _p_rc=$?
        case "$_p_rc" in
            0) _port="$_p" ;;
            1) _port=""; _port_unknown=0 ;;   # 枚举成功、确实没有代理：dim「未检测到」
            *) _port=""; _port_unknown=1 ;;   # 枚举失败：warn「没读到，无法判断」
        esac
    fi

    # 终端同步到底有没有在生效。光看「块写进去了」不算数：块不成对同样能让
    # 「看起来装好了，实则每次开窗口都不同步」。与 Win 侧 Get-TerminalSyncState 同语义。
    _ts_state="missing"
    _ts_hits=0
    _ts_unpaired=0
    _ts_stale=0
    _ts_badline=""
    # 按行读而不是 for-in-$( )：后者靠词拆分，路径含空格会被拆坏。
    while IFS= read -r _ts_p; do
        [ -n "$_ts_p" ] || continue
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
    done <<EOF
$(rc_check_files)
EOF
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
    # 若它指向本机死端口，浏览器全挂而终端正常——提醒一句，绝不动它
    # （动它是「网络救援」的活）。
    #
    # 判据**只有一处实现**：doctor 层的 sysproxy_layers + sysproxy_verdict。
    # 这里原来是第三套实现（scutil --proxy 读全局，只认 127.0.0.1），
    # 而 mac 的系统代理是**每个网络服务各存一份**，scutil 只报当前生效的那一份——
    # 公司 VPN 上残留、Wi-Fi 上干净的情况它完全看不见。
    # quick 只查手动代理两层：状态页每次刷新都调它，全量档会拖慢刷新。
    _sp_bad=0
    _sp_first_url=""
    _sp_first_kind=""
    _sp_count=0
    while IFS="$(printf '\t')" read -r _sp_layer _sp_svc _sp_kind _sp_url _sp_port; do
        [ -n "$_sp_svc" ] || continue
        if sysproxy_fixable "$_sp_kind"; then
            _sp_count=$((_sp_count + 1))
            if [ -z "$_sp_first_kind" ]; then
                _sp_first_url="$_sp_url"
                _sp_first_kind="$_sp_kind"
            fi
        fi
    done <<EOF
$(sysproxy_layers quick)
EOF
    [ "$_sp_count" -gt 0 ] && _sp_bad=1

    # 版本信息（只读：查不到只提示，不写文件、不提问）
    _local_ver=$(get_local_version || true)
    return 0
}
