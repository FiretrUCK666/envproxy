# ------------------------------------------------------------------------------
#  update.sh — 更新层：版本比较、下载校验、用户确认流程、安装来源分流
#  状态显示只读；动手只走更新入口。
# ------------------------------------------------------------------------------

# 更新源：分平台安装包资产（见第 9 节），按源表逐源尝试。
# 开发副本（安装根有 .git）的只读版本检查跟自己的 git remote 走，
# 覆盖文件这条路上 git 副本一律不参与。
UPDATE_REPO_DEFAULT="FiretrUCK666/envproxy"

# 更新源表：每行一条
#   "<标识来源> <显示名> <优先路径> <Api> <Web> <下载前缀> <API 前缀>"，有序，逐个尝试，
# 第一个能回答"最新版是什么"的胜出。
# @@ 接仓库标识（用参数展开做纯字符串替换，不经 sed——正则会把地址里的符号当元字符）。
# 加一个源 = 加一行，不动任何判断逻辑。目前只有官方源一条。顺序即优先级。
#
# 两段地址的分工：
#   问版本：Api 读 JSON、Web 读 302 的 Location。Api 优先——它语义明确，但匿名配额只有
#           60 次/小时/IP；Web 不吃配额，可网页路径在受限网络里会整段超时
#           （实测同一条 URL：curl 拿到 302、.NET 超时）。所以 Api 优先、Web 兜底。
#   取安装包：先走 API 的资产端点（回 302 到 release-assets 的 CDN），再退回直连下载。
#           GitHub 网页主机在受限网络里时通时不通（同一台机器实测过连续 5 次下载超时），
#           而 api.github.com 稳定可达（实测 200 / 0.2s），所以 API 在前、直连兜底。


UPDATE_SOURCE_TABLE='official GitHub Api https://api.github.com/repos/@@/releases/latest https://github.com/@@/releases/latest https://github.com/@@ https://api.github.com/repos/@@'

# ------------------------------------------------------------------------------
# 9. 在线更新（检查更新 + 一键升级；状态显示只读，动手只在这里）
# ------------------------------------------------------------------------------
# 更新源：分平台安装包资产（EnvProxy-mac.tar.gz；Windows 侧取 EnvProxy-win.zip），按上面的源表逐源尝试。
#   只同步本平台目录与共享文件，另一平台目录不动（分平台包里本来就没有它）。
#   安装包内容由仓库 .gitattributes 的 export-ignore 声明，发布流水线用 git archive 产出。
#   不接公共加速站：那些站点靠站长自掏腰包维持、生命周期以月计，而且包从它手里过一遍
#   就等于多信一个陌生人。
#   判据是环境事实，不看是谁在用：
#     安装根有 .git = 开发副本 → 更新只读，不改动任何文件，提示走 git pull；
#     有 .github、无 .git = 源码包 → 先确认用途（当安装包用就更新并清理源码文件，
#       自己改代码就一个字节都不动），拿不到输入时按后者；
#     两个都没有 = 安装副本 → 下载安装包、校验、覆盖安装区。

get_project_root() {
    dirname "$SCRIPT_DIR"
}

is_dev_copy() {
    [ -e "$(get_project_root)/.git" ]
}

# 源码包：有 .github、无 .git（多见于删掉了 .git 的克隆，或很早以前下载的旧包；
# 现在网页上下载的包已不再含这些文件，见 README 故障排查）。
# 安装包里永远没有 .github（打包配置排除），用户自己也不会建这个目录，认它零误伤。
# 传参则判指定目录（自检用），不传判安装根。
is_source_copy() {
    _sr="${1:-$(get_project_root)}"
    [ ! -e "$_sr/.git" ] && [ -d "$_sr/.github" ]
}

