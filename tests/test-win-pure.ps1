# EnvProxy Windows pure-function regression tests.
# Run: pwsh tests/test-win-pure.ps1   (PowerShell 5.1 compatible, UTF-8 with BOM)
#
# 注册表用例写在临时键上，不碰使用者的真实环境：下面把四个落点整体改道，
# 跑完删掉沙箱键。生产路径一字未改——改的只是"写到哪个键"。
# （以前这些用例直接改真实的 HKCU\Environment，靠 finally 还原。
#   finally 挡不住 Ctrl+C：中断一次，代理变量就留在被删状态，屏幕上一句话都没有。）
#
# The core is loaded through its real entry point: that exercises the library loader and its
# completeness check, and the entry returns immediately when dot-sourced.

# 本自检要在「干净的环境」里跑：使用者机器上可能已经把 ENVPROXY_TERM 设成 off，
# 或别处导出了代理变量。那些是真实状态，但会让这里的断言在不同的机器上得出不同结论——
# 同一个提交在 CI 通过、在用户机器上失败（或反过来），是最难查的一类红。
# 记下原值，跑完还原，全程只在进程层动，不碰使用者真正设置。
$__savedTerm = $env:ENVPROXY_TERM
$__savedProxy = @{}
foreach ($__n in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','NODE_USE_ENV_PROXY',
                  'http_proxy','https_proxy','all_proxy','no_proxy')) {
    $__savedProxy[$__n] = [Environment]::GetEnvironmentVariable($__n, 'Process')
}
Remove-Item Env:ENVPROXY_TERM -ErrorAction SilentlyContinue
foreach ($__n in $__savedProxy.Keys) { [Environment]::SetEnvironmentVariable($__n, $null, 'Process') }
$ErrorActionPreference = 'Stop'
$script:fails = 0
. (Join-Path $PSScriptRoot '../win/envproxy.ps1')

# ------------------------------------------------------------------------------
# 注册表沙箱：把所有落点改到临时键，跑完整段真实路径却一个字节都不碰使用者环境。
# ------------------------------------------------------------------------------
# 为什么必须沙箱：这一份自检要验证"写入 / 删除 / 快照还原 / 终端钩子"整套真实行为，
# 那些函数只认注册表。原来它们直接改 HKCU\Environment，靠 finally 还原——
# 而 finally 挡不住 Ctrl+C / 关窗口 / 进程被杀。用户跑一次自检、中途按一下中断，
# 代理变量就留在被删状态，屏幕上没有任何提示，他也不会知道该去查什么。
#
# 做法是把**落点**换掉，不是另写一套假对象：调用的仍是 Write-UserEnvValues、
# Snapshot-PrevEnv、Get-ProfileBlockLines 这些真函数，连生成的钩子正文都一样
# 指向沙箱键，于是那段钩子逻辑照旧被真跑一遍。
# 四个子键在 base 层各声明一次，这里改一次就全跟着走。
if ($env:OS -eq 'Windows_NT') {
    $script:SavedRegSandbox = @{
        UserEnv       = $UserEnvSubKey
        Owned         = $OwnedRegSubKey
        PrevEnv       = $PrevEnvSubKey
        ScriptPathReg = $ScriptPathRegSubKey
    }
    $env:OS | Out-Null
    $UserEnvSubKey       = 'Software\EnvProxy\__t_env'
    $OwnedRegSubKey      = 'Software\EnvProxy\__t_owned'
    $PrevEnvSubKey       = 'Software\EnvProxy\__t_prev'
    $ScriptPathRegSubKey = 'Software\EnvProxy\__t_scriptpath'
    if (-not (Test-RegKey 'HKCU:\Software\EnvProxy')) {
        New-Item -Path 'HKCU:\Software\EnvProxy' -Force -ErrorAction SilentlyContinue | Out-Null
    }
    foreach ($k in @($UserEnvSubKey, $OwnedRegSubKey, $PrevEnvSubKey, $ScriptPathRegSubKey)) {
        Remove-Item -LiteralPath (Get-RegPath $k) -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -Path (Get-UserEnvKeyPath) -Force -ErrorAction SilentlyContinue | Out-Null
}

# 日志隔离：把 $LogFile 换到临时目录，绝不写进仓库里的 win\monitor\monitor.log。
#
# 为什么必须有这一步：有些用例要走"枚举失败 / 状态 unknown"这条真实路径，
# 而那条路径会调 Write-MonitorLog。默认的 $LogFile 指向仓库内的运行时目录——
# 于是"跑一次自检"会在使用者的真实日志里留下几条 simulated 的假失败记录，
# 事后排查时看到的是自己测试造出来的噪声。测试改坏被测对象的现场，是最坏的一种。
# 换到临时目录后：既照常验证了"失败会记一条日志"，又不污染真实运行时状态。
$script:SavedLogFile = $LogFile
$script:TestLogDir = Join-Path ([System.IO.Path]::GetTempPath()) ('envproxy_testlog_' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -Path $script:TestLogDir -ItemType Directory -Force | Out-Null
$LogFile = Join-Path $script:TestLogDir 'monitor.log'

function Assert-Eq([string]$Name, $Want, $Have) {
    if ("$Want" -eq "$Have") { Write-Host ("  PASS {0}" -f $Name) }
    else { Write-Host ("  FAIL {0} (want [{1}] have [{2}])" -f $Name, $Want, $Have); $script:fails++ }
}

# 大小写敏感的比较。`-eq` 对字符串不区分大小写，所以"校验值被归一成小写"
# 这类契约用它断言等于没断言——实测把 Get-AssetFromJson 里的 .ToLower() 删掉，
# 全部 digest 用例照样 PASS，而那正是两侧判决口径会分叉的地方
# （一边认大写、另一边跳过大写校验，同一个包两边结论不同）。
function Assert-EqCase([string]$Name, $Want, $Have) {
    if ("$Want" -ceq "$Have") { Write-Host ("  PASS {0}" -f $Name) }
    else { Write-Host ("  FAIL {0} (want [{1}] have [{2}])" -f $Name, $Want, $Have); $script:fails++ }
}

function Assert-Throws([string]$Name, [scriptblock]$Block) {
    $threw = $false
    try { & $Block | Out-Null } catch { $threw = $true }
    Assert-Eq $Name $true $threw
}

function Write-TestFile([string]$P, [string]$T) {
    $dir = Split-Path -Parent $P
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    [System.IO.File]::WriteAllText($P, $T)
}

function New-TempDir([string]$Prefix) {
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + [Guid]::NewGuid().ToString('N'))
    New-Item -Path $d -ItemType Directory -Force | Out-Null
    return $d
}

# A local HTTP server, used to exercise the real network paths (a redirect, a rate limit)
# without touching the network. It serves until the test stops it.
# Two things it must get right, or the gate turns red at random:
#   - the port has to be one nothing else is listening on (a taken port means the client
#     gets "connection refused", which the code reports as a network failure);
#   - the caller must not talk to it before it is really listening (a fixed sleep is
#     not enough on a busy machine).
# The server keeps serving instead of answering exactly one request: a client that opens
# a second connection (retry, pre-connect) would otherwise wait for an answer nobody sends.
function Start-OneShotServer([int]$Status, [hashtable]$Headers, [string]$Body) {
    $port = 0
    for ($try = 0; $try -lt 30; $try++) {
        $candidate = 18000 + (Get-Random -Maximum 2000)
        $probe = $null
        try {
            $probe = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $candidate)
            $probe.Start()
            $port = $candidate
        } catch { $port = 0 } finally { if ($probe) { try { $probe.Stop() } catch {} } }
        if ($port -ne 0) { break }
    }
    if ($port -eq 0) { throw 'no free port for the mock server' }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
        # Arguments come in through $args: a scriptblock handed to AddScript does not bind its
        # own param block reliably across PowerShell versions.
        $p = $args[0]; $status = $args[1]; $hdrs = $args[2]; $body = $args[3]
        $tcp = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $p)
        $tcp.Start()
        try {
            # AcceptTcpClientAsync, not Socket.Poll -- on Windows a listening socket does not
            # report a pending connection through Poll, so Poll would only time out.
            while ($true) {
                $accept = $tcp.AcceptTcpClientAsync()
                if (-not $accept.Wait(1000)) { continue }
                $client = $accept.Result
                try {
                    $stream = $client.GetStream()
                    $buf = New-Object byte[] 2048
                    $null = $stream.Read($buf, 0, $buf.Length)
                    $raw = "HTTP/1.1 $status X`r`n"
                    foreach ($k in $hdrs.Keys) { $raw += "$k`: $($hdrs[$k])`r`n" }
                    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                    $raw += "Content-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
                    $head = [System.Text.Encoding]::UTF8.GetBytes($raw)
                    $stream.Write($head, 0, $head.Length)
                    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
                    $stream.Flush()
                } catch {}
                try { $client.Close() } catch {}
            }
        } catch {}
        $tcp.Stop()
    }).AddArgument($port).AddArgument($Status).AddArgument($Headers).AddArgument($Body)
    $null = $ps.BeginInvoke()
    # Wait until it really accepts connections before handing the port to the caller.
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
        throw 'the mock server did not start listening'
    }
    return @{ Port = $port; Runspace = $rs; Shell = $ps }
}

function Stop-OneShotServer($Server) {
    try { $Server.Shell.Stop() } catch {}
    try { $Server.Runspace.Dispose() } catch {}
}

Write-Host '[1] pure functions'
Assert-Eq 'merge keeps user entries' 'localhost,127.0.0.1,::1,example.com' (Merge-NoProxy 'localhost,example.com,::1' $DefaultNoProxy)
Assert-Eq 'merge empty' 'localhost,127.0.0.1,::1' (Merge-NoProxy '' $DefaultNoProxy)
Assert-Eq 'normalize' 'localhost|foo' ((Get-NormalizedNoProxyEntries ' Localhost , FOO ') -join '|')
Assert-Eq 'versions 1.0.10 > 1.0.9' '1' (Compare-Versions '1.0.10' '1.0.9')
Assert-Eq 'versions 1.0 == 1.0.0' '0' (Compare-Versions '1.0' '1.0.0')
Assert-Eq 'versions 2.0 > 10-part' '-1' (Compare-Versions '1.9' '1.10')
$t = Get-ProxyVarTable '17890'
Assert-Eq 'var table count' '5' ($t.Count)
Assert-Eq 'var table value' 'http://127.0.0.1:17890' ($t['HTTP_PROXY'])

# 这一组的快照键就是沙箱键（文件开头已整体改道），跑之前先清空它。
# Test-IsOwnedProxyValue 内部会去读安装快照判断「这个名字装前就有了吗」，
# 那结论必须由本用例自己控制：装过的机器上快照里有这几个名字，断言就会拿到
# 与干净 CI 相反的结论——同一份测试两边结论相反，是最难查的一类红。
if ($env:OS -eq 'Windows_NT') {
    Remove-Item -LiteralPath (Get-PrevEnvRegKeyPath) -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path (Get-PrevEnvRegKeyPath) -Force | Out-Null
}
Write-Host '[2] ownership convention (real predicate)'
Assert-Eq 'local counts as ours' $true (Test-IsOwnedProxyValue 'HTTP_PROXY' 'http://127.0.0.1:7890')
Assert-Eq 'corp does not' $false (Test-IsOwnedProxyValue 'HTTP_PROXY' 'http://corp:8080')
Assert-Eq 'own no_proxy entry counts' $true (Test-IsOwnedProxyValue 'NO_PROXY' 'localhost,example.com')
Assert-Eq 'foreign no_proxy does not' $false (Test-IsOwnedProxyValue 'NO_PROXY' 'example.com')
Assert-Eq 'node flag 1 counts' $true (Test-IsOwnedProxyValue 'NODE_USE_ENV_PROXY' '1')
Assert-Eq 'node flag other does not' $false (Test-IsOwnedProxyValue 'NODE_USE_ENV_PROXY' '0')
Assert-Eq 'empty counts as nothing' $false (Test-IsOwnedProxyValue 'HTTP_PROXY' '')

