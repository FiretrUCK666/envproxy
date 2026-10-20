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

# 列出本机所有处于监听状态的 TCP 连接。
# 用 netstat 而不是 Get-NetTCPConnection：后者每次 1.7–2.3 秒（WMI 启动开销），
# 而监控每 2–3 秒跑一轮、在位复核每轮还要查一次端口——这一项就吃掉了整个周期。
# 同一台机器实测 netstat 30–50 毫秒，快 40 倍以上。
# netstat 不可用（被裁剪的系统）或状态列被本地化时，退回 WMI：慢，但可靠。
# 返回与 Get-NetTCPConnection 同形的对象（LocalAddress / LocalPort / OwningProcess）。
function Get-ListeningTcpConnections {
    $raw = $null
    try { $raw = & netstat.exe -ano -p TCP 2>$null } catch { $raw = $null }
    if (-not $raw) {
        return @(Get-NetTCPConnection -State Listen -ErrorAction Stop)
    }
    $listeners = New-Object System.Collections.ArrayList
    $sawListening = $false
    $sawTcp = $false
    foreach ($line in $raw) {
        if ($line -notmatch '^\s*TCP\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)\s*$') { continue }
        $sawTcp = $true
        $state = $Matches[3]
        if ($state -ne "LISTENING") { continue }
        $sawListening = $true
        $endpoint = ConvertTo-ListenEndpoint $Matches[1]
        if (-not $endpoint) { continue }
        [void]$listeners.Add([pscustomobject]@{
            LocalAddress = $endpoint.Address
            LocalPort = $endpoint.Port
            OwningProcess = [int]$Matches[4]
        })
    }
    if ($listeners.Count -gt 0) { return $listeners }
    if ($sawListening) { throw "netstat 解析出错：有 LISTENING 行但没解析出端口" }
    if ($sawTcp) {
        # 有 TCP 行、却一个 LISTENING 都没有：状态列多半被本地化了。改走 WMI 那一路。
        return @(Get-NetTCPConnection -State Listen -ErrorAction Stop)
    }
    return $listeners
}

function Test-PortListening([int]$Port) {
    # 命令本身可能不可用（被裁剪的系统、极老版本）：-ErrorAction 拦不住 CommandNotFoundException，
    # 必须包 try，否则 -Install 与监控主循环都会被一条终端命令打断（与 Find-CandidatePorts 同一套处理）。
    for ($i = 0; $i -lt 2; $i++) {
        try {
            foreach ($l in (Get-ListeningTcpConnections)) {
                if ($l.LocalPort -eq $Port) { return $true }
            }
            return $false
        } catch {}
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
            $listeners = Get-ListeningTcpConnections
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
