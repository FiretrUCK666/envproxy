# ==============================================================================
#  doctor.ps1 — 体检层：系统代理各层的读取、判定与修复
#  由入口 envproxy.ps1 按固定顺序点源加载，不单独运行。
#
#  职责边界（改这个文件前先读这一段）：
#    可以有 —— 探测系统代理各层、按判据给结论、修复、读写备份
#    不许有 —— 打印任何屏幕内容、读用户输入、进菜单循环、改环境变量
#  界面住在 ops（菜单）与 shortcut（高级功能页）里，这一层只产出数据。
#  这样它只依赖 base + probe，不反向调 ops，不产生新的依赖环。
#
#  为什么需要这一层（问题从哪来）：
#    Windows 上的「代理」不是一个开关，是好几套互相独立的系统。翻墙软件被强杀、
#    断电、直接关机之后，它写下的设置会留在系统里，指向一个已经不存在的本地端口。
#    浏览器照旧把请求发给那个端口，于是「国内网站也打不开」——线没断，路指错了。
#    Windows 真正生效的是 Internet Settings 下的 DefaultConnectionSettings 二进制，
#    ProxyEnable / ProxyServer 只是给人看的镜像。只改镜像不生效，是这一层最要紧的坑。
#
#  判据（唯一一处，见 Get-SystemProxyVerdict）：
#    地址是本机回环 + 端口连不上 = 可修；其余一律不动。
#    回环这条判据站得住：公司/学校代理的地址一定是真实 IP 或域名，不可能写成
#    127.0.0.1（那是「我自己这台机器」的意思）。所以「回环」= 「某个本机程序写的」，
#    「端口死」= 「写它的程序不在了」。两条客观事实叠加，不是猜。
# ==============================================================================

# ------------------------------------------------------------------------------
# 判定结论词（两侧同形，门禁 6 核对；Mac 侧见 doctor.sh 同一组）
# ------------------------------------------------------------------------------
# 只在这里定义一次，**所有检查器共用**、界面与状态页都读它——写两处必然分叉。
# 名字叫 Finding 而不是 SysProxy：这套词现在描述的是「某一层网络设置出了什么事」，
# 不再只服务于系统代理。多一层检查器不需要、也不许新增词——七个词表达的是
# 「有没有东西 / 东西归谁 / 能不能修」，与层无关。
$FindingKinds = @{
    Clean         = 'clean'            # 压根没设
    Blocking      = 'residue-blocking' # 手动代理指向死端口：真断网，最高优先级
    Slowing       = 'residue-slowing'  # 自动配置脚本指向死端口：能上网但会卡几秒
    Alive         = 'alive'            # 回环地址 + 端口活着：翻墙软件正在用，不动
    Foreign       = 'foreign'          # 不是回环：公司/学校代理，工具不碰
    Managed       = 'managed'          # 被组策略、描述文件管着：改了也会被改回，不动
    # 读不出来：系统工具被拦、权限不足、输出认不出来。**必须与 Foreign 分开**——
    # Foreign 断言「这是别人的代理」，读不出来时我们连地址都没有，说成 Foreign 是编的。
    # 它不可修，也不进「不能动」那一组的计数（那组的意思是「东西在那儿，但不归我碰」）。
    Unreadable    = 'unreadable'
}

# ------------------------------------------------------------------------------
# 统一诊断记录（Finding）：所有检查器的输出只有这一种形状
# ------------------------------------------------------------------------------
# 为什么必须统一：界面的职责是「把可修的东西列出来、把不归我碰的东西列出来」，
# 那与具体是哪一层毫无关系。只要每层的输出同构，界面就永远不用改——
# 加一层检查器不需要碰界面一个字，这是「不堆补丁」在这里的具体含义。
#
# 字段：
#   Id       稳定标识，进日志与报告（如 sysproxy.manual / cli-proxy.git）
#   Kind     七个结论词之一
#   Subject  给人看的分组名（「浏览器代理」「Git 自己的代理」）
#   Where    东西在哪（层名、网卡名、文件路径）
#   Value    当前值（地址、DNS 列表）
#   Reason   为什么这么判。**只许引用廉价信号**（地址形态、端口三态、是否被管）
#   Advice   使用者能做什么
#   Evidence 贵信号（握手、属主、客户端名）。**只进报告，绝不参与授权**
#   Fix      修它要调用哪个函数；空串 = 只诊断不修
#   Fixable  由 Kind 算出来，不许调用方自己写比较
function New-Finding {
    param(
        [string]$Id,
        [string]$Kind,
        [string]$Subject = '',
        [string]$Where = '',
        [string]$Value = '',
        [string]$Reason = '',
        [string]$Advice = '',
        [string]$Evidence = '',
        $Data = $null
    )
    return @{
        Id       = $Id
        Kind     = $Kind
        Subject  = $Subject
        Where    = $Where
        Value    = $Value
        Reason   = $Reason
        Advice   = $Advice
        Evidence = $Evidence
        # **Finding 上没有「用哪个函数修」那样的字段，故意的。**
        # 可修性由三件事推出来：Kind → 检查器表里该层有没有 Fix → 这条记录
        # 自己声明的 Repairable（存在 Data 里，只有看得见文件格式的那一层能回答）。
        # 把「哪个函数修」存进 Finding 就成了第二个真相，两边分叉时不会报错，
        # 读代码的人也无从判断哪份算数。权威判据只有一个：
        # insp 层的 Test-FindingRepairable。
        Data     = $Data
    }
}

# WinINET 的连接标志位。值与 Windows SDK 一致，改动会导致写进去的开关错位。
# 只列我们真正要看的两层：手动代理与自动配置脚本。
# 自动检测（WPAD，0x08）不单列——修复走"逐位改、只碰出问题的那一位"，
# 它天然被保留在 $Flags 里，不需要单独解析出一个从没人读的字段。
$ProxyTypeProxy        = 0x02
$ProxyTypeAutoProxyUrl = 0x04

# 判据里「哪个结论允许被修」只有一处：**只有 residue 两类**。
# 界面要判断「这项能不能修」时调这个，不许自己写 -eq 比较——
# 那样加一类结论就会漏掉界面那一处。
# 名字从 SysProxy 改成 Finding：它判的是所有检查器共用的那套结论词，
# 不再只属于系统代理那一层。**只有这一处实现**，没有别名——
# 同一个概念两个名字，迟早会一边改一边忘。
function Test-FindingFixable([string]$Kind) {
    return ($Kind -eq $FindingKinds.Blocking -or $Kind -eq $FindingKinds.Slowing)
}

# ------------------------------------------------------------------------------
# 1. 纯判据：给定事实，说出结论（不碰系统、不碰网络，便于回归）
# ------------------------------------------------------------------------------
# 参数全是已经查好的事实，函数自己不探测。测试直接喂入参，不需要联网、不需要注册表。
#   $Url     系统里写着的代理地址（可能是 http://127.0.0.1:7078，也可能只是 127.0.0.1:7078）
#   $Port    端口（$Url 拆不出来时由调用方单独给）
#   $Alive   端口活着吗：$true 活 / $false 死 / $null 说不清
#   $Managed 被组策略管着吗
#   $Kind    这一层是「手动代理」还是「自动配置脚本」
#
# 「说不清」($null) 必须归到不许动的结论里：拿不准的时候不动，是这一层唯一安全的默认。
# 判成可修然后删掉一个其实在用的代理，代价是用户唯一的上网路径没了——两个方向的代价
# 不对称，判据就不许对称。
function Get-SystemProxyVerdict {
    param(
        [string]$Url,
        [int]$Port = 0,
        $Alive = $null,
        [bool]$Managed = $false,
        [string]$Kind = 'manual'
    )
    if ($Managed) { return $FindingKinds.Managed }
    if (-not $Url -and $Port -le 0) { return $FindingKinds.Clean }
    # 地址拆不出端口、也不是合法地址：无从判断死活，归「不是本机代理」那类——不动。
    if (-not (Test-LoopbackUrl $Url)) { return $FindingKinds.Foreign }
    if ($null -eq $Alive) { return $FindingKinds.Foreign }
    if ($Alive) { return $FindingKinds.Alive }
    if ($Kind -eq 'pac') { return $FindingKinds.Slowing }
    return $FindingKinds.Blocking
}

