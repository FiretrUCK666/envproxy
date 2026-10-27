# ------------------------------------------------------------------------------
#  base.sh — 基础层：契约常量、纯函数助手
#  由入口 envproxy.sh 按固定顺序 source 加载，不单独运行。
#  本层必须加载期安全（无顶层副作用），自检只 source 这一层。
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# 0. 路径与常量（全部动态推导，不写死用户名/磁盘）
# ------------------------------------------------------------------------------

ENVPROXY_HOME="${ENVPROXY_HOME:-$HOME/.envproxy}"

# ------------------------------------------------------------------------------
# 2. 环境变量读写（终端路 proxy.env + GUI 路 launchctl，双路同进同退）
# ------------------------------------------------------------------------------
# 本机地址直连的默认例外集，写法遵循 NO_PROXY 的通行规范：IPv6 地址**裸写**。
# 裸写是各家的共同要求——httpx 的规范示例就是 `NO_PROXY=example.com,::1,localhost,...`，
# 而且它会自己给 IPv6 补上方括号去构造内部模式；预先写成 `[::1]` 会被当成普通域名，
# 生成非法模式，反而让每一次请求都抛 `InvalidURL: Invalid port: ':1]'`。
# 也就是说方括号属于 URL 字面量的写法，在 NO_PROXY 里是写错了位置。
DEFAULT_NO_PROXY="localhost,127.0.0.1,::1"

# 终端同步要检查/写入/摘除的那些 shell 配置文件。
#
# **写成函数，不写成常量**：常量在 source 那一刻就把 $HOME 固化进去了。
# 自检会把 HOME 改道到沙箱，固化过的名单仍然指向使用者的真实家目录——
# 那等于自检去动真实环境（曾经就是这样：断言红在一个与改动无关的用例上，
# 而真实原因是它操作了错误的文件）。
#
# 三个调用方（状态页 / 安装 / 卸载）必须共用这一份，各写一份必然漂移：
# 曾经状态页只看 `.zshrc` 系列、安装实际写 `.zshenv`，只装了 `.zshenv` 的用户
# 状态页会报"配置文件里没有同步块"，照它说的重装一遍也修不好。
#
# 为什么是这几个：zsh 的 `.zshenv` 在**所有** shell 类型下都会加载（登录、交互、
# 脚本、ssh 远程命令），`.zshrc` 只在交互式下加载；bash 侧用 `.bash_profile`
# 与 `.bashrc`。`.zprofile` / `.zlogin` 列进来是为了认出"早期版本可能写过的位置"——
# 装过老版本的用户那里可能还留着块，摘除时要找得到。
rc_check_files() {
    printf '%s\n' \
        "$HOME/.zshenv" "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zlogin" \
        "$HOME/.bash_profile" "$HOME/.bashrc"
}

# 安装真正写入的落点，按 shell 分两组：zsh 侧 `touch` 建（缺了就建），
# bash 侧只在文件已存在时写（不替使用者造 `.bash_profile` 那种会干扰他既有配置的文件）。
rc_zsh_files() {
    printf '%s\n' "$HOME/.zshenv" "$HOME/.zshrc"
}

rc_bash_files() {
    printf '%s\n' "$HOME/.bash_profile" "$HOME/.bashrc"
}

# 帮助每一屏的行数上限。超过这个数，终端会把底部的「怎么退出」切掉——
# 用户会以为帮助卡死，其实只是没画出来。与 Windows 侧 $HelpMaxLines 必须一致。
# 依据同那边：量的是整屏输出（含标题与结尾导航），正文实际只有 27 行。
HELP_MAX_LINES=40

# ESC 字符：所有 ANSI 序列都从它开始。写成变量而不是每个地方敲一次，读起来才看得懂。
_ESC=$(printf '\033')
# ---- 屏幕渲染层的常量（Windows 侧同名同义，值可不同）----
# 最小可用终端：宽度不够时一折行就认不出「标签 : 内容」的结构，宁可不刷新。
SCREEN_MIN_WIDTH=40
# 最小可用高度：低于这个数，状态页连正文都放不下，只能靠裁剪硬塞，不如退回静态。
SCREEN_MIN_HEIGHT=20
# 内容区下方要留的行数：一行给「按 0 返回」的提示，一行给光标。
SCREEN_BOTTOM_MARGIN=2
# 「等一小会儿看有没有按键」的轮询粒度（秒）。
# DIVERGE(Mac): bash 3.2 的 read -t 只认整数秒（Apple 的 read.def 里走 alarm()），
#   没有亚秒超时，所以这里是 1 秒；Windows 侧是 150 毫秒。差异只在按键手感，
#   行为语义（按 0/q/Esc 退出、其余忽略）完全相同。
SCREEN_POLL_SEC=1
# 状态页自己刷新的间隔（秒）。与监控的探测节奏（2-3 秒）对齐，不做智能变速。
STATUS_REFRESH_SEC=2

