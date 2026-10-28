# ==============================================================================
#  ops.ps1 — 动作层：菜单背后的安装、停止、卸载、状态编排、菜单与帮助、问题反馈
#  把下面各层拼成使用者点得到的行为。
#  卸载要处理「走代理的快捷方式」的去留，因此依赖 shortcut 层的扫描与删除函数。
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
        Write-Styled 'warn' "      请检查杀软拦截，或再打开一次菜单选 $(Get-MenuKey 'Install')（$(Get-MenuName 'Install')）（安装 / 修复）；仍然不行就把它加进白名单。"
    }
    # 首次安装的判据必须在写路径记录**之前**取：写完这台机器上就有记录了，再判永远是"重装"。
    # 差别在于本机地址的代理变量算谁的——首次安装时它只可能是使用者自己的。
    $firstInstall = -not ((Get-ItemProperty (Get-ScriptPathRegKeyPath) -Name "ScriptPath" -ErrorAction SilentlyContinue).ScriptPath)
    Update-ScriptPathRecord
    # 先快照用户原值，再动任何东西：监控一启动就会在几秒内自愈、把代理变量写进去，
    # 那时再快照，存下的就是"我们写下的值"而不是用户原值，卸载还原会留下我们的条目。
    # （快照只记一次；已经存在时这里是无副作用的空操作。）
    # 成败要收下来：这份快照是**其它所有归属判据的输入**，记不下来说明卸载时
    # 还原不回用户的配置——那是安装时最该喊出来的一句话，不能只是安静地过去。
    $snapshotOk = $true
    try { if ((Snapshot-PrevEnv -FirstInstall:$firstInstall) -ne 0) { $snapshotOk = $false } } catch { $snapshotOk = $false }
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
        Write-Styled 'warn' "      再打开一次菜单选 $(Get-MenuKey 'Install')（$(Get-MenuName 'Install')）（安装 / 修复）重试；仍然不行请反馈。"
    } else {
        Write-Styled 'ok' "[3/4] 环境变量：已按当前状态校正"
    }
    # 快照没记下就要说出来：它决定"卸载时能不能还原你原来的配置"。
    # 不说的话，用户卸载后发现自己原来的公司代理没了，而安装时屏幕上一切正常。
    if (-not $snapshotOk) {
        Write-Styled 'warn' "      没能记下你原来的代理设置（写入被拦住），卸载时可能还原不回来。"
        Write-Styled 'warn' "      如果原本自己设过代理，请先抄一份；再点一次菜单选 1 重试。"
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
        @('', "菜单选 $(Get-MenuKey 'Help')（$(Get-MenuName 'Help')）第 2 条，各种终端都有现成命令。", ''),
        @('想让某个窗口一直不翻墙', '在它里面执行', "`$env:ENVPROXY_TERM = 'off'"),
        @('改回跟着翻墙软件走', '在它里面执行', 'Remove-Item Env:ENVPROXY_TERM'),
        @('忘了怎么用', "菜单选 $(Get-MenuKey 'Help')（$(Get-MenuName 'Help')）。", '')
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
    # 清掉代理变量。而它在菜单里紧挨着「6 停止监控」（那个是可逆的，"下次开机会自己回来"），
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
        Write-Styled 'dim' "  真的要卸载，请双击 打开菜单.cmd 选 $(Get-MenuKey 'Uninstall')（$(Get-MenuName 'Uninstall')）（一键恢复）；"
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
    # 成败要收下来：还原没写成时**不能**照常删掉整棵键，否则用户原值和唯一副本
    # 一起消失，而卸载还提示他"照上面列出的位置手动删"——数据已经丢了，
    # 处置建议却指向"再删一次"。这种情况停下来，让用户先手动处理。
    $restoreOk = $true
    try { if ((Restore-PrevEnv) -ne 0) { $restoreOk = $false } } catch { $restoreOk = $false }
    if (-not $restoreOk) {
        Write-Styled 'warn' "[未完成] 你原来的代理设置没能写回去（可能被杀软或组策略拦住了）。"
        Write-Styled 'warn' "        备份还留着，没有再删任何东西。请先手动把原来的设置加回去，"
        Write-Styled 'warn' "        再点一次菜单选 $(Get-MenuKey 'Uninstall')（$(Get-MenuName 'Uninstall')）（一键恢复）收尾。"
        return
    }
    # 还完再广播一次：运行中的进程按旧环境块活着，不广播它们就继续走死代理——"无需重启"靠这一次广播。
    Broadcast-EnvironmentChange
    Remove-Item -LiteralPath (Get-ScriptPathRegKeyPath) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $LauncherPath -Force -ErrorAction SilentlyContinue
    # Git Bash 同步用的状态镜像也在定位器目录里：它由本工具新引入，卸载必须带走。
    # 先删文件再删目录，否则目录非空、Remove-Item 不带 -Recurse 会失败（原来就是这样漏的）。
    Remove-Item -LiteralPath (Join-Path $LauncherDir "terminal.env") -Force -ErrorAction SilentlyContinue
    # 固定入口的端口记录也带走：它是本工具写的运行时状态，留着只会让保留的图标
    # 去连一个没人听的口（白等一次连接超时），随后才降级到直读注册表。
    $relayPortFile = ''
    try { $relayPortFile = Get-RelayPortFile } catch {}
    if ($relayPortFile) { Remove-Item -LiteralPath $relayPortFile -Force -ErrorAction SilentlyContinue }
    # 走代理的快捷方式：能问的时候先问再定 launcher.ps1 与 launchers\ 的去留；
    # -Purge 与无交互环境不问（前者直接删，后者默认保留）。
    # 这一问必须在删目录**之前**——先删了再问，用户答"保留"就来不及了。
    $keepShortcuts = $false
    $shortcutRecs = @(Get-ProxyShortcutRecords)
    $orphanLaunchers = @(Get-OrphanProxyLaunchers)
    $hasShortcuts = ($shortcutRecs.Count -gt 0) -or ($orphanLaunchers.Count -gt 0)
    if ($hasShortcuts) {
        # 默认保留：那是用户自己动手建的东西，删了得重来一遍。
        # 与"历史日志默认保留"同一个道理——不可逆且有价值的东西，默认不动。
        $keepShortcuts = $true
        $names = @($shortcutRecs | ForEach-Object { $_.Name })
        if ($names.Count -eq 0) { $names = @($orphanLaunchers | ForEach-Object { $_.Name }) }
        $listText = (($names | Select-Object -Unique) -join '、')
        # @explain 「走代理的快捷方式」是产品里的图标名，用户会在桌面上看到它
        Write-Styled 'text' ("你为这些程序建了走代理的快捷方式：" + $listText)
        Write-Styled 'dim'  "卸载后它们仍然能启动程序，但不再自动带代理（那时按注册表现状走：有代理就用，没有就直连）。"
        if ($Purge) {
            # -Purge 的语义是"我知道我在干什么，全部清干净"，与"-Yes 跳过确认"同一条思路。
            $keepShortcuts = $false
            # @explain 「走代理的快捷方式」是产品里的图标名，用户会在桌面上看到它
            Write-Styled 'dim' "已指定 -Purge：走代理的快捷方式一并删除。"
        } elseif (Test-CanPrompt) {
            try {
                $sc = Read-Host "这些快捷方式是否保留？[Y] 保留（默认） / [N] 一起删掉"
                if ($sc -match '^[Nn]') { $keepShortcuts = $false }
            } catch {
                $keepShortcuts = $true
            }
        } else {
            Write-Styled 'dim' "这里没法提问，默认保留（要一并删除请用 -Uninstall -Purge）。"
        }
    }
    if ($keepShortcuts) {
        # 只删明确属于运行时的那两个文件，跳过 launchers\。
        # 不能对整个目录 -Recurse：那会把用户选择保留的启动脚本一起带走，
        # 而任务栏上那些图标正指着它们——图标会全部失效。
        Get-ChildItem -LiteralPath $LauncherDir -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'launchers' } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        # 目录只剩空壳时才删；还留着 launchers 就保留目录本身
        try {
            if (-not (Test-Item (Join-Path $LauncherDir 'launchers'))) {
                if (-not (Get-ChildItem -LiteralPath $LauncherDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                    Remove-Item -LiteralPath $LauncherDir -Force -ErrorAction SilentlyContinue
                }
            }
        } catch {}
    } else {
        # 整个目录带走（含 launchers\）：用户明确说了不要那些快捷方式。
        # 必须带 -Recurse：5.1 上删非空目录不带它会抛 NullReferenceException 且目录纹丝不动，
        # 于是"卸载未完成"永远修不好——用户再点一次也删不掉，因为没人去删那些残留。
        Remove-Item -LiteralPath $LauncherDir -Recurse -Force -ErrorAction SilentlyContinue
        # 图标也要删，否则桌面上会留下一堆点不开的空壳。判据是内容不是名字（见 Remove-ProxyShortcuts）。
        $rm = Remove-ProxyShortcuts
        if ($rm.RemovedLnk -gt 0) {
            # @explain 「走代理的快捷方式」是产品里的图标名，不是解释机制
        Write-Styled 'ok' ("走代理的快捷方式：已删除 {0} 个" -f $rm.RemovedLnk)
        }
        if ($rm.Failed.Count -gt 0) {
            Write-Styled 'warn' "这些快捷方式没能删掉（可能被占用）："
            foreach ($f in $rm.Failed) { Write-Styled 'dim' ("  " + $f) }
        }
    }
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
        # 状态快照。不删的后果与 version.cache 一字不差：重装后状态页会读到上一份
        # 安装留下的结论（"已开启端口 7078"），而那是已经不存在的状态。
        Remove-ItemSafe $StateSnapshotFile
        # 「上次提示过的代理状态」。不删的后果具体：重装后的监控会读到上一份安装留下的值，
        # 于是重装后第一次真实变化被当成「已经提示过了」而静默跳过——用户换了端口却什么提示都没有。
        Remove-ItemSafe (Get-ProxyNotifyStatePath)
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
    # 目录只在"该删干净"的场合才算脏：用户选择保留快捷方式时，那个目录里
    # 本来就该留着 launchers\，把它报成残留会让每次保留都显示"卸载未完成"。
    if ((Test-Item $LauncherDir) -and -not $keepShortcuts) { $dirty += ("定位脚本所在目录仍在：" + $LauncherDir) }
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
        # 保留下来的快捷方式要说清它现在的行为：用户最可能担心的是"图标还能不能用"。
        # 事实是能用，只是不再自动带代理——它读注册表现状，有代理就用，没有就直连。
        if ($keepShortcuts -and $hasShortcuts) {
            # @explain 「走代理的快捷方式」是产品里的图标名，用户会在桌面上看到它
        Write-Styled 'dim' "        走代理的快捷方式按你的选择保留了："
            Write-Styled 'dim' ("          " + (Get-ProxyLauncherDir))
            Write-Styled 'dim' "        那些图标仍然能启动程序；此时它们按注册表现状走（有代理就用，没有就直连）。"
            Write-Styled 'dim' "        以后想彻底清掉，删掉上面那个文件夹和对应的图标即可。"
        }
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
        Write-Styled 'warn' "        再打开菜单选 $(Get-MenuKey 'Uninstall')（$(Get-MenuName 'Uninstall')）（一键恢复）试一次；还不行就照上面列出的位置手动删。"
    }
}

