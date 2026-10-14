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
HOOK_LINE='[ -f "$HOME/.envproxy/proxy.env" ] && . "$HOME/.envproxy/proxy.env"'

# ------------------------------------------------------------------------------
# 1. 日志（只记状态翻转；超过 200KB 截断为最近 200 行）
# ------------------------------------------------------------------------------
log_msg() {
    mkdir -p "$MONITOR_DIR" 2>/dev/null || true
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || return 0
    _size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    _size=$(printf '%s' "$_size" | tr -cd '0-9')
    if [ -n "$_size" ] && [ "$_size" -gt 204800 ] 2>/dev/null; then
        tail -n 200 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || rm -f "$LOG_FILE.tmp" 2>/dev/null || true
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
#     - "2-停止监控"停不住：停止后约 10 秒（默认 ThrottleInterval）被自动拉回，
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

set_autorun() {
    mkdir -p "$ENVPROXY_HOME" "$HOME/Library/LaunchAgents" 2>/dev/null || true
    if [ -f "$SCRIPT_DIR/locator.sh" ]; then
        cp "$SCRIPT_DIR/locator.sh" "$LOCATOR_PATH" 2>/dev/null || true
        chmod +x "$LOCATOR_PATH" 2>/dev/null || true
    fi
    get_plist_content > "$PLIST_PATH" 2>/dev/null || true
    update_path_record
    _uid=$(id -u)
    launchctl bootout "gui/$_uid/$PLIST_LABEL" 2>/dev/null || true
    if ! launchctl bootstrap "gui/$_uid" "$PLIST_PATH" 2>/dev/null; then
        launchctl load "$PLIST_PATH" 2>/dev/null || true
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

_backup_rc() {
    cp -p "$1" "$1.envproxy.bak" 2>/dev/null || true
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
        cat "$_htmp" > "$_hrc" 2>/dev/null || true
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
        # 经临时文件写回原文件，不改 inode/软链/权限——mv 替换会把软链换成普通文件，不用。
        _backup_rc "$_rc"
        if awk -v s="$HOOK_START" -v e="$HOOK_END" '$0==s{skip=1;next} $0==e{skip=0;next} !skip' "$_rc" > "$_tmp" 2>/dev/null; then
            cat "$_tmp" > "$_rc" 2>/dev/null || true
        fi
        rm -f "$_tmp" 2>/dev/null || true
    done
}

# ------------------------------------------------------------------------------
# 7. 监控进程管理（PID 文件 + 命令行校验 + 优雅停止）
# ------------------------------------------------------------------------------
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
    case "$_args" in
        *envproxy.sh*)
            case "$_args" in
                *install*|*stop*|*uninstall*|*status*|*purge*) return 1;;
                *) printf '%s' "$_pid"; return 0;;
            esac
            ;;
    esac
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
    echo "监控进程未能确认运行（另一个副本的监控可能占着单实例锁）。" >&2
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

    CURRENT_STATE="off"
    get_current_state || true
    apply_state "$CURRENT_STATE" || true
    _last="$CURRENT_STATE"
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
            if [ $_pending_n -ge 2 ]; then
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
                        remove_user_env_vars
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
