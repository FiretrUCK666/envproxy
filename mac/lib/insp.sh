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
# 六列，管道分隔（与 Windows 侧同一组字段，便于门禁逐项比对）：
#   1 Id       稳定标识，写进还原点的 inspector 字段
#   2 Title    界面上那一组叫什么（用户看得懂的说法，不是内部名）
#   3 Quick    状态页（每 2–3 秒）要不要跑它：1 = 要，0 = 只在全量档跑
#   4 Detect   输出 Finding 行的函数名
#   5 Fix      修它的函数名；空 = 只诊断不修
#   6 Restore  撤销函数名（门禁核对「声明了可修就得有撤销的路」）
#
# **顺序就是界面上的顺序**：按网络分层从低到高（网址解析 → 浏览器 → 终端工具），
# 与人排查故障的方向一致——先看是不是连名字都解析不了，再看浏览器，最后看工具。
#
# 贵的一律 Quick=0：状态页刷新的代价以毫秒计，跑一次要读文件或连端口的
# 检查器进去就把刷新拖垮了。
DOCTOR_INSPECTORS=(
    'dns|网址解析|0|get_dns_findings||'
    'sysproxy|浏览器代理|1|get_sysproxy_findings|sysproxy_repair|restore_sysproxy_snapshot'
    'cli-proxy|终端工具里的代理|0|get_cli_proxy_findings|repair_cli_proxy_config|restore_cli_proxy_snapshot'
    'socks|只认 SOCKS 的端口|0|get_socks_findings||'
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
# 三件事缺一不可：Kind 说「这是什么性质的问题」，Fix 列说「我们被授权动这一层吗」，
# 这一条记录自己说「这股形态能不能安全改」（Finding 第 8 列；空 = 没声明，按允许处理）。
# 只看 Kind 会让「DNS 指向本机死端口」（Blocking、但那一层 Fix 为空）进「要修的」，
# 用户按 y 什么都不修，屏幕还说"它自己消失了"。
# 第三维是随工具配置一起长出来的：同一个 cli-proxy 层里，`.npmrc` 删一行是安全的，
# `settings.xml` 的 <proxy> 块删一半会留下坏配置——所以「能不能动」只能由
# **看得见文件格式的那一层**回答，不能由 Kind 或表猜。与 Windows 侧的
# Finding.Data.Repairable 同义（那边用结构化字段，这边用 Finding 的第 8 列）。
# 参数：$1 = Kind，$2 = 检查器 Id，$3 = 这一条声明的可改性（1 / 0 / 空）
finding_repairable() {
    _fr_kind="${1:-}"; _fr_id="${2:-}"; _fr_rep="${3:-}"
    finding_fixable "$_fr_kind" || return 1
    [ "$_fr_rep" = "0" ] && return 1
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
# 这条 Finding 属于「只是提醒」那一类吗（用户该知道，但本工具不改）？
#
# **判 Id，不判 Reason 里的中文。** 文案会改，判据不该跟着改：
# 改一次措辞就静默换区，不报错也不失败，是最难查的那种坏法。
# 与 Windows 侧 Finding.Data.Tag 是同一件事（那边用结构化字段，这边用 Id 后缀）。
# 这条 Finding 是「端口活着、但连不上外面」那一档吗？
# 判 Id 后缀，不判 Reason 里的中文（理由同 finding_is_hint）。
finding_is_upstream_fail() {
    case "${1:-}" in
        *.upstreamfail) return 0 ;;
    esac
    return 1
}
finding_is_hint() {
    case "${1:-}" in
        *.overlay) return 0 ;;
    esac
    return 1
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
            refused)
                _gsf_reason="$_gsf_reason　它说 HTTP，但这次不答应建隧道（不是代理，或者它只服务特定地址）。" ;;
            not-http)
                _gsf_reason="$_gsf_reason　它不像代理，更像别的程序占着这个端口。" ;;
            silent)
                _gsf_reason="$_gsf_reason　它连上了但不应答代理握手。" ;;
        esac
        # Id 后缀带上握手结论：界面上要认「端口活着但连不上外面」那一档，
        # 靠的就是它。**不能靠 Reason 里的中文反推**——文案一改，那一档就不报了，
        # 不报错也不失败。后缀是稳定的语义标识，措辞随便改。
        _gsf_id="sysproxy.$_gsf_l"
        case "${_gsf_hs:-}" in
            upstream-fail) _gsf_id="$_gsf_id.upstreamfail" ;;
        esac
        finding_new "$_gsf_id" "$_gsf_kind" '浏览器代理' "$_gsf_where" \
            "${_gsf_url:-}" "$_gsf_reason" \
            "$(get_sysproxy_advice "$_gsf_kind")" ''
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
# 为什么环境变量救不了它：这些配置文件里写的代理**优先级高于环境变量**。
# EnvProxy 把变量管得再好，也压不过它。而现实里这些文件最常出现的毛病就是
# 「跟着某篇教程写死过一个本机端口，后来软件换了端口/卸载了」。
#
# 边界（比系统代理更严，因为这里动的是用户的文件，不是系统设置）：
#   · 只认「本机回环 + 端口不通」，与系统代理同一套判据；
#   · 非回环（公司代理）、读不出来 → 一律不动；
#   · 文件里有 include / includeIf → 不动：代理可能来自被包含的另一个文件；
#   · 只动命中行，不重写整个文件；改前整份原文进还原点，能逐字撤回。
#
# 三种修法（目标表的第 7 列，见下表）：
#   drop       删掉那一项。给「自己认环境变量」的工具用：删掉之后它读 EnvProxy
#              注入的值，比改成某个具体端口更耐用——端口再变它自己跟上。
#   port       有活着的代理就改成当前端口，没有就删掉（Gradle / SSH）。
#   port-only  只能改端口，删不了：它们的配置是嵌套结构或成对元素
#              （YAML 的 proxy_servers、XML 的 <proxy>），删一半会留下坏配置。
#              没有活代理时**只报告不动手**——「拿不准就不动」在这里的落点。
#
# 表是唯一权威：加一个工具 = 加一行，读、判、修全部从它派生。
# 八列（用 | 分隔，空列写成相邻两个 |）：
#   1 Id        稳定标识（进 Finding Id 与还原点）。两侧同 Id（门禁 6 核对）
#   2 显示名    界面上那一组叫什么
#   3 Format    kv / yaml / yaml-nested / yarnrc / xml / ssh
#   4 Section   段名（kv 与 yaml-nested 用；空 = 顶层键或不限段）
#   5 Keys      命中哪些键（空格分隔）
#   6 Pair      成对键，写成"主机键=端口键"（只有 Gradle 这样写）
#   7 Fix       修法：drop / port / port-only
#   8 Files     候选文件，逗号分隔，形如 "根:相对路径"；根取 home / appdata / support
CLI_PROXY_TARGETS=(
    'git|Git 自己的代理|kv||http.proxy https.proxy||drop|home:.gitconfig'
    'npm|npm 自己的代理|kv||proxy https-proxy||drop|home:.npmrc'
    'curl|curl 自己的代理|kv||proxy x||drop|home:.curlrc'
    'cargo|Cargo 自己的代理|kv|http|proxy||drop|home:.cargo/config.toml,home:.cargo/config'
    'pip|pip 自己的代理|kv|global|proxy||drop|home:.config/pip/pip.conf,support:pip/pip.conf,home:.pip/pip.conf'
    'wget|wget 自己的代理|kv||http_proxy https_proxy||drop|home:.wgetrc'
    'yarn|Yarn 自己的代理|yarnrc||proxy https-proxy||drop|home:.yarnrc'
    'yarn-berry|Yarn（新版）自己的代理|yaml||httpProxy httpsProxy||drop|home:.yarnrc.yml'
    'gradle|Gradle 自己的代理|kv|||systemProp.http.proxyHost=systemProp.http.proxyPort|port|home:.gradle/gradle.properties'
    'conda|Conda 自己的代理|yaml-nested|proxy_servers|http https||port-only|home:.condarc'
    'maven|Maven 自己的代理|xml||||port-only|home:.m2/settings.xml'
    'nuget|NuGet 自己的代理|xml||||port-only|home:.nuget/NuGet/NuGet.Config'
    'ssh|SSH 自己的代理|ssh||||port|home:.ssh/config'
)

