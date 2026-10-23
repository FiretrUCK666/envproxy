# ==============================================================================
#  runtime.ps1 — 运行时层：日志、监控进程管理、监控主循环、自启动与定位器
#  路径常量依赖入口先设好的 $ScriptDir 与 $ScriptPath；本层不得自行推算脚本目录或入口路径。
# ==============================================================================

# ------------------------------------------------------------------------------
# 3. 自启动（固定位置定位器架构，不需要管理员）
# ------------------------------------------------------------------------------
# 架构：Run 键 → 定位器（%LOCALAPPDATA%\EnvProxy\launcher.ps1，固定位置永不移动）
#               → 读注册表里的"脚本当前路径"记录 → 启动监控
#       文件夹被移动后，定位器发现记录失效 → 自动搜索新位置 → 更新记录 → 启动。
#       因此：移动文件夹后什么都不用点，下次开机自动完成重新定位。
$RunKeyPath       = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$RunKeyName       = "EnvProxyMonitor"
$ScriptPathRegKey = "HKCU:\Software\EnvProxy"
# 用户原值快照：安装时记下被覆盖前的用户级代理变量，卸载时按快照还原。
# 与 $ScriptPathRegKey 父子关系——卸载清注册表键时连同删掉，不留痕迹。
$PrevEnvRegKey   = "HKCU:\Software\EnvProxy\Backup"
# 我们写下的值（变量名 -> 值），终端同步的钩子据此判断"当前值是不是我们的"。
# 与 Mac 侧 ~/.envproxy/owned.env 同义：不存在就说明不是我们写的，一个都不许删。
$OwnedRegKey     = "HKCU:\Software\EnvProxy\Owned"
# 顶层取值必须加载期安全：CI 自检会在 Linux 上点源本文件测纯函数，
# 那里没有 LOCALAPPDATA。运行时只在 Windows 走，兜底值走不到业务逻辑。
$_localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [System.IO.Path]::GetTempPath() }
$LauncherDir      = Join-Path $_localAppData "EnvProxy"
$LauncherPath     = Join-Path $LauncherDir "launcher.ps1"

# 登录定位器的正文住在 win\locator.ps1 这个**真实文件**里，不再内嵌成字符串。
#
# 为什么必须是真实文件而不是内嵌字符串（here-string）：字符串里的代码对解析器不可见，
# 门禁 2（语法检查）与门禁 3（编码红线）都看不见它，测试也只验证"启动命令指向这个文件"。
# 实测在那种字符串里删掉一个右花括号：门禁 2 仍然绿、单元测试仍然 ALL PASS、
# 自愈判据仍然报"已是最新"——错误会一路绿灯发到用户机器上，表现为"开机自启静默失效"，
# 而且不报任何错。是真实文件，门禁 1/2/3/9 就自动覆盖它，改坏了当场就红。
#
# 返回模板正文；模板缺失时抛错而不是返回空串——写一份空定位器等于把开机自启静默关掉。
function Get-LauncherContent {
    $src = Join-Path $ScriptDir "locator.ps1"
    if (-not (Test-Item $src)) {
        throw ("找不到登录定位器模板：{0}（安装包不完整，请重新下载覆盖）" -f $src)
    }
    # 必须剥掉源文件的 BOM。Read-Text 是用 UTF8 解码的，它**不会**自动去掉 BOM，
    # 而写入端（WriteAllText 带 UTF8Encoding($true)）会再加一个——
    # 结果装出来的 launcher.ps1 是 EF BB BF EF BB BF 开头，PowerShell 只剥一个，
    # 剩下的 U+FEFF 跟行首的 # 拼成一个"命令名"，5.1 直接报
    # The term '# ' is not recognized，开机自启静默失效。
    $body = (Read-Text $src)
    if ($body.Length -gt 0 -and $body[0] -eq [char]0xFEFF) { $body = $body.Substring(1) }
    return $body
}

# 把定位器写到固定位置，并把 Run 键指向定位器
function Get-LauncherCommand {
    # 定位器命令行是同一事实的三处用法（写入、自愈比对、安装后复检）的唯一来源。
    return ('powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $LauncherPath)
}

function Set-AutoRun {
    New-Item -Path $LauncherDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    [System.IO.File]::WriteAllText($LauncherPath, (Get-LauncherContent), (New-Object System.Text.UTF8Encoding($true)))
    Set-ItemProperty -Path $RunKeyPath -Name $RunKeyName -Value (Get-LauncherCommand) -ErrorAction Stop
}

function Remove-AutoRun {
    Remove-ItemProperty -Path $RunKeyPath -Name $RunKeyName -ErrorAction SilentlyContinue
}

# 记录"脚本当前路径"（监控启动时写入；定位器靠它快速找到脚本）
# 记的必须是入口脚本：定位器会直接拿这个值去 -File 启动，记成库文件等于记了个跑不起来的文件。
function Update-ScriptPathRecord {
    # 只在键不存在时才建。注册表上的 New-Item -Force 会把这个键**清空重建**，
    # 连带删掉 Backup 快照——监控每次启动都调本函数，快照会在装上后一两秒内就没了，
    # 卸载时便无值可还原，使用者手设的代理配置凭空消失。
    if (-not (Test-RegKey $ScriptPathRegKey)) {
        New-Item -Path $ScriptPathRegKey -Force -ErrorAction SilentlyContinue | Out-Null
    }
    Set-ItemProperty -Path $ScriptPathRegKey -Name "ScriptPath" -Value $ScriptPath -ErrorAction SilentlyContinue
}

# 自启动自愈：让固定位置的自启动配置**与当前代码生成的内容一致**——不只是"存在"。
# 判据是内容而非存在，理由是升级路径：改完脚本若没走"安装"，固定位置里留着的仍是
# 旧定位器（搜索算法、参数改了都不生效），旧的 Run 值也可能指向被删掉的路径。
# 每次自查 = 让系统状态收敛到当前代码，不依赖用户记得重装。
function Test-LauncherCurrent {
    try {
        if (-not (Test-Item $LauncherPath)) { return $false }
        # BOM 必须单独校验：Read-Text 会自动识别并剥掉 BOM，所以文本一致并不能证明
        # BOM 还在。BOM 一丢（外部编辑器另存、杀软改文件、备份还原工具），
        # PowerShell 5.1 会按 ANSI 读这个文件，中文注释撑破语法 -> 登录时启动项
        # 静默失效，而「内容比对」却说一切正常。三字节单独断言一次。
        $bytes = [System.IO.File]::ReadAllBytes($LauncherPath)
        if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) { return $false }
        # 行尾与首尾空白不比：落盘的行尾与 win/locator.ps1 源码的行尾
        # 不必逐字节相同，比"生成出来的代码"是否一致就够了。
        $want = (Get-LauncherContent) -replace "`r`n", "`n"
        $have = (Read-Text $LauncherPath) -replace "`r`n", "`n"
        return ($have.Trim() -eq $want.Trim())
    } catch { return $false }
}

# 版本号缓存：监控每 30 轮（约 60–90 秒）刷新一次，状态页只读。
#
# 为什么要缓存：状态页原来自己调 Get-RemoteVersion，那是真实网络请求（先 API 后 Web，
# 各 8 秒超时，限流时还会换出口重试）。离线、限流、走白名单网络的人，每次点"查看状态"
# 都在等一个注定失败的请求——而用户对"点一下要等 10 秒"的归因通常是"这工具很慢"。
# 写缓存的是监控（它本来就写文件），状态显示"永不写文件、永不提问"这条契约一个字不动：
# **写的人换了，不是多了一个**。
#
# 格式两行：版本号、写入时刻（ISO 8601）。带时间戳是因为陈旧数据必须能被认出——
# 只报"已是最新"而不知道这个结论有多旧，比不报更糟。
function Write-VersionCache {
    $r = Get-RemoteVersion
    if (-not $r) { return }   # 查不到就保持上次的值，不写「未知」把好数据冲掉
    $dir = Split-Path -Parent $VersionCacheFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
    $stamp = (Get-Date).ToString("o", [System.Globalization.CultureInfo]::InvariantCulture)
    try { Write-Text -Path $VersionCacheFile -Text ($r.Version + "`n" + $stamp + "`n") } catch {}
}

