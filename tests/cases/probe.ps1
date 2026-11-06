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
        $batchHit = Test-HttpProxyBatch @($realProxy.Port)
        Assert-Eq 'the batch path finds the same proxy' ([string]$realProxy.Port) ([string]$batchHit)
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
Assert-Eq 'batch closed finds nothing' '' (Test-HttpProxyBatch @(9, 1))

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
Assert-Eq 'attestation: answered + directly walled counts' $true (Test-EndpointEvidence $true 'walled')
Assert-Eq 'attestation: answered but directly reachable proves nothing' $false (Test-EndpointEvidence $true 'reachable')
Assert-Eq 'attestation: no answer never counts' $false (Test-EndpointEvidence $false 'walled')
Assert-Eq 'attestation: unknown proof value never counts' $false (Test-EndpointEvidence $true '')

# 假代理：按 Host 分派的应答。$ByHost 里列出的主机回 204，其余回 $DefaultStatus。
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
$__proofMap = @{}
try {
    ${function:Test-EndpointDirect} = { param([string]$HostName, [string]$Path, [string]$Expect = '204') return [bool]$__proofMap[$HostName] }

    # 承重墙：六个端点全是"直连也通"，那么经代理收到多少个 204 都证明不了代理能出去。
    # 删掉合格证这一步，这条断言会立刻变红——这正是它存在的理由。
    $__allReachable = Start-HostDispatchServer @{} 204
    try {
        $script:EndpointProofCache = @{}
        $script:LastGoodEndpoint = 0
        foreach ($e in $CheckEndpoints) { $__proofMap[$e.Host] = $true }
        Assert-Eq 'a proxy answering only directly-reachable endpoints is not alive' $false (Test-RealConnectivity $__allReachable.Port)
    } finally { Stop-OneShotServer $__allReachable }

    # 反向：同样的假代理，端点换成"直连不通"，必须认出来。
    # 少了这条，"恒返回 false"也能让上面那条绿——那等于把功能删掉。
    $__allWalled = Start-HostDispatchServer @{} 204
    try {
        $script:EndpointProofCache = @{}
        $script:LastGoodEndpoint = 0
        foreach ($e in $CheckEndpoints) { $__proofMap[$e.Host] = $false }
        Assert-Eq 'the same proxy is alive once its endpoints are walled' $true (Test-RealConnectivity $__allWalled.Port)
    } finally { Stop-OneShotServer $__allWalled }

    # 原样复现那次误判：只有 gstatic 系回 204（它们直连也通），其余一律 502（节点死）。
    $__deadNode = Start-HostDispatchServer @{ 'gstatic.com' = 204 } 502
    try {
        $script:EndpointProofCache = @{}
        $script:LastGoodEndpoint = 0
        foreach ($e in $CheckEndpoints) { $__proofMap[$e.Host] = ($e.Host -match 'gstatic\.com') }
        Assert-Eq 'a dead node that only answers the two gstatic endpoints is not alive' $false (Test-RealConnectivity $__deadNode.Port)
    } finally { Stop-OneShotServer $__deadNode }
} finally {
    Set-Item -Path Function:Test-EndpointDirect -Value $__proofSaved
    $script:EndpointProofCache = @{}
    $script:LastGoodEndpoint = 0
    Remove-Variable -Name __proofSaved -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name __proofMap -Scope Script -ErrorAction SilentlyContinue
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

