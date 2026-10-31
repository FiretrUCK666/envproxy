# ==============================================================================
#  help.ps1 — 菜单与帮助层：菜单表、菜单渲染、帮助主题、帮助渲染
#  菜单编号的唯一权威处是下面的 $MenuItems；散文里写「选 N」时一律从这张表取。
#  这是**唯一**一处：写死的数字会在菜单重排后指向错的命令，那不是排版问题，
#  是把人引到一个会改坏东西的动作上。
# ==============================================================================

function Get-MenuRenderedLines {
    $nameW = Get-MenuNameWidth
    $out = @()
    $hl = Get-MonitorProcess
    $verText = Get-LocalVersion
    if (-not $verText) { $verText = "未知" }
    $out += [pscustomobject]@{ Role = 'title'; Text = '======== EnvProxy 菜单 ========'
                               Segments = @(@{ Role = 'title'; Text = '======== EnvProxy 菜单 ========' }) }
    # 抬头是这一屏最该被看到的一行：用户打开菜单九成的目的是"我现在正常吗"，
    # 答案就在这里（监控在跑 = 正常，未运行 = 有问题）。
    # 早先整行用 dim（暗灰），等于把答案压到最暗、还给它贴了"背景信息"的标签；
    # 而"怎么修"的编号反而是亮绿——优先级是反的。
    # 现在拆两段：标签用灰（它确实是背景），**状态值用 ok/warn**（与状态页同一套语义）。
    $monRole = if ($hl) { 'ok' } else { 'warn' }
    $monText = if ($hl) { ("运行中 (PID {0})" -f $hl.ProcessId) } else { '未运行' }
    $segs = @(
        @{ Role = 'dim'; Text = '  监控 ' },
        @{ Role = $monRole; Text = $monText },
        @{ Role = 'dim'; Text = ("    版本 v{0}" -f $verText) }
    )
    $joined = ''
    foreach ($sg in $segs) { $joined += $sg.Text }
    $out += [pscustomobject]@{ Role = 'dim'; Text = $joined; Segments = $segs }
    # 未运行时补一句可执行的话：打开菜单 → 第一行就知道好不好 → 坏了直接告诉按哪个键。
    if (-not $hl) {
        $hint = '        按 1 可以让它重新跑起来'
        $out += [pscustomobject]@{ Role = 'dim'; Text = $hint
                                   Segments = @(@{ Role = 'dim'; Text = $hint }) }
    }
    foreach ($g in (Get-MenuGroups)) {
        $items = @($MenuItems | Where-Object { $_.Group -eq $g })
        if ($items.Count -eq 0) { continue }
        $out += [pscustomobject]@{ Role = 'blank'; Text = ''; Segments = @() }
        $out += [pscustomobject]@{ Role = 'heading'; Text = ('  ' + $g)
                                   Segments = @(@{ Role = 'heading'; Text = ('  ' + $g) }) }
        foreach ($mi in $items) {
            # 退出项没有动作，编号跟着变暗：亮绿色的编号会让人以为"它跟别的项一样要跑个什么"。
            $keyRole = if ($mi.Switch) { 'cmd' } else { 'dim' }
            $segs = @(
                @{ Role = $keyRole; Text = ('    ' + $mi.Key) },
                @{ Role = 'value';  Text = ('  ' + (Format-MenuCell $mi.Name $nameW)) }
            )
            if ($mi.Hint) { $segs += @{ Role = 'dim'; Text = ('   ' + $mi.Hint) } }
            $joined = ''
            foreach ($s in $segs) { $joined += $s.Text }
            $out += [pscustomobject]@{ Role = 'item'; Text = $joined; Segments = $segs }
        }
    }
    $out += [pscustomobject]@{ Role = 'blank'; Text = ''; Segments = @() }
    $out += [pscustomobject]@{ Role = 'dim'; Text = '  输编号后回车执行    直接回车 = 查看状态'
                               Segments = @(@{ Role = 'dim'; Text = '  输编号后回车执行    直接回车 = 查看状态' }) }
    return $out
}

# 带配色地把菜单打到屏幕上。与 Format-MenuText 同源（Get-MenuRenderedLines），只差上不上色。
# 渲染整张菜单（纯文本）。打印与测试共用内容，保证"表里有什么，屏幕就有什么"。
function Format-MenuText {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($r in (Get-MenuRenderedLines)) { [void]$out.Add($r.Text) }
    return ($out -join "`n")
}

function Show-MenuColored {
    foreach ($r in (Get-MenuRenderedLines)) {
        if ($r.Role -eq 'blank') { Write-Host ''; continue }
        foreach ($s in $r.Segments) { Write-Styled $s.Role $s.Text -NoNewline }
        Write-Host ''
    }
}

# 帮助正文的缩进。所有角色都在 2 格或更深，**没有一个是 0**：
# 标题贴到最左边时，屏幕上看起来像"这一行不属于任何结构"，而正文却缩进 2 格——
# 结果是标题比内容更靠外，读起来是内容在往里缩，整页重心散掉（实测用户第一眼就说"贴边"）。
# 现在标题与正文同级（都在 2 格），子项再往内一层：
#
#   标题        ← 2 格：与它下面的正文左边缘对齐
#   正文        ← 2 格
#     子项编号  ← 4 格：比正文深一层，表示"这是上面那句话的分项"
#         说明  ← 6 格：子项的补充，比子项再深一层
#       命令   ← 6 格：跟说明同一层，因为它解释的通常就是上一句
#     左列|右列 ← 4 格：表格行与子项同级
$HelpRoleIndent = @{
    'h'  = 2
    't'  = 2
    't2' = 6
    'i'  = 4
    'w'  = 2
    'c'  = 6
    'r'  = 4
    'rc' = 4
    'm'  = 4
    'b'  = 0
}

