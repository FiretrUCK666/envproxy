# ==============================================================================
#  insp.ps1 — 检查器层：注册表、编排、以及「系统代理之外」的那些检查器与救援页
#  由入口 envproxy.ps1 按固定顺序点源加载，不单独运行。
#
#  为什么单独成一个库（而不是继续往 doctor.ps1 里堆）：
#    doctor.ps1 的职责是「怎么安全地读一层、判一层、修一层」——它是**叶子**，
#    只依赖 base + probe，界面反过来调它。检查器不一样：它要汇总各层、要渲染，
#    而渲染必须调 base 的配色与清屏。把编排放进 doctor 会立刻造出
#    doctor -> 界面 -> doctor 的环（门禁 1/2 会拦）。
#
#  依赖方向（单向）：insp -> doctor -> probe -> base
#    doctor 不认识 insp，所以 doctor 那份判据永远是唯一的一份。
#
#  职责边界（改这个文件前先读这一段）：
#    可以有 —— 检查器注册表、编排、各检查器的读取与修复、救援页界面
#    不许有 —— 改环境变量、安装/卸载、快捷方式
#
#  加一层网络检查的完整动作（三处，没有第四处）：
#    1) 写一个产出 Finding 数组的读取函数（判据必须是纯函数，能喂测试用例）
#    2) 要修就再写一个修复函数，以及对应的撤销函数（写还原点 + 回读确认）
#    3) 在下面的 $DoctorInspectors 里加一行
#  界面、报告、状态页一个字都不用改——它们只认 Finding，不认检查器名字。
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 检查器注册表：唯一权威，也是唯一分派点
# ------------------------------------------------------------------------------
# 字段：
#   Id       稳定标识，写进还原点的 inspector 字段
#   Title    界面上那一组叫什么（用户看得懂的说法，不是内部名）
#   Quick    状态页（每 2–3 秒刷一次）要不要跑它。**贵的一律 $false**：
#            状态页刷新的代价以毫秒计，跑一次要读文件或连端口的检查器进去就毁了
#   Detect   产出 Finding 数组的函数名
#   Fix      修它的函数名；$null = 只诊断不修（「不敢自动改」的那些层）
#   Restore  撤销函数名。实际撤销走 Restore-FindingSnapshot 的分发；
#            这一列让门禁能核对「声明了可修就得有撤销的路」
#
# **顺序就是界面上的顺序**：从下往上（网址解析 → 浏览器 → 终端工具），
# 与人排查故障的方向一致——先看是不是连名字都解析不了，再看浏览器，最后看工具。
# 最后一条「只认 SOCKS 的端口」是解释性的：它回答"本机明明有代理在跑，
# 为什么这个工具说没有"，排在最后才不会抢走真故障的位置。
$DoctorInspectors = @(
    @{ Id = 'dns';       Title = '网址解析';         Quick = $false
       Detect = 'Get-DnsFindings';    Fix = $null;                     Restore = $null }
    @{ Id = 'sysproxy';  Title = '浏览器代理';       Quick = $true
       Detect = 'Get-SysProxyFindings'; Fix = 'Repair-SystemProxy';    Restore = 'Restore-SysProxySnapshot' }
    @{ Id = 'cli-proxy'; Title = '终端工具里的代理'; Quick = $false
       Detect = 'Get-CliProxyFindings'; Fix = 'Repair-CliProxyConfig'; Restore = 'Restore-CliProxySnapshot' }
    @{ Id = 'socks';     Title = '只认 SOCKS 的端口'; Quick = $false
       Detect = 'Get-SocksFindings';  Fix = $null;                     Restore = $null }
)

# 按 Id 取检查器描述符。取不到返回 $null——调用方据此报错，不静默回落。
function Get-DoctorInspector([string]$Id) {
    if (-not $Id) { return $null }
    foreach ($d in $DoctorInspectors) { if ($d.Id -eq $Id) { return $d } }
    return $null
}

# 表自检：每个声明的函数必须在本侧真实存在。
# 在进体检页时跑，不在加载期跑（库加载期不许有对外副作用）。
# 用 Test-Path function: 而不是 Get-Command：后者会触发模块自动加载，
# 而本项目的契约明确说自动加载会挑版本、让命令静默缺失。
function Assert-DoctorInspectors {
    foreach ($d in $DoctorInspectors) {
        foreach ($col in @('Detect', 'Fix', 'Restore')) {
            $fn = [string]$d[$col]
            if (-not $fn) { continue }
            if (-not (Test-Path -LiteralPath ('function:' + $fn))) {
                throw ("检查器表：$($d.Id) 的 $col 指向不存在的函数 $fn")
            }
        }
        # 声明了 Fix 却没有 Restore = 「会改东西但没有回退的路」。
        # 这一条比函数存在性更要紧：它守的是用户按 r 时能不能真的退回去。
        if ($d.Fix -and -not $d.Restore) {
            throw ("检查器表：$($d.Id) 声明了修复却没有撤销函数")
        }
    }
}

# ------------------------------------------------------------------------------
# 2. 编排：跑一遍检查器，装配成一张 Finding 清单
# ------------------------------------------------------------------------------
# -Quick 只跑 Quick=$true 的（状态页）；不加是全量（体检页）。
# **一个函数、两种深度**，不是两套代码：复制一份轻量实现，迟早两边结论不一致。
#
# 某个检查器抛异常不许把整体带崩：它自己那一层变成一条 unreadable 记录，
# 其余层照常出结论。理由是失效模式——「一个检查器崩了 → 整屏空白」会让用户
# 以为网络没问题，而真相是「有一层没看见」。这与三态哲学同源：
# 「读不出来」必须与「没问题」分开。
# 这条 Finding 我们被授权去修吗？
#
# **这是「可修」的唯一判据，界面只许查它，不许自己按 Kind 猜。**
# 三件事一起看，缺一不可：
#   ① Kind 说的是「这条记录是什么性质的问题」；
#   ② 我们有没有被授权动这一层——由检查器表的 Fix 列回答；
#   ③ **这条记录自己说这股形态能不能安全改**（Data.Repairable）。
# 只看 Kind 会让「DNS 指向本机死端口」这种 Blocking 记录进「要修的是」，
# 而那一层根本没有 Fix：用户按 y，屏幕什么都不修，还说"它自己消失了"。
# 只看 Fix 会让 Clean 那类记录冒出「可以修」。
# 而 ③ 是随工具配置一起长出来的一维：同一个 cli-proxy 层里，
# `.npmrc` 删一行是安全的，`settings.xml` 的 <proxy> 块删一半会留下坏配置——
# 所以「能不能动」只能由**看得见文件格式的那一层**回答，不能由 Kind 或表猜。
function Test-FindingRepairable($Finding) {
    if ($null -eq $Finding) { return $false }
    if (-not (Test-FindingFixable ([string]$Finding.Kind))) { return $false }
    # 检查器 Id 就是 Finding Id 里第一个点号之前的那一段（dns.loopback -> dns）。
    $inspId = ([string]$Finding.Id) -replace '\..*$', ''
    $insp = Get-DoctorInspector $inspId
    if ($null -eq $insp) { return $false }
    $fn = [string]$insp.Fix
    if (-not $fn) { return $false }
    if (-not (Test-Path -LiteralPath ('function:' + $fn))) { return $false }
    # 没有声明这一维的层按「允许」处理：它们原本就走 Kind + Fix 两维，
    # 给个默认 false 会把系统代理那一层整体变成不可修。
    try {
        if ($Finding.Data -and $Finding.Data.ContainsKey('Repairable')) {
            return [bool]$Finding.Data.Repairable
        }
    } catch { }
    return $true
}

