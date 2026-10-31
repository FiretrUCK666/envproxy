# ==============================================================================
#  help.sh — 菜单与帮助层：菜单表、菜单渲染、帮助主题、帮助渲染、高级功能
#  菜单编号的唯一权威处是下面的 MENU_ITEMS；散文里写「选 N」时一律从这张表取。
#  这是**唯一**一处：写死的数字会在菜单重排后指向错的命令，那不是排版问题，
#  是把人引到一个会改坏东西的动作上。
# ==============================================================================

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
    '3|窗口|这个窗口不要翻墙 / 用公司的代理'
    '4|命令行|某条命令不想翻墙'
    '5|软件|某个程序还是翻不了墙'
    '6|出问题|出问题了：怎么查、怎么报'
    '7|上不了网|上不了网（关了翻墙软件之后）'
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

# 可用的编号范围，从表里算：加一条主题就自动变成 "有 1-7"，不会留下写死的旧范围。
# 菜单可用的编号，从表里算：加一项就自动变成 "1-8 和 0"，不会留下写死的旧范围。
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

# 底部那一行「有 1-7」/「有 1 2 3 4 6 7 8」。
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
        h) echo 2 ;;
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
        # 只认两列行（r / rc）。这里用 if 而不是 case：这段嵌在
        # $( ... | while read ... ) 里，而 macOS 自带的 bash 3.2 在这个位置
        # 对 case 的分支终止符会报 syntax error（CI 实测），if 不受影响。
        if [ "$_hbk_c" != "r" ] && [ "$_hbk_c" != "rc" ]; then continue; fi
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
# 帮助里要印的项目地址。取不到就返回空串——宁可少一句，也不能印一个打不开的链接。
_proj_home_url() {
    get_project_home 2>/dev/null || true
}

_proj_issue_url() {
    get_project_issues 2>/dev/null || true
}


# 帮助正文住在 `cat <<'TOPIC'` 里——**单引号 heredoc，一个变量都不展开**。
# 所以这一段里的编号与名字只能写字面量，不能用 $(menu_ref ...)：
# 写了就会原样打印成 "$(menu_ref install)"，比写错数字更糟（用户看到的是代码）。
# 代价是这一段会与菜单表各自维护，于是门禁 15 核对这里出现的「选 N（名字）」
# 与菜单表逐项一致——写死的部分由门禁兜住，而不是靠人记得。
_help_topic_body() {
    case "$1" in
    1) cat <<'TOPIC'
h 它做什么
t 你的翻墙软件只管浏览器，不管终端里的 git、npm、curl。
t 这个工具补上这一段：翻墙软件一开，它们跟着能翻；一关，自动恢复。
t 你什么都不用记，也不用每次敲开关。
h 它怎么知道你现在在翻墙
t 每 2 到 3 秒看一次，要同时满足三条才算：
i 1. 你电脑上确实有程序开着一个口子（端口）在等连接；
i 2. 那个口子确实是个翻墙代理，会按规矩回应；
i 3. 它确实连得到外面，试 6 个端点（几个常用的检测网址）任意一个通就算。
t 三条全过才动手。所以你本机开着网页服务、开发服务器都不会被误认。
t 它不认品牌、不认程序名、不认端口号——那些只用来加快查找。
h 它是谁做的、在哪
t 这是开源项目。代码、新版、问题反馈都在这一个地址：
TOPIC
    printf 'c %s\n' "$(_proj_home_url)"
    cat <<'TOPIC'
TOPIC
    ;;
    2) cat <<'TOPIC'
h 装完之后，按窗口分三种情况
i 1. 装完之后新开的窗口
t2 启动时读到的就是当前状态，什么都不用做。
i 2. 装完之后开的窗口，后来翻墙软件又开了或关了
t2 按一次回车即可。
i 3. 装之前就已经开着的窗口
t2 同步代码还没装进去。在那个窗口里敲下面这一条，或者重开窗口：
rc zsh / bash|. ~/.envproxy/prompt-sync.sh
t 开头的点号和后面的空格都不能少；fish 不支持。
h 为什么要按一次回车
t 每个程序只在启动那一刻读一次「该走哪个代理」，读完就固定了。
t 之后系统再改，已经在跑的窗口不会跟着变。
t 这个工具挑的时机是每次命令跑完、等你回到能打字的时候同步——
t 你本来就一直在敲命令，所以不用专门做什么。
TOPIC
    ;;
    3) cat <<'TOPIC'
