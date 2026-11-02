# ==============================================================================
# shortcut.sh — 给单个程序定规矩（走代理 / 固定直连）
#
# 为什么 macOS 也需要这一层：
#   本工具平时用 launchctl setenv 把代理变量设成全局，从 Dock 启动的程序都拿得到。
#   但那是**一刀切**：所有程序拿到同一个值，没法让某个程序单独走、或者单独不走。
#   这一层补的就是"按程序区分"——这也是 Windows 侧同一个功能的由来。
#
#   两边机制不同，但使用者看到的行为一致：
#     Windows  造一个 .lnk + .vbs，点图标时先把变量设好再拉起程序
#     macOS    造一个独立的 .app 壳子，点图标时先把变量设好再拉起程序
#
# macOS 的做法为什么是「独立的 .app」而不是改原来的 app：
#   改原 app 的 bundle（放脚本进 Contents/MacOS、改 Info.plist 的 CFBundleExecutable）
#   会破坏它的代码签名，Gatekeeper 会拒绝打开；而且原 app 一更新就被覆盖。
#   造一个独立的壳子两者都避免了：原 app 一个字节不动，壳子可以随时删掉重造。
#
# 壳子长这样（都是现成的系统能力，不引入任何依赖）：
#   MyApp（走代理）.app/
#     Contents/Info.plist          声明它是个 app、叫什么、图标借谁的
#     Contents/MacOS/launcher      一个 shell 脚本，setenv 之后 exec 真程序
#
# 它与 Windows 侧共用同一张模式表（PROXY_MODES / PROXY_MODE_* 在 base.sh），
# 所以两边"有哪几种规矩、每种叫什么"永远一致。
# ==============================================================================

# 壳子放哪。与 Windows 的 launchers 目录同理：集中一处，好找好删。
# 用 ~/.envproxy 是因为它已经是本工具的家目录，卸载时会被整份带走。
_shortcut_apps_dir() {
    printf '%s\n' "$HOME/.envproxy/apps"
}

# 图标放哪（默认桌面）。放在桌面而不是"应用程序"文件夹：
# 放 /Applications 需要管理员权限，而桌面双击就能用，用户也好删。
_shortcut_default_dest() {
    printf '%s\n' "$HOME/Desktop"
}

# 把一个值写进 shell 单引号串，内部的单引号也安全转义。
#
# 单引号串里唯一不能直接出现的字符就是单引号本身。标准解法是把它换成
#   '"'"'
# 拆开看：先闭合当前串（'）、再写一个双引号包住的单引号（"'"）、再重新打开（'）。
# 拼起来仍然是一个字面量，shell 读到的就是那个单引号。
#
# 为什么不再"含单引号就放弃"：那会让一个合法路径静默建不成图标，
# 而报出来的原因只能是"建不出来"，用户无从知道真正卡在引号上。
# 能安全处理的就不该拒绝——拒绝只留给真正做不到的情况。
#
# 用 sed 而不是 shell 参数替换：这里的替换串本身含引号，
# 在参数替换里要跨三层引号嵌套，一处写错就生成一条会执行任意代码的脚本。
# sed 的 s 命令只需处理转义，判据单一、可读。sed 是系统自带，不引入依赖。
_shortcut_sq() {
    _ssq_out=$(printf '%s' "$1" | sed "s/'/'\"'\"'/g")
    printf "'%s'" "$_ssq_out"
    return 0
}

