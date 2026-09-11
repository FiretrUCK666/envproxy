# ==============================================================================
#  envproxy.ps1 — 命令行自动翻墙（Windows 原生，零依赖，通用版）
# ------------------------------------------------------------------------------
#  子命令（双击配套 .cmd，或在 PowerShell 里运行）：
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Install   一键安装
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Stop      停止监控
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Uninstall 一键恢复
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Status    查看状态
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Update     检查更新（一键升级，问过才装）
#     无参数（由开机自启调用）                                         进入监控模式
#
#  运行环境：Windows 10/11 自带 PowerShell 5.1。不需要 Node/Python/管理员。
#
#  原理（通用，不绑定任何特定翻墙软件）：
#     监控进程每 2 秒探测一次"本机是否有 HTTP 代理端口正在监听"。
#     发现来源（两层，与系统代理/PAC/Core 完全无关，只认端口本身）：
#       1) 快路径：常见翻墙软件默认端口扫描（$KnownProxyPorts，可自行增删）
#       2) 万能路径：全端口扫描 + CONNECT 握手探测（进程名预筛提速）
#           → 随便改端口、随便换软件，都能自动发现，不写死任何东西
#     状态翻转（开/关/换端口）时才写一次用户级环境变量并广播刷新。
#     状态稳定时什么都不写 —— 不存在"反复监测反复断连"。
#
#  行为保证：
#     - 翻墙软件断开/重连/退出/重启/换端口/换软件 → 监控自动跟随，无需任何操作
#     - 退出翻墙软件后约 8 秒删除代理变量；"断开连接"（内核仍活着）以流量真相判定，≤35 秒
#     - 整个文件夹移动到任何位置 → 无需任何操作（监控自退 + 定位器开机自动重新定位）
#     - 无常驻依赖、不改系统代理、不需要管理员
# ==============================================================================

param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Stop,
    [switch]$Status,
    [switch]$Update,
    [switch]$Yes,
    [switch]$Purge
)

# ------------------------------------------------------------------------------
# 0. Win32 广播 API（通知系统"环境变量已变化"，纯系统自带能力）
# ------------------------------------------------------------------------------
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class EnvProxyNative {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
'@ -ErrorAction SilentlyContinue
} catch {}

function Broadcast-EnvironmentChange {
    try {
        $r = [UIntPtr]::Zero
        [EnvProxyNative]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero,
            "Environment", 0x0002, 3000, [ref]$r) | Out-Null
    } catch {}
}

# ------------------------------------------------------------------------------
# 1. 通用代理端口发现（不绑定任何特定软件、不写死端口）
# ------------------------------------------------------------------------------
# 常见翻墙软件的默认本地代理端口（快速扫描用）。可自行增删。
$KnownProxyPorts = @(7078, 7890, 7897, 10808, 10809, 10801, 2080, 2081, 1080, 8118, 8080, 6152, 8888)

# 翻墙软件进程名特征（用于快速预筛，缩小 CONNECT 探测范围）。可自行扩展。
# 注意：此列表只影响"速度"不影响"覆盖面"——即使进程名不在列表里，
#       第二轮的"全端口 CONNECT 探测"也能发现它（见 Find-ProxyPortByConnect）。
$ProxyProcessPatterns = @("monocloud", "clash", "mihomo", "verge", "v2ray", "xray",
    "sing-box", "singbox", "hiddify", "shadowsocks", "ss-local", "trojan", "hysteria",
    "neko", "netch", "surge", "outline")

function Test-PortListening([int]$Port) {
    return [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

# CONNECT 探测：向端口发一个 HTTP CONNECT 请求，只有真正的 HTTP 代理才回 "200"。
# 这是区分"代理端口"与"其他服务端口"的终极判定，不依赖进程名/端口号猜测。
function Test-HttpProxy([int]$Port) {
    $client = $null
    $stream = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.ReceiveTimeout = 500
        $client.SendTimeout = 500
        $client.Connect("127.0.0.1", $Port)
        $stream = $client.GetStream()
        $stream.ReadTimeout = 500
        $req = [System.Text.Encoding]::ASCII.GetBytes("CONNECT 127.0.0.1:9 HTTP/1.1`r`nHost: 127.0.0.1:9`r`n`r`n")
        $stream.Write($req, 0, $req.Length)
        $stream.Flush()
        $buf = New-Object byte[] 512
        $n = $stream.Read($buf, 0, 512)
        if ($n -gt 0) {
            $resp = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
            return ($resp -match "^\s*HTTP/1\.[01]\s+200")
        }
        return $false
    } catch {
        return $false
    } finally {
        if ($stream) { try { $stream.Close() } catch {} }
        if ($client) { try { $client.Close() } catch {} }
    }
}

# 并行批量 CONNECT 探测：对多个端口同时发起握手，~1 秒内出结果。
# 用于全端口兜底扫描——避免"逐个串行等超时"导致的几十秒延迟。
function Test-HttpProxyBatch([int[]]$Ports) {
    $pending = @()
    foreach ($p in $Ports) {
        $c = New-Object System.Net.Sockets.TcpClient
        try {
            $ar = $c.BeginConnect("127.0.0.1", $p, $null, $null)
            $pending += [PSCustomObject]@{ Port = $p; Client = $c; Async = $ar }
        } catch { $c.Close() }
    }
    # 阶段 1：并发连接，最多等 800ms
    $connected = @()
    foreach ($item in $pending) {
        if ($item.Async.AsyncWaitHandle.WaitOne(800)) {
            try { $item.Client.EndConnect($item.Async); $connected += $item } catch {}
        }
    }
    # 阶段 2：对已连接的端口发 CONNECT 读响应（非代理端口通常立即拒绝，毫秒级）
    foreach ($item in $connected) {
        try {
            $c = $item.Client
            $s = $c.GetStream()
            $s.ReadTimeout = 500
            $req = [System.Text.Encoding]::ASCII.GetBytes("CONNECT 127.0.0.1:9 HTTP/1.1`r`nHost: 127.0.0.1:9`r`n`r`n")
            $s.Write($req, 0, $req.Length)
            $s.Flush()
            $buf = New-Object byte[] 512
            $n = $s.Read($buf, 0, 512)
            if ($n -gt 0) {
                $resp = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
                if ($resp -match "^\s*HTTP/1\.[01]\s+200") { return $item.Port }
            }
        } catch {}
        finally { try { $item.Client.Close() } catch {} }
    }
    foreach ($item in $pending) { try { $item.Client.Close() } catch {} }
    return $null
}

# 来源 1（快路径）：常见端口扫描——绝大多数翻墙软件的默认端口，秒级命中
function Find-ListeningPort {
    try {
        # 一次查询拿到全部监听端口，内存过滤已知端口（避免逐端口串行查询的开销）
        $listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue
        foreach ($p in $KnownProxyPorts) {
            if ($listeners.LocalPort -contains $p) { return $p }
        }
    } catch {}
    return $null
}

# 来源 2（万能路径）：CONNECT 握手探测，不依赖进程名、端口号、软件品牌。
#   FullScan=$true ：第一轮进程预筛 + 第二轮全端口并行批量探测（慢，~1 秒）
#   FullScan=$false：只做第一轮进程预筛（毫秒级，用于 off 状态的低开销轮询）
# 谁回答 "200 Connection Established"，谁就是正在工作的 HTTP 代理。
function Find-ProxyPortByConnect([bool]$FullScan = $true) {
    try {
        # 一次性构建 PID -> 进程名 映射（避免逐个查询进程的开销）
        $procMap = @{}
        Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $procMap[$_.Id] = $_.ProcessName.ToLower() }

        $listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalAddress -in @("127.0.0.1", "::1", "0.0.0.0", "::") }

        # 第一轮：疑似翻墙软件的进程监听的端口（始终执行，覆盖 99% 常见软件）
        $suspectPorts = @()
        foreach ($l in $listeners) {
            $pname = $procMap[$l.OwningProcess]
            if (-not $pname) { continue }
            foreach ($pat in $ProxyProcessPatterns) {
                if ($pname -like "*$pat*") { $suspectPorts += $l.LocalPort; break }
            }
        }
        foreach ($p in ($suspectPorts | Sort-Object -Unique)) {
            if (Test-HttpProxy $p) { return $p }
        }

        # 第二轮：兜底——所有监听端口并行批量握手探测（进程名无特征也能发现）。
        # 仅在 FullScan 时执行（批量探测约 1 秒，off 状态降频调用以省资源）。
        if (-not $FullScan) { return $null }
        $restPorts = @()
        foreach ($l in $listeners) {
            if ($suspectPorts -contains $l.LocalPort) { continue }   # 第一轮已测过
            $restPorts += $l.LocalPort
        }
        if ($restPorts.Count -gt 0) {
            return Test-HttpProxyBatch ($restPorts | Sort-Object -Unique)
        }
    } catch {}
    return $null
}

