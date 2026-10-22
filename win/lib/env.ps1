# ==============================================================================
#  env.ps1 — 环境变量层：用户级代理变量的写入、删除、归属判定、快照与还原
#  注入与删除共用同一张变量表，不许只动其中几个。
# ==============================================================================

# ------------------------------------------------------------------------------
# 0. Win32 广播 API（通知系统"环境变量已变化"，纯系统自带能力）
# ------------------------------------------------------------------------------
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class EnvProxyNative {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
'@ -ErrorAction SilentlyContinue
} catch {}

function Broadcast-EnvironmentChange {
    try {
        $r = [UIntPtr]::Zero
        [EnvProxyNative]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero,
            "Environment", 0x0002, 3000, [ref]$r) | Out-Null
    } catch {}
}

# --- 用户级环境变量的唯一写入口 -------------------------------------------------
# 为什么不用 [Environment]::SetEnvironmentVariable(..., "User")：
#   它每写一个变量都要同步等一次 WM_SETTINGCHANGE 广播结束（实测单个约 11 秒，
#   5 个变量 56 秒、删 6 个 67 秒）。而本项目的契约是"整批写完之后统一广播一次"，
#   于是前面每一次等待都是纯粹的浪费——首次安装之所以要卡一分钟，根子就在这里。
#   直接写 HKCU\Environment 是同一件事的另一条路，实测 5 个变量连带删除只要 10 毫秒。
#
# 它还有两个实实在在的好处：
#   1) 保留原值类型。SetEnvironmentVariable 一律按 REG_SZ 写回，把 REG_EXPAND_SZ
#      的 %USERPROFILE% 这类引用永久展开成字面路径；直接写可以原样保持类型。
#   2) 批量打开一次键，写 N 个变量只付一次打开开销。
#
# 广播不在这里做：调用方写完一批之后再调一次 Broadcast-EnvironmentChange。
# 分开是刻意的——状态机在同一轮里可能既删又写，广播一次就够。

# 读 HKCU\Environment 里的原始值（不做环境变量展开）。
# 为什么不能用 [Environment]::GetEnvironmentVariable(..., "User")：
# 它返回的是**已展开**的值。用户原有 NO_PROXY 常写成 %USERPROFILE%,internal.corp
# （企业环境里设例外域名的常见写法），用那个 API 读出来就变成
# C:\Users\某人,internal.corp，我们再合并写回时，%USERPROFILE% 这个引用就永久没了。
# 类型还是 REG_EXPAND_SZ，但里面已经没有可展开的东西——用户换用户名或改路径后失效。
# 这里直接读注册表原文，引用保持原样。

# 读安装快照里的原始值（不做环境变量展开）。快照里所有读取都必须走这里。
#
# 为什么不直接用 Get-ItemProperty：它对 REG_EXPAND_SZ 会展开。当前快照的值是用
# Set-ItemProperty 写进去的（落成 REG_SZ，不含类型信息），所以读出来恰好不展开——
# 但那是**存储方式的副作用，不是读取方的保证**。快照里同时记着 __Kind 字段、
# 还原时按原类型写回，说明这套设计本来就打算保留类型；哪天写入端改成保留
# REG_EXPAND_SZ，这几处读取就会静默开始展开，用户换用户名或改路径后失效，
# 而且不报任何错。用不展开的 API 读，行为就不再依赖写入端存成什么类型。
function Get-PrevEnvRaw([string]$Name) {
    $key = $null
    try {
        # $PrevEnvRegKey 是 PowerShell 提供程序路径（HKCU:\Software\...），
        # 转成 .NET 的键路径再用 DoNotExpandEnvironmentNames 读原文。
        $sub = $PrevEnvRegKey -replace '^HKCU:\\', ''
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sub, $false)
        if ($null -eq $key) { return $null }
        $v = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $v) { return $null }
        return [string]$v
    } catch {
        return $null
    } finally {
        if ($key) { try { $key.Close() } catch {} }
    }
}
function Get-UserEnvRaw([string]$Name) {
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $false)
        if ($null -eq $key) { return $null }
        $v = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $v) { return $null }
        return [string]$v
    } catch {
        return $null
    } finally {
        if ($key) { try { $key.Close() } catch {} }
    }
}
# 空值表示"删除这个变量"（SetEnvironmentVariable(...,$null) 的等价写法）。
function Set-UserEnvRaw([hashtable]$Values) {
    if (-not $Values -or $Values.Count -eq 0) { return }
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
        if ($null -eq $key) { return }
        foreach ($n in $Values.Keys) {
            $v = $Values[$n]
            if ($null -eq $v) {
                try { $key.DeleteValue($n, $false) } catch {}
                continue
            }
            # 原值若是 REG_EXPAND_SZ 就按 REG_EXPAND_SZ 写回，其余按 REG_SZ。
            # 读不到旧类型（新变量）时用 REG_SZ——与 SetEnvironmentVariable 的默认一致。
            $kind = [Microsoft.Win32.RegistryValueKind]::String
            try {
                $oldKind = $key.GetValueKind($n)
                if ($oldKind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) {
                    $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
                }
            } catch {}
            $key.SetValue($n, [string]$v, $kind)
        }
    } catch {
        # 写失败必须抛出去，不许吞。
        # 吞掉的后果实测过：需要 5 个变量时只写进 3 个，函数却"成功"返回，
        # 调用方照常广播并记日志"已注入代理"——用户得到的是半套变量，
        # 而日志说一切正常。更糟的是下一轮的幂等判据会发现"不齐"，再写再失败再谎报，
        # 每轮都重复一遍。这正是本项目最怕的"半代理"，必须让调用方看得见。
        throw
    } finally {
        if ($key) { try { $key.Close() } catch {} }
    }
}