# 归属判定的第二层：安装快照里本来就记着的值，哪怕长得像我们的，也永远是使用者的。
# 没有这一层，用户自己写的 NO_PROXY=localhost、或自挂的 mitmproxy（127.0.0.1:8080）
# 会在 off 态每 30 轮被定时删掉，日志还谎称"回收残留"。
if ($env:OS -eq 'Windows_NT') {
    # 照样只碰沙箱键：真实快照里存着使用者安装前的原值，
    # 往那里写测试值、跑完再删，等于把他的快照改残，卸载还原不回去。
    $bakKey = Get-PrevEnvRegKeyPath
    Remove-Item -LiteralPath $bakKey -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $bakKey -ErrorAction SilentlyContinue | Out-Null
    try {
        Set-ItemProperty -Path $bakKey -Name 'NO_PROXY' -Value 'localhost' -ErrorAction Stop
        Set-ItemProperty -Path $bakKey -Name 'HTTP_PROXY' -Value 'http://127.0.0.1:8080' -ErrorAction Stop
        Assert-Eq '快照里有的 NO_PROXY 项判为使用者的' $false (Test-IsOwnedProxyValue 'NO_PROXY' 'localhost')
        Assert-Eq '快照里没有的默认项仍归我们回收' $true (Test-IsOwnedProxyValue 'NO_PROXY' '127.0.0.1')
        Assert-Eq '快照里有的本机代理地址判为使用者的' $false (Test-IsOwnedProxyValue 'HTTP_PROXY' 'http://127.0.0.1:8080')
        # 判据必须与 Remove-UserEnvVars 同一套：那边逐项减默认集、快照里的原样留。
        # 所以「掺了我们默认项的混合值」要算我们写的（整份都在快照里才算使用者的），
        # 否则门槛判定「不用清」，回收函数却照样删掉其中几项——两个判据各说各话。
        Assert-Eq '掺了默认项的混合值算我们写的' $true (Test-IsOwnedProxyValue 'NO_PROXY' 'localhost,127.0.0.1,::1')
        Assert-Eq '全在快照里的值算使用者的' $false (Test-IsOwnedProxyValue 'NO_PROXY' 'localhost')
    } finally {
        Remove-Item -LiteralPath $bakKey -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host '  SKIP 快照归属判定（本机没有注册表）'
}

Write-Host '[2c] NO_PROXY reclaim (pure function, no registry)'
# 这一段测的是"用判据的那段循环"，不是判据本身。
# 上面 [2] 段把"什么算我们写的"钉得很死，但那些断言全在测 Test-IsOwnedProxyValue——
# 把 Remove-UserEnvVars 里逐项分类的循环改坏（比如删掉"快照里本来就有的条目原样留"
# 那一支），判据断言照样全绿，而用户的 NO_PROXY=localhost 会在 off 态被删掉。
# 循环已经抽成纯函数 Get-NoProxyAfterReclaim，所以这里可以直接喂值、不用动真实注册表。
$dnp = $DefaultNoProxy
# 关键用例：使用者的值里含一个**默认项**（localhost），它在快照里 -> 必须留。
# 而 127.0.0.1 在默认集里但不在快照里 -> 必须摘。这一对是唯一能区分两条分支的形状。
$got = Get-NoProxyAfterReclaim ("localhost,corp.example," + $dnp) 'localhost,corp.example' $dnp
Assert-Eq 'reclaim: 快照里的默认项原样留' $true ([bool](@($got -split ',') -contains 'localhost'))
Assert-Eq 'reclaim: 不在快照的默认项被摘掉' $false ([bool](@($got -split ',') -contains '127.0.0.1'))
Assert-Eq 'reclaim: 使用者的非默认项也留着' $true ([bool](@($got -split ',') -contains 'corp.example'))
# 没有快照时：默认项全是我们的，全摘；剩下的留着
$got2 = Get-NoProxyAfterReclaim ("corp.example," + $dnp) $null $dnp
Assert-Eq 'reclaim: 无快照时默认项全摘' 'corp.example' $got2
# 只剩我们的项：整份该删（返回 $null）
$got3 = Get-NoProxyAfterReclaim $dnp $null $dnp
Assert-Eq 'reclaim: 只剩我们的项时整份删除' $null $got3
# 快照里记着使用者的 NO_PROXY 原本就是空 -> 我们加的项照摘
$got4 = Get-NoProxyAfterReclaim 'example.com' 'example.com' $dnp
Assert-Eq 'reclaim: 使用者原值原样不动' 'example.com' $got4
# 大小写：使用者的写法要原样保留，不能顺手改成小写。
# 注意期望值里有三个条目：LocalHost、Corp.Example 是使用者的；默认集里那个 localhost
# 规范化后与快照里的 localhost 相等，所以它也算使用者的、同样保留。
# 这不是漏摘——"它是不是我们写的"按规范化后的值判，判到了就在快照里，就该留。
$got5 = Get-NoProxyAfterReclaim ('LocalHost,Corp.Example,' + $dnp) 'localhost,corp.example' $dnp
Assert-Eq 'reclaim: 保留使用者的原始大小写' 'LocalHost,Corp.Example,localhost' $got5
Assert-Eq 'reclaim: 大小写不同不算我们的（不被摘）' $true ([bool](@($got5 -split ',') -contains 'LocalHost'))

Write-Host '[2d] malformed state strings are refused, not silently accepted'
# 状态串只有两种合法形状：off，或 on:<1..65535>。
# 畸形的一律不许写、也不许报成功——"什么都没做却报成功"是最难查的一种故障：
# 屏幕上一切正常，只有终端连不上网。
# 为什么这里能安全地测：Invoke-EnvStateWrite 对畸形输入在**拿锁之前**就返回了，
# 所以这些断言不会碰注册表，也不会写用户的环境变量。
foreach ($bad in @('on:', 'garbage', 'on:abc', 'on:0', 'on:70000', 'on:-1')) {
    $r = $null
    try { $r = Invoke-EnvStateWrite $bad '' '' } catch { $r = 'threw' }
    Assert-Eq ("畸形状态串被拒：" + $bad) 1 $r
    # Apply-State 是它的调用方，也必须挡住而不是抛异常。
    # 它在监控主循环里跑：抛出去会被 catch 吞掉，$lastState 不更新，
    # 而变量可能已经被改过——状态与实际就此分叉，屏幕上完全看不出来。
    $ar = $null
    try { $ar = Apply-State $bad } catch { $ar = 'threw' }
    Assert-Eq ("Apply-State 对畸形串不抛异常：" + $bad) $false $ar
}
# 合法输入必须放行（off 与 unknown 不动变量，返回 0 = 没有失败）
foreach ($good in @('off', 'unknown', '')) {
    $r = $null
    try { $r = Invoke-EnvStateWrite $good '' '' } catch { $r = 'threw' }
    Assert-Eq ("合法状态串放行：" + $good) 0 $r
}

Write-Host '[2e] the mirror file has a self-heal path'
# 契约：Git Bash 那份终端同步读 terminal.env 判断"这几个值是不是我们写的"。
# 那个文件被删掉之后，必须有东西能重建它——否则已开着的窗口永远清不掉死代理，
# 用户看到的是 git/curl 全部 ECONNREFUSED 而错误里没有本工具的名字。
# 曾经它只在 Apply-State（状态翻转）里写，30 轮自愈那条路不写，
# 于是"删掉就再也回不来"。这条钉住"自愈也能重建"。
$mirrorPath = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "EnvProxy\terminal.env"
$mirrorBak = $null
if (Test-Path $mirrorPath) { $mirrorBak = Get-Content $mirrorPath -Raw -ErrorAction SilentlyContinue }
try {
    if (Test-Path $mirrorPath) { Remove-Item $mirrorPath -Force -ErrorAction SilentlyContinue }
    # 走自愈那条路（Invoke-EnvStateWrite），不是走 Apply-State
    $mirrorRc = Invoke-EnvStateWrite "on:7078" "" ""
    Assert-Eq '自愈能把被删的镜像文件重建出来' $true (Test-Path $mirrorPath)
    if (Test-Path $mirrorPath) {
        $mirrorLines = @(Get-Content $mirrorPath)
        Assert-Eq '重建出来的镜像含 we 写下的归属记录' $true (@($mirrorLines | Where-Object { $_ -like 'owned_*' }).Count -gt 0)
    }
} finally {
    if ($mirrorBak) { [System.IO.File]::WriteAllText($mirrorPath, $mirrorBak, (New-Object System.Text.UTF8Encoding($false))) }
}

Write-Host '[2f] every terminal-sync state has something to say'
# 契约：问题清单里说"终端同步没生效"时，往下一定找得到"终端同步"那一行。
# 曾经 State 叫 nohost、switch 处理的是 unknown，两者恰好错位，
# 于是那一项永远不打印——用户被指向一个不存在的提示。
# 这条枚举 Get-TerminalSyncState 可能返回的**全部**状态，逐个喂给渲染器。
foreach ($ss in @('ok', 'blocked', 'unpaired', 'missing', 'stale', 'nohost')) {
    $probeSt = Get-StatusSnapshot
    $probeSt.TermSync = @{ State = $ss; Detail = 'x'; Path = ''; Line = 0 }
    # 必须用 6>&1 重定向：状态页走 Write-Host（information stream），
    # 2>&1 只接错误流，捕获到的是 0 行——那样这条断言会永远红或永远绿，
    # 取决于怎么读结果，而两种都不说明任何事。
    $probeOut = @(Show-StatusSnapshot $probeSt 6>&1)
    # 判据不能只是"出现了'终端同步'四个字"——default 分支也会打印它，
    # 于是"正常态被误判成未知"这种 bug 会假绿（真发生过：补 nohost 时漏了 ok，
    # 屏幕上打成"终端同步 : 状态未知（ok）"，而这条断言当时是绿的）。
    # 现在要求：正常态必须说"已生效"，异常态不许出现"状态未知"。
    #
    # 状态行是**两段**渲染的（标签用 key、内容按状态上色），所以 6>&1 捕获到的是
    # 一行拆成的两个元素。这里先把同一个标签后面的内容接回去再判断，
    # 否则只会看到"终端同步 : "这半截，断言永远红（实测踩过）。
    $joined = [System.Collections.Generic.List[string]]::new()
    $pending = $null
    foreach ($o in $probeOut) {
        $s = [string]$o
        if ($s -match '(监控进程|开机自启|翻墙代理|终端同步|代理变量|版本)\s*:\s*$') {
            $pending = $s.TrimEnd()
        } elseif ($null -ne $pending) {
            $joined.Add(($pending + ' ' + $s.Trim()))
            $pending = $null
        } else {
            $joined.Add($s)
        }
    }
    if ($null -ne $pending) { $joined.Add($pending) }
    $syncLine = @($joined | Where-Object { $_ -match '终端同步' })
    $hasLine = $syncLine.Count -gt 0
    Assert-Eq ("终端同步状态必须有对应那一行：" + $ss) $true $hasLine
    if ($ss -eq 'ok') {
        Assert-Eq '正常态必须说"已生效"' $true (@($syncLine | Where-Object { $_ -match '已生效' }).Count -gt 0)
        Assert-Eq '正常态不许说"状态未知"' $false (@($syncLine | Where-Object { $_ -match '状态未知' }).Count -gt 0)
        Assert-Eq '正常态只打印一次（不许重复）' 1 $syncLine.Count
    } else {
        Assert-Eq ("异常态不许落进未知兜底：" + $ss) $false (@($syncLine | Where-Object { $_ -match '状态未知' }).Count -gt 0)
    }
}

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

Write-Host '[5] atomic file copy (every package file goes through this)'
$dir5 = New-TempDir 'envproxy_atomic_'
$src5 = Join-Path $dir5 'from.ps1'
$dst5 = Join-Path $dir5 'to.ps1'
[System.IO.File]::WriteAllText($src5, "Write-Host 'one'`n", (New-Object System.Text.UTF8Encoding($true)))
Copy-FileAtomic $src5 $dst5
Assert-Eq 'copy creates the destination' $true (Test-Path -LiteralPath $dst5)
Assert-Eq 'copy is byte exact' ((Get-Sha256Hex $src5)) ((Get-Sha256Hex $dst5))
Assert-Eq 'copy keeps the BOM' 'EF-BB-BF' (([BitConverter]::ToString([System.IO.File]::ReadAllBytes($dst5)[0..2])))
[System.IO.File]::WriteAllText($src5, "Write-Host 'two'`n", (New-Object System.Text.UTF8Encoding($false)))
Copy-FileAtomic $src5 $dst5
Assert-Eq 'overwrite replaces content exactly' ((Get-Sha256Hex $src5)) ((Get-Sha256Hex $dst5))
Assert-Eq 'overwrite drops the old BOM' '57-72-69' (([BitConverter]::ToString([System.IO.File]::ReadAllBytes($dst5)[0..2])))
Assert-Eq 'no temp file left behind' '0' (@(Get-ChildItem -LiteralPath $dir5 -Filter '*.envproxy-new*' -File).Count)
$deep = Join-Path $dir5 'win\lib\base.ps1'
Copy-FileAtomic $src5 $deep
Assert-Eq 'missing parent directories are created' $true (Test-Path -LiteralPath $deep)
Remove-Item -LiteralPath $dir5 -Recurse -Force

Write-Host '[6] package structure verification'
$pkg = New-TempDir 'envproxy_pkg_'
$bomEnc = New-Object System.Text.UTF8Encoding($true)
$plainEnc = New-Object System.Text.UTF8Encoding($false)
Write-TestFile (Join-Path $pkg 'VERSION') '9.9.9'
New-Item -Path (Join-Path $pkg 'win\lib'), (Join-Path $pkg 'mac') -ItemType Directory -Force | Out-Null
# The package must be complete under the content-set rule: the entry declares its libraries,
# and the platform folder may hold nothing beyond entry + menu + those libraries.
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\envproxy.ps1'), "# entry`n`$CoreLibs = @(`"base`", `"probe`")`n", $bomEnc)
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\打开菜单.cmd'), "@echo off`n", $plainEnc)
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\base.ps1'), '# lib', $bomEnc)
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\probe.ps1'), '# lib', $bomEnc)
[System.IO.File]::WriteAllText((Join-Path $pkg 'mac\envproxy.sh'), "#!/bin/bash`n", $plainEnc)
$threw = $false
try { Test-Package $pkg '9.9.9' 'win' } catch { $threw = $true }
Assert-Eq 'a well-formed package is accepted' $false $threw
Assert-Throws 'version mismatch is rejected' { Test-Package $pkg '1.2.3' 'win' }
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\base.ps1'), '# lib', $plainEnc)
Assert-Throws 'a library without BOM is rejected' { Test-Package $pkg '9.9.9' 'win' }
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\base.ps1'), '# lib', $bomEnc)
[System.IO.File]::WriteAllText((Join-Path $pkg 'mac\envproxy.sh'), "#!`r`n", $plainEnc)
Assert-Throws 'a CRLF shell script is rejected' { Test-Package $pkg '9.9.9' 'win' }
[System.IO.File]::WriteAllText((Join-Path $pkg 'mac\envproxy.sh'), "#!/bin/bash`n", $plainEnc)
Remove-Item -LiteralPath (Join-Path $pkg 'mac\envproxy.sh') -Force
Assert-Eq 'a win split without the mac entry is accepted' $false $(try { Test-Package $pkg '9.9.9' 'win'; $false } catch { $true })
[System.IO.File]::WriteAllText((Join-Path $pkg 'mac\envproxy.sh'), "#!/bin/bash`n", $plainEnc)
Remove-Item -LiteralPath (Join-Path $pkg 'win\envproxy.ps1') -Force
Assert-Throws 'a missing own-platform entry is rejected' { Test-Package $pkg '9.9.9' 'win' }
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\envproxy.ps1'), "# entry`n`$CoreLibs = @(`"base`", `"probe`")`n", $bomEnc)
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\probe.ps1'), ([char]0xFEFF).ToString(), $plainEnc)
Assert-Throws 'a BOM-only truncated file is rejected' { Test-Package $pkg '9.9.9' 'win' }
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\probe.ps1'), '', $plainEnc)
Assert-Throws 'a zero-byte script is rejected' { Test-Package $pkg '9.9.9' 'win' }
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\probe.ps1'), '# lib', $bomEnc)
# A package missing one declared library, or carrying a file nobody declared, must be refused:
# otherwise the overwrite step deletes the missing library as "stale" and still reports success.
Remove-Item -LiteralPath (Join-Path $pkg 'win\lib\probe.ps1') -Force
Assert-Throws 'a package missing a declared library is rejected' { Test-Package $pkg '9.9.9' 'win' }
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\probe.ps1'), '# lib', $bomEnc)
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\backdoor.ps1'), '# lib', $bomEnc)
Assert-Throws 'a package carrying an undeclared file is rejected' { Test-Package $pkg '9.9.9' 'win' }
Remove-Item -LiteralPath (Join-Path $pkg 'win\lib\backdoor.ps1') -Force
Remove-Item -LiteralPath $pkg -Recurse -Force

Write-Host '[6b] scoped install (split onto legacy tree)'
$leg = New-TempDir 'envproxy_scoped_'
$spk = New-TempDir 'envproxy_split_'
$stg = New-TempDir 'envproxy_stage_'
New-Item -Path (Join-Path $leg 'win\lib'), (Join-Path $leg 'mac'), (Join-Path $leg 'release-notes') -ItemType Directory -Force | Out-Null
New-Item -Path (Join-Path $spk 'win\lib'), (Join-Path $spk 'release-notes') -ItemType Directory -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $leg 'win\envproxy.ps1'), '# entry OLD', $bomEnc)
[System.IO.File]::WriteAllText((Join-Path $leg 'win\lib\base.ps1'), '# lib OLD', $bomEnc)
Write-TestFile (Join-Path $leg 'win\old.cmd') 'stale'
Write-TestFile (Join-Path $leg 'mac\envproxy.sh') "#!/bin/bash`n# mac OLD"
Write-TestFile (Join-Path $leg 'mac\old.sh') 'stale'
Write-TestFile (Join-Path $leg 'VERSION') '1.0.0'
[System.IO.File]::WriteAllText((Join-Path $spk 'win\envproxy.ps1'), '# entry NEW', $bomEnc)
[System.IO.File]::WriteAllText((Join-Path $spk 'win\lib\base.ps1'), '# lib NEW', $bomEnc)
Write-TestFile (Join-Path $spk 'release-notes\v9.md') 'notes'
Write-TestFile (Join-Path $spk 'VERSION') '9.9.9'
Install-Package -SrcRoot $spk -ProjectRoot $leg -Stage $stg -ShipDirs @('win', 'release-notes', 'assets')
Assert-Eq 'scoped write updates own entry' '# entry NEW' ([System.IO.File]::ReadAllText((Join-Path $leg 'win\envproxy.ps1'), [System.Text.Encoding]::UTF8))
Assert-Eq 'scoped delete removes own stale file' $false (Test-Path -LiteralPath (Join-Path $leg 'win\old.cmd'))
Assert-Eq 'other platform entry untouched' "#!/bin/bash`n# mac OLD" (Get-Content -LiteralPath (Join-Path $leg 'mac\envproxy.sh') -Raw)
Assert-Eq 'other platform stale file left alone' $true (Test-Path -LiteralPath (Join-Path $leg 'mac\old.sh'))
Assert-Eq 'shared VERSION updated' '9.9.9' ((Get-Content -LiteralPath (Join-Path $leg 'VERSION') -Raw).Trim())
# rollback: lock the destination entry, the write must fail and originals come back
$fs = [System.IO.File]::Open((Join-Path $leg 'win\envproxy.ps1'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
$rbThrew = $false
try { Install-Package -SrcRoot $spk -ProjectRoot $leg -Stage $stg -ShipDirs @('win', 'release-notes', 'assets') } catch { $rbThrew = $true }
$fs.Close()
Assert-Eq 'locked write fails loudly' $true $rbThrew
Assert-Eq 'rollback restores entry' '# entry NEW' ([System.IO.File]::ReadAllText((Join-Path $leg 'win\envproxy.ps1'), [System.Text.Encoding]::UTF8))
Remove-Item -LiteralPath $leg -Recurse -Force
Remove-Item -LiteralPath $spk -Recurse -Force
Remove-Item -LiteralPath $stg -Recurse -Force

Write-Host '[7] the library set declared by the entry'
# The entry is a thin loader: it owns the library list and nothing else. These assertions keep
# that budget from eroding silently.
$entryText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '../win/envproxy.ps1'), [System.Text.Encoding]::UTF8)
$declaredList = [regex]::Match($entryText, '\$CoreLibs\s*=\s*@\(([^)]*)\)').Groups[1].Value
$declared = @([regex]::Matches($declaredList, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
$actual = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../win/lib') -Filter *.ps1 -File | ForEach-Object { $_.BaseName } | Sort-Object)
Assert-Eq 'declared libraries match the lib folder' ($declared -join ',') ($actual -join ',')
$empty = @($declared | Where-Object {
    $p = Join-Path $PSScriptRoot ("../win/lib/{0}.ps1" -f $_)
    ([regex]::Matches([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8), '(?m)^function\s')).Count -eq 0
})
Assert-Eq 'every library defines at least one function' '0' ($empty.Count)
Assert-Eq 'the entry stays a thin loader' $true (@([regex]::Matches($entryText, '(?m)^function\s')).Count -le 6)

Write-Host '[8] autorun launcher command'
# The command line written into the Run key has one source of truth; the installer's read-back
# check and the self-heal comparison both compare against it, so its shape is an invariant.
$cmd = Get-LauncherCommand
Assert-Eq 'launcher command points at the launcher file' $true ($cmd -like ('*' + $LauncherPath + '*'))
Assert-Eq 'launcher command hides the window' $true ($cmd -like '*WindowStyle Hidden*')
Assert-Eq 'launcher command bypasses execution policy' $true ($cmd -like '*ExecutionPolicy Bypass*')

Write-Host '[9] the monitor launch target'
# The monitor is started from the entry script, and libraries must never answer "where am I" on
# their own: inside a library $PSCommandPath / $PSScriptRoot point at the library file, so using
# them as the entry path starts a file that cannot run on its own (no monitor, and no log line).
$entryFile = Join-Path $PSScriptRoot '../win/envproxy.ps1'
Assert-Eq 'the entry publishes its own path' ((Get-Item -LiteralPath $entryFile).FullName) ((Get-Item -LiteralPath $ScriptPath).FullName)
Assert-Eq 'the script directory derives from it' ((Get-Item -LiteralPath (Split-Path -Parent $entryFile)).FullName) ((Get-Item -LiteralPath $ScriptDir).FullName)
$launch = @(Get-MonitorLaunchArgs)
Assert-Eq 'launch args end with -File' '-File' $launch[-2]
Assert-Eq 'launch args quote the entry path' ('"{0}"' -f (Get-Item -LiteralPath $entryFile).FullName) $launch[-1]
Assert-Eq 'launch target is the entry, not a library' 'envproxy.ps1' (Split-Path -Leaf ($launch[-1].Trim('"')))
Assert-Eq 'launch target exists' $true (Test-Path -LiteralPath ($launch[-1].Trim('"')))
# Confirming a freshly started monitor judges by the pid file the monitor writes itself (it writes
# it only after it owns the singleton). "Some process has this script on its command line" is not
# enough: the process that just lost the singleton race looks like that for a moment too, and that
# is how an installer came to print "started" while nothing was running.
$dir9 = New-TempDir 'envproxy_pid_'
$savedPidFile = $PidFile
$PidFile = Join-Path $dir9 'monitor.pid'
Assert-Eq 'no pid file is not a confirmed monitor' '' (Get-MonitorProcessFromPidFile)
Write-TestFile $PidFile '999999'
Assert-Eq 'a dead pid is not a confirmed monitor' '' (Get-MonitorProcessFromPidFile)
$PidFile = $savedPidFile
Remove-Item -LiteralPath $dir9 -Recurse -Force

Write-Host '[10] judging a finished install'
# The updater decides the finish step worked by reading the install root's pid file, never by the
# child's exit code: PowerShell 5.1 cannot read ExitCode after Start-Process -PassThru (it returns
# empty), so treating "unreadable" as failure makes every update run the fallback and tear down the
# monitor it had just started.
$root10 = New-TempDir 'envproxy_finish_'
New-Item -Path (Join-Path $root10 'win\monitor') -ItemType Directory -Force | Out-Null
Assert-Eq 'no pid file is not a finished install' $false (Test-InstallRootMonitor $root10)
Write-TestFile (Join-Path $root10 'win\monitor\monitor.pid') '999999'
Assert-Eq 'a dead pid is not a finished install' $false (Test-InstallRootMonitor $root10)
Write-TestFile (Join-Path $root10 'win\monitor\monitor.pid') ([string]$PID)
Assert-Eq 'a live non-monitor pid is not a finished install' $false (Test-InstallRootMonitor $root10)
Remove-Item -LiteralPath $root10 -Recurse -Force

Write-Host '[10b] status display stays read-only'
# 契约：状态显示永不写文件。
# 这条原来靠一个 -NoLog 开关守着（探测层会写日志，只读路径把它关掉）。
# 那是"错位 + 补丁"：probe 调 runtime 的日志函数本身就是反向依赖，开关只是把它盖住。
# 现在探测层根本不写日志——它只把"枚举成没成、为什么"放进脚本级变量，记录由调用方决定。
# 于是这条契约变成结构性的：**没有任何开关可以忘传**。
# 断言改成钉住这个结构：探测层里不许出现写日志的调用。
$probeSrc = Get-Content (Join-Path $ScriptDir 'lib\probe.ps1') -Raw -Encoding UTF8
# 只数**真正的调用**（行首不是注释且带左括号）：解释性注释里提到这个函数名是正常的，
# 而"-match 'Write-MonitorLog'" 会把注释也算进去，于是把"已经改对"报成"没改"。
# 逐行数真正的调用：跳过注释行。用行长而不是正则的 \s*——\s 会吃掉换行，
# 跨行匹配会让整条判据失效（实测踩到过：变异后命中数仍是 0，断言假绿）。
$probeCalls = 0
foreach ($pl in ($probeSrc -split "`r?`n")) {
    $plTrim = $pl.Trim()
    if (-not $plTrim) { continue }
    if ($plTrim.StartsWith('#')) { continue }
    # 用 Contains 而不是 -match：带括号的正则在 PowerShell 里这里匹配不到，
    # 而且它失败时只返回 False、不报错——一条永远为假的判据比没有判据更糟
    # （实测踩到过：变异注入了真实调用，断言仍然绿）。
    if ($plTrim.Contains('Write-MonitorLog')) { $probeCalls++ }
}
Assert-Eq 'probe 层不写日志（结构保证，不靠开关）' 0 $probeCalls
Assert-Eq 'probe 层把失败原因交出来' $true ($probeSrc -match 'PortEnumerationReason')
Assert-Eq 'Get-ActiveProxyPort 不再有 NoLog 参数' $false ((Get-Command Get-ActiveProxyPort).Parameters.ContainsKey('NoLog'))
$opsSrc = Get-Content (Join-Path $ScriptDir 'lib\ops.ps1') -Raw -Encoding UTF8
Assert-Eq '状态页调探测时不传任何开关' $false ($opsSrc -match 'Get-ActiveProxyPort[^\r\n]*-NoLog')

# 卸载必须把运行时状态清干净：漏一个就"没恢复到装之前"，而屏幕照样报"已完成"。
# 具体后果（都实际发生过或差点发生）：
#   version.cache     -> 重装后状态页显示上一次安装留下的版本号；
#   update.inprogress -> 被读成"上次更新没完成"，其实是上一次安装的经历；
#   stopped.intent    -> 重装后状态页说"你点过停止"而监控正在跑；
#   monitor.beat      -> 上一个进程的心跳，留着会让"还活着吗"读到过期答案。
# 这里抽源码核对：不 purge（保留日志）那一条分支必须逐个点到这些名字。
# 判据取"Uninstall 函数体"而不是整个文件——整个文件里这些名字到处都是，
# 拿全文匹配等于断言恒真（这类假绿在本项目里踩过好几次）。
$unStart = $opsSrc.IndexOf('function Uninstall-EnvProxy')
Assert-Eq '卸载函数存在' $true ($unStart -ge 0)
$unBody = ''
if ($unStart -ge 0) {
    $unNext = $opsSrc.IndexOf("`nfunction ", $unStart + 10)
    if ($unNext -lt 0) { $unNext = $opsSrc.Length }
    $unBody = $opsSrc.Substring($unStart, $unNext - $unStart)
}
$unMissing = @()
foreach ($unName in @('$PidFile', '$StopFlag', '$StopIntentFile', '$VersionCacheFile', '$UpdateInProgressFile', '$HeartbeatFile')) {
    if (-not $unBody.Contains('Remove-ItemSafe ' + $unName)) { $unMissing += $unName }
}
Assert-Eq '卸载: 运行时状态逐项点到（不留过期答案）' '' ($unMissing -join ' ')
# 目录只删空的：使用者在 %USERPROFILE%\.envproxy 里自己放的东西一个字节都不许动。
Assert-Eq '卸载: 工具目录只在空时才删（不碰使用者的东西）' $true ($unBody -match 'Get-ChildItem -LiteralPath \$epHome')

Write-Host '[11] the menu dispatch table'
# The menu maps numbers to existing entry switches; the shells call back through these
# switches, so every number must resolve and every switch must exist.
#
# The expected key set is DERIVED from $MenuItems, not written out literally.
# A literal list has to be edited every time a menu item is added, and the way that
# fails is silent: the assertion just says "the count is wrong" and the next person
# edits the number without checking that the new item is wired to a real switch.
# Deriving it means adding an entry needs no test edit, while every entry still gets
# checked for the two things that actually matter (unique key, resolvable switch).
$menuKeys = @($MenuItems | ForEach-Object { $_.Key })
Assert-Eq 'menu has one entry per item' @($MenuItems).Count $menuKeys.Count
Assert-Eq 'menu keys are unique' $menuKeys.Count (@($menuKeys | Select-Object -Unique).Count)
foreach ($k in $menuKeys) { Assert-Eq ('menu key is a single char: ' + $k) 1 $k.Length }
# Every non-quit item must name a switch the entry actually answers.
$entryTxt = [System.IO.File]::ReadAllText((Join-Path (Get-Location) 'win/envproxy.ps1'))
$menuSwitches = @($MenuItems | Where-Object { $_.Switch } | ForEach-Object { $_.Switch })
foreach ($sw in $menuSwitches) {
    Assert-Eq ('menu switch -' + $sw + ' is declared in the entry param block') $true ($entryTxt -match ('\[switch\]\$' + $sw + '\b'))
    Assert-Eq ('menu switch -' + $sw + ' is dispatched') $true ($entryTxt -match ('if \(\$' + $sw + '\)'))
}
# Quit is the only item without a switch, and it must still carry a key.
Assert-Eq 'only the quit item has no switch' 1 (@($MenuItems | Where-Object { -not $_.Switch }).Count)
# Help exists and actually explains the three things a confused user needs.
# Asserting only "the function exists" is not enough: help text that says nothing
# still "exists". These keywords are the load-bearing facts.
Assert-Eq 'Show-Help is defined' 'Function' (Get-Command Show-Help -ErrorAction SilentlyContinue).CommandType
# Help is paginated: an index plus one topic per screen. The full text must still be
# reachable for non-interactive callers, so both shapes have to hold:
#   - every topic resolves to a body, and the index lists every topic key;
#   - the concatenation of all topics still carries the load-bearing facts.
$helpTopics = @(Get-HelpTopics)
Assert-Eq 'help has topics' $true ($helpTopics.Count -ge 7)
$helpIdx = Format-HelpIndex
foreach ($t in $helpTopics) {
    Assert-Eq ('help topic ' + $t.Key + ' renders') $true ($null -ne (Format-HelpTopic $t.Key))
    Assert-Eq ('help index lists topic ' + $t.Key) $true ($helpIdx -match ('(?m)^\s*' + [regex]::Escape($t.Key) + '\s{2}'))
    Assert-Eq ('help topic ' + $t.Key + ' has a title') $true (-not [string]::IsNullOrWhiteSpace($t.Title))
}
Assert-Eq 'help topic body is never empty' $true (@($helpTopics | Where-Object { @($_.Lines).Count -eq 0 }).Count -eq 0)
$helpTxt = (Format-HelpAll)
Assert-Eq 'help explains the Enter timing' $true ($helpTxt -match '回车')
Assert-Eq 'help points at install/repair as the catch-all' $true ($helpTxt -match '安装 / 修复')
Assert-Eq 'help gives the per-window switch' $true ($helpTxt -match 'ENVPROXY_TERM')
# Every screen ends with the way back out. Without it a user who lands on a topic
# has no idea how to leave, which is exactly the "wall of text" problem pagination solves.
Assert-Eq 'a topic screen says how to go back' $true ((Format-HelpTopic '1') -match '直接回车')
# 交互只有两种操作：输数字、直接回车。屏幕上不能出现 n / p / m / a 这类字母导航——
# 用户记不住哪个键管哪件事，而这正是之前被抱怨的地方。
# 这条钉住的是「文案里不许再出现字母导航」，不是措辞本身。
$topicText = (Format-HelpTopic '1')
Assert-Eq 'a topic screen offers no letter keys' $false ($topicText -match 'n = |p = |m = |a 看')
$indexText = (Format-HelpIndex)
Assert-Eq 'the help index offers no letter keys' $false ($indexText -match 'n = |p = |m = |a 看')
Assert-Eq 'the help index says what Enter does' $true ($indexText -match '直接回车')
# 每一行都带一个明确角色，屏幕才有层次，而不是一整屏灰。
# 角色由内容自己声明（行首标记），不从行的形状去猜——猜的判据注定会错：
# 同一屏里 `set HTTP_PROXY=…` 判成命令、`PowerShell  $env:...` 判成说明，
# 用户看到的就是"配色坏了"。
$roleSeen = @{}
foreach ($t in $helpTopics) {
    foreach ($r in (Get-HelpRenderedLines $t.Lines)) {
        $roleSeen[$r.Role] = $true
        foreach ($sg in $r.Segments) { $roleSeen[$sg.Role] = $true }
    }
}
foreach ($r in @('heading', 'cmd', 'text', 'item', 'key', 'value', 'dim')) {
    Assert-Eq ('help uses the ' + $r + ' role') $true $roleSeen.ContainsKey($r)
}
# 配色契约：命令色必须一眼可辨。与 Mac 侧同一组断言（那边在 test-mac-pure.sh）。
#
# 原来这里是空的：只有"角色已在表里定义"一条，把 cmd 改成和标题一样的青色也照样绿。
# 用户报的就是这个——命令、大标题、段标题同色，一眼分不清哪行能整行复制去跑。
$cmdColor = Get-StyleColorName 'cmd'
Assert-Eq 'cmd colour is set (not the default foreground)' $true ($cmdColor -ne 'none')
Assert-Eq 'cmd colour differs from the screen title' $true ($cmdColor -ne (Get-StyleColorName 'title'))
Assert-Eq 'cmd colour differs from section headings' $true ($cmdColor -ne (Get-StyleColorName 'heading'))
$clash = @()
foreach ($r in @('item', 'key', 'value', 'warn', 'dim', 'text')) {
    if ((Get-StyleColorName $r) -eq $cmdColor) { $clash += $r }
}
Assert-Eq 'cmd colour clashes with no other role' '' ($clash -join ' ')
# 每个角色的颜色名都要能在映射表里查到：写错一个名字不会报错，只会静默变默认色。
$unresolved = @()
foreach ($r in $StyleRoles) {
    $n = Get-StyleColorName $r
    if ($n -eq 'none') { continue }
    if (-not (Get-StyleColor $r)) { $unresolved += ($r + '=' + $n) }
}
Assert-Eq 'every role resolves to a real console colour' '' ($unresolved -join ' ')
# 用到的角色必须都在配色表里：写错一个角色名不会报错，只会静默变成默认色，
# 而"这一行怎么没颜色"正是这次要治的那类毛病。
# blank/row 是排版结构（空行、多列行），不是颜色，不参与这条断言。
foreach ($r in $roleSeen.Keys) {
    if ($r -eq 'blank' -or $r -eq 'row') { continue }
    Assert-Eq ('role ' + $r + ' is defined in the style table') $true ($StyleRoles -contains $r)
}
# 屏幕形状：这一类坏法（命令被转义吃掉、混进开发机路径、行太长折行、
# 同一句写两遍、整屏超出终端高度）靠"关键字还在不在"是查不出来的——
# 坏行里往往还含有别的行的关键字，于是断言照样全绿。
# 所以直接量屏幕上会出现的形状，一次挡住一整类。
# 量的是真实渲染结果（$rendered），不是正文数组：标题、空行、导航行、提示行
# 都占屏幕，只数正文会漏掉它们。
foreach ($t in $helpTopics) {
    $rendered = @((Format-HelpTopic $t.Key) -split "`n")
    # 1) 一屏放得下：超出的部分会被终端切掉，而被切掉的常常是底部的「怎么退出」。
    # 上限来自 base 层的具名常量，不在这里写死数字：写死的话，改常量时测试
    # 还在守旧值，两处会悄悄分叉。
    Assert-Eq ('topic ' + $t.Key + ' renders within ' + $HelpMaxLines + ' lines') $true ($rendered.Count -le $HelpMaxLines)
    # 2) 相邻两行一模一样 = 编辑时留下的重复段，用户会以为屏幕坏了。
    $dupFound = $false
    for ($i = 1; $i -lt $rendered.Count; $i++) {
        if ($rendered[$i] -ne '' -and $rendered[$i] -eq $rendered[$i - 1]) { $dupFound = $true; break }
    }
    Assert-Eq ('topic ' + $t.Key + ' has no duplicated line') $false $dupFound
    # 3) 行宽：超宽会让终端硬折行。例外是「一整条命令」——命令是给用户整条复制的，
    #    硬拆成两行会让复制变成两段、中间夹换行，粘进终端就成了两条命令，比折行更难用。
    #    所以判据是「超宽的行必须是一条命令（缩进 + 不含中文）」，而不是「一律不许超」。
    #    这比「一律不许超」弱，但它诚实表达了真实约束，而不是假装没超。
    $tooWide = ''
    foreach ($ln in $rendered) {
        $w = 0
        foreach ($ch in $ln.ToCharArray()) { $w += if ([int]$ch -gt 0x2E80) { 2 } else { 1 } }
        if ($w -le 80) { continue }
        if ($ln -match '^\s+\S' -and $ln -notmatch '[\u4e00-\u9fff]') { continue }
        $tooWide = $ln; break
    }
    Assert-Eq ('topic ' + $t.Key + ' has no line wider than 80 columns') '' $tooWide
    # 4) 不许混进本机的绝对路径：那一屏是给别人看的，写死 C:\Users\某人 会让别人困惑，
    #    换台机器就失准。$PROFILE 这类环境自带变量才是正确写法。
    $absPath = ''
    foreach ($ln in $rendered) { if ($ln -match '[A-Za-z]:\\Users\\|/Users/') { $absPath = $ln; break } }
    Assert-Eq ('topic ' + $t.Key + ' has no hardcoded home path') '' $absPath
    # 5) 命令不许残缺。判据只看「长得像命令的行」（4 格以上缩进 + 含 = 或 $ 或 set/unset），
    #    普通说明文字里出现 = 是正常的（比如「直接回车 = 回目录」），不能一起判死。
    #    要挡住的是这几类真实事故：反引号残留、变量名被吃成空、等号左边没名字。
    $broken = ''
    foreach ($ln in $rendered) {
        if ($ln -notmatch '^\s{4,}\S') { continue }
        # 反引号单独判：它不可能出现在任何正常文案里，不需要先满足"像命令"。
        if ($ln.IndexOf([char]96) -ge 0) { $broken = $ln; break }
        if ($ln -notmatch '=|\$|set |unset |export ') { continue }
        if ($ln -match '\$(\s|=|$)') { $broken = $ln; break }
        if ($ln -match '^\s+[=:]\s') { $broken = $ln; break }
    }
    Assert-Eq ('topic ' + $t.Key + ' has no broken command') '' $broken
}

# A table entry that is never printed is a feature the user cannot reach: the menu once
# printed a hardcoded list and [6] Help never appeared on screen even though the table
# had it. Show-Menu bails out under redirected input, so it cannot be exercised here --
# instead call the very renderer the menu prints, so this assertion cannot drift away
# from the real output (a locally rebuilt string would keep passing after a redesign).
$menuOut = Format-MenuText
foreach ($k in $menuKeys) { Assert-Eq ('menu prints key ' + $k) $true ($menuOut -match ('(?m)^\s*' + [regex]::Escape($k) + '\s{2}')) }
# 每一项都要有一句人话解释，包括「0 退出」。按 Switch 计数会漏掉退出项（它没有子命令），
# 于是"加了一项却没写提示"这种疏漏反而检查不到。
Assert-Eq 'every menu item has a hint' $true (@($MenuItems | Where-Object { -not $_.Hint }).Count -eq 0)
# Grouping is presentation only: every entry belongs to a declared group, and the
# Groups keep their order so the screen reads top to bottom the way the table declares it.
# Both the allowed group names and the expected order are DERIVED from $MenuItems:
# a literal list here would need editing every time a group is added, and the symptom
# of forgetting is a confusing "item has no group" on an item that plainly has one.
$declaredGroups = @(Get-MenuGroups)
foreach ($mi in $MenuItems) { Assert-Eq ('menu item ' + $mi.Key + ' has a group') $true ($mi.Group -in $declaredGroups) }
Assert-Eq 'menu groups are unique' $declaredGroups.Count (@($declaredGroups | Select-Object -Unique).Count)
$menuTextOrder = @()
foreach ($g in $declaredGroups) { $menuTextOrder += $menuOut.IndexOf($g) }
$orderOk = $true
for ($i = 1; $i -lt $menuTextOrder.Count; $i++) {
    if ($menuTextOrder[$i-1] -ge $menuTextOrder[$i]) { $orderOk = $false }
}
Assert-Eq 'menu groups render in declared order' $true $orderOk


# Test-CanPrompt guards every interactive screen. It once called itself instead of reading
# [Console]::IsInputRedirected: infinite recursion, stack overflow, swallowed by catch, so it
# always returned $false -- the menu printed one line and quit on every real console, and
# -Help took 14s. No behavioural test catches that (the suite runs redirected, where False is
# the CORRECT answer). So pin the shape: the body must not mention its own name.
$canPromptSrc = (Get-Command Test-CanPrompt).Definition
Assert-Eq 'Test-CanPrompt does not call itself' $false ($canPromptSrc -match 'Test-CanPrompt\s*\)')
Assert-Eq 'Test-CanPrompt reads IsInputRedirected' $true ($canPromptSrc -match 'IsInputRedirected')
# Same class of mistake, other direction: a guard that always says "no prompt" would make the
# menu unreachable too. Pin that the redirect check is a plain property read, in a single line.
Assert-Eq 'Test-CanPrompt has no nested function' $false ($canPromptSrc -match 'function\s+Test-CanPrompt')
Write-Host '[12] the online update source table'
# The updater walks an ordered source table and takes the first source that answers, so a broken
# table degrades silently: updates keep "working" until the day the official source is unreachable.
# Two properties are load-bearing:
#   - it must ALWAYS come back as a list. PowerShell unwraps a single-element collection, so with
#     only the official source enabled (the normal state) the
#     caller would receive one hashtable instead of a list of sources: foreach then walks its
#     key/value pairs, and .Count reports the number of keys (4) rather than the number of sources.
#   - every entry must carry the four fields the walker reads, with the @@ placeholder intact.
$srcTable0 = Get-UpdateSources
Assert-Eq 'sources always come back as a list' 'Object[]' $srcTable0.GetType().Name
Assert-Eq 'at least one source is usable' $true ($srcTable0.Count -ge 1)
Assert-Eq 'the official source stays first' 'official' $UpdateSourceTable[0].Id
foreach ($s in $UpdateSourceTable) {
    Assert-Eq ('source ' + $s.Name + ' declares exactly Id/Name/Preferred/Api/Web/Base/ApiRepo') 7 (@($s.Keys).Count)
    Assert-Eq ('source ' + $s.Name + ' keeps a placeholder in Api') $true ($s.Api -like '*@@*')
    Assert-Eq ('source ' + $s.Name + ' keeps a placeholder in Web') $true ($s.Web -like '*@@*')
    Assert-Eq ('source ' + $s.Name + ' keeps a placeholder in Base') $true ($s.Base -like '*@@*')
    Assert-Eq ('source ' + $s.Name + ' keeps a placeholder in ApiRepo') $true ($s.ApiRepo -like '*@@*')
    Assert-Eq ('source ' + $s.Name + ' prefers a known path') $true (@('Api', 'Web') -contains $s.Preferred)
}
# Picking an asset id out of a release payload decides whether a package download ever leaves
# api.github.com for the flaky github.com host, so the shape rules are pinned here: the id must be
# the one belonging to the named asset (never the release id, never the uploader id), and any
# unparsable payload must come back empty so the caller falls back to the direct URL.
$assetJson = '{"id":99,"tag_name":"v1.2.3","assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/12345","id":12345,"name":"EnvProxy-win.zip","uploader":{"login":"u","id":777}},{"url":"https://api.github.com/repos/o/r/releases/assets/67890","id":67890,"name":"EnvProxy-mac.tar.gz"}]}'
# The sample mirrors what the server actually sends: indented, with a space after each colon.
# Pinning only a minified payload would pin our own assumption instead of the outside world.
$assetPretty = @'
{
  "id": 99,
  "tag_name": "v1.2.3",
  "assets": [
    {
      "url": "https://api.github.com/repos/o/r/releases/assets/12345",
      "id": 12345,
      "name": "EnvProxy-win.zip",
      "uploader": { "login": "u", "id": 777 }
    },
    {
      "url": "https://api.github.com/repos/o/r/releases/assets/67890",
      "id": 67890,
      "name": "EnvProxy-mac.tar.gz"
    }
  ]
}
'@
Assert-Eq 'an asset id is taken from the indented payload the server really sends' '67890' ((Get-AssetFromJson $assetPretty 'EnvProxy-mac.tar.gz').Id)
Assert-Eq 'an asset id is taken by file name' '67890' ((Get-AssetFromJson $assetJson 'EnvProxy-mac.tar.gz').Id)
Assert-Eq 'the first asset is still matched exactly' '12345' ((Get-AssetFromJson $assetJson 'EnvProxy-win.zip').Id)
Assert-Eq 'a missing file name yields nothing' '' (Get-AssetFromJson $assetJson 'EnvProxy-nope.zip')
Assert-Eq 'an unparsable payload yields nothing' '' (Get-AssetFromJson 'not json' 'EnvProxy-win.zip')
Assert-Eq 'an empty payload yields nothing' '' (Get-AssetFromJson '' 'EnvProxy-win.zip')
# The file name must match byte for byte: GitHub asset names are case sensitive, and PowerShell's
# -eq is NOT — without -ceq a differently-cased name would match and download the wrong file.
Assert-Eq 'a differently cased file name does not match' '' (Get-AssetFromJson $assetJson 'envproxy-mac.tar.gz')
# The id comes from the url (the endpoint we actually GET); the id field is only a fallback.
$assetUrlFirst = '{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/555","id":999,"name":"EnvProxy-win.zip"}]}'
Assert-Eq 'the url wins over the id field' '555' ((Get-AssetFromJson $assetUrlFirst 'EnvProxy-win.zip').Id)
$assetIdOnly = '{"assets":[{"url":"https://example.invalid/x","id":666,"name":"EnvProxy-win.zip"}]}'
Assert-Eq 'the id field is used when the url has no number' '666' ((Get-AssetFromJson $assetIdOnly 'EnvProxy-win.zip').Id)
# A malformed id must not reach the URL: 0, a leading zero and an absurd length are all wrong.
foreach ($badId in @('0', '007', '12345678901234567890')) {
    $badJson = '{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/' + $badId + '","name":"EnvProxy-win.zip"}]}'
    Assert-Eq ("a malformed id is refused: " + $badId) '' (Get-AssetFromJson $badJson 'EnvProxy-win.zip')
}
# The digest is GitHub's own checksum of the asset. A wrong shape counts as no digest at all
# (older assets do not carry the field).
$digestOk = 'sha256:' + ('a' * 64)
$assetDigest = '{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/777","name":"EnvProxy-win.zip","digest":"' + $digestOk + '"}]}'
Assert-EqCase 'a valid digest is taken' $digestOk ((Get-AssetFromJson $assetDigest 'EnvProxy-win.zip').Digest)
$assetDigestNull = '{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/777","name":"EnvProxy-win.zip","digest":null}]}'
Assert-Eq 'a null digest counts as no digest' '' ((Get-AssetFromJson $assetDigestNull 'EnvProxy-win.zip').Digest)
$assetDigestBad = '{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/777","name":"EnvProxy-win.zip","digest":"sha256:XYZ"}]}'
Assert-Eq 'a malformed digest counts as no digest' '' ((Get-AssetFromJson $assetDigestBad 'EnvProxy-win.zip').Digest)
# Reading a tag out of a redirect target is shape-checked, and that check is not cosmetic: a repo
# that got renamed answers /releases/latest with a redirect to the renamed repo's path, whose last
# segment is the literal "latest". Taking the tail blindly would turn that into a version number
# and then into a download URL built from garbage.
Assert-Eq 'a tag-page redirect yields its tag' 'v0.3.2' (Get-TagFromLocation 'https://github.com/owner/repo/releases/tag/v0.3.2')
Assert-Eq 'a renamed-repo redirect yields nothing' '' (Get-TagFromLocation 'https://github.com/new-owner/repo/releases/latest')
Assert-Eq 'a tag with parentheses survives intact' 'v2026.09(jdk25)' (Get-TagFromLocation 'https://github.com/x/y/releases/tag/v2026.09(jdk25)')
Assert-Eq 'an empty redirect target yields nothing' '' (Get-TagFromLocation '')
Assert-Eq 'a location without a tag segment yields nothing' '' (Get-TagFromLocation 'https://github.com/owner/repo/releases')
# The web path answers with a 302, and a 302 is not a success status code. Reading the status
# before the redirect target turns this whole fallback into a dead path -- and since "network"
# outranks "quota" in the failure table, it also flattens the rate limit the API path did detect.
# So the redirect is exercised against a real local server here: a unit test on the pure
# function alone would never have caught it.
$srv = Start-OneShotServer 302 @{ Location = "http://127.0.0.1:0/owner/repo/releases/tag/v7.7.7" } ''
try {
    $webResult = Get-TagFromWebVia "http://127.0.0.1:$($srv.Port)/owner/repo/releases/latest" ""
    Assert-Eq 'the web path reads the tag out of a 302 redirect' 'v7.7.7' $webResult.Tag
    Assert-Eq 'a 302 is not a failure' '' $webResult.Failure
} finally { Stop-OneShotServer $srv }
# The API path has to tell a rate limit apart from a refusal, and it does it by reading
# X-RateLimit-Remaining. Getting that wrong sends the user off to switch on a proxy for
# something that will be fine in an hour.
$srv = Start-OneShotServer 403 @{ 'X-RateLimit-Remaining' = '0' } '{"message":"API rate limit exceeded"}'
try {
    $null = Invoke-UpdateText "http://127.0.0.1:$($srv.Port)/repos/o/r/releases/latest"
    Assert-Eq 'a rate limited version query is reported as a quota problem' 'quota' $script:VersionQueryFailure
} finally { Stop-OneShotServer $srv }
$srv = Start-OneShotServer 403 @{ 'X-RateLimit-Remaining' = '42' } '{"message":"Forbidden"}'
try {
    $null = Invoke-UpdateText "http://127.0.0.1:$($srv.Port)/repos/o/r/releases/latest"
    Assert-Eq 'a refused version query with quota left is reported as a server problem' 'server' $script:VersionQueryFailure
} finally { Stop-OneShotServer $srv }
# The download is checked against the digest GitHub publishes for the asset. That digest comes
# with the asset listing we already fetched, so the check costs no extra request and no extra
# download. A release without the field is simply not checked -- refusing to update over a
# missing field would block every older release.
$digestDir = New-TempDir 'ep-digest'
$digestFile = Join-Path $digestDir 'pkg.zip'
[System.IO.File]::WriteAllText($digestFile, 'hello')
$digestReal = 'sha256:' + (Get-Sha256Hex $digestFile)
Assert-Eq 'a matching digest passes' 'ok' (Test-AssetDigest $digestFile $digestReal)
Assert-Eq 'a wrong digest is caught' 'mismatch' (Test-AssetDigest $digestFile ('sha256:' + ('0' * 64)))
Assert-Eq 'no digest means no check' 'skip' (Test-AssetDigest $digestFile '')
Assert-Eq 'a malformed digest is not a pass' 'mismatch' (Test-AssetDigest $digestFile 'sha256:XYZ')
# A file we cannot read is not a file that was tampered with. An antivirus scanner holds the
# freshly downloaded package for a moment; calling that "the content was rewritten" blames the
# publisher for a local hiccup (and the mac side lets the same case through).
$digestMissing = Join-Path $digestDir 'not-there.zip'
Assert-Eq 'a file that is not there is not a mismatch' 'skip' (Test-AssetDigest $digestMissing $digestReal)
# The digest hex case must be handled the same way on both sides: a publisher that answers in
# uppercase must not make one platform check and the other silently skip.
$assetDigestUpper = '{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/777","name":"EnvProxy-win.zip","digest":"sha256:2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824"}]}'
Assert-EqCase 'an uppercase digest is accepted and normalised' 'sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824' ((Get-AssetFromJson $assetDigestUpper 'EnvProxy-win.zip').Digest)
# A tag goes into a URL, so it has to be encoded first. The tag comes from the server's answer,
# not from us: a tag with a space or a slash would otherwise build a broken address.
Assert-Eq 'a plain tag is left alone' 'v1.2.3' (ConvertTo-UrlSegment 'v1.2.3')
Assert-Eq 'a space in a tag is encoded' 'v1%202' (ConvertTo-UrlSegment 'v1 2')
Assert-Eq 'a slash in a tag is encoded' '..%2F..%2Fevil' (ConvertTo-UrlSegment '../../evil')
Assert-Eq 'a question mark in a tag is encoded' 'v1%3F2' (ConvertTo-UrlSegment 'v1?2')
# A 200 that does not carry a release document is not "this release ships no such file".
    # A captive portal answers 200 with an HTML login page; reporting that as a missing file
    # blames the publisher and sends the user to a page that cannot help either.
    $relJson = '{"tag_name":"v1.0.0","assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/1","name":"EnvProxy-win.zip"}]}'
    [void](Get-AssetFromJson $relJson 'EnvProxy-win.zip')
    Assert-Eq 'a release document is recognised as one' 'release' $script:UpdateAssetScope
    [void](Get-AssetFromJson '<html><body>Login</body></html>' 'EnvProxy-win.zip')
    Assert-Eq 'an HTML page is not a release document' 'other' $script:UpdateAssetScope
    [void](Get-AssetFromJson '{"message":"Bad credentials"}' 'EnvProxy-win.zip')
    Assert-Eq 'an error object is not a release document' 'other' $script:UpdateAssetScope
    [void](Get-AssetFromJson $relJson 'EnvProxy-nope.zip')
    Assert-Eq 'a release document without our file is still a release document' 'release' $script:UpdateAssetScope

# The reason for a failed asset lookup must take part in the picking. Otherwise that failure
# stays invisible and only the direct download counts -- and a 404 there gets reported as
# "the release does not ship this file", blaming the maintainer for what is really a quota.
$remoteForAsset = @{ ApiRepo = 'http://127.0.0.1:1/repos/o/r'; Tag = 'v1.0.0'; Base = 'http://127.0.0.1:1/o/r'; Name = 'GitHub' }
# 这条只问一件事：连不上时归哪一类。可本机要是正好有代理在跑，代码会经它重试一次，
# 代理替我们回一个 502，就被归成"对方服务端出错"——测试结果跟着这台机器当时的状态摇摆。
# 把"有没有活代理"在测试作用域里固定成没有，这一条才只测它自己那件事。
# 同样要成对还原：这个替身会真去扫端口的函数，后面的用例若"顺带"调它，
# 拿到的永远是 $null —— 而那正是"本机没有代理"这个假设，会让断言在不该过的场合过。
$__gapSaved = (Get-Item -Path Function:Get-ActiveProxyPort).ScriptBlock
try {
function Get-ActiveProxyPort { param([switch]$FullScan) return $null }
Assert-Eq 'an asset lookup that cannot reach the API reports a network problem' 'network' (Get-UpdateAsset $remoteForAsset 'EnvProxy-win.zip').Failure
Assert-Eq 'the placeholder expands into the repo id' 'https://api.github.com/repos/owner/repo/releases/latest' ($UpdateSourceTable[0].Api).Replace('@@', 'owner/repo')
# No source may come back with an empty repo id: the walker would build a URL with a hole where the
# id goes, and the fetch would fail in a way that looks like a network problem.
# Count is taken straight off the returned value, never wrapped in @(): Get-UpdateSources returns
# ,$out to force an array, and @(...) around a call collapses that into "one element".
Assert-Eq 'no source comes back with an empty repo id' '0' (@($srcTable0 | Where-Object { -not $_.Repo }).Count)
Assert-Eq 'every exported source carries its five walker fields' '0' (@($srcTable0 | Where-Object { -not $_.Api -or -not $_.Web -or -not $_.Base -or -not $_.Preferred -or -not $_.ApiRepo }).Count)

# The repo id comes off the git remote, and every way of writing that remote has to give the same
# answer: the last two path segments. Reading it with a greedy ".*github.com[:/]([^/]+)/([^/]+)"
# looks fine until the remote carries a port -- ssh://git@ssh.github.com:443/owner/repo hands back
# "443/owner", the query URL is built against the wrong repo, and the user is told "the release
# does not ship this file, download it by hand" -- the wrong next step, from a working release.
Assert-Eq 'https remote' 'owner/repo' (Get-RepoIdFromRemoteUrl 'https://github.com/owner/repo.git')
Assert-Eq 'https remote without the .git suffix' 'owner/repo' (Get-RepoIdFromRemoteUrl 'https://github.com/owner/repo')
Assert-Eq 'scp-style remote' 'owner/repo' (Get-RepoIdFromRemoteUrl 'git@github.com:owner/repo.git')
Assert-Eq 'ssh remote with a port' 'owner/repo' (Get-RepoIdFromRemoteUrl 'ssh://git@ssh.github.com:443/owner/repo.git')
Assert-Eq 'a trailing slash is not part of the id' 'owner/repo' (Get-RepoIdFromRemoteUrl 'https://github.com/owner/repo/')
Assert-Eq 'a host that is not GitHub is not an id' '' (Get-RepoIdFromRemoteUrl 'https://gitlab.com/owner/repo.git')
Assert-Eq 'a local path is not an id' '' (Get-RepoIdFromRemoteUrl 'D:\somewhere\repo')
Assert-Eq 'an empty remote is not an id' '' (Get-RepoIdFromRemoteUrl '')
} finally {
    Set-Item -Path Function:Get-ActiveProxyPort -Value $__gapSaved
    Remove-Variable -Name __gapSaved -Scope Script -ErrorAction SilentlyContinue
}

Write-Host '[5c] update failure classification'
# The reason a download failed decides what the user is told to do next: wait an hour
# (quota), open the proxy (network), download by hand (missing), or fix the disk (local).
# Collapsing them into one "failed" string is what made the advice useless.
Assert-Eq '404 means the release does not ship the file' 'missing' (Get-UpdateFailureKind 404)
Assert-Eq '410 also means the file is gone' 'missing' (Get-UpdateFailureKind 410)
Assert-Eq '429 means the API quota is exhausted' 'quota' (Get-UpdateFailureKind 429)
Assert-Eq '403 with no quota left means the quota is exhausted' 'quota' (Get-UpdateFailureKind 403 '0')
Assert-Eq '403 with quota to spare is a refusal, not a quota problem' 'server' (Get-UpdateFailureKind 403 '42')
Assert-Eq '403 with an unknown quota header is a refusal' 'server' (Get-UpdateFailureKind 403)
Assert-Eq '5xx is a server-side problem' 'server' (Get-UpdateFailureKind 503)
Assert-Eq 'any other status is treated as unreachable' 'network' (Get-UpdateFailureKind 418)
# Picking one reason out of several attempts: "missing" only stands when nothing else
# explains the failure. A walled middlebox answers 404 to everything, so a lone 404
# next to a timeout must not be reported as "the maintainer forgot to publish".
Assert-Eq 'a single reason is reported as is' 'missing' (Select-UpdateFailureKind @('missing'))
Assert-Eq 'two identical reasons collapse to one' 'missing' (Select-UpdateFailureKind @('missing', 'missing'))
Assert-Eq 'a timeout next to a 404 reports the timeout' 'network' (Select-UpdateFailureKind @('missing', 'network'))
Assert-Eq 'a quota next to a 404 reports the quota' 'quota' (Select-UpdateFailureKind @('missing', 'quota'))
Assert-Eq 'an unwritable temp dir outranks the timeout' 'local' (Select-UpdateFailureKind @('network', 'local'))
# The table's order IS the report priority, so it is worth pinning: adding a reason must not
# silently reorder the advice, and "missing" must stay last (it accuses the maintainer).
Assert-Eq 'the table lists every reason exactly once' '6' (@($UpdateFailureKinds | Select-Object -Unique).Count)
Assert-Eq 'the table puts the local problem first' 'local' $UpdateFailureKinds[0]
Assert-Eq 'the table puts the missing-package case last' 'missing' $UpdateFailureKinds[$UpdateFailureKinds.Count - 1]
Assert-Eq 'no reason at all falls back to unreachable' 'network' (Select-UpdateFailureKind @())
Assert-Eq 'an empty reason falls back to unreachable' 'network' (Select-UpdateFailureKind @(''))
# 接线：重试之后必须走挑选规则，不许把后一次的原因直接盖上去。
# 状态页的行结构：标签固定 key 色，内容按状态取角色。
#
# 为什么要有这条断言：原来状态页每一行把「标签 : 内容」整行套一个角色，
# 于是"代理变量 : 无（直连状态）"整行变灰，标签也跟着灰——用户最先看的恰恰是标签。
# 状态好的行整行绿、状态无的行整行灰，扫一眼只看到"有的绿有的灰"，分不清哪段是名字。
# 这条断言钉住"标签用 key"这个结构，改回整行同色就红。
$labelRoles = @()
$src = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '../win/lib/ops.ps1'))
# 状态页里每个标签都必须经 Write-StatusRow 输出（它会用 key 上色）
foreach ($lbl in @('监控进程', '开机自启', '翻墙代理', '终端同步', '代理变量', '版本')) {
    $inRow = [regex]::IsMatch($src, "Write-StatusRow '" + $lbl + "'")
    $inBare = [regex]::IsMatch($src, "Write-Styled '\w+' ""?" + $lbl + " : ")
    Assert-Eq ('status row uses the split renderer: ' + $lbl) $true $inRow
    Assert-Eq ('status label is not painted by the whole-line colour: ' + $lbl) $false $inBare
}