# 根目录。取不到返回空串 = 这个文件在这台机器上不适用。
# **不写死用户名**：拿不到家目录还去拼一个路径，改的可能是别人的东西。
cli_proxy_root() {
    case "${1:-home}" in
        support)
            [ -n "${HOME:-}" ] || { printf ''; return 0; }
            printf '%s/Library/Application Support' "$HOME" ;;
        appdata)
            # macOS 没有 %APPDATA% 这回事。列留着是为了两侧表同形（门禁 6 比 Id 集合）。
            printf '' ;;
        *)
            [ -n "${HOME:-}" ] || { printf ''; return 0; }
            printf '%s' "$HOME" ;;
    esac
}

# 这个目标的全部候选绝对路径（一行一个，按表里的顺序）。
# 自检用 CLI_PROXY_HOME_OVERRIDE 把家目录整体改道——绝不能碰使用者的真文件。
cli_proxy_file_paths() {
    _cpt_files=''
    _insp_field "${1:-}" 8 || return 0
    _cpt_files=$_insp_out
    _cpt_rest="$_cpt_files"
    while [ -n "$_cpt_rest" ]; do
        case "$_cpt_rest" in
            *,*) _cpt_one=${_cpt_rest%%,*}; _cpt_rest=${_cpt_rest#*,} ;;
            *)   _cpt_one=$_cpt_rest; _cpt_rest='' ;;
        esac
        [ -n "$_cpt_one" ] || continue
        case "$_cpt_one" in
            *:*) _cpt_root=${_cpt_one%%:*}; _cpt_rel=${_cpt_one#*:} ;;
            *)   _cpt_root='home'; _cpt_rel=$_cpt_one ;;
        esac
        if [ -n "${CLI_PROXY_HOME_OVERRIDE:-}" ]; then
            printf '%s/%s\n' "$CLI_PROXY_HOME_OVERRIDE" "$_cpt_rel"
            continue
        fi
        _cpt_base=$(cli_proxy_root "$_cpt_root")
        [ -n "$_cpt_base" ] || continue
        printf '%s/%s\n' "$_cpt_base" "$_cpt_rel"
    done
    return 0
}

# 去掉首尾空白（纯 shell，不起子进程）。结果写进 _cpt_trim。
_cpt_trim() {
    _cpt_trim_v="${1:-}"
    _cpt_trim_v="${_cpt_trim_v#"${_cpt_trim_v%%[![:space:]]*}"}"
    _cpt_trim_v="${_cpt_trim_v%"${_cpt_trim_v##*[![:space:]]}"}"
    _cpt_trim=$_cpt_trim_v
}

# 从一行里取「键 = 值」，结果写进 _cfl_key 与 _cfl_val。不是键值行时返回 1。
# $2 决定认哪种写法：
#   equals  proxy = http://...       （gitconfig / npmrc / curlrc / pip.conf / config.toml / wgetrc / gradle.properties）
#   colon   httpProxy: "http://..."  （yarnrc.yml / condarc）
#   space   proxy "http://..."       （yarnrc classic）
#
# 行内注释**必须先剥掉**：`proxy = 127.0.0.1:7890 # clash` 是很常见的写法，
# 带着注释去解析会得到「值认不出来」，于是这个死端口永远查不出来——静默漏检。
# 剥的判据是「注释符前面有空白」：URL 里不会出现 ` #`，而人写注释总会空一格。
# 纯 shell 实现（不起子进程）：一屏要读十几个文件，逐行 fork 会慢到没法用。
_cfl_key=''
_cfl_val=''
_cli_config_line_parse() {
    _cfl_key=''; _cfl_val=''
    _cfl_sep="${2:-equals}"
    _cpt_trim "${1:-}"
    _cfl_t=$_cpt_trim
    [ -n "$_cfl_t" ] || return 1
    case "$_cfl_t" in
        '#'*|';'*) return 1 ;;
        '['*) return 1 ;;
    esac
    # 行内注释：取「最早的、前面带空白的 # 或 ;」之前那一段。
    # ${var%%pattern} 删的是**最长**匹配后缀，所以命中的是最早那个注释符。
    case "$_cfl_t" in
        *[[:space:]][#\;]*)
            _cfl_t="${_cfl_t%%[[:space:]][#\;]*}"
            while [ -n "$_cfl_t" ]; do
                case "$_cfl_t" in
                    *[[:space:]]) _cfl_t=${_cfl_t%[[:space:]]} ;;
                    *) break ;;
                esac
            done ;;
    esac
    [ -n "$_cfl_t" ] || return 1
    case "$_cfl_sep" in
        colon)
            case "$_cfl_t" in *:*) : ;; *) return 1 ;; esac
            _cfl_key="${_cfl_t%%:*}"
            _cfl_val="${_cfl_t#*:}" ;;
        space)
            case "$_cfl_t" in *[[:space:]]*) : ;; *) return 1 ;; esac
            _cfl_key="${_cfl_t%%[[:space:]]*}"
            _cfl_val="${_cfl_t#*[[:space:]]}" ;;
        *)
            case "$_cfl_t" in *=*) : ;; *) return 1 ;; esac
            _cfl_key="${_cfl_t%%=*}"
            _cfl_val="${_cfl_t#*=}" ;;
    esac
    _cpt_trim "$_cfl_key"; _cfl_key=$_cpt_trim
    # 键名：字母开头，只含字母数字与 _ . -
    case "$_cfl_key" in
        ''|[!A-Za-z]*|*[!A-Za-z0-9_.-]*) return 1 ;;
    esac
    _cpt_trim "$_cfl_val"; _cfl_val=$_cpt_trim
    # 剥引号：只在成对时剥，避免把值尾部的合法字符当引号删掉。
    case "$_cfl_val" in
        \"*\") _cfl_val="${_cfl_val#\"}"; _cfl_val="${_cfl_val%\"}" ;;
        \'*\') _cfl_val="${_cfl_val#\'}"; _cfl_val="${_cfl_val%\'}" ;;
    esac
    return 0
}

# 从代理值里取裸主机与端口，结果写进 _csv_host / _csv_port。取不到返回 1。
# 必须认三种写法：`127.0.0.1:7890`、`http://[::1]:7890`、`socks5://host:7890`。
_cli_split_value() {
    _csv_host=''; _csv_port=''
    _csv_v="${1:-}"
    case "$_csv_v" in
        *'://'*) _csv_v="${_csv_v#*://}" ;;
    esac
    _csv_v="${_csv_v%%/*}"
    case "$_csv_v" in *@*) _csv_v="${_csv_v##*@}" ;; esac
    case "$_csv_v" in
        '['*']'*)
            _csv_host="${_csv_v#[}"
            _csv_host="${_csv_host%%]*}"
            _csv_port="${_csv_v##*]:}" ;;
        *:*)
            _csv_host="${_csv_v%:*}"
            _csv_port="${_csv_v##*:}" ;;
        *) return 1 ;;
    esac
    case "$_csv_port" in ''|*[!0-9]*) _csv_host=''; _csv_port=''; return 1 ;; esac
    [ "$_csv_port" -gt 0 ] 2>/dev/null || { _csv_host=''; _csv_port=''; return 1; }
    return 0
}

# 输出一条命中项。十列，TAB 分隔：
#   Line <TAB> Lines <TAB> Key <TAB> Value <TAB> Host <TAB> Port <TAB> FixLine <TAB> PortOnly <TAB> Inc <TAB> Raw
# Lines 是「要删掉的话删哪几行」（成对键是两行，逗号分隔）。
# Inc 是「这个文件里有 include」（1/0）：有 include 的代理可能来自别处，改这一行没用。
_cli_entry_emit() {
    _cee_tab="$(printf '\t')"
    _cee_raw="$(printf '%s' "${10:-}" | tr '\t' ' ')"
    printf '%s\n' "${1}${_cee_tab}${2}${_cee_tab}${3}${_cee_tab}${4}${_cee_tab}${5}${_cee_tab}${6}${_cee_tab}${7}${_cee_tab}${8}${_cee_tab}${9:-0}${_cee_tab}${_cee_raw}"
}

# 读一个文件里的全部代理项。输出条目行；读不出来时输出一行以 ! 开头的原因。
# 文件不存在 = 读成功、零条目（「这一层不存在」不是「读不出来」）。
read_cli_proxy_file() {
    _rcpf_path="${1:-}"; _rcpf_row="${2:-}"
    [ -n "$_rcpf_path" ] || { printf '%s\n' '!找不到这个文件所在的目录'; return 0; }
    [ -f "$_rcpf_path" ] || return 0
    [ -r "$_rcpf_path" ] || { printf '%s\n' '!没有读权限'; return 0; }
    _insp_field "$_rcpf_row" 3; _rcpf_fmt=$_insp_out
    case "$_rcpf_fmt" in
        xml)         _cli_read_xml "$_rcpf_path" "$_rcpf_row" ;;
        ssh)         _cli_read_ssh "$_rcpf_path" "$_rcpf_row" ;;
        yaml)        _cli_read_kv "$_rcpf_path" "$_rcpf_row" colon '' ;;
        yarnrc)      _cli_read_kv "$_rcpf_path" "$_rcpf_row" space '' ;;
        yaml-nested) _cli_read_kv "$_rcpf_path" "$_rcpf_row" colon nested ;;
        *)           _cli_read_kv "$_rcpf_path" "$_rcpf_row" equals '' ;;
    esac
    return 0
}

