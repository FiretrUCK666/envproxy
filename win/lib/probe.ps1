# ==============================================================================
#  probe.ps1 — 探测层：端口发现、CONNECT 握手、真实节点连通、当前状态判定
#  判决三层缺一不可；进程名表与已知端口表只影响扫描速度，不影响覆盖面。
# ==============================================================================

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

# 把 netstat 的本地端点拆成地址与端口。
# IPv6 写成 "[::1]:445"（带方括号），IPv4 写成 "127.0.0.1:8080"（不带）——两种形态都要认。
# 拆不出合法端口就返回 $null（这一行当噪声丢掉，不影响别的行）。
function ConvertTo-ListenEndpoint([string]$Local) {
    $addr = ""
    $portText = ""
    if ($Local.StartsWith("[")) {
        $close = $Local.LastIndexOf("]")
        if ($close -lt 1) { return $null }
        $addr = $Local.Substring(1, $close - 1)
        $portText = $Local.Substring($close + 1)
        if (-not $portText.StartsWith(":")) { return $null }
        $portText = $portText.Substring(1)
    } else {
        $colon = $Local.LastIndexOf(":")
        if ($colon -lt 1) { return $null }
        $addr = $Local.Substring(0, $colon)
        $portText = $Local.Substring($colon + 1)
    }
    $port = 0
    if (-not [int]::TryParse($portText, [ref]$port)) { return $null }
    if ($port -lt 1 -or $port -gt 65535) { return $null }
    return @{ Address = $addr; Port = $port }
}

# 把 netstat -ano 的输出解析成监听口列表。
#
# 为什么单独成一个纯函数：解析要能被逐条钉死（多一列、状态带空格、被本地化、
# 一行 TCP 都没有），而"取值"要能被单独换掉（进程内 API / netstat / WMI 三层）。
# 两者混在一个函数里时，测试只能靠给外部命令打桩——而打桩又会被上层的新取值路径绕过去，
# 于是"测了解析"变成"测了个寂寞"。分开之后，解析可以拿一段固定的文本直接验，
# 与这台机器上有没有 netstat、走的是哪条路完全无关。
#
# 返回值：解析出的监听口列表（可能为空）。空 != 读不出来——读不出来的情况一律抛：
#   - 有 LISTENING 行却没解析出端口（行形状变了）
#   - 有 TCP 行但没有 LISTENING 行
#   - 一条 TCP 行都没有（协议列不是 TCP，说明拿到的根本不是 netstat 输出）
# 这三种都必须抛，不许返回空表：空表会被上层读成"本机没有端口在监听"→ 判 off →
# 把用户的代理变量删掉。解析失败绝不能长得像"没有端口"。
function ConvertFrom-NetstatOutput([string[]]$Raw) {
    $listeners = New-Object System.Collections.ArrayList
    $sawListening = $false
    $sawTcp = $false
    foreach ($line in $Raw) {
        # "有没有 TCP 行"必须**独立于**整行的解析结果来判断。
        # 若只有整行匹配上才置真，"行形状变了"会一行都匹配不上 → 直接返回空数组。
        # 宽松判据只认协议列（"TCP"这个 token 不会被本地化）。
        if ($line -match '^\s*TCP\s') { $sawTcp = $true }
        # 行尾**不锚定**：PID 之后允许还有列。
        # 为什么：Windows 更新可能给 netstat 加一列（历史上加过 InHost 那种）。
        # 锚定行尾的话，加一列就整行匹配不上 → 一个监听口都解析不出来 → 这一轮"读不出来"。
        # 而我们要的信息全在前 5 列里，多出来的列与我们无关，不该因此罢工。
        # 要求 PID 后面是空白或行尾，是为了不把 "LISTENING 6544abc" 这种半截数字当成 PID。
        if ($line -notmatch '^\s*TCP\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)(\s|$)') { continue }
        if ($Matches[3] -ne "LISTENING") { continue }
        $sawListening = $true
        $endpoint = ConvertTo-ListenEndpoint $Matches[1]
        if (-not $endpoint) { continue }
        [void]$listeners.Add([pscustomobject]@{
            LocalAddress  = $endpoint.Address
            LocalPort     = $endpoint.Port
            OwningProcess = [int]$Matches[4]
        })
    }
    if ($listeners.Count -gt 0) { return $listeners }
    if ($sawListening) { throw "netstat 有 LISTENING 行但没解析出端口（行形状变了）" }
    if ($sawTcp) { throw "netstat 有 TCP 行但没有 LISTENING 行（状态列可能被本地化了）" }
    throw "netstat 输出里没有 TCP 行（拿到的可能不是 netstat 的输出）"
}