# 日志体积上限与截断后保留的行数。写成具名常量而不是散在代码里的 204800 / 200：
# 文档里印着这两个数，两侧也各写了一遍，散着放就一定会有一天改一处漏一处。
# 与 Windows 侧 $LogMaxBytes / $LogTailLines 同口径，门禁 6 核对。
LOG_MAX_BYTES=204800
LOG_TAIL_LINES=200

# 计算一段文字在终端里占几格：中日韩字符占两格，其余一格。
# 所有需要对齐的地方（菜单、帮助的两列、安装提示、日志裁剪）都走这一处：
# 写第二份就会有一天两份算出两个宽度，屏幕上看就是"某一屏的表格歪了"。
# 放在 base 层而不是 ops：帮助与菜单都要用它，而 ops 里的定义顺序会随编辑变化。
#
# 判据与 Windows 侧 Get-DisplayWidth 逐字节同一条：码位 > U+2E80 记两格。
# UTF-8 下等价于"3 字节序列的首字节 >= 0xE3"——2 字节序列（é · °）与
# U+2000..U+2E7F 的三字节序列（… → ）都只有一格，与 Windows 的结论一致。
#
# 为什么按字节走而不是按字符走：旧版用 `wc -c` + `tr` 数多字节字节数再除以 3，
# 于是每个 2 字节字符（… → · ° é）被算成 2 格，比 Windows 宽一格，表格歪掉；
# 而 `_truncate_width` 逐字符调本函数，一个字符 forks 3 次——实测一条超宽日志行
# （98 列、137 字符）要 11 秒，状态页每多打印一行日志就多等这么久。
# 现在整个函数零 fork：`printf -v` 取字节值，纯算术累加。
_display_width() {
    _dw_s="$1"
    [ -n "$_dw_s" ] || { printf '0'; return 0; }
    # 判据与 Windows 侧 Get-DisplayWidth 同一条：码位 > U+2E80 记两格。
    # UTF-8 下等价于"3 字节序列且（首字节 > 0xE2，或首字节 = 0xE2 且第二字节 >= 0xBA）"；
    # 4 字节序列（补充平面）码位必然 > U+2E80，也记两格。
    #
    # 这个函数的结论必须在 GNU bash 5 与 macOS bash 3.2 上**逐字符相同**，
    # 否则菜单与帮助的两列表格只在 Mac 上歪，而开发机复现不出来。踩过的坑：
    #   ① printf -v '%d' "'$ch" 取字节值：3.2 对多字节字节返回 < 128，
    #      整个函数退化成"按字节数算宽度"（「中」3 格、「…」3 格）；
    #   ② case [$'\001'-$'\177'] 区间模式：3.2 对 case 里的 ANSI-C 引用
    #      支持不完整，报 syntax error near ';;'。
    # 现在只用 od：它的输出是纯十六进制文本，与 shell 版本、locale 都无关，
    # 之后的解码是纯算术。
    #
    # 性能：od 是一次进程启动。调用点都是"渲染一行"，量级够用；
    # 频繁重复的字符串（菜单同一行渲染多次）走下面的记忆表。
    # 算对的代价是一次进程启动，而算错的代价是 Mac 上整屏表格歪掉。
    printf -v _dw_key '%s' "$_dw_s"
    if [ "${_DW_CACHE_K-}" = "$_dw_key" ] && [ -n "${_DW_CACHE_V+x}" ]; then
        printf '%s' "$_DW_CACHE_V"
        return 0
    fi
    _dw_hex=$(printf '%s' "$_dw_s" | od -An -tx1 -v)
    _dw_hex="${_dw_hex//[[:space:]]/}"
    _dw_n=${#_dw_hex}
    _dw_i=0
    _dw_w=0
    while [ "$_dw_i" -lt "$_dw_n" ]; do
        _dw_b=$((16#${_dw_hex:$_dw_i:2}))
        if [ "$_dw_b" -lt 128 ]; then
            _dw_w=$((_dw_w + 1)); _dw_i=$((_dw_i + 2))
        elif [ "$_dw_b" -ge 240 ]; then
            _dw_w=$((_dw_w + 2)); _dw_i=$((_dw_i + 8))
        elif [ "$_dw_b" -ge 224 ]; then
            _dw_b2=0
            if [ "$_dw_b" -eq 226 ] && [ $((_dw_i + 4)) -le "$_dw_n" ]; then
                _dw_b2=$((16#${_dw_hex:$((_dw_i + 2)):2}))
            fi
            if [ "$_dw_b" -gt 226 ] || { [ "$_dw_b" -eq 226 ] && [ "$_dw_b2" -ge 186 ]; }; then
                _dw_w=$((_dw_w + 2))
            else
                _dw_w=$((_dw_w + 1))
            fi
            _dw_i=$((_dw_i + 6))
        else
            _dw_w=$((_dw_w + 1)); _dw_i=$((_dw_i + 4))
        fi
    done
    _DW_CACHE_K="$_dw_key"
    _DW_CACHE_V="$_dw_w"
    printf '%s' "$_dw_w"
}

# 把文字补齐到指定宽度（按上面的显示宽度算）。
_menu_cell_pad() {
    _mcp_text="$1"
    _mcp_width="$2"
    _mcp_len=$(_display_width "$_mcp_text")
    _mcp_pad=$((_mcp_width - _mcp_len))
    [ "$_mcp_pad" -lt 0 ] && _mcp_pad=0
    printf '%s%*s' "$_mcp_text" "$_mcp_pad" ''
}
# 这个地址是不是指向本机回环。
# 它问的是"这个**目标**在本机吗"，用来决定要不要经代理去取；
# 与归属判定那条（"这个代理值是不是我们写的本机地址"）不是一个问题，不共用函数。
# 判据认全三种写法：127.0.0.1、[::1]、localhost。
# 给回环地址设代理没有意义——代理那次请求的主机名仍是回环，看的是代理进程
# 自己那一侧，只会让"本机服务"看起来忽好忽坏。
# 判据与 Windows 侧 Test-LoopbackUrl 必须**逐例同结论**（自检拿同一张表两侧各跑一遍）：
# 它的用途是"这个地址要不要经代理去取"，两侧结论不同就成了行为分叉。
# 所以这里做的是同一个 URI 解析，不是逐字面量比对——
# 逐字面量会把 http://LOCALHOST:7890、user:pw@localhost、127.0.0.2 判成"不是回环"，
# 而 Windows 的 [System.Uri] 认整个 127.0.0.0/8、会把 host 归一成小写、会剥掉 UserInfo。
# 输出一个字段：host（小写、去掉方括号与端口、去掉 userinfo）。解析不出来就输出空。
_url_host() {
    _uh_u="$1"
    case "$_uh_u" in
        *://*) _uh_u="${_uh_u#*://}" ;;
    esac
    _uh_u="${_uh_u%%/*}"
    _uh_u="${_uh_u%%\?*}"
    _uh_u="${_uh_u%%#*}"
    # userinfo：最后一个 @ 之后才是主机（密码里可能有 @）
    case "$_uh_u" in
        *@*) _uh_u="${_uh_u##*@}" ;;
    esac
    case "$_uh_u" in
        '['*)
            # 方括号 IPv6：[::1]:7078 —— 取方括号里的内容。
            # 不能用 %%:* 截端口：它会在第一个冒号处切断，"[::1]" 变成 "["。
            _uh_u="${_uh_u#[}"
            _uh_u="${_uh_u%%]*}"
            ;;
        *)
            # 没有方括号：最后一个冒号之后是端口（也覆盖 :::1 这种畸形写法）
            case "$_uh_u" in
                *:*) _uh_u="${_uh_u%%:*}" ;;
            esac
            ;;
    esac
    # Windows 的 URI 解析把 host 归一成小写，这里跟上
    printf '%s' "$_uh_u" | tr '[:upper:]' '[:lower:]'
}

is_loopback_url() {
    [ -n "${1:-}" ] || return 1
    _ilu_host=$(_url_host "$1")
    [ -n "$_ilu_host" ] || return 1
    # 127.0.0.0/8 整段都算回环：Windows 的 Uri.IsLoopback 就这么判，只认 127.0.0.1 会分叉。
    case "$_ilu_host" in
        127.*|localhost|::1) return 0 ;;
    esac
    return 1
}

