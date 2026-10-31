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
# 只在这里定义一次，界面与状态页都读它——写两处必然分叉。
$SysProxyKinds = @{
    Clean         = 'clean'            # 压根没设代理
    Blocking      = 'residue-blocking' # 手动代理指向死端口：真断网，最高优先级
    Slowing       = 'residue-slowing'  # 自动配置脚本指向死端口：能上网但会卡几秒
    Alive         = 'alive'            # 回环地址 + 端口活着：翻墙软件正在用，不动
    Foreign       = 'foreign'          # 不是回环：公司/学校代理，工具不碰
    Managed       = 'managed'          # 被组策略、描述文件管着：改了也会被改回，不动
}

# WinINET 的连接标志位。值与 Windows SDK 一致，改动会导致写进去的开关错位。
$ProxyTypeDirect       = 0x01
$ProxyTypeProxy        = 0x02
$ProxyTypeAutoProxyUrl = 0x04
$ProxyTypeAutoDetect   = 0x08

# 判据里「哪个结论允许被修」只有一处：**只有 residue 两类**。
# 界面要判断「这项能不能修」时调这个，不许自己写 -eq 比较——
# 那样加一类结论就会漏掉界面那一处。
function Test-SysProxyFixable([string]$Kind) {
    return ($Kind -eq $SysProxyKinds.Blocking -or $Kind -eq $SysProxyKinds.Slowing)
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
    if ($Managed) { return $SysProxyKinds.Managed }
    if (-not $Url -and $Port -le 0) { return $SysProxyKinds.Clean }
    # 地址拆不出端口、也不是合法地址：无从判断死活，归「不是本机代理」那类——不动。
    if (-not (Test-LoopbackUrl $Url) -and $Port -le 0) { return $SysProxyKinds.Foreign }
    if (-not (Test-LoopbackUrl $Url)) { return $SysProxyKinds.Foreign }
    if ($null -eq $Alive) { return $SysProxyKinds.Foreign }
    if ($Alive) { return $SysProxyKinds.Alive }
    if ($Kind -eq 'pac') { return $SysProxyKinds.Slowing }
    return $SysProxyKinds.Blocking
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
        AutoDetect  = $false
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
    $r.AutoDetect  = (($flags -band $ProxyTypeAutoDetect) -ne 0)
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
    if ($ProxyServer) { [void]$entries.Add(@{ Option = $script:IpcProxyServer; Value = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($ProxyServer) }) }
    if ($ProxyBypass) { [void]$entries.Add(@{ Option = $script:IpcProxyBypass; Value = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($ProxyBypass) }) }
    if ($AutoConfigUrl) { [void]$entries.Add(@{ Option = $script:IpcAutoConfig; Value = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($AutoConfigUrl) }) }
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
function Test-SystemProxyManaged {
    # 「禁止更改代理设置」策略：值名固定，出现即生效（DWORD 1）。
    # ProxySettingsPerUser=0 是「让代理设置作用于整台机器」，用户级改动本就不生效。
    $policyNames = @(
        'ProxySettingsPerUser'
        'DisableCachingOfSSLPages'
        'ProxySettingsPerUserMachine'
        'PreventChangingProxySettings'
    )
    $keys = @(
        'HKLM:\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings',
        'HKCU:\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'
    )
    foreach ($k in $keys) {
        if (-not (Test-RegKey $k)) { continue }
        foreach ($n in $policyNames) {
            $v = Get-ItemProperty -LiteralPath $k -Name $n -ErrorAction SilentlyContinue
            if (-not $v) { continue }
            $raw = $null
            try { $raw = $v.$n } catch {}
            if ($null -eq $raw) { continue }
            # ProxySettingsPerUser=0 才表示「整机统一」，=1 是默认（每用户各管各的）。
            if ($n -eq 'ProxySettingsPerUser') { if ([int]$raw -eq 0) { return $true } continue }
            if ([int]$raw -eq 1) { return $true }
        }
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
#   Kind   结论词（见 $SysProxyKinds）
#   Detail 给人看的补充（什么时候用得到由界面决定）
#
# -Quick 只查手动代理与自动配置两层，且超时短——供每 2–3 秒刷新的状态页用。
# 不加 -Quick 是全量（多查 winhttp），供体检页用。
# **一个函数、两种深度**，不是两套代码：复制一份轻量实现，迟早两边结论不一致。
function Get-SystemProxyLayers {
    param([switch]$Quick)
    $timeoutMs = if ($Quick) { 300 } else { 800 }
    $managed = Test-SystemProxyManaged
    $out = New-Object System.Collections.ArrayList

    # ---- 手动代理与自动配置脚本：同一个接口一次读回 ----
    $conn = Get-SystemProxyConnection
    if ($conn) {
        if (($conn.Flags -band $ProxyTypeProxy) -ne 0 -and $conn.ProxyServer) {
            $split = Split-ProxyUrl (ConvertTo-ProxyUrl $conn.ProxyServer)
            $port = if ($split) { [int]$split.Port } else { 0 }
            $alive = $null
            if ($split) { $alive = Test-TcpAlive $split.Host $port $timeoutMs }
            $url = ConvertTo-ProxyUrl $conn.ProxyServer
            [void]$out.Add(@{
                Layer = 'manual'; Url = $url; Port = $port
                Kind = (Get-SystemProxyVerdict -Url $url -Port $port -Alive $alive -Managed $managed -Kind 'manual')
                Detail = ''
            })
        }
        if (($conn.Flags -band $ProxyTypeAutoProxyUrl) -ne 0 -and $conn.AutoConfigUrl) {
            $split = Split-ProxyUrl $conn.AutoConfigUrl
            $port = if ($split) { [int]$split.Port } else { 0 }
            $alive = $null
            if ($split) { $alive = Test-TcpAlive $split.Host $port $timeoutMs }
            [void]$out.Add(@{
                Layer = 'pac'; Url = $conn.AutoConfigUrl; Port = $port
                Kind = (Get-SystemProxyVerdict -Url $conn.AutoConfigUrl -Port $port -Alive $alive -Managed $managed -Kind 'pac')
                Detail = ''
            })
        }
    }

    # ---- WinHTTP：Windows 独有的一层，安装器与系统服务读它 ----
    # DIVERGE(Win): Mac 没有等价的独立层，那边系统代理只有「每个网络服务一份」那套。
    if (-not $Quick) {
        $wh = Get-WinHttpProxy
        if ($wh -and $wh.Server) {
            $split = Split-ProxyUrl (ConvertTo-ProxyUrl $wh.Server)
            $port = if ($split) { [int]$split.Port } else { 0 }
            $alive = $null
            if ($split) { $alive = Test-TcpAlive $split.Host $port $timeoutMs }
            $url = ConvertTo-ProxyUrl $wh.Server
            [void]$out.Add(@{
                Layer = 'winhttp'; Url = $url; Port = $port
                Kind = (Get-SystemProxyVerdict -Url $url -Port $port -Alive $alive -Managed $managed -Kind 'manual')
                Detail = ''
            })
        }
    }
    return $out
}

# 读 WinHTTP 的代理设置。返回 $null = 没设或读不出来。
#
# 用 netsh 而不是直接读注册表：注册表里那份是二进制（WinHttpSettings），
# 解析它等于再写一遍微软的内部格式。netsh 是系统自带、输出稳定、且是官方入口。
function Get-WinHttpProxy {
    try {
        $raw = & netsh winhttp show proxy 2>$null
        if (-not $raw) { return $null }
        $text = ($raw | Out-String)
        # 「直接访问(没有代理服务器)」/ "Direct access (no proxy server)" 都表示没设。
        if ($text -match 'Direct access|直接访问') { return $null }
        $m = [regex]::Match($text, '[A-Za-z0-9_\.\-\[\]]+:\d+')
        if (-not $m.Success) { return $null }
        return @{ Server = $m.Value }
    } catch {
        return $null
    }
}

# ------------------------------------------------------------------------------
# 6. 备份：动手之前先把原样记下来，能还原
# ------------------------------------------------------------------------------
# 落在 monitor\ 下，与 state.snapshot 同一个运行时目录：卸载时会一起清掉，
# 不新增一个「卸载之后还留在盘上」的位置。
#
# 为什么必须能还原：修系统代理是整个工具里除了卸载之外唯一会动「别人写的设置」的地方。
# 用户回头发现某个程序连不上了，唯一能接受的说法是「我把它改回去」。
function Get-SysProxyBackupPath { return (Join-Path $MonitorDir 'doctor.bak') }

# 备份文件的行编码。
#
# **不能借用 runtime 层的快照编解码**：doctor 只允许依赖 base + probe，
# 引 rutime 会造出 doctor <-> runtime 的新环（门禁 1/2 会拦）。
# 这里的值只有代理地址、例外列表、PAC 地址三种，都是单行 ASCII 或带 ; 的短串，
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

# 写备份。**只写一次**：每次覆盖就失效（用户第一次修之前的原样才是要还原的那个）。
# 已经有备份就不动它。
function Backup-SystemProxy {
    param($Conn)
    if (-not $Conn) { return $false }
    try {
        # MonitorDir 由 base 层按需算出来；没装过的机器上它可能还没初始化。
        $null = Ensure-MonitorPaths
        if (-not $MonitorDir) { return $false }
        if (-not (Test-Item $MonitorDir)) { [void](New-Item -Path $MonitorDir -ItemType Directory -Force -ErrorAction SilentlyContinue) }
        $path = Get-SysProxyBackupPath
        if (Test-Item $path) { return $true }
        $lines = @(
            ('flags={0}' -f $Conn.Flags)
            ('server={0}' -f (ConvertTo-DoctorBakValue $Conn.ProxyServer))
            ('bypass={0}' -f (ConvertTo-DoctorBakValue $Conn.ProxyBypass))
            ('pac={0}' -f (ConvertTo-DoctorBakValue $Conn.AutoConfigUrl))
        )
        Write-Text -Path $path -Text ($lines -join "`n")
        return (Test-Item $path)
    } catch {
        return $false
    }
}

# 读回备份。文件不存在或读不懂都返回 $null——调用方据此说「没有可还原的记录」，
# 不能猜一个默认值去写：猜错等于把用户的设置改成我们编的。
function Read-SystemProxyBackup {
    try {
        $path = Get-SysProxyBackupPath
        if (-not (Test-Item $path)) { return $null }
        $map = @{}
        foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
            $m = [regex]::Match($line, '^(flags|server|bypass|pac)=(.*)$')
            if ($m.Success) { $map[$m.Groups[1].Value] = (ConvertFrom-DoctorBakValue $m.Groups[2].Value) }
        }
        if (-not $map.ContainsKey('flags')) { return $null }
        $f = 0
        if (-not [int]::TryParse([string]$map['flags'], [ref]$f)) { return $null }
        # 长度校验：真实的标志位只用到低 4 位。超出这个范围的数字说明文件被写坏了
        # （测试里出现过 "garbage" 被读到、flags 变成 0 的情况），
        # 按 0 用会把代理整个关掉，所以这里直接判成「读不出来」。
        if ($f -lt 0 -or $f -gt 0x0F) { return $null }
        return @{
            Flags = $f
            ProxyServer = [string]$map['server']
            ProxyBypass = [string]$map['bypass']
            AutoConfigUrl = [string]$map['pac']
        }
    } catch {
        return $null
    }
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
    $fixable = @($layers | Where-Object { (Test-SysProxyFixable $_.Kind) })
    if ($fixable.Count -eq 0) { return $res }

    # 备份写不下来就不动手：没有退路的修改不该发生。
    if (-not (Backup-SystemProxy $before)) { $res.Result = 'nobackup'; return $res }

    # 目标标志位：把「可修的层」关掉，其余层原样保留。
    # 只关出问题的那一层——把整个代理关掉会连带干掉用户正常的公司代理。
    $newFlags = $before.Flags
    $newServer = $before.ProxyServer
    $newPac = $before.AutoConfigUrl
    foreach ($f in $fixable) {
        if ($f.Layer -eq 'manual') {
            $newFlags = $newFlags -band (-bnot $ProxyTypeProxy)
            $newServer = ''
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
        $after = Get-SystemProxyConnection
        if (-not $after) { $res.Result = 'failed'; $res.Detail = 'verify'; return $res }
        $flagOk = ([int]$after.Flags -eq [int]$newFlags)
        if (-not $flagOk) { $res.Result = 'failed'; $res.Detail = 'verify'; return $res }
    }

    # WinHTTP 是独立一层，需要管理员。不是管理员时不代跑，由界面给出命令。
    if ($IncludeWinHttp) {
        $whLayers = @($layers | Where-Object { $_.Layer -eq 'winhttp' -and (Test-SysProxyFixable $_.Kind) })
        if ($whLayers.Count -gt 0) {
            if (Test-IsElevated) {
                try { & netsh winhttp reset proxy 2>$null | Out-Null } catch {}
                $after2 = Get-WinHttpProxy
                if ($after2 -and $after2.Server) { [void]$res.Failed.Add('winhttp') }
                else { [void]$res.Changed.Add('winhttp') }
            } else {
                [void]$res.Failed.Add('winhttp')
                $res.Detail = 'needadmin'
            }
        }
    }

    $res.Result = if ($res.Failed.Count -gt 0 -and $res.Changed.Count -eq 0) { 'failed' } else { 'fixed' }
    return $res
}

# 从备份还原。返回 $true = 回过读、值对上了。
#
# **没有备份时什么都不做**。原来这里先 Set 再判断，读不出备份时
# Flags 取到 $null → 转成 0 → 等于「直连」，于是把用户的代理整个关掉了。
# 实测踩到：备份文件是被写坏的内容，还原一次代理就从「手动代理开着」变成「全关」。
# 没有可还原的记录，唯一安全的动作是不动。
function Restore-SystemProxyBackup {
    $bak = Read-SystemProxyBackup
    if (-not $bak) { return $false }
    if ($null -eq $bak.Flags) { return $false }
    $ok = Set-SystemProxyConnection -Flags $bak.Flags -ProxyServer $bak.ProxyServer `
        -ProxyBypass $bak.ProxyBypass -AutoConfigUrl $bak.AutoConfigUrl
    if (-not $ok) { return $false }
    $after = Get-SystemProxyConnection
    if (-not $after) { return $false }
    return ([int]$after.Flags -eq [int]$bak.Flags)
}
