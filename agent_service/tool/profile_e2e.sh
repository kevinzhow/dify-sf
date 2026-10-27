#!/usr/bin/env bash
# End-to-end test of the executor profile colvalley-blender (docs/agent-v2.md, "Executor profiles"):
#
#   agent_service/tool/profile_e2e.sh SUBNET CHECKOUT BLEND [SANDBOX_POOL]
#
# SUBNET        a free private /28 for the project's `default` network, e.g. 10.212.9.0/28
# CHECKOUT      a colvalley-3d checkout made by its tools/board/prepare_checkout.sh (mounted read-only at
#               /opt/colvalley-3d)
# BLEND         the candidate .blend (e.g. the fujiya r6 model); given to the run as an input file (files[])
# SANDBOX_POOL  the supervisor's SANDBOX_SUBNET_POOL (default 10.219.0.0/16)
#
# Environment: E2E_IMAGE (agent service image; default: built from this tree as dify-sf-agent-service:e2e-<id> and
# removed afterwards), E2E_BLENDER_IMAGE (default: dify-sf/sandbox-colvalley-blender:1, resolved to its digest),
# E2E_DEFAULT_IMAGE (default langgenius/dify-agent-local-sandbox:1.17.1, resolved to its digest), E2E_RENDER_NODE
# (default /dev/dri/renderD128), E2E_KEEP=DIR (keep the logs, events and the downloaded outputs there), TMPDIR (the
# scratch directory's parent, default /var/tmp).
#
# It writes a profile file with `default` and `colvalley-blender`, starts agent_service, sandbox_supervisor and
# agent_sandbox_proxy from the repository's docker-compose.yml under its own project (the profile file mounted
# read-only into both, /dev/dri read-only into the supervisor so that it can read the render node's group) and a
# scripted fake inner gateway. One operation (tools.shell, tools.view_image, executor_profile colvalley-blender) runs:
# the model calls shell_run (render_board.sh --object fujiya on the input .blend inside the sandbox), view_image on the
# board and final_output with the board as a declared file output. The test checks the run, the uploaded board, the
# sandbox container (image digest, read-only checkout, render node and group, limits, no proxy, its network), measures
# the sandbox's peak memory and CPU from its cgroup, acks, deletes the execution and checks that the sandbox is gone.
# Everything created carries dify-sf.test=<random> and is removed at the end, also on failure.
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
fi
SUBNET=$1
CHECKOUT=$(readlink -f "$2")
BLEND=$(readlink -f "$3")
POOL=${4:-10.219.0.0/16}
RENDER_NODE=${E2E_RENDER_NODE:-/dev/dri/renderD128}

HERE=$(cd "$(dirname "$0")/.." && pwd)        # agent_service/
REPO=$(cd "$HERE/.." && pwd)
ID=$(openssl rand -hex 4)
LABEL_KEY=dify-sf.test
LABEL="$LABEL_KEY=$ID"
PROJECT=dify-sf-e2e-$ID
IMAGE=${E2E_IMAGE:-}
OWN_IMAGE=
GATEWAY_IMAGE=dify-sf-e2e-gateway:$ID
SERVICE_KEY=e2e-service-key-$ID
SUPERVISOR_KEY=e2e-supervisor-key-$ID
WORK=$(mktemp -d "${TMPDIR:-/var/tmp}/dify-sf-e2e-$ID.XXXX")   # TMPDIR: a disk directory (big outputs never in /tmp)
EXECUTION=E2E-$ID
FILE_ID=$(python3 -I -c 'import uuid; print(uuid.uuid4())')