h 一、让这个窗口一直不翻墙
rc zsh / bash|export ENVPROXY_TERM=off
t 下次回到提示符才生效，别的窗口照旧跟着翻墙软件走。
w 别只 unset 一个拼写：mac 上大写小写是两个变量，各清一份。
h 二、让这个窗口用公司的代理
t 公司代理和自动跟随只能选一个，先做第一节再设地址（反了会被盖掉）。
t 地址端口问公司 IT 要，不是翻墙软件那个（下面 A 换成它）：
rc zsh / bash|export HTTPS_PROXY=http://A:端口
t 上面这条够 git、curl、npm 用。有程序还是不认，就再抄下面这条：
rc zsh / bash|export ALL_PROXY=http://A:端口; export NODE_USE_ENV_PROXY=1
h 三、改回自动跟随
rc zsh / bash|unset ENVPROXY_TERM
t 清掉 ENVPROXY_TERM 就都撤回了。改回来公司地址会被盖掉——那是对的，
t 表示回到自动；地址没删，只是不用。
t fish 不支持这些配置文件，上面的开关对它无效。
TOPIC
    ;;
    4) cat <<'TOPIC'
h 每个工具写法不一样，没有通用的一条命令
h curl
c curl --noproxy "*" https://example.com
h git
c git -c http.proxy= -c https.proxy= clone https://github.com/git/git.git
t 等号后留空，这条就不用代理；写别的值，就改用那个代理。
h npm
c npm --noproxy=registry.npmjs.org install typescript
w 注意：只认具体网址，写 * 没用，而且不报错，请求照常翻墙。
t 写成 --no-proxy 会被理解成关闭代理，也不是你要的效果。
t 另外 npm 只认 HTTPS_PROXY，不认 HTTP_PROXY。
h wget
c wget --no-proxy https://example.com
h docker
t 没有单条命令的写法，改 Docker 自己的设置（Settings 里的 Proxies）。
h 这些参数是各工具自己的，不是这个工具提供的
t 不加参数时，它们读的才是这个工具写进系统的代理。
TOPIC
    ;;
    5) cat <<'TOPIC'
h 这个平台基本不会遇到
t 从 Dock 或访达启动的程序，读的是 launchctl 设的变量，本工具一直在设。
t 所以它们开起来就能拿到代理，不需要额外做一个启动器。
h 如果你确实遇到某个程序还是翻不了墙
t 先在终端里用同一条命令试：够说明问题的是那个程序自己，不是这个工具。
c HTTPS_PROXY=$HTTPS_PROXY open -a "程序名"
t 它自己带代理设置项的，直接填本工具的地址（菜单选 2（查看状态）能看到）。
h Windows 版才有「高级功能」
t 那边的资源管理器拿不到登录之后才注入的值，必须给软件配一个启动器。
t 这是平台差异，不是功能有没有做全。
TOPIC
    ;;
    6) cat <<'TOPIC'
h 先按这个顺序查，多数问题到第二步就好了
i 1. 在出问题的窗口里敲下面这一条，看有没有地址
t2 有地址 = 设好了；空的 = 没设上，重开一个窗口试试。
rc zsh / bash|echo $HTTPS_PROXY
i 2. 看菜单最上面那行写的什么
t2 写「未运行」就选 1（安装 / 修复）。
i 3. 两个常见误会
t2 npm 只认 HTTPS_PROXY，不认 HTTP_PROXY。
t2 「翻墙代理」有、「代理变量」无 = 翻墙软件在跑、本工具被停了，不是坏了。
h 还是不行：把问题报上去
t 菜单选 8（问题反馈）。它先问你四句话，再自动补上这台机器的情况，
t 存成一个文件、把路径复制好。你不用找日志，也不用敲命令。
t 然后把文件内容贴到下面这个地址（本项目只在这里收问题）：
TOPIC
    printf 'c %s\n' "$(_proj_issue_url)"
    cat <<'TOPIC'
t 打不开就把网址手动敲进浏览器：
TOPIC
    printf '  %s\n' "$(_proj_home_url)"
    cat <<'TOPIC'
