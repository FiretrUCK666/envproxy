# ------------------------------------------------------------------------------
#  runtime.sh — 运行时层：日志、监控进程、监控主循环、自启动定位器、shell 集成
#  路径常量依赖入口先设好的 SCRIPT_DIR；本层不得自行推算脚本目录。
# ------------------------------------------------------------------------------
MONITOR_DIR="$SCRIPT_DIR/monitor"
PID_FILE="$MONITOR_DIR/monitor.pid"
STOP_FLAG="$MONITOR_DIR/stop.flag"
LOG_FILE="$MONITOR_DIR/monitor.log"
PATH_CONF="$ENVPROXY_HOME/path.conf"
LOCATOR_PATH="$ENVPROXY_HOME/locator.sh"
PLIST_LABEL="com.envproxy.monitor"
# 测试可覆盖安装位置与自启动位置（自检时指向沙箱，不碰真实 HOME）。
PLIST_PATH="${PLIST_PATH:-$HOME/Library/LaunchAgents/$PLIST_LABEL.plist}"

# shell hook 标记（幂等插入/精确移除的依据）
HOOK_START="# >>> EnvProxy >>>"
HOOK_END="# <<< EnvProxy <<<"
# rc 里只放这一行，逻辑住在 prompt-sync.sh：
#   - 这一行要能被 _hook_block_paired 用整行匹配守护，所以必须短、必须单行；
#   - zsh / bash 两套写法、以后的修正都改 prompt-sync.sh，不动使用者的文件。
# 这一行做两件事：启动时读一次（服务非交互进程，如编辑器里的子 shell），
# 并注册"每次提示符前重读"的钩子（让已经开着的窗口也能跟上代理状态）。
HOOK_LINE='[ -r "$HOME/.envproxy/prompt-sync.sh" ] && . "$HOME/.envproxy/prompt-sync.sh"'

# 状态疑似翻转要连续确认几轮才动手：轮数决定"抗抖能力"，也是对外公布的
# "连回来要多久 / 断开要多久"的一部分，所以必须是具名常量（门禁要读它推导文档）。
STATE_DEBOUNCE_ROUNDS=2

# ------------------------------------------------------------------------------
# 1. 日志（只记状态翻转；超过 LOG_MAX_BYTES 截断为最近 LOG_TAIL_LINES 行）
# ------------------------------------------------------------------------------
log_msg() {
    mkdir -p "$MONITOR_DIR" 2>/dev/null || true
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || return 0
    _size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    _size=$(printf '%s' "$_size" | tr -cd '0-9')
    if [ -n "$_size" ] && [ "$_size" -gt "$LOG_MAX_BYTES" ] 2>/dev/null; then
        tail -n "$LOG_TAIL_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || rm -f "$LOG_FILE.tmp" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# 5. 自启动（LaunchAgent + 固定定位器；文件夹可任意移动）
# ------------------------------------------------------------------------------
update_path_record() {
    mkdir -p "$ENVPROXY_HOME" 2>/dev/null || true
    printf '%s\n' "$SCRIPT_PATH" > "$PATH_CONF" 2>/dev/null || true
}

# plist 的语义 = "登录时把它拉起来"，仅此而已——刻意不声明 KeepAlive。
#   对齐的依据：Windows 侧的自启动就是一个 Run 键（登录时执行一次），监控被停掉或
#   自行退出后不会复活。这里若写 KeepAlive，launchd 会在 job 主进程退出后无条件重启它，
#   而定位器末尾用 exec 把监控变成 job 主进程，于是直接破坏两件事：
#     - 菜单"停止监控"停不住：停止后约 10 秒（默认 ThrottleInterval）被自动拉回，
#       变量跟着重新注入，"暂停到下次登录"的承诺失效；
#     - 每个启动周期还会多一次无谓的 fork：job 被反复拉起，而定位器的单实例检查
#       立刻让它退出，如此每 10 秒一轮。
#   运行期的可靠性交给监控自身（互斥锁 + 自启动自愈），与 Windows 同语义。
#   将来若真的要"崩溃自动重启"，必须同时让"停止"能被系统表达出来（stop 里 bootout），
#   否则同一个意图会由两套机制互相打架。
get_plist_content() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$PLIST_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>$LOCATOR_PATH</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>WorkingDirectory</key><string>$ENVPROXY_HOME</string>
  <key>StandardOutPath</key><string>$ENVPROXY_HOME/monitor.stdout.log</string>
  <key>StandardErrorPath</key><string>$ENVPROXY_HOME/monitor.stderr.log</string>
</dict>
</plist>
EOF
}

