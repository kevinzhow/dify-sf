#!/usr/bin/env bash
# Start/stop the differential-test stacks. Nothing here stays resident: every session ends with `down`.
#
#   e2e/stack.sh ref-up | ref-down          stack R: Dify 1.17.1 (api, worker, plugin daemon, sandbox, ssrf proxy,
#                                           Postgres, Redis) from $DIFY_DOCKER_DIR + e2e/difyref.override.yaml
#   e2e/stack.sh ours-up | ours-down        stack P: dify-sf (docker-compose.yml, profile runtime) as project difysf-p
#   e2e/stack.sh stub-up | stub-down        llmstub (deterministic OpenAI-compatible stub) on network difysf_e2e
#   e2e/stack.sh mem <label>                memory of every running e2e container now and its peak (cgroup memory.peak)
#   e2e/stack.sh down                       everything above + the shared network
#   e2e/stack.sh status
#
# Environment: DIFY_DOCKER_DIR (Dify 1.17.1's docker/ directory, for ref-*), DIFYREF_API_PORT (15001),
# DIFYREF_DAEMON_PORT (15002), LLMSTUB_PORT (18000), DIFYSF_P_PORT (18080), DIFYSF_P_DAEMON_PORT (15102),
# DIFYSF_P_PG_PORT (55433), E2E_OUT (e2e/.out: logs and measurements).
# Containers are outside the caller's cgroup; every service carries its own memory cap. On a shared machine run whole
# sessions (up ... tests ... down) inside the heavy-job wrapper so that stacks never overlap.
set -euo pipefail
E2E=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$E2E/.." && pwd)
OUT=${E2E_OUT:-$E2E/.out}
mkdir -p "$OUT"
NET=difysf_e2e
export DIFYREF_API_PORT=${DIFYREF_API_PORT:-15001} DIFYREF_DAEMON_PORT=${DIFYREF_DAEMON_PORT:-15002}
export LLMSTUB_PORT=${LLMSTUB_PORT:-18000}

ref() {
  : "${DIFY_DOCKER_DIR:?set DIFY_DOCKER_DIR to the docker directory of Dify 1.17.1}"
  docker compose -p difyref --project-directory "$DIFY_DOCKER_DIR" -f "$DIFY_DOCKER_DIR/docker-compose.yaml" \
    -f "$E2E/difyref.override.yaml" "$@"
}
ours() {
  COLLAB_PORT=${DIFYSF_P_PORT:-18080} COLLAB_PG_PORT=${DIFYSF_P_PG_PORT:-55433} \
  COLLAB_PLUGIN_DAEMON_PORT=${DIFYSF_P_DAEMON_PORT:-15102} \
    docker compose -p difysf-p --project-directory "$REPO" -f "$REPO/docker-compose.yml" \
    -f "$E2E/runtime-e2e.override.yaml" --profile runtime "$@"
}
stub() { docker compose -p difysf-llmstub -f "$E2E/llmstub/compose.yaml" "$@"; }

net_up() { docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null; }
net_down() { docker network rm "$NET" >/dev/null 2>&1 || true; }

wait_http() {  # url seconds
  local url=$1 n=${2:-180}
  for _ in $(seq 1 "$n"); do
    curl -fsS -m 3 -o /dev/null "$url" 2>/dev/null && return 0
    sleep 1
  done
  echo "timeout waiting for $url" >&2
  return 1
}

wait_healthy() {  # container seconds
  local c=$1 n=${2:-120} s
  for _ in $(seq 1 "$n"); do
    s=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null || echo missing)
    [ "$s" = healthy ] && return 0
    sleep 1
  done
  echo "timeout waiting for $c to be healthy (last: $s)" >&2
  return 1
}

mem() {
  local label=${1:-now} ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local ids
  ids=$(docker ps -q --filter label=com.docker.compose.project=difyref --filter status=running;
        docker ps -q --filter label=com.docker.compose.project=difysf-p --filter status=running;
        docker ps -q --filter label=com.docker.compose.project=difysf-llmstub --filter status=running)
  [ -n "$ids" ] || { echo "no e2e containers running"; return 0; }
  printf '%-34s %10s %10s %10s %10s\n' container "anon MiB" "now MiB" "peak MiB" "cap MiB"
  local total_now=0 total_peak=0 total_anon=0 id name full cg now peak cap anon
  for id in $ids; do
    name=$(docker inspect -f '{{.Name}}' "$id" | sed 's,^/,,')
    full=$(docker inspect -f '{{.Id}}' "$id")
    cg=$(ls -d /sys/fs/cgroup/system.slice/docker-"$full".scope 2>/dev/null || true)
    now=$(cat "$cg/memory.current" 2>/dev/null || echo 0)
    peak=$(cat "$cg/memory.peak" 2>/dev/null || echo 0)
    anon=$(awk '$1=="anon"{print $2}' "$cg/memory.stat" 2>/dev/null || echo 0)
    cap=$(docker inspect -f '{{.HostConfig.Memory}}' "$id")
    now=$((now / 1048576)); peak=$((peak / 1048576)); cap=$((cap / 1048576)); anon=$((${anon:-0} / 1048576))
    total_now=$((total_now + now)); total_peak=$((total_peak + peak)); total_anon=$((total_anon + anon))
    printf '%-34s %10s %10s %10s %10s\n' "$name" "$anon" "$now" "$peak" "$cap"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$label" "$name" "$anon" "$now" "$peak" "$cap" >> "$OUT/mem.tsv"
  done
  printf '%-34s %10s %10s %10s\n' TOTAL "$total_anon" "$total_now" "$total_peak"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t-\n' "$ts" "$label" TOTAL "$total_anon" "$total_now" "$total_peak" >> "$OUT/mem.tsv"
  echo "(cgroup of each container: anon = process memory, now/peak = memory.current/memory.peak incl. page cache; host MemAvailable $(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo) MiB)"
}

cmd=${1:-status}; shift || true
case "$cmd" in
  stub-up)   net_up; stub up -d; wait_http "http://127.0.0.1:$LLMSTUB_PORT/health" 60 ;;
  stub-down) stub down --remove-orphans ;;
  ref-up)
    net_up
    # Order by hand: --no-deps keeps agent_backend (and its sandbox/proxy) out; api/worker wait for Postgres.
    ref up -d --no-deps db_postgres redis init_permissions ssrf_proxy sandbox
    wait_healthy difyref-db_postgres-1 120
    ref up -d --no-deps plugin_daemon api worker
    wait_http "http://127.0.0.1:$DIFYREF_API_PORT/health" 300
    ;;
  ref-down)  ref down --remove-orphans ;;
  ref-logs)  ref logs --no-color "$@" ;;
  ours-up)
    net_up
    ours up -d --no-build
    wait_http "http://127.0.0.1:${DIFYSF_P_PORT:-18080}/v1/system-features" 120 || wait_http "http://127.0.0.1:${DIFYSF_P_PORT:-18080}/" 30
    ;;
  ours-down) ours down --remove-orphans ;;
  ours-logs) ours logs --no-color "$@" ;;
  mem)       mem "${1:-now}" ;;
  down)
    if [ -n "${DIFY_DOCKER_DIR:-}" ]; then ref down --remove-orphans || true
    else  # without Dify's compose files: stop and remove the project's containers by label
      ids=$(docker ps -aq --filter label=com.docker.compose.project=difyref)
      [ -z "$ids" ] || docker rm -f $ids >/dev/null
    fi
    ours down --remove-orphans || true
    stub down --remove-orphans || true
    net_down
    ;;
  status)    docker ps --filter network=$NET --format '{{.Names}}\t{{.Status}}' ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
