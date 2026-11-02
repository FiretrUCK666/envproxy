# EnvProxy 真实机器边缘情况研究报告

研究方式：AnySearch 多轮检索 + 逐篇抓取全文（微软官方文档、Apple 生态文档、curl 官方手册、PowerShell 团队材料、真实 issue 与运维事故帖），共 39 个来源，结论均标注 URL。凡关键结论均以一手输出或官方文档为据，不用二手博客的转述当唯一依据。

---

## 0. 结论先行（TL;DR）

1. **25 个场景里，9 个是高危**（数据损坏或用户断网），16 个是"表现不对但可恢复"。
   高危的 9 个是：RDP 多会话、漫游配置跨机残留、GPO 反复覆盖、企业代理被误删、
   离线误判成"代理已断"、EDR 拦截写入却报成功、AppLocker/WDAC 拦脚本、
   便携版多副本并发写、断电留下半套变量。
2. **工具最大的结构性风险不是"探测不准"，而是"写了没写成功却以为成功了"。**
   所有失败都必须能读回来验证；读不回来一律当"不知道"，不允许当"没有"。
3. **有 4 类场景在原理上无法可靠检测**，只能靠保守策略（宁可不动）：
   回环端口上跑的是翻墙代理还是企业 ZTNA 客户端、GPO 是否在管环境变量、
   PID 归属、被墙与离线。这四条必须写进设计前提，不能靠"再想个办法"解决。
4. **两个平台的根本差异要写进架构，不是写进分支**：
   Windows 环境变量是注册表值（可精确读写类型、可枚举、可回读）；
   macOS 是 launchd 会话内的一次性 setenv（重启即失、跨用户域不同、不可枚举）。
   所以 macOS 侧的"真相源"必须是磁盘上的 `proxy.env`，launchctl 只是投影。

---

## 1. 风险矩阵

严重度定义：**高** = 数据损坏或用户断网；**中** = 功能失效需人工介入；**低** = 表现不佳但自愈。