# 组合发现：先走快路径（常见端口，秒级），不中再走万能路径（CONNECT 探测）。
# FullScan 控制万能路径是否启用昂贵的全端口批量探测（off 状态降频用）。
function Get-ActiveProxyPort([bool]$FullScan = $true) {
    $fast = Find-ListeningPort
    if ($fast) { return $fast }
    return Find-ProxyPortByConnect -FullScan:$FullScan
}

# 验证端点（多端点轮换，防止单一端点被干扰/墙导致误判"断开"）。
# 选型原则：必须是"明确被墙 + 官方连通性检查端点 + 零字节响应 + 全球极稳"的站点。
# 端点池刻意跨厂商、跨域段：
#   Google 主域段 / gstatic CDN 段 / YouTube 段 / 非 Google 兜底（被墙站点）。
# 任何一个域段被干扰（DNS 污染、节点线路问题、站点封锁节点出口 IP）时其余幸存；
# 只有"所有域段全部不通"才判节点死——杜绝单域段盲区导致的误删。
# 上次成功的端点优先复用——稳定的端点持续走快路，异常时自动切换。
$CheckEndpoints = @(
    @{ Host = "clients3.google.com";            Path = "/generate_204" },
    @{ Host = "connectivitycheck.gstatic.com";  Path = "/generate_204" },
    @{ Host = "www.gstatic.com";                Path = "/generate_204" },
    @{ Host = "youtubei.googleapis.com";        Path = "/generate_204" },
    @{ Host = "www.google.com";                 Path = "/generate_204" },
    @{ Host = "www.wikipedia.org";              Path = "/" },
    @{ Host = "twitter.com";                    Path = "/" }
)
$script:LastGoodEndpoint = 0

# 单端点探测：通过代理发真实 HTTP 请求，成功返回 $true
function Test-SingleEndpoint([int]$Port, [string]$HostName, [string]$Path) {
    $client = $null
    $stream = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.ReceiveTimeout = 6000
        $client.SendTimeout = 6000
        $client.Connect("127.0.0.1", $Port)
        $stream = $client.GetStream()
        # 超时 6 秒：节点慢/重连中时 mihomo 转发可能长达数秒；过短会把"慢但通"误判为"断"
        $stream.ReadTimeout = 6000
        $req = [System.Text.Encoding]::ASCII.GetBytes("GET http://$HostName$Path HTTP/1.1`r`nHost: $HostName`r`nUser-Agent: EnvProxyCheck`r`nConnection: close`r`n`r`n")
        $stream.Write($req, 0, $req.Length)
        $stream.Flush()
        $buf = New-Object byte[] 1024
        $sb = New-Object System.Text.StringBuilder
        while ($sb.ToString() -notmatch "\r\n\r\n") {
            $n = $stream.Read($buf, 0, 1024)
            if ($n -le 0) { break }
            [void]$sb.Append([System.Text.Encoding]::ASCII.GetString($buf, 0, $n))
        }
        $resp = $sb.ToString()
        # 防御：CONNECT 式响应（"Connection Established"）不是 GET 请求的合法响应，
        # 说明对方不是真实转发代理（可能是残留进程/异常程序）→ 判定节点断
        if ($resp -match "Connection Established") { return $false }
        # 204 / 200 / 3xx = 节点通；502/504/超时/拒绝 = 节点断（内核可能仍活着）
        return ($resp -match "^\s*HTTP/1\.[01]\s+(204|200|30[0-9])")
    } catch {
        return $false
    } finally {
        if ($stream) { try { $stream.Close() } catch {} }
        if ($client) { try { $client.Close() } catch {} }
    }
}