# 状态显示。
# **永不联网、永不写文件、永不提问**：版本号读监控写下的缓存（runtime 层的
# Write-VersionCache / Read-VersionCache）。缓存旧了就如实说"几小时前的记录"，
# 缓存没有就说清"没法确认"并指向更新入口——状态页不替用户做请求。
# 这条不只是为了快：离线、限流、走白名单网络的人，联网检查只会让他每次查看状态
# 都等一个注定失败的请求，而归因通常是"这工具很慢"。门禁 6 的 e1 段守着它。


# 把状态页渲染成**纯文本行**（不带颜色），供刷新循环使用。
#
# 为什么要有这一份而不是复用 Show-StatusSnapshot：那一份是给「看一眼就走」的
# 场景用的，它直接往屏幕上写、带颜色、带 NoNewline 分段。刷新循环需要的是
# 「一帧 = 一组字符串」，才能与上一帧逐行比较、只重画变化的行。
#
# 两边会不会分叉？会，所以这个函数的输出必须由 Show-StatusSnapshot 的同源数据算出：
#   - 结论行、问题清单、参考项：同一份 $st
#   - 判断逻辑：调同一个 Get-StatusProblems（下面抽出来的）
# 内容一旦不一致，自检里有断言比对两者的行数。
function Format-StatusLines($st) {
    $out = New-Object System.Collections.ArrayList
    # 一行的标准形态：标签固定用 key 色，内容按状态取角色。
    # 与 Write-StatusRow（静态页）同一条契约，只是这里产出字符串而不是直接打印。
    $row = {
        param([string]$Label, [string]$Value, [string]$Role = 'text', [string]$Suffix = '')
        [void]$out.Add((Format-Styled 'key' ($Label + ' : ')) + (Format-Styled $Role ($Value + $Suffix)))
    }
    # 纯文本行（无标签的说明、标题、分隔线）按角色整行上色
    $line = {
        param([string]$Text, [string]$Role = 'text')
        [void]$out.Add((Format-Styled $Role $Text))
    }

    $problems = @(Get-StatusProblems $st)
    & $line '======== EnvProxy 状态（实时刷新）========' 'title'
    # 标题下空一行：标题在给下面的内容起头，结论立刻顶着标题读起来很闷。
    # 与帮助页同一套规矩（标题上下各空一行），两版状态页也一样。
    & $line '' 'text'
    if ($problems.Count -eq 0) {
        & $line '一切正常，不用做任何事。' 'ok'
    } else {
        & $line ('有 {0} 项要注意：' -f $problems.Count) 'warn'
        foreach ($p in $problems) { & $line ('  - ' + $p) 'warn' }
    }
    & $line '' 'text'

    # 监控
    if ($st.Monitor) {
        $mpid = 0
        try { $mpid = [int]$st.Monitor.ProcessId } catch { $mpid = 0 }
        if ($mpid -gt 0) {
            & $row $StatusLabels.Monitor ('运行中 (PID {0})' -f $mpid) 'ok'
        } else {
            # 心跳判活拿不到 PID：如实说"在写心跳"，不编一个号
            & $row $StatusLabels.Monitor '运行中（心跳正常）' 'ok'
        }
    } elseif ($st.StopIntent) {
        & $row $StatusLabels.Monitor '按你的选择停着' 'dim'
    } elseif ($st.NeverInstalled) {
        & $row $StatusLabels.Monitor '还没安装' 'dim'
    } else {
        & $row $StatusLabels.Monitor '不在了（可能被结束任务关掉或崩溃）' 'warn'
    }

    # 自启
    if ($st.AutoRunOk) { & $row $StatusLabels.AutoRun '已启用' 'ok' }
    else { & $row $StatusLabels.AutoRun '没生效' 'warn' }

    # 翻墙代理
    #
    # 这一行与下面「代理变量」那一行必须交代清楚各自是什么时候的结论——
    # 前者来自监控写的快照（2-3 秒一轮，且状态翻转要去抖两轮），后者是当场的试连。
    # 实时页每 2 秒重算一次，如果不说清，用户会看到「已开启」和「端口已不在」同屏，
    # 以为工具在抽风。快照里本来就有 pending_state（正在确认、尚未落定），
    # 用它把「矛盾」说成「进行中」。
    if ($st.Port) {
        $ageNote = ''
        $pending = ''
        if ($st.Snapshot -and $st.Snapshot.Status -eq 'ok') {
            if ($null -ne $st.Snapshot.AgeSec -and $st.Snapshot.AgeSec -gt $SnapshotFreshSec) {
                # 两档措辞：刚过新鲜线只是"稍旧"；过了可用线要明说这可能不代表现在——
                # 同一句话会让 30 秒和 200 秒看起来一样，而后者离"监控可能已经死了"很近。
                $ageNote = if ($st.Snapshot.AgeSec -gt $SnapshotUsableSec) {
                    ('（{0} 秒前的判断，可能已不是现在的情况）' -f $st.Snapshot.AgeSec)
                } else {
                    ('（{0} 秒前的判断）' -f $st.Snapshot.AgeSec)
                }
            }
            # 正在去抖：状态已经疑似变了，但还没确认够轮数
            $ps = ''
            try { $ps = [string]$st.Snapshot.PendingState } catch { $ps = '' }
            if ($ps) {
                $what = if ($ps -match '^on:(\d+)$') { ('刚发现端口 {0}' -f $Matches[1]) }
                        elseif ($ps -eq 'off') { '刚发现代理不在了' }
                        else { $ps }
                $pending = ('  · 正在确认：{0}' -f $what)
            }
        }
        & $row $StatusLabels.Proxy ('已开启（本地端口 {0} 监听中）' -f $st.Port) 'ok' ($ageNote + $pending)
    } elseif ($st.PortUnknown) {
        # 直接取值：$st 是 [ordered] 字典，缺键时取值是 $null、不会抛。
        # 不要用 PSObject.Properties.Name -contains 判断键存在——对字典它返回的是
        # 字典对象自身的属性（Count/Keys/Values），"-contains 某个键" 恒为假，
        # 于是失败原因永远显示不出来，而这正是排查「是 netstat 形状变了还是权限问题」
        # 唯一的线索。
        $why = ''
        if ($st.PortEnumerationReason) { $why = '：' + $st.PortEnumerationReason }
        & $row $StatusLabels.Proxy ('这一轮没读到端口，无法判断' + $why) 'warn'
    } else {
        & $row $StatusLabels.Proxy '未检测到（当前无翻墙代理在运行）' 'dim'
    }

    # ---- 第三组：代理变量（紧跟"翻墙代理"，两者是一件事的两端） ----
    #
    # 分组与静态页同一套（两版是同一屏的两种刷新方式，改一处必须改另一处）：
    # 进程与自启（后台在不在）、翻墙代理与代理变量（链路通不通）、终端同步（窗口跟不跟得上）。
    # 组间留白、组内紧凑——八行紧贴在一起是一坨字，眼睛找不到落点。
    # 顺序是有意的：代理变量必须紧跟翻墙代理，它们讲的是同一条链路的两端；
    # 终端同步排在最后，它只关系"已开的窗口跟不跟得上"，与链路本身无关。
    if ($st.ProxyValue -and $st.ProxyAlive) {
        & $row $StatusLabels.Vars ('已注入 ({0})' -f $st.ProxyValue) 'ok'
    } elseif ($st.ProxyValue -and $st.ProxyAlive -eq $false) {
        & $row $StatusLabels.Vars ('指向的端口已不在（{0}）' -f $st.ProxyValue) 'warn'
        $op = 0
        if ($st.ProxyPort) { $op = [int]$st.ProxyPort }
        if ($op -gt 0 -and $st.Port -and $op -ne [int]$st.Port) {
            & $line ('  变量里是旧端口 {0}，翻墙代理现在在 {1}。' -f $op, $st.Port) 'dim'
            & $line '  监控在跑的话几秒内会自己跟过去。' 'dim'
        } elseif (-not $st.Port) {
            & $line '  翻墙代理现在没在跑，所以这个地址已经没用了。' 'dim'
        }
    } elseif ($st.ProxyValue) {
        & $row $StatusLabels.Vars ('值不是合法地址（{0}）' -f $st.ProxyValue) 'warn'
    } else {
        & $row $StatusLabels.Vars '无（直连状态）' 'dim'
    }


    # ---- 第三组之二：更新中断 / 系统代理残留 ----
    # 这两段静态页有、实时帧曾经没有——同一份状态，按回车看和等它刷新，
    # 屏幕上的行数不一样，而缺的正好是"怎么办"那句。
    # 用户报"信息对不上"时，查的人会以为是缓存问题，实际是两份代码。
    if ($st.UpdateInProgress) {
        & $row $StatusLabels.LastUpdate '没有完成（覆盖过程中断）' 'warn'
        & $line '  程序文件可能新旧混合，某些功能会静默失效。' 'dim'
        & $line "  打开菜单选 $(Get-MenuKey 'Install')（$(Get-MenuName 'Install')）重做一次即可。" 'dim'
    }
    if ($st.SysProxy) {
        & $row $StatusLabels.SysProxy ("疑似残留（指向本机死端口 {0}，非本工具写入）。" -f $st.SysProxy.Server) 'warn'
        & $line '  浏览器打不开先检查它：系统设置 → 网络 → 代理，或把翻墙软件断开重进一次。' 'dim'
    }
    # ---- 第四组：终端同步 ----
    # 话术从 Get-TermSyncText 取，与静态页同源
    & $line '' 'text'
    if ($st.TermSync) {
        $tt = Get-TermSyncText $st.TermSync.State $st.TermSync
        $role = if ($tt.Bad) { 'warn' } else { 'ok' }
        & $row $StatusLabels.TermSync $tt.Text $role
        if ($tt.Hint) {
            foreach ($h in @($tt.Hint -split "`n")) {
                if ($h) { & $line ('  ' + $h) 'dim' }
            }
        }
    } else {
        & $row $StatusLabels.TermSync '状态未知' 'dim'
    }

    # ---- 第四组之二：固定入口（只在真的建过走代理的图标时才出现）----
    # 两版必须说同一句话，措辞与 Show-StatusSnapshot 里那一段逐字相同。
    # 判据用"有没有图标"而不是"中继在不在跑"：对没建图标的人那是必然的噪音。
    $relayIconCount = 0
    try { $relayIconCount = @(Get-ProxyShortcutRecords).Count } catch { $relayIconCount = 0 }
    if ($relayIconCount -gt 0) {
        $rs = $null
        try { $rs = Get-RelayStatus } catch {}
        & $line '' '' 'text'
        if ($rs -and $rs.Running) {
            & $row $StatusLabels.Advanced ("{0} 个图标，固定入口 http://127.0.0.1:{1} 正常" -f $relayIconCount, $rs.Port) 'ok'
        } else {
            & $row $StatusLabels.Advanced ("{0} 个图标，但固定入口没在工作（它们会退回直读当前代理，不影响使用）" -f $relayIconCount) 'dim'
        }
    }
    # 版本（与上面的状态分组分开：那是当前状态，这是软件版本）
    # 文案从 Get-VersionText 取——与静态页**同一份判断**。
    # 这里原来自己写了一小套（只认"相等=最新 / 否则=新版可用"），
    # 于是静态页说"开发副本"、实时帧说"已是最新"，同一台机器两句话。
    & $line '' '' 'text'
    $vt = Get-VersionText $st
    & $row $StatusLabels.Version $vt.Text $vt.Role

    # 日志尾
    #
    # 裁到「窗口宽 - 2」，按**显示宽度**算而不是字符数：中文一字两格，
    # 按字符数裁 78 会让中文密集的行实际占 90+ 格，折行——而这一层是按逻辑行
    # 做绝对定位的，折行会让后面每一行都错位。Get-DisplayWidth 就是为此存在的，
    # 静态页的 Show-RecentLog 已经这么做了，这里必须用同一个判据。
    & $line '' 'text'
    & $line '---------------- 最近日志 ----------------' 'title'
    $tail = ''
    if ($st.Snapshot -and $st.Snapshot.Status -eq 'ok') { $tail = [string]$st.Snapshot.LogTail }
    if (-not $tail) { try { $tail = [string](Get-LogTailText 3) } catch { $tail = '' } }
    $logW = 0
    try { $logW = (Get-ConsoleWidth) - 2 } catch { $logW = 78 }
    if ($logW -lt 20) { $logW = 20 }
    if ($tail) {
        foreach ($ln in @($tail -split "`n")) {
            if (-not $ln) { continue }
            & $line ('  ' + (Limit-DisplayText $ln $logW)) 'dim'
        }
    } else {
        & $line '  （暂无日志）' 'dim'
    }

    & $line '==================================' 'title'
    # 底部提示与结束框之间空一行：紧贴着会被读成框里的内容，
    # 而它是这一屏的操作说明——"按 0 返回"要让人一眼看到，不能被边框糊进去。
    & $line '' 'text'
    # 提示只能写真正支持的键。写了却没人处理的键，用户按下去毫无反应，
    # 会以为程序卡住了——比不写这句更糟。
    & $line '正在实时刷新 · 按 0 或 Esc 返回' 'cmd'
    return $out.ToArray()
}

