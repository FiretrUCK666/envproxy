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
# 失败原因写进全局 FETCH_FAILURE（见下面的失败原因词表），调用方据此提示。
fetch_update_text() {
    _out=$(curl -fsSL --max-time 8 -A "EnvProxyUpdate" "$1" 2>/dev/null) \
        && { printf '%s' "$_out"; return 0; }
    env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy \
        curl -fsSL --max-time 8 --noproxy '*' -A "EnvProxyUpdate" "$1" 2>/dev/null
}

# ------------------------------------------------------------------------------
# 失败原因分类：把"为什么不行"从一堆布尔量变成一个明确的值
# ------------------------------------------------------------------------------
# 以前所有失败都塌缩成同一个 "fail"，于是提示只能笼统说"下载失败"——用户分不清
# 是发布漏了包（等也没用）、GitHub 限流（一小时后会好）、还是自己网络不通（开代理就好）。
# 这三种情况要做的动作完全不同，混成一句话等于把判断责任推给使用者。
# 原因词表（两侧必须一致，见 check.yml 门禁 6）。**表的顺序就是报告优先级**：
# 越靠前越该先报给用户——"最可行动"的那个先说，用户照着做就行。
#   local       本机临时目录不可写——是本机的问题，与网络和发布都无关
#   network     连不上（超时、DNS、连接被拒）——开代理或换网络就好
#   quota       GitHub 接口配额用尽（403/429 且带限流特征）——等一小时会好
#   server      GitHub 服务端出错（5xx）——等一会儿会好
#   bad-content 拿回来的不是安装包（200 但内容是 JSON/HTML/损坏的包）
#   missing     这个版本没有提供该文件（404/410）——等不会好，要去 Releases 手动下
# missing 排在最后是刻意的：它指控的是发布方，只有在没有别的解释时才能这么说。
UPDATE_FAILURE_KINDS="local network quota server bad-content missing"

# 把 HTTP 状态码归到失败原因。403/429 有两种含义（限流 vs 真的被拒），
# 靠响应头里的 X-RateLimit-Remaining 区分：剩 0 就是配额用尽。
# $2 传剩余配额（可空）；传空表示"没拿到这个头"，此时按"真的被拒"处理。
update_failure_kind() {
    _ufk_code="$1"
    _ufk_rem="$2"
    case "$_ufk_code" in
        404|410) printf 'missing'; return 0 ;;
        429) printf 'quota'; return 0 ;;
        403)
            if [ "$_ufk_rem" = "0" ]; then printf 'quota'; else printf 'server'; fi
            return 0 ;;
        5??) printf 'server'; return 0 ;;
        *) printf 'network'; return 0 ;;
    esac
}

# 把失败原因翻译成一句人能据此行动的话（与 Windows 侧同义）。
# 判据只有一条：用户读完这句，知道下一步该做什么。
update_failure_message() {
    _ufm_kind="$1"
    _ufm_src="$2"
    case "$_ufm_kind" in
        missing)
            printf '%s 上没有提供这个版本的安装包（等也不会出现）。请到 Releases 页面手动下载对应平台的安装包，覆盖一次即可。' "$_ufm_src"
            ;;
        quota)
            printf 'GitHub 接口配额用尽了（匿名访问每小时 60 次，%s 也因此没问出结果）。等一小时后重试通常就好；也可以先到 Releases 页面手动下载。' "$_ufm_src"
            ;;
        server)
            printf '%s 服务端出错（HTTP 5xx 或请求被拒）。这通常是对方临时故障，过一会儿重试就好。' "$_ufm_src"
            ;;
        network)
            printf '连不上 %s（超时或连接被拒）。可以打开翻墙软件让请求走代理再试一次，或稍后重试。' "$_ufm_src"
            ;;
        bad-content)
            printf '从 %s 拿回来的内容不是安装包（可能下载不完整，或被中间网络改写）。请重试一次，或到 Releases 页面手动下载安装包。' "$_ufm_src"
            ;;
        local)
            printf '本机临时目录不可写，没法下载安装包（与网络和发布都无关）。请检查磁盘空间与临时目录权限，或手动下载安装包覆盖。'
            ;;
        *)
            printf '从 %s 更新失败。请稍后重试，或到 Releases 页面手动下载安装包。' "$_ufm_src"
            ;;
    esac
}