# 输出这个文件里有没有 include / includeIf（1 / 0）。
_cli_file_has_include() {
    _fhi_hit=0
    while IFS= read -r _fhi_scan || [ -n "$_fhi_scan" ]; do
        _fhi_st="$_fhi_scan"
        _fhi_st="${_fhi_st#"${_fhi_st%%[![:space:]]*}"}"
        case "$_fhi_st" in
            '['*)
                _fhi_si="${_fhi_st#\[}"
                _fhi_si="${_fhi_si%%\]*}"
                _fhi_si="${_fhi_si%%[[:space:]]*}"
                _fhi_si=$(printf '%s' "$_fhi_si" | tr 'A-Z' 'a-z')
                case "$_fhi_si" in
                    include|includeif) _fhi_hit=1 ;;
                esac ;;
        esac
    done < "$1"
    printf '%s' "$_fhi_hit"
}

# 「一行一项」的三种写法共用这一份读法：差别只在分隔符、段头、父键。
#
# 两遍读。第一遍只为回答「这个文件里有没有 include」，第二遍才逐行判命中。
# 为什么必须两遍：`[include]` 段可能出现在文件任何位置——实测最常见的写法是
# 把它放在最后。一遍扫的话，前面那些 proxy 行在被收集时还不知道后面有 include，
# 于是「有 include 就不动」这条护栏在最需要它的文件上失效——而这个失效是静默的。
_cli_read_kv() {
    _rk_path="$1"; _rk_row="$2"; _rk_sep="$3"; _rk_nested="$4"
    _rk_tab="$(printf '\t')"
    _rk_inc=$(_cli_file_has_include "$_rk_path")
    _insp_field "$_rk_row" 4 || true; _rk_section_want=$_insp_out
    _insp_field "$_rk_row" 5 || true; _rk_keys=$_insp_out
    _insp_field "$_rk_row" 6 || true; _rk_pair=$_insp_out
    _rk_want=' '
    for _rk_k in $_rk_keys; do
        _rk_l=$(printf '%s' "$_rk_k" | tr 'A-Z' 'a-z')
        _rk_want="$_rk_want$_rk_l "
    done
    for _rk_p in $_rk_pair; do
        case "$_rk_p" in
            *=*)
                _rk_ph=$(printf '%s' "${_rk_p%%=*}" | tr 'A-Z' 'a-z')
                _rk_pp=$(printf '%s' "${_rk_p#*=}" | tr 'A-Z' 'a-z')
                _rk_want="$_rk_want$_rk_ph $_rk_pp " ;;
        esac
    done
    _rk_sec=''; _rk_parent=''; _rk_n=0
    _rk_hits=''
    while IFS= read -r _rk_raw || [ -n "$_rk_raw" ]; do
        _rk_n=$((_rk_n + 1))
        _cpt_trim "$_rk_raw"; _rk_t=$_cpt_trim
        [ -n "$_rk_t" ] || continue
        case "$_rk_t" in
            '['*)
                _rk_inner="${_rk_t#\[}"
                _rk_inner="${_rk_inner%%\]*}"
                _rk_sec="${_rk_inner%%[[:space:]]*}"
                _rk_sec=$(printf '%s' "$_rk_sec" | tr 'A-Z' 'a-z')
                _rk_parent=''
                continue ;;
        esac
        case "$_rk_t" in '#'*|';'*) continue ;; esac
        _rk_indented=0
        case "$_rk_raw" in [[:space:]]*) _rk_indented=1 ;; esac
        _cli_config_line_parse "$_rk_raw" "$_rk_sep" || continue
        _rk_leaf=$(printf '%s' "$_cfl_key" | tr 'A-Z' 'a-z')
        _rk_full="$_rk_leaf"
        if [ "$_rk_nested" = "nested" ]; then
            if [ "$_rk_indented" = "0" ]; then
                _rk_parent="$_rk_leaf"
                continue
            fi
            [ -n "$_rk_parent" ] || continue
            _rk_full="$_rk_parent.$_rk_leaf"
            if [ -n "$_rk_section_want" ]; then
                _rk_sw=$(printf '%s' "$_rk_section_want" | tr 'A-Z' 'a-z')
                [ "$_rk_parent" = "$_rk_sw" ] || continue
            fi
        elif [ -n "$_rk_section_want" ]; then
            _rk_sw=$(printf '%s' "$_rk_section_want" | tr 'A-Z' 'a-z')
            [ "$_rk_sec" = "$_rk_sw" ] || continue
        elif [ -n "$_rk_sec" ]; then
            _rk_full="$_rk_sec.$_rk_leaf"
        fi
        _rk_hit=0
        case "$_rk_want" in
            *" $_rk_full "*) _rk_hit=1 ;;
            *" $_rk_leaf "*) _rk_hit=1 ;;
        esac
        [ "$_rk_hit" = "1" ] || continue
        _rk_hits="$_rk_hits$_rk_n${_rk_tab}$_rk_leaf${_rk_tab}$_rk_full${_rk_tab}$_cfl_val${_rk_tab}$_rk_raw
"
    done < "$_rk_path"

    # ---- 成对键（Gradle）：主机与端口分两行写，必须凑齐才算一项 ----
    if [ -n "$_rk_pair" ]; then
        for _rk_p in $_rk_pair; do
            case "$_rk_p" in *=*) : ;; *) continue ;; esac
            _rk_ph=$(printf '%s' "${_rk_p%%=*}" | tr 'A-Z' 'a-z')
            _rk_pp=$(printf '%s' "${_rk_p#*=}" | tr 'A-Z' 'a-z')
            _rk_hline=''; _rk_hval=''; _rk_pl=''; _rk_pval=''
            while IFS="$_rk_tab" read -r _rk_l _rk_k _rk_f _rk_v _rk_r; do
                [ -n "$_rk_l" ] || continue
                if [ -z "$_rk_hline" ] && [ "$_rk_k" = "$_rk_ph" ]; then _rk_hline="$_rk_l"; _rk_hval="$_rk_v"; fi
                if [ -z "$_rk_pl" ] && [ "$_rk_k" = "$_rk_pp" ]; then _rk_pl="$_rk_l"; _rk_pval="$_rk_v"; fi
            done <<EOF
$_rk_hits
EOF
            # 只写了一行的是半截配置：那一行不生效，判死会让用户以为这里挡住了网络。
            [ -n "$_rk_hline" ] && [ -n "$_rk_pl" ] || continue
            case "$_rk_pval" in ''|*[!0-9]*) continue ;; esac
            [ "$_rk_pval" -gt 0 ] 2>/dev/null || continue
            _cli_split_value "$_rk_hval:$_rk_pval" || continue
            _cli_entry_emit "$_rk_pl" "$_rk_hline,$_rk_pl" "$_rk_ph" \
                "http://$_csv_host:$_csv_port" "$_csv_host" "$_csv_port" "$_rk_pl" "1" "$_rk_inc" "$_rk_hval:$_rk_pval"
        done
        return 0
    fi

    while IFS="$_rk_tab" read -r _rk_l _rk_k _rk_f _rk_v _rk_r; do
        [ -n "$_rk_l" ] || continue
        [ -n "$_rk_v" ] || continue
        _cli_split_value "$_rk_v" || true
        _cli_entry_emit "$_rk_l" "$_rk_l" "$_rk_f" "$_rk_v" "$_csv_host" "$_csv_port" "$_rk_l" "0" "$_rk_inc" "$_rk_r"
    done <<EOF
$_rk_hits
EOF
}