# 实时状态页：自己刷新，不用按键。
#
# 退出条件：按 0 / q / Esc。
# 降级：不能画屏（重定向、无控制台、窗口太小）时直接打一次静态输出就走——
#       与今天的行为逐字节相同，绝不往文件里塞控制字符。
# 终端同步那两行的话术：状态码 -> 「一句结论 + 一句怎么办」。
#
# 为什么抽成数据而不是留在渲染里：状态码（ok/unpaired/blocked/stale/missing/nohost）
# 是内部词汇，只有这张表知道怎么把它翻译给使用者。两条渲染路径各自 switch 一遍，
# 结果就是实时页直接把 unpaired 印给用户、静态页给出中文——同一份数据两种说法。
# 表在这里，两个渲染器都从它取，加新状态只改一处。
function Get-TermSyncText([string]$State, $Sync) {
    switch ($State) {
        'ok'       { return @{ Text = '已生效（已开着的窗口敲回车即跟上）'; Hint = ''; Bad = $false } }
        'blocked'  {
            $detail = ''
            try { $detail = [string]$Sync.Detail } catch { $detail = '' }
            return @{ Text = '装了但跑不起来'; Hint = ($detail + "`n  按提示改一次，改完重开一个窗口。").Trim(); Bad = $true }
        }
        'unpaired' {
            # 不能说"重跑一次安装可修复"——重跑同样会被这条护栏拒绝。
            $line = 0
            try { $line = [int]$Sync.Line } catch { $line = 0 }
            $hint = if ($line -gt 0) {
                ('删掉配置文件里孤立的那行标记（第 {0} 行）再选 1。' -f $line)
            } else {
                '在配置文件里找到孤立的 EnvProxy 标记行删掉，再选 1。'
            }
            return @{ Text = '配置文件里的标记不成对，未改动它'; Hint = $hint; Bad = $true }
        }
        'stale'    {
            # 内容过期不是用户的问题，也不用手工改：安装会按当前版本重写。
            return @{ Text = '同步块是旧版本的'; Hint = '这不影响用，只是那段代码旧了；打开菜单选 1 会更新它。'; Bad = $true }
        }
        'missing'  { return @{ Text = '配置文件里没有同步块'; Hint = '打开菜单选 1 可以写入。'; Bad = $true } }
        'nohost'   { return @{ Text = '这一轮读不到配置文件路径，无法判断'; Hint = '过几秒再看一次；一直在就选 1。'; Bad = $true } }
        default    {
            # 走到这里说明 Get-TerminalSyncState 又加了新状态而这张表没跟上。
            # 必须打印出来：问题清单会说"终端同步没生效"，而整屏找不到那四个字，
            # 用户被指向一个不存在的提示（真发生过：State 叫 nohost、switch 处理 unknown）。
            return @{ Text = ('状态未知（' + $State + '）'); Hint = "打开菜单选 $(Get-MenuKey 'Install')（$(Get-MenuName 'Install')）重写一次。"; Bad = $true }
        }
    }
}

# 实时状态页：进屏幕、自己刷新、按 0/Esc 退出。
# 画不了屏（重定向 / 无控制台 / 窗口太小）时退回一次性静态输出。
function Show-StatusLive {
    $st = Get-StatusSnapshot
    $frame = @(Format-StatusLines $st)

    $need = Measure-ScreenFrame $frame
    if (-not (Test-CanDrawScreen -NeedLines $need.Lines -NeedWidth $need.Width)) {
        # 降级：退回今天的一次性输出
        Show-StatusSnapshot $st
        return
    }

    if (-not (Enter-Screen)) {
        Show-StatusSnapshot $st
        return
    }

    $prev = @()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $nextPaint = 0
    try {
        while ($true) {
            # 到点就重新算一帧。算之前先判能不能画——用户可能刚把窗口拉小。
            if ($sw.ElapsedMilliseconds -ge $nextPaint) {
                # 两个调用都要保护：取数失败留下一堆 $null 会顺着渲染冒泡，
                # 而渲染里几十处属性访问全靠输入恰好齐全——加一个可能为空的字段就抛。
                # 抛出去会让整个状态页退出（用户只是看一眼，不该被一帧失败踢出来），
                # 所以渲染失败就保留上一帧，下一轮再试。
                try { $st = Get-StatusSnapshot } catch { $st = $null }
                try { $frame = @(Format-StatusLines $st) } catch { $frame = $prev }
                $need = Measure-ScreenFrame $frame
                if (Test-CanDrawScreen -NeedLines $need.Lines -NeedWidth $need.Width) {
                    $null = Write-ScreenFrame -Old $prev -New $frame
                    $prev = $frame
                } else {
                    # 画不了（窗口太小）。作废记账：等窗口恢复时必然整帧重画，
                    # 否则屏幕上会停着半截旧帧，而"变化的行"永远补不齐它。
                    $prev = @()
                }
                # 固定 2 秒刷新：与监控的探测节奏（2-3 秒）对齐。
                # 比监控更快没有意义——数据本身就是监控写的，它 2 秒才更新一次。
                $nextPaint = $sw.ElapsedMilliseconds + $StatusRefreshIntervalMs
            }
            $k = Wait-ScreenKey -Milliseconds $ScreenPollMs
            if ($k -eq 'Quit') { break }
            # 'Error' = 读键通道没了（控制台句柄失效之类）。继续转下去只会空转，
            # 而且永远等不到 Quit —— 交回屏幕退出，别让用户面对一台变卡的机器。
            if ($k -eq 'Error') { break }
        }
    } finally {
        # 任何退出路径都要恢复：Ctrl+C 走 finally，光标不会永久消失。
        Exit-Screen
    }
}
function Show-Status {
    # 状态对象先在内存里算完，再统一渲染。
    # 为什么不能边算边打印：结论行("一切正常" / "有 N 项要注意")必须出现在最上面，
    # 而它是全部检查跑完之后才知道的。先打印再补结论 = 用户读完 8 行还要自己合成判断。
    # 这一层也是 --json 之类机器可读输出的前提（先有对象，才有第二种渲染方式）。
    $st = Get-StatusSnapshot
    Show-StatusSnapshot $st
}

# 生成一份可以直接发给别人看的问题报告。
#
# 为什么要它：以前反馈唯一的办法是"自己找到日志文件、打开、复制、再贴到 GitHub"。
# 不会用 GitHub、不会敲命令的人卡在第一步就放弃了。这里把整件事压成一个按键：
# 收集 → 存成单个文件 → 路径直接进剪贴板 → 屏幕上说清下一步做什么。
#
# 反馈时问的问题。前三条是结构化的（作者能按栏目定位），第四条是自由补充——
# 有些情况前三条装不下：报错原文、你试过什么、你怀疑哪里不对。留一个开口，
# 比逼着用户把话塞进三个格子里好。
# 顺序即重要性：先定"哪个环节坏了"，再问"你看到什么"，最后问"你本来想做什么"，
# 因为同一现象在不同意图下是完全不同的问题。
# 问题写成大白话：使用者不是工程师，问"请描述你的复现步骤"只会得到一句"就是不好使"。
$ReportQuestions = @(
    @{ Key = 'where';  Text = '哪一步出的问题？';       Example = '比如：装完之后终端里还是上不了网 / 换了新的翻墙软件 / 升级之后就这样了' }
    @{ Key = 'what';   Text = '屏幕上显示了什么？';     Example = '比如：状态页说未运行 / 命令报 ECONNREFUSED / 点了没反应' }
    @{ Key = 'expect'; Text = '你本来希望它做什么？';   Example = '比如：希望 git clone 能直接通 / 希望它自己跟着翻墙软件开关' }
    @{ Key = 'extra';  Text = '还有什么想补充的？';     Example = '想写什么都行：报错原文、你试过什么、你怀疑哪里不对'; Free = $true }
)

