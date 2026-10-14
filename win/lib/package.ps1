# ==============================================================================
#  package.ps1 — 安装包层：覆盖安装区、备份与逐文件回滚
#  覆盖前必校验目的地；任何一步失败回滚到更新前，安装区不留半截。
# ==============================================================================

# 校验安装包：包内 VERSION 与目标一致、两个平台的核心文件都在、两条编码红线没被改过。
# 任何一项不过就抛异常，调用方据此中止——安装区一个字节都不动。
function Test-Package([string]$Root, [string]$WantVersion) {
    $srcVer = ""
    try { $srcVer = ((Read-Text (Join-Path $Root "VERSION")).Trim()) } catch {}
    if (-not $srcVer -or ($srcVer -ne $WantVersion)) { throw "校验失败（包内 VERSION 与目标版本不一致），未做任何改动。" }
    # 结构校验，不点名具体文件：两个入口必须在，包内每一个脚本都要过编码红线。
    # 于是加库、改名、挪位置都不用改这里——与 CI 门禁 3 是同一条规则，两处不会漂移。
    foreach ($entry in @("win\envproxy.ps1", "mac\envproxy.sh")) {
        if (-not (Test-Item (Join-Path $Root $entry))) { throw ("校验失败（安装包缺少 {0}），未做任何改动。" -f $entry) }
    }
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

function Copy-FileAtomic([string]$Src, [string]$Dest) {
    # 每个文件都走"同目录临时文件 + 整体替换"，与 macOS 侧同一语义。
    # 不用 Copy-Item：它先截断再写，中途断电或被杀就留下半截文件——程序拆成多文件后，
    # 任何一个文件半截都等于整个程序起不来。字节直拷顺带保住包内文件的 BOM 与行尾，
    # 不需要再按文件类型分特例。
    $dir = Split-Path -Parent $Dest
    if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [System.IO.Directory]::CreateDirectory($dir) | Out-Null }
    $tmp = "$Dest.envproxy-new$PID"
    try {
        [System.IO.File]::Copy($Src, $tmp, $true)
        if ([System.IO.File]::Exists($Dest)) {
            try { [System.IO.File]::Replace($tmp, $Dest, $null) }
            catch { [System.IO.File]::Copy($tmp, $Dest, $true); [System.IO.File]::Delete($tmp) }
        } else {
            [System.IO.File]::Move($tmp, $Dest)
        }
    } catch {
        try { if ([System.IO.File]::Exists($tmp)) { [System.IO.File]::Delete($tmp) } } catch {}
        throw
    }
}