# 读版本缓存。没有或读不出来返回 $null（调用方据此说"还没查过"）。
function Read-VersionCache {
    if (-not (Test-Item $VersionCacheFile)) { return $null }
    try {
        $lines = [System.IO.File]::ReadAllLines($VersionCacheFile, [System.Text.Encoding]::UTF8)
        if ($lines.Count -lt 2) { return $null }
        $ver = $lines[0].Trim()
        if (-not $ver) { return $null }
        $at = [datetime]::MinValue
        try { $at = [datetime]::Parse($lines[1].Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch {}
        return @{ Version = $ver; At = $at; AgeMinutes = [int]((Get-Date) - $at).TotalMinutes }
    } catch { return $null }
}

function Repair-AutoRun {
    try {
        $expected = Get-LauncherCommand
        $actual = (Get-ItemProperty $RunKeyPath -ErrorAction SilentlyContinue).$RunKeyName
        if ((-not (Test-LauncherCurrent)) -or $actual -ne $expected) {
            New-Item -Path $LauncherDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
            [System.IO.File]::WriteAllText($LauncherPath, (Get-LauncherContent), (New-Object System.Text.UTF8Encoding($true)))
            Set-ItemProperty -Path $RunKeyPath -Name $RunKeyName -Value $expected -ErrorAction Stop
            # 写完必须读回：修没修成由复读决定，不由"我调用了写入"决定。
            $check = (Get-ItemProperty $RunKeyPath -ErrorAction Stop).$RunKeyName
            if (($check -eq $expected) -and (Test-LauncherCurrent)) {
                Write-MonitorLog "已自动修复开机自启动（定位器/自启动项缺失、损坏或与当前版本不一致）"
            } else {
                Write-MonitorLog "开机自启动修复失败：写入后读回不一致"
            }
        }
    } catch {
        try { Write-MonitorLog ("开机自启动修复失败：" + $_.Exception.Message) } catch {}
    }
}

# ------------------------------------------------------------------------------
# 3b. PowerShell 配置文件的终端同步（对应 Mac 侧的 shell hook）
# ------------------------------------------------------------------------------
# DIVERGE(Win): 机制与 Mac 侧必然不同，三处：
#   1) 挂载点——PowerShell 没有 precmd/PROMPT_COMMAND 那种官方钩子，只能改写 $PROFILE
#      并**包住 prompt 函数**；Mac 是在 rc 文件里 source 一个脚本、注册 precmd 钩子。
#   2) 状态来源——本侧每次回到提示符实时查注册表（HKCU\Environment 与
#      Software\EnvProxy\Owned）；Mac 侧读的是 ~/.envproxy/proxy.env 与 owned.env 两个文件。
#   3) 落点数量——本侧写 5.1 与 7 两个版本的 profile；Mac 写 4 个 rc（.zshenv/.zshrc/
#      存在的 .bash_profile/.bashrc）。
#   共同点（行为契约，两侧必须一致）：只对安装之后新启动的 shell 生效；只清"值仍等于
#   我们写下的那个"；钩子永不输出、永不打断用户的提示符。
# 为什么需要：环境变量只在进程启动那一刻从父进程复制，已经开着的 PowerShell 窗口
#   拿不到新值（WM_SETTINGCHANGE 广播对已运行的控制台进程无效）。唯一可靠的时机是
#   "每次回到提示符、准备执行下一条命令之前"——也就是 prompt 函数被调用时。
#
# 为什么挂 $PROFILE 而不是每次自己开窗口：
#   $PROFILE（CurrentUserCurrentHost）在四个变体里**最后执行**，能包住前面所有模块
#   （Oh My Posh / posh-git）定义的 prompt；且只需当前用户权限。绝不硬编码 Documents
#   路径——OneDrive 重定向会让它变，必须现场向 PowerShell 要。
#
# 三条硬约束（都在自检里钉住）：
#   1) prompt 里一旦抛异常，整个提示符渲染失败（官方文档：默认 prompt 只在自定义
#      prompt 出错时才出现）。所以同步逻辑必须整体 try/catch 包死。
#   2) 只写 5 个大写拼写。Windows 变量名大小写不敏感，补小写会制造跨进程重名
#      （.NET 宿主建表报 "same key has already been added"），这是项目已确立的红线。
#   3) 删除用 [NullString]::Value：.NET 9 起 $null 不再等于删除，会留一个空值变量。
#      本机 5.1 上两者等价，但代码要跨版本正确。
$ProfileBlockStart = '# >>> EnvProxy >>>'
$ProfileBlockEnd   = '# <<< EnvProxy <<<'

# 我们要同步的变量（与 $ProxyVarNames 同源，不另立一份清单）。
function Get-ProfileBlockLines {
    # 这段代码要做两件事：
    #   1) 立刻同步一次（新开窗口马上拿到当前状态，不必等第一次回车）；
    #   2) 包住 prompt 函数，让**每次回到提示符**都再同步一次——这才让"已经开着的窗口
    #      敲回车就跟着变"成立。只做第 1 件的话，敲回车不会触发任何东西，
    #      那一句承诺就是假的（Windows 没有 precmd 那种自动钩子，必须自己包 prompt）。
    #
    # 写进使用者文件的那几行**必须是纯 ASCII**：我们不知道那个文件是什么编码
    # （Get-TextFileEncoding 会沿用原文件；新建的通常是无 BOM 的 UTF-8）。
    # 中文注释放进无 BOM 文件后，PowerShell 5.1 按 ANSI 读，全变乱码。
    # 乱码只是注释、不影响功能，但使用者的配置文件里出现一堆看不懂的方块，
    # 会让人以为装坏了。而替使用者改文件编码比乱码更糟。所以：这段说英文。
    #
    # 包 prompt 的三条约束：
    #   a) 必须记住原函数并原样调用，否则 Oh My Posh / Starship / 自定义提示符全被顶掉；
    #   b) 同步逻辑整体 try/catch 包死——prompt 里抛异常会让整个提示符渲染失败；
    #   c) 不能重复包装（重复 source 会把 prompt 包成洋葱），用哨兵变量挡住。
    $names = ($ProxyVarNames | ForEach-Object { "'$_'" }) -join ', '
    $body = @(
        $ProfileBlockStart
        '# EnvProxy: keeps already-open windows in sync with the proxy state.',
        '# Written by the installer; removed as a whole on uninstall.',
        '# Take over in one window: $env:ENVPROXY_TERM = "off" to go direct,',
        '# Remove-Item Env:ENVPROXY_TERM to go back to automatic.',
        'try {',
        ("    `$__epNames = @(" + $names + ")"),
        '    $__epSync = {',
        '        try {',
        '            $__epReg = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $false)',
        '            $__epOwn = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\EnvProxy\Owned", $false)',
        '            if ($null -ne $__epReg) {',
        '                if ($env:ENVPROXY_TERM -eq "off") {',
        '                    # Direct mode: clear only values we actually wrote.',
        '                    # Anything the user set themselves stays untouched.',
        '                    foreach ($__epN in $__epNames) {',
        '                        $__epCur = [Environment]::GetEnvironmentVariable($__epN, "Process")',
        '                        $__epOurs = if ($null -ne $__epOwn) { $__epOwn.GetValue($__epN, $null) } else { $null }',
        '                        if (($null -ne $__epOurs) -and ($__epCur -eq [string]$__epOurs)) {',
        '                            [Environment]::SetEnvironmentVariable($__epN, [NullString]::Value, "Process")',
        '                        }',
        '                    }',
        '                } else {',
        '                    # Auto mode: inject what the registry holds. When it holds',
        '                    # nothing, clear only our own values (ownership record matches).',
        '                    foreach ($__epN in $__epNames) {',
        '                        $__epVal = $__epReg.GetValue($__epN, $null)',
        '                        $__epCur = [Environment]::GetEnvironmentVariable($__epN, "Process")',
        '                        $__epOurs = if ($null -ne $__epOwn) { $__epOwn.GetValue($__epN, $null) } else { $null }',
        '                        if ($null -ne $__epVal) {',
        '                            [Environment]::SetEnvironmentVariable($__epN, [string]$__epVal, "Process")',
        '                        } elseif ($null -ne $__epOurs) {',
        '                            if ($__epCur -eq [string]$__epOurs) {',
        '                                [Environment]::SetEnvironmentVariable($__epN, [NullString]::Value, "Process")',
        '                            }',
        '                            continue',
        '                        } else {',
        '                            # No ownership record (an older install that was',
        '                            # upgraded never wrote one). Clear NOTHING here:',
        '                            # without a record there is no test, and guessing',
        '                            # always deletes the wrong one. A mitmproxy the user',
        '                            # started on any port looks exactly like ours.',
        '                            # Better to leave a stale value (the next on',
        '                            # overwrites it) than to delete their own config.',
        '                            continue',
        '                        }',
        '                    }',
        '                }',
        '                $__epReg.Close()',
        '            }',
        '            if ($null -ne $__epOwn) { $__epOwn.Close() }',
        '        } catch { }',
        '    }',
        '    & $__epSync',
        '    $global:__EnvProxySyncQuiet = $__epSync',
        '    if ((-not $global:__EnvProxyPromptWrapped) -and $Host.Name -ne "ServerRemoteHost" -and [Environment]::UserInteractive) {',
        '        $global:__EnvProxyPromptWrapped = $true',
        '        $global:__EnvProxyPrevPrompt = $function:prompt',
        '        function global:prompt {',
        '            if ($null -ne $global:__EnvProxyPrevPrompt) {',
        '                $__epTxt = (& $global:__EnvProxyPrevPrompt)',
        '                try { & $global:__EnvProxySyncQuiet } catch { }',
        '                return $__epTxt',
        '            }',
        '            $__epLoc = $executionContext.SessionState.Path.CurrentLocation',
        '            try { & $global:__EnvProxySyncQuiet } catch { }',
        '            return ("PS " + $__epLoc + "> ")',
        '        }',
        '    }',
        '} catch { }',
        $ProfileBlockEnd
    )
    return $body
}

# 成对护栏：起止标记都在、且开始行在结束行之前。缺一侧或顺序错乱就一个字节都不改。
# 探测一个已存在文件的编码，按同样的编码读回它的行。
# 为什么必须这样读：用户 profile 可能是 GBK（中文系统记事本默认）、UTF-16 或带 BOM。
# 一律按 UTF-8 读会把 GBK 的中文读成乱码，于是"我们的块在不在、内容对不对"全部判错——
# 安装报 verify-failed、卸载认不出自己的块。写回与读回必须用同一套编码判断。
function Get-TextFileEncoding([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return (New-Object System.Text.UTF8Encoding($false)) }
    try {
        $b = [System.IO.File]::ReadAllBytes($Path)
        if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return (New-Object System.Text.UTF8Encoding($true)) }
        if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return (New-Object System.Text.UnicodeEncoding($false, $true)) }
        if ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { return (New-Object System.Text.UnicodeEncoding($true, $true)) }
        # 无 BOM：严格 UTF-8 能解就是 UTF-8，否则按 ANSI 处理。
        # 不能用 Encoding::Default——它在 .NET Framework 上是 ANSI、在 .NET Core 上是 UTF-8。
        try {
            $strict = New-Object System.Text.UTF8Encoding($false, $true)
            [void]$strict.GetString($b)
        } catch {
            # 不是 UTF-8，就是某个 ANSI 代码页。这里不能只用 CurrentCulture 的 ANSICodePage：
            # 那个值是"当前系统"的代码页（英文 Windows 与 CI 的 Linux 都是 1252），
            # 而文件可能是中文系统写的 936。用 1252 去解 936 的字节，中文变乱码，
            # 于是"我们的块在不在"判错、安装报 verify-failed。
            #
            # 顺序很关键：多字节代码页在前，单字节兜底在后。
            # 单字节编码（1252 这类）把任意字节都映到一个字符，往返永远"一致"——
            # 先试它就会把 936 的中文解成一堆怪符号还自认为成功，探不出来。
            # 所以只有多字节代码页都解不干净时，才退回单字节。
            $multibyte = @(936, 950, 932, 949, 51932, 20932)
            $singlebyte = @()
            try { $singlebyte += [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage } catch {}
            $singlebyte += @(1252, 1251, 850)
            foreach ($cp in ($multibyte + $singlebyte)) {
                if (-not $cp) { continue }
                try {
                    $e = [System.Text.Encoding]::GetEncoding([int]$cp)
                    $s = $e.GetString($b)
                    # 往返一致才算"这个代码页能正确解释这段字节"。
                    $back = $e.GetBytes($s)
                    if (($back -join ',') -eq ($b -join ',')) { return $e }
                } catch {}
            }
        }
    } catch {}
    return (New-Object System.Text.UTF8Encoding($false))
}

function Read-ProfileLines([string]$Path) {
    $enc = Get-TextFileEncoding $Path
    try {
        $text = $enc.GetString([System.IO.File]::ReadAllBytes($Path))
        # 必须剥掉开头的 BOM 字符（U+FEFF）：Encoding::GetString 会把它当成正文的一部分。
        # 不剥这一下，读出来的第一行带着 BOM，写回时编码器再加一个 BOM，
        # 于是每装一次/卸一次就多叠一层 —— 实测装一次卸一次后 BOM 从 1 个变 3 个。
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
        return @($text -split "`r?`n")
    } catch { return @() }
}

# 标记是否在（大小写敏感、逐字节比较）。
# 全项目只用这一个判据：混用 -ceq 与 -contains 会让"装"与"卸"得出相反结论——
# 标记大小写被改过时，安装报 verify-failed、卸载报 unpaired，用户从此既装不上也卸不掉。
# 与 Mac 侧 grep -qxF（字节比较）同口径。
# "我们的标记行在不在这份文件里"——**全项目唯一的判据**。
#
# 为什么必须容忍首尾空白：编辑器保存、手工编辑、Markdown 工具补空格，都会让标记行
# 末尾多一个空格。而"标记在不在"被用在五处：安装前判有没有块、判成对、状态页判
# missing/unpaired、修复入口判要不要修、卸载时判要不要摘。这些地方原来各写一份比较，
# 严格度还不一样（有的整行 -ceq、有的 .Trim() -ceq），于是同一个文件能给出三种结论：
# 状态页说"没有同步块"、安装说"标记不成对"、修复入口说"没有需要修的"——而修复入口
# 存在的唯一理由就是把"不成对"这个死状态救回来。它看不见，那条路就是死的。
# 实测复现过：开始标记末尾一个空格，四处的结论分别是 False / False / missing / Fixed 0。
#
# 判据本身只认"去掉首尾空白后逐字节相等"：标记是我们自己写的固定字符串，
# 大小写敏感是对的（-ceq 保留），但首尾空白不该影响"它是不是那一行"。
function Test-MarkerPresent([string[]]$Lines, [string]$Marker) {
    $want = $Marker.Trim()
    foreach ($l in $Lines) { if ($l.Trim() -ceq $want) { return $true } }
    return $false
}

function Test-ProfileBlockPaired([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $lines = @(Read-ProfileLines $Path)
    # 与 Test-MarkerPresent 同一判据（去首尾空白后逐字节比）：同一个概念不准有两套严格度。
    $bs = $ProfileBlockStart.Trim()
    $be = $ProfileBlockEnd.Trim()
    $s = -1; $e = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $t = $lines[$i].Trim()
        if ($t -ceq $bs -and $s -lt 0) { $s = $i }
        if ($t -ceq $be -and $e -lt 0) { $e = $i }
    }
    return (($s -ge 0) -and ($e -gt $s))
}

# 读回比对：块内容与当前版本是否一致（升级后不一致要重写）。
function Test-ProfileBlockCurrent([string]$Path) {
    if (-not (Test-ProfileBlockPaired $Path)) { return $false }
    $lines = @(Read-ProfileLines $Path)
    $s = -1; $e = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -ceq $ProfileBlockStart.Trim() -and $s -lt 0) { $s = $i }
        if ($lines[$i].Trim() -ceq $ProfileBlockEnd.Trim() -and $e -lt 0) { $e = $i }
    }
    if ($s -lt 0 -or $e -le $s) { return $false }
    $have = @($lines[$s..$e])
    $want = @(Get-ProfileBlockLines)
    if ($have.Count -ne $want.Count) { return $false }
    for ($i = 0; $i -lt $want.Count; $i++) {
        if ($have[$i] -cne $want[$i]) { return $false }
    }
    return $true
}

