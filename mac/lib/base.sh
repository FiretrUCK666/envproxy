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

# 帮助每一屏的行数上限。超过这个数，终端会把底部的「怎么退出」切掉——
# 用户会以为帮助卡死，其实只是没画出来。与 Windows 侧 $HelpMaxLines 必须一致。
HELP_MAX_LINES=30

# 变量事实源（写/核/收/判四处共用，口径不再分家）：代理变量 6 个（大小写双写）
# + NO_PROXY 双写 + 哨兵 1 个，归属一律按"本机地址才是我们写下的"判定。
OWNED_HTTP_PREFIX="http://127.0.0.1:"

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
    case "$1" in "$OWNED_HTTP_PREFIX"*) ;; *) return 1;; esac
    # 快照里存的是单引号转义后的值（见 shell_escape_sq），所以两种写法都要认。
    # 逐变量比对，而不是"整份文件里 grep 一下"：后者会把 NO_PROXY 里恰好含同一串
    # 文本的情况也算进来，而且依赖分隔符形式，格式一改保护就静默失效。
    if [ -f "$PREV_ENV" ]; then
        _iov_want=$(printf '%s' "$1")
        for _iov_v in $PROXY_ADDR_VAR_NAMES; do
            _iov_have=$(_snapshot_value_of "$_iov_v")
            [ -n "$_iov_have" ] && [ "$_iov_have" = "$_iov_want" ] && return 1
        done
    fi
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
        printf '无法识别的参数: %s' "$USAGE_EXTRA"
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
            if [ "${USAGE_COMMAND:-}" != "update" ]; then
                printf -- '--yes 只在检查更新时才有意义：它表示跳过确认。请用 update --yes。'
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
