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

# 定位器脚本内容（安装时写入固定位置，由本脚本生成，保证一致）
function Get-LauncherContent {
    return @'
# EnvProxy 登录定位器（由 envproxy.ps1 安装时生成，请勿手改）
$ErrorActionPreference = "SilentlyContinue"
$reg = "HKCU:\Software\EnvProxy"
$target = (Get-ItemProperty $reg -ErrorAction SilentlyContinue).ScriptPath
# 广播用的 P/Invoke 不能写成 @'...'@ here-string：外层模板本身就是单引号 here-string，
# 内层再出现行首 '@ 会提前终结外层。这里用反引号转义拼单行 C# 源码。
try {
    $csSrc = "using System;`nusing System.Runtime.InteropServices;`npublic static class EnvProxyNative {`n [DllImport(`"user32.dll`", CharSet = CharSet.Auto)]`n public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);`n}"
    Add-Type -TypeDefinition $csSrc -ErrorAction SilentlyContinue
} catch {}
function Send-LocatorBroadcast {
    try {
        $r = [UIntPtr]::Zero
        [EnvProxyNative]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero,
            "Environment", 0x0002, 3000, [ref]$r) | Out-Null
    } catch {}
}

# 记录必须指向入口脚本本身：指向别处（例如某个库文件）同样算失效。
# 只判"文件在不在"不够——记录写坏了、而那个文件恰好存在时，会一直去启动一个跑不起来的
# 文件，搜索却永远不触发，开机自启动就此静默失效。
if (-not $target -or -not (Test-Path -LiteralPath $target) -or ((Split-Path -Leaf $target) -ne "envproxy.ps1")) {
    # 记录失效（文件夹被移动/删除过，或记录指向的不是入口脚本）。先顺手清理旧位置的运行时残留：
    # 覆盖"移动后立刻关机"的场景（监控来不及自退，旧位置可能残留 monitor 目录/空壳）。
    if ($target -and -not (Test-Path -LiteralPath $target)) {
        $oldDir = Split-Path -Parent $target
        Remove-Item -LiteralPath (Join-Path $oldDir "monitor") -Recurse -Force -ErrorAction SilentlyContinue
        $left = Get-ChildItem -LiteralPath $oldDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $left) { Remove-Item -LiteralPath $oldDir -Force -ErrorAction SilentlyContinue }
    }
    # 分层自动搜索新位置
    #   用户常用位置深搜 6 层；其他磁盘根浅搜 4 层。
    #   注意：不从用户目录根整体递归——AppData 等大目录会因权限问题中断遍历。
    $roots = @(
        @{ Path = "$env:USERPROFILE\Desktop";   Depth = 6 },
        @{ Path = "$env:USERPROFILE\Documents"; Depth = 6 },
        @{ Path = "$env:USERPROFILE\Downloads"; Depth = 6 },
        @{ Path = "$env:USERPROFILE\OneDrive";  Depth = 6 },
        @{ Path = "$env:USERPROFILE\.config";   Depth = 6 }
    )
    $sysRoot = "$($env:SystemDrive)\"
    Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.Root -ne $sysRoot } |
        ForEach-Object { $roots += @{ Path = $_.Root; Depth = 4 } }

    # 先把所有搜索根的结果汇总，再统一按活跃度排序（与 Mac 侧 locator.sh 同一算法）。
    # 不能"命中第一个根就收工"：那样排序只在一个根内成立，靠前的根（桌面/文稿/下载…）
    # 里放着的陈旧备份会压过其他盘里真正在用的正本——而"活跃度优先"正是
    # "备份目录不会被误选"的唯一依据。
    $candidates = @()
    foreach ($r in $roots) {
        $candidates += @(Get-ChildItem -LiteralPath $r.Path -Recurse -Depth $r.Depth -Filter "envproxy.ps1" -ErrorAction SilentlyContinue)
    }
    if ($candidates.Count -gt 0) {
        # 活跃度排序：monitor\monitor.log 最近写入的优先（无日志的排最后），
        # 同活跃度再看脚本本身的修改时间。这样"真正在用的项目"永远胜出，
        # 用户复制的备份（日志陈旧或没有日志）不会被误选。
        foreach ($c in $candidates) {
            $logPath = Join-Path (Split-Path -Parent $c.FullName) "monitor\monitor.log"
            $logTime = if (Test-Path -LiteralPath $logPath) { ([System.IO.FileInfo]$logPath).LastWriteTime } else { [datetime]::MinValue }
            $c | Add-Member -NotePropertyName EnvLogTime -NotePropertyValue $logTime -Force
        }
        $target = ($candidates | Sort-Object EnvLogTime, LastWriteTime -Descending | Select-Object -First 1).FullName
    }
}
if (-not $target -or -not (Test-Path -LiteralPath $target)) {
    # 兜底：安装根找不到了（记录为空，或搜索后仍无可用候选、$target 留着旧的死路径），
    # 没有活着的组件会再纠正变量——把我们写的东西清掉，新终端不再读到过期代理。
    # 只删本机地址（归属判定），用户自己的配置不动。判据与 Mac 侧同源（值非空且文件存在才算找到）。
    # 清完必须广播：Explorer 在登录时已按旧注册表建好环境块，不广播则它之后起的
    # 每个终端都继续继承死变量。保持静默（登录路径不打扰用户）。
    $cleared = $false
    foreach ($n in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")) {
        $v = [Environment]::GetEnvironmentVariable($n, "User")
        if ($v -like "http://127.0.0.1:*") {
            [Environment]::SetEnvironmentVariable($n, $null, "User")
            $cleared = $true
        }
    }
    if ([Environment]::GetEnvironmentVariable("NODE_USE_ENV_PROXY", "User") -eq "1") {
        [Environment]::SetEnvironmentVariable("NODE_USE_ENV_PROXY", $null, "User")
        $cleared = $true
    }
    if ($cleared) { Send-LocatorBroadcast }
    exit
}

# 注册表上的 New-Item -Force 不是"已存在就跳过"，而是**清空重建**：
# 连带删掉里面的 Backup 快照，那是卸载时还原使用者原值的唯一依据。
# 所以只在键不存在时才建。
if (-not (Test-Path -LiteralPath $reg)) { New-Item -Path $reg -Force -ErrorAction SilentlyContinue | Out-Null }
Set-ItemProperty -Path $reg -Name "ScriptPath" -Value $target -ErrorAction SilentlyContinue

# 监控进程识别判据：与核心脚本里的 $MonitorCmdLinePattern 保持同一语义。
# 这里必须写字面量——本模板是单引号 here-string，变量在生成时不会被展开，
# 写变量名会让生成的定位器引用一个未定义变量（空模式恒匹配，反而误判"监控已在跑"）。
# 引号可有可无：引号是启动方式决定的，不是身份的一部分。
$MonitorCmdLinePattern = '-File\s+"?[^"]*envproxy\.ps1"?\s*$'
$running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match $MonitorCmdLinePattern }
if (-not $running) {
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden `
        -ArgumentList "-NoProfile","-WindowStyle","Hidden","-ExecutionPolicy","Bypass","-File","`"$target`""
}
'@
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
        # 行尾与首尾空白不比：落盘的行尾与源码里 here-string 的行尾
        # 不必逐字节相同，比"生成出来的代码"是否一致就够了。
        $want = (Get-LauncherContent) -replace "`r`n", "`n"
        $have = (Read-Text $LauncherPath) -replace "`r`n", "`n"
        return ($have.Trim() -eq $want.Trim())
    } catch { return $false }
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
    # 包 prompt 的三条约束：
    #   a) 必须记住原函数并原样调用，否则 Oh My Posh / Starship / 自定义提示符全被顶掉；
    #   b) 同步逻辑整体 try/catch 包死——prompt 里抛异常会让整个提示符渲染失败；
    #   c) 不能重复包装（重复 source 会把 prompt 包成洋葱），用哨兵变量挡住。
    $names = ($ProxyVarNames | ForEach-Object { "'$_'" }) -join ', '
    $body = @(
        $ProfileBlockStart
        '# EnvProxy: 让已经开着的窗口跟着代理状态走（本块由安装程序写入，卸载时整块移除）',
        '# 手动接管：$env:ENVPROXY_TERM = "off" 固定直连；Remove-Item Env:ENVPROXY_TERM 恢复自动',
        'try {',
        ("    `$__epNames = @(" + $names + ")"),
        '    $__epSync = {',
        '        try {',
        '            $__epReg = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $false)',
        '            $__epOwn = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\EnvProxy\Owned", $false)',
        '            if ($null -ne $__epReg) {',
        '                if ($env:ENVPROXY_TERM -eq "off") {',
        '                    # 固定直连：只清"确实是我们写下的那些值"。值是我们写的才清，',
        '                    # 用户自己设的（哪怕是本机地址）一律不动——这是 README 的承诺。',
        '                    foreach ($__epN in $__epNames) {',
        '                        $__epCur = [Environment]::GetEnvironmentVariable($__epN, "Process")',
        '                        $__epOurs = if ($null -ne $__epOwn) { $__epOwn.GetValue($__epN, $null) } else { $null }',
        '                        if (($null -ne $__epOurs) -and ($__epCur -eq [string]$__epOurs)) {',
        '                            [Environment]::SetEnvironmentVariable($__epN, [NullString]::Value, "Process")',
        '                        }',
        '                    }',
        '                } else {',
        '                    # 自动跟随：注册表有值就注入；没有值时只清我们自己写下的那些——',
        '                    # 判据是归属记录里有这个名字且当前值相等，用户自己设的一律不动。',
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
        '                            # 归属记录不存在（升级上来的老安装还没写过它）。',
        '                            # 这里**不清任何东西**：没有记录就没有判据，猜就要猜错——',
        '                            # 使用者自己起在任意端口的 mitmproxy 长得和我们的完全一样，',
        '                            # 按形状猜只能二选一，必然误删其中一类。',
        '                            # 宁可留一个过期值（下次 on 会覆盖；下次 off 时有记录就能清），',
        '                            # 也不替他删掉自己的配置。',
        '                            # 与 Mac 侧 write_off_sentinel 的"文件里没有可解析端口就退化成 no-op"',
        '                            # 是同一条原则：判不了就不动。',
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
        # 无 BOM：严格 UTF-8 能解就是 UTF-8，否则按系统 ANSI。
        # 不能用 Encoding::Default——它在 .NET Framework 上是 ANSI、在 .NET Core 上是 UTF-8。
        try {
            $strict = New-Object System.Text.UTF8Encoding($false, $true)
            [void]$strict.GetString($b)
        } catch {
            try { return [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage) } catch {}
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
function Test-MarkerPresent([string[]]$Lines, [string]$Marker) {
    foreach ($l in $Lines) { if ($l -ceq $Marker) { return $true } }
    return $false
}

function Test-ProfileBlockPaired([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $lines = @(Read-ProfileLines $Path)
    $s = -1; $e = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -ceq $ProfileBlockStart -and $s -lt 0) { $s = $i }
        if ($lines[$i] -ceq $ProfileBlockEnd -and $e -lt 0) { $e = $i }
    }
    return (($s -ge 0) -and ($e -gt $s))
}

# 读回比对：块内容与当前版本是否一致（升级后不一致要重写）。
function Test-ProfileBlockCurrent([string]$Path) {
    if (-not (Test-ProfileBlockPaired $Path)) { return $false }
    $lines = @(Read-ProfileLines $Path)
    $s = -1; $e = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -ceq $ProfileBlockStart -and $s -lt 0) { $s = $i }
        if ($lines[$i] -ceq $ProfileBlockEnd -and $e -lt 0) { $e = $i }
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
        $enc = New-Object System.Text.UTF8Encoding($false)
        $hasBom = $false
        if (Test-Path -LiteralPath $Path) {
            try {
                $old = [System.IO.File]::ReadAllBytes($Path)
                if ($old.Length -ge 3 -and $old[0] -eq 0xEF -and $old[1] -eq 0xBB -and $old[2] -eq 0xBF) {
                    $hasBom = $true
                    $enc = New-Object System.Text.UTF8Encoding($true)
                } elseif ($old.Length -ge 2 -and $old[0] -eq 0xFF -and $old[1] -eq 0xFE) {
                    $enc = New-Object System.Text.UnicodeEncoding($false, $true)
                } elseif ($old.Length -ge 2 -and $old[0] -eq 0xFE -and $old[1] -eq 0xFF) {
                    $enc = New-Object System.Text.UnicodeEncoding($true, $true)
                } else {
                    # 没有 BOM：可能是 UTF-8，也可能是系统 ANSI（中文系统即 GBK）。
                    # 用严格 UTF-8 解码试探——能完整解出来就当 UTF-8，否则按 ANSI 处理。
                    # 注意不能用 [System.Text.Encoding]::Default 拿 ANSI：
                    # 那在 .NET Framework(5.1) 上是 ANSI，在 .NET Core(pwsh 7) 上却是 UTF-8，
                    # 同一段代码两个宿主行为不同。而这文件的读者可能是任意一个宿主，
                    # 所以必须显式按系统代码页（ACP）取，两个宿主才一致。
                    try {
                        $strict = New-Object System.Text.UTF8Encoding($false, $true)
                        [void]$strict.GetString($old)
                    } catch {
                        try {
                            $acp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
                            $enc = [System.Text.Encoding]::GetEncoding($acp)
                        } catch {
                            # 取不到 ANSI 就宁可不动：写坏用户配置比不写更糟。
                            return $false
                        }
                    }
                }
            } catch {}
        }
        [System.IO.File]::WriteAllLines($tmp, $Lines, $enc)
        if (Test-Path -LiteralPath $Path) {
            # 改用户文件之前先备份：改坏了还能手工还原。
            # 与 Mac 侧改 rc 前留 *.envproxy.bak 是同一规矩（双端对等）。
            try { Copy-Item -LiteralPath $Path -Destination ($Path + ".envproxy.bak") -Force -ErrorAction SilentlyContinue } catch {}
            Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
        } else {
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
    return @($paths | Where-Object { $_ })
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

function Install-OneShellProfile([string]$path) {
    if (-not $path) { return @{ Ok = $false; Reason = 'no-profile'; Path = '' } }
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
                    if ($existing[$i] -ceq $ProfileBlockStart -and $s -lt 0) { $s = $i }
                    if ($existing[$i] -ceq $ProfileBlockEnd -and $e -lt 0) { $e = $i }
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
    $s = -1; $e = -1
    for ($i = 0; $i -lt $existing.Count; $i++) {
        if ($existing[$i] -ceq $ProfileBlockStart -and $s -lt 0) { $s = $i }
        if ($existing[$i] -ceq $ProfileBlockEnd -and $e -lt 0) { $e = $i }
    }
    $keep = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $existing.Count; $i++) {
        if ($i -ge $s -and $i -le $e) { continue }
        [void]$keep.Add($existing[$i])
    }
    # 摘完若只剩结尾空行，一并收掉，别给用户留个空白尾巴
    while ($keep.Count -gt 0 -and [string]::IsNullOrWhiteSpace($keep[$keep.Count - 1])) {
        $keep.RemoveAt($keep.Count - 1)
    }
    if (-not (Write-TextAtomic -Path $path -Lines @($keep))) {
        return @{ Ok = $false; Reason = 'write-failed'; Path = $path }
    }
    if ((Test-MarkerPresent @(Read-ProfileLines $path) $ProfileBlockStart)) {
        return @{ Ok = $false; Reason = 'verify-failed'; Path = $path }
    }
    return @{ Ok = $true; Reason = 'removed'; Path = $path }
}

# 执行策略检查：Restricted 下 profile 根本不执行且无提示。
# 静默失败最糟——用户以为在同步，实际一次都没同步过。
function Get-ProfileExecutionPolicyWarning {
    try {
        $p = Get-ExecutionPolicy -Scope CurrentUser
        if ($p -eq 'Restricted' -or $p -eq 'AllSigned') {
            return ("当前执行策略是 $p，PowerShell 不会运行配置文件（$PROFILE）——" +
                    "终端同步不会生效。改成 RemoteSigned 即可：Set-ExecutionPolicy RemoteSigned -Scope CurrentUser")
        }
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
function Get-MonitorProcess {
    $fromFile = Get-MonitorProcessFromPidFile
    if ($fromFile) { return $fromFile }
    return Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $PID -and
            $_.CommandLine -match $MonitorCmdLinePattern
        } | Select-Object -First 1
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
            Write-Host "监控进程已在运行（路径一致），跳过启动。" -ForegroundColor Yellow
            return $true
        }
        Write-Host $(if ($Force) { "正在重启监控以加载当前最新代码..." } else { "检测到旧位置的监控进程，正在迁移到当前路径..." }) -ForegroundColor Yellow
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
        Write-Host "监控进程已启动。" -ForegroundColor Green
        return $true
    }
    # 起不来要分清是"另一个副本占着锁"还是"根本没起来"：前者该去别处收摊，后者该查杀软与日志。
    # 说清楚另一份在哪，使用者才知道该进哪个文件夹——只说"可能被占着"，等于把排查推回去。
    $other = $null
    try {
        $other = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match $MonitorCmdLinePattern } |
            Select-Object -First 1
    } catch {}
    if ($other) {
        $otherPath = ""
        if ($other.CommandLine -match '-File\s+"?([^"]*?envproxy\.ps1)"?\s*$') { $otherPath = $Matches[1] }
        $otherDir = if ($otherPath) { Split-Path -Parent (Split-Path -Parent $otherPath) } else { "" }
        Write-Host ("监控进程未能确认运行：另一个副本的监控正占着单实例锁（{0}）。" -f $(if ($otherDir) { $otherDir } else { $otherPath })) -ForegroundColor Yellow
        Write-Host "      还用那份就继续用它；不用了，进上面那个文件夹打开菜单选 一键恢复，再回到这里选 安装。" -ForegroundColor Yellow
    } else {
        Write-Host "监控进程未能确认运行：这次没看到别的副本，多半是启动被拦或启动过程出错。" -ForegroundColor Yellow
        Write-Host "      再选一次 安装 / 修复；仍然不行就看 查看状态 和 monitor.log 最近几行。" -ForegroundColor Yellow
    }
    return $false
}

