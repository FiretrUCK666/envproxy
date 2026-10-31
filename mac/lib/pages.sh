# ==============================================================================
#  pages.sh — 状态页层：把「现在什么情况」渲染成人能读的几行
#  **永不联网、永不写文件、永不提问**：版本号读监控写下的缓存，缓存旧了就如实说
#  「几小时前的记录」，缓存没有就说清「没法确认」并指向更新入口。
#
#  两份渲染器（实时帧 format_status_lines 与静态页 show_status）必须同源：
#  同一份快照、同一套问题清单。内容一旦不一致，自检里有断言比对。
# ==============================================================================


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

# 生成一份可以直接发给别人看的问题报告。
#
# 为什么要它：以前反馈唯一的办法是"自己找到日志文件、打开、复制、再贴到 GitHub"。
# 不会用 GitHub、不会敲命令的人卡在第一步就放弃了。这里把整件事压成一个按键：
# 收集 → 存成单个文件 → 路径直接进剪贴板 → 屏幕上说清下一步做什么。
#
# 边界：只读、不联网、不改任何配置。文件落在 monitor/ 下，卸载时会一起清掉。
# 反馈时要问的四个问题。顺序即重要性：先定"哪个环节坏了"，作者才知道该看哪一段；
# 再问"你看到什么"，那是最能定位症状的一条；最后问"你本来想做什么"，
# 因为同一现象在不同意图下是完全不同的问题。
# 问题写成大白话：使用者不是工程师，问"请描述复现步骤"只会得到一句"就是不好使"。
REPORT_Q1="哪一步出的问题？"
REPORT_Q1_EG="比如：装完之后终端里还是上不了网 / 换了个新的翻墙软件 / 升级之后就这样了"
REPORT_Q2="屏幕上显示了什么？"
REPORT_Q2_EG="比如：状态页说未运行 / 命令报 ECONNREFUSED 127.0.0.1:7890 / 没反应"
REPORT_Q3="你本来希望它做什么？"
REPORT_Q3_EG="比如：希望 git clone 能直接通 / 希望它自己跟着翻墙软件开关"
REPORT_Q4="还有什么想补充的？"

# 问一个问题，回车跳过。跳过时报告里写"（没填）"而不是留白——
# 留白会被读成"这一项不适用"，而"没填"才是真的信息（作者据此知道还得追问）。
# 第三参数非空表示这一问是自由补充：提示语换成"想写什么都行"，
# 因为自由的题目再给例子反而限制住人。
read_report_answer() {
    _rra_prompt="$1"
    _rra_eg="$2"
    _rra_free="${3:-}"
    echo "" >&2
    printf "  %s\n" "$_rra_prompt" >&2
    echo "" >&2
    if [ -n "$_rra_free" ]; then
        printf "    想写什么都行，一段话也行。\n" >&2
    elif [ -n "$_rra_eg" ]; then
        printf "    %s\n" "$_rra_eg" >&2
    fi
    printf "    （不想写就直接回车）\n" >&2
    printf "  > " >&2
    _rra_ans=""
    IFS= read -r _rra_ans || true
    printf "%s" "$_rra_ans"
}


