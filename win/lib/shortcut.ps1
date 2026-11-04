# ==============================================================================
#  shortcut.ps1 — 走代理的快捷方式：生成启动脚本、读写 .lnk、扫描记录、三屏界面
#
#  为什么单独成一个库：这一块与"安装/卸载/状态编排"完全是两件事。
#  它自带 VBS 生成、.lnk 的 COM 读写、程序扫描和三屏交互；
#  留在 ops 里会让以后每一次动 ops 都得先绕过它，也让这一块的边界看不见。
#
#  依赖只有 base：常量、纯函数、配色输出（Write-Styled）、清屏（Clear-Screen）、
#  屏幕宽度（Get-ConsoleWidth / Get-DisplayWidth）都住在 base。
#  本库**不依赖 ops**；反向依赖是 ops -> shortcut——卸载流程要在删目录之前
#  扫出这些快捷方式、问用户留不留。依赖是单向的，所以本库在 CoreLibs 里排在
#  ops 之后只是书写顺序，不代表它需要 ops 先加载。
# ==============================================================================

# ------------------------------------------------------------------------------
# 高级功能：给程序建一个「走代理」的快捷方式
# ------------------------------------------------------------------------------
# 为什么需要它（全部来自实测，不是推测）：
#   一个进程的环境变量在**启动那一刻**从父进程继承，之后系统再怎么改都不影响它。
#   而从资源管理器启动的 GUI 程序，环境来自登录会话——那份环境可能在代理注入
#   之前就固定了。实测对照：
#     父进程有代理环境 -> language_server 开 11 条连接全走代理，界面 1 秒打开
#     父进程没有代理环境 -> 直连 Google 超时 30 秒，界面端口不响应，白屏
#   重启资源管理器解决不了：Windows 自动拉起的新实例继承的是同一个登录会话环境。
#
# 唯一可靠的办法是**在启动前把代理环境直接交给程序**，绕开资源管理器这条继承链。
# 本节做的就是这个：给程序配一个启动脚本，脚本先读代理、再带着环境启动程序。

# ------------------------------------------------------------------------------
# 模式表：一个程序可以被指定成哪几种「规矩」
# ------------------------------------------------------------------------------
#
# **这是模式的唯一权威处。** 图标名后缀、启动脚本名、启动器行为、管理页显示，
# 四处全部从这张表派生，任何一处都不许再手写模式的名字或行为。
#
# 为什么必须做成表而不是两段 if：
#   一个程序可以有不止一种模式，而「身份 = 程序路径 + 模式」。少了模式这一维，
#   「WeChat 走代理」和「WeChat 固定直连」会被算成同一件事——启动脚本同名、
#   互相覆盖，最后点哪个图标都只按最后建的那个跑，而屏幕上看不出任何异常。
#   以后要加第三种模式（比如「走另一个代理」「阻断」），只往这张表里加一行。
#
# 字段：
#   Id      稳定标识。进文件名、进记录、进命令行开关都用它，**永不随显示变**
#   Suffix  图标名的后缀。用户会在桌面/任务栏逐字看到，换成别的说法就对不上
#   Label   在管理页和确认框里给用户看的短名（不带括号）
#   Mode    交给启动器的作用方式：proxy = 注入代理变量；direct = 清空代理变量
#
# @explain 「走代理」「固定直连」都是图标的显示名（走代理 / 固定直连 两种图标），不是解释机制
$ShortcutModes = @(
    # Id      身份的一部分（启动脚本按它算文件名，两模式不能撞）
    # Action  行为类别。分派只看这一列：proxy = 启动前设上代理，direct = 启动前清掉代理
    # Suffix  图标名的后缀。加在程序名后面，所以带括号和全角空格
    # Label   管理页与确认页里的短名
    # Note    一句话说清这条规矩的后果。直接回显模式的意图，不让用户从名字去猜
    # Desc    快捷方式「备注」字段里的前缀
    # Role    管理页里这条记录用什么颜色。proxy 是常规色，direct 是弱化色（它不是默认选择）
    # @explain 「走代理」「固定直连」是产品的固定叫法（图标名的一部分），不是解释机制
    @{ Id = 'proxy';  Action = 'proxy'
       Suffix = '（翻墙）';   Label = '翻墙'
       # 曾经用过的后缀。用户桌面上那些老图标还带着它们，删不掉也改不了名——
       # 只认当前后缀的话，改一次措辞就把所有已建的图标变成「认不出来」，
       # 而那些图标其实完全能用。认旧名是为了让改名不伤到已经发出去的东西。
       AliasSuffixes = @('（走代理）')
       Note = '双击它启动的程序会翻墙，跟着翻墙软件走。'
       Desc = '通过 EnvProxy 翻墙启动：'; Role = 'text' }
    @{ Id = 'direct'; Action = 'direct'
       Suffix = '（直连）';   Label = '直连'
       AliasSuffixes = @('（固定直连）')
       Note = '双击它启动的程序一定不翻墙，哪怕别的程序都在翻墙。'
       Desc = '通过 EnvProxy 直连启动：'; Role = 'dim' }
)

# 默认模式：不给开关时按这个来，保持老行为不变。
$DefaultShortcutMode = 'proxy'

# 按 Id 取模式定义。取不到返回 $null，由调用方决定怎么报——
# 静默回落成默认模式会让「传错了模式名」变成「静默按默认做」，那是最坏的一种误导。
function Get-ShortcutMode([string]$Id) {
    if (-not $Id) { return $null }
    foreach ($m in $ShortcutModes) {
        if ($m.Id -eq $Id) { return $m }
    }
    return $null
}


# 全部模式的后缀清单，供扫描时剥离文件名用。
# 必须按长度降序：'（固定直连）' 比 '（走代理）' 长，先剥短的会让长后缀剥不干净。
function Get-ShortcutSuffixes {
    # 当前后缀与全部历史后缀一起返回。漏掉旧后缀会让老图标在扫描时剥不干净，
    # 名字里留着「（走代理）」而被当成程序名的一部分。
    $all = @()
    foreach ($m in $ShortcutModes) {
        $all += @($m.Suffix)
        $all += @($m.AliasSuffixes)
    }
    return @($all | Where-Object { $_ } | Sort-Object { $_.Length } -Descending)
}

# 从图标名里剥离模式后缀，返回程序名。
# 一个都剥不掉时原样返回——那说明这个图标不是本工具建的，调用方会据此跳过它。
function Get-ShortcutBaseName([string]$Name) {
    if (-not $Name) { return '' }
    foreach ($sfx in (Get-ShortcutSuffixes)) {
        if ($Name.EndsWith($sfx, [StringComparison]::Ordinal)) {
            return $Name.Substring(0, $Name.Length - $sfx.Length)
        }
    }
    return $Name
}

# 从图标名里认出是哪种模式。认不出返回 $null。
function Get-ShortcutModeFromName([string]$Name) {
    if (-not $Name) { return $null }
    foreach ($m in $ShortcutModes) {
        # 当前后缀和所有历史后缀都认。只认当前的话，改一次措辞就把用户桌面上
        # 已经建好的图标全变成「认不出来」——而那些图标完全能用。
        foreach ($sfx in @($m.Suffix) + @($m.AliasSuffixes)) {
            if (-not $sfx) { continue }
            if ($Name.EndsWith($sfx, [StringComparison]::Ordinal)) { return $m }
        }
    }
    return $null
}

# 启动脚本里那一行「它服务的程序是哪个」的标记名。写与读共用这一个常量：
# 两处各写一遍字面量的话，改一处会让所有已生成的图标静默读不出目标路径——
# 症状是管理页里"目标程序"一栏全空，而没有任何报错。
$ProxyLauncherMark = 'envproxy-target-hex:'

# 启动脚本里那一行「它用的是哪种模式」的标记名。写与读共用这一个常量。
# 老脚本没有这一行——读出来是空串，调用方按"未知"处理（不删、只提示）。
$ProxyLauncherModeMark = 'envproxy-mode:'

# ------------------------------------------------------------------------------
# 生成与扫描（无界面：不读输入、不画屏幕，可以脱离终端单独测）
# ------------------------------------------------------------------------------

# 启动脚本目录。放在 %LOCALAPPDATA%\EnvProxy 之下，而不是 ~/.envproxy：
#   ~/.envproxy 是给 bash 钩子用的（Windows 与 macOS 共用这个名字），
#   启动脚本由 wscript 按绝对路径直接调用，与 shell 无关，放那边没有道理。
function Get-ProxyLauncherDir {
    return (Join-Path (Get-InstallDir) 'launchers')
}

# 一个程序在扫描列表里要不要被排除。
# 判据是"这个名字像不像一个能用的程序"，不是"像不像用户装的东西"——
# 后者判不了（用户可能把程序装在任何地方）。每一条都来自实测扫出来的噪音：
#   卸载器 / 帮助文档 / 系统工具 / Python 自带开发工具 都不是日常要用的程序。
# 用整词匹配而不是子串：子串会让 "Notepad++" 被 'notepad' 误伤。
$ProxyScanExcludeWords = @(
    '卸载', 'uninstall', 'unins000', 'unins',
    'readme', '帮助', '说明', '更新日志', 'changelog', 'license', '手册', '文档', '教程', '指南',
    '此电脑', '回收站', '控制面板', '网络连接', 'cmd', 'regedit',
    'notepad', 'idle', 'module docs', 'python'
)

# 这个名字该不该从候选列表里排除。
function Test-ProxyScanExcluded([string]$Name) {
    if (-not $Name) { return $true }
    $n = $Name.ToLower().Trim()
    if (-not $n) { return $true }
    # 去掉常见的后缀再比：用户看到的可能是 "Antigravity 快捷方式"
    $n = $n -replace '\s*(快捷方式|shortcut)$', ''
    # 判据分两类，混在一起两头都判不准：
    #
    #   ① 中文词：用 Contains。中文没有词边界，"卸载工具""帮助文档"里那个词就是它
    #      的全部含义，出现即算噪音。用边界匹配一个都挡不住——实测
    #      '卸载工具' / '某某卸载' / '帮助文档' 全部漏过，而这些快捷方式指向的是
    #      真的 exe，用户（分不清"程序"和"卸载程序"）挑中它就会建一个
    #      "点一下就卸载某个软件"的图标。这不是体验问题，是数据风险。
    #
    #   ② 英文词：必须有边界，否则 'notepad' 会把 'Notepad++' 一起吞掉，
    #      而 Notepad++ 是用户真会用的编辑器。
    foreach ($w in $ProxyScanExcludeWords) {
        if ($w -match '[\u4e00-\u9fff]') {
            if ($n.Contains($w)) { return $true }
        } else {
            if ($n -eq $w) { return $true }
            if ($n -like ($w + ' *') -or $n -like ($w + '-*') -or $n -like ($w + '_*')) { return $true }
            if ($n -like ('* ' + $w) -or $n -like ('* ' + $w + ' *')) { return $true }
        }
    }
    return $false
}

