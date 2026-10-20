# EnvProxy Windows pure-function regression tests (no side effects, registry untouched).
# Run: pwsh tests/test-win-pure.ps1   (PowerShell 5.1 compatible, ASCII only)
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

# A one-shot local HTTP server, used to exercise the real network paths (a redirect, a rate
# limit) without touching the network. It answers exactly one request and then stops: a listener
# loop would keep the test process alive after the test itself is done.
function Start-OneShotServer([int]$Status, [hashtable]$Headers, [string]$Body) {
    $port = 18000 + (Get-Random -Maximum 2000)
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
            # Bounded wait: if the client never shows up, give up instead of blocking the run.
            # AcceptTcpClientAsync, not Socket.Poll -- on Windows a listening socket does not
            # report a pending connection through Poll, so Poll would only time out.
            $accept = $tcp.AcceptTcpClientAsync()
            if (-not $accept.Wait(20000)) { return }
            $client = $accept.Result
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
            $client.Close()
        } catch {}
        $tcp.Stop()
    }).AddArgument($port).AddArgument($Status).AddArgument($Headers).AddArgument($Body)
    $null = $ps.BeginInvoke()
    Start-Sleep -Milliseconds 600
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
Assert-Eq 'copy is byte exact' ((Get-FileHash -LiteralPath $src5 -Algorithm SHA256).Hash) ((Get-FileHash -LiteralPath $dst5 -Algorithm SHA256).Hash)
Assert-Eq 'copy keeps the BOM' 'EF-BB-BF' (([BitConverter]::ToString([System.IO.File]::ReadAllBytes($dst5)[0..2])))
[System.IO.File]::WriteAllText($src5, "Write-Host 'two'`n", (New-Object System.Text.UTF8Encoding($false)))
Copy-FileAtomic $src5 $dst5
Assert-Eq 'overwrite replaces content exactly' ((Get-FileHash -LiteralPath $src5 -Algorithm SHA256).Hash) ((Get-FileHash -LiteralPath $dst5 -Algorithm SHA256).Hash)
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

Write-Host '[11] the menu dispatch table'
# The menu maps numbers to existing entry switches; the shells call back through these
# switches, so every number must resolve and every switch must exist. Names are checked
# as data (keys and switch words only): this file stays ASCII-only on purpose.
$menuKeys = @($MenuItems | ForEach-Object { $_.Key })
Assert-Eq 'menu has six entries' 6 $menuKeys.Count
foreach ($k in @('1', '2', '3', '4', '5', '0')) { Assert-Eq ('menu has key ' + $k) $true ($menuKeys -contains $k) }
$menuSwitches = @($MenuItems | Where-Object { $_.Switch } | ForEach-Object { $_.Switch })
foreach ($sw in @('Install', 'Status', 'Stop', 'Uninstall', 'Update')) { Assert-Eq ('menu covers -' + $sw) $true ($menuSwitches -contains $sw) }

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
$digestReal = 'sha256:' + (Get-FileHash -Path $digestFile -Algorithm SHA256).Hash.ToLower()
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
Assert-Eq 'an asset lookup that cannot reach the API reports a network problem' 'network' (Get-UpdateAsset $remoteForAsset 'EnvProxy-win.zip').Failure
Assert-Eq 'the placeholder expands into the repo id' 'https://api.github.com/repos/owner/repo/releases/latest' ($UpdateSourceTable[0].Api).Replace('@@', 'owner/repo')
# No source may come back with an empty repo id: the walker would build a URL with a hole where the
# id goes, and the fetch would fail in a way that looks like a network problem.
# Count is taken straight off the returned value, never wrapped in @(): Get-UpdateSources returns
# ,$out to force an array, and @(...) around a call collapses that into "one element".
Assert-Eq 'no source comes back with an empty repo id' '0' (@($srcTable0 | Where-Object { -not $_.Repo }).Count)
Assert-Eq 'every exported source carries its five walker fields' '0' (@($srcTable0 | Where-Object { -not $_.Api -or -not $_.Web -or -not $_.Base -or -not $_.Preferred -or -not $_.ApiRepo }).Count)

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
foreach ($bad in @('-Foo', '-Installt', 'extra')) {
    $rc = 0
    $ps = Start-Process -FilePath (Get-Process -Id $PID).Path -PassThru -NoNewWindow -Wait `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$entryPath`"", $bad)
    $rc = $ps.ExitCode
    Assert-Eq ("入口拒绝不认识的参数: " + $bad) 2 $rc
}

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
# 行为层面才看得出来（曾经就漂过：同一个应答，一边更新、一边说"没提供安装包"）。
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
    Assert-Eq '资产契约 用例都跑到了' 17 $contractSeen.Count
} else {
    Write-Host '  SKIP 找不到 tests/asset-cases.txt（仓库内的用例文件）'
}

if ($script:fails -eq 0) { Write-Host 'ALL PASS'; exit 0 }
Write-Host ("FAILURES: {0}" -f $script:fails); exit 1
