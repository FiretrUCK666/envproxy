# ==============================================================================
#  insp.sh — 检查器层：注册表、编排、以及「系统代理之外」的那些检查器与救援页
#  由入口 envproxy.sh 按固定顺序 source，不单独运行。
#
#  为什么单独成一个库（而不是继续往 doctor.sh 里堆）：
#    doctor.sh 的职责是「怎么安全地读一层、判一层、修一层」——它是**叶子**，
#    界面反过来调它。检查器不一样：它要汇总各层、要渲染，
#    而渲染必须调 base 的配色与清屏。把编排放进 doctor 会立刻造出
#    doctor -> 界面 -> doctor 的环（门禁 1 会拦）。
#
#  依赖方向（单向）：insp -> doctor -> probe -> base
#    doctor 不认识 insp，所以 doctor 那份判据永远是唯一的一份。
#
#  职责边界（改这个文件前先读这一段）：
#    可以有 —— 检查器注册表、编排、各检查器的读取与修复、救援页界面
#    不许有 —— 改环境变量、安装/卸载、快捷方式
#
#  加一层网络检查的完整动作（三处，没有第四处）：
#    1) 写一个输出 Finding 行的读取函数（判据必须是纯函数，能喂测试用例）
#    2) 要修就再写一个修复函数，以及对应的撤销函数（写还原点 + 回读确认）
#    3) 在下面的 DOCTOR_INSPECTORS 里加一行
#  界面、报告、状态页一个字都不用改——它们只认 Finding，不认检查器名字。
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 检查器注册表：唯一权威，也是唯一分派点
# ------------------------------------------------------------------------------
# 七列，管道分隔（与 ADVANCED_ITEMS / MENU_ITEMS 同一种「机器列在前」的形状，
# 解析只读前几段，加人读列不影响取字段）：
#   1 Id       稳定标识，写进还原点的 inspector 字段
#   2 Title    界面上那一组叫什么（用户看得懂的说法，不是内部名）
#   3 Quick    状态页（每 2–3 秒）要不要跑它：1 = 要，0 = 只在全量档跑
#   4 Detect   输出 Finding 行的函数名
#   5 Fix      修它的函数名；空 = 只诊断不修
#   6 Restore  撤销函数名（门禁核对「声明了可修就得有撤销的路」）
#   7 _        预留，留空（与 Windows 侧保持同样的列数，便于两侧逐项比对）
#
# **顺序就是界面上的顺序**：从下往上（网址解析 → 浏览器 → 终端工具），
# 与人排查故障的方向一致——先看是不是连名字都解析不了，再看浏览器，最后看工具。
#
# 贵的一律 Quick=0：状态页刷新的代价以毫秒计，跑一次要读文件或连端口的
# 检查器进去就把刷新拖垮了。
DOCTOR_INSPECTORS=(
    'dns|网址解析|0|get_dns_findings||'
    'sysproxy|浏览器代理|1|get_sysproxy_findings|sysproxy_repair|restore_sysproxy_snapshot'
    'cli-proxy|终端工具里的代理|0|get_cli_proxy_findings|repair_cli_proxy_config|restore_cli_proxy_snapshot'
)

# 取一行里第 N 段，结果写进 _insp_out。段不存在时返回 1。
#
# 不用 $(...) 取字段：命令替换会 fork 子 shell，而渲染一屏要取几十次。
# 与 help.sh 的 _adv_field 同一手法——同一件事不该有第二种写法。
_insp_field() {
    _insp_s=$1
    _insp_n=$2
    while [ "$_insp_n" -gt 1 ]; do
        case "$_insp_s" in
            *'|'*) _insp_s=${_insp_s#*|} ;;
            *) _insp_out=''; return 1 ;;
        esac
        _insp_n=$((_insp_n - 1))
    done
    _insp_out=${_insp_s%%|*}
    return 0
}

# 按 Id 取描述符的一列。取不到时输出空。
insp_field_of_id() {
    _ifoi_want="$1"; _ifoi_col="$2"
    for _ifoi_row in ${DOCTOR_INSPECTORS[@]+"${DOCTOR_INSPECTORS[@]}"}; do
        _insp_field "$_ifoi_row" 1 || continue
        if [ "$_insp_out" = "$_ifoi_want" ]; then
            _insp_field "$_ifoi_row" "$_ifoi_col" && { printf '%s' "$_insp_out"; return 0; }
            printf ''
            return 0
        fi
    done
    printf ''
    return 0
}

# 表自检：每个声明的函数必须在本侧真存在。
# 用 declare -F 而不是 command -v：后者会搜 PATH，
# 同名的可执行文件会让这项检查假通过。
# 在进体检页时跑，不在加载期跑（库加载期不许有对外副作用）。
assert_doctor_inspectors() {
    _adi_bad=0
    for _adi_row in ${DOCTOR_INSPECTORS[@]+"${DOCTOR_INSPECTORS[@]}"}; do
        _insp_field "$_adi_row" 1; _adi_id=$_insp_out
        _insp_field "$_adi_row" 4; _adi_detect=$_insp_out
        _insp_field "$_adi_row" 5; _adi_fix=$_insp_out
        _insp_field "$_adi_row" 6; _adi_restore=$_insp_out
        if [ -z "$_adi_id" ]; then
            echo "检查器表：有一行没有 Id" >&2; _adi_bad=1; continue
        fi
        if [ -z "$_adi_detect" ]; then
            echo "检查器表：$_adi_id 没有读取函数" >&2; _adi_bad=1; continue
        fi
        if ! declare -F "$_adi_detect" >/dev/null 2>&1; then
            echo "检查器表：$_adi_id 的读取函数 $_adi_detect 不存在" >&2; _adi_bad=1
        fi
        if [ -n "$_adi_fix" ]; then
            if ! declare -F "$_adi_fix" >/dev/null 2>&1; then
                echo "检查器表：$_adi_id 的修复函数 $_adi_fix 不存在" >&2; _adi_bad=1
            fi
            # 声明了可修就必须有撤销的路，否则用户按 r 时退不回去。
            if [ -z "$_adi_restore" ]; then
                echo "检查器表：$_adi_id 声明了修复却没有撤销函数" >&2; _adi_bad=1
            elif ! declare -F "$_adi_restore" >/dev/null 2>&1; then
                echo "检查器表：$_adi_id 的撤销函数 $_adi_restore 不存在" >&2; _adi_bad=1
            fi
        fi
    done
    return $_adi_bad
}