# Maven 的 settings.xml：<proxy> 块里 <host> 与 <port> 各是一个元素，
# 还能有 <active>false</active>（那一块根本不生效）与 <protocol>。
# NuGet 的 NuGet.Config：<add key="http_proxy" value="..." />。
#
# 只认能完整读出的块：缺 host、缺 port、<active>false</active>、块没闭合——
# 一律不产结论。那种情况下我们连"它在挡哪条路"都说不清，说成故障就是编的。
_cli_read_xml() {
    _x_path="$1"
    _x_in=0; _x_start=0; _x_host=''; _x_port=''; _x_active='true'; _x_proto=''
    _x_hostline=0; _x_portline=0; _x_n=0
    while IFS= read -r _x_raw || [ -n "$_x_raw" ]; do
        _x_n=$((_x_n + 1))
        _cpt_trim "$_x_raw"; _x_t=$_cpt_trim
        [ -n "$_x_t" ] || continue
        case "$_x_t" in '<!--'*) continue ;; esac
        if [ "$_x_in" = "0" ]; then
            case "$_x_t" in
                *'<proxy'*)
                    _x_in=1; _x_start=$_x_n
                    _x_host=''; _x_port=''; _x_active='true'; _x_proto=''
                    _x_hostline=0; _x_portline=0 ;;
                *'<add'*)
                    _cli_xml_add_line "$_x_t" "$_x_n" ;;
                *) continue ;;
            esac
        fi
        case "$_x_t" in
            *'<host>'*) _x_v="${_x_t#*<host>}"; _x_host="${_x_v%%</host>*}"; _x_hostline=$_x_n ;;
        esac
        case "$_x_t" in
            *'<port>'*) _x_v="${_x_t#*<port>}"; _x_port="${_x_v%%</port>*}"; _x_portline=$_x_n ;;
        esac
        case "$_x_t" in
            *'<active>'*) _x_v="${_x_t#*<active>}"; _x_active="${_x_v%%</active>*}" ;;
        esac
        case "$_x_t" in
            *'<protocol>'*) _x_v="${_x_t#*<protocol>}"; _x_proto="${_x_v%%</protocol>*}" ;;
        esac
        case "$_x_t" in
            *'</proxy>'*)
                case "$_x_port" in ''|*[!0-9]*) _x_port='' ;; esac
                if [ -n "$_x_host" ] && [ -n "$_x_port" ] && [ "$_x_portline" -gt 0 ] 2>/dev/null; then
                    _x_act=$(printf '%s' "$_x_active" | tr 'A-Z' 'a-z')
                    if [ "$_x_act" != "false" ]; then
                        _x_pt=$(printf '%s' "$_x_proto" | tr 'A-Z' 'a-z')
                        _x_val="http://$_x_host:$_x_port"
                        case "$_x_pt" in
                            socks5|socks) _x_val="socks5://$_x_host:$_x_port" ;;
                        esac
                        _cli_split_value "$_x_val" || true
                        _cli_entry_emit "$_x_portline" "$_x_portline" "proxy" \
                            "$_x_val" "$_csv_host" "$_csv_port" "$_x_portline" "1" "0" "$_x_host:$_x_port"
                    fi
                fi
                _x_in=0 ;;
        esac
    done < "$_x_path"
}

# NuGet 的那一行：<add key="http_proxy" value="http://127.0.0.1:7890" />
# 属性顺序、引号种类都可能不同，逐个形态认；认不出就当没有（宁漏不误）。
_cli_xml_add_line() {
    _xa_line="$1"; _xa_n="$2"
    _xa_lc=$(printf '%s' "$_xa_line" | tr 'A-Z' 'a-z')
    case "$_xa_lc" in
        *'key="http_proxy"'*) ;;
        *"key='http_proxy'"*) ;;
        *) return 0 ;;
    esac
    _xa_val=''
    case "$_xa_line" in
        *'value="'*) _xa_v="${_xa_line#*value=\"}"; _xa_val="${_xa_v%%\"*}" ;;
        *"value='"*) _xa_v="${_xa_line#*value=\'}"; _xa_val="${_xa_v%%\'*}" ;;
    esac
    [ -n "$_xa_val" ] || return 0
    _cli_split_value "$_xa_val" || return 0
    _cli_entry_emit "$_xa_n" "$_xa_n" "http_proxy" "$_xa_val" "$_csv_host" "$_csv_port" "$_xa_n" "0" "0" "$_xa_line"
    return 0
}

# SSH 的 ~/.ssh/config：OpenSSH 完全不看 HTTP_PROXY，只认 ProxyCommand / ProxyJump。
# 这里只找「本机回环地址 + 端口」那一种形态（常见写法是
# `ProxyCommand nc -X connect -x 127.0.0.1:7890 %h %p` 或 `connect -H 127.0.0.1:7890`）。
# 目标写成域名别名的（ProxyJump bastion）不是本机代理，不产结论。
_cli_read_ssh() {
    _s_path="$1"
    _s_n=0
    while IFS= read -r _s_raw || [ -n "$_s_raw" ]; do
        _s_n=$((_s_n + 1))
        _cpt_trim "$_s_raw"; _s_t=$_cpt_trim
        [ -n "$_s_t" ] || continue
        case "$_s_t" in '#'*) continue ;; esac
        case "$_s_t" in
            [Pp]roxy[Cc]ommand[[:space:]]*|[Pp]roxy[Jj]ump[[:space:]]*) ;;
            *) continue ;;
        esac
        _s_rest="${_s_t#*[[:space:]]}"
        _s_host=''; _s_port=''
        case "$_s_rest" in
            *'127.0.0.1:'*) _s_host='127.0.0.1'; _s_v="${_s_rest#*127.0.0.1:}" ;;
            *'localhost:'*)  _s_host='localhost';  _s_v="${_s_rest#*localhost:}" ;;
            *'[::1]:'*)      _s_host='::1';        _s_v="${_s_rest#*\[::1\]:}" ;;
            *) continue ;;
        esac
        _s_port="${_s_v%%[!0-9]*}"
        case "$_s_port" in ''|*[!0-9]*) continue ;; esac
        [ "$_s_port" -gt 0 ] 2>/dev/null || continue
        _cli_entry_emit "$_s_n" "$_s_n" "ProxyCommand" \
            "http://$_s_host:$_s_port" "$_s_host" "$_s_port" "$_s_n" "0" "0" "$_s_t"
    done < "$_s_path"
}

# 纯判据（与 Windows 侧 Get-CliProxyVerdict 逐条同形）：
#   $1 值   $2 死活（alive / dead / unknown）   $3 文件里有 include：1 / 0
# 归 foreign 而不是可修——「修了也没用」等于没修，报成修好就是谎报。
cli_proxy_verdict() {
    _cpv_val="${1:-}"; _cpv_alive="${2:-unknown}"; _cpv_inc="${3:-0}"
    [ -n "$_cpv_val" ] || { printf '%s' "$FINDING_KIND_CLEAN"; return 0; }
    # 解析不出地址：认不出来就说什么都不做。**不许当 clean**——
    # clean 是「这里没设」，而这里明明写了一行我们看不懂的东西。
    _cpv_url=$(_url_host "$_cpv_val") || { printf '%s' "$FINDING_KIND_FOREIGN"; return 0; }
    [ -n "$_cpv_url" ] || { printf '%s' "$FINDING_KIND_FOREIGN"; return 0; }
    is_loopback_url "$_cpv_val" || { printf '%s' "$FINDING_KIND_FOREIGN"; return 0; }
    # 文件里有 include：代理可能来自别处，改这一行解决不了问题。
    [ "$_cpv_inc" = "1" ] && { printf '%s' "$FINDING_KIND_FOREIGN"; return 0; }
    # 说不清死活时不动：判成可修然后删掉一个其实在用的代理，代价是用户唯一的上网路径没了。
    [ "$_cpv_alive" = "unknown" ] && { printf '%s' "$FINDING_KIND_FOREIGN"; return 0; }
    [ "$_cpv_alive" = "alive" ] && { printf '%s' "$FINDING_KIND_ALIVE"; return 0; }
    printf '%s' "$FINDING_KIND_BLOCKING"
    return 0
}

# 这一项该怎么修（与目标表的 Fix 列不同：这里还看「现在有没有活着的代理」）。
#   $1 = 表里的 Fix 列   $2 = 现在有没有活代理（1/0）
#   drop 删掉那一项 / port 改成当前端口 / none 本工具不动手，只报告
cli_proxy_entry_mode() {
    case "${1:-drop}" in
        port-only) if [ "${2:-0}" = "1" ]; then printf 'port'; else printf 'none'; fi ;;
        port)      if [ "${2:-0}" = "1" ]; then printf 'port'; else printf 'drop'; fi ;;
        *)         printf 'drop' ;;
    esac
    return 0
}

