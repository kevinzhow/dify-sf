#!/usr/bin/env bash
# Compose smoke test of the Agent v2 profile `agent` (see agent_service/README.md, "Compose smoke test").
#
#   agent_service/tool/compose_smoke.sh SUBNET [SANDBOX_POOL]
#
# SUBNET        a free private /28 (or larger) for the project's `default` network, e.g. 10.212.7.0/28
#               (check `docker network ls -q | xargs docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}'`)
# SANDBOX_POOL  the supervisor's SANDBOX_SUBNET_POOL (default 10.213.0.0/16), split into one /28 per sandbox
#
# Environment: SMOKE_IMAGE (default dify-sf-agent-service:dev, must exist locally), SMOKE_SANDBOX_IMAGE
# (default langgenius/dify-agent-local-sandbox:1.17.1), SMOKE_KEEP_LOGS=DIR (copy the service logs there).
#
# It starts agent_service, sandbox_supervisor and agent_sandbox_proxy from the repository's docker-compose.yml under
# its own project name, plus a scripted fake inner gateway (bin/fake_gateway.dart, built into a throwaway image).
# The scripted model calls shell_run (workspace file, direct egress, the proxy, pip download, a refused domain) and
# then final_output. One operation is driven through agent_service's HTTP API: POST /v1/operations, the event
# stream, the status, ack, DELETE /v1/executions/{id}; the sandbox container and its network must then be gone.
# Everything created carries the label dify-sf.test=<random> and is removed at the end, also on failure. Nothing
# is pulled; images, containers, networks and volumes of others are never touched.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
fi
SUBNET=$1
POOL=${2:-10.213.0.0/16}
IMAGE=${SMOKE_IMAGE:-dify-sf-agent-service:dev}
SANDBOX_IMAGE=${SMOKE_SANDBOX_IMAGE:-langgenius/dify-agent-local-sandbox:1.17.1}

HERE=$(cd "$(dirname "$0")/.." && pwd)        # agent_service/
REPO=$(cd "$HERE/.." && pwd)
ID=$(openssl rand -hex 4)
LABEL_KEY=dify-sf.test
LABEL="$LABEL_KEY=$ID"
PROJECT=dify-sf-smoke-$ID
GATEWAY_IMAGE=dify-sf-smoke-gateway:$ID
SERVICE_KEY=smoke-service-key-$ID
SUPERVISOR_KEY=smoke-supervisor-key-$ID
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dify-sf-smoke-$ID.XXXX")
EXECUTION=SMOKE-$ID