function Stop-Monitor {
    $w = Get-MonitorProcess
    if (-not $w) { Write-Host "监控进程未在运行。" -ForegroundColor Yellow; return }
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
    # 跨位置停止的零残留：若停止标志写在"别的" monitor 目录、且该目录已空
    # （旧监控退出时已清理自己的 pid/flag），则把这个重建的空目录一并移除
    if ($targetDir -ne $MonitorDir) {
        $left = Get-ChildItem -LiteralPath $targetDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $left) {
            Remove-Item -LiteralPath $targetDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (Get-MonitorProcess) {
        Write-Host "监控进程未能停止（请检查是否有别的窗口正在运行它）。" -ForegroundColor Yellow
    } else {
        Write-Host "监控进程已停止。" -ForegroundColor Green
    }
}

# ------------------------------------------------------------------------------
# 5. 日志（只记状态翻转，不刷屏；超过 200KB 自动截断）
# ------------------------------------------------------------------------------
$LogFile = Join-Path $MonitorDir "monitor.log"

function Write-MonitorLog([string]$msg) {
    try {
        Ensure-MonitorDir
        $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
        # 共享写模式（FileShare.ReadWrite）：多进程追加写入互不阻塞，零锁脆弱点。
        # 改用共享文件流后，任何进程（含监控自身截断）互不阻塞，零锁脆弱点。
        $fs = [System.IO.File]::Open($LogFile, [System.IO.FileMode]::Append,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($line + "`r`n")
            $fs.Write($bytes, 0, $bytes.Length)
        } finally { $fs.Dispose() }
        # 体积上限：超过 200KB 截断为最近 200 行（黑匣子保留近期窗口，永远不会无限增长）
        # 截断同样用共享模式；万一失败（极端外部锁），静默跳过、下次再试——绝不中断监控
        # 注意：读取必须显式 UTF8 —— 默认按 ANSI 读会乱码，且截断时把乱码写回损坏日志
        $fi = New-Object System.IO.FileInfo($LogFile)
        if ($fi.Exists -and $fi.Length -gt 200KB) {
            $keep = [System.IO.File]::ReadAllLines($LogFile, [System.Text.Encoding]::UTF8) | Select-Object -Last 200
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
    try { Write-Text -Path $PidFile -Text ([string]$PID) } catch {}
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
        # 自退检测：脚本文件不存在 = 文件夹被移动/删除 → 旧位置不再需要本监控。
        # 静默退出并清理旧位置的一切运行时痕迹（下次开机定位器会从新位置启动）。
        if (-not $ScriptPath -or -not (Test-Item $ScriptPath)) { $selfExit = $true; break }
        try {
            $state = Get-CurrentState

            if ($state -eq "unknown") {
                # 这一轮不知道（端口枚举失败）：沿用上一状态，不动环境变量，
                # 也不计入去抖——把"没读到"当成"没在翻墙"会删掉用户的代理变量。
                Write-MonitorLog "端口枚举失败 -> 本轮沿用上一状态，不动环境变量"
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
                        Write-MonitorLog "已自动更新终端同步钩子（配置块内容与当前版本不一致）"
                    } elseif ($pr.Reason -eq 'unpaired') {
                        Write-MonitorLog ("终端同步钩子未更新：配置文件里的标记不成对，未改动它：" + $pr.Path)
                    }
                } catch {}
                # 变量自检：Apply-State 只在状态翻转时动手，稳态下它永远不会被调用，
                # 于是"别的东西改坏了变量"没人纠正。这里按同一周期做一次整表核对：
                # on 态补齐缺失项，off 态把残留收干净——判据与删除侧同一套，
                # 幂等（齐了就零写入、零广播）。只核对我们本该持有的那几个，
                # 用户自己设的、与本工具无关的变量不受影响。
                if ($lastState -eq "off") {
                    if (Test-ProxyVarsPresent) {
                        Remove-UserEnvVars
                        Broadcast-EnvironmentChange
                        Write-MonitorLog "检测到代理变量残留 -> 已回收，恢复直连"
                    }
                } else {
                    # 自愈写入后也要广播：不广播的话已经运行的资源管理器/程序仍是旧环境，
                    # 与 Apply-State 就成了两套行为。写入成功才广播。
                    # 先判 "on:" 前缀：启动对齐若抛过异常，$lastState 仍是 $null，
                    # 直接 Substring 会抛异常、白记一条"检测异常"。
                    if ($lastState -and $lastState.StartsWith("on:")) {
                        if (Sync-UserEnvVars $lastState.Substring(3)) { Broadcast-EnvironmentChange }
                    }
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
            Remove-Item -LiteralPath $MonitorDir -Recurse -Force -ErrorAction SilentlyContinue
            $left = Get-ChildItem -LiteralPath $ScriptDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $left) {
                Remove-Item -LiteralPath $ScriptDir -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    } else {
        Write-MonitorLog "==== 监控退出（收到停止信号）===="
        try { Remove-ItemSafe $PidFile } catch {}
        try { Remove-ItemSafe $StopFlag } catch {}
    }
    $mutex.ReleaseMutex()
}
