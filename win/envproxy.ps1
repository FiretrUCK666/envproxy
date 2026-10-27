# ==============================================================================
#  envproxy.ps1 — 命令行自动翻墙（Windows 原生，零依赖，通用版）
# ------------------------------------------------------------------------------
#  子命令（双击"打开菜单"，或在 PowerShell 里运行）：
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Menu                打开菜单（安装/状态/停止/恢复/更新）
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Install             一键安装
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Stop                停止监控并删变量
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Uninstall           一键恢复（问日志留不留）
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Uninstall -Purge    一键恢复并连日志一起删（不问）
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Status              查看状态
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Update              检查更新（问过才装）
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Update -Yes         检查更新并跳过确认（供脚本调用）
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Help                打印帮助（忘了怎么用时看）
#     无参数（由开机自启调用）                                                   进入监控模式
#
#  运行环境：Windows 10/11 自带 PowerShell 5.1。不需要 Node/Python/管理员。
#
#  原理（通用，不绑定任何特定翻墙软件）：
#     监控进程每 2-3 秒探测一次"本机是否有 HTTP 代理端口正在监听"（on 态 2 秒、off 态 3 秒）。
#     发现来源（两层，与系统代理/PAC/Core 完全无关，只认端口本身）：
#       1) 快路径：常见翻墙软件默认端口扫描（$KnownProxyPorts，可自行增删）
#       2) 万能路径：全端口扫描 + CONNECT 握手探测（进程名预筛提速）
#           → 随便改端口、随便换软件，都能自动发现，不写死任何东西
#     状态翻转（开/关/换端口）时才写一次用户级环境变量并广播刷新。
#     状态稳定时什么都不写 —— 不存在"反复监测反复断连"。
#
#  行为保证：
#     - 翻墙软件断开/重连/退出/重启/换端口/换软件 → 监控自动跟随，无需任何操作
#     - 退出翻墙软件后删掉代理变量；"断开连接"（内核仍活着）以流量真相判定，慢得多
#       （平时 15 秒探一次，发现失败后加密到 5 秒一次，连续失败满 10 秒、至少 3 次才判"断"）
#     - 断开后连回来会恢复代理变量（一次成功即认，且刚下完结论时保持加密观察）
#     - 具体秒数只有一个权威源：README 第 5 节的状态图。这里不复述，免得改常量时对不上。
#     - 整个文件夹移动 → 无需任何操作（监控自退 + 定位器开机自动重新定位；
#       自动搜索只覆盖"用户目录 + 其他磁盘根"，搬到范围外时打开菜单选"安装 / 修复"接管）
#     - 无常驻依赖、不改系统代理、不需要管理员
# ==============================================================================

param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Stop,
    [switch]$Status,
    [switch]$Update,
    [switch]$Menu,
    [switch]$Help,
    [switch]$Advanced,
    [switch]$Report,
    [switch]$Yes,
    [switch]$Purge,
    [switch]$RepairProfile
)
# ------------------------------------------------------------------------------
#  文件结构（入口只做四件事：解析参数、挂操作锁、加载自检、分派）
#     envproxy.ps1      入口（本文件）
#     lib\base.ps1     契约常量、纯函数、文件读写助手
#     lib\probe.ps1    端口发现、握手、节点连通、状态判定
#     lib\env.ps1      代理变量写入/删除/归属/快照还原
#     lib\runtime.ps1  日志、监控进程、主循环、自启动定位器
#     lib\package.ps1  覆盖安装区、备份与回滚
#     lib\update.ps1   版本检查、下载校验、确认流程
#     lib\ops.ps1      安装/停止/卸载/状态编排、菜单与帮助
#     lib\shortcut.ps1 走代理的快捷方式（生成启动脚本、读写 .lnk、扫描记录、三屏界面）
#   库清单的唯一权威处是下面的 $CoreLibs；门禁会核对它与 lib\ 实际内容一致。
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# 启动期的输出通道（必须先于任何库定义）
# ------------------------------------------------------------------------------
# 下面两段自救提示（缺文件 / 解析不过）存在的唯一理由，就是"库有问题时给人一句人话"。
# 而它们跑在库加载**之前**，此刻 Write-Styled 还定义在 base.ps1 里、根本没进来。
# 用它打印的后果是：满屏 "术语 'Write-Styled' 不会被识别"，排查方向被引到"工具自己崩了"。
# 所以这里自带一个不依赖任何库的最小输出器，只用 Write-Host。
function Write-BootWarn([string]$Text) {
    try { Write-Host $Text -ForegroundColor Yellow } catch { try { Write-Host $Text } catch {} }
}