# 把一行带标记的正文拆成「角色 + 各列」。
# 标记认不出来时按正文处理并把整行原样显示：宁可颜色不理想，也不能把内容弄丢。
function Split-HelpLine([string]$Line) {
    $code = ''
    $rest = ''
    $sp = $Line.IndexOf(' ')
    if ($sp -ge 0) { $code = $Line.Substring(0, $sp); $rest = $Line.Substring($sp + 1) }
    else { $code = $Line }
    if (-not $HelpRoleIndent.ContainsKey($code)) { $code = 't' }
    $rowKey = ''
    $name = ''
    $hint = ''
    $text = $rest
    if ($code -eq 'r' -or $code -eq 'rc') {
        $bar = $rest.IndexOf('|')
        if ($bar -ge 0) { $rowKey = $rest.Substring(0, $bar); $text = $rest.Substring($bar + 1) }
        else { $code = 't' }
    } elseif ($code -eq 'm') {
        $parts = $rest -split '\|', 3
        if ($parts.Count -ge 2) {
            $rowKey = $parts[0]; $name = $parts[1]
            if ($parts.Count -ge 3) { $hint = $parts[2] }
            $text = ''
        } else { $code = 't'; $text = $rest }
    }
    return [pscustomobject]@{ Code = $code; Indent = $HelpRoleIndent[$code]
                              RowKey = $rowKey; Name = $name; Hint = $hint; Text = $text }
}

