# ------------------------------------------------------------------------------
#  base.sh — 基础层：契约常量、纯函数助手
#  由入口 envproxy.sh 按固定顺序 source 加载，不单独运行。
#  本层必须加载期安全（无顶层副作用），自检只 source 这一层。
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# 0. 路径与常量（全部动态推导，不写死用户名/磁盘）
# ------------------------------------------------------------------------------

ENVPROXY_HOME="${ENVPROXY_HOME:-$HOME/.envproxy}"
# 安装记录（只有安装时写、卸载时删）。住在 base 而不是 runtime：
# base 层的 has_install_record 要读它，而 base 先于 runtime 加载——
# 放在 runtime 会让"装过没装过"在 base 层被读成"没装过"（空路径 → [ -f "" ] 为假），
# 于是首次安装判据永远成立，使用者自己设的本机代理会被当成本工具残留删掉。
# 它只由 ENVPROXY_HOME 派生，天然属于这一层。
PATH_CONF="$ENVPROXY_HOME/path.conf"

# 运行时目录与日志文件：住在 base 而不是 runtime，理由是 log_msg 必须在这里。
# 写日志是横切能力：env / probe / runtime 三层都要写，任何一层都不该"反过来"
# 依赖另一层去拿它。
#
# **但派生它的 SCRIPT_DIR 只有入口才有**（契约：只有入口能回答"这个程序在哪里"）。
# 在加载期就算，等于让 base 层依赖一个自己还没有的值：单独 `. ./mac/lib/base.sh`
# 时直接报 `SCRIPT_DIR: unbound variable`（set -u 下当场崩）。
# 这里改成**惰性**：两个变量只在 SCRIPT_DIR 已经存在时立刻算好（正常运行时
# 入口早就发布过了，行为与以前完全一致）；否则留空，由 ensure_monitor_paths
# 在真正需要路径的地方现算。
if [ -n "${SCRIPT_DIR:-}" ]; then
    MONITOR_DIR="$SCRIPT_DIR/monitor"
    LOG_FILE="$MONITOR_DIR/monitor.log"
fi

# 幂等地补上两个路径变量。SCRIPT_DIR 还没有时什么都不做并返回 1——
# 调用方那时也不该用到路径（库里任何函数被调用时，入口必然已经发布过位置）。
ensure_monitor_paths() {
    if [ -n "${MONITOR_DIR:-}" ] && [ -n "${LOG_FILE:-}" ]; then return 0; fi
    [ -n "${SCRIPT_DIR:-}" ] || return 1
    MONITOR_DIR="$SCRIPT_DIR/monitor"
    LOG_FILE="$MONITOR_DIR/monitor.log"
    return 0
}

# 写一行监控日志（带时间戳），并在超过上限时截尾。
# 放在 base 层是为了断开一条真环：probe/env 要写日志 → runtime；runtime 又要读
# env 的变量状态、probe 的判定结论 → 回到 probe/env。三层互相依赖时，
# 单独读任何一份文件都看不出它需要什么，改动一处会在另一处炸。
log_msg() {
    ensure_monitor_paths || return 0
    mkdir -p "$MONITOR_DIR" 2>/dev/null || true
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || return 0
    _size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    _size=$(printf '%s' "$_size" | tr -cd '0-9')
    if [ -n "$_size" ] && [ "$_size" -gt "$LOG_MAX_BYTES" ] 2>/dev/null; then
        tail -n "$LOG_TAIL_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || rm -f "$LOG_FILE.tmp" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# 2. 安装根与项目身份（纯查询，不联网、不写文件）
# ------------------------------------------------------------------------------
# 为什么这一组住在 base：它们只回答"这是哪个目录、这是哪个仓库"，
# 是 update / ops / 帮助页共同的输入。原来它们住在 update 层，ops 要用就得反向引用，
# update 又要调 ops 的安装收尾——于是两层互相依赖，谁也不能单独读懂。
# 判定"是不是开发副本"是环境事实，与"要不要更新"是两件事，不该绑在一起。
# 调用方传目录则判该目录（自检用），不传就判安装根。
UPDATE_REPO_DEFAULT="FiretrUCK666/envproxy"
# 更新源表：每行一条，字段依次是 Id / Name / Preferred / Api / Web / Base / ApiRepo。
# @@ 是仓库标识的占位符，**加源 = 表里加一行**，不改代码逻辑。
# 住在 base 而不是 update：两侧同层，且 get_project_home 这类"项目地址"函数
# 也要从这里派生——放上层会让 base 反过来引用 update（加载顺序一旦变了就静默失效）。
UPDATE_SOURCE_TABLE='official GitHub Api https://api.github.com/repos/@@/releases/latest https://github.com/@@/releases/latest https://github.com/@@ https://api.github.com/repos/@@'

get_project_root() {
    dirname "$SCRIPT_DIR"
}

is_dev_copy() {
    [ -e "$(get_project_root)/.git" ]
}

# 源码包：有 .github、无 .git（多见于删掉了 .git 的克隆，或很早以前下载的旧包；
# 现在网页上下载的包已不再含这些文件，见 README 第 8 节）。
# 安装包里永远没有 .github（打包配置排除），用户自己也不会建这个目录，认它零误伤。
# 传参则判指定目录（自检用），不传判安装根。
is_source_copy() {
    _sr="${1:-$(get_project_root)}"
    [ ! -e "$_sr/.git" ] && [ -d "$_sr/.github" ]
}

# 从 git 远程地址里取出 "owner/repo"（纯函数）。
# 认的写法一视同仁：https://github.com/owner/repo、git@github.com:owner/repo、
# ssh://git@ssh.github.com:443/owner/repo——仓库标识永远是路径的最后两段，与协议、主机、
# 端口、有没有 .git 后缀无关，所以按"最后两段"取，而不是按某一种写法的长相去套。
# 不许用 ".*github\.com[:/]([^/]+)/([^/]+)" 这种贪婪正则：ssh://git@ssh.github.com:443/owner/repo
# 里 github.com 后面紧跟的是端口，第一段就抓成了 443，仓库标识跟着变成 "443/owner"，
# 查询地址全错，最后报出来的是"发布方没提供安装包，请手动下载"——把用户支到错的下一步。
# 主机不是 GitHub 时输出空串，让调用方退回内置默认。
repo_id_from_remote_url() {
    [ -n "$1" ] || return 0
    # scp 写法 git@host:owner/repo 里主机与路径之间是冒号而不是斜杠，先换成斜杠。
    # 只认"@ 后面到第一个 : 之前没有斜杠"这一种，别误伤 ssh:// 里的端口。
    printf '%s' "$1" \
        | sed -E 's#^([^/]+@[^/:]+):#\1/#; s#[?#].*$##; s#/+$##; s#\.git$##' \
        | awk -F/ '{
              n = NF
              if (n < 3) exit
              host = $(n - 2)
              sub(/^.*@/, "", host)
              sub(/:[0-9]+$/, "", host)
              if (host != "github.com" && host !~ /[.]github[.]com$/) exit
              if ($(n - 1) == "" || $n == "") exit
              printf "%s/%s", $(n - 1), $n
          }'
}

