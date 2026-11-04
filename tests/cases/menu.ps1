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
$opsSrc = Get-AllLibSource
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

# 操作锁必须能降级：有些受限会话/安全策略不让建 Global\ 对象。
# 不降级的后果是 install/uninstall/stop/update 四个动作全部永久失败，
# 而提示写的是「另一个安装正在进行」——一句假话，用户怎么重试都不会好。
Assert-Eq 'lock: Global naming carries the user sid' 'True' `
    ([bool]([regex]::IsMatch((Get-MutexName 'EnvProxyInstallOp'), '^Global\\EnvProxyInstallOp-S-')))
Assert-Eq 'lock: the local fallback drops the Global prefix' 'True' `
    ([bool]([regex]::IsMatch((Get-MutexName 'EnvProxyInstallOp' -Local), '^Local\\EnvProxyInstallOp-S-')))
# 建不出来与"被别人占着"必须能分开：两件事的提示完全不同。
$entrySrc = [System.IO.File]::ReadAllText((Join-Path $ScriptDir 'envproxy.ps1'), [System.Text.Encoding]::UTF8)
Assert-Eq 'lock: it tries the global namespace first, then the local one' 'True' `
    ([bool]([regex]::IsMatch($entrySrc, '(?s)foreach \(\$local in @\(\$false, \$true\)\)')))
Assert-Eq 'lock: a lock that cannot even be created is reported differently' 'True' `
    ([bool]([regex]::IsMatch($entrySrc, 'OpLockUnavailable')))
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
Assert-Eq 'a topic screen says how to go back' $true ((Format-HelpTopic '1') -match '回车')
# 交互只有两种操作：输数字、直接回车。屏幕上不能出现 n / p / m / a 这类字母导航——
# 用户记不住哪个键管哪件事，而这正是之前被抱怨的地方。
# 这条钉住的是「文案里不许再出现字母导航」，不是措辞本身。
$topicText = (Format-HelpTopic '1')
Assert-Eq 'a topic screen offers no letter keys' $false ($topicText -match 'n = |p = |m = |a 看')
$indexText = (Format-HelpIndex)
Assert-Eq 'the help index offers no letter keys' $false ($indexText -match 'n = |p = |m = |a 看')
Assert-Eq 'the help index says what Enter does' $true ($indexText -match '回车')
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
    # 高级功能那一屏同样是用户逐行读的，同样会折行——上面这轮只查帮助主题，
    # 管不到它。实测「5 网络与代理修复」那行曾到 82 列：名字和说明分家，
    # 后半截顶到最左边，整屏结构就散了。
    $advWide = ''
    foreach ($al in (Get-AdvancedPageLines)) {
        $atext = ''
        if ($al -is [string]) { $atext = $al }
        elseif ($al -is [hashtable] -and $al.ContainsKey('Segments')) {
            foreach ($s in $al.Segments) { $atext += [string]$s.Text }
        }
        if (-not $atext) { continue }
        if ((Get-DisplayWidth $atext) -le 80) { continue }
        $advWide = $atext; break
    }
    Assert-Eq 'advanced page has no line wider than 80 columns' '' $advWide