# 真实节点连通性探测：快路优先 + 失败兜底，任一成功即判"通"。
# 这是区分"断开连接（内核仍活着）"与"正在翻墙"的唯一可靠手段
# （两者在端口监听层面完全一样）。
# 设计（动态自学习，不写死）：
#   快路：只测"上次成功的端点"——正常时毫秒级命中、流量最小（每次仅 1 个请求）。
#   兜底：快路失败（端点被干扰/挂掉）→ 并行探测其余全部跨域段端点，
#         任一成功即判通，并自动把该端点记为新的最优端点（下次走快路）。
#   这样：单个域段（如 Google 主域）整体抽风时，其余域段（gstatic/维基/推特等）
#         照样兜底证明"节点活着"，杜绝单域段盲区误删；且正常延迟/流量不受影响。
function Test-RealConnectivity([int]$Port) {
    # ---- 快路：只测上次成功的端点（正常路径，毫秒级，1 个请求）----
    $last = $script:LastGoodEndpoint
    if (Test-SingleEndpoint $Port $CheckEndpoints[$last].Host $CheckEndpoints[$last].Path) {
        return $true
    }

    # ---- 兜底：上次端点失败 → 并行探测其余全部端点（6 秒封顶）----
    $handler = $null
    $client = $null
    try {
        # HttpClient（.NET 内置，零依赖）：并发发起所有端点请求
        if (-not ("System.Net.Http.HttpClient" -as [type])) {
            Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
        }
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.UseProxy = $true
        $handler.Proxy = New-Object System.Net.WebProxy("http://127.0.0.1:$Port")
        $handler.AllowAutoRedirect = $false
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(6)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd("EnvProxyCheck")

        $tasks = @{}
        foreach ($i in 0..($CheckEndpoints.Count - 1)) {
            if ($i -eq $last) { continue }
            $e = $CheckEndpoints[$i]
            try { $tasks[$i] = $client.GetAsync("http://$($e.Host)$($e.Path)") } catch {}
        }
        $deadline = [DateTime]::Now.AddSeconds(6)
        while ($tasks.Count -gt 0 -and [DateTime]::Now -lt $deadline) {
            foreach ($k in @($tasks.Keys)) {
                $t = $tasks[$k]
                if ($t.IsCompleted) {
                    $ok = $false
                    try {
                        $resp = $t.Result
                        $code = [int]$resp.StatusCode
                        # 204 / 200 / 3xx = 节点通；502/504/超时/异常 = 节点断（内核可能仍活着）
                        if ($code -ge 200 -and $code -lt 400) { $ok = $true }
                        $resp.Dispose()
                    } catch { $ok = $false }
                    if ($ok) {
                        # 动态自学习：把兜底命中的端点记为新的最优端点（下次走快路）
                        $script:LastGoodEndpoint = $k
                        return $true
                    }
                    $tasks.Remove($k)
                }
            }
            if ($tasks.Count -gt 0) { Start-Sleep -Milliseconds 100 }
        }
        return $false
    } catch {
        # HttpClient 不可用等极端环境：回退串行 TCP 探测（原逻辑）
        foreach ($i in 0..($CheckEndpoints.Count - 1)) {
            if ($i -eq $last) { continue }
            if (Test-SingleEndpoint $Port $CheckEndpoints[$i].Host $CheckEndpoints[$i].Path) {
                $script:LastGoodEndpoint = $i
                return $true
            }
        }
        return $false
    } finally {
        if ($client) { try { $client.Dispose() } catch {} }
        if ($handler) { try { $handler.Dispose() } catch {} }
    }
}

# 节点连通性判定（15 秒节流 + 迟滞防抖）：
#   节流：真实探测产生一次外网请求（约 200 字节），15 秒最多探测一次。
#   迟滞：连续 2 次失败才判"断"（防止节点抖动/慢响应导致状态来回翻转）；
#         恢复则 1 次成功立即判"通"（重连要快）。
$script:LastNodeCheck = [datetime]::MinValue
$script:NodeAlive = $false
$script:NodeFailCount = 0

function Test-NodeAlive([int]$Port, [bool]$Force = $false) {
    if (-not $Force -and ((Get-Date) - $script:LastNodeCheck).TotalSeconds -lt 15) {
        return $script:NodeAlive
    }
    $script:LastNodeCheck = Get-Date
    $result = Test-RealConnectivity $Port
    if ($result) {
        $script:NodeFailCount = 0
        $script:NodeAlive = $true
    } else {
        $script:NodeFailCount++
        # Force 探测绕过迟滞立即生效（端口变化场景需真实判定）；否则连续 2 次失败才判死
        if ($Force -or ($script:NodeFailCount -ge 2)) {
            $script:NodeAlive = $false
        }
    }
    return $script:NodeAlive
}
# 当前真实状态："off" 或 "on:<端口>"
# 判定标准（三层，缺一不可）：
#   1) 端口在监听（内核活着）
#   2) CONNECT 握手成功（是 HTTP 代理——发现阶段已完成）
#   3) 真实请求打通外网（节点真通——"断开连接但内核仍活着"在此层被识别为 off）
# 性能：on 状态每轮只做轻量监听检查，节点验证带 15 秒节流（控制真实请求流量）。
#       off 状态轻量发现（毫秒级）；全端口批量探测每 10 轮（约 30 秒）一次。
$script:CachedPort = $null
$script:LastSeenPort = $null
$script:Round = 0

function Get-CurrentState {
    $script:Round++
    $port = $script:CachedPort

    if ($port) {
        if (Test-PortListening $port) {
            # 端口仍在监听：节点验证（15 秒节流，断开连接后内核仍活着时在此识别）
            if (Test-NodeAlive $port) { return "on:$port" }
            # 节点不通：视作关闭（删除变量恢复直连）
            $script:CachedPort = $null
            return "off"
        }
        # 端口停止：可能是"断开→改端口→重连"的过渡期，先睡 2 秒跳过
        Start-Sleep -Seconds 2
        $newPort = Get-ActiveProxyPort
        if ($newPort) {
            # 端口变化：立即真实验证节点（不等节流），改端口重连秒级恢复
            if (Test-NodeAlive $newPort -Force:$true) {
                $script:CachedPort = $newPort
                $script:LastSeenPort = $newPort
                return "on:$newPort"
            }
            return "off"
        }
        $script:CachedPort = $null
        $script:LastSeenPort = $null
        return "off"
    }

    # 无缓存（off 状态）：轻量发现；每 10 轮补一次全端口批量探测
    $fullScan = (($script:Round % 10) -eq 0)
    $newPort = Get-ActiveProxyPort -FullScan:$fullScan
    if ($newPort) {
        # 端口"从无到有"= 强信号（重连了）：立即真实验证，不等节流 → 秒级注入
        if ($script:LastSeenPort -ne $newPort) {
            $script:LastSeenPort = $newPort
            if (Test-NodeAlive $newPort -Force:$true) {
                $script:CachedPort = $newPort
                return "on:$newPort"
            }
            return "off"
        }
        # 端口一直存在（断开连接但内核活着的场景）：节流验证，防抖优先
        if (Test-NodeAlive $newPort) {
            $script:CachedPort = $newPort
            return "on:$newPort"
        }
    } else {
        $script:LastSeenPort = $null
    }
    return "off"
}

# ------------------------------------------------------------------------------
# 2. 读写用户级环境变量（注册表 HKCU\Environment，不需要管理员）
# ------------------------------------------------------------------------------
$ProxyVarNames = @("HTTP_PROXY","http_proxy","HTTPS_PROXY","https_proxy","ALL_PROXY","all_proxy","NO_PROXY","no_proxy","NODE_USE_ENV_PROXY")