# 把一段文字按终端显示宽度截断，超出时补省略号。
# 必须按"字符"走而不是按字节切：中文占两格，按字节切会把一个汉字切成半个，
# 屏幕上就是乱码。逐字符累加显示宽度，超过就停。
# 截断走的是与 _display_width 同一套字节判据（就地展开，不再逐字符调子 shell）：
# 逐字符调子 shell 的代价是每个字符 forks 数次，一条超宽日志行要十几秒。
# 从标准输入读若干行，输出其中最大的显示宽度。
# 五处「求一列里最宽的名字」原来是同一形状各写一遍（安装提示列、菜单名字列、
# 帮助两列、帮助名字列），只有变量前缀不同。收敛成一处之后，
# 「宽度怎么算」只有 _display_width 一个答案，改它不会漏掉某一屏。
_max_width_of() {
    _mwo_w=0
    while IFS= read -r _mwo_l; do
        _mwo_n=$(_display_width "$_mwo_l")
        [ "$_mwo_n" -gt "$_mwo_w" ] && _mwo_w="$_mwo_n"
    done
    printf '%s' "$_mwo_w"
}

_truncate_width() {
    LC_ALL=C
    _tw_s="$1"
    _tw_max="$2"
    if [ "$(_display_width "$_tw_s")" -le "$_tw_max" ]; then
        printf '%s' "$_tw_s"
        return 0
    fi
    _tw_n=${#_tw_s}
    _tw_i=0
    _tw_aw=0
    _tw_acc=0   # 已接受部分的字节数
    while [ "$_tw_i" -lt "$_tw_n" ]; do
        _tw_ch=${_tw_s:_tw_i:1}
        # 宽度**不再自己算一遍**：这里原来复制了一份与 _display_width 相同的判据，
        # 于是同一个 bug 要修两处——实测就踩到了（…/→/— 被判成两格，裁剪和补齐
        # 给出互相矛盾的宽度，两列对齐歪掉）。判据只留 _display_width 一处。
        _tw_cw=$(_display_width "$_tw_ch")
        printf -v _tw_b '%d' "'$_tw_ch"
        if [ "$_tw_b" -lt 128 ]; then _tw_cl=1
        elif [ "$_tw_b" -ge 224 ]; then _tw_cl=3
        else _tw_cl=2; fi
        [ $((_tw_aw + _tw_cw)) -gt "$_tw_max" ] && break
        _tw_aw=$((_tw_aw + _tw_cw))
        _tw_i=$((_tw_i + _tw_cl))
        _tw_acc=$_tw_i
    done
    printf '%s…' "${_tw_s:0:_tw_acc}"
}

# 配色分两层：角色 -> 颜色名 -> 本平台怎么写。
#
# 为什么要多这一层名字：两侧写颜色的方式毫无共同语言（Windows 侧是 [ConsoleColor]
# 枚举，这里是 ANSI 数字），于是"两端口径一致"只能靠人记得住，门禁也只比得了角色名、
# 一个颜色都比不了——实测就这么放过去一次：`cmd` 从绿改成了青，命令与标题同色，
# 用户在屏幕上一眼分不清，两侧门禁却全绿。多这一层之后，两侧共享的是颜色名，
# 门禁直接比颜色名，"换个颜色只改一处"和"两侧不许分叉"才同时成立。
# 颜色名 -> ANSI 前景色码。
# 颜色名清单：与上面 case 的分支一一对应（自检核对"每个角色的颜色名都在里面"）。
# 写在映射函数旁边，因为这就是那张表的目录；挪到别处放就会漂。
STYLE_COLOR_NAMES="cyan brightwhite green yellow darkgray none"

style_code_of_name() {
    case "$1" in
        cyan)        echo "96" ;;
        brightwhite) echo "97" ;;
        green)       echo "92" ;;
        yellow)      echo "93" ;;
        darkgray)    echo "90" ;;
        *)           echo "" ;;
    esac
}