# ------------------------------------------------------------------------------
# 2. 编排：跑一遍检查器，输出合并后的 Finding 行
# ------------------------------------------------------------------------------
# $1 = quick 时只跑 Quick=1 的（状态页）；其余是全量（体检页）。
# **一个函数、两种深度**，不是两套代码：复制一份轻量实现，迟早两边结论不一致。
#
# 某个检查器抛异常不许把整体带崩：它自己那一层变成一条 unreadable 记录，
# 其余层照常出结论。理由是失效模式——「一个检查器崩了 → 整屏空白」会让用户
# 以为网络没问题，而真相是「有一层没看见」。
# 这条 Finding 我们被授权去修吗？
#
# **这是「可修」的唯一判据，界面只许查它，不许自己按 Kind 猜。**
# 两件事缺一不可：Kind 说「这是什么性质的问题」，
# Fix 列说「我们被授权动这一层吗」。
# 只看 Kind 会让「DNS 指向本机死端口」（Blocking、但那一层 Fix 为空）进「要修的」，
# 用户按 y 什么都不修，屏幕还说"它自己消失了"。
# 参数：$1 = Kind，$2 = 检查器 Id
finding_repairable() {
    _fr_kind="${1:-}"; _fr_id="${2:-}"
    finding_fixable "$_fr_kind" || return 1
    # 参数可以是检查器 Id（sysproxy），也可以是完整 Finding Id（sysproxy.direct）。
    # **必须两种都认**：调用点分散在界面各处，有的手里只有 Finding Id。
    # 只认一种的后果是另一侧的可修项全部被判成不可修——
    # 屏幕上那一区直接空了，而没有任何报错（实测踩过：传 sysproxy.direct 得"不可修"）。
    # 截法与 Windows 侧 Test-FindingRepairable 一致：取第一个点号之前的那一段。
    _fr_insp=${_fr_id%%.*}
    _fr_fix=$(insp_field_of_id "$_fr_insp" 5 2>/dev/null || true)
    [ -n "$_fr_fix" ] || return 1
    return 0
}
invoke_doctor_check() {
    _idc_quick="${1:-}"
    for _idc_row in ${DOCTOR_INSPECTORS[@]+"${DOCTOR_INSPECTORS[@]}"}; do
        _insp_field "$_idc_row" 1; _idc_id=$_insp_out
        _insp_field "$_idc_row" 2; _idc_title=$_insp_out
        _insp_field "$_idc_row" 3; _idc_isquick=$_insp_out
        _insp_field "$_idc_row" 4; _idc_fn=$_insp_out
        [ -n "$_idc_fn" ] || continue
        if [ "$_idc_quick" = "quick" ] && [ "$_idc_isquick" != "1" ]; then continue; fi
        if ! declare -F "$_idc_fn" >/dev/null 2>&1; then
            finding_new "$_idc_id.error" "$FINDING_KIND_UNREADABLE" "$_idc_title" "$_idc_id" \
                '' "这一项没能检查：读取函数不存在" '这一项没读出来，不代表没问题。' ''
            continue
        fi
        # 收集输出到变量再统一打印：直接调用会把它的 stderr 混进结果行。
        #
        # **读失败必须变成一条 unreadable，不许静默清空。**
        # 原来写的是 `|| _idc_out=''`：函数崩了就什么都不产，
        # 屏幕上看这一层"没问题"——而"读不出来"与"没问题"是两件事，
        # 这正是本项目反复强调的那条契约的反面。Windows 侧一直是这样处理的。
        if ! _idc_out=$("$_idc_fn" 2>/dev/null); then
            finding_new "$_idc_id.error" "$FINDING_KIND_UNREADABLE" "$_idc_title" "$_idc_id" \
                '' "这一项没能检查：读取过程出错了" '这一项没读出来，不代表没问题。可以到「问题反馈」生成一份报告。' ''
            continue
        fi
        if [ -n "$_idc_out" ]; then
            printf '%s\n' "$_idc_out"
        fi
    done
    return 0
}

# ------------------------------------------------------------------------------
# 3. 系统代理那一层的 Finding 包装
# ------------------------------------------------------------------------------
# **判断逻辑一个字没动**：还是 sysproxy_layers 产出的事实，只换了一层外壳。
# 这样「加检查器」对既有功能是零行为变更——一旦包装层开始自己判断，
# 就等于把 doctor 的判据抄成两份，两份迟早不一致。
get_sysproxy_findings() {
    _gsf_layers=$(sysproxy_layers)
    [ -n "$_gsf_layers" ] || return 0
    while IFS="$(printf '\t')" read -r _gsf_l _gsf_svc _gsf_kind _gsf_url _gsf_port _gsf_box _gsf_hs; do
        [ -n "$_gsf_svc" ] || continue
        # 界面上那一组叫什么。内部层名不给人看：用户不知道 autoproxy 是什么，
        # 但认得「浏览器代理」与「自动配置脚本」——那是他在系统设置里能点到的词。
        case "$_gsf_l" in
            pac)     _gsf_where='自动配置脚本' ;;
            manual)  _gsf_where='浏览器代理设置' ;;
            unknown) _gsf_where='浏览器代理设置' ;;
            *)       _gsf_where="$_gsf_l" ;;
        esac
        # mac 是「每个网络服务一份」，所以把服务名带上——不说清是哪个网络，
        # 用户不知道该去系统设置里改哪一行。
        case "$_gsf_svc" in
            '') : ;;
            *)  _gsf_where="$_gsf_svc 上的$_gsf_where" ;;
        esac
        case "$_gsf_kind" in
            "$FINDING_KIND_CLEAN") continue ;;
        esac
        # 握手分类是**贵信号**：只进 Reason 的补充说明，绝不参与授权。
        # 它决定「端口活着但连不上外面」那一档要不要出现——那条判断读的是它。
        _gsf_reason=$(get_sysproxy_reason "$_gsf_kind" "$_gsf_url" "${_gsf_port:-0}")
        case "${_gsf_hs:-}" in
            upstream-fail)
                _gsf_reason="$_gsf_reason　它连不上外面（节点可能挂了）。" ;;
            proxy-auth)
                _gsf_reason="$_gsf_reason　它要求密码，是个正经代理。" ;;
            not-http)
                _gsf_reason="$_gsf_reason　它不像代理，更像别的程序占着这个端口。" ;;
            silent)
                _gsf_reason="$_gsf_reason　它连上了但不应答代理握手。" ;;
        esac
        finding_new "sysproxy.$_gsf_l" "$_gsf_kind" '浏览器代理' "$_gsf_where" \
            "${_gsf_url:-}" "$_gsf_reason" \
            "$(get_sysproxy_advice "$_gsf_kind")" 'sysproxy'
    done <<EOF
$_gsf_layers
EOF
    return 0
}

# 给一个结论配一句"为什么这么判"。**只用廉价信号**（地址形态、端口三态、是否被管），
# 不引入握手/进程/时间那些贵信号——贵信号会因为环境失败，一旦影响措辞就影响授权判断。
get_sysproxy_reason() {
    _gsr_kind="$1"; _gsr_url="$2"; _gsr_port="${3:-0}"
    case "$_gsr_kind" in
        "$FINDING_KIND_MANAGED")  printf '%s' '这台电脑的代理设置由管理员统一管着，改了也会被改回去。' ;;
        "$FINDING_KIND_ALIVE")    printf '%s' "代理地址是本机，端口 $_gsr_port 上有程序在听，连得上。" ;;
        "$FINDING_KIND_BLOCKING") printf '%s' "地址是本机，但端口 $_gsr_port 上没有任何程序在听。网页请求发出去没人接，所以打不开。" ;;
        "$FINDING_KIND_SLOWING")  printf '%s' "设置脚本指向本机的 $_gsr_port 端口，那里已经没程序了。网页能开，但每次都要先等它超时。" ;;
        "$FINDING_KIND_FOREIGN")  printf '%s' "代理地址不是这台电脑自己（$_gsr_url），多半是公司或学校给的，本工具不碰。" ;;
        *) printf '' ;;
    esac
    return 0
}

