#!/bin/sh
# Optional foreground nginx launcher. Send info-level errors through a metadata
# allowlist; raw nginx info logs can contain request URLs and header values.
set -eu
source_config=${1:-/etc/nginx/nginx.conf}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
grep -q '^error_log /dev/stderr warn;$' "$source_config" || { echo 'unsupported gateway error-log configuration' >&2; exit 64; }
work=$(mktemp -d "${TMPDIR:-/tmp}/codex-gateway.XXXXXX")
nginx_pid=''; filter_pid=''; stopping=0
cleanup() {
    [ -z "$nginx_pid" ] || kill -TERM "$nginx_pid" 2>/dev/null || :
    [ -z "$filter_pid" ] || kill -TERM "$filter_pid" 2>/dev/null || :
    rm -f "$work/errors" "$work/nginx.conf"
    rmdir "$work"
}
trap cleanup EXIT
trap 'stopping=1; [ -z "$nginx_pid" ] || kill -TERM "$nginx_pid" 2>/dev/null || :' TERM INT
trap 'stopping=1; [ -z "$nginx_pid" ] || kill -QUIT "$nginx_pid" 2>/dev/null || :' QUIT
sed 's@^error_log /dev/stderr warn;$@error_log /dev/stderr info;@' "$source_config" > "$work/nginx.conf"
mkfifo "$work/errors"
awk -W interactive -f "$script_dir/codex-gateway-error-log.awk" < "$work/errors" >&2 &
filter_pid=$!
nginx -c "$work/nginx.conf" -g 'daemon off;' 2> "$work/errors" &
nginx_pid=$!
status=0
wait "$nginx_pid" || status=$?
# A terminating signal can interrupt wait before nginx has reaped its workers.
if kill -0 "$nginx_pid" 2>/dev/null; then wait "$nginx_pid" || :; fi
nginx_pid=''
[ "$stopping" -eq 0 ] || status=0
wait "$filter_pid" || :
filter_pid=''
exit "$status"
