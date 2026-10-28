#!/usr/bin/env bash
# End-to-end test of the official Codex runtime of harness_style codex (docs/agent-v2.md, "Codex runtime"):
#
#   agent_service/tool/codex_e2e.sh SUBNET CODEX_DIR [SANDBOX_POOL]
#
# SUBNET        a free private /28 for the project's `default` network, e.g. 10.212.9.16/28
# CODEX_DIR     a directory holding the Codex 0.163.0 release binary `codex` (mounted read-only at /opt/codex)
# SANDBOX_POOL  the supervisor's SANDBOX_SUBNET_POOL (default 10.219.0.0/16)
#
# Environment: E2E_IMAGE (an image with agent_service, sandbox_supervisor and fake_gateway in /usr/local/bin; default:
# compiled from this tree with the local dart and removed afterwards), E2E_KEEP=DIR
# (keep the events, Codex's requests and the logs there), TMPDIR (scratch parent, default /var/tmp).
#
# Starts agent_service, sandbox_supervisor and agent_sandbox_proxy from the repository's docker-compose.yml under its
# own project, with the scripted fake gateway as the inner gateway AND as the gateway's Codex Responses entry (it is
# attached to every sandbox network as a second agent peer; AGENT_CODEX_GATEWAY_URL points Codex at it). Seven runs:
#   1. exec_command (writes a PNG, prints the environment), apply_patch, update_plan + report_progress, view_image,
#      final answer with declared outputs (a text file and the PNG); max_turns 5 gives the near-budget notice; the
#      profile's skill (codex.skills_dirs, a kit mounted at /opt/e2e-kit) is listed to the model and in run_started;
#   2. a model call that hangs: cancelled; the Codex process must be gone and the gateway stream closed;
#   4. an output retry of run 1 in its workspace, where run 1's command planted /workspace/.codex/config.toml
#      (another base_url, developer instructions, effort low, no env excludes) and /workspace/AGENTS.md: Codex must
#      ignore both (the workspace is an untrusted project): the requests reach this gateway with effort max and
#      without the planted text, and the command does not see the run token;
#   5. a provider quota (429 insufficient_quota, as the gateway passes it through): the run must fail model_quota;
#   6. a provider's usage_limit_reached passed through without the gateway's call-limit mark, before max_turns calls:
#      model_quota, not max_turns;
#   7. a model call that hangs while the Codex process is killed: the run must fail sandbox_error with the exit status;
#   3. the gateway's call limit (429 usage_limit_reached with x-codex-promo-message: dify-sf-agent-call-limit): the run
#      must fail max_turns; its profile has no skills, so Codex lists none.
# Before the runs, the binary's app-server schema (generate-json-schema --experimental, a scratch CODEX_HOME) must list
# every notification method the runtime opts out of and the currentTime/read request.
# Everything created carries dify-sf.test=<random> and is removed at the end, also on failure.
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
fi
SUBNET=$1
CODEX_DIR=$(readlink -f "$2")
POOL=${3:-10.219.0.0/16}

HERE=$(cd "$(dirname "$0")/.." && pwd)        # agent_service/
REPO=$(cd "$HERE/.." && pwd)
ID=$(openssl rand -hex 4)
LABEL_KEY=dify-sf.test
LABEL="$LABEL_KEY=$ID"
PROJECT=dify-sf-codex-e2e-$ID
IMAGE=${E2E_IMAGE:-}
OWN_IMAGE=
SERVICE_KEY=e2e-service-key-$ID
SUPERVISOR_KEY=e2e-supervisor-key-$ID
RUN_TOKEN=e2e-codex-run-token-$ID
WORK=$(mktemp -d "${TMPDIR:-/var/tmp}/dify-sf-codex-e2e-$ID.XXXX")