# 问一个问题，回车跳过。跳过时报告里写"（没填）"而不是留白——
# 留白会被读成"这一项不适用"，而"没填"才是真的信息（作者据此知道还得追问）。
# $Free 表示这一问是自由补充：提示语换成"想写什么都行"，也不显示"直接回车"以外的引导，
# 因为自由的题目再给例子反而限制住人。
function Read-ReportAnswer([string]$Prompt, [string]$Example, [bool]$Free = $false) {
    Write-Host ''
    Write-Styled 'heading' ('  ' + $Prompt)
    Write-Host ''
    if ($Free) {
        Write-Styled 'dim' '    想写什么都行，一段话也行。'
    } elseif ($Example) {
        Write-Styled 'dim' ('    ' + $Example)
    }
    Write-Styled 'dim' '    （不想写就直接回车）'
    $text = ''
    try { $text = [string](Read-Host '  > ') } catch { $text = '' }
    return $text.Trim()
}

# 把使用者写的那几段拼成报告里的一节。
function Format-ReportAnswers($Answers) {
    $out = New-Object System.Collections.ArrayList
    foreach ($q in $ReportQuestions) {
        $v = [string]$Answers[$q.Key]
        if (-not $v) { $v = '（没填）' }
        [void]$out.Add('  ' + $q.Text)
        foreach ($ln in @($v -split "`r?`n")) {
            if ($ln) { [void]$out.Add('    ' + $ln) } else { [void]$out.Add('') }
        }
        [void]$out.Add('')
    }
    return $out
}

