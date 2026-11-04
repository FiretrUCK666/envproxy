Write-Host '[32] Inspector registry and the finding contract (insp)'
# 这一节守的是「加一层网络检查 = 表里加一行」这条架构承诺。
# 它一旦破了，每加一层就要改界面、改报告、改备份——那正是要避免的屎山。
# 断言全部落在**机制**上，不落在某个检查器的名字上：删掉任何一层，这几条仍然成立。
try { Assert-DoctorInspectors; Write-Host '  PASS inspector table: every declared function exists' }
catch { Write-Host ('  FAIL inspector table: ' + $_.Exception.Message); $script:fails++ }
# 握手分类：3xx 与 5xx 必须分开。
# 原来两者都归 upstream-fail，于是"某个 web 服务回了 302"会被解释成
# "它是代理，但上游坏了"——方向错了，而且将来谁拿这几类做授权判断就会误判。
$hk = @(
  @{ R='HTTP/1.1 200 Connection established';      W='proxy-ok' },
  @{ R='HTTP/1.1 407 Proxy Authentication Required'; W='proxy-auth' },
  @{ R='HTTP/1.1 502 Bad Gateway';                 W='upstream-fail' },
  @{ R='HTTP/1.1 302 Found';                       W='refused' },
  @{ R='HTTP/1.1 403 Forbidden';                   W='refused' },
  @{ R='HTTP/1.1 2000 NotAStatus';                 W='not-http' },
  @{ R='SSH-2.0-OpenSSH_8.9';                      W='not-http' },
  @{ R='';                                         W='silent' }
)
foreach ($c in $hk) {
    Assert-Eq ("handshake: " + $c.R) $c.W $c.W (Get-HandshakeKind $c.R)
}
Assert-Eq 'inspector: the registry is non-empty' $true (@($DoctorInspectors).Count -gt 0)
# 每个描述符必须有这五列。缺 Id 会让还原点分不清是谁的，缺 Detect 会让那一层静默消失。
foreach ($d in @($DoctorInspectors)) {
    Assert-Eq ('inspector ' + $d.Id + ': has Id') $true ([bool]$d.Id)
    Assert-Eq ('inspector ' + $d.Id + ': has Title') $true ([bool]$d.Title)
    Assert-Eq ('inspector ' + $d.Id + ': has Detect') $true ([bool]$d.Detect)
    $hasFn = $null -ne (Get-Command -Name $d.Detect -ErrorAction SilentlyContinue)
    Assert-Eq ('inspector ' + $d.Id + ': Detect resolves') $true $hasFn
    if ($d.Fix) {
        # 声明了可修就必须有撤销的路，否则用户按 r 时退不回去。
        Assert-Eq ('inspector ' + $d.Id + ': Fix has a Restore') $true ([bool]$d.Restore)
    }
}
# 至少有一层是可修的，否则「修复」这个功能整体不存在了。
Assert-Eq 'inspector: at least one layer is fixable' $true (@($DoctorInspectors | Where-Object { $_.Fix }).Count -gt 0)
# 状态页只跑 Quick 项：任何一层标了 Quick 就必须真的能在 -Quick 下跑出来。
Assert-Eq 'inspector: -Quick runs only the quick ones' 0 `
    (@(Invoke-DoctorCheck -Quick | Where-Object {
        $id = ([string]$_.Id) -replace '\..*$', ''
        $d = Get-DoctorInspector $id
        -not ($d -and $d.Quick)
    }).Count)

# 「这一档能不能修」只有一处判据：Kind 决定档位。
foreach ($k in @('residue-blocking', 'residue-slowing')) {
    Assert-Eq ('kind-level: ' + $k + ' is fixable') 'True' ([string](Test-FindingFixable $k))
}
foreach ($k in @('clean', 'alive', 'foreign', 'managed', 'unreadable')) {
    Assert-Eq ('kind-level: ' + $k + ' is not fixable') 'False' ([string](Test-FindingFixable $k))
}
# 「这一条记录该不该出现在『要修的』里」是另一件事：Kind + 该层有没有 Fix。
# 两件事分开测，是因为它们曾经被搅在一起——DNS 判成 Blocking 却没有 Fix，
# 屏幕于是给了个按下去什么都不做的按钮。
Assert-Eq 'repairable: dns has no fix, so it is not repairable' 'False' `
    ([string](Test-FindingRepairable (New-Finding -Id 'dns.loopback' -Kind 'residue-blocking')))