# 当前真正在用的本机代理端点，写进 CLI_LIVE_HOST / CLI_LIVE_PORT。
#
# 判据只用**我们自己注入的那个值**（proxy.env 里的 HTTP_PROXY）：它是 EnvProxy
# 此刻认定的端口，而且必须是活的。不在这里重新全端口扫描——救援页已经够慢，
# 而且"我们的值指向一个活端口"就是使用者此刻真正在用的那个（与状态页同源）。
CLI_LIVE_HOST=''
CLI_LIVE_PORT=''
cli_live_proxy_endpoint() {
    CLI_LIVE_HOST=''; CLI_LIVE_PORT=''
    [ -n "${PROXY_ENV:-}" ] || return 1
    [ -f "$PROXY_ENV" ] || return 1
    _clep_line=$(grep -E '^export HTTP_PROXY=' "$PROXY_ENV" 2>/dev/null | head -n 1)
    [ -n "$_clep_line" ] || return 1
    _clep_url="${_clep_line#*export HTTP_PROXY=}"
    _clep_url=$(printf '%s' "$_clep_url" | tr -d "\"'")
    _cli_split_value "$_clep_url" || return 1
    port_alive_bounded "$_csv_host" "$_csv_port" || return 1
    CLI_LIVE_HOST="$_csv_host"; CLI_LIVE_PORT="$_csv_port"
    return 0
}

# 给一条结论配一句人说。$1 Kind $2 工具名 $3 值 $4 Mode $5 有没有活代理端口 $6 文件里有 include
_cli_proxy_reason() {
    _cpr_kind="${1:-}"; _cpr_tool="$2"; _cpr_val="$3"; _cpr_mode="$4"; _cpr_inc="${6:-0}"
    case "$_cpr_kind" in
        "$FINDING_KIND_ALIVE")
            printf '这里写的是本机地址，程序还开着，连得上。' ;;
        "$FINDING_KIND_BLOCKING"|"$FINDING_KIND_SLOWING")
            _cpr_s="这个文件里写着让 $_cpr_tool 走本机的一个代理，但那个程序已经不在了。"
            case "$_cpr_mode" in
                port) _cpr_s="$_cpr_s可以把它改到你现在在用的端口 $CLI_LIVE_PORT。" ;;
                none) _cpr_s="$_cpr_s这种文件本工具不替你改。" ;;
            esac
            printf '%s' "$_cpr_s" ;;
        "$FINDING_KIND_FOREIGN")
            if [ "$_cpr_inc" = "1" ]; then
                printf '这个文件的代理设置可能是从别处读进来的，本工具不知道该改哪一个，所以不动。'
            elif [ -z "$(_url_host "$_cpr_val" 2>/dev/null)" ]; then
                printf '这一项的值认不出来，所以不动它。'
            else
                printf '这个代理不是这台电脑自己的，多半是公司或学校给的，本工具不碰。'
            fi ;;
        *) printf '' ;;
    esac
    return 0
}

# $1 Kind $2 Mode
_cli_proxy_advice() {
    finding_fixable "${1:-}" || { printf '保持原样即可。'; return 0; }
    case "${2:-drop}" in
        port) printf '可以让本工具把它改成你现在在用的端口（会先备份，能还原）。' ;;
        drop) printf '可以让本工具删掉那一行（会先备份，能还原）；删掉之后它会改用系统里的代理设置。' ;;
        none) printf '这种格式本工具不替你改：把那一项删掉，或把端口改成你现在在用的那个。' ;;
        *)    printf '保持原样即可。' ;;
    esac
    return 0
}

# 读全部 CLI 配置文件，输出 Finding 行。
#
# 第 8 列（曾经留空的那一列）现在放 Repairable：1 = 这一条能安全地改 / 0 = 只报告。
# 那一列本来就是为「这一条归谁修」留的，正是这个意思；界面按 finding_repairable
# 的第 3 个参数读它，与 Windows 侧的 Finding.Data.Repairable 同义。
get_cli_proxy_findings() {
    _cpf_live=0
    cli_live_proxy_endpoint && _cpf_live=1
    for _cpf_row in ${CLI_PROXY_TARGETS[@]+"${CLI_PROXY_TARGETS[@]}"}; do
        _insp_field "$_cpf_row" 1; _cpf_id=$_insp_out
        _insp_field "$_cpf_row" 2; _cpf_name=$_insp_out
        _insp_field "$_cpf_row" 7; _cpf_fixmode=$_insp_out
        _cpf_paths=$(cli_proxy_file_paths "$_cpf_row")
        while IFS= read -r _cpf_path; do
            [ -n "$_cpf_path" ] || continue
            [ -f "$_cpf_path" ] || continue
            _cpf_rows=$(read_cli_proxy_file "$_cpf_path" "$_cpf_row")
            case "$_cpf_rows" in
                '!'*)
                    # 读不出来要单独说，不许静默消失。
                    _cpf_why=${_cpf_rows#!}
                    finding_new "cli-proxy.$_cpf_id" "$FINDING_KIND_UNREADABLE" "$_cpf_name" "$_cpf_path" \
                        '' "这个文件没读出来：$_cpf_why" '读不出来不代表没问题，但本工具不会去改它。' ''
                    continue ;;
            esac
            [ -n "$_cpf_rows" ] || continue
            while IFS="$(printf '\t')" read -r _cpf_ln _cpf_lines _cpf_key _cpf_val _cpf_host _cpf_port _cpf_fl _cpf_po _cpf_inc _cpf_raw; do
                [ -n "$_cpf_ln" ] || continue
                _cpf_alive='unknown'
                if [ -n "$_cpf_host" ] && [ -n "$_cpf_port" ]; then
                    if port_alive_bounded "$_cpf_host" "$_cpf_port"; then _cpf_alive='alive'; else _cpf_alive='dead'; fi
                fi
                _cpf_k=$(cli_proxy_verdict "$_cpf_val" "$_cpf_alive" "$_cpf_inc")
                case "$_cpf_k" in "$FINDING_KIND_CLEAN") continue ;; esac
                _cpf_mode=$(cli_proxy_entry_mode "$_cpf_fixmode" "$_cpf_live")
                _cpf_rep=0
                if [ "$_cpf_mode" != "none" ] && finding_fixable "$_cpf_k"; then _cpf_rep=1; fi
                _cpf_reason=$(_cli_proxy_reason "$_cpf_k" "$_cpf_name" "$_cpf_val" "$_cpf_mode" "$_cpf_live" "$_cpf_inc")
                _cpf_advice=$(_cli_proxy_advice "$_cpf_k" "$_cpf_mode")
                finding_new "cli-proxy.$_cpf_id" "$_cpf_k" "$_cpf_name" "$_cpf_path" \
                    "$_cpf_val" "$_cpf_reason" "$_cpf_advice" "$_cpf_rep"
            done <<EOF
$_cpf_rows
EOF
        done <<EOF
$_cpf_paths
EOF
    done
    return 0
}

# 把一行里的旧端点换成新端点。能换就打印新行；换不了返回 1（调用方据此不写文件）。
#
# **只替换 host:port 那一段**：账号密码、协议、后面的路径一个字都不碰。
# 公司代理常写成 http://user:pass@host:port，整行重写会把密码抹掉——那是数据损坏。
_cli_repoint_line() {
    _rl_line="$1"; _rl_oh="$2"; _rl_op="$3"; _rl_nh="$4"; _rl_np="$5"; _rl_po="$6"
    [ -n "$_rl_np" ] || return 1
    [ -n "$_rl_op" ] || return 1
    # **不用 ${var/pat/"rep"}**：macOS 自带 bash 3.2 会把替换串两侧的引号当字面量，
    # 于是 `proxy = http://127.0.0.1:7890` 变成 `proxy = http://"127.0.0.1:9999"`
    # ——配置被改坏，而 bash 5 上一切正常（实测由 CI 的 macOS 作业逮到）。
    # 改成「切前缀 + 拼回去」：${var%%pat} / ${var#*pat} 在 3.2 与 5.x 上语义完全一致。
    if [ "$_rl_po" = "1" ]; then
        # 那一行上只有一个端口数字（Gradle 的 port 行、XML 的 <port> 元素）。
        _rl_pre=${_rl_line%%"$_rl_op"*}
        [ "$_rl_pre" != "$_rl_line" ] || return 1
        printf '%s' "$_rl_pre$_rl_np${_rl_line#*"$_rl_op"}"
        return 0
    fi
    case "$_rl_nh" in
        *:*) _rl_new="[$_rl_nh]:$_rl_np" ;;
        *)   _rl_new="$_rl_nh:$_rl_np" ;;
    esac
    _rl_c1="[$_rl_oh]:$_rl_op"
    _rl_c2="$_rl_oh:$_rl_op"
    for _rl_c in "$_rl_c1" "$_rl_c2"; do
        _rl_pre=${_rl_line%%"$_rl_c"*}
        [ "$_rl_pre" != "$_rl_line" ] || continue
        printf '%s' "$_rl_pre$_rl_new${_rl_line#*"$_rl_c"}"
        return 0
    done
    return 1
}

