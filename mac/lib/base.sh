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

# 变量事实源（写/核/收/判四处共用，口径不再分家）：代理变量 6 个（大小写双写）
# + NO_PROXY 双写 + 哨兵 1 个，归属一律按"本机地址才是我们写下的"判定。
OWNED_HTTP_PREFIX="http://127.0.0.1:"

# NO_PROXY 只增不减：已存在的条目原样保留，缺失的默认条目补上。
# 环境变量是共享资源——用户自己加的例外（公司内网等）与别的工具写下的例外都必须留着，
# 本工具只负责"本机地址一定直连"这一件事。
# 取值用 sed 而非 tr -d ' '：条目里可能有空格，整体删空格会改掉别人写的值。
merge_no_proxy() {
    _existing="$1"; _default="$2"
    _out="$_default"
    _lower=$(printf '%s' "$_default" | tr 'A-Z' 'a-z')
    _old=$IFS; IFS=','
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

# 这个值是不是本工具写下的：只有 127.0.0.1 本机地址才算我们的，
# 用户或公司工具写的其他地址一律不动。
is_owned_proxy_value() {
    case "$1" in "$OWNED_HTTP_PREFIX"*) return 0;; *) return 1;; esac
}

# 成员判断：$1 在空格分隔表 $2 里则返回 0
_in_list() {
    case " $2 " in *" $1 "*) return 0;; *) return 1;; esac
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
