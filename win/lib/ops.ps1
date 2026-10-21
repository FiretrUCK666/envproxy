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
    # 先说清楚要动什么、不动什么，再说"正在做"——安装要改四处系统设置，
    # 用户在按完编号之后得先知道会发生什么，而不是盯着静止的屏幕猜。
    Write-Host "会改这 4 处：开机自启、终端配置、环境变量、后台监控。"
    Write-Host "不会动你的其他设置。" -ForegroundColor DarkGray
    Write-Host ""
    Set-AutoRun
    # 写完必须读回：装没装上由复读决定，不由"我调用了写入"决定（与自愈路径同一条规矩）。
    # 杀软拦 Run 键是真实发生过的事，那时不能报"已写入"。
    $runHave = $null
    try { $runHave = (Get-ItemProperty $RunKeyPath -ErrorAction SilentlyContinue).$RunKeyName } catch {}
    if (($runHave -eq (Get-LauncherCommand)) -and (Test-LauncherCurrent)) {
        Write-Host "[1/4] 开机自启动：已写入（固定定位器架构）" -ForegroundColor Green
    } else {
        Write-Host "[1/4] 开机自启动：写入后读回不一致，可能被杀软拦住。" -ForegroundColor Yellow
        Write-Host "      请检查杀软拦截，或再打开一次菜单选 安装；仍然不行就把它加进白名单。" -ForegroundColor Yellow
    }
    # 首次安装的判据必须在写路径记录**之前**取：写完这台机器上就有记录了，再判永远是"重装"。
    # 差别在于本机地址的代理变量算谁的——首次安装时它只可能是使用者自己的。
    $firstInstall = -not ((Get-ItemProperty $ScriptPathRegKey -Name "ScriptPath" -ErrorAction SilentlyContinue).ScriptPath)
    Update-ScriptPathRecord
    # 先快照用户原值，再动任何东西：监控一启动就会在几秒内自愈、把代理变量写进去，
    # 那时再快照，存下的就是"我们写下的值"而不是用户原值，卸载还原会留下我们的条目。
    # （快照只记一次；已经存在时这里是无副作用的空操作。）
    Snapshot-PrevEnv -FirstInstall:$firstInstall
    # 装没装上由返回值决定，不由"我调用过启动"决定（与自启动项读回复检同一条规矩）。
    # 这一步在慢机器上可能花一两秒，先说一声，别让屏幕静止不动。
    Write-Host "[2/4] 正在启动后台监控……" -ForegroundColor DarkGray
    if (Start-Monitor -Force:$true) {
        Write-Host "[2/4] 监控进程：已启动" -ForegroundColor Green
    } else {
        Write-Host "[2/4] 监控进程：未能确认运行，原因见下面那两行。" -ForegroundColor Yellow
    }
    # 立即对齐环境变量状态：有代理 → 注入；无代理 → 清理残留死变量
    # （不等监控的双轮去抖，"安装"即"一键修复"）
    # 先说要探测，因为这三层验证要连外网，慢的时候差不多一秒。
    Write-Host "[3/4] 正在确认翻墙软件在不在（有端口、是代理、真能连出去）……" -ForegroundColor DarkGray
    $state = Get-CurrentState
    Apply-State $state
    if ($state -eq "unknown") {
        # 端口枚举失败：这一轮不知道状态，一个变量都没动——不能说"已校正"。
        Write-Host "[3/4] 环境变量：端口枚举失败，这一轮不知道状态，未做任何改动。" -ForegroundColor Yellow
    } else {
        Write-Host "[3/4] 环境变量：已按当前状态校正" -ForegroundColor Green
    }
    # 终端同步：写 $PROFILE 里的钩子块，让已经开着的窗口也能跟上。
    # 失败不阻断安装（其余三件事已经做成），但必须如实说清原因，不许报成功。
    Write-Host "[4/4] 正在写终端配置……" -ForegroundColor DarkGray
    $prof = Install-ShellProfile
    switch ($prof.Reason) {
        'installed'  { Write-Host "[4/4] 终端同步：已在 PowerShell 配置文件里写入钩子" -ForegroundColor Green }
        'current'    { Write-Host "[4/4] 终端同步：已是最新" -ForegroundColor Green }
        'no-profile' { Write-Host "[4/4] 终端同步：取不到 $PROFILE 路径，跳过（新窗口仍会生效）" -ForegroundColor Yellow }
        'unpaired'   {
            Write-Host "[4/4] 终端同步：配置文件里的标记不成对，未改动它（安全起见一个字节都没动）" -ForegroundColor Yellow
            Write-Host ("      " + $prof.Path) -ForegroundColor DarkGray
        }
        default      {
            Write-Host ("[4/4] 终端同步：写入失败（" + $prof.Reason + "）") -ForegroundColor Yellow
            Write-Host ("      " + $prof.Path) -ForegroundColor DarkGray
        }
    }
    $polWarn = Get-ProfileExecutionPolicyWarning
    if ($polWarn) { Write-Host ("      " + $polWarn) -ForegroundColor Yellow }
    Start-Sleep -Seconds 1
    Write-Host ""
    # 联网对比版本要一两秒：先说一声，别让最后这一步又变成静默等待。
    Write-Host "正在联网确认有没有新版本……" -ForegroundColor DarkGray
    Show-Status
    Write-Host ""
    Write-Host "提示：之后新开的终端/程序自动获得代理；" -ForegroundColor Green
    Write-Host "      已经开着的窗口敲一下回车就会跟上，退出翻墙软件后同样。" -ForegroundColor Green
    Write-Host "      想让某个窗口固定直连：在它里面执行 `$env:ENVPROXY_TERM = 'off'" -ForegroundColor DarkGray
    Write-Host "      （改回跟着翻墙软件走：Remove-Item Env:ENVPROXY_TERM）。" -ForegroundColor DarkGray
}