# 把一段带标记的正文渲染成"屏幕上真正出现的那些行"。
#
# 每一行是若干「颜色段」（Role + Text）拼起来的：一行一个颜色表达不了
# "编号是绿的、名字是白的、说明是灰的"，而那正是主菜单教给用户的分层读法。
# 于是纯文本输出把各段拼成整行，彩屏逐段上色，两边读的是同一份渲染结果——
# "屏幕上有、测试里没有"不可能发生。
#
# 多列行的列宽在这里统一算：同一块里所有同类行补到同一个宽度，别的行不参与
# （否则一段长正文会把列撑得很宽）。
function Get-HelpRenderedLines([string[]]$Lines) {
    $parsed = @()
    foreach ($l in $Lines) { $parsed += (Split-HelpLine $l) }
    # ---- 空行由这里统一补，正文里不写 b ----
    #
    # 手写空行是"有的地方记得、有的地方忘了"，屏幕上就是一段挤一段松。这种不一致
    # 单看每一行都挑不出错，但整页读起来就是"没排好"——用户说不出来，只觉得别扭。
    # 所以改由结构决定，谁也不用记。规则三条：
    #
    #   一、标题上下各空一行。下面必须空：标题在给下面的内容起头，挤着就开始读很闷。
    #       上面必须空：每个标题因此成为独立一段，块与块自然分开。
    #       （第一个标题的上面不空，它紧接页头。）
    #   二、表格块（连续的 r/rc/m 行）前后各空一行，块内行与行之间不空。
    #       表格是嵌在正文里的另一类东西，两侧不留白会跟正文糊在一起；
    #       而块内逐行空行会把它拆成一格一段，那正是"散"的来源。
    #   三、**带说明的编号条目之间空一行**。判据是"这一条后面跟了它自己的说明或命令"：
    #       那种条目是"小标题 + 一段话"的结构，两条挤在一起会让人以为说明属于下一条。
    #       而**连续的编号条目**（每条只有一行、没有附属内容）之间**不空**——
    #       它们是一个并列的清单，逐条空行会把三件并列的事读成三件互不相干的事。
    #
    # 于是每个主题的骨架完全一样：标题、空行、内容、空行、标题……
    $isTable = { param($c) $c -and ($c.Code -eq 'r' -or $c.Code -eq 'rc' -or $c.Code -eq 'm') }
    # 条目（i）的"从属行"：它自己的说明（t2）、命令（c/rc/r）、警告（w）。
    # 这些都是"属于上一条"的内容，不该与条目平级。
    $isItemChild = { param($c) $c -and ($c.Code -eq 't2' -or $c.Code -eq 'c' -or $c.Code -eq 'rc' -or $c.Code -eq 'r' -or $c.Code -eq 'w') }
    $spaced = @()
    $n = $parsed.Count
    for ($i = 0; $i -lt $n; $i++) {
        $cur = $parsed[$i]
        $next = if ($i -lt $n - 1) { $parsed[$i + 1] } else { $null }
        # 标题前 / 表格块开始前 / 带说明的条目之前要空
        if ($i -gt 0) {
            $prev = $parsed[$i - 1]
            $prevTbl = & $isTable $prev
            $curTbl = & $isTable $cur
            $needBlank = $false
            if ($cur.Code -eq 'h') { $needBlank = $true }
            elseif ($curTbl -and -not $prevTbl) { $needBlank = $true }
            # 编号条目之间：上一条带自己的说明（t2）或非表格命令（c）时，说明那一段结束了，
            # 新条目要另起一段。判据看**上一行是不是从属行**，而不是看上一行是不是 i——
            # 「2.」后面跟的是它的 t2，到「3.」时上一行是 t2 不是 i，按代码值比会漏掉，
            # 表现就是两条说明挤在一起、让人以为下面那句属于上一条。
            elseif ($cur.Code -eq 'i' -and (& $isItemChild $prev)) { $needBlank = $true }
            if ($needBlank) { $spaced += (Split-HelpLine 'b ') }
        }
        $spaced += $cur
        # 标题后 / 表格块结束后
        if ($cur.Code -eq 'h') {
            $spaced += (Split-HelpLine 'b ')
        } elseif ((& $isTable $cur) -and $next -and -not (& $isTable $next)) {
            $spaced += (Split-HelpLine 'b ')
        }
    }
    # 去掉连续空行与首尾空行：上面几条规则会在边界各补一次，重了就是两三个空行。
    $parsed = @()
    foreach ($r in $spaced) {
        if ($r.Code -eq 'b') {
            if ($parsed.Count -eq 0) { continue }
            if ($parsed[$parsed.Count - 1].Code -eq 'b') { continue }
        }
        $parsed += $r
    }
    while ($parsed.Count -gt 0 -and $parsed[$parsed.Count - 1].Code -eq 'b') {
        $parsed = @($parsed | Select-Object -First ($parsed.Count - 1))
    }
    $keyW = 0
    $nameW = 0
    foreach ($r in $parsed) {
        if ($r.RowKey) {
            $w = Get-DisplayWidth $r.RowKey
            if ($w -gt $keyW) { $keyW = $w }
        }
        if ($r.Name) {
            $w = Get-DisplayWidth $r.Name
            if ($w -gt $nameW) { $nameW = $w }
        }
    }
    $out = @()
    foreach ($r in $parsed) {
        $pad = ' ' * $r.Indent
        $segs = @()
        $role = 'text'
        switch ($r.Code) {
            'b'  { $role = 'blank' }
            'h'  { $role = 'heading'; $segs += @{ Role = 'heading'; Text = ($pad + $r.Text) } }
            'i'  { $role = 'item';    $segs += @{ Role = 'item';    Text = ($pad + $r.Text) } }
            'w'  { $role = 'warn';    $segs += @{ Role = 'warn';    Text = ($pad + $r.Text) } }
            'c'  { $role = 'cmd';     $segs += @{ Role = 'cmd';     Text = ($pad + $r.Text) } }
            'r'  { $role = 'row'
                   $segs += @{ Role = 'key';  Text = ($pad + (Format-MenuCell $r.RowKey $keyW) + '   ') }
                   $segs += @{ Role = 'text'; Text = $r.Text } }
            'rc' { $role = 'row'
                   $segs += @{ Role = 'key';  Text = ($pad + (Format-MenuCell $r.RowKey $keyW) + '   ') }
                   $segs += @{ Role = 'cmd';  Text = $r.Text } }
            'm'  { $role = 'row'
                   $segs += @{ Role = 'cmd';   Text = ($pad + $r.RowKey + '  ') }
                   $segs += @{ Role = 'value'; Text = (Format-MenuCell $r.Name $nameW) }
                   if ($r.Hint) { $segs += @{ Role = 'dim'; Text = ('   ' + $r.Hint) } } }
            default { $segs += @{ Role = 'text'; Text = ($pad + $r.Text) } }
        }
        $joined = ''
        foreach ($s in $segs) { $joined += $s.Text }
        $out += [pscustomobject]@{ Role = $role; Segments = $segs; Text = $joined }
    }
    return $out
}