new_problem_report() {
    _npr_stamp=$(date '+%Y%m%d-%H%M%S')
    _npr_name="report-$_npr_stamp.txt"
    mkdir -p "$MONITOR_DIR" 2>/dev/null || true
    _npr_target="$MONITOR_DIR/$_npr_name"

    # 先问清楚"你遇到的是什么问题"，再收集环境。
    # 顺序不能反：只把环境收齐、却不问症状，作者拿到的是一份"这台机器当时长什么样"，
    # 而不是"哪里坏了"——三十行状态值一条也用不上，还得反问用户。
    echo ""
    printf "======== 问题反馈 ========\n"
    echo ""
    printf "  下面问你四句话，一句话一行，随手写就行。\n"
    printf "  写完会自动补上这台机器的情况，然后生成一份可以贴到网页上的报告。\n"
    _npr_a1=$(read_report_answer "$REPORT_Q1" "$REPORT_Q1_EG")
    _npr_a2=$(read_report_answer "$REPORT_Q2" "$REPORT_Q2_EG")
    _npr_a3=$(read_report_answer "$REPORT_Q3" "$REPORT_Q3_EG")
    _npr_a4=$(read_report_answer "$REPORT_Q4" "" "free")
    if [ -z "$_npr_a1" ] && [ -z "$_npr_a2" ] && [ -z "$_npr_a3" ] && [ -z "$_npr_a4" ]; then
        echo ""
        printf "  四句都空着。这样的报告发出去，对方只能反问你要细节。\n"
        printf "  还是要生成吗？(y/N) "
        _npr_go=""
        IFS= read -r _npr_go || true
        case "$_npr_go" in
            [Yy]*) : ;;
            *) printf "  已取消，什么都没做。\n"; return 0 ;;
        esac
    fi

    # 报告正文先拼进一个变量，再**原样**写到落点。
    # 不写成"两处各 echo 一遍"：那样两处内容必然漂移，兜底那份会缺版本号与路径——
    # 而那两个正是排查最需要的。Windows 侧也是"同一份文本写两次"。
    _npr_body=$(
        echo "======== EnvProxy 问题报告 ========"
        echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
        _npr_ver=$(get_local_version 2>/dev/null)
        [ -z "$_npr_ver" ] && _npr_ver="未知"
        echo "程序版本：v$_npr_ver"
        echo "系统：$(uname -srm 2>/dev/null)"
        echo "Shell：${SHELL:-未知}    bash：${BASH_VERSION:-未知}"
        # 使用者自己写的那一段放在最前面：报告是给人读的，作者第一眼该看到"哪里坏了"，
        # 而不是先读三十行环境值才在末尾找到一句"不好使"。
        echo ""
        echo "---------------- 你遇到的问题 ----------------"
        printf "  %s\n" "$REPORT_Q1"
        if [ -n "$_npr_a1" ]; then printf "    %s\n" "$_npr_a1"; else printf "    （没填）\n"; fi
        echo ""
        printf "  %s\n" "$REPORT_Q2"
        if [ -n "$_npr_a2" ]; then printf "    %s\n" "$_npr_a2"; else printf "    （没填）\n"; fi
        echo ""
        printf "  %s\n" "$REPORT_Q3"
        if [ -n "$_npr_a3" ]; then printf "    %s\n" "$_npr_a3"; else printf "    （没填）\n"; fi
        echo ""
        printf "  %s\n" "$REPORT_Q4"
        if [ -n "$_npr_a4" ]; then printf "    %s\n" "$_npr_a4"; else printf "    （没填）\n"; fi
        echo ""
        echo "---------------- 当前状态 ----------------"
        # 用纯文本渲染：报告是给文件看的，不能带颜色控制字符。
        show_status 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
        echo ""
        echo "---------------- 运行日志（最后 30 行） ----------------"
        if [ -f "$LOG_FILE" ]; then
            tail -n 30 "$LOG_FILE" 2>/dev/null | sed 's/^/  /'
        else
            echo "  （还没有日志：这个工具可能从未运行过）"
        fi
        echo ""
        echo "---------------- 位置 ----------------"
        echo "  程序目录：$SCRIPT_DIR"
        echo "  运行状态目录：$MONITOR_DIR"
        echo ""
        # 项目地址跟着正文一起写进去：报告可能隔几天才发，那时不一定还记得地址在哪。
        # 地址只有一处来源（get_project_home / get_project_issues），不许在这里手写第二份。
        echo "---------------- 发到哪里 ----------------"
        echo "  提问题：$(get_project_issues 2>/dev/null || true)"
        echo "  项目主页：$(get_project_home 2>/dev/null || true)"
        echo ""
        echo "=================================="
        echo "这份报告含本机路径与端口。代理地址里的账号密码已经隐去。"
        echo "发给别人前可以先自己打开看一眼。"
    )

    # 脱敏在**唯一汇聚点**：状态页必须如实显示代理地址（那是它的职责），
    # 而报告是准备发给别人的。带认证的代理（http://user:pass@host:port）
    # 原样落盘就是把明文密码写进一个"准备发出去"的文件。
    _npr_body=$(printf '%s\n' "$_npr_body" | sed 's#://[^/@[:space:]]*@#://***@#g')

    printf '%s\n' "$_npr_body" > "$_npr_target" 2>/dev/null

    # monitor/ 写不进去时退到临时目录：报告不能因为路径问题就生成不出来。
    # 内容与上面完全一致，只是换个落点。
    if [ ! -s "$_npr_target" ]; then
        _npr_target="${TMPDIR:-/tmp}/$_npr_name"
        printf '%s\n' "$_npr_body" > "$_npr_target" 2>/dev/null
    fi

    if [ ! -s "$_npr_target" ]; then
        _npr_target="${TMPDIR:-/tmp}/$_npr_name"
        {
            echo "======== EnvProxy 问题报告 ========"
            echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
            show_status 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
            echo ""
            echo "---------------- 运行日志 ----------------"
            [ -f "$LOG_FILE" ] && tail -n 30 "$LOG_FILE" 2>/dev/null
        } > "$_npr_target" 2>/dev/null
    fi

    echo ""
    if [ ! -s "$_npr_target" ]; then
        echo "报告生成失败：两个位置都写不进去。" >&2
        echo "  可以先把菜单$(menu_ref status)的截图发给对方。" >&2
        return 1
    fi

    style_out title "======== 报告已生成 ========"
    echo ""
    echo "  报告文件："
    style_out value "  $_npr_target"
    echo ""
    # 剪贴板：macOS 自带 pbcopy。不保证有（极精简环境），失败就只打印路径。
    if command -v pbcopy >/dev/null 2>&1 && printf '%s' "$_npr_target" | pbcopy 2>/dev/null; then
        echo "  这个路径已经复制到剪贴板了，可以直接粘到聊天窗口里。"
    else
        echo "  （这个环境没有剪贴板，请手动把上面那个路径复制下来）"
    fi
    echo ""
    style_out heading "  接下来怎么发出去"
    echo "    把这个地址打开，新建一个 issue，把报告内容贴进去："
    echo "      $(get_project_issues 2>/dev/null || true)"
    echo "  这是本项目唯一收问题的地方。"
    echo ""
    echo "  按回车回到菜单"
    read -r _npr_pause 2>/dev/null || true
    return 0
}