# ------------------------------------------------------------------------------
# 2. 解析 DefaultConnectionSettings（纯函数：喂字节，出结论）
# ------------------------------------------------------------------------------
# Windows 真正生效的代理配置存在这个二进制里。结构（微软未公开，逆向得到的稳定结论）：
#   偏移 0  4 字节 固定头（0x46）
#   偏移 4  4 字节 每次修改递增的计数器
#   偏移 8  4 字节 **标志位**（这一项才是开关，值见下方常量）
#   偏移 12 起依次是三个「长度 + 内容」（代理地址、例外列表、自动配置脚本地址）
#
# 只读标志位，不改整段字节：整段重写要自己维护计数器与三个长度字段，
# 算错一位就写坏用户的网络设置。写走 WinINET 接口，它替我们维护这些。
#
# 为什么必须有这个解析：只读 ProxyEnable 的话，「PAC 脚本残留」看不出来
# （那种情况下 ProxyEnable 是 0，看着一切正常，但浏览器每次开网页都要先等脚本超时）。
function ConvertFrom-ProxyConnectionBlob {
    param([byte[]]$Bytes)
    $r = @{
        Ok          = $false
        Flags       = 0
        ManualProxy = $false
        AutoConfig  = $false
        ProxyServer = ''
        AutoConfigUrl = ''
    }
    # 头 12 字节 + 三个「长度字段」至少 12 字节。短于这个长度的数据不是这个结构，
    # 一律当作「读不出来」，绝不按空值处理——那会让上层以为「没设代理」。
    if (-not $Bytes -or $Bytes.Length -lt 24) { return $r }
    $flags = [int]$Bytes[8] -bor ([int]$Bytes[9] -shl 8) -bor ([int]$Bytes[10] -shl 16) -bor ([int]$Bytes[11] -shl 24)
    $r.Flags       = $flags
    $r.ManualProxy = (($flags -band $ProxyTypeProxy) -ne 0)
    $r.AutoConfig  = (($flags -band $ProxyTypeAutoProxyUrl) -ne 0)
    # 三个字符串依次是：代理地址、例外列表、自动配置脚本地址。
    # 每个都是「4 字节长度（小端）+ 那么多字节的 ASCII」。
    # 越界一律停下、保留已解析的部分：读坏的数据不该抛异常到界面上，
    # 也不该把「读到一半」伪装成完整结论。
    $pos = 12
    $names = @('ProxyServer', 'ProxyOverride', 'AutoConfigUrl')
    foreach ($n in $names) {
        if ($pos + 4 -gt $Bytes.Length) { break }
        $len = [int]$Bytes[$pos] -bor ([int]$Bytes[$pos + 1] -shl 8) -bor ([int]$Bytes[$pos + 2] -shl 16) -bor ([int]$Bytes[$pos + 3] -shl 24)
        $pos += 4
        if ($len -lt 0 -or $pos + $len -gt $Bytes.Length) { break }
        if ($len -gt 0) {
            $s = [System.Text.Encoding]::ASCII.GetString($Bytes, $pos, $len)
            if ($r.ContainsKey($n)) { $r[$n] = $s }
        }
        $pos += $len
    }
    $r.Ok = $true
    return $r
}

