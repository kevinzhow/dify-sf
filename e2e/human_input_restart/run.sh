#!/usr/bin/env bash
# A human-input resume across a real process restart: two server **processes** (two containers, one database), with a
# kill -9 between them. The first process pauses a run, takes the answer, and dies before it can claim it; the second
# process starts on the same database, finds the answered pause on startup and finishes the run.
#
# This is the process-level counterpart of `HumanInputRealRestartTests` (two `Routes` in one process): it proves nothing
# in the resume depends on memory that a restart loses.
#
#   e2e/human_input_restart/run.sh            # needs docker and dify-sf-dev:local (server/run-swift.sh builds it)
#
# A second scenario (`scenario2.sh`, run at the end) covers the restart that loses nothing: a paused run, the first
# process stopped with SIGTERM, a **new** process on the same database, and the answer arriving over HTTP afterwards.
# It counts the run's side effects (a local HTTP counter service and the node executions) and requires exactly one each.
#
# Env: HITL_IMAGE (default dify-sf-dev:local), HITL_PORT (default 18090), HITL_DB_PORT (default 55440),
#      HITL_BUILD_CACHE (default server/.build), HITL_BUILD_MODE (default release), HITL_TAG (unique by default),
#      HITL_PORT2 (default 18091, scenario 2), HITL_OUT (default e2e/.out/human_input_restart: logs and the raw SSE).
set -euo pipefail
cd "$(dirname "$0")/../.."

IMAGE="${HITL_IMAGE:-dify-sf-dev:local}"
PORT="${HITL_PORT:-18090}"
HITL_RUN_TAG=${HITL_TAG:-dify-hitl-$(id -u)-$$}
export HITL_RUN_TAG
BUILD_CACHE=${HITL_BUILD_CACHE:-$PWD/server/.build}
BUILD_MODE=${HITL_BUILD_MODE:-release}
export HITL_BUILD_CACHE="$BUILD_CACHE" HITL_BUILD_MODE="$BUILD_MODE"
OUT=${HITL_OUT:-$PWD/e2e/.out/human_input_restart/$HITL_RUN_TAG}   # small logs and the raw SSE; keep them off /tmp on a small box
# Names and labels are unique to this invocation; cleanup never removes another invocation's containers.
NET=$HITL_RUN_TAG-net
PG=$HITL_RUN_TAG-pg
A=$HITL_RUN_TAG-a
B=$HITL_RUN_TAG-b
BASE="http://127.0.0.1:$PORT"

cleanup() {
  for name in "$A" "$B" "$PG"; do
    if [ "$(docker inspect --format '{{index .Config.Labels "dify-sf.hitl"}}' "$name" 2>/dev/null || true)" = "$HITL_RUN_TAG" ]; then
      docker rm -f "$name" >/dev/null 2>&1 || true
    fi
  done
  if [ "$(docker network inspect --format '{{index .Labels "dify-sf.hitl"}}' "$NET" 2>/dev/null || true)" = "$HITL_RUN_TAG" ]; then
    docker network rm "$NET" >/dev/null 2>&1 || true
  fi
}
mkdir -p "$OUT"
chmod 700 "$OUT"
trap cleanup EXIT
cleanup
if docker network inspect "$NET" >/dev/null 2>&1; then
  [ "$(docker network inspect --format '{{index .Labels "dify-sf.hitl"}}' "$NET")" = "$HITL_RUN_TAG" ] || { echo "refusing an existing foreign network" >&2; exit 2; }
else
  docker network create --label dify-sf.hitl="$HITL_RUN_TAG" "$NET" >/dev/null
fi

echo "== database"
docker run -d --name "$PG" --label dify-sf.hitl="$HITL_RUN_TAG" --network "$NET" --memory 512m --cpus .5 -e POSTGRES_USER=collab -e POSTGRES_PASSWORD=collab -e POSTGRES_DB=collab \
  postgres:15-alpine >/dev/null
for _ in $(seq 1 60); do docker exec "$PG" pg_isready -U collab -d collab >/dev/null 2>&1 && break; sleep 1; done

server() { # server <name> <extra env...>
  local name=$1; shift
  docker run -d --name "$name" --label dify-sf.hitl="$HITL_RUN_TAG" --network "$NET" --memory 1g --cpus 1 --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -e COLLAB_DB_HOST="$PG" -e COLLAB_DB_USER=collab -e COLLAB_DB_PASSWORD=collab -e COLLAB_DB_NAME=collab \
    -e COLLAB_HTTP_HOST=0.0.0.0 -e COLLAB_HTTP_PORT=8080 -e COLLAB_HUMAN_INPUT_WEB_ENABLED=true -e COLLAB_FILES_DIRECTORY=/tmp/uploads -e COLLAB_LOG_LEVEL=info \
    "$@" -p "127.0.0.1:$PORT:8080" -v "$PWD/server":/work:ro -v "$BUILD_CACHE":/work/.build:ro -w /work "$IMAGE" ".build/$BUILD_MODE/collab-server" >/dev/null
  for _ in $(seq 1 60); do curl -sf "$BASE/v1/system-features" >/dev/null 2>&1 && return 0; sleep 1; done
  echo "server $name did not start" >&2; docker logs "$name" | tail -20 >&2; exit 1
}

