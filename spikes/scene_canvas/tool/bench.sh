#!/bin/bash
# One spike run on a headless Weston (GL renderer on the real GPU, 120 Hz virtual output).
# Usage: scene_bench.sh <bundle-binary> <outfile> [extra env assignments...]
# env: W H SCALE (output size/scale; default 1600x1000 @1), SHOOT_AT=<s> (compositor screenshot that long after launch,
#      saved next to <outfile> as <outfile>.png)
set -u
bin=$1; out=$2; shift 2
export XDG_RUNTIME_DIR=/run/user/$(id -u)
sock=wl-spike-$$
W=${W:-1600}; H=${H:-1000}; SCALE=${SCALE:-1}
weston --backend=headless --renderer=gl --width=$W --height=$H --scale=$SCALE --refresh-rate=120000 \
  --socket=$sock --idle-time=0 --no-config ${SHOOT_AT:+--debug} >/tmp/weston-$$.log 2>&1 &
wpid=$!
for i in $(seq 50); do [ -S $XDG_RUNTIME_DIR/$sock ] && break; sleep 0.1; done
env GDK_BACKEND=wayland WAYLAND_DISPLAY=$sock RAFT_LINUX_VSYNC_STATS=1 "$@" timeout 120 "$bin" >"$out" 2>&1 &
apid=$!
if [ -n "${SHOOT_AT:-}" ]; then
  sleep "$SHOOT_AT"
  d=$(mktemp -d); (cd $d && WAYLAND_DISPLAY=$sock weston-screenshooter >/dev/null 2>&1; mv $d/*.png "$out.png" 2>/dev/null); rm -rf $d
fi
wait $apid
rc=$?
kill $wpid 2>/dev/null; wait $wpid 2>/dev/null
echo "rc=$rc" >>"$out"
grep -iE "error|warn" /tmp/weston-$$.log | head -5 >>"$out"; rm -f /tmp/weston-$$.log