# ------------------------------------------------------------------------------
# 3. WinINET 接口（读写系统代理的唯一正确通道）
# ------------------------------------------------------------------------------
# 为什么必须走它而不是直接改注册表：它同时更新镜像值与那段二进制，
# 并且会通知已开的程序「设置变了」。直接改注册表只动镜像，
# 浏览器照旧读旧值——症状是「修好了，但网页还是打不开」，
# 而屏幕上、回读结果里全都是对的，最难查的一类。
#
# 零依赖：这些声明是进程内的 P/Invoke，不装任何东西。项目里已有两处同样做法
# （env.ps1 的 SendMessageTimeout、relay.ps1 的 C# 类）。
$script:SysProxyApiReady = $null
function Initialize-SysProxyApi {
    if ($null -ne $script:SysProxyApiReady) { return $script:SysProxyApiReady }
    $script:SysProxyApiReady = $false
    try {
        if (-not ("EnvProxyWinInet" -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class EnvProxyWinInet {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct INTERNET_PER_CONN_OPTION_LIST {
        public int dwSize;
        public string pszConnection;
        public int dwOptionCount;
        public int dwOptionError;
        public IntPtr pOptions;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INTERNET_PER_CONN_OPTION {
        public int dwOption;
        public IntPtr value;
    }

    [DllImport("wininet.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool InternetQueryOption(IntPtr hInternet, int dwOption,
        ref INTERNET_PER_CONN_OPTION_LIST list, ref int lpdwBufferLength);

    [DllImport("wininet.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool InternetSetOption(IntPtr hInternet, int dwOption,
        ref INTERNET_PER_CONN_OPTION_LIST list, int dwBufferLength);

    [DllImport("wininet.dll", SetLastError = true)]
    public static extern bool InternetSetOption(IntPtr hInternet, int dwOption,
        IntPtr lpBuffer, int dwBufferLength);
}
'@ -ErrorAction Stop
        }
        $script:SysProxyApiReady = $true
    } catch {
        $script:SysProxyApiReady = $false
    }
    return $script:SysProxyApiReady
}

# 选项常量（Windows SDK 原值）
$script:IpcFlags        = 1   # INTERNET_PER_CONN_FLAGS
$script:IpcProxyServer  = 2   # INTERNET_PER_CONN_PROXY_SERVER
$script:IpcProxyBypass  = 3   # INTERNET_PER_CONN_PROXY_BYPASS
$script:IpcAutoConfig   = 4   # INTERNET_PER_CONN_AUTOCONFIG_URL
$script:OptPerConn      = 75  # INTERNET_OPTION_PER_CONNECTION_OPTION
$script:OptSettingsChanged = 39       # INTERNET_OPTION_SETTINGS_CHANGED
$script:OptProxyChanged    = 95       # INTERNET_OPTION_PROXY_SETTINGS_CHANGED

# 读当前生效的代理配置。返回 $null = 读不出来（含接口不可用）。
#
# 读的是「局域网连接」（pszConnection = null）那一份：浏览器默认就用它。
# 每用户一条拨号/VPN 连接各有自己的设置，但那不是家庭用户撞上的场景，
# 而且逐连接去改的风险远大于收益（改错一条 VPN 会让公司网络连不上）。
function Get-SystemProxyConnection {
    if (-not (Initialize-SysProxyApi)) { return $null }
    try {
        $list = New-Object EnvProxyWinInet+INTERNET_PER_CONN_OPTION_LIST
        $size = [System.Runtime.InteropServices.Marshal]::SizeOf($list)
        $opts = @(1, 2, 3, 4)
        $optSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][EnvProxyWinInet+INTERNET_PER_CONN_OPTION])
        $ptrs = [System.Runtime.InteropServices.Marshal]::AllocCoTaskMem($optSize * $opts.Count)
        $list.dwSize = $size
        $list.pszConnection = $null
        $list.dwOptionCount = $opts.Count
        $list.dwOptionError = 0
        $list.pOptions = $ptrs
        for ($i = 0; $i -lt $opts.Count; $i++) {
            $o = New-Object EnvProxyWinInet+INTERNET_PER_CONN_OPTION
            $o.dwOption = $opts[$i]
            $o.value = [IntPtr]::Zero
            [System.Runtime.InteropServices.Marshal]::StructureToPtr($o, [IntPtr]($ptrs.ToInt64() + $optSize * $i), $false)
        }
        $len = $size
        $ok = [EnvProxyWinInet]::InternetQueryOption([IntPtr]::Zero, $script:OptPerConn, [ref]$list, [ref]$len)
        $result = $null
        if ($ok) {
            $result = @{ Flags = 0; ProxyServer = ''; ProxyBypass = ''; AutoConfigUrl = '' }
            for ($i = 0; $i -lt $opts.Count; $i++) {
                $o = [System.Runtime.InteropServices.Marshal]::PtrToStructure(
                    [IntPtr]($ptrs.ToInt64() + $optSize * $i), [type][EnvProxyWinInet+INTERNET_PER_CONN_OPTION])
                switch ($o.dwOption) {
                    1 { $result.Flags = [int]$o.value }
                    default {
                        if ($o.value -ne [IntPtr]::Zero) {
                            $s = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($o.value)
                            if ($o.dwOption -eq 2) { $result.ProxyServer = $s }
                            elseif ($o.dwOption -eq 3) { $result.ProxyBypass = $s }
                            elseif ($o.dwOption -eq 4) { $result.AutoConfigUrl = $s }
                            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($o.value)
                        }
                    }
                }
            }
        }
        [System.Runtime.InteropServices.Marshal]::FreeCoTaskMem($ptrs)
        return $result
    } catch {
        return $null
    }
}

# 写回代理配置并通知已开的程序。
#   $Flags / $ProxyServer / $ProxyBypass / $AutoConfigUrl
# 返回 $true = 写成功。**写成功不等于生效**：调用方必须回读确认（Get-SystemProxyConnection）。
function Set-SystemProxyConnection {
    param([int]$Flags, [string]$ProxyServer = '', [string]$ProxyBypass = '', [string]$AutoConfigUrl = '')
    if (-not (Initialize-SysProxyApi)) { return $false }
    $list = New-Object EnvProxyWinInet+INTERNET_PER_CONN_OPTION_LIST
    $optSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][EnvProxyWinInet+INTERNET_PER_CONN_OPTION])
    $entries = New-Object System.Collections.ArrayList
    [void]$entries.Add(@{ Option = $script:IpcFlags; Value = [IntPtr][int]$Flags })
    # 三个字符串项**不管空不空都要下发**。
    #
    # 原来写成 `if ($ProxyServer) { ... }`，空串就整条不发——而"不发"不是"写空"，
    # 是"保留 blob 里原来的值"。于是清一条残留时：代理服务器、例外列表、PAC 地址
    # 全被保住，只有标志位变了；回读只比 Flags，照样报"修好了"。
    # 用户看到成功、浏览器还是打不开，而且下次读出来仍是脏的。
    # 空值要显式写成空串（StringToHGlobalUni('') 给的是有效空串指针，不是 IntPtr.Zero）。
    [void]$entries.Add(@{ Option = $script:IpcProxyServer; Value = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni([string]$ProxyServer) })
    [void]$entries.Add(@{ Option = $script:IpcProxyBypass;    Value = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni([string]$ProxyBypass) })
    [void]$entries.Add(@{ Option = $script:IpcAutoConfig;     Value = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni([string]$AutoConfigUrl) })
    $ptrs = [System.Runtime.InteropServices.Marshal]::AllocCoTaskMem($optSize * $entries.Count)
    $ok = $false
    try {
        $list.dwSize = [System.Runtime.InteropServices.Marshal]::SizeOf($list)
        $list.pszConnection = $null
        $list.dwOptionCount = $entries.Count
        $list.dwOptionError = 0
        $list.pOptions = $ptrs
        for ($i = 0; $i -lt $entries.Count; $i++) {
            $o = New-Object EnvProxyWinInet+INTERNET_PER_CONN_OPTION
            $o.dwOption = $entries[$i].Option
            $o.value = $entries[$i].Value
            [System.Runtime.InteropServices.Marshal]::StructureToPtr($o, [IntPtr]($ptrs.ToInt64() + $optSize * $i), $false)
        }
        $ok = [EnvProxyWinInet]::InternetSetOption([IntPtr]::Zero, $script:OptPerConn, [ref]$list, $list.dwSize)
        if ($ok) {
            # 两次通知都要发：第一个告诉系统「设置变了」，第二个是代理专用的那条。
            # 只发后者时，已经跑着的浏览器有时不会立刻重读。
            [void][EnvProxyWinInet]::InternetSetOption([IntPtr]::Zero, $script:OptSettingsChanged, [IntPtr]::Zero, 0)
            [void][EnvProxyWinInet]::InternetSetOption([IntPtr]::Zero, $script:OptProxyChanged, [IntPtr]::Zero, 0)
        }
    } catch {
        $ok = $false
    } finally {
        foreach ($e in $entries) {
            if ($e.Option -ne $script:IpcFlags -and $e.Value -ne [IntPtr]::Zero) {
                try { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($e.Value) } catch {}
            }
        }
        try { [System.Runtime.InteropServices.Marshal]::FreeCoTaskMem($ptrs) } catch {}
    }
    return $ok
}

# ------------------------------------------------------------------------------
# 4. 组策略：识别「改了也会被改回来」
# ------------------------------------------------------------------------------
# 研究确认：策略启用后，界面改不动，直接改注册表也会在下次策略刷新时还原。
# 不识别这一项的后果是工具报「已修好」、用户过一会儿发现又坏了，
# 然后以为工具是坏的。识别出来就直接说「这个被管理员锁着，要联系网管」。
#
# **判据必须是具体值名，不能是「这个键下有没有东西」。**
# 实测：`HKLM\...\Policies\...\Internet Settings` 这个键在普通家用机上也存在，
# 里面放着 `CallLegacyWCMPolicies`——那与代理毫无关系。
# 按「键存在且有值」判，会把没被管的机器一律判成被管，从而永远不修，
# 那正是这个功能最该避免的失败（用户点了修，工具说「被管着」）。
# 只有真正管辖代理的那几个值名出现，才算被管。
# WinINET 的代理设置是**按连接**存的：LAN 一份，每个拨号/VPN 连接各一份。
# 我们现在读写的是 LAN 那份（pszConnection = NULL）。若用户在用 PPPoE 拨号或 VPN，
# **别的连接上可能还留着一条死端口的代理**，那也会让浏览器打不开网，而我们只看 LAN，
# 会报"已修好"——这正是"部分失败不许报成修好"这条契约要防的。
#
# 这个函数只做一件事：把"除 LAN 之外还有哪些连接存着自己的代理设置"列出来，
# 供界面如实提示。它**不读也不改**那些连接（写别的连接风险更大，且本项目不覆盖那种场景）。
# 返回连接名数组（不含 DefaultConnectionSettings / SavedLegacySettings 这两个 LAN 专用值）。
function Get-OtherConnectionProxyNames {
    $out = @()
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'
    if (-not (Test-RegKey $key)) { return $out }
    try {
        $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
        foreach ($p in $props.PSObject.Properties) {
            $n = [string]$p.Name
            if ($n -match '^PS') { continue }
            # 这两个是 LAN 用的（Default 是生效值、SavedLegacy 是旧版兼容），不算"别的连接"。
            if ($n -eq 'DefaultConnectionSettings' -or $n -eq 'SavedLegacySettings') { continue }
            $out += $n
        }
    } catch { }
    return $out
}
# 这台机器的代理设置是不是被组策略管着（改了会被刷回去，所以不该动）。
#
# **三个值名与它们所属的键，逐一按微软官方策略定义（inetres.admx）核对过**。
# 策略的值名与策略标题不是一回事，把标题当值名是这类判据最常见的错法。
# 今天这张表只有三项，每一项都能在 admx 里逐字找到：
#
#   策略 UserProxy            key=Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings
#                             valueName=ProxySettingsPerUser   enabledValue=0（整机统一，用户级改动不生效）
#   策略 RestrictProxy        key=Software\Policies\Microsoft\Internet Explorer\Control Panel
#                             valueName=Proxy          DWORD 1 = 锁住代理页
#   策略 RestrictAutoconfig   key=Software\Policies\Microsoft\Internet Explorer\Control Panel
#                             valueName=Autoconfig     DWORD 1 = 锁住自动配置页
#
# 三个值**不在同一个键**：后两个在 Internet Explorer\Control Panel 下。
# 只查 Internet Settings 一个键，会把「锁了代理页」的企业机判成没被管，然后去改一个改不动的东西、
# 改完还报成功——那正是这个函数要防的失败。
#
# 反例（曾经写进来、已删）：DisableCachingOfSSLPages 管 SSL 页面缓存，与代理无关；
# PreventChangingProxySettings / ProxySettingsPerMachine 在 admx 里**根本不存在**（是记错的标题）。
# 把它们算进来/写错，会让判据两个方向都出错：该拦的没拦，不该拦的乱拦。
$SysProxyPolicyChecks = @(
    @{ Key = 'HKLM:\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'
       Name = 'ProxySettingsPerUser'; Want = 0 }
    @{ Key = 'HKCU:\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'
       Name = 'ProxySettingsPerUser'; Want = 0 }
    @{ Key = 'HKLM:\Software\Policies\Microsoft\Internet Explorer\Control Panel'
       Name = 'Proxy'; Want = 1 }
    @{ Key = 'HKCU:\Software\Policies\Microsoft\Internet Explorer\Control Panel'
       Name = 'Proxy'; Want = 1 }
    @{ Key = 'HKLM:\Software\Policies\Microsoft\Internet Explorer\Control Panel'
       Name = 'Autoconfig'; Want = 1 }
    @{ Key = 'HKCU:\Software\Policies\Microsoft\Internet Explorer\Control Panel'
       Name = 'Autoconfig'; Want = 1 }
)

