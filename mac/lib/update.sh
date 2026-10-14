# ------------------------------------------------------------------------------
#  update.sh — 更新层：版本比较、下载校验、用户确认流程、安装来源分流
#  状态显示只读；动手只走更新入口。
# ------------------------------------------------------------------------------

# 更新源：GitHub Release 里的安装包资产（见第 9 节）。
# 开发副本（安装根有 .git）的只读版本检查跟自己的 git remote 走，
# 覆盖文件这条路上 git 副本一律不参与。
UPDATE_REPO_DEFAULT="FiretrUCK666/envproxy"

# ------------------------------------------------------------------------------
# 9. 在线更新（检查更新 + 一键升级；状态显示只读，动手只在这里）
# ------------------------------------------------------------------------------
# 更新源：GitHub Release 里的分平台安装包资产（EnvProxy-mac.tar.gz；Windows 侧取 EnvProxy-win.zip）。
#   只同步本平台目录与共享文件，另一平台目录不动（分平台包里本来就没有它）。
#   安装包内容由仓库 .gitattributes 的 export-ignore 声明，发布流水线用 git archive 产出。
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
# 现在网页上下载的 zip 已不再含这些文件，见 README 故障排查）。
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

# 取文本：先按当前环境（含代理变量）取，失败再直连重试一次。
# DIVERGE(Mac): Win 侧走系统代理恒为直连，需显式经 127.0.0.1 重试；
# Mac 侧 curl 继承环境变量代理，这里反向补一次直连回退，两方向都覆盖。
fetch_update_text() {
    _out=$(curl -fsSL --max-time 3 -A "EnvProxyUpdate" "$1" 2>/dev/null) \
        && { printf '%s' "$_out"; return 0; }
    env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy \
        curl -fsSL --max-time 3 --noproxy '*' -A "EnvProxyUpdate" "$1" 2>/dev/null
}

# 下载文件：返回 0 = 成功，22 = 这个地址确实没有文件（HTTP 404，不必再试代理），其余 = 失败。
fetch_update_file() {
    curl -fsSL --max-time 60 -A "EnvProxyUpdate" -o "$2" "$1" 2>/dev/null
    _curlrc=$?
    [ "$_curlrc" -eq 0 ] && return 0
    [ "$_curlrc" -eq 22 ] && return 22
    env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy \
        curl -fsSL --max-time 60 --noproxy '*' -A "EnvProxyUpdate" -o "$2" "$1" 2>/dev/null
}

# 查最新 Release：成功时置 REMOTE_VERSION / REMOTE_TAG 并返回 0，否则返回 1（只读）。
REMOTE_VERSION=""
REMOTE_TAG=""

get_remote_version() {
    _repo=$(get_update_repo)
    _json=$(fetch_update_text "https://api.github.com/repos/$_repo/releases/latest" || true)
    [ -n "$_json" ] || return 1
    _tag=$(printf '%s' "$_json" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
    [ -n "$_tag" ] || return 1
    REMOTE_TAG="$_tag"
    REMOTE_VERSION=$(printf '%s' "$_tag" | sed -E 's/^v//')
    [ -n "$REMOTE_VERSION" ] || return 1
    return 0
}

update_envproxy() {
    _yes="$1"
    echo "======== EnvProxy 检查更新 ========"
    _local=$(get_local_version || true)
    if [ -n "$_local" ]; then echo "本地版本 : v$_local"; else echo "本地版本 : 未知"; fi
    echo "正在检查最新版本（最多等几秒）..."
    if ! get_remote_version; then
        echo "最新版本 : 检查失败（网络不可达或 GitHub API 限流）"
        echo "请稍后重试；把翻墙软件开关一次再试也是常见解法。"
        return 0
    fi
    echo "最新版本 : $REMOTE_TAG"
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
    # 下载安装包到临时目录并校验；校验没过就一个字节都不动安装区
    _repo=$(get_update_repo)
    _url="https://github.com/$_repo/releases/download/$REMOTE_TAG/EnvProxy-mac.tar.gz"
    # DIVERGE(Mac): Mac 取 tar.gz + tar；Win 取 zip + Expand-Archive（见 envproxy.ps1）。
    # 临时路径必须不可预测：固定名字 + 先删后建，攻击者可预置同名 symlink 把下载与解压引向别处。
    # 下载失败只提示确认 GitHub 可达后重试：镜像站只收录部分项目，加速代理属透明中转，
    # 不硬编码任何第三方域名，不为它放宽校验。
    _rnd=$(mktemp /tmp/envproxy_update.XXXXXX 2>/dev/null) || { echo "更新失败：临时文件建不起，未做任何改动。"; return 0; }
    rm -f "$_rnd" 2>/dev/null || true
    _tgz="$_rnd.tar.gz"
    _exdir="$_rnd-src"
    echo "正在下载安装包..."
    rm -f "$_tgz" 2>/dev/null || true
    rm -rf "$_exdir" 2>/dev/null || true
    mkdir -p "$_exdir" 2>/dev/null || { echo "更新失败：临时目录建不起，未做任何改动。"; return 0; }
    fetch_update_file "$_url" "$_tgz"
    _dlrc=$?
    if [ "$_dlrc" -ne 0 ]; then
        if [ "$_dlrc" -eq 22 ]; then
            echo "更新失败：这个版本没有提供安装包（下载地址返回 404），未做任何改动。请到 Releases 页面手动下载。"
        else
            echo "更新失败：下载失败（网络不可达），未做任何改动。"
        fi
        rm -f "$_tgz" 2>/dev/null || true
        rm -rf "$_exdir" 2>/dev/null || true
        return 0
    fi
    echo "正在解压并校验..."
    if ! tar -xzf "$_tgz" -C "$_exdir" 2>/dev/null; then
        echo "更新失败：解压失败，未做任何改动。"
        rm -f "$_tgz" 2>/dev/null || true
        rm -rf "$_exdir" 2>/dev/null || true
        return 0
    fi
    if ! verify_package "$_exdir" "$REMOTE_VERSION" "mac"; then
        echo "更新失败：校验失败（包内容与目标版本对不上，或编码红线被改过），未做任何改动。"
        rm -f "$_tgz" 2>/dev/null || true
        rm -rf "$_exdir" 2>/dev/null || true
        return 0
    fi
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
    if ! install_package "$_exdir" "$_uroot" "$_exdir"; then
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