# 列出本机所有处于监听状态的 TCP 连接。
# 返回与 Get-NetTCPConnection 同形的对象（LocalAddress / LocalPort / OwningProcess）。
#
# 三层取值，从"最不依赖外部环境"往"最依赖"排：
#   ① .NET 的 IPGlobalProperties.GetActiveTcpListeners() —— **进程内**，不起子进程、不读文本
#   ② netstat.exe —— 起一个外部进程 + 解析文本
#   ③ Get-NetTCPConnection —— WMI，最后兜底
#
# 为什么把 ① 提到第一层（这是这一版的关键修正）：
# ② 依赖三件事同时成立——那个 exe 真被调起来、输出没被安全软件吞掉、行格式与解析假设一致。
# 任何一件不成立，这一轮就"枚举失败"。实测踩过：常驻监控连续几十次失败，
# 而同一份代码在前台每次都正常——差别只在进程环境（PATH、安全软件注入、句柄配额）。
# ① 不碰这三件事：它就在当前进程里问操作系统要一张表，实测平均 1.2 毫秒
# （netstat 27 毫秒起，还要加上建进程和解析），并且实测 62 个监听口与 netstat 逐项一致、
# IPv4 与 IPv6 都覆盖（47 + 15）。
#
# ③ 与 ① 不是一回事：③ 是 PowerShell 的 Get-NetTCPConnection（要拉起 WMI，实测 1.7–2.3 秒），
# ① 是 .NET 原生接口（同一个信息，不用 WMI）。两者被当成一件事时，"必须起外部进程"
# 就成了唯一选择——而它正是"在别人机器上悄悄失效"的那一类。
#
# PID 不是必需项：只有"按进程名提速"那一步要用它，而那一步只是加速（见 Find-CandidatePorts
# 里的两轮来源）。所以 ① 不带 PID 完全够用；需要 PID 时再单独取一次（只在候选端口不空时）。
function Get-ListeningTcpConnections {
    # ---- ① 进程内 .NET 接口 ----
    $apiWhy = ""
    try {
        $eps = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        if ($eps -and @($eps).Count -gt 0) {
            $list = New-Object System.Collections.ArrayList
            foreach ($e in $eps) {
                [void]$list.Add([pscustomobject]@{
                    LocalAddress  = $e.Address.ToString()
                    LocalPort     = [int]$e.Port
                    # 0 = 未知。调用方按"拿不到 PID"处理，不许当成"属于 0 号进程"。
                    OwningProcess = 0
                })
            }
            return $list
        }
        # 一个监听口都没有：可能是真的没有（此时下面两条路也会给出同样的答案），
        # 也可能是这台系统的 NET 实现拿不到。留个原因，继续往下试——宁可多花 30 毫秒，
        # 也不要在"其实有代理"的机器上把空表当成结论。
        $apiWhy = "GetActiveTcpListeners 返回空（$([System.Environment]::OSVersion.Version)）"
    } catch {
        $apiWhy = "GetActiveTcpListeners 失败：" + $_.Exception.Message
    }

    # ---- ② netstat.exe ----
    # 必须用全量 -ano（**不带** -p TCP）：-p TCP 只回 IPv4 表，IPv6 的监听口一行都不出现
    # （实测本机 -p TCP 含 "[::" 的行 0 条、不带 -p 有 44 条）。而 mihomo / sing-box 这类
    # 客户端配 bind-address: "::1" 时只绑 IPv6 回环——枚举看不到它，候选集就是空的，
    # 状态机判 off，然后把用户的代理变量删掉。
    # 用绝对路径找 netstat，不走 PATH（那个进程的 PATH 由父进程决定，不受本程序控制）。
    # ENVPROXY_NETSTAT 是给测试用的逃生口：要模拟"netstat 输出形状变了""根本调不到 netstat"，
    # 都得能换掉这条路径；真实运行不设这个变量。
    $netstat = [string]$env:ENVPROXY_NETSTAT
    if (-not $netstat) {
        $netstat = Join-Path ([string]$env:SystemRoot) "System32\netstat.exe"
        if (-not (Test-Path -LiteralPath $netstat)) { $netstat = "netstat.exe" }
    }
    $netstatWhy = ""
    $raw = $null
    try {
        $raw = & $netstat -ano 2>$null
        if (-not $raw) { $netstatWhy = "netstat 没有输出（$netstat）" }
    } catch {
        $raw = $null
        $netstatWhy = "netstat 调用失败：" + $_.Exception.Message
    }
    if ($raw) {
        try {
            return (ConvertFrom-NetstatOutput $raw)
        } catch {
            # 解析失败只记原因，继续往 WMI 兜底——"这条取值路走不通"不等于"读不出来"。
            $netstatWhy = $_.Exception.Message
        }
    }

    # ---- ③ WMI 兜底 ----
    try {
        return @(Get-NetTCPConnection -State Listen -ErrorAction Stop)
    } catch {
        # 三条路都失败，把三段的真实原因一起报出去。
        # 不许塌缩成一句"读不出来"：那会让人去查系统权限，而真正的问题可能是
        # netstat 被安全软件吞了输出——两件事的排查方向完全不同。
        throw ("端口枚举失败（" + $apiWhy + "；" + $netstatWhy + "；Get-NetTCPConnection 也不可用：" + $_.Exception.Message + "）")
    }
}

function Test-PortListening([int]$Port) {
    # 命令本身可能不可用（被裁剪的系统、极老版本）：-ErrorAction 拦不住 CommandNotFoundException，
    # 必须包 try，否则 -Install 与监控主循环都会被一条终端命令打断（与 Find-CandidatePorts 同一套处理）。
    # 返回值是**三态**，不是布尔：
    #   "listening"  端口确实在监听
    #   "absent"     读到了端口表，里面没有这个端口（真的没在听）
    #   "unknown"    两次都读不出来（读不出来 ≠ 没在听）
    # 把 unknown 混成 absent，会让"读失败"被判成"代理没了"-> 删掉用户的代理变量。
    # Mac 侧 get_listening_ports 用同样的三态（0/1/非0）表达同一件事。
    for ($i = 0; $i -lt 2; $i++) {
        try {
            foreach ($l in (Get-ListeningTcpConnections)) {
                if ($l.LocalPort -eq $Port) { return "listening" }
            }
            return "absent"
        } catch {}
    }
    return "unknown"
}

# CONNECT 探测：向端口发一个 HTTP CONNECT 请求，只有真正的 HTTP 代理才回 "200"。
# CONNECT 握手的报文与"什么算应答"的唯一出处。
# 串行探测（Test-HttpProxy）与并行探测（Test-HttpProxyBatch）都要用：
# 各写一份必然分叉，而分叉的后果是"同一个端口串行判通、并行判死"——
# 批量那一层会把候选集悄悄缩小，用户看到的就是"有时候能检测到有时候不能"。
# 判据抽成纯函数 Test-ConnectResponse，喂字符串就能测，不必真连网络。
$ConnectProbeRequest = [System.Text.Encoding]::ASCII.GetBytes("CONNECT 127.0.0.1:9 HTTP/1.1`r`nHost: 127.0.0.1:9`r`n`r`n")

function Get-ConnectProbeRequest {
    return $ConnectProbeRequest
}

# 应答算不算"这是个真代理"：必须是 HTTP/1.x 且状态码 200。
# 504/502/超时/拒绝都不算（内核还活着但出口断了，那属于节点不通，不是"这不是代理"）。
function Test-ConnectResponse([string]$Response) {
    if (-not $Response) { return $false }
    return [bool]($Response -match "^\s*HTTP/1\.[01]\s+200")
}