function Test-SystemProxyManaged {
    foreach ($check in $SysProxyPolicyChecks) {
        if (-not (Test-RegKey $check.Key)) { continue }
        $v = Get-ItemProperty -LiteralPath $check.Key -Name $check.Name -ErrorAction SilentlyContinue
        if (-not $v) { continue }
        $raw = $null
        try { $raw = $v.($check.Name) } catch { $raw = $null }
        if ($null -eq $raw) { continue }
        $num = 0
        if (-not [int]::TryParse([string]$raw, [ref]$num)) { continue }
        if ($num -eq [int]$check.Want) { return $true }
    }
    return $false
}

# ------------------------------------------------------------------------------
# 5. 读出全部层，装配成可判定的数据
# ------------------------------------------------------------------------------
# 返回一张清单，每项一条「某一层上有没有东西、能不能修」：
#   Layer  标签（manual / pac / winhttp / blob）
#   Url    地址原文
#   Port   端口
#   Kind   结论词（见 $FindingKinds）
#   Detail 给人看的补充（什么时候用得到由界面决定）
#
# -Quick 只查手动代理与自动配置两层，且超时短——供每 2–3 秒刷新的状态页用。
# 不加 -Quick 是全量（多查 winhttp），供体检页用。
# **一个函数、两种深度**，不是两套代码：复制一份轻量实现，迟早两边结论不一致。
# 把「系统代理的原始值」归一成一条能判断的地址。
#
# Windows 允许分协议写法：`http=127.0.0.1:7078;https=127.0.0.1:7078;socks=127.0.0.1:7079`。
# 而 `ConvertTo-ProxyUrl` 只认单个地址，遇到这种整串就返回 $null——
# 于是在系统代理里明明写着死端口，界面却报"没发现问题"，用户怎么点都修不好。
# 这在 Windows 上是很常见的写法（不少客户端与组策略都这么写），不能当边角情况。
#
# 做法：按 `;` 拆开，每段去掉 `proto=` 前缀后逐个归一，**取第一个可用的**。
# 为什么不返回多地址：判据只关心"有没有指向本机的死端口"，一条就足以决定修不修；
# 而修复动作是把整段关掉，不需要知道其余几条。
function ConvertTo-SysProxyUrl([string]$Raw) {
    if (-not $Raw) { return $null }
    $v = $Raw.Trim()
    if (-not $v) { return $null }
    $single = ConvertTo-ProxyUrl $v
    if ($single) { return $single }
    foreach ($seg in ($v -split ';')) {
        $s = $seg.Trim()
        if (-not $s) { continue }
        # 去掉 `proto=host:port` 里的 `proto=` 前缀
        $s = $s -replace '^[A-Za-z][A-Za-z0-9+.-]*=\s*', ''
        if (-not $s) { continue }
        $one = ConvertTo-ProxyUrl $s
        if ($one) { return $one }
    }
    return $null
}

function Get-SystemProxyLayers {
    param([switch]$Quick)
    $timeoutMs = if ($Quick) { 300 } else { 800 }
    $managed = Test-SystemProxyManaged
    $out = New-Object System.Collections.ArrayList

    # ---- 手动代理与自动配置脚本：同一个接口一次读回 ----
    $conn = Get-SystemProxyConnection
    if ($conn) {
        if (($conn.Flags -band $ProxyTypeProxy) -ne 0 -and $conn.ProxyServer) {
            $split = Split-ProxyUrl (ConvertTo-SysProxyUrl $conn.ProxyServer)
            $port = if ($split) { [int]$split.Port } else { 0 }
            $alive = $null
            if ($split) { $alive = Test-TcpAlive (ConvertTo-ProbeHost $split.Host) $port $timeoutMs }
            $url = ConvertTo-SysProxyUrl $conn.ProxyServer
            $manualKind = Get-SystemProxyVerdict -Url $url -Port $port -Alive $alive -Managed $managed -Kind 'manual'
            # 证据只在**端口活着**或**端口死了但有人报错**时才有意义；死了就没什么可问的。
            # -Quick（状态页，每 2–3 秒刷一次）绝不采集：握手与查进程都要起连接/查询，
            # 那是这个页面刷新的十倍开销。状态页只报结论，体检页才报证据。
            $ev = $null
            if (-not $Quick -and $port -gt 0) {
                try { $ev = Get-SysProxyEvidence $port } catch { $ev = $null }
            }
            [void]$out.Add(@{
                Layer = 'manual'; Url = $url; Port = $port
                Kind = $manualKind
                Detail = (Get-SysProxyReason -Kind $manualKind -Url $url -Port $port -Alive $alive -Layer 'manual')
                Advice = (Get-SysProxyAdvice -Kind $manualKind -Port $port)
                Evidence = $(if ($ev) { $ev.Summary } else { '' })
                Handshake = $(if ($ev) { $ev.Handshake } else { '' })
            })
        }
        if (($conn.Flags -band $ProxyTypeAutoProxyUrl) -ne 0 -and $conn.AutoConfigUrl) {
            $split = Split-ProxyUrl $conn.AutoConfigUrl
            $port = if ($split) { [int]$split.Port } else { 0 }
            $alive = $null
            if ($split) { $alive = Test-TcpAlive (ConvertTo-ProbeHost $split.Host) $port $timeoutMs }
            $pacKind = Get-SystemProxyVerdict -Url $conn.AutoConfigUrl -Port $port -Alive $alive -Managed $managed -Kind 'pac'
            $ev2 = $null
            if (-not $Quick -and $port -gt 0) {
                try { $ev2 = Get-SysProxyEvidence $port } catch { $ev2 = $null }
            }
            [void]$out.Add(@{
                Layer = 'pac'; Url = $conn.AutoConfigUrl; Port = $port
                Kind = $pacKind
                Detail = (Get-SysProxyReason -Kind $pacKind -Url $conn.AutoConfigUrl -Port $port -Alive $alive -Layer 'pac')
                Advice = (Get-SysProxyAdvice -Kind $pacKind -Port $port)
                Evidence = $(if ($ev2) { $ev2.Summary } else { '' })
                Handshake = $(if ($ev2) { $ev2.Handshake } else { '' })
            })
        }
    }

    # ---- WinHTTP：Windows 独有的一层，安装器与系统服务读它 ----
    # DIVERGE(Win): Mac 没有等价的独立层，那边系统代理只有「每个网络服务一份」那套。
    if (-not $Quick) {
        $wh = Get-WinHttpProxy
        # 读不出来时也要成层（不可修），否则这一层会静默消失：
        # 用户报"上不了网"，工具说"没发现问题"，因为最脏的那层根本不在清单里。
        #
        # 但**不能借 Foreign 表达"读不出来"**：Foreign 是在断言「地址不是本机，
        # 是使用者自己设的」，而读不出来的时候连地址都没有，说成 Foreign 就是编的，
        # 屏幕上还会印出一个只有标签、后面什么都没有的空行，用户完全看不懂。
        # 单列一个 unreadable 结论词，语义是「这一层没读到，不知道」。
        if ($wh -and $wh.State -eq 'unknown') {
            [void]$out.Add(@{
                Layer = 'winhttp'; Url = ''; Port = 0
                Kind = $FindingKinds.Unreadable
                Detail = ('这一层没读到：' + $wh.Detail)
            })
        }
        if ($wh -and $wh.State -eq 'set' -and $wh.Server) {
            $split = Split-ProxyUrl (ConvertTo-SysProxyUrl $wh.Server)
            $port = if ($split) { [int]$split.Port } else { 0 }
            $alive = $null
            if ($split) { $alive = Test-TcpAlive (ConvertTo-ProbeHost $split.Host) $port $timeoutMs }
            $url = ConvertTo-SysProxyUrl $wh.Server
            $whKind = Get-SystemProxyVerdict -Url $url -Port $port -Alive $alive -Managed $managed -Kind 'manual'
            [void]$out.Add(@{
                Layer = 'winhttp'; Url = $url; Port = $port
                Kind = $whKind
                Detail = (Get-SysProxyReason -Kind $whKind -Url $url -Port $port -Alive $alive -Layer 'winhttp')
                Advice = (Get-SysProxyAdvice -Kind $whKind -Port $port)
            })
        }
    }
    return $out
}

