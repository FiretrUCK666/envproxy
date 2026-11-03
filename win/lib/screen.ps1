# ==============================================================================
#  screen.ps1 — 屏幕渲染层：把「一帧内容」画到屏幕上，只重画变化的行
#
#  为什么单独一层：它有**状态**（上一帧的宽度与内容）和**副作用**（写 Console、
#  读按键），与 base 的「契约常量 + 纯函数」是两类东西。混在一起会让
#  「base 能不能做 X」这个问题没有单一答案。
#
#  依赖方向：base <- screen <- pages / shortcut。单向，不反向。
#  它只被这两层用（已核实），所以拆出来不产生环。
# ==============================================================================

# ------------------------------------------------------------------------------
#  屏幕渲染层：把「一帧内容」画到屏幕上，只重画变化的行。
#
#  这一层是唯一实现：菜单、帮助、状态页、管理页全都走它，没有页面特例。
#  它不认识颜色、不认识业务——输入只有两个字符串数组（上一帧、这一帧）。
#  颜色在**调用方**把内容拼成字符串之前就已经决定了，这一层只管画。
#
#  为什么单独一层：现在每个页面各自 Clear-Host + 逐行 Write-Host，于是
#  ① 清屏那一瞬屏幕全空 = 闪；② 没有「只重画变化行」的能力 = 每帧整屏重写。
#  把这两件事收敛到一处，改一次就对所有页面生效。
# ------------------------------------------------------------------------------

# 能不能做「就地重画」。这是所有刷新逻辑的前置判据，只有这一个实现。
#
# 三种情况不能画：
#   输出被重定向（管道/文件）—— 控制字符会原样写进文件，污染输出；
#   没有真实控制台 —— SetCursorPosition 会抛异常；
#   窗口太矮 —— 内容放不下，重画必然滚屏，滚屏后绝对坐标全部错位。
#
# 判据要**一次问清**，不许各页面自己再判一遍：项目里 "IsOutputRedirected" 这个
# 判断已经有四处，散着判必然漂移。
function Test-CanDrawScreen([int]$NeedLines = 0, [int]$NeedWidth = 0) {
    try {
        if ([Console]::IsOutputRedirected) { return $false }
        if ([Console]::IsInputRedirected) { return $false }
        $w = 0
        try { $w = [Console]::WindowWidth } catch { $w = 0 }
        $h = 0
        try { $h = [Console]::WindowHeight } catch { $h = 0 }
        if ($w -lt $ScreenMinWidth) { return $false }
        if ($h -lt $ScreenMinHeight) { return $false }
        # 留 ScreenBottomMargin 行给「按 0 返回」那行提示 + 光标所在行
        if ($NeedLines -gt 0 -and ($NeedLines + $ScreenBottomMargin) -gt $h) { return $false }
        # 宽度也要按**这一帧的实际最宽行**判：固定 40 只是「能读」的底线，
        # 而帧里有 82 列的日志行。80 列窗口放着 82 列的行，终端会折行——
        # 折出来的物理行不在这一层的记账里，后面每一行的绝对定位就全错位了。
        if ($NeedWidth -gt 0 -and $NeedWidth -gt $w) { return $false }
        # 光标定位能力本身要能拿到：拿不到就说明没有真控制台
        $null = [Console]::CursorTop
        return $true
    } catch {
        return $false
    }
}

# 一帧要占多少屏：行数 + 最宽行的显示宽度。
# 判「画不画得下」必须用这两个真实值，不能拿固定的最小宽高去猜——
# 最小宽高只是"能读"的底线，而真实帧里可能有 80+ 列的行、23 行的最坏情况。
function Measure-ScreenFrame([string[]]$Lines = @()) {
    $n = @($Lines).Count
    $w = 0
    foreach ($ln in $Lines) {
        $s = [string]$ln
        $dw = 0
        try { $dw = Get-DisplayWidth $s } catch { $dw = $s.Length }
        if ($dw -gt $w) { $w = $dw }
    }
    return @{ Lines = $n; Width = $w }
}

