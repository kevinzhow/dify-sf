#!/usr/bin/env bash
# Runs one native client in its own Weston compositor. No X11 or shared display.
set -euo pipefail
: "${DIFYSF_CLIENT_BINARY:?Set the path to the built Linux dify_sf_app binary}"
: "${DIFYSF_MCP_RUNTIME_ROOT:?Set an owner-only writable runtime root}"
umask 077
runtime=$(mktemp -d "$DIFYSF_MCP_RUNTIME_ROOT/dify-sf-mcp.XXXXXX")
export XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY=wayland-dify-mcp GDK_BACKEND=wayland GSETTINGS_BACKEND=memory
client_pid='' compositor_pid=''
cleanup() {
  trap - EXIT INT TERM
  if [[ -n "$client_pid" ]]; then kill -TERM "$client_pid" 2>/dev/null || true; wait "$client_pid" 2>/dev/null || true; fi
  if [[ -n "$compositor_pid" ]]; then kill -TERM "$compositor_pid" 2>/dev/null || true; wait "$compositor_pid" 2>/dev/null || true; fi
  # Weston removes its socket and lock itself. Never remove profile or logs.
  # Operators can supply the shared machine cleanup lock on managed runners.
  if [[ -n "${DIFYSF_CLEANUP_LOCK:-}" ]]; then
    flock "$DIFYSF_CLEANUP_LOCK" rmdir "$runtime" 2>/dev/null || true
  else
    rmdir "$runtime" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
weston --backend=headless --renderer=pixman --no-config --idle-time=0 --socket="$WAYLAND_DISPLAY" &
compositor_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
  [[ -S "$runtime/$WAYLAND_DISPLAY" ]] && break
  kill -0 "$compositor_pid" 2>/dev/null || { echo 'Weston failed to start' >&2; exit 1; }
  sleep 0.1
done
[[ -S "$runtime/$WAYLAND_DISPLAY" ]] || { echo 'Weston socket timed out' >&2; exit 1; }
"$DIFYSF_CLIENT_BINARY" "$@" &
client_pid=$!
wait "$client_pid"