# 给一个结论配一句"为什么这么判"。**只用廉价信号**（地址形态、端口三态、是否被管），
# 不引入握手/进程/时间那些贵信号——贵信号会因为环境失败，一旦影响措辞就会影响授权判断。
#
# 为什么必须有：屏幕上只写"能修"等于让用户盲信。他会想知道"你凭什么动我的设置"。
# 说得出依据，他才能自己核对；说不出，这个功能就只是一个黑箱。
# 收集"这个端口现在到底是谁"的证据。**只用于解释，绝不参与授权。**
#
# 三个信号：属主进程 / CONNECT 握手分类 / 是否在客户端目录里。
# 为什么只做解释：它们都会因环境失败（权限不足读不到属主、握手被防火墙拦、
# 自研客户端不在目录里）。一旦它们参与"要不要动手"，失败就会变成"退回可修"——
# 越不可靠越容易删东西。挡在授权外，失效的代价只是"解释少一句"。
#
# 返回 @{ Handshake; OwnerName; OwnerIsClient; CatalogName; Summary } 或 $null（都拿不到）。
function Get-SysProxyEvidence([int]$Port) {
    if ($Port -le 0) { return $null }
    $hs = ''
    $owner = ''
    $isClient = $false
    $catName = ''
    try { $hs = [string](Get-ConnectHandshakeKind $Port) } catch { $hs = '' }
    try {
        $o = Get-PortOwner $Port
        if ($o) { $owner = [string]$o.Name }
    } catch { $owner = '' }
    try {
        if ($owner) {
            $c = Get-ClientByProcessName $owner
            if ($c) { $isClient = $true; $catName = [string]$c.Name }
        }
        if (-not $catName) {
            $c2 = Get-ClientByPort $Port
            if ($c2) { $catName = [string]$c2.Name }
        }
    } catch { }
    if (-not $hs -and -not $owner) { return $null }
    return @{
        Handshake     = $hs
        OwnerName     = $owner
        OwnerIsClient = $isClient
        CatalogName   = $catName
        Summary       = (Get-SysProxyEvidenceText -Handshake $hs -OwnerName $owner -IsClient $isClient -CatalogName $catName)
    }
}

# 把证据说成一句人话。
function Get-SysProxyEvidenceText([string]$Handshake, [string]$OwnerName, [bool]$IsClient, [string]$CatalogName) {
    $parts = @()
    if ($OwnerName) {
        if ($IsClient -and $CatalogName) {
            $parts += ('占用端口的是 ' + $OwnerName + '，像是' + $CatalogName + '在跑')
        } else {
            $parts += ('占用端口的是 ' + $OwnerName)
        }
    }
    switch ($Handshake) {
        'proxy-ok'        { $parts += '它应答了代理握手，确实在工作' }
        'proxy-auth'      { $parts += '它要求密码，是个正经代理' }
        'upstream-fail'   { $parts += '它是代理，但连不上你要访问的地方（多半是节点问题）' }
        'refused'         { $parts += '它说 HTTP，但这次不答应建隧道（不是代理，或者它只服务特定地址）' }
        'not-http'        { $parts += '它不像代理，更像别的程序占着这个端口' }
        'silent'          { $parts += '它连上了但不应答代理握手' }
    }
    if ($parts.Count -eq 0) { return '' }
    return (($parts -join '；') + '。')
}

function Get-SysProxyReason([string]$Kind, [string]$Url, [int]$Port, $Alive, [string]$Layer) {
    $host_ = ''
    try { $sp = Split-ProxyUrl $Url; if ($sp) { $host_ = [string]$sp.Host } } catch { $host_ = '' }
    $isLoop = $false
    try { $isLoop = Test-LoopbackUrl $Url } catch { $isLoop = $false }
    switch ($Kind) {
        'clean'           { return '没有设任何代理，浏览器直接连。' }
        'managed'         { return '这台电脑的代理设置由管理员统一管着，改了也会被改回去。' }
        'alive' {
            # 措辞要分三种情况，别一律说"它正在工作"：
            #   ① 本机地址 + 端口活  → 最可能是翻墙软件在跑
            #   ② 别的形态 + 端口活  → 只说"连得上"，不替它下结论
            # （握手与属主的细节由 Evidence 那一行补，这里只管一句总述。）
            if ($isLoop) { return ('代理地址是本机，端口 ' + $Port + ' 上有程序在听，连得上。') }
            return ('代理地址 ' + $host_ + ' 的端口 ' + $Port + ' 连得上。')
        }
        'residue-blocking' {
            if ($isLoop) { return ('地址是本机，但端口 ' + $Port + ' 上没有任何程序在听。网页请求发出去没人接，所以打不开。') }
            return '这个代理连不上，网页打不开。'
        }
        'residue-slowing' {
            if ($isLoop) { return ('设置脚本指向本机的 ' + $Port + ' 端口，那里已经没程序了。网页能开，但每次都要先等它超时。') }
            return '这个设置脚本连不上，网页会变慢。'
        }
        'foreign' {
            if (-not $host_) { return '这一项的地址读不出来，所以不动它。' }
            if ($Layer -eq 'winhttp') { return '这一项只有系统自带工具在用，浏览器不读它。' }
            # 本机网卡上的地址（allow LAN 的客户端会这么写）要说清，别笼统说成"公司代理"。
            $isOwnNic = $false
            try { $isOwnNic = Test-LocalInterfaceAddress $host_ } catch { $isOwnNic = $false }
            if ($isOwnNic) {
                return ('地址 ' + $host_ + ' 是这台电脑网卡上的地址。它可能是某个客户端开了「允许局域网」后写下的，本工具不动。')
            }
            return ('代理地址是 ' + $host_ + '，不是这台电脑自己——多半是公司或学校给的，本工具不碰。')
        }
        default { return '' }
    }
}