# 批量写入一组代理变量（名 => 值）。值传 $null 表示删除该变量。
# 这是"写用户级环境变量"的唯一通道：库内任何地方都不许再直接调
# [Environment]::SetEnvironmentVariable(..., "User")——那会退回到每次等广播的老路。
# 调用方负责在整批写完之后调一次 Broadcast-EnvironmentChange。
function Write-UserEnvValues([hashtable]$Values) {
    Set-UserEnvRaw -Values $Values
}

# 批量删除一组变量（名 => $null 的语法糖，调用处读起来更清楚）。
function Remove-UserEnvNames([string[]]$Names) {
    if (-not $Names -or $Names.Count -eq 0) { return }
    $t = @{}
    foreach ($n in $Names) { $t[$n] = $null }
    Set-UserEnvRaw -Values $t
}

function Get-EnvProxyValue {
    return [Environment]::GetEnvironmentVariable($ProxyVarNames[0], "User")
}

function Sync-UserEnvVars([string]$Port) {
    # 幂等判据是**整套变量**是否都已就位，不是只看代理地址：
    # 只看地址会让"代理值对、但别的变量缺失或漂移"的半代理状态一直无人纠正。
    # 返回是否真的写了东西——调用方据此决定要不要广播（静默时零广播、零写入）。
    # 地址现场探测：只绑 ::1 的代理在 IPv4 上连不上，写死 127.0.0.1 会注入一个用不了的地址。
    $desired = Get-ProxyVarTable $Port (Get-ProxyUrlForPort ([int]$Port))
    # 用不展开的读法：用户原有值里的 %USERPROFILE% 这类引用必须原样保留，
    # 用 GetEnvironmentVariable 会把它展开成字面路径，合并写回后引用就永久丢了。
    $existingNoProxy = Get-UserEnvRaw "NO_PROXY"
    $desired["NO_PROXY"] = Merge-NoProxy $existingNoProxy $DefaultNoProxy
    $changed = $false
    foreach ($n in $desired.Keys) {
        # 比较两边都要用不展开的读法，否则永远不相等：desired 里的 NO_PROXY 是用
        # Get-UserEnvRaw 取原文再合并出来的（可能含 %USERPROFILE%），而 GetEnvironmentVariable
        # 读出来是展开后的字面路径。两者一比较就恒不相等，于是每轮都判"要写"、
        # 每轮都多一次同步广播。实测连跑 4 轮全部返回 True，正是这个原因。
        if ((Get-UserEnvRaw $n) -ne $desired[$n]) { $changed = $true; break }
    }
    # 归属记录**先写**，再判断要不要改环境变量。
    # 这两件事必须解耦：升级安装时代理正开着、端口没变，"值已齐全"于是提前 return，
    # 归属记录就永远建不起来——之后代理一关，已开着的窗口拿不到归属判据，一直清不掉。
    # 它的语义是"我们现在拥有哪些值"，只要 on 态成立就该有，与"这次要不要写"无关。
    # 必须用 OpenSubKey(...,$true) 以**可写**方式打开：Get-Item 拿到的是只读键，
    # SetValue 会抛 "Cannot write to the registry key"。这个异常会被 catch 吞掉，
    # 于是键建出来了、内容却是空的——钩子的归属判据等于不存在。
    try {
        if (-not (Test-RegKey $OwnedRegKey)) { New-Item -Path $OwnedRegKey -Force -ErrorAction Stop | Out-Null }
        $ok = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\EnvProxy\Owned", $true)
        if ($null -ne $ok) {
            # 重新持有这些值 = 撤回"已归还"标记。不删的话，off 时打的标记会一直留着，
            # 此后钩子永远认为"这些值已经不是我们的"，on 态反而不会跟随。
            foreach ($n in $desired.Keys) {
                $ok.SetValue($n, [string]$desired[$n], [Microsoft.Win32.RegistryValueKind]::String)
            }
            $ok.Close()
        }
    } catch {}
    if (-not $changed) { return $false }
    # 写失败时返回 $false 而不是抛给上层：调用方（Apply-State / 安装流程）要的是
    # "这一轮没写成"，好如实报告；抛异常会让安装整个中断，连后面几步都不跑。
    try { Write-UserEnvValues -Values $desired } catch { return $false }
    return $true
}

