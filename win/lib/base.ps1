# ==============================================================================
#  base.ps1 — 基础层：契约常量、纯函数、文件读写助手、屏幕输出的基础能力
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
# 注册表落点：每一样只声明一次（下面四个子键），别处一律从它派生。
#
# 以前 "Environment" 在 6 个地方各写一遍、"Software\EnvProxy\..." 在 5 处各写一遍。
# 同一个地址散着写，改一处漏一处只是时间问题；更要紧的是——自检要把
# "写入 / 删除 / 快照还原 / 终端钩子"整套真实路径跑一遍，却**不能碰使用者的真环境**
# （它原来靠 finally 还原，而 finally 挡不住 Ctrl+C：按一次中断，代理变量就留在
#  被删状态，屏幕上一句话都没有）。地址只要能被指向别处，自检就能整段跑在临时键上，
# 而调用的仍是同一条生产通道，不是另写一套。
#
# 路径用函数现算、不用变量缓存：变量是库加载时求值一次的普通赋值，
# 自检在加载之后才改道，变量不会跟着变（mac 侧自检注释里点名过这个地雷）。
$UserEnvSubKey       = 'Environment'
$OwnedRegSubKey      = 'Software\EnvProxy\Owned'
$PrevEnvSubKey       = 'Software\EnvProxy\Backup'
$ScriptPathRegSubKey = 'Software\EnvProxy'