# 给一个结论配一句"你可以做什么"。空串表示"没有需要你做的事"。
function Get-SysProxyAdvice([string]$Kind, [int]$Port) {
    switch ($Kind) {
        'residue-blocking' { return '可以让本工具修掉它（会先备份，能还原）。' }
        'residue-slowing'  { return '可以让本工具修掉它（会先备份，能还原）。' }
        'alive'            { return '不需要做什么。' }
        'managed'          { return '需要的话请找管理员。' }
        'foreign'          { return '如果这是你自己设的，保持原样即可。' }
        default            { return '' }
    }
}
# 用 netsh 而不是直接读注册表：注册表里那份是二进制（WinHttpSettings），
# 解析它等于再写一遍微软的内部格式。netsh 是系统自带、输出稳定、且是官方入口。
#
# 读 WinHTTP 那一层。**返回三态，不许把「读不出来」和「没设」混成一个 $null**：
#   @{ State='set';     Server='host:port' }  确实设了代理
#   @{ State='none' }                          确实没设（Direct access）
#   @{ State='unknown'; Detail='原因' }        读不出来（netsh 不可用、输出认不出）
#
# 为什么必须分开：混成一个 $null 时，netsh 被组策略禁用/被 AppLocker 拦/PATH 坏掉，
# 这一层就会静默消失——用户报「上不了网」，工具说「没发现问题」，因为最脏的那层看不见。
# 而写回去那一步同样靠"回读还是 $null"反推成功，于是"一条命令都没跑"也会报修好了。
function Get-WinHttpProxy {
    try {
        $raw = & netsh winhttp show proxy 2>$null
        $rc = $LASTEXITCODE
        if ($null -eq $raw -or ($raw -is [array] -and $raw.Count -eq 0)) {
            return @{ State = 'unknown'; Detail = if ($rc) { '查询工具返回了错误（代码 ' + $rc + '），可能被安全软件拦住了' } else { '系统没有给出任何结果' } }
        }
        $text = ($raw | Out-String)
        if (-not $text.Trim()) { return @{ State = 'unknown'; Detail = '系统返回了空结果' } }
        # 「直接访问(没有代理服务器)」/ "Direct access (no proxy server)" 都表示没设。
        if ($text -match 'Direct access|直接访问') { return @{ State = 'none' } }
        # 取「主机:端口」。两种形态都要认：
        #   普通主机 / IPv4：`proxy.corp.com:3128`、`127.0.0.1:7078`
        #   IPv6：`[::1]:7078`
        # 原来只有 `[A-Za-z0-9_\.\-\[\]]+:\d+` 一条，它会把 `[::1]:7078` 从中间的冒号处切，
        # 得到 `1]:7078` —— 拆不出端口，这一层就直接从结果里消失（不报、不修、不提示）。
        # 方括号那一条必须排前面：正则取第一个匹配，顺序反了会被普通规则先吃掉。
        $m = [regex]::Match($text, '\[[0-9A-Fa-f:]+\]:\d+|[A-Za-z0-9_\.\-]+:\d+')
        # 有输出、但没有"直接访问"字样、也取不到 host:port —— 这是"认不出"，
        # 不是"没设"。报 unknown，让界面如实说这一层没法判断。
        if (-not $m.Success) { return @{ State = 'unknown'; Detail = '系统给的格式认不出来' } }
        return @{ State = 'set'; Server = $m.Value }
    } catch {
        return @{ State = 'unknown'; Detail = $_.Exception.Message }
    }
}

# ------------------------------------------------------------------------------
# 6. 备份：事务日志（每次修复一个还原点，能撤销最近一次）
# ------------------------------------------------------------------------------
# 落在 monitor\ 下，与 state.snapshot 同一个运行时目录：卸载时会一起清掉，
# 不新增一个「卸载之后还留在盘上」的位置。
#
# 为什么必须能还原：修系统代理是整个工具里除了卸载之外唯一会动「别人写的设置」的地方。
# 用户回头发现某个程序连不上了，唯一能接受的说法是「我把它改回去」。
#
# **为什么从单槽位（doctor.bak）改成日志**：
# 单槽位只有一个还原点，而且「只写一次」。一旦可修的层不止一处（系统代理 + 终端工具配置），
# 这条规则立刻自相矛盾：修完 A 再修 B，槽位里存的仍是 A 之前的原样，
# 用户按「还原」以为撤掉的是刚才那次，实际撤掉的是很久以前那次——
# 而屏幕上只说「已经改回去了」。日志让每一次修复各自留一个还原点，
# 「还原」= 撤销最近一次，语义与用户的心智一致。
#
# 格式（三行一段，追加写）：
#   --- op <utc> <op-id> <result>
#   <key>=<escaped value>        字段由各层自己声明，编解码沿用下面两个函数
#   --- end
# *result* 由还原时决定不了，写入时先记 'applied'；还原成功后再追加一条 op 记 'restored'
# 是不必要的复杂度——还原只读，不写。
#
# 保留最近 $DoctorJournalKeep 段：太多了没人看，也把用户的日志目录撑大。
$DoctorJournalKeep = 5

function Get-DoctorJournalPath { return (Join-Path $MonitorDir 'doctor.journal') }
# 旧版单槽位备份的位置。**仍然读、不再写**：升级前修过的人手里有它，
# 直接丢掉等于把他们唯一的一次还原机会删了。
function Get-SysProxyBackupPath { return (Join-Path $MonitorDir 'doctor.bak') }