h 想彻底删掉它
t 菜单选 7（一键恢复）。会问你要不要留日志。
h 不开菜单也能用（写脚本、远程连过来的时候）
r 开关|install status stop uninstall update help report
r 补充|--yes 跳过确认   --purge 连日志删   repair-profile 摘标记
c bash envproxy.sh status
t self-test 是 mac 独有（Windows 那份由开发侧跑）。
t 不碰 ~/.zshrc 和环境变量，只报告结果。
TOPIC
    ;;

    7) cat <<'TOPIC'
h 先分清是哪种上不了网
t 浏览器打不开、但别的程序照常 = 浏览器这边的问题。
t 什么都连不上 = 网络本身的问题，跟这个工具无关。
h 最常见的原因：翻墙软件没关干净
t 多数翻墙软件退出时会把自己写进系统的设置撤掉。
t 被强制关机、断电、或者直接点了叉，就没来得及撤。
t 那条设置还在，浏览器就照旧去找一个
t 已经不存在的程序，于是国内网站也打不开。
h 怎么自己修
t 进主菜单的高级功能，再选网络救援。
t 它会说清查到什么；能修的问你一句才动手，
t 改之前先备份。
t 修完把浏览器关掉重开一次再看。
h 什么东西它不会动
t 公司、学校给你的代理，它一个字节都不碰。
t 被管理员统一管着的也不碰，那种改了也会被改回去。
t 它只修「指向本机、但程序已经不在了」的那种。
h 修错了想改回去
t 再进那一屏，按 r 回车就能还原成修之前的样子。
h 还不行
t 用主菜单的「问题反馈」生成报告，贴到项目页面。
t 报告里已经有网络体检的结论，不用你另外描述。
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
    # 引导语与清单之间空一行：不然它会被读成清单的第一条。
    # 与帮助正文、状态页同一套规矩——引导语负责起头，内容另起一段。
    _line_blank
    # 编号列宽按最大编号算，让标题那一列永远对齐（与 Windows 侧同一算法）：
    # 写死两个空格时，编号超过 9 会把那一行整体右推一格，清单就从整齐变成参差。
    _rhi_w=1
    for _rhi_k in "${HELP_TOPIC_KEYS[@]}"; do
        if [ "${#_rhi_k}" -gt "$_rhi_w" ]; then _rhi_w=${#_rhi_k}; fi
    done
    for _rhi_k in "${HELP_TOPIC_KEYS[@]}"; do
        _rhi_pad="$_rhi_k"
        while [ "${#_rhi_pad}" -lt "$_rhi_w" ]; do _rhi_pad=" $_rhi_pad"; done
        _seg cmd "  $_rhi_pad"
        _seg value "   $(_help_topic_title "$_rhi_k")"
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
# 空行由结构决定，正文里不写 b（与 Windows 侧同一套规则）。
#
# 规则两条：
#   一、标题上下各空一行（第一个标题的上面不空，它紧接页头）
#   二、表格块（连续的 r/rc/m 行）前后各空一行
# 其余一律不空：正文连续读才顺；编号条目之间也不空，它们是一个列表。
#
# 手写空行的老做法是"有的地方记得、有的地方忘了"，屏幕上就是一段挤一段松。
# 空行由结构决定，正文里不写 b（与 Windows 侧同一套规则）。
#
# 规则两条：
#   一、标题上下各空一行（第一个标题的上面不空，它紧接页头）
#   二、表格块（连续的 r/rc/m 行）**前后**各空一行，块内行与行之间不空
# 其余一律不空：正文连续读才顺；编号条目之间也不空，它们是一个列表。
#
# 为什么要把整段读进来再处理：判断"表格块结束了没有"必须能看见下一行。
# 边读边吐的写法只能看上一行，于是每一行后面都补了空行——表格被拆成一格一段，
# 屏幕上就是「开关」「空行」「补充」「空行」这种散开的样子。
_help_apply_spacing() {
    _hs_all=$(cat)
    # 先拆成数组（macOS 自带 bash 3.2 没有 mapfile，用 while read 累加）
    _hs_i=0
    while IFS= read -r _hs_l; do
        _hs_c=${_hs_l%% *}
        if ! _help_code_valid "$_hs_c"; then _hs_c="t"; fi
        # 手写的空行一律丢掉，空行只由下面按结构补
        [ "$_hs_c" = "b" ] && continue
        _hs_i=$((_hs_i + 1))
        eval "_hs_line$_hs_i=\$_hs_l"
    done <<EOF
$_hs_all
EOF
    _hs_n=$_hs_i
    _hs_k=1
    _hs_prev_tbl=0
    _hs_last_blank=0
    while [ "$_hs_k" -le "$_hs_n" ]; do
        eval "_hs_cur=\$_hs_line$_hs_k"
        _hs_c=${_hs_cur%% *}
        if ! _help_code_valid "$_hs_c"; then _hs_c="t"; fi
        _hs_tbl=0
        case "$_hs_c" in r|rc|m) _hs_tbl=1 ;; esac
        # 下一行的类型（用来判断块是否结束）
        _hs_nxt_tbl=0
        _hs_nxt_c=""
        if [ "$_hs_k" -lt "$_hs_n" ]; then
            eval "_hs_nxt=\$_hs_line$((_hs_k + 1))"
            _hs_nxt_c=${_hs_nxt%% *}
            if ! _help_code_valid "$_hs_nxt_c"; then _hs_nxt_c="t"; fi
            case "$_hs_nxt_c" in r|rc|m) _hs_nxt_tbl=1 ;; esac
        fi
        # 标题前 / 表格块开始前：空一行（上一行已经是空行就不补，否则会连出两行）
        if [ "$_hs_k" -gt 1 ] && [ "$_hs_last_blank" = "0" ]; then
            if [ "$_hs_c" = "h" ] || { [ "$_hs_tbl" = "1" ] && [ "$_hs_prev_tbl" = "0" ]; }; then
                echo "b "
                _hs_last_blank=1
            fi
        fi
        echo "$_hs_cur"
        _hs_last_blank=0
        # 标题后 / 表格块结束后：空一行
        if [ "$_hs_c" = "h" ] || { [ "$_hs_tbl" = "1" ] && [ "$_hs_nxt_tbl" = "0" ] && [ "$_hs_k" -lt "$_hs_n" ]; }; then
            echo "b "
            _hs_last_blank=1
        fi
        _hs_prev_tbl=$_hs_tbl
        _hs_k=$((_hs_k + 1))
    done
    return 0
}

