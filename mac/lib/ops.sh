# ------------------------------------------------------------------------------
#  ops.sh — 动作层：菜单背后的安装、停止、卸载、状态编排，以及自检沙箱
#  把下面各层拼成使用者点得到的行为。
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# 自检回归：沙箱里跑，断言 hook 成对护栏、合并语义、归属判定与注入回收往返。
# 只碰沙箱 HOME 与沙箱 ENVPROXY_HOME，不碰真实用户文件。CI 门禁调用，失败返回非零。
# ------------------------------------------------------------------------------
_selftest_fails=0

_selftest_assert_eq() {
    _name="$1"; _want="$2"; _have="$3"
    if [ "$_want" = "$_have" ]; then
        echo "  PASS $_name"
    else
        echo "  FAIL $_name（期望 [$_want]，实际 [$_have]）"
        _selftest_fails=$((_selftest_fails + 1))
    fi
}

_selftest_assert_file_eq() {
    _name="$1"; _want="$2"; _file="$3"
    _have=$(cat "$_file" 2>/dev/null || echo "__MISSING__")
    if [ "$_want" = "$_have" ]; then
        echo "  PASS $_name"
    else
        echo "  FAIL $_name（文件内容不符，实际：）"
        printf '%s\n' "$_have" | sed 's/^/    |/'
        _selftest_fails=$((_selftest_fails + 1))
    fi
}

# 断言一段文字里含有某个片段（用于提示文案必须包含关键动作）。
# 比"整串相等"更适合文案：文案会变，但"必须提到手动下载"这件事不能变。
_selftest_assert_contains() {
    _name="$1"; _needle="$2"; _hay="$3"
    case "$_hay" in
        *"$_needle"*)
            echo "  PASS $_name"
            ;;
        *)
            echo "  FAIL $_name（应包含 [$_needle]，实际：）"
            printf '%s\n' "$_hay" | sed 's/^/    |/'
            _selftest_fails=$((_selftest_fails + 1))
            ;;
    esac
}