# 帮助的内容表：每个主题一屏放得下，进帮助先看目录，选一个只看那一段。
# 为什么这么分：一次性把十几屏内容全刷出来，看到后面已经忘了前面讲什么；
# 按"我此刻想解决什么"分主题，再配一个固定的返回行，用户随时能退回来换一段看。
# 每条格式：键 / 标题（目录里显示）/ 正文行数组（带角色标记，见上面 Split-HelpLine）。
function Get-HelpTopics {
    # 项目地址在帮助里出现三处（关于、求助、反馈），只在这里取一次。
    # 唯一来源是 Get-ProjectUrls（从官网源的 Base 派生），换远端只改那一处。
    $proj = Get-ProjectUrls
    $HelpProjHome = $proj.Home
    $HelpProjIssue = $proj.Issues
    return @(
        @{
            Key = '1'; Title = '这是干什么用的'; Short = '用处'
            Lines = @(
                'h 它做什么',
                't 你的翻墙软件只管浏览器，不管终端里的 git、npm、curl。',
                't 这个工具补上这一段：翻墙软件一开，它们跟着能翻；一关，自动恢复。',
                't 你什么都不用记，也不用每次敲开关。',
                'b ',
                'h 它怎么知道你现在在翻墙',
                't 每 2 到 3 秒看一次，要同时满足三条才算：',
                'i 1. 你电脑上确实有程序开着一个口子（端口）在等连接；',
                'i 2. 那个口子确实是个翻墙代理，会按规矩回应；',
                'i 3. 它确实连得到外面，试 6 个端点（几个常用的检测网址）任意一个通就算。',
                't 三条全过才动手。所以你本机开着网页服务、开发服务器都不会被误认。',
                't 它不认品牌、不认程序名、不认端口号——那些只用来加快查找。',
                'h 它是谁做的、在哪',
                't 这是开源项目。代码、新版、问题反馈都在这一个地址：',
                ('i ' + $HelpProjHome)
            )
        },
        @{
            Key = '2'; Title = '装完之后要我做什么'; Short = '装完'
            Lines = @(
                'h 按窗口分三种情况，多半你属于第一种',
                'b ',
                'i 1. 装完之后才打开的窗口',
                't2 启动时读到的就是当前状态，什么都不用做。',
                'b ',
                'i 2. 装完之后打开的窗口，后来翻墙软件又开了或关了',
                't2 按一次回车即可（cmd 窗口只能重开，见下面第 3 条）。',
                'b ',
                'i 3. 装之前就已经开着的窗口',
                't2 同步代码还没装进去。在那个窗口里敲下面这一条，或者重开窗口：',
                'b ',
                'rc PowerShell|. $PROFILE',
                'rc Git Bash|source ~/.bashrc',
                'r cmd|没有这条命令，只能重开窗口',
                'b ',
                'h 为什么要按一次回车',
                't 每个程序只在启动那一刻读一次「该走哪个代理」，读完就固定了。',
                't 之后系统再改，已经在跑的窗口不会跟着变。',
                't 这个工具挑的时机是每次命令跑完、等你回到能打字的时候同步——',
                't 你本来就一直在敲命令，所以不用专门做什么。'
            )
        },
        @{
            Key = '3'; Title = '这个窗口不要翻墙 / 用公司的代理'; Short = '窗口'
            Lines = @(
                'h 一、让这个窗口一直不翻墙',
                'rc PowerShell|$env:ENVPROXY_TERM = ''off''',
                'rc Git Bash|export ENVPROXY_TERM=off',
                't 下次回到提示符才生效，别的窗口照旧跟着翻墙软件走。',
                't cmd 没这个开关，只能自己清 5 个变量（& 两边别留空格）：',
                ('rc cmd|set ' + ((@($ProxyVarNames) | ForEach-Object { $_ + '=' }) -join '&set ')),
                'w 别用 unset HTTP_PROXY：大写清不掉小写，curl 照样用代理。',
                'h 二、让这个窗口用公司的代理',
                't 公司代理和自动跟随只能选一个，先做第一节再设地址（反了会被盖掉）。',
                't 地址端口问公司 IT 要，不是翻墙软件那个（下面 A 换成它）：',
                'rc PowerShell|$env:HTTPS_PROXY = ''http://A:端口''',
                'rc Git Bash|export HTTPS_PROXY=http://A:端口',
                'rc cmd|set HTTPS_PROXY=http://A:端口',
                't 上面这条够 git、curl、npm 用。有程序还是不认，就再抄下面这条：',
                'rc PowerShell|$env:ALL_PROXY = ''http://A:端口''; $env:NODE_USE_ENV_PROXY = ''1''',
                'rc Git Bash|export ALL_PROXY=http://A:端口; export NODE_USE_ENV_PROXY=1',
                'rc cmd|set ALL_PROXY=http://A:端口&set NODE_USE_ENV_PROXY=1',
                'h 三、改回自动跟随',
                'rc PowerShell|Remove-Item Env:ENVPROXY_TERM',
                'rc Git Bash|unset ENVPROXY_TERM',
                'r cmd|重开一个窗口',
                't 清掉 ENVPROXY_TERM 就都撤回了。改回来公司地址会被盖掉——那是对的，',
                't 表示回到自动；地址没删，只是不用。'
            )
        },
        @{
            Key = '4'; Title = '某条命令不想翻墙'; Short = '命令行'
            Lines = @(
                'h 每个工具写法不一样，没有通用的一条命令',
                'h curl',
                'rc PowerShell|curl.exe --noproxy "*" https://example.com',
                'rc cmd|curl --noproxy "*" https://example.com',
                'rc Git Bash / Mac|curl --noproxy "*" https://example.com',
                't PowerShell 5.1 必须写 .exe（它把 curl 当别名，不写会报参数找不到）；',
                't cmd 和 PowerShell 7 里写不写都行。',
                'h git 和 npm',
                'rc 三个窗口一样|git -c http.proxy= -c https.proxy= clone 仓库地址',
                'rc 三个窗口一样|npm --noproxy=registry.npmjs.org install 包名',
                't git 等号后留空 = 这条不用代理；写别的值 = 改用那个代理。',
                'w npm 的 --noproxy 只认具体网址，写 * 没用也不报错，请求还是翻墙。',
                't 写成 --no-proxy 会被当成 --proxy=false，也不是不用代理。',
                'h wget（Windows 不自带，装过才有）',
                'rc Git Bash / Mac|wget --no-proxy https://example.com',
                'rc PowerShell|wget.exe --no-proxy https://example.com',
                'h docker',
                't 没有单条命令的写法，改 Docker 自己的设置（Settings 里的 Proxies）。',
                'h 这些参数是各工具自己的，不是这个工具提供的',
                't 不加时它们才读这个工具写进系统的代理。',
                't 想确认绕过去了：跑一下那条命令，能通就是绕过了。',
                't 反而连不上，把参数去掉再试一次，就分清是参数问题还是网络问题。'
            )
        },
        @{
            Key = '5'; Title = '某个程序还是翻不了墙'; Short = '软件'
            Lines = @(
                'h 有些程序不认系统设的代理',
                't 它们只在启动那一刻读一次「该走哪个代理」，之后怎么变都不理。',
                't 而它们多半是从桌面或任务栏点的，那一层拿不到这个工具设的值。',
                'h 解决办法：给它建一个能翻墙的图标',
                't 菜单选 5 进高级功能，再选 1。挑程序（或输入路径），选放哪，确认。',
                # @explain 「走代理」是图标名的后缀，帮助必须与桌面上的名字对上
                't 它会生成一个新图标，名字后面带「走代理」。以后点那个就能翻墙。',
                'b ',
                'h 注意三件事',
                't 程序已经开着的，点了不会换代理，必须先关掉再点。',
                't 微软商店装的应用（没有独立 exe 的那种）不支持。',
                't 新图标可以拖到任务栏固定；固定后删掉桌面那个不影响使用。',
                'b ',
                'h 翻墙软件换了端口之后',
                't 用上面那些图标开的程序不受影响，照常用就行。',
                't 会停在旧地址上的，只有「启动那一刻读一次」的程序（从桌面点开的那种）。',
                't 终端里的新开一个窗口就跟随；PowerShell 与 Git Bash 敲一下回车即可。',
                't 出现这种情况时会自动弹一句提示，不用你盯着。',
                'b ',
                'h 固定入口是干什么的',
                't 有些程序会把你给的地址写进它自己的设置里，之后一直用那个。',
                't 翻墙软件一换端口它们就连不上，而你还得去它的设置里改一遍。',
                't 固定入口在本机开一个永不变的地址，程序只认这个，背后自动跟着翻墙软件走。',
                't 建图标时自动就用它，不用你做什么；它跟着监控一起跑，也没有开关要拨。',
                't 它没在工作也不要紧：图标会退回去读当前地址，照样能用。',
                't 想看它现在的状态：菜单选 5 再选 3，那一屏只看不改。',
                'b ',
                'h 不想要了',
                't 菜单选 5 再选 2，能看状态、逐个删。'
            )
        },
        @{
            Key = '6'; Title = '出问题了：怎么查、怎么报'; Short = '出问题'
            Lines = @(
                'h 先按这个顺序查，多数问题到第二步就好了',
                'b ',
                'i 1. 在出问题的窗口里敲下面这一条，看有没有地址',
                't2 有地址 = 设好了；空的 = 没设上，重开一个窗口试试。',
                'rc PowerShell|$env:HTTPS_PROXY',
                'rc cmd|set HTTPS_PROXY',
                'rc Git Bash|echo $HTTPS_PROXY',
                'b ',
                'i 2. 看菜单最上面那行写的什么',
                "t2 写「未运行」就选 $(Get-MenuRef 'Install')。",
                'i 3. 两个常见误会',
                't2 npm 只认 HTTPS_PROXY，不认 HTTP_PROXY；你自己清过它就不走了。',
                't2 「翻墙代理」有、「代理变量」无 = 翻墙软件在跑、这个工具被停了，不是坏了。',
                'h 还是不行：把问题报上去',
                "t 菜单选 $(Get-MenuRef 'Report')。它先问你四句话，再自动补上这台机器的情况，",
                't 存成一个文件、把路径复制好。你不用找日志，也不用敲命令。',
                't 然后把文件内容贴到这里（本项目只在这里收问题）：',
                ('i ' + $HelpProjIssue),
                'h 想彻底删掉它',
                "t 菜单选 $(Get-MenuRef 'Uninstall')。会问你要不要留日志。",
                'h 不开菜单也能用（写脚本、远程连过来的时候）',
                'r 日常|-Install -Status -Stop -Uninstall -Update',
                'r 其它|-Help -Menu -Advanced -Report',
                'r 补充|-Yes 跳过确认  -Purge 连日志一起删  -RepairProfile 摘掉孤立标记'
            )
        },
        @{
            Key = '7'; Title = '上不了网（关了翻墙软件之后）'; Short = '上不了网'
            Lines = @(
                'h 先分清是哪种"上不了网"',
                't 浏览器打不开、但别的程序照常 = 浏览器这边的问题。',
                't 什么都连不上 = 网络本身的问题，跟这个工具无关。',
                'b ',
                'h 最常见的原因：翻墙软件没关干净',
                't 多数翻墙软件退出时会把自己写进系统的设置撤掉。',
                't 被强制关机、断电、或者直接点了叉，就没来得及撤。',
                't 那条设置还在，浏览器就照旧去找一个已经不存在的程序，',
                't 于是国内网站也打不开——这不是网断了，是路指错了。',
                'b ',
                'h 怎么自己修',
                "i 1. 菜单选 $(Get-MenuRef 'Advanced')，里面选网络救援",
                't2 它会说清查到什么；能修的问你一句才动手，改之前先备份。',
                'i 2. 按 y 回车',
                't2 修完把浏览器关掉重开一次再看。',
                'b ',
                'h 什么东西它不会动',
                't 公司、学校给你的代理，它一个字节都不碰。',
                't 被管理员统一管着的也不碰，那种改了也会被改回去。',
                't 它只修「指向本机、但程序已经不在了」的那种。',
                'b ',
                'h 修错了想改回去',
                't 再进那一屏，按 r 回车就能还原成修之前的样子。',
                'b ',
                'h 还不行',
                "t 用菜单选 $(Get-MenuRef 'Report')生成报告，贴到项目页面。",
                't 报告里有网络体检的结论，不用你另外描述。'
            )
        }
    )
}