# 按计划改一个文件。计划每行六列（TAB）：Mode <TAB> Lines <TAB> FixLine <TAB> OldHost <TAB> OldPort <TAB> PortOnly
# Mode=drop 删掉 Lines 里的行；Mode=port 改写 FixLine 那一行。
# 整份重写到同目录临时文件再 mv：就地改写到一半失败，用户就得到半截配置。
# 参数：$1 文件路径  $2 计划  $3 目标主机  $4 目标端口
_cli_apply_plan() {
    _ap_path="$1"; _ap_plan="$2"; _ap_nh="$3"; _ap_np="$4"
    _ap_tab="$(printf '\t')"
    _ap_tmp="$_ap_path.tmp.$$"
    : > "$_ap_tmp" 2>/dev/null || return 1
    _ap_n=0
    while IFS= read -r _ap_line || [ -n "$_ap_line" ]; do
        _ap_n=$((_ap_n + 1))
        _ap_action='keep'; _ap_text=''
        while IFS= read -r _ap_pl; do
            [ -n "$_ap_pl" ] || continue
            _ap_mode=${_ap_pl%%"$_ap_tab"*}; _ap_rest=${_ap_pl#*"$_ap_tab"}
            _ap_lines=${_ap_rest%%"$_ap_tab"*}; _ap_rest=${_ap_rest#*"$_ap_tab"}
            _ap_fl=${_ap_rest%%"$_ap_tab"*}; _ap_rest=${_ap_rest#*"$_ap_tab"}
            _ap_oh=${_ap_rest%%"$_ap_tab"*}; _ap_rest=${_ap_rest#*"$_ap_tab"}
            _ap_op=${_ap_rest%%"$_ap_tab"*}; _ap_po=${_ap_rest#*"$_ap_tab"}
            if [ "$_ap_mode" = "port" ] && [ "$_ap_fl" = "$_ap_n" ]; then
                _ap_text=$(_cli_repoint_line "$_ap_line" "$_ap_oh" "$_ap_op" "$_ap_nh" "$_ap_np" "$_ap_po") || _ap_text=''
                if [ -z "$_ap_text" ]; then _ap_action='fail'; break; fi
                _ap_action='replace'
                continue
            fi
            if [ "$_ap_mode" = "drop" ] && [ -n "$_ap_lines" ]; then
                case ",$_ap_lines," in
                    *",$_ap_n,"*) _ap_action='drop'; break ;;
                esac
            fi
        done <<EOF
$_ap_plan
EOF
        if [ "$_ap_action" = "fail" ]; then
            rm -f "$_ap_tmp" 2>/dev/null
            return 1
        fi
        [ "$_ap_action" = "drop" ] && continue
        if [ "$_ap_action" = "replace" ]; then
            printf '%s\n' "$_ap_text" >> "$_ap_tmp" 2>/dev/null || { rm -f "$_ap_tmp" 2>/dev/null; return 1; }
        else
            printf '%s\n' "$_ap_line" >> "$_ap_tmp" 2>/dev/null || { rm -f "$_ap_tmp" 2>/dev/null; return 1; }
        fi
    done < "$_ap_path"
    mv -f "$_ap_tmp" "$_ap_path" 2>/dev/null || { rm -f "$_ap_tmp" 2>/dev/null; return 1; }
    return 0
}

# 修：删掉判为死的行，或把它们改成当前端口。输出三态结论词：fixed / none / failed / partial / nobackup
#
# **逐行改，不重写整个文件**：配置文件是用户的，里面有他别的东西。
# 改之前把整份原文写进还原点；还原时整份写回去。
repair_cli_proxy_config() {
    _rcpc_any=0
    _rcpc_ok=0
    _rcpc_fail=0
    _rcpc_tab="$(printf '\t')"
    _rcpc_live=0
    cli_live_proxy_endpoint && _rcpc_live=1
    for _rcpc_row in ${CLI_PROXY_TARGETS[@]+"${CLI_PROXY_TARGETS[@]}"}; do
        _insp_field "$_rcpc_row" 1; _rcpc_id=$_insp_out
        _insp_field "$_rcpc_row" 7; _rcpc_fixmode=$_insp_out
        _rcpc_paths=$(cli_proxy_file_paths "$_rcpc_row")
        while IFS= read -r _rcpc_path; do
            [ -n "$_rcpc_path" ] || continue
            [ -f "$_rcpc_path" ] || continue
            _rcpc_rows=$(read_cli_proxy_file "$_rcpc_path" "$_rcpc_row")
            case "$_rcpc_rows" in '!'*) continue ;; esac
            [ -n "$_rcpc_rows" ] || continue
            # 挑出要动的项，排成计划（每行六列）。
            _rcpc_plan=''
            _rcpc_touched=' '
            while IFS="$_rcpc_tab" read -r _rcpc_ln _rcpc_lines _rcpc_key _rcpc_val _rcpc_host _rcpc_port _rcpc_fl _rcpc_po _rcpc_inc _rcpc_raw; do
                [ -n "$_rcpc_ln" ] || continue
                _rcpc_alive='unknown'
                if [ -n "$_rcpc_host" ] && [ -n "$_rcpc_port" ]; then
                    if port_alive_bounded "$_rcpc_host" "$_rcpc_port"; then _rcpc_alive='alive'; else _rcpc_alive='dead'; fi
                fi
                _rcpc_k=$(cli_proxy_verdict "$_rcpc_val" "$_rcpc_alive" "$_rcpc_inc")
                finding_fixable "$_rcpc_k" || continue
                _rcpc_mode=$(cli_proxy_entry_mode "$_rcpc_fixmode" "$_rcpc_live")
                [ "$_rcpc_mode" = "none" ] && continue
                _rcpc_plan="${_rcpc_plan}${_rcpc_mode}${_rcpc_tab}${_rcpc_lines}${_rcpc_tab}${_rcpc_fl}${_rcpc_tab}${_rcpc_host}${_rcpc_tab}${_rcpc_port}${_rcpc_tab}${_rcpc_po}
"
                _rcpc_touched="${_rcpc_touched}${_rcpc_host}|${_rcpc_port} "
            done <<EOF
$_rcpc_rows
EOF
            [ -n "$_rcpc_plan" ] || continue
            _rcpc_any=1
            # 还原点：存整份原文。写不下来就不动手——没有退路的修改不该发生。
            _rcpc_orig=$(cat "$_rcpc_path" 2>/dev/null) || { _rcpc_fail=$((_rcpc_fail + 1)); continue; }
            if ! add_doctor_journal_entry 'cli-proxy' \
                    "inspector=cli-proxy" \
                    "target=$_rcpc_id" \
                    "path=$(_bak_enc "$_rcpc_path")" \
                    "content=$(_bak_enc "$_rcpc_orig")"; then
                printf 'nobackup'
                return 0
            fi
            if ! _cli_apply_plan "$_rcpc_path" "$_rcpc_plan" "$CLI_LIVE_HOST" "$CLI_LIVE_PORT"; then
                _rcpc_fail=$((_rcpc_fail + 1))
                continue
            fi
            # 回读确认：**我们动过的那几项**真的不在了才算修好。
            # 只看"文件里还有没有别的可修项"会误报：同一文件里可能还留着一条
            # 本工具不该动的项（比如没有活端口时的 port-only 项），那不是这次修复的失败。
            _rcpc_after=$(read_cli_proxy_file "$_rcpc_path" "$_rcpc_row")
            _rcpc_left=0
            if [ -n "$_rcpc_after" ]; then
                while IFS="$_rcpc_tab" read -r _rcpc_l2 _rcpc_ls2 _rcpc_k2 _rcpc_v2 _rcpc_h2 _rcpc_p2 _rcpc_f2 _rcpc_o2 _rcpc_i2 _rcpc_r2; do
                    [ -n "$_rcpc_l2" ] || continue
                    case "$_rcpc_touched" in
                        *" ${_rcpc_h2}|${_rcpc_p2} "*) : ;;
                        *) continue ;;
                    esac
                    _rcpc_alive2='unknown'
                    if [ -n "$_rcpc_h2" ] && [ -n "$_rcpc_p2" ]; then
                        if port_alive_bounded "$_rcpc_h2" "$_rcpc_p2"; then _rcpc_alive2='alive'; else _rcpc_alive2='dead'; fi
                    fi
                    _rcpc_k2v=$(cli_proxy_verdict "$_rcpc_v2" "$_rcpc_alive2" "$_rcpc_i2")
                    finding_fixable "$_rcpc_k2v" && _rcpc_left=$((_rcpc_left + 1))
                done <<EOF
$_rcpc_after
EOF
            fi
            if [ "$_rcpc_left" -eq 0 ]; then _rcpc_ok=$((_rcpc_ok + 1)); else _rcpc_fail=$((_rcpc_fail + 1)); fi
        done <<EOF
$_rcpc_paths
EOF
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
# 4b. 只认 SOCKS 的端口（socks 检查器）——只解释，不动手
# ------------------------------------------------------------------------------
# 它回答的问题只有一句：「本机有个代理端口在跑，为什么这个工具说没有？」
# 答案通常是"那个端口只认 SOCKS5，而我们（以及多数终端工具）只认 HTTP 代理"。
#
# 结论词用 alive：端口活着、程序也在，只是它说的协议不是我们用的那一种——
# 与系统代理里"回环活着"是同一档含义（东西在那儿、不归我们碰）。
# **绝不因为发现了 SOCKS 口就把它当代理注入**：ALL_PROXY 指向纯 SOCKS 口会让
# 只认 HTTP 的工具全挂，比"没有代理"更糟。
get_socks_findings() {
    _gsf_rows=$(socks_only_ports)
    [ -n "$_gsf_rows" ] || return 0
    while IFS='|' read -r _gsf_port _gsf_who; do
        [ -n "$_gsf_port" ] || continue
        [ -n "$_gsf_who" ] || _gsf_who='本机的一个程序'
        finding_new "socks.$_gsf_port" "$FINDING_KIND_ALIVE" '只认 SOCKS 的端口' \
            "$_gsf_who 的 $_gsf_port" \
            "socks5://127.0.0.1:$_gsf_port" \
            '这个端口只认 SOCKS5，不认 HTTP 代理——所以本工具用不上它，只认环境变量的工具（git、npm、curl 这些）也走不了它。' \
            '想让它给终端工具用：在客户端的设置里把 HTTP 代理或混合端口打开；或者把它填进那些只认 SOCKS 的程序里。' \
            ''
    done <<EOF
$_gsf_rows
EOF
    return 0
}

# ------------------------------------------------------------------------------
# 5. 网址解析（dns 检查器）—— macOS 侧
# ------------------------------------------------------------------------------
# 与 Windows 侧同一套结论词、同一个口径：DNS 被指到本机（或翻墙软件的虚拟网段），
# 而那里没有任何程序在应答 = 网页打不开，而聊天软件可能还是好的。
# 「回环 + 没人应答」两条客观事实叠加，与系统代理那一层同构。
#
# DIVERGE(Mac): 读法与 Windows 不同，两处，都有原因：
#   1) DNS 是按**网络服务**存的（Wi-Fi、雷雳以太网、公司 VPN 各一份），
#      必须遍历全部服务（复用 sysproxy_list_services），不能只看当前那个：
#      真实案例是「公司 VPN 上残留了本机 DNS、Wi-Fi 上是好的」。
#      macOS 也没有 Windows 那种「所有 WLAN 网络的 DNS」单值形态，所以不存在
#      "两处设置打架"那一条——少一条不是能力缩水，是那边真的没有这件事。
#   2) 判活**不看 TCP 53**：mac 上的 DNS 主要走 UDP，只连 TCP 53 会把"只开了 UDP
#      的本地解析器"误判成死掉，然后告诉用户"那里没有程序在听"——那是假话。
#      改用 lsof 被动看谁在监听 53（TCP 或 UDP 都算），取不到 lsof 再退回 TCP 连接，
#      两条都不成立时**不下结论**（读不出来不等于没问题，也不等于有问题）。
#
# 不给 Fix：改 DNS 得先知道"重置成自动之后路由器会下发什么"，而那个答案在系统里
# 根本读不到。猜错会把用户手设的 223.5.5.5 换成更糟的地址，症状比故障还难查。

# DNS 地址属于哪一类：loopback / fakeip / other。与 Windows 侧 Get-DnsAddressClass
# 同判据（198.18.0.0/15 是翻墙软件的虚拟 IP 池，真实互联网与公司内网不会用它）。
dns_address_class() {
    _dac_a=$(printf '%s' "${1:-}" | tr -d '[]' | tr -d ' ')
    [ -n "$_dac_a" ] || { printf 'other'; return 0; }
    case "$_dac_a" in
        127.*|localhost|::1|0:0:0:0:0:0:0:1) printf 'loopback'; return 0 ;;
        198.18.*|198.19.*) printf 'fakeip'; return 0 ;;
    esac
    printf 'other'
    return 0
}

