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

# 把 [Environment] 的 User 位置映射到注册表的取值类型。
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
    $desired = Get-ProxyVarTable $Port
    $existingNoProxy = [Environment]::GetEnvironmentVariable("NO_PROXY", "User")
    $desired["NO_PROXY"] = Merge-NoProxy $existingNoProxy $DefaultNoProxy
    $changed = $false
    foreach ($n in $desired.Keys) {
        if ([Environment]::GetEnvironmentVariable($n, "User") -ne $desired[$n]) { $changed = $true; break }
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
    Write-UserEnvValues -Values $desired
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
    $plan = @{}
    foreach ($n in $ProxyVarNames) {
        $cur = [Environment]::GetEnvironmentVariable($n, "User")
        if (-not $cur) { continue }
        if ($n -eq "NO_PROXY") {
            # 只回收我们加进去的那几项：从当前值里逐项减掉默认集，剩下的原样写回（保留用户的写法与顺序），
            # 减空了才删变量。不能按"整份等于默认集"判断——用户原本就有 NO_PROXY 时，我们加的那几项
            # 会永远留在他的值里，回收不干净。
            # 但快照里本来就有的条目是使用者的，哪怕它正好等于默认项也不许减（见 Test-SnapshotRecorded）。
            $oursSet = Get-NormalizedNoProxyEntries $ours
            $bakSet = @()
            try {
                if (Test-RegKey $PrevEnvRegKey) {
                    $rawBak = (Get-ItemProperty -Path $PrevEnvRegKey -Name "NO_PROXY" -ErrorAction SilentlyContinue)."NO_PROXY"
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
            $plan[$n] = if ($keep.Count -eq 0) { $null } else { ($keep -join ',') }
            continue
        }
        if ($n -eq "NODE_USE_ENV_PROXY") {
            if (Test-IsOwnedProxyValue $n $cur) { $plan[$n] = $null }
            continue
        }
        if ($n -in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")) {
            # 归属判定：形状上是本机地址、且安装快照里本来没有它，才是我们写下的。
            # 用户自己挂的 mitmproxy（http://127.0.0.1:8080）同样有快照，一律不动。
            if (Test-IsOwnedProxyValue $n $cur) { $plan[$n] = $null }
            continue
        }
        $plan[$n] = $null
    }
    if ($plan.Count -gt 0) { Write-UserEnvValues -Values $plan }
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
    return ($Value -like "http://127.0.0.1:*")
}

# 第 2 层：安装快照里本来就记着它吗？记着 = 使用者自己的，我们永远不许动。
# 这一层是必需的：光看形状会把用户自己写的 NO_PROXY=localhost、或 mitmproxy 的
# http://127.0.0.1:8080 当成我们的，在 off 态每 30 轮定时删掉，日志还谎称"回收残留"。
function Test-SnapshotRecorded([string]$Name, [string]$Value) {
    try {
        if (-not (Test-RegKey $PrevEnvRegKey)) { return $false }
        $raw = (Get-ItemProperty -Path $PrevEnvRegKey -Name $Name -ErrorAction SilentlyContinue).$Name
        if ($null -eq $raw) { return $false }
        if ($Name -ne "NO_PROXY") { return ($Value -eq [string]$raw) }
        # NO_PROXY 逐条比：快照里出现的条目一律算使用者的。
        $bakSet = Get-NormalizedNoProxyEntries ([string]$raw)
        foreach ($e in (Get-NormalizedNoProxyEntries $Value)) { if ($bakSet -contains $e) { return $true } }
        return $false
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
    if ($FirstInstall) { return $false }
    if ($Name -eq "NODE_USE_ENV_PROXY") { return ($Value -eq "1") }
    if ($Name -in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")) { return ($Value -like "http://127.0.0.1:*") }
    return $false
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
            $bak = (Get-ItemProperty -Path $PrevEnvRegKey -Name $n -ErrorAction SilentlyContinue).$n
            if ($null -ne $bak) {
                $kindName = (Get-ItemProperty -Path $PrevEnvRegKey -Name ("{0}__Kind" -f $n) -ErrorAction SilentlyContinue).("{0}__Kind" -f $n)
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
function Apply-State([string]$state) {
    # "unknown" = 这一轮不知道（端口枚举失败），不是"不在翻墙"。
    # 绝不能拿它去写变量：状态串的下标解析会把它当成 "on:<端口>"，
    # 于是把代理地址写成 http://127.0.0.1:nown。
    if (-not $state -or $state -eq "unknown") { return }
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
    try {
        if ($state -eq "off") {
            if (Test-ProxyVarsPresent) {
                Remove-UserEnvVars
                Broadcast-EnvironmentChange
                Write-MonitorLog "代理已关闭 -> 已删除代理变量，恢复直连"
            }
        } else {
            $port = $state.Substring(3)
            $want = "http://127.0.0.1:$port"
            if (Sync-UserEnvVars $port) {
                Broadcast-EnvironmentChange
                Write-MonitorLog "检测到本地代理端口 $port -> 已注入代理 $want"
            }
        }
    } finally {
        if ($gate) {
            try { if ($held) { $gate.ReleaseMutex() } } catch {}
            try { $gate.Dispose() } catch {}
        }
    }
}