# 状态页的纯文本帧（不带颜色控制字符）：给实时刷新与报告用。
# 与 show_status 同一份内容，只是这里产出字符串而不是直接打印——
# 屏幕渲染层要按行比较，所以必须先拿到"这一帧是什么"。
format_status_lines() {
    _fsl_out=$(show_status 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
    printf '%s' "$_fsl_out"
}

# 实时状态页：进屏幕、自己刷新、按 0/q/Esc 退出。
# 画不了屏（重定向 / 无终端 / 窗口太小）时退回一次性静态输出。
show_status_live() {
    # 底部要留一行放操作提示（下面 _ssl_frame 末尾追加），所以行数预算 +1。
    # 提示只能写真正支持的键——写了却没人处理的键，用户按下去毫无反应，
    # 会以为程序卡住了。这里三个键 wait_screen_key 都认。
    _ssl_hint='正在实时刷新 · 按 0 或 Esc 返回'
    _ssl_frame=$(format_status_lines)
    _ssl_frame="$_ssl_frame
$_ssl_hint"
    _ssl_need=$(printf '%s\n' "$_ssl_frame" | grep -c '' || echo 0)
    _ssl_width=0
    while IFS= read -r _ssl_l; do
        _ssl_w=$(_display_width "$_ssl_l")
        [ "$_ssl_w" -gt "$_ssl_width" ] && _ssl_width="$_ssl_w"
    done <<EOF
$_ssl_frame
EOF

    if ! test_can_draw_screen "$_ssl_need" "$_ssl_width"; then
        # 降级：退回一次性输出，与今天的行为一致
        show_status
        return 0
    fi
    enter_screen || { show_status; return 0; }

    _ssl_prev=""
    _ssl_next=0
    monotonic_now; _ssl_now=$MONO_NOW
    # Ctrl+C 也要恢复光标：不恢复的话用户下次看到的是一台"没有光标"的终端。
    trap 'exit_screen; trap - INT; return 130' INT
    while :; do
        monotonic_now; _ssl_now=$MONO_NOW
        if [ "$_ssl_now" -ge "$_ssl_next" ]; then
            # 渲染失败就保留上一帧：状态页是"看一眼"用的，不该被一帧失败踢出去。
            # 与 Windows 侧同一处理（那边两个调用各包一层 try）。
            _ssl_new=$(format_status_lines 2>/dev/null)
            # 提示行每一帧都要重新接上：它不属于状态内容（format_status_lines 不产出它），
            # 只接在首帧的话，刷一次就消失了。
            [ -n "$_ssl_new" ] && _ssl_frame="$_ssl_new
$_ssl_hint"
            _ssl_need=$(printf '%s\n' "$_ssl_frame" | grep -c '' || echo 0)
            _ssl_width=0
            while IFS= read -r _ssl_l; do
                _ssl_w=$(_display_width "$_ssl_l")
                [ "$_ssl_w" -gt "$_ssl_width" ] && _ssl_width="$_ssl_w"
            done <<EOF
$_ssl_frame
EOF
            if test_can_draw_screen "$_ssl_need" "$_ssl_width"; then
                write_screen_frame "$_ssl_prev" "$_ssl_frame"
                _ssl_prev="$_ssl_frame"
            else
                # 画不了（窗口太小）：作废记账，等窗口恢复时必然整帧重画
                _ssl_prev=""
            fi
            _ssl_next=$((_ssl_now + STATUS_REFRESH_SEC))
        fi
        # DIVERGE(Mac): read -t 只认整数秒，所以这里是 1 秒一轮。
        _ssl_k=$(wait_screen_key "$SCREEN_POLL_SEC")
        case "$_ssl_k" in
            Quit) break ;;
        esac
    done
    trap - INT
    exit_screen
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
    # 与安装侧同一个判据（base 层 has_install_record）：内联一份就是第二个真相。
    if has_install_record; then _never_installed=0; else _never_installed=1; fi
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
    # 监控每轮都算"变量与状态对不对得上""写进去了没有"，但这里从来没读过它。
    # 结果是：变量被别的程序改坏、或写入失败时，状态页仍然说"一切正常"，
    # 而终端其实连不上。与 Windows 侧同一套判据、同一句措辞。
    # 空串（老版本写的快照没有这两个字段）按"不报"处理，不许当成"有问题"。
    if [ "$_snap_ok" = "1" ]; then
        [ "$SNAP_VARS_MATCH" = "no" ] && _pb="$_pb代理变量和当前状态对不上（可能被别的程序改了）
"
        [ "$SNAP_APPLY_RESULT" = "failed" ] && _pb="$_pb代理变量写不进去（下一轮还会再试）
"
# 代理在跑、端口也活着，但它连不出去——多半是节点问题，不是设置坏了。
# 只在**拿到握手证据**时才说（空 = 不知道），否则就是凭猜给用户指方向。
[ "${SNAP_NODE_HANDSHAKE:-}" = "upstream-fail" ] && _pb="$_pb代理在跑，但它连不上外面（多半是节点问题，换个节点试试）
"
    fi
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
    # 标题下空一行：标题在给下面的内容起头，结论立刻顶着标题读起来很闷。
    # 与帮助页同一套规矩（标题上下各空一行），与 Windows 侧状态页同形。
    echo ""
    if [ "$_pn" = "0" ]; then
        style_out ok "一切正常，不用做任何事。"
    elif [ "$_never_installed" = "1" ]; then
        # 从没装过：几件"没生效"都是同一个事实（还没装），
        # 说成"有 N 项要注意"会让第一次打开的人以为机器有好几处毛病。
        style_out dim "还没开始用。打开菜单$(menu_ref install)就能装上。"
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
                style_out dim "  （你点过停止。下次登录会自动恢复，或现在$(menu_ref install)）"
            else
                style_out warn "  （你点过停止，但开机自启记录也坏了，下次登录不会自动恢复）"
                style_out dim "  打开菜单$(menu_ref install)可以一起修好。"
            fi
        elif [ "$_never_installed" = "1" ]; then
            # 从没装过：这不是问题，是起点。用"崩溃/被强制退出"描述它，
            # 第一次打开的人会以为自己的机器出了事（"我明明没装过"）。
            style_out dim "  （还没装过。装上之后它会自己常驻，不用你管）"
            style_out dim "  打开菜单$(menu_ref install)开始使用。"
        else
            style_out warn "  （不是点了停止，是进程不在了：可能被强制退出，或崩溃）"
            style_out dim "  打开菜单$(menu_ref install)可以让它重新跑起来。"
        fi
    fi
    if [ "$_autorun_ok" = "0" ]; then
        if [ "$_autorun_reg" = "1" ]; then
            _status_row "开机自启" "记录还在，但启动文件已不存在（登录时不会启动）" warn
            style_out dim "  记录指向：$LOCATOR_PATH"
            style_out dim "  打开菜单$(menu_ref install)可以重建。"
        elif [ -f "$PLIST_PATH" ]; then
            _status_row "开机自启" "已写入但未加载" warn
            style_out dim "  打开菜单$(menu_ref install)可以重建。"
        else
            _status_row "开机自启" "未启用" warn
            style_out dim "  打开菜单$(menu_ref install)可以启用。"
        fi
    fi
    if [ -n "$_cur" ] && [ -z "$_cur_alive" ]; then
        _status_row "代理变量" "值不是合法地址（$_cur）" warn
        style_out dim "  多半是别的工具改写成了半个地址。$(menu_ref install)会按当前代理重写一遍。"
    elif [ -n "$_cur" ] && [ "$_cur_alive" = "0" ]; then
        _status_row "代理变量" "指向的端口已不在（$_cur）" warn
        style_out warn "  终端里联网会报 ECONNREFUSED，错误里没有本工具的名字，所以你会去查网络。"
        # 这一屏最容易被读成"工具坏了"：翻墙代理明明是开着的，代理变量却说端口不在。
        # 实情是**它俩指向的不是同一个端口**——换了端口、变量还停在旧的那个上。
        # _cur_port 是**变量里**那个端口，$_port 是**当前翻墙代理**的端口。
        # 两个都摆出来，用户一眼看懂差在哪；只讲道理他还要自己比。
        if [ -n "$_cur_port" ] && [ -n "$_port" ] && [ "$_cur_port" != "$_port" ]; then
            # 代理在别的端口上活着：跟着它走就对了
            style_out dim "  变量里是旧端口 $_cur_port，翻墙代理现在在 $_port。"
            style_out dim "  监控在跑的话几秒内会自己跟过去；想立刻跟上就$(menu_ref install)。"
        elif [ -z "$_port" ]; then
            # 代理根本没在跑：没有可跟的目标，那就是该清掉
            style_out dim "  翻墙代理现在没在跑，所以这个地址已经没用了。"
            style_out dim "  监控在跑的话几秒内会把它清掉；想立刻清掉就$(menu_ref install)。"
        else
            # 端口解析不出来（极少见），只给通用说法，不编具体原因
            style_out dim "  这个地址已经连不上了（多半是刚换过端口）。"
            style_out dim "  监控在跑的话几秒内会自己跟上；想立刻跟上就$(menu_ref install)。"
        fi
    elif [ -n "$_cur" ] && [ -z "$_m" ]; then
        _status_row "代理变量" "已注入（$_cur），但没人维护" warn
        style_out dim "  翻墙软件断开后不会自动清掉，终端会连不上。"
        style_out dim "  打开$(menu_ref install)恢复监控；或$(menu_ref uninstall)，把这批变量一并清掉。"
    elif [ -z "$_cur" ] && [ -n "$_port" ] && [ -z "$_m" ]; then
        # "翻墙代理有" + "代理变量无" 单独看像自相矛盾。实话是：软件在跑，
        # 但本工具没在它上面工作（多半是使用者自己停的）。补一句桥接，否则会被判定"坏了"。
        # 与 Windows 侧同一句、同一判据。
        _status_row "代理变量" "无（翻墙软件在跑，但本工具已停用，所以没往终端里设代理）" dim
    fi
    case "$_ts_state" in
        # 正常态什么都不说：它由下面"参考信息"那一段单独打一行绿的。
        # 这个 case 只管"有问题的几种"，漏掉 ok 会让最正常的状态落进 *、
        # 于是每个装对了的人都会看到"状态未知（ok）"——比不报还糟。
        ok) : ;;
        unpaired)
            _status_row "终端同步" "配置文件里的标记不成对，未改动它" warn
            if [ -n "$_ts_badline" ]; then
                style_out dim "  删掉配置文件里孤立的那行标记（第 $_ts_badline 行）再$(menu_ref install)。"
            else
                style_out dim "  删掉配置文件里孤立的 EnvProxy 标记行再$(menu_ref install)。"
            fi ;;
        stale)
            _status_row "终端同步" "同步块是旧版本的" warn
            # 内容过期不是用户的问题，也不用手工改：安装会按当前版本重写。
            style_out dim "  这不影响用，只是那段代码旧了；打开$(menu_ref install)会更新它。" ;;
        missing)
            _status_row "终端同步" "配置文件里没有同步块" warn
            style_out dim "  打开$(menu_ref install)可以写入。" ;;
        *)
            # 走到这里说明判定端又加了新状态而这里没跟上。静默跳过不行：
            # 上面的问题清单会说"终端同步没生效"，而往下整屏找不到"终端同步"
            # 四个字——用户被指向一个不存在的提示。Windows 侧真发生过一次
            # （State 叫 nohost、switch 处理的是 unknown，恰好错位）。
            _status_row "终端同步" "状态未知（$_ts_state）" warn
            style_out dim "  打开菜单$(menu_ref install)重写一次。" ;;
    esac
    if [ "$_upd_prog" = "1" ]; then
        _status_row "上次更新" "没有完成（覆盖过程中断）" warn
        style_out dim "  程序文件可能新旧混合，某些功能会静默失效。"
        style_out dim "  打开菜单$(menu_ref install)重做一次即可。"
    fi
    if [ "$_sp_bad" = "1" ]; then
        # 两种残留的症状真的不同，不能混成一句：
        #   manual 手动代理指向死端口 —— 浏览器打不开任何网页（真断网）
        #   pac    设置脚本指向死端口 —— 能上网，但每次开网页先卡几秒
        # 措辞与 Windows 侧逐字相同（两平台同一件事必须同一句话）。
        if [ "$_sp_first_kind" = "$SYSPROXY_KIND_SLOWING" ]; then
            _sp_text="有个设置脚本指向已经关掉的程序（网页能开，但每次要等几秒）"
        else
            _sp_text="指向本机一个已经关掉的程序（浏览器会打不开网页）"
        fi
        _status_row "系统代理" "${_sp_text}。不是本工具写的。" warn
        style_out dim "  这一项可以自己修：菜单$(menu_ref advanced)，再选网络救援。"
    fi
    [ "$_pn" != "0" ] && echo ""

    # ---- 参考信息：正常项 ----
    # 分组之间空一行（与 Windows 侧同一套）：八行数据紧贴在一起的观感是"一坨字"，
    # 眼睛找不到落点。分三组——进程与自启（后台在不在）、代理与变量（链路通不通）、
    # 终端同步（已开的窗口跟不跟得上）。组内紧凑、组间留白。
    [ -n "$_m" ] && _status_row "监控进程" "运行中 (PID $_m)" ok
    [ "$_autorun_ok" = "1" ] && _status_row "开机自启" "已启用" ok
    if [ -n "$_m" ] || [ "$_autorun_ok" = "1" ]; then
        if [ -n "$_port" ] || [ "$_port_unknown" = "1" ] || [ -n "$_cur" ]; then
            echo ""
        fi
    fi
    if [ -n "$_port" ]; then
        # 快照过旧时必须标注"这是几秒前的判断"。
        # 少了这句，200 秒前的结论和此刻的结论在屏幕上长得一模一样——
        # 而那一刻离"监控可能已经死了"很近，用户会以为一切正常。
        # 两档措辞与 Windows 侧逐字对应：刚过新鲜线只是"稍旧"，
        # 过了可用线要明说"可能已不是现在的情况"。同一句话会让 30 秒与 200 秒看起来一样。
        _age_note=""
        if [ "$_snap_ok" = "1" ] && [ "$SNAP_AGE" -gt "$SNAPSHOT_FRESH_SEC" ]; then
            if [ "$SNAP_AGE" -gt "$SNAPSHOT_USABLE_SEC" ]; then
                _age_note="（${SNAP_AGE} 秒前的判断，可能已不是现在的情况）"
            else
                _age_note="（${SNAP_AGE} 秒前的判断）"
            fi
        fi
        _status_row "翻墙代理" "已开启（本地端口 $_port 监听中）${_age_note}" ok
    elif [ "$_port_unknown" = "1" ]; then
        _status_row "翻墙代理" "这一轮没读到本机端口，无法判断（正常，会自动重试）" warn
    else
        _status_row "翻墙代理" "未检测到（当前无翻墙代理在运行）" dim
    fi
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
    if [ "$_ts_state" = "ok" ]; then
        echo ""
        _status_row "终端同步" "已生效（已开着的窗口敲回车即跟上）" ok
    fi
    echo ""

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
        _status_row "版本" "$_local_text（还没查过最新版；监控每 30 轮查一次，也可以$(menu_ref update)立刻查）" dim
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
            _state="可打开菜单$(menu_ref update)升级"; _role="warn"
        else
            _newer=$(compare_versions "$_local_ver" "$REMOTE_VERSION" || true)
            if [ "$_newer" -gt 0 ] 2>/dev/null; then
                _state="本地版本比最新发布版新"; _role="dim"
            else
                _older=$(compare_versions "$REMOTE_VERSION" "$_local_ver" || true)
                if [ "$_older" -gt 0 ] 2>/dev/null; then
                    _state="发现新版 $REMOTE_TAG，$(menu_ref update)即可升级"; _role="warn"
                else
                    _state="已是最新"; _role="dim"
                fi
            fi
        fi
        # 与同屏其余 7 行同一结构：标签固定 key 色、只有内容按状态变色。
        # 整行套一个角色色会让「版本」这个标签也跟着变色——那正是 _status_row 要解决的毛病。
        _status_row "版本" "$_local_text（$_state）$_age_text" "$_role"
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

# ------------------------------------------------------------------------------
# 状态快照的收集（get_status_snapshot）住在状态页这一层，不留在编排层：
# 它收集的是「此刻什么情况」，只被状态页与报告消费，编排层不消费它。
# 留在编排层会与状态页形成环（编排层调 show_status，状态页又调它）——
# 这个项目只认单向依赖：单独读任何一个文件都要能看出它依赖什么。
# ------------------------------------------------------------------------------

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
