# ==============================================================================
#  update.ps1 — 更新层：版本比较、下载校验、用户确认流程、安装来源分流
#  状态显示只读；动手只走更新入口。
# ==============================================================================

# ------------------------------------------------------------------------------
# 8. 在线更新（检查更新 + 一键升级；状态显示只读，动手只在这里）
# ------------------------------------------------------------------------------
# 更新源：GitHub Release 里的安装包资产（EnvProxy.zip；Mac 侧取 EnvProxy.tar.gz）。
#   安装包内容由仓库 .gitattributes 的 export-ignore 声明，发布流水线用 git archive 产出。
#   下载失败只提示确认 GitHub 可达后重试：镜像站只收录部分项目，加速代理属透明中转，
#   不硬编码任何第三方域名，不为它放宽校验。
#   判据是环境事实，不看是谁在用：
#     安装根有 .git = 开发副本 → 更新只读，不改动任何文件，提示走 git pull；
#     有 .github、无 .git = 源码包 → 先确认用途（当安装包用就更新并清理源码文件，
#       自己改代码就一个字节都不动），拿不到输入时按后者；
#     两个都没有 = 安装副本 → 下载安装包、校验、覆盖安装区。
#   读版本时开发副本跟自己的 git remote 走（fork 后看得到自己仓库的 Release）；
#   覆盖文件这条路上，git 副本一律不参与。
$UpdateRepoDefault = "FiretrUCK666/envproxy"

# 安装根有 .git（目录，或 worktree 的 .git 文件）= 开发副本。
function Test-DevCopy {
    $root = Split-Path -Parent $ScriptDir
    return (Test-Item (Join-Path $root ".git"))
}

# 源码包：有 .github、无 .git（多见于删掉了 .git 的克隆，或很早以前下载的旧包；
# 现在网页上下载的 zip 已不再含这些文件，见 README 故障排查）。
# 安装包里永远没有 .github（打包配置排除），用户自己也不会建这个目录，认它零误伤。
# 传参则判指定目录（自检用），不传判安装根。
function Test-SourceCopy {
    param([string]$Root = "")
    if (-not $Root) { $Root = Split-Path -Parent $ScriptDir }
    return ((-not (Test-Item (Join-Path $Root ".git"))) -and (Test-Item (Join-Path $Root ".github")))
}