# 把一帧内容画到屏幕起点，返回这一帧实际占了多少屏幕行。
#
# $Old 与 $New 都是字符串数组，一个元素 = 一个逻辑行。行数可以不同：
# 变少时多出来的行会被擦掉（写空格），变多时新行追加。
#
# 返回实际占用的行数，调用方拿它当下一次的 $Old 行数。
function Write-ScreenFrame {
    param(
        [string[]]$Old = @(),
        [string[]]$New = @()
    )
    if (-not (Test-CanDrawScreen)) { return 0 }
    $n = @($New).Count
    $o = @($Old).Count
    if ($n -eq 0 -and $o -eq 0) { return 0 }

    # 窗口尺寸一变，终端会把已有内容重新折行，屏幕上"第几行是什么"整个失效——
    # 而这一层的记账（$Old）是按逻辑行算的。此时如果继续只重画"变化的行"，
    # 没变化的行会永远停在错位状态（实测：窗口拉小再拉回，11 轮刷新都修不好）。
    # 所以尺寸一有变化就作废记账、整帧重画。这是唯一能一次覆盖
    # "缩小时/拉大时/中途变/恢复时"的判据，不用逐个场景处理。
    $w = 0; $h = 0
    try { $w = [Console]::WindowWidth; $h = [Console]::WindowHeight } catch { }
    if ($w -ne $script:ScreenLastWidth -or $h -ne $script:ScreenLastHeight) {
        $script:ScreenLastWidth = $w
        $script:ScreenLastHeight = $h
        $Old = @()
        $o = 0
    }

    # 行数上限由函数自己守，不靠调用方记得先判：这一帧比窗口还高时，
    # 绝对定位 ESC[<行>;1H 会指向不存在的行——多数终端把它夹到末行，
    # 但一旦滚屏，后面每个逻辑行的绝对定位都错位，屏幕会显示错乱内容。
    #
    # 余量必须与 Test-CanDrawScreen 用**同一个常量**，不许在这里另写一个数：
    # 这里原来写的是 $h - 1，比那份判断宽松一行。帧高恰好等于「窗口高 - 1」时
    # 校验放行，可画完最后一行光标贴在窗口底部，终端为了让它可见会向上滚一行：
    # 屏幕上第 1 行被顶走，而这里的记账（$Old）还按原位置算。下一帧继续用绝对
    # 定位，落点整体偏移，最后一行于是被重复画出来（实测：底部提示行出现两次）。
    if ($h -gt 0 -and $n -gt ($h - $ScreenBottomMargin)) { return 0 }

    # 先把整帧拼成一个字符串再一次写出。
    # 为什么不是逐行 Write-Host：实测 12 行逐行写要 9.28 毫秒，一次拼接写出
    # 只要 0.24 毫秒（快 39 倍），而且中间没有「画到一半」的可见状态。
    $sb = New-Object System.Text.StringBuilder
    $max = [Math]::Max($o, $n)
    for ($i = 0; $i -lt $max; $i++) {
        $text = if ($i -lt $n) { [string]$New[$i] } else { '' }
        $prev = if ($i -lt $o) { [string]$Old[$i] } else { '' }
        # 内容没变就跳过这一行（这是「不闪」的本质：无变化时一个字节都不发）
        if ($i -lt $n -and $text -ceq $prev) { continue }
        [void]$sb.Append([char]27 + '[' + ($i + 1) + ';1H')     # 定位到该行
        [void]$sb.Append($text)
        [void]$sb.Append([char]27 + '[K')                        # 清到行尾，擦掉上一帧的尾巴
    }
    # 行数变少时，把多出来的行擦空
    if ($o -gt $n) {
        for ($i = $n; $i -lt $o; $i++) {
            [void]$sb.Append([char]27 + '[' + ($i + 1) + ';1H')
            [void]$sb.Append([char]27 + '[K')
        }
    }
    if ($sb.Length -eq 0) { return $n }   # 完全没有变化：不发任何字节

    try {
        [Console]::Out.Write(([char]27 + '[?25l'))   # 藏光标，避免看到它跳
        [Console]::Out.Write($sb.ToString())
        [Console]::Out.Write(([char]27 + '[?25h'))   # 恢复光标
        [Console]::Out.Flush()
    } catch {}
    return $n
}