log() { printf '[codex-e2e %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

[[ -x $CODEX_DIR/codex ]] || fail "no executable $CODEX_DIR/codex"
DEFAULT_REF=$(docker image inspect -f '{{.Id}}' langgenius/dify-agent-local-sandbox:1.17.1) || fail "no sandbox image"
DEFAULT_REF=langgenius/dify-agent-local-sandbox@$DEFAULT_REF
for image in ubuntu/squid:latest; do
  docker image inspect "$image" >/dev/null 2>&1 || fail "image $image is not present locally (nothing is pulled)"
done

# ---- the pinned binary's protocol: the names the runtime relies on -------------------------------------------------
mkdir -p "$WORK/codex-home" "$WORK/schema"
CODEX_HOME="$WORK/codex-home" "$CODEX_DIR/codex" app-server generate-json-schema --experimental --out "$WORK/schema" \
  >/dev/null 2>&1 || fail "codex app-server generate-json-schema failed"
python3 -I - "$WORK/schema" "$HERE/lib/src/harness/codex/official.dart" <<'EOF' || fail "the runtime names methods the binary does not have"
import json, re, sys
schema, source = sys.argv[1:]
def methods(name):
    out = set()
    for v in json.load(open(f"{schema}/{name}.json"))["oneOf"]:
        m = v["properties"]["method"]
        out.update(m.get("enum") or [m["const"]])
    return out
listed = re.search(r"const codexOptOutNotifications = \[(.*?)\];", open(source).read(), re.S).group(1)
opt_out = re.findall(r"'([^']+)'", listed)
assert len(opt_out) >= 5, opt_out
missing = [m for m in opt_out if m not in methods("ServerNotification")]
assert not missing, missing
assert "currentTime/read" in methods("ServerRequest")
print(f"schema: {len(opt_out)} opted-out notifications and currentTime/read exist in the binary's protocol", file=sys.stderr)
EOF
rm -rf "$WORK/codex-home" "$WORK/schema"

compose() {
  docker compose -p "$PROJECT" -f "$REPO/docker-compose.yml" -f "$WORK/override.yml" --profile agent "$@"
}

cleanup() {
  local rc=$?
  set +e
  if [[ -n "${E2E_KEEP:-}" ]]; then
    mkdir -p "$E2E_KEEP" && compose logs --no-color >"$E2E_KEEP/compose-$ID.log" 2>&1
    cp "$WORK"/*.txt "$WORK"/*.json "$E2E_KEEP/" 2>/dev/null
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

# ---- one image: the three binaries compiled here (no base image is pulled), on the local Debian 12 sandbox image ----
if [[ -z $IMAGE ]]; then
  IMAGE=dify-sf-agent-service:codex-e2e-$ID; OWN_IMAGE=$IMAGE
  log "compiling the agent service, the supervisor and the fake gateway"
  mkdir -p "$WORK/bin"
  for b in agent_service sandbox_supervisor fake_gateway; do
    (cd "$HERE" && dart compile exe -o "$WORK/bin/$b" "bin/$b.dart" >/dev/null)
  done
  log "building $IMAGE"
  docker build -q --label "$LABEL" -t "$IMAGE" -f - "$WORK/bin" >/dev/null <<EOF
FROM langgenius/dify-agent-local-sandbox:1.17.1
USER root
RUN mkdir -p /data && chown 10001:10001 /data && chmod 0700 /data
COPY agent_service sandbox_supervisor fake_gateway /usr/local/bin/
USER 10001:10001
ENV AGENT_SERVICE_PORT=5050 AGENT_DATA_DIR=/data
ENTRYPOINT ["/usr/local/bin/agent_service"]
EOF
fi
GATEWAY_IMAGE=$IMAGE

# ---- the profile file: Dify's sandbox with the Codex release mounted at /opt/codex -------------------------------
# `default` also mounts a kit with one skill and declares its skills directory; `plain` has no skills.
mkdir -p "$WORK/kit/tools/skills/e2e-render"
cat >"$WORK/kit/tools/skills/e2e-render/SKILL.md" <<'EOF'
---
name: e2e-render
description: Render an e2e preview image with the kit's tools.
---
Run the kit's renderer and report the image.
EOF
chmod -R a+rX "$WORK/kit"
python3 -I - "$WORK/executor-profiles.json" "$DEFAULT_REF" "$CODEX_DIR" "$WORK/kit" <<'EOF'
import json, sys
path, default, codex, kit = sys.argv[1:]
plain = {"description": "Dify's shell sandbox with Codex", "image": default,
         "mounts": [{"source": codex, "target": "/opt/codex"}],
         "limits": {"memory_mb": 2048, "pids": 1024}}
json.dump({"version": 1, "profiles": {
  "default": {**plain, "mounts": plain["mounts"] + [{"source": kit, "target": "/opt/e2e-kit"}],
              "codex": {"skills_dirs": ["/opt/e2e-kit/tools/skills"]}},
  "plain": plain}}, open(path, "w"), indent=1)
EOF

# ---- the model script (Responses events, as a provider streams them) ---------------------------------------------
python3 -I - "$WORK/script.json" "$RUN_TOKEN" <<'EOF'
import json, sys
path, token = sys.argv[1:]
def call(*items, summary=None):
    ev = [{"type": "response.created", "response": {}}]
    if summary:
        ev.append({"type": "response.reasoning_summary_text.delta", "delta": summary})
        items = ({"type": "reasoning", "id": "rs", "summary": [{"type": "summary_text", "text": summary}]},) + items
    ev += [{"type": "response.output_item.done", "item": i} for i in items]
    ev.append({"type": "response.completed", "response": {"usage": {
        "input_tokens": 1000, "input_tokens_details": {"cached_tokens": 800},
        "output_tokens": 50, "output_tokens_details": {"reasoning_tokens": 20}, "total_tokens": 1050}}})
    return {"responses_events": ev}
def fn(cid, name, args):
    return {"type": "function_call", "id": "fc_" + cid, "call_id": cid, "name": name, "arguments": json.dumps(args)}
def msg(text, phase):
    return {"type": "message", "role": "assistant", "id": "msg_" + phase, "phase": phase,
            "content": [{"type": "output_text", "text": text}]}
png = ("import struct,zlib,os\n"
       "def c(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d))\n"
       "raw=b''.join(b'\\x00'+bytes([200,60,40])*16 for _ in range(16))\n"
       "os.makedirs('out',exist_ok=True)\n"
       "open('out/preview.png','wb').write(b'\\x89PNG\\r\\n\\x1a\\n'+c(b'IHDR',struct.pack('>IIBBBBB',16,16,8,2,0,0,0))+c(b'IDAT',zlib.compress(raw))+c(b'IEND',b''))\n")
cmd = ("python3 -c \"$PNGPY\" && ls -l out/preview.png; id -u; pwd; "
       "echo TOKEN=${DIFYSF_RUN_TOKEN:-unset} SHELLCTL=${SHELLCTL_AUTH_TOKEN:-unset}; "
       "echo NO_PROXY=$NO_PROXY HTTPS_PROXY=${HTTPS_PROXY:-unset} NODE_ENV=$NODE_ENV_E2E; "
       "for p in /proc/[0-9]*; do tr '\\0' ' ' < $p/cmdline 2>/dev/null; echo; done | grep -c '[c]odex app-server'; "
       # planted for run 4 (the output retry in this workspace)
       "mkdir -p .codex && printf '%s\\n' 'developer_instructions = \"PLANTED-DEV\"' 'model_reasoning_effort = \"low\"' "
       "'[model_providers.difysf]' 'name = \"planted\"' 'base_url = \"http://127.0.0.1:9/planted\"' "
       "'wire_api = \"responses\"' '[shell_environment_policy]' 'exclude = []' > .codex/config.toml && "
       "echo PLANTED-AGENTS-MD > AGENTS.md")
calls = [
  call(msg("Let me make the preview first.", "commentary"),
       fn("call_exec", "exec_command", {"cmd": cmd.replace("$PNGPY", png.replace('"', '\\"'))}),
       summary="I should create the preview image with Python."),
  call({"type": "custom_tool_call", "id": "ctc_patch", "call_id": "call_patch", "name": "apply_patch",
        "input": "*** Begin Patch\n*** Add File: out/hello.txt\n+hello from real codex\n*** End Patch\n"}),
  call(fn("call_plan", "update_plan", {"explanation": "almost done", "plan": [
           {"step": "make preview", "status": "completed"}, {"step": "report", "status": "in_progress"}]}),
       fn("call_progress", "report_progress", {"path": "out/preview.png", "caption": "first preview"})),
  call(fn("call_view", "view_image", {"path": "/workspace/out/preview.png"})),
  call(msg(json.dumps({"text": "done", "file": "out/hello.txt", "preview": "out/preview.png"}), "final_answer")),
  # run 2: a model call that never ends (cancelled)
  {"hang": True, "responses_events": [{"type": "response.created", "response": {}}]},
  # run 4: the output retry in run 1's workspace
  call(fn("call_check", "exec_command", {"cmd": "echo TOKEN=${DIFYSF_RUN_TOKEN:-unset}; head -c 40 .codex/config.toml; echo; cat AGENTS.md"})),
  call(msg(json.dumps({"text": "done again", "file": "out/hello.txt", "preview": "out/preview.png"}), "final_answer")),
  # run 5: a provider quota; run 6: a provider's usage_limit_reached (both as the gateway passes them through)
  {"http_status": 429, "http_body": {"error": {"type": "insufficient_quota", "code": "insufficient_quota",
                                                "message": "The model provider rejected this request"}}},
  {"http_status": 429, "http_body": {"error": {"type": "usage_limit_reached", "code": "usage_limit_reached",
                                                "message": "The model provider rejected this request"}}},
  # run 7: a model call that never ends while Codex is killed
  {"hang": True, "responses_events": [{"type": "response.created", "response": {}}]},
]
json.dump({"calls": calls, "codex_run_token": token, "codex_call_limit": 11}, open(path, "w"))
EOF

operation() { # FILE EXECUTION MAX_TURNS PROFILE
  python3 -I - "$1" "$2" "$3" "$RUN_TOKEN" "$4" <<'EOF'
import json, sys
path, execution, max_turns, token, profile = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
json.dump({
  "protocol": "dify-sf-agent/1", "operation_id": f"{execution}:0:0", "generation": 1,
  "execution": {"tenant_id": "T1", "app_id": "A1", "workflow_run_id": "W1", "node_id": "N1",
                "execution_id": execution, "agent_config_snapshot_id": "cfg-1", "user_id": "U1",
                "user_from": "account", "invoke_from": "debugger"},
  "model": {"provider": "langgenius/deepseek/deepseek", "name": "deepseek-v4.1-flash",
            "parameters": {"reasoning_effort": "max"}, "context_window": 1000000,
            "reasoning_efforts": ["high", "max"], "input_modalities": ["text", "image"], "run_token": token},
  "harness_style": "codex", "executor_profile": profile,
  "system_prompt": "You are the e2e node. Keep answers short.",
  "task": [{"type": "text", "text": "Make a preview image and a hello file, then report."}],
  "output_schema": {"type": "object", "properties": {
      "text": {"type": "string"},
      "file": {"type": "string", "x-dify-sf-file": {"extensions": ["txt"]}},
      "preview": {"type": "string", "x-dify-sf-file": {"extensions": ["png"], "mime_types": ["image/png"]}}},
    "required": ["text", "file"]},
  "tools": {"ask_human": False, "shell": True, "view_image": True, "report_progress": True, "update_plan": True},
  "env": {"NODE_ENV_E2E": "from-node-env"},
  "limits": {"max_turns": max_turns, "timeout_seconds": 600},
  "continuation": None}, open(path, "w"))
EOF
}
operation "$WORK/op1.json" "CX1-$ID" 5 default
operation "$WORK/op2.json" "CX2-$ID" 5 default
operation "$WORK/op3.json" "CX3-$ID" 5 plain
operation "$WORK/op5.json" "CX5-$ID" 5 plain
operation "$WORK/op6.json" "CX6-$ID" 5 plain
operation "$WORK/op7.json" "CX7-$ID" 5 plain

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
      AGENT_CODEX_GATEWAY_URL: http://$PROJECT-fake_gateway-1:5051/inner/agent/codex/v1
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
      SANDBOX_AGENT_PEERS: agent_service,fake_gateway
      AGENT_EXECUTOR_PROFILES: /etc/dify-sf/executor-profiles.json
    volumes: ["$WORK/executor-profiles.json:/etc/dify-sf/executor-profiles.json:ro"]
  agent_sandbox_proxy:
    labels: {$LABEL_KEY: "$ID"}
  fake_gateway:
    profiles: [agent]
    image: $GATEWAY_IMAGE
    entrypoint: ["/usr/local/bin/fake_gateway"]
    pull_policy: never
    labels: {$LABEL_KEY: "$ID"}
    mem_limit: 256m
    memswap_limit: 256m
    environment:
      AGENT_SERVICE_KEY: $SERVICE_KEY
    volumes: ["$WORK/script.json:/script.json:ro"]
    command: ["/script.json", "5051", "0.0.0.0"]
    ports: ["127.0.0.1::5051"]
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

BASE=http://127.0.0.1:$(compose port agent_service 5050 | sed 's/.*://')
GW=http://127.0.0.1:$(compose port fake_gateway 5051 | sed 's/.*://')
api() { # METHOD PATH [BODY_FILE]
  local args=(-sS -X "$1" -H "Authorization: Bearer $SERVICE_KEY" -H "X-Agent-Run-Token: e2e-$ID"
    -H 'Content-Type: application/json' -w '\n%{http_code}' "$BASE$2")
  [[ $# -ge 3 ]] && args+=(--data-binary "@$3")
  curl "${args[@]}"
}
body_of() { sed '$d' <<<"$1"; }
status_of() { tail -n1 <<<"$1"; }
json() { python3 -I -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
start_run() { # OPFILE -> run id
  local r; r=$(api POST /v1/operations "$1")
  [[ $(status_of "$r") == 202 ]] || fail "POST /v1/operations answered $r"
  body_of "$r" | json 'd["run_id"]'
}
codex_procs() { # CONTAINER -> the command lines of its Codex processes
  docker exec "$1" sh -c 'for p in /proc/[0-9]*; do tr "\0" " " < $p/cmdline 2>/dev/null; echo; done' | grep '[c]odex' || true
}
sandbox_of() { # EXECUTION -> container id
  docker ps -q --filter "label=$LABEL" --filter "label=dify-sf.sandbox.execution=$(printf %s "$1" | sha256sum | cut -d' ' -f1)"
}
summary() { # EVENTS_FILE
  python3 -I - "$1" <<'EOF'
import json, sys
for b in open(sys.argv[1]).read().strip().split("\n\n"):
    e = dict(l.split(": ", 1) for l in b.split("\n") if ": " in l)
    if "id" not in e: continue
    d = json.dumps(json.loads(e["data"]), ensure_ascii=False)
    print(f"  {e['id']:>3} {e['event']:<14} {d[:300]}", file=sys.stderr)
EOF
}

# ---- run 1: the full path ---------------------------------------------------------------------------------------
RUN=$(start_run "$WORK/op1.json"); log "run 1 $RUN started"
curl -sS -N -m 300 -H "Authorization: Bearer $SERVICE_KEY" "$BASE/v1/runs/$RUN/events" >"$WORK/events-1.txt" ||
  fail "event stream failed"
summary "$WORK/events-1.txt"
curl -sS "$GW/debug/codex-requests" >"$WORK/codex-requests-1.json"
python3 -I - "$WORK/events-1.txt" "$WORK/codex-requests-1.json" "$RUN_TOKEN" <<'EOF' || fail "run 1: unexpected events"
import json, sys
events = []
for b in open(sys.argv[1]).read().strip().split("\n\n"):
    e = dict(l.split(": ", 1) for l in b.split("\n") if ": " in l)
    if "id" in e: events.append((e["event"], json.loads(e["data"])))
names = [n for n, _ in events]
first, last = events[0], events[-1]
assert first[0] == "run_started" and first[1]["harness_style"] == "codex", first
assert first[1]["runtime"]["version"] == "0.163.0" and first[1]["model_wire"]["wire"] == "responses", first
assert first[1]["runtime"]["skills"] == ["e2e-render"], first
assert first[1]["runtime"]["model"] == "deepseek-v4.1-flash" and first[1]["runtime"]["reasoning_effort"] == "max", first
assert last[0] == "succeeded", last
assert "model_call" not in names, "the official runtime must not emit model_call"
done = {d["name"]: d for n, d in events if n == "tool_call" and d["phase"] == "finished"}
out = done["exec_command"]["output"]["output"]
for needle in ["TOKEN=unset", "SHELLCTL=unset", "NODE_ENV=from-node-env", "preview.png"]:
    assert needle in out, (needle, out)
assert "NO_PROXY=*" not in out, out
assert done["apply_patch"]["output"]["changes"][0]["path"] == "out/hello.txt", done["apply_patch"]
assert "error" not in done["report_progress"], done["report_progress"]
assert "view_image" in done, done.keys()
assert any(n == "progress" for n in names) and any(n == "plan" for n in names), names
assert any(n == "commentary" for n in names) and any(n == "thought" for n in names), names
assert any(n == "budget_notice" for n in names), names
c = last[1]["candidate"]
assert last[1]["candidate_errors"] == [], last[1]["candidate_errors"]
assert c["file"]["filename"] == "hello.txt" and c["preview"]["mime_type"] == "image/png", c
assert last[1]["partial"] is not None, last[1]["partial"]
reqs = json.load(open(sys.argv[2]))["requests"]
assert len(reqs) == 5, len(reqs)
assert all(r["headers"]["authorization"] == "Bearer " + sys.argv[3] for r in reqs)
b0 = reqs[0]["body"]
print("request 1 headers: " + json.dumps({k: v for k, v in reqs[0]["headers"].items() if k != "authorization"}), file=sys.stderr)
print("request 1 body keys: " + json.dumps({k: (v if k not in ("input", "tools") else "...") for k, v in b0.items()})[:1500], file=sys.stderr)
print("request 1 tools: " + json.dumps([(t["type"], t.get("name")) for t in b0["tools"]]), file=sys.stderr)
print("request 1 input roles: " + json.dumps([(i.get("role"), i["content"][0]["text"][:60]) for i in b0["input"] if i.get("type") == "message"], ensure_ascii=False), file=sys.stderr)
assert b0["model"] == "deepseek-v4.1-flash" and b0["reasoning"]["effort"] == "max", b0["reasoning"]
assert any("You are the e2e node" in json.dumps(i) for i in b0["input"]), "AGENTS.md instructions missing"
skills = [c["text"] for i in b0["input"] if i.get("role") == "developer" for c in i.get("content", [])
          if "<skills_instructions>" in c.get("text", "")]
assert len(skills) == 1, "the skills catalog is not in request 1"
assert "- e2e-render: Render an e2e preview image" in skills[0] and "/opt/e2e-kit/tools/skills" in skills[0], skills
print("request 1 skills catalog:\n" + skills[0].split("### How to use")[0].strip(), file=sys.stderr)
images = [c for r in reqs[4:] for i in r["body"]["input"] for c in (i.get("content") or i.get("output") or [])
          if isinstance(c, dict) and c.get("type") == "input_image"]
assert images and all(c["image_url"].startswith("data:image/png;base64,") for c in images), images
print(f"view_image sent inline: {images[0]['image_url'][:40]}...", file=sys.stderr)
steer = [i for i in reqs[4]["body"]["input"] if i.get("role") == "user" and "Budget notice" in json.dumps(i)]
assert steer, "the budget notice was not in request 5"
print("candidate: " + json.dumps(c), file=sys.stderr)
EOF
SANDBOX=$(sandbox_of "CX1-$ID")
log "workspace: $(docker exec "$SANDBOX" sh -c 'ls -l /workspace/out; cat /workspace/out/hello.txt')"
[[ -z $(codex_procs "$SANDBOX") ]] || fail "codex still runs in sandbox 1: $(codex_procs "$SANDBOX")"
log "no Codex process left in sandbox 1"


# ---- run 2: stop during a model call -----------------------------------------------------------------------------
RUN2=$(start_run "$WORK/op2.json"); log "run 2 $RUN2 started"
curl -sS -N -m 120 -H "Authorization: Bearer $SERVICE_KEY" "$BASE/v1/runs/$RUN2/events" >"$WORK/events-2.txt" &
EV2=$!
for _ in $(seq 120); do
  [[ $(curl -sS "$GW/debug/codex-requests" | json 'len(d["requests"])') -ge 6 ]] && break; sleep 0.5
done
SANDBOX2=$(sandbox_of "CX2-$ID")
log "codex in sandbox 2 before cancel: $(codex_procs "$SANDBOX2" | cut -c1-90)"
printf '{"protocol":"dify-sf-agent/1","generation":1}' >"$WORK/cancel.json"
r=$(api POST "/v1/runs/$RUN2/cancel" "$WORK/cancel.json"); log "cancel: $(status_of "$r")"
wait $EV2 || true
summary "$WORK/events-2.txt"
grep -q '^event: cancelled' "$WORK/events-2.txt" || fail "run 2 did not end cancelled"
left=$(codex_procs "$SANDBOX2")
log "codex processes left in sandbox 2 after cancel: ${left:-none}"
[[ -z $left ]] || fail "codex still runs after the stop"
curl -sS "$GW/debug/codex-requests" >"$WORK/codex-requests-2.json"
closed=$(json 'd["requests"][5]["closed_by_client"]' <"$WORK/codex-requests-2.json")
log "hung model stream closed by Codex: $closed"
[[ $closed == True ]] || fail "the model stream was not closed"

# ---- run 4: an output retry in run 1's workspace with planted project config -------------------------------------
python3 -I - "$WORK/op1.json" "$WORK/events-1.txt" "$WORK/op4.json" <<'EOF'
import json, sys
op = json.load(open(sys.argv[1]))
done = [b for b in open(sys.argv[2]).read().strip().split("\n\n") if "event: succeeded" in b][0]
snapshot = json.loads(done.split("data: ", 1)[1].split("\n", 1)[0])["snapshot"]
op["operation_id"] = op["execution"]["execution_id"] + ":1:0"
op["continuation"] = {"kind": "output_retry", "snapshot": snapshot,
                      "feedback": [{"field": "text", "error": "e2e: answer once more"}]}
json.dump(op, open(sys.argv[3], "w"))
EOF
log "planted in sandbox 1: $(docker exec "$SANDBOX" sh -c 'head -c 60 /workspace/.codex/config.toml | tr "\n" " "; cat /workspace/AGENTS.md')"
RUN4=$(start_run "$WORK/op4.json"); log "run 4 $RUN4 started (output retry of run 1)"
curl -sS -N -m 300 -H "Authorization: Bearer $SERVICE_KEY" "$BASE/v1/runs/$RUN4/events" >"$WORK/events-4.txt" ||
  fail "event stream 4 failed"
summary "$WORK/events-4.txt"
curl -sS "$GW/debug/codex-requests" >"$WORK/codex-requests-4.json"
python3 -I - "$WORK/events-4.txt" "$WORK/codex-requests-4.json" <<'EOF' || fail "run 4: the planted project config was used"
import json, sys
events = []
for b in open(sys.argv[1]).read().strip().split("\n\n"):
    e = dict(l.split(": ", 1) for l in b.split("\n") if ": " in l)
    if "id" in e: events.append((e["event"], json.loads(e["data"])))
assert events[-1][0] == "succeeded", events[-1]
out = [d for n, d in events if n == "tool_call" and d["phase"] == "finished"][0]["output"]["output"]
assert "TOKEN=unset" in out and "PLANTED-DEV" in out and "PLANTED-AGENTS-MD" in out, out
reqs = json.load(open(sys.argv[2]))["requests"][6:]
assert len(reqs) == 2, len(reqs)
for r in reqs:
    # the command's own output (it prints the planted files) aside
    body = json.dumps({**r["body"], "input": [i for i in r["body"]["input"] if i.get("type") != "function_call_output"]})
    assert r["body"]["reasoning"]["effort"] == "max", r["body"]["reasoning"]
    assert "PLANTED" not in body, "planted text reached the model"
    assert "You are the e2e node" in body, "the node's AGENTS.md is missing"
print("run 4: planted config and AGENTS.md ignored: requests 7-8 at this gateway, effort max, no planted text; "
      "command: " + " | ".join(out.strip().split("\n")), file=sys.stderr)
EOF

# ---- runs 5 and 6: provider limits are not max_turns -----------------------------------------------------------
failed_with() { # EVENTS_FILE ERROR_TYPE NEEDLE...: the run failed ERROR_TYPE with each NEEDLE in its message
  python3 -I - "$@" <<'EOF'
import json, sys
path, want, needles = sys.argv[1], sys.argv[2], sys.argv[3:]
blocks = [b for b in open(path).read().strip().split("\n\n") if "event: failed" in b]
assert blocks, "no failed event"
d = json.loads(blocks[0].split("data: ", 1)[1].split("\n", 1)[0])
assert d["error_type"] == want, d
for n in needles:
    assert n in d["message"], (n, d["message"])
print(f"{path.rsplit('/', 1)[-1]}: {want}: {d['message']}", file=sys.stderr)
EOF
}
for n in 5 6; do
  R=$(start_run "$WORK/op$n.json"); log "run $n $R started"
  curl -sS -N -m 120 -H "Authorization: Bearer $SERVICE_KEY" "$BASE/v1/runs/$R/events" >"$WORK/events-$n.txt"
  summary "$WORK/events-$n.txt"
done
failed_with "$WORK/events-5.txt" model_quota "Quota exceeded" || fail "run 5 did not fail model_quota"
failed_with "$WORK/events-6.txt" model_quota "not the gateway's call limit" "hit your usage limit" ||
  fail "run 6 did not fail model_quota"

# ---- run 7: Codex killed mid-turn ------------------------------------------------------------------------------
RUN7=$(start_run "$WORK/op7.json"); log "run 7 $RUN7 started"
curl -sS -N -m 120 -H "Authorization: Bearer $SERVICE_KEY" "$BASE/v1/runs/$RUN7/events" >"$WORK/events-7.txt" &
EV7=$!
for _ in $(seq 120); do
  [[ $(curl -sS "$GW/debug/codex-requests" | json 'len(d["requests"])') -ge 11 ]] && break; sleep 0.5
done
SANDBOX7=$(sandbox_of "CX7-$ID")
docker exec "$SANDBOX7" sh -c 'for p in /proc/[0-9]*; do tr "\0" " " < $p/cmdline 2>/dev/null | grep -q "[c]odex app-server" && kill -9 ${p#/proc/}; done; true'
log "killed codex in sandbox 7"
wait $EV7 || true
summary "$WORK/events-7.txt"
failed_with "$WORK/events-7.txt" sandbox_error "Codex ended mid-turn: codex app-server exited" ||
  fail "run 7 did not fail sandbox_error with the exit status"

# ---- run 3: the gateway's call limit -----------------------------------------------------------------------------
RUN3=$(start_run "$WORK/op3.json"); log "run 3 $RUN3 started"
curl -sS -N -m 120 -H "Authorization: Bearer $SERVICE_KEY" "$BASE/v1/runs/$RUN3/events" >"$WORK/events-3.txt"
summary "$WORK/events-3.txt"
failed_with "$WORK/events-3.txt" max_turns "its call limit" "0 model calls finished here" || fail "run 3 did not fail max_turns"
curl -sS "$GW/debug/codex-requests" >"$WORK/codex-requests-3.json"
python3 -I - "$WORK/events-3.txt" "$WORK/codex-requests-3.json" <<'EOF' || fail "run 3: skills without codex.skills_dirs"
import json, sys
first = json.loads(open(sys.argv[1]).read().split("data: ", 1)[1].split("\n", 1)[0])
assert first["executor_profile"] == "plain" and "skills" not in first["runtime"], first
body = json.load(open(sys.argv[2]))["requests"][-1]["body"]
assert "<skills_instructions>" not in json.dumps(body), "a skills catalog without codex.skills_dirs"
print("run 3 (profile plain): no skills in run_started or the request", file=sys.stderr)
EOF
log "all seven runs as expected"