| # | 场景 | 严重度 | 当前可能失效表现 | 检测方式 | 处理策略 |
|---|---|---|---|---|---|
| A1 | 标准用户 vs 管理员 | 低 | HKCU 写入两者都能成功；但广播受 UIPI 限制，管不到提权窗口 | 读进程完整性级别 | 非提权运行；文档写明"提权窗口需重开" |
| A2 | 多用户同时登录（快速切换） | 中 | HKCU 各用户独立，不互相污染；但每用户一份监控各自广播，互不可见 | 按 SID 过滤进程 | 按 SID 分治，不做跨用户操作 |
| A3 | RDP 多会话（同一用户） | **高** | 两份监控写同一 HKCU，互相覆盖 owned 记录；广播跨会话不到达 | 枚举会话（WTS）+ 全局互斥体 | 监控单实例锁按"用户"而非"路径"命名 |
| A4 | 域账户 + 漫游配置文件 | **高** | `HKCU\Environment` 在 ntuser.dat 里，**会跟着漫游**；A 机的 127.0.0.1:7890 带到 B 机 | 记录写入时的机器标识 | 变量带机器指纹，异机一律当"过期"清理 |
| A5 | GPO 强制环境变量 | **高** | 本地写入被 GPP 每 90±30 分钟覆盖回去；删了又回来，用户看到"删不掉" | 观察"删掉后同值重现" | 识别为受管，转为只读并明示，不反复对抗 |
| B6 | VPN 连接/断开 | 低 | VPN 无监听 TCP 端口，不会误判；但 ZTNA 客户端的回环端口会被误判（见 B7） | 只看回环监听 + CONNECT 握手 | 不做网卡判断；TUN 不进判决（已是契约） |
| B7 | 企业代理（非回环） | **高** | 若误删/误改，用户整个公司网络中断 | 地址形态判定 | 非回环地址：判与删一律跳过（已是契约） |
| B8 | 多个代理同时存在 | 中 | 每轮选中不同端口 → 变量反复改 → 终端行为抖动 | 记录"当前选中端口" | 锁定优先端口，只在失守时切换 |
| B9 | 网络切换抖动 | 中 | WiFi→有线瞬间连接被拒 → 判"断" → 删变量 → 再注入 | 拒绝 vs 超时要分开 | 拒绝+超时分流；超时不判"断" |
| B10 | 完全离线 | **高** | 节点探测必然失败 → 判"断" → 删变量；落地后代理其实还在 | 区分"本机拒绝"与"外网超时" | 无外网时保持上一状态，不动变量 |
| C11 | 只绑 IPv6 回环 | 中 | 只试 127.0.0.1 → 永远检测不到，且不报错 | 两个回环字面量各试一次 | 显式地址族建 socket，`::1` 与 `127.0.0.1` 都试 |
| C12 | 非标准/随机端口 | 中 | 重启换端口 → 已知端口表全落空 → 判 off | 全端口 CONNECT 兜底 | 有界扫描 + 记住上次端口 |
| C13 | 崩溃后端口 TIME_WAIT | 低 | TIME_WAIT 不监听，新连接被 RST；但 netstat 里那行还在 | 只认 `LISTEN` 状态 + 握手 | 判定只认握手，不认"端口出现在列表里" |
| C14 | 非代理程序占端口 | 低 | 握手不过 → 不误判；但回 200 的本地 MITM 会被当成代理 | 三层验证 | 三层缺一不可，已覆盖 |
| D15 | 杀软/EDR 拦截 | **高** | 写注册表被拦 → 报成功 → 用户以为生效；或进程被杀 → 半套变量 | 写后回读逐项比对 | 不允许"写完不验"；不一致即回滚 |
| D16 | AppLocker / WDAC | **高** | PowerShell 进 ConstrainedLanguage → 用 .NET 类型直接报错；或整脚本被拒 | 读 `LanguageMode` | 启动即检查，明确拒跑并说明 |
| D17 | 非中英文系统 | 中 | netstat 表头/状态词本地化（LISTENING→ABHÖREN）→ 一行都匹配不上 | 宽松数 TCP 行，不锚定状态词 | 解析与取值分离；解析不出必须报"不知道" |
| D18 | 5.1 被移除/禁用 | 中 | `.cmd` 调 `powershell -File` 直接失败，菜单打不开 | 探测 5.1 与 7 | 双引擎探测 + 明确报错 |
| D19 | macOS SIP/Gatekeeper/TCC | 中 | 装到 `~/Downloads` 后登录自启读不到目录（TCC）→ 静默失效；隔离属性导致脚本拒跑 | 路径落点 + 隔离属性 | 拒绝装进 TCC 保护目录；装前清隔离属性 |
| E20 | 便携版多副本 | **高** | 两份监控同时跑，写同一 HKCU，互相判对方"不是我写的" | 全局互斥体（按产品+用户） | 监控也只允许一份 |
| E21 | OneDrive/网络驱动器 | 中 | 云端占位文件读不出来；UNC 路径下脚本受执行策略限制 | 路径类型 + 文件可读性 | 检测到即拒绝安装并说明 |
| E22 | 磁盘满 / 路径超长 | 中 | 日志写不进 → 主循环崩；`monitor\` 建不出来 → 状态页报"未运行" | 写前探测 + 长度校验 | 日志失败降级不中断；装前校验路径长度 |
| E23 | 系统时间被改 | 中 | TLS 校验失败 → 更新报"网络失败"；日志时间跳变 | 只在一次运行内比时间 | 一切"两时刻相减"用单调时钟（已是契约） |
| E24 | 断电/强制关机 | **高** | 变量写了一半；owned 记录与实际值不一致 → 认不出自己写的 | 启动时对账 | 记录与实值双向对账，孤儿记录丢弃 |
| E25 | 版本比线上新 | 低 | 报"已是最新"误导 | 比较而非相等 | 如实提示"本地比发布版新"（已是契约） |

---

## 2. 三类分级：必须处理 / 只记录 / 无法检测

### 2.1 必须处理（会导致数据损坏或用户断网）—— 9 项

| 场景 | 为什么是"必须" |
|---|---|
| **A3 RDP 多会话** | 两份监控同时写同一 HKCU。owned 记录被对方覆盖 → 清理时认不出自己写的值 → 该删的不删、不该删的删掉。这是唯一会**破坏用户既有配置**的路径。 |
| **A4 漫游配置文件** | 环境变量是**用户级**的，随 ntuser.dat 一起漫游。A 机的 `127.0.0.1:7890` 会在 B 机上生效——B 机上没有这个端口，用户所有 CLI 工具瞬间全断，而且 B 机的监控未必及时清理。来源：Raymond Chen 关于漫游配置文件的说明（`%USERPROFILE%\ntuser.dat` 就是每用户注册表，属于配置文件的一部分）。 |
| **A5 GPO 覆盖** | 组策略首选项（GPP）的 Environment 扩展默认动作是 **Update**，且**每次策略刷新（默认 90 分钟 ± 30 分钟随机偏移）都会重新应用**，除非勾了"仅应用一次不再重新应用"。结果：我们删掉的变量最多两小时后自己回来。用户看到"关了还在"，比"不工作"更伤信任。 |
| **B7 企业代理被误删** | 用户公司出口就配在 `HTTP_PROXY=http://proxy.corp.example:8080`。工具若把它当"上一轮残留"删掉，用户整个公司网络中断——这是本工具能造成的**最严重**单一事故。 |
| **B10 离线误判** | 断网 / 上飞机 / 落地未联网时节点探测必然失败。若按"连续失败即断"处理，会把变量整套删掉并广播，把用户所有已开窗口的代理一次拆光；而代理其实还活着。 |
| **D15 EDR 拦截写入** | 写 `HKCU\Environment` + 广播 `WM_SETTINGCHANGE` 在 EDR 眼里长得像持久化行为。写入被静默拦掉而工具报成功 → 用户以为在代理里，实际直连；或只写进去 3 个变量 → "半代理"，比全都没写更诡异。 |
| **D16 AppLocker/WDAC** | 策略生效时 PowerShell 会进 ConstrainedLanguage 模式，`[Microsoft.Win32.Registry]`、`.NET` 方法调用、`Add-Type` 全部不可用 → 脚本在加载期就炸。而且 Windows 11 24H2 上这套强制执行**曾经坏了几个月**（2025 年 4 月发现，PowerShell 7.6 才修），意味着"有时拦、有时不拦"，不能假设稳定。 |
| **E20 便携版多副本** | 复制到两处后两份监控并存，写同一份 HKCU，并互相把对方写的值判成"不是我写的"→ 都不删，永久残留；或者都删，来回抽搐。 |
| **E24 断电/强制关机** | 5 个变量写进去一部分就断电 → 半代理；owned 记录与实值不一致 → 下次启动"记录说是我的、值对不上"，按严格规则不删 → 永久残留。 |

### 2.2 记录 + 轻量处理即可（不必为它加特判）—— 16 项

A1 标准用户 vs 管理员、A2 多用户（HKCU 天然隔离）、B6 VPN、B8 多代理（靠锁端口而非特判）、
B9 网络抖动（靠拒绝/超时分流）、C11 IPv6 回环、C12 随机端口、C13 TIME_WAIT、C14 非代理占端口、
D17 本地化、D18 5.1 缺失、D19 SIP/Gatekeeper/TCC、E21 OneDrive、E22 磁盘满/长路径、
E23 时间被改、E25 版本比线上新。

（9 + 16 = 25，正好覆盖全部场景。其中 B9 与 B10 是同一个结构决定的两种表现：B10 高危、必须处理，
B9 是它的低危副作用，一并靠"超时不判断"解决——这就是治本不治标：一处规则覆盖两类症状。）