self_test() {
    _selftest_fails=0
    _sandbox=$(mktemp -d /tmp/envproxy_selftest.XXXXXX 2>/dev/null) || { echo "自检失败：沙箱建不起"; return 1; }
    # 运行期改道：HOME 管 hook 落点，ENVPROXY_HOME 管 proxy.env/快照，MONITOR_DIR 管日志。
    HOME="$_sandbox"
    ENVPROXY_HOME="$_sandbox/.envproxy"
    PROXY_ENV="$ENVPROXY_HOME/proxy.env"
    PREV_ENV="$ENVPROXY_HOME/prev.env"
    MONITOR_DIR="$ENVPROXY_HOME/monitor"
    LOG_FILE="$MONITOR_DIR/monitor.log"
    export HOME ENVPROXY_HOME
    mkdir -p "$ENVPROXY_HOME" "$MONITOR_DIR" 2>/dev/null || true

    echo "[1] hook 成对护栏"
    printf '%s\n' 'export PATH=/x' '# >>> EnvProxy >>>' 'OLD-HOOK' '# <<< EnvProxy <<<' 'alias ll="ls"' > "$HOME/.zshenv"
    _normalize_hook_block "$HOME/.zshenv" || true
    _selftest_assert_file_eq "旧块被清理、用户行保留" "$(printf '%s\n' 'export PATH=/x' 'alias ll="ls"')" "$HOME/.zshenv"

    printf '%s\n' 'export PATH=/x' '# >>> EnvProxy >>>' 'HOOK' 'alias ll="ls"' > "$HOME/.zshenv"
    _before=$(cat "$HOME/.zshenv" 2>/dev/null)
    _normalize_hook_block "$HOME/.zshenv" || true
    _selftest_assert_eq "缺结束行时一个字节都不改" "$_before" "$(cat "$HOME/.zshenv" 2>/dev/null)"

    printf '%s\n' 'export PATH=/x' '# >>> EnvProxy >>>' 'HOOK' '# <<< EnvProxy <<< ' 'alias ll="ls"' > "$HOME/.zshenv"
    _before=$(cat "$HOME/.zshenv" 2>/dev/null)
    remove_shell_hooks 2>/dev/null || true
    _selftest_assert_eq "结束行尾随空格时不截断" "$_before" "$(cat "$HOME/.zshenv" 2>/dev/null)"

    printf '%s\n' 'export PATH=/x' '# >>> EnvProxy >>>' "$HOOK_LINE" '# <<< EnvProxy <<<' 'alias ll="ls"' > "$HOME/.zshenv"
    remove_shell_hooks 2>/dev/null || true
    _selftest_assert_file_eq "成对时正常移除" "$(printf '%s\n' 'export PATH=/x' 'alias ll="ls"')" "$HOME/.zshenv"

    echo "[2] 合并与归属"
    _selftest_assert_eq "补默认项、留用户条目" "localhost,127.0.0.1,::1,example.com" "$(merge_no_proxy 'localhost,example.com,::1' "$DEFAULT_NO_PROXY")"
    _selftest_assert_eq "含单引号条目丢弃" "localhost,127.0.0.1,::1,ok.example" "$(merge_no_proxy "ok.example,a'b" "$DEFAULT_NO_PROXY")"
    if is_owned_proxy_value "http://127.0.0.1:7890"; then _o1=1; else _o1=0; fi
    if is_owned_proxy_value "http://corp:8080"; then _o2=1; else _o2=0; fi
    _selftest_assert_eq "本机地址算我们的" "1" "$_o1"
    _selftest_assert_eq "公司地址不算我们的" "0" "$_o2"
    _selftest_assert_eq "转义幂等" "'a'" "$(shell_escape_sq 'a')"
    # compare_versions 结果走 stdout（exit 恒 0），直接取输出断言。
    _selftest_assert_eq "版本逐段数值比" "1" "$(compare_versions "1.0.10" "1.0.9")"

    echo "[3] 注入核对回收往返"
    set_user_env_vars "17890" || true
    if env_vars_in_sync "17890"; then _s1=1; else _s1=0; fi
    _selftest_assert_eq "注入后判就位" "1" "$_s1"
    if proxy_vars_present; then _s2=1; else _s2=0; fi
    _selftest_assert_eq "注入后判有痕迹" "1" "$_s2"
    # shellcheck disable=SC1090
    . "$PROXY_ENV" 2>/dev/null || true
    _selftest_assert_eq "proxy.env 可被 source" "http://127.0.0.1:17890" "$HTTP_PROXY"
    remove_user_env_vars || true
    if [ -f "$PROXY_ENV" ]; then _s3=1; else _s3=0; fi
    _selftest_assert_eq "回收后文件消失" "0" "$_s3"
    if proxy_vars_present; then _s4=1; else _s4=0; fi
    _selftest_assert_eq "回收后无痕迹" "0" "$_s4"
    unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy NODE_USE_ENV_PROXY 2>/dev/null || true

    echo "[4] 快照还原"
    snapshot_prev_env || true
    if [ -f "$PREV_ENV" ]; then _s5=1; else _s5=0; fi
    _selftest_assert_eq "快照文件生成" "1" "$_s5"
    restore_prev_env || true
    if [ -f "$PREV_ENV" ]; then _s6=1; else _s6=0; fi
    _selftest_assert_eq "还原后快照删除" "0" "$_s6"

    echo "[5] 源码包判据与清理"
    _fakeroot="$_sandbox/fakeroot"
    mkdir -p "$_fakeroot/.github" "$_fakeroot/tests" 2>/dev/null || true
    printf 'dev\n' > "$_fakeroot/AGENTS.md" 2>/dev/null || true
    printf 'mine\n' > "$_fakeroot/my-notes.txt" 2>/dev/null || true
    printf 't\n' > "$_fakeroot/tests/t.txt" 2>/dev/null || true
    printf '/AGENTS.md  export-ignore\n/.github/  export-ignore\n/tests/  export-ignore\n/.gitattributes  export-ignore\n' > "$_fakeroot/.gitattributes" 2>/dev/null || true
    if is_source_copy "$_fakeroot"; then _t1=1; else _t1=0; fi
    _selftest_assert_eq "有.github无.git判源码包" "1" "$_t1"
    mkdir -p "$_sandbox/fakegit/.git" 2>/dev/null || true
    if is_source_copy "$_sandbox/fakegit"; then _t2=1; else _t2=0; fi
    _selftest_assert_eq "有.git不判源码包" "0" "$_t2"
    if is_source_copy "$_sandbox"; then _t3=1; else _t3=0; fi
    _selftest_assert_eq "两者都没有不判源码包" "0" "$_t3"
    clean_source_files "$_fakeroot" || true
    if [ -e "$_fakeroot/.github" ] || [ -e "$_fakeroot/tests" ] || [ -e "$_fakeroot/AGENTS.md" ] || [ -e "$_fakeroot/.gitattributes" ]; then _t4=1; else _t4=0; fi
    _selftest_assert_eq "清理删掉源码文件" "0" "$_t4"
    if [ -f "$_fakeroot/my-notes.txt" ]; then _t5=1; else _t5=0; fi
    _selftest_assert_eq "用户自己的文件保留" "1" "$_t5"
    if is_source_copy "$_fakeroot"; then _t6=1; else _t6=0; fi
    _selftest_assert_eq "清理后不再判源码包" "0" "$_t6"

    echo "[6] 安装包结构校验"
    _pkg="$_sandbox/pkg"
    mkdir -p "$_pkg/win/lib" "$_pkg/mac/lib" 2>/dev/null || true
    printf '9.9.9' > "$_pkg/VERSION" 2>/dev/null || true
    # 本平台（mac）的包必须完整：入口自己声明库清单，目录里只放入口 + 菜单壳 + 定位器 + 声明的库。
    printf 'CORE_LIBS="base probe"\n' > "$_pkg/mac/envproxy.sh" 2>/dev/null || true
    printf '# menu\n' > "$_pkg/mac/打开菜单.command" 2>/dev/null || true
    printf '# locator\n' > "$_pkg/mac/locator.sh" 2>/dev/null || true
    printf '# lib\n' > "$_pkg/mac/lib/base.sh" 2>/dev/null || true
    printf '# lib\n' > "$_pkg/mac/lib/probe.sh" 2>/dev/null || true
    # 另一平台目录只是陪衬：校验只看本平台目录的文件集，但编码红线会扫全树。
    printf '\357\273\277# entry\n' > "$_pkg/win/envproxy.ps1" 2>/dev/null || true
    printf '\357\273\277# lib\n' > "$_pkg/win/lib/base.ps1" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p1=1; else _p1=0; fi
    _selftest_assert_eq "结构完整的包被接受" "1" "$_p1"
    if verify_package "$_pkg" "1.2.3" "mac"; then _p2=1; else _p2=0; fi
    _selftest_assert_eq "版本不符被拒绝" "0" "$_p2"
    printf '# lib\n' > "$_pkg/win/lib/base.ps1" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p3=1; else _p3=0; fi
    _selftest_assert_eq "库缺 BOM 被拒绝" "0" "$_p3"
    printf '\357\273\277# lib\n' > "$_pkg/win/lib/base.ps1" 2>/dev/null || true
    printf 'CORE_LIBS="base probe"\r\n' > "$_pkg/mac/envproxy.sh" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p4=1; else _p4=0; fi
    _selftest_assert_eq "壳含 CRLF 被拒绝" "0" "$_p4"
    printf 'CORE_LIBS="base probe"\n' > "$_pkg/mac/envproxy.sh" 2>/dev/null || true
    printf '\357\273\277' > "$_pkg/win/lib/empty.ps1" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p5=1; else _p5=0; fi
    _selftest_assert_eq "只剩 BOM 的截断文件被拒绝" "0" "$_p5"
    rm -f "$_pkg/win/lib/empty.ps1" 2>/dev/null || true
    rm -f "$_pkg/win/envproxy.ps1" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p6=1; else _p6=0; fi
    _selftest_assert_eq "缺另一平台入口照样接受" "1" "$_p6"
    printf '\357\273\277# entry\n' > "$_pkg/win/envproxy.ps1" 2>/dev/null || true
    # 内容集：缺一个声明的库、或多一个没声明的文件，都必须拒收——否则覆盖时
    # 删除循环会把缺的库当旧版残留删空，安装区变空壳还报成功。
    rm -f "$_pkg/mac/lib/probe.sh" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p7=1; else _p7=0; fi
    _selftest_assert_eq "缺一个声明的库被拒绝" "0" "$_p7"
    printf '# lib\n' > "$_pkg/mac/lib/probe.sh" 2>/dev/null || true
    printf '# x\n' > "$_pkg/mac/lib/backdoor.sh" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p8=1; else _p8=0; fi
    _selftest_assert_eq "多一个未声明的文件被拒绝" "0" "$_p8"
    rm -f "$_pkg/mac/lib/backdoor.sh" 2>/dev/null || true
    rm -f "$_pkg/mac/envproxy.sh" 2>/dev/null || true
    if verify_package "$_pkg" "9.9.9" "mac"; then _p9=1; else _p9=0; fi
    _selftest_assert_eq "只缺自己平台入口也被拒绝" "0" "$_p9"

    echo "[6b] 分包作用域（覆盖 legacy 全量树）"
    _leg="$_sandbox/legacy"; _spk="$_sandbox/split"; _stg="$_sandbox/stage"
    mkdir -p "$_leg/win" "$_leg/mac/lib" "$_leg/release-notes" "$_spk/mac/lib" "$_spk/release-notes" "$_stg" 2>/dev/null || true
    printf '9.9.9' > "$_leg/VERSION" 2>/dev/null || true
    printf '9.9.9' > "$_spk/VERSION" 2>/dev/null || true
    printf '#!/bin/bash\n# mac OLD\n' > "$_leg/mac/envproxy.sh" 2>/dev/null || true
    printf '#!/bin/bash\n# lib OLD\n' > "$_leg/mac/lib/base.sh" 2>/dev/null || true
    printf 'stale\n' > "$_leg/mac/old.sh" 2>/dev/null || true
    printf '# win OLD\n' > "$_leg/win/envproxy.ps1" 2>/dev/null || true
    printf 'stale\n' > "$_leg/win/old.ps1" 2>/dev/null || true
    printf '#!/bin/bash\n# mac NEW\n' > "$_spk/mac/envproxy.sh" 2>/dev/null || true
    printf '#!/bin/bash\n# lib NEW\n' > "$_spk/mac/lib/base.sh" 2>/dev/null || true
    printf 'notes\n' > "$_spk/release-notes/v9.md" 2>/dev/null || true
    if install_package "$_spk" "$_leg" "$_stg" "mac release-notes assets"; then _q0=1; else _q0=0; fi
    _selftest_assert_eq "作用域覆盖成功" "1" "$_q0"
    _selftest_assert_file_eq "本平台入口被更新" "$(printf '#!/bin/bash\n# mac NEW\n')" "$_leg/mac/envproxy.sh"
    if [ ! -f "$_leg/mac/old.sh" ]; then _q1=1; else _q1=0; fi
    _selftest_assert_eq "本平台残留被删" "1" "$_q1"
    _selftest_assert_file_eq "另一平台入口原样不动" "$(printf '# win OLD\n')" "$_leg/win/envproxy.ps1"
    if [ -f "$_leg/win/old.ps1" ]; then _q2=1; else _q2=0; fi
    _selftest_assert_eq "另一平台残留原样保留" "1" "$_q2"
    _selftest_assert_eq "共享 VERSION 落位" "9.9.9" "$(tr -d ' \t\r\n' < "$_leg/VERSION" 2>/dev/null)"
    # 写失败必须大声失败：目标只读时一个字节都写不进去，且返回非零。
    # root 不受权限位限制，且 Windows 的 git-bash 下 chmod 拦不住写——这段只在真 POSIX 非 root 跑
    #（CI 的 ubuntu 与日常的 macOS，本地 Windows 跑门禁时跳过并记一笔）。
    _q3=0
    if [ "$(id -u 2>/dev/null)" != "0" ]; then
        case "$(uname -s 2>/dev/null)" in
            MINGW*|MSYS*|CYGWIN*) echo "  SKIP 写不进去就报失败（非 POSIX 环境）";;
            *)
                chmod -w "$_leg/mac" 2>/dev/null || true
                if install_package "$_spk" "$_leg" "$_stg" "mac release-notes assets"; then _q3=1; else _q3=0; fi
                chmod +w "$_leg/mac" 2>/dev/null || true;;
        esac
    fi
    _selftest_assert_eq "写不进去就报失败" "0" "$_q3"

    echo "[7] 库清单与库实现"
    # 空壳库（只有注释、没有函数）在语法上完全合法，却会让整个 mac 侧起不来——
    # 装上去之后监控第一次调用就挂。这里逐个查"存在、非空、至少有一个函数定义"。
    for _lib in $CORE_LIBS; do
        _lf="$LIB_DIR/$_lib.sh"
        if [ -s "$_lf" ]; then _l0=1; else _l0=0; fi
        _selftest_assert_eq "库 $_lib.sh 存在且非空" "1" "$_l0"
        if grep -qE '^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{' "$_lf" 2>/dev/null; then _l1=1; else _l1=0; fi
        _selftest_assert_eq "库 $_lib.sh 里有函数定义" "1" "$_l1"
    done
    # 每个库的代表入口函数必须真的被定义出来（改名或写空壳都会在这里露出来）。
    for _pair in "base:merge_no_proxy" "probe:get_current_state" "env:apply_state" "runtime:run_monitor_loop" "package:install_package" "update:update_envproxy" "ops:install_envproxy"; do
        _lib="${_pair%%:*}"; _fn="${_pair##*:}"
        if [ "$(type -t "$_fn" 2>/dev/null || true)" = "function" ]; then _l2=1; else _l2=0; fi
        _selftest_assert_eq "库 $_lib 的代表函数 $_fn 已定义" "1" "$_l2"
    done

    echo "[8] 监控启动目标"
    # 监控必须从入口脚本启动：库不得自行推算"我在哪"——在库里 $0 / BASH_SOURCE 指的是库文件
    # 自己，拿它启动等于去跑一个跑不起来的文件（装完没有监控，日志里连一行都不会有）。
    if [ -n "$SCRIPT_PATH" ] && [ "$SCRIPT_PATH" = "$SCRIPT_DIR/envproxy.sh" ] && [ -f "$SCRIPT_PATH" ]; then _l3=1; else _l3=0; fi
    _selftest_assert_eq "入口公布的 SCRIPT_PATH 指向入口脚本本身" "1" "$_l3"

    echo "[8b] 运行时加固"
    # 监控的判据必须看**参数位**，不是看命令行里有没有 install/stop 这些字。
    # 装在名字带 install 的目录里的监控，用子串匹配会被当成一次性命令：
    # 于是"监控没在跑"→ 又起一个，停的时候也停不掉。
    if is_monitor_args "/bin/bash /Users/me/Downloads/install/mac/envproxy.sh"; then _r1=1; else _r1=0; fi
    _selftest_assert_eq "路径里带 install 的监控仍然算监控" "1" "$_r1"
    if is_monitor_args "/bin/bash /Users/me/mac/envproxy.sh"; then _r2=1; else _r2=0; fi
    _selftest_assert_eq "不带子命令的算监控" "1" "$_r2"
    if is_monitor_args "/bin/bash /Users/me/mac/envproxy.sh install"; then _r3=0; else _r3=1; fi
    _selftest_assert_eq "带 install 子命令的不算监控" "1" "$_r3"
    if is_monitor_args "/bin/bash /Users/me/mac/envproxy.sh status"; then _r4=0; else _r4=1; fi
    _selftest_assert_eq "带 status 子命令的不算监控" "1" "$_r4"
    if is_monitor_args "/usr/bin/sleep 100"; then _r5=0; else _r5=1; fi
    _selftest_assert_eq "别的进程不算监控" "1" "$_r5"

    # 操作锁：拿锁必须原子的。以前用 mkdir 拿锁、再把 pid 写进去——
    # 中间那个空窗里另一个进程读到空的 pid，会把锁当成陈旧的接管掉，
    # 两个安装同时跑就互相覆盖文件。现在用 ln：锁一出现就是完整的。
    _rlock="$_sandbox/.op.lock.test"
    if acquire_op_lock "$_rlock" >/dev/null 2>&1; then _r6=1; else _r6=0; fi
    _selftest_assert_eq "第一次拿锁成功" "1" "$_r6"
    if [ -f "$_rlock" ]; then _r7=1; else _r7=0; fi
    _selftest_assert_eq "锁文件存在" "1" "$_r7"
    if acquire_op_lock "$_rlock" >/dev/null 2>&1; then _r8=0; else _r8=1; fi
    _selftest_assert_eq "持锁者还在时第二个拿不到" "1" "$_r8"
    # 陈旧锁（持有者已经不在）必须能被接管——否则一次崩溃就把用户锁死在门外。
    rm -f "$_rlock" 2>/dev/null || true
    printf '999999\n' > "$_rlock" 2>/dev/null || true
    if acquire_op_lock "$_rlock" >/dev/null 2>&1; then _r9=1; else _r9=0; fi
    _selftest_assert_eq "陈旧的锁能被接管" "1" "$_r9"
    rm -f "$_rlock" 2>/dev/null || true
    # 锁内容必须就是持有者的 pid：读出来才能判断"持有者还在不在"。
    _rlock2="$_sandbox/.op.lock.test2"
    acquire_op_lock "$_rlock2" >/dev/null 2>&1 || true
    _r10=$(cat "$_rlock2" 2>/dev/null | tr -d ' \t\r\n')
    _selftest_assert_eq "锁里写的是持有者的 pid" "$$" "$_r10"
    rm -f "$_rlock2" 2>/dev/null || true

    # hook 改写必须原子：以前是就地截断重写，中途失败或被杀，
    # 用户的 .zshrc 就停在半截上，shell 一开就报错。
    _rcf="$_sandbox/rc-test"
    _rcsrc="$_sandbox/rc-src"
    printf 'old content\n' > "$_rcf" 2>/dev/null || true
    printf 'new content\n' > "$_rcsrc" 2>/dev/null || true
    if _write_rc_atomic "$_rcsrc" "$_rcf" 2>/dev/null; then _r11=1; else _r11=0; fi
    _selftest_assert_eq "原子写成功" "1" "$_r11"
    _selftest_assert_file_eq "内容换成了新的" "$(printf 'new content')" "$_rcf"
    # 软链不能被换成普通文件：mv 是原子的，但直接 mv 会把软链换成实体文件。
    # 有些环境（Windows 的 git-bash）建不出真软链——ln -s 会退化成复制，
    # 那时这条测不了，跳过并记一笔（真 macOS 与 CI 的 ubuntu 都测得到）。
    _rctarget="$_sandbox/rc-target"
    _rclink="$_sandbox/rc-link"
    printf 'target old\n' > "$_rctarget" 2>/dev/null || true
    printf 'target new\n' > "$_rcsrc" 2>/dev/null || true
    if ln -sf "$_rctarget" "$_rclink" 2>/dev/null && [ -L "$_rclink" ]; then
        _write_rc_atomic "$_rcsrc" "$_rclink" 2>/dev/null || true
        if [ -L "$_rclink" ]; then _r12=1; else _r12=0; fi
        _selftest_assert_eq "软链还是软链" "1" "$_r12"
        _selftest_assert_file_eq "软链指向的文件内容更新了" "$(printf 'target new')" "$_rctarget"
    else
        echo "  SKIP 软链改写（本机建不出真软链）"
    fi

    # 权限位要照原文件带过去（用户可能特意设过）。
    # Windows 的 git-bash 上 chmod 是空操作（MSYS 不实现 POSIX 权限），
    # 那时权限测不了，跳过并记一笔。
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) echo "  SKIP 权限位与快照权限（非 POSIX 环境）";;
        *)
            chmod 600 "$_rcf" 2>/dev/null || true
            printf 'again\n' > "$_rcsrc" 2>/dev/null || true
            _write_rc_atomic "$_rcsrc" "$_rcf" 2>/dev/null || true
            _rperm=$(_perm_of "$_rcf")
            _selftest_assert_eq "权限位保持不变" "600" "$_rperm"
            # 快照里是用户原来的代理地址，可能带账号密码。默认权限（同 umask，通常 0644）
            # 是同机其他用户都能读——凭据就这么漏出去了。
            rm -f "$PREV_ENV" 2>/dev/null || true
            snapshot_prev_env >/dev/null 2>&1 || true
            _rperm2=$(_perm_of "$PREV_ENV")
            _selftest_assert_eq "快照文件的权限是 600" "600" "$_rperm2"
            ;;
    esac

    # 自愈不许杀正在跑的监控：bootout 会给监控发 SIGTERM，
    # 而紧接着启的新监控可能抢不到单实例锁——于是"自愈"的结果是监控没了。
    if autorun_reload_needed 1; then _r13=1; else _r13=0; fi
    _selftest_assert_eq "明确要求时才重载代理" "1" "$_r13"
    if grep -q 'autorun_reload_needed' "$LIB_DIR/runtime.sh" 2>/dev/null; then _r14=1; else _r14=0; fi
    _selftest_assert_eq "set_autorun 走的是这个判据" "1" "$_r14"

    echo "[9] 菜单分派"
    # menu 子命令必须在入口分派里存在，show_menu 必须已定义；
    # 菜单列出的每个子命令都必须能在入口分派里找到（壳调回来的路不断）。
    if [ "$(type -t show_menu 2>/dev/null || true)" = "function" ]; then _l4=1; else _l4=0; fi
    _selftest_assert_eq "show_menu 已定义" "1" "$_l4"
    if grep -qE '^[[:space:]]*menu\)' "$SCRIPT_DIR/envproxy.sh" 2>/dev/null; then _l5=1; else _l5=0; fi
    _selftest_assert_eq "menu 在入口分派里存在" "1" "$_l5"
    for _ms in install status stop uninstall update; do
        if grep -qE "^[[:space:]]*$_ms\\)" "$SCRIPT_DIR/envproxy.sh" 2>/dev/null; then _l6=1; else _l6=0; fi
        _selftest_assert_eq "菜单子命令 $_ms 在入口分派里存在" "1" "$_l6"
    done

    echo "[10] 更新源表"
    # 更新入口按源表逐个试，第一个答出来的胜出。表坏了不会报错，只会悄悄退化成"只剩官方源"，
    # 直到官方源不可达那天才暴露——而那天正是最需要兜底的时刻。所以表的形状在这里钉住：
    # 每条七个字段、模板保留 @@ 占位符、优先路径合法、官方源排第一。
    _st_all=$(get_update_sources)
    if [ -n "$_st_all" ]; then _st1=1; else _st1=0; fi
    _selftest_assert_eq "源表至少有一个可用源" "1" "$_st1"
    _selftest_assert_eq "官方源排第一" "GitHub" "$(printf '%s\n' "$_st_all" | head -n 1 | cut -d'|' -f1)"
    # 模板表每条必须正好七个字段、保留 @@ 占位符、优先路径是已知值；代入后每行必须是成形地址
    # （四个地址都非空、占位符替换干净、网页路径落在 releases/latest 上、API 前缀是个 https 根）。
    # 不点名具体域名：加源是"表里加一行"，把域名写死会让以后加非 GitHub 源时自检直接失败。
    _st_tpl_ok=$(printf '%s\n' "$UPDATE_SOURCE_TABLE" | awk '
        NF != 7 { bad = 1 }
        $0 !~ /@@/ { bad = 1 }
        $3 != "Api" && $3 != "Web" { bad = 1 }
        END { print (bad ? 0 : 1) }')
    _selftest_assert_eq "源表每条七字段、模板带占位符、优先路径合法" "1" "$_st_tpl_ok"
    _st_out_ok=$(get_update_sources | awk -F'|' '
        NF != 6 { bad = 1 }
        $2 != "Api" && $2 != "Web" { bad = 1 }
        $3 == "" || $4 == "" || $5 == "" || $6 == "" { bad = 1 }
        $3 $4 $5 $6 ~ /@@/ { bad = 1 }
        $4 !~ /releases\/latest$/ { bad = 1 }
        $6 !~ /^https:\/\/[^\/]+\/./ { bad = 1 }
        END { print (bad ? 0 : 1) }')
    _selftest_assert_eq "仓库标识代入后四处地址成形、无占位符残留" "1" "$_st_out_ok"
    # 资产解析是纯函数，结果写进 ASSET_ID / ASSET_DIGEST 两个全局。
    # 样本照抄服务端真实格式：GitHub 的响应带缩进（冒号后有空格），只拿压缩 JSON 测
    # 等于钉住自己的假设，而不是钉住外部世界的事实。
    _st_asset_pretty='{
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
}'
    _st_asset_json='{"id":99,"tag_name":"v1.2.3","assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/12345","id":12345,"name":"EnvProxy-win.zip","uploader":{"login":"u","id":777}},{"url":"https://api.github.com/repos/o/r/releases/assets/67890","id":67890,"name":"EnvProxy-mac.tar.gz"}]}'
    get_asset_from_json "$_st_asset_pretty" 'EnvProxy-mac.tar.gz'
    _selftest_assert_eq "按文件名取 id（服务端缩进格式）" "67890" "$ASSET_ID"
    get_asset_from_json "$_st_asset_json" 'EnvProxy-mac.tar.gz'
    _selftest_assert_eq "按文件名取 id（压缩格式也认）" "67890" "$ASSET_ID"
    # 字段顺序是服务端的实现细节：name 在前时也必须取到**本条资产**的 id，不能取到上一条。
    _st_asset_reordered='{"assets":[{"id":111,"name":"EnvProxy-win.zip"},{"name":"EnvProxy-mac.tar.gz","id":222}]}'
    get_asset_from_json "$_st_asset_reordered" 'EnvProxy-mac.tar.gz'
    _selftest_assert_eq "字段顺序反过来仍取本条资产的 id" "222" "$ASSET_ID"
    _st_asset_space='{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/333","name":"Env Proxy mac.tar.gz"}]}'
    get_asset_from_json "$_st_asset_space" 'Env Proxy mac.tar.gz'
    _selftest_assert_eq "文件名里带空格也能匹配" "333" "$ASSET_ID"
    get_asset_from_json "$_st_asset_pretty" 'EnvProxy-nope.zip'
    _selftest_assert_eq "资产 JSON 里没有该文件时留空" "" "$ASSET_ID"
    get_asset_from_json 'not json' 'EnvProxy-win.zip'
    _selftest_assert_eq "资产 JSON 不合法时留空" "" "$ASSET_ID"
    get_asset_from_json '{"message":"API rate limit exceeded"}' 'EnvProxy-mac.tar.gz'
    _selftest_assert_eq "限流错误页不会给出 id" "" "$ASSET_ID"
    # 200 但不是 Release JSON（企业代理劫持页、错误对象）不能报"这版没提供安装包"——
    # 那是冤枉维护者，还让用户去手动下载（那里同样拿不到）。
    get_asset_from_json '<html><body>Login</body></html>' 'EnvProxy-mac.tar.gz'
    _selftest_assert_eq "HTML 页面不是 Release JSON" "other" "$ASSET_SCOPE"
    get_asset_from_json '{"message":"Bad credentials"}' 'EnvProxy-mac.tar.gz'
    _selftest_assert_eq "错误对象不是 Release JSON" "other" "$ASSET_SCOPE"
    get_asset_from_json "$_st_asset_json" 'EnvProxy-mac.tar.gz'
    _selftest_assert_eq "Release JSON 认得出来" "release" "$ASSET_SCOPE"
    get_asset_from_json "$_st_asset_json" 'EnvProxy-nope.zip'
    _selftest_assert_eq "Release JSON 里没有该文件时仍然是 Release JSON" "release" "$ASSET_SCOPE"
    # digest 的十六进制大小写两侧必须一致：对方改成大写时，不能一边验、一边静默不验。
    _st_asset_upper='{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/888","name":"EnvProxy-mac.tar.gz","digest":"sha256:1731CE10FDE048900C7B3A793D81CBA5EC8411D6E1FE82930B3C34BC82CFB4D5"}]}'
    get_asset_from_json "$_st_asset_upper" 'EnvProxy-mac.tar.gz'
    _selftest_assert_eq "大写 digest 认得出来并归一为小写" "sha256:1731ce10fde048900c7b3a793d81cba5ec8411d6e1fe82930b3c34bc82cfb4d5" "$ASSET_DIGEST"
    # 标签要编码后才拼进 URL（标签来自远端应答，不编码会拼出坏地址）。
    _selftest_assert_eq "普通标签不编码" "v1.2.3" "$(url_encode 'v1.2.3')"
    _selftest_assert_eq "标签里的空格要编码" "v1%202" "$(url_encode 'v1 2')"
    _selftest_assert_eq "标签里的斜杠要编码" "..%2F..%2Fevil" "$(url_encode '../../evil')"
    _selftest_assert_eq "标签里的问号要编码" "v1%3F2" "$(url_encode 'v1?2')"
    # 文件名必须逐字节相等：GitHub 的资产名大小写敏感，认成不敏感就会去下错文件。
    get_asset_from_json "$_st_asset_json" 'envproxy-mac.tar.gz'
    _selftest_assert_eq "文件名大小写不同不匹配" "" "$ASSET_ID"
    # 发布说明是自由文本，里面出现 },{ 或引号都不该把解析搞坏（切块式写法就会在这里翻车）。
    _st_asset_body='{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/444","id":444,"name":"EnvProxy-win.zip"}],"body":"示例 },{ 还有 \\"引号\\" 与 {花括号}"}'
    get_asset_from_json "$_st_asset_body" 'EnvProxy-win.zip'
    _selftest_assert_eq "发布说明里的 },{ 不影响取资产" "444" "$ASSET_ID"
    # 编号取自 url（那是我们真正要 GET 的端点），url 里没有才退回 id 字段。
    _st_asset_urlover='{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/555","id":999,"name":"EnvProxy-win.zip"}]}'
    get_asset_from_json "$_st_asset_urlover" 'EnvProxy-win.zip'
    _selftest_assert_eq "编号以 url 为准" "555" "$ASSET_ID"
    _st_asset_idonly='{"assets":[{"url":"https://example.invalid/x","id":666,"name":"EnvProxy-win.zip"}]}'
    get_asset_from_json "$_st_asset_idonly" 'EnvProxy-win.zip'
    _selftest_assert_eq "url 里没有编号时退回 id 字段" "666" "$ASSET_ID"
    # 编号形状不对就不认：0、前导零、二十位数都不该进 URL。
    for _st_bad in 0 007 12345678901234567890; do
        get_asset_from_json "{\"assets\":[{\"url\":\"https://api.github.com/repos/o/r/releases/assets/$_st_bad\",\"name\":\"EnvProxy-win.zip\"}]}" 'EnvProxy-win.zip'
        _selftest_assert_eq "编号 $_st_bad 不认" "" "$ASSET_ID"
    done
    # digest 是 GitHub 自己算的资产校验值：形状不对就当没有（老资产根本没这字段）。
    _st_asset_dg="sha256:$(printf 'a%.0s' $(seq 1 64))"
    _st_asset_digest="{\"assets\":[{\"url\":\"https://api.github.com/repos/o/r/releases/assets/777\",\"name\":\"EnvProxy-win.zip\",\"digest\":\"$_st_asset_dg\"}]}"
    get_asset_from_json "$_st_asset_digest" 'EnvProxy-win.zip'
    _selftest_assert_eq "digest 合法时取到" "$_st_asset_dg" "$ASSET_DIGEST"
    get_asset_from_json '{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/777","name":"EnvProxy-win.zip","digest":null}]}' 'EnvProxy-win.zip'
    _selftest_assert_eq "digest 为 null 时当作没有" "" "$ASSET_DIGEST"
    get_asset_from_json '{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/777","name":"EnvProxy-win.zip","digest":"sha256:XYZ"}]}' 'EnvProxy-win.zip'
    _selftest_assert_eq "digest 形状不对时当作没有" "" "$ASSET_DIGEST"
    # 问版本阶段的原因要分得清。解析层是纯函数，直接喂应答即可——不联网，
    # 也不用改别人的函数（在自检里重定义库函数会真的覆盖生产函数，库之间不能重名）。
    # 这些判据曾集体失效：原因写在全局、调用却套了命令替换，命令替换跑在子 shell 里，
    # 全局赋值出不来，于是限流、缺包、服务端故障全被报成"连不上"，
    # 用户会被叫去开翻墙软件（白折腾）。
    tag_from_api_response "x
429" ""
    _selftest_assert_eq "问版本：429 是配额用尽" "quota" "$TAG_FAILURE"
    tag_from_api_response "x
404" ""
    _selftest_assert_eq "问版本：404 是没这个版本" "missing" "$TAG_FAILURE"
    tag_from_api_response "x
403" "0"
    _selftest_assert_eq "问版本：403 且配额剩 0 是配额用尽" "quota" "$TAG_FAILURE"
    tag_from_api_response "x
403" "42"
    _selftest_assert_eq "问版本：403 但还有配额是被拒" "server" "$TAG_FAILURE"
    tag_from_api_response "x
500" ""
    _selftest_assert_eq "问版本：5xx 是服务端问题" "server" "$TAG_FAILURE"
    tag_from_api_response "x
200" ""
    _selftest_assert_eq "问版本：200 但内容不是 JSON 报连不上" "network" "$TAG_FAILURE"
    tag_from_api_response '{"tag_name":"v3.2.1"}
200' ""
    _selftest_assert_eq "问版本：200 且有标签时取到标签" "v3.2.1" "$TAG"
    # 网页路径：3xx 是正常应答，重定向目标里有标签就该取到。
    tag_from_web_response "302" "https://github.com/o/r/releases/tag/v1.2.3" ""
    _selftest_assert_eq "问版本：网页 302 里的标签取得到" "v1.2.3" "$TAG"
    _selftest_assert_eq "问版本：网页 302 不是失败" "" "$TAG_FAILURE"
    tag_from_web_response "302" "https://github.com/o/r/releases/latest" ""
    _selftest_assert_eq "问版本：重定向到预期之外的地方算服务端问题" "server" "$TAG_FAILURE"
    tag_from_web_response "429" "" ""
    _selftest_assert_eq "问版本：网页路 429 是配额用尽" "quota" "$TAG_FAILURE"
    # 下载到的文件要跟 GitHub 发布的资产校验值对一下。那个 digest 是查资产编号时顺带拿到的，
    # 不额外发请求也不额外下文件；老版本没有这个字段就跳过校验，不因此拦住更新。
    # 期望值用 "hello" 的已知 sha256 写死：这样测的是"对不对"，不是"某个工具算出来多少"，
    # 也不会因为本机少了 shasum 或 openssl 而测不成。
    _st_dg_file="${TMPDIR:-/tmp}/envproxy-selftest-digest.$$"
    printf 'hello' > "$_st_dg_file"
    check_asset_digest "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" "$_st_dg_file"
    _selftest_assert_eq "校验值对得上" "0" "$?"
    check_asset_digest "sha256:$(printf '0%.0s' $(seq 1 64))" "$_st_dg_file"
    _selftest_assert_eq "校验值对不上要报出来" "1" "$?"
    check_asset_digest "" "$_st_dg_file"
    _selftest_assert_eq "没有校验值就跳过" "2" "$?"
    rm -f "$_st_dg_file" 2>/dev/null || true
    # 查资产编号失败的原因也要参与挑选：否则"这条失败的路没走成"会隐形，
    # 最后只剩直连那一次的结果——直连 404 就被报成"发布方没提供安装包"，
    # 而真实原因可能是配额用尽，那是在冤枉维护者。
    asset_query_failure "429" ""
    _selftest_assert_eq "查资产编号：限流的原因带得出来" "quota" "$ASSET_FAILURE"
    _selftest_assert_eq "查资产编号：限流时不报缺包" "quota" "$(select_update_failure_kind "$ASSET_FAILURE missing")"
    asset_query_failure "200" ""
    _selftest_assert_eq "查资产编号：请求成功时先不判原因" "" "$ASSET_FAILURE"
    # 换源判据：必须比本地新，且不能比已选定的胜出版本旧。只判"比本地新"会让 1.5.0
    # 在 9.9.9 取不到包时被接受，把用户带到更旧的版本上。
    _selftest_assert_eq "换源：同版本接受" "0" "$(source_acceptable 9.9.9 9.9.9 1.0.0; echo $?)"
    _selftest_assert_eq "换源：更旧于胜出版本要拒绝" "1" "$(source_acceptable 1.5.0 9.9.9 1.0.0; echo $?)"
    _selftest_assert_eq "换源：不比本地新要拒绝" "1" "$(source_acceptable 1.0.0 9.9.9 1.0.0; echo $?)"
    _selftest_assert_eq "换源：没有胜出版本时只比本地" "0" "$(source_acceptable 2.0.0 '' 1.0.0; echo $?)"
    _selftest_assert_eq "换源：空版本要拒绝" "1" "$(source_acceptable '' 9.9.9 1.0.0; echo $?)"
    # 从重定向目标取标签必须做形态校验：仓库改名时对方会先 302 到改名后的路径，
    # 最后一段是字面量 "latest"，naive 取尾段会把垃圾当成版本号去拼下载地址。
    _selftest_assert_eq "从 tag 页重定向取标签" "v1.2.3" "$(get_tag_from_location 'https://github.com/o/r/releases/tag/v1.2.3')"
    _selftest_assert_eq "改名仓库的重定向不给标签" "" "$(get_tag_from_location 'https://github.com/new/r/releases/latest')"
    _selftest_assert_eq "含括号的标签原样保留" "v2026.09(jdk25)" "$(get_tag_from_location 'https://github.com/o/r/releases/tag/v2026.09(jdk25)')"
    # 源表展开后每条都必须带仓库标识，不能出现地址带洞的源。
    # 期望条数从表里现算，不写死：写死"1"会让以后按"加源 = 表里加一行"加第二个源时
    # 自检直接失败——那测的是"当前只有一条源"，不是行为对不对。
    _st_want=$(printf '%s\n' "$UPDATE_SOURCE_TABLE" | grep -c . || true)
    _st_one=$(printf '%s\n' "$(get_update_sources)" | grep -c . || true)
    _selftest_assert_eq "源表展开后的条数与表里一致" "$_st_want" "$_st_one"
    if [ -n "$(update_source_id official)" ]; then _st2=1; else _st2=0; fi
    _selftest_assert_eq "official 给出非空仓库标识" "1" "$_st2"

    # 失败原因分类：下载失败的原因决定用户该做什么（等一小时 / 开代理 / 手动下载 / 修磁盘），
    # 全塌缩成一个"失败"字符串就等于把判断责任推给使用者。
    _selftest_assert_eq "失败分类：404 是发布没提供该文件" "missing" "$(update_failure_kind 404 '')"
    _selftest_assert_eq "失败分类：410 也是文件没了" "missing" "$(update_failure_kind 410 '')"
    _selftest_assert_eq "失败分类：429 是配额用尽" "quota" "$(update_failure_kind 429 '')"
    _selftest_assert_eq "失败分类：403 且配额剩 0 是配额用尽" "quota" "$(update_failure_kind 403 0)"
    _selftest_assert_eq "失败分类：403 但还有配额是被拒绝" "server" "$(update_failure_kind 403 42)"
    _selftest_assert_eq "失败分类：403 读不到配额头算被拒绝" "server" "$(update_failure_kind 403 '')"
    _selftest_assert_eq "失败分类：5xx 是服务端问题" "server" "$(update_failure_kind 503 '')"
    _selftest_assert_eq "失败分类：其它状态码按连不上处理" "network" "$(update_failure_kind 418 '')"
    # 多个原因里挑一个报：只有"全都是 missing"才报 missing。中间设备被墙时会对什么都回 404，
    # 404 旁边还有个超时就报"发布漏了包"等于冤枉维护者。
    _selftest_assert_eq "挑原因：单个原样报出" "missing" "$(select_update_failure_kind missing)"
    _selftest_assert_eq "挑原因：两个相同合并成一个" "missing" "$(select_update_failure_kind missing missing)"
    _selftest_assert_eq "挑原因：404 旁边的超时报超时" "network" "$(select_update_failure_kind missing network)"
    _selftest_assert_eq "挑原因：404 旁边的配额报配额" "quota" "$(select_update_failure_kind missing quota)"
    _selftest_assert_eq "挑原因：临时目录不可写比超时更该先说" "local" "$(select_update_failure_kind network local)"
    _selftest_assert_eq "挑原因：没有原因时退回连不上" "network" "$(select_update_failure_kind '')"
    # 词表的顺序就是报告优先级：加一个原因不能悄悄改掉建议的先后，
    # 而 missing（指控发布方）必须排在最后。
    _ufk_n=$(printf '%s\n' $UPDATE_FAILURE_KINDS | grep -c . || true)
    _selftest_assert_eq "失败词表：每个原因只出现一次" "6" "$(printf '%s\n' $UPDATE_FAILURE_KINDS | sort -u | grep -c . || true)"
    _selftest_assert_eq "失败词表：本机问题排第一" "local" "$(printf '%s\n' $UPDATE_FAILURE_KINDS | head -n 1)"
    _selftest_assert_eq "失败词表：缺包排最后" "missing" "$(printf '%s\n' $UPDATE_FAILURE_KINDS | tail -n 1)"
    # 提示必须给出下一步动作，否则用户还是得自己猜。
    _ufm_m=$(update_failure_message missing GitHub)
    _ufm_q=$(update_failure_message quota GitHub)
    _ufm_n=$(update_failure_message network GitHub)
    _ufm_l=$(update_failure_message local GitHub)
    _selftest_assert_contains "提示：缺包要说手动下载" "手动下载" "$_ufm_m"
    _selftest_assert_contains "提示：配额要说会随时间恢复" "重试" "$_ufm_q"
    _selftest_assert_contains "提示：连不上要说开代理" "代理" "$_ufm_n"
    _selftest_assert_contains "提示：本机问题要说磁盘与权限" "磁盘" "$_ufm_l"
    _selftest_assert_eq "提示：没有一种说法会声称成功" "0" "$(for _k in missing quota server network bad-content local; do update_failure_message "$_k" GitHub; done | grep -c '成功' || true)"

    # ==========================================================================
    # 端口枚举失败 = 这一轮不知道，不是"没有端口"
    # ==========================================================================
    # 读不出来却被当成空表，状态机会判 off -> 把用户的代理环境变量删掉。
    # 与 Windows 侧同形：枚举失败要传上去，状态机据此沿用上一状态。
    _st_broken="$_sandbox/brokenbin"
    mkdir -p "$_st_broken" 2>/dev/null || true
    printf '#!/bin/sh\nexit 127\n' > "$_st_broken/lsof" 2>/dev/null || true
    printf '#!/bin/sh\nexit 127\n' > "$_st_broken/netstat" 2>/dev/null || true
    chmod +x "$_st_broken/lsof" "$_st_broken/netstat" 2>/dev/null || true
    if [ -x "$_st_broken/lsof" ] && [ -x "$_st_broken/netstat" ]; then
        _st_oldpath="$PATH"
        PATH="$_st_broken:$PATH"
        export PATH
        _st_ports=$(get_listening_ports)
        _st_rc=$?
        _selftest_assert_eq "端口枚举读不出来时返回非 0（不能当成空表）" "1" "$_st_rc"
        # 状态判定在枚举失败时要沿用上一状态：get_current_state 返回非 0。
        # 这一步必须在坏掉的 PATH 下做（枚举要真的失败）。
        CACHED_PORT=""
        get_current_state
        _st_state_rc=$?
        PATH="$_st_oldpath"
        export PATH
        _selftest_assert_eq "枚举失败时状态判定返回非 0（上层据此沿用上一状态）" "1" "$_st_state_rc"
    else
        echo "  SKIP 造不出坏掉的 lsof/netstat 桩（权限或文件系统不支持）"
    fi

    # 入口参数守卫：多余的参数、别处用的 --purge，都要报用法错误（退出码 2），
    # 不许静默进入监控模式。两道守卫都在分派之前触发，所以这两个调用不会真的装/删任何东西。
    _sg_rc=0
    /bin/bash "$SCRIPT_PATH" install --purge >/dev/null 2>&1 || _sg_rc=$?
    _selftest_assert_eq "入口：--purge 用在 uninstall 以外要报用法错误" "2" "$_sg_rc"
    _sg_rc=0
    /bin/bash "$SCRIPT_PATH" status extra >/dev/null 2>&1 || _sg_rc=$?
    _selftest_assert_eq "入口：多余的位置参数要报用法错误" "2" "$_sg_rc"

    # 带开关的一次性命令不能被当成监控：
    # 判据是脚本路径之后的第一个词，不是最后一个词。
    _selftest_assert_eq "带开关的一次性命令不是监控: uninstall --purge" "1" "$(is_monitor_args "/bin/bash $SCRIPT_PATH uninstall --purge" && echo 0 || echo 1)"
    _selftest_assert_eq "带开关的一次性命令不是监控: update --yes" "1" "$(is_monitor_args "/bin/bash $SCRIPT_PATH update --yes" && echo 0 || echo 1)"
    _selftest_assert_eq "带开关的一次性命令不是监控: install --purge" "1" "$(is_monitor_args "/bin/bash $SCRIPT_PATH install --purge" && echo 0 || echo 1)"

    # ==========================================================================
    # 资产解析契约：同一批应答，两侧必须得出同一个结论
    # ==========================================================================
    # 用例放在 tests/asset-cases.txt（仓库内文件；安装包里没有这一份，
    # 所以找不到就跳过——自检在安装副本里也要能跑）。
    # 每一行还打印成 "contract ..."，门禁 10 把两边的这些行互相比一次：
    # 文本层面的门禁看不出行为漂移，行为层面才看得出来。
    _st_cases="$SCRIPT_DIR/../tests/asset-cases.txt"
    if [ -f "$_st_cases" ]; then
        _st_seen=0
        while IFS='|' read -r _st_name _st_scope _st_id _st_digest _st_fail _st_body; do
            case "$_st_name" in ""|'#'*) continue ;; esac
            get_asset_from_json "$_st_body" "EnvProxy-test.zip"
            _st_got_id="$ASSET_ID"
            _st_got_digest="$ASSET_DIGEST"
            _st_got_fail=""
            if [ -z "$ASSET_ID" ]; then
                _st_got_fail=$(asset_failure_from_scope "$ASSET_SCOPE")
            fi
            _selftest_assert_eq "资产契约 正文种类: $_st_name" "$_st_scope" "$ASSET_SCOPE"
            _selftest_assert_eq "资产契约 编号: $_st_name" "$_st_id" "$_st_got_id"
            _selftest_assert_eq "资产契约 校验值: $_st_name" "$_st_digest" "$_st_got_digest"
            _selftest_assert_eq "资产契约 失败原因: $_st_name" "$_st_fail" "$_st_got_fail"
            echo "contract $_st_name $ASSET_SCOPE $_st_got_id $_st_got_digest $_st_got_fail"
            _st_seen=$((_st_seen + 1))
        done < "$_st_cases"
        _selftest_assert_eq "资产契约 用例都跑到了" "17" "$_st_seen"
    else
        echo "  SKIP 找不到 tests/asset-cases.txt（仓库内的用例文件）"
    fi

    rm -rf "$_sandbox" 2>/dev/null || true
    if [ "$_selftest_fails" -eq 0 ]; then
        echo "自检全部通过"
        return 0
    fi
    echo "自检失败：$_selftest_fails 项"
    return 1
}

