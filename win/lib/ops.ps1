# ==============================================================================
#  ops.ps1 — 动作层：菜单背后的安装、停止、卸载、状态编排
#  把下面各层拼成使用者点得到的行为。
# ==============================================================================

# ------------------------------------------------------------------------------
# 7. 子命令实现
# ------------------------------------------------------------------------------
function Install-EnvProxy {
    Write-Host "======== EnvProxy 安装 ========" -ForegroundColor Cyan
    if (Test-IsElevated) { Write-Host "当前是管理员身份：接下来改的会是管理员这个账号的配置。日常使用请用普通终端重来一次。" -ForegroundColor Yellow }
    # 先说清楚要动什么、不动什么，再说"正在做"——安装要改四处系统设置，
    # 用户在按完编号之后得先知道会发生什么，而不是盯着静止的屏幕猜。
    Write-Host "会改这 4 处：开机自启、终端配置、环境变量、后台监控。"
    Write-Host "不会动你的其他设置。" -ForegroundColor DarkGray
    Write-Host ""
    # 每一步各自兜住异常：某一处失败不该把后面几步一起带走。
    # 实测过没有这层保护的后果——Run 键被组策略禁用时，第 1 步抛出的 .NET 异常
    # 直接终止整个脚本，启动监控、对齐变量、写终端钩子全都没执行，
    # 而用户看到的是一堆红色异常文本，不是"第 1 步失败、其余继续"的分级报告。
    $step1Ok = $false
    try {
        Set-AutoRun
        # 写完必须读回：装没装上由复读决定，不由"我调用了写入"决定（与自愈路径同一条规矩）。
        # 杀软拦 Run 键是真实发生过的事，那时不能报"已写入"。
        $runHave = $null
        try { $runHave = (Get-ItemProperty $RunKeyPath -ErrorAction SilentlyContinue).$RunKeyName } catch {}
        $step1Ok = (($runHave -eq (Get-LauncherCommand)) -and (Test-LauncherCurrent))
    } catch {}
    if ($step1Ok) {
        Write-Host "[1/4] 开机自启动：已写入" -ForegroundColor Green
    } else {
        Write-Host "[1/4] 开机自启动：没写成。可能被杀软或组策略拦住了。" -ForegroundColor Yellow
        Write-Host "      请检查杀软拦截，或再打开一次菜单选 1（安装 / 修复）；仍然不行就把它加进白名单。" -ForegroundColor Yellow
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
    $step2Ok = $false
    try { $step2Ok = Start-Monitor -Force:$true } catch {}
    if ($step2Ok) {
        Write-Host "[2/4] 监控进程：已启动" -ForegroundColor Green
    } else {
        Write-Host "[2/4] 监控进程：未能确认运行，原因见下面那两行。" -ForegroundColor Yellow
    }
    # 立即对齐环境变量状态：有代理 → 注入；无代理 → 清理残留死变量
    # （不等监控的双轮去抖，"安装"即"一键修复"）
    # 先说要探测，因为这三层验证要连外网，慢的时候差不多一秒。
    Write-Host "[3/4] 正在确认翻墙软件在不在（有端口、是代理、真能连出去）……" -ForegroundColor DarkGray
    $state = "unknown"
    $appliedOk = $true
    try {
        $state = Get-CurrentState
        $appliedOk = Apply-State $state
    } catch {
        # 对齐失败不该把终端同步那一步也带走：那一步与代理状态无关。
        $state = "failed"
        $appliedOk = $false
    }
    if ($state -eq "unknown") {
        # 端口枚举失败：这一轮不知道状态，一个变量都没动——不能说"已校正"。
        Write-Host "[3/4] 环境变量：这一轮没读到本机端口，所以没有改动任何设置（正常，会自动重试）。" -ForegroundColor Yellow
    } elseif ($state -eq "failed") {
        Write-Host "[3/4] 环境变量：这一步没做成，原因见上面那行。其余步骤不受影响。" -ForegroundColor Yellow
    } elseif (-not $appliedOk) {
        # 写失败必须如实说，不能说"已校正"——用户会以为在走代理，实际是半套变量。
        Write-Host "[3/4] 环境变量：没写进去。可能被杀软或组策略拦住了。" -ForegroundColor Yellow
        Write-Host "      再打开一次菜单选 1（安装 / 修复）重试；仍然不行请反馈。" -ForegroundColor Yellow
    } else {
        Write-Host "[3/4] 环境变量：已按当前状态校正" -ForegroundColor Green
    }
    # 终端同步：写 $PROFILE 里的钩子块，让已经开着的窗口也能跟上。
    # 失败不阻断安装（其余三件事已经做成），但必须如实说清原因，不许报成功。
    Write-Host "[4/4] 正在写终端配置……" -ForegroundColor DarkGray
    $prof = $null
    try { $prof = Install-ShellProfile } catch { $prof = [pscustomobject]@{ Reason = "error"; Path = "" } }
    switch ($prof.Reason) {
        'installed'  { Write-Host "[4/4] 终端同步：已写进 PowerShell 和 Git Bash 的配置文件" -ForegroundColor Green }
        'current'    { Write-Host "[4/4] 终端同步：已是最新（PowerShell 与 Git Bash 都已在位）" -ForegroundColor Green }
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
    Write-Host "      装完之后一直开着的窗口，敲一下回车就跟上（cmd 窗口只能重开）。" -ForegroundColor Green
    Write-Host "      装之前就开着的窗口没有同步代码，要重开一个。退出翻墙软件后同样。" -ForegroundColor Green
    Write-Host "      想让某个窗口固定直连：在它里面执行 `$env:ENVPROXY_TERM = 'off'" -ForegroundColor DarkGray
    Write-Host "      （改回跟着翻墙软件走：Remove-Item Env:ENVPROXY_TERM）。" -ForegroundColor DarkGray
}

function Uninstall-EnvProxy([bool]$Purge = $false) {
    Write-Host "======== EnvProxy 卸载（一键恢复原状）========" -ForegroundColor Cyan
    if (Test-IsElevated) { Write-Host "当前是管理员身份：接下来改的会是管理员这个账号的配置。日常使用请用普通终端重来一次。" -ForegroundColor Yellow }
    Stop-Monitor
    Remove-AutoRun
    # 先摘终端同步的钩子块：它引用 $ProxyVarNames，留着会指向一个已经卸载的工具。
    # 只摘我们那一块，用户 profile 里其余内容一字不动（不成对时一个字节都不改）。
    $profRm = Remove-ShellProfile
    if ($profRm.Ok) {
        if ($profRm.Reason -eq 'removed') { Write-Host "终端同步：已从 PowerShell 和 Git Bash 的配置文件里移除" -ForegroundColor Green }
    } else {
        Write-Host ("终端同步：没能移除（" + $profRm.Reason + "），可手动删掉下面文件里 EnvProxy 标记的那几行：") -ForegroundColor Yellow
        Write-Host ("  " + $profRm.Path) -ForegroundColor DarkGray
    }
    # 顺序是定的：先清我们写的值，再按快照还用户原值。
    # 反过来会把用户原值里与默认集重合的项（如 localhost）当成"我们加的"剥掉，快照保护落空。
    # 走 Apply-State 而不是裸调 Remove-UserEnvVars：拿写变量锁、判据与写入同源、写完广播。
    # 裸调会绕过锁，与监控自愈并发时可能留下半套变量。
    $null = Apply-State "off"
    # 复检用的期望值先抄一份：Restore 会删掉快照键，抄晚了就没处可查了。
    # 有快照的名字以"与快照一致"为准（用户原值里若含 localhost 这类与默认集重合的项，
    # 它既不是残留也不能删）；没快照的名字才按"有无我们的痕迹"判。
    $restoredWant = @{}
    foreach ($n in $ProxyVarNames) {
        $bv = Get-PrevEnvRaw $n
        if ($null -ne $bv) { $restoredWant[$n] = [string]$bv }
    }
    # 先按快照还用户原值，再清注册表键（快照键在该键之下，顺序不能反）。
    Restore-PrevEnv
    # 还完再广播一次：运行中的进程按旧环境块活着，不广播它们就继续走死代理——"无需重启"靠这一次广播。
    Broadcast-EnvironmentChange
    Remove-Item -LiteralPath $ScriptPathRegKey -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $LauncherPath -Force -ErrorAction SilentlyContinue
    # Git Bash 同步用的状态镜像也在定位器目录里：它由本工具新引入，卸载必须带走。
    # 先删文件再删目录，否则目录非空、Remove-Item 不带 -Recurse 会失败（原来就是这样漏的）。
    Remove-Item -LiteralPath (Join-Path $LauncherDir "terminal.env") -Force -ErrorAction SilentlyContinue
    # %LOCALAPPDATA%\EnvProxy 是我们**独占**的目录（只有 launcher.ps1 / terminal.env / *.tmp*），
    # 必须带 -Recurse：5.1 上删非空目录不带它会抛 NullReferenceException 且目录纹丝不动，
    # 于是"卸载未完成"永远修不好——用户再点一次也删不掉，因为没人去删那些残留。
    Remove-Item -LiteralPath $LauncherDir -Recurse -Force -ErrorAction SilentlyContinue
    # Git Bash 的同步脚本副本也要清：它装在 ~/.envproxy 下，不属于安装目录，
    # 单靠删安装夹带不走。与 Mac 侧 uninstall 删 prompt-sync.sh 再 rmdir 同一套动作。
    # 目录只在空的时候才删——里面若有使用者自己放的东西，一个字节都不动。
    $epHome = Join-Path ([string]$env:USERPROFILE) '.envproxy'
    Remove-Item -LiteralPath (Join-Path $epHome 'prompt-sync.sh') -Force -ErrorAction SilentlyContinue
    try {
        if ((Test-Item $epHome) -and -not (Get-ChildItem -LiteralPath $epHome -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            Remove-Item -LiteralPath $epHome -Force -ErrorAction SilentlyContinue
        }
    } catch {}
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
    # 每条残留都带上**具体位置**。只写"路径记录仍在"再加一句"手动删除上述位置"，
    # 用户看着空白不知道删什么——提示得能照着做才算提示。
    $dirty = @()
    try { $null = Get-ItemPropertyValue -Path $RunKeyPath -Name $RunKeyName -ErrorAction Stop
          $dirty += ("开机自启动项仍在：" + $RunKeyPath + " 里的 " + $RunKeyName) } catch {}
    if (Test-Item $LauncherPath) { $dirty += ("定位脚本仍在：" + $LauncherPath) }
    if (Test-Item $LauncherDir) { $dirty += ("定位脚本所在目录仍在：" + $LauncherDir) }
    if (Test-RegKey $ScriptPathRegKey) { $dirty += ("路径记录仍在：注册表 " + $ScriptPathRegKey) }
    if (Test-Item (Join-Path ([string]$env:USERPROFILE) ".envproxy\prompt-sync.sh")) { $dirty += "Git Bash 同步脚本副本仍在" }
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
        Write-Host "[完成] 监控已停，开机自启、代理变量和定位用的小脚本都已删除。" -ForegroundColor Green
        if ($removeLog) {
            Write-Host "        历史日志已一并彻底删除。" -ForegroundColor Green
        } else {
            Write-Host "        历史日志保留在 monitor\monitor.log（黑匣子，供日后排查）。" -ForegroundColor Yellow
        }
        Write-Host "        电脑已恢复到安装前的状态。新开终端即直连；已经开着的旧窗口重开一个。" -ForegroundColor Green
    } else {
        Write-Host "[未完成] 这几处没清干净：" -ForegroundColor Yellow
        foreach ($d in $dirty) { Write-Host ("        - " + $d) -ForegroundColor Yellow }
        Write-Host "        再打开菜单选 6（一键恢复）试一次；还不行就照上面列出的位置手动删。" -ForegroundColor Yellow
    }
}

# 状态显示。
# 会联网查一次最新版本（约 1-2 秒）：看状态时最想知道的就是"我是不是最新版"，
# 这个检查不能省。慢的那一下由调用方先说一声，不静默等待。
function Show-Status {
    Write-Host "======== EnvProxy 状态 ========" -ForegroundColor Cyan

    $m = Get-MonitorProcess
    $run = (Get-ItemProperty $RunKeyPath -ErrorAction SilentlyContinue).$RunKeyName
    # 自启是否真的会生效：值在，且它指向的脚本真的存在。
    # 只看"值非空"会说谎——卸载不彻底或手工删过文件夹时，登录时什么都不会起来。
    $autoRunOk = $false
    $launcher = ""
    if ($run -match '-File\s+"?([^"]+\.ps1)"?') { $launcher = $Matches[1] }
    if ($launcher -and (Test-Path -LiteralPath $launcher)) { $autoRunOk = $true }

    if ($m) {
        Write-Host ("监控进程 : 运行中 (PID {0})" -f $m.ProcessId) -ForegroundColor Green
    } else {
        Write-Host "监控进程 : 未运行" -ForegroundColor Yellow
        # "停止"是一个稳定状态（自启动只在登录时拉起一次，不保活）。
        # 但"未运行"有两个完全不同的原因，事后长相一样：使用者主动停的，还是进程被
        # "结束任务"关掉/崩溃了。只有执行停止的那一方留下的意图标记能分辨。
        # 不分辨就只能猜：说成"你停的"，被强杀的人会以为自己点错了；什么都不说，
        # 真停过的人会以为坏了。
        if (Test-Item $StopIntentFile) {
            if ($autoRunOk) { Write-Host "           （已按你的选择停止，下次登录会自动恢复）" -ForegroundColor DarkGray }
        } else {
            Write-Host "           （不是点了停止，是进程不在了：可能被「结束任务」关掉，或崩溃）" -ForegroundColor Yellow
            Write-Host "           打开菜单选 1（安装 / 修复）可以让它重新跑起来。" -ForegroundColor DarkGray
        }
    }

    if ($run) {
        if ($autoRunOk) {
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
        Write-Host "翻墙代理 : 这一轮没读到本机端口，无法判断（正常，会自动重试）" -ForegroundColor Yellow
    } else {
        Write-Host "翻墙代理 : 未检测到（当前无翻墙代理在运行）" -ForegroundColor Yellow
    }

    # 终端同步：已开着的窗口靠它跟上变化。这一项缺了，用户会在「监控运行中」的
    # 假象里以为一切正常，其实每次开窗口都不同步（执行策略、块不成对、宿主不支持）。
    $ts = $null
    try { $ts = Get-TerminalSyncState } catch {}
    if ($ts) {
        switch ($ts.State) {
            'ok'       { Write-Host "终端同步 : 已生效（已开着的窗口敲回车即跟上）" -ForegroundColor Green }
            'blocked'  { Write-Host "终端同步 : 装了但跑不起来" -ForegroundColor Yellow
                         Write-Host ("            " + $ts.Detail) -ForegroundColor Yellow }
            'unpaired' { Write-Host "终端同步 : 配置文件里的标记不成对，未改动它" -ForegroundColor Yellow
                         Write-Host "            打开菜单选 1 可以修复" -ForegroundColor Yellow }
            'missing'  { Write-Host "终端同步 : 配置文件里没有同步块" -ForegroundColor Yellow
                         Write-Host "            打开菜单选 1 可以写入" -ForegroundColor Yellow }
            default    { Write-Host "终端同步 : 这一轮读不到配置文件路径，无法判断" -ForegroundColor Yellow }
        }
    }

    $cur = Get-EnvProxyValue
    if ($cur) {
        # 光看"变量有值"不够：变量可能指向一个已经不存在的端口。
        # 那种情况下终端里每条联网命令都会报 ECONNREFUSED 127.0.0.1:xxxx，
        # 而错误信息里没有本工具的名字——用户（和帮他排查的 AI）会去查网络、查防火墙、
        # 查 DNS，唯独查不到这里。所以状态页要主动把这件事认下来。
        $varPort = 0
        if ($cur -match "127\.0\.0\.1:(\d+)") { $varPort = [int]$Matches[1] }
        $varAlive = $true
        if ($varPort -gt 0) {
            $varAlive = $false
            $tc2 = $null
            try {
                $tc2 = New-Object Net.Sockets.TcpClient
                $iar2 = $tc2.BeginConnect("127.0.0.1", $varPort, $null, $null)
                if ($iar2.AsyncWaitHandle.WaitOne(800)) { $tc2.EndConnect($iar2); $varAlive = $true }
            } catch {} finally {
                try { if ($tc2) { $tc2.Close() } } catch {}
            }
        }
        if ($varAlive) {
            Write-Host ("代理变量 : 已注入 ({0})" -f $cur) -ForegroundColor Green
            # 变量已经写进系统，但没有任何进程在维护它们。翻墙软件一关，这些变量就指向
            # 一个死端口，curl/git 会一直失败到手工处理或下次登录——用户不知道要找这里。
            if (-not $m) {
                Write-Host "           但这些变量现在没人维护：翻墙软件断开后不会自动清掉，终端会连不上。" -ForegroundColor Yellow
                Write-Host "           打开菜单选 1（安装 / 修复）恢复监控；或选 5（停止监控）把这批变量一并清掉。" -ForegroundColor DarkGray
            }
        } else {
            Write-Host ("代理变量 : 指向的端口已不在（{0}）" -f $cur) -ForegroundColor Yellow
            Write-Host ("           终端里联网会报 ECONNREFUSED 127.0.0.1:{0}，那是这里造成的。" -f $varPort) -ForegroundColor Yellow
            Write-Host "           监控在跑的话，几秒内会自动清掉；想立刻清掉、或者监控本来就没在跑，就打开菜单选 1（安装 / 修复）。" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "代理变量 : 无（直连状态）" -ForegroundColor DarkGray
        # 上一行说"有代理在监听"、这一行说"没注入变量"，单独看会以为自相矛盾。
        # 实话是：翻墙软件在跑，但本工具没在它上面工作（多半是用户自己停的）。
        # 补一句桥接，否则用户会判定"坏了"然后去卸载。
        if ($port -and -not $m) { Write-Host "           （翻墙软件在跑，但本工具已停用，所以没往终端里设代理）" -ForegroundColor DarkGray }
    }

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
            Write-Host "更新状态 : 可打开菜单选 3（检查更新）升级" -ForegroundColor Yellow
        } elseif ((Compare-Versions $localVer $remoteVer.Version) -gt 0) {
            Write-Host "更新状态 : 本地版本比最新发布版新" -ForegroundColor Green
        } elseif ((Compare-Versions $remoteVer.Version $localVer) -gt 0) {
            Write-Host "更新状态 : 发现新版，打开菜单选 3（检查更新）即可升级" -ForegroundColor Yellow
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
# 分组只影响打印顺序；编号按使用频率从上往下连续排（1-4 日常、5-6 维护、0 退出）。
$MenuItems = @(
    @{ Key = "1"; Name = "安装 / 修复"; Switch = "Install";   Group = "日常"; Hint = "第一次用选它；觉得不对劲也选它" },
    @{ Key = "2"; Name = "查看状态";   Switch = "Status";    Group = "日常"; Hint = "现在什么情况，一眼看清" },
    @{ Key = "3"; Name = "检查更新";   Switch = "Update";    Group = "日常"; Hint = "有新版先告诉改了什么，同意才装" },
    @{ Key = "4"; Name = "帮助";       Switch = "Help";      Group = "日常"; Hint = "忘了怎么用就看它" },
    @{ Key = "5"; Name = "停止监控";   Switch = "Stop";      Group = "维护"; Hint = "先停掉，下次开机自己回来" },
    @{ Key = "6"; Name = "一键恢复";   Switch = "Uninstall"; Group = "维护"; Hint = "彻底卸载，回到没装之前" },
    @{ Key = "0"; Name = "退出";       Switch = "";          Group = "退出"; Hint = "关掉这个窗口" }
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

# 分组的显示顺序，从 $MenuItems 按首次出现推导。打印（纯文本与彩屏）与帮助共用这一处。
# 写死数组的后果不是"少印一行"而是"屏幕上看不见、却照样敲得动"：分派不看分组，
# 所以漏印的那一项仍然会被执行——用户看到的菜单和能敲的菜单成了两件事。
function Get-MenuGroups {
    return @($MenuItems | ForEach-Object { $_.Group } | Where-Object { $_ } | Select-Object -Unique)
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
    foreach ($g in (Get-MenuGroups)) {
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
    Write-Host '  输编号后回车执行    直接回车 = 查看状态' -ForegroundColor DarkGray
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
    # 分组顺序从表里按首次出现推导，不再写死数组：加一个分组只改表。
    # 打印与分派读同一份顺序。写死会在"表里有、数组里没有"时静默漏印一项，
    # 而分派不看分组、照样能敲到它——用户看见的菜单和能敲的菜单就不是同一件事。
    foreach ($g in (Get-MenuGroups)) {
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
    [void]$out.Add("  输编号后回车执行    直接回车 = 查看状态")
    return ($out -join "`n")
}

# 帮助里「菜单每一项是干什么的」那一屏的正文，从 $MenuItems 生成。
# 为什么生成而不是手抄：手抄的那一份在改菜单时会静默过期，症状是用户照帮助里的
# 编号去敲，敲到的是另一件事（想检查更新，结果卸载了）。生成之后这份内容与菜单
# 读同一张表，改表即同步，不存在"两边都要记得改"。
function Get-HelpMenuLines {
    $out = New-Object System.Collections.Generic.List[string]
    $nameW = Get-MenuNameWidth
    [void]$out.Add('这些编号要在主菜单里敲，不是在帮助里敲。')
    foreach ($g in (Get-MenuGroups)) {
        $items = @($MenuItems | Where-Object { $_.Group -eq $g })
        if ($items.Count -eq 0) { continue }
        [void]$out.Add('')
        if ($g -eq '日常') { [void]$out.Add(($g + '（平时只会用到这些）')) } else { [void]$out.Add($g) }
        foreach ($mi in $items) {
            if ($mi.Hint) {
                [void]$out.Add(('  ' + $mi.Key + '  ' + (Format-MenuCell $mi.Name $nameW) + '  ' + $mi.Hint))
            } else {
                # 每个菜单项都必须有 Hint（上面那张表里写全）。这里留空只是兜底，
                # 不再拼"什么都不做。直接按回车等于查看状态"——那句话本身就自相矛盾
                # （0 明明会关掉窗口，而在帮助页里回车是退回上一级，不是查看状态）。
                [void]$out.Add(('  ' + $mi.Key + '  ' + (Format-MenuCell $mi.Name $nameW)))
            }
        }
    }
    return $out
}

# 帮助的内容表：每个主题一屏放得下，进帮助先看目录，选一个只看那一段。
# 为什么这么分：一次性把十几屏内容全刷出来，看到后面已经忘了前面讲什么；
# 按"我此刻想解决什么"分主题，再配一个固定的返回行，用户随时能退回来换一段看。
# 每条格式：键 / 标题（目录里显示）/ 正文行数组。
function Get-HelpTopics {
    return @(
        @{
            Key = '1'; Title = '这是干什么用的'; Short = '用处'
            Lines = @(
                '它做什么',
                '  翻墙软件一开，终端里的 git、npm、curl 就能翻墙；',
                '  一关，它们自动恢复直连。不用记任何开关。',
                '',
                '它怎么判断你现在在翻墙',
                '  每 2 到 3 秒看一次。要同时满足三条才算：',
                '    1. 本机有端口在监听；',
                '    2. 它确实是个代理，会回应握手；',
                '    3. 它确实连得通外面，试 7 个站点任意一个通就算。',
                '  三条全过才写变量。所以本机开着网页服务、开发服务器都不会被误判。',
                '  它不认品牌、不认进程名、不认端口号，那些只用来加快扫描。'
            )
        },
        @{
            Key = '2'; Title = '装完之后要我做什么'; Short = '装完'
            Lines = @(
                '装完之后，按窗口分三种情况',
                '',
                '  1. 装完之后才打开的窗口',
                '     启动时读到的就是当前状态，什么都不用做。',
                '',
                '  2. 装完之后打开的窗口，后来代理又变了',
                '     按一次回车即可（cmd 窗口只能重开，见下面第 3 条）。',
                '',
                '  3. 装之前就已经开着的窗口',
                '     同步代码还没装进去。PowerShell 输入下面这条，或者重开窗口：',
                '         . $PROFILE',
                '',
                '     Git Bash 输入：source ~/.bashrc',
                '',
                '     cmd 没有这个办法，重开窗口就行。',
                '',
                '为什么要按一次回车',
                '  每个程序只在启动那一刻读一次环境变量，读完就固定了。之后系统改了，',
                '  已经在跑的窗口不会跟着变。EnvProxy 挑的时机是每次命令跑完、',
                '  等你回到能打字的状态时同步——你本来就一直在敲命令，不用专门做什么。'
            )
        },
        @{
            Key = '3'; Title = '这个窗口固定直连 / 恢复自动'; Short = '窗口'
            Lines = @(
                '一、固定直连（这个窗口不再自动跟随）',
                '  PowerShell 输入：',
                '      $env:ENVPROXY_TERM = ''off''',
                '  Git Bash 输入：',
                '      export ENVPROXY_TERM=off',
                '  设上之后这个窗口一直直连，你自己设的值（比如公司代理）不动。',
                '',
                '  cmd 没有这个开关，自己把 5 个变量清掉（& 两边别留空格）：',
                '      set HTTP_PROXY=&set HTTPS_PROXY=&set ALL_PROXY=&set NO_PROXY=&set NODE_USE_ENV_PROXY=',
                '',
                '  别用 unset HTTP_PROXY：我们写进 Git Bash 的是小写拼写，',
                '  unset 大写的清不掉小写，curl 照样走代理，下个提示符还会写回来。',
                '',
                '二、恢复自动跟随',
                '  PowerShell：Remove-Item Env:ENVPROXY_TERM',
                '  Git Bash：unset ENVPROXY_TERM',
                '  cmd：重开窗口就是自动跟随',
                '  窗口一关，上面这些改动全部失效。'
            )
        },
        @{
            Key = '4'; Title = '这个窗口走公司代理'; Short = '代理'
            Lines = @(
                '先做第 3 条（固定直连），再设地址。顺序反了等于没设。',
                '',
                '一、设地址（换成公司给的）',
                '  PowerShell 输入：',
                '      $env:HTTPS_PROXY = ''http://你的地址:端口''',
                '',
                '  cmd 输入：',
                '      set HTTPS_PROXY=http://你的地址:端口',
                '',
                '  Git Bash 输入：',
                '      export HTTPS_PROXY=http://你的地址:端口',
                '',
                '二、看现在走不走代理（有值 = 走，空的 = 直连）',
                '  PowerShell 输入：',
                '      $env:HTTPS_PROXY',
                '',
                '  cmd 输入：',
                '      set HTTPS_PROXY',
                '',
                '  Git Bash 输入：',
                '      echo $HTTPS_PROXY',
                '',
                '端口是你公司给的，问 IT 要（通常会给一份代理设置说明）。',
                '注意：这里不是翻墙软件那个端口，别去那儿找。',
                '你手设的值不会被删，只清和工具写入值相同的那些。'
            )
        },
        @{
            Key = '5'; Title = '我要让某条命令不走代理'; Short = '命令'
            Lines = @(
                '不同工具写法不一样，没有通用的一条命令',
                '',
                'curl',
                '     curl.exe --noproxy "*" https://example.com',
                '  只有 PowerShell 5.1 必须写 .exe：它把 curl 和 wget 都当成了别名。',
                '  cmd 和 PowerShell 7 里 curl 就是真的 curl.exe，写不写都行。',
                '',
                'git',
                '     git -c http.proxy= -c https.proxy= clone https://github.com/git/git.git',
                '  等号后留空，这条就不用代理；写别的值，就改用那个代理。',
                '',
                'npm',
                '     npm --noproxy=registry.npmjs.org install typescript',
                '  注意：只认具体网址，写 * 没用，而且不报错，请求照常走代理。',
                '  写成 --no-proxy 会被理解成关闭代理，也不是你要的效果。',
                '  另外 npm 只认 HTTPS_PROXY，不认 HTTP_PROXY。',
                '',
                'wget',
                '  Windows 不自带 wget。自己装过才用得上这一条：',
                '     wget.exe --no-proxy https://example.com',
                '',
                'docker',
                '  没有单条命令的写法，改 Docker 自己的设置（Settings 里的 Proxies）。'
            )
        },
        @{
            Key = '6'; Title = '菜单每一项是干什么的'; Short = '菜单'
            Lines = @(Get-HelpMenuLines)
        },
        @{
            Key = '7'; Title = '装了还是连不上网 / 状态不对'; Short = '连不上'
            Lines = @(
                '连不上网，按这个顺序查',
                '  1. 在那个窗口里看变量有没有值。PowerShell 输入：',
                '       $env:HTTPS_PROXY',
                '     空的就是没注入，重开一个窗口就好。',
                '',
                '  2. 有值还是连不上：看菜单顶上「监控」是不是未运行。',
                '     未运行就选 1（安装 / 修复）。',
                '',
                '  3. npm 只认 HTTPS_PROXY，不认 HTTP_PROXY；你自己清过它就不走了。',
                '',
                '状态页怎么读',
                '  监控进程  后台程序在不在跑',
                '  开机自启  下次登录会不会自动起来',
                '  翻墙代理  本机有没有翻墙软件在监听端口',
                '  终端同步  已经开着的窗口会不会跟着变',
                '  代理变量  这个工具往终端里设代理了没有',
                '  「翻墙代理」有、「代理变量」无 = 翻墙在跑、工具被你停了，不是坏了。',
                '  其余几行是系统代理、版本号、更新状态。',
                '',
                '日志和 AI 排查',
                '  日志在 win\monitor\monitor.log，反馈附最后 20 行。',
                '  AI 报 ECONNREFUSED 127.0.0.1:端口号 = 变量指向了已关闭的端口，',
                '  不是网络坏了。菜单选 2 看「代理变量」那行会直接说清。',
                '  它只管 HTTP/HTTPS 变量；ping、游戏、BT 这类走自己协议的',
                '  不认——那些要开翻墙软件的 TUN 模式。'
            )
        },
        @{
            Key = '8'; Title = '还是不行 / 想删掉它'; Short = '不行'
            Lines = @(
                '大部分问题都可以用「安装 / 修复」解决',
                '  打开菜单选 1。它不会重复安装，不会中断网络，也不会丢失你的设置。',
                '',
                '还是不行',
                '  菜单选 2 把状态截图，再选 1 修复一次。反馈时附上 monitor\monitor.log',
                '  最后 20 行，能省很多来回。',
                '',
                '想彻底删掉它',
                '  菜单选 6（一键恢复）。会问你要不要留日志。',
                '',
                '不开菜单也能用（适合写脚本，或远程连过来）',
                '  开关：-Install  -Status  -Stop  -Uninstall  -Update  -Help  -Menu',
                '  -Purge 连日志一起删，只配 -Uninstall 用。完整写法：',
                '      powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Status'
            )
        }
    )
}

# 帮助目录：只列标题，一屏放得下。
function Format-HelpIndex {
    $out = New-Object System.Collections.Generic.List[string]
    [void]$out.Add('================ EnvProxy 帮助 ================')
    [void]$out.Add('')
    # 这里原来写「想知道什么，就输它的编号」，和底部提示重复了一遍；
    # 换成一句真正有用的话：告诉他这些条目是按「我遇到什么」排的。
    [void]$out.Add('  按你遇到的问题挑一条：')
    foreach ($t in (Get-HelpTopics)) {
        [void]$out.Add(('    {0}  {1}' -f $t.Key, $t.Title))
    }
    [void]$out.Add('')
    $ver = Get-LocalVersion
    if ([string]::IsNullOrWhiteSpace($ver)) { $ver = '未知' }
    [void]$out.Add(('  本机版本 v{0}' -f $ver))
    [void]$out.Add('')
    [void]$out.Add('  输编号查看    直接回车 = 回主菜单')
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
    # 顶格、且不像一句完整的话 = 小标题。
    # 判据只看结构、不看长度：长度上限是个任意数字，而它与 Mac 侧一旦不一致，
    # 同一条标题就会在两端显示成不同颜色——同一个产品两种观感。句子才带句末标点，
    # 标题不带，这条区分是稳定的，也不怕以后把标题写长一点。
    if ($indent -eq 0) {
        if ($body -notmatch '[。；，]') { return 'heading' }
        return 'text'
    }
    if ($body -match '^(注意|别|不要|小心)') { return 'warn' }
    # 命令行 = 缩进 4 格以上，且这一行没有任何中日韩字符。
    # 判据不能是"看起来像不像命令"：只要允许中英混排，「cmd 和 Git Bash 没这个开关」
    # 这种说明就会因为开头是字母而被染成命令色。颜色一错，整屏就显得乱，而且会
    # 把"能整行复制去跑的一行"和"只是提到命令的一行"混成同一种视觉。
    # 反过来这条也给内容立了规矩：命令行必须能整行复制去跑，中文说明另起一行。
    if ($indent -ge 4 -and $body -notmatch '[\u4e00-\u9fff\uff00-\uffef]') { return 'cmd' }
    if ($body -match '^\d+[.、)]\s' -or $body -match '^\d+\s{2}') { return 'item' }
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
# 主题页底部那一行：把全部编号和短名并排列出来，当前这条用方括号标。
# 为什么需要它：用户在主题里只看到「输编号看别的」，却不知道别的编号是几号——
# 那句话等于白说。列出编号既回答了"编号是什么"，也顺手回答了"还有哪几条"。
# 编号与短名都从表里取，加一条主题时这里自动跟上，不会留下写死的旧数字。
# 可用的编号范围，从表里算：加一条主题就自动变成 "有 1-8"，不会留下写死的旧范围。
# 菜单可用的编号，从表里算：加一项就自动变成 "1-6 和 0"，不会留下写死的旧范围。
# 和帮助的 Format-HelpKeyRange 同一个思路——改数字的地方只该有一处。
# 把一组编号写成人话。连续就写「1-6」，中间有断层就逐个列出来。
# 为什么不能只取首尾：从表里删掉一项之后，首尾相减仍然给出「1-6」，
# 而那段时间里 4 已经不存在了——用户照着敲 4，得到「没有这个编号」。
# 提示的用途是告诉他能敲什么，说错比不说更糟。
function Format-KeyList([string[]]$Keys) {
    if ($Keys.Count -eq 0) { return '' }
    if ($Keys.Count -eq 1) { return $Keys[0] }
    $ints = @($Keys | ForEach-Object { [int]$_ } | Sort-Object)
    $contiguous = $true
    for ($i = 1; $i -lt $ints.Count; $i++) { if ($ints[$i] -ne $ints[$i - 1] + 1) { $contiguous = $false; break } }
    if ($contiguous) { return ($ints[0].ToString() + '-' + $ints[$ints.Count - 1].ToString()) }
    return (($ints | ForEach-Object { $_.ToString() }) -join ' ')
}

function Get-MenuKeyRange {
    $keys = @($MenuItems | Where-Object { $_.Switch } | ForEach-Object { $_.Key })
    $quit = @($MenuItems | Where-Object { -not $_.Switch } | ForEach-Object { $_.Key })
    if ($keys.Count -eq 0) { return '没有可用的编号' }
    $text = Format-KeyList $keys
    if ($quit.Count -gt 0) { $text += ' 和 ' + ((@($quit | ForEach-Object { [int]$_ } | Sort-Object) | ForEach-Object { $_.ToString() }) -join ' ') }
    return $text
}

function Format-HelpKeyRange {
    $keys = @(Get-HelpTopics | ForEach-Object { $_.Key })
    if ($keys.Count -eq 0) { return '没有可用的编号' }
    if ($keys.Count -eq 1) { return '只有 ' + $keys[0] }
    return ('有 ' + (Format-KeyList $keys))
}

function Format-HelpNavLine([string]$CurrentKey) {
    $parts = @()
    foreach ($t in (Get-HelpTopics)) {
        $label = if ($t.Key -eq $CurrentKey) { '[' + $t.Key + ']' + $t.Short } else { $t.Key + ' ' + $t.Short }
        $parts += $label
    }
    return ('  ' + ($parts -join '  '))
}

function Format-HelpTopic([string]$Key) {
    $t = @(Get-HelpTopics | Where-Object { $_.Key -eq $Key })
    if ($t.Count -eq 0) { return $null }
    $t = $t[0]
    $out = New-Object System.Collections.Generic.List[string]
    [void]$out.Add(('================ 帮助 {0} · {1} ================' -f $t.Key, $t.Title))
    [void]$out.Add('')
    foreach ($l in $t.Lines) { [void]$out.Add($l) }
    [void]$out.Add('')
    [void]$out.Add((Format-HelpNavLine $t.Key))
    [void]$out.Add('  输编号看别的    直接回车 = 回目录')
    return ($out -join "`n")
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
    Write-Host ((Format-HelpNavLine $t.Key))
    Write-Host '  输编号看别的    直接回车 = 回目录'
    return $true
}

# 全文：把所有主题按顺序拼起来，一个字不少。
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
# 交互只有两种操作，和菜单完全一样：
#   输数字 = 去看那一条；直接回车 = 回上一级。
# 不用 n / p / m / a 这些字母：用户记不住哪个键管哪件事，
# 而"输编号"和"按回车"不需要学。条目不多，一屏列得下，也就没有翻页的必要。
function Show-Help([switch]$All) {
    if ($All -or -not (Test-CanPrompt)) {
        Write-Host (Format-HelpAll)
        return
    }
    # $cur 为空 = 当前在目录页；非空 = 正在看那一条。
    # 用一种状态表达两页：换主题时才不会跳回目录，也不用嵌套循环把逻辑写两遍。
    $cur = ''
    while ($true) {
        if (-not $cur) {
            Clear-Screen
            Write-Host (Format-HelpIndex) -ForegroundColor Cyan
        }
        $sel = ''
        try { $sel = "$(Read-Host '输编号，或直接回车')".Trim() } catch { return }
        if (-not $sel) {
            # 回车：在主题里回目录，在目录里回主菜单。
            if ($cur) { $cur = ''; continue }
            return
        }
        # q 和 0 与「直接回车」同义：菜单里 q/0 都是退出，刚在菜单学会按 q 的人，
        # 进到帮助再按就被判成"没有这一条"，会以为帮助坏了。不写进屏幕，只是别拒绝他。
        if ($sel -eq 'q' -or $sel -eq 'Q' -or $sel -eq '0') {
            if ($cur) { $cur = ''; continue }
            return
        }
        # 先查表、有效才清屏：输错时把当前这屏留在屏幕上，用户还能照着挑。
        # 与菜单屏一致（输错不重画），不该一屏一个做法。
        if (-not (Test-HelpKey $sel)) {
            Write-Host ("没有这一条：{0}（{1}）" -f $sel, (Format-HelpKeyRange)) -ForegroundColor Yellow
            continue
        }
        Clear-Screen
        [void](Show-HelpTopicColored $sel)
        $cur = $sel
    }
}

# 这个编号有没有对应的帮助主题。输错时用它来决定"要不要清屏"：
# 无效就保留当前屏（用户还要照着挑），有效才换屏。
function Test-HelpKey([string]$Key) {
    return [bool]@(Get-HelpTopics | Where-Object { $_.Key -eq $Key }).Count
}

function Show-Menu {
    # 非交互 stdin（管道/重定向）直接退出不进循环：菜单是给人点的，自动化请用开关。
    # 否则管道到 EOF 时 Read-Host 读空会被当成回车，一遍遍重复默认动作停不下来。
    try {
        if (-not (Test-CanPrompt)) {
            Write-Host "菜单需要双击 打开菜单.cmd 使用，管道调用请直接用 -Install/-Status/-Stop/-Uninstall/-Update/-Help 开关。" -ForegroundColor Yellow
            return
        }
    } catch {}
    # 两轮两种画法：重画整张菜单（首次进入、子命令结束后），或者什么都不画
    # （输错编号那一轮）。之前用布尔量只能表达"清不清屏"，所以输错时仍会重画
    # 整张菜单，连错几次屏幕就滚得找不到位置——而注释里承诺的恰恰相反。
    $mode = "menu"
    while ($true) {
        if ($mode -eq "menu") { Clear-Screen; Show-MenuColored }
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
            # 输错只补一行，菜单本身留在原位：重画一遍会让屏幕不停往下滚，
            # 连错几次就再也找不到自己在哪了（ADHD 用户尤其受不了）。
            Write-Host ("没有这个编号：{0}（可用的有 {1}）" -f $choice, (Get-MenuKeyRange)) -ForegroundColor Yellow
            $mode = "none"
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
        # 子命令跑完先停一下：下一轮开头就要清屏，不等一下就把它刚打印的内容抹掉了。
        try { $null = Read-Host '按回车回菜单' } catch { return }
        $mode = "menu"
    }
}
