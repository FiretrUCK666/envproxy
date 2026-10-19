# ------------------------------------------------------------------------------
#  update.sh — 更新层：版本比较、下载校验、用户确认流程、安装来源分流
#  状态显示只读；动手只走更新入口。
# ------------------------------------------------------------------------------

# 更新源：分平台安装包资产（见第 9 节），按源表逐源尝试。
# 开发副本（安装根有 .git）的只读版本检查跟自己的 git remote 走，
# 覆盖文件这条路上 git 副本一律不参与。
UPDATE_REPO_DEFAULT="FiretrUCK666/envproxy"

# 镜像仓库：在 Gitee 建好镜像仓库后填 "<用户名>/<仓库名>"（例如 "FiretrUCK666/envproxy"）。
# 留空 = 这一源尚未启用，逐源尝试时直接跳过——这是源表的正常状态（镜像还没建），
# 不是特例分支，所以不需要任何开关变量。
GITEE_MIRROR_REPO=""

# 更新源表：每行一条 "<标识来源> <显示名> <API> <下载前缀>"，有序，逐个尝试，
# 第一个能回答"最新版是什么"的胜出。
# 每行一条 "<标识来源> <显示名> <优先路径> <Api> <Web> <下载前缀>"，@@ 接仓库标识
# （用参数展开做纯字符串替换，不经 sed——正则会把地址里的符号当元字符）。
# 加一个镜像源 = 加一行，不动任何判断逻辑。
# 顺序即优先级：官方源在前（能通时它最快、也最权威），镜像源在后兜底。
# 两个源的 release JSON 同构（都取 tag_name）、网页路径同构（都 302 到 /releases/tag/<标签>）、
# 下载路径同构（/<仓库>/releases/download/<标签>/<文件名>），所以解析与下载代码完全共用。
#
# 为什么每个源要两条路径、且优先顺序按源定：两条各有短板。
#   Api 语义明确，但两个源都有配额——Gitee 匿名 API 会整段回 403 Rate Limit Exceeded（实测），
#       GitHub 匿名 API 只有 60 次/小时/IP。
#   Web 走网页重定向，不吃 API 配额；但 GitHub 侧的网页路径在受限网络里会整段超时
#       （实测同一条 URL curl 拿到 302、.NET 超时），Gitee 侧反而稳（约 240ms）。
# 通道不止一条的理由是产品自身的前提——用这个工具的人可能正处在"还没连上代理"的时刻，
# 而官方源在那个时刻通常不可达；没有镜像兜底，更新就变成了"必须先能翻墙才能更新"。
# 两个源都归维护者所有，信任级别一致，因此校验口径一个字都不用放宽。
UPDATE_SOURCE_TABLE='official GitHub Api https://api.github.com/repos/@@/releases/latest https://github.com/@@/releases/latest https://github.com/@@
mirror Gitee Web https://gitee.com/api/v5/repos/@@/releases/latest https://gitee.com/@@/releases/latest https://gitee.com/@@'

# ------------------------------------------------------------------------------
# 9. 在线更新（检查更新 + 一键升级；状态显示只读，动手只在这里）
# ------------------------------------------------------------------------------
# 更新源：分平台安装包资产（EnvProxy-mac.tar.gz；Windows 侧取 EnvProxy-win.zip），按上面的源表逐源尝试。
#   只同步本平台目录与共享文件，另一平台目录不动（分平台包里本来就没有它）。
#   安装包内容由仓库 .gitattributes 的 export-ignore 声明，发布流水线用 git archive 产出。
#   不接公共加速站：那些站点靠站长自掏腰包维持、生命周期以月计，而且包从它手里过一遍
#   就等于多信一个陌生人。镜像走的是维护者自己在国内平台建的仓库，与自己 GitHub 仓库同级，
#   因此校验口径一个字都不用放宽。
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

# 这一源的仓库标识从哪里取。
#   official：环境事实——开发副本跟自己的 git remote 走（fork 后看得见自己仓库的 Release），
#             安装副本用内置默认；
#   mirror：维护者在 Gitee 建好镜像仓库后填进 GITEE_MIRROR_REPO，留空 = 这一源尚未启用。
update_source_id() {
    case "$1" in
        mirror) printf '%s' "$GITEE_MIRROR_REPO" ;;
        *) printf '%s' "$(get_update_repo)" ;;
    esac
}

# 取文本：先按当前环境（含代理变量）取，失败再直连重试一次。
# DIVERGE(Mac): Win 侧走系统代理恒为直连，需显式经 127.0.0.1 重试；
# Mac 侧 curl 继承环境变量代理，这里反向补一次直连回退，两方向都覆盖。
fetch_update_text() {
    _out=$(curl -fsSL --max-time 3 -A "EnvProxyUpdate" "$1" 2>/dev/null) \
        && { printf '%s' "$_out"; return 0; }
    env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy \
        curl -fsSL --max-time 3 --noproxy '*' -A "EnvProxyUpdate" "$1" 2>/dev/null
}

