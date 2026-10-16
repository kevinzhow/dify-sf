#!/usr/bin/env bash
# Runs `collab-bench <args>` with real processes: Postgres and Toxiproxy in containers on a private docker
# network, the harness (server processes, client workers, fault injection) in the dev container, as root so it
# may shape traffic with tc/netem (needs NET_ADMIN, granted to that one container only).
#
#   bench/run.sh chaos --runs 300 --parallel 3
#   bench/run.sh storm --mix b --clients 100 --duration 120
#
# Everything binds to the private network or localhost; nothing is published.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"
NET=dify-sf-bench-net
PG=dify-sf-bench-pg
TOXI=dify-sf-bench-toxi
DEV=dify-sf-bench-dev
DEV_IMAGE="${DEV_IMAGE:-dify-sf-dev:local}"
PG_IMAGE="${PG_IMAGE:-postgres:15-alpine}"
TOXI_IMAGE="${TOXI_IMAGE:-ghcr.io/shopify/toxiproxy:2.12.0}"
uid="$(id -u)"; gid="$(id -g)"

cleanup() {
  [ "${KEEP:-0}" = 1 ] || docker rm -f "$PG" "$TOXI" "$DEV" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
docker rm -f "$PG" "$TOXI" "$DEV" >/dev/null 2>&1 || true

docker run -d --name "$PG" --network "$NET" \
  -e POSTGRES_USER=collab -e POSTGRES_PASSWORD=collab -e POSTGRES_DB=collab \
  "$PG_IMAGE" -c max_connections=400 >/dev/null
docker run -d --name "$TOXI" --network "$NET" "$TOXI_IMAGE" -host 0.0.0.0 >/dev/null

# Build as the invoking user (so .build stays user-owned), then run as root.
docker run --rm --user "$uid:$gid" -e HOME=/tmp -v "$repo/server":/work -w /work "$DEV_IMAGE" \
  swift build -c release 2>&1 | grep -E "error|Build" | tail -5

for _ in $(seq 1 60); do
  docker exec "$PG" pg_isready -U collab -d collab >/dev/null 2>&1 && break
  sleep 1
done

docker run --rm --name "$DEV" --network "$NET" --cap-add NET_ADMIN --user root \
  -e HOME=/tmp \
  -e HARNESS_DB_HOST="$PG" -e HARNESS_DB_PORT=5432 -e HARNESS_DB_USER=collab -e HARNESS_DB_PASSWORD=collab -e HARNESS_DB_NAME=collab \
  -e HARNESS_TOXIPROXY_API="http://$TOXI:8474" -e HARNESS_TOXIPROXY_HOST="$TOXI" -e HARNESS_SELF_HOST="$DEV" \
  -e HARNESS_BIN_DIR=.build/release -e HARNESS_SERVER_DEFECT="${HARNESS_SERVER_DEFECT:-}" \
  -v "$repo/server":/work -v "$repo/bench":/repo/bench -w /work "$DEV_IMAGE" \
  sh -c 'ulimit -n 65536 2>/dev/null; .build/release/collab-bench "$@"; rc=$?; chown -R '"$uid:$gid"' /repo/bench 2>/dev/null; exit $rc' sh "$@"