# 原子写回：先写同目录临时文件再整体替换，任何一步失败原文件一个字节不动。
# 这在用户的配置文件上尤其重要——留下半截的 profile，一开 PowerShell 就报错。
function Write-TextAtomic([string]$Path, [string[]]$Lines) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    $tmp = Join-Path $dir (".envproxy-profile." + $PID + ".tmp")
    try {
        # 编码：沿用原文件的编码与 BOM 状态，绝不"统一成 UTF-8 无 BOM"。
        # 这是用户自己长期维护的文件——它可能是 GBK（中文系统的记事本默认），
        # 也可能带 BOM。按固定编码写回会把用户原有的中文全部写成乱码且无法恢复。
        # 文件不存在时（首次创建）才用 UTF-8 无 BOM。
        #
        # 探测只认 Get-TextFileEncoding 这一处：写回与读回必须是同一套判据。
        # 各自实现一套的结果就是"写进去用 A 编码、读回来用 B 编码"——
        # 中文变问号、复检必然 verify-failed，而且症状看起来像"安装坏了"。
        $enc = Get-TextFileEncoding $Path
        $hasBom = $false
        if (Test-Path -LiteralPath $Path) {
            try {
                $old = [System.IO.File]::ReadAllBytes($Path)
                $hasBom = ($old.Length -ge 3 -and $old[0] -eq 0xEF -and $old[1] -eq 0xBB -and $old[2] -eq 0xBF)
            } catch {}
        }
        # 行尾沿用原文件：WriteAllLines 固定用 Environment.NewLine，会把 LF 的 profile
        # 静默改成 CRLF（Windows 上）或把 CRLF 改成 LF（Linux 上）——两种都污染用户的
        # diff 和行尾约定。所以要探测原文件自己的行尾，而不是跟着运行平台走。
        # 判断必须**先按已探测到的编码解码再找换行**，不能直接扫原始字节：
        # UTF-16 里每个字符占两字节，字节序列中的 13/10 各自独立出现，按字节扫会误判成 LF。
        # 只有文件不存在（首次创建）时才用平台默认。
        $nl = [Environment]::NewLine
        if (Test-Path -LiteralPath $Path) {
            try {
                $probe = $enc.GetString([System.IO.File]::ReadAllBytes($Path))
                if ($probe.IndexOf("`n") -ge 0) {
                    # 出现 CRLF 就按 CRLF；全是裸 LF 才按 LF。两者都有时按 CRLF 保持现状。
                    if ($probe.IndexOf("`r`n") -ge 0) { $nl = "`r`n" }
                    elseif ([regex]::IsMatch($probe, "(?<!`r)`n")) { $nl = "`n" }
                }
            } catch {}
        }
        $text = ($Lines -join $nl)
        if ($Lines.Count -gt 0) { $text += $nl }
        [System.IO.File]::WriteAllText($tmp, $text, $enc)
        if (Test-Path -LiteralPath $Path) {
            # 备份只在**第一次**写之前留下：它代表「装之前长什么样」，那才是能还原回去的东西。
            # 每次写都覆盖的话，装第二次时 .bak 里已经是带我们那一块的版本，
            # 使用者的原始内容在装+卸一轮之后就没了——README 承诺的「改坏了还能还原」落空。
            $bak = $Path + ".envproxy.bak"
            if (-not (Test-Path -LiteralPath $bak)) {
                try { Copy-Item -LiteralPath $Path -Destination $bak -Force -ErrorAction SilentlyContinue } catch {}
            }
            Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
        } else {
            # 原本没有这个文件：留一张显式字条，卸载时据此判断「该删文件」而不是「该还原内容」。
            # 否则「原来不存在」与「原来是空文件」分不开，而 0 字节的 .bak 看着像备份、其实什么都还原不了。
            $bak = $Path + ".envproxy.bak"
            if (-not (Test-Path -LiteralPath $bak)) {
                try { [System.IO.File]::WriteAllText($bak, "# envproxy: 本文件在安装前不存在（卸载时应删除，不要还原内容）`n", (New-Object System.Text.UTF8Encoding($false))) } catch {}
            }
            Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
        }
        return $true
    } catch {
        try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch {}
        return $false
    }
}

# 需要覆盖的所有 profile 路径。
# 为什么不是一个：Windows PowerShell 5.1 与 PowerShell 7 的 $PROFILE 是**两个不同文件**
#   （Documents\WindowsPowerShell\... 与 Documents\PowerShell\...）。
# 本程序是被 powershell.exe(5.1) 启动的，只看当前 $PROFILE 就只会写 5.1 那个；
# 日常用 pwsh 7 的人永远拿不到终端同步，而且没有任何报错——静默不兑现承诺。
# 所以两边都写。路径现场从各自宿主问，不硬编码 Documents（OneDrive 重定向会让它变）。
# 终端同步到底有没有在生效——给状态页用。
# 光看「块写进去了」不算数：执行策略拦着、块不成对，都能让
#「看起来装好了，实则每次开窗口都不同步」。
function Get-TerminalSyncState {
    $paths = @()
    try { $paths = @(Get-ProfilePaths) } catch {}
    if ($paths.Count -eq 0) { return @{ State = 'nohost'; Detail = '取不到配置文件路径' } }
    $unpaired = 0
    $current = 0
    # 记下第一处"孤立标记"的位置（文件:行），状态页据此告诉用户"删哪一行"。
    # 只说"标记不成对"等于让用户自己去几千行的 profile 里找；而重跑安装同样会被
    # 这条护栏拒绝（"安全起见一个字节都没动"），所以只报现象等于给了个死路。
    $badPath = ''
    $badLine = 0
    foreach ($p in $paths) {
        if (-not (Test-Item $p)) { continue }
        # Git Bash 的块用 bash 语法，判据也必须是它自己那套：
        # 拿 PowerShell 的标记去比永远不成对，会让状态页把「已经装好」误报成「没有同步块」。
        if (Test-IsBashrcPath $p) {
            $lines = @(Read-ProfileLines $p)
            $hs = -1; $he = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i].Trim() -ceq $BashBlockStart -and $hs -lt 0) { $hs = $i }
                if ($lines[$i].Trim() -ceq $BashBlockEnd -and $he -lt 0) { $he = $i }
            }
            if (($hs -ge 0) -ne ($he -ge 0)) {
                $unpaired++
                if (-not $badPath) {
                    $badPath = $p
                    $badLine = $(if ($hs -ge 0) { $hs + 1 } else { $he + 1 })
                }
                continue
            }
            if ($hs -ge 0 -and $he -gt $hs) {
                $have = @($lines[$hs..$he] | ForEach-Object { $_.Trim() })
                $want = @(Get-BashBlockLines | ForEach-Object { $_.Trim() })
                if (($have -join "`n") -eq ($want -join "`n")) { $current++ }
            }
            continue
        }
        # 先判「有没有我们的标记」，再判成对。两件事必须分开：
        # 用户自己的 profile（从没装过）里一个标记都没有，Test-ProfileBlockPaired 也返回 false，
        # 于是「从没装过」会被报成「标记不成对」——而后者会让用户被告知"重跑安装可修复"，
        # 他又不知道该删哪行。同一文件里的 Remove-OneShellProfile 就是先 Test-MarkerPresent
        # 再判成对，这里与它对齐（同一件事只准有一处判据）。
        if (-not (Test-MarkerPresent @(Read-ProfileLines $p) $ProfileBlockStart)) { continue }
        if (-not (Test-ProfileBlockPaired $p)) {
            $unpaired++
            if (-not $badPath) {
                # 找第一个出现的孤立标记行号（开始行或结束行，谁孤就是谁）。
                $pl = @(Read-ProfileLines $p)
                for ($k = 0; $k -lt $pl.Count; $k++) {
                    $t = $pl[$k].Trim()
                    if ($t -ceq $ProfileBlockStart -or $t -ceq $ProfileBlockEnd) { $badPath = $p; $badLine = $k + 1; break }
                }
            }
            continue
        }
        if (Test-ProfileBlockCurrent $p) { $current++ }
    }
    # 执行策略会拦掉整个 profile 文件，块再对也跑不起来。判定优先于块本身。
    $pol = ''
    try { $pol = Get-ProfileExecutionPolicyWarning } catch {}
    if ($pol) { return @{ State = 'blocked'; Detail = $pol } }
    if ($current -gt 0) { return @{ State = 'ok'; Detail = '' } }
    if ($unpaired -gt 0) { return @{ State = 'unpaired'; Detail = '配置文件里的标记不成对，未改动它'; Path = $badPath; Line = $badLine } }
    # 到这儿还有第三种情况：标记成对、但块内容与当前版本不一致（升级后没走"安装"、
    # 或者块被改过）。它既不是"没有块"也不是"不成对"——报成 missing 会让用户以为
    # 从没装过，而去点"安装"（能修好，但屏幕先给了一个错的事实）。
    # 判据与安装侧同一件事：Test-ProfileBlockCurrent 不成立就是过期。
    $stale = 0
    foreach ($p in $paths) {
        if (-not (Test-Item $p)) { continue }
        if (-not (Test-MarkerPresent @(Read-ProfileLines $p) $ProfileBlockStart)) { continue }
        if (Test-ProfileBlockPaired $p) { $stale++ }
    }
    if ($stale -gt 0) { return @{ State = 'stale'; Detail = '同步块是旧版本的，没自动改' } }
    return @{ State = 'missing'; Detail = '配置文件里没有同步块' }
}

# 显式修复"标记不成对"的 profile：先备份整份，再摘掉**孤立**的标记行，最后读回复检。
#
# 为什么需要它：安装/卸载遇到不成对的标记一律"一个字节都不改"（这是对的——猜必错），
# 但这让一个可诊断、可修复的状态变成不可达：用户照文档重跑安装，每次都被拒绝。
# 人一旦明确说出"我同意修"，就不该再被拒。所以给一个显式入口，
# 语义是"我确认这是半截标记，删掉它"，而不是"你猜一个"。
function Repair-ProfileMarkers {
    $paths = @()
    try { $paths = @(Get-ProfilePaths) } catch {}
    $fixed = @()
    $failed = @()
    foreach ($p in $paths) {
        if (-not (Test-Item $p)) { continue }
        if ($p -like "*.bashrc") {
            $bs = $BashBlockStart; $be = $BashBlockEnd
        } else {
            $bs = $ProfileBlockStart; $be = $ProfileBlockEnd
        }
        $lines = @(Read-ProfileLines $p)
        $hasS = $false; $hasE = $false
        foreach ($l in $lines) {
            if ($l.Trim() -ceq $bs) { $hasS = $true }
            if ($l.Trim() -ceq $be) { $hasE = $true }
        }
        # 只处理"确有标记但不成对"的文件；成对的与完全没装的都不碰。
        if ($hasS -eq $hasE) { continue }
        $keep = New-Object System.Collections.ArrayList
        foreach ($l in $lines) {
            $t = $l.Trim()
            # 只删孤立的标记行；块内其余内容（钩子行）一并留给下一次安装重写。
            if ($t -ceq $bs -and -not $hasE) { continue }
            if ($t -ceq $be -and -not $hasS) { continue }
            [void]$keep.Add($l)
        }
        # 先备份整份（与正常写入同一套 .envproxy.bak 命名，不另造一套）。
        try {
            $bak = $p + ".envproxy.bak"
            if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $p -Destination $bak -Force -ErrorAction SilentlyContinue }
        } catch {}
        if (-not (Write-TextAtomic -Path $p -Lines @($keep))) { $failed += $p; continue }
        # 读回复检：修没修成由复读决定，不由"我调用了写入"决定。
        $still = @(Read-ProfileLines $p)
        $stillS = $false; $stillE = $false
        foreach ($l in $still) {
            if ($l.Trim() -ceq $bs) { $stillS = $true }
            if ($l.Trim() -ceq $be) { $stillE = $true }
        }
        if ($stillS -or $stillE) { $failed += $p } else { $fixed += $p }
    }
    return @{ Fixed = $fixed; Failed = $failed }
}

