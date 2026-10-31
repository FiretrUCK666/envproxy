# ==============================================================================
#  pages.ps1 — 状态页层：把「现在什么情况」渲染成人能读的几行
#  **永不联网、永不写文件、永不提问**：版本号读监控写下的缓存，缓存旧了就如实说
#  「几小时前的记录」，缓存没有就说清「没法确认」并指向更新入口。
#
#  两份渲染器（实时帧 Format-StatusLines 与静态页 Show-StatusSnapshot）必须同源：
#  同一份 $st、同一个 Get-StatusProblems。内容一旦不一致，自检里有断言比对行数。
# ==============================================================================


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
        & $line "  打开菜单选 $(Get-MenuRef 'Install')重做一次即可。" 'dim'
    }
    if ($st.SysProxy) {
        # 两种残留的症状真的不同，不能混成一句：
        #   manual 手动代理指向死端口 —— 浏览器打不开任何网页（真断网）
        #   pac    设置脚本指向死端口 —— 能上网，但每次开网页先卡几秒
        # 说成同一句话，前者会被当成小毛病、后者会被当成彻底坏了。
        $spText = if ($st.SysProxy.Kind -eq 'residue-slowing') {
            '有个设置脚本指向已经关掉的程序（网页能开，但每次要等几秒）'
        } else {
            '指向本机一个已经关掉的程序（浏览器会打不开网页）'
        }
        & $row $StatusLabels.SysProxy ($spText + '。不是本工具写的。') 'warn'
        & $line ('  这一项可以自己修：菜单选 ' + (Get-MenuKey 'Advanced') + '（' + (Get-MenuName 'Advanced') + '），再选网络救援。') 'dim'
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
            return @{ Text = ('状态未知（' + $State + '）'); Hint = "打开菜单选 $(Get-MenuRef 'Install')重写一次。"; Bad = $true }
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

    # 网络体检：报告里最该有的一节。
    # 用户报「上不了网」的时候，作者第一件事就是想确认「是不是浏览器被指到了死端口」——
    # 没有这一节，得靠来回追问三四轮。判据本来就是现成的（doctor 层），
    # 顺手写进来，提问的人不用另外描述。
    & $rule '网络体检（浏览器那一侧）'
    try {
        $docLayers = @(Get-SystemProxyLayers)
        if ($docLayers.Count -eq 0) {
            & $add '  没有设任何浏览器代理（干净直连）。'
        } else {
            foreach ($dl in $docLayers) {
                $flag = if (Test-SysProxyFixable $dl.Kind) { '【可修】' }
                        elseif ($dl.Kind -eq $SysProxyKinds.Alive) { '（正在用）' }
                        elseif ($dl.Kind -eq $SysProxyKinds.Managed) { '（被管理员锁定）' }
                        else { '（不是本机的，未动）' }
                & $add ('  ' + $dl.Layer + '  ' + $dl.Url + '  -> ' + $dl.Kind + ' ' + $flag)
            }
        }
        $fixCount = @($docLayers | Where-Object { Test-SysProxyFixable $_.Kind }).Count
        & $add ('  这一层有没有问题：' + $(if ($fixCount -gt 0) { '有' } else { '没有' }))
    } catch {
        & $add ('  （取网络体检结论时出错：' + $_.Exception.Message + '）')
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
        Write-Styled 'dim' "  可以先把菜单选 $(Get-MenuRef 'Status')的截图发给对方。"
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
        # 监控在"代理在跑"那一轮顺手问过的握手结论。空 = 不知道（老版本快照或那一轮没采），
        # 判据那里按"不报"处理——**不知道绝不等于没问题**。
        $st.NodeHandshake = [string]$st.Snapshot.NodeHandshake
    } else {
        # 注入的地址由这里读好再传进去：Get-InUseProxyPort 只管探测，
        # 不该反过来去调 env 层的读值函数（那会让 probe 依赖 env、env 又依赖 probe）。
        $injected = ''
        try { $injected = [string](Get-EnvProxyValue) } catch { $injected = '' }
        $st.Port = Get-InUseProxyPort -FullScan:$true -InjectedUrl $injected
        $st.PortUnknown = [bool]$script:PortEnumerationFailed
        try { $st.PortEnumerationReason = [string]$script:PortEnumerationReason } catch { $st.PortEnumerationReason = '' }
        # 没读到快照就没有这两个结论：留空串，不许假设成"一致 / 成功"。
        $st.VarsMatch = ''
        $st.ApplyResult = ''
        $st.NodeHandshake = ''
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
    # 若它指向本机死端口，浏览器全挂而终端正常——提醒一句，绝不动它（动它是「网络救援」的活）。
    #
    # 判据**只有一处实现**：doctor 层的 Get-SystemProxyLayers + Get-SystemProxyVerdict。
    # 这里原来内联了一小段（只认 ProxyEnable + 127.0.0.1 + 端口死活），
    # 与 doctor 各写一套必然分叉——那个版本还看不见 PAC 残留、也不认 ::1 与 localhost，
    # 于是「浏览器每次开网页先等几秒」这种症状在状态页上完全隐形。
    # -Quick 只查两层、超时 300 毫秒：状态页每 2 秒刷一次，全量档会把刷新拖垮。
    $st.SysProxy = $null
    try {
        $spLayers = @(Get-SystemProxyLayers -Quick)
        $spBad = @($spLayers | Where-Object { Test-SysProxyFixable $_.Kind })
        if ($spBad.Count -gt 0) {
            # 只报第一个：状态页那一行是一句话，列一长串会读不下去。
            # 详细的几项留给「网络救援」那一屏。
            $st.SysProxy = @{ Server = $spBad[0].Url; Port = $spBad[0].Port; Kind = $spBad[0].Kind; Count = $spBad.Count }
        }
    } catch {}
    # 上次更新是否中途死了：这个标记只有断电/被杀才会留下。
    # 那种情况下入口通常还能起来、启动自检全绿，但安装区可能新旧混合，
    # 表现为某些功能静默失效——所以必须主动说出来。
    $st.UpdateInProgress = Test-Item $UpdateInProgressFile
    # 这台机器上到底装过没装过。判据是安装时写下的路径记录——它只在安装时写、卸载时删。
    # 用途是避免把"从没装过"说成"崩溃/被结束任务"：后者是故障语气，
    # 而首次打开的人看到的应该是"还没装，按 1 就好"，不是"你的东西坏了"。
    # 与安装侧同一个判据（base.ps1 的 Test-HasInstallRecord）：内联一份就是第二个真相。
    $st.NeverInstalled = -not (Test-HasInstallRecord)
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
    # 代理在跑、端口也活着，但它连不出去——多半是节点问题，不是设置坏了。
    # 只在**拿到握手证据**时才说（空 = 不知道），否则就是凭猜给用户指方向。
    if ($st.NodeHandshake -eq 'upstream-fail') {
        $problems += "代理在跑，但它连不上外面（多半是节点问题，换个节点试试）"
    }
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
        Write-Styled 'dim' "还没开始用。打开菜单选 $(Get-MenuRef 'Install')就能装上。"
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
                Write-Styled 'dim' "  打开菜单选 $(Get-MenuRef 'Install')可以一起修好。"
            }
        } elseif ($st.NeverInstalled) {
            # 从没装过：这不是问题，是起点。用"崩溃/被结束任务"描述它，
            # 第一次打开的人会以为自己的机器出了事（"我明明没装过"）。
            Write-Styled 'dim' "  （还没装过。装上之后它会自己常驻，不用你管）"
            Write-Styled 'dim' "  打开菜单选 $(Get-MenuRef 'Install')开始使用。"
        } else {
            Write-Styled 'warn' "  （不是点了停止，是进程不在了：可能被结束任务关掉，或崩溃）"
            Write-Styled 'dim' "  打开菜单选 $(Get-MenuRef 'Install')可以让它重新跑起来。"
        }
    }
    if (-not $st.AutoRunOk) {
        if ($st.AutoRunRaw) {
            Write-StatusRow $StatusLabels.AutoRun '记录还在，但启动文件已不存在（登录时不会启动）' 'warn'
            Write-Styled 'dim' ("  记录指向：{0}" -f $(if ($st.AutoRunLauncher) { $st.AutoRunLauncher } else { $st.AutoRunRaw }))
        } else {
            Write-StatusRow $StatusLabels.AutoRun '未启用' 'warn'
        }
        Write-Styled 'dim' "  打开菜单选 $(Get-MenuRef 'Install')可以重建。"
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
        Write-Styled 'dim' "  多半是别的工具改写成了半个地址。选 $(Get-MenuRef 'Install')会按当前代理重写一遍。"
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
            Write-Styled 'dim' "  监控在跑的话几秒内会自己跟过去；想立刻跟上就选 $(Get-MenuRef 'Install')。"
        } elseif (-not $st.Port) {
            # 代理根本没在跑：没有可跟的目标，那就是该清掉
            Write-Styled 'dim' '  翻墙代理现在没在跑，所以这个地址已经没用了。'
            Write-Styled 'dim' "  监控在跑的话几秒内会把它清掉；想立刻清掉就选 $(Get-MenuRef 'Install')。"
        } else {
            # 端口解析不出来（极少见），只给通用说法，不编具体原因
            Write-Styled 'dim' '  这个地址已经连不上了（多半是刚换过端口）。'
            Write-Styled 'dim' "  监控在跑的话几秒内会自己跟上；想立刻跟上就选 $(Get-MenuRef 'Install')。"
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
        Write-Styled 'dim' "  打开菜单选 $(Get-MenuRef 'Install')重做一次即可。"
    }
    if ($st.SysProxy) {
        # 措辞与实时帧逐字相同（两版是同一屏的两种刷新方式），见 Format-StatusLines。
        $spText2 = if ($st.SysProxy.Kind -eq 'residue-slowing') {
            '有个设置脚本指向已经关掉的程序（网页能开，但每次要等几秒）'
        } else {
            '指向本机一个已经关掉的程序（浏览器会打不开网页）'
        }
        Write-StatusRow $StatusLabels.SysProxy ($spText2 + '。不是本工具写的。') 'warn'
        # 这一行是"怎么处理"的说明，与它上面那条结论不该同级；
        # 都是 warn 会让整段看起来像两个错误，实际是"一个问题 + 一条办法"。mac 侧本来就是 dim。
        Write-Styled 'dim' ('  这一项可以自己修：菜单选 ' + (Get-MenuKey 'Advanced') + '（' + (Get-MenuName 'Advanced') + '），再选网络救援。')
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
        $state = "可打开菜单选 $(Get-MenuRef 'Update')升级"; $role = 'warn'
    } elseif ((Compare-Versions $localVer $remote.Version) -gt 0) {
        $state = "本地版本比最新发布版新"; $role = 'dim'
    } elseif ((Compare-Versions $remote.Version $localVer) -gt 0) {
        $state = ("发现新版 {0}，选 $(Get-MenuRef 'Update')即可升级" -f $remote.Tag); $role = 'warn'
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
    # 不在这里自己判 IsOutputRedirected：base 层 Test-CanDrawScreen / Get-ConsoleWidth
    # 是"这个控制台能不能画屏、有多宽"的唯一判据，散着判必然漂移（base.ps1 里那句
    # "已经有四处、散着判必然漂移"说的就是这件事）。用 Get-ConsoleWidth，
    # 它在非终端下返回 0，这里再兜到下面的最小值。
    try { $cw = Get-ConsoleWidth; if ($cw -gt 0) { $logW = $cw - 2 } } catch {}
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
