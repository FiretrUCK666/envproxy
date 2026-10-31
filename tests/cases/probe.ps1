Write-Host '[3] closed ports'
Assert-Eq 'single closed is not proxy' $false (Test-HttpProxy 9)

    # ---- 正向覆盖：判决三层的前两层必须真的能被认出来 ----
    # 这一段是补历史欠账：原来 Test-HttpProxy / Test-EndpointStatus 只有否定断言
    #（关闭的端口不是代理），没有任何一条说真代理要认得出来。
    # 后果是这两个函数可以被改成恒返回 $false 而全部门禁全绿——
    # 那等于工具在最核心的功能上彻底失效，用户只会看到检测不到代理。
    # 假服务器返回的是 @{Port=...; Ps=...; Rs=...}，用 $srv.Port 取端口、用 Stop-OneShotServer 收尾。
    $realProxy = Start-OneShotServer 200 @{} ''
    try {
        Assert-Eq 'a real CONNECT proxy is recognised' $true (Test-HttpProxy $realProxy.Port)
        $batchHit = Test-HttpProxyBatch @($realProxy.Port)
        Assert-Eq 'the batch path finds the same proxy' ([string]$realProxy.Port) ([string]$batchHit)
    } finally { Stop-OneShotServer $realProxy }
    $refusing = Start-OneShotServer 403 @{} 'no'
    try {
        Assert-Eq 'a proxy that refuses is not accepted' $false (Test-HttpProxy $refusing.Port)
    } finally { Stop-OneShotServer $refusing }

    # 端点判据的三态：204 类只认 204，3xx 类只认 3xx。
    # 这两条曾在两侧都没有任何断言——把 204 放宽成 200..399 会全绿，
    # 而那正好放进强制门户返回 200 登录页这个最该挡的场景。
    Assert-Eq 'endpoint 204 accepts 204' $true (Test-EndpointStatus 204 '204')
    Assert-Eq 'endpoint 204 rejects 200 (captive portal)' $false (Test-EndpointStatus 200 '204')
    Assert-Eq 'endpoint 204 rejects 302' $false (Test-EndpointStatus 302 '204')
    Assert-Eq 'endpoint 3xx accepts 301' $true (Test-EndpointStatus 301 '3xx')
    Assert-Eq 'endpoint 3xx rejects 204' $false (Test-EndpointStatus 204 '3xx')
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