# ------------------------------------------------------------------------------
# 加载核心库（顺序固定：契约常量与纯函数必须先就位）
# ------------------------------------------------------------------------------
# 只有入口能回答"这个程序在哪里"：库被点源后 $PSCommandPath 与 $PSScriptRoot 指的都是
# **库文件自己**——拿它当入口路径会去启动一个库文件（跑不起来、连日志都写不出来），
# 拿它推目录会把 monitor 目录指进 lib\。所以入口在这里公布两个事实，各库一律只用它们。
$ScriptPath = if ($PSCommandPath) { $PSCommandPath }
              elseif ($PSScriptRoot) { Join-Path $PSScriptRoot "envproxy.ps1" }
              else { Join-Path (Get-Location).Path "envproxy.ps1" }
$ScriptDir  = Split-Path -Parent $ScriptPath
$LibDir = Join-Path $ScriptDir "lib"
# 库清单是唯一权威处：新增或改名库只改这里，门禁核对它与 lib\ 实际内容一致。
# relay 只依赖 base（它用的是固定安装目录，不是 monitor 目录），所以排在 runtime 之前
# 也可以；排在 package 之前是因为建快捷方式那一段要用它算端口记录的位置。
$CoreLibs = @("base", "probe", "env", "runtime", "relay", "package", "update", "ops", "shortcut")
# 加载前先验完整性：缺文件时说人话，而不是抛一句看不懂的语法错误。
$missingLib = @()
foreach ($libName in $CoreLibs) {
    $libPath = Join-Path $LibDir ("{0}.ps1" -f $libName)
    if (-not (Test-Path -LiteralPath $libPath)) { $missingLib += ("lib\{0}.ps1" -f $libName) }
    elseif ((Get-Item -LiteralPath $libPath).Length -eq 0) { $missingLib += ("lib\{0}.ps1（空文件）" -f $libName) }
}
if ($missingLib.Count) {
    Write-BootWarn "安装不完整，缺少程序文件："
    foreach ($m in $missingLib) { Write-BootWarn ("  " + $m) }
    Write-BootWarn "这个文件夹没有完整拷过来，或者文件被删掉了。"
    Write-BootWarn "到 Releases 页面重新下载安装包，解压后覆盖这个文件夹即可（缺文件时打开菜单也修不了——它自己就要用到这些文件）。"
    exit 1
}
# 解析预检：文件在、不为空，但语法解析不了（典型是 .ps1 丢了 UTF-8 BOM，
# 5.1 按 ANSI 读中文注释会撑破字符串）——点源会抛错，而点源发生在参数分派之前，
# 于是任何子命令都变成"没有输出、退出码 0"。静默退出 0 是最坏的失败方式：
# 计划任务与 CI 会把它读成成功。这里先解析一遍，解析不过就明说并退出 1。
$parseBad = @()
foreach ($libName in $CoreLibs) {
    $libPath = Join-Path $LibDir ("{0}.ps1" -f $libName)
    $tok = $null; $err = $null
    try {
        [void][System.Management.Automation.Language.Parser]::ParseFile($libPath, [ref]$tok, [ref]$err)
    } catch {
        $parseBad += ("lib\{0}.ps1（读不出来）" -f $libName)
        continue
    }
    if ($err -and $err.Count) { $parseBad += ("lib\{0}.ps1（{1}）" -f $libName, $err[0].Message) }
}
if ($parseBad.Count) {
    Write-BootWarn "程序文件损坏，无法解析："
    foreach ($m in $parseBad) { Write-BootWarn ("  " + $m) }
    Write-BootWarn "最常见的原因是 .ps1 被存成了「UTF-8 无 BOM」：中文注释在 PowerShell 5.1 下"
    Write-BootWarn "会按系统代码页读成乱码、撑破语法。到 Releases 页面重新下载安装包覆盖即可。"
    exit 1
}
foreach ($libName in $CoreLibs) { . (Join-Path $LibDir ("{0}.ps1" -f $libName)) }