# 角色 -> 颜色名，一条记录一个角色（空格分隔）。
# cmd 必须是绿色，且不许与其余任何角色同色：屏幕上的绿色就是"这一整行能复制去跑"。
# 用户每换一屏都要重新认这件事，所以它是可读性问题，不是审美问题。
# 门禁 6 与两侧自检都钉住这两条，改色当场红。
STYLE_MAP="title:cyan heading:cyan item:brightwhite key:brightwhite value:brightwhite cmd:green ok:green warn:yellow dim:darkgray text:none"
# 角色名清单从表里派生，不另抄一份（抄一份就会有一天两边不一样）。
STYLE_ROLES=""
for _sr_rec in $STYLE_MAP; do
    STYLE_ROLES="$STYLE_ROLES ${_sr_rec%%:*}"
done
STYLE_ROLES="${STYLE_ROLES# }"
unset _sr_rec

# 角色 -> 颜色名。没声明的角色一律按 none（不写颜色），不报错也不乱猜。
style_color_of_role() {
    case " $STYLE_MAP " in
        *" $1:"*) ;;
        *) echo "none"; return 0 ;;
    esac
    for _scr_rec in $STYLE_MAP; do
        case "$_scr_rec" in
            "$1":*) echo "${_scr_rec#*:}"; unset _scr_rec; return 0 ;;
        esac
    done
    unset _scr_rec
    echo "none"
}

