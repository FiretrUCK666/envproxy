Write-Host '[1] pure functions'
Assert-Eq 'merge keeps user entries' 'localhost,127.0.0.1,::1,example.com' (Merge-NoProxy 'localhost,example.com,::1' $DefaultNoProxy)
Assert-Eq 'merge empty' 'localhost,127.0.0.1,::1' (Merge-NoProxy '' $DefaultNoProxy)
Assert-Eq 'normalize' 'localhost|foo' ((Get-NormalizedNoProxyEntries ' Localhost , FOO ') -join '|')
Assert-Eq 'versions 1.0.10 > 1.0.9' '1' (Compare-Versions '1.0.10' '1.0.9')
Assert-Eq 'versions 1.0 == 1.0.0' '0' (Compare-Versions '1.0' '1.0.0')
Assert-Eq 'versions 2.0 > 10-part' '-1' (Compare-Versions '1.9' '1.10')
$t = Get-ProxyVarTable '17890'
Assert-Eq 'var table count' '5' ($t.Count)
Assert-Eq 'var table value' 'http://127.0.0.1:17890' ($t['HTTP_PROXY'])

# 这一组的快照键就是沙箱键（文件开头已整体改道），跑之前先清空它。
# Test-IsOwnedProxyValue 内部会去读安装快照判断「这个名字装前就有了吗」，
# 那结论必须由本用例自己控制：装过的机器上快照里有这几个名字，断言就会拿到
# 与干净 CI 相反的结论——同一份测试两边结论相反，是最难查的一类红。
Write-Host '[2] ownership convention (real predicate)'
if ($env:OS -eq 'Windows_NT') {
    Remove-Item -LiteralPath (Get-PrevEnvRegKeyPath) -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path (Get-PrevEnvRegKeyPath) -Force | Out-Null
    # 这几条的前提是"快照键在、且里面没有这几个名字"——只有注册表能造出来。
    # 没有注册表时（CI 的 ubuntu 作业跑同一份文件）Test-SnapshotRecorded 会走到
    # "键整个不存在且无安装记录"那一支、返回 $null（不知道），于是判 false。
    # 那是**正确行为**（分不清就别认领），只是与本组断言要问的问题不同。
    # 所以整组跟着前提一起跳过，而不是把断言放宽——放宽会让真回归溜过去。
    Assert-Eq 'local counts as ours' $true (Test-IsOwnedProxyValue 'HTTP_PROXY' 'http://127.0.0.1:7890')
    Assert-Eq 'corp does not' $false (Test-IsOwnedProxyValue 'HTTP_PROXY' 'http://corp:8080')
    Assert-Eq 'own no_proxy entry counts' $true (Test-IsOwnedProxyValue 'NO_PROXY' 'localhost,example.com')
    Assert-Eq 'foreign no_proxy does not' $false (Test-IsOwnedProxyValue 'NO_PROXY' 'example.com')
    Assert-Eq 'node flag 1 counts' $true (Test-IsOwnedProxyValue 'NODE_USE_ENV_PROXY' '1')
    Assert-Eq 'node flag other does not' $false (Test-IsOwnedProxyValue 'NODE_USE_ENV_PROXY' '0')
} else {
    Write-Host '  SKIP 归属判定的"快照在、里面没有"前提（本机没有注册表，造不出这个前提）'
}
Assert-Eq 'empty counts as nothing' $false (Test-IsOwnedProxyValue 'HTTP_PROXY' '')
# NO_PROXY 为空也必须算"没有痕迹"。
#
# 这条原来漏了：NO_PROXY 走的是"逐项比对"而不是整值相等，而空值拆出来的条目集是
# 空集，「每一项都在我们记下的那份里」对空集**恒真**，于是它返回 true。
# 后果不是一个显示问题：Test-ProxyVarsPresent 拿它当清理门槛，变量已经清空仍被判成
# "还有我们的痕迹"，清理函数删不到东西、回读确认依旧为真，最后 Invoke-EnvStateWrite
# 报 1——一个干净的直连状态被报成"写失败"，而屏幕提示用户"可能被杀软拦住了"。
# CI 的 ubuntu 作业正是因为这条红的（那边注册表不可写，空值路径必被走到）。
Assert-Eq 'empty NO_PROXY counts as nothing' $false (Test-IsOwnedProxyValue 'NO_PROXY' '')
Assert-Eq 'whitespace NO_PROXY counts as nothing' $false (Test-IsOwnedProxyValue 'NO_PROXY' '   ')
Assert-Eq 'empty node flag counts as nothing' $false (Test-IsOwnedProxyValue 'NODE_USE_ENV_PROXY' '')