# 更新收尾不需要单独的子命令：覆盖完成后由更新入口 exec 安装根里的新脚本跑 install
# （从安装根执行，路径记录/自启动/监控才会落在安装根）。

# ------------------------------------------------------------------------------
# 10. 子命令
# ------------------------------------------------------------------------------
install_envproxy() {
    echo "======== EnvProxy 安装 (macOS) ========"
    if [ "$(id -u 2>/dev/null)" = "0" ]; then echo "当前是 root 身份：动的将是 root 的配置，日常使用请用普通终端重做一遍。"; fi
    # 先快照用户原值：之后卸载时按它还原，覆盖前留底。
    snapshot_prev_env || true
    if set_autorun; then
        echo "[1/3] 开机自启动：已写入（LaunchAgent + 固定定位器）"
    else
        echo "[1/3] 开机自启动：写入失败，请检查 ~/Library/LaunchAgents 是否可写"
    fi
    if insert_shell_hooks; then
        echo "[2/3] 终端集成：已写入 shell hook（zsh/bash，新开终端生效；fish 暂不支持，见故障排查）"
    else
        echo "[2/3] 终端集成：写入失败，请检查 ~/.zshenv 是否可写"
    fi
    update_path_record
    if start_monitor 1; then
        echo "[3/3] 监控进程：已启动"
    else
        echo "[3/3] 监控进程：未能确认运行，请用菜单"查看状态"核对"
        echo "      一台电脑只留一份安装；另一个副本的监控在跑时会占住单实例锁。"
    fi
    CURRENT_STATE="off"
    get_current_state || true
    apply_state "$CURRENT_STATE" || true
    sleep 1
    echo ""
    show_status
    echo ""
    echo "提示：之后【新打开】的终端/程序自动获得代理；"
    echo "      已经开着的旧窗口不会自动变化，重开一个即可。"
}

