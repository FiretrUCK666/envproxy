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

# ------------------------------------------------------------------------------
# 失败原因分类：把"为什么不行"从一堆布尔量变成一个明确的值
# ------------------------------------------------------------------------------
# 失败必须分类：塌缩成同一个 "fail" 时提示只能笼统说"下载失败"，用户分不清
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
$UpdateFailureKinds = @("local", "network", "quota", "server", "bad-content", "missing")

# 把 HTTP 状态码归到失败原因。403/429 有两种含义（限流 vs 真的被拒），
# 靠响应头里的 X-RateLimit-Remaining 区分：剩 0 就是配额用尽。
# $RateLimitRemaining 传空表示"没拿到这个头"，此时按"真的被拒"处理。
# 更新结果：0 = 达成目的（已更新 / 已是最新 / 用户选择不更新 / 开发副本不改）；
# 1 = 失败（检查失败、下载失败、校验失败、覆盖失败、收尾没成）。
# 用脚本级变量而不是返回值：函数里各种命令都可能往管道里写东西，返回值会被污染；
# 而计划任务、CI 这类调用方靠**退出码**判断更新成功没有。
$script:UpdateExitCode = 0

# 这个进程能不能跟人对话？
# 判据：标准输入被重定向就没人能回答（后台任务、计划任务、CI 都是这样）。
function Get-UpdateFailureKind([int]$StatusCode, [string]$RateLimitRemaining = "") {
    if ($StatusCode -eq 404 -or $StatusCode -eq 410) { return "missing" }
    if ($StatusCode -eq 429) { return "quota" }
    if ($StatusCode -eq 403) {
        if ($RateLimitRemaining -eq "0") { return "quota" }
        return "server"
    }
    if ($StatusCode -ge 500) { return "server" }
    return "network"
}

# 把失败原因翻译成一句人能据此行动的话。
# 判据只有一条：用户读完这句，知道下一步该做什么。
function Get-UpdateFailureMessage([string]$Kind, [string]$SourceName) {
    switch ($Kind) {
        "missing" {
            return ("{0} 上没有提供这个版本的安装包（等也不会出现）。" -f $SourceName) +
                "请到 Releases 页面手动下载对应平台的安装包，覆盖一次即可。"
        }
        "quota" {
            return ("GitHub 接口配额用尽了（匿名访问每小时 60 次，{0} 也因此没问出结果）。" -f $SourceName) +
                "等一小时后重试通常就好；也可以先到 Releases 页面手动下载。"
        }
        "server" {
            return ("{0} 服务端出错（HTTP 5xx 或请求被拒）。" -f $SourceName) +
                "这通常是对方临时故障，过一会儿重试就好。"
        }
        "network" {
            return ("连不上 {0}（超时或连接被拒）。" -f $SourceName) +
                "可以打开翻墙软件让请求走代理再试一次，或稍后重试。"
        }
        "bad-content" {
            return ("从 {0} 拿回来的东西没法用（下载的内容不完整、被中间网络改写，或这一版里安装包的信息有问题）。" -f $SourceName) +
                "请重试一次，或到 Releases 页面手动下载安装包。"
        }
        "local" {
            return "本机临时目录不可写，没法下载安装包（与网络和发布都无关）。" +
                "请检查磁盘空间与临时目录权限，或手动下载安装包覆盖。"
        }
        default {
            return ("从 {0} 更新失败。" -f $SourceName) + "请稍后重试，或到 Releases 页面手动下载安装包。"
        }
    }
}

# 从多条尝试的失败原因里挑一个报给用户（纯函数，可单测）。
# 规则：
#   1. 只有"全部都是 missing"才报 missing。404 必须是没有别的解释时才算数——
#      被墙的中间设备会给假 404，混着网络故障时说"发布漏了包"等于冤枉维护者。
#   2. 其余情况按"最可行动"排序取第一个：local（要修本机）> network（开代理就好）>
#      quota（等一小时）> server（等一会儿）> bad-content（重试或手动）。
function Select-UpdateFailureKind([string[]]$Kinds) {
    if (-not $Kinds) { return "network" }
    $distinct = @($Kinds | Where-Object { $_ } | Select-Object -Unique)
    if (-not $distinct.Count) { return "network" }
    if ($distinct.Count -eq 1) { return $distinct[0] }
    # 按词表顺序取第一个命中的：missing 排在最后（它只在没有别的解释时才成立）。
    foreach ($k in $UpdateFailureKinds) {
        if ($distinct -contains $k) { return $k }
    }
    return $distinct[0]
}

# 安装根有 .git（目录，或 worktree 的 .git 文件）= 开发副本。
function Test-DevCopy {
    $root = Split-Path -Parent $ScriptDir
    return (Test-Item (Join-Path $root ".git"))
}

# 源码包：有 .github、无 .git（多见于删掉了 .git 的克隆，或很早以前下载的旧包；
# 现在网页上下载的包已不再含这些文件，见 README 第 8 节）。
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
            if (-not $e) { continue }
            # 只允许安装根内的相对路径：绝对路径、盘符、任何一段 .. 一律跳过。
            # 清单来自随包的 .gitattributes，但"随包"不等于"可信"——一个 ../Documents 就能
            # 删掉安装根同级的目录，而这条路只有"点检查更新 + 源码包"才走得到。
            if ($e -match '^[/\\]' -or $e -match '^[A-Za-z]:') { continue }
            if ($e -match '(^|[/\\])\.\.([/\\]|$)') { continue }
            $p = Join-Path $Root $e
            # 再按解析后的绝对路径复核一次：拼出来的路径必须仍在安装根里，否则跳过。
            try {
                $fullP = [System.IO.Path]::GetFullPath($p)
                $fullRoot = [System.IO.Path]::GetFullPath($Root)
                if (-not $fullP.StartsWith($fullRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            } catch { continue }
            if (-not (Test-Item $p)) { continue }
            if ($e.EndsWith('/')) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
            else { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
        }
    } catch {}
}

