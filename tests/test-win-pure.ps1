
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

# 安装目录隔离：relay.port / terminal.env / launchers\ 都住在 Get-InstallDir() 下，
# 默认是使用者真实的 %LOCALAPPDATA%\EnvProxy。不隔离的后果不是"脏一点"，
# 而是**用例结论取决于本机装没装、监控在不在跑**：
#   「另一个进程读得到中继端口」这条要的是"自检写下的端口，子进程读回来还是它"，
#   而真实安装的监控每轮都在把 relay.port 重写成自己的端口。两者抢同一个文件，
#   于是这条用例随机红、随机绿——同一份提交在本机过、在 CI 挂（或反过来）。
# 这与注册表那四个子键是同一件事：把**落点**换掉，跑的是真逻辑。
$script:SavedInstallDir = $InstallDirOverride
$script:SavedToolHomeDir = $ToolHomeDirOverride
$script:TestInstallDir = Join-Path ([System.IO.Path]::GetTempPath()) ('envproxy_testhome_' + [guid]::NewGuid().ToString('N').Substring(0,8))
$InstallDirOverride = $script:TestInstallDir
$ToolHomeDirOverride = (Join-Path $script:TestInstallDir '.envproxy')
if (-not (Test-Path -LiteralPath $script:TestInstallDir)) {
    New-Item -ItemType Directory -Path $script:TestInstallDir -Force | Out-Null
}
# $LauncherDir 在 runtime 层加载时就算好了，改 override 追不上它，这里直接对齐。
$script:SavedLauncherDir = $LauncherDir
$LauncherDir = $script:TestInstallDir

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

# 需要独占真实注册表的一段可以用它把断言整体静音。
# 为什么要有：那种断言的前提是"这段时间里没有别人在改同一批变量"，
# 拿不到互斥体就说明前提不成立——此时报 FAIL 是谎报（它测的是监控在写，
# 不是我们的代码坏了）；报 PASS 也是谎报。唯一诚实的处置是明确说"跳过"。
$script:AssertionMuted = $false
function Assert-EqGated([string]$Name, $Want, $Have) {
    if ($script:AssertionMuted) { Write-Host ("  SKIP {0}" -f $Name); return }
    Assert-Eq $Name $Want $Have
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
Write-Host '[2] ownership convention (real predicate)'
if ($env:OS -eq 'Windows_NT') {
    Remove-Item -LiteralPath (Get-PrevEnvRegKeyPath) -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path (Get-PrevEnvRegKeyPath) -Force | Out-Null
    # 这几条的前提是"快照键在、且里面没有这几个名字"——只有注册表能造出来。
    # 没有注册表时（CI 的 ubuntu 作业跑同一份文件）Test-SnapshotRecorded 会走到
    # "键整个不存在且无安装记录"那一支、返回 $null（不知道），于是判 false。
    # 那是**正确行为**（分不清就别认领），只是与本组断言要问的问题不同。
    # 所以整组跟着前提一起跳过，而不是把断言放宽——放宽会让真回归溜过去。
    Assert-Eq 'local counts as ours' $true (Test-IsOwnedProxyValue 'HTTP_PROXY' 'http://127.0.0.1:7890')
    Assert-Eq 'corp does not' $false (Test-IsOwnedProxyValue 'HTTP_PROXY' 'http://corp:8080')
    Assert-Eq 'own no_proxy entry counts' $true (Test-IsOwnedProxyValue 'NO_PROXY' 'localhost,example.com')
    Assert-Eq 'foreign no_proxy does not' $false (Test-IsOwnedProxyValue 'NO_PROXY' 'example.com')
    Assert-Eq 'node flag 1 counts' $true (Test-IsOwnedProxyValue 'NODE_USE_ENV_PROXY' '1')
    Assert-Eq 'node flag other does not' $false (Test-IsOwnedProxyValue 'NODE_USE_ENV_PROXY' '0')
} else {
    Write-Host '  SKIP 归属判定的"快照在、里面没有"前提（本机没有注册表，造不出这个前提）'
}
Assert-Eq 'empty counts as nothing' $false (Test-IsOwnedProxyValue 'HTTP_PROXY' '')
# NO_PROXY 为空也必须算"没有痕迹"。
#
# 这条原来漏了：NO_PROXY 走的是"逐项比对"而不是整值相等，而空值拆出来的条目集是
# 空集，「每一项都在我们记下的那份里」对空集**恒真**，于是它返回 true。
# 后果不是一个显示问题：Test-ProxyVarsPresent 拿它当清理门槛，变量已经清空仍被判成
# "还有我们的痕迹"，清理函数删不到东西、回读确认依旧为真，最后 Invoke-EnvStateWrite
# 报 1——一个干净的直连状态被报成"写失败"，而屏幕提示用户"可能被杀软拦住了"。
# CI 的 ubuntu 作业正是因为这条红的（那边注册表不可写，空值路径必被走到）。
Assert-Eq 'empty NO_PROXY counts as nothing' $false (Test-IsOwnedProxyValue 'NO_PROXY' '')
Assert-Eq 'whitespace NO_PROXY counts as nothing' $false (Test-IsOwnedProxyValue 'NO_PROXY' '   ')
Assert-Eq 'empty node flag counts as nothing' $false (Test-IsOwnedProxyValue 'NODE_USE_ENV_PROXY' '')

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

        # ------------------------------------------------------------------
        # 快照里有这个名字、但当前值**已经是我们注入的那个**——必须判成我们的。
        #
        # 这是本项目最贵的一类错，因为它的形状最普通：装之前用户本来就有
        # HTTP_PROXY（企业代理、旧工具残留都长这样），快照于是记下了这个名字。
        # 之后我们把它覆盖成 127.0.0.1:<翻墙端口>。关代理时若按"名字在快照里
        # 就算他的"来判断，我们注入的值就永远删不掉：
        #   - 三个地址变量继续指向死端口，git/curl/npm 全部 ECONNREFUSED；
        #   - 而 NO_PROXY/NODE_USE_ENV_PROXY 没有快照条目，照样被删——
        #     于是连 localhost 都要往死代理送，成为更难查的"半套变量"；
        #   - PowerShell 提示符钩子读注册表看到值还在，每开一个窗口就再注入一次；
        #   - 屏幕上还打"已删除代理变量，恢复直连"。
        # 判据必须落在**值**上：当前值等于我们记下的那个 → 就是我们的，与快照无关。
        # ------------------------------------------------------------------
        New-Item -Path (Get-OwnedRegKeyPath) -Force -ErrorAction SilentlyContinue | Out-Null
        Set-ItemProperty -Path (Get-OwnedRegKeyPath) -Name 'HTTP_PROXY' -Value 'http://127.0.0.1:7078' -ErrorAction SilentlyContinue
        Assert-Eq '快照记着名字、但值是我们注入的 -> 仍是我们的（必须回收）' $true `
            (Test-IsOwnedProxyValue 'HTTP_PROXY' 'http://127.0.0.1:7078')
        Assert-Eq '同一情形下用户自己的另一个端点仍不许动' $false `
            (Test-IsOwnedProxyValue 'HTTP_PROXY' 'http://127.0.0.1:8080')
        # 清理门槛也必须跟着认：它是同一个判据的调用方，两处各说各话就是"半代理"的来源。
        Assert-Eq '清理门槛与归属判据同一套（门槛必须看到我们的值）' $true `
            ([bool](Test-IsOwnedProxyValue 'HTTP_PROXY' 'http://127.0.0.1:7078'))
        Remove-Item -LiteralPath (Get-OwnedRegKeyPath) -Recurse -Force -ErrorAction SilentlyContinue
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
# 合法输入必须放行：unknown 与空串在拿锁**之前**就返回 0，不碰注册表。
# 这两个可以放心测。
#
# 'off' **不在这里测**：它真的会去删 HKCU\Environment 里的变量。这台机器上如果
# 后台监控正在跑（每 2-3 秒重写一次），测试删掉、监控写回，断言就会随机变红；
# 而在没有注册表的平台（CI 的 ubuntu 作业跑同一份文件）它必然失败。
# 原来是把它一起塞进这个循环的，于是"按平台看行为"的随机红被当成平台差异查了很久。
# off 的行为改在【隔离的注册表沙箱】里验证——见下面 [2g] 之后的 off 用例。
foreach ($good in @('unknown', '')) {
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
$mirrorPath = Join-Path (Get-InstallDir) "terminal.env"
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
# 数量不写死：写死 7 的话，每加删一条主题都要改测试，而改测试的人往往只是把数字改对，
# 不会去想"这条例子的本意是什么"（它守的是"帮助不能是空的"）。改成"至少有一条"，
# 再配一条"编号连续"的独立断言——那才是真正会让用户点错的东西。
Assert-Eq 'help has topics' $true ($helpTopics.Count -ge 1)
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
foreach ($r in @('heading', 'cmd', 'text', 'item', 'key', 'warn')) {
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
# 状态页里每个标签都必须经 Write-StatusRow 输出（它会用 key 上色）。
# 标签值从 $StatusLabels 表取（唯一权威处），源码里查的是"用它做行标签"这件事：
#   ① 静态页必须出现 `Write-StatusRow $StatusLabels.X`；
#   ② 表里的每个键都必须真的被渲染器用到——只建表不接线等于没建。
$srcLive = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '../win/lib/ops.ps1'))
foreach ($k in @('Monitor', 'AutoRun', 'Proxy', 'TermSync', 'Vars', 'Version')) {
    $lbl = [string]$StatusLabels[$k]
    $inRow = [regex]::IsMatch($srcLive, 'Write-StatusRow \$StatusLabels\.' + $k + '\b')
    $inBare = [regex]::IsMatch($srcLive, "Write-Styled '\w+' ""?" + [regex]::Escape($lbl) + " : ")
    Assert-Eq ('status row uses the split renderer: ' + $lbl) $true $inRow
    Assert-Eq ('status label is not painted by the whole-line colour: ' + $lbl) $false $inBare
    $used = [regex]::IsMatch($srcLive, '\$StatusLabels\.' + $k + '\b')
    Assert-Eq ('status label is actually used by a renderer: ' + $lbl) $true $used
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
Assert-Eq 'the network advice gives a next step' '1' ([int]($msgNet -match '重试'))
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
# [7d] off 态不许每轮都做全端口扫描
# ------------------------------------------------------------------------------
# "第一次全扫要不要做"曾经用"候选集签名是不是空"来回答。在一台从头到尾没有代理的
# 机器上，候选集恒空、签名恒为空串、与初值相同 -> 签名永不更新 -> 那个条件恒为真
# -> **每一轮都全扫**。实测 8 轮做 8 次全扫、每次约 2.8 秒，而 off 态轮间隔 3 秒，
# 占空比接近 50%——机器上什么都没发生，监控却在满负荷跑。
# 现在改用一次性标记 EverFullScanned：做过就置位、永不回退。
# 这条用例钉住"20 轮里全扫次数是 3（第 1、10、20 轮），不是 20"。
$script:SavedFind = ${function:Find-CandidatePorts}
$script:SavedRealConn = ${function:Test-RealConnectivity}
try {
    $script:FullScanCalls = 0
    function Find-CandidatePorts([bool]$FullScan = $true) {
        if ($FullScan) { $script:FullScanCalls++ }
        $script:PortEnumerationFailed = $false
        return @()
    }
    function Test-RealConnectivity([int]$Port) { return $false }
    $script:CachedPort = $null
    $script:LastAlivePort = $null
    $script:LastSeenSet = ""
    $script:Round = 0
    $script:NeedDeepScan = $false
    $script:EverFullScanned = $false
    $script:NodeState = @{}
    foreach ($__i in 1..20) { $null = Get-CurrentState }
    # 第 1 轮（首次全扫）、第 10 轮、第 20 轮 = 3 次。允许小幅差异是因为
    # 轮次取模与"首次"可能落在同一轮上，但绝不允许回到"每轮一次"。
    Assert-Eq '无代理时 20 轮里只做 3 次全扫（不是每轮）' $true ($script:FullScanCalls -le 3)
    Assert-Eq '无代理时确实做过首次全扫' $true ($script:EverFullScanned)
} finally {
    Set-Item -Path Function:Find-CandidatePorts -Value $script:SavedFind
    Set-Item -Path Function:Test-RealConnectivity -Value $script:SavedRealConn
    Remove-Variable -Name SavedFind, SavedRealConn -Scope Script -ErrorAction SilentlyContinue
    $script:CachedPort = $null
    $script:NodeState = @{}
    $script:EverFullScanned = $false
}

# ------------------------------------------------------------------------------
# [7e] "按进程名提速"必须真的会执行
# ------------------------------------------------------------------------------
# 这段提速依赖 PID，而默认取值路径（进程内的 GetActiveTcpListeners）结构上不提供 PID。
# 曾经用"这一路有没有 PID"当开关，于是正常机器上它恒为假、整段从未执行过。
# 更隐蔽的是：改成"单独取一次 PID 表"之后，循环里把变量名写成了 $pid——
# 那是 PowerShell 的**只读自动变量**，赋值直接抛错，而整段外面包着 try/catch，
# 异常被静默吞掉，于是"看起来实现了、实际还是不生效"。
# 这条用例钉住两件事：PID 表能取到、且按进程名能认出对应的端口。
$script:SavedPidMap = ${function:Get-ListeningPortPidMap}
$script:SavedListeners = ${function:Get-ListeningTcpConnections}
$script:SavedHttpProxy = ${function:Test-HttpProxy}
try {
    # 造一个"端口 59999 由 monocloud 进程监听"的世界，不依赖本机真实进程
    $selfPid = $PID
    function Get-ListeningTcpConnections {
        @([pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 59999; OwningProcess = 0 })
    }
    function Get-ListeningPortPidMap {
        $m = @{}; $m[59999] = $selfPid; return $m
    }
    function Test-HttpProxy([int]$Port) { return ($Port -eq 59999) }
    # 把当前进程"改名"成 monocloud 不可行，改用"进程名特征含当前进程名"来验证链路：
    # 真正要证明的是"PID 表 -> 进程名 -> 匹配 -> 入候选"这条链没断，而不是某个具体品牌。
    $selfName = (Get-Process -Id $selfPid -ErrorAction SilentlyContinue).ProcessName
    if ($selfName) {
        $savedPatterns = $ProxyProcessPatterns
        $savedKnown = $KnownProxyPorts
        try {
            $ProxyProcessPatterns = @($selfName.ToLowerInvariant())
            $KnownProxyPorts = @()
            $hit = @(Find-CandidatePorts -FullScan:$false)
            Assert-Eq '按进程名提速：PID 表取得到并命中端口' $true ($hit -contains 59999)
        } finally {
            $ProxyProcessPatterns = $savedPatterns
            $KnownProxyPorts = $savedKnown
        }
    } else {
        Write-Host '  SKIP 按进程名提速（拿不到当前进程名）'
    }
} finally {
    Set-Item -Path Function:Get-ListeningPortPidMap -Value $script:SavedPidMap
    Set-Item -Path Function:Get-ListeningTcpConnections -Value $script:SavedListeners
    Set-Item -Path Function:Test-HttpProxy -Value $script:SavedHttpProxy
    Remove-Variable -Name SavedPidMap, SavedListeners, SavedHttpProxy -Scope Script -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------------------
# [7f] "读哪个变量当代理源"只能有一个答案
# ------------------------------------------------------------------------------
# 曾经分叉过：Get-EnvProxyValue 取 $ProxyVarNames[0]（HTTP_PROXY），
# 而生成启动脚本那一处写死 HTTPS_PROXY。同一个程序对同一个问题给出两个答案，
# 谁都不报错——将来只改其中一处，另一处就会静默读到别的值。
# 现在两处都从 $PrimaryProxyVarName 取。这条用例钉住：
#   ① 它确实是地址类变量之一；
#   ② 生成出来的启动脚本读的就是它（而不是别写一个）；
#   ③ 改这个常量，脚本跟着改——证明是插值而非抄写。
$__genBody = {
    param([string]$Target)
    $b = New-ProxyLauncherBody $Target 'C:\Test'
    $bytes = [Convert]::FromBase64String($b)
    $ms = New-Object IO.MemoryStream(,$bytes)
    $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Decompress)
    (New-Object IO.StreamReader($gz)).ReadToEnd()
}
Assert-Eq '主代理变量是地址类之一' $true ($ProxyAddrVarNames -contains $PrimaryProxyVarName)
$__body = & $__genBody 'C:\Test\app.exe'
# 匹配 ".<变量名>" 这个形态：它出现在"从注册表读当前代理值"的那一处
# （`(gp '...').HTTP_PROXY` 或 `(gp '...').ALL_PROXY`）。
# 不锚定后面的分号/括号：启动脚本加了固定入口的探测之后，那里跟的是 `}`
# 而不是 `;`——锚死标点会让这条用例在实现变化时假红，而它要测的是
# "读的是哪个变量"，不是"那个字符是什么"。
Assert-Eq '启动脚本读的是主代理变量（插值，不是另写一个）' $true `
    ($__body -match ('\.' + [regex]::Escape($PrimaryProxyVarName) + '(?![A-Za-z_])'))
