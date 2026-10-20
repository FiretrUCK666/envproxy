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

if ($script:fails -eq 0) { Write-Host 'ALL PASS'; exit 0 }
Write-Host ("FAILURES: {0}" -f $script:fails); exit 1