# 该不该重载 launchd 代理？返回 0 = 要重载，1 = 不用。
# 判据只有两条：明确要求重载（安装路径），或者代理根本没被装载（那时也没有监控可杀）。
# 纯函数，自检可测。
autorun_reload_needed() {
    [ "${1:-}" = "1" ] && return 0
    launchctl list 2>/dev/null | grep -qF "$PLIST_LABEL" && return 1
    return 0
}

# 把终端同步脚本装到固定位置。返回 0 = 已就位（新装/已最新），1 = 失败。
# 用内容比对而不是"文件在不在"：升级后模板变了而副本还是旧的，
# 钩子行为就永远停在老版本——这与自启动的"内容一致"判据是同一道理。
install_prompt_sync() {
    _ps_src="$SCRIPT_DIR/prompt-sync.sh"
    _ps_dst="$ENVPROXY_HOME/prompt-sync.sh"
    [ -f "$_ps_src" ] || return 1
    mkdir -p "$ENVPROXY_HOME" 2>/dev/null || true
    if [ -f "$_ps_dst" ] && cmp -s "$_ps_src" "$_ps_dst" 2>/dev/null; then
        return 0
    fi
    _ps_tmp="$_ps_dst.tmp.$$"
    if cp "$_ps_src" "$_ps_tmp" 2>/dev/null && mv "$_ps_tmp" "$_ps_dst" 2>/dev/null; then
        chmod 644 "$_ps_dst" 2>/dev/null || true
        return 0
    fi
    rm -f "$_ps_tmp" 2>/dev/null || true
    return 1
}

set_autorun() {
    mkdir -p "$ENVPROXY_HOME" "$HOME/Library/LaunchAgents" 2>/dev/null || true
    if [ -f "$SCRIPT_DIR/locator.sh" ]; then
        cp "$SCRIPT_DIR/locator.sh" "$LOCATOR_PATH" 2>/dev/null || true
        chmod +x "$LOCATOR_PATH" 2>/dev/null || true
    fi
    # 终端同步脚本也复制到固定位置：rc 里那一行只认 ~/.envproxy/prompt-sync.sh。
    # 这样整个文件夹被移动/改名后，已经装好的 hook 仍然指向一份有效的实现
    # （与定位器同一套"固定位置"思路），改逻辑时只需要更新这一份。
    install_prompt_sync
    get_plist_content > "$PLIST_PATH" 2>/dev/null || true
    update_path_record
    # 重载 launchd 代理要谨慎：bootout 会给**正在跑的监控**发 SIGTERM，
    # 而紧接着 bootstrap 启的新监控可能抢不到单实例锁（旧的还没退干净），
    # 于是"自愈"的结果是监控没了——直到下次登录才恢复。
    # plist 内容只在装载时被 launchd 读一次，所以内容更新落进文件就够了；
    # 真正需要重载的只有"代理根本没被装载"这一种情况（那时也没有监控可杀）。
    # $1=1 是明确要求重载（安装路径：要把新的 plist 装载进去）。
    if autorun_reload_needed "${1:-}"; then
        _uid=$(id -u)
        launchctl bootout "gui/$_uid/$PLIST_LABEL" 2>/dev/null || true
        if ! launchctl bootstrap "gui/$_uid" "$PLIST_PATH" 2>/dev/null; then
            launchctl load "$PLIST_PATH" 2>/dev/null || true
        fi
    fi
    # 落点判据：两个固定产物都在才算成功，调用方据此打印实话。
    [ -f "$PLIST_PATH" ] && [ -f "$LOCATOR_PATH" ]
}

remove_autorun() {
    _uid=$(id -u)
    launchctl bootout "gui/$_uid/$PLIST_LABEL" 2>/dev/null || true
    launchctl bootout "gui/$_uid" "$PLIST_PATH" 2>/dev/null || true
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH" 2>/dev/null || true
}