# 帮助目录屏的内容。整屏只有这一份：纯文本与彩屏都从它取，
# 于是"改一个字只改一处"，也不可能出现"屏幕上有、测试里没有"。
#
# 编号用命令色、标题用强调色、底部说明用灰：与主菜单同一套三层区分，
# 用户在两个页面之间切换时不用重新认一遍。
function Get-HelpIndexRenderedLines {
    $ver = Get-LocalVersion
    if ([string]::IsNullOrWhiteSpace($ver)) { $ver = '未知' }
    $out = @()
    $out += [pscustomobject]@{ Role = 'title'; Text = '================ EnvProxy 帮助 ================'
                               Segments = @(@{ Role = 'title'; Text = '================ EnvProxy 帮助 ================' }) }
    $out += [pscustomobject]@{ Role = 'blank'; Text = ''; Segments = @() }
    # 引导语与下面的清单之间空一行：不然"按你遇到的问题挑一条"会被读成清单的第一条。
    # 与帮助正文同一套规矩——标题/引导语负责起头，内容另起一段。
    $out += [pscustomobject]@{ Role = 'text'; Text = '  按你遇到的问题挑一条：'
                               Segments = @(@{ Role = 'text'; Text = '  按你遇到的问题挑一条：' }) }
    $out += [pscustomobject]@{ Role = 'blank'; Text = ''; Segments = @() }
    # 编号列宽按最大编号算，让标题那一列永远对齐：
    # 直接写两个空格时，编号 1 到 6 宽度相同看不出问题，但主题一多（10 以上）
    # 两位数编号会把那一行整体右推一格，清单就从"整齐一列"变成"参差的"。
    $keys = @(foreach ($t in (Get-HelpTopics)) { [string]$t.Key })
    $keyW = 1
    foreach ($k in $keys) { if ($k.Length -gt $keyW) { $keyW = $k.Length } }
    foreach ($t in (Get-HelpTopics)) {
        $num = ([string]$t.Key).PadLeft($keyW)
        $segs = @(
            @{ Role = 'cmd';   Text = ('  ' + $num) },
            @{ Role = 'value'; Text = ('   ' + $t.Title) }
        )
        $joined = ''
        foreach ($sg in $segs) { $joined += $sg.Text }
        $out += [pscustomobject]@{ Role = 'item'; Text = $joined; Segments = $segs }
    }
    $out += [pscustomobject]@{ Role = 'blank'; Text = ''; Segments = @() }
    $out += [pscustomobject]@{ Role = 'dim'; Text = ('  本机版本 v' + $ver)
                               Segments = @(@{ Role = 'dim'; Text = ('  本机版本 v' + $ver) }) }
    $out += [pscustomobject]@{ Role = 'blank'; Text = ''; Segments = @() }
    $out += [pscustomobject]@{ Role = 'dim'; Text = '  输编号查看    直接回车 = 回主菜单'
                               Segments = @(@{ Role = 'dim'; Text = '  输编号查看    直接回车 = 回主菜单' }) }
    return $out
}