function Remove-UserEnvVars {
    # 注入与删除共用一张表，两者不可能漂移；再按名复查一遍，确保"按名之后确实一个都不剩"——
    # 无主残留正是"半代理"诡异行为的来源。
    #
    # 例外：只回收**本工具自己写下的** NO_PROXY / NODE_USE_ENV_PROXY。
    # 环境变量是用户级共享资源，用户或别的工具可能把这两项用于自己的用途；
    # 值不是我们写的那一个，就说明不是我们的东西，一律不动。
    $ours = $DefaultNoProxy
    # 先算出每一项该变成什么，最后一次性写入：判断逻辑与写入动作分开，
    # 既不重复付注册表打开的开销，也让"到底动了哪些变量"在一处看得全。
    # 要写的和要删的分开收：删除走 Remove-UserEnvNames 这个具名入口，
    # 写入走 Write-UserEnvValues。两个入口都直写注册表，广播由调用方统一发一次。
    $plan = @{}
    $drop = @()
    foreach ($n in $ProxyVarNames) {
        # 用不展开的读法：用户值里的 %USERPROFILE% 这类引用必须原样保留。用 GetEnvironmentVariable
        # 读出来已被展开，写回时引用就永久丢了（与注入方向同一个病）。
        $cur = Get-UserEnvRaw $n
        if ($n -eq "NO_PROXY") {
            # 只回收我们加进去的那几项：从当前值里逐项减掉默认集，剩下的原样写回（保留用户的写法与顺序），
            # 减空了才删变量。不能按"整份等于默认集"判断——用户原本就有 NO_PROXY 时，我们加的那几项
            # 会永远留在他的值里，回收不干净。
            # 但快照里本来就有的条目是使用者的，哪怕它正好等于默认项也不许减（见 Test-SnapshotRecorded）。
            $oursSet = Get-NormalizedNoProxyEntries $ours
            $bakSet = @()
            try {
                if (Test-RegKey $PrevEnvRegKey) {
                    # 快照也要不展开地读：Get-ItemProperty 对 REG_EXPAND_SZ 同样会展开。
                    $rawBak = Get-PrevEnvRaw "NO_PROXY"
                    if ($rawBak) { $bakSet = Get-NormalizedNoProxyEntries ([string]$rawBak) }
                }
            } catch {}
            $keep = @()
            foreach ($part in ($cur -split ',')) {
                $t = $part.Trim()
                if (-not $t) { continue }
                $key = $t.ToLowerInvariant()
                if ($bakSet -contains $key) { $keep += $t; continue }      # 使用者自己的，原样留
                if ($oursSet -contains $key) { continue }                   # 我们加的，摘掉
                $keep += $t
            }
            if ($keep.Count -eq 0) { $drop += $n } else { $plan[$n] = ($keep -join ',') }
            continue
        }
        if ($n -eq "NODE_USE_ENV_PROXY") {
            if (Test-IsOwnedProxyValue $n $cur) { $drop += $n }
            continue
        }
        if ($n -in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")) {
            # 归属判定：形状上是本机地址、且安装快照里本来没有它，才是我们写下的。
            # 用户自己挂的 mitmproxy（http://127.0.0.1:8080）同样有快照，一律不动。
            if (Test-IsOwnedProxyValue $n $cur) { $drop += $n }
            continue
        }
        # 这里刻意不留"其余变量一律删"的兜底：$ProxyVarNames 的 5 个名字都被上面
        # 三条分支覆盖，兜底永远走不到；留着它反而是个陷阱——将来真加进第 6 个变量时，
        # 它会静默走进一个**没有归属判定**的分支，直接把用户自己设的值删掉。
        # 新增变量时应当在这里显式写一条自己的归属规则，让编译器式的"漏了会报错"变成结构约束。
    }
    # 写失败只影响"清得干不干净"，不该让整个 off 流程崩掉——off 之后监控每轮都会再试。
    # 与注入路径的区别在这里：注入失败必须让人看见（否则用户以为在翻墙、实际没走代理），清理失败下一轮自愈。
    try {
        if ($plan.Count -gt 0) { Write-UserEnvValues -Values $plan }
        if ($drop.Count -gt 0) { Remove-UserEnvNames -Names $drop }
    } catch {}
    # 归属记录在这里**不动**：它记的是"我们写下过哪些值"，不是"我们现在是否持有"。
    # 为什么不能在这里清：off 之后，已经开着的窗口里还挂着我们注入的值，钩子唯一的判据
    # 就是这份记录——清掉它，off 就清不掉已开窗口，终端同步这条主功能直接失效。
    # 代价是一个很窄的边界：off 之后使用者又手设成**一模一样**的值（同端口、同写法），
    # 钩子会把它当成我们写的而清掉。Mac 侧的 off 哨兵是同一语义（按"值相等"守卫），
    # 双端一致。真正需要保护的是公司代理、别的端口这类**不同**的值——那些永不受影响。
}