function New-ProblemReport {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $fileName = 'report-' + $stamp + '.txt'
    $target = Join-Path $MonitorDir $fileName
    # monitor\ 不可写时退到临时目录：报告不能因为路径问题就生成不出来。
    if (-not (Test-Path -LiteralPath $MonitorDir)) { $null = New-Item -ItemType Directory -Path $MonitorDir -Force -ErrorAction SilentlyContinue }

    # 先问清楚"你遇到的是什么问题"，再收集环境。
    # 顺序不能反：只把环境收齐、却不问症状，作者拿到的是一份"这台机器当时长什么样"，
    # 而不是"哪里坏了"——三十行状态值一条也用不上，还得反问用户，一来一回一天。
    Write-Host ''
    Write-Styled 'title' '======== 问题反馈 ========'
    Write-Host ''
    Write-Styled 'text' '  下面问你四句话，一句话一行，随手写就行。'
    Write-Styled 'dim'  '  写完会自动补上这台机器的情况，生成一份可以贴到网页上的报告。'
    $answers = @{}
    $anyAnswer = $false
    foreach ($q in $ReportQuestions) {
        $a = Read-ReportAnswer $q.Text $q.Example ([bool]$q.Free)
        $answers[$q.Key] = $a
        if ($a) { $anyAnswer = $true }
    }
    if (-not $anyAnswer) {
        Write-Host ''
        Write-Styled 'warn' '  四句都空着。这样的报告发出去，对方只能反问你要细节。'
        $go = 'n'
        try { $go = [string](Read-Host '  还是要生成吗？(y/N)') } catch { $go = 'n' }
        if ($go -notmatch '^[Yy]') {
            Write-Styled 'dim' '  已取消，什么都没做。'
            return
        }
    }

    $L = New-Object System.Collections.ArrayList
    # 报告里的每一行都从这里过，所以脱敏放在这里——**唯一汇聚点**。
    # 状态页必须如实显示代理地址（那是它的职责），而报告是准备发给别人的，
    # 带认证的代理（http://user:pass@host:port）原样落盘就是把明文密码写进文件。
    # 放在这而不是逐个调用点改：漏一处就是事故，而这里没有第二处可漏。
    $add = { param($s) [void]$L.Add((Hide-ProxyCredential ([string]$s))) }
    $rule = { param($title) [void]$L.Add('---------------- ' + $title + ' ----------------') }

    & $add '======== EnvProxy 问题报告 ========'
    & $add ('生成时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

    # 使用者自己写的那一段放在最前面：报告是给人读的，作者第一眼该看到"哪里坏了"，
    # 而不是先读三十行环境值才在末尾找到一句"不好使"。
    & $add ''
    & $rule '你遇到的问题'
    foreach ($ln in (Format-ReportAnswers $answers)) { & $add $ln }

    $ver = ''
    try { $ver = Get-LocalVersion } catch { $ver = '' }
    if (-not $ver) { $ver = '未知' }
    $isDev = $false
    try { $isDev = Test-DevCopy } catch { $isDev = $false }
    & $add ('程序版本：v' + $ver + $(if ($isDev) { '（开发副本）' } else { '' }))
    & $add ('系统：' + [System.Environment]::OSVersion.VersionString)
    & $add ('PowerShell：' + $PSVersionTable.PSVersion.ToString())
    & $add ''

    & $rule '当前状态'
    try {
        $snap = Get-StatusSnapshot
        # 用纯文本渲染器：报告是给文件看的，不能带颜色控制字符。
        # 底部那两句是屏幕上的操作提示（"正在实时刷新""按 0 返回"），
        # 进了文件只会让读的人困惑——它们不是状态本身。按行剔掉。
        foreach ($ln in @(Format-StatusLines $snap)) {
            $plain = Remove-AnsiColor $ln
            if ($plain -match '^\s*(正在实时刷新|按 0 或 Esc)') { continue }
            if ($plain -match '^\s*=+\s*$') { continue }
            if ($plain -match '^\s*======== EnvProxy 状态') {
                & $add '======== EnvProxy 状态 ========'
                continue
            }
            & $add $plain
        }
    } catch {
        & $add ('（取状态时出错：' + $_.Exception.Message + '）')
    }
    & $add ''

    & $rule '运行日志（最后 30 行）'
    $tail = ''
    try { $tail = [string](Get-LogTailText 30) } catch { $tail = '' }
    if ($tail) { foreach ($ln in @($tail -split "`n")) { if ($ln) { & $add ('  ' + $ln) } } }
    else { & $add '  （还没有日志：这个工具可能从未运行过）' }
    & $add ''

    & $rule '后台程序快照（排查用）'
    $sn = $null
    try { $sn = Read-StateSnapshot } catch { $sn = $null }
    if ($sn -and $sn.Status -eq 'ok') {
        & $add ('  最近一次判断：' + $sn.State)
        & $add ('  写入轮次：' + $sn.Round + '    进程号：' + $sn.Pid)
        & $add ('  距今：' + $sn.AgeSec + ' 秒前')
        & $add ('  端口扫描：' + $sn.PortEnumeration + $(if ($sn.PortReason) { '（' + $sn.PortReason + '）' } else { '' }))
        # 后台程序是旧版本时明确写出来：升级后没重启监控，这个差异会让人误判。
        if ($sn.Pid -gt 0) {
            $livePid = 0
            try { $livePid = [int](Get-MonitorProcessFast).ProcessId } catch { $livePid = 0 }
            if ($livePid -gt 0 -and $livePid -ne $sn.Pid) {
                & $add ('  注意：快照是旧进程 ' + $sn.Pid + ' 写的，现在跑的是 ' + $livePid + '。选 1 可重启后台程序。')
            }
        }
    } elseif ($sn) {
        & $add ('  读不出来：' + $sn.Status + $(if ($sn.Reason) { '（' + $sn.Reason + '）' } else { '' }))
        & $add '  （这不影响使用，状态页会自动改用实时探测）'
    } else {
        & $add '  （没有快照文件：后台程序可能从没跑过）'
    }
    & $add ''

    & $rule '位置'
    & $add ('  程序目录：' + $ScriptDir)
    & $add ('  运行状态目录：' + $MonitorDir)
    & $add ''

    # 项目地址跟着正文一起写进去：报告可能隔几天才发，那时不一定还记得地址在哪。
    # 地址只有一处来源（见 Get-ProjectUrls），不许在这里手写第二份。
    $urls = Get-ProjectUrls
    & $rule '发到哪里'
    & $add ('  提问题：' + $urls.Issues)
    & $add ('  项目主页：' + $urls.Home)
    & $add ''
    & $add '=================================='
    & $add '这份报告含本机路径与端口。代理地址里的账号密码已经隐去。'
    & $add '发出去之前可以先自己打开看一眼。'

    $text = ($L -join "`r`n")
    $saved = ''
    try {
        Write-Text -Path $target -Text $text -WithBom $false
        $saved = $target
    } catch {
        # monitor\ 写不进去（只读分区、权限），退到临时目录
        try {
            $target = Join-Path $env:TEMP $fileName
            Write-Text -Path $target -Text $text -WithBom $false
            $saved = $target
        } catch { $saved = '' }
    }

    Write-Host ''
    if (-not $saved) {
        Write-Styled 'warn' '报告生成失败：两个位置都写不进去。'
        Write-Styled 'dim' "  可以先把菜单选 $(Get-MenuKey 'Status')（$(Get-MenuName 'Status')）的截图发给对方。"
        # 退出码是这条命令唯一能被程序读懂的结论，说"成功"而实际失败是谎报。
        # 与 mac 侧同一套语义（那边 report 分支 return 1）。AGENTS 规定：1 = 失败。
        $script:ReportExitCode = 1
        return
    }

    Write-Styled 'title' '======== 报告已生成 ========'
    Write-Host ''
    Write-Styled 'ok' '  报告文件：'
    Write-Styled 'value' ('  ' + $saved)
    Write-Host ''
    # 剪贴板：不保证有（远程会话、某些精简环境），失败就只打印路径，不报错。
    $copied = $false
    try {
        Set-Clipboard -Value $saved -ErrorAction Stop
        $copied = $true
    } catch { $copied = $false }
    if ($copied) {
        Write-Styled 'ok' '  这个路径已经复制到剪贴板了，可以直接粘到聊天窗口里。'
    } else {
        Write-Styled 'dim' '  （这个环境没有剪贴板，请手动把上面那个路径复制下来）'
    }
    Write-Host ''
    Write-Styled 'heading' '  接下来怎么发出去'
    Write-Host ''
    Write-Styled 'text' '    把这个地址打开，新建一个 issue，把报告内容贴进去：'
    Write-Styled 'value' ('      ' + $urls.Issues)
    Write-Styled 'dim' '  这是本项目唯一收问题的地方。'
    Write-Host ''
    Write-Styled 'dim' '  按回车回到菜单'
    try { $null = Read-Host } catch { }
}

# 采集状态：只读、不写文件、不提问、不猜。所有值都来自现成函数。
function Get-StatusSnapshot {
    $st = [ordered]@{}
    # 判"监控在不在"走轻量路径：只读心跳，实测 3.8 毫秒；
    # 而 Get-MonitorProcess 为了拿命令行要查进程表，实测 170 毫秒。
    # 状态页每次刷新都要问一次，用重的那条等于每 2 秒白烧一次 CPU。
    # 心跳过期（说不清）时才退回复用完整判据——那种情况本来就少见。
    $st.Monitor = Get-MonitorProcessFast
    if (-not $st.Monitor) { $st.Monitor = Get-MonitorProcess }
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
    # ---- 端口与状态：优先读监控写下的快照，读不到/太旧才自己探测 ----
    #
    # 为什么不再一律自己探测：最坏情况（代理刚换端口、变量指向的旧端口已死）
    # 那要 2.7 秒——因为必须走全端口 CONNECT 扫描。而监控每 2-3 秒就在做同一件事，
    # 结论它早就有了。读快照约 2 毫秒，且两边结论同源（不会出现"状态页说没代理、
    # 监控还在用 7078"这种自相矛盾）。
    #
    # 降级由 Read-StateSnapshot 的 Status 表达：ok 用快照；none/unreadable/damaged
    # 退回实时探测。任何情况下都不许把"读不出来"当成"没有代理"。
    $st.Snapshot = Read-StateSnapshot
    $snapOk = ($st.Snapshot.Status -eq 'ok')
    if ($snapOk -and ($null -ne $st.Snapshot.AgeSec)) {
        # 时间戳比现在晚 60 秒以上 = 系统时间被调过，不许当"刚写的"
        if ($st.Snapshot.AgeSec -lt -60) { $snapOk = $false; $st.Snapshot.Status = 'skewed' }
        elseif ($st.Snapshot.AgeSec -gt $SnapshotStaleSec) { $snapOk = $false; $st.Snapshot.Status = 'stale' }
    } else { $snapOk = $false }

    if ($snapOk) {
        # 快照里的 state 形如 'on:7078' / 'off' / ''
        $snapPort = 0
        if ($st.Snapshot.State -match '^on:(\d+)$') { $snapPort = [int]$Matches[1] }
        $st.Port = if ($snapPort -gt 0) { $snapPort } else { $null }
        $st.PortUnknown = ($st.Snapshot.PortEnumeration -eq 'failed')
        $st.PortEnumerationReason = [string]$st.Snapshot.PortReason
        # 监控每轮算过"变量是否与状态一致、写进去了没有"，状态页要消费它们。
        # 不读的后果是白算——快照里有，而屏幕上永远看不到，用户以为一切正常。
        # 读不到（老版本写的快照没有这两个字段）时留空串，判据那里按"不报"处理。
        $st.VarsMatch = [string]$st.Snapshot.VarsMatch
        $st.ApplyResult = [string]$st.Snapshot.ApplyResult
    } else {
        $st.Port = Get-InUseProxyPort -FullScan:$true
        $st.PortUnknown = [bool]$script:PortEnumerationFailed
        try { $st.PortEnumerationReason = [string]$script:PortEnumerationReason } catch { $st.PortEnumerationReason = '' }
        # 没读到快照就没有这两个结论：留空串，不许假设成"一致 / 成功"。
        $st.VarsMatch = ''
        $st.ApplyResult = ''
    }
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

# 问题清单：这一屏只回答一个问题"我现在正常吗"。
#
# 抽成独立函数（不写在渲染里）有两个理由：
#   ① 实时刷新那一版和静态快照那一版必须用**同一套判断**，否则两边会说出不同的话；
#   ② 判断与渲染混在一起时，加一条问题要同时改两个地方，必有一处漏。
function Get-StatusProblems($st) {
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
    if ($st.TermSync -and $st.TermSync.State -ne 'ok') { $problems += "终端同步没生效" }
    if ($st.SysProxy) { $problems += "系统代理可能残留（不是本工具写的）" }
    if ($st.UpdateInProgress) { $problems += "上次更新没有完成，程序文件可能新旧混合" }
    # 代理变量与"当前状态"对不上、以及写不进去——这两件事监控每轮都算，
    # 但状态页从来没读过，于是它们即使出问题也不会出现在"有 N 项要注意"里。
    # 用户看到的是"一切正常"，而终端其实连不上。
    if ($st.VarsMatch -eq 'no') { $problems += "代理变量和当前状态对不上（可能被别的程序改了）" }
    if ($st.ApplyResult -eq 'failed') { $problems += "代理变量写不进去（下一轮还会再试）" }
    return $problems
}

function Show-StatusSnapshot($st) {
    # ---- 先把结论算出来（判断在 Get-StatusProblems 里，与实时刷新那版共用）----
    $problems = @(Get-StatusProblems $st)

    Write-Styled 'title' "======== EnvProxy 状态 ========"
    # 标题下空一行，与实时刷新那版、帮助页同一套规矩。
    Write-Host ''
    if ($problems.Count -eq 0) {
        Write-Styled 'ok' "一切正常，不用做任何事。"
    } elseif ($st.NeverInstalled) {
        # 从没装过：三件"没生效"都是同一个事实（还没装），
        # 说成"有 3 项要注意"会让第一次打开的人以为机器有三处毛病。
        Write-Styled 'dim' "还没开始用。打开菜单选 $(Get-MenuKey 'Install')（$(Get-MenuName 'Install')）（安装 / 修复）就能装上。"
    } else {
        Write-Styled 'warn' ("有 {0} 项要注意：" -f $problems.Count)
        foreach ($p in $problems) { Write-Styled 'warn' ("  - " + $p) }
    }
    Write-Host ''

    # ---- 要注意的：只印有问题的那几项，每项带一句怎么办 ----
    $m = $st.Monitor
    if (-not $m) {
        Write-StatusRow $StatusLabels.Monitor '未运行' 'warn'
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
                Write-Styled 'dim' "  打开菜单选 $(Get-MenuKey 'Install')（$(Get-MenuName 'Install')）（安装 / 修复）可以一起修好。"
            }
        } elseif ($st.NeverInstalled) {
            # 从没装过：这不是问题，是起点。用"崩溃/被结束任务"描述它，
            # 第一次打开的人会以为自己的机器出了事（"我明明没装过"）。
            Write-Styled 'dim' "  （还没装过。装上之后它会自己常驻，不用你管）"
            Write-Styled 'dim' "  打开菜单选 $(Get-MenuKey 'Install')（$(Get-MenuName 'Install')）（安装 / 修复）开始使用。"
        } else {
            Write-Styled 'warn' "  （不是点了停止，是进程不在了：可能被结束任务关掉，或崩溃）"
            Write-Styled 'dim' "  打开菜单选 $(Get-MenuKey 'Install')（$(Get-MenuName 'Install')）（安装 / 修复）可以让它重新跑起来。"
        }
    }
    if (-not $st.AutoRunOk) {
        if ($st.AutoRunRaw) {
            Write-StatusRow $StatusLabels.AutoRun '记录还在，但启动文件已不存在（登录时不会启动）' 'warn'
            Write-Styled 'dim' ("  记录指向：{0}" -f $(if ($st.AutoRunLauncher) { $st.AutoRunLauncher } else { $st.AutoRunRaw }))
        } else {
            Write-StatusRow $StatusLabels.AutoRun '未启用' 'warn'
        }
        Write-Styled 'dim' "  打开菜单选 $(Get-MenuKey 'Install')（$(Get-MenuName 'Install')）（安装 / 修复）可以重建。"
    }
    if (-not $st.ProxyValue -and $st.Port -and -not $m -and -not $st.NeverInstalled) {
        # "翻墙代理有" + "代理变量无" 单独看像自相矛盾。实话是：软件在跑，
        # 但本工具没在它上面工作（多半是用户自己停的）。补一句桥接，否则会被判定"坏了"。
        Write-StatusRow $StatusLabels.Vars '无（翻墙软件在跑，但本工具已停用，所以没往终端里设代理）' 'dim'
    } elseif ($st.ProxyValue -and $null -eq $st.ProxyAlive) {
        # 值在，但不是个能解析的地址。与"端口已不在"分开说：那个等监控自愈就行，
        # 这个说明变量被别的工具改坏了（写进了半个地址、或者端口是个词）。
        # 不许落绿字"已注入"——那等于告诉用户一切正常。
        Write-StatusRow $StatusLabels.Vars ("值不是合法地址（{0}）" -f $st.ProxyValue) 'warn'
        Write-Styled 'dim' "  多半是别的工具改写成了半个地址。选 $(Get-MenuKey 'Install')（$(Get-MenuName 'Install')）（安装 / 修复）会按当前代理重写一遍。"
    } elseif ($st.ProxyValue -and -not $st.ProxyAlive) {
        Write-StatusRow $StatusLabels.Vars ("指向的端口已不在（{0}）" -f $st.ProxyValue) 'warn'
        Write-Styled 'warn' ("  终端里联网会报 ECONNREFUSED，错误里没有本工具的名字，所以你会去查网络。")
        # 这一屏最容易被读成"工具坏了"：翻墙代理明明是开着的，代理变量却说端口不在。
        # 实情是**它俩指向的不是同一个端口**——换了端口、变量还停在旧的那个上。
        $oldPort = $null
        try {
            $pv = Split-ProxyUrl $st.ProxyValue
            if ($pv -and $pv.Port) { $oldPort = [int]$pv.Port }
        } catch {}
        if ($oldPort -and $st.Port -and $oldPort -ne [int]$st.Port) {
            # 代理在别的端口上活着：跟着它走就对了
            Write-Styled 'dim' ("  变量里是旧端口 {0}，翻墙代理现在在 {1}。" -f $oldPort, $st.Port)
            Write-Styled 'dim' "  监控在跑的话几秒内会自己跟过去；想立刻跟上就选 $(Get-MenuKey 'Install')（$(Get-MenuName 'Install')）。"
        } elseif (-not $st.Port) {
            # 代理根本没在跑：没有可跟的目标，那就是该清掉
            Write-Styled 'dim' '  翻墙代理现在没在跑，所以这个地址已经没用了。'
            Write-Styled 'dim' "  监控在跑的话几秒内会把它清掉；想立刻清掉就选 $(Get-MenuKey 'Install')（$(Get-MenuName 'Install')）。"
        } else {
            # 端口解析不出来（极少见），只给通用说法，不编具体原因
            Write-Styled 'dim' '  这个地址已经连不上了（多半是刚换过端口）。'
            Write-Styled 'dim' "  监控在跑的话几秒内会自己跟上；想立刻跟上就选 $(Get-MenuKey 'Install')（$(Get-MenuName 'Install')）。"
        }
    } elseif ($st.ProxyValue -and -not $m) {
        Write-StatusRow $StatusLabels.Vars ("已注入（{0}），但没人维护" -f $st.ProxyValue) 'warn'
        Write-Styled 'dim' "  翻墙软件断开后不会自动清掉，终端会连不上。"
        Write-Styled 'dim' "  打开菜单选 1 恢复监控；或选 7 一键恢复，把这批变量一并清掉。"
    }
    if ($st.TermSync) {
        # 话术从 Get-TermSyncText 取：与实时状态页同一张表，两边说的话逐字相同。
        $tt = Get-TermSyncText $st.TermSync.State $st.TermSync
        if ($tt.Text -ne '已生效（已开着的窗口敲回车即跟上）') {
            Write-StatusRow $StatusLabels.TermSync $tt.Text 'warn'
            if ($tt.Hint) {
                foreach ($h in @($tt.Hint -split "`n")) {
                    if ($h) { Write-Styled 'dim' ('  ' + $h) }
                }
            }
        }
    }
    if ($st.UpdateInProgress) {
        Write-StatusRow $StatusLabels.LastUpdate '没有完成（覆盖过程中断）' 'warn'
        Write-Styled 'dim' "  程序文件可能新旧混合，某些功能会静默失效。"
        Write-Styled 'dim' "  打开菜单选 $(Get-MenuKey 'Install')（$(Get-MenuName 'Install')）（安装 / 修复）重做一次即可。"
    }
    if ($st.SysProxy) {
        Write-StatusRow $StatusLabels.SysProxy ("疑似残留（指向本机死端口 {0}，非本工具写入）。" -f $st.SysProxy.Server) 'warn'
        # 这一行是"怎么处理"的说明，与它上面那条结论不该同级；
        # 都是 warn 会让整段看起来像两个错误，实际是"一个问题 + 一条办法"。mac 侧本来就是 dim。
        Write-Styled 'dim' "  浏览器打不开先检查它：系统设置 → 网络 → 代理，或把翻墙软件断开重进一次。"
    }
    # ---- 参考信息：正常项各占一行，用 ok 色方便一眼确认核心链路是通的 ----
    #
    # 分组之间空一行：八行数据紧贴在一起，观感是"一坨字"，眼睛找不到落点。
    # 分三组——进程与自启（后台在不在）、代理与变量（翻墙链路通不通）、
    # 终端同步（已开的窗口跟不跟得上）。组内紧凑、组间留白。
    # 空行只在"前一组确实印了东西"时才补，避免连着两个空行。
    $printedGroup = $false
    if ($m) { Write-StatusRow $StatusLabels.Monitor ("运行中 (PID {0})" -f $m.ProcessId) 'ok'; $printedGroup = $true }
    if ($st.AutoRunOk) { Write-StatusRow $StatusLabels.AutoRun '已启用' 'ok'; $printedGroup = $true }

    if ($st.Port -or $st.PortUnknown -or $st.ProxyValue) {
        if ($printedGroup) { Write-Host '' }
    }
    if ($st.Port) {
        Write-StatusRow $StatusLabels.Proxy ("已开启（本地端口 {0} 监听中）" -f $st.Port) 'ok'
    } elseif ($st.PortUnknown) {
        Write-StatusRow $StatusLabels.Proxy '这一轮没读到本机端口，无法判断（正常，会自动重试）' 'warn'
    } else {
        Write-StatusRow $StatusLabels.Proxy '未检测到（当前无翻墙代理在运行）' 'dim'
    }
    # 代理变量只有"已注入且活着"这一种情况才进参考区；
    # 指向死端口、没人维护、翻墙在跑但工具停用这三种都已在上面说过，
    # 这里再打一遍就是同一件事说两次，读者会以为有两处不同的问题。
    if ($st.ProxyValue -and $st.ProxyAlive -and $m) {
        Write-StatusRow $StatusLabels.Vars ("已注入 ({0})" -f $st.ProxyValue) 'ok'
    } elseif (-not $st.ProxyValue -and -not $st.Port) {
        # 只有"确实没有翻墙软件在跑"时才说"直连状态"。
        # 少了 -not $st.Port 这一半，就会与上面那条"翻墙软件在跑但本工具已停用"
        # 同时命中：同一屏里"代理变量"出现两次，一次说"已停用"、一次说"直连"，
        # 用户会以为有两处不同的设置要处理（实测复现过）。
        # 判据必须是**完整**的：有代理在跑就不该说"直连"，那是两件事。
        Write-StatusRow $StatusLabels.Vars '无（直连状态）' 'dim'
    }
    if ($st.TermSync -and $st.TermSync.State -eq 'ok') {
        Write-Host ''
        Write-StatusRow $StatusLabels.TermSync '已生效（已开着的窗口敲回车即跟上）' 'ok'
    }
    # ---- 固定入口（只在真的建过走代理的图标时才出现）----
    # 措辞与实时帧逐字相同：两版是同一屏的两种刷新方式，改一处必须改另一处。
    # 这里曾经只有实时帧有、静态页整段缺失——建过图标的人在降级路径下就看不到它，
    # 而它正是"程序记的地址为什么不会失效"的唯一解释。
    # 判据用"有没有图标"而不是"中继在不在跑"：对没建图标的人那是必然的噪音。
    $relayIconCount = 0
    try { $relayIconCount = @(Get-ProxyShortcutRecords).Count } catch { $relayIconCount = 0 }
    if ($relayIconCount -gt 0) {
        $rs = $null
        try { $rs = Get-RelayStatus } catch {}
        Write-Host ''
        if ($rs -and $rs.Running) {
            Write-StatusRow $StatusLabels.Advanced ("{0} 个图标，固定入口 http://127.0.0.1:{1} 正常" -f $relayIconCount, $rs.Port) 'ok'
        } else {
            Write-StatusRow $StatusLabels.Advanced ("{0} 个图标，但固定入口没在工作（它们会退回直读当前代理，不影响使用）" -f $relayIconCount) 'dim'
        }
    }

    Write-Host ''
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
    $vt = Get-VersionText $st
    Write-StatusRow $StatusLabels.Version $vt.Text $vt.Role
}