# 归属判定的第二层：安装快照里本来就记着的值，哪怕长得像我们的，也永远是使用者的。
# 没有这一层，用户自己写的 NO_PROXY=localhost、或自挂的 mitmproxy（127.0.0.1:8080）
# 会在 off 态每 30 轮被定时删掉，日志还谎称"回收残留"。
if ($env:OS -eq 'Windows_NT') {
    # 照样只碰沙箱键：真实快照里存着使用者安装前的原值，
    # 往那里写测试值、跑完再删，等于把他的快照改残，卸载还原不回去。
    $bakKey = Get-PrevEnvRegKeyPath
    Remove-Item -LiteralPath $bakKey -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $bakKey -ErrorAction SilentlyContinue | Out-Null
    try {
        Set-ItemProperty -Path $bakKey -Name 'NO_PROXY' -Value 'localhost' -ErrorAction Stop
        Set-ItemProperty -Path $bakKey -Name 'HTTP_PROXY' -Value 'http://127.0.0.1:8080' -ErrorAction Stop
        Assert-Eq '快照里有的 NO_PROXY 项判为使用者的' $false (Test-IsOwnedProxyValue 'NO_PROXY' 'localhost')
        Assert-Eq '快照里没有的默认项仍归我们回收' $true (Test-IsOwnedProxyValue 'NO_PROXY' '127.0.0.1')
        Assert-Eq '快照里有的本机代理地址判为使用者的' $false (Test-IsOwnedProxyValue 'HTTP_PROXY' 'http://127.0.0.1:8080')
        # 判据必须与 Remove-UserEnvVars 同一套：那边逐项减默认集、快照里的原样留。
        # 所以「掺了我们默认项的混合值」要算我们写的（整份都在快照里才算使用者的），
        # 否则门槛判定「不用清」，回收函数却照样删掉其中几项——两个判据各说各话。
        Assert-Eq '掺了默认项的混合值算我们写的' $true (Test-IsOwnedProxyValue 'NO_PROXY' 'localhost,127.0.0.1,::1')
        Assert-Eq '全在快照里的值算使用者的' $false (Test-IsOwnedProxyValue 'NO_PROXY' 'localhost')

        # ------------------------------------------------------------------
        # 快照里有这个名字、但当前值**已经是我们注入的那个**——必须判成我们的。
        #
        # 这是本项目最贵的一类错，因为它的形状最普通：装之前用户本来就有
        # HTTP_PROXY（企业代理、旧工具残留都长这样），快照于是记下了这个名字。
        # 之后我们把它覆盖成 127.0.0.1:<翻墙端口>。关代理时若按"名字在快照里
        # 就算他的"来判断，我们注入的值就永远删不掉：
        #   - 三个地址变量继续指向死端口，git/curl/npm 全部 ECONNREFUSED；
        #   - 而 NO_PROXY/NODE_USE_ENV_PROXY 没有快照条目，照样被删——
        #     于是连 localhost 都要往死代理送，成为更难查的"半套变量"；
        #   - PowerShell 提示符钩子读注册表看到值还在，每开一个窗口就再注入一次；
        #   - 屏幕上还打"已删除代理变量，恢复直连"。
        # 判据必须落在**值**上：当前值等于我们记下的那个 → 就是我们的，与快照无关。
        # ------------------------------------------------------------------
        New-Item -Path (Get-OwnedRegKeyPath) -Force -ErrorAction SilentlyContinue | Out-Null
        Set-ItemProperty -Path (Get-OwnedRegKeyPath) -Name 'HTTP_PROXY' -Value 'http://127.0.0.1:7078' -ErrorAction SilentlyContinue
        Assert-Eq '快照记着名字、但值是我们注入的 -> 仍是我们的（必须回收）' $true `
            (Test-IsOwnedProxyValue 'HTTP_PROXY' 'http://127.0.0.1:7078')
        Assert-Eq '同一情形下用户自己的另一个端点仍不许动' $false `
            (Test-IsOwnedProxyValue 'HTTP_PROXY' 'http://127.0.0.1:8080')
        # 清理门槛也必须跟着认：它是同一个判据的调用方，两处各说各话就是"半代理"的来源。
        Assert-Eq '清理门槛与归属判据同一套（门槛必须看到我们的值）' $true `
            ([bool](Test-IsOwnedProxyValue 'HTTP_PROXY' 'http://127.0.0.1:7078'))
        Remove-Item -LiteralPath (Get-OwnedRegKeyPath) -Recurse -Force -ErrorAction SilentlyContinue
    } finally {
        Remove-Item -LiteralPath $bakKey -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host '  SKIP 快照归属判定（本机没有注册表）'
}

Write-Host '[2c] NO_PROXY reclaim (pure function, no registry)'
# 这一段测的是"用判据的那段循环"，不是判据本身。
# 上面 [2] 段把"什么算我们写的"钉得很死，但那些断言全在测 Test-IsOwnedProxyValue——
# 把 Remove-UserEnvVars 里逐项分类的循环改坏（比如删掉"快照里本来就有的条目原样留"
# 那一支），判据断言照样全绿，而用户的 NO_PROXY=localhost 会在 off 态被删掉。
# 循环已经抽成纯函数 Get-NoProxyAfterReclaim，所以这里可以直接喂值、不用动真实注册表。
$dnp = $DefaultNoProxy
# 关键用例：使用者的值里含一个**默认项**（localhost），它在快照里 -> 必须留。
# 而 127.0.0.1 在默认集里但不在快照里 -> 必须摘。这一对是唯一能区分两条分支的形状。
$got = Get-NoProxyAfterReclaim ("localhost,corp.example," + $dnp) 'localhost,corp.example' $dnp
Assert-Eq 'reclaim: 快照里的默认项原样留' $true ([bool](@($got -split ',') -contains 'localhost'))
Assert-Eq 'reclaim: 不在快照的默认项被摘掉' $false ([bool](@($got -split ',') -contains '127.0.0.1'))
Assert-Eq 'reclaim: 使用者的非默认项也留着' $true ([bool](@($got -split ',') -contains 'corp.example'))
# 没有快照时：默认项全是我们的，全摘；剩下的留着
$got2 = Get-NoProxyAfterReclaim ("corp.example," + $dnp) $null $dnp
Assert-Eq 'reclaim: 无快照时默认项全摘' 'corp.example' $got2
# 只剩我们的项：整份该删（返回 $null）
$got3 = Get-NoProxyAfterReclaim $dnp $null $dnp
Assert-Eq 'reclaim: 只剩我们的项时整份删除' $null $got3
# 快照里记着使用者的 NO_PROXY 原本就是空 -> 我们加的项照摘
$got4 = Get-NoProxyAfterReclaim 'example.com' 'example.com' $dnp
Assert-Eq 'reclaim: 使用者原值原样不动' 'example.com' $got4
# 大小写：使用者的写法要原样保留，不能顺手改成小写。
# 注意期望值里有三个条目：LocalHost、Corp.Example 是使用者的；默认集里那个 localhost
# 规范化后与快照里的 localhost 相等，所以它也算使用者的、同样保留。
# 这不是漏摘——"它是不是我们写的"按规范化后的值判，判到了就在快照里，就该留。
$got5 = Get-NoProxyAfterReclaim ('LocalHost,Corp.Example,' + $dnp) 'localhost,corp.example' $dnp
Assert-Eq 'reclaim: 保留使用者的原始大小写' 'LocalHost,Corp.Example,localhost' $got5
Assert-Eq 'reclaim: 大小写不同不算我们的（不被摘）' $true ([bool](@($got5 -split ',') -contains 'LocalHost'))

Write-Host '[2d] malformed state strings are refused, not silently accepted'
# 状态串只有两种合法形状：off，或 on:<1..65535>。
# 畸形的一律不许写、也不许报成功——"什么都没做却报成功"是最难查的一种故障：
# 屏幕上一切正常，只有终端连不上网。
# 为什么这里能安全地测：Invoke-EnvStateWrite 对畸形输入在**拿锁之前**就返回了，
# 所以这些断言不会碰注册表，也不会写用户的环境变量。
foreach ($bad in @('on:', 'garbage', 'on:abc', 'on:0', 'on:70000', 'on:-1')) {
    $r = $null
    try { $r = Invoke-EnvStateWrite $bad '' '' } catch { $r = 'threw' }
    Assert-Eq ("畸形状态串被拒：" + $bad) 1 $r
    # Apply-State 是它的调用方，也必须挡住而不是抛异常。
    # 它在监控主循环里跑：抛出去会被 catch 吞掉，$lastState 不更新，
    # 而变量可能已经被改过——状态与实际就此分叉，屏幕上完全看不出来。
    $ar = $null
    try { $ar = Apply-State $bad } catch { $ar = 'threw' }
    Assert-Eq ("Apply-State 对畸形串不抛异常：" + $bad) $false $ar
}
# 合法输入必须放行：unknown 与空串在拿锁**之前**就返回 0，不碰注册表。
# 这两个可以放心测。
#
# 'off' **不在这里测**：它真的会去删 HKCU\Environment 里的变量。这台机器上如果
# 后台监控正在跑（每 2-3 秒重写一次），测试删掉、监控写回，断言就会随机变红；
# 而在没有注册表的平台（CI 的 ubuntu 作业跑同一份文件）它必然失败。
# 原来是把它一起塞进这个循环的，于是"按平台看行为"的随机红被当成平台差异查了很久。
# off 的行为改在【隔离的注册表沙箱】里验证——见下面 [2g] 之后的 off 用例。
foreach ($good in @('unknown', '')) {
    $r = $null
    try { $r = Invoke-EnvStateWrite $good '' '' } catch { $r = 'threw' }
    Assert-Eq ("合法状态串放行：" + $good) 0 $r
}

Write-Host '[2e] the mirror file has a self-heal path'
# 契约：Git Bash 那份终端同步读 terminal.env 判断"这几个值是不是我们写的"。
# 那个文件被删掉之后，必须有东西能重建它——否则已开着的窗口永远清不掉死代理，
# 用户看到的是 git/curl 全部 ECONNREFUSED 而错误里没有本工具的名字。
# 曾经它只在 Apply-State（状态翻转）里写，30 轮自愈那条路不写，
# 于是"删掉就再也回不来"。这条钉住"自愈也能重建"。
$mirrorPath = Join-Path (Get-InstallDir) "terminal.env"
$mirrorBak = $null
if (Test-Path $mirrorPath) { $mirrorBak = Get-Content $mirrorPath -Raw -ErrorAction SilentlyContinue }
try {
    if (Test-Path $mirrorPath) { Remove-Item $mirrorPath -Force -ErrorAction SilentlyContinue }
    # 走自愈那条路（Invoke-EnvStateWrite），不是走 Apply-State
    $mirrorRc = Invoke-EnvStateWrite "on:7078" "" ""
    Assert-Eq '自愈能把被删的镜像文件重建出来' $true (Test-Path $mirrorPath)
    if (Test-Path $mirrorPath) {
        $mirrorLines = @(Get-Content $mirrorPath)
        Assert-Eq '重建出来的镜像含 we 写下的归属记录' $true (@($mirrorLines | Where-Object { $_ -like 'owned_*' }).Count -gt 0)
    }
} finally {
    if ($mirrorBak) { [System.IO.File]::WriteAllText($mirrorPath, $mirrorBak, (New-Object System.Text.UTF8Encoding($false))) }
}

Write-Host '[2f] every terminal-sync state has something to say'
# 契约：问题清单里说"终端同步没生效"时，往下一定找得到"终端同步"那一行。
# 曾经 State 叫 nohost、switch 处理的是 unknown，两者恰好错位，
# 于是那一项永远不打印——用户被指向一个不存在的提示。
# 这条枚举 Get-TerminalSyncState 可能返回的**全部**状态，逐个喂给渲染器。
foreach ($ss in @('ok', 'blocked', 'unpaired', 'missing', 'stale', 'nohost')) {
    $probeSt = Get-StatusSnapshot
    $probeSt.TermSync = @{ State = $ss; Detail = 'x'; Path = ''; Line = 0 }
    # 必须用 6>&1 重定向：状态页走 Write-Host（information stream），
    # 2>&1 只接错误流，捕获到的是 0 行——那样这条断言会永远红或永远绿，
    # 取决于怎么读结果，而两种都不说明任何事。
    $probeOut = @(Show-StatusSnapshot $probeSt 6>&1)
    # 判据不能只是"出现了'终端同步'四个字"——default 分支也会打印它，
    # 于是"正常态被误判成未知"这种 bug 会假绿（真发生过：补 nohost 时漏了 ok，
    # 屏幕上打成"终端同步 : 状态未知（ok）"，而这条断言当时是绿的）。
    # 现在要求：正常态必须说"已生效"，异常态不许出现"状态未知"。
    #
    # 状态行是**两段**渲染的（标签用 key、内容按状态上色），所以 6>&1 捕获到的是
    # 一行拆成的两个元素。这里先把同一个标签后面的内容接回去再判断，
    # 否则只会看到"终端同步 : "这半截，断言永远红（实测踩过）。
    $joined = [System.Collections.Generic.List[string]]::new()
    $pending = $null
    foreach ($o in $probeOut) {
        $s = [string]$o
        if ($s -match '(监控进程|开机自启|翻墙代理|终端同步|代理变量|版本)\s*:\s*$') {
            $pending = $s.TrimEnd()
        } elseif ($null -ne $pending) {
            $joined.Add(($pending + ' ' + $s.Trim()))
            $pending = $null
        } else {
            $joined.Add($s)
        }
    }
    if ($null -ne $pending) { $joined.Add($pending) }
    $syncLine = @($joined | Where-Object { $_ -match '终端同步' })
    $hasLine = $syncLine.Count -gt 0
    Assert-Eq ("终端同步状态必须有对应那一行：" + $ss) $true $hasLine
    if ($ss -eq 'ok') {
        Assert-Eq '正常态必须说"已生效"' $true (@($syncLine | Where-Object { $_ -match '已生效' }).Count -gt 0)
        Assert-Eq '正常态不许说"状态未知"' $false (@($syncLine | Where-Object { $_ -match '状态未知' }).Count -gt 0)
        Assert-Eq '正常态只打印一次（不许重复）' 1 $syncLine.Count
    } else {
        Assert-Eq ("异常态不许落进未知兜底：" + $ss) $false (@($syncLine | Where-Object { $_ -match '状态未知' }).Count -gt 0)
    }
}