# 回环判据：与 Mac 侧 is_loopback_url 同一张表、同一批结论（两侧各跑一遍，门禁 10 互比）。
Assert-Eq 'loopback url: http://127.0.0.1:7078' 'true' (Test-LoopbackUrl 'http://127.0.0.1:7078')
Assert-Eq 'loopback url: http://[::1]:7078' 'true' (Test-LoopbackUrl 'http://[::1]:7078')
Assert-Eq 'loopback url: http://localhost:8080/' 'true' (Test-LoopbackUrl 'http://localhost:8080/')
Assert-Eq 'loopback url: http://LOCALHOST:7890' 'true' (Test-LoopbackUrl 'http://LOCALHOST:7890')
Assert-Eq 'loopback url: http://127.0.0.2:7890' 'true' (Test-LoopbackUrl 'http://127.0.0.2:7890')
Assert-Eq 'loopback url: http://user:pw@localhost:7890' 'true' (Test-LoopbackUrl 'http://user:pw@localhost:7890')
Assert-Eq 'loopback url: https://api.github.com/repos/o/r' 'false' (Test-LoopbackUrl 'https://api.github.com/repos/o/r')
Assert-Eq 'loopback url: http://192.168.1.5:7078/' 'false' (Test-LoopbackUrl 'http://192.168.1.5:7078/')
Assert-Eq 'loopback url: http://[2001:db8::1]:8080/' 'false' (Test-LoopbackUrl 'http://[2001:db8::1]:8080/')
Assert-Eq 'loopback url: http://localhost.:7890' 'false' (Test-LoopbackUrl 'http://localhost.:7890')