# 源码包转安装包：删掉源码专用文件（清单从 .gitattributes 的排除表实时读，不是写死的）。
# 调用方保证安装根有效且用户已确认；删完下次更新不再问。
function Remove-SourceOnlyFiles([string]$Root) {
    try {
        $ga = Join-Path $Root ".gitattributes"
        if (-not (Test-Item $ga)) { return }
        $list = @()
        foreach ($l in ((Read-Text $ga) -split "`n")) {
            $t = $l.Trim()
            if ($t -match '^/(\S+?)\s+export-ignore') { $list += $Matches[1] }
        }
        foreach ($e in $list) {
            $p = Join-Path $Root $e
            if (-not (Test-Item $p)) { continue }
            if ($e.EndsWith('/')) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
            else { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
        }
    } catch {}
}

function Get-UpdateRepo {
    if (Test-DevCopy) {
        $root = Split-Path -Parent $ScriptDir
        try {
            $url = (git -C $root config --get remote.origin.url 2>$null)
            if ($url -and ($url -match 'github\.com[:/]([^/]+)/([^/\s]+)')) {
                $repo = $Matches[2] -replace '\.git$',''
                if ($Matches[1] -and $repo) { return ("{0}/{1}" -f $Matches[1], $repo) }
            }
        } catch {}
    }
    return $UpdateRepoDefault
}

function Get-LocalVersion {
    try {
        $root = Split-Path -Parent $ScriptDir
        $vf = Join-Path $root "VERSION"
        # 直接读、用异常判不存在：先 Test-Path 再读是两套语义，含 [ ] 时前者会撒谎。
        return ((Read-Text $vf).Trim())
    } catch {}
    return ""
}

# 带代理兜底的 HTTPS 取文本：先直连，失败且本地代理 active 时经代理重试一次。
# DIVERGE(Win): Mac 侧 curl 自动继承环境变量代理，单次调用叠加直连回退即可；
# Win 侧走系统代理恒为直连，需显式经 127.0.0.1 重试。
function Invoke-UpdateText([string]$Url) {
    $text = Invoke-UpdateTextVia $Url ""
    if ($text) { return $text }
    $port = $null
    try { $port = Get-ActiveProxyPort -FullScan:$false } catch {}
    if (-not $port) { try { $port = Get-ActiveProxyPort -FullScan:$true } catch {} }
    if ($port) { return (Invoke-UpdateTextVia $Url "$port") }
    return $null
}

function Invoke-UpdateTextVia([string]$Url, [string]$ProxyPort) {
    $handler = $null; $client = $null
    try {
        if (-not ("System.Net.Http.HttpClient" -as [type])) { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop }
        $handler = New-Object System.Net.Http.HttpClientHandler
        if ($ProxyPort) {
            $handler.UseProxy = $true
            $handler.Proxy = New-Object System.Net.WebProxy("http://127.0.0.1:$ProxyPort")
        } else {
            $handler.UseProxy = $false
        }
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(8)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd("EnvProxyUpdate")
        $task = $client.GetStringAsync($Url)
        if ($task.Wait(8000)) { return $task.Result }
        return $null
    } catch { return $null }
    finally {
        if ($client) { try { $client.Dispose() } catch {} }
        if ($handler) { try { $handler.Dispose() } catch {} }
    }
}

# 查最新 Release：返回 @{ Version="1.2.0"; Tag="v1.2.0" }，查不到返回 $null（只读，不抛异常）。
function Get-RemoteVersion {
    try {
        $repo = Get-UpdateRepo
        $json = Invoke-UpdateText ("https://api.github.com/repos/{0}/releases/latest" -f $repo)
        if (-not $json) { return $null }
        $obj = $json | ConvertFrom-Json
        $tag = ("{0}" -f $obj.tag_name).Trim()
        if (-not $tag) { return $null }
        $ver = if ($tag -match '^v(.*)$') { $Matches[1].Trim() } else { $tag }
        if (-not $ver) { return $null }
        return @{ Version = $ver; Tag = $tag }
    } catch { return $null }
}

# 带代理兜底的 HTTPS 下载：返回 "ok" / "missing"（这个版本没提供该文件）/ "fail"。
# 单独分出 "missing"，是为了把「这次发布漏了安装包」和「本机网络不通」两句提示分开。
function Save-UpdateFile([string]$Url, [string]$DestFile) {
    $r = Save-UpdateFileVia $Url $DestFile ""
    if ($r -ne "fail") { return $r }
    $port = $null
    try { $port = Get-ActiveProxyPort -FullScan:$false } catch {}
    if (-not $port) { try { $port = Get-ActiveProxyPort -FullScan:$true } catch {} }
    if ($port) { return (Save-UpdateFileVia $Url $DestFile "$port") }
    return "fail"
}

function Save-UpdateFileVia([string]$Url, [string]$DestFile, [string]$ProxyPort) {
    $handler = $null; $client = $null
    try {
        if (-not ("System.Net.Http.HttpClient" -as [type])) { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop }
        $handler = New-Object System.Net.Http.HttpClientHandler
        if ($ProxyPort) {
            $handler.UseProxy = $true
            $handler.Proxy = New-Object System.Net.WebProxy("http://127.0.0.1:$ProxyPort")
        } else {
            $handler.UseProxy = $false
        }
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(60)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd("EnvProxyUpdate")
        $respTask = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
        if (-not $respTask.Wait(60000)) { return "fail" }
        $resp = $respTask.Result
        if (($resp.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) -or ($resp.StatusCode -eq [System.Net.HttpStatusCode]::Gone)) { return "missing" }
        if (-not $resp.IsSuccessStatusCode) { return "fail" }
        $bodyTask = $resp.Content.ReadAsByteArrayAsync()
        if (-not $bodyTask.Wait(60000)) { return "fail" }
        [System.IO.File]::WriteAllBytes($DestFile, $bodyTask.Result)
        return "ok"
    } catch { return "fail" }
    finally {
        if ($client) { try { $client.Dispose() } catch {} }
        if ($handler) { try { $handler.Dispose() } catch {} }
    }
}

# 跑一次"安装收尾"：启动安装根里的入口脚本（-Install）并等它结束。返回"它有没有正常跑完"，
# 但**不把退出码当成结论**——见 Test-InstallRootMonitor 的注释。
function Invoke-InstallFinish([string]$Entry, [int]$TimeoutMs = 120000) {
    try {
        $proc = Start-Process -FilePath "powershell" -PassThru -NoNewWindow -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$Entry`"", "-Install"
        )
        if ($proc.WaitForExit($TimeoutMs)) { return $true }
        try { $proc.Kill() } catch {}
        Write-Host "安装收尾超过 2 分钟没结束，已中止。" -ForegroundColor Yellow
        return $false
    } catch {
        Write-Host ("安装收尾没能启动：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
        return $false
    }
}

# 收尾是否真的完成：读安装根的 monitor\monitor.pid，确认那个进程还活着、命令行指向**安装根**的入口。
# 判据必须是复读出来的事实，不能用子进程的退出码：PowerShell 5.1 里 Start-Process -PassThru 之后
# ExitCode 读不到（返回空），把"读不到"当失败会让每次更新都白跑一遍收尾、把刚装好的监控掀掉，
# 还会让旧代码把刚写对的路径记录改回去。
function Test-InstallRootMonitor([string]$Root) {
    $pidFile = Join-Path $Root "win\monitor\monitor.pid"
    if (-not (Test-Item $pidFile)) { return $false }
    try {
        $p = [int]((Read-Text $pidFile).Trim())
        $w = Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue
        if ($w -and ($w.CommandLine -match $MonitorCmdLinePattern) -and
            ($w.CommandLine.IndexOf($Root, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)) { return $true }
    } catch {}
    return $false
}

function Update-EnvProxy([bool]$AutoYes = $false) {
    Write-Host "======== EnvProxy 检查更新 ========" -ForegroundColor Cyan
    $local = Get-LocalVersion
    if ($local) { Write-Host ("本地版本 : v{0}" -f $local) -ForegroundColor Green }
    else { Write-Host "本地版本 : 未知" -ForegroundColor Yellow }
    Write-Host "正在检查最新版本（最多等几秒）..." -ForegroundColor DarkGray
    $remote = Get-RemoteVersion
    if (-not $remote) {
        Write-Host "最新版本 : 检查失败（网络不可达或 GitHub API 限流）" -ForegroundColor Yellow
        Write-Host "请稍后重试。也可以先关掉、再打开翻墙软件，让它换一个状态，常常就能连上。" -ForegroundColor Yellow
        return
    }
    Write-Host ("最新版本 : {0}" -f $remote.Tag) -ForegroundColor Green
    $cleanSource = $false
    if (Test-DevCopy) {
        Write-Host "这是开发副本（安装根有 .git）：更新入口不改动任何文件。" -ForegroundColor DarkGray
        Write-Host "拉新代码请在仓库里执行：git pull" -ForegroundColor DarkGray
        return
    }
    if (Test-SourceCopy) {
        Write-Host "这里是源码包（有 .github、无 .git），不是安装包。" -ForegroundColor Yellow
        $choice = ""
        try { $choice = Read-Host "更新会覆盖程序文件：[U] 当安装包用并清理源码文件 / [D] 自己改代码什么都不动（默认）" } catch { $choice = "" }
        if ($choice -notmatch '^[Uu]') {
            Write-Host "已取消：一个字节都没动。纯使用请去 Releases 下载安装包。" -ForegroundColor Yellow
            return
        }
        Write-Host "继续更新，完成后源码专用文件会被清理（下次不再问）。" -ForegroundColor Cyan
        $cleanSource = $true
    }
    # 本地版本读不到 = 安装区已经不完整（VERSION 是随包必带的文件）。
    # 此时任何"比较"都是瞎猜，直接拒绝并指一条明路，而不是继续往下走。
    if (-not $local) {
        Write-Host "本地版本未知（安装根缺少 VERSION 文件），不敢自动更新，未做任何改动。" -ForegroundColor Yellow
        Write-Host "请到 Releases 页面手动下载安装包覆盖一次，或打开菜单选"安装 / 修复"。" -ForegroundColor Yellow
        return
    }
    if ($local -and ((Compare-Versions $local $remote.Version) -gt 0)) {
        Write-Host "本地版本比最新发布版新，不自动更新（需要确认就打开 Releases 页面）。" -ForegroundColor Green
        return
    }
    if ($local -and ((Compare-Versions $remote.Version $local) -le 0)) {
        Write-Host "已是最新，无需更新。" -ForegroundColor Green
        Write-Host "（如果怀疑上次更新没装完整，到 Releases 页面重新下载安装包覆盖一次即可。）" -ForegroundColor DarkGray
        return
    }
    # 防呆：点的是备份文件夹时警告（正式路径以注册表记录为准）
    $regPath = $null
    try { $regPath = (Get-ItemProperty $ScriptPathRegKey -ErrorAction SilentlyContinue).ScriptPath } catch {}
    if ($regPath -and (("$regPath").ToLower() -ne ("$ScriptPath").ToLower())) {
        Write-Host ("注意：你现在点的是 [{0}]，" -f $ScriptPath) -ForegroundColor Yellow
        Write-Host ("但正式安装在 [{0}]。" -f $regPath) -ForegroundColor Yellow
        Write-Host "继续会更新【当前这个文件夹】并把它切换为正式安装。" -ForegroundColor Yellow
    }
    # 下载安装包到临时目录并校验；校验没过就一个字节都不动安装区
    $repo = Get-UpdateRepo
    $zipUrl = "https://github.com/{0}/releases/download/{1}/EnvProxy.zip" -f $repo, $remote.Tag
    # DIVERGE(Win): Win 取 zip + Expand-Archive；Mac 取 tar.gz + tar（见 envproxy.sh）。
    $tmpBase = Join-Path ([System.IO.Path]::GetTempPath()) ("EnvProxyUpdate-" + ($remote.Tag -replace '[^A-Za-z0-9._-]','_'))
    $zipFile = "$tmpBase.zip"
    $extractDir = "${tmpBase}-pkg"
    try {
        Write-Host "正在下载安装包..." -ForegroundColor Cyan
        Remove-ItemSafe $zipFile
        Remove-ItemSafe $extractDir
        New-Item -Path $extractDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        $dl = Save-UpdateFile $zipUrl $zipFile
        if ($dl -eq "missing") { throw "这个版本没有提供安装包（下载地址返回 404），未做任何改动。请到 Releases 页面手动下载。" }
        if ($dl -ne "ok") { throw "下载失败（网络不可达），未做任何改动。" }
        Write-Host "正在解压并校验..." -ForegroundColor Cyan
        Expand-Archive -Path $zipFile -DestinationPath $extractDir -Force -ErrorAction Stop
        Test-Package $extractDir $remote.Version
        # 先把这一版改了什么给用户看，再问要不要装
        Show-ReleaseNotes $extractDir $remote.Tag
        if (-not $AutoYes) {
            $answer = ""
            try { $answer = Read-Host ("已下载并校验通过（{0}），现在更新？[y/N]" -f $remote.Tag) } catch { $answer = "" }
            if ($answer -notmatch '^[Yy]') { Write-Host "已取消：安装区一个字节都没动。" -ForegroundColor Yellow; return }
        }
        # 停监控 → 覆盖安装区（跳过 monitor 保日志；全部文件一次覆盖到位）→ 用安装根新脚本收尾
        # → 交给**新版本**的自己收尾。整段失败会回滚，安装区不会半新半旧。
        Write-Host "正在安装新版（保留日志，原监控先停）..." -ForegroundColor Cyan
        try { Stop-Monitor } catch {}
        $root = Split-Path -Parent $ScriptDir
        try {
            # 全部文件一次覆盖到位，包含正在执行的这个核心脚本：PowerShell 启动时已把整份脚本读进
            # 内存，之后覆盖文件不影响本次运行。任何一步失败会整体回滚。
            Install-Package -SrcRoot $extractDir -ProjectRoot $root -Stage $extractDir
        } catch {
            Write-Host ("更新失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
            Write-Host "已恢复原状，正在重启监控..." -ForegroundColor Yellow
            try { Install-EnvProxy | Out-Null } catch {}
            return
        }
        if ($cleanSource) { Remove-SourceOnlyFiles $root }
        # 收尾跑**安装根里**的新脚本（不是解压目录里那份）：只有从安装根执行，路径记录、自启动项与
        # 监控进程才会落在安装根，不会指向马上要被删掉的临时目录。带超时，卡住就报错而不是无声等待。
        $newScript = Join-Path $root "win\envproxy.ps1"
        # 先把操作锁交出去：收尾子进程跑的是同一个安装动作，它会自己去拿这把锁。
        if ($opMutex) { try { $opMutex.ReleaseMutex() } catch {}; $opMutex = $null }
        $null = Invoke-InstallFinish $newScript
        # 收尾成没成由**复读**决定：安装根里的监控在跑，就是成了。
        $ok = $false
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline) {
            if (Test-InstallRootMonitor $root) { $ok = $true; break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $ok) {
            # 文件已经覆盖到位：再跑一次收尾，跑的仍是安装根里的**新代码**（不是本进程这份旧代码——
            # 旧代码对新布局的假设可能已经过时，让它去动安装区是自找麻烦）。
            Write-Host "收尾没走完，正在用新版本再试一次..." -ForegroundColor Yellow
            $null = Invoke-InstallFinish $newScript
            $ok = Test-InstallRootMonitor $root
        }
        if (-not $ok) {
            Write-Host "监控未能确认运行，请打开菜单选一次"安装 / 修复"。" -ForegroundColor Yellow
        }
    } catch {
        Write-Host ("更新失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
        Write-Host "可稍后重试；也可以手动下载安装包覆盖后，再打开菜单选一次"安装 / 修复"。" -ForegroundColor Yellow
    } finally {
        try { Remove-ItemSafe $zipFile } catch {}
        # 解压目录在收尾完成后清理；收尾跑的是安装根里的新脚本，这里只是兜底删除。
        try { if (Test-Item $extractDir) { Remove-ItemSafe $extractDir } } catch {}
    }
}

# 打印这一版改了什么：包内 release-notes/<标签>.md，最多 40 行；没有就跳过。
function Show-ReleaseNotes([string]$Root, [string]$Tag) {
    $f = Join-Path $Root ("release-notes\{0}.md" -f $Tag)
    if (-not (Test-Item $f)) { return }
    try {
        $lines = @([System.IO.File]::ReadAllLines($f, [System.Text.Encoding]::UTF8))
        Write-Host ("---------- {0} 改了什么 ----------" -f $Tag) -ForegroundColor Cyan
        $lines | Select-Object -First 40 | ForEach-Object { Write-Host "  $_" }
        if ($lines.Count -gt 40) { Write-Host ("  （以上为前 40 行；全文见 Releases 页面，更新完成后也会出现在安装目录的 release-notes\{0}.md）" -f $Tag) -ForegroundColor DarkGray }
        Write-Host "----------------------------------" -ForegroundColor Cyan
    } catch {}
}