# 开发副本跟自己的 git remote 走（fork 后看得到自己仓库的 Release）；安装副本用内置默认。
get_update_repo() {
    if is_dev_copy && command -v git >/dev/null 2>&1; then
        _u=$(git -C "$(get_project_root)" config --get remote.origin.url 2>/dev/null || true)
        _r=$(repo_id_from_remote_url "$_u")
        if [ -n "$_r" ]; then printf '%s' "$_r"; return 0; fi
    fi
    printf '%s' "$UPDATE_REPO_DEFAULT"
}

# 项目对外地址：主页、提问题的地方。与 Windows 侧 Get-ProjectUrls 同形。
#
# 从官网源的 Base 派生而不是各写一份：地址换了只改 UPDATE_SOURCE_TABLE 那一行，
# 帮助、报告全跟着变。各写一份的结果是"帮助里还指着旧仓库"，用户点了打不开，
# 也没有任何报错告诉他为什么。
get_project_home() {
    _gph_repo=$(get_update_repo)
    [ -n "$_gph_repo" ] || return 1
    printf "https://github.com/%s" "$_gph_repo"
}

get_project_issues() {
    _gpi_home=$(get_project_home) || return 1
    printf "%s/issues/new" "$_gpi_home"
}
# 本地版本号：读安装根的 VERSION。读不到就失败（不是返回空串——
# 空串会被上层当成"版本是空的"，比较结果全错，还会报"已是最新"）。
get_local_version() {
    _vf="$(get_project_root)/VERSION"
    [ -f "$_vf" ] || return 1
    tr -d ' \t\r\n' < "$_vf" 2>/dev/null
}

# ------------------------------------------------------------------------------
# 2. 环境变量读写（终端路 proxy.env + GUI 路 launchctl，双路同进同退）
# ------------------------------------------------------------------------------
# 本机地址直连的默认例外集，写法遵循 NO_PROXY 的通行规范：IPv6 地址**裸写**。
# 裸写是各家的共同要求——httpx 的规范示例就是 `NO_PROXY=example.com,::1,localhost,...`，
# 而且它会自己给 IPv6 补上方括号去构造内部模式；预先写成 `[::1]` 会被当成普通域名，
# 生成非法模式，反而让每一次请求都抛 `InvalidURL: Invalid port: ':1]'`。
# 也就是说方括号属于 URL 字面量的写法，在 NO_PROXY 里是写错了位置。
DEFAULT_NO_PROXY="localhost,127.0.0.1,::1"

# 终端同步要检查/写入/摘除的那些 shell 配置文件。
#
# **写成函数，不写成常量**：常量在 source 那一刻就把 $HOME 固化进去了。
# 自检会把 HOME 改道到沙箱，固化过的名单仍然指向使用者的真实家目录——
# 那等于自检去动真实环境（曾经就是这样：断言红在一个与改动无关的用例上，
# 而真实原因是它操作了错误的文件）。
#
# 三个调用方（状态页 / 安装 / 卸载）必须共用这一份，各写一份必然漂移：
# 曾经状态页只看 `.zshrc` 系列、安装实际写 `.zshenv`，只装了 `.zshenv` 的用户
# 状态页会报"配置文件里没有同步块"，照它说的重装一遍也修不好。
#
# 为什么是这几个：zsh 的 `.zshenv` 在**所有** shell 类型下都会加载（登录、交互、
# 脚本、ssh 远程命令），`.zshrc` 只在交互式下加载；bash 侧用 `.bash_profile`
# 与 `.bashrc`。`.zprofile` / `.zlogin` 列进来是为了认出"早期版本可能写过的位置"——
# 装过老版本的用户那里可能还留着块，摘除时要找得到。
rc_check_files() {
    printf '%s\n' \
        "$HOME/.zshenv" "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zlogin" \
        "$HOME/.bash_profile" "$HOME/.bashrc"
}

# 安装真正写入的落点，按 shell 分两组：zsh 侧 `touch` 建（缺了就建），
# bash 侧只在文件已存在时写（不替使用者造 `.bash_profile` 那种会干扰他既有配置的文件）。
rc_zsh_files() {
    printf '%s\n' "$HOME/.zshenv" "$HOME/.zshrc"
}

rc_bash_files() {
    printf '%s\n' "$HOME/.bash_profile" "$HOME/.bashrc"
}

# 帮助每一屏的行数上限。超过这个数，终端会把底部的「怎么退出」切掉——
# 用户会以为帮助卡死，其实只是没画出来。与 Windows 侧 $HelpMaxLines 必须一致。
# 依据同那边：量的是整屏输出（含标题与结尾导航），正文实际只有 27 行。
HELP_MAX_LINES=40

# ESC 字符：所有 ANSI 序列都从它开始。写成变量而不是每个地方敲一次，读起来才看得懂。
_ESC=$(printf '\033')
# ---- 屏幕渲染层的常量（Windows 侧同名同义，值可不同）----
# 最小可用终端：宽度不够时一折行就认不出「标签 : 内容」的结构，宁可不刷新。
SCREEN_MIN_WIDTH=40
# 最小可用高度：低于这个数，状态页连正文都放不下，只能靠裁剪硬塞，不如退回静态。
SCREEN_MIN_HEIGHT=20
# 内容区下方要留的行数：一行给「按 0 返回」的提示，一行给光标。
SCREEN_BOTTOM_MARGIN=2
# 「等一小会儿看有没有按键」的轮询粒度（秒）。
# DIVERGE(Mac): bash 3.2 的 read -t 只认整数秒（Apple 的 read.def 里走 alarm()），
#   没有亚秒超时，所以这里是 1 秒；Windows 侧是 150 毫秒。差异只在按键手感，
#   行为语义（按 0/q/Esc 退出、其余忽略）完全相同。
SCREEN_POLL_SEC=1
# 状态页自己刷新的间隔（秒）。与监控的探测节奏（2-3 秒）对齐，不做智能变速。
STATUS_REFRESH_SEC=2