# 备份文件的行编码。
#
# **不能借用 runtime 层的快照编解码**：doctor 只允许依赖 base + probe，
# 引 runtime 会造出 doctor <-> runtime 的新环（门禁 1/2 会拦）。
# 这里的值都是地址、路径、例外列表这类单行短串，
# 只需要挡住换行与 = 两个字符：
#   换行会让一条记录裂成两行；= 会让「第一个 = 之前是键」这条解析错位。
# 转义用 % 领头（与 URL 编码同形，读起来不陌生），% 自己先转，避免二次解码。
function ConvertTo-DoctorBakValue([string]$Text) {
    if (-not $Text) { return '' }
    return ($Text -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A' -replace '=', '%3D')
}
function ConvertFrom-DoctorBakValue([string]$Text) {
    if (-not $Text) { return '' }
    return ($Text -replace '%3D', '=' -replace '%0A', "`n" -replace '%0D', "`r" -replace '%25', '%')
}

# 造一个还原点的正文（不含首尾标记）。$Fields 是有序哈希表：键名只许 [a-z0-9_]，
# 值一律经过转义。写成有序是因为一个还原点往往要按顺序读回来。
function Format-DoctorJournalEntry([string]$OpId, [string]$Result, $Fields) {
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add(('--- op {0} {1} {2}' -f ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')), $OpId, $Result))
    foreach ($k in $Fields.Keys) {
        if ($k -notmatch '^[a-z0-9_]+$') { continue }
        [void]$lines.Add(('{0}={1}' -f $k, (ConvertTo-DoctorBakValue ([string]$Fields[$k]))))
    }
    [void]$lines.Add('--- end')
    return ($lines -join "`n")
}

# 读全部还原点，返回数组（旧的在前，最近的在后）。
#
# **读不出来返回空数组，不是抛错**：调用方据此说「没有可还原的记录」。
# 猜一个默认值去写，等于把用户的设置改成我们编的。
#
# 读的时候同时兼容旧的 doctor.bak：它没有首尾标记，整份就是一段字段。
# 把它当成一条 op 接在最前面（它年代最久），于是升级前修过的人**第一天就能还原**，
# 不需要先再修一次。
function Read-DoctorJournal {
    $ops = New-Object System.Collections.ArrayList
    # 旧单槽位备份：字段是 flags/server/bypass/pac，与系统代理那一层的字段同名。
    try {
        $oldPath = Get-SysProxyBackupPath
        if (Test-Item $oldPath) {
            $map = @{}
            foreach ($line in [System.IO.File]::ReadAllLines($oldPath, [System.Text.Encoding]::UTF8)) {
                $m = [regex]::Match($line, '^(flags|server|bypass|pac)=(.*)$')
                if ($m.Success) { $map[$m.Groups[1].Value] = (ConvertFrom-DoctorBakValue $m.Groups[2].Value) }
            }
            $f = 0
            if ($map.ContainsKey('flags') -and [int]::TryParse([string]$map['flags'], [ref]$f) -and $f -ge 0 -and $f -le 0x0F) {
                $fields = [ordered]@{
                    inspector = 'sysproxy'
                    layer     = 'legacy'
                    flags     = [string]$f
                    server    = [string]$map['server']
                    bypass    = [string]$map['bypass']
                    pac       = [string]$map['pac']
                }
                [void]$ops.Add(@{ Stamp = ''; OpId = 'legacy-bak'; Result = 'applied'; Fields = $fields })
            }
        }
    } catch { }
    try {
        $path = Get-DoctorJournalPath
        if (-not (Test-Item $path)) { return $ops }
        $cur = $null
        foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
            $t = ([string]$line).TrimEnd()
            if ($t -match '^--- op (\S+) (\S+) (\S+)$') {
                $cur = @{ Stamp = $Matches[1]; OpId = $Matches[2]; Result = $Matches[3]; Fields = [ordered]@{} }
                continue
            }
            if ($t -eq '--- end') {
                # 没有字段的 op 是写了一半的：丢掉，别让「还原」去动一个空记录。
                if ($cur -and $cur.Fields.Count -gt 0) { [void]$ops.Add($cur) }
                $cur = $null
                continue
            }
            if ($null -eq $cur) { continue }
            $m = [regex]::Match($t, '^([a-z0-9_]+)=(.*)$')
            if ($m.Success) { $cur.Fields[$m.Groups[1].Value] = (ConvertFrom-DoctorBakValue $m.Groups[2].Value) }
        }
    } catch { }
    return $ops
}

# 覆盖写入整份日志（用于撤销后消费掉那一段）。
#
# 与 Add-DoctorJournalEntry 分开：那个是"追加并裁到保留条数"，
# 这个是"按给定的段重写"。删除只能靠重写——按字节截会把段截成半截，
# 下次读出来是一条无效记录。
function Write-DoctorJournalOps($Ops) {
    try {
        $null = Ensure-MonitorPaths
        if (-not $MonitorDir) { return $false }
        $path = Get-DoctorJournalPath
        $list = @($Ops | Where-Object { $null -ne $_ })
        if ($list.Count -eq 0) {
            if (Test-Item $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            return $true
        }
        $text = ''
        foreach ($op in $list) { $text += (Format-DoctorJournalEntry $op.OpId $op.Result $op.Fields) }
        Write-Text -Path $path -Text $text -WithBom $false
        return (Test-Item $path)
    } catch {
        return $false
    }
}
# 追加一个还原点。返回 $true = 确实落盘了。
#
# **写不下来就返回假，调用方据此不动手**：没有退路的修改不该发生。
# 保留最近 $DoctorJournalKeep 段——超了就整份重写（而不是截断），
# 因为要按「段」丢，按字节截会把最后一段截成半截，下次读出来是一条无效记录。
function Add-DoctorJournalEntry([string]$OpId, $Fields, [string]$Result = 'applied') {
    try {
        $null = Ensure-MonitorPaths
        if (-not $MonitorDir) { return $false }
        if (-not (Test-Item $MonitorDir)) { [void](New-Item -Path $MonitorDir -ItemType Directory -Force -ErrorAction SilentlyContinue) }
        $entry = Format-DoctorJournalEntry $OpId $Result $Fields
        $existing = @(Read-DoctorJournal | Where-Object { $_.OpId -ne 'legacy-bak' })
        # 只留最后 N-1 段，再拼上新的这一段，总数不超过 N。
        $keep = @()
        $keepCount = [Math]::Max(0, $DoctorJournalKeep - 1)
        if ($existing.Count -gt $keepCount) { $existing = @($existing | Select-Object -Last $keepCount) }
        foreach ($op in $existing) {
            $keep += (Format-DoctorJournalEntry $op.OpId $op.Result $op.Fields)
        }
        $keep += $entry
        Write-Text -Path (Get-DoctorJournalPath) -Text (($keep -join "`n") + "`n") -WithBom $false
        return (Test-Item (Get-DoctorJournalPath))
    } catch {
        return $false
    }
}

# 有没有能撤销的记录。界面据此决定要不要印「输 r 还原」那一行：
# 备份在就允许还原，与「当下有没有可修项」是两件事。
function Test-DoctorJournalHasRestore {
    try { return (@(Read-DoctorJournal).Count -gt 0) } catch { return $false }
}


# ------------------------------------------------------------------------------
# 7. 修复：只修可修的那几项，且必须回读确认
# ------------------------------------------------------------------------------
# 返回一个结论对象（**三态，不许塌缩**）：
#   Result = 'none'     没有可修项（什么都没做）
#          = 'fixed'   改完回读，值确实变了
#          = 'failed'  写失败，或回读没变
#          = 'nobackup' 备份写不下来，为了安全选择不动
#   Changed 修好的层（manual/pac/winhttp）
#   Failed  没修成的层
#
# 为什么必须回读：WinINET 接口返回 true 只代表「调用没报错」，
# 不代表设置真的生效（组策略会在下一瞬间覆盖它）。不确认就报成功，
# 就是屏幕上说修好了、浏览器还是打不开——这类 bug 最难查。
function Repair-SystemProxy {
    param([switch]$IncludeWinHttp)
    # 两个集合必须是 ArrayList，不能是 @()：@() 是**固定长度**数组，
    # .Add() 会抛 "Collection was of a fixed size."。而它外面套着 try/catch 时
    # 会被吞成一句红字，结果对象却已经按「修好了」往下走——
    # 屏幕上说已修复、实际一个字节没动。实测踩到过，所以写在这里。
    $res = @{
        Result = 'none'
        Changed = (New-Object System.Collections.ArrayList)
        Failed = (New-Object System.Collections.ArrayList)
        Detail = ''
    }
    $before = Get-SystemProxyConnection
    if (-not $before) { $res.Result = 'failed'; $res.Detail = 'read'; return $res }

    $layers = @(Get-SystemProxyLayers)
    $fixable = @($layers | Where-Object { (Test-FindingFixable $_.Kind) })
    if ($fixable.Count -eq 0) { return $res }

    # 备份写不下来就不动手：没有退路的修改不该发生。
    #
    # 一个还原点只记「这次动之前长什么样」。同一层里 manual 与 pac 可能同时可修，
    # 但它们改的是同一份 WinINET 配置，所以合成**一个**还原点——分开记会造出
    # 两条内容相同、还原时互相覆盖的记录。
    $backupFields = [ordered]@{
        inspector = 'sysproxy'
        flags     = [string]$before.Flags
        server    = [string]$before.ProxyServer
        bypass    = [string]$before.ProxyBypass
        pac       = [string]$before.AutoConfigUrl
    }
    if (-not (Add-DoctorJournalEntry 'sysproxy' $backupFields)) { $res.Result = 'nobackup'; return $res }

    # 目标标志位：把「可修的层」关掉，其余层原样保留。
    #
    # **必须逐位改、只碰出问题的那一位。** 在 WinINET 里"关手动代理"与"关 PAC"不是独立的：
    # 有些客户端（Clash Verge Rev 的 sysopt.rs 明说）在用命令行方式切代理时，
    # 关 PAC 会连带清掉代理标志位，所以它必须先清 PAC 再设代理——两个方向都会互踩。
    # 我们走 INTERNET_PER_CONN_OPTION 逐项下发，实测不会互踩
    # （0x7 清手动后得 0x5，PAC 位与 PAC 地址都还在），但**这个结论依赖于"只改那一位"**：
    # 谁要是图省事改成"写整个 flags=1"或"只写 ProxyEnable=0"，就会把用户的 PAC 一起清掉，
    # 造出"修好手动代理、弄坏 PAC"的新故障。事后的回读比对（含 AutoConfigUrl）就是为这条兜底。
    # 只关出问题的那一层——把整个代理关掉会连带干掉用户正常的公司代理。
    $newFlags = $before.Flags
    $newServer = $before.ProxyServer
    $newPac = $before.AutoConfigUrl
    foreach ($f in $fixable) {
        if ($f.Layer -eq 'manual') {
            # **逐段处理，不许整段清空。**
            #
            # Windows 允许分协议写法：`http=127.0.0.1:7890;https=127.0.0.1:7891`。
            # 若 7890 死了、7891 还跟着当前客户端活着，整段清空就把用户唯一还通的
            # 那条路径删掉了——而判据是"只修指向死端口的那一项"，实现却退化成"全关"。
            # 做法：拆开、只删掉判为死的那几段、其余原样拼回去；全删空才清标志位。
            $kept = @()
            foreach ($seg in ([string]$before.ProxyServer -split ';')) {
                $s = $seg.Trim()
                if (-not $s) { continue }
                $one = ConvertTo-ProxyUrl ($s -replace '^[A-Za-z][A-Za-z0-9+.-]*=\s*', '')
                if (-not $one) {
                    # 认不出的段原样保留：宁可这次没修成，也不删掉一段我们看不懂的配置。
                    $kept += $s
                    continue
                }
                $sp = Split-ProxyUrl $one
                if (-not $sp) { $kept += $s; continue }
                $segAlive = Test-TcpAlive (ConvertTo-ProbeHost $sp.Host) ([int]$sp.Port) 800
                $segVerdict = Get-SystemProxyVerdict -Url $one -Port ([int]$sp.Port) -Alive $segAlive
                if (Test-FindingFixable $segVerdict) { continue }   # 这一段是死的，丢掉
                $kept += $s
            }
            if ($kept.Count -eq 0) {
                $newFlags = $newFlags -band (-bnot $ProxyTypeProxy)
                $newServer = ''
            } else {
                # 还有活着的段：保留代理标志位，只把字符串换成剩下的部分。
                $newServer = ($kept -join ';')
            }
            [void]$res.Changed.Add('manual')
        } elseif ($f.Layer -eq 'pac') {
            $newFlags = $newFlags -band (-bnot $ProxyTypeAutoProxyUrl)
            $newPac = ''
            [void]$res.Changed.Add('pac')
        }
    }
    # 一个都没落到可写层（例如只有 winhttp 可修）时不发写请求，避免空写。
    if ($res.Changed.Count -gt 0) {
        $ok = Set-SystemProxyConnection -Flags $newFlags -ProxyServer $newServer `
            -ProxyBypass $before.ProxyBypass -AutoConfigUrl $newPac
        if (-not $ok) { $res.Result = 'failed'; $res.Detail = 'write'; return $res }
        # 回读确认：值与期望不一致就是没成功，如实报。
        #
        # **三个字符串项也要比**，不能只比 Flags。只比标志位的话，"标志位改了、
        # 服务器地址/PAC 地址还留在 blob 里"这种情况会被判成成功——
        # 而那正是"屏幕上说修好了、浏览器还是打不开"的来源。
        $after = Get-SystemProxyConnection
        if (-not $after) { $res.Result = 'failed'; $res.Detail = 'verify'; return $res }
        $flagOk = ([int]$after.Flags -eq [int]$newFlags)
        $valOk = ([string]$after.ProxyServer -eq [string]$newServer) -and
                 ([string]$after.AutoConfigUrl -eq [string]$newPac)
        if (-not $flagOk -or -not $valOk) { $res.Result = 'failed'; $res.Detail = 'verify'; return $res }
    }

    # WinHTTP 是独立一层，需要管理员。不是管理员时不代跑，由界面给出命令。
    if ($IncludeWinHttp) {
        $whLayers = @($layers | Where-Object { $_.Layer -eq 'winhttp' -and (Test-FindingFixable $_.Kind) })
        if ($whLayers.Count -gt 0) {
            if (Test-IsElevated) {
                # 必须看 netsh 自己的退出码。原来的判法是"回读还没读到就算修好"——
                # 而 netsh 根本跑不起来时，回读同样读不到，于是"一条命令都没跑"也报成功。
                $resetOk = $false
                try { & netsh winhttp reset proxy 2>$null | Out-Null; $resetOk = ($LASTEXITCODE -eq 0) } catch { $resetOk = $false }
                $after2 = Get-WinHttpProxy
                if ($resetOk -and $after2 -and $after2.State -eq 'none') {
                    [void]$res.Changed.Add('winhttp')
                } else {
                    [void]$res.Failed.Add('winhttp')
                }
            } else {
                [void]$res.Failed.Add('winhttp')
                $res.Detail = 'needadmin'
            }
        }
    }

    # 结论必须是三态，不许把「部分失败」压成「修好了」。
    #
    # 原来写成「失败有、成功零」才算 failed —— 于是「WinINET 修好了、WinHTTP 没修成」
    # 会被报成 fixed，界面打「[完成] 修好了」，而 Failed 列表从头到尾没人读过。
    # 那正是这个功能最不能犯的错：屏幕上说好了，实际还留着一层指着死端口。
    if ($res.Failed.Count -eq 0) {
        $res.Result = 'fixed'
    } elseif ($res.Changed.Count -eq 0) {
        $res.Result = 'failed'
    } else {
        $res.Result = 'partial'
    }
    return $res
}

# 撤销一次系统代理修复。返回 'ok' / 'failed' / 'skip'。
function Restore-SysProxySnapshot($Op) {
    if (-not $Op) { return 'skip' }
    $fl = 0
    if (-not [int]::TryParse([string]$Op.Fields['flags'], [ref]$fl)) { return 'skip' }
    # 长度校验：真实的标志位只用到低 4 位。超出这个范围的数字说明记录被写坏了
    # （测试里出现过 "garbage" 被读到、flags 变成 0 的情况），
    # 按 0 用会把代理整个关掉，所以这里直接判成「读不出来」。
    if ($fl -lt 0 -or $fl -gt 0x0F) { return 'skip' }
    $server = [string]$Op.Fields['server']
    $bypass = [string]$Op.Fields['bypass']
    $pac    = [string]$Op.Fields['pac']
    $ok = Set-SystemProxyConnection -Flags $fl -ProxyServer $server -ProxyBypass $bypass -AutoConfigUrl $pac
    if (-not $ok) { return 'failed' }
    $after = Get-SystemProxyConnection
    if (-not $after) { return 'failed' }
    # 三类值都要比：只比标志位的话，「标志位改回去了、地址还留着」会被判成功——
    # 而那正是「屏幕上说改回去了、浏览器还是不对」的来源。
    if ([int]$after.Flags -ne $fl) { return 'failed' }
    if ([string]$after.ProxyServer -cne $server) { return 'failed' }
    if ([string]$after.AutoConfigUrl -cne $pac) { return 'failed' }
    return 'ok'
}
