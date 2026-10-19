# ==============================================================================
#  update.ps1 — 更新层：版本比较、下载校验、用户确认流程、安装来源分流
#  状态显示只读；动手只走更新入口。
# ==============================================================================

# ------------------------------------------------------------------------------
# 8. 在线更新（检查更新 + 一键升级；状态显示只读，动手只在这里）
# ------------------------------------------------------------------------------
# 更新源：分平台安装包资产（EnvProxy-win.zip；Mac 侧取 EnvProxy-mac.tar.gz），按下面的源表尝试。
#   只同步本平台目录与共享文件，另一平台目录不动（分平台包里本来就没有它）。
#   安装包内容由仓库 .gitattributes 的 export-ignore 声明，发布流水线用 git archive 产出。
#   不接公共加速站：那些站点靠站长自掏腰包维持、生命周期以月计，包从它手里过一遍还等于多信一个陌生人。
#   判据是环境事实，不看是谁在用：
#     安装根有 .git = 开发副本 → 更新只读，不改动任何文件，提示走 git pull；
#     有 .github、无 .git = 源码包 → 先确认用途（当安装包用就更新并清理源码文件，
#       自己改代码就一个字节都不动），拿不到输入时按后者；
#     两个都没有 = 安装副本 → 下载安装包、校验、覆盖安装区。
#   读版本时开发副本跟自己的 git remote 走（fork 后看得到自己仓库的 Release）；
#   覆盖文件这条路上，git 副本一律不参与。
$UpdateRepoDefault = "FiretrUCK666/envproxy"

# 更新源表：有序，逐个尝试，第一个能给出"可用的新版本安装包"的胜出。
# 每项声明五件事：
#   Id        这一源的仓库标识从哪里取（见 Get-UpdateRepoId）
#   Api/Web   两条"怎么问最新版"的路径，Preferred 决定先试哪条，另一条是兜底
#   Base      安装包直连下载的地址前缀（最后一道兜底）
#   ApiRepo   API 端点前缀，用来查资产 id 并从 API 取包（首选下载路径）
# 地址里的 @@ 接仓库标识（用纯字符串替换，不经正则——正则会把地址里的符号当元字符）。
# 目前只有官方源一条；新增一个源 = 表里加一行（若引入新的标识来源，再加一个 Id 分支），
# 不涉及任何判断逻辑。顺序即优先级。
#
# 为什么要两条问版本的路：各有短板。
#   Api 语义明确，但匿名配额只有 60 次/小时/IP。
#   Web 走网页重定向、不吃 API 配额；但网页路径在受限网络里会整段超时
#       （同一台机器实测：同一条 URL，curl 拿到 302、.NET 超时）。
# 所以 Api 优先、Web 兜底：API 被限流时网页能救回来。
#
# 为什么下载也分两条路、且 API 在前：GitHub 的网页主机（github.com）在受限网络里时通时不通
# （同一台机器实测过连续 5 次下载超时），而 api.github.com 稳定可达（实测 200 / 0.2s）。
# API 的资产端点回 302 到 release-assets 的 CDN 域名，那条链在同类网络里也通。
# 所以先走 API 资产端点，再退回直连下载——两条都失败才算这个源不可用。
$UpdateSourceTable = @(
    @{ Id = "official"; Name = "GitHub"; Preferred = "Api"; Api = "https://api.github.com/repos/@@/releases/latest"; Web = "https://github.com/@@/releases/latest"; Base = "https://github.com/@@"; ApiRepo = "https://api.github.com/repos/@@"; }
)

# 安装根有 .git（目录，或 worktree 的 .git 文件）= 开发副本。
function Test-DevCopy {
    $root = Split-Path -Parent $ScriptDir
    return (Test-Item (Join-Path $root ".git"))
}

# 源码包：有 .github、无 .git（多见于删掉了 .git 的克隆，或很早以前下载的旧包；
# 现在网页上下载的包已不再含这些文件，见 README 故障排查）。
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

# 这一源的仓库标识从哪里取：环境事实——开发副本跟自己的 git remote 走
# （fork 后看得见自己仓库的 Release），安装副本用内置默认。
# 参数保留是为了源表的 Id 字段：将来加源时按 Id 分派，不必改调用方。
function Get-UpdateRepoId([string]$Key) {
    return (Get-UpdateRepo)
}

