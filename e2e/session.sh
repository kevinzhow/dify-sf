#!/usr/bin/env bash
# One differential-test session from start to stop; the stacks are always taken down at the end (also on failure).
#
#   e2e/session.sh [ref] [ours] [compare] [self] [difysf] [perf] [conformance]
#     ref         stack R (Dify 1.17.1) + llmstub; setup_ref.py (account, plugin, stub model, probe run)
#     ours        stack P (dify-sf, profile runtime); setup_ours.py (plugin into dify-sf's daemon, invoke via daemon;
#                 with ref also through Dify's daemon)
#     compare     e2e/compare.py over the live cases (needs ref); `self` adds Dify-vs-Dify, `difysf` adds Dify-vs-dify-sf
#                 (needs ours)
#     perf        a 20-node draft run on stack P, timed, with the server's memory (needs ours; e2e/perf_draft_run.py)
#     conformance the client conformance test against stack P's server (needs ours and DIFYSF_CLIENT_DIR, a checkout of
#                 dify-sf-client; dart on PATH)
# Memory of every container is measured after each phase (e2e/.out/mem.tsv). Needs DIFY_DOCKER_DIR for ref. On a
# shared machine run the whole script inside the heavy-job wrapper.
set -uo pipefail
E2E=$(cd "$(dirname "$0")" && pwd)
OUT=${E2E_OUT:-$E2E/.out}
mkdir -p "$OUT"
want() { for a in "${ARGS[@]}"; do [ "$a" = "$1" ] && return 0; done; return 1; }
ARGS=("$@")
STACK="$E2E/stack.sh"
PY="python3 -I"
status=0
step() { echo; echo "== $* ($(date -u +%H:%M:%SZ))"; }
finish() {
  step "memory at the end"; "$STACK" mem end || true
  step "stopping everything"; "$STACK" down || true
  "$STACK" status || true
  exit $status
}
trap finish EXIT
trap 'status=130; exit' INT TERM

step "llmstub"; "$STACK" stub-up || { status=1; exit; }
if want ref; then
  step "stack R up"; "$STACK" ref-up || { status=1; "$STACK" ref-logs --tail 80 api plugin_daemon || true; exit; }
  "$STACK" mem ref-idle
  step "setup_ref"; $PY "$E2E/setup_ref.py" || { status=1; "$STACK" ref-logs --tail 120 api worker plugin_daemon || true; exit; }
  "$STACK" mem ref-after-setup
fi
if want ours; then
  step "stack P up"; "$STACK" ours-up || { status=1; "$STACK" ours-logs --tail 80 || true; exit; }
  "$STACK" mem ours-idle
  step "setup_ours"; if want ref; then $PY "$E2E/setup_ours.py" --dify; else $PY "$E2E/setup_ours.py"; fi || status=1
  "$STACK" mem after-setup-ours
fi
if want compare; then
  flags=()
  want self && flags+=(--self)
  want difysf && flags+=(--difysf "http://127.0.0.1:${DIFYSF_P_PORT:-18080}")
  step "compare ${flags[*]}"; $PY "$E2E/compare.py" "${flags[@]}" 2>&1 | tee "$OUT/compare.log"
  [ "${PIPESTATUS[0]}" = 0 ] || status=1
  "$STACK" mem after-compare
fi
if want perf; then
  step "perf: 20-node draft run on stack P"; $PY "$E2E/perf_draft_run.py" 2>&1 | tee "$OUT/perf.log"
  [ "${PIPESTATUS[0]}" = 0 ] || status=1
  "$STACK" mem after-perf
fi
if want conformance; then
  step "client conformance against stack P"
  ( cd "${DIFYSF_CLIENT_DIR:?}/packages/collab_client" && \
    DIFYSF_URL="http://127.0.0.1:${DIFYSF_P_PORT:-18080}" DIFYSF_STUB_HOST=host.docker.internal \
    DIFYSF_EMAIL="${DIFYSF_EMAIL:-e2e-owner@example.test}" DIFYSF_PASSWORD="${DIFYSF_PASSWORD:-E2e-throwaway-1}" \
      dart test test/conformance_test.dart 2>&1 | tail -40 ) || status=1
fi
