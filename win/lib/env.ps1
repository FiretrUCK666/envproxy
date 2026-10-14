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
    if (-not $changed) { return $false }
    foreach ($n in $desired.Keys) {
        [Environment]::SetEnvironmentVariable($n, $desired[$n], "User")
    }
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
    foreach ($n in $ProxyVarNames) {
        $cur = [Environment]::GetEnvironmentVariable($n, "User")
        if (-not $cur) { continue }
        if ($n -eq "NO_PROXY") {
            # 只回收我们加进去的那几项：从当前值里逐项减掉默认集，剩下的原样写回（保留用户的写法与顺序），
            # 减空了才删变量。不能按"整份等于默认集"判断——用户原本就有 NO_PROXY 时，我们加的那几项
            # 会永远留在他的值里，回收不干净。
            $oursSet = Get-NormalizedNoProxyEntries $ours
            $keep = @()
            foreach ($part in ($cur -split ',')) {
                $t = $part.Trim()
                if (-not $t) { continue }
                if ($oursSet -contains $t.ToLowerInvariant()) { continue }
                $keep += $t
            }
            if ($keep.Count -eq 0) { [Environment]::SetEnvironmentVariable($n, $null, "User") }
            else { [Environment]::SetEnvironmentVariable($n, ($keep -join ','), "User") }
            continue
        }
        if ($n -eq "NODE_USE_ENV_PROXY") {
            if ($cur -eq "1") { [Environment]::SetEnvironmentVariable($n, $null, "User") }
            continue
        }
        if ($n -in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")) {
            # 归属判定：只有本机地址才是我们写下的，用户或公司工具写的其他地址一律不动。
            if ($cur -like "http://127.0.0.1:*") { [Environment]::SetEnvironmentVariable($n, $null, "User") }
            continue
        }
        [Environment]::SetEnvironmentVariable($n, $null, "User")
    }
}

# 我们该持有的那套变量现在还在不在。判据与 Remove-UserEnvVars 完全一致：
# 三个代理变量只要有一个还有值就算在，NO_PROXY 看有没有我们写的默认项，
# NODE_USE_ENV_PROXY 看值是不是我们写的 1。两边共用一套判据，才不会出现
# "删得掉但门槛没让它删"的残留（半代理）。
function Test-ProxyVarsPresent {
    $oursSet = Get-NormalizedNoProxyEntries $DefaultNoProxy
    foreach ($n in $ProxyVarNames) {
        $cur = [Environment]::GetEnvironmentVariable($n, "User")
        if (-not $cur) { continue }
        if ($n -eq "NO_PROXY") {
            foreach ($e in (Get-NormalizedNoProxyEntries $cur)) { if ($oursSet -contains $e) { return $true } }
            continue
        }
        if ($n -eq "NODE_USE_ENV_PROXY") { if ($cur -eq "1") { return $true }; continue }
        # 归属判定与删除同口径：别人的代理地址不算我们的痕迹。
        if ($cur -like "http://127.0.0.1:*") { return $true }
    }
    return $false
}

# 安装时快照原值（只记一次）：卸载时按快照还原，用户原来的配置不丢。
# 属于我们自己的值视为无（升级路径下安装时代理正开着，不能把刚写的值当成用户的）。
function Snapshot-PrevEnv {
    try {
        if (Get-Item -LiteralPath $PrevEnvRegKey -ErrorAction SilentlyContinue) { return }
        New-Item -Path $PrevEnvRegKey -Force -ErrorAction Stop | Out-Null
        foreach ($n in $ProxyVarNames) {
            $cur = [Environment]::GetEnvironmentVariable($n, "User")
            if (-not $cur) { continue }
            if ($n -eq "NODE_USE_ENV_PROXY" -and $cur -eq "1") { continue }
            if (($n -in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")) -and ($cur -like "http://127.0.0.1:*")) { continue }
            Set-ItemProperty -Path $PrevEnvRegKey -Name $n -Value $cur -ErrorAction SilentlyContinue
        }
    } catch {}
}

# 卸载时按快照还原用户原值，还原完删掉快照键。无快照时什么都不做。
function Restore-PrevEnv {
    try {
        if (-not (Get-Item -LiteralPath $PrevEnvRegKey -ErrorAction SilentlyContinue)) { return }
        foreach ($n in $ProxyVarNames) {
            $bak = (Get-ItemProperty -Path $PrevEnvRegKey -Name $n -ErrorAction SilentlyContinue).$n
            if ($null -ne $bak) { [Environment]::SetEnvironmentVariable($n, $bak, "User") }
        }
        Remove-Item -LiteralPath $PrevEnvRegKey -Recurse -Force -ErrorAction SilentlyContinue
    } catch {}
}

# 把状态应用到系统（幂等：整套变量都已就位就什么都不做）
function Apply-State([string]$state) {
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
