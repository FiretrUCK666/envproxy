# ==============================================================================
#  report.ps1 — 问题报告：问几个问题，把状态、体检、日志、快照拼成一份文件
#
#  为什么单独一层：它是**唯一会写文件、唯一会向用户提问**的代码。
#  状态页的招牌契约是「只读、不问」（AGENTS.md 写明，唯一例外就是这一层），
#  两者混在一个文件里时，那条契约就只剩一句注释在守——而注释不会拦人。
#  拆开之后，"这个文件会不会动用户的磁盘"看一眼文件名就有答案。
#
#  依赖方向：base <- screen << pages <- report。报告要复用状态页的渲染，
#  所以它在 pages 之后加载；反过来 pages 不知道 report 存在。
# ==============================================================================


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
    Write-Styled 'title' (Format-TitleRule '问题反馈')
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
            # 标题两版已经统一（都是不带「（实时刷新）」的那句），这里不再改写。
            & $add $plain
        }
    } catch {
        & $add ('（取状态时出错：' + $_.Exception.Message + '）')
    }
    & $add ''

    # 网络体检：报告里最该有的一节。
    # 用户报「上不了网」的时候，作者第一件事就是想确认「是不是哪里被指到了死端口」——
    # 没有这一节，得靠来回追问三四轮。判据本来就是现成的（检查器层），
    # 顺手写进来，提问的人不用另外描述。
    #
    # **遍历全部检查器，不点名任何一层**：加一层检查，这一节自动多几行。
    # 报告是给排查的人看的，标记可以直白写内部语义。
    & $rule '网络体检（全部检查器）'
    try {
        $findings = @(Invoke-DoctorCheck)
        if ($findings.Count -eq 0) {
            & $add '  各项都没发现问题。'
        } else {
            foreach ($fd in $findings) {
                # unreadable 单独一档：它没有地址、也不参与判断，
                # 落进「不是本机的，未动」会把「探测失败」说成「别人的设置」。
                $flag = if (Test-FindingFixable $fd.Kind) { '【可修】' }
                        elseif ($fd.Kind -eq $FindingKinds.Alive) { '（正在用）' }
                        elseif ($fd.Kind -eq $FindingKinds.Managed) { '（被管理员锁定）' }
                        elseif ($fd.Kind -eq $FindingKinds.Unreadable) { '（这一项没读到）' }
                        else { '（不是本机的，未动）' }
                $where = if ($fd.Where) { [string]$fd.Where } else { [string]$fd.Id }
                $val = if ($fd.Value) { [string]$fd.Value } else { '（无地址）' }
                $extra = if ($fd.Reason) { '  ' + [string]$fd.Reason } else { '' }
                & $add ('  ' + $where + '  ' + $val + '  -> ' + $fd.Kind + ' ' + $flag + $extra)
                # 证据只在**端口活着**或需要解释时才有内容，且它只进报告、不参与授权。
                if ($fd.Evidence) { & $add ('      证据：' + [string]$fd.Evidence) }
            }
        }
        $fixCount = @($findings | Where-Object { Test-FindingFixable $_.Kind }).Count
        & $add ('  有没有可以修的残留：' + $(if ($fixCount -gt 0) { '有（' + $fixCount + ' 项）' } else { '没有' }))
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
                & $add ('  注意：快照是旧进程 ' + $sn.Pid + ' 写的，现在跑的是 ' + $livePid + '。' + (Get-MenuRef 'Install') + '可重启后台程序。')
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
        Write-Styled 'dim' "  可以先把菜单$(Get-MenuRef 'Status')的截图发给对方。"
        # 退出码是这条命令唯一能被程序读懂的结论，说"成功"而实际失败是谎报。
        # 与 mac 侧同一套语义（那边 report 分支 return 1）。AGENTS 规定：1 = 失败。
        $script:ReportExitCode = 1
        return
    }

    Write-Styled 'title' (Format-TitleRule '报告已生成')
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