# 日志体积上限与截断后保留的行数。写成具名常量而不是散在代码里的 204800 / 200：
# 文档里印着这两个数，两侧也各写了一遍，散着放就一定会有一天改一处漏一处。
# 与 Windows 侧 $LogMaxBytes / $LogTailLines 同口径，门禁 6 核对。
LOG_MAX_BYTES=204800
LOG_TAIL_LINES=200

# ------------------------------------------------------------------------------
# 显示宽度：唯一判据 _dw_walk（走一遍字节，给出宽度与"到哪个字节为止还放得下"）
# ------------------------------------------------------------------------------
# 所有需要对齐的地方（菜单、帮助的两列、安装提示、日志裁剪）都走这里：
# 写第二份就会有一天两份算出两个宽度，屏幕上看就是"某一屏的表格歪了"。
# 放在 base 层而不是 ops：帮助与菜单都要用它，而 ops 里的定义顺序会随编辑变化。
#
# 判据与 Windows 侧 Get-CharWidth 同一条：码位 > U+2E80 记两格。
# UTF-8 下等价于"3 字节序列且（首字节 > 0xE2，或首字节 = 0xE2 且第二字节 >= 0xBA）"；
# 4 字节序列（补充平面）码位必然 > U+2E80，也记两格。
#
# 为什么整行只开一次 od、之后纯算术：这个遍历被 _truncate_width 按字符反复调用过，
# 每次调用都 fork 一次 od——实测一条 80 列的中文日志行在 Git Bash 上要 4-8 秒。
# 整行一次性转成十六进制文本之后，解码全靠 $(( )) 与 ${var:i:n}，
# 与 shell 版本、locale 都无关（od 的输出恒为 ASCII）。
#
# 为什么要一次性算出"截到第几个字节"：_truncate_width 需要两个断点——
# "宽度不超过 max"与"宽度不超过 max-1"（后者给省略号腾一格）。一次遍历同时记下，
# 免得为了第二个断点把 od 再开一遍。
#
# 输出（调用方直接读这几个全局，不开子 shell）：
#   DW_W      这一段文字的总显示宽度
#   DW_BYTES  总字节数
#   DW_END    累计宽度首次达到 _dw_walk 的 $2 时的字节位置
#   DW_END1   累计宽度首次达到 ($2 - 1) 时的字节位置
# $2 < 0 表示只要总宽度，两个断点不记。
#
# 这个函数的结论必须在 GNU bash 5 与 macOS bash 3.2 上**逐字符相同**，
# 否则菜单与帮助的两列表格只在 Mac 上歪，而开发机复现不出来。踩过的坑：
#   ① printf -v '%d' "'$ch" 取字节值：3.2 对多字节字节返回 < 128，
#      整个函数退化成"按字节数算宽度"（「中」3 格、「…」3 格）；
#   ② case [$'\001'-$'\177'] 区间模式：3.2 对 case 里的 ANSI-C 引用
#      支持不完整，报 syntax error near ';;'。
# 所以只用 od 取字节，之后的解码是纯算术。
#
# ANSI 颜色序列不占格子——终端把它当控制指令执行，屏幕上不留宽度。
# 与 Windows 侧 Get-DisplayWidth 的剥除判据同形（那边是一条正则，这里是同一套
# CSI 语法的手工扫描）：不剥掉就会把 ESC[36m 这类序列也算进去，一行 34 格的
# 标题被算成 51 格，于是"这帧太宽画不下"而白白降级，日志裁剪也会截短。
_dw_walk() {
    _dw_s="$1"
    _dw_soft="$2"
    DW_W=0
    DW_BYTES=0
    DW_END=0
    DW_END1=0
    [ -n "$_dw_s" ] || return 0
    _dw_hex=$(printf '%s' "$_dw_s" | od -An -tx1 -v)
    _dw_hex="${_dw_hex//[[:space:]]/}"
    # _dw_n 是十六进制字符数，恒等于字节数 × 2（od 的输出是纯 ASCII）。
    _dw_n=${#_dw_hex}
    _dw_i=0
    while [ "$_dw_i" -lt "$_dw_n" ]; do
        _dw_b=$((16#${_dw_hex:$_dw_i:2}))
        if [ "$_dw_b" -eq 27 ] && [ $((_dw_i + 4)) -le "$_dw_n" ]; then
            # ESC [ …… 末字节（0x40..0x7E）：整段零宽，一个像素都不占。
            _dw_b2=$((16#${_dw_hex:$((_dw_i + 2)):2}))
            if [ "$_dw_b2" -eq 91 ]; then
                _dw_i=$((_dw_i + 4))
                while [ "$_dw_i" -lt "$_dw_n" ]; do
                    _dw_b2=$((16#${_dw_hex:$_dw_i:2}))
                    _dw_i=$((_dw_i + 2))
                    if [ "$_dw_b2" -ge 64 ] && [ "$_dw_b2" -le 126 ]; then break; fi
                done
                _dw_w=0
                DW_BYTES=$((_dw_i / 2))
                continue
            fi
        fi
        if [ "$_dw_b" -lt 128 ]; then
            _dw_w=1; _dw_i=$((_dw_i + 2))
        elif [ "$_dw_b" -lt 224 ]; then
            _dw_w=1; _dw_i=$((_dw_i + 4))
        elif [ "$_dw_b" -lt 240 ]; then
            _dw_b2=0
            if [ "$_dw_b" -eq 226 ] && [ $((_dw_i + 4)) -le "$_dw_n" ]; then
                _dw_b2=$((16#${_dw_hex:$((_dw_i + 2)):2}))
            fi
            if [ "$_dw_b" -gt 226 ] || { [ "$_dw_b" -eq 226 ] && [ "$_dw_b2" -ge 186 ]; }; then
                _dw_w=2
            else
                _dw_w=1
            fi
            _dw_i=$((_dw_i + 6))
        else
            # 4 字节序列（补充平面）。推进量必须是 4：按 3 推进会把一个字符
            # 剩下一字节留给下一轮，截断点落在字符中间，输出就不是合法 UTF-8
            # （实测：😀 后面跟中文时会被劈开，屏幕上是一个乱码方块）。
            _dw_w=2; _dw_i=$((_dw_i + 8))
        fi
        DW_W=$((DW_W + _dw_w))
        DW_BYTES=$((_dw_i / 2))
        if [ "$DW_W" -le "$_dw_soft" ]; then DW_END=$DW_BYTES; fi
        if [ "$DW_W" -le $((_dw_soft - 1)) ]; then DW_END1=$DW_BYTES; fi
    done
    # 循环里只按"每加完一个可见字符"更新断点，整段都是转义序列时两个断点会留在 0。
    # 收尾再确认一次：总宽度已经放得下就等于"整段都放得下"，断点落在末尾。
    if [ "$DW_W" -le "$_dw_soft" ]; then DW_END=$DW_BYTES; fi
    return 0
}

# 一段文字在终端里占几格。
# 返回总宽度；这里是唯一的"宽度怎么算"实现，别处一律调它。
_display_width() {
    _dw_walk "$1" -1
    printf '%s' "$DW_W"
}

# 把文字补齐到指定宽度（按上面的显示宽度算）。
_menu_cell_pad() {
    _mcp_text="$1"
    _mcp_width="$2"
    _mcp_len=$(_display_width "$_mcp_text")
    _mcp_pad=$((_mcp_width - _mcp_len))
    [ "$_mcp_pad" -lt 0 ] && _mcp_pad=0
    printf '%s%*s' "$_mcp_text" "$_mcp_pad" ''
}
# 这个地址是不是指向本机回环。
# 它问的是"这个**目标**在本机吗"，用来决定要不要经代理去取；
# 与归属判定那条（"这个代理值是不是我们写的本机地址"）不是一个问题，不共用函数。
# 判据认全三种写法：127.0.0.1、[::1]、localhost。
# 给回环地址设代理没有意义——代理那次请求的主机名仍是回环，看的是代理进程
# 自己那一侧，只会让"本机服务"看起来忽好忽坏。
# 判据与 Windows 侧 Test-LoopbackUrl 必须**逐例同结论**（自检拿同一张表两侧各跑一遍）：
# 它的用途是"这个地址要不要经代理去取"，两侧结论不同就成了行为分叉。
# 所以这里做的是同一个 URI 解析，不是逐字面量比对——
# 逐字面量会把 http://LOCALHOST:7890、user:pw@localhost、127.0.0.2 判成"不是回环"，
# 而 Windows 的 [System.Uri] 认整个 127.0.0.0/8、会把 host 归一成小写、会剥掉 UserInfo。
# 输出一个字段：host（小写、去掉方括号与端口、去掉 userinfo）。解析不出来就输出空。
_url_host() {
    _uh_u="$1"
    case "$_uh_u" in
        *://*) _uh_u="${_uh_u#*://}" ;;
    esac
    _uh_u="${_uh_u%%/*}"
    _uh_u="${_uh_u%%\?*}"
    _uh_u="${_uh_u%%#*}"
    # userinfo：最后一个 @ 之后才是主机（密码里可能有 @）
    case "$_uh_u" in
        *@*) _uh_u="${_uh_u##*@}" ;;
    esac
    case "$_uh_u" in
        '['*)
            # 方括号 IPv6：[::1]:7078 —— 取方括号里的内容。
            # 不能用 %%:* 截端口：它会在第一个冒号处切断，"[::1]" 变成 "["。
            _uh_u="${_uh_u#[}"
            _uh_u="${_uh_u%%]*}"
            ;;
        *)
            # 没有方括号：最后一个冒号之后是端口（也覆盖 :::1 这种畸形写法）
            case "$_uh_u" in
                *:*) _uh_u="${_uh_u%%:*}" ;;
            esac
            ;;
    esac
    # Windows 的 URI 解析把 host 归一成小写，这里跟上
    printf '%s' "$_uh_u" | tr '[:upper:]' '[:lower:]'
}

is_loopback_url() {
    [ -n "${1:-}" ] || return 1
    _ilu_host=$(_url_host "$1")
    [ -n "$_ilu_host" ] || return 1
    # 127.0.0.0/8 整段都算回环：Windows 的 Uri.IsLoopback 就这么判，只认 127.0.0.1 会分叉。
    case "$_ilu_host" in
        127.*|localhost|::1) return 0 ;;
    esac
    return 1
}

# 从标准输入读若干行，输出其中最大的显示宽度。
# 五处「求一列里最宽的名字」原来是同一形状各写一遍（安装提示列、菜单名字列、
# 帮助两列、帮助名字列），只有变量前缀不同。收敛成一处之后，
# 「宽度怎么算」只有 _display_width 一个答案，改它不会漏掉某一屏。
_max_width_of() {
    _mwo_w=0
    while IFS= read -r _mwo_l; do
        _mwo_n=$(_display_width "$_mwo_l")
        [ "$_mwo_n" -gt "$_mwo_w" ] && _mwo_w="$_mwo_n"
    done
    printf '%s' "$_mwo_w"
}

# 把一段文字按终端显示宽度截断，超出时补省略号。
# 返回的字符串加上省略号之后**不会超过** $2 格——与 Windows 侧 Limit-DisplayText
# 同一条判据：截到 max-1，最后补一个占 1 格的…。若按"截到 max 再补…"算，
# 实际宽度是 max+1：日志行正好顶满终端宽度而触发自动折行，
# 而状态页是按绝对行号画的（write_screen_frame），折行会把后面每一行往下推。
#
# 必须按字符走而不是按字节切：中文占两格，按字节切会把一个汉字切成半个，
# 屏幕上就是乱码。判据与 _display_width 同一套（就是它底下的 _dw_walk），
# 只走一遍字节、只开一次 od，两个断点一起算出来。
#
# 为什么 LC_ALL=C 要写成 local：不写 local 时它会把**调用方**的 locale 改掉。
# 实测：调用方 LC_ALL=C.UTF-8，调完这个函数变成 C，同一 shell 里之后所有
# ${#x} 从"字符数"变成"字节数"，两列表格按字节数对齐就会歪。
# 写成 local 之后作用域跟着函数走，退出即还原（bash 3.2 支持 local）。
_truncate_width() {
    local LC_ALL=C
    _tw_s="$1"
    _tw_max="$2"
    # 上限小于 1 时没有位置放内容；给个省略号比给空串更说明"这里被截了"。
    if [ "$_tw_max" -le 0 ]; then printf '%s' "$_tw_s"; return 0; fi
    _dw_walk "$_tw_s" "$_tw_max"
    if [ "$DW_END" -eq "$DW_BYTES" ]; then
        # 整段都放得下（含空串）：原样返回，不加省略号。
        printf '%s' "$_tw_s"
        return 0
    fi
    printf '%s…' "${_tw_s:0:$DW_END1}"
}

# 配色分两层：角色 -> 颜色名 -> 本平台怎么写。
#
# 为什么要多这一层名字：两侧写颜色的方式毫无共同语言（Windows 侧是 [ConsoleColor]
# 枚举，这里是 ANSI 数字），于是"两端口径一致"只能靠人记得住，门禁也只比得了角色名、
# 一个颜色都比不了——实测就这么放过去一次：`cmd` 从绿改成了青，命令与标题同色，
# 用户在屏幕上一眼分不清，两侧门禁却全绿。多这一层之后，两侧共享的是颜色名，
# 门禁直接比颜色名，"换个颜色只改一处"和"两侧不许分叉"才同时成立。
# 颜色名 -> ANSI 前景色码。
# 颜色名清单：与上面 case 的分支一一对应（自检核对"每个角色的颜色名都在里面"）。
# 写在映射函数旁边，因为这就是那张表的目录；挪到别处放就会漂。
STYLE_COLOR_NAMES="cyan brightwhite green yellow darkgray none"

style_code_of_name() {
    case "$1" in
        cyan)        echo "96" ;;
        brightwhite) echo "97" ;;
        green)       echo "92" ;;
        yellow)      echo "93" ;;
        darkgray)    echo "90" ;;
        *)           echo "" ;;
    esac
}