Assert-Eq 'repairable: sysproxy is repairable' 'True' `
    ([string](Test-FindingRepairable (New-Finding -Id 'sysproxy.layer' -Kind 'residue-blocking')))
Assert-Eq 'repairable: cli-proxy is repairable' 'True' `
    ([string](Test-FindingRepairable (New-Finding -Id 'cli-proxy.git' -Kind 'residue-blocking')))
Assert-Eq 'repairable: a clean layer is not repairable' 'False' `
    ([string](Test-FindingRepairable (New-Finding -Id 'sysproxy.layer' -Kind 'clean')))
# 参数可以是检查器 Id（sysproxy），也可以是完整 Finding Id（sysproxy.direct）。
# 调用点分散在界面各处，有的手里只有 Finding Id；只认一种的后果是
# 另一侧的项全部被判成不可修，屏幕上那一区直接空了而没有任何报错。
Assert-Eq 'repairable: accepts the bare inspector id' 'True' `
    ([string](Test-FindingRepairable (New-Finding -Id 'sysproxy' -Kind 'residue-blocking')))
Assert-Eq 'repairable: accepts a dotted finding id' 'True' `
    ([string](Test-FindingRepairable (New-Finding -Id 'cli-proxy.git' -Kind 'residue-blocking')))
# 「本工具不改、但问题真实存在」的记录必须能与「没问题」分开。
# DNS 指向死端口就是这一类：Kind 是可修档（它确实在挡网络），但那一层没有 Fix。
# 判据若只看 Kind，它会被算进「挡住网络」却修不了；只看 Fix，它会从三个区全部消失。
# 两个都不对的方式都会让屏幕说错话，所以这里把两个维度分别钉住。
$dnsFinding = New-Finding -Id 'dns.loopback' -Kind 'residue-blocking' -Subject '网址解析'
Assert-Eq 'dns: its kind is in the repairable tier' 'True' ([string](Test-FindingFixable 'residue-blocking'))
Assert-Eq 'dns: but the layer has no fix, so we may not touch it' 'False' ([string](Test-FindingRepairable $dnsFinding))
# 这条判据要能在救援页源码里找到对应的「先于没发现问题」分支，
# 否则 DNS 一有问题屏幕第一句就是「没发现问题」——误报平安。
$rescueSrc2 = [System.IO.File]::ReadAllText((Join-Path $ScriptDir 'lib\insp.ps1'), [System.Text.Encoding]::UTF8)
# 「再按一次往上撤一条」必须是真的：撤成功要从日志里消费掉那一段。
# 只还原不消费的话，再按 r 取到的还是同一段——反复还原同一次，
# 而界面上那句「撤销上一次修复」听起来像是在逐条回退。
$journalUndoDir = Join-Path $env:TEMP ("undo_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $journalUndoDir -Force | Out-Null
$savedMonitor = $MonitorDir
$MonitorDir = $journalUndoDir
try {
    $ua = Join-Path $journalUndoDir 'a.txt'; $ub = Join-Path $journalUndoDir 'b.txt'
    Set-Content -LiteralPath $ua -Value 'AAA'; Set-Content -LiteralPath $ub -Value 'BBB'
    [void](Add-DoctorJournalEntry 'cli-proxy.git' ([ordered]@{ inspector = 'cli-proxy'; path = $ua; content = 'AAA' }))
    [void](Add-DoctorJournalEntry 'cli-proxy.npm' ([ordered]@{ inspector = 'cli-proxy'; path = $ub; content = 'BBB' }))
    Set-Content -LiteralPath $ua -Value 'CHANGED1'; Set-Content -LiteralPath $ub -Value 'CHANGED2'
    $u1 = Restore-DoctorJournal
    Assert-Eq 'undo: the first press restores the most recent layer' 'ok' ([string]$u1.Result)
    Assert-Eq 'undo: the most recent press leaves one fewer entry' 1 (@(Read-DoctorJournal).Count)
    Assert-Eq 'undo: the second newest file is back to its old content' 'BBB' ((Get-Content -LiteralPath $ub -Raw).Trim())
    $u2 = Restore-DoctorJournal
    Assert-Eq 'undo: the second press goes one step further back' 'ok' ([string]$u2.Result)
    Assert-Eq 'undo: the older file is back to its old content' 'AAA' ((Get-Content -LiteralPath $ua -Raw).Trim())
    $u3 = Restore-DoctorJournal
    Assert-Eq 'undo: with nothing left it says so instead of repeating' 'none' ([string]$u3.Result)
} finally {
    $MonitorDir = $savedMonitor
    Remove-Item -LiteralPath $journalUndoDir -Recurse -Force -ErrorAction SilentlyContinue
}
Assert-Eq 'rescue: an unfixable problem is reported before the all-clear' 'True' `
    ([bool]([regex]::IsMatch($rescueSrc2, '(?s)realButUnfixable.{0,400}没发现问题')))