# 给一个结论配一句"你可以做什么"。空串表示"没有需要你做的事"。
get_sysproxy_advice() {
    case "${1:-}" in
        "$FINDING_KIND_BLOCKING"|"$FINDING_KIND_SLOWING") printf '%s' '可以让本工具修掉它（会先备份，能还原）。' ;;
        "$FINDING_KIND_ALIVE")    printf '%s' '不需要做什么。' ;;
        "$FINDING_KIND_MANAGED")  printf '%s' '需要的话请找管理员。' ;;
        "$FINDING_KIND_FOREIGN")  printf '%s' '如果这是你自己设的，保持原样即可。' ;;
        *) printf '' ;;
    esac
    return 0
}

# ------------------------------------------------------------------------------
# 4. 终端工具配置里的代理（cli-proxy 检查器）
# ------------------------------------------------------------------------------
# 为什么这是最该补的一块：它的判据与系统代理**完全同构**——
# 「本机回环 + 端口死」= 某个本机程序写的、而且写它的程序已经不在了。
# 同一个纯函数判，误伤率为零。
#
# 为什么环境变量救不了它：这些配置文件（.gitconfig、.npmrc、.curlrc）
# 里写的代理**优先级高于环境变量**。EnvProxy 把变量管得再好，也压不过它。
#
# 边界（比系统代理更严，因为这里动的是用户的文件，不是系统设置）：
#   · 只认「本机回环 + 端口不通」，与系统代理同一套判据；
#   · 非回环（公司代理）、读不出来 → 一律不动；
#   · 文件里有 include / includeIf → 不动：代理可能来自被包含的另一个文件，
#     只改主文件会「显示修好了、实际没修」，与「部分失败不许报成修好」是同一条原则；
#   · 只删那一行，不重写整个文件；改前整份原文进还原点，能逐字撤回。
#
# 表是唯一权威：加一个文件 = 加一行。三列：Id|显示名|文件名
# 落点一律 $HOME 下（mac 上 git/npm/curl 都读家目录那一份）。
CLI_PROXY_TARGETS=(
    'git|Git 自己的代理|.gitconfig|http.proxy https.proxy'
    'npm|npm 自己的代理|.npmrc|proxy https-proxy'
    'curl|curl 自己的代理|.curlrc|proxy x'
)

# 这个文件的绝对路径。返回空串 = 这台机器上不适用。
# **不写死用户名**：家目录从环境取，取不到就当作不适用。
cli_proxy_file_path() {
    _cpfp_file="$1"
    if [ -n "${CLI_PROXY_HOME_OVERRIDE:-}" ]; then
        printf '%s' "$CLI_PROXY_HOME_OVERRIDE/$_cpfp_file"
        return 0
    fi
    [ -n "${HOME:-}" ] || { printf ''; return 0; }
    printf '%s' "$HOME/$_cpfp_file"
    return 0
}

# 从一行里取「键 = 值」，结果写进 _cfl_key 与 _cfl_val。不是键值行时返回 1。
#
# 三种形态都要认，因为三个文件用三种写法：
#   INI（.gitconfig）:  [http]  换行  proxy = http://127.0.0.1:7890
#   键值（.npmrc）:      proxy=http://127.0.0.1:7890
#   键值（.curlrc）:     proxy = "http://127.0.0.1:7890"
# 值两侧的引号必须剥掉，否则地址会带着引号进 is_loopback_url，判成「不是回环」→ 永不修。
_cfl_key=''
_cfl_val=''
_cli_config_line_parse() {
    _cfl_key=''; _cfl_val=''
    _cfl_t="${1:-}"
    # 去掉首尾空白（纯 shell，不起子进程）
    _cfl_t="${_cfl_t#"${_cfl_t%%[![:space:]]*}"}"
    _cfl_t="${_cfl_t%"${_cfl_t##*[![:space:]]}"}"
    [ -n "$_cfl_t" ] || return 1
    # 注释行：三种文件都用 # 或 ; 开头。**必须先判**，否则注释里的 proxy=
    # 会被当成真的设置去判、去修。
    case "$_cfl_t" in
        '#'*|';'*) return 1 ;;
    esac
    # 段头：[http] / [http "url"]。不是键值行，但也不是错误——由调用方处理。
    case "$_cfl_t" in
        '['*) return 1 ;;
    esac
    # 必须在第一个 = 处切：值里可能还有 =（例如 base64 的凭据）
    case "$_cfl_t" in
        *=*) : ;;
        *) return 1 ;;
    esac
    _cfl_key="${_cfl_t%%=*}"
    _cfl_val="${_cfl_t#*=}"
    _cfl_key="${_cfl_key%"${_cfl_key##*[![:space:]]}"}"
    _cfl_val="${_cfl_val#"${_cfl_val%%[![:space:]]*}"}"
    _cfl_val="${_cfl_val%"${_cfl_val##*[![:space:]]}"}"
    [ -n "$_cfl_key" ] || return 1
    # 剥引号：只在成对时剥，避免把值尾部的合法字符当引号删掉。
    case "$_cfl_val" in
        \"*\") _cfl_val="${_cfl_val#\"}"; _cfl_val="${_cfl_val%\"}" ;;
        \'*\') _cfl_val="${_cfl_val#\'}"; _cfl_val="${_cfl_val%\'}" ;;
    esac
    return 0
}

# 读一个文件里的全部代理项。输出每行 5 个 TAB 字段：
#   LineNumber <TAB> FullKey <TAB> Value <TAB> HasInclude <TAB> ReadOk
# ReadOk=0 表示读不出来（那时前面几列为空）。文件不存在视为读成功、零条目。
read_cli_proxy_file() {
    _rcpf_path="$1"; _rcpf_keys="$2"
    [ -n "$_rcpf_path" ] || { printf '0\t\t\t0\t0\n'; return 0; }
    if [ ! -f "$_rcpf_path" ]; then
        return 0    # 没有这个文件：这一层不存在，不产结论
    fi
    if [ ! -r "$_rcpf_path" ]; then
        printf '0\t\t\t0\t0\n'
        return 0
    fi
    # **两遍读**。第一遍只为回答「这个文件里有没有 include」，
    # 第二遍才逐行判命中。
    #
    # 为什么必须两遍：`[include]` 段可能出现在文件任何位置——实测最常见的写法是
    # 把它放在最后（`git config --global include.path ...` 就是追加到末尾）。
    # 一遍扫的话，前面那些 proxy 行在被打印时还不知道后面有 include，
    # 于是「有 include 就不动」这条护栏在最需要它的文件上失效——
    # 而这个失效是静默的：屏幕上显示"可修"，删掉之后代理仍然从别处生效。
    _rcpf_hasinc=0
    while IFS= read -r _rcpf_scan || [ -n "$_rcpf_scan" ]; do
        _rcpf_st="$_rcpf_scan"
        _rcpf_st="${_rcpf_st#"${_rcpf_st%%[![:space:]]*}"}"
        case "$_rcpf_st" in
            '['*)
                _rcpf_si="${_rcpf_st#\[}"
                _rcpf_si="${_rcpf_si%%\]*}"
                _rcpf_si="${_rcpf_si%%[[:space:]]*}"
                _rcpf_si=$(printf '%s' "$_rcpf_si" | tr 'A-Z' 'a-z')
                case "$_rcpf_si" in
                    include|includeif) _rcpf_hasinc=1 ;;
                esac ;;
        esac
    done < "$_rcpf_path"
    _rcpf_section=''
    _rcpf_n=0
    while IFS= read -r _rcpf_line || [ -n "$_rcpf_line" ]; do
        _rcpf_n=$((_rcpf_n + 1))
        _rcpf_t="$_rcpf_line"
        _rcpf_t="${_rcpf_t#"${_rcpf_t%%[![:space:]]*}"}"
        # 段头：只取方括号里第一段词，引号里的东西不是段名的一部分。
        case "$_rcpf_t" in
            '['*)
                _rcpf_inner="${_rcpf_t#\[}"
                _rcpf_inner="${_rcpf_inner%%\]*}"
                _rcpf_section="${_rcpf_inner%%[[:space:]]*}"
                _rcpf_section=$(printf '%s' "$_rcpf_section" | tr 'A-Z' 'a-z')
                continue ;;
        esac
        _cli_config_line_parse "$_rcpf_line" || continue
        _rcpf_leaf=$(printf '%s' "$_cfl_key" | tr 'A-Z' 'a-z')
        if [ -n "$_rcpf_section" ]; then
            _rcpf_full="${_rcpf_section}.${_rcpf_leaf}"
        else
            _rcpf_full="$_rcpf_leaf"
        fi
        _rcpf_hit=0
        for _rcpf_want in $_rcpf_keys; do
            _rcpf_wantl=$(printf '%s' "$_rcpf_want" | tr 'A-Z' 'a-z')
            # 两种写法都算命中：完整键（http.proxy）与裸键（proxy，在 [http] 段里）。
            if [ "$_rcpf_full" = "$_rcpf_wantl" ] || [ "$_rcpf_leaf" = "$_rcpf_wantl" ]; then
                _rcpf_hit=1
                break
            fi
        done
        [ "$_rcpf_hit" = "1" ] || continue
        printf '%s\t%s\t%s\t%s\t1\n' "$_rcpf_n" "$_rcpf_full" "$_cfl_val" "$_rcpf_hasinc"
    done < "$_rcpf_path"
    return 0
}

