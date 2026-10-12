# ==============================================================================
#  envproxy.ps1 — 命令行自动翻墙（Windows 原生，零依赖，通用版）
# ------------------------------------------------------------------------------
#  子命令（双击配套 .cmd，或在 PowerShell 里运行）：
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Install             一键安装
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Stop                停止监控并删变量
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Uninstall           一键恢复（问日志留不留）
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Uninstall -Purge    一键恢复并连日志一起删（不问）
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Status              查看状态
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Update              检查更新（问过才装）
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Update -Yes         检查更新并跳过确认（供脚本调用）
#     无参数（由开机自启调用）                                                   进入监控模式
#
#  运行环境：Windows 10/11 自带 PowerShell 5.1。不需要 Node/Python/管理员。
#
#  原理（通用，不绑定任何特定翻墙软件）：
#     监控进程每 2-3 秒探测一次"本机是否有 HTTP 代理端口正在监听"（on 态 2 秒、off 态 3 秒）。
#     发现来源（两层，与系统代理/PAC/Core 完全无关，只认端口本身）：
#       1) 快路径：常见翻墙软件默认端口扫描（$KnownProxyPorts，可自行增删）
#       2) 万能路径：全端口扫描 + CONNECT 握手探测（进程名预筛提速）
#           → 随便改端口、随便换软件，都能自动发现，不写死任何东西
#     状态翻转（开/关/换端口）时才写一次用户级环境变量并广播刷新。
#     状态稳定时什么都不写 —— 不存在"反复监测反复断连"。
#
#  行为保证：
#     - 翻墙软件断开/重连/退出/重启/换端口/换软件 → 监控自动跟随，无需任何操作
#     - 退出翻墙软件后约 5 秒删除代理变量；"断开连接"（内核仍活着）以流量真相判定，约 30 秒
#       （本地代理响应挂起、探测跑满超时时最坏约 45 秒）
#     - 整个文件夹移动 → 无需任何操作（监控自退 + 定位器开机自动重新定位；
#       自动搜索只覆盖"用户目录 + 其他磁盘根"，搬到范围外时双击一次"安装"接管）
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
# 本表只是"常见入站口"的提速提示：命中它省一轮全端口兜底，不命中也不影响覆盖面。
# 收录标准：能过 CONNECT 门、且可能拿去注入（http:// 方案）的口才值得收；
# 纯 SOCKS 口（如 Surge 6153、mihomo socks-port 7891、Netch 2801）刻意不收——
# 过不了握手门，列进去只是每轮多一次注定失败的本机握手。已在表内的不动（判决走握手门，无害）。
$KnownProxyPorts = @(7078, 7890, 7897, 10808, 10809, 10801, 2080, 2081, 1080, 8118, 8080, 6152, 8888, 12334)  # 12334 = Hiddify-Next 默认

# 翻墙软件进程名特征（用于快速预筛，缩小 CONNECT 探测范围）。可自行扩展。
# 注意：此列表只影响"速度"不影响"覆盖面"——即使进程名不在列表里，
#       第二轮的"全端口 CONNECT 探测"也能发现它（见 Find-CandidatePorts）。
# 不认品牌、不认版本：mihomo-party/flclash 已被 mihomo/clash 命中；
# Stash/Quantumult X 默认 Network Extension 模式、不产生本地口，故不单列。
$ProxyProcessPatterns = @("monocloud", "clash", "mihomo", "verge", "v2ray", "xray",
    "sing-box", "singbox", "hiddify", "shadowsocks", "ss-local", "trojan", "hysteria",
    "neko", "netch", "surge", "outline")

# ------------------------------------------------------------------------------
# 0.5 文件与路径的唯一入口（治本：所有读写都从这里走，内部一律 -LiteralPath）
# 使用者能给安装文件夹改名，名字里可能出现 [ ] * ? 这类字符——在 PowerShell 里它们是通配符，
# 直接用 Test-Path / Get-Content / Remove-Item 会出现"文件明明在、却说不存在"，甚至删错对象。
# 因此凡是路径可能来自用户环境的读写（安装根、注册表记录、命令行、搜索结果），
# 一律走下面四个函数；新代码直接调它们就不会踩到通配符语义。
# 门禁会扫描"关键 cmdlet 是否直接吃裸变量路径"，绕过去当场失败。
# ------------------------------------------------------------------------------
function Test-Item([string]$Path) {
    if (-not $Path) { return $false }
    try { return [bool]([System.IO.File]::Exists($Path) -or [System.IO.Directory]::Exists($Path)) } catch { return $false }
}
function Read-Text([string]$Path) {
    # 读文本：显式 UTF-8，绝不交给系统代码页去猜（中文 Windows 上会读成乱码）
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}
function Write-Text([string]$Path, [string]$Text, [bool]$WithBom = $false) {
    # 原子写：先写同目录临时文件，再整体替换——中途断电也不会留下半个文件。
    # 需要 BOM 的地方（PowerShell 5.1 要认的脚本）由调用方显式声明，不靠编辑器的默认行为。
    $dir = Split-Path -Parent $Path
    if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [System.IO.Directory]::CreateDirectory($dir) | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($WithBom)
    $tmp = "$Path.tmp$PID"
    [System.IO.File]::WriteAllText($tmp, $Text, $enc)
    if ([System.IO.File]::Exists($Path)) {
        try { [System.IO.File]::Replace($tmp, $Path, $null) }
        catch { [System.IO.File]::Copy($tmp, $Path, $true); [System.IO.File]::Delete($tmp) }
    } else {
        [System.IO.File]::Move($tmp, $Path)
    }
}
function Remove-ItemSafe([string]$Path) {
    if (-not $Path) { return }
    try {
        if ([System.IO.Directory]::Exists($Path)) { [System.IO.Directory]::Delete($Path, $true) }
        elseif ([System.IO.File]::Exists($Path)) { [System.IO.File]::Delete($Path) }
    } catch {}
}

