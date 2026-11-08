# ------------------------------------------------------------------------------
# 终端同步
#
# 职责：让"已经开着的终端窗口"在下次回到提示符时跟上代理状态的变化。
#
# 为什么单独成一个库：这块有它自己的完整逻辑（shell 配置文件、钩子块、提示符、
# 执行策略提示），与"进程/日志/监控循环"没有关系。混在 runtime 里时，
# runtime 有 2000 多行、读者找不到边界，而改一处终端同步要在里面翻半天。
#
# 加载顺序在 runtime 之前：主循环会调 Install-ShellProfile 做自愈。
#
# 契约（AGENTS.md「终端同步只照做，不判断」）：
#   - 热路径不起外部进程；
#   - 清除只认"值仍等于我们写下的那个"，没有归属记录时一个都不动；
#   - 钩子永不输出、永不返回非零。
# ------------------------------------------------------------------------------


# ------------------------------------------------------------------------------
# 写入用户配置文件用的底层原语
#
# 这四个函数只服务"改用户 profile"这一件事：探测原文件编码、判断标记行在不在、
# 原子地写回、读生效的执行策略。它们的唯一调用方都在本库，所以住在这一层。
#
# 为什么从 runtime 搬到这里：留在 runtime 会形成 runtime <-> shell 的循环依赖
# （runtime 的主循环要调 Install-ShellProfile，而这里的函数要调 runtime 的）。
# 环的毛病不是跑不起来，是单独读任何一个文件都看不出它依赖什么——
# 门禁 2 专门拦这件事。
#
# 为什么不搬进 base：它们会写文件、读系统策略，不是纯函数。
# base 的定位是"契约常量与纯函数"，塞进去会让它的边界变模糊。
# ------------------------------------------------------------------------------

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
function Test-MarkerPresent([string[]]$Lines, [string]$Marker) {
    $want = $Marker.Trim()
    foreach ($l in $Lines) { if ($l.Trim() -ceq $want) { return $true } }
    return $false
}
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


# 某个落点是不是 Git Bash 的启动文件（决定那一块的内容与钩子行）。
function Test-IsBashrcPath([string]$Path) {
    if (-not $Path) { return $false }
    return ($Path -like "*.bashrc")
}

# 安装/修复：幂等。已经正确就零写入（不动用户的文件 mtime）。
# 多个 profile 逐个处理，任一失败要如实报告是哪一个。


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
        ("            `$__epReg = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(`"" + $UserEnvSubKey + "`", `$false)"),
        ("            `$__epOwn = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(`"" + $OwnedRegSubKey + "`", `$false)"),
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
# 第一句必须先把两个路径落实：base 层的 $MonitorDir / $LogFile 是惰性的
# （加载期不读 $ScriptDir，见那边的注释）。漏了这句，下面六个路径会算成
# "monitor.pid" 这种相对路径——文件散到进程的当前目录去，卸载复检也找不到它们。
$null = Ensure-MonitorPaths
$PidFile    = Join-Path $MonitorDir "monitor.pid"
# "是使用者主动停的"这个意图要落盘。监控进程被外部结束（任务管理器、崩溃）和用户点「停止」
# 在事后完全无法区分：pid 没了、自启动还在，两种情况长得一模一样。
# 不区分就只能二选一：都说"你停的"（用户没停，会以为点错了），或都不说（真停过的人会以为坏了）。
# 所以由执行停止的那一方写下这个标记，监控自己启动时删掉它。
$StopIntentFile = Join-Path $MonitorDir "stopped.intent"
# 版本号缓存：由监控刷新、状态页只读。状态页不许联网（见 Write-VersionCache 的注释）。
$VersionCacheFile = Join-Path $MonitorDir "version.cache"
# 状态快照：监控每轮把自己的结论写在这里，状态页只读。
# 有了它，状态页不必自己重新探测（最坏情况那要 2.7 秒的全端口扫描），
# 而且两边结论同源，不会出现"状态页说没代理、监控还在用 7078"。
$StateSnapshotFile = Join-Path $MonitorDir "state.snapshot"
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