# 讲解页（WSL / Docker）结尾必须有分隔线，与救援页同一形态。
# 没有它的时候，「这一页只讲解」和「看完按回车」会读成正文的最后两行，
# 用户不知道讲完了没有。这条判断放在源码层：渲染函数是两页共用的一个。
$guideSrc = [System.IO.File]::ReadAllText((Join-Path $ScriptDir 'lib\shortcut.ps1'), [System.Text.Encoding]::UTF8)
$guideFn = [regex]::Match($guideSrc, '(?s)function Show-GuidePage.*?\n\}')
Assert-Eq 'guide page: the shared renderer was found' 'True' ([string]$guideFn.Success)
if ($guideFn.Success) {
    $g = $guideFn.Value
    Assert-Eq 'guide page: it draws a divider before the footer' 'True' `
        ([bool]([regex]::IsMatch($g, 'Format-PlainRule')))
    Assert-Eq 'guide page: the divider comes before the footer text' 'True' `
        ([bool]([regex]::IsMatch($g, '(?s)Format-PlainRule.*?Footer')))
    # 标题线也不许手敲：手敲的话这一屏和别的屏宽度对不上。
    Assert-Eq 'guide page: the title rule is computed, not typed' 'False' `
        ([bool]([regex]::IsMatch($g, '''=+ '' \+')))
}

# 显示宽度必须按码位算，不能按 UTF-16 码元算。
# emoji 是代理对：逐个 [char] 判会各算两格（实测 '😀' 得 4，而终端只占 2），
# 两端对同一字符算出不同宽度，菜单列就永远对不齐。
Assert-Eq 'width: emoji occupies two cells' 2 (Get-DisplayWidth ([char]::ConvertFromUtf32(0x1F600)))
Assert-Eq 'width: emoji after CJK still adds two' 6 (Get-DisplayWidth ('微信' + [char]::ConvertFromUtf32(0x1F600)))
Assert-Eq 'width: a combining mark adds nothing' 1 (Get-DisplayWidth ('e' + [char]0x301))
Assert-Eq 'width: plain ASCII counts one each' 5 (Get-DisplayWidth 'abcde')
# 剪切不许切出半个代理对：那样屏幕上就是乱码方块。
$wide = '微信' + [char]::ConvertFromUtf32(0x1F600) + '测试'
$brokenAt = ''
foreach ($w in @(2, 3, 4, 5, 6, 7, 8)) {
    foreach ($cut in @((Limit-DisplayTextWithTail $wide $w), (Limit-DisplayText $wide $w))) {
        for ($i = 0; $i -lt $cut.Length; $i++) {
            if ([char]::IsHighSurrogate($cut[$i]) -and ($i + 1 -ge $cut.Length -or -not [char]::IsLowSurrogate($cut[$i + 1]))) { $brokenAt = "w=$w" }
            if ([char]::IsLowSurrogate($cut[$i]) -and ($i -eq 0 -or -not [char]::IsHighSurrogate($cut[$i - 1]))) { $brokenAt = "w=$w" }
        }
    }
}
Assert-Eq 'truncation never splits a surrogate pair' '' $brokenAt
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

# ---------------------------------------------------------------------------
# 按程序定规矩：模式表的派生关系与身份唯一性
#
# 这一层最危险的失效是"屏幕上看不出来"：两个模式的图标行为一旦相同，
# 用户双击任何一个都是同一个结果，而画面、文件名、图标名全都正常。
# ---------------------------------------------------------------------------
Write-Host '[10c] per-program rules: identity is path + mode'

# 身份必须带模式这一维。少这一维时，同一程序的两个模式会算出同一个启动脚本
# 文件名，后建的覆盖先建的，两个图标行为相同——而桌面上看着是两个不同的图标。
$modeIdList = @($global:ShortcutModes | ForEach-Object { $_.Id })
Assert-Eq '至少两种模式' $true ($modeIdList.Count -ge 2)
Assert-Eq '模式 Id 唯一' $true (($modeIdList | Select-Object -Unique).Count -eq $modeIdList.Count)
Assert-Eq '默认模式在表里' $true ($modeIdList -contains $DefaultShortcutMode)

foreach ($m in @($global:ShortcutModes)) {
    # 四个派生点都必须非空：缺一个就会让某个界面露出空白或报错。
    Assert-Eq ("模式 {0} 有 Action" -f $m.Id) $false ([string]::IsNullOrWhiteSpace($m.Action))
    Assert-Eq ("模式 {0} 有 Suffix" -f $m.Id) $false ([string]::IsNullOrWhiteSpace($m.Suffix))
    Assert-Eq ("模式 {0} 有 Label" -f $m.Id) $false ([string]::IsNullOrWhiteSpace($m.Label))
    Assert-Eq ("模式 {0} 有 Note" -f $m.Id) $false ([string]::IsNullOrWhiteSpace($m.Note))
    Assert-Eq ("模式 {0} 有 Desc" -f $m.Id) $false ([string]::IsNullOrWhiteSpace($m.Desc))
    Assert-Eq ("模式 {0} 的 Role 合法" -f $m.Id) $true (@('text','dim','key','ok','warn') -contains $m.Role)
}

# Action 是行为类别，不是 Id 的副本：直连与代理必须落在不同的 Action 上，
# 否则启动脚本的 if 分支永远只走一支（两个图标的实际行为将完全相同）。
$actionList = @($global:ShortcutModes | ForEach-Object { $_.Action })
Assert-Eq 'Action 覆盖两种行为' $true (($actionList -contains 'proxy') -and ($actionList -contains 'direct'))

# 取不到的模式必须返回 $null，不许静默回落到默认模式——
# 那会把"模式名传错"变成"按默认做了"，而用户以为它生效了。
Assert-Eq '未知模式返回 $null' $null (Get-ShortcutMode 'no-such-mode')
Assert-Eq '空模式返回 $null' $null (Get-ShortcutMode '')

# 启动脚本正文必须体现两种行为：直连那支清变量，代理那支设变量。
$scSrc = [System.IO.File]::ReadAllText((Join-Path $ScriptDir 'lib\shortcut.ps1'), [System.Text.Encoding]::UTF8)
# 清变量只认进程级删除。另两种写法实测都删不掉（$env:X = $null 五个变量统统失效），
# 删不掉就等于直连没生效——而屏幕上一切正常。
# 生成出来的那一行长这样（$n 已被替换成真实变量名）：
#   [Environment]::SetEnvironmentVariable('HTTP_PROXY',$null,'Process');
Assert-Eq '直连用进程级删除' $true ($scSrc -match "SetEnvironmentVariable\(''' \+ \`$n \+ '''\,\`$null,''Process''\)")
# 不许用 $env:X = $null 那个写法：实测五个变量统统删不掉，子进程照样读到代理。
# 判据只数**真正的赋值**（左边是 $env:，右边是 $null），不数注释里提到它的地方。
$envAssign = 0
foreach ($sl in ($scSrc -split "`r?`n")) {
    $slTrim = $sl.Trim()
    if (-not $slTrim) { continue }
    if ($slTrim.StartsWith('#')) { continue }
    if ($slTrim -match '\$env:\w+\s*=\s*\$null') { $envAssign++ }
}
Assert-Eq '直连不用 $env:X = $null' 0 $envAssign
# 启动脚本里那行模式标记是扫描时的唯一身份依据（用户能改图标名，改不了脚本内容）。
Assert-Eq '启动脚本带模式标记' $true ($scSrc -match 'envproxy-mode:')

# 表自检必须真会失败：它守的是"表里写了处理器但函数不存在"这类静默失效。
# 只断言"现在能过"证明不了这一点——必须造一个坏表看它是否抛。
$assertFn = Get-Command Assert-AdvancedTable -ErrorAction SilentlyContinue
Assert-Eq 'Assert-AdvancedTable 存在' $true ($null -ne $assertFn)
$advList = @($global:AdvancedItems)
Assert-Eq '高级功能表非空' $true ($advList.Count -gt 0)
$keys = @($advList | ForEach-Object { [int]$_.Key })
Assert-Eq '编号从 1 连续' $true (($keys -join ',') -eq ((1..$keys.Count) -join ','))
Assert-Eq '编号不重复' $true ((($keys | Select-Object -Unique).Count) -eq $keys.Count)
# 每个处理器必须真存在——这正是门禁 16 的 G-A 在纯函数层的同一判据。
foreach ($it in $advList) {
    Assert-Eq ("处理器 {0} 存在" -f $it.Handler) $true ($null -ne (Get-Command $it.Handler -ErrorAction SilentlyContinue))
    Assert-Eq ("项 {0} 的 Kind 合法" -f $it.Key) $true (@('do','read') -contains $it.Kind)
}
# ---------------------------------------------------------------------------
# 空字符串不能当 Read-Host 的提示词。
#
# `Read-Host ''` 不等待输入，而是直接抛「name 不能为 NULL 或为空」。
# 外面套着 catch {} 时错误被吞掉，屏幕上的效果是那一页闪一下就退回上一层——
# 用户以为这个功能坏了（「管理已建的」在没有任何图标时正是这样）。
#
# 只靠人工看代码看不出来：那行读起来像"等一次回车"，完全合理。
# 而它只在"没有任何图标"这条路径上出现，平时测不到。
#
# 不传参数（`Read-Host`）是合法的、会真等回车，不在拦截范围。
$script:bareReadHostHits = @()
$script:libDir = Join-Path $ScriptDir 'lib'
foreach ($libFile in @(Get-ChildItem -LiteralPath $script:libDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue)) {
    $libLines = @(Get-Content -LiteralPath $libFile.FullName -ErrorAction SilentlyContinue)
    for ($li = 0; $li -lt $libLines.Count; $li++) {
        # 匹配 Read-Host 后面紧跟一个空字符串字面量（单引号或双引号成对）。
        if ($libLines[$li] -match "Read-Host\s+''" -or $libLines[$li] -match 'Read-Host\s+""') {
            $script:bareReadHostHits += ("{0}:{1}" -f $libFile.Name, ($li + 1))
        }
    }
}
Assert-Eq '没有 Read-Host 传空提示词（空提示会直接报错、不等待）' 0 $script:bareReadHostHits.Count
if ($script:bareReadHostHits.Count -gt 0) {
    Write-Host ("    命中: " + ($script:bareReadHostHits -join ', '))
}