function Get-RegPath([string]$SubKey) { return ('HKCU:\' + $SubKey) }

# 同一落点的另一种形态：.NET 的 OpenSubKey 吃"HKCU:\"后面的裸子键，
# 不吃 PowerShell 提供程序路径。两条形态都从上面的子键声明派生，别处不许再抄字面量
# ——抄一份的后果自检与生产会走两个不同位置，跑一次自检就把使用者真实的键写成测试值。
function Get-RegSubKeyPath([string]$SubKey) { return $SubKey }
function Get-OwnedRegSubKey { return (Get-RegSubKeyPath $OwnedRegSubKey) }

# 家目录下那个我们自己用的文件夹（Git Bash 同步脚本住在这里）。
# 与注册表落点同理：做成可替换的，自检才能把 install 那条真实路径跑一遍
# 而不往使用者家目录写字。默认值就是真实位置，正常安装行为一个字节不变。
$ToolHomeDirName = '.envproxy'
function Get-ToolHomeDir { return (Join-Path ([string]$env:USERPROFILE) $ToolHomeDirName) }

# 镜像文件 terminal.env 住在 %LOCALAPPDATA%\EnvProxy（给 Git Bash 的钩子读）。
# 同样可替换：它是安装与状态翻转都会写的文件，自检不该写进使用者真实的那一份。
# 顶层取值必须加载期安全：CI 会在 Linux 上点源本文件，那里没有 LocalApplicationData。
function Get-InstallDir {
    $base = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
    return (Join-Path $base 'EnvProxy')
}
function Get-UserEnvKeyPath { return (Get-RegPath $UserEnvSubKey) }
function Get-OwnedRegKeyPath { return (Get-RegPath $OwnedRegSubKey) }
function Get-PrevEnvRegKeyPath { return (Get-RegPath $PrevEnvSubKey) }
function Get-ScriptPathRegKeyPath { return (Get-RegPath $ScriptPathRegSubKey) }
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
# 其中"值是代理地址"的那几个。另两个角色不同：NO_PROXY 是例外清单，
# NODE_USE_ENV_PROXY 是开关。归属判定要按角色分派——地址看形状、清单逐项减、
# 开关只认 1——所以"哪些名字是地址类"必须只定义一处。
# Mac 侧对应 $PROXY_ADDR_VAR_NAMES；两侧同形，门禁 6 核对。
$ProxyAddrVarNames = @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")

# "读一个当前代理地址"该读哪个变量——只定义这一处。
#
# 为什么需要它：三个地址变量注入时值相同，取哪个都"能跑"，于是不同地方各写各的，
# 悄悄分叉了：Get-EnvProxyValue 取的是 $ProxyVarNames[0]（HTTP_PROXY），
# 而生成启动脚本的那一处写死了 HTTPS_PROXY。同一个程序对"主代理变量是哪个"
# 给出两个不同答案，谁都没报错——将来只改其中一处，另一处就会静默读到别的值。
# 取 HTTP_PROXY 的理由：它在变量表里排第一，且是最通用、兼容面最广的那个；
# 三个地址变量由同一张表整批写入，读第一个与读第二个拿到的必然是同一个串。
$PrimaryProxyVarName = $ProxyAddrVarNames[0]

# NODE_USE_ENV_PROXY 的取值。就是"打开"的意思，但只定义这一处：
# 注入端（Get-ProxyVarTable）与启动器生成端都要写它，各写一个字面量 '1'
# 就会出现"终端里是 1、快捷方式里是 true"这种只有某一种启动方式才失效的分叉。
$NodeUseEnvProxyValue = '1'

# 本机地址直连的默认例外集，写法遵循 NO_PROXY 的通行规范：IPv6 地址**裸写**。
# 裸写是各家的共同要求——httpx 的规范示例就是 `NO_PROXY=example.com,::1,localhost,...`，
# 而且它会自己给 IPv6 补上方括号去构造内部模式（见其 _utils.is_ipv6_hostname 分支）；
# 预先写成 `[::1]` 会被当成普通域名，生成非法模式，反而让每一次请求都抛
# `InvalidURL: Invalid port: ':1]'`。也就是说方括号属于 URL 字面量的写法，
# 在 NO_PROXY 里是写错了位置，不是"另一种合法写法"。
$DefaultNoProxy = "localhost,127.0.0.1,::1"

# 帮助每一屏的行数上限。超过这个数，终端会把底部的「怎么退出」切掉——
# 用户会以为帮助卡死，其实只是没画出来。
# 40 的来历：量的是 Format-HelpTopic 的整屏输出（含标题行与结尾两行导航），
# 正文实际剩 35 行。常见终端 30-40 行，扣掉提示符与命令回显之后放得下；
# 24 行的小窗口里要往下滚一点才看得到「怎么回目录」——那是可选的内容损失，
# 换来的是块之间留得住空行、每块读起来有呼吸感。这个取舍是有意的：
# 挤在一起的正文比多滚一屏更难读。所以排版优先，内容超了就调这个数，
$HelpMaxLines = 40

# ---- 屏幕渲染层的常量（两侧都有实现：Mac 侧见 mac/lib/base.sh 同名同义的一组）----
# 最小可用终端：宽度不够时一折行就认不出「标签 : 内容」的结构，宁可不刷新。
# 40 与 Get-ConsoleWidth 的下限同一个数：那里也认为 40 是能正常阅读的底线。
$ScreenMinWidth = 40
# 最小可用高度：低于这个数，状态页（正常约 15 屏行、出问题时约 23 屏行）连正文都放不下。
# 20 的依据：标题 1 + 结论 1 + 空行 1 + 六项状态 6 + 版本 1 + 日志段 5 + 提示 1 = 16，
# 再留 4 行给多出来的问题说明；低于 20 就只能靠裁剪硬塞，不如退回静态。
$ScreenMinHeight = 20
# 内容区下方要留的行数：一行给「按 0 返回」的提示，一行给光标。
$ScreenBottomMargin = 2
# 「等一小会儿看有没有按键」的轮询间隔（毫秒）。
# 150 的来源：比一次屏幕重画（实测 0.06–3 毫秒）大两个数量级，
# 不会空转烧 CPU；又足够小到按键感觉得到即时。
# Mac 侧若补实时刷新，对应的常量受 bash 3.2 的 read -t 只认整数秒限制，
# 值必然不同（DIVERGE(Mac): bash 3.2 没有亚秒超时）。
$ScreenPollMs = 150
# 读键连续失败多少次就放弃等键。用于「控制台句柄中途失效」这种没法恢复的情况：
# 继续空转只会把一个核吃满，不如交回 Error 让调用方退出循环。
$ScreenKeyFailLimit = 3
# 实时刷新间隔（毫秒）。固定 2000，不做智能变速：
# 监控本身 2-3 秒才更新一次状态快照，刷得比它快没有意义；
# 而固定值让「多久能看到变化」这件事可预期，不会时快时慢。
$StatusRefreshIntervalMs = 2000
# 上一帧画完时的窗口尺寸。用它判断「终端有没有被改过大小」：
# 尺寸一变，屏幕上第几行是什么就全变了，必须整帧重画（见 Write-ScreenFrame）。
# 初值故意留空（$null）：第一次画必然与它不等，于是第一帧天然是整帧重画。
$script:ScreenLastWidth = $null
$script:ScreenLastHeight = $null

# 日志体积上限与截断后保留的行数。写成具名常量而不是散在代码里的 200KB / 200：
# 文档里印着这两个数，两侧也各写了一遍，散着放就一定会有一天改一处漏一处。
# 与 Mac 侧 LOG_MAX_BYTES / LOG_TAIL_LINES 同口径，门禁 6 核对。
$LogMaxBytes = 200KB
$LogTailLines = 200

# 配色分两层：角色 -> 颜色名 -> 本平台怎么写。
#
# 为什么要多这一层名字：两侧写颜色的方式毫无共同语言（这里是 [ConsoleColor] 枚举，
# Mac 侧是 ANSI 数字），于是"两端口径一致"只能靠人记得住，门禁也只比得了角色名、
# 一个颜色都比不了——实测就这么放过去一次：`cmd` 从绿改成了青，命令与标题同色，
# 用户在屏幕上一眼分不清，两侧门禁却全绿。多这一层之后，两侧共享的是颜色名，
# 门禁直接比颜色名，"换个颜色只改一处"和"两侧不许分叉"才同时成立。
$ColorCodes = @{
    cyan        = 'Cyan'      # 标题、段标题
    brightwhite = 'White'     # 条目、左列、要强调的值
    green       = 'Green'     # 能整行复制的命令、做成了
    yellow      = 'Yellow'    # 要留意
    darkgray    = 'DarkGray'  # 次要说明
    none        = ''          # 终端自己的默认前景色，不与使用者的配色方案打架
}

# 颜色名 -> ANSI 前景码。与 $ColorCodes 是同一套颜色名的两种写法：
#   Write-Styled 那条路走 [ConsoleColor]（逐段 Write-Host，带 NoNewline）；
#   屏幕渲染层那条路走 ANSI（整帧拼一个字符串一次写出，实测快 39 倍）。
#
# 码值必须与 [ConsoleColor] 的语义**逐项对上**，否则同一个程序里会出现两种"青"：
# .NET 的 Cyan/Green/Yellow 都是亮色（控制台调色板里亮的那一档），对应 ANSI 的 9x 段；
# 写成 3x 段就是暗青/暗绿/暗黄，肉眼一眼能看出差别——实测踩过这一条，
# cyan 写成 36，实时页的标题比菜单/帮助的标题暗一档。
# White 在 .NET 里本来就是亮白（97），DarkGray 对应 90。
$ColorAnsi = @{
    cyan        = '96'   # 亮青，等同 [ConsoleColor]::Cyan
    brightwhite = '97'   # 亮白，等同 [ConsoleColor]::White
    green       = '92'   # 亮绿，等同 [ConsoleColor]::Green
    yellow      = '93'   # 亮黄，等同 [ConsoleColor]::Yellow
    darkgray    = '90'   # 灰，等同 [ConsoleColor]::DarkGray
    none        = ''
}

# 角色 -> 颜色名。顺序即声明顺序，$StyleRoles 从它派生，不另抄一份。
# cmd 必须是绿色，且不许与其余任何角色同色：屏幕上的绿色就是"这一整行能复制去跑"。
# 用户每换一屏都要重新认这件事，所以它是可读性问题，不是审美问题。
# 门禁 6 与两侧自检都钉住这两条，改色当场红。
$StyleMap = [ordered]@{
    title   = 'cyan'        # 每屏开头那一行等号标题
    heading = 'cyan'        # 段标题
    item    = 'brightwhite' # 编号条目
    key     = 'brightwhite' # 两列的左列（PowerShell / 监控进程…）
    value   = 'brightwhite' # 要强调的值（名字、版本号）
    cmd     = 'green'       # 要敲的东西：能整行复制去跑的命令，或要挑的编号
    ok      = 'green'       # 做成了
    warn    = 'yellow'      # 要留意
    dim     = 'darkgray'    # 次要说明，不该抢注意力
    text    = 'none'        # 正文：跟终端默认色一致
}
$StyleRoles = @($StyleMap.Keys)

# 角色 -> 颜色名。没声明的角色一律按 none（不写颜色），不报错也不乱猜。
function Get-StyleColorName([string]$Role) {
    if ($StyleMap.Contains($Role)) { return [string]$StyleMap[$Role] }
    return 'none'
}

# 角色 -> 本平台的前景色。Write-Styled 只认这一处，别处不许再写颜色字面量。
function Get-StyleColor([string]$Role) {
    $name = Get-StyleColorName $Role
    if ($ColorCodes.ContainsKey($name)) { return $ColorCodes[$name] }
    return ''
}

# 按角色输出一行。所有给人看的文字都走这里，于是"换个颜色"只要改上面那张表。
function Write-Styled([string]$Role, [string]$Text, [switch]$NoNewline) {
    $c = Get-StyleColor $Role
    if ($c) { Write-Host $Text -ForegroundColor $c -NoNewline:$NoNewline }
    else { Write-Host $Text -NoNewline:$NoNewline }
}

# 角色 -> ANSI 前景码。屏幕渲染层那条路用它（整帧拼一个字符串），
# 与 Write-Styled 共用 $StyleMap / $ColorAnsi，颜色名是同一个。
function Get-StyleAnsi([string]$Role) {
    $name = Get-StyleColorName $Role
    if ($ColorAnsi.ContainsKey($name)) { return [string]$ColorAnsi[$name] }
    return ''
}

# 把一段文字按角色包上 ANSI 颜色。给屏幕渲染层用——那一层只认字符串，
# 而"一行的标签固定色、内容按状态变色"这条契约要求一行里有多个颜色段。
# 于是分段上色在**调用方**拼字符串时完成，渲染层只管画。
function Format-Styled([string]$Role, [string]$Text) {
    $code = Get-StyleAnsi $Role
    if (-not $code) { return $Text }
    return ([char]27 + '[' + $code + 'm' + $Text + [char]27 + '[0m')
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

# 这个地址是不是指向本机回环。
# 与上面那条不是一个问题，所以也不共用一个函数：
#   Test-LoopbackProxyUrl  问"这个代理**值**是不是我们写的本机地址"（归属判定用）
#   本函数                 问"这个**目标**在本机吗"（决定要不要经代理去取）
# 判据要认全三种写法：127.0.0.1、[::1]、localhost。给回环地址设代理没有意义——
# 代理那次请求的主机名仍是回环，看的是代理进程自己那一侧，只会让"本机服务"
# 看起来忽好忽坏。
function Test-LoopbackUrl([string]$Url) {
    if (-not $Url) { return $false }
    $u = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$u)) { return $false }
    if ($u.IsLoopback) { return $true }
    return ($u.Host -eq "localhost")
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
    $table["NODE_USE_ENV_PROXY"] = $NodeUseEnvProxyValue
    return $table
}

# ------------------------------------------------------------------------------
# 4.5 启动器要用的两件小事（纯函数，好测）
# ------------------------------------------------------------------------------
# 为什么这两件事住在 base 而不是 ops：它们都是"给定输入就该算出结果"的判定，
# 没有副作用，测试能直接喂参数验。放进 ops 会拖上写文件、弹提示的上下文，
# 那种函数只能靠真跑一遍来验，而真跑一遍会动用户的桌面。

# 代理地址去掉首尾空白、补上协议、去掉末尾斜杠，得到一个能直接放进环境变量的值。
# 判据宽松是有意的：代理地址可能来自注册表（我们自己写的，规范）、也可能来自
# 用户手填（可能少写 http://、可能多打一个空格）。宽松解析、严格校验，
# 比"格式不对就整个失败"对用户友好得多。
# 返回 $null 表示这串东西不像一个代理地址。
function ConvertTo-ProxyUrl([string]$Raw) {
    if (-not $Raw) { return $null }
    $v = $Raw.Trim()
    if (-not $v) { return $null }
    # 没写协议时补 http://：本机代理端口几乎都是混合端口，HTTP 兼容面最大。
    if ($v -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') { $v = 'http://' + $v }
    # 末尾斜杠要去掉：环境变量里的代理地址带斜杠时，部分工具会拼出 //path。
    $v = $v.TrimEnd('/')
    # 必须能解析出主机和端口，否则它不是一个可用的代理地址。
    $u = $null
    if (-not [System.Uri]::TryCreate($v, [System.UriKind]::Absolute, [ref]$u)) { return $null }
    if (-not $u.Host) { return $null }
    # 端口必须**显式写出来**：Uri 对省略端口的值会自动补成协议默认端口（http 补 80），
    # 于是 "http://127.0.0.1" 与 "http://bad" 都会得到 Port=80 而看起来"有端口"。
    # IsDefaultPort 才是"端口有没有被写出来"的判据——它一次挡住这两种假地址。
    if ($u.IsDefaultPort) { return $null }
    if ($u.Port -le 0) { return $null }
    # 主机名要像一个主机：Uri 会把纯中文当成合法主机名收下，那种值放进环境变量
    # 只会让所有请求失败，不如在这里判掉。
    if ($u.Host -notmatch '^[A-Za-z0-9\.\-_\[\]:]+$') { return $null }
    $scheme = $u.Scheme.ToLower()
    if ($scheme -notin @('http', 'https', 'socks5', 'socks5h', 'socks4')) { return $null }
    return $v
}

# 把代理地址里的账号密码隐去，别的部分原样保留：http://user:pass@host:port -> http://***@host:port
#
# 为什么必须有这一处：状态页要把"代理变量现在是什么"如实地打出来（那是它的职责），
# 而问题报告复用状态页的输出去发给别人。带认证的代理（公司代理、本地 mitmproxy）写的正是
# http://user:pass@host:port 这种形式，原样落盘就是把用户的明文密码写进一个"准备发出去"的文件。
# 所以：屏幕上如实显示，落进报告的走这一步——**报告里有一处没脱敏就是事故**。
# 只认 URL 里 userinfo 的写法（:// 之后、@ 之前的冒号），不碰地址的其余任何部分。
function Hide-ProxyCredential([string]$Text) {
    if (-not $Text) { return $Text }
    return [regex]::Replace($Text, '(?<=://)[^/@\s]+(?=@)', '***')
}

# 文件的 sha256（小写十六进制）。
# 不用 Get-FileHash：它是 Microsoft.PowerShell.Utility 模块导出的命令，
# 而 PSModulePath 里只要排着别的 PowerShell 版本的模块目录（常见于从 pwsh 7 里再开 5.1），
# 模块自动加载就会挑中那个二进制模块并加载失败——命令直接"找不到"，
# 不是报错而是静默缺失：校验值那一步会跟着塌掉。
# 直接用 .NET 的 SHA256 自己算：任何环境都拿得到，不依赖模块自动加载。
# 从一个**Windows 路径**里取文件名（不含扩展名）。
#
# 为什么不用 [System.IO.Path]::GetFileNameWithoutExtension：那个方法按**宿主平台**
# 的规则认目录分隔符——Windows 认反斜杠，Linux 只认正斜杠。于是同一个
# 'C:\App\unins000.exe' 在 Windows 上返回 'unins000'、在 Linux 上返回带整串目录的
# 'C:\App\unins000'，依赖它的判断在 CI 上恒为假：同一条断言本机绿、CI 红。
#
# 这个项目处理的永远是 Windows 路径（探针、快捷方式、开始菜单都在 Windows 上），
# 所以判据按反斜杠与正斜杠都切，与跑在哪个平台无关。
function Get-PathBaseName([string]$Path) {
    if (-not $Path) { return '' }
    $name = ($Path -split '[\\/]')[-1]
    if (-not $name) { return '' }
    $dot = $name.LastIndexOf('.')
    if ($dot -gt 0) { return $name.Substring(0, $dot) }
    return $name
}

# 从一个 Windows 路径里取扩展名（含点，小写）。与 Get-PathBaseName 同一条理由：
# 不能用 [System.IO.Path]::GetExtension，它按宿主平台认分隔符。
function Get-PathExtension([string]$Path) {
    if (-not $Path) { return '' }
    $name = ($Path -split '[\\/]')[-1]
    $dot = $name.LastIndexOf('.')
    if ($dot -ge 0 -and $dot -lt ($name.Length - 1)) { return $name.Substring($dot).ToLower() }
    return ''
}

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

# ------------------------------------------------------------------------------
# 终端显示的度量与折行（纯函数：只依赖字符码与控制台尺寸，不碰文件、不碰环境）
#
# 为什么住 base 而不是 ops：ops 与 shortcut 都要用它们，放进任何一方都会
# 让另一方反向依赖过去。它们本身与"操作"无关，只是"这段文字占几格"，
# 属于契约层的度量工具。
# ------------------------------------------------------------------------------

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
    if (-not $Text) { return 0 }
    # ANSI 颜色序列不占格子——终端把它当控制指令执行，屏幕上不留宽度。
    # 不剥掉就会把 ESC[36m 这类序列也算进去：实测一行 34 格的标题被算成 51 格，
    # 于是 Measure-ScreenFrame 误判"这帧太宽、画不下"而白白降级，日志裁剪也会截短。
    # 渲染层的着色与度量必须在这一点上对齐。
    $clean = [regex]::Replace($Text, [string][char]27 + '\[[0-9;]*[A-Za-z]', '')
    $w = 0
    foreach ($ch in $clean.ToCharArray()) { $w += (Get-CharWidth $ch) }
    return $w
}

# 去掉一行里的 ANSI 颜色序列，只留可见文字。
# 需要按"可见字符位置"切分的场合用它；纯算宽度用 Get-DisplayWidth 即可。
function Remove-AnsiColor([string]$Text) {
    if (-not $Text) { return '' }
    return [regex]::Replace($Text, [string][char]27 + '\[[0-9;]*[A-Za-z]', '')
}

# 把一段文字按终端可见宽度补空格（中文按两格算）。
function Format-MenuCell([string]$Text, [int]$Width) {
    $pad = $Width - (Get-DisplayWidth $Text)
    if ($pad -lt 0) { $pad = 0 }
    return $Text + (' ' * $pad)
}

# 终端宽度。取不到就用 80——这是所有终端的最小公约数，
# 按它折行最多是"早一点换行"，按更大的值折行会让内容在窄终端上被切掉。
function Get-ConsoleWidth([int]$Fallback = 80) {
    try {
        $w = [Console]::WindowWidth
        if ($w -ge 40) { return $w }
    } catch {}
    # 回退值也要合法：调用方可能传个负数进来，而宽度是要拿去做减法与取子串的。
    # 40 是"最小能看"的宽度，小于它折出来的行每行只剩一两个字符。
    return [Math]::Max(40, $Fallback)
}

# 把一行长文字折成多行，续行保持缩进。
#
# 为什么要这个：管理页要显示快捷方式的完整路径，而任务栏那条路径有 130 多个字符，
# 在普通终端里必然折行。系统自动折行的续行从第 0 列开始，于是"图标"和它下面那半截
# 路径看起来是两行无关的东西——而这一屏的全部作用正是"认准要删哪一个"。
# 自己折行，续行就能对齐到值那一列。
#
# 折行点优先选空格与反斜杠（路径在这些位置断开最好读）；一段里找不到合适的位置
# 就硬切，保证宽度一定不超。
function Split-DisplayText([string]$Text, [int]$Width, [int]$Indent = 0) {
    if (-not $Text) { return @() }
    # 宽度太小就别折了：硬折成每行一两个字符反而更难读。这是有意的降级，
    # 不是「折到这个宽度」——调用方要保证宽度够（Get-ConsoleWidth 最小给 40）。
    if ($Width -lt 8) { return @((' ' * $Indent) + $Text) }
    $out = @()
    $rest = $Text
    $pad = ' ' * $Indent
    $first = $true
    while ($true) {
        # 续行至少留 8 格：缩进接近或超过总宽时，减出来的宽度会小到只剩一两个字符。
        $avail = if ($first) { $Width } else { [Math]::Max(8, $Width - $Indent) }
        if ((Get-DisplayWidth $rest) -le $avail) {
            $out += $(if ($first) { $rest } else { $pad + $rest })
            break
        }
        # 逐字符累加到刚好超宽为止，记下最后见到的可断点
        $acc = 0
        $cut = -1
        $break = -1
        for ($i = 0; $i -lt $rest.Length; $i++) {
            $cw = Get-CharWidth $rest[$i]
            if ($acc + $cw -gt $avail) { break }
            $acc += $cw
            $cut = $i
            if ($rest[$i] -eq ' ' -or $rest[$i] -eq '\' -or $rest[$i] -eq '/') { $break = $i }
        }
        if ($cut -lt 0) { $cut = 0 }
        # 断点太靠前就不用它（会切出很短的一段，反而更难读）
        if ($break -gt 0 -and $break -ge [int]($cut * 0.6)) { $cut = $break }
        $piece = $rest.Substring(0, $cut + 1).TrimEnd()
        if (-not $piece) { $piece = $rest.Substring(0, $cut + 1) }
        $out += $(if ($first) { $piece } else { $pad + $piece })
        $rest = $rest.Substring($cut + 1).TrimStart()
        $first = $false
        if (-not $rest) { break }
    }
    return $out
}

# 为什么必须带判断：Clear-Host 在输出被重定向时（管道、日志、CI）会抛
# "设置 CursorPosition 时出现异常：句柄无效"——它依赖真实控制台缓冲区。
# 那种环境本来也拿不到终端，清屏毫无意义，还会把错误日志刷脏。
function Clear-Screen {
    try {
        if ([Console]::IsOutputRedirected) { return }
        Clear-Host
    } catch {}
}

# ------------------------------------------------------------------------------
#  屏幕渲染层：把「一帧内容」画到屏幕上，只重画变化的行。
#
#  这一层是唯一实现：菜单、帮助、状态页、管理页全都走它，没有页面特例。
#  它不认识颜色、不认识业务——输入只有两个字符串数组（上一帧、这一帧）。
#  颜色在**调用方**把内容拼成字符串之前就已经决定了，这一层只管画。
#
#  为什么单独一层：现在每个页面各自 Clear-Host + 逐行 Write-Host，于是
#  ① 清屏那一瞬屏幕全空 = 闪；② 没有「只重画变化行」的能力 = 每帧整屏重写。
#  把这两件事收敛到一处，改一次就对所有页面生效。
# ------------------------------------------------------------------------------

# 能不能做「就地重画」。这是所有刷新逻辑的前置判据，只有这一个实现。
#
# 三种情况不能画：
#   输出被重定向（管道/文件）—— 控制字符会原样写进文件，污染输出；
#   没有真实控制台 —— SetCursorPosition 会抛异常；
#   窗口太矮 —— 内容放不下，重画必然滚屏，滚屏后绝对坐标全部错位。
#
# 判据要**一次问清**，不许各页面自己再判一遍：项目里 "IsOutputRedirected" 这个
# 判断已经有四处，散着判必然漂移。
function Test-CanDrawScreen([int]$NeedLines = 0, [int]$NeedWidth = 0) {
    try {
        if ([Console]::IsOutputRedirected) { return $false }
        if ([Console]::IsInputRedirected) { return $false }
        $w = 0
        try { $w = [Console]::WindowWidth } catch { $w = 0 }
        $h = 0
        try { $h = [Console]::WindowHeight } catch { $h = 0 }
        if ($w -lt $ScreenMinWidth) { return $false }
        if ($h -lt $ScreenMinHeight) { return $false }
        # 留 ScreenBottomMargin 行给「按 0 返回」那行提示 + 光标所在行
        if ($NeedLines -gt 0 -and ($NeedLines + $ScreenBottomMargin) -gt $h) { return $false }
        # 宽度也要按**这一帧的实际最宽行**判：固定 40 只是「能读」的底线，
        # 而帧里有 82 列的日志行。80 列窗口放着 82 列的行，终端会折行——
        # 折出来的物理行不在这一层的记账里，后面每一行的绝对定位就全错位了。
        if ($NeedWidth -gt 0 -and $NeedWidth -gt $w) { return $false }
        # 光标定位能力本身要能拿到：拿不到就说明没有真控制台
        $null = [Console]::CursorTop
        return $true
    } catch {
        return $false
    }
}

# 一帧要占多少屏：行数 + 最宽行的显示宽度。
# 判「画不画得下」必须用这两个真实值，不能拿固定的最小宽高去猜——
# 最小宽高只是"能读"的底线，而真实帧里可能有 80+ 列的行、23 行的最坏情况。
function Measure-ScreenFrame([string[]]$Lines = @()) {
    $n = @($Lines).Count
    $w = 0
    foreach ($ln in $Lines) {
        $s = [string]$ln
        $dw = 0
        try { $dw = Get-DisplayWidth $s } catch { $dw = $s.Length }
        if ($dw -gt $w) { $w = $dw }
    }
    return @{ Lines = $n; Width = $w }
}

# 把一帧内容画到屏幕起点，返回这一帧实际占了多少屏幕行。
#
# $Old 与 $New 都是字符串数组，一个元素 = 一个逻辑行。行数可以不同：
# 变少时多出来的行会被擦掉（写空格），变多时新行追加。
#
# 返回实际占用的行数，调用方拿它当下一次的 $Old 行数。
function Write-ScreenFrame {
    param(
        [string[]]$Old = @(),
        [string[]]$New = @()
    )
    if (-not (Test-CanDrawScreen)) { return 0 }
    $n = @($New).Count
    $o = @($Old).Count
    if ($n -eq 0 -and $o -eq 0) { return 0 }

    # 窗口尺寸一变，终端会把已有内容重新折行，屏幕上"第几行是什么"整个失效——
    # 而这一层的记账（$Old）是按逻辑行算的。此时如果继续只重画"变化的行"，
    # 没变化的行会永远停在错位状态（实测：窗口拉小再拉回，11 轮刷新都修不好）。
    # 所以尺寸一有变化就作废记账、整帧重画。这是唯一能一次覆盖
    # "缩小时/拉大时/中途变/恢复时"的判据，不用逐个场景处理。
    $w = 0; $h = 0
    try { $w = [Console]::WindowWidth; $h = [Console]::WindowHeight } catch { }
    if ($w -ne $script:ScreenLastWidth -or $h -ne $script:ScreenLastHeight) {
        $script:ScreenLastWidth = $w
        $script:ScreenLastHeight = $h
        $Old = @()
        $o = 0
    }

    # 行数上限由函数自己守，不靠调用方记得先判：这一帧比窗口还高时，
    # 绝对定位 ESC[<行>;1H 会指向不存在的行——多数终端把它夹到末行，
    # 但一旦滚屏，后面每个逻辑行的绝对定位都错位，屏幕会显示错乱内容。
    # 宁可这一帧不画（返回 0，调用方下一轮重试），也不要画出一屏乱码。
    if ($h -gt 0 -and $n -gt ($h - 1)) { return 0 }

    # 先把整帧拼成一个字符串再一次写出。
    # 为什么不是逐行 Write-Host：实测 12 行逐行写要 9.28 毫秒，一次拼接写出
    # 只要 0.24 毫秒（快 39 倍），而且中间没有「画到一半」的可见状态。
    $sb = New-Object System.Text.StringBuilder
    $max = [Math]::Max($o, $n)
    for ($i = 0; $i -lt $max; $i++) {
        $text = if ($i -lt $n) { [string]$New[$i] } else { '' }
        $prev = if ($i -lt $o) { [string]$Old[$i] } else { '' }
        # 内容没变就跳过这一行（这是「不闪」的本质：无变化时一个字节都不发）
        if ($i -lt $n -and $text -ceq $prev) { continue }
        [void]$sb.Append([char]27 + '[' + ($i + 1) + ';1H')     # 定位到该行
        [void]$sb.Append($text)
        [void]$sb.Append([char]27 + '[K')                        # 清到行尾，擦掉上一帧的尾巴
    }
    # 行数变少时，把多出来的行擦空
    if ($o -gt $n) {
        for ($i = $n; $i -lt $o; $i++) {
            [void]$sb.Append([char]27 + '[' + ($i + 1) + ';1H')
            [void]$sb.Append([char]27 + '[K')
        }
    }
    if ($sb.Length -eq 0) { return $n }   # 完全没有变化：不发任何字节

    try {
        [Console]::Out.Write(([char]27 + '[?25l'))   # 藏光标，避免看到它跳
        [Console]::Out.Write($sb.ToString())
        [Console]::Out.Write(([char]27 + '[?25h'))   # 恢复光标
        [Console]::Out.Flush()
    } catch {}
    return $n
}

# 进入/退出「屏幕已接管」状态：进入前清一次屏（只这一次），退出后把光标放回底部。
# 只有这两个函数会清屏。刷新循环里一次都不许清——清屏就是闪的根源。
function Enter-Screen {
    if (-not (Test-CanDrawScreen)) { return $false }
    try {
        Clear-Screen
        [Console]::Out.Write(([char]27 + '[H'))   # 光标回左上角
        [Console]::Out.Flush()
    } catch { return $false }
    return $true
}

function Exit-Screen {
    try {
        # 光标从「内容区」移到最下面一行，之后正常输出不会盖住刚画的内容
        $h = 0
        try { $h = [Console]::WindowHeight } catch { $h = 0 }
        if ($h -gt 0) {
            [Console]::SetCursorPosition(0, [Math]::Min($h - 1, [Console]::BufferHeight - 1))
        }
        [Console]::Out.Write([char]27 + '[?25h')   # 确保光标可见（Ctrl+C 后也要恢复）
        [Console]::Out.Flush()
    } catch {}
}

# 等一小段时间，顺便看有没有按键。返回：'' = 没按；其余 = 按下的那个字符。
# 返回 'Quit' 表示用户按了 0 / Esc / q，调用方据此退出刷新循环。
#
# 为什么不用 Read-Host：PS 5.1 是单线程宿主，Read-Host 阻塞在 ReadConsole 上时
# 整个事件循环停摆——实测那 3 秒内定时器回调一次都不触发。要「边刷新边等输入」
# 只能自己用 KeyAvailable 轮询。
function Wait-ScreenKey([int]$Milliseconds = 150) {
    $elapsed = 0
    $fails = 0
    while ($elapsed -lt $Milliseconds) {
        $got = $null
        try {
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq 'Escape') { return 'Quit' }
                $c = [string]$k.KeyChar
                if ($c -eq '0' -or $c -eq 'q' -or $c -eq 'Q') { return 'Quit' }
                # 空字符 = 功能键（方向键、F1 之类，KeyChar 是 \0）。
                # 它不是一个"输入"，不该结束这一轮等待：直接返回会让连按方向键的人
                # 把刷新节奏打乱（每次按键都提前结束等待）。当作没按，继续等。
                if ($c) { $got = $c }
            }
        } catch {
            # 读键失败（stdin 被夺走、控制台句柄失效）不等于"没按键就立刻返回"。
            # 立刻返回会让调用方的 while 循环毫无间隔地空转——实测那样一秒能转
            # 几千次、把一个核吃满，而且永远退不出去（拿不到 Quit）。
            # 这里必须照常歇一个轮询周期；连续失败太多次说明输入通道真的没了，
            # 交回一个 Error 让调用方退出循环，而不是陪着它空转。
            $fails++
            if ($fails -ge $ScreenKeyFailLimit) { return 'Error' }
        }
        if ($got) { return $got }
        Start-Sleep -Milliseconds $ScreenPollMs
        $elapsed += $ScreenPollMs
    }
    return ''
}