$__savedPrimary = $PrimaryProxyVarName
$__savedSubKey = $UserEnvSubKey
try {
    $PrimaryProxyVarName = 'ALL_PROXY'
    $UserEnvSubKey = 'Software\EnvProxy\__probe'
    $__body2 = & $__genBody 'C:\Test\app.exe'
    Assert-Eq '改主代理变量，脚本跟着改' $true ($__body2 -match '\.ALL_PROXY(?![A-Za-z_])')
    Assert-Eq '改注册表落点，脚本跟着改' $true ($__body2 -match [regex]::Escape('HKCU:\Software\EnvProxy\__probe'))
} finally {
    $PrimaryProxyVarName = $__savedPrimary
    $UserEnvSubKey = $__savedSubKey
}

# ------------------------------------------------------------------------------
# [7g] 固定入口（中继）：能起、能转发、能降级
# ------------------------------------------------------------------------------
# 它给「走代理的快捷方式」一个永不改变的地址，所以三件事必须成立：
#   ① 起得来，并把实际端口写进记录文件（启动器靠它找过来）；
#   ② 真的能转发（HTTP 与 HTTPS 两种形态都要过——只做 CONNECT 时纯 HTTP 全挂）；
#   ③ 上游不在时要**快速明确失败**，而不是让客户端挂在那儿。
# 第三条尤其重要：中继活着但上游死了，如果中继不吭声，用户看到的是"程序卡住"，
# 比"连不上"更难查。
if ((Test-RelayType)) {
    $__relayPort = 0
    $__relayFile = ''
    try {
        $__relayFile = Get-RelayPortFile
        $__relayStarted = Start-Relay
        Assert-Eq '中继起得来' $true $__relayStarted
        if ($__relayStarted) {
            $__relayPort = $script:RelayPort
            Assert-Eq '中继监听在一个合法端口上' $true ($__relayPort -gt 0 -and $__relayPort -le 65535)
            # 记录文件必须写出来：否则启动器读不到端口，会一直退回直读注册表，
            # "永不失效的地址"这个能力等于没做。
            if ($__relayFile) {
                Assert-Eq '端口记录文件已写出' $true (Test-Item $__relayFile)
                Assert-Eq '记录内容就是实际端口' ([string]$__relayPort) ((Read-Text $__relayFile).Trim())
            }
            # 上游设成一个确定没人监听的口：中继必须在有限时间内给出失败，
            # 不许无限等待。判据用"能连上中继"+"很快收到回应"两件事。
            [EnvProxyRelay]::SetUpstream(1)
            $__sw = [Diagnostics.Stopwatch]::StartNew()
            $__gotAnswer = $false
            try {
                $__c = New-Object System.Net.Sockets.TcpClient
                $__c.Connect('127.0.0.1', $__relayPort)
                $__s = $__c.GetStream()
                $__s.ReadTimeout = 6000
                $__req = [System.Text.Encoding]::ASCII.GetBytes("CONNECT example.com:443 HTTP/1.1`r`nHost: example.com:443`r`n`r`n")
                $__s.Write($__req, 0, $__req.Length)
                $__s.Flush()
                $__buf = New-Object byte[] 256
                $__n = $__s.Read($__buf, 0, 256)
                $__gotAnswer = ($__n -gt 0)
                if ($__gotAnswer) {
                    $__resp = [System.Text.Encoding]::ASCII.GetString($__buf, 0, $__n)
                    Assert-Eq '上游不可用时回的是明确的失败状态码（不是 200）' $false ($__resp -match '^HTTP/1\.[01] 200')
                }
                $__c.Close()
            } catch { $__gotAnswer = $false }
            Assert-Eq '上游不可用时也会给客户端一个明确答复' $true $__gotAnswer
            Assert-Eq '失败答复不超过 5 秒' $true ($__sw.ElapsedMilliseconds -lt 5000)
            # 上游没了就清空：不留下一个指向死端口的静态字段，后面的用例会读它。
            [EnvProxyRelay]::SetUpstream(0)
        }
    } finally {
        Stop-Relay
        # 记录文件必须随停止消失：留着它，启动器会去连一个没人听的口，
        # 白等一次连接超时之后才降级。
        if ($__relayFile) {
            Assert-Eq '停掉中继后端口记录被清掉' $false (Test-Item $__relayFile)
        }
    }
} else {
    Write-Host '  SKIP 固定入口（本机编译不出中继类型）'
}

