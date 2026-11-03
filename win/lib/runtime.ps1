# ==============================================================================
#  runtime.ps1 — 运行时层：日志、监控进程管理、监控主循环、自启动与定位器、
#                代理地址变化时的提醒、状态快照（$MonitorDir、状态文件、弹窗都在这一层）
#  路径常量依赖入口先设好的 $ScriptDir 与 $ScriptPath；本层不得自行推算脚本目录或入口路径。
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
# 下面三个注册表路径的子键声明在 base 层（$ScriptPathRegSubKey / $PrevEnvSubKey /
# $OwnedRegSubKey），这里按需现算，不另抄一份。
#   路径记录：定位器据此找到脚本现在的位置
#   用户原值快照：安装时记下被覆盖前的用户级代理变量，卸载时按快照还原；
#                 与路径记录是父子关系——卸载清注册表键时连同删掉，不留痕迹
#   我们写下的值（变量名 -> 值）：终端同步的钩子据此判断"当前值是不是我们的"。
#                 与 Mac 侧 ~/.envproxy/owned.env 同义：没有这份记录就一个都不许删。
# 安装目录与 terminal.env 的目录是同一个（都在 %LOCALAPPDATA%\EnvProxy），
# 所以只能有一处声明：Get-InstallDir 在 base 层，已处理"CI 在 Linux 上点源"的兜底。
$LauncherDir      = Get-InstallDir
$LauncherPath     = Join-Path $LauncherDir "launcher.ps1"

# 登录定位器的正文住在 win\locator.ps1 这个**真实文件**里，不再内嵌成字符串。
#
# 为什么必须是真实文件而不是内嵌字符串（here-string）：字符串里的代码对解析器不可见，
# 门禁 2（语法检查）与门禁 3（编码红线）都看不见它，测试也只验证"启动命令指向这个文件"。
# 实测在那种字符串里删掉一个右花括号：门禁 2 仍然绿、单元测试仍然 ALL PASS、
# 自愈判据仍然报"已是最新"——错误会一路绿灯发到用户机器上，表现为"开机自启静默失效"，
# 而且不报任何错。是真实文件，门禁 1/2/3/9 就自动覆盖它，改坏了当场就红。
#
# 返回模板正文；模板缺失时抛错而不是返回空串——写一份空定位器等于把开机自启静默关掉。
function Get-LauncherContent {
    $src = Join-Path $ScriptDir "locator.ps1"
    if (-not (Test-Item $src)) {
        throw ("找不到登录定位器模板：{0}（安装包不完整，请重新下载覆盖）" -f $src)
    }
    # 必须剥掉源文件的 BOM。Read-Text 是用 UTF8 解码的，它**不会**自动去掉 BOM，
    # 而写入端（WriteAllText 带 UTF8Encoding($true)）会再加一个——
    # 结果装出来的 launcher.ps1 是 EF BB BF EF BB BF 开头，PowerShell 只剥一个，
    # 剩下的 U+FEFF 跟行首的 # 拼成一个"命令名"，5.1 直接报
    # The term '# ' is not recognized，开机自启静默失效。
    $body = (Read-Text $src)
    if ($body.Length -gt 0 -and $body[0] -eq [char]0xFEFF) { $body = $body.Substring(1) }
    return $body
}

# 把定位器写到固定位置，并把 Run 键指向定位器
function Get-LauncherCommand {
    # 定位器命令行是同一事实的三处用法（写入、自愈比对、安装后复检）的唯一来源。
    return ('powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $LauncherPath)
}

function Set-AutoRun {
    New-Item -Path $LauncherDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    [System.IO.File]::WriteAllText($LauncherPath, (Get-LauncherContent), (New-Object System.Text.UTF8Encoding($true)))
    Set-ItemProperty -Path $RunKeyPath -Name $RunKeyName -Value (Get-LauncherCommand) -ErrorAction Stop
}

function Remove-AutoRun {
    Remove-ItemProperty -Path $RunKeyPath -Name $RunKeyName -ErrorAction SilentlyContinue
}

# 记录"脚本当前路径"（监控启动时写入；定位器靠它快速找到脚本）
# 记的必须是入口脚本：定位器会直接拿这个值去 -File 启动，记成库文件等于记了个跑不起来的文件。
function Update-ScriptPathRecord {
    # 只在键不存在时才建。注册表上的 New-Item -Force 会把这个键**清空重建**，
    # 连带删掉 Backup 快照——监控每次启动都调本函数，快照会在装上后一两秒内就没了，
    # 卸载时便无值可还原，使用者手设的代理配置凭空消失。
    if (-not (Test-RegKey (Get-ScriptPathRegKeyPath))) {
        New-Item -Path (Get-ScriptPathRegKeyPath) -Force -ErrorAction SilentlyContinue | Out-Null
    }
    Set-ItemProperty -Path (Get-ScriptPathRegKeyPath) -Name "ScriptPath" -Value $ScriptPath -ErrorAction SilentlyContinue
}

# 自启动自愈：让固定位置的自启动配置**与当前代码生成的内容一致**——不只是"存在"。
# 判据是内容而非存在，理由是升级路径：改完脚本若没走"安装"，固定位置里留着的仍是
# 旧定位器（搜索算法、参数改了都不生效），旧的 Run 值也可能指向被删掉的路径。
# 每次自查 = 让系统状态收敛到当前代码，不依赖用户记得重装。
function Test-LauncherCurrent {
    try {
        if (-not (Test-Item $LauncherPath)) { return $false }
        # BOM 必须单独校验：Read-Text 会自动识别并剥掉 BOM，所以文本一致并不能证明
        # BOM 还在。BOM 一丢（外部编辑器另存、杀软改文件、备份还原工具），
        # PowerShell 5.1 会按 ANSI 读这个文件，中文注释撑破语法 -> 登录时启动项
        # 静默失效，而「内容比对」却说一切正常。三字节单独断言一次。
        $bytes = [System.IO.File]::ReadAllBytes($LauncherPath)
        if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) { return $false }
        # 行尾与首尾空白不比：落盘的行尾与 win/locator.ps1 源码的行尾
        # 不必逐字节相同，比"生成出来的代码"是否一致就够了。
        $want = (Get-LauncherContent) -replace "`r`n", "`n"
        $have = (Read-Text $LauncherPath) -replace "`r`n", "`n"
        return ($have.Trim() -eq $want.Trim())
    } catch { return $false }
}

# 版本号缓存：监控每 30 轮（约 60–90 秒）刷新一次，状态页只读。
#
# 为什么要缓存：状态页原来自己调 Get-RemoteVersion，那是真实网络请求（先 API 后 Web，
# 各 8 秒超时，限流时还会换出口重试）。离线、限流、走白名单网络的人，每次点"查看状态"
# 都在等一个注定失败的请求——而用户对"点一下要等 10 秒"的归因通常是"这工具很慢"。
# 写缓存的是监控（它本来就写文件），状态显示"永不写文件、永不提问"这条契约一个字不动：
# **写的人换了，不是多了一个**。
#
# 格式两行：版本号、写入时刻（ISO 8601）。带时间戳是因为陈旧数据必须能被认出——
# 只报"已是最新"而不知道这个结论有多旧，比不报更糟。
function Write-VersionCache {
    $r = Get-RemoteVersion
    if (-not $r) { return }   # 查不到就保持上次的值，不写「未知」把好数据冲掉
    $dir = Split-Path -Parent $VersionCacheFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
    $stamp = (Get-Date).ToString("o", [System.Globalization.CultureInfo]::InvariantCulture)
    try { Write-Text -Path $VersionCacheFile -Text ($r.Version + "`n" + $stamp + "`n") } catch {}
}

