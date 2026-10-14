# ------------------------------------------------------------------------------
#  package.sh — 安装包层：覆盖安装区、备份与逐文件回滚
#  每个文件都写同目录临时文件再改名，不留半截文件。
# ------------------------------------------------------------------------------

# 校验安装包：包内 VERSION 与目标一致、两个平台的核心文件都在、两条编码红线没被改过。
verify_package() {
    _vroot="$1"
    _vwant="$2"
    _vver=$(tr -d ' \t\r\n' < "$_vroot/VERSION" 2>/dev/null || true)
    [ -n "$_vver" ] && [ "$_vver" = "$_vwant" ] || return 1
    # 结构校验，不点名具体文件：两个入口必须在，包内每一个脚本都要过编码红线。
    # 于是加库、改名、挪位置都不用改这里——与 CI 门禁 3 是同一条规则，两处不会漂移。
    [ -f "$_vroot/win/envproxy.ps1" ] && [ -f "$_vroot/mac/envproxy.sh" ] || return 1
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

# 覆盖安装区。边界三条：包内文件全部写入；win/monitor 与 mac/monitor 永不覆盖、永不删；
# 四个程序目录内、新包没有的文件按清单删除（旧按钮不会残留成"点了没反应"）。
# 安装根目录只覆盖同名文件，绝不删任何东西——根目录可能有用户自己的东西。
# 参数 3 是本次更新的临时目录（放备份）。覆盖全走临时文件改名，运行中的旧脚本不受影响。
# 任何一步失败就逐文件回滚，并返回非零。
install_package() {
    _proot="$1"
    _pdest="$2"
    _pstage="${3:-}"
    # 目的地校验（第二道）：目标必须已经是一个安装根。调用方进门时已验过一次，
    # 这里是给"函数被别处直接调用"留的底线——后面的删除循环只认这个结论。
    if [ ! -f "$_pdest/mac/envproxy.sh" ] || [ ! -f "$_pdest/VERSION" ]; then
        echo "拒绝覆盖：目标不是 EnvProxy 安装目录，未做任何改动。"
        return 1
    fi
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
        for _pd in win mac release-notes assets; do
            [ -d "$_pdest/$_pd" ] && cp -pR "$_pdest/$_pd" "$_pbak/$_pd" 2>/dev/null
        done
        # 根目录那几个随包文件也要备份：只备份程序目录的话，中途失败回滚后会留下
        # "版本号是新的、程序目录是旧的"——比不滚还难查。
        for _pf in VERSION README.md README.en.md LICENSE; do
            [ -f "$_pdest/$_pf" ] && cp -p "$_pdest/$_pf" "$_pbak/$_pf" 2>/dev/null
        done
    fi
    for _pd in win mac release-notes assets; do
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
    while IFS= read -r _prel; do
        [ -n "$_prel" ] || continue
        _ptarget="$_pdest/$_prel"
        mkdir -p "$(dirname "$_ptarget")" 2>/dev/null || { _pcopy=0; continue; }
        # 所有文件一律"写同目录临时文件再改名"：cp 直接截断重写不安全——
        # 其中一个文件可能正在被执行（bash 边读边执行），字符串比对认身份
        # 在大小写不敏感卷/软链下还会失配。不再设特例，一视同仁。
        _ptmp="$_ptarget.envproxy-new.$$"
        if cp -p "$_proot/$_prel" "$_ptmp" 2>/dev/null && mv -f "$_ptmp" "$_ptarget" 2>/dev/null; then
            :
        else
            rm -f "$_ptmp" 2>/dev/null || true
            _pcopy=0
        fi
    done < "$_plist"
    if [ "$_pok" != "1" ] || [ "$_pcopy" != "1" ]; then
        if [ -n "$_pstage" ] && [ -d "$_pstage/backup" ]; then
            # 回滚用"逐文件覆盖回去 + 删掉新增文件"，不用"删整个目录再搬回"：
            # 后者会被同一个被占用的文件挡住（更新失败的原因往往就是它），把安装区弄成半截。
            for _pd in win mac release-notes assets; do
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
            for _pf in VERSION README.md README.en.md LICENSE; do
                [ -f "$_pstage/backup/$_pf" ] && cp -p "$_pstage/backup/$_pf" "$_pdest/$_pf" 2>/dev/null
            done
            echo "更新失败：写入安装区失败，已回滚到更新前的状态。"
        else
            echo "更新失败：文件写入失败。请点一次 1-安装 修复后重试。"
        fi
        rm -f "$_plist" 2>/dev/null || true
        return 1
    fi
    rm -f "$_plist" 2>/dev/null || true
    return 0
}