# --- 归属判定分三层，每层只回答一个问题 ------------------------------------------
# 第 1 层：这个值「长得像」我们写的吗？只看形状，纯函数。
function Test-OwnedProxyShape([string]$Name, [string]$Value) {
    if (-not $Value) { return $false }
    if ($Name -eq "NO_PROXY") {
        $oursSet = Get-NormalizedNoProxyEntries $DefaultNoProxy
        foreach ($e in (Get-NormalizedNoProxyEntries $Value)) { if ($oursSet -contains $e) { return $true } }
        return $false
    }
    if ($Name -eq "NODE_USE_ENV_PROXY") { return ($Value -eq "1") }
    return (Test-LoopbackProxyUrl $Value)
}

# 第 2 层：安装快照里本来就记着它吗？记着 = 使用者自己的，我们永远不许动。
# 这一层是必需的：光看形状会把用户自己写的 NO_PROXY=localhost、或 mitmproxy 的
# http://127.0.0.1:8080 当成我们的，在 off 态每 30 轮定时删掉，日志还谎称"回收残留"。
function Test-SnapshotRecorded([string]$Name, [string]$Value) {
    try {
        if (-not (Test-RegKey $PrevEnvRegKey)) { return $false }
        $raw = Get-PrevEnvRaw $Name
        if ($null -eq $raw) { return $false }
        # 判据是「快照里**记过这个名字**」，不是「值恰好相等」。
        #
        # 这一条以前写成值相等，逻辑是反的：使用者装之前在用户环境变量里手设了
        # HTTP_PROXY=http://127.0.0.1:8080（本地 mitmproxy、公司内网跳板、自己写的转发都长这样），
        # 我们注入时把它改成 127.0.0.1:<翻墙端口>，于是「值不相等」-> 判成不是他的 ->
        # off 的那一刻把它删掉。他原本能用的东西某天开始不通，没人告诉他；
        # 卸载时按快照还原回来，于是症状变成「时好时坏、重装一次就好了」。
        # 快照里出现过的名字就是使用者的地盘，我们永不动它——这才是这条函数的本意
        #（NO_PROXY 分支下面的注释讲的是同一件事，代理地址分支当年没跟上）。
        # 快照里没有这个名字 = 装前是空的 = 现在这个值必然是我们写的。
        if ($Name -ne "NO_PROXY") { return $true }
        # NO_PROXY 要逐条比，而且判据必须与 Remove-UserEnvVars 同一套：
        # 那边是"逐项减掉默认集，快照里本来就有的条目原样留"。
        # 如果这里改成"任一条目命中就算使用者的"，就会出现
        # 门槛认为"不是我们的、不用清"，而回收函数照样删掉其中几项——
        # 两个判据各说各话，正是项目注释反复强调要防的那种残留。
        # 所以这里同样回答："这个值里还有没有**不在快照里**的条目"。
        # 有 → 说明我们掺了东西进来（返回 $false，不算使用者原有的）。
        # 全都在快照里 → 整份都是使用者自己的（返回 $true）。
        $bakSet = Get-NormalizedNoProxyEntries ([string]$raw)
        foreach ($e in (Get-NormalizedNoProxyEntries $Value)) {
            if (-not ($bakSet -contains $e)) { return $false }
        }
        return $true
    } catch { return $false }
}