# ------------------------------------------------------------------------------
# 9. 入口分派
# ------------------------------------------------------------------------------
# 操作锁：安装与更新会改同一批文件，同一时刻只允许一个在跑；撞上就直接退出、不做任何改动。
# 用命名互斥体：进程结束由系统自动释放，不需要（也不该）手工解锁。
# 实测过：上家崩溃后，下一次 WaitOne(0) 直接拿到锁、不抛遗弃异常——不存在"被一次崩溃卡到重启"，
# 所以这里不需要 AbandonedMutexException 分支，保持 catch 全收。
# 互斥体的名字由 base 层的 Get-MutexName 生成（库里的写变量锁也用它，所以它不在入口）。
function Get-OpLock {
    try {
        $m = New-Object System.Threading.Mutex($false, (Get-MutexName "EnvProxyInstallOp"))
        if (-not $m.WaitOne(0)) { return $null }
        return $m
    } catch { return $null }
}
function Exit-IfOpBusy {
    $m = Get-OpLock
    if (-not $m) {
        Write-Styled 'warn' "另一个安装/更新正在进行，请等它结束再试（没有做任何改动）。"
        exit 1
    }
    return $m
}
# 用法判定：错的用法一律退出码 2，不许静默进入监控模式。
# 判据在 base 层的 Get-UsageError（纯函数，两端同形）；这里只负责把参数归一化后交给它。
# 多余或打错的参数要报错退出：powershell -File 对不认识的参数名**不会**报绑定错误，
# 它们只是落进 $args。不拦的话，敲错一个选项就会静默进入监控模式——用户以为在装东西，
# 工具却在后台常驻起来。
# 用法错误要在拿操作锁**之前**判：用法错误既不改文件也不删变量，不该占着锁，
# 也不该因为"另一个安装正在进行"而报成退出码 1（那是动作冲突，不是用法错误）。
$usageCommands = @()
if ($Install)   { $usageCommands += "install" }
if ($Uninstall) { $usageCommands += "uninstall" }
if ($Stop)      { $usageCommands += "stop" }
if ($Status)    { $usageCommands += "status" }
if ($Update)    { $usageCommands += "update" }
if ($Menu)      { $usageCommands += "menu" }
if ($Help)      { $usageCommands += "help" }
if ($Advanced)  { $usageCommands += "advanced" }
if ($Report)    { $usageCommands += "report" }
if ($RepairProfile) { $usageCommands += "repair-profile" }
$usageSwitches = @()
if ($Purge) { $usageSwitches += "purge" }
if ($Yes)   { $usageSwitches += "yes" }
# 前缀缩写护栏：PowerShell 的参数绑定**接受唯一前缀**，于是
#   -Un      -> -Uninstall   少打几个字母就真的卸载
#   -Instal  -> -Install     少打一个字母就真的安装
# 而 $args 是空的，Get-UsageError 完全看不见——它会静默执行破坏性动作。
#
# 判据的难点在于：$MyInvocation.Line 是**整行输入**，不是"脚本收到的参数"。
# 拿整行去比对，下面这些完全正常的用法都会被判成"你把参数写错了"（退出码 2）：
#     .\envproxy.ps1 -Status | Select-Object -First 3      → 报 -First 无法识别
#     .\envproxy.ps1 -Status | Format-Table -AutoSize      → 报 -AutoSize 无法识别
#     pwsh -NoProfile .\envproxy.ps1 -Status               → 报 -NoProfile 无法识别
# 而"看状态并截几行"恰恰是脚本化使用最自然的一步。
#
# 所以判据不是"整行有没有别的命令"，而是取一个**精确窗口**：
#   脚本路径之后，到第一个 shell 元字符之前——那一段才是本脚本收到的参数。
#   `.\envproxy.ps1 -Status | Select-Object -First 3` 的窗口是 ` -Status `，
#   `-First` 落在管道之后、不在窗口里，自然不会误报。
# 这个窗口同时保住了护栏的本职：`-Instal` / `-Un` 就在窗口里，照样被拦下。
# 宁可不拦缩写，也不能把对的用法拦下来——拦错了用户无法通过重试解决。
$knownSwitches = @('Install','Uninstall','Stop','Status','Update','Menu','Help','Advanced','Report','Yes','Purge','RepairProfile')
$rawLine = ""
try { $rawLine = [string]$MyInvocation.Line } catch {}
if ([string]::IsNullOrWhiteSpace($rawLine)) {
    try { $rawLine = [string](Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue).CommandLine } catch {}
}
if (-not [string]::IsNullOrWhiteSpace($rawLine)) {
    # 先定位脚本路径本身：`-File "x.ps1"`、位置式 `x.ps1`、以及带引号/带 .\ 前缀都算。
    $pathMatch = [regex]::Match($rawLine, '(?i)("[^"]*envproxy\.ps1"|[^\swith;|&]*(?:\\|/)?envproxy\.ps1)')
    $tail = $null
    if ($pathMatch.Success) { $tail = $rawLine.Substring($pathMatch.Index + $pathMatch.Length) }
    if ($null -ne $tail) {
        # 窗口截到第一个元字符为止：管道、语句分隔、重定向、括号、子表达式之后都不属于我们。
        $stopAt = $tail.IndexOfAny([char[]]@('|',';','&','>','<','{','}','$','(',')','`'))
        $window = if ($stopAt -ge 0) { $tail.Substring(0, $stopAt) } else { $tail }
        foreach ($m in [regex]::Matches($window, '(?i)(?<=^|\s)--?([A-Za-z][A-Za-z0-9]*)')) {
            $typed = $m.Groups[1].Value
            if (-not ($knownSwitches | Where-Object { $_ -eq $typed })) {
                Write-Styled 'warn' ("无法识别的开关：-" + $typed)
                Write-Styled 'warn' ("可用开关：" + (($knownSwitches | ForEach-Object { "-" + $_ }) -join ' '))
                Write-Styled 'warn' "参数必须写全，不支持缩写（少打几个字母会被当成另一个动作）。"
                exit 2
            }
        }
    }
}
# 命令给了两个以上也算用法错误（mac 侧表现为多余的位置参数）。
$usageCommand = ""
if ($usageCommands.Count -eq 1) { $usageCommand = $usageCommands[0] }
$usageError = Get-UsageError -Command $usageCommand -CommandCount $usageCommands.Count `
                            -Switches $usageSwitches -Extra @($args)
if ($usageError) {
    Write-Styled 'warn' $usageError
    Write-Styled 'warn' "用法：powershell -ExecutionPolicy Bypass -File envproxy.ps1 {-Install|-Uninstall|-Stop|-Status|-Update|-Menu|-Help|-Advanced|-Report|-RepairProfile} [-Yes] [-Purge]"
    exit 2
}
if ($Update) {
    $opMutex = Exit-IfOpBusy
    Update-EnvProxy -AutoYes:$Yes
    # 退出码如实反映结果：计划任务、CI 靠它判断更新成功没有。
    exit $script:UpdateExitCode
}
if ($Install) {
    $opMutex = Exit-IfOpBusy
    Install-EnvProxy
    return
}
if ($Uninstall) {
    $opMutex = Exit-IfOpBusy
    Uninstall-EnvProxy -Purge:$Purge -Yes:$Yes
    return
}
if ($Stop) {
    $opMutex = Exit-IfOpBusy
    if (Test-IsElevated) { Write-Styled 'warn' "当前是管理员身份：动的将是管理员的配置，日常使用请用普通终端重做一遍。" }
    Stop-Monitor
    # 走 Apply-State 而不是裸调删除：拿写变量锁，与监控自愈互斥，不留半套变量。
    $null = Apply-State "off"
    Write-Styled 'title' "代理变量已清除，当前恢复直连。"
    # 提醒已开窗口：它们没被通知，要等下一次回到提示符才更新。
    # 这不是缺陷，是环境变量的固有物理限制（一个进程的环境在它启动时就定了），
    # 与其让人以为"工具坏了"，不如说清楚。
    Write-Styled 'dim' "      已经开着的其它终端窗口，敲一下回车（或随便跑条命令）就跟上。"
    return
}
if ($Status) {
    # 交互终端里走实时刷新（自己动、不用按键）；
    # 输出被重定向 / 无控制台 / 窗口太小时 Show-StatusLive 会自动降级成
    # 今天那份一次性静态输出（逐字节相同，零控制字符），所以两种情况都能走这里。
    Show-StatusLive
    return
}
if ($Menu) {
    Show-Menu
    return
}
if ($Advanced) {
    Show-AdvancedMenu
    return
}
if ($Report) {
    New-ProblemReport
    return
}
if ($Help) {
    Show-Help
    return
}
# 显式修复"配置文件里标记不成对"。这是一个**需要人明确同意**的修复动作：
# 安装/卸载遇到不成对的标记一律"一个字节都不改"（猜必错），但那条护栏让一个
# 可诊断、可修复的状态变成不可达——用户照文档重跑安装，每次都被拒绝。
# 所以给一个显式入口，语义是"我确认这是半截标记，删掉它"，不是"你猜一个"。
if ($RepairProfile) {
    $r = Repair-ProfileMarkers
    if ($r.Fixed.Count -gt 0) {
        Write-Styled 'ok' "[完成] 已摘掉这些文件里的孤立标记（原文件已备份为 *.envproxy.bak）："
        foreach ($p in $r.Fixed) { Write-Styled 'dim' ("        " + $p) }
        Write-Styled 'dim' "        现在打开菜单选 1（安装 / 修复），把它重新写好。"
    }
    if ($r.Failed.Count -gt 0) {
        Write-Styled 'warn' "[未完成] 这些文件没能修好（可能不可写）："
        foreach ($p in $r.Failed) { Write-Styled 'warn' ("        " + $p) }
        Write-Styled 'warn' "        可以手动删掉文件里孤立的 # >>> EnvProxy >>> 那一行。"
    }
    if ($r.Fixed.Count -eq 0 -and $r.Failed.Count -eq 0) {
        Write-Styled 'dim' "没有需要修的：所有配置文件里的标记都是成对的。"
    }
    # 有没修好的就返回非 0。
    #
    # 不返回非 0 的后果：脚本里写成 `envproxy.ps1 -RepairProfile; if ($?) { ... }`
    # 的人会以为修好了，接着去开菜单重装，然后又被同一条护栏拒绝——
    # 退出码是这条命令唯一能被程序读懂的结论，说"成功"而实际失败是谎报。
    # 与 mac 侧同一套语义（那边 repair_hook_markers 有失败就 return 1）。
    if ($r.Failed.Count -gt 0) { exit 1 }
    return
}
# 无参数 = 监控模式（由开机自启调用）。
# 被点号引用（测试加载）时只定义函数、不进入监控。
if ($MyInvocation.InvocationName -eq '.') { return }
Run-MonitorLoop