function Uninstall-EnvProxy([bool]$Purge = $false) {
    Write-Host "======== EnvProxy 卸载（一键恢复原状）========" -ForegroundColor Cyan
    if (Test-IsElevated) { Write-Host "当前是管理员身份：动的将是管理员的配置，日常使用请用普通终端重做一遍。" -ForegroundColor Yellow }
    Stop-Monitor
    Remove-AutoRun
    # 先摘终端同步的钩子块：它引用 $ProxyVarNames，留着会指向一个已经卸载的工具。
    # 只摘我们那一块，用户 profile 里其余内容一字不动（不成对时一个字节都不改）。
    $profRm = Remove-ShellProfile
    if ($profRm.Ok) {
        if ($profRm.Reason -eq 'removed') { Write-Host "终端同步：已从 PowerShell 配置文件里移除钩子" -ForegroundColor Green }
    } else {
        Write-Host ("终端同步：未能移除钩子（" + $profRm.Reason + "），可手动删除下面文件里 EnvProxy 标记的那几行：") -ForegroundColor Yellow
        Write-Host ("  " + $profRm.Path) -ForegroundColor DarkGray
    }
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
    if (Test-RegKey $ScriptPathRegKey) { $dirty += "路径记录仍在" }
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

# 状态显示。
# 会联网查一次最新版本（约 1-2 秒）：看状态时最想知道的就是"我是不是最新版"，
# 这个检查不能省。慢的那一下由调用方先说一声，不静默等待。
function Show-Status {
    Write-Host "======== EnvProxy 状态 ========" -ForegroundColor Cyan

    $m = Get-MonitorProcess
    if ($m) { Write-Host ("监控进程 : 运行中 (PID {0})" -f $m.ProcessId) -ForegroundColor Green }
    else    { Write-Host "监控进程 : 未运行" -ForegroundColor Yellow }

    $run = (Get-ItemProperty $RunKeyPath -ErrorAction SilentlyContinue).$RunKeyName
    if ($run) {
        # 只看"值非空"会说谎：卸载不彻底或手工删过文件夹时，Run 键指向的启动器
        # 已经不在了，登录时什么都不会起来，状态页却仍报"已启用"。
        # 判据要和"能不能真的启动"一致：值在，且它指向的脚本真的存在。
        $launcher = ""
        if ($run -match '-File\s+"?([^"]+\.ps1)"?') { $launcher = $Matches[1] }
        if ($launcher -and (Test-Path -LiteralPath $launcher)) {
            Write-Host "开机自启 : 已启用" -ForegroundColor Green
        } else {
            Write-Host "开机自启 : 记录还在，但启动文件已不存在（登录时不会启动）" -ForegroundColor Yellow
            Write-Host ("           记录指向：{0}" -f $(if ($launcher) { $launcher } else { $run })) -ForegroundColor DarkGray
            Write-Host "           打开菜单选 1（安装 / 修复）可以重建。" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "开机自启 : 未启用" -ForegroundColor Yellow
    }

    # 状态页只做快扫：全端口批量探测约 1 秒，放在只读的状态显示里太重。
    # DIVERGE(Win): 这里用 Get-ActiveProxyPort 并把日志关掉（-NoLog），Mac 侧状态页
    #   直接调 find_candidate_ports ——那个函数本身就不写日志。两端都是只读，
    #   只是 Mac 的日志写在 get_current_state 里、Windows 的写在 Find-CandidatePorts 里，
    #   所以 Windows 需要显式传 -NoLog 才能守住"状态显示永不写文件"这条契约。
    $port = Get-ActiveProxyPort -FullScan:$false -NoLog:$true
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
    # Mac 侧同语义实现在 show_status（读 scutil --proxy + nc 试连），两侧判据一致。
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
# 屏幕刷新：菜单与帮助都是"一屏一页"，切换页面时先清屏再画。
#
# 为什么必须带判断：Clear-Host 在输出被重定向时（管道、日志、CI）会抛
# "设置 CursorPosition 时出现异常：句柄无效"——它依赖真实控制台缓冲区。
# 那种环境本来也拿不到终端，清屏毫无意义，还会把错误日志刷脏。
# 所以只在"真有终端"时清，其余情况老实往下输出。
function Clear-Screen {
    try {
        if ([Console]::IsOutputRedirected) { return }
        Clear-Host
    } catch {}
}

# 菜单只做三件事：打印、读编号、起子进程跑对应开关后回到菜单。
# 每个动作都走一遍入口开关的完整路径（含操作锁）：菜单自己不拿锁、不碰变量不碰文件，
# 所以菜单里的 bug 最多影响菜单显示，动不了安装区。
# **打印与分派共用下面这张 $MenuItems**：加一项就自动出现在菜单里，不会再出现
# "表里加了、打印忘了"这种功能明明做了、用户却看不见的缺口。
# 非交互环境（管道/后台调用）直接退出并提示，不死循环（与 Read-Host 各处的规矩一致）。
# 分组只影响"打印时怎么排"，不改变编号与行为：用户记熟的 1-6、0 一个都不动。
$MenuItems = @(
    @{ Key = "1"; Name = "安装 / 修复"; Switch = "Install";   Group = "日常"; Hint = "首次安装；觉得不对劲就点它" },
    @{ Key = "2"; Name = "查看状态";   Switch = "Status";    Group = "日常"; Hint = "监控、翻墙、变量、版本" },
    @{ Key = "5"; Name = "检查更新";   Switch = "Update";    Group = "日常"; Hint = "有新版先说明，同意才装" },
    @{ Key = "3"; Name = "停止监控";   Switch = "Stop";      Group = "维护"; Hint = "停掉并恢复直连，下次登录回来" },
    @{ Key = "4"; Name = "一键恢复";   Switch = "Uninstall"; Group = "维护"; Hint = "彻底卸载，回到没装之前" },
    @{ Key = "6"; Name = "帮助";       Switch = "Help";      Group = "维护"; Hint = "分主题查看，不用翻屏" },
    @{ Key = "0"; Name = "退出";       Switch = "";          Group = "退出" }
)

# 菜单里名字那一列要按最长的自动对齐：写死宽度会在改文案后错位，
# 而错位的表格正是"看起来乱"的主要来源。
function Get-MenuNameWidth {
    $w = 0
    foreach ($mi in $MenuItems) {
        $len = 0
        foreach ($ch in $mi.Name.ToCharArray()) {
            # 中文字符在终端里占两格，按 2 计；ASCII 占 1。
            $len += if ([int]$ch -gt 0x2E80) { 2 } else { 1 }
        }
        if ($len -gt $w) { $w = $len }
    }
    return $w
}

# 把一段文字按终端可见宽度补空格（中文按两格算）。
function Format-MenuCell([string]$Text, [int]$Width) {
    $len = 0
    foreach ($ch in $Text.ToCharArray()) { $len += if ([int]$ch -gt 0x2E80) { 2 } else { 1 } }
    $pad = $Width - $len
    if ($pad -lt 0) { $pad = 0 }
    return $Text + (' ' * $pad)
}

# 带配色地把菜单打到屏幕上。
# 与 Format-MenuText 的分工：那个返回纯文本（给测试和非交互用），这个负责上色。
# 两者读同一张 $MenuItems，所以不会出现"屏幕上有、测试里没有"。
function Show-MenuColored {
    $nameW = Get-MenuNameWidth
    $hl = Get-MonitorProcess
    $verText = Get-LocalVersion
    if (-not $verText) { $verText = "未知" }
    Write-Host "======== EnvProxy 菜单 ========" -ForegroundColor Cyan
    # 抬头是状态提要，用灰：它是背景信息，不该和可点的编号抢注意力。
    if ($hl) {
        Write-Host ("  监控 运行中 (PID {0})    版本 v{1}" -f $hl.ProcessId, $verText) -ForegroundColor DarkGray
    } else {
        Write-Host ("  监控 未运行    版本 v{0}" -f $verText) -ForegroundColor DarkGray
    }
    foreach ($g in @('日常', '维护', '退出')) {
        $items = @($MenuItems | Where-Object { $_.Group -eq $g })
        if ($items.Count -eq 0) { continue }
        Write-Host ''
        Write-Host ("  $g") -ForegroundColor Cyan
        foreach ($mi in $items) {
            # 编号用亮色（这是用户要敲的东西），名字白色，说明灰色。
            # 三层区分让"敲哪个"一眼看出来，不用逐行读完整行。
            $keyColor = if ($mi.Switch) { 'Green' } else { 'DarkGray' }
            Write-Host ('    {0}' -f $mi.Key) -ForegroundColor $keyColor -NoNewline
            if ($mi.Hint) {
                $nameCell = Format-MenuCell $mi.Name $nameW
                Write-Host ('  {0}' -f $nameCell) -ForegroundColor White -NoNewline
                Write-Host ('   {0}' -f $mi.Hint) -ForegroundColor Gray
            } else {
                Write-Host ('  {0}' -f $mi.Name) -ForegroundColor White
            }
        }
    }
    Write-Host ''
    Write-Host '  输入编号后回车（直接回车 = 查看状态）' -ForegroundColor DarkGray
}

# 渲染整张菜单（纯文本）。打印与测试共用内容，保证"表里有什么，屏幕就有什么"。
function Format-MenuText {
    $nameW = Get-MenuNameWidth
    $out = New-Object System.Collections.Generic.List[string]
    $hl = Get-MonitorProcess
    $monText = if ($hl) { ("运行中 (PID {0})" -f $hl.ProcessId) } else { "未运行" }
    $verText = Get-LocalVersion
    if (-not $verText) { $verText = "未知" }
    [void]$out.Add("======== EnvProxy 菜单 ========")
    [void]$out.Add(("  监控 {0}    版本 v{1}" -f $monText, $verText))
    $groups = @('日常', '维护', '退出')
    foreach ($g in $groups) {
        $items = @($MenuItems | Where-Object { $_.Group -eq $g })
        if ($items.Count -eq 0) { continue }
        [void]$out.Add("")
        [void]$out.Add(("  {0}" -f $g))
        foreach ($mi in $items) {
            if ($mi.Hint) {
                $nameCell = Format-MenuCell $mi.Name $nameW
                [void]$out.Add(("    {0}  {1}   {2}" -f $mi.Key, $nameCell, $mi.Hint))
            } else {
                # 没有提示就不补空格：行尾留一串空白，复制出去很难看。
                [void]$out.Add(("    {0}  {1}" -f $mi.Key, $mi.Name))
            }
        }
    }
    [void]$out.Add("")
    [void]$out.Add("  输入编号后回车（直接回车 = 查看状态）")
    return ($out -join "`n")
}

# 帮助的内容表：每个主题一屏放得下，进帮助先看目录，选一个只看那一段。
# 为什么这么分：一次性把十几屏内容全刷出来，看到后面已经忘了前面讲什么；
# 按"我此刻想解决什么"分主题，再配一个固定的返回行，用户随时能退回来换一段看。
# 每条格式：键 / 标题（目录里显示）/ 正文行数组。
function Get-HelpTopics {
    return @(
        @{
            Key = '1'; Title = '它是什么、怎么判断你在翻墙'
            Lines = @(
                '它做什么',
                '  翻墙软件一开，终端里的 git / npm / curl 就能翻墙；',
                '  一关，它们自动恢复直连。不用记任何开关。',
                '',
                '它凭什么判断你在翻墙',
                '  每 2 到 3 秒看一次，但要同时满足三条才算：',
                '    1. 本机有端口在监听；',
                '    2. 它确实是代理——发一次握手，要回 HTTP/1.x 200；',
                '    3. 它确实连得通外面——通过它访问 7 个不同站点，任意一个通就算。',
                '  三条全过才写变量，所以本机开着网页服务、开发服务器都不会被误判。',
                '  它不认品牌、不认进程名、不认端口号，那些只用来加快扫描。'
            )
        },
        @{
            Key = '2'; Title = '装完之后会发生什么'
            Lines = @(
                '装完之后，按窗口分三种情况',
                '  1. 装完之后打开的窗口',
                '     启动时读到的就是当前状态，什么都不用做。',
                '  2. 装完之后打开、后来代理又变了',
                '     按一次回车即可。',
                '  3. 装之前就打开的窗口',
                '     同步代码还没装进去，要重开一个窗口，',
                '     或者执行主题 3 里那条加载命令。',
                '',
                '为什么开着的窗口要按一次回车',
                '  每个程序只在启动那一刻读一次环境变量，读完就固定了。之后系统改了，',
                '  已经在跑的窗口不会跟着变。EnvProxy 挑的时机是每次命令跑完、屏幕重新',
                '  出现光标的时候——你本来就一直在敲命令，所以不用专门做什么。'
            )
        },
        @{
            Key = '3'; Title = '单个窗口怎么接管 / 走公司代理'
            Lines = @(
                '这些命令要在 PowerShell 里敲，不是老式的「命令提示符」(cmd)',
                '  日常你接触的窗口基本都是 PowerShell：开始菜单搜 PowerShell、',
                '  Win+R 输入 powershell、Windows Terminal、VS Code 终端，都是。',
                '  只有手动打开「命令提示符」才是 cmd。看提示符就能分辨：',
                '  开头有 PS 的是 PowerShell。',
                '',
                '  如果确实在用 cmd，写法不同：',
                '      set ENVPROXY_TERM=off     固定直连',
                '      set ENVPROXY_TERM=        改回跟着翻墙软件走',
                '      set HTTPS_PROXY           查看代理',
                '',
                '让这个窗口固定直连（只管当前窗口，窗口一关就失效）',
                '      $env:ENVPROXY_TERM = ''off''',
                '  改回跟着翻墙软件走：',
                '      Remove-Item Env:ENVPROXY_TERM',
                '  ENVPROXY_TERM 是 EnvProxy 自己的开关变量，只有 ''off'' 一个值有意义：',
                '  设上它就表示这个窗口不要跟着翻墙软件变。它不影响翻墙软件本身，',
                '  只影响你敲命令的这个窗口。',
                '',
                '让这个窗口走公司代理（两步，顺序不能反）',
                '  1. 先停掉自动跟随：$env:ENVPROXY_TERM = ''off''',
                '  2. 再设公司代理：  $env:HTTPS_PROXY = ''http://你的地址:端口''',
                '  为什么必须先停掉：不停的话，翻墙软件一有变化就会覆盖你刚设的地址。',
                '',
                '检查现在走不走代理',
                '      $env:HTTPS_PROXY          （有值就是走代理，空的是直连）',
                '',
                '让已经开着的窗口立刻跟上',
                '      . $PROFILE',
                '  $PROFILE 是 PowerShell 每次启动时自动跑的文件，安装时往里面放了一段',
                '  同步代码，这条命令就是手动跑一次它。PowerShell 5.1 和 7 各有自己的',
                '  $PROFILE，安装时两个都写了，所以你在哪个窗口里敲它，加载的都是对应的',
                '  那一份。',
                '  注意：开头的点号和后面的空格都不能少；只对 PowerShell 有效（cmd 和',
                '  Git Bash 没有这个文件）；执行完只影响这一个窗口，别的已开窗口要各自',
                '  执行或重开；如果那个窗口从没装过 EnvProxy，这个文件可能不存在，',
                '  会看到「找不到路径」的红字，属正常，重开一个窗口就行。'
            )
        },
        @{
            Key = '4'; Title = '让某一条命令不走代理'
            Lines = @(
                '不同工具写法不一样，没有通用的一条命令',
                '',
                'curl',
                '      curl.exe --noproxy "*" 网址',
                '  Windows 上必须写 curl.exe。PowerShell 把 curl 和 wget 都当成了别名，',
                '  指向 Invoke-WebRequest，直接敲会报「参数找不到」。',
                '',
                'git',
                '      git -c http.proxy= -c https.proxy= clone 仓库地址',
                '  等号后留空 = 这条不用代理；写别的值 = 改用那个代理。',
                '',
                'npm',
                '      npm --noproxy=registry.npmjs.org install 包名',
                '  注意：noproxy 只认域名，写 * 没用，而且不报错，请求照常走代理。',
                '  写成 --no-proxy 会被理解成 --proxy=false，也不是你要的效果。',
                '  另外 npm 只认 HTTPS_PROXY，不认 HTTP_PROXY。',
                '',
                'wget',
                '  Windows 不自带 wget。自己装过 GNU wget 才写：',
                '      wget.exe --no-proxy 网址',
                '  （PowerShell 里的 wget 只是别名，指向 Invoke-WebRequest，不是真的 wget）',
                '',
                'docker',
                '  没有单条命令的写法，改 Docker 自己的设置（Settings 里的 Proxies）。'
            )
        },
        @{
            Key = '5'; Title = '菜单每个选项做什么'
            Lines = @(
                '  [1] 安装 / 修复',
                '      首次安装，或者觉得不对劲时都选它。重复跑不会多装一份。',
                '  [2] 查看状态',
                '      监控在不在跑、翻墙状态、变量、版本。只读，不改任何东西。',
                '  [3] 停止监控',
                '      临时停用，下次登录会自己回来。',
                '  [4] 一键恢复',
                '      彻底卸载，回到没装之前。会问你要不要留日志。',
                '  [5] 检查更新',
                '      先告诉你有新版和改了什么，同意才装。升级不用开翻墙软件。',
                '  [6] 帮助',
                '      就是这里。',
                '  [0] 退出菜单',
                '      什么都不做。直接按回车等于选 2（查看状态）。'
            )
        },
        @{
            Key = '6'; Title = '日志在哪、文件夹结构'
            Lines = @(
                '日志',
                '      win\monitor\monitor.log',
                '  上限 200KB，写满只留最近 200 行。卸载时会问你要不要留它。',
                '',
                '文件夹里都是什么',
                '      打开菜单.cmd        唯一需要双击的文件',
                '      envproxy.ps1        主程序',
                '      lib\                程序库，不用管',
                '      monitor\            运行时自动生成，放日志和 pid',
                '  整个文件夹可以改名、搬走。更新只覆盖程序文件，',
                '  所以别把你要长期保留的东西放进这个文件夹。'
            )
        },
        @{
            Key = '7'; Title = '觉得不对劲怎么办'
            Lines = @(
                '大部分问题都可以用「安装 / 修复」解决',
                '  打开菜单选 1。它不会重复安装，不会中断网络，',
                '  也不会丢失你自己的设置。',
                '',
                '还是不行',
                '  打开菜单选 2，把状态截图；再选 1 修复一次。',
                '  反馈时附上 monitor\monitor.log 最后 20 行，能省很多来回。',
                '',
                '只想看命令和完整说明',
                '  完整说明在项目里的 README，',
                '  其中「常用操作一页纸」一节收了所有命令。'
            )
        }
    )
}

# 帮助目录：只列标题，一屏放得下。
function Format-HelpIndex {
    $out = New-Object System.Collections.Generic.List[string]
    [void]$out.Add('================ EnvProxy 帮助 ================')
    [void]$out.Add('')
    [void]$out.Add('  想知道什么，就输它的编号：')
    [void]$out.Add('')
    foreach ($t in (Get-HelpTopics)) {
        [void]$out.Add(('    {0}  {1}' -f $t.Key, $t.Title))
    }
    [void]$out.Add('')
    $ver = Get-LocalVersion
    if ([string]::IsNullOrWhiteSpace($ver)) { $ver = '未知' }
    [void]$out.Add(('  本机版本 v{0}' -f $ver))
    [void]$out.Add('')
    [void]$out.Add('  输入编号后回车    0 = 回主菜单')
    return ($out -join "`n")
}

# 判断一行在屏幕上该用什么颜色。
# 判据只看行自己的形状，不依赖调用方声明：文案改动时配色自动跟上，不会脱节。
#   顶格且不以符号开头 -> 小标题（青色加粗感）
#   缩进 4 格以上且像是命令 -> 命令（绿色，用户可能要照抄）
#   含"注意/为什么/必须先" -> 提醒（黄色）
#   其余 -> 正文（灰色）
# 判错最多是颜色不理想，不会丢内容，也不会报错。
function Get-HelpLineRole([string]$Line) {
    if ([string]::IsNullOrWhiteSpace($Line)) { return 'blank' }
    $indent = 0
    foreach ($ch in $Line.ToCharArray()) { if ($ch -eq ' ') { $indent++ } else { break } }
    $body = $Line.Trim()
    # 顶格的一行短句是小标题（不是句子：没有句号、逗号结尾通常也不长）
    if ($indent -eq 0) {
        if ($body.Length -le 30 -and $body -notmatch '[。；，]$') { return 'heading' }
        return 'text'
    }
    if ($body -match '^(注意|为什么|必须|别|不要|小心)') { return 'warn' }
    # 命令：缩进 4 格以上，且像命令行（英文开头，或含 = / -- 这类参数特征）
    if ($indent -ge 4 -and ($body -match '^[A-Za-z$./\\]' -or $body -match '--|=\S')) { return 'cmd' }
    if ($body -match '^(\d+\.|\[|\d+ \s)') { return 'item' }
    return 'text'
}

# 按角色给一行配色输出。
function Write-HelpLine([string]$Line) {
    $role = Get-HelpLineRole $Line
    switch ($role) {
        'heading' { Write-Host $Line -ForegroundColor Cyan }
        'cmd'     { Write-Host $Line -ForegroundColor Green }
        'warn'    { Write-Host $Line -ForegroundColor Yellow }
        'item'    { Write-Host $Line -ForegroundColor White }
        'blank'   { Write-Host '' }
        default   { Write-Host $Line -ForegroundColor Gray }
    }
}

# 单个主题：正文前后各留一行，底部固定给返回方式。
function Format-HelpTopic([string]$Key) {
    $t = @(Get-HelpTopics | Where-Object { $_.Key -eq $Key })
    if ($t.Count -eq 0) { return $null }
    $t = $t[0]
    $out = New-Object System.Collections.Generic.List[string]
    [void]$out.Add(('================ 帮助 {0} · {1} ================' -f $t.Key, $t.Title))
    [void]$out.Add('')
    foreach ($l in $t.Lines) { [void]$out.Add($l) }
    [void]$out.Add('')
    [void]$out.Add('  0 = 返回目录    n = 下一个    p = 上一个    m = 回主菜单')
    return ($out -join "`n")
}

# 把 n / p 这类导航词翻译成目标主题的键。
# 有了它，用户不用记"我现在在第几个"，直接按 n 就能翻到下一篇。
# 到头绕回去（环形），避免"按了没反应"的困惑。
# 参数名不能用 $Input：那是 PowerShell 的自动变量，赋值会被静默忽略。
function Resolve-HelpNav([string]$Nav, [string]$CurrentKey) {
    $keys = @(Get-HelpTopics | ForEach-Object { $_.Key })
    if ($keys.Count -eq 0) { return $null }
    $idx = [array]::IndexOf($keys, $CurrentKey)
    if ($idx -lt 0) { $idx = 0 }
    if ($Nav -eq 'n' -or $Nav -eq 'N') { return $keys[($idx + 1) % $keys.Count] }
    if ($Nav -eq 'p' -or $Nav -eq 'P') { return $keys[($idx - 1 + $keys.Count) % $keys.Count] }
    return $null
}

# 带配色地把一个主题打到屏幕上。
# 与 Format-HelpTopic 的区别：那个返回纯文本（给非交互和测试用），
# 这个负责上色（给人看）。两者共用同一份内容，不会出现"屏幕上有、文档里没有"。
function Show-HelpTopicColored([string]$Key) {
    $t = @(Get-HelpTopics | Where-Object { $_.Key -eq $Key })
    if ($t.Count -eq 0) { return $false }
    $t = $t[0]
    Write-Host ('================ 帮助 {0} · {1} ================' -f $t.Key, $t.Title) -ForegroundColor Cyan
    Write-Host ''
    foreach ($l in $t.Lines) { Write-HelpLine $l }
    Write-Host ''
    Write-Host '  0 = 返回目录    n = 下一个    p = 上一个    m = 回主菜单' -ForegroundColor DarkGray
    return $true
}

# 全文：把 7 个主题按顺序拼起来，一个字不少。
# 非交互调用（-Help 被脚本/管道调用）走这条：调用方要的是一份完整文档，
# 分页导航对没有终端的场景没有意义。
function Format-HelpAll {
    $out = New-Object System.Collections.Generic.List[string]
    [void]$out.Add((Format-HelpIndex))
    foreach ($t in (Get-HelpTopics)) {
        [void]$out.Add('')
        [void]$out.Add((Format-HelpTopic $t.Key))
    }
    return ($out -join "`n")
}

# 帮助入口。
# -All：不导航，直接给全文（非交互、或明确要全文时用）。
# 交互：先给目录，输编号看主题，0 回目录，m 回主菜单。
function Show-Help([switch]$All) {
    if ($All -or [Console]::IsInputRedirected) {
        Write-Host (Format-HelpAll)
        return
    }
    while ($true) {
        # 目录与主题各占一屏：切换时清屏，屏幕上永远只有当前这一页。
        Clear-Screen
        Write-Host (Format-HelpIndex) -ForegroundColor Cyan
        $sel = ''
        try { $sel = "$(Read-Host '看哪个（回车返回）')".Trim() } catch { return }
        if (-not $sel) { return }
        if ($sel -eq '0' -or $sel -eq 'm' -or $sel -eq 'M') { return }
        Clear-Screen
        if (-not (Show-HelpTopicColored $sel)) {
            Write-Host ("没有这个编号：{0}（1-7，或 0 返回）" -f $sel) -ForegroundColor Yellow
            $null = Read-Host '按回车回目录'
            continue
        }
        # 看完一个主题以后，直接问下一个看哪个，不用退回目录再选一次。
        # 允许连看，也允许按 n / p 前后翻：用户不用记"我在第几个"。
        $cur = $sel
        while ($true) {
            $next = ''
            try { $next = "$(Read-Host '按回车回目录；n 下一个；p 上一个；或直接输编号')".Trim() } catch { return }
            if (-not $next) { break }
            if ($next -eq 'm' -or $next -eq 'M' -or $next -eq '0') { return }
            $nav = Resolve-HelpNav $next $cur
            if ($nav) { $next = $nav }
            Clear-Screen
            if (Show-HelpTopicColored $next) { $cur = $next; continue }
            Write-Host ("没有这个编号：{0}" -f $next) -ForegroundColor Yellow
            $null = Read-Host '按回车回目录'
            break
        }
    }
}

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
        # 每一轮先清屏：菜单始终占着同一块地方，不会一行行往下堆。
        Clear-Screen
        Show-MenuColored
        try {
            $choice = Read-Host "输入编号"
        } catch {
            Write-Host "菜单需要双击 打开菜单.cmd 使用，管道调用请直接用 -Install/-Status/-Stop/-Uninstall/-Update/-Help 开关。" -ForegroundColor Yellow
            return
        }
        # 先 Trim 再判空：纯空格应当与直接回车同义（Mac 侧 tr -d 之后再判空，两端同语义）。
        $choice = "$choice".Trim()
        if (-not $choice) { $choice = "2" }
        # q 与 0 同义：很多人下意识打 q 想退出，报"没有这个编号"只会让人以为程序坏了。
        if ($choice -eq 'q' -or $choice -eq 'Q') { $choice = "0" }
        $item = @($MenuItems | Where-Object { $_.Key -eq $choice })
        if (-not $item -or ($item.Count -eq 0)) {
            # 只打一行，不重画整张菜单：输错一次就把屏幕刷一遍，会让人分不清刚才看到的是哪一屏。
            Write-Host ("没有这个编号：{0}（可用的有 1-6 和 0）" -f $choice) -ForegroundColor Yellow
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