# 角色 -> ANSI 码。渲染只认这一处，别处不许再写颜色字面量。
style_color() {
    style_code_of_name "$(style_color_of_role "$1")"
}
# 按角色输出一行。所有给人看的文字都走这里，于是"换个颜色"只要改上面那张表。
# stdout 不是终端时不上色：转义序列会原样写进日志（实测 ^[[36m），既弄脏日志也没法看。
style_out() {
    _so_role="$1"; shift
    if [ ! -t 1 ]; then printf '%s\n' "$*"; return 0; fi
    _so_c=$(style_color "$_so_role")
    if [ -z "$_so_c" ]; then printf '%s\n' "$*"; else printf '\033[%sm%s\033[0m\n' "$_so_c" "$*"; fi
    return 0
}

# 变量事实源（写/核/收/判四处共用，口径不再分家）：代理变量 6 个（大小写双写）
# + NO_PROXY 双写 + 哨兵 1 个，归属一律按"本机地址才是我们写下的"判定。
OWNED_HTTP_PREFIX="http://127.0.0.1:"
# 注入端按"实际能连上的那个地址"拼 URL：只绑 ::1 的代理在 IPv4 上主动拒绝，
# 所以注入值可能是 http://[::1]:port。形状判据必须同时认这两种，
# 只认 127.0.0.1 的话 IPv6 注入的值会被判成"不是我们的"，既清不掉也认不出。
OWNED_HTTP6_PREFIX="http://[::1]:"

# ------------------------------------------------------------------------------
# 变量名的**唯一权威处**（与 Win 侧 $ProxyVarNames 同地位）。
# 为什么要表：名字手抄在各处就会漂移——漏一个变量的后果是"清不干净"，
# 而它只在特定操作下才暴露（用户以为固定直连了，curl 却还在走代理）。
# 新增/改名变量时**只改这里**，写入、核对、回收、归属记录都遍历它。
# DIVERGE(Mac): 9 个——5 个规范拼写 + 4 个小写拼写。macOS 的变量名真大小写敏感，
#   有的工具只认小写；Windows 命名空间大小写不敏感，写小写只会互相覆盖，故那边只有 5 个。
# 顺序即写入顺序：大写在前、小写紧随其后，NO_PROXY 归到中间那一组之后。
PROXY_VAR_NAMES="HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy NODE_USE_ENV_PROXY"
# 走代理地址的那 6 个（不含 NO_PROXY / NODE_USE_ENV_PROXY：它们的值不是代理地址）
PROXY_ADDR_VAR_NAMES="HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy"
# NO_PROXY 的两个拼写（值是例外清单，回收规则与地址变量不同）
NO_PROXY_VAR_NAMES="NO_PROXY no_proxy"

# NO_PROXY 只增不减：已存在的条目原样保留，缺失的默认条目补上。
# 环境变量是共享资源——用户自己加的例外（公司内网等）与别的工具写下的例外都必须留着，
# 本工具只负责"本机地址一定直连"这一件事。
# 取值用 sed 而非 tr -d ' '：条目里可能有空格，整体删空格会改掉别人写的值。
merge_no_proxy() {
    _existing="$1"; _default="$2"
    _out="$_default"
    _lower=$(printf '%s' "$_default" | tr 'A-Z' 'a-z')
    _old=$IFS; IFS=','
    # 关掉通配：NO_PROXY 里合法写着 *.corp 这类条目，不关的话 for 会把它当 glob 展开成
    # 当前目录里的文件名（实测 `*.corp` 变成 alpha.corp,beta.corp），值就被改写了。
    _had_f=0; case $- in *f*) _had_f=1;; esac
    set -f
    for _p in $_existing; do
        _pt=$(printf '%s' "$_p" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -n "$_pt" ] || continue
        # 单引号不是合法的主机名/IP 字符，且会破坏 proxy.env 的 source 转义幂等——直接丢弃该条目。
        case "$_pt" in *"'"*) continue;; esac
        _pl=$(printf '%s' "$_pt" | tr 'A-Z' 'a-z')
        case ",$_lower," in
            *",$_pl,"*) ;;
            *) _out="${_out:+$_out,}$_pt"; _lower="${_lower},${_pl}" ;;
        esac
    done
    IFS=$_old
    [ "$_had_f" -eq 1 ] || set +f
    printf '%s' "$_out"
}

# shell 安全转义：单引号包裹、内部单引号转义。proxy.env 会被 hook 在每个新
# shell 里 source，未转义的 $、反引号会被执行（值变代码）。
shell_escape_sq() {
    _sq="$1"
    _sq=$(printf '%s' "$_sq" | sed "s/'/'\\\\''/g")
    printf "'%s'" "$_sq"
}

# 这一项是不是我们默认例外集里的（大小写不敏感）。用于精确回收 NO_PROXY：
# 只减掉我们加进去的那几项，用户自己写的条目原样留着。
is_default_no_proxy_entry() {
    _must=$(printf '%s' "$DEFAULT_NO_PROXY" | tr -d ' ' | tr 'A-Z' 'a-z')
    _me=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    case ",$_must," in *",$_me,"*) return 0 ;; esac
    return 1
}