function Get-ProfilePaths {
    # 自检可以设 $env:ENVPROXY_PROFILE_OVERRIDE（分号分隔）把落点改到沙箱，
    # 这样既能覆盖"多落点"这条逻辑，又不会碰用户真实的 profile。
    $ov = ""
    try { $ov = [string]$env:ENVPROXY_PROFILE_OVERRIDE } catch {}
    if (-not [string]::IsNullOrWhiteSpace($ov)) {
        return @($ov -split ';' | Where-Object { $_ })
    }
    $paths = New-Object System.Collections.ArrayList
    $docs = ""
    try { $docs = [Environment]::GetFolderPath('MyDocuments') } catch {}
    if ([string]::IsNullOrWhiteSpace($docs)) {
        try { $docs = Join-Path $env:USERPROFILE 'Documents' } catch {}
    }
    if (-not [string]::IsNullOrWhiteSpace($docs)) {
        # 5.1 的默认落点
        [void]$paths.Add((Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'))
        # 7+ 的默认落点
        [void]$paths.Add((Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1'))
    }
    # 当前宿主自己的 $PROFILE 一定要包含（它可能被用户改到别处）
    try {
        $cur = $PROFILE
        if (-not [string]::IsNullOrWhiteSpace($cur) -and -not ($paths -contains $cur)) { [void]$paths.Add($cur) }
    } catch {}
    # Git Bash 的 ~/.bashrc 也是一个落点：它靠提示符钩子重读状态镜像文件，
    # 与 PowerShell 侧同一套「只清我们写下的值」判据，但块内容与钩子行不同，
    # 由 Install-OneShellProfile 按路径分辨（见 Test-IsBashrcPath）。
    try {
        $home2 = [string]$env:USERPROFILE
        if (-not [string]::IsNullOrWhiteSpace($home2)) {
            $bashrc = Join-Path $home2 ".bashrc"
            if (-not ($paths -contains $bashrc)) { [void]$paths.Add($bashrc) }
        }
    } catch {}
    return @($paths | Where-Object { $_ })
}

# 某个落点是不是 Git Bash 的启动文件（决定那一块的内容与钩子行）。
function Test-IsBashrcPath([string]$Path) {
    if (-not $Path) { return $false }
    return ($Path -like "*.bashrc")
}

# 安装/修复：幂等。已经正确就零写入（不动用户的文件 mtime）。
# 多个 profile 逐个处理，任一失败要如实报告是哪一个。
function Install-ShellProfile {
    $all = @(Get-ProfilePaths)
    if ($all.Count -eq 0) { return @{ Ok = $false; Reason = 'no-profile'; Path = '' } }
    $touched = New-Object System.Collections.ArrayList
    $lastReason = 'current'
    $firstErr = $null
    foreach ($path in $all) {
        # 逐个独立处理，一个失败不影响其余：5.1 那个 profile 标记不成对，
        # 不该连带让 pwsh 7 的落点也不写——那会让"另一个版本拿不到同步"继续静默存在。
        $r = Install-OneShellProfile $path
        if (-not $r.Ok) { if ($null -eq $firstErr) { $firstErr = $r }; continue }
        if ($r.Reason -eq 'installed') { [void]$touched.Add($path); $lastReason = 'installed' }
    }
    if ($null -ne $firstErr) { return $firstErr }
    $shown = if ($touched.Count -gt 0) { ($touched -join '; ') } else { ($all -join '; ') }
    return @{ Ok = $true; Reason = $lastReason; Path = $shown }
}

# Git Bash 那一块的标记行（与 PowerShell 的标记分开，互不干扰）。
$BashBlockStart = "# >>> EnvProxy >>>"
$BashBlockEnd   = "# <<< EnvProxy <<<"

# Git Bash 启动时执行的那一行：加载一次性复制到固定位置的脚本。
# 不把逻辑写进 .bashrc：逻辑要跟着版本走，而 .bashrc 是使用者的文件。
function Get-BashHookLine {
    return '[ -r "$HOME/.envproxy/prompt-sync.sh" ] && . "$HOME/.envproxy/prompt-sync.sh"'
}

function Get-BashBlockLines {
    return @($BashBlockStart, (Get-BashHookLine), $BashBlockEnd)
}

# Git Bash 终端同步脚本的正文。**以模板形式内嵌，安装时生成到 ~/.envproxy/prompt-sync.sh。**
#
# 为什么不作为独立文件随包发：包校验器（旧版和新版）只放行平台目录直接下级的
# .ps1 / .cmd / .command。多一个 win/prompt-sync.sh（.sh）会让**已经发布的旧版客户端**
# 在点「检查更新」时被自己的校验器拒收，报的还是「拿回来的东西没法用」——
# 把版本代差说成网络问题。修复只在新版里，而新版正是被拒收的那个包，自锁。
#
# 内嵌的代价是这门脚本对 shell 语法检查不可见（它在字符串里）。所以门禁 1 会把
# 这段抽出来单独 `bash -n` 一遍——生成式代码必须有门禁校验输出，否则改坏了没人知道。
# 标记注释就是给那条门禁定位用的，不要删。
function Get-PromptSyncContent {
    # <<<PROMPT_SYNC_BEGIN>>>
    return @'
# ==============================================================================
#  prompt-sync.sh — 让 Git Bash 里"已经开着的窗口"跟着代理状态走
#  由 bash 启动时加载一次（~/.bashrc 里那一行）；它自己注册"每次提示符前重读"的钩子。
#
#  为什么需要它：环境变量只在进程启动那一刻从父进程复制，已开着的窗口拿不到新值。
#  唯一可靠的时机是"每次回到提示符、准备执行下一条命令之前"。
#
#  DIVERGE(Win-GitBash): 与 PowerShell 侧的两处不同
#    1) 挂载点——bash 有官方钩子 PROMPT_COMMAND，不用改写别人的函数；
#    2) 状态来源——本侧读一个**普通状态文件**，不读注册表。
#       原因：MSYS2 的 /proc/registry 只能在最顶层 shell 进程里读，任何函数里
#       做重定向都会得到空值（实测）；绕开它要么用 cat（单次 57ms）要么用
#       reg.exe（47ms），敲回车会明显卡。普通文件没这个限制，单次约 0.5ms。
#       该文件由监控在每次状态变化时原子写入，是注册表状态的镜像。
#
#  ------------------------------------------------------------------------------
#  三条设计原则（与 Mac 侧、PowerShell 侧完全一致）
#  ------------------------------------------------------------------------------
#  1) 只动"我们自己写下的那一个值"。
#     只有当前值仍等于状态文件里记的值，才允许清除。
#     于是使用者自己设的公司代理、本地 mitmproxy 一律不碰。
#
#  2) 使用者随时可以接管，命令只有两条：
#       export ENVPROXY_TERM=off     这个终端固定直连
#       unset  ENVPROXY_TERM         恢复自动跟随
#
#  3) 热路径不启动任何外部进程。
#     只用 shell 内建的 read / case / export / unset（实测单次约 0.5 毫秒）。
#
#  钩子里一旦报错会打断使用者的输入，所以本文件：永不输出、永不返回非零、
#  所有外部不确定性都吞掉。
# ==============================================================================

# 只在交互式 shell 里生效。
#
# PROMPT_COMMAND 只在交互式 bash 里会被执行，所以"多跑一次"本来不会发生；
# 但**加载这个文件本身**也会触发末尾那次同步，而非交互调用（scp / rsync / git 的
# 远端钩子、`bash -c '...'`）同样会 source ~/.bashrc。那里没有任何窗口需要跟随，
# 白读一次文件、白改一次环境变量，纯属多余动作。
# 判据用 $-（当前 shell 的选项串）：含 i 才是交互式。这是 bash 的标准写法，
# 不依赖 PS1 是否已经被设置好（某些启动顺序下 PS1 后到）。
case "$-" in
    *i*) ;;
    *) return 0 2>/dev/null || exit 0 ;;
esac

if [ -z "${_ENVPROXY_GB_READY-}" ]; then
    _ENVPROXY_GB_READY=1

    # 状态文件位置：与 PowerShell 侧共用同一个安装目录。
    # 取值来源是 %LOCALAPPDATA%\EnvProxy\terminal.env（监控写）。
    _ENVPROXY_GB_STATE=""
    if [ -n "${LOCALAPPDATA-}" ]; then
        _ENVPROXY_GB_STATE="$LOCALAPPDATA/EnvProxy/terminal.env"
    fi

    # 清掉"仍等于我们写下的那个"的变量。没有状态文件时一个都不动。
    # 写入侧只有小写，但清除侧仍要认两套拼写：曾经写过大写的老版本窗口里
    # 可能还留着大写那一份，不认它就会永远清不掉。
    _envproxy_gb_clear() {
        [ -n "$_ENVPROXY_GB_STATE" ] || return 0
        [ -r "$_ENVPROXY_GB_STATE" ] || return 0
        _epc_n=""
        _epc_want=""
        while IFS='=' read -r _epc_k _epc_v; do
            case "$_epc_k" in
                owned_HTTP_PROXY|owned_HTTPS_PROXY|owned_ALL_PROXY|owned_NO_PROXY|owned_NODE_USE_ENV_PROXY) ;;
                *) continue ;;
            esac
            _epc_n="${_epc_k#owned_}"
            _epc_want="$_epc_v"
            [ -n "$_epc_want" ] || continue
            eval "_epc_cur=\"\${$_epc_n-}\""
            # 两种拼写都要看：只看大写的话，"只有小写还在"的窗口永远清不干净。
            # Git Bash 里 curl 恰恰认小写，那种窗口会一直走一个已经死掉的代理，
            # 而使用者以为"敲回车就跟上了"——状态文件明明写的是断开。
            _epc_lc=""
            case "$_epc_n" in
                HTTP_PROXY)  eval "_epc_lc=\"\${http_proxy-}\"" ;;
                HTTPS_PROXY) eval "_epc_lc=\"\${https_proxy-}\"" ;;
                ALL_PROXY)   eval "_epc_lc=\"\${all_proxy-}\"" ;;
                NO_PROXY)    eval "_epc_lc=\"\${no_proxy-}\"" ;;
            esac
            if [ "$_epc_cur" = "$_epc_want" ] || { [ -n "$_epc_lc" ] && [ "$_epc_lc" = "$_epc_want" ]; }; then
                unset "$_epc_n" 2>/dev/null || true
                case "$_epc_n" in
                    HTTP_PROXY)  unset http_proxy 2>/dev/null || true ;;
                    HTTPS_PROXY) unset https_proxy 2>/dev/null || true ;;
                    ALL_PROXY)   unset all_proxy 2>/dev/null || true ;;
                    NO_PROXY)    unset no_proxy 2>/dev/null || true ;;
                esac
            fi
        done < "$_ENVPROXY_GB_STATE"
        unset _epc_n _epc_want _epc_cur _epc_k _epc_v 2>/dev/null || true
        return 0
    }

    # 同步一次：把状态文件里的值应用到当前 shell。全程 shell 内建，零 fork。
    _envproxy_gb_apply() {
        [ -n "$_ENVPROXY_GB_STATE" ] || return 0
        [ -r "$_ENVPROXY_GB_STATE" ] || return 0

        # 使用者要求这个终端固定直连
        if [ "${ENVPROXY_TERM-}" = "off" ]; then
            _envproxy_gb_clear
            return 0
        fi

        _epa_http=""
        _epa_np=""
        _epa_node=""
        while IFS='=' read -r _epa_k _epa_v; do
            case "$_epa_k" in
                HTTP_PROXY)          _epa_http="$_epa_v" ;;
                NO_PROXY)            _epa_np="$_epa_v" ;;
                NODE_USE_ENV_PROXY)  _epa_node="$_epa_v" ;;
            esac
        done < "$_ENVPROXY_GB_STATE"

        # **只写小写一种拼写**，绝不两套都写。
        #
        # 这是项目红线（AGENTS.md：不许在 Windows 侧重引入大小写成对的变量名）。
        # 理由不是洁癖：bash 的变量名区分大小写，两套都会进环境块；而 Windows 进程
        # 拿到的环境块里就有两条只差大小写的同名项。PowerShell 5.1 的
        # `Get-ChildItem Env:` 用不分大小写的字典装它们，直接抛
        # "An item with the same key has already been added"——从这样一个 Git Bash
        # 窗口里启动任何 5.1 会话，枚举环境变量就崩。实测复现过。
        #
        # 只写小写的代价是零：Windows 的环境变量查找**不区分大小写**，
        # 从 bash 启的 powershell.exe 用 HTTP_PROXY 一样读得到；而 MSYS 的工具
        # （curl 等）本来就只认小写。所以小写是唯一两边都满足的写法。
        if [ -n "$_epa_http" ]; then
            export http_proxy="$_epa_http"
            export https_proxy="$_epa_http"
            export all_proxy="$_epa_http"
            if [ -n "$_epa_np" ]; then export no_proxy="$_epa_np"; fi
            # NODE_USE_ENV_PROXY 没有小写变体，且它和上面四个不构成"同名两套"。
            if [ -n "$_epa_node" ]; then export NODE_USE_ENV_PROXY="$_epa_node"; fi
        else
            _envproxy_gb_clear
        fi
        unset _epa_http _epa_np _epa_node _epa_k _epa_v 2>/dev/null || true
        return 0
    }

    # bash 的官方钩子。保留使用者自己的 PROMPT_COMMAND 前缀，不覆盖。
    _envproxy_gb_prompt() {
        _epbp_rc=$?
        _envproxy_gb_apply
        return $_epbp_rc
    }

    case "${PROMPT_COMMAND-};" in
        *_envproxy_gb_prompt*) ;;
        *) PROMPT_COMMAND="_envproxy_gb_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
    esac

    # 加载时先同步一次：新开的窗口立刻就是对的
    _envproxy_gb_apply
