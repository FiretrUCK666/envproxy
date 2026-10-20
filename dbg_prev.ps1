$sh = @'
set -u
D=/tmp/ep-dbg-$$
mkdir -p "$D"
export HOME="$D"
export ENVPROXY_HOME="$D/.envproxy"
PREV_ENV="$ENVPROXY_HOME/prev.env"
mkdir -p "$ENVPROXY_HOME"

# 复刻 snapshot_prev_env 的写法
_sntmp="$PREV_ENV.tmp.$$"
{
  for _v in HTTP_PROXY http_proxy; do
    _cur=""
    printf '%s\t%s\n' "$_v" "$_cur"
  done
} > "$_sntmp" 2>/dev/null && mv "$_sntmp" "$PREV_ENV" 2>/dev/null || rm -f "$_sntmp" 2>/dev/null || true
echo "  写入后权限: $(stat -c '%a' "$PREV_ENV" 2>/dev/null || echo '?')"
[ -f "$PREV_ENV" ] && chmod 600 "$PREV_ENV" 2>/dev/null || true
echo "  chmod 后权限: $(stat -c '%a' "$PREV_ENV" 2>/dev/null || echo '?')"

echo ""
echo "  stat -f '%Lp' 的输出: [$(stat -f '%Lp' "$PREV_ENV" 2>/dev/null | head -n 1)]"
echo "  stat -c '%a' 的输出:  [$(stat -c '%a' "$PREV_ENV" 2>/dev/null | head -n 1)]"
rm -rf "$D"
'@
Set-Content -Path "$env:TEMP\dbg_prev.sh" -Value $sh -Encoding utf8
& "C:\Program Files\Git\bin\bash.exe" "$env:TEMP\dbg_prev.sh" 2>&1