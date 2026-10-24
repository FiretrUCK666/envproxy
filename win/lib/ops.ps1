# ==============================================================================
#  ops.ps1 — 动作层：菜单背后的安装、停止、卸载、状态编排
#  把下面各层拼成使用者点得到的行为。
# ==============================================================================

# ------------------------------------------------------------------------------
# 7. 子命令实现
# ------------------------------------------------------------------------------
function Install-EnvProxy {
    Write-Styled 'title' "======== EnvProxy 安装 ========"
    if (Test-IsElevated) { Write-Styled 'warn' "当前是管理员身份：接下来改的会是管理员这个账号的配置。日常使用请用普通终端重来一次。" }
    # 先说清楚要动什么、不动什么，再说"正在做"——安装要改四处系统设置，
    # 用户在按完编号之后得先知道会发生什么，而不是盯着静止的屏幕猜。
    Write-Styled 'text' "会改这 4 处：开机自启、终端配置、环境变量、后台监控。"
    Write-Styled 'dim' "不会动你的其他设置。"
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
        Write-Styled 'ok' "[1/4] 开机自启动：已写入"
    } else {
        Write-Styled 'warn' "[1/4] 开机自启动：没写成。可能被杀软或组策略拦住了。"
        Write-Styled 'warn' "      请检查杀软拦截，或再打开一次菜单选 1（安装 / 修复）；仍然不行就把它加进白名单。"
    }
    # 首次安装的判据必须在写路径记录**之前**取：写完这台机器上就有记录了，再判永远是"重装"。
    # 差别在于本机地址的代理变量算谁的——首次安装时它只可能是使用者自己的。
    $firstInstall = -not ((Get-ItemProperty (Get-ScriptPathRegKeyPath) -Name "ScriptPath" -ErrorAction SilentlyContinue).ScriptPath)
    Update-ScriptPathRecord
    # 先快照用户原值，再动任何东西：监控一启动就会在几秒内自愈、把代理变量写进去，
    # 那时再快照，存下的就是"我们写下的值"而不是用户原值，卸载还原会留下我们的条目。
    # （快照只记一次；已经存在时这里是无副作用的空操作。）
    Snapshot-PrevEnv -FirstInstall:$firstInstall
    # 装没装上由返回值决定，不由"我调用过启动"决定（与自启动项读回复检同一条规矩）。
    # 这一步在慢机器上可能花一两秒，先说一声，别让屏幕静止不动。
    Write-Styled 'dim' "[2/4] 正在启动后台监控……"
    $step2Ok = $false
    try { $step2Ok = Start-Monitor -Force:$true } catch {}
    if ($step2Ok) {
        Write-Styled 'ok' "[2/4] 监控进程：已启动"
    } else {
        Write-Styled 'warn' "[2/4] 监控进程：未能确认运行，原因见下面那两行。"
    }
    # 立即对齐环境变量状态：有代理 → 注入；无代理 → 清理残留死变量
    # （不等监控的双轮去抖，"安装"即"一键修复"）
    # 先说要探测，因为这三层验证要连外网，慢的时候差不多一秒。
    Write-Styled 'dim' "[3/4] 正在确认翻墙软件在不在（有端口、是代理、真能连出去）……"
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
        Write-Styled 'warn' "[3/4] 环境变量：这一轮没读到本机端口，所以没有改动任何设置（正常，会自动重试）。"
    } elseif ($state -eq "failed") {
        Write-Styled 'warn' "[3/4] 环境变量：这一步没做成，原因见上面那行。其余步骤不受影响。"
    } elseif (-not $appliedOk) {
        # 写失败必须如实说，不能说"已校正"——用户会以为在走代理，实际是半套变量。
        Write-Styled 'warn' "[3/4] 环境变量：没写进去。可能被杀软或组策略拦住了。"
        Write-Styled 'warn' "      再打开一次菜单选 1（安装 / 修复）重试；仍然不行请反馈。"
    } else {
        Write-Styled 'ok' "[3/4] 环境变量：已按当前状态校正"
    }
    # 终端同步：写 $PROFILE 里的钩子块，让已经开着的窗口也能跟上。
    # 失败不阻断安装（其余三件事已经做成），但必须如实说清原因，不许报成功。
    Write-Styled 'dim' "[4/4] 正在写终端配置……"
    $prof = $null
    try { $prof = Install-ShellProfile } catch { $prof = [pscustomobject]@{ Reason = "error"; Path = "" } }
    switch ($prof.Reason) {
        'installed'  { Write-Styled 'ok' "[4/4] 终端同步：已写进 PowerShell 和 Git Bash 的配置文件" }
        'current'    { Write-Styled 'ok' "[4/4] 终端同步：已是最新（PowerShell 与 Git Bash 都已在位）" }
        'no-profile' { Write-Styled 'warn' "[4/4] 终端同步：取不到 $PROFILE 路径，跳过（新窗口仍会生效）" }
        'unpaired'   {
            Write-Styled 'warn' "[4/4] 终端同步：配置文件里的标记不成对，未改动它（安全起见一个字节都没动）"
            Write-Styled 'dim' ("      " + $prof.Path)
        }
        default      {
            Write-Styled 'warn' ("[4/4] 终端同步：写入失败（" + $prof.Reason + "）")
            Write-Styled 'dim' ("      " + $prof.Path)
        }
    }
    $polWarn = Get-ProfileExecutionPolicyWarning
    if ($polWarn) { Write-Styled 'warn' ("      " + $polWarn) }
    Start-Sleep -Seconds 1
    Write-Host ""
    # 这里**不联网**：版本号取自监控写下的缓存（状态页只读、永不联网那条契约）。
    # 所以不能说"正在联网确认"——那是在描述一件不会发生的事，用户会以为
    # 网慢/被墙导致"检查失败"，而实际根本没发请求。
    Write-Styled 'dim' "正在看当前状态（版本号取自监控缓存，不联网）……"
    Show-Status
    Write-Host ""
    # 左边那一列用 Format-MenuCell 按最长的条目补齐，不靠手敲空格：
    # 手敲的话，改一个字就整列歪掉，而"歪一格"这种事只有人眼看得出来。
    Write-Styled 'ok' "装好了。之后怎么用："
    # 每一行三格：左列标签 / 右列的说明 / 右列里那段能照抄的命令（没有就留空）。
    # 命令单独列一格、而不是靠正则从整行里认出来——认形状会错：
    # "在它里面执行  $env:ENVPROXY_TERM = 'off'" 开头不是命令，
    # 整行就被判成说明（暗），用户看不出哪一段能复制。这正是配色坏过的老原因。
    $tipRows = @(
        @('新开的终端 / 程序', '自动就是对的，什么都不用做。', ''),
        @('一直开着的窗口', '敲一下回车就跟上（cmd 窗口只能重开）。', ''),
        @('装之前就开着的窗口', '重开一个，或者手动加载一次', ''),
        @('', '菜单选 4（帮助）第 2 条，各种终端都有现成命令。', ''),
        @('想让某个窗口固定直连', '在它里面执行', "`$env:ENVPROXY_TERM = 'off'"),
        @('改回跟着翻墙软件走', '在它里面执行', 'Remove-Item Env:ENVPROXY_TERM'),
        @('忘了怎么用', '菜单选 4（帮助）。', '')
    )
    $tipW = 0
    foreach ($r in $tipRows) {
        $len = Get-DisplayWidth $r[0]
        if ($len -gt $tipW) { $tipW = $len }
    }
    foreach ($r in $tipRows) {
        $cell = if ($r[0]) { Format-MenuCell $r[0] $tipW } else { ' ' * $tipW }
        # 左列是标签（暗）、右列说明是正文（默认色）、命令是绿色。
        # 三层各司其职才有"哪一段能复制"这回事；整行一个颜色等于没有层次。
        Write-Styled 'dim' ('   ' + $cell + '   ') -NoNewline
        Write-Styled 'text' $r[1] -NoNewline
        if ($r[2]) { Write-Styled 'cmd' ('  ' + $r[2]) } else { Write-Host '' }
    }
}

