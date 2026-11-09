Write-Host '[3] closed ports'
Assert-Eq 'single closed is not proxy' $false (Test-HttpProxy 9)

    # ---- 正向覆盖：判决三层的前两层必须真的能被认出来 ----
    # 这一段是补历史欠账：原来 Test-HttpProxy / Test-EndpointStatus 只有否定断言
    #（关闭的端口不是代理），没有任何一条说真代理要认得出来。
    # 后果是这两个函数可以被改成恒返回 $false 而全部门禁全绿——
    # 那等于工具在最核心的功能上彻底失效，用户只会看到检测不到代理。
    # 假服务器返回的是 @{Port=...; Ps=...; Rs=...}，用 $srv.Port 取端口、用 Stop-OneShotServer 收尾。
    $realProxy = Start-OneShotServer 200 @{} ''
    try {
        Assert-Eq 'a real CONNECT proxy is recognised' $true (Test-HttpProxy $realProxy.Port)
        # 批量探测现在带回**全部**命中（按传入顺序），不再是"谁先应答算谁"。
        # 单端口时是这个数组唯一的元素，所以 [0] 取法与原来的语义等价。
        $batchHit = @(Test-HttpProxyBatch @($realProxy.Port))
        Assert-Eq 'the batch path finds the same proxy' ([string]$realProxy.Port) ([string]$batchHit[0])
    } finally { Stop-OneShotServer $realProxy }
    $refusing = Start-OneShotServer 403 @{} 'no'
    try {
        Assert-Eq 'a proxy that refuses is not accepted' $false (Test-HttpProxy $refusing.Port)
    } finally { Stop-OneShotServer $refusing }

    # 端点判据的三态：204 类只认 204，3xx 类只认 3xx。
    # 这两条曾在两侧都没有任何断言——把 204 放宽成 200..399 会全绿，
    # 而那正好放进强制门户返回 200 登录页这个最该挡的场景。
    Assert-Eq 'endpoint 204 accepts 204' $true (Test-EndpointStatus 204 '204')
    Assert-Eq 'endpoint 204 rejects 200 (captive portal)' $false (Test-EndpointStatus 200 '204')
    Assert-Eq 'endpoint 204 rejects 302' $false (Test-EndpointStatus 302 '204')
    Assert-Eq 'endpoint 3xx accepts 301' $true (Test-EndpointStatus 301 '3xx')
    Assert-Eq 'endpoint 3xx rejects 204' $false (Test-EndpointStatus 204 '3xx')
Assert-Eq 'batch closed finds nothing' '' (@(Test-HttpProxyBatch @(9, 1)) -join ',')

# ------------------------------------------------------------------------------
# 端点合格证：一个端点的"通"只有在**直连它不通**时才证明得了代理能出去。
#
# 这一组挡的是一个真实发生过的误判（2026-11-06）：用户换节点后节点域名消失，
# 所有真被墙的站点一律回 502，而 www.gstatic.com 与 connectivitycheck.gstatic.com
# 在那个网络下直连就回 204（国内有落地）。旧代码只看"经代理拿到期望应答"，
# 于是从这两个端点收到 204、判成"翻墙中"，把一条死代理注入到每个终端里。
# 屏幕全绿、终端全挂——本工具最不能犯的错。
# ------------------------------------------------------------------------------
Write-Host '[3b] endpoint attestation (a direct-reachable endpoint proves nothing)'
Assert-Eq 'attestation: blocked counts' $true (Test-EndpointEvidence 'blocked')
Assert-Eq 'attestation: reachable proves nothing' $false (Test-EndpointEvidence 'reachable')
Assert-Eq 'attestation: unknown proves nothing' $false (Test-EndpointEvidence 'unknown')
Assert-Eq 'attestation: an empty value never counts' $false (Test-EndpointEvidence '')