Assert-Eq 'repairable: an unknown layer is not repairable' 'False' `
    ([string](Test-FindingRepairable (New-Finding -Id 'nope.thing' -Kind 'residue-blocking')))
# 判据只有一处实现：不许再出现第二个名字指向同一件事。
if (Get-Command Test-SysProxyFixable -ErrorAction SilentlyContinue) {
    Assert-Eq 'fixable 判据只有 Test-FindingFixable 一个名字' 'absent' 'present'
}

Write-Host '[33] Terminal tool proxy configuration (cli-proxy)'
# 这一节守的是「误伤率为零」：
#   · 只认本机回环 + 端口不通；
#   · 公司代理、认不出的值、说不清死活、文件里有 include —— 一律不动。
# 每一条都对应一种「删掉用户唯一的上网路径」或「删了他公司代理」的真实后果。
$cliCases = @(
    @('dead loopback is fixable',        'http://127.0.0.1:7890', $false, $false, 'residue-blocking'),
    @('live loopback is left alone',     'http://127.0.0.1:7890', $true,  $false, 'alive'),
    @('unknown liveness is untouched',   'http://127.0.0.1:7890', $null,  $false, 'foreign'),
    @('localhost counts as loopback',    'http://localhost:10809', $false, $false, 'residue-blocking'),
    @('bracketed IPv6 counts too',       'http://[::1]:10808',    $false, $false, 'residue-blocking'),
    @('a corporate proxy is never ours', 'http://proxy.corp.com:3128', $false, $false, 'foreign'),
    @('a LAN proxy is never ours',       'http://10.0.0.8:8080',  $false, $false, 'foreign'),
    @('an empty value means nothing set','',                      $false, $false, 'clean'),
    @('a file with include is untouched','http://127.0.0.1:7890', $false, $true,  'foreign'),
    @('an unparseable value is untouched','not-a-url',            $false, $false, 'foreign')
)
foreach ($c in $cliCases) {
    Assert-Eq ('cli-proxy: ' + $c[0]) $c[4] (Get-CliProxyVerdict -Value $c[1] -Alive $c[2] -HasInclude ([bool]$c[3]))
}
# 行解析：三种文件写法都要认，注释必须不认。
Assert-Eq 'cli-proxy: ini style key/value' 'proxy|http://127.0.0.1:7890' `
    ((ConvertFrom-CliConfigLine 'proxy = http://127.0.0.1:7890').Key + '|' + (ConvertFrom-CliConfigLine 'proxy = http://127.0.0.1:7890').Value)