echo "== first process: run to the pause, answer it, die before it is claimed"
# `slowClaim` holds the resume 1.5 s before its claim, so the kill lands in the crash window deterministically.
server "$A" -e COLLAB_TEST_DEFECT=slowClaim

TOKEN=$(curl -s -X POST "$BASE/v1/setup" -H 'Content-Type: application/json' \
  -d '{"email":"hitl-restart@example.test","name":"HITL Restart","password":"hitl-restart-1"}' |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')

APP=$(curl -s -X POST "$BASE/v1/docs/import" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data-binary @- <<'YAML' | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
app:
  mode: workflow
  name: hitl-restart
kind: app
version: 0.3.1
workflow:
  conversation_variables: []
  environment_variables: []
  features: {}
  graph:
    edges:
    - {id: e1, source: start, sourceHandle: source, target: human, targetHandle: target}
    - {id: e2, source: human, sourceHandle: approve, target: end, targetHandle: target}
    nodes:
    - id: start
      data: {title: Start, type: start, variables: []}
    - id: human
      data:
        title: Approve
        type: human-input
        form_content: 'Approve {{#$output.reply#}}?'
        inputs: [{type: paragraph, output_variable_name: reply}]
        user_actions: [{id: approve, title: Approve it, button_style: primary}]
    - id: end
      data:
        title: End
        type: end
        outputs: [{variable: reply, value_selector: [human, reply]}]
YAML
)
echo "app=$APP"

curl -sN -X POST "$BASE/v1/apps/$APP/workflows/draft/run" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"inputs":{}}' > "$OUT/run.sse"
FORM=$(E2E_SSE="$OUT/run.sse" python3 - <<'PY'
import json, os
frames = [l[6:] for l in open(os.environ["E2E_SSE"]).read().split('\n\n') if l.startswith('data: ')]
for f in frames:
    e = json.loads(f)
    if e.get('event') == 'human_input_required':
        print(e['data']['form_token'], e['workflow_run_id']); break
PY
)
FORM_TOKEN=${FORM% *}; RUN_ID=${FORM#* }
echo "run=$RUN_ID form=$FORM_TOKEN"

curl -s -X POST "$BASE/v1/form/human_input/$FORM_TOKEN" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"inputs":{"reply":"yes"},"action":"approve"}' >/dev/null
echo "answered; killing the first process before its claim"
sleep 0.2
docker kill "$A" >/dev/null

STATE=$(docker exec "$PG" psql -U collab -d collab -tAc \
  "select r.status || '|' || f.status || '|' || coalesce(f.consumed_at::text,'null') from workflow_runs r join human_input_forms f on f.workflow_run_id = r.id where r.id = '$RUN_ID'")
echo "after the crash: $STATE"
[ "$STATE" = "paused|submitted|null" ] || { echo "expected an answered pause no one claimed, got $STATE" >&2; exit 1; }

echo "== second process: startup picks the answered pause up"
server "$B"
for _ in $(seq 1 100); do
  STATUS=$(docker exec "$PG" psql -U collab -d collab -tAc "select status from workflow_runs where id = '$RUN_ID'")
  [ "$STATUS" = "succeeded" ] || [ "$STATUS" = "failed" ] && break
  sleep 0.2
done
echo "after the restart: $STATUS"
[ "$STATUS" = "succeeded" ] || { echo "the second process did not finish the run ($STATUS)" >&2; docker logs "$B" | tail -30 >&2; exit 1; }

OUTPUT=$(curl -s "$BASE/v1/apps/$APP/workflow-runs/$RUN_ID" -H "Authorization: Bearer $TOKEN" |
  python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["outputs"], sort_keys=True))')
echo "outputs: $OUTPUT"
[ "$OUTPUT" = '{"reply": "yes"}' ] || { echo "wrong outputs: $OUTPUT" >&2; exit 1; }

echo "OK: a killed process left an answered pause, and a new process finished it"

# Scenario 2 lives in its own file (a readable second half) and shares this script's image and output directory.
HITL_IMAGE="$IMAGE" HITL_OUT="$OUT" bash "$(dirname "$0")/scenario2.sh"