# 角色 -> 颜色名，一条记录一个角色（空格分隔）。
# cmd 必须是绿色，且不许与其余任何角色同色：屏幕上的绿色就是"这一整行能复制去跑"。
# 用户每换一屏都要重新认这件事，所以它是可读性问题，不是审美问题。
# 门禁 6 与两侧自检都钉住这两条，改色当场红。
STYLE_MAP="title:cyan heading:cyan item:brightwhite key:brightwhite value:brightwhite cmd:green ok:green warn:yellow dim:darkgray text:none"
# 角色名清单从表里派生，不另抄一份（抄一份就会有一天两边不一样）。
STYLE_ROLES=""
for _sr_rec in $STYLE_MAP; do
    STYLE_ROLES="$STYLE_ROLES ${_sr_rec%%:*}"
done
STYLE_ROLES="${STYLE_ROLES# }"
unset _sr_rec

# 角色 -> 颜色名。没声明的角色一律按 none（不写颜色），不报错也不乱猜。
style_color_of_role() {
    case " $STYLE_MAP " in
        *" $1:"*) ;;
        *) echo "none"; return 0 ;;
    esac
    for _scr_rec in $STYLE_MAP; do
        case "$_scr_rec" in
            "$1":*) echo "${_scr_rec#*:}"; unset _scr_rec; return 0 ;;
        esac
    done
    unset _scr_rec
    echo "none"
}