# 三态的分界线：什么算"确定被墙"，什么只能算"不知道"。
# 两态时这两件事被压成同一个返回值，于是 DNS 一挂、门户一拦，全都变成"被墙"——
# 合格证恒真，新判据退化成旧判据，而屏幕上看不出任何异常。
Assert-Eq 'tri-state: the three kinds are distinct' $true (
    ($script:EndpointProofKinds.Blocked -ne $script:EndpointProofKinds.Reachable) -and
    ($script:EndpointProofKinds.Reachable -ne $script:EndpointProofKinds.Unknown) -and
    ($script:EndpointProofKinds.Blocked -ne $script:EndpointProofKinds.Unknown))

# 直连基线的池：形状本身就是契约。
# 少于两条就等于回到"押在某一家身上"的单点依赖（评审里说的企业内网/海外分支场景）；
# 路径不以 / 开头会拼出坏网址；主机重复等于白试两次。四条都不碰网络，纯查表。
Write-Host '[3c] direct baseline pool'
Assert-Eq 'baseline pool: three probes' 3 (@($DirectBaselinePool).Count)
Assert-Eq 'baseline pool: every entry has a host and a rooted path' 0 (@($DirectBaselinePool | Where-Object {
    -not $_.Host -or -not ([string]$_.Path).StartsWith('/') }).Count)
Assert-Eq 'baseline pool: hosts are unique' 3 (@($DirectBaselinePool | ForEach-Object { $_.Host } | Sort-Object -Unique).Count)
Assert-Eq 'baseline pool: per-probe timeout is shorter' $true ($DirectBaselineTimeoutMs -lt $EndpointDirectTimeoutMs)

# 取值的桩：直接给三态之一，绕开真网络。
function Set-EndpointDirectKind([string]$Kind) {
    ${function:Test-EndpointDirect} = { param([string]$h, [string]$p, [string]$e = '204') return $Kind }.GetNewClosure()
}

# 假代理：按 Host 分派的应答。$ByHost 里列出的主机回 204，其余回 $DefaultStatus。
# 直接复用骨架里的 Start-OneShotServer 不行——它只会回一个固定状态码，
# 而这一组要的正是"对不同主机回不同状态"。
# 必须真的监听、且一直服务到测试结束——固定 sleep 在忙机器上会随机红。
function Start-HostDispatchServer([hashtable]$ByHost, [int]$DefaultStatus) {
    $port = 0
    for ($t = 0; $t -lt 30; $t++) {
        $candidate = 18000 + (Get-Random -Maximum 2000)
        $probe = $null
        try {
            $probe = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $candidate)
            $probe.Start()
            $port = $candidate
        } catch { $port = 0 } finally { if ($probe) { try { $probe.Stop() } catch {} } }
        if ($port -ne 0) { break }
    }
    if ($port -eq 0) { throw 'no free port for the mock proxy' }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
        $p = $args[0]; $map = $args[1]; $default = $args[2]
        $tcp = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $p)
        $tcp.Start()
        try {
            while ($true) {
                $accept = $tcp.AcceptTcpClientAsync()
                if (-not $accept.Wait(1000)) { continue }
                $client = $accept.Result
                try {
                    $stream = $client.GetStream()
                    $buf = New-Object byte[] 4096
                    $read = $stream.Read($buf, 0, $buf.Length)
                    $text = [System.Text.Encoding]::ASCII.GetString($buf, 0, [Math]::Max($read, 0))
                    # 目标主机可能在请求行（GET http://host/path）也可能在 Host 头里
                    $hit = 0
                    foreach ($h in $map.Keys) {
                        if ($text -match [regex]::Escape([string]$h)) { $hit = $map[$h] }
                    }
                    if ($hit -eq 0) { $hit = $default }
                    $raw = "HTTP/1.1 $hit X`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
                    $b = [System.Text.Encoding]::ASCII.GetBytes($raw)
                    $stream.Write($b, 0, $b.Length)
                    $stream.Flush()
                } catch {}
                try { $client.Close() } catch {}
            }
        } catch {}
        $tcp.Stop()
    }).AddArgument($port).AddArgument($ByHost).AddArgument($DefaultStatus)
    $null = $ps.BeginInvoke()
    $deadline = (Get-Date).AddSeconds(10)
    $up = $false
    while ((Get-Date) -lt $deadline) {
        try {
            $probe = New-Object System.Net.Sockets.TcpClient
            $probe.Connect('127.0.0.1', $port)
            $probe.Close()
            $up = $true
            break
        } catch { Start-Sleep -Milliseconds 50 }
    }
    if (-not $up) {
        try { $ps.Stop() } catch {}
        try { $rs.Dispose() } catch {}
        throw 'the mock proxy did not start listening'
    }
    return @{ Port = $port; Runspace = $rs; Shell = $ps }
}