# 监控进程的识别判据（唯一权威处，下面三处引用都指向它）：
# 监控进程的特征 = 命令行以 -File "...envproxy.ps1" 结尾、且不带任何子命令。
# 执行 -Status / -Install / -Stop 的进程带了子命令参数，故不会被误认；调用方自身另行排除。
# 收紧到行尾锚定是为了排除"命令行里恰好含 envproxy 字样"的其他进程（如带 -Command 的诊断调用）。
# 路径两侧的引号可有可无：引号由启动方式决定（自己起的时候常常没加），不是身份的一部分。
# 把引号当成条件会出这种事：认不出已经跑着的监控 → 安装器以为监控没在跑 → 起第二份 →
# 单实例锁又把第二份挡掉 → 于是再也起不来监控，状态页还报"未运行"。判身份要看实质。
# DIVERGE(Mac): macOS 侧等价实现是 `pgrep -f "envproxy\.sh$"`（见 mac/locator.sh），语义相同。
$MonitorCmdLinePattern = '-File\s+"?[^"]*envproxy\.ps1"?\s*$'
# 同一判据的**捕获版本**：语义完全相同，只多一个捕获组——停下来时要按它
# 推算"那个进程自己的 monitor 目录在哪"，跨位置停止信号才写得对。
# 它是上面那条的子集（去掉括号就应当逐字相同），由自检钉住这一点；
# 换成运行时拼正则的话，读代码的人反而看不出这条判据到底长什么样。
$MonitorCmdLineCapture = '-File\s+"?([^"]*?envproxy\.ps1)"?\s*$'

# 判据一：监控自己写下的 pid 文件（它在抢到单实例互斥之后才写）。
# 这是"监控真的在跑"的唯一可靠判据——命令行特征只能说明"有这么个进程"，
# 而刚启动、还没抢到锁就在退出的那个也满足它，拿它当"已启动"就会报假话。


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
    $tpl = @'
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
    # 还原写入端做的百分号转义（见 env 层 ConvertTo-EnvFileValue）。
