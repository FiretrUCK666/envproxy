# ==============================================================================
#  envproxy.ps1 — 命令行自动翻墙（Windows 原生，零依赖，通用版）
# ------------------------------------------------------------------------------
#  子命令（双击配套 .cmd，或在 PowerShell 里运行）：
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Install             一键安装
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Stop                停止监控并删变量
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Uninstall           一键恢复（问日志留不留）
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Uninstall -Purge    一键恢复并连日志一起删（不问）
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Status              查看状态
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Update              检查更新（问过才装）
#     powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Update -Yes         检查更新并跳过确认（供脚本调用）
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
#     - 退出翻墙软件后约 5 秒删除代理变量；"断开连接"（内核仍活着）以流量真相判定，约 30 秒
#       （本地代理响应挂起、探测跑满超时时最坏约 45 秒）
#     - 整个文件夹移动 → 无需任何操作（监控自退 + 定位器开机自动重新定位；
#       自动搜索只覆盖"用户目录 + 其他磁盘根"，搬到范围外时双击一次"安装"接管）
#     - 无常驻依赖、不改系统代理、不需要管理员
# ==============================================================================

param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Stop,
    [switch]$Status,
    [switch]$Update,
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
# 只有入口推算自身目录：库被点源后 $PSScriptRoot 指向 lib\ 自己，用它推路径会把
# monitor 目录指到 lib\ 里去。所以脚本目录在这里算好，各库一律用这个全局。
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
             else { (Get-Location).Path }
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
    Write-Host "到 Releases 页面重新下载安装包覆盖一次即可（也可以先双击 1-安装 试试）。" -ForegroundColor Yellow
    exit 1
}
foreach ($libName in $CoreLibs) { . (Join-Path $LibDir ("{0}.ps1" -f $libName)) }

# ------------------------------------------------------------------------------
# 9. 入口分派
# ------------------------------------------------------------------------------
# 操作锁：安装与更新会改同一批文件，同一时刻只允许一个在跑；撞上就直接退出、不做任何改动。
# 用命名互斥体：进程结束由系统自动释放，不需要（也不该）手工解锁。
function Get-MutexName([string]$Base) {
    # 互斥体按用户隔离：机器级 Global\ 配当前用户 SID。
    # 同一台电脑多个账户各装一份时互不干扰；同一用户多次登录共用同一把锁，单监控语义不变。
    # 拿不到 SID 就回落到无后缀（行为与过去一致），绝不因此罢工。
    try {
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if ($sid) { return ("Global\{0}-{1}" -f $Base, $sid) }
    } catch {}
    return ("Global\{0}" -f $Base)
}
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
if ($Update) {
    $opMutex = Exit-IfOpBusy
    Update-EnvProxy -AutoYes:$Yes
    return
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
    Stop-Monitor
    # 走 Apply-State 而不是裸调删除：拿写变量锁，与监控自愈互斥，不留半套变量。
    Apply-State "off"
    Write-Host "代理变量已清除，当前恢复直连。" -ForegroundColor Cyan
    return
}
if ($Status) {
    Show-Status
    return
}
# 无参数 = 监控模式（由开机自启调用）。
# 被点号引用（测试加载）时只定义函数、不进入监控。
if ($MyInvocation.InvocationName -eq '.') { return }
Run-MonitorLoop
