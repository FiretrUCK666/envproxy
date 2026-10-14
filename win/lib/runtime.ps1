# ==============================================================================
#  runtime.ps1 — 运行时层：日志、监控进程管理、监控主循环、自启动与定位器
#  路径常量依赖入口先设好的 $ScriptDir；本层不得自行用 $PSScriptRoot 推算脚本目录。
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

if (-not $target -or -not (Test-Path -LiteralPath $target)) {
    # 记录失效（文件夹被移动/删除过）。先顺手清理旧位置的运行时残留：
    # 覆盖"移动后立刻关机"的场景（监控来不及自退，旧位置可能残留 monitor 目录/空壳）。
    if ($target) {
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
if (-not $target) { exit }

New-Item -Path $reg -Force -ErrorAction SilentlyContinue | Out-Null
Set-ItemProperty -Path $reg -Name "ScriptPath" -Value $target -ErrorAction SilentlyContinue

# 监控进程识别判据：与核心脚本里的 $MonitorCmdLinePattern 保持同一语义。
# 这里必须写字面量——本模板是单引号 here-string，变量在生成时不会被展开，
# 写变量名会让生成的定位器引用一个未定义变量（空模式恒匹配，反而误判"监控已在跑"）。
$MonitorCmdLinePattern = '-File\s+"[^"]*envproxy\.ps1"\s*$'
$running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match $MonitorCmdLinePattern }
if (-not $running) {
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden `
        -ArgumentList "-NoProfile","-WindowStyle","Hidden","-ExecutionPolicy","Bypass","-File","`"$target`""
}
'@
}

# 把定位器写到固定位置，并把 Run 键指向定位器
function Set-AutoRun {
    New-Item -Path $LauncherDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    [System.IO.File]::WriteAllText($LauncherPath, (Get-LauncherContent), (New-Object System.Text.UTF8Encoding($true)))
    $launcherCmd = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $LauncherPath
    Set-ItemProperty -Path $RunKeyPath -Name $RunKeyName -Value $launcherCmd -ErrorAction Stop
}

function Remove-AutoRun {
    Remove-ItemProperty -Path $RunKeyPath -Name $RunKeyName -ErrorAction SilentlyContinue
}

# 记录"脚本当前路径"（监控启动时写入；定位器靠它快速找到脚本）
function Update-ScriptPathRecord {
    New-Item -Path $ScriptPathRegKey -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $ScriptPathRegKey -Name "ScriptPath" -Value $PSCommandPath -ErrorAction SilentlyContinue
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
        $expected = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $LauncherPath
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
# 4. 监控进程管理（PID 文件 + 优雅停止标志 + 兜底强杀）
# ------------------------------------------------------------------------------
# 脚本目录（三阶兜底，任何调用方式都不脆弱）：
#   1) $PSScriptRoot       —— 正常 -File 执行（监控/安装/停止全是这种）
#   2) $PSCommandPath      —— 个别特殊调用
#   3) 当前工作目录        —— 最后兜底

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
# DIVERGE(Mac): macOS 侧等价实现是 `pgrep -f "envproxy\.sh$"`（见 mac/locator.sh），语义相同。
$MonitorCmdLinePattern = '-File\s+"[^"]*envproxy\.ps1"\s*$'

function Get-MonitorProcess {
    # 先按 PID 文件（校验命令行确实是本脚本，防止 PID 被系统复用而误杀他人）
    if (Test-Item $PidFile) {
        try {
            $pid2 = [int]((Read-Text $PidFile).Trim())
            if ($pid2 -ne $PID) {
                $w = Get-CimInstance Win32_Process -Filter "ProcessId=$pid2" -ErrorAction SilentlyContinue
                if ($w -and $w.CommandLine -match $MonitorCmdLinePattern) { return $w }
            }
        } catch {}
    }
    # 再按命令行特征兜底：
    # 监控进程的特征 = 命令行以 -File "...envproxy.ps1" 结尾（不带任何子命令）
    # 这样执行 -Status / -Install 等命令的进程不会被误认，自身也被排除
    return Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $PID -and
            $_.CommandLine -match $MonitorCmdLinePattern
        } | Select-Object -First 1
}

function Start-Monitor([bool]$Force = $false) {
    $existing = Get-MonitorProcess
    if ($existing) {
        # 已有监控在跑：
        #   - Force（安装场景）：无条件重启，保证运行中的监控永远是当前脚本的最新代码
        #   - 非 Force 且路径一致：幂等跳过（重复点安装零副作用）
        #   - 非 Force 且路径不一致：旧位置的监控（文件夹被移动过）：先停掉旧的，再启动新的
        # 注意：用 IndexOf 而非 -like——-like 会把路径里的 [ ] 当通配符误判
        $samePath = ($existing.CommandLine.IndexOf($PSCommandPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
        if (-not $Force -and $samePath) {
            Write-Host "监控进程已在运行（路径一致），跳过启动。" -ForegroundColor Yellow
            return
        }
        Write-Host $(if ($Force) { "正在重启监控以加载当前最新代码..." } else { "检测到旧位置的监控进程，正在迁移到当前路径..." }) -ForegroundColor Yellow
        Stop-Monitor
    }
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden `
        -ArgumentList "-NoProfile","-WindowStyle","Hidden","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`""
    # 启动完必须复查：子进程可能因抢不到单实例互斥而静默退出，
    # 此时再打印"已启动"就是假话。
    Start-Sleep -Seconds 2
    if (Get-MonitorProcess) {
        Write-Host "监控进程已启动。" -ForegroundColor Green
    } else {
        Write-Host "监控进程未能确认运行，请用 4-查看状态 核对（可能是另一个监控占着单实例锁）。" -ForegroundColor Yellow
    }
}

function Stop-Monitor {
    $w = Get-MonitorProcess
    if (-not $w) { Write-Host "监控进程未在运行。" -ForegroundColor Yellow; return }
    # 从目标监控的命令行动态解析它的脚本位置 → 把停止标志写到"它自己"的 monitor 目录。
    # 处理文件夹被移动/复制后新旧位置不一致的场景：让旧位置的监控优雅退出，而非强杀。
    $targetDir = $MonitorDir
    if ($w.CommandLine -match '-File\s+"([^"]*envproxy\.ps1)"') {
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
# 6. 监控主循环（事件驱动 + 双轮确认去抖，无频繁写操作）
# ------------------------------------------------------------------------------
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
        Apply-State $bootState
        $lastState = $bootState
    } catch {
        Write-MonitorLog "启动对齐异常: $($_.Exception.Message)"
    }

    while (-not (Test-Item $StopFlag)) {
        # 自退检测：脚本文件不存在 = 文件夹被移动/删除 → 旧位置不再需要本监控。
        # 静默退出并清理旧位置的一切运行时痕迹（下次开机定位器会从新位置启动）。
        if (-not $PSCommandPath -or -not (Test-Item $PSCommandPath)) { $selfExit = $true; break }
        try {
            $state = Get-CurrentState

            if ($state -ne $lastState) {
                # 状态疑似翻转：连续确认 2 轮才动手，杜绝抖动
                if ($state -eq $pendingState) { $pendingCount++ } else { $pendingState = $state; $pendingCount = 1 }
                if ($pendingCount -ge 2) {
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
