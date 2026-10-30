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
            # 判据是"脚本类文件"这个**类别**，不是本平台的库扩展名：曾经只认 .sh（mac 当平台时）
            # 与 .command/.cmd，于是 win 当平台时（_vlib_ext=.ps1）win/prompt-sync.sh 不在名单里，
            # 每一份更新包都会被自己的校验器拒收。现在两个平台的全部脚本类型都认，
            # 任一侧新增模板都不必再改这里。
            # 但**只认直属**：任意深度的子目录脚本照样拒（下面那行判路径里有没有额外的 /），
            # 否则等于给投毒包开了一扇后门。
            "$_vplat_dir/"*.ps1|"$_vplat_dir/"*.sh|"$_vplat_dir/"*.command|"$_vplat_dir/"*.cmd)
                case "${_vr#"$_vplat_dir/"}" in */*) return 1 ;; esac ;;
            *) return 1 ;;
        esac
    done <<_VPKG_
$(find "$_vroot/$_vplat_dir" -type f 2>/dev/null)
_VPKG_
    _vlist=$(mktemp "${TMPDIR:-/tmp}/envproxy_verify.XXXXXX" 2>/dev/null) || return 1
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

    # 最后一道准入：**新代码能不能跑**。
    #
    # 前面查的全是"形状"——文件齐不齐、库清单对不对、VERSION 一致不一致、行尾对不对。
    # 一个语法上跑不起来的包（少一个 fi、多一个引号）能完美通过全部形状校验，然后被装上去。
    # 而装坏之后没有退路：覆盖成功 → 收尾用新入口跑 install → 新入口自己解析就失败 →
    # 提示"请打开菜单选一次安装 / 修复"——那句话此时是死路，菜单也是同一个入口。
    # 同时旧监控已被停掉、开机自启指向这个跑不起来的入口。
    #
    # 用 `bash -n`（与 CI 门禁 1 同一手段），放在**覆盖之前**。代价几十毫秒，收益是消除这条死路。
    if [ "$_vplat" = "mac" ] && [ -f "$_vroot/mac/envproxy.sh" ]; then
        for _vf_syn in "$_vroot/mac/envproxy.sh" "$_vroot"/mac/lib/*.sh "$_vroot"/mac/*.sh; do
            [ -f "$_vf_syn" ] || continue
            if ! /bin/bash -n "$_vf_syn" 2>/dev/null; then
                echo "校验失败（$(basename "$_vf_syn") 有语法错误），未做任何改动。这一版装上去会跑不起来，所以拒收。" >&2
                return 1
            fi
        done
    fi
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
    # 回滚未完成时留下的备份路径（空 = 没有 / 不需要）。
    # 必须**先初始化**：本脚本跑在 set -u 下，回滚成功那条路不会赋值它，
    # 调用方再去读就会 "unbound variable" 把整个更新流程打断在收尾之前。
    INSTALL_PARTIAL_BACKUP=""
    # 目的地校验（第二道）：目标必须已经是一个安装根。调用方进门时已验过一次，
    # 这里是给"函数被别处直接调用"留的底线——后面的删除循环只认这个结论。
    if [ ! -f "$_pdest/mac/envproxy.sh" ] || [ ! -f "$_pdest/VERSION" ]; then
        echo "拒绝覆盖：目标不是 EnvProxy 安装目录，未做任何改动。"
        return 1
    fi
    # C9: 覆盖进行中的落盘标记。
    #
    # 文件是逐个替换的，整个窗口有几秒。若这几秒里断电、蓝屏、被强制关机，
    # 安装区就会新旧混在一起。因为 VERSION 最后写，`get_local_version` 仍报旧版本、
    # 入口通常还起得来——于是启动自检全绿，运行时表现为某个函数"找不到"
    # 或行为与常量不一致，而这类错误会被大量容错吞成"这一轮不知道"，
    # 表现为功能部分可用、部分静默失效。没有任何自检会发现"这份安装是半新半旧的"。
    #
    # 所以覆盖前写标记、成功后删掉；状态页发现它就报出来。
    # 与 stopped.intent 同一个手法：用落盘意图区分两类事后长相相同的情况。
    _pmark="$_pdest/mac/monitor/update.inprogress"

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
    _plist=$(mktemp "${TMPDIR:-/tmp}/envproxy_pkglist.XXXXXX" 2>/dev/null) || { echo "更新失败：临时文件建不起，未做任何改动。"; return 1; }
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
        # 备份失败必须**中止**，不能继续覆盖。
        #
        # 原因在回滚那一侧：回滚的判据是"备份里没有的文件就删掉"（第 253 行）——
        # 因为覆盖会删掉新包里没有的旧文件，回滚就要把它们还原回来，
        # 而"备份里没有"被当成了"本来就不该有"。
        # 一旦备份本身是部分的，这两条合起来就变成：**没备份成功的文件，回滚时被删掉**。
        # 实测复现过：备份只成功 1 个文件时，回滚删掉另外 2 个，安装区只剩 1 个文件。
        # 也就是说"更新失败"从一个可恢复的状态变成了丢文件。
        #
        # 备份完整性只有这里能保证——回滚后的复读查的是"备份清单里的文件是否都还原了"，
        # 它按定义查不出"清单本身就缺项"（缺的那项不在清单里，也就没有比对对象）。
        _pbak_bad=0
        # shellcheck disable=SC2086
        for _pd in $_peff; do
            [ -d "$_pdest/$_pd" ] || continue
            if ! cp -pR "$_pdest/$_pd" "$_pbak/$_pd" 2>/dev/null; then _pbak_bad=1; fi
            # monitor 不备份：日志与 pid 是活的运行时状态，回滚也不碰它们。
            rm -rf "$_pbak/$_pd/monitor" 2>/dev/null || true
        done
        # 根目录那几个随包文件也要备份：只备份程序目录的话，中途失败回滚后会留下
        # "版本号是新的、程序目录是旧的"——比不滚还难查。名单从包里取，不写死。
        # 这里用重定向而不是管道：管道右边跑在子 shell 里，_pbak_bad 的赋值出不来。
        _pkg_root_files > "$_pstage/root-files.list" 2>/dev/null || true
        while IFS= read -r _pf; do
            [ -n "$_pf" ] || continue
            [ -f "$_pdest/$_pf" ] || continue
            if ! cp -p "$_pdest/$_pf" "$_pbak/$_pf" 2>/dev/null; then _pbak_bad=1; fi
        done < "$_pstage/root-files.list"
        rm -f "$_pstage/root-files.list" 2>/dev/null || true
        if [ "$_pbak_bad" = "1" ] || [ ! -d "$_pbak" ]; then
            echo "拒绝更新：覆盖前的备份没有完整做成（磁盘满、权限不足或被安全软件挡住）。" >&2
            echo "  没有完整备份就没有可靠回滚，所以现在一个文件都没改。" >&2
            echo "  请腾出磁盘空间或检查安装目录权限后重试。" >&2
            return 1
        fi
    fi

    # 标记落在这里而不是函数开头：它的语义是「我正在改安装区」。
    # 前面任何一步中止（最典型是备份没做成）时一个文件都还没改，
    # 此刻留下标记只会让状态页永久报「上次更新没完成」——
    # 而用户照屏幕重做一次、覆盖又成功，标记却仍然在，成了死循环。
    #
    # 先建目录再写：monitor/ 在全新安装里还不存在，先写必然失败，
    # 而这个失败被 2>/dev/null 吞掉——标记压根落不了盘，于是最需要它的
    # 那一次（第一次更新）保护失效。顺序必须反过来。
    mkdir -p "$(dirname "$_pmark")" 2>/dev/null || true
    printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$_pmark" 2>/dev/null || true
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
            # 回滚也要复读：上面的复制全部带 `|| true`，不回读就敢说"已回滚"是假话。
            # Windows 侧 package.ps1 早写过这条教训（入口被占用时 VERSION 会先变新、
            # 旧入口留在原地，更新入口于是认为本地比线上新，用户再也收不到新版）。
            # 逐字节比一遍，有不一致就改口径为"回滚未完成"，别让用户以为已经好了。
            _pbad="$_pstage/rollback-未还原清单.$$"
            : > "$_pbad" 2>/dev/null || _pbad="${TMPDIR:-/tmp}/envproxy-rollback-未还原清单.$$"
            for _pd in $_peff; do
                _pb="$_pstage/backup/$_pd"
                [ -d "$_pb" ] || continue
                (cd "$_pb" && find . -type f 2>/dev/null | sed 's|^\./||') | while IFS= read -r _r; do
                    [ -f "$_pdest/$_pd/$_r" ] || { printf '%s\n' "$_pd/$_r" >> "$_pbad"; continue; }
                    cmp -s "$_pb/$_r" "$_pdest/$_pd/$_r" 2>/dev/null || printf '%s\n' "$_pd/$_r" >> "$_pbad"
                done
            done
            _pkg_root_files | while IFS= read -r _pf; do
                [ -n "$_pf" ] || continue
                [ -f "$_pstage/backup/$_pf" ] || continue
                [ -f "$_pdest/$_pf" ] || { printf '%s\n' "$_pf" >> "$_pbad"; continue; }
                cmp -s "$_pstage/backup/$_pf" "$_pdest/$_pf" 2>/dev/null || printf '%s\n' "$_pf" >> "$_pbad"
            done
            if [ -s "$_pbad" ]; then
                echo "更新失败：写入安装区失败，且回滚未完成——以下文件没能还原："
                sed 's/^/    /' "$_pbad"
                # 回滚没做成时，备份是唯一的回退抓手，而它正躺在 $_pstage/backup 里，
                # 调用方（update.sh 的 finally）接下来会把整个 $_pstage 删掉。
                # 所以搬到安装根旁的具名目录，并把路径交出去（调用方据此提示用户去哪找）。
                _pkeep="$(dirname "$_pdest")/envproxy-backup-partial"
                if [ -d "$_pstage/backup" ]; then
                    rm -rf "$_pkeep" 2>/dev/null || true
                    if cp -R "$_pstage/backup" "$_pkeep" 2>/dev/null; then
                        INSTALL_PARTIAL_BACKUP="$_pkeep"
                        echo "覆盖前的文件已保留到：$_pkeep"
                        echo "把它里面的文件拷回安装目录，即可回到更新前的状态。"
                    else
                        INSTALL_PARTIAL_BACKUP=""
                        echo "备份也没能保留下来：请到 Releases 页面重新下载安装包覆盖一次。"
                    fi
                fi
                echo "请到 Releases 页面重新下载安装包，解压后覆盖这个文件夹（或在菜单里选 安装 / 修复）。"
                # 标记**故意不删**：安装区确实还是半新半旧，这条警报是真的。
                # 它将在下一次成功的「安装 / 修复」收尾时被清掉（见 ops.sh 收尾那一步）。
                rm -f "$_pbad" 2>/dev/null || true
            else
                echo "更新失败：写入安装区失败，已回滚到更新前的状态。"
                # 回滚完整成功 = 安装区已回到更新前，标记不能再留（留着就是假警报）。
                rm -f "$_pmark" 2>/dev/null || true
            fi
        else
            echo "更新失败：文件写入失败。请打开菜单选「安装 / 修复」后重试。"
        fi
        rm -f "$_plist" 2>/dev/null || true
        return 1
    fi
    rm -f "$_plist" 2>/dev/null || true
    # 覆盖全部成功：撤掉"更新进行中"标记（留着会让状态页一直报假警报）。
    rm -f "$_pmark" 2>/dev/null || true
    return 0
}
