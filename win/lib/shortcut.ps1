# ==============================================================================
#  shortcut.ps1 — 走代理的快捷方式：生成启动脚本、读写 .lnk、扫描记录、三屏界面
#
#  为什么单独成一个库：这一块与"安装/卸载/状态编排"完全是两件事。
#  它自带 VBS 生成、.lnk 的 COM 读写、程序扫描和三屏交互，约 1000 行；
#  留在 ops 里会让以后每一次动 ops 都得先绕过它，也让这一块的边界看不见。
#
#  依赖只有 base：常量、纯函数、配色输出（Write-Styled）、清屏（Clear-Screen）、
#  屏幕宽度与折行（Get-ConsoleWidth / Split-DisplayText）都住在 base。
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

# 快捷方式文件名后缀。放进名字而不是"另存到别的目录"，是为了在任务栏和开始
# 菜单里一眼分辨：同一个程序的两个图标各自身份明确，用户不会点错。
$ProxyShortcutSuffix = '（走代理）'

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
    'readme', '帮助', '说明', '更新日志', 'changelog', 'license',
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
    # 系统目录里的东西不是用户装的程序（regedit / cmd / 各种 .cpl）
    $win = ([string]$env:SystemRoot).ToLower()
    if ($win -and $p.StartsWith($win + '\system32\')) { return $true }
    if ($win -and $p.StartsWith($win + '\syswow64\')) { return $true }
    # 卸载器几乎都叫 unins*.exe / uninstall*.exe
    $file = [System.IO.Path]::GetFileNameWithoutExtension($p)
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
function New-ProxyLauncherBody([string]$TargetPath, [string]$WorkingDir) {
    if (-not $TargetPath) { throw '目标路径为空' }
    if (-not $WorkingDir) { $WorkingDir = Split-Path -Parent $TargetPath }
    # PowerShell 单引号串里的单引号要写成两个
    $t = $TargetPath.Replace("'", "''")
    $w = $WorkingDir.Replace("'", "''")
    # 变量名与 NO_PROXY 的默认值都从 base 层的权威常量来，不在这里手抄一遍。
    # 手抄的后果不是"多写几个字"，而是同一个程序从快捷方式启动和从终端启动
    # 拿到不同的 NO_PROXY：以后往默认值里加一项，这里会漏改，
    # 症状是"有时候连不上"，而且只在某一种启动方式下出现。
    $addrVars = @($ProxyVarNames | Where-Object { $_ -notin @('NO_PROXY', 'NODE_USE_ENV_PROXY') })
    $setv = ''
    foreach ($n in $addrVars) { $setv += ('$env:' + $n + '=$p;') }
    $noProxyDefault = $DefaultNoProxy.Replace("'", "''")
    $ps = "`$p=(gp 'HKCU:\Environment' -ea 0).HTTPS_PROXY;" +
          "if(`$p){" + $setv +
          "`$n=(gp 'HKCU:\Environment' -ea 0).NO_PROXY;" +
          "if(-not `$n){`$n='" + $noProxyDefault + "'};" +
          "`$env:NO_PROXY=`$n;`$env:NODE_USE_ENV_PROXY='1'}" +
          "else{try{Add-Type -AssemblyName PresentationFramework;" +
          "[Windows.MessageBox]::Show('没检测到代理，程序将直连启动。请先开代理软件再点一次。','EnvProxy')|Out-Null}catch{}};" +
          "Start-Process -FilePath '$t' -WorkingDirectory '$w'"
    return (Compress-ToBase64 $ps)
}

# 生成启动脚本（.vbs）的内容。
# 纯 ASCII：VBS 文件带 BOM 或中文都可能被某些旧版 WSH 读错，而 base64 本来就没有中文。
function New-ProxyLauncherVbs([string]$EncodedBody, [string]$TargetPath = "") {
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
            $body += "' envproxy-target-hex: " + $hex + "`r`n"
        } catch {}
    }
    return $body
}

# 从一个启动脚本里读出它服务的程序路径。读不出来返回空串。
function Get-ProxyLauncherTarget([string]$LauncherPath) {
    if (-not $LauncherPath) { return '' }
    try {
        if (-not (Test-Path -LiteralPath $LauncherPath)) { return '' }
        $text = [System.IO.File]::ReadAllText($LauncherPath, [System.Text.Encoding]::ASCII)
        $m = [regex]::Match($text, "envproxy-target-hex:\s*([0-9a-fA-F]+)")
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
# 文件名带路径哈希：两个不同目录下同名的程序（都叫 app.exe）不会互相覆盖，
# 而同一个程序反复建仍然是同一个文件（不会越积越多）。
function New-ProxyLauncherScript([string]$TargetPath, [string]$WorkingDir) {
    $dir = Get-ProxyLauncherDir
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($TargetPath)
    foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) { $base = $base.Replace([string]$ch, '') }
    if (-not $base) { $base = 'app' }
    # 取路径 sha256 的前 8 位做区分；同一路径永远得到同一个名字
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($TargetPath.ToLower()))
    } finally { $sha.Dispose() }
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt 4; $i++) { [void]$sb.Append($hash[$i].ToString('x2')) }
    $vbsPath = Join-Path $dir ($base + '_' + $sb.ToString() + '.vbs')

    $enc = New-ProxyLauncherBody $TargetPath $WorkingDir
    $vbs = New-ProxyLauncherVbs $enc $TargetPath
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

# 建一个「走代理」的快捷方式。
# 返回 Ok / Path / LauncherPath / Reason。
function New-ProxyShortcut {
    param(
        [Parameter(Mandatory=$true)][string]$TargetPath,
        [string]$WorkingDirectory = "",
        [string]$DestinationDir = "",
        [string]$Name = "",
        [switch]$Force
    )
    $res = [pscustomobject]@{ Ok = $false; Path = ""; LauncherPath = ""; Reason = ""; Existed = $false
                              ProxyOk = $false; ProxyRaw = "" }

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
    try { $res.ProxyRaw = [string](Get-ItemProperty -LiteralPath (Get-UserEnvKeyPath) -Name 'HTTPS_PROXY' -ErrorAction SilentlyContinue).HTTPS_PROXY } catch {}
    $res.ProxyOk = [bool](ConvertTo-ProxyUrl $res.ProxyRaw)
    if (-not $WorkingDirectory) { $WorkingDirectory = Split-Path -Parent $TargetPath }
    if (-not (Test-Path -LiteralPath $WorkingDirectory)) { $WorkingDirectory = Split-Path -Parent $TargetPath }
    if (-not $DestinationDir) { $DestinationDir = [Environment]::GetFolderPath('Desktop') }
    if (-not (Test-Path -LiteralPath $DestinationDir)) {
        $res.Reason = "目标文件夹不存在：$DestinationDir"
        return $res
    }
    if (-not $Name) { $Name = [System.IO.Path]::GetFileNameWithoutExtension($TargetPath) }
    foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) { $Name = $Name.Replace([string]$ch, '') }
    if (-not $Name) { $Name = '程序' }
    $lnkPath = Join-Path $DestinationDir ($Name + $ProxyShortcutSuffix + '.lnk')
    if ((Test-Path -LiteralPath $lnkPath) -and -not $Force) {
        $res.Existed = $true
        $res.Path = $lnkPath
        $res.Reason = "已经有同名快捷方式：$lnkPath"
        return $res
    }

    $vbsPath = $null
    try {
        $vbsPath = New-ProxyLauncherScript $TargetPath $WorkingDirectory
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
        $lnk.Description = ('通过 EnvProxy 走代理启动：' + $Name)
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
    $dirs = @(
        @{ Path = [Environment]::GetFolderPath('Desktop'); Where = '桌面' },
        @{ Path = (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'); Where = '任务栏' },
        @{ Path = [Environment]::GetFolderPath('Programs'); Where = '开始菜单' },
        @{ Path = [Environment]::GetFolderPath('CommonPrograms'); Where = '开始菜单（所有用户）' }
    )
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

                $name = $f.BaseName -replace [regex]::Escape($ProxyShortcutSuffix) + '$', ''
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
            if ($tgt) { $nm = [System.IO.Path]::GetFileNameWithoutExtension($tgt) }
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
function Get-InstalledPrograms {
    $out = @()
    $seen = @{}
    $dirs = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('Programs'),
        [Environment]::GetFolderPath('CommonPrograms')
    )
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
                $ext = [System.IO.Path]::GetExtension($t).ToLower()
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
function Get-AdvancedPageLines {
    return @(
        @{ Role='title';   Text='======== 高级功能 ========' },
        @{ Role='blank';   Text='' },
        @{ Role='heading'; Text='  为什么需要它' },
        @{ Role='text';    Text='    有些程序只认启动那一刻的环境变量，不会自己去找代理。' },
        @{ Role='text';    Text='    而资源管理器的环境可能在开机时就固定了，之后代理怎么变它都收不到。' },
        @{ Role='text';    Text='    这里的快捷方式会在启动前先读一次代理，直接交给程序，绕开那一环。' },
        @{ Role='blank';   Text='' },
        @{ Role='heading'; Text='  能做什么' },
        @{ Role='item';    Text='    1  给程序建走代理的快捷方式   挑一个已装的程序，或手动输入路径' },
        @{ Role='item';    Text='    2  管理已建的                 看状态、删掉不要的' },
        @{ Role='blank';   Text='' },
        @{ Role='heading'; Text='  要注意' },
        @{ Role='dim';     Text='    程序已经开着的，点了不会换代理，必须先关掉再点。' },
        @{ Role='dim';     Text='    微软商店装的应用（UWP）不支持，它们没有独立的 exe 路径。' },
        @{ Role='blank';   Text='' },
        @{ Role='dim';     Text='  输编号后回车执行    0 = 返回主菜单' }
    )
}

# 把 role+text 的行画到屏幕上。与主菜单同一套颜色，只差这里是一行一色（不分段），
# 因为这一屏没有"标签 + 值"那种同行不同色的结构。
function Show-AdvancedPage {
    Clear-Screen
    foreach ($r in (Get-AdvancedPageLines)) {
        if ($r.Role -eq 'blank') { Write-Host ''; continue }
        Write-Styled $r.Role $r.Text
    }
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
            Write-Styled 'title' '======== 选一个程序 ========'
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
                    Name = [System.IO.Path]::GetFileNameWithoutExtension($p)
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
        Write-Styled 'title' '======== 选一个程序 ========'
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
                try { $null = Read-Host '  按回车继续' } catch { return $null }
                continue
            }
            return ([pscustomobject]@{
                Name = [System.IO.Path]::GetFileNameWithoutExtension($p)
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
function Invoke-NewProxyShortcutFlow {
    $progs = @(Get-InstalledPrograms)
    $chosen = Show-ProgramPicker -Programs $progs
    if (-not $chosen) { return }

    # 选放哪里。默认桌面——用户最容易看到也最容易拖到任务栏。
    Clear-Screen
    Write-Styled 'title' '======== 放在哪里 ========'
    Write-Host ''
    Write-Styled 'text' ('  程序：' + $chosen.Name)
    Write-Styled 'dim'  ('  路径：' + $chosen.TargetPath)
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
        try { $null = Read-Host '  按回车继续' } catch {}
        return
    }

    # 确认
    # 三段用同一套"标签 + 值"排版。原来「程序」只有标签、值另起一行，
    # 而下面两段是同一行，三段格式不一致，最像"界面坏了"的位置恰好是最后确认这屏。
    Clear-Screen
    Write-Styled 'title' '======== 确认 ========'
    Write-Host ''
    Write-Styled 'text' ('  程序    ' + $chosen.Name)
    Write-Styled 'dim'  ('          ' + $chosen.TargetPath)
    Write-Host ''
    Write-Styled 'text' ('  图标名  ' + [System.IO.Path]::GetFileNameWithoutExtension($chosen.TargetPath) + $ProxyShortcutSuffix)
    Write-Styled 'text' ('  放在    ' + $dest)
    Write-Host ''
    # 先探一次同名：把"会覆盖"直接写进这一屏，让用户一次 y 就完成。
    #
    # 原来要按两次 y（确认建 + 确认覆盖），而第二次按回车会静默"什么都没改"。
    # 用户重做的原因通常正是"原来那个不对"，他第一屏按完 y 就以为结束了，
    # 第二屏顺手回车 → 旧图标原样留着 → 他回到桌面点一下还是坏的 →
    # 得出结论"这个修复功能没用"。两个 y 表达同一个意图，本身就是设计错误。
    $lnkName = [System.IO.Path]::GetFileNameWithoutExtension($chosen.TargetPath)
    $wouldBe = Join-Path $dest ($lnkName + $ProxyShortcutSuffix + '.lnk')
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
                           -DestinationDir $dest -Name $lnkName -Force:$willOverwrite
    Clear-Screen
    if ($r.Ok) {
        Write-Styled 'ok' ('  [完成] ' + $(if($willOverwrite){'已覆盖：'}else{'已创建：'}))
        Write-Styled 'dim' ('         ' + $r.Path)
        Write-Host ''
        Write-Styled 'text' '  原来的图标没动，两个可以同时用。'
        Write-Styled 'dim'  ('  启动脚本在：' + $r.LauncherPath)
        Write-Host ''
        Write-Styled 'dim'  '  想固定到任务栏：把这个新图标拖到任务栏就行。'
        Write-Styled 'dim'  '  注意别删掉上面那个启动脚本，删了图标就失效。'
        # 代理值不合法时要说一句：快捷方式本身建好了，只是它读不到能用的代理。
        # 不说的话用户点了图标发现没走代理，会以为这个功能坏了。
        if (-not $r.ProxyOk) {
            Write-Host ''
            Write-Styled 'warn' '  注意：现在没有检测到有效的代理地址。'
            Write-Styled 'dim'  '  这个图标仍然能用，但启动时会直连。开好代理软件再点一次就正常了。'
        }
    } elseif ($r.Existed) {
        Write-Styled 'warn' '  [已有] 同名快捷方式已经存在：'
        Write-Styled 'dim'  ('         ' + $r.Path)
        Write-Host ''
        # 直接在这里给覆盖选项。让用户"去管理页删掉再回来重建"要走十来步
        # （返回、进管理、找编号、确认、退出、再选程序），中途按错就回起点；
        # 而重新生成同一个快捷方式只需要把同样的内容再写一遍。
        Write-Styled 'text' '  要用当前设置覆盖它吗？'
        Write-Styled 'dim'  '  输 y 回车覆盖，直接回车 = 保留原来的'
        $ov = ''
        try { $ov = "$(Read-Host '覆盖')".Trim() } catch {}
        if ($ov -match '^(y|yes|是)$') {
            $r2 = New-ProxyShortcut -TargetPath $chosen.TargetPath -WorkingDirectory $chosen.WorkingDirectory `
                                    -DestinationDir $dest -Name ([System.IO.Path]::GetFileNameWithoutExtension($chosen.TargetPath)) -Force
            Write-Host ''
            if ($r2.Ok) {
                Write-Styled 'ok' '  [完成] 已覆盖：'
                Write-Styled 'dim' ('         ' + $r2.Path)
            } else {
                Write-Styled 'warn' ('  [失败] 没能覆盖：' + $r2.Reason)
            }
        } else {
            Write-Host ''
            Write-Styled 'dim' '  保留原来的，什么都没改。'
        }
    } else {
        Write-Styled 'warn' '  [失败] 没能创建：'
        Write-Styled 'dim'  ('         ' + $r.Reason)
    }
    Write-Host ''
    try { $null = Read-Host '  按回车返回' } catch {}
}

# 管理页：列出所有我们建的快捷方式，可以逐个删。
# 按程序分组显示：同一个程序的图标和启动脚本是配套的，分开列会让人以为它们无关。
function Invoke-ManageProxyShortcuts {
    while ($true) {
        $recs = @(Get-ProxyShortcutRecords)
        $orphans = @(Get-OrphanProxyLaunchers)
        Clear-Screen
        Write-Styled 'title' '======== 管理走代理的快捷方式 ========'
        Write-Host ''
        if ($recs.Count -eq 0 -and $orphans.Count -eq 0) {
            Write-Styled 'dim' '  还没有建过。先回上一页选 1 建一个。'
            Write-Host ''
            Write-Styled 'dim' '  按回车返回'
            try { $null = Read-Host '' } catch {}
            return
        }
        $idx = 0
        if ($recs.Count -gt 0) {
            foreach ($r in $recs) {
                $idx++
                $stateText = switch ($r.State) {
                    'ok'           { '正常' }
                    'no-launcher'  { '启动脚本被删了，图标点了会失败' }
                    'broken-target' { '程序已经不在了（被卸载或搬走），图标点了会失败' }
                    default        { $r.State }
                }
                $stateRole = if ($r.State -eq 'ok') { 'ok' } else { 'warn' }
                # 名字后面跟位置：同一个程序可以同时出现在桌面和任务栏
                # （固定到任务栏时 Windows 会复制一份），不带位置的话两行内容一模一样。
                # 名字本身可能已经带括号（''Antigravity（走代理）''），后面再接一个''（桌面）''
                # 连成三个括号读着别扭。中间加分隔点，两段身份各自清楚。
                Write-Styled 'item' ('    ' + $idx.ToString().PadLeft(2) + '  ' + $r.Name + '  ·  ' + $r.Where)
                Write-Styled $stateRole ('        状态  ' + $stateText)
                # 完整路径 + 位置都写出来。路径长到折行也照写：
                # 截短了用户就没法照着去找、也没法复制，而这一屏的作用正是"我要删哪一个"。
                # 折行自己来（续行对齐到值那一列）：交给终端折的话续行从第 0 列开始，
                # 那半截路径看起来像另一个条目的内容，反而更容易认错行。
                # 续行缩进 14 = "        图标  " 的可见宽度（8 空格 + 图标两字 + 2 空格）。
                $wrapW = (Get-ConsoleWidth) - 16
                $lnkLines = @(Split-DisplayText $r.LnkPath $wrapW 14)
                for ($k = 0; $k -lt $lnkLines.Count; $k++) {
                    if ($k -eq 0) { Write-Styled 'dim' ('        图标  ' + $lnkLines[$k].TrimStart()) }
                    else { Write-Styled 'dim' $lnkLines[$k] }
                }
                # 启动脚本被多个图标共用时说清楚：删掉这条不会弄坏别人。
                $shareCount = @($recs | Where-Object { $_.LauncherPath -eq $r.LauncherPath }).Count
                $shareNote = if ($shareCount -gt 1) { ('（' + $shareCount + ' 个图标共用）') } else { '' }
                $vbsLines = @(Split-DisplayText ($r.LauncherPath + $shareNote) $wrapW 14)
                for ($k = 0; $k -lt $vbsLines.Count; $k++) {
                    if ($k -eq 0) { Write-Styled 'dim' ('        脚本  ' + $vbsLines[$k].TrimStart()) }
                    else { Write-Styled 'dim' $vbsLines[$k] }
                }
            }
        }
        if ($orphans.Count -gt 0) {
            Write-Host ''
            # 这一段的意思是"还有启动脚本，但它的图标我找不到"。
            # 用户完全可能把图标挪到别处（自己建的文件夹、移动硬盘），那不算错，
            # 所以措辞不能写成"图标已经被删了"——那会让他以为自己弄坏了什么。
            Write-Styled 'heading' '  这些启动脚本没有对应的图标'
            Write-Styled 'dim' '  （图标可能被你挪到别处了，也可能删掉了）'
            foreach ($o in $orphans) {
                $idx++
                Write-Styled 'item' ('    ' + $idx.ToString().PadLeft(2) + '  ' + $o.Name)
                if ($o.Target) {
                    Write-Styled 'dim' ('        程序  ' + $o.Target)
                } else {
                    Write-Styled 'dim' '        程序  （这个脚本没记下是哪个程序，可能是旧版本建的）'
                }
                Write-Styled 'dim'  ('        脚本  ' + $o.LauncherPath)
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
        $n = 0
        if (-not [int]::TryParse($ans, [ref]$n) -or $n -lt 1 -or $n -gt $idx) {
            Write-Styled 'warn' ('  没有这个编号：' + $ans + '（可用的有 1-' + $idx + '）')
            Start-Sleep -Milliseconds 700
            continue
        }
        # 定位到具体那一条
        $targetLnk = $null
        $targetVbs = $null
        if ($n -le $recs.Count) {
            $targetLnk = $recs[$n-1].LnkPath
            $targetVbs = $recs[$n-1].LauncherPath
        } else {
            $targetVbs = $orphans[$n - $recs.Count - 1].LauncherPath
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

# 高级功能的总入口：菜单选 7 进来就是这里。
function Show-AdvancedMenu {
    while ($true) {
        Show-AdvancedPage
        $ans = ''
        try { $ans = "$(Read-Host '选择')".Trim() } catch { return }
        if (-not $ans -or $ans -eq '0' -or $ans -match '^[Qq]$') { return }
        switch ($ans) {
            '1' { Invoke-NewProxyShortcutFlow }
            '2' { Invoke-ManageProxyShortcuts }
            default {
                Write-Styled 'warn' ('  没有这个编号：' + $ans + '（可用的有 1、2，0 = 返回）')
                Start-Sleep -Milliseconds 700
            }
        }
    }
}
