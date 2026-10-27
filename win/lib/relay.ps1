# ==============================================================================
#  relay.ps1 — 固定入口：给「走代理的快捷方式」一个永不改变的地址
#
#  为什么单独成一个库：它要做的事（在内存里编译一个转发器、开监听、双向泵数据）
#  与"探测有没有代理"完全是两件事。留在 probe 里会让探测层多一份网络服务的职责，
#  也让这一块难以单独验证。依赖只有 base（常量、屏幕输出、路径助手）。
#
#  ------------------------------------------------------------------------------
#  它解决的问题
# ------------------------------------------------------------------------------
#  翻墙软件的本地端口会变：换软件、重启后随机端口、端口被占用时自动顺延。
#  而某些程序（尤其那些把自己的代理配置缓存在配置文件里的）会一直记着旧地址，
#  端口一变它们就连不上，用户只会去查网络。
#
#  这里在本机开一个**固定**地址，程序只认这个；背后自动跟着翻墙软件换。
#
#  ------------------------------------------------------------------------------
#  它不解决的问题（也不该由它解决）
# ------------------------------------------------------------------------------
#  全局环境变量**不指向这里**。只有「走代理的快捷方式」生成的启动器会用它。
#  理由：中继活着但上游挂了时，全局变量会让**所有**工具一起连不上，比没代理更糟。
#  而启动器是"每次点击重新决定"的，中继不可用它会自动退回直读注册表——
#  爆炸半径只有"点图标的那一个程序"，而且永远有降级路径。
#
#  ------------------------------------------------------------------------------
#  与生命周期的关系
# ------------------------------------------------------------------------------
#  中继**内嵌在监控进程里**（独立线程），不新增常驻进程：
#    安装        -> 监控起来，它起来
#    停止监控    -> 监控退出，它跟着没了；快捷方式退回直读注册表（那时变量已删，等于直连）
#    一键恢复    -> 同上；默认保留的图标仍能点开程序，只是不带代理
#    重新安装    -> 监控回来，图标自动又能带上代理，不用重建
#  所以它**不需要任何额外的清理逻辑**，也不破坏「自启动=登录拉起一次、不保活」的契约。
#  ------------------------------------------------------------------------------
#  DIVERGE(Win): 这是 Windows 独有的能力，mac 侧不实现，理由不是"没做"
# ------------------------------------------------------------------------------
#  mac 侧没有快捷方式这一层：`launchctl setenv` 对之后由 launchd 拉起的进程直接生效，
#  Finder/Dock 启动的应用自然继承，不需要"启动前注入"的启动器，也就没有一个
#  "地址被写死在别处"的东西需要固定入口去兜。
#  换句话说：Windows 需要固定入口，是因为它的启动器把地址交给了程序；
#  mac 没有那个交接点，因此没有同一类问题可解。
#  哪天 mac 侧真的出现了等价需求（某个程序把地址缓存进自己的配置），
#  正确的做法是复用这一层的设计思路（内存里转发 + 每连接取上游），
#  而不是把这段 C# 搬过去——那边没有 Add-Type，等价物要用别的方式实现。
# ==============================================================================

# 固定入口的默认端口。
#
# 选值原则（不写死某个用途）：挑一个不在各翻墙软件默认端口表里、也不在任何
# 常见服务默认端口上的值，避免"装完就冲突"。它不是"给某个软件用的端口"，
# 所以不放 $KnownProxyPorts——那张表是"去探测谁在监听"，而这是我们自己开的。
$RelayDefaultPort = 17099
# 端口被占用时往后顺延多少个再放弃。20 个足够：本机同时占住连续 21 个端口
# 的情况极其罕见，而无限顺延会让"失败"变成"慢慢扫遍全端口"。
$RelayPortScanSpan = 20

# 状态探针路径。中继对这个路径**自己应答、不转发**，读方据此确认
# "中继还在，且现在转发到哪个端口"。
# 与 C# 里的 StatusPath 必须逐字相同——那里是常量、这里是常量，
# 唯一保证它们一致的办法是**从这里传进去**（放在下面生成的代码里会破坏可读性，
# 所以两边都写成显式常量，并由自检比对：探不通就是不一致，自检会红）。
$script:RelayStatusPath = '/__envproxy_relay_status__'