### 2.3 另一条轴：无法可靠检测、只能保守（宁可不动）—— 4 项

下面 4 项与前两节**交叉**（它们分散在上面若干场景里），单列是因为它们的处理原则不同：
不是"检测得更准"，而是**承认测不出来，然后选一个不会造成损害的方向**。

| 场景 | 为什么原理上测不出来 | 保守策略 |
|---|---|---|
| **回环端口是翻墙代理还是企业 ZTNA** | 两者都是"回环 + 能 CONNECT + 能出网"，形状完全一致。企业零信任客户端（Zscaler/Netskope 一类）也常在本机开监听端口。判据本身没有区分度。 | 只在本机**已安装记录存在**时才认领回环地址；没装过就不动。这样至少不会把别人的东西删掉。 |
| **GPO 是否在管环境变量** | GPP 写进去的值**不留任何策略标记**，和用户手设的值在注册表里一模一样。 | 不猜，用"删掉后同值重现"这个**时间维度**证据，且重现后只记录不反复对抗。 |
| **PID 归属** | 进程退出后 PID 会被回收；查询到的 owner 可能是另一个刚启动的进程。 | PID 只用于"按进程名提速"，永不参与判定（已是契约）。状态页不许声称"是哪个程序"。 |
| **被墙 vs 离线** | 探针超时既可能是"网络断了"，也可能是"目标被墙"，还可能"防火墙静默丢包"。三者从客户端看完全一样。 | 超时一律不判"断"；只有**本机端口明确拒绝**才判"代理没了"。 |

---

## 3. 分组详解：会怎样 / 怎么检测 / 怎么处理

### A. 用户身份与权限

#### A1 标准用户 vs 管理员
- **会怎样**：两种身份都能写 `HKCU\Environment`（那是自己的 hive，不需要提权）。真正的差异在**广播**：`SendMessage`/`SendMessageTimeout` 受 UIPI（用户界面特权隔离）约束——中完整性级别进程只能给"同级或更低"级别的窗口发消息，发给提权窗口会以访问被拒（错误 5）失败。所以提权运行的 PowerShell 窗口收不到通知。
- **怎么检测**：读当前进程的完整性级别；广播后检查是否有窗口返回失败（注意：`HWND_BROADCAST` 用 `SendMessageTimeout` 时**拿不到单个窗口的超时信息**，只能拿到整体成败）。
- **怎么处理**：默认以非提权运行。状态页和帮助明确写"已用管理员权限打开的窗口不会自动跟随，重开一次"。不要为了"覆盖提权窗口"去要求提权——那会把工具推进企业管控的对立面。

#### A2 多个用户同时登录（快速用户切换）
- **会怎样**：**不会互相干扰**。每个人有自己的 `ntuser.dat`，`HKCU` 是各自的视图，A 用户写不到 B 用户的环境变量（需要对方 hive 已加载且显式用 `HKU\<SID>`）。唯一需要注意的是：每个用户跑一份监控，各自广播，广播只在**自己的会话**里生效。
- **怎么检测**：按 SID 过滤进程（这是必须的——进程枚举返回全机器所有用户的进程，不过滤会把别人的监控认成自己的，状态页报别人的 PID，启动时甚至会去停别人的）。
- **怎么处理**：所有跨进程识别一律带 SID 前缀；不做任何跨用户操作；锁的名字也带 SID。

#### A3 远程桌面（RDP）多会话
- **会怎样**：默认 `fSingleSessionPerUser=1`，同一用户只能有一个会话，问题被掩盖。一旦管理员把它改成 0（多会话场景常见），同一用户会有两个会话同时跑监控，**写同一份 HKCU**：
  1. 会话 1 写入值并记录 owned；会话 2 又写一遍（值相同，无害）；
  2. 但会话 2 的"上一轮状态"是独立的，它可能判 off 并触发清理，把会话 1 刚写的删掉；
  3. 广播跨会话不到达——微软 Session 0 隔离文档写得很直白："应用运行在不同会话，因此有不同的消息队列，消息永远不会到达目的地"。
  4. 结果：一个会话里终端有代理，另一个没有，还周期性抽搐。
- **怎么检测**：用 WTS API 枚举本用户的会话数；或用**命名互斥体**做单实例（`Global\` 命名空间可跨会话，`Local\` 不行）。
- **怎么处理**：**监控本身必须是单实例，锁名按「产品 + 用户 SID」，不按路径、不按会话**。第二个会话启动时直接退出并提示"此账号已在另一个会话中运行"。这一条同时解决 A3 和 E20。

#### A4 企业域账户 + 漫游配置文件
- **会怎样**：`HKCU\Environment` 存在 `%USERPROFILE%\ntuser.dat` 里，而 ntuser.dat 就是"用户配置文件"的一部分。域账户启用漫游后，登录时从服务器拉下来、注销时写回去。于是：
  - A 机上注入的 `HTTP_PROXY=http://127.0.0.1:7890` 会跟着漫游到 B 机；
  - B 机上没有 7890 端口 → 用户所有走环境变量的 CLI（git/npm/curl）全部连不上；
  - 更糟：B 机的监控可能把它认成"不是我写的"（如果 owned 记录没有一起漫游或对不上）→ 不清理 → 永久残留。
  - Raymond Chen 的原文还补了一刀：对**缓存副本**的修改会被丢弃，或者反过来把服务器上的新改动顶掉，两种情况都会造成数据丢失。
- **怎么检测**：写入时在 owned 记录里带上**机器标识**（计算机名 + 一个安装期生成的随机安装 ID）。启动时比对：记录是别的机器写的 → 不是我的。
- **怎么处理**：**变量带机器指纹，异机一律当"过期"清理**，而不是当"我的"保留。判断顺序：先看机器指纹 → 再看向量是否等于我写下的 → 最后才看向量形状。这条不动摇"归属记录优先"的原则，只是在记录里多一个维度。

