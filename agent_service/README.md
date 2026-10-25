# agent_service

The Agent v2 agent service of dify-sf: a standalone Dart program that runs inline agents with
[Genkit Dart](https://pub.dev/packages/genkit) 1.0.1. The Swift server starts one operation per agent step (first run,
each answer to a question, each declared-output retry); the service runs the agent loop and streams events. It never
holds model credentials: every model call goes back through the Swift server's inner gateway.

The contract it implements is [`docs/agent-v2.md`](../docs/agent-v2.md) (protocol `dify-sf-agent/1`, session envelope
`dify-sf-agent-session/1`).

## What is in this version

- All routes of the protocol: operations (idempotent by request digest, generation checks), run status, the event
  stream with cursor resume, ack, cancel, leases, execution deletion, the reconciliation list and health.
- A durable run store under `AGENT_DATA_DIR`: append-only events, the terminal result written before it is streamed,
  the per-execution generation and operation index. Events are kept until ack or 24 hours after the run ended.
- A Genkit model over `POST /inner/agent/llm/invoke`: Dify `PromptMessage` mapping (images as
  `dify-sf-file:<file_id>` references), streamed chunks, tool-call deltas merged by index or id, reasoning from `<think>` tags or
  `reasoning_content`, usage per call.
- The `ask_human` tool with Dify's arguments and limits; pauses with a versioned session snapshot and resumes the
  original tool call in a later operation (any process).
- Declared outputs through the `final_output` tool, as in Dify: its arguments are the candidate, with per-field
  errors (the Swift server decides retries and defaults).

- The shell: Dify's `shell_run`, `shell_wait`, `shell_input` and `shell_interrupt` over one sandbox container per
  execution (`lib/src/sandbox/`), created through the sandbox supervisor on first shell use, probed before the first
  command, with `files[]` materialized into `/workspace`. Its ID is the envelope's `workspace_ref`; a resume reuses it.
  Every run end terminates the run's jobs and kills what they left; DELETE and lease expiry release the sandbox.
- Declared file outputs (`x-dify-sf-file`): workspace paths checked, uploaded and replaced by
  `{"upload_id", "filename", "mime_type", "size"}`.
- The sandbox supervisor, `bin/sandbox_supervisor.dart` (`lib/src/supervisor/`): the only component with Docker access.

Without `AGENT_SANDBOX_SUPERVISOR_URL`, `tools.shell: true` fails with `sandbox_unavailable` and health reports
`"sandbox": "disabled"`.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `AGENT_SERVICE_KEY` | required | Bearer key every request must carry; also sent on inner calls |
| `AGENT_DATA_DIR` | required | Run store root |
| `AGENT_SERVICE_PORT` | `5050` | Listening port (all interfaces) |
| `AGENT_INNER_URL` | none | Base URL of the Swift server's inner endpoints; without it runs fail and health is `degraded` |
| `AGENT_LOG_LEVEL` | `info` | `debug`, `info`, `warning` or `error` |
| `AGENT_SANDBOX_SUPERVISOR_URL` | none | The sandbox supervisor; without it the shell is disabled |
| `AGENT_SANDBOX_SUPERVISOR_KEY` | required with the URL | The supervisor's bearer key |

The supervisor (`sandbox_supervisor`) reads:

| Variable | Default | Meaning |
|---|---|---|
| `SANDBOX_SUPERVISOR_KEY` | required | Bearer key of its API |
| `SANDBOX_NETWORK` | required | Existing internal Docker network for sandboxes (never created by the supervisor) |
| `SANDBOX_SUPERVISOR_PORT` | `5060` | Listening port |
| `DOCKER_SOCKET` | `/var/run/docker.sock` | Docker Engine API socket (API v1.44) |
| `SANDBOX_IMAGE` | `langgenius/dify-agent-local-sandbox:1.17.1` | Sandbox image (must be present; never pulled) |
| `SANDBOX_LABEL` | `dify-sf.agent-sandbox=1` | `key=value` on every sandbox; only such containers are listed, swept or removed |
| `SANDBOX_NAME_PREFIX` | `dify-sf-sandbox-` | Container names: prefix + 24 hex of SHA-256(execution key) |
| `SANDBOX_MEMORY_MB`, `SANDBOX_CPUS`, `SANDBOX_PIDS_LIMIT` | `1024`, `1`, `256` | Limits (memory includes the tmpfs) |
| `SANDBOX_HOME_MB`, `SANDBOX_WORKSPACE_MB` | `256`, `512` | tmpfs sizes of `/home/dify` and `/workspace` |
| `SANDBOX_UID`, `SANDBOX_GID` | `1000` | Owner of the tmpfs mounts (the image's `dify` user) |
| `SANDBOX_PROXY_URL`, `SANDBOX_NO_PROXY` | none, `localhost,127.0.0.1` | Proxy variables given to sandboxes |
| `SANDBOX_ADDRESS` | `name` | Sandbox URLs by container `name` (Docker DNS) or `ip` |
| `SANDBOX_STATE_FILE` | none | Known sandboxes; without it a restart sweeps every labelled container |
| `SANDBOX_START_TIMEOUT` | `60` | Seconds to wait for a healthy shellctl |

`SIGTERM` stops the service: running operations end `failed` (`internal`) and their results are stored.

## Development

```sh
dart pub get
dart analyze
dart format --set-exit-if-changed .
dart test -j 2
```

The tests are hermetic: they start the service, a scripted inner gateway, a fake supervisor and fake shellctl
daemons (`lib/src/testing/`) in-process on `127.0.0.1`, and a fake Docker Engine on a unix socket; they use no real
model or container. Test data goes to `.dart_tool/agent_service_test/`.

The real sandbox test uses this machine's Docker and the local sandbox image; it creates its own internal networks and
containers labelled `dify-sf.test=<random>` and removes them at the end:

```sh
AGENT_SANDBOX_IT=1 dart test -j 1 test/sandbox_integration_test.dart
```

## Running locally with the fake gateway

`bin/fake_gateway.dart` serves a scripted inner gateway (the script format is documented in
`lib/src/testing/scripted_gateway.dart`). For example, with a script `answer.json`:

```json
{"calls": [{"chunks": [{"text": "<think>easy</think>Hello!"},
                       {"usage": {"prompt_tokens": 3, "completion_tokens": 2}, "finish_reason": "stop"}]}]}
```

```sh
export AGENT_SERVICE_KEY=dev-key
dart run bin/fake_gateway.dart answer.json 5051 &
AGENT_DATA_DIR=./.dart_tool/dev-data AGENT_INNER_URL=http://127.0.0.1:5051 dart run bin/agent_service.dart &

curl -s -H "Authorization: Bearer $AGENT_SERVICE_KEY" -H 'X-Agent-Run-Token: dev' \
  -H 'Content-Type: application/json' localhost:5050/v1/operations -d @operation.json
curl -N -H "Authorization: Bearer $AGENT_SERVICE_KEY" localhost:5050/v1/runs/<run_id>/events
```

`operation.json` is a `POST /v1/operations` body as in the contract (`test/support.dart` builds one).

## Container image

`Dockerfile` builds both AOT binaries with `dart:3.13` and runs them as a non-root user on `debian:bookworm-slim` with
CA certificates; mount a volume at `/data`. The default entrypoint is the agent service; the supervisor uses
`--entrypoint /usr/local/bin/sandbox_supervisor`, the Docker socket and the socket's group (see the root
`docker-compose.yml`, profile `agent`).

## Layout

| Path | Contents |
|---|---|
| `lib/src/protocol.dart` | Request models, validation, canonical-JSON digest, usage |
| `lib/src/run_store.dart` | Durable run store and retention |
| `lib/src/server.dart` | HTTP routes (`dart:io`) |
| `lib/src/gateway.dart` | Inner gateway client, SSE parsing, chunk accumulation |
| `lib/src/model.dart` | Genkit model over the gateway, PromptMessage mapping |
| `lib/src/loop.dart` | One run: Genkit loop, ask_human, snapshots, terminal results |
| `lib/src/ask_human.dart` | Dify's ask_human schema, guidance and limits |
| `lib/src/output_tool.dart` | The `final_output` tool: schema checks, `$defs` inlining, pydantic-ai texts |
| `lib/src/leases.dart` | Execution leases |
| `lib/src/file_outputs.dart` | Declared file outputs: `x-dify-sf-file`, constraints, MIME types |
| `lib/src/sandbox/` | Supervisor client, per-execution sandboxes (probes, reaper, files), shellctl client, shell tools |
| `lib/src/supervisor/` | The sandbox supervisor and its Docker Engine client |
| `lib/src/testing/` | Scripted inner gateway, fake supervisor and shellctl, shared by tests and `bin/fake_gateway.dart` |