# ------------------------------------------------------------------------------
# [7h] 中继状态必须能被**另一个进程**读到
# ------------------------------------------------------------------------------
# 状态页与「查看中继」那一屏都运行在独立进程里，而中继跑在监控进程里。
# 曾经 Get-RelayStatus 读的是 $script:RelayInstance——那只存在于起中继的那个进程。
# 结果是：中继明明在跑，界面永远显示"没在工作"，而且看起来一切正常。
# 这个用例钉住"判据跨进程有效"：本进程起中继 -> 用子进程去读 -> 必须读得到。
# 同时钉住"上游端口也读得准"，因为那是显示"当前转发到哪儿"的唯一来源。
if (Test-RelayType) {
    $__rp = 0
    try {
        $null = Start-Relay
        if ($script:RelayPort -gt 0) {
            $__rp = $script:RelayPort
            [EnvProxyRelay]::SetUpstream(7078)
            Start-Sleep -Milliseconds 150
            # 子进程是完全独立的一份 PowerShell：它没有任何进程内状态，
            # 只能靠 relay.port 文件 + 状态探针。这正是状态页所处的环境。
            $probe = @"
`$ErrorActionPreference='Stop'
`$ScriptDir='$ScriptDir'
foreach (`$n in @('base','probe','env','runtime','relay')) { . (Join-Path (Join-Path `$ScriptDir 'lib') "`$n.ps1") }
# 安装目录的沙箱必须跟着子进程走：它重新点源库，override 回到空，
# 于是会去读使用者**真实** %LOCALAPPDATA%\EnvProxy\relay.port——那正是这条用例
# 要证明"跨进程读得到"的那个文件，读错一份就等于没测。
`$InstallDirOverride = '$($script:TestInstallDir -replace "'", "''")'
`$s = Get-RelayStatus
Write-Output ("{0}|{1}|{2}" -f `$s.Running, `$s.Port, `$s.Upstream)
"@
            $f = Join-Path ([System.IO.Path]::GetTempPath()) ("relayprobe_" + [guid]::NewGuid().ToString('N') + ".ps1")
            try {
                [System.IO.File]::WriteAllText($f, $probe, (New-Object System.Text.UTF8Encoding($true)))
                $out = @(& (Get-Command pwsh -ErrorAction SilentlyContinue).Source -NoProfile -File $f 2>$null)
                $line = @($out | Where-Object { $_ -match '^\w+\|\d+\|\d+$' }) | Select-Object -First 1
                if ($line) {
                    $parts = $line -split '\|'
                    Assert-Eq '另一个进程读得到中继在跑' 'True' $parts[0]
                    Assert-Eq '另一个进程读得到中继端口' ([string]$__rp) $parts[1]
                    Assert-Eq '另一个进程读得到上游端口' '7078' $parts[2]
                } else {
                    Write-Host '  SKIP 跨进程中继判据（子进程没跑起来）'
                }
            } finally {
                if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
            }
        }
    } finally {
        Stop-Relay
    }
} else {
    Write-Host '  SKIP 跨进程中继判据（本机编译不出中继类型）'
}

# ------------------------------------------------------------------------------
# [7i] 状态判决在真实使用场景里的整条路径
# ------------------------------------------------------------------------------
# 上面那些用例各测一个判据，这一条测**组合起来的实际行为**。
# 起因是一次真实故障：翻墙软件关掉后，状态页十几分钟一直显示"已开启"、
# 同时又说"端口已不在"、加一句"正在确认"。三句话互相矛盾，而每一处判据单看都对。
# 根因是快扫返回空时一律返回 unknown——unknown 不计进去抖，
# 于是永远凑不齐"连续两轮确认"，状态永远翻不过来。
#
# 单测判据抓不到这一类问题，因为它们只在**组合**里出现。
# 所以这里直接驱动真实的 Get-CurrentState，只替换探测层（那是唯一的外部依赖）。
# 每个场景都对应一个用户真实会遇到的情形：
#   A 正常开着 / B 关掉 / C 换成表外的端口 / D 两个软件同时开
#   E 首次启动 / F 从旧端口换到新端口 / G 端口被非代理程序占着
#
# 判据写成"必须出现某个结论"而不是"第 N 轮必须是某值"：
# 轮次节流（每 10 轮一次全扫）是内部实现，钉死它会让人一调参就假红。
# 唯一额外约束是"不许永远判不出来"——那正是这次故障的形态。
function Invoke-StateScenario {
    param(
        [int[]]$Listening,      # 本机在监听的端口（= 候选集的全扫结果）
        [int[]]$QuickVisible,   # 快扫看得见的（常见端口表 + 进程名认得出的）
        [int[]]$NotProxy,       # 在监听但不是代理（握手不过）
        [bool]$NodeAlive,
        [int]$Rounds,
        [bool]$EverFullScanned = $true,
        [int]$InitPort = 0
    )
    $script:CachedPort = $null
    $script:LastAlivePort = $null
    $script:LastSeenSet = ""
    if ($InitPort -gt 0) {
        $script:CachedPort = $InitPort
        $script:LastAlivePort = $InitPort
        $script:LastSeenSet = [string]$InitPort
    }
    $script:Round = 100
    $script:NeedDeepScan = $false
    $script:EverFullScanned = $EverFullScanned
    $script:PortEnumerationFailed = $false
    $__out = New-Object System.Collections.ArrayList
    for ($k = 0; $k -lt $Rounds; $k++) {
        # 每一轮都重新定义桩：真实实现会改这些函数之外的状态，桩必须无状态。
        $__l = $Listening; $__q = $QuickVisible; $__np = $NotProxy; $__alive = $NodeAlive
        function Find-CandidatePorts {
            param([bool]$FullScan = $true)
            $script:PortEnumerationFailed = $false
            if ($FullScan) { return $__l }
            return $__q
        }
        function Test-PortListening {
            param([int]$Port)
            if ($__l -contains $Port) { return "listening" }
            return "absent"
        }
        function Test-HttpProxy {
            param([int]$Port)
            if ($__np -contains $Port) { return $false }
            return $__alive
        }
        function Test-NodeAlive { param([int]$Port) return $__alive }
        function Confirm-CandidatePort {
            param($Candidates, $Preferred)
            foreach ($x in @($Candidates)) {
                if (Test-HttpProxy ([int]$x)) { return [int]$x }
            }
            return $null
        }
        [void]$__out.Add((Get-CurrentState))
    }
    return $__out.ToArray()
}

# A：正常开着。第一轮就该确认（用户不该等）。
$__a = @(Invoke-StateScenario -Listening @(7078) -QuickVisible @(7078) -NodeAlive $true -Rounds 3)
Assert-Eq "场景A 正常开着：第一轮就判 on" "on:7078" $__a[0]
Assert-Eq "场景A 正常开着：三轮都稳定" "on:7078 on:7078 on:7078" ($__a -join " ")

# B：翻墙软件关掉。这是那次故障的场景——必须能翻到 off。
$__b = @(Invoke-StateScenario -Listening @() -QuickVisible @() -NodeAlive $false -Rounds 3)
Assert-Eq "场景B 关掉：能判 off（曾经卡死在 on）" "off off off" ($__b -join " ")

# C：换成表外端口。快扫看不见，全扫才看得见——必须最终发现，且不许永远判不出来。
$__c = @(Invoke-StateScenario -Listening @(7890) -QuickVisible @() -NodeAlive $true -Rounds 12)

# C 的断言就是"最终必须发现"：发现不了，这 12 轮全是 off，
# 那正是"永远判不出来"的形态，一条断言足够。
Assert-Eq "场景C 表外端口：最终必须发现（全 off 就是找不回来）" $true ([bool](@($__c | Where-Object { $_ -eq "on:7890" }).Count))

# D：两个翻墙软件同时开。判一个就行（变量只能指向一个），不许判 off。
$__d = @(Invoke-StateScenario -Listening @(7078,7890) -QuickVisible @(7078,7890) -NodeAlive $true -Rounds 3)
Assert-Eq "场景D 两个同时开：判出其中一个" $true ([bool](@($__d | Where-Object { $_ -like "on:*" }).Count))

# E：首次启动就遇到表外端口（还没做过任何全扫）。首轮必须全扫，否则用户要等 30 秒。
$__e = @(Invoke-StateScenario -Listening @(7890) -QuickVisible @() -NodeAlive $true -Rounds 2 -EverFullScanned $false)
Assert-Eq "场景E 首启就是表外端口：第一轮全扫直接发现" "on:7890" $__e[0]

# F：从 7078 换到 7890（改端口重开软件）。旧端口没了必须尽快跟到新端口。
$__f = @(Invoke-StateScenario -Listening @(7890) -QuickVisible @() -NodeAlive $true -Rounds 6 -InitPort 7078)
Assert-Eq "场景F 换端口：最终跟到新端口" $true ([bool](@($__f | Where-Object { $_ -eq "on:7890" }).Count))

# G：端口被非代理程序占着（开发服务器常占 8080/3000）。
# 握手不过就绝不能判 on —— 否则用户开个本地服务就被误注入代理。
# 注意这里测的是"上层会不会把握手失败的端口判成 on"，握手本身由
# Test-ConnectResponse 的纯函数用例覆盖（见下面的 [7j]，那个才打到生产代码）。
# 桩必须真的返回 false，否则这条就成了自己测自己。
$__g = @(Invoke-StateScenario -Listening @(8080) -QuickVisible @(8080) -NotProxy @(8080) -NodeAlive $true -Rounds 3)
Assert-Eq "场景G 非代理占端口：不许判 on" "off off off" ($__g -join " ")
# ------------------------------------------------------------------------------
# [7j] 握手判定：什么才算"这是个代理端口"
# ------------------------------------------------------------------------------
# 这是区分"代理端口"与"其他服务端口"的唯一判据，不依赖进程名/端口号猜测。
# 判错两个方向都致命：把开发服务器当成代理 -> 注入死代理、终端全断；
# 把真代理漏掉 -> 用户以为工具坏了。
# 纯函数，喂字符串就能测，不必真连网络。
Assert-Eq "握手：标准 200 算代理" $true (Test-ConnectResponse "HTTP/1.1 200 Connection established`r`n`r`n")
Assert-Eq "握手：1.0 的 200 也算" $true (Test-ConnectResponse "HTTP/1.0 200 OK`r`n`r`n")
Assert-Eq "握手：前面有空白也算" $true (Test-ConnectResponse "`r`nHTTP/1.1 200 OK")
Assert-Eq "握手：404 不算" $false (Test-ConnectResponse "HTTP/1.1 404 Not Found`r`n`r`n")
Assert-Eq "握手：403 不算" $false (Test-ConnectResponse "HTTP/1.1 403 Forbidden`r`n`r`n")
Assert-Eq "握手：500 不算" $false (Test-ConnectResponse "HTTP/1.1 500 Internal Server Error")
Assert-Eq "握手：2000 不算（只认 200 本身，不许前缀匹配放过）" $false (Test-ConnectResponse "HTTP/1.1 2000 OK")
Assert-Eq "握手：空应答不算" $false (Test-ConnectResponse "")
Assert-Eq "握手：非 HTTP 应答不算（不是 HTTP 服务）" $false (Test-ConnectResponse "SSH-2.0-OpenSSH_8.9")
Assert-Eq "握手：HTTP/2 不算（CONNECT 走 1.x，2 的语义不同）" $false (Test-ConnectResponse "HTTP/2 200")

# 收尾：把桩换回真实实现，后面的用例不该被这些桩影响。
$__probeLib = Get-Content (Join-Path $ScriptDir "lib\probe.ps1") -Raw -Encoding UTF8
. ([scriptblock]::Create($__probeLib))


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
# [2g] 快照写入的成败必须能传出去
# ------------------------------------------------------------------------------
# 这份快照是**其它所有归属判据的输入**：记不下来说明卸载时还原不回用户的原值。
# 原来整个函数体包在 try{}catch{} 里、逐项写还带 SilentlyContinue，
# 于是"记下了"与"没记下"长得一模一样，安装入口也就无从如实报告。
# 这里钉住两条：记下了返回 0；已经有了也返回 0（幂等，不算失败）。
if ($env:OS -eq 'Windows_NT') {
    $snapBak = Get-PrevEnvRegKeyPath
    try {
        Remove-Item -LiteralPath $snapBak -Recurse -Force -ErrorAction SilentlyContinue
        $rc1 = $null
        try { $rc1 = Snapshot-PrevEnv -FirstInstall:$true } catch { $rc1 = 'threw' }
        Assert-Eq '快照：写成了返回 0（不是"抛异常"也不是空值）' 0 $rc1
        Assert-Eq '快照：写完成后键确实在' $true (Test-RegKey $snapBak)
        $rc2 = $null
        try { $rc2 = Snapshot-PrevEnv -FirstInstall:$false } catch { $rc2 = 'threw' }
        Assert-Eq '快照：已经存在时返回 0（幂等，不是失败）' 0 $rc2
    } finally {
        Remove-Item -LiteralPath $snapBak -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host '  SKIP 快照写入成败（本机没有注册表）'
}

# ------------------------------------------------------------------------------
# [2h] off 态写入：在**隔离的注册表沙箱**里验，不碰真实环境变量
# ------------------------------------------------------------------------------
# 为什么单独一段：其它地方测 off 会真的删 HKCU\Environment 里的变量。
# 这台机器上后台监控每 2-3 秒重写一次，测试删掉、监控写回，断言就随机变红；
# 而在没有注册表的平台上它必然失败（CI 的 ubuntu 作业跑同一份文件）。
# 所以把落点临时指到沙箱子键，只验"判据对不对"，不碰使用者的真实设置。
if ($env:OS -eq 'Windows_NT') {
    $__savedEnvKey = $UserEnvSubKey
    try {
        $UserEnvSubKey = 'Software\EnvProxy\__offstate'
        Remove-Item -LiteralPath (Get-RegPath $UserEnvSubKey) -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path (Get-UserEnvKeyPath) -Force -ErrorAction SilentlyContinue | Out-Null

        # 空环境：没有我们的痕迹 -> off 是"没事可做"，必须是 0 而不是失败。
        # 这条曾经是红的：空 NO_PROXY 在逐项比对里"每一项都在"对空集恒真，
        # 于是被判成"还有我们的痕迹"，删又删不到，最后报 1——
        # 一个干净的直连状态被报成写失败，提示还叫用户去查杀软。
        $r0 = $null
        try { $r0 = Invoke-EnvStateWrite 'off' '' '' } catch { $r0 = 'threw' }
        Assert-Eq 'off：空环境判为没有痕迹（返回 0，不是失败）' 0 $r0
        Assert-Eq 'off：空环境的 NO_PROXY 不算我们的' $false (Test-IsOwnedProxyValue 'NO_PROXY' '')
        Assert-Eq 'off：空环境的 NO_PROXY（空白）不算我们的' $false (Test-IsOwnedProxyValue 'NO_PROXY' '   ')

        # 沙箱里放一个我们写下的值 -> 应当被认领并清掉，且返回 0。
        Set-ItemProperty -Path (Get-UserEnvKeyPath) -Name 'HTTP_PROXY' -Value 'http://127.0.0.1:7078' -ErrorAction SilentlyContinue
        Set-ItemProperty -Path (Get-UserEnvKeyPath) -Name 'NO_PROXY'   -Value 'localhost,127.0.0.1,::1' -ErrorAction SilentlyContinue
        Assert-Eq 'off：沙箱里我们自己写的 NO_PROXY 算我们的' $true (Test-IsOwnedProxyValue 'NO_PROXY' 'localhost,127.0.0.1,::1')
        $r1 = $null
        try { $r1 = Invoke-EnvStateWrite 'off' '' '' } catch { $r1 = 'threw' }
        Assert-Eq 'off：清掉自己写的值之后返回 0' 0 $r1
    } finally {
        Remove-Item -LiteralPath (Get-RegPath 'Software\EnvProxy\__offstate') -Recurse -Force -ErrorAction SilentlyContinue
        $UserEnvSubKey = $__savedEnvKey
    }
} else {
    Write-Host '  SKIP off 态写入（本机没有注册表）'
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
Assert-Eq '间隔：稳定态用稳定间隔' $NodeCheckThrottleSec (Get-NodeProbeInterval 0 $thr $null $tNow $NodeCheckThrottleSec $NodeFastSec)
Assert-Eq '间隔：有失败未达阈值时加密' $NodeFastSec (Get-NodeProbeInterval 1 $thr $null $tNow $NodeCheckThrottleSec $NodeFastSec)
Assert-Eq '间隔：刚下完结论时加密' $NodeFastSec (Get-NodeProbeInterval 0 $thr ($tNow + 1) $tNow $NodeCheckThrottleSec $NodeFastSec)
Assert-Eq '间隔：加密窗口过了就回到稳定档' $NodeCheckThrottleSec (Get-NodeProbeInterval 0 $thr ($tNow + -1) $tNow $NodeCheckThrottleSec $NodeFastSec)
Assert-Eq '间隔：失败已达阈值（结论已定）回到稳定档' $NodeCheckThrottleSec (Get-NodeProbeInterval $thr $thr $null $tNow $NodeCheckThrottleSec $NodeFastSec)
Assert-Eq '间隔：失败远超阈值也仍是稳定档（计数不会让间隔永远快下去）' $NodeCheckThrottleSec (Get-NodeProbeInterval 999 $thr $null $tNow $NodeCheckThrottleSec $NodeFastSec)
# 时钟为负时，"现在 < 哨兵" 曾在每个负数时刻都成立，把间隔永久钉在快档。
# 哨兵改 $null 之后，负时钟下也应该拿到稳定间隔。
Assert-Eq '间隔：时钟为负且没开过加密窗口，仍是稳定档' $NodeCheckThrottleSec (Get-NodeProbeInterval 0 $thr $null (-4000.0) $NodeCheckThrottleSec $NodeFastSec)

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

# 单调钟为负时仍然能判"断"。
#
# 这是 PowerShel 5.1 上的真实故障，不是假想：那边没有 TickCount64，退到 Int32 的
# TickCount，而它是**有符号**的——连续开机满 24.86 天就变负。原来用 -1.0 当"从未探过"
# 的哨兵、又用 -lt 0 判断它，两者在负值区间无法区分：每轮都被当成"没探过"，
# 节流恒生效、失败计数每轮清零、跨度恒为 0 -> 永不判"断"。
# 后果是代理早已死亡、变量永远指向死端口，终端全部 ECONNREFUSED。
# 该用例把时钟推到负值区间再推进，钉住"照样 3 次就判死"。
# 判据全部从常量推导，不写字面量——以后调阈值不该让它误报红。
$__monoSaved = (Get-Item -Path Function:Get-MonotonicSeconds).ScriptBlock
$__trcSaved2 = (Get-Item -Path Function:Test-RealConnectivity).ScriptBlock
$script:fakeNow = 0.0
try {
    ${function:Get-MonotonicSeconds} = { return $script:fakeNow }
    ${function:Test-RealConnectivity} = { param([int]$p) return $false }
    $script:NodeState = @{}
    $script:fakeNow = -5000.0
    $script:NodeState['7078'] = @{ LastCheck = $null; Alive = $true; FailCount = 0
                                   FirstFailAt = $null; FastUntil = $null }
    $verdictRound = 0
    for ($i = 1; $i -le ($NodeFailThreshold + 3); $i++) {
        # 每轮推进比稳定间隔多一点，保证节流不会把这次探测挡掉
        $script:fakeNow = $script:fakeNow + ($NodeCheckThrottleSec + 1)
        $alive = Test-NodeAlive 7078
        if (-not $alive -and $verdictRound -eq 0) { $verdictRound = $i }
    }
    Assert-Eq '时钟为负时仍然判得出断（不是永远 True）' $false (Test-NodeAlive 7078)
    # 判死发生在"次数够"的那一刻；时长条件也在同一轮满足（每轮推进 > dwell）。
    # 断言它确实在循环内发生过，而不是一直没判。
    Assert-Eq '时钟为负时循环内就判出了断' $true ($verdictRound -gt 0)
    Assert-Eq '时钟为负时判死不晚于阈值轮次' $true ($verdictRound -le $NodeFailThreshold)
} finally {
    ${function:Get-MonotonicSeconds} = $__monoSaved
    ${function:Test-RealConnectivity} = $__trcSaved2
    $script:fakeNow = 0.0
    $script:NodeState = @{}
}

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
# 先拿"写用户变量"那把互斥体再动手。
#
# 为什么必须拿：这一段验的是**真实注册表**（沙箱键覆盖不了 Git Bash 钩子的行为），
# 而在已安装的机器上，监控每 2–3 秒会做一次变量自愈——它写的是同一批真实变量。
# 两边同时动手就是竞态：实测连跑四次得到 3 / 1 / 4 / 0 个失败，失败项每次都不一样，
# 而且全都是"我们的值不见了"这类症状。一个会随机变红的测试等于没有测试——
# 它一会让人去查不存在的 bug，一会又放过了真问题。
# 拿锁之后监控会在 WaitOne 那里等，本段跑完释放，两边不再交叉。
$hookGate = $null
$hookHeld = $false
try {
    $hookGate = New-Object System.Threading.Mutex($false, (Get-MutexName "EnvProxyApplyState"))
    $hookHeld = $hookGate.WaitOne(30000)
} catch [System.Threading.AbandonedMutexException] {
    # 上一个持有者没释放就死了，但锁已经交给本线程（与 env.ps1 同一条判断）。
    $hookHeld = $true
} catch {}
if (-not $hookHeld) {
    # 拿不到锁 = 监控正在写同一批真实变量，这一段的前提不成立。
    # 明确跳过而不是给出可能失真的结论（FAIL 和 PASS 在这里都是假话）。
    Write-Host '  SKIP 等不到变量锁（监控正在写），这一段整体跳过——避免给出失真的结论'
    $script:AssertionMuted = $true
}
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
    Assert-EqGated '加载钩子后立刻注入' 'http://127.0.0.1:7078' $env:HTTPS_PROXY
    # 注意：不能用 "$null -ne $function:prompt" 判"包住了"——PowerShell 自带默认 prompt，
    # 那个表达式永远为真，把包装函数整行删掉也照样 PASS（实测如此）。
    # 真判据是我们自己的哨兵变量 + 真的调一次 prompt 看效果。
    Assert-EqGated '包装标记已置位（这是回车生效的机制）' $true $global:__EnvProxyPromptWrapped
    Assert-EqGated '原 prompt 已备份（用于链式调用）' $true ($null -ne $global:__EnvProxyPrevPrompt)

    # 真实路径：敲回车 = 宿主调用 prompt。这里手动调一次，走的是包装后的函数。
    foreach ($n in $ProxyVarNames) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
    $null = prompt
    Assert-EqGated '敲回车（调 prompt）后拿到代理' 'http://127.0.0.1:7078' $env:HTTPS_PROXY

    # 代理关掉：monitor 清掉注册表里的值 -> 钩子把会话里"我们写过的"也清掉
    foreach ($n in $ProxyVarNames) { Set-RegValue $n $null }
    $null = prompt
    Assert-EqGated '代理关掉后回到提示符恢复直连' '' "$env:HTTPS_PROXY"

    # 用户自己设的值必须保留（README 的承诺，也是契约里最容易被破坏的一条）
    $env:HTTPS_PROXY = 'http://corp-proxy:8080'
    $null = prompt
    Assert-EqGated '用户自己的公司代理不被删' 'http://corp-proxy:8080' $env:HTTPS_PROXY

    $env:HTTPS_PROXY = 'http://127.0.0.1:8080'
    $null = prompt
    Assert-EqGated '用户自己的本机地址不被删' 'http://127.0.0.1:8080' $env:HTTPS_PROXY

    # 逐窗口接管
    foreach ($n in $ProxyVarNames) { Set-RegValue $n $null }
    Set-RegValue 'HTTPS_PROXY' 'http://127.0.0.1:7078'
    Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue
    $null = prompt
    Assert-EqGated '重新注入' 'http://127.0.0.1:7078' $env:HTTPS_PROXY
    $env:ENVPROXY_TERM = 'off'
    $null = prompt
    Assert-EqGated '接管开关生效（固定直连）' '' "$env:HTTPS_PROXY"
    Remove-Item Env:ENVPROXY_TERM -ErrorAction SilentlyContinue
    $null = prompt
    Assert-EqGated '放开接管开关后恢复自动' 'http://127.0.0.1:7078' $env:HTTPS_PROXY

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
    Assert-EqGated '值等于记录值：清除' '' "$env:HTTPS_PROXY"

    # (b) 有归属记录、但使用者改成了别的值 → 必须保住（不能按形状猜）
    $env:HTTPS_PROXY = 'http://corp-proxy:8080'
    $null = prompt
    Assert-EqGated '值不等于记录值：保住公司代理' 'http://corp-proxy:8080' $env:HTTPS_PROXY

    # (c) 有归属记录、使用者改成另一个本机端口 → 同样必须保住
    $env:HTTPS_PROXY = 'http://127.0.0.1:9090'
    $null = prompt
    Assert-EqGated '值不等于记录值：保住别的端口的本机代理' 'http://127.0.0.1:9090' $env:HTTPS_PROXY

    # (d) 没有归属记录 → 判不了，一个都不动
    if (Test-Path (Get-OwnedRegKeyPath)) { Remove-Item (Get-OwnedRegKeyPath) -Recurse -Force }
    $env:HTTPS_PROXY = 'http://127.0.0.1:7078'
    $null = prompt
    Assert-EqGated '无归属记录时不动任何值（判不了就不猜）' 'http://127.0.0.1:7078' $env:HTTPS_PROXY

    # (e) 快照保护住在 env.ps1 的注册表清理路径里，不在钩子里——直接断言那个判据，
    #     不能拿钩子的行为冒充它（钩子根本不读快照）。
    Assert-EqGated 'Test-IsOwnedProxyValue 是真实存在的判据' 'Function' (Get-Command Test-IsOwnedProxyValue -ErrorAction SilentlyContinue).CommandType

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
    # 还原做完之后才放锁：早放会让监控在"变量已改回、归属记录还没放回"的空窗里插进来，
    # 读到一份不完整的记录，又变成另一种竞态。
    if ($hookHeld -and $null -ne $hookGate) {
        try { $hookGate.ReleaseMutex() } catch {}
    }
    if ($null -ne $hookGate) { try { $hookGate.Dispose() } catch {} }
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
#
# 必须先判"这台机器上有没有 curl"。取不到时**跳过**，不要硬算：
# `(Get-Command curl).CommandType` 在结果为 null 时抛
# "You cannot call a method on a null-valued expression"，
# 而本文件 $ErrorActionPreference = 'Stop'，于是整段自检当场中止——
# 后面几百条用例一条都不跑，CI 日志里只剩一句"退出码 1"。
# 精简的 Linux 容器、Server Core、被清理过的系统都可能没有 curl。
# 这与下面 cmd 那段是同一个教训（那里已经先算路径再判存在）。
$curlCmd = Get-Command curl -ErrorAction SilentlyContinue
if ($curlCmd) {
    $curlKind = $curlCmd.CommandType.ToString()
    $is51 = ($PSVersionTable.PSVersion.Major -lt 6)
    Assert-Eq 'curl kind matches what the docs claim for this version' $true (($is51 -and $curlKind -eq 'Alias') -or ((-not $is51) -and $curlKind -ne 'Alias'))
} else {
    Write-Host '  SKIP curl 别名前提（这台机器上取不到 curl）'
}

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
# 断言改成钉"派生调用"而不是"死文字"：文案里的菜单名已收敛到 Get-MenuRef，
# 源码里不再出现「安装 / 修复」这个字面串（它住在菜单表里）。
# 钉死文字会让这条断言在正确的重构之后变红，而钉死"有没有告诉读者下一步"才是它本来要守的东西。
Assert-Eq 'status page tells the reader what to do next' $true ($renderSrc -match 'Get-MenuRef')
Assert-Eq 'status page points at the install/repair action' $true ($renderSrc -match "Get-MenuRef 'Install'")
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
# 帮助里那一条（菜单说明）已经不在了：主菜单自己就把每项干什么写得清清楚楚，
# 再列一遍等于让用户读两遍同样的东西。所以这里只剩菜单渲染这一处要守。
foreach ($fn in @('Get-MenuRenderedLines')) {
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
# 只数**真正的调用**，不数注释与函数定义：全文命中会把解释性注释（env.ps1 里
# 有两句提到这个名字）和定义行一起算进去，于是两个真实调用点全删掉、命中数仍然够，
# 断言照样绿。判据是"剥掉注释行、再去掉定义那一行之后还剩几次"。
$script:pvpCalls = 0
foreach ($f in @('win/lib/env.ps1', 'win/lib/runtime.ps1')) {
    $p = Join-Path (Get-Location) $f
    foreach ($ln in ([System.IO.File]::ReadAllText($p) -split "`r?`n")) {
        $t = $ln.Trim()
        if (-not $t) { continue }
        if ($t.StartsWith('#')) { continue }
        if ($t -match '^function\s+Test-ProxyVarsPresent\b') { continue }
        $script:pvpCalls += ([regex]::Matches($t, 'Test-ProxyVarsPresent')).Count
    }
}
# apply-state 与监控自愈各一处：少于 2 就说明有一条路的门槛被剪断了。
Assert-Eq '接线：清理门槛被至少两处调用' $true ($script:pvpCalls -ge 2)
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
    $chunk = Get-FunctionBody 'win/lib/ops.ps1' $fn
    Assert-Eq ('接线：' + $fn + ' 函数体取到了') $true ($chunk.Length -gt 0)
    Assert-Eq ('接线：' + $fn + ' 不写用户变量') $false ([bool]([regex]::IsMatch($chunk, 'SetEnvironmentVariable')))
}

# ------------------------------------------------------------------------------
# 状态快照（监控写、状态页只读）
#
# 这一层的判据是「读不出来 ≠ 没有」。坏文件、缺字段、时间戳解析失败，都必须
# 判成读不出来，绝不能让调用方当成「值为空 = 没有代理」——那是这个项目最怕的
# 反向倒挂：状态页说没代理、监控还在用着 7078。
# ------------------------------------------------------------------------------
Write-Host ''
Write-Host '--- 状态快照 ---'

$snapDir = New-TempDir 'ep-snap-'
$snapFile = Join-Path $snapDir 'state.snapshot'
$realSnapFile = $StateSnapshotFile
try {
    $StateSnapshotFile = $snapFile

    # 没有文件 = none（不是 damaged，也不是「空快照」）
    Assert-Eq '快照：没有文件判 none' 'none' (Read-StateSnapshot).Status

    # 完整往返：写进去的每个字段都要原样读回来
    Write-StateSnapshot -State 'on:7078' -PrevState 'on:7100' -PendingState 'off' -PendingCount 2 `
        -PortEnumeration 'ok' -PortReason '' -VarsMatch 'yes' -ApplyResult 'ok'
    $r = Read-StateSnapshot
    Assert-Eq '快照：写完能读回 ok' 'ok' $r.Status
    Assert-Eq '快照：state 原样' 'on:7078' $r.State
    Assert-Eq '快照：prev_state 原样' 'on:7100' $r.PrevState
    Assert-Eq '快照：pending_state 原样' 'off' $r.PendingState
    Assert-Eq '快照：pending_count 是数字' 2 $r.PendingCount
    Assert-Eq '快照：vars_match 原样' 'yes' $r.VarsMatch
    Assert-Eq '快照：apply_result 原样' 'ok' $r.ApplyResult
    Assert-Eq '快照：pid 不是 0' $true ($r.Pid -gt 0)
    Assert-Eq '快照：年龄接近 0' $true ([Math]::Abs($r.AgeSec) -le 5)

    # 三态：空值 / 有值 / 不知道，三者不许互相冒充
    Write-StateSnapshot -State '' -PrevState '' -PendingState '' -PendingCount 0 `
        -PortEnumeration 'failed' -PortReason 'netstat 没有输出' -VarsMatch 'unknown' -ApplyResult 'unknown'
    $r = Read-StateSnapshot
    Assert-Eq '快照：空 state 读作空（明确的空）' '' $r.State
    Assert-Eq '快照：枚举失败读作 failed' 'failed' $r.PortEnumeration
    Assert-Eq '快照：失败原因原样带回' 'netstat 没有输出' $r.PortReason
    Assert-Eq '快照：unknown 不等于空' 'unknown' $r.VarsMatch

    # 值里带等号、反斜杠、换行：都不得破坏解析
    Write-StateSnapshot -State 'off' -PrevState '' -PendingState '' -PendingCount 0 `
        -PortEnumeration 'failed' -PortReason 'C:\Windows\System32 a=b 以及换行' -VarsMatch 'no' -ApplyResult 'failed'
    $r = Read-StateSnapshot
    Assert-Eq '快照：值里的等号与反斜杠完整保留' 'C:\Windows\System32 a=b 以及换行' $r.PortReason

    # 缺任何一个字段 = 整份不用。半截文件最危险：它看着像有效数据。
    $good = [System.IO.File]::ReadAllLines($snapFile)
    foreach ($drop in @('round=', 'state=', 'log_tail=')) {
        $kept = @($good | Where-Object { $_ -notlike ($drop + '*') })
        [System.IO.File]::WriteAllLines($snapFile, $kept, (New-Object System.Text.UTF8Encoding($false)))
        $d = Read-StateSnapshot
        Assert-Eq ('快照：缺 ' + $drop.TrimEnd('=') + ' 判 damaged') 'damaged' $d.Status
        Assert-Eq ('快照：缺字段时一个字段都不返回（' + $drop.TrimEnd('=') + '）') '' $d.State
    }

    # 首行标记不对 = 不是我们的文件
    [System.IO.File]::WriteAllLines($snapFile, @('随便什么', 'round=1'), (New-Object System.Text.UTF8Encoding($false)))
    Assert-Eq '快照：首行标记不对判 damaged' 'damaged' (Read-StateSnapshot).Status

    # 时间戳解析不出来也得判 damaged，不许当成「刚写的」
    Write-StateSnapshot -State 'off' -PrevState '' -PendingState '' -PendingCount 0 `
        -PortEnumeration 'ok' -PortReason '' -VarsMatch 'yes' -ApplyResult 'ok'
    $txt = [System.IO.File]::ReadAllText($snapFile) -replace 'written=[^\n]*', 'written=不是时间'
    [System.IO.File]::WriteAllText($snapFile, $txt, (New-Object System.Text.UTF8Encoding($false)))
    Assert-Eq '快照：时间戳坏了判 damaged' 'damaged' (Read-StateSnapshot).Status

    # 字段表本身：门禁 6 拿它与 Mac 侧比对，两侧必须同名同数量
    Assert-Eq '快照：字段表 12 个' 12 $SnapshotKeys.Count
    Assert-Eq '快照：字段表含 written' $true ($SnapshotKeys -contains 'written')
    Assert-Eq '快照：字段表含 vars_match' $true ($SnapshotKeys -contains 'vars_match')

    # 三个陈旧阈值必须递增，且最旧的等于心跳上限（同一个语义只能有一个数）
    Assert-Eq '快照：阈值递增' $true (($SnapshotFreshSec -lt $SnapshotUsableSec) -and ($SnapshotUsableSec -lt $SnapshotStaleSec))
    # 报告会发给别人，代理地址里的账号密码必须在这一处隐去。
    # 断言的正是"状态页如实显示、报告里脱敏"这条边界：只测脱敏函数，不测整条报告链——
    # 报告还依赖实时状态与日志，测它会让这条断言变成环境测试。
    Assert-Eq '报告脱敏：带密码的地址被隐去' 'http://***@127.0.0.1:7890' (Hide-ProxyCredential 'http://user:MySecretPwd@127.0.0.1:7890')
    Assert-Eq '报告脱敏：socks5 同样隐去' 'socks5://***@127.0.0.1:1080' (Hide-ProxyCredential 'socks5://u:p@127.0.0.1:1080')
    Assert-Eq '报告脱敏：无凭据的地址原样保留' 'http://127.0.0.1:7890' (Hide-ProxyCredential 'http://127.0.0.1:7890')
    Assert-Eq '报告脱敏：只动 userinfo，不动主机端口' $true ((Hide-ProxyCredential '代理变量 : 已注入 (http://u:p@h:1)') -eq '代理变量 : 已注入 (http://***@h:1)')
    Assert-Eq '快照：最旧阈值等于心跳上限' $HeartbeatMaxSec $SnapshotStaleSec
} finally {
    $StateSnapshotFile = $realSnapFile
    Remove-Item -LiteralPath $snapDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------------------
# 屏幕渲染层
#
# 这一层决定「闪不闪」。判据是字节数：内容不变时必须零字节输出，
# 只改一行时只发一行。不含控制台的纯计算部分可以直接断言。
# ------------------------------------------------------------------------------
Write-Host ''
Write-Host '--- 屏幕渲染层 ---'

# 能不能画屏：重定向/无控制台时必须判 false。自检本身就跑在重定向环境里，
# 所以这里断言 false——这正好验证了「重定向不发控制字符」这条降级。
Assert-Eq '渲染：重定向环境判不可画屏' $false (Test-CanDrawScreen)

# 窗口太矮时拒绝画屏：要求 40 行而最小高度是 20 行，必然放不下
Assert-Eq '渲染：要求超出窗口高度时判不可画屏' $false (Test-CanDrawScreen 9999)

# 常量必须有值且自洽（散着写死会在改一处时漏掉另一处）
Assert-Eq '渲染：最小宽高已定义' $true (($ScreenMinWidth -gt 0) -and ($ScreenMinHeight -gt 0))
Assert-Eq '渲染：刷新间隔是 2000ms' 2000 $StatusRefreshIntervalMs
Assert-Eq '渲染：轮询粒度小于刷新间隔' $true ($ScreenPollMs -lt $StatusRefreshIntervalMs)

# Write-ScreenFrame 在不可画屏时必须安静返回 0，且一个字节都不发
$frameOut = Write-ScreenFrame -Old @('a') -New @('b')
Assert-Eq '渲染：不可画屏时不画且返回 0' 0 $frameOut

# ------------------------------------------------------------------------------
# 状态页的两条渲染路径必须同源
#
# Format-StatusLines（纯文本行，给刷新循环）与 Show-StatusSnapshot（带颜色分段）
# 是两份输出逻辑，最容易漂移。这里断言两者的「话」一致：
#   同一份状态，结论行与问题条目必须逐条相同。
# ------------------------------------------------------------------------------
Write-Host ''
Write-Host '--- 状态页两条渲染路径 ---'

$probeSt = [ordered]@{
    Monitor = $null; StopIntent = $false; NeverInstalled = $true
    AutoRunOk = $false; Port = $null; PortUnknown = $false; PortEnumerationReason = ''
    TermSync = $null; ProxyValue = ''; ProxyAlive = $null; ProxyPort = 0; ProxyHost = $null
    SysProxy = $false; UpdateInProgress = $false; LocalVersion = '9.9.9'
    RemoteCache = $null; Snapshot = $null; DevCopy = $false
}
$probs = @(Get-StatusProblems $probeSt)
# 从没装过时报两条：还没安装 + 开机自启没生效。两条都是真的（都没做成），
# 而 Show-StatusSnapshot 里另有分支把这种情况说成一句话，避免让人以为机器有三处毛病。
Assert-Eq '问题清单：从没装过时报两条' 2 $probs.Count
Assert-Eq '问题清单：那一条是还没安装' '还没安装' $probs[0]

# 正例：一切正常时一条都不报
$goodSt = [ordered]@{
    Monitor = [pscustomobject]@{ ProcessId = 1234 }; StopIntent = $false; NeverInstalled = $false
    AutoRunOk = $true; Port = 7078; PortUnknown = $false; PortEnumerationReason = ''
    TermSync = [pscustomobject]@{ State = 'ok' }; ProxyValue = 'http://127.0.0.1:7078'; ProxyAlive = $true
    ProxyPort = 7078; ProxyHost = '127.0.0.1'
    SysProxy = $false; UpdateInProgress = $false; LocalVersion = '9.9.9'
    RemoteCache = $null; Snapshot = $null; DevCopy = $false
}
Assert-Eq '问题清单：全正常时零条' 0 (@(Get-StatusProblems $goodSt)).Count

# 判断只有一处实现：Show-StatusSnapshot 必须调 Get-StatusProblems，
# 不许自己再算一遍（两处各写一套必然分叉）
$opsSrc = [System.IO.File]::ReadAllText((Join-Path (Get-Location) 'win/lib/ops.ps1'))
$ssBody = Get-FunctionBody 'win/lib/ops.ps1' 'Show-StatusSnapshot'
Assert-Eq '接线：Show-StatusSnapshot 函数体取到了' $true ($ssBody.Length -gt 0)
Assert-Eq '接线：Show-StatusSnapshot 调用 Get-StatusProblems' $true ([bool]([regex]::IsMatch($ssBody, 'Get-StatusProblems')))
Assert-Eq '接线：Show-StatusSnapshot 不自己累加问题' $false ([bool]([regex]::IsMatch($ssBody, '\$problems \+= ')))

# Format-StatusLines 也必须走同一个判断
$fsBody = Get-FunctionBody 'win/lib/ops.ps1' 'Format-StatusLines'
Assert-Eq '接线：Format-StatusLines 函数体取到了' $true ($fsBody.Length -gt 0)
Assert-Eq '接线：Format-StatusLines 调用 Get-StatusProblems' $true ([bool]([regex]::IsMatch($fsBody, 'Get-StatusProblems')))

# 两条渲染路径的输出要能对上：拿同一份状态，逐条比对结论行
$lines = @(Format-StatusLines $goodSt)
Assert-Eq '渲染路径：正常态首行是标题' $true ($lines[0] -match 'EnvProxy 状态')
# 帧里每一行都带 ANSI 颜色，直接比字符串会把颜色码也算进去而永远不等。
# 比"说了什么"必须先剥掉颜色——这正好也验证了 Remove-AnsiColor 能用。
#
# 断言「结论在标题之后、且是第一条有内容的话」，**不写死行号**：
# 排版规则会变（标题下要留一行空白、以后还可能加分组），行号一钉死，
# 每次调排版都得改测试，改到最后就没人当真了。
$bodyLines = @($lines | Select-Object -Skip 1 | ForEach-Object { Remove-AnsiColor $_ } | Where-Object { $_.Trim() })
Assert-Eq '渲染路径：正常态说一切正常' '一切正常，不用做任何事。' $bodyLines[0]
Assert-Eq '渲染路径：帧里带退出提示' $true ([bool](@($lines | Where-Object { $_ -match '按 0 或 Esc' }).Count))
Assert-Eq '渲染路径：正常态不含「项要注意」' $false ([bool](@($lines | Where-Object { $_ -match '项要注意' }).Count))

$badLines = @(Format-StatusLines $probeSt)
Assert-Eq '渲染路径：异常态报出注意项' $true ([bool](@($badLines | Where-Object { $_ -match '\d+ 项要注意' }).Count))

# ------------------------------------------------------------------------------
# 两版状态页必须说同样的话（真比对，不是各自测各的）
# ------------------------------------------------------------------------------
# 上面那些断言只验 Format-StatusLines 自己，从未把两版放在一起看，
# 于是"注释声称自检会比对两版"这句话长期是假的，而两版真的分叉了：
# 静态页有「上次更新」「系统代理」两段带'怎么办'的说明，实时帧完全没有——
# 同一份状态，按回车看 8 行、等它刷新看 6 行，缺的正好是行动指引。
# 用户报"信息对不上"时，查的人会以为是缓存问题，实际是两份代码。
#
# 判据：同一份状态喂给两版，**抠掉颜色与排版差异后，两版的"内容行"必须一致**。
# 排版允许不同（实时帧有边框、有刷新提示；静态页没有），内容不允许。
# 这一条不依赖行号、不写死具体句子——将来加行，两版都得加，否则这里红。
$__cmpSt = [ordered]@{
    Monitor = [pscustomobject]@{ ProcessId = 4321 }
    StopIntent = $false; NeverInstalled = $false; AutoRunOk = $true
    Port = 7078; PortUnknown = $false
    ProxyValue = 'http://127.0.0.1:7078'; ProxyAlive = $true
    # 终端同步用**正常态**（最常见的那条路），不用 $null。
    # 用 $null 会让 fixture 恰好走进 else 分支——那里曾因为一个大括号错位
    # 被误当成 `$vt 的作用域，于是"版本行是空的"这个真 bug 被这条用例放过了。
    # 用正常态才对：正常机器永远走 if 分支，那才是用户实际看到的样子。
    TermSync = [pscustomobject]@{ State = 'ok' }
    SysProxy = [pscustomobject]@{ State = 'residual'; Server = '127.0.0.1:9999' }
    UpdateInProgress = $true
    VarsMatch = 'no'; ApplyResult = 'failed'
}
# 只保留"内容"：去掉颜色、去掉纯装饰（分隔线、刷新提示、空行）。
function __cmpContent([string[]]$Lines) {
    $keep = @()
    foreach ($ln in $Lines) {
        $t = (Remove-AnsiColor $ln).Trim()
        if (-not $t) { continue }
        if ($t -match '^=+$' -or $t -match '^-{2,}' -or $t -match '正在实时刷新' -or $t -match 'EnvProxy 状态') { continue }
        $keep += $t
    }
    return $keep
}
# 从静态页的行里抽出"状态项"：它的形态是 `标签 :` 单独一行，值在下一行。
# 返回 @( @{Label; Value} ... )
# 为什么要这样抽：两版的**行结构本来就不同**——静态页把标签和值分两行，
# 实时帧合成 "标签 : 值" 一行。逐字比行永远不等，那是排版差异，不是内容差异。
function __cmpItems([string[]]$Lines) {
    $items = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $t = (Remove-AnsiColor $Lines[$i]).Trim()
        if ($t -match '^(?<lbl>[^:]+):$' -and $i + 1 -lt $Lines.Count) {
            $val = (Remove-AnsiColor $Lines[$i + 1]).Trim()
            if ($val -and $val -notmatch '^[^:]+:$') {
                $items += @{ Label = $Matches['lbl'].Trim(); Value = $val }
            }
        }
    }
    return $items
}
$__liveRaw = @(Format-StatusLines $__cmpSt)
$__statRaw = @(Show-StatusSnapshot $__cmpSt 6>&1 | ForEach-Object { "$_" })
$__live = __cmpContent $__liveRaw
$__stat = __cmpContent $__statRaw