# 记录实际使用的端口。启动器要读它才知道该连哪儿。
#
# 位置选**固定安装目录**（Get-InstallDir，即 %LOCALAPPDATA%\EnvProxy），
# 不是 monitor 目录。原因：这个路径会被写进启动脚本（.vbs 里那串 base64），
# 而项目契约明确写着"文件夹可任意搬家、改名、复制备份"。写死一个跟着安装根走的
# 绝对路径，一搬家就失效——虽然失效只导致降级（退回直读注册表），但那是白丢一个能力。
# 固定目录不随安装根变，搬多少次都还指向同一个地方。
# 与 terminal.env、launchers\ 放在同一处，也是同一个理由。
#
# 路径每次现算（不在加载期求值）：库必须加载期安全，点源那一刻环境还可能没就位。
# 取不到时返回空串而不是抛：生成启动脚本那一段会据此写"没有固定入口"，
# 退化成"只读注册表"的旧行为，而不是让整个建图标流程失败。
function Get-RelayPortFile {
    $dir = Get-InstallDir
    if (-not $dir) { return '' }
    return (Join-Path $dir 'relay.port')
}

# 读出当前中继端口。读不到/内容不合法返回 $null（调用方按"没在跑"处理）。
function Get-RelayPort {
    try {
        $p = Get-RelayPortFile
        if (-not (Test-Item $p)) { return $null }
        $t = (Read-Text $p).Trim()
        if ($t -notmatch '^\d+$') { return $null }
        $n = [int]$t
        if ($n -lt 1 -or $n -gt 65535) { return $null }
        return $n
    } catch { return $null }
}

# 挑一个可用的端口：从默认值开始，占用就顺延。
# 返回 @{ Port = n; Ok = $true } 或 @{ Port = 0; Ok = $false }。
function Select-RelayPort {
    for ($i = 0; $i -lt $RelayPortScanSpan; $i++) {
        $candidate = $RelayDefaultPort + $i
        if ($candidate -gt 65535) { break }
        $listener = $null
        try {
            $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $candidate)
            $listener.Start()
            return @{ Port = $candidate; Ok = $true }
        } catch {
            # 这个端口被占了：试下一个
        } finally {
            if ($listener) { try { $listener.Stop() } catch {} }
        }
    }
    return @{ Port = 0; Ok = $false }
}