# 安装快照（prev.env）里本来就记着这一项吗？记着 = 使用者自己的，我们永远不许动。
# 光看"形状像不像我们的"不够：用户自己也完全可能写 NO_PROXY=localhost，
# 或者用 mitmproxy 挂 http://127.0.0.1:8080。只看形状会在 off 态把它定时删掉。
# 快照格式是「变量名 TAB 值」（见 env.sh 的 snapshot_prev_env），不是 NAME=value——
# 按 = 解析会一行都匹配不上，于是保护全部落空（用户自己的条目会被当默认项剥掉）。
_snapshot_value_of() {
    # $1 = 变量名；输出该变量在快照里记下的值（去掉外层单引号）。没有则输出空。
    [ -f "$PREV_ENV" ] || return 0
    awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$PREV_ENV" 2>/dev/null |
        sed "s/^'\(.*\)'$/\1/"
}

no_proxy_entry_in_snapshot() {
    [ -f "$PREV_ENV" ] || return 1
    _nes=$(_snapshot_value_of NO_PROXY)
    [ -n "$_nes" ] || return 1
    _nes_me=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    _nes_list=$(printf '%s' "$_nes" | tr -d ' ' | tr 'A-Z' 'a-z')
    case ",$_nes_list," in *",$_nes_me,"*) return 0 ;; esac
    return 1
}

# 这个值是不是本工具写下的：只有 127.0.0.1 本机地址才算我们的，
# 用户或公司工具写的其他地址一律不动。
# 光看形状不够——用户自己也可能挂 mitmproxy（http://127.0.0.1:8080）；
# 安装快照里本来就有这个值，那就是他的，永远不许我们删（与 Win 侧分层同形）。
is_owned_proxy_value() {
    case "$1" in
        "$OWNED_HTTP_PREFIX"*|"$OWNED_HTTP6_PREFIX"*) ;;
        *) return 1 ;;
    esac
    # 快照里存的是单引号转义后的值（见 shell_escape_sq），所以两种写法都要认。
    # 逐变量比对，而不是"整份文件里 grep 一下"：后者会把 NO_PROXY 里恰好含同一串
    # 文本的情况也算进来，而且依赖分隔符形式，格式一改保护就静默失效。
    #
    # 快照文件**不存在**：按"全新安装、用户原本没设过代理变量"处理，这个本机地址就是我们的。
    # 这条不能改成"不认领"——那样每次全新安装注入的值都清不掉，off 态会永远残留一套变量。
    if [ ! -f "$PREV_ENV" ]; then
        return 0
    fi
    _iov_want=$(printf '%s' "$1")
    _iov_readable=0
    for _iov_v in $PROXY_ADDR_VAR_NAMES; do
        _iov_have=$(_snapshot_value_of "$_iov_v")
        if [ -n "$_iov_have" ]; then
            _iov_readable=1
            [ "$_iov_have" = "$_iov_want" ] && return 1
        fi
    done
    # 文件在、但一个变量都没读出内容：说明这份快照不可用（被截断 / 权限 / 格式坏了），
    # 此时**不认领**。这与 Windows 侧 Test-SnapshotRecorded 的三态化同一条：
    # 读不出来若落成"是我们的"，后续会把这个本机地址删掉——而那可能正是使用者自己挂的
    # mitmproxy。两个方向的代价不对称：不认领最多多留一个值（下一轮还会再判），
    # 认错了则删掉他本来能用的东西，而且没有任何提示。
    [ "$_iov_readable" = "1" ] || return 1
    return 0
}

# 成员判断：$1 在空格分隔表 $2 里则返回 0
_in_list() {
    case " $2 " in *" $1 "*) return 0;; *) return 1;; esac
}