function Uninstall-EnvProxy([bool]$Purge = $false, [bool]$Yes = $false) {
    Write-Styled 'title' "======== EnvProxy 卸载（一键恢复原状）========"
    if (Test-IsElevated) { Write-Styled 'warn' "当前是管理员身份：接下来改的会是管理员这个账号的配置。日常使用请用普通终端重来一次。" }
    # 先问一句再动手。这是整个工具里**唯一不可逆**的动作：会删开机自启、摘终端配置、
    # 清掉代理变量。而它在菜单里紧挨着「5 停止监控」（那个是可逆的，"下次开机会自己回来"），
    # 手滑按错就没有回头路。原来全函数里唯一的提问是"日志要不要保留"——
    # 而那时监控已停、自启已删、配置已摘，问什么都晚了。
    # 默认 N（回车 = 不卸载）：危险动作的默认必须是"不做"。
    # -Purge（清日志）本身就是"我知道我在干什么"的显式意图，但它不清这个确认——
    # 意图明确的是"日志"，不是"卸载"。
    # 确认必须在**任何**环境下生效，包括管道/脚本里：
    # 危险动作"问不到人就直接做"等于没有确认（实测过一次，管道里跑 -Uninstall 直接卸干净了）。
    # 问不到人时的正确行为是**拒绝并要求显式意图**，不是默默执行。
    $confirmed = $false
    if ($Yes) {
        # 显式声明"跳过确认"。这一支存在的意义正是非交互环境：
        # 问不到人的时候必须靠一个明确的开关放行，而不是靠沉默。
        $confirmed = $true
        Write-Styled 'dim' "已确认（-Yes）：开始卸载。"
    } elseif (Test-CanPrompt) {
        Write-Styled 'text' "卸载后会删掉开机自启、终端配置和代理变量，恢复成没装之前的样子。"
        try {
            $a = Read-Host "确定要卸载吗？输入 y 回车确认，直接回车 = 取消"
            $confirmed = [bool]($a -and $a.Trim() -match '^(y|yes|是)$')
        } catch { $confirmed = $false }
        if (-not $confirmed) {
            Write-Styled 'dim' "已取消，什么都没改。"
            return
        }
    } else {
        # 没有可交互的控制台：不能问，也不能替用户答应。
        Write-Styled 'warn' "这里没法问你要不要卸载（没有可交互的控制台），所以什么都不会做。"
        Write-Styled 'dim' "  真的要卸载，请双击 打开菜单.cmd 选 6；"
        Write-Styled 'dim' "  或者确认无误后加 -Yes：envproxy.ps1 -Uninstall -Yes"
        return
    }
    Stop-Monitor
    Remove-AutoRun
    # 先摘终端同步的钩子块：它引用 $ProxyVarNames，留着会指向一个已经卸载的工具。
    # 只摘我们那一块，用户 profile 里其余内容一字不动（不成对时一个字节都不改）。
    $profRm = Remove-ShellProfile
    if ($profRm.Ok) {
        if ($profRm.Reason -eq 'removed') { Write-Styled 'ok' "终端同步：已从 PowerShell 和 Git Bash 的配置文件里移除" }
    } else {
        Write-Styled 'warn' ("终端同步：没能移除（" + $profRm.Reason + "），可手动删掉下面文件里 EnvProxy 标记的那几行：")
        Write-Styled 'dim' ("  " + $profRm.Path)
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
    Remove-Item -LiteralPath (Get-ScriptPathRegKeyPath) -Recurse -Force -ErrorAction SilentlyContinue
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
    $epHome = Get-ToolHomeDir
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
        # 先判"能不能问"再问。没有护栏时它照样能返回（stdin 重定向到 nul 时 Read-Host
        # 立即返回空串，实测 0 秒），但那是**碰巧**安全的：屏幕上的提问没人看得见、
        # 也没人能答，等于问了一个注定被当成"保留"的问题。
        # 明确不提问、直接按默认值走，比"问了个没人能答的问题"更清楚。
        if (Test-CanPrompt) {
            try {
                $choice = Read-Host "历史日志 monitor\monitor.log 是否保留？[Y] 保留（默认） / [N] 彻底删除"
                if ($choice -match '^[Nn]') { $removeLog = $true }
            } catch {
                $removeLog = $false
            }
        } else {
            # 无交互环境（管道/后台调用）：安全默认 = 保留日志（黑匣子留着，日后能查）
            $removeLog = $false
            Write-Styled 'dim' "历史日志默认保留（这里没法提问；要一并删除请用 -Uninstall -Purge）。"
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
        # 保留历史日志（黑匣子，便于日后排查），只删运行时临时文件。
        # 卸载 = 恢复成没装过：所有运行时状态都不该活过它，唯一保留的是黑匣子日志。
        # 漏掉任何一个的后果都很具体：version.cache 会让重装后的状态页显示上一次的版本号；
        # update.inprogress 会被读成"上次更新没完成"（那是上一次安装的经历）；
        # stopped.intent 一删就够，留着会让重装后的状态页说"你点过停止"而监控正在跑；
        # monitor.beat 是上一个进程的心跳，留着会让"监控还活着吗"读到过期的答案。
        Remove-ItemSafe $PidFile
        Remove-ItemSafe $StopFlag
        Remove-ItemSafe $StopIntentFile
        Remove-ItemSafe $VersionCacheFile
        Remove-ItemSafe $UpdateInProgressFile
        Remove-ItemSafe $HeartbeatFile
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
    if (Test-RegKey (Get-ScriptPathRegKeyPath)) { $dirty += ("路径记录仍在：注册表 " + (Get-ScriptPathRegKeyPath)) }
    # 我们装进 ~/.envproxy 的只有 prompt-sync.sh 一个文件。它删不掉才算脏。
    $epHome = Get-ToolHomeDir
    if (Test-Item (Join-Path $epHome "prompt-sync.sh")) { $dirty += ("Git Bash 同步脚本副本仍在：" + (Join-Path $epHome "prompt-sync.sh")) }
    # 目录里别的东西**不算脏**，也不删：可能是使用者自己放的，删错比留着糟。
    # 但它必须被说出来，否则用户对着一个不知道是什么的文件夹发呆。
    # 这一条走单独一句、不进"没清干净"：卸载确实完成了自己的部分，
    # 报成"未完成"会让人再选一次「一键恢复」——那对他毫无作用，因为我们本来就不删它，
    # 而"照上面列出的位置手动删"更会让他删掉本来不该动的东西。
    # 措辞也不用"不是本工具写的"：实测这种情况多半就是本工具另一个平台版本写的
    # （在 Git Bash 里跑过 macOS 版的 install），说成外人的残留会让人以为中毒。
    $epLeftover = @()
    if (Test-Item $epHome) {
        $epLeftover = @(Get-ChildItem -LiteralPath $epHome -Force -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -ne 'prompt-sync.sh' } |
                        ForEach-Object { $_.Name })
    }
    if ((Test-Item $PidFile) -or (Test-Item $StopFlag)) { $dirty += "监控运行时文件仍在" }
    # 变量复检不用整表判据：有快照的名字必须与快照一致（用户原值含重合项也算干净），
    # 只有没快照的名字才按"有无我们的痕迹"判——否则正确的还原会被误报成残留。
    $varsClean = $true
    foreach ($n in $ProxyVarNames) {
        # 必须用**不展开**的读法：$restoredWant 来自 Backup 键的 REG_EXPAND_SZ 原文
        # （可能含 %USERPROFILE%），而 GetEnvironmentVariable 读出来是展开后的字面路径。
        # 拿展开值跟原文比，凡是快照里带引用的变量都必然"不相等"——功能其实已正确还原，
        # 复检却报"代理变量仍在"，还提示用户去手动删。用户照做就会删掉自己公司代理的
        # NO_PROXY 项。同一条判据的两端必须是同一种读法。
        $cur = Get-UserEnvRaw $n
        if ($restoredWant.ContainsKey($n)) { if ($cur -ne $restoredWant[$n]) { $varsClean = $false } }
        elseif (Test-IsOwnedProxyValue $n $cur) { $varsClean = $false }
    }
    if (-not $varsClean) { $dirty += "代理变量仍在" }
    if (Get-MonitorProcess) { $dirty += "监控进程仍在" }
    # 复检不能只靠一条通道：进程身份原来全走 WMI，而 WMI 被精简工具关掉时它返回空，
    # 于是"监控仍在"这一项永远进不了 $dirty，屏幕上打印"[完成] 已恢复到安装前的状态"，
    # 而实际上监控还活着、还会把自启动项重建回来。
    # 所以补一条**不依赖任何进程查询**的事后判据：卸载已经把 Run 键删掉了，
    # 如果几秒之内它又出现了，那只能是活着的监控自愈写回来的。
    if (-not $dirty.Contains("监控进程仍在")) {
        Start-Sleep -Seconds 3
        $runAfter = (Get-ItemProperty $RunKeyPath -ErrorAction SilentlyContinue).$RunKeyName
        if ($runAfter) { $dirty += "监控进程仍在（开机自启被它重建了）" }
    }
    if ($removeLog -and (Test-Item (Join-Path $MonitorDir "monitor.log"))) { $dirty += "历史日志未能删除" }
    if ($dirty.Count -eq 0) {
        Write-Styled 'ok' "[完成] 监控已停，开机自启、代理变量和定位用的小脚本都已删除。"
        if ($removeLog) {
            Write-Styled 'ok' "        历史日志已一并彻底删除。"
        } else {
            # 这一行说的是"你选择留下的东西在哪"，不是警告。
            # 用 warn（黄）会给一整屏绿色的成功页加一条假警报——同一函数里真正的
            # "没干净"是用 [未完成] 开头那一支。mac 侧本来就是 dim，以它为准。
            Write-Styled 'dim' "        历史日志保留在 monitor\monitor.log（黑匣子，供日后排查）。"
        }
        Write-Styled 'ok' "        电脑已恢复到安装前的状态。新开终端即直连；已经开着的旧窗口重开一个。"
        # 目录里剩下的东西：卸载确实做完了自己那部分，所以放在"完成"之后单独说，
        # 用 dim（背景信息）而不是 warn——它不是警告，是告知。
        # 给绝对路径、不给 ~/.envproxy：Windows 用户没有 ~ 这个概念，而且机器上
        # 还有一个长得很像的 %LOCALAPPDATA%\EnvProxy\，写相对写法更容易找错地方。
        if ($epLeftover.Count -gt 0) {
            Write-Styled 'dim' ("        这个文件夹里还留着几样没有动：" + $epHome)
            Write-Styled 'dim' ("          " + ($epLeftover -join '、'))
            Write-Styled 'dim' "        它们可能是你自己放的（也可能是在 Git Bash 里跑过 macOS 版留下的），"
            Write-Styled 'dim' "        不确定就先留着；确定不要了再自己删，程序不会再用到它们。"
        }
    } else {
        Write-Styled 'warn' "[未完成] 这几处没清干净："
        foreach ($d in $dirty) { Write-Styled 'warn' ("        - " + $d) }
        Write-Styled 'warn' "        再打开菜单选 6（一键恢复）试一次；还不行就照上面列出的位置手动删。"
    }
}

# 状态显示。
# **永不联网、永不写文件、永不提问**：版本号读监控写下的缓存（runtime 层的
# Write-VersionCache / Read-VersionCache）。缓存旧了就如实说"几小时前的记录"，
# 缓存没有就说清"没法确认"并指向更新入口——状态页不替用户做请求。
# 这条不只是为了快：离线、限流、走白名单网络的人，联网检查只会让他每次查看状态
# 都等一个注定失败的请求，而归因通常是"这工具很慢"。门禁 6 的 e1 段守着它。
function Show-Status {
    # 状态对象先在内存里算完，再统一渲染。
    # 为什么不能边算边打印：结论行("一切正常" / "有 N 项要注意")必须出现在最上面，
    # 而它是全部检查跑完之后才知道的。先打印再补结论 = 用户读完 8 行还要自己合成判断。
    # 这一层也是 --json 之类机器可读输出的前提（先有对象，才有第二种渲染方式）。
    $st = Get-StatusSnapshot
    Show-StatusSnapshot $st
}

# 采集状态：只读、不写文件、不提问、不猜。所有值都来自现成函数。
function Get-StatusSnapshot {
    $st = [ordered]@{}
    $st.Monitor = Get-MonitorProcess
    $run = (Get-ItemProperty $RunKeyPath -ErrorAction SilentlyContinue).$RunKeyName
    $launcher = ""
    if ($run -match '-File\s+"?([^"]+\.ps1)"?') { $launcher = $Matches[1] }
    # 自启是否真的会生效：值在，且它指向的脚本真的存在。
    # 只看"值非空"会说谎——卸载不彻底或手工删过文件夹时，登录时什么都不会起来。
    $st.AutoRunRaw = $run
    $st.AutoRunLauncher = $launcher
    $st.AutoRunOk = [bool]($launcher -and (Test-Path -LiteralPath $launcher))
    $st.StopIntent = Test-Item $StopIntentFile
    # 状态页要回答的是"我此刻正常吗"，所以它必须**看得见用户真正在用的那个端口**。
    #
    # 原来这里用快扫（-FullScan:$false，约 55 毫秒）："快"换来的代价是只认
    # 常见端口表 + 进程名。用户把端口改成表外的值（实测 7099）后，快扫返回空，
    # 屏幕打"未检测到（当前无翻墙代理在运行）"；而同一屏的"代理变量"那行
    # 读的是注册表真实值、试连还通着 —— 两行自相矛盾，用户以为工具坏了。
    #
    # 现在改走 Get-InUseProxyPort：先直接验注入值指向的那个端口（那是我们自己写的，
    # 就是用户此刻在用的），命中即返回（约 100 毫秒）；真没命中才退到候选集，
    # 且那里的 FullScan 用 $true——状态页一天点不了几次，"慢 1 秒"远比"说谎"便宜。
    # 探测层本身不写日志：成败与原因放在 $script:PortEnumerationFailed / Reason 里，
    # 记不记由调用方决定（监控每轮记，状态页一次都不记）。
    $st.Port = Get-InUseProxyPort -FullScan:$true
    $st.PortUnknown = [bool]$script:PortEnumerationFailed
    try { $st.TermSync = Get-TerminalSyncState } catch { $st.TermSync = $null }
    $st.ProxyValue = Get-EnvProxyValue
    # 注入值指向的端口还在不在：解析真实值（可能是 IPv4 也可能是 [::1]），按地址族试连。
    # 早先这里用正则只认 127.0.0.1，于是 IPv6-only 的代理整段检查被跳过、直接报"已注入"。
    $st.ProxyHost = $null
    $st.ProxyPort = 0
    # 三态：$true 活着 / $false 端口不在 / $null 说不清（值不是合法地址）。
    #
    # 初值必须是 $null 而不是 $true。原来是 $true，于是"值解析不出来"时整个 if 被跳过、
    # $true 留在原处，变成了结论——屏幕上绿字"已注入 (not-a-url)"、"一切正常"。
    # 这条路径真实可达：注册表被别的工具写成 http://127.0.0.1:0 或半个地址就会命中。
    # 一种"说不清"的默认值必须是"不知道"，不能是"好"：说不知道最多让人多查一眼，
    # 说"一切正常"会让人压根不去查。
    $st.ProxyAlive = $null
    if ($st.ProxyValue) {
        $pp = Split-ProxyUrl $st.ProxyValue
        if ($pp) {
            $st.ProxyHost = $pp.Host
            $st.ProxyPort = $pp.Port
            $st.ProxyAlive = Test-TcpAlive $pp.Host $pp.Port 800
        }
        # 解析不出来就保持 $null：这不是"端口死"，是"这个值根本不是地址"，
        # 处理方式不同——前者等监控自愈，后者要人看一眼变量被谁改坏了。
    }
    # 系统代理是浏览器的世界，不是我们写的，但用户常把它的毛病算到我们头上。
    # 若它指向本机死端口，浏览器全挂而终端正常——提醒一句，绝不动它。
    $st.SysProxy = $null
    try {
        $sp = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction Stop
        if (($sp.ProxyEnable -eq 1) -and ($sp.ProxyServer -match "127\.0\.0\.1:(\d+)")) {
            $spPort = [int]$Matches[1]
            if (-not (Test-TcpAlive "127.0.0.1" $spPort 800)) {
                $st.SysProxy = @{ Server = $sp.ProxyServer; Port = $spPort }
            }
        }
    } catch {}
    # 上次更新是否中途死了：这个标记只有断电/被杀才会留下。
    # 那种情况下入口通常还能起来、启动自检全绿，但安装区可能新旧混合，
    # 表现为某些功能静默失效——所以必须主动说出来。
    $st.UpdateInProgress = Test-Item $UpdateInProgressFile
    # 这台机器上到底装过没装过。判据是安装时写下的路径记录——它只在安装时写、卸载时删。
    # 用途是避免把"从没装过"说成"崩溃/被结束任务"：后者是故障语气，
    # 而首次打开的人看到的应该是"还没装，按 1 就好"，不是"你的东西坏了"。
    $st.NeverInstalled = -not ((Get-ItemProperty (Get-ScriptPathRegKeyPath) -Name "ScriptPath" -ErrorAction SilentlyContinue).ScriptPath)
    $st.LocalVersion = Get-LocalVersion
    # 最新版本号来自**监控写下的缓存**，状态页自己绝不联网：
    # 否则每次"查看状态"都要等一次外网往返（离线/限流时是注定失败的等待）。
    # 写缓存的是监控，状态显示"永不写文件"这条契约不动——写的人换了，不是多了一个。
    $st.RemoteCache = $null
    try { $st.RemoteCache = Read-VersionCache } catch {}
    return $st
}

# 状态页的一行：左列标签固定一种颜色，右侧内容按状态取角色。
#
# 为什么不一整行一个颜色：标签（"监控进程"、"翻墙代理"）是**固定的名词**，
# 它不该随状态变色。整行同色时，状态好的行整行绿、状态无的行整行灰，
# 用户扫一眼看到的是"有的绿有的灰"，却分不清哪一段是名字、哪一段是结论。
# 标签统一用 key（与帮助左列、菜单名字同色），内容按状态用 ok/warn/dim/text，
# 于是"名词—判断"这条结构在任何状态下都长得一样。
function Write-StatusRow([string]$Label, [string]$Value, [string]$Role = 'text') {
    Write-Styled 'key' ($Label + ' : ') -NoNewline
    Write-Styled $Role $Value
}

# 把状态对象渲染成屏幕。纯渲染：不再做任何探测，也不再写任何东西。

function Show-StatusSnapshot($st) {
    # ---- 先把结论算出来：这一屏只回答一个问题"我现在正常吗" ----
    # 读者（尤其是注意力容易被打断的那种）读完 8 行再自己合成判断，是这屏最大的问题。
    # 所以结论放最上面一行，细节在下面；正常项与异常项不再同构平铺。
    $problems = @()
    if (-not $st.Monitor) {
        if ($st.StopIntent) { $problems += "监控按你的选择停着" }
        elseif ($st.NeverInstalled) { $problems += "还没安装" }
        else { $problems += "监控进程不在了（可能被结束任务关掉或崩溃）" }
    }
    if (-not $st.AutoRunOk) { $problems += "开机自启没生效" }
    if ($st.PortUnknown) { $problems += "这一轮没读到本机端口，无法判断代理" }
    if ($st.ProxyValue -and $st.ProxyAlive -eq $false) { $problems += "代理变量指向的端口已经不在" }
    if ($st.ProxyValue -and $null -eq $st.ProxyAlive) { $problems += "代理变量里不是合法地址" }
    # 「没人维护」不是一个独立问题，它是「监控没在跑」的后果。
    # 两个都计进"有 N 项要注意"，用户会以为有两件事要修，而实际只有一件。
    # 所以它只在**监控还在跑、变量却指向死端口**时才需要单独说；
    # 监控没在跑那一支里已经用补充说明讲过了。
    if ($st.TermSync -and $st.TermSync.State -ne 'ok') { $problems += "终端同步没生效" }
    if ($st.SysProxy) { $problems += "系统代理可能残留（不是本工具写的）" }
    if ($st.UpdateInProgress) { $problems += "上次更新没有完成，程序文件可能新旧混合" }

    Write-Styled 'title' "======== EnvProxy 状态 ========"
    if ($problems.Count -eq 0) {
        Write-Styled 'ok' "一切正常，不用做任何事。"
    } elseif ($st.NeverInstalled) {
        # 从没装过：三件"没生效"都是同一个事实（还没装），
        # 说成"有 3 项要注意"会让第一次打开的人以为机器有三处毛病。
        Write-Styled 'dim' "还没开始用。打开菜单选 1（安装 / 修复）就能装上。"
    } else {
        Write-Styled 'warn' ("有 {0} 项要注意：" -f $problems.Count)
        foreach ($p in $problems) { Write-Styled 'warn' ("  - " + $p) }
    }
    Write-Host ''

    # ---- 要注意的：只印有问题的那几项，每项带一句怎么办 ----
    $m = $st.Monitor
    if (-not $m) {
        Write-StatusRow '监控进程' '未运行' 'warn'
        # "停止"是一个稳定状态（自启动只在登录时拉起一次，不保活）。
        # 但"未运行"有两个完全不同的原因，事后长相一样：使用者主动停的，还是进程被
        # "结束任务"关掉/崩溃了。只有执行停止的那一方留下的意图标记能分辨。
        # 不分辨就只能猜：说成"你停的"，被强杀的人会以为自己点错了；什么都不说，
        # 真停过的人会以为坏了。
        if ($st.StopIntent) {
            if ($st.AutoRunOk) {
                Write-Styled 'dim' "  （你点过停止。下次登录会自动恢复，或现在选 1）"
            } else {
                # 两个问题叠在一起时必须说清是两个：点过停止 + 自启记录也坏了。
                Write-Styled 'warn' "  （你点过停止，但开机自启记录也坏了，下次登录不会自动恢复）"
                Write-Styled 'dim' "  打开菜单选 1（安装 / 修复）可以一起修好。"
            }
        } elseif ($st.NeverInstalled) {
            # 从没装过：这不是问题，是起点。用"崩溃/被结束任务"描述它，
            # 第一次打开的人会以为自己的机器出了事（"我明明没装过"）。
            Write-Styled 'dim' "  （还没装过。装上之后它会自己常驻，不用你管）"
            Write-Styled 'dim' "  打开菜单选 1（安装 / 修复）开始使用。"
        } else {
            Write-Styled 'warn' "  （不是点了停止，是进程不在了：可能被结束任务关掉，或崩溃）"
            Write-Styled 'dim' "  打开菜单选 1（安装 / 修复）可以让它重新跑起来。"
        }
    }
    if (-not $st.AutoRunOk) {
        if ($st.AutoRunRaw) {
            Write-StatusRow '开机自启' '记录还在，但启动文件已不存在（登录时不会启动）' 'warn'
            Write-Styled 'dim' ("  记录指向：{0}" -f $(if ($st.AutoRunLauncher) { $st.AutoRunLauncher } else { $st.AutoRunRaw }))
        } else {
            Write-StatusRow '开机自启' '未启用' 'warn'
        }
        Write-Styled 'dim' "  打开菜单选 1（安装 / 修复）可以重建。"
    }
    if (-not $st.ProxyValue -and $st.Port -and -not $m -and -not $st.NeverInstalled) {
        # "翻墙代理有" + "代理变量无" 单独看像自相矛盾。实话是：软件在跑，
        # 但本工具没在它上面工作（多半是用户自己停的）。补一句桥接，否则会被判定"坏了"。
        Write-StatusRow '代理变量' '无（翻墙软件在跑，但本工具已停用，所以没往终端里设代理）' 'dim'
    } elseif ($st.ProxyValue -and $null -eq $st.ProxyAlive) {
        # 值在，但不是个能解析的地址。与"端口已不在"分开说：那个等监控自愈就行，
        # 这个说明变量被别的工具改坏了（写进了半个地址、或者端口是个词）。
        # 不许落绿字"已注入"——那等于告诉用户一切正常。
        Write-StatusRow '代理变量' ("值不是合法地址（{0}）" -f $st.ProxyValue) 'warn'
        Write-Styled 'dim' "  多半是别的工具改写成了半个地址。选 1（安装 / 修复）会按当前代理重写一遍。"
    } elseif ($st.ProxyValue -and -not $st.ProxyAlive) {
        Write-StatusRow '代理变量' ("指向的端口已不在（{0}）" -f $st.ProxyValue) 'warn'
        Write-Styled 'warn' ("  终端里联网会报 ECONNREFUSED，错误里没有本工具的名字，所以你会去查网络。")
        Write-Styled 'dim' "  监控在跑的话几秒内会自动清掉；想立刻清掉就选 1（安装 / 修复）。"
    } elseif ($st.ProxyValue -and -not $m) {
        Write-StatusRow '代理变量' ("已注入（{0}），但没人维护" -f $st.ProxyValue) 'warn'
        Write-Styled 'dim' "  翻墙软件断开后不会自动清掉，终端会连不上。"
        Write-Styled 'dim' "  打开菜单选 1 恢复监控；或选 5 把这批变量一并清掉。"
    }
    if ($st.TermSync) {
        # 注意正常的 'ok' 不在这张表里：它在下面"参考信息"那一段单独打印
        # （正常项与异常项分区显示，不是一个 switch 能表达的）。
        # 这个 switch 只管"有问题的那几种"，default 负责兜住将来新增而这里没跟上的状态。
        switch ($st.TermSync.State) {
            'ok'       { }
            'blocked'  { Write-StatusRow '终端同步' '装了但跑不起来' 'warn'
                         Write-Styled 'dim' ("  " + $st.TermSync.Detail)
                         Write-Styled 'dim' "  按提示改一次，改完重开一个窗口。" }
            'unpaired' { Write-StatusRow '终端同步' '配置文件里的标记不成对，未改动它' 'warn'
                         # 这里不能说"重跑一次安装可修复"——重跑同样会被这条护栏拒绝，
                         # 用户会反复重跑、每次都被"安全起见一个字节都没动"回绝。
                         # 必须给一条真的能做成的动作。
                         if ($st.TermSync.Line) {
                             Write-Styled 'dim' ("  删掉配置文件里孤立的那行标记（第 " + $st.TermSync.Line + " 行）再选 1。")
                         } else {
                             Write-Styled 'dim' "  在配置文件里找到孤立的 EnvProxy 标记行删掉，再选 1。"
                         } }
            'stale'    { Write-StatusRow '终端同步' '同步块是旧版本的' 'warn'
                         # 内容过期不是用户的问题，也不用手工改：安装会按当前版本重写。
                         Write-Styled 'dim' "  这不影响用，只是那段代码旧了；打开菜单选 1 会更新它。" }
            'missing'  { Write-StatusRow '终端同步' '配置文件里没有同步块' 'warn'
                         Write-Styled 'dim' "  打开菜单选 1 可以写入。" }
            'nohost'   { Write-StatusRow '终端同步' '这一轮读不到配置文件路径，无法判断' 'warn'
                         Write-Styled 'dim' "  过几秒再看一次；一直在就选 1。" }
            default    {
                # 走到这里说明 Get-TerminalSyncState 又加了新状态而这里没跟上。
                # 静默跳过不行：上面的问题清单会说"终端同步没生效"，而往下整屏
                # 找不到"终端同步"四个字——用户被指向一个不存在的提示。
                # 这是真发生过的一次（State 叫 nohost，switch 处理的是 unknown，
                # 两者恰好错位，于是这一项永远不打印）。
                Write-StatusRow '终端同步' ("状态未知（" + $st.TermSync.State + "）") 'warn'
                Write-Styled 'dim' "  打开菜单选 1（安装 / 修复）重写一次。"
            }
        }
    }
    if ($st.UpdateInProgress) {
        Write-StatusRow '上次更新' '没有完成（覆盖过程中断）' 'warn'
        Write-Styled 'dim' "  程序文件可能新旧混合，某些功能会静默失效。"
        Write-Styled 'dim' "  打开菜单选 1（安装 / 修复）重做一次即可。"
    }
    if ($st.SysProxy) {
        Write-StatusRow '系统代理' ("疑似残留（指向本机死端口 {0}，非本工具写入）。" -f $st.SysProxy.Server) 'warn'
        # 这一行是"怎么处理"的说明，与它上面那条结论不该同级；
        # 都是 warn 会让整段看起来像两个错误，实际是"一个问题 + 一条办法"。mac 侧本来就是 dim。
        Write-Styled 'dim' "  浏览器打不开先检查它：系统设置 → 网络 → 代理，或把翻墙软件断开重进一次。"
    }
    # 这里**不再**补空行：问题清单那一段末尾（结论行之后）已经空过一行了。
    # 再补一次就在同一屏里出现两个连续空行，本来紧凑的"结论—细节"分组被切出一道缝
    # （实测复现：状态页第 4、5 行都是空行）。
    # ---- 参考信息：正常项压成最少的行，且统一用灰，不跟"要注意"抢注意力 ----
    # 全绿时也要能一眼确认"核心链路是通的"，所以正常的那几项各占一行但用 ok 色；
    # 版本号那三行对普通用户没有行动价值，压成一行。
    if ($m) { Write-StatusRow '监控进程' ("运行中 (PID {0})" -f $m.ProcessId) 'ok' }
    if ($st.AutoRunOk) { Write-StatusRow '开机自启' '已启用' 'ok' }
    if ($st.Port) {
        Write-StatusRow '翻墙代理' ("已开启（本地端口 {0} 监听中）" -f $st.Port) 'ok'
    } elseif ($st.PortUnknown) {
        Write-StatusRow '翻墙代理' '这一轮没读到本机端口，无法判断（正常，会自动重试）' 'warn'
    } else {
        Write-StatusRow '翻墙代理' '未检测到（当前无翻墙代理在运行）' 'dim'
    }
    if ($st.TermSync -and $st.TermSync.State -eq 'ok') {
        Write-StatusRow '终端同步' '已生效（已开着的窗口敲回车即跟上）' 'ok'
    }
    # 代理变量只有"已注入且活着"这一种情况才进参考区；
    # 指向死端口、没人维护、翻墙在跑但工具停用这三种都已在上面说过，
    # 这里再打一遍就是同一件事说两次，读者会以为有两处不同的问题。
    if ($st.ProxyValue -and $st.ProxyAlive -and $m) {
        Write-StatusRow '代理变量' ("已注入 ({0})" -f $st.ProxyValue) 'ok'
    } elseif (-not $st.ProxyValue -and -not $st.Port) {
        # 只有"确实没有翻墙软件在跑"时才说"直连状态"。
        # 少了 -not $st.Port 这一半，就会与上面那条"翻墙软件在跑但本工具已停用"
        # 同时命中：同一屏里"代理变量"出现两次，一次说"已停用"、一次说"直连"，
        # 用户会以为有两处不同的设置要处理（实测复现过）。
        # 判据必须是**完整**的：有代理在跑就不该说"直连"，那是两件事。
        Write-StatusRow '代理变量' '无（直连状态）' 'dim'
    }
    Show-VersionLines $st
    Show-RecentLog
}

# 版本那三行：正常时压成一行。原来"本地版本/最新版本/更新状态"各占一行、
# 与"监控未运行"平级，等于把对普通用户没有行动价值的信息和要靠它行动的信息摆成一样重。
#
# 数据来自监控写的缓存，所以有三种情况，必须分开说：
#   有且新鲜  → 正常比较版本
#   有但很旧  → 仍然比较，但把"这是多久以前查的"一起说出来（陈旧数据不许假装是当前数据）
#   还没有    → 说明为什么还没有（监控没在跑 / 刚装上），并给出主动查的办法
function Show-VersionLines($st) {
    $localVer = $st.LocalVersion
    $cache = $st.RemoteCache
    $remote = $null
    if ($cache) { $remote = @{ Version = $cache.Version; Tag = ("v" + $cache.Version) } }
    $localText = if ($localVer) { "v$localVer" } else { "未知" }
    if (-not $cache) {
        # 还没有缓存：不联网、不猜，说清为什么 + 去哪儿主动查。
        Write-StatusRow '版本' ("{0}（还没查过最新版；监控每 30 轮查一次，也可以选 3 立刻查）" -f $localText) 'dim'
        return
    }
    $ageText = ""
    if ($cache.AgeMinutes -ge 1440) { $ageText = ("（{0} 天前的记录）" -f [int]($cache.AgeMinutes / 1440)) }
    elseif ($cache.AgeMinutes -ge 60) { $ageText = ("（{0} 小时前的记录）" -f [int]($cache.AgeMinutes / 60)) }
    if ($remote) {
        $state = $null
        $role = 'ok'
        if (Test-DevCopy) {
            $state = "开发副本（更新走 git pull，本入口不改动文件）"; $role = 'dim'
        } elseif (Test-SourceCopy) {
            $state = "源码包（更新入口会先确认用途再动手）"; $role = 'warn'
        } elseif (-not $localVer) {
            $state = "可打开菜单选 3（检查更新）升级"; $role = 'warn'
        } elseif ((Compare-Versions $localVer $remote.Version) -gt 0) {
            $state = "本地版本比最新发布版新"; $role = 'dim'
        } elseif ((Compare-Versions $remote.Version $localVer) -gt 0) {
            $state = ("发现新版 {0}，选 3（检查更新）即可升级" -f $remote.Tag); $role = 'warn'
        } else {
            $state = "已是最新"; $role = 'dim'
        }
        if ($role -eq 'dim') {
            Write-StatusRow '版本' ("{0}（{1}）{2}" -f $localText, $state, $ageText) 'dim'
        } else {
            Write-StatusRow '版本' ("{0}（{1}）{2}" -f $localText, $state, $ageText) $role
        }
    }
}

# 最近日志：读最后 3 行，按窗口宽度裁。纯读+打印，不探测、不写文件。
function Show-RecentLog {
    Write-Styled 'title' "---------------- 最近日志 ----------------"
    if (-not (Test-Item $LogFile)) {
        Write-Styled 'dim' "  （暂无日志）"
        Write-Styled 'title' "=================================="
        return
    }
    # 日志行按控制台宽度裁：一行日志本来就是给文件看的（不折行、好搜），
    # 但状态页会把它原样打到屏幕上。122 列的长行在 80/100 列的窗口里会硬折成两三行，
    # 屏幕上就是一团乱——"最近日志"于是从"看一眼有没有异常"变成"读一段糊住的字"。
    # 裁到窗口宽度 - 2（留两个缩进），并在末尾补一个省略号说明"这行还有后半段"。
    # 日志行宽：默认 80 列（大多数终端的标准宽度），能拿到真实窗口宽度时按窗口减 2（给缩进）。
    # 80 这个默认值不是随手取的：本工具自己写下的日志行最长约 80 格
    # （"检测到本地代理端口 7078 -> 已注入代理 http://127.0.0.1:7078" 正是 80）。
    # 默认值比它小的话，最常见的那条日志每屏都被截成 "http://127.0.0.1:7…"，
    # 而截掉的恰好是端口号——排查时最想看的那个数字。
    $logW = 80
    try { if (-not [Console]::IsOutputRedirected) { $logW = [Console]::WindowWidth - 2 } } catch {}
    if ($logW -lt 40) { $logW = 40 }
    foreach ($logLine in ([System.IO.File]::ReadAllLines($LogFile, [System.Text.Encoding]::UTF8) | Select-Object -Last 3)) {
        $shown = $logLine
        if ((Get-DisplayWidth $shown) -gt $logW) {
            $acc = ''
            $accW = 0
            foreach ($ch in $shown.ToCharArray()) {
                $cw = Get-CharWidth $ch
                if ($accW + $cw -gt ($logW - 1)) { break }
                $acc += $ch
                $accW += $cw
            }
            $shown = $acc + '…'
        }
        Write-Styled 'dim' "  $shown"
    }
    Write-Styled 'title' "=================================="
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

# 单个字符占几格：码位 > U+2E80 记两格，其余一格。
# 这是**唯一**的判据处：Get-DisplayWidth 与日志裁剪都调它。写成两份就会有一天
# 两份算出两个宽度，症状是同一屏里两列对不齐、日志截得长短不一。
# 与 Mac 侧 _display_width 同一条判据（门禁核对两端对同一批字符的结论相同）。
function Get-CharWidth([char]$Ch) {
    if ([int]$Ch -gt 0x2E80) { return 2 }
    return 1
}

# 计算一段文字在终端里占几格：中日韩字符占两格，其余一格。
# 所有需要对齐的地方都走这一处。
function Get-DisplayWidth([string]$Text) {
    $w = 0
    foreach ($ch in $Text.ToCharArray()) { $w += (Get-CharWidth $ch) }
    return $w
}

# 把一段文字按终端可见宽度补空格（中文按两格算）。
function Format-MenuCell([string]$Text, [int]$Width) {
    $pad = $Width - (Get-DisplayWidth $Text)
    if ($pad -lt 0) { $pad = 0 }
    return $Text + (' ' * $pad)
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
        $len = Get-DisplayWidth $mi.Name
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

# 把整张菜单渲染成"屏幕上真正出现的那些行"，每行是若干「颜色段」。
#
# 为什么是分段而不是一行一色：菜单的读法是三层——编号（要敲的）、名字（敲它会发生什么）、
# 说明（细节）。一行一个颜色表达不了这个分层，而分不清"哪部分是要敲的东西"正是
# 菜单最难用的地方。
# 为什么先渲染再输出：纯文本（Format-MenuText，给非交互与测试）与彩屏（Show-MenuColored）
# 共用这一份，两者只会差"上不上色"，不可能出现"屏幕上有、测试里没有"。
function Get-MenuRenderedLines {
    $nameW = Get-MenuNameWidth
    $out = @()
    $hl = Get-MonitorProcess
    $verText = Get-LocalVersion
    if (-not $verText) { $verText = "未知" }
    $out += [pscustomobject]@{ Role = 'title'; Text = '======== EnvProxy 菜单 ========'
                               Segments = @(@{ Role = 'title'; Text = '======== EnvProxy 菜单 ========' }) }
    # 抬头是这一屏最该被看到的一行：用户打开菜单九成的目的是"我现在正常吗"，
    # 答案就在这里（监控在跑 = 正常，未运行 = 有问题）。
    # 早先整行用 dim（暗灰），等于把答案压到最暗、还给它贴了"背景信息"的标签；
    # 而"怎么修"的编号反而是亮绿——优先级是反的。
    # 现在拆两段：标签用灰（它确实是背景），**状态值用 ok/warn**（与状态页同一套语义）。
    $monRole = if ($hl) { 'ok' } else { 'warn' }
    $monText = if ($hl) { ("运行中 (PID {0})" -f $hl.ProcessId) } else { '未运行' }
    $segs = @(
        @{ Role = 'dim'; Text = '  监控 ' },
        @{ Role = $monRole; Text = $monText },
        @{ Role = 'dim'; Text = ("    版本 v{0}" -f $verText) }
    )
    $joined = ''
    foreach ($sg in $segs) { $joined += $sg.Text }
    $out += [pscustomobject]@{ Role = 'dim'; Text = $joined; Segments = $segs }
    # 未运行时补一句可执行的话：打开菜单 → 第一行就知道好不好 → 坏了直接告诉按哪个键。
    if (-not $hl) {
        $hint = '        按 1 可以让它重新跑起来'
        $out += [pscustomobject]@{ Role = 'dim'; Text = $hint
                                   Segments = @(@{ Role = 'dim'; Text = $hint }) }
    }
    foreach ($g in (Get-MenuGroups)) {
        $items = @($MenuItems | Where-Object { $_.Group -eq $g })
        if ($items.Count -eq 0) { continue }
        $out += [pscustomobject]@{ Role = 'blank'; Text = ''; Segments = @() }
        $out += [pscustomobject]@{ Role = 'heading'; Text = ('  ' + $g)
                                   Segments = @(@{ Role = 'heading'; Text = ('  ' + $g) }) }
        foreach ($mi in $items) {
            # 退出项没有动作，编号跟着变暗：亮绿色的编号会让人以为"它跟别的项一样要跑个什么"。
            $keyRole = if ($mi.Switch) { 'cmd' } else { 'dim' }
            $segs = @(
                @{ Role = $keyRole; Text = ('    ' + $mi.Key) },
                @{ Role = 'value';  Text = ('  ' + (Format-MenuCell $mi.Name $nameW)) }
            )
            if ($mi.Hint) { $segs += @{ Role = 'dim'; Text = ('   ' + $mi.Hint) } }
            $joined = ''
            foreach ($s in $segs) { $joined += $s.Text }
            $out += [pscustomobject]@{ Role = 'item'; Text = $joined; Segments = $segs }
        }
    }
    $out += [pscustomobject]@{ Role = 'blank'; Text = ''; Segments = @() }
    $out += [pscustomobject]@{ Role = 'dim'; Text = '  输编号后回车执行    直接回车 = 查看状态'
                               Segments = @(@{ Role = 'dim'; Text = '  输编号后回车执行    直接回车 = 查看状态' }) }
    return $out
}

# 带配色地把菜单打到屏幕上。与 Format-MenuText 同源（Get-MenuRenderedLines），只差上不上色。
function Show-MenuColored {
    foreach ($r in (Get-MenuRenderedLines)) {
        if ($r.Role -eq 'blank') { Write-Host ''; continue }
        foreach ($s in $r.Segments) { Write-Styled $s.Role $s.Text -NoNewline }
        Write-Host ''
    }
}

# 渲染整张菜单（纯文本）。打印与测试共用内容，保证"表里有什么，屏幕就有什么"。
function Format-MenuText {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($r in (Get-MenuRenderedLines)) { [void]$out.Add($r.Text) }
    return ($out -join "`n")
}

# 帮助里「菜单每一项是干什么的」那一屏的正文，从 $MenuItems 生成。
# 为什么生成而不是手抄：手抄的那一份在改菜单时会静默过期，症状是用户照帮助里的
# 编号去敲，敲到的是另一件事（想检查更新，结果卸载了）。生成之后这份内容与菜单
# 读同一张表，改表即同步，不存在"两边都要记得改"。
function Get-HelpMenuLines {
    $out = New-Object System.Collections.Generic.List[string]
    [void]$out.Add('t 这些编号要在主菜单里敲，不是在帮助里敲。')
    foreach ($g in (Get-MenuGroups)) {
        $items = @($MenuItems | Where-Object { $_.Group -eq $g })
        if ($items.Count -eq 0) { continue }
        [void]$out.Add('b ')
        if ($g -eq '日常') { [void]$out.Add(('h ' + $g + '（平时只会用到这些）')) } else { [void]$out.Add(('h ' + $g)) }
        foreach ($mi in $items) {
            # 三格：编号 / 名字 / 说明。名字列由渲染器按整块自动补齐，不在这里手敲空格。
            [void]$out.Add(('m ' + $mi.Key + '|' + $mi.Name + '|' + $mi.Hint))
        }
    }
    return $out
}

# 帮助正文的角色标记。每一行自己声明"我是什么"，渲染器照着画，不再从行的形状去猜。
#
# 为什么必须这样：靠形状猜的判据是"缩进 4 格以上 + 这一行没有汉字 = 命令"，
# 而真实内容不按这个形状长——`Git Bash   source ~/.bashrc` 带了左列标签，
# `PowerShell  $env:ENVPROXY_TERM = 'off'` 只缩进 2 格，两行都是能整行复制的命令，
# 却都会被判成普通说明（灰）。同一屏里 `set HTTP_PROXY=…` 是绿的、旁边三行是灰的，
# 用户看到的就是"配色坏了"。这不是漏了哪一行，是判据本身注定会错。
#
# 标记写在行首，一个字母加一个空格：
#   h  小标题                         t  正文
#   t2 正文（接在编号条目下面的续行）  i  编号条目
#   w  提醒                           c  命令（整行可复制）
#   b  空行
#   r  两列：左列说"在哪儿敲"、右列是说明      rc 两列，右列是命令
#   m  三格：编号 / 名字 / 说明（菜单那一屏）
# 多列行的写法：'rc PowerShell|$env:ENVPROXY_TERM = ''off'''
# 列宽由渲染器按整块自动算，不手敲空格——手敲与写死列宽是同一类毛病。
$HelpRoleIndent = @{
    'h'  = 0
    't'  = 2
    't2' = 6
    'i'  = 4
    'w'  = 2
    'c'  = 6
    'r'  = 4
    'rc' = 4
    'm'  = 4
    'b'  = 0
}

# 把一行带标记的正文拆成「角色 + 各列」。
# 标记认不出来时按正文处理并把整行原样显示：宁可颜色不理想，也不能把内容弄丢。
function Split-HelpLine([string]$Line) {
    $code = ''
    $rest = ''
    $sp = $Line.IndexOf(' ')
    if ($sp -ge 0) { $code = $Line.Substring(0, $sp); $rest = $Line.Substring($sp + 1) }
    else { $code = $Line }
    if (-not $HelpRoleIndent.ContainsKey($code)) { $code = 't' }
    $rowKey = ''
    $name = ''
    $hint = ''
    $text = $rest
    if ($code -eq 'r' -or $code -eq 'rc') {
        $bar = $rest.IndexOf('|')
        if ($bar -ge 0) { $rowKey = $rest.Substring(0, $bar); $text = $rest.Substring($bar + 1) }
        else { $code = 't' }
    } elseif ($code -eq 'm') {
        $parts = $rest -split '\|', 3
        if ($parts.Count -ge 2) {
            $rowKey = $parts[0]; $name = $parts[1]
            if ($parts.Count -ge 3) { $hint = $parts[2] }
            $text = ''
        } else { $code = 't'; $text = $rest }
    }
    return [pscustomobject]@{ Code = $code; Indent = $HelpRoleIndent[$code]
                              RowKey = $rowKey; Name = $name; Hint = $hint; Text = $text }
}

# 把一段带标记的正文渲染成"屏幕上真正出现的那些行"。
#
# 每一行是若干「颜色段」（Role + Text）拼起来的：一行一个颜色表达不了
# "编号是绿的、名字是白的、说明是灰的"，而那正是主菜单教给用户的分层读法。
# 于是纯文本输出把各段拼成整行，彩屏逐段上色，两边读的是同一份渲染结果——
# "屏幕上有、测试里没有"不可能发生。
#
# 多列行的列宽在这里统一算：同一块里所有同类行补到同一个宽度，别的行不参与
# （否则一段长正文会把列撑得很宽）。
function Get-HelpRenderedLines([string[]]$Lines) {
    $parsed = @()
    foreach ($l in $Lines) { $parsed += (Split-HelpLine $l) }
    $keyW = 0
    $nameW = 0
    foreach ($r in $parsed) {
        if ($r.RowKey) {
            $w = Get-DisplayWidth $r.RowKey
            if ($w -gt $keyW) { $keyW = $w }
        }
        if ($r.Name) {
            $w = Get-DisplayWidth $r.Name
            if ($w -gt $nameW) { $nameW = $w }
        }
    }
    $out = @()
    foreach ($r in $parsed) {
        $pad = ' ' * $r.Indent
        $segs = @()
        $role = 'text'
        switch ($r.Code) {
            'b'  { $role = 'blank' }
            'h'  { $role = 'heading'; $segs += @{ Role = 'heading'; Text = ($pad + $r.Text) } }
            'i'  { $role = 'item';    $segs += @{ Role = 'item';    Text = ($pad + $r.Text) } }
            'w'  { $role = 'warn';    $segs += @{ Role = 'warn';    Text = ($pad + $r.Text) } }
            'c'  { $role = 'cmd';     $segs += @{ Role = 'cmd';     Text = ($pad + $r.Text) } }
            'r'  { $role = 'row'
                   $segs += @{ Role = 'key';  Text = ($pad + (Format-MenuCell $r.RowKey $keyW) + '   ') }
                   $segs += @{ Role = 'text'; Text = $r.Text } }
            'rc' { $role = 'row'
                   $segs += @{ Role = 'key';  Text = ($pad + (Format-MenuCell $r.RowKey $keyW) + '   ') }
                   $segs += @{ Role = 'cmd';  Text = $r.Text } }
            'm'  { $role = 'row'
                   $segs += @{ Role = 'cmd';   Text = ($pad + $r.RowKey + '  ') }
                   $segs += @{ Role = 'value'; Text = (Format-MenuCell $r.Name $nameW) }
                   if ($r.Hint) { $segs += @{ Role = 'dim'; Text = ('   ' + $r.Hint) } } }
            default { $segs += @{ Role = 'text'; Text = ($pad + $r.Text) } }
        }
        $joined = ''
        foreach ($s in $segs) { $joined += $s.Text }
        $out += [pscustomobject]@{ Role = $role; Segments = $segs; Text = $joined }
    }
    return $out
}

# 帮助的内容表：每个主题一屏放得下，进帮助先看目录，选一个只看那一段。
# 为什么这么分：一次性把十几屏内容全刷出来，看到后面已经忘了前面讲什么；
# 按"我此刻想解决什么"分主题，再配一个固定的返回行，用户随时能退回来换一段看。
# 每条格式：键 / 标题（目录里显示）/ 正文行数组（带角色标记，见上面 Split-HelpLine）。
function Get-HelpTopics {
    return @(
        @{
            Key = '1'; Title = '这是干什么用的'; Short = '用处'
            Lines = @(
                'h 它做什么',
                't 翻墙软件一开，终端里的 git、npm、curl 就能翻墙；',
                't 一关，它们自动恢复直连。不用记任何开关。',
                'b ',
                'h 它怎么判断你现在在翻墙',
                't 每 2 到 3 秒看一次。要同时满足三条才算：',
                'i 1. 本机有端口在监听；',
                'i 2. 它确实是个代理，会回应握手；',
                'i 3. 它确实连得通外面，试 6 个端点任意一个通就算。',
                't 三条全过才写变量。所以本机开着网页服务、开发服务器都不会被误判。',
                't 它不认品牌、不认进程名、不认端口号，那些只用来加快扫描。'
            )
        },
        @{
            Key = '2'; Title = '装完之后要我做什么'; Short = '装完'
            Lines = @(
                'h 装完之后，按窗口分三种情况',
                'b ',
                'i 1. 装完之后才打开的窗口',
                't2 启动时读到的就是当前状态，什么都不用做。',
                'b ',
                'i 2. 装完之后打开的窗口，后来代理又变了',
                't2 按一次回车即可（cmd 窗口只能重开，见下面第 3 条）。',
                'b ',
                'i 3. 装之前就已经开着的窗口',
                't2 同步代码还没装进去。在那个窗口里敲下面这一条，或者重开窗口：',
                'b ',
                'rc PowerShell|. $PROFILE',
                'rc Git Bash|source ~/.bashrc',
                'r cmd|没有这条命令，只能重开窗口',
                'b ',
                'h 为什么要按一次回车',
                't 每个程序只在启动那一刻读一次环境变量，读完就固定了。之后系统改了，',
                't 已经在跑的窗口不会跟着变。EnvProxy 挑的时机是每次命令跑完、',
                't 等你回到能打字的状态时同步——你本来就一直在敲命令，不用专门做什么。'
            )
        },
        @{
            Key = '3'; Title = '这个窗口固定直连 / 恢复自动'; Short = '窗口'
            Lines = @(
                'h 一、让这个窗口一直直连',
                'b ',
                'rc PowerShell|$env:ENVPROXY_TERM = ''off''',
                'rc Git Bash|export ENVPROXY_TERM=off',
                'b ',
                't 敲完下一次回到提示符时生效。你自己设的值（比如公司代理）不会被删。',
                'b ',
                # cmd 这一行是表格的第三行，不是正文：写成正文会变成"缩进 2 格的灰字"，
                # 与上面两行既不对齐、也不白——用户看到的就是"这里格式坏了"。
                # 它下面的命令用空左列的 rc：左列补成同样的宽度，命令正好落在右列下方。
                ('r cmd|没有这个开关，只能自己清 {0} 个变量（& 两边别留空格）：' -f @($ProxyVarNames).Count),
                ('rc |set ' + ((@($ProxyVarNames) | ForEach-Object { $_ + '=' }) -join '&set ')),
                'b ',
                'w 别用 unset HTTP_PROXY：我们写进 Git Bash 的是小写拼写，',
                't unset 大写的清不掉小写，curl 照样走代理，下个提示符还会写回来。',
                'b ',
                'h 二、改回自动跟随',
                'b ',
                'rc PowerShell|Remove-Item Env:ENVPROXY_TERM',
                'rc Git Bash|unset ENVPROXY_TERM',
                'r cmd|重开一个窗口',
                'b ',
                't 上面两节都只对这个窗口有效，窗口一关就没了。'
            )
        },
        @{
            Key = '4'; Title = '这个窗口走公司代理'; Short = '代理'
            Lines = @(
                't 先做第 3 条（固定直连），再设地址。顺序反了等于没设。',
                'b ',
                'h 一、设地址（换成公司给的）',
                'b ',
                'rc PowerShell|$env:HTTPS_PROXY = ''http://你的地址:端口''',
                'rc Git Bash|export HTTPS_PROXY=http://你的地址:端口',
                'rc cmd|set HTTPS_PROXY=http://你的地址:端口',
                'b ',
                'h 二、看现在走不走代理（有值 = 走，空的 = 直连）',
                'b ',
                'rc PowerShell|$env:HTTPS_PROXY',
                'rc Git Bash|echo $HTTPS_PROXY',
                'rc cmd|set HTTPS_PROXY',
                'b ',
                't 端口是你公司给的，问 IT 要（通常会给一份代理设置说明）。',
                'w 注意：这里不是翻墙软件那个端口，别去那儿找。',
                't 你手设的值不会被删，只清和工具写入值相同的那些。'
            )
        },
        @{
            Key = '5'; Title = '我要让某条命令不走代理'; Short = '命令'
            Lines = @(
                'h 不同工具写法不一样，没有通用的一条命令',
                'b ',
                'h curl',
                'c curl.exe --noproxy "*" https://example.com',
                't 只有 PowerShell 5.1 必须写 .exe：它把 curl 和 wget 都当成了别名。',
                't cmd 和 PowerShell 7 里 curl 就是真的 curl.exe，写不写都行。',
                'b ',
                'h git',
                'c git -c http.proxy= -c https.proxy= clone https://github.com/git/git.git',
                't 等号后留空，这条就不用代理；写别的值，就改用那个代理。',
                'b ',
                'h npm',
                'c npm --noproxy=registry.npmjs.org install typescript',
                'w 注意：只认具体网址，写 * 没用，而且不报错，请求照常走代理。',
                't 写成 --no-proxy 会被理解成关闭代理，也不是你要的效果。',
                't 另外 npm 只认 HTTPS_PROXY，不认 HTTP_PROXY。',
                'b ',
                'h wget',
                't Windows 不自带 wget。自己装过才用得上这一条：',
                'c wget.exe --no-proxy https://example.com',
                'b ',
                'h docker',
                't 没有单条命令的写法，改 Docker 自己的设置（Settings 里的 Proxies）。'
            )
        },
        @{
            Key = '6'; Title = '菜单每一项是干什么的'; Short = '菜单'
            Lines = @(Get-HelpMenuLines)
        },
        @{
            Key = '7'; Title = '装了还是连不上网 / 状态不对'; Short = '连不上'
            Lines = @(
                'h 连不上网，按这个顺序查',
                'i 1. 在出问题的窗口里敲对应的一条，看有没有值（空的 = 没注入，重开窗口）：',
                'rc PowerShell|$env:HTTPS_PROXY',
                'rc cmd|set HTTPS_PROXY',
                'rc Git Bash|echo $HTTPS_PROXY',
                'b ',
                'i 2. 有值还是连不上：看菜单顶上「监控」写的是运行中还是未运行。',
                't2 未运行就选 1（安装 / 修复）。',
                'i 3. npm 只认 HTTPS_PROXY，不认 HTTP_PROXY；你自己清过它就不走了。',
                'b ',
                'h 状态页怎么读',
                'r 监控进程|后台程序在不在跑',
                'r 开机自启|下次登录会不会自动起来',
                'r 翻墙代理|本机有没有翻墙软件在监听端口',
                'r 终端同步|已经开着的窗口会不会跟着变',
                'r 代理变量|这个工具往终端里设代理了没有',
                't 「翻墙代理」有、「代理变量」无 = 翻墙在跑、工具被停了，不是坏了。',
                'b ',
                'h 日志和 AI 排查',
                't 反馈时附最后 20 行日志。先 cd 到装它的文件夹，再照对应的一条敲：',
                'rc PowerShell|Get-Content .\win\monitor\monitor.log -Tail 20',
                'rc Git Bash|tail -n 20 win/monitor/monitor.log',
                't AI 报 ECONNREFUSED 127.0.0.1:端口号 = 变量指向了已关闭的端口，不是网络坏了。',
                't 菜单选 2 看「代理变量」那行会说清。它只管 HTTP/HTTPS 变量，ping、',
                't 游戏、BT 走自己协议的不认，要开 TUN 模式。'
            )
        },
        @{
            Key = '8'; Title = '还是不行 / 想删掉它'; Short = '不行'
            Lines = @(
                'h 大部分问题都可以用「安装 / 修复」解决',
                't 打开菜单选 1。它不会重复安装，不会中断网络，也不会丢失你的设置。',
                'b ',
                'h 还是不行',
                't 菜单选 2 把状态截图，再选 1 修复一次。反馈时附上 monitor\monitor.log',
                't 最后 20 行，能省很多来回。',
                'b ',
                'h 想彻底删掉它',
                't 菜单选 6（一键恢复）。会问你要不要留日志。',
                'b ',
                'h 不开菜单也能用（适合写脚本，或远程连过来）',
                'r 开关|-Install  -Status  -Stop  -Uninstall  -Update  -Help  -Menu',
    'r 补充|-Yes        跳过确认（检查和卸载时问的那句）',
    'r 补充|-Purge      卸载时连历史日志一起删',
    'r 补充|-RepairProfile  摘掉配置文件里孤立的标记（会先备份）',
                't -Purge 连日志一起删，只配 -Uninstall 用。完整写法：',
                'c powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Status'
            )
        }
    )
}

# 帮助目录屏的内容。整屏只有这一份：纯文本与彩屏都从它取，
# 于是"改一个字只改一处"，也不可能出现"屏幕上有、测试里没有"。
#
# 编号用命令色、标题用强调色、底部说明用灰：与主菜单同一套三层区分，
# 用户在两个页面之间切换时不用重新认一遍。
function Get-HelpIndexRenderedLines {
    $ver = Get-LocalVersion
    if ([string]::IsNullOrWhiteSpace($ver)) { $ver = '未知' }
    $out = @()
    $out += [pscustomobject]@{ Role = 'title'; Text = '================ EnvProxy 帮助 ================'
                               Segments = @(@{ Role = 'title'; Text = '================ EnvProxy 帮助 ================' }) }
    $out += [pscustomobject]@{ Role = 'blank'; Text = ''; Segments = @() }
    $out += [pscustomobject]@{ Role = 'text'; Text = '  按你遇到的问题挑一条：'
                               Segments = @(@{ Role = 'text'; Text = '  按你遇到的问题挑一条：' }) }
    foreach ($t in (Get-HelpTopics)) {
        $segs = @(
            @{ Role = 'cmd';   Text = ('    ' + $t.Key) },
            @{ Role = 'value'; Text = ('  ' + $t.Title) }
        )
        $joined = ''
        foreach ($sg in $segs) { $joined += $sg.Text }
        $out += [pscustomobject]@{ Role = 'item'; Text = $joined; Segments = $segs }
    }
    $out += [pscustomobject]@{ Role = 'blank'; Text = ''; Segments = @() }
    $out += [pscustomobject]@{ Role = 'dim'; Text = ('  本机版本 v' + $ver)
                               Segments = @(@{ Role = 'dim'; Text = ('  本机版本 v' + $ver) }) }
    $out += [pscustomobject]@{ Role = 'blank'; Text = ''; Segments = @() }
    $out += [pscustomobject]@{ Role = 'dim'; Text = '  输编号查看    直接回车 = 回主菜单'
                               Segments = @(@{ Role = 'dim'; Text = '  输编号查看    直接回车 = 回主菜单' }) }
    return $out
}

# 帮助目录屏（带配色）。
function Show-HelpIndexColored {
    foreach ($r in (Get-HelpIndexRenderedLines)) {
        if ($r.Role -eq 'blank') { Write-Host ''; continue }
        foreach ($s in $r.Segments) { Write-Styled $s.Role $s.Text -NoNewline }
        Write-Host ''
    }
}

# 帮助目录的纯文本（非交互与自检用）。与彩屏同一份内容，只差上不上色。
function Format-HelpIndex {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($r in (Get-HelpIndexRenderedLines)) { [void]$out.Add($r.Text) }
    return ($out -join "`n")
}

# 主题页底部那一行：把全部编号和短名并排列出来，当前这条用方括号标。
# 为什么需要它：用户在主题里只看到「输编号看别的」，却不知道别的编号是几号——
# 那句话等于白说。列出编号既回答了"编号是什么"，也顺手回答了"还有哪几条"。
function Format-HelpNavLine([string]$CurrentKey) {
    $parts = @()
    foreach ($t in (Get-HelpTopics)) {
        $label = if ($t.Key -eq $CurrentKey) { '[' + $t.Key + ']' + $t.Short } else { $t.Key + ' ' + $t.Short }
        $parts += $label
    }
    return ('  ' + ($parts -join '  '))
}

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

# 菜单可用的编号，从表里算：加一项就自动变成 "1-6 和 0"，不会留下写死的旧范围。
function Get-MenuKeyRange {
    $keys = @($MenuItems | Where-Object { $_.Switch } | ForEach-Object { $_.Key })
    $quit = @($MenuItems | Where-Object { -not $_.Switch } | ForEach-Object { $_.Key })
    if ($keys.Count -eq 0) { return '没有可用的编号' }
    $text = Format-KeyList $keys
    if ($quit.Count -gt 0) { $text += ' 和 ' + ((@($quit | ForEach-Object { [int]$_ } | Sort-Object) | ForEach-Object { $_.ToString() }) -join ' ') }
    return $text
}

# 可用的编号范围，从表里算：加一条主题就自动变成 "有 1-8"，不会留下写死的旧范围。
function Format-HelpKeyRange {
    $keys = @(Get-HelpTopics | ForEach-Object { $_.Key })
    if ($keys.Count -eq 0) { return '没有可用的编号' }
    if ($keys.Count -eq 1) { return '只有 ' + $keys[0] }
    return ('有 ' + (Format-KeyList $keys))
}

# 单个主题的纯文本（给非交互调用与自检用）：与彩屏读同一份渲染结果。
function Format-HelpTopic([string]$Key) {
    $t = @(Get-HelpTopics | Where-Object { $_.Key -eq $Key })
    if ($t.Count -eq 0) { return $null }
    $t = $t[0]
    $out = New-Object System.Collections.Generic.List[string]
    [void]$out.Add(('================ 帮助 {0} · {1} ================' -f $t.Key, $t.Title))
    [void]$out.Add('')
    foreach ($r in (Get-HelpRenderedLines $t.Lines)) { [void]$out.Add($r.Text) }
    [void]$out.Add('')
    [void]$out.Add((Format-HelpNavLine $t.Key))
    [void]$out.Add('  输编号看别的    直接回车 = 回目录')
    return ($out -join "`n")
}

# 带配色地把一个主题打到屏幕上。
# 与 Format-HelpTopic 的区别只有"上不上色"：两者读同一份渲染结果（Get-HelpRenderedLines），
# 所以屏幕上有什么、非交互输出就是什么，不存在两份内容各自漂移。
# 一行分几段就上几个色：整行同色时"哪部分是命令"又得靠眼睛找，等于白上色。
function Show-HelpTopicColored([string]$Key) {
    $t = @(Get-HelpTopics | Where-Object { $_.Key -eq $Key })
    if ($t.Count -eq 0) { return $false }
    $t = $t[0]
    Write-Styled 'title' ('================ 帮助 {0} · {1} ================' -f $t.Key, $t.Title)
    Write-Host ''
    foreach ($r in (Get-HelpRenderedLines $t.Lines)) {
        if ($r.Role -eq 'blank') { Write-Host ''; continue }
        foreach ($s in $r.Segments) { Write-Styled $s.Role $s.Text -NoNewline }
        Write-Host ''
    }
    Write-Host ''
    Write-Styled 'dim' (Format-HelpNavLine $t.Key)
    Write-Styled 'dim' '  输编号看别的    直接回车 = 回目录'
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
            Show-HelpIndexColored
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
            Write-Styled 'warn' ("没有这一条：{0}（{1}）" -f $sel, (Format-HelpKeyRange))
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
            # 非交互时先把菜单正文打出来，再提示怎么用开关。
            # 与 Mac 侧对齐（那边 stdout 不是终端就退回纯文本菜单）：
            # 同样的调用在两个平台上不该一个给菜单、一个只给一句警告。
            # 这也让 Format-MenuText 不再是"只有测试在用"的死函数。
            Write-Host (Format-MenuText)
            Write-Host ''
            Write-Styled 'warn' "以上是菜单。管道里没法交互，请直接用 -Install/-Status/-Stop/-Uninstall/-Update/-Help 开关（全部开关见 -Help）。"
            return
        }
    } catch {}
    # 两轮两种画法：重画整张菜单（首次进入、子命令结束后），或者什么都不画
    # （输错编号那一轮）。所以它是三态的字符串而不是布尔量：布尔量只能表达"清不清屏"，
    # 输错时仍会重画整张菜单，连错几次屏幕就滚得找不到位置。
    $mode = "menu"
    while ($true) {
        if ($mode -eq "menu") { Clear-Screen; Show-MenuColored }
        try {
            $choice = Read-Host "输入编号"
        } catch {
            Write-Styled 'warn' "菜单需要双击 打开菜单.cmd 使用，管道调用请直接用 -Install/-Status/-Stop/-Uninstall/-Update/-Help 开关（全部开关见 -Help）。"
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
            Write-Styled 'warn' ("没有这个编号：{0}（可用的有 {1}）" -f $choice, (Get-MenuKeyRange))
            $mode = "none"
            continue
        }
        if (-not $item[0].Switch) { return }
        # 子进程跑完整开关：与入口开关走的是同一条路（含锁、确认、复检）。
        # 本进程只等它结束，不解释它的退出码（退出码在 5.1 里读不到，判据只看复读）。
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath ("-" + $item[0].Switch)
        } catch {
            Write-Styled 'warn' ("启动失败：{0}" -f $_.Exception.Message)
        }
        # 子命令跑完先停一下：下一轮开头就要清屏，不等一下就把它刚打印的内容抹掉了。
        try { $null = Read-Host '按回车回菜单' } catch { return }
        $mode = "menu"
    }
}