# 本机这次实际可用的源（有序）：没有仓库标识的源直接跳过（目前只有官方源一条）。
function Get-UpdateSources {
    $out = @()
    foreach ($s in $UpdateSourceTable) {
        $id = Get-UpdateRepoId $s.Id
        if (-not $id) { continue }
        $out += @{ Name = $s.Name; Repo = $id; Preferred = $s.Preferred; Api = $s.Api; Web = $s.Web; Base = $s.Base; ApiRepo = $s.ApiRepo }
    }
    # 前面那个逗号不能省：PowerShell 会把单元素集合解包成元素本身，
    # 于是"只剩一个源"时调用方拿到的是一个哈希表而不是源的表，
    # foreach 会去遍历它的键值对、.Count 会变成键的个数。逗号包一层强制它始终是数组。
    return ,$out
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

# 查最新 Release（状态显示与更新入口共用）：
# 返回 @{ Version="1.2.0"; Tag="v1.2.0"; Base="<下载前缀>"; Name="<源名>" }，
# 所有源都问不到才返回 $null（只读，不抛异常，不写文件）。
# 逐个源尝试，第一个答出来的胜出。
# 顺带把胜出源的下载前缀一并带回去——版本与安装包必须来自同一个源，
# 否则会出现"拿 A 源的版本号去下 B 源的包"。
function Get-RemoteVersion {
    foreach ($src in (Get-UpdateSources)) {
        $r = Get-RemoteVersionFrom $src
        if ($r) { return $r }
    }
    return $null
}

# 从**一个**源查最新 Release：这一源自己的两条路径都试过还不行，才算它答不上来。
# 拆出这一层是为了让更新入口能按源做完整的尝试（问版本 + 取包），而不只是问版本。
function Get-RemoteVersionFrom([hashtable]$Src) {
    try {
        $tag = Get-TagFromSource $Src
        if (-not $tag) { return $null }
        $ver = if ($tag -match '^v(.*)$') { $Matches[1].Trim() } else { $tag }
        if (-not $ver) { return $null }
        # ApiRepo 缺省时置空，而不是让 .Replace 在 $null 上抛：那个异常会被外层的 catch
        # 吞成"这个源答不上来"，整条源被静默跳过——"加源 = 表里加一行"就成了陷阱。
        $apiRepo = if ($Src.ApiRepo) { $Src.ApiRepo.Replace('@@', $Src.Repo) } else { "" }
        return @{ Version = $ver; Tag = $tag; Base = $Src.Base.Replace('@@', $Src.Repo); ApiRepo = $apiRepo; Name = $Src.Name }
    } catch { return $null }
}

# 按这一源声明的优先顺序问版本，先答出来的那条胜出。
function Get-TagFromSource([hashtable]$Src) {
    $order = if ("$($Src.Preferred)" -eq "Web") { @("Web", "Api") } else { @("Api", "Web") }
    foreach ($kind in $order) {
        $tpl = if ($kind -eq "Web") { $Src.Web } else { $Src.Api }
        if (-not $tpl) { continue }
        $url = $tpl.Replace('@@', $Src.Repo)
        $tag = if ($kind -eq "Web") { Get-TagFromWeb $url } else { Get-TagFromApi $url }
        if ($tag) { return $tag }
    }
    return ""
}

# API 路径：读 JSON 的 tag_name。
function Get-TagFromApi([string]$Url) {
    try {
        $json = Invoke-UpdateText $Url
        if (-not $json) { return "" }
        $obj = $json | ConvertFrom-Json
        return (("{0}" -f $obj.tag_name).Trim())
    } catch { return "" }
}

# 从重定向目标里提取标签；形状不对就返回空（调用方据此换另一条路径）。
# 抽成纯函数是为了能进回归测试：必须校验它确实落在 /releases/tag/<标签> 上，不能只取最后一段——
# 仓库改名时对方会先 302 到改名后的仓库路径（实测过 dromara/hutool），那时最后一段是字面量
# "latest"，naive 取尾段会把垃圾当成版本号去拼下载地址。
# 标签本身可能含括号等字符且不做百分号编码（实测 v2026.09(jdk25)），所以整段取、不解码。
function Get-TagFromLocation([string]$Location) {
    if (-not $Location) { return "" }
    $m = [regex]::Match($Location, '/releases/tag/([^/?#]+)$')
    if (-not $m.Success) { return "" }
    return $m.Groups[1].Value
}

# 网页路径：读 302 的 Location 取标签。带代理兜底（与 API 路径同一个模式）。
function Get-TagFromWeb([string]$Url) {
    $tag = Get-TagFromWebVia $Url ""
    if ($tag) { return $tag }
    $port = $null
    try { $port = Get-ActiveProxyPort -FullScan:$false } catch {}
    if (-not $port) { try { $port = Get-ActiveProxyPort -FullScan:$true } catch {} }
    if (-not $port) { return "" }
    return (Get-TagFromWebVia $Url "$port")
}

function Get-TagFromWebVia([string]$Url, [string]$ProxyPort) {
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
        # 不跟随重定向：只有拦住第一跳，才读得到 Location 里的标签。
        $handler.AllowAutoRedirect = $false
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(8)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd("EnvProxyUpdate")
        $task = $client.GetAsync($Url)
        if (-not $task.Wait(8000)) { return "" }
        $loc = $task.Result.Headers.Location
        if (-not $loc) { return "" }
        return (Get-TagFromLocation $loc.ToString())
    } catch { return "" }
    finally {
        if ($client) { try { $client.Dispose() } catch {} }
        if ($handler) { try { $handler.Dispose() } catch {} }
    }
}