# 从多条尝试的失败原因里挑一个报给用户（纯函数，可自检）。
# 规则（与 Windows 侧同一套，两边必须一致）：
#   1. 只有"全部都是 missing"才报 missing。404 必须是没有别的解释时才算数——
#      被墙的中间设备会给假 404，混着网络故障时说"发布漏了包"等于冤枉维护者。
#   2. 其余情况按"最可行动"排序取第一个：local（要修本机）> network（开代理就好）>
#      quota（等一小时）> server（等一会儿）> bad-content（重试或手动）。
select_update_failure_kind() {
    _ufk_all="$*"
    # 先去掉重复项：同一个原因出现几次不影响结论。
    _ufk_uniq=""
    for _ufk_k in $_ufk_all; do
        [ -n "$_ufk_k" ] || continue
        case " $_ufk_uniq " in *" $_ufk_k "*) continue ;; esac
        _ufk_uniq="$_ufk_uniq $_ufk_k"
    done
    [ -n "$_ufk_uniq" ] || { printf 'network'; return 0; }
    # 只有一种原因：原样报出。
    _ufk_n=0
    for _ufk_k in $_ufk_uniq; do _ufk_n=$((_ufk_n + 1)); done
    if [ "$_ufk_n" -eq 1 ]; then
        for _ufk_k in $_ufk_uniq; do printf '%s' "$_ufk_k"; done
        return 0
    fi
    # 按词表顺序取第一个命中的：missing 排在最后（它只在没有别的解释时才成立）。
    for _ufk_p in $UPDATE_FAILURE_KINDS; do
        case " $_ufk_uniq " in *" $_ufk_p "*) printf '%s' "$_ufk_p"; return 0 ;; esac
    done
    printf 'network'
}