# 源码包转安装包：删掉源码专用文件（清单从 .gitattributes 的排除表实时读，不是写死的）。
# 调用方保证安装根有效且用户已确认；删完下次更新不再问。
clean_source_files() {
    _croot="$1"
    [ -f "$_croot/.gitattributes" ] || return 0
    _clist=$(grep -E '^/[^ ]+[ ]+export-ignore' "$_croot/.gitattributes" 2>/dev/null | sed -E 's#^/([^ ]+)[ ]+export-ignore.*#\1#' || true)
    [ -n "$_clist" ] || return 0
    for _cent in $_clist; do
        # 只允许安装根内的相对路径：绝对路径、任何一段 .. 一律跳过。
        # 清单来自随包的 .gitattributes，但"随包"不等于"可信"——一个 ../Documents 就能
        # 删掉安装根同级的目录，而这条路只有"点检查更新 + 源码包"才走得到。
        case "/$_cent/" in
            //*|*/../*) continue ;;
        esac
        case "$_cent" in
            */) [ -e "$_croot/$_cent" ] && rm -rf "$_croot/$_cent" 2>/dev/null || true ;;
            *) [ -e "$_croot/$_cent" ] && rm -f "$_croot/$_cent" 2>/dev/null || true ;;
        esac
    done
    return 0
}

get_local_version() {
    _vf="$(get_project_root)/VERSION"
    [ -f "$_vf" ] || return 1
    tr -d ' \t\r\n' < "$_vf" 2>/dev/null
}

# 开发副本跟自己的 git remote 走（fork 后看得到自己仓库的 Release）；安装副本用内置默认。
get_update_repo() {
    if is_dev_copy && command -v git >/dev/null 2>&1; then
        _u=$(git -C "$(get_project_root)" config --get remote.origin.url 2>/dev/null || true)
        case "$_u" in
            *github.com*)
                _r=$(printf '%s' "$_u" | sed -E 's#.*github\.com[:/]([^/]+)/([^/]+)#\1/\2#; s#\.git$##')
                if [ -n "$_r" ]; then printf '%s' "$_r"; return 0; fi
                ;;
        esac
    fi
    printf '%s' "$UPDATE_REPO_DEFAULT"
}

# 这一源的仓库标识从哪里取：环境事实——开发副本跟自己的 git remote 走
# （fork 后看得见自己仓库的 Release），安装副本用内置默认。
# 参数保留是为了源表的标识字段：将来加源时按它分派，不必改调用方。
update_source_id() {
    printf '%s' "$(get_update_repo)"
}

# 取文本：先按当前环境（含代理变量）取，失败再直连重试一次。
# DIVERGE(Mac): Win 侧走系统代理恒为直连，需显式经 127.0.0.1 重试；
# Mac 侧 curl 继承环境变量代理，这里反向补一次直连回退，两方向都覆盖。
fetch_update_text() {
    _out=$(curl -fsSL --max-time 8 -A "EnvProxyUpdate" "$1" 2>/dev/null) \
        && { printf '%s' "$_out"; return 0; }
    env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy \
        curl -fsSL --max-time 8 --noproxy '*' -A "EnvProxyUpdate" "$1" 2>/dev/null
}

# 从 releases/tags/<标签> 的 JSON 里找出某个文件名对应的资产 id（纯函数，自检可测）。
# 找不到、或 JSON 形状不对，一律输出空——调用方据此退回直连下载，不当错误处理。
# 做法：先按 "},{" 把 assets 里的对象切成一段一段，在**同一段**里同时找文件名与编号。
#   编号优先从这段的 url 取（…/releases/assets/<id>）——url 属于这条资产自己，与字段
#   先后无关；取不到才退回这段里的第一个 "id"。这样既不依赖 JSON 是单行还是带缩进
#   （GitHub 按 Accept 不同两种都会回），也不依赖 id 与 name 谁先谁后（那只是当前实现的
#   巧合，顺序一换旧写法就会返回上一条资产的 id）。
# 不用 jq：macOS 自带环境没有它，零依赖是安装口号。
get_asset_id_from_json() {
    printf '%s' "$1" | tr '\n' ' ' | awk -v want="$2" '
    BEGIN {
        w = want
        gsub(/[\\.^$*+?()\[\]{}|]/, "\\\\&", w)
        pat = "\"name\"[ \t]*:[ \t]*\"" w "\""
    }
    {
        s = $0
        # 对象之间可能是 "},{"，也可能是 "}," 加换行加缩进（服务端带缩进时就是后者），
        # 所以分隔符要容忍空白，否则整段数组被当成一个对象、取到第一条资产的编号。
        gsub(/\},[ \t]*\{/, "}\n{", s)
        n = split(s, obj, "\n")
        for (i = 1; i <= n; i++) {
            if (obj[i] !~ pat) continue
            if (match(obj[i], /releases\/assets\/[0-9]+/)) {
                m = substr(obj[i], RSTART, RLENGTH); gsub(/[^0-9]/, "", m)
                if (m != "") { print m; exit }
            }
            if (match(obj[i], /"id"[ \t]*:[ \t]*[0-9]+/)) {
                m = substr(obj[i], RSTART, RLENGTH); gsub(/[^0-9]/, "", m)
                if (m != "") { print m; exit }
            }
        }
    }'
}

