# ==============================================================================
#  base.ps1 — 基础层：契约常量、纯函数、文件读写助手
#  由入口 envproxy.ps1 按固定顺序点源加载，不单独运行。
#  本层必须加载期安全（无顶层副作用、不依赖 Windows 专有环境），自检只点源这一层。
# ==============================================================================

# ------------------------------------------------------------------------------
# 0.5 文件与路径的唯一入口（治本：所有读写都从这里走，内部一律 -LiteralPath）
# 使用者能给安装文件夹改名，名字里可能出现 [ ] * ? 这类字符——在 PowerShell 里它们是通配符，
# 直接用 Test-Path / Get-Content / Remove-Item 会出现"文件明明在、却说不存在"，甚至删错对象。
# 因此凡是路径可能来自用户环境的读写（安装根、注册表记录、命令行、搜索结果），
# 一律走下面四个函数；新代码直接调它们就不会踩到通配符语义。
# 门禁会扫描"关键 cmdlet 是否直接吃裸变量路径"，绕过去当场失败。
# ------------------------------------------------------------------------------
function Test-Item([string]$Path) {
    if (-not $Path) { return $false }
    try { return [bool]([System.IO.File]::Exists($Path) -or [System.IO.Directory]::Exists($Path)) } catch { return $false }
}
# 注册表键是否存在。**不能用 Test-Item 判注册表**：它问的是文件系统，
# 对 HKCU:\ 这类路径永远返回假。照着它去判断"键在不在"，已存在的键会被当成不存在，
# 于是下一步的 New-Item -Force 把键清空重建——连带删掉里面的快照数据。
function Test-RegKey([string]$Path) {
    if (-not $Path) { return $false }
    try { return [bool](Test-Path -LiteralPath $Path) } catch { return $false }
}
function Read-Text([string]$Path) {
    # 读文本：显式 UTF-8，绝不交给系统代码页去猜（中文 Windows 上会读成乱码）
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}
function Write-Text([string]$Path, [string]$Text, [bool]$WithBom = $false) {
    # 原子写：先写同目录临时文件，再整体替换——中途断电也不会留下半个文件。
    # 需要 BOM 的地方（PowerShell 5.1 要认的脚本）由调用方显式声明，不靠编辑器的默认行为。
    $dir = Split-Path -Parent $Path
    if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [System.IO.Directory]::CreateDirectory($dir) | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($WithBom)
    $tmp = "$Path.tmp$PID"
    [System.IO.File]::WriteAllText($tmp, $Text, $enc)
    if ([System.IO.File]::Exists($Path)) {
        # 第三参数是「备份文件路径」：传 $null 会被绑成空字符串并抛异常（5.1 与 7 都如此，
        # 实测 "The path is not of a legal form"），于是每次都落到下面的非原子兜底分支。
        # 必须用 [NullString]::Value 才是真正的"不要备份"。
        try { [System.IO.File]::Replace($tmp, $Path, [NullString]::Value) }
        catch { [System.IO.File]::Copy($tmp, $Path, $true); [System.IO.File]::Delete($tmp) }
    } else {
        [System.IO.File]::Move($tmp, $Path)
    }
}
function Remove-ItemSafe([string]$Path) {
    if (-not $Path) { return }
    try {
        if ([System.IO.Directory]::Exists($Path)) { [System.IO.Directory]::Delete($Path, $true) }
        elseif ([System.IO.File]::Exists($Path)) { [System.IO.File]::Delete($Path) }
    } catch {}
}

# ------------------------------------------------------------------------------
# 2. 读写用户级环境变量（注册表 HKCU\Environment，不需要管理员）
# ------------------------------------------------------------------------------
# 变量名一律用规范大写拼写；一张表同时是「注入清单」与「删除清单」，两者不可能再漂移。
#
# DIVERGE(Win): Windows 的环境命名空间大小写不敏感（注册表 HKCU\Environment 尤其如此），
# 同名不同大小写就是同一个变量：写两遍只会互相覆盖，注册表里始终只有一个键。
# 而"大小写各写一份"会在运行期留下**同名两种拼写的重复环境块**——.NET 系宿主按
# "大小写不敏感字典"建表时直接抛 "An item with the same key has already been added"，
# 连 Get-ChildItem Env: 都枚举不出来；子进程继续继承同一个块，一个终端窗口里跑的东西
# 一起中招。故 Windows 侧对一个逻辑变量只写一个规范拼写，共 5 个变量名。
# DIVERGE(Mac): macOS 的 launchctl 与环境块真大小写敏感，大小写各一份确有意义，Mac 侧写 9 个。
$ProxyVarNames = @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "NODE_USE_ENV_PROXY")