#### A5 组策略强制设置环境变量
- **会怎样**：企业通常两种做法：
  1. **组策略首选项（GPP）→ Windows 设置 → 环境**：可创建/修改/删除用户或系统的环境变量。默认动作是 `Update`（存在就改，不存在就建），并且**每次策略刷新都重新应用**。默认刷新间隔 90 分钟 + 0–30 分钟随机偏移。
  2. **本地安全策略/脚本**：登录脚本每次登录重设。
  两种都导致同一现象：我们删掉的变量自己回来了，或者我们写的值被改回企业规定的值。
- **怎么检测**：**唯一的可靠信号是时间维度**——删掉后，同一个值在 ≤2 小时内原样重现。GPP 不留任何注册表标记，静态读注册表永远判不出来。可辅助：`gpresult /r` 结果里是否有 Environment 扩展（但那要跑外部进程，只能进诊断页，不能进热路径）。
- **怎么处理**：
  - 一旦观察到"删掉又重现"，把该变量标记为**受管**，此后**只读不写**，状态页如实显示"此项由公司策略管理，EnvProxy 不再改动"。
  - **不要反复对抗**：每 90 分钟删一次再被写回来，等于持续制造注册表写入事件，EDR 会盯上。
  - 这也意味着：受管变量不参与"整套同进同退"——否则一个受管变量会把整套逻辑拖垮。要显式规定：**受管变量从集合中剔除，并在状态页列出被剔除的项**。

---

### B. 网络环境剧变

#### B6 VPN 连接/断开
- **会怎样**：**不会误判**。VPN 建立的是虚拟网卡和路由，不监听 TCP 端口；本工具的候选集只来自"回环 + LISTEN"，所以 VPN 天生进不了候选集。唯一例外见 B8。
- **怎么检测**：不需要专门检测。本项目已明确"TUN 识别不进判决"——TUN 网卡与企业 VPN 网卡无法区分，判错会删掉用户唯一的代理路径。
- **怎么处理**：维持现状。**不要**为了"更准确"去读网卡列表——那正是会引入误判的地方。

#### B7 企业代理（非回环地址）存在时
- **会怎样**：如果工具把 `HTTP_PROXY=http://proxy.corp.example:8080` 当成"上一个代理的残留"删掉，用户的整个公司网络出口就断了——这是本工具能造成的**最严重**事故。
- **怎么检测**：**地址形态**是唯一廉价且稳定的信号：值是回环地址（`127.0.0.1`/`::1`/`localhost`）→ 可能是我们写的；非回环 → 一定是用户的。
- **怎么处理**：维持契约——"非回环地址，判与删一律跳过"。并且要守住一条更硬的边界：**授权只看廉价信号**（地址形态、端口三态、策略管辖、该层是否生效）。握手分类、端口属主、客户端目录匹配这些"贵信号"只许进解释，绝不进授权——它们会因权限、防火墙、自研客户端而不定地失效，一旦参与授权，失效就变成"退回可修"，越不可靠越容易删东西。

#### B8 同时有多个代理（公司代理 + 翻墙软件）
- **会怎样**：两个层面：
  1. **两个翻墙软件同时跑**（Clash + v2rayN）：两个回环端口都过握手，都过节点连通。如果每轮"谁先扫到选谁"，变量会来回改，终端行为抖动。
  2. **公司代理在非回环、翻墙在回环**：不冲突——公司代理那 5 个变量本来就是用户的，我们不碰；我们只写回环值。但**如果我们覆盖了用户的同名变量**，就丢了公司配置，必须靠安装快照还原。
- **怎么检测**：候选集每轮可能变化 → 记住"当前锁定端口"；状态机记候选集合签名，签名不变就不重选。
- **怎么处理**：**锁定优先端口**，只在它失守（握手失败）时才切换；切换要记日志（"从 7890 切到 10808"）。安装时快照原值，卸载按快照还原——这条是"不弄坏用户配置"的最后一道保险。

#### B9 网络切换（WiFi → 有线 → 热点）
- **会怎样**：切换瞬间，本机回环连接不受影响（回环不走网卡），但**节点探测**会失败。如果失败就判"断"，会走一遍"删变量 → 再注入"，用户在两三秒里看到终端报错。
- **怎么检测**：**区分"明确拒绝"与"没有回应"**。这是个纯技术但极其关键的区分：
  - 连接被**拒绝**（收到 RST）＝ 对端主机在，但那个端口没有监听者 → 代理确实没了；
  - 连接**超时**（没有收到任何回应）＝ 包丢了、被丢包式防火墙挡了、或网络断了 → **什么都不能断定**。
- **怎么处理**：超时**永远不判"断"**，只累积失败；拒绝才计入"代理没了"的证据。再叠加已有的去抖（连续满 N 秒且至少 M 次）。这条规则同时解决 B10。

#### B10 完全离线
- **会怎样**：节点探测 100% 失败。如果按"连续失败即断"处理，飞机上/断网时会删掉变量；落地后代理明明还在，却要等下一轮才恢复。更糟的是删变量这个动作会广播，把用户所有已开窗口的代理拆掉。
- **怎么检测**：见 B9——超时而非拒绝；也可辅以"本机是否还有任何可用网卡/默认路由"（但那要读系统接口，只能作为解释，不能作为授权）。
- **怎么处理**：**无外网时保持上一状态，不动变量**。已经在契约里："off 不等于零外网"、"判『断』必须比判『通』保守"。这里要补一句明确的：**"本机端口拒绝"才是断的判据，"外网不通"不是。**

---

### C. 代理软件形态