#
# **两条路径共用这一个函数**：清除路径要拿它比对"值还是不是我们写的"，
# 应用路径要拿它把值真正注入回环境。早先只有清除路径还原了，
# 应用路径直接把 %0A / %25 当字面量注入——含 % 的企业例外清单失效，
# 含换行的值多出一个假域名，而屏幕上完全看不出来。
#
# 顺序与编码相反：先还原换行、再还原百分号（否则 %250A 会被当成换行）。
# 两个候选方案都被实测否掉过，记在这里免得重走：
#   1. 用 bash 的 ${x//模式/替换}：命令替换会把结果尾部的换行全部吃掉；
#   2. 用 sed 的多行 s 命令：续行之后的源码缩进会跟着进替换串。
# 最终用 awk，换行交给 sprintf("%c",10) 生成——源码里没有真换行。
# 只在确实含 % 时才 fork：绝大多数窗口的值不含 %，热路径保持零进程。
_envproxy_gb_unescape() {
    _egu_in="$1"
    case "$_egu_in" in
        *%*)
            printf '%s' "$_egu_in" | awk '{gsub(/%0A/, sprintf("%c",10)); gsub(/%25/,"%"); printf "%s", $0}' ;;
        *)
            printf '%s' "$_egu_in" ;;
    esac
}
_envproxy_gb_clear() {
        [ -n "$_ENVPROXY_GB_STATE" ] || return 0
        [ -r "$_ENVPROXY_GB_STATE" ] || return 0
        _epc_n=""
        _epc_want=""
        while IFS='=' read -r _epc_k _epc_v; do
            case "$_epc_k" in
                __ENVPROXY_OWNED_KEYS__) ;;
                *) continue ;;
            esac
            _epc_n="${_epc_k#owned_}"
            _epc_want="$_epc_v"
            # 还原写入端做的百分号转义（见 env 层 ConvertTo-EnvFileValue）。
            # 不还原的话，带换行的 NO_PROXY 在文件里是 %0A 字面量，与窗口里的真实值
            # 永远不相等 -> 判成"不是我们写的" -> 那个窗口永远清不掉旧代理。
            # 顺序与编码相反：先还原换行、再还原百分号（否则 %250A 会被当成换行）。
            #
            # 两个候选方案都被实测否掉过，记在这里免得重走：
            #   1. 用 bash 的 ${x//模式/替换}：命令替换会把结果尾部的换行全部吃掉，
            #      值变成 localhostcorp.com，比不还原更糟；
            #   2. 用 sed 的多行 s 命令：续行之后的源码缩进会跟着进替换串。
            # 最终用 awk，换行交给 sprintf("%c",10) 生成——源码里没有真换行，
            # 也不依赖续行，缩进怎么排都不影响结果。
            # 只在确实含 % 时才 fork：绝大多数窗口的值不含 %，热路径保持零进程。
            _epc_want=$(_envproxy_gb_unescape "$_epc_want")
            [ -n "$_epc_want" ] || continue
            eval "_epc_cur=\"\${$_epc_n-}\""
            # 两种拼写都要看：只看大写的话，"只有小写还在"的窗口永远清不干净。
            # Git Bash 里 curl 恰恰认小写，那种窗口会一直走一个已经死掉的代理，
            # 而使用者以为"敲回车就跟上了"——状态文件明明写的是断开。
            _epc_lc=""
            case "$_epc_n" in
                __ENVPROXY_LC_CASES_READ__



            esac
            if [ "$_epc_cur" = "$_epc_want" ] || { [ -n "$_epc_lc" ] && [ "$_epc_lc" = "$_epc_want" ]; }; then
                unset "$_epc_n" 2>/dev/null || true
                case "$_epc_n" in
                    __ENVPROXY_LC_CASES_UNSET__



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
                HTTP_PROXY)          _epa_http=$(_envproxy_gb_unescape "$_epa_v") ;;
                # **值要还原转义**：文件里存的是 %0A / %25 形态，
                # 直接注入会让用户拿到字面量 %0A 与 %25。与清除路径共用同一个函数。
                NO_PROXY)            _epa_np=$(_envproxy_gb_unescape "$_epa_v") ;;
                NODE_USE_ENV_PROXY)  _epa_node=$(_envproxy_gb_unescape "$_epa_v") ;;
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
    # 把占位符换成真实清单。
    #
    # 为什么不在 here-string 里直接写：这里是单引号 here-string，不插值；
    # 换成双引号的话整个 bash 脚本里的每个 $ 都要转义，一处漏掉就是一个
    # 静默失效的变量引用——代价远大于收益。
    #
    # 为什么必须换：这段 bash 里原本手抄了三份变量清单（归属键、大小写读取、
    # 大小写清除）。抄写与 $ProxyVarNames 是两处独立的事实，新增第 6 个变量时
    # 漏改任何一处都不会报错：Git Bash 窗口里那个变量永远清不掉（case 落到
    # `*) continue`），而 Windows 主流程一切正常。这正是"同一判断只准有一处
    # 实现"要防的事。
    #
    # 大小写映射只对"有对应小写拼写"的变量生成。Windows 变量名不区分大小写，
    # 但 Git Bash 里 export 出来的名字是逐字节比较的，curl 只认小写那套，
    # 所以这里要显式处理成对的名字；$ProxyVarNames 里没有小写拼写，
    # 对不上的就跳过（NODE_USE_ENV_PROXY 就是这种）。
    $tpl = $tpl.Replace('__ENVPROXY_OWNED_KEYS__', (($ProxyVarNames | ForEach-Object { 'owned_' + $_ }) -join '|'))
    $lcRead = @()
    $lcUnset = @()
    foreach ($n in $ProxyVarNames) {
        $lc = $n.ToLowerInvariant()
        # 必须用 -cne（区分大小写）：PowerShell 的 -eq 对字符串不区分大小写，
        # `'HTTP_PROXY' -eq 'http_proxy'` 返回 True，于是这条映射一条都生成不出来。
        # 实测踩过：生成出来的脚本里只有一个空的 _epc_lc=""，小写那套永远清不掉。
        if ($lc -ceq $n) { continue }
        # 缩进按最长名字对齐：$n 之后补到第 12 列，让 case 分支的右括号对齐。
        # 补到第 20 列：最长的是 NODE_USE_ENV_PROXY（18 字符），再留一格空格。
        $pad = ' ' * [Math]::Max(0, 20 - $n.Length)
        # 塞进格式串必须双写成 {{ }}，而那正是上一版生成出空映射的原因——
        # 一个转义写错，整条 case 分支变成空行，脚本语法还在、功能没了。
        $lcRead  += ('                ' + $n + ')' + $pad + 'eval "_epc_lc=\"' + '${' + $lc + '-}\"" ;;')
        $lcUnset += ('                    ' + $n + ')' + $pad + 'unset ' + $lc + ' 2>/dev/null || true ;;')
    }
    $tpl = $tpl.Replace('                __ENVPROXY_LC_CASES_READ__', ($lcRead -join "`n"))
    $tpl = $tpl.Replace('                    __ENVPROXY_LC_CASES_UNSET__', ($lcUnset -join "`n"))
    # <<<PROMPT_SYNC_END>>>
    return $tpl
}

# 把模板复制到 ~/.envproxy/prompt-sync.sh。
# 判据是内容比对，与 Mac 侧 install_prompt_sync 同一套：模板变了副本才更新。


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


# 把模板复制到 ~/.envproxy/prompt-sync.sh。
# 判据是内容比对，与 Mac 侧 install_prompt_sync 同一套：模板变了副本才更新。
function Install-BashrcPromptSync {
    # 正文来自内嵌模板（见 Get-PromptSyncContent 上方的说明），不再读随包文件。
    $dstDir = Get-ToolHomeDir
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
    for ($i = 0; $i -lt $existing.Count; $i++) {
        $line = $existing[$i]
        if (-not $skipping -and $line.Trim() -ceq $ProfileBlockStart.Trim()) {
            $skipping = $true
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