# 本机地址直连的默认例外集，写法遵循 NO_PROXY 的通行规范：IPv6 地址**裸写**。
# 裸写是各家的共同要求——httpx 的规范示例就是 `NO_PROXY=example.com,::1,localhost,...`，
# 而且它会自己给 IPv6 补上方括号去构造内部模式（见其 _utils.is_ipv6_hostname 分支）；
# 预先写成 `[::1]` 会被当成普通域名，生成非法模式，反而让每一次请求都抛
# `InvalidURL: Invalid port: ':1]'`。也就是说方括号属于 URL 字面量的写法，
# 在 NO_PROXY 里是写错了位置，不是"另一种合法写法"。
$DefaultNoProxy = "localhost,127.0.0.1,::1"

# 帮助每一屏的行数上限。超过这个数，终端会把底部的「怎么退出」切掉——
# 用户会以为帮助卡死，其实只是没画出来。30 这个数字的来历：常见终端 24-30 行，
# 留出提示符与命令回显后剩这么多；它与 Mac 侧 HELP_MAX_LINES 必须一致，
# 门禁 6 核对。改这里就是改「帮助一屏能放多少」，不是调样式。
$HelpMaxLines = 30

# 日志体积上限与截断后保留的行数。写成具名常量而不是散在代码里的 200KB / 200：
# 文档里印着这两个数，两侧也各写了一遍，散着放就一定会有一天改一处漏一处。
# 与 Mac 侧 LOG_MAX_BYTES / LOG_TAIL_LINES 同口径，门禁 6 核对。
$LogMaxBytes = 200KB
$LogTailLines = 200

# 屏幕角色的配色表：所有用户可见页面（菜单、帮助、状态、安装、卸载、更新）都从这里取色。
# 为什么要有这张表：颜色散在各页面时，同一个概念会在不同页面用不同颜色——用户每换一屏
# 就要重新认一遍"哪一行是能照抄的命令"。角色名与 Mac 侧 STYLE_ROLES 一致（门禁 6 核对），
# 于是"两端口径一致"不靠人记得住，而是靠没有第二个地方可以改。
# 取空串 = 用终端自己的默认前景色（不写颜色），避免与使用者的配色方案打架。
$StyleMap = [ordered]@{
    title   = 'Cyan'      # 每屏开头那一行等号标题
    heading = 'Cyan'      # 段标题
    item    = 'White'     # 编号条目
    key     = 'White'     # 两列的左列（PowerShell / 监控进程…）
    value   = 'White'     # 要强调的值（名字、版本号）
    cmd     = 'Cyan'      # 能整行复制去跑的命令 / 编号
    ok      = 'Green'     # 做成了
    warn    = 'Yellow'    # 要留意
    dim     = 'DarkGray'  # 次要说明，不该抢注意力
    text    = ''          # 正文：跟终端默认色一致
}
$StyleRoles = @('title', 'heading', 'item', 'key', 'value', 'cmd', 'ok', 'warn', 'dim', 'text')

# 「最新版本 : 检查失败（…）」这一句的唯一出处。
# 早先它在状态页与更新入口各硬编码一遍（共四处），改一次措辞要改四处，
# 漏一处就是"同一个故障，状态页和更新入口两种说法"。
# 句子外壳（前缀、括号、来源名）收在这里；失败原因本身仍由 Get-UpdateFailureMessage 生成。
$UPD_FAIL_ALL_SOURCES = "所有更新源"
function Format-VersionCheckFailure([string]$Kind) {
    # 句子外壳（前缀、来源名、括号）收在这一处；具体原因由 Get-UpdateFailureMessage
    # 按失败类别生成——它需要一个来源名才能把话说完整（"连不上 <来源>"），
    # 所以来源名必须传进去，不能在外面拼。
    return ("最新版本 : " + (Get-UpdateFailureMessage $Kind $UPD_FAIL_ALL_SOURCES))
}

function Get-StyleColor([string]$Role) {
    if ($StyleMap.Contains($Role)) { return $StyleMap[$Role] }
    return ''
}

# 按角色输出一行。所有给人看的文字都走这里，于是"换个颜色"只要改上面那张表。
function Write-Styled([string]$Role, [string]$Text, [switch]$NoNewline) {
    $c = Get-StyleColor $Role
    if ($c) { Write-Host $Text -ForegroundColor $c -NoNewline:$NoNewline }
    else { Write-Host $Text -NoNewline:$NoNewline }
}