# 帮助目录屏（带配色）。
function Show-HelpIndexColored {
    foreach ($r in (Get-HelpIndexRenderedLines)) {
        if ($r.Role -eq 'blank') { Write-Host ''; continue }
        foreach ($s in $r.Segments) { Write-Styled $s.Role $s.Text -NoNewline }
        Write-Host ''
    }
}

# 帮助目录的纯文本（非交互与自检用）。与彩屏同一份内容，只差上不上色。
function Format-HelpIndex {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($r in (Get-HelpIndexRenderedLines)) { [void]$out.Add($r.Text) }
    return ($out -join "`n")
}

# 主题页底部那一行：把全部编号和短名并排列出来，当前这条用方括号标。
# 为什么需要它：用户在主题里只看到「输编号看别的」，却不知道别的编号是几号——
# 那句话等于白说。列出编号既回答了"编号是什么"，也顺手回答了"还有哪几条"。
function Format-HelpNavLine([string]$CurrentKey) {
    $parts = @()
    foreach ($t in (Get-HelpTopics)) {
        $label = if ($t.Key -eq $CurrentKey) { '[' + $t.Key + ']' + $t.Short } else { $t.Key + ' ' + $t.Short }
        $parts += $label
    }
    return ('  ' + ($parts -join '  '))
}