# ------------------------------------------------------------------------------
# 5. 入口用法判定（纯函数，两端同形）
# ------------------------------------------------------------------------------
# 入口所有的用法错误都从这里出：输出空串 = 用法正确；输出该报的错 = 用法错误
# （入口打印它、退出 2）。输入是四样归一化后的东西：
#   USAGE_COMMAND       用户要的命令（小写；空 = 监控模式）
#   USAGE_COMMAND_COUNT 命令给了几个（>1 = 用法错误）
#   USAGE_SWITCHES      用户给的开关名（purge / yes，空格分隔）
#   USAGE_EXTRA         不认识的参数（空格分隔）
# 输入用全局变量传：bash 3.2 没有 nameref，函数收不了数组。
# 抽成纯函数是有原因的：直接跑入口验"合法用法必须放行"会真的装、卸、起监控，
# 副作用落在用户机器上（卸载删日志、更新改安装区），这类断言根本没法写。
# 判定本身没有副作用，纯函数才能把"必须拒"和"必须放行"两个方向都钉住。
usage_error() {
    if [ "${USAGE_COMMAND_COUNT:-0}" -gt 1 ]; then
        printf '一次只给一个命令。'
        return 1
    fi
    if [ -n "${USAGE_EXTRA:-}" ]; then
        printf '无法识别的参数：%s' "$USAGE_EXTRA"
        return 1
    fi
    # 开关必须跟着它的命令：--purge 只配 uninstall，--yes 只配 update。
    # 单独给会一路落到监控模式：用户以为在清日志或在答"是"，工具却把监控起来了。
    case " ${USAGE_SWITCHES:-} " in
        *" purge "*)
            if [ "${USAGE_COMMAND:-}" != "uninstall" ]; then
                printf -- '--purge 只在卸载时才有意义：它表示连日志一起删。请用 uninstall --purge。'
                return 1
            fi
            ;;
    esac
    case " ${USAGE_SWITCHES:-} " in
        *" yes "*)
            # --yes 在两处有意义：跳过更新的确认，以及在**没法提问的环境里**明确表达
            # "我知道我在做什么"（卸载）。后者不是多余：卸载在非交互环境下会被拒绝，
            # 没有这个开关，脚本和 CI 就永远卸不掉。
            if [ "${USAGE_COMMAND:-}" != "update" ] && [ "${USAGE_COMMAND:-}" != "uninstall" ]; then
                printf -- '--yes 只在检查更新或卸载时才有意义：它表示跳过确认。请用 update --yes 或 uninstall --yes。'
                return 1
            fi
            ;;
    esac
    return 0
}

# 版本比较：按 . 分段逐段数值比。输出 1（A 新）/ 0（相等）/ -1（A 旧）。
compare_versions() {
    awk -v a="$1" -v b="$2" 'BEGIN{
        na=split(a,pa,"."); nb=split(b,pb,".");
        n=(na>nb?na:nb);
        for(i=1;i<=n;i++){ xa=(i<=na?pa[i]+0:0); xb=(i<=nb?pb[i]+0:0);
            if(xa>xb){print 1; exit} if(xa<xb){print -1; exit} }
        print 0 }'
}

# ------------------------------------------------------------------------------
# 屏幕渲染层：能不能就地重画、怎么画一帧、怎么进出、怎么等一个键。
#
# 为什么单独一层：一次性输出（打印完就结束）不需要这些；一旦要"自己动"，
# 就必须解决三件事——不能清屏（清屏就是闪）、只画变化的行、光标别乱跳。
# 放进 base 是因为 ops 与 future 的页面都要用，放进 ops 会让别的层反向依赖。
# ------------------------------------------------------------------------------

# 能不能做「就地重画」。这是所有刷新逻辑的前置判据，只有这一个实现。
# 四种情况不能画：
#   输出被重定向（管道/文件）—— 控制字符会原样写进文件，污染输出；
#   没有真实终端 —— 光标定位会失效；
#   窗口太窄/太矮 —— 内容放不下，重画必然滚屏，滚屏后绝对定位全部错位。
# 参数：$1 = 这一帧要占几行；$2 = 这一帧最宽行多少列（0 表示不检查宽度）
test_can_draw_screen() {
    _tcd_lines="${1:-0}"
    _tcd_width="${2:-0}"
    [ -t 1 ] || return 1
    [ -t 0 ] || return 1
    _tcd_w=$(tput cols 2>/dev/null || echo 80)
    _tcd_h=$(tput lines 2>/dev/null || echo 24)
    case "$_tcd_w" in ''|*[!0-9]*) _tcd_w=80;; esac
    case "$_tcd_h" in ''|*[!0-9]*) _tcd_h=24;; esac
    [ "$_tcd_w" -ge "$SCREEN_MIN_WIDTH" ] || return 1
    [ "$_tcd_h" -ge "$SCREEN_MIN_HEIGHT" ] || return 1
    if [ "$_tcd_lines" -gt 0 ] && [ $((_tcd_lines + SCREEN_BOTTOM_MARGIN)) -gt "$_tcd_h" ]; then
        return 1
    fi
    # 宽度也要按这一帧的实际最宽行判：折行会让后面每一行的绝对定位错位。
    if [ "$_tcd_width" -gt 0 ] && [ "$_tcd_width" -gt "$_tcd_w" ]; then
        return 1
    fi
    return 0
}