function Get-EnvProxyValue {
    return [Environment]::GetEnvironmentVariable("HTTP_PROXY", "User")
}

function Set-UserEnvVars([string]$Port) {
    # 代理值统一用 http:// 协议写法：本地代理端口（MonoCloud/Clash 等）几乎都是
    # 混合端口，HTTP 与 SOCKS5 都能应答；而部分工具（如 dsh/新版 Node 系）只认
    # http:// 写法、不支持 socks5://（会提示不支持并跳过）。统一 http:// 兼容面最大。
    $http = "http://127.0.0.1:$Port"
    [Environment]::SetEnvironmentVariable("HTTP_PROXY",   $http,  "User")
    [Environment]::SetEnvironmentVariable("http_proxy",   $http,  "User")
    [Environment]::SetEnvironmentVariable("HTTPS_PROXY",  $http,  "User")
    [Environment]::SetEnvironmentVariable("https_proxy",  $http,  "User")
    [Environment]::SetEnvironmentVariable("ALL_PROXY",    $http,  "User")
    [Environment]::SetEnvironmentVariable("all_proxy",    $http,  "User")
    # 本机地址直连（与 README 变量表一致；大小写各一份：部分工具只认小写 no_proxy）
    [Environment]::SetEnvironmentVariable("NO_PROXY",     "localhost,127.0.0.1,::1", "User")
    [Environment]::SetEnvironmentVariable("no_proxy",     "localhost,127.0.0.1,::1", "User")
    # 让新版 Node 系工具的原生 fetch 也自动读环境变量代理（老版本自动忽略）
    [Environment]::SetEnvironmentVariable("NODE_USE_ENV_PROXY", "1", "User")
}

function Remove-UserEnvVars {
    foreach ($n in $ProxyVarNames) {
        [Environment]::SetEnvironmentVariable($n, $null, "User")
    }
}

# 把状态应用到系统（幂等：值已经正确就什么都不做）
function Apply-State([string]$state) {
    if ($state -eq "off") {
        if (Get-EnvProxyValue) {
            Remove-UserEnvVars
            Broadcast-EnvironmentChange
            Write-MonitorLog "代理已关闭 -> 已删除代理变量，恢复直连"
        }
    } else {
        $port = $state.Substring(3)
        $want = "http://127.0.0.1:$port"
        if ((Get-EnvProxyValue) -ne $want) {
            Set-UserEnvVars $port
            Broadcast-EnvironmentChange
            Write-MonitorLog "检测到本地代理端口 $port -> 已注入代理 $want"
        }
    }
}

# ------------------------------------------------------------------------------
# 3. 自启动（固定位置定位器架构，不需要管理员）
# ------------------------------------------------------------------------------
# 架构：Run 键 → 定位器（%LOCALAPPDATA%\EnvProxy\launcher.ps1，固定位置永不移动）
#               → 读注册表里的"脚本当前路径"记录 → 启动监控
#       文件夹被移动后，定位器发现记录失效 → 自动搜索新位置 → 更新记录 → 启动。
#       因此：移动文件夹后什么都不用点，下次开机自动完成重新定位。
$RunKeyPath       = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$RunKeyName       = "EnvProxyMonitor"
$ScriptPathRegKey = "HKCU:\Software\EnvProxy"
$LauncherDir      = Join-Path $env:LOCALAPPDATA "EnvProxy"
$LauncherPath     = Join-Path $LauncherDir "launcher.ps1"

# 定位器脚本内容（安装时写入固定位置，由本脚本生成，保证一致）
function Get-LauncherContent {
    return @'
# EnvProxy 登录定位器（由 envproxy.ps1 安装时生成，请勿手改）
$ErrorActionPreference = "SilentlyContinue"
$reg = "HKCU:\Software\EnvProxy"
$target = (Get-ItemProperty $reg -ErrorAction SilentlyContinue).ScriptPath

if (-not $target -or -not (Test-Path $target)) {
    # 记录失效（文件夹被移动/删除过）。先顺手清理旧位置的运行时残留：
    # 覆盖"移动后立刻关机"的场景（监控来不及自退，旧位置可能残留 monitor 目录/空壳）。
    if ($target) {
        $oldDir = Split-Path -Parent $target
        Remove-Item (Join-Path $oldDir "monitor") -Recurse -Force -ErrorAction SilentlyContinue
        $left = Get-ChildItem $oldDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $left) { Remove-Item $oldDir -Force -ErrorAction SilentlyContinue }
    }
    # 分层自动搜索新位置
    #   用户常用位置深搜 6 层；其他磁盘根浅搜 4 层。
    #   注意：不从用户目录根整体递归——AppData 等大目录会因权限问题中断遍历。
    $roots = @(
        @{ Path = "$env:USERPROFILE\Desktop";   Depth = 6 },
        @{ Path = "$env:USERPROFILE\Documents"; Depth = 6 },
        @{ Path = "$env:USERPROFILE\Downloads"; Depth = 6 },
        @{ Path = "$env:USERPROFILE\OneDrive";  Depth = 6 },
        @{ Path = "$env:USERPROFILE\.config";   Depth = 6 }
    )
    $sysRoot = "$($env:SystemDrive)\"
    Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.Root -ne $sysRoot } |
        ForEach-Object { $roots += @{ Path = $_.Root; Depth = 4 } }

    foreach ($r in $roots) {
        $candidates = @(Get-ChildItem -Path $r.Path -Recurse -Depth $r.Depth -Filter "envproxy.ps1" -ErrorAction SilentlyContinue)
        if ($candidates.Count -eq 0) { continue }
        # 活跃度排序：monitor\monitor.log 最近写入的优先。
        # 这样"真正在用的项目"永远胜出，用户复制的备份（无日志或日志陈旧）不会被误选。
        foreach ($c in $candidates) {
            $logPath = Join-Path (Split-Path -Parent $c.FullName) "monitor\monitor.log"
            $logTime = if (Test-Path $logPath) { (Get-Item $logPath).LastWriteTime } else { [datetime]::MinValue }
            $c | Add-Member -NotePropertyName EnvLogTime -NotePropertyValue $logTime -Force
        }
        $found = $candidates | Sort-Object EnvLogTime, LastWriteTime -Descending | Select-Object -First 1
        $target = $found.FullName
        break
    }
}
if (-not $target) { exit }

New-Item -Path $reg -Force -ErrorAction SilentlyContinue | Out-Null
Set-ItemProperty -Path $reg -Name "ScriptPath" -Value $target -ErrorAction SilentlyContinue

$running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match '-File\s+"[^"]*envproxy\.ps1"\s*$' }
if (-not $running) {
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden `
        -ArgumentList "-NoProfile","-WindowStyle","Hidden","-ExecutionPolicy","Bypass","-File","`"$target`""
}
'@
}