Assert-Eq 'cli-proxy: double quotes are stripped' 'http://127.0.0.1:7890' (ConvertFrom-CliConfigLine 'proxy = "http://127.0.0.1:7890"').Value
Assert-Eq 'cli-proxy: single quotes are stripped' 'http://127.0.0.1:7890' (ConvertFrom-CliConfigLine "proxy='http://127.0.0.1:7890'").Value
Assert-Eq 'cli-proxy: trailing spaces are trimmed' 'http://127.0.0.1:7890' (ConvertFrom-CliConfigLine 'proxy = http://127.0.0.1:7890   ').Value
Assert-Eq 'cli-proxy: a socks scheme is kept' 'socks5://127.0.0.1:1080' (ConvertFrom-CliConfigLine 'proxy=socks5://127.0.0.1:1080').Value
# 注释行必须不命中：注释里的 proxy= 被当成真的设置，就会去改一个用户没设过的东西。
Assert-Eq 'cli-proxy: hash comment is not a setting' '' ([string](ConvertFrom-CliConfigLine '# proxy=http://127.0.0.1:7890'))
Assert-Eq 'cli-proxy: semicolon comment is not a setting' '' ([string](ConvertFrom-CliConfigLine '; proxy=http://127.0.0.1:7890'))
Assert-Eq 'cli-proxy: a section header is not a setting' '' ([string](ConvertFrom-CliConfigLine '[http]'))
Assert-Eq 'cli-proxy: a dotted key keeps its full name' 'http.proxy|v' `
    ((ConvertFrom-CliConfigLine 'http.proxy = v').Key + '|' + (ConvertFrom-CliConfigLine 'http.proxy = v').Value)
# 读文件的真实路径：段名要拼进键名，include 要能被认出来。
# **落点用 Path 指到临时目录**：这跑的是真的 Read-CliProxyFile，但一个字节都不碰使用者家目录。
$cfgDir = New-TempDir 'envproxy_cli_'
$gitCfg = Join-Path $cfgDir 'gitconfig'
Write-TestFile $gitCfg @"
[user]
    name = someone
[http]
    proxy = http://127.0.0.1:10809
[https]
    proxy = http://127.0.0.1:10809
[include]
    path = ../other.gitconfig
"@
$gitTarget = @{ Id = 'git'; Name = 'Git'; FileName = 'gitconfig'; Scope = 'home'; Path = $gitCfg; Keys = @('http.proxy', 'https.proxy') }
$gitRead = Read-CliProxyFile $gitTarget
Assert-Eq 'cli-proxy: ini reader finds both proxy keys' 2 (@($gitRead.Entries).Count)
Assert-Eq 'cli-proxy: ini reader reports include' 'True' $gitRead.HasInclude
Assert-Eq 'cli-proxy: ini keys carry their section' 'http.proxy' ([string](@($gitRead.Entries)[0]).Key)
Assert-Eq 'cli-proxy: ini keys are not the bare name' $false ('proxy' -eq [string](@($gitRead.Entries)[0]).Key)
# 注释里的 proxy= 不许被读成设置：读到了就会去改一个用户没设过的东西。
$npmCfg = Join-Path $cfgDir '.npmrc'
Write-TestFile $npmCfg "# proxy=http://127.0.0.1:9999`nregistry=https://registry.npmjs.org/`nproxy=http://127.0.0.1:7890"
$npmTarget = @{ Id = 'npm'; Name = 'npm'; FileName = '.npmrc'; Scope = 'home'; Path = $npmCfg; Keys = @('proxy', 'https-proxy') }
$npmRead = Read-CliProxyFile $npmTarget
Assert-Eq 'cli-proxy: a commented-out proxy is not an entry' 1 (@($npmRead.Entries).Count)
Assert-Eq 'cli-proxy: the live proxy is the entry' 'http://127.0.0.1:7890' ([string](@($npmRead.Entries)[0]).Value)
# 文件不存在时：读成功、零条目（「这一层不存在」不是「读不出来」）。
$missingTarget = @{ Id = 'x'; Name = 'x'; FileName = 'nope'; Scope = 'home'; Path = (Join-Path $cfgDir 'no-such-file'); Keys = @('proxy') }
$missingRead = Read-CliProxyFile $missingTarget
Assert-Eq 'cli-proxy: a missing file reads as ok with no entries' 'True' $missingRead.Ok
Assert-Eq 'cli-proxy: a missing file yields no findings' 0 (@(Get-CliProxyFindings | Where-Object { $_.Where -eq $missingTarget.Path }).Count)
Remove-Item -LiteralPath $cfgDir -Recurse -Force