# 第 3 层：到底该不该回收。形状像、且快照里没有它，才是我们写下的。
# 判据与 Remove-UserEnvVars 必须同一套，否则会出现"删得掉但门槛没让它删"的残留。
function Test-IsOwnedProxyValue([string]$Name, [string]$Value) {
    if (-not (Test-OwnedProxyShape $Name $Value)) { return $false }
    return (-not (Test-SnapshotRecorded $Name $Value))
}
# 我们该持有的那套变量现在还在不在。判据与 Remove-UserEnvVars 完全一致：
# 三个代理变量只要有一个还有值就算在，NO_PROXY 看有没有我们写的默认项，
# NODE_USE_ENV_PROXY 看值是不是我们写的 1。两边共用一套判据，才不会出现
# "删得掉但门槛没让它删"的残留（半代理）。
function Test-ProxyVarsPresent {
    foreach ($n in $ProxyVarNames) {
        if (Test-IsOwnedProxyValue $n ([Environment]::GetEnvironmentVariable($n, "User"))) { return $true }
    }
    return $false
}

# 快照时这个值要不要当成"我们写的"跳过（纯函数，不碰注册表，可单测）。
# "像我们写的"不够——还要机器上本来就有本工具的安装记录，才可能是我们留下的。
# 首次安装时机器上还没有我们的任何东西：此刻本机地址的代理变量、
# 以及 NODE_USE_ENV_PROXY=1，都是使用者自己的配置。把它们当我们的跳过，
# 卸载时会被删掉又无从还原——用了几年的手设配置就这么凭空没了。
function Test-SnapshotSkip([string]$Name, [string]$Value, [bool]$FirstInstall) {
    if (-not $Value) { return $false }
    # 归属记录里逐字记着这个值 = 这就是我们自己写下的，永远不是使用者的原值。
    # 这一条必须排在"首次安装"之前，因为它比那个推断更硬：
    # 首次安装的推断前提是"机器上还没有我们的东西"，而**卸载没清干净时那个前提不成立**——
    # 残留的本机地址代理值会在下一次全新安装时被当成使用者的、存进快照、再按快照还原，
    # 于是永远清不掉。实测踩过：ALL_PROXY 与 NODE_USE_ENV_PROXY 两项就这样活过了两次卸载，
    # 卸载每次都报"已恢复到安装前的状态"。
    #
    # 判据是**值相等**（对 NO_PROXY 是逐项被默认集覆盖），不是"快照里记过这个名字"——
    # 后者是 Test-SnapshotRecorded 的语义，它回答的是"使用者的地盘里有没有这个名字"，
    # 拿它来判归属会把使用者的公司代理也判成我们的（那样他就永久丢了自己的配置）。
    # 归属记录记的才是"我们写下过哪些值"，与终端钩子用的是同一份记录。
    if (Test-IsOurOwnedValue $Name $Value) { return $true }
    if ($FirstInstall) { return $false }
    if ($Name -eq "NODE_USE_ENV_PROXY") { return ($Value -eq "1") }
    if ($Name -in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")) { return (Test-LoopbackProxyUrl $Value) }
    return $false
}

# 这个值是不是"我们写下过的那个"（只查归属记录，不查快照）。
# 与 Test-SnapshotRecorded 的区别要说清，两者答的不是同一个问题：
#   Test-SnapshotRecorded  "使用者装之前有没有设过这个名字"——有就是他的地盘，我们永不删
#   本函数                "这个值是不是我们自己写下来的"——是就不该进快照
# 混用会把使用者的配置当成我们的（丢配置），或把我们的当成使用者的（永远清不掉）。
function Test-IsOurOwnedValue([string]$Name, [string]$Value) {
    try {
        if (-not (Test-RegKey $OwnedRegKey)) { return $false }
        $k = Get-Item -LiteralPath $OwnedRegKey -ErrorAction SilentlyContinue
        if (-not $k) { return $false }
        $rec = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $rec) { return $false }
        if ($Name -eq "NO_PROXY") {
            # NO_PROXY 是"逐项合并"的：只有当前值里每一项都还在我们记下的那份里，
            # 才说明整份都是我们写的。多出来的条目是使用者自己加的，那就不是我们的。
            $recSet = Get-NormalizedNoProxyEntries ([string]$rec)
            foreach ($e in (Get-NormalizedNoProxyEntries $Value)) {
                if (-not ($recSet -contains $e)) { return $false }
            }
            return $true
        }
        return ([string]$rec -eq [string]$Value)
    } catch { return $false }
}