# 这是区分"代理端口"与"其他服务端口"的终极判定，不依赖进程名/端口号猜测。
function Test-HttpProxy([int]$Port) {
    $client = $null
    $stream = $null
    try {
        $conn = Connect-Loopback $Port 500
        if (-not $conn) { return $false }
        $client = $conn.Client
        $stream = $client.GetStream()
        $stream.ReadTimeout = 500
        $req = Get-ConnectProbeRequest
        $stream.Write($req, 0, $req.Length)
        $stream.Flush()
        $buf = New-Object byte[] 512
        $n = $stream.Read($buf, 0, 512)
        if ($n -gt 0) {
            $resp = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
            return (Test-ConnectResponse $resp)
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
function Test-HttpProxyBatch([int[]]$Ports, [string]$Address = "") {
    # 地址族要显式选：默认（IPv4）套接字连 IPv6 地址会抛 "socket is not connected"，
    # 而不是"连不上"——那样并行批量探测对 IPv6-only 端口永远返回空。
    if (-not $Address) { $Address = $LoopbackProbes[0] }
    $family = if ($Address -like "*:*") {
        [System.Net.Sockets.AddressFamily]::InterNetworkV6
    } else {
        [System.Net.Sockets.AddressFamily]::InterNetwork
    }
    $addrObj = [System.Net.IPAddress]::Parse($Address)
    $pending = @()
    foreach ($p in $Ports) {
        $c = $null
        try {
            # 必须把 $family 传进去。不传就是默认的 IPv4 套接字，拿它去连 ::1 会抛
            # "This protocol version is not supported"，被下面的 catch 静默吞掉——
            # 于是批量探测对 IPv6-only 的端口**永远返回空**，而调用方把它读成"这些端口上没有代理"。
            # 上面那两行注释早就写明了要显式选地址族，实现却漏了这一步（$family 成了死变量）。
            $c = New-Object System.Net.Sockets.TcpClient($family)
            $ar = $c.BeginConnect($addrObj, $p, $null, $null)
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
            $req = Get-ConnectProbeRequest
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
                        if (Test-ConnectResponse $resp) { $winner = $r.Item.Port; break }
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
    # 所以这里先做一次即时重试；仍失败就记下"这一轮不知道"（$script:PortEnumerationFailed），
    # 由状态机据此沿用上一状态、不动用户的环境变量。
    # 偶发抖动因此不会翻转状态，而"真的枚举不了"这种系统性问题会在日志里现形。
    # （mac 侧同形：那边枚举失败时 get_listening_ports 返回非 0，一路传到状态机。）
    $listeners = @()
    $enumerated = $false
    for ($attempt = 0; $attempt -lt 2 -and -not $enumerated; $attempt++) {
        try {
            $listeners = Get-ListeningTcpConnections
            $enumerated = $true
        } catch {
            # 留一份原因给日志用：这里吞掉异常是对的（不能让一轮探测中断监控），
            # 但"吞掉"不等于"丢掉"——不记下来就永远查不出为什么。
            $script:PortEnumerationError = $_.Exception.Message
            if ($attempt -eq 0) { Start-Sleep -Milliseconds 300 }
        }
    }
    $script:PortEnumerationFailed = (-not $enumerated)
    # 失败原因整理好放在 $script:PortEnumerationReason 里，**这一层不写日志**。
    #
    # 为什么：probe 是探测层，它的职责是回答"本机有没有可用的代理端口"。
    # 它原来直接调 Write-MonitorLog（那是 runtime 层的函数），于是形成了
    # probe → runtime 的反向依赖："状态页永不写文件"这条契约没法靠结构保证，
    # 只能在调用点显式传一个 -NoLog 开关去关掉——那个开关本身就是这个错位的症状。
    # 现在这一层只把事实（成败 + 原因）交出去，记录由调用方按场合决定：
    # 监控每轮都记，状态页一次都不记（它连日志都还没打开）。
    # 原因仍然保留：只写"两次都没成功"等于把唯一的线索丢掉，事后分不清是
    # netstat 形状变了、被裁剪、还是权限问题。
    $script:PortEnumerationReason = ""
    if (-not $enumerated) {
        $why = ""
        try { $why = "$($script:PortEnumerationError)" } catch {}
        $why = ($why -replace "\s+", " ").Trim()
        if ($why.Length -gt 200) { $why = $why.Substring(0, 200) + "..." }
        if (-not $why) { $why = "（无异常消息）" }
        $script:PortEnumerationReason = $why
    }
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
        # 键必须显式转 [int]：Get-Process.Id 是 Int32，而 Get-NetTCPConnection 的
        # OwningProcess 是 UInt32（netstat 路径已是 Int32，见上面的 [int]$Matches[4]）。
        # 哈希表键类型严格——[uint32]1234 查不到 [int]1234——不转的话，走 WMI 兜底
        # 的非英文系统上这个进程名过滤整段失效（只剩全端口兜底，收敛变慢）。
        # 名字转小写必须用 ToLowerInvariant：ToLower 受当前区域设置影响，
        # 土耳其语下 HIDDIFY 会变成 hıddıfy（无点 ı），匹配不到 *hiddify*。
        # 这一整段只是**提速**，不是正确性的必要条件：即使一个端口都认不出来，
        # 下面第二轮的"全端口并行握手探测"照样能发现代理（只是慢一点）。
        # 所以它出任何问题都必须静默跳过，绝不能让整轮枚举失败。
        #
        # 为什么要单独说这件事：OwningProcess = 0 表示"取不到 PID"（进程内那条路拿不到）。
        # 以前这里直接按 PID 去查名字，拿不到就 continue——逻辑上没错，但前提是
        # "一定有 PID"。现在前提变了，就得把"没有 PID"写成正常的、预期内的情况。
        $suspectPorts = @()
        $hasPid = @($listeners | Where-Object { [int]$_.OwningProcess -gt 0 }).Count -gt 0
        if ($hasPid) {
            # 键必须显式转 [int]：Get-Process.Id 是 Int32，而 Get-NetTCPConnection 的
            # OwningProcess 是 UInt32。哈希表键类型严格——[uint32]1234 查不到 [int]1234。
            # 名字转小写必须用 ToLowerInvariant：ToLower 受当前区域设置影响，
            # 土耳其语下 HIDIFY 会变成 hıdıfy（无点 ı），匹配不到 *hiddify*。
            $procMap = @{}
            foreach ($pr in @(Get-Process -ErrorAction SilentlyContinue)) {
                try { $procMap[[int]$pr.Id] = $pr.ProcessName.ToLowerInvariant() } catch {}
            }
            foreach ($l in ($listeners | Where-Object { $_.LocalAddress -in @("127.0.0.1", "::1", "0.0.0.0", "::") })) {
                $pname = $procMap[[int]$l.OwningProcess]
                if (-not $pname) { continue }
                foreach ($pat in $ProxyProcessPatterns) {
                    if ($pname -like "*$pat*") { $suspectPorts += $l.LocalPort; break }
                }
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
                # 两个回环地址各扫一遍：只绑 ::1 的代理在 IPv4 上是主动拒绝的。
                $uniq = $restPorts | Sort-Object -Unique
                foreach ($addr in $LoopbackProbes) {
                    $tail = Test-HttpProxyBatch $uniq $addr
                    if ($tail -and ($ordered -notcontains $tail)) { $ordered += $tail; break }
                }
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

# 探测"现在真实在用的代理端口"，供**只读画面**（状态页）使用。
#
# 为什么不直接用 Get-ActiveProxyPort：它只能靠"常见端口表 + 进程名"去猜。
# 用户把端口改成 7099 这种不在表里的值时，猜不中；而状态页那边又必须快，
# 于是快扫(non-FullScan)返回空 -> 屏幕打"未检测到"，可同一屏的"代理变量"那行
# 读的是注册表里的真实值、试连还通着 —— 两行自相矛盾。
# 实测过：7099 三层判据（监听/CONNECT/节点）全过，快扫 55ms 却给 []。
#
# 正确的顺序是"从已知推未知"，而不是每轮从零开始猜：
#   1) 环境变量里那个值是我们自己写下的，它指向哪个端口就先验哪个（1 个 TCP 连接，
#      毫秒级）。命中即返回——绝大多数情况下第一步就够，比扫全端口快得多也准得多。
#   2) 没命中（变量没写、或变量指向的端口已死）才去找候选集。
#      这里用 FullScan：状态页一年也点不了几次，"慢 1 秒"远比"说谎"便宜。
#      fullScan 默认给 $true，调用方不必记得传。
# 返回 $null 表示"确实没找到"，与"没读到"由 $script:PortEnumerationFailed 区分。
function Get-InUseProxyPort([bool]$FullScan = $true) {
    # 1) 先验注入值：它是我们写的，指向的就是"用户此刻在用的那个"。
    $known = $null
    try {
        $val = Get-EnvProxyValue
        if ($val) {
            $parts = Split-ProxyUrl $val
            if ($parts -and $parts.Port -gt 0) { $known = [int]$parts.Port }
        }
    } catch {}
    if ($known) {
        # 三层里能便宜地验的都验：端口在听、且是 HTTP 代理（CONNECT 回 200）。
        # 不走 Test-NodeAlive 的节流缓存——状态页要的是"此刻"，而且只验一个端口，
        # 一次请求的代价可以接受；这也避免"节流窗口内沿用旧结论"导致再次说谎。
        $listen = Test-PortListening $known
        if ($listen -eq "listening") {
            try { if (Test-HttpProxy $known) { return $known } } catch {}
        }
    }
    # 2) 注入值不可用：退回候选集（状态页用全扫，别让"看不见"变成"没检测到"）。
    return (Get-ActiveProxyPort -FullScan:$FullScan)
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
# 探测用的本机回环地址，按顺序尝试。
# 只绑 IPv6 回环的代理（mihomo / sing-box 的 bind-address: "::1"）对 127.0.0.1 是
# 主动拒绝的（实测 "actively refused"），只试 IPv4 会让这类用户永远检测不到代理、
# 而且不报任何错。两个地址语义等价，都试一遍即可覆盖。
# 注入的地址**每次现场探测**：连得上的那个回环地址才写进去，可能是 127.0.0.1，
# 也可能是 ::1（拼成 http://[::1]:port）。不能固定写 127.0.0.1——只绑 ::1 的代理
# 在 IPv4 上主动拒绝，写死会让这类用户注入一个用不了的地址。见 Get-ProxyUrlForPort。
$LoopbackProbes = @("127.0.0.1", "::1")

# 探测某一端口时，按 $LoopbackProbes 顺序尝试连接，返回第一个连上的地址。
# 返回 $null = 两个地址都连不上。调用方据此判断"这个端口上没有代理"。
function Connect-Loopback([int]$Port, [int]$TimeoutMs = 500) {
    foreach ($addr in $LoopbackProbes) {
        $c = $null
        try {
            # TcpClient 默认是 IPv4 套接字，拿去连 IPv6 地址不会报"地址不可达"，
            # 而是抛 "socket is not connected"（实测）——必须按地址族显式建套接字。
            $family = if ($addr -like "*:*") {
                [System.Net.Sockets.AddressFamily]::InterNetworkV6
            } else {
                [System.Net.Sockets.AddressFamily]::InterNetwork
            }
            $c = New-Object System.Net.Sockets.TcpClient($family)
            $c.ReceiveTimeout = $TimeoutMs
            $c.SendTimeout = $TimeoutMs
            $c.Connect([System.Net.IPAddress]::Parse($addr), $Port)
            if ($c.Connected) { return @{ Client = $c; Address = $addr } }
            try { $c.Close() } catch {}
        } catch {
            if ($c) { try { $c.Close() } catch {} }
        }
    }
    return $null
}

# 单个地址上试一次 TCP 连接，只回答"这个端口还在不在"。
# 状态页用它判两件事：注入的代理变量指向的端口、系统代理指向的端口。
# 必须按地址族显式建套接字：注入值可能是 http://[::1]:7078，
# 用 IPv4 套接字连 ::1 不报"地址不可达"而是抛 "socket is not connected"，
# 于是判成"死了"——那正是本项目最怕的"看起来正常、实则错的结论"的反面。
function Test-TcpAlive([string]$Address, [int]$Port, [int]$TimeoutMs = 800) {
    if (-not $Address -or $Port -le 0) { return $false }
    $c = $null
    try {
        $family = if ($Address -like "*:*") {
            [System.Net.Sockets.AddressFamily]::InterNetworkV6
        } else {
            [System.Net.Sockets.AddressFamily]::InterNetwork
        }
        $c = New-Object System.Net.Sockets.TcpClient($family)
        $iar = $c.BeginConnect([System.Net.IPAddress]::Parse($Address), $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { $c.EndConnect($iar); return $true }
        return $false
    } catch {
        return $false
    } finally {
        if ($c) { try { $c.Close() } catch {} }
    }
}

# 从注入值里取出主机与端口。返回一个含 Host / Port 两个字段的对象；解析不了返回 $null。
# 不写正则：注入值有两种合法形态（http://127.0.0.1:p 与 http://[::1]:p），
# 手写正则会漏掉 IPv6 那一种——实测状态页就是这样把整段活性检查跳过去的。
function Split-ProxyUrl([string]$Url) {
    if (-not $Url) { return $null }
    try {
        $u = [System.Uri]$Url
        if ($u.Port -le 0) { return $null }
        # Uri::Host 对 IPv6 返回带方括号的 "[::1]"（这是 URL 的写法），
        # 而 IPAddress::Parse 要的是裸 "::1"。不剥掉方括号的话，IPv6 注入值
        # 会在试连时解析失败、被静默判成"端口已死"——正是这条检查要防的那种错误结论。
        $h = $u.Host
        if ($h.StartsWith('[') -and $h.EndsWith(']')) { $h = $h.Substring(1, $h.Length - 2) }
        return [pscustomobject]@{ Host = $h; Port = $u.Port }
    } catch {
        return $null
    }
}

# 给已选定的回环地址拼代理 URL：IPv6 字面量要加方括号。
function Get-ProxyUrlFor([string]$Address, [int]$Port) {
    if ($Address -like "*:*") { return ("http://[{0}]:{1}" -f $Address, $Port) }
    return ("http://{0}:{1}" -f $Address, $Port)
}

# 这个端口该按哪个回环地址注入？现场探测，取第一个连得上的。
#
# 为什么不能固定写 127.0.0.1：只绑 ::1 的代理（mihomo / sing-box 配 bind-address: "::1"）
# 在 IPv4 上是主动拒绝的。检测那一层已经能发现它了，但注入端如果还写 127.0.0.1，
# 用户拿到的是一个连不上的地址——终端里每条命令 ECONNREFUSED，状态页却显示"已注入、正常"。
# 那比"检测不到"更糟：检测不到至少还是直连。
# 探测只在状态**变化**时发生（不是每轮），两次连接的开销可以忽略。
function Get-ProxyUrlForPort([int]$Port) {
    $addr = $LoopbackProbes[0]
    $conn = Connect-Loopback $Port 500
    if ($conn) {
        $addr = $conn.Address
        try { $conn.Client.Close() } catch {}
    }
    return (Get-ProxyUrlFor $addr $Port)
}

# 每个端点声明它**该回什么**，判据不再各处各写一套。
# /generate_204 这类连通性检查端点的契约就是 204：正常返 204；被强制门户劫持时
# 回 200 + 登录页、或 302 跳登录页——那两种都不是"节点通"，必须判断。
# wikipedia 是跨域段的兜底端点，它的正常应答就是 3xx（跟随与否都算通），
# 收 204 会让这两个端点永远判死、端点池退化成纯 Google 段。
# 所以 Expect 只有两种取值：
#   204  -> 只认 204
#   3xx  -> 只认 300-399（**不认裸 200**：200 是门户劫持的典型应答）
# 把 2xx 全收进来、或三处各写一套，会让同一节点因走了哪条判定路径而结论不同。
$CheckEndpoints = @(
    @{ Host = "clients3.google.com";            Path = "/generate_204"; Expect = "204" },
    @{ Host = "connectivitycheck.gstatic.com";  Path = "/generate_204"; Expect = "204" },
    @{ Host = "www.gstatic.com";                Path = "/generate_204"; Expect = "204" },
    @{ Host = "youtubei.googleapis.com";        Path = "/generate_204"; Expect = "204" },
    @{ Host = "www.google.com";                 Path = "/generate_204"; Expect = "204" },
    @{ Host = "www.wikipedia.org";              Path = "/";           Expect = "3xx" }
)

# 单个端点应答的状态码判定（唯一的判据实现）。$Expect 取自端点表。
function Test-EndpointStatus([int]$Code, [string]$Expect) {
    if ($Expect -eq "204") { return ($Code -eq 204) }
    if ($Expect -eq "3xx") { return ($Code -ge 300 -and $Code -le 399) }
    return $false
}
$script:LastGoodEndpoint = 0

# 单端点探测：通过代理发真实 HTTP 请求，成功返回 $true
function Test-SingleEndpoint([int]$Port, [string]$HostName, [string]$Path, [string]$Expect = "204") {
    # 只在**一个**字段里持有连接：先拿到 Connect-Loopback 的结果再取 client。
    # 早先这里先 New 一个 TcpClient、随后又被覆盖成 Connect-Loopback 的那个，
    # finally 只关得到后者——每调用一次泄漏一个套接字句柄（实测 200 次 +202 句柄），
    # 而这正是唯一真实节点探测路径，失败期每 5 秒一次。
    $client = $null
    $stream = $null
    try {
        $conn = Connect-Loopback $Port 500
        if (-not $conn) { return $false }
        $client = $conn.Client
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
        # 判据只有一个地方（Test-EndpointStatus），按端点自己声明的期望值判。
        $m = [regex]::Match($resp, "^\s*HTTP/1\.[01]\s+(\d{3})")
        if (-not $m.Success) { return $false }
        return (Test-EndpointStatus ([int]$m.Groups[1].Value) $Expect)
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
    if (Test-SingleEndpoint $Port $CheckEndpoints[$last].Host $CheckEndpoints[$last].Path $CheckEndpoints[$last].Expect) {
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
        # 代理串必须用实际能连上的那个回环地址：只绑 ::1 的代理在 127.0.0.1 上是
        # 主动拒绝的，写死 IPv4 会让这条兜底路径对它们永远失败。
        $conn = Connect-Loopback $Port 500
        $proxyAddr = if ($conn) { $conn.Address } else { $LoopbackProbes[0] }
        if ($conn) { try { $conn.Client.Close() } catch {} }
        $handler.Proxy = New-Object System.Net.WebProxy((Get-ProxyUrlFor $proxyAddr $Port))
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
                        # 与快路**同一判据**：按端点自己声明的期望值判。
                        # 这里以前收"全部 2xx"（-ge 200 -lt 400），而快路只认 200/204/30x，
                        # 于是同一个节点"走哪条路"会得出不同结论；而且 201/202/206 语义不明，
                        # 判"通"会把终端流量送进坏节点（两个方向的代价不对称）。
                        $ok = (Test-EndpointStatus $code $CheckEndpoints[$k].Expect)
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
            # 第 4 个参数（期望值）必须传：不传就吃默认 204，而 wikipedia 的
            # 期望值是 3xx——它们正常就回重定向，按 204 判会永远判死，端点池退化成纯 Google 段。
            # 同一判断只准有一处实现：这条串行兜底与上面的并行兜底必须同判据。
            if (Test-SingleEndpoint $Port $CheckEndpoints[$i].Host $CheckEndpoints[$i].Path $CheckEndpoints[$i].Expect) {
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

# 节点连通性判定（自适应节流 + 双条件迟滞）：
#   节流：真实探测产生一次外网请求（约 200 字节）。间隔不是固定值，而是跟着"有没有结论"走
#         （见 Get-NodeProbeInterval）：稳定态省流量，正在查和刚下结论时加密。
#   迟滞：连续失败**满 $NodeFailDwellSec 秒且至少 $NodeFailThreshold 次**才判"断"；
#         恢复则 1 次成功立即判"通"并把计数与起点清零，使偶发抖动不累积成"断"。
# 为什么是"次数 + 时长"两个条件而不是只数次数：只数次数时，判据的时长是
# 「次数 × 节流间隔」的乘积，改节流省的流量会直接变成判"断"的耗时，两件事被一个旋钮绑住。
# 拆开后：防抖强度（能吸收多长的抖动）只看 dwell，流量口径只看稳定态间隔，各管各的。
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

# --- 判定用的常量（两侧同形，门禁 6 核对取值一致）--------------------------------
# 采样间隔：稳定态多久探一次。它只决定"流量"和"发现异常的快慢"，不再决定判"断"要多久。
$NodeCheckThrottleSec = 15
# 过渡态采样间隔：正在收集证据（有失败、但还没凑够判据）或刚下完结论时用这个值。
# 注意不是"有失败就用"：失败已达阈值说明结论已定，那时要回稳定档，否则节点一直死时
# 计数会无界增长、间隔永远钉在快档（实测流量是承诺值的 2.5 倍）。
$NodeFastSec          = 5
# 下完结论后继续加密观察多久（判错了能在这段时间里自己改回来）。
$NodeFastWindowSec    = 60
# 判"断"的双条件：至少这么多次，且失败必须已经持续这么久。
$NodeFailThreshold    = 3
$NodeFailDwellSec     = 10
# 槽位闲置多久就丢弃旧失败起点：判定的节奏是快档（$NodeFastSec），正常失败时远达不到这个门限，
# 只有"端口消失很久后又回来"才会撞上。独立常量，不与节流档位绑定。
$NodeIdleResetSec     = 30

# 这一轮该隔多久再探（纯函数，不碰网络、不读时钟，便于回归）：
#   正在收集证据（有失败、还没凑够判据）  -> 快速间隔（问勤一点才可能尽快下结论）
#   刚下完结论（可能判错，需要能马上纠正） -> 快速间隔
#   结论已经稳定（失败已达阈值、或一切正常） -> 稳定间隔（省流量）
# 第三条是关键：只按"有没有失败"决定间隔的话，节点一直死时失败计数会无界增长、
# 间隔永远钉在快速档——实测 3600 秒探测 601 次，是承诺值的 2.5 倍。
# "已经得出结论"就不必再勤问：多问几次不会改变结论。
# 时刻参数一律是单调秒数（Get-MonotonicSeconds 的结果），不是墙上时钟。
function Get-NodeProbeInterval([int]$FailCount, [int]$Threshold, [double]$FastUntil, [double]$Now,
                               [int]$Steady, [int]$Fast) {
    if ($FailCount -gt 0 -and $FailCount -lt $Threshold) { return $Fast }
    if ($Now -lt $FastUntil) { return $Fast }
    return $Steady
}

# 单调时钟（秒，double）。**所有"两个时刻相减"的判定都必须用它。**
# 原因：Get-Date 是墙上时钟，NTP 校时/夏令时/休眠唤醒都会跳变。
#   时钟向后跳 -> (now - last) 变负数 -> "还不到探测间隔"恒成立 -> 停止探测，
#                 代理状态再也不更新（实测 -3600 秒时彻底冻结）；
#   时钟向前跳 -> 失败计数被 IdleReset 清零 -> 判据永远凑不够。
# 用 TickCount 相减则不受任何跳变影响。64 位避免 32 位的 49.7 天回绕。
# 单调时钟的取值口径。TickCount64 只在 .NET 4.5+/PowerShell 7 上有；
# Windows PowerShell 5.1 的 [System.Environment] 没有这个属性，取值会得到 $null
# 而不是抛异常（实测），所以不能用 try/catch 判可用性，必须判值本身。
$script:HasTickCount64 = $null
function Test-HasTickCount64 {
    if ($null -ne $script:HasTickCount64) { return $script:HasTickCount64 }
    $script:HasTickCount64 = $false
    try {
        $v = [System.Environment]::TickCount64
        if ($null -ne $v -and [double]$v -gt 0) { $script:HasTickCount64 = $true }
    } catch {}
    return $script:HasTickCount64
}

# 32 位 TickCount 会 49.7 天回绕。所有跨调用比较都经 ConvertTo-MonotonicDelta
# 做无符号回绕校正，避免"开机满 49.7 天后时间倒流"。
function Get-MonotonicRaw {
    if (Test-HasTickCount64) {
        try { return [double][System.Environment]::TickCount64 } catch {}
    }
    try { return [double][System.Environment]::TickCount } catch {}
    return 0.0
}

function Get-MonotonicSeconds {
    return ((Get-MonotonicRaw) / 1000.0)
}

# 两个单调读数（**毫秒原始值**）之间的秒差，带 32 位回绕校正。$From 在前、$To 在后时返回正数。
# 返回值单位是秒：调用方传进来的通常是毫秒（TickCount 的原始单位），出去的是秒。
# 校正只对 32 位值域生效：判据是"读数本身落在 32 位范围外就没有回绕问题"，
# 而不是"有没有 TickCount64"——后者会让正常的大数值被误当成回绕。
function ConvertTo-MonotonicDelta([double]$FromRaw, [double]$ToRaw) {
    $d = $ToRaw - $FromRaw
    $max32 = 4294967296.0
    $half32 = 2147483648.0
    # 只有当两个读数都在 32 位值域内、且差跨越了回绕时才校正。
    if ($FromRaw -lt $max32 -and $ToRaw -lt $max32) {
        if ($d -lt -$half32) { $d += $max32 }
        elseif ($d -gt $half32) { $d -= $max32 }
    }
    return ($d / 1000.0)
}

# 这一轮能不能判"断"（纯函数）：次数与时长两个条件都满足才算。
# 用"首次失败时刻"算时长而不是累加间隔——间隔会随上面那个函数变化，累加会漂。
function Test-NodeVerdict([int]$FailCount, [double]$FailSpanSec, [int]$Threshold, [int]$DwellSec) {
    return (($FailCount -ge $Threshold) -and ($FailSpanSec -ge $DwellSec))
}

function Test-NodeAlive([int]$Port, [bool]$Force = $false) {
    $now = Get-MonotonicSeconds
    $st = $script:NodeState["$Port"]
    if (-not $st) {
        # 时刻一律用单调秒数：-1 表示"从未"（单调时钟起点是开机，不会是负数）。
        $st = @{ LastCheck = -1.0; Alive = $false; FailCount = 0
                 FirstFailAt = -1.0; FastUntil = -1.0 }
        $script:NodeState["$Port"] = $st
    }
    # "连续"失败必须先真的连续观测：这个端口很久没被探过（槽位留着旧账），
    # 那几次失败与现在不构成同一个连续段。不清零的话，跨度会把中间整段没观测的时间算进去，
    # 一回来就同时满足"≥N 次"和"≥dwell 秒"而当场判"断"——比契约激进，也和 Mac 侧不等价。
    # 门限用独立的常量，不借用节流档位：判定的节奏是快档（5 秒），而节流档位说的是"多久探一次"，
    # 两者含义不同，绑在一起会让以后调任一个都牵动另一个。
    # LastCheck = -1 表示这个槽位还没被探过：$idle 取一个大于任何门限的值即可，
    # 但不能参与后面的减法（-1 - now 会得到很大的负数）。
    # 相减走 ConvertTo-MonotonicDelta 做 32 位回绕校正。5.1 上没有 TickCount64，用的是 Int32 的
    # TickCount，开机满 49.7 天它归零：直接相减会得到很大的负数，$age -lt $iv 恒成立，
    # 于是再也不做真实探测、代理状态永久冻结（用户关掉翻墙软件也不删变量）。
    # 校正函数早就写好了却没接线，等于没有——这里接上它。
    $idle = if ($st.LastCheck -lt 0) { [double]::MaxValue } else { ConvertTo-MonotonicDelta ($st.LastCheck * 1000.0) ($now * 1000.0) }
    if ($st.FailCount -gt 0 -and $idle -gt $NodeIdleResetSec) {
        $st.FailCount = 0
        $st.FirstFailAt = -1.0
    }
    if (-not $Force) {
        $age = $idle
        $iv = Get-NodeProbeInterval $st.FailCount $NodeFailThreshold $st.FastUntil $now $NodeCheckThrottleSec $NodeFastSec
        if ($age -lt $iv) { return $st.Alive }
    }
    $st.LastCheck = $now
    $wasAlive = $st.Alive
    $result = Test-RealConnectivity $Port
    if ($result) {
        $st.FailCount = 0
        $st.FirstFailAt = -1.0
        $st.Alive = $true
        # 只在结论翻转（断->通）时开加密观察窗。若每次成功都重开，窗口永远不结束，
        # 稳态间隔就永远走不到——实测会退化成每 6 秒一探，流量是承诺值的 3 倍。
        if (-not $wasAlive) { $st.FastUntil = $now + $NodeFastWindowSec }
    } else {
        $st.FailCount++
        if ($st.FirstFailAt -lt 0) { $st.FirstFailAt = $now }
        $span = ConvertTo-MonotonicDelta ($st.FirstFailAt * 1000.0) ($now * 1000.0)
        # Force 探测绕过迟滞立即生效（端口变化场景需真实判定）；否则双条件都满足才判死
        if ($Force -or (Test-NodeVerdict $st.FailCount $span $NodeFailThreshold $NodeFailDwellSec)) {
            $st.Alive = $false
            # 只在结论翻转（通->断）时开窗：判错的话 5 秒内就能探到成功、把变量补回来。
            if ($wasAlive) { $st.FastUntil = $now + $NodeFastWindowSec }
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
# 刚丢掉缓存（端口停了 / 在位复核失守）时置位：下一轮立刻深扫一次。
# 用户改端口、换软件、断开重连都走这条路径，新端口往往不在常见表里，
# 靠"每 10 轮才全扫一次"会让空窗拖到约 27 秒。
$script:NeedDeepScan = $false
$script:LastSeenSet = ""
$script:LastAlivePort = $null
$script:Round = 0

# 端口枚举这一轮是否失败（true = 不知道，不是不在翻墙）。
# 由 Find-CandidatePorts 写，由 Get-CurrentState 读。
$script:PortEnumerationFailed = $false
function Get-CurrentState {
    $script:Round++
    $port = $script:CachedPort

    if ($port) {
        $listenState = Test-PortListening $port
        # 读不出来（unknown）时这一轮**是"不知道"**：既不能当"还在听"（可能早没了），
        # 也不能当"没在听"（那会判 off、删掉用户的代理变量）。原地不动最安全。
        if ($listenState -eq "unknown") { return "unknown" }
        if ($listenState -eq "listening") {
            # 在位复核（约每 10 轮一次，本机零流量）：代理退出后若有别的程序
            # 占了同一端口，握手不过立即丢缓存，不等 15 秒节点节流。
            # 返回的 off 照常进调用方的双轮去抖，不会单轮抖动。
            if ((($script:Round % 10) -eq 0) -and (-not (Test-HttpProxy $port))) {
                $script:CachedPort = $null
                # 刚失去这个端口：下一轮立刻深扫一次再下结论。
                # 否则要等第 10 轮全扫，而用户此刻多半已经换到表外的端口上了。
                $script:NeedDeepScan = $true
                return "off"
            }
            # 端口仍在监听：节点验证（15 秒节流，断开连接后内核仍活着时在此识别）
            if (Test-NodeAlive $port) { return "on:$port" }
            # 节点不通：视作关闭（删除变量恢复直连）
            $script:CachedPort = $null
            # 同上：换节点/重连/改端口都会走到这里，下一轮深扫一次。
            $script:NeedDeepScan = $true
            return "off"
        }
        # 端口停止：可能是"断开→改端口→重连/换软件"的过渡期，先睡 2 秒跳过
        Start-Sleep -Seconds 2
        $cands = Find-CandidatePorts -FullScan:$true
        if ($script:PortEnumerationFailed) { return "unknown" }
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

    # 无缓存（off 状态）：轻量候选集；每 10 轮补一次全端口批量尾巴。
    #
    # 但"每 10 轮一次"不能是唯一入口：用户改端口/换软件时，CachedPort 刚被清空，
    # 而新端口往往不在常见表里——快扫看不见它，只能等第 10 轮。实测：off 态每轮 3 秒，
    # 那意味着**最长约 27 秒**空窗，期间状态是"不知道"，用户的代理变量已经在指向新端口
    # 却拿不到确认。这正是"等了很久"的第三个来源。
    #
    # 所以加一条：**刚丢缓存的那一轮立刻全扫**。判据是 LastAlivePort 有值但 CachedPort 空
    # ——说明上一轮还在用某个端口，这一轮它没了，正是"断开/改端口/换软件"的时刻，
    # 此刻最需要一次深扫。稳态下（一直 off，从没活过）仍然按 10 轮节流，不白烧 CPU。
    # 深度决策（扫之前就要定，不能"扫空了再补救"）。
    #
    # 三种情况要全扫：
    #   ① 到了 10 轮的节流点；
    #   ② 刚丢掉缓存（端口停了 / 在位复核失守 / 节点不通）——用户正改端口；
    #   ③ 还没确认过任何端口（LastSeenSet 为空）：此时快扫的"什么都没看见"
    #      无法区分"真没有"与"端口在表外"，必须全扫一次才能下结论。
    #      少了③就会卡在 unknown 里出不来（实测：改端口后 6 轮全是 unknown）。
    $justLostCache = [bool]$script:NeedDeepScan
    $script:NeedDeepScan = $false
    $neverConfirmed = ($script:LastSeenSet -eq '') -and ($null -eq $script:LastAlivePort)
    $fullScan = (($script:Round % 10) -eq 0) -or $justLostCache -or $neverConfirmed
    $cands = Find-CandidatePorts -FullScan:$fullScan
    # 端口枚举失败 = 这一轮不知道，不是不在翻墙。判 off 会删掉用户的代理变量，
    # 而真实情况可能只是这一次没读到。交给主循环"沿用上一状态"。
    if ($script:PortEnumerationFailed) { return "unknown" }
    $sig = ($cands -join ",")
    # 快扫只认"常见端口表 + 进程名"，它给出的是全集的一个**子集**，不是完整观测。
    # 这带来两个必须分开处理的问题：
    #
    # ① 签名不能被快扫覆盖。全扫记下 "7099"，下一轮快扫算出 ""，两串不同 ->
    #    判"集合变化" -> 重新试活 -> 候选集空 -> off -> 再下一轮全扫又"发现变化"。
    #    "集合变化 = 强信号"就这样被自己的节流反复触发，恢复被钉在最多 10 轮
    #    （off 态每轮 3 秒，约 30 秒）——实测复现，用户说的"等很久"就是它。
    #    故：**只有全扫轮更新签名**。
    #
    # ② 快扫轮"什么都没看到"不构成"没有代理"的证据。它没看到的可能是非标准端口。
    #    这时唯一安全的动作是"不知道"（沿用上一状态、不动变量），
    #    与端口枚举失败时同一处置——把"没看见"当成"不存在"会删掉用户的代理变量。
    if (-not $fullScan) {
        if ($cands.Count -eq 0) { return "unknown" }
        # 快扫有结果：不动签名，但可以按现有签名判断"是否已知变化"。
        # 签名里本来就有这个端口 = 与上次全扫一致；否则说明快扫看到了新东西，按变化处理。
        if ($sig -eq $script:LastSeenSet) {
            # 与上次全扫一致：落到下面的稳定态节流单查。
        } else {
            # 快扫看到了签名里没有的端口：这是真的新面孔（不是深度差异造成的），
            # 但**不更新签名**（签名只能由全扫写），直接验活。
            $hit = Confirm-CandidatePort $cands $script:LastAlivePort
            if ($hit) {
                $script:CachedPort = $hit
                $script:LastAlivePort = $hit
                return "on:$hit"
            }
            return "off"
        }
    } elseif ($sig -ne $script:LastSeenSet) {
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
