# ==============================================================================
#  ops.ps1 — 动作层：菜单背后的安装、停止、卸载、状态编排
#  把下面各层拼成使用者点得到的行为。
# ==============================================================================

# ------------------------------------------------------------------------------
# 7. 子命令实现
# ------------------------------------------------------------------------------
function Install-EnvProxy {
    Write-Host "======== EnvProxy 安装 ========" -ForegroundColor Cyan
    if (Test-IsElevated) { Write-Host "当前是管理员身份：动的将是管理员的配置，日常使用请用普通终端重做一遍。" -ForegroundColor Yellow }
    Set-AutoRun
    # 写完必须读回：装没装上由复读决定，不由"我调用了写入"决定（与自愈路径同一条规矩）。
    # 杀软拦 Run 键是真实发生过的事，那时不能报"已写入"。
    $runHave = $null
    try { $runHave = (Get-ItemProperty $RunKeyPath -ErrorAction SilentlyContinue).$RunKeyName } catch {}
    if (($runHave -eq (Get-LauncherCommand)) -and (Test-LauncherCurrent)) {
        Write-Host "[1/3] 开机自启动：已写入（固定定位器架构）" -ForegroundColor Green
    } else {
        Write-Host "[1/3] 开机自启动：写入后读回不一致，可能被杀软拦住。" -ForegroundColor Yellow
        Write-Host "      请检查杀软拦截，或再打开一次菜单选 安装；仍然不行就把它加进白名单。" -ForegroundColor Yellow
    }
    Update-ScriptPathRecord
    # 先快照用户原值，再动任何东西：监控一启动就会在几秒内自愈、把代理变量写进去，
    # 那时再快照，存下的就是"我们写下的值"而不是用户原值，卸载还原会留下我们的条目。
    # （快照只记一次；已经存在时这里是无副作用的空操作。）
    Snapshot-PrevEnv
    # 装没装上由返回值决定，不由"我调用过启动"决定（与自启动项读回复检同一条规矩）。
    if (Start-Monitor -Force:$true) {
        Write-Host "[2/3] 监控进程：已启动" -ForegroundColor Green
    } else {
        Write-Host "[2/3] 监控进程：未能确认运行，请打开菜单选 查看状态 核对。" -ForegroundColor Yellow
        Write-Host "      一台电脑只留一份安装；另一个副本的监控在跑时会占住单实例锁。" -ForegroundColor Yellow
    }
    # 立即对齐环境变量状态：有代理 → 注入；无代理 → 清理残留死变量
    # （不等监控的双轮去抖，"安装"即"一键修复"）
    $state = Get-CurrentState
    Apply-State $state
    if ($state -eq "unknown") {
        # 端口枚举失败：这一轮不知道状态，一个变量都没动——不能说"已校正"。
        Write-Host "[3/3] 环境变量：端口枚举失败，这一轮不知道状态，未做任何改动。" -ForegroundColor Yellow
    } else {
        Write-Host "[3/3] 环境变量：已按当前状态校正" -ForegroundColor Green
    }
    Start-Sleep -Seconds 1
    Write-Host ""
    Show-Status
    Write-Host ""
    Write-Host "提示：之后【新打开】的终端/程序自动获得代理；" -ForegroundColor Yellow
    Write-Host "      已经开着的旧窗口不会自动变化，重开一个即可。" -ForegroundColor Yellow
}