# 自启动自愈：让两处固定位置的产物**与当前代码一致**——不只是"存在"。
# 判据取内容而非存在，理由是升级路径：改完脚本若没走"安装"，固定位置里留着的仍是
# 旧 plist / 旧定位器（搜索算法、参数、乃至 KeepAlive 这类语义都会停在旧值上）。
# 每次自查 = 让系统状态收敛到当前代码，不依赖用户记得重装。
repair_autorun() {
    _need=0
    [ -f "$PLIST_PATH" ] || _need=1
    [ -f "$LOCATOR_PATH" ] || _need=1
    if [ $_need -eq 0 ]; then
        # 命令替换会吃掉末尾换行，所以这里比的是"生成出来的代码"是否一致，行尾不算差异。
        _want_plist=$(get_plist_content)
        _have_plist=$(cat "$PLIST_PATH" 2>/dev/null)
        [ "$_have_plist" = "$_want_plist" ] || _need=1
        if [ -f "$SCRIPT_DIR/locator.sh" ]; then
            cmp -s "$SCRIPT_DIR/locator.sh" "$LOCATOR_PATH" || _need=1
        fi
        launchctl list 2>/dev/null | grep -qF "$PLIST_LABEL" || _need=1
    fi
    if [ $_need -eq 1 ]; then
        set_autorun || true
        log_msg "已自动修复开机自启动（定位器/自启动项缺失、损坏或与当前版本不一致）"
    fi
    _repair_hooks || true
}

# hook 存在性自愈（与变量 30 轮自检、自启动内容比对同周期）：zsh 落点缺失或内容不符就补写。
# bash 落点只在安装时处理（存在才写），稳态下不碰。
_repair_hooks() {
    # 先确保固定位置上的同步脚本是本版本（内容比对，不是"文件在不在"）：
    # 升级后模板变了而副本还是旧的，钩子行为就停在老版本，而 rc 里那一行看起来完全正常。
    if [ -f "$SCRIPT_DIR/prompt-sync.sh" ] && ! cmp -s "$SCRIPT_DIR/prompt-sync.sh" "$ENVPROXY_HOME/prompt-sync.sh" 2>/dev/null; then
        if install_prompt_sync; then
            log_msg "已自动更新终端同步脚本（内容与当前版本不一致）"
        fi
    fi
    _need=0
    _any=0
    for _rc in "$HOME/.zshenv" "$HOME/.zshrc"; do
        [ -f "$_rc" ] || continue
        _any=1
        if ! _hook_block_paired "$_rc" 2>/dev/null || ! grep -qxF "$HOOK_LINE" "$_rc" 2>/dev/null; then
            _need=1
            break
        fi
    done
    [ "$_any" = "0" ] && _need=1
    if [ "$_need" = "1" ]; then
        insert_shell_hooks || true
        log_msg "已自动修复终端 shell hook（缺失或内容与当前版本不一致）"
    fi
}