# 把一帧画到屏幕上，返回这一帧占了几行。
# 参数：$1 = 上一帧的内容（换行分隔，空表示没有上一帧）；$2 = 这一帧的内容。
#
# 关键点：内容没变的行一个字节都不发 —— 这是「不闪」的本质。
# 窗口尺寸一变就整帧重画：尺寸变化后终端会把已有内容重新折行，
# 屏幕上"第几行是什么"整个失效，而这一层的记账是按逻辑行算的。
write_screen_frame() {
    _wsf_old="$1"
    _wsf_new="$2"
    [ -t 1 ] || return 0
    _wsf_n=$(printf '%s\n' "$_wsf_new" | grep -c '' || echo 0)
    [ "$_wsf_n" -gt 0 ] || return 0

    # 尺寸变化检测
    _wsf_w=$(tput cols 2>/dev/null || echo 0)
    _wsf_h=$(tput lines 2>/dev/null || echo 0)
    if [ "$_wsf_w" != "${_SCREEN_LAST_W:-}" ] || [ "$_wsf_h" != "${_SCREEN_LAST_H:-}" ]; then
        _SCREEN_LAST_W="$_wsf_w"
        _SCREEN_LAST_H="$_wsf_h"
        _wsf_old=""
    fi

    # 逐行比较：只输出变化的行。用纯 bash 比较，不起子进程（热路径）。
    _wsf_buf=""
    _wsf_i=0
    _wsf_old_rest="$_wsf_old"
    while IFS= read -r _wsf_line; do
        _wsf_i=$((_wsf_i + 1))
        if [ -n "$_wsf_old_rest" ]; then
            _wsf_prev="${_wsf_old_rest%%$'\n'*}"
            case "$_wsf_old_rest" in
                *$'\n'*) _wsf_old_rest="${_wsf_old_rest#*$'\n'}" ;;
                *) _wsf_old_rest="" ;;
            esac
        else
            _wsf_prev=""
        fi
        [ "$_wsf_line" = "$_wsf_prev" ] && continue
        _wsf_buf="$_wsf_buf${_ESC}[${_wsf_i};1H${_wsf_line}${_ESC}[K"
    done <<EOF
$_wsf_new
EOF

    [ -n "$_wsf_buf" ] || return "$_wsf_n"
    # 藏光标 → 一次写出 → 恢复光标。整帧拼成一个字符串再写，快且没有"画到一半"的中间态。
    printf '%s' "${_ESC}[?25l${_wsf_buf}${_ESC}[?25h"
    return "$_wsf_n"
}

# 进/出「屏幕已接管」状态。只有进入时清一次屏；刷新循环里一次都不许清——清屏就是闪的根源。
enter_screen() {
    test_can_draw_screen || return 1
    printf '%s' "${_ESC}[2J${_ESC}[H"
    return 0
}

exit_screen() {
    # 光标放到底部并恢复可见：任何退出路径都要能到这里（Ctrl+C 走 trap）。
    _es_bottom=$(tput lines 2>/dev/null || echo 24)
    printf '%s' "${_ESC}[${_es_bottom};1H${_ESC}[?25h"
    return 0
}

# 等一个键，最多 $1 秒。返回：
#   Quit  —— 0 / q / Q
#   其它  —— 按下的字符（调用方自己决定怎么处理）
#   空    —— 超时没按键，或按的是功能键（方向键之类）
#
# DIVERGE(Mac): bash 3.2 的 read -t 只认整数秒，超时与 EOF 都返回 1，
#   所以要用"返回值 > 128 还是 == 1 且变量为空"两个信号来区分"超时"和"读不到"。
#   这一点与 Windows 侧不同（那边用 Console.KeyAvailable 轮询）。
wait_screen_key() {
    _wsk_sec="${1:-1}"
    _wsk_c=""
    _wsk_v=""
    _wsk_start=$(date +%s)
    if IFS= read -r -s -n 1 -t "$_wsk_sec" _wsk_v 2>/dev/null; then
        _wsk_c="$_wsk_v"
    else
        _wsk_c=""
        # read -t 超时会立即返回（rc>128）。如果 stdin 根本不可读（EOF、无 tty），
        # read 会立刻返回 rc=1 而**不是**等满超时——那样调用方的 while 会毫无间隔地
        # 空转，把一个核吃满且永远退不出去（实测一秒能转几千次）。
        # 所以这里必须自己把时间补足，保住"每一轮至少歇 _wsk_sec 秒"这条不变量。
        _wsk_now=$(date +%s)
        _wsk_waited=$((_wsk_now - _wsk_start))
        if [ "$_wsk_waited" -lt "$_wsk_sec" ]; then
            sleep "$((_wsk_sec - _wsk_waited))" 2>/dev/null || true
        fi
    fi
    case "$_wsk_c" in
        ''|$'\r'|$'\n') return 0 ;;
        '0'|'q'|'Q') printf '%s' 'Quit'; return 0 ;;
    esac
    printf '%s' "$_wsk_c"
    return 0
}
