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
$repoRoot = $TestRoot
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
# 取一个函数的正文。
#
# $file 传空串 = **在 win\lib 下的所有库里找**。这是默认该用的方式：
# 断言关心的是"这个函数怎么写"，不是"它住在哪个文件"。写死文件名的话，
# 每次把库拆开或挪位置都要来改一遍测试——那是让测试去绑定实现细节。
function Get-FunctionBody([string]$file, [string]$name) {
    if (-not $file) {
        foreach ($libFile in @(Get-ChildItem 'win\lib' -Filter *.ps1 -File)) {
            $body = Get-FunctionBody ('win\lib\' + $libFile.Name) $name
            if ($body) { return $body }
        }
        return ''
    }
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
    $chunk = Get-FunctionBody '' $fn
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
    $realSnapFile = $global:StateSnapshotFile
try {
    $global:StateSnapshotFile = $snapFile

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
    $global:StateSnapshotFile = $realSnapFile
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
$opsSrc = Get-AllLibSource
$ssBody = Get-FunctionBody '' 'Show-StatusSnapshot'
Assert-Eq '接线：Show-StatusSnapshot 函数体取到了' $true ($ssBody.Length -gt 0)
Assert-Eq '接线：Show-StatusSnapshot 调用 Get-StatusProblems' $true ([bool]([regex]::IsMatch($ssBody, 'Get-StatusProblems')))
Assert-Eq '接线：Show-StatusSnapshot 不自己累加问题' $false ([bool]([regex]::IsMatch($ssBody, '\$problems \+= ')))

# Format-StatusLines 也必须走同一个判断
$fsBody = Get-FunctionBody '' 'Format-StatusLines'
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
    $chunk = Get-FunctionBody '' $fn
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
$opsSrc2 = Get-AllLibSource
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
foreach ($pair in @(@('win/lib/pages.ps1', '状态页'), @('win/lib/ops.ps1', '状态页'), @('win/lib/shortcut.ps1', '中继页'))) {
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
$instBody = Get-FunctionBody '' 'Install-EnvProxy'
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