# 下载成功不等于拿到的是安装包：请求头被网络中间层丢掉时，资产端点会回 200 + JSON。
# 判前两个字节是不是 gzip 头（1f 8b）；不是就丢弃这份内容，让调用方继续试直连那条路。
_is_gzip() {
    [ -s "$1" ] || return 1
    [ "$(od -An -tx1 -N2 "$1" 2>/dev/null | tr -d ' \n')" = "1f8b" ]
}

# 问这一源的 API 要"某个标签下某个文件的资产 id"。拿不到输出空，绝不报错退出。
get_update_asset_id() {
    _ga_json=$(fetch_update_text "$1/releases/tags/$2" || true)
    [ -n "$_ga_json" ] || return 0
    get_asset_id_from_json "$_ga_json" "$3"
}

# 取一个文件到本地：$1=目标文件 $2=额外请求头（空则不带）$3=URL
# 拆成两个小函数是为了让"带不带请求头"只在一个地方分支，调用方（含直连兜底）不必各写两遍。
_fetch_to_file() {
    if [ -n "$2" ]; then
        curl -fsSL --max-time 60 -A "EnvProxyUpdate" -H "$2" -o "$1" -w '%{http_code}' "$3" 2>/dev/null
    else
        curl -fsSL --max-time 60 -A "EnvProxyUpdate" -o "$1" -w '%{http_code}' "$3" 2>/dev/null
    fi
}

_fetch_to_file_direct() {
    if [ -n "$2" ]; then
        env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy \
            curl -fsSL --max-time 60 --noproxy '*' -A "EnvProxyUpdate" -H "$2" -o "$1" -w '%{http_code}' "$3" 2>/dev/null
    else
        env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy \
            curl -fsSL --max-time 60 --noproxy '*' -A "EnvProxyUpdate" -o "$1" -w '%{http_code}' "$3" 2>/dev/null
    fi
}

# 下载文件：$1=URL $2=目标文件 $3=额外请求头（可空，API 资产端点要 Accept: application/octet-stream）
# 入口开着 set -u，所以 $3 必须带默认值：两参调用（直连兜底那条）不许因为少一个参数就整条失效。
# 返回 0 = 成功，22 = 这个地址确实没有文件（HTTP 404/410，不必再试代理），其余 = 失败。
# 判据必须是**真实状态码**，不能拿 curl -f 的退出码当语义：-f 对任何 >=400 一律返回 22
# （实测 400/401/403/404/410/429/500/502/503 全是 22），把 22 当"没提供安装包"会把限流和
# 服务端故障一起误报成缺包，还会掐掉本该有的直连重试。Windows 侧判的就是 404/410。
fetch_update_file() {
    _fuf_hdr="${3:-}"
    _code=$(_fetch_to_file "$2" "$_fuf_hdr" "$1")
    _rc=$?
    [ "$_rc" -eq 0 ] && return 0
    case "$_code" in 404|410) return 22 ;; esac
    # 非"文件不存在"的失败：直连再试一次（代理变量在、代理却不干活，是墙内常见形态）。
    _code2=$(_fetch_to_file_direct "$2" "$_fuf_hdr" "$1")
    _rc2=$?
    [ "$_rc2" -eq 0 ] && return 0
    case "$_code2" in 404|410) return 22 ;; esac
    return 1
}