# 进入/退出「屏幕已接管」状态：进入前清一次屏（只这一次），退出后把光标放回底部。
# 只有这两个函数会清屏。刷新循环里一次都不许清——清屏就是闪的根源。
function Enter-Screen {
    if (-not (Test-CanDrawScreen)) { return $false }
    try {
        Clear-Screen
        [Console]::Out.Write(([char]27 + '[H'))   # 光标回左上角
        [Console]::Out.Flush()
    } catch { return $false }
    return $true
}

function Exit-Screen {
    try {
        # 光标从「内容区」移到最下面一行，之后正常输出不会盖住刚画的内容
        $h = 0
        try { $h = [Console]::WindowHeight } catch { $h = 0 }
        if ($h -gt 0) {
            [Console]::SetCursorPosition(0, [Math]::Min($h - 1, [Console]::BufferHeight - 1))
        }
        [Console]::Out.Write([char]27 + '[?25h')   # 确保光标可见（Ctrl+C 后也要恢复）
        [Console]::Out.Flush()
    } catch {}
}

# 等一小段时间，顺便看有没有按键。返回：'' = 没按；其余 = 按下的那个字符。
# 返回 'Quit' 表示用户按了 0 / Esc / q，调用方据此退出刷新循环。
#
# 为什么不用 Read-Host：PS 5.1 是单线程宿主，Read-Host 阻塞在 ReadConsole 上时
# 整个事件循环停摆——实测那 3 秒内定时器回调一次都不触发。要「边刷新边等输入」
# 只能自己用 KeyAvailable 轮询。
function Wait-ScreenKey([int]$Milliseconds = 150) {
    $elapsed = 0
    $fails = 0
    while ($elapsed -lt $Milliseconds) {
        $got = $null
        try {
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq 'Escape') { return 'Quit' }
                $c = [string]$k.KeyChar
                if ($c -eq '0' -or $c -eq 'q' -or $c -eq 'Q') { return 'Quit' }
                # 空字符 = 功能键（方向键、F1 之类，KeyChar 是 \0）。
                # 它不是一个"输入"，不该结束这一轮等待：直接返回会让连按方向键的人
                # 把刷新节奏打乱（每次按键都提前结束等待）。当作没按，继续等。
                if ($c) { $got = $c }
            }
        } catch {
            # 读键失败（stdin 被夺走、控制台句柄失效）不等于"没按键就立刻返回"。
            # 立刻返回会让调用方的 while 循环毫无间隔地空转——实测那样一秒能转
            # 几千次、把一个核吃满，而且永远退不出去（拿不到 Quit）。
            # 这里必须照常歇一个轮询周期；连续失败太多次说明输入通道真的没了，
            # 交回一个 Error 让调用方退出循环，而不是陪着它空转。
            $fails++
            if ($fails -ge $ScreenKeyFailLimit) { return 'Error' }
        }
        if ($got) { return $got }
        Start-Sleep -Milliseconds $ScreenPollMs
        $elapsed += $ScreenPollMs
    }
    return ''
}


# ==============================================================================
# 页面骨架：所有全屏页共用同一套结构
# ==============================================================================
#
# 为什么要有这一层：以前每个页面自己拼标题、自己决定用哪个颜色角色写"怎么返回"，
# 于是同一件事在五个页面上有五种写法（`0 = 返回主菜单` / `按回车返回` /
# `按 0 或 Esc 返回`…），角色也在 dim / key / cmd 之间乱跳。
# 用户读到的是"这里一套、那里一套"——不是文案问题，是**没有共同结构**。
#
# 现在只留三种行：标题、内容、导航。每个页面的差别只体现在"内容"里，
# 标题与导航的形状由这一层统一决定，改一次全站生效。