# 版本那一行说的是什么——**唯一实现**，静态页与实时帧都从这里取。
#
# 为什么抽出来：这一行原来有两份判断。静态页认六种情况（开发副本 / 源码包 /
# 还没查过 / 比发布版新 / 发现有新版 / 已是最新），实时帧只认两种（相等就"已是最新"、
# 否则"新版可用"）。于是同一台机器上，按回车看到"开发副本（更新走 git pull）"、
# 等五秒后刷新变成"已是最新"——两句互相矛盾的话，而两处代码各自"看起来都对"。
# 用户报"信息对不上"时，查的人会以为是缓存问题，实际是两份代码。
#
# 返回 @{ Text; Role }：Text 是完整的一整句（含括号），Role 是颜色角色。
function Get-VersionText($st) {
    $localVer = $st.LocalVersion
    $cache = $st.RemoteCache
    $localText = if ($localVer) { "v$localVer" } else { "未知" }
    if (-not $cache) {
        # 还没有缓存：不联网、不猜，说清为什么 + 去哪儿主动查。
        return @{ Text = ("{0}（还没查过最新版；监控每 30 轮查一次，也可以选 3 立刻查）" -f $localText); Role = 'dim' }
    }
    $remote = $null
    if ($cache.Version) { $remote = @{ Version = $cache.Version; Tag = ("v" + $cache.Version) } }
    $ageText = ""
    if ($cache.AgeMinutes -ge 1440) { $ageText = ("（{0} 天前的记录）" -f [int]($cache.AgeMinutes / 1440)) }
    elseif ($cache.AgeMinutes -ge 60) { $ageText = ("（{0} 小时前的记录）" -f [int]($cache.AgeMinutes / 60)) }
    if (-not $remote) { return @{ Text = ($localText + $ageText); Role = 'dim' } }
    $state = $null
    $role = 'ok'
    if (Test-DevCopy) {
        $state = "开发副本（更新走 git pull，本入口不改动文件）"; $role = 'dim'
    } elseif (Test-SourceCopy) {
        $state = "源码包（更新入口会先确认用途再动手）"; $role = 'warn'
    } elseif (-not $localVer) {
        $state = "可打开菜单选 $(Get-MenuKey 'Update')（$(Get-MenuName 'Update')）（检查更新）升级"; $role = 'warn'
    } elseif ((Compare-Versions $localVer $remote.Version) -gt 0) {
        $state = "本地版本比最新发布版新"; $role = 'dim'
    } elseif ((Compare-Versions $remote.Version $localVer) -gt 0) {
        $state = ("发现新版 {0}，选 $(Get-MenuKey 'Update')（$(Get-MenuName 'Update')）（检查更新）即可升级" -f $remote.Tag); $role = 'warn'
    } else {
        $state = "已是最新"; $role = 'dim'
    }
    return @{ Text = ("{0}（{1}）{2}" -f $localText, $state, $ageText); Role = $role }
}

# 把一段文本裁到指定**显示宽度**，超出时末尾补省略号。
#
# 为什么不用 .Length：中文一字两格。按字符数裁 78 会让中文密集的行实际占 90+ 格，
# 在 80 列窗口里折行——而状态页是按逻辑行做绝对定位的，折行会让后面每行都错位。
# 这是唯一实现：静态页的最近日志与实时页的日志段都调它，不许各写一份。
function Limit-DisplayText([string]$Text, [int]$Width) {
    if (-not $Text) { return '' }
    if ($Width -le 1) { return '' }
    if ((Get-DisplayWidth $Text) -le $Width) { return $Text }
    $acc = ''
    $accW = 0
    foreach ($ch in $Text.ToCharArray()) {
        $cw = Get-CharWidth $ch
        if ($accW + $cw -gt ($Width - 1)) { break }
        $acc += $ch
        $accW += $cw
    }
    return $acc + '…'
}

