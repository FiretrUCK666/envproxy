# ------------------------------------------------------------------------------
#  package.sh — 安装包层：覆盖安装区、备份与逐文件回滚
#  每个文件都写同目录临时文件再改名，不留半截文件。
# ------------------------------------------------------------------------------

# 校验安装包：包内 VERSION 与目标一致、本平台的核心文件在、两条编码红线没被改过。
# $3 决定认哪个入口（分平台包只含自己平台，另一端的不认也不拦）。
verify_package() {
    _vroot="$1"
    _vwant="$2"
    _vplat="${3:-mac}"
    _vver=$(tr -d ' \t\r\n' < "$_vroot/VERSION" 2>/dev/null || true)
    [ -n "$_vver" ] && [ "$_vver" = "$_vwant" ] || return 1
    # 结构校验，不点名具体文件：本平台入口必须在，包内每一个脚本都要过编码红线。
    # 于是加库、改名、挪位置都不用改这里——与 CI 门禁 3 是同一条规则，两处不会漂移。
    if [ "$_vplat" = "win" ]; then _ventry="win/envproxy.ps1"; else _ventry="mac/envproxy.sh"; fi
    [ -f "$_vroot/$_ventry" ] || return 1
    # 菜单壳也必须在：它是使用者唯一能双击的东西，缺了等于装完没法打开。
    if [ "$_vplat" = "win" ]; then
        [ -f "$_vroot/win/打开菜单.cmd" ] || return 1
    else
        [ -f "$_vroot/mac/打开菜单.command" ] || return 1
    fi
    # 内容集校验：本平台目录里只能有"入口 + 菜单壳 + 根下模板 + 入口自己声明的每个库"，
    # 缺一个或多一个都拒收。只查"入口在不在"是不够的——一个只剩 VERSION + 入口的包能过那一关，
    # 而覆盖时"作用域内、新包没有的文件按清单删除"会把所有库当成旧版残留删掉：
    # 安装区被清空、VERSION 却被抬高，之后更新入口还会拒绝回退，用户卡在坏状态里。
    # 库清单从**包内入口**读，不在本文件里再写一份名单——加库改名都不用改这里。
    if [ "$_vplat" = "win" ]; then
        _vplat_dir=win; _vlib_ext=".ps1"; _ventry_name="envproxy.ps1"
        _vdecl=$(sed -n 's/.*\$CoreLibs[ ]*=[ ]*@(\([^)]*\)).*/\1/p' "$_vroot/$_ventry" 2>/dev/null | head -n 1 | tr -d '"')
    else
        _vplat_dir=mac; _vlib_ext=".sh"; _ventry_name="envproxy.sh"
        _vdecl=$(sed -n 's/^CORE_LIBS="\([^"]*\)".*/\1/p' "$_vroot/$_ventry" 2>/dev/null | head -n 1)
    fi
    [ -n "$_vdecl" ] || return 1
    for _vl in $_vdecl; do
        [ -f "$_vroot/$_vplat_dir/lib/$_vl$_vlib_ext" ] || return 1
    done
    while IFS= read -r _vf; do
        [ -n "$_vf" ] || continue
        _vr=${_vf#"$_vroot"/}
        case "$_vr" in
            # 本平台入口：必须恰好是它。
            "$_vplat_dir/$_ventry_name") ;;
            # lib/ 下的每个文件都必须出现在入口声明的库清单里——加库漏改入口、塞进清单外的
            # 库都要拦住（否则覆盖时"新包没有的按清单删"会把它们当旧版残留清掉）。
            "$_vplat_dir/lib/"*"$_vlib_ext")
                _vbase=$(basename "$_vr" "$_vlib_ext")
                case " $_vdecl " in *" $_vbase "*) ;; *) return 1 ;; esac ;;
            # 本平台目录**直属**的其余脚本：菜单壳、以及被复制到固定位置的模板
            # （定位器、shell 集成脚本）。这些不是库、不由入口加载，所以不进 CORE_LIBS。
            # 不逐个点名：点名意味着"新增一个模板要改两处校验"，漏掉 prompt-sync.sh 就是这么来的。
            # 但**只认直属**：写成 "$_vplat_dir/"*"$_vlib_ext" 会连 mac/payload/evil.sh
            # 这种任意深度的子目录脚本一起放行——那等于给投毒包开了一扇后门。
            # 判据是"路径里不含额外的 /"，不是靠通配符。
            "$_vplat_dir/"*"$_vlib_ext"|"$_vplat_dir/"*.command|"$_vplat_dir/"*.cmd)
                case "${_vr#"$_vplat_dir/"}" in */*) return 1 ;; esac ;;
            *) return 1 ;;
        esac
    done <<_VPKG_
$(find "$_vroot/$_vplat_dir" -type f 2>/dev/null)
_VPKG_
    _vlist=$(mktemp /tmp/envproxy_verify.XXXXXX 2>/dev/null) || return 1
    find "$_vroot" -type f \( -name '*.ps1' -o -name '*.sh' \) > "$_vlist" 2>/dev/null
    if [ ! -s "$_vlist" ]; then rm -f "$_vlist" 2>/dev/null || true; return 1; fi
    _vbad=0
    while IFS= read -r _vf; do
        [ -n "$_vf" ] || continue
        _vsize=$(wc -c < "$_vf" 2>/dev/null | tr -d ' \t')
        _vbom=$(head -c 3 "$_vf" 2>/dev/null | od -An -tx1 | tr -d ' \n')
        # "空"按去掉 BOM 之后的正文算：只剩 3 字节 BOM 的截断文件必须被拦下。
        if [ "$_vbom" = "efbbbf" ]; then _vsize=$((_vsize - 3)); fi
        if [ -z "$_vsize" ] || [ "$_vsize" -le 0 ]; then _vbad=1; break; fi
        case "$_vf" in
            *.ps1) [ "$_vbom" = "efbbbf" ] || { _vbad=1; break; } ;;
            *.sh)
                if [ "$_vbom" = "efbbbf" ]; then _vbad=1; break; fi
                # 按字节找 0d：不用 grep 匹配 CR——有些环境（msys 的 grep）按文本模式读文件，
                # 会把行尾的 CR 吃掉，检测静默失效。od 读的是真字节，哪里都一致。
                if od -An -v -tx1 "$_vf" 2>/dev/null | tr -s ' ' '\n' | grep -qx '0d'; then _vbad=1; break; fi
                ;;
        esac
    done < "$_vlist"
    rm -f "$_vlist" 2>/dev/null || true
    [ "$_vbad" = "0" ] || return 1
    return 0
}

# 包内根文件（VERSION/README/LICENSE…）：不写死名单，包里有谁算谁。
# 读调用方的 $_plist（备份前已生成，不含 backup/）。
_pkg_root_files() {
    grep -v '/' "$_plist" 2>/dev/null | grep -v '^$' || true
}

# 覆盖安装区。边界三条：作用域内包文件全部写入；win/monitor 与 mac/monitor 永不覆盖、永不删；
# 作用域内、新包没有的文件按清单删除（旧入口不会残留成"点了没反应"）。
# $4 是本次覆盖的作用域（默认本平台目录 + 共享）：分平台包只含自己平台，更新时绝不碰
# 另一平台的目录（不删、不加、不校验）。备份、删残留、回滚全走这一个变量，范围天然一致。
# 安装根目录只覆盖同名文件，绝不删任何东西——根目录可能有用户自己的东西。
# 参数 3 是本次更新的临时目录（放备份）。覆盖全走临时文件改名，运行中的旧脚本不受影响。
# 任何一步失败就逐文件回滚，并返回非零。
install_package() {
    _proot="$1"
    _pdest="$2"
    _pstage="${3:-}"
    _pship="${4:-mac release-notes assets}"
    # 目的地校验（第二道）：目标必须已经是一个安装根。调用方进门时已验过一次，
    # 这里是给"函数被别处直接调用"留的底线——后面的删除循环只认这个结论。
    if [ ! -f "$_pdest/mac/envproxy.sh" ] || [ ! -f "$_pdest/VERSION" ]; then
        echo "拒绝覆盖：目标不是 EnvProxy 安装目录，未做任何改动。"
        return 1
    fi
    # 生效作用域 = 调用方声明 ∩ 包内实际有的目录（与 Win 侧 Install-Package 同语义）：
    # 分包本来就没有另一平台目录，即使有人传了全量作用域，也绝不碰包外的东西。
    _peff=""
    # shellcheck disable=SC2086
    for _pd in $_pship; do
        [ -d "$_proot/$_pd" ] && _peff="$_peff $_pd"
    done
    # 上一次覆盖若在中途被杀可能留下临时文件；顺手清干净，不留垃圾。
    # shellcheck disable=SC2086
    for _pd in $_peff; do
        find "$_pdest/$_pd" -type f -name '*.envproxy-new.*' -delete 2>/dev/null || true
    done
    _plist=$(mktemp /tmp/envproxy_pkglist.XXXXXX 2>/dev/null) || { echo "更新失败：临时文件建不起，未做任何改动。"; return 1; }
    # 清单必须在备份之前生成：备份目录就在 $_pstage 里（真实调用处与 $_proot 是同一个目录），
    # 先生成清单会把 backup/** 当成"包内文件"一起拷进用户安装根（里面还带着上一版核心脚本）。
    _pok=1
    (cd "$_proot" && find . -type f 2>/dev/null | sed 's|^\./||') > "$_plist" 2>/dev/null || _pok=0
    if grep -q '^backup/' "$_plist" 2>/dev/null; then
        echo "更新失败：安装清单里混进了备份目录，已中止。"
        rm -f "$_plist" 2>/dev/null || true
        return 1
    fi
    if [ -n "$_pstage" ]; then
        _pbak="$_pstage/backup"
        rm -rf "$_pbak" 2>/dev/null || true
        mkdir -p "$_pbak" 2>/dev/null || true
        # shellcheck disable=SC2086
        for _pd in $_peff; do
            [ -d "$_pdest/$_pd" ] && cp -pR "$_pdest/$_pd" "$_pbak/$_pd" 2>/dev/null
            # monitor 不备份：日志与 pid 是活的运行时状态，回滚也不碰它们。
            rm -rf "$_pbak/$_pd/monitor" 2>/dev/null || true
        done
        # 根目录那几个随包文件也要备份：只备份程序目录的话，中途失败回滚后会留下
        # "版本号是新的、程序目录是旧的"——比不滚还难查。名单从包里取，不写死。
        _pkg_root_files | while IFS= read -r _pf; do
            [ -n "$_pf" ] || continue
            [ -f "$_pdest/$_pf" ] && cp -p "$_pdest/$_pf" "$_pbak/$_pf" 2>/dev/null
        done
    fi
    # shellcheck disable=SC2086
    for _pd in $_peff; do
        [ -d "$_pdest/$_pd" ] || continue
        find "$_pdest/$_pd" -type f 2>/dev/null | while IFS= read -r _pf; do
            _prel="${_pf#"$_pdest"/}"
            case "$_prel" in win/monitor/*|mac/monitor/*) continue;; esac
            [ -f "$_proot/$_prel" ] && continue
            if rm -f "$_pf" 2>/dev/null; then echo "  已移除旧版本残留：$_prel"; fi
        done
        find "$_pdest/$_pd" -mindepth 1 -type d 2>/dev/null | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2- | while IFS= read -r _pdir; do
            case "$_pdir" in */monitor|*/monitor/*) continue;; esac
            rmdir "$_pdir" 2>/dev/null || true
        done
    done
    _pcopy=1
    # 写两遍：除 VERSION 外先写完，最后单独写 VERSION——它若先变成新版本而程序文件没写完，
    # 更新入口会认为本地比线上新而拒绝再升级（与 Win 侧同顺序）。
    for _ppass in 1 2; do
    while IFS= read -r _prel; do
        [ -n "$_prel" ] || continue
        # 只写作用域内的文件：包外目录即使被显式传入也不碰（与备份/删除/回滚同范围）。
        case "$_prel" in
            */*) _ptop="${_prel%%/*}"
                 case " $_peff " in *" $_ptop "*) ;; *) continue;; esac ;;
        esac
        if [ "$_ppass" = "1" ]; then [ "$_prel" = "VERSION" ] && continue
        else [ "$_prel" = "VERSION" ] || continue; fi
        _ptarget="$_pdest/$_prel"
        mkdir -p "$(dirname "$_ptarget")" 2>/dev/null || { _pcopy=0; continue; }
        # 所有文件一律"写同目录临时文件再改名"：cp 直接截断重写不安全——
        # 其中一个文件可能正在被执行（bash 边读边执行），字符串比对认身份
        # 在大小写不敏感卷/软链下还会失配。不再设特例，一视同仁。
        # 临时文件用 mktemp 独占创建（不可预测，无残留可预置）；写完核对字节数再改名。
        _ptmp=$(mktemp "${_ptarget}.envproxy-new.XXXXXX" 2>/dev/null) || { _pcopy=0; continue; }
        if cp -p "$_proot/$_prel" "$_ptmp" 2>/dev/null; then
            _ws=$(wc -c < "$_proot/$_prel" 2>/dev/null | tr -d ' \t')
            _wt=$(wc -c < "$_ptmp" 2>/dev/null | tr -d ' \t')
            if [ -n "$_ws" ] && [ "$_ws" = "$_wt" ] && mv -f "$_ptmp" "$_ptarget" 2>/dev/null; then
                :
            else
                rm -f "$_ptmp" 2>/dev/null || true
                _pcopy=0
            fi
        else
            rm -f "$_ptmp" 2>/dev/null || true
            _pcopy=0
        fi
    done < "$_plist"
    done
    if [ "$_pok" != "1" ] || [ "$_pcopy" != "1" ]; then
        if [ -n "$_pstage" ] && [ -d "$_pstage/backup" ]; then
            # 回滚用"逐文件覆盖回去 + 删掉新增文件"，不用"删整个目录再搬回"：
            # 后者会被同一个被占用的文件挡住（更新失败的原因往往就是它），把安装区弄成半截。
            # shellcheck disable=SC2086
            for _pd in $_peff; do
                _pb="$_pstage/backup/$_pd"
                [ -d "$_pb" ] || continue
                mkdir -p "$_pdest/$_pd" 2>/dev/null || true
                (cd "$_pb" && find . -type f 2>/dev/null | sed 's|^\./||') | while IFS= read -r _r; do
                    _pt="$_pdest/$_pd/$_r"
                    mkdir -p "$(dirname "$_pt")" 2>/dev/null || true
                    cp -p "$_pb/$_r" "$_pt" 2>/dev/null || true
                done
                (cd "$_pdest/$_pd" && find . -type f 2>/dev/null | sed 's|^\./||') | while IFS= read -r _r; do
                    case "$_r" in monitor/*) continue;; esac
                    [ -f "$_pb/$_r" ] || rm -f "$_pdest/$_pd/$_r" 2>/dev/null || true
                done
            done
            _pkg_root_files | while IFS= read -r _pf; do
                [ -n "$_pf" ] || continue
                [ -f "$_pstage/backup/$_pf" ] && cp -p "$_pstage/backup/$_pf" "$_pdest/$_pf" 2>/dev/null
            done
            echo "更新失败：写入安装区失败，已回滚到更新前的状态。"
        else
            echo "更新失败：文件写入失败。请打开菜单选"安装 / 修复"后重试。"
        fi
        rm -f "$_plist" 2>/dev/null || true
        return 1
    fi
    rm -f "$_plist" 2>/dev/null || true
    return 0
}
