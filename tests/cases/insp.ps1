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
# 临时目录用 .NET 的 GetTempPath：Linux 上没有 $env:TEMP，Join-Path 收到 null 会崩。
$journalUndoDir = Join-Path ([System.IO.Path]::GetTempPath()) ("undo_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
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

# 行解析：三种写法都要认（= / : / 空格），注释必须不认，行尾注释必须剥掉。
$p1 = ConvertFrom-CliConfigLine 'proxy = http://127.0.0.1:7890'
Assert-Eq 'cli-proxy: ini style key/value' 'proxy|http://127.0.0.1:7890' ($p1.Key + '|' + $p1.Value)
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
# 行尾注释必须剥掉。`proxy = 127.0.0.1:7890 # clash` 是最常见的写法之一；
# 不剥的话地址解析失败、判成「值认不出来」，那个死端口永远查不出来（静默漏检）。
Assert-Eq 'cli-proxy: inline hash comment is stripped' '127.0.0.1:7890' (ConvertFrom-CliConfigLine 'proxy = 127.0.0.1:7890 # clash').Value
Assert-Eq 'cli-proxy: inline semicolon comment is stripped' '127.0.0.1:7890' (ConvertFrom-CliConfigLine 'proxy = 127.0.0.1:7890 ; old').Value
Assert-Eq 'cli-proxy: quoted value plus comment' '127.0.0.1:7890' (ConvertFrom-CliConfigLine 'proxy = "127.0.0.1:7890" # 旧代理').Value
# 另外两种写法：YAML 的 `键: 值`、yarnrc 的 `键 "值"`。
Assert-Eq 'cli-proxy: yaml colon form' 'httpProxy|http://127.0.0.1:7890' `
    ((ConvertFrom-CliConfigLine 'httpProxy: "http://127.0.0.1:7890"' 'colon').Key + '|' + (ConvertFrom-CliConfigLine 'httpProxy: "http://127.0.0.1:7890"' 'colon').Value)
Assert-Eq 'cli-proxy: yarnrc space form' 'proxy|http://127.0.0.1:7890' `
    ((ConvertFrom-CliConfigLine 'proxy "http://127.0.0.1:7890"' 'space').Key + '|' + (ConvertFrom-CliConfigLine 'proxy "http://127.0.0.1:7890"' 'space').Value)
Assert-Eq 'cli-proxy: a dotted key is not truncated' 'systemProp.http.proxyHost' (ConvertFrom-CliConfigLine 'systemProp.http.proxyHost=127.0.0.1').Key

# 读文件的真实路径。**落点用 Path 指到临时目录**：这跑的是真的 Read-CliProxyFile，
# 但一个字节都不碰使用者家目录。
$cfgDir = New-TempDir 'envproxy_cli_'

# --- INI（.gitconfig）：段名拼进键名、include 要能被认出来 ---
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
$gitTarget = @{ Id = 'git'; Name = 'Git'; Format = 'kv'; Section = ''; Keys = @('http.proxy', 'https.proxy'); Pair = @{}; Fix = 'drop'; Files = @('home:.gitconfig'); Path = $gitCfg }
$gitRead = Read-CliProxyFile $gitTarget $gitCfg
Assert-Eq 'cli-proxy: ini reader finds both proxy keys' 2 (@($gitRead.Entries).Count)
Assert-Eq 'cli-proxy: ini reader reports include' 'True' $gitRead.HasInclude
Assert-Eq 'cli-proxy: ini keys carry their section' 'http.proxy' ([string](@($gitRead.Entries)[0]).Key)
Assert-Eq 'cli-proxy: ini keys are not the bare name' $false ('proxy' -eq [string](@($gitRead.Entries)[0]).Key)

# --- .npmrc：注释里的 proxy= 不许被读成设置；行尾注释要剥掉 ---
$npmCfg = Join-Path $cfgDir '.npmrc'
Write-TestFile $npmCfg "# proxy=http://127.0.0.1:9999`nregistry=https://registry.npmjs.org/`nproxy=127.0.0.1:7890 # clash"
$npmTarget = @{ Id = 'npm'; Name = 'npm'; Format = 'kv'; Section = ''; Keys = @('proxy', 'https-proxy'); Pair = @{}; Fix = 'drop'; Files = @('home:.npmrc'); Path = $npmCfg }
$npmRead = Read-CliProxyFile $npmTarget $npmCfg
Assert-Eq 'cli-proxy: a commented-out proxy is not an entry' 1 (@($npmRead.Entries).Count)
Assert-Eq 'cli-proxy: the live proxy is the entry' '127.0.0.1:7890' ([string](@($npmRead.Entries)[0]).Value)

# --- Cargo：TOML 的 [http] 段，值是带引号的 ---
$cargoCfg = Join-Path $cfgDir 'config.toml'
Write-TestFile $cargoCfg "[net]`nretry = 2`n[http]`nproxy = `"http://127.0.0.1:7890`"`n"
$cargoTarget = @{ Id = 'cargo'; Name = 'Cargo'; Format = 'kv'; Section = 'http'; Keys = @('proxy'); Pair = @{}; Fix = 'drop'; Files = @('home:.cargo/config.toml'); Path = $cargoCfg }
Assert-Eq 'cli-proxy: cargo reads the [http] proxy' 'http://127.0.0.1:7890' ([string](@((Read-CliProxyFile $cargoTarget $cargoCfg).Entries)[0]).Value)
# 段不匹配时不算：别的段里叫 proxy 的东西不是 http 代理。
$cargoOther = Join-Path $cfgDir 'config2.toml'
Write-TestFile $cargoOther "[net]`nproxy = `"http://127.0.0.1:7890`"`n"
Assert-Eq 'cli-proxy: a proxy in another section is not ours' 0 (@((Read-CliProxyFile $cargoTarget $cargoOther).Entries).Count)

# --- Gradle：主机与端口分两行写，必须凑齐才算一项 ---
$gradleCfg = Join-Path $cfgDir 'gradle.properties'
Write-TestFile $gradleCfg "org.gradle.jvmargs=-Xmx2g`nsystemProp.http.proxyHost=127.0.0.1`nsystemProp.http.proxyPort=7890`n"
$gradleTarget = @{ Id = 'gradle'; Name = 'Gradle'; Format = 'kv'; Section = ''; Keys = @(); Fix = 'port'
                   Pair = @{ 'systemProp.http.proxyHost' = 'systemProp.http.proxyPort' }; Files = @('home:.gradle/gradle.properties'); Path = $gradleCfg }
$gradleRead = Read-CliProxyFile $gradleTarget $gradleCfg
Assert-Eq 'cli-proxy: gradle pairs host and port into one entry' 1 (@($gradleRead.Entries).Count)
Assert-Eq 'cli-proxy: gradle entry carries the port' '7890' ([string](@($gradleRead.Entries)[0]).Port)
Assert-Eq 'cli-proxy: gradle entry knows the port line' 'True' ([string](@($gradleRead.Entries)[0]).PortOnly)
Assert-Eq 'cli-proxy: gradle entry deletes both lines' 2 (@(@($gradleRead.Entries)[0]).Lines.Count)
# 只写主机不写端口 = 半截配置：那一行不生效，判死会让用户以为这里挡住了网络。
$gradleHalf = Join-Path $cfgDir 'gradle-half.properties'
Write-TestFile $gradleHalf "systemProp.http.proxyHost=127.0.0.1`n"
Assert-Eq 'cli-proxy: gradle without a port yields nothing' 0 (@((Read-CliProxyFile $gradleTarget $gradleHalf).Entries).Count)

# --- Conda：嵌套 YAML，父键下面挂 http / https ---
$condaCfg = Join-Path $cfgDir '.condarc'
Write-TestFile $condaCfg "proxy_servers:`n  http: http://127.0.0.1:7890`n  https: http://127.0.0.1:7890`nchannels:`n  - defaults`n"
$condaTarget = @{ Id = 'conda'; Name = 'Conda'; Format = 'yaml-nested'; Section = 'proxy_servers'; Keys = @('http', 'https'); Pair = @{}; Fix = 'port-only'; Files = @('home:.condarc'); Path = $condaCfg }
$condaRead = Read-CliProxyFile $condaTarget $condaCfg
Assert-Eq 'cli-proxy: conda finds both nested proxies' 2 (@($condaRead.Entries).Count)
Assert-Eq 'cli-proxy: conda keys carry the parent' 'proxy_servers.http' ([string](@($condaRead.Entries)[0]).Key)

# --- Maven：<proxy> 块，<active>false</active> 的那一块不算 ---
$mavenCfg = Join-Path $cfgDir 'settings.xml'
Write-TestFile $mavenCfg @"
<settings>
  <proxies>
    <proxy>
      <id>local</id>
      <active>true</active>
      <host>127.0.0.1</host>
      <port>7890</port>
    </proxy>
    <proxy>
      <id>off</id>
      <active>false</active>
      <host>127.0.0.1</host>
      <port>7891</port>
    </proxy>
  </proxies>
</settings>
"@
$mavenTarget = @{ Id = 'maven'; Name = 'Maven'; Format = 'xml'; Section = ''; Keys = @(); Pair = @{}; Fix = 'port-only'; Files = @('home:.m2/settings.xml'); Path = $mavenCfg }
$mavenRead = Read-CliProxyFile $mavenTarget $mavenCfg
Assert-Eq 'cli-proxy: maven skips the inactive proxy' 1 (@($mavenRead.Entries).Count)
Assert-Eq 'cli-proxy: maven reads the port element' '7890' ([string](@($mavenRead.Entries)[0]).Port)
Assert-Eq 'cli-proxy: maven repoints the port element' 'True' ([string](@($mavenRead.Entries)[0]).PortOnly)

# --- NuGet：<add key="http_proxy" value="..." /> ---
$nugetCfg = Join-Path $cfgDir 'NuGet.Config'
Write-TestFile $nugetCfg '<configuration><config><add key="http_proxy" value="http://127.0.0.1:7890" /></config></configuration>'
$nugetTarget = @{ Id = 'nuget'; Name = 'NuGet'; Format = 'xml'; Section = ''; Keys = @(); Pair = @{}; Fix = 'port-only'; Files = @('appdata:NuGet/NuGet.Config'); Path = $nugetCfg }
Assert-Eq 'cli-proxy: nuget reads the http_proxy value' '7890' ([string](@((Read-CliProxyFile $nugetTarget $nugetCfg).Entries)[0]).Port)

# --- SSH：ProxyCommand 里的本机代理；域名别名不是本机代理 ---
$sshCfg = Join-Path $cfgDir 'ssh_config'
Write-TestFile $sshCfg "Host github.com`n  ProxyCommand nc -X connect -x 127.0.0.1:7890 %h %p`nHost *`n  ProxyJump bastion`n"
$sshTarget = @{ Id = 'ssh'; Name = 'SSH'; Format = 'ssh'; Section = ''; Keys = @(); Pair = @{}; Fix = 'port'; Files = @('home:.ssh/config'); Path = $sshCfg }
$sshRead = Read-CliProxyFile $sshTarget $sshCfg
Assert-Eq 'cli-proxy: ssh finds the loopback proxy command' 1 (@($sshRead.Entries).Count)
Assert-Eq 'cli-proxy: ssh keeps the port' '7890' ([string](@($sshRead.Entries)[0]).Port)
$sshCfg2 = Join-Path $cfgDir 'ssh_config2'
Write-TestFile $sshCfg2 "Host *`n  ProxyJump bastion`n"
Assert-Eq 'cli-proxy: a jump host alias is not a local proxy' 0 (@((Read-CliProxyFile $sshTarget $sshCfg2).Entries).Count)

# --- 文件不存在时：读成功、零条目（「这一层不存在」不是「读不出来」）---
$missingTarget = @{ Id = 'x'; Name = 'x'; Format = 'kv'; Section = ''; Keys = @('proxy'); Pair = @{}; Fix = 'drop'; Files = @('home:nope'); Path = (Join-Path $cfgDir 'no-such-file') }
$missingRead = Read-CliProxyFile $missingTarget $missingTarget.Path
Assert-Eq 'cli-proxy: a missing file reads as ok with no entries' 'True' $missingRead.Ok
Assert-Eq 'cli-proxy: a missing file yields no findings' 0 (@(Get-CliProxyFindings | Where-Object { $_.Where -eq $missingTarget.Path }).Count)
Remove-Item -LiteralPath $cfgDir -Recurse -Force

# 修法三档：删行 / 改端口 / 只报告。判据同时看「这层怎么修」与「现在有没有活代理」。
Assert-Eq 'mode: a drop-only tool always drops' 'drop' ([string](Get-CliProxyEntryMode @{ Fix = 'drop' } $null))
Assert-Eq 'mode: a port tool without a live proxy falls back to drop' 'drop' ([string](Get-CliProxyEntryMode @{ Fix = 'port' } $null))
Assert-Eq 'mode: a port tool with a live proxy repoints' 'port' ([string](Get-CliProxyEntryMode @{ Fix = 'port' } @{ Host = '127.0.0.1'; Port = 1 }))
Assert-Eq 'mode: a port-only tool without a live proxy only reports' 'none' ([string](Get-CliProxyEntryMode @{ Fix = 'port-only' } $null))
Assert-Eq 'mode: a port-only tool with a live proxy repoints' 'port' ([string](Get-CliProxyEntryMode @{ Fix = 'port-only' } @{ Host = '127.0.0.1'; Port = 1 }))

# 「能不能动」的第三维：同一层里 .npmrc 能删、settings.xml 不能改结构。
# 没有这一维，救援页会对 XML 也亮出「可以修」，按下去什么也没修好。
Assert-Eq 'repairable: a droppable entry is repairable' 'True' `
    ([string](Test-FindingRepairable (New-Finding -Id 'cli-proxy.npm' -Kind 'residue-blocking' -Data @{ Repairable = $true })))
Assert-Eq 'repairable: a format we cannot edit is reported only' 'False' `
    ([string](Test-FindingRepairable (New-Finding -Id 'cli-proxy.maven' -Kind 'residue-blocking' -Data @{ Repairable = $false })))

# 改端口那一行只替换地址，别的一个字都不许动：账号密码被抹掉是数据损坏。
Assert-Eq 'repoint: replaces host and port only' 'proxy = http://127.0.0.1:9999' `
    (Set-CliProxyEndpointOnLine 'proxy = http://127.0.0.1:7890' '127.0.0.1' 7890 '127.0.0.1' 9999 $false)
Assert-Eq 'repoint: keeps credentials' 'proxy = http://u:p@127.0.0.1:9999' `
    (Set-CliProxyEndpointOnLine 'proxy = http://u:p@127.0.0.1:7890' '127.0.0.1' 7890 '127.0.0.1' 9999 $false)
Assert-Eq 'repoint: a port-only line keeps its markup' '  <port>9999</port>' `
    (Set-CliProxyEndpointOnLine '  <port>7890</port>' '' 7890 '127.0.0.1' 9999 $true)
Assert-Eq 'repoint: ipv6 keeps its brackets' 'proxy=http://[::1]:9999' `
    (Set-CliProxyEndpointOnLine 'proxy=http://[::1]:7890' '::1' 7890 '::1' 9999 $false)
Assert-Eq 'repoint: no endpoint means no edit' '' `
    ([string](Set-CliProxyEndpointOnLine 'proxy=nothing' '127.0.0.1' 7890 '127.0.0.1' 9999 $false))

# 真跑一遍修复：删行与改端口两条路都要落到文件上，而且不许碰别的行。
$repairDir = New-TempDir 'envproxy_clirepair_'
$savedTargets = $CliProxyTargets
$savedLiveFn = ${function:Get-CliLiveProxyEndpoint}
$savedMonitorForRepair = $MonitorDir
try {
    $script:MonitorDir = $repairDir
    # (1) 没有活代理：把死的那一行删掉，其余原样。
    $dropFile = Join-Path $repairDir '.npmrc'
    Write-TestFile $dropFile "registry=https://registry.npmjs.org/`nproxy=http://127.0.0.1:65001`n"
    $CliProxyTargets = @(@{ Id = 'npm'; Name = 'npm'; Format = 'kv'; Section = ''; Keys = @('proxy', 'https-proxy'); Pair = @{}; Fix = 'drop'; Files = @('home:.npmrc'); Path = $dropFile })
    ${function:Get-CliLiveProxyEndpoint} = { return $null }
    $dr = Repair-CliProxyConfig
    Assert-Eq 'repair: dropping the dead line reports fixed' 'fixed' ([string]$dr.Result)
    Assert-Eq 'repair: only the dead line is gone' "registry=https://registry.npmjs.org/`n" ([System.IO.File]::ReadAllText($dropFile))

    # (2) 有活代理：把端口改过去（Gradle 的成对键）。
    $portFile = Join-Path $repairDir 'gradle.properties'
    Write-TestFile $portFile "org.gradle.jvmargs=-Xmx2g`nsystemProp.http.proxyHost=127.0.0.1`nsystemProp.http.proxyPort=65001`n"
    $CliProxyTargets = @(@{ Id = 'gradle'; Name = 'Gradle'; Format = 'kv'; Section = ''; Keys = @(); Pair = @{ 'systemProp.http.proxyHost' = 'systemProp.http.proxyPort' }; Fix = 'port'; Files = @('home:.gradle/gradle.properties'); Path = $portFile })
    ${function:Get-CliLiveProxyEndpoint} = { return @{ Host = '127.0.0.1'; Port = 17001 } }
    $pr = Repair-CliProxyConfig
    Assert-Eq 'repair: repointing reports fixed' 'fixed' ([string]$pr.Result)
    Assert-Eq 'repair: the port line is rewritten' 'True' ([bool]([System.IO.File]::ReadAllText($portFile) -match 'systemProp\.http\.proxyPort=17001'))
    Assert-Eq 'repair: the host line is untouched' 'True' ([bool]([System.IO.File]::ReadAllText($portFile) -match 'systemProp\.http\.proxyHost=127\.0\.0\.1'))
    Assert-Eq 'repair: unrelated lines survive' 'True' ([bool]([System.IO.File]::ReadAllText($portFile) -match 'org\.gradle\.jvmargs=-Xmx2g'))

    # (3) 只能改端口的格式、又没有活代理：一条都不许改（只报告）。
    $xmlFile = Join-Path $repairDir 'settings.xml'
    Write-TestFile $xmlFile "<settings>`n  <proxies>`n    <proxy>`n      <active>true</active>`n      <host>127.0.0.1</host>`n      <port>7890</port>`n    </proxy>`n  </proxies>`n</settings>`n"
    $CliProxyTargets = @(@{ Id = 'maven'; Name = 'Maven'; Format = 'xml'; Section = ''; Keys = @(); Pair = @{}; Fix = 'port-only'; Files = @('home:.m2/settings.xml'); Path = $xmlFile })
    ${function:Get-CliLiveProxyEndpoint} = { return $null }
    $xr = Repair-CliProxyConfig
    Assert-Eq 'repair: a port-only format with no live proxy reports nothing done' 'none' ([string]$xr.Result)
    Assert-Eq 'repair: and the file is byte-identical' 'True' ([bool]([System.IO.File]::ReadAllText($xmlFile) -match '<port>7890</port>'))
} finally {
    $CliProxyTargets = $savedTargets
    ${function:Get-CliLiveProxyEndpoint} = $savedLiveFn
    $script:MonitorDir = $savedMonitorForRepair
    Remove-Item -LiteralPath $repairDir -Recurse -Force -ErrorAction SilentlyContinue
}
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