# 纯判据：给定一个配置文件里的代理值，说出结论。**不碰文件、不碰网络**，便于回归。
#
# 与 sysproxy_verdict 同源同形，只是少了两维：
# 配置文件里没有「被描述文件管着」这一说，也没有 PAC 那种「慢但能上」的形态。
# 少掉不是简化，是那两件事在这个场景里真的不存在——不做成通用参数再处处判断。
#   $1 值   $2 死活（alive / dead / unknown）   $3 文件里有 include：1 / 0
cli_proxy_verdict() {
    _cpv_val="${1:-}"; _cpv_alive="${2:-unknown}"; _cpv_inc="${3:-0}"
    [ -n "$_cpv_val" ] || { printf '%s' "$FINDING_KIND_CLEAN"; return 0; }
    # 解析不出地址：认不出来就说什么都不做。**不许当 clean**——
    # clean 是「这里没设」，而这里明明写了一行我们看不懂的东西。
    _cpv_url=$(_url_host "$_cpv_val") || { printf '%s' "$FINDING_KIND_FOREIGN"; return 0; }
    [ -n "$_cpv_url" ] || { printf '%s' "$FINDING_KIND_FOREIGN"; return 0; }
    is_loopback_url "$_cpv_val" || { printf '%s' "$FINDING_KIND_FOREIGN"; return 0; }
    # 文件里有 include：代理可能来自别处，改这一行解决不了问题。
    # 归 foreign 而不是可修——「修了也没用」等于没修，报成修好就是谎报。
    [ "$_cpv_inc" = "1" ] && { printf '%s' "$FINDING_KIND_FOREIGN"; return 0; }
    # 说不清死活时不动：判成可修然后删掉一个其实在用的代理，代价是用户唯一的上网路径没了。
    [ "$_cpv_alive" = "unknown" ] && { printf '%s' "$FINDING_KIND_FOREIGN"; return 0; }
    [ "$_cpv_alive" = "alive" ] && { printf '%s' "$FINDING_KIND_ALIVE"; return 0; }
    printf '%s' "$FINDING_KIND_BLOCKING"
    return 0
}

# 读全部 CLI 配置文件，输出 Finding 行。
get_cli_proxy_findings() {
    for _gcp_row in ${CLI_PROXY_TARGETS[@]+"${CLI_PROXY_TARGETS[@]}"}; do
        _insp_field "$_gcp_row" 1; _gcp_id=$_insp_out
        _insp_field "$_gcp_row" 2; _gcp_name=$_insp_out
        _insp_field "$_gcp_row" 3; _gcp_file=$_insp_out
        _insp_field "$_gcp_row" 4; _gcp_keys=$_insp_out
        _gcp_path=$(cli_proxy_file_path "$_gcp_file")
        [ -n "$_gcp_path" ] || continue
        [ -f "$_gcp_path" ] || continue
        _gcp_rows=$(read_cli_proxy_file "$_gcp_path" "$_gcp_keys")
        # 读不出来（最后两列是 0）要单独说，不许静默消失。
        _gcp_bad=0
        if [ -n "$_gcp_rows" ]; then
            _gcp_bad=$(printf '%s\n' "$_gcp_rows" | awk -F"\t" '$5 == "0" {c++} END {print c+0}')
        fi
        if [ "$_gcp_bad" -gt 0 ]; then
            finding_new "cli-proxy.$_gcp_id" "$FINDING_KIND_UNREADABLE" "$_gcp_name" "$_gcp_path" \
                '' '这个文件没读出来。' '读不出来不代表没问题，但本工具不会去改它。' ''
            continue
        fi
        [ -n "$_gcp_rows" ] || continue
        while IFS="$(printf '\t')" read -r _gcp_ln _gcp_key _gcp_val _gcp_inc _gcp_ok; do
            [ -n "$_gcp_ln" ] || continue
            [ "$_gcp_ok" = "1" ] || continue
            _gcp_alive='unknown'
            _gcp_addr=$(sysproxy_split_url "$_gcp_val")
            _gcp_addr=$(printf '%s' "$_gcp_addr" | sed -E 's/^\[([^]]*)\]:[0-9]+$/\1/; t; s/:[0-9]+$//')
            _gcp_port=$(printf '%s' "$_gcp_addr" | sed -E 's/^.*://')
            case "$_gcp_val" in
                *:*) _gcp_port="${_gcp_val##*:}" ;;
                *)   _gcp_port='' ;;
            esac
            case "$_gcp_port" in ''|*[!0-9]*) _gcp_port='' ;; esac
            if [ -n "$_gcp_port" ] && [ "$_gcp_port" -gt 0 ] 2>/dev/null; then
                if port_alive_bounded "$_gcp_addr" "$_gcp_port"; then
                    _gcp_alive='alive'
                else
                    _gcp_alive='dead'
                fi
            fi
            _gcp_kind=$(cli_proxy_verdict "$_gcp_val" "$_gcp_alive" "$_gcp_inc")
            case "$_gcp_kind" in
                "$FINDING_KIND_CLEAN") continue ;;
            esac
            _gcp_reason=''
            _gcp_advice='保持原样即可。'
            case "$_gcp_kind" in
                "$FINDING_KIND_ALIVE")
                    _gcp_reason='这里写的是本机地址，程序还开着，连得上。' ;;
                "$FINDING_KIND_BLOCKING")
                    _gcp_reason="这个文件里写着让 $_gcp_file 走本机的一个代理，但那个程序已经不在了。"
                    _gcp_advice='可以让本工具删掉那一行（会先备份，能还原）。' ;;
                "$FINDING_KIND_FOREIGN")
                    if [ "$_gcp_inc" = "1" ]; then
                        _gcp_reason='这个文件的代理设置可能是从别处读进来的，本工具不知道该改哪一个，所以不动。'
                    else
                        _gcp_reason='这个代理不是这台电脑自己的，多半是公司或学校给的，本工具不碰。'
                    fi ;;
            esac
            finding_new "cli-proxy.$_gcp_id" "$_gcp_kind" "$_gcp_name" "$_gcp_path" \
                "$_gcp_val" "$_gcp_reason" "$_gcp_advice" 'cli-proxy'
        done <<EOF