# 安装时快照原值（只记一次）：卸载时按快照还原，用户原来的配置不丢。
# 重装/升级时代理正开着，我们上次写下的值不能当成使用者的（见 Test-SnapshotSkip）。
# 注意：不用 Volatile Environment 做"会话级"优化——它是未文档化机制，语义不保证；持久化即 HKCU 本体。
# 类型也要留底：原值若是 REG_EXPAND_SZ（含 %引用%），按 REG_SZ 写回会提前展开、腐化用户配置。
# 所以读未展开值、存类型，还原时按原类型写回。
function Snapshot-PrevEnv([bool]$FirstInstall = $false) {
    try {
        if (Get-Item -LiteralPath $PrevEnvRegKey -ErrorAction SilentlyContinue) { return }
        # 父键按需建；子键不带 -Force——注册表上的 -Force 是"清空重建"，不是"已存在就跳过"。
        if (-not (Test-RegKey $ScriptPathRegKey)) { New-Item -Path $ScriptPathRegKey -Force -ErrorAction SilentlyContinue | Out-Null }
        New-Item -Path $PrevEnvRegKey -ErrorAction Stop | Out-Null
        $envKey = Get-Item -LiteralPath "HKCU:\Environment" -ErrorAction SilentlyContinue
        foreach ($n in $ProxyVarNames) {
            $raw = $null
            $kind = "String"
            if ($envKey) {
                try {
                    $raw = $envKey.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    $kind = $envKey.GetValueKind($n).ToString()
                } catch {}
            }
            if ($null -eq $raw) { continue }
            if (Test-SnapshotSkip $n $raw $FirstInstall) { continue }
            Set-ItemProperty -Path $PrevEnvRegKey -Name $n -Value $raw -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $PrevEnvRegKey -Name ("{0}__Kind" -f $n) -Value $kind -ErrorAction SilentlyContinue
        }
    } catch {}
}