# 从 releases/tags/<标签> 的 JSON 里找出某个文件名对应的资产 id（纯函数，可单测）。
# 找不到、或者 JSON 形状不对，一律返回空串——调用方据此退回直连下载，不把它当错误。
# 用 @() 包一层：只有一个资产的发布会让 PowerShell 把数组解包成对象本身。
function Get-AssetIdFromJson([string]$Json, [string]$FileName) {
    if (-not $Json -or -not $FileName) { return "" }
    try {
        $rel = $Json | ConvertFrom-Json
        foreach ($a in @($rel.assets)) {
            if ($a -and (("{0}" -f $a.name) -eq $FileName)) { return ("{0}" -f $a.id) }
        }
    } catch { }
    return ""
}

# 问这一源的 API 要"某个标签下某个文件的资产 id"。拿不到就返回空，绝不抛。
# 这一步多花一次 API 配额（匿名 60 次/小时），换来的是不用碰时通时不通的 github.com。
function Get-UpdateAssetId([hashtable]$Remote, [string]$FileName) {
    if (-not $Remote.ApiRepo) { return "" }
    $url = "{0}/releases/tags/{1}" -f $Remote.ApiRepo, $Remote.Tag
    return (Get-AssetIdFromJson (Invoke-UpdateText $url) $FileName)
}

# 带代理兜底的 HTTPS 下载：返回 "ok" / "missing"（这个版本没提供该文件）/ "fail"。
# 单独分出 "missing"，是为了把「这次发布漏了安装包」和「本机网络不通」两句提示分开。
# Headers 用于 API 资产端点那条路（Accept: application/octet-stream 才会回二进制）。
function Save-UpdateFile([string]$Url, [string]$DestFile, [hashtable]$Headers = @{}) {
    $r = Save-UpdateFileVia $Url $DestFile "" $Headers
    if ($r -ne "fail") { return $r }
    $port = $null
    try { $port = Get-ActiveProxyPort -FullScan:$false } catch {}
    if (-not $port) { try { $port = Get-ActiveProxyPort -FullScan:$true } catch {} }
    if ($port) { return (Save-UpdateFileVia $Url $DestFile "$port" $Headers) }
    return "fail"
}

function Save-UpdateFileVia([string]$Url, [string]$DestFile, [string]$ProxyPort, [hashtable]$Headers = @{}) {
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
        # 自定义头（API 资产端点要 Accept: application/octet-stream）。返回 false 说明头没加上，
        # 那这条请求拿回来的会是 JSON 而不是安装包——当场判失败，别把 JSON 当包往下走。
        if ($Headers) {
            foreach ($hk in $Headers.Keys) {
                if (-not $client.DefaultRequestHeaders.TryAddWithoutValidation([string]$hk, [string]$Headers[$hk])) { return "fail" }
            }
        }
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

# 文件头是不是一个 zip。下载"成功"不等于拿到的是安装包：资产端点在请求头被网络中间层
# 丢掉时会回 200 + JSON（GitHub 的资产元数据），透明的错误页也可能回 200 + HTML。
# 那种东西写进 .zip 会让解包报"找不到中央目录"，把网络问题说成发布问题；
# 更糟的是它会让"成功"分支提前 break，把本该救场的直连兜底挡在门外。
function Test-ZipMagic([string]$Path) {
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 4
            if ($fs.Read($buf, 0, 4) -lt 4) { return $false }
            # 本地文件头 PK\x03\x04（常见）、空档 PK\x05\x06、分卷 PK\x07\x08
            return ($buf[0] -eq 0x50 -and $buf[1] -eq 0x4B)
        } finally { $fs.Dispose() }
    } catch { return $false }
}