uninstall_envproxy() {
    _purge="$1"
    echo "======== EnvProxy 卸载（一键恢复原状）========"
    if [ "$(id -u 2>/dev/null)" = "0" ]; then echo "当前是 root 身份：动的将是 root 的配置，日常使用请用普通终端重做一遍。"; fi
    stop_monitor || true
    remove_autorun
    rm -f "$LOCATOR_PATH" "$PATH_CONF" 2>/dev/null || true
    remove_shell_hooks
    _remove_log=0
    if [ "$_purge" = "1" ]; then
        _remove_log=1
    else
        printf "历史日志 monitor/monitor.log 是否保留？[Y] 保留（默认） / [N] 彻底删除: "
        _choice=""
        if read -r _choice < /dev/tty 2>/dev/null; then :; else _choice=""; fi
        case "$_choice" in [Nn]*) _remove_log=1;; *) _remove_log=0;; esac
    fi
    if [ $_remove_log -eq 1 ]; then
        rm -rf "$MONITOR_DIR" 2>/dev/null || true
    else
        rm -f "$PID_FILE" "$STOP_FLAG" 2>/dev/null || true
        if [ -d "$MONITOR_DIR" ] && [ -z "$(ls -A "$MONITOR_DIR" 2>/dev/null)" ]; then
            rm -f "$PID_FILE" "$STOP_FLAG" 2>/dev/null || true
        fi
    fi
    _ghost=$(get_monitor_pid || true)
    if [ -n "$_ghost" ]; then kill -9 "$_ghost" 2>/dev/null || true; sleep 0.5; fi
    # Mac 侧写变量无 Win 式进程内写锁：靠前面先停监控把竞态窗口收到最小（单实例文件锁另保安装互斥）。
    remove_user_env_vars
    # 按安装时的快照还用户原值（若有），还完删掉快照。
    restore_prev_env || true
    # launchd 的两个重定向文件（StandardOutPath/StandardErrorPath）是运行时管道，不是黑匣子：
    # 一律清掉，"恢复到安装前的状态"才成立。唯一的黑匣子是 monitor/monitor.log，
    # 它的去留由上面那次询问决定。
    rm -f "$ENVPROXY_HOME/monitor.stdout.log" "$ENVPROXY_HOME/monitor.stderr.log" 2>/dev/null || true
    # 非 purge 也只保留项目内日志：固定目录空了就删，不留空壳
    if [ -d "$ENVPROXY_HOME" ] && [ -z "$(ls -A "$ENVPROXY_HOME" 2>/dev/null)" ]; then
        rmdir "$ENVPROXY_HOME" 2>/dev/null || true
    fi
    # 卸载末尾回读复检：上面每一步都可能静默失败，定论必须由复读结果决定。
    # DIVERGE(Mac): 复检项按平台映射——plist 对应 Windows 的 Run 键，
    # proxy.env 对应注册表变量，其余同源。
    _dirty=""
    if launchctl list 2>/dev/null | grep -qF "$PLIST_LABEL"; then _dirty="$_dirty 开机自启动项仍在；"; fi
    if [ -f "$PLIST_PATH" ]; then _dirty="$_dirty 自启动文件仍在；"; fi
    if [ -f "$LOCATOR_PATH" ]; then _dirty="$_dirty 定位器文件仍在；"; fi
    if [ -f "$PROXY_ENV" ]; then _dirty="$_dirty 代理变量文件仍在；"; fi
    if [ -f "$PREV_ENV" ]; then _dirty="$_dirty 变量快照仍在；"; fi
    if [ -f "$PATH_CONF" ]; then _dirty="$_dirty 路径记录仍在；"; fi
    if [ -f "$ENVPROXY_HOME/monitor.stdout.log" ] || [ -f "$ENVPROXY_HOME/monitor.stderr.log" ]; then _dirty="$_dirty 自启动重定向残留；"; fi
    # hook 名单与 remove_shell_hooks 同一份（改一边必须改另一边）：残留整块即脏。
    for _rc in "$HOME/.zshenv" "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zlogin" "$HOME/.bash_profile" "$HOME/.bashrc"; do
        if grep -qxF "$HOOK_START" "$_rc" 2>/dev/null; then _dirty="$_dirty shell hook 残留；"; break; fi
    done
    if proxy_vars_present 2>/dev/null; then _dirty="$_dirty 代理变量仍在；"; fi
    if [ -n "$(get_monitor_pid || true)" ]; then _dirty="$_dirty 监控进程仍在；"; fi
    if [ $_remove_log -eq 1 ] && [ -f "$LOG_FILE" ]; then _dirty="$_dirty 历史日志未能删除；"; fi
    if [ -z "$_dirty" ]; then
        echo "[完成] 监控已停、自启动已删、定位器已清、代理变量已清除。"
        if [ $_remove_log -eq 1 ]; then
            echo "        历史日志已一并彻底删除。"
        else
            echo "        历史日志保留在 monitor/monitor.log（黑匣子，供日后排查）。"
        fi
        echo "        电脑已恢复到安装前的状态，无需重启。"
    else
        echo "[未完成] 以下残留请手动处理：$_dirty"
        echo "        可再跑一次 uninstall，或手动删除上述位置。"
    fi
}