# 角色 -> ANSI 码。渲染只认这一处，别处不许再写颜色字面量。
style_color() {
    style_code_of_name "$(style_color_of_role "$1")"
}
# 按角色输出一行。所有给人看的文字都走这里，于是"换个颜色"只要改上面那张表。
# stdout 不是终端时不上色：转义序列会原样写进日志（实测 ^[[36m），既弄脏日志也没法看。
style_out() {
    _so_role="$1"; shift
    if [ ! -t 1 ]; then printf '%s\n' "$*"; return 0; fi
    _so_c=$(style_color "$_so_role")
    if [ -z "$_so_c" ]; then printf '%s\n' "$*"; else printf '\033[%sm%s\033[0m\n' "$_so_c" "$*"; fi
    return 0
}

# 变量事实源（写/核/收/判四处共用，口径不再分家）：代理变量 6 个（大小写双写）
# + NO_PROXY 双写 + 哨兵 1 个，归属一律按"本机地址才是我们写下的"判定。
OWNED_HTTP_PREFIX="http://127.0.0.1:"
# 注入端按"实际能连上的那个地址"拼 URL：只绑 ::1 的代理在 IPv4 上主动拒绝，
# 所以注入值可能是 http://[::1]:port。形状判据必须同时认这两种，
# 只认 127.0.0.1 的话 IPv6 注入的值会被判成"不是我们的"，既清不掉也认不出。
OWNED_HTTP6_PREFIX="http://[::1]:"

# ------------------------------------------------------------------------------
# 变量名的**唯一权威处**（与 Win 侧 $ProxyVarNames 同地位）。
# 为什么要表：名字手抄在各处就会漂移——漏一个变量的后果是"清不干净"，
# 而它只在特定操作下才暴露（用户以为固定直连了，curl 却还在走代理）。
# 新增/改名变量时**只改这里**，写入、核对、回收、归属记录都遍历它。
# DIVERGE(Mac): 9 个——5 个规范拼写 + 4 个小写拼写。macOS 的变量名真大小写敏感，
#   有的工具只认小写；Windows 命名空间大小写不敏感，写小写只会互相覆盖，故那边只有 5 个。
# 顺序即写入顺序：大写在前、小写紧随其后，NO_PROXY 归到中间那一组之后。
PROXY_VAR_NAMES="HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy NODE_USE_ENV_PROXY"
# 走代理地址的那 6 个（不含 NO_PROXY / NODE_USE_ENV_PROXY：它们的值不是代理地址）
PROXY_ADDR_VAR_NAMES="HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy"
# NO_PROXY 的两个拼写（值是例外清单，回收规则与地址变量不同）
NO_PROXY_VAR_NAMES="NO_PROXY no_proxy"

# 这台机器上装过没有——**唯一权威处**。判据是安装时写下的路径记录（PATH_CONF），
# 它只在安装时写、卸载时删。
#
# 为什么必须只留一处：它决定"本机地址的代理变量算谁的"。安装侧当作首次安装时，
# 那些值会被认成使用者自己的（不删）；状态页判断"还没装过"时，措辞是"按 1 就好"
# 而不是故障语气。两处各写一份、演化时分叉，表现就是使用者自己设的 mitmproxy
# 被当成本工具残留删掉，而且没有快照可还原。
has_install_record() {
    [ -f "$PATH_CONF" ]
}

