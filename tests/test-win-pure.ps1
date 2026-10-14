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

Write-Host '[2] ownership convention'
Assert-Eq 'local counts as ours' $true ('http://127.0.0.1:7890' -like 'http://127.0.0.1:*')
Assert-Eq 'corp does not' $false ('http://corp:8080' -like 'http://127.0.0.1:*')

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
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\envproxy.ps1'), '# entry', $bomEnc)
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\base.ps1'), '# lib', $bomEnc)
[System.IO.File]::WriteAllText((Join-Path $pkg 'mac\envproxy.sh'), "#!/bin/bash`n", $plainEnc)
$threw = $false
try { Test-Package $pkg '9.9.9' } catch { $threw = $true }
Assert-Eq 'a well-formed package is accepted' $false $threw
Assert-Throws 'version mismatch is rejected' { Test-Package $pkg '1.2.3' }
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\base.ps1'), '# lib', $plainEnc)
Assert-Throws 'a library without BOM is rejected' { Test-Package $pkg '9.9.9' }
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\base.ps1'), '# lib', $bomEnc)
[System.IO.File]::WriteAllText((Join-Path $pkg 'mac\envproxy.sh'), "#!`r`n", $plainEnc)
Assert-Throws 'a CRLF shell script is rejected' { Test-Package $pkg '9.9.9' }
[System.IO.File]::WriteAllText((Join-Path $pkg 'mac\envproxy.sh'), "#!/bin/bash`n", $plainEnc)
Remove-Item -LiteralPath (Join-Path $pkg 'mac\envproxy.sh') -Force
Assert-Throws 'a missing platform entry is rejected' { Test-Package $pkg '9.9.9' }
[System.IO.File]::WriteAllText((Join-Path $pkg 'mac\envproxy.sh'), "#!/bin/bash`n", $plainEnc)
[System.IO.File]::WriteAllText((Join-Path $pkg 'win\lib\empty.ps1'), '', $bomEnc)
Assert-Throws 'an empty script is rejected' { Test-Package $pkg '9.9.9' }
Remove-Item -LiteralPath $pkg -Recurse -Force

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

Write-Host '[10] judging a finished install'
# The updater decides the finish step worked by reading the install root's pid file, never by the
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

if ($script:fails -eq 0) { Write-Host 'ALL PASS'; exit 0 }
Write-Host ("FAILURES: {0}" -f $script:fails); exit 1