Write-Host '[34] DNS layering (dns)'
# 判据只说两件能证伪的事。这一节把它们钉死：宽松一点就会把用户自己设的
# 公共 DNS 说成「故障」，或者把 198.18（翻墙软件的虚拟段）漏过去。
foreach ($p in @(
    @('127.0.0.1', 'loopback'), @('::1', 'loopback'), @('localhost', 'loopback'), @('[::1]', 'loopback'),
    @('198.18.0.2', 'fakeip'), @('198.19.255.254', 'fakeip'),
    @('198.20.0.1', 'other'), @('198.17.0.1', 'other'),
    @('223.5.5.5', 'other'), @('8.8.8.8', 'other'), @('10.0.0.1', 'other'),
    @('172.16.0.1', 'other'), @('192.168.31.1', 'other'), @('169.254.1.1', 'other'),
    @('', 'other'), @('not-an-ip', 'other')
)) { Assert-Eq ('dns class: ' + $p[0]) $p[1] (Get-DnsAddressClass $p[0]) }
Assert-Eq 'dns: the 198.18/15 boundary is inclusive below' 'fakeip' (Get-DnsAddressClass '198.18.0.0')
Assert-Eq 'dns: the 198.18/15 boundary is inclusive above' 'fakeip' (Get-DnsAddressClass '198.19.255.255')
Assert-Eq 'dns: comma separated list splits' '223.5.5.5 180.76.76.76' ((ConvertFrom-DnsList '223.5.5.5,180.76.76.76') -join ' ')
Assert-Eq 'dns: space separated list splits' '223.5.5.5 180.76.76.76' ((ConvertFrom-DnsList '223.5.5.5 180.76.76.76') -join ' ')
Assert-Eq 'dns: empty separators are dropped' '1.1.1.1' ((ConvertFrom-DnsList ' 1.1.1.1 ;;') -join ' ')
Assert-Eq 'dns: an empty value yields nothing' '' ((ConvertFrom-DnsList '') -join ' ')