# ------------------------------------------------------------------------------
# 6. shell 集成（标记块幂等插入/精确移除）
# ------------------------------------------------------------------------------
# 落点选择：`.zshenv` 是唯一在所有 shell 类型（登录/交互/脚本/ssh 远程命令）都会加载的文件，
# 所以它是终端路的首选落点；`.zshrc` 作为冗余。hook 行本身无输出、无耗时。
insert_shell_hooks() {
    for _rc in "$HOME/.zshenv" "$HOME/.zshrc"; do
        touch "$_rc" 2>/dev/null || continue
        _normalize_hook_block "$_rc" || true
        if ! grep -qxF "$HOOK_START" "$_rc" 2>/dev/null; then
            printf '\n%s\n%s\n%s\n' "$HOOK_START" "$HOOK_LINE" "$HOOK_END" >> "$_rc" 2>/dev/null || true
        fi
    done
    for _rc in "$HOME/.bash_profile" "$HOME/.bashrc"; do
        [ -f "$_rc" ] || continue
        _normalize_hook_block "$_rc" || true
        if ! grep -qxF "$HOOK_START" "$_rc" 2>/dev/null; then
            printf '\n%s\n%s\n%s\n' "$HOOK_START" "$HOOK_LINE" "$HOOK_END" >> "$_rc" 2>/dev/null || true
        fi
    done
    # 落点判据：两个 zsh 落点至少一个有完整 hook 块，否则终端路不通。
    for _rc in "$HOME/.zshenv" "$HOME/.zshrc"; do
        if _hook_block_paired "$_rc" 2>/dev/null && grep -qxF "$HOOK_LINE" "$_rc" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# hook 块内容自愈：标记在、但内容与当前版本不符时删掉旧块（由调用方重新追加正确块）。
# 经临时文件写回原文件，不改 inode/软链/权限——mv 替换会把软链换成普通文件，不用。
# 安全三条：判定与删除统一用整行匹配；开始行与结束行必须成对且有序才动手，
# 缺一侧或顺序错乱就一个字节都不改；动手前先备份。
_hook_block_paired() {
    _hrc="$1"
    grep -qxF "$HOOK_START" "$_hrc" 2>/dev/null || return 1
    grep -qxF "$HOOK_END" "$_hrc" 2>/dev/null || return 1
    _s=$(grep -nxF "$HOOK_START" "$_hrc" 2>/dev/null | head -n 1 | cut -d: -f1)
    _e=$(grep -nxF "$HOOK_END" "$_hrc" 2>/dev/null | head -n 1 | cut -d: -f1)
    _s=$(printf '%s' "$_s" | tr -cd '0-9'); _e=$(printf '%s' "$_e" | tr -cd '0-9')
    [ -n "$_s" ] && [ -n "$_e" ] && [ "$_s" -lt "$_e" ] || return 1
    return 0
}

# 改使用者配置之前留一份「安装前快照」，**只写一次**。
#
# 只写一次是这条约定的全部价值所在：它代表「装之前长什么样」，那才是能还原回去的东西。
# 每次都覆盖的话，装第二次时 .bak 里已经是带我们钩子块的版本，使用者的原始内容在
# 「装 + 卸」一轮之后就没了——README 承诺的「改坏了还能还原」落空，而且是不报错地落空。
# 卸载时也不能重写：那时文件里已经有我们的块了，再 cp 一次等于把快照换成被污染的那份。
#
# 原文件不存在时留一张显式字条：否则「原来不存在」与「原来是空文件」分不开，
# 0 字节的 .bak 看着像备份、其实什么都还原不了。
_backup_rc() {
    [ -n "$1" ] || return 0
    [ -e "$1.envproxy.bak" ] && return 0
    if [ -e "$1" ]; then
        cp -p "$1" "$1.envproxy.bak" 2>/dev/null || true
    else
        printf '%s\n' '# envproxy: 本文件在安装前不存在（卸载时应删除，不要还原内容）' > "$1.envproxy.bak" 2>/dev/null || true
    fi
    return 0
}

# 解析软链指向的真实文件（最多跟 10 层）。
# mv 是原子的（目标要么是旧内容、要么是新内容，不会是半截），
# 但直接 mv 会把软链换成普通文件——所以先找到软链指向的真实文件，对它做替换。
# macOS 的 readlink 只解一层，链子要自己跟到底。
_resolve_real_path() {
    _rrp="$1"
    _rrp_n=0
    while [ -L "$_rrp" ] && [ "$_rrp_n" -lt 10 ]; do
        _rrp_n=$((_rrp_n + 1))
        _rrp_link=$(readlink "$_rrp" 2>/dev/null) || break
        [ -n "$_rrp_link" ] || break
        case "$_rrp_link" in
            /*) _rrp="$_rrp_link" ;;
            *) _rrp="$(dirname "$_rrp")/$_rrp_link" ;;
        esac
    done
    printf '%s' "$_rrp"
}

# 取文件的权限位（八进制）。macOS 是 stat -f，Linux 是 stat -c。
# 两个都试，但**必须校验结果像权限位**：GNU 的 stat -f 是"看文件系统"，
# 不是"按格式输出"，它会成功返回一段文件系统信息——不校验就会把那段信息当权限位用。
_perm_of() {
    _po=$(stat -f '%Lp' "$1" 2>/dev/null | head -n 1)
    case "$_po" in
        [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) printf '%s' "$_po"; return 0;;
    esac
    _po=$(stat -c '%a' "$1" 2>/dev/null | head -n 1)
    case "$_po" in
        [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) printf '%s' "$_po"; return 0;;
    esac
    printf ''
}

# 把临时文件的内容落到目标文件：原子替换。
# 不能写成 `cat 临时文件 > 原文件`——那是**就地截断重写**：中途失败或进程被杀，
# 用户的 .zshrc 就停在半截上，shell 一开就报错（配置坏了比没装更糟）。
# 改成同目录临时文件 + mv：mv 是改名，原子；权限位照原文件带过去。
_write_rc_atomic() {
    _wra_src="$1"
    _wra_dst="$2"
    _wra_real=$(_resolve_real_path "$_wra_dst")
    _wra_dir=$(dirname "$_wra_real")
    [ -d "$_wra_dir" ] || return 1
    # 临时文件必须和目标同目录，mv 才是同一文件系统内的改名（才是原子的）。
    _wra_tmp="$_wra_dir/.envproxy-rc.$$"
    if ! cat "$_wra_src" > "$_wra_tmp" 2>/dev/null; then
        rm -f "$_wra_tmp" 2>/dev/null || true
        return 1
    fi
    _wra_perm=$(_perm_of "$_wra_real")
    [ -n "$_wra_perm" ] && chmod "$_wra_perm" "$_wra_tmp" 2>/dev/null || true
    if mv "$_wra_tmp" "$_wra_real" 2>/dev/null; then
        return 0
    fi
    rm -f "$_wra_tmp" 2>/dev/null || true
    return 1
}

_normalize_hook_block() {
    _hrc="$1"
    grep -qxF "$HOOK_START" "$_hrc" 2>/dev/null || return 0
    if ! _hook_block_paired "$_hrc"; then
        log_msg "shell hook 标记不完整（缺结束行或顺序错乱），未改动：$_hrc"
        return 0
    fi
    _hwant="$(printf '%s\n%s\n%s' "$HOOK_START" "$HOOK_LINE" "$HOOK_END")"
    _have="$(awk -v s="$HOOK_START" -v e="$HOOK_END" '$0==s{f=1} f{print} $0==e{exit}' "$_hrc" 2>/dev/null)"
    [ "$_have" = "$_hwant" ] && return 0
    _htmp="$_hrc.tmp.$$"
    _backup_rc "$_hrc"
    if awk -v s="$HOOK_START" -v e="$HOOK_END" '$0==s{skip=1;next} $0==e{skip=0;next} !skip' "$_hrc" > "$_htmp" 2>/dev/null; then
        if ! _write_rc_atomic "$_htmp" "$_hrc"; then
            log_msg "shell hook 改写失败（原文件保持不变）：$_hrc"
        fi
    fi
    rm -f "$_htmp" 2>/dev/null || true
    return 0
}

remove_shell_hooks() {
    for _rc in "$HOME/.zshenv" "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zlogin" "$HOME/.bash_profile" "$HOME/.bashrc"; do
        [ -f "$_rc" ] || continue
        # 没有标记的文件碰都不碰：全量重写会改 mtime，白白弄脏用户文件。
        grep -qxF "$HOOK_START" "$_rc" 2>/dev/null || continue
        if ! _hook_block_paired "$_rc"; then
            log_msg "shell hook 标记不完整（缺结束行或顺序错乱），未改动：$_rc"
            continue
        fi
        _tmp="$_rc.tmp.$$"
        _backup_rc "$_rc"
        if awk -v s="$HOOK_START" -v e="$HOOK_END" '$0==s{skip=1;next} $0==e{skip=0;next} !skip' "$_rc" > "$_tmp" 2>/dev/null; then
            if ! _write_rc_atomic "$_tmp" "$_rc"; then
                log_msg "shell hook 清理失败（原文件保持不变）：$_rc"
            fi
        fi
        rm -f "$_tmp" 2>/dev/null || true
    done
}

# 状态对齐：判出状态才动手，判不出就什么都不做。
# 端口枚举失败时这一轮是“不知道”，按“没代理”去清理变量是在删一个可能还活着的代理——
# 那正是最不该犯的错。返回 0 = 判出了状态，1 = 不知道。
align_state_once() {
    # 不给 CURRENT_STATE 预设任何值：预设成 off 就是"读不出来被当成没有"，
    # 而调用方失败时只读"不知道"，不读这个变量。判不出状态就别留下痕迹。
    if ! get_current_state; then
        log_msg "端口枚举失败 -> 本轮沿用上一状态，不动环境变量"
        return 1
    fi
    apply_state "$CURRENT_STATE" || true
    return 0
}

# ------------------------------------------------------------------------------
# 7. 监控进程管理（PID 文件 + 命令行校验 + 优雅停止）
# ------------------------------------------------------------------------------
# 判据：这个进程是"监控"还是"一次性命令"。
# 监控的命令行是"解释器 + 脚本路径"，后面没有子命令；
# 一次性命令的命令行是"解释器 + 脚本路径 + 子命令 [开关]"，子命令是**脚本路径之后的第一个词**。
# 判据必须是**参数位**，不能是"命令行里有没有 install/stop 这些字"——
# 装在名字带 install 的目录里（Downloads/install/…）的监控会被误判成一次性命令：
# 于是"监控没在跑"→ 又起一个，停的时候也停不掉。
#
# 取第一个词而不是最后一个：子命令后面可以跟开关（uninstall --purge / update --yes），
# 取最后一个词会把带开关的一次性命令当成监控。
# 纯函数，自检可测（不联网、不起进程）。
is_monitor_args() {
    case "$1" in
        *envproxy.sh*) ;;
        *) return 1;;
    esac
    # 去掉脚本路径本身，剩下的第一个词才是子命令。
    _ima_rest="${1#*envproxy.sh}"
    _ima_arg=$(printf '%s' "$_ima_rest" | sed -E 's/^[[:space:]]+//; s/[[:space:]].*$//')
    case "$_ima_arg" in
        install|stop|uninstall|status|purge|update|menu|self-test) return 1;;
    esac
    return 0
}

# 判据一：监控自己写下的 pid 文件（它在拿到单实例锁之后才写）。
# 这是"监控真的在跑"的唯一可靠判据——命令行特征只能说明"有这么个进程"，
# 而刚启动、还没抢到锁就在退出的那个也满足它，拿它当"已启动"就会报假话。
get_monitor_pid_from_file() {
    [ -f "$PID_FILE" ] || return 1
    _pid=$(tr -cd '0-9' < "$PID_FILE" 2>/dev/null)
    [ -n "$_pid" ] || return 1
    [ "$_pid" != "$$" ] || return 1
    kill -0 "$_pid" 2>/dev/null || return 1
    _args=$(ps -p "$_pid" -o args= 2>/dev/null)
    if is_monitor_args "$_args"; then
        printf '%s' "$_pid"
        return 0
    fi
    return 1
}

# 判据二（兜底）：命令行特征。判"有没有监控在跑"用它——pid 文件缺失或陈旧但确实有监控时
# 靠它（手工启动、pid 文件被删、跨位置停止）；判"我刚启动的监控起来了吗"不能用它。
get_monitor_pid() {
    if _pid=$(get_monitor_pid_from_file); then
        printf '%s' "$_pid"
        return 0
    fi
    # pgrep 是 macOS 自带（10.6 起），直调即可，不留走不到的兜底分支。
    for _pid in $(pgrep -f "envproxy\.sh$" 2>/dev/null); do
        [ "$_pid" != "$$" ] || continue
        printf '%s' "$_pid"
        return 0
    done
    return 1
}

start_monitor() {
    _force="$1"
    _existing=$(get_monitor_pid || true)
    if [ -n "$_existing" ]; then
        _args=$(ps -p "$_existing" -o args= 2>/dev/null || echo "")
        _same=0
        case "$_args" in *"$SCRIPT_PATH"*) _same=1;; esac
        if [ "$_force" != "1" ] && [ "$_same" = "1" ]; then
            echo "监控进程已在运行（路径一致），跳过启动。"
            return 0
        fi
        if [ "$_force" = "1" ]; then echo "正在重启监控以加载当前最新代码..."; else echo "检测到旧位置的监控进程，正在迁移到当前路径..."; fi
        stop_monitor || true
    fi
    # 启动前清掉可能残留的 pid 文件（强杀不给监控机会删它），否则复检会读到上一次运行的 pid。
    rm -f "$PID_FILE" 2>/dev/null || true
    nohup /bin/bash "$SCRIPT_PATH" >/dev/null 2>&1 < /dev/null &
    # shellcheck disable=SC2312
    disown 2>/dev/null || true
    # 复检判据是 pid 文件（监控拿到单实例锁之后才写）。冷启动要几秒，所以轮询而不是固定等待：
    # 固定等待既可能把"其实起来了"误报成失败，也可能放过那个正在抢锁失败的进程。
    _deadline=$(( $(date +%s) + 12 ))
    while [ "$(date +%s)" -lt "$_deadline" ]; do
        get_monitor_pid_from_file >/dev/null 2>&1 && break
        sleep 0.4
    done
    if get_monitor_pid_from_file >/dev/null 2>&1; then
        echo "监控进程已启动。"
        return 0
    fi
    # 起不来要分清是"另一个副本占着锁"还是"根本没起来"：前者该去别处收摊，后者该查权限与日志。
    # 说清楚另一份在哪，使用者才知道该进哪个文件夹。
    _other=$(get_monitor_pid || true)
    if [ -n "$_other" ]; then
        _oargs=$(ps -p "$_other" -o args= 2>/dev/null || echo "")
        _opath=$(printf '%s' "$_oargs" | sed 's/^[^ ]*[ ]*//')
        echo "监控进程未能确认运行：另一个副本的监控正占着单实例锁（$_opath）。" >&2
        echo "      还用那份就继续用它；不用了，进上面那个文件夹打开菜单选 一键恢复，再回到这里选 安装。" >&2
    else
        echo "监控进程未能确认运行：这次没看到别的副本，多半是启动被拦或启动过程出错。" >&2
        echo "      再选一次 安装 / 修复；仍然不行就看 查看状态 和 monitor.log 最近几行。" >&2
    fi
    return 1
}

stop_monitor() {
    _existing=$(get_monitor_pid || true)
    if [ -z "$_existing" ]; then echo "监控进程未在运行。"; return 0; fi
    _args=$(ps -p "$_existing" -o args= 2>/dev/null || echo "")
    _target_dir="$MONITOR_DIR"
    # ps 的 args 是"解释器 + 脚本路径"两个词，路径里可能有空格，所以按"去掉第一个词"取整串，
    # 不能用只匹配非空格字符的正则（路径带空格时会截到尾巴，把停止标志写进错误目录，
    # 优雅停止退化成强杀、旧监控残留）。
    _from_args=$(printf '%s' "$_args" | sed 's/^[^ ]*[ ]*//')
    case "$_from_args" in
        *envproxy.sh*) _target_dir="$(dirname "$_from_args")/monitor" ;;
    esac
    mkdir -p "$_target_dir" 2>/dev/null || true
    printf 'stop\n' > "$_target_dir/stop.flag" 2>/dev/null || true
    _i=0
    while [ $_i -lt 60 ]; do
        get_monitor_pid >/dev/null 2>&1 || break
        sleep 0.1
        _i=$((_i + 1))
    done
    _again=$(get_monitor_pid || true)
    if [ -n "$_again" ]; then
        kill "$_again" 2>/dev/null || true
        sleep 1
        _ghost=$(get_monitor_pid || true)
        [ -n "$_ghost" ] && kill -9 "$_ghost" 2>/dev/null || true
        sleep 0.5
    fi
    rm -f "$_target_dir/stop.flag" "$STOP_FLAG" 2>/dev/null || true
    if [ "$_target_dir" != "$MONITOR_DIR" ] && [ -d "$_target_dir" ]; then
        if [ -z "$(ls -A "$_target_dir" 2>/dev/null)" ]; then rmdir "$_target_dir" 2>/dev/null || true; fi
    fi
    # 定论由复读决定，不由"我发了停止信号"决定：进程还在就不能报"已停止"。
    if [ -n "$(get_monitor_pid || true)" ]; then
        echo "监控进程未能停止（请检查是否有别的窗口正在运行它）。"
    else
        echo "监控进程已停止。"
    fi
}