# 把一组编号写成人话。连续就写「1-6」，中间有断层就逐个列出来。
# 为什么不能只取首尾：从表里删掉一项之后，首尾相减仍然给出「1-6」，
# 而那段时间里 4 已经不存在了——用户照着敲 4，得到「没有这个编号」。
# 提示的用途是告诉他能敲什么，说错比不说更糟。
function Format-KeyList([string[]]$Keys) {
    if ($Keys.Count -eq 0) { return '' }
    if ($Keys.Count -eq 1) { return $Keys[0] }
    $ints = @($Keys | ForEach-Object { [int]$_ } | Sort-Object)
    $contiguous = $true
    for ($i = 1; $i -lt $ints.Count; $i++) { if ($ints[$i] -ne $ints[$i - 1] + 1) { $contiguous = $false; break } }
    if ($contiguous) { return ($ints[0].ToString() + '-' + $ints[$ints.Count - 1].ToString()) }
    return (($ints | ForEach-Object { $_.ToString() }) -join ' ')
}

# 菜单可用的编号，从表里算：加一项就自动变成 "1-6 和 0"，不会留下写死的旧范围。
function Get-MenuKeyRange {
    $keys = @($MenuItems | Where-Object { $_.Switch } | ForEach-Object { $_.Key })
    $quit = @($MenuItems | Where-Object { -not $_.Switch } | ForEach-Object { $_.Key })
    if ($keys.Count -eq 0) { return '没有可用的编号' }
    $text = Format-KeyList $keys
    if ($quit.Count -gt 0) { $text += ' 和 ' + ((@($quit | ForEach-Object { [int]$_ } | Sort-Object) | ForEach-Object { $_.ToString() }) -join ' ') }
    return $text
}

# 可用的编号范围，从表里算：加一条主题就自动变成 "有 1-8"，不会留下写死的旧范围。
function Format-HelpKeyRange {
    $keys = @(Get-HelpTopics | ForEach-Object { $_.Key })
    if ($keys.Count -eq 0) { return '没有可用的编号' }
    if ($keys.Count -eq 1) { return '只有 ' + $keys[0] }
    return ('有 ' + (Format-KeyList $keys))
}

# 单个主题的纯文本（给非交互调用与自检用）：与彩屏读同一份渲染结果。
function Format-HelpTopic([string]$Key) {
    $t = @(Get-HelpTopics | Where-Object { $_.Key -eq $Key })
    if ($t.Count -eq 0) { return $null }
    $t = $t[0]
    $out = New-Object System.Collections.Generic.List[string]
    [void]$out.Add(('================ 帮助 {0} · {1} ================' -f $t.Key, $t.Title))
    [void]$out.Add('')
    foreach ($r in (Get-HelpRenderedLines $t.Lines)) { [void]$out.Add($r.Text) }
    [void]$out.Add('')
    [void]$out.Add((Format-HelpNavLine $t.Key))
    [void]$out.Add('  输编号看别的    直接回车 = 回目录')
    return ($out -join "`n")
}

# 带配色地把一个主题打到屏幕上。
# 与 Format-HelpTopic 的区别只有"上不上色"：两者读同一份渲染结果（Get-HelpRenderedLines），
# 所以屏幕上有什么、非交互输出就是什么，不存在两份内容各自漂移。
# 一行分几段就上几个色：整行同色时"哪部分是命令"又得靠眼睛找，等于白上色。
function Show-HelpTopicColored([string]$Key) {
    $t = @(Get-HelpTopics | Where-Object { $_.Key -eq $Key })
    if ($t.Count -eq 0) { return $false }
    $t = $t[0]
    Write-Styled 'title' ('================ 帮助 {0} · {1} ================' -f $t.Key, $t.Title)
    Write-Host ''
    foreach ($r in (Get-HelpRenderedLines $t.Lines)) {
        if ($r.Role -eq 'blank') { Write-Host ''; continue }
        foreach ($s in $r.Segments) { Write-Styled $s.Role $s.Text -NoNewline }
        Write-Host ''
    }
    Write-Host ''
    Write-Styled 'dim' (Format-HelpNavLine $t.Key)
    Write-Styled 'dim' '  输编号看别的    直接回车 = 回目录'
    return $true
}

# 全文：把所有主题按顺序拼起来，一个字不少。
# 非交互调用（-Help 被脚本/管道调用）走这条：调用方要的是一份完整文档，
# 分页导航对没有终端的场景没有意义。
function Format-HelpAll {
    $out = New-Object System.Collections.Generic.List[string]
    [void]$out.Add((Format-HelpIndex))
    foreach ($t in (Get-HelpTopics)) {
        [void]$out.Add('')
        [void]$out.Add((Format-HelpTopic $t.Key))
    }
    return ($out -join "`n")
}