fi
'@
    # <<<PROMPT_SYNC_END>>>
}

# 把模板复制到 ~/.envproxy/prompt-sync.sh。
# 判据是内容比对，与 Mac 侧 install_prompt_sync 同一套：模板变了副本才更新。
function Install-BashrcPromptSync {
    # 正文来自内嵌模板（见 Get-PromptSyncContent 上方的说明），不再读随包文件。
    $dstDir = Join-Path ([string]$env:USERPROFILE) ".envproxy"
    $dst = Join-Path $dstDir "prompt-sync.sh"
    try {
        if (-not (Test-Item $dstDir)) { [System.IO.Directory]::CreateDirectory($dstDir) | Out-Null }
        $wantText = ((Get-PromptSyncContent) -replace "`r`n", "`n")
        if (Test-Item $dst) {
            $haveText = ([System.IO.File]::ReadAllText($dst, [System.Text.Encoding]::UTF8) -replace "`r`n", "`n")
            if ($haveText -eq $wantText) { return $true }
        }
        $tmp = "$dst.tmp$PID"
        [System.IO.File]::WriteAllText($tmp, $wantText, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Item $dst) {
            try { [System.IO.File]::Replace($tmp, $dst, [NullString]::Value) }
            catch { [System.IO.File]::Copy($tmp, $dst, $true); [System.IO.File]::Delete($tmp) }
        } else {
            [System.IO.File]::Move($tmp, $dst)
        }
        return $true
    } catch { return $false }
}

# 装 Git Bash 的终端同步：先放副本，再在 ~/.bashrc 里放一对标记。
# 块内容与 PowerShell 那套完全不同（bash 语法），所以走独立实现。
function Install-BashrcProfile([string]$path) {
    if (-not $path) { return @{ Ok = $false; Reason = 'no-profile'; Path = '' } }
    if (-not (Install-BashrcPromptSync)) {
        return @{ Ok = $false; Reason = 'copy-failed'; Path = $path }
    }
    try {
        $existing = @()
        if (Test-Item $path) { $existing = @(Read-ProfileLines $path) }
        $want = @(Get-BashBlockLines)
        $s = -1; $e = -1
        for ($i = 0; $i -lt $existing.Count; $i++) {
            if ($existing[$i].Trim() -ceq $BashBlockStart -and $s -lt 0) { $s = $i }
            if ($existing[$i].Trim() -ceq $BashBlockEnd -and $e -lt 0) { $e = $i }
        }
        # 标记不配对：绝不猜测，原样不动（与 PowerShell 侧同一护栏）。
        if (($s -ge 0) -ne ($e -ge 0)) { return @{ Ok = $false; Reason = 'unpaired'; Path = $path } }
        if ($s -ge 0 -and $e -gt $s) {
            $have = @($existing[$s..$e] | ForEach-Object { $_.Trim() })
            if (($have -join "`n") -eq ((@($want) | ForEach-Object { $_.Trim() }) -join "`n")) {
                return @{ Ok = $true; Reason = 'current'; Path = $path }
            }
            $keep = New-Object System.Collections.ArrayList
            for ($i = 0; $i -lt $existing.Count; $i++) {
                if ($i -ge $s -and $i -le $e) { continue }
                [void]$keep.Add($existing[$i])
            }
        } else {
            $keep = New-Object System.Collections.ArrayList
            foreach ($l in $existing) { [void]$keep.Add($l) }
        }
        if ($keep.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($keep[$keep.Count - 1])) { [void]$keep.Add('') }
        foreach ($l in $want) { [void]$keep.Add($l) }
        if (-not (Write-TextAtomic -Path $path -Lines @($keep))) {
            return @{ Ok = $false; Reason = 'write-failed'; Path = $path }
        }
        return @{ Ok = $true; Reason = 'installed'; Path = $path }
    } catch {
        return @{ Ok = $false; Reason = $_.Exception.Message; Path = $path }
    }
}

function Install-OneShellProfile([string]$path) {
    if (-not $path) { return @{ Ok = $false; Reason = 'no-profile'; Path = '' } }
    # Git Bash 的 .bashrc 用 bash 语法，块内容与 PowerShell 完全不同，走自己的实现。
    if (Test-IsBashrcPath $path) { return (Install-BashrcProfile $path) }
    if (Test-ProfileBlockCurrent $path) { return @{ Ok = $true; Reason = 'current'; Path = $path } }
    try {
        $existing = @()
        if (Test-Path -LiteralPath $path) { $existing = @(Read-ProfileLines $path) }
        $keep = New-Object System.Collections.ArrayList
        if (Test-Path -LiteralPath $path) {
            if (Test-ProfileBlockPaired $path) {
                # 有完整旧块：摘掉它，换成新版
                $s = -1; $e = -1
                for ($i = 0; $i -lt $existing.Count; $i++) {
                    if ($existing[$i].Trim() -ceq $ProfileBlockStart.Trim() -and $s -lt 0) { $s = $i }
                    if ($existing[$i].Trim() -ceq $ProfileBlockEnd.Trim() -and $e -lt 0) { $e = $i }
                }
                for ($i = 0; $i -lt $existing.Count; $i++) {
                    if ($i -ge $s -and $i -le $e) { continue }
                    [void]$keep.Add($existing[$i])
                }
            } elseif ((Test-MarkerPresent $existing $ProfileBlockStart) -or (Test-MarkerPresent $existing $ProfileBlockEnd)) {
                # 标记不配对：绝不猜测，原样不动（与 Mac 侧同一护栏）
                return @{ Ok = $false; Reason = 'unpaired'; Path = $path }
            } else {
                foreach ($l in $existing) { [void]$keep.Add($l) }
            }
        }
        # 块放在**末尾**：$PROFILE 最后执行，放最后才能包住前面所有 prompt 定义。
        if ($keep.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($keep[$keep.Count - 1])) {
            [void]$keep.Add('')
        }
        foreach ($l in (Get-ProfileBlockLines)) { [void]$keep.Add($l) }
        if (-not (Write-TextAtomic -Path $path -Lines @($keep))) {
            return @{ Ok = $false; Reason = 'write-failed'; Path = $path }
        }
        # 读回复检：修没修成由复读决定，不由"我调用了写入"决定。
        if (-not (Test-ProfileBlockCurrent $path)) {
            return @{ Ok = $false; Reason = 'verify-failed'; Path = $path }
        }
        return @{ Ok = $true; Reason = 'installed'; Path = $path }
    } catch {
        return @{ Ok = $false; Reason = $_.Exception.Message; Path = $path }
    }
}

# 卸载：只摘我们那一块，用户其余内容一字不动。返回是否真的动过文件。
function Remove-ShellProfile {
    # 安装时写了几个 profile，卸载就要摘几个——只摘当前宿主的那个，
    # 另一个版本的 PowerShell 里会一直留着一段引用已卸载工具的代码。
    $all = @(Get-ProfilePaths)
    if ($all.Count -eq 0) { return @{ Ok = $true; Reason = 'no-profile'; Path = '' } }
    $removed = New-Object System.Collections.ArrayList
    $firstErr = $null
    foreach ($p in $all) {
        # 同安装：一个落点失败不拦其余，否则另一个版本的 PowerShell 里会一直留着
        # 一段引用已卸载工具的代码。
        $r = Remove-OneShellProfile $p
        if (-not $r.Ok) { if ($null -eq $firstErr) { $firstErr = $r }; continue }
        if ($r.Reason -eq 'removed') { [void]$removed.Add($p) }
    }
    if ($null -ne $firstErr) { return $firstErr }
    if ($removed.Count -gt 0) { return @{ Ok = $true; Reason = 'removed'; Path = ($removed -join '; ') } }
    return @{ Ok = $true; Reason = 'no-block'; Path = ($all -join '; ') }
}

function Remove-OneShellProfile([string]$path) {
    if (-not $path) { return @{ Ok = $true; Reason = 'no-profile'; Path = '' } }
    if (-not (Test-Path -LiteralPath $path)) { return @{ Ok = $true; Reason = 'absent'; Path = $path } }
    $existing = @(Read-ProfileLines $path)
    if (-not ((Test-MarkerPresent $existing $ProfileBlockStart) -or (Test-MarkerPresent $existing $ProfileBlockEnd))) {
        # 没有我们的标记：碰都不碰（连 mtime 都不改）
        return @{ Ok = $true; Reason = 'no-block'; Path = $path }
    }
    if (-not (Test-ProfileBlockPaired $path)) {
        return @{ Ok = $false; Reason = 'unpaired'; Path = $path }
    }
    # 把所有成对的块都摘掉，不是只摘第一对。
    # 装过两次（或从不同位置装过）的机器上会留下两对标记，只摘一对的话
    # 卸载会「看着成功、余下一块」，下一次卸载才干净——用户以为没卸掉。
    # Mac 侧那边是一次摘干净的（awk 反复开关），这里对齐它。
    $keep = New-Object System.Collections.ArrayList
    $skipping = $false
    $removed = 0
    for ($i = 0; $i -lt $existing.Count; $i++) {
        $line = $existing[$i]
        if (-not $skipping -and $line.Trim() -ceq $ProfileBlockStart.Trim()) {
            $skipping = $true
            $removed++
            continue
        }
        if ($skipping) {
            if ($line.Trim() -ceq $ProfileBlockEnd.Trim()) { $skipping = $false }
            continue
        }
        [void]$keep.Add($line)
    }
    # 摘完若只剩结尾空行，一并收掉，别给用户留个空白尾巴
    while ($keep.Count -gt 0 -and [string]::IsNullOrWhiteSpace($keep[$keep.Count - 1])) {
        $keep.RemoveAt($keep.Count - 1)
    }
    # 摘完若什么都不剩，说明这个文件里原本只有我们那一块（或者本来就是空的）。
    # 再擦成空文件就是"卸载回到安装前"没做到位：装之前它不存在，卸完却多一个空文件。
    # 只在确实为空时删除，用户自己写过内容的一个字节都不动。
    # 卸载把 .bak 也带走：它是我们安装时留下的快照，卸载就是"回到我们没来之前"。
    # 留着它既违背 README「卸载后不留残留」，也和 .bak 里自己写的那句
    #「卸载时应删除」对不上——写了却没人执行，等于给用户一句空承诺。
    $bakPath = $path + ".envproxy.bak"
    if ($keep.Count -eq 0) {
        try {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            try { if (Test-Path -LiteralPath $bakPath) { Remove-Item -LiteralPath $bakPath -Force -ErrorAction SilentlyContinue } } catch {}
            return @{ Ok = $true; Reason = 'removed-empty'; Path = $path }
        } catch {
            # 删不掉就退回"写空文件"：留一个空文件也强过报错让人没法收尾。
        }
    }
    if (-not (Write-TextAtomic -Path $path -Lines @($keep))) {
        return @{ Ok = $false; Reason = 'write-failed'; Path = $path }
    }
    if ((Test-MarkerPresent @(Read-ProfileLines $path) $ProfileBlockStart)) {
        return @{ Ok = $false; Reason = 'verify-failed'; Path = $path }
    }
    try { if (Test-Path -LiteralPath $bakPath) { Remove-Item -LiteralPath $bakPath -Force -ErrorAction SilentlyContinue } } catch {}
    return @{ Ok = $true; Reason = 'removed'; Path = $path }
}

