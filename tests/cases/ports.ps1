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
$entryPath = Join-Path $TestRoot 'win/envproxy.ps1'
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
$contractFile = Join-Path $TestRoot 'tests/asset-cases.txt'
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
