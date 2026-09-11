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

if [ -z "$_target" ] || [ ! -f "$_target" ]; then
    # 记录失效：先顺手清理旧位置残留（移动后立刻关机、监控来不及自退的场景）
    if [ -n "$_target" ]; then
        _old_dir=$(dirname "$_target" 2>/dev/null)
        if [ -n "$_old_dir" ]; then
            rm -rf "$_old_dir/monitor" 2>/dev/null
            if [ -d "$_old_dir" ] && [ -z "$(ls -A "$_old_dir" 2>/dev/null)" ]; then
                rmdir "$_old_dir" 2>/dev/null
            fi
        fi
    fi
    # 分层搜索：用户常用位置深搜 6 层；其他卷根浅搜 4 层。
    # 注意：不从 $HOME 根整体递归——大目录 + TCC 弹窗会拖慢登录；错误全部静默忽略。
    # 注意：跳过 Time Machine 备份卷，否则又慢又可能误选。
    _best=""
    _best_log_mtime=0
    _best_file_mtime=0
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
    for _r in "$HOME/Desktop" "$HOME/Documents" "$HOME/Downloads" "$HOME/OneDrive" "$HOME/.config"; do
        _out=$(_search_one "$_r" 6)
        [ -n "$_out" ] && _all="$_all
$_out"
    done
    for _vol in /Volumes/*; do
        [ -d "$_vol" ] || continue
        case "$_vol" in *Time*Machine*|*Backups.backupdb*) continue;; esac
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

[ -n "$_target" ] && [ -f "$_target" ] || exit 0

mkdir -p "$(dirname "$REG")" 2>/dev/null
printf '%s\n' "$_target" > "$REG" 2>/dev/null

# 单实例：已在跑就静默退出（监控自身还有互斥锁，这里只是少 fork 一次）
if command -v pgrep >/dev/null 2>&1; then
    pgrep -f "envproxy\.sh$" >/dev/null 2>&1 && exit 0
fi

exec /bin/bash "$_target"
