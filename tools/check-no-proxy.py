#!/usr/bin/env python3
"""校验 NO_PROXY 默认值的写法，并验证真实网络库能否正常工作。

为什么需要这条门禁：NO_PROXY 里 IPv6 的写法有两种，只有一种是各家的共同规范。
写错不会报错、也不会在本地立刻表现，而是让某个 HTTP 库在**每一次请求**上抛异常
（httpx 遇到 `[::1]` 会抛 InvalidURL: Invalid port: ':1]'）。
这类问题只在真正用到那个库时才炸，靠人工核对必然漏，所以放进 CI 每次都验。

只依赖 Python 标准库。装了 httpx 就顺带真跑一次请求，没装则跳过（不算失败）。

用法：python tools/check-no-proxy.py     （仓库根下执行）
"""
import http.server
import os
import re
import subprocess
import sys
import sysconfig
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failures = []
notes = []


def read_default_no_proxy():
    """两平台的核心脚本各自只有一处默认例外集定义，从源码读取，避免第三份副本。"""
    values = {}
    ps1 = os.path.join(ROOT, "win", "envproxy.ps1")
    with open(ps1, encoding="utf-8-sig") as fh:
        m = re.search(r'^\$DefaultNoProxy\s*=\s*"([^"]*)"', fh.read(), re.M)
    values["win/envproxy.ps1"] = m.group(1) if m else None

    sh = os.path.join(ROOT, "mac", "envproxy.sh")
    with open(sh, encoding="utf-8") as fh:
        m = re.search(r'^DEFAULT_NO_PROXY="([^"]*)"', fh.read(), re.M)
    values["mac/envproxy.sh"] = m.group(1) if m else None
    return values


def check_declared_values(values):
    for path, value in values.items():
        if value is None:
            failures.append("%s: 没有找到默认例外集的定义" % path)
            continue
        if "[::1]" in value:
            failures.append(
                "%s: 默认例外集含方括号写法 [::1]；NO_PROXY 里 IPv6 必须裸写，"
                "方括号会让 httpx 的每一次请求都抛 InvalidURL" % path)
        if "::1" not in value:
            failures.append("%s: 默认例外集缺少 IPv6 本机地址 ::1" % path)
        if "localhost" not in value or "127.0.0.1" not in value:
            failures.append("%s: 默认例外集缺少 localhost 或 127.0.0.1" % path)
        notes.append("%s 默认值 = %s" % (path, value))

    distinct = {v for v in values.values() if v is not None}
    if len(distinct) > 1:
        failures.append("两平台的默认例外集不一致：%s" % values)


def check_stdlib_bypass():
    """标准库的判定：本机地址必须被认作直连。"""
    text = "localhost,127.0.0.1,::1"
    os.environ["NO_PROXY"] = text
    os.environ["no_proxy"] = text
    import urllib.request
    for host in ("127.0.0.1", "::1", "[::1]"):
        try:
            got = bool(urllib.request.proxy_bypass(host))
        except Exception as exc:              # noqa: BLE001
            failures.append("urllib 判定 %s 时抛异常：%r" % (host, exc))
            continue
        notes.append("urllib proxy_bypass(%-7s) = %s" % (host, got))
        if host == "127.0.0.1" and not got:
            failures.append("urllib 不认为 127.0.0.1 直连；本机地址必须直连")


def find_httpx_python():
    """httpx 不一定装在当前解释器里，找一个装了它的解释器来跑真请求。"""
    if _has_httpx(sys.executable):
        return sys.executable
    for name in ("python3", "python", "py"):
        path = _which(name)
        if path and _has_httpx(path):
            return path
    user_site = sysconfig.get_paths().get("purelib")
    if user_site and os.path.isdir(user_site) and _has_httpx(sys.executable, extra_site=user_site):
        return sys.executable
    return None


def _which(name):
    from shutil import which
    return which(name)


def _has_httpx(python, extra_site=None):
    code = "import httpx" if not extra_site else (
        "import sys; sys.path.insert(0, %r); import httpx" % extra_site)
    try:
        return subprocess.run([python, "-c", code], capture_output=True).returncode == 0
    except Exception:                          # noqa: BLE001
        return False


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args):
        pass


CHILD = r'''
import os, sys
val = sys.argv[1]; target = sys.argv[2]
for k in list(os.environ):
    if k.lower().endswith("_proxy"):
        os.environ.pop(k, None)
os.environ["NO_PROXY"] = val
os.environ["no_proxy"] = val
import httpx
with httpx.Client(timeout=5.0) as client:
    resp = client.get(target)
print("status=%d" % resp.status_code)
'''


def check_httpx(python):
    if python is None:
        notes.append("未找到装有 httpx 的解释器，跳过真请求验证（不算失败）")
        return
    server = http.server.HTTPServer(("127.0.0.1", 0), _Handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        target = "http://127.0.0.1:%d/" % port
        for value, expect_ok in (("localhost,127.0.0.1,::1", True),
                                 ("localhost,127.0.0.1,::1,[::1]", False)):
            proc = subprocess.run([python, "-c", CHILD, value, target],
                                  capture_output=True, text=True)
            ok = proc.returncode == 0
            tag = "通过" if ok == expect_ok else "与预期不符"
            notes.append("httpx 请求 %-28s -> %s（%s）" % (value, "成功" if ok else "失败", tag))
            if ok != expect_ok:
                detail = (proc.stderr or "").strip().splitlines()
                failures.append("httpx 对 %s 的行为与预期不符：%s"
                                % (value, detail[-1] if detail else "无输出"))
    finally:
        server.shutdown()


def main():
    check_declared_values(read_default_no_proxy())
    check_stdlib_bypass()
    check_httpx(find_httpx_python())

    print("检查项：")
    for line in notes:
        print("  " + line)
    if failures:
        print("\n不通过：")
        for line in failures:
            print("  " + line)
        return 1
    print("\n全部通过。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