# 覆盖安装区。边界三条：包内文件全部写入；win\monitor 与 mac\monitor 永不覆盖、永不删；
# 四个程序目录内、新包没有的文件按清单删除（旧按钮不会残留成"点了没反应"）。
# 安装根目录只覆盖同名文件，绝不删任何东西——根目录可能有用户自己的东西。
function Install-Package([string]$SrcRoot, [string]$ProjectRoot, [string]$Stage) {
    # $Stage 必填：没有它就没有备份，也就没有回滚——不留"可以无回滚地覆盖安装区"的口子。
    if (-not $Stage) { throw "内部错误：覆盖安装区必须提供备份目录（-Stage）。" }
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
    # 覆盖前后各做一件事，都是为了让"更新到一半失败"不留残局：
    #   覆盖前——把四个程序目录 + 根目录那几个随包文件备份到本次更新的临时目录；
    #   覆盖中——任何一步失败就整体回滚到备份（安装区回到更新前），然后把异常抛给调用方。
    # 本函数内所有路径读写一律走字面量语义（-LiteralPath / 第 0.5 节 helper），
    # 安装文件夹改名带上 [ ] 也不影响。
    $shipDirs = @("win", "mac", "release-notes", "assets")
    $pkg = @{}
    foreach ($f in (Get-ChildItem -LiteralPath $SrcRoot -Recurse -File -Force -ErrorAction Stop)) {
        $rel = $f.FullName.Substring($SrcRoot.Length).TrimStart('\')
        $pkg[$rel.ToLower()] = $rel
    }
    $backup = $null
    if ($Stage) {
        $backup = Join-Path $Stage "backup"
        Remove-ItemSafe (Join-Path $Stage "backup")
        New-Item -Path $backup -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        foreach ($d in $shipDirs) {
            $src = Join-Path $ProjectRoot $d
            if (Test-Item $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $backup $d) -Recurse -Force -ErrorAction Stop }
        }
        # 根目录那几个随包文件（VERSION / README / LICENSE）也要备份：只备份程序目录的话，
        # 中途失败回滚后会留下"版本号是新的、程序目录是旧的"——比不滚还难查。
        foreach ($rel in $pkg.Values) {
            if ($rel -match '\\') { continue }
            $src = Join-Path $ProjectRoot $rel
            if (Test-Item $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $backup $rel) -Force -ErrorAction Stop }
        }
    }
    try {
        $removed = 0
        foreach ($d in $shipDirs) {
            $destDir = Join-Path $ProjectRoot $d
            if (-not (Test-Item $destDir)) { continue }
            foreach ($f in (Get-ChildItem -LiteralPath $destDir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                # 越界保护：枚举结果必须确定位于本次目标之下，否则跳过（通配符曾让这里指向过别的目录）。
                if (-not $f.FullName.StartsWith($destDir, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                $rel = $f.FullName.Substring($ProjectRoot.Length).TrimStart('\')
                if ($rel -match '^(win|mac)\\monitor\\') { continue }
                if (-not $pkg.ContainsKey($rel.ToLower())) {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                    Write-Host ("  已移除旧版本残留：{0}" -f $rel) -ForegroundColor DarkGray
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
        foreach ($rel in $pkg.Values) {
            $dest = Join-Path $ProjectRoot $rel
            $parent = Split-Path -Parent $dest
            if ($parent -and -not (Test-Item $parent)) { New-Item -Path $parent -ItemType Directory -Force -ErrorAction Stop | Out-Null }
            Copy-FileAtomic (Join-Path $SrcRoot $rel) $dest
        }
        # 上一次覆盖若在中途被杀，安装区可能留下写了一半的临时文件；顺手清干净，不留垃圾。
        Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File -Filter "*.envproxy-new*" -Force -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-ItemSafe $_.FullName }
        if ($removed -gt 0) { Write-Host ("  共移除 {0} 个旧版本残留文件。" -f $removed) -ForegroundColor DarkGray }
    } catch {
        if ($backup -and (Test-Item $backup)) {
            # 回滚用"逐文件覆盖回去 + 删掉新增文件"，不用"删整个目录再搬回"：
            # 后者会被同一个被占用的文件挡住（更新失败的原因往往就是它），把安装区弄成半截。
            foreach ($d in $shipDirs) {
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
                    Copy-Item -LiteralPath $f.FullName -Destination $target -Force -ErrorAction SilentlyContinue
                }
                foreach ($f in (Get-ChildItem -LiteralPath $dst -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                    if (-not $f.FullName.StartsWith($dst, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                    $rel = $f.FullName.Substring($dst.Length).TrimStart('\')
                    if ($rel -like 'monitor\*') { continue }
                    if (-not (Test-Item (Join-Path $bak $rel))) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
                }
            }
            foreach ($rel in $pkg.Values) {
                if ($rel -match '\\') { continue }
                $bak = Join-Path $backup $rel
                if (Test-Item $bak) { Copy-Item -LiteralPath $bak -Destination (Join-Path $ProjectRoot $rel) -Force -ErrorAction SilentlyContinue }
            }
            throw ("安装区写入失败，已回滚到更新前的状态：{0}" -f $_.Exception.Message)
        }
        throw
    }
}
