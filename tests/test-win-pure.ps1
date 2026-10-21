# EnvProxy Windows pure-function regression tests (no side effects, registry untouched).
# Run: pwsh tests/test-win-pure.ps1   (PowerShell 5.1 compatible, UTF-8 with BOM)
#
# The core is loaded through its real entry point: that exercises the library loader and its
# completeness check, and the entry returns immediately when dot-sourced.
$ErrorActionPreference = 'Stop'
$script:fails = 0
. (Join-Path $PSScriptRoot '../win/envproxy.ps1')

function Assert-Eq([string]$Name, $Want, $Have) {
    if ("$Want" -eq "$Have") { Write-Host ("  PASS {0}" -f $Name) }
    else { Write-Host ("  FAIL {0} (want [{1}] have [{2}])" -f $Name, $Want, $Have); $script:fails++ }
}

function Assert-Throws([string]$Name, [scriptblock]$Block) {
    $threw = $false
    try { & $Block | Out-Null } catch { $threw = $true }
    Assert-Eq $Name $true $threw
}

function Write-TestFile([string]$P, [string]$T) {
    $dir = Split-Path -Parent $P
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    [System.IO.File]::WriteAllText($P, $T)
}

function New-TempDir([string]$Prefix) {
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + [Guid]::NewGuid().ToString('N'))
    New-Item -Path $d -ItemType Directory -Force | Out-Null
    return $d
}

# A local HTTP server, used to exercise the real network paths (a redirect, a rate limit)
# without touching the network. It serves until the test stops it.
# Two things it must get right, or the gate turns red at random:
#   - the port has to be one nothing else is listening on (a taken port means the client
#     gets "connection refused", which the code reports as a network failure);
#   - the caller must not talk to it before it is really listening (a fixed sleep is
#     not enough on a busy machine).
# The server keeps serving instead of answering exactly one request: a client that opens
# a second connection (retry, pre-connect) would otherwise wait for an answer nobody sends.
function Start-OneShotServer([int]$Status, [hashtable]$Headers, [string]$Body) {
    $port = 0
    for ($try = 0; $try -lt 30; $try++) {
        $candidate = 18000 + (Get-Random -Maximum 2000)
        $probe = $null
        try {
            $probe = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $candidate)
            $probe.Start()
            $port = $candidate
        } catch { $port = 0 } finally { if ($probe) { try { $probe.Stop() } catch {} } }
        if ($port -ne 0) { break }
    }
    if ($port -eq 0) { throw 'no free port for the mock server' }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
        # Arguments come in through $args: a scriptblock handed to AddScript does not bind its
        # own param block reliably across PowerShell versions.
        $p = $args[0]; $status = $args[1]; $hdrs = $args[2]; $body = $args[3]
        $tcp = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $p)
        $tcp.Start()
        try {
            # AcceptTcpClientAsync, not Socket.Poll -- on Windows a listening socket does not
            # report a pending connection through Poll, so Poll would only time out.
            while ($true) {
                $accept = $tcp.AcceptTcpClientAsync()
                if (-not $accept.Wait(1000)) { continue }
                $client = $accept.Result
                try {
                    $stream = $client.GetStream()
                    $buf = New-Object byte[] 2048
                    $null = $stream.Read($buf, 0, $buf.Length)
                    $raw = "HTTP/1.1 $status X`r`n"
                    foreach ($k in $hdrs.Keys) { $raw += "$k`: $($hdrs[$k])`r`n" }
                    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                    $raw += "Content-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
                    $head = [System.Text.Encoding]::UTF8.GetBytes($raw)
                    $stream.Write($head, 0, $head.Length)
                    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
                    $stream.Flush()
                } catch {}
                try { $client.Close() } catch {}
            }
        } catch {}
        $tcp.Stop()
    }).AddArgument($port).AddArgument($Status).AddArgument($Headers).AddArgument($Body)
    $null = $ps.BeginInvoke()
    # Wait until it really accepts connections before handing the port to the caller.
    $deadline = (Get-Date).AddSeconds(10)
    $up = $false
    while ((Get-Date) -lt $deadline) {
        try {
            $probe = New-Object System.Net.Sockets.TcpClient
            $probe.Connect('127.0.0.1', $port)
            $probe.Close()
            $up = $true
            break
        } catch { Start-Sleep -Milliseconds 50 }
    }
    if (-not $up) {
        try { $ps.Stop() } catch {}
        try { $rs.Dispose() } catch {}
        throw 'the mock server did not start listening'
    }
    return @{ Port = $port; Runspace = $rs; Shell = $ps }
}

function Stop-OneShotServer($Server) {
    try { $Server.Shell.Stop() } catch {}
    try { $Server.Runspace.Dispose() } catch {}
}

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

Write-Host '[2] ownership convention (real predicate)'
Assert-Eq 'local counts as ours' $true (Test-IsOwnedProxyValue 'HTTP_PROXY' 'http://127.0.0.1:7890')
Assert-Eq 'corp does not' $false (Test-IsOwnedProxyValue 'HTTP_PROXY' 'http://corp:8080')
Assert-Eq 'own no_proxy entry counts' $true (Test-IsOwnedProxyValue 'NO_PROXY' 'localhost,example.com')
Assert-Eq 'foreign no_proxy does not' $false (Test-IsOwnedProxyValue 'NO_PROXY' 'example.com')
Assert-Eq 'node flag 1 counts' $true (Test-IsOwnedProxyValue 'NODE_USE_ENV_PROXY' '1')
Assert-Eq 'node flag other does not' $false (Test-IsOwnedProxyValue 'NODE_USE_ENV_PROXY' '0')
Assert-Eq 'empty counts as nothing' $false (Test-IsOwnedProxyValue 'HTTP_PROXY' '')