# 直连调 curl：把本工具可能设置过的代理变量逐个从环境里摘掉，再执行 curl。
#
# 为什么要有这个包装：这些调用点的意图都是"绕过代理，直接连目标"（探测握手、
# 取版本号、下载资产）。环境里挂着 HTTP_PROXY 时 curl 会悄悄走代理，于是
# "直连"实际上是"又走了一遍代理"——症状是探测永远失败、更新永远连不上，
# 而 curl 自己一声不吭。
#
# 原来这套 `-u HTTP_PROXY -u http_proxy …` 清单在手抄，全仓 7 处、彼此还不一致
# （有一处多带了 NO_PROXY no_proxy，其余六处没有）。清单本来就该从 PROXY_VAR_NAMES
# 一处派生：手抄的后果是漏一个拼写就"探测被用户自己的环境劫持"，
# 而这是最难复现的一类失效。
#
# 用法：curl_direct <curl 的其余参数...>
# 输出与返回码原样透传，调用方照常用管道接。
curl_direct() {
    _cd_args=""
    for _cd_v in $PROXY_VAR_NAMES; do
        _cd_args="$_cd_args -u $_cd_v"
    done
    # shellcheck disable=SC2086
    env $_cd_args curl "$@"
}

# NO_PROXY 只增不减：已存在的条目原样保留，缺失的默认条目补上。
# 环境变量是共享资源——用户自己加的例外（公司内网等）与别的工具写下的例外都必须留着，
# 本工具只负责"本机地址一定直连"这一件事。
# 取值用 sed 而非 tr -d ' '：条目里可能有空格，整体删空格会改掉别人写的值。
merge_no_proxy() {
    _existing="$1"; _default="$2"
    _out="$_default"
    _lower=$(printf '%s' "$_default" | tr 'A-Z' 'a-z')
    _old=$IFS; IFS=','
    # 关掉通配：NO_PROXY 里合法写着 *.corp 这类条目，不关的话 for 会把它当 glob 展开成
    # 当前目录里的文件名（实测 `*.corp` 变成 alpha.corp,beta.corp），值就被改写了。
    _had_f=0; case $- in *f*) _had_f=1;; esac
    set -f
    for _p in $_existing; do
        _pt=$(printf '%s' "$_p" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -n "$_pt" ] || continue
        # 单引号不是合法的主机名/IP 字符，且会破坏 proxy.env 的 source 转义幂等——直接丢弃该条目。
        case "$_pt" in *"'"*) continue;; esac
        _pl=$(printf '%s' "$_pt" | tr 'A-Z' 'a-z')
        case ",$_lower," in
            *",$_pl,"*) ;;
            *) _out="${_out:+$_out,}$_pt"; _lower="${_lower},${_pl}" ;;
        esac
    done
    IFS=$_old
    [ "$_had_f" -eq 1 ] || set +f
    printf '%s' "$_out"
}

# shell 安全转义：单引号包裹、内部单引号转义。proxy.env 会被 hook 在每个新
# shell 里 source，未转义的 $、反引号会被执行（值变代码）。
shell_escape_sq() {
    _sq="$1"
    _sq=$(printf '%s' "$_sq" | sed "s/'/'\\\\''/g")
    printf "'%s'" "$_sq"
}

# 这一项是不是我们默认例外集里的（大小写不敏感）。用于精确回收 NO_PROXY：
# 只减掉我们加进去的那几项，用户自己写的条目原样留着。
is_default_no_proxy_entry() {
    _must=$(printf '%s' "$DEFAULT_NO_PROXY" | tr -d ' ' | tr 'A-Z' 'a-z')
    _me=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    case ",$_must," in *",$_me,"*) return 0 ;; esac
    return 1
}

# 安装快照（prev.env）里本来就记着这一项吗？记着 = 使用者自己的，我们永远不许动。
# 光看"形状像不像我们的"不够：用户自己也完全可能写 NO_PROXY=localhost，
# 或者用 mitmproxy 挂 http://127.0.0.1:8080。只看形状会在 off 态把它定时删掉。
# 快照格式是「变量名 TAB 值」（见 env.sh 的 snapshot_prev_env），不是 NAME=value——
# 按 = 解析会一行都匹配不上，于是保护全部落空（用户自己的条目会被当默认项剥掉）。
_snapshot_value_of() {
    # $1 = 变量名；输出该变量在快照里记下的值（去掉外层单引号）。没有则输出空。
    [ -f "$PREV_ENV" ] || return 0
    awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$PREV_ENV" 2>/dev/null |
        sed "s/^'\(.*\)'$/\1/"
}

no_proxy_entry_in_snapshot() {
    [ -f "$PREV_ENV" ] || return 1
    _nes=$(_snapshot_value_of NO_PROXY)
    [ -n "$_nes" ] || return 1
    _nes_me=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    _nes_list=$(printf '%s' "$_nes" | tr -d ' ' | tr 'A-Z' 'a-z')
    case ",$_nes_list," in *",$_nes_me,"*) return 0 ;; esac
    return 1
}

# 这个值是不是本工具写下的：只有 127.0.0.1 本机地址才算我们的，
# 用户或公司工具写的其他地址一律不动。
# 光看形状不够——用户自己也可能挂 mitmproxy（http://127.0.0.1:8080）；
# 安装快照里本来就有这个值，那就是他的，永远不许我们删（与 Win 侧分层同形）。
is_owned_proxy_value() {
    case "$1" in
        "$OWNED_HTTP_PREFIX"*|"$OWNED_HTTP6_PREFIX"*) ;;
        *) return 1 ;;
    esac
    # 快照里存的是单引号转义后的值（见 shell_escape_sq），所以两种写法都要认。
    # 逐变量比对，而不是"整份文件里 grep 一下"：后者会把 NO_PROXY 里恰好含同一串
    # 文本的情况也算进来，而且依赖分隔符形式，格式一改保护就静默失效。
    #
    # 快照文件**不存在**时有两种结果相反的情况，必须分开：
    #   装过（有安装记录 path.conf）却没快照：只可能是"装前本机没设过"，
    #     所以现在这个本机地址是我们写的 -> 认领（return 0）。
    #   从没装过：这个本机代理是使用者自己挂的 mitmproxy / 内网跳板，
    #     没有任何证据指向我们 -> 不认领（return 1）。
    # 折叠成"一律认领"的后果是：在一台从没装过的机器上执行 stop，
    # 就把使用者自己设的本机代理删掉，而且没有快照可以还原。
    # 判据用安装记录（PATH_CONF），与状态页判断"还没安装"用的是同一处事实。
    if [ ! -f "$PREV_ENV" ]; then
        [ -f "$PATH_CONF" ] && return 0
        return 1
    fi
    _iov_want=$(printf '%s' "$1")
    _iov_readable=0
    for _iov_v in $PROXY_ADDR_VAR_NAMES; do
        _iov_have=$(_snapshot_value_of "$_iov_v")
        if [ -n "$_iov_have" ]; then
            _iov_readable=1
            [ "$_iov_have" = "$_iov_want" ] && return 1
        fi
    done
    # 文件在、但一个变量都没读出内容：说明这份快照不可用（被截断 / 权限 / 格式坏了），
    # 此时**不认领**。这与 Windows 侧 Test-SnapshotRecorded 的三态化同一条：
    # 读不出来若落成"是我们的"，后续会把这个本机地址删掉——而那可能正是使用者自己挂的
    # mitmproxy。两个方向的代价不对称：不认领最多多留一个值（下一轮还会再判），
    # 认错了则删掉他本来能用的东西，而且没有任何提示。
    [ "$_iov_readable" = "1" ] || return 1
    return 0
}