show_status() {
    echo "======== EnvProxy 状态 (macOS) ========"
    _m=$(get_monitor_pid || true)
    if [ -n "$_m" ]; then echo "监控进程 : 运行中 (PID $_m)"; else echo "监控进程 : 未运行"; fi
    if launchctl list 2>/dev/null | grep -qF "$PLIST_LABEL"; then
        echo "开机自启 : 已启用"
    else
        if [ -f "$PLIST_PATH" ]; then echo "开机自启 : 已写入但未加载"; else echo "开机自启 : 未启用"; fi
    fi
    _port=$(get_active_proxy_port 1 2>/dev/null || true)
    if [ -n "$_port" ]; then
        echo "翻墙代理 : 已开启（本地端口 $_port 监听中）"
    else
        echo "翻墙代理 : 未检测到（当前无翻墙代理在运行）"
    fi
    _cur=$(get_current_proxy_port 2>/dev/null || true)
    if [ -n "$_cur" ]; then echo "代理变量 : 已注入 (http://127.0.0.1:$_cur)"; else echo "代理变量 : 无（直连状态）"; fi
    # 版本信息（只读：查不到只提示，不写文件、不提问）
    _local_ver=$(get_local_version || true)
    if [ -n "$_local_ver" ]; then echo "本地版本 : v$_local_ver"; else echo "本地版本 : 未知"; fi
    if get_remote_version; then
        echo "最新版本 : $REMOTE_TAG"
        if is_dev_copy; then
            echo "更新状态 : 开发副本（更新走 git pull，本入口不改动文件）"
        elif is_source_copy; then
            echo "更新状态 : 源码包（更新入口会先确认用途再动手）"
        elif [ -z "$_local_ver" ]; then
            echo "更新状态 : 可用菜单 检查更新 升级"
        else
            _newer=$(compare_versions "$_local_ver" "$REMOTE_VERSION" || true)
            if [ "$_newer" -gt 0 ] 2>/dev/null; then
                echo "更新状态 : 本地版本比最新发布版新"
            else
                _older=$(compare_versions "$REMOTE_VERSION" "$_local_ver" || true)
                if [ "$_older" -gt 0 ] 2>/dev/null; then
                    echo "更新状态 : 发现新版，用菜单 检查更新 可升级"
                else
                    echo "更新状态 : 已是最新"
                fi
            fi
        fi
    else
        # 状态显示也要说清是哪一类失败：笼统说"都不可达"会让用户以为是网络问题，
        # 而限流（等一小时）、缺包（手动下载）要做的动作完全不同。
        echo "最新版本 : 检查失败（$(update_failure_message "${REMOTE_FAILURE_KIND:-network}" "所有更新源")）"
        echo "更新状态 : 未知"
    fi
    echo "---------------- 最近日志 ----------------"
    if [ -f "$LOG_FILE" ]; then
        tail -n 3 "$LOG_FILE" 2>/dev/null | sed 's/^/  /' || echo "  （暂无日志）"
    else
        echo "  （暂无日志）"
    fi
    echo "=================================="
}