# 从 releases/tags/<标签> 的 JSON 里找出某个文件名对应的资产（纯函数，自检可测）。
# 结果写进全局 ASSET_ID（资产编号）与 ASSET_DIGEST（GitHub 给的 sha256，可能为空）。
# 找不到、或 JSON 形状不对，两个全局都留空——调用方据此退回直连下载，不当错误处理。
#
# 为什么逐字符扫而不是"按 },{ 切块 + 正则取字段"：切块是文本扫描，遇到自由文本就出错。
# 真实响应里每个资产都带一个 uploader 对象，里面**也有 id 字段**（用户的 GitHub 账号 id）；
# 发布标题的 name 字段和资产的文件名同处顶层；而发布说明是自由文本，里面出现 },{ 就会把
# 切块切坏。所以这里认得字符串边界（引号与转义）与嵌套层级，只在 assets 数组的第一层取值。
#
# 契约（两侧必须一致，见 check.yml 门禁 6）：
#   1. 文件名逐字节相等（区分大小写）——GitHub 的资产名大小写敏感。
#   2. 编号取自 url 字段（…/releases/assets/<编号>）：那是我们真正要 GET 的端点，
#      权威性高于 id 字段；url 里没有才退回 id 字段。
#   3. 编号必须是 1..16 位、首位非 0（0、007、二十位数都不该进 URL）。
#   4. digest 有则必须是 sha256:<64 位十六进制>，没有就留空（老资产没这字段）。
# 不用 jq：macOS 自带环境没有它，零依赖是安装口号。
# awk 写法只用 POSIX 语法：macOS 自带的是 BSD awk，不支持 {n} 区间量词。
get_asset_from_json() {
    ASSET_ID=""
    ASSET_DIGEST=""
    [ -n "$1" ] && [ -n "$2" ] || return 0
    _gaf=$(printf '%s' "$1" | tr '\n' ' ' | awk -v want="$2" '
    function valid_id(v) { return (v ~ /^[1-9][0-9]*$/ && length(v) <= 16) }
    function is_sha256(v,   h) {
        if (length(v) != 71) return 0
        if (substr(v, 1, 7) != "sha256:") return 0
        h = substr(v, 8)
        return (h ~ /^[0-9a-f]+$/) ? 1 : 0
    }
    function id_from(url, idf,   v) {
        if (match(url, /releases\/assets\/[0-9]+/)) {
            v = substr(url, RSTART, RLENGTH)
            gsub(/[^0-9]/, "", v)
            if (valid_id(v)) return v
        }
        if (idf ~ /^[0-9]+$/ && valid_id(idf)) return idf
        return ""
    }
    {
        doc = $0
        n = length(doc)
        i = 1
        depth = 0
        instr = 0
        esc = 0
        s = ""
        key = ""
        expectval = 0
        inassets = 0
        adep = -1
        aname = ""; aurl = ""; aid = ""; adg = ""
        while (i <= n) {
            c = substr(doc, i, 1)
            if (expectval) {
                while (i <= n && substr(doc, i, 1) ~ /[ \t]/) i++
                c = substr(doc, i, 1)
                if (c == "\"") { instr = 1; s = ""; esc = 0; i++; expectval = 0; continue }
                if (c == "{" || c == "[") { expectval = 0; continue }
                v = ""
                while (i <= n) {
                    c = substr(doc, i, 1)
                    if (c == "," || c == "}" || c == "]" || c == " " || c == "\t") break
                    v = v c
                    i++
                }
                if (inassets && depth == adep + 1) {
                    if (key == "id") aid = v
                    else if (key == "digest") adg = v
                }
                key = ""
                expectval = 0
                continue
            }
            if (instr) {
                if (esc) { s = s c; esc = 0 }
                else if (c == "\\") { esc = 1 }
                else if (c == "\"") {
                    instr = 0
                    j = i + 1
                    while (j <= n && substr(doc, j, 1) ~ /[ \t]/) j++
                    if (substr(doc, j, 1) == ":") {
                        key = s
                    } else {
                        if (inassets && depth == adep + 1) {
                            if (key == "name") aname = s
                            else if (key == "url") aurl = s
                            else if (key == "id") aid = s
                            else if (key == "digest") adg = s
                        }
                        key = ""
                    }
                } else { s = s c }
                i++
                continue
            }
            if (c == "\"") { instr = 1; s = ""; esc = 0; i++; continue }
            if (c == ":") { expectval = 1; i++; continue }
            if (c == "{") {
                depth++
                if (inassets && depth == adep + 1) { aname=""; aurl=""; aid=""; adg="" }
                i++
                continue
            }
            if (c == "}") {
                if (inassets && depth == adep + 1) {
                    if (aname == want) {
                        v = id_from(aurl, aid)
                        if (v != "") {
                            d = is_sha256(adg) ? adg : ""
                            printf "%s|%s", v, d
                            exit
                        }
                    }
                    aname=""; aurl=""; aid=""; adg=""
                }
                depth--
                i++
                continue
            }
            if (c == "[") {
                if (key == "assets" && !inassets) { inassets = 1; adep = depth }
                key = ""
                i++
                continue
            }
            if (c == "]") {
                if (inassets && depth == adep) { inassets = 0 }
                key = ""
                i++
                continue
            }
            if (c == ",") { key = ""; i++; continue }
            i++
        }
    }')
    [ -n "$_gaf" ] || return 0
    ASSET_ID="${_gaf%%|*}"
    ASSET_DIGEST="${_gaf#*|}"
    [ "$ASSET_DIGEST" = "$_gaf" ] && ASSET_DIGEST=""
    return 0
}

# 下载成功不等于拿到的是安装包：请求头被网络中间层丢掉时，资产端点会回 200 + JSON。
# 先判前两个字节是不是 gzip 头（1f8b），再**真开一次**——魔数只能证明"不是 JSON/HTML"，
# 截断的包同样以 1f8b 开头；打不开就丢弃这份内容，让调用方继续试直连那条路。
_is_gzip() {
    [ -s "$1" ] || return 1
    [ "$(od -An -tx1 -N2 "$1" 2>/dev/null | tr -d ' \n')" = "1f8b" ] || return 1
    tar -tzf "$1" >/dev/null 2>&1
}

# 问这一源的 API 要"某个标签下某个文件的资产 id"。拿不到输出空，绝不报错退出。
get_update_asset() {
    _ga_json=$(fetch_update_text "$1/releases/tags/$2" || true)
    [ -n "$_ga_json" ] || return 0
    get_asset_from_json "$_ga_json" "$3"
}

# 取一个文件到本地：$1=目标文件 $2=额外请求头（空则不带）$3=URL
# 拆成两个小函数是为了让"带不带请求头"只在一个地方分支，调用方（含直连兜底）不必各写两遍。
_fetch_to_file() {
    # -D 把响应头另存一份：判断"配额用尽"要看 X-RateLimit-Remaining，
    # 光看状态码分不出 403 是限流还是真的被拒。
    if [ -n "$2" ]; then
        curl -fsSL --max-time 60 -D "$1.headers" -A "EnvProxyUpdate" -H "$2" -o "$1" -w '%{http_code}' "$3" 2>/dev/null
    else
        curl -fsSL --max-time 60 -D "$1.headers" -A "EnvProxyUpdate" -o "$1" -w '%{http_code}' "$3" 2>/dev/null
    fi
}

_fetch_to_file_direct() {
    if [ -n "$2" ]; then
        env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy \
            curl -fsSL --max-time 60 --noproxy '*' -D "$1.headers" -A "EnvProxyUpdate" -H "$2" -o "$1" -w '%{http_code}' "$3" 2>/dev/null
    else
        env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy \
            curl -fsSL --max-time 60 --noproxy '*' -D "$1.headers" -A "EnvProxyUpdate" -o "$1" -w '%{http_code}' "$3" 2>/dev/null
    fi
}

# 下载失败的原因（见下面的失败原因词表）：fetch_update_file 写入，调用方读取。
FETCH_FAILURE=""
# 资产解析结果：get_asset_from_json 写入，调用方读取。
# ASSET_ID 是 GitHub 资产端点的编号，ASSET_DIGEST 是 GitHub 算好的 sha256（老资产没有，为空）。
ASSET_ID=""
ASSET_DIGEST=""

# 下载文件：$1=URL $2=目标文件 $3=额外请求头（可空，API 资产端点要 Accept: application/octet-stream）
# 入口开着 set -u，所以 $3 必须带默认值：两参调用（直连兜底那条）不许因为少一个参数就整条失效。
# 成功返回 0，失败返回非 0，并把失败原因写进全局 FETCH_FAILURE（见失败原因词表）。
# 判据必须是**真实状态码**，不能拿 curl -f 的退出码当语义：-f 对任何 >=400 一律返回 22
# （实测 400/401/403/404/410/429/500/502/503 全是 22），把 22 当"没提供安装包"会把限流和
# 服务端故障一起误报成缺包，还会掐掉本该有的直连重试。Windows 侧判的就是 404/410。
fetch_update_file() {
    _fuf_hdr="${3:-}"
    _fuf_code=$(_fetch_to_file "$2" "$_fuf_hdr" "$1")
    _fuf_rc=$?
    [ "$_fuf_rc" -eq 0 ] && return 0
    _fuf_rem=$(_fetch_rate_remaining "$2")
    FETCH_FAILURE=$(update_failure_kind "$_fuf_code" "$_fuf_rem")
    # 非"文件不存在"的失败：直连再试一次（代理变量在、代理却不干活，是墙内常见形态）。
    # 但只有"连不上"才值得再试一次：配额与服务端错误换个出口也是同样结果，重试只是白等。
    if [ "$FETCH_FAILURE" = "network" ]; then
        _fuf_code2=$(_fetch_to_file_direct "$2" "$_fuf_hdr" "$1")
        _fuf_rc2=$?
        [ "$_fuf_rc2" -eq 0 ] && return 0
        _fuf_rem2=$(_fetch_rate_remaining "$2")
        FETCH_FAILURE=$(update_failure_kind "$_fuf_code2" "$_fuf_rem2")
    fi
    return 1
}

# 从上一次下载留下的响应头里读"配额还剩多少"（读不到就返回空）。
# curl 把响应头写进目标文件旁边的 .headers 文件里（见 _fetch_to_file）。
# 403 有两种含义（限流 / 真的被拒），靠这个头区分：剩 0 就是配额用尽。
_fetch_rate_remaining() {
    _frr_h="$1.headers"
    [ -f "$_frr_h" ] || return 0
    # 取最后一个 x-ratelimit-remaining（重定向时会有多组头，最后一组才是最终响应）。
    _frr_v=$(grep -i '^x-ratelimit-remaining:' "$_frr_h" 2>/dev/null | tail -n 1 | tr -d '\r' | sed 's/^[^:]*:[[:space:]]*//')
    printf '%s' "$_frr_v"
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
    FETCH_FAILURE=""
    _ajson=$(fetch_update_text "$1" || true)
    if [ -z "$_ajson" ]; then
        # curl 的退出码分不出 404/403/超时：这里按"连不上或被拒"归类，
        # 由上层统一挑一句准确的话报给用户。
        FETCH_FAILURE="network"
        return 0
    fi
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
# 全都问不到时，REMOTE_FAILURE_KIND 记下原因（供提示用）。
REMOTE_FAILURE_KIND="network"
get_remote_version() {
    # 源表用 here-doc 喂给 while，不用管道：管道会把 while 丢进子 shell，
    # 里面赋的 REMOTE_* 出了循环就没了——而那正是调用方要读的东西。
    _grv_kinds=""
    while IFS='|' read -r _sname _spref _sapi _sweb _sbase _sapirepo; do
        [ -n "$_sname" ] || continue
        if get_remote_version_from "$_sname" "$_spref" "$_sapi" "$_sweb" "$_sbase"; then
            REMOTE_FAILURE_KIND=""
            return 0
        fi
        [ -n "$FETCH_FAILURE" ] && _grv_kinds="$_grv_kinds $FETCH_FAILURE"
    done <<_ENVPROXY_SRCS_
$(get_update_sources)
_ENVPROXY_SRCS_
    REMOTE_FAILURE_KIND=$(select_update_failure_kind "$_grv_kinds")
    return 1
}

# 换源时这个源该不该接受（纯函数，自检可测）：必须比本地新，且不能比已经选定的胜出版本旧。
# 只看"比本地新"是不够的——那样 A 源答 9.9.9 却拿不到包时，B 源的 1.5.0 也会被接受，
# 用户会被"换源"带到更旧的版本上（Windows 侧比的是胜出版本，两侧必须同一套判据）。
# 返回 0 = 接受，1 = 跳过。
source_acceptable() {
    _sa_ver="$1"; _sa_win="$2"; _sa_local="$3"
    [ -n "$_sa_ver" ] || return 1
    _sa_cmp=$(compare_versions "$_sa_ver" "$_sa_local" 2>/dev/null || echo 0)
    [ "$_sa_cmp" -gt 0 ] 2>/dev/null || return 1
    if [ -n "$_sa_win" ]; then
        _sa_cmp2=$(compare_versions "$_sa_ver" "$_sa_win" 2>/dev/null || echo 0)
        [ "$_sa_cmp2" -lt 0 ] 2>/dev/null && return 1
    fi
    return 0
}

update_envproxy() {
    _yes="$1"
    echo "======== EnvProxy 检查更新 ========"
    _local=$(get_local_version || true)
    if [ -n "$_local" ]; then echo "本地版本 : v$_local"; else echo "本地版本 : 未知"; fi
    echo "正在检查最新版本（最多等十几秒）..."
    if ! get_remote_version; then
        # 问版本失败也要说清原因：连不上要开代理，配额用尽要等，仓库改名/删库是另一回事。
        echo "最新版本 : 检查失败（$(update_failure_message "${REMOTE_FAILURE_KIND:-network}" "所有更新源")）"
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
    _rnd=$(mktemp /tmp/envproxy_update.XXXXXX 2>/dev/null) || { echo "更新失败：本机临时目录建不起临时文件，未做任何改动。"; echo "请检查磁盘空间与 /tmp 权限，或到 Releases 页面手动下载安装包。"; return 0; }
    rm -f "$_rnd" 2>/dev/null || true
    _tgz=""
    _exdir=""
    # 各次尝试的失败原因（空格分隔）：最后统一挑一个报给用户，
    # 不再各说各的（以前"缺包"和"下载失败"两句会互相矛盾）。
    _pkg_kinds=""
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
        # 换源不能把用户带到更旧的版本上：既要比本地新，也不能比已选定的胜出版本旧。
        source_acceptable "$REMOTE_VERSION" "$_pre_ver" "$_local" || continue
        _sl=$(printf '%s' "$_sname" | tr -c 'A-Za-z0-9' '_')
        _try_tgz="${_rnd}.${_sl}.tar.gz"
        _try_dir="${_rnd}.${_sl}-src"
        rm -f "$_try_tgz" "$_try_tgz.headers" 2>/dev/null || true
        rm -rf "$_try_dir" 2>/dev/null || true
        if ! mkdir -p "$_try_dir" 2>/dev/null; then
            # 解压目录建不起来 = 本机临时目录不可写，与网络和发布都无关。
            _pkg_kinds="$_pkg_kinds local"
            continue
        fi
        # 下载顺序：API 资产端点优先，直连下载兜底（见源表上方的说明）。
        # 两条路都可能"这一版没提供这个文件"，任一条拿到就算成功；都不成才换源。
        # 每次失败的**原因**记进 _pkg_kinds，最后统一挑一句准确的话报给用户。
        _got=1
        # 资产编号与校验值是**全局变量**（get_asset_from_json 写全局）：
        # 用命令替换捕获会在子 shell 里跑，取回来的永远是空——所以这里直接调用再读全局。
        get_update_asset "$_sapirepo" "$REMOTE_TAG" "EnvProxy-mac.tar.gz" || true
        _asset_id="$ASSET_ID"
        _asset_digest="$ASSET_DIGEST"
        if [ -n "$_asset_id" ]; then
            fetch_update_file "$_sapirepo/releases/assets/$_asset_id" "$_try_tgz" "Accept: application/octet-stream"
            _rc=$?
            if [ "$_rc" -eq 0 ]; then
                # 200 不等于拿到包：请求头被中间层丢掉时这里回的是 JSON。不是 gzip 就丢弃，
                # 让下面的直连兜底接手——否则会把"网络问题"报成"发布缺包/校验失败"。
                if _is_gzip "$_try_tgz"; then _got=0; else rm -f "$_try_tgz" "$_try_tgz.headers" 2>/dev/null || true; _pkg_kinds="$_pkg_kinds bad-content"; fi
            else
                _pkg_kinds="$_pkg_kinds $FETCH_FAILURE"
            fi
        fi
        if [ "$_got" -ne 0 ]; then
            fetch_update_file "$_sbase/releases/download/$REMOTE_TAG/EnvProxy-mac.tar.gz" "$_try_tgz" ""
            _rc=$?
            if [ "$_rc" -eq 0 ]; then
                if _is_gzip "$_try_tgz"; then _got=0; else rm -f "$_try_tgz" "$_try_tgz.headers" 2>/dev/null || true; _pkg_kinds="$_pkg_kinds bad-content"; fi
            else
                _pkg_kinds="$_pkg_kinds $FETCH_FAILURE"
            fi
        fi
        if [ "$_got" -ne 0 ]; then
            rm -f "$_try_tgz" "$_try_tgz.headers" 2>/dev/null || true
            rm -rf "$_try_dir" 2>/dev/null || true
            continue
        fi
        if ! tar -xzf "$_try_tgz" -C "$_try_dir" 2>/dev/null; then
            # 解不开 = 内容不对（包损坏或被中间网络改写），不是"发布漏包"。
            _pkg_kinds="$_pkg_kinds bad-content"
            rm -f "$_try_tgz" "$_try_tgz.headers" 2>/dev/null || true
            rm -rf "$_try_dir" 2>/dev/null || true
            continue
        fi
        if ! verify_package "$_try_dir" "$REMOTE_VERSION" "mac"; then
            # 包能解开但结构不对 = 内容不对（发版漏文件、包被改写）。
            _pkg_kinds="$_pkg_kinds bad-content"
            rm -f "$_try_tgz" "$_try_tgz.headers" 2>/dev/null || true
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
        _pkg_kind=$(select_update_failure_kind "$_pkg_kinds")
        echo "更新失败：$(update_failure_message "$_pkg_kind" "${REMOTE_SOURCE_NAME:-更新源}")"
        echo "未做任何改动。"
        rm -f "$_rnd"* 2>/dev/null || true
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
                rm -f "$_tgz" "$_tgz.headers" 2>/dev/null || true
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
        rm -f "$_tgz" "$_tgz.headers" 2>/dev/null || true
        rm -rf "$_exdir" 2>/dev/null || true
        echo "安装区已回滚（覆盖前监控没停，不需要恢复）。"
        return 1
    fi
    echo "正在停止旧监控..."
    rm -f "$_tgz" "$_tgz.headers" 2>/dev/null || true
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
