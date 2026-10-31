
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

# 项目根。**分组用例一律用它拼路径**，不要用 $PSScriptRoot：
# 分组文件住在 tests\cases\，那两个变量在它里面指向 cases\ 而不是 tests\。
# 这个变量是唯一权威处，以后再挪目录也不用改各组。
$TestRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

. (Join-Path $TestRoot 'win/envproxy.ps1')

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

# 把 win\lib 下所有库的源码合并成一段文本。
#
# 用途：那些"某个词在整个库里出现/不该出现"的断言。它们关心的是**整个库集合**，
# 不是某个具体文件。写死文件名的话，把库拆开就要来改一遍测试——而拆分不该改变
# 任何被测行为的结论。
function Get-AllLibSource {
    $sb = New-Object System.Text.StringBuilder
    foreach ($f in @(Get-ChildItem 'win\lib' -Filter *.ps1 -File | Sort-Object Name)) {
        [void]$sb.AppendLine([System.IO.File]::ReadAllText($f.FullName))
    }
    return $sb.ToString()
}

# ------------------------------------------------------------------------------
# 用例按被测对象分组，依次点源。
#
# 为什么分组：这个文件曾经是单一文件写到三千八百多行，而且分节顺序已经乱了
# （[5c] 排在 [12] 后面、[7a2] 在 [7b] 前面）。找一条断言的代价随着行数线性上升，
# 而"这条断言在哪"是排查失败时的第一个问题。
#
# 分组判据是**被测对象**，不是行数：改 env 的变量逻辑只打开 cases\env.ps1，
# 不必在一整片里翻。骨架（沙箱、注册表改道、断言函数）留在这个文件，
# 分组只写用例——新加一组就是这里加一行。
#
# 顺序有依赖的地方保留原顺序：前面几组会建立沙箱与假服务器，后面几组用它们。
# ------------------------------------------------------------------------------
$caseDir = Join-Path $PSScriptRoot 'cases'
foreach ($caseName in @('env', 'probe', 'package', 'menu', 'update', 'ports', 'term', 'readme', 'doctor')) {
    $casePath = Join-Path $caseDir ($caseName + '.ps1')
    if (-not (Test-Path -LiteralPath $casePath)) {
        Write-Host ("missing case file: {0}" -f $casePath)
        $script:fails++
        continue
    }
    . $casePath
}

if ($script:fails -eq 0) { Write-Host 'ALL PASS'; exit 0 }
Write-Host ("FAILURES: {0}" -f $script:fails); exit 1
