# EnvProxy Windows pure-function regression tests (no side effects, registry untouched).
# Run: pwsh tests/test-win-pure.ps1   (PowerShell 5.1 compatible, ASCII only)
$ErrorActionPreference = 'Stop'
$script:fails = 0
. (Join-Path $PSScriptRoot '../win/envproxy.ps1')

function Assert-Eq([string]$Name, $Want, $Have) {
    if ("$Want" -eq "$Have") { Write-Host ("  PASS {0}" -f $Name) }
    else { Write-Host ("  FAIL {0} (want [{1}] have [{2}])" -f $Name, $Want, $Have); $script:fails++ }
}

function Write-TestFile([string]$P, [string]$T) {
    [System.IO.File]::WriteAllText($P, $T)
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
$fake = Join-Path ([System.IO.Path]::GetTempPath()) ('envproxy_srctest_' + [Guid]::NewGuid().ToString('N'))
New-Item -Path $fake -ItemType Directory -Force | Out-Null
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

if ($script:fails -eq 0) { Write-Host 'ALL PASS'; exit 0 }
Write-Host ("FAILURES: {0}" -f $script:fails); exit 1