# 归属判定的第二层：安装快照里本来就记着的值，哪怕长得像我们的，也永远是使用者的。
# 没有这一层，用户自己写的 NO_PROXY=localhost、或自挂的 mitmproxy（127.0.0.1:8080）
# 会在 off 态每 30 轮被定时删掉，日志还谎称"回收残留"。
if ($env:OS -eq 'Windows_NT') {
    $bakKey = 'HKCU:\Software\EnvProxy\Backup'
    $madeParent = $false
    if (-not (Test-RegKey 'HKCU:\Software\EnvProxy')) { New-Item -Path 'HKCU:\Software\EnvProxy' -ErrorAction SilentlyContinue | Out-Null; $madeParent = $true }
    $madeBak = $false
    if (-not (Test-RegKey $bakKey)) { New-Item -Path $bakKey -ErrorAction SilentlyContinue | Out-Null; $madeBak = $true }
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
    } finally {
        foreach ($nm in @('NO_PROXY', 'HTTP_PROXY')) { Remove-ItemProperty -Path $bakKey -Name $nm -ErrorAction SilentlyContinue }
        if ($madeBak) { Remove-Item -Path $bakKey -Recurse -Force -ErrorAction SilentlyContinue }
        if ($madeParent) { Remove-Item -Path 'HKCU:\Software\EnvProxy' -Recurse -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-Host '  SKIP 快照归属判定（本机没有注册表）'
}

Write-Host '[3] closed ports'
Assert-Eq 'single closed is not proxy' $false (Test-HttpProxy 9)
Assert-Eq 'batch closed finds nothing' '' (Test-HttpProxyBatch @(9, 1))

Write-Host '[4] source copy detection and cleanup'
$fake = New-TempDir 'envproxy_srctest_'
New-Item -Path (Join-Path $fake '.github') -ItemType Directory -Force | Out-Null
Write-TestFile (Join-Path $fake 'AGENTS.md') 'dev'
Write-TestFile (Join-Path $fake 'my-notes.txt') 'mine'
Write-TestFile (Join-Path $fake '.gitattributes') "/AGENTS.md  export-ignore`n/.github/  export-ignore"
Assert-Eq 'github-without-git is source copy' $true (Test-SourceCopy -Root $fake)
New-Item -Path (Join-Path $fake '.git') -ItemType Directory -Force | Out-Null
Assert-Eq 'git present is not source copy' $false (Test-SourceCopy -Root $fake)
Remove-Item -LiteralPath (Join-Path $fake '.git') -Recurse -Force
Remove-SourceOnlyFiles $fake
Assert-Eq 'cleanup removes dev files' $false (Test-Path -LiteralPath (Join-Path $fake 'AGENTS.md'))
Assert-Eq 'cleanup removes github dir' $false (Test-Path -LiteralPath (Join-Path $fake '.github'))
Assert-Eq 'cleanup keeps user files' $true (Test-Path -LiteralPath (Join-Path $fake 'my-notes.txt'))
Assert-Eq 'converted folder is install copy' $false (Test-SourceCopy -Root $fake)
Remove-Item -LiteralPath $fake -Recurse -Force
$bare = New-TempDir 'envproxy_bare_'
Write-TestFile (Join-Path $bare 'my-notes.txt') 'mine'
Assert-Eq 'neither marker means install copy' $false (Test-SourceCopy -Root $bare)
Remove-Item -LiteralPath $bare -Recurse -Force

Write-Host '[5] atomic file copy (every package file goes through this)'
$dir5 = New-TempDir 'envproxy_atomic_'
$src5 = Join-Path $dir5 'from.ps1'
$dst5 = Join-Path $dir5 'to.ps1'
[System.IO.File]::WriteAllText($src5, "Write-Host 'one'`n", (New-Object System.Text.UTF8Encoding($true)))
Copy-FileAtomic $src5 $dst5
Assert-Eq 'copy creates the destination' $true (Test-Path -LiteralPath $dst5)
Assert-Eq 'copy is byte exact' ((Get-Sha256Hex $src5)) ((Get-Sha256Hex $dst5))
Assert-Eq 'copy keeps the BOM' 'EF-BB-BF' (([BitConverter]::ToString([System.IO.File]::ReadAllBytes($dst5)[0..2])))
[System.IO.File]::WriteAllText($src5, "Write-Host 'two'`n", (New-Object System.Text.UTF8Encoding($false)))
Copy-FileAtomic $src5 $dst5
Assert-Eq 'overwrite replaces content exactly' ((Get-Sha256Hex $src5)) ((Get-Sha256Hex $dst5))
Assert-Eq 'overwrite drops the old BOM' '57-72-69' (([BitConverter]::ToString([System.IO.File]::ReadAllBytes($dst5)[0..2])))
Assert-Eq 'no temp file left behind' '0' (@(Get-ChildItem -LiteralPath $dir5 -Filter '*.envproxy-new*' -File).Count)
$deep = Join-Path $dir5 'win\lib\base.ps1'
Copy-FileAtomic $src5 $deep
Assert-Eq 'missing parent directories are created' $true (Test-Path -LiteralPath $deep)
Remove-Item -LiteralPath $dir5 -Recurse -Force

Write-Host '[6] package structure verification'
$pkg = New-TempDir 'envproxy_pkg_'
$bomEnc = New-Object System.Text.UTF8Encoding($true)
$plainEnc = New-Object System.Text.UTF8Encoding($false)
Write-TestFile (Join-Path $pkg 'VERSION') '9.9.9'
New-Item -Path (Join-Path $pkg 'win\lib'), (Join-Path $pkg 'mac') -ItemType Directory -Force | Out-Null
# The package must be complete under the content-set rule: the entry declares its libraries,
# and the platform folder may hold nothing beyond entry + menu + those libraries.
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\envproxy.ps1'), "# entry`n`$CoreLibs = @(`"base`", `"probe`")`n", $bomEnc)
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\打开菜单.cmd'), "@echo off`n", $plainEnc)
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\base.ps1'), '# lib', $bomEnc)
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\probe.ps1'), '# lib', $bomEnc)
[System.IO.File]::WriteAllText((Join-Path $pkg 'mac\envproxy.sh'), "#!/bin/bash`n", $plainEnc)
$threw = $false
try { Test-Package $pkg '9.9.9' 'win' } catch { $threw = $true }
Assert-Eq 'a well-formed package is accepted' $false $threw
Assert-Throws 'version mismatch is rejected' { Test-Package $pkg '1.2.3' 'win' }
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\base.ps1'), '# lib', $plainEnc)
Assert-Throws 'a library without BOM is rejected' { Test-Package $pkg '9.9.9' 'win' }
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\base.ps1'), '# lib', $bomEnc)
[System.IO.File]::WriteAllText((Join-Path $pkg 'mac\envproxy.sh'), "#!`r`n", $plainEnc)
Assert-Throws 'a CRLF shell script is rejected' { Test-Package $pkg '9.9.9' 'win' }
[System.IO.File]::WriteAllText((Join-Path $pkg 'mac\envproxy.sh'), "#!/bin/bash`n", $plainEnc)
Remove-Item -LiteralPath (Join-Path $pkg 'mac\envproxy.sh') -Force
Assert-Eq 'a win split without the mac entry is accepted' $false $(try { Test-Package $pkg '9.9.9' 'win'; $false } catch { $true })
[System.IO.File]::WriteAllText((Join-Path $pkg 'mac\envproxy.sh'), "#!/bin/bash`n", $plainEnc)
Remove-Item -LiteralPath (Join-Path $pkg 'win\envproxy.ps1') -Force
Assert-Throws 'a missing own-platform entry is rejected' { Test-Package $pkg '9.9.9' 'win' }
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\envproxy.ps1'), "# entry`n`$CoreLibs = @(`"base`", `"probe`")`n", $bomEnc)
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\probe.ps1'), ([char]0xFEFF).ToString(), $plainEnc)
Assert-Throws 'a BOM-only truncated file is rejected' { Test-Package $pkg '9.9.9' 'win' }
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\probe.ps1'), '', $plainEnc)
Assert-Throws 'a zero-byte script is rejected' { Test-Package $pkg '9.9.9' 'win' }
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\probe.ps1'), '# lib', $bomEnc)
# A package missing one declared library, or carrying a file nobody declared, must be refused:
# otherwise the overwrite step deletes the missing library as "stale" and still reports success.
Remove-Item -LiteralPath (Join-Path $pkg 'win\lib\probe.ps1') -Force
Assert-Throws 'a package missing a declared library is rejected' { Test-Package $pkg '9.9.9' 'win' }
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\probe.ps1'), '# lib', $bomEnc)
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\backdoor.ps1'), '# lib', $bomEnc)
Assert-Throws 'a package carrying an undeclared file is rejected' { Test-Package $pkg '9.9.9' 'win' }
Remove-Item -LiteralPath (Join-Path $pkg 'win\lib\backdoor.ps1') -Force
Remove-Item -LiteralPath $pkg -Recurse -Force

Write-Host '[6b] scoped install (split onto legacy tree)'
$leg = New-TempDir 'envproxy_scoped_'
$spk = New-TempDir 'envproxy_split_'
$stg = New-TempDir 'envproxy_stage_'
New-Item -Path (Join-Path $leg 'win\lib'), (Join-Path $leg 'mac'), (Join-Path $leg 'release-notes') -ItemType Directory -Force | Out-Null
New-Item -Path (Join-Path $spk 'win\lib'), (Join-Path $spk 'release-notes') -ItemType Directory -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $leg 'win\envproxy.ps1'), '# entry OLD', $bomEnc)
[System.IO.File]::WriteAllText((Join-Path $leg 'win\lib\base.ps1'), '# lib OLD', $bomEnc)
Write-TestFile (Join-Path $leg 'win\old.cmd') 'stale'
Write-TestFile (Join-Path $leg 'mac\envproxy.sh') "#!/bin/bash`n# mac OLD"
Write-TestFile (Join-Path $leg 'mac\old.sh') 'stale'
Write-TestFile (Join-Path $leg 'VERSION') '1.0.0'
[System.IO.File]::WriteAllText((Join-Path $spk 'win\envproxy.ps1'), '# entry NEW', $bomEnc)
[System.IO.File]::WriteAllText((Join-Path $spk 'win\lib\base.ps1'), '# lib NEW', $bomEnc)
Write-TestFile (Join-Path $spk 'release-notes\v9.md') 'notes'
Write-TestFile (Join-Path $spk 'VERSION') '9.9.9'
Install-Package -SrcRoot $spk -ProjectRoot $leg -Stage $stg -ShipDirs @('win', 'release-notes', 'assets')
Assert-Eq 'scoped write updates own entry' '# entry NEW' ([System.IO.File]::ReadAllText((Join-Path $leg 'win\envproxy.ps1'), [System.Text.Encoding]::UTF8))
Assert-Eq 'scoped delete removes own stale file' $false (Test-Path -LiteralPath (Join-Path $leg 'win\old.cmd'))
Assert-Eq 'other platform entry untouched' "#!/bin/bash`n# mac OLD" (Get-Content -LiteralPath (Join-Path $leg 'mac\envproxy.sh') -Raw)
Assert-Eq 'other platform stale file left alone' $true (Test-Path -LiteralPath (Join-Path $leg 'mac\old.sh'))
Assert-Eq 'shared VERSION updated' '9.9.9' ((Get-Content -LiteralPath (Join-Path $leg 'VERSION') -Raw).Trim())
# rollback: lock the destination entry, the write must fail and originals come back
$fs = [System.IO.File]::Open((Join-Path $leg 'win\envproxy.ps1'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
$rbThrew = $false
try { Install-Package -SrcRoot $spk -ProjectRoot $leg -Stage $stg -ShipDirs @('win', 'release-notes', 'assets') } catch { $rbThrew = $true }
$fs.Close()
Assert-Eq 'locked write fails loudly' $true $rbThrew
Assert-Eq 'rollback restores entry' '# entry NEW' ([System.IO.File]::ReadAllText((Join-Path $leg 'win\envproxy.ps1'), [System.Text.Encoding]::UTF8))
Remove-Item -LiteralPath $leg -Recurse -Force
Remove-Item -LiteralPath $spk -Recurse -Force
Remove-Item -LiteralPath $stg -Recurse -Force

Write-Host '[7] the library set declared by the entry'
# The entry is a thin loader: it owns the library list and nothing else. These assertions keep
# that budget from eroding silently.
$entryText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '../win/envproxy.ps1'), [System.Text.Encoding]::UTF8)
$declaredList = [regex]::Match($entryText, '\$CoreLibs\s*=\s*@\(([^)]*)\)').Groups[1].Value
$declared = @([regex]::Matches($declaredList, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
$actual = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../win/lib') -Filter *.ps1 -File | ForEach-Object { $_.BaseName } | Sort-Object)
Assert-Eq 'declared libraries match the lib folder' ($declared -join ',') ($actual -join ',')
$empty = @($declared | Where-Object {
    $p = Join-Path $PSScriptRoot ("../win/lib/{0}.ps1" -f $_)
    ([regex]::Matches([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8), '(?m)^function\s')).Count -eq 0
})
Assert-Eq 'every library defines at least one function' '0' ($empty.Count)
Assert-Eq 'the entry stays a thin loader' $true (@([regex]::Matches($entryText, '(?m)^function\s')).Count -le 6)

Write-Host '[8] autorun launcher command'
# The command line written into the Run key has one source of truth; the installer's read-back
# check and the self-heal comparison both compare against it, so its shape is an invariant.
$cmd = Get-LauncherCommand
Assert-Eq 'launcher command points at the launcher file' $true ($cmd -like ('*' + $LauncherPath + '*'))
Assert-Eq 'launcher command hides the window' $true ($cmd -like '*WindowStyle Hidden*')
Assert-Eq 'launcher command bypasses execution policy' $true ($cmd -like '*ExecutionPolicy Bypass*')

Write-Host '[9] the monitor launch target'
# The monitor is started from the entry script, and libraries must never answer "where am I" on
# their own: inside a library $PSCommandPath / $PSScriptRoot point at the library file, so using
# them as the entry path starts a file that cannot run on its own (no monitor, and no log line).
$entryFile = Join-Path $PSScriptRoot '../win/envproxy.ps1'
Assert-Eq 'the entry publishes its own path' ((Get-Item -LiteralPath $entryFile).FullName) ((Get-Item -LiteralPath $ScriptPath).FullName)
Assert-Eq 'the script directory derives from it' ((Get-Item -LiteralPath (Split-Path -Parent $entryFile)).FullName) ((Get-Item -LiteralPath $ScriptDir).FullName)
$launch = @(Get-MonitorLaunchArgs)
Assert-Eq 'launch args end with -File' '-File' $launch[-2]
Assert-Eq 'launch args quote the entry path' ('"{0}"' -f (Get-Item -LiteralPath $entryFile).FullName) $launch[-1]
Assert-Eq 'launch target is the entry, not a library' 'envproxy.ps1' (Split-Path -Leaf ($launch[-1].Trim('"')))
Assert-Eq 'launch target exists' $true (Test-Path -LiteralPath ($launch[-1].Trim('"')))
# Confirming a freshly started monitor judges by the pid file the monitor writes itself (it writes
# it only after it owns the singleton). "Some process has this script on its command line" is not
# enough: the process that just lost the singleton race looks like that for a moment too, and that
# is how an installer came to print "started" while nothing was running.
$dir9 = New-TempDir 'envproxy_pid_'
$savedPidFile = $PidFile
$PidFile = Join-Path $dir9 'monitor.pid'
Assert-Eq 'no pid file is not a confirmed monitor' '' (Get-MonitorProcessFromPidFile)
Write-TestFile $PidFile '999999'
Assert-Eq 'a dead pid is not a confirmed monitor' '' (Get-MonitorProcessFromPidFile)
$PidFile = $savedPidFile
Remove-Item -LiteralPath $dir9 -Recurse -Force

Write-Host '[10] judging a finished install'# The updater decides the finish step worked by reading the install root's pid file, never by the
# child's exit code: PowerShell 5.1 cannot read ExitCode after Start-Process -PassThru (it returns
# empty), so treating "unreadable" as failure makes every update run the fallback and tear down the
# monitor it had just started.
$root10 = New-TempDir 'envproxy_finish_'
New-Item -Path (Join-Path $root10 'win\monitor') -ItemType Directory -Force | Out-Null
Assert-Eq 'no pid file is not a finished install' $false (Test-InstallRootMonitor $root10)
Write-TestFile (Join-Path $root10 'win\monitor\monitor.pid') '999999'
Assert-Eq 'a dead pid is not a finished install' $false (Test-InstallRootMonitor $root10)
Write-TestFile (Join-Path $root10 'win\monitor\monitor.pid') ([string]$PID)
Assert-Eq 'a live non-monitor pid is not a finished install' $false (Test-InstallRootMonitor $root10)
Remove-Item -LiteralPath $root10 -Recurse -Force

Write-Host '[10b] status display stays read-only'
# 契约：状态显示永不写文件。它内部会快扫一次端口，而端口枚举失败时
# Find-CandidatePorts 会写日志——只读路径必须用 -NoLog 把这一路关掉，
# 否则一次 -Status 就往黑匣子里塞一行，既违反契约也污染日志。
Assert-Eq 'Get-ActiveProxyPort accepts -NoLog' $true ((Get-Command Get-ActiveProxyPort).Parameters.ContainsKey('NoLog'))
Assert-Eq 'Find-CandidatePorts accepts -NoLog' $true ((Get-Command Find-CandidatePorts).Parameters.ContainsKey('NoLog'))
$opsSrc = Get-Content (Join-Path $ScriptDir 'lib\ops.ps1') -Raw -Encoding UTF8
Assert-Eq 'status scan passes -NoLog' $true ($opsSrc -match 'Get-ActiveProxyPort[^\r\n]*-NoLog:\$true')

Write-Host '[11] the menu dispatch table'
# The menu maps numbers to existing entry switches; the shells call back through these
# switches, so every number must resolve and every switch must exist.
$menuKeys = @($MenuItems | ForEach-Object { $_.Key })
Assert-Eq 'menu has seven entries' 7 $menuKeys.Count
foreach ($k in @('1', '2', '3', '4', '5', '6', '0')) { Assert-Eq ('menu has key ' + $k) $true ($menuKeys -contains $k) }
$menuSwitches = @($MenuItems | Where-Object { $_.Switch } | ForEach-Object { $_.Switch })
foreach ($sw in @('Install', 'Status', 'Stop', 'Uninstall', 'Update', 'Help')) { Assert-Eq ('menu covers -' + $sw) $true ($menuSwitches -contains $sw) }
# Help exists and actually explains the three things a confused user needs.
# Asserting only "the function exists" is not enough: help text that says nothing
# still "exists". These keywords are the load-bearing facts.
Assert-Eq 'Show-Help is defined' 'Function' (Get-Command Show-Help -ErrorAction SilentlyContinue).CommandType
# Help is paginated: an index plus one topic per screen. The full text must still be
# reachable for non-interactive callers, so both shapes have to hold:
#   - every topic resolves to a body, and the index lists every topic key;
#   - the concatenation of all topics still carries the load-bearing facts.
$helpTopics = @(Get-HelpTopics)
Assert-Eq 'help has topics' $true ($helpTopics.Count -ge 7)
$helpIdx = Format-HelpIndex
foreach ($t in $helpTopics) {
    Assert-Eq ('help topic ' + $t.Key + ' renders') $true ($null -ne (Format-HelpTopic $t.Key))
    Assert-Eq ('help index lists topic ' + $t.Key) $true ($helpIdx -match ('(?m)^\s*' + [regex]::Escape($t.Key) + '\s{2}'))
    Assert-Eq ('help topic ' + $t.Key + ' has a title') $true (-not [string]::IsNullOrWhiteSpace($t.Title))
}
Assert-Eq 'help topic body is never empty' $true (@($helpTopics | Where-Object { @($_.Lines).Count -eq 0 }).Count -eq 0)
$helpTxt = (Format-HelpAll)
Assert-Eq 'help explains the Enter timing' $true ($helpTxt -match '回车')
Assert-Eq 'help points at install/repair as the catch-all' $true ($helpTxt -match '安装 / 修复')
Assert-Eq 'help gives the per-window switch' $true ($helpTxt -match 'ENVPROXY_TERM')
# Every screen ends with the way back out. Without it a user who lands on a topic
# has no idea how to leave, which is exactly the "wall of text" problem pagination solves.
Assert-Eq 'a topic screen says how to go back' $true ((Format-HelpTopic '1') -match '直接回车')
# 交互只有两种操作：输数字、直接回车。屏幕上不能出现 n / p / m / a 这类字母导航——
# 用户记不住哪个键管哪件事，而这正是之前被抱怨的地方。
# 这条钉住的是「文案里不许再出现字母导航」，不是措辞本身。
$topicText = (Format-HelpTopic '1')
Assert-Eq 'a topic screen offers no letter keys' $false ($topicText -match 'n = |p = |m = |a 看')
$indexText = (Format-HelpIndex)
Assert-Eq 'the help index offers no letter keys' $false ($indexText -match 'n = |p = |m = |a 看')
Assert-Eq 'the help index says what Enter does' $true ($indexText -match '直接回车')
# Every line gets a colour role so the screen has hierarchy instead of one grey wall.
# Roles are derived from the line shape, so each shape must be recognised.
$roleSeen = @{}
foreach ($t in $helpTopics) { foreach ($l in $t.Lines) { $roleSeen[(Get-HelpLineRole $l)] = $true } }
foreach ($r in @('heading', 'cmd', 'text')) { Assert-Eq ('help uses the ' + $r + ' role') $true $roleSeen.ContainsKey($r) }
# 屏幕形状：这一类坏法（命令被转义吃掉、混进开发机路径、行太长折行、
# 同一句写两遍、整屏超出终端高度）靠"关键字还在不在"是查不出来的——
# 坏行里往往还含有别的行的关键字，于是断言照样全绿。
# 所以直接量屏幕上会出现的形状，一次挡住一整类。
# 量的是真实渲染结果（$rendered），不是正文数组：标题、空行、导航行、提示行
# 都占屏幕，只数正文会漏掉它们。
foreach ($t in $helpTopics) {
    $rendered = @((Format-HelpTopic $t.Key) -split "`n")
    # 1) 一屏放得下：超出的部分会被终端切掉，而被切掉的常常是底部的「怎么退出」。
    Assert-Eq ('topic ' + $t.Key + ' renders within 30 lines') $true ($rendered.Count -le 30)
    # 2) 相邻两行一模一样 = 编辑时留下的重复段，用户会以为屏幕坏了。
    $dupFound = $false
    for ($i = 1; $i -lt $rendered.Count; $i++) {
        if ($rendered[$i] -ne '' -and $rendered[$i] -eq $rendered[$i - 1]) { $dupFound = $true; break }
    }
    Assert-Eq ('topic ' + $t.Key + ' has no duplicated line') $false $dupFound
    # 3) 行宽：超宽会让终端硬折行。例外是「一整条命令」——命令是给用户整条复制的，
    #    硬拆成两行会让复制变成两段、中间夹换行，粘进终端就成了两条命令，比折行更难用。
    #    所以判据是「超宽的行必须是一条命令（缩进 + 不含中文）」，而不是「一律不许超」。
    #    这比「一律不许超」弱，但它诚实表达了真实约束，而不是假装没超。
    $tooWide = ''
    foreach ($ln in $rendered) {
        $w = 0
        foreach ($ch in $ln.ToCharArray()) { $w += if ([int]$ch -gt 0x2E80) { 2 } else { 1 } }
        if ($w -le 80) { continue }
        if ($ln -match '^\s+\S' -and $ln -notmatch '[\u4e00-\u9fff]') { continue }
        $tooWide = $ln; break
    }
    Assert-Eq ('topic ' + $t.Key + ' has no line wider than 80 columns') '' $tooWide
    # 4) 不许混进本机的绝对路径：那一屏是给别人看的，写死 C:\Users\某人 会让别人困惑，
    #    换台机器就失准。$PROFILE 这类环境自带变量才是正确写法。
    $absPath = ''
    foreach ($ln in $rendered) { if ($ln -match '[A-Za-z]:\\Users\\|/Users/') { $absPath = $ln; break } }
    Assert-Eq ('topic ' + $t.Key + ' has no hardcoded home path') '' $absPath
    # 5) 命令不许残缺。判据只看「长得像命令的行」（4 格以上缩进 + 含 = 或 $ 或 set/unset），
    #    普通说明文字里出现 = 是正常的（比如「直接回车 = 回目录」），不能一起判死。
    #    要挡住的是这几类真实事故：反引号残留、变量名被吃成空、等号左边没名字。
    $broken = ''
    foreach ($ln in $rendered) {
        if ($ln -notmatch '^\s{4,}\S') { continue }
        # 反引号单独判：它不可能出现在任何正常文案里，不需要先满足"像命令"。
        if ($ln.IndexOf([char]96) -ge 0) { $broken = $ln; break }
        if ($ln -notmatch '=|\$|set |unset |export ') { continue }
        if ($ln -match '\$(\s|=|$)') { $broken = $ln; break }
        if ($ln -match '^\s+[=:]\s') { $broken = $ln; break }
    }
    Assert-Eq ('topic ' + $t.Key + ' has no broken command') '' $broken
}

# A table entry that is never printed is a feature the user cannot reach: the menu once
# printed a hardcoded list and [6] Help never appeared on screen even though the table
# had it. Show-Menu bails out under redirected input, so it cannot be exercised here --
# instead call the very renderer the menu prints, so this assertion cannot drift away
# from the real output (a locally rebuilt string would keep passing after a redesign).
$menuOut = Format-MenuText
foreach ($k in $menuKeys) { Assert-Eq ('menu prints key ' + $k) $true ($menuOut -match ('(?m)^\s*' + [regex]::Escape($k) + '\s{2}')) }
Assert-Eq 'every action has a hint' $true (@($MenuItems | Where-Object { $_.Switch }).Count -eq @($MenuItems | Where-Object { $_.Hint }).Count)
# Grouping is presentation only: every entry belongs to a declared group, and the
# groups keep their order so the screen reads 日常 -> 维护 -> 退出.
foreach ($mi in $MenuItems) { Assert-Eq ('menu item ' + $mi.Key + ' has a group') $true ($mi.Group -in @('日常', '维护', '退出')) }
$menuTextOrder = @()
foreach ($g in @('日常', '维护', '退出')) { $menuTextOrder += $menuOut.IndexOf($g) }
Assert-Eq 'menu groups render in order' $true ($menuTextOrder[0] -lt $menuTextOrder[1] -and $menuTextOrder[1] -lt $menuTextOrder[2])


# Test-CanPrompt guards every interactive screen. It once called itself instead of reading
# [Console]::IsInputRedirected: infinite recursion, stack overflow, swallowed by catch, so it
# always returned $false -- the menu printed one line and quit on every real console, and
# -Help took 14s. No behavioural test catches that (the suite runs redirected, where False is
# the CORRECT answer). So pin the shape: the body must not mention its own name.
$canPromptSrc = (Get-Command Test-CanPrompt).Definition
Assert-Eq 'Test-CanPrompt does not call itself' $false ($canPromptSrc -match 'Test-CanPrompt\s*\)')
Assert-Eq 'Test-CanPrompt reads IsInputRedirected' $true ($canPromptSrc -match 'IsInputRedirected')
# Same class of mistake, other direction: a guard that always says "no prompt" would make the
# menu unreachable too. Pin that the redirect check is a plain property read, in a single line.
Assert-Eq 'Test-CanPrompt has no nested function' $false ($canPromptSrc -match 'function\s+Test-CanPrompt')
Write-Host '[12] the online update source table'
# The updater walks an ordered source table and takes the first source that answers, so a broken
# table degrades silently: updates keep "working" until the day the official source is unreachable.
# Two properties are load-bearing:
#   - it must ALWAYS come back as a list. PowerShell unwraps a single-element collection, so with
#     only the official source enabled (the normal state) the
#     caller would receive one hashtable instead of a list of sources: foreach then walks its
#     key/value pairs, and .Count reports the number of keys (4) rather than the number of sources.
#   - every entry must carry the four fields the walker reads, with the @@ placeholder intact.
$srcTable0 = Get-UpdateSources
Assert-Eq 'sources always come back as a list' 'Object[]' $srcTable0.GetType().Name
Assert-Eq 'at least one source is usable' $true ($srcTable0.Count -ge 1)
Assert-Eq 'the official source stays first' 'official' $UpdateSourceTable[0].Id
foreach ($s in $UpdateSourceTable) {
    Assert-Eq ('source ' + $s.Name + ' declares exactly Id/Name/Preferred/Api/Web/Base/ApiRepo') 7 (@($s.Keys).Count)
    Assert-Eq ('source ' + $s.Name + ' keeps a placeholder in Api') $true ($s.Api -like '*@@*')
    Assert-Eq ('source ' + $s.Name + ' keeps a placeholder in Web') $true ($s.Web -like '*@@*')
    Assert-Eq ('source ' + $s.Name + ' keeps a placeholder in Base') $true ($s.Base -like '*@@*')
    Assert-Eq ('source ' + $s.Name + ' keeps a placeholder in ApiRepo') $true ($s.ApiRepo -like '*@@*')
    Assert-Eq ('source ' + $s.Name + ' prefers a known path') $true (@('Api', 'Web') -contains $s.Preferred)
}
# Picking an asset id out of a release payload decides whether a package download ever leaves
# api.github.com for the flaky github.com host, so the shape rules are pinned here: the id must be
# the one belonging to the named asset (never the release id, never the uploader id), and any
# unparsable payload must come back empty so the caller falls back to the direct URL.
$assetJson = '{"id":99,"tag_name":"v1.2.3","assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/12345","id":12345,"name":"EnvProxy-win.zip","uploader":{"login":"u","id":777}},{"url":"https://api.github.com/repos/o/r/releases/assets/67890","id":67890,"name":"EnvProxy-mac.tar.gz"}]}'
# The sample mirrors what the server actually sends: indented, with a space after each colon.
# Pinning only a minified payload would pin our own assumption instead of the outside world.
$assetPretty = @'
{
  "id": 99,
  "tag_name": "v1.2.3",
  "assets": [
    {
      "url": "https://api.github.com/repos/o/r/releases/assets/12345",
      "id": 12345,
      "name": "EnvProxy-win.zip",
      "uploader": { "login": "u", "id": 777 }
    },
    {
      "url": "https://api.github.com/repos/o/r/releases/assets/67890",
      "id": 67890,
      "name": "EnvProxy-mac.tar.gz"
    }
  ]
}
'@
Assert-Eq 'an asset id is taken from the indented payload the server really sends' '67890' ((Get-AssetFromJson $assetPretty 'EnvProxy-mac.tar.gz').Id)
Assert-Eq 'an asset id is taken by file name' '67890' ((Get-AssetFromJson $assetJson 'EnvProxy-mac.tar.gz').Id)
Assert-Eq 'the first asset is still matched exactly' '12345' ((Get-AssetFromJson $assetJson 'EnvProxy-win.zip').Id)
Assert-Eq 'a missing file name yields nothing' '' (Get-AssetFromJson $assetJson 'EnvProxy-nope.zip')
Assert-Eq 'an unparsable payload yields nothing' '' (Get-AssetFromJson 'not json' 'EnvProxy-win.zip')
Assert-Eq 'an empty payload yields nothing' '' (Get-AssetFromJson '' 'EnvProxy-win.zip')
# The file name must match byte for byte: GitHub asset names are case sensitive, and PowerShell's
# -eq is NOT — without -ceq a differently-cased name would match and download the wrong file.
Assert-Eq 'a differently cased file name does not match' '' (Get-AssetFromJson $assetJson 'envproxy-mac.tar.gz')
# The id comes from the url (the endpoint we actually GET); the id field is only a fallback.
$assetUrlFirst = '{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/555","id":999,"name":"EnvProxy-win.zip"}]}'
Assert-Eq 'the url wins over the id field' '555' ((Get-AssetFromJson $assetUrlFirst 'EnvProxy-win.zip').Id)
$assetIdOnly = '{"assets":[{"url":"https://example.invalid/x","id":666,"name":"EnvProxy-win.zip"}]}'
Assert-Eq 'the id field is used when the url has no number' '666' ((Get-AssetFromJson $assetIdOnly 'EnvProxy-win.zip').Id)
# A malformed id must not reach the URL: 0, a leading zero and an absurd length are all wrong.
foreach ($badId in @('0', '007', '12345678901234567890')) {
    $badJson = '{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/' + $badId + '","name":"EnvProxy-win.zip"}]}'
    Assert-Eq ("a malformed id is refused: " + $badId) '' (Get-AssetFromJson $badJson 'EnvProxy-win.zip')
}
# The digest is GitHub's own checksum of the asset. A wrong shape counts as no digest at all
# (older assets do not carry the field).
$digestOk = 'sha256:' + ('a' * 64)
$assetDigest = '{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/777","name":"EnvProxy-win.zip","digest":"' + $digestOk + '"}]}'
Assert-Eq 'a valid digest is taken' $digestOk ((Get-AssetFromJson $assetDigest 'EnvProxy-win.zip').Digest)
$assetDigestNull = '{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/777","name":"EnvProxy-win.zip","digest":null}]}'
Assert-Eq 'a null digest counts as no digest' '' ((Get-AssetFromJson $assetDigestNull 'EnvProxy-win.zip').Digest)
$assetDigestBad = '{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/777","name":"EnvProxy-win.zip","digest":"sha256:XYZ"}]}'
Assert-Eq 'a malformed digest counts as no digest' '' ((Get-AssetFromJson $assetDigestBad 'EnvProxy-win.zip').Digest)
# Reading a tag out of a redirect target is shape-checked, and that check is not cosmetic: a repo
# that got renamed answers /releases/latest with a redirect to the renamed repo's path, whose last
# segment is the literal "latest". Taking the tail blindly would turn that into a version number
# and then into a download URL built from garbage.
Assert-Eq 'a tag-page redirect yields its tag' 'v0.3.2' (Get-TagFromLocation 'https://github.com/owner/repo/releases/tag/v0.3.2')
Assert-Eq 'a renamed-repo redirect yields nothing' '' (Get-TagFromLocation 'https://github.com/new-owner/repo/releases/latest')
Assert-Eq 'a tag with parentheses survives intact' 'v2026.09(jdk25)' (Get-TagFromLocation 'https://github.com/x/y/releases/tag/v2026.09(jdk25)')
Assert-Eq 'an empty redirect target yields nothing' '' (Get-TagFromLocation '')
Assert-Eq 'a location without a tag segment yields nothing' '' (Get-TagFromLocation 'https://github.com/owner/repo/releases')
# The web path answers with a 302, and a 302 is not a success status code. Reading the status
# before the redirect target turns this whole fallback into a dead path -- and since "network"
# outranks "quota" in the failure table, it also flattens the rate limit the API path did detect.
# So the redirect is exercised against a real local server here: a unit test on the pure
# function alone would never have caught it.
$srv = Start-OneShotServer 302 @{ Location = "http://127.0.0.1:0/owner/repo/releases/tag/v7.7.7" } ''
try {
    $webResult = Get-TagFromWebVia "http://127.0.0.1:$($srv.Port)/owner/repo/releases/latest" ""
    Assert-Eq 'the web path reads the tag out of a 302 redirect' 'v7.7.7' $webResult.Tag
    Assert-Eq 'a 302 is not a failure' '' $webResult.Failure
} finally { Stop-OneShotServer $srv }
# The API path has to tell a rate limit apart from a refusal, and it does it by reading
# X-RateLimit-Remaining. Getting that wrong sends the user off to switch on a proxy for
# something that will be fine in an hour.
$srv = Start-OneShotServer 403 @{ 'X-RateLimit-Remaining' = '0' } '{"message":"API rate limit exceeded"}'
try {
    $null = Invoke-UpdateText "http://127.0.0.1:$($srv.Port)/repos/o/r/releases/latest"
    Assert-Eq 'a rate limited version query is reported as a quota problem' 'quota' $script:UpdateLastVersionFailure
} finally { Stop-OneShotServer $srv }
$srv = Start-OneShotServer 403 @{ 'X-RateLimit-Remaining' = '42' } '{"message":"Forbidden"}'
try {
    $null = Invoke-UpdateText "http://127.0.0.1:$($srv.Port)/repos/o/r/releases/latest"
    Assert-Eq 'a refused version query with quota left is reported as a server problem' 'server' $script:UpdateLastVersionFailure
} finally { Stop-OneShotServer $srv }
# The download is checked against the digest GitHub publishes for the asset. That digest comes
# with the asset listing we already fetched, so the check costs no extra request and no extra
# download. A release without the field is simply not checked -- refusing to update over a
# missing field would block every older release.
$digestDir = New-TempDir 'ep-digest'
$digestFile = Join-Path $digestDir 'pkg.zip'
[System.IO.File]::WriteAllText($digestFile, 'hello')
$digestReal = 'sha256:' + (Get-Sha256Hex $digestFile)
Assert-Eq 'a matching digest passes' 'ok' (Test-AssetDigest $digestFile $digestReal)
Assert-Eq 'a wrong digest is caught' 'mismatch' (Test-AssetDigest $digestFile ('sha256:' + ('0' * 64)))
Assert-Eq 'no digest means no check' 'skip' (Test-AssetDigest $digestFile '')
Assert-Eq 'a malformed digest is not a pass' 'mismatch' (Test-AssetDigest $digestFile 'sha256:XYZ')
# A file we cannot read is not a file that was tampered with. An antivirus scanner holds the
# freshly downloaded package for a moment; calling that "the content was rewritten" blames the
# publisher for a local hiccup (and the mac side lets the same case through).
$digestMissing = Join-Path $digestDir 'not-there.zip'
Assert-Eq 'a file that is not there is not a mismatch' 'skip' (Test-AssetDigest $digestMissing $digestReal)
# The digest hex case must be handled the same way on both sides: a publisher that answers in
# uppercase must not make one platform check and the other silently skip.
$assetDigestUpper = '{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/777","name":"EnvProxy-win.zip","digest":"sha256:2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824"}]}'
Assert-Eq 'an uppercase digest is accepted and normalised' 'sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824' ((Get-AssetFromJson $assetDigestUpper 'EnvProxy-win.zip').Digest)
# A tag goes into a URL, so it has to be encoded first. The tag comes from the server's answer,
# not from us: a tag with a space or a slash would otherwise build a broken address.
Assert-Eq 'a plain tag is left alone' 'v1.2.3' (ConvertTo-UrlSegment 'v1.2.3')
Assert-Eq 'a space in a tag is encoded' 'v1%202' (ConvertTo-UrlSegment 'v1 2')
Assert-Eq 'a slash in a tag is encoded' '..%2F..%2Fevil' (ConvertTo-UrlSegment '../../evil')
Assert-Eq 'a question mark in a tag is encoded' 'v1%3F2' (ConvertTo-UrlSegment 'v1?2')
# A 200 that does not carry a release document is not "this release ships no such file".
    # A captive portal answers 200 with an HTML login page; reporting that as a missing file
    # blames the publisher and sends the user to a page that cannot help either.
    $relJson = '{"tag_name":"v1.0.0","assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/1","name":"EnvProxy-win.zip"}]}'
    [void](Get-AssetFromJson $relJson 'EnvProxy-win.zip')
    Assert-Eq 'a release document is recognised as one' 'release' $script:UpdateAssetScope
    [void](Get-AssetFromJson '<html><body>Login</body></html>' 'EnvProxy-win.zip')
    Assert-Eq 'an HTML page is not a release document' 'other' $script:UpdateAssetScope
    [void](Get-AssetFromJson '{"message":"Bad credentials"}' 'EnvProxy-win.zip')
    Assert-Eq 'an error object is not a release document' 'other' $script:UpdateAssetScope
    [void](Get-AssetFromJson $relJson 'EnvProxy-nope.zip')
    Assert-Eq 'a release document without our file is still a release document' 'release' $script:UpdateAssetScope

# The reason for a failed asset lookup must take part in the picking. Otherwise that failure
# stays invisible and only the direct download counts -- and a 404 there gets reported as
# "the release does not ship this file", blaming the maintainer for what is really a quota.
$remoteForAsset = @{ ApiRepo = 'http://127.0.0.1:1/repos/o/r'; Tag = 'v1.0.0'; Base = 'http://127.0.0.1:1/o/r'; Name = 'GitHub' }
# 这条只问一件事：连不上时归哪一类。可本机要是正好有代理在跑，代码会经它重试一次，
# 代理替我们回一个 502，就被归成"对方服务端出错"——测试结果跟着这台机器当时的状态摇摆。
# 把"有没有活代理"在测试作用域里固定成没有，这一条才只测它自己那件事。
function Get-ActiveProxyPort { param([switch]$FullScan) return $null }
Assert-Eq 'an asset lookup that cannot reach the API reports a network problem' 'network' (Get-UpdateAsset $remoteForAsset 'EnvProxy-win.zip').Failure
Assert-Eq 'the placeholder expands into the repo id' 'https://api.github.com/repos/owner/repo/releases/latest' ($UpdateSourceTable[0].Api).Replace('@@', 'owner/repo')
# No source may come back with an empty repo id: the walker would build a URL with a hole where the
# id goes, and the fetch would fail in a way that looks like a network problem.
# Count is taken straight off the returned value, never wrapped in @(): Get-UpdateSources returns
# ,$out to force an array, and @(...) around a call collapses that into "one element".
Assert-Eq 'no source comes back with an empty repo id' '0' (@($srcTable0 | Where-Object { -not $_.Repo }).Count)
Assert-Eq 'every exported source carries its five walker fields' '0' (@($srcTable0 | Where-Object { -not $_.Api -or -not $_.Web -or -not $_.Base -or -not $_.Preferred -or -not $_.ApiRepo }).Count)

# The repo id comes off the git remote, and every way of writing that remote has to give the same
# answer: the last two path segments. Reading it with a greedy ".*github.com[:/]([^/]+)/([^/]+)"
# looks fine until the remote carries a port -- ssh://git@ssh.github.com:443/owner/repo hands back
# "443/owner", the query URL is built against the wrong repo, and the user is told "the release
# does not ship this file, download it by hand" -- the wrong next step, from a working release.
Assert-Eq 'https remote' 'owner/repo' (Get-RepoIdFromRemoteUrl 'https://github.com/owner/repo.git')
Assert-Eq 'https remote without the .git suffix' 'owner/repo' (Get-RepoIdFromRemoteUrl 'https://github.com/owner/repo')
Assert-Eq 'scp-style remote' 'owner/repo' (Get-RepoIdFromRemoteUrl 'git@github.com:owner/repo.git')
Assert-Eq 'ssh remote with a port' 'owner/repo' (Get-RepoIdFromRemoteUrl 'ssh://git@ssh.github.com:443/owner/repo.git')
Assert-Eq 'a trailing slash is not part of the id' 'owner/repo' (Get-RepoIdFromRemoteUrl 'https://github.com/owner/repo/')
Assert-Eq 'a host that is not GitHub is not an id' '' (Get-RepoIdFromRemoteUrl 'https://gitlab.com/owner/repo.git')
Assert-Eq 'a local path is not an id' '' (Get-RepoIdFromRemoteUrl 'D:\somewhere\repo')
Assert-Eq 'an empty remote is not an id' '' (Get-RepoIdFromRemoteUrl '')

Write-Host '[5c] update failure classification'
# The reason a download failed decides what the user is told to do next: wait an hour
# (quota), open the proxy (network), download by hand (missing), or fix the disk (local).
# Collapsing them into one "failed" string is what made the advice useless.
Assert-Eq '404 means the release does not ship the file' 'missing' (Get-UpdateFailureKind 404)
Assert-Eq '410 also means the file is gone' 'missing' (Get-UpdateFailureKind 410)
Assert-Eq '429 means the API quota is exhausted' 'quota' (Get-UpdateFailureKind 429)
Assert-Eq '403 with no quota left means the quota is exhausted' 'quota' (Get-UpdateFailureKind 403 '0')
Assert-Eq '403 with quota to spare is a refusal, not a quota problem' 'server' (Get-UpdateFailureKind 403 '42')
Assert-Eq '403 with an unknown quota header is a refusal' 'server' (Get-UpdateFailureKind 403)
Assert-Eq '5xx is a server-side problem' 'server' (Get-UpdateFailureKind 503)
Assert-Eq 'any other status is treated as unreachable' 'network' (Get-UpdateFailureKind 418)
# Picking one reason out of several attempts: "missing" only stands when nothing else
# explains the failure. A walled middlebox answers 404 to everything, so a lone 404
# next to a timeout must not be reported as "the maintainer forgot to publish".
Assert-Eq 'a single reason is reported as is' 'missing' (Select-UpdateFailureKind @('missing'))
Assert-Eq 'two identical reasons collapse to one' 'missing' (Select-UpdateFailureKind @('missing', 'missing'))
Assert-Eq 'a timeout next to a 404 reports the timeout' 'network' (Select-UpdateFailureKind @('missing', 'network'))
Assert-Eq 'a quota next to a 404 reports the quota' 'quota' (Select-UpdateFailureKind @('missing', 'quota'))
Assert-Eq 'an unwritable temp dir outranks the timeout' 'local' (Select-UpdateFailureKind @('network', 'local'))
# The table's order IS the report priority, so it is worth pinning: adding a reason must not
# silently reorder the advice, and "missing" must stay last (it accuses the maintainer).
Assert-Eq 'the table lists every reason exactly once' '6' (@($UpdateFailureKinds | Select-Object -Unique).Count)
Assert-Eq 'the table puts the local problem first' 'local' $UpdateFailureKinds[0]
Assert-Eq 'the table puts the missing-package case last' 'missing' $UpdateFailureKinds[$UpdateFailureKinds.Count - 1]
Assert-Eq 'no reason at all falls back to unreachable' 'network' (Select-UpdateFailureKind @())
Assert-Eq 'an empty reason falls back to unreachable' 'network' (Select-UpdateFailureKind @(''))
# The advice must name the action, otherwise the user still has to guess.
$msgMissing = Get-UpdateFailureMessage 'missing' 'GitHub'
$msgQuota = Get-UpdateFailureMessage 'quota' 'GitHub'
$msgNet = Get-UpdateFailureMessage 'network' 'GitHub'
$msgLocal = Get-UpdateFailureMessage 'local' 'GitHub'
Assert-Eq 'the missing-file advice points at manual download' '1' ([int]($msgMissing -match '手动下载'))
Assert-Eq 'the quota advice says it clears with time' '1' ([int]($msgQuota -match '一小时|重试'))
Assert-Eq 'the network advice points at the proxy' '1' ([int]($msgNet -match '代理'))
Assert-Eq 'the local advice points at the disk' '1' ([int]($msgLocal -match '磁盘|权限'))
$advices = @('missing', 'quota', 'server', 'network', 'bad-content', 'local') | ForEach-Object { Get-UpdateFailureMessage $_ 'GitHub' }
Assert-Eq 'no advice claims success' '0' (@($advices | Where-Object { $_ -match '成功' }).Count)

Write-Host '[7b] listening port enumeration'

# The listening port list drives the whole judgment, so the netstat parsing has to be exact.
# netstat writes IPv4 as "127.0.0.1:8080" and IPv6 as "[::1]:8080" (with brackets).
$ep4 = ConvertTo-ListenEndpoint '127.0.0.1:8080'
Assert-Eq 'an IPv4 endpoint splits into address and port' '127.0.0.1|8080' ("$($ep4.Address)|$($ep4.Port)")
$ep6 = ConvertTo-ListenEndpoint '[::1]:8080'
Assert-Eq 'a bracketed IPv6 endpoint splits too' '::1|8080' ("$($ep6.Address)|$($ep6.Port)")
$epAny = ConvertTo-ListenEndpoint '[::]:135'
Assert-Eq 'the any-address IPv6 form is understood' '::|135' ("$($epAny.Address)|$($epAny.Port)")
$epHigh = ConvertTo-ListenEndpoint '0.0.0.0:65535'
Assert-Eq 'the highest port is understood' '65535' "$($epHigh.Port)"
# A line that is not an endpoint must be dropped, never guessed at.
Assert-Eq 'a line without a port is rejected' '1' ([int]($null -eq (ConvertTo-ListenEndpoint 'nonsense')))
Assert-Eq 'a port that is not a number is rejected' '1' ([int]($null -eq (ConvertTo-ListenEndpoint '127.0.0.1:abc')))
Assert-Eq 'port zero is rejected' '1' ([int]($null -eq (ConvertTo-ListenEndpoint '127.0.0.1:0')))
Assert-Eq 'a port above the range is rejected' '1' ([int]($null -eq (ConvertTo-ListenEndpoint '127.0.0.1:70000')))
Assert-Eq 'a broken bracket is rejected' '1' ([int]($null -eq (ConvertTo-ListenEndpoint '[::1:8080')))

# The signal "are there TCP rows" must not come out of the parse itself. When the row shape
# changes (an extra column, a state made of two words) nothing matches, and an empty answer
# would be read as "no port is listening" -- the state machine would then call off and delete
# the user's proxy variables. The protocol column is never localised, so a loose match on it
# survives every shape change.
if ($env:OS -eq 'Windows_NT') {
    $global:NetstatStub = @()
    function global:netstat.exe { $global:NetstatStub }
    $shapeCases = @(
        @{ Name = 'an extra column'; Lines = @('  Proto Local Foreign State PID InHost', '  TCP    0.0.0.0:22    0.0.0.0:0    LISTENING    6544    -') },
        @{ Name = 'a state made of two words'; Lines = @('  Proto Local Foreign State PID', '  TCP    0.0.0.0:22    0.0.0.0:0    LISTEN  6544') },
        @{ Name = 'a localised state'; Lines = @('  Proto Local Foreign State PID', '  TCP    0.0.0.0:22    0.0.0.0:0    ABHÖREN    6544') }
    )
    foreach ($case in $shapeCases) {
        $global:NetstatStub = $case.Lines
        $shapeThrew = $false
        $shapeCount = -1
        try { $shapeCount = @(Get-ListeningTcpConnections).Count } catch { $shapeThrew = $true }
        # Falling back to WMI is the right answer: it is slow but it is right.
        Assert-Eq ('a netstat row shape that changed is handled, not swallowed: ' + $case.Name) '0' ([int]$shapeThrew)
    }
    # Output that carries no TCP row at all is not something we can read: say so instead of
    # handing back an empty list, which looks exactly like "nothing is listening".
    $global:NetstatStub = @('  Proto Local Foreign State PID')
    $noTcpThrew = $false
    try { [void](Get-ListeningTcpConnections) } catch { $noTcpThrew = $true }
    Assert-Eq 'output without a single TCP row is refused instead of reported as empty' '1' ([int]$noTcpThrew)
    Remove-Item function:global:netstat.exe -ErrorAction SilentlyContinue
    Remove-Variable -Name NetstatStub -Scope Global -ErrorAction SilentlyContinue
}

# The enumeration has to agree with the system: a port that is really listening must be found,
# and a port that is not must not be. This is the one check that would catch a parse that
# silently returns nothing -- which would make the monitor believe there is no proxy.
#
# A machine that has neither netstat nor the WMI fallback (the CI runs this file on Linux
# as well) has nothing to compare against: the enumeration reports that it cannot read,
# which is the right answer, so the comparison is skipped there instead of failing.
$probeListen = @()
$probeThrew = $false
try { $probeListen = Get-ListeningTcpConnections } catch { $probeThrew = $true }
if ($probeThrew) {
    Write-Host '  SKIP 本机既没有 netstat 也没有 WMI 兜底，无法与系统核对'
} else {
    # 取第一个元素的属性名：直接对数组取 .PSObject 拿到的是数组自己的属性（Count/Length），不是元素的。
    $probeFirst = @($probeListen)[0]
    $probeNames = @()
    if ($probeFirst) { $probeNames = @($probeFirst.PSObject.Properties.Name) }
    Assert-Eq 'the enumeration exposes the local address' '1' ([int]($probeNames -contains 'LocalAddress'))
    Assert-Eq 'the enumeration exposes the local port' '1' ([int]($probeNames -contains 'LocalPort'))
    Assert-Eq 'the enumeration exposes the owning process' '1' ([int]($probeNames -contains 'OwningProcess'))
    if (@($probeListen).Count -gt 0) {
        $somePort = @($probeListen)[0].LocalPort
        Assert-Eq 'a port the system reports as listening is found' '1' ([int](Test-PortListening $somePort))
        Assert-Eq 'the same port is found in the port list' '1' ([int](@($probeListen.LocalPort) -contains $somePort))
    }
    Assert-Eq 'a port nothing listens on is not reported' '0' ([int](Test-PortListening 1))
}

# ------------------------------------------------------------------------------
# [2b] 入口不许默默跑起来：多余或打错的参数要报用法错误（退出码 2）
# ------------------------------------------------------------------------------
# powershell -File 对不认识的参数名不报绑定错误，它们只是落进 $args。
# 不拦的话，敲错一个选项就会静默进入监控模式。
# 这里用子进程验：点源加载时 $args 是空的，验不到。
$entryPath = Join-Path $PSScriptRoot '../win/envproxy.ps1'
function Invoke-EntryChild([string[]]$EntryArgs) {
    $exe = (Get-Process -Id $PID).Path
    if ($env:OS -ne 'Windows_NT') {
        # Linux 上 Start-Process 不支持重定向参数，直接调用取退出码。
        & $exe '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' $entryPath @EntryArgs 2>$null | Out-Null
        return $LASTEXITCODE
    }
    # 临时目录用 .NET 的 GetTempPath：Linux 上没有 $env:TEMP（那是 Windows 才有的变量），
    # 直接写 $env:TEMP 会让 Join-Path 收到 null，整个自检在这一步就崩掉。
    $tmpDir = [System.IO.Path]::GetTempPath()
    $outFile = Join-Path $tmpDir ("ep-entry-out-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".txt")
    $errFile = Join-Path $tmpDir ("ep-entry-err-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".txt")
    try {
        # 每个参数都要自己带引号：Start-Process 把参数数组用空格拼成一条命令行，
        # 不加引号时空参数会被整个吞掉（"空参数要报用法错误"这条就永远测不到）。
        $quoted = @('"-NoProfile"', '"-ExecutionPolicy"', '"Bypass"', '"-File"', ('"' + $entryPath + '"'))
        foreach ($a in $EntryArgs) { $quoted += ('"' + $a + '"') }
        $ps = Start-Process -FilePath $exe -PassThru -NoNewWindow -Wait `
            -ArgumentList $quoted `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        return $ps.ExitCode
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}
# 打错的参数名也要拒（不只是不认识的）：它是入口守卫最典型的用途。
foreach ($bad in @('-Installt')) {
    $rc = Invoke-EntryChild @($bad)
    Assert-Eq ("入口拒绝打错的参数: " + $bad) 2 $rc
}

# ------------------------------------------------------------------------------
# [2c] 入口的参数与退出码：两侧同一套，门禁 10 把两边的这些行互相比一次
# ------------------------------------------------------------------------------
# 只放平台无关的用例：三种误用都在动手之前被拦下，两端跑出来的退出码必然相同。
# "合法用法必须放行"是另一回事（见下面那条本地断言）：它要真跑子命令，
# 而 Windows 的状态显示依赖注册表、只在 Windows 上有确定结果，所以不进跨端契约。
$entryCases = @(
    @{ Name = 'unknown-arg';          Args = @('-Foo');              Want = 2 },
    @{ Name = 'extra-positional';     Args = @('-Status', 'extra');  Want = 2 },
    @{ Name = 'purge-misuse';         Args = @('-Install', '-Purge'); Want = 2 },
    @{ Name = 'switch-without-command'; Args = @('-Yes');            Want = 2 },
    @{ Name = 'unknown-switch';       Args = @('-Status', '-Foo');   Want = 2 },
    @{ Name = 'two-commands';         Args = @('-Install', '-Uninstall'); Want = 2 }
)
foreach ($c in $entryCases) {
    $rc = Invoke-EntryChild $c.Args
    Assert-Eq ("入口退出码: " + $c.Name) $c.Want $rc
    Write-Host ("entry {0} {1}" -f $c.Name, $rc)
}
# 空参数不等于"没传参数"：前者是参数写错（退出码 2），后者才是监控模式。
$rc = Invoke-EntryChild @('')
Assert-Eq '入口：空参数要报用法错误（不能当成没传参数）' 2 $rc
# 用法判定本身是纯函数（base 层 Get-UsageError，两端同形），两个方向都要钉住：
# "必须拒"不许放过，"必须放行"不许误伤。
# "放行"这一向只能在这里测：真跑一次入口就会真的卸载或更新，副作用落在用户机器上。
$null = Get-UsageError -Command 'status' -CommandCount 1
Assert-Eq '用法判定：普通命令放行' '' $null
$null = Get-UsageError -Command '' -CommandCount 0
Assert-Eq '用法判定：无命令（监控模式）放行' '' $null
$null = Get-UsageError -Command 'uninstall' -CommandCount 1 -Switches @('purge')
Assert-Eq '用法判定：卸载带 -Purge 放行' '' $null
$null = Get-UsageError -Command 'update' -CommandCount 1 -Switches @('yes')
Assert-Eq '用法判定：更新带 -Yes 放行' '' $null
function Usage-Rejected($e) { if ($e) { '真' } else { '假' } }
Assert-Eq '用法判定：-Purge 跟着别的命令要拒' '真' (Usage-Rejected (Get-UsageError -Command 'install' -CommandCount 1 -Switches @('purge')))
Assert-Eq '用法判定：-Yes 跟着别的命令要拒' '真' (Usage-Rejected (Get-UsageError -Command 'status' -CommandCount 1 -Switches @('yes')))
Assert-Eq '用法判定：不认识的参数要拒' '真' (Usage-Rejected (Get-UsageError -Command 'status' -CommandCount 1 -Extra @('-Foo')))
Assert-Eq '用法判定：一次给两个命令要拒' '真' (Usage-Rejected (Get-UsageError -Command 'install' -CommandCount 2))

# ------------------------------------------------------------------------------
# [7c] 端口枚举失败 = 这一轮不知道，不是"没有端口"
# ------------------------------------------------------------------------------
# 读不出来却被当成空表，状态机会判 off -> 把用户的代理环境变量删掉。
# 两侧的判据必须一样：枚举失败要传上去，状态机据此沿用上一状态。
if ($env:OS -eq 'Windows_NT') {
    function global:netstat.exe { throw "netstat is not available" }
    function global:Get-NetTCPConnection { throw "Get-NetTCPConnection is not recognized" }
    $script:CachedPort = $null
    $unknownState = Get-CurrentState
    Assert-Eq '端口枚举失败时状态是"不知道"而不是 off' 'unknown' $unknownState
    Remove-Item function:global:netstat.exe -ErrorAction SilentlyContinue
    Remove-Item function:global:Get-NetTCPConnection -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------------------
# [8c] 资产解析契约：同一批应答，两侧必须得出同一个结论
# ------------------------------------------------------------------------------
# 用例放在 tests/asset-cases.txt：名字、正文种类、编号、校验值、失败原因、正文。
# 这里跑一遍并和文件里写下的期望比对；每一行还打印成 "contract ..."，
# 门禁 10 再把两边的这些行互相比一次——文本层面的门禁看不出行为漂移，
# 行为层面才看得出来（同一个应答，一边更新、一边说"没提供安装包"就是这种漂移）。
$contractFile = Join-Path $PSScriptRoot 'asset-cases.txt'
if (Test-Path -LiteralPath $contractFile) {
    $contractSeen = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($contractFile, [System.Text.Encoding]::UTF8)) {
        if (-not $line -or $line.StartsWith('#')) { continue }
        $f = $line -split "\|"
        if ($f.Count -ne 6) { Assert-Eq ('用例行字段数不对: ' + $f[0]) 6 $f.Count; continue }
        $cName = $f[0]; $cScope = $f[1]; $cId = $f[2]; $cDigest = $f[3]; $cFail = $f[4]; $cBody = $f[5]
        $asset = Get-AssetFromJson $cBody 'EnvProxy-test.zip'
        $gotId = ''; $gotDigest = ''
        if ($asset) { $gotId = $asset.Id; $gotDigest = $asset.Digest }
        $gotFail = ''
        if (-not $asset) { $gotFail = Get-AssetFailureFromScope $script:UpdateAssetScope }
        Assert-Eq ('资产契约 正文种类: ' + $cName) $cScope $script:UpdateAssetScope
        Assert-Eq ('资产契约 编号: ' + $cName) $cId $gotId
        Assert-Eq ('资产契约 校验值: ' + $cName) $cDigest $gotDigest
        Assert-Eq ('资产契约 失败原因: ' + $cName) $cFail $gotFail
        Write-Host ("contract {0} {1} {2} {3} {4}" -f $cName, $script:UpdateAssetScope, $gotId, $gotDigest, $gotFail)
        $contractSeen[$cName] = $true
    }
    Assert-Eq '资产契约 用例都跑到了' 20 $contractSeen.Count
} else {
    Write-Host '  SKIP 找不到 tests/asset-cases.txt（仓库内的用例文件）'
}

# ------------------------------------------------------------------------------
# [9] 监控进程的身份判据：看实质，不看启动方式的细节
# ------------------------------------------------------------------------------
# 判据是"命令行结尾跑的是本脚本、且没有子命令"。路径两侧的引号可有可无：
# 引号是启动方式决定的，不是身份的一部分。把引号当成条件会出这种事——
# 认不出已经跑着的监控，安装器就以为监控没在跑而起第二份，单实例锁又把第二份挡掉，
# 于是再也起不来监控，状态页还报"未运行"。
Assert-Eq '监控判据认得带引号的命令行' $true ('powershell.exe -NoProfile -File "D:\EnvProxy\win\envproxy.ps1"' -match $MonitorCmdLinePattern)
Assert-Eq '监控判据认得不带引号的命令行' $true ('powershell.exe -NoProfile -File D:\EnvProxy\win\envproxy.ps1' -match $MonitorCmdLinePattern)
Assert-Eq '监控判据认不得带子命令的进程' $false ('powershell.exe -File "D:\EnvProxy\win\envproxy.ps1" -Status' -match $MonitorCmdLinePattern)
Assert-Eq '监控判据认不得命令行中间提到脚本的进程' $false ('powershell.exe -Command "Get-Content D:\EnvProxy\win\envproxy.ps1"' -match $MonitorCmdLinePattern)

# ------------------------------------------------------------------------------
# [10] 快照归属判定：首次安装时，本机地址的代理变量是使用者自己的
# ------------------------------------------------------------------------------
# "像我们写的"不够——还要机器上本来就有本工具的安装记录，才可能是我们留下的。
# 首次安装时把使用者的手设变量当成我们的跳过，卸载时会被删掉又无从还原。
Assert-Eq '首次安装：本机地址的代理变量要快照' $false (Test-SnapshotSkip 'HTTP_PROXY' 'http://127.0.0.1:7890' $true)
Assert-Eq '首次安装：NODE_USE_ENV_PROXY=1 要快照' $false (Test-SnapshotSkip 'NODE_USE_ENV_PROXY' '1' $true)
Assert-Eq '重装：本机地址是我们上次写的，跳过' $true (Test-SnapshotSkip 'HTTPS_PROXY' 'http://127.0.0.1:7890' $false)
Assert-Eq '重装：NODE_USE_ENV_PROXY=1 是我们写的，跳过' $true (Test-SnapshotSkip 'NODE_USE_ENV_PROXY' '1' $false)
Assert-Eq '别人的代理地址从来不跳过' $false (Test-SnapshotSkip 'HTTP_PROXY' 'http://10.0.0.1:8080' $false)
Assert-Eq '空值不跳过' $false (Test-SnapshotSkip 'HTTP_PROXY' '' $false)

# ------------------------------------------------------------------------------
# [11] 注册表判断：文件系统那套对 HKCU:\ 永远说"不存在"
# ------------------------------------------------------------------------------
# 照着 Test-Item 判"键在不在"，已存在的键会被当成不存在，下一步 New-Item -Force 就把键
# 清空重建——连带删掉里面的用户原值快照。所以注册表一律用 Test-RegKey。
# 只有 Windows 有注册表：CI 的 ubuntu 作业也跑这一份，在那边这三条没有意义。
if ($env:OS -eq 'Windows_NT') {
    Assert-Eq '注册表判断：已存在的键判为存在' $true (Test-RegKey 'HKCU:\Software')
    Assert-Eq '注册表判断：不存在的键判为不存在' $false (Test-RegKey 'HKCU:\Software\EnvProxyNoSuchKey')
    Assert-Eq '文件系统判断对注册表路径返回假（所以注册表要用 Test-RegKey）' $false (Test-Item 'HKCU:\Software')
} else {
    Write-Host '  SKIP 注册表判断（本机没有注册表）'
}

# ------------------------------------------------------------------------------
# [12] 节点判定的双条件迟滞与自适应节流
# ------------------------------------------------------------------------------
# 判"断"要同时满足"次数"和"时长"。只数次数时，判据的时长是「次数 × 节流间隔」的乘积，
# 于是改节流（省流量）会直接变成判"断"的耗时——两件事被一个旋钮绑住，实测 3 × 15 秒
# 意味着"只断开"要等 50 秒。拆开后两种失败都要被拦住：
#   - 次数够、时间不够（短促抖动，问得再勤也不许下结论）
#   - 时间够、次数不够（一次失败间隔很久，不能只凭"时长"就判断）
Assert-Eq '双条件：3 次但只横跨 4 秒不判断' $false (Test-NodeVerdict 3 4 $NodeFailThreshold $NodeFailDwellSec)
Assert-Eq '双条件：2 次即使横跨 30 秒也不判断' $false (Test-NodeVerdict 2 30 $NodeFailThreshold $NodeFailDwellSec)
# 边界用常量推导，不写字面量：写死 10 / 9.9 等于把"dwell 必须恰好是 10"固化进用例，
# 以后正常调参（比如调到 20）会误报红，而这两条声称测的是"双条件"这个机制。
Assert-Eq '双条件：次数够且横跨恰好满 dwell 才判断' $true (Test-NodeVerdict $NodeFailThreshold $NodeFailDwellSec $NodeFailThreshold $NodeFailDwellSec)
Assert-Eq '双条件：差一点点也不行' $false (Test-NodeVerdict $NodeFailThreshold ($NodeFailDwellSec - 0.1) $NodeFailThreshold $NodeFailDwellSec)
Assert-Eq '双条件：次数差一次就不判断' $false (Test-NodeVerdict ($NodeFailThreshold - 1) ($NodeFailDwellSec * 3) $NodeFailThreshold $NodeFailDwellSec)
Assert-Eq '双条件：更多次、更久当然判断' $true (Test-NodeVerdict ($NodeFailThreshold + 2) ($NodeFailDwellSec * 4) $NodeFailThreshold $NodeFailDwellSec)

# 采样间隔跟着"有没有结论"走：稳定态省流量，正在收集证据和刚下结论时加密。
# 关键是最后两条：失败已达阈值（结论已定）时必须回到稳定档——只按"有没有失败"
# 决定间隔的话，节点一直死时计数会无界增长、间隔永远钉在快速档（实测 2.5 倍流量）。
$tNow = [datetime]::Now
$thr = $NodeFailThreshold
Assert-Eq '间隔：稳定态用稳定间隔' $NodeCheckThrottleSec (Get-NodeProbeInterval 0 $thr ([datetime]::MinValue) $tNow $NodeCheckThrottleSec $NodeFastSec)
Assert-Eq '间隔：有失败未达阈值时加密' $NodeFastSec (Get-NodeProbeInterval 1 $thr ([datetime]::MinValue) $tNow $NodeCheckThrottleSec $NodeFastSec)
Assert-Eq '间隔：刚下完结论时加密' $NodeFastSec (Get-NodeProbeInterval 0 $thr $tNow.AddSeconds(1) $tNow $NodeCheckThrottleSec $NodeFastSec)
Assert-Eq '间隔：加密窗口过了就回到稳定档' $NodeCheckThrottleSec (Get-NodeProbeInterval 0 $thr $tNow.AddSeconds(-1) $tNow $NodeCheckThrottleSec $NodeFastSec)
Assert-Eq '间隔：失败已达阈值（结论已定）回到稳定档' $NodeCheckThrottleSec (Get-NodeProbeInterval $thr $thr ([datetime]::MinValue) $tNow $NodeCheckThrottleSec $NodeFastSec)
Assert-Eq '间隔：失败远超阈值也仍是稳定档（计数不会让间隔永远快下去）' $NodeCheckThrottleSec (Get-NodeProbeInterval 999 $thr ([datetime]::MinValue) $tNow $NodeCheckThrottleSec $NodeFastSec)

# 常量自身的形状：加密必须比稳定快，否则"加密"没有意义；判据时长必须是可解释的小数秒。
if ($NodeFastSec -lt $NodeCheckThrottleSec) { Write-Host '  ok   加密间隔确实比稳定态快' } else { Write-Host '  FAIL 加密间隔不比稳定态快，加密没有意义'; $script:fails++ }
if ($NodeFailDwellSec -gt 0) { Write-Host '  ok   dwell 是正数' } else { Write-Host '  FAIL dwell 必须是正数'; $script:fails++ }

# "连续"失败必须先真的连续观测：端口槽位留着旧账时，旧失败起点会让跨度把中间整段
# 没观测的时间算进去，于是一回来就同时满足"≥N 次"和"≥dwell 秒"而当场判"断"——比契约激进。
# 这里直接驱动 Test-NodeAlive，钉住"闲置太久就丢弃旧起点"真的发生了。
$script:NodeState = @{}
$script:ProbeOk = $false
${function:Test-RealConnectivity} = { param([int]$p) return $script:ProbeOk }
[void](Test-NodeAlive 7078)                       # 先失败一次，建立失败起点
$slot = $script:NodeState['7078']
$slot.LastCheck = (Get-Date).AddMinutes(-10)      # 模拟这个端口很久没被探过
$slot.FirstFailAt = (Get-Date).AddMinutes(-10)
$slot.FailCount = 1
[void](Test-NodeAlive 7078)                       # 闲置之后再来一次失败
$span = ((Get-Date) - $script:NodeState['7078'].FirstFailAt).TotalSeconds
Assert-Eq '闲置太久的旧失败起点被丢弃（跨度从 0 重算，不是 600 秒）' $true ($span -lt 60)
Assert-Eq '闲置后失败计数从 1 重新算' 1 $script:NodeState['7078'].FailCount

# 加密观察窗只在**结论翻转**时开。若每次成功都重开，窗口永远不结束，稳态间隔就永远
# 走不到——实测会退化成每 5-6 秒一探，流量变成承诺值的 3 倍。钉住这个闭环：
$script:ProbeOk = $true
$script:NodeState = @{}
$script:NodeState['7078'] = @{ LastCheck = [datetime]::Now.AddSeconds(-20); Alive = $true
    FailCount = 0; FirstFailAt = [datetime]::MinValue; FastUntil = [datetime]::MinValue }
for ($i = 0; $i -lt 4; $i++) {
    [void](Test-NodeAlive 7078)
    $script:NodeState['7078'].LastCheck = (Get-Date).AddSeconds(-2)   # 模拟每轮 2 秒的节奏
}
Assert-Eq '连续成功时不会反复开窗（窗口保持过期，间隔才能回到稳态）' $true ($script:NodeState['7078'].FastUntil -eq [datetime]::MinValue)

$script:NodeState = @{}
$script:NodeState['7078'] = @{ LastCheck = [datetime]::Now.AddSeconds(-20); Alive = $false
    FailCount = 3; FirstFailAt = [datetime]::Now.AddSeconds(-30); FastUntil = [datetime]::MinValue }
[void](Test-NodeAlive 7078)                       # 断->通 翻转
Assert-Eq '断->通翻转后确实开窗' $true ($script:NodeState['7078'].FastUntil -gt (Get-Date))

# 换端口时新端口必须重新判定，不能沿用上一个端口的结论。
# Win 侧按端口分槽本来就不会串；这条挡的是"将来有人把分槽改成单槽"——
# Mac 侧单槽就是这么把死端口报成"通"的（写错变量的那一类）。
$script:NodeState = @{}
$script:ProbeOk = $true
[void](Test-NodeAlive 7078)                        # 7078 通
Assert-Eq '换端口前：7078 判为通' $true $script:NodeState['7078'].Alive
$script:ProbeOk = $false
$r7897 = Test-NodeAlive 7897                       # 换到死端口，非强制
Assert-Eq '换到死端口首次探测就判为断（不沿用上个端口的"通"）' $false $r7897
Assert-Eq '新端口的槽从零开始计数' 1 $script:NodeState['7897'].FailCount

# 抖动不累积：失败与成功交替时必须始终判"通"（一次成功即清零计数）。
# 轮间隔要落在"能真探到"（≥ 稳定档）与"不触发闲置清零"（< 闲置门槛）之间。
# 取 -30 秒会每轮撞上闲置清零，计数恒为 1、永远够不到阈值——那样这条用例测的是
# 闲置清零，而不是它声称的"抖动不累积"，把"成功即清零"删掉它照样绿。
$probeGap = [int](($NodeCheckThrottleSec + $NodeIdleResetSec) / 2)
$script:NodeState = @{}
$script:NodeState['7078'] = @{ LastCheck = [datetime]::MinValue; Alive = $true
    FailCount = 0; FirstFailAt = [datetime]::MinValue; FastUntil = [datetime]::MinValue }
$everDown = $false
$maxFails = 0
for ($i = 0; $i -lt 20; $i++) {
    $script:ProbeOk = ($i % 2 -eq 0)
    $script:NodeState['7078'].LastCheck = (Get-Date).AddSeconds(-$probeGap)
    if (-not (Test-NodeAlive 7078)) { $everDown = $true }
    if ($script:NodeState['7078'].FailCount -gt $maxFails) { $maxFails = $script:NodeState['7078'].FailCount }
}
Assert-Eq '失败/成功交替 20 轮里从不判"断"（抖动不累积）' $false $everDown
Assert-Eq '交替时失败计数最高只到 1（成功即清零，攒不起来）' 1 $maxFails

# 终端同步：$PROFILE 里的钩子块。核心是"只摘自己那一块、用户内容一字不动"，
# 以及"标记不配对时绝不猜"。沙箱里用两个临时文件当两个版本的 profile——
# Windows 5.1 与 7 的落点不同，两处都要写，这条正是要测的。
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
        Assert-Eq ("{0} 钩子块写入" -f $c.Name) $true ($txtAfter -match 'EnvProxy: 让已经开着的窗口')
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
$hookSBox = Join-Path ([System.IO.Path]::GetTempPath()) ("ep_hook_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $hookSBox -Force -ErrorAction SilentlyContinue | Out-Null
$hookFile = Join-Path $hookSBox 'hook.ps1'
[System.IO.File]::WriteAllLines($hookFile, (Get-ProfileBlockLines), (New-Object System.Text.UTF8Encoding($false)))
$savedEnv = @{}
foreach ($n in $ProxyVarNames) { $savedEnv[$n] = [Environment]::GetEnvironmentVariable($n, 'User') }
$savedOwnedExist = Test-Path $OwnedRegKey
# 直接写注册表，不走 [Environment]::SetEnvironmentVariable：后者每写一次都会等
# WM_SETTINGCHANGE 广播超时（实测 5 个变量约 26 秒），自检会卡到超时。
# 钩子读的就是注册表这一层，直接写它等价，而且更快。
function Set-RegValue([string]$Name, $Value) {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
    if ($null -eq $k) { return }
    if ($null -eq $Value) { try { $k.DeleteValue($Name, $false) } catch {} }
    else { $k.SetValue($Name, [string]$Value, [Microsoft.Win32.RegistryValueKind]::String) }
    $k.Close()
}
try {
    foreach ($n in $ProxyVarNames) { Set-RegValue $n $null }
    if (Test-Path $OwnedRegKey) { Remove-Item $OwnedRegKey -Recurse -Force }
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
    if (-not (Test-RegKey $OwnedRegKey)) { New-Item -Path $OwnedRegKey -Force | Out-Null }
    $ok = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\EnvProxy\Owned", $true)
    if ($ok) {
        $ok.SetValue('HTTP_PROXY',  'http://127.0.0.1:7078', [Microsoft.Win32.RegistryValueKind]::String)
        $ok.SetValue('HTTPS_PROXY', 'http://127.0.0.1:7078', [Microsoft.Win32.RegistryValueKind]::String)
        $ok.SetValue('ALL_PROXY',   'http://127.0.0.1:7078', [Microsoft.Win32.RegistryValueKind]::String)
        $ok.SetValue('NO_PROXY',    'localhost,127.0.0.1,::1', [Microsoft.Win32.RegistryValueKind]::String)
        $ok.SetValue('NODE_USE_ENV_PROXY', '1', [Microsoft.Win32.RegistryValueKind]::String)
        $ok.Close()
    }
    . $hookFile
    Assert-Eq '加载钩子后立刻注入' 'http://127.0.0.1:7078' $env:HTTPS_PROXY
    # 注意：不能用 "$null -ne $function:prompt" 判"包住了"——PowerShell 自带默认 prompt，
    # 那个表达式永远为真，把包装函数整行删掉也照样 PASS（实测如此）。
    # 真判据是我们自己的哨兵变量 + 真的调一次 prompt 看效果。
    Assert-Eq '包装标记已置位（这是回车生效的机制）' $true $global:__EnvProxyPromptWrapped
    Assert-Eq '原 prompt 已备份（用于链式调用）' $true ($null -ne $global:__EnvProxyPrevPrompt)

    # 真实路径：敲回车 = 宿主调用 prompt。这里手动调一次，走的是包装后的函数。
    foreach ($n in $ProxyVarNames) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
    $null = prompt
    Assert-Eq '敲回车（调 prompt）后拿到代理' 'http://127.0.0.1:7078' $env:HTTPS_PROXY

    # 代理关掉：monitor 清掉注册表里的值 -> 钩子把会话里"我们写过的"也清掉
    foreach ($n in $ProxyVarNames) { Set-RegValue $n $null }
    $null = prompt
    Assert-Eq '代理关掉后回到提示符恢复直连' '' "$env:HTTPS_PROXY"

    # 用户自己设的值必须保留（README 的承诺，也是契约里最容易被破坏的一条）
    $env:HTTPS_PROXY = 'http://corp-proxy:8080'
    $null = prompt
    Assert-Eq '用户自己的公司代理不被删' 'http://corp-proxy:8080' $env:HTTPS_PROXY

    $env:HTTPS_PROXY = 'http://127.0.0.1:8080'
    $null = prompt
    Assert-Eq '用户自己的本机地址不被删' 'http://127.0.0.1:8080' $env:HTTPS_PROXY

    # 逐窗口接管
    foreach ($n in $ProxyVarNames) { Set-RegValue $n $null }
    Set-RegValue 'HTTPS_PROXY' 'http://127.0.0.1:7078'
    Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue
    $null = prompt
    Assert-Eq '重新注入' 'http://127.0.0.1:7078' $env:HTTPS_PROXY
    $env:ENVPROXY_TERM = 'off'
    $null = prompt
    Assert-Eq '接管开关生效（固定直连）' '' "$env:HTTPS_PROXY"
    Remove-Item Env:ENVPROXY_TERM -ErrorAction SilentlyContinue
    $null = prompt
    Assert-Eq '放开接管开关后恢复自动' 'http://127.0.0.1:7078' $env:HTTPS_PROXY

    # 归属边界：这几条决定"会不会误删使用者自己的代理"，是最难事后补救的一类。
    # 钩子的判据只有两条：注册表有值就注入；没有值但当前值等于归属记录里记的那个就清除。
    # 所以每条用例都必须先把归属记录摆成真实状态，再只改被测的那一个维度——
    # 否则所有用例都会落进同一个"没有归属记录→什么都不做"的分支，断言再多条也是假的。
    $savedBakExist = Test-Path $PrevEnvRegKey
    Write-Host '[14b] 归属边界：什么时候可以清'

    # 造一份真实的归属记录，模拟"我们确实写过这些值"。
    function Set-OwnedRecord([string]$Value) {
        if (-not (Test-Path $OwnedRegKey)) { New-Item -Path $OwnedRegKey -Force -ErrorAction SilentlyContinue | Out-Null }
        $ok = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\EnvProxy\Owned", $true)
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
    Assert-Eq '值等于记录值：清除' '' "$env:HTTPS_PROXY"

    # (b) 有归属记录、但使用者改成了别的值 → 必须保住（不能按形状猜）
    $env:HTTPS_PROXY = 'http://corp-proxy:8080'
    $null = prompt
    Assert-Eq '值不等于记录值：保住公司代理' 'http://corp-proxy:8080' $env:HTTPS_PROXY

    # (c) 有归属记录、使用者改成另一个本机端口 → 同样必须保住
    $env:HTTPS_PROXY = 'http://127.0.0.1:9090'
    $null = prompt
    Assert-Eq '值不等于记录值：保住别的端口的本机代理' 'http://127.0.0.1:9090' $env:HTTPS_PROXY

    # (d) 没有归属记录 → 判不了，一个都不动
    if (Test-Path $OwnedRegKey) { Remove-Item $OwnedRegKey -Recurse -Force }
    $env:HTTPS_PROXY = 'http://127.0.0.1:7078'
    $null = prompt
    Assert-Eq '无归属记录时不动任何值（判不了就不猜）' 'http://127.0.0.1:7078' $env:HTTPS_PROXY

    # (e) 快照保护住在 env.ps1 的注册表清理路径里，不在钩子里——直接断言那个判据，
    #     不能拿钩子的行为冒充它（钩子根本不读快照）。
    Assert-Eq 'Test-IsOwnedProxyValue 是真实存在的判据' 'Function' (Get-Command Test-IsOwnedProxyValue -ErrorAction SilentlyContinue).CommandType

} finally {
    foreach ($n in $ProxyVarNames) { Set-RegValue $n $savedEnv[$n] }
    # 快照键：测试往 Backup 里种过值。原本就有的只删我们种的那一项；
    # 原本没有的整棵删掉——否则会在使用者机器上留一个空键。
    if (Test-Path $PrevEnvRegKey) {
        $bk2 = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\EnvProxy\Backup", $true)
        $emptyNow = $false
        if ($null -ne $bk2) {
            try { $bk2.DeleteValue('HTTPS_PROXY', $false) } catch {}
            $emptyNow = (@($bk2.GetValueNames()).Count -eq 0)
            $bk2.Close()
        }
        if ($emptyNow -and (-not $savedBakExist)) { Remove-Item $PrevEnvRegKey -Recurse -Force -ErrorAction SilentlyContinue }
    }
    # 归属记录：测试前没有就整棵删掉，别把 HKCU\Software\EnvProxy 留在用户机器上。
    if (-not $savedOwnedExist) {
        if (Test-Path $OwnedRegKey) { Remove-Item $OwnedRegKey -Recurse -Force -ErrorAction SilentlyContinue }
        # 只有它空了才删父键（父键可能装着真实的 ScriptPath）。
        if ((Test-Path $ScriptPathRegKey) -and -not (@(Get-ChildItem $ScriptPathRegKey -ErrorAction SilentlyContinue).Count)) {
            Remove-Item $ScriptPathRegKey -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($n in $ProxyVarNames) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
    Remove-Item Env:ENVPROXY_TERM -ErrorAction SilentlyContinue
    Remove-Item Env:__EnvProxyPromptWrapped -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $hookSBox -ErrorAction SilentlyContinue
}
}


# ------------------------------------------------------------------------------
# [20] 文档里印出来的每条命令都真能跑
# 这一节的理由：帮助和 README 里的命令是给用户「照抄」的。抄下来跑不通，
# 比不写更糟——用户会以为是自己敲错了。所以这里把每种终端的写法都真跑一遍，
# 断言的是「可观察的结果」，不是「字符串里有没有这个词」。
# 只验证不依赖网络、不改用户设置的那些：改完立刻复原。
# ------------------------------------------------------------------------------
Write-Host '[20] every documented command actually runs'

# PowerShell：固定直连 -> 复原
$env:ENVPROXY_TERM = 'off'
Assert-Eq 'PS: ENVPROXY_TERM becomes off' 'off' $env:ENVPROXY_TERM
Remove-Item Env:ENVPROXY_TERM -ErrorAction SilentlyContinue
Assert-Eq 'PS: Remove-Item clears it' $true ($null -eq $env:ENVPROXY_TERM)

# PowerShell：设了能读回来
$env:HTTPS_PROXY = 'http://1.2.3.4:8080'
Assert-Eq 'PS: corporate proxy reads back' 'http://1.2.3.4:8080' $env:HTTPS_PROXY
Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue

# curl 的别名差异：文档说 5.1 是别名、7 不是。这条钉住这个前提。
$curlKind = (Get-Command curl -ErrorAction SilentlyContinue).CommandType.ToString()
$is51 = ($PSVersionTable.PSVersion.Major -lt 6)
Assert-Eq 'curl kind matches what the docs claim for this version' $true (($is51 -and $curlKind -eq 'Alias') -or ((-not $is51) -and $curlKind -ne 'Alias'))

# cmd：清 5 个变量（一行写法）。用独立 cmd 进程，不碰本进程环境。
$cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
if (Test-Path -LiteralPath $cmdExe) {
    $script = (@('@echo off', 'set HTTPS_PROXY=http://b', 'set HTTP_PROXY=&set HTTPS_PROXY=&set ALL_PROXY=&set NO_PROXY=&set NODE_USE_ENV_PROXY=', 'if defined HTTPS_PROXY (echo LEFT) else (echo CLEARED)') -join "`r`n")
    $tmpCmd = Join-Path $env:TEMP ('ep_cmd_' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.cmd')
    [System.IO.File]::WriteAllText($tmpCmd, $script, (New-Object System.Text.ASCIIEncoding))
    $out = (& $cmdExe /c $tmpCmd) -join ' '
    Remove-Item -LiteralPath $tmpCmd -Force -ErrorAction SilentlyContinue
    Assert-Eq 'cmd: one-line clear really clears' $true ($out -match 'CLEARED')
}

# cmd 的坑：& 两边留空格会得到一个只含空格的值。文档专门警告过，这里钉住这个事实。
if (Test-Path -LiteralPath $cmdExe) {
    $tmpCmd2 = Join-Path $env:TEMP ('ep_cmd2_' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.cmd')
    $script2 = (@('@echo off', 'set SPACETEST=hello', 'set SPACETEST= & set OTHER=1', 'if "[%SPACETEST%]"=="[ ]" (echo HASTHE-SPACE) else (echo NO-SPACE)') -join "`r`n")
    [System.IO.File]::WriteAllText($tmpCmd2, $script2, (New-Object System.Text.ASCIIEncoding))
    $out2 = (& $cmdExe /c $tmpCmd2) -join ' '
    Remove-Item -LiteralPath $tmpCmd2 -Force -ErrorAction SilentlyContinue
    Assert-Eq 'cmd: the documented space trap is real' $true ($out2 -match 'HASTHE-SPACE')
}

# 文档里每条命令的「形状」也要对：只有 PowerShell 才用 $env:，只有 bash 才用 export。
$docText = (Format-HelpTopic '3')
Assert-Eq 'help gives a cmd form for pinning' $true ($docText -match 'set HTTP_PROXY=')
Assert-Eq 'help gives a bash form for pinning' $true ($docText -match 'unset HTTP_PROXY')
Assert-Eq 'help gives a PowerShell form for pinning' $true ($docText -match '\$env:ENVPROXY_TERM')
Assert-Eq 'help warns about the ampersand space trap' $true ($docText -match '空格')

# 状态页必须主动认下"变量指向的端口已经不在"这件事。
# 不认的话，终端里每条联网命令都会报 ECONNREFUSED 127.0.0.1:xxxx，
# 而错误信息里没有本工具的名字——用户（和帮他排查的 AI）会去查网络、防火墙、DNS，
# 唯独查不到这里。这条断言钉住那份"主动认错"的文案还在。
$statusSrc = (Get-Command Show-Status).Definition
Assert-Eq 'status page checks whether the injected port is still alive' $true ($statusSrc -match 'BeginConnect')
Assert-Eq 'status page names ECONNREFUSED as its own doing' $true ($statusSrc -match 'ECONNREFUSED')
Assert-Eq 'status page tells the reader what to do next' $true ($statusSrc -match '安装 / 修复')

# The coloured screen and the plain-text menu must take their group order from the
# SAME derived list. They once each had a hand-written array: a group typo then made
# an item invisible on screen while it stayed typeable -- the user sees one menu and
# can run another. Pin it structurally: no hand-written group array may reappear.
foreach ($fn in @('Show-MenuColored', 'Format-MenuText', 'Get-HelpMenuLines')) {
    $src = (Get-Command $fn).Definition
    Assert-Eq ($fn + ' derives its groups instead of listing them') $false ($src -match "@\('日常'")
    Assert-Eq ($fn + ' uses the shared group order') $true ($src -match 'Get-MenuGroups')
}
Assert-Eq 'the shared group order is the only place groups are ordered' 1 (([regex]::Matches((Get-Command Get-MenuGroups).Definition, 'Select-Object -Unique')).Count)

# Help topic 6 is a second copy of the menu table. If it is hand-written it goes
# stale silently, and the symptom is the worst kind: the user reads help, types the
# number it names, and gets a DIFFERENT action (wants check-for-updates, uninstalls).
# So it must be generated from $MenuItems, and this assertion proves it is: a fake
# menu entry must show up in the help screen with no other edit.
$helpMenuText = (Format-HelpTopic '6')
foreach ($mi in $MenuItems) {
    Assert-Eq ('help menu screen shows menu key ' + $mi.Key) $true ($helpMenuText -match ('(?m)^\s{2}' + [regex]::Escape($mi.Key) + '\s{2}'))
    Assert-Eq ('help menu screen names menu key ' + $mi.Key) $true ($helpMenuText -match [regex]::Escape($mi.Name))
}
# Mutation test: append a row to the table and confirm it appears on the help screen.
$fakeRow = @{ Key = '9'; Name = '假条目'; Switch = 'Status'; Group = '日常'; Hint = '这条只用于自检' }
$MenuItems = @($MenuItems) + $fakeRow
$helpMenuText2 = (Format-HelpTopic '6')
Assert-Eq 'the help menu screen is generated from the table' $true ($helpMenuText2 -match '假条目')
Assert-Eq 'a generated row keeps its hint' $true ($helpMenuText2 -match '这条只用于自检')
$MenuItems = @($MenuItems | Where-Object { $_.Key -ne '9' })

# ------------------------------------------------------------------------------
# [21] README 抄了一份菜单表和帮助目录，必须是代码的镜像
# 这一节的理由：README 不能引用代码，只能把菜单编号和帮助标题抄一份。这一份
# 一旦和代码脱节，后果比"文档旧了"严重：用户照 README 的编号去敲，敲到的是
# 另一件事（想检查更新，结果卸载了）。这类错误没人会当场发现——文档看着很正常。
# 所以这里把两份表逐行对回代码：名字必须一字不差（中文那份直接就是代码里的字符串），
# 编号顺序也必须一致。英文那份只比编号与行数，标题是另一种语言，比不了字面。
# ------------------------------------------------------------------------------
Write-Host '[21] README mirrors the menu and help tables'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
# 按表头认表，不按周围的散文认：散文措辞会改，表头是这张表自己的身份。
# $Headers 里任一命中即算这张表。取到表头后往下读到第一个空行为止。
function Get-TableByHeader([string[]]$Lines, [string[]]$Headers) {
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch '^\|') { continue }
        $cells = @($Lines[$i] -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        foreach ($h in $Headers) { if ($cells -contains $h) {
            $rows = @()
            for ($k = $i + 2; $k -lt $Lines.Count; $k++) {
                if ($Lines[$k] -notmatch '^\|') { break }
                $rows += $Lines[$k]
            }
            return $rows
        } }
    }
    return @()
}
foreach ($pair in @(@('README.md', $false), @('README.en.md', $true))) {
    $docPath = Join-Path $repoRoot $pair[0]
    if (-not (Test-Path -LiteralPath $docPath)) {
        Assert-Eq ($pair[0] + ' exists') $true $false
        continue
    }
    $docLines = [System.IO.File]::ReadAllLines($docPath, [System.Text.Encoding]::UTF8)
    $menuRows = @(Get-TableByHeader $docLines @('菜单项', 'Menu item'))
    $helpRows = @(Get-TableByHeader $docLines @('编号', 'No.'))
    $docMenuKeys = @($menuRows | ForEach-Object { [regex]::Match($_, '^\|\s*\*\*(\d)').Groups[1].Value } | Where-Object { $_ })
    $docHelpKeys = @($helpRows | ForEach-Object { [regex]::Match($_, '^\|\s*(\d)\s*\|').Groups[1].Value } | Where-Object { $_ })
    $codeMenuKeys = @($MenuItems | ForEach-Object { $_.Key })
    $codeHelpKeys = @(Get-HelpTopics | ForEach-Object { $_.Key })
    Assert-Eq ($pair[0] + ' menu table lists every menu key in code order') ($codeMenuKeys -join ',') ($docMenuKeys -join ',')
    Assert-Eq ($pair[0] + ' help table lists every help topic in code order') ($codeHelpKeys -join ',') ($docHelpKeys -join ',')
    # 编号对上了，还要对名字：编号和名字各自正确、但配错了对，照样把人指到另一个动作上。
    # 只有中文 README 能逐字比——它的名字就是代码里的同一个字符串。
    if ($pair[0] -eq 'README.md') {
        foreach ($mi in $MenuItems) {
            $want = '**' + $mi.Key + ' ' + $mi.Name + '**'
            Assert-Eq ('README names menu key ' + $mi.Key + ' as ' + $mi.Name) $true ([bool]($menuRows -match [regex]::Escape($want)))
        }
        foreach ($t in (Get-HelpTopics)) {
            $want = '| ' + $t.Key + ' | ' + $t.Title + ' |'
            Assert-Eq ('README names help topic ' + $t.Key + ' as ' + $t.Title) $true ([bool]($helpRows -match [regex]::Escape($want)))
        }
    }
}

if ($script:fails -eq 0) { Write-Host 'ALL PASS'; exit 0 }
Write-Host ("FAILURES: {0}" -f $script:fails); exit 1