function Invoke-DoctorCheck {
    param([switch]$Quick)
    $findings = New-Object System.Collections.ArrayList
    foreach ($insp in $DoctorInspectors) {
        if ($Quick -and -not $insp.Quick) { continue }
        $fn = [string]$insp.Detect
        if (-not $fn) { continue }
        try {
            if (-not (Test-Path -LiteralPath ('function:' + $fn))) {
                throw ('读取函数 ' + $fn + ' 不存在')
            }
            foreach ($f in @(& $fn)) {
                if (-not $f) { continue }
                if (-not $f.Id) { $f.Id = [string]$insp.Id }
                [void]$findings.Add($f)
            }
        } catch {
            [void]$findings.Add((New-Finding -Id ($insp.Id + '.error') -Kind $FindingKinds.Unreadable `
                -Subject ([string]$insp.Title) -Where ([string]$insp.Id) `
                -Reason ('这一项没能检查：' + $_.Exception.Message) `
                -Advice '这一项没读出来，不代表没问题。可以到「问题反馈」生成一份报告。'))
        }
    }
    return $findings
}

# ------------------------------------------------------------------------------
# 3. 系统代理那一层的 Finding 包装
# ------------------------------------------------------------------------------
# **判断逻辑一个字没动**：还是 Get-SystemProxyLayers 产出的事实，只换了一层外壳。
# 这样「加检查器」对既有功能是零行为变更——一旦包装层开始自己判断，
# 就等于把 doctor 的判据抄成两份，两份迟早不一致。
function Get-SysProxyFindings {
    $out = New-Object System.Collections.ArrayList
    foreach ($L in @(Get-SystemProxyLayers)) {
        # 界面上那一组叫什么。内部层名不给人看：用户不知道 WinHTTP 是什么，
        # 但认得「浏览器代理」与「自动配置脚本」——那是他在系统设置里能点到的词。
        $where = switch ([string]$L.Layer) {
            'manual'  { '浏览器代理设置' }
            'pac'     { '自动配置脚本' }
            'winhttp' { '系统自带工具（不常见）' }
            default   { [string]$L.Layer }
        }
        [void]$out.Add((New-Finding `
            -Id ('sysproxy.' + [string]$L.Layer) `
            -Kind ([string]$L.Kind) `
            -Subject '浏览器代理' `
            -Where $where `
            -Value ([string]$L.Url) `
            -Reason ([string]$L.Detail) `
            -Advice ([string]$L.Advice) `
            -Evidence ([string]$L.Evidence) `
            -Data @{ Layer = [string]$L.Layer; Port = [int]$L.Port; Handshake = [string]$L.Handshake }))
    }
    return $out
}

# ------------------------------------------------------------------------------
# 4. 终端工具配置里的代理（cli-proxy 检查器）
# ------------------------------------------------------------------------------
# 为什么这是最该补的一块：它的判据与系统代理**完全同构**——
# 「本机回环 + 端口死」= 某个本机程序写的、而且写它的程序已经不在了。
# 同一个纯函数判，误伤率为零。
#
# 为什么环境变量救不了它：这些配置文件里写的代理**优先级高于环境变量**。
# EnvProxy 把变量管得再好，也压不过它。而现实里这些文件最常出现的毛病就是
# 「跟着某篇教程写死过一个本机端口，后来软件换了端口/卸载了」。
#
# 边界（比系统代理更严，因为这里动的是用户的文件，不是系统设置）：
#   · 只认「本机回环 + 端口不通」，与系统代理同一套判据；
#   · 非回环（公司代理）、读不出来 → 一律不动；
#   · 文件里有 include / includeIf → 不动：代理可能来自被包含的另一个文件；
#   · 只动命中行，不重写整个文件；改前整份原文进还原点，能逐字撤回。
#
# 三种修法（目标表的 Fix 列，见下表）：
#   drop       删掉那一项。给「自己认环境变量」的工具用：删掉之后它读 EnvProxy
#              注入的值，比改成某个具体端口更耐用——端口再变它自己跟上。
#   port       有活着的代理就改成当前端口，没有就删掉（Gradle / SSH）。
#   port-only  只能改端口，删不了：它们的配置是嵌套结构或成对元素
#              （YAML 的 proxy_servers、XML 的 <proxy>），删一半会留下坏配置。
#              没有活代理时**只报告不动手**——「拿不准就不动」在这里的落点。
#
# 这张表是唯一权威：加一个工具 = 加一行，读、判、修全部从它派生。
# 列的含义：
#   Id      稳定标识（进 Finding Id 与还原点）。两侧同 Id：同一个工具在两个平台上
#           必须叫同一个名字，否则报告与文档对不上（门禁 6 核对）。
#   Name    界面上那一组叫什么（用户认得的是工具名，不是文件名）。
#   Files   候选文件，形如 "根:相对路径"。根取 home / appdata（Win）/ support（Mac）。
#           一个工具可以有多个落点（pip 有三处、cargo 两处、curl 两处），**全查**：
#           多报一个不生效的旧文件，比漏报一个正在生效的有害得多。
#   Format  文件格式：kv / yaml / yaml-nested / yarnrc / xml / ssh
#   Section 段名（只有 kv 与 yaml-nested 用）：'http' / 'global' / 'proxy_servers'
#   Keys    命中哪些键（kv / yaml / yarnrc 用）
#   Pair    成对键：主机写一行、端口写一行（只有 Gradle 这样写）
#   Fix     修法：drop / port / port-only
$CliProxyTargets = @(
    @{ Id = 'git';        Name = 'Git 自己的代理';        Format = 'kv';          Section = '';              Keys = @('http.proxy', 'https.proxy'); Pair = @{}; Fix = 'drop'
       Files = @('home:.gitconfig') }
    @{ Id = 'npm';        Name = 'npm 自己的代理';        Format = 'kv';          Section = '';              Keys = @('proxy', 'https-proxy');      Pair = @{}; Fix = 'drop'
       Files = @('home:.npmrc') }
    @{ Id = 'curl';       Name = 'curl 自己的代理';       Format = 'kv';          Section = '';              Keys = @('proxy', 'x');                Pair = @{}; Fix = 'drop'
       Files = @('home:.curlrc', 'appdata:_curlrc') }
    @{ Id = 'cargo';      Name = 'Cargo 自己的代理';      Format = 'kv';          Section = 'http';          Keys = @('proxy');                     Pair = @{}; Fix = 'drop'
       Files = @('home:.cargo/config.toml', 'home:.cargo/config') }
    @{ Id = 'pip';        Name = 'pip 自己的代理';        Format = 'kv';          Section = 'global';        Keys = @('proxy');                     Pair = @{}; Fix = 'drop'
       Files = @('appdata:pip/pip.ini', 'home:pip/pip.ini') }
    @{ Id = 'wget';       Name = 'wget 自己的代理';       Format = 'kv';          Section = '';              Keys = @('http_proxy', 'https_proxy'); Pair = @{}; Fix = 'drop'
       Files = @('home:.wgetrc') }
    @{ Id = 'yarn';       Name = 'Yarn 自己的代理';       Format = 'yarnrc';      Section = '';              Keys = @('proxy', 'https-proxy');      Pair = @{}; Fix = 'drop'
       Files = @('home:.yarnrc') }
    @{ Id = 'yarn-berry'; Name = 'Yarn（新版）自己的代理'; Format = 'yaml';       Section = '';              Keys = @('httpProxy', 'httpsProxy');   Pair = @{}; Fix = 'drop'
       Files = @('home:.yarnrc.yml') }
    @{ Id = 'gradle';     Name = 'Gradle 自己的代理';     Format = 'kv';          Section = '';              Keys = @();                            Pair = @{ 'systemProp.http.proxyHost' = 'systemProp.http.proxyPort'; 'systemProp.https.proxyHost' = 'systemProp.https.proxyPort' }; Fix = 'port'
       Files = @('home:.gradle/gradle.properties') }
    @{ Id = 'conda';      Name = 'Conda 自己的代理';      Format = 'yaml-nested'; Section = 'proxy_servers'; Keys = @('http', 'https');             Pair = @{}; Fix = 'port-only'
       Files = @('home:.condarc') }
    @{ Id = 'maven';      Name = 'Maven 自己的代理';      Format = 'xml';         Section = '';              Keys = @();                            Pair = @{}; Fix = 'port-only'
       Files = @('home:.m2/settings.xml') }
    @{ Id = 'nuget';      Name = 'NuGet 自己的代理';      Format = 'xml';         Section = '';              Keys = @();                            Pair = @{}; Fix = 'port-only'
       Files = @('appdata:NuGet/NuGet.Config') }
    @{ Id = 'ssh';        Name = 'SSH 自己的代理';        Format = 'ssh';         Section = '';              Keys = @();                            Pair = @{}; Fix = 'port'
       Files = @('home:.ssh/config') }
)

# 根目录。取不到返回空串 = 这个文件在这台机器上不适用。
# **不写死任何盘符或用户名**：拿不到根目录还去拼一个路径，改的可能是别人的东西。
function Get-CliProxyRoot([string]$Root) {
    switch ($Root) {
        'appdata' {
            try { return [string]$env:APPDATA } catch { return '' }
        }
        # 'support'（mac 的 ~/Library/Application Support）在 Windows 侧不可达：
        # 本侧 $CliProxyTargets 的 Files 只用 home:/appdata: 两种前缀。
        # 这里不保留那个分支——留着会让后来的人以为"支持"是可用选项，
        # 写进表里却永远解析成空路径，症状是那一行的检查静默跳过。
        default {
            $h = ''
            try { $h = [string]$env:USERPROFILE } catch { $h = '' }
            if (-not $h) { try { $h = [string]$env:HOME } catch { $h = '' } }
            return $h
        }
    }
}

# 这个目标的全部候选绝对路径。
# $Target.Path 给定时只用它：这是「落点可指向别处」的机制——自检要跑真实读写，
# 但绝不能碰使用者的真文件。
function Get-CliProxyFilePaths($Target) {
    if (-not $Target) { return @() }
    if ($Target.Path) { return @([string]$Target.Path) }
    $out = @()
    foreach ($f in @($Target.Files)) {
        $spec = [string]$f
        if (-not $spec) { continue }
        $rootName = 'home'
        $rel = $spec
        $i = $spec.IndexOf(':')
        if ($i -gt 0) { $rootName = $spec.Substring(0, $i); $rel = $spec.Substring($i + 1) }
        $root = Get-CliProxyRoot $rootName
        if (-not $root) { continue }
        $rel = $rel.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $out += (Join-Path $root $rel)
    }
    return $out
}

# 从一行里取「键 = 值」。$Sep 决定认哪种写法：
#   equals  proxy = http://...       （gitconfig / npmrc / curlrc / pip.ini / cargo.toml / wgetrc / gradle.properties）
#   colon   httpProxy: "http://..."  （yarnrc.yml / condarc）
#   space   proxy "http://..."       （yarnrc classic）
#
# 行内注释**必须先剥掉**：`proxy = 127.0.0.1:7890 # clash` 是很常见的写法，
# 带着注释去解析会得到「值认不出来」，于是这个死端口永远查不出来——静默漏检。
# 剥的判据是「注释符前面有空白」：URL 里不会出现 ` #`，而人写注释总会空一格。
#
# 值两侧的引号必须剥掉，否则地址会带着引号进判据，判成「不是回环」→ 永不修。
function ConvertFrom-CliConfigLine([string]$Line, [string]$Sep = 'equals') {
    if (-not $Line) { return $null }
    $t = $Line.Trim()
    if (-not $t) { return $null }
    # 注释行：三种文件都用 # 或 ; 开头。**必须先判**，否则注释里的 proxy=
    # 会被当成真的设置去判、去修。
    if ($t.StartsWith('#') -or $t.StartsWith(';')) { return $null }
    if ($t.StartsWith('[')) { return $null }
    $t = [regex]::Replace($t, '\s+[#;].*$', '').TrimEnd()
    if (-not $t) { return $null }
    $m = $null
    switch ($Sep) {
        'colon' { $m = [regex]::Match($t, '^([A-Za-z][A-Za-z0-9_.\-]*)\s*:\s*(.*)$') }
        'space' { $m = [regex]::Match($t, '^([A-Za-z][A-Za-z0-9_.\-]*)\s+(.*)$') }
        default { $m = [regex]::Match($t, '^([A-Za-z][A-Za-z0-9_.\-]*)\s*=\s*(.*)$') }
    }
    if (-not $m.Success) { return $null }
    $v = $m.Groups[2].Value.Trim()
    # 剥引号：只在成对时剥，避免把值尾部的合法字符当引号删掉。
    if ($v.Length -ge 2) {
        if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) {
            $v = $v.Substring(1, $v.Length - 2)
        }
    }
    return @{ Key = $m.Groups[1].Value; Value = $v }
}