# 成员判断：$1 在空格分隔表 $2 里则返回 0
_in_list() {
    case " $2 " in *" $1 "*) return 0;; *) return 1;; esac
}

# ------------------------------------------------------------------------------
# 5. 入口用法判定（纯函数，两端同形）
# ------------------------------------------------------------------------------
# 入口所有的用法错误都从这里出：输出空串 = 用法正确；输出该报的错 = 用法错误
# （入口打印它、退出 2）。输入是四样归一化后的东西：
#   USAGE_COMMAND       用户要的命令（小写；空 = 监控模式）
#   USAGE_COMMAND_COUNT 命令给了几个（>1 = 用法错误）
#   USAGE_SWITCHES      用户给的开关名（purge / yes，空格分隔）
#   USAGE_EXTRA         不认识的参数（空格分隔）
# 输入用全局变量传：bash 3.2 没有 nameref，函数收不了数组。
# 抽成纯函数是有原因的：直接跑入口验"合法用法必须放行"会真的装、卸、起监控，
# 副作用落在用户机器上（卸载删日志、更新改安装区），这类断言根本没法写。
# 判定本身没有副作用，纯函数才能把"必须拒"和"必须放行"两个方向都钉住。
usage_error() {
    if [ "${USAGE_COMMAND_COUNT:-0}" -gt 1 ]; then
        printf '一次只给一个命令。'
        return 1
    fi
    # "给了命令位、但归一化后是空" 是打错，不是"没给命令"。
    #
    # 这条针对光秃秃的横线：入口用 sed 's/^--*//; s/^-//' 剥前缀，于是
    # `-`、`--`、`---` 全都变成空串，而 USAGE_COMMAND_COUNT 仍然是 1。
    # 只判"命令 >1 个"的话，它会被当成一次合法的空命令，一路落到分派的 "" 分支
    # ——那是**监控模式**：敲错一个横线，工具就在后台常驻起来，屏幕上没有任何报错。
    # "没传参数"（COUNT=0）才是监控模式，两者不能压成同一个空串。
    if [ "${USAGE_COMMAND_COUNT:-0}" -ge 1 ] && [ -z "${USAGE_COMMAND:-}" ]; then
        printf '无法识别的参数：%s' "${USAGE_EXTRA:-（空）}"
        return 1
    fi
    if [ -n "${USAGE_EXTRA:-}" ]; then
        printf '无法识别的参数：%s' "$USAGE_EXTRA"
        return 1
    fi
    # 开关必须跟着它的命令：--purge 只配 uninstall，--yes 只配 update。
    # 单独给会一路落到监控模式：用户以为在清日志或在答"是"，工具却把监控起来了。
    case " ${USAGE_SWITCHES:-} " in
        *" purge "*)
            if [ "${USAGE_COMMAND:-}" != "uninstall" ]; then
                printf -- '--purge 只在卸载时才有意义：它表示连日志一起删。请用 uninstall --purge。'
                return 1
            fi
            ;;
    esac
    case " ${USAGE_SWITCHES:-} " in
        *" yes "*)
            # --yes 在两处有意义：跳过更新的确认，以及在**没法提问的环境里**明确表达
            # "我知道我在做什么"（卸载）。后者不是多余：卸载在非交互环境下会被拒绝，
            # 没有这个开关，脚本和 CI 就永远卸不掉。
            if [ "${USAGE_COMMAND:-}" != "update" ] && [ "${USAGE_COMMAND:-}" != "uninstall" ]; then
                printf -- '--yes 只在检查更新或卸载时才有意义：它表示跳过确认。请用 update --yes 或 uninstall --yes。'
                return 1
            fi
            ;;
    esac
    return 0
}

# 版本比较：按 . 分段逐段数值比。输出 1（A 新）/ 0（相等）/ -1（A 旧）。
compare_versions() {
    awk -v a="$1" -v b="$2" 'BEGIN{
        na=split(a,pa,"."); nb=split(b,pb,".");
        n=(na>nb?na:nb);
        for(i=1;i<=n;i++){ xa=(i<=na?pa[i]+0:0); xb=(i<=nb?pb[i]+0:0);
            if(xa>xb){print 1; exit} if(xa<xb){print -1; exit} }
        print 0 }'
}

# ------------------------------------------------------------------------------
# 屏幕渲染层：能不能就地重画、怎么画一帧、怎么进出、怎么等一个键。
#
# 为什么单独一层：一次性输出（打印完就结束）不需要这些；一旦要"自己动"，
# 就必须解决三件事——不能清屏（清屏就是闪）、只画变化的行、光标别乱跳。
# 放进 base 是因为 ops 与 future 的页面都要用，放进 ops 会让别的层反向依赖。
# ------------------------------------------------------------------------------

