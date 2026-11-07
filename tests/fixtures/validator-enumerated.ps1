# ==============================================================================
#  v1.0.0 的安装包校验器（冻结副本，原样来自 git show v1.0.0:win/lib/package.ps1）
#
#  为什么冻结：已发布的客户端用它校验新包。它是**枚举式白名单**——
#  平台目录下只放行「入口 + 菜单壳 + 定位器(mac) + 入口声明的每个库」，
#  多一个文件就整包拒收。
#
#  当前包在平台根下多了 win/locator.ps1、mac/prompt-sync.sh 等脚本，
#  v1.0.0 的用户点「检查更新」会永远得到「包里有清单外的文件」——
#  而那句错误来自他们手里那版代码，我们改新代码救不了他们。
#
#  冻结它的用途：让**当前产出的真包**必须能过它。
#  每次要往平台根下加脚本之前，先看这条会不会把老客户端卡死。
#  这条规则只增不改：v1.0.0 已经发出去了，它的行为永远不会变。
# ==============================================================================
# 夹具自带的两个最小辅助函数。
# **不许改成调用当前代码里的同名函数**：夹具要代表"老客户端那一版的行为"，
# 依赖现役实现就跟着现役一起变，等于没冻结。
function Read-Text([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}
function Test-Item([string]$Path) {
    return (Test-Path -LiteralPath $Path)
}
function Test-Package([string]$Root, [string]$WantVersion, [string]$Platform = "win") {
    $srcVer = ""
    try { $srcVer = ((Read-Text (Join-Path $Root "VERSION")).Trim()) } catch {}
    if (-not $srcVer -or ($srcVer -ne $WantVersion)) { throw "校验失败（包内 VERSION 与目标版本不一致），未做任何改动。" }
    # 结构校验，不点名具体文件：本平台入口必须在，包内每一个脚本都要过编码红线。
    # 于是加库、改名、挪位置都不用改这里——与 CI 门禁 3 是同一条规则，两处不会漂移。
    $wantEntry = if ($Platform -eq "mac") { "mac\envproxy.sh" } else { "win\envproxy.ps1" }
    if (-not (Test-Item (Join-Path $Root $wantEntry))) { throw ("校验失败（安装包缺少 {0}），未做任何改动。" -f $wantEntry) }
    # 内容集校验：本平台目录里只能有"入口 + 菜单壳 + 定位器(mac) + 入口自己声明的每个库"，
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
    if ($Platform -eq "mac") { $allowed += @("mac/打开菜单.command", "mac/locator.sh") }
    else { $allowed += "win/打开菜单.cmd" }
    foreach ($l in $declared) { $allowed += "$platDir/lib/$l$libExt" }
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
    $extra = @($actual | Where-Object { $allowed -notcontains $_ })
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
}