# 读版本缓存。没有或读不出来返回 $null（调用方据此说"还没查过"）。
function Read-VersionCache {
    if (-not (Test-Item $VersionCacheFile)) { return $null }
    try {
        $lines = [System.IO.File]::ReadAllLines($VersionCacheFile, [System.Text.Encoding]::UTF8)
        if ($lines.Count -lt 2) { return $null }
        $ver = $lines[0].Trim()
        if (-not $ver) { return $null }
        $at = [datetime]::MinValue
        try { $at = [datetime]::Parse($lines[1].Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch {}
        return @{ Version = $ver; At = $at; AgeMinutes = [int]((Get-Date) - $at).TotalMinutes }
    } catch { return $null }
}


# ==============================================================================
#  状态快照：监控每轮把自己的结论写下来，状态页只读它。
#
#  为什么要这一层：状态页现在每次都要自己重新探测一遍，最坏情况（代理刚换端口、
#  变量指向的旧端口已死）要 2.7 秒——因为那时必须走全端口扫描。而监控每 2-3 秒
#  就在做同一件事，结论它早就有了，只是只写成了给人看的文本日志。
#
#  让监控把结论写成结构化的一份，状态页读它：一次 3 毫秒，而且两边永远同源
#  （不会出现"状态页说没代理、监控还在用 7078"这种自相矛盾）。
#
#  这与版本缓存是同一个手法，不违反「状态显示只读」：写的人还是监控，
#  状态页一个字节都不写。
# ==============================================================================

# 快照的字段表——唯一权威处。门禁 15 会拿它与 Mac 侧的 SNAPSHOT_KEYS 比对。
# 顺序即写入顺序；读的时候不依赖顺序（按 key 找），但缺任何一个键都算文件损坏。
$SnapshotKeys = @(
    'written'           # 本轮探测完成的时刻（UTC，秒精度，两侧都能解析的格式）
    'round'             # 探测层轮次计数，单调递增。判「这份数据有没有在推进」靠它，不靠时间
    'pid'               # 写它的监控进程
    'state'             # 当前确认状态：on:<端口> / off / 空（从未确认过）
    'prev_state'        # 上次翻转前的状态
    'pending_state'     # 正在去抖、尚未落定的候选状态
    'pending_count'     # 该候选已被连续确认的轮数
    'port_enumeration'  # ok / failed —— 本轮端口枚举成没成
    'port_reason'       # 枚举失败的原因（成功时为空）
    'vars_match'        # yes / no / unknown —— 变量是否与状态该有的样子一致
    'apply_result'      # ok / failed / unknown —— 本轮有没有动变量、动成功没
    'log_tail'          # 最近几条日志，用 \n 转义成字面量；状态页不必再读日志文件
)

# 快照判"新不新"的阈值（秒）。三档，各自有明确含义，不是随手拍的数。
#   ≤ 10 秒：新鲜，直接用；一轮 2-3 秒，容得下三次心跳缺失。
$SnapshotFreshSec = 10
#   ≤ 60 秒：可用，但屏幕上要标明"这是 N 秒前的判断"，并提示可能已不是现在的情况。
$SnapshotUsableSec = 60
#   > 240 秒（与 $HeartbeatMaxSec 同值）：不再当"当前状态"，退回实时探测。
#   同一个语义「超过这么久就认为监控不在了」，两处必须同值。
$SnapshotStaleSec = 240

# 把值里的换行转义掉，保证一行一个键值对、且切分点唯一。
function ConvertTo-SnapshotValue([string]$Text) {
    if ($null -eq $Text) { return '' }
    $s = [string]$Text
    # 换行编成 %0A（URL 风格百分号转义），百分号本身编成 %25 —— 先编百分号再编换行。
    # 为什么不用反斜杠：Windows 路径里全是反斜杠（C:\nodejs\npm），拿 \n 当换行标记
    # 就必须同时转义反斜杠本身，而两层转义在 PowerShell 字符串里极易写错——实测
    # 那样写往返不闭环，含 \n 的路径会被劈成两行，字段随之静默丢失。
    # 百分号转义只有一层，也不与路径里的字符冲突。
    $s = $s.Replace('%', '%25')
    $s = $s -replace "`r`n", '%0A'
    $s = $s -replace "`n", '%0A'
    $s = $s -replace "`r", '%0A'
    # 键值对以第一个 = 切分，所以值里的 = 无害；控制字符会破坏显示，一并去掉
    $s = $s -replace "[\x00-\x08\x0B\x0C\x0E-\x1F]", ''
    return $s
}

# 把转义过的值还原成原样。顺序与 ConvertTo 相反：先还原换行，再还原百分号。
#
# 不做"老格式（字面 \n）"的兼容：那需要把 \n 也当换行，而 Windows 路径里全是反斜杠，
# C:\nodejs\npm 会被劈成两行——这比它想解决的问题更糟。升级瞬间旧监控写下的那几份
# 快照会被判成"一行超长日志"，最多持续到监控重启（用户重跑一次安装即结束），
# 而状态页对读不懂的数据本来就会退回实时探测，不会说错话。
function ConvertFrom-SnapshotValue([string]$Text) {
    if (-not $Text) { return '' }
    $s = ([string]$Text).Replace('%0A', "`n")
    return $s.Replace('%25', '%')
}

# 写一份快照。所有字段由调用方算好传进来——这里不做任何判断，只负责落盘。
#
# 失败一律吞掉：监控的职责是管代理，写快照是附带。写不出来不能让监控停摆。
function Write-StateSnapshot {
    param(
        [string]$State,
        [string]$PrevState,
        [string]$PendingState,
        [int]$PendingCount,
        [string]$PortEnumeration,
        [string]$PortReason,
        [string]$VarsMatch,
        [string]$ApplyResult,
        [string]$NodeHandshake = ''
    )
    $lines = @()
    $lines += '# envproxy-snapshot 1'
    # 用 DateTimeOffset 而不是 DateTime：DateTime 在 ParseExact 带 AssumeUniversal 时
    # 仍可能给出 Kind=Local，于是同一个时刻被当成本地时间、年龄差出整整一个时区。
    # DateTimeOffset 明确带 Offset，写读两侧不会有歧义。
    $lines += 'written=' + ([DateTimeOffset]::UtcNow).ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    $round = 0
    try { if ($null -ne $script:Round) { $round = [int]$script:Round } } catch { $round = 0 }
    $lines += 'round=' + $round
    # 用 24340（PowerShell 自动变量，当前进程）；本地同名变量会遮蔽它，所以显式取一次
    $myPid = 0; try { $myPid = [int]$PID } catch { $myPid = 0 }
    $lines += 'pid=' + $myPid
    # 握手结论：只在**已经锁定端口**时才有值（那时端口是活的，握手不会等超时）。
    # 它回答「代理在，但它连不连得出去」——这一条决定了状态页要不要提示「是节点问题」。
    # 空串 = 这一轮没采（没有锁定端口），调用方必须当成「不知道」，不许当「没问题」。
    $lines += 'node_handshake=' + (ConvertTo-SnapshotValue $NodeHandshake)
    $lines += 'state=' + (ConvertTo-SnapshotValue $State)
    $lines += 'prev_state=' + (ConvertTo-SnapshotValue $PrevState)
    $lines += 'pending_state=' + (ConvertTo-SnapshotValue $PendingState)
    $lines += 'pending_count=' + $PendingCount
    $lines += 'port_enumeration=' + (ConvertTo-SnapshotValue $PortEnumeration)
    $lines += 'port_reason=' + (ConvertTo-SnapshotValue $PortReason)
    $lines += 'vars_match=' + (ConvertTo-SnapshotValue $VarsMatch)
    $lines += 'apply_result=' + (ConvertTo-SnapshotValue $ApplyResult)
    # 日志尾由这里自己取，调用方不必再读一遍文件
    $tail = ''
    try { $tail = [string](Get-LogTailText 4) } catch { $tail = '' }
    $lines += 'log_tail=' + (ConvertTo-SnapshotValue $tail)
    $text = ($lines -join "`n") + "`n"
    # 走 Write-Text：它做「同目录临时文件 + 整体替换」，是项目里唯一的原子写法。
    # 临时名是 "$Path.tmp$PID"，命中 package.ps1 的 *.tmp[0-9]* 清扫规则。
    try { Write-Text -Path $StateSnapshotFile -Text $text } catch {}
}

# 读快照。返回一个哈希表：
#   Status = 'ok' / 'none'（没有文件）/ 'unreadable'（读失败）/ 'damaged'（格式不对）
#   AgeSec = 距今秒数（拿不到为 $null）
#   Round / Pid / State / PrevState / PendingState / PendingCount /
#   PortEnumeration / PortReason / VarsMatch / ApplyResult / LogTail
#
# 关键：读失败、格式不对、缺键——一律判"读不出来"，绝不把空值当成"没有代理"。
# 这条与探测层「读不出来 ≠ 没有端口」是同一个判据。
function Read-StateSnapshot {
    $r = @{
        Status = 'none'; AgeSec = $null; Round = 0; Pid = 0
        State = ''; PrevState = ''; PendingState = ''; PendingCount = 0
        PortEnumeration = ''; PortReason = ''; VarsMatch = ''; ApplyResult = ''
        NodeHandshake = ''
        LogTail = ''; Reason = ''
    }
    if (-not (Test-Item $StateSnapshotFile)) { return $r }
    $text = ''
    try {
        # 用 FileShare.ReadWrite 打开：监控可能正在改名替换，不能因此读失败
        $fs = New-Object System.IO.FileStream($StateSnapshotFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            $text = $sr.ReadToEnd()
            $sr.Close()
        } finally { $fs.Close() }
    } catch {
        $r.Status = 'unreadable'
        $r.Reason = $_.Exception.Message
        return $r
    }
    $lines = @($text -split "`n")
    if ($lines.Count -lt 2 -or $lines[0].Trim() -ne '# envproxy-snapshot 1') {
        $r.Status = 'damaged'; $r.Reason = '首行格式标记不对'; return $r
    }
    $map = @{}
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $ln = $lines[$i]
        if (-not $ln) { continue }
        $eq = $ln.IndexOf('=')
        if ($eq -lt 1) { continue }
        $k = $ln.Substring(0, $eq)
        $v = $ln.Substring($eq + 1)
        $map[$k] = $v
    }
    # 缺任何一个键 = 这份文件不完整（写到一半被杀）。整份不用，绝不用半份。
    foreach ($k in $SnapshotKeys) {
        if (-not $map.ContainsKey($k)) {
            $r.Status = 'damaged'; $r.Reason = ('缺字段 ' + $k); return $r
        }
    }
    $r.Status = 'ok'
    $r.Round = 0
    $tmpInt = 0
    [void][int]::TryParse($map['round'], [ref]$tmpInt)
    $r.Round = $tmpInt
    $r.Pid = 0
    $tmpInt = 0
    [void][int]::TryParse($map['pid'], [ref]$tmpInt)
    $r.Pid = $tmpInt
    $r.State = ConvertFrom-SnapshotValue $map['state']
    $r.PrevState = ConvertFrom-SnapshotValue $map['prev_state']
    $r.PendingState = ConvertFrom-SnapshotValue $map['pending_state']
    $r.PendingCount = 0
    $tmpInt = 0
    [void][int]::TryParse($map['pending_count'], [ref]$tmpInt)
    $r.PendingCount = $tmpInt
    $r.PortEnumeration = ConvertFrom-SnapshotValue $map['port_enumeration']
    $r.PortReason = ConvertFrom-SnapshotValue $map['port_reason']
    $r.VarsMatch = ConvertFrom-SnapshotValue $map['vars_match']
    $r.ApplyResult = ConvertFrom-SnapshotValue $map['apply_result']
    # **可选字段**：它不在 $SnapshotKeys 里，因为老版本监控写不出它。
    # 放进去的话，升级瞬间那份旧快照会被判成「缺字段 = 损坏」，状态页会整段退回实时探测。
    # 读不到就是不知道——判据那里按「不报」处理，绝不假设成「没问题」。
    if ($map.ContainsKey('node_handshake')) { $r.NodeHandshake = ConvertFrom-SnapshotValue $map['node_handshake'] }
    $r.LogTail = ConvertFrom-SnapshotValue $map['log_tail']
    # 年龄：用墙上时钟（快照里的时刻本来就是墙上时钟）。为负说明系统时间被调过，
    # 那时不许当"刚写的"，判成过旧、让调用方退回实时探测。
    try {
        $t = [DateTimeOffset]::ParseExact($map['written'], 'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
        $r.AgeSec = [int](([DateTimeOffset]::UtcNow - $t).TotalSeconds)
    } catch {
        $r.Status = 'damaged'; $r.Reason = 'written 时间戳解析失败'; $r.AgeSec = $null
    }
    return $r
}

# 取日志最后 N 行（给快照用）。读不出来返回空串，不抛。
function Get-LogTailText([int]$Count = 4) {
    try {
        if (-not (Test-Item $LogFile)) { return '' }
        $all = @(Get-Content -LiteralPath $LogFile -Tail $Count -Encoding UTF8 -ErrorAction Stop)
        return ($all -join "`n")
    } catch { return '' }
}


function Repair-AutoRun {
    try {
        $expected = Get-LauncherCommand
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
# 3b. PowerShell 配置文件的终端同步（对应 Mac 侧的 shell hook）
# ------------------------------------------------------------------------------
# DIVERGE(Win): 机制与 Mac 侧必然不同，三处：
#   1) 挂载点——PowerShell 没有 precmd/PROMPT_COMMAND 那种官方钩子，只能改写 $PROFILE
#      并**包住 prompt 函数**；Mac 是在 rc 文件里 source 一个脚本、注册 precmd 钩子。
#   2) 状态来源——本侧每次回到提示符实时查注册表（HKCU\Environment 与
#      Software\EnvProxy\Owned）；Mac 侧读的是 ~/.envproxy/proxy.env 与 owned.env 两个文件。
#   3) 落点数量——本侧写 5.1 与 7 两个版本的 profile；Mac 写 4 个 rc（.zshenv/.zshrc/
#      存在的 .bash_profile/.bashrc）。
#   共同点（行为契约，两侧必须一致）：只对安装之后新启动的 shell 生效；只清"值仍等于
#   我们写下的那个"；钩子永不输出、永不打断用户的提示符。
# 为什么需要：环境变量只在进程启动那一刻从父进程复制，已经开着的 PowerShell 窗口
#   拿不到新值（WM_SETTINGCHANGE 广播对已运行的控制台进程无效）。唯一可靠的时机是
#   "每次回到提示符、准备执行下一条命令之前"——也就是 prompt 函数被调用时。
#
# 为什么挂 $PROFILE 而不是每次自己开窗口：
#   $PROFILE（CurrentUserCurrentHost）在四个变体里**最后执行**，能包住前面所有模块
#   （Oh My Posh / posh-git）定义的 prompt；且只需当前用户权限。绝不硬编码 Documents
#   路径——OneDrive 重定向会让它变，必须现场向 PowerShell 要。
#
# 三条硬约束（都在自检里钉住）：
#   1) prompt 里一旦抛异常，整个提示符渲染失败（官方文档：默认 prompt 只在自定义
#      prompt 出错时才出现）。所以同步逻辑必须整体 try/catch 包死。
#   2) 只写 5 个大写拼写。Windows 变量名大小写不敏感，补小写会制造跨进程重名
#      （.NET 宿主建表报 "same key has already been added"），这是项目已确立的红线。
#   3) 删除用 [NullString]::Value：.NET 9 起 $null 不再等于删除，会留一个空值变量。
#      本机 5.1 上两者等价，但代码要跨版本正确。
$ProfileBlockStart = '# >>> EnvProxy >>>'
$ProfileBlockEnd   = '# <<< EnvProxy <<<'
function Get-MonitorProcessFromPidFile {
    if (-not (Test-Item $PidFile)) { return $null }
    try {
        $pid2 = [int]((Read-Text $PidFile).Trim())
        if ($pid2 -ne $PID) {
            # 校验命令行确实是本脚本，防止 PID 被系统复用而误杀他人
            $w = Get-CimInstance Win32_Process -Filter "ProcessId=$pid2" -ErrorAction SilentlyContinue
            if ($w -and $w.CommandLine -match $MonitorCmdLinePattern) { return $w }
        }
    } catch {}
    return $null
}

# 判据二（兜底）：命令行特征。判"有没有监控在跑"用它——pid 文件缺失或陈旧但确实有监控时
# 靠它（手工启动、pid 文件被删、跨位置停止）；判"我刚启动的监控起来了吗"不能用它。
# 监控进程是否活着：不依赖 WMI 的第二条判据。
#
# 为什么需要它：身份判定原来只走 WMI（Get-CimInstance / Invoke-CimMethod）一条通道，
# 而"停止"和"卸载"完全依赖它。各类"系统优化/精简"工具会关掉 Windows Management
# Instrumentation，企业镜像、Ghost 装机盘也会，WMI 仓损坏同样会让它抛异常
# （Get-OwnMonitorProcesses 自己就 `catch { return @() }`）。通道一断，后果是三连击且全部静默：
#   1. -Stop 静默变成空操作 → 监控 2–3 秒后把变量重新注入，用户看到"停了又自己回来"；
#   2. -Uninstall 停不掉 → 后续照做删掉 Run 键，而活着的监控每 30 轮自愈把 Run 键和
#      launcher 重建回来（周期只有 60–90 秒，比人操作快）；
#   3. 卸载复检用的是同一个通道 → 屏幕上打印"[完成] 电脑已恢复到安装前的状态"。
# 也就是"卸载"这个最后的兜底手段会失效——比直接报错糟得多。
#
# 判据用 pid 文件里的 pid + Get-Process（进程快照 API，不是 WMI）。
#
# 这里**不**用"pid 文件的修改时间新不新"当心跳：监控只在启动时写一次 pid 文件
# （文件缺失时才补写），稳态下它的 mtime 会一直停在启动那一刻。拿它当新鲜度判据，
# 结果是监控正常运行几小时后这个判据恒为假——看起来"有兜底"，实际等于没有。
#
# 但光看"这个 pid 还活着"不够：pid 会被系统回收再分配。实测过——把 pid 文件改写成一个
# 无关进程的号（哪怕是 explorer），判据照样为真，于是状态页会报"监控运行中 (PID <别人的号>)"，
# 卸载复检也会认定"监控进程仍在"而报未完成。所以必须再核一次"这个进程跑的是不是本脚本"。
# 这一步用 Get-Process 的 CommandLine（不是 WMI/CIM，普通用户可读），
# 与本文件里 MonitorCmdLinePattern 同一套判据——**同一个判断不写两遍**。
function Test-MonitorAlive {
    # 心跳文件里记着「pid + 那个进程的启动时刻」。两条都要对得上才算活着：
    #   pid 对得上  → 大概率是它；
    #   启动时刻也对得上 → 一定是它（系统回收 pid 后新进程的启动时刻必然不同）。
    # 这样既不依赖 WMI，也不怕 pid 复用。
    if (Test-Item $HeartbeatFile) {
        try {
            $parts = @((Read-Text $HeartbeatFile).Trim() -split '\s+')
            $beatPid = 0
            [void][int]::TryParse($parts[0], [ref]$beatPid)
            if ($beatPid -gt 0 -and $beatPid -ne $PID) {
                $proc = Get-Process -Id $beatPid -ErrorAction SilentlyContinue
                if ($proc) {
                    if ($parts.Count -lt 2) { return $true }
                    $wantTicks = 0
                    if ([long]::TryParse($parts[1], [ref]$wantTicks) -and $wantTicks -gt 0) {
                        return ([long]$proc.StartTime.Ticks -eq $wantTicks)
                    }
                    return $true
                }
            }
        } catch {}
    }
    # 心跳还没写过（刚启动的头几秒）时靠 pid 文件 + Get-Process。
    # 这条单独用挡不住 pid 复用，所以只在心跳缺席时兜底——正常运行时心跳总在。
    if (Test-Item $PidFile) {
        try {
            $p = [int]((Read-Text $PidFile).Trim())
            if ($p -gt 0 -and $p -ne $PID) {
                if (Get-Process -Id $p -ErrorAction SilentlyContinue) { return $true }
            }
        } catch {}
    }
    return $false
}

# 「监控在不在、PID 多少」的**轻量**判据：只读 pid/心跳文件，绝不查进程表。
#
# 为什么需要单独一份：Get-MonitorProcess 为了拿"命令行"要调 Get-CimInstance，
# 实测 185 毫秒——而状态页每次刷新都要问"监控在不在"，2 秒一次就白烧约 9% 的 CPU。
# 状态页要的只是"在不在、PID 多少"，不需要命令行。
#
# 判据强度说清（这是它与 Get-MonitorProcess 的差别）：
#   心跳在 $HeartbeatMaxSec 内写过 -> 监控一定活着（它定期写，写不动就不会新）
#   心跳过期                   -> 说不清（可能真死了，也可能休眠刚醒）-> 返回 $null
# 它**不**用于"停止/卸载"这类会动别人进程的动作：那些必须走完整身份校验
# （命令行 + 启动时刻），认错进程的代价不对称。
function Get-MonitorProcessFast {
    # 心跳文件只证明「某个监控进程在 240 秒内写过它」，不证明**那个 pid 现在还活着**：
    # 强杀、崩溃、断电都留下一个新鲜的心跳。所以拿到 pid 之后必须核一次存在性。
    # 这里用 Get-Process -Id（单查，个位数毫秒），不是要 170 毫秒的 Get-CimInstance。
    try {
        if (-not (Test-Item $HeartbeatFile)) { return $null }
        $beatPid = 0
        $wantTicks = 0
        try {
            $parts = @((Read-Text $HeartbeatFile).Trim() -split '\s+')
            if ($parts.Count -ge 1) { [void][int]::TryParse($parts[0], [ref]$beatPid) }
            if ($parts.Count -ge 2) { [void][long]::TryParse($parts[1], [ref]$wantTicks) }
        } catch { return $null }
        if ($beatPid -le 0) { return $null }

        # 心跳的**年龄**也要看：只认 pid 与启动时刻，等于"这个进程还活着"，
        # 但那不是我们要回答的问题——我们要的是"监控还在正常轮转"。
        # 进程活着却卡死（IO 挂起、死循环、被调试器停住）时，pid 和 ticks 都对得上，
        # 心跳却早就停更了；这种状态下状态页会一直说"运行中"，而环境变量再也不更新。
        # $HeartbeatMaxSec 就是为这件事存在的，这里必须真的用它。
        try {
            $beatAge = ((Get-Date) - (Get-Item -LiteralPath $HeartbeatFile).LastWriteTime).TotalSeconds
            if ($beatAge -gt $HeartbeatMaxSec) { return $null }
        } catch { return $null }

        # pid 对得上还不够：系统回收 pid 后新进程会顶替它。
        # 心跳里记着写它的那个进程的启动时刻，两者都对上才认。
        $proc = Get-Process -Id $beatPid -ErrorAction SilentlyContinue
        if (-not $proc) { return $null }
        if ($wantTicks -gt 0) {
            $actualTicks = 0
            try { $actualTicks = [long]$proc.StartTime.Ticks } catch { return $null }
            if ($actualTicks -ne $wantTicks) { return $null }
        }
        return [pscustomobject]@{ ProcessId = $beatPid; CommandLine = ""; Alive = $true }
    } catch {}
    return $null
}

function Get-MonitorProcess {
    $fromFile = Get-MonitorProcessFromPidFile
    if ($fromFile) { return $fromFile }
    # 不依赖 WMI 的快速判据：心跳新鲜就当作活着。
    # 它拿不到 PID（拿得到也在 $fromFile 那一支返回了），所以只在"是不是活着"这个问题上生效。
    if (Test-MonitorAlive) { return [pscustomobject]@{ ProcessId = 0; CommandLine = "" } }
    # Get-CimInstance 是 Windows 专有的命令：Linux/macOS 上的 pwsh 没有它。
    # 本项目的测试会在 ubuntu 上跑这份代码（门禁 10），退不回来就会抛异常、
    # 整份自检中断在这里。非 Windows 上直接当作"没有命令行线索"。
    if ($env:OS -ne "Windows_NT") { return $null }
    $list = @(Get-OwnMonitorProcesses)
    if ($list.Count -gt 0) { return $list[0] }
    return $null
}

# 监控启动参数的唯一来源：命令行必须以 -File "<入口路径>" 结尾——这既是监控进程的识别判据
# （见 $MonitorCmdLinePattern），也是"启动的到底是哪个文件"的唯一出处。测试也从这里取。
function Get-MonitorLaunchArgs {
    return @("-NoProfile","-WindowStyle","Hidden","-ExecutionPolicy","Bypass","-File",('"{0}"' -f $ScriptPath))
}

# 返回值 = 是否确认监控在跑。调用方据此说话——"我调用过启动"不等于"它起来了"。
function Start-Monitor([bool]$Force = $false) {
    $existing = Get-MonitorProcess
    if ($existing) {
        # 已有监控在跑：
        #   - Force（安装场景）：无条件重启，保证运行中的监控永远是当前脚本的最新代码
        #   - 非 Force 且路径一致：幂等跳过（重复点安装零副作用）
        #   - 非 Force 且路径不一致：旧位置的监控（文件夹被移动过）：先停掉旧的，再启动新的
        # 注意：用 IndexOf 而非 -like——-like 会把路径里的 [ ] 当通配符误判
        $samePath = ($existing.CommandLine.IndexOf($ScriptPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
        if (-not $Force -and $samePath) {
            Write-Styled 'warn' "监控进程已在运行（路径一致），跳过启动。"
            return $true
        }
        Write-Styled 'warn' $(if ($Force) { "正在重启监控以加载当前最新代码..." } else { "检测到旧位置的监控进程，正在迁移到当前路径..." })
        Stop-Monitor
    }
    # 启动前清掉可能残留的 pid 文件（强杀不给监控机会删它），否则复检会读到上一次运行的 pid。
    Remove-ItemSafe $PidFile
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList (Get-MonitorLaunchArgs)
    # 启动完必须复查，判据是**监控自己写下的 pid 文件**：抢不到单实例互斥的子进程会安静退出，
    # 而它在退出前同样"命令行里带着本脚本"，只看进程存在就会把这种失败报成"已启动"。
    # 但也要给它足够时间：PowerShell 5.1 冷启动并加载全部库可能要好几秒，所以轮询而不是固定等。
    $deadline = (Get-MonotonicSeconds) + 12
    while ((Get-MonotonicSeconds) -lt $deadline) {
        if (Get-MonitorProcessFromPidFile) { break }
        Start-Sleep -Milliseconds 400
    }
    if (Get-MonitorProcessFromPidFile) {
        Write-Styled 'ok' "监控进程已启动。"
        return $true
    }
    # 起不来要分清是"另一个副本占着锁"还是"根本没起来"：前者该去别处收摊，后者该查杀软与日志。
    # 说清楚另一份在哪，使用者才知道该进哪个文件夹——只说"可能被占着"，等于把排查推回去。
    $other = $null
    try {
        $otherList = @(Get-OwnMonitorProcesses)
        if ($otherList.Count -gt 0) { $other = $otherList[0] }
    } catch {}
    if ($other) {
        $otherPath = ""
        if ($other.CommandLine -match '-File\s+"?([^"]*?envproxy\.ps1)"?\s*$') { $otherPath = $Matches[1] }
        $otherDir = if ($otherPath) { Split-Path -Parent (Split-Path -Parent $otherPath) } else { "" }
        Write-Styled 'warn' ("监控进程未能确认运行：另一个副本的监控正占着单实例锁（{0}）。" -f $(if ($otherDir) { $otherDir } else { $otherPath }))
        Write-Styled 'warn' "      还用那份就继续用它；不用了，进上面那个文件夹打开菜单选 一键恢复，再回到这里选 安装。"
    } else {
        Write-Styled 'warn' "监控进程未能确认运行：这次没看到别的副本，多半是启动被拦或启动过程出错。"
        Write-Styled 'warn' "      再选一次 安装 / 修复；仍然不行就看 查看状态 和 monitor.log 最近几行。"
    }
    return $false
}

function Stop-Monitor {
    $w = Get-MonitorProcess
    if (-not $w) {
        # 监控本来就没在跑，但使用者确实表达了"停"的意图——照样记下来。
        # 不记的话，状态页会把这台机器报成"进程不在了（可能被结束任务关掉）"，
        # 而真相是使用者刚刚点过停止。意图比进程状态更权威。
        try { Write-Text -Path $StopIntentFile -Text "user" } catch {}
        Write-Styled 'warn' "监控进程未在运行。"
        # 没在跑 = 目的已经达成，算成功（与 mac 侧那支的 return 0 一致）。
        return 0
    }
    # 从目标监控的命令行动态解析它的脚本位置 → 把停止标志写到"它自己"的 monitor 目录。
    # 处理文件夹被移动/复制后新旧位置不一致的场景：让旧位置的监控优雅退出，而非强杀。
    $targetDir = $MonitorDir
    # 引号可有可无：引号是启动方式决定的，不是身份的一部分（与 $MonitorCmdLinePattern 同一条道理）。
    # 要求带引号时，手工起的监控拿不到它自己的目录：停止标志写进了"我们"的 monitor 目录，
    # 优雅停止退化成强杀，还留下一个谁也不会消费的 stop.flag。
    if ($w.CommandLine -match '-File\s+"?([^"]*?envproxy\.ps1)"?\s*$') {
        $targetDir = Join-Path (Split-Path -Parent $Matches[1]) "monitor"
    }
    $targetFlag = Join-Path $targetDir "stop.flag"
    # 1) 优雅：写停止标志，监控进程 2 秒内自行退出
    try {
        New-Item -Path $targetDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        Write-Text -Path $targetFlag -Text "stop"
    } catch {}
    $deadline = (Get-MonotonicSeconds) + 6
    while ((Get-MonotonicSeconds) -lt $deadline) {
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
    # 记下"这是使用者主动停的"，状态页据此区分它与"进程被外部结束"。
    try { Write-Text -Path $StopIntentFile -Text "user" } catch {}
    # 强杀路径下监控来不及删自己的心跳与快照；不清掉它们，下面这条判定会读到一个
    # "2 秒前刚刷新"的心跳，于是误报"未能停止"。
    # 位置必须是目标目录（跨位置停止时目标不是本进程的 $MonitorDir）。
    #
    # 状态快照尤其要清："停止"是一个**明确的状态**，不该靠快照 240 秒自然过期来表达。
    # 留着它，状态页在这段时间里仍会把它当"当前结论"，于是代理没在跑也报"已开启"——
    # 而使用者刚刚才点过停止，屏幕与他的动作直接矛盾。
    # 必须在"跨位置空目录清理"之前做：目录一旦被删掉，下面按路径删文件就落空了。
    try {
        $beatTarget = Join-Path $targetDir "monitor.beat"
        if (Test-Item $beatTarget) { Remove-Item -LiteralPath $beatTarget -Force -ErrorAction SilentlyContinue }
        $snapTarget = Join-Path $targetDir "state.snapshot"
        if (Test-Item $snapTarget) { Remove-Item -LiteralPath $snapTarget -Force -ErrorAction SilentlyContinue }
    } catch {}
    if (-not (Test-Item $targetDir) -or $targetDir -eq $MonitorDir) {
        try { Remove-ItemSafe $HeartbeatFile } catch {}
        try { Remove-ItemSafe $StateSnapshotFile } catch {}
    }
    # 跨位置停止的零残留：若停止标志写在"别的" monitor 目录、且该目录已空
    # （旧监控退出时已清理自己的 pid/flag），则把这个重建的空目录一并移除。
    # 必须排在上面删心跳/快照之后：目录先没了，按路径删文件就全部落空。
    if ($targetDir -ne $MonitorDir) {
        $left = Get-ChildItem -LiteralPath $targetDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $left) {
            Remove-Item -LiteralPath $targetDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (Get-MonitorProcess) {
        Write-Styled 'warn' "监控进程未能停止（请检查是否有别的窗口正在运行它）。"
        # 定论由复读决定，不由"我发了停止信号"决定：进程还在就不能报"已停止"。
        # 返回值也必须跟着这个结论走——原来两支都只写屏幕、函数隐式返回 $null，
        # 于是入口那句 `if (-not $stopOk) { exit 1 }` 永远不成立：屏幕说"未能停止"，
        # 脚本里的 `envproxy.ps1 -Stop && 下一步` 却照常往下走。
        # 与 mac 侧 stop_monitor 的 return 1 / return 0 同一套。
        return 1
    }
    Write-Styled 'ok' "监控进程已停止。"
    return 0
}

# ------------------------------------------------------------------------------
# 5. 日志（只记状态翻转，不刷屏；超过 $LogMaxBytes 自动截断）
# ------------------------------------------------------------------------------


# ------------------------------------------------------------------------------
# 6. 监控主循环（事件驱动 + 多轮确认去抖，无频繁写操作）
# ------------------------------------------------------------------------------
# 状态疑似翻转要连续确认几轮才动手：轮数决定"抗抖能力"，也是对外公布的
# "连回来要多久 / 断开要多久"的一部分，所以必须是具名常量（门禁要读它推导文档）。
$StateDebounceRounds = 2
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
    try {
        Write-Text -Path $PidFile -Text ([string]$PID)
        # 监控活着就等于"不是停止状态"，把上次的停止意图清掉。
        Remove-ItemSafe $StopIntentFile
    } catch {}
    Update-ScriptPathRecord
    Write-MonitorLog "==== 监控启动 ===="

    # 固定入口（中继）：跟监控同生共死，不新增常驻进程。
    # 起不来不该让监控停摆——它只是"走代理的快捷方式"的一个便利，
    # 没有它那些图标照样能用（退回直读当前代理）。所以失败只记日志，不改监控行为。
    #
    # 但**日志必须说清是哪一种失败**：编译不了 / 端口全被占 / 启动抛异常，
    # 这三种的排查方向完全不同。只写一句"没能启动"，事后只能靠改代码去试。
    try {
        if (Start-Relay) {
            Write-MonitorLog ("固定入口已启动：127.0.0.1:" + $script:RelayPort)
        } else {
            $why = ""
            try { $why = [string]$script:RelayFailReason } catch {}
            if ($why) {
                Write-MonitorLog ("固定入口没能启动（不影响使用）：" + $why)
            } else {
                Write-MonitorLog "固定入口没能启动（不影响使用：桌面图标的可用状态会按每次打开时的实际情况判断）"
            }
        }
    } catch {
        Write-MonitorLog ("固定入口启动异常（不影响使用）：" + $_.Exception.Message)
    }

    # 启动立即对齐：不等去抖，当场校正环境变量。
    # 关键场景：关机前没退出翻墙软件 → 重启后环境变量残留死端口 →
    # 监控一启动就立即清掉残留（恢复直连）或注入正确值，闭环无窗口期。
    # $prevState 与 $lastState 是一对：$lastState 是"现在是什么"，
    # $prevState 是"这次翻转之前是什么"。提示逻辑要比较这两个。
    # 两个都在循环外声明，启动对齐时一起赋值——否则第一次翻转拿不到旧值。
    $lastState    = $null
    $prevState    = $null
    $pendingState = $null
    $pendingCount = 0
    $repairRound  = 0
    # 快照用的两个量：变量是否与状态一致、本轮写变量成没成。
    # 两者都只在特定轮次才算得出来，其余轮次必须是 $null（= 不知道），
    # 不许拿上一次的结论顶替——那会把"没算"说成"一致"。
    $lastVarsMatch   = $null
    $lastApplyResult = "unknown"
    $selfExit     = $false
    try {
        $bootState = Get-CurrentState
        # 端口枚举失败时这一轮是"不知道"：按"没代理"去清理变量，
        # 是在删一个可能还活着的代理——那正是最不该犯的错。
        if ($bootState -ne "unknown") {
            Apply-State $bootState
            $lastState = $bootState
        } else {
            Write-MonitorLog "启动时端口枚举失败 -> 不动环境变量，沿用现状"
        }
        # 启动对齐时就把"上一状态"定下来，与 $lastState 同步。
        # 不这么做的话，$prevState 要到第一次状态翻转时才被赋值，
        # 于是"监控刚起来之后的第一次换端口"拿到的旧状态是空值，
        # 提示判据认为无从比较而跳过——而那恰好是开机后最常发生的一次变化。
        $prevState = $lastState
    } catch {
        Write-MonitorLog "启动对齐异常: $($_.Exception.Message)"
    }

    while (-not (Test-Item $StopFlag)) {
        # 运行时目录自愈。它只在启动时建过一次，被外部删掉（清理工具、误删、同步软件）之后
        # 日志与 pid 文件就再也写不出来了：进程还在正常干活，状态页却因为读不到 pid 而报
        # "未运行"——用户看到的是"明明在跑却说没跑"，于是又去点安装，起第二份被单实例锁挡掉，
        # 彻底卡死。每轮先确认目录在，是这件事的唯一收敛点（mkdir -p 是幂等的、不产生 IO）。
        if (-not (Test-Item $MonitorDir)) { Ensure-MonitorDir }
        # pid 文件同理：它一旦丢失，对外就"查不到自己在跑"。重新写一份，代价是一次小文件写。
        if (-not (Test-Item $PidFile)) { try { Write-Text -Path $PidFile -Text ([string]$PID) } catch {} }
        # 心跳：每 3 轮刷新一次（写的内容是 pid + 启动时刻，比"单个字节"多几十字节，
        # 但仍是一次小文件写，代价可忽略）。
        # 它的存在是为了让"没有 WMI 的机器上也能判断监控还活着"——
        # 不依赖任何系统服务，也不依赖进程查询接口。
        if ($repairRound % 3 -eq 0) {
            try {
                # 内容：本进程 pid + 启动时刻 ticks。
                # 记启动时刻是为了挡住 pid 复用——系统回收 pid 再分配给别的进程后，
                # 新进程的 StartTime 一定不同。这是 mac 侧 `ps -p <pid> -o args=` 的等价物：
                # PowerShell 5.1 的 Get-Process 没有 CommandLine 属性（那是 7 才有的），
                # 而拿命令行在 5.1 下只能走 WMI/CIM —— 正是本判据要绕开的通道。
                $me = Get-Process -Id $PID -ErrorAction SilentlyContinue
                $stamp = if ($me) { [string]$me.StartTime.Ticks } else { "0" }
                Write-Text -Path $HeartbeatFile -Text (([string]$PID) + " " + $stamp)
            } catch {}
        }
        # 日志文件也要补。它只在"状态有变化"时才写，稳态下一条都不产生——
        # 只补目录和 pid 的话，删过目录之后 monitor.log 会一直不存在，
        # 等到真出问题时用户手上没有任何线索可查（"日志永远是空的"比"没日志"更误导）。
        # 写一条记录本身就是最好的补法：文件建起来了，而且留下了"这里被重建过"的痕迹。
        if (-not (Test-Item $LogFile)) {
            try { Write-MonitorLog "运行时目录被外部删除，已重建（进程未受影响，继续按原状态工作）" } catch {}
        }
        # 自退检测：脚本文件不存在 = 文件夹被移动/删除 → 旧位置不再需要本监控。
        # 静默退出并清理旧位置的一切运行时痕迹（下次开机定位器会从新位置启动）。
        if (-not $ScriptPath -or -not (Test-Item $ScriptPath)) { $selfExit = $true; break }
        try {
            $state = Get-CurrentState
            # 本轮是不是"读不出来"。unknown 既不是"变化"也不是"稳定"，
            # 它**不参与去抖记账**——见下面 if 处的说明。
            $stateUnknown = $false

            if ($state -eq "unknown") {
                # 这一轮不知道（端口枚举失败）：沿用上一状态，不动环境变量，
                # 也不计入去抖——把"没读到"当成"没在翻墙"会删掉用户的代理变量。
                # 失败原因由探测层放在 $script:PortEnumerationReason 里，这里带上一句：
                # 只写"枚举失败"等于把唯一的线索丢掉，事后分不清是 netstat 形状变了、
                # 输出被裁剪、还是权限问题，而这几种的排查方向完全不同。
                $why = ""
                try { $why = [string]$script:PortEnumerationReason } catch {}
                if ($why) {
                    Write-MonitorLog ("端口枚举失败（两次都没成功：" + $why + "）-> 本轮沿用上一状态，不动环境变量")
                } else {
                    Write-MonitorLog "端口枚举失败 -> 本轮沿用上一状态，不动环境变量"
                }
                $state = $lastState
                $stateUnknown = $true
            }

            # 去抖记账。**unknown 轮必须整段跳过**，这是"状态翻不过来"的第二条路径：
            #
            # 上面把 $state 换成了 $lastState，于是这里的 $state -ne $lastState 恒为假，
            # 直接落进 else 把 $pendingCount 清零——前面几轮攒下的"待确认"证据全废。
            # 后果：只要端口枚举在 2 轮确认窗口里失败过一次，on→off 就永远走不完。
            # 实测：关掉翻墙软件 + 枚举隔轮失败，12 轮内状态一次都没动，
            # 变量一直指向死端口，状态页绿字"已开启"——正是刚修的那个故障换了个入口。
            #
            # 根因是"不计入"被实现成了"清零"。正确的语义是：这一轮没读到，
            # 既不能当作证据支持翻转，也不能当作反证否掉已有证据——原地不动。
            if ($stateUnknown) {
                # 什么都不做：保留 $pendingState / $pendingCount 原样，下一轮接着攒。
            } elseif ($state -ne $lastState) {
                # 状态疑似翻转：连续确认 $StateDebounceRounds 轮才动手，杜绝抖动
                if ($state -eq $pendingState) { $pendingCount++ } else { $pendingState = $state; $pendingCount = 1 }
                if ($pendingCount -ge $StateDebounceRounds) {
                    $prevState = $lastState
                    Apply-State $state
                    $lastState = $state
                    $pendingState = $null
                    $pendingCount = 0
                    # 代理地址换了之后，已经开着的程序还连着旧地址，会连不上。
                    # 提醒一句（提示跑在独立进程里，不阻塞这一轮探测）。
                    # 放在 Apply-State 之后：变量已经写好，用户看到提示时去重开程序就是对的。
                    try { $null = Register-ProxyStateChange $prevState $state } catch {}
                }
            } else {
                $pendingState = $null
                $pendingCount = 0
            }

            # 把本轮的结论写成快照，供状态页只读。
            #
            # 每轮都写，不只在变化时写：只在变化时写会让文件在稳态下永远停在上次
            # 变化那一刻，于是"一直稳定在 off"和"十分钟前死在 off"长得一模一样。
            # 每轮写把"文件新不新"和"监控活着吗"合成一个问题：written 是几秒前，
            # 就说明监控活着、且结论就是此刻的结论。
            #
            # 写失败一律吞掉（Write-StateSnapshot 内部 try/catch）：监控的职责是管代理，
            # 写快照是附带。写不出来最多让状态页退回实时探测，不能让监控停摆。
            try {
                $snapState = if ($lastState) { [string]$lastState } else { "" }
                $snapPrev = if ($prevState) { [string]$prevState } else { "" }
                $snapPending = if ($pendingState) { [string]$pendingState } else { "" }
                $snapEnum = if ($script:PortEnumerationFailed) { "failed" } else { "ok" }
                $snapReason = ""
                if ($script:PortEnumerationFailed) { try { $snapReason = [string]$script:PortEnumerationReason } catch { $snapReason = "" } }
                # vars_match 只在自愈那一轮才算过；其余轮如实写 unknown，
                # 不许把"没算"写成"一致"。
                $snapVars = "unknown"
                if ($lastVarsMatch -ne $null) {
                    $snapVars = if ($lastVarsMatch) { "yes" } else { "no" }
                }
                # 代理在跑的时候，顺手问一句"它连不连得出去"。
                #
                # 三条纪律，缺一条就会拖垮或说谎：
                #   ① **只对已锁定的端口问**——那时端口是活的，握手 3–14ms，不会等 TCP 超时
                #      （对一个没人听的端口会白等 4 秒，那是把刷新周期踩爆的代价）；
                #   ② **只在 on 状态问**。off 的时候没有代理，问它干什么；
                #   ③ **问不到就留空**，不许写成"没问题"。空 = 这一轮不知道，
                #      状态页据此不作任何判断（宁可不说，也不能猜）。
                $snapHs = ""
                # 状态串的格式是 `on:7078`（冒号），不是 `on 7078`（空格）。
    # 写成 `-like 'on *'` 永远不成立，于是这个字段恒为空、状态页那条
    # 「代理在跑但连不上外面（多半是节点问题）」从来没显示过——一个被静默禁用
    # 的用户可见功能。同一份代码里其余 7 处都用 StartsWith('on:') 或正则，
    # 只有这里写成了空格，改成同一个判据（契约：同一判断只准有一处实现）。
    if ($snapState -and $snapState.StartsWith('on:')) {
                    $snapPort = 0
                    try { if ([int]::TryParse($snapState.Substring(3), [ref]$snapPort)) { } else { $snapPort = 0 } } catch { $snapPort = 0 }
                    if ($snapPort -gt 0) {
                        try { $snapHs = [string](Get-ConnectHandshakeKind $snapPort 300) } catch { $snapHs = "" }
                    }
                }
                Write-StateSnapshot -State $snapState -PrevState $snapPrev -PendingState $snapPending `
                    -PendingCount $pendingCount -PortEnumeration $snapEnum -PortReason $snapReason `
                    -VarsMatch $snapVars -ApplyResult $lastApplyResult -NodeHandshake $snapHs
            } catch {}

            # 固定入口跟着当前代理走：每轮把"我们注入的那个值指向哪个端口"告诉中继。
            # 成本是一次静态字段写（微秒级），所以不必节流。
            # 中继**不缓存**上游：换端口后下一条新连接就走新的，不需要重启它。
            # 中继没在跑时这是空操作（Sync-RelayUpstream 自己判）。
            # 中继本身也要每轮确认还活着。
            #
            # accept 线程可能因为一次监听异常就退出了。那时如果不重建，会永久坏到
            # 监控进程重启：图标还能点，但永远不走代理，状态页说"没在工作"，
            # 没有任何路径会修它。Start-Relay 是幂等的（在跑就直接返回），
            # 所以拿它当"死了就重建"的唯一收敛点，成本是一次布尔判断。
            #
            # 顺序在 Sync 之前：先在的中继不存在时重建，再告诉它上游是谁——
            # 反过来的话，刚重建的那一个会空等一轮才拿到上游。
            try { $null = Start-Relay } catch {}
            try { Sync-RelayUpstream } catch {}

            # 每 30 轮自愈一次（轮间隔 on 2 秒 / off 3 秒 → 约 60–90 秒一次）。
            # 按轮计数而不是按秒：轮询节奏本身就是可变配置，写死秒数会随节奏改动而失准。
            $repairRound++
            if ($repairRound -ge 30) {
                $repairRound = 0
                Repair-AutoRun
                # 终端同步的钩子块也在这里自愈：升级后没走"安装"，旧块内容会一直留在用户
                # $PROFILE 里（钩子改了却送不到手里）。幂等，已是最新就零写入。
                try {
                    $pr = Install-ShellProfile
                    if ($pr.Reason -eq 'installed') {
                        Write-MonitorLog "已自动更新终端同步（配置块内容与当前版本不一致）"
                    } elseif ($pr.Reason -eq 'unpaired') {
                        Write-MonitorLog ("终端同步没有更新：配置文件里的标记不成对，没动它：" + $pr.Path)
                    }
                } catch {}
                # 版本号缓存：状态页要显示"是不是最新版"，而它自己不许联网——
                # 否则每次"查看状态"都要等一次外网往返（离线/限流时白等）。
                # 写缓存的是监控（它本来就写文件），状态页只读。
                try { Write-VersionCache } catch {}
                # 变量自检：Apply-State 只在状态翻转时动手，稳态下它永远不会被调用，
                # 于是"别的东西改坏了变量"没人纠正。这里按同一周期做一次整表核对：
                # on 态补齐缺失项，off 态把残留收干净——幂等（齐了就零写入、零广播）。
                # 只核对我们本该持有的那几个，用户自己设的变量不受影响。
                #
                # 动手的那段走与 Apply-State 完全相同的函数（Invoke-EnvStateWrite）：
                # 拿同一把跨进程锁、同样的判断、同样的广播。两份代码做同一件事的后果是
                # 改一处漏一处，而症状是"翻转时对、自愈时错"，屏幕上完全看不出来。
                # 先判 "on:" 前缀：启动对齐若抛过异常，$lastState 仍是 $null。
                if ($lastState) {
                    $healOk = Invoke-EnvStateWrite $lastState `
                        "检测到代理变量残留 -> 已回收，恢复直连" `
                        "变量被人改坏了 -> 已按当前代理端口重新写回"
                    if ($healOk -ne 0) { Write-MonitorLog "变量自检没能写回（下一轮再试）" }
                    # 把自愈的结论记下来给快照用：0 = 写成功或本来就齐。
                    # 这是唯一能算出"变量与状态是否一致"的地方，别处算不了。
                    $lastVarsMatch = ($healOk -eq 0)
                    $lastApplyResult = if ($healOk -eq 0) { "ok" } else { "failed" }
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

    # 固定入口先停：它只是一个监听线程，与本进程同生共死。
    # 停掉之后端口记录也一并清掉——留着它，启动器会去连一个没人听的口，
    # 白白多等一个连接超时之后才降级。清掉则它立刻退回直读注册表。
    try {
        Stop-Relay
    } catch {}
    try { Write-MonitorLog "固定入口已停止" } catch {}

    if ($selfExit) {
        # 文件夹被移动/删除：自退时没有活着的组件会再纠正变量，先把我们写的东西清掉
        # （新位置的监控会在秒级内按需重注），再清运行时目录与空壳。
        # 注意竞态：移动瞬间若恰好写日志，Ensure-MonitorDir 会重建旧位置目录。
        # 因此：删 monitor 目录后，若脚本目录只剩空壳（无任何其他文件）→ 一并删除，
        # 确保旧位置完全消失（下次移回时 Move-Item 不会因空壳而嵌套）。
        try { Apply-State "off" } catch {}
        try {
            # 整个目录一起删，心跳自然也在里面；但删之前先把文件删掉，
            # 免得目录删除失败（被占用）时留下一个新鲜心跳骗后续判据。
            try { Remove-ItemSafe $HeartbeatFile } catch {}
            Remove-Item -LiteralPath $MonitorDir -Recurse -Force -ErrorAction SilentlyContinue
            $left = Get-ChildItem -LiteralPath $ScriptDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $left) {
                Remove-Item -LiteralPath $ScriptDir -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    } else {
        Write-MonitorLog "==== 监控退出（收到停止信号）===="
        # 退出前把 off 态落到状态镜像文件。这一步不能省：停止流程由**本进程**执行 Apply-State off
        # （Stop-Monitor 是另一个进程，它只写 stop.flag），所以这里是唯一能把"现在没代理了"
        # 告诉 Git Bash 钩子的地方。漏了它，已开着的 Git Bash 窗口永远不会被清空。
        try { Write-TerminalStateFile "off" } catch {}
        try { Remove-ItemSafe $PidFile } catch {}
        # 心跳必须和 pid 一起删。留着它的后果是：任何一个"监控刚退出"的瞬间，
        # 心跳还是新鲜的（最长 240 秒），于是 Test-MonitorAlive 判"还活着"，
        # 停止流程就打印"监控进程未能停止（请检查是否有别的窗口正在运行它）"——
        # 而监控其实已经退干净了。测试里真出现过这句，用户会以为出了问题。
        try { Remove-ItemSafe $HeartbeatFile } catch {}
        # 快照与心跳同理：留着它，停止之后状态页会在 SnapshotStaleSec 的窗口内
        # 继续把上一轮结论当成"当前状态"，报出"翻墙代理已开启"而变量已经删光。
        try { Remove-ItemSafe $StateSnapshotFile } catch {}
        try { Remove-ItemSafe $StopFlag } catch {}
    }
    $mutex.ReleaseMutex()
}

# 查「本用户的」监控进程。**必须按 SID 过滤**：Win32_Process 返回的是全机器所有
# 用户的进程，不过滤会认领别人的监控——状态页报出别人的 PID，
# Start-Monitor 还会把别人的监控当成「旧位置」停掉（写 stop.flag + 强杀）。
function Get-OwnMonitorProcesses {
    if ($env:OS -ne "Windows_NT") { return @() }
    $mySid = ""
    try {
        $mySid = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    } catch {}
    if (-not $mySid) { return @() }
    $all = @()
    try {
        $all = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)
    } catch { return @() }
    $mine = @()
    foreach ($p in $all) {
        if ($p.ProcessId -eq $PID) { continue }
        if (-not ($p.CommandLine -match $MonitorCmdLinePattern)) { continue }
        # SID 必须走 Invoke-CimMethod：Get-CimInstance 返回的是 CimInstance，
        # 上面并没有 GetOwnerSid() 这个方法（它属于旧的 Get-WmiObject 对象）。
        # 直接点方法会抛 "does not contain a method named 'GetOwnerSid'"，被 catch 吞掉后
        # $sid 恒为空 —— 于是**每一个**监控进程都被判成"不是我的"，状态页永远报"未运行"，
        # 而进程明明活着。这是把整段探测变成空操作，比不做过滤更糟。
        # 取不到 SID 时跳过而不是收下：宁可认不出自己的监控（下次启动会再起一份，
        # 单实例锁会挡住），也不要把别人的杀错。
        $sid = ""
        try { $sid = [string](Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop).Sid } catch {}
        if ($sid -and $sid -eq $mySid) { $mine += $p }
    }
    return $mine
}

# ------------------------------------------------------------------------------
# 代理换了之后提醒正在运行的程序
# ------------------------------------------------------------------------------
# 已启动的程序，环境变量在启动那一刻就定死了，之后怎么改都影响不到它。
# 所以换端口（或代理关掉）之后，那些程序还在连旧地址，会连不上、界面卡死或白屏，
# 而用户看不出原因——他只知道"刚才还好好的"。
#
# 这里不试图改别人的进程（Windows 没有这个能力），而是由本工具弹一句提示：
# 告诉用户"代理变了，正在运行的程序需要重开"。这是唯一做得到的事。
#
# 三个约束，缺一个就会变成骚扰：
#   ① 只在端口真的变了时提示。7078 -> 7078（重连但端口没变）不提示，因为那些程序
#      仍然连得通，提示是假警报；
#   ② 同一次变化只提示一次。记在一个文件里，避免每一轮探测都弹一遍；
#   ③ 不阻塞主循环。提示放在独立进程里弹，本进程立刻继续探测。

# 上次提示过的端口记在这里。用文件而不是内存变量：监控进程重启后不该重复提示
# 同一件事，而用户看到的是"每次开机又弹一遍"。
function Get-ProxyNotifyStatePath {
    return (Join-Path $MonitorDir 'notify.last')
}

# 读上次提示过的端口。返回空串 = 没有记录（从没提示过）。
function Read-ProxyNotifyState {
    $p = Get-ProxyNotifyStatePath
    try {
        if (-not (Test-Item $p)) { return '' }
        # 自写自读，用最简单的读法；读到半截或读失败都当作"没有记录"，
        # 最坏结果是多弹一次提示，不会弹错内容。
        $t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
        if (-not $t) { return '' }
        return $t.Trim()
    } catch { return '' }
}

# 写这个状态文件。
#
# 为什么不用 Write-TextAtomic：那是给**用户 profile** 用的写入器，
# 它会做三件这里不需要的事——探测原文件编码、沿用原文件行尾、留下 .envproxy.bak 备份。
# 前两件对一个我们自己写的单行 ASCII 状态文件毫无意义，第三件是实实在在的污染：
# 它会在 monitor 目录里留下 notify.last.envproxy.bak，而那个后缀在本项目里
# 语义是"用户装之前的原始内容，卸载时用来还原"。把一个状态文件伪装成备份，
# 既误导以后排查的人，也让"monitor 目录里只该有那几种运行时文件"这条不再成立。
#
# 这里要的只是"整份替换、不会读到半截"：同目录临时文件 + 原子替换。
function Write-ProxyNotifyState([string]$Value) {
    $p = Get-ProxyNotifyStatePath
    try {
        $dir = Split-Path -Parent $p
        if ($dir -and -not (Test-Item $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
        # 临时文件名带 PID：两个进程同时写不会撞同一个临时文件。
        $tmp = "$p.$PID.tmp"
        try {
            [System.IO.File]::WriteAllText($tmp, [string]$Value, (New-Object System.Text.UTF8Encoding($false)))
            if ([System.IO.File]::Exists($p)) {
                # 5.1 没有 File.Move 的覆盖重载，先删再移。
                [System.IO.File]::Delete($p)
            }
            [System.IO.File]::Move($tmp, $p)
        } finally {
            if ([System.IO.File]::Exists($tmp)) {
                try { [System.IO.File]::Delete($tmp) } catch {}
            }
        }
    } catch {}
}

# 状态换成新的了：该不该提醒。
# 返回 $true = 需要提示（并已记下新状态）。
#
# 判据只有一条：**代理地址变了，且新旧两个都是"有代理"或"从有到无"**。
#   off    -> on:P    提示（程序原来直连，现在有代理了；多数程序会自动重连，不必提醒）
#                      —— 实际上这个方向不需要提醒：直连变代理，旧程序照旧直连能通，
#                      没有"连不上"的问题。所以不提示。
#   on:P1  -> on:P2   提示（端口变了，旧程序仍连 P1）
#   on:P   -> off     提示（代理没了，旧程序还写着 P1）
#   on:P   -> on:P    不提示（同一个地址）
#   off    -> off     不提示
#   unknown 参与的任何迁移都不提示：那一轮根本不知道状态，提示等于谎报。
function Test-ProxyShouldNotify([string]$OldState, [string]$NewState) {
    if (-not $OldState -or -not $NewState) { return $false }
    if ($OldState -eq 'unknown' -or $NewState -eq 'unknown') { return $false }
    # 统一成 "off" 或 "on:端口"
    $oldOn = $OldState.StartsWith('on:')
    $newOn = $NewState.StartsWith('on:')
    $oldPort = if ($oldOn) { $OldState.Substring(3) } else { '' }
    $newPort = if ($newOn) { $NewState.Substring(3) } else { '' }

    if ($oldOn -and $newOn) {
        # 端口变了才提示；没变什么都不做
        return ($oldPort -ne $newPort)
    }
    if ($oldOn -and -not $newOn) {
        # 代理关了：旧程序还挂着那个地址，会连不上
        return $true
    }
    # off -> on（新出现代理）与 off -> off 都不提示：
    # 前者的旧程序照旧直连能通，没有问题；后者什么都没变。
    return $false
}

# 真的弹一句。放在独立进程里，不阻塞调用方。
#
# 做法：起一个 powershell 去弹 WScript.Shell.Popup，弹窗 10 秒后自己关，用户什么都不用点。
#
# 为什么用 -EncodedCommand 而不写一个 .vbs 让 wscript 执行：中文写进 .vbs 要靠 ANSI 编码，
# 实测这条路不可靠——cscript 直接报"无效字符"（写进去的字节 wscript 认不出）。
# 改成把整段脚本 base64 后交给 powershell，编码由 base64 保证，任何语言的字符都不会坏。
#
# 代价是启动慢一点（实测约 290 ms），但这是低频事件（只在代理地址真变时发生），
# 而且它跑在独立进程里，不占监控主循环的时间。
function Invoke-ProxyChangeNotice([string]$OldState, [string]$NewState) {
    # 措辞按"用户遇到什么"来写，不按"我们的状态机怎么变"来写。
    #
    # 两种情况要分开说，因为后果真的不同：
    #   on -> on  ：翻墙软件换了端口。**用菜单建的图标不受影响**——它们连的是固定入口，
    #               那个地址永不变，背后自动跟着换。会断的只有直接读环境变量的程序
    #               （git/npm/curl 这类在终端里跑的），它们下次开就会读新值。
    #               所以这句不能再吓唬人说"程序都连不上了"，那是固定入口出现之前的说法。
    #   on -> off ：代理真的关了，谁都用不了。这时"关掉重开"也救不了——
    #               要救只能重新开翻墙软件。指错方向比不提示更糟。
    #
    # 端口号不写进弹窗：用户不认端口号，也做不了什么，写出来只会让他以为要记下来。
    $msg = if ($NewState.StartsWith('on:')) {
        "翻墙软件换了个端口。`r`n`r`n" +
        "用菜单建的那些图标不受影响，照常用就行。`r`n" +
        "在终端里跑的程序（git、npm 这类）新开一个窗口就跟着换了；`r`n" +
        "PowerShell 和 Git Bash 里，已经开着的窗口敲一下回车也会跟上`r`n" +
        "（cmd 窗口没有这个机制，得关掉重开一个）。"
    } else {
        "翻墙软件关掉了（或者断开了）。`r`n`r`n" +
        "现在上不了外网，终端里的程序也会连不上。`r`n" +
        "要用就把它重新打开，代理会自动回来；不用管也行。"
    }
    # 消息文本走 base64：中文、引号、换行都不用操心转义，编码由 base64 保证。
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($msg))
    $inner = "`$m=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$b64'));" +
             "`$s=New-Object -ComObject WScript.Shell;" +
             "`$null=`$s.Popup(`$m,10,'EnvProxy',64)"
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($inner))
    try {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand ' + $enc) `
            -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
    } catch {}
}

# 在主循环看到状态翻转时调用：判断 + 提示 + 记录，一处做完，免得调用点各写一遍再分叉。
#
# 去重只靠一件事：这个文件记的是"**上次提示时**的那个新状态"。
# 主循环每轮都会调用本函数（state 与 lastState 不同才进来，且已过去抖），
# 如果同一目标状态已经提示过——例如监控重启后又看到同样的翻转——
# 就不再弹。这样既不会漏（真正的新变化一定没有记录），也不会烦（同一件事只弹一次）。
function Register-ProxyStateChange([string]$OldState, [string]$NewState) {
    if (-not (Test-ProxyShouldNotify $OldState $NewState)) { return $false }
    $lastNotified = Read-ProxyNotifyState
    if ($lastNotified -eq $NewState) { return $false }
    Write-ProxyNotifyState $NewState
    Invoke-ProxyChangeNotice $OldState $NewState
    return $true
}