# 代理地址归一化：启动器要用它把"用户能填出的各种写法"变成一个能放进环境变量的值。
# 这里钉住的每一条都是真实可能出现的输入：注册表里我们自己写的（规范）、
# 用户手填的（可能少协议、多空格、带末尾斜杠、带账号密码）。
Assert-Eq 'proxy url: 规范写法原样保留' 'http://127.0.0.1:7078' (ConvertTo-ProxyUrl 'http://127.0.0.1:7078')
Assert-Eq 'proxy url: 去首尾空白' 'http://127.0.0.1:7078' (ConvertTo-ProxyUrl '  http://127.0.0.1:7078  ')
Assert-Eq 'proxy url: 去末尾斜杠' 'http://127.0.0.1:7078' (ConvertTo-ProxyUrl 'http://127.0.0.1:7078/')
Assert-Eq 'proxy url: 少写协议时补 http' 'http://127.0.0.1:7078' (ConvertTo-ProxyUrl '127.0.0.1:7078')
Assert-Eq 'proxy url: IPv6 方括号保留' 'http://[::1]:7078' (ConvertTo-ProxyUrl 'http://[::1]:7078')
Assert-Eq 'proxy url: IPv6 少协议也补' 'http://[::1]:7078' (ConvertTo-ProxyUrl '[::1]:7078')
Assert-Eq 'proxy url: socks5 保留协议' 'socks5://127.0.0.1:1080' (ConvertTo-ProxyUrl 'socks5://127.0.0.1:1080')
# 账号密码里出现 ! 和 % 时不能被吞：cmd 的延迟展开会把 ! 吃掉，这里不能重犯。
Assert-Eq 'proxy url: 密码含 ! 不被吞' 'http://user:pa!ss@127.0.0.1:7078' (ConvertTo-ProxyUrl 'http://user:pa!ss@127.0.0.1:7078')
Assert-Eq 'proxy url: 密码含 %40 不被吞' 'http://user:p%40ss@127.0.0.1:7078' (ConvertTo-ProxyUrl 'http://user:p%40ss@127.0.0.1:7078')
Assert-Eq 'proxy url: 空串返回 null' 'true' ($null -eq (ConvertTo-ProxyUrl ''))
Assert-Eq 'proxy url: 纯空白返回 null' 'true' ($null -eq (ConvertTo-ProxyUrl '   '))
# 这两条防的是 Uri 的默认端口陷阱：它会替 "http://127.0.0.1" 补出 Port=80，
# 看起来"有端口"，其实用户没写端口——那种值放进环境变量全是连不上。
Assert-Eq 'proxy url: 没写端口返回 null' 'true' ($null -eq (ConvertTo-ProxyUrl 'http://127.0.0.1'))
Assert-Eq 'proxy url: 显式 :80 也算默认端口' 'true' ($null -eq (ConvertTo-ProxyUrl 'http://127.0.0.1:80'))
Assert-Eq 'proxy url: 非主机名返回 null' 'true' ($null -eq (ConvertTo-ProxyUrl '不是地址'))
Assert-Eq 'proxy url: 不支持的协议返回 null' 'true' ($null -eq (ConvertTo-ProxyUrl 'ftp://127.0.0.1:21'))


