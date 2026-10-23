#!/bin/zsh
# EnvProxy 登录定位器（由 envproxy.sh 安装时复制到 ~/.envproxy/locator.sh，请勿手改）
# 职责：读 ~/.envproxy/path.conf → 找到真实 envproxy.sh → exec 它。
# 文件夹被移动后记录失效 → 自动搜索新位置 → 更新记录 → 启动。
# 全程静默（launchd 会收走 stdout/stderr），失败静默退出，不打扰登录。

REG="$HOME/.envproxy/path.conf"
_target=""
if [ -f "$REG" ]; then
    _target=$(head -n 1 "$REG" 2>/dev/null | tr -d '\r\n')
fi

# 记录必须指向入口脚本本身：指向别处（例如某个库文件）同样算失效。
# 只判"文件在不在"不够——记录写坏了、而那个文件恰好存在时，会一直去 exec 一个跑不起来的
# 文件，搜索却永远不触发，登录自启动就此静默失效。
case "$_target" in
    */envproxy.sh) : ;;
    *) _target="" ;;
esac

if [ -z "$_target" ] || [ ! -f "$_target" ]; then
    # 记录失效（文件不在了，或记录指向的不是入口脚本）：先顺手清理旧位置残留
    # （移动后立刻关机、监控来不及自退的场景）
    if [ -n "$_target" ]; then
        _old_dir=$(dirname "$_target" 2>/dev/null)
        if [ -n "$_old_dir" ]; then
            rm -f "$_old_dir/monitor/monitor.pid" "$_old_dir/monitor/stop.flag" 2>/dev/null
    rm -rf "$_old_dir/monitor/.lock" 2>/dev/null
            if [ -d "$_old_dir" ] && [ -z "$(ls -A "$_old_dir" 2>/dev/null)" ]; then
                rmdir "$_old_dir" 2>/dev/null
            fi
        fi
    fi
    # 分层搜索：用户常用位置深搜 6 层；其他卷根浅搜 4 层。
    # 注意：不从 $HOME 根整体递归——大目录 + TCC 弹窗会拖慢登录；错误全部静默忽略。
    # 注意：跳过 Time Machine 备份卷，否则又慢又可能误选。
    _search_one() {
        _root="$1"; _depth="$2"
        [ -d "$_root" ] || return 0
        find "$_root" -maxdepth "$_depth" -name "envproxy.sh" -print 2>/dev/null | while IFS= read -r _cand; do
            [ -f "$_cand" ] || continue
            _cdir=$(dirname "$_cand" 2>/dev/null)
            _log="$_cdir/monitor/monitor.log"
            _lm=0
            _fm=0
            if [ -f "$_log" ]; then
                _lm=$(stat -f %m "$_log" 2>/dev/null || stat -c %Y "$_log" 2>/dev/null || echo 0)
                _lm=$(printf '%s' "$_lm" | tr -cd '0-9')
                [ -n "$_lm" ] || _lm=0
            fi
            _fm=$(stat -f %m "$_cand" 2>/dev/null || stat -c %Y "$_cand" 2>/dev/null || echo 0)
            _fm=$(printf '%s' "$_fm" | tr -cd '0-9')
            [ -n "$_fm" ] || _fm=0
            printf '%s %s %s\n' "$_lm" "$_fm" "$_cand"
        done
    }
    _all=""
    # 总时限：一个根慢和十个根加起来慢，后果一样，所以限的是**整段搜索**而不是单个根。
    # 超时就放弃搜索、走既有的"找不到就清变量退出"分支——宁可不接管，
    # 也不能让登录卡住、更不能让监控因为搜索出错而不启动。
    # 用 bash 自带的 SECONDS，零 fork（这个脚本本身就在登录路径上，每多一个进程都要付钱）。
    _budget_start=$SECONDS
    _over_budget() { [ $(( SECONDS - _budget_start )) -ge 8 ]; }
    for _r in "$HOME/Desktop" "$HOME/Documents" "$HOME/Downloads" "$HOME/OneDrive" "$HOME/.config"; do
        _over_budget && break
        _out=$(_search_one "$_r" 6)
        [ -n "$_out" ] && _all="$_all