$_gcp_rows
EOF
    done
    return 0
}

# 修：删掉那几个判为死的行。输出三态结论词：fixed / none / failed / partial / nobackup
#
# **逐行删，不重写整个文件**：配置文件是用户的，里面有他别的东西。
# 删之前把整份原文写进还原点；还原时整份写回去。
#
# 为什么还原点存全份而不是「被删的那几行」：用户可能在修完之后又改了文件，
# 按行号插回去会插错位置。存全份则还原的判据变成「内容逐字回到原样」，
# 那正是用户对「还原」的全部期待——对不上就如实报，不假装成功。
repair_cli_proxy_config() {
    _rcpc_any=0
    _rcpc_ok=0
    _rcpc_fail=0
    for _rcpc_row in ${CLI_PROXY_TARGETS[@]+"${CLI_PROXY_TARGETS[@]}"}; do
        _insp_field "$_rcpc_row" 1; _rcpc_id=$_insp_out
        _insp_field "$_rcpc_row" 3; _rcpc_file=$_insp_out
        _insp_field "$_rcpc_row" 4; _rcpc_keys=$_insp_out
        _rcpc_path=$(cli_proxy_file_path "$_rcpc_file")
        [ -n "$_rcpc_path" ] || continue
        [ -f "$_rcpc_path" ] || continue
        _rcpc_rows=$(read_cli_proxy_file "$_rcpc_path" "$_rcpc_keys")
        [ -n "$_rcpc_rows" ] || continue
        # 挑出判为死的行号。
        _rcpc_dead=''
        while IFS="$(printf '\t')" read -r _rcpc_ln _rcpc_key _rcpc_val _rcpc_inc _rcpc_okr; do
            [ -n "$_rcpc_ln" ] || continue
            [ "$_rcpc_okr" = "1" ] || continue
            _rcpc_alive='unknown'
            _rcpc_port=''
            case "$_rcpc_val" in
                *:*) _rcpc_port="${_rcpc_val##*:}" ;;
            esac
            case "$_rcpc_port" in ''|*[!0-9]*) _rcpc_port='' ;; esac
            _rcpc_addr=$(sysproxy_split_url "$_rcpc_val")
            _rcpc_addr=$(printf '%s' "$_rcpc_addr" | sed -E 's/^\[([^]]*)\]:[0-9]+$/\1/; t; s/:[0-9]+$//')
            if [ -n "$_rcpc_port" ] && [ "$_rcpc_port" -gt 0 ] 2>/dev/null; then
                if port_alive_bounded "$_rcpc_addr" "$_rcpc_port"; then _rcpc_alive='alive'; else _rcpc_alive='dead'; fi
            fi
            _rcpc_k=$(cli_proxy_verdict "$_rcpc_val" "$_rcpc_alive" "$_rcpc_inc")
            case "$_rcpc_k" in
                "$FINDING_KIND_BLOCKING"|"$FINDING_KIND_SLOWING") _rcpc_dead="$_rcpc_dead $_rcpc_ln" ;;
            esac
        done <<EOF
$_rcpc_rows
EOF
        [ -n "$_rcpc_dead" ] || continue
        _rcpc_any=1
        # 还原点：存整份原文。
        _rcpc_orig=$(cat "$_rcpc_path" 2>/dev/null) || { _rcpc_fail=$((_rcpc_fail + 1)); continue; }
        if ! add_doctor_journal_entry 'cli-proxy' \
                "inspector=cli-proxy" \
                "target=$_rcpc_id" \
                "path=$(_bak_enc "$_rcpc_path")" \
                "content=$(_bak_enc "$_rcpc_orig")"; then
            printf 'nobackup'
            return 0
        fi
        # 只删判为死的那几行。awk 一行搞定，且保留其余行的原样（含行尾空白）。
        _rcpc_tmp="$_rcpc_path.tmp.$$"
        if ! awk -v dead="$_rcpc_dead" '
            BEGIN { n = split(dead, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") skip[a[i]] = 1 }
            { if (!(FNR in skip)) print }
        ' "$_rcpc_path" > "$_rcpc_tmp" 2>/dev/null; then
            rm -f "$_rcpc_tmp" 2>/dev/null
            _rcpc_fail=$((_rcpc_fail + 1))
            continue
        fi
        # 原子替换：就地截断中途失败，用户就得到半截的配置。
        if ! mv -f "$_rcpc_tmp" "$_rcpc_path" 2>/dev/null; then
            rm -f "$_rcpc_tmp" 2>/dev/null
            _rcpc_fail=$((_rcpc_fail + 1))
            continue
        fi
        # 回读确认：那几项真的没了才算修好。不确认就报成功，
        # 就是屏幕上说修好了、git 还是连不上。
        _rcpc_after=$(read_cli_proxy_file "$_rcpc_path" "$_rcpc_keys")
        _rcpc_left=0
        if [ -n "$_rcpc_after" ]; then
            while IFS="$(printf '\t')" read -r _rcpc_l2 _rcpc_k2 _rcpc_v2 _rcpc_i2 _rcpc_o2; do
                [ -n "$_rcpc_l2" ] || continue
                [ "$_rcpc_o2" = "1" ] || continue
                _rcpc_k2v=$(cli_proxy_verdict "$_rcpc_v2" 'dead' "$_rcpc_i2")
                case "$_rcpc_k2v" in
                    "$FINDING_KIND_BLOCKING"|"$FINDING_KIND_SLOWING") _rcpc_left=$((_rcpc_left + 1)) ;;
                esac
            done <<EOF
$_rcpc_after
EOF
        fi
        if [ "$_rcpc_left" -eq 0 ]; then _rcpc_ok=$((_rcpc_ok + 1)); else _rcpc_fail=$((_rcpc_fail + 1)); fi
    done
    if [ "$_rcpc_any" -eq 0 ]; then printf 'none'; return 0; fi
    if [ "$_rcpc_fail" -eq 0 ] && [ "$_rcpc_ok" -gt 0 ]; then printf 'fixed'; return 0; fi
    if [ "$_rcpc_ok" -eq 0 ]; then printf 'failed'; return 0; fi
    printf 'partial'
    return 0
}