format_help_topic() {
    _ht_title=$(_help_topic_title "$1")
    [ -z "$_ht_title" ] && return 1
    _SEG_COLORED=0
    _SEG_LINE=""
    echo "================ 帮助 $1 · $_ht_title ================"
    echo ""
    _HELP_BLOCK=$(_help_topic_body "$1" | _help_apply_spacing)
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
# 分组只影响打印顺序；编号按使用频率从上往下连续排（1-4 日常、5 进阶、6-7 维护、8 支持、0 退出）。
# 子命令为空表示"不跑任何东西"（退出项）。分派直接读这一列，
# 不许再另写一份 case——两份清单必然漂移，症状是"表里加了、点了没反应"。
# 格式固定为五个字段、四条竖线；少一条竖线字段会静默错位（菜单照常打印、不报错，
# 用户看到的却是错的内容）。所以下面带一道校验，格式不对就当场报错。
#
# 两侧共用同一套编号：同名项在两台机器上必须是同一个数字（用户可能两台都用）。
# 编号 5「高级功能」两侧同名同号；里面装的东西按平台不同（mac 没有启动器需求，
# 那边只放「网络救援」）。DIVERGE(Mac): 从 Dock 启动的程序本来就拿得到 launchctl
# 设的变量，不需要额外做启动器——所以这边的高级功能里没有建图标那一项。
MENU_ITEMS=(
    '1|安装 / 修复|第一次用选它；觉得不对劲也选它|日常|install'
    '2|查看状态|现在什么情况，一眼看清|日常|status'
    '3|检查更新|有新版先告诉改了什么，同意才装|日常|update'
    '4|帮助|忘了怎么用就看它|日常|help'
    '5|高级功能|上不了网的时候用这个|进阶|advanced'
    '6|停止监控|先停掉，下次开机自己回来|维护|stop'
    '7|一键恢复|彻底卸载，回到没装之前|维护|uninstall'
    '8|问题反馈|出问题了，一键生成一份报告|支持|report'
    '0|退出|关掉这个窗口|退出|'
)

# 菜单编号/名字的唯一权威处就是上面那张表的第 1、2 列。散文里写"选 N（名字）"时
# **一律从这张表取**，不许再写字面量——菜单项一旦重排，写死的数字就指向错的命令，
# 那不是排版问题，是把人引到一个会改坏东西的动作上。
#
# 按第 5 列的动作名查，不按编号查：动作名是稳定的语义标识，编号只是它的显示形式。
# 查不到时**大声失败**（非零退出 + stderr），不静默返回 0——返回 0 会渲染成
# "选 0（退出）"，看着还挺像真的，而那正是最坏的一种误导。
_menu_field_by_action() {
    _mfb_want="$1"
    _mfb_col="$2"
    for _mfb_i in "${MENU_ITEMS[@]}"; do
        if [ "$(printf '%s' "$_mfb_i" | cut -d'|' -f5)" = "$_mfb_want" ]; then
            printf '%s' "$(printf '%s' "$_mfb_i" | cut -d'|' -f"$_mfb_col")"
            return 0
        fi
    done
    printf '没有动作名为 %s 的菜单项\n' "$_mfb_want" >&2
    return 1
}
menu_key() { _menu_field_by_action "$1" 1; }
menu_name() { _menu_field_by_action "$1" 2; }

# 拼出用户看到的那一小段："选 2（查看状态）"。编号与名字都来自同一张表，
# 于是重排或改名时屏幕上的提示会自己跟上。
menu_ref() {
    _mr_k=$(menu_key "$1") || return 1
    _mr_n=$(menu_name "$1") || return 1
    printf '选 %s（%s）' "$_mr_k" "$_mr_n"
}

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
        # 状态页同理，而且它是实时刷新的：起子进程的话，子进程退出后屏幕就停在最后一帧。
        # 与 Windows 侧对 Status 的处理同一条理由。
        if [ "$_msub" = "status" ]; then
            show_status_live
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

# ==============================================================================
#  高级功能与网络救援（界面层）
#
#  这一层只做界面：把 doctor 层的结论画出来、问一句、把用户的意思交回去。
#  判定与修复全在 doctor 层（那边才允许碰系统设置）。
#  与 Windows 侧同名同序（shortcut.ps1 的 Show-AdvancedMenu / Show-RescuePage），
#  两平台同一件事必须同一句话。
#
#  DIVERGE(Mac): Windows 的高级功能里另有「建走代理的图标」「管理图标」「看中继」，
#  mac 都没有——从 Dock 启动的程序本来就拿得到 launchctl 设的变量，不需要启动器。
#  所以这边的高级功能只有一项，但菜单项本身与 Win 同名同号（编号 5）。
# ==============================================================================

# 高级功能二级菜单。编号从这张表派生，散文里不写死数字。
# 高级功能里的菜单项表。**打印与分派共用这一张**：加一项就自动出现在屏幕上、
# 也自动能敲，不会出现"表里加了、打印忘了"或"打印有、敲了没反应"。
# 与主菜单的 MENU_ITEMS 同一条道理。
#
# 第 2 列是模块：同一个功能的几种操作归一组，插在这里只影响分组显示，
# 不影响编号——编号是用户要敲的数字。
ADVANCED_ITEMS=(
    '1|rescue|网络救援|浏览器打不开网页的时候，先来这里查一下'
)

# 模块顺序与各自的说明。加一个模块只改这张表。
ADVANCED_MODULES=(
    'rescue|浏览器上不了网的时候'
)

# 某个模块的"为什么需要它"。三条以 | 分隔，与上面的表分开维护：
# 说明是整段散文，塞进表格行会把那张表读成一团。
_advanced_module_why() {
    case "$1" in
        rescue) printf '%s\n' \
            '翻墙软件被强行关掉（关机、断电、直接点叉）时，它写进系统的那条设置' \
            '可能没来得及撤掉。浏览器照旧把请求发给一个已经不存在的程序，' \
            '于是连国内网站都打不开——线没断，是路指错了。' ;;
    esac
}