# 执行策略检查：Restricted 下 profile 根本不执行且无提示。
# 静默失败最糟——用户以为在同步，实际一次都没同步过。
# 解析「真正生效的」执行策略，以及它能不能被本地改掉。
# 不能只看 -Scope CurrentUser：那个 scope 没设过时返回 Undefined，而真正拦住 $PROFILE 的
# 可能是 MachinePolicy/UserPolicy（组策略，优先级最高、改本地设置无效），也可能是
# LocalMachine（管理员设过）。实测本机 CurrentUser=Undefined 而生效值 RemoteSigned——
# 只看 CurrentUser 会在最需要提醒的场景里一句话都不说。
# 优先级：MachinePolicy > UserPolicy > Process > CurrentUser > LocalMachine。
# 全为 Undefined 时，Windows 客户端的有效策略就是 Restricted（微软文档明确）。
function Get-EffectiveExecutionPolicy {
    # 要回答的问题是「**新开的窗口**会不会执行配置文件」，不是「当前这个进程现在能不能跑脚本」。
    # 这两个问题有完全不同的答案来源：
    #   - Process 层只是本进程的临时覆盖（安装器自己就是用 -ExecutionPolicy Bypass 拉起的），
    #     它随进程消失，对下一个窗口毫无影响。把它算进来，等于让"我自己能跑"冒充"用户能跑"。
    #     实测：安装器以 Bypass 启动时 EffectivePolicy 会被解析成 Bypass，于是即使用户把
    #     CurrentUser 设成 Restricted（配置文件一次都不执行），状态页照样报"已生效"。
    #   - 新窗口继承的是持久化的那几层：组策略 > 用户设置 > 机器设置。
    # 所以这里刻意**跳过 Process**，只在持久化三层里按优先级取。
    # 全为 Undefined 时，Windows 客户端的有效策略就是 Restricted（微软文档明确）。
    $scopes = @{}
    try {
        foreach ($e in (Get-ExecutionPolicy -List)) {
            $scopes[[string]$e.Scope] = [string]$e.ExecutionPolicy
        }
    } catch {}
    foreach ($n in @('MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine')) {
        $v = $scopes[$n]
        if ($v -and $v -ne 'Undefined') {
            return @{ Policy = $v; Enforced = ($n -eq 'MachinePolicy' -or $n -eq 'UserPolicy'); Scope = $n }
        }
    }
    return @{ Policy = 'Restricted'; Enforced = $false; Scope = '(未设置)' }
}

function Get-ProfileExecutionPolicyWarning {
    try {
        $eff = Get-EffectiveExecutionPolicy
        $p = $eff.Policy
        if ($p -ne 'Restricted' -and $p -ne 'AllSigned') { return '' }
        if ($eff.Enforced) {
            return ("当前执行策略是 $p（由组策略强制，本地改不了），PowerShell 不会运行" +
                    "配置文件（$PROFILE）——终端同步不会生效。需要管理员放开脚本执行。")
        }
        return ("当前执行策略是 $p，PowerShell 不会运行配置文件（$PROFILE）——" +
                "终端同步不会生效。改成 RemoteSigned 即可：Set-ExecutionPolicy RemoteSigned -Scope CurrentUser")
    } catch {}
    return ''
}

# ------------------------------------------------------------------------------
# 4. 监控进程管理（PID 文件 + 优雅停止标志 + 兜底强杀）
# ------------------------------------------------------------------------------
# 脚本目录用入口发布的 $ScriptDir（本层不自行推算：库里的 $PSScriptRoot 指向 lib\ 自己）。

# 所有运行时文件集中放 monitor\ 子文件夹（log / pid / stop 标志），
# 卸载时整目录删除，一个都不残留。
$MonitorDir = Join-Path $ScriptDir "monitor"
$PidFile    = Join-Path $MonitorDir "monitor.pid"
# "是使用者主动停的"这个意图要落盘。监控进程被外部结束（任务管理器、崩溃）和用户点「停止」
# 在事后完全无法区分：pid 没了、自启动还在，两种情况长得一模一样。
# 不区分就只能二选一：都说"你停的"（用户没停，会以为点错了），或都不说（真停过的人会以为坏了）。
# 所以由执行停止的那一方写下这个标记，监控自己启动时删掉它。
$StopIntentFile = Join-Path $MonitorDir "stopped.intent"
# 版本号缓存：由监控刷新、状态页只读。状态页不许联网（见 Write-VersionCache 的注释）。
$VersionCacheFile = Join-Path $MonitorDir "version.cache"
# 覆盖安装区时的"进行中"标记。正常结束（成功或回滚）都会删掉它；
# 断电/被杀才会留下——那种情况下安装区可能是新旧混合的，而没有任何自检看得出来。
$UpdateInProgressFile = Join-Path $MonitorDir "update.inprogress"
# 心跳文件：监控每轮把它刷新一次。它的唯一用途是"没有 WMI 时也能判断监控还活着"。
# 与 pid 文件分开：pid 文件的语义是"我是哪个进程"（只在启动时写一次，缺失才补），
# 让它兼当心跳会让两个语义互相污染——而实测过，稳态下 pid 的 mtime 会停在启动那一刻。
$HeartbeatFile = Join-Path $MonitorDir "monitor.beat"
# 心跳多久没更新就认为"监控不在了"。240 秒：稳定态一轮 2–3 秒，这个窗口容得下
# 一次休眠唤醒、一次磁盘卡顿、一次系统更新后的短暂无响应，又足够短到
# "监控真死了"能在几分钟内被发现。
$HeartbeatMaxSec = 240

$StopFlag   = Join-Path $MonitorDir "stop.flag"