Write-Host '[36] SOCKS-only ports (socks inspector)'
# 判据只有一条：3 字节问候之后，回包的**版本字节**是 0x05。
# 这条判据的作用只有解释：把「本机有代理在跑、工具却说没有」变成一句能行动的话。
Assert-Eq 'socks: port 0 is never a socks proxy' 'False' ([string](Test-Socks5Port 0 200))
Assert-Eq 'socks: a closed port is not a socks proxy' 'False' ([string](Test-Socks5Port 65002 200))

# 真起一个只回 SOCKS 问候应答的端口，确认判据认得出它（不是恒假）。
# 与 probe 测试里的假代理同一手法：真监听、真连接、一直服务到测试进程结束。
function Start-SocksReplyServer {
    $port = 0
    for ($try = 0; $try -lt 30; $try++) {
        $candidate = 20000 + (Get-Random -Maximum 2000)
        $probe = $null
        try {
            $probe = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $candidate)
            $probe.Start(); $port = $candidate
        } catch { $port = 0 } finally { if ($probe) { try { $probe.Stop() } catch {} } }
        if ($port -ne 0) { break }
    }
    if ($port -eq 0) { throw 'no free port for the socks mock' }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
        $p = $args[0]
        $tcp = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $p)
        $tcp.Start()
        try {
            while ($true) {
                $accept = $tcp.AcceptTcpClientAsync()
                if (-not $accept.Wait(1000)) { continue }
                $client = $accept.Result
                try {
                    $stream = $client.GetStream()
                    $buf = New-Object byte[] 3
                    $null = $stream.Read($buf, 0, 3)
                    # SOCKS5 方法选择应答：版本 5，无需认证。
                    $reply = [byte[]]@(0x05, 0x00)
                    $stream.Write($reply, 0, 2)
                    $stream.Flush()
                } catch {}
                try { $client.Close() } catch {}
            }
        } catch {}
        $tcp.Stop()
    }).AddArgument($port)
    $null = $ps.BeginInvoke()
    # 等它真的监听起来：固定 sleep 不够（机器一忙就随机红）。
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $c = $null
        try {
            $c = New-Object System.Net.Sockets.TcpClient
            $c.Connect('127.0.0.1', $port)
            break
        } catch { Start-Sleep -Milliseconds 50 } finally { if ($c) { try { $c.Close() } catch {} } }
    }
    return $port
}
$socksPort = Start-SocksReplyServer
Assert-Eq 'socks: a socks-only port is recognised' 'True' ([string](Test-Socks5Port $socksPort 500))
# 混合端口（HTTP 与 SOCKS 都应答）不算「只认 SOCKS」：那由 Get-SocksOnlyPorts 的
# 握手前置挡住，这里只钉住"能连上、会回话"这一半判据。
Write-Host '[37] Status JSON (machine-readable output)'
# 给脚本、状态栏、批量部署读的：一行、纯 ASCII、字段名与取值是契约。
# 手写序列化（不用 ConvertTo-Json）：它是模块命令，PSModulePath 排着别的版本时会静默缺失，
# 症状是整条输出变成空白而退出码仍是 0。
$stJson = @{
    LocalVersion = '9.9.9'; NeverInstalled = $false; Monitor = $true; AutoRunOk = $true
    Port = 7078; PortUnknown = $false
    ProxyValue = 'http://127.0.0.1:7078'; ProxyAlive = $true
    NodeHandshake = 'proxy-ok'; VarsMatch = 'yes'
    TermSync = $null; SysProxy = $null; UpdateInProgress = $false; StopIntent = $false
    ApplyResult = 'ok'
}
$jsonLine = Format-StatusJson $stJson
Assert-Eq 'json: a single line' 1 (@($jsonLine -split "`n").Count)
# 纯 ASCII 是契约的一部分：Windows PowerShell 5.1 把中文重定向到文件/管道时按控制台
# 代码页编码，脚本那边会读到乱码。机器读的东西本来也不该靠文案。
Assert-Eq 'json: pure ascii' 'True' ([string]([bool]($jsonLine -match '^[\x20-\x7E]+$')))
$j1 = $jsonLine | ConvertFrom-Json
Assert-Eq 'json: schema' 1 $j1.schema
Assert-Eq 'json: version' '9.9.9' $j1.version
Assert-Eq 'json: installed' 'True' ([string]$j1.installed)
Assert-Eq 'json: monitor' 'True' ([string]$j1.monitor)
Assert-Eq 'json: state on' 'on' $j1.state
Assert-Eq 'json: port' 7078 $j1.port
Assert-Eq 'json: proxy' 'http://127.0.0.1:7078' $j1.proxy
Assert-Eq 'json: node handshake' 'proxy-ok' $j1.nodeHandshake
Assert-Eq 'json: vars match' 'yes' $j1.varsMatch
Assert-Eq 'json: issues count' 0 $j1.issues
Assert-Eq 'json: relay field exists' 'True' ([string]($j1.PSObject.Properties.Name -contains 'relayPort'))
# 三态不许塌缩：端口枚举失败是「不知道」，不是「没有代理」。
# 塌缩成 off 会让脚本以为"现在该直连"，而事实是"这一轮没读到端口"。
$stJson.Port = $null; $stJson.PortUnknown = $true
$j2 = (Format-StatusJson $stJson) | ConvertFrom-Json
Assert-Eq 'json: unknown is not collapsed to off' 'unknown' $j2.state
Assert-Eq 'json: unknown keeps port null' $null $j2.port
$stJson.PortUnknown = $false
$j3 = (Format-StatusJson $stJson) | ConvertFrom-Json
Assert-Eq 'json: off when nothing is running' 'off' $j3.state
# 引号与反斜杠必须转义：状态里的值来自系统（可能被别的工具改坏），
# 一个裸引号就会让整行 JSON 变成解析不了的垃圾。
$stJson.ProxyValue = 'http://x/"q"\back'
$j4 = (Format-StatusJson $stJson) | ConvertFrom-Json
Assert-Eq 'json: quotes and backslashes round trip' 'http://x/"q"\back' $j4.proxy