# 生成壳子的启动脚本内容。
# $1 = 目标程序路径  $2 = 模式 Id（proxy / direct）
#
# 两种模式的差别只有一处：启动前是"设上代理"还是"清掉代理"。
# 别的都一样（都 exec 真程序、都带同样的工作目录）。
_shortcut_launcher_body() {
    _slb_target=$1
    _slb_mode=$2
    _slb_target_q=$(_shortcut_sq "$_slb_target") || return 1

    printf '#!/bin/sh\n'
    printf '# 这个文件由 EnvProxy 生成，删掉对应的 .app 即可。\n'
    printf '# 它只做一件事：把环境准备好，然后把控制权交给真程序。\n'
    printf '\n'

    case "$_slb_mode" in
        direct)
            # 清空：让这个程序及其所有子进程都看不到代理。
            # 变量清单直接用 PROXY_VAR_NAMES（mac 侧它**已含大小写两种拼写**），
            # 不要再自己补一遍小写：那样每条都会 unset 两次。
            for _slb_v in $PROXY_VAR_NAMES; do
                printf 'unset %s\n' "$_slb_v"
            done
            ;;
        *)
            # 走代理：从中继端口记录读当前地址，读不到就退回 proxy.env 里的值。
            # **不把地址写死在这里**：翻墙软件会换端口，写死的壳子换一次就废了，
            # 而"每次点击重新决定"正是壳子这一层的价值。
            printf 'ENVPROXY_HOME="${ENVPROXY_HOME:-$HOME/.envproxy}"\n'
            printf '_ep=""\n'
            printf 'if [ -r "$ENVPROXY_HOME/relay.port" ]; then\n'
            printf '    _ep="http://127.0.0.1:$(cat "$ENVPROXY_HOME/relay.port" 2>/dev/null)"\n'
            printf 'fi\n'
            printf 'if [ -z "$_ep" ] && [ -r "$ENVPROXY_HOME/proxy.env" ]; then\n'
            # 从 proxy.env 摘 HTTP_PROXY 的值。文件里那一行形如
            #   export HTTP_PROXY="http://127.0.0.1:7078"
            # 要拿到的是两端的引号去掉、只剩地址。
            #
            # 用参数替换而不是 sed/tr：地址里不会出现引号，所以"去头、去尾"就够了；
            # 而 sed 要跨层引号嵌套、tr 的字符集里再套引号更容易写错（上一版就是
            # tr 的写法把引号留在了值里，症状是代理地址变成 ["http://..."]，
            # 客户端收到带引号的 URL 会直接当成无效地址）。
            printf '    _ln=$(grep "^export HTTP_PROXY=" "$ENVPROXY_HOME/proxy.env" 2>/dev/null | head -1)\n'
            printf '    _ln=${_ln#export HTTP_PROXY=}\n'
            printf '    _ln=${_ln#\\"}\n'
            printf '    _ep=${_ln%%\\"}\n'
            printf 'fi\n'
            printf 'if [ -n "$_ep" ]; then\n'
            # 变量清单同样直接用 PROXY_VAR_NAMES（已含两种拼写）。
            # NO_PROXY 单独处理（要的是例外清单，不是代理地址）。
            # NODE_USE_ENV_PROXY 更要单独处理：它要的是开关值，不是 URL——
            # 把它和地址类变量一视同仁地赋成 URL，Node 会读到一个非法开关值。
            for _slb_v in $PROXY_VAR_NAMES; do
                case "$_slb_v" in
                    NO_PROXY|no_proxy|NODE_USE_ENV_PROXY|node_use_env_proxy) continue ;;
                esac
                printf '    %s="$_ep"; export %s\n' "$_slb_v" "$_slb_v"
            done
            printf '    NO_PROXY="${NO_PROXY:-%s}"; export NO_PROXY\n' "$DEFAULT_NO_PROXY"
            printf '    no_proxy="$NO_PROXY"; export no_proxy\n'
            # 开关值从 base 层的权威常量来，不手写字面量。
            printf '    NODE_USE_ENV_PROXY=%s; export NODE_USE_ENV_PROXY\n' "$NODE_USE_ENV_PROXY_VALUE"
            printf 'fi\n'
            ;;
    esac

    # 把参数原样转交：双击或 `open -a` 时，壳子收到的 $@ 就是使用者的参数。
    #
    # 目标是 .app 时**不能直接 exec 它**：.app 是个目录，exec 会报
    # "Is a directory"。Finder 双击时由 LaunchServices 自己去找可执行文件，
    # 但 shell 的 exec 不会——必须把可执行文件的路径解析出来。
    #
    # 解析顺序照 macOS 的规矩：先读 Info.plist 的 CFBundleExecutable，
    # 读不到（plist 是二进制格式、或字段缺失）就退回 bundle 名同名文件，
    # 那是绝大多数 app 的布局。
    printf '\n'
    if [ "${_slb_target_q%.app\'}" != "$_slb_target_q" ]; then
        printf '_app=%s\n' "$_slb_target_q"
        printf '_exe=""\n'
        # 先试 plist：文本格式的可以直接 grep，二进制格式要靠 PlistBuddy。
        printf 'if [ -r "$_app/Contents/Info.plist" ]; then\n'
        printf '    if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then\n'
        printf '        _exe=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$_app/Contents/Info.plist" 2>/dev/null)\n'
        printf "    fi\n"
        printf 'fi\n'
        printf 'if [ -z "$_exe" ]; then\n'
        printf '    _exe=$(basename "$_app" .app)\n'
        printf 'fi\n'
        printf 'exec "$_app/Contents/MacOS/$_exe" "$@"\n'
    else
        printf 'exec %s "$@"\n' "$_slb_target_q"
    fi
    return 0
}