function Ensure-MonitorDir {
    try { New-Item -Path $MonitorDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
}

# 监控进程的识别判据（唯一权威处，下面三处引用都指向它）：
# 监控进程的特征 = 命令行以 -File "...envproxy.ps1" 结尾、且不带任何子命令。
# 执行 -Status / -Install / -Stop 的进程带了子命令参数，故不会被误认；调用方自身另行排除。
# 收紧到行尾锚定是为了排除"命令行里恰好含 envproxy 字样"的其他进程（如带 -Command 的诊断调用）。
# 路径两侧的引号可有可无：引号由启动方式决定（自己起的时候常常没加），不是身份的一部分。
# 把引号当成条件会出这种事：认不出已经跑着的监控 → 安装器以为监控没在跑 → 起第二份 →
# 单实例锁又把第二份挡掉 → 于是再也起不来监控，状态页还报"未运行"。判身份要看实质。
# DIVERGE(Mac): macOS 侧等价实现是 `pgrep -f "envproxy\.sh$"`（见 mac/locator.sh），语义相同。
$MonitorCmdLinePattern = '-File\s+"?[^"]*envproxy\.ps1"?\s*$'

# 判据一：监控自己写下的 pid 文件（它在抢到单实例互斥之后才写）。
# 这是"监控真的在跑"的唯一可靠判据——命令行特征只能说明"有这么个进程"，
# 而刚启动、还没抢到锁就在退出的那个也满足它，拿它当"已启动"就会报假话。
function Get-MonitorProcessFromPidFile {
    if (-not (Test-Item $PidFile)) { return $null }
    try {
        $pid2 = [int]((Read-Text $PidFile).Trim())
        if ($pid2 -ne $PID) {
            # 校验命令行确实是本脚本，防止 PID 被系统复用而误杀他人
            $w = Get-CimInstance Win32_Process -Filter "ProcessId=$pid2" -ErrorAction SilentlyContinue
            if ($w -and $w.CommandLine -match $MonitorCmdLinePattern) { return $w }
        }
    } catch {}
    return $null
}

# 判据二（兜底）：命令行特征。判"有没有监控在跑"用它——pid 文件缺失或陈旧但确实有监控时
# 靠它（手工启动、pid 文件被删、跨位置停止）；判"我刚启动的监控起来了吗"不能用它。
# 监控进程是否活着：不依赖 WMI 的第二条判据。
#
# 为什么需要它：身份判定原来只走 WMI（Get-CimInstance / Invoke-CimMethod）一条通道，
# 而"停止"和"卸载"完全依赖它。各类"系统优化/精简"工具会关掉 Windows Management
# Instrumentation，企业镜像、Ghost 装机盘也会，WMI 仓损坏同样会让它抛异常
# （Get-OwnMonitorProcesses 自己就 `catch { return @() }`）。通道一断，后果是三连击且全部静默：
#   1. -Stop 静默变成空操作 → 监控 2–3 秒后把变量重新注入，用户看到"停了又自己回来"；
#   2. -Uninstall 停不掉 → 后续照做删掉 Run 键，而活着的监控每 30 轮自愈把 Run 键和
#      launcher 重建回来（周期只有 60–90 秒，比人操作快）；
#   3. 卸载复检用的是同一个通道 → 屏幕上打印"[完成] 电脑已恢复到安装前的状态"。
# 也就是"卸载"这个最后的兜底手段会失效——比直接报错糟得多。
#
# 判据用 pid 文件里的 pid + Get-Process（进程快照 API，不是 WMI）。
#
# 这里**不**用"pid 文件的修改时间新不新"当心跳：监控只在启动时写一次 pid 文件
# （文件缺失时才补写），稳态下它的 mtime 会一直停在启动那一刻。拿它当新鲜度判据，
# 结果是监控正常运行几小时后这个判据恒为假——看起来"有兜底"，实际等于没有。
#
# 但光看"这个 pid 还活着"不够：pid 会被系统回收再分配。实测过——把 pid 文件改写成一个
# 无关进程的号（哪怕是 explorer），判据照样为真，于是状态页会报"监控运行中 (PID <别人的号>)"，
# 卸载复检也会认定"监控进程仍在"而报未完成。所以必须再核一次"这个进程跑的是不是本脚本"。
# 这一步用 Get-Process 的 CommandLine（不是 WMI/CIM，普通用户可读），
# 与本文件里 MonitorCmdLinePattern 同一套判据——**同一个判断不写两遍**。
function Test-MonitorAlive {
    # 心跳文件里记着「pid + 那个进程的启动时刻」。两条都要对得上才算活着：
    #   pid 对得上  → 大概率是它；
    #   启动时刻也对得上 → 一定是它（系统回收 pid 后新进程的启动时刻必然不同）。
    # 这样既不依赖 WMI，也不怕 pid 复用。
    if (Test-Item $HeartbeatFile) {
        try {
            $parts = @((Read-Text $HeartbeatFile).Trim() -split '\s+')
            $beatPid = 0
            [void][int]::TryParse($parts[0], [ref]$beatPid)
            if ($beatPid -gt 0 -and $beatPid -ne $PID) {
                $proc = Get-Process -Id $beatPid -ErrorAction SilentlyContinue
                if ($proc) {
                    if ($parts.Count -lt 2) { return $true }
                    $wantTicks = 0
                    if ([long]::TryParse($parts[1], [ref]$wantTicks) -and $wantTicks -gt 0) {
                        return ([long]$proc.StartTime.Ticks -eq $wantTicks)
                    }
                    return $true
                }
            }
        } catch {}
    }
    # 心跳还没写过（刚启动的头几秒）时靠 pid 文件 + Get-Process。
    # 这条单独用挡不住 pid 复用，所以只在心跳缺席时兜底——正常运行时心跳总在。
    if (Test-Item $PidFile) {
        try {
            $p = [int]((Read-Text $PidFile).Trim())
            if ($p -gt 0 -and $p -ne $PID) {
                if (Get-Process -Id $p -ErrorAction SilentlyContinue) { return $true }
            }
        } catch {}
    }
    return $false
}

function Get-MonitorProcess {
    $fromFile = Get-MonitorProcessFromPidFile
    if ($fromFile) { return $fromFile }
    # 不依赖 WMI 的快速判据：心跳新鲜就当作活着。
    # 它拿不到 PID（拿得到也在 $fromFile 那一支返回了），所以只在"是不是活着"这个问题上生效。
    if (Test-MonitorAlive) { return [pscustomobject]@{ ProcessId = 0; CommandLine = "" } }
    # Get-CimInstance 是 Windows 专有的命令：Linux/macOS 上的 pwsh 没有它。
    # 本项目的测试会在 ubuntu 上跑这份代码（门禁 10），退不回来就会抛异常、
    # 整份自检中断在这里。非 Windows 上直接当作"没有命令行线索"。
    if ($env:OS -ne "Windows_NT") { return $null }
    $list = @(Get-OwnMonitorProcesses)
    if ($list.Count -gt 0) { return $list[0] }
    return $null
}

# 监控启动参数的唯一来源：命令行必须以 -File "<入口路径>" 结尾——这既是监控进程的识别判据
# （见 $MonitorCmdLinePattern），也是"启动的到底是哪个文件"的唯一出处。测试也从这里取。
function Get-MonitorLaunchArgs {
    return @("-NoProfile","-WindowStyle","Hidden","-ExecutionPolicy","Bypass","-File",('"{0}"' -f $ScriptPath))
}

# 返回值 = 是否确认监控在跑。调用方据此说话——"我调用过启动"不等于"它起来了"。
function Start-Monitor([bool]$Force = $false) {
    $existing = Get-MonitorProcess
    if ($existing) {
        # 已有监控在跑：
        #   - Force（安装场景）：无条件重启，保证运行中的监控永远是当前脚本的最新代码
        #   - 非 Force 且路径一致：幂等跳过（重复点安装零副作用）
        #   - 非 Force 且路径不一致：旧位置的监控（文件夹被移动过）：先停掉旧的，再启动新的
        # 注意：用 IndexOf 而非 -like——-like 会把路径里的 [ ] 当通配符误判
        $samePath = ($existing.CommandLine.IndexOf($ScriptPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
        if (-not $Force -and $samePath) {
            Write-Styled 'warn' "监控进程已在运行（路径一致），跳过启动。"
            return $true
        }
        Write-Styled 'warn' $(if ($Force) { "正在重启监控以加载当前最新代码..." } else { "检测到旧位置的监控进程，正在迁移到当前路径..." })
        Stop-Monitor
    }
    # 启动前清掉可能残留的 pid 文件（强杀不给监控机会删它），否则复检会读到上一次运行的 pid。
    Remove-ItemSafe $PidFile
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList (Get-MonitorLaunchArgs)
    # 启动完必须复查，判据是**监控自己写下的 pid 文件**：抢不到单实例互斥的子进程会安静退出，
    # 而它在退出前同样"命令行里带着本脚本"，只看进程存在就会把这种失败报成"已启动"。
    # 但也要给它足够时间：PowerShell 5.1 冷启动并加载七个库可能要好几秒，所以轮询而不是固定等。
    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline) {
        if (Get-MonitorProcessFromPidFile) { break }
        Start-Sleep -Milliseconds 400
    }
    if (Get-MonitorProcessFromPidFile) {
        Write-Styled 'ok' "监控进程已启动。"
        return $true
    }
    # 起不来要分清是"另一个副本占着锁"还是"根本没起来"：前者该去别处收摊，后者该查杀软与日志。
    # 说清楚另一份在哪，使用者才知道该进哪个文件夹——只说"可能被占着"，等于把排查推回去。
    $other = $null
    try {
        $otherList = @(Get-OwnMonitorProcesses)
        if ($otherList.Count -gt 0) { $other = $otherList[0] }
    } catch {}
    if ($other) {
        $otherPath = ""
        if ($other.CommandLine -match '-File\s+"?([^"]*?envproxy\.ps1)"?\s*$') { $otherPath = $Matches[1] }
        $otherDir = if ($otherPath) { Split-Path -Parent (Split-Path -Parent $otherPath) } else { "" }
        Write-Styled 'warn' ("监控进程未能确认运行：另一个副本的监控正占着单实例锁（{0}）。" -f $(if ($otherDir) { $otherDir } else { $otherPath }))
        Write-Styled 'warn' "      还用那份就继续用它；不用了，进上面那个文件夹打开菜单选 一键恢复，再回到这里选 安装。"
    } else {
        Write-Styled 'warn' "监控进程未能确认运行：这次没看到别的副本，多半是启动被拦或启动过程出错。"
        Write-Styled 'warn' "      再选一次 安装 / 修复；仍然不行就看 查看状态 和 monitor.log 最近几行。"
    }
    return $false
}

function Stop-Monitor {
    $w = Get-MonitorProcess
    if (-not $w) {
        # 监控本来就没在跑，但使用者确实表达了"停"的意图——照样记下来。
        # 不记的话，状态页会把这台机器报成"进程不在了（可能被结束任务关掉）"，
        # 而真相是使用者刚刚点过停止。意图比进程状态更权威。
        try { Write-Text -Path $StopIntentFile -Text "user" } catch {}
        Write-Styled 'warn' "监控进程未在运行。"
        return
    }
    # 从目标监控的命令行动态解析它的脚本位置 → 把停止标志写到"它自己"的 monitor 目录。
    # 处理文件夹被移动/复制后新旧位置不一致的场景：让旧位置的监控优雅退出，而非强杀。
    $targetDir = $MonitorDir
    # 引号可有可无：引号是启动方式决定的，不是身份的一部分（与 $MonitorCmdLinePattern 同一条道理）。
    # 要求带引号时，手工起的监控拿不到它自己的目录：停止标志写进了"我们"的 monitor 目录，
    # 优雅停止退化成强杀，还留下一个谁也不会消费的 stop.flag。
    if ($w.CommandLine -match '-File\s+"?([^"]*?envproxy\.ps1)"?\s*$') {
        $targetDir = Join-Path (Split-Path -Parent $Matches[1]) "monitor"
    }
    $targetFlag = Join-Path $targetDir "stop.flag"
    # 1) 优雅：写停止标志，监控进程 2 秒内自行退出
    try {
        New-Item -Path $targetDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        Write-Text -Path $targetFlag -Text "stop"
    } catch {}
    $deadline = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-MonitorProcess)) { break }
        Start-Sleep -Milliseconds 300
    }
    # 2) 兜底：还没退就强杀，并等待充分时间确保进程彻底消亡 + 互斥锁释放
    #    （防止迁移场景下"新监控启动时旧监控还没死透"的竞态）
    $w2 = Get-MonitorProcess
    if ($w2) {
        Stop-Process -Id $w2.ProcessId -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
    Remove-ItemSafe $targetFlag
    Remove-ItemSafe $StopFlag
    # 记下"这是使用者主动停的"，状态页据此区分它与"进程被外部结束"。
    try { Write-Text -Path $StopIntentFile -Text "user" } catch {}
    # 跨位置停止的零残留：若停止标志写在"别的" monitor 目录、且该目录已空
    # （旧监控退出时已清理自己的 pid/flag），则把这个重建的空目录一并移除
    if ($targetDir -ne $MonitorDir) {
        $left = Get-ChildItem -LiteralPath $targetDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $left) {
            Remove-Item -LiteralPath $targetDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    # 强杀路径下监控来不及删自己的心跳；不清掉它，下面这条判定会读到一个
    # "2 秒前刚刷新"的心跳，于是误报"未能停止"。所以判定之前主动清一次。
    # 位置必须是目标目录（跨位置停止时目标不是本进程的 $MonitorDir）。
    try {
        $beatTarget = Join-Path $targetDir "monitor.beat"
        if (Test-Item $beatTarget) { Remove-Item -LiteralPath $beatTarget -Force -ErrorAction SilentlyContinue }
    } catch {}
    if (-not (Test-Item $targetDir) -or $targetDir -eq $MonitorDir) {
        try { Remove-ItemSafe $HeartbeatFile } catch {}
    }
    if (Get-MonitorProcess) {
        Write-Styled 'warn' "监控进程未能停止（请检查是否有别的窗口正在运行它）。"
    } else {
        Write-Styled 'ok' "监控进程已停止。"
    }
}

# ------------------------------------------------------------------------------
# 5. 日志（只记状态翻转，不刷屏；超过 $LogMaxBytes 自动截断）
# ------------------------------------------------------------------------------
$LogFile = Join-Path $MonitorDir "monitor.log"

function Write-MonitorLog([string]$msg) {
    try {
        Ensure-MonitorDir
        # 时间戳必须用固定区域性：Get-Date -Format 受当前区域设置影响，
        # 泰语（th-TH）下写成佛历年份（实测 "2569-10-22"），阿拉伯语写回历（"1448-05-11"）。
        # 日志是给人对时间用的，年份错位会让整条线索作废。mac 侧 date 输出本就是数字，这边对齐它。
        $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
        $line = "{0}  {1}" -f $stamp, $msg
        # 共享写模式（FileShare.ReadWrite）：多进程追加写入互不阻塞，零锁脆弱点。
        # 改用共享文件流后，任何进程（含监控自身截断）互不阻塞，零锁脆弱点。
        $fs = [System.IO.File]::Open($LogFile, [System.IO.FileMode]::Append,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($line + "`r`n")
            $fs.Write($bytes, 0, $bytes.Length)
        } finally { $fs.Dispose() }
        # 体积上限：超过 $LogMaxBytes 截断为最近 $LogTailLines 行（黑匣子保留近期窗口，永远不会无限增长）
        # 截断同样用共享模式；万一失败（极端外部锁），静默跳过、下次再试——绝不中断监控
        # 注意：读取必须显式 UTF8 —— 默认按 ANSI 读会乱码，且截断时把乱码写回损坏日志
        $fi = New-Object System.IO.FileInfo($LogFile)
        if ($fi.Exists -and $fi.Length -gt $LogMaxBytes) {
            $keep = [System.IO.File]::ReadAllLines($LogFile, [System.Text.Encoding]::UTF8) | Select-Object -Last $LogTailLines
            $fs2 = [System.IO.File]::Open($LogFile, [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try {
                $bytes2 = [System.Text.Encoding]::UTF8.GetBytes(($keep -join "`r`n") + "`r`n")
                $fs2.Write($bytes2, 0, $bytes2.Length)
            } finally { $fs2.Dispose() }
        }
    } catch {}
}

# ------------------------------------------------------------------------------
# 6. 监控主循环（事件驱动 + 多轮确认去抖，无频繁写操作）
# ------------------------------------------------------------------------------
# 状态疑似翻转要连续确认几轮才动手：轮数决定"抗抖能力"，也是对外公布的
# "连回来要多久 / 断开要多久"的一部分，所以必须是具名常量（门禁要读它推导文档）。
$StateDebounceRounds = 2
function Run-MonitorLoop {
    # 单实例互斥：重复启动自动退出。名字按用户隔离（见 Get-MutexName），
    # 同一台电脑多个账户各装一份时互不干扰。
    $mutex = New-Object System.Threading.Mutex($false, (Get-MutexName "EnvProxyMonitorSingleton"))
    if (-not $mutex.WaitOne(0)) {
        try { Write-MonitorLog "监控未启动：已有另一个监控进程在运行（单实例互斥）。" } catch {}
        return
    }

    Remove-ItemSafe $StopFlag
    Ensure-MonitorDir
    try {
        Write-Text -Path $PidFile -Text ([string]$PID)
        # 监控活着就等于"不是停止状态"，把上次的停止意图清掉。
        Remove-ItemSafe $StopIntentFile
    } catch {}
    Update-ScriptPathRecord
    Write-MonitorLog "==== 监控启动 ===="

    # 启动立即对齐：不等去抖，当场校正环境变量。
    # 关键场景：关机前没退出翻墙软件 → 重启后环境变量残留死端口 →
    # 监控一启动就立即清掉残留（恢复直连）或注入正确值，闭环无窗口期。
    $lastState    = $null
    $pendingState = $null
    $pendingCount = 0
    $repairRound  = 0
    $selfExit     = $false
    try {
        $bootState = Get-CurrentState
        # 端口枚举失败时这一轮是"不知道"：按"没代理"去清理变量，
        # 是在删一个可能还活着的代理——那正是最不该犯的错。
        if ($bootState -ne "unknown") {
            Apply-State $bootState
            $lastState = $bootState
        } else {
            Write-MonitorLog "启动时端口枚举失败 -> 不动环境变量，沿用现状"
        }
    } catch {
        Write-MonitorLog "启动对齐异常: $($_.Exception.Message)"
    }

    while (-not (Test-Item $StopFlag)) {
        # 运行时目录自愈。它只在启动时建过一次，被外部删掉（清理工具、误删、同步软件）之后
        # 日志与 pid 文件就再也写不出来了：进程还在正常干活，状态页却因为读不到 pid 而报
        # "未运行"——用户看到的是"明明在跑却说没跑"，于是又去点安装，起第二份被单实例锁挡掉，
        # 彻底卡死。每轮先确认目录在，是这件事的唯一收敛点（mkdir -p 是幂等的、不产生 IO）。
        if (-not (Test-Item $MonitorDir)) { Ensure-MonitorDir }
        # pid 文件同理：它一旦丢失，对外就"查不到自己在跑"。重新写一份，代价是一次小文件写。
        if (-not (Test-Item $PidFile)) { try { Write-Text -Path $PidFile -Text ([string]$PID) } catch {} }
        # 心跳：每轮刷新一次（写单个字节，代价可忽略）。
        # 它的存在是为了让"没有 WMI 的机器上也能判断监控还活着"——
        # 不依赖任何系统服务，也不依赖进程查询接口。
        if ($repairRound % 3 -eq 0) {
            try {
                # 内容：本进程 pid + 启动时刻 ticks。
                # 记启动时刻是为了挡住 pid 复用——系统回收 pid 再分配给别的进程后，
                # 新进程的 StartTime 一定不同。这是 mac 侧 `ps -p <pid> -o args=` 的等价物：
                # PowerShell 5.1 的 Get-Process 没有 CommandLine 属性（那是 7 才有的），
                # 而拿命令行在 5.1 下只能走 WMI/CIM —— 正是本判据要绕开的通道。
                $me = Get-Process -Id $PID -ErrorAction SilentlyContinue
                $stamp = if ($me) { [string]$me.StartTime.Ticks } else { "0" }
                Write-Text -Path $HeartbeatFile -Text (([string]$PID) + " " + $stamp)
            } catch {}
        }
        # 日志文件也要补。它只在"状态有变化"时才写，稳态下一条都不产生——
        # 只补目录和 pid 的话，删过目录之后 monitor.log 会一直不存在，
        # 等到真出问题时用户手上没有任何线索可查（"日志永远是空的"比"没日志"更误导）。
        # 写一条记录本身就是最好的补法：文件建起来了，而且留下了"这里被重建过"的痕迹。
        if (-not (Test-Item $LogFile)) {
            try { Write-MonitorLog "运行时目录被外部删除，已重建（进程未受影响，继续按原状态工作）" } catch {}
        }
        # 自退检测：脚本文件不存在 = 文件夹被移动/删除 → 旧位置不再需要本监控。
        # 静默退出并清理旧位置的一切运行时痕迹（下次开机定位器会从新位置启动）。
        if (-not $ScriptPath -or -not (Test-Item $ScriptPath)) { $selfExit = $true; break }
        try {
            $state = Get-CurrentState

            if ($state -eq "unknown") {
                # 这一轮不知道（端口枚举失败）：沿用上一状态，不动环境变量，
                # 也不计入去抖——把"没读到"当成"没在翻墙"会删掉用户的代理变量。
                # 失败原因由探测层放在 $script:PortEnumerationReason 里，这里带上一句：
                # 只写"枚举失败"等于把唯一的线索丢掉，事后分不清是 netstat 形状变了、
                # 输出被裁剪、还是权限问题，而这几种的排查方向完全不同。
                $why = ""
                try { $why = [string]$script:PortEnumerationReason } catch {}
                if ($why) {
                    Write-MonitorLog ("端口枚举失败（两次都没成功：" + $why + "）-> 本轮沿用上一状态，不动环境变量")
                } else {
                    Write-MonitorLog "端口枚举失败 -> 本轮沿用上一状态，不动环境变量"
                }
                $state = $lastState
            }

            if ($state -ne $lastState) {
                # 状态疑似翻转：连续确认 $StateDebounceRounds 轮才动手，杜绝抖动
                if ($state -eq $pendingState) { $pendingCount++ } else { $pendingState = $state; $pendingCount = 1 }
                if ($pendingCount -ge $StateDebounceRounds) {
                    Apply-State $state
                    $lastState = $state
                    $pendingState = $null
                    $pendingCount = 0
                }
            } else {
                $pendingState = $null
                $pendingCount = 0
            }

            # 每 30 轮自愈一次（轮间隔 on 2 秒 / off 3 秒 → 约 60–90 秒一次）。
            # 按轮计数而不是按秒：轮询节奏本身就是可变配置，写死秒数会随节奏改动而失准。
            $repairRound++
            if ($repairRound -ge 30) {
                $repairRound = 0
                Repair-AutoRun
                # 终端同步的钩子块也在这里自愈：升级后没走"安装"，旧块内容会一直留在用户
                # $PROFILE 里（钩子改了却送不到手里）。幂等，已是最新就零写入。
                try {
                    $pr = Install-ShellProfile
                    if ($pr.Reason -eq 'installed') {
                        Write-MonitorLog "已自动更新终端同步（配置块内容与当前版本不一致）"
                    } elseif ($pr.Reason -eq 'unpaired') {
                        Write-MonitorLog ("终端同步没有更新：配置文件里的标记不成对，没动它：" + $pr.Path)
                    }
                } catch {}
                # 版本号缓存：状态页要显示"是不是最新版"，而它自己不许联网——
                # 否则每次"查看状态"都要等一次外网往返（离线/限流时白等）。
                # 写缓存的是监控（它本来就写文件），状态页只读。
                try { Write-VersionCache } catch {}
                # 变量自检：Apply-State 只在状态翻转时动手，稳态下它永远不会被调用，
                # 于是"别的东西改坏了变量"没人纠正。这里按同一周期做一次整表核对：
                # on 态补齐缺失项，off 态把残留收干净——幂等（齐了就零写入、零广播）。
                # 只核对我们本该持有的那几个，用户自己设的变量不受影响。
                #
                # 动手的那段走与 Apply-State 完全相同的函数（Invoke-EnvStateWrite）：
                # 拿同一把跨进程锁、同样的判断、同样的广播。两份代码做同一件事的后果是
                # 改一处漏一处，而症状是"翻转时对、自愈时错"，屏幕上完全看不出来。
                # 先判 "on:" 前缀：启动对齐若抛过异常，$lastState 仍是 $null。
                if ($lastState) {
                    $healOk = Invoke-EnvStateWrite $lastState `
                        "检测到代理变量残留 -> 已回收，恢复直连" `
                        "变量被人改坏了 -> 已按当前代理端口重新写回"
                    if ($healOk -ne 0) { Write-MonitorLog "变量自检没能写回（下一轮再试）" }
                }
            }

            # 节奏差异化：on 状态 2 秒一轮（响应快）；off 状态 3 秒一轮（省资源）
            $sleepSec = $(if ($lastState -eq "off") { 3 } else { 2 })
            Start-Sleep -Seconds $sleepSec
        } catch {
            # 任何单轮异常都不致命：记日志、等 5 秒、继续下一轮（自愈）
            Write-MonitorLog "检测异常: $($_.Exception.Message)"
            Start-Sleep -Seconds 5
        }
    }

    if ($selfExit) {
        # 文件夹被移动/删除：自退时没有活着的组件会再纠正变量，先把我们写的东西清掉
        # （新位置的监控会在秒级内按需重注），再清运行时目录与空壳。
        # 注意竞态：移动瞬间若恰好写日志，Ensure-MonitorDir 会重建旧位置目录。
        # 因此：删 monitor 目录后，若脚本目录只剩空壳（无任何其他文件）→ 一并删除，
        # 确保旧位置完全消失（下次移回时 Move-Item 不会因空壳而嵌套）。
        try { Apply-State "off" } catch {}
        try {
            # 整个目录一起删，心跳自然也在里面；但删之前先把文件删掉，
            # 免得目录删除失败（被占用）时留下一个新鲜心跳骗后续判据。
            try { Remove-ItemSafe $HeartbeatFile } catch {}
            Remove-Item -LiteralPath $MonitorDir -Recurse -Force -ErrorAction SilentlyContinue
            $left = Get-ChildItem -LiteralPath $ScriptDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $left) {
                Remove-Item -LiteralPath $ScriptDir -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    } else {
        Write-MonitorLog "==== 监控退出（收到停止信号）===="
        # 退出前把 off 态落到状态镜像文件。这一步不能省：停止流程由**本进程**执行 Apply-State off
        # （Stop-Monitor 是另一个进程，它只写 stop.flag），所以这里是唯一能把"现在没代理了"
        # 告诉 Git Bash 钩子的地方。漏了它，已开着的 Git Bash 窗口永远不会被清空。
        try { Write-TerminalStateFile "off" } catch {}
        try { Remove-ItemSafe $PidFile } catch {}
        # 心跳必须和 pid 一起删。留着它的后果是：任何一个"监控刚退出"的瞬间，
        # 心跳还是新鲜的（最长 240 秒），于是 Test-MonitorAlive 判"还活着"，
        # 停止流程就打印"监控进程未能停止（请检查是否有别的窗口正在运行它）"——
        # 而监控其实已经退干净了。测试里真出现过这句，用户会以为出了问题。
        try { Remove-ItemSafe $HeartbeatFile } catch {}
        try { Remove-ItemSafe $StopFlag } catch {}
    }
    $mutex.ReleaseMutex()
}

# 查「本用户的」监控进程。**必须按 SID 过滤**：Win32_Process 返回的是全机器所有
# 用户的进程，不过滤会认领别人的监控——状态页报出别人的 PID，
# Start-Monitor 还会把别人的监控当成「旧位置」停掉（写 stop.flag + 强杀）。
function Get-OwnMonitorProcesses {
    if ($env:OS -ne "Windows_NT") { return @() }
    $mySid = ""
    try {
        $mySid = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    } catch {}
    if (-not $mySid) { return @() }
    $all = @()
    try {
        $all = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)
    } catch { return @() }
    $mine = @()
    foreach ($p in $all) {
        if ($p.ProcessId -eq $PID) { continue }
        if (-not ($p.CommandLine -match $MonitorCmdLinePattern)) { continue }
        # SID 必须走 Invoke-CimMethod：Get-CimInstance 返回的是 CimInstance，
        # 上面并没有 GetOwnerSid() 这个方法（它属于旧的 Get-WmiObject 对象）。
        # 直接点方法会抛 "does not contain a method named 'GetOwnerSid'"，被 catch 吞掉后
        # $sid 恒为空 —— 于是**每一个**监控进程都被判成"不是我的"，状态页永远报"未运行"，
        # 而进程明明活着。这是把整段探测变成空操作，比不做过滤更糟。
        # 取不到 SID 时跳过而不是收下：宁可认不出自己的监控（下次启动会再起一份，
        # 单实例锁会挡住），也不要把别人的杀错。
        $sid = ""
        try { $sid = [string](Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop).Sid } catch {}
        if ($sid -and $sid -eq $mySid) { $mine += $p }
    }
    return $mine
}