Write-Host '[35] Transaction journal (doctor)'
# 从单槽位（doctor.bak）换成日志的理由：可修的层不止一处之后，
# 「只写一次」的槽位会让「还原」撤掉很久以前那次，而屏幕上说「已经改回去了」。
# 这一节把新语义钉死：追加、只撤最近一次、按 inspector 分发、旧格式仍能读。
$jDir = New-TempDir 'envproxy_journal_'
$__savedMonitor = $MonitorDir
try {
    $script:MonitorDir = $jDir
    Assert-Eq 'journal: nothing to restore at first' 'False' (Test-DoctorJournalHasRestore)
    $jf1 = [ordered]@{ inspector = 'sysproxy'; flags = '3'; server = '127.0.0.1:7890'; bypass = '<local>'; pac = '' }
    Assert-Eq 'journal: the first entry is written' 'True' (Add-DoctorJournalEntry 'sysproxy' $jf1)
    Assert-Eq 'journal: one entry readable' 1 (@(Read-DoctorJournal).Count)
    $j1 = @(Read-DoctorJournal)[0]
    Assert-Eq 'journal: inspector survives' 'sysproxy' ([string]$j1.Fields['inspector'])
    Assert-Eq 'journal: a value with a colon survives' '127.0.0.1:7890' ([string]$j1.Fields['server'])
    # 值里的 = 与换行必须能原样读回来，否则配置文件还原会损坏。
    $cfgText = "a=b`nc=d"
    $jf2 = [ordered]@{ inspector = 'cli-proxy'; path = 'C:\x\.gitconfig'; content = $cfgText }
    Assert-Eq 'journal: the second entry is appended' 'True' (Add-DoctorJournalEntry 'cli-proxy' $jf2)
    Assert-Eq 'journal: both entries readable' 2 (@(Read-DoctorJournal).Count)
    $j2 = @(Read-DoctorJournal)[1]
    Assert-Eq 'journal: the last entry is the second one' 'cli-proxy' ([string]$j2.Fields['inspector'])
    Assert-Eq 'journal: escaped newline round trips' $cfgText ([string]$j2.Fields['content'])
    # 上限：写多了只留最近 N 段。不设上限就是往用户的日志目录里无限追加。
    for ($i = 0; $i -lt 10; $i++) { [void](Add-DoctorJournalEntry 'sysproxy' $jf1) }
    Assert-Eq 'journal: entries are capped' $DoctorJournalKeep (@(Read-DoctorJournal).Count)
} finally {
    $script:MonitorDir = $__savedMonitor
    Remove-Item -LiteralPath $jDir -Recurse -Force -ErrorAction SilentlyContinue
}
# 两侧的保留条数必须是同一个数（门禁 6 也核，这里先钉一道本侧）。
Assert-Eq 'journal: keep count is a real constant' $true ($DoctorJournalKeep -ge 1)
# 旧格式（doctor.bak）必须仍然能读：升级上来的机器上，那是用户唯一的还原机会。
# 夹具用生产编码器生成，避免「测试自己编了一份格式」而与真实文件对不上。
$jDir2 = New-TempDir 'envproxy_legacy_'
$__savedMonitor2 = $MonitorDir
try {
    $script:MonitorDir = $jDir2
    $bakBody = @(
        'flags=3'
        ('server=' + (ConvertTo-DoctorBakValue '127.0.0.1:7078'))
        ('bypass=' + (ConvertTo-DoctorBakValue '<local>'))
        'pac='
    ) -join "`n"
    Write-TestFile (Join-Path $jDir2 'doctor.bak') $bakBody
    $lops = @(Read-DoctorJournal)
    Assert-Eq 'legacy bak: read as one restorable op' 1 $lops.Count
    Assert-Eq 'legacy bak: marked as legacy' 'legacy-bak' ([string]$lops[0].OpId)
    Assert-Eq 'legacy bak: attributed to the system proxy layer' 'sysproxy' ([string]$lops[0].Fields['inspector'])
    Assert-Eq 'legacy bak: flags survive' '3' ([string]$lops[0].Fields['flags'])
    Assert-Eq 'legacy bak: server survives' '127.0.0.1:7078' ([string]$lops[0].Fields['server'])
    Assert-Eq 'legacy bak: bypass survives' '<local>' ([string]$lops[0].Fields['bypass'])
    Assert-Eq 'legacy bak: restore is offered' 'True' (Test-DoctorJournalHasRestore)
} finally {
    $script:MonitorDir = $__savedMonitor2
    Remove-Item -LiteralPath $jDir2 -Recurse -Force -ErrorAction SilentlyContinue
}
# 分发：撤销必须按 inspector 找对实现，且内容是「逐字回到原样」。
$jDir3 = New-TempDir 'envproxy_restore_'
$__savedMonitor3 = $MonitorDir
try {
    $script:MonitorDir = $jDir3
    $npmFile = Join-Path $jDir3 '.npmrc'
    $npmOrig = "registry=https://registry.npmjs.org/`nproxy=http://127.0.0.1:7890`n"
    Write-TestFile $npmFile $npmOrig
    $jf3 = [ordered]@{ inspector = 'cli-proxy'; target = 'npm'; path = $npmFile; content = $npmOrig }
    [void](Add-DoctorJournalEntry 'cli-proxy' $jf3)
    Write-TestFile $npmFile "registry=https://registry.npmjs.org/`n"
    $rr = Restore-DoctorJournal
    Assert-Eq 'restore: reports ok' 'ok' ([string]$rr.Result)
    Assert-Eq 'restore: the file is byte-identical to before' $true `
        ([System.IO.File]::ReadAllText($npmFile) -ceq $npmOrig)
    # 撤销成功要**消费掉**那一段：日志里只剩这一段，撤完就没有了。
    # 旧行为是"追加式、撤完还在"，导致再按 r 反复还原同一次——
    # 而界面上写的是「撤销上一次修复」，听起来像在逐条回退。
    Assert-Eq 'restore: the entry is consumed by a successful undo' 'False' (Test-DoctorJournalHasRestore)
} finally {
    $script:MonitorDir = $__savedMonitor3
    Remove-Item -LiteralPath $jDir3 -Recurse -Force -ErrorAction SilentlyContinue
}