# 帮助入口。
# -All：不导航，直接给全文（非交互、或明确要全文时用）。
# 交互只有两种操作，和菜单完全一样：
#   输数字 = 去看那一条；直接回车 = 回上一级。
# 不用 n / p / m / a 这些字母：用户记不住哪个键管哪件事，
# 而"输编号"和"按回车"不需要学。条目不多，一屏列得下，也就没有翻页的必要。
function Show-Help([switch]$All) {
    if ($All -or -not (Test-CanPrompt)) {
        Write-Host (Format-HelpAll)
        return
    }
    # $cur 为空 = 当前在目录页；非空 = 正在看那一条。
    # 用一种状态表达两页：换主题时才不会跳回目录，也不用嵌套循环把逻辑写两遍。
    $cur = ''
    while ($true) {
        if (-not $cur) {
            Clear-Screen
            Show-HelpIndexColored
        }
        $sel = ''
        try { $sel = "$(Read-Host '输编号，或直接回车')".Trim() } catch { return }
        if (-not $sel) {
            # 回车：在主题里回目录，在目录里回主菜单。
            if ($cur) { $cur = ''; continue }
            return
        }
        # q 和 0 与「直接回车」同义：菜单里 q/0 都是退出，刚在菜单学会按 q 的人，
        # 进到帮助再按就被判成"没有这一条"，会以为帮助坏了。不写进屏幕，只是别拒绝他。
        if ($sel -eq 'q' -or $sel -eq 'Q' -or $sel -eq '0') {
            if ($cur) { $cur = ''; continue }
            return
        }
        # 先查表、有效才清屏：输错时把当前这屏留在屏幕上，用户还能照着挑。
        # 与菜单屏一致（输错不重画），不该一屏一个做法。
        if (-not (Test-HelpKey $sel)) {
            Write-Styled 'warn' ("没有这一条：{0}（{1}）" -f $sel, (Format-HelpKeyRange))
            continue
        }
        Clear-Screen
        [void](Show-HelpTopicColored $sel)
        $cur = $sel
    }
}

# 这个编号有没有对应的帮助主题。输错时用它来决定"要不要清屏"：
# 无效就保留当前屏（用户还要照着挑），有效才换屏。
function Test-HelpKey([string]$Key) {
    return [bool]@(Get-HelpTopics | Where-Object { $_.Key -eq $Key }).Count
}

function Show-Menu {
    # 非交互 stdin（管道/重定向）直接退出不进循环：菜单是给人点的，自动化请用开关。
    # 否则管道到 EOF 时 Read-Host 读空会被当成回车，一遍遍重复默认动作停不下来。
    try {
        if (-not (Test-CanPrompt)) {
            # 非交互时先把菜单正文打出来，再提示怎么用开关。
            # 与 Mac 侧对齐（那边 stdout 不是终端就退回纯文本菜单）：
            # 同样的调用在两个平台上不该一个给菜单、一个只给一句警告。
            # 这也让 Format-MenuText 不再是"只有测试在用"的死函数。
            Write-Host (Format-MenuText)
            Write-Host ''
            Write-Styled 'warn' "以上是菜单。管道里没法交互，请直接用 -Install/-Status/-Stop/-Uninstall/-Update/-Help 开关（全部开关见 -Help）。"
            return
        }
    } catch {}
    # 两轮两种画法：重画整张菜单（首次进入、子命令结束后），或者什么都不画
    # （输错编号那一轮）。所以它是三态的字符串而不是布尔量：布尔量只能表达"清不清屏"，
    # 输错时仍会重画整张菜单，连错几次屏幕就滚得找不到位置。
    $mode = "menu"
    while ($true) {
        if ($mode -eq "menu") { Clear-Screen; Show-MenuColored }
        try {
            $choice = Read-Host "输入编号"
        } catch {
            Write-Styled 'warn' "菜单需要双击 打开菜单.cmd 使用，管道调用请直接用 -Install/-Status/-Stop/-Uninstall/-Update/-Help 开关（全部开关见 -Help）。"
            return
        }
        # 先 Trim 再判空：纯空格应当与直接回车同义（Mac 侧 tr -d 之后再判空，两端同语义）。
        $choice = "$choice".Trim()
        if (-not $choice) { $choice = "2" }
        # q 与 0 同义：很多人下意识打 q 想退出，报"没有这个编号"只会让人以为程序坏了。
        if ($choice -eq 'q' -or $choice -eq 'Q') { $choice = "0" }
        $item = @($MenuItems | Where-Object { $_.Key -eq $choice })
        if (-not $item -or ($item.Count -eq 0)) {
            # 输错只补一行，菜单本身留在原位：重画一遍会让屏幕不停往下滚，
            # 连错几次就再也找不到自己在哪了（ADHD 用户尤其受不了）。
            Write-Styled 'warn' ("没有这个编号：{0}（可用的有 {1}）" -f $choice, (Get-MenuKeyRange))
            $mode = "none"
            continue
        }
        if (-not $item[0].Switch) { return }
        # 「查看状态」留在本进程里跑：它是实时刷新的，要能回到菜单；
        # 起子进程就回不来了（子进程退出后屏幕就停在最后一帧）。
        # 与 Mac 侧对 help 的处理同一理由——那边也是"要回菜单的留在本进程"。
        if ($item[0].Switch -eq "Status") {
            Show-StatusLive
            # 不清屏：Exit-Screen 已经把光标放到内容下方，菜单会自然接在后面画。
            # 清一次屏等于用户按完 0 屏幕先白一下——那正是"不要闪"要避免的事，
            # 只是从刷新中挪到了退出瞬间。
            $mode = "menu"
            continue
        }
        # 其余子进程跑完整开关：与入口开关走的是同一条路（含锁、确认、复检）。
        # 本进程只等它结束，不解释它的退出码（退出码在 5.1 里读不到，判据只看复读）。
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath ("-" + $item[0].Switch)
        } catch {
            Write-Styled 'warn' ("启动失败：{0}" -f $_.Exception.Message)
        }
        # 子命令跑完先停一下：下一轮开头就要清屏，不等一下就把它刚打印的内容抹掉了。
        try { $null = Read-Host '按回车回菜单' } catch { return }
        $mode = "menu"
    }
}