log() { printf '[e2e %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }
digest_ref() { # IMAGE -> repo@sha256:<id> (the containerd image store's content digest)
  local id repo
  id=$(docker image inspect -f '{{.Id}}' "$1") || return 1
  repo=${1%@*}; repo=${repo%:*}
  echo "$repo@$id"
}

[[ -f $CHECKOUT/.cv3d-prepared/checkout.txt && -x $CHECKOUT/.cv3d-prepared/fs_importer ]] \
  || fail "$CHECKOUT is not a prepared colvalley-3d checkout (tools/board/prepare_checkout.sh)"
[[ -f $BLEND ]] || fail "no file $BLEND"
[[ -c $RENDER_NODE ]] || fail "no render node $RENDER_NODE"
BLENDER_REF=$(digest_ref "${E2E_BLENDER_IMAGE:-dify-sf/sandbox-colvalley-blender:1}") || fail "no colvalley-blender image"
DEFAULT_REF=$(digest_ref "${E2E_DEFAULT_IMAGE:-langgenius/dify-agent-local-sandbox:1.17.1}") || fail "no default sandbox image"
for image in ubuntu/squid:latest dart:3.13 debian:bookworm-slim; do
  docker image inspect "$image" >/dev/null 2>&1 || fail "image $image is not present locally (nothing is pulled)"
done

compose() {
  docker compose -p "$PROJECT" -f "$REPO/docker-compose.yml" -f "$WORK/override.yml" --profile agent "$@"
}

SAMPLER=
cleanup() {
  local rc=$?
  set +e
  [[ -n $SAMPLER ]] && kill "$SAMPLER" 2>/dev/null
  if [[ -n "${E2E_KEEP:-}" ]]; then
    mkdir -p "$E2E_KEEP" && compose logs --no-color >"$E2E_KEEP/compose-$ID.log" 2>&1
    cp "$WORK"/*.txt "$WORK"/*.json "$WORK"/*.png "$E2E_KEEP/" 2>/dev/null
  elif [[ $rc -ne 0 && -f "$WORK/override.yml" ]]; then
    compose logs --no-color --tail 80 >&2
  fi
  log "cleanup"
  [[ -f "$WORK/override.yml" ]] && compose down -v --remove-orphans --timeout 5 >/dev/null 2>&1
  for c in $(docker ps -aq --filter "label=$LABEL"); do docker rm -f -v "$c" >/dev/null; done
  for n in $(docker network ls -q --filter "label=$LABEL"); do
    for c in $(docker network inspect -f '{{range $k, $v := .Containers}}{{$k}} {{end}}' "$n"); do
      docker network disconnect -f "$n" "$c" >/dev/null 2>&1
    done
    docker network rm "$n" >/dev/null
  done
  for v in $(docker volume ls -q --filter "label=$LABEL"); do docker volume rm "$v" >/dev/null; done
  docker image rm "$GATEWAY_IMAGE" >/dev/null 2>&1
  [[ -n $OWN_IMAGE ]] && docker image rm "$OWN_IMAGE" >/dev/null 2>&1
  rm -rf "$WORK"
  local left
  left="$(docker ps -aq --filter "label=$LABEL")$(docker network ls -q --filter "label=$LABEL")"
  left+="$(docker volume ls -q --filter "label=$LABEL")$(docker image ls -q --filter "label=$LABEL")"
  log "cleanup check (label $LABEL): containers/networks/volumes/images left: ${left:-none}"
  if [[ -n "$left" ]]; then log "FAIL: cleanup left resources"; rc=1; fi
  if [[ $rc -eq 0 ]]; then log "PASS"; fi
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---- images: the agent service from this tree, the fake inner gateway ------------------------------------------
if [[ -z $IMAGE ]]; then
  IMAGE=dify-sf-agent-service:e2e-$ID; OWN_IMAGE=$IMAGE
  log "building $IMAGE"
  docker build -q --label "$LABEL" -t "$IMAGE" "$HERE" >/dev/null
fi
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

# ---- the profile file -------------------------------------------------------------------------------------------
python3 -I - "$WORK/executor-profiles.json" "$DEFAULT_REF" "$BLENDER_REF" "$CHECKOUT" "$RENDER_NODE" <<'EOF'
import json, sys
path, default, blender, checkout, node = sys.argv[1:]
json.dump({"version": 1, "profiles": {
  "default": {"description": "Dify's shell sandbox", "image": default},
  "colvalley-blender": {
    "description": "Blender 5.2.3, colvalley-3d (read-only) and its board renderer",
    "image": blender,
    "mounts": [{"source": checkout, "target": "/opt/colvalley-3d"}],
    "network": {"egress": "none"},
    "devices": [node],
    "limits": {"cpus": 4, "memory_mb": 6144, "pids": 1024, "workspace_mb": 1536, "home_mb": 512,
               "timeout_seconds_max": 10800, "max_turns_max": 200},
    "env": {"BLENDER": "/opt/blender/blender", "CV3D_PYTHON": "/opt/cv3d-venv/bin/python",
            "FS_IMPORTER": "/opt/colvalley-3d/.cv3d-prepared/fs_importer"}}}}, open(path, "w"), indent=1)
EOF

# ---- the model script: shell_run (the board), view_image, final_output -------------------------------------------
SHELL_SCRIPT=$(cat <<'EOF'
# Output is collected and printed at the end: shellctl returns a running job once its output goes idle.
{
echo "uid=$(id -u) groups=$(id -G)"
echo "env BLENDER=$BLENDER CV3D_PYTHON=$CV3D_PYTHON FS_IMPORTER=$FS_IMPORTER"
head -3 /opt/colvalley-3d/.cv3d-prepared/checkout.txt
if ( : > /opt/colvalley-3d/.e2e-probe ) 2>/dev/null; then echo checkout=writable; else echo checkout=read-only; fi
if timeout 5 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null; then echo direct=open; else echo direct=blocked; fi
echo "proxy_env=${HTTPS_PROXY:-none}"
s=$(date +%s%N)
/opt/colvalley-3d/tools/board/render_board.sh --object fujiya --collection Model --work-dir /workspace/cv3d \
  -o /workspace/board 'r6=/workspace/in/fujiya_r6.blend' > /workspace/board.log 2>&1
echo "BOARD_RC=$? BOARD_MS=$(( ($(date +%s%N) - s) / 1000000 ))"
tail -4 /workspace/board.log
grep -h FS_AA /workspace/board/1/render.log | head -1
ls -l /workspace/board/board.png
du -sh /workspace 2>/dev/null
} > /workspace/e2e.out 2>&1; cat /workspace/e2e.out
EOF
)
python3 -I - "$WORK/script.json" "$SHELL_SCRIPT" "$FILE_ID" "$BLEND" <<'EOF'
import base64, json, sys
path, script, file_id, blend = sys.argv[1:]
data = open(blend, "rb").read()
def call(cid, name, args):
    return {"chunks": [
        {"tool_calls": [{"id": cid, "type": "function",
                         "function": {"name": name, "arguments": json.dumps(args)}}]},
        {"usage": {"prompt_tokens": 10, "completion_tokens": 5}, "finish_reason": "tool_calls"}]}
json.dump({"files": {file_id: {"mime_type": "application/x-blender", "size": len(data),
                               "content_base64": base64.b64encode(data).decode()}},
           "calls": [call("c1", "shell_run", {"script": script, "timeout": 280}),
                     call("c2", "view_image", {"path": "board/board.png"}),
                     call("c3", "final_output", {"text": "board rendered", "board": "board/board.png"})]},
          open(path, "w"))
EOF
python3 -I - "$WORK/operation.json" "$EXECUTION" "$FILE_ID" <<'EOF'
import json, sys
path, execution, file_id = sys.argv[1:]
json.dump({
  "protocol": "dify-sf-agent/1", "operation_id": f"{execution}:0:0", "generation": 1,
  "execution": {"tenant_id": "T1", "app_id": "A1", "workflow_run_id": "W1", "node_id": "N1",
                "execution_id": execution, "agent_config_snapshot_id": "cfg-1", "user_id": "U1",
                "user_from": "account", "invoke_from": "debugger"},
  "model": {"provider": "langgenius/deepseek/deepseek", "name": "e2e-scripted-model", "parameters": {}},
  "system_prompt": "You model in Blender and check your board.",
  "task": [{"type": "text", "text": "Render the board of the fujiya r6 candidate."}],
  "output_schema": {"type": "object", "properties": {
      "text": {"type": "string"},
      "board": {"type": "string", "x-dify-sf-file": {"extensions": ["png"], "mime_types": ["image/png"]}}},
    "required": ["text", "board"]},
  "tools": {"ask_human": False, "shell": True, "view_image": True}, "env": {},
  "files": [{"file_id": file_id, "path": "in/fujiya_r6.blend"}],
  "limits": {"max_turns": 6, "timeout_seconds": 3600},
  "executor_profile": "colvalley-blender",
  "continuation": None}, open(path, "w"))
EOF

# ---- the compose override ---------------------------------------------------------------------------------------
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
      AGENT_EXECUTOR_PROFILES: /etc/dify-sf/executor-profiles.json
    volumes: ["$WORK/executor-profiles.json:/etc/dify-sf/executor-profiles.json:ro"]
    ports: ["127.0.0.1::5050"]
  sandbox_supervisor:
    image: $IMAGE
    pull_policy: never
    labels: {$LABEL_KEY: "$ID"}
    group_add: ["$DOCKER_GID"]
    environment:
      SANDBOX_SUPERVISOR_KEY: $SUPERVISOR_KEY
      SANDBOX_LABEL: $LABEL
      SANDBOX_SUBNET_POOL: $POOL
      SANDBOX_START_TIMEOUT: "120"
      AGENT_EXECUTOR_PROFILES: /etc/dify-sf/executor-profiles.json
    volumes:
      - "$WORK/executor-profiles.json:/etc/dify-sf/executor-profiles.json:ro"
      - "/dev/dri:/dev/dri:ro"
  agent_sandbox_proxy:
    labels: {$LABEL_KEY: "$ID"}
  fake_gateway:
    profiles: [agent]
    image: $GATEWAY_IMAGE
    pull_policy: never
    labels: {$LABEL_KEY: "$ID"}
    mem_limit: 256m
    memswap_limit: 256m
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
chmod a+r "$WORK/script.json" "$WORK/executor-profiles.json"
chmod a+x "$WORK"

log "starting project $PROJECT (default network $SUBNET, sandbox pool $POOL)"
compose up -d --no-build --pull never --wait --wait-timeout 120 \
  agent_service sandbox_supervisor agent_sandbox_proxy fake_gateway

PORT=$(compose port agent_service 5050 | sed 's/.*://')
BASE=http://127.0.0.1:$PORT
api() { # METHOD PATH [BODY_FILE]
  local args=(-sS -X "$1" -H "Authorization: Bearer $SERVICE_KEY" -H "X-Agent-Run-Token: e2e-$ID"
    -H 'Content-Type: application/json' -w '\n%{http_code}' "$BASE$2")
  [[ $# -ge 3 ]] && args+=(--data-binary "@$3")
  curl "${args[@]}"
}
status_of() { tail -n1 <<<"$1"; }
body_of() { sed '$d' <<<"$1"; }
json() { python3 -I -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

r=$(api GET /v1/profiles)
log "profiles: $(body_of "$r")"
[[ $(body_of "$r" | json '" ".join(p["name"] + "=" + p["status"] for p in d["profiles"])') == \
   "default=ok colvalley-blender=ok" ]] || fail "profiles are not both ok"
body_of "$r" | grep -qE 'sha256|/opt|/dev/dri|BLENDER' && fail "GET /v1/profiles shows images, mounts, devices or env"
r=$(api GET /v1/health)
log "health: $(body_of "$r")"

r=$(api POST /v1/operations "$WORK/operation.json")
[[ $(status_of "$r") == 202 ]] || fail "POST /v1/operations answered $(body_of "$r")"
RUN=$(body_of "$r" | json 'd["run_id"]')
T0=$(date +%s%N)
log "run $RUN started"

# Sample the sandbox's cgroup while the run goes on (memory.peak covers the container's whole life).
( while sleep 0.5; do
    c=$(docker ps -q --no-trunc --filter "label=$LABEL" --filter "label=dify-sf.sandbox.execution" | head -1)
    [[ -n $c && -r /sys/fs/cgroup/system.slice/docker-$c.scope/memory.current ]] || continue
    echo "$(date +%s.%N) $(cat /sys/fs/cgroup/system.slice/docker-$c.scope/memory.current) $(awk '/usage_usec/{print $2}' /sys/fs/cgroup/system.slice/docker-$c.scope/cpu.stat)"
  done ) > "$WORK/samples.txt" 2>/dev/null &
SAMPLER=$!

curl -sS -N -m 900 -H "Authorization: Bearer $SERVICE_KEY" "$BASE/v1/runs/$RUN/events" >"$WORK/events.txt" ||
  fail "event stream failed"
T1=$(date +%s%N)
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
    if "id" in e:  # not a ": keep-alive" comment
        events.append((int(e["id"]), e["event"], json.loads(e["data"])))
first, last = events[0], events[-1]
assert first[1] == "run_started" and first[2]["executor_profile"] == "colvalley-blender", first
print(f"run_started: {json.dumps(first[2])}", file=sys.stderr)
print(f"terminal event {last[0]} {last[1]}: {json.dumps(last[2])[:600]}", file=sys.stderr)
assert last[1] == "succeeded", "the run did not succeed"
finished = {d["name"]: d for _, ev, d in events if ev == "tool_call" and d.get("phase") == "finished"}
out = finished["shell_run"].get("output")
text = out if isinstance(out, str) else json.dumps(out)
print("shell_run output:\n" + text, file=sys.stderr)
for needle in ["BOARD_RC=0", "checkout=read-only", "direct=blocked", "proxy_env=none",
               "FS_AA requested=msaa effective=msaa", "env BLENDER=/opt/blender/blender"]:
    assert needle in text, f"missing {needle!r} in the shell_run output"
view = finished["view_image"]
assert "error" not in view and "attached" in view["output"], view
print("view_image: " + view["output"], file=sys.stderr)
c = last[2]["candidate"]
assert last[2]["candidate_errors"] == [], last[2]["candidate_errors"]
assert c["board"]["filename"] == "board.png" and c["board"]["mime_type"] == "image/png", c
print(f"declared output board: {json.dumps(c['board'])}", file=sys.stderr)
EOF

SANDBOX=$(docker ps -q --no-trunc --filter "label=$LABEL" --filter "label=dify-sf.sandbox.execution")
[[ $(wc -w <<<"$SANDBOX") == 1 ]] || fail "expected one sandbox container, found: $SANDBOX"
CG=/sys/fs/cgroup/system.slice/docker-$SANDBOX.scope
PEAK=$(cat "$CG/memory.peak"); CPU_US=$(awk '/usage_usec/{print $2}' "$CG/cpu.stat")
kill $SAMPLER 2>/dev/null; wait $SAMPLER 2>/dev/null || true
python3 -I - "$WORK/samples.txt" "$PEAK" "$CPU_US" "$T0" "$T1" <<'EOF' | tee "$WORK/measurements.txt" >&2
import sys
path, peak, cpu_us, t0, t1 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
rows = [tuple(map(float, l.split())) for l in open(path) if len(l.split()) == 3]
best = 0.0
for (ta, _, ua), (tb, _, ub) in zip(rows, rows[1:]):
    if tb > ta: best = max(best, (ub - ua) / 1e6 / (tb - ta))
print(f"sandbox memory.peak {peak / 2**20:.0f} MiB (cgroup, tmpfs included); "
      f"sampled max memory.current {max((r[1] for r in rows), default=0) / 2**20:.0f} MiB")
print(f"sandbox CPU {cpu_us / 1e6:.1f} s total; peak {best:.2f} CPUs over 0.5 s samples")
print(f"run wall time {(t1 - t0) / 1e9:.1f} s (POST to terminal event)")
EOF
docker inspect "$SANDBOX" >"$WORK/sandbox-inspect.json"
python3 -I - "$WORK/sandbox-inspect.json" "$BLENDER_REF" "$CHECKOUT" "$RENDER_NODE" "$(stat -c %g "$RENDER_NODE")" <<'EOF' || fail "unexpected sandbox container"
import json, sys
c = json.load(open(sys.argv[1]))[0]
ref, checkout, node, gid = sys.argv[2:]
hc, cfg = c["HostConfig"], c["Config"]
assert cfg["Image"] == ref, cfg["Image"]
assert cfg["Labels"]["dify-sf.sandbox.profile"] == "colvalley-blender"
assert not [e for e in cfg["Env"] if "proxy" in e.lower()], cfg["Env"]
m = [x for x in c["Mounts"] if x["Destination"] == "/opt/colvalley-3d"]
assert len(m) == 1 and m[0]["Source"] == checkout and m[0]["RW"] is False and m[0]["Type"] == "bind", c["Mounts"]
assert [d["PathOnHost"] for d in hc["Devices"]] == [node] and hc["GroupAdd"] == [gid], (hc["Devices"], hc["GroupAdd"])
assert hc["Memory"] == 6144 << 20 and hc["NanoCpus"] == 4 * 10**9 and hc["PidsLimit"] == 1024
assert hc["ReadonlyRootfs"] and hc["CapDrop"] == ["ALL"] and not hc["Privileged"]
assert "size=1536m" in hc["Tmpfs"]["/workspace"] and "size=512m" in hc["Tmpfs"]["/home/dify"]
print(f"sandbox: image {cfg['Image']}, checkout ro, {node} + group {gid}, 4 CPUs, 6144 MiB, 1024 PIDs, no proxy",
      file=sys.stderr)
EOF
NET=$(docker network ls -q --filter "label=$LABEL" --filter "label=dify-sf.sandbox.execution")
attached=$(docker network inspect -f '{{range $k, $v := .Containers}}{{$k}}{{"\n"}}{{end}}' "$NET" | sed '/^$/d' | sort)
expected=$( (docker inspect -f '{{.Id}}' "$(compose ps -q agent_service)"; echo "$SANDBOX") | sort)
[[ "$attached" == "$expected" ]] || fail "the sandbox network has other endpoints (the proxy?): $attached"
log "the sandbox network holds exactly the sandbox and agent_service (egress none: no proxy)"

# The board as the sandbox holds it (the fake gateway keeps the uploaded copy in memory only).
docker exec "$SANDBOX" cat /workspace/board/board.png >"$WORK/board.png"
docker exec "$SANDBOX" cat /workspace/board/measurements.txt >"$WORK/board-measurements.txt"
log "board.png $(stat -c %s "$WORK/board.png") bytes, sha256 $(sha256sum "$WORK/board.png" | cut -c1-16)"

r=$(api GET "/v1/runs/$RUN")
RESULT_EVENT=$(body_of "$r" | json 'd["last_event_id"]')
printf '{"protocol":"dify-sf-agent/1","generation":1,"result_event_id":%s}' "$RESULT_EVENT" >"$WORK/ack.json"
r=$(api POST "/v1/runs/$RUN/ack" "$WORK/ack.json")
[[ $(status_of "$r") == 200 ]] || fail "ack: $r"
printf '{"protocol":"dify-sf-agent/1","generation":1}' >"$WORK/delete.json"
r=$(api DELETE "/v1/executions/$EXECUTION" "$WORK/delete.json")
[[ $(status_of "$r") == 200 ]] || fail "DELETE execution: $r"
[[ -z $(docker ps -aq --filter "id=$SANDBOX") ]] || fail "the sandbox container still exists"
docker network inspect "$NET" >/dev/null 2>&1 && fail "the sandbox network still exists"
log "deleted the execution; the sandbox container and its network are gone"