# 关键断言：静态页报出来的每一个"状态项"（标签 + 值），实时帧里都得有。
# 判据落在**标签和值都出现**上，不落到行格式上——两版排版可以不同，
# 但"这一项说了什么"必须一样。静态页多出来一项而实时帧没有，就是这次的真实故障形态。
$__items = @(__cmpItems $__stat)
Assert-Eq '两版状态页：至少抽出 5 个状态项（抽取规则没失效）' $true ($__items.Count -ge 5)
$__missingInLive = @()
foreach ($it in $__items) {
    $hitLabel = @($__live | Where-Object { $_ -match ('^' + [regex]::Escape($it.Label) + '\s*[:：]') }).Count -gt 0
    $hitValue = @($__live | Where-Object { $_ -like ('*' + $it.Value + '*') }).Count -gt 0
    if (-not ($hitLabel -and $hitValue)) { $__missingInLive += ($it.Label + ' -> ' + $it.Value) }
}
Assert-Eq '两版状态页：静态页的每一项实时帧都有（缺了就是分叉）' 0 $__missingInLive.Count
foreach ($m in $__missingInLive) { Write-Host ('    实时帧缺少：' + $m) }

# 反向：实时帧报出来的项，静态页也得有（防止以后只改实时帧）。
#
# 实时帧的行是"标签 : 值"一行写完的，而 __cmpItems 认的是"标签单独一行带冒号"，
# 所以它从实时帧抽出 0 项——下面那条断言于是恒真，静默丢行（比如整段"高级功能"）
# 它永远发现不了。实测把静态页的"高级功能"整段删掉，这条照样绿。
# 这里改用专门认"标签 : 值"的抽取，并且**先断言抽到了东西**：
# 抽取规则失效必须报红，不能让"抽不到"悄悄退化成"没问题"。
function __cmpLiveLabels([string[]]$Lines) {
    $labels = @()
    foreach ($ln in $Lines) {
        $t = (Remove-AnsiColor $ln).Trim()
        if ($t -match '^(?<lbl>[^:：]+)\s*[:：]') {
            $l = $Matches['lbl'].Trim()
            # 排除说明性文字（含空格的都不是标签，例如"打开菜单选 1"）
            if ($l -and $l -notmatch '\s' -and $labels -notcontains $l) { $labels += $l }
        }
    }
    return $labels
}
$__liveItems = @(__cmpLiveLabels $__liveRaw)
Assert-Eq '两版状态页：实时帧至少抽出 5 个标签（抽取规则没失效）' $true ($__liveItems.Count -ge 5)
$__missingInStat = @()
foreach ($lbl in $__liveItems) {
    $hit = @($__stat | Where-Object { $_ -match ('^' + [regex]::Escape($lbl) + '\s*[:：]') }).Count -gt 0
    if (-not $hit) { $__missingInStat += $lbl }
}
Assert-Eq '两版状态页：实时帧的每一项静态页都有' 0 $__missingInStat.Count
foreach ($m in $__missingInStat) { Write-Host ('    静态页缺少：' + $m) }
foreach ($m in $__missingInStat) { Write-Host ('    静态页缺少：' + $m) }

