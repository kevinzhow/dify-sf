#!/usr/bin/env bash
# The runtime against a real plugin daemon (protocol 1.13): Dify's plugin daemon 0.6.10 with the pinned
# openai_api_compatible plugin (docker-compose.yml, profile `runtime`, project difysf-p) and the deterministic stub LLM
# (e2e/llmstub), all on the e2e network. Runs
#   1. the Swift integration test (RuntimeDaemonIntegrationTests: the routes in-process, the real daemon and stub), and
#   2. the server binary over HTTP: an LLM node's single run through `POST /v1/apps/{app}/workflows/draft/nodes/llm/run`,
#   3. the Dart client's HttpWorkflowRunApi against that server (when the client repository is next to this one).
# Everything it starts is stopped at the end (volumes stay: the installed plugin is reused next time).
# Containers escape the caller's cgroup; each one has a memory cap. On a shared machine run it inside the heavy-job
# wrapper so that it never overlaps another stack.
set -euo pipefail
cd "$(dirname "$0")"
SERVER=$PWD
REPO=$(cd .. && pwd)
NET=difysf_e2e
PG=dify-sf-rt-e2e-pg
SRV=dify-sf-rt-e2e-server
TENANT=${E2E_TENANT:-00000000-0000-0000-0000-000000000001}
DAEMON_KEY=${COLLAB_PLUGIN_DAEMON_KEY:-dify-sf-local-plugin-daemon-key}
DAEMON_PORT=${DIFYSF_P_DAEMON_PORT:-15102}
DAEMON_CONTAINER=difysf-p-plugin_daemon-1
ours() {
  COLLAB_PG_PORT=${DIFYSF_P_PG_PORT:-55433} COLLAB_PLUGIN_DAEMON_PORT=$DAEMON_PORT \
    docker compose -p difysf-p --project-directory "$REPO" -f "$REPO/docker-compose.yml" -f "$REPO/e2e/runtime-e2e.override.yaml" \
    --profile runtime "$@"
}
cleanup() {
  docker rm -f "$PG" "$SRV" >/dev/null 2>&1 || true
  ours stop plugin_daemon redis postgres >/dev/null 2>&1 || true
  ours rm -f plugin_daemon redis postgres >/dev/null 2>&1 || true
  "$REPO/e2e/stack.sh" stub-down >/dev/null 2>&1 || true
  if [ -z "$(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$NET" 2>/dev/null)" ]; then
    docker network rm "$NET" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

"$REPO/e2e/stack.sh" stub-up
ours up -d --no-build postgres redis plugin_daemon
for _ in $(seq 1 180); do curl -fsS -m 3 -o /dev/null "http://127.0.0.1:$DAEMON_PORT/health/check" 2>/dev/null && break; sleep 1; done
# Installs the pinned plugin for our tenant (idempotent; the first time downloads its Python dependencies) and checks a
# direct invocation of the stub through the daemon.
# After a start the daemon needs a while to launch installed plugins ("no available node, plugin runtime not found").
for i in $(seq 1 30); do
  E2E_TENANT=$TENANT DIFYSF_DAEMON_URL="http://127.0.0.1:$DAEMON_PORT" DIFYSF_DAEMON_KEY=$DAEMON_KEY \
    python3 -I "$REPO/e2e/setup_ours.py" > /tmp/dify-sf-rt-e2e-setup.log 2>&1 && break
  [ "$i" = 30 ] && { tail -5 /tmp/dify-sf-rt-e2e-setup.log; exit 1; }
  sleep 10
done
tail -1 /tmp/dify-sf-rt-e2e-setup.log

docker run -d --name "$PG" --memory 1g --cpus 1 --network "$NET" -e POSTGRES_USER=collab -e POSTGRES_PASSWORD=collab \
  -e POSTGRES_DB=collab postgres:15-alpine >/dev/null
for _ in $(seq 1 60); do docker exec "$PG" pg_isready -U collab -d collab >/dev/null 2>&1 && break; sleep 1; done

COMMON=(--memory "${DEV_MEM:-4g}" --cpus "${DEV_CPUS:-3}" --network "$NET" --user "$(id -u):$(id -g)" -e HOME=/tmp
        -v "$SERVER":/work -w /work)
# 1. The integration test (its own schema in the test database).
docker run --rm "${COMMON[@]}" -e TEST_DB_HOST="$PG" -e TEST_PLUGIN_DAEMON_URL="http://$DAEMON_CONTAINER:5002" \
  -e TEST_PLUGIN_DAEMON_KEY="$DAEMON_KEY" -e TEST_PLUGIN_DAEMON_TENANT="$TENANT" -e TEST_LLMSTUB_ENDPOINT=http://llmstub:8000/v1 \
  "${DEV_IMAGE:-dify-sf-dev:local}" swift test -c release -Xswiftc -enable-testing --filter RuntimeDaemonIntegrationTests

# 2. The server binary over HTTP, configured through its environment like a deployment.
docker run --rm "${COMMON[@]}" "${DEV_IMAGE:-dify-sf-dev:local}" swift build -c release -Xswiftc -enable-testing --product collab-server
docker run -d --name "$SRV" --memory 1g --cpus 1 --network "$NET" -p "127.0.0.1:${RT_E2E_PORT:-18090}:8080" --user "$(id -u):$(id -g)" -v "$SERVER":/work -w /work \
  -e COLLAB_HTTP_HOST=0.0.0.0 -e COLLAB_DB_HOST="$PG" -e COLLAB_SECRETS_KEY=ZGlmeS1zZi1sb2NhbC1kZXZlbG9wbWVudC1rZXktMDE= \
  -e COLLAB_MODELS_VALIDATE=false -e COLLAB_PLUGIN_DAEMON_URL="http://$DAEMON_CONTAINER:5002" -e COLLAB_PLUGIN_DAEMON_KEY="$DAEMON_KEY" \
  -e COLLAB_PLUGIN_DAEMON_TENANT="$TENANT" "${DEV_IMAGE:-dify-sf-dev:local}" .build/release/collab-server >/dev/null
# The client: python3 from the plugin daemon's image (already pulled), standard library only.
docker run --rm --network "$NET" --memory 256m -v "$REPO/tool/runtime_e2e_http.py":/t.py:ro --entrypoint python3 \
  langgenius/dify-plugin-daemon:0.6.10-local -I /t.py "http://$SRV:8080"
# 3. The Dart client's HttpWorkflowRunApi against the same server (the client repository next to this one, when present).
CLIENT=${DIFYSF_CLIENT_DIR:-$REPO/../dify-sf-client}
if [ -d "$CLIENT/packages/collab_client" ] && command -v dart >/dev/null; then
  (cd "$CLIENT/packages/collab_client" && DIFYSF_RUNTIME_URL="http://127.0.0.1:${RT_E2E_PORT:-18090}" dart test test/runtime_e2e_test.dart)
else
  echo "runtime e2e: no client checkout or dart: skipping the Dart client test"
fi
echo "runtime e2e: OK"