# 直连那一侧是唯一要真联网的取值函数，这里换掉它，测试就不依赖这台机器能不能翻墙。
# 覆盖的是**最外层取值函数**，与内部走 DNS 还是 HttpClient 无关。
$__proofSaved = (Get-Item -Path Function:Test-EndpointDirect).ScriptBlock
$__baselineSaved = (Get-Item -Path Function:Test-DirectBaselineAlive).ScriptBlock
try {
    # 直连基线恒为「能上网」：下面这些用例关心的是端点本身，不是整条直连断没断。
    ${function:Test-DirectBaselineAlive} = { return $true }
    # 默认全部"确定被墙"，个别用例再挑端点改成别的。
    ${function:Test-EndpointDirect} = { param([string]$HostName, [string]$Path, [string]$Expect = '204') return 'blocked' }

    # 承重墙：六个端点全是"直连也通"，那么经代理收到多少个 204 都证明不了代理能出去。
    # 删掉合格证这一步，这条断言会立刻变红——这正是它存在的理由。
    $__allReachable = Start-HostDispatchServer @{} 204
    try {
        $script:EndpointProofCache = @{}
        $script:LastGoodEndpoint = 0
        Set-EndpointDirectKind 'reachable'
        $__allReachVerdict = Test-RealConnectivity $__allReachable.Port
        $__allReachDegraded = $script:ProofDegraded
        # 退回旧判据：全 reachable 是本机直连被整体接管（TUN / 透明代理），
        # 判"不通"会让一个正常工作的代理永远被判死。
        Assert-Eq 'a proxy is alive when every endpoint is directly reachable (falls back)' $true $__allReachVerdict
        Assert-Eq 'that fallback is flagged so the log can say so' $true $__allReachDegraded
    } finally { Stop-OneShotServer $__allReachable }

    # 反向承重墙：同样全 reachable，但**全部问不出来**（DNS 挂了）——一个端点的通都不算数。
    # 这一条与上一条的区别就是整个三态改动的意义，必须分开钉住。
    $__allUnknown = Start-HostDispatchServer @{} 204
    try {
        $script:EndpointProofCache = @{}
        $script:LastGoodEndpoint = 0
        Set-EndpointDirectKind 'unknown'
        $__allUnknownVerdict = Test-RealConnectivity $__allUnknown.Port
        Assert-Eq 'a proxy is NOT alive when no endpoint can be attested (unknown is not walled)' $false $__allUnknownVerdict
        Assert-Eq 'the unknown path never falls back' $false $script:ProofDegraded
    } finally { Stop-OneShotServer $__allUnknown }

    # 反向：同样的假代理，端点换成"确定被墙"，必须认出来。
    # 少了这条，"恒返回 false"也能让上面那条绿——那等于把功能删掉。
    $__allBlocked = Start-HostDispatchServer @{} 204
    try {
        $script:EndpointProofCache = @{}
        $script:LastGoodEndpoint = 0
        Set-EndpointDirectKind 'blocked'
        Assert-Eq 'the same proxy is alive once its endpoints are blocked' $true (Test-RealConnectivity $__allBlocked.Port)
    } finally { Stop-OneShotServer $__allBlocked }

    # 原样复现那次误判：只有 gstatic 系回 204（它们直连也通），其余一律 502（节点死）。
    $__deadNode = Start-HostDispatchServer @{ 'gstatic.com' = 204 } 502
    try {
        $script:EndpointProofCache = @{}
        $script:LastGoodEndpoint = 0
        Set-EndpointDirectKind 'blocked'
        ${function:Test-EndpointDirect} = {
            param([string]$HostName, [string]$Path, [string]$Expect = '204')
            if ($HostName -match 'gstatic\.com') { return 'reachable' } else { return 'blocked' }
        }
        Assert-Eq 'a dead node that only answers the two gstatic endpoints is not alive' $false (Test-RealConnectivity $__deadNode.Port)
    } finally { Stop-OneShotServer $__deadNode }

    # 越界索引不许静默发证：那是一张没有任何依据的合格证，而且它让判决朝"判活"方向错。
    $script:EndpointProofCache = @{}
    ${function:Test-EndpointDirect} = { param([string]$h, [string]$p, [string]$e = '204') return 'blocked' }
    Assert-Eq 'an out-of-range index yields unknown, not a pass' 'unknown' (Get-EndpointProof 99)
    Assert-Eq 'a negative index yields unknown too' 'unknown' (Get-EndpointProof -1)

    # Unknown 不入缓存：它说的是"这一次没问出来"，不是这个端点的性质。
    $script:EndpointProofCache = @{}
    $__unknownCalls = 0
    ${function:Test-EndpointDirect} = { param([string]$h, [string]$p, [string]$e = '204') $script:__unknownCalls++; return 'unknown' }
    [void](Get-EndpointProof 0)
    [void](Get-EndpointProof 0)
    Assert-Eq 'unknown is never cached (asked every time)' 2 $__unknownCalls
} finally {
    Set-Item -Path Function:Test-EndpointDirect -Value $__proofSaved
    Set-Item -Path Function:Test-DirectBaselineAlive -Value $__baselineSaved
    $script:EndpointProofCache = @{}
    $script:DirectBaseline = $null
    $script:LastGoodEndpoint = 0
    $script:ProofDegraded = $false
    Remove-Variable -Name __proofSaved -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name __baselineSaved -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name __unknownCalls -Scope Script -ErrorAction SilentlyContinue
}