# 查最新 Release：成功时置 REMOTE_VERSION / REMOTE_TAG / REMOTE_SOURCE_BASE / REMOTE_SOURCE_NAME
# 并返回 0，所有源都问不到才返回 1（只读，不写文件）。
# 逐个源尝试，第一个答出来的胜出。
# 顺带记下胜出源的下载前缀——版本与安装包必须来自同一个源，
# 否则会出现"拿 A 源的版本号去下 B 源的包"。
REMOTE_VERSION=""
REMOTE_TAG=""
REMOTE_SOURCE_BASE=""
REMOTE_SOURCE_NAME=""

# 本机这次实际可用的源（有序）：每行一条
# "<显示名>|<优先路径>|<Api>|<Web>|<下载前缀>|<API 前缀>"，仓库标识已代入。
# 没有仓库标识的源直接跳过（目前只有官方源一条）。
get_update_sources() {
    while read -r _sid _sname _spref _sapi _sweb _sbase _sapirepo; do
        [ -n "$_sid" ] || continue
        _gid=$(update_source_id "$_sid")
        [ -n "$_gid" ] || continue
        printf '%s|%s|%s|%s|%s|%s\n' "$_sname" "$_spref" "${_sapi//@@/$_gid}" "${_sweb//@@/$_gid}" "${_sbase//@@/$_gid}" "${_sapirepo//@@/$_gid}"
    done <<_ENVPROXY_SOURCES_
$UPDATE_SOURCE_TABLE
_ENVPROXY_SOURCES_
}

# 从重定向目标里取标签；形状不对就返回空（调用方据此换另一条路径）。
# 必须校验它确实落在 /releases/tag/<标签> 上，不能只取最后一段：仓库改名时对方会先
# 302 到改名后的仓库路径（实测 dromara/hutool），那时最后一段是字面量 "latest"，
# naive 取尾段会把垃圾当成版本号去拼下载地址。
# 标签可能含括号等字符且不做百分号编码（实测 v2026.09(jdk25)），所以整段取、不解码。
get_tag_from_location() {
    [ -n "$1" ] || return 0
    printf '%s' "$1" | sed -n 's#.*/releases/tag/\([^/?#]*\)$#\1#p'
}

# 网页路径：读 302 的 Location 取标签。带直连兜底（与 API 路径同一个模式）。
get_tag_from_web() {
    _wloc=$(curl -sI -o /dev/null -w '%{redirect_url}' --max-time 8 -A "EnvProxyUpdate" "$1" 2>/dev/null || true)
    [ -n "$_wloc" ] || _wloc=$(env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy \
        curl -sI -o /dev/null -w '%{redirect_url}' --max-time 8 --noproxy '*' -A "EnvProxyUpdate" "$1" 2>/dev/null || true)
    get_tag_from_location "$_wloc"
}

# API 路径：读 JSON 的 tag_name。
get_tag_from_api() {
    _ajson=$(fetch_update_text "$1" || true)
    [ -n "$_ajson" ] || return 0
    printf '%s' "$_ajson" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/'
}

# 按这一源声明的优先顺序问版本：先 Preferred 那条，不行再试另一条。
get_tag_from_source() {
    if [ "$2" = "Web" ]; then _k1=Web; _k2=Api; else _k1=Api; _k2=Web; fi
    for _kind in $_k1 $_k2; do
        if [ "$_kind" = "Web" ]; then
            [ -n "$4" ] || continue
            _tag=$(get_tag_from_web "$4")
        else
            [ -n "$3" ] || continue
            _tag=$(get_tag_from_api "$3")
        fi
        if [ -n "$_tag" ]; then printf '%s' "$_tag"; return 0; fi
    done
    return 0
}