# 从 git 远程地址里取出 "owner/repo"（纯函数）。
# 认的写法一视同仁：https://github.com/owner/repo、git@github.com:owner/repo、
# ssh://git@ssh.github.com:443/owner/repo——仓库标识永远是路径的最后两段，与协议、主机、
# 端口、有没有 .git 后缀无关，所以按"最后两段"取，而不是按某一种写法的长相去套。
# 不许用 ".*github\.com[:/]([^/]+)/([^/]+)" 这种贪婪正则：ssh://git@ssh.github.com:443/owner/repo
# 里 github.com 后面紧跟的是端口，第一段就抓成了 443，仓库标识跟着变成 "443/owner"，
# 查询地址全错，最后报出来的是"发布方没提供安装包，请手动下载"——把用户支到错的下一步。
# 主机不是 GitHub 时返回空串，让调用方退回内置默认：换了个远端（本地镜像、别的托管）
# 不该让查询地址继续指着那个主机，也不该报成"发布方没给包"。
function Get-RepoIdFromRemoteUrl([string]$Url) {
    if (-not $Url) { return "" }
    $u = $Url.Trim()
    # scp 写法 git@host:owner/repo 里主机与路径之间是冒号而不是斜杠，先换成斜杠，
    # 后面就只剩一种分隔符。只认"@ 后面到第一个 : 之前没有斜杠"这一种，别误伤 ssh:// 里的端口。
    $u = $u -replace '^([^/]+@[^/:]+):', '$1/'
    $u = $u -replace '[?#].*$', ''
    $u = $u.TrimEnd('/')
    $u = $u -replace '\.git$', ''
    $parts = @($u -split '[/\\]' | Where-Object { $_ -ne '' })
    if ($parts.Count -lt 3) { return "" }
    $hostPart = $parts[$parts.Count - 3] -replace '^.*@', ''
    $hostPart = $hostPart -replace ':[0-9]+$', ''
    if ($hostPart -ne 'github.com' -and $hostPart -notlike '*.github.com') { return "" }
    $owner = $parts[$parts.Count - 2]
    $repo = $parts[$parts.Count - 1]
    if (-not $owner -or -not $repo) { return "" }
    return ("{0}/{1}" -f $owner, $repo)
}