# 从**指定源**取一个合格的安装包：下载 → 解压 → 结构校验，全过才算数。
# 任何一步不过都返回 $null（换不换源由调用方决定），并把临时物清干净——
# 失败路径绝不给安装区留下任何东西。
function Get-UpdatePackage([hashtable]$Remote) {
    # DIVERGE(Win): Win 取 zip + Expand-Archive；Mac 取 tar.gz + tar（见 envproxy.sh）。
    $tmpBase = Join-Path ([System.IO.Path]::GetTempPath()) ("EnvProxyUpdate-" + ($Remote.Tag -replace '[^A-Za-z0-9._-]','_') + "-" + [System.IO.Path]::GetRandomFileName())
    $zipFile = "$tmpBase.zip"
    $extractDir = "${tmpBase}-pkg"
    $ok = $false
    try {
        Remove-ItemSafe $zipFile
        Remove-ItemSafe $extractDir
        New-Item -Path $extractDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        # 地址由**这一源自己**给出：版本与安装包来自同一个源，不会串源。
        # 下载顺序：API 资产端点优先，直连下载兜底（见源表上方关于两条路的说明）。
        # 两条路都可能"没有这个文件"，所以先各跑一遍再判：任何一条拿到就算成功，
        # 全部失败时才按"有真失败就报失败、否则报缺包"给提示。
        $file = "EnvProxy-win.zip"
        $targets = @()
        $assetId = Get-UpdateAssetId $Remote $file
        if ($assetId) {
            $targets += @{ Url = ("{0}/releases/assets/{1}" -f $Remote.ApiRepo, $assetId); Headers = @{ Accept = "application/octet-stream" } }
        }
        $targets += @{ Url = ("{0}/releases/download/{1}/{2}" -f $Remote.Base, $Remote.Tag, $file); Headers = @{} }
        $dl = "fail"
        $sawFail = $false
        $sawMissing = $false
        foreach ($t in $targets) {
            $r = Save-UpdateFile $t.Url $zipFile $t.Headers
            if ($r -eq "ok") {
                if (Test-ZipMagic $zipFile) { $dl = "ok"; break }
                # 200 但不是 zip：丢掉这份内容，继续试下一条路（多半是直连）。
                Remove-ItemSafe $zipFile
                $r = "fail"
            }
            if ($r -eq "missing") { $sawMissing = $true } else { $sawFail = $true }
        }
        if ($dl -ne "ok") { $dl = if ($sawFail) { "fail" } elseif ($sawMissing) { "missing" } else { "fail" } }
        if ($dl -eq "missing") {
            Write-Host ("  {0} 上没有提供这个版本的安装包。" -f $Remote.Name) -ForegroundColor DarkGray
        } elseif ($dl -ne "ok") {
            Write-Host ("  从 {0} 下载失败。" -f $Remote.Name) -ForegroundColor DarkGray
        } else {
            Write-Host "正在解压并校验..." -ForegroundColor Cyan
            Expand-Archive -Path $zipFile -DestinationPath $extractDir -Force -ErrorAction Stop
            Test-Package $extractDir $Remote.Version "win"
            $ok = $true
        }
    } catch {
        Write-Host ("  {0} 的安装包没通过校验：{1}" -f $Remote.Name, $_.Exception.Message) -ForegroundColor DarkGray
    }
    if (-not $ok) {
        Remove-ItemSafe $zipFile
        Remove-ItemSafe $extractDir
        return $null
    }
    return @{ Root = $extractDir; Zip = $zipFile; Tag = $Remote.Tag; Version = $Remote.Version; Name = $Remote.Name }
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
    Write-Host "正在检查最新版本（最多等十几秒）..." -ForegroundColor DarkGray
    $remote = Get-RemoteVersion
    if (-not $remote) {
        Write-Host "最新版本 : 检查失败（所有更新源都不可达）" -ForegroundColor Yellow
        Write-Host "请稍后重试。也可以先关掉、再打开翻墙软件，让它换一个状态，常常就能连上。" -ForegroundColor Yellow
        return
    }
    Write-Host ("最新版本 : {0}（来源：{1}）" -f $remote.Tag, $remote.Name) -ForegroundColor Green
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
    # 取包：先试胜出源，它取不到就换下一个源再试。
    # 只回退"问版本"是不够的——官方源的 API 答得出、它的资产主机却下不动，是现实存在的形态
    # （同一台机器实测 api.github.com 通、github.com 整段超时），而那一刻另一个源本来能救回来。
    # 换源必须**连同版本一起换**：用那一源自己的标签下它自己的包，保持"版本与包同源"。
    $zipFile = $null
    $extractDir = $null
    try {
        $pkg = Get-UpdatePackage $remote
        if (-not $pkg) {
            foreach ($src in (Get-UpdateSources)) {
                # 同名源跳过必须排在联网之前：胜出源刚刚已经试过，再问一次只会白烧一次
                # API 配额，而取包失败的时刻往往正是配额最紧张的时候。
                if ($src.Name -eq $remote.Name) { continue }
                $alt = Get-RemoteVersionFrom $src
                if (-not $alt) { continue }
                # 只接受不比当前目标更旧的源：更新到一个更旧的版本没有意义。
                if ((Compare-Versions $alt.Version $remote.Version) -lt 0) { continue }
                Write-Host ("改用 {0} 重试（{1}）..." -f $alt.Name, $alt.Tag) -ForegroundColor Cyan
                $pkg = Get-UpdatePackage $alt
                if ($pkg) { break }
            }
        }
        if (-not $pkg) { throw "没能取到可用的安装包（下载失败或校验没通过），未做任何改动。请稍后重试，也可以到 Releases 页面手动下载安装包覆盖一次。" }
        $extractDir = $pkg.Root
        $zipFile = $pkg.Zip
        # 先把这一版改了什么给用户看，再问要不要装
        Show-ReleaseNotes $extractDir $pkg.Tag
        if (-not $AutoYes) {
            $answer = ""
            try { $answer = Read-Host ("已下载并校验通过（{0}），现在更新？[y/N]" -f $pkg.Tag) } catch { $answer = "" }
            if ($answer -notmatch '^[Yy]') { Write-Host "已取消：安装区一个字节都没动。" -ForegroundColor Yellow; return }
        }
        # 停监控 → 覆盖安装区（跳过 monitor 保日志；全部文件一次覆盖到位）→ 用安装根新脚本收尾
        # → 交给**新版本**的自己收尾。整段失败会回滚，安装区不会半新半旧。
        Write-Host "正在安装新版（保留日志，原监控先停）..." -ForegroundColor Cyan
        try { Stop-Monitor } catch {}
        $root = Split-Path -Parent $ScriptDir
        try {
            # 全部文件一次覆盖到位，包含正在执行的这个核心脚本：PowerShell 启动时已把整份脚本读进
            # 内存，之后覆盖文件不影响本次运行。只同步本平台目录与共享文件，另一平台目录不动。
            # 任何一步失败会整体回滚。
            Install-Package -SrcRoot $extractDir -ProjectRoot $root -Stage $extractDir -ShipDirs @("win", "release-notes", "assets")
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
        # 取包失败时这两个变量还是 $null：没拿到包就说明临时物已经在取包函数里清过了。
        if ($zipFile) { try { Remove-ItemSafe $zipFile } catch {} }
        # 解压目录在收尾完成后清理；收尾跑的是安装根里的新脚本，这里只是兜底删除。
        if ($extractDir) { try { if (Test-Item $extractDir) { Remove-ItemSafe $extractDir } } catch {} }
    }
}

# 打印这一版改了什么：包内 release-notes/<标签>.md，最多 40 行；没有就跳过。
function Show-ReleaseNotes([string]$Root, [string]$Tag) {
    $safeTag = $Tag -replace '[^A-Za-z0-9._-]','_'
    $f = Join-Path $Root ("release-notes\{0}.md" -f $safeTag)
    if (-not (Test-Item $f)) { return }
    try {
        $lines = @([System.IO.File]::ReadAllLines($f, [System.Text.Encoding]::UTF8))
        Write-Host ("---------- {0} 改了什么 ----------" -f $Tag) -ForegroundColor Cyan
        $lines | Select-Object -First 40 | ForEach-Object { Write-Host "  $_" }
        if ($lines.Count -gt 40) { Write-Host ("  （以上为前 40 行；全文见 Releases 页面，更新完成后也会出现在安装目录的 release-notes\{0}.md）" -f $Tag) -ForegroundColor DarkGray }
        Write-Host "----------------------------------" -ForegroundColor Cyan
    } catch {}
}
