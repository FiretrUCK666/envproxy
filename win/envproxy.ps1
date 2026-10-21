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
    [switch]$Yes,
    [switch]$Purge
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
#     lib\ops.ps1      安装/停止/卸载/状态编排
#   库清单的唯一权威处是下面的 $CoreLibs；门禁会核对它与 lib\ 实际内容一致。
# ------------------------------------------------------------------------------
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
$CoreLibs = @("base", "probe", "env", "runtime", "package", "update", "ops")
# 加载前先验完整性：缺文件时说人话，而不是抛一句看不懂的语法错误。
$missingLib = @()
foreach ($libName in $CoreLibs) {
    $libPath = Join-Path $LibDir ("{0}.ps1" -f $libName)
    if (-not (Test-Path -LiteralPath $libPath)) { $missingLib += ("lib\{0}.ps1" -f $libName) }
    elseif ((Get-Item -LiteralPath $libPath).Length -eq 0) { $missingLib += ("lib\{0}.ps1（空文件）" -f $libName) }
}
if ($missingLib.Count) {
    Write-Host "安装不完整，缺少程序文件：" -ForegroundColor Yellow
    foreach ($m in $missingLib) { Write-Host ("  " + $m) -ForegroundColor Yellow }
    Write-Host "这个文件夹没有完整拷过来，或者文件被删掉了。" -ForegroundColor Yellow
    Write-Host "到 Releases 页面重新下载安装包，解压后覆盖这个文件夹即可（缺文件时打开菜单也修不了——它自己就要用到这些文件）。" -ForegroundColor Yellow
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
    Write-Host "程序文件损坏，无法解析：" -ForegroundColor Yellow
    foreach ($m in $parseBad) { Write-Host ("  " + $m) -ForegroundColor Yellow }
    Write-Host "最常见的原因是 .ps1 被存成了「UTF-8 无 BOM」：中文注释在 PowerShell 5.1 下" -ForegroundColor Yellow
    Write-Host "会按系统代码页读成乱码、撑破语法。到 Releases 页面重新下载安装包覆盖即可。" -ForegroundColor Yellow
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
        Write-Host "另一个安装/更新正在进行，请等它结束再试（没有做任何改动）。" -ForegroundColor Yellow
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
$usageSwitches = @()
if ($Purge) { $usageSwitches += "purge" }
if ($Yes)   { $usageSwitches += "yes" }
# 前缀缩写护栏：PowerShell 的参数绑定**接受唯一前缀**，于是
#   -Un      -> -Uninstall   少打几个字母就真的卸载
#   -Instal  -> -Install     少打一个字母就真的安装
# 而 $args 是空的，Get-UsageError 完全看不见——它会静默执行破坏性动作。
# 这里回读原始命令行，逐个确认每个 -开关 都**精确**等于已声明的名字。
$knownSwitches = @('Install','Uninstall','Stop','Status','Update','Menu','Help','Yes','Purge')
$rawLine = ""
try { $rawLine = [string]$MyInvocation.Line } catch {}
if ([string]::IsNullOrWhiteSpace($rawLine)) {
    try { $rawLine = [string](Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue).CommandLine } catch {}
}
if (-not [string]::IsNullOrWhiteSpace($rawLine)) {
    # 只看 -File <脚本> 之后的那一段：前面是 powershell.exe 自己的参数
    # （-NoProfile、-ExecutionPolicy 等），不该拿我们的开关表去校验它们。
    $scriptArgs = $rawLine
    if ($rawLine -match '(?i)-File\s+("[^"]+"|\S+)(.*)$') {
        $scriptArgs = $Matches[2]
    } elseif ($rawLine -match '(?i)-Command\b') {
        # -Command 形态：参数已经是代码的一部分，不做原文校验（避免误判）。
        $scriptArgs = ""
    }
    foreach ($m in [regex]::Matches($scriptArgs, '(?i)(?<=^|\s)--?([A-Za-z][A-Za-z0-9]*)')) {
        $typed = $m.Groups[1].Value
        if (-not ($knownSwitches | Where-Object { $_ -eq $typed })) {
            Write-Host ("无法识别的开关：-" + $typed) -ForegroundColor Yellow
            Write-Host ("可用开关：" + (($knownSwitches | ForEach-Object { "-" + $_ }) -join ' ')) -ForegroundColor Yellow
            Write-Host "参数必须写全，不支持缩写（少打几个字母会被当成另一个动作）。" -ForegroundColor Yellow
            exit 2
        }
    }
}
# 命令给了两个以上也算用法错误（mac 侧表现为多余的位置参数）。
$usageCommand = ""
if ($usageCommands.Count -eq 1) { $usageCommand = $usageCommands[0] }
$usageError = Get-UsageError -Command $usageCommand -CommandCount $usageCommands.Count `
                            -Switches $usageSwitches -Extra @($args)
if ($usageError) {
    Write-Host $usageError -ForegroundColor Yellow
    Write-Host "用法：powershell -ExecutionPolicy Bypass -File envproxy.ps1 {-Install|-Uninstall|-Stop|-Status|-Update|-Menu|-Help} [-Yes] [-Purge]" -ForegroundColor Yellow
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
    Uninstall-EnvProxy -Purge:$Purge
    return
}
if ($Stop) {
    $opMutex = Exit-IfOpBusy
    if (Test-IsElevated) { Write-Host "当前是管理员身份：动的将是管理员的配置，日常使用请用普通终端重做一遍。" -ForegroundColor Yellow }
    Stop-Monitor
    # 走 Apply-State 而不是裸调删除：拿写变量锁，与监控自愈互斥，不留半套变量。
    Apply-State "off"
    Write-Host "代理变量已清除，当前恢复直连。" -ForegroundColor Cyan
    # 提醒已开窗口：它们没被通知，要等下一次回到提示符才更新。
    # 这不是缺陷，是环境变量的固有物理限制（一个进程的环境在它启动时就定了），
    # 与其让人以为"工具坏了"，不如说清楚。
    Write-Host "      已经开着的其它终端窗口，敲一下回车（或随便跑条命令）就跟上。" -ForegroundColor DarkGray
    return
}
if ($Status) {
    Show-Status
    return
}
if ($Menu) {
    Show-Menu
    return
}
if ($Help) {
    Show-Help
    return
}
# 无参数 = 监控模式（由开机自启调用）。
# 被点号引用（测试加载）时只定义函数、不进入监控。
if ($MyInvocation.InvocationName -eq '.') { return }
Run-MonitorLoop