# 标题行：等号宽度跟随文字长度，不写死。
function Format-PageTitle([string]$Title) {
    return ('======== ' + $Title + ' ========')
}

# 区块分隔线：两个内容块之间画一条短横线，让"这一段"和"下一段"有视觉边界。
# 长度固定 40：太短看着像打字错误，太长在窄窗口里会折行。
function Format-PageRule {
    return ('  ' + ('-' * 40))
}

# 导航行：这一屏怎么退出。**全站只有这一个形状**。
#   $Hint   人话说明（可空）
#   $Keys   可选按键，例如 @('0','Esc')
# 返回 @{ Segments=... } 一行，角色由这一层定死。
# 导航行的每一项都必须是「按键 = 含义」的完整短语。
#
# 这条形状是硬要求，不是排版偏好：只渲染一个孤零零的 `0`，读者不知道它是
# 编号、页码还是快捷键——他得回头数上面的列表才敢按。而 `0 = 返回` 一眼就懂。
# 所以颜色只用来强调**按键那个字符**，含义必须紧跟在同一个短语里，不许拆行。
#
#   $Hint   这一屏能做什么（人话，可空）
#   $Pairs  按键与含义的配对，每项形如 @{ Key='0'; What='返回主菜单' }
#
# 输出一行：\'  说明文字    0 = 含义    N = 含义\'
# 其中按键染 cmd 色（绿，与菜单里"要敲的东西"同一条规则），其余 dim。
function Format-PageNav([string]$Hint = '', [array]$Pairs = @()) {
    $segs = New-Object System.Collections.ArrayList
    if ($Hint -or $Pairs.Count -eq 0) {
        $head = if ($Hint) { $Hint } else { '按回车返回' }
        [void]$segs.Add(@{ Role = 'dim'; Text = ('  ' + $head) })
    }
    foreach ($p in $Pairs) {
        if (-not $p) { continue }
        # 前导 4 空格 = 项与项之间的视觉间隔；含义与等号跟着按键走，不许分开。
        [void]$segs.Add(@{ Role = 'dim'; Text = '    ' })
        [void]$segs.Add(@{ Role = 'cmd'; Text = [string]$p.Key })
        [void]$segs.Add(@{ Role = 'dim'; Text = (' = ' + [string]$p.What) })
    }
    return @{ Segments = @($segs) }
}

# 便捷构造：把 "0=返回"、"N=下一页" 这种写法转成 Pair。
# 分隔符用 |，因为含义里可能出现等号与逗号，而 | 在文案里从不出现。
function New-NavPair([string]$Key, [string]$What) {
    return @{ Key = $Key; What = $What }
}

# 把导航行直接画到屏幕上。
function Write-PageNav([string]$Hint = '', [array]$Pairs = @()) {
    $nav = Format-PageNav -Hint $Hint -Pairs $Pairs
    foreach ($seg in $nav.Segments) { Write-Styled $seg.Role $seg.Text -NoNewline }
    Write-Host ''
}

# 把「标题 + 内容行 + 导航」拼成一份行清单。调用方只管中间那段内容。
#   -Title    标题文字（不带等号）
#   -Body     内容行数组（@{Role=...;Text=...} 或带 Segments 的行）
#   -NavHint  导航说明
#   -NavPairs 导航按键与含义的配对
function New-PageLines {
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [array]$Body = @(),
        [string]$NavHint = '',
        [array]$NavPairs = @()
    )
    $out = New-Object System.Collections.ArrayList
    [void]$out.Add(@{ Role = 'title'; Text = (Format-PageTitle $Title) })
    [void]$out.Add(@{ Role = 'blank'; Text = '' })
    foreach ($b in $Body) {
        if ($null -eq $b) { continue }
        [void]$out.Add($b)
    }
    [void]$out.Add(@{ Role = 'blank'; Text = '' })
    [void]$out.Add((Format-PageNav -Hint $NavHint -Pairs $NavPairs))
    return $out
}