#### C11 只绑 IPv6 回环
- **会怎样**：代理只 listen 在 `[::1]:7890`，对 `127.0.0.1:7890` 主动拒绝。只试 IPv4 的实现会**永远检测不到，而且不报错**——最难发现的失效类型。
- **怎么检测**：两个回环字面量各试一次，**按地址族显式创建 socket**。
- **怎么处理**：已覆盖（契约：探测本机代理要试两个回环地址）。要补的是**日志**：状态页应显示"IPv6 回环命中"，否则用户看不出区别。
- **额外坑**：不要用 `localhost` 让系统去解析——不同系统的解析顺序不同，会挑到另一个地址族。

#### C12 非标准端口 / 每次随机
- **会怎样**：客户端重启后端口从 7890 变成 54321。已知端口表全落空 → 候选集为空 → 判 off → 删变量。用户体感是"代理软件一重启，终端就坏一会儿"。
- **怎么检测**：全端口 CONNECT 兜底（这是唯一不依赖配置的办法）。
- **怎么处理**：有界扫描——**不能**每 15 秒扫 65535 个端口。分层：已知端口表 → 上次锁定端口 → 冷启动时做一次有界全扫（并行、统一截止），之后只在"状态未知"时才重扫。**关键**：`on` 只可能来自本轮候选集；候选集为空就只能是 `off`，不许沿用上一轮记住的端口。

#### C13 崩溃后端口仍被占（TIME_WAIT）
- **会怎样**：**TIME_WAIT 不是监听状态**。它是"连接已关闭但在等 2MSL"的临时状态，内核仍持有四元组，但**不接受新连接**——对它的新 SYN 会回 RST，客户端得到"连接被拒绝"。所以：
  - 不会造成"假代理"（握手必然失败）；
  - 但会让 `netstat` 里那一行**还在**。如果实现用"端口是否出现在 netstat 输出里"判断存活，就会误判为"活着"。
- **怎么检测**：**只认 `LISTEN` 状态的行**，并且判定只认握手，不认"列表里有没有"。
- **怎么处理**：已覆盖（三层验证第一层是"监听"）。要补的是**过滤条件必须严格到状态列**，且解析出的状态词不能硬编码英文（见 D17）。

#### C14 非代理程序占用常见代理端口
- **会怎样**：开发服务器、Docker、IDE 的调试端口占了 7890/8080。握手必然失败 → 不误判。**但有一类特例**：本机 MITM 调试工具（mitmproxy、Charles、Fiddler）会正常应答 CONNECT 200 且能出网 → 会被判成"真代理"并注入。
- **怎么检测**：第三层"真实节点连通"会通过（它确实能出网），所以**测不出来**。
- **怎么处理**：这不是 bug——它**确实是**一个代理，注入是合理的。真正的风险在"删"：只删我们写下的值（归属记录），所以删掉 MITM 代理的变量只会让用户回到他原本的配置。**不要**加"排除 MITM 端口"这类黑名单，那是打补丁。

---

### D. 系统环境

#### D15 杀毒软件 / EDR 拦截
- **会怎样**：三种失败形态，全都危险：
  1. 注册表写入被静默拦掉，API 仍返回成功 → 工具报"已注入"，实际没写；
  2. 写到一半进程被杀 → 5 个变量写进去 2 个 → **"半代理"**（`HTTP_PROXY` 有、`HTTPS_PROXY` 没有），行为比完全不设更诡异；
  3. 广播被拦 → 变量写进去了但已开窗口不知道。
- **怎么检测**：**写后回读，逐项比对**。这是唯一可靠的手段，也顺带覆盖磁盘满、权限异常等一切"写失败"。
- **怎么处理**：
  - 整批写 → 整批回读 → 有一项不一致就**整批回滚**并报失败（"整套同进同退"必须包含失败路径）；
  - 报告里分清楚"写入被拒"与"写入成功但广播失败"，这两种排查方向相反；
  - 不要"重试三次"——被策略拦住时重试只是多制造三条审计日志。

#### D16 AppLocker / WDAC
- **会怎样**：策略生效时，未签名的 `.ps1` 会被放进 **ConstrainedLanguage（受限语言模式）**：`Add-Type` 被禁、`.NET` 类型的方法调用只允许白名单、`New-Object` 受限。本工具重度依赖 `[Microsoft.Win32.Registry]`、`SHA256`、`Socket` → **加载期就失败**，报错信息还很晦涩（不是"权限不足"，是"方法调用不被允许"）。
  更麻烦的是**执行不稳定**：Windows 11 24H2 上这套强制执行坏了几个月（2025-04 被发现），同一台机器可能今天拦明天不拦。
- **怎么检测**：启动时读 `$ExecutionContext.SessionState.LanguageMode`，是 `ConstrainedLanguage` 就直接判定"跑不了"。这比等到第 40 行报错好得多。
- **怎么处理**：明确拒跑并给可执行的下一步（"这台机器的安全策略不允许运行未签名脚本，请联系 IT 把本工具加入白名单，或改用 pwsh 7.6+"）。
  注意 **PowerShell 7.6 修了 AppLocker 回退逻辑**，所以 7 上的行为可能和 5.1 不同——两个引擎都要测。

#### D17 系统语言非中文/英文
- **会怎样**：`netstat` 的**表头和状态词是本地化的**——这是实测过的，不是推测。德语 Windows 上 `netstat -an` 的真实输出是：

  ```
  Proto  Lokale Adresse   Remoteadresse   Status
  TCP    192.168.1.7:139  0.0.0.0:0       ABHÖREN
  TCP    192.168.1.7:1031 192.168.11.25:139  HERGESTELLT
  TCP    192.168.1.7:1036 64.49.76.16:80  SCHLIESSEN_WARTEN
  ```

  也就是说 `LISTENING` → `ABHÖREN`、`ESTABLISHED` → `HERGESTELLT`、`CLOSE_WAIT` → `SCHLIESSEN_WARTEN`，**连表头都换了**（`Active Connections` → `Aktive Verbindungen`）。
  硬编码匹配 `LISTENING` → **一行都匹配不上** → 空数组 → 上层读成"本机没有端口在监听" → 判 off → **删掉用户的代理变量**。