# 从**一个**源查最新 Release：这一源自己的两条路径都试过还不行，才算它答不上来。
# 拆出这一层是为了让更新入口能按源做完整尝试（问版本 + 取包），而不只是问版本。
get_remote_version_from() {
    _rsname="$1"; _rspref="$2"; _rsapi="$3"; _rsweb="$4"; _rsbase="$5"
    _rstag=$(get_tag_from_source "$_rsname" "$_rspref" "$_rsapi" "$_rsweb")
    [ -n "$_rstag" ] || return 1
    _rsver=$(printf '%s' "$_rstag" | sed -E 's/^v//')
    [ -n "$_rsver" ] || return 1
    REMOTE_TAG="$_rstag"
    REMOTE_VERSION="$_rsver"
    REMOTE_SOURCE_BASE="$_rsbase"
    REMOTE_SOURCE_NAME="$_rsname"
    return 0
}

# 查最新 Release（状态显示与更新入口共用）：第一个答出来的源胜出（只读，不写文件）。
get_remote_version() {
    # 源表用 here-doc 喂给 while，不用管道：管道会把 while 丢进子 shell，
    # 里面赋的 REMOTE_* 出了循环就没了——而那正是调用方要读的东西。
    while IFS='|' read -r _sname _spref _sapi _sweb _sbase _sapirepo; do
        [ -n "$_sname" ] || continue
        if get_remote_version_from "$_sname" "$_spref" "$_sapi" "$_sweb" "$_sbase"; then
            return 0
        fi
    done <<_ENVPROXY_SRCS_
$(get_update_sources)
_ENVPROXY_SRCS_
    return 1
}

