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
Assert-EqCase 'a valid digest is taken' $digestOk ((Get-AssetFromJson $assetDigest 'EnvProxy-win.zip').Digest)
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
    Assert-Eq 'a rate limited version query is reported as a quota problem' 'quota' $script:VersionQueryFailure
} finally { Stop-OneShotServer $srv }
$srv = Start-OneShotServer 403 @{ 'X-RateLimit-Remaining' = '42' } '{"message":"Forbidden"}'
try {
    $null = Invoke-UpdateText "http://127.0.0.1:$($srv.Port)/repos/o/r/releases/latest"
    Assert-Eq 'a refused version query with quota left is reported as a server problem' 'server' $script:VersionQueryFailure
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
Assert-EqCase 'an uppercase digest is accepted and normalised' 'sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824' ((Get-AssetFromJson $assetDigestUpper 'EnvProxy-win.zip').Digest)
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
# 同样要成对还原：这个替身会真去扫端口的函数，后面的用例若"顺带"调它，
# 拿到的永远是 $null —— 而那正是"本机没有代理"这个假设，会让断言在不该过的场合过。
$__gapSaved = (Get-Item -Path Function:Get-ActiveProxyPort).ScriptBlock
try {
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
} finally {
    Set-Item -Path Function:Get-ActiveProxyPort -Value $__gapSaved
    Remove-Variable -Name __gapSaved -Scope Script -ErrorAction SilentlyContinue
}

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
# 接线：重试之后必须走挑选规则，不许把后一次的原因直接盖上去。
# 状态页的行结构：标签固定 key 色，内容按状态取角色。
#
# 为什么要有这条断言：原来状态页每一行把「标签 : 内容」整行套一个角色，
# 于是"代理变量 : 无（直连状态）"整行变灰，标签也跟着灰——用户最先看的恰恰是标签。
# 状态好的行整行绿、状态无的行整行灰，扫一眼只看到"有的绿有的灰"，分不清哪段是名字。
# 这条断言钉住"标签用 key"这个结构，改回整行同色就红。
# 状态页里每个标签都必须经 Write-StatusRow 输出（它会用 key 上色）。
# 标签值从 $StatusLabels 表取（唯一权威处），源码里查的是"用它做行标签"这件事：
#   ① 静态页必须出现 `Write-StatusRow $StatusLabels.X`；
#   ② 表里的每个键都必须真的被渲染器用到——只建表不接线等于没建。
$srcLive = Get-AllLibSource
foreach ($k in @('Monitor', 'AutoRun', 'Proxy', 'TermSync', 'Vars', 'Version')) {
    $lbl = [string]$StatusLabels[$k]
    $inRow = [regex]::IsMatch($srcLive, 'Write-StatusRow \$StatusLabels\.' + $k + '\b')
    $inBare = [regex]::IsMatch($srcLive, "Write-Styled '\w+' ""?" + [regex]::Escape($lbl) + " : ")
    Assert-Eq ('status row uses the split renderer: ' + $lbl) $true $inRow
    Assert-Eq ('status label is not painted by the whole-line colour: ' + $lbl) $false $inBare
    $used = [regex]::IsMatch($srcLive, '\$StatusLabels\.' + $k + '\b')
    Assert-Eq ('status label is actually used by a renderer: ' + $lbl) $true $used
}

# 回环判据：与 Mac 侧 is_loopback_url 同一张表、同一批结论（两侧各跑一遍，门禁 10 互比）。
Assert-Eq 'loopback url: http://127.0.0.1:7078' 'true' (Test-LoopbackUrl 'http://127.0.0.1:7078')
Assert-Eq 'loopback url: http://[::1]:7078' 'true' (Test-LoopbackUrl 'http://[::1]:7078')
Assert-Eq 'loopback url: http://localhost:8080/' 'true' (Test-LoopbackUrl 'http://localhost:8080/')
Assert-Eq 'loopback url: http://LOCALHOST:7890' 'true' (Test-LoopbackUrl 'http://LOCALHOST:7890')
Assert-Eq 'loopback url: http://127.0.0.2:7890' 'true' (Test-LoopbackUrl 'http://127.0.0.2:7890')
Assert-Eq 'loopback url: http://user:pw@localhost:7890' 'true' (Test-LoopbackUrl 'http://user:pw@localhost:7890')
Assert-Eq 'loopback url: https://api.github.com/repos/o/r' 'false' (Test-LoopbackUrl 'https://api.github.com/repos/o/r')
Assert-Eq 'loopback url: http://192.168.1.5:7078/' 'false' (Test-LoopbackUrl 'http://192.168.1.5:7078/')
Assert-Eq 'loopback url: http://[2001:db8::1]:8080/' 'false' (Test-LoopbackUrl 'http://[2001:db8::1]:8080/')
Assert-Eq 'loopback url: http://localhost.:7890' 'false' (Test-LoopbackUrl 'http://localhost.:7890')

# 代理地址归一化：启动器要用它把"用户能填出的各种写法"变成一个能放进环境变量的值。
# 这里钉住的每一条都是真实可能出现的输入：注册表里我们自己写的（规范）、
# 用户手填的（可能少协议、多空格、带末尾斜杠、带账号密码）。
Assert-Eq 'proxy url: 规范写法原样保留' 'http://127.0.0.1:7078' (ConvertTo-ProxyUrl 'http://127.0.0.1:7078')
Assert-Eq 'proxy url: 去首尾空白' 'http://127.0.0.1:7078' (ConvertTo-ProxyUrl '  http://127.0.0.1:7078  ')
Assert-Eq 'proxy url: 去末尾斜杠' 'http://127.0.0.1:7078' (ConvertTo-ProxyUrl 'http://127.0.0.1:7078/')
Assert-Eq 'proxy url: 少写协议时补 http' 'http://127.0.0.1:7078' (ConvertTo-ProxyUrl '127.0.0.1:7078')
Assert-Eq 'proxy url: IPv6 方括号保留' 'http://[::1]:7078' (ConvertTo-ProxyUrl 'http://[::1]:7078')
Assert-Eq 'proxy url: IPv6 少协议也补' 'http://[::1]:7078' (ConvertTo-ProxyUrl '[::1]:7078')
Assert-Eq 'proxy url: socks5 保留协议' 'socks5://127.0.0.1:1080' (ConvertTo-ProxyUrl 'socks5://127.0.0.1:1080')
# 账号密码里出现 ! 和 % 时不能被吞：cmd 的延迟展开会把 ! 吃掉，这里不能重犯。
Assert-Eq 'proxy url: 密码含 ! 不被吞' 'http://user:pa!ss@127.0.0.1:7078' (ConvertTo-ProxyUrl 'http://user:pa!ss@127.0.0.1:7078')
Assert-Eq 'proxy url: 密码含 %40 不被吞' 'http://user:p%40ss@127.0.0.1:7078' (ConvertTo-ProxyUrl 'http://user:p%40ss@127.0.0.1:7078')
Assert-Eq 'proxy url: 空串返回 null' 'true' ($null -eq (ConvertTo-ProxyUrl ''))
Assert-Eq 'proxy url: 纯空白返回 null' 'true' ($null -eq (ConvertTo-ProxyUrl '   '))
# 这两条防的是 Uri 的默认端口陷阱：它会替 "http://127.0.0.1" 补出 Port=80，
# 看起来"有端口"，其实用户没写端口——那种值放进环境变量全是连不上。
Assert-Eq 'proxy url: 没写端口返回 null' 'true' ($null -eq (ConvertTo-ProxyUrl 'http://127.0.0.1'))
Assert-Eq 'proxy url: 显式 :80 也算默认端口' 'true' ($null -eq (ConvertTo-ProxyUrl 'http://127.0.0.1:80'))
Assert-Eq 'proxy url: 非主机名返回 null' 'true' ($null -eq (ConvertTo-ProxyUrl '不是地址'))
Assert-Eq 'proxy url: 不支持的协议返回 null' 'true' ($null -eq (ConvertTo-ProxyUrl 'ftp://127.0.0.1:21'))


# 「这个快捷方式是不是我们建的」判据：只认 launchers 目录**里面**的 .vbs。
#
# 这一组防的是误删用户文件：判据曾用子串包含，于是 launchers2 / launchersX
# 这类同级目录里的 .vbs 也被当成我们的，卸载时连同用户的快捷方式一起删掉。
# 判得宽比判得严危险得多——判严只是留下自己的垃圾，判宽是动别人的东西。
#
# 断言直接打在生产函数 Test-ProxyShortcutArgsOurs 上，不在这里另写一份副本：
# 副本会让这组用例失去意义——生产那份改了、写歪了、退回子串包含了，
# 测副本的断言照样全绿，测试发现不了被测对象的变化。
$launcherRoot = [System.IO.Path]::GetFullPath((Get-ProxyLauncherDir)).TrimEnd('\')
# 必须认成我们的（否则卸载删不掉自己的东西）
Assert-Eq 'shortcut ours: 目录内的 vbs' 'true' (Test-ProxyShortcutArgsOurs ('"' + $launcherRoot + '\app_1234abcd.vbs"'))
Assert-Eq 'shortcut ours: 不带引号也算' 'true' (Test-ProxyShortcutArgsOurs ($launcherRoot + '\app_1234abcd.vbs'))
Assert-Eq 'shortcut ours: 中文文件名也算' 'true' (Test-ProxyShortcutArgsOurs ('"' + $launcherRoot + '\中文_aabb.vbs"'))
# 绝不能认成我们的（否则删掉用户的东西）
Assert-Eq 'shortcut not ours: launchers2 同级目录' 'false' (Test-ProxyShortcutArgsOurs ('"' + $launcherRoot + '2\mine.vbs"'))
Assert-Eq 'shortcut not ours: launchersX 同级目录' 'false' (Test-ProxyShortcutArgsOurs ('"' + $launcherRoot + 'X\user.vbs"'))
Assert-Eq 'shortcut not ours: 用 .. 绕出去' 'false' (Test-ProxyShortcutArgsOurs ('"' + $launcherRoot + '\..\backup\user.vbs"'))
Assert-Eq 'shortcut not ours: 桌面上的用户脚本' 'false' (Test-ProxyShortcutArgsOurs '"C:\Users\X\Desktop\mine.vbs"')
Assert-Eq 'shortcut not ours: 不是 vbs' 'false' (Test-ProxyShortcutArgsOurs ('"' + $launcherRoot + '\a.exe"'))
Assert-Eq 'shortcut not ours: 空参数' 'false' (Test-ProxyShortcutArgsOurs '')
Assert-Eq 'shortcut not ours: 只有一个引号' 'false' (Test-ProxyShortcutArgsOurs '"')

# 启动脚本要记住自己服务的是哪个程序。
#
# 为什么要测：脚本文件名是「程序名_哈希」，哈希那段对人没有意义。图标被删掉
# 或挪到别处之后，launchers 目录里只剩脚本，管理页只能显示一个像
# app_aabbccdd 的名字——用户看不出这是哪个程序的、该不该删。
# 程序路径本身只存在压缩过的命令里（base64），外面读不出来，所以另留一行可读记录。
#
# 记录必须写成十六进制而不是原文：脚本文件要保持纯 ASCII，
# 直接写中文路径会让某些旧版 WSH 读错文件、整个快捷方式失效。
$tgtSbox = Join-Path ([System.IO.Path]::GetTempPath()) ("epsbx_tgt_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tgtSbox -Force | Out-Null
try {
    $cnDir = Join-Path $tgtSbox '中文 目录 (测试)'
    New-Item -ItemType Directory -Path $cnDir -Force | Out-Null
    $cnApp = Join-Path $cnDir '我的 程序.exe'
    [System.IO.File]::WriteAllText($cnApp, 'x', [System.Text.Encoding]::ASCII)

    $encBody = Compress-ToBase64 'echo test'
    $vbsText = New-ProxyLauncherVbs $encBody $cnApp
    Assert-Eq 'launcher remembers its target: 有记录行' 'true' ($vbsText -match 'envproxy-target-hex:')
    Assert-Eq 'launcher remembers its target: 正文是纯 ASCII' 'true' (-not ($vbsText.ToCharArray() | Where-Object { [int]$_ -gt 127 }))

    $vbsFile = Join-Path $tgtSbox 'probe.vbs'
    [System.IO.File]::WriteAllText($vbsFile, $vbsText, [System.Text.Encoding]::ASCII)
    Assert-Eq 'launcher target round-trips: 中文路径 + 空格 + 括号' $cnApp (Get-ProxyLauncherTarget $vbsFile)
    Assert-Eq 'launcher target: 不存在的文件返回空' '' (Get-ProxyLauncherTarget (Join-Path $tgtSbox 'nope.vbs'))
    Assert-Eq 'launcher target: 空路径返回空' '' (Get-ProxyLauncherTarget '')
    # 旧版本建的脚本没有这一行，读不出来要返回空而不是报错
    $oldVbs = Join-Path $tgtSbox 'old.vbs'
    [System.IO.File]::WriteAllText($oldVbs, 'CreateObject("WScript.Shell").Run "cmd.exe", 0, False' + "`r`n", [System.Text.Encoding]::ASCII)
    Assert-Eq 'launcher target: 旧脚本（没有记录行）返回空' '' (Get-ProxyLauncherTarget $oldVbs)
    # 记录行被写坏时也不能抛异常
    $badVbs = Join-Path $tgtSbox 'bad.vbs'
    [System.IO.File]::WriteAllText($badVbs, "' envproxy-target-hex: zzz" + "`r`n", [System.Text.Encoding]::ASCII)
    Assert-Eq 'launcher target: 坏 hex 返回空' '' (Get-ProxyLauncherTarget $badVbs)
} finally {
    Remove-Item -LiteralPath $tgtSbox -Recurse -Force -ErrorAction SilentlyContinue
}

# 程序候选的排除规则：决定"扫出来那三四十个程序里，哪些不该出现"。
#
# 这张表看起来只是文案，其实每条都对应一个真实存在的噪音源：开始菜单里混着
# 卸载器、帮助文档、Python 自带的开发工具，全列出来用户得在两屏垃圾里找自己要的。
# 而判错的代价不对称：多排除一个，用户要手动输路径（麻烦）；少排除一个，
# 他要多读几行（也有代价但小得多）——所以规则宁可稍严，但绝不能误伤真程序。
# 最典型的一条：'notepad' 要排掉，而 'Notepad++' 必须留下（它是用户真会用的编辑器），
# 这要求英文词按整词匹配、中文词按包含匹配（中文没有词边界）。
Assert-Eq 'scan exclude: notepad 排除' 'true' (Test-ProxyScanExcluded 'notepad')
Assert-Eq 'scan exclude: Notepad++ 保留' 'false' (Test-ProxyScanExcluded 'Notepad++')
Assert-Eq 'scan exclude: 卸载xxx 排除' 'true' (Test-ProxyScanExcluded '卸载 Antigravity')
Assert-Eq 'scan exclude: 用户帮助 排除' 'true' (Test-ProxyScanExcluded '用户帮助')
Assert-Eq 'scan exclude: 使用说明 排除' 'true' (Test-ProxyScanExcluded '使用说明')
Assert-Eq 'scan exclude: README 排除' 'true' (Test-ProxyScanExcluded 'README')
# 文档类噪音：开始菜单里「用户手册」「新手教程」这类快捷方式指向的是帮助文档，
# 建一个「走代理启动帮助文档」的图标对谁都没用。中文没有词边界，只能靠包含匹配。
Assert-Eq 'scan exclude: 用户手册 排除' 'true' (Test-ProxyScanExcluded '用户手册')
Assert-Eq 'scan exclude: 使用文档 排除' 'true' (Test-ProxyScanExcluded '使用文档')
Assert-Eq 'scan exclude: 新手教程 排除' 'true' (Test-ProxyScanExcluded '新手教程')
Assert-Eq 'scan exclude: 配置指南 排除' 'true' (Test-ProxyScanExcluded '配置指南')
Assert-Eq 'scan exclude: unins000 排除' 'true' (Test-ProxyScanExcluded 'unins000')
Assert-Eq 'scan exclude: cmd 排除' 'true' (Test-ProxyScanExcluded 'cmd')
Assert-Eq 'scan exclude: 此电脑 排除' 'true' (Test-ProxyScanExcluded '此电脑')
Assert-Eq 'scan exclude: Antigravity 保留' 'false' (Test-ProxyScanExcluded 'Antigravity')
Assert-Eq 'scan exclude: 豆包 保留' 'false' (Test-ProxyScanExcluded '豆包')
Assert-Eq 'scan exclude: Visual Studio Code 保留' 'false' (Test-ProxyScanExcluded 'Visual Studio Code')
# 「xxx 快捷方式」要剥掉后缀再判：剥掉之后 '卸载 快捷方式' 仍是噪音
Assert-Eq 'scan exclude: 名字带"快捷方式"后缀也能判' 'true' (Test-ProxyScanExcluded '卸载 快捷方式')
Assert-Eq 'scan exclude: 空名字排除' 'true' (Test-ProxyScanExcluded '')

# 路径级排除：挡住"系统目录里的工具"，名字判据挡不住这些。
#
# 这一段测的是**与宿主平台无关**：判据不能依赖只在一个平台上才成立的东西。
# 已经踩过两个坑，都是"本机绿、CI 红"：
#   ① 只看 `$env:SystemRoot` 判系统目录——那个变量在 Linux 上是空的；
#   ② 用 `[System.IO.Path]::GetFileNameWithoutExtension` 取文件名——它按宿主平台
#      的规则认分隔符，Linux 只认正斜杠，于是 `C:\App\unins000.exe` 在 CI 上
#      被当成"整串文件名"，`unins*` 判断恒为假。
# 这类断言比没有断言更糟：它教人习惯性忽略红灯。所以下面显式把它们锁住。
Assert-Eq 'scan exclude path: System32 里的排除' 'true' (Test-ProxyScanExcludedPath 'C:\Windows\System32\regedit.exe')
Assert-Eq 'scan exclude path: SysWOW64 里的排除' 'true' (Test-ProxyScanExcludedPath 'C:\Windows\SysWOW64\cmd.exe')
# 抹掉 SystemRoot 之后仍然要挡得住（这正是 CI 上跑的那种情况）
$__sr = $env:SystemRoot
try {
    $env:SystemRoot = $null
    Assert-Eq 'scan exclude path: 无 SystemRoot 也挡 System32' 'true' (Test-ProxyScanExcludedPath 'C:\Windows\System32\regedit.exe')
    Assert-Eq 'scan exclude path: 无 SystemRoot 也挡 SysWOW64' 'true' (Test-ProxyScanExcludedPath 'C:\Windows\SysWOW64\cmd.exe')
    Assert-Eq 'scan exclude path: 无 SystemRoot 不误伤普通程序' 'false' (Test-ProxyScanExcludedPath 'D:\Doubao\Doubao.exe')
    # 反斜杠路径里的卸载器：取文件名不能靠 Path API（Linux 上切不出来）
    Assert-Eq 'scan exclude path: 无 SystemRoot 也认反斜杠里的 unins' 'true' (Test-ProxyScanExcludedPath 'C:\Program Files\App\unins000.exe')
    Assert-Eq 'scan exclude path: 无 SystemRoot 也认反斜杠里的 uninstall' 'true' (Test-ProxyScanExcludedPath 'C:\Program Files\App\Uninstall.exe')
} finally {
    $env:SystemRoot = $__sr
}
# 两种分隔符都要认（同一个程序的写法可能来自不同来源）
Assert-Eq 'scan exclude path: 正斜杠路径也认卸载器' 'true' (Test-ProxyScanExcludedPath 'C:/Program Files/App/unins000.exe')
Assert-Eq 'scan exclude path: 裸文件名也认卸载器' 'true' (Test-ProxyScanExcludedPath 'unins000.exe')
Assert-Eq 'scan exclude path: 卸载器排除' 'true' (Test-ProxyScanExcludedPath 'C:\Program Files\App\unins000.exe')
Assert-Eq 'scan exclude path: Uninstall 排除' 'true' (Test-ProxyScanExcludedPath 'C:\Program Files\App\Uninstall.exe')
Assert-Eq 'scan exclude path: 普通程序保留' 'false' (Test-ProxyScanExcludedPath 'C:\Users\X\AppData\Local\Programs\antigravity\Antigravity.exe')
Assert-Eq 'scan exclude path: D 盘程序保留' 'false' (Test-ProxyScanExcludedPath 'D:\Doubao\Doubao.exe')
Assert-Eq 'scan exclude path: 空路径排除' 'true' (Test-ProxyScanExcludedPath '')

#
# 这条防的是一个真实发生过的 bug：挑选函数与它的断言都在，但调用方
# 直接 `$script:VersionQueryFailure = $t2.Failure`，绕过了整个规则。
# 于是"第一次 quota（配额用尽，等一小时）、重试后 server（对方故障）"时报了 server——
# 用户照着等一会儿，怎么等都没用。
# 断言测函数怎么挑，测不出"没人调它"；只能读源码看调用点。
$uSrc = [System.IO.File]::ReadAllText((Join-Path (Get-Location) 'win/lib/update.ps1'))
$iFn = $uSrc.IndexOf('function Invoke-UpdateText(')
Assert-Eq '接线：Invoke-UpdateText 找到了' $true ($iFn -ge 0)
if ($iFn -ge 0) {
    $uBody = $uSrc.Substring($iFn, [Math]::Min(1400, $uSrc.Length - $iFn))
    Assert-Eq '接线：重试路径把两次原因都交给挑选规则' $true ($uBody -match 'Select-UpdateFailureKind')
    # 反面：不许出现 "= $t2.Failure" 这种直接覆盖。
    Assert-Eq '接线：重试路径不直接覆盖失败原因' $false ([regex]::IsMatch($uBody, 'VersionQueryFailure\s*=\s*\$t2\.Failure'))
}
# The advice must name the action, otherwise the user still has to guess.
$msgMissing = Get-UpdateFailureMessage 'missing' 'GitHub'
$msgQuota = Get-UpdateFailureMessage 'quota' 'GitHub'
$msgNet = Get-UpdateFailureMessage 'network' 'GitHub'
$msgLocal = Get-UpdateFailureMessage 'local' 'GitHub'
Assert-Eq 'the missing-file advice points at manual download' '1' ([int]($msgMissing -match '手动下载'))
Assert-Eq 'the quota advice says it clears with time' '1' ([int]($msgQuota -match '一小时|重试'))
Assert-Eq 'the network advice gives a next step' '1' ([int]($msgNet -match '重试'))
Assert-Eq 'the local advice points at the disk' '1' ([int]($msgLocal -match '磁盘|权限'))
$advices = @('missing', 'quota', 'server', 'network', 'bad-content', 'local') | ForEach-Object { Get-UpdateFailureMessage $_ 'GitHub' }
Assert-Eq 'no advice claims success' '0' (@($advices | Where-Object { $_ -match '成功' }).Count)

Write-Host '[7a2] retry with another exit IP'

# 失败以后要不要"换个出口 IP 再试一次"，判据只有一条：这个失败是不是由出口决定的。
# 把它钉住，是因为判错的代价不对称：
#   - 该换却不换（quota）：只能去走更慢的兜底路。实测直连出口配额用尽时，
#     同地址经本机代理 468ms 就 200，而网页兜底要 8.7 秒。
#   - 不该换却换（missing/server）：白等一轮，还把真实原因盖成别的原因。
# 这两种都是"看起来能跑、其实慢或误导"的坏法，只有断言看得见。
foreach ($k in @('network', 'quota')) {
    Assert-Eq ('the ' + $k + ' failure is worth retrying on another exit') '1' ([int](Test-RetryWithProxy $k))
}
foreach ($k in @('server', 'missing', 'bad-content', 'local', '')) {
    Assert-Eq ('the ' + $k + ' failure is not retried on another exit') '0' ([int](Test-RetryWithProxy $k))
}
# 空原因（一次都没失败过）也不能触发重试。
Assert-Eq 'no failure means no retry' '0' ([int](Test-RetryWithProxy $null))