# 撤销一次 CLI 配置修复。返回 ok / failed / skip。
# 判据是「文件内容逐字回到原样」——这是用户对「还原」的全部期待。
restore_cli_proxy_snapshot() {
    _rcps_path=$(doctor_journal_last_field 'path')
    [ -n "$_rcps_path" ] || { printf 'skip'; return 0; }
    _rcps_content=$(doctor_journal_last_field 'content')
    # content 可能是空文件：空串也合法，所以判「有没有这个字段」而不是「是不是空」。
    _rcps_has=$(doctor_journal_ops | tail -n 1 | cut -f4- | tr '\001' '\n' | grep -c '^content=' 2>/dev/null || true)
    [ "${_rcps_has:-0}" -gt 0 ] || { printf 'skip'; return 0; }
    _rcps_tmp="$_rcps_path.tmp.$$"
    if ! printf '%s' "$_rcps_content" > "$_rcps_tmp" 2>/dev/null; then
        rm -f "$_rcps_tmp" 2>/dev/null
        printf 'failed'; return 0
    fi
    if ! mv -f "$_rcps_tmp" "$_rcps_path" 2>/dev/null; then
        rm -f "$_rcps_tmp" 2>/dev/null
        printf 'failed'; return 0
    fi
    _rcps_after=$(cat "$_rcps_path" 2>/dev/null) || { printf 'failed'; return 0; }
    [ "$_rcps_after" = "$_rcps_content" ] && printf 'ok' || printf 'failed'
    return 0
}

# ------------------------------------------------------------------------------
# 5. 网址解析（dns 检查器）—— macOS 侧只做「能证伪」的那一条
# ------------------------------------------------------------------------------
# DIVERGE(Mac): Windows 侧能做两条（网卡级与「所有网络」两处设置打架、生效 DNS
#   指向本机且 53 无人应答）。macOS 没有第一件事——那边没有「所有 WLAN 网络的 DNS」
#   这个设置，网络服务的 DNS 只有一份，不存在两处打架。第二件事在 mac 上也不是
#   「读注册表」而是 `scutil --dns` 的解析器快照，判据完全不同，混在一层里会让
#   两侧的结论词含义分叉。所以这一层在 mac 上如实返回空。
#
# 为什么允许一个检查器在本侧产出空：表是两侧同形的（门禁 6 核对），
# 但**能力**不必同形。返回空 ≠ 读不出来——读不出来要产 unreadable，
# 那才是「有一层没看见」。这里是真的没有这一层可看。
get_dns_findings() {
    return 0
}

# ------------------------------------------------------------------------------
# 6. 撤销的入口：按 inspector 字段决定调哪一层的撤销实现
# ------------------------------------------------------------------------------
# 这是**唯一分发点**，住在 insp 层而不是 doctor 层，理由是依赖方向——
# doctor 是叶子，它不该知道自己有哪几层；每层把快照写给自己，
# 但「撤销最近一次」只有一个入口。
#
# 输出：Result <TAB> Inspector，Result ∈ none / ok / failed / partial
# 还原旧版单槽位备份（doctor.bak）。返回 ok / failed / canceled / skip。
#
# 旧文件是制表符分隔的五列：服务、类型、启用、地址、端口——
# 与 sysproxy_repair 现在写进日志的 services 表**逐列同形**，所以
# 直接把内容交给 restore_sysproxy_snapshot，复用的是同一条唯一实现：
# 撤销只该有一处代码，两处各写一套迟早分叉。
#
# **不借道日志**：早先的做法是先往日志追加一段临时记录再调那函数。
# 那样会占用保留条数、把使用者另一条真实还原点挤掉（挤掉的回不来），
# 写回日志还要求原子、中途失败会留下半截日志让所有还原点报废。
restore_legacy_sysproxy_snapshot() {
    _rlss_path=$(sysproxy_backup_path)
    [ -f "$_rlss_path" ] || { printf 'none'; return 0; }
    _rlss_rows=$(cat "$_rlss_path" 2>/dev/null)
    [ -n "$_rlss_rows" ] || { printf 'none'; return 0; }
    _rlss_res=$(restore_sysproxy_snapshot "$_rlss_rows")
    printf '%s' "$_rlss_res"
}
restore_doctor_journal() {
    if ! doctor_journal_has_restore; then
        printf 'none\t'
        return 0
    fi
    _rdj_count=$(doctor_journal_count)
    if [ "$_rdj_count" -eq 0 ]; then
        # 只有旧单槽位备份：它是 sysproxy 的，字段是 flags/server/bypass/pac。
        # 这条路径要兼容升级上来的机器——那是他们唯一的还原机会，
        # 所以必须**真的还原**，不能只回一句"没有可还原的记录"：
        # 界面刚刚还印着「输 r 回车」，按下去却什么也没发生，比不给这个选项更糟。
        if [ -f "$(sysproxy_backup_path)" ]; then
            _rdj_lg=$(restore_legacy_sysproxy_snapshot)
            printf '%s\tlegacy' "$_rdj_lg"
            # 撤成功了才删：留着会让 has_restore 一直为真，再按 r 又还原同一份旧快照。
            [ "$_rdj_lg" = 'ok' ] && rm -f "$(sysproxy_backup_path)" 2>/dev/null
            return 0
        fi
        printf 'none\t'
        return 0
    fi
    _rdj_insp=$(doctor_journal_last_field 'inspector')
    _rdj_restore=$(insp_field_of_id "$_rdj_insp" 6)
    if [ -z "$_rdj_restore" ] || ! declare -F "$_rdj_restore" >/dev/null 2>&1; then
        printf 'failed\t%s' "$_rdj_insp"
        return 0
    fi
    _rdj_out=$("$_rdj_restore" 2>/dev/null) || _rdj_out='failed'
    case "$_rdj_out" in
        ok)
            # 撤成功就消费掉那一段，让「再按一次往上撤一条」真的成立。
            # 不消费的话再按 r 取到的还是同一段，反复还原同一次——
            # 而界面上写的是「撤销上一次修复」，听起来像在逐条回退。与 Windows 侧同形。
            drop_last_doctor_journal_entry >/dev/null 2>&1 || true
            printf 'ok\t%s' "$_rdj_insp" ;;
        skip)   printf 'none\t%s' "$_rdj_insp" ;;
        *)      printf 'failed\t%s' "$_rdj_insp" ;;
    esac
    return 0
}