update_envproxy() {
    _yes="$1"
    echo "======== EnvProxy 检查更新 ========"
    _local=$(get_local_version || true)
    if [ -n "$_local" ]; then echo "本地版本 : v$_local"; else echo "本地版本 : 未知"; fi
    echo "正在检查最新版本（最多等十几秒）..."
    if ! get_remote_version; then
        echo "最新版本 : 检查失败（所有更新源都不可达）"
        echo "请稍后重试；把翻墙软件开关一次再试也是常见解法。"
        return 0
    fi
    echo "最新版本 : $REMOTE_TAG（来源：$REMOTE_SOURCE_NAME）"
    _clean_source=0
    if is_dev_copy; then
        echo "这是开发副本（安装根有 .git）：更新入口不改动任何文件。"
        echo "拉新代码请在仓库里执行：git pull"
        return 0
    fi
    if is_source_copy; then
        echo "这里是源码包（有 .github、无 .git），不是安装包。"
        printf "更新会覆盖程序文件：[U] 当安装包用并清理源码文件 / [D] 自己改代码什么都不动（默认）: "
        _ans=""
        if read -r _ans < /dev/tty 2>/dev/null; then :; else _ans=""; fi
        case "$_ans" in
            [Uu]*)
                echo "继续更新，完成后源码专用文件会被清理（下次不再问）。"
                _clean_source=1
                ;;
            *)
                echo "已取消：一个字节都没动。纯使用请去 Releases 下载安装包。"
                return 0
                ;;
        esac
    fi
    if [ -n "$_local" ]; then
        _newer=$(compare_versions "$_local" "$REMOTE_VERSION" || true)
        if [ "$_newer" -gt 0 ] 2>/dev/null; then
            echo "本地版本比最新发布版新，不自动更新（需要确认就打开 Releases 页面）。"
            return 0
        fi
        _older=$(compare_versions "$REMOTE_VERSION" "$_local" || true)
        if [ "$_older" -le 0 ] 2>/dev/null; then
            echo "已是最新，无需更新。"
            return 0
        fi
    fi
    # 目的地校验 + 版本闸门：脚本一旦不在 <根>/mac/ 布局里，推导出的"安装根"就是错的，
    # 后面的删除循环会删用户自己的文件；VERSION 读不到时任何"比较"都是瞎猜。
    # 两项任一不过就拒绝并指明路，不下载、不覆盖、不删任何东西。
    _uroot="$(get_project_root)"
    if [ ! -f "$_uroot/mac/envproxy.sh" ] || [ ! -f "$_uroot/VERSION" ]; then
        echo "这里不是 EnvProxy 安装目录（缺少 mac/envproxy.sh 或 VERSION），未做任何改动。"
        echo "请从安装包的 mac/ 目录里运行，或手动下载安装包覆盖。"
        return 0
    fi
    if [ -z "$_local" ]; then
        echo "本地版本未知（安装根缺少 VERSION 文件），不敢自动更新，未做任何改动。"
        echo "请到 Releases 页面手动下载安装包覆盖一次，或打开菜单选"安装 / 修复"。"
        return 0
    fi
    # 防呆：点的是备份文件夹时警告（正式路径以 path.conf 记录为准）
    _reg=""
    [ -f "$PATH_CONF" ] && _reg=$(head -n 1 "$PATH_CONF" 2>/dev/null | tr -d '\r\n' || true)
    # 大小写不敏感地比：macOS 默认卷不区分大小写，只差大小写的路径是同一个文件夹，
    # 那时不该弹"你点的是备份副本"的警告（Windows 侧同样是两边都转小写后比）。
    _reg_lc=$(printf '%s' "$_reg" | tr 'A-Z' 'a-z')
    _self_lc=$(printf '%s' "$SCRIPT_PATH" | tr 'A-Z' 'a-z')
    if [ -n "$_reg" ] && [ "$_reg_lc" != "$_self_lc" ]; then
        echo "注意：你现在点的是 [$SCRIPT_PATH]，"
        echo "但正式安装在 [$_reg]。"
        echo "继续会更新【当前这个文件夹】并把它切换为正式安装。"
    fi
    # 取包：逐源尝试"问版本 → 下载 → 解压 → 校验"，第一个拿到合格包的源胜出。
    # 只回退"问版本"是不够的——官方源的 API 答得出、它的资产主机却下不动，是现实存在的形态
    # （同一台机器实测 api.github.com 通、github.com 整段超时），而那一刻另一个源本来能救回来。
    # 换源连同版本一起换：用那一源自己的标签下它自己的包，保持"版本与包同源"。
    # DIVERGE(Mac): Mac 取 tar.gz + tar；Win 取 zip + Expand-Archive（见 envproxy.ps1）。
    # 临时路径必须不可预测：固定名字 + 先删后建，攻击者可预置同名 symlink 把下载与解压引向别处。
    _rnd=$(mktemp /tmp/envproxy_update.XXXXXX 2>/dev/null) || { echo "更新失败：临时文件建不起，未做任何改动。"; return 0; }
    rm -f "$_rnd" 2>/dev/null || true
    _tgz=""
    _exdir=""
    _pkg_missing=0
    _pkg_fail=0
    # 已经问到的胜出源（上面那轮问版本的结果）：这条源在下面不必再问一次，
    # 省下的一次 API 配额正好留给最需要的取资产那一步。
    _pre_name="$REMOTE_SOURCE_NAME"
    _pre_tag="$REMOTE_TAG"
    _pre_ver="$REMOTE_VERSION"
    _pre_base="$REMOTE_SOURCE_BASE"
    echo "正在下载安装包..."
    while IFS='|' read -r _sname _spref _sapi _sweb _sbase _sapirepo; do
        [ -n "$_sname" ] || continue
        if [ "$_sname" = "$_pre_name" ]; then
            REMOTE_TAG="$_pre_tag"; REMOTE_VERSION="$_pre_ver"
            REMOTE_SOURCE_BASE="$_pre_base"; REMOTE_SOURCE_NAME="$_pre_name"
        else
            get_remote_version_from "$_sname" "$_spref" "$_sapi" "$_sweb" "$_sbase" || continue
        fi
        # 只接受比本地新的版本：换源不能把用户带到更旧的版本上。
        _cmp=$(compare_versions "$REMOTE_VERSION" "$_local" 2>/dev/null || echo 0)
        [ "$_cmp" -gt 0 ] 2>/dev/null || continue
        _sl=$(printf '%s' "$_sname" | tr -c 'A-Za-z0-9' '_')
        _try_tgz="${_rnd}.${_sl}.tar.gz"
        _try_dir="${_rnd}.${_sl}-src"
        rm -f "$_try_tgz" 2>/dev/null || true
        rm -rf "$_try_dir" 2>/dev/null || true
        mkdir -p "$_try_dir" 2>/dev/null || continue
        # 下载顺序：API 资产端点优先，直连下载兜底（见源表上方的说明）。
        # 两条路都可能"这一版没提供这个文件"，任一条拿到就算成功；都不成才换源。
        # 22 = 404/410（确实没这个文件），其余 = 网络或服务故障——两者分开记，
        # 最后的提示才能和 Windows 侧一样诚实地分开说（见下面的 _pkg_missing / _pkg_fail）。
        _got=1
        _miss=0
        _fail=0
        _asset_id=$(get_update_asset_id "$_sapirepo" "$REMOTE_TAG" "EnvProxy-mac.tar.gz" || true)
        if [ -n "$_asset_id" ]; then
            fetch_update_file "$_sapirepo/releases/assets/$_asset_id" "$_try_tgz" "Accept: application/octet-stream"
            _rc=$?
            if [ "$_rc" -eq 0 ]; then
                # 200 不等于拿到包：请求头被中间层丢掉时这里回的是 JSON。不是 gzip 就丢弃，
                # 让下面的直连兜底接手——否则会把"网络问题"报成"发布缺包/校验失败"。
                if _is_gzip "$_try_tgz"; then _got=0; else rm -f "$_try_tgz" 2>/dev/null || true; _fail=1; fi
            elif [ "$_rc" -eq 22 ]; then _miss=1; else _fail=1; fi
        fi
        if [ "$_got" -ne 0 ]; then
            fetch_update_file "$_sbase/releases/download/$REMOTE_TAG/EnvProxy-mac.tar.gz" "$_try_tgz" ""
            _rc=$?
            if [ "$_rc" -eq 0 ]; then
                if _is_gzip "$_try_tgz"; then _got=0; else rm -f "$_try_tgz" 2>/dev/null || true; _fail=1; fi
            elif [ "$_rc" -eq 22 ]; then _miss=1; else _fail=1; fi
        fi
        if [ "$_got" -ne 0 ]; then
            # 记下这次是怎么失败的：所有源都试完仍没有包时，用它们决定说"缺包"还是"下载失败"。
            if [ "$_fail" -eq 1 ]; then _pkg_fail=1; elif [ "$_miss" -eq 1 ]; then _pkg_missing=1; else _pkg_fail=1; fi
            rm -f "$_try_tgz" 2>/dev/null || true
            rm -rf "$_try_dir" 2>/dev/null || true
            continue
        fi
        if ! tar -xzf "$_try_tgz" -C "$_try_dir" 2>/dev/null; then
            _pkg_fail=1
            rm -f "$_try_tgz" 2>/dev/null || true
            rm -rf "$_try_dir" 2>/dev/null || true
            continue
        fi
        if ! verify_package "$_try_dir" "$REMOTE_VERSION" "mac"; then
            _pkg_fail=1
            rm -f "$_try_tgz" 2>/dev/null || true
            rm -rf "$_try_dir" 2>/dev/null || true
            continue
        fi
        _tgz="$_try_tgz"
        _exdir="$_try_dir"
        break
    done <<_ENVPROXY_PKG_