# 本机有没有程序在听 53 端口。输出 bound / free / unknown。
#
# **被动看**，不去连：UDP 的 DNS 解析器只绑 UDP，TCP 连接必然失败——
# 用 TCP 判活会把它们全判成死掉，然后误导用户去改一个其实正常的设置。
dns53_state() {
    if command -v lsof >/dev/null 2>&1; then
        _d5s_hit=$(lsof -nP -i:53 2>/dev/null | awk 'NR > 1 { if ($0 ~ /\(LISTEN\)/ || $0 ~ /\(UDP\)/) { print "y"; exit } }')
        if [ -n "$_d5s_hit" ]; then printf 'bound'; return 0; fi
        # lsof 跑起来了、什么都没看到：可以确定没人在听。
        printf 'free'
        return 0
    fi
    if port_alive_bounded 127.0.0.1 53; then
        printf 'bound'; return 0
    fi
    printf 'unknown'
    return 0
}

# 读全部网络服务的 DNS。输出 "服务<TAB>地址" 一行一条；读不出来返回 1。
# networksetup 对"没设 DNS"的服务回一句"There aren't any DNS Servers set on X."，
# 那不是错误，是"这一层不存在"。
_dns_read_services() {
    _drs_seen=' '
    _drs_any=0
    _drs_services=$(sysproxy_list_services 2>/dev/null || true)
    [ -n "$_drs_services" ] || return 1
    while IFS= read -r _drs_svc; do
        [ -n "$_drs_svc" ] || continue
        _drs_any=1
        _drs_out=$(networksetup -getdnsservers "$_drs_svc" 2>/dev/null || true)
        # 没设 DNS 的那句人话：认它的开头，别去猜系统语言。
        case "$_drs_out" in
            *"aren't any"*|*"There aren"*|*'没有'*) continue ;;
        esac
        while IFS= read -r _drs_one; do
            _drs_one=$(printf '%s' "$_drs_one" | tr -d ' ')
            [ -n "$_drs_one" ] || continue
            case "$_drs_one" in
                *[!0-9a-fA-F:.]*) continue ;;   # 不是地址（本地化文案、空行）
            esac
            case "$_drs_seen" in *" $_drs_one "*) continue ;; esac
            _drs_seen="$_drs_seen$_drs_one "
            printf '%s\t%s\n' "$_drs_svc" "$_drs_one"
        done <<EOF
$_drs_out
EOF
    done <<EOF
$_drs_services
EOF
    [ "$_drs_any" = "1" ] || return 1
    return 0
}

get_dns_findings() {
    _gd_rows=$(_dns_read_services)
    if [ $? -ne 0 ]; then
        finding_new 'dns.state' "$FINDING_KIND_UNREADABLE" '网址解析' '网络服务的 DNS 设置' \
            '' '这一项没读出来：网络服务列表不可用。' '读不出来不代表没问题，但本工具不会去改它。' ''
        return 0
    fi
    # 没配 DNS 的服务不产结论：那不是问题，是默认（用路由器下发的）。
    [ -n "$_gd_rows" ] || return 0
    _gd_state=$(dns53_state)
    _gd_emitted=0
    while IFS="$(printf '\t')" read -r _gd_svc _gd_addr; do
        [ -n "$_gd_addr" ] || continue
        _gd_cls=$(dns_address_class "$_gd_addr")
        case "$_gd_cls" in loopback|fakeip) : ;; *) continue ;; esac
        if [ "$_gd_state" = "bound" ]; then
            finding_new 'dns.loopback' "$FINDING_KIND_ALIVE" '网址解析' "$_gd_svc 的 DNS 设置" \
                "$_gd_addr" 'DNS 指向本机，本机确实有个程序在处理。' '不需要做什么。' ''
        elif [ "$_gd_state" = "free" ]; then
            _gd_emitted=$((_gd_emitted + 1))
            [ "$_gd_emitted" -le 3 ] || continue
            finding_new 'dns.loopback' "$FINDING_KIND_BLOCKING" '网址解析' "$_gd_svc 的 DNS 设置" \
                "$_gd_addr" \
                "网址解析被指到本机的 $_gd_addr，但那里没有程序在听——网页会打不开，而聊天软件可能还是好的。" \
                '这一项本工具不自动改：改错了会把你的网络换成路由器的设置。到系统设置的网络里，把 DNS 改回「自动」即可。' \
                ''
        fi
        # unknown：两条判活都拿不到结果。**不下结论**——把"没看见"说成"没人听"
        # 会让用户去改一个可能完全正常的设置。
    done <<EOF