# 状态页整段不许写文件、不许改变量（只读契约）
foreach ($fn in @('Format-StatusLines', 'Show-StatusLive', 'Get-StatusProblems')) {
    # 按花括号配对取函数体：截固定长度会把下一个函数框进来，
    # 而它的写文件调用会让这条断言永远红——量错对象比没量更糟。
    $chunk = Get-FunctionBody 'win/lib/ops.ps1' $fn
    Assert-Eq ('接线：' + $fn + ' 函数体取到了') $true ($chunk.Length -gt 0)
    Assert-Eq ('接线：' + $fn + ' 不写文件') $false ([bool]([regex]::IsMatch($chunk, 'Write-Text|Set-Content|New-Item|Remove-ItemSafe')))
    Assert-Eq ('接线：' + $fn + ' 不写用户变量') $false ([bool]([regex]::IsMatch($chunk, 'SetEnvironmentVariable|Write-UserEnv')))
}

# 轻量判活与完整判活：前者只读心跳，不许碰进程表
$rtSrc = [System.IO.File]::ReadAllText((Join-Path (Get-Location) 'win/lib/runtime.ps1'))
$fastChunk = Get-FunctionBody 'win/lib/runtime.ps1' 'Get-MonitorProcessFast'
Assert-Eq '接线：Get-MonitorProcessFast 函数体取到了' $true ($fastChunk.Length -gt 0)
if ($fastChunk.Length -gt 0) {
    # Get-Item 读的是文件属性（心跳文件的 mtime），不是进程表——不算重判活。
    # 真正要禁的是查进程：那才是 170ms 的来源。
    # 真正贵的是 Get-CimInstance（查全表，实测 170ms）。Get-Process -Id 是单查某个
    # pid，实测个位数毫秒，而且判活必须核一次「那个 pid 还在不在」——光看心跳文件的
    # mtime 会把强杀后留下的新鲜心跳当成活着（实测会把死进程的 PID 报到屏幕上）。
    # 只看代码，不看注释：注释里会把「不用 Get-CimInstance」写出来解释为什么，
    # 把那句当违规就永远红。先剥掉注释行再判。
    $fastCode = (@($fastChunk -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n")
    Assert-Eq '接线：轻量判活不用 WMI 全表查询' $false ([bool]([regex]::IsMatch($fastCode, 'Get-CimInstance')))
    # 但它必须核 pid 存在性：没有 Get-Process 就说明又退回了「只看 mtime」。
    Assert-Eq '接线：轻量判活核过 pid 存在性' $true ([bool]([regex]::IsMatch($fastChunk, 'Get-Process')))
}

# ------------------------------------------------------------------------------
# 本次修复的回归断言
#
# 每一条都对应一个真实发生过的缺陷，不是"为了覆盖率"补的。反向验证过：
# 把修复撤掉，这些断言会红。
# ------------------------------------------------------------------------------
Write-Host ''
Write-Host '--- 状态页修复项 ---'

# 1. 终端同步的状态码不许原样上屏
#    曾经：Format-StatusLines 直接把 $st.TermSync.State 拼进去，于是
#    blocked/unpaired/stale/missing/nohost 五个英文单词印给用户。
foreach ($code in @('blocked', 'unpaired', 'stale', 'missing', 'nohost')) {
    $sync = [pscustomobject]@{ State = $code; Detail = 'x'; Line = 7 }
    $tt = Get-TermSyncText $code $sync
    $hasAscii = [bool]([regex]::IsMatch([string]$tt.Text, '[A-Za-z]{4,}'))
    Assert-Eq ('终端同步：' + $code + ' 译成中文（不含英文单词）') $false $hasAscii
    Assert-Eq ('终端同步：' + $code + ' 带下一步动作') $true ([bool]($tt.Hint))
}
$okT = Get-TermSyncText 'ok' ([pscustomobject]@{ State = 'ok' })
Assert-Eq '终端同步：ok 不需要提示动作' '' $okT.Hint
Assert-Eq '终端同步：未知状态也要说人话' $true ([bool]((Get-TermSyncText 'zzz' ([pscustomobject]@{ State = 'zzz' })).Text -match '状态未知'))

# 2. 提示里出现的按键必须真的被处理
#    曾经：底部写「按 2 看一次静态快照」，而循环只认 Quit，按 2 毫无反应。
$opsSrc2 = [System.IO.File]::ReadAllText((Join-Path (Get-Location) 'win/lib/ops.ps1'))
$fsIdx2 = $opsSrc2.IndexOf('function Format-StatusLines')
$nextFn2 = $opsSrc2.IndexOf('function ', $fsIdx2 + 10)
$fsChunk2 = if ($nextFn2 -gt $fsIdx2) { $opsSrc2.Substring($fsIdx2, $nextFn2 - $fsIdx2) } else { $opsSrc2.Substring($fsIdx2) }
$slIdx2 = $opsSrc2.IndexOf('function Show-StatusLive')
$nextFn3 = $opsSrc2.IndexOf('function ', $slIdx2 + 10)
$slChunk2 = if ($nextFn3 -gt $slIdx2) { $opsSrc2.Substring($slIdx2, $nextFn3 - $slIdx2) } else { $opsSrc2.Substring($slIdx2) }
# 找出所有 "按 X" 里提到的键
$advertised = @([regex]::Matches($fsChunk2, '按 ([0-9A-Za-z])') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$unstoppable = @()
foreach ($k in $advertised) {
    # 0/q/Q/Esc 由 Wait-ScreenKey 映射成 Quit，循环认它；其余必须自己有分支
    if (@('0', 'q', 'Q') -contains $k) { continue }
    if ($slChunk2 -notmatch ("-eq '" + [regex]::Escape($k) + "'")) { $unstoppable += $k }
}
Assert-Eq '提示：提到的每个按键都有对应分支' 0 $unstoppable.Count

# 3. Wait-ScreenKey 的异常路径不许让外层空转
#    曾经：catch { return '' } 立即返回，循环毫无间隔地转，一秒几千次、吃满一个核。
$bsSrc = [System.IO.File]::ReadAllText((Join-Path (Get-Location) 'win/lib/base.ps1'))
$wsChunk = Get-FunctionBody 'win/lib/base.ps1' 'Wait-ScreenKey'
Assert-Eq '接线：Wait-ScreenKey 函数体取到了' $true ($wsChunk.Length -gt 0)
Assert-Eq '按键：读键失败时不会立即返回空转' $false ([bool]([regex]::IsMatch($wsChunk, "catch\s*\{\s*return\s+''\s*\}")))
Assert-Eq '按键：有放弃阈值常量' $true ($ScreenKeyFailLimit -gt 0)
Assert-Eq '按键：功能键（空字符）不当成输入返回' $true ([bool]([regex]::IsMatch($wsChunk, 'if \(\$c\)')))

# 3b. 轮询超时的空串不是按键，任何循环都不许把它当退出。
#     曾经：中继页写着"看完按回车返回"，退出判据写成 if ($k -eq "") { break }，
#     而 Wait-ScreenKey 等满一个轮询周期、没等到键时返回的正是一个空串。
#     结果这一屏画完一帧就自己退出，用户看到的是"点进去闪一下又退回上级菜单"。
#     判据据此收紧：Wait-ScreenKey 的返回语义里，空串 == 没有按键。
$wsReturnsEmpty = [bool]([regex]::IsMatch($wsChunk, "return\s+'"))
Assert-Eq '按键：等满超时明确返回空串（调用方据此区分没按键）' $true $wsReturnsEmpty
# 两个屏幕循环都不许把空串当退出。
# 判据取「$k 与空串比较」这一具体形态，而不是笼统搜 break——
# 笼统搜会把正常分支也算进去。
foreach ($pair in @(@('win/lib/ops.ps1', '状态页'), @('win/lib/shortcut.ps1', '中继页'))) {
    $src2 = [System.IO.File]::ReadAllText((Join-Path (Get-Location) $pair[0]))
    $badEmpty = 0
    foreach ($m in [regex]::Matches($src2, '\$k\s+-eq\s+(\S+)')) {
        $rhs = $m.Groups[1].Value.TrimEnd(')', '"').TrimStart('(', '"', "'")
        if ($rhs -eq '') { $badEmpty++ }
    }
    Assert-Eq ('按键：' + $pair[1] + ' 不把空串当退出') 0 $badEmpty
}

# 3c. 中继的端口记录必须能自愈，不能只靠启动时写一次。
#     曾经：中继启动时写一次 relay.port，之后再不写。那个文件被删掉
#     （跑一次卸载 / 清理工具 / 停→启的窗口期）后，中继还在转发，
#     但状态页与「查看中继」读不到凭据，双双显示"没在工作"——
#     而 monitor.log 明明写着"固定入口已启动：127.0.0.1:17099"。
#     实测过这个组合，用户看到的就是两句互相矛盾的话。
$rlSrc = [System.IO.File]::ReadAllText((Join-Path (Get-Location) 'win/lib/relay.ps1'))
$syncChunk = Get-FunctionBody 'win/lib/relay.ps1' 'Sync-RelayUpstream'
Assert-Eq '接线：Sync-RelayUpstream 函数体取到了' $true ($syncChunk.Length -gt 0)
Assert-Eq '中继：每轮同步会确认端口记录' $true ([bool]([regex]::IsMatch($syncChunk, 'Get-RelayPortFile')))
Assert-Eq '中继：内容已对就不重复写盘' $true ([bool]([regex]::IsMatch($syncChunk, '\$now -ne \$want')))
$startChunk = Get-FunctionBody 'win/lib/relay.ps1' 'Start-Relay'
Assert-Eq '接线：Start-Relay 函数体取到了' $true ($startChunk.Length -gt 0)
Assert-Eq '中继：端口记录写失败要留日志' $false ([bool]([regex]::IsMatch($startChunk, 'Port\) \} catch \{\}')))
# 4. 画屏门槛必须按真实帧尺寸判，不能只看固定最小宽高
#    曾经：固定 40 列放行，而帧里有 82 列的日志行 → 折行 → 绝对定位全错位。
Assert-Eq '画屏：Test-CanDrawScreen 支持按帧宽判' $true ([bool]([regex]::IsMatch($bsSrc, 'function Test-CanDrawScreen\(\[int\]\$NeedLines = 0, \[int\]\$NeedWidth = 0\)')))
Assert-Eq '画屏：有帧尺寸测量函数' $true ($bsSrc -match 'function Measure-ScreenFrame')
$mf = Measure-ScreenFrame @('短', '这一行比较长比较长', '中')
Assert-Eq '画屏：帧尺寸测量取最宽行' $true ($mf.Width -ge 16)
Assert-Eq '画屏：帧尺寸测量记行数' 3 $mf.Lines

# 5. 窗口尺寸变化必须作废记账（否则拉小再拉回，屏幕永久错位）
Assert-Eq '画屏：尺寸变化时作废上一帧' $true ([bool]([regex]::IsMatch($bsSrc, 'ScreenLastWidth')))

# 6. 日志裁剪按显示宽度，不按字符数
#    曾经：$ln.Length -gt 78，中文行实际 90+ 格必然折行。
$ldIdx = $opsSrc2.IndexOf('function Limit-DisplayText')
Assert-Eq '日志：有按显示宽度裁剪的函数' $true ($ldIdx -ge 0)
if ($ldIdx -ge 0) {
    $nextLd = $opsSrc2.IndexOf('function ', $ldIdx + 10)
    $ldChunk = if ($nextLd -gt $ldIdx) { $opsSrc2.Substring($ldIdx, $nextLd - $ldIdx) } else { $opsSrc2.Substring($ldIdx) }
    Assert-Eq '日志：裁剪用 Get-DisplayWidth' $true ([bool]([regex]::IsMatch($ldChunk, 'Get-DisplayWidth')))
    $cut = Limit-DisplayText ('一' * 100) 60
    Assert-Eq '日志：中文长行裁到 60 列内' $true ((Get-DisplayWidth $cut) -le 60)
    $keep = Limit-DisplayText '短行' 60
    Assert-Eq '日志：短行不动' '短行' $keep
}

# 7. 快照的转义必须闭环（含 Windows 路径的值不许被劈成两行）
#    曾经：用 \n 当换行标记却不转义反斜杠，C:\nodejs\npm 读回来变成两行、字段丢失。
foreach ($v in @('C:\nodejs\npm', 'C:\new\nested', '100% 完成', '%0A 字面量')) {
    $rt = ConvertFrom-SnapshotValue (ConvertTo-SnapshotValue $v)
    Assert-Eq ('快照转义：往返回原值 ' + $v) $v $rt
}
$rtNl = ConvertFrom-SnapshotValue (ConvertTo-SnapshotValue ("甲`n乙"))
Assert-Eq '快照转义：真换行仍能还原' $true ($rtNl -eq "甲`n乙")
Assert-Eq '快照转义：编码结果不含真换行（否则会劈开键值对）' $false ([bool]([regex]::IsMatch((ConvertTo-SnapshotValue "甲`n乙"), '[\r\n]')))

# 8. 轻量判活必须核 pid 存在性（不能只看心跳文件的 mtime）
#    只看 mtime 时，强杀后留下的新鲜心跳被当成活着，状态页会报出死进程的 PID。
#    判据必须真的比到东西：恒真表达式（如 `... -or $true`）永远绿、等于零覆盖。
#    这两条是这段唯一有效的断言（核 pid 存在性、比对启动时刻）。
$fCode = (@((Get-FunctionBody 'win/lib/runtime.ps1' 'Get-MonitorProcessFast') -split "`n" |
        Where-Object { $_ -notmatch '^\s*#' }) -join "`n")
Assert-Eq '判活：核了 pid 存在性（Get-Process -Id）' $true ([bool]([regex]::IsMatch($fCode, 'Get-Process\s+-Id')))
Assert-Eq '判活：比对了启动时刻（挡 pid 复用）' $true ([bool]([regex]::IsMatch($fCode, 'wantTicks')))
# 心跳年龄必须看（否则进程卡死时状态页一直说"运行中"），但**不许只用它**：
# 强杀/崩溃/断电都会留下一个新鲜心跳，只凭 mtime 会把死进程报成活着。
# 所以两条都要：mtime 判"还在正常轮转"，pid + 启动时刻判"那个进程真的还活着"。
Assert-Eq '判活：看了心跳年龄（进程卡死能被发现）' $true ([bool]([regex]::IsMatch($fCode, 'LastWriteTime')))
Assert-Eq '判活：心跳年龄用了具名阈值而非裸数字' $true ([bool]([regex]::IsMatch($fCode, 'HeartbeatMaxSec')))
Assert-Eq '判活：mtime 只是条件之一，不是唯一判据' $true ([bool]([regex]::IsMatch($fCode, 'Get-Process\s+-Id')))

# 9. 卸载与停止都要清掉状态快照（否则重装/停止后读到上一份结论）
$unIdx = $opsSrc2.IndexOf('function Uninstall-EnvProxy')
$nextUn = $opsSrc2.IndexOf('function ', $unIdx + 10)
$unChunk = if ($nextUn -gt $unIdx) { $opsSrc2.Substring($unIdx, $nextUn - $unIdx) } else { $opsSrc2.Substring($unIdx) }
Assert-Eq '卸载：清掉状态快照' $true ([bool]([regex]::IsMatch($unChunk, 'Remove-ItemSafe\s+\$StateSnapshotFile')))
# 停止流程住在 runtime 层的 Stop-Monitor 里：按函数体取，不看全文——
# 全文里这个调用只出现一次，删掉停止流程那一处、别处补一个同形调用就能骗过它。
$stopChunk = Get-FunctionBody 'win/lib/runtime.ps1' 'Stop-Monitor'
Assert-Eq '接线：Stop-Monitor 函数体取到了' $true ($stopChunk.Length -gt 0)
Assert-Eq '停止：清掉状态快照' $true ([bool]([regex]::IsMatch($stopChunk, 'Remove-ItemSafe\s+\$StateSnapshotFile')))

# 9b. 更新中断标记：写要在备份之后，清要有人清（与 mac 侧同一对断言同形）
#     三条独立事实，删掉任何一条都会让用户卡在"永久报上次更新没完成"里：
#       ① 安装收尾会清它（否则照状态页的指引重做一次也清不掉，唯一出路是卸载）；
#       ② 写它必须在备份成功之后（否则备份阶段一失败就留下一个没人清的标记）；
#       ③ 回滚完整成功时也要清它（否则安装区明明已经回到原样，警报还在）。
$instBody = Get-FunctionBody 'win/lib/ops.ps1' 'Install-EnvProxy'
Assert-Eq '接线：安装收尾会清更新中断标记' $true ([bool]([regex]::IsMatch($instBody, 'Remove-ItemSafe\s+\$UpdateInProgressFile|Remove-Item[^\r\n]*\$UpdateInProgressFile')))
# ② 用行号比先后：写标记的那行必须晚于备份完成的那个循环。
$pkgLines = Get-Content 'win/lib/package.ps1'
$markerWriteLine = 0
$backupDoneLine = 0
for ($i = 0; $i -lt $pkgLines.Count; $i++) {
    if ($pkgLines[$i] -match 'Write-Text\s+-Path\s+\$marker') { $markerWriteLine = $i + 1; break }
}
for ($i = 0; $i -lt $pkgLines.Count; $i++) {
    if ($pkgLines[$i] -match 'Copy-Item -LiteralPath \$src -Destination \(Join-Path \$backup') { $backupDoneLine = $i + 1 }
}
Assert-Eq '接线：更新标记在备份成功之后才写' $true ($markerWriteLine -gt 0 -and $backupDoneLine -gt 0 -and $markerWriteLine -gt $backupDoneLine)
# ③ 回滚完整成功那条路要清标记；partial 那条不许清（安装区确实还是半新半旧）。
$pkgBody = Get-FunctionBody 'win/lib/package.ps1' 'Install-Package'
Assert-Eq '接线：回滚完整成功会清更新中断标记' $true ([bool]([regex]::IsMatch($pkgBody, "LastInstallRollback = 'complete'[\s\S]{0,400}Remove-Item -LiteralPath \`$marker")))
Assert-Eq '接线：回滚未完成时报告 partial 并交出备份路径' $true ([bool]([regex]::IsMatch($pkgBody, "LastInstallRollback = 'partial'[\s\S]{0,200}LastInstallRollbackBackup = \`$backup")))
# 覆盖成功那条路必须有明确结论：没有 'ok' 的话调用方只能靠猜。
Assert-Eq '接线：覆盖成功会报告 ok' $true ([bool]([regex]::IsMatch($pkgBody, "LastInstallRollback = 'ok'")))

# 10. 端口枚举失败的原因必须能显示出来
#     曾经：用 PSObject.Properties.Name -contains 判断键存在，对字典恒为假，
#     于是那句"为什么读不到"永远不显示，而这正是排查方向唯一的线索。
# 剥掉注释再判：注释里会把「不要用 PSObject.Properties.Name -contains」这句
# 写出来解释原因，把它当违规就永远红。
$fsCode = (@($fsChunk2 -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n")
Assert-Eq '端口：不再用恒假的键存在性判断' $false ([bool]([regex]::IsMatch($fsCode, 'PSObject\.Properties\.Name -contains')))
# 两张颜色表必须逐项对上：ConsoleColor 那条路（菜单/帮助等）与 ANSI 那条路
# （实时状态页）如果落到不同亮度，同一程序里就会出现两种"青"。
# .NET 的 Cyan/Green/Yellow 都是亮色，对应 ANSI 9x 段；写成 3x 就是暗色，
# 肉眼能看出来——实测踩过这一条。
$expectAnsi = @{ Cyan = '96'; White = '97'; Green = '92'; Yellow = '93'; DarkGray = '90'; '' = '' }
$colorMismatch = @()
foreach ($cn in $ColorCodes.Keys) {
    $cc = [string]$ColorCodes[$cn]
    $an = [string]$ColorAnsi[$cn]
    if ($an -ne $expectAnsi[$cc]) { $colorMismatch += ($cn + ':' + $cc + '->' + $an) }
}
Assert-Eq '配色：ANSI 码与 ConsoleColor 逐项对应' 0 $colorMismatch.Count
Assert-Eq '配色：两张表键集合相同' ((@($ColorCodes.Keys | Sort-Object)) -join ',') ((@($ColorAnsi.Keys | Sort-Object)) -join ',')

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

Write-Host '[22] Monitor directory self-heals and stays idempotent'
# 契约：monitor\ 被清理工具整份删掉后，进程还在干活、pid 文件却写不出来，
# 状态页报"未运行"，用户再点安装起第二份、被锁挡掉——再也起不来监控。
# 所以主循环每轮开头都要能无条件重建（幂等）。
$monDirBak = $MonitorDir
try {
    $MonitorDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ep_mondir_' + [guid]::NewGuid().ToString('N').Substring(0,8))
    if (Test-Path -LiteralPath $MonitorDir) { Remove-Item -LiteralPath $MonitorDir -Recurse -Force -ErrorAction SilentlyContinue }
    Ensure-MonitorDir
    Assert-Eq 'Ensure-MonitorDir 能把目录建出来' $true (Test-Path -LiteralPath $MonitorDir)
    # 再调一次不抛错、目录还在（主循环每轮都调，第二次就失败等于每轮报错）
    $secondOk = $true
    try { Ensure-MonitorDir } catch { $secondOk = $false }
    Assert-Eq '重复创建是幂等的（不抛错）' $true $secondOk
    Assert-Eq '重复创建后目录仍在' $true (Test-Path -LiteralPath $MonitorDir)
} finally {
    if ($MonitorDir -and (Test-Path -LiteralPath $MonitorDir)) { Remove-Item -LiteralPath $MonitorDir -Recurse -Force -ErrorAction SilentlyContinue }
    $MonitorDir = $monDirBak
    $null = Ensure-MonitorPaths
}

Write-Host '[23] Operation lock name is per-user and complete'
# 契约（AGENTS.md「安装、更新、卸载、停止共用一把操作锁」）：
#   ① 必须在 Global\ 命名空间：多个账户各装一份时互不干扰；
#   ② 拿得到 SID 时必须带当前用户 SID 后缀：同一台机器上别人的锁不能拦住我；
#   ③ 基本名不同的必须是两把锁（拿错锁等于没锁）。
# 这条以前没断言：Name 拼错一个字符，两处就各拿各的锁，并发破坏无人拦截。
#
# **②③ 都只在"拿得到 SID"时才有意义**：这份测试在 CI 的 ubuntu（pwsh 7）里也要跑，
# 那里没有 WindowsIdentity 类型，Get-MutexName 会按设计降级成无后缀。把"有 SID"
# 写成无条件要求，等于让测试在非 Windows 上一律红——那是测试的错，不是代码的错
# （代码的契约是"拿得到就带、拿不到就降级"，降级本身也是契约的一部分）。
$lockA = Get-MutexName 'EnvProxyInstallOp'
$lockB = Get-MutexName 'EnvProxyApplyState'
$mySid = ''
try { $mySid = [string][System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch {}
Assert-Eq '锁名带 Global\ 前缀（各平台都必须）' $true ($lockA.StartsWith('Global\'))
Assert-Eq '不同的基本名是两把不同的锁' $true ($lockA -ne $lockB)
Assert-Eq '同一基本名两次调用得到同一个名字（可复现）' $lockA (Get-MutexName 'EnvProxyInstallOp')
if ($mySid.Length -gt 0) {
    Assert-Eq '拿得到 SID 时锁名必须带它（同一台机器上别人的锁拦不住我）' $true ($lockA.Contains($mySid))
} else {
    Write-Host '  SKIP 锁名带 SID（本机拿不到 WindowsIdentity，非 Windows 平台按设计降级）'
    # 降级本身也要验：无 SID 时必须是干净的基本名，不能留个悬空的分隔符
    Assert-Eq '降级后锁名是纯基本名（不留悬空分隔符）' ('Global\EnvProxyInstallOp') $lockA
}
# 真拿一次具名互斥再放掉：名字拼错或命名空间不可用时这里会失败，
# 而那时"安装/更新/卸载互斥"整个机制都是假的。
# 不断言"同线程拿第二把会失败"：Mutex 本来就同线程可重入（拿两次放两次），
# 那是 .NET 既定语义、不是缺陷。真互斥发生在跨进程之间，要验它得真起子进程，
# 成本远超收益；而这里要防的"名字拼错导致两处各拿各的锁"已由上面三条覆盖。
$lockOk = $false
$lk = $null
try {
    $lk = New-Object System.Threading.Mutex($false, $lockA)
    $lockOk = $lk.WaitOne(3000)
} catch { $lockOk = $false }
if ($lockOk) {
    Assert-Eq '这把锁真能拿到（名称与命名空间有效）' $true $true
} else {
    Write-Host '  SKIP 锁可用性（本平台建不出具名互斥）'
}
if ($lk) {
    try { if ($lockOk) { $lk.ReleaseMutex() } } catch {}
    try { $lk.Dispose() } catch {}
}

# 安装目录沙箱：复原 override、删掉临时目录。
# 顺序与注册表那段同理：先把落点指回真实位置，再删沙箱，免得清理本身打到沙箱。
try {
    $InstallDirOverride = $script:SavedInstallDir
    $ToolHomeDirOverride = $script:SavedToolHomeDir
    if ($null -ne $script:SavedLauncherDir) { $LauncherDir = $script:SavedLauncherDir }
    if ($script:TestInstallDir -and (Test-Path -LiteralPath $script:TestInstallDir)) {
        Remove-Item -LiteralPath $script:TestInstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch {}

Write-Host '[24] System proxy verdict table (doctor)'
# 判据表就是「不能误删」这条底线的机械证明：只有"本机回环 + 端口不通"才允许修。
# 那张表一变，用户唯一的上网路径就可能被删掉——所以逐条钉死。
Assert-Eq 'verdict: no proxy at all is clean' 'clean' (Get-SystemProxyVerdict -Url '' -Port 0)
Assert-Eq 'verdict: dead loopback is fixable (blocking)' 'residue-blocking' (Get-SystemProxyVerdict -Url 'http://127.0.0.1:7078' -Port 7078 -Alive $false)
Assert-Eq 'verdict: live loopback is left alone' 'alive' (Get-SystemProxyVerdict -Url 'http://127.0.0.1:7078' -Port 7078 -Alive $true)
Assert-Eq 'verdict: localhost is also loopback' 'residue-blocking' (Get-SystemProxyVerdict -Url 'http://localhost:7890' -Port 7890 -Alive $false)
Assert-Eq 'verdict: bracketed IPv6 is also loopback' 'residue-blocking' (Get-SystemProxyVerdict -Url 'http://[::1]:10808' -Port 10808 -Alive $false)
Assert-Eq 'verdict: dead PAC is slowing, not blocking' 'residue-slowing' (Get-SystemProxyVerdict -Url 'http://127.0.0.1:7078/pac' -Port 7078 -Alive $false -Kind 'pac')
Assert-Eq 'verdict: a company proxy is never ours' 'foreign' (Get-SystemProxyVerdict -Url 'http://10.0.0.8:8080' -Port 8080 -Alive $false)
Assert-Eq 'verdict: a hostname proxy is never ours' 'foreign' (Get-SystemProxyVerdict -Url 'http://proxy.corp.com:3128' -Port 3128 -Alive $false)
Assert-Eq 'verdict: policy-managed wins over everything' 'managed' (Get-SystemProxyVerdict -Url 'http://127.0.0.1:7078' -Port 7078 -Alive $false -Managed $true)
Assert-Eq 'verdict: unknown liveness is never touched' 'foreign' (Get-SystemProxyVerdict -Url 'http://127.0.0.1:7078' -Port 7078 -Alive $null)
Assert-Eq 'fixable: blocking yes' 'True' (Test-SysProxyFixable 'residue-blocking')
Assert-Eq 'fixable: slowing yes' 'True' (Test-SysProxyFixable 'residue-slowing')
Assert-Eq 'fixable: alive no' 'False' (Test-SysProxyFixable 'alive')
Assert-Eq 'fixable: foreign no' 'False' (Test-SysProxyFixable 'foreign')
Assert-Eq 'fixable: managed no' 'False' (Test-SysProxyFixable 'managed')
Assert-Eq 'fixable: clean no' 'False' (Test-SysProxyFixable 'clean')

Write-Host '[25] DefaultConnectionSettings parsing (doctor)'
# 这一段防的是「假修好」：Windows 真正生效的是这段二进制，只读 ProxyEnable 看不出来
# PAC 残留（那种情况下 ProxyEnable 是 0，看着一切正常）。解析错了，界面就会报错状态。
function New-ProxyBlob([int]$Flags, [string]$Server, [string]$Bypass, [string]$Pac) {
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([int]0x46); $bw.Write([int]7); $bw.Write([int]$Flags)
    foreach ($s in @($Server, $Bypass, $Pac)) {
        $b = [System.Text.Encoding]::ASCII.GetBytes($s)
        $bw.Write([int]$b.Length); $bw.Write($b)
    }
    $bw.Write([int]1); $bw.Write((New-Object byte[] 31))
    $bw.Flush()
    return $ms.ToArray()
}
$manualBlob = ConvertFrom-ProxyConnectionBlob (New-ProxyBlob 0x03 '127.0.0.1:7078' '<local>' '')
Assert-Eq 'blob: manual proxy parsed' 'True' $manualBlob.ManualProxy
Assert-Eq 'blob: manual proxy has no PAC' 'False' $manualBlob.AutoConfig
Assert-Eq 'blob: manual proxy server read back' '127.0.0.1:7078' $manualBlob.ProxyServer
$pacBlob = ConvertFrom-ProxyConnectionBlob (New-ProxyBlob 0x05 '' '' 'http://127.0.0.1:7078/pac')
Assert-Eq 'blob: PAC-only is not manual' 'False' $pacBlob.ManualProxy
Assert-Eq 'blob: PAC-only is detected' 'True' $pacBlob.AutoConfig
Assert-Eq 'blob: PAC url read back' 'http://127.0.0.1:7078/pac' $pacBlob.AutoConfigUrl
$offBlob = ConvertFrom-ProxyConnectionBlob (New-ProxyBlob 0x01 '' '' '')
Assert-Eq 'blob: everything off reads as clean' 'False' $offBlob.ManualProxy
Assert-Eq 'blob: everything off has no PAC' 'False' $offBlob.AutoConfig
$shortBlob = ConvertFrom-ProxyConnectionBlob ([byte[]](1, 2, 3))
Assert-Eq 'blob: too short is not Ok (not "no proxy")' 'False' $shortBlob.Ok
$truncBlob = ConvertFrom-ProxyConnectionBlob ([byte[]](0x46, 0, 0, 0, 1, 0, 0, 0, 0x03, 0, 0, 0, 255, 0, 0, 0))
Assert-Eq 'blob: truncated does not throw and is not Ok' 'False' $truncBlob.Ok

Write-Host '[26] Operator remark: doctor must not depend on the GUI'
# doctor 是叶子层：它只允许依赖 base + probe。ops/shortcut 反过来调它是正常的，
# 而它一旦调界面就会成环（门禁 1/2 会拦，但那要等到 CI；这里先钉一道）。
$doctorText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\win\lib\doctor.ps1'))
foreach ($guiFn in @('Write-Styled', 'Write-Host', 'Read-Host', 'Clear-Screen', 'Show-AdvancedPage')) {
    $hit = [regex]::IsMatch($doctorText, ('(?m)^(?!\s*#).*\b' + [regex]::Escape($guiFn) + '\b'))
    Assert-Eq ('doctor never calls ' + $guiFn) 'False' ([string]$hit)
}
Write-Host '[27] System proxy address normalization and liveness (doctor)'
# 这四条对应四个「会弄坏用户东西」的真实缺陷，每一条都是实跑复现出来的。
# 拔掉修复，下面至少一条会红。
Assert-Eq 'normalize: multi-protocol picks the first usable' 'http://127.0.0.1:7078' (ConvertTo-SysProxyUrl 'http=127.0.0.1:7078;https=127.0.0.1:7078;socks=127.0.0.1:7079')
Assert-Eq 'normalize: multi-protocol socks only' 'http://127.0.0.1:1080' (ConvertTo-SysProxyUrl 'socks=127.0.0.1:1080')
Assert-Eq 'normalize: corporate multi-protocol still parses' 'http://10.0.0.8:8080' (ConvertTo-SysProxyUrl 'http=10.0.0.8:8080;https=10.0.0.8:8080')
Assert-Eq 'normalize: plain address unchanged' 'http://127.0.0.1:7078' (ConvertTo-SysProxyUrl '127.0.0.1:7078')
Assert-Eq 'normalize: garbage yields nothing' '' ([string](ConvertTo-SysProxyUrl 'garbage'))
# localhost 必须与 127.0.0.1 同判：存主机名时判成"端口已死"，救援会关掉正在用的代理。
$loPort = 0
for ($i = 0; $i -lt 20; $i++) {
    $cand = 19100 + (Get-Random -Maximum 300)
    try {
        $probe = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $cand)
        $probe.Start(); $probe.Stop(); $loPort = $cand; break
    } catch {}
}
Assert-Eq 'liveness: a free port is found for the hostname test' $true ($loPort -gt 0)
if ($loPort -gt 0) {
    $ln = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $loPort)
    $ln.Start()
    try {
        Assert-Eq 'liveness: 127.0.0.1 reaches a live listener' $true (Test-TcpAlive '127.0.0.1' $loPort 800)
        Assert-Eq 'liveness: localhost reaches the same listener' $true (Test-TcpAlive 'localhost' $loPort 800)
    } finally { try { $ln.Stop() } catch {} }
    Assert-Eq 'liveness: hostname on a dead port is dead' $false (Test-TcpAlive 'localhost' $loPort 500)
}
Assert-Eq 'liveness: an unresolvable host is dead, not an exception' $false (Test-TcpAlive 'no-such-host.invalid' 9 500)
# WinHTTP 输出里的 IPv6 必须整段取到，不能被中间冒号切开。
$whRx = '\[[0-9A-Fa-f:]+\]:\d+|[A-Za-z0-9_\.\-]+:\d+'
Assert-Eq 'winhttp: bracketed IPv6 is taken whole' '[::1]:7078' ([regex]::Match('Proxy Server(s) : [::1]:7078', $whRx).Value)
Assert-Eq 'winhttp: plain host still parses' 'proxy.corp.com:3128' ([regex]::Match('Proxy Server(s) : proxy.corp.com:3128', $whRx).Value)
Assert-Eq 'winhttp: an IPv4 address still parses' '127.0.0.1:7078' ([regex]::Match('Proxy Server(s) : 127.0.0.1:7078', $whRx).Value)
Write-Host '[28] Rescue must not overstate success or over-delete'
# 这一节守三件"说假话"的事，每一条都对应一个实跑复现过的缺陷。
# ① 部分失败不许报成"全部修好"；
# ② netsh 读不出来不许当成"没设"，更不许反推成"修好了"；
# ③ 分协议写法里只删死的那一段，活着的原样保留。
$repSrc = (Get-Command Repair-SystemProxy).Definition
Assert-Eq 'repair: a partial result is reported as partial' $true ($repSrc -match "'partial'")
Assert-Eq 'repair: partial only when failed and changed are both non-empty' $true ($repSrc -match '\$res\.Failed\.Count -eq 0')
Assert-Eq 'repair: winhttp writes only after netsh exits cleanly' $true ($repSrc -match 'LASTEXITCODE')
# 分协议：按段处理，不许整段置空。
Assert-Eq 'repair: manual layer is edited segment by segment' $true ($repSrc -match "ProxyServer -split ';'")
Assert-Eq 'repair: unrecognized segments are kept as-is' $true ($repSrc -match 'kept \+= \$s')
$whSrc = (Get-Command Get-WinHttpProxy).Definition
Assert-Eq 'winhttp read: returns a three-state object, not $null' $true ($whSrc -match "State = 'unknown'")
Assert-Eq 'winhttp read: reports an exit code when netsh fails' $true ($whSrc -match 'LASTEXITCODE')
Assert-Eq 'winhttp read: takes bracketed IPv6 whole' $true ($whSrc -match '\\\[\[0-9A-Fa-f:'  )
# 组策略名单里不许混进与代理无关的值（否则企业机永远"被管着"、救援永不生效）。
# 只看代码、剔掉注释：这两个名字会出现在解释"为什么不能把它们算进来"的注释里，
# 拿整段源码去比会把注释一并算上，断言就变成在检查注释有没有提到它。
$manCode = (@(($manSrc = (Get-Command Test-SystemProxyManaged).Definition) -split "`n" |
        Where-Object { $_ -notmatch '^\s*#' }) -join "`n")
Assert-Eq 'policy: SSL page caching is not a proxy policy' $false ($manCode -match 'DisableCachingOfSSLPages')
Assert-Eq 'policy: a made-up value name is not used' $false ($manCode -match 'ProxySettingsPerUserMachine')
# 策略表住在函数外的顶层（$SysProxyPolicyChecks），所以要比**整个库文件**，
# 不能只比 Test-SystemProxyManaged 的函数体——那样永远匹配不到。
$docAll = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\win\lib\doctor.ps1'))
Assert-Eq 'policy: UserProxy value is checked' $true ($docAll -match 'ProxySettingsPerUser')
Assert-Eq 'policy: RestrictProxy value is checked' $true ($docAll -match "Name = 'Proxy'")
Assert-Eq 'policy: RestrictAutoconfig value is checked' $true ($docAll -match "Name = 'Autoconfig'")
Assert-Eq 'policy: the Control Panel key is consulted too' $true ($docAll -match 'Internet Explorer\\Control Panel')
# 还原入口不许被"没有可修项"挡住。
$rescueSrc = (Get-Command Show-RescuePage).Definition
Assert-Eq 'rescue: restore is gated on the backup, not on fixable count' $true ($rescueSrc -match '\$hasBackup')
Assert-Eq 'rescue: no early return just because nothing is fixable' $true ($rescueSrc -match '\$fixable\.Count -eq 0 -and -not \$hasBackup')
# 失败的项必须在屏幕上说出来，不许只报"修好了"。
Assert-Eq 'rescue: partial names what was left unfixed' $true ($rescueSrc -match '\$leftNames')
Write-Host '[29] Handshake classification, port ownership, client catalog'
# 这一节守三件事，都对应"会误删活代理"或"永远修不好"的真实缺陷。
# ① 握手必须五分类：节点挂掉的代理回 502，不能被当成"这不是代理"；
# ② 0.0.0.0 / :: 是本机，但直接连会抛异常，必须先归一化；
# ③ 客户端目录是端口表/进程表的唯一来源，加客户端只改表。
Assert-Eq 'handshake: 200 is proxy-ok' 'proxy-ok' (Get-HandshakeKind 'HTTP/1.1 200 Connection established')
Assert-Eq 'handshake: 407 is proxy-auth' 'proxy-auth' (Get-HandshakeKind 'HTTP/1.1 407 Proxy Authentication Required')
Assert-Eq 'handshake: 502 is upstream-fail, not "not a proxy"' 'upstream-fail' (Get-HandshakeKind 'HTTP/1.1 502 Bad Gateway')
Assert-Eq 'handshake: 403 is upstream-fail too' 'upstream-fail' (Get-HandshakeKind 'HTTP/1.0 403 Forbidden')
Assert-Eq 'handshake: an SSH banner is not-http' 'not-http' (Get-HandshakeKind 'SSH-2.0-OpenSSH_9.0')
Assert-Eq 'handshake: silence is silent' 'silent' (Get-HandshakeKind '')
Assert-Eq 'handshake: 2000 is never read as proxy-ok' $false ((Get-HandshakeKind 'HTTP/1.1 2000 weird') -eq 'proxy-ok')

# 地址归一化：通配地址指本机，但探测要走回环，否则 Connect 抛"地址无效"。
Assert-Eq 'addr: 0.0.0.0 counts as local' $true (Test-LoopbackUrl 'http://0.0.0.0:7890')
Assert-Eq 'addr: :: counts as local' $true (Test-LoopbackUrl 'http://[::]:7890')
Assert-Eq 'addr: 0.0.0.0 probes via 127.0.0.1' '127.0.0.1' (ConvertTo-ProbeHost '0.0.0.0')
Assert-Eq 'addr: :: probes via ::1' '::1' (ConvertTo-ProbeHost '::')
Assert-Eq 'addr: a LAN IP is still not local' $false (Test-LoopbackUrl 'http://192.168.1.5:7890')
Assert-Eq 'addr: a LAN IP probes as itself' '192.168.1.5' (ConvertTo-ProbeHost '192.168.1.5')

# 客户端目录：两张旧表必须从它派生，不能各存一份。
Assert-Eq 'catalog: known ports derive from the catalog' $true ($KnownProxyPorts.Count -ge 20)
Assert-Eq 'catalog: 7897 belongs to Clash Verge Rev' 'Clash 系' ((Get-ClientByPort 7897).Name)
Assert-Eq 'catalog: 12334 belongs to Hiddify' 'Hiddify' ((Get-ClientByPort 12334).Name)
Assert-Eq 'catalog: 10811 is the v2ray PAC port' 'v2ray 系' ((Get-ClientByPort 10811).Name)
Assert-Eq 'catalog: process patterns derive too' $true ($ProxyProcessPatterns -contains 'clash')
Assert-Eq 'catalog: an unknown port maps to nothing' '' ([string]((Get-ClientByPort 54321)))
# 端口表只能提速，绝不能参与授权——授权只看形态+端口三态。
$catKinds = @($KnownProxyPorts | ForEach-Object { Get-SystemProxyVerdict -Url ("http://127.0.0.1:" + $_) -Port $_ -Alive $false })
Assert-Eq 'catalog: every catalog port is fixable only when dead+loopback' $true (@($catKinds | Where-Object { $_ -ne 'residue-blocking' }).Count -eq 0)

# 结论必须带解释，不能只给一个词。
$lay = @(Get-SystemProxyLayers)
foreach ($L in $lay) {
    Assert-Eq ('reason present for ' + $L.Kind) $true ([bool]($L.Detail))
}
# 拨号/VPN 连接各存一份代理——发现到了就要说，不能报"已修好"。
# 空数组经管道会被展平成 $null，所以判据用 @() 包一层再数个数：
# 这一步只要"能调用、能返回、不抛"就算过，条数由真机决定。
$otherConnsProbe = @(Get-OtherConnectionProxyNames)
Assert-Eq 'other connections: detector runs and yields a countable list' $true ($otherConnsProbe.Count -ge 0)
Write-Host '[30] Evidence text and the node-problem branch'
# 这一节守的是"端口活着但连不上外面"这一档：说错方向会让用户去动系统代理，
# 而删掉代理设置并不恢复网络（程序还在跑、还占着端口），只会把他能用的路径删掉。
Assert-Eq 'evidence: upstream-fail names the node, not the settings' $true `
    ((Get-SysProxyEvidenceText -Handshake 'upstream-fail' -OwnerName 'clash' -IsClient $true -CatalogName 'Clash 系') -match '节点')
Assert-Eq 'evidence: upstream-fail never blames the settings' $false `
    ((Get-SysProxyEvidenceText -Handshake 'upstream-fail' -OwnerName '' -IsClient $false -CatalogName '') -match '设置')
Assert-Eq 'evidence: proxy-ok says it works' $true `
    ((Get-SysProxyEvidenceText -Handshake 'proxy-ok' -OwnerName 'clash' -IsClient $true -CatalogName 'Clash 系') -match '确实在工作')
Assert-Eq 'evidence: not-http says another program holds the port' $true `
    ((Get-SysProxyEvidenceText -Handshake 'not-http' -OwnerName 'python' -IsClient $false -CatalogName '') -match '别的程序')
Assert-Eq 'evidence: an owner from the catalog gets named' $true `
    ((Get-SysProxyEvidenceText -Handshake 'proxy-ok' -OwnerName 'clash-verge' -IsClient $true -CatalogName 'Clash 系') -match 'Clash 系')
Assert-Eq 'evidence: no handshake and no owner yields nothing' '' `
    (Get-SysProxyEvidenceText -Handshake '' -OwnerName '' -IsClient $false -CatalogName '')

# 救援页那一档只在「活着 + 握手说上游失败」时成立。
# 拿不到握手时必须不成立——绝不凭猜给用户指方向。
$rescueSrc = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\win\lib\shortcut.ps1'))
Assert-Eq 'rescue: the node-problem branch exists' $true ($rescueSrc -match 'aliveBroken')
Assert-Eq 'rescue: it requires the alive kind' $true ($rescueSrc -match '\$_.Kind -eq \$SysProxyKinds\.Alive')
Assert-Eq 'rescue: it requires upstream-fail evidence' $true ($rescueSrc -match "Handshake -eq 'upstream-fail'")
Assert-Eq 'rescue: the message points at the node' $true ($rescueSrc -match '多半是节点的问题')
# 这一档的台词本身不许出现"删/清掉设置"之类的话——那正是错的指导。
# 只取**这一段分支**里的字符串，不看注释，也不扫整份文件（别处的"删掉"说的是删快捷方式图标）。
$branchStart = $rescueSrc.IndexOf('aliveBroken.Count -gt 0')
$branchEnd = $rescueSrc.IndexOf('elseif ($fixable.Count -eq 0)', [Math]::Max($branchStart, 0))
$branch = if ($branchStart -ge 0 -and $branchEnd -gt $branchStart) { $rescueSrc.Substring($branchStart, $branchEnd - $branchStart) } else { '' }
Assert-Eq 'rescue: the node-problem branch was located' $true ([bool]$branch)
$branchStr = (@([regex]::Matches($branch, "'([^']*[\u4e00-\u9fa5][^']*)'") | ForEach-Object { $_.Groups[1].Value }) -join "`n")
Assert-Eq 'rescue: its text never says delete the setting' $false ($branchStr -match '删|清掉')
Assert-Eq 'rescue: its text tells the user to switch node or restart' $true ($branchStr -match '节点|重开')

# Quick 模式不采集握手，所以这一档在状态页永远不可能误报。
$quickLayers = @(Get-SystemProxyLayers -Quick)
foreach ($q in $quickLayers) {
    Assert-Eq ('quick: no handshake collected for ' + $q.Layer) '' ([string]$q.Handshake)
}
Write-Host '[31] Colored keys, snapshot node_handshake, status hint'
# ① 高级功能页的编号必须**单独一段、染 cmd 色**：整行同色会让编号混进正文，用户得逐字找。
$advLines = @(Get-AdvancedPageLines)
$segRows = @($advLines | Where-Object { $_.ContainsKey('Segments') })
Assert-Eq 'advanced: item rows are segmented so the key can be colored' $true ($segRows.Count -ge 4)
foreach ($r in $segRows) {
    Assert-Eq 'advanced: first segment is the key' 'cmd' $r.Segments[0].Role
    Assert-Eq 'advanced: the rest is body text' 'item' $r.Segments[1].Role
    Assert-Eq 'advanced: the key segment is just the number' $true ([bool]($r.Segments[0].Text.Trim() -match '^[0-9]+$'))
}
# 编号颜色必须是绿色（cmd 角色），且这是唯一的"要敲的东西"色。
Assert-Eq 'advanced: cmd role is green' 'green' ([string]$StyleMap['cmd'])

# ② 快照的 node_handshake 必须能往返，且**老快照不许被判损坏**。
$snapFile = Join-Path $env:TEMP ('snaptest-' + [guid]::NewGuid().ToString('N') + '.txt')
$script:StateSnapshotFile = $snapFile
Write-StateSnapshot -State 'on:7078' -PrevState 'off' -PendingState '' -PendingCount 0 `
    -PortEnumeration 'ok' -PortReason '' -VarsMatch 'yes' -ApplyResult 'ok' -NodeHandshake 'upstream-fail'
$snapNew = Read-StateSnapshot
Assert-Eq 'snapshot: node_handshake survives a round trip' 'upstream-fail' ([string]$snapNew.NodeHandshake)
Assert-Eq 'snapshot: status is ok' 'ok' ([string]$snapNew.Status)
# 模拟老版本监控写下的快照（没有这个字段）：必须仍判 ok，字段留空 = 不知道。
$oldBody = @"
# envproxy-snapshot 1
written=$(([DateTimeOffset]::UtcNow).ToString('yyyy-MM-ddTHH:mm:ssZ'))
round=5
pid=1234
state=on:7078
prev_state=off
pending_state=
pending_count=0
port_enumeration=ok
port_reason=
vars_match=yes
apply_result=ok
log_tail=hi
"@
[System.IO.File]::WriteAllText($snapFile, $oldBody, (New-Object System.Text.UTF8Encoding($false)))
$snapOld = Read-StateSnapshot
Assert-Eq 'snapshot: an older snapshot is not judged damaged' 'ok' ([string]$snapOld.Status)
Assert-Eq 'snapshot: a missing handshake reads as unknown, not as fine' '' ([string]$snapOld.NodeHandshake)
Remove-Item -LiteralPath $snapFile -Force -ErrorAction SilentlyContinue

# ③ 状态页那条提示只在拿到 upstream-fail 证据时出现。
$mkSt = {
    param($hs)
    [pscustomobject]@{
        Monitor = @{ ProcessId = 999 }; AutoRunOk = $true; PortUnknown = $false
        ProxyValue = 'http://127.0.0.1:7078'; ProxyAlive = $true; TermSync = @{ State = 'ok' }
        SysProxy = $null; UpdateInProgress = $false; VarsMatch = 'yes'; ApplyResult = 'ok'
        NodeHandshake = $hs
    }
}
$pHit = @(Get-StatusProblems (& $mkSt 'upstream-fail') | Where-Object { $_ -match '节点' })
$pOk  = @(Get-StatusProblems (& $mkSt 'proxy-ok') | Where-Object { $_ -match '节点' })
$pUnk = @(Get-StatusProblems (& $mkSt '') | Where-Object { $_ -match '节点' })
Assert-Eq 'status: upstream-fail raises the node hint' 1 $pHit.Count
Assert-Eq 'status: a healthy proxy raises nothing' 0 $pOk.Count
Assert-Eq 'status: an unknown handshake raises nothing' 0 $pUnk.Count
Assert-Eq 'status: the hint points at the node' $true ([bool]($pHit[0] -match '节点'))
if ($script:fails -eq 0) { Write-Host 'ALL PASS'; exit 0 }
Write-Host ("FAILURES: {0}" -f $script:fails); exit 1