# 把定位器写到固定位置，并把 Run 键指向定位器
function Set-AutoRun {
    New-Item -Path $LauncherDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    Set-Content -Path $LauncherPath -Value (Get-LauncherContent) -Encoding UTF8 -ErrorAction Stop
    $launcherCmd = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $LauncherPath
    Set-ItemProperty -Path $RunKeyPath -Name $RunKeyName -Value $launcherCmd -ErrorAction Stop
}

function Remove-AutoRun {
    Remove-ItemProperty -Path $RunKeyPath -Name $RunKeyName -ErrorAction SilentlyContinue
}

# 记录"脚本当前路径"（监控启动时写入；定位器靠它快速找到脚本）
function Update-ScriptPathRecord {
    New-Item -Path $ScriptPathRegKey -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $ScriptPathRegKey -Name "ScriptPath" -Value $PSCommandPath -ErrorAction SilentlyContinue
}

# 自启动自愈：定位器文件丢失或 Run 键损坏时自动重建修复（每 60 秒自查一次）
function Repair-AutoRun {
    try {
        $expected = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $LauncherPath
        $actual = (Get-ItemProperty $RunKeyPath -ErrorAction SilentlyContinue).$RunKeyName
        if (-not (Test-Path $LauncherPath) -or $actual -ne $expected) {
            New-Item -Path $LauncherDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
            Set-Content -Path $LauncherPath -Value (Get-LauncherContent) -Encoding UTF8 -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $RunKeyPath -Name $RunKeyName -Value $expected -ErrorAction SilentlyContinue
            Write-MonitorLog "已自动修复开机自启动（定位器/自启动项损坏）"
        }
    } catch {}
}

# ------------------------------------------------------------------------------
# 4. 监控进程管理（PID 文件 + 优雅停止标志 + 兜底强杀）
# ------------------------------------------------------------------------------
# 脚本目录（三阶兜底，任何调用方式都不脆弱）：
#   1) $PSScriptRoot       —— 正常 -File 执行（监控/安装/停止全是这种）
#   2) $PSCommandPath      —— 个别特殊调用
#   3) 当前工作目录        —— 最后兜底
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
             else { (Get-Location).Path }

# 所有运行时文件集中放 monitor\ 子文件夹（log / pid / stop 标志），
# 卸载时整目录删除，一个都不残留。
$MonitorDir = Join-Path $ScriptDir "monitor"
$PidFile    = Join-Path $MonitorDir "monitor.pid"
$StopFlag   = Join-Path $MonitorDir "stop.flag"

function Ensure-MonitorDir {
    try { New-Item -Path $MonitorDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
}

function Get-MonitorProcess {
    # 先按 PID 文件（校验命令行确实是本脚本，防止 PID 被系统复用而误杀他人）
    if (Test-Path $PidFile) {
        try {
            $pid2 = [int]((Get-Content $PidFile -Raw -ErrorAction Stop).Trim())
            if ($pid2 -ne $PID) {
                $w = Get-CimInstance Win32_Process -Filter "ProcessId=$pid2" -ErrorAction SilentlyContinue
                if ($w -and $w.CommandLine -match '-File\s+"[^"]*envproxy\.ps1"\s*$') { return $w }
            }
        } catch {}
    }
    # 再按命令行特征兜底：
    # 监控进程的特征 = 命令行以 -File "...envproxy.ps1" 结尾（不带任何子命令）
    # 这样执行 -Status / -Install 等命令的进程不会被误认，自身也被排除
    return Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $PID -and
            $_.CommandLine -match '-File\s+"[^"]*envproxy\.ps1"\s*$'
        } | Select-Object -First 1
}