Write-Host '[4] source copy detection and cleanup'
$fake = New-TempDir 'envproxy_srctest_'
New-Item -Path (Join-Path $fake '.github') -ItemType Directory -Force | Out-Null
Write-TestFile (Join-Path $fake 'AGENTS.md') 'dev'
Write-TestFile (Join-Path $fake 'my-notes.txt') 'mine'
Write-TestFile (Join-Path $fake '.gitattributes') "/AGENTS.md  export-ignore`n/.github/  export-ignore"
Assert-Eq 'github-without-git is source copy' $true (Test-SourceCopy -Root $fake)
New-Item -Path (Join-Path $fake '.git') -ItemType Directory -Force | Out-Null
Assert-Eq 'git present is not source copy' $false (Test-SourceCopy -Root $fake)
Remove-Item -LiteralPath (Join-Path $fake '.git') -Recurse -Force
Remove-SourceOnlyFiles $fake
Assert-Eq 'cleanup removes dev files' $false (Test-Path -LiteralPath (Join-Path $fake 'AGENTS.md'))
Assert-Eq 'cleanup removes github dir' $false (Test-Path -LiteralPath (Join-Path $fake '.github'))
Assert-Eq 'cleanup keeps user files' $true (Test-Path -LiteralPath (Join-Path $fake 'my-notes.txt'))
Assert-Eq 'converted folder is install copy' $false (Test-SourceCopy -Root $fake)
Remove-Item -LiteralPath $fake -Recurse -Force
$bare = New-TempDir 'envproxy_bare_'
Write-TestFile (Join-Path $bare 'my-notes.txt') 'mine'
Assert-Eq 'neither marker means install copy' $false (Test-SourceCopy -Root $bare)
Remove-Item -LiteralPath $bare -Recurse -Force