# 一个程序路径该不该从候选列表里排除。
# 与名字判据分开：路径能挡掉"系统目录里的工具"，而名字挡不掉。
function Test-ProxyScanExcludedPath([string]$Path) {
    if (-not $Path) { return $true }
    $p = $Path.ToLower()
    # 系统目录里的东西不是用户装的程序（regedit / cmd / 各种 .cpl）。
    #
    # 判据要**认出任何 Windows 系统目录**，不能只看 $env:SystemRoot：那个变量只在
    # Windows 上存在，在 CI 的 Linux 上为空——于是同一个路径在本机被判「排除」、在 CI
    # 被判「保留」，同一条断言两地结论相反。判据写成「路径里有一段是 system32 或
    # syswow64」就与宿主平台无关了。
    if ($p -match '(^|\\)(system32|syswow64)\\') { return $true }
    # 少见的部署：Windows 目录不在默认盘符下，再按本机真实值兜一次
    $win = ([string]$env:SystemRoot).ToLower().TrimEnd('\')
    if ($win -and $p.StartsWith($win + '\')) { return $true }
    # 卸载器几乎都叫 unins*.exe / uninstall*.exe。
    # 取文件名要用「两种分隔符都切」，不能用 [System.IO.Path] 的 API：那个方法按
    # **宿主平台**的规则认分隔符——Windows 认反斜杠，Linux 只认正斜杠。同一个
    # 'C:\App\unins000.exe' 在 Linux 上会被当成
    # 整串没有扩展名的文件名，于是这条判断在 CI 上恒为假、断言两地结论相反。
    $file = ($p -split '[\\/]')[-1]
    $file = $file -replace '\.[^.]+$', ''
    if ($file -like 'unins*' -or $file -like 'uninstall*') { return $true }
    return $false
}

# 把一段脚本压成 base64（先 GZip）。启动脚本里用它把"要执行的命令"压短。
function Compress-ToBase64([string]$Text) {
    if (-not $Text) { return '' }
    $raw = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $ms = New-Object System.IO.MemoryStream
    try {
        $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
        try { $gz.Write($raw, 0, $raw.Length) } finally { $gz.Dispose() }
        return [Convert]::ToBase64String($ms.ToArray())
    } finally {
        $ms.Dispose()
    }
}

# 生成启动脚本的正文。
#
# 为什么是"脚本里再压缩一层 PowerShell 命令"而不是直接写 PowerShell 代码：
#   wscript 只能执行 VBScript，不能直接跑 PowerShell；而 VBScript 里拼接
#   长命令的引号转义极易出错（实测 8 种刁钻路径全部失败过一次）。
#   这里的做法是：VBS 只做一件最简单的事——把一段 base64 交给 powershell 解压执行。
#   base64 只有 A-Za-z0-9+/=，没有引号、没有中文，VBS 不需要任何转义。
#
# 运行时做三件事：读注册表拿代理 -> 放进自己的环境 -> 启动目标程序。
#
# 运行时**不校验**代理值，只原样取用注册表里的那个。两个原因：
#   ① 那个值是 EnvProxy 自己校验过才写进去的，运行时再验一遍没有新信息；
#   ② 校验要多写几十行，而这段脚本的每一行都要占 .vbs 的体积（虽然现在余量很足），
#      更实际的理由是——运行在裸 powershell 里，验错了也没有人能看到错误。
# 建快捷方式时会用 ConvertTo-ProxyUrl 看一眼当前值（结果放在 ProxyOk 里给界面用），
# 那是为了"建完之后告诉用户现在没有可用代理"，不是为了拦住建不成。
function New-ProxyLauncherBody([string]$TargetPath, [string]$WorkingDir, $Mode, [string]$ExtraArgs = "") {
    if (-not $TargetPath) { throw '目标路径为空' }
    if (-not $WorkingDir) { $WorkingDir = Split-Path -Parent $TargetPath }
    if (-not $Mode) { $Mode = Get-ShortcutMode $DefaultShortcutMode }
    if (-not $Mode) { throw '模式表为空，无法生成启动器' }
    # PowerShell 单引号串里的单引号要写成两个
    $t = $TargetPath.Replace("'", "''")
    $w = $WorkingDir.Replace("'", "''")
    # 额外参数：原样追加到目标程序后面。
    # 它写在启动器里而不是 .lnk 的 Arguments 里——.lnk 的参数位只放得下启动脚本本身，
    # 再塞目标程序的参数会让 `wscript.exe "脚本.vbs" --proxy-server=...` 变成
    # 传给 wscript 的参数，启动器根本收不到。
    # 拼进命令时整段放在一对单引号里，内部的单引号照 PowerShell 规矩写两遍。
    $argPart = ''
    if ($ExtraArgs) {
        # 占位符 __ENVPROXY_CURRENT__ 要换成**生成出来的脚本里**的变量引用 $p，
        # 而不是在这里求值。这个区别是致命的：
        #   写 "('--proxy-server=' + $p)"（$ 不转义）—— $p 在当前上下文求值，
        #       此刻它还不存在，拼出来是 ('--proxy-server=' + )，连语法都不完整；
        #   写 "('--proxy-server=' + `$p)"（反引号转义）—— 字面保留 $p，
        #       脚本运行时那一行才取值，那正是"点击那一刻才知道地址"要的效果。
        # 用**数组**形式传参，不用单字符串：单字符串要靠 Start-Process 自己按空格重切，
        # 边界是猜出来的；数组的每一项就是一个参数，边界写在代码里。
        # 现在这些参数都不含空格，但将来有人加一个含空格的值就会静默裂开——
        # 而裂开的症状是"程序起来了但参数没生效"，不报错。
        if ($ExtraArgs -like '*__ENVPROXY_CURRENT__*') {
            $argPart = " -ArgumentList @(('--proxy-server=' + `$p), '--proxy-bypass-list=localhost,127.0.0.1,[::1]')"
        } else {
            $argList = @($ExtraArgs -split ' ' | Where-Object { $_ })
            $quoted = @($argList | ForEach-Object { "'" + $_.Replace("'", "''") + "'" })
            $argPart = " -ArgumentList @(" + ($quoted -join ', ') + ")"
        }
    }

    # ---- 固定直连：先把代理变量清干净，再原样启动 ----
    #
    # 为什么"清空"就够了：环境变量在进程启动那一刻从父进程继承，而这一层是**唯一**
    # 能改变某个进程拿到的环境的时机（见本文件开头那段实测）。清掉之后这个程序
    # 及其所有子进程都看不到代理，等于直连。
    #
    # 这一支**不读代理、不碰中继、不弹窗**——它跟代理是否存在完全无关，
    # 翻墙软件开没开都不影响它工作。
    # 分派只看 Action 这一列：加一种模式不必改这里，只要它有各自的 Action 实现。
    if ($Mode.Action -eq 'direct') {
        $clear = ''
        # 用 [Environment]::SetEnvironmentVariable(名, $null, 'Process')。三种写法实测对比：
        #
        #   `$env:NAME = $null`   —— **五个变量统统删不掉**（进程环境块里值还在，
        #                            子进程照样读到代理）。它看起来最像"清空"，
        #                            所以很容易被当成对的写下去。
        #   `Remove-Item Env:NAME`—— **不稳定**：五个里 NO_PROXY 删不掉。
        #   本方法                —— 五个全部删干净，子进程确认看不到。
        #
        # 为什么这条差别致命：直连模式的全部机制就是"让子进程看不到代理变量"。
        # 删不掉 = 直连没生效，而屏幕上一切正常，用户只会觉得"这个图标没用"，
        # 且没有任何线索指向真正的原因。
        #
        # 第三个参数 'Process' 必须写：省略时目标依 .NET 版本而定，
        # 写成 'User' 会去改注册表——那是删用户的全局设置，性质完全不同。
        foreach ($n in @($ProxyVarNames)) {
            $clear += ('[Environment]::SetEnvironmentVariable(''' + $n + ''',$null,''Process'');')
        }
        $psd = $clear + "Start-Process -FilePath '$t'" + $argPart + " -WorkingDirectory '$w'"
        return (Compress-ToBase64 $psd)
    }

    # ---- 走代理：读当前代理值，注入后启动 ----
    # 弹窗里要点名是哪个程序——用户往往点了一堆图标之后才发现不对，不点名就不知道关哪个。
    # 只取文件名、去掉扩展名，并且截断：可执行文件名偶尔很长，整段塞进弹窗会把排版撑坏。
    # 单引号必须转义（它要进单引号串），这一点与路径同样处理。
    $appLabel = [System.IO.Path]::GetFileNameWithoutExtension($TargetPath)
    if (-not $appLabel) { $appLabel = $TargetPath }
    if ($appLabel.Length -gt 24) { $appLabel = $appLabel.Substring(0, 24) + '…' }
    $appLabel = $appLabel.Replace("'", "''")
    # 这一段里的每一个"名字"都从 base 层的权威常量来，不手抄：
    #   变量清单      $ProxyAddrVarNames（"哪些变量是地址类"只定义一处）
    #   主代理变量    $PrimaryProxyVarName（"读哪一个当代理源"只定义一处）
    #   注册表落点    Get-RegSubKeyPath $UserEnvSubKey
    #   开关值        $NodeUseEnvProxyValue
    #   例外清单默认  $DefaultNoProxy
    # 手抄的后果不是"多写几个字"：同一个程序从快捷方式启动和从终端启动会拿到不同的值，
    # 而症状是"有时候连不上"，只在某一种启动方式下出现，极难查。
    $addrVars = $ProxyAddrVarNames
    $setv = ''
    foreach ($n in $addrVars) { $setv += ('$env:' + $n + '=$p;') }
    $noProxyDefault = $DefaultNoProxy.Replace("'", "''")
    $envKeyPath = Get-RegSubKeyPath $UserEnvSubKey
    # 固定入口（中继）的端口记录文件。启动器**每次点击都重新读**，所以中继换了端口
    # 它照样能跟上，用户不需要重建图标——这是"永不失效的地址"真正的落地方式。
    $relayPortFile = (Get-RelayPortFile).Replace("'", "''")
    # ---------------------------------------------------------------------------
    # 自适应的两段式取代理值（顺序不能反）
    # ---------------------------------------------------------------------------
    # 1) 先试固定入口：读端口记录 -> 200ms 内探一次 -> 通了就用它。
    #    用固定入口的好处是：翻墙软件换端口时，程序里的地址**永远不变**。
    # 2) 不通就退回读注册表当前值（就是原来的行为）。
    #    这条退路是必须的：中继可能没起来（端口被占、类型编译失败）、或者监控被停了。
    #    有它在，最坏情况回到"没有固定入口"的旧行为，而不是"图标全废"。
    # 两个都拿不到才弹窗——那个弹窗是用户唯一的线索，不能省。
    #
    # 探测必须带超时：不加超时连一个没人监听的口要等约 2 秒（TCP 重试），
    # 用户会感觉图标点了没反应。200ms 足够区分"有人听"与"没人听"。
    $relayProbe = "`$rp=0;" +
        "try{`$f='$relayPortFile';" +
        "if(tp `$f){`$rp=[int]((gc `$f -ea 0 -raw).Trim())}}catch{};" +
        "`$useRelay=`$false;" +
        "if(`$rp -gt 0){try{`$c=New-Object Net.Sockets.TcpClient;" +
        "`$a=`$c.BeginConnect('127.0.0.1',`$rp,`$null,`$null);" +
        "if(`$a.AsyncWaitHandle.WaitOne(200)){`$c.EndConnect(`$a);`$useRelay=`$true};`$c.Close()}catch{}};"
    $ps = $relayProbe +
          "`$p='';" +
          "if(`$useRelay){`$p='http://127.0.0.1:'+`$rp}" +
          "else{`$p=(gp 'HKCU:\$envKeyPath' -ea 0)." + $PrimaryProxyVarName + "};" +
          "if(`$p){" + $setv +
          "`$n=(gp 'HKCU:\$envKeyPath' -ea 0).NO_PROXY;" +
          "if(-not `$n){`$n='" + $noProxyDefault + "'};" +
          "`$env:NO_PROXY=`$n;" + 'NODE_USE_ENV_PROXY_PLACEHOLDER' + "}" +
          "else{try{Add-Type -AssemblyName PresentationFramework;" +
          "[Windows.MessageBox]::Show('没找到可用的代理，《" + $appLabel + "》已经按直连打开了。`n`n" +
          "翻墙软件开着的话：打开菜单选 1（安装 / 修复），再点这个图标。`n" +
          "翻墙软件没开的话：先开它，再点这个图标。','EnvProxy')|Out-Null}catch{}};" +
          "Start-Process -FilePath '$t'" + $argPart + " -WorkingDirectory '$w'"
    # ---------------------------------------------------------------------------
    # 这段弹窗的三条约束，每条都对应一次真实的误用
    # ---------------------------------------------------------------------------
    # 1) **必须说清程序已经开了**。`Start-Process` 在弹窗之后照常执行，
    #    所以用户看到弹窗时程序已经启动了。"请再点一次"会让他开第二个实例。
    # 2) **必须点名是哪个程序**。用户常常是从任务栏/桌面点了一堆图标之后才发现不对，
    #    不点名他就不知道该关哪个。程序名在这里，不额外花钱。
    # 3) **必须给出"监控被停"这条出路**。停止监控会执行 Apply-State off、把代理变量删光，
    #    那之后无论开多少次翻墙软件、点多少次图标，注册表里永远是空的——
    #    只叫他"开代理软件"，他会陷进一个怎么试都出不来的循环，而且完全无从察觉。
    #    选 1（安装 / 修复）会把监控重新拉起来，那条路才通。
    # ---------------------------------------------------------------------------
    # 开关变量名与它的取值都从权威处来：名字在变量表里，取值由 base 层给出。
    $switchName = $ProxyVarNames | Where-Object { $_ -eq 'NODE_USE_ENV_PROXY' } | Select-Object -First 1
    $ps = $ps.Replace('NODE_USE_ENV_PROXY_PLACEHOLDER', ('$env:' + $switchName + "='" + $NodeUseEnvProxyValue + "'"))
    # tp 是 "Test-Path" 的简写：启动脚本体积有限（要塞进 base64 再塞进 .vbs），
    # 全名与简写各出现一次就是几十字节。这里只为了省体积，行为完全等价。
    $ps = $ps.Replace('tp $f', 'Test-Path -LiteralPath $f')
    return (Compress-ToBase64 $ps)
}

# 生成启动脚本（.vbs）的内容。
# 纯 ASCII：VBS 文件带 BOM 或中文都可能被某些旧版 WSH 读错，而 base64 本来就没有中文。
function New-ProxyLauncherVbs([string]$EncodedBody, [string]$TargetPath = "", $Mode = $null) {
    if (-not $EncodedBody) { throw '启动命令为空' }
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command ' +
           '"$b=''' + $EncodedBody + ''';' +
           '$m=[IO.MemoryStream]::new([Convert]::FromBase64String($b));' +
           '$g=[IO.Compression.GZipStream]::new($m,[IO.Compression.CompressionMode]::Decompress);' +
           '$r=[IO.StreamReader]::new($g);$s=$r.ReadToEnd();$r.Close();iex $s"'
    # VBS 字符串里的双引号要写两次
    $escaped = $cmd.Replace('"', '""')
    $body = 'CreateObject("WScript.Shell").Run "' + $escaped + '", 0, False' + "`r`n"
    # 在脚本里留一行注释，记下它服务的是哪个程序。
    #
    # 为什么必须留：脚本文件名是「程序名_哈希」，哈希那一段对人没有意义。
    # 图标被删掉或挪走之后，launchers 目录里只剩这个脚本，而管理页当时只能显示
    # 一个像 scene_test_aabbccdd 的名字——用户看不出这是哪个程序的、该不该删。
    # 真正的程序路径只存在压缩过的命令里，外面读不出来，所以要另外留一份可读记录。
    #
    # 用注释而不是数据行：VBS 注释以单引号开头，语法上完全无副作用；
    # 文件必须保持纯 ASCII，所以路径按 UTF-8 转成十六进制写进去，读的时候再还原。
    # 直接写中文路径会破坏"VBS 文件必须纯 ASCII"这条（某些旧版 WSH 读它会出错）。
    if ($TargetPath) {
        try {
            $hex = -join ([System.Text.Encoding]::UTF8.GetBytes($TargetPath) | ForEach-Object { $_.ToString('x2') })
            $body += "' " + $ProxyLauncherMark + " " + $hex + "`r`n"
        } catch {}
    }
    # 模式标记。**孤儿脚本清理要靠它分辨「同一个程序的两个模式」**：
    # 没有这一行时，两个模式的脚本长得完全一样，清理逻辑无法判断哪个还有图标在用。
    # 值只用 ASCII 的 Id（不加中文），保持整个 .vbs 纯 ASCII。
    if ($Mode -and $Mode.Id) {
        $body += "' " + $ProxyLauncherModeMark + " " + $Mode.Id + "`r`n"
    }
    return $body
}

# 从一个启动脚本里读出它用的模式 Id。读不出来返回空串（老脚本没有这一行）。
function Get-ProxyLauncherMode([string]$LauncherPath) {
    if (-not $LauncherPath) { return '' }
    try {
        if (-not (Test-Path -LiteralPath $LauncherPath)) { return '' }
        foreach ($ln in @(Get-Content -LiteralPath $LauncherPath -ErrorAction SilentlyContinue)) {
            if ($ln -match ('^''\s*' + [regex]::Escape($ProxyLauncherModeMark) + '\s+(\S+)')) {
                return $Matches[1]
            }
        }
        return ''
    } catch { return '' }
}

# 从一个启动脚本里读出它服务的程序路径。读不出来返回空串。
function Get-ProxyLauncherTarget([string]$LauncherPath) {
    if (-not $LauncherPath) { return '' }
    try {
        if (-not (Test-Path -LiteralPath $LauncherPath)) { return '' }
        $text = [System.IO.File]::ReadAllText($LauncherPath, [System.Text.Encoding]::ASCII)
        $m = [regex]::Match($text, [regex]::Escape($ProxyLauncherMark) + '\s*([0-9a-fA-F]+)')
        if (-not $m.Success) { return '' }
        $hex = $m.Groups[1].Value
        if ($hex.Length % 2 -ne 0) { return '' }
        $bytes = New-Object 'byte[]' ($hex.Length / 2)
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16)
        }
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch { return '' }
}

# 为一个程序生成启动脚本，返回脚本路径。
#
# 文件名 = 程序名 + 哈希(程序路径 + 模式)。两个维度都必须进哈希：
#   只哈希路径 —— 「同一个程序走代理」和「同一个程序固定直连」会得到同一个文件名，
#                后建的覆盖先建的，两个图标行为相同，而屏幕上看不出异常。
#   只哈希模式 —— 两个目录下同名的程序（都叫 app.exe）会互相覆盖。
function New-ProxyLauncherScript([string]$TargetPath, [string]$WorkingDir, [string]$ModeId = $DefaultShortcutMode, [string]$ExtraArgs = "") {
    $mode = Get-ShortcutMode $ModeId
    if (-not $mode) { throw ("未知的模式：{0}" -f $ModeId) }
    $dir = Get-ProxyLauncherDir
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }
    $base = Get-PathBaseName $TargetPath
    foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) { $base = $base.Replace([string]$ch, '') }
    if (-not $base) { $base = 'app' }
    # 哈希的输入是「路径 + 模式」。分隔符用 \n：
    # 路径里不会出现换行，所以「a\nproxy」与「a\nproxy」之外不可能拼出同一串。
    $key = $TargetPath.ToLower() + "`n" + $mode.Id
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($key))
    } finally { $sha.Dispose() }
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt 4; $i++) { [void]$sb.Append($hash[$i].ToString('x2')) }
    $vbsPath = Join-Path $dir ($base + '_' + $sb.ToString() + '.vbs')

    $enc = New-ProxyLauncherBody $TargetPath $WorkingDir $mode $ExtraArgs
    $vbs = New-ProxyLauncherVbs $enc $TargetPath $mode
    # 先写临时文件再整体替换：中途失败不会留下半个脚本。
    # 临时文件名带 PID：两个进程同时给同一个程序建快捷方式时不会撞同一个临时文件。
    #
    # try/finally 保证临时文件一定被清掉。没有它的话，WriteAllText、Delete、Move
    # 任一步抛异常都会留下 .vbs.tmp 残骸——而清理逻辑只扫 *.vbs，
    # 于是那个残骸会永远躺在 launchers 目录里，选了"保留快捷方式"的卸载也带不走。
    $tmp = "$vbsPath.$PID.tmp"
    try {
        [System.IO.File]::WriteAllText($tmp, $vbs, (New-Object System.Text.ASCIIEncoding))
        if ([System.IO.File]::Exists($vbsPath)) { [System.IO.File]::Delete($vbsPath) }
        [System.IO.File]::Move($tmp, $vbsPath)
    } finally {
        if ([System.IO.File]::Exists($tmp)) {
            try { [System.IO.File]::Delete($tmp) } catch {}
        }
    }
    return $vbsPath
}

# 检查这台机器能不能跑 WSH 脚本（wscript）。
# 有些企业环境用组策略禁了 Windows Script Host；那时快捷方式会静默失效，
# 与其让用户对着不动的窗口猜，不如在创建时就说清楚。
function Test-WshEnabled {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows Script Host\Settings',
        'HKCU:\SOFTWARE\Microsoft\Windows Script Host\Settings'
    )
    foreach ($k in $keys) {
        # 用 -LiteralPath 而不是 -Path：项目规矩是"运行时取到的路径一律按字面处理"。
        # 收窄到"我知道这个不含通配符"就是把判断分散到每一处调用点，将来复制到别处就漏了。
        $v = (Get-ItemProperty -LiteralPath $k -Name 'Enabled' -ErrorAction SilentlyContinue).Enabled
        if ($null -ne $v -and $v -eq 0) { return $false }
    }
    return $true
}

# 建一个「走代理」或「固定直连」的快捷方式。
# 返回 Ok / Path / LauncherPath / Reason / Mode。
function New-ProxyShortcut {
    param(
        [Parameter(Mandatory=$true)][string]$TargetPath,
        [string]$WorkingDirectory = "",
        [string]$DestinationDir = "",
        [string]$Name = "",
        [string]$ModeId = $DefaultShortcutMode,
        [string]$ExtraArgs = "",
        [switch]$Force
    )
    $res = [pscustomobject]@{ Ok = $false; Path = ""; LauncherPath = ""; Reason = ""; Existed = $false
                              ProxyOk = $false; ProxyRaw = ""; Mode = $ModeId }

    $mode = Get-ShortcutMode $ModeId
    if (-not $mode) {
        $res.Reason = "未知的模式：$ModeId"
        return $res
    }
    $res.Mode = $mode.Id

    if (-not (Test-Path -LiteralPath $TargetPath)) {
        $res.Reason = "找不到这个程序：$TargetPath"
        return $res
    }
    if (-not (Test-WshEnabled)) {
        $res.Reason = "这台机器禁用了 Windows Script Host（组策略），建不了不闪窗口的启动方式。"
        return $res
    }
    # 建之前先看一眼当前代理值合不合法。
    # 不合法的值（别的工具写坏的、手工填错的）照样会建成功——快捷方式本身没毛病，
    # 它只是读不到可用的代理而已；但要在结果里说一句，否则用户点了图标发现没走代理，
    # 只会以为这个功能坏了。判断规则只写在 ConvertTo-ProxyUrl 那一处。
    try { $res.ProxyRaw = [string](Get-EnvProxyValue $PrimaryProxyVarName) } catch {}
    $res.ProxyOk = [bool](ConvertTo-ProxyUrl $res.ProxyRaw)
    if (-not $WorkingDirectory) { $WorkingDirectory = Split-Path -Parent $TargetPath }
    if (-not (Test-Path -LiteralPath $WorkingDirectory)) { $WorkingDirectory = Split-Path -Parent $TargetPath }
    if (-not $DestinationDir) { $DestinationDir = [Environment]::GetFolderPath('Desktop') }
    if (-not (Test-Path -LiteralPath $DestinationDir)) {
        $res.Reason = "目标文件夹不存在：$DestinationDir"
        return $res
    }
    if (-not $Name) { $Name = Get-PathBaseName $TargetPath }
    foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) { $Name = $Name.Replace([string]$ch, '') }
    if (-not $Name) { $Name = '程序' }
    # 图标名 = 程序名 + 模式后缀。**后缀从模式表来，不写字面量**：
    # 写死 '（走代理）' 的话，加「固定直连」时这一行会静默沿用旧后缀，
    # 两个模式的图标在桌面上长得一模一样，用户点哪个都说不清。
    $lnkPath = Join-Path $DestinationDir ($Name + $mode.Suffix + '.lnk')
    if ((Test-Path -LiteralPath $lnkPath) -and -not $Force) {
        $res.Existed = $true
        $res.Path = $lnkPath
        $res.Reason = "已经有同名快捷方式：$lnkPath"
        return $res
    }

    $vbsPath = $null
    try {
        $vbsPath = New-ProxyLauncherScript $TargetPath $WorkingDirectory $mode.Id $ExtraArgs
    } catch {
        $res.Reason = "生成启动脚本失败：$($_.Exception.Message)"
        return $res
    }
    $res.LauncherPath = $vbsPath

    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    if (-not (Test-Path -LiteralPath $wscript)) { $wscript = 'wscript.exe' }

    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut($lnkPath)
        $lnk.TargetPath = $wscript
        $lnk.Arguments = '"' + $vbsPath + '"'
        # 工作目录照原样传：很多程序靠它找自己的资源文件，改成别处会打不开。
        $lnk.WorkingDirectory = $WorkingDirectory
        $lnk.IconLocation = $TargetPath + ',0'
        # 前缀取自模式表，加一种模式不必改这里。
        $desc = $mode.Desc + $Name
        $lnk.Description = $desc
        $lnk.WindowStyle = 1
        $lnk.Save()
    } catch {
        $res.Reason = "写快捷方式失败：$($_.Exception.Message)"
        return $res
    } finally {
        if ($shell) { try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch {} }
    }

    # 写后回读：写成功不等于读回来是对的（本项目其它写操作同一条规矩）。
    # 判据只钉三件与实现无关的事实：指向 wscript、参数指向我们刚写的启动脚本、工作目录对。
    #
    # 回读失败时必须把刚写的 .lnk 删掉：否则用户看到"[失败] 没能创建"，
    # 桌面上却多了一个图标；下次再建会撞上"已经有同名快捷方式"，
    # 于是永远建不成，而屏幕上给的理由（已有同名）也是错的。
    # COM 释放放 finally：回读任一属性抛异常时也不会漏。
    $verifyOk = $false
    $verifyMsg = ''
    try {
        $shell2 = New-Object -ComObject WScript.Shell
        try {
            $chk = $shell2.CreateShortcut($lnkPath)
            $okTarget = ($chk.TargetPath -ieq $wscript)
            $okArgs = ([string]$chk.Arguments).Contains($vbsPath)
            $okDir = ($chk.WorkingDirectory -ieq $WorkingDirectory)
            $verifyOk = ($okTarget -and $okArgs -and $okDir)
            if (-not $verifyOk) {
                $verifyMsg = ("写进去的内容读回来不对（目标={0} 参数={1} 工作目录={2}）" -f $okTarget, $okArgs, $okDir)
            }
        } finally {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell2)
        }
    } catch {
        $verifyMsg = "回读校验失败：$($_.Exception.Message)"
    }
    if (-not $verifyOk) {
        # 收干净：半截的快捷方式比没有更糟，它会让下一次尝试也失败。
        try { Remove-Item -LiteralPath $lnkPath -Force -ErrorAction SilentlyContinue } catch {}
        $res.Reason = $verifyMsg
        return $res
    }

    # 记下落点。只在**回读通过之后**记：回读失败的分支上面已经把 .lnk 删掉了，
    # 那时记下来只会让扫描去翻一个空目录。
    # 标准目录也会走到这里，但 Register-ShortcutExtraDir 自己会跳过它们。
    try { Register-ShortcutExtraDir $DestinationDir } catch {}

    $res.Ok = $true
    $res.Path = $lnkPath
    return $res
}

# 这个快捷方式的参数（Arguments）是不是指向**我们 launchers 目录里**的 .vbs。
#
# 抽成独立函数有两个原因：① 判据只有一处，扫描和测试读同一份；
# ② 这是个"判得宽就会动别人东西"的地方——按子串包含判，launchers2 / launchers_backup
#    这类同级目录里的用户脚本也会被认成我们的，卸载时一起删掉。判得严只是留下自己的
#    垃圾，判得宽是碰别人的文件，两种代价不对称。
#
# 判法：去引号 → 拒绝含 ..（规范化后可能落到目录外）→ 规范化 → 与"目录 + 分隔符"比前缀。
# 加分隔符是关键：只比 "…\launchers" 的话，"…\launchers2" 也会命中。
function Test-ProxyShortcutArgsOurs([string]$Arguments) {
    if (-not $Arguments) { return $false }
    if ($Arguments -notmatch '(?i)\.vbs"?$') { return $false }
    $raw = $Arguments.Trim().Trim('"')
    if (-not $raw) { return $false }
    if ($raw -match '\.\.') { return $false }
    $full = ''
    try { $full = [System.IO.Path]::GetFullPath($raw) } catch { return $false }
    if (-not $full) { return $false }
    $root = ''
    try { $root = [System.IO.Path]::GetFullPath((Get-ProxyLauncherDir)).TrimEnd('\') } catch { return $false }
    if (-not $root) { return $false }
    return $full.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

# 扫出所有「我们建的」快捷方式。
#
# 判据是**内容**而不是文件名：同时满足"目标是 wscript.exe"和"参数指向
# 本工具的 launchers 目录"，才算我们建的。只按名字判会误删用户自己建的
# 同名图标——那是别人的东西，一个字节都不该动。
#
# 返回每个记录的：LnkPath、LauncherPath、Name、State。
#   State: ok（图标和脚本都在）/ no-launcher（脚本没了）/ broken-target（程序没了）
function Get-ProxyShortcutRecords {
    $records = @()

    # 四处要扫，每处都带一个给人看的位置名。
    # 位置名必须写进界面：同一个程序的图标可能同时出现在桌面、任务栏和开始菜单
    # （固定到任务栏时 Windows 会**复制**一份），只列文件名的话用户看到两行
    # 一模一样的内容，分不清哪个是哪个，也不敢删任何一个。
    $dirs = Get-ShortcutDirList -WithTaskBar $true
    $seen = @{}
    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($d in $dirs) {
            if (-not $d.Path -or -not (Test-Path -LiteralPath $d.Path)) { continue }
            foreach ($f in @(Get-ChildItem -LiteralPath $d.Path -Filter '*.lnk' -File -ErrorAction SilentlyContinue)) {
                if ($seen.ContainsKey($f.FullName)) { continue }
                $lnk = $null
                try { $lnk = $shell.CreateShortcut($f.FullName) } catch { continue }
                if (-not $lnk) { continue }
                $args = [string]$lnk.Arguments
                # 判据一：目标是 wscript.exe
                $isWscript = ([string]$lnk.TargetPath) -match '(?i)wscript\.exe$'
                if (-not $isWscript) { continue }
                # 判据二：参数指向我们 launchers 目录里的 .vbs。
                # 判据只有一处实现（Test-ProxyShortcutArgsOurs），扫描与测试读同一份。
                if (-not (Test-ProxyShortcutArgsOurs $args)) { continue }
                $seen[$f.FullName] = $true

                # 从参数里取出 .vbs 路径（判据里已经校验过归属，这里只要原值显示给用户）
                $vbsPath = $args.Trim().Trim('"')

                # 名字与模式都从文件名剥：后缀表住在那张模式表里，不在这里手抄。
                # 认不出后缀 = 不是本工具建的名字（可能用户改过名），按"未知模式"处理：
                # 仍然列出来（它有我们的启动脚本），但不给它编一个假模式。
                $name = Get-ShortcutBaseName $f.BaseName
                $nameMode = Get-ShortcutModeFromName $f.BaseName
                # 判定顺序：**先读脚本里那行标记，再用文件名兜底**，最后才是"未知"。
                #
                # 为什么脚本优先：那行标记是生成那一刻写死的，用户改不了；
                # 而图标名用户随时能改。反过来会出一个很难发现的错：
                # 把「微信（翻墙）」改名成「微信（直连）」，界面就显示"直连"，
                # 而实际行为仍是翻墙——显示与行为相反，且屏幕上没有任何异常。
                #
                # 文件名只在脚本读不到模式时兜底（老版本建的脚本没有那行标记）。
                $modeId = ''
                if (Test-Path -LiteralPath $vbsPath) { $modeId = Get-ProxyLauncherMode $vbsPath }
                if (-not $modeId -and $nameMode) { $modeId = $nameMode.Id }
                # 三种状态，都要能判出来：
                #   no-launcher   —— 启动脚本被删了，点了必定失败
                #   broken-target —— 脚本在，但它要启动的程序被卸载/搬走了，点了也会失败
                #   ok            —— 两样都在
                # 中间那个状态以前只写在注释里没有实现，于是程序卸载之后管理页仍显示"正常"，
                # 用户点了才发现打不开。程序路径就记在启动脚本的注释行里（Get-ProxyLauncherTarget），
                # 读一次就知道，不必再单独存一份。
                $state = 'ok'
                $targetPath = ''
                if (-not (Test-Path -LiteralPath $vbsPath)) {
                    $state = 'no-launcher'
                } else {
                    $targetPath = Get-ProxyLauncherTarget $vbsPath
                    # 读不到程序路径（旧版本建的脚本）时不下判断：那种情况"不知道"不等于"坏了"，
                    # 报成 broken-target 会让旧脚本一律显示成故障。
                    if ($targetPath -and -not (Test-Path -LiteralPath $targetPath)) {
                        $state = 'broken-target'
                    }
                }
                $records += [pscustomobject]@{
                    LnkPath      = $f.FullName
                    LauncherPath = $vbsPath
                    Name         = $name
                    ModeId       = $modeId
                    Mode         = (Get-ShortcutMode $modeId)
                    State        = $state
                    Where        = $d.Where
                    ProgramPath  = $targetPath
                    Target       = [string]$lnk.TargetPath
                }
            }
        }
    } finally {
        if ($shell) { try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch {} }
    }
    return $records
}

# 扫出 `launchers` 目录里没有被任何图标引用的启动脚本。
# 用途：管理页要把"图标删了、脚本还在"的情况也显示出来，否则用户不知道
# 那个 .vbs 是不是没用了。
function Get-OrphanProxyLaunchers {
    $dir = Get-ProxyLauncherDir
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $used = @{}
    foreach ($r in (Get-ProxyShortcutRecords)) {
        if ($r.LauncherPath) { $used[$r.LauncherPath.ToLower()] = $true }
    }
    $out = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.vbs' -File -ErrorAction SilentlyContinue)) {
        if (-not $used.ContainsKey($f.FullName.ToLower())) {
            # 名字里那段哈希对人没有意义，把脚本自己记下的程序路径一并带出去，
            # 界面才能显示"这个脚本是给哪个程序的"。读不到就留空，界面另有说法。
            $tgt = Get-ProxyLauncherTarget $f.FullName
            $nm = $f.BaseName
            if ($tgt) { $nm = Get-PathBaseName $tgt }
            $out += [pscustomobject]@{ LauncherPath = $f.FullName; Name = $nm; Target = $tgt }
        }
    }
    return $out
}

# 删掉所有我们建的快捷方式与启动脚本。返回删了多少、有哪些删不掉。
function Remove-ProxyShortcuts {
    $res = [pscustomobject]@{ RemovedLnk = 0; RemovedLauncher = 0; Failed = @() }
    foreach ($r in (Get-ProxyShortcutRecords)) {
        try {
            Remove-Item -LiteralPath $r.LnkPath -Force -ErrorAction Stop
            $res.RemovedLnk++
        } catch {
            $res.Failed += $r.LnkPath
        }
    }
    # 脚本全删（含孤儿：图标已经不在的那些）
    $dir = Get-ProxyLauncherDir
    if (Test-Path -LiteralPath $dir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.vbs' -File -ErrorAction SilentlyContinue)) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $res.RemovedLauncher++
            } catch {
                $res.Failed += $f.FullName
            }
        }
        # 目录空了就删，不空就留着（可能还有用户的其它东西）
        try {
            if (-not (Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
    return $res
}

# 扫出可以作为候选的程序。
# 来源：桌面 + 用户开始菜单 + 公共开始菜单的 .lnk。
# 返回去重后的 { Name, TargetPath, WorkingDirectory }。
# 快捷方式可能所在的目录，带一个给人看的位置名。
#
# 两处清单**必须分开**，不是重复：
#   - 这一份（$WithTaskBar = $true）用于**管理我们建过的图标**：固定到任务栏时
#     Windows 会复制一份到 TaskBar 目录，不扫那里就会漏掉用户实际点的那个。
#   - 候选程序那份**不能**含任务栏：那里放的都是已经在别处出现过的图标，
#     扫进来只会让同一个程序在候选列表里出现两次。
# 合成一份的后果是两种场景必有一边错，所以差异是有意的。
# 按**显示宽度**取前 N 格，用于把长路径手动断行。
#
# 与 pages 层的 Limit-DisplayText 不同：那个会补省略号（它是"只显示一行"的场合），
# 这里要的是"分段显示完整内容"，所以只切、不加标记，切点在字符边界上。
# 为什么不能用 .Substring($n)：中文一字两格，按字符数切会让中文行超宽。
function Limit-DisplayTextWithTail([string]$Text, [int]$Width) {
    if (-not $Text) { return '' }
    if ($Width -le 1) { return $Text.Substring(0, 1) }
    $accW = 0
    $i = 0
    foreach ($ch in $Text.ToCharArray()) {
        $cw = Get-CharWidth $ch
        if ($accW + $cw -gt $Width) { break }
        $accW += $cw
        $i++
    }
    if ($i -le 0) { $i = 1 }
    return $Text.Substring(0, $i)
}

# 判断一个程序是不是浏览器内核做的（Chrome / Edge / Electron 应用）。
#
# 为什么这件事能自动做：这类程序有个**结构上的**共同点，不是猜的——
#   Electron 应用必有 resources\app.asar（它的前端代码就打包在那个文件里）
#   Chrome/Edge 本体旁边必有 chrome.dll 或 msedge.dll
# 这两个都是"没有它就跑不起来"的东西，不是可选的附带文件。
#
# 为什么要排除系统目录：System32 下面装着 Edge 的 WebView 组件
# （Microsoft-Edge-WebView\msedge.dll），不排除的话 cmd.exe、notepad.exe
# 全都会被判成浏览器内核——而给它们加 --proxy-server 会直接打不开。
#
# 判错的代价不对称：漏判只是这个图标不走代理（用户还能用），
# 误判是那个程序根本打不开。所以判据只在"确认无误"时才说"是"。
function Test-ChromiumApp([string]$ExePath) {
    if (-not $ExePath) { return $false }
    if (-not (Test-Path -LiteralPath $ExePath)) { return $false }
    $dir = Split-Path -Parent $ExePath
    if (-not $dir) { return $false }
    foreach ($s in @($env:SystemRoot, "$env:SystemRoot\System32", "$env:SystemRoot\SysWOW64", "$env:SystemRoot\WinSxS")) {
        if ($s -and $dir.StartsWith($s, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    # Electron：resources\app.asar
    if (Test-Path -LiteralPath (Join-Path $dir 'resources\app.asar')) { return $true }
    $subs = @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue)
    foreach ($sub in $subs) {
        if (Test-Path -LiteralPath (Join-Path $sub.FullName 'resources\app.asar')) { return $true }
    }
    # Chrome/Edge：核心 dll（本级或版本号子目录里）
    $dlls = @('chrome.dll', 'chrome_elf.dll', 'msedge.dll', 'msedge_elf.dll')
    foreach ($n in $dlls) {
        if (Test-Path -LiteralPath (Join-Path $dir $n)) { return $true }
    }
    foreach ($sub in $subs) {
        foreach ($n in $dlls) {
            if (Test-Path -LiteralPath (Join-Path $sub.FullName $n)) { return $true }
        }
    }
    return $false
}

# 曾经用过的自定义落点，存在 launchers 旁边的一行一个文件里。
#
# 为什么必须记：图标建到别处之后，扫描那四个标准目录就看不见它了，
# 而"找不到对应图标的启动脚本"会被当成孤儿——用户在管理页删掉那条孤儿，
# 桌面上的图标就变成双击报错（启动脚本没了）。一个合法选项变成无声陷阱。
# 记下落点则扫描和孤儿判定都用同一份清单，放哪儿都找得到。
function Get-ShortcutExtraDirsFile {
    return (Join-Path (Get-InstallDir) 'shortcut-dirs.txt')
}

function Get-ShortcutExtraDirs {
    $f = Get-ShortcutExtraDirsFile
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    $out = @()
    try {
        foreach ($l in @(Get-Content -LiteralPath $f -Encoding UTF8 -ErrorAction Stop)) {
            $s = "$l".Trim()
            # 目录已经不在了就跳过，但不删记录：外接硬盘拔了就属于这种，
            # 插回来图标还在，记录不该因为一次"暂时找不到"而丢。
            if ($s -and (Test-Path -LiteralPath $s)) { $out += $s }
        }
    } catch {}
    return @($out | Select-Object -Unique)
}

# 记一个落点。标准目录不记：它们在扫描清单里本来就有，记了只是重复。
function Register-ShortcutExtraDir([string]$Dir) {
    if (-not $Dir) { return }
    if (-not (Test-Path -LiteralPath $Dir)) { return }
    $full = (Resolve-Path -LiteralPath $Dir).Path.TrimEnd('\')
    # 已经是标准目录之一就不必记
    foreach ($d in @(Get-ShortcutDirList -WithTaskBar $true)) {
        if ($d.Path -and ((Resolve-Path -LiteralPath $d.Path -ErrorAction SilentlyContinue).Path.TrimEnd('\') -eq $full)) { return }
    }
    $f = Get-ShortcutExtraDirsFile
    $cur = @()
    if (Test-Path -LiteralPath $f) {
        try { $cur = @(Get-Content -LiteralPath $f -Encoding UTF8 -ErrorAction Stop | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) } catch { $cur = @() }
    }
    if ($cur -contains $full) { return }
    $cur += $full
    $dir = Split-Path -Parent $f
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue }
    try { Set-Content -LiteralPath $f -Value $cur -Encoding UTF8 -ErrorAction Stop } catch {}
}

function Get-ShortcutDirList([bool]$WithTaskBar = $false) {
    $dirs = @(
        @{ Path = [Environment]::GetFolderPath('Desktop'); Where = '桌面' },
        @{ Path = [Environment]::GetFolderPath('Programs'); Where = '开始菜单' },
        @{ Path = [Environment]::GetFolderPath('CommonPrograms'); Where = '开始菜单（所有用户）' }
    )
    if ($WithTaskBar) {
        $dirs = @(
            @{ Path = [Environment]::GetFolderPath('Desktop'); Where = '桌面' },
            @{ Path = (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'); Where = '任务栏' },
            @{ Path = [Environment]::GetFolderPath('Programs'); Where = '开始菜单' },
            @{ Path = [Environment]::GetFolderPath('CommonPrograms'); Where = '开始菜单（所有用户）' }
        )
    }
    # 用户自选过的落点也要扫。漏掉它们的话，建到别处的图标在管理页里看不见，
    # 而它的启动脚本会被当成"没有对应图标的孤儿"——用户在管理页删掉那条孤儿，
    # 那个图标就变成双击报错。一个合法的落点选项变成无声的陷阱。
    $known = @()
    foreach ($d in $dirs) { if ($d.Path) { $known += ($d.Path.TrimEnd('\')) } }
    foreach ($x in @(Get-ShortcutExtraDirs)) {
        if (-not $x) { continue }
        if ($known -contains $x.TrimEnd('\')) { continue }
        # 位置名用最后一级目录：用户认得出"我的快捷方式"，认不出完整路径。
        $dirs += @{ Path = $x; Where = (Split-Path -Leaf $x) }
    }
    return $dirs
}

function Get-InstalledPrograms {
    $out = @()
    $seen = @{}
    # 不含任务栏：那里的图标都是别处已出现过的，扫进来会让同一个程序出现两次。
    $dirs = @(Get-ShortcutDirList -WithTaskBar $false | ForEach-Object { $_.Path })
    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($d in $dirs) {
            if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
            # 开始菜单有子目录，要递归；桌面一般只有一层
            foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter '*.lnk' -File -Recurse -ErrorAction SilentlyContinue)) {
                $lnk = $null
                try { $lnk = $shell.CreateShortcut($f.FullName) } catch { continue }
                if (-not $lnk) { continue }
                $t = [string]$lnk.TargetPath
                if (-not $t) { continue }
                # 只要可执行文件；UWP 应用的 TargetPath 是空的，已经在上面挡掉
                $ext = Get-PathExtension $t.ToLower()
                if ($ext -notin @('.exe', '.cmd', '.bat')) { continue }
                if (-not (Test-Path -LiteralPath $t)) { continue }
                if (Test-ProxyScanExcludedPath $t) { continue }
                $name = $f.BaseName
                if (Test-ProxyScanExcluded $name) { continue }
                $key = $t.ToLower()
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                $wd = [string]$lnk.WorkingDirectory
                if (-not $wd -or -not (Test-Path -LiteralPath $wd)) { $wd = Split-Path -Parent $t }
                $out += [pscustomobject]@{ Name = $name; TargetPath = $t; WorkingDirectory = $wd }
            }
        }
    } finally {
        if ($shell) { try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch {} }
    }
    return @($out | Sort-Object Name)
}

# ------------------------------------------------------------------------------
# 高级功能的三个屏幕：主页面、选程序、管理
# ------------------------------------------------------------------------------
# 排版沿用主菜单与帮助页那套：标题用 title、段标题用 heading、要敲的编号用 cmd、
# 名字用 value、说明用 dim。不新增颜色角色——门禁 6 逐角色比两侧颜色名，加一个
# 就要两边一起加，而现有十种足够表达这一屏的全部层级。

# 高级功能主页面。第一次进来的人什么都不知道，所以先讲"为什么需要"，
# 再讲"能做什么"，最后讲"要注意什么"。解释压在 3 行以内。
#
# 空行排列与帮助页同一套规矩：标题**上下各空一行**，内容块之间分开。
# 这里也遵守"不要手写不一致"——每一节都是"空行、标题、空行、内容"，
# 四节结构一模一样，加一节照抄一段即可。
# 高级功能里的菜单项。
#
# **打印与分派共用这一张表**：加一项就自动出现在屏幕上、也自动能敲，
# 不会再出现"表里加了、打印忘了"或"打印有、敲了没反应"。
# 与主菜单的 $MenuItems 同一条道理（那边也是表驱动）。
#
# 模块这一列是给「分组」用的：1-3 是同一个功能的三种操作（都围绕"给程序建图标"），
# 4 是另一件事（修浏览器代理），所以两模块分开显示、各带一句说明。
# 分组只影响打印顺序，不影响编号——编号是用户要敲的数字，按表顺序连续排。
# 高级功能表。**打印与分派共用这一张。**
#
# 七列，缺一不可。每列的存在理由：
#   Key      用户敲的数字。**不是标识**——重排会变，所以分派不许按它查身份
#   Action   稳定语义标识。分派、提示派生、「这是哪一项」一律靠它
#   Handler  处理器函数名。分派查这一列，查不到就大声失败
#   Module   分组，只影响打印顺序，不影响编号
#   Kind     do = 会改东西 / read = 只看不改。门禁靠它强制「只读项不许写」
#   Name     术语表的唯一权威。别处出现必须派生，不许手抄
#   Hint     一句决策依据
#
# 为什么 Action 与 Handler 分开：Action 是「这一项是什么」，Handler 是
# 「这一项怎么实现」。换实现只改 Handler，用户的提示文案一个字不动。
#
# @explain 「走代理」「固定直连」是菜单项的名字，用户按这两个词找菜单；不是解释机制。
$AdvancedItems = @(
    @{ Key='1'; Action='NewProxyIcon';  Module='icon';   Kind='do'
       Name='给程序建固定走代理的快捷方式'; Hint='挑一个已装的程序，或手动输入路径'
       Handler='Invoke-NewProxyShortcutFlow' }
    @{ Key='2'; Action='NewDirectIcon'; Module='icon';   Kind='do'
       Name='给程序建固定直连的快捷方式'; Hint='适合不想翻墙的软件，双击它一定不翻墙'
       Handler='Invoke-DirectShortcutFlow' }
    @{ Key='3'; Action='ManageIcons';   Module='icon';   Kind='do'
       Name='管理已建的';               Hint='看状态、删掉不要的'
       Handler='Invoke-ManageProxyShortcuts' }
    @{ Key='4'; Action='ViewRelay';     Module='icon';   Kind='read'
       Name='查看中继';                 Hint='图标用的那个固定地址，现在怎么样；只看不改'
       Handler='Show-RelayPage' }
    @{ Key='5'; Action='Rescue';        Module='rescue'; Kind='do'
       Name='网络与代理修复';           Hint='网页、终端工具连不上网的时候，先来这里查一下'
       Handler='Show-RescuePage' }
    @{ Key='6'; Action='WslGuide';      Module='guide';  Kind='read'
       Name='WSL 里也想翻墙';           Hint='要改一个系统设置，这里只讲怎么改'
       Handler='Show-WslGuidePage' }
    @{ Key='7'; Action='DockerGuide';   Module='guide';  Kind='read'
       Name='Docker 里也想翻墙';        Hint='要改 Docker 自己的设置，这里只讲怎么改'
       Handler='Show-DockerGuidePage' }
)

# 按 Action 取项。分派与「按语义名找编号」都走它。
# 取不到返回 $null，由调用方决定怎么报——静默回落会让「传错了名字」
# 变成「静默按默认做」，那是最坏的一种误导。

# 高级功能项的指路文案。与 base 层的 Get-MenuRef 同构：
# 编号与名字都从表里派生，**不许在文案里手写编号**。
#
# 手写的后果已经发生过一次：帮助里写「菜单选 5 再选 3，那一屏只看不改」，
# 而 3 号是「管理已建的」（会删东西），只看不改的是 4 号。
# 同一句里两个数字，一个对（5）一个错（3），因为都靠手抄。
# 用户按它去"看看状态"，却进了一个能删东西的页面。
#
# 取不到就返回空串：调用方据此把整句提示去掉，而不是印一个"再选 （）"。
function Get-AdvancedRef([string]$Action) {
    $ai = Get-AdvancedItem $Action
    if (-not $ai) { return '' }
    # 只带编号，不带名字：名字最长 18 个字，拼进去会把整句顶过 80 列，
    # 而 80 列的窗口会折行、后半截顶到最左边（自检里有断言盯这条）。
    # 编号才是他要敲的东西；名字在下一屏自己就看见了。
    return ('选 ' + $ai.Key)
}

function Get-AdvancedItem([string]$Action) {
    if (-not $Action) { return $null }
    foreach ($ai in $AdvancedItems) {
        if ($ai.Action -eq $Action) { return $ai }
    }
    return $null
}

# 表与代码的一致性自检：每个 Handler 必须是本侧真存在的函数。
# 在菜单入口处跑，不在加载期跑（库加载期不许有对外副作用）。
# 用 Test-Path function: 而不是 Get-Command：后者会触发模块自动加载，
# 而本项目的契约明确说自动加载会挑版本、让命令静默缺失。
function Assert-AdvancedTable {
    foreach ($ai in $AdvancedItems) {
        if (-not $ai.Handler) {
            throw ("高级功能表：{0}「{1}」没有 Handler" -f $ai.Key, $ai.Name)
        }
        if (-not (Test-Path -LiteralPath ('function:' + $ai.Handler))) {
            throw ("高级功能表：{0}「{1}」指向不存在的处理器 {2}" -f $ai.Key, $ai.Name, $ai.Handler)
        }
    }
}

# 模块顺序与各自的说明。加一个模块只改这两张表。
#
# 分三段的原因：icon 是「给某个程序定规矩」，rescue 是「出问题了先来查」，
# guide 是「本工具管不到的地方怎么自己配」——三者的意图完全不同，
# 混在一列里会让人分不清该看哪一段。
#
# guide 段的两项**只讲解、不动手**（表里 Kind='read'）：WSL 的 .wslconfig 和
# Docker Desktop 的设置改了会让它们起不来，而本工具没有能力验证改得对不对。
# 只讲不改是这里唯一负责的做法。
$AdvancedModules = @(
    @{ Id='icon';   Title='给某个程序定规矩'
       Why=@('有些程序只认启动那一刻的环境变量，不会自己去找代理。',
             '而资源管理器的环境可能在开机时就固定了，之后代理怎么变它都收不到。',
             '这里的快捷方式会在启动前先读一次代理，直接交给程序，绕开那一环。')
       Note=@('程序已经开着的，点了不会换代理，必须先关掉再点。',
              '微软商店装的应用（UWP）不支持，它们没有独立的 exe 路径。') }
    @{ Id='rescue'; Title='上不了网的时候'
       Why=@('翻墙软件被强行关掉（关机、断电、直接点叉）时，它写进系统和自己配置里的设置',
             '可能没来得及撤掉。浏览器和终端照旧把请求发给一个已经不存在的程序，',
             '于是连国内网站都打不开——线没断，是路指错了。')
       Note=@('只修「指向本机、但那个程序已经不在」的那一种。',
              '公司/学校给你的代理，它一个字节都不碰。') }
    @{ Id='guide';  Title='本工具管不到的地方'
       Why=@('浏览器和桌面应用看的是「系统代理」，不是这里的设置——那一层由你的翻墙软件管。',
             'WSL 和 Docker 各自是一套独立的系统，读的是它们自己的设置。',
             '下面两项只讲怎么改，不会替你动任何配置。')
       Note=@('这两项按回车只会看到说明，不会改你的设置。') }
)

# 按模块取项。打印用，分派不用（分派只按编号查）。
function Get-AdvancedItemsByModule([string]$Module) {
    return @($AdvancedItems | Where-Object { $_.Module -eq $Module })
}

# 高级功能页的内容。**从上面两张表生成，不手写**：
# 手写的话，加一项要同时改表和正文，必有一处漏——而这类漏法在屏幕上看不出来。
function Get-AdvancedPageLines {
    # 名字列按最宽的名字自动对齐。写死宽度会在改文案后错位——
    # 错位之后「编号—名字—说明」三列的读法就散了，用户分不清哪个说明属于哪一项。
    $nameWidth = 0
    foreach ($it in $AdvancedItems) {
        $w = Get-DisplayWidth $it.Name
        if ($w -gt $nameWidth) { $nameWidth = $w }
    }
    $out = New-Object System.Collections.ArrayList
    [void]$out.Add(@{ Role='title';   Text=(Format-TitleRule '高级功能') })
    # 模块之间画一条分隔线：三块内容各讲一件事，全靠 heading 区分时，
    # 眼睛要扫到下一行的颜色才能判断"这是新的一段"，而 heading 与正文的
    # 视觉重量太接近，那个边界看不出来。第一个模块前不画——
    # 标题下面紧跟一条线会像"标题被划掉了"。
    $advModIndex = 0
    foreach ($mod in $AdvancedModules) {
        $items = @(Get-AdvancedItemsByModule $mod.Id)
        if ($items.Count -eq 0) { continue }
        if ($advModIndex -gt 0) {
            [void]$out.Add(@{ Role='blank'; Text='' })
            [void]$out.Add(@{ Role='dim';   Text=(Format-PlainRule '高级功能') })
        }
        $advModIndex++
        [void]$out.Add(@{ Role='blank';   Text='' })
        [void]$out.Add(@{ Role='heading'; Text=('  ' + $mod.Title) })
        [void]$out.Add(@{ Role='blank';   Text='' })
        foreach ($w in $mod.Why) { [void]$out.Add(@{ Role='text'; Text=('    ' + $w) }) }
        [void]$out.Add(@{ Role='blank';   Text='' })
        foreach ($it in $items) {
            # @explain 「走代理的快捷方式」是这个功能的名字，用户按它逐字找菜单项；不是解释机制。
            $pad = ' ' * [Math]::Max(0, $nameWidth - (Get-DisplayWidth $it.Name))
            # 编号单独一段、染成 cmd 色（绿）：屏幕上的绿字就是"这是你要敲的东西"，
            # 与主菜单同一条规则。整行同色会让编号混进正文里，用户得逐字找。
            [void]$out.Add(@{
                Segments = @(
                    @{ Role='cmd';  Text=('    ' + $it.Key) }
                    @{ Role='item'; Text=('  ' + $it.Name + $pad + '   ' + $it.Hint) }
                )
            })
        }
        if ($mod.Note.Count -gt 0) {
            [void]$out.Add(@{ Role='blank';   Text='' })
            foreach ($n in $mod.Note) { [void]$out.Add(@{ Role='dim'; Text=('    ' + $n) }) }
        }
    }
    [void]$out.Add(@{ Role='blank';   Text='' })
    [void]$out.Add(@{ Role='dim';     Text=(Format-ListExitHint '输编号后回车执行') })
    return $out
}

# 把 role+text 的行画到屏幕上。与主菜单同一套颜色，只差这里是一行一色（不分段），
# 因为这一屏没有"标签 + 值"那种同行不同色的结构。
function Show-AdvancedPage {
    Clear-Screen
    foreach ($r in (Get-AdvancedPageLines)) {
        if ($r.Role -eq 'blank') { Write-Host ''; continue }
        # 一段一行一色：编号绿、名字白。没有分段的行照常整行一色。
        if ($r.ContainsKey('Segments')) {
            foreach ($seg in $r.Segments) { Write-Styled $seg.Role $seg.Text -NoNewline }
            Write-Host ''
            continue
        }
        Write-Styled $r.Role $r.Text
    }
}

# 「查看中继」这一屏：**只读**，不需要用户做任何操作。
#
# 为什么叫「查看」而不是「设置」：中继跟监控同生共死，自动工作，没有开关可拨。
# 把一屏"没有可操作项"的界面叫成"设置"，用户会一直在找那个不存在的开关。
# 它存在的意义是回答三个疑问：
#   ① 我那些图标用的是什么地址（为什么它们从来不用改）
#   ② 它现在有没有在工作（没在工作也不要紧——图标会退回读当前代理）
#   ③ 背后跟着的是哪个端口（换软件之后想确认一下）
# 把「查看中继」的一行行对象转成可交给屏幕层渲染的字符串帧。
#
# 为什么需要这一层：屏幕层（Write-ScreenFrame / Measure-ScreenFrame）处理的是
# 已经带颜色的字符串，而 Get-RelayPageLines 返回的是 { Role; Text } 结构。
# 两者之间要有个转换——否则每一处调用都得自己拼颜色，拼接规则一分叉就又回到
# "同一屏两种长相"那类问题。
#
# 角色到颜色走同一张表（Write-Styled 用的就是它），不在这里另写一份。
function ConvertTo-RelayFrame($Status) {
    $out = @()
    foreach ($r in (Get-RelayPageLines -Status $Status)) {
        if ($r.Role -eq 'blank') { $out += ''; continue }
        $out += (Format-Styled $r.Role $r.Text)
    }
    return $out
}

function Get-RelayPageLines {
    # 可选传入状态：实时刷新时调用方已经取过一次，再取一次等于每帧多发一个探针。
    # 不传就自己取，保证单独调用（一次性输出那条路）照常能用。
    param($Status = $null)
    $st = if ($Status) { $Status } else { Get-RelayStatus }
    $icons = 0
    try { $icons = @(Get-ProxyShortcutRecords).Count } catch {}
    # 这一屏的职责只有一件事：告诉他"现在没事，不用管"。
    # 所以"有没有在工作"必须在最前面用一句话说完，后面的内容只用来回答疑问。
    # 曾经把"去选 1 修它"放在这里，同屏又写着"什么都不用做"——
    # 给了动作又立刻收回，读者会在"要不要管"之间反复，那比不说更糟。
    $lines = @(
        @{ Role='title';   Text=(Format-TitleRule '查看中继') },
        @{ Role='blank';   Text='' },
        @{ Role='heading'; Text='  它是什么' },
        @{ Role='blank';   Text='' },
        @{ Role='text';    Text='    就是给图标用的那个永不变的地址。' },
        @{ Role='text';    Text='    有些程序会把地址记进自己的设置里，翻墙软件一换端口它就废了；' },
        @{ Role='text';    Text='    中继不让它变，所以那些程序不用你去改设置。' },
        @{ Role='blank';   Text='' },
        @{ Role='heading'; Text='  现在的情况' },
        @{ Role='blank';   Text='' }
    )
    if ($st.Running) {
        $lines += @{ Role='ok';  Text=("    入口地址      http://127.0.0.1:{0}" -f $st.Port) }
        if ($st.Upstream -gt 0) {
            $lines += @{ Role='text'; Text=("    当前转发到    127.0.0.1:{0}" -f $st.Upstream) }
        } else {
            $lines += @{ Role='dim'; Text='    当前转发到    （还没有可用的代理，所以暂时不转发）' }
        }
        $lines += @{ Role='ok';  Text='    工作状态      正常' }
    } else {
        $lines += @{ Role='dim'; Text='    入口地址      （暂时没有开）' }
        $lines += @{ Role='dim'; Text='    工作状态      没在工作，但不影响使用' }
        $lines += @{ Role='dim'; Text='    图标会退回去读当前代理，照样能用；下次监控正常跑起来它会自己回来。' }
    }
    if ($icons -gt 0) {
        $lines += @{ Role='text'; Text=("    用它建的图标  {0} 个" -f $icons) }
    } else {
        $lines += @{ Role='dim';  Text='    用它建的图标  还没有' }
    }
    $lines += @(
        @{ Role='blank';   Text='' },
        @{ Role='dim';     Text='  这里没有开关要拨。' }
    )
    return $lines
}

function Show-RelayPage {
    # 这一屏要**实时刷新**：用户可能就一直开着它，期间关了翻墙软件、
    # 换了端口、又反复开关过。画一次就停住的话，他盯着一个"当前转发到 7078"
    # 的旧结论，而实际早就变了——屏幕上那句"现在的情况"就成了假话。
    #
    # 数据本来就是现成的：Get-RelayStatus 每帧重新读端口文件 + 发探针，
    # 它一直是新的。问题只在"画一次就返回"，所以这里照状态页那套做循环。
    #
    # 刷新节奏与状态页同一常量：数据是监控写的，监控 2-3 秒才更新一次，
    # 比它更快没有意义，只会白烧 CPU。
    $frame = @(ConvertTo-RelayFrame (Get-RelayStatus))
    $need = Measure-ScreenFrame $frame
    if (-not (Test-CanDrawScreen -NeedLines $need.Lines -NeedWidth $need.Width)) {
        # 画不了（窗口太小 / 不是终端）：退回一次性输出，至少让他看得见内容。
        Show-RelayPageOnce
        return
    }
    if (-not (Enter-Screen)) {
        Show-RelayPageOnce
        return
    }
    $prev = @()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $nextPaint = 0
    try {
        while ($true) {
            if ($sw.ElapsedMilliseconds -ge $nextPaint) {
                # 取数与渲染都要保护：一帧失败不该把用户踢出这一屏，
                # 保留上一帧、下一轮再试——与状态页同一套处置。
                try { $frame = @(ConvertTo-RelayFrame (Get-RelayStatus)) } catch { $frame = $prev }
                $need = Measure-ScreenFrame $frame
                if (Test-CanDrawScreen -NeedLines $need.Lines -NeedWidth $need.Width) {
                    $null = Write-ScreenFrame -Old $prev -New $frame
                    $prev = $frame
                } else {
                    # 窗口被拉小了：作废记账，恢复时必然整帧重画。
                    $prev = @()
                }
                $nextPaint = $sw.ElapsedMilliseconds + $StatusRefreshIntervalMs
            }
            $k = Wait-ScreenKey -Milliseconds $ScreenPollMs
            # 退出判据必须**和屏幕上写的话一致**：这一屏写着"看完按回车返回"，
            # 而 Wait-ScreenKey 只把 Esc / 0 / q 当 Quit，回车回的是 CR 字符。
            # 所以这里直接认回车（CR / LF），再加上与别处一致的 Quit / Error。
            #
            # **空串不是按键。** Wait-ScreenKey 等满一个轮询周期、没等到键时
            # 返回的是空串——把它当退出，等于"画完一帧就自己走人"：
            # 实测就是这一屏闪一下退回上一级菜单，用户以为点坏了。
            # 空串必须继续循环，这是它与状态页唯一不同的地方（状态页不需要认回车）。
            if ($k -eq 'Error') { break }
            if ($k -eq 'Quit') { break }
            if ($k -eq "`r" -or $k -eq "`n") { break }
        }
    } finally {
        Exit-Screen
    }
}

# 一次性输出（实时刷新不可用时的降级路径）。
function Show-RelayPageOnce {
    Clear-Screen
    foreach ($r in (Get-RelayPageLines)) {
        if ($r.Role -eq 'blank') { Write-Host ''; continue }
        Write-Styled $r.Role $r.Text
    }
    # 这里必须自己等一次回车。
    #
    # 从"实时刷新"降级到"画一次"有两个触发条件：窗口太小，或者不是真终端
    # （比如输出被重定向）。这两种情况下若画完就返回，调用方会立刻重画上一层菜单——
    # 这一屏只闪几十毫秒，用户什么都没看清就没了，他会以为"点了没反应"。
    # 那正是 Show-ProgramPicker 里记过的同一个毛病：能看见的提示必须配一个能应答的输入。
    #
    # 等键放在这个函数内部，而不是交给调用方补一次 Read-Host：
    # 那样实时路径和降级路径的"怎么退出"就散在两处，将来改一处忘另一处。
    try { $null = Wait-ScreenKey -Milliseconds 60000 } catch {}
    # Wait-ScreenKey 最多等 60 秒；真终端里任何键都会立刻返回，不会真等满。
    # 非交互环境（没有控制台句柄）它会连续失败并返回 Error，那时也没必要再等。
}

# 选程序页：把扫出来的程序列成编号表。
# 一屏放不下就分页——ADHD 用户对着滚出屏幕的列表会直接放弃。
function Show-ProgramPicker {
    param([array]$Programs, [int]$PageSize = 12)

    if (-not $Programs -or $Programs.Count -eq 0) {
        # 空列表也要真的读一次输入。
        # 只画一屏、不读就返回的话，调用方会立刻重画上一层，那一屏只闪几十毫秒——
        # 用户点完"1 给程序建快捷方式"什么都没发生，再点一次、再闪一次，
        # 三次之后他就认为这功能坏了。而屏幕上明明写着"输 P 手动输入路径"，
        # 只是他永远没机会按。能看见的提示必须配一个能应答的输入。
        while ($true) {
            Clear-Screen
            Write-Styled 'title' (Format-TitleRule '选一个程序')
            Write-Host ''
            Write-Styled 'warn' '  没找到可以建快捷方式的程序。'
            Write-Host ''
            Write-Styled 'dim' '  常见原因：程序装在非常规位置，或者它的快捷方式不在开始菜单里。'
            Write-Styled 'dim' '  可以直接输入程序文件的完整路径。'
            Write-Host ''
            Write-Styled 'dim' '  输 P 手动输入路径    0 = 返回'
            $a = ''
            try { $a = "$(Read-Host '选择')".Trim() } catch { return $null }
            if (-not $a) { continue }
            if ($a -eq '0' -or $a -match '^[Qq]$') { return $null }
            if ($a -match '^[Pp]$') {
                $p = ''
                try { $p = "$(Read-Host '  程序路径（可把文件拖进来）')".Trim() } catch { continue }
                $p = $p.Trim('"').Trim("'")
                if (-not $p) { continue }
                if (-not (Test-Path -LiteralPath $p)) {
                    Write-Styled 'warn' '  找不到这个文件。'
                    Start-Sleep -Milliseconds 900
                    continue
                }
                return ([pscustomobject]@{
                    Name = Get-PathBaseName $p
                    TargetPath = $p
                    WorkingDirectory = (Split-Path -Parent $p)
                })
            }
            Write-Styled 'warn' '  这里只有 P 和 0 两个键。'
            Start-Sleep -Milliseconds 900
        }
    }

    $page = 0
    $totalPages = [math]::Ceiling($Programs.Count / $PageSize)
    while ($true) {
        Clear-Screen
        Write-Styled 'title' (Format-TitleRule '选一个程序')
        Write-Host ''
        $start = $page * $PageSize
        $end = [Math]::Min($start + $PageSize - 1, $Programs.Count - 1)
        Write-Styled 'dim' ('  找到 ' + $Programs.Count + ' 个' + $(if($totalPages -gt 1){"（第 $($page+1)/$totalPages 页，编号 $($start+1)-$($end+1)）"}else{''}) + '：')
        Write-Host ''
        for ($i = $start; $i -le $end; $i++) {
            # 编号是**全局连续**的（第 2 页从 13 开始），不是每页重新从 1 数。
            # 每页重置的话，用户想选第 20 个会输 8（第 2 页第 8 个），
            # 而屏幕得先告诉"这一页是 13-24"他才知道该输什么——一层不必要的换算，
            # 换算错了得到的回答是"没有这个编号"，方向完全相反。
            $n = $i + 1
            Write-Styled 'item' ('    ' + $n.ToString().PadLeft(2) + '  ' + $Programs[$i].Name)
        }
        Write-Host ''
        $nav = '  输编号选择'
        if ($totalPages -gt 1) {
            if ($page -lt $totalPages - 1) { $nav += '    N = 下一页' }
            if ($page -gt 0) { $nav += '    B = 上一页' }
        }
        Write-Styled 'dim' ($nav + '    P = 手动输入路径    0 = 返回')

        $ans = ''
        try { $ans = "$(Read-Host '选择')".Trim() } catch { return $null }
        if (-not $ans) { continue }
        if ($ans -eq '0' -or $ans -match '^[Qq]$') { return $null }
        if ($ans -match '^[Pp]$') {
            $p = ''
            try { $p = "$(Read-Host '  程序路径（可把文件拖进来）')".Trim() } catch { continue }
            $p = $p.Trim('"').Trim("'")
            if (-not $p) { continue }
            if (-not (Test-Path -LiteralPath $p)) {
                Write-Styled 'warn' '  找不到这个文件。'
                try { $null = Read-Host (Format-PromptHint '回车继续') } catch { return $null }
                continue
            }
            return ([pscustomobject]@{
                Name = Get-PathBaseName $p
                TargetPath = $p
                WorkingDirectory = (Split-Path -Parent $p)
            })
        }
        if ($ans -match '^[Nn]$') {
            if ($page -lt $totalPages - 1) { $page++; continue }
            Write-Styled 'warn' '  已经是最后一页了。'
            Start-Sleep -Milliseconds 900
            continue
        }
        if ($ans -match '^[Bb]$') {
            if ($page -gt 0) { $page--; continue }
            Write-Styled 'warn' '  已经在第一页了。'
            Start-Sleep -Milliseconds 900
            continue
        }
        $idx = 0
        # 编号是全局的，所以直接用 $idx 当下标，不必再减 $start。
        if ([int]::TryParse($ans, [ref]$idx) -and $idx -ge ($start + 1) -and $idx -le ($end + 1)) {
            return $Programs[$idx - 1]
        }
        # 说清这一页有哪些编号，而且**不重画**：重画会让屏幕往下滚，
        # 连错几次就再也找不到自己在哪（主菜单早就为这个原因定过这条规矩）。
        Write-Styled 'warn' ('  没有这个编号：' + $ans + '（这一页是 ' + ($start + 1) + '-' + ($end + 1) + '）')
        Start-Sleep -Milliseconds 1200
    }
}

# 建快捷方式的完整流程：选程序 -> 选位置 -> 确认 -> 建 -> 报结果
function Invoke-NewProxyShortcutFlow([string]$ModeId = $DefaultShortcutMode) {
    # 模式在这里定下来，之后整条流程都用它。**模式决定这一屏的所有措辞**：
    # 走代理要说"它会带上当前代理"，固定直连要说"它一定不走代理"——
    # 两种意图相反的操作用同一套话术，用户会在确认页看不出自己要建的是哪个。
    $mode = Get-ShortcutMode $ModeId
    if (-not $mode) {
        Write-Styled 'warn' ("  未知的模式：{0}" -f $ModeId)
        Start-Sleep -Milliseconds 900
        return
    }
    # 行为类别取自表里的 Action，不是从 Id 猜。
    $isDirect = ($mode.Action -eq 'direct')

    $progs = @(Get-InstalledPrograms)
    $chosen = Show-ProgramPicker -Programs $progs
    if (-not $chosen) { return }

    # 同一个程序可能已经有别的模式的图标了。提前说一句，用户才知道桌面上会多一个。
    $existing = @()
    try {
        $existing = @(Get-ProxyShortcutRecords | Where-Object {
            $_.ProgramPath -and ($_.ProgramPath -ieq $chosen.TargetPath) -and $_.State -ne 'no-launcher'
        })
    } catch {}
    $otherMode = @($existing | Where-Object { $_.ModeId -and $_.ModeId -ne $mode.Id })

    # 选放哪里。默认桌面——用户最容易看到也最容易拖到任务栏。
    Clear-Screen
    Write-Styled 'title' (Format-TitleRule '放在哪里')
    Write-Host ''
    Write-Styled 'text' ('  程序：' + $chosen.Name)
    Write-Styled 'dim'  ('  路径：' + $chosen.TargetPath)
    # 规矩也要写在这一屏：用户刚选完程序，这时的第一件事是确认"我要给它定什么规矩"。
    $modeRole = $mode.Role
    Write-Styled $modeRole ('  规矩：' + $mode.Label)
    if ($otherMode.Count -gt 0) {
        $names = ($otherMode | ForEach-Object {
            if ($_.Mode) { $_.Mode.Label } else { '别的规矩' }
        } | Sort-Object -Unique) -join '、'
        Write-Styled 'dim' ('  它已经有「' + $names + '」的图标了，这次会再多一个，两个并存')
    }
    Write-Host ''
    Write-Styled 'item' '    1  桌面（默认）'
    Write-Styled 'item' '    2  开始菜单'
    Write-Styled 'item' '    3  自己输入一个文件夹'
    Write-Host ''
    Write-Styled 'dim' '  输编号后回车    直接回车 = 桌面    0 = 返回'

    # 这一屏也要有出口。原来只有 1/2/3 三条路，选完程序想反悔时
    # 只能"走完确认页再按回车取消"——多三次按键，而且他不知道自己正在取消。
    $dest = [Environment]::GetFolderPath('Desktop')
    while ($true) {
        $ans = ''
        try { $ans = "$(Read-Host '选择')".Trim() } catch { return }
        if ($ans -eq '0' -or $ans -match '^[Qq]$') { return }
        if (-not $ans -or $ans -eq '1') {
            $dest = [Environment]::GetFolderPath('Desktop'); break
        }
        if ($ans -eq '2') {
            $dest = [Environment]::GetFolderPath('Programs'); break
        }
        if ($ans -eq '3') {
            # 输错路径要能重试，不能一次失败就取消整条流程：
            # 用户多半是从资源管理器复制过来的长路径，粘错一个字符很常见。
            $manual = ''
            try { $manual = "$(Read-Host '  文件夹路径（可把文件夹拖进来）')".Trim() } catch { return }
            $manual = $manual.Trim('"').Trim("'")
            if (-not $manual) { continue }
            if (Test-Path -LiteralPath $manual) { $dest = $manual; break }
            Write-Styled 'warn' '  找不到这个文件夹，请重新输入。'
            Start-Sleep -Milliseconds 900
            continue
        }
        Write-Styled 'warn' '  只有 1、2、3、0 四个键。'
        Start-Sleep -Milliseconds 900
    }
    if (-not $dest -or -not (Test-Path -LiteralPath $dest)) {
        Write-Styled 'warn' '  这个文件夹用不了，已取消。'
        try { $null = Read-Host (Format-PromptHint '回车继续') } catch {}
        return
    }

    # ---- 浏览器内核做的程序：自动判断，不额外问一屏 ----
    #
    # 这类程序（Chrome / Edge / VS Code / Electron 应用）只认系统代理，
    # 不看环境变量，所以要让它按这个规矩走，得给它带上 --proxy-server 启动参数。
    #
    # 为什么不问用户：这不是他能回答的问题——"它是不是浏览器内核做的"
    # 是内部概念，摊给用户看只会让他卡住。判断由 Test-ChromiumApp 做，
    # 判据是结构性的（见那个函数），实测准确；结果写在确认页上，
    # 他觉得不对可以按 0 退出重来。
    $isChromium = Test-ChromiumApp $chosen.TargetPath
    $extraArgs = ''
    if ($isChromium) {
        if ($isDirect) {
            # 强制直连：direct:// 让它彻底不用代理，bypass-list=* 是双保险
            # （有些版本在 direct:// 下仍会去读一遍绕过列表）。
            $extraArgs = '--proxy-server=direct:// --proxy-bypass-list=*'
        } else {
            # 走代理这一支要写成占位符，由启动器在**点击那一刻**替换成当时的代理地址。
            # 不在这里写死端口：翻墙软件换端口后写死的图标就废了，
            # 而"每次点击重新决定"正是启动器这一层的价值。
            $extraArgs = '--proxy-server=__ENVPROXY_CURRENT__ --proxy-bypass-list=localhost,127.0.0.1,[::1]'
        }
    }

    # 确认
    # 三段用同一套"标签 + 值"排版。原来「程序」只有标签、值另起一行，
    # 而下面两段是同一行，三段格式不一致，最像"界面坏了"的位置恰好是最后确认这屏。
    Clear-Screen
    Write-Styled 'title' (Format-TitleRule '确认')
    Write-Host ''
    Write-Styled 'text' ('  程序    ' + $chosen.Name)
    Write-Styled 'dim'  ('          ' + $chosen.TargetPath)
    Write-Host ''
    Write-Styled 'text' ('  规矩    ' + $mode.Label)
    # 后果说明取自模式表，与图标名、短名同一个来源，不会各说一套。
    $modeNote = $mode.Note
    Write-Styled 'dim'  ('          ' + $modeNote)
    Write-Host ''
    Write-Styled 'text' ('  图标名  ' + (Get-PathBaseName $chosen.TargetPath) + $mode.Suffix)
    Write-Styled 'text' ('  放在    ' + $dest)
    # 浏览器内核的程序要额外带启动参数，这件事必须在确认页上说一句：
    # 不说的话，用户不知道为什么这个图标和别的不一样，出问题时也无从对照。
    # 措辞只讲"对他有什么影响"，不讲内核、参数这些他不需要知道的东西。
    if ($isChromium) {
        Write-Styled 'text' ('  适配    ' + '这个程序需要单独指定，已自动带上')
    }

    Write-Host ''
    # 先探一次同名：把"会覆盖"直接写进这一屏，让用户一次 y 就完成。
    #
    # 原来要按两次 y（确认建 + 确认覆盖），而第二次按回车会静默"什么都没改"。
    # 用户重做的原因通常正是"原来那个不对"，他第一屏按完 y 就以为结束了，
    # 第二屏顺手回车 → 旧图标原样留着 → 他回到桌面点一下还是坏的 →
    # 得出结论"这个修复功能没用"。两个 y 表达同一个意图，本身就是设计错误。
    $lnkName = Get-PathBaseName $chosen.TargetPath
    $wouldBe = Join-Path $dest ($lnkName + $mode.Suffix + '.lnk')
    $willOverwrite = Test-Path -LiteralPath $wouldBe
    if ($willOverwrite) {
        Write-Styled 'warn' '  这个位置已经有同名图标了，确认后会覆盖它。'
        Write-Styled 'dim'  ('    ' + $wouldBe)
    } else {
        Write-Styled 'dim'  '  你原来的图标不会被改动，两个可以同时用。'
    }
    Write-Host ''
    Write-Styled 'dim'  '  输 y 回车确认，直接回车 = 取消'
    $c = ''
    try { $c = "$(Read-Host '确认')".Trim() } catch { return }
    if (-not ($c -match '^(y|yes|是)$')) {
        Write-Styled 'dim' '  已取消，什么都没改。'
        Start-Sleep -Milliseconds 800
        return
    }

    # 建。用户在上一屏已经确认过"要覆盖"，这里直接用 -Force，不再问第二遍。
    $r = New-ProxyShortcut -TargetPath $chosen.TargetPath -WorkingDirectory $chosen.WorkingDirectory `
                           -DestinationDir $dest -Name $lnkName -ModeId $mode.Id -ExtraArgs $extraArgs -Force:$willOverwrite
    Clear-Screen
    if ($r.Ok) {
        Write-Styled 'ok' ('  [完成] ' + $(if($willOverwrite){'已覆盖：'}else{'已创建：'}))
        Write-Styled 'dim' ('    ' + $r.Path)
        Write-Host ''
        Write-Styled 'text' '  原来的图标没动，两个可以同时用。'
        Write-Styled 'dim'  ('  启动脚本在：' + $r.LauncherPath)
        Write-Host ''
        Write-Styled 'dim'  '  想固定到任务栏：把这个新图标拖到任务栏就行。'
        Write-Styled 'dim'  '  注意别删掉上面那个启动脚本，删了图标就失效。'
        # 代理值不合法时要说一句：快捷方式本身建好了，只是它读不到能用的代理。
        # 不说的话用户点了图标发现没走代理，会以为这个功能坏了。
        # 只在**走代理**的模式下提醒。直连模式本来就不读代理，
        # 对它说"开好代理软件再点一次"是把人往错的方向推——
        # 他会以为直连图标也需要代理，甚至真的去开代理重做一遍。
        # 比的是 $r.Mode 本身：New-ProxyShortcut 在结果里放的是模式 Id 字符串（"proxy"/"direct"）。
        # 曾经这里写的是 $r.Mode.Action —— 字符串上取 .Action 恒为 $null，比较永远为假，
        # 于是这段告警成了死代码：代理没开时建图标一声不响，用户点进去发现没走代理。
        if (-not $r.ProxyOk -and $r.Mode -eq 'proxy') {
            Write-Host ''
            Write-Styled 'warn' '  注意：现在没有检测到有效的代理地址。'
            Write-Styled 'dim'  '  这个图标仍然能用，但启动时会直连。开好代理软件再点一次就正常了。'
        }
        Write-Host ''
        # 这里**不追问"要不要覆盖"**。
        #
        # 曾经这里问过，用户的原话是：「我当时都没有新建任何东西，还叫我覆盖什么」。
        # 他说的对：走到这一步，图标刚刚建好（上面那行 [完成] 已经打出来了），
        # 而"覆盖"暗示有另一份东西会被替换掉——但他没有第二份，也看不见第二份。
        # 一个无法回答的问题比不问更糟：他只能随便按一个，然后不知道自己选了什么。
        #
        # 真正需要"更新已有图标"的场景（同名的图标已经在那儿）由 New-ProxyShortcut
        # 自己的 -Force 语义处理：它只写 <名字><后缀>.lnk 这一个文件，从不碰
        # 用户原本的快捷方式。所以这里不需要再问一遍——上面已经建好了。
    } else {
        Write-Styled 'warn' '  [失败] 没能创建：'
        Write-Styled 'dim'  ('         ' + $r.Reason)
    }
    Write-Host ''
    try { $null = Read-Host (Format-PromptHint '回车返回') } catch {}
}

# 管理页：列出所有我们建的快捷方式，可以逐个删。
# 按程序分组显示：同一个程序的图标和启动脚本是配套的，分开列会让人以为它们无关。
function Invoke-ManageProxyShortcuts {
    # 翻页状态留在循环外：每轮重画时不能把它重置，否则按 N 只会闪一下回到第一页。
    $page = 0
    while ($true) {
        $recs = @(Get-ProxyShortcutRecords)
        $orphans = @(Get-OrphanProxyLaunchers)
        Clear-Screen
        Write-Styled 'title' (Format-TitleRule '管理已建的')
        Write-Host ''
        if ($recs.Count -eq 0 -and $orphans.Count -eq 0) {
            Write-Styled 'dim' '  还没有建过。先回上一页选 1 或 2 建一个。'
            Write-Host ''
            try { $null = Read-Host (Format-PromptHint '回车返回') } catch {}
            return
        }
        # 按程序名排序，同一程序的两种规矩自然挨在一起。
        # 这样「WeChat 翻墙」和「WeChat 直连」上下相邻，一眼看出是同一程序的两个版本；
        # 不排序则按扫描顺序散落各处，看起来像两个无关的图标。
        $sorted = @($recs | Sort-Object { $_.Name }, { $_.ModeId })

        # 分页：每个图标占 2-4 行（标题、状态、图标路径、脚本路径），
        # 十几个图标就会滚出屏幕，顶部的标题和底部的提示都看不见，
        # 用户反而找不到自己刚看到的那个编号。与选程序页同一套做法。
        $pageSize = 6
        $pageCount = [Math]::Max(1, [Math]::Ceiling($sorted.Count / $pageSize))
        if ($page -ge $pageCount) { $page = $pageCount - 1 }
        if ($page -lt 0) { $page = 0 }

        $idx = 0
        if ($sorted.Count -gt 0) {
            $pageStart = $page * $pageSize
            $pageEnd = [Math]::Min($pageStart + $pageSize, $sorted.Count) - 1
            # 编号用全局连续编号（第 2 页从 7 开始），不用每页从 1 起：
            # 分页只是少画几条，编号是"这个图标叫什么"的身份，跳来跳去会让人以为选错了。
            $idx = $pageStart
            for ($pi = $pageStart; $pi -le $pageEnd; $pi++) {
                $r = $sorted[$pi]
                $idx++

                # 标题行：编号 + 哪个程序 + 什么规矩 + 在哪。
                # 这四样是"我在看什么"的全部，必须一条横着读完。
                $modeLabel = if ($r.Mode) { $r.Mode.Label } else { '认不出来' }
                $modeRole = if ($r.Mode) { $r.Mode.Role } else { 'warn' }
                Write-Styled 'cmd'  ('  ' + $idx.ToString().PadLeft(2) + '  ') -NoNewline
                Write-Styled 'item' $r.Name -NoNewline
                Write-Styled 'dim'  '  ·  ' -NoNewline
                Write-Styled $modeRole $modeLabel -NoNewline
                Write-Styled 'dim'  ('  ·  ' + $r.Where)
                Write-Host ''

                # 详情一律另起缩进行。**每行都必须一行放得下**：
                # 路径比窗口宽时，PowerShell 会在任意位置硬折行，
                # 后半截顶到最左边——看起来像另一条无关的内容，整屏结构就散了。
                # 所以按"窗口宽度减去缩进"裁，末尾补省略号，宁可少看几个字符。
                $indent = '      '
                $avail = (Get-ConsoleWidth) - (Get-DisplayWidth $indent) - 2

                $stateText = switch ($r.State) {
                    'ok'            { '正常' }
                    'no-launcher'   { '启动脚本被删了，点了会失败' }
                    'broken-target' { '程序已经不在了（被卸载或搬走），点了会失败' }
                    default         { $r.State }
                }
                $stateRole = if ($r.State -eq 'ok') { 'ok' } else { 'warn' }
                Write-Styled 'key'   $indent -NoNewline
                Write-Styled 'key'   '状态  ' -NoNewline
                Write-Styled $stateRole $stateText
                Write-Host ''

                # 认不出规矩时说明为什么，而不是只给两个字。
                # 用户看到"认不出来"会以为是坏了；实际多半是旧版本建的图标，
                # 删掉重建就正常——这个补救办法必须说出来，否则他不知道怎么办。
                if (-not $r.Mode) {
                    Write-Styled 'dim' ($indent + '      ' + '（旧版建的，改名后对不上号；删了重建就好）')
                    Write-Host ''
                }

                # 路径单独占一行，标签固定宽（4 格），冒号与路径的起点永远对齐。
                # 标签不对齐时两条路径的起点参差，眼睛要重新找位置。
                foreach ($pair in @(@('图标', $r.LnkPath), @('脚本', $r.LauncherPath))) {
                    $lbl = $pair[0]
                    $val = [string]$pair[1]
                    if (-not $val) { continue }
                    $label = $indent + $lbl + '  '
                    $labelW = Get-DisplayWidth $label
                    # 路径给完整的，一个字都不省——用户要看的就是"到底在哪个文件"。
                    # 代价是比窗口宽时会折行，所以这里按窗口宽度自己断行、
                    # 并给续行补上与路径起点对齐的缩进：
                    # 交给终端自然折行的话，后半截会顶到最左边，看起来像另一条内容。
                    # 留 2 格余量：在最后一格写字符终端会提前折行。
                    $wrapW = [Math]::Max(16, (Get-ConsoleWidth) - $labelW - 2)
                    $rest = $val
                    $first = $true
                    while ($rest) {
                        if ($first) {
                            Write-Styled 'key' $label -NoNewline
                            $first = $false
                        } else {
                            Write-Styled 'dim' (' ' * $labelW) -NoNewline
                        }
                        $chunk = Limit-DisplayTextWithTail $rest $wrapW
                        Write-Styled 'dim' $chunk
                        Write-Host ''
                        $rest = $rest.Substring($chunk.Length)
                    }
                }
                # 图标之间空一行：不空的话上一个的脚本路径和下一个的标题连成一片，
                # 分不清哪个路径属于哪个图标。
                Write-Host ''
            }
            Write-Host ''
            # 统计一句话说清"我总共建了多少"。用户在一长列里数不出来。
            $progCount = @($sorted | ForEach-Object { $_.Name } | Sort-Object -Unique).Count
            $summary = '  一共 ' + $sorted.Count + ' 个图标，涉及 ' + $progCount + ' 个程序。'
            if ($pageCount -gt 1) {
                $summary += ('  第 ' + ($page + 1) + '/' + $pageCount + ' 页（N 下一页，B 上一页）。')
            }
            Write-Styled 'dim' $summary
            }
        if ($orphans.Count -gt 0) {
            Write-Host ''
            # 这一段的意思是"还有启动脚本，但它的图标我找不到"。
            # 用户完全可能把图标挪到别处（自己建的文件夹、移动硬盘），那不算错，
            # 所以措辞不能写成"图标已经被删了"——那会让他以为自己弄坏了什么。
            Write-Styled 'heading' '  这些启动脚本没有对应的图标'
            Write-Host ''
            Write-Styled 'dim' '  （图标可能被你挪到别处了，也可能删掉了）'
            foreach ($o in $orphans) {
                $idx++
                Write-Styled 'item' ('  ' + $idx.ToString().PadLeft(2) + '  ' + $o.Name)
                if ($o.Target) {
                    Write-Styled 'dim' ('    程序  ' + $o.Target)
                } else {
                    Write-Styled 'dim' '    程序  （这个脚本没记下是哪个程序，可能是旧版本建的）'
                }
                Write-Styled 'dim'  ('    脚本  ' + $o.LauncherPath)
            }
        }
        Write-Host ''
        # 底部说明要说清两件事：删的是图标；脚本被共用时会保留。
        # 原来只写"连同它的启动脚本"，共用时那句话是假的。
        Write-Styled 'dim' '  输编号 = 删掉那个图标（启动脚本还被别的图标用着时会保留）'
        Write-Styled 'dim' '  0 = 返回'

        $ans = ''
        try { $ans = "$(Read-Host '选择')".Trim() } catch { return }
        if (-not $ans -or $ans -eq '0' -or $ans -match '^[Qq]$') { return }
        # 翻页要在编号解析之前判：否则 'N' 会被当成非法编号，报"没有这个编号：N"。
        if ($ans -match '^[Nn]$') {
            if ($page -lt $pageCount - 1) { $page++; continue }
            Write-Styled 'warn' '  已经是最后一页了。'
            Start-Sleep -Milliseconds 900
            continue
        }
        if ($ans -match '^[Bb]$') {
            if ($page -gt 0) { $page--; continue }
            Write-Styled 'warn' '  已经是第一页了。'
            Start-Sleep -Milliseconds 900
            continue
        }
        $n = 0
        if (-not [int]::TryParse($ans, [ref]$n) -or $n -lt 1 -or $n -gt $idx) {
            Write-Styled 'warn' ('  没有这个编号：' + $ans + '（可用的有 1-' + $idx + '）')
            Start-Sleep -Milliseconds 700
            continue
        }
        # 定位到具体那一条。
        # **必须用 $sorted，不能用 $recs**：屏幕上的编号是按程序名排过序的，
        # 而 $recs 是扫描顺序。两处用不同的序，用户选 1、实际删的却是另一个——
        # 而这个错误在屏幕上看不出来，直到他发现删错了图标。
        $targetLnk = $null
        $targetVbs = $null
        if ($n -le $sorted.Count) {
            $targetLnk = $sorted[$n-1].LnkPath
            $targetVbs = $sorted[$n-1].LauncherPath
        } else {
            $targetVbs = $orphans[$n - $sorted.Count - 1].LauncherPath
        }

        Write-Host ''
        # 这个启动脚本还有别人在用吗？
        # 同一个程序可以建两个图标（桌面一个、开始菜单一个）：它们的 .lnk 不同名，
        # 但启动脚本按"程序路径哈希"命名，所以是**同一个文件**。
        # 不看一眼就删，会把另一个图标一起弄坏——而用户当时的意图只是"删掉重复的那个"。
        $sharedBy = @($recs | Where-Object { $_.LauncherPath -eq $targetVbs -and $_.LnkPath -ne $targetLnk })
        Write-Styled 'text' '  确定要删掉吗？'
        if ($targetLnk) { Write-Styled 'dim' ('    图标  ' + $targetLnk) }
        Write-Styled 'dim' ('    脚本  ' + $targetVbs)
        if ($sharedBy.Count -gt 0) {
            Write-Host ''
            Write-Styled 'warn' '  这个启动脚本还有别的图标在用，会保留：'
            foreach ($s in $sharedBy) { Write-Styled 'dim' ('    ' + $s.LnkPath) }
        }
        Write-Host ''
        Write-Styled 'dim' '  输 y 回车确认，直接回车 = 不删'
        $c = ''
        try { $c = "$(Read-Host '确认')".Trim() } catch { continue }
        if (-not ($c -match '^(y|yes|是)$')) { continue }

        $okAll = $true
        if ($targetLnk -and (Test-Path -LiteralPath $targetLnk)) {
            try { Remove-Item -LiteralPath $targetLnk -Force -ErrorAction Stop }
            catch { $okAll = $false; Write-Styled 'warn' ('  图标删不掉：' + $_.Exception.Message) }
        }
        if ($targetVbs -and (Test-Path -LiteralPath $targetVbs) -and $sharedBy.Count -eq 0) {
            try { Remove-Item -LiteralPath $targetVbs -Force -ErrorAction Stop }
            catch { $okAll = $false; Write-Styled 'warn' ('  脚本删不掉：' + $_.Exception.Message) }
        }
        if ($okAll) {
            Write-Styled 'ok' '  [完成] 已删除。'
        } else {
            Write-Styled 'warn' '  [未完成] 上面列出的那些没删掉，可能被占用。'
        }
        Start-Sleep -Milliseconds 900
    }
}

# 高级功能的总入口：菜单选 5 进来就是这里。
function Show-AdvancedMenu {
    # 先自检：表里指的处理器都真实存在。放在这里而不是加载期——
    # 库加载期不许有对外副作用（本项目契约），而且进这一屏才需要它。
    try {
        Assert-AdvancedTable
    } catch {
        Write-Styled 'warn' ('  ' + $_.Exception.Message)
        Start-Sleep -Milliseconds 1200
        return
    }
    while ($true) {
        Show-AdvancedPage
        $ans = ''
        try { $ans = "$(Read-Host '选择')".Trim() } catch { return }
        if (-not $ans -or $ans -eq '0' -or $ans -match '^[Qq]$') { return }
        # 分派：编号 -> 行 -> Handler。**只查表，不认识任何具体功能的名字。**
        #
        # 为什么不能写一张「编号 → 动作」的哈希表：那是同一件事的第二份描述。
        # 表里加一项而这里忘了加，屏幕上有那个编号、敲下去却说"没有这个编号"；
        # 插入一项让编号重排时，这里每一行都要改，改错一处就是静默执行错的动作。
        # 现在加一项只需要在表里加一行，分派代码一个字不动。
        $hit = $null
        foreach ($ai in $AdvancedItems) {
            if ([string]$ai.Key -eq $ans) { $hit = $ai; break }
        }
        if ($hit) {
            # Handler 名字已经在入口处自检过存在性，这里直接调用。
            #
            # 会改动东西的项（Kind='do'）要先拿操作锁：它们写的是**全局位置**
            # （%LOCALAPPDATA%\EnvProxy\launchers、系统代理注册表），
            # 而不只是这个文件夹。另一个窗口正在安装/卸载时同时改这些地方，
            # 两边各写一半，最后谁对谁错取决于时序——那是屏幕上看不出来的坏状态。
            #
            # 判据取自表里的 Kind，不写死编号：以后加新项只要标了 do 就自动受保护，
            # 忘了标门禁 16 会拦住（只读项里出现写操作直接红）。
            if ($hit.Kind -eq 'do') {
                $opLock = $null
                try {
                    $opLock = New-Object System.Threading.Mutex($false, (Get-MutexName 'EnvProxyInstallOp'))
                    if (-not $opLock.WaitOne(0)) {
                        Write-Styled 'warn' '  另一个安装/卸载正在进行，请等它结束再试（没有做任何改动）。'
                        Start-Sleep -Milliseconds 1400
                        $hit = $null
                    }
                } catch { $opLock = $null }
                if ($hit) {
                    try { & $hit.Handler }
                    finally {
                        if ($opLock) { try { $opLock.ReleaseMutex() } catch {} }
                    }
                } else {
                    if ($opLock) { try { $opLock.ReleaseMutex() } catch {} }
                }
            } else {
                & $hit.Handler
            }
        } else {
            # 可用编号从表里算，不写死：加一项后提示会自动跟上来。
            $keys = @($AdvancedItems | ForEach-Object { $_.Key })
            Write-Styled 'warn' ('  没有这个编号：' + $ans + '（可用的有 ' + ($keys -join '、') + '，0 = 返回）')
            Start-Sleep -Milliseconds 700
        }
    }
}

# 「给程序建固定直连的快捷方式」的入口。
#
# 为什么是独立的一个函数而不是给上面那个加个参数：
# 表里每一项的 Handler 都必须是**无参、自成一屏、自己收键**的形状（这是表能成立的前提）。
# 带参数的入口会让分派要么加 if、要么这一项单独开分支，表的假设就破了。
function Invoke-DirectShortcutFlow {
    Invoke-NewProxyShortcutFlow -ModeId 'direct'
}

# ------------------------------------------------------------------------------
# 本工具管不到的地方：只讲解、不动手
# ------------------------------------------------------------------------------
#
# 这两个页面共享同一套结构：先说清「为什么管不到」，再给可照抄的做法，
# 最后明说「我没改任何东西」。
#
# 为什么不做成自动配置：WSL 的 .wslconfig 改错会让 WSL 起不来；
# Docker Desktop 的设置文件官方没公开格式。改坏了我无法验证，用户会连"去下载修复版"
# 都做不到——那正是最不该制造的状态。

# 通用的一屏讲解渲染。$Blocks 是若干 { Role; Text } 行的数组。
function Show-GuidePage([string]$Title, [object[]]$Blocks, [string]$Footer) {
    Clear-Screen
    Write-Styled 'title' ('======== ' + $Title + ' ========')
    Write-Host ''
    foreach ($b in $Blocks) {
        Write-Styled $b.Role ($b.Text)
    }
    # 结尾这两行不能和正文挤在一起，也不能太暗：
    # "我没改你的东西"是这一页的结论，"按回车返回"是唯一的出路，
    # 两者都写成 dim 时会混进上面的讲解里，用户读完不知道这一步算完了没有。
    Write-Host ''
    Write-Styled 'text' ('  ' + $Footer)
    Write-Host ''
    Write-Styled 'key' (Format-ExitHint 'BackToMenu')
    try { $null = Read-Host } catch {}
}

function Show-WslGuidePage {
    $blocks = @(
        @{ Role='text'; Text='  WSL 是另一套系统，装在你 Windows 里面。' }
        @{ Role='text'; Text='  它有自己的网络设置，看不到这里设的代理变量。' }
        @{ Role='blank'; Text='' }
        @{ Role='heading'; Text='  想让 WSL 里也能翻墙，改一个设置就行' }
        @{ Role='blank'; Text='' }
        @{ Role='text'; Text='  1. 打开这个文件（没有就新建）：' }
        @{ Role='cmd'; Text='    C:\Users\你的用户名\.wslconfig' }
        @{ Role='blank'; Text='' }
        @{ Role='text'; Text='  2. 写入下面两行：' }
        @{ Role='cmd'; Text='    [wsl2]' }
        @{ Role='cmd'; Text='    networkingMode=mirrored' }
        @{ Role='cmd'; Text='    autoProxy=true' }
        @{ Role='blank'; Text='' }
        @{ Role='text'; Text='  3. 存盘，然后在 PowerShell 里执行一次：' }
        @{ Role='cmd'; Text='    wsl --shutdown' }
        @{ Role='blank'; Text='' }
        @{ Role='text'; Text='  之后 WSL 会自己跟着 Windows 的代理走，不用再管。' }
        @{ Role='blank'; Text='' }
        @{ Role='dim'; Text='  要 Windows 11 22H2 或更新的版本才支持这两行。' }
        @{ Role='dim'; Text='  旧版本会忽略它们，不会出问题，但也就不生效。' }
    )
    Show-GuidePage 'WSL 里也想翻墙' $blocks '这一页只讲解，没有改你的任何设置。'
}

function Show-DockerGuidePage {
    $blocks = @(
        @{ Role='text'; Text='  Docker 的代理分三层，各有各的设置位置。' }
        @{ Role='text'; Text='  这里只讲最常用的两种，都不受本工具影响。' }
        @{ Role='blank'; Text='' }
        @{ Role='heading'; Text='  一、拉镜像慢或拉不下来（docker pull）' }
        @{ Role='blank'; Text='' }
        @{ Role='text'; Text='  改 Docker Desktop 自己的设置：' }
        @{ Role='cmd';  Text='    Settings → Resources → Proxies' }
        @{ Role='text'; Text='  地址填 http://127.0.0.1:端口号。端口号看菜单选 2（查看状态）。' }
        @{ Role='blank'; Text='' }
        @{ Role='dim'; Text='  注意：改 daemon.json 在 Docker Desktop 上没用，它不读那个文件。' }
        @{ Role='blank'; Text='' }
        @{ Role='heading'; Text='  二、容器里面的程序要翻墙' }
        @{ Role='blank'; Text='' }
        @{ Role='text'; Text='  启动容器时显式传进去（宿主的变量不会自动进去），' }
        @{ Role='text'; Text='  把下面的端口号换成菜单 2 显示的那个：' }
        @{ Role='cmd';  Text='    docker run -e HTTP_PROXY=http://host.docker.internal:端口号 镜像名' }
        @{ Role='blank'; Text='' }
        @{ Role='text'; Text='  想一次配好、以后都不用传，写进 ~/.docker/config.json 的 proxies 字段。' }
        @{ Role='dim'; Text='  它管容器和构建，但管不了 docker pull —— 那是第一层的事。' }
    )
    Show-GuidePage 'Docker 里也想翻墙' $blocks '这一页只讲解，没有改你的任何设置。'
}
