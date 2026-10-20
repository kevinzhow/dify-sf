#!/usr/bin/env bash


echo
echo "== scenario 2: a restart that loses nothing — answered over HTTP by the new process, each side effect once"
# A second server pair on its own port and database: the run pauses in A2, A2 is ended with SIGTERM (what `docker stop`
# sends), B2 starts on the same database, and the answer arrives over HTTP *after* B2 is up. An HTTP node calls a local
# counter service once; the node executions are counted in the database. Each must be exactly one at the end.
PORT2=${HITL_PORT2:-18091}
IMAGE="${HITL_IMAGE:-dify-sf-dev:local}"
OUT="${HITL_OUT:-$PWD/e2e/.out/human_input_restart}"
E2E_OUT2="$OUT/scenario2"; mkdir -p "$E2E_OUT2"; chmod 777 "$E2E_OUT2"
NET2=hitl-restart-net2; PG2=hitl-restart-pg2; A2=hitl-restart-a2; B2=hitl-restart-b2; ECHO2=hitl-restart-echo
BASE2="http://127.0.0.1:$PORT2"
cleanup2() { docker rm -f "$A2" "$B2" "$PG2" "$ECHO2" >/dev/null 2>&1 || true; }
trap cleanup2 EXIT
cleanup2
docker network inspect "$NET2" >/dev/null 2>&1 || docker network create "$NET2" >/dev/null
docker run -d --name "$PG2" --network "$NET2" -e POSTGRES_USER=collab -e POSTGRES_PASSWORD=collab -e POSTGRES_DB=collab postgres:15-alpine >/dev/null
for _ in $(seq 1 60); do docker exec "$PG2" pg_isready -U collab -d collab >/dev/null 2>&1 && break; sleep 1; done

# The local effect counter: a tiny HTTP service whose calls are counted in a file this script reads.
rm -f "$E2E_OUT2/echo.count"
docker run -d --name "$ECHO2" --network "$NET2" --memory 96m -e PYTHONUNBUFFERED=1 -v "$E2E_OUT2":/out \
  python:3.12-alpine python -c '
import http.server, json, pathlib
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        p = pathlib.Path("/out/echo.count"); n = (int(p.read_text()) if p.exists() else 0) + 1; p.write_text(str(n))
        body = json.dumps({"n": n, "message": n}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("0.0.0.0", 8000), H).serve_forever()
' >/dev/null

start2() { # start2 <name> <extra env...>
  local name=$1; shift
  docker run -d --name "$name" --network "$NET2" --memory 3g -e HOME=/tmp \
    -e COLLAB_DB_HOST="$PG2" -e COLLAB_DB_USER=collab -e COLLAB_DB_PASSWORD=collab -e COLLAB_DB_NAME=collab \
    -e COLLAB_HTTP_HOST=0.0.0.0 -e COLLAB_HTTP_PORT=8080 -e COLLAB_PLUGIN_DAEMON_URL=http://127.0.0.1:1 -e COLLAB_LOG_LEVEL=info \
    "$@" -p "127.0.0.1:$PORT2:8080" -v "$PWD/server":/work -w /work "$IMAGE" .build/debug/collab-server >/dev/null
  for _ in $(seq 1 90); do curl -sf "$BASE2/v1/system-features" >/dev/null 2>&1 && return 0; sleep 1; done
  echo "server $name did not start" >&2; docker logs "$name" | tail -20 >&2; exit 1
}

