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
$doctorText = [System.IO.File]::ReadAllText((Join-Path $TestRoot 'win\lib\doctor.ps1'))
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
$docAll = [System.IO.File]::ReadAllText((Join-Path $TestRoot 'win\lib\doctor.ps1'))
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
$rescueSrc = [System.IO.File]::ReadAllText((Join-Path $TestRoot 'win\lib\shortcut.ps1'))
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
# 临时目录必须用 .NET 的 GetTempPath：Linux 上没有 $env:TEMP（那是 Windows 才有的变量），
# Join-Path 收到 null 会让自检在这一步就崩掉——而那会被报成"快照功能坏了"，方向全错。
$snapFile = Join-Path ([System.IO.Path]::GetTempPath()) ('snaptest-' + [guid]::NewGuid().ToString('N') + '.txt')
$global:StateSnapshotFile = $snapFile


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
Get-Content $snapFile -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("    [" + $_ + "]") }
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