# 最近日志：读最后 3 行，按窗口宽度裁。纯读+打印，不探测、不写文件。
function Show-RecentLog {
    # 日志块与上面的状态分组之间空一行：这是两块不同性质的东西（当前状态 vs 历史记录），
    # 紧贴着会让"最近日志"看起来像状态的一部分。
    Write-Host ''
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
        $shown = Limit-DisplayText $shown $logW
        Write-Styled 'dim' "  $shown"
    }
    Write-Styled 'title' "=================================="
}

# ------------------------------------------------------------------------------
# 8. 菜单（唯一双击入口"打开菜单"背后：编号→现有开关，不新增行为）
# ------------------------------------------------------------------------------
# 屏幕刷新：菜单与帮助都是"一屏一页"，切换页面时先清屏再画（清屏实现在 base 层的 Clear-Screen）。

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
    @{ Key = "5"; Name = "高级功能";   Switch = "Advanced";  Group = "进阶"; Hint = "给某个软件建一个能翻墙的图标" },
    @{ Key = "6"; Name = "停止监控";   Switch = "Stop";      Group = "维护"; Hint = "先停掉，下次开机自己回来" },
    @{ Key = "7"; Name = "一键恢复";   Switch = "Uninstall"; Group = "维护"; Hint = "彻底卸载，回到没装之前" },
    @{ Key = "8"; Name = "问题反馈";   Switch = "Report";    Group = "支持"; Hint = "出问题了，一键生成一份报告" },
    @{ Key = "0"; Name = "退出";       Switch = "";          Group = "退出"; Hint = "关掉这个窗口" }
)

# 菜单编号的唯一权威处就是上面那张表的 Key 列。散文里写"选 N"时**一律从这张表取**。
#
# 为什么值得一个函数：用户在状态页、帮助、错误提示里看到的"选 N（某某）"有几十处，
# 而菜单项一旦重排（加一项、挪一组），写死的数字就全部指向错的命令——
# 那不是排版问题，是把人引到一个会改坏东西的动作上（"安装 / 修复"指到"一键恢复"）。
# 靠人记"改了菜单要全局搜一遍数字"是不可靠的：数字在中文句子里，搜 2 会撞上别的 2。
#
# 按 Switch 名字找，不按编号找：Switch 是稳定的语义标识，编号只是它的显示形式。
# 查不到时**大声失败**，不静默返回 0——静默返回 0 会渲染成"选 0（退出）"，
# 看着还挺像真的，而那正是最坏的一种误导。
function Get-MenuKey([string]$Switch) {
    foreach ($mi in $MenuItems) {
        if ($mi.Switch -eq $Switch) { return [string]$mi.Key }
    }
    throw ("菜单里没有 Switch 为 {0} 的项——提示文案用到了不存在的命令名" -f $Switch)
}

# 菜单项显示名，同样从那张表取。提示写"选 N（名字）"时，名字也一并派生：
# 只派生编号的话，菜单项一改名，屏幕上就剩一串光秃秃的编号，
# 用户还得回头翻菜单才知道那是干什么的——"选 1" 远不如"选 1（安装 / 修复）"能读。
function Get-MenuName([string]$Switch) {
    foreach ($mi in $MenuItems) {
        if ($mi.Switch -eq $Switch) { return [string]$mi.Name }
    }
    throw ("菜单里没有 Switch 为 {0} 的项——提示文案用到了不存在的命令名" -f $Switch)
}

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
# 渲染整张菜单（纯文本）。打印与测试共用内容，保证"表里有什么，屏幕就有什么"。
function Format-MenuText {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($r in (Get-MenuRenderedLines)) { [void]$out.Add($r.Text) }
    return ($out -join "`n")
}

function Show-MenuColored {
    foreach ($r in (Get-MenuRenderedLines)) {
        if ($r.Role -eq 'blank') { Write-Host ''; continue }
        foreach ($s in $r.Segments) { Write-Styled $s.Role $s.Text -NoNewline }
        Write-Host ''
    }
}