log() { printf '[smoke %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

for image in "$IMAGE" "$SANDBOX_IMAGE" ubuntu/squid:latest dart:3.13 debian:bookworm-slim; do
  docker image inspect "$image" >/dev/null 2>&1 || fail "image $image is not present locally (nothing is pulled)"
done

compose() {
  docker compose -p "$PROJECT" -f "$REPO/docker-compose.yml" -f "$WORK/override.yml" --profile agent "$@"
}

cleanup() {
  local rc=$?
  set +e
  if [[ -n "${SMOKE_KEEP_LOGS:-}" ]]; then
    mkdir -p "$SMOKE_KEEP_LOGS" && compose logs --no-color >"$SMOKE_KEEP_LOGS/compose-$ID.log" 2>&1
  elif [[ $rc -ne 0 && -f "$WORK/override.yml" ]]; then
    compose logs --no-color --tail 80 >&2
  fi
  log "cleanup"
  [[ -f "$WORK/override.yml" ]] && compose down -v --remove-orphans --timeout 5 >/dev/null 2>&1
  # Sandboxes (and their networks) are created by the supervisor, not by compose: remove what carries the label.
  for c in $(docker ps -aq --filter "label=$LABEL"); do docker rm -f -v "$c" >/dev/null; done
  for n in $(docker network ls -q --filter "label=$LABEL"); do
    for c in $(docker network inspect -f '{{range $k, $v := .Containers}}{{$k}} {{end}}' "$n"); do
      docker network disconnect -f "$n" "$c" >/dev/null 2>&1
    done
    docker network rm "$n" >/dev/null
  done
  for v in $(docker volume ls -q --filter "label=$LABEL"); do docker volume rm "$v" >/dev/null; done
  docker image rm "$GATEWAY_IMAGE" >/dev/null 2>&1
  rm -rf "$WORK"
  local left
  left="$(docker ps -aq --filter "label=$LABEL")$(docker network ls -q --filter "label=$LABEL")"
  left+="$(docker volume ls -q --filter "label=$LABEL")$(docker image ls -q --filter "label=$LABEL")"
  log "cleanup check (label $LABEL): containers/networks/volumes/images left: ${left:-none}"
  docker ps -a --filter "label=$LABEL" --format '  container {{.Names}}' >&2
  docker network ls --filter "label=$LABEL" --format '  network {{.Name}}' >&2
  docker volume ls --filter "label=$LABEL" --format '  volume {{.Name}}' >&2
  if [[ -n "$left" ]]; then
    log "FAIL: cleanup left resources"
    rc=1
  fi
  if [[ $rc -eq 0 ]]; then log "PASS"; fi
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---- the fake inner gateway: compiled into a throwaway image ---------------------------------------------------
log "building $GATEWAY_IMAGE"
docker build -q --label "$LABEL" -t "$GATEWAY_IMAGE" -f - "$HERE" >/dev/null <<'EOF'
FROM dart:3.13 AS build
WORKDIR /src
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get --enforce-lockfile
COPY . .
RUN mkdir -p /out && dart pub get --offline --enforce-lockfile \
 && dart compile exe bin/fake_gateway.dart -o /out/fake_gateway
FROM debian:bookworm-slim
COPY --from=build /out/fake_gateway /usr/local/bin/fake_gateway
USER 10001:10001
ENTRYPOINT ["/usr/local/bin/fake_gateway"]
EOF

# ---- the model script: shell_run, then final_output ------------------------------------------------------------
SHELL_SCRIPT=$(cat <<'EOF'
# Output is collected and printed at the end: shellctl returns a running job once its output goes idle.
{
echo "smoke-file-$(id -u)" > note.txt && cat note.txt && ls -l note.txt
if timeout 5 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null; then echo direct=open; else echo direct=blocked; fi
echo "proxy_env=${HTTPS_PROXY:-none}"
curl -sS -o /dev/null -w 'allowlisted=%{http_code}\n' -m 30 https://pypi.org/simple/six/ 2>&1 || echo allowlisted=error
curl -sS -o /dev/null -m 15 https://example.com/ 2>&1 | grep -q 'response 403' && echo refused=403 || echo refused=other
if pip download --no-deps --disable-pip-version-check -q -d dl six==1.16.0 >pip.log 2>&1; then echo pip=ok; ls dl; else echo pip=failed; tail -3 pip.log; fi
} > smoke.out 2>&1; cat smoke.out
EOF
)
python3 -I - "$WORK/script.json" "$SHELL_SCRIPT" <<'EOF'
import json, sys
path, script = sys.argv[1], sys.argv[2]
def call(cid, name, args):
    return {"chunks": [
        {"tool_calls": [{"id": cid, "type": "function",
                         "function": {"name": name, "arguments": json.dumps(args)}}]},
        {"usage": {"prompt_tokens": 10, "completion_tokens": 5}, "finish_reason": "tool_calls"}]}
json.dump({"calls": [call("c1", "shell_run", {"script": script, "timeout": 120}),
                     call("c2", "final_output", {"text": "smoke done"})]}, open(path, "w"))
EOF
python3 -I - "$WORK/operation.json" "$EXECUTION" <<'EOF'
import json, sys
path, execution = sys.argv[1], sys.argv[2]
json.dump({
  "protocol": "dify-sf-agent/1", "operation_id": f"{execution}:0:0", "generation": 1,
  "execution": {"tenant_id": "T1", "app_id": "A1", "workflow_run_id": "W1", "node_id": "N1",
                "execution_id": execution, "agent_config_snapshot_id": "cfg-1", "user_id": "U1",
                "user_from": "account", "invoke_from": "debugger"},
  "model": {"provider": "langgenius/openai_api_compatible/openai_api_compatible", "name": "smoke-model",
            "parameters": {}},
  "system_prompt": "You are a smoke test.", "task": [{"type": "text", "text": "Run the smoke script."}],
  "output_schema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]},
  "tools": {"ask_human": False, "shell": True}, "env": {}, "files": [],
  "limits": {"max_turns": 5, "timeout_seconds": 300}, "continuation": None}, open(path, "w"))
EOF

# ---- the compose override: names, labels, subnets, limits, the fake gateway -----------------------------------
DOCKER_SOCKET=${DOCKER_SOCKET:-/var/run/docker.sock}
DOCKER_GID=$(stat -c %g "$DOCKER_SOCKET")
cat >"$WORK/override.yml" <<EOF
services:
  agent_service:
    image: $IMAGE
    pull_policy: never
    labels: {$LABEL_KEY: "$ID"}
    environment:
      AGENT_SERVICE_KEY: $SERVICE_KEY
      AGENT_SANDBOX_SUPERVISOR_KEY: $SUPERVISOR_KEY
      AGENT_INNER_URL: http://fake_gateway:5051
    ports: ["127.0.0.1::5050"]
  sandbox_supervisor:
    image: $IMAGE
    pull_policy: never
    labels: {$LABEL_KEY: "$ID"}
    group_add: ["$DOCKER_GID"]
    environment:
      SANDBOX_SUPERVISOR_KEY: $SUPERVISOR_KEY
      SANDBOX_IMAGE: $SANDBOX_IMAGE
      SANDBOX_LABEL: $LABEL
      SANDBOX_SUBNET_POOL: $POOL
      SANDBOX_MEMORY_MB: "512"
      SANDBOX_HOME_MB: "64"
      SANDBOX_WORKSPACE_MB: "128"
  agent_sandbox_proxy:
    labels: {$LABEL_KEY: "$ID"}
  fake_gateway:
    profiles: [agent]
    image: $GATEWAY_IMAGE
    pull_policy: never
    labels: {$LABEL_KEY: "$ID"}
    mem_limit: 128m
    memswap_limit: 128m
    environment:
      AGENT_SERVICE_KEY: $SERVICE_KEY
    volumes: ["$WORK/script.json:/script.json:ro"]
    command: ["/script.json", "5051", "0.0.0.0"]
networks:
  default:
    labels: {$LABEL_KEY: "$ID"}
    ipam:
      config: [{subnet: "$SUBNET"}]
volumes:
  agent_service_data: {labels: {$LABEL_KEY: "$ID"}}
  sandbox_supervisor_state: {labels: {$LABEL_KEY: "$ID"}}
EOF
chmod a+r "$WORK/script.json"
chmod a+x "$WORK"

log "starting project $PROJECT (default network $SUBNET, sandbox pool $POOL)"
compose up -d --no-build --pull never --wait --wait-timeout 120 \
  agent_service sandbox_supervisor agent_sandbox_proxy fake_gateway

PORT=$(compose port agent_service 5050 | sed 's/.*://')
BASE=http://127.0.0.1:$PORT
api() { # METHOD PATH [BODY_FILE]
  local args=(-sS -X "$1" -H "Authorization: Bearer $SERVICE_KEY" -H "X-Agent-Run-Token: smoke-$ID"
    -H 'Content-Type: application/json' -w '\n%{http_code}' "$BASE$2")
  [[ $# -ge 3 ]] && args+=(--data-binary "@$3")
  curl "${args[@]}"
}
status_of() { tail -n1 <<<"$1"; }
body_of() { sed '$d' <<<"$1"; }
json() { python3 -I -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

r=$(api GET /v1/health)
log "health: $(body_of "$r")"
[[ $(status_of "$r") == 200 ]] || fail "health answered $(status_of "$r")"
[[ $(body_of "$r" | json 'd["status"], d["sandbox"]') == "ok isolated" ]] || fail "health is not ok/isolated"

r=$(api POST /v1/operations "$WORK/operation.json")
[[ $(status_of "$r") == 202 ]] || fail "POST /v1/operations answered $(body_of "$r")"
RUN=$(body_of "$r" | json 'd["run_id"]')
log "run $RUN started"

curl -sS -N -m 300 -H "Authorization: Bearer $SERVICE_KEY" "$BASE/v1/runs/$RUN/events" >"$WORK/events.txt" ||
  fail "event stream failed"
grep '^event: ' "$WORK/events.txt" | sed 's/^event: //' | sort | uniq -c | sed 's/^/  /' >&2
python3 -I - "$WORK/events.txt" <<'EOF' || fail "unexpected events"
import json, sys
blocks = open(sys.argv[1]).read().strip().split("\n\n")
events = []
for b in blocks:
    e = {}
    for line in b.split("\n"):
        k, _, v = line.partition(": ")
        e[k] = v
    events.append((int(e["id"]), e["event"], json.loads(e["data"])))
last = events[-1]
print(f"terminal event {last[0]} {last[1]}: {json.dumps(last[2])[:400]}", file=sys.stderr)
assert last[1] == "succeeded", "the run did not succeed"
outputs = [d.get("output") for _, ev, d in events
           if ev == "tool_call" and d.get("name") == "shell_run" and d.get("phase") == "finished"]
assert outputs, "no finished shell_run"
text = json.dumps(outputs[0]) if not isinstance(outputs[0], str) else outputs[0]
print("shell_run output:\n" + text, file=sys.stderr)
for needle in ["smoke-file-1000", "direct=blocked", "allowlisted=200", "refused=403", "pip=ok",
               "six-1.16.0-py2.py3-none-any.whl"]:
    assert needle in text, f"missing {needle!r} in the shell_run output"
assert (last[2].get("candidate") or last[2].get("output") or {}).get("text") == "smoke done" \
    or "smoke done" in json.dumps(last[2]), "final_output not in the result"
EOF

r=$(api GET "/v1/runs/$RUN")
RESULT_EVENT=$(body_of "$r" | json 'd["last_event_id"]')
[[ $(body_of "$r" | json 'd["status"]') == succeeded ]] || fail "status is not succeeded: $(body_of "$r")"
printf '{"protocol":"dify-sf-agent/1","generation":1,"result_event_id":%s}' "$RESULT_EVENT" >"$WORK/ack.json"
r=$(api POST "/v1/runs/$RUN/ack" "$WORK/ack.json")
[[ $(status_of "$r") == 200 && $(body_of "$r" | json 'd["acknowledged"]') == True ]] || fail "ack: $r"
log "acknowledged result event $RESULT_EVENT"

SANDBOXES=$(docker ps -aq --filter "label=$LABEL" --filter "label=dify-sf.sandbox.execution")
[[ $(wc -w <<<"$SANDBOXES") == 1 ]] || fail "expected one sandbox container, found: $SANDBOXES"
SANDBOX_NETS=$(docker network ls -q --filter "label=$LABEL" --filter "label=dify-sf.sandbox.execution")
[[ $(wc -w <<<"$SANDBOX_NETS") == 1 ]] || fail "expected one sandbox network, found: $SANDBOX_NETS"
log "sandbox $(docker inspect -f '{{.Name}} {{.State.Health.Status}}' "$SANDBOXES") on $(docker network inspect -f \
  '{{.Name}} {{range .IPAM.Config}}{{.Subnet}}{{end}} internal={{.Internal}} {{index .Options "com.docker.network.bridge.inhibit_ipv4"}}' \
  "$SANDBOX_NETS")"
[[ $(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$SANDBOXES" | wc -w) == 1 ]] ||
  fail "the sandbox is on more than its own network"
[[ $(docker network inspect -f '{{.Internal}} {{index .Options "com.docker.network.bridge.inhibit_ipv4"}}' \
  "$SANDBOX_NETS") == "true true" ]] || fail "the sandbox network is not internal with inhibit_ipv4"
expected=$(for s in agent_service agent_sandbox_proxy; do compose ps -q "$s"; done; echo "$SANDBOXES")
expected=$(docker inspect -f '{{.Id}}' $expected | sort)
attached=$(docker network inspect -f '{{range $k, $v := .Containers}}{{$k}}{{"\n"}}{{end}}' "$SANDBOX_NETS" | sed '/^$/d' | sort)
[[ "$attached" == "$expected" ]] || fail "the sandbox network has other endpoints: $attached"
log "the sandbox network holds exactly the sandbox, agent_service and agent_sandbox_proxy"
owner=$(compose exec -T sandbox_supervisor stat -c '%u:%g %a' /data /data/sandboxes.json | tr '\n' ' ')
log "supervisor /data and state file: $owner"
[[ $owner == "10001:10001 700 10001:10001 "* ]] || fail "unexpected owner of the supervisor state: $owner"

printf '{"protocol":"dify-sf-agent/1","generation":1}' >"$WORK/delete.json"
r=$(api DELETE "/v1/executions/$EXECUTION" "$WORK/delete.json")
[[ $(status_of "$r") == 200 ]] || fail "DELETE execution: $r"
log "deleted execution: $(body_of "$r")"
[[ -z $(docker ps -aq --filter "id=$SANDBOXES") ]] || fail "the sandbox container still exists"
for n in $SANDBOX_NETS; do
  docker network inspect "$n" >/dev/null 2>&1 && fail "the sandbox network $n still exists"
done
log "the supervisor removed the sandbox container${SANDBOX_NETS:+ and its network}"