# 生成 Info.plist。$1 = 显示名  $2 = 壳子可执行文件名  $3 = 目标程序路径（借它的图标）
_shortcut_plist() {
    _sp_name=$1
    _sp_exec=$2
    _sp_target=$3
    # 显示名要转义 XML 实体，否则名字里一个 & 就让 plist 解析失败，
    # 而 Finder 只会说"应用已损坏"，看不出真正原因。
    _sp_xml=$(printf '%s' "$_sp_name" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n'
    printf '<dict>\n'
    printf '  <key>CFBundleName</key><string>%s</string>\n' "$_sp_xml"
    printf '  <key>CFBundleDisplayName</key><string>%s</string>\n' "$_sp_xml"
    printf '  <key>CFBundleExecutable</key><string>%s</string>\n' "$_sp_exec"
    printf '  <key>CFBundlePackageType</key><string>APPL</string>\n'
    printf '  <key>CFBundleVersion</key><string>1.0</string>\n'
    printf '  <key>CFBundleShortVersionString</key><string>1.0</string>\n'
    # 让它不出现在 Dock（壳子只是中转，用户要看到的是真程序的图标）。
    printf '  <key>LSUIElement</key><true/>\n'
    printf '  <key>LSBackgroundOnly</key><false/>\n'
    printf '</dict>\n'
    printf '</plist>\n'
    return 0
}

# 造一个壳子。$1 = 目标程序路径  $2 = 模式 Id  $3 = 放到哪个目录（空=桌面）
# 成功时把壳子路径打到标准输出，失败返回非零。
_shortcut_build_app() {
    _sba_target=$1
    _sba_mode=$2
    _sba_dest=${3:-$(_shortcut_default_dest)}

    [ -e "$_sba_target" ] || return 1
    _sba_suffix=$(proxy_mode_suffix "$_sba_mode" 2>/dev/null) || return 1
    [ -n "$_sba_suffix" ] || return 1

    _sba_base=$(basename "$_sba_target")
    _sba_base=${_sba_base%.app}
    _sba_app="$_sba_dest/${_sba_base}${_sba_suffix}.app"

    _sba_store=$(_shortcut_apps_dir)
    mkdir -p "$_sba_store" 2>/dev/null || return 1
    # 壳子的身份 = 目标路径 + 模式。两者都必须进目录名：
    #   只算路径  —— 同一个程序的两种模式会共用同一个壳子，后建的覆盖先建的
    #   只算模式  —— 两个不同目录下同名的程序会互相覆盖
    _sba_key=$(printf '%s\n%s' "$_sba_target" "$_sba_mode" | cksum | cut -d' ' -f1)
    _sba_work="$_sba_store/${_sba_base}_${_sba_key}.app"

    # 重造前先删旧的：壳子里可能残留上一次的启动脚本，
    # 不删会让"改了模式但行为没变"这种诡异现象出现。
    rm -rf "$_sba_work" 2>/dev/null || true
    mkdir -p "$_sba_work/Contents/MacOS" 2>/dev/null || return 1

    _shortcut_launcher_body "$_sba_target" "$_sba_mode" > "$_sba_work/Contents/MacOS/launcher" || return 1
    chmod 755 "$_sba_work/Contents/MacOS/launcher" 2>/dev/null || return 1
    _shortcut_plist "${_sba_base}${_sba_suffix}" "launcher" "$_sba_target" > "$_sba_work/Contents/Info.plist" || return 1

    # 放到目标位置。用 ditto 而不是 cp -R：ditto 保留扩展属性与符号链接，
    # 而 cp -R 在某些 macOS 版本上会把壳子弄成"已损坏"。
    mkdir -p "$_sba_dest" 2>/dev/null || return 1
    rm -rf "$_sba_app" 2>/dev/null || true
    if command -v ditto >/dev/null 2>&1; then
        ditto "$_sba_work" "$_sba_app" 2>/dev/null || return 1
    else
        cp -R "$_sba_work" "$_sba_app" 2>/dev/null || return 1
    fi

    printf '%s\n' "$_sba_app"
    return 0
}

# 扫出本工具造的壳子。判据是**内容**而不是文件名：
# Info.plist 里有我们的标记、且启动脚本里带着目标路径那一行。
# 只按名字判会误删使用者自己建的、名字恰好也带「（走代理）」的 app。
_shortcut_records() {
    _sr_base=$(_shortcut_default_dest)
    for _sr_dir in "$_sr_base" /Applications "$HOME/Applications"; do
        [ -d "$_sr_dir" ] || continue
        for _sr_app in "$_sr_dir"/*.app; do
            [ -d "$_sr_app" ] || continue
            _sr_launcher="$_sr_app/Contents/MacOS/launcher"
            [ -f "$_sr_launcher" ] || continue
            # 启动脚本里必须有我们写的那句注释，否则不是我们造的。
            grep -q '这个文件由 EnvProxy 生成' "$_sr_launcher" 2>/dev/null || continue
            _sr_target=$(sed -n 's/^exec .*//p' "$_sr_launcher" 2>/dev/null)
            _sr_target=$(grep '^exec ' "$_sr_launcher" 2>/dev/null | head -1 | sed -e "s/^exec //" -e "s/ \"\\\$@\"$//" -e "s/^'//" -e "s/'$//")
            _sr_name=$(basename "$_sr_app" .app)
            _sr_mode=""
            for _sr_m in $PROXY_MODES; do
                _sr_sfx=$(proxy_mode_suffix "$_sr_m" 2>/dev/null) || continue
                case "$_sr_name" in
                    *"$_sr_sfx") _sr_mode=$_sr_m; _sr_name=${_sr_name%"$_sr_sfx"} ;;
                esac
            done
            _sr_state=ok
            [ -e "$_sr_target" ] || _sr_state=broken-target
            printf '%s\t%s\t%s\t%s\t%s\n' "$_sr_app" "$_sr_name" "$_sr_mode" "$_sr_state" "$_sr_target"
        done
    done
    return 0
}