echo "-- first process (A2): the run pauses"
start2 "$A2"
TOKEN2=$(curl -s -X POST "$BASE2/v1/setup" -H 'Content-Type: application/json' \
  -d '{"email":"hitl-restart2@example.test","name":"HITL Restart 2","password":"hitl-restart-2"}' |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
APP2=$(curl -s -X POST "$BASE2/v1/docs/import" -H "Authorization: Bearer $TOKEN2" -H 'Content-Type: application/json' \
  --data-binary @- <<'YAML' | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
app:
  mode: workflow
  name: hitl-restart-effects
kind: app
version: 0.3.1
workflow:
  conversation_variables: []
  environment_variables: []
  features: {}
  graph:
    edges:
    - {id: e1, source: start, sourceHandle: source, target: http, targetHandle: target}
    - {id: e2, source: http, sourceHandle: source, target: human, targetHandle: target}
    - {id: e3, source: human, sourceHandle: approve, target: end, targetHandle: target}
    nodes:
    - id: start
      data: {title: Start, type: start, variables: []}
    - id: http
      data:
        title: Call
        type: http-request
        method: get
        url: http://hitl-restart-echo:8000/report
        authorization: {type: no-auth, config: null}
        headers: ''
        params: ''
        body: {type: json, data: [{type: text, key: '', value: '{}'}]}
        timeout: {max_connect_timeout: 0, max_read_timeout: 0, max_write_timeout: 0}
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
        outputs:
        - {variable: reply, value_selector: [human, reply]}
        - {variable: message, value_selector: [http, body]}
YAML
)
curl -sN -X POST "$BASE2/v1/apps/$APP2/workflows/draft/run" -H "Authorization: Bearer $TOKEN2" \
  -H 'Content-Type: application/json' -d '{"inputs":{}}' > "$E2E_OUT2/run.sse"
read -r FORM2 RUN2 <<<"$(E2E_SSE="$E2E_OUT2/run.sse" python3 - <<'PY'
import json, os
for raw in open(os.environ["E2E_SSE"]).read().split("\n\n"):
    if raw.startswith("data: "):
        e = json.loads(raw[6:])
        if e.get("event") == "human_input_required":
            print(e["data"]["form_token"], e["workflow_run_id"]); break
PY
)"
echo "run=$RUN2 form=$FORM2"

echo "-- ending A2 (SIGTERM) and starting a new process (B2) on the same database"
docker stop --time 20 "$A2" >/dev/null
docker rm -f "$A2" >/dev/null
start2 "$B2"
STATE_BEFORE=$(docker exec "$PG2" psql -U collab -d collab -tAc "select status from workflow_runs where id = '$RUN2'")
echo "after the restart, before the answer: $STATE_BEFORE"
[ "$STATE_BEFORE" = "paused" ] || { echo "B2 changed the paused run at startup ($STATE_BEFORE)" >&2; exit 1; }

echo "-- the answer arrives over HTTP, to B2"
curl -s -X POST "$BASE2/v1/form/human_input/$FORM2" -H "Authorization: Bearer $TOKEN2" \
  -H 'Content-Type: application/json' -d '{"inputs":{"reply":"yes"},"action":"approve"}' >/dev/null
STATUS2=""
for _ in $(seq 1 200); do
  STATUS2=$(docker exec "$PG2" psql -U collab -d collab -tAc "select status from workflow_runs where id = '$RUN2'")
  { [ "$STATUS2" = "succeeded" ] || [ "$STATUS2" = "failed" ]; } && break
  sleep 0.2
done
echo "after the answer: $STATUS2"
[ "$STATUS2" = "succeeded" ] || { echo "B2 did not finish the run ($STATUS2)" >&2; docker logs "$B2" | tail -30 >&2; exit 1; }

OUTPUT2=$(curl -s "$BASE2/v1/apps/$APP2/workflow-runs/$RUN2" -H "Authorization: Bearer $TOKEN2" |
  python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["outputs"], sort_keys=True))')
ECHO_CALLS=$(cat "$E2E_OUT2/echo.count")
HTTP_CALLS=$(docker exec "$PG2" psql -U collab -d collab -tAc "select count(*) from workflow_node_executions where workflow_run_id = '$RUN2' and node_id = 'http'")
HUMAN_CALLS=$(docker exec "$PG2" psql -U collab -d collab -tAc "select count(*) from workflow_node_executions where workflow_run_id = '$RUN2' and node_id = 'human'")
echo "outputs: $OUTPUT2"
echo "calls: counter service $ECHO_CALLS, http node executions $HTTP_CALLS, human node executions $HUMAN_CALLS"
[ "$ECHO_CALLS" = "1" ] || { echo "the HTTP node ran $ECHO_CALLS times" >&2; exit 1; }
[ "$HTTP_CALLS" = "1" ] && [ "$HUMAN_CALLS" = "1" ] || { echo "a node ran more than once across the restart" >&2; exit 1; }
OUTPUT2="$OUTPUT2" python3 - <<'PY'
import json, os
o = json.loads(os.environ["OUTPUT2"])
assert o.get("reply") == "yes", o
assert o.get("message") and json.loads(o["message"])["n"] == 1, o
PY
echo "OK: a paused run survived a real restart, was answered over HTTP, finished, and each side effect ran once"