# 能不能做「就地重画」。这是所有刷新逻辑的前置判据，只有这一个实现。
# 四种情况不能画：
#   输出被重定向（管道/文件）—— 控制字符会原样写进文件，污染输出；
#   没有真实终端 —— 光标定位会失效；
#   窗口太窄/太矮 —— 内容放不下，重画必然滚屏，滚屏后绝对定位全部错位。
# 参数：$1 = 这一帧要占几行；$2 = 这一帧最宽行多少列（0 表示不检查宽度）
test_can_draw_screen() {
    _tcd_lines="${1:-0}"
    _tcd_width="${2:-0}"
    [ -t 1 ] || return 1
    [ -t 0 ] || return 1
    _tcd_w=$(tput cols 2>/dev/null || echo 80)
    _tcd_h=$(tput lines 2>/dev/null || echo 24)
    case "$_tcd_w" in ''|*[!0-9]*) _tcd_w=80;; esac
    case "$_tcd_h" in ''|*[!0-9]*) _tcd_h=24;; esac
    [ "$_tcd_w" -ge "$SCREEN_MIN_WIDTH" ] || return 1
    [ "$_tcd_h" -ge "$SCREEN_MIN_HEIGHT" ] || return 1
    if [ "$_tcd_lines" -gt 0 ] && [ $((_tcd_lines + SCREEN_BOTTOM_MARGIN)) -gt "$_tcd_h" ]; then
        return 1
    fi
    # 宽度也要按这一帧的实际最宽行判：折行会让后面每一行的绝对定位错位。
    if [ "$_tcd_width" -gt 0 ] && [ "$_tcd_width" -gt "$_tcd_w" ]; then
        return 1
    fi
    return 0
}

# 把一帧画到屏幕上，返回这一帧占了几行。
# 参数：$1 = 上一帧的内容（换行分隔，空表示没有上一帧）；$2 = 这一帧的内容。
#
# 关键点：内容没变的行一个字节都不发 —— 这是「不闪」的本质。
# 窗口尺寸一变就整帧重画：尺寸变化后终端会把已有内容重新折行，
# 屏幕上"第几行是什么"整个失效，而这一层的记账是按逻辑行算的。
write_screen_frame() {
    _wsf_old="$1"
    _wsf_new="$2"
    [ -t 1 ] || return 0
    _wsf_n=$(printf '%s\n' "$_wsf_new" | grep -c '' || echo 0)
    [ "$_wsf_n" -gt 0 ] || return 0

    # 尺寸变化检测
    _wsf_w=$(tput cols 2>/dev/null || echo 0)
    _wsf_h=$(tput lines 2>/dev/null || echo 0)
    if [ "$_wsf_w" != "${_SCREEN_LAST_W:-}" ] || [ "$_wsf_h" != "${_SCREEN_LAST_H:-}" ]; then
        _SCREEN_LAST_W="$_wsf_w"
        _SCREEN_LAST_H="$_wsf_h"
        _wsf_old=""
    fi

    # 逐行比较：只输出变化的行。用纯 bash 比较，不起子进程（热路径）。
    _wsf_buf=""
    _wsf_i=0
    _wsf_old_rest="$_wsf_old"
    while IFS= read -r _wsf_line; do
        _wsf_i=$((_wsf_i + 1))
        if [ -n "$_wsf_old_rest" ]; then
            _wsf_prev="${_wsf_old_rest%%$'\n'*}"
            case "$_wsf_old_rest" in
                *$'\n'*) _wsf_old_rest="${_wsf_old_rest#*$'\n'}" ;;
                *) _wsf_old_rest="" ;;
            esac
        else
            _wsf_prev=""
        fi
        [ "$_wsf_line" = "$_wsf_prev" ] && continue
        _wsf_buf="$_wsf_buf${_ESC}[${_wsf_i};1H${_wsf_line}${_ESC}[K"
    done <<EOF
$_wsf_new
EOF

    [ -n "$_wsf_buf" ] || return "$_wsf_n"
    # 藏光标 → 一次写出 → 恢复光标。整帧拼成一个字符串再写，快且没有"画到一半"的中间态。
    printf '%s' "${_ESC}[?25l${_wsf_buf}${_ESC}[?25h"
    return "$_wsf_n"
}

# 进/出「屏幕已接管」状态。只有进入时清一次屏；刷新循环里一次都不许清——清屏就是闪的根源。
enter_screen() {
    test_can_draw_screen || return 1
    printf '%s' "${_ESC}[2J${_ESC}[H"
    return 0
}

exit_screen() {
    # 光标放到底部并恢复可见：任何退出路径都要能到这里（Ctrl+C 走 trap）。
    _es_bottom=$(tput lines 2>/dev/null || echo 24)
    printf '%s' "${_ESC}[${_es_bottom};1H${_ESC}[?25h"
    return 0
}

# 等一个键，最多 $1 秒。返回：
#   Quit  —— 0 / q / Q
#   其它  —— 按下的字符（调用方自己决定怎么处理）
#   空    —— 超时没按键，或按的是功能键（方向键之类）
#
# DIVERGE(Mac): bash 3.2 的 read -t 只认整数秒，超时与 EOF 都返回 1，
#   所以要用"返回值 > 128 还是 == 1 且变量为空"两个信号来区分"超时"和"读不到"。
#   这一点与 Windows 侧不同（那边用 Console.KeyAvailable 轮询）。
wait_screen_key() {
    _wsk_sec="${1:-1}"
    _wsk_c=""
    _wsk_v=""
    _wsk_start=$(date +%s)
    if IFS= read -r -s -n 1 -t "$_wsk_sec" _wsk_v 2>/dev/null; then
        _wsk_c="$_wsk_v"
    else
        _wsk_c=""
        # read -t 超时会立即返回（rc>128）。如果 stdin 根本不可读（EOF、无 tty），
        # read 会立刻返回 rc=1 而**不是**等满超时——那样调用方的 while 会毫无间隔地
        # 空转，把一个核吃满且永远退不出去（实测一秒能转几千次）。
        # 所以这里必须自己把时间补足，保住"每一轮至少歇 _wsk_sec 秒"这条不变量。
        _wsk_now=$(date +%s)
        _wsk_waited=$((_wsk_now - _wsk_start))
        if [ "$_wsk_waited" -lt "$_wsk_sec" ]; then
            sleep "$((_wsk_sec - _wsk_waited))" 2>/dev/null || true
        fi
    fi
    case "$_wsk_c" in
        ''|$'\r'|$'\n') return 0 ;;
        # Esc 也退出：Windows 侧一直是 0/q/Esc 三个键，这里少了 Esc 就成了两种行为。
        # 终端里的 Esc 是一个裸 0x1B 字节（方向键是 0x1B 后跟别的字节，在这里只会取到
        # 第一个字节，按方向键等于按 Esc——状态页没有需要方向键的操作，可以接受）。
        '0'|'q'|'Q'|$'\033') printf '%s' 'Quit'; return 0 ;;
    esac
    printf '%s' "$_wsk_c"
    return 0
}