# .gitconfig 的段名会影响键的完整名字：`[http]` 段里的 `proxy` 是 `http.proxy`。
function Get-CliConfigKey([string]$Section, [string]$Leaf) {
    if (-not $Section) { return $Leaf }
    return ($Section + '.' + $Leaf)
}

# 读一个文件里所有代理项。返回 @{ Ok; Entries; HasInclude; Problem }
#   Ok         读成功了吗（文件不存在也算成功，条目为空）
#   Entries    @( @{ Line; Lines; Key; Value; Host; Port; FixLine; PortOnly; Raw } )
#              Line    这一项落在哪一行（单行项）
#              Lines   要删掉的话是哪几行（成对键是两行）
#              FixLine 要改端口的话改哪一行
#              PortOnly 那一行上只有端口数字（Gradle / XML 的 <port>）
#   HasInclude 文件里有 include / includeIf 段
#   Problem    读不出来时的一句原因
function Read-CliProxyFile($Target, [string]$Path) {
    $r = @{ Ok = $true; Entries = (New-Object System.Collections.ArrayList); HasInclude = $false; Problem = '' }
    if (-not $Path) { $r.Problem = '找不到这个文件所在的目录'; $r.Ok = $false; return $r }
    if (-not (Test-Item $Path)) { return $r }
    $lines = $null
    try {
        $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
    } catch {
        $r.Ok = $false; $r.Problem = $_.Exception.Message; return $r
    }
    switch ([string]$Target.Format) {
        'xml'         { Read-CliProxyXml $Target $lines $r }
        'ssh'         { Read-CliProxySshConfig $Target $lines $r }
        'yaml'        { Read-CliProxyKeyValue $Target $lines $r 'colon' }
        'yarnrc'      { Read-CliProxyKeyValue $Target $lines $r 'space' }
        'yaml-nested' { Read-CliProxyKeyValue $Target $lines $r 'colon' -Nested }
        default       { Read-CliProxyKeyValue $Target $lines $r 'equals' }
    }
    return $r
}

# 「一行一项」的三种写法共用这一份读法：差别只在分隔符、段头、父键。
#
# 两遍读。第一遍只为回答「这个文件里有没有 include」，第二遍才逐行判命中。
# 为什么必须两遍：`[include]` 段可能出现在文件任何位置——实测最常见的写法是
# 把它放在最后（`git config --global include.path ...` 就是追加到末尾）。
# 一遍扫的话，前面那些 proxy 行在被收集时还不知道后面有 include，
# 于是「有 include 就不动」这条护栏在最需要它的文件上失效——
# 而这个失效是静默的：屏幕上显示"可修"，删掉之后代理仍然从别处生效。
function Read-CliProxyKeyValue($Target, $Lines, $Result, [string]$Sep = 'equals', [switch]$Nested) {
    $want = @()
    foreach ($k in @($Target.Keys)) { if ($k) { $want += ([string]$k).ToLower() } }
    $pairHosts = @()
    $pairPorts = @()
    if ($Target.Pair) {
        foreach ($hk in @($Target.Pair.Keys)) {
            $pairHosts += ([string]$hk).ToLower()
            if ($Target.Pair[$hk]) { $pairPorts += ([string]$Target.Pair[$hk]).ToLower() }
        }
    }
    $wantAll = @($want + $pairHosts + $pairPorts)

    foreach ($line in $Lines) {
        $tt = ([string]$line).Trim()
        if (-not $tt.StartsWith('[')) { continue }
        $sm = [regex]::Match($tt, '^\[([^\]]*)\]')
        if (-not $sm.Success) { continue }
        $first = ($sm.Groups[1].Value -split '\s+')[0]
        $sec = $first.ToLower()
        if ($sec -eq 'include' -or $sec -eq 'includeif') { $Result.HasInclude = $true }
    }

    $section = ''
    $parent = ''
    $n = 0
    $hits = New-Object System.Collections.ArrayList
    foreach ($line in $Lines) {
        $n++
        $raw = [string]$line
        $t = $raw.Trim()
        if (-not $t) { continue }
        # 段头：[http] / [http "url"]。只取方括号里第一段词，引号里的东西不是段名的一部分。
        if ($t.StartsWith('[')) {
            $sm = [regex]::Match($t, '^\[([^\]]*)\]')
            if ($sm.Success) {
                $first = ($sm.Groups[1].Value -split '\s+')[0]
                $section = $first.ToLower()
            }
            $parent = ''
            continue
        }
        if ($t.StartsWith('#') -or $t.StartsWith(';')) { continue }
        $indented = ($raw -match '^\s')
        $kv = ConvertFrom-CliConfigLine $raw $Sep
        if (-not $kv) { continue }
        $leafL = $kv.Key.ToLower()
        $fullL = $leafL
        if ($Nested) {
            # 顶层且没有值 = 父键（`proxy_servers:`），下面的缩进行才是子项。
            if (-not $indented) {
                $parent = $leafL
                continue
            }
            if (-not $parent) { continue }
            $fullL = $parent + '.' + $leafL
            if ($Target.Section -and $parent -ne ([string]$Target.Section).ToLower()) { continue }
        } elseif ($Target.Section) {
            # 声明了段就只认这个段（cargo 的 [http]、pip 的 [global]）。
            if ($section -ne ([string]$Target.Section).ToLower()) { continue }
        } elseif ($section) {
            $fullL = $section + '.' + $leafL
        }
        $hit = $false
        foreach ($k in $wantAll) {
            if ($fullL -eq $k -or $leafL -eq $k) { $hit = $true; break }
        }
        if (-not $hit) { continue }
        [void]$hits.Add(@{ Line = $n; Key = $leafL; Full = $fullL; Value = [string]$kv.Value; Raw = $raw; Indented = $indented })
    }

    # ---- 成对键（Gradle）：主机与端口分两行写，必须凑齐才算一项 ----
    if ($Target.Pair -and @($Target.Pair.Keys).Count -gt 0) {
        foreach ($hk in @($Target.Pair.Keys)) {
            $pk = [string]$Target.Pair[$hk]
            $h = $null; $p = $null
            foreach ($x in $hits) {
                if (-not $h -and $x.Key -eq ([string]$hk).ToLower()) { $h = $x }
                if (-not $p -and $x.Key -eq ([string]$pk).ToLower()) { $p = $x }
            }
            # 只写了一行的是半截配置：判死会让用户以为「这里挡住了网络」，
            # 而那一行其实不生效。不产结论才是诚实的。
            if (-not $h -or -not $p) { continue }
            $pval = ([string]$p.Value).Trim()
            if ($pval -notmatch '^(\d{1,5})$') { continue }
            $port = [int]$Matches[1]
            if ($port -le 0 -or $port -gt 65535) { continue }
            $hv = ([string]$h.Value).Trim()
            if (-not $hv) { continue }
            $url = ConvertTo-ProxyUrl ($hv + ':' + [string]$port)
            if (-not $url) { continue }
            $sp = Split-ProxyUrl $url
            if (-not $sp) { continue }
            [void]$Result.Entries.Add(@{
                Line = [int]$p.Line; Lines = @([int]$h.Line, [int]$p.Line)
                Key = ([string]$hk)
                Value = $url; Host = [string]$sp.Host; Port = [int]$sp.Port
                FixLine = [int]$p.Line; PortOnly = $true
                Raw = (([string]$h.Raw) + ' / ' + ([string]$p.Raw))
            })
        }
        return
    }

    foreach ($x in $hits) {
        if (-not ([string]$x.Value)) { continue }
        $url = ConvertTo-ProxyUrl ([string]$x.Value)
        $hostName = ''; $port = 0
        if ($url) {
            $sp = Split-ProxyUrl $url
            if ($sp) { $hostName = [string]$sp.Host; $port = [int]$sp.Port }
        }
        [void]$Result.Entries.Add(@{
            Line = [int]$x.Line; Lines = @([int]$x.Line); Key = [string]$x.Full
            Value = [string]$x.Value; Host = $hostName; Port = $port
            FixLine = [int]$x.Line; PortOnly = $false; Raw = [string]$x.Raw
        })
    }
}

# Maven 的 settings.xml：<proxy> 块里 <host> 与 <port> 各是一个元素，
# 还能有 <active>false</active>（那一块根本不生效）与 <protocol>。
#
# 只认能完整读出的块：缺 host、缺 port、<active>false>、块没闭合——一律不产结论。
# 那种情况下我们连"它在挡哪条路"都说不清，说成故障就是编的。
function Read-CliProxyXml($Target, $Lines, $Result) {
    $inProxy = $false
    $blockStart = 0
    $hostName = ''; $port = 0; $active = 'true'; $proto = ''
    $portLine = 0
    $n = 0
    foreach ($line in $Lines) {
        $n++
        $t = ([string]$line).Trim()
        if (-not $t) { continue }
        # 整行注释直接跳过；块内的 XML 注释也不解析（拿不准就不动）。
        if ($t.StartsWith('<!--')) { continue }
        if (-not $inProxy) {
            if ($t -match '<proxy[\s>]' -or $t -match '<proxy$') {
                $inProxy = $true; $blockStart = $n
                $hostName = ''; $port = 0; $active = 'true'; $proto = ''
                $portLine = 0
            } else {
                # NuGet 的写法：<add key="http_proxy" value="http://127.0.0.1:7890" />
                if ($t -match '<add\b' -and $t -match '(?i)key\s*=\s*"http_proxy"' -and $t -match '(?i)value\s*=\s*"([^"]*)"') {
                    $val = $Matches[1]
                    $url = ConvertTo-ProxyUrl $val
                    if ($url) {
                        $sp = Split-ProxyUrl $url
                        if ($sp) {
                            [void]$Result.Entries.Add(@{
                                Line = $n; Lines = @($n); Key = 'http_proxy'
                                Value = $val; Host = [string]$sp.Host; Port = [int]$sp.Port
                                FixLine = $n; PortOnly = $false; Raw = $t
                            })
                        }
                    }
                }
                continue
            }
        }
        if ($t -match '<host>\s*([^<]*?)\s*</host>') { $hostName = $Matches[1] }
        if ($t -match '<port>\s*(\d{1,5})\s*</port>') { $port = [int]$Matches[1]; $portLine = $n }
        if ($t -match '<active>\s*([^<]*?)\s*</active>') { $active = $Matches[1].ToLower() }
        if ($t -match '<protocol>\s*([^<]*?)\s*</protocol>') { $proto = $Matches[1].ToLower() }
        if ($t -match '</proxy>') {
            if ($hostName -and $port -gt 0 -and $portLine -gt 0 -and $active -ne 'false') {
                $scheme = 'http'
                if ($proto -eq 'socks5' -or $proto -eq 'socks') { $scheme = 'socks5' }
                $url = ConvertTo-ProxyUrl ($hostName + ':' + [string]$port)
                if ($url) {
                    $sp = Split-ProxyUrl $url
                    if ($sp) {
                        [void]$Result.Entries.Add(@{
                            Line = $portLine; Lines = @($blockStart..$n); Key = 'proxy'
                            Value = ($scheme + '://' + $hostName + ':' + [string]$port)
                            Host = [string]$sp.Host; Port = [int]$sp.Port
                            FixLine = $portLine; PortOnly = $true; Raw = ('<proxy> ' + $hostName + ':' + [string]$port)
                        })
                    }
                }
            }
            $inProxy = $false
        }
    }
}