# 拿操作锁（安装/更新/停止/卸载共用）：成功返回 0；撞上返回 1 并打印提示。
# 用 ln 而不是 mkdir：mkdir 成功到"把 pid 写进去"之间有个空窗，
# 那个空窗里另一个进程读到空的 pid，会把锁当成陈旧的接管掉——
# 两个安装同时跑，就会互相覆盖文件。
# ln 是原子的：目标存在就失败，失败即输；先把 pid 写进临时文件再 ln 过去，
# 锁一出现就是完整的。
# $1=锁文件路径。
acquire_op_lock() {
    _aol_lock="$1"
    _aol_tmp="$_aol_lock.tmp.$$"
    printf '%s\n' "$$" > "$_aol_tmp" 2>/dev/null || true
    if ln "$_aol_tmp" "$_aol_lock" 2>/dev/null; then
        rm -f "$_aol_tmp" 2>/dev/null || true
        return 0
    fi
    rm -f "$_aol_tmp" 2>/dev/null || true
    _aol_pid=$(cat "$_aol_lock" 2>/dev/null || echo 0)
    if [ -n "$_aol_pid" ] && [ "$_aol_pid" != "0" ] && kill -0 "$_aol_pid" 2>/dev/null; then
        echo "另一个安装/更新正在进行（PID $_aol_pid），请等它结束再试（没有做任何改动）。"
        return 1
    fi
    # 陈旧锁（持有者已经不在）：接管。删掉再 ln——ln 是原子的，
    # 两个进程同时接管也只有一个能成功。
    rm -f "$_aol_lock" 2>/dev/null || true
    printf '%s\n' "$$" > "$_aol_tmp" 2>/dev/null || true
    if ln "$_aol_tmp" "$_aol_lock" 2>/dev/null; then
        rm -f "$_aol_tmp" 2>/dev/null || true
        return 0
    fi
    rm -f "$_aol_tmp" 2>/dev/null || true
    echo "另一个安装/更新正在进行，请稍候（没有做任何改动）。"
    return 1
}