# 下载文件。返回 0 = 成功，22 = 这个地址确实没有文件（HTTP 404/410，不必再试代理），其余 = 失败。
# 判据必须是**真实状态码**，不能拿 curl -f 的退出码当语义：-f 对任何 >=400 一律返回 22
# （实测 400/401/403/404/410/429/500/502/503 全是 22），把 22 当"没提供安装包"会把限流和
# 服务端故障一起误报成缺包，还会掐掉本该有的直连重试。Windows 侧判的就是 404/410。
fetch_update_file() {
    _code=$(curl -fsSL --max-time 60 -A "EnvProxyUpdate" -o "$2" -w '%{http_code}' "$1" 2>/dev/null)
    _rc=$?
    [ "$_rc" -eq 0 ] && return 0
    case "$_code" in 404|410) return 22 ;; esac
    # 非"文件不存在"的失败：直连再试一次（代理变量在、代理却不干活，是墙内常见形态）。
    _code2=$(env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy \
        curl -fsSL --max-time 60 --noproxy '*' -A "EnvProxyUpdate" -o "$2" -w '%{http_code}' "$1" 2>/dev/null)
    _rc2=$?
    [ "$_rc2" -eq 0 ] && return 0
    case "$_code2" in 404|410) return 22 ;; esac
    return 1
}

# 查最新 Release：成功时置 REMOTE_VERSION / REMOTE_TAG / REMOTE_SOURCE_BASE / REMOTE_SOURCE_NAME
# 并返回 0，所有源都问不到才返回 1（只读，不写文件）。
# 逐个源尝试，第一个答出来的胜出：官方源在前，它不通就自动换镜像源。
# 顺带记下胜出源的下载前缀——版本与安装包必须来自同一个源，
# 否则会出现"拿 A 源的版本号去下 B 源的包"。
REMOTE_VERSION=""
REMOTE_TAG=""
REMOTE_SOURCE_BASE=""
REMOTE_SOURCE_NAME=""

# 本机这次实际可用的源（有序）：每行一条 "<显示名>|<优先路径>|<Api>|<Web>|<下载前缀>"，仓库标识已代入。
# 没有仓库标识的源直接跳过——镜像还没建是正常状态，不是特例分支。
get_update_sources() {
    while read -r _sid _sname _spref _sapi _sweb _sbase; do
        [ -n "$_sid" ] || continue
        _gid=$(update_source_id "$_sid")
        [ -n "$_gid" ] || continue
        printf '%s|%s|%s|%s|%s\n' "$_sname" "$_spref" "${_sapi//@@/$_gid}" "${_sweb//@@/$_gid}" "${_sbase//@@/$_gid}"
    done <<_ENVPROXY_SOURCES_
$UPDATE_SOURCE_TABLE
_ENVPROXY_SOURCES_
}

# 从重定向目标里取标签；形状不对就返回空（调用方据此换另一条路径）。
# 必须校验它确实落在 /releases/tag/<标签> 上，不能只取最后一段：仓库改名时 Gitee 会先
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
    while IFS='|' read -r _sname _spref _sapi _sweb _sbase; do
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
    echo "正在检查最新版本（官方源不通会自动换国内镜像，最多等十几秒）..."
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
    # （同一台机器实测 api.github.com 通、github.com 整段超时），而那一刻镜像本来能救回来。
    # 换源连同版本一起换：用那一源自己的标签下它自己的包，保持"版本与包同源"。
    # DIVERGE(Mac): Mac 取 tar.gz + tar；Win 取 zip + Expand-Archive（见 envproxy.ps1）。
    # 临时路径必须不可预测：固定名字 + 先删后建，攻击者可预置同名 symlink 把下载与解压引向别处。
    _rnd=$(mktemp /tmp/envproxy_update.XXXXXX 2>/dev/null) || { echo "更新失败：临时文件建不起，未做任何改动。"; return 0; }
    rm -f "$_rnd" 2>/dev/null || true
    _tgz=""
    _exdir=""
    echo "正在下载安装包..."
    while IFS='|' read -r _sname _spref _sapi _sweb _sbase; do
        [ -n "$_sname" ] || continue
        get_remote_version_from "$_sname" "$_spref" "$_sapi" "$_sweb" "$_sbase" || continue
        # 只接受比本地新的版本：换源不能把用户带到更旧的版本上。
        _cmp=$(compare_versions "$REMOTE_VERSION" "$_local" 2>/dev/null || echo 0)
        [ "$_cmp" -gt 0 ] 2>/dev/null || continue
        _sl=$(printf '%s' "$_sname" | tr -c 'A-Za-z0-9' '_')
        _try_tgz="${_rnd}.${_sl}.tar.gz"
        _try_dir="${_rnd}.${_sl}-src"
        rm -f "$_try_tgz" 2>/dev/null || true
        rm -rf "$_try_dir" 2>/dev/null || true
        mkdir -p "$_try_dir" 2>/dev/null || continue
        if ! fetch_update_file "$_sbase/releases/download/$REMOTE_TAG/EnvProxy-mac.tar.gz" "$_try_tgz"; then
            rm -f "$_try_tgz" 2>/dev/null || true
            rm -rf "$_try_dir" 2>/dev/null || true
            continue
        fi
        if ! tar -xzf "$_try_tgz" -C "$_try_dir" 2>/dev/null; then
            rm -f "$_try_tgz" 2>/dev/null || true
            rm -rf "$_try_dir" 2>/dev/null || true
            continue
        fi
        if ! verify_package "$_try_dir" "$REMOTE_VERSION" "mac"; then
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
        echo "更新失败：没能取到可用的安装包（下载失败，或校验没通过），未做任何改动。"
        echo "请稍后重试，也可以到 Releases 页面手动下载安装包覆盖一次。"
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