# 卸载时按快照还原用户原值，还原完删掉快照键。无快照时什么都不做。
# 按快照时的原类型写回：REG_EXPAND_SZ 的原值若按 REG_SZ 写回，里面的 %引用% 会被提前展开。
function Restore-PrevEnv {
    try {
        if (-not (Get-Item -LiteralPath $PrevEnvRegKey -ErrorAction SilentlyContinue)) { return }
        $plain = @{}
        foreach ($n in $ProxyVarNames) {
            $bak = Get-PrevEnvRaw $n
            # 快照里这一条如果就是"我们写下过的那个值"，它从来不是使用者的原值——
            # 不能还原回去。老版本的快照确实可能存着这种条目（首次安装时把本机地址的
            # 代理值也一起存了），还原它等于把我们的东西当成他的配置装回去：
            # 卸载报"已恢复原状"，而 ALL_PROXY / NODE_USE_ENV_PROXY 一直留着。
            # 这条判断在还原侧做，所以**已经存在的坏快照也会被自愈**，不用等用户重装。
            if ($null -ne $bak -and (Test-IsOurOwnedValue $n ([string]$bak))) { continue }
            if ($null -ne $bak) {
                $kindName = Get-PrevEnvRaw ("{0}__Kind" -f $n)
                if ($kindName -eq "ExpandString") {
                    Set-ItemProperty -Path "HKCU:\Environment" -Name $n -Value $bak -Type ExpandString -ErrorAction SilentlyContinue
                } else {
                    $plain[$n] = $bak
                }
            }
        }
        # 非 ExpandString 的那些一次性写回：来源明确是"字符串"，不必再猜原类型。
        if ($plain.Count -gt 0) { Write-UserEnvValues -Values $plain }
        Remove-Item -LiteralPath $PrevEnvRegKey -Recurse -Force -ErrorAction SilentlyContinue
    } catch {}
}

# 把状态应用到系统（幂等：整套变量都已就位就什么都不做）
# 返回值说明这一步有没有做成：
#   $true  = 状态已经对齐（可能本来就齐，也可能是这次写好的）
#   $false = 尝试写了但失败（调用方必须如实报告，不许说"已校正"）
# 之前没有返回值，安装流程只能一律打"已按当前状态校正"——把写失败也说成成功，
# 用户以为在走代理、实际是半套变量。
function Apply-State([string]$state) {
    # "unknown" = 这一轮不知道（端口枚举失败），不是"不在翻墙"。
    # 绝不能拿它去写变量：状态串的下标解析会把它当成 "on:<端口>"，
    # 于是把代理地址写成 http://127.0.0.1:nown。
    if (-not $state -or $state -eq "unknown") { return $true }
    # 全局互斥：安装入口与监控主循环可能同一时刻各校正一次（点"安装"时两者都在跑），
    # 没有这把锁就会出现"两边都判定要写 → 重复写 + 重复广播"。锁只覆盖"判断 + 写入"这段，
    # 拿到锁的一方写完，另一方进来时看到已就位，自然什么都不做。
    # 拿不到锁也照常往下走：锁只是省一次重复广播，跳过写入反而会让变量停在错的状态。
    $gate = $null
    $held = $false
    try {
        $gate = New-Object System.Threading.Mutex($false, (Get-MutexName "EnvProxyApplyState"))
        $held = $gate.WaitOne(5000)
    } catch { $held = $false }
    $appliedOk = $true
    try {
        if ($state -eq "off") {
            if (Test-ProxyVarsPresent) {
                Remove-UserEnvVars
                Broadcast-EnvironmentChange
                Write-MonitorLog "代理已关闭 -> 已删除代理变量，恢复直连"
            }
        } else {
            $port = $state.Substring(3)
            # 期望值要与实际注入的地址同源，否则 IPv6-only 的代理会被判成"没写成"。
            $want = Get-ProxyUrlForPort ([int]$port)
            if (-not (Sync-UserEnvVars $port)) {
                # Sync-UserEnvVars 返回 false 有两种情况：本来就齐（正常）、或者写失败。
                # 靠"值到底齐了没有"再确认一次，才能区分这两者。
                $appliedOk = ((Get-UserEnvRaw "HTTPS_PROXY") -eq $want)
            } else {
                Broadcast-EnvironmentChange
                Write-MonitorLog "检测到本地代理端口 $port -> 已注入代理 $want"
            }
        }
    } catch {
        $appliedOk = $false
    } finally {
        if ($gate) {
            try { if ($held) { $gate.ReleaseMutex() } } catch {}
            try { $gate.Dispose() } catch {}
        }
    }
    # 给 Git Bash 那份终端同步看的镜像文件。注册表它读不了（MSYS2 的 /proc/registry
    # 只能在最顶层 shell 进程里读，函数里读到的是空），所以这里额外落一份普通文件。
    # 写失败不影响任何判定：读不到文件时那份钩子什么都不做。
    try { Write-TerminalStateFile $state } catch {}
    return $appliedOk
}