function Get-UpdateRepo {
    if (Test-DevCopy) {
        $root = Split-Path -Parent $ScriptDir
        try {
            $url = (git -C $root config --get remote.origin.url 2>$null)
            $id = Get-RepoIdFromRemoteUrl $url
            if ($id) { return $id }
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
# 失败原因记在 $script:UpdateLastVersionFailure：调用方要靠它区分"连不上"与"被限流"。
function Invoke-UpdateText([string]$Url) {
    $text = Invoke-UpdateTextVia $Url ""
    if ($text.Text) { return $text.Text }
    $script:UpdateLastVersionFailure = $text.Failure
    if ($text.Failure -eq "network") {
        $port = $null
        try { $port = Get-ActiveProxyPort -FullScan:$false } catch {}
        if (-not $port) { try { $port = Get-ActiveProxyPort -FullScan:$true } catch {} }
        if ($port) {
            $t2 = Invoke-UpdateTextVia $Url "$port"
            if ($t2.Text) { return $t2.Text }
            $script:UpdateLastVersionFailure = $t2.Failure
        }
    }
    return $null
}

function Invoke-UpdateTextVia([string]$Url, [string]$ProxyPort) {
    $handler = $null; $client = $null
    try {
        if (-not ("System.Net.Http.HttpClient" -as [type])) { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop }
        $handler = New-Object System.Net.Http.HttpClientHandler
        if ($ProxyPort) {
            $handler.UseProxy = $true
            # 地址现场探测，与注入端同源：只绑 ::1 的代理在 IPv4 上连不上，
            # 写死 127.0.0.1 会让"更新"这条路对它永远失败。
            $handler.Proxy = New-Object System.Net.WebProxy((Get-ProxyUrlForPort ([int]$ProxyPort)))
        } else {
            $handler.UseProxy = $false
        }
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(8)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd("EnvProxyUpdate")
        $task = $client.GetAsync($Url)
        if (-not $task.Wait(8000)) { return @{ Text = ""; Failure = "network" } }
        $resp = $task.Result
        if (-not $resp.IsSuccessStatusCode) {
            $rem = ""
            try {
                if ($resp.Headers.Contains("X-RateLimit-Remaining")) {
                    $rem = (($resp.Headers.GetValues("X-RateLimit-Remaining")) | Select-Object -First 1)
                }
            } catch {}
            return @{ Text = ""; Failure = (Get-UpdateFailureKind ([int]$resp.StatusCode) ("$rem").Trim()) }
        }
        return @{ Text = $task.Result.Content.ReadAsStringAsync().Result; Failure = "" }
    } catch { return @{ Text = ""; Failure = "network" } }
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
# 全都问不到时，$script:UpdateLastVersionFailure 记下原因（供提示用）。
$script:UpdateLastVersionFailure = "network"
function Get-RemoteVersion {
    $kinds = @()
    foreach ($src in (Get-UpdateSources)) {
        $r = Get-RemoteVersionFrom $src
        if ($r) { return $r }
        if ($script:UpdateLastVersionFailure) { $kinds += $script:UpdateLastVersionFailure }
    }
    $script:UpdateLastVersionFailure = (Select-UpdateFailureKind $kinds)
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
# 两条路都没答出来时，$script:UpdateLastVersionFailure 记下原因（供最终提示用）。
function Get-TagFromSource([hashtable]$Src) {
    $order = if ("$($Src.Preferred)" -eq "Web") { @("Web", "Api") } else { @("Api", "Web") }
    $kinds = @()
    foreach ($kind in $order) {
        $tpl = if ($kind -eq "Web") { $Src.Web } else { $Src.Api }
        if (-not $tpl) { continue }
        $url = $tpl.Replace('@@', $Src.Repo)
        $tag = if ($kind -eq "Web") { Get-TagFromWeb $url } else { Get-TagFromApi $url }
        if ($tag) { return $tag }
        if ($script:UpdateLastVersionFailure) { $kinds += $script:UpdateLastVersionFailure }
    }
    $script:UpdateLastVersionFailure = (Select-UpdateFailureKind $kinds)
    return ""
}

# API 路径：读 JSON 的 tag_name。
# 拿不到时把原因记进 $script:UpdateLastVersionFailure（限流与连不上要分开说）。
function Get-TagFromApi([string]$Url) {
    $script:UpdateLastVersionFailure = ""
    try {
        $json = Invoke-UpdateText $Url
        if (-not $json) { return "" }
        $obj = $json | ConvertFrom-Json
        $tag = ("{0}" -f $obj.tag_name).Trim()
        if (-not $tag) {
            # 200 + 一个能解析、但不是发布信息的 JSON（企业代理/门户劫持、错误对象）：
            # 原因必须算进去，否则它会从挑选集合里消失，最后报成别的原因——
            # 同一个应答在 mac 侧报的是"连不上"（中间那层换了内容，该开代理或换网络），
            # 两边给用户的指示必须一致。
            $script:UpdateLastVersionFailure = "network"
            return ""
        }
        return $tag
    } catch {
        # 200 但内容不是预期的 JSON：多半是网络中间层换了内容（劫持页、门户页）。
        # 报"连不上"比"服务端出错"贴近——服务端好好的，是中间那层不对，
        # 而用户该做的动作是开代理或换网络，不是干等。
        $script:UpdateLastVersionFailure = "network"
        return ""
    }
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
    $script:UpdateLastVersionFailure = ""
    $r = Get-TagFromWebVia $Url ""
    if ($r.Tag) { return $r.Tag }
    $script:UpdateLastVersionFailure = $r.Failure
    if ($r.Failure -eq "network") {
        $port = $null
        try { $port = Get-ActiveProxyPort -FullScan:$false } catch {}
        if (-not $port) { try { $port = Get-ActiveProxyPort -FullScan:$true } catch {} }
        if ($port) {
            $r2 = Get-TagFromWebVia $Url "$port"
            if ($r2.Tag) { return $r2.Tag }
            $script:UpdateLastVersionFailure = $r2.Failure
        }
    }
    return ""
}

function Get-TagFromWebVia([string]$Url, [string]$ProxyPort) {
    $handler = $null; $client = $null
    try {
        if (-not ("System.Net.Http.HttpClient" -as [type])) { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop }
        $handler = New-Object System.Net.Http.HttpClientHandler
        if ($ProxyPort) {
            $handler.UseProxy = $true
            # 地址现场探测，与注入端同源：只绑 ::1 的代理在 IPv4 上连不上，
            # 写死 127.0.0.1 会让"更新"这条路对它永远失败。
            $handler.Proxy = New-Object System.Net.WebProxy((Get-ProxyUrlForPort ([int]$ProxyPort)))
        } else {
            $handler.UseProxy = $false
        }
        # 不跟随重定向：只有拦住第一跳，才读得到 Location 里的标签。
        $handler.AllowAutoRedirect = $false
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(8)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd("EnvProxyUpdate")
        $task = $client.GetAsync($Url)
        if (-not $task.Wait(8000)) { return @{ Tag = ""; Failure = "network" } }
        $resp = $task.Result
        # 这条路的**正常应答就是 3xx**（不跟随重定向，才读得到 Location 里的标签）。
        # 所以先认 Location，再按状态码归类——反过来写会把 302 当成失败：
        # .NET 的 IsSuccessStatusCode 只对 2xx 为真，那样网页兜底这条路永远是死的，
        # "API 限流时网页能救回来"就成了空话，还会把 API 判出的限流压成"连不上"。
        $loc = $resp.Headers.Location
        if ($loc) {
            $tag = Get-TagFromLocation $loc.ToString()
            if ($tag) { return @{ Tag = $tag; Failure = "" } }
            # 重定向了但里面没有可认的标签：对方指向了预期之外的地方。
            return @{ Tag = ""; Failure = "server" }
        }
        if (-not $resp.IsSuccessStatusCode) {
            $rem = ""
            try {
                if ($resp.Headers.Contains("X-RateLimit-Remaining")) {
                    $rem = (($resp.Headers.GetValues("X-RateLimit-Remaining")) | Select-Object -First 1)
                }
            } catch {}
            return @{ Tag = ""; Failure = (Get-UpdateFailureKind ([int]$resp.StatusCode) ("$rem").Trim()) }
        }
        # 2xx 但没有重定向目标：这一层给的不是我们期待的形状。
        # 报"连不上"比"服务端出错"贴近——服务端好好的，是中间那层不对，
        # 而用户该做的动作是开代理或换网络，不是干等（与 mac 侧、与问版本那条路同一口径）。
        return @{ Tag = ""; Failure = "network" }
    } catch { return @{ Tag = ""; Failure = "network" } }
    finally {
        if ($client) { try { $client.Dispose() } catch {} }
        if ($handler) { try { $handler.Dispose() } catch {} }
    }
}

# 从 releases/tags/<标签> 的 JSON 里找出某个文件名对应的资产（纯函数，可单测）。
# 返回 @{ Id = "..."; Digest = "..." }；找不到或形状不对一律返回 $null——
# 调用方据此退回直连下载，不把它当错误。
# 用 @() 包一层：只有一个资产的发布会让 PowerShell 把数组解包成对象本身。
#
# 契约（两侧必须一致，见 check.yml 门禁 6）：
#   1. 文件名**逐字节相等**（区分大小写）。GitHub 的资产名大小写敏感，
#      而 PowerShell 的 -eq 对字符串**不区分大小写**——用 -eq 会把 "envproxy-win.zip"
#      也认成 "EnvProxy-win.zip"，与 mac 侧行为不一致。
#   2. 编号取自 url 字段（…/releases/assets/<编号>）：那是我们真正要 GET 的端点，
#      权威性高于 id 字段；url 里没有才退回 id 字段。
#   3. 编号必须是 1..16 位、首位非 0：0、007、二十位数都不该进 URL。
#   4. digest 是 GitHub 自己算的资产校验值；老资产没有这字段，有则必须是
#      sha256:<64 位十六进制>，否则当作没有。
# 标签要编码后才拼进 URL。
# 标签来自远端应答（tag_name 或重定向目标），不是我们写的——带空格、#、/ 的标签
# 会把地址拼坏（甚至把路径拼到别处去）。编码后才是合法地址。
function ConvertTo-UrlSegment([string]$Value) {
    if ($null -eq $Value) { return "" }
    try { return [uri]::EscapeDataString($Value) } catch { return "" }
}

# 从一个资产对象里取它的编号。规则只有一条，两侧必须一模一样：
#   1. 编号取自 url（那是我们真正要 GET 的端点），url 里没有编号才看这个资产自己的 id 字段。
#   2. url 里的编号不可用（0、007、二十位数）时，退回 id 字段——**不是**直接判失败。
#      同一个应答在两端必须得出同一个编号：一边更新、一边说"没提供安装包"是最坏的结局。
#   3. 两个来源都取不到可用编号，才算"取不到"。
function Get-AssetIdFrom($Asset) {
    $url = "{0}" -f $Asset.url
    if ($url -match '/releases/assets/([0-9]+)') {
        # 先存进变量：PowerShell 的 -match 会重写 $Matches，嵌套匹配时
        # 内层的 $Matches[1] 已经不是外层那个编号了（取出来是空，编号就永远取不到）。
        $num = $Matches[1]
        if ($num -match '^[1-9][0-9]{0,15}$') { return $num }
    }
    $id = "{0}" -f $Asset.id
    if ($id -match '^[1-9][0-9]{0,15}$') { return $id }
    return ""
}

# 这段正文是什么？结果放在 $script:UpdateAssetScope，三个取值：
#   other         不是我们要的 Release JSON（HTML 登录页、错误对象……）
#   release       是 Release JSON，里面没有这个文件
#   release-bad-id 是 Release JSON，这个文件在里面，但它的编号取不出来
# 为什么要分清：企业代理/门户劫持 api.github.com 时会回 200 + HTML 登录页，
# 或者 200 + 一个错误对象。那不是"这一版没提供安装包"——是中间层换了内容。
# 报 missing 等于冤枉维护者，还让用户白跑一趟 Releases 页面（那里同样拿不到）。
# "文件在里面但编号取不出来"同样不是 missing：那个文件是有的，报"没提供"是冤枉维护者。
$script:UpdateAssetScope = "other"
function Get-AssetFromJson([string]$Json, [string]$FileName) {
    $script:UpdateAssetScope = "other"
    if (-not $Json -or -not $FileName) { return $null }
    # 顶层必须是对象：数组开头的应答不是发布信息。
    # 光看解析结果分不出来——ConvertFrom-Json 会把单元素数组解包成元素本身，
    # 于是"顶层是一个元素"和"顶层是一个对象"长得一样，元素个数一变结论就变。
    $trimmed = $Json.TrimStart()
    if (-not $trimmed.StartsWith("{")) { return $null }
    try {
        $rel = $Json | ConvertFrom-Json -ErrorAction Stop
    } catch { return $null }
    if ($null -eq $rel -or $rel -is [array]) { return $null }
    # 判据是"顶层有没有 assets 字段"，不是"assets 是不是数组"：
    # ConvertFrom-Json 会把单元素数组解包成元素本身、空数组解包成 null，
    # 拿它判数组必然和 mac 侧（逐字符扫描，看得见方括号）对不上。
    # 顶层有 assets 字段就是发布信息：里面没有我们要的文件，那是 missing。
    $prop = $rel.PSObject.Properties["assets"]
    if ($null -eq $prop) { return $null }
    $assets = $prop.Value
    $script:UpdateAssetScope = "release"
    try {
        foreach ($a in @($assets)) {
            if (-not $a) { continue }
            if (("{0}" -f $a.name) -cne $FileName) { continue }
            # 文件在发布里。编号取不出来是一种单独的情况，不能混进"没提供"。
            $script:UpdateAssetScope = "release-bad-id"
            $id = Get-AssetIdFrom $a
            if (-not $id) { return $null }
            $script:UpdateAssetScope = "release"
            $digest = ""
            $dg = "{0}" -f $a.digest
            # 大小写两侧必须一致（mac 侧按不区分大小写处理）：对方改了大小写就静默不校验，
            # 等于这道保险自己失效。统一按小写存，比较时也按小写比。
            if ($dg -match '^sha256:[0-9a-fA-F]{64}$') { $digest = $dg.ToLower() }
            return @{ Id = $id; Digest = $digest }
        }
    } catch { }
    return $null
}

# 正文种类 → 失败原因。抽成纯函数是为了让两侧能对同一份正文得出同一个结论
# （门禁 6 把同一批应答喂给两边，比对的就是这个结果）。
function Get-AssetFailureFromScope([string]$Scope) {
    switch ($Scope) {
        "release" { return "missing" }
        "release-bad-id" { return "bad-content" }
        default { return "network" }
    }
}

# 问这一源的 API 要"某个标签下某个文件的资产"。拿不到编号时也把原因带回来，绝不抛。
# 这一步多花一次 API 配额（匿名 60 次/小时），换来的是不用碰时通时不通的 github.com。
# 返回 @{ Id = ""; Digest = ""; Failure = "<原因>" } 表示"没拿到编号"，Failure 必填：
# **查编号这一步失败的原因必须一起参与挑选**，否则这条失败会隐形，
# 最终只剩直连那一次的结果——直连 404 就被报成"发布方没提供安装包"，
# 而真实原因可能是配额用尽或对方 5xx，那是在冤枉维护者。
function Get-UpdateAsset([hashtable]$Remote, [string]$FileName) {
    if (-not $Remote.ApiRepo) { return @{ Id = ""; Digest = ""; Failure = "network" } }
    $url = "{0}/releases/tags/{1}" -f $Remote.ApiRepo, (ConvertTo-UrlSegment $Remote.Tag)
    $body = Invoke-UpdateText $url
    $failure = $script:UpdateLastVersionFailure
    $asset = Get-AssetFromJson $body $FileName
    if ($asset) { return $asset }
    if ($body) {
        # 正文有内容但拿不到编号：原因由正文种类决定（缺包 / 编号不可用 / 不是发布信息），
        # 不在这里另写一套判断——两侧共用一张映射表，才不会一边说缺包、一边说连不上。
        return @{ Id = ""; Digest = ""; Failure = (Get-AssetFailureFromScope $script:UpdateAssetScope) }
    }
    return @{ Id = ""; Digest = ""; Failure = $failure }
}

# 拿下载到的文件跟 GitHub 发布的资产校验值对一下。
# digest 是 GitHub 自己算的 sha256，查资产编号那一步顺带就拿到了——
# 不额外发请求、不额外下文件、不依赖我们自己的发版流程。
# 旧版本没有这个字段（那时 GitHub 还不给），那就跳过校验，不因此拦住更新。
#
# 返回三态：
#   "ok"        校验值对得上
#   "mismatch"  对不上——内容被改写或截断
#   "skip"      没有校验值可比，或者**文件读不出来**
# 读不出来必须归 skip 而不是 mismatch：杀毒扫描器会短暂锁住刚下好的文件，
# 这时候把"本机读不到"说成"内容被改过"，是把一个瞬时问题扣到发布方头上。
# （mac 侧同样故障是放行的，两端行为必须一致。）
function Test-AssetDigest([string]$Path, [string]$Digest) {
    if (-not $Digest) { return "skip" }
    # 路径为空时 Test-Path 在 PowerShell 5.1 上是"参数绑定失败"的终止错误：
    # 抛出去就坏了"三态"的约定（这里必须返回三态之一，不能抛）。
    if (-not $Path) { return "skip" }
    if (-not (Test-Path -LiteralPath $Path)) { return "skip" }
    $hash = $null
    try {
        # 自己算，不用 Get-FileHash：那是模块里的命令，模块自动加载挑错版本时
        # 会直接"找不到"（见 base 层 Get-Sha256Hex 的说明）。读不出来抛异常，
        # 这里接住归 skip——本机读不到不等于内容被改过。
        $hash = Get-Sha256Hex $Path
    } catch { $hash = $null }
    if (-not $hash) { return "skip" }
    $actual = "sha256:" + ("{0}" -f $hash).ToLower()
    if ($actual -eq ("{0}" -f $Digest).ToLower()) { return "ok" }
    return "mismatch"
}

# 带代理兜底的 HTTPS 下载：成功返回 "ok"，失败返回**失败原因**（见 Get-UpdateFailureKind 的词表）。
# 单独分出每一种原因，是为了让最终提示能说清"等一会儿""开代理"还是"手动下载"——
# 这些动作互不相同，塌缩成一个 fail 就只能把判断推给使用者。
# Headers 用于 API 资产端点那条路（Accept: application/octet-stream 才会回二进制）。
function Save-UpdateFile([string]$Url, [string]$DestFile, [hashtable]$Headers = @{}) {
    $r = Save-UpdateFileVia $Url $DestFile "" $Headers
    if ($r -eq "ok") { return "ok" }
    # 走代理只在"网络连不上"时才有意义：缺包/配额/服务端错误换个出口也是同样结果，
    # 重试只是白等一遍。代理本身是本机的另一个出口，连接失败换条路可能就通了。
    if ($r -eq "network") {
        $port = $null
        try { $port = Get-ActiveProxyPort -FullScan:$false } catch {}
        if (-not $port) { try { $port = Get-ActiveProxyPort -FullScan:$true } catch {} }
        if ($port) { return (Save-UpdateFileVia $Url $DestFile "$port" $Headers) }
    }
    return $r
}

function Save-UpdateFileVia([string]$Url, [string]$DestFile, [string]$ProxyPort, [hashtable]$Headers = @{}) {
    $handler = $null; $client = $null
    try {
        if (-not ("System.Net.Http.HttpClient" -as [type])) { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop }
        $handler = New-Object System.Net.Http.HttpClientHandler
        if ($ProxyPort) {
            $handler.UseProxy = $true
            # 地址现场探测，与注入端同源：只绑 ::1 的代理在 IPv4 上连不上，
            # 写死 127.0.0.1 会让"更新"这条路对它永远失败。
            $handler.Proxy = New-Object System.Net.WebProxy((Get-ProxyUrlForPort ([int]$ProxyPort)))
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
                $hn = [string]$hk
                $hv = [string]$Headers[$hk]
                # TryAddWithoutValidation 不做校验：头名或值里带 CR/LF，就能塞进额外的请求头
                # （请求走私）。这里自己拦一道。
                if ($hn -match '[\r\n:]' -or $hv -match '[\r\n]') { return "bad-content" }
                if (-not $client.DefaultRequestHeaders.TryAddWithoutValidation($hn, $hv)) { return "bad-content" }
            }
        }
        $respTask = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
        if (-not $respTask.Wait(60000)) { return "network" }
        $resp = $respTask.Result
        if (-not $resp.IsSuccessStatusCode) {
            # 403 有两种含义（限流 / 真的被拒），靠限流头区分：剩 0 就是配额用尽。
            $rem = ""
            try {
                if ($resp.Headers.Contains("X-RateLimit-Remaining")) {
                    $rem = (($resp.Headers.GetValues("X-RateLimit-Remaining")) | Select-Object -First 1)
                }
            } catch {}
            return (Get-UpdateFailureKind ([int]$resp.StatusCode) ("$rem").Trim())
        }
        $bodyTask = $resp.Content.ReadAsByteArrayAsync()
        if (-not $bodyTask.Wait(60000)) { return "network" }
        [System.IO.File]::WriteAllBytes($DestFile, $bodyTask.Result)
        return "ok"
    } catch {
        # 写文件失败（临时目录不可写）是本机问题，不能和网络问题混成一句。
        if ($_.Exception -is [System.UnauthorizedAccessException] -or $_.Exception -is [System.IO.IOException]) { return "local" }
        return "network"
    }
    finally {
        if ($client) { try { $client.Dispose() } catch {} }
        if ($handler) { try { $handler.Dispose() } catch {} }
    }
}

# 文件头是不是一个 zip。下载"成功"不等于拿到的是安装包：资产端点在请求头被网络中间层
# 丢掉时会回 200 + JSON（GitHub 的资产元数据），透明的错误页也可能回 200 + HTML。
# 那种东西写进 .zip 会让解包报"找不到中央目录"，把网络问题说成发布问题；
# 更糟的是它会让"成功"分支提前 break，把本该救场的直连兜底挡在门外。
function Test-UsableZip([string]$Path) {
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 4
            if ($fs.Read($buf, 0, 4) -lt 4) { return $false }
            # 本地文件头 PK\x03\x04（常见）、空档 PK\x05\x06、分卷 PK\x07\x08
            if (-not ($buf[0] -eq 0x50 -and $buf[1] -eq 0x4B)) { return $false }
        } finally { $fs.Dispose() }
    } catch { return $false }
    # 魔数只能证明"不是 JSON/HTML"：截断的 zip 同样以 PK 开头。真开一次中央目录——
    # 打不开就说明这份内容不可用，让调用方继续试直连，而不是把网络问题说成发布问题。
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $z = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try { return ($z.Entries.Count -gt 0) } finally { $z.Dispose() }
    } catch { return $false }
}

# 从**指定源**取一个合格的安装包：下载 → 解压 → 结构校验，全过才算数。
# 任何一步不过都返回 $null（换不换源由调用方决定），并把临时物清干净——
# 失败路径绝不给安装区留下任何东西。
# 失败原因写进脚本级变量 $UpdateLastFailure：调用方要靠它决定给用户什么提示，
# 在这里打印会让"每个源各说一句"和"最后一句总结"互相打架。
# 清掉 24 小时以前留下的更新临时物。
# 判据是**修改时间**，不是创建时间：文件被改过就说明它还在用。
# 文件与目录**都要清**：下载的包是 <base>.zip（文件），解压目录是 <base>-pkg（目录）。
# 只枚举 -Directory 会让被强杀/断电留下的 .zip 永久堆在临时目录里——用户看不到，
# 但它一直在那儿。
function Remove-StaleUpdateTemp {
    try {
        $root = [System.IO.Path]::GetTempPath()
        $cutoff = (Get-Date).AddHours(-24)
        foreach ($it in (Get-ChildItem -LiteralPath $root -Filter "EnvProxyUpdate-*" -Force -ErrorAction SilentlyContinue)) {
            try {
                if ($it.LastWriteTime -lt $cutoff) {
                    if ($it.PSIsContainer) {
                        Remove-Item -LiteralPath $it.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    } else {
                        Remove-Item -LiteralPath $it.FullName -Force -ErrorAction SilentlyContinue
                    }
                }
            } catch {}
        }
    } catch {}
}

function Get-UpdatePackage([hashtable]$Remote) {
    # DIVERGE(Win): Win 取 zip + Expand-Archive；Mac 取 tar.gz + tar（见 envproxy.sh）。
    $script:UpdateLastFailure = "network"
    # 先清掉以前留下的临时目录：进程被强杀（或者断电）会留下整个目录，不清就一直堆着。
    Remove-StaleUpdateTemp
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
        $kinds = @()
        $asset = Get-UpdateAsset $Remote $file
        if ($asset -and $asset.Id) {
            $targets += @{ Url = ("{0}/releases/assets/{1}" -f $Remote.ApiRepo, $asset.Id); Headers = @{ Accept = "application/octet-stream" } }
        } elseif ($asset -and $asset.Failure) {
            # 查资产编号这一步自己就失败了：这个原因必须一起参与挑选，
            # 否则"这条失败的路没走成"会隐形，最后只剩直连那一次的结果——
            # 直连 404 就被报成"发布方没提供安装包"，而真实原因可能是配额用尽。
            $kinds += $asset.Failure
        }
        $targets += @{ Url = ("{0}/releases/download/{1}/{2}" -f $Remote.Base, (ConvertTo-UrlSegment $Remote.Tag), $file); Headers = @{} }
        $dl = "fail"
        foreach ($t in $targets) {
            $r = Save-UpdateFile $t.Url $zipFile $t.Headers
            if ($r -eq "ok") {
                if (Test-UsableZip $zipFile) {
                    # 校验值对不上：拿回来的不是 GitHub 发布的那份内容（下载被改写或截断）。
                    # 这跟"打不开的 zip"是同一类问题：内容不可信，丢掉它换下一条路。
                    if ((Test-AssetDigest $zipFile $asset.Digest) -eq "mismatch") {
                        Remove-ItemSafe $zipFile
                        $r = "bad-content"
                    } else {
                        $dl = "ok"
                        break
                    }
                } else {
                    # 200 但不是一个能打开的 zip：丢掉这份内容，继续试下一条路（多半是直连）。
                    Remove-ItemSafe $zipFile
                    $r = "bad-content"
                }
            }
            $kinds += $r
        }
        if ($dl -ne "ok") { $script:UpdateLastFailure = (Select-UpdateFailureKind $kinds) }
        if ($dl -eq "ok") {
            Write-Styled 'title' "正在解压并校验..."
            try {
                # -LiteralPath 而不是 -Path：-Path 会把路径当通配模式，
                # 临时目录里带方括号（如 [1]）时直接报 PathNotFound（实测），
                # 而那会被误归成"内容不对"，让人以为是发布包有问题。
                Expand-Archive -LiteralPath $zipFile -DestinationPath $extractDir -Force -ErrorAction Stop
            } catch {
                $script:UpdateLastFailure = "bad-content"
                Remove-ItemSafe $zipFile
                Remove-ItemSafe $extractDir
                return $null
            }
            try {
                Test-Package $extractDir $Remote.Version "win"
            } catch {
                # 包能解开但结构不对 = 内容不对（发版漏文件、包被改写），不是网络问题。
                $script:UpdateLastFailure = "bad-content"
                Remove-ItemSafe $zipFile
                Remove-ItemSafe $extractDir
                return $null
            }
            $ok = $true
        }
    } catch {
        $script:UpdateLastFailure = "local"
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
        Write-Styled 'warn' "安装收尾超过 2 分钟没结束，已中止。"
        return $false
    } catch {
        Write-Styled 'warn' ("安装收尾没能启动：{0}" -f $_.Exception.Message)
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
    $script:UpdateExitCode = 0
    Write-Styled 'title' "======== EnvProxy 检查更新 ========"
    $local = Get-LocalVersion
    if ($local) { Write-Styled 'ok' ("本地版本 : v{0}" -f $local) }
    else { Write-Styled 'warn' "本地版本 : 未知" }
    Write-Styled 'dim' "正在检查最新版本（最多等十几秒）..."
    $remote = Get-RemoteVersion
    if (-not $remote) {
        # 问版本失败也要说清原因：连不上要开代理，配额用尽要等，仓库改名/删库是另一回事。
        Write-Styled 'warn' ("最新版本 : 检查失败（{0}）" -f (Get-UpdateFailureMessage $script:UpdateLastVersionFailure "所有更新源"))
        $script:UpdateExitCode = 1
        return
    }
    Write-Styled 'ok' ("最新版本 : {0}（来源：{1}）" -f $remote.Tag, $remote.Name)
    $cleanSource = $false
    if (Test-DevCopy) {
        Write-Styled 'dim' "这是开发副本（安装根有 .git）：更新入口不改动任何文件。"
        Write-Styled 'dim' "拉新代码请在仓库里执行：git pull"
        return
    }
    if (Test-SourceCopy) {
        Write-Styled 'warn' "这里是源码包（有 .github、无 .git），不是安装包。"
        $choice = ""
        try { $choice = Read-Host "更新会覆盖程序文件：[U] 当安装包用并清理源码文件 / [D] 自己改代码什么都不动（默认）" } catch { $choice = "" }
        if ($choice -notmatch '^[Uu]') {
            Write-Styled 'warn' "已取消：一个字节都没动。纯使用请去 Releases 下载安装包。"
            return
        }
        Write-Styled 'title' "继续更新，完成后源码专用文件会被清理（下次不再问）。"
        $cleanSource = $true
    }
    # 本地版本读不到 = 安装区已经不完整（VERSION 是随包必带的文件）。
    # 此时任何"比较"都是瞎猜，直接拒绝并指一条明路，而不是继续往下走。
    if (-not $local) {
        Write-Styled 'warn' "本地版本未知（安装根缺少 VERSION 文件），不敢自动更新，未做任何改动。"
        Write-Styled 'warn' "请到 Releases 页面手动下载安装包覆盖一次，或打开菜单选「安装 / 修复」。"
        $script:UpdateExitCode = 1
        return
    }
    if ($local -and ((Compare-Versions $local $remote.Version) -gt 0)) {
        Write-Styled 'ok' "本地版本比最新发布版新，不自动更新（需要确认就打开 Releases 页面）。"
        return
    }
    if ($local -and ((Compare-Versions $remote.Version $local) -le 0)) {
        Write-Styled 'ok' "已是最新，无需更新。"
        Write-Styled 'dim' "（如果怀疑上次更新没装完整，到 Releases 页面重新下载安装包覆盖一次即可。）"
        return
    }
    # 防呆：点的是备份文件夹时警告（正式路径以注册表记录为准）
    $regPath = $null
    try { $regPath = (Get-ItemProperty $ScriptPathRegKey -ErrorAction SilentlyContinue).ScriptPath } catch {}
    if ($regPath -and (("$regPath").ToLower() -ne ("$ScriptPath").ToLower())) {
        Write-Styled 'warn' ("注意：你现在点的是 [{0}]，" -f $ScriptPath)
        Write-Styled 'warn' ("但正式安装在 [{0}]。" -f $regPath)
        Write-Styled 'warn' "继续会更新【当前这个文件夹】并把它切换为正式安装。"
    }
    # 非交互环境（没有能提问的控制台）：问不到人，就别白下一个包。
    # 先问再下载：反过来会白烧一次 GitHub 配额和一份安装包。
    if (-not $AutoYes -and -not (Test-CanPrompt)) {
        Write-Styled 'warn' ("发现新版本 {0}，但当前环境没法提问（没有可交互的控制台），未做任何改动。" -f $remote.Tag)
        Write-Styled 'warn' "要更新请在能交互的终端里运行，或加 -Yes 跳过确认。"
        $script:UpdateExitCode = 1
        return
    }
    # 取包：先试胜出源，它取不到就换下一个源再试。
    # 只回退"问版本"是不够的——官方源的 API 答得出、它的资产主机却下不动，是现实存在的形态
    # （同一台机器实测 api.github.com 通、github.com 整段超时），而那一刻另一个源本来能救回来。
    # 换源必须**连同版本一起换**：用那一源自己的标签下它自己的包，保持"版本与包同源"。
    $zipFile = $null
    $extractDir = $null
    $kinds = @()
    try {
        $pkg = Get-UpdatePackage $remote
        if (-not $pkg) { $kinds += $script:UpdateLastFailure }
        if (-not $pkg) {
            foreach ($src in (Get-UpdateSources)) {
                # 同名源跳过必须排在联网之前：胜出源刚刚已经试过，再问一次只会白烧一次
                # API 配额，而取包失败的时刻往往正是配额最紧张的时候。
                if ($src.Name -eq $remote.Name) { continue }
                $alt = Get-RemoteVersionFrom $src
                if (-not $alt) { continue }
                # 只接受不比当前目标更旧的源：更新到一个更旧的版本没有意义。
                if ((Compare-Versions $alt.Version $remote.Version) -lt 0) { continue }
                Write-Styled 'title' ("改用 {0} 重试（{1}）..." -f $alt.Name, $alt.Tag)
                $pkg = Get-UpdatePackage $alt
                if ($pkg) { break }
                $kinds += $script:UpdateLastFailure
            }
        }
        # 一句话说清"为什么没成、接下来怎么办"：由真实失败原因决定，
        # 两句口径必须一致：这里说"下载失败或校验没过"会与上面"没有提供安装包"自相矛盾。
        if (-not $pkg) {
            $script:UpdateLastFailure = (Select-UpdateFailureKind $kinds)
            Write-Styled 'warn' ("更新失败：{0}" -f (Get-UpdateFailureMessage $script:UpdateLastFailure $remote.Name))
            Write-Styled 'warn' "未做任何改动。"
            $script:UpdateExitCode = 1
            return
        }
        $extractDir = $pkg.Root
        $zipFile = $pkg.Zip
        # 先把这一版改了什么给用户看，再问要不要装
        Show-ReleaseNotes $extractDir $pkg.Tag
        if (-not $AutoYes) {
            # 读不到回答（控制台没了、没权限）与"用户答否"是两件事：
            # 前者是"没法提问"（退出码 1），后者是"用户不更新"（退出码 0）。
            $answer = ""
            $readOk = $true
            try { $answer = Read-Host ("已下载并校验通过（{0}），现在更新？[y/N]" -f $pkg.Tag) } catch { $readOk = $false }
            if (-not $readOk) {
                Write-Styled 'warn' "没法提问：读不到你的回答，未做任何改动。"
                $script:UpdateExitCode = 1
                return
            }
            if ($answer -notmatch '^[Yy]') { Write-Styled 'warn' "已取消：安装区一个字节都没动。"; return }
        }
        # 停监控 → 覆盖安装区（跳过 monitor 保日志；全部文件一次覆盖到位）→ 用安装根新脚本收尾
        # → 交给**新版本**的自己收尾。整段失败会回滚，安装区不会半新半旧。
        Write-Styled 'title' "正在安装新版（保留日志，原监控先停）..."
        try { Stop-Monitor } catch {}
        $root = Split-Path -Parent $ScriptDir
        try {
            # 全部文件一次覆盖到位，包含正在执行的这个核心脚本：PowerShell 启动时已把整份脚本读进
            # 内存，之后覆盖文件不影响本次运行。只同步本平台目录与共享文件，另一平台目录不动。
            # 任何一步失败会整体回滚。
            Install-Package -SrcRoot $extractDir -ProjectRoot $root -Stage $extractDir -ShipDirs @("win", "release-notes", "assets")
        } catch {
            Write-Styled 'warn' ("更新失败：{0}" -f $_.Exception.Message)
            Write-Styled 'warn' "已恢复原状，正在重启监控..."
            try { Install-EnvProxy | Out-Null } catch {}
            $script:UpdateExitCode = 1
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
            Write-Styled 'warn' "收尾没走完，正在用新版本再试一次..."
            $null = Invoke-InstallFinish $newScript
            $ok = Test-InstallRootMonitor $root
        }
        if (-not $ok) {
            # 文件已经覆盖到位，但监控没起来：目的没达成，退出码要如实说"没成"。
            Write-Styled 'warn' "监控未能确认运行，请打开菜单选一次「安装 / 修复」。"
            $script:UpdateExitCode = 1
        }
    } catch {
        Write-Styled 'warn' ("更新失败：{0}" -f $_.Exception.Message)
        Write-Styled 'warn' "可稍后重试；也可以手动下载安装包覆盖后，再打开菜单选一次「安装 / 修复」。"
        $script:UpdateExitCode = 1
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
        Write-Styled 'title' ("---------- {0} 改了什么 ----------" -f $Tag)
        $lines | Select-Object -First 40 | ForEach-Object { Write-Host "  $_" }
        if ($lines.Count -gt 40) { Write-Styled 'dim' ("  （以上为前 40 行；全文见 Releases 页面，更新完成后也会出现在安装目录的 release-notes\{0}.md）" -f $Tag) }
        Write-Styled 'title' "----------------------------------"
    } catch {}
}