# ------------------------------------------------------------------------------
# 7. 救援页：遍历 Finding，不认任何具体检查器
# ------------------------------------------------------------------------------
# 这一屏只回答三件事：有没有问题、问题出在哪一行、我该敲什么。
# 结构与 Windows 侧同形（那边是 Show-RescuePage）。
#
# **它不认识任何检查器名字**：三个区（要修的 / 不归我碰的 / 只是提醒的）
# 全部按 Kind 分组算出来。加一层检查器，这一屏一个字都不用改。
show_rescue_page() {
    clear_screen_safe
    style_out title "======== 网络与代理修复 ========"
    echo ""
    # 第一句就说清它管到哪儿。名字里带「网络」，但用户到这里时心里想的是
    # 「我整个网都不行」——不说清，他会以为这一屏能修所有上网问题。
    style_out dim "  查浏览器、终端工具、网址解析这几处设置是不是指错了地方。"
    style_out dim "  只修「指向本机、但那个程序已经不在」的残留。"

    if ! assert_doctor_inspectors; then
        echo ""
        style_out warn "  检查器表有问题，这一屏没法用。"
        style_out dim "  按回车返回"
        read -r _rs_dummy || true
        return 1
    fi

    _rs_all=$(invoke_doctor_check full)
    # 本轮实际查了几层：按表里声明算，不写死数字。
    # 写死「三处」的话，某侧少一层（mac 没有 DNS 检查）时那句话就是假的。
    _rs_checked=0
    for _rs_row in ${DOCTOR_INSPECTORS[@]+"${DOCTOR_INSPECTORS[@]}"}; do
        _insp_field "$_rs_row" 4 >/dev/null 2>&1 && [ -n "$_insp_out" ] && _rs_checked=$((_rs_checked + 1))
    done
    _rs_fixable=0
    _rs_blocking=0
    _rs_slowing=0
    _rs_foreign=0
    _rs_managed=0
    _rs_hint=0
    _rs_alive=0
    # 「端口活着、但握手说它连不上外面」——只有拿到握手证据时才认这一档。
    # 拿不到握手（quick 档或权限不足）时**不算**，绝不凭猜给用户指方向。
    #
    # 这一档与「指向死端口」是两种病，必须分开说：建议用户去动系统代理
    # 并不会恢复网络（程序还在跑、还占着端口），只会把他能用的那条路径删掉。
    _rs_alivebroken=0
    if [ -n "$_rs_all" ]; then
        while IFS="$(printf '\t')" read -r _rs_id _rs_kind _rs_subj _rs_where _rs_val _rs_reason _rs_advice _rs_fix; do
            [ -n "$_rs_id" ] || continue
            case "$_rs_kind" in
                # 只在"真能修"时计数：下面那句「发现 N 处挡住了网络」承诺的是
                # "按 y 能修好"，把不可修的算进来就会说了却做不到。与 Windows 侧同形。
                "$FINDING_KIND_BLOCKING")
                    finding_repairable "$_rs_kind" "$_rs_id" && _rs_blocking=$((_rs_blocking + 1)) ;;
                "$FINDING_KIND_SLOWING")
                    finding_repairable "$_rs_kind" "$_rs_id" && _rs_slowing=$((_rs_slowing + 1)) ;;
                "$FINDING_KIND_ALIVE")
                    _rs_alive=$((_rs_alive + 1))
                    # 握手分类在那条 Finding 的 Reason 里（sysproxy 层用 get_sysproxy_reason 生成）。
                    # 只有明确说了「连不上外面」才认这一档。
                    case "$_rs_reason" in
                        *'连不上外面'*|*'没有回应'*) _rs_alivebroken=$((_rs_alivebroken + 1)) ;;
                    esac ;;
                "$FINDING_KIND_FOREIGN")
                    # 带「不会生效」这类措辞的是设置冲突，属于「只是提醒」；
                    # 其余 foreign 是「别人的东西，我没动」。
                    case "$_rs_reason" in
                        *'不会生效'*) _rs_hint=$((_rs_hint + 1)) ;;
                        *) _rs_foreign=$((_rs_foreign + 1)) ;;
                    esac ;;
                "$FINDING_KIND_MANAGED")  _rs_managed=$((_rs_managed + 1)) ;;
            esac
            finding_repairable "$_rs_kind" "$_rs_id" && _rs_fixable=$((_rs_fixable + 1))
        done <<EOF
$_rs_all
EOF
    fi

    # ---- 结论 ----
    echo ""
    _rs_outofscope=0
    if [ "$_rs_blocking" -gt 0 ]; then
        style_out warn "  查完了：发现 $_rs_blocking 处残留设置挡住了网络。"
    elif [ "$_rs_slowing" -gt 0 ]; then
        style_out warn "  查完了：发现 $_rs_slowing 处设置指向已经关掉的程序。"
        style_out dim "          网络能通，但每次都要先等它几秒。"
    elif [ "$_rs_alivebroken" -gt 0 ]; then
        style_out warn "  查完了：设置本身没坏，但代理连不上外面。"
        style_out dim "          这多半是节点的问题。关掉重开代理软件，或者换一个节点。"
        _rs_outofscope=1
    else
        # 「本工具不自动改、但问题确实存在」的那些（DNS 指向死端口就是）。
        # **必须先于「没发现问题」判**：上面三个计数只统计可修项，
        # 这类记录不会进任何一个——落进 else 就成了"屏幕第一句说你没问题"，
        # 紧接着的提醒区却在说网页会打不开。误报平安比不说更坏。
        if [ "$_rs_hint" -gt 0 ]; then
            style_out warn "  查完了：发现 $_rs_hint 处问题，但本工具不自动改（见下面的提醒）。"
        else
            style_out ok "  查完了：这几处设置都没发现问题（共查了 ${_rs_checked} 处）。"
        fi
        _rs_outofscope=1
    fi

    # ---- 要修的那些行 ----
    if [ "$_rs_fixable" -gt 0 ]; then
        echo ""
        style_out warn "  要修的是："
        while IFS="$(printf '\t')" read -r _rs_id _rs_kind _rs_subj _rs_where _rs_val _rs_reason _rs_advice _rs_fix; do
            [ -n "$_rs_id" ] || continue
            finding_repairable "$_rs_kind" "$_rs_id" || continue
            style_out text "    [$_rs_subj]  ${_rs_val:-（读不出地址）}"
            [ -n "$_rs_reason" ] && style_out dim "      $_rs_reason"
            # Advice 是「使用者能做什么」。写了就得显示。
            [ -n "$_rs_advice" ] && style_out dim "      $_rs_advice"
        done <<EOF
$_rs_all
EOF
    fi

    # ---- 只是提醒的那些（不归我碰，但用户该知道） ----
    if [ "$_rs_hint" -gt 0 ]; then
        echo ""
        style_out dim "  发现的网络状况（只是提醒，本工具不改）："
        while IFS="$(printf '\t')" read -r _rs_id _rs_kind _rs_subj _rs_where _rs_val _rs_reason _rs_advice _rs_fix; do
            [ -n "$_rs_id" ] || continue
            _rs_show=0
            if [ "$_rs_kind" = "$FINDING_KIND_FOREIGN" ]; then
                case "$_rs_reason" in
                    *'不会生效'*) _rs_show=1 ;;
                esac
            fi
            # 问题真实存在、但这一层没有 Fix 的（DNS 指向本机死端口就是）。
            # 它既不该进「要修的」，也不该进「不归我碰的」——漏了就会从三区里全部消失。
            if finding_fixable "$_rs_kind" && ! finding_repairable "$_rs_kind" "$_rs_id"; then
                _rs_show=1
            fi
            [ "$_rs_show" -eq 1 ] || continue
            style_out text "    [$_rs_subj]  $_rs_reason"
            [ -n "$_rs_advice" ] && style_out dim "      $_rs_advice"
        done <<EOF