$(get_update_sources)
_ENVPROXY_PKG_
    if [ -z "$_exdir" ]; then
        if [ "$_pkg_fail" -eq 0 ] && [ "$_pkg_missing" -eq 1 ]; then
            echo "这个版本没有提供安装包：${REMOTE_SOURCE_NAME:-更新源} 上没有挂 EnvProxy-mac.tar.gz。"
            echo "请到 Releases 页面手动下载 EnvProxy-mac.tar.gz 覆盖一次。"
        else
            echo "更新失败：没能取到可用的安装包（下载失败，或校验没通过），未做任何改动。"
            echo "请稍后重试，也可以到 Releases 页面手动下载安装包覆盖一次。"
        fi
        return 0
    fi
    echo "最新版本 : $REMOTE_TAG（来源：$REMOTE_SOURCE_NAME）"
    # 先把这一版改了什么给用户看，再问要不要装
    show_release_notes "$_exdir" "$REMOTE_TAG"
    if [ "$_yes" != "1" ]; then
        printf "已下载并校验通过（%s），现在更新？[y/N]: " "$REMOTE_TAG"
        _ans=""
        if read -r _ans < /dev/tty 2>/dev/null; then :; else _ans=""; fi
        case "$_ans" in
            [Yy]*) ;;
            *)
                echo "已取消：安装区一个字节都没动。"
                rm -f "$_tgz" 2>/dev/null || true
                rm -rf "$_exdir" 2>/dev/null || true
                return 0
                ;;
        esac
    fi
    # 覆盖安装区（跳过 monitor 保日志；全部文件一次覆盖到位，含正在执行的核心脚本——
    # 写的是同目录临时文件再改名，运行中的旧文件不受影响）。
    # 注意顺序：先覆盖、后停监控——停得越晚，监控裸奔的窗口越短。
    # 旧监控在覆盖期间只读写变量与自启动，不碰程序文件，不会打架。
    # DIVERGE(Mac): Windows 侧是先停监控再覆盖。两侧收尾都会由新脚本的安装再对齐一次，
    # 最终状态相同；这里选"后停"只为缩短变量无人纠正的窗口。
    echo "正在安装新版（保留日志）..."
    if ! install_package "$_exdir" "$_uroot" "$_exdir" "mac release-notes assets"; then
        rm -f "$_tgz" 2>/dev/null || true
        rm -rf "$_exdir" 2>/dev/null || true
        echo "安装区已回滚（覆盖前监控没停，不需要恢复）。"
        return 1
    fi
    echo "正在停止旧监控..."
    rm -f "$_tgz" 2>/dev/null || true
    if [ "${_clean_source:-0}" = "1" ]; then clean_source_files "$_uroot" || true; fi
    # 收尾跑**安装根里**的新脚本：只有从安装根执行，路径记录、自启动与监控才会落在安装根，
    # 不会指向马上要被删掉的解压目录（那会让监控起来后立刻自退、"切换为正式安装"变成假的）。
    # 用子进程而不是 exec：失败时还能用当前（旧）代码兜底把监控拉起来，不让它停在停用状态。
    # 交出手里的操作锁：收尾子进程跑的是同一个安装动作，它会自己去拿锁。
    rm -rf "$MONITOR_DIR/.op.lock" 2>/dev/null || true
    trap - EXIT
    if ! /bin/bash "$_uroot/mac/envproxy.sh" install; then
        echo "收尾没走完，正在按当前文件重启监控..."
        install_envproxy >/dev/null 2>&1 || true
        echo "如果状态仍不对，请打开菜单选一次"安装 / 修复"。"
    fi
    rm -rf "$_exdir" 2>/dev/null || true
}

# 打印这一版改了什么：包内 release-notes/<标签>.md，最多 40 行；没有就跳过。
show_release_notes() {
    # tag 先清洗再拼路径：$2 来自远端 API，未清洗直接拼会有路径穿越风险（与 tgz/exdir 共用同一条卫生规则）。
    _ntag=$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '_')
    _nfile="$1/release-notes/$_ntag.md"
    [ -f "$_nfile" ] || return 0
    echo "---------- $2 改了什么 ----------"
    sed -n '1,40p' "$_nfile" 2>/dev/null
    _nlines=$(wc -l < "$_nfile" 2>/dev/null | tr -d ' ')
    if [ -n "$_nlines" ] && [ "$_nlines" -gt 40 ] 2>/dev/null; then
        echo "  （以上为前 40 行；全文见 Releases 页面，更新完成后也会出现在安装目录的 release-notes/$_ntag.md）"
    fi
    echo "----------------------------------"
    return 0
}