# SSH 的 ~/.ssh/config：OpenSSH 完全不看 HTTP_PROXY，只认 ProxyCommand / ProxyJump。
# 这里只找「本机回环地址 + 端口」那一种形态（常见写法是
# `ProxyCommand nc -X connect -x 127.0.0.1:7890 %h %p` 或 `connect -H 127.0.0.1:7890`）。
# 目标写成域名别名的（ProxyJump bastion）不是本机代理，不产结论。
function Read-CliProxySshConfig($Target, $Lines, $Result) {
    $n = 0
    foreach ($line in $Lines) {
        $n++
        $t = ([string]$line).Trim()
        if (-not $t) { continue }
        if ($t.StartsWith('#')) { continue }
        if ($t -notmatch '^(?i:ProxyCommand|ProxyJump)\s+(.+)$') { continue }
        $rest = [string]$Matches[1]
        if ($rest -notmatch '(?i)(127\.0\.0\.1|localhost|\[::1\])\s*:\s*(\d{1,5})') { continue }
        $addr = [string]$Matches[1]
        $port = [int]$Matches[2]
        if ($port -le 0 -or $port -gt 65535) { continue }
        $bare = $addr.Trim('[', ']')
        [void]$Result.Entries.Add(@{
            Line = $n; Lines = @($n); Key = 'ProxyCommand'
            Value = ('http://' + $bare + ':' + [string]$port)
            Host = $bare; Port = $port
            FixLine = $n; PortOnly = $false; Raw = $t
        })
    }
}

# 纯判据：给定一个配置文件里的代理值，说出结论。**不碰文件、不碰网络**，便于回归。
#
# 与 Get-SystemProxyVerdict 同源同形，只是少了两维：
# 配置文件里没有「被组策略管着」这一说，也没有 PAC 那种「慢但能上」的形态。
# 少掉不是简化，是那两件事在这个场景里真的不存在——**不做成通用参数再处处判断**。
function Get-CliProxyVerdict {
    param(
        [string]$Value,
        $Alive = $null,
        [bool]$HasInclude = $false
    )
    if (-not $Value) { return $FindingKinds.Clean }
    $url = ConvertTo-ProxyUrl $Value
    # 解析不出地址：认不出来就说什么都不做。**不许当 clean**——
    # clean 是「这里没设」，而这里明明写了一行我们看不懂的东西。
    if (-not $url) { return $FindingKinds.Foreign }
    if (-not (Test-LoopbackUrl $url)) { return $FindingKinds.Foreign }
    # 文件里有 include：代理可能来自别处，改这一行解决不了问题。
    # 归 foreign 而不是可修——「修了也没用」等于没修，报成修好就是谎报。
    if ($HasInclude) { return $FindingKinds.Foreign }
    # 说不清死活时不动：判成可修然后删掉一个其实在用的代理，代价是用户唯一的上网路径没了。
    if ($null -eq $Alive) { return $FindingKinds.Foreign }
    if ($Alive) { return $FindingKinds.Alive }
    return $FindingKinds.Blocking
}

# 这一项该怎么修（与目标表的 Fix 列不同：这里还看「现在有没有活着的代理」）。
#   drop       删掉那一项
#   port       改成当前端口
#   none       本工具不动手，只报告
function Get-CliProxyEntryMode($Target, $Live) {
    if (-not $Target) { return 'none' }
    switch ([string]$Target.Fix) {
        'port-only' { if ($Live) { return 'port' } return 'none' }
        'port'      { if ($Live) { return 'port' } return 'drop' }
        default     { return 'drop' }
    }
}

# 当前真正在用的本机代理端点（没有就返回 $null）。
#
# 判据只用**我们自己注入的那个值**：它是 EnvProxy 此刻认定的端口，而且必须是活的。
# 不在这里重新全端口扫描：救援页已经够慢，而且"我们的值指向一个活端口"就是
# 使用者此刻真正在用的那个——与状态页读同一个来源（env 层）。
function Get-CliLiveProxyEndpoint {
    $v = ''
    try { $v = [string](Get-EnvProxyValue) } catch { $v = '' }
    if (-not $v) { return $null }
    $sp = Split-ProxyUrl $v
    if (-not $sp) { return $null }
    if (-not (Test-TcpAlive (ConvertTo-ProbeHost $sp.Host) ([int]$sp.Port) 400)) { return $null }
    return @{ Host = [string]$sp.Host; Port = [int]$sp.Port }
}

# 给一条结论配一句人说。为什么必须有：屏幕上只写「能修」等于让用户盲信。
function Get-CliProxyReason {
    param(
        [string]$Kind,
        $Target,
        [string]$Value,
        $Alive = $null,
        [bool]$HasInclude = $false,
        [string]$Mode = 'drop',
        $Live = $null
    )
    switch ($Kind) {
        'clean'   { return '' }
        'alive'   { return '这里写的是本机地址，程序还开着，连得上。' }
        'residue-blocking' {
            $tool = ''
            if ($Target) { $tool = [string]$Target.Name }
            $s = ('这个文件里写着让 ' + $tool + ' 走本机的一个代理，但那个程序已经不在了。')
            if ($Mode -eq 'port' -and $Live) { $s += ('可以把它改到你现在在用的端口 ' + [string]$Live.Port + '。') }
            elseif ($Mode -eq 'none') { $s += '这种文件本工具不替你改。' }
            return $s
        }
        'foreign' {
            if ($HasInclude) { return '这个文件的代理设置可能是从别处读进来的，本工具不知道该改哪一个，所以不动。' }
            if (-not (ConvertTo-ProxyUrl $Value)) { return '这一项的值认不出来，所以不动它。' }
            return '这个代理不是这台电脑自己的，多半是公司或学校给的，本工具不碰。'
        }
        default   { return '' }
    }
}

function Get-CliProxyAdvice([string]$Kind, [string]$Mode) {
    if (-not (Test-FindingFixable $Kind)) { return '保持原样即可。' }
    switch ($Mode) {
        'port' { return '可以让本工具把它改成你现在在用的端口（会先备份，能还原）。' }
        'drop' { return '可以让本工具删掉那一行（会先备份，能还原）；删掉之后它会改用系统里的代理设置。' }
        'none' { return '这种格式本工具不替你改：把那一项删掉，或把端口改成你现在在用的那个。' }
        default { return '保持原样即可。' }
    }
}