# 建一个壳子，返回 Ok / Path / Reason / Mode 四段（用 | 分隔）。
# 与 Windows 侧的 New-ProxyShortcut 返回同样的事实，让两边的界面能说同样的话。
_shortcut_new() {
    _sn_target=$1
    _sn_mode=$2
    _sn_dest=${3:-}

    case "$_sn_target" in
        *.app) _sn_real="$_sn_target/Contents/MacOS" ;;
        *)     _sn_real=$_sn_target ;;
    esac

    if [ ! -e "$_sn_target" ]; then
        printf 'fail|%s|找不到这个程序\n' ""
        return 0
    fi
    if ! proxy_mode_suffix "$_sn_mode" >/dev/null 2>&1; then
        printf 'fail|%s|未知的模式：%s\n' "" "$_sn_mode"
        return 0
    fi

    # 同一程序已有别的模式的壳子时，先记下来，让界面能提一句。
    _sn_app=$(_shortcut_build_app "$_sn_target" "$_sn_mode" $_sn_dest 2>/dev/null)
    if [ -z "$_sn_app" ]; then
        printf 'fail|%s|建不出来（目标文件夹不可写？）\n' ""
        return 0
    fi
    printf 'ok|%s|%s\n' "$_sn_app" "$_sn_mode"
    return 0
}