$_out"
    done
    for _vol in /Volumes/*; do
        _over_budget && break
        [ -d "$_vol" ] || continue
        case "$_vol" in *Time*Machine*|*Backups.backupdb*) continue;; esac
        # 跳过网络挂载点：断线的 SMB/NFS 卷上一次递归遍历会各等一次传输超时
        # （数秒到数十秒），而这段搜索排在"启动监控"之前——后果是监控晚启动，
        # 这期间没有人纠正环境变量；严重时搜索中途出错，监控压根不启动。
        # mount 的输出里网络卷形如 "//user@host/share on /Volumes/x (smbfs, ...)"。
        case "$(mount 2>/dev/null | grep -F " on $_vol " || true)" in
            *smbfs*|*nfs*|*afpfs*|*webdav*) continue ;;
        esac
        _out=$(_search_one "$_vol" 4)
        [ -n "$_out" ] && _all="$_all
$_out"
    done
    # 活跃度排序：monitor.log 最近写入优先（真正在用的胜出，备份永不误选）
    _best_line=$(printf '%s' "$_all" | grep -E '^[0-9]+ [0-9]+ ' | sort -rn | head -n 1)
    if [ -n "$_best_line" ]; then
        _target=$(printf '%s' "$_best_line" | sed 's/^[0-9]* [0-9]* //')
    fi
fi

[ -n "$_target" ] && [ -f "$_target" ] || {
    # 兜底：安装根找不到了，没有活着的组件会再纠正变量——把我们写的东西清掉，
    # 新终端不再读到过期代理。只删本机地址（归属判定），用户自己的配置不动。
    # 保持静默（登录路径不打扰用户），无日志可写：monitor 目录可能已不存在。
    rm -f "$HOME/.envproxy/proxy.env" 2>/dev/null
    for _v in HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy; do
        _cur=$(launchctl getenv "$_v" 2>/dev/null || echo "")
        # **两种回环写法都要认**：注入端按实际能连上的地址拼 URL，只绑 ::1 的代理
        # 注入的就是 http://[::1]:port。只认 127.0.0.1 会让这类用户的死代理永远清不掉——
        # 而这段代码只在"安装根已经找不到"时跑，那时没有任何活着的组件会再纠正变量。
        # 与 Windows 侧 locator.ps1 同一判据（那边连注释都写了这条）。这里同上：
        # 用前缀匹配而不是 case 通配符，因为 [ ] 在通配符里是字符类定界符，
        # "http://[::1]:*" 会被解释成"http:// 加一个 : 或 1 加 :任意"，判据整个作废。
        case "$_cur" in
            http://127.0.0.1:*) launchctl unsetenv "$_v" 2>/dev/null ;;
            'http://[::1]:'*) launchctl unsetenv "$_v" 2>/dev/null ;;
        esac
    done
    _node=$(launchctl getenv NODE_USE_ENV_PROXY 2>/dev/null || echo "")
    [ "$_node" = "1" ] && launchctl unsetenv NODE_USE_ENV_PROXY 2>/dev/null
    exit 0
}

mkdir -p "$(dirname "$REG")" 2>/dev/null
printf '%s\n' "$_target" > "$REG" 2>/dev/null

# 单实例：已在跑就静默退出（监控自身还有互斥锁，这里只是少 fork 一次）。
# 判据必须按 UID 过滤：别的账户的监控不算"已经有人在跑"。
# 不过滤的后果是——同一台 Mac 上另一个账户装过本工具时，这个定位器每次登录
# 都以为"监控已经在跑"而静默退出，于是**本账户的监控永远不启动**，
# 而状态页读自己的 pid 文件报"未运行"，两条信息互相矛盾。与 core 侧同一判据。
pgrep -u "$(id -u)" -f "envproxy\.sh$" >/dev/null 2>&1 && exit 0

exec /bin/bash "$_target"