$_rs_all
EOF
    fi

    # ---- 不归我们碰的那些 ----
    if [ "$_rs_foreign" -gt 0 ] || [ "$_rs_managed" -gt 0 ]; then
        echo ""
        style_out dim "  另外 $((_rs_foreign + _rs_managed)) 项是你自己设的，本工具不碰："
        while IFS="$(printf '\t')" read -r _rs_id _rs_kind _rs_subj _rs_where _rs_val _rs_reason _rs_advice _rs_fix; do
            [ -n "$_rs_id" ] || continue
            case "$_rs_kind" in
                "$FINDING_KIND_MANAGED")
                    style_out dim "    [$_rs_subj]  （这台电脑由管理员统一管着）" ;;
                "$FINDING_KIND_FOREIGN")
                    case "$_rs_reason" in
                        *'不会生效'*) : ;;
                        *) style_out dim "    [$_rs_subj]  ${_rs_val:-（地址没读到）}" ;;
                    esac ;;
            esac
        done <<EOF
$_rs_all
EOF
    fi

    # 读不出来的那一层不在这里显示：它不参与任何判断，纯粹是探测本身失败。
    # 印出来只会让使用者看到「系统给的格式认不出来」这种他无法行动、也无需知道的话。
    # 诊断信息归问题报告，那里读者是排查的人，不是正在看病的使用者。

    # ---- 兜底说明：讲清这一屏查不到什么 ----
    if [ "$_rs_outofscope" = "1" ]; then
        echo ""
        style_out dim "  如果还是上不了网，那问题不在这里："
        style_out dim "  可能是虚拟网卡（TUN）、路由表、或者防火墙规则。"
    fi

    # ---- 动作 ----
    #
    # 「能不能还原」与「当下有没有可修项」是两件事，必须分开判断。
    # 最常撞上的时序：昨天修过（还原点已写），今天客户端换回原端口，现在没有可修项了，
    # 用户想把设置改回原样——若按「可修项为零」提前返回，他只会看到「按回车返回」，
    # r 根本敲不到，而帮助页承诺了那条路。
    echo ""
    # 与同屏标题同宽：标题是手敲的 `======== 网络与代理修复 ========`（显示宽 26），
    # 分隔线原来硬写 62，一屏里出现 26/64 两种宽度，看着像两个部件拼成。
    # 按标题的显示宽度算（中文一字两格），下限 40，与 Windows 侧同一条口径。
    _rs_title_w=$(_display_width "网络与代理修复")
    _rs_rule_w=$((_rs_title_w + 2))
    [ "$_rs_rule_w" -lt 40 ] && _rs_rule_w=40
    _rs_rule="  $(printf '%*s' "$_rs_rule_w" '' | tr ' ' '-')"
    style_out dim "$_rs_rule"
    echo ""
    _rs_hasbak=0
    doctor_journal_has_restore && _rs_hasbak=1
    if [ "$_rs_fixable" -eq 0 ] && [ "$_rs_hasbak" -eq 0 ]; then
        style_out dim "  按回车返回"
        read -r _rs_dummy || true
        return 0
    fi
    [ "$_rs_fixable" -gt 0 ] && style_out text "  输 y 回车 = 修好上面那 $_rs_fixable 项（会先备份，能还原）"
    [ "$_rs_hasbak" -eq 1 ] && style_out dim "  输 r 回车 = 撤销上一次修复"
    style_out dim "  直接回车 = 什么都不做，返回"
    _rs_ans=""
    if ! read -r _rs_ans 2>/dev/null; then return 0; fi
    case "$_rs_ans" in
        r|R)
            [ "$_rs_hasbak" -eq 1 ] || return 0
            _rs_rr=$(restore_doctor_journal) || _rs_rr='failed	'
            _rs_rr_res=${_rs_rr%%	*}
            echo ""
            case "$_rs_rr_res" in
                ok)      style_out ok "  [完成] 已经改回上一次修复之前的样子。" ;;
                partial) style_out warn "  [未完成] 只改回去一部分。"
                         style_out dim "  可以再试一次；还不行就用主菜单的「问题反馈」生成一份报告。" ;;
                none)    style_out dim "  没有可还原的记录。" ;;
                *)       style_out warn "  [未完成] 没能改回去。可以再试一次。" ;;
            esac
            style_out dim "  按回车返回"
            read -r _rs_dummy || true
            return 0 ;;
        y|Y|yes|YES|是) ;;
        *) return 0 ;;
    esac
    [ "$_rs_fixable" -gt 0 ] || return 0

    # ---- 真动手：按检查器分组，各修各的 ----
    #
    # **只调表里声明的 Fix**，不认具体名字。修的顺序按注册表顺序（网络 → 浏览器 → 终端），
    # 因为越靠下的一层越可能是上层症状的来源。
    #
    # mac 上改系统代理要管理员，会弹一次系统密码框——先告诉用户，别让他以为卡死了。
    echo ""
    style_out text "  接下来会弹一个要开机密码的窗口，那是系统的，不是要装别的东西。"
    _rs_anyfixed=0
    _rs_anyfail=0
    _rs_aborted=0
    for _rs_row in ${DOCTOR_INSPECTORS[@]+"${DOCTOR_INSPECTORS[@]}"}; do
        _insp_field "$_rs_row" 1; _rs_iid=$_insp_out
        _insp_field "$_rs_row" 2; _rs_ititle=$_insp_out
        _insp_field "$_rs_row" 5; _rs_ifix=$_insp_out
        [ -n "$_rs_ifix" ] || continue
        declare -F "$_rs_ifix" >/dev/null 2>&1 || continue
        # 这一层有没有可修项？
        _rs_mine=$(printf '%s\n' "$_rs_all" | awk -F"\t" -v pre="$_rs_iid." '
            index($1, pre) == 1 && ($2 == "residue-blocking" || $2 == "residue-slowing") { c++ }
            END { print c+0 }')
        [ "${_rs_mine:-0}" -gt 0 ] || continue
        _rs_res=$("$_rs_ifix" 2>/dev/null) || _rs_res='failed'
        case "$_rs_res" in
            fixed)   _rs_anyfixed=1 ;;
            partial) _rs_anyfail=1 ;;
            failed)  _rs_anyfail=1 ;;
            nobackup) _rs_anyfail=1; _rs_aborted=1 ;;
            none)    : ;;
            *)       _rs_anyfail=1 ;;
        esac
        [ "$_rs_aborted" = "1" ] && break
    done

    echo ""
    # 结论必须三态，不许把「部分失败」压成「修好了」。
    if [ "$_rs_aborted" = "1" ]; then
        style_out warn "  [未完成] 备份写不下来，为了安全停在这里。"
        style_out dim "  已经改过的部分可以输 r 撤销。确认日志目录可写之后再来一次。"
    elif [ "$_rs_anyfail" = "1" ]; then
        style_out warn "  [未完成] 修好了一部分，还有没改成的。"
        style_out dim "  可以再试一次；还不行就用主菜单的「问题反馈」生成一份报告。"
    elif [ "$_rs_anyfixed" = "1" ]; then
        style_out ok "  [完成] 修好了。"
        style_out dim "  浏览器要是还打不开，把它关掉重开一次。"
        style_out dim "  终端里已经开着的窗口也一样，重开一个即可。"
    else
        style_out dim "  查的时候还在，动手的时候已经没了（可能是你自己关掉了）。"
    fi
    style_out dim "  按回车返回"
    read -r _rs_dummy || true
    return 0
}