# 某个模块的"要注意"。与 why 同一个理由分开维护。
_advanced_module_note() {
    case "$1" in
        rescue) printf '%s\n' \
            '只修「指向本机、但那个程序已经不在」的那一种。' \
            '公司/学校给你的代理，它一个字节都不碰。' ;;
    esac
}

# 高级功能二级菜单。编号、名字、说明全部从 ADVANCED_ITEMS 取，不手写。
show_advanced_menu() {
    while :; do
        clear_screen_safe
        style_out title "======== 高级功能 ========"
        # 名字列按最宽的名字自动对齐。写死宽度会在改文案后错位——
        # 错位之后「编号—名字—说明」三列的读法就散了。
        _adm_nw=0
        for _adm_i in ${ADVANCED_ITEMS[@]+"${ADVANCED_ITEMS[@]}"}; do
            _adm_rest=${_adm_i#*|}; _adm_rest=${_adm_rest#*|}
            _adm_nm=${_adm_rest%%|*}
            _adm_w=$(_display_width "$_adm_nm")
            [ "$_adm_w" -gt "$_adm_nw" ] && _adm_nw="$_adm_w"
        done
        for _adm_m in ${ADVANCED_MODULES[@]+"${ADVANCED_MODULES[@]}"}; do
            _adm_mid=${_adm_m%%|*}
            _adm_mtitle=${_adm_m#*|}
            # 这个模块下有没有项？没有就整段不印（表里留着也不会出现空标题）。
            _adm_has=0
            for _adm_i in ${ADVANCED_ITEMS[@]+"${ADVANCED_ITEMS[@]}"}; do
                _adm_k=${_adm_i%%|*}; _adm_r=${_adm_i#*|}; _adm_mo=${_adm_r%%|*}
                [ "$_adm_mo" = "$_adm_mid" ] && _adm_has=1
            done
            [ "$_adm_has" = "1" ] || continue
            echo ""
            style_out heading "  $_adm_mtitle"
            echo ""
            _advanced_module_why "$_adm_mid" | while IFS= read -r _adm_w; do
                style_out text "    $_adm_w"
            done
            echo ""
            for _adm_i in ${ADVANCED_ITEMS[@]+"${ADVANCED_ITEMS[@]}"}; do
                _adm_k=${_adm_i%%|*}; _adm_r=${_adm_i#*|}
                _adm_mo=${_adm_r%%|*}; _adm_r=${_adm_r#*|}
                _adm_nm=${_adm_r%%|*}; _adm_hint=${_adm_r#*|}
                [ "$_adm_mo" = "$_adm_mid" ] || continue
                _adm_gap=$((_adm_nw - $(_display_width "$_adm_nm"))); [ "$_adm_gap" -lt 0 ] && _adm_gap=0; _adm_pad=$(printf "%*s" "$_adm_gap" "")
                # 只给**编号**上色（绿 = 你要敲的东西），名字与说明用正文色。
                # 整行同色会让编号混进正文里，用户得逐字找；与 Windows 侧同一条规则。
                style_out_nonewline cmd "    ${_adm_k}"
                style_out_nonewline item "  ${_adm_nm}${_adm_pad}   ${_adm_hint}"
                echo ""
            done
            # 空行只在这一段前面加一次：写在循环里会每行都空一行。
            if _advanced_module_note "$_adm_mid" | grep -q .; then
                echo ""
                _advanced_module_note "$_adm_mid" | while IFS= read -r _adm_n; do
                    [ -n "$_adm_n" ] || continue
                    style_out dim "    $_adm_n"
                done
            fi
        done
        echo ""
        style_out dim "  输编号后回车执行    0 = 返回主菜单"
        _adm_ans=""
        if ! read -r _adm_ans 2>/dev/null; then
            # 非交互（管道/重定向）：把这一屏打出来就够了，不要死循环等输入。
            echo "  管道里没法交互，请直接用开关（见 help）。"
            return 0
        fi
        case "$_adm_ans" in
            ''|0|q|Q) return 0 ;;
        esac
        # 分派查同一张表：屏幕上有的编号一定敲得到，没有的一定敲不到。
        _adm_hit=0
        for _adm_i in ${ADVANCED_ITEMS[@]+"${ADVANCED_ITEMS[@]}"}; do
            if [ "${_adm_i%%|*}" = "$_adm_ans" ]; then _adm_hit=1; fi
        done
        if [ "$_adm_hit" = "1" ]; then
            show_rescue_page
        else
            _adm_keys=""
            for _adm_i in ${ADVANCED_ITEMS[@]+"${ADVANCED_ITEMS[@]}"}; do
                _adm_keys="$_adm_keys ${_adm_i%%|*}"
            done
            style_out warn "  没有这个编号：$_adm_ans（可用的有$_adm_keys，0 = 返回）"
        fi
    done
}

# 网络救援页：查出问题 -> 说清 -> 问一句 -> 修 -> 回读 -> 报结果。
#
# 这一屏的读法是「先结论、后明细、最后动作」，与状态页同一套：
# 用户打开它的时候心里只有一个问题「我这网到底怎么了」。
show_rescue_page() {
    clear_screen_safe
    style_out title "======== 网络救援 ========"
    echo ""

    _rs_layers=$(sysproxy_layers full)
    _rs_fixable=0
    _rs_blocking=0
    _rs_slowing=0
    _rs_foreign=0
    _rs_managed=0
    _rs_alivebroken=0
    while IFS="$(printf '\t')" read -r _rs_l _rs_svc _rs_kind _rs_url _rs_port _rs_box _rs_hs; do
        [ -n "$_rs_svc" ] || continue
        case "$_rs_kind" in
            "$SYSPROXY_KIND_BLOCKING") _rs_blocking=$((_rs_blocking + 1)) ;;
            "$SYSPROXY_KIND_SLOWING")  _rs_slowing=$((_rs_slowing + 1)) ;;
            "$SYSPROXY_KIND_FOREIGN")  _rs_foreign=$((_rs_foreign + 1)) ;;
            "$SYSPROXY_KIND_MANAGED")  _rs_managed=$((_rs_managed + 1)) ;;
        esac
        # 「端口活着、但握手说它连不上外面」——只有拿到握手证据时才认这一档。
        # 拿不到（quick 或权限不足）时**不算**，绝不凭猜给用户指方向。
        if [ "$_rs_kind" = "$SYSPROXY_KIND_ALIVE" ] && [ "${_rs_hs:-}" = "upstream-fail" ]; then
            _rs_alivebroken=$((_rs_alivebroken + 1))
        fi
        sysproxy_fixable "$_rs_kind" && _rs_fixable=$((_rs_fixable + 1))
    done <<EOF
$_rs_layers
EOF

    # ---- 先给结论：这一屏最上面那句必须是"你现在是什么情况" ----
    if [ "$_rs_blocking" -gt 0 ]; then
        style_out warn "  查下来：浏览器被指到了一个已经关掉的程序上。"
        style_out dim  "          所以网页打不开——线没断，是路指错了。"
    elif [ "$_rs_slowing" -gt 0 ]; then
        style_out warn "  查下来：有个设置脚本指向已经关掉的程序。"
        style_out dim  "          网页能开，但每次都要先等它几秒。"
    elif [ "$_rs_alivebroken" -gt 0 ]; then
        # 代理程序还开着、端口也活着，但它连不上外面。
        # 这一档以前不存在：以前只会说"没发现问题"，用户会以为工具没查出来，然后去动系统代理——
        # 而删掉代理设置并不恢复网络（程序还在跑、还占着端口），只会把他能用的路径删掉。
        style_out warn "  查下来：代理程序还开着，端口也在，但它连不上外面。"
        style_out dim  "          这多半是节点的问题，不是设置坏了。"
        style_out dim  "          关掉重开代理软件、或者换一个节点试试。"
    elif [ "$_rs_fixable" -eq 0 ]; then
        style_out ok "  查下来：没发现问题，浏览器这边的设置是好的。"
        if [ "$_rs_foreign" -gt 0 ]; then
            echo ""
            style_out dim "  你设了别的代理（公司或学校的），那是你自己的设置，本工具不碰。"
        fi
        # 必须说清这个工具管不到哪儿，否则用户会以为"它说没事 = 网没问题"。
        echo ""
        style_out dim "  这个工具只管「浏览器代理」这一层。"
        style_out dim "  如果网还是不通，问题可能在别处：虚拟网卡、路由表、或防火墙规则。"
    fi

    # ---- 明细：能修的与不能动的分开列，不混在一起 ----
    if [ "$_rs_fixable" -gt 0 ]; then
        echo ""
        style_out heading "  能修的有 $_rs_fixable 项："
        echo ""
        while IFS="$(printf '\t')" read -r _rs_l2 _rs_svc2 _rs_kind2 _rs_url2 _rs_port2; do
            [ -n "$_rs_svc2" ] || continue
            sysproxy_fixable "$_rs_kind2" || continue
            if [ "$_rs_kind2" = "$SYSPROXY_KIND_SLOWING" ]; then
                _rs_why="那个脚本已经不在了"
            else
                _rs_why="那个程序已经不在了"
            fi
            style_out text "    $_rs_svc2  $_rs_url2"
            style_out dim  "      $_rs_why"
        done <<EOF
$_rs_layers
EOF
    fi
    if [ "$_rs_foreign" -gt 0 ] || [ "$_rs_managed" -gt 0 ]; then
        echo ""
        style_out heading "  不能动的 $((_rs_foreign + _rs_managed)) 项："
        echo ""
        while IFS="$(printf '\t')" read -r _rs_l3 _rs_svc3 _rs_kind3 _rs_url3 _rs_port3; do
            [ -n "$_rs_svc3" ] || continue
            case "$_rs_kind3" in
                "$SYSPROXY_KIND_FOREIGN")
                    style_out text "    $_rs_svc3  $_rs_url3"
                    style_out dim "      不是本机的地址，多半是公司或学校的，本工具不碰"
                    ;;
                "$SYSPROXY_KIND_MANAGED")
                    style_out text "    $_rs_svc3"
                    style_out dim "      这台电脑的设置由管理员统一管着，改了也会被改回去"
                    ;;
            esac
        done <<EOF