- **怎么检测**：不检测语言。改用**宽松判据**：只数"这一行是不是 TCP 行"——协议列 `TCP`/`TCPv6`/`UDP` **不本地化**（德语输出里仍是 `TCP`），行尾不锚定，状态列不作为匹配条件。
- **怎么处理**：
  - 一条 TCP 行都没有 → **抛错**，返回"不知道"，不许返回空表；
  - 解析与取值分离（纯函数吃文本，测试直接喂德语/法语/俄语样本）；
  - `reg.exe`、`tasklist`、PowerShell 错误消息同样会本地化——**不要匹配任何本地化文本**，只读退出码和结构；
  - 日志时间格式用固定格式串，不依赖系统区域设置。
- **注**：这类 bug 在真实项目里出现过——某开源工具用 `findPidOnPort()` 在 netstat 输出里找 `LISTENING`，德语机打印 `ABHÖREN`、法语机打印 `ÉCOUTE`，功能直接失效。

#### D18 Windows PowerShell 被移除或禁用
- **会怎样**：要把三件事分开，混在一起会得出错误结论：
  1. **PowerShell 2.0 引擎**：2025 年 8 月起从 Windows 11 24H2 移除（Server 2025 从 2025 年 9 月，微软 servicing 公告 2025-08-11）。**对本工具无影响**，因为我们要求 5.1。
  2. **5.1 本身**：官方口径是"仍随 Windows 客户端与服务器默认安装，微软没有移除 5.1 的计划"。所以"5.1 被系统移除"**不是常态**，只发生在两种情况：第三方精简镜像（tiny11 一类）被人为删掉组件，或被安全策略禁用（`HKLM` 下的 PowerShell 策略、SRP、AppLocker 拒绝）。这两种才是真实风险，`.cmd` 里 `powershell -File` 会直接失败——用户看到窗口一闪而过。
  3. **只有 pwsh 7**：脚本要能在 7 上跑（大部分兼容，但编码默认值、`-UseBasicParsing`、`Get-FileHash` 的模块可用性有差异）。
- **怎么检测**：启动器先探测 5.1 是否存在、能否执行一个最小脚本；失败则探测 `pwsh`。
- **怎么处理**：两段式启动器，明确报错（"本机没有可用的 PowerShell，请安装 PowerShell 7 或修复系统组件"）。**不做**静默降级到 cmd——零依赖的边界不能破。**也不要**把"5.1 可能被删"当默认假设去写复杂降级逻辑：那是把小概率事件做成常态负担。

#### D19 macOS SIP / Gatekeeper / TCC
- **会怎样**：三层不同的问题，容易混为一谈：
  1. **SIP**：保护 `/System`、`/usr`、`/bin`、`/sbin`、`/var` 和预装 App，连 root 都改不了（Apple 签名且带特权的进程除外）。**本项目装在用户家目录，不受影响**——但如果有人把工具放进 `/usr/local` 之外的受保护路径就会失败。`/usr/local`、`/Applications`、`/Library` 是可写的。
  2. **Gatekeeper / 隔离属性**：从浏览器下载的 zip 解压后，里面的 `.command`、`.sh` 带 `com.apple.quarantine` 扩展属性 → 双击 `.command` 会被拦（"无法验证开发者"）。**这是安装路径上最常见的第一个坑**。
  3. **TCC（隐私权限）**：`~/Desktop`、`~/Documents`、`~/Downloads` 是受保护目录。如果用户把工具解压到 `~/Downloads`，然后 LaunchAgent 在登录时去读那个目录 → **没有 TCC 授权就读不到**，脚本静默失败。而且 TCC 授权是绑"发起进程的签名+路径"的，Homebrew 升级换了二进制路径后旧授权会"看着勾着但无效"。
- **怎么检测**：
  - 隔离属性：`xattr -p com.apple.quarantine <file>`；
  - TCC 落点：判断安装根是否落在受保护目录下（纯字符串判断即可）；
  - SIP：`csrutil status`（只进诊断页，不进热路径——那是外部进程）。
- **怎么处理**：
  - 安装时**拒绝**落在 TCC 保护目录，提示"请把这个文件夹移到 `~/` 下再装"（一句话解决，比教用户开 Full Disk Access 好得多）；
  - 安装脚本自己清隔离属性（`xattr -d`），或者在 README 里给出那一条命令；
  - 需要弹窗/AppleScript 的地方（本项目不需要）要预留"非交互环境没人点同意"的处理。

---

### E. 特殊情况

#### E20 便携版/绿色版，被复制到多处
- **会怎样**：两处副本各自有一份监控在跑，写同一份 `HKCU\Environment`：
  - 副本 A 写入 → 记录 owned（A 的路径）；
  - 副本 B 判 off → 看 owned 记录，"这值是我写的吗？"——如果记录在注册表里是共享的，B 会认为是自己写的（因为是同一份 HKCU 记录）→ 删掉；
  - 或者反过来：定位器按"日志活跃度"选新位置，两份日志都在写，活跃度打平 → 选择不稳定 → 每轮换一个"权威副本"。
- **怎么检测**：进程枚举 + 命令行识别（契约里已有"监控的身份只看实质：命令行结尾跑的是本脚本且没有子命令"）。
- **怎么处理**：**监控必须是全局单实例**（命名互斥体按产品+用户，不按路径）。第二份启动时直接退出。这比"杀别人的监控"安全得多——强杀会把对方正在写的注册表留在半截。

#### E21 安装在 OneDrive / 网络驱动器
- **会怎样**：
  1. **OneDrive Files On-Demand**：文件可能是"云端占位符"（dehydrated），本地只有元数据。读它会触发下载；离线时读失败。表现是"文件明明在，脚本报找不到"。
  2. **网络驱动器 / UNC 路径**：延迟高、可能断连；PowerShell 对来自 UNC 的脚本会按"Internet 区域"处理，`RemoteSigned` 策略下需要签名 → 直接拒跑。
  3. 两者都会让"每 2–3 秒一次"的监控主循环变慢，进而让去抖阈值失真。