function Test-PortListening([int]$Port) {
    # 命令本身可能不可用（被裁剪的系统、极老版本）：-ErrorAction 拦不住 CommandNotFoundException，
    # 必须包 try，否则 -Install 与监控主循环都会被一条终端命令打断（与 Find-CandidatePorts 同一套处理）。
    for ($i = 0; $i -lt 2; $i++) {
        try { return [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop) } catch {}
    }
    return $false
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
# 两阶段都用"同时开工 + 统一截止"：连接阶段总共最多等 800ms，
# 读响应阶段总共最多等 500ms（谁先回 200 就用谁），耗时不再随端口数线性增长。
function Test-HttpProxyBatch([int[]]$Ports) {
    $pending = @()
    foreach ($p in $Ports) {
        $c = $null
        try {
            $c = New-Object System.Net.Sockets.TcpClient
            $ar = $c.BeginConnect("127.0.0.1", $p, $null, $null)
            $pending += [PSCustomObject]@{ Port = $p; Client = $c; Async = $ar }
        } catch { try { if ($c) { $c.Close() } } catch {} }
    }
    if ($pending.Count -eq 0) { return $null }
    # 阶段 1：并发连接，统一截止 800ms（逐个 IsCompleted 轮询，无 64 句柄上限问题）
    $deadline = [DateTime]::UtcNow.AddMilliseconds(800)
    do {
        $allDone = $true
        foreach ($item in $pending) {
            if (-not $item.Async.IsCompleted) { $allDone = $false; break }
        }
        if ($allDone) { break }
        Start-Sleep -Milliseconds 20
    } while ([DateTime]::UtcNow -lt $deadline)
    $connected = @()
    foreach ($item in $pending) {
        if (-not $item.Async.IsCompleted) { continue }
        try { $item.Client.EndConnect($item.Async); $connected += $item } catch {}
    }
    # 阶段 2：已连接端口同时发 CONNECT、同时读响应，统一截止 500ms
    $reads = @()
    foreach ($item in $connected) {
        try {
            $c = $item.Client
            $s = $c.GetStream()
            $req = [System.Text.Encoding]::ASCII.GetBytes("CONNECT 127.0.0.1:9 HTTP/1.1`r`nHost: 127.0.0.1:9`r`n`r`n")
            $s.Write($req, 0, $req.Length)
            $s.Flush()
            $buf = New-Object byte[] 512
            $rar = $s.BeginRead($buf, 0, 512, $null, $null)
            $reads += [PSCustomObject]@{ Item = $item; Stream = $s; Buffer = $buf; Async = $rar }
        } catch {}
    }
    $winner = $null
    $remain = @($reads)
    $deadline = [DateTime]::UtcNow.AddMilliseconds(500)
    while ($null -eq $winner -and $remain.Count -gt 0 -and ([DateTime]::UtcNow -lt $deadline)) {
        $next = @()
        foreach ($r in $remain) {
            if ($r.Async.IsCompleted) {
                try {
                    $n = $r.Stream.EndRead($r.Async)
                    if ($n -gt 0) {
                        $resp = [System.Text.Encoding]::ASCII.GetString($r.Buffer, 0, $n)
                        if ($resp -match "^\s*HTTP/1\.[01]\s+200") { $winner = $r.Item.Port; break }
                    }
                } catch {}
            } else {
                $next += $r
            }
        }
        if (($null -eq $winner) -and ($next.Count -gt 0)) { Start-Sleep -Milliseconds 20 }
        $remain = $next
    }
    if ($null -ne $winner) {
        foreach ($item in $pending) { try { $item.Client.Close() } catch {} }
        return $winner
    }
    foreach ($item in $pending) { try { $item.Client.Close() } catch {} }
    return $null
}

# 候选集发现（有序去重，本机零流量）：先已知端口（按表顺序），再可疑进程端口
# （数字排序），最后按需追加全端口批量探测的尾巴。全部过 CONNECT 握手门——
# 握手不过的（开发服务器、纯 SOCKS 口、认证口）进不了集合。
# 返回 [int[]]，可能为空。调用方（状态机）按集合签名判断变化并逐个试活；
# 只要首选不要全集的调用方继续用 Get-ActiveProxyPort（取第一个）。
function Find-CandidatePorts([bool]$FullScan = $true) {
    $ordered = @()
    # 端口枚举失败 ≠ 本机没有端口：失败的后果是候选集为空 → 调用方两轮后判 off 并删变量。
    # 所以这里先做一次即时重试，仍失败就留一条日志（可诊断），再按原行为继续——
    # 偶发抖动因此不会翻转状态，而"真的枚举不了"这种系统性问题会在日志里现形。
    $listeners = @()
    $enumerated = $false
    for ($attempt = 0; $attempt -lt 2 -and -not $enumerated; $attempt++) {
        try {
            $listeners = Get-NetTCPConnection -State Listen -ErrorAction Stop
            $enumerated = $true
        } catch {
            if ($attempt -eq 0) { Start-Sleep -Milliseconds 300 }
        }
    }
    if (-not $enumerated) { try { Write-MonitorLog "端口枚举失败（两次都没成功）-> 本轮按无端口处理" } catch {} }
    try {
        $listening = @($listeners.LocalPort | Sort-Object -Unique)

        # 来源 1（快路径）：常见端口扫描——绝大多数翻墙软件的默认端口，秒级命中
        foreach ($p in $KnownProxyPorts) {
            if (($listening -contains $p) -and ($ordered -notcontains $p)) {
                if (Test-HttpProxy $p) { $ordered += $p }
            }
        }

        # 来源 2 第一轮：疑似翻墙软件的进程监听的端口（始终执行，覆盖 99% 常见软件）
        # 注意：此列表只影响"速度"不影响"覆盖面"——即使进程名不在列表里，
        #       第二轮的"全端口 CONNECT 探测"也能发现它（见下）。
        $procMap = @{}
        Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $procMap[$_.Id] = $_.ProcessName.ToLower() }
        $suspectPorts = @()
        foreach ($l in ($listeners | Where-Object { $_.LocalAddress -in @("127.0.0.1", "::1", "0.0.0.0", "::") })) {
            $pname = $procMap[$l.OwningProcess]
            if (-not $pname) { continue }
            foreach ($pat in $ProxyProcessPatterns) {
                if ($pname -like "*$pat*") { $suspectPorts += $l.LocalPort; break }
            }
        }
        foreach ($p in ($suspectPorts | Sort-Object -Unique)) {
            if ($ordered -notcontains $p) {
                if (Test-HttpProxy $p) { $ordered += $p }
            }
        }

        # 来源 2 第二轮：兜底——所有监听端口并行批量握手探测（进程名无特征也能发现）。
        # 仅在 FullScan 时执行（批量探测约 1 秒，off 状态降频调用以省资源）。
        # 批量探测一旦有结果就立刻返回（不等其余探针跑完），所以一次只带回一个端口：
        # 候选集里有它，试活层就能收敛到它；其余同为代理的端口要等下一次集合变化或全扫再验。
        # 覆盖面上限是"同时开两个都不在常见表里的代理软件，只认其中一个"——够用，
        # 因为只要有一个可用端口，注入就是正确的。
        if ($FullScan) {
            $restPorts = @()
            foreach ($lp in $listening) {
                if ($ordered -notcontains $lp) { $restPorts += $lp }
            }
            if ($restPorts.Count -gt 0) {
                $tail = Test-HttpProxyBatch ($restPorts | Sort-Object -Unique)
                if ($tail -and ($ordered -notcontains $tail)) { $ordered += $tail }
            }
        }
    } catch {}
    return $ordered
}

# 组合发现（薄封装）：只要首选不要全集的调用方（状态显示、更新走代理）继续调这个，
# 语义与平台无关（第一个候选或 $null）。状态机走集合 + 试活，不调这个。
# FullScan 控制是否启用昂贵的全端口批量探测（off 状态降频用）。
function Get-ActiveProxyPort([bool]$FullScan = $true) {
    $cands = Find-CandidatePorts -FullScan:$FullScan
    if ($cands -and ($cands.Count -gt 0)) { return $cands[0] }
    return $null
}