# 是否跑在提权身份下：提权后 HKCU 指向管理员的配置，装/停/卸动的都是"另一个人"的状态。
# 只做提醒不拦截——机器上只有一个日常用户时，提醒一句就够了。
function Test-IsElevated {
    try {
        return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-MutexName([string]$Base) {
    # 互斥体按用户隔离：机器级 Global\ 配当前用户 SID。
    # 同一台电脑多个账户各装一份时互不干扰；同一用户多次登录共用同一把锁，单监控语义不变。
    # 拿不到 SID 就回落到无后缀，绝不因此罢工。
    # 放在 base：入口的安装/更新锁与库里的写变量锁都用它，库不许回头依赖入口。
    try {
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if ($sid) { return ("Global\{0}-{1}" -f $Base, $sid) }
    } catch {}
    return ("Global\{0}" -f $Base)
}

# 小写化 + 去空白，用于合并去重（比较时大小写不敏感）
function Get-NormalizedNoProxyEntries([string]$Value) {
    $out = @()
    foreach ($part in ($Value -split ',')) {
        $t = $part.Trim()
        if ($t) { $out += $t.ToLowerInvariant() }
    }
    return $out
}

# NO_PROXY 只增不减：已存在的条目原样保留，缺失的默认条目补上。
# 这样做是因为环境变量是用户级共享资源——用户自己加的例外（公司内网等）与
# 别的工具写下的例外都必须留着，本工具只负责"本机地址一定直连"这一件事。
# 后果是两条：用户手动加例外不会被下一轮冲掉，也不会与轮次之间来回互相覆盖。
function Merge-NoProxy([string]$Existing, [string]$Default) {
    $parts = @()
    foreach ($p in ($Default -split ',')) { $t = $p.Trim(); if ($t) { $parts += $t } }
    $seen = Get-NormalizedNoProxyEntries $Default
    foreach ($p in ($Existing -split ',')) {
        $t = $p.Trim()
        if (-not $t) { continue }
        if ($seen -notcontains $t.ToLowerInvariant()) { $parts += $t; $seen += $t.ToLowerInvariant() }
    }
    return ($parts -join ',')
}

# 本机回环地址的两种写法。注入端按"实际能连上的那个地址"拼 URL：只绑 ::1 的代理
# 在 IPv4 上主动拒绝，所以注入值可能是 http://[::1]:port。
# 归属判定的"形状"这一层必须同时认这两种——只认 127.0.0.1 的话，IPv6 注入的值会被判成
# "不是我们的"，既清不掉、也认不出，两个后果都是静默的。
function Test-LoopbackProxyUrl([string]$Value) {
    if (-not $Value) { return $false }
    # 必须用 StartsWith，不能用 -like：PowerShell 通配符里 [ ] 是字符类的定界符，
    # "http://[::1]:*" 会被解释成"http://" + 一个属于 {:,1} 的字符 + ":任意"，
    # 于是它既不匹配真正的 http://[::1]:7078，反而可能匹配上别的东西。
    # 这里要的是字面前缀，就用字面比较。
    return ($Value.StartsWith("http://127.0.0.1:") -or $Value.StartsWith("http://[::1]:"))
}

function Get-ProxyVarTable([string]$Port, [string]$ProxyUrl = "") {
    # 代理值统一用 http:// 协议写法：本地代理端口（MonoCloud/Clash 等）几乎都是
    # 混合端口，HTTP 与 SOCKS5 都能应答；而部分工具（如 dsh/新版 Node 系）只认
    # http:// 写法、不支持 socks5://（会提示不支持并跳过）。统一 http:// 兼容面最大。
    # 地址由调用方现场探测后传进来（见 probe 层 Get-ProxyUrlForPort）：只绑 ::1 的代理
    # 在 IPv4 上连不上，写死 127.0.0.1 会注入一个用不了的地址。
    # 不传时按 127.0.0.1 走——纯函数调用（测试）保持这个默认值，行为不变。
    $http = if ($ProxyUrl) { $ProxyUrl } else { "http://127.0.0.1:$Port" }
    $table = [ordered]@{}
    foreach ($n in $ProxyVarNames) { $table[$n] = $http }
    # 本机地址直连（与 README 变量表一致）
    $table["NO_PROXY"] = $DefaultNoProxy
    # 让新版 Node 系工具的原生 fetch 也自动读环境变量代理（老版本自动忽略）
    $table["NODE_USE_ENV_PROXY"] = "1"
    return $table
}

# 文件的 sha256（小写十六进制）。
# 不用 Get-FileHash：它是 Microsoft.PowerShell.Utility 模块导出的命令，
# 而 PSModulePath 里只要排着别的 PowerShell 版本的模块目录（常见于从 pwsh 7 里再开 5.1），
# 模块自动加载就会挑中那个二进制模块并加载失败——命令直接"找不到"，
# 不是报错而是静默缺失：校验值那一步会跟着塌掉。
# 直接用 .NET 的 SHA256 自己算：任何环境都拿得到，不依赖模块自动加载。
function Get-Sha256Hex([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try { $bytes = $sha.ComputeHash($fs) } finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}

# ------------------------------------------------------------------------------
# 5. 入口用法判定（纯函数，两端同形）
# ------------------------------------------------------------------------------
# 入口所有的用法错误都从这里出：返回 $null = 用法正确；返回字符串 = 该报的错
# （入口打印它、退出 2）。输入是四样归一化后的东西：
#   Command       用户要的命令（install/uninstall/stop/status/update/menu；空 = 监控模式）
#   CommandCount  命令给了几个（>1 = 用法错误）
#   Switches      用户给的开关名（purge / yes）
#   Extra         不认识的参数
# 抽成纯函数是有原因的：直接跑入口验"合法用法必须放行"会真的装、卸、起监控，
# 副作用落在用户机器上（卸载删日志、更新改安装区），这类断言根本没法写。
# 判定本身没有副作用，纯函数才能把"必须拒"和"必须放行"两个方向都钉住。
function Get-UsageError {
    param(
        [string]$Command = "",
        [int]$CommandCount = 0,
        [string[]]$Switches = @(),
        [string[]]$Extra = @()
    )
    if ($CommandCount -gt 1) { return "一次只给一个命令。" }
    if ($Extra.Count -gt 0) {
        # 空参数也要说清是哪里的空：直接拼出来会只剩一个冒号。
        $parts = foreach ($e in $Extra) { if ($e -eq "") { '""' } else { $e } }
        return ("无法识别的参数：{0}" -f ($parts -join ' '))
    }
    # 开关必须跟着它的命令：-Purge 只配 -Uninstall，-Yes 只配 -Update 或 -Uninstall。
    # 单独给会一路落到监控模式：用户以为在清日志或在答"是"，工具却把监控起来了。
    if ("purge" -in $Switches -and $Command -ne "uninstall") {
        return "-Purge 只在卸载时才有意义：它表示连日志一起删。请用 -Uninstall -Purge。"
    }
    # -Yes 在两个地方有意义：跳过更新的确认，以及在**没法提问的环境里**明确表达
    # "我知道我在做什么"（卸载）。后者不是多余：卸载在非交互环境下会被拒绝，
    # 没有这个开关，脚本和 CI 就永远卸不掉（而"问不到人就默默执行"更糟，实测过）。
    if ("yes" -in $Switches -and $Command -notin @("update", "uninstall")) {
        return "-Yes 只在检查更新或卸载时才有意义：它表示跳过确认。请用 -Update -Yes 或 -Uninstall -Yes。"
    }
    return $null
}

# 版本比较：按 . 分段逐段数值比（"1.10" > "1.9"；字符串比会错）。
# 返回 1（A 新）/ 0（相等）/ -1（A 旧）。
# 注意：PowerShell 变量名不分大小写，$a 即 $A（[string] 参数），赋值会被转回字符串，
# 因此循环变量必须另起名（$va/$vb），否则逐段数值比会退化成字符串比（"10" < "9"）。
function Compare-Versions([string]$A, [string]$B) {
    # 段值用 64 位整数并做溢出兜底：远端 tag 是外部输入，一个 20 位的数字会让 [int] 转换
    # 抛异常，而调用点不在 try 里——整个更新入口会因此崩掉。超范围按"最大"处理，不抛。
    $pa = @(); $pb = @()
    foreach ($s in ($A -split '\.')) {
        [long]$v = 0
        if ($s -match '^(\d+)$') { if (-not [long]::TryParse($Matches[1], [ref]$v)) { $v = [long]::MaxValue } }
        $pa += $v
    }
    foreach ($s in ($B -split '\.')) {
        [long]$v = 0
        if ($s -match '^(\d+)$') { if (-not [long]::TryParse($Matches[1], [ref]$v)) { $v = [long]::MaxValue } }
        $pb += $v
    }
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $va = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
        $vb = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
        if ($va -gt $vb) { return 1 }
        if ($va -lt $vb) { return -1 }
    }
    return 0
}

# 真的能对着一台终端问问题吗？
# 为什么放在 base 层：ops（菜单/帮助）和 update（更新前确认）都要问这个问题，
# 而 update 在 ops 之前加载，调不到 ops 里的函数。放这里两边都能用，判据也只有一份。
# 为什么不用 [Console]::IsInputRedirected 单独判断：它只回答"stdin 是不是重定向到了
# 文件/管道"，不回答"有没有可读的终端"。用任务计划或服务方式启动时（CreateProcess
# 不传 stdin），进程可能被判成交互，于是进了 Read-Host —— 而那个环境下 Read-Host
# 既不返回也不抛异常，进程静默挂死。所以还要确认控制台缓冲区真的存在。
function Test-CanPrompt {
    try {
        if ([Console]::IsInputRedirected) { return $false }
        # 没有控制台缓冲区时访问这个属性会抛异常（"句柄无效"）。
        $null = [Console]::WindowWidth
        return $true
    } catch {
        return $false
    }
}