function Uninstall-EnvProxy([bool]$Purge = $false) {
    Write-Host "======== EnvProxy 卸载（一键恢复原状）========" -ForegroundColor Cyan
    if (Test-IsElevated) { Write-Host "当前是管理员身份：动的将是管理员的配置，日常使用请用普通终端重做一遍。" -ForegroundColor Yellow }
    Stop-Monitor
    Remove-AutoRun
    # 顺序是定的：先清我们写的值，再按快照还用户原值。
    # 反过来会把用户原值里与默认集重合的项（如 localhost）当成"我们加的"剥掉，快照保护落空。
    # 走 Apply-State 而不是裸调 Remove-UserEnvVars：拿写变量锁、判据与写入同源、写完广播。
    # 裸调会绕过锁，与监控自愈并发时可能留下半套变量。
    Apply-State "off"
    # 复检用的期望值先抄一份：Restore 会删掉快照键，抄晚了就没处可查了。
    # 有快照的名字以"与快照一致"为准（用户原值里若含 localhost 这类与默认集重合的项，
    # 它既不是残留也不能删）；没快照的名字才按"有无我们的痕迹"判。
    $restoredWant = @{}
    foreach ($n in $ProxyVarNames) {
        $bv = (Get-ItemProperty -Path $PrevEnvRegKey -Name $n -ErrorAction SilentlyContinue).$n
        if ($null -ne $bv) { $restoredWant[$n] = [string]$bv }
    }
    # 先按快照还用户原值，再清注册表键（快照键在该键之下，顺序不能反）。
    Restore-PrevEnv
    # 还完再广播一次：运行中的进程按旧环境块活着，不广播它们就继续走死代理——"无需重启"靠这一次广播。
    Broadcast-EnvironmentChange
    Remove-Item -LiteralPath $ScriptPathRegKey -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $LauncherPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $LauncherDir -Force -ErrorAction SilentlyContinue
    # 日志去留：黑匣子保留还是彻底删除？
    #   - 交互模式（菜单里选 一键恢复）：询问用户，默认保留
    #   - 自动化模式（-Uninstall -Purge）：直接彻底删除，不询问
    $removeLog = $Purge
    if (-not $Purge) {
        try {
            $choice = Read-Host "历史日志 monitor\monitor.log 是否保留？[Y] 保留（默认） / [N] 彻底删除"
            if ($choice -match '^[Nn]') { $removeLog = $true }
        } catch {
            # 无交互环境（管道/后台调用）：安全默认 = 保留日志
            $removeLog = $false
        }
    }
    if ($removeLog) {
        # 彻底清除：连历史日志一起删（黑匣子也不要了）
        # 刚杀掉的监控进程其文件锁可能还没释放：删三次再下定论，删不掉就由末尾的复检如实报告。
        for ($i = 0; $i -lt 3 -and (Test-Item $MonitorDir); $i++) {
            Remove-Item -LiteralPath $MonitorDir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Item $MonitorDir) { Start-Sleep -Milliseconds 500 }
        }
    } else {
        # 保留历史日志（黑匣子，便于日后排查），只删运行时临时文件
        Remove-ItemSafe $PidFile
        Remove-ItemSafe $StopFlag
        # 若无日志可留（从未运行过），空目录一并移除，不留任何痕迹
        $hasContent = Get-ChildItem -LiteralPath $MonitorDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $hasContent) {
            Remove-Item -LiteralPath $MonitorDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    # 卸载验尸：确保监控彻底死透——否则它的自愈机制会在下一个自查周期（约 60–90 秒）重建自启动（复活）
    # 这里再查一次并强杀兜底，堵死"卸载后复活"的唯一理论路径
    $ghost = Get-MonitorProcess
    if ($ghost) {
        Stop-Process -Id $ghost.ProcessId -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
    # 卸载末尾回读复检：上面每一步都可能静默失败，定论必须由复读结果决定。
    # DIVERGE(Win): 复检项按平台映射——Run 键对应 Mac 的 plist，
    # 注册表变量对应 proxy.env，其余同源。
    $dirty = @()
    try { $null = Get-ItemPropertyValue -Path $RunKeyPath -Name $RunKeyName -ErrorAction Stop; $dirty += "开机自启动项仍在" } catch {}
    if (Test-Item $LauncherPath) { $dirty += "定位器文件仍在" }
    if (Test-Item $LauncherDir) { $dirty += "定位器目录仍在" }
    if (Test-Item $ScriptPathRegKey) { $dirty += "路径记录仍在" }
    if ((Test-Item $PidFile) -or (Test-Item $StopFlag)) { $dirty += "监控运行时文件仍在" }
    # 变量复检不用整表判据：有快照的名字必须与快照一致（用户原值含重合项也算干净），
    # 只有没快照的名字才按"有无我们的痕迹"判——否则正确的还原会被误报成残留。
    $varsClean = $true
    foreach ($n in $ProxyVarNames) {
        $cur = [Environment]::GetEnvironmentVariable($n, "User")
        if ($restoredWant.ContainsKey($n)) { if ($cur -ne $restoredWant[$n]) { $varsClean = $false } }
        elseif (Test-IsOwnedProxyValue $n $cur) { $varsClean = $false }
    }
    if (-not $varsClean) { $dirty += "代理变量仍在" }
    if (Get-MonitorProcess) { $dirty += "监控进程仍在" }
    if ($removeLog -and (Test-Item (Join-Path $MonitorDir "monitor.log"))) { $dirty += "历史日志未能删除" }
    if ($dirty.Count -eq 0) {
        Write-Host "[完成] 监控已停、自启动已删、定位器已清、代理变量已清除。" -ForegroundColor Green
        if ($removeLog) {
            Write-Host "        历史日志已一并彻底删除。" -ForegroundColor Green
        } else {
            Write-Host "        历史日志保留在 monitor\monitor.log（黑匣子，供日后排查）。" -ForegroundColor Yellow
        }
        Write-Host "        电脑已恢复到安装前的状态。新开终端即直连；已经开着的旧窗口重开一个。" -ForegroundColor Green
    } else {
        Write-Host ("[未完成] 以下残留请手动处理：{0}" -f ($dirty -join "；")) -ForegroundColor Yellow
        Write-Host "        可再打开菜单选 一键恢复，或手动删除上述位置。" -ForegroundColor Yellow
    }
}

function Show-Status {
    Write-Host "======== EnvProxy 状态 ========" -ForegroundColor Cyan

    $m = Get-MonitorProcess
    if ($m) { Write-Host ("监控进程 : 运行中 (PID {0})" -f $m.ProcessId) -ForegroundColor Green }
    else    { Write-Host "监控进程 : 未运行" -ForegroundColor Yellow }

    $run = (Get-ItemProperty $RunKeyPath -ErrorAction SilentlyContinue).$RunKeyName
    if ($run) { Write-Host "开机自启 : 已启用" -ForegroundColor Green }
    else      { Write-Host "开机自启 : 未启用" -ForegroundColor Yellow }

    # 状态页只做快扫：全端口批量探测约 1 秒，放在只读的状态显示里太重。
    $port = Get-ActiveProxyPort -FullScan:$false
    if ($port) {
        Write-Host ("翻墙代理 : 已开启（本地端口 {0} 监听中）" -f $port) -ForegroundColor Green
    } elseif ($script:PortEnumerationFailed) {
        # 端口枚举读不出来 = 这一轮不知道有没有代理在运行，不能说成"没有代理"。
        Write-Host "翻墙代理 : 读不出来（端口枚举失败，这一轮不知道有没有代理在运行）" -ForegroundColor Yellow
    } else {
        Write-Host "翻墙代理 : 未检测到（当前无翻墙代理在运行）" -ForegroundColor Yellow
    }

    $cur = Get-EnvProxyValue
    if ($cur) { Write-Host ("代理变量 : 已注入 ({0})" -f $cur) -ForegroundColor Green }
    else      { Write-Host "代理变量 : 无（直连状态）" -ForegroundColor DarkGray }

    # 只读提示：系统代理是浏览器的世界，不是我们写的，但用户常把它的毛病算到我们头上。
    # 若它指向本机死端口，浏览器全挂而终端正常——提醒一句，绝不动它。
    # DIVERGE(Win): Mac 侧用 scutil --proxy 同语义，待真机回齐。
    try {
        $sp = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction Stop
        if (($sp.ProxyEnable -eq 1) -and ($sp.ProxyServer -match "127\.0\.0\.1:(\d+)")) {
            $spPort = [int]$Matches[1]
            $spAlive = $false
            $tc = $null
            try {
                $tc = New-Object Net.Sockets.TcpClient
                $iar = $tc.BeginConnect("127.0.0.1", $spPort, $null, $null)
                if ($iar.AsyncWaitHandle.WaitOne(800)) { $tc.EndConnect($iar); $spAlive = $true }
            } catch {} finally {
                try { if ($tc) { $tc.Close() } } catch {}
            }
            if (-not $spAlive) {
                Write-Host ("系统代理 : 疑似残留（指向本机死端口 {0}，非本工具写入）。" -f $sp.ProxyServer) -ForegroundColor Yellow
                Write-Host "      浏览器打不开先检查它：系统设置 → 网络 → 代理，或把翻墙软件断开重进一次。" -ForegroundColor Yellow
            }
        }
    } catch {}

    # 版本信息（只读：查不到只提示，不断言、不写文件、不提问）
    $localVer = Get-LocalVersion
    if ($localVer) { Write-Host ("本地版本 : v{0}" -f $localVer) -ForegroundColor Green }
    else           { Write-Host "本地版本 : 未知" -ForegroundColor Yellow }
    $remoteVer = Get-RemoteVersion
    if ($remoteVer) {
        Write-Host ("最新版本 : {0}" -f $remoteVer.Tag) -ForegroundColor Green
        if (Test-DevCopy) {
            Write-Host "更新状态 : 开发副本（更新走 git pull，本入口不改动文件）" -ForegroundColor DarkGray
        } elseif (Test-SourceCopy) {
            Write-Host "更新状态 : 源码包（更新入口会先确认用途再动手）" -ForegroundColor Yellow
        } elseif (-not $localVer) {
            Write-Host "更新状态 : 可打开菜单选 检查更新 升级" -ForegroundColor Yellow
        } elseif ((Compare-Versions $localVer $remoteVer.Version) -gt 0) {
            Write-Host "更新状态 : 本地版本比最新发布版新" -ForegroundColor Green
        } elseif ((Compare-Versions $remoteVer.Version $localVer) -gt 0) {
            Write-Host "更新状态 : 发现新版，可打开菜单选 检查更新 升级" -ForegroundColor Yellow
        } else {
            Write-Host "更新状态 : 已是最新" -ForegroundColor Green
        }
    } else {
        # 状态显示也要说清是哪一类失败：笼统说"都不可达"会让用户以为是网络问题，
        # 而限流（等一小时）、缺包（手动下载）要做的动作完全不同。
        Write-Host ("最新版本 : 检查失败（{0}）" -f (Get-UpdateFailureMessage $script:UpdateLastVersionFailure "所有更新源")) -ForegroundColor Yellow
        Write-Host "更新状态 : 未知" -ForegroundColor DarkGray
    }

    Write-Host "---------------- 最近日志 ----------------" -ForegroundColor Cyan
    if (Test-Item $LogFile) {
        [System.IO.File]::ReadAllLines($LogFile, [System.Text.Encoding]::UTF8) | Select-Object -Last 3 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    } else {
        Write-Host "  （暂无日志）" -ForegroundColor DarkGray
    }
    Write-Host "==================================" -ForegroundColor Cyan
}

# ------------------------------------------------------------------------------
# 8. 菜单（唯一双击入口"打开菜单"背后：编号→现有开关，不新增行为）
# ------------------------------------------------------------------------------
# 菜单只做三件事：打印、读编号、起子进程跑对应开关后回到菜单。
# 每个动作都走一遍入口开关的完整路径（含操作锁）：菜单自己不拿锁、不碰变量不碰文件，
# 所以菜单里的 bug 最多影响菜单显示，动不了安装区。五个动作与入口开关一一对应。
# 非交互环境（管道/后台调用）直接退出并提示，不死循环（与 Read-Host 各处的规矩一致）。
$MenuItems = @(
    @{ Key = "1"; Name = "安装 / 修复"; Switch = "Install" },
    @{ Key = "2"; Name = "查看状态";   Switch = "Status" },
    @{ Key = "3"; Name = "停止监控";   Switch = "Stop" },
    @{ Key = "4"; Name = "一键恢复";   Switch = "Uninstall" },
    @{ Key = "5"; Name = "检查更新";   Switch = "Update" },
    @{ Key = "0"; Name = "退出";       Switch = "" }
)
function Show-Menu {
    # 非交互 stdin（管道/重定向）直接退出不进循环：菜单是给人点的，自动化请用开关。
    # 否则管道到 EOF 时 Read-Host 读空会被当成回车，一遍遍重复默认动作停不下来。
    try {
        if ([Console]::IsInputRedirected) {
            Write-Host "菜单需要双击 打开菜单.cmd 使用，管道调用请直接用 -Install/-Status/-Stop/-Uninstall/-Update 开关。" -ForegroundColor Yellow
            return
        }
    } catch {}
    while ($true) {
        Write-Host ""
        Write-Host "======== EnvProxy 菜单 ========" -ForegroundColor Cyan
        # 抬头只读瞬时项（监控在不在、本地版本），不做网络探测，不卡菜单。
        $hm = Get-MonitorProcess
        $monText = if ($hm) { ("运行中 (PID {0})" -f $hm.ProcessId) } else { "未运行" }
        $verText = Get-LocalVersion
        if (-not $verText) { $verText = "未知" }
        Write-Host ("当前：监控{0}，本地版本 v{1}（详情选 2 查看状态）" -f $monText, $verText) -ForegroundColor DarkGray
        Write-Host "  [1] 安装 / 修复（首次安装；觉得不对劲就点它）" -ForegroundColor Green
        Write-Host "  [2] 查看状态（监控、翻墙、变量、版本）" -ForegroundColor Green
        Write-Host "  [3] 停止监控（停掉并恢复直连，下次开机回来）" -ForegroundColor Green
        Write-Host "  [4] 一键恢复（彻底卸载，回到没装之前）" -ForegroundColor Green
        Write-Host "  [5] 检查更新（有新版先说明，同意才装）" -ForegroundColor Green
        Write-Host "  [0] 退出" -ForegroundColor DarkGray
        try {
            $choice = Read-Host "选一个（回车=查看状态）"
        } catch {
            Write-Host "菜单需要双击 打开菜单.cmd 使用，管道调用请直接用 -Install/-Status/-Stop/-Uninstall/-Update 开关。" -ForegroundColor Yellow
            return
        }
        if (-not $choice) { $choice = "2" }
        $item = @($MenuItems | Where-Object { $_.Key -eq $choice.Trim() })
        if (-not $item -or ($item.Count -eq 0)) {
            Write-Host "没有这个编号，重输一个。" -ForegroundColor Yellow
            continue
        }
        if (-not $item[0].Switch) { return }
        # 子进程跑完整开关：与入口开关走的是同一条路（含锁、确认、复检）。
        # 本进程只等它结束，不解释它的退出码（退出码在 5.1 里读不到，判据只看复读）。
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath ("-" + $item[0].Switch)
        } catch {
            Write-Host ("启动失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}