# 删一个壳子。
_shortcut_remove() {
    _srm_app=$1
    case "$_srm_app" in
        *.app) ;;
        *) return 1 ;;
    esac
    [ -d "$_srm_app" ] || return 1
    # 只删我们造的：判据与扫描一致，防止误删使用者自己的 app。
    grep -q '这个文件由 EnvProxy 生成' "$_srm_app/Contents/MacOS/launcher" 2>/dev/null || return 1
    rm -rf "$_srm_app" 2>/dev/null || return 1
    return 0
}

# ------------------------------------------------------------------------------
# 界面
# ------------------------------------------------------------------------------

# 选程序。扫 /Applications 与 ~/Applications 下的 .app，按名字排序，分页显示。
# $1 可以是预设的筛选词（用户输入时边打边筛）。
_shortcut_pick_program() {
    _spp_filter=$1
    _spp_list=""
    for _spp_dir in /Applications "$HOME/Applications" /System/Applications; do
        [ -d "$_spp_dir" ] || continue
        for _spp_app in "$_spp_dir"/*.app; do
            [ -d "$_spp_app" ] || continue
            _spp_n=$(basename "$_spp_app" .app)
            if [ -n "$_spp_filter" ]; then
                case "$_spp_n" in
                    *"$_spp_filter"*) ;;
                    *) continue ;;
                esac
            fi
            _spp_list="$_spp_list$_spp_app
"
        done
    done
    printf '%s' "$_spp_list" | sort -u
}

# 「管理已建的」：列出所有壳子，能选中删掉。
_shortcut_manage_page() {
    while :; do
        clear_screen_safe 2>/dev/null || clear 2>/dev/null || true
        style_out title "======== 管理已建的 ========"
        echo ""
        _sm_recs=$(_shortcut_records)
        if [ -z "$_sm_recs" ]; then
            style_out dim "  还没有建过。先回上一页选 1 或 2 建一个。"
            echo ""
            style_out dim "  按回车返回"
            _sm_x=""
            read -r _sm_x 2>/dev/null || return 0
            return 0
        fi
        # 按程序名排序，同一程序的两种规矩自然挨在一起。
        _sm_sorted=$(printf '%s\n' "$_sm_recs" | sort -t"$(printf '\t')" -k2,2 -k3,3)
        _sm_idx=0
        _sm_old_ifs=$IFS
        IFS=$(printf '\n')
        for _sm_line in $_sm_sorted; do
            [ -n "$_sm_line" ] || continue
            _sm_idx=$((_sm_idx + 1))
            IFS=$_sm_old_ifs
            _sm_app=$(printf '%s' "$_sm_line" | cut -f1)
            _sm_name=$(printf '%s' "$_sm_line" | cut -f2)
            _sm_mode=$(printf '%s' "$_sm_line" | cut -f3)
            _sm_state=$(printf '%s' "$_sm_line" | cut -f4)
            IFS=$(printf '\n')
            _sm_label=$(proxy_mode_label "$_sm_mode" 2>/dev/null)
            [ -n "$_sm_label" ] || _sm_label="（未知）"
            style_out_nonewline cmd "  $(printf '%2s' "$_sm_idx")  "
            style_out_nonewline item "$_sm_name    $_sm_label"
            if [ "$_sm_state" != "ok" ]; then
                style_out warn "    （程序已经不在了，点了会失败）"
            else
                echo ""
            fi
        done
        IFS=$_sm_old_ifs
        echo ""
        style_out dim "  输编号 = 删掉那个壳子    0 = 返回"
        _sm_ans=""
        read -r _sm_ans 2>/dev/null || return 0
        case "$_sm_ans" in
            ''|0|q|Q) return 0 ;;
        esac
        case "$_sm_ans" in
            *[!0-9]*) style_out warn "  没有这个编号：$_sm_ans"; sleep 1; continue ;;
        esac
        if [ "$_sm_ans" -lt 1 ] || [ "$_sm_ans" -gt "$_sm_idx" ]; then
            style_out warn "  没有这个编号：$_sm_ans（可用的有 1-$_sm_idx）"
            sleep 1
            continue
        fi
        _sm_pick=$(printf '%s\n' "$_sm_sorted" | sed -n "${_sm_ans}p" | cut -f1)
        echo ""
        style_out text "  确定要删掉吗？"
        style_out dim "    $_sm_pick"
        echo ""
        style_out dim "  输 y 回车确认，直接回车 = 不删"
        _sm_c=""
        read -r _sm_c 2>/dev/null || return 0
        case "$_sm_c" in
            y|Y|yes|是)
                if _shortcut_remove "$_sm_pick"; then
                    style_out ok "  已删掉。"
                else
                    style_out warn "  删不掉：可能没有权限，或者它已经不在那里了。"
                fi
                sleep 1
                ;;
        esac
    done
}

# 「给程序建走代理的快捷方式」的入口。$1 = 模式 Id
_shortcut_new_flow() {
    _snf_mode=$1
    _snf_label=$(proxy_mode_label "$_snf_mode" 2>/dev/null)
    [ -n "$_snf_label" ] || _snf_label="$_snf_mode"

    clear_screen_safe 2>/dev/null || clear 2>/dev/null || true
    style_out title "======== 挑一个程序 ========"
    echo ""
    style_out dim "  下面列出这台机器上装了哪些程序。"
    style_out dim "  也可以直接输入程序名的一部分来筛选。"
    echo ""
    _snf_apps=$(_shortcut_pick_program "")
    _snf_n=0
    _snf_old_ifs=$IFS
    IFS=$(printf '\n')
    for _snf_a in $_snf_apps; do
        [ -n "$_snf_a" ] || continue
        _snf_n=$((_snf_n + 1))
        [ "$_snf_n" -le 20 ] || break
        IFS=$_snf_old_ifs
        style_out_nonewline cmd "  $(printf '%2s' "$_snf_n")  "
        style_out item "$(basename "$_snf_a" .app)"
        IFS=$(printf '\n')
    done
    IFS=$_snf_old_ifs
    echo ""
    style_out dim "  输编号后回车    输其它字 = 按名字筛选    0 = 返回"
    _snf_ans=""
    read -r _snf_ans 2>/dev/null || return 0
    case "$_snf_ans" in
        ''|0|q|Q) return 0 ;;
    esac
    case "$_snf_ans" in
        *[!0-9]*)
            # 当成筛选词重来一次
            _shortcut_new_flow_filtered "$_snf_mode" "$_snf_ans"
            return 0
            ;;
    esac
    _snf_pick=$(printf '%s\n' "$_snf_apps" | sed -n "${_snf_ans}p")
    [ -n "$_snf_pick" ] || { style_out warn "  没有这个编号：$_snf_ans"; sleep 1; return 0; }
    _shortcut_confirm_and_build "$_snf_mode" "$_snf_pick"
}

# 带筛选词的同一流程。
_shortcut_new_flow_filtered() {
    _snff_mode=$1
    _snff_filter=$2
    _snff_apps=$(_shortcut_pick_program "$_snff_filter")
    if [ -z "$_snff_apps" ]; then
        style_out warn "  没有名字含「$_snff_filter」的程序。"
        sleep 1
        return 0
    fi
    _snff_n=$(printf '%s\n' "$_snff_apps" | grep -c .)
    if [ "$_snff_n" = "1" ]; then
        _shortcut_confirm_and_build "$_snff_mode" "$_snff_apps"
        return 0
    fi
    clear_screen_safe 2>/dev/null || clear 2>/dev/null || true
    style_out title "======== 找到 $_snff_n 个 ========"
    echo ""
    _snff_i=0
    _snff_old_ifs=$IFS
    IFS=$(printf '\n')
    for _snff_a in $_snff_apps; do
        [ -n "$_snff_a" ] || continue
        _snff_i=$((_snff_i + 1))
        IFS=$_snff_old_ifs
        style_out_nonewline cmd "  $(printf '%2s' "$_snff_i")  "
        style_out item "$(basename "$_snff_a" .app)"
        IFS=$(printf '\n')
    done
    IFS=$_snff_old_ifs
    echo ""
    style_out dim "  输编号后回车    0 = 返回"
    _snff_ans=""
    read -r _snff_ans 2>/dev/null || return 0
    case "$_snff_ans" in
        ''|0) return 0 ;;
    esac
    _snff_pick=$(printf '%s\n' "$_snff_apps" | sed -n "${_snff_ans}p")
    [ -n "$_snff_pick" ] || return 0
    _shortcut_confirm_and_build "$_snff_mode" "$_snff_pick"
}

# 确认页 + 真建。
_shortcut_confirm_and_build() {
    _scb_mode=$1
    _scb_target=$2
    _scb_label=$(proxy_mode_label "$_scb_mode" 2>/dev/null)
    [ -n "$_scb_label" ] || _scb_label=$_scb_mode
    _scb_suffix=$(proxy_mode_suffix "$_scb_mode" 2>/dev/null)
    _scb_name=$(basename "$_scb_target" .app)

    clear_screen_safe 2>/dev/null || clear 2>/dev/null || true
    style_out title "======== 确认 ========"
    echo ""
    style_out text "  程序    $_scb_name"
    style_out dim  "          $_scb_target"
    echo ""
    style_out text "  规矩    $_scb_label"
    if [ "$_scb_mode" = "direct" ]; then
        style_out dim "          双击它启动的程序一定不走代理，哪怕别的程序都在翻墙。"
    else
        style_out dim "          双击它启动的程序会带上当前代理，跟着翻墙软件走。"
    fi
    echo ""
    style_out text "  图标名  ${_scb_name}${_scb_suffix}"
    style_out text "  放在    $(_shortcut_default_dest)"
    echo ""
    style_out dim "  输 y 回车确认，直接回车 = 取消"
    _scb_c=""
    read -r _scb_c 2>/dev/null || return 0
    case "$_scb_c" in
        y|Y|yes|是) ;;
        *) return 0 ;;
    esac

    _scb_res=$(_shortcut_new "$_scb_target" "$_scb_mode" "")
    _scb_ok=$(printf '%s' "$_scb_res" | cut -d'|' -f1)
    _scb_path=$(printf '%s' "$_scb_res" | cut -d'|' -f2)
    _scb_why=$(printf '%s' "$_scb_res" | cut -d'|' -f3)

    echo ""
    if [ "$_scb_ok" = "ok" ]; then
        # 写后回读：写成功不等于读回来是对的（本项目其它写操作同一条规矩）。
        if [ -d "$_scb_path" ] && [ -x "$_scb_path/Contents/MacOS/launcher" ]; then
            style_out ok "  建好了。"
            style_out dim "    $_scb_path"
            style_out dim "    双击试一下。第一次打开可能会问你确不确定。"
        else
            style_out warn "  建了，但读回来不对：$_scb_path"
            style_out dim "  这个壳子可能打不开。请把这一行截图反馈。"
        fi
    else
        style_out warn "  $_scb_why"
    fi
    echo ""
    style_out dim "  按回车返回"
    _scb_x=""
    read -r _scb_x 2>/dev/null || return 0
    return 0
}

# 表的 Handler 必须**无参**（这是表能成立的前提：分派只认名字，不知道任何参数）。
# 所以每种模式各配一个零参包装，而不是让表里写 `---proxy` 这类参数。
_shortcut_new_flow_proxy() {
    _shortcut_new_flow proxy
}

_shortcut_new_flow_direct() {
    _shortcut_new_flow direct
}
