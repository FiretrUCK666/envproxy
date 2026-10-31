# ==============================================================================
#  ops.ps1 — 编排层：安装、卸载、日常操作的编排，含过程叙述
#
#  它做两件事：按顺序调用别的层；把「每一步做成没做成」讲给使用者听
#  （`[1/4]` 那几行）。**判定与统计不在这里**——那些在 probe / env / doctor 层。
#
#  但文案确实在这里，因为它与调用顺序长在一起：第 3 步失败了才说第 3 步的话。
#  把这些话搬到 pages 层会让"哪一步失败"变成要跨函数传的参数，比现在更难读。
#
#  状态页与版本显示住在 pages 层，菜单与帮助住在 help 层：
#  它们各有各的变更原因（状态页因要说清而变化、菜单帮助因文案变），
#  混在一个文件里会让改一处时碰到另外两处。
# ==============================================================================


# ------------------------------------------------------------------------------
# 7. 子命令实现
# ------------------------------------------------------------------------------
function Install-EnvProxy {
    Write-Styled 'title' "======== EnvProxy 安装 ========"
    # 四步里哪几步真的做成了，要一路记到函数末尾：入口靠这个值决定退出码，
    # 脚本里写 `envproxy.ps1 -Install; if (Test-Succeeded) ...` 的人也靠它。
    # 原来这个函数没有返回值，于是"监控没起来""变量写不进去"这类明确的失败
    # 在退出码上是看不见的——用户只能靠肉眼读屏幕。与 mac 侧 _inst_ok 同一套语义。
    $instOk = 0
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
        $instOk = 1
        Write-Styled 'warn' "[1/4] 开机自启动：没写成。可能被杀软或组策略拦住了。"
        Write-Styled 'warn' "      请检查杀软拦截，或再打开一次菜单$(Get-MenuRef 'Install')；仍然不行就把它加进白名单。"
    }
    # 首次安装的判据必须在写路径记录**之前**取：写完这台机器上就有记录了，再判永远是"重装"。
    # 差别在于本机地址的代理变量算谁的——首次安装时它只可能是使用者自己的。
    # 判据走 base 层的 Test-HasInstallRecord：那里是这条事实的**唯一权威处**，
    # 内联一份的后果是两处演化时悄无声息地分叉，表现是"安装以为是首次、清理以为装过"，
    # 于是使用者自己设的本机代理被当成我们的残留删掉，而且没有快照可还原。
    $firstInstall = -not (Test-HasInstallRecord)
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
        $instOk = 1
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
        $instOk = 1
        Write-Styled 'warn' "[3/4] 环境变量：这一步没做成，原因见上面那行。其余步骤不受影响。"
    } elseif (-not $appliedOk) {
        # 写失败必须如实说，不能说"已校正"——用户会以为在走代理，实际是半套变量。
        $instOk = 1
        Write-Styled 'warn' "[3/4] 环境变量：没写进去。可能被杀软或组策略拦住了。"
        Write-Styled 'warn' "      再打开一次菜单$(Get-MenuRef 'Install')重试；仍然不行请反馈。"
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
            # 标记不成对 = 这一项没做成，退出码要如实反映（否则屏幕说失败、程序说成功）。
            $instOk = 1
            Write-Styled 'warn' "[4/4] 终端同步：配置文件里的标记不成对，未改动它（安全起见一个字节都没动）"
            Write-Styled 'dim' ("      " + $prof.Path)
        }
        default      {
            # 同上：写入失败必须让退出码跟着变。'installed'/'current'/'no-profile' 不置位——
            # 前两者是真做成了，'no-profile' 是取不到路径、新窗口仍然生效，不算失败。
            $instOk = 1
            Write-Styled 'warn' ("[4/4] 终端同步：写入失败（" + $prof.Reason + "）")
            Write-Styled 'dim' ("      " + $prof.Path)
        }
    }
    $polWarn = Get-ProfileExecutionPolicyWarning
    if ($polWarn) { Write-Styled 'warn' ("      " + $polWarn) }
    Start-Sleep -Seconds 1
    Write-Host ""
    # 安装走到了收尾这一步，说明覆盖早就成功、文件全是新的——那条
    # 「上次更新没有完成」的警报到此已经不成立，必须撤掉。
    # 不撤的后果是死循环：状态页说「选 1 重做一次即可」，用户照做、覆盖也真的成功了，
    # 可标记还在，屏幕上是同一句警告——一条自己都说错了怎么修的指引，比不提示更糟。
    # 与 mac 侧 ops.sh 在同一位置做同一件事（那边是 show_status 之前 rm -f）。
    try { if (Test-Item $UpdateInProgressFile) { Remove-ItemSafe $UpdateInProgressFile } } catch {}
    # 这里**不联网**：版本号取自监控写下的缓存（状态页只读、永不联网那条契约）。
    # 所以不能说"正在联网确认"——那是在描述一件不会发生的事，用户会以为
    # 网慢/被墙导致"检查失败"，而实际根本没发请求。
    Write-Styled 'dim' "正在看当前状态（版本号取自监控缓存，不联网）……"
    Show-Status
    Write-Host ""
    # 左边那一列用 Format-MenuCell 按最长的条目补齐，不靠手敲空格：
    # 手敲的话，改一个字就整列歪掉，而"歪一格"这种事只有人眼看得出来。
    # 有步骤没做成时不许说"装好了"——那是这台机器上最容易被当成"已经没事了"的一句话。
    if ($instOk -eq 0) {
        Write-Styled 'ok' "装好了。之后怎么用："
    } else {
        Write-Styled 'warn' "装是装了，但有步骤没做成（见上面带「失败 / 未能 / 没写成」的那几行）。"
        Write-Styled 'warn' "先把它们解决掉，再打开一次菜单$(Get-MenuRef 'Install')重跑；否则某些功能会时好时坏。"
        Write-Host ""
        Write-Styled 'dim' "之后怎么用："
    }
    # 每一行三格：左列标签 / 右列的说明 / 右列里那段能照抄的命令（没有就留空）。
    # 命令单独列一格、而不是靠正则从整行里认出来——认形状会错：
    # "在它里面执行  $env:ENVPROXY_TERM = 'off'" 开头不是命令，
    # 整行就被判成说明（暗），用户看不出哪一段能复制。这正是配色坏过的老原因。
    $tipRows = @(
        @('新开的终端 / 程序', '自动就是对的，什么都不用做。', ''),
        @('一直开着的窗口', '敲一下回车就跟上（cmd 窗口只能重开）。', ''),
        @('装之前就开着的窗口', '重开一个，或者手动加载一次', ''),
        @('', "菜单$(Get-MenuRef 'Help')第 2 条，各种终端都有现成命令。", ''),
        @('想让某个窗口一直不翻墙', '在它里面执行', "`$env:ENVPROXY_TERM = 'off'"),
        @('改回跟着翻墙软件走', '在它里面执行', 'Remove-Item Env:ENVPROXY_TERM'),
        @('忘了怎么用', "菜单$(Get-MenuRef 'Help')。", '')
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
    # 退出码如实反映这次安装成没成：入口靠它，脚本里也靠它。
    # 不能靠"最后一条命令"隐式决定——最后一条是 Write-Host，永远是成功。
    #
    # 只返回一个整数，不许让它变成数组：PowerShell 的函数会把**所有未被接住的输出**
    # 一起返回，将来这里谁加一行裸调用（不是 Write-Host、也没赋值给变量），
    # 返回值就成了 [那段输出, 0] 这样的数组，而 `exit $数组` 会被压成 0——
    # 于是"装失败"静默变成"成功"。用 Out-Null 包住整条调用链，把这条缝隙焊死。
    return [int]$instOk
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
        #
        # **必须显式 return 1**：裸 return 返回 $null，而入口写的是
        # `exit ([int](...)[-1])` 与 `[int]$code`——[int]$null 等于 0。
        # 于是屏幕上打「什么都不会做」，退出码却是成功，脚本里那句
        # `envproxy.ps1 -Uninstall; if ($?)` 会当成卸干净了。
        # 同一函数里 restore_prev_env 失败那条分支就是这么修的（见下面 return 1），
        # mac 侧 ops.sh 的同一分支也是。三处必须同形。
        Write-Styled 'warn' "这里没法问你要不要卸载（没有可交互的控制台），所以不会动你的代理设置与安装文件。"
        Write-Styled 'dim' "  真的要卸载，请双击 打开菜单.cmd $(Get-MenuRef 'Uninstall')；"
        Write-Styled 'dim' "  或者确认无误后加 -Yes：envproxy.ps1 -Uninstall -Yes"
        # 拒绝执行是对的（问不到人就不能替使用者答应），但**自启动记录属于清理自己的残留**，
        # 不需要征得同意：留着它，每次登录 Windows 都会失败一次，而那时工具已经卸载、
        # 再没有任何东西会来修它。代理变量与安装区那两样才需要人点头。
        Remove-AutoRun
        return 1
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
        Write-Styled 'warn' "        再点一次菜单$(Get-MenuRef 'Uninstall')收尾。"
        # 必须显式返回 1：裸 return 返回 $null，而入口写的是 `exit ([int](...)[-1])`，
        # [int]$null 等于 0——屏幕上打"[未完成]"，退出码却是成功。
        # 这正是"用户原设置没还原、备份还留着"那种最需要人动手的情形，报成功最贵：
        # 脚本里的 `-Uninstall; if ($?) { 删备份 }` 会把唯一一份备份也删掉。
        # mac 侧同一分支写的就是 return 1（ops.sh 里 restore_prev_env 失败那条），两侧必须同形。
        return 1
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
        # 网络救援动手前留下的原样。不删的后果与 state.snapshot 同类：
        # 重装后没有任何组件会用它，但它是使用者当时的系统代理设置副本——
        # 一份没人管理、也没人知道该不该删的配置留在盘上，本身就不该发生。
        Remove-ItemSafe (Get-SysProxyBackupPath)
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
        Write-Styled 'warn' "        再打开菜单$(Get-MenuRef 'Uninstall')试一次；还不行就照上面列出的位置手动删。"
        # 退出码必须跟着结论走：只打印"[未完成]"而返回成功，
        # 脚本里的"卸载成功就删备份"之类判断就会成立——屏幕说没清完、退出码说成功了。
        return 1
    }
    return 0
}
