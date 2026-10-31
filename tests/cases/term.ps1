Write-Host '[13] 终端同步：$PROFILE 钩子块（多落点）'
$profSbox = Join-Path ([System.IO.Path]::GetTempPath()) ("ep_prof_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $profSbox -Force -ErrorAction SilentlyContinue | Out-Null
$fakeProfile  = Join-Path $profSbox 'ps51_profile.ps1'
$fakeProfile7 = Join-Path $profSbox 'pwsh7_profile.ps1'
$oldOverride = $env:ENVPROXY_PROFILE_OVERRIDE
$env:ENVPROXY_PROFILE_OVERRIDE = $fakeProfile + ';' + $fakeProfile7
try {
    $r = Install-ShellProfile
    Assert-Eq '全新安装成功' $true $r.Ok
    Assert-Eq '两个落点都写了（5.1）' $true (Test-Path $fakeProfile)
    Assert-Eq '两个落点都写了（7）' $true (Test-Path $fakeProfile7)
    $txt = Get-Content $fakeProfile -Raw -Encoding UTF8
    Assert-Eq '写入开始标记' $true ($txt -match [regex]::Escape($ProfileBlockStart))
    Assert-Eq '写入结束标记' $true ($txt -match [regex]::Escape($ProfileBlockEnd))
    # 变量清单从生成的代码里抠出来数：只允许 5 个大写拼写，不许有小写（跨进程重名雷区）
    $namesLine = @($txt -split "`r?`n" | Where-Object { $_ -match 'epNames = @\(' })[0]
    $names = [regex]::Matches($namesLine, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
    Assert-Eq '变量清单恰好 5 个' 5 $names.Count
    Assert-Eq '清单里没有小写拼写' 0 (@($names | Where-Object { $_ -cmatch '^[a-z]' }).Count)
    Assert-Eq '含手动接管开关说明' $true ($txt -match 'ENVPROXY_TERM')
    Assert-Eq '用了 NullString 真删' $true ($txt -match 'NullString')

    Assert-Eq '幂等：再装一次返回 current' 'current' (Install-ShellProfile).Reason
    Assert-Eq '幂等：标记只出现一次' 1 (([regex]::Matches((Get-Content $fakeProfile -Raw -Encoding UTF8), [regex]::Escape($ProfileBlockStart))).Count)

    # 用户原有内容必须保留，且我们的块在末尾（$PROFILE 最后执行才能包住前面的 prompt）
    Set-Content -Path $fakeProfile -Value @('$env:MY_SETTING = "keep-me"', 'function prompt { "custom> " }') -Encoding UTF8
    Assert-Eq '在用户内容之上安装成功' $true (Install-ShellProfile).Ok
    $txt3 = Get-Content $fakeProfile -Raw -Encoding UTF8
    Assert-Eq '用户的设置还在' $true ($txt3 -match 'keep-me')
    Assert-Eq '用户的 prompt 还在' $true ($txt3 -match 'custom>')
    Assert-Eq '块在文件末尾' $ProfileBlockEnd (@($txt3.TrimEnd() -split "`r?`n")[-1])

    # 卸载：只摘我们的块
    Assert-Eq '卸载成功' $true (Remove-ShellProfile).Ok
    $txt4 = Get-Content $fakeProfile -Raw -Encoding UTF8
    Assert-Eq '标记已消失' $false ($txt4 -match 'EnvProxy')
    Assert-Eq '卸载后用户内容完好' $true ($txt4 -match 'keep-me')

    # 标记不配对的护栏：一个字节都不改
    Set-Content -Path $fakeProfile -Value @($ProfileBlockStart, 'dangling') -Encoding UTF8
    $before = [System.IO.File]::ReadAllText($fakeProfile)
    $r5 = Install-ShellProfile
    Assert-Eq '不配对时拒绝安装' $false $r5.Ok
    Assert-Eq '不配对时原因正确' 'unpaired' $r5.Reason
    Assert-Eq '不配对时文件未被改动' $before ([System.IO.File]::ReadAllText($fakeProfile))
    Assert-Eq '不配对时拒绝卸载' $false (Remove-ShellProfile).Ok
    Assert-Eq '不配对时文件仍未被改动' $before ([System.IO.File]::ReadAllText($fakeProfile))

    # 没有我们标记的文件：卸载碰都不碰（连 mtime 都不改）
    Set-Content -Path $fakeProfile -Value @('$env:X = 1') -Encoding UTF8
    $mt1 = (Get-Item $fakeProfile).LastWriteTime.Ticks
    Start-Sleep -Milliseconds 30
    Assert-Eq '无标记时卸载返回 no-block' 'no-block' (Remove-ShellProfile).Reason
    Assert-Eq '无标记时 mtime 未变' $mt1 (Get-Item $fakeProfile).LastWriteTime.Ticks

    # 升级：旧块内容不同必须重写（否则改了钩子却送不到用户手里）
    Set-Content -Path $fakeProfile -Value @('$env:Y=2', $ProfileBlockStart, 'OLD-HOOK', $ProfileBlockEnd) -Encoding UTF8
    Assert-Eq '旧块被识别为过期并重写' 'installed' (Install-ShellProfile).Reason
    $txt7 = Get-Content $fakeProfile -Raw -Encoding UTF8
    Assert-Eq '旧的钩子内容已消失' $false ($txt7 -match 'OLD-HOOK')
    Assert-Eq '升级时用户内容保留' $true ($txt7 -match 'Y=2')

    # 用户配置文件的编码必须原样保住，而且要逐字节还原。
    # 这是最容易被写坏的东西：GBK 被当 UTF-8 读会变乱码、BOM 每轮叠加一层。
    # 行尾也要保住：WriteAllLines 固定用 Environment.NewLine（CRLF），会把 LF 的
    # profile 静默改成 CRLF——夹具只写 CRLF 时这条永远测不出来，所以这里带上 LF。
    #
    # GBK 用例写死代码页 936，不用 CurrentCulture 的 ANSICodePage：
    # 那个值跟着运行环境走（CI 的 ubuntu 上是 1252，编不了中文，中文会变成 "?"），
    # 于是这条用例在非中文环境下测的其实是"1252 能不能往返"——看起来红，但和 GBK 无关。
    $gbk = $null
    try { $gbk = [System.Text.Encoding]::GetEncoding(936) } catch { }
    $encCases = @()
    if ($gbk) {
        $encCases += @{ Name = 'GBK'; Enc = $gbk; Nl = "`r`n" }
    } else {
        Write-Host '  SKIP GBK 用例：这个平台没有代码页 936（非中文环境），无从构造 GBK 文件'
    }
    $encCases += @{ Name = 'UTF8-BOM';  Enc = (New-Object System.Text.UTF8Encoding($true));            Nl = "`r`n" }
    $encCases += @{ Name = 'UTF8';      Enc = (New-Object System.Text.UTF8Encoding($false));           Nl = "`r`n" }
    $encCases += @{ Name = 'UTF8-LF';   Enc = (New-Object System.Text.UTF8Encoding($false));           Nl = "`n" }
    $encCases += @{ Name = 'UTF8BOM-LF';Enc = (New-Object System.Text.UTF8Encoding($true));            Nl = "`n" }
    $encCases += @{ Name = 'UTF16-LE';  Enc = (New-Object System.Text.UnicodeEncoding($false, $true)); Nl = "`r`n" }
    $userLine = '# 我的 PowerShell 配置'
    foreach ($c in $encCases) {
        $fp = Join-Path $profSbox ("enc_" + $c.Name + ".ps1")
        # UnicodeEncoding 的 GetBytes 不含前导 BOM，要自己补，否则读回来对不上。
        $body = $c.Enc.GetBytes($userLine + $c.Nl)
        if ($c.Name -eq 'UTF8-BOM' -or $c.Name -eq 'UTF8BOM-LF') { $body = [System.Text.Encoding]::UTF8.GetPreamble() + $body }
        if ($c.Name -eq 'UTF16-LE') { $body = $c.Enc.GetPreamble() + $body }
        [System.IO.File]::WriteAllBytes($fp, $body)
        $orig = [System.IO.File]::ReadAllBytes($fp)
        $env:ENVPROXY_PROFILE_OVERRIDE = $fp
        $rI = Install-ShellProfile
        $txtAfter = $c.Enc.GetString([System.IO.File]::ReadAllBytes($fp))
        Assert-Eq ("{0} 安装成功" -f $c.Name) $true $rI.Ok
        Assert-Eq ("{0} 用户原有中文保住" -f $c.Name) $true ($txtAfter -match '我的 PowerShell 配置')
        # 块里那几行刻意是纯 ASCII：我们不知道目标文件是什么编码，
        # 中文注释放进无 BOM 文件会被 5.1 当 ANSI 读成乱码。
        Assert-Eq ("{0} 钩子块写入" -f $c.Name) $true ($txtAfter -match 'EnvProxy: keeps already-open windows')
        # 行尾风格在安装后必须没变：LF 夹具里不该出现 CR。
        if ($c.Nl -eq "`n") {
            $afterBytes = [System.IO.File]::ReadAllBytes($fp)
            $cr = @($afterBytes | Where-Object { $_ -eq 13 }).Count
            Assert-Eq ("{0} 安装后行尾未被改成 CRLF" -f $c.Name) 0 $cr
        }
        $null = Remove-ShellProfile
        $fin = [System.IO.File]::ReadAllBytes($fp)
        Assert-Eq ("{0} 卸载后逐字节还原（BOM 不叠加）" -f $c.Name) $true (($fin -join ',') -eq ($orig -join ','))
    }
} finally {
    if ($null -eq $oldOverride) { Remove-Item Env:ENVPROXY_PROFILE_OVERRIDE -ErrorAction SilentlyContinue }
    else { $env:ENVPROXY_PROFILE_OVERRIDE = $oldOverride }
    Remove-Item -Recurse -Force $profSbox -ErrorAction SilentlyContinue
}

# 终端同步的**行为**验证：钩子块生成出来以后，改注册表能不能让当前会话跟着变。
# 这一步是"敲回车就跟上"的核心机制，只检查文本里有没有 prompt 是不够的。
# 它读写的全是 Windows 注册表，Linux 上没有这一层（CI 的 ubuntu 上要跳过，
# 不是"失败"——Mac 侧对应行为由 mac/envproxy.sh self-test 自己覆盖）。
Write-Host '[14] 终端同步：钩子的真实行为'
if ($env:OS -ne 'Windows_NT') {
    Write-Host '  SKIP 这一步验证的是 Windows 注册表侧的钩子行为，非 Windows 平台跳过'
} else {
# 先拿"写用户变量"那把互斥体再动手。
#
# 为什么必须拿：这一段验的是**真实注册表**（沙箱键覆盖不了 Git Bash 钩子的行为），
# 而在已安装的机器上，监控每 2–3 秒会做一次变量自愈——它写的是同一批真实变量。
# 两边同时动手就是竞态：实测连跑四次得到 3 / 1 / 4 / 0 个失败，失败项每次都不一样，
# 而且全都是"我们的值不见了"这类症状。一个会随机变红的测试等于没有测试——
# 它一会让人去查不存在的 bug，一会又放过了真问题。
# 拿锁之后监控会在 WaitOne 那里等，本段跑完释放，两边不再交叉。
$hookGate = $null
$hookHeld = $false
try {
    $hookGate = New-Object System.Threading.Mutex($false, (Get-MutexName "EnvProxyApplyState"))
    $hookHeld = $hookGate.WaitOne(30000)
} catch [System.Threading.AbandonedMutexException] {
    # 上一个持有者没释放就死了，但锁已经交给本线程（与 env.ps1 同一条判断）。
    $hookHeld = $true
} catch {}
if (-not $hookHeld) {
    # 拿不到锁 = 监控正在写同一批真实变量，这一段的前提不成立。
    # 明确跳过而不是给出可能失真的结论（FAIL 和 PASS 在这里都是假话）。
    Write-Host '  SKIP 等不到变量锁（监控正在写），这一段整体跳过——避免给出失真的结论'
    $script:AssertionMuted = $true
}
$hookSBox = Join-Path ([System.IO.Path]::GetTempPath()) ("ep_hook_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $hookSBox -Force -ErrorAction SilentlyContinue | Out-Null
$hookFile = Join-Path $hookSBox 'hook.ps1'
[System.IO.File]::WriteAllLines($hookFile, (Get-ProfileBlockLines), (New-Object System.Text.UTF8Encoding($false)))
$savedEnv = @{}
foreach ($n in $ProxyVarNames) { $savedEnv[$n] = [Environment]::GetEnvironmentVariable($n, 'User') }
# 归属记录要整份存下来再还原，只记「存不存在」不够：
# 它是「哪些值是我们写的」的唯一凭据，而真实安装过的机器上它是有内容的。
# 测试中途会把它删掉（模拟「没有归属记录」那一档），跑完必须原样放回——
# 否则跑一次自检就把用户机器的归属记录清空，Git Bash 的钩子从此再也清不掉变量
#（契约：没有归属记录时一个都不动），而且不报任何错。
$savedOwnedExist = Test-Path (Get-OwnedRegKeyPath)
$savedOwnedValues = @{}
if ($savedOwnedExist) {
    $__so = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($OwnedRegSubKey, $false)
    if ($null -ne $__so) {
        foreach ($__sn in $__so.GetValueNames()) { $savedOwnedValues[$__sn] = [string]$__so.GetValue($__sn) }
        $__so.Close()
    }
}
# 直接写注册表，不走 [Environment]::SetEnvironmentVariable：后者每写一次都会等
# WM_SETTINGCHANGE 广播超时（实测 5 个变量约 26 秒），自检会卡到超时。
# 钩子读的就是注册表这一层，直接写它等价，而且更快。
function Set-RegValue([string]$Name, $Value) {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($UserEnvSubKey, $true)
    if ($null -eq $k) { return }
    if ($null -eq $Value) { try { $k.DeleteValue($Name, $false) } catch {} }
    else { $k.SetValue($Name, [string]$Value, [Microsoft.Win32.RegistryValueKind]::String) }
    $k.Close()
}
try {
    foreach ($n in $ProxyVarNames) { Set-RegValue $n $null }
    if (Test-Path (Get-OwnedRegKeyPath)) { Remove-Item (Get-OwnedRegKeyPath) -Recurse -Force }
    foreach ($n in $ProxyVarNames) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
    Remove-Item Env:__EnvProxyPromptWrapped -ErrorAction SilentlyContinue
    Remove-Item Env:ENVPROXY_TERM -ErrorAction SilentlyContinue

    # 代理开着：注册表有值 + 归属记录 -> 钩子注入
    # 归属记录用真实写入路径产生（它就是 monitor 写的那一份）。
    foreach ($n in $ProxyVarNames) { Set-RegValue $n $null }
    Set-RegValue 'HTTP_PROXY'  'http://127.0.0.1:7078'
    Set-RegValue 'HTTPS_PROXY' 'http://127.0.0.1:7078'
    Set-RegValue 'ALL_PROXY'   'http://127.0.0.1:7078'
    Set-RegValue 'NO_PROXY'    'localhost,127.0.0.1,::1'
    Set-RegValue 'NODE_USE_ENV_PROXY' '1'
    if (-not (Test-RegKey (Get-OwnedRegKeyPath))) { New-Item -Path (Get-OwnedRegKeyPath) -Force | Out-Null }
    $ok = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($OwnedRegSubKey, $true)
    if ($ok) {
        $ok.SetValue('HTTP_PROXY',  'http://127.0.0.1:7078', [Microsoft.Win32.RegistryValueKind]::String)
        $ok.SetValue('HTTPS_PROXY', 'http://127.0.0.1:7078', [Microsoft.Win32.RegistryValueKind]::String)
        $ok.SetValue('ALL_PROXY',   'http://127.0.0.1:7078', [Microsoft.Win32.RegistryValueKind]::String)
        $ok.SetValue('NO_PROXY',    'localhost,127.0.0.1,::1', [Microsoft.Win32.RegistryValueKind]::String)
        $ok.SetValue('NODE_USE_ENV_PROXY', '1', [Microsoft.Win32.RegistryValueKind]::String)
        $ok.Close()
    }
    . $hookFile
    Assert-EqGated '加载钩子后立刻注入' 'http://127.0.0.1:7078' $env:HTTPS_PROXY
    # 注意：不能用 "$null -ne $function:prompt" 判"包住了"——PowerShell 自带默认 prompt，
    # 那个表达式永远为真，把包装函数整行删掉也照样 PASS（实测如此）。
    # 真判据是我们自己的哨兵变量 + 真的调一次 prompt 看效果。
    Assert-EqGated '包装标记已置位（这是回车生效的机制）' $true $global:__EnvProxyPromptWrapped
    Assert-EqGated '原 prompt 已备份（用于链式调用）' $true ($null -ne $global:__EnvProxyPrevPrompt)

    # 真实路径：敲回车 = 宿主调用 prompt。这里手动调一次，走的是包装后的函数。
    foreach ($n in $ProxyVarNames) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
    $null = prompt
    Assert-EqGated '敲回车（调 prompt）后拿到代理' 'http://127.0.0.1:7078' $env:HTTPS_PROXY

    # 代理关掉：monitor 清掉注册表里的值 -> 钩子把会话里"我们写过的"也清掉
    foreach ($n in $ProxyVarNames) { Set-RegValue $n $null }
    $null = prompt
    Assert-EqGated '代理关掉后回到提示符恢复直连' '' "$env:HTTPS_PROXY"

    # 用户自己设的值必须保留（README 的承诺，也是契约里最容易被破坏的一条）
    $env:HTTPS_PROXY = 'http://corp-proxy:8080'
    $null = prompt
    Assert-EqGated '用户自己的公司代理不被删' 'http://corp-proxy:8080' $env:HTTPS_PROXY

    $env:HTTPS_PROXY = 'http://127.0.0.1:8080'
    $null = prompt
    Assert-EqGated '用户自己的本机地址不被删' 'http://127.0.0.1:8080' $env:HTTPS_PROXY

    # 逐窗口接管
    foreach ($n in $ProxyVarNames) { Set-RegValue $n $null }
    Set-RegValue 'HTTPS_PROXY' 'http://127.0.0.1:7078'
    Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue
    $null = prompt
    Assert-EqGated '重新注入' 'http://127.0.0.1:7078' $env:HTTPS_PROXY
    $env:ENVPROXY_TERM = 'off'
    $null = prompt
    Assert-EqGated '接管开关生效（固定直连）' '' "$env:HTTPS_PROXY"
    Remove-Item Env:ENVPROXY_TERM -ErrorAction SilentlyContinue
    $null = prompt
    Assert-EqGated '放开接管开关后恢复自动' 'http://127.0.0.1:7078' $env:HTTPS_PROXY

    # 归属边界：这几条决定"会不会误删使用者自己的代理"，是最难事后补救的一类。
    # 钩子的判据只有两条：注册表有值就注入；没有值但当前值等于归属记录里记的那个就清除。
    # 所以每条用例都必须先把归属记录摆成真实状态，再只改被测的那一个维度——
    # 否则所有用例都会落进同一个"没有归属记录→什么都不做"的分支，断言再多条也是假的。
    $savedBakExist = Test-Path (Get-PrevEnvRegKeyPath)
    Write-Host '[14b] 归属边界：什么时候可以清'

    # 造一份真实的归属记录，模拟"我们确实写过这些值"。
    function Set-OwnedRecord([string]$Value) {
        if (-not (Test-Path (Get-OwnedRegKeyPath))) { New-Item -Path (Get-OwnedRegKeyPath) -Force -ErrorAction SilentlyContinue | Out-Null }
        $ok = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($OwnedRegSubKey, $true)
        if ($null -eq $ok) { return }
        foreach ($n in $ProxyVarNames) {
            if ($n -eq 'NODE_USE_ENV_PROXY') { $ok.SetValue($n, '1', [Microsoft.Win32.RegistryValueKind]::String) }
            else { $ok.SetValue($n, $Value, [Microsoft.Win32.RegistryValueKind]::String) }
        }
        $ok.Close()
    }

    # (a) 有归属记录、当前值等于记录值 → 清除（这是主功能：翻墙关了要还原）
    foreach ($n in $ProxyVarNames) { Set-RegValue $n $null }
    Set-OwnedRecord 'http://127.0.0.1:7078'
    $env:HTTPS_PROXY = 'http://127.0.0.1:7078'
    $null = prompt
    Assert-EqGated '值等于记录值：清除' '' "$env:HTTPS_PROXY"

    # (b) 有归属记录、但使用者改成了别的值 → 必须保住（不能按形状猜）
    $env:HTTPS_PROXY = 'http://corp-proxy:8080'
    $null = prompt
    Assert-EqGated '值不等于记录值：保住公司代理' 'http://corp-proxy:8080' $env:HTTPS_PROXY

    # (c) 有归属记录、使用者改成另一个本机端口 → 同样必须保住
    $env:HTTPS_PROXY = 'http://127.0.0.1:9090'
    $null = prompt
    Assert-EqGated '值不等于记录值：保住别的端口的本机代理' 'http://127.0.0.1:9090' $env:HTTPS_PROXY

    # (d) 没有归属记录 → 判不了，一个都不动
    if (Test-Path (Get-OwnedRegKeyPath)) { Remove-Item (Get-OwnedRegKeyPath) -Recurse -Force }
    $env:HTTPS_PROXY = 'http://127.0.0.1:7078'
    $null = prompt
    Assert-EqGated '无归属记录时不动任何值（判不了就不猜）' 'http://127.0.0.1:7078' $env:HTTPS_PROXY

    # (e) 快照保护住在 env.ps1 的注册表清理路径里，不在钩子里——直接断言那个判据，
    #     不能拿钩子的行为冒充它（钩子根本不读快照）。
    Assert-EqGated 'Test-IsOwnedProxyValue 是真实存在的判据' 'Function' (Get-Command Test-IsOwnedProxyValue -ErrorAction SilentlyContinue).CommandType

} finally {
    foreach ($n in $ProxyVarNames) { Set-RegValue $n $savedEnv[$n] }
    # 快照键：测试往 Backup 里种过值。原本就有的只删我们种的那一项；
    # 原本没有的整棵删掉——否则会在使用者机器上留一个空键。
    if (Test-Path (Get-PrevEnvRegKeyPath)) {
        $bk2 = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($PrevEnvSubKey, $true)
        $emptyNow = $false
        if ($null -ne $bk2) {
            try { $bk2.DeleteValue('HTTPS_PROXY', $false) } catch {}
            $emptyNow = (@($bk2.GetValueNames()).Count -eq 0)
            $bk2.Close()
        }
        if ($emptyNow -and (-not $savedBakExist)) { Remove-Item (Get-PrevEnvRegKeyPath) -Recurse -Force -ErrorAction SilentlyContinue }
    }
    # 归属记录：整份放回原样。
    # 测试中途会删掉它（模拟「没有归属记录」那一档），跑完必须还原——
    # 它是「哪些值是我们写的」的唯一凭据：清空了，Git Bash 的钩子就再也清不掉变量
    #（契约：没有归属记录时一个都不动），而且不报任何错。
    if ($savedOwnedExist) {
        if (-not (Test-Path (Get-OwnedRegKeyPath))) { New-Item -Path (Get-OwnedRegKeyPath) -Force -ErrorAction SilentlyContinue | Out-Null }
        $__ro = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($OwnedRegSubKey, $true)
        if ($null -ne $__ro) {
            foreach ($__rn in $savedOwnedValues.Keys) {
                $__ro.SetValue($__rn, $savedOwnedValues[$__rn], [Microsoft.Win32.RegistryValueKind]::String)
            }
            $__ro.Close()
        }
    } else {
        if (Test-Path (Get-OwnedRegKeyPath)) { Remove-Item (Get-OwnedRegKeyPath) -Recurse -Force -ErrorAction SilentlyContinue }
        # 只有它空了才删父键（父键可能装着真实的 ScriptPath）。
        if ((Test-Path (Get-ScriptPathRegKeyPath)) -and -not (@(Get-ChildItem (Get-ScriptPathRegKeyPath) -ErrorAction SilentlyContinue).Count)) {
            Remove-Item (Get-ScriptPathRegKeyPath) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($n in $ProxyVarNames) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
    Remove-Item Env:ENVPROXY_TERM -ErrorAction SilentlyContinue
    Remove-Item Env:__EnvProxyPromptWrapped -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $hookSBox -ErrorAction SilentlyContinue
    # 还原做完之后才放锁：早放会让监控在"变量已改回、归属记录还没放回"的空窗里插进来，
    # 读到一份不完整的记录，又变成另一种竞态。
    if ($hookHeld -and $null -ne $hookGate) {
        try { $hookGate.ReleaseMutex() } catch {}
    }
    if ($null -ne $hookGate) { try { $hookGate.Dispose() } catch {} }
}
}


# ------------------------------------------------------------------------------
# [20] 文档里印出来的每条命令都真能跑
# 这一节的理由：帮助和 README 里的命令是给用户「照抄」的。抄下来跑不通，
# 比不写更糟——用户会以为是自己敲错了。所以这里把每种终端的写法都真跑一遍，
# 断言的是「可观察的结果」，不是「字符串里有没有这个词」。
# 只验证不依赖网络、不改用户设置的那些：改完立刻复原。
# ------------------------------------------------------------------------------