function Start-Monitor([bool]$Force = $false) {
    $existing = Get-MonitorProcess
    if ($existing) {
        # 已有监控在跑：
        #   - Force（安装场景）：无条件重启，保证运行中的监控永远是当前脚本的最新代码
        #   - 非 Force 且路径一致：幂等跳过（重复点安装零副作用）
        #   - 非 Force 且路径不一致：旧位置的监控（文件夹被移动过）：先停掉旧的，再启动新的
        # 注意：用 IndexOf 而非 -like——-like 会把路径里的 [ ] 当通配符误判
        $samePath = ($existing.CommandLine.IndexOf($PSCommandPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
        if (-not $Force -and $samePath) {
            Write-Host "监控进程已在运行（路径一致），跳过启动。" -ForegroundColor Yellow
            return
        }
        Write-Host $(if ($Force) { "正在重启监控以加载当前最新代码..." } else { "检测到旧位置的监控进程，正在迁移到当前路径..." }) -ForegroundColor Yellow
        Stop-Monitor
    }
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden `
        -ArgumentList "-NoProfile","-WindowStyle","Hidden","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`""
    Write-Host "监控进程已启动。" -ForegroundColor Green
}

function Stop-Monitor {
    $w = Get-MonitorProcess
    if (-not $w) { Write-Host "监控进程未在运行。" -ForegroundColor Yellow; return }
    # 从目标监控的命令行动态解析它的脚本位置 → 把停止标志写到"它自己"的 monitor 目录。
    # 处理文件夹被移动/复制后新旧位置不一致的场景：让旧位置的监控优雅退出，而非强杀。
    $targetDir = $MonitorDir
    if ($w.CommandLine -match '-File\s+"([^"]*envproxy\.ps1)"') {
        $targetDir = Join-Path (Split-Path -Parent $Matches[1]) "monitor"
    }
    $targetFlag = Join-Path $targetDir "stop.flag"
    # 1) 优雅：写停止标志，监控进程 2 秒内自行退出
    try {
        New-Item -Path $targetDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        Set-Content -Path $targetFlag -Value "stop" -Encoding ASCII -ErrorAction Stop
    } catch {}
    $deadline = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-MonitorProcess)) { break }
        Start-Sleep -Milliseconds 300
    }
    # 2) 兜底：还没退就强杀，并等待充分时间确保进程彻底消亡 + 互斥锁释放
    #    （防止迁移场景下"新监控启动时旧监控还没死透"的竞态）
    $w2 = Get-MonitorProcess
    if ($w2) {
        Stop-Process -Id $w2.ProcessId -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
    Remove-Item $targetFlag -Force -ErrorAction SilentlyContinue
    Remove-Item $StopFlag -Force -ErrorAction SilentlyContinue
    # 跨位置停止的零残留：若停止标志写在"别的" monitor 目录、且该目录已空
    # （旧监控退出时已清理自己的 pid/flag），则把这个重建的空目录一并移除
    if ($targetDir -ne $MonitorDir) {
        $left = Get-ChildItem $targetDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $left) {
            Remove-Item -Path $targetDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "监控进程已停止。" -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# 5. 日志（只记状态翻转，不刷屏；超过 200KB 自动截断）
# ------------------------------------------------------------------------------
$LogFile = Join-Path $MonitorDir "monitor.log"

function Write-MonitorLog([string]$msg) {
    try {
        Ensure-MonitorDir
        $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
        # 共享写模式（FileShare.ReadWrite）：Add-Content 会延迟释放句柄导致锁冲突，
        # 改用共享文件流后，任何进程（含监控自身截断）互不阻塞，零锁脆弱点。
        $fs = [System.IO.File]::Open($LogFile, [System.IO.FileMode]::Append,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($line + "`r`n")
            $fs.Write($bytes, 0, $bytes.Length)
        } finally { $fs.Dispose() }
        # 体积上限：超过 200KB 截断为最近 200 行（黑匣子保留近期窗口，永远不会无限增长）
        # 截断同样用共享模式；万一失败（极端外部锁），静默跳过、下次再试——绝不中断监控
        # 注意：读取必须显式 UTF8 —— 默认按 ANSI 读会乱码，且截断时把乱码写回损坏日志
        $fi = Get-Item $LogFile -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 200KB) {
            $keep = Get-Content $LogFile -Tail 200 -Encoding UTF8
            $fs2 = [System.IO.File]::Open($LogFile, [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try {
                $bytes2 = [System.Text.Encoding]::UTF8.GetBytes(($keep -join "`r`n") + "`r`n")
                $fs2.Write($bytes2, 0, $bytes2.Length)
            } finally { $fs2.Dispose() }
        }
    } catch {}
}

# ------------------------------------------------------------------------------
# 6. 监控主循环（事件驱动 + 双轮确认去抖，无频繁写操作）
# ------------------------------------------------------------------------------
function Run-MonitorLoop {
    # 单实例互斥：重复启动自动退出
    $mutex = New-Object System.Threading.Mutex($false, "Global\EnvProxyMonitorSingleton")
    if (-not $mutex.WaitOne(0)) { return }

    Remove-Item $StopFlag -Force -ErrorAction SilentlyContinue
    Ensure-MonitorDir
    try { Set-Content -Path $PidFile -Value $PID -Encoding ASCII } catch {}
    Update-ScriptPathRecord
    Write-MonitorLog "==== 监控启动 ===="

    # 启动立即对齐：不等去抖，当场校正环境变量。
    # 关键场景：关机前没退出翻墙软件 → 重启后环境变量残留死端口 →
    # 监控一启动就立即清掉残留（恢复直连）或注入正确值，闭环无窗口期。
    $lastState    = $null
    $pendingState = $null
    $pendingCount = 0
    $repairRound  = 0
    $selfExit     = $false
    try {
        $bootState = Get-CurrentState
        Apply-State $bootState
        $lastState = $bootState
    } catch {
        Write-MonitorLog "启动对齐异常: $($_.Exception.Message)"
    }

    while (-not (Test-Path $StopFlag)) {
        # 自退检测：脚本文件不存在 = 文件夹被移动/删除 → 旧位置不再需要本监控。
        # 静默退出并清理旧位置的一切运行时痕迹（下次开机定位器会从新位置启动）。
        if (-not (Test-Path $PSCommandPath)) { $selfExit = $true; break }
        try {
            $state = Get-CurrentState

            if ($state -ne $lastState) {
                # 状态疑似翻转：连续确认 2 轮才动手，杜绝抖动
                if ($state -eq $pendingState) { $pendingCount++ } else { $pendingState = $state; $pendingCount = 1 }
                if ($pendingCount -ge 2) {
                    Apply-State $state
                    $lastState = $state
                    $pendingState = $null
                    $pendingCount = 0
                }
            } else {
                $pendingState = $null
                $pendingCount = 0
            }

            # 每 30 轮自愈一次自启动配置（定位器/自启动项损坏时自动修复）
            $repairRound++
            if ($repairRound -ge 30) {
                $repairRound = 0
                Repair-AutoRun
            }

            # 节奏差异化：on 状态 2 秒一轮（响应快）；off 状态 3 秒一轮（省资源）
            $sleepSec = $(if ($lastState -eq "off") { 3 } else { 2 })
            Start-Sleep -Seconds $sleepSec
        } catch {
            # 任何单轮异常都不致命：记日志、等 5 秒、继续下一轮（自愈）
            Write-MonitorLog "检测异常: $($_.Exception.Message)"
            Start-Sleep -Seconds 5
        }
    }

    if ($selfExit) {
        # 文件夹被移动/删除：静默自退，旧位置零残留。
        # 注意竞态：移动瞬间若恰好写日志，Ensure-MonitorDir 会重建旧位置目录。
        # 因此：删 monitor 目录后，若脚本目录只剩空壳（无任何其他文件）→ 一并删除，
        # 确保旧位置完全消失（下次移回时 Move-Item 不会因空壳而嵌套）。
        try {
            Remove-Item -Path $MonitorDir -Recurse -Force -ErrorAction SilentlyContinue
            $left = Get-ChildItem $ScriptDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $left) {
                Remove-Item -Path $ScriptDir -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    } else {
        Write-MonitorLog "==== 监控退出（收到停止信号）===="
        try { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue } catch {}
        try { Remove-Item $StopFlag -Force -ErrorAction SilentlyContinue } catch {}
    }
    $mutex.ReleaseMutex()
}

# ------------------------------------------------------------------------------
# 7. 子命令实现
# ------------------------------------------------------------------------------
function Install-EnvProxy {
    Write-Host "======== EnvProxy 安装 ========" -ForegroundColor Cyan
    Set-AutoRun
    Write-Host "[1/2] 开机自启动：已写入（固定定位器架构）" -ForegroundColor Green
    Update-ScriptPathRecord
    Start-Monitor -Force:$true
    Write-Host "[2/2] 监控进程：已启动" -ForegroundColor Green
    # 立即对齐环境变量状态：有代理 → 注入；无代理 → 清理残留死变量
    # （不等监控的双轮去抖，"安装"即"一键修复"）
    Apply-State (Get-CurrentState)
    Start-Sleep -Seconds 1
    Write-Host ""
    Show-Status
    Write-Host ""
    Write-Host "提示：之后【新打开】的终端/程序自动获得代理；" -ForegroundColor Yellow
    Write-Host "      已经开着的旧窗口不会自动变化，重开一个即可。" -ForegroundColor Yellow
}

function Uninstall-EnvProxy([bool]$Purge = $false) {
    Write-Host "======== EnvProxy 卸载（一键恢复原状）========" -ForegroundColor Cyan
    Stop-Monitor
    Remove-AutoRun
    Remove-Item -Path $ScriptPathRegKey -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $LauncherPath -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $LauncherDir -Force -ErrorAction SilentlyContinue
    # 日志去留：黑匣子保留还是彻底删除？
    #   - 交互模式（双击 3-一键恢复.cmd）：询问用户，默认保留
    #   - 自动化模式（-Uninstall -Purge）：直接彻底删除，不询问
    $removeLog = $Purge
    if (-not $Purge) {
        try {
            $choice = Read-Host "历史日志 monitor\monitor.log 是否保留？[Y] 保留（默认） / [N] 彻底删除"
            if ($choice -match '^[Nn]') { $removeLog = $true }
        } catch {
            # 无交互环境（管道/后台调用）：安全默认 = 保留日志
            $removeLog = $false
        }
    }
    if ($removeLog) {
        # 彻底清除：连历史日志一起删（黑匣子也不要了）
        Remove-Item -Path $MonitorDir -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        # 保留历史日志（黑匣子，便于日后排查），只删运行时临时文件
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
        Remove-Item $StopFlag -Force -ErrorAction SilentlyContinue
        # 若无日志可留（从未运行过），空目录一并移除，不留任何痕迹
        $hasContent = Get-ChildItem $MonitorDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $hasContent) {
            Remove-Item -Path $MonitorDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    # 卸载验尸：确保监控彻底死透——否则它的自愈机制会在 60 秒后重建自启动（复活）
    # 这里再查一次并强杀兜底，堵死"卸载后复活"的唯一理论路径
    $ghost = Get-MonitorProcess
    if ($ghost) {
        Stop-Process -Id $ghost.ProcessId -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
    Remove-UserEnvVars
    Broadcast-EnvironmentChange
    Write-Host "[完成] 监控已停、自启动已删、定位器已清、代理变量已清除。" -ForegroundColor Green
    if ($removeLog) {
        Write-Host "        历史日志已一并彻底删除。" -ForegroundColor Green
    } else {
        Write-Host "        历史日志保留在 monitor\monitor.log（黑匣子，供日后排查）。" -ForegroundColor Yellow
    }
    Write-Host "        电脑已恢复到安装前的状态，无需重启。" -ForegroundColor Green
}

function Show-Status {
    Write-Host "======== EnvProxy 状态 ========" -ForegroundColor Cyan

    $m = Get-MonitorProcess
    if ($m) { Write-Host ("监控进程 : 运行中 (PID {0})" -f $m.ProcessId) -ForegroundColor Green }
    else    { Write-Host "监控进程 : 未运行" -ForegroundColor Yellow }

    $run = (Get-ItemProperty $RunKeyPath -ErrorAction SilentlyContinue).$RunKeyName
    if ($run) { Write-Host "开机自启 : 已启用" -ForegroundColor Green }
    else      { Write-Host "开机自启 : 未启用" -ForegroundColor Yellow }

    $port = Get-ActiveProxyPort
    if ($port) {
        Write-Host ("翻墙代理 : 已开启（本地端口 {0} 监听中）" -f $port) -ForegroundColor Green
    } else {
        Write-Host "翻墙代理 : 未检测到（当前无翻墙代理在运行）" -ForegroundColor Yellow
    }

    $cur = Get-EnvProxyValue
    if ($cur) { Write-Host ("代理变量 : 已注入 ({0})" -f $cur) -ForegroundColor Green }
    else      { Write-Host "代理变量 : 无（直连状态）" -ForegroundColor DarkGray }

    # 版本信息（只读：查不到只提示，不断言、不写文件、不提问）
    $localVer = Get-LocalVersion
    if ($localVer) { Write-Host ("本地版本 : v{0}" -f $localVer) -ForegroundColor Green }
    else           { Write-Host "本地版本 : 未知" -ForegroundColor Yellow }
    $remoteVer = Get-RemoteVersion
    if ($remoteVer) {
        Write-Host ("最新版本 : {0}" -f $remoteVer.Tag) -ForegroundColor Green
        if ($localVer -and ((Compare-Versions $remoteVer.Version $localVer) -le 0)) {
            Write-Host "更新状态 : 已是最新" -ForegroundColor Green
        } elseif ($localVer) {
            Write-Host "更新状态 : 发现新版，用 5-检查更新 可升级" -ForegroundColor Yellow
        } else {
            Write-Host "更新状态 : 可用 5-检查更新 升级" -ForegroundColor Yellow
        }
    } else {
        Write-Host "最新版本 : 检查失败（网络不可达，稍后重试）" -ForegroundColor Yellow
        Write-Host "更新状态 : 未知" -ForegroundColor DarkGray
    }

    Write-Host "---------------- 最近日志 ----------------" -ForegroundColor Cyan
    if (Test-Path $LogFile) {
        Get-Content $LogFile -Tail 3 -Encoding UTF8 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    } else {
        Write-Host "  （暂无日志）" -ForegroundColor DarkGray
    }
    Write-Host "==================================" -ForegroundColor Cyan
}

# ------------------------------------------------------------------------------
# 8. 在线更新（检查更新 + 一键升级；状态显示只读，动手只在这里）
# ------------------------------------------------------------------------------
# 更新源：GitHub Release（releases/latest → 标签源码包整包覆盖）。
#   不用 git pull（用户机器未必有 git）、不用单文件拉取（新版增删文件会漏）。
#   上游默认与 README 克隆地址同源；有 .git 时优先从 git remote 解析
#   （fork 后 git-clone 的机器自动跟自己的 Release 走）。
$UpdateRepoDefault = "FiretrUCK666/envproxy"

function Get-UpdateRepo {
    try {
        $url = (git config --get remote.origin.url 2>$null)
        if ($url -and ($url -match 'github\.com[:/]([^/]+)/([^/\s]+)')) {
            $repo = $Matches[2] -replace '\.git$',''
            if ($Matches[1] -and $repo) { return ("{0}/{1}" -f $Matches[1], $repo) }
        }
    } catch {}
    return $UpdateRepoDefault
}

function Get-LocalVersion {
    try {
        $root = Split-Path -Parent $ScriptDir
        $vf = Join-Path $root "VERSION"
        if (Test-Path $vf) { return ((Get-Content $vf -Raw -Encoding UTF8 -ErrorAction Stop).Trim()) }
    } catch {}
    return ""
}

# 版本比较：按 . 分段逐段数值比（"1.10" > "1.9"；字符串比会错）。
# 返回 1（A 新）/ 0（相等）/ -1（A 旧）。
# 注意：PowerShell 变量名不分大小写，$a 即 $A（[string] 参数），赋值会被转回字符串，
# 因此循环变量必须另起名（$va/$vb），否则逐段数值比会退化成字符串比（"10" < "9"）。
function Compare-Versions([string]$A, [string]$B) {
    $pa = @(); $pb = @()
    foreach ($s in ($A -split '\.')) { if ($s -match '(\d+)') { $pa += [int]$Matches[1] } else { $pa += 0 } }
    foreach ($s in ($B -split '\.')) { if ($s -match '(\d+)') { $pb += [int]$Matches[1] } else { $pb += 0 } }
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $va = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
        $vb = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
        if ($va -gt $vb) { return 1 }
        if ($va -lt $vb) { return -1 }
    }
    return 0
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

# 带代理兜底的 HTTPS 下载文件：成功返回 $true。
function Save-UpdateFile([string]$Url, [string]$DestFile) {
    if (Save-UpdateFileVia $Url $DestFile "") { return $true }
    $port = $null
    try { $port = Get-ActiveProxyPort -FullScan:$false } catch {}
    if (-not $port) { try { $port = Get-ActiveProxyPort -FullScan:$true } catch {} }
    if ($port) { return (Save-UpdateFileVia $Url $DestFile "$port") }
    return $false
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
        $task = $client.GetByteArrayAsync($Url)
        if (-not $task.Wait(60000)) { return $false }
        [System.IO.File]::WriteAllBytes($DestFile, $task.Result)
        return $true
    } catch { return $false }
    finally {
        if ($client) { try { $client.Dispose() } catch {} }
        if ($handler) { try { $handler.Dispose() } catch {} }
    }
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
        Write-Host "请稍后重试；翻墙开/关换个状态再试一次也常有效。" -ForegroundColor Yellow
        return
    }
    Write-Host ("最新版本 : {0}" -f $remote.Tag) -ForegroundColor Green
    if ($local -and ((Compare-Versions $remote.Version $local) -le 0)) {
        Write-Host "已是最新，无需更新。" -ForegroundColor Green
        return
    }
    # 防呆：点的是备份文件夹时警告（正式路径以注册表记录为准）
    $regPath = $null
    try { $regPath = (Get-ItemProperty $ScriptPathRegKey -ErrorAction SilentlyContinue).ScriptPath } catch {}
    if ($regPath -and (("$regPath").ToLower() -ne ("$PSCommandPath").ToLower())) {
        Write-Host ("注意：你现在点的是 [{0}]，" -f $PSCommandPath) -ForegroundColor Yellow
        Write-Host ("但正式安装在 [{0}]。" -f $regPath) -ForegroundColor Yellow
        Write-Host "继续会更新【当前这个文件夹】并把它切换为正式安装。" -ForegroundColor Yellow
    }
    if (-not $AutoYes) {
        $answer = ""
        try { $answer = Read-Host ("发现新版 {0}，是否更新？[y/N]" -f $remote.Tag) } catch { $answer = "" }
        if ($answer -notmatch '^[Yy]') { Write-Host "已取消，未做任何改动。" -ForegroundColor Yellow; return }
    }
    # 下载标签源码包（整包，防漏文件）
    $repo = Get-UpdateRepo
    $zipUrl = "https://codeload.github.com/{0}/zip/refs/tags/{1}" -f $repo, $remote.Tag
    # DIVERGE(Win): Win 取 zip + Expand-Archive；Mac 取 tar.gz + tar（见 envproxy.sh）。
    $tmpBase = Join-Path ([System.IO.Path]::GetTempPath()) ("EnvProxyUpdate-" + ($remote.Tag -replace '[^A-Za-z0-9._-]','_'))
    $zipFile = "$tmpBase.zip"
    $extractDir = "${tmpBase}-src"
    try {
        Write-Host "正在下载新版..." -ForegroundColor Cyan
        Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path $extractDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        if (-not (Save-UpdateFile $zipUrl $zipFile)) { throw "下载失败（网络不可达），未做任何改动。" }
        Write-Host "正在解压并校验..." -ForegroundColor Cyan
        Expand-Archive -Path $zipFile -DestinationPath $extractDir -Force -ErrorAction Stop
        $top = Get-ChildItem $extractDir -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
        $srcRoot = if ($top) { $top.FullName } else { $extractDir }
        $srcVer = ""
        try { $srcVer = ((Get-Content (Join-Path $srcRoot "VERSION") -Raw -Encoding UTF8 -ErrorAction Stop).Trim()) } catch {}
        if (-not $srcVer -or ($srcVer -ne $remote.Version)) { throw "校验失败（包内 VERSION 与目标版本不一致），未做任何改动。" }
        if (-not (Test-Path (Join-Path $srcRoot "win\envproxy.ps1"))) { throw "校验失败（包内缺核心文件），未做任何改动。" }
        # 停监控 → 字节覆盖（跳过 monitor，保日志）→ 走一次万能修复收尾
        Write-Host "正在安装新版（保留日志，原监控先停）..." -ForegroundColor Cyan
        Stop-Monitor
        $projectRoot = Split-Path -Parent $ScriptDir
        foreach ($item in (Get-ChildItem $srcRoot -Force -ErrorAction Stop)) {
            if ($item.Name -eq ".git") { continue }
            if ($item.PSIsContainer) {
                $dest = Join-Path $projectRoot $item.Name
                New-Item -Path $dest -ItemType Directory -Force -ErrorAction Stop | Out-Null
                foreach ($child in (Get-ChildItem $item.FullName -Force -ErrorAction Stop)) {
                    # win\monitor / mac\monitor：本机运行时黑匣子，永不覆盖
                    if ($child.Name -eq "monitor") { continue }
                    Copy-Item $child.FullName $dest -Recurse -Force -ErrorAction Stop
                }
            } else {
                Copy-Item $item.FullName $projectRoot -Force -ErrorAction Stop
            }
        }
        Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        Install-EnvProxy
        Write-Host ("已更新到 {0}。" -f $remote.Tag) -ForegroundColor Green
    } catch {
        Write-Host ("更新失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
        Write-Host "当前旧版未被破坏，可稍后重试；着急就手动下载覆盖后点一次 1-安装。" -ForegroundColor Yellow
        try { Remove-Item $zipFile -Force -ErrorAction SilentlyContinue } catch {}
        try { Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
}

# ------------------------------------------------------------------------------
# 9. 入口分派
# ------------------------------------------------------------------------------
if ($Update) {
    Update-EnvProxy -AutoYes:$Yes
    return
}
if ($Install) {
    Install-EnvProxy
    return
}
if ($Uninstall) {
    Uninstall-EnvProxy -Purge:$Purge
    return
}
if ($Stop) {
    Stop-Monitor
    Remove-UserEnvVars
    Broadcast-EnvironmentChange
    Write-Host "代理变量已清除，当前恢复直连。" -ForegroundColor Cyan
    return
}
if ($Status) {
    Show-Status
    return
}
# 无参数 = 监控模式（由开机自启调用）
Run-MonitorLoop