$_rs_layers
EOF
    fi

    # ---- 动作 ----
    echo ""
    # 「能不能还原」与「当下有没有可修项」是两件事，必须分开判断。
    # 最常撞上的时序：昨天修过（备份已写），今天客户端换回原端口，现在没有可修项了，
    # 用户想把代理改回原样——若按「可修项为零」提前返回，他只会看到「按回车返回」，
    # r 根本敲不到，而帮助页承诺了那条路。备份在就允许还原，与 fixable 无关。
    _rs_hasbak=0
    [ -f "$(sysproxy_backup_path)" ] && _rs_hasbak=1
    if [ "$_rs_fixable" -eq 0 ] && [ "$_rs_hasbak" -eq 0 ]; then
        style_out dim "  按回车返回"
        read -r _rs_dummy || true
        return 0
    fi
    [ "$_rs_fixable" -gt 0 ] && style_out text "  输 y 回车 = 修好上面那 $_rs_fixable 项（会先备份，能还原）"
    [ "$_rs_hasbak" -eq 1 ] && style_out dim "  输 r 回车 = 还原成第一次修之前的样子"
    style_out dim "  直接回车 = 什么都不做，返回"
    _rs_ans=""
    if ! read -r _rs_ans 2>/dev/null; then return 0; fi
    case "$_rs_ans" in
        y|Y|yes|YES|是) ;;
        r|R)
            [ "$_rs_hasbak" -eq 1 ] || return 0
            _rs_rr=$(sysproxy_restore)
            echo ""
            case "$_rs_rr" in
                ok)       style_out ok "  [完成] 已经改回第一次修之前的样子。" ;;
                canceled) style_out warn "  你取消了密码，什么都没改。" ;;
                *)        style_out warn "  [未完成] 没能改回去。可以再试一次。" ;;
            esac
            style_out dim "  按回车返回"
            read -r _rs_dummy || true
            return 0 ;;
        *) return 0 ;;
    esac

    # 真动手。mac 上改系统代理要管理员，会弹一次系统密码框。
    echo ""
    style_out text "  接下来会弹一个要开机密码的窗口，那是系统的，不是要装别的东西。"
    _rs_res=$(sysproxy_repair)
    echo ""
    case "$_rs_res" in
        fixed)
            style_out ok "  [完成] 修好了。"
            style_out dim "  浏览器要是还打不开，把它关掉重开一次。" ;;
        none)
            style_out dim "  查的时候还在，动手的时候已经没了（可能是你自己关掉了）。" ;;
        managed)
            style_out warn "  这台电脑的设置由管理员统一管着，本工具改不动。"
            style_out dim "  需要的话请找管理员。" ;;
        nobackup)
            style_out warn "  [未完成] 备份写不下来，为了安全没有动任何设置。"
            style_out dim "  确认日志目录可写之后再来一次。" ;;
        canceled)
            style_out warn "  你取消了密码，什么都没改。" ;;
        *)
            style_out warn "  [未完成] 没能改完。"
            style_out dim "  可以再试一次；还不行就用主菜单的「问题反馈」生成一份报告。" ;;
    esac
    style_out dim "  按回车返回"
    read -r _rs_dummy || true
    return 0
}