# 有序试活：按候选顺序逐个验证，返回第一个真活的端口或 $null（只读，不写状态）。
# 规则只有两条：
#   1) $Preferred（上次验活过、仍在集合里）先按该端口自己的节流缓存试
#      （窗口内零新增探测，绝不会读到别的端口的结论）；
#   2) 其余一律当场验（Force）。集合抖动但首选仍活时，不烧探测、不改状态。
function Confirm-CandidatePort([int[]]$Candidates, $Preferred) {
    if (-not $Candidates -or ($Candidates.Count -eq 0)) { return $null }
    if (($null -ne $Preferred) -and ($Candidates -contains $Preferred)) {
        try { if (Test-NodeAlive ([int]$Preferred)) { return ([int]$Preferred) } } catch {}
    }
    foreach ($p in $Candidates) {
        if (($null -ne $Preferred) -and ($p -eq $Preferred)) { continue }
        try { if (Test-NodeAlive ([int]$p) -Force:$true) { return ([int]$p) } } catch {}
    }
    return $null
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
            # ResponseHeadersRead：只等响应头，不缓冲正文。探测只关心状态码，
            # 流量预算（每端口 15 秒最多一次、每次不足 1KB）靠这条成立——
            # 正文一个字节都不读，端点将来换成大响应也不会改变流量口径。
            try { $tasks[$i] = $client.GetAsync("http://$($e.Host)$($e.Path)", [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead) } catch {}
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
#   节流：真实探测产生一次外网请求（约 200 字节），每端口 15 秒最多探测一次。
#   迟滞：连续 $NodeFailThreshold 次失败才判"断"；恢复则 1 次成功立即判"通"
#         并把失败计数清零，使偶发抖动不累积成"断"。
# 迟滞必须不对称（这不是可调口味，是判据本身）：判"断"的代价是「删变量 + 全系统广播」，
# 影响机器上每一个应用；误留代理变量的代价只是多等一会儿。两个代价不对称，判据就不许对称——
# 一次探测不通不等于代理没了。另一侧的反向约束同样成立："通"要快（1 次成功即认），
# 否则重连后要白等一个迟滞窗口。
# 阈值只是"调参"，改它不动机制；判定仍走三层验证，不许绕过计数改单次判定。
# 分槽：节流缓存按端口分槽（哈希表）——同端口读缓存，换端口一律重验。
# 多候选试活时，绝不会读到别的端口的旧结论（全局单槽在此会串味）。
# DIVERGE(Win): Mac 侧 bash 3.2 无关联数组，只记最近一个槽位（见 test_node_alive）；
# 行为契约一致（同端口节流、异端口重验）。$script:LastGoodEndpoint 两侧都保持全局
# （只是快路提示，猜错最多浪费一次探测，不影响正确性）。
$script:NodeState = @{}
$NodeCheckThrottleSec = 15
$NodeFailThreshold    = 3

function Test-NodeAlive([int]$Port, [bool]$Force = $false) {
    $st = $script:NodeState["$Port"]
    if (-not $st) {
        $st = @{ LastCheck = [datetime]::MinValue; Alive = $false; FailCount = 0 }
        $script:NodeState["$Port"] = $st
    }
    if (-not $Force) {
        $age = ((Get-Date) - $st.LastCheck).TotalSeconds
        if ($age -lt $NodeCheckThrottleSec) { return $st.Alive }
    }
    $st.LastCheck = Get-Date
    $result = Test-RealConnectivity $Port
    if ($result) {
        $st.FailCount = 0
        $st.Alive = $true
    } else {
        $st.FailCount++
        # Force 探测绕过迟滞立即生效（端口变化场景需真实判定）；否则连续 $NodeFailThreshold 次失败才判死
        if ($Force -or ($st.FailCount -ge $NodeFailThreshold)) {
            $st.Alive = $false
        }
    }
    return $st.Alive
}
# 当前真实状态："off" 或 "on:<端口>"
# 判定标准（三层，缺一不可）：
#   1) 端口在监听（内核活着）
#   2) CONNECT 握手成功（是 HTTP 代理——发现阶段已完成）
#   3) 真实请求打通外网（节点真通——"断开连接但内核仍活着"在此层被识别为 off）
# 性能：on 状态每轮只做轻量监听检查，节点验证带 15 秒节流（控制真实请求流量）。
#       off 状态轻量发现（毫秒级）；全端口批量探测每 10 轮（约 30 秒）一次。
$script:CachedPort = $null
$script:LastSeenSet = ""
$script:LastAlivePort = $null
$script:Round = 0

function Get-CurrentState {
    $script:Round++
    $port = $script:CachedPort

    if ($port) {
        if (Test-PortListening $port) {
            # 在位复核（约每 10 轮一次，本机零流量）：代理退出后若有别的程序
            # 占了同一端口，握手不过立即丢缓存，不等 15 秒节点节流。
            # 返回的 off 照常进调用方的双轮去抖，不会单轮抖动。
            if ((($script:Round % 10) -eq 0) -and (-not (Test-HttpProxy $port))) {
                $script:CachedPort = $null
                return "off"
            }
            # 端口仍在监听：节点验证（15 秒节流，断开连接后内核仍活着时在此识别）
            if (Test-NodeAlive $port) { return "on:$port" }
            # 节点不通：视作关闭（删除变量恢复直连）
            $script:CachedPort = $null
            return "off"
        }
        # 端口停止：可能是"断开→改端口→重连/换软件"的过渡期，先睡 2 秒跳过
        Start-Sleep -Seconds 2
        $cands = Find-CandidatePorts -FullScan:$true
        $script:LastSeenSet = ($cands -join ",")
        $hit = Confirm-CandidatePort $cands $null   # 旧首选已停，直接走全集
        if ($hit) {
            # 过渡后首个验活：立即采用（不等节流），改端口/换软件秒级恢复
            $script:CachedPort = $hit
            $script:LastAlivePort = $hit
            return "on:$hit"
        }
        $script:CachedPort = $null
        return "off"
    }

    # 无缓存（off 状态）：轻量候选集；每 10 轮补一次全端口批量尾巴
    $fullScan = (($script:Round % 10) -eq 0)
    $cands = Find-CandidatePorts -FullScan:$fullScan
    $sig = ($cands -join ",")
    if ($sig -ne $script:LastSeenSet) {
        # 集合变化 = 强信号（新到、离开、换端口、增减成员）：走一遍有序试活。
        # 上次验活的仍在就认回它（缓存结论，零新增探测）；新面孔当场验 → 秒级收敛。
        $script:LastSeenSet = $sig
        $pref = $script:LastAlivePort
        if (($null -ne $pref) -and ($cands -notcontains $pref)) { $pref = $null }
        $hit = Confirm-CandidatePort $cands $pref
        if ($hit) {
            $script:CachedPort = $hit
            $script:LastAlivePort = $hit
            return "on:$hit"
        }
        return "off"
    }
    # 集合稳定：节流单查（上次验活的优先，否则第一个），防抖优先。
    # 不变量：on 只可能来自本轮候选集——候选集是过了"监听 + CONNECT 握手"两道门的，
    # 从集合之外挑端口（例如沿用上轮记住的端口）会给已经消失的端口报 on：
    # 既违反三层判据，又会在端口消失后反复清零调用方的去抖计数，
    # 把"退出软件后秒级删变量"拖成几十秒。故候选集为空 = 本机没有代理在监听，
    # 节点结论无从谈起，直接 off。
    $check = $null
    if ($cands.Count -gt 0) {
        $check = $script:LastAlivePort
        if (($null -eq $check) -or ($cands -notcontains $check)) { $check = $cands[0] }
    }
    if ($null -ne $check) {
        if (Test-NodeAlive ([int]$check)) {
            $script:CachedPort = $check
            $script:LastAlivePort = $check
            return "on:$check"
        }
    }
    return "off"
}

# ------------------------------------------------------------------------------
# 2. 读写用户级环境变量（注册表 HKCU\Environment，不需要管理员）
# ------------------------------------------------------------------------------
# 变量名一律用规范大写拼写；一张表同时是「注入清单」与「删除清单」，两者不可能再漂移。
#
# DIVERGE(Win): Windows 的环境命名空间大小写不敏感（注册表 HKCU\Environment 尤其如此），
# 同名不同大小写就是同一个变量：写两遍只会互相覆盖，注册表里始终只有一个键。
# 而"大小写各写一份"会在运行期留下**同名两种拼写的重复环境块**——.NET 系宿主按
# "大小写不敏感字典"建表时直接抛 "An item with the same key has already been added"，
# 连 Get-ChildItem Env: 都枚举不出来；子进程继续继承同一个块，一个终端窗口里跑的东西
# 一起中招。故 Windows 侧对一个逻辑变量只写一个规范拼写，共 5 个变量名。
# DIVERGE(Mac): macOS 的 launchctl 与环境块真大小写敏感，大小写各一份确有意义，Mac 侧写 9 个。
$ProxyVarNames = @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "NODE_USE_ENV_PROXY")

# 本机地址直连的默认例外集，写法遵循 NO_PROXY 的通行规范：IPv6 地址**裸写**。
# 裸写是各家的共同要求——httpx 的规范示例就是 `NO_PROXY=example.com,::1,localhost,...`，
# 而且它会自己给 IPv6 补上方括号去构造内部模式（见其 _utils.is_ipv6_hostname 分支）；
# 预先写成 `[::1]` 会被当成普通域名，生成非法模式，反而让每一次请求都抛
# `InvalidURL: Invalid port: ':1]'`。也就是说方括号属于 URL 字面量的写法，
# 在 NO_PROXY 里是写错了位置，不是"另一种合法写法"。
$DefaultNoProxy = "localhost,127.0.0.1,::1"

function Get-EnvProxyValue {
    return [Environment]::GetEnvironmentVariable($ProxyVarNames[0], "User")
}

# 小写化 + 去空白，用于合并去重（比较时大小写不敏感）
function Get-NormalizedNoProxyEntries([string]$Value) {
    $out = @()
    foreach ($part in ($Value -split ',')) {
        $t = $part.Trim()
        if ($t) { $out += $t.ToLowerInvariant() }
    }
    return $out
}

# NO_PROXY 只增不减：已存在的条目原样保留，缺失的默认条目补上。
# 这样做是因为环境变量是用户级共享资源——用户自己加的例外（公司内网等）与
# 别的工具写下的例外都必须留着，本工具只负责"本机地址一定直连"这一件事。
# 后果是两条：用户手动加例外不会被下一轮冲掉，也不会与轮次之间来回互相覆盖。
function Merge-NoProxy([string]$Existing, [string]$Default) {
    $parts = @()
    foreach ($p in ($Default -split ',')) { $t = $p.Trim(); if ($t) { $parts += $t } }
    $seen = Get-NormalizedNoProxyEntries $Default
    foreach ($p in ($Existing -split ',')) {
        $t = $p.Trim()
        if (-not $t) { continue }
        if ($seen -notcontains $t.ToLowerInvariant()) { $parts += $t; $seen += $t.ToLowerInvariant() }
    }
    return ($parts -join ',')
}

function Get-ProxyVarTable([string]$Port) {
    # 代理值统一用 http:// 协议写法：本地代理端口（MonoCloud/Clash 等）几乎都是
    # 混合端口，HTTP 与 SOCKS5 都能应答；而部分工具（如 dsh/新版 Node 系）只认
    # http:// 写法、不支持 socks5://（会提示不支持并跳过）。统一 http:// 兼容面最大。
    $http = "http://127.0.0.1:$Port"
    $table = [ordered]@{}
    foreach ($n in $ProxyVarNames) { $table[$n] = $http }
    # 本机地址直连（与 README 变量表一致）
    $table["NO_PROXY"] = $DefaultNoProxy
    # 让新版 Node 系工具的原生 fetch 也自动读环境变量代理（老版本自动忽略）
    $table["NODE_USE_ENV_PROXY"] = "1"
    return $table
}

function Sync-UserEnvVars([string]$Port) {
    # 幂等判据是**整套变量**是否都已就位，不是只看代理地址：
    # 只看地址会让"代理值对、但别的变量缺失或漂移"的半代理状态一直无人纠正。
    # 返回是否真的写了东西——调用方据此决定要不要广播（静默时零广播、零写入）。
    $desired = Get-ProxyVarTable $Port
    $existingNoProxy = [Environment]::GetEnvironmentVariable("NO_PROXY", "User")
    $desired["NO_PROXY"] = Merge-NoProxy $existingNoProxy $DefaultNoProxy
    $changed = $false
    foreach ($n in $desired.Keys) {
        if ([Environment]::GetEnvironmentVariable($n, "User") -ne $desired[$n]) { $changed = $true; break }
    }
    if (-not $changed) { return $false }
    foreach ($n in $desired.Keys) {
        [Environment]::SetEnvironmentVariable($n, $desired[$n], "User")
    }
    return $true
}

function Remove-UserEnvVars {
    # 注入与删除共用一张表，两者不可能漂移；再按名复查一遍，确保"按名之后确实一个都不剩"——
    # 无主残留正是"半代理"诡异行为的来源。
    #
    # 例外：只回收**本工具自己写下的** NO_PROXY / NODE_USE_ENV_PROXY。
    # 环境变量是用户级共享资源，用户或别的工具可能把这两项用于自己的用途；
    # 值不是我们写的那一个，就说明不是我们的东西，一律不动。
    $ours = $DefaultNoProxy
    foreach ($n in $ProxyVarNames) {
        $cur = [Environment]::GetEnvironmentVariable($n, "User")
        if (-not $cur) { continue }
        if ($n -eq "NO_PROXY") {
            # 只回收我们加进去的那几项：从当前值里逐项减掉默认集，剩下的原样写回（保留用户的写法与顺序），
            # 减空了才删变量。不能按"整份等于默认集"判断——用户原本就有 NO_PROXY 时，我们加的那几项
            # 会永远留在他的值里，回收不干净。
            $oursSet = Get-NormalizedNoProxyEntries $ours
            $keep = @()
            foreach ($part in ($cur -split ',')) {
                $t = $part.Trim()
                if (-not $t) { continue }
                if ($oursSet -contains $t.ToLowerInvariant()) { continue }
                $keep += $t
            }
            if ($keep.Count -eq 0) { [Environment]::SetEnvironmentVariable($n, $null, "User") }
            else { [Environment]::SetEnvironmentVariable($n, ($keep -join ','), "User") }
            continue
        }
        if ($n -eq "NODE_USE_ENV_PROXY") {
            if ($cur -eq "1") { [Environment]::SetEnvironmentVariable($n, $null, "User") }
            continue
        }
        if ($n -in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")) {
            # 归属判定：只有本机地址才是我们写下的，用户或公司工具写的其他地址一律不动。
            if ($cur -like "http://127.0.0.1:*") { [Environment]::SetEnvironmentVariable($n, $null, "User") }
            continue
        }
        [Environment]::SetEnvironmentVariable($n, $null, "User")
    }
}

# 我们该持有的那套变量现在还在不在。判据与 Remove-UserEnvVars 完全一致：
# 三个代理变量只要有一个还有值就算在，NO_PROXY 看有没有我们写的默认项，
# NODE_USE_ENV_PROXY 看值是不是我们写的 1。两边共用一套判据，才不会出现
# "删得掉但门槛没让它删"的残留（半代理）。
function Test-ProxyVarsPresent {
    $oursSet = Get-NormalizedNoProxyEntries $DefaultNoProxy
    foreach ($n in $ProxyVarNames) {
        $cur = [Environment]::GetEnvironmentVariable($n, "User")
        if (-not $cur) { continue }
        if ($n -eq "NO_PROXY") {
            foreach ($e in (Get-NormalizedNoProxyEntries $cur)) { if ($oursSet -contains $e) { return $true } }
            continue
        }
        if ($n -eq "NODE_USE_ENV_PROXY") { if ($cur -eq "1") { return $true }; continue }
        # 归属判定与删除同口径：别人的代理地址不算我们的痕迹。
        if ($cur -like "http://127.0.0.1:*") { return $true }
    }
    return $false
}

# 安装时快照原值（只记一次）：卸载时按快照还原，用户原来的配置不丢。
# 属于我们自己的值视为无（升级路径下安装时代理正开着，不能把刚写的值当成用户的）。
function Snapshot-PrevEnv {
    try {
        if (Get-Item -LiteralPath $PrevEnvRegKey -ErrorAction SilentlyContinue) { return }
        New-Item -Path $PrevEnvRegKey -Force -ErrorAction Stop | Out-Null
        foreach ($n in $ProxyVarNames) {
            $cur = [Environment]::GetEnvironmentVariable($n, "User")
            if (-not $cur) { continue }
            if ($n -eq "NODE_USE_ENV_PROXY" -and $cur -eq "1") { continue }
            if (($n -in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")) -and ($cur -like "http://127.0.0.1:*")) { continue }
            Set-ItemProperty -Path $PrevEnvRegKey -Name $n -Value $cur -ErrorAction SilentlyContinue
        }
    } catch {}
}

# 卸载时按快照还原用户原值，还原完删掉快照键。无快照时什么都不做。
function Restore-PrevEnv {
    try {
        if (-not (Get-Item -LiteralPath $PrevEnvRegKey -ErrorAction SilentlyContinue)) { return }
        foreach ($n in $ProxyVarNames) {
            $bak = (Get-ItemProperty -Path $PrevEnvRegKey -Name $n -ErrorAction SilentlyContinue).$n
            if ($null -ne $bak) { [Environment]::SetEnvironmentVariable($n, $bak, "User") }
        }
        Remove-Item -LiteralPath $PrevEnvRegKey -Recurse -Force -ErrorAction SilentlyContinue
    } catch {}
}

# 把状态应用到系统（幂等：整套变量都已就位就什么都不做）
function Apply-State([string]$state) {
    # 全局互斥：安装入口与监控主循环可能同一时刻各校正一次（点"安装"时两者都在跑），
    # 没有这把锁就会出现"两边都判定要写 → 重复写 + 重复广播"。锁只覆盖"判断 + 写入"这段，
    # 拿到锁的一方写完，另一方进来时看到已就位，自然什么都不做。
    # 拿不到锁也照常往下走：锁只是省一次重复广播，跳过写入反而会让变量停在错的状态。
    $gate = $null
    $held = $false
    try {
        $gate = New-Object System.Threading.Mutex($false, (Get-MutexName "EnvProxyApplyState"))
        $held = $gate.WaitOne(5000)
    } catch { $held = $false }
    try {
        if ($state -eq "off") {
            if (Test-ProxyVarsPresent) {
                Remove-UserEnvVars
                Broadcast-EnvironmentChange
                Write-MonitorLog "代理已关闭 -> 已删除代理变量，恢复直连"
            }
        } else {
            $port = $state.Substring(3)
            $want = "http://127.0.0.1:$port"
            if (Sync-UserEnvVars $port) {
                Broadcast-EnvironmentChange
                Write-MonitorLog "检测到本地代理端口 $port -> 已注入代理 $want"
            }
        }
    } finally {
        if ($gate) {
            try { if ($held) { $gate.ReleaseMutex() } } catch {}
            try { $gate.Dispose() } catch {}
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
# 用户原值快照：安装时记下被覆盖前的用户级代理变量，卸载时按快照还原。
# 与 $ScriptPathRegKey 父子关系——卸载清注册表键时连同删掉，不留痕迹。
$PrevEnvRegKey   = "HKCU:\Software\EnvProxy\Backup"
# 顶层取值必须加载期安全：CI 自检会在 Linux 上点源本文件测纯函数，
# 那里没有 LOCALAPPDATA。运行时只在 Windows 走，兜底值走不到业务逻辑。
$_localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [System.IO.Path]::GetTempPath() }
$LauncherDir      = Join-Path $_localAppData "EnvProxy"
$LauncherPath     = Join-Path $LauncherDir "launcher.ps1"

# 定位器脚本内容（安装时写入固定位置，由本脚本生成，保证一致）
function Get-LauncherContent {
    return @'
# EnvProxy 登录定位器（由 envproxy.ps1 安装时生成，请勿手改）
$ErrorActionPreference = "SilentlyContinue"
$reg = "HKCU:\Software\EnvProxy"
$target = (Get-ItemProperty $reg -ErrorAction SilentlyContinue).ScriptPath

if (-not $target -or -not (Test-Path -LiteralPath $target)) {
    # 记录失效（文件夹被移动/删除过）。先顺手清理旧位置的运行时残留：
    # 覆盖"移动后立刻关机"的场景（监控来不及自退，旧位置可能残留 monitor 目录/空壳）。
    if ($target) {
        $oldDir = Split-Path -Parent $target
        Remove-Item -LiteralPath (Join-Path $oldDir "monitor") -Recurse -Force -ErrorAction SilentlyContinue
        $left = Get-ChildItem -LiteralPath $oldDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $left) { Remove-Item -LiteralPath $oldDir -Force -ErrorAction SilentlyContinue }
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

    # 先把所有搜索根的结果汇总，再统一按活跃度排序（与 Mac 侧 locator.sh 同一算法）。
    # 不能"命中第一个根就收工"：那样排序只在一个根内成立，靠前的根（桌面/文稿/下载…）
    # 里放着的陈旧备份会压过其他盘里真正在用的正本——而"活跃度优先"正是
    # "备份目录不会被误选"的唯一依据。
    $candidates = @()
    foreach ($r in $roots) {
        $candidates += @(Get-ChildItem -LiteralPath $r.Path -Recurse -Depth $r.Depth -Filter "envproxy.ps1" -ErrorAction SilentlyContinue)
    }
    if ($candidates.Count -gt 0) {
        # 活跃度排序：monitor\monitor.log 最近写入的优先（无日志的排最后），
        # 同活跃度再看脚本本身的修改时间。这样"真正在用的项目"永远胜出，
        # 用户复制的备份（日志陈旧或没有日志）不会被误选。
        foreach ($c in $candidates) {
            $logPath = Join-Path (Split-Path -Parent $c.FullName) "monitor\monitor.log"
            $logTime = if (Test-Path -LiteralPath $logPath) { ([System.IO.FileInfo]$logPath).LastWriteTime } else { [datetime]::MinValue }
            $c | Add-Member -NotePropertyName EnvLogTime -NotePropertyValue $logTime -Force
        }
        $target = ($candidates | Sort-Object EnvLogTime, LastWriteTime -Descending | Select-Object -First 1).FullName
    }
}
if (-not $target) { exit }

New-Item -Path $reg -Force -ErrorAction SilentlyContinue | Out-Null
Set-ItemProperty -Path $reg -Name "ScriptPath" -Value $target -ErrorAction SilentlyContinue

# 监控进程识别判据：与核心脚本里的 $MonitorCmdLinePattern 保持同一语义。
# 这里必须写字面量——本模板是单引号 here-string，变量在生成时不会被展开，
# 写变量名会让生成的定位器引用一个未定义变量（空模式恒匹配，反而误判"监控已在跑"）。
$MonitorCmdLinePattern = '-File\s+"[^"]*envproxy\.ps1"\s*$'
$running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match $MonitorCmdLinePattern }
if (-not $running) {
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden `
        -ArgumentList "-NoProfile","-WindowStyle","Hidden","-ExecutionPolicy","Bypass","-File","`"$target`""
}
'@
}

# 把定位器写到固定位置，并把 Run 键指向定位器
function Set-AutoRun {
    New-Item -Path $LauncherDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    [System.IO.File]::WriteAllText($LauncherPath, (Get-LauncherContent), (New-Object System.Text.UTF8Encoding($true)))
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

# 自启动自愈：让固定位置的自启动配置**与当前代码生成的内容一致**——不只是"存在"。
# 判据是内容而非存在，理由是升级路径：改完脚本若没走"安装"，固定位置里留着的仍是
# 旧定位器（搜索算法、参数改了都不生效），旧的 Run 值也可能指向被删掉的路径。
# 每次自查 = 让系统状态收敛到当前代码，不依赖用户记得重装。
function Test-LauncherCurrent {
    try {
        if (-not (Test-Item $LauncherPath)) { return $false }
        # 行尾与首尾空白不比：落盘的行尾与源码里 here-string 的行尾
        # 不必逐字节相同，比"生成出来的代码"是否一致就够了。
        $want = (Get-LauncherContent) -replace "`r`n", "`n"
        $have = (Read-Text $LauncherPath) -replace "`r`n", "`n"
        return ($have.Trim() -eq $want.Trim())
    } catch { return $false }
}

function Repair-AutoRun {
    try {
        $expected = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $LauncherPath
        $actual = (Get-ItemProperty $RunKeyPath -ErrorAction SilentlyContinue).$RunKeyName
        if ((-not (Test-LauncherCurrent)) -or $actual -ne $expected) {
            New-Item -Path $LauncherDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
            [System.IO.File]::WriteAllText($LauncherPath, (Get-LauncherContent), (New-Object System.Text.UTF8Encoding($true)))
            Set-ItemProperty -Path $RunKeyPath -Name $RunKeyName -Value $expected -ErrorAction Stop
            # 写完必须读回：修没修成由复读决定，不由"我调用了写入"决定。
            $check = (Get-ItemProperty $RunKeyPath -ErrorAction Stop).$RunKeyName
            if (($check -eq $expected) -and (Test-LauncherCurrent)) {
                Write-MonitorLog "已自动修复开机自启动（定位器/自启动项缺失、损坏或与当前版本不一致）"
            } else {
                Write-MonitorLog "开机自启动修复失败：写入后读回不一致"
            }
        }
    } catch {
        try { Write-MonitorLog ("开机自启动修复失败：" + $_.Exception.Message) } catch {}
    }
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

# 监控进程的识别判据（唯一权威处，下面三处引用都指向它）：
# 监控进程的特征 = 命令行以 -File "...envproxy.ps1" 结尾、且不带任何子命令。
# 执行 -Status / -Install / -Stop 的进程带了子命令参数，故不会被误认；调用方自身另行排除。
# 收紧到行尾锚定是为了排除"命令行里恰好含 envproxy 字样"的其他进程（如带 -Command 的诊断调用）。
# DIVERGE(Mac): macOS 侧等价实现是 `pgrep -f "envproxy\.sh$"`（见 mac/locator.sh），语义相同。
$MonitorCmdLinePattern = '-File\s+"[^"]*envproxy\.ps1"\s*$'

function Get-MonitorProcess {
    # 先按 PID 文件（校验命令行确实是本脚本，防止 PID 被系统复用而误杀他人）
    if (Test-Item $PidFile) {
        try {
            $pid2 = [int]((Read-Text $PidFile).Trim())
            if ($pid2 -ne $PID) {
                $w = Get-CimInstance Win32_Process -Filter "ProcessId=$pid2" -ErrorAction SilentlyContinue
                if ($w -and $w.CommandLine -match $MonitorCmdLinePattern) { return $w }
            }
        } catch {}
    }
    # 再按命令行特征兜底：
    # 监控进程的特征 = 命令行以 -File "...envproxy.ps1" 结尾（不带任何子命令）
    # 这样执行 -Status / -Install 等命令的进程不会被误认，自身也被排除
    return Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $PID -and
            $_.CommandLine -match $MonitorCmdLinePattern
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
    # 启动完必须复查：子进程可能因抢不到单实例互斥而静默退出，
    # 此时再打印"已启动"就是假话。
    Start-Sleep -Seconds 2
    if (Get-MonitorProcess) {
        Write-Host "监控进程已启动。" -ForegroundColor Green
    } else {
        Write-Host "监控进程未能确认运行，请用 4-查看状态 核对（可能是另一个监控占着单实例锁）。" -ForegroundColor Yellow
    }
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
        Write-Text -Path $targetFlag -Text "stop"
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
    Remove-ItemSafe $targetFlag
    Remove-ItemSafe $StopFlag
    # 跨位置停止的零残留：若停止标志写在"别的" monitor 目录、且该目录已空
    # （旧监控退出时已清理自己的 pid/flag），则把这个重建的空目录一并移除
    if ($targetDir -ne $MonitorDir) {
        $left = Get-ChildItem -LiteralPath $targetDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $left) {
            Remove-Item -LiteralPath $targetDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (Get-MonitorProcess) {
        Write-Host "监控进程未能停止（请检查是否有别的窗口正在运行它）。" -ForegroundColor Yellow
    } else {
        Write-Host "监控进程已停止。" -ForegroundColor Green
    }
}

# ------------------------------------------------------------------------------
# 5. 日志（只记状态翻转，不刷屏；超过 200KB 自动截断）
# ------------------------------------------------------------------------------
$LogFile = Join-Path $MonitorDir "monitor.log"

function Write-MonitorLog([string]$msg) {
    try {
        Ensure-MonitorDir
        $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
        # 共享写模式（FileShare.ReadWrite）：多进程追加写入互不阻塞，零锁脆弱点。
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
        $fi = New-Object System.IO.FileInfo($LogFile)
        if ($fi.Exists -and $fi.Length -gt 200KB) {
            $keep = [System.IO.File]::ReadAllLines($LogFile, [System.Text.Encoding]::UTF8) | Select-Object -Last 200
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
    # 单实例互斥：重复启动自动退出。名字按用户隔离（见 Get-MutexName），
    # 同一台电脑多个账户各装一份时互不干扰。
    $mutex = New-Object System.Threading.Mutex($false, (Get-MutexName "EnvProxyMonitorSingleton"))
    if (-not $mutex.WaitOne(0)) {
        try { Write-MonitorLog "监控未启动：已有另一个监控进程在运行（单实例互斥）。" } catch {}
        return
    }

    Remove-ItemSafe $StopFlag
    Ensure-MonitorDir
    try { Write-Text -Path $PidFile -Text ([string]$PID) } catch {}
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

    while (-not (Test-Item $StopFlag)) {
        # 自退检测：脚本文件不存在 = 文件夹被移动/删除 → 旧位置不再需要本监控。
        # 静默退出并清理旧位置的一切运行时痕迹（下次开机定位器会从新位置启动）。
        if (-not $PSCommandPath -or -not (Test-Item $PSCommandPath)) { $selfExit = $true; break }
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

            # 每 30 轮自愈一次（轮间隔 on 2 秒 / off 3 秒 → 约 60–90 秒一次）。
            # 按轮计数而不是按秒：轮询节奏本身就是可变配置，写死秒数会随节奏改动而失准。
            $repairRound++
            if ($repairRound -ge 30) {
                $repairRound = 0
                Repair-AutoRun
                # 变量自检：Apply-State 只在状态翻转时动手，稳态下它永远不会被调用，
                # 于是"别的东西改坏了变量"没人纠正。这里按同一周期做一次整表核对：
                # on 态补齐缺失项，off 态把残留收干净——判据与删除侧同一套，
                # 幂等（齐了就零写入、零广播）。只核对我们本该持有的那几个，
                # 用户自己设的、与本工具无关的变量不受影响。
                if ($lastState -eq "off") {
                    if (Test-ProxyVarsPresent) {
                        Remove-UserEnvVars
                        Broadcast-EnvironmentChange
                        Write-MonitorLog "检测到代理变量残留 -> 已回收，恢复直连"
                    }
                } else {
                    # 自愈写入后也要广播：不广播的话已经运行的资源管理器/程序仍是旧环境，
                    # 与 Apply-State 就成了两套行为。写入成功才广播。
                    # 先判 "on:" 前缀：启动对齐若抛过异常，$lastState 仍是 $null，
                    # 直接 Substring 会抛异常、白记一条"检测异常"。
                    if ($lastState -and $lastState.StartsWith("on:")) {
                        if (Sync-UserEnvVars $lastState.Substring(3)) { Broadcast-EnvironmentChange }
                    }
                }
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
        # 文件夹被移动/删除：自退时没有活着的组件会再纠正变量，先把我们写的东西清掉
        # （新位置的监控会在秒级内按需重注），再清运行时目录与空壳。
        # 注意竞态：移动瞬间若恰好写日志，Ensure-MonitorDir 会重建旧位置目录。
        # 因此：删 monitor 目录后，若脚本目录只剩空壳（无任何其他文件）→ 一并删除，
        # 确保旧位置完全消失（下次移回时 Move-Item 不会因空壳而嵌套）。
        try { Apply-State "off" } catch {}
        try {
            Remove-Item -LiteralPath $MonitorDir -Recurse -Force -ErrorAction SilentlyContinue
            $left = Get-ChildItem -LiteralPath $ScriptDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $left) {
                Remove-Item -LiteralPath $ScriptDir -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    } else {
        Write-MonitorLog "==== 监控退出（收到停止信号）===="
        try { Remove-ItemSafe $PidFile } catch {}
        try { Remove-ItemSafe $StopFlag } catch {}
    }
    $mutex.ReleaseMutex()
}

# ------------------------------------------------------------------------------
# 7. 子命令实现
# ------------------------------------------------------------------------------
function Install-EnvProxy {
    Write-Host "======== EnvProxy 安装 ========" -ForegroundColor Cyan
    Set-AutoRun
    Write-Host "[1/3] 开机自启动：已写入（固定定位器架构）" -ForegroundColor Green
    Update-ScriptPathRecord
    Start-Monitor -Force:$true
    Write-Host "[2/3] 监控进程：已启动" -ForegroundColor Green
    # 立即对齐环境变量状态：有代理 → 注入；无代理 → 清理残留死变量
    # （不等监控的双轮去抖，"安装"即"一键修复"）
    # 先快照用户原值：之后卸载时按它还原，覆盖前留底。
    Snapshot-PrevEnv
    Apply-State (Get-CurrentState)
    Write-Host "[3/3] 环境变量：已按当前状态校正" -ForegroundColor Green
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
    # 先按快照还用户原值，再清注册表键（快照键在该键之下，顺序不能反）。
    Restore-PrevEnv
    Remove-Item -LiteralPath $ScriptPathRegKey -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $LauncherPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $LauncherDir -Force -ErrorAction SilentlyContinue
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
        # 刚杀掉的监控进程其文件锁可能还没释放：删三次再下定论，删不掉就由末尾的复检如实报告。
        for ($i = 0; $i -lt 3 -and (Test-Item $MonitorDir); $i++) {
            Remove-Item -LiteralPath $MonitorDir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Item $MonitorDir) { Start-Sleep -Milliseconds 500 }
        }
    } else {
        # 保留历史日志（黑匣子，便于日后排查），只删运行时临时文件
        Remove-ItemSafe $PidFile
        Remove-ItemSafe $StopFlag
        # 若无日志可留（从未运行过），空目录一并移除，不留任何痕迹
        $hasContent = Get-ChildItem -LiteralPath $MonitorDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $hasContent) {
            Remove-Item -LiteralPath $MonitorDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    # 卸载验尸：确保监控彻底死透——否则它的自愈机制会在下一个自查周期（约 60–90 秒）重建自启动（复活）
    # 这里再查一次并强杀兜底，堵死"卸载后复活"的唯一理论路径
    $ghost = Get-MonitorProcess
    if ($ghost) {
        Stop-Process -Id $ghost.ProcessId -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
    # 走 Apply-State 而不是裸调 Remove-UserEnvVars：拿写变量锁、判据与写入同源、写完广播。
    # 裸调会绕过锁，与监控自愈并发时可能留下半套变量。
    Apply-State "off"
    # 卸载末尾回读复检：上面每一步都可能静默失败，定论必须由复读结果决定。
    # DIVERGE(Win): 复检项按平台映射——Run 键对应 Mac 的 plist，
    # 注册表变量对应 proxy.env，其余同源。
    $dirty = @()
    try { $null = Get-ItemPropertyValue -Path $RunKeyPath -Name $RunKeyName -ErrorAction Stop; $dirty += "开机自启动项仍在" } catch {}
    if (Test-Item $LauncherPath) { $dirty += "定位器文件仍在" }
    if (Test-ProxyVarsPresent) { $dirty += "代理变量仍在" }
    if (Get-MonitorProcess) { $dirty += "监控进程仍在" }
    if ($removeLog -and (Test-Item (Join-Path $MonitorDir "monitor.log"))) { $dirty += "历史日志未能删除" }
    if ($dirty.Count -eq 0) {
        Write-Host "[完成] 监控已停、自启动已删、定位器已清、代理变量已清除。" -ForegroundColor Green
        if ($removeLog) {
            Write-Host "        历史日志已一并彻底删除。" -ForegroundColor Green
        } else {
            Write-Host "        历史日志保留在 monitor\monitor.log（黑匣子，供日后排查）。" -ForegroundColor Yellow
        }
        Write-Host "        电脑已恢复到安装前的状态，无需重启。" -ForegroundColor Green
    } else {
        Write-Host ("[未完成] 以下残留请手动处理：{0}" -f ($dirty -join "；")) -ForegroundColor Yellow
        Write-Host "        可再双击一次 3-一键恢复，或手动删除上述位置。" -ForegroundColor Yellow
    }
}

function Show-Status {
    Write-Host "======== EnvProxy 状态 ========" -ForegroundColor Cyan

    $m = Get-MonitorProcess
    if ($m) { Write-Host ("监控进程 : 运行中 (PID {0})" -f $m.ProcessId) -ForegroundColor Green }
    else    { Write-Host "监控进程 : 未运行" -ForegroundColor Yellow }

    $run = (Get-ItemProperty $RunKeyPath -ErrorAction SilentlyContinue).$RunKeyName
    if ($run) { Write-Host "开机自启 : 已启用" -ForegroundColor Green }
    else      { Write-Host "开机自启 : 未启用" -ForegroundColor Yellow }

    # 状态页只做快扫：全端口批量探测约 1 秒，放在只读的状态显示里太重。
    $port = Get-ActiveProxyPort -FullScan:$false
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
        if (Test-DevCopy) {
            Write-Host "更新状态 : 开发副本（更新走 git pull，本入口不改动文件）" -ForegroundColor DarkGray
        } elseif (-not $localVer) {
            Write-Host "更新状态 : 可点 5-检查更新 升级" -ForegroundColor Yellow
        } elseif ((Compare-Versions $localVer $remoteVer.Version) -gt 0) {
            Write-Host "更新状态 : 本地版本比最新发布版新" -ForegroundColor Green
        } elseif ((Compare-Versions $remoteVer.Version $localVer) -gt 0) {
            Write-Host "更新状态 : 发现新版，可点 5-检查更新 升级" -ForegroundColor Yellow
        } else {
            Write-Host "更新状态 : 已是最新" -ForegroundColor Green
        }
    } else {
        Write-Host "最新版本 : 检查失败（网络不可达或 GitHub API 限流，稍后重试）" -ForegroundColor Yellow
        Write-Host "更新状态 : 未知" -ForegroundColor DarkGray
    }

    Write-Host "---------------- 最近日志 ----------------" -ForegroundColor Cyan
    if (Test-Item $LogFile) {
        [System.IO.File]::ReadAllLines($LogFile, [System.Text.Encoding]::UTF8) | Select-Object -Last 3 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    } else {
        Write-Host "  （暂无日志）" -ForegroundColor DarkGray
    }
    Write-Host "==================================" -ForegroundColor Cyan
}

# ------------------------------------------------------------------------------
# 8. 在线更新（检查更新 + 一键升级；状态显示只读，动手只在这里）
# ------------------------------------------------------------------------------
# 更新源：GitHub Release 里的安装包资产（EnvProxy.zip；Mac 侧取 EnvProxy.tar.gz）。
#   安装包内容由仓库 .gitattributes 的 export-ignore 声明，发布流水线用 git archive 产出。
#   下载失败只提示确认 GitHub 可达后重试：镜像站只收录部分项目，加速代理属透明中转，
#   不硬编码任何第三方域名，不为它放宽校验。
#   判据是环境事实，不看是谁在用：
#     安装根有 .git = 开发副本 → 更新只读，不改动任何文件，提示走 git pull；
#     没有 .git     = 安装副本 → 下载安装包、校验、覆盖安装区。
#   读版本时开发副本跟自己的 git remote 走（fork 后看得到自己仓库的 Release）；
#   覆盖文件这条路上，git 副本一律不参与。
$UpdateRepoDefault = "FiretrUCK666/envproxy"

# 安装根有 .git（目录，或 worktree 的 .git 文件）= 开发副本。
function Test-DevCopy {
    $root = Split-Path -Parent $ScriptDir
    return (Test-Item (Join-Path $root ".git"))
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
    if (Test-DevCopy) {
        Write-Host "这是开发副本（安装根有 .git）：更新入口不改动任何文件。" -ForegroundColor DarkGray
        Write-Host "拉新代码请在仓库里执行：git pull" -ForegroundColor DarkGray
        return
    }
    # 本地版本读不到 = 安装区已经不完整（VERSION 是随包必带的文件）。
    # 此时任何"比较"都是瞎猜，直接拒绝并指一条明路，而不是继续往下走。
    if (-not $local) {
        Write-Host "本地版本未知（安装根缺少 VERSION 文件），不敢自动更新，未做任何改动。" -ForegroundColor Yellow
        Write-Host "请到 Releases 页面手动下载安装包覆盖一次，或双击 1-安装 修复。" -ForegroundColor Yellow
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
    if ($regPath -and (("$regPath").ToLower() -ne ("$PSCommandPath").ToLower())) {
        Write-Host ("注意：你现在点的是 [{0}]，" -f $PSCommandPath) -ForegroundColor Yellow
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
        # 收尾跑**安装根里**的新脚本（不是解压目录里那份）：只有从安装根执行，路径记录、自启动项与
        # 监控进程才会落在安装根，不会指向马上要被删掉的临时目录。带超时，卡住就报错而不是无声等待。
        $newScript = Join-Path $root "win\envproxy.ps1"
        # 先把操作锁交出去：收尾子进程跑的是同一个安装动作，它会自己去拿这把锁。
        if ($opMutex) { try { $opMutex.ReleaseMutex() } catch {}; $opMutex = $null }
        $rc = 1
        try {
            $proc = Start-Process -FilePath "powershell" -PassThru -NoNewWindow -ArgumentList @(
                "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$newScript`"", "-Install"
            )
            if ($proc.WaitForExit(120000)) { $rc = $proc.ExitCode }
            else { try { $proc.Kill() } catch {}; Write-Host "收尾超过 2 分钟没结束，已中止。" -ForegroundColor Yellow }
        } catch {
            Write-Host ("收尾没能启动：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
        if ($rc -ne 0) {
            # 收尾子进程失败/超时也不能把监控留在停用状态：文件已经覆盖完成，这里用当前进程
            # （旧代码）调一次安装，它会去安装根把**新脚本**拉起来，自启动项也会一起修好。
            Write-Host "收尾没走完，正在按新版本重启监控..." -ForegroundColor Yellow
            try { Install-EnvProxy | Out-Null } catch {}
            Write-Host "如果状态仍不对，请再双击一次 1-安装。" -ForegroundColor Yellow
        }
    } catch {
        Write-Host ("更新失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
        Write-Host "可稍后重试；也可以手动下载安装包覆盖后再点一次 1-安装。" -ForegroundColor Yellow
    } finally {
        try { Remove-ItemSafe $zipFile } catch {}
        # 解压目录在收尾完成后清理；收尾跑的是安装根里的新脚本，这里只是兜底删除。
        try { if (Test-Item $extractDir) { Remove-ItemSafe $extractDir } } catch {}
    }
}

# 校验安装包：包内 VERSION 与目标一致、两个平台的核心文件都在、两条编码红线没被改过。
# 任何一项不过就抛异常，调用方据此中止——安装区一个字节都不动。
function Test-Package([string]$Root, [string]$WantVersion) {
    $srcVer = ""
    try { $srcVer = ((Read-Text (Join-Path $Root "VERSION")).Trim()) } catch {}
    if (-not $srcVer -or ($srcVer -ne $WantVersion)) { throw "校验失败（包内 VERSION 与目标版本不一致），未做任何改动。" }
    $psFile = Join-Path $Root "win\envproxy.ps1"
    $shFile = Join-Path $Root "mac\envproxy.sh"
    if (-not (Test-Item $psFile) -or -not (Test-Item $shFile)) { throw "校验失败（包内缺核心文件），未做任何改动。" }
    $b = [System.IO.File]::ReadAllBytes($psFile)
    if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) { throw "校验失败（包内 win\envproxy.ps1 缺少 UTF-8 BOM），未做任何改动。" }
    $s = [System.IO.File]::ReadAllBytes($shFile)
    if ($s.Length -ge 3 -and $s[0] -eq 0xEF -and $s[1] -eq 0xBB -and $s[2] -eq 0xBF) { throw "校验失败（包内 mac\envproxy.sh 带了 BOM），未做任何改动。" }
    if ([System.Text.Encoding]::UTF8.GetString($s).Contains("`r`n")) { throw "校验失败（包内 mac\envproxy.sh 含 CRLF），未做任何改动。" }
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

# 覆盖安装区。边界三条：包内文件全部写入；win\monitor 与 mac\monitor 永不覆盖、永不删；
# 四个程序目录内、新包没有的文件按清单删除（旧按钮不会残留成"点了没反应"）。
# 安装根目录只覆盖同名文件，绝不删任何东西——根目录可能有用户自己的东西。
function Install-Package([string]$SrcRoot, [string]$ProjectRoot, [string]$Stage) {
    # $Stage 必填：没有它就没有备份，也就没有回滚——不留"可以无回滚地覆盖安装区"的口子。
    if (-not $Stage) { throw "内部错误：覆盖安装区必须提供备份目录（-Stage）。" }
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
            $srcFile = Join-Path $SrcRoot $rel
            if ($rel -ieq 'win\envproxy.ps1') {
                # 核心脚本必须原子替换：Copy-Item 先截断再写，中途断电会留下半截文件，
                # 而修复入口恰恰就是这个文件。temp + Replace 不存在中间状态。
                Write-Text -Path $dest -Text ([System.IO.File]::ReadAllText($srcFile, [System.Text.Encoding]::UTF8)) -WithBom $true
            } else {
                Copy-Item -LiteralPath $srcFile -Destination $dest -Force -ErrorAction Stop
            }
        }
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

# ------------------------------------------------------------------------------
# 9. 入口分派
# ------------------------------------------------------------------------------
# 操作锁：安装与更新会改同一批文件，同一时刻只允许一个在跑；撞上就直接退出、不做任何改动。
# 用命名互斥体：进程结束由系统自动释放，不需要（也不该）手工解锁。
function Get-MutexName([string]$Base) {
    # 互斥体按用户隔离：机器级 Global\ 配当前用户 SID。
    # 同一台电脑多个账户各装一份时互不干扰；同一用户多次登录共用同一把锁，单监控语义不变。
    # 拿不到 SID 就回落到无后缀（行为与过去一致），绝不因此罢工。
    try {
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if ($sid) { return ("Global\{0}-{1}" -f $Base, $sid) }
    } catch {}
    return ("Global\{0}" -f $Base)
}
function Get-OpLock {
    try {
        $m = New-Object System.Threading.Mutex($false, (Get-MutexName "EnvProxyInstallOp"))
        if (-not $m.WaitOne(0)) { return $null }
        return $m
    } catch { return $null }
}
function Exit-IfOpBusy {
    $m = Get-OpLock
    if (-not $m) {
        Write-Host "另一个安装/更新正在进行，请等它结束再试（没有做任何改动）。" -ForegroundColor Yellow
        exit 1
    }
    return $m
}
if ($Update) {
    $opMutex = Exit-IfOpBusy
    Update-EnvProxy -AutoYes:$Yes
    return
}
if ($Install) {
    $opMutex = Exit-IfOpBusy
    Install-EnvProxy
    return
}
if ($Uninstall) {
    $opMutex = Exit-IfOpBusy
    Uninstall-EnvProxy -Purge:$Purge
    return
}
if ($Stop) {
    $opMutex = Exit-IfOpBusy
    Stop-Monitor
    # 走 Apply-State 而不是裸调删除：拿写变量锁，与监控自愈互斥，不留半套变量。
    Apply-State "off"
    Write-Host "代理变量已清除，当前恢复直连。" -ForegroundColor Cyan
    return
}
if ($Status) {
    Show-Status
    return
}
# 无参数 = 监控模式（由开机自启调用）。
# 被点号引用（测试加载）时只定义函数、不进入监控。
if ($MyInvocation.InvocationName -eq '.') { return }
Run-MonitorLoop
