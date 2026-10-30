# ==============================================================================
#  package.ps1 — 安装包层：覆盖安装区、备份与逐文件回滚
#  覆盖前必校验目的地；任何一步失败回滚到更新前，安装区不留半截。
# ==============================================================================

# 校验安装包：包内 VERSION 与目标一致、本平台的核心文件在、两条编码红线没被改过。
# $Platform 决定认哪个入口（分平台包只含自己平台，另一端的不认也不拦）。
# 任何一项不过就抛异常，调用方据此中止——安装区一个字节都不动。
function Test-Package([string]$Root, [string]$WantVersion, [string]$Platform = "win") {
    $srcVer = ""
    try { $srcVer = ((Read-Text (Join-Path $Root "VERSION")).Trim()) } catch {}
    if (-not $srcVer -or ($srcVer -ne $WantVersion)) { throw "校验失败（包内 VERSION 与目标版本不一致），未做任何改动。" }
    # 结构校验，不点名具体文件：本平台入口必须在，包内每一个脚本都要过编码红线。
    # 于是加库、改名、挪位置都不用改这里——与 CI 门禁 3 是同一条规则，两处不会漂移。
    $wantEntry = if ($Platform -eq "mac") { "mac\envproxy.sh" } else { "win\envproxy.ps1" }
    if (-not (Test-Item (Join-Path $Root $wantEntry))) { throw ("校验失败（安装包缺少 {0}），未做任何改动。" -f $wantEntry) }
    # 菜单壳也必须在：它是使用者唯一能双击的东西，缺了等于装完没法打开。
    $wantShell = if ($Platform -eq "mac") { "mac\打开菜单.command" } else { "win\打开菜单.cmd" }
    if (-not (Test-Item (Join-Path $Root $wantShell))) { throw ("校验失败（安装包缺少 {0}），未做任何改动。" -f $wantShell) }
    # 内容集校验：本平台目录里只能有"入口 + 菜单壳 + 根下模板 + 入口自己声明的每个库"，
    # 缺一个或多一个都拒收。只查"入口在不在"是不够的——一个只剩 VERSION + 入口的包能过那一关，
    # 而覆盖时"作用域内、新包没有的文件按清单删除"会把所有库当成旧版残留删掉：
    # 安装区被清空、VERSION 却被抬高，之后更新入口还会拒绝回退，用户卡在坏状态里。
    # 声明的库清单从**包内入口**读（而不是在本文件里再写一份名单），加库改名都不用改这里。
    $platDir = if ($Platform -eq "mac") { "mac" } else { "win" }
    $entryName = Split-Path -Leaf $wantEntry
    $libExt = if ($Platform -eq "mac") { ".sh" } else { ".ps1" }
    $declPattern = if ($Platform -eq "mac") { 'CORE_LIBS="([^"]*)"' } else { '\$CoreLibs\s*=\s*@\(([^)]*)\)' }
    $decl = [regex]::Match((Read-Text (Join-Path $Root $wantEntry)), $declPattern)
    if (-not $decl.Success) { throw "校验失败（包内入口没有声明库清单），未做任何改动。" }
    $declared = @()
    foreach ($m in [regex]::Matches($decl.Groups[1].Value, '"([^"]+)"')) { $declared += $m.Groups[1].Value }
    if (-not $declared.Count) { $declared = @($decl.Groups[1].Value -split '\s+' | Where-Object { $_ }) }
    if (-not $declared.Count) { throw "校验失败（包内入口声明的库清单是空的），未做任何改动。" }
    $allowed = @()
    $allowed += "$platDir/$entryName"
    foreach ($l in $declared) { $allowed += "$platDir/lib/$l$libExt" }
    # 根下（lib/ 之外）**直属**的脚本一律放行：菜单壳，以及被复制到固定位置的模板
    # （定位器、shell 集成脚本）。它们不是库、不由入口加载，所以不进库清单，但是合法包内容。
    #
    # 允许的扩展名**按平台分开**，而且只收本平台在用的那几种。
    #
    # 这条规则的真正约束不是"本程序支持哪些脚本"，而是**最老的那个客户端接受什么**：
    # 老用户点「检查更新」时，跑的是他手里那版代码的校验器。新校验器一旦比它宽松，
    # 就会出现"新版能收、老版拒收"——而修复只在新版里，新版又正是被拒的那一个，自锁。
    # 已发布旧版的校验器放行集合：win 是 .ps1/.command/.cmd，mac 是 .sh/.command/.cmd。
    # 所以这里取同样的集合，保证"能过新版 ⇒ 一定也能过老版"。
    # （win 侧曾经内嵌过 prompt-sync.sh，正是踩了老版不认 .sh 这个坑；现在它内嵌在代码里，
    #  包里不再有这个文件，但规则仍按上面的兼容性原则划。）
    # 仍然必须判"直属"（见下面的 extra 判定）：任意深度的子目录脚本照样拒，
    # 否则等于给投毒包开了一扇后门。
    $scriptExts = if ($Platform -eq "mac") { @(".sh", ".cmd", ".command") } else { @(".ps1", ".cmd", ".command") }
    # 相对路径要么按传入的 Root 剥、要么按它的长名剥：Windows 上同一个目录可能以 8.3 短名
    # （FIRETR~1）出现，而 Get-ChildItem 回的是长名——只按一种剥会算出空名单，
    # 于是"包内缺少所有文件"，把好包也拒了。
    $rootTrim = $Root.TrimEnd('\', '/')
    $rootFull = $rootTrim
    try { $rootFull = (Get-Item -LiteralPath $Root).FullName.TrimEnd('\', '/') } catch {}
    $actual = @(Get-ChildItem -LiteralPath (Join-Path $Root $platDir) -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            $p = $_.FullName
            if ($p.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { $p.Substring($rootFull.Length) }
            else { $p.Substring([Math]::Min($rootTrim.Length, $p.Length)) }
        } | ForEach-Object { $_.TrimStart('\', '/').Replace('\', '/') })
    $missing = @($allowed | Where-Object { $actual -notcontains $_ })
    # 多出来的文件：lib/ 下的一律拒（清单外的库覆盖时会被当残留删掉）；
    # 平台目录**直属**的脚本放行（菜单壳与各种模板，见 $scriptExts 的说明）；其余一律拒。
    # 必须判"直属"：只比扩展名会连 payload\evil.ps1 这种任意深度的子目录脚本一起放行，
    # 那等于给投毒包开了一扇后门。
    $extra = @($actual | Where-Object {
        if ($allowed -contains $_) { return $false }
        if ($_ -like "$platDir/lib/*") { return $true }
        $rel = $_ -replace ("^" + [regex]::Escape($platDir) + "/"), ""
        if ($rel -like "*/*") { return $true }
        $ext = [System.IO.Path]::GetExtension($_)
        return -not ($scriptExts -contains $ext)
    })
    if ($missing.Count) { throw ("校验失败（安装包缺少 {0}），未做任何改动。" -f ($missing -join ', ')) }
    if ($extra.Count) { throw ("校验失败（安装包里有清单外的文件：{0}），未做任何改动。" -f ($extra -join ', ')) }
    $scripts = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.sh' })
    foreach ($f in $scripts) {
        $b = [System.IO.File]::ReadAllBytes($f.FullName)
        $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
        # "空"按去掉 BOM 之后的正文算：只剩 3 字节 BOM 的截断文件必须被拦下。
        $bodyLen = $b.Length
        if ($hasBom) { $bodyLen = $bodyLen - 3 }
        if ($bodyLen -le 0) { throw ("校验失败（{0} 是空文件），未做任何改动。" -f $f.Name) }
        if ($f.Extension -eq '.ps1') {
            if (-not $hasBom) { throw ("校验失败（{0} 缺少 UTF-8 BOM），未做任何改动。" -f $f.Name) }
        } else {
            if ($hasBom) { throw ("校验失败（{0} 带了 BOM），未做任何改动。" -f $f.Name) }
            if ([System.Text.Encoding]::UTF8.GetString($b).Contains("`r`n")) { throw ("校验失败（{0} 含 CRLF），未做任何改动。" -f $f.Name) }
        }
    }

    # 最后一道准入：**新代码能不能跑**。
    #
    # 前面查的全是"形状"——文件齐不齐、库清单对不对、VERSION 一致不一致、BOM 与行尾对不对。
    # 一个语法上跑不起来的包（少一个右花括号、多一个引号、引用了不存在的函数）能完美通过
    # 全部形状校验，然后被装上去。而装坏之后没有退路：
    #   覆盖成功 → 收尾用新入口跑 -Install → 新入口自己在解析预检里退出 1 →
    #   提示"请打开菜单选一次安装 / 修复"——那句话此时是死路，菜单也是同一个入口、同样解析不过。
    #   同时旧监控已被停掉、开机自启指向这个跑不起来的入口。
    #   机器进入"程序坏了、装不回、开机也不自启"的状态，唯一出路是手动去 Releases 重下。
    #
    # 所以把"能跑"纳入准入，且放在**覆盖之前**。成本是几十毫秒的解析，
    # 收益是彻底消除上面那条死路。用与入口完全相同的 Parser::ParseFile——
    # 判据只有一处，改一侧不会让准入与启动检查错位。
    $scripts = @()
    foreach ($l in $declared) { $scripts += (Join-Path $Root ("{0}/lib/{1}{2}" -f $platDir, $l, $libExt)) }
    $scripts += (Join-Path $Root $wantEntry)
    foreach ($sp in $scripts) {
        $ptok = $null; $perr = $null
        try {
            [void][System.Management.Automation.Language.Parser]::ParseFile($sp, [ref]$ptok, [ref]$perr)
        } catch {
            throw ("校验失败（{0} 读不出来），未做任何改动。" -f (Split-Path -Leaf $sp))
        }
        if ($perr -and $perr.Count) {
            throw ("校验失败（{0} 有语法错误：{1}），未做任何改动。这一版装上去会跑不起来，所以拒收。" -f (Split-Path -Leaf $sp), $perr[0].Message)
        }
    }

}

function Copy-FileAtomic([string]$Src, [string]$Dest) {
    # 每个文件都走"同目录临时文件 + 整体替换"，与 macOS 侧同一语义。
    # 不用 Copy-Item：它先截断再写，中途断电或被杀就留下半截文件——程序拆成多文件后，
    # 任何一个文件半截都等于整个程序起不来。字节直拷顺带保住包内文件的 BOM 与行尾，
    # 不需要再按文件类型分特例。
    $dir = Split-Path -Parent $Dest
    if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [System.IO.Directory]::CreateDirectory($dir) | Out-Null }
    $tmp = "$Dest.envproxy-new$PID"
    try {
        $wantLen = (Get-Item -LiteralPath $Src).Length
        [System.IO.File]::Copy($Src, $tmp, $true)
        # 写完核对字节数：磁盘满或中途被杀会留下截断文件，而"非空"检查分辨不出 1 字节和完整文件。
        if ((Get-Item -LiteralPath $tmp).Length -ne $wantLen) { throw ("写入不完整（{0}：源 {1} 字节，已写 {2} 字节）" -f $Dest, $wantLen, (Get-Item -LiteralPath $tmp).Length) }
        if ([System.IO.File]::Exists($Dest)) {
            # 第三参数必须是 [NullString]::Value：传 $null 绑成空字符串会抛异常，
            # 于是每次都悄悄退化成非原子的 Copy+Delete（见 base.ps1 同一处注释）。
            try { [System.IO.File]::Replace($tmp, $Dest, [NullString]::Value) }
            catch { [System.IO.File]::Copy($tmp, $Dest, $true); [System.IO.File]::Delete($tmp) }
        } else {
            [System.IO.File]::Move($tmp, $Dest)
        }
    } catch {
        try { if ([System.IO.File]::Exists($tmp)) { [System.IO.File]::Delete($tmp) } } catch {}
        throw
    }
}

# 覆盖安装区。边界三条：作用域内包文件全部写入；win\monitor 与 mac\monitor 永不覆盖、永不删；
# 作用域内、新包没有的文件按清单删除（旧入口不会残留成"点了没反应"）。作用域外的目录碰都不碰。
# 安装根目录只覆盖同名文件，绝不删任何东西——根目录可能有用户自己的东西。
function Install-Package([string]$SrcRoot, [string]$ProjectRoot, [string]$Stage, [string[]]$ShipDirs = @("win", "mac", "release-notes", "assets")) {
    # $Stage 必填：没有它就没有备份，也就没有回滚——不留"可以无回滚地覆盖安装区"的口子。
    if (-not $Stage) { throw "内部错误：覆盖安装区必须提供备份目录（-Stage）。" }
    # $ShipDirs 是本次覆盖的作用域：分平台包只含自己平台目录，更新时绝不碰另一平台的目录
    # （不删、不加、不校验——那是另一端的地盘）。备份、删残留、回滚、复读全走这一个变量，
    # 范围天然一致。调用方不传即全量（旧行为）。
    # 路径形态归一：参数可能是 8.3 短名（例如从 %TEMP% 拼出来的临时目录，或短名形态的启动路径），
    # 而 Get-ChildItem 枚举子项返回的是长名——两种写法长度不同，"减掉根前缀"算出来的相对路径
    # 就会整体错位：那会误删不该删的文件（连 monitor 日志一起）并把新文件写到错位置。
    # 先各自解析成长名，后面所有相对路径计算才对得上。
    $SrcRoot = (Get-Item -LiteralPath $SrcRoot -ErrorAction SilentlyContinue).FullName
    $ProjectRoot = (Get-Item -LiteralPath $ProjectRoot -ErrorAction SilentlyContinue).FullName
    # $Stage 允许还不存在（调用方只给一个临时目录名）：先建出来再解析，保持原有的容忍度。
    if ($Stage -and -not (Test-Item $Stage)) { New-Item -Path $Stage -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
    $Stage = (Get-Item -LiteralPath $Stage -ErrorAction SilentlyContinue).FullName
    if (-not $SrcRoot -or -not $ProjectRoot -or -not $Stage) { throw "更新中止：安装包目录或安装目录不可访问，未做任何改动。" }
    # 目的地校验：目标必须已经是一个安装根（有 VERSION 与核心脚本），否则一律拒绝。
    # 根目录是从"脚本所在目录的父目录"推出来的；脚本一旦不在 <根>\win\ 布局里，
    # 推导出的"安装根"就是错的，后面的删除循环会删掉用户自己的文件。这道闸让那种情况到此为止。
    if (-not (Test-Item (Join-Path $ProjectRoot "VERSION"))) { throw "这里不是 EnvProxy 安装目录（缺少 VERSION），未做任何改动。请从安装包的 win\ 目录里运行，或手动下载安装包覆盖。" }
    if (-not (Test-Item (Join-Path $ProjectRoot "win\envproxy.ps1"))) { throw "这里不是 EnvProxy 安装目录（缺少 win\envproxy.ps1），未做任何改动。请从安装包的 win\ 目录里运行，或手动下载安装包覆盖。" }

    # C9: 覆盖进行中的落盘标记。
    #
    # 文件是逐个替换的，整个窗口有几秒。若这几秒里断电、蓝屏、被强制关机，
    # 或用户在任务管理器里结束进程，安装区里就会新旧混在一起。
    # 因为 VERSION 最后写，`Get-LocalVersion` 仍报旧版本，入口通常还能起来——
    # 于是**启动自检全绿**，运行时表现为某个函数"找不到"或行为与常量不一致
    # （新入口配旧 probe，端口表或阈值就对不上），而这类错误会被大量 try/catch
    # 吞成"这一轮不知道"，表现为功能部分可用、部分静默失效。
    # 没有任何自检会发现"这份安装是半新半旧的"。
    #
    # 所以覆盖前写一个标记、成功后删掉。入口发现它就在状态页报出来。
    # 与 stopped.intent 是同一个手法：用落盘意图区分两类事后长相相同的情况。
    #
    # 这两项是"这次覆盖走到哪一步"的结论，供调用方决定该说什么话、该不该保住备份。
    # 三态，含义不同，绝不许混用：
    #   untouched = 覆盖一个文件都没动（备份阶段就失败了）→ 可以说"未做任何改动"
    #   complete  = 覆盖动过、失败后回滚完全成功      → 可以说"已恢复原状"
    #   partial   = 覆盖动过、回滚没做成                → 必须说"半新半旧"并保住备份
    # 初值是 untouched：备份阶段在 try 之外，那里失败时下面的 catch 根本不会跑，
    # 留着初值才是对的——那时安装区确实一个字节都没变。
    $script:LastInstallRollback = 'untouched'
    $script:LastInstallRollbackBackup = ''
    $marker = Join-Path $ProjectRoot ("{0}\monitor\update.inprogress" -f $(if ($ShipDirs -contains "win") { "win" } else { "mac" }))
    # 标记**不在这里写**——要等备份做完、真要动手覆盖的那一刻才写。
    #
    # 原来写在这（备份之前），于是有三条路会把它留在盘上而没有任何人去清：
    #   ① 备份失败（Copy-Item -ErrorAction Stop，在 try 之外）→ 直接上抛，标记没人删；
    #   ② 回滚未完成 → 下面 throw 抢在"回滚成功才清标记"那一行之前；
    #   ③ 连 $Stage 都没传、备份压根没建 → 同上。
    # 留下的后果不是"多一个文件"：状态页读到它就永久报"上次更新没完成，选 1 重做一次"
    # （ops.ps1 的 UpdateInProgress 判断），而"重做一次"走的还是这条路，照样清不掉——
    # 用户唯一出路是卸载。备份做完再写，① ③ 就不再有标记；② 由 partial 分支自己负责清。
    #
    # 覆盖前后各做一件事，都是为了让"更新到一半失败"不留残局：
    #   覆盖前——把四个程序目录 + 根目录那几个随包文件备份到本次更新的临时目录；
    #   覆盖中——任何一步失败就整体回滚到备份（安装区回到更新前），然后把异常抛给调用方。
    # 本函数内所有路径读写一律走字面量语义（-LiteralPath / 第 0.5 节 helper），
    # 安装文件夹改名带上 [ ] 也不影响。
    $pkg = @{}
    foreach ($f in (Get-ChildItem -LiteralPath $SrcRoot -Recurse -File -Force -ErrorAction Stop)) {
        $rel = $f.FullName.Substring($SrcRoot.Length).TrimStart('\')
        # Stage 复用 SrcRoot 时，备份目录就在包目录里：枚举必须跳过它，否则备份会被当成包内文件。
        if ($rel -like 'backup\*') { continue }
        $pkg[$rel.ToLower()] = $rel
    }
    # 生效作用域 = 调用方声明 ∩ 包内实际有的目录：分包本来就没有另一平台目录，
    # 即使有人传了全量作用域，也绝不碰包外的东西。备份、删残留、写入、回滚、复读全走它。
    $effShip = @($ShipDirs | Where-Object { Test-Path -LiteralPath (Join-Path $SrcRoot $_) })
    $backup = $null
    if ($Stage) {
        $backup = Join-Path $Stage "backup"
        Remove-ItemSafe (Join-Path $Stage "backup")
        New-Item -Path $backup -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        foreach ($d in $effShip) {
            $src = Join-Path $ProjectRoot $d
            if (Test-Item $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $backup $d) -Recurse -Force -ErrorAction Stop }
            # monitor 不备份：日志与 pid 是活的运行时状态，回滚也不碰它们（删残留与回滚各有自己的跳过）。
            Remove-Item -LiteralPath (Join-Path $backup (Join-Path $d "monitor")) -Recurse -Force -ErrorAction SilentlyContinue
        }
        # 根目录那几个随包文件（VERSION / README / LICENSE）也要备份：只备份程序目录的话，
        # 中途失败回滚后会留下"版本号是新的、程序目录是旧的"——比不滚还难查。
        foreach ($rel in $pkg.Values) {
            if ($rel -match '\\') { continue }
            $src = Join-Path $ProjectRoot $rel
            if (Test-Item $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $backup $rel) -Force -ErrorAction Stop }
        }
        # 备份齐了、马上要动安装区了——这时候才写"更新进行中"。
        # 此刻起任何中断都会留下新旧混合的安装区，标记正是给那种情况用的；
        # 而在此之前失败（上面的备份）安装区一个字节都没动，不该留下这个标记。
        try {
            $mdir = Split-Path -Parent $marker
            if (-not (Test-Item $mdir)) { New-Item -Path $mdir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
            Write-Text -Path $marker -Text ((Get-Date).ToString("o", [System.Globalization.CultureInfo]::InvariantCulture))
        } catch {}
    }
    try {
        $removed = 0
        foreach ($d in $effShip) {
            $destDir = Join-Path $ProjectRoot $d
            if (-not (Test-Item $destDir)) { continue }
            foreach ($f in (Get-ChildItem -LiteralPath $destDir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                # 越界保护：枚举结果必须确定位于本次目标之下，否则跳过（通配符曾让这里指向过别的目录）。
                if (-not $f.FullName.StartsWith($destDir, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                $rel = $f.FullName.Substring($ProjectRoot.Length).TrimStart('\')
                if ($rel -match '^(win|mac)\\monitor\\') { continue }
                if (-not $pkg.ContainsKey($rel.ToLower())) {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                    Write-Styled 'dim' ("  已移除旧版本残留：{0}" -f $rel)
                    $removed++
                }
            }
            Get-ChildItem -LiteralPath $destDir -Recurse -Directory -Force -ErrorAction SilentlyContinue |
                Sort-Object { $_.FullName.Length } -Descending |
                ForEach-Object {
                    if (-not $_.FullName.StartsWith($destDir, [System.StringComparison]::OrdinalIgnoreCase)) { return }
                    $drel = $_.FullName.Substring($ProjectRoot.Length).TrimStart('\')
                    if ($drel -match '^(win|mac)\\monitor') { return }
                    if (-not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
                }
        }
        # 写入顺序：先程序文件 → 再根目录随包文件 → 最后才写 VERSION。
        # VERSION 是"这一份是哪一版"的判据：它若先变成新版本而程序文件没写完，更新入口会
        # 认为本地比线上新而拒绝再升级，用户就被卡在坏状态里出不来。
        $rootFiles = @()
        foreach ($rel in $pkg.Values) {
            if ($rel -notmatch '\\') { $rootFiles += $rel; continue }
            # 只写作用域内的文件：包外目录即使被显式传入也不碰（与备份/删除/回滚同范围）。
            if ($effShip -notcontains (($rel -split '\\')[0])) { continue }
            $dest = Join-Path $ProjectRoot $rel
            $parent = Split-Path -Parent $dest
            if ($parent -and -not (Test-Item $parent)) { New-Item -Path $parent -ItemType Directory -Force -ErrorAction Stop | Out-Null }
            Copy-FileAtomic (Join-Path $SrcRoot $rel) $dest
        }
        foreach ($rel in $rootFiles) {
            if ($rel -ieq 'VERSION') { continue }
            Copy-FileAtomic (Join-Path $SrcRoot $rel) (Join-Path $ProjectRoot $rel)
        }
        if ($rootFiles -contains 'VERSION') {
            Copy-FileAtomic (Join-Path $SrcRoot 'VERSION') (Join-Path $ProjectRoot 'VERSION')
        }
        # 上一次覆盖若在中途被杀，安装区可能留下写了一半的临时文件；顺手清干净，不留垃圾。
        # 两种命名都扫：Copy-FileAtomic 产生 *.envproxy-new*，Write-Text 产生 *.tmp<数字>。
        Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '*.envproxy-new*' -or $_.Name -like '*.tmp[0-9]*' } |
            ForEach-Object { Remove-ItemSafe $_.FullName }
        if ($removed -gt 0) { Write-Styled 'dim' ("  共移除 {0} 个旧版本残留文件。" -f $removed) }
        # 覆盖全部成功：撤掉"更新进行中"标记。
        # 留着它会让状态页一直报"上次更新没完成，程序文件可能新旧混合"——那是假警报。
        try { if (Test-Item $marker) { Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue } } catch {}
        $script:LastInstallRollback = 'ok'
    } catch {
        if ($backup -and (Test-Item $backup)) {
            # 回滚用"逐文件覆盖回去 + 删掉新增文件"，不用"删整个目录再搬回"：
            # 后者会被同一个被占用的文件挡住（更新失败的原因往往就是它），把安装区弄成半截。
            foreach ($d in $effShip) {
                $dst = Join-Path $ProjectRoot $d
                $bak = Join-Path $backup $d
                if (-not (Test-Item $bak)) { continue }
                if (-not (Test-Item $dst)) { New-Item -Path $dst -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
                foreach ($f in (Get-ChildItem -LiteralPath $bak -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                    if (-not $f.FullName.StartsWith($bak, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                    $rel = $f.FullName.Substring($bak.Length).TrimStart('\')
                    $target = Join-Path $dst $rel
                    $tp = Split-Path -Parent $target
                    if ($tp -and -not (Test-Item $tp)) { New-Item -Path $tp -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
                    # 单个文件还原不了，绝不能拖垮整趟回滚：Windows PowerShell 5.1 下被占用的目标
                    # 会让 Copy-Item 抛**终止性错误**，-ErrorAction SilentlyContinue 拦不住它
                    # （PowerShell 7 下同一情形不抛，所以这个差异在本地极容易漏过去）。
                    # 异常一旦冲出 catch，后面的"删新增文件"、其余作用域目录、根文件还原、以及
                    # 最后那段回读复检就全都不跑了——恰好在"回滚唯一存在的理由"那个场景失效。
                    try { Copy-Item -LiteralPath $f.FullName -Destination $target -Force -ErrorAction Stop } catch {}
                }
                foreach ($f in (Get-ChildItem -LiteralPath $dst -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                    if (-not $f.FullName.StartsWith($dst, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                    $rel = $f.FullName.Substring($dst.Length).TrimStart('\')
                    if ($rel -like 'monitor\*') { continue }
                    if (-not (Test-Item (Join-Path $bak $rel))) { try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch {} }
                }
            }
            foreach ($rel in $pkg.Values) {
                if ($rel -match '\\') { continue }
                $bakFile = Join-Path $backup $rel
                if (Test-Item $bakFile) { try { Copy-Item -LiteralPath $bakFile -Destination (Join-Path $ProjectRoot $rel) -Force -ErrorAction Stop } catch {} }
            }
            # 回滚也要复读：上面的复制都带 SilentlyContinue，不回读就敢说"已回滚"是假话。
            # 实测过：入口文件被占用时，VERSION 会先写成新版本、旧入口留在原地，
            # 于是更新入口认为本地比线上新，用户从此收不到任何新版本。
            #
            # 复读本身也可能抛（文件正被占着时 Get-Sha256Hex 打不开它）。一旦这里抛出去，
            # 整个 catch 会中断在"回滚做没做成"还没结论的地方——外面既拿不到状态、
            # 也拿不到备份路径，只能把"半新半旧"错报成"没动过"。
            # 所以复读的每一步都必须自己兜住异常：抛不出来，结论才留得下。
            $notBack = @()
            foreach ($d in $effShip) {
                $bakD = Join-Path $backup $d
                if (-not (Test-Item $bakD)) { continue }
                foreach ($f in (Get-ChildItem -LiteralPath $bakD -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                    try {
                        $rel = $f.FullName.Substring($bakD.Length).TrimStart('\')
                        if ($rel -like 'monitor\*') { continue }
                        $cur = Join-Path (Join-Path $ProjectRoot $d) $rel
                        if (-not (Test-Item $cur)) { $notBack += ("{0}\{1}" -f $d, $rel); continue }
                        if ((Get-Sha256Hex $f.FullName) -ne (Get-Sha256Hex $cur)) { $notBack += ("{0}\{1}" -f $d, $rel) }
                    } catch {
                        # 读不出来就当作"没能还原"——把"我不知道"说成"已经还原了"才是谎报。
                        $notBack += ("{0}\{1}" -f $d, $f.Name)
                    }
                }
            }
            foreach ($rel in $pkg.Values) {
                if ($rel -match '\\') { continue }
                $bakFile = Join-Path $backup $rel
                if (-not (Test-Item $bakFile)) { continue }
                try {
                    $curFile = Join-Path $ProjectRoot $rel
                    if (-not (Test-Item $curFile)) { $notBack += $rel; continue }
                    if ((Get-Sha256Hex $bakFile) -ne (Get-Sha256Hex $curFile)) { $notBack += $rel }
                } catch {
                    $notBack += $rel
                }
            }
            if ($notBack.Count) {
                # 回滚没做成：安装区现在半新半旧，**备份是唯一的回退抓手**。
                # 这里只报告事实（状态 + 清单 + 备份位置），不把备份搬走也不删——
                # 搬去哪、怎么告诉用户，是调用方（update 层）的事，它才知道安装根在哪、
                # 临时目录什么时候会被清掉。
                $script:LastInstallRollback = 'partial'
                $script:LastInstallRollbackBackup = $backup
                throw ("安装区写入失败，且回滚未完成——以下文件没能还原：{0}。请到 Releases 页面手动下载安装包覆盖一次。" -f (($notBack | Select-Object -First 6) -join '；'))
            }
            # 回滚成功 = 安装区已经回到更新前，不再处于"半新半旧"，标记要撤掉，
            # 否则下一次启动会白报一次"上次更新没完成"。
            $script:LastInstallRollback = 'complete'
            $script:LastInstallRollbackBackup = ''
            try { if (Test-Item $marker) { Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue } } catch {}
            throw ("安装区写入失败，已回滚到更新前的状态：{0}" -f $_.Exception.Message)
        }
        # 走到这里说明 $Stage 给了、但备份目录没建起来（建目录被拦、盘满、权限）。
        # 覆盖还没动手（备份在 try 之前），安装区一个字节都没变——标记也没写过
        # （标记同样在备份之后才写），所以这里既不用删标记、也不用报"半新半旧"。
        # 状态保持 untouched：这是"什么都没改"的准确描述。
        throw
    }
}