# ------------------------------------------------------------------------------
# 8. 监控主循环（双轮确认去抖；任何单轮异常都不致命）
# ------------------------------------------------------------------------------
run_monitor_loop() {
    # 运行时目录必须在这里就建：安装包不带 monitor/（不入库），全新安装时这是它第一次被用到。
    # 少了这一句，锁目录就建不出来、函数直接 return，监控永远起不来——而安装界面照样打印"已启动"。
    mkdir -p "$MONITOR_DIR" 2>/dev/null || true
    _lockdir="$MONITOR_DIR/.lock"
    if ! mkdir "$_lockdir" 2>/dev/null; then
        _e=$(get_monitor_pid || true)
        [ -n "$_e" ] && return 0
        rmdir "$_lockdir" 2>/dev/null || true
        if ! mkdir "$_lockdir" 2>/dev/null; then
            echo "监控启动失败：运行时目录不可写（$MONITOR_DIR）。" >&2
            return 1
        fi
    fi
    # shellcheck disable=SC2064
    trap "rmdir \"$_lockdir\" 2>/dev/null || true" EXIT
    _e=$(get_monitor_pid || true)
    if [ -n "$_e" ]; then rmdir "$_lockdir" 2>/dev/null || true; trap - EXIT; return 0; fi

    rm -f "$STOP_FLAG" 2>/dev/null || true
    mkdir -p "$MONITOR_DIR" 2>/dev/null || true
    printf '%s\n' "$$" > "$PID_FILE" 2>/dev/null || true
    update_path_record
    log_msg "==== 监控启动 ===="

    # 状态对齐：判出状态才动手；判不出（端口枚举失败）就是"不知道"，沿用现状。
    # 判出状态 -> 返回 0，状态在 CURRENT_STATE 里；判不出 -> 返回 1，什么都不动。
    if align_state_once; then
        _last="$CURRENT_STATE"
    else
        # 状态是"不知道"：不能拿预设的 off 当"上一状态"。
        # 否则 30 轮后的自愈块会以为"我们处于 off 态、有残留"，把用户的代理变量删掉
        # ——那正是这一版要杜绝的事。留空 = 没有上一状态，两个分支都不会进。
        _last=""
    fi
    _pending=""
    _pending_n=0
    _repair=0
    _self=0

    while [ ! -f "$STOP_FLAG" ]; do
        if [ ! -f "$SCRIPT_PATH" ]; then _self=1; break; fi
        if ! get_current_state; then
            log_msg "检测异常：状态探测失败，沿用上一状态"
            CURRENT_STATE="$_last"
        fi
        _st="$CURRENT_STATE"
        if [ "$_st" != "$_last" ]; then
            if [ "$_st" = "$_pending" ]; then _pending_n=$((_pending_n + 1)); else _pending="$_st"; _pending_n=1; fi
            if [ $_pending_n -ge "$STATE_DEBOUNCE_ROUNDS" ]; then
                apply_state "$_st" || true
                _last="$_st"
                _pending=""; _pending_n=0
            fi
        else
            _pending=""; _pending_n=0
        fi
        _repair=$((_repair + 1))
        # 每 30 轮自愈一次（轮间隔 on 2 秒 / off 3 秒 → 约 60–90 秒一次）。
        # 按轮计数而不是按秒：轮询节奏本身就是可变配置，写死秒数会随节奏改动而失准。
        if [ $_repair -ge 30 ]; then
            _repair=0
            repair_autorun || true
            # 变量自检：apply_state 只在状态翻转时动手，稳态下它永远不会被调用，
            # 于是"别的东西改坏了变量"没人纠正。这里按同一周期整表核对，不齐就补回来
            # （幂等，齐了则零写入）。只核对我们本该持有的那几个，与用户自己的变量无关。
            case "$_last" in
                on:*) sync_user_env_vars "${_last#on:}" || true ;;
                off)
                    # off 态残留兜底（与 Windows 侧 30 轮自检同语义）：整表判据走同一套，
                    # 稳态 off 下外部改动或旧残留也能被纠正，而不是等到下次翻转。
                    if proxy_vars_present; then
                        remove_user_env_vars sentinel
                        log_msg "检测到代理变量残留 -> 已回收，恢复直连"
                    fi
                    ;;
            esac
        fi
        if [ "$_last" = "off" ]; then sleep 3; else sleep 2; fi
    done

    if [ "$_self" = "1" ]; then
        # 自退时没有活着的组件会再纠正变量：先把我们写的东西清掉（新位置的监控会在秒级内按需重注），
        # 再清运行时目录。否则删文件夹后新终端继续读到过期代理。
        remove_user_env_vars || true
        rm -rf "$MONITOR_DIR" 2>/dev/null || true
        if [ -d "$SCRIPT_DIR" ] && [ -z "$(ls -A "$SCRIPT_DIR" 2>/dev/null)" ]; then
            rmdir "$SCRIPT_DIR" 2>/dev/null || true
        fi
    else
        log_msg "==== 监控退出（收到停止信号）===="
        rm -f "$PID_FILE" "$STOP_FLAG" 2>/dev/null || true
    fi
    rmdir "$_lockdir" 2>/dev/null || true
    trap - EXIT
}