# 帮助正文的缩进。所有角色都在 2 格或更深，**没有一个是 0**：
# 标题贴到最左边时，屏幕上看起来像"这一行不属于任何结构"，而正文却缩进 2 格——
# 结果是标题比内容更靠外，读起来是内容在往里缩，整页重心散掉（实测用户第一眼就说"贴边"）。
# 现在标题与正文同级（都在 2 格），子项再往内一层：
#
#   标题        ← 2 格：与它下面的正文左边缘对齐
#   正文        ← 2 格
#     子项编号  ← 4 格：比正文深一层，表示"这是上面那句话的分项"
#         说明  ← 6 格：子项的补充，比子项再深一层
#       命令   ← 6 格：跟说明同一层，因为它解释的通常就是上一句
#     左列|右列 ← 4 格：表格行与子项同级
$HelpRoleIndent = @{
    'h'  = 2
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
    # ---- 空行由这里统一补，正文里不写 b ----
    #
    # 手写空行是"有的地方记得、有的地方忘了"，屏幕上就是一段挤一段松。这种不一致
    # 单看每一行都挑不出错，但整页读起来就是"没排好"——用户说不出来，只觉得别扭。
    # 所以改由结构决定，谁也不用记。规则三条：
    #
    #   一、标题上下各空一行。下面必须空：标题在给下面的内容起头，挤着就开始读很闷。
    #       上面必须空：每个标题因此成为独立一段，块与块自然分开。
    #       （第一个标题的上面不空，它紧接页头。）
    #   二、表格块（连续的 r/rc/m 行）前后各空一行，块内行与行之间不空。
    #       表格是嵌在正文里的另一类东西，两侧不留白会跟正文糊在一起；
    #       而块内逐行空行会把它拆成一格一段，那正是"散"的来源。
    #   三、**带说明的编号条目之间空一行**。判据是"这一条后面跟了它自己的说明或命令"：
    #       那种条目是"小标题 + 一段话"的结构，两条挤在一起会让人以为说明属于下一条。
    #       而**连续的编号条目**（每条只有一行、没有附属内容）之间**不空**——
    #       它们是一个并列的清单，逐条空行会把三件并列的事读成三件互不相干的事。
    #
    # 于是每个主题的骨架完全一样：标题、空行、内容、空行、标题……
    $isTable = { param($c) $c -and ($c.Code -eq 'r' -or $c.Code -eq 'rc' -or $c.Code -eq 'm') }
    # 条目（i）的"从属行"：它自己的说明（t2）、命令（c/rc/r）、警告（w）。
    # 这些都是"属于上一条"的内容，不该与条目平级。
    $isItemChild = { param($c) $c -and ($c.Code -eq 't2' -or $c.Code -eq 'c' -or $c.Code -eq 'rc' -or $c.Code -eq 'r' -or $c.Code -eq 'w') }
    # 一条目是否"带说明"：看它后面紧跟的那一行是不是从属行。
    $itemHasChild = {
        param($idx)
        if ($idx -ge $n - 1) { return $false }
        $nx = $parsed[$idx + 1]
        return (& $isItemChild $nx)
    }
    $spaced = @()
    $n = $parsed.Count
    for ($i = 0; $i -lt $n; $i++) {
        $cur = $parsed[$i]
        $next = if ($i -lt $n - 1) { $parsed[$i + 1] } else { $null }
        # 标题前 / 表格块开始前 / 带说明的条目之前要空
        if ($i -gt 0) {
            $prev = $parsed[$i - 1]
            $prevTbl = & $isTable $prev
            $curTbl = & $isTable $cur
            $needBlank = $false
            if ($cur.Code -eq 'h') { $needBlank = $true }
            elseif ($curTbl -and -not $prevTbl) { $needBlank = $true }
            # 编号条目之间：上一条带自己的说明（t2）或非表格命令（c）时，说明那一段结束了，
            # 新条目要另起一段。判据看**上一行是不是从属行**，而不是看上一行是不是 i——
            # 「2.」后面跟的是它的 t2，到「3.」时上一行是 t2 不是 i，按代码值比会漏掉，
            # 表现就是两条说明挤在一起、让人以为下面那句属于上一条。
            elseif ($cur.Code -eq 'i' -and (& $isItemChild $prev)) { $needBlank = $true }
            if ($needBlank) { $spaced += (Split-HelpLine 'b ') }
        }
        $spaced += $cur
        # 标题后 / 表格块结束后
        if ($cur.Code -eq 'h') {
            $spaced += (Split-HelpLine 'b ')
        } elseif ((& $isTable $cur) -and $next -and -not (& $isTable $next)) {
            $spaced += (Split-HelpLine 'b ')
        }
    }
    # 去掉连续空行与首尾空行：上面几条规则会在边界各补一次，重了就是两三个空行。
    $parsed = @()
    foreach ($r in $spaced) {
        if ($r.Code -eq 'b') {
            if ($parsed.Count -eq 0) { continue }
            if ($parsed[$parsed.Count - 1].Code -eq 'b') { continue }
        }
        $parsed += $r
    }
    while ($parsed.Count -gt 0 -and $parsed[$parsed.Count - 1].Code -eq 'b') {
        $parsed = @($parsed | Select-Object -First ($parsed.Count - 1))
    }
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
    # 项目地址在帮助里出现三处（关于、求助、反馈），只在这里取一次。
    # 唯一来源是 Get-ProjectUrls（从官网源的 Base 派生），换远端只改那一处。
    $proj = Get-ProjectUrls
    $HelpProjHome = $proj.Home
    $HelpProjIssue = $proj.Issues
    return @(
        @{
            Key = '1'; Title = '这是干什么用的'; Short = '用处'
            Lines = @(
                'h 它做什么',
                't 你的翻墙软件只管浏览器，不管终端里的 git、npm、curl。',
                't 这个工具补上这一段：翻墙软件一开，它们跟着能翻；一关，自动恢复。',
                't 你什么都不用记，也不用每次敲开关。',
                'b ',
                'h 它怎么知道你现在在翻墙',
                't 每 2 到 3 秒看一次，要同时满足三条才算：',
                'i 1. 你电脑上确实有程序开着一个口子（端口）在等连接；',
                'i 2. 那个口子确实是个翻墙代理，会按规矩回应；',
                'i 3. 它确实连得到外面，试 6 个端点（几个常用的检测网址）任意一个通就算。',
                't 三条全过才动手。所以你本机开着网页服务、开发服务器都不会被误认。',
                't 它不认品牌、不认程序名、不认端口号——那些只用来加快查找。',
                'h 它是谁做的、在哪',
                't 这是开源项目。代码、新版、问题反馈都在这一个地址：',
                ('i ' + $HelpProjHome)
            )
        },
        @{
            Key = '2'; Title = '装完之后要我做什么'; Short = '装完'
            Lines = @(
                'h 按窗口分三种情况，多半你属于第一种',
                'b ',
                'i 1. 装完之后才打开的窗口',
                't2 启动时读到的就是当前状态，什么都不用做。',
                'b ',
                'i 2. 装完之后打开的窗口，后来翻墙软件又开了或关了',
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
                't 每个程序只在启动那一刻读一次「该走哪个代理」，读完就固定了。',
                't 之后系统再改，已经在跑的窗口不会跟着变。',
                't 这个工具挑的时机是每次命令跑完、等你回到能打字的时候同步——',
                't 你本来就一直在敲命令，所以不用专门做什么。'
            )
        },
        @{
            Key = '3'; Title = '这个窗口不要翻墙 / 用公司的代理'; Short = '窗口'
            Lines = @(
                'h 一、让这个窗口一直不翻墙',
                'rc PowerShell|$env:ENVPROXY_TERM = ''off''',
                'rc Git Bash|export ENVPROXY_TERM=off',
                't 下次回到提示符才生效，别的窗口照旧跟着翻墙软件走。',
                't cmd 没这个开关，只能自己清 5 个变量（& 两边别留空格）：',
                ('rc cmd|set ' + ((@($ProxyVarNames) | ForEach-Object { $_ + '=' }) -join '&set ')),
                'w 别用 unset HTTP_PROXY：大写清不掉小写，curl 照样用代理。',
                'h 二、让这个窗口用公司的代理',
                't 公司代理和自动跟随只能选一个，先做第一节再设地址（反了会被盖掉）。',
                't 地址端口问公司 IT 要，不是翻墙软件那个（下面 A 换成它）：',
                'rc PowerShell|$env:HTTPS_PROXY = ''http://A:端口''',
                'rc Git Bash|export HTTPS_PROXY=http://A:端口',
                'rc cmd|set HTTPS_PROXY=http://A:端口',
                't 上面这条够 git、curl、npm 用。有程序还是不认，就再抄下面这条：',
                'rc PowerShell|$env:ALL_PROXY = ''http://A:端口''; $env:NODE_USE_ENV_PROXY = ''1''',
                'rc Git Bash|export ALL_PROXY=http://A:端口; export NODE_USE_ENV_PROXY=1',
                'rc cmd|set ALL_PROXY=http://A:端口&set NODE_USE_ENV_PROXY=1',
                'h 三、改回自动跟随',
                'rc PowerShell|Remove-Item Env:ENVPROXY_TERM',
                'rc Git Bash|unset ENVPROXY_TERM',
                'r cmd|重开一个窗口',
                't 清掉 ENVPROXY_TERM 就都撤回了。改回来公司地址会被盖掉——那是对的，',
                't 表示回到自动；地址没删，只是不用。'
            )
        },
        @{
            Key = '4'; Title = '某条命令不想翻墙'; Short = '命令行'
            Lines = @(
                'h 每个工具写法不一样，没有通用的一条命令',
                'h curl',
                'rc PowerShell|curl.exe --noproxy "*" https://example.com',
                'rc cmd|curl --noproxy "*" https://example.com',
                'rc Git Bash / Mac|curl --noproxy "*" https://example.com',
                't PowerShell 5.1 必须写 .exe（它把 curl 当别名，不写会报参数找不到）；',
                't cmd 和 PowerShell 7 里写不写都行。',
                'h git 和 npm',
                'rc 三个窗口一样|git -c http.proxy= -c https.proxy= clone 仓库地址',
                'rc 三个窗口一样|npm --noproxy=registry.npmjs.org install 包名',
                't git 等号后留空 = 这条不用代理；写别的值 = 改用那个代理。',
                'w npm 的 --noproxy 只认具体网址，写 * 没用也不报错，请求还是翻墙。',
                't 写成 --no-proxy 会被当成 --proxy=false，也不是不用代理。',
                'h wget（Windows 不自带，装过才有）',
                'rc Git Bash / Mac|wget --no-proxy https://example.com',
                'rc PowerShell|wget.exe --no-proxy https://example.com',
                'h docker',
                't 没有单条命令的写法，改 Docker 自己的设置（Settings 里的 Proxies）。',
                'h 这些参数是各工具自己的，不是这个工具提供的',
                't 不加时它们才读这个工具写进系统的代理。',
                't 想确认绕过去了：跑一下那条命令，能通就是绕过了。',
                't 反而连不上，把参数去掉再试一次，就分清是参数问题还是网络问题。'
            )
        },
        @{
            Key = '5'; Title = '某个程序还是翻不了墙'; Short = '软件'
            Lines = @(
                'h 有些程序不认系统设的代理',
                't 它们只在启动那一刻读一次「该走哪个代理」，之后怎么变都不理。',
                't 而它们多半是从桌面或任务栏点的，那一层拿不到这个工具设的值。',
                'h 解决办法：给它建一个能翻墙的图标',
                't 菜单选 5 进高级功能，再选 1。挑程序（或输入路径），选放哪，确认。',
                # @explain 「走代理」是图标名的后缀，帮助必须与桌面上的名字对上
                't 它会生成一个新图标，名字后面带「走代理」。以后点那个就能翻墙。',
                'b ',
                'h 注意三件事',
                't 程序已经开着的，点了不会换代理，必须先关掉再点。',
                't 微软商店装的应用（没有独立 exe 的那种）不支持。',
                't 新图标可以拖到任务栏固定；固定后删掉桌面那个不影响使用。',
                'b ',
                'h 翻墙软件换了端口之后',
                't 已经开着的程序还连着旧端口，会连不上。关掉重开就好。',
                't 出现这种情况时会自动弹一句提示，不用你盯着。',
                'b ',
                'h 固定入口是干什么的',
                't 有些程序会把你给的地址写进它自己的设置里，之后一直用那个。',
                't 翻墙软件一换端口它们就连不上，而你还得去它的设置里改一遍。',
                't 固定入口在本机开一个永不变的地址，程序只认这个，背后自动跟着翻墙软件走。',
                't 建图标时自动就用它，不用你做什么；它跟着监控一起跑，也没有开关要拨。',
                't 它没在工作也不要紧：图标会退回去读当前地址，照样能用。',
                't 想看它现在的状态：菜单选 5 再选 3，那一屏只看不改。',
                'b ',
                'h 不想要了',
                't 菜单选 5 再选 2，能看状态、逐个删。'
            )
        },
        @{
            Key = '6'; Title = '出问题了：怎么查、怎么报'; Short = '出问题'
            Lines = @(
                'h 先按这个顺序查，多数问题到第二步就好了',
                'b ',
                'i 1. 在出问题的窗口里敲下面这一条，看有没有地址',
                't2 有地址 = 设好了；空的 = 没设上，重开一个窗口试试。',
                'rc PowerShell|$env:HTTPS_PROXY',
                'rc cmd|set HTTPS_PROXY',
                'rc Git Bash|echo $HTTPS_PROXY',
                'b ',
                'i 2. 看菜单最上面那行写的什么',
                "t2 写「未运行」就选 $(Get-MenuKey 'Install')（$(Get-MenuName 'Install')）。",
                'i 3. 两个常见误会',
                't2 npm 只认 HTTPS_PROXY，不认 HTTP_PROXY；你自己清过它就不走了。',
                't2 「翻墙代理」有、「代理变量」无 = 翻墙软件在跑、这个工具被停了，不是坏了。',
                'h 还是不行：把问题报上去',
                "t 菜单选 $(Get-MenuKey 'Report')（$(Get-MenuName 'Report')）。它先问你四句话，再自动补上这台机器的情况，",
                't 存成一个文件、把路径复制好。你不用找日志，也不用敲命令。',
                't 然后把文件内容贴到这里（本项目只在这里收问题）：',
                ('i ' + $HelpProjIssue),
                'h 想彻底删掉它',
                "t 菜单选 $(Get-MenuKey 'Uninstall')（$(Get-MenuName 'Uninstall')）。会问你要不要留日志。",
                'h 不开菜单也能用（写脚本、远程连过来的时候）',
                'r 日常|-Install -Status -Stop -Uninstall -Update',
                'r 其它|-Help -Menu -Advanced -Report',
                'r 补充|-Yes 跳过确认  -Purge 连日志一起删  -RepairProfile 摘掉孤立标记'
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
    # 引导语与下面的清单之间空一行：不然"按你遇到的问题挑一条"会被读成清单的第一条。
    # 与帮助正文同一套规矩——标题/引导语负责起头，内容另起一段。
    $out += [pscustomobject]@{ Role = 'text'; Text = '  按你遇到的问题挑一条：'
                               Segments = @(@{ Role = 'text'; Text = '  按你遇到的问题挑一条：' }) }
    $out += [pscustomobject]@{ Role = 'blank'; Text = ''; Segments = @() }
    # 编号列宽按最大编号算，让标题那一列永远对齐：
    # 直接写两个空格时，编号 1 到 6 宽度相同看不出问题，但主题一多（10 以上）
    # 两位数编号会把那一行整体右推一格，清单就从"整齐一列"变成"参差的"。
    $keys = @(foreach ($t in (Get-HelpTopics)) { [string]$t.Key })
    $keyW = 1
    foreach ($k in $keys) { if ($k.Length -gt $keyW) { $keyW = $k.Length } }
    foreach ($t in (Get-HelpTopics)) {
        $num = ([string]$t.Key).PadLeft($keyW)
        $segs = @(
            @{ Role = 'cmd';   Text = ('  ' + $num) },
            @{ Role = 'value'; Text = ('   ' + $t.Title) }
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
        # 「查看状态」留在本进程里跑：它是实时刷新的，要能回到菜单；
        # 起子进程就回不来了（子进程退出后屏幕就停在最后一帧）。
        # 与 Mac 侧对 help 的处理同一理由——那边也是"要回菜单的留在本进程"。
        if ($item[0].Switch -eq "Status") {
            Show-StatusLive
            # 不清屏：Exit-Screen 已经把光标放到内容下方，菜单会自然接在后面画。
            # 清一次屏等于用户按完 0 屏幕先白一下——那正是"不要闪"要避免的事，
            # 只是从刷新中挪到了退出瞬间。
            $mode = "menu"
            continue
        }
        # 其余子进程跑完整开关：与入口开关走的是同一条路（含锁、确认、复检）。
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