- **怎么检测**：判断安装根的路径类型（UNC 前缀 `\\`、是否在 OneDrive 根下）；用一个小的读操作验证文件真的可读。
- **怎么处理**：**拒绝安装**并说明原因（"请放到本地磁盘"）。不要试图支持——延迟和离线是这类路径的本质属性，不是能修的 bug。

#### E22 磁盘空间满 / 路径超长（260 字符）
- **会怎样**：
  1. 磁盘满 → 日志写不进 → 如果写日志失败会抛异常，主循环整个崩掉 → 监控死了但没人知道；
  2. `monitor\` 目录建不出来 → `monitor.pid` 写不出来 → **进程还在干活，状态页却报"未运行"** → 用户再点安装 → 起第二份 → 被锁挡掉 → 用户彻底懵；
  3. 路径超长：Windows 默认 `MAX_PATH` 是 260 字符；从 Windows 10 1607 起可以开启长路径（注册表 `LongPathsEnabled=1`），但**还要求应用自身的清单声明 longPathAware**，两者缺一不可。所以"系统开了长路径"不等于"这个脚本能用长路径"。
- **怎么检测**：写日志前探测可写性（写一个小临时文件）；启动时校验安装根路径长度；目录不在就建（幂等）。
- **怎么处理**：
  - 日志写入失败**降级为丢弃**，绝不让它中断主循环；
  - 每轮开头确保运行时目录存在（契约已有）；
  - 安装前校验路径长度，超限就提示"换个短一点的路径"，不要指望长路径开关。

#### E23 系统时间被改
- **会怎样**：三种影响：
  1. **更新检查**：版本检查走 HTTPS，时钟错到证书有效期外 → TLS 校验失败 → 被归为 `network` 类失败。用户看到"网络连不上"，实际是时钟错了。这两者的排查方向完全相反。
  2. **日志**：时间戳跳变，事后无法按时间还原事件顺序。
  3. **去抖**：如果用墙上时钟算"两时刻相减"，向后跳会**永不再探测**，向前跳会**清零失败计数**。这是最隐蔽的一种。
- **怎么检测**：无法可靠检测"时钟对不对"（要对时就得联网，离线时无解）。但可以检测**单次运行内时钟跳变**：记录单调时钟与墙上时钟的差值，差值突变即判定"时钟被改"。
- **怎么处理**：一切"两时刻相减"用单调时钟（契约已有）；日志同时记单调值（相对启动的秒数）与墙上时间；更新失败分类里，把"证书时间无效"单独归一类或至少在文案里点一句"请检查系统时间"。**不要**因为时钟可疑就跳过更新——那会让被改时钟的机器永远收不到修复。

#### E24 断电 / 强制关机
- **会怎样**：最危险的一种"半成品状态"：
  1. 5 个变量写进去一部分就断电 → 半代理；
  2. owned 记录写了但变量没写（或反过来）→ 下次启动时"记录说这是我的，但值对不上" → 按严格规则会**不删**（保守），于是残留永久存在；
  3. `monitor.pid` 残留 → 启动时误判"已在运行"而退出，或误判"陈旧"而去接管一个已死的 PID（PID 还可能被别的程序复用）。
- **怎么检测**：启动时做一次**双向对账**：owned 记录里的每一项，去注册表里找；值相等 → 确认是我的；值不等或不存在 → 记录是孤儿，丢弃该条记录（不是丢弃变量）。反向：注册表里有回环值但没有记录 → 按"没有归属记录时一个都不动"处理。
- **怎么处理**：
  - 对账只在启动和安装/卸载时做，不进热路径；
  - pid 文件带"进程启动时间"一起写，接管前校验，避免 PID 复用误判；
  - 断电留下的半套变量，靠"整套同进同退"的回读校验在下一轮被发现并补齐或清理。

---

## 4. 这些结论对 EnvProxy 结构的实际含义

不是加 25 个 if，而是**五处结构性收敛**：

1. **单向数据流 + 回读验证**：任何"写"都必须配一次"读回来对"。写失败的路径要和写成功一样完整（回滚）。这一条同时兜住 EDR、磁盘满、断电、权限异常。
2. **所有权记录多一个维度（机器指纹）**：解决漫游；且记录与实值要能双向对账（解决断电）。
3. **一套"三态"贯穿到底**：`通` / `断` / `不知道`。所有失败路径落到"不知道"，而"不知道"的语义是**沿用上一状态、不动变量**。已有的 `unknown` 状态要扩展到所有层（探测、写入、广播、清理）。
4. **单实例锁按「产品 + 用户 SID」**，不按路径、不按会话。监控和安装操作各一把，都在 `Global\` 命名空间。这一条把 A3、E20 一起解决。
5. **"受管项"是一等公民**：GPO 覆盖的变量要被识别出来、从"整套"里剔除、在状态页单列。不剔除的话，"整套同进同退"会被一个管不住的变量拖死。

---

## 5. 来源

**微软官方（机制与契约）**
1. Environment Variables - Win32 apps — https://learn.microsoft.com/en-us/windows/win32/procthread/environment-variables
2. User Environment Variables - Win32 apps — https://learn.microsoft.com/en-us/windows/win32/shell/user-environment-variables
3. SendMessageTimeoutW function — https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendmessagetimeoutw
4. SendMessage function（UIPI 约束、HWND_BROADCAST）— https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendmessage
5. WM_SETTINGCHANGE message — https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-settingchange
6. Application Compatibility: Session 0 Isolation（跨会话消息不到达）— https://learn.microsoft.com/en-us/previous-versions/bb756986(v=msdn.10)
7. Applying Group Policy（默认 90 分钟刷新）— https://learn.microsoft.com/en-us/previous-versions/windows/desktop/Policy/applying-group-policy
8. Group Policy Environment preference extension — https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2008-R2-and-2008/cc770493(v=ws.11)
9. setx（1024 字符截断、REG_EXPAND_SZ 被展开）— https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/setx
10. netstat — https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/netstat
11. Maximum Path Length Limitation — https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation
12. No Environment Change Notification when Reboot Required — https://devblogs.microsoft.com/setup/no-environment-change-notification-when-reboot-required/

**代理环境变量语义**
13. Proxy environment variables — everything curl（`http_proxy` 只认小写的原因、`ALL_PROXY`、`NO_PROXY`）— https://everything.curl.dev/usingcurl/proxies/env.html
14. libcurl-env(3) — https://manpages.debian.org/testing/libcurl4-doc/libcurl-env.3.en.html
15. Go issue: HTTP_PROXY / http_proxy 优先级不一致（跨实现差异）— https://github.com/golang/go/issues/79656
16. Python issue 26804: 小写代理变量优先 — https://bugs.python.org/issue26804

**漫游配置文件与配置文件本质**
17. Raymond Chen: 漫游用户配置文件对程序员的含义（ntuser.dat 就是每用户注册表；缓存副本的修改会丢失）— https://blogs.msdn.microsoft.com/oldnewthing/20050630-20/
18. Roaming user profiles on Windows 8/Server 2012 incompatible（配置文件版本隔离与损坏）— https://support.microsoft.com/en-us/kb/2887239
19. Mandatory user profiles（ntuser.man 优先于 ntuser.dat，改动在注销时丢弃）— https://sploitus.com/exploit?id=PACKETSTORM:199583

**PowerShell / 应用控制**
20. PowerShell 2.0 removal from Windows（微软 servicing 公告，2025-08-11）— https://support.microsoft.com/en-us/servicing/os/windows/docs/2025/08/powershell-2-0-removal-from-windows
21. PowerShell 5.1 vs PowerShell 7（5.1 仍随 Windows 默认安装、无移除计划；7 独立并行安装）— https://activedirectorypro.com/update-powershell-version/
22. Windows 11 24H2: PowerShell AppLocker/WDAC Script Enforcement was broken for months — https://borncity.com/win/2025/06/02/windows-11-24h2-powershell-applocker-wdac-script-enforcement-was-broken-for-months/
23. Exploiting PowerShell code injection（ConstrainedLanguage 的实际约束：Add-Type 禁用、.NET 白名单）— http://www.exploit-monday.com/2017/08/exploiting-powershell-code-injection.html
24. How can I tell if AppLocker is enforcing Constrained Mode — https://learn.microsoft.com/en-us/answers/questions/1835360/how-can-i-tell-if-applocker-is-enforcing-constrain

**macOS**
25. macOS bash 3.2 与 GPLv3（为什么 Apple 不升级）— https://apple.stackexchange.com/questions/345847/is-macos-mostly-closed-source
26. launchctl setenv 重启后丢失 / GUI app 从 per-user launchd 继承 — https://apple.stackexchange.com/questions/63662/how-to-change-path-environment-variable-to-os-x-10-8-mountain-lion-that-will-be
27. System Integrity Protection 保护范围（/System /usr /bin /sbin /var；可写 /usr/local、/Applications）— https://www.kolide.com/features/checks/mac-system-integrity-protection
28. TCC：Automation 授权、非交互 runner 必须预先授权、macOS 大版本升级会掉授权 — https://techearl.com/mac-dark-mode-command-line
29. Full Disk Access 与 helper 二进制路径漂移导致 TCC 授权"看着有其实无效" — https://nodemac.com/en/blog/articles/openclaw-macos-tcc-screen-recording-automation-permission-regression-matrix-m4-2026.html

**连接语义（拒绝 vs 超时）**
30. Connection Refused vs Timed Out（RST 是明确否定；超时是"没有证据"）— https://oneuptime.com/blog/post/2026-07-28-connection-refused-vs-connection-timed-out/view
31. TIME_WAIT 状态说明（关闭后的等待态，不接受新连接）— https://www.yougetsignal.com/library/time-wait-state-idoy6cu

**本地化解析**
32. Parsing the output of Windows commands on non-English versions — https://superuser.com/questions/1098461/parsing-the-output-of-windows-commands-on-non-english-versions
33. Converting string output to objects（netstat 表头结构、IPv6 方括号、状态列）— https://devblogs.microsoft.com/powershell-community/converting-string-output-to-objects/
34. 德语 Windows 上 netstat 的真实输出（`ABHÖREN` / `HERGESTELLT` / `SCHLIESSEN_WARTEN`，表头同时本地化）— https://www.nwlab.net/tutorials/netstat/offene-ports-netstat.html
35. 真实项目记录：`findPidOnPort()` 硬编码 `LISTENING`，德语机打印 `ABHÖREN`、法语机打印 `ÉCOUTE` — https://github.com/bassprofressor-lab/openwolf-enhanced/blob/main/CHANGELOG.md

**企业代理与 GPO 冲突**
36. DefaultConnectionSettings 二进制值格式（只改 ProxyEnable 不生效）— https://stackoverflow.com/questions/4283027/whats-the-format-of-the-defaultconnectionsettings-value-in-the-windows-registry
37. GPO 反复覆盖用户手改的代理设置（真实运维事故帖）— https://forum.level1techs.com/t/windows-proxy-settings-registry-group-policy-defaultconnectionsettings-binary-value-is-changed-after-reboot/168935
38. Group Policy Preferences 动作模式（Create/Replace/Update/Delete，默认 Update）— https://programming4.us/desktop/22898.aspx
39. GPP 默认在每次策略刷新重新应用；"仅应用一次不再重新应用"的用途 — https://programming4.us/desktop/24606.aspx