# ------------------------------------------------------------------------------
# 菜单（唯一双击入口"打开菜单"背后：编号→现有子命令，不新增行为）
# 菜单只做三件事：打印、读编号、起子进程跑对应子命令后回到菜单。
# 每个动作都走一遍入口子命令的完整路径（含操作锁）：菜单自己不拿锁，
# 所以菜单里的 bug 最多影响菜单显示，动不了安装区。五个动作与入口子命令一一对应。
# 非交互环境（stdin 不是终端）直接退出并提示，不死循环。
show_menu() {
    if [ ! -t 0 ]; then
        echo "菜单需要双击 打开菜单.command 使用，管道调用请直接用 install/status/stop/uninstall/update 子命令。"
        return 1
    fi
    while true; do
        echo ""
        echo "======== EnvProxy 菜单 (macOS) ========"
        # 抬头只读瞬时项（监控在不在、本地版本），不做网络探测，不卡菜单。
        _hm=$(get_monitor_pid || true)
        _hver=$(get_local_version || true)
        [ -z "$_hver" ] && _hver="未知"
        if [ -n "$_hm" ]; then _hmon="运行中 (PID $_hm)"; else _hmon="未运行"; fi
        echo "当前：监控$_hmon，本地版本 v$_hver（详情选 2 查看状态）"
        echo "  [1] 安装 / 修复（首次安装；觉得不对劲就点它）"
        echo "  [2] 查看状态（监控、翻墙、变量、版本）"
        echo "  [3] 停止监控（停掉并恢复直连，下次登录回来）"
        echo "  [4] 一键恢复（彻底卸载，回到没装之前）"
        echo "  [5] 检查更新（有新版先说明，同意才装）"
        echo "  [0] 退出"
        printf "选一个（回车=查看状态）："
        if ! IFS= read -r _choice; then
            echo ""
            echo "菜单需要双击 打开菜单.command 使用。"
            return 0
        fi
        # 首尾空格不算输错（与 Windows 侧 .Trim() 同语义）。
        _choice=$(printf '%s' "$_choice" | tr -d '[:space:]')
        [ -z "$_choice" ] && _choice="2"
        case "$_choice" in
            1) _msub="install";;
            2) _msub="status";;
            3) _msub="stop";;
            4) _msub="uninstall";;
            5) _msub="update";;
            0) return 0;;
            *) echo "没有这个编号，重输一个。"; continue;;
        esac
        # 子进程跑完整子命令：与入口子命令走的是同一条路（含锁、确认、复检）。
        /bin/bash "$SCRIPT_PATH" "$_msub" || echo "启动失败（退出码 $?）。"
    done
}