$_gd_rows
EOF
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
#
# 「一条记录该进哪一区」抽成 rescue_bucket 一个纯函数。
# 抽出来的理由不是整洁：这段判定原来散在 `case` 里，于是「毛病真实、但这一层
# 没有 Fix」的那一类（DNS 指向本机死端口就是）三个计数一个都进不去——
# 屏幕上第一句是绿字「没发现问题」，紧接着的提醒区却在说网页会打不开。
# 一处判定只能有一份实现，才谈得上被测试钉住。
rescue_bucket() {
    _rb_kind="${1:-}"; _rb_rep="${2:-0}"; _rb_fix="${3:-0}"; _rb_hintid="${4:-0}"; _rb_upstream="${5:-0}"
    case "$_rb_kind" in
        "$FINDING_KIND_BLOCKING")  [ "$_rb_rep" = "1" ] && printf 'blocking' || printf 'unfixable' ;;
        "$FINDING_KIND_SLOWING")   [ "$_rb_rep" = "1" ] && printf 'slowing'  || printf 'unfixable' ;;
        "$FINDING_KIND_ALIVE")     [ "$_rb_upstream" = "1" ] && printf 'alivebroken' || printf 'alive' ;;
        "$FINDING_KIND_FOREIGN")   [ "$_rb_hintid" = "1" ] && printf 'hint' || printf 'foreign' ;;
        "$FINDING_KIND_MANAGED")   printf 'managed' ;;
        # 读不出来、认不出的结论：不参与任何判断，也不显示。
        # 把"没看见"说成"没问题"或"有问题"都是错的方向。
        *)                         printf 'clean' ;;
    esac
    return 0
}

# 这一类记录该不该出现在「只是提醒」那一区。判据集中在上面那个函数里：
#   ① 不归我们碰、但有话要说的（地址冲突那种，Id 后缀 .overlay）；
#   ② 毛病真实存在、但这一层没有 Fix、或这条记录自己声明不可修。
rescue_in_hint() {
    _rih_kind="${1:-}"; _rih_rep="${2:-0}"; _rih_fx="${3:-0}"; _rih_hintid="${4:-0}"
    [ "$_rih_hintid" = "1" ] && return 0
    [ "$_rih_fx" = "1" ] && [ "$_rih_rep" != "1" ] && return 0
    return 1
}

show_rescue_page() {
    clear_screen_safe
    style_out title "======== 网络与代理修复 ========"
    echo ""
    # 第一句就说清它管到哪儿。名字里带「网络」，但用户到这里时心里想的是
    # 「我整个网都不行」——不说清，他会以为这一屏能修所有上网问题。
    style_out dim "  查浏览器、终端工具、网址解析这几处设置是不是指错了地方，"
style_out dim "  顺带看看本机有没有只认 SOCKS 的端口（那种端口本工具用不了）。"
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
    # 毛病真实存在、但本工具不动手的那一类（DNS 指向本机死端口就是）。
    # 与 Windows 侧的 $realButUnfixable 同义：它既不该说成「挡住了网络」
    # （按 y 修不了，承诺了就做不到），也不该说成「没问题」。
    _rs_unfixable=0
    # 「端口活着、但握手说它连不上外面」——只有拿到握手证据时才认这一档。
    # 拿不到握手（quick 档或权限不足）时**不算**，绝不凭猜给用户指方向。
    #
    # 这一档与「指向死端口」是两种病，必须分开说：建议用户去动系统代理
    # 并不会恢复网络（程序还在跑、还占着端口），只会把他能用的那条路径删掉。
    _rs_alivebroken=0
    if [ -n "$_rs_all" ]; then
        while IFS="$(printf '\t')" read -r _rs_id _rs_kind _rs_subj _rs_where _rs_val _rs_reason _rs_advice _rs_fix; do
            [ -n "$_rs_id" ] || continue
            # 这一条能不能修，只问该问的那一处（与「要修的是」那一区同一个判据）。
            _rs_rep=0
            finding_repairable "$_rs_kind" "$_rs_id" "$_rs_fix" && _rs_rep=1
            _rs_fx=0
            finding_fixable "$_rs_kind" && _rs_fx=1
            # 这一档的判据由 get_sysproxy_findings 在产 Finding 时定（看握手结果），
            # 这里不再从 Reason 里反推中文。用 Id 后缀认那一档：
            # 文案会改，判据不该跟着改——改一次措辞就静默少报一档，不报错也不失败。
            _rs_up=0
            finding_is_upstream_fail "$_rs_id" && _rs_up=1
            # 判**Id**，不判中文文案：原来这里匹配过 Reason 里的「不会生效」，
            # 改一次措辞就静默换区，不报错也不失败。
            _rs_hid=0
            finding_is_hint "$_rs_id" && _rs_hid=1
            case "$(rescue_bucket "$_rs_kind" "$_rs_rep" "$_rs_fx" "$_rs_hid" "$_rs_up")" in
                blocking)    _rs_blocking=$((_rs_blocking + 1)) ;;
                slowing)     _rs_slowing=$((_rs_slowing + 1)) ;;
                unfixable)   _rs_unfixable=$((_rs_unfixable + 1)) ;;
                alivebroken) _rs_alivebroken=$((_rs_alivebroken + 1)) ;;
                alive)       : ;;
                hint)        _rs_hint=$((_rs_hint + 1)) ;;
                foreign)     _rs_foreign=$((_rs_foreign + 1)) ;;
                managed)     _rs_managed=$((_rs_managed + 1)) ;;
            esac
            [ "$_rs_rep" = "1" ] && _rs_fixable=$((_rs_fixable + 1))
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
        if [ "$_rs_unfixable" -gt 0 ]; then
            style_out warn "  查完了：发现 $_rs_unfixable 处问题，但本工具不自动改（见下面的提醒）。"
        elif [ "$_rs_hint" -gt 0 ]; then
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
            finding_repairable "$_rs_kind" "$_rs_id" "$_rs_fix" || continue
            style_out text "    [$_rs_subj]  ${_rs_val:-（读不出地址）}"
            [ -n "$_rs_reason" ] && style_out dim "      $_rs_reason"
            # Advice 是「使用者能做什么」。写了就得显示。
            [ -n "$_rs_advice" ] && style_out dim "      $_rs_advice"
        done <<EOF
$_rs_all
EOF
    fi

    # ---- 只是提醒的那些（不归我碰，但用户该知道） ----
    if [ "$_rs_hint" -gt 0 ] || [ "$_rs_unfixable" -gt 0 ]; then
        echo ""
        style_out dim "  发现的网络状况（只是提醒，本工具不改）："
        while IFS="$(printf '\t')" read -r _rs_id _rs_kind _rs_subj _rs_where _rs_val _rs_reason _rs_advice _rs_fix; do
            [ -n "$_rs_id" ] || continue
            _rs_rep=0
            finding_repairable "$_rs_kind" "$_rs_id" "$_rs_fix" && _rs_rep=1
            _rs_fx=0
            finding_fixable "$_rs_kind" && _rs_fx=1
            _rs_hid=0
            finding_is_hint "$_rs_id" && _rs_hid=1
            # 与上面那个计数用**同一个判据**：两处各写一套条件，收进来与列出来就会对不上。
            rescue_in_hint "$_rs_kind" "$_rs_rep" "$_rs_fx" "$_rs_hid" || continue
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
                    # 「只是提醒」的那种上面已经单独印过，这里不再重复数。判 Id，不判文案。
                    finding_is_hint "$_rs_id" || style_out dim "    [$_rs_subj]  ${_rs_val:-（地址没读到）}" ;;
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
        # **第 8 列（Repairable）必须一起判**：只看 Kind 会把「同一层里本工具不该动的那一条」
        # （没有活代理时的 port-only、结构删不得的 xml 块）也算进来，
        # 于是这一层的修复函数被叫起来、却一条都改不动，屏幕上落进
        # 「查的时候还在，动手的时候已经没了」——把判据错误赖给用户。
        _rs_mine=$(printf '%s\n' "$_rs_all" | awk -F"\t" -v pre="$_rs_iid." '
            index($1, pre) == 1 && ($2 == "residue-blocking" || $2 == "residue-slowing") && $8 != "0" { c++ }
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