# 「这个快捷方式是不是我们建的」判据：只认 launchers 目录**里面**的 .vbs。
#
# 这一组防的是误删用户文件：判据曾用子串包含，于是 launchers2 / launchersX
# 这类同级目录里的 .vbs 也被当成我们的，卸载时连同用户的快捷方式一起删掉。
# 判得宽比判得严危险得多——判严只是留下自己的垃圾，判宽是动别人的东西。
#
# 断言直接打在生产函数 Test-ProxyShortcutArgsOurs 上，不在这里另写一份副本：
# 副本会让这组用例失去意义——生产那份改了、写歪了、退回子串包含了，
# 测副本的断言照样全绿，测试发现不了被测对象的变化。
$launcherRoot = [System.IO.Path]::GetFullPath((Get-ProxyLauncherDir)).TrimEnd('\')
# 必须认成我们的（否则卸载删不掉自己的东西）
Assert-Eq 'shortcut ours: 目录内的 vbs' 'true' (Test-ProxyShortcutArgsOurs ('"' + $launcherRoot + '\app_1234abcd.vbs"'))
Assert-Eq 'shortcut ours: 不带引号也算' 'true' (Test-ProxyShortcutArgsOurs ($launcherRoot + '\app_1234abcd.vbs'))
Assert-Eq 'shortcut ours: 中文文件名也算' 'true' (Test-ProxyShortcutArgsOurs ('"' + $launcherRoot + '\中文_aabb.vbs"'))
# 绝不能认成我们的（否则删掉用户的东西）
Assert-Eq 'shortcut not ours: launchers2 同级目录' 'false' (Test-ProxyShortcutArgsOurs ('"' + $launcherRoot + '2\mine.vbs"'))
Assert-Eq 'shortcut not ours: launchersX 同级目录' 'false' (Test-ProxyShortcutArgsOurs ('"' + $launcherRoot + 'X\user.vbs"'))
Assert-Eq 'shortcut not ours: 用 .. 绕出去' 'false' (Test-ProxyShortcutArgsOurs ('"' + $launcherRoot + '\..\backup\user.vbs"'))
Assert-Eq 'shortcut not ours: 桌面上的用户脚本' 'false' (Test-ProxyShortcutArgsOurs '"C:\Users\X\Desktop\mine.vbs"')
Assert-Eq 'shortcut not ours: 不是 vbs' 'false' (Test-ProxyShortcutArgsOurs ('"' + $launcherRoot + '\a.exe"'))
Assert-Eq 'shortcut not ours: 空参数' 'false' (Test-ProxyShortcutArgsOurs '')
Assert-Eq 'shortcut not ours: 只有一个引号' 'false' (Test-ProxyShortcutArgsOurs '"')

# 启动脚本要记住自己服务的是哪个程序。
#
# 为什么要测：脚本文件名是「程序名_哈希」，哈希那段对人没有意义。图标被删掉
# 或挪到别处之后，launchers 目录里只剩脚本，管理页只能显示一个像
# app_aabbccdd 的名字——用户看不出这是哪个程序的、该不该删。
# 程序路径本身只存在压缩过的命令里（base64），外面读不出来，所以另留一行可读记录。
#
# 记录必须写成十六进制而不是原文：脚本文件要保持纯 ASCII，
# 直接写中文路径会让某些旧版 WSH 读错文件、整个快捷方式失效。
$tgtSbox = Join-Path ([System.IO.Path]::GetTempPath()) ("epsbx_tgt_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tgtSbox -Force | Out-Null
try {
    $cnDir = Join-Path $tgtSbox '中文 目录 (测试)'
    New-Item -ItemType Directory -Path $cnDir -Force | Out-Null
    $cnApp = Join-Path $cnDir '我的 程序.exe'
    [System.IO.File]::WriteAllText($cnApp, 'x', [System.Text.Encoding]::ASCII)

    $encBody = Compress-ToBase64 'echo test'
    $vbsText = New-ProxyLauncherVbs $encBody $cnApp
    Assert-Eq 'launcher remembers its target: 有记录行' 'true' ($vbsText -match 'envproxy-target-hex:')
    Assert-Eq 'launcher remembers its target: 正文是纯 ASCII' 'true' (-not ($vbsText.ToCharArray() | Where-Object { [int]$_ -gt 127 }))

    $vbsFile = Join-Path $tgtSbox 'probe.vbs'
    [System.IO.File]::WriteAllText($vbsFile, $vbsText, [System.Text.Encoding]::ASCII)
    Assert-Eq 'launcher target round-trips: 中文路径 + 空格 + 括号' $cnApp (Get-ProxyLauncherTarget $vbsFile)
    Assert-Eq 'launcher target: 不存在的文件返回空' '' (Get-ProxyLauncherTarget (Join-Path $tgtSbox 'nope.vbs'))
    Assert-Eq 'launcher target: 空路径返回空' '' (Get-ProxyLauncherTarget '')
    # 旧版本建的脚本没有这一行，读不出来要返回空而不是报错
    $oldVbs = Join-Path $tgtSbox 'old.vbs'
    [System.IO.File]::WriteAllText($oldVbs, 'CreateObject("WScript.Shell").Run "cmd.exe", 0, False' + "`r`n", [System.Text.Encoding]::ASCII)
    Assert-Eq 'launcher target: 旧脚本（没有记录行）返回空' '' (Get-ProxyLauncherTarget $oldVbs)
    # 记录行被写坏时也不能抛异常
    $badVbs = Join-Path $tgtSbox 'bad.vbs'
    [System.IO.File]::WriteAllText($badVbs, "' envproxy-target-hex: zzz" + "`r`n", [System.Text.Encoding]::ASCII)
    Assert-Eq 'launcher target: 坏 hex 返回空' '' (Get-ProxyLauncherTarget $badVbs)
} finally {
    Remove-Item -LiteralPath $tgtSbox -Recurse -Force -ErrorAction SilentlyContinue
}

# 程序候选的排除规则：决定"扫出来那三四十个程序里，哪些不该出现"。
#
# 这张表看起来只是文案，其实每条都对应一个真实存在的噪音源：开始菜单里混着
# 卸载器、帮助文档、Python 自带的开发工具，全列出来用户得在两屏垃圾里找自己要的。
# 而判错的代价不对称：多排除一个，用户要手动输路径（麻烦）；少排除一个，
# 他要多读几行（也有代价但小得多）——所以规则宁可稍严，但绝不能误伤真程序。
# 最典型的一条：'notepad' 要排掉，而 'Notepad++' 必须留下（它是用户真会用的编辑器），
# 这要求英文词按整词匹配、中文词按包含匹配（中文没有词边界）。
Assert-Eq 'scan exclude: notepad 排除' 'true' (Test-ProxyScanExcluded 'notepad')
Assert-Eq 'scan exclude: Notepad++ 保留' 'false' (Test-ProxyScanExcluded 'Notepad++')
Assert-Eq 'scan exclude: 卸载xxx 排除' 'true' (Test-ProxyScanExcluded '卸载 Antigravity')
Assert-Eq 'scan exclude: 用户帮助 排除' 'true' (Test-ProxyScanExcluded '用户帮助')
Assert-Eq 'scan exclude: 使用说明 排除' 'true' (Test-ProxyScanExcluded '使用说明')
Assert-Eq 'scan exclude: README 排除' 'true' (Test-ProxyScanExcluded 'README')
# 文档类噪音：开始菜单里「用户手册」「新手教程」这类快捷方式指向的是帮助文档，
# 建一个「走代理启动帮助文档」的图标对谁都没用。中文没有词边界，只能靠包含匹配。
Assert-Eq 'scan exclude: 用户手册 排除' 'true' (Test-ProxyScanExcluded '用户手册')
Assert-Eq 'scan exclude: 使用文档 排除' 'true' (Test-ProxyScanExcluded '使用文档')
Assert-Eq 'scan exclude: 新手教程 排除' 'true' (Test-ProxyScanExcluded '新手教程')
Assert-Eq 'scan exclude: 配置指南 排除' 'true' (Test-ProxyScanExcluded '配置指南')
Assert-Eq 'scan exclude: unins000 排除' 'true' (Test-ProxyScanExcluded 'unins000')
Assert-Eq 'scan exclude: cmd 排除' 'true' (Test-ProxyScanExcluded 'cmd')
Assert-Eq 'scan exclude: 此电脑 排除' 'true' (Test-ProxyScanExcluded '此电脑')
Assert-Eq 'scan exclude: Antigravity 保留' 'false' (Test-ProxyScanExcluded 'Antigravity')
Assert-Eq 'scan exclude: 豆包 保留' 'false' (Test-ProxyScanExcluded '豆包')
Assert-Eq 'scan exclude: Visual Studio Code 保留' 'false' (Test-ProxyScanExcluded 'Visual Studio Code')
# 「xxx 快捷方式」要剥掉后缀再判：剥掉之后 '卸载 快捷方式' 仍是噪音
Assert-Eq 'scan exclude: 名字带"快捷方式"后缀也能判' 'true' (Test-ProxyScanExcluded '卸载 快捷方式')
Assert-Eq 'scan exclude: 空名字排除' 'true' (Test-ProxyScanExcluded '')

# 路径级排除：挡住"系统目录里的工具"，名字判据挡不住这些。
#
# 这一段测的是**与宿主平台无关**：判据不能依赖只在一个平台上才成立的东西。
# 已经踩过两个坑，都是"本机绿、CI 红"：
#   ① 只看 `$env:SystemRoot` 判系统目录——那个变量在 Linux 上是空的；
#   ② 用 `[System.IO.Path]::GetFileNameWithoutExtension` 取文件名——它按宿主平台
#      的规则认分隔符，Linux 只认正斜杠，于是 `C:\App\unins000.exe` 在 CI 上
#      被当成"整串文件名"，`unins*` 判断恒为假。
# 这类断言比没有断言更糟：它教人习惯性忽略红灯。所以下面显式把它们锁住。
Assert-Eq 'scan exclude path: System32 里的排除' 'true' (Test-ProxyScanExcludedPath 'C:\Windows\System32\regedit.exe')
Assert-Eq 'scan exclude path: SysWOW64 里的排除' 'true' (Test-ProxyScanExcludedPath 'C:\Windows\SysWOW64\cmd.exe')
# 抹掉 SystemRoot 之后仍然要挡得住（这正是 CI 上跑的那种情况）
$__sr = $env:SystemRoot
try {
    $env:SystemRoot = $null
    Assert-Eq 'scan exclude path: 无 SystemRoot 也挡 System32' 'true' (Test-ProxyScanExcludedPath 'C:\Windows\System32\regedit.exe')
    Assert-Eq 'scan exclude path: 无 SystemRoot 也挡 SysWOW64' 'true' (Test-ProxyScanExcludedPath 'C:\Windows\SysWOW64\cmd.exe')
    Assert-Eq 'scan exclude path: 无 SystemRoot 不误伤普通程序' 'false' (Test-ProxyScanExcludedPath 'D:\Doubao\Doubao.exe')
    # 反斜杠路径里的卸载器：取文件名不能靠 Path API（Linux 上切不出来）
    Assert-Eq 'scan exclude path: 无 SystemRoot 也认反斜杠里的 unins' 'true' (Test-ProxyScanExcludedPath 'C:\Program Files\App\unins000.exe')
    Assert-Eq 'scan exclude path: 无 SystemRoot 也认反斜杠里的 uninstall' 'true' (Test-ProxyScanExcludedPath 'C:\Program Files\App\Uninstall.exe')
} finally {
    $env:SystemRoot = $__sr
}
# 两种分隔符都要认（同一个程序的写法可能来自不同来源）
Assert-Eq 'scan exclude path: 正斜杠路径也认卸载器' 'true' (Test-ProxyScanExcludedPath 'C:/Program Files/App/unins000.exe')
Assert-Eq 'scan exclude path: 裸文件名也认卸载器' 'true' (Test-ProxyScanExcludedPath 'unins000.exe')
Assert-Eq 'scan exclude path: 卸载器排除' 'true' (Test-ProxyScanExcludedPath 'C:\Program Files\App\unins000.exe')
Assert-Eq 'scan exclude path: Uninstall 排除' 'true' (Test-ProxyScanExcludedPath 'C:\Program Files\App\Uninstall.exe')
Assert-Eq 'scan exclude path: 普通程序保留' 'false' (Test-ProxyScanExcludedPath 'C:\Users\X\AppData\Local\Programs\antigravity\Antigravity.exe')
Assert-Eq 'scan exclude path: D 盘程序保留' 'false' (Test-ProxyScanExcludedPath 'D:\Doubao\Doubao.exe')
Assert-Eq 'scan exclude path: 空路径排除' 'true' (Test-ProxyScanExcludedPath '')

#
# 这条防的是一个真实发生过的 bug：挑选函数与它的断言都在，但调用方
# 直接 `$script:VersionQueryFailure = $t2.Failure`，绕过了整个规则。
# 于是"第一次 quota（配额用尽，等一小时）、重试后 server（对方故障）"时报了 server——
# 用户照着等一会儿，怎么等都没用。
# 断言测函数怎么挑，测不出"没人调它"；只能读源码看调用点。
$uSrc = [System.IO.File]::ReadAllText((Join-Path (Get-Location) 'win/lib/update.ps1'))
$iFn = $uSrc.IndexOf('function Invoke-UpdateText(')
Assert-Eq '接线：Invoke-UpdateText 找到了' $true ($iFn -ge 0)
if ($iFn -ge 0) {
    $uBody = $uSrc.Substring($iFn, [Math]::Min(1400, $uSrc.Length - $iFn))
    Assert-Eq '接线：重试路径把两次原因都交给挑选规则' $true ($uBody -match 'Select-UpdateFailureKind')
    # 反面：不许出现 "= $t2.Failure" 这种直接覆盖。
    Assert-Eq '接线：重试路径不直接覆盖失败原因' $false ([regex]::IsMatch($uBody, 'VersionQueryFailure\s*=\s*\$t2\.Failure'))
}
# The advice must name the action, otherwise the user still has to guess.
$msgMissing = Get-UpdateFailureMessage 'missing' 'GitHub'
$msgQuota = Get-UpdateFailureMessage 'quota' 'GitHub'
$msgNet = Get-UpdateFailureMessage 'network' 'GitHub'
$msgLocal = Get-UpdateFailureMessage 'local' 'GitHub'
Assert-Eq 'the missing-file advice points at manual download' '1' ([int]($msgMissing -match '手动下载'))
Assert-Eq 'the quota advice says it clears with time' '1' ([int]($msgQuota -match '一小时|重试'))
Assert-Eq 'the network advice points at the proxy' '1' ([int]($msgNet -match '代理'))
Assert-Eq 'the local advice points at the disk' '1' ([int]($msgLocal -match '磁盘|权限'))
$advices = @('missing', 'quota', 'server', 'network', 'bad-content', 'local') | ForEach-Object { Get-UpdateFailureMessage $_ 'GitHub' }
Assert-Eq 'no advice claims success' '0' (@($advices | Where-Object { $_ -match '成功' }).Count)

Write-Host '[7a2] retry with another exit IP'

# 失败以后要不要"换个出口 IP 再试一次"，判据只有一条：这个失败是不是由出口决定的。
# 把它钉住，是因为判错的代价不对称：
#   - 该换却不换（quota）：只能去走更慢的兜底路。实测直连出口配额用尽时，
#     同地址经本机代理 468ms 就 200，而网页兜底要 8.7 秒。
#   - 不该换却换（missing/server）：白等一轮，还把真实原因盖成别的原因。
# 这两种都是"看起来能跑、其实慢或误导"的坏法，只有断言看得见。
foreach ($k in @('network', 'quota')) {
    Assert-Eq ('the ' + $k + ' failure is worth retrying on another exit') '1' ([int](Test-RetryWithProxy $k))
}
foreach ($k in @('server', 'missing', 'bad-content', 'local', '')) {
    Assert-Eq ('the ' + $k + ' failure is not retried on another exit') '0' ([int](Test-RetryWithProxy $k))
}
# 空原因（一次都没失败过）也不能触发重试。
Assert-Eq 'no failure means no retry' '0' ([int](Test-RetryWithProxy $null))
Write-Host '[7b] listening port enumeration'

# The listening port list drives the whole judgment, so the netstat parsing has to be exact.
# netstat writes IPv4 as "127.0.0.1:8080" and IPv6 as "[::1]:8080" (with brackets).
$ep4 = ConvertTo-ListenEndpoint '127.0.0.1:8080'
Assert-Eq 'an IPv4 endpoint splits into address and port' '127.0.0.1|8080' ("$($ep4.Address)|$($ep4.Port)")
$ep6 = ConvertTo-ListenEndpoint '[::1]:8080'
Assert-Eq 'a bracketed IPv6 endpoint splits too' '::1|8080' ("$($ep6.Address)|$($ep6.Port)")
$epAny = ConvertTo-ListenEndpoint '[::]:135'
Assert-Eq 'the any-address IPv6 form is understood' '::|135' ("$($epAny.Address)|$($epAny.Port)")
$epHigh = ConvertTo-ListenEndpoint '0.0.0.0:65535'
Assert-Eq 'the highest port is understood' '65535' "$($epHigh.Port)"
# A line that is not an endpoint must be dropped, never guessed at.
Assert-Eq 'a line without a port is rejected' '1' ([int]($null -eq (ConvertTo-ListenEndpoint 'nonsense')))
Assert-Eq 'a port that is not a number is rejected' '1' ([int]($null -eq (ConvertTo-ListenEndpoint '127.0.0.1:abc')))
Assert-Eq 'port zero is rejected' '1' ([int]($null -eq (ConvertTo-ListenEndpoint '127.0.0.1:0')))
Assert-Eq 'a port above the range is rejected' '1' ([int]($null -eq (ConvertTo-ListenEndpoint '127.0.0.1:70000')))
Assert-Eq 'a broken bracket is rejected' '1' ([int]($null -eq (ConvertTo-ListenEndpoint '[::1:8080')))

# The signal "are there TCP rows" must not come out of the parse itself. When the row shape
# changes (an extra column, a state made of two words) nothing matches, and an empty answer
# would be read as "no port is listening" -- the state machine would then call off and delete
# the user's proxy variables. The protocol column is never localised, so a loose match on it
# survives every shape change.
# 解析是纯函数，所以直接喂文本验，不需要给 netstat 打桩。
# 为什么改成这样：取值现在是三层（进程内 .NET API / netstat / WMI），
# 打桩只能影响中间那一层，而第一层会先返回真数据——桩就被绕过去了，
# 于是"测了行形状"变成"测了个寂寞"。解析单独抽出来之后，与机器上有没有 netstat 无关。
$shapeCases = @(
    @{ Name = 'an extra column'; Expected = 1; Lines = @('  Proto Local Foreign State PID InHost', '  TCP    0.0.0.0:22    0.0.0.0:0    LISTENING    6544    -') },
    @{ Name = 'a state made of two words'; Expected = 0; Lines = @('  Proto Local Foreign State PID', '  TCP    0.0.0.0:22    0.0.0.0:0    LISTEN  6544') },
    @{ Name = 'a localised state'; Expected = 0; Lines = @('  Proto Local Foreign State PID', '  TCP    0.0.0.0:22    0.0.0.0:0    ABHÖREN    6544') }
)
foreach ($case in $shapeCases) {
    $got = -1
    $threw = $false
    try { $got = @(ConvertFrom-NetstatOutput $case.Lines).Count } catch { $threw = $true }
    if ($case.Expected -gt 0) {
        # 多一列但状态仍是 LISTENING：能解析出来就解析（宽松匹配本来就该容忍多出来的列）。
        Assert-Eq ('a netstat row with an extra column still parses: ' + $case.Name) '0' ([int]$threw)
        Assert-Eq ('and it finds the listener: ' + $case.Name) '1' $got
    } else {
        # 状态认不出来：必须抛，不能悄悄返回空表——空表长得跟"没有端口在监听"一模一样。
        Assert-Eq ('an unreadable state is refused, not reported as empty: ' + $case.Name) '1' ([int]$threw)
    }
}
# 一条 TCP 行都没有：拿到的根本不是 netstat 输出，必须拒绝。
$noTcpThrew = $false
try { [void](ConvertFrom-NetstatOutput @('  Proto Local Foreign State PID')) } catch { $noTcpThrew = $true }
Assert-Eq 'output without a single TCP row is refused instead of reported as empty' '1' ([int]$noTcpThrew)
# 空输出同样是"读不出来"，不是"没有端口"。
$emptyThrew = $false
try { [void](ConvertFrom-NetstatOutput @()) } catch { $emptyThrew = $true }
Assert-Eq 'empty output is refused instead of reported as empty' '1' ([int]$emptyThrew)
# 正常输出：IPv4 与 IPv6 都要认，非监听行要丢掉。
$goodLines = @(
    '',
    'Active Connections',
    '',
    '  Proto  Local Address          Foreign Address        State           PID',
    '  TCP    0.0.0.0:22             0.0.0.0:0              LISTENING       8052',
    '  TCP    127.0.0.1:7078         0.0.0.0:0              LISTENING       4416',
    '  TCP    [::]:135               [::]:0                 LISTENING       2160',
    '  TCP    [::1]:7890             [::]:0                 LISTENING       9001',
    '  TCP    127.0.0.1:50000        127.0.0.1:7078         ESTABLISHED     4416',
    '  UDP    0.0.0.0:500              *:*                                    1234'
)
$parsed = @(ConvertFrom-NetstatOutput $goodLines)
Assert-Eq 'a real netstat block yields only the listening sockets' '4' $parsed.Count
Assert-Eq 'IPv4 loopback keeps its address' '1' ([int](@($parsed | Where-Object { $_.LocalAddress -eq '127.0.0.1' -and $_.LocalPort -eq 7078 }).Count))
Assert-Eq 'IPv6 loopback keeps its address' '1' ([int](@($parsed | Where-Object { $_.LocalAddress -eq '::1' -and $_.LocalPort -eq 7890 }).Count))
Assert-Eq 'the any-address IPv6 form is kept' '1' ([int](@($parsed | Where-Object { $_.LocalAddress -eq '::' -and $_.LocalPort -eq 135 }).Count))
Assert-Eq 'an established connection is not a listener' '0' ([int](@($parsed | Where-Object { $_.LocalPort -eq 50000 }).Count))
Assert-Eq 'the parse carries the owning pid when the row has one' '4416' (@($parsed | Where-Object { $_.LocalPort -eq 7078 })[0].OwningProcess)

# The enumeration has to agree with the system: a port that is really listening must be found,
# and a port that is not must not be. This is the one check that would catch a parse that
# silently returns nothing -- which would make the monitor believe there is no proxy.
#
# A machine that has neither netstat nor the WMI fallback (the CI runs this file on Linux
# as well) has nothing to compare against: the enumeration reports that it cannot read,
# which is the right answer, so the comparison is skipped there instead of failing.
$probeListen = @()
$probeThrew = $false
try { $probeListen = Get-ListeningTcpConnections } catch { $probeThrew = $true }
if ($probeThrew) {
    Write-Host '  SKIP 本机既没有 netstat 也没有 WMI 兜底，无法与系统核对'
} else {
    # 取第一个元素的属性名：直接对数组取 .PSObject 拿到的是数组自己的属性（Count/Length），不是元素的。
    $probeFirst = @($probeListen)[0]
    $probeNames = @()
    if ($probeFirst) { $probeNames = @($probeFirst.PSObject.Properties.Name) }
    Assert-Eq 'the enumeration exposes the local address' '1' ([int]($probeNames -contains 'LocalAddress'))
    Assert-Eq 'the enumeration exposes the local port' '1' ([int]($probeNames -contains 'LocalPort'))
    Assert-Eq 'the enumeration exposes the owning process' '1' ([int]($probeNames -contains 'OwningProcess'))
    if (@($probeListen).Count -gt 0) {
        $somePort = @($probeListen)[0].LocalPort
        # Test-PortListening 是三态（listening / absent / unknown），不是布尔：
        # 「读不出来」必须与「没在听」分开，否则一次读失败会被判成代理没了。
        Assert-Eq 'a port the system reports as listening is found' 'listening' ([string](Test-PortListening $somePort))
        Assert-Eq 'the same port is found in the port list' '1' ([int](@($probeListen.LocalPort) -contains $somePort))
    }
    Assert-Eq 'a port nothing listens on is absent, not unknown' 'absent' ([string](Test-PortListening 1))
}

# ------------------------------------------------------------------------------
# [2b] 入口不许默默跑起来：多余或打错的参数要报用法错误（退出码 2）
# ------------------------------------------------------------------------------
# powershell -File 对不认识的参数名不报绑定错误，它们只是落进 $args。
# 不拦的话，敲错一个选项就会静默进入监控模式。
# 这里用子进程验：点源加载时 $args 是空的，验不到。
$entryPath = Join-Path $PSScriptRoot '../win/envproxy.ps1'
function Invoke-EntryChild([string[]]$EntryArgs) {
    $exe = (Get-Process -Id $PID).Path
    if ($env:OS -ne 'Windows_NT') {
        # Linux 上 Start-Process 不支持重定向参数，直接调用取退出码。
        & $exe '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' $entryPath @EntryArgs 2>$null | Out-Null
        return $LASTEXITCODE
    }
    # 临时目录用 .NET 的 GetTempPath：Linux 上没有 $env:TEMP（那是 Windows 才有的变量），
    # 直接写 $env:TEMP 会让 Join-Path 收到 null，整个自检在这一步就崩掉。
    $tmpDir = [System.IO.Path]::GetTempPath()
    $outFile = Join-Path $tmpDir ("ep-entry-out-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".txt")
    $errFile = Join-Path $tmpDir ("ep-entry-err-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".txt")
    try {
        # 每个参数都要自己带引号：Start-Process 把参数数组用空格拼成一条命令行，
        # 不加引号时空参数会被整个吞掉（"空参数要报用法错误"这条就永远测不到）。
        $quoted = @('"-NoProfile"', '"-ExecutionPolicy"', '"Bypass"', '"-File"', ('"' + $entryPath + '"'))
        foreach ($a in $EntryArgs) { $quoted += ('"' + $a + '"') }
        $ps = Start-Process -FilePath $exe -PassThru -NoNewWindow -Wait `
            -ArgumentList $quoted `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        return $ps.ExitCode
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}
# 打错的参数名也要拒（不只是不认识的）：它是入口守卫最典型的用途。
foreach ($bad in @('-Installt')) {
    $rc = Invoke-EntryChild @($bad)
    Assert-Eq ("入口拒绝打错的参数: " + $bad) 2 $rc
}

# ------------------------------------------------------------------------------
# [2c] 入口的参数与退出码：两侧同一套，门禁 10 把两边的这些行互相比一次
# ------------------------------------------------------------------------------
# 只放平台无关的用例：三种误用都在动手之前被拦下，两端跑出来的退出码必然相同。
# "合法用法必须放行"是另一回事（见下面那条本地断言）：它要真跑子命令，
# 而 Windows 的状态显示依赖注册表、只在 Windows 上有确定结果，所以不进跨端契约。
$entryCases = @(
    @{ Name = 'unknown-arg';          Args = @('-Foo');              Want = 2 },
    @{ Name = 'extra-positional';     Args = @('-Status', 'extra');  Want = 2 },
    @{ Name = 'purge-misuse';         Args = @('-Install', '-Purge'); Want = 2 },
    @{ Name = 'switch-without-command'; Args = @('-Yes');            Want = 2 },
    @{ Name = 'unknown-switch';       Args = @('-Status', '-Foo');   Want = 2 },
    @{ Name = 'two-commands';         Args = @('-Install', '-Uninstall'); Want = 2 }
)
foreach ($c in $entryCases) {
    $rc = Invoke-EntryChild $c.Args
    Assert-Eq ("入口退出码: " + $c.Name) $c.Want $rc
    Write-Host ("entry {0} {1}" -f $c.Name, $rc)
}
# 空参数不等于"没传参数"：前者是参数写错（退出码 2），后者才是监控模式。
$rc = Invoke-EntryChild @('')
Assert-Eq '入口：空参数要报用法错误（不能当成没传参数）' 2 $rc
# 用法判定本身是纯函数（base 层 Get-UsageError，两端同形），两个方向都要钉住：
# "必须拒"不许放过，"必须放行"不许误伤。
# "放行"这一向只能在这里测：真跑一次入口就会真的卸载或更新，副作用落在用户机器上。
# 必须把返回值接住再断言。写成 `$null = Get-UsageError ...` 然后断言 $null 的话，
# 断言比的是字面量 $null，永远通过——这四条是「合法用法必须放行」这条契约的
# 唯一执行者（真跑一次入口就会真的卸载或更新，副作用落在用户机器上，只能在纯函数层断言），
# 它们恒真等于这条契约没人守。
$e = Get-UsageError -Command 'status' -CommandCount 1
Assert-Eq '用法判定：普通命令放行' '' $e
$e = Get-UsageError -Command '' -CommandCount 0
Assert-Eq '用法判定：无命令（监控模式）放行' '' $e
$e = Get-UsageError -Command 'uninstall' -CommandCount 1 -Switches @('purge')
Assert-Eq '用法判定：卸载带 -Purge 放行' '' $e
$e = Get-UsageError -Command 'update' -CommandCount 1 -Switches @('yes')
Assert-Eq '用法判定：更新带 -Yes 放行' '' $e
function Usage-Rejected($e) { if ($e) { '真' } else { '假' } }
Assert-Eq '用法判定：-Purge 跟着别的命令要拒' '真' (Usage-Rejected (Get-UsageError -Command 'install' -CommandCount 1 -Switches @('purge')))
Assert-Eq '用法判定：-Yes 跟着别的命令要拒' '真' (Usage-Rejected (Get-UsageError -Command 'status' -CommandCount 1 -Switches @('yes')))
Assert-Eq '用法判定：不认识的参数要拒' '真' (Usage-Rejected (Get-UsageError -Command 'status' -CommandCount 1 -Extra @('-Foo')))
Assert-Eq '用法判定：一次给两个命令要拒' '真' (Usage-Rejected (Get-UsageError -Command 'install' -CommandCount 2))
# 放行方向：合法用法必须过。这两条之前只有 update 一条，uninstall 那条没有——
# 而 AGENTS.md 里 "-Yes 只配 -Update" 那句错的约定了很久没人发现，正是因为它没有计数器。
# 卸载问不到人时会拒绝执行，-Yes 是那种场合唯一的出路；把这条判据改窄 = 切断非交互卸载。
Assert-Eq '用法判定：-Yes 配 update 放行' '假' (Usage-Rejected (Get-UsageError -Command 'update' -CommandCount 1 -Switches @('yes')))
Assert-Eq '用法判定：-Yes 配 uninstall 放行' '假' (Usage-Rejected (Get-UsageError -Command 'uninstall' -CommandCount 1 -Switches @('yes')))
Assert-Eq '用法判定：-Yes 配 uninstall 且带 -Purge 放行' '假' (Usage-Rejected (Get-UsageError -Command 'uninstall' -CommandCount 1 -Switches @('yes','purge')))
Assert-Eq '用法判定：-Purge 配 uninstall 放行' '假' (Usage-Rejected (Get-UsageError -Command 'uninstall' -CommandCount 1 -Switches @('purge')))

# ------------------------------------------------------------------------------
# [7c] 端口枚举失败 = 这一轮不知道，不是"没有端口"
# ------------------------------------------------------------------------------
# 读不出来却被当成空表，状态机会判 off -> 把用户的代理环境变量删掉。
# 两侧的判据必须一样：枚举失败要传上去，状态机据此沿用上一状态。
# 枚举失败时状态必须是"不知道"，不是 off——这一条与"哪一层失败"无关，所以直接
# 覆盖枚举函数本身来制造失败，而不是给 netstat 打桩。
#
# 为什么不再打 netstat 的桩：取值现在是三层（进程内 .NET API / netstat / WMI）。
# 桩只能盖住后两层，第一层照样会返回真数据，于是"模拟失败"根本没发生，
# 这条断言就会假绿（或者像刚才那样反过来红）。覆盖最外层的枚举函数，
# 才是"无论内部怎么实现都会失败"的确定性做法。
$script:SavedEnum = ${function:Get-ListeningTcpConnections}
try {
    function Get-ListeningTcpConnections { throw "simulated: every enumeration path failed" }
    $script:CachedPort = $null
    $unknownState = Get-CurrentState
    Assert-Eq '端口枚举失败时状态是"不知道"而不是 off' 'unknown' $unknownState
} finally {
    Set-Item -Path Function:Get-ListeningTcpConnections -Value $script:SavedEnum
    Remove-Variable -Name SavedEnum -Scope Script -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------------------
# [8c] 资产解析契约：同一批应答，两侧必须得出同一个结论
# ------------------------------------------------------------------------------
# 用例放在 tests/asset-cases.txt：名字、正文种类、编号、校验值、失败原因、正文。
# 这里跑一遍并和文件里写下的期望比对；每一行还打印成 "contract ..."，
# 门禁 10 再把两边的这些行互相比一次——文本层面的门禁看不出行为漂移，
# 行为层面才看得出来（同一个应答，一边更新、一边说"没提供安装包"就是这种漂移）。
$contractFile = Join-Path $PSScriptRoot 'asset-cases.txt'
if (Test-Path -LiteralPath $contractFile) {
    $contractSeen = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($contractFile, [System.Text.Encoding]::UTF8)) {
        if (-not $line -or $line.StartsWith('#')) { continue }
        $f = $line -split "\|"
        if ($f.Count -ne 6) { Assert-Eq ('用例行字段数不对: ' + $f[0]) 6 $f.Count; continue }
        $cName = $f[0]; $cScope = $f[1]; $cId = $f[2]; $cDigest = $f[3]; $cFail = $f[4]; $cBody = $f[5]
        $asset = Get-AssetFromJson $cBody 'EnvProxy-test.zip'
        $gotId = ''; $gotDigest = ''
        if ($asset) { $gotId = $asset.Id; $gotDigest = $asset.Digest }
        $gotFail = ''
        if (-not $asset) { $gotFail = Get-AssetFailureFromScope $script:UpdateAssetScope }
        Assert-Eq ('资产契约 正文种类: ' + $cName) $cScope $script:UpdateAssetScope
        Assert-Eq ('资产契约 编号: ' + $cName) $cId $gotId
        Assert-Eq ('资产契约 校验值: ' + $cName) $cDigest $gotDigest
        Assert-Eq ('资产契约 失败原因: ' + $cName) $cFail $gotFail
        Write-Host ("contract {0} {1} {2} {3} {4}" -f $cName, $script:UpdateAssetScope, $gotId, $gotDigest, $gotFail)
        $contractSeen[$cName] = $true
    }
    Assert-Eq '资产契约 用例都跑到了' 20 $contractSeen.Count
} else {
    Write-Host '  SKIP 找不到 tests/asset-cases.txt（仓库内的用例文件）'
}

# ------------------------------------------------------------------------------
# [9] 监控进程的身份判据：看实质，不看启动方式的细节
# ------------------------------------------------------------------------------
# 判据是"命令行结尾跑的是本脚本、且没有子命令"。路径两侧的引号可有可无：
# 引号是启动方式决定的，不是身份的一部分。把引号当成条件会出这种事——
# 认不出已经跑着的监控，安装器就以为监控没在跑而起第二份，单实例锁又把第二份挡掉，
# 于是再也起不来监控，状态页还报"未运行"。
Assert-Eq '监控判据认得带引号的命令行' $true ('powershell.exe -NoProfile -File "D:\EnvProxy\win\envproxy.ps1"' -match $MonitorCmdLinePattern)
Assert-Eq '监控判据认得不带引号的命令行' $true ('powershell.exe -NoProfile -File D:\EnvProxy\win\envproxy.ps1' -match $MonitorCmdLinePattern)
Assert-Eq '监控判据认不得带子命令的进程' $false ('powershell.exe -File "D:\EnvProxy\win\envproxy.ps1" -Status' -match $MonitorCmdLinePattern)
Assert-Eq '监控判据认不得命令行中间提到脚本的进程' $false ('powershell.exe -Command "Get-Content D:\EnvProxy\win\envproxy.ps1"' -match $MonitorCmdLinePattern)
# 定位器（win/locator.ps1）是独立的登录期脚本，不加载任何库，所以它只能自带一份
# 同样的字面量。但「同一语义」这句话原来没有任何机制兜住：门禁 6 不比对这两个模式，
# 测试也只钉了 runtime 那一份。改一侧的后果是「定位器认不出已在跑的监控 → 再起一份
# 被单实例锁挡掉 → 监控起不来而状态页报未运行」。
# 定位器就在仓库里，测试读得到，所以直接把它抓出来比对。
$locSrc = [System.IO.File]::ReadAllText((Join-Path (Get-Location) 'win/locator.ps1'))
# 只抓"等号右边到行尾"，剥引号留给下一步：把两件事塞进一个正则时，
# 引号很容易被当成通配符吃掉（实测过一次，取出来的是没有引号的内容，
# 而断言看起来"通过了第一层"，第二层永远空）。
$locRaw = [regex]::Match($locSrc, "MonitorCmdLinePattern\s*=\s*(.+)$", "Multiline")
Assert-Eq '定位器里带了一份监控命令行判据' $true ($locRaw.Success)
if ($locRaw.Success) {
    $locVal = $locRaw.Groups[1].Value.Trim()
    if ($locVal.Length -ge 2) { $locVal = $locVal.Substring(1, $locVal.Length - 2) }
    Assert-Eq '定位器与核心脚本的监控命令行判据完全相同' $MonitorCmdLinePattern $locVal
}

# ------------------------------------------------------------------------------
# [10] 快照归属判定：首次安装时，本机地址的代理变量是使用者自己的
# ------------------------------------------------------------------------------
# "像我们写的"不够——还要机器上本来就有本工具的安装记录，才可能是我们留下的。
# 首次安装时把使用者的手设变量当成我们的跳过，卸载时会被删掉又无从还原。
# 归属记录优先于"首次安装"这个推断。
#
# 为什么必须这样：首次安装的推断前提是"机器上还没有我们的东西"，而**卸载没清干净时
# 那个前提不成立**。残留的本机地址代理值会在下一次全新安装时被当成使用者的、存进快照、
# 再按快照还原——于是永远清不掉（实测踩过：ALL_PROXY 与 NODE_USE_ENV_PROXY 两项
# 就这样活过了两次卸载，而卸载每次都报"已恢复到安装前的状态"）。
# 归属记录记的是"我们写下过哪些值"，它比推断更硬：记录里有，就一定不是使用者的原值。
#
# 这一组断言要在**已知的归属记录状态**下跑：先记下真实记录、单独造一份受控的，
# 跑完还原。不这样做的话，同一条断言在"装过一次的机器"和"干净机器"上会得出相反结论——
# 那是最难查的一类红。
# 只有 Windows 有注册表：CI 的 ubuntu 作业跑的是同一份文件。
# 这一段直接 New-Item -Path 'HKCU:\...'，在 Linux 上抛 DriveNotFoundException；
# 而本文件第 19 行是 $ErrorActionPreference = 'Stop'，于是它成为终止错误——
# 脚本当场退出，ALL PASS / FAILURES 那两行都不打印，**之后 124 条断言一条不跑**。
# 那种红看起来像"某条断言失败"，实际是整个后半段都没执行，排查方向会完全跑偏。
# 其余 5 处注册表访问都有守卫（161/175/184/1122/1354），这里照同一形态补上。
if ($env:OS -eq 'Windows_NT') {
$script:SavedOwned = $null
$script:SavedOwnedNames = @()
try {
    if (Test-RegKey (Get-OwnedRegKeyPath)) {
        $ok0 = Get-Item -LiteralPath (Get-OwnedRegKeyPath) -ErrorAction SilentlyContinue
        if ($ok0) {
            foreach ($n in $ok0.GetValueNames()) {
                if ($script:SavedOwned -eq $null) { $script:SavedOwned = @{} }
                $script:SavedOwned[$n] = $ok0.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $script:SavedOwnedNames += $n
            }
        }
    }
    # 造一份受控记录：只记 HTTP_PROXY 与 NODE_USE_ENV_PROXY（两个代表值）
    if (Test-RegKey (Get-OwnedRegKeyPath)) { Remove-Item -LiteralPath (Get-OwnedRegKeyPath) -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -Path (Get-OwnedRegKeyPath) -Force | Out-Null
    Set-ItemProperty -Path (Get-OwnedRegKeyPath) -Name 'HTTP_PROXY' -Value 'http://127.0.0.1:7890'
    Set-ItemProperty -Path (Get-OwnedRegKeyPath) -Name 'NODE_USE_ENV_PROXY' -Value '1'

    # 归属记录里有的值：即使是"首次安装"，也不该进快照（否则卸载还原时又装回去）。
    Assert-Eq '首次安装：归属记录里有的值不进快照' $true (Test-SnapshotSkip 'HTTP_PROXY' 'http://127.0.0.1:7890' $true)
    Assert-Eq '首次安装：NODE_USE_ENV_PROXY=1 在记录里，不进快照' $true (Test-SnapshotSkip 'NODE_USE_ENV_PROXY' '1' $true)
    # 归属记录里没有的值：首次安装时它只可能是使用者自己设的，必须进快照（否则丢配置）。
    Assert-Eq '首次安装：记录里没有的本机地址仍算使用者的' $false (Test-SnapshotSkip 'HTTPS_PROXY' 'http://127.0.0.1:9999' $true)
    # 别人的代理地址从来不跳过（与记录无关）。
    Assert-Eq '别人的代理地址从来不跳过' $false (Test-SnapshotSkip 'HTTP_PROXY' 'http://10.0.0.1:8080' $false)
    Assert-Eq '空值不跳过' $false (Test-SnapshotSkip 'HTTP_PROXY' '' $false)

    # 清掉记录，验证"重装时靠形状判"那条老规则仍然成立（记录缺失时的降级）。
    Remove-Item -LiteralPath (Get-OwnedRegKeyPath) -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Eq '重装：本机地址是我们上次写的，跳过' $true (Test-SnapshotSkip 'HTTPS_PROXY' 'http://127.0.0.1:7890' $false)
    Assert-Eq '重装：NODE_USE_ENV_PROXY=1 是我们写的，跳过' $true (Test-SnapshotSkip 'NODE_USE_ENV_PROXY' '1' $false)
} finally {
    # 还原真实归属记录：这一组断言不该改动这台机器上的安装状态。
    Remove-Item -LiteralPath (Get-OwnedRegKeyPath) -Recurse -Force -ErrorAction SilentlyContinue
    if ($script:SavedOwnedNames.Count -gt 0) {
        New-Item -Path (Get-OwnedRegKeyPath) -Force | Out-Null
        foreach ($n in $script:SavedOwnedNames) {
            Set-ItemProperty -Path (Get-OwnedRegKeyPath) -Name $n -Value $script:SavedOwned[$n] -ErrorAction SilentlyContinue
        }
    }
    Remove-Variable -Name SavedOwned -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name SavedOwnedNames -Scope Script -ErrorAction SilentlyContinue
}
} else {
    Write-Host '  SKIP 快照归属判定（本机没有注册表）'
}

# ------------------------------------------------------------------------------
# [11] 注册表判断：文件系统那套对 HKCU:\ 永远说"不存在"
# ------------------------------------------------------------------------------
# 照着 Test-Item 判"键在不在"，已存在的键会被当成不存在，下一步 New-Item -Force 就把键
# 清空重建——连带删掉里面的用户原值快照。所以注册表一律用 Test-RegKey。
# 只有 Windows 有注册表：CI 的 ubuntu 作业也跑这一份，在那边这三条没有意义。
if ($env:OS -eq 'Windows_NT') {
    Assert-Eq '注册表判断：已存在的键判为存在' $true (Test-RegKey 'HKCU:\Software')
    Assert-Eq '注册表判断：不存在的键判为不存在' $false (Test-RegKey 'HKCU:\Software\EnvProxyNoSuchKey')
    Assert-Eq '文件系统判断对注册表路径返回假（所以注册表要用 Test-RegKey）' $false (Test-Item 'HKCU:\Software')
} else {
    Write-Host '  SKIP 注册表判断（本机没有注册表）'
}

# ------------------------------------------------------------------------------
# [12] 节点判定的双条件迟滞与自适应节流
# ------------------------------------------------------------------------------
# 判"断"要同时满足"次数"和"时长"。只数次数时，判据的时长是「次数 × 节流间隔」的乘积，
# 于是改节流（省流量）会直接变成判"断"的耗时——两件事被一个旋钮绑住，实测 3 × 15 秒
# 意味着"只断开"要等 50 秒。拆开后两种失败都要被拦住：
#   - 次数够、时间不够（短促抖动，问得再勤也不许下结论）
#   - 时间够、次数不够（一次失败间隔很久，不能只凭"时长"就判断）
Assert-Eq '双条件：3 次但只横跨 4 秒不判断' $false (Test-NodeVerdict 3 4 $NodeFailThreshold $NodeFailDwellSec)
Assert-Eq '双条件：2 次即使横跨 30 秒也不判断' $false (Test-NodeVerdict 2 30 $NodeFailThreshold $NodeFailDwellSec)
# 边界用常量推导，不写字面量：写死 10 / 9.9 等于把"dwell 必须恰好是 10"固化进用例，
# 以后正常调参（比如调到 20）会误报红，而这两条声称测的是"双条件"这个机制。
Assert-Eq '双条件：次数够且横跨恰好满 dwell 才判断' $true (Test-NodeVerdict $NodeFailThreshold $NodeFailDwellSec $NodeFailThreshold $NodeFailDwellSec)
Assert-Eq '双条件：差一点点也不行' $false (Test-NodeVerdict $NodeFailThreshold ($NodeFailDwellSec - 0.1) $NodeFailThreshold $NodeFailDwellSec)
Assert-Eq '双条件：次数差一次就不判断' $false (Test-NodeVerdict ($NodeFailThreshold - 1) ($NodeFailDwellSec * 3) $NodeFailThreshold $NodeFailDwellSec)
Assert-Eq '双条件：更多次、更久当然判断' $true (Test-NodeVerdict ($NodeFailThreshold + 2) ($NodeFailDwellSec * 4) $NodeFailThreshold $NodeFailDwellSec)

# 采样间隔跟着"有没有结论"走：稳定态省流量，正在收集证据和刚下结论时加密。
# 关键是最后两条：失败已达阈值（结论已定）时必须回到稳定档——只按"有没有失败"
# 决定间隔的话，节点一直死时计数会无界增长、间隔永远钉在快速档（实测 2.5 倍流量）。
$tNow = Get-MonotonicSeconds
$thr = $NodeFailThreshold
Assert-Eq '间隔：稳定态用稳定间隔' $NodeCheckThrottleSec (Get-NodeProbeInterval 0 $thr -1.0 $tNow $NodeCheckThrottleSec $NodeFastSec)
Assert-Eq '间隔：有失败未达阈值时加密' $NodeFastSec (Get-NodeProbeInterval 1 $thr -1.0 $tNow $NodeCheckThrottleSec $NodeFastSec)
Assert-Eq '间隔：刚下完结论时加密' $NodeFastSec (Get-NodeProbeInterval 0 $thr ($tNow + 1) $tNow $NodeCheckThrottleSec $NodeFastSec)
Assert-Eq '间隔：加密窗口过了就回到稳定档' $NodeCheckThrottleSec (Get-NodeProbeInterval 0 $thr ($tNow + -1) $tNow $NodeCheckThrottleSec $NodeFastSec)
Assert-Eq '间隔：失败已达阈值（结论已定）回到稳定档' $NodeCheckThrottleSec (Get-NodeProbeInterval $thr $thr (-1.0) $tNow $NodeCheckThrottleSec $NodeFastSec)
Assert-Eq '间隔：失败远超阈值也仍是稳定档（计数不会让间隔永远快下去）' $NodeCheckThrottleSec (Get-NodeProbeInterval 999 $thr (-1.0) $tNow $NodeCheckThrottleSec $NodeFastSec)

# 常量自身的形状：加密必须比稳定快，否则"加密"没有意义；判据时长必须是可解释的小数秒。
if ($NodeFastSec -lt $NodeCheckThrottleSec) { Write-Host '  ok   加密间隔确实比稳定态快' } else { Write-Host '  FAIL 加密间隔不比稳定态快，加密没有意义'; $script:fails++ }
if ($NodeFailDwellSec -gt 0) { Write-Host '  ok   dwell 是正数' } else { Write-Host '  FAIL dwell 必须是正数'; $script:fails++ }

# "连续"失败必须先真的连续观测：端口槽位留着旧账时，旧失败起点会让跨度把中间整段
# 没观测的时间算进去，于是一回来就同时满足"≥N 次"和"≥dwell 秒"而当场判"断"——比契约激进。
# 这里直接驱动 Test-NodeAlive，钉住"闲置太久就丢弃旧起点"真的发生了。
$script:NodeState = @{}
$script:ProbeOk = $false
# 替身必须成对还原：本文件其他替身都用 try/finally（见上面的 Get-ListeningTcpConnections）。
# 留着不还原，本文件后面任何"顺带"走到真实连通性判定的用例都会拿到 $script:ProbeOk 的假答案——
# 那种错极难查：断言看起来在测 A，实际测的是一个被前一段代码留下的常量。
$__trcSaved = (Get-Item -Path Function:Test-RealConnectivity).ScriptBlock
try {
${function:Test-RealConnectivity} = { param([int]$p) return $script:ProbeOk }
[void](Test-NodeAlive 7078)                       # 先失败一次，建立失败起点
$slot = $script:NodeState['7078']
$slot.LastCheck = ((Get-MonotonicSeconds) - 600)      # 模拟这个端口很久没被探过
$slot.FirstFailAt = ((Get-MonotonicSeconds) - 600)
$slot.FailCount = 1
[void](Test-NodeAlive 7078)                       # 闲置之后再来一次失败
$span = ((Get-MonotonicSeconds) - $script:NodeState['7078'].FirstFailAt)
Assert-Eq '闲置太久的旧失败起点被丢弃（跨度从 0 重算，不是 600 秒）' $true ($span -lt 60)
Assert-Eq '闲置后失败计数从 1 重新算' 1 $script:NodeState['7078'].FailCount

# 加密观察窗只在**结论翻转**时开。若每次成功都重开，窗口永远不结束，稳态间隔就永远
# 走不到——实测会退化成每 5-6 秒一探，流量变成承诺值的 3 倍。钉住这个闭环：
$script:ProbeOk = $true
$script:NodeState = @{}
$script:NodeState['7078'] = @{ LastCheck = ((Get-MonotonicSeconds) - 20); Alive = $true
    FailCount = 0; FirstFailAt = -1.0; FastUntil = -1.0 }
for ($i = 0; $i -lt 4; $i++) {
    [void](Test-NodeAlive 7078)
    $script:NodeState['7078'].LastCheck = ((Get-MonotonicSeconds) - 2)   # 模拟每轮 2 秒的节奏
}
Assert-Eq '连续成功时不会反复开窗（窗口保持过期，间隔才能回到稳态）' $true ($script:NodeState['7078'].FastUntil -eq -1.0)

$script:NodeState = @{}
$script:NodeState['7078'] = @{ LastCheck = ((Get-MonotonicSeconds) - 20); Alive = $false
    FailCount = 3; FirstFailAt = ($tNow - 30); FastUntil = -1.0 }
[void](Test-NodeAlive 7078)                       # 断->通 翻转
Assert-Eq '断->通翻转后确实开窗' $true ($script:NodeState['7078'].FastUntil -gt (Get-MonotonicSeconds))

# 换端口时新端口必须重新判定，不能沿用上一个端口的结论。
# Win 侧按端口分槽本来就不会串；这条挡的是"将来有人把分槽改成单槽"——
# Mac 侧单槽就是这么把死端口报成"通"的（写错变量的那一类）。
$script:NodeState = @{}
$script:ProbeOk = $true
[void](Test-NodeAlive 7078)                        # 7078 通
Assert-Eq '换端口前：7078 判为通' $true $script:NodeState['7078'].Alive
$script:ProbeOk = $false
$r7897 = Test-NodeAlive 7897                       # 换到死端口，非强制
Assert-Eq '换到死端口首次探测就判为断（不沿用上个端口的"通"）' $false $r7897
Assert-Eq '新端口的槽从零开始计数' 1 $script:NodeState['7897'].FailCount

# 抖动不累积：失败与成功交替时必须始终判"通"（一次成功即清零计数）。
# 轮间隔要落在"能真探到"（≥ 稳定档）与"不触发闲置清零"（< 闲置门槛）之间。
# 取 -30 秒会每轮撞上闲置清零，计数恒为 1、永远够不到阈值——那样这条用例测的是
# 闲置清零，而不是它声称的"抖动不累积"，把"成功即清零"删掉它照样绿。
$probeGap = [int](($NodeCheckThrottleSec + $NodeIdleResetSec) / 2)
$script:NodeState = @{}
$script:NodeState['7078'] = @{ LastCheck = -1.0; Alive = $true
    FailCount = 0; FirstFailAt = -1.0; FastUntil = -1.0 }
$everDown = $false
$maxFails = 0
for ($i = 0; $i -lt 20; $i++) {
    $script:ProbeOk = ($i % 2 -eq 0)
    $script:NodeState['7078'].LastCheck = ((Get-MonotonicSeconds) - $probeGap)
    if (-not (Test-NodeAlive 7078)) { $everDown = $true }
    if ($script:NodeState['7078'].FailCount -gt $maxFails) { $maxFails = $script:NodeState['7078'].FailCount }
}
Assert-Eq '失败/成功交替 20 轮里从不判"断"（抖动不累积）' $false $everDown
Assert-Eq '交替时失败计数最高只到 1（成功即清零，攒不起来）' 1 $maxFails
} finally {
    Set-Item -Path Function:Test-RealConnectivity -Value $__trcSaved
    Remove-Variable -Name __trcSaved -Scope Script -ErrorAction SilentlyContinue
}

# 终端同步：$PROFILE 里的钩子块。核心是"只摘自己那一块、用户内容一字不动"，
# 以及"标记不配对时绝不猜"。沙箱里用两个临时文件当两个版本的 profile——
# Windows 5.1 与 7 的落点不同，两处都要写，这条正是要测的。
Write-Host '[13] 终端同步：$PROFILE 钩子块（多落点）'
$profSbox = Join-Path ([System.IO.Path]::GetTempPath()) ("ep_prof_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $profSbox -Force -ErrorAction SilentlyContinue | Out-Null
$fakeProfile  = Join-Path $profSbox 'ps51_profile.ps1'
$fakeProfile7 = Join-Path $profSbox 'pwsh7_profile.ps1'
$oldOverride = $env:ENVPROXY_PROFILE_OVERRIDE
$env:ENVPROXY_PROFILE_OVERRIDE = $fakeProfile + ';' + $fakeProfile7
try {
    $r = Install-ShellProfile
    Assert-Eq '全新安装成功' $true $r.Ok
    Assert-Eq '两个落点都写了（5.1）' $true (Test-Path $fakeProfile)
    Assert-Eq '两个落点都写了（7）' $true (Test-Path $fakeProfile7)
    $txt = Get-Content $fakeProfile -Raw -Encoding UTF8
    Assert-Eq '写入开始标记' $true ($txt -match [regex]::Escape($ProfileBlockStart))
    Assert-Eq '写入结束标记' $true ($txt -match [regex]::Escape($ProfileBlockEnd))
    # 变量清单从生成的代码里抠出来数：只允许 5 个大写拼写，不许有小写（跨进程重名雷区）
    $namesLine = @($txt -split "`r?`n" | Where-Object { $_ -match 'epNames = @\(' })[0]
    $names = [regex]::Matches($namesLine, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
    Assert-Eq '变量清单恰好 5 个' 5 $names.Count
    Assert-Eq '清单里没有小写拼写' 0 (@($names | Where-Object { $_ -cmatch '^[a-z]' }).Count)
    Assert-Eq '含手动接管开关说明' $true ($txt -match 'ENVPROXY_TERM')
    Assert-Eq '用了 NullString 真删' $true ($txt -match 'NullString')

    Assert-Eq '幂等：再装一次返回 current' 'current' (Install-ShellProfile).Reason
    Assert-Eq '幂等：标记只出现一次' 1 (([regex]::Matches((Get-Content $fakeProfile -Raw -Encoding UTF8), [regex]::Escape($ProfileBlockStart))).Count)

    # 用户原有内容必须保留，且我们的块在末尾（$PROFILE 最后执行才能包住前面的 prompt）
    Set-Content -Path $fakeProfile -Value @('$env:MY_SETTING = "keep-me"', 'function prompt { "custom> " }') -Encoding UTF8
    Assert-Eq '在用户内容之上安装成功' $true (Install-ShellProfile).Ok
    $txt3 = Get-Content $fakeProfile -Raw -Encoding UTF8
    Assert-Eq '用户的设置还在' $true ($txt3 -match 'keep-me')
    Assert-Eq '用户的 prompt 还在' $true ($txt3 -match 'custom>')
    Assert-Eq '块在文件末尾' $ProfileBlockEnd (@($txt3.TrimEnd() -split "`r?`n")[-1])

    # 卸载：只摘我们的块
    Assert-Eq '卸载成功' $true (Remove-ShellProfile).Ok
    $txt4 = Get-Content $fakeProfile -Raw -Encoding UTF8
    Assert-Eq '标记已消失' $false ($txt4 -match 'EnvProxy')
    Assert-Eq '卸载后用户内容完好' $true ($txt4 -match 'keep-me')

    # 标记不配对的护栏：一个字节都不改
    Set-Content -Path $fakeProfile -Value @($ProfileBlockStart, 'dangling') -Encoding UTF8
    $before = [System.IO.File]::ReadAllText($fakeProfile)
    $r5 = Install-ShellProfile
    Assert-Eq '不配对时拒绝安装' $false $r5.Ok
    Assert-Eq '不配对时原因正确' 'unpaired' $r5.Reason
    Assert-Eq '不配对时文件未被改动' $before ([System.IO.File]::ReadAllText($fakeProfile))
    Assert-Eq '不配对时拒绝卸载' $false (Remove-ShellProfile).Ok
    Assert-Eq '不配对时文件仍未被改动' $before ([System.IO.File]::ReadAllText($fakeProfile))

    # 没有我们标记的文件：卸载碰都不碰（连 mtime 都不改）
    Set-Content -Path $fakeProfile -Value @('$env:X = 1') -Encoding UTF8
    $mt1 = (Get-Item $fakeProfile).LastWriteTime.Ticks
    Start-Sleep -Milliseconds 30
    Assert-Eq '无标记时卸载返回 no-block' 'no-block' (Remove-ShellProfile).Reason
    Assert-Eq '无标记时 mtime 未变' $mt1 (Get-Item $fakeProfile).LastWriteTime.Ticks

    # 升级：旧块内容不同必须重写（否则改了钩子却送不到用户手里）
    Set-Content -Path $fakeProfile -Value @('$env:Y=2', $ProfileBlockStart, 'OLD-HOOK', $ProfileBlockEnd) -Encoding UTF8
    Assert-Eq '旧块被识别为过期并重写' 'installed' (Install-ShellProfile).Reason
    $txt7 = Get-Content $fakeProfile -Raw -Encoding UTF8
    Assert-Eq '旧的钩子内容已消失' $false ($txt7 -match 'OLD-HOOK')
    Assert-Eq '升级时用户内容保留' $true ($txt7 -match 'Y=2')

    # 用户配置文件的编码必须原样保住，而且要逐字节还原。
    # 这是最容易被写坏的东西：GBK 被当 UTF-8 读会变乱码、BOM 每轮叠加一层。
    # 行尾也要保住：WriteAllLines 固定用 Environment.NewLine（CRLF），会把 LF 的
    # profile 静默改成 CRLF——夹具只写 CRLF 时这条永远测不出来，所以这里带上 LF。
    #
    # GBK 用例写死代码页 936，不用 CurrentCulture 的 ANSICodePage：
    # 那个值跟着运行环境走（CI 的 ubuntu 上是 1252，编不了中文，中文会变成 "?"），
    # 于是这条用例在非中文环境下测的其实是"1252 能不能往返"——看起来红，但和 GBK 无关。
    $gbk = $null
    try { $gbk = [System.Text.Encoding]::GetEncoding(936) } catch { }
    $encCases = @()
    if ($gbk) {
        $encCases += @{ Name = 'GBK'; Enc = $gbk; Nl = "`r`n" }
    } else {
        Write-Host '  SKIP GBK 用例：这个平台没有代码页 936（非中文环境），无从构造 GBK 文件'
    }
    $encCases += @{ Name = 'UTF8-BOM';  Enc = (New-Object System.Text.UTF8Encoding($true));            Nl = "`r`n" }
    $encCases += @{ Name = 'UTF8';      Enc = (New-Object System.Text.UTF8Encoding($false));           Nl = "`r`n" }
    $encCases += @{ Name = 'UTF8-LF';   Enc = (New-Object System.Text.UTF8Encoding($false));           Nl = "`n" }
    $encCases += @{ Name = 'UTF8BOM-LF';Enc = (New-Object System.Text.UTF8Encoding($true));            Nl = "`n" }
    $encCases += @{ Name = 'UTF16-LE';  Enc = (New-Object System.Text.UnicodeEncoding($false, $true)); Nl = "`r`n" }
    $userLine = '# 我的 PowerShell 配置'
    foreach ($c in $encCases) {
        $fp = Join-Path $profSbox ("enc_" + $c.Name + ".ps1")
        # UnicodeEncoding 的 GetBytes 不含前导 BOM，要自己补，否则读回来对不上。
        $body = $c.Enc.GetBytes($userLine + $c.Nl)
        if ($c.Name -eq 'UTF8-BOM' -or $c.Name -eq 'UTF8BOM-LF') { $body = [System.Text.Encoding]::UTF8.GetPreamble() + $body }
        if ($c.Name -eq 'UTF16-LE') { $body = $c.Enc.GetPreamble() + $body }
        [System.IO.File]::WriteAllBytes($fp, $body)
        $orig = [System.IO.File]::ReadAllBytes($fp)
        $env:ENVPROXY_PROFILE_OVERRIDE = $fp
        $rI = Install-ShellProfile
        $txtAfter = $c.Enc.GetString([System.IO.File]::ReadAllBytes($fp))
        Assert-Eq ("{0} 安装成功" -f $c.Name) $true $rI.Ok
        Assert-Eq ("{0} 用户原有中文保住" -f $c.Name) $true ($txtAfter -match '我的 PowerShell 配置')
        # 块里那几行刻意是纯 ASCII：我们不知道目标文件是什么编码，
        # 中文注释放进无 BOM 文件会被 5.1 当 ANSI 读成乱码。
        Assert-Eq ("{0} 钩子块写入" -f $c.Name) $true ($txtAfter -match 'EnvProxy: keeps already-open windows')
        # 行尾风格在安装后必须没变：LF 夹具里不该出现 CR。
        if ($c.Nl -eq "`n") {
            $afterBytes = [System.IO.File]::ReadAllBytes($fp)
            $cr = @($afterBytes | Where-Object { $_ -eq 13 }).Count
            Assert-Eq ("{0} 安装后行尾未被改成 CRLF" -f $c.Name) 0 $cr
        }
        $null = Remove-ShellProfile
        $fin = [System.IO.File]::ReadAllBytes($fp)
        Assert-Eq ("{0} 卸载后逐字节还原（BOM 不叠加）" -f $c.Name) $true (($fin -join ',') -eq ($orig -join ','))
    }
} finally {
    if ($null -eq $oldOverride) { Remove-Item Env:ENVPROXY_PROFILE_OVERRIDE -ErrorAction SilentlyContinue }
    else { $env:ENVPROXY_PROFILE_OVERRIDE = $oldOverride }
    Remove-Item -Recurse -Force $profSbox -ErrorAction SilentlyContinue
}

# 终端同步的**行为**验证：钩子块生成出来以后，改注册表能不能让当前会话跟着变。
# 这一步是"敲回车就跟上"的核心机制，只检查文本里有没有 prompt 是不够的。
# 它读写的全是 Windows 注册表，Linux 上没有这一层（CI 的 ubuntu 上要跳过，
# 不是"失败"——Mac 侧对应行为由 mac/envproxy.sh self-test 自己覆盖）。
Write-Host '[14] 终端同步：钩子的真实行为'
if ($env:OS -ne 'Windows_NT') {
    Write-Host '  SKIP 这一步验证的是 Windows 注册表侧的钩子行为，非 Windows 平台跳过'
} else {
$hookSBox = Join-Path ([System.IO.Path]::GetTempPath()) ("ep_hook_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $hookSBox -Force -ErrorAction SilentlyContinue | Out-Null
$hookFile = Join-Path $hookSBox 'hook.ps1'
[System.IO.File]::WriteAllLines($hookFile, (Get-ProfileBlockLines), (New-Object System.Text.UTF8Encoding($false)))
$savedEnv = @{}
foreach ($n in $ProxyVarNames) { $savedEnv[$n] = [Environment]::GetEnvironmentVariable($n, 'User') }
# 归属记录要整份存下来再还原，只记「存不存在」不够：
# 它是「哪些值是我们写的」的唯一凭据，而真实安装过的机器上它是有内容的。
# 测试中途会把它删掉（模拟「没有归属记录」那一档），跑完必须原样放回——
# 否则跑一次自检就把用户机器的归属记录清空，Git Bash 的钩子从此再也清不掉变量
#（契约：没有归属记录时一个都不动），而且不报任何错。
$savedOwnedExist = Test-Path (Get-OwnedRegKeyPath)
$savedOwnedValues = @{}
if ($savedOwnedExist) {
    $__so = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($OwnedRegSubKey, $false)
    if ($null -ne $__so) {
        foreach ($__sn in $__so.GetValueNames()) { $savedOwnedValues[$__sn] = [string]$__so.GetValue($__sn) }
        $__so.Close()
    }
}
# 直接写注册表，不走 [Environment]::SetEnvironmentVariable：后者每写一次都会等
# WM_SETTINGCHANGE 广播超时（实测 5 个变量约 26 秒），自检会卡到超时。
# 钩子读的就是注册表这一层，直接写它等价，而且更快。
function Set-RegValue([string]$Name, $Value) {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($UserEnvSubKey, $true)
    if ($null -eq $k) { return }
    if ($null -eq $Value) { try { $k.DeleteValue($Name, $false) } catch {} }
    else { $k.SetValue($Name, [string]$Value, [Microsoft.Win32.RegistryValueKind]::String) }
    $k.Close()
}
try {
    foreach ($n in $ProxyVarNames) { Set-RegValue $n $null }
    if (Test-Path (Get-OwnedRegKeyPath)) { Remove-Item (Get-OwnedRegKeyPath) -Recurse -Force }
    foreach ($n in $ProxyVarNames) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
    Remove-Item Env:__EnvProxyPromptWrapped -ErrorAction SilentlyContinue
    Remove-Item Env:ENVPROXY_TERM -ErrorAction SilentlyContinue

    # 代理开着：注册表有值 + 归属记录 -> 钩子注入
    # 归属记录用真实写入路径产生（它就是 monitor 写的那一份）。
    foreach ($n in $ProxyVarNames) { Set-RegValue $n $null }
    Set-RegValue 'HTTP_PROXY'  'http://127.0.0.1:7078'
    Set-RegValue 'HTTPS_PROXY' 'http://127.0.0.1:7078'
    Set-RegValue 'ALL_PROXY'   'http://127.0.0.1:7078'
    Set-RegValue 'NO_PROXY'    'localhost,127.0.0.1,::1'
    Set-RegValue 'NODE_USE_ENV_PROXY' '1'
    if (-not (Test-RegKey (Get-OwnedRegKeyPath))) { New-Item -Path (Get-OwnedRegKeyPath) -Force | Out-Null }
    $ok = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($OwnedRegSubKey, $true)
    if ($ok) {
        $ok.SetValue('HTTP_PROXY',  'http://127.0.0.1:7078', [Microsoft.Win32.RegistryValueKind]::String)
        $ok.SetValue('HTTPS_PROXY', 'http://127.0.0.1:7078', [Microsoft.Win32.RegistryValueKind]::String)
        $ok.SetValue('ALL_PROXY',   'http://127.0.0.1:7078', [Microsoft.Win32.RegistryValueKind]::String)
        $ok.SetValue('NO_PROXY',    'localhost,127.0.0.1,::1', [Microsoft.Win32.RegistryValueKind]::String)
        $ok.SetValue('NODE_USE_ENV_PROXY', '1', [Microsoft.Win32.RegistryValueKind]::String)
        $ok.Close()
    }
    . $hookFile
    Assert-Eq '加载钩子后立刻注入' 'http://127.0.0.1:7078' $env:HTTPS_PROXY
    # 注意：不能用 "$null -ne $function:prompt" 判"包住了"——PowerShell 自带默认 prompt，
    # 那个表达式永远为真，把包装函数整行删掉也照样 PASS（实测如此）。
    # 真判据是我们自己的哨兵变量 + 真的调一次 prompt 看效果。
    Assert-Eq '包装标记已置位（这是回车生效的机制）' $true $global:__EnvProxyPromptWrapped
    Assert-Eq '原 prompt 已备份（用于链式调用）' $true ($null -ne $global:__EnvProxyPrevPrompt)

    # 真实路径：敲回车 = 宿主调用 prompt。这里手动调一次，走的是包装后的函数。
    foreach ($n in $ProxyVarNames) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
    $null = prompt
    Assert-Eq '敲回车（调 prompt）后拿到代理' 'http://127.0.0.1:7078' $env:HTTPS_PROXY

    # 代理关掉：monitor 清掉注册表里的值 -> 钩子把会话里"我们写过的"也清掉
    foreach ($n in $ProxyVarNames) { Set-RegValue $n $null }
    $null = prompt
    Assert-Eq '代理关掉后回到提示符恢复直连' '' "$env:HTTPS_PROXY"

    # 用户自己设的值必须保留（README 的承诺，也是契约里最容易被破坏的一条）
    $env:HTTPS_PROXY = 'http://corp-proxy:8080'
    $null = prompt
    Assert-Eq '用户自己的公司代理不被删' 'http://corp-proxy:8080' $env:HTTPS_PROXY

    $env:HTTPS_PROXY = 'http://127.0.0.1:8080'
    $null = prompt
    Assert-Eq '用户自己的本机地址不被删' 'http://127.0.0.1:8080' $env:HTTPS_PROXY

    # 逐窗口接管
    foreach ($n in $ProxyVarNames) { Set-RegValue $n $null }
    Set-RegValue 'HTTPS_PROXY' 'http://127.0.0.1:7078'
    Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue
    $null = prompt
    Assert-Eq '重新注入' 'http://127.0.0.1:7078' $env:HTTPS_PROXY
    $env:ENVPROXY_TERM = 'off'
    $null = prompt
    Assert-Eq '接管开关生效（固定直连）' '' "$env:HTTPS_PROXY"
    Remove-Item Env:ENVPROXY_TERM -ErrorAction SilentlyContinue
    $null = prompt
    Assert-Eq '放开接管开关后恢复自动' 'http://127.0.0.1:7078' $env:HTTPS_PROXY

    # 归属边界：这几条决定"会不会误删使用者自己的代理"，是最难事后补救的一类。
    # 钩子的判据只有两条：注册表有值就注入；没有值但当前值等于归属记录里记的那个就清除。
    # 所以每条用例都必须先把归属记录摆成真实状态，再只改被测的那一个维度——
    # 否则所有用例都会落进同一个"没有归属记录→什么都不做"的分支，断言再多条也是假的。
    $savedBakExist = Test-Path (Get-PrevEnvRegKeyPath)
    Write-Host '[14b] 归属边界：什么时候可以清'

    # 造一份真实的归属记录，模拟"我们确实写过这些值"。
    function Set-OwnedRecord([string]$Value) {
        if (-not (Test-Path (Get-OwnedRegKeyPath))) { New-Item -Path (Get-OwnedRegKeyPath) -Force -ErrorAction SilentlyContinue | Out-Null }
        $ok = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($OwnedRegSubKey, $true)
        if ($null -eq $ok) { return }
        foreach ($n in $ProxyVarNames) {
            if ($n -eq 'NODE_USE_ENV_PROXY') { $ok.SetValue($n, '1', [Microsoft.Win32.RegistryValueKind]::String) }
            else { $ok.SetValue($n, $Value, [Microsoft.Win32.RegistryValueKind]::String) }
        }
        $ok.Close()
    }

    # (a) 有归属记录、当前值等于记录值 → 清除（这是主功能：翻墙关了要还原）
    foreach ($n in $ProxyVarNames) { Set-RegValue $n $null }
    Set-OwnedRecord 'http://127.0.0.1:7078'
    $env:HTTPS_PROXY = 'http://127.0.0.1:7078'
    $null = prompt
    Assert-Eq '值等于记录值：清除' '' "$env:HTTPS_PROXY"

    # (b) 有归属记录、但使用者改成了别的值 → 必须保住（不能按形状猜）
    $env:HTTPS_PROXY = 'http://corp-proxy:8080'
    $null = prompt
    Assert-Eq '值不等于记录值：保住公司代理' 'http://corp-proxy:8080' $env:HTTPS_PROXY

    # (c) 有归属记录、使用者改成另一个本机端口 → 同样必须保住
    $env:HTTPS_PROXY = 'http://127.0.0.1:9090'
    $null = prompt
    Assert-Eq '值不等于记录值：保住别的端口的本机代理' 'http://127.0.0.1:9090' $env:HTTPS_PROXY

    # (d) 没有归属记录 → 判不了，一个都不动
    if (Test-Path (Get-OwnedRegKeyPath)) { Remove-Item (Get-OwnedRegKeyPath) -Recurse -Force }
    $env:HTTPS_PROXY = 'http://127.0.0.1:7078'
    $null = prompt
    Assert-Eq '无归属记录时不动任何值（判不了就不猜）' 'http://127.0.0.1:7078' $env:HTTPS_PROXY

    # (e) 快照保护住在 env.ps1 的注册表清理路径里，不在钩子里——直接断言那个判据，
    #     不能拿钩子的行为冒充它（钩子根本不读快照）。
    Assert-Eq 'Test-IsOwnedProxyValue 是真实存在的判据' 'Function' (Get-Command Test-IsOwnedProxyValue -ErrorAction SilentlyContinue).CommandType

} finally {
    foreach ($n in $ProxyVarNames) { Set-RegValue $n $savedEnv[$n] }
    # 快照键：测试往 Backup 里种过值。原本就有的只删我们种的那一项；
    # 原本没有的整棵删掉——否则会在使用者机器上留一个空键。
    if (Test-Path (Get-PrevEnvRegKeyPath)) {
        $bk2 = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($PrevEnvSubKey, $true)
        $emptyNow = $false
        if ($null -ne $bk2) {
            try { $bk2.DeleteValue('HTTPS_PROXY', $false) } catch {}
            $emptyNow = (@($bk2.GetValueNames()).Count -eq 0)
            $bk2.Close()
        }
        if ($emptyNow -and (-not $savedBakExist)) { Remove-Item (Get-PrevEnvRegKeyPath) -Recurse -Force -ErrorAction SilentlyContinue }
    }
    # 归属记录：整份放回原样。
    # 测试中途会删掉它（模拟「没有归属记录」那一档），跑完必须还原——
    # 它是「哪些值是我们写的」的唯一凭据：清空了，Git Bash 的钩子就再也清不掉变量
    #（契约：没有归属记录时一个都不动），而且不报任何错。
    if ($savedOwnedExist) {
        if (-not (Test-Path (Get-OwnedRegKeyPath))) { New-Item -Path (Get-OwnedRegKeyPath) -Force -ErrorAction SilentlyContinue | Out-Null }
        $__ro = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($OwnedRegSubKey, $true)
        if ($null -ne $__ro) {
            foreach ($__rn in $savedOwnedValues.Keys) {
                $__ro.SetValue($__rn, $savedOwnedValues[$__rn], [Microsoft.Win32.RegistryValueKind]::String)
            }
            $__ro.Close()
        }
    } else {
        if (Test-Path (Get-OwnedRegKeyPath)) { Remove-Item (Get-OwnedRegKeyPath) -Recurse -Force -ErrorAction SilentlyContinue }
        # 只有它空了才删父键（父键可能装着真实的 ScriptPath）。
        if ((Test-Path (Get-ScriptPathRegKeyPath)) -and -not (@(Get-ChildItem (Get-ScriptPathRegKeyPath) -ErrorAction SilentlyContinue).Count)) {
            Remove-Item (Get-ScriptPathRegKeyPath) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($n in $ProxyVarNames) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
    Remove-Item Env:ENVPROXY_TERM -ErrorAction SilentlyContinue
    Remove-Item Env:__EnvProxyPromptWrapped -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $hookSBox -ErrorAction SilentlyContinue
}
}


# ------------------------------------------------------------------------------
# [20] 文档里印出来的每条命令都真能跑
# 这一节的理由：帮助和 README 里的命令是给用户「照抄」的。抄下来跑不通，
# 比不写更糟——用户会以为是自己敲错了。所以这里把每种终端的写法都真跑一遍，
# 断言的是「可观察的结果」，不是「字符串里有没有这个词」。
# 只验证不依赖网络、不改用户设置的那些：改完立刻复原。
# ------------------------------------------------------------------------------
Write-Host '[20] every documented command actually runs'

# PowerShell：固定直连 -> 复原
$env:ENVPROXY_TERM = 'off'
Assert-Eq 'PS: ENVPROXY_TERM becomes off' 'off' $env:ENVPROXY_TERM
Remove-Item Env:ENVPROXY_TERM -ErrorAction SilentlyContinue
Assert-Eq 'PS: Remove-Item clears it' $true ($null -eq $env:ENVPROXY_TERM)

# PowerShell：设了能读回来
$env:HTTPS_PROXY = 'http://1.2.3.4:8080'
Assert-Eq 'PS: corporate proxy reads back' 'http://1.2.3.4:8080' $env:HTTPS_PROXY
Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue

# curl 的别名差异：文档说 5.1 是别名、7 不是。这条钉住这个前提。
$curlKind = (Get-Command curl -ErrorAction SilentlyContinue).CommandType.ToString()
$is51 = ($PSVersionTable.PSVersion.Major -lt 6)
Assert-Eq 'curl kind matches what the docs claim for this version' $true (($is51 -and $curlKind -eq 'Alias') -or ((-not $is51) -and $curlKind -ne 'Alias'))

# cmd：清 5 个变量（一行写法）。用独立 cmd 进程，不碰本进程环境。
# 没有 SystemRoot 就是不在 Windows 上（CI 的 Linux 侧会跑这一份）：这时根本没有 cmd.exe，
# 连 Join-Path 都会因为参数为空直接抛错——而一个抛错会让**整个自检静默中止**，
# 后面所有用例一条都不跑，日志里却只看到"退出码 1"。所以先算出生效的路径，拿不到就跳过。
$cmdExe = $null
if ($env:SystemRoot) { $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe' }
if ($cmdExe -and (Test-Path -LiteralPath $cmdExe)) {
    $script = (@('@echo off', 'set HTTPS_PROXY=http://b', 'set HTTP_PROXY=&set HTTPS_PROXY=&set ALL_PROXY=&set NO_PROXY=&set NODE_USE_ENV_PROXY=', 'if defined HTTPS_PROXY (echo LEFT) else (echo CLEARED)') -join "`r`n")
    $tmpCmd = Join-Path $env:TEMP ('ep_cmd_' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.cmd')
    [System.IO.File]::WriteAllText($tmpCmd, $script, (New-Object System.Text.ASCIIEncoding))
    $out = (& $cmdExe /c $tmpCmd) -join ' '
    Remove-Item -LiteralPath $tmpCmd -Force -ErrorAction SilentlyContinue
    Assert-Eq 'cmd: one-line clear really clears' $true ($out -match 'CLEARED')
}

# cmd 的坑：& 两边留空格会得到一个只含空格的值。文档专门警告过，这里钉住这个事实。
if ($cmdExe -and (Test-Path -LiteralPath $cmdExe)) {
    $tmpCmd2 = Join-Path $env:TEMP ('ep_cmd2_' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.cmd')
    $script2 = (@('@echo off', 'set SPACETEST=hello', 'set SPACETEST= & set OTHER=1', 'if "[%SPACETEST%]"=="[ ]" (echo HASTHE-SPACE) else (echo NO-SPACE)') -join "`r`n")
    [System.IO.File]::WriteAllText($tmpCmd2, $script2, (New-Object System.Text.ASCIIEncoding))
    $out2 = (& $cmdExe /c $tmpCmd2) -join ' '
    Remove-Item -LiteralPath $tmpCmd2 -Force -ErrorAction SilentlyContinue
    Assert-Eq 'cmd: the documented space trap is real' $true ($out2 -match 'HASTHE-SPACE')
}

# 文档里每条命令的「形状」也要对：只有 PowerShell 才用 $env:，只有 bash 才用 export。
$docText = (Format-HelpTopic '3')
Assert-Eq 'help gives a cmd form for pinning' $true ($docText -match 'set HTTP_PROXY=')
Assert-Eq 'help gives a bash form for pinning' $true ($docText -match 'unset HTTP_PROXY')
Assert-Eq 'help gives a PowerShell form for pinning' $true ($docText -match '\$env:ENVPROXY_TERM')
Assert-Eq 'help warns about the ampersand space trap' $true ($docText -match '空格')

# 状态页必须主动认下"变量指向的端口已经不在"这件事。
# 不认的话，终端里每条联网命令都会报 ECONNREFUSED 127.0.0.1:xxxx，
# 而错误信息里没有本工具的名字——用户（和帮他排查的 AI）会去查网络、防火墙、DNS，
# 唯独查不到这里。这条断言钉住那份"主动认错"的文案还在。
# 状态页拆成了两层：采集（Get-StatusSnapshot）与渲染（Show-StatusSnapshot）。
# 断言要跟着拆，否则会变成"查了一个不含这段代码的函数"——那是假红，也是假绿。
# 原则不变：判据（试连）与文案（主动认 ECONNREFUSED）都必须还在，只是各在自己的层里。
$snapSrc = (Get-Command Get-StatusSnapshot).Definition
$renderSrc = (Get-Command Show-StatusSnapshot).Definition
Assert-Eq 'status page checks whether the injected port is still alive' $true ($snapSrc -match 'Test-TcpAlive')
Assert-Eq 'status page names ECONNREFUSED as its own doing' $true ($renderSrc -match 'ECONNREFUSED')
Assert-Eq 'status page tells the reader what to do next' $true ($renderSrc -match '安装 / 修复')
# 结论行必须在最上面：读者读完 8 行再自己合成判断，是这屏原来的最大问题。
Assert-Eq 'status page leads with a one-line verdict' $true ($renderSrc -match '一切正常')

# 绿色的一行 = "这一整行可以复制去跑"。颜色是唯一告诉读者"哪些行是命令"的东西，
# 所以这个承诺必须是真的。历史上假过两次：
#   - 一条命令被拆成两行绿色（只复制前半段会留下半套变量，正是本项目要防的状态）；
#   - 一串开关名因为缩进像命令而被染绿，粘进终端却报"无法识别开关"。
# 现在颜色由内容声明（'c ' 标记表示"整行可复制"），于是断言从"渲染结果里的命令段"取，
# 而不是从一个会在改文案后漂移的形状判据取。
$cmdTexts = @()
foreach ($t2 in $helpTopics) {
    foreach ($r2 in (Get-HelpRenderedLines $t2.Lines)) {
        # 两列行（r/rc）的右边是命令，也要收；但编号段（m 行）不算命令。
        if ($r2.Role -eq 'cmd') { $cmdTexts += $r2.Text.Trim(); continue }
        if ($r2.Role -ne 'row') { continue }
        foreach ($sg2 in $r2.Segments) {
            if ($sg2.Role -ne 'cmd') { continue }
            # 纯数字段是菜单编号，不是命令。
            if ($sg2.Text.Trim() -match '^\d+$') { continue }
            $cmdTexts += $sg2.Text.Trim()
        }
    }
}
$cmdTexts = @($cmdTexts | Where-Object { $_ })
Assert-Eq 'help actually shows runnable commands' $true ($cmdTexts.Count -ge 5)
# 只按"渲染成命令色"收不行：帮助 6（菜单那一屏）的编号也是命令色，它们不是命令，
# 是"在这个屏幕里敲哪个数字"。判据用行角色把两者分开——cmd 行才是命令，
# row 行里的 cmd 段是"要敲的编号"，不该拿去比对"首词是不是真程序"。
$cmdFirstTokens = @{}
foreach ($c in $cmdTexts) {
    $first = ($c -split '\s+')[0]
    if (-not $cmdFirstTokens.ContainsKey($first)) { $cmdFirstTokens[$first] = $c }
}
# 允许的首词表刻意写得小而明确：帮助里只该出现这么多工具。
# `$env:NAME = 'value'` 是赋值语句，所以绿色行也可以以变量引用开头。
# 保持明确：帮助不该悄悄开始展示没人审过的工具。
# `tail`（Git Bash 自带）与 `Get-Content`（PowerShell 自带）用于帮助第 7 条
# 教用户怎么取最后 20 行日志——两者都是系统自带命令，不破零依赖。
$allowed = @('powershell', 'set', 'unset', 'export', 'Remove-Item', 'Get-Content', 'tail',
             'curl', 'curl.exe', 'git', 'npm', 'wget', 'wget.exe', 'echo', '.', 'source')
foreach ($first in $cmdFirstTokens.Keys) {
    $isAssignment = $first -match '^\$env:[A-Za-z_][A-Za-z0-9_]*$'
    Assert-Eq ('a green line starts with a real program: ' + $first) $true (($allowed -contains $first) -or $isAssignment)
}
# 只有开关的一行不是命令，是备忘单。
foreach ($c in $cmdTexts) {
    Assert-Eq ('a green line is not just a list of switches: ' + $c) $false ($c -match '^-{1,2}\w+(\s+-{1,2}\w+)+$')
}
# 命令不许断在半路：以 '&' 结尾意味着后半段在下一行，单独复制只做了一半的活。
# （`set VAR=` 以等号结尾是完整命令——它就是在清空变量，不算断。）
foreach ($c in $cmdTexts) {
    Assert-Eq ('a green command is not left unfinished: ' + $c) $false ($c -match '&$')
}

# The "you can type X" hint must never name a key that does not exist. Taking the
# first and last key and printing a span does exactly that after a row is removed:
# 1..6 minus 4 still read as "1-6", and typing 4 answers "no such number".
Assert-Eq 'a contiguous key list collapses to a span' '1-6' (Format-KeyList @('1','2','3','4','5','6'))
Assert-Eq 'a gapped key list is spelled out' '1 2 3 5 6' (Format-KeyList @('1','2','3','5','6'))
Assert-Eq 'a single key is just itself' '4' (Format-KeyList @('4'))
Assert-Eq 'an empty list says nothing' '' (Format-KeyList @())
$saveItems = @($MenuItems)
try {
    $MenuItems = @($MenuItems | Where-Object { $_.Key -ne '4' })
    $rangeWithGap = Get-MenuKeyRange
    Assert-Eq 'the menu hint never names a removed key' $false ($rangeWithGap -match '\b4\b')
    Assert-Eq 'the menu hint still names every remaining key' $true (($rangeWithGap -match '1 2 3') -and ($rangeWithGap -match '5 6'))
} finally {
    $MenuItems = $saveItems
}

# The coloured screen and the plain-text menu must take their group order from the
# SAME derived list. They once each had a hand-written array: a group typo then made
# an item invisible on screen while it stayed typeable -- the user sees one menu and
# can run another. Pin it structurally: no hand-written group array may reappear.
# 彩屏、纯文本、帮助第 6 条必须都从同一个渲染来源取分组顺序。
# 三个函数各自拼一遍的话，分组只要改一处漏两处，就会出现"屏幕上少一项、却照样敲得动"。
foreach ($fn in @('Get-MenuRenderedLines', 'Get-HelpMenuLines')) {
    $src = (Get-Command $fn).Definition
    Assert-Eq ($fn + ' derives its groups instead of listing them') $false ($src -match "@\('日常'")
    Assert-Eq ($fn + ' uses the shared group order') $true ($src -match 'Get-MenuGroups')
}
# 纯文本与彩屏必须同源：只查"两边都上色"是不够的，得钉住它们点名了同一个渲染函数，
# 否则各写一份内容照样能通过颜色断言（颜色对、字不一样）。
foreach ($fn in @('Show-MenuColored', 'Format-MenuText')) {
    $src = (Get-Command $fn).Definition
    Assert-Eq ($fn + ' renders from the shared source') $true ($src -match 'Get-MenuRenderedLines')
}
Assert-Eq 'the shared group order is the only place groups are ordered' 1 (([regex]::Matches((Get-Command Get-MenuGroups).Definition, 'Select-Object -Unique')).Count)

# Help topic 6 is a second copy of the menu table. If it is hand-written it goes
# stale silently, and the symptom is the worst kind: the user reads help, types the
# number it names, and gets a DIFFERENT action (wants check-for-updates, uninstalls).
# So it must be generated from $MenuItems, and this assertion proves it is: a fake
# menu entry must show up in the help screen with no other edit.
$helpMenuText = (Format-HelpTopic '6')
foreach ($mi in $MenuItems) {
    Assert-Eq ('help menu screen shows menu key ' + $mi.Key) $true ($helpMenuText -match ('(?m)^\s+' + [regex]::Escape($mi.Key) + '\s{2}'))
    Assert-Eq ('help menu screen names menu key ' + $mi.Key) $true ($helpMenuText -match [regex]::Escape($mi.Name))
}
# Mutation test: append a row to the table and confirm it appears on the help screen.
$fakeRow = @{ Key = '9'; Name = '假条目'; Switch = 'Status'; Group = '日常'; Hint = '这条只用于自检' }
$MenuItems = @($MenuItems) + $fakeRow
$helpMenuText2 = (Format-HelpTopic '6')
Assert-Eq 'the help menu screen is generated from the table' $true ($helpMenuText2 -match '假条目')
Assert-Eq 'a generated row keeps its hint' $true ($helpMenuText2 -match '这条只用于自检')
$MenuItems = @($MenuItems | Where-Object { $_.Key -ne '9' })

# ------------------------------------------------------------------------------
# [21] README 抄了一份菜单表和帮助目录，必须是代码的镜像
# 这一节的理由：README 不能引用代码，只能把菜单编号和帮助标题抄一份。这一份
# 一旦和代码脱节，后果比"文档旧了"严重：用户照 README 的编号去敲，敲到的是
# 另一件事（想检查更新，结果卸载了）。这类错误没人会当场发现——文档看着很正常。
# 所以这里把两份表逐行对回代码：名字必须一字不差（中文那份直接就是代码里的字符串），
# 编号顺序也必须一致。英文那份只比编号与行数，标题是另一种语言，比不了字面。
# ------------------------------------------------------------------------------
Write-Host '[21] README mirrors the menu and help tables'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
# 按表头认表，不按周围的散文认：散文措辞会改，表头是这张表自己的身份。
# $Headers 里任一命中即算这张表。取到表头后往下读到第一个空行为止。
function Get-TableByHeader([string[]]$Lines, [string[]]$Headers) {
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch '^\|') { continue }
        $cells = @($Lines[$i] -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        foreach ($h in $Headers) { if ($cells -contains $h) {
            $rows = @()
            for ($k = $i + 2; $k -lt $Lines.Count; $k++) {
                if ($Lines[$k] -notmatch '^\|') { break }
                $rows += $Lines[$k]
            }
            return $rows
        } }
    }
    return @()
}
foreach ($pair in @(@('README.md', $false), @('README.en.md', $true))) {
    $docPath = Join-Path $repoRoot $pair[0]
    if (-not (Test-Path -LiteralPath $docPath)) {
        Assert-Eq ($pair[0] + ' exists') $true $false
        continue
    }
    $docLines = [System.IO.File]::ReadAllLines($docPath, [System.Text.Encoding]::UTF8)
    $menuRows = @(Get-TableByHeader $docLines @('菜单项', 'Menu item'))
    $helpRows = @(Get-TableByHeader $docLines @('编号', 'No.'))
    $docMenuKeys = @($menuRows | ForEach-Object { [regex]::Match($_, '^\|\s*\*\*(\d)').Groups[1].Value } | Where-Object { $_ })
    $docHelpKeys = @($helpRows | ForEach-Object { [regex]::Match($_, '^\|\s*(\d)\s*\|').Groups[1].Value } | Where-Object { $_ })
    $codeMenuKeys = @($MenuItems | ForEach-Object { $_.Key })
    $codeHelpKeys = @(Get-HelpTopics | ForEach-Object { $_.Key })
    Assert-Eq ($pair[0] + ' menu table lists every menu key in code order') ($codeMenuKeys -join ',') ($docMenuKeys -join ',')
    Assert-Eq ($pair[0] + ' help table lists every help topic in code order') ($codeHelpKeys -join ',') ($docHelpKeys -join ',')
    # 编号对上了，还要对名字：编号和名字各自正确、但配错了对，照样把人指到另一个动作上。
    # 只有中文 README 能逐字比——它的名字就是代码里的同一个字符串。
    if ($pair[0] -eq 'README.md') {
        foreach ($mi in $MenuItems) {
            $want = '**' + $mi.Key + ' ' + $mi.Name + '**'
            Assert-Eq ('README names menu key ' + $mi.Key + ' as ' + $mi.Name) $true ([bool]($menuRows -match [regex]::Escape($want)))
        }
        foreach ($t in (Get-HelpTopics)) {
            $want = '| ' + $t.Key + ' | ' + $t.Title + ' |'
            Assert-Eq ('README names help topic ' + $t.Key + ' as ' + $t.Title) $true ([bool]($helpRows -match [regex]::Escape($want)))
        }
    }
}

# ------------------------------------------------------------------------------
# [9w] 接线（源码级）：这些地方"删掉一行就静默失效"
# ------------------------------------------------------------------------------
# 破坏测试的结论：这套门禁擅长拦「格式 / 常量 / 纯函数」，不擅长拦「减法」——
# 删掉一行关键调用、或者让某个门槛恒假，所有门禁仍然全绿，而产品彻底不能用。实测的
# 三个 P0：把入口最后的 Run-MonitorLoop 注释掉（开机自启静默退出 0）；让
# Test-ProxyVarsPresent 恒返回 $false（变量永远删不掉、连卸载都清不干净）；
# 去掉 Confirm-CandidatePort 里的节点验证（死代理被判成翻墙中）。
#
# 这里补的是最窄的一层防线：读源码断言「调用还在」。它不验行为、只验接线没被剪断，
# 代价近零。真正的行为验证仍然靠上面那些纯函数用例。
function Test-SourceMatch([string]$file, [string]$pattern) {
    $p = Join-Path (Get-Location) $file
    if (-not (Test-Path -LiteralPath $p)) { return $false }
    return [bool]([regex]::IsMatch([System.IO.File]::ReadAllText($p), $pattern))
}
# 取出某个函数的函数体（按花括号配对，不靠行数窗口）。
# 用窗口会漏判：Confirm-CandidatePort 里有两个 Test-NodeAlive 调用，删掉其中一个，
# 另一个还在窗口内，断言照样过——而这正是"删掉一半接线"这类破坏的特征。
# 按花括号配对取到的是确切的函数体，"里面还剩几个调用"数得清。
function Get-FunctionBody([string]$file, [string]$name) {
    $p = Join-Path (Get-Location) $file
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    $src = [System.IO.File]::ReadAllText($p)
    $i = $src.IndexOf('function ' + $name)
    if ($i -lt 0) { return '' }
    $open = $src.IndexOf('{', $i)
    if ($open -lt 0) { return '' }
    $depth = 0
    for ($j = $open; $j -lt $src.Length; $j++) {
        if ($src[$j] -eq '{') { $depth++ }
        elseif ($src[$j] -eq '}') {
            $depth--
            if ($depth -eq 0) { return $src.Substring($open, $j - $open + 1) }
        }
    }
    return ''
}
function Test-BodyHas([string]$file, [string]$name, [string]$needle, [int]$min = 1) {
    $b = Get-FunctionBody $file $name
    if (-not $b) { return $false }
    return ([regex]::Matches($b, [regex]::Escape($needle))).Count -ge $min
}
# "先问后答"：函数体里必须先真的去问那个判据，再返回结论。
# 只查"函数体里出现过那个判据"不够——有人在函数第一行写 return $false，
# 判据还在下面、永远走不到，一样会让清理功能整个失效。
function Test-BodyAsksFirst([string]$file, [string]$name, [string]$needle) {
    $b = Get-FunctionBody $file $name
    if (-not $b) { return $false }
    $iAsk = $b.IndexOf($needle)
    if ($iAsk -lt 0) { return $false }
    # 函数体里所有"直接返回某个常量"的位置：只要有一个在询问之前，就不算先问后答。
    foreach ($m in [regex]::Matches($b, 'return\s+\$(false|true)\b')) {
        if ($m.Index -lt $iAsk) { return $false }
    }
    return $true
}

# 装配：入口最后一句必须是进入监控主循环（无参数 = 开机自启那条路）。
Assert-Eq '接线：入口会进入监控主循环' $true (Test-SourceMatch 'win/envproxy.ps1' '(?m)^Run-MonitorLoop\s*$')
# 装配：候选端口确认必须过"真实节点连通"这一层，不能只凭 CONNECT 握手就判 on。
# 两个分支（优先端口、其余端口）各要一次：删掉其中一个，另一个还在，照样能跑，
# 但"优先端口"那条路上就绕过了节点验证。
Assert-Eq '接线：候选确认会验证真实节点（两处分支）' $true (Test-BodyHas 'win/lib/probe.ps1' 'Confirm-CandidatePort' 'Test-NodeAlive' 2)
# 装配：清理门槛必须被真正调用（至少 apply-state 与监控自愈两处）。
$script:pvpHits = 0
foreach ($f in @('win/lib/env.ps1', 'win/lib/runtime.ps1')) {
    $p = Join-Path (Get-Location) $f
    $script:pvpHits += ([regex]::Matches([System.IO.File]::ReadAllText($p), 'Test-ProxyVarsPresent')).Count
}
# 定义本身算一次，所以两处调用点意味着至少 3 次命中。
Assert-Eq '接线：清理门槛被至少两处调用' $true ($script:pvpHits -ge 3)
# 装配：门槛本身必须真的去问归属记录，不能是恒假的空壳。
# "恒返回 $false"这一种破坏，光数调用点看不出来（调用还在，只是永远说不该清）。
Assert-Eq '接线：清理门槛会问归属记录' $true (Test-BodyHas 'win/lib/env.ps1' 'Test-ProxyVarsPresent' 'Test-IsOwnedProxyValue' 1)
# 还要"先问后答"：函数体里如果先 return $false 再说要问归属记录，那条询问永远走不到，
# 清理功能整个失效（变量再也删不掉，连卸载都清不干净）。
Assert-Eq '接线：清理门槛先问后答' $true (Test-BodyAsksFirst 'win/lib/env.ps1' 'Test-ProxyVarsPresent' 'Test-IsOwnedProxyValue')
# 装配：状态去抖必须比的是常量，不是字面量（改成 1 就等于去掉去抖，抖动即翻）。
Assert-Eq '接线：去抖比的是常量' $true (Test-SourceMatch 'win/lib/runtime.ps1' '\$pendingCount\s+-ge\s+\$StateDebounceRounds')
# 装配：覆盖安装走的必须是"临时文件 + 整体替换"，不是直接覆盖（断电留半截）。
# 机制是 .NET 的 File::Replace / File::Move（同目录临时文件 + 整体替换），
# 不是 Copy-Item —— 后者先截断再写，中途被杀就留半截文件。
Assert-Eq '接线：文件覆盖是原子替换' $true (Test-BodyHas 'win/lib/package.ps1' 'Copy-FileAtomic' 'File]::Replace(' 1)
# 装配：菜单壳里引用的脚本必须真的存在。
# 壳里写错一个文件名，用户双击就是"找不到文件"；而门禁 2 的正则只找
# "envproxy\.ps1 -<开关>"，名字一改就一条都不匹配——不是报错，是静默跳过。
$cmdSrc = [System.IO.File]::ReadAllText((Join-Path (Get-Location) 'win/打开菜单.cmd'))
# 先把 %~dp0 这类"脚本所在目录"前缀去掉再找文件名，否则 dp0envproxy.ps1 会被当成文件名。
$cmdSrc = [regex]::Replace($cmdSrc, '%~dp0', '')
$cmdRefs = @([regex]::Matches($cmdSrc, '([A-Za-z0-9_\-]+\.ps1)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$cmdMissing = @()
foreach ($r in $cmdRefs) {
    if (-not (Test-Path -LiteralPath (Join-Path (Get-Location) ('win/' + $r)))) { $cmdMissing += $r }
}
Assert-Eq '接线：菜单壳引用的脚本都存在' 0 $cmdMissing.Count
# 状态页必须只读：它在"查看状态"里被调用，写文件或改变量都是越界。
foreach ($fn in @('Show-Status')) {
    $p = Join-Path (Get-Location) 'win/lib/ops.ps1'
    $src = [System.IO.File]::ReadAllText($p)
    $i = $src.IndexOf('function ' + $fn)
    if ($i -ge 0) {
        $chunk = $src.Substring($i, [Math]::Min(9000, $src.Length - $i))
        Assert-Eq ('接线：' + $fn + ' 不写用户变量') $false ([bool]([regex]::IsMatch($chunk, 'SetEnvironmentVariable')))
    }
}

# 还原跑之前记下的环境（见文件开头那段守卫）：自检不该改变调用它的那个 shell 的状态。
foreach ($__n in $__savedProxy.Keys) { [Environment]::SetEnvironmentVariable($__n, $__savedProxy[$__n], 'Process') }
if ($null -ne $__savedTerm) { $env:ENVPROXY_TERM = $__savedTerm } else { Remove-Item Env:ENVPROXY_TERM -ErrorAction SilentlyContinue }

# 测试结束：删掉临时日志目录，并把 $LogFile 还原。
try {
    if ($script:TestLogDir -and (Test-Path -LiteralPath $script:TestLogDir)) {
        Remove-Item -LiteralPath $script:TestLogDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($script:SavedLogFile) { $LogFile = $script:SavedLogFile }
} catch {}

# 注册表沙箱：删掉临时键、把四个子键复原。
# 两件事都要做——只删键不够，因为 Get-*KeyPath 是现算的，
# 变量还指着沙箱时，后面任何清理都会打到沙箱而不是真实位置。
if ($env:OS -eq 'Windows_NT' -and $script:SavedRegSandbox) {
    try {
        foreach ($k in @($UserEnvSubKey, $OwnedRegSubKey, $PrevEnvSubKey, $ScriptPathRegSubKey)) {
            Remove-Item -LiteralPath (Get-RegPath $k) -Recurse -Force -ErrorAction SilentlyContinue
        }
        # 父键只在空了的时候删（它可能装着使用者的真实数据）
        if ((Test-Path 'HKCU:\Software\EnvProxy') -and
            -not (@(Get-ChildItem 'HKCU:\Software\EnvProxy' -ErrorAction SilentlyContinue).Count)) {
            Remove-Item 'HKCU:\Software\EnvProxy' -Recurse -Force -ErrorAction SilentlyContinue
        }
        $UserEnvSubKey       = $script:SavedRegSandbox.UserEnv
        $OwnedRegSubKey      = $script:SavedRegSandbox.Owned
        $PrevEnvSubKey       = $script:SavedRegSandbox.PrevEnv
        $ScriptPathRegSubKey = $script:SavedRegSandbox.ScriptPathReg
    } catch {}
}

if ($script:fails -eq 0) { Write-Host 'ALL PASS'; exit 0 }
Write-Host ("FAILURES: {0}" -f $script:fails); exit 1