# 读全部 CLI 配置文件，产出 Finding。
function Get-CliProxyFindings {
    $out = New-Object System.Collections.ArrayList
    $live = Get-CliLiveProxyEndpoint
    foreach ($target in $CliProxyTargets) {
        foreach ($path in @(Get-CliProxyFilePaths $target)) {
            if (-not $path) { continue }
            if (-not (Test-Item $path)) { continue }   # 没有这个文件：这一层不存在，不产结论
            $read = Read-CliProxyFile $target $path
            if (-not $read.Ok) {
                [void]$out.Add((New-Finding -Id ('cli-proxy.' + $target.Id) -Kind $FindingKinds.Unreadable `
                    -Subject ([string]$target.Name) -Where $path `
                    -Reason ('这个文件没读出来：' + [string]$read.Problem) `
                    -Advice '读不出来不代表没问题，但本工具不会去改它。'))
                continue
            }
            foreach ($e in $read.Entries) {
                $alive = $null
                if ($e.Host -and [int]$e.Port -gt 0) {
                    # 400 毫秒：回环连接要么立刻成功、要么立刻被拒；等更久没有意义，
                    # 而救援页要读十几个文件，每个都等 800 毫秒会把一屏拖到几秒。
                    $alive = Test-TcpAlive (ConvertTo-ProbeHost ([string]$e.Host)) ([int]$e.Port) 400
                }
                $kind = Get-CliProxyVerdict -Value ([string]$e.Value) -Alive $alive -HasInclude $read.HasInclude
                if ($kind -eq $FindingKinds.Clean) { continue }
                $mode = Get-CliProxyEntryMode $target $live
                [void]$out.Add((New-Finding `
                    -Id ('cli-proxy.' + $target.Id) `
                    -Kind $kind `
                    -Subject ([string]$target.Name) `
                    -Where $path `
                    -Value ([string]$e.Value) `
                    -Reason (Get-CliProxyReason -Kind $kind -Target $target -Value ([string]$e.Value) -Alive $alive -HasInclude $read.HasInclude -Mode $mode -Live $live) `
                    -Advice (Get-CliProxyAdvice -Kind $kind -Mode $mode) `
                    -Data @{
                        TargetId = [string]$target.Id
                        Lines    = @($e.Lines)
                        FixLine  = [int]$e.FixLine
                        PortOnly = [bool]$e.PortOnly
                        Host     = [string]$e.Host
                        Port     = [int]$e.Port
                        Key      = [string]$e.Key
                        Raw      = [string]$e.Raw
                        Mode     = $mode
                        Repairable = [bool](($mode -ne 'none') -and (Test-FindingFixable $kind))
                    }))
            }
        }
    }
    return $out
}

# 写回一个配置文件。**换行符按原文件的样子来**，不统一成 CRLF 也不统一成 LF。
#
# 为什么不能随便选一个：配置文件是用户的，别的工具会读它。把 LF 改成 CRLF
# 在多数场景无害，但它是**没被要求过的改动**——而这类改动每次修完都会让
# git diff 里多出整份文件的变更，用户下次自己改它时看不出哪一行是真的。
#
# 原子写：同目录临时文件 + 整体替换。就地截断中途失败，用户就得到半截的配置。
function Write-CliProxyFile([string]$Path, [string[]]$Lines, [string]$NewLine) {
    $text = ($Lines -join $NewLine)
    # 保留文件末尾的换行：删掉它会让下一次 diff 显示「最后一行变了」
    if ($Lines.Count -gt 0) { $text += $NewLine }
    Write-Text -Path $Path -Text $text -WithBom $false
}

# 这个文件用哪种换行。判据是「原文件里 CRLF 与裸 LF 哪个多」——
# 混用的文件按多数走，还原时逐字比的是完整内容，所以最终仍以还原点为准。
function Get-CliProxyNewLine([string]$Path) {
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $crlf = ([regex]::Matches($raw, "`r`n")).Count
        $lf = ([regex]::Matches($raw, "`n")).Count - $crlf
        if ($crlf -gt $lf) { return "`r`n" }
    } catch { }
    return "`n"
}

# 把一行里的旧端点换成新端点。返回换好的行；换不了返回 $null（调用方据此不写文件）。
#
# **只替换 host:port 那一段**：账号密码、协议、后面的路径一个字都不碰。
# 公司代理常写成 http://user:pass@host:port，整行重写会把密码抹掉——那是数据损坏。
function Set-CliProxyEndpointOnLine([string]$Line, [string]$OldHost, [int]$OldPort, [string]$NewHost, [int]$NewPort, [bool]$PortOnly) {
    if ($PortOnly) {
        $re = '(?<!\d)' + [string]$OldPort + '(?!\d)'
        $new = [regex]::Replace([string]$Line, $re, ([string]$NewPort), 1)
        if ($new -ne $Line) { return $new }
        return $null
    }
    $newText = if ($NewHost -like '*:*') { '[' + $NewHost + ']:' + [string]$NewPort } else { $NewHost + ':' + [string]$NewPort }
    $cands = @()
    if ($OldHost -like '*:*') { $cands += ('[' + $OldHost + ']:' + [string]$OldPort) }
    else { $cands += ($OldHost + ':' + [string]$OldPort); $cands += ('[' + $OldHost + ']:' + [string]$OldPort) }
    foreach ($c in $cands) {
        $idx = ([string]$Line).IndexOf($c, [System.StringComparison]::OrdinalIgnoreCase)
        if ($idx -ge 0) {
            return (([string]$Line).Substring(0, $idx) + $newText + ([string]$Line).Substring($idx + $c.Length))
        }
    }
    return $null
}

# 修：删掉判为死的行，或把它们改成当前端口。返回三态结论对象（与 Repair-SystemProxy 同形）。
#
# **逐行改，不重写整个文件**：配置文件是用户的，里面有他别的东西。
# 改之前把整份原文写进还原点；还原时整份写回去。
#
# 为什么还原点存全份而不是「被改的那几行」：用户可能在修完之后又改了文件，
# 按行号插回去会插错位置。存全份则还原的判据变成「内容逐字回到原样」，
# 那正是用户对「还原」的全部期待——对不上就如实报，不假装成功。
function Repair-CliProxyConfig {
    $res = @{
        Result = 'none'
        Changed = (New-Object System.Collections.ArrayList)
        Failed = (New-Object System.Collections.ArrayList)
        Detail = ''
    }
    $findings = @(Get-CliProxyFindings | Where-Object { (Test-FindingFixable $_.Kind) -and (Test-FindingRepairable $_) })
    if ($findings.Count -eq 0) { return $res }
    $live = Get-CliLiveProxyEndpoint

    # 按文件归组：同一个文件里改多行要一次改完，否则行号会互相错位。
    $byFile = @{}
    foreach ($f in $findings) {
        $p = [string]$f.Where
        if (-not $p) { continue }
        if (-not $byFile.ContainsKey($p)) { $byFile[$p] = New-Object System.Collections.ArrayList }
        [void]$byFile[$p].Add($f)
    }

    foreach ($path in $byFile.Keys) {
        $items = @($byFile[$path])
        if ($items.Count -eq 0) { continue }
        $original = ''
        try { $original = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) } catch {
            [void]$res.Failed.Add($path); continue
        }
        $targetId = [string]$items[0].Data.TargetId
        $fields = [ordered]@{
            inspector = 'cli-proxy'
            target    = $targetId
            path      = $path
            content   = $original
        }
        if (-not (Add-DoctorJournalEntry 'cli-proxy' $fields)) {
            # 备份写不下来就不动手：没有退路的修改不该发生。
            $res.Detail = 'nobackup'
            [void]$res.Failed.Add($path)
            continue
        }
        $nl = Get-CliProxyNewLine $path
        $lines = New-Object System.Collections.ArrayList
        foreach ($ln in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) { [void]$lines.Add($ln) }

        $dropNumbers = @()
        $touched = @()      # 我们动过的旧端点：回读时只看它们有没有真的消失
        $editFailed = $false
        foreach ($it in $items) {
            $mode = [string]$it.Data.Mode
            $oldHost = [string]$it.Data.Host
            $oldPort = [int]$it.Data.Port
            if ($mode -eq 'port') {
                $fixLine = [int]$it.Data.FixLine
                if (-not $live -or $fixLine -le 0 -or $fixLine -gt $lines.Count) { $editFailed = $true; break }
                $newLine = Set-CliProxyEndpointOnLine ([string]$lines[$fixLine - 1]) $oldHost $oldPort ([string]$live.Host) ([int]$live.Port) ([bool]$it.Data.PortOnly)
                if (-not $newLine) { $editFailed = $true; break }
                $lines[$fixLine - 1] = $newLine
                $touched += ($oldHost + '|' + [string]$oldPort)
                continue
            }
            foreach ($n in @($it.Data.Lines)) { $dropNumbers += [int]$n }
            $touched += ($oldHost + '|' + [string]$oldPort)
        }
        if ($editFailed) { [void]$res.Failed.Add($path); continue }
        # 按行号倒序删，否则删掉一行之后后面的行号就全错了。
        foreach ($n in ($dropNumbers | Sort-Object -Descending -Unique)) {
            $idx = $n - 1
            if ($idx -ge 0 -and $idx -lt $lines.Count) { $lines.RemoveAt($idx) }
        }
        try {
            Write-CliProxyFile $path @($lines) $nl
        } catch {
            [void]$res.Failed.Add($path); continue
        }
        # 回读确认：**我们动过的那几项**真的不在了才算修好。
        # 只看"文件里还有没有别的可修项"会误报：同一文件里可能还留着一条
        # 本工具不该动的项（比如没有活端口时的 port-only 项），那不是这次修复的失败。
        $target = Get-CliProxyTarget $targetId
        if (-not $target) { [void]$res.Failed.Add($path); continue }
        $after = Read-CliProxyFile $target $path
        $left = 0
        foreach ($e in $after.Entries) {
            $key = ([string]$e.Host + '|' + [string]$e.Port)
            if ($touched -notcontains $key) { continue }
            $alive = $null
            if ($e.Host -and [int]$e.Port -gt 0) { $alive = Test-TcpAlive (ConvertTo-ProbeHost ([string]$e.Host)) ([int]$e.Port) 400 }
            $k = Get-CliProxyVerdict -Value ([string]$e.Value) -Alive $alive -HasInclude $after.HasInclude
            if (Test-FindingFixable $k) { $left++ }
        }
        if ($left -eq 0) { [void]$res.Changed.Add($path) } else { [void]$res.Failed.Add($path) }
    }

    if ($res.Failed.Count -eq 0 -and $res.Changed.Count -gt 0) { $res.Result = 'fixed' }
    elseif ($res.Changed.Count -eq 0 -and $res.Failed.Count -gt 0) { $res.Result = 'failed' }
    elseif ($res.Changed.Count -gt 0) { $res.Result = 'partial' }
    return $res
}

# 按 Id 取 CLI 目标描述符（Repair 里回读要用它）。取不到返回 $null。
function Get-CliProxyTarget([string]$TargetId) {
    foreach ($t in $CliProxyTargets) { if ($t.Id -eq $TargetId) { return $t } }
    return $null
}

# 撤销一次 CLI 配置修复。返回 'ok' / 'failed' / 'skip'。
#
# 判据是「文件内容逐字回到原样」——这是用户对「还原」的全部期待。
# 内容对不上就报 failed：可能是他这期间又改了文件，那时硬写回去会覆盖他的新改动。
function Restore-CliProxySnapshot($Op) {
    if (-not $Op) { return 'skip' }
    $path = [string]$Op.Fields['path']
    if (-not $path) { return 'skip' }
    # content 里可能有换行，所以它走的是 ConvertFrom-DoctorBakValue 解出来的原样。
    $content = [string]$Op.Fields['content']
    if (-not $Op.Fields.Contains('content')) { return 'skip' }
    try {
        Write-Text -Path $path -Text $content -WithBom $false
    } catch {
        return 'failed'
    }
    $after = ''
    try { $after = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) } catch { return 'failed' }
    if ($after -cne $content) { return 'failed' }
    return 'ok'
}

# ------------------------------------------------------------------------------
# 4b. 只认 SOCKS 的端口（socks 检查器）——只解释，不动手
# ------------------------------------------------------------------------------
# 它回答的问题只有一句：「本机有个代理端口在跑，为什么这个工具说没有？」
# 答案通常是"那个端口只认 SOCKS5，而我们（以及多数终端工具）只认 HTTP 代理"。
#
# 结论词用 alive：端口活着、程序也在，只是它说的协议不是我们用的那一种——
# 与系统代理里"回环活着"是同一档含义（东西在那儿、不归我们碰）。
# **绝不因为发现了 SOCKS 口就把它当代理注入**：ALL_PROXY 指向纯 SOCKS 口会让
# 只认 HTTP 的工具全挂，比"没有代理"更糟。
function Get-SocksFindings {
    $out = New-Object System.Collections.ArrayList
    foreach ($p in @(Get-SocksOnlyPorts)) {
        $port = [int]$p.Port
        if ($port -le 0) { continue }
        $who = [string]$p.Client
        if (-not $who) { $who = '本机的一个程序' }
        [void]$out.Add((New-Finding `
            -Id ('socks.' + [string]$port) `
            -Kind $FindingKinds.Alive `
            -Subject '只认 SOCKS 的端口' `
            -Where ($who + ' 的 ' + [string]$port) `
            -Value ('socks5://127.0.0.1:' + [string]$port) `
            -Reason ('这个端口只认 SOCKS5，不认 HTTP 代理——所以本工具用不上它，' +
                     '只认环境变量的工具（git、npm、curl 这些）也走不了它。') `
            -Advice ('想让它给终端工具用：在客户端的设置里把 HTTP 代理或混合端口打开；' +
                     '或者把它填进那些只认 SOCKS 的程序里。') ))
    }
    return $out
}

# ------------------------------------------------------------------------------
# 5. 网址解析（dns 检查器）——只诊断，不动手
# ------------------------------------------------------------------------------
# 为什么只诊断：要「修」就得判「重置自动获取之后系统会拿到什么 DNS」，
# 而 Windows 不给这个答案——DHCP 还没发生，路由器的设置也无从预知。
# 判错会把用户手设的 223.5.5.5 换成路由器下发的坏地址，症状比故障更糟。
# 拿不准的时候不动，是这一层唯一安全的默认；但**必须说得出来**，
# 否则用户永远不知道去系统设置里看哪一处。
#
# 判据只用能证伪的两条：
#   dns-overlay   网卡级 NameServer 与 ProfileNameServer 同时存在且不同
#                 → 这类冲突在系统设置里看得见（那句「已设置所有 WLAN 网络的 DNS 设置」），
#                    我们能做的就是说清「你设了两处，生效的是哪一处」
#   dns-loopback  生效 DNS 指向本机/虚拟网段，且本机 53 端口没有程序在听
#                 → 与系统代理完全同构的两条客观事实叠加
# 其余（公共 DNS、公司 DNS、读不出来）一律 foreign / unreadable，不动也不吓人。

# DNS 地址属于哪一类。返回 'loopback' / 'fakeip' / 'other'。
#
# fakeip 段是 198.18.0.0/15（RFC 2544 的基准测试网段）：现实互联网与公司内网
# 都不会拿它当真实服务器地址，用它的只有翻墙软件的虚拟 IP 池。
function Get-DnsAddressClass([string]$Addr) {
    if (-not $Addr) { return 'other' }
    $a = $Addr.Trim().Trim('[', ']')
    if (-not $a) { return 'other' }
    if ($a -eq '::1' -or $a -eq 'localhost') { return 'loopback' }
    $parsed = $null
    if ([System.Net.IPAddress]::TryParse($a, [ref]$parsed)) {
        if ([System.Net.IPAddress]::IsLoopback($parsed)) { return 'loopback' }
        if ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
            $b = $parsed.GetAddressBytes()
            # 198.18.0.0/15 = 198.18.x.x 与 198.19.x.x
            if ($b[0] -eq 198 -and ($b[1] -eq 18 -or $b[1] -eq 19)) { return 'fakeip' }
        }
        return 'other'
    }
    return 'other'
}

# 把 "223.5.5.5,180.76.76.76" 或 "223.5.5.5 180.76.76.76" 拆成数组。
function ConvertFrom-DnsList([string]$Raw) {
    $out = @()
    if (-not $Raw) { return $out }
    foreach ($p in ($Raw -split '[,;\s]+')) {
        $t = $p.Trim()
        if ($t) { $out += $t }
    }
    return $out
}

# 读当前活跃网卡的 DNS 两层。返回 @{ Ok; Adapter; Servers; ProfileServer; Problem }
#
# **不靠解析 netsh 的文本**：netsh 的输出是按系统语言本地化的
# （「静态配置的 DNS 服务器」/「Statically Configured」/「直接アクセス」……），
# 靠匹配自然语言在非中文非英文的系统上必然失明。注册表值名是 ASCII 常量，
# 与系统语言无关。
#
# ProfileNameServer 是 Win11 里「所有 WLAN 网络的 DNS」那一处设置的单值形态：
# 它非空时，单个 Wi-Fi 的 DNS 设置会被系统忽略（设置页上那句黄字说的就是它）。
function Get-DnsLayerState {
    $r = @{ Ok = $false; Adapter = ''; AdapterGuid = ''; Servers = @(); ProfileServer = ''; Problem = '' }
    # 找当前有默认路由的那块网卡：静置的网卡上有什么 DNS 与用户此刻上不上网无关，
    # 读它们只会让结论被无关数据带偏。
    $alias = ''
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
        if ($route) { $alias = [string]$route.InterfaceAlias }
    } catch { $alias = '' }
    if (-not $alias) { $r.Problem = '读不到当前在用的网卡'; return $r }
    $r.Adapter = $alias
    $guid = ''
    try {
        $nic = Get-NetAdapter -Name $alias -ErrorAction Stop
        $guid = [string]$nic.InterfaceGuid
    } catch { $guid = '' }
    if (-not $guid) { $r.Problem = '读不到这块网卡的标识'; return $r }
    $r.AdapterGuid = $guid
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $guid
    if (-not (Test-RegKey $key)) { $r.Problem = '这块网卡没有网络设置记录'; return $r }
    $servers = @()
    $profile = ''
    try {
        $v = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
        $servers = @(ConvertFrom-DnsList ([string]$v.NameServer))
        if ($v.PSObject.Properties.Name -contains 'ProfileNameServer') {
            $profile = [string]$v.ProfileNameServer
        }
    } catch {
        $r.Problem = $_.Exception.Message; return $r
    }
    $r.Servers = $servers
    $r.ProfileServer = $profile
    $r.Ok = $true
    return $r
}

# 读全部 DNS 层，产出 Finding。
function Get-DnsFindings {
    $out = New-Object System.Collections.ArrayList
    $st = Get-DnsLayerState
    if (-not $st.Ok) {
        [void]$out.Add((New-Finding -Id 'dns.state' -Kind $FindingKinds.Unreadable `
            -Subject '网址解析' -Where '网卡设置' `
            -Reason ('这一项没读出来：' + [string]$st.Problem) `
            -Advice '读不出来不代表没问题，但本工具不会去改它。'))
        return $out
    }
    $servers = @($st.Servers)
    $profile = [string]$st.ProfileServer
    $profileList = @(ConvertFrom-DnsList $profile)

    # ---- 网卡级与「所有 WLAN」两处设置打架 ----
    # 判据是两条客观事实同时成立：两处都有值，且两处不一样。
    # 只有一处有值时不产结论——那不是冲突，就是正常的一种设置方式。
    if ($servers.Count -gt 0 -and $profileList.Count -gt 0) {
        $same = (($servers -join ',') -eq ($profileList -join ','))
        if (-not $same) {
            [void]$out.Add((New-Finding -Id 'dns.overlay' -Kind $FindingKinds.Foreign `
                -Subject '网址解析' -Where ($st.Adapter + ' 的 DNS 设置') `
                -Value ($profileList -join '、') `
                -Reason ('你给「所有网络」设了 ' + ($profileList -join '、') + '，所以单独给某几个 Wi-Fi 设的 ' + ($servers -join '、') + ' 不会生效。') `
                -Advice '两处都留着一个设置，系统只用其中一处。想统一就去系统设置里把多余的删掉；本工具不改 DNS。' `
                -Data @{ Tag = 'dns-conflict' }))
        }
    }

    # ---- 生效的 DNS 指向本机/虚拟网段，且那里没有程序在听 ----
    # 「生效」取网卡级那份：有它就它说了算（它压过单个 Wi-Fi 的设置，与系统设置页一致）。
    $effective = if ($servers.Count -gt 0) { $servers } else { $profileList }
    foreach ($addr in $effective) {
        $cls = Get-DnsAddressClass $addr
        if ($cls -ne 'loopback' -and $cls -ne 'fakeip') { continue }
        # 本机 53 端口有没有程序在听：这是第二个客观事实。
        # 只听 TCP 不够（DNS 主要走 UDP），但**判活只连端口**是本项目的一贯判据，
        # 而且「TCP 也没有」已经足以说明「本机没有能应答的 DNS 服务」。
        $alive53 = Test-TcpAlive '127.0.0.1' 53 300
        if ($alive53) {
            [void]$out.Add((New-Finding -Id 'dns.loopback' -Kind $FindingKinds.Alive `
                -Subject '网址解析' -Where ($st.Adapter + ' 的 DNS 设置') `
                -Value $addr `
                -Reason ('DNS 指向本机，本机确实有个程序在处理。') `
                -Advice '不需要做什么。'))
        } else {
            [void]$out.Add((New-Finding -Id 'dns.loopback' -Kind $FindingKinds.Blocking `
                -Subject '网址解析' -Where ($st.Adapter + ' 的 DNS 设置') `
                -Value $addr `
                -Reason ('网址解析被指到本机的 ' + $addr + '，但那里没有程序在听——网页会打不开，而聊天软件可能还是好的。') `
                -Advice '这一项本工具不自动改：改错了会把你的网络换成路由器的设置。到系统设置的网络属性里，把 DNS 改回「自动获取」即可。'))
        }
    }
    return $out
}

# 把一条还原点就地撤销。返回 'ok' / 'failed' / 'skip'。
#
# 这是**分发点**：按 `inspector` 字段决定调哪一层的撤销实现。
# 它住在 insp 层而不是 doctor 层，理由是依赖方向——doctor 是叶子，
# 它不该知道自己有哪几层；每层把快照写给自己，但「撤销最近一次」只有一个入口。
function Restore-FindingSnapshot($Op) {
    if (-not $Op) { return 'skip' }
    $insp = ''
    try { $insp = [string]$Op.Fields['inspector'] } catch { $insp = '' }
    switch ($insp) {
        'sysproxy'  { return (Restore-SysProxySnapshot $Op) }
        'cli-proxy' { return (Restore-CliProxySnapshot $Op) }
        default { return 'skip' }
    }
}

# 撤销最近一次修复。返回三态（**不许塌缩**）：
#   Result = 'none'    没有可还原的记录
#          = 'ok'      撤销完成，且回读对上了
#          = 'failed'  写了但回读没对上
#   Undone / Left  分别是撤掉的层与没撤成的层
#
# 只撤销**最近一条**：与「撤销上一次修复」这个说法一致，也是用户按 r 时的心理预期。
# 更早的记录留在日志里，以后再按一次就是再往上撤销一条。
function Restore-DoctorJournal {
    $res = @{
        Result = 'none'
        Undone = (New-Object System.Collections.ArrayList)
        Left   = (New-Object System.Collections.ArrayList)
        Inspector = ''
    }
    $ops = @(Read-DoctorJournal)
    if ($ops.Count -eq 0) { return $res }
    $last = $ops[$ops.Count - 1]
    $res.Inspector = [string]$last.Fields['inspector']
    $outcome = Restore-FindingSnapshot $last
    switch ($outcome) {
        'ok'     { [void]$res.Undone.Add($res.Inspector) }
        'failed' { [void]$res.Left.Add($res.Inspector) }
        default  { }   # skip：记录读不懂，什么都没做
    }
    if ($res.Left.Count -eq 0 -and $res.Undone.Count -gt 0) {
        $res.Result = 'ok'
    } elseif ($res.Undone.Count -eq 0 -and $res.Left.Count -eq 0) {
        $res.Result = 'none'
    } elseif ($res.Undone.Count -eq 0) {
        $res.Result = 'failed'
    } else {
        $res.Result = 'partial'
    }
    # 撤的是旧版单槽位备份（doctor.bak）时，**只在真的撤销成功之后**才删它。
    # 判定必须在 $res.Result 结算之后：原来这段写在结算之前，那时 Result 还是初值
    # "none"，"none -ne failed" 恒为真——撤失败也删，用户唯一一次回退机会就没了。
    # mac 侧写的是"只有 ok 才删"，两侧必须同形。
    if ($res.Result -eq 'ok' -and [string]$last.OpId -eq 'legacy-bak') {
        try { if (Test-Item (Get-SysProxyBackupPath)) { Remove-Item -LiteralPath (Get-SysProxyBackupPath) -Force } } catch { }
    }
    # 撤成功就从日志里消费掉那一段，让「再按一次往上撤一条」真的成立。
    # 不消费的话，再按 r 取到的还是同一段，等于反复还原同一次——
    # 而函数头那句注释早就这么承诺了（说了没做，比不说更糟）。
    # 撤失败或跳过时**不动日志**：那一段还有用，用户可能想再试一次。
    # 旧版单槽位备份（legacy-bak）不走这里：它根本没有对应的日志段。
    if ($res.Result -eq 'ok' -and [string]$last.OpId -ne 'legacy-bak') {
        $rest = @($ops | Select-Object -First ($ops.Count - 1))
        [void](Write-DoctorJournalOps $rest)
    }
    return $res
}

# ------------------------------------------------------------------------------
# 6. 救援页：遍历 Finding，不认任何具体检查器
# ------------------------------------------------------------------------------
# 这一屏只回答三件事：有没有问题、问题出在哪一行、我该敲什么。
# 结构是「一句话结论 → 要动的那些行 → 一条分隔线 → 动作」。
#
# 两条硬规矩（改之前先读）：
#   1) 不给使用者看内部名词。「WinHTTP」这种词他看不懂，也没法据此行动。
#   2) 结论用色块区分严重度：ok 绿（没事）、warn 黄（要修）、dim 灰（说明）。
#
# **它不认识任何检查器名字**：三个区（要修的 / 不归我碰的 / 只是提醒的）
# 全部按 Kind 分组算出来。加一层检查器，这一屏一个字都不用改。
function Show-RescuePage {
    Clear-Screen
    Write-Styled 'title' (Format-TitleRule '网络与代理修复')
    Write-Host ''
    # 第一句就说清它管到哪儿。名字里带「网络」，但用户到这里时心里想的是
    # 「我整个网都不行」——不说清，他会以为这一屏能修所有上网问题，
    # 查完没事就以为网络确实没问题，然后往错的方向找。
    Write-Styled 'dim' '  查浏览器、终端工具、网址解析这几处设置是不是指错了地方，'
    Write-Styled 'dim' '  顺带看看本机有没有只认 SOCKS 的端口（那种端口本工具用不了）。'
    Write-Styled 'dim' '  只修「指向本机、但那个程序已经不在」的残留。'

    try { Assert-DoctorInspectors } catch {
        Write-Host ''
        Write-Styled 'warn' ('  ' + $_.Exception.Message)
        Write-Styled 'dim' (Format-ExitHint 'BackToMenu')
        try { [void](Read-Host) } catch { }
        return
    }

    $findings = @(Invoke-DoctorCheck)
    # 按 Kind 分三组。**这就是「界面不认检查器」的全部实现**：
    # 它只回答「哪一档该放哪个区」，与是哪一层毫无关系。
    $fixable = @($findings | Where-Object { Test-FindingRepairable $_ })
    # 「挡住网络」这句话承诺的是"下面这些按 y 能修好"，所以只数真能修的那些。
    # 把不可修的也算进来，用户会看到"发现 1 处挡住了网络"、按 y 却什么都不发生。
    $blocking = @($fixable | Where-Object { $_.Kind -eq $FindingKinds.Blocking })
    $slowing  = @($fixable | Where-Object { $_.Kind -eq $FindingKinds.Slowing })
    $foreign  = @($findings | Where-Object { $_.Kind -eq $FindingKinds.Foreign })
    $managed  = @($findings | Where-Object { $_.Kind -eq $FindingKinds.Managed })
    # 读不出来的一层不能静默消失，也不能混进「你没动」那一组（那组的语义是
    # 「东西在那儿、只是不归我碰」，而读不出来连是什么都不知道）。
    # **故意不渲染**：它不参与任何判断，纯粹是探测本身失败。
    # 印出来只会让使用者看到「系统给的格式认不出来」这种他无法行动、也无需知道的话。
    # 诊断信息归问题报告，那里的读者是排查的人，不是正在看病的使用者。
    # 「端口活着、但握手说它连不上外面」——只有拿到握手证据时才认这一档。
    # 拿不到握手时**不算**，绝不凭猜给用户指方向。
    $aliveBroken = @($findings | Where-Object {
        $_.Kind -eq $FindingKinds.Alive -and [string]$_.Data.Handshake -eq 'upstream-fail'
    })
    # 「只是提醒」这一组混了两个来源，语义都是「用户该知道，但本工具不动手」：
    #   ① 不归我们碰、但有话要说的（地址冲突那种）；
    #   ② **问题确实存在、但这一层根本没有 Fix 的**（DNS 指向本机死端口就是）。
    # ② 必须单独立一项：它既不该进「要修的」（按 y 什么都不会发生），
    #   也不能进「不归我碰的」（那是别人的设置，而这是我们看得见、只是没授权动）。
    # 漏了它这条记录就会从三个区里全部消失——比误报更难发现。
    # 判**结构化标记**，不判中文文案。
    # 原来这里是 `Reason -match '不会生效'`：改一次措辞（「不会生效」写成「不生效」），
    # 这条就从「只是提醒」掉进「不归我碰的」——不报错、不失败，静默换区。
    $hints = @($foreign | Where-Object { [string]$_.Data.Tag -eq 'dns-conflict' })
    $hints += @($findings | Where-Object {
        (Test-FindingFixable $_.Kind) -and -not (Test-FindingRepairable $_)
    })

    # ---- 结论 ----
    Write-Host ''
    $outOfScope = $false
    if ($blocking.Count -gt 0) {
        Write-Styled 'warn' ('  查完了：发现 {0} 处残留设置挡住了网络。' -f $blocking.Count)
    } elseif ($slowing.Count -gt 0) {
        Write-Styled 'warn' ('  查完了：发现 {0} 处设置指向已经关掉的程序。' -f $slowing.Count)
        Write-Styled 'dim'  '          网络能通，但每次都要先等它几秒。'
    } elseif ($aliveBroken.Count -gt 0) {
        Write-Styled 'warn' '  查完了：设置本身没坏，但代理连不上外面。'
        Write-Styled 'dim'  '          这多半是节点的问题。关掉重开代理软件，或者换一个节点。'
        $outOfScope = $true
    } else {
        # 「本工具不自动改、但问题确实存在」的那些（DNS 指向死端口就是）。
        # **必须先于「没发现问题」判**：那三个计数只统计可修项，
        # 所以 DNS 那种「Blocking 但没有 Fix」不会进任何一个——
        # 落进 else 就成了"屏幕第一句说你没问题"，紧接着的提醒区却在说网页会打不开。
        # 这类误报平安比不说更坏：它会让人排除掉唯一真实的原因。
        $realButUnfixable = @($hints | Where-Object { Test-FindingFixable $_.Kind })
        if ($realButUnfixable.Count -gt 0) {
            Write-Styled 'warn' ('  查完了：发现 {0} 处问题，但本工具不自动改（见下面的提醒）。' -f $realButUnfixable.Count)
            $outOfScope = $true
        } else {
            # 「几处」按本轮实际查过的层数说，不写死数字：写死的话，
            # 某侧少查一层（mac 没有 DNS 检查）时这句话就是假的。
            $checkedCount = @($DoctorInspectors | Where-Object { Test-Path -LiteralPath ('function:' + [string]$_.Detect) }).Count
            Write-Styled 'ok' ('  查完了：这几处设置都没发现问题（共查了 {0} 处）。' -f $checkedCount)
            $outOfScope = $true
        }
    }

    # ---- 要修的那些行 ----
    # 一行一项：「[这一组叫什么]  值  为什么」。分组名来自 Finding.Subject，
    # 所以新加一层检查器时这里自动多一行，不用改这个函数。
    if ($fixable.Count -gt 0) {
        Write-Host ''
        Write-Styled 'warn' '  要修的是：'
        $w = 0
        foreach ($f in $fixable) {
            $dw = Get-DisplayWidth ([string]$f.Subject)
            if ($dw -gt $w) { $w = $dw }
        }
        foreach ($f in $fixable) {
            $pad = ' ' * [Math]::Max(0, $w - (Get-DisplayWidth ([string]$f.Subject)))
            $val = if ($f.Value) { [string]$f.Value } else { '（读不出地址）' }
            Write-Styled 'text' ('    [' + [string]$f.Subject + ']' + $pad + '  ' + $val)
            if ($f.Reason) { Write-Styled 'dim' ('      ' + [string]$f.Reason) }
            # Advice 是「使用者能做什么」。写了就得显示——不显示的话，
            # 最需要它的那一类（"这一项本工具不自动改，你自己去系统设置里改"）
            # 就永远只在代码里存在，用户看不到。
            if ($f.Advice) { Write-Styled 'dim' ('      ' + [string]$f.Advice) }
        }
    }

    # ---- 只是提醒的那些（不归我碰，但用户该知道） ----
    if ($hints.Count -gt 0) {
        Write-Host ''
        Write-Styled 'dim' '  发现的网络状况（只是提醒，本工具不改）：'
        foreach ($f in $hints) {
            Write-Styled 'text' ('    [' + [string]$f.Subject + ']  ' + [string]$f.Reason)
            if ($f.Advice) { Write-Styled 'dim' ('      ' + [string]$f.Advice) }
        }
    }

    # ---- 不归我们碰的那些 ----
    # 合并成一句，不逐条展开——那是使用者的东西，说清「我没动」就够。
    # hints 已经在上面单独说过，这里不再重复数。
    $otherForeign = @($foreign | Where-Object { $hints -notcontains $_ })
    $untouched = $otherForeign.Count + $managed.Count
    if ($untouched -gt 0) {
        Write-Host ''
        Write-Styled 'dim' ('  另外 {0} 项是你自己设的，本工具不碰：' -f $untouched)
        foreach ($f in $otherForeign) {
            $v = if ($f.Value) { [string]$f.Value } else { '（地址没读到）' }
            Write-Styled 'dim' ('    [' + [string]$f.Subject + ']  ' + $v)
        }
        foreach ($f in $managed) {
            Write-Styled 'dim' ('    [' + [string]$f.Subject + ']  （这台电脑由管理员统一管着）')
        }
    }

    # 读不出来的那一层不在这里显示：它不参与任何判断，纯粹是探测本身失败。
    # 印出来只会让使用者看到「系统给的格式认不出来」这种他无法行动、也无需知道的话。
    # 诊断信息归问题报告，那里读者是排查的人，不是正在看病的使用者。

    # ---- 兜底说明：讲清这一屏查不到什么 ----
    # Proxifier / Netch / SSTap / 各种加速器走的是驱动、TUN 网卡与路由表，
    # 它们出问题时上面这三处设置里一个字节都不会变——扫这些地方永远扫不出来。
    if ($outOfScope) {
        Write-Host ''
        Write-Styled 'dim' '  如果还是上不了网，那问题不在这里：'
        Write-Styled 'dim' '  可能是虚拟网卡（TUN）、路由表、或者防火墙规则。'
    }

    # ---- 动作 ----
    #
    # 分隔线只在这里用一条：把「上面是情况」和「下面是你要敲什么」分开。
    #
    # 「能不能还原」与「当下有没有可修项」是两件事，必须分开判断。
    # 最容易撞上的正是这个时序：昨天修过（还原点已写），今天客户端换回原来的端口，
    # 现在没有可修项了，用户想把设置改回原样——若在这里按「可修项为零」提前返回，
    # 他只会看到「按回车返回」，r 根本敲不到；而帮助页白纸黑字承诺了那条路。
    Write-Host ''
    Write-Styled 'dim' ('  ' + (Format-PlainRule '网络与代理修复'))
    Write-Host ''
    $hasBackup = $false
    try { $hasBackup = Test-DoctorJournalHasRestore } catch { $hasBackup = $false }
    if ($fixable.Count -eq 0 -and -not $hasBackup) {
        Write-Styled 'dim' (Format-ExitHint 'BackToMenu')
        try { [void](Read-Host) } catch { return }
        return
    }
    if ($fixable.Count -gt 0) {
        Write-Styled 'text' ("  输 y 回车 = 修好上面那 {0} 项（会先备份，能还原）" -f $fixable.Count)
    }
    if ($hasBackup) {
        Write-Styled 'dim' '  输 r 回车 = 撤销上一次修复'
    }
    Write-Styled 'dim' '  直接回车 = 什么都不做，返回'
    $ans = ''
    try { $ans = "$(Read-Host '选择')".Trim() } catch { return }
    if ($ans -match '^(r|R)$') {
        if (-not $hasBackup) { return }
        $rr = Restore-DoctorJournal
        Write-Host ''
        switch ([string]$rr.Result) {
            'ok' { Write-Styled 'ok' '  [完成] 已经改回上一次修复之前的样子。' }
            'partial' {
                Write-Styled 'warn' '  [未完成] 只改回去一部分。'
                Write-Styled 'dim' '  可以再试一次；还不行就用主菜单的「问题反馈」生成一份报告。'
            }
            'none' { Write-Styled 'dim' '  没有可还原的记录。' }
            default { Write-Styled 'warn' '  [未完成] 没能改回去。可以再试一次。' }
        }
        Write-Styled 'dim' (Format-ExitHint 'BackToMenu')
        try { [void](Read-Host) } catch { }
        return
    }
    if (-not ($ans -match '^(y|Y|yes|YES|是)$')) { return }
    if ($fixable.Count -eq 0) { return }

    # ---- 真动手：按检查器分组，各修各的 ----
    #
    # **只调表里声明的 Fix**，不认具体名字。修的顺序按注册表顺序（网络 → 浏览器 → 终端），
    # 因为越靠下的一层越可能是上层症状的来源。
    #
    # 任何一层报「备份写不下来」都立刻停手：没有退路的修改不该发生，
    # 而前一层已经改过的东西仍然可以由 r 撤销。
    Write-Host ''
    $results = New-Object System.Collections.ArrayList
    $aborted = $false
    foreach ($insp in $DoctorInspectors) {
        if (-not $insp.Fix) { continue }
        $mine = @($fixable | Where-Object { $_.Id -like ($insp.Id + '.*') })
        if ($mine.Count -eq 0) { continue }
        $fn = [string]$insp.Fix
        if (-not (Test-Path -LiteralPath ('function:' + $fn))) { continue }
        $r = $null
        try { $r = & $fn } catch { $r = @{ Result = 'failed'; Detail = $_.Exception.Message } }
        [void]$results.Add(@{ Inspector = [string]$insp.Id; Title = [string]$insp.Title; Result = $r })
        if ($r -and [string]$r.Detail -eq 'nobackup') { $aborted = $true; break }
    }

    # 结论必须三态，不许把「部分失败」压成「修好了」。
    $anyFixed = $false
    $anyFailed = $false
    $anyPartial = $false
    foreach ($x in $results) {
        $k = ''
        if ($x.Result -and $x.Result.Result) { $k = [string]$x.Result.Result }
        switch ($k) {
            'fixed'   { $anyFixed = $true }
            'partial' { $anyPartial = $true }
            'failed'  { $anyFailed = $true }
            'nobackup' { $anyFailed = $true }
            'none'    { }
            default   { }
        }
    }
    if ($aborted) {
        Write-Styled 'warn' '  [未完成] 备份写不下来，为了安全停在这里。'
        Write-Styled 'dim'  '  已经改过的部分可以输 r 撤销。确认日志目录可写之后再来一次。'
    } elseif ($anyFailed -or $anyPartial) {
        Write-Styled 'warn' '  [未完成] 修好了一部分，还有没改成的。'
        foreach ($x in $results) {
            $k = ''
            if ($x.Result -and $x.Result.Result) { $k = [string]$x.Result.Result }
            if ($k -eq 'fixed' -or $k -eq 'none') { continue }
            if (-not $k) { continue }
            Write-Styled 'dim' ('  没改成的：' + [string]$x.Title)
        }
        Write-Styled 'dim' '  可以再试一次；还不行就用主菜单的「问题反馈」生成一份报告。'
    } elseif ($anyFixed) {
        Write-Styled 'ok' '  [完成] 修好了。'
        Write-Styled 'dim' '  浏览器要是还打不开，把它关掉重开一次。'
        Write-Styled 'dim' '  终端里已经开着的窗口也一样，重开一个即可。'
    } else {
        Write-Styled 'dim' '  查的时候还在，动手的时候已经没了（可能是你自己关掉了）。'
    }

    # 拨号/VPN 连接各存一份代理设置，我们只改 LAN 那份。
    # 不把这条说出来，用户就会得到「修好了但还是打不开」——而那正是最伤人的那种失败。
    $otherConns = @()
    try { $otherConns = @(Get-OtherConnectionProxyNames) } catch { $otherConns = @() }
    if ($otherConns.Count -gt 0) {
        Write-Host ''
        Write-Styled 'warn' '  另外还有连接存着自己的代理设置，这次没有检查：'
        foreach ($cn in $otherConns) { Write-Styled 'text' ('    ' + $cn) }
        Write-Styled 'dim'  '  如果你在用拨号或 VPN 上网，请在上面那个连接里看一下代理设置。'
    }
    Write-Styled 'dim' (Format-ExitHint 'BackToMenu')
    try { [void](Read-Host) } catch { }
    return
}
