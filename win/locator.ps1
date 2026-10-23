# EnvProxy 登录定位器。安装时由 envproxy.ps1 复制到 %LOCALAPPDATA%\EnvProxy\launcher.ps1，
# 开机由 Run 键拉起，负责按日志活跃度找回真正的安装位置。这个文件是模板，请勿手改。
$ErrorActionPreference = "SilentlyContinue"
$reg = "HKCU:\Software\EnvProxy"
$target = (Get-ItemProperty $reg -ErrorAction SilentlyContinue).ScriptPath
# 广播用的 P/Invoke 拼成单行 C# 源码：这是个独立脚本，任何时刻都要能单独跑起来
# （库不在身边、被复制到别处也要能跑），所以不依赖任何外部文件，也不写多行 here-string
# 去和模板的引号规则纠缠。
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
    # 只搜**本地**磁盘：网络盘（映射的 Z: 之类）与已断开的可移动卷会让
    # Get-ChildItem -Recurse 在登录路径上各自等一次传输超时（数秒到数十秒，
    # 视协议与服务器是否回 RST 而定，机器之间差异极大）。
    # 这段搜索排在"启动监控"之前，于是后果是：监控晚启动几十秒到几分钟，
    # 这期间没有人纠正环境变量（上次关机时代理还开着的话，一开机终端就带着死端口全连不上）；
    # 更糟的是搜索中途抛异常（某些失败是终止性的），于是**监控压根不启动**，
    # 而 Run 键、launcher.ps1 全都还在、状态页报"开机自启：已启用"。
    # DisplayRoot 对网络盘是 UNC 路径（\\server\share），据此排除。
    Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.Root -ne $sysRoot } |
        Where-Object { -not $_.DisplayRoot -or ($_.DisplayRoot -notmatch '^\\\\') } |
        ForEach-Object { $roots += @{ Path = $_.Root; Depth = 4 } }

    # 先把所有搜索根的结果汇总，再统一按活跃度排序（与 Mac 侧 locator.sh 同一算法）。
    # 不能"命中第一个根就收工"：那样排序只在一个根内成立，靠前的根（桌面/文稿/下载…）
    # 里放着的陈旧备份会压过其他盘里真正在用的正本——而"活跃度优先"正是
    # "备份目录不会被误选"的唯一依据。
    $candidates = @()
    # 总时限：一个根慢和十个根加起来慢，后果一样，所以限的是**整段搜索**而不是单个根。
    # 超时就放弃搜索、走下面那条"清变量后退出"的既有分支——宁可不接管，
    # 也不能让登录卡住、更不能让监控因为搜索抛异常而不启动。
    $budget = [Diagnostics.Stopwatch]::StartNew()
    foreach ($r in $roots) {
        if ($budget.Elapsed.TotalSeconds -ge 8) { break }
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
    # 只删本机地址，用户自己的配置不动。判据与 Mac 侧同源（值非空且文件存在才算找到）。
    # 清完必须广播：Explorer 在登录时已按旧注册表建好环境块，不广播则它之后起的
    # 每个终端都继续继承死变量。保持静默（登录路径不打扰用户）。
    #
    # 这里为什么自己写注册表、不调 env 层的 Write-UserEnvValues / Remove-UserEnvNames：
    # 这段是**生成的独立脚本**，运行在登录时、安装根已经找不到的场合——那时 env.ps1
    # 根本不在身边，没有库可以依赖。所以它只能自带最小实现。
    # 代价是归属判定这里是简版（只看"像不像本机地址"，没有快照比对）：那种情况下
    # 已经没有任何记录可查，而留下的过期代理必须清掉，两害相权取清理。
    $cleared = $false
    $drop = @()
    foreach ($n in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")) {
        $v = [Environment]::GetEnvironmentVariable($n, "User")
        # 两种回环写法都算"我们写的"：注入端按实际能连上的地址拼 URL，
        # 只绑 ::1 的代理注入的就是 http://[::1]:port。只认 127.0.0.1 会让它清不掉。
        # 这一段在生成出来的定位器里是独立脚本（没有库），所以判据内联。
        # 用 StartsWith 而不是 -like：通配符里 [ ] 是字符类定界符，"http://[::1]:*"
        # 会被当成"http:// 加一个 : 或 1 加 :任意"，判据整个作废。
        if ($v.StartsWith("http://127.0.0.1:") -or $v.StartsWith("http://[::1]:")) { $drop += $n }
    }
    if ([Environment]::GetEnvironmentVariable("NODE_USE_ENV_PROXY", "User") -eq "1") { $drop += "NODE_USE_ENV_PROXY" }
    # 直接写注册表，不走 [Environment]::SetEnvironmentVariable：后者每删一个变量都要同步
    # 等一次 WM_SETTINGCHANGE 广播结束（单个约 11 秒）。这条路径在登录时为用户清残留，
    # 让他为了删 4 个变量干等近一分钟是不可接受的；广播在下面统一发一次即可。
    if ($drop.Count -gt 0) {
        try {
            $ek = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
            if ($null -ne $ek) {
                foreach ($n in $drop) { try { $ek.DeleteValue($n, $false) } catch {} }
                $ek.Close()
                $cleared = $true
            }
        } catch {}
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
# 这段是**生成的独立定位器**：运行时安装根可能已经不在、库也不在身边，
# 所以不能调核心脚本里的函数，SID 过滤只能内联写一遍。
# 不过滤的话，多用户同机时会把别人的监控当成"已在跑"而不再启动自己的。
$__epSid = ""
try { $__epSid = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value } catch {}
$running = @()
foreach ($__epP in (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
    if ($__epP.ProcessId -eq $PID) { continue }
    if (-not ($__epP.CommandLine -match $MonitorCmdLinePattern)) { continue }
    if ($__epSid -ne "") {
        $__epOsid = ""
        # 同 runtime.ps1 里那段：CimInstance 上没有 GetOwnerSid()，必须走 Invoke-CimMethod，
        # 否则这里恒为空 -> 过滤失效。定位器是独立脚本、没有库，所以只能自带这一行。
        try { $__epOsid = [string](Invoke-CimMethod -InputObject $__epP -MethodName GetOwnerSid -ErrorAction Stop).Sid } catch {}
        if ($__epOsid -ne $__epSid) { continue }
    }
    $running += $__epP
}
if (-not $running) {
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden `
        -ArgumentList "-NoProfile","-WindowStyle","Hidden","-ExecutionPolicy","Bypass","-File","`"$target`""
}