# 中继转发器的实现（**在内存里编译**，不落盘、不引依赖）。
#
# 用 Add-Type 而不是纯 PowerShell 写：这件事要求"一个客户端连接对应两条 socket
# 互相泵字节"，纯 PowerShell 只能靠 BeginRead/EndRead 手搓回调状态机，
# 在 5.1 上没有 async/await，写出来既慢又容易漏掉半关闭。C# 里几十行就够了，
# 编译器是 .NET Framework 自带的（5.1 一定有），不需要装任何东西。
#
# ------------------------------------------------------------------------------
# 三条必须守住的行为（都是实测踩出来的，不是推演）
# ------------------------------------------------------------------------------
#  1) **必须同时处理 CONNECT 与普通 HTTP 两种请求形态。**
#     只做 CONNECT 时 HTTPS 正常、纯 HTTP 全部失败——因为纯 HTTP 走代理时
#     客户端发的是"GET http://host/path"（绝对 URI），不发 CONNECT。
#
#  2) **回 200 之前必须先连上上游、读到上游的响应头。**
#     顺序反过来就再也无法报错：一旦回了 200，客户端认为隧道已建立，
#     之后上游连不上只能硬断链，表现成"莫名其妙断线"而不是"代理不可用"。
#
#  3) **上游死时要快速回 502。** 实测 2 秒内能给客户端明确答复；
#     超时值太大会让客户端长时间挂起，用户以为卡死。
#
# 上游端口**不缓存**：每次新连接都重新解析，所以翻墙软件换端口后
# 已经在跑的中继不需要重启，下一条新连接就自动走新上游。
function Initialize-RelayType {
    if ('EnvProxyRelay' -as [type]) { return $true }
    $code = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public class EnvProxyRelay {
    // 上游 = 地址 + 端口，必须**一起**换。
    //
    // 只存端口会丢掉地址族：只监听 ::1 的代理（mihomo / sing-box 配 bind-address: "::1"）
    // 对 IPv4 回环是**主动拒绝**，那条链路 100% 失败；而终端里 curl 一切正常
    // （变量注入的是 http://[::1]:端口），用户只会觉得"某个软件坏了"。
    private static readonly object _upLock = new object();
    private static string _upstreamHost = "127.0.0.1";
    private static int _upstreamPort = 0;

    public static void SetUpstream(string host, int port) {
        lock (_upLock) {
            _upstreamHost = string.IsNullOrEmpty(host) ? "127.0.0.1" : host;
            _upstreamPort = port;
        }
    }
    public static void SetUpstream(int port) { SetUpstream("127.0.0.1", port); }
    public static int GetUpstream() { lock (_upLock) { return _upstreamPort; } }

    private TcpListener _listener = null;
    private Thread _acceptThread = null;
    private volatile bool _running = false;
    private int _port = 0;
    private int _active = 0;
    private readonly List<Socket> _conns = new List<Socket>();

    private const int MaxConnections = 200;
    private const int ThreadStackBytes = 256 * 1024;
    private const int MaxHeadBytes = 65536;
    private const int ConnectTimeoutMs = 4000;
    private const int FirstPacketTimeoutMs = 2000;

    private static string _lastError = "";
    public static string LastError { get { return _lastError; } }

    public int Port { get { return _port; } }
    // 判活要看**线程还在不在**，不能只看那个布尔。
    // accept 线程异常退出后 _running 若还留着 true，会同时骗过两个人：
    // 界面读到 Running=true（以为没事）、Start-Relay 的幂等判据也读到 true（不重建），
    // 于是永久坏到监控进程重启——图标还能点，但永远不走代理，谁都不修。
    public bool Running {
        get { return _running && _acceptThread != null && _acceptThread.IsAlive; }
    }

    public bool Start(int port) { return StartRange(port, 1); }

    // 在 [startPort, startPort+span) 里找第一个能绑的端口，**一次 bind 定胜负**。
    //
    // 原来分两步：先 bind 探一次、Stop、返回端口，回来再 bind 一次。两步之间有窗口，
    // 探测说完好、真正绑定时被别人抢走，于是 Start 返回 false——而窗口里还有十几个空闲端口，
    // 代码一个都不再试，整条能力就此消失，日志里还没有任何细节。
    public bool StartRange(int startPort, int span) {
        if (span < 1) { span = 1; }
        Stop();
        _lastError = "";
        for (int i = 0; i < span; i++) {
            int p = (startPort <= 0) ? 0 : (startPort + i);
            TcpListener l = null;
            try {
                l = new TcpListener(IPAddress.Loopback, p);
                l.Start();
            } catch (Exception ex) {
                if (l != null) { try { l.Stop(); } catch {} }
                _lastError = "bind " + p + ": " + ex.Message;
                if (startPort <= 0) { _running = false; return false; }
                continue;
            }
            _listener = l;
            _port = ((IPEndPoint)l.LocalEndpoint).Port;
            _running = true;
            _acceptThread = new Thread(AcceptLoop);
            _acceptThread.IsBackground = true;
            _acceptThread.Start();
            return true;
        }
        _lastError = "no free port in [" + startPort + ", " + (startPort + span - 1) + "]";
        _running = false;
        return false;
    }

    public void Stop() {
        _running = false;
        try { if (_listener != null) { _listener.Stop(); } } catch {}
        _listener = null;
        // 已建立的连接也要关。不然"停止"之后旧隧道还在继续转发，
        // 而端口记录已经删了——读方以为中继没了，实际还有流量在走。
        Socket[] snap;
        lock (_conns) { snap = _conns.ToArray(); _conns.Clear(); }
        for (int i = 0; i < snap.Length; i++) { try { snap[i].Close(); } catch {} }
    }

    private void AcceptLoop() {
        while (_running) {
            Socket client = null;
            try { client = _listener.AcceptSocket(); }
            catch { break; }
            // 超过上限：立刻回 503 再关，不让它堆在线程里。
            if (Interlocked.Increment(ref _active) > MaxConnections) {
                Interlocked.Decrement(ref _active);
                Reply(client, "HTTP/1.1 503 Service Unavailable", "busy", 0);
                try { client.Close(); } catch {}
                continue;
            }
            Track(client, true);
            Socket c = client;
            // **每条连接一个专属线程**，不用线程池。
            // 线程池超过最小线程数后约每 0.5-1 秒才补一个线程，而 Handle 是阻塞写法、
            // 整条连接都占着线程：实测 50 条并发时最后一条要等 22 秒才拿到线程，
            // 用户看到的是"点了图标先卡十几秒才动"，连状态探针也一起堵死。
            // 专属线程 + 小栈（256KB）让开销可预期；上限 200 防失控程序吃光内存。
            Thread t = new Thread(delegate() {
                try { Handle(c); }
                finally {
                    Track(c, false);
                    Interlocked.Decrement(ref _active);
                }
            }, ThreadStackBytes);
            t.IsBackground = true;
            t.Start();
        }
        // 退出这个循环只有两种可能：Stop() 关了监听（_running 已是 false），
        // 或者监听出了异常。后者必须把 _running 也置假，让上层能发现并重建。
        _running = false;
    }

    private void Track(Socket s, bool add) {
        lock (_conns) {
            if (add) { _conns.Add(s); }
            else { _conns.Remove(s); }
        }
    }

    private static void Pump(Socket from, Socket to) {
        byte[] buf = new byte[16384];
        try {
            while (true) {
                int n = from.Receive(buf);
                if (n <= 0) {
                    // 半关闭：不这么做大响应体会被截断（"下载到一半失败"）。
                    try { to.Shutdown(SocketShutdown.Send); } catch {}
                    return;
                }
                to.Send(buf, 0, n, SocketFlags.None);
            }
        } catch {}
    }

    private const string StatusPath = "/__envproxy_relay_status__";

    // 只看请求行，且路径必须**完全相等**。
    // 前缀匹配会把 GET /__envproxy_relay_status__evil 也截胡，那条请求永远到不了上游。
    private static bool IsStatusRequest(string head) {
        int e = head.IndexOf("\r\n", StringComparison.Ordinal);
        string line = (e > 0) ? head.Substring(0, e) : head;
        string[] parts = line.Split(' ');
        if (parts.Length < 2) { return false; }
        return string.Equals(parts[1], StatusPath, StringComparison.Ordinal);
    }

    private static int IndexOfCrLfCrLf(byte[] buf, int len) {
        for (int i = 0; i + 3 < len; i++) {
            if (buf[i] == 13 && buf[i+1] == 10 && buf[i+2] == 13 && buf[i+3] == 10) { return i; }
        }
        return -1;
    }

    // 读到头的结尾（空行）为止，**不能只读一次**。
    // 客户端的请求头经常分两次写出，也可能是很大的 Cookie（>16KB）。
    // 只读一次就把半截头当完整头转给上游，上游等不到空行不应答，
    // 客户端挂满超时后收到 504——每条这类请求都彻底失败。
    private static byte[] ReadHead(Socket s, int timeoutMs) {
        s.ReceiveTimeout = timeoutMs;
        byte[] buf = new byte[8192];
        MemoryStream ms = new MemoryStream();
        int total = 0;
        while (total < MaxHeadBytes) {
            int n;
            try { n = s.Receive(buf); }
            catch { return null; }
            if (n <= 0) { break; }
            ms.Write(buf, 0, n);
            total += n;
            if (IndexOfCrLfCrLf(ms.GetBuffer(), total) >= 0) { break; }
        }
        if (total <= 0) { return null; }
        byte[] outb = new byte[total];
        Array.Copy(ms.GetBuffer(), outb, total);
        return outb;
    }

    // 上游地址候选：给的地址优先，若它是回环再补另一个地址族。
    // 与本项目"探测本机代理要试两个回环地址"同一条道理。
    private static string[] BuildCandidates(string host) {
        if (string.IsNullOrEmpty(host)) { return new string[] { "127.0.0.1", "::1" }; }
        if (host == "::1") { return new string[] { "::1", "127.0.0.1" }; }
        if (host == "127.0.0.1") { return new string[] { "127.0.0.1", "::1" }; }
        return new string[] { host };
    }

    private static Socket ConnectUpstream(string host, int port, out bool timedOut) {
        timedOut = false;
        string[] cands = BuildCandidates(host);
        for (int i = 0; i < cands.Length; i++) {
            Socket s = null;
            try {
                IPAddress addr = IPAddress.Parse(cands[i]);
                s = new Socket(addr.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                s.NoDelay = true;
                IAsyncResult ar = s.BeginConnect(new IPEndPoint(addr, port), null, null);
                if (!ar.AsyncWaitHandle.WaitOne(ConnectTimeoutMs)) {
                    timedOut = true;
                    try { s.Close(); } catch {}
                    continue;
                }
                s.EndConnect(ar);
                return s;
            } catch {
                if (s != null) { try { s.Close(); } catch {} }
            }
        }
        return null;
    }

    private static bool IsOkStatus(string text) {
        return text.StartsWith("HTTP/1.1 200", StringComparison.Ordinal)
            || text.StartsWith("HTTP/1.0 200", StringComparison.Ordinal);
    }

    private void Handle(Socket client) {
        Socket upstream = null;
        try {
            client.NoDelay = true;
            byte[] head = ReadHead(client, 15000);
            if (head == null) { return; }
            string requestHead = Encoding.ASCII.GetString(head);

            if (IsStatusRequest(requestHead)) {
                int cur;
                lock (_upLock) { cur = _upstreamPort; }
                string body = "{\"running\":true,\"upstream\":" + cur + "}";
                byte[] payload = Encoding.UTF8.GetBytes(body);
                StringBuilder sb = new StringBuilder();
                sb.Append("HTTP/1.1 200 OK\r\n");
                sb.Append("Content-Type: application/json\r\n");
                sb.Append("Content-Length: ").Append(payload.Length).Append("\r\n");
                sb.Append("Connection: close\r\n");
                sb.Append("X-EnvProxy-Relay: status\r\n");
                sb.Append("X-EnvProxy-Upstream: ").Append(cur).Append("\r\n\r\n");
                client.Send(Encoding.ASCII.GetBytes(sb.ToString()));
                client.Send(payload);
                return;
            }

            string upHost;
            int upPort;
            lock (_upLock) { upHost = _upstreamHost; upPort = _upstreamPort; }
            if (upPort <= 0) {
                Reply(client, "HTTP/1.1 503 Service Unavailable", "no upstream", 0);
                return;
            }

            bool timedOut;
            upstream = ConnectUpstream(upHost, upPort, out timedOut);
            if (upstream == null) {
                // 拒绝与超时要分开：拒绝是"上游没开"（去开翻墙软件），
                // 超时是"上游不答"（重连 / 换节点）。混成一个码，用户不知道从哪儿下手。
                if (timedOut) {
                    Reply(client, "HTTP/1.1 504 Gateway Timeout", "upstream timeout", upPort);
                } else {
                    Reply(client, "HTTP/1.1 502 Bad Gateway", "upstream refused", upPort);
                }
                return;
            }

            upstream.Send(head, 0, head.Length, SocketFlags.None);

            byte[] upHead = ReadHead(upstream, FirstPacketTimeoutMs);
            if (upHead == null) {
                Reply(client, "HTTP/1.1 504 Gateway Timeout", "upstream no response", upPort);
                return;
            }
            string upText = Encoding.ASCII.GetString(upHead);
            bool isConnect = requestHead.StartsWith("CONNECT ", StringComparison.OrdinalIgnoreCase);

            if (isConnect) {
                if (IsOkStatus(upText)) {
                    byte[] ok = Encoding.ASCII.GetBytes("HTTP/1.1 200 Connection established\r\n\r\n");
                    client.Send(ok);
                    // 上游把 200 头和数据放在同一个包里是合法的（TLS 握手包常见）。
                    // 头之后那些字节必须转给客户端，否则隧道第一段就丢数据、TLS 直接崩。
                    int hdrEnd = IndexOfCrLfCrLf(upHead, upHead.Length);
                    if (hdrEnd >= 0) {
                        int bodyStart = hdrEnd + 4;
                        if (bodyStart < upHead.Length) {
                            byte[] rest = new byte[upHead.Length - bodyStart];
                            Array.Copy(upHead, bodyStart, rest, 0, rest.Length);
                            client.Send(rest);
                        }
                    }
                } else {
                    client.Send(upHead);
                    return;
                }
            } else {
                // 普通 HTTP：上游已经把响应头（可能连正文）回过来了，原样转给客户端。
                client.Send(upHead);
            }

            // 进泵之前必须把读超时清零。Socket.ReceiveTimeout 管的是整条连接的生命周期，
            // 而隧道里十几秒没有字节是完全正常的（keep-alive、SSE、看文章时页面静止）。
            // 留着超时的表现是"停十几秒不动就断了"，而且完全不报错。
            client.ReceiveTimeout = 0;
            upstream.ReceiveTimeout = 0;
            Socket upRef = upstream;
            Socket clRef = client;
            Thread t = new Thread(delegate() { Pump(upRef, clRef); }, ThreadStackBytes);
            t.IsBackground = true;
            t.Start();
            Pump(client, upstream);
        } catch {
            try { Reply(client, "HTTP/1.1 502 Bad Gateway", "relay error", 0); } catch {}
        } finally {
            try { if (client != null) { client.Close(); } } catch {}
            try { if (upstream != null) { upstream.Close(); } } catch {}
        }
    }

    private static void Reply(Socket s, string status, string why, int upPort) {
        StringBuilder sb = new StringBuilder();
        sb.Append(status).Append("\r\n");
        sb.Append("Content-Length: 0\r\n");
        // 必须有 Connection: close，否则客户端会按长连接等着，白白挂到超时。
        sb.Append("Connection: close\r\n");
        sb.Append("X-EnvProxy-Relay: ").Append(why).Append("\r\n");
        sb.Append("X-EnvProxy-Upstream: ").Append(upPort).Append("\r\n\r\n");
        try { s.Send(Encoding.ASCII.GetBytes(sb.ToString())); } catch {}
    }
}
'@
    try {
        Add-Type -TypeDefinition $code -ErrorAction Stop
        return $true
    } catch {
        # 编译失败（极罕见：.NET 组件被裁剪）不能让监控停摆，只是没有固定入口。
        return $false
    }
}

# 中继类型能不能用（只读判断，不产生副作用）。
# 自检用它决定"跑中继用例"还是"跳过"：在编译不出类型的机器上，
# 那些用例的自检本身不该变成红灯——那是平台限制，不是行为错误。
function Test-RelayType {
    if ('EnvProxyRelay' -as [type]) { return $true }
    return (Initialize-RelayType)
}

# 中继的状态，供监控与状态页共用（同一份词汇，不各写一套）。
$script:RelayInstance = $null
$script:RelayPort = 0
$script:RelayFailed = $false
# 上一次失败的原因（空串 = 没失败过）。三种失败（编译不了 / 端口全占 / 启动异常）
# 必须分得开：只置一个 bool 的话，日志里那句话对三种情况都成立，
# 用户和开发者都分不清该查哪儿。
$script:RelayFailReason = ""

# 起中继。已在跑就什么都不做（幂等——主循环会反复调它）。
# 返回 $true 表示"现在有一个在跑"。
function Start-Relay {
    # 幂等：主循环每轮都会调（它本来就是"死了就重建"的唯一收敛点）。
    if ($script:RelayInstance -and $script:RelayInstance.Running) { return $true }
    # 上一份实例还在但不 Running（accept 线程死了）：先收干净再重建，
    # 不然旧监听可能还占着端口。
    if ($script:RelayInstance) { try { $script:RelayInstance.Stop() } catch {}; $script:RelayInstance = $null }
    if (-not (Initialize-RelayType)) {
        $script:RelayFailed = $true
        $script:RelayFailReason = "中继类型编译失败（.NET 组件可能被裁剪）"
        return $false
    }
    try {
        $relay = New-Object EnvProxyRelay
        # **在 C# 里一次绑到底**：别在这边先探一次端口再让它绑一次。
        # 两步之间有窗口，抢输之后原来直接放弃，而窗口里还有十几个空闲端口。
        if (-not $relay.StartRange($RelayDefaultPort, $RelayPortScanSpan)) {
            $script:RelayFailed = $true
            $script:RelayFailReason = "端口绑定失败：" + [string]([EnvProxyRelay]::LastError)
            return $false
        }
        $script:RelayInstance = $relay
        $script:RelayPort = $relay.Port
        $script:RelayFailed = $false
        $script:RelayFailReason = ""
        # 记录实际端口：启动器要读它。写失败不影响中继工作（启动器会退回直读注册表）。
        try { Write-Text -Path (Get-RelayPortFile) -Text ([string]$relay.Port) } catch {}
        return $true
    } catch {
        $script:RelayFailed = $true
        $script:RelayFailReason = "启动异常：" + $_.Exception.Message
        return $false
    }
}

# 停中继并清掉端口记录。
function Stop-Relay {
    if ($script:RelayInstance) {
        try { $script:RelayInstance.Stop() } catch {}
        $script:RelayInstance = $null
    }
    $script:RelayPort = 0
    try {
        $f = Get-RelayPortFile
        if (Test-Item $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    } catch {}
}

# 把当前上游告诉中继。主循环每轮调一次（成本几乎为零：一次静态字段写）。
# 上游取"我们注入的那个值指向的端口"——它是权威来源，与终端拿到的完全一致。
function Sync-RelayUpstream {
    if (-not ($script:RelayInstance -and $script:RelayInstance.Running)) { return }
    $upHost = "127.0.0.1"
    $port = 0
    try {
        $val = Get-EnvProxyValue
        if ($val) {
            $parts = Split-ProxyUrl $val
            if ($parts -and $parts.Port -gt 0) {
                $port = [int]$parts.Port
                # **地址也要带上**，不能只传端口。
                # 只监听 ::1 的代理（mihomo / sing-box 配 bind-address: "::1"）对 IPv4
                # 回环是主动拒绝：只传端口等于把这类用户的固定入口直接判死，
                # 而终端里 curl 一切正常（变量注入的是 http://[::1]:端口），
                # 用户只会觉得"某个软件坏了"，根本不会想到是中继。
                if ($parts.Host) { $upHost = [string]$parts.Host }
            }
        }
    } catch {}
    try { [EnvProxyRelay]::SetUpstream($upHost, $port) } catch {}
}

# 中继当前是否可用（状态页、查看中继页用；只读，不启动任何东西）。
# 返回 @{ Running = bool; Port = int; Upstream = int; Failed = bool }
#
# **判据必须能被另一个进程读到。**
# 状态页、「查看中继」那一屏都运行在独立进程里（envproxy.ps1 -Status / 菜单），
# 而 $script:RelayInstance 只存在于**起中继的那个进程**（监控进程）中。
# 所以这里绝不能读进程内变量：那样写出来的结果是"中继跑着，界面永远说没在工作"，
# 而且它看起来一切正常——实测过：中继在跑、relay.port 写着端口，
# 另一个进程读到的 Running 仍然是 False。
#
# 正确判据是"跨进程的两件事都对上"：
#   ① relay.port 文件在（写方是监控进程，读方只读它——与"监控在不在"同一套做法）；
#   ② 那个端口真的接受连接，且回的是一个能干活的中继（不是随便谁占了那个口）。
#
# ②必须问"能不能干活"，不能只问"有没有人听"：
# 中继只要活着就一定接受 TCP 连接，哪怕它自己根本没上游。
# 只判"有人听"会让"翻墙软件关着"这个最常见状态被判成"正常"，
# 而实际上启动器把程序指过去只会收到 503。
# 这里读它回的 EnvProxy-Relay 响应头——那是中继自己写的，别的进程伪造不出来。
function Get-RelayStatus {
    $port = 0
    $running = $false
    $upstream = 0
    try { $port = Get-RelayPort } catch { $port = 0 }
    if ($port -gt 0) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $ar = $client.BeginConnect('127.0.0.1', $port, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne(300)) {
                $client.EndConnect($ar)
                $client.ReceiveTimeout = 1000
                $stream = $client.GetStream()
                # 发状态探针。**必须走中继自己的路径**，不能发普通请求——
                # 普通请求会被转发给上游，回什么取决于上游（实测裸 GET 被上游回 400），
                # 读方就分不清"中继不在"和"上游不认这个请求"。
                $probe = [System.Text.Encoding]::ASCII.GetBytes("GET $script:RelayStatusPath HTTP/1.1`r`nHost: 127.0.0.1`r`n`r`n")
                $stream.Write($probe, 0, $probe.Length)
                $stream.Flush()
                $buf = New-Object byte[] 512
                $n = $stream.Read($buf, 0, 512)
                if ($n -gt 0) {
                    $resp = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
                    # 中继的应答里必有这个头（它在 Handle 里写的），据此确认"是它、不是别人"。
                    if ($resp -match 'X-EnvProxy-Relay') {
                        $running = $true
                        # 上游端口从中继自己回头里读，不在这里猜。
                        # 没上游时它写 0，那就如实报 0 —— 界面据此显示"暂时不转发"。
                        $m = [regex]::Match($resp, 'X-EnvProxy-Upstream:\s*(\d+)')
                        if ($m.Success) { $upstream = [int]$m.Groups[1].Value }
                    }
                }
            }
            $client.Close()
        } catch {
            # 连不上就是不在跑（端口被写下了但没人听：监控刚退出的瞬间）。
        }
    }
    # 进程内那一份仍然有用：本进程就是监控进程时，它的 Failed 标记别的地方读不到。
    $failed = [bool]$script:RelayFailed
    return @{ Running = $running; Port = $port; Upstream = $upstream; Failed = $failed }
}
