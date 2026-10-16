#!/usr/bin/env bash
# Runs the Postgres integration tests (and everything else) against a throw-away Postgres container.
set -euo pipefail
cd "$(dirname "$0")"
NET=dify-sf-test-net; PG=dify-sf-test-pg
cleanup() { docker rm -f "$PG" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
docker rm -f "$PG" >/dev/null 2>&1 || true
docker run -d --name "$PG" --network "$NET" -e POSTGRES_USER=collab -e POSTGRES_PASSWORD=collab -e POSTGRES_DB=collab postgres:15-alpine >/dev/null
for _ in $(seq 1 60); do docker exec "$PG" pg_isready -U collab -d collab >/dev/null 2>&1 && break; sleep 1; done
docker run --rm --network "$NET" --user "$(id -u):$(id -g)" -e HOME=/tmp -e TEST_DB_HOST="$PG" \
  -v "$PWD":/work -w /work "${DEV_IMAGE:-dify-sf-dev:local}" swift test -c release -Xswiftc -enable-testing "$@"