# 把当前状态落到 LOCALAPPDATA 下的 EnvProxy 目录，文件名 terminal.env，供 Git Bash 的提示符钩子读。
# 格式是每行 KEY=VALUE：无前缀行是「当前该注入的值」，owned_ 前缀行是「归属记录」
# （值仍等于它才允许清除，与注册表 Owned 键同一套判据）。
# 一次性整份重写：读的一方只会看到写之前或写之后的完整内容，不会看到半份。
function Write-TerminalStateFile([string]$State) {
    # 这个文件的语义是「归属通道」，不是「当前状态快照」。
    # 两者的差别决定 off 态该写什么：当快照看就该清空；可清空之后钩子手上再没有任何依据
    # 判断「窗口里那几个值是不是我们写的」，于是它只能什么都不做——结果是关掉代理后，
    # 已经开着的 Git Bash 窗口永远停在死端口上，git/curl/npm 全部 ECONNREFUSED，
    # 而错误信息里根本不出现本工具的名字，用户会去查网络、防火墙、DNS。
    # 所以 off 态也要留 owned_*：钩子据此知道「这些值当初是我们写下的，现在可以安全撤掉」。
    # owned_* 存的是**当初写下的那个值**，不是当前值：撤除判据是「窗口里的值仍等于它」，
    # 与我们后来改了什么无关。
    # 取值来源分两种，都必须有明确出处：
    #   on          -> 本轮要注入的值（就是它本身）
    #   其他（off/unknown/空）-> 注册表 Owned 键里的历史值
    #                          （此时变量已删，只能从记录取；绝不拿当前环境变量顶替——
    #                            那可能是用户自己的公司代理，冒充"我们写的"会让钩子删掉它）
    $dir = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "EnvProxy"
    $path = Join-Path $dir "terminal.env"
    $names = @("HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","NO_PROXY","NODE_USE_ENV_PROXY")
    $lines = @()
    $own = @{}
    if ($State -and $State -ne "unknown" -and $State.StartsWith("on:")) {
        # 与注入端同源：镜像文件里写的地址必须就是变量里那个，否则 Git Bash 跟着它写进
        # 窗口的地址会连不上（只绑 ::1 的代理在 IPv4 上是拒绝的）。
        $url = Get-ProxyUrlForPort ([int]$State.Substring(3))
        $np = [string](Get-UserEnvRaw "NO_PROXY")
        $node = [string](Get-UserEnvRaw "NODE_USE_ENV_PROXY")
        $lines += "HTTP_PROXY=$url"
        $lines += "HTTPS_PROXY=$url"
        $lines += "ALL_PROXY=$url"
        if ($np) { $lines += "NO_PROXY=$np" }
        if ($node) { $lines += "NODE_USE_ENV_PROXY=$node" }
        $own["HTTP_PROXY"] = $url
        $own["HTTPS_PROXY"] = $url
        $own["ALL_PROXY"] = $url
        if ($np) { $own["NO_PROXY"] = $np }
        if ($node) { $own["NODE_USE_ENV_PROXY"] = $node }
    } else {
        try {
            $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\EnvProxy\Owned', $false)
            if ($null -ne $k) {
                foreach ($n in $names) {
                    $v = $k.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    if ($null -ne $v -and -not [string]::IsNullOrEmpty([string]$v)) { $own[$n] = [string]$v }
                }
                $k.Close()
            }
        } catch {}
    }
    foreach ($n in $names) {
        if ($own.ContainsKey($n)) { $lines += ("owned_" + $n + "=" + $own[$n]) }
    }
    # 落盘。用 base 层的 Write-Text（同目录临时文件 + 整体替换），不在这里再写一遍
    # 那套原子逻辑：本项目已经因为 File.Replace 的第三参数踩过一次坑，而这个模式
    # 在仓库里已经有三份，不该有第四份。
    # 明确不带 BOM（Write-Text 的默认）：这个文件是给 bash 读的，行首多一个 BOM 会让
    # 第一行变成「\uFEFFowned_HTTP_PROXY」，钩子从此认不出那条记录，变量也就清不掉。
    $text = ""
    if ($lines.Count -gt 0) { $text = (($lines -join "`n") + "`n") }
    Write-Text -Path $path -Text $text
}
