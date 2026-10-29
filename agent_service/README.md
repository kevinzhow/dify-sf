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
  Each sandbox gets its own internal network (a /28 of `SANDBOX_SUBNET_POOL`, no host address), shared only with the
  configured agent service and proxy containers and removed with the sandbox.

- Executor profiles (`lib/src/executor_profiles.dart`): named sandbox environments from `AGENT_EXECUTOR_PROFILES`
  (image by digest, read-only binds under `/opt`, DRI render nodes, egress `none` or `allowlist`, limits, env), read
  by the service and the supervisor; `executor_profile` in operations, `GET /v1/profiles`, `profiles` in health.
  Images are built from `sandbox-images/<name>/` with `tool/build_sandbox_image.sh`.
- `view_image` (with `tools.view_image`, a dify-sf extension): the model looks at a workspace image; it stays in the
  conversation (append-only history for the provider's prompt cache), at most 16 MiB of viewed images per
  conversation (`viewImageConversationBytes`).
- `report_progress` (with `tools.report_progress`, a dify-sf extension): a preview image and caption for the people
  following the run, uploaded and announced by a `progress` event; never in the model's context.
- Near-budget submit (a dify-sf extension): when the model calls or the time left are only what finishing needs, the
  model is told to call `final_output` now; the result is marked `partial`.
- Prompt cache: every model request extends the previous one byte for byte (`model_call.prompt.prefix_stable`);
  cache hit and miss tokens in `usage` when reported. `tool/cache_probe.dart` measures them (a logging proxy for the
  provider endpoint, and a direct probe).

- `harness_style: "codex"` (`lib/src/harness/codex/`). By default (`AGENT_CODEX_RUNTIME=official`) the official
  Codex CLI runs it (`official.dart`, `official_run.dart`): the released binary (rust-v0.163.0, pinned SHA-256,
  mounted read-only at `/opt/codex` by the executor profile) runs as `codex app-server` in the run's sandbox, calls the
  model through the Swift server's Codex Responses entry with the run token (HTTP, or the Responses WebSocket with
  `model.transport: "websocket"`), and is driven over its app-server JSON-RPC protocol; one operation is one Codex
  turn. With `codex_session.retain` the workspace and the Codex thread are kept for the next round of the same node
  in the same workflow run (`retained_session.dart`). Contract: docs/agent-v2.md, "Codex runtime".
  The Dart port of the Codex harness (Apache-2.0, see `../third_party/codex/`: Codex's prompts, `exec_command`,
  `write_stdin`, `apply_patch`, `view_image`, retries; the native Responses wire or the plugin wire) runs only with
  `AGENT_CODEX_RUNTIME=port` and is no longer extended. `dart run tool/gen_codex_vendor.dart` regenerates its
  vendored texts. Contract: docs/agent-v2.md, "Harness styles".

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
| `AGENT_EXECUTOR_PROFILES` | `/etc/dify-sf/executor-profiles.json` | The executor profile file (docs/agent-v2.md, "Executor profiles"); without a file at the default path only the implicit `default`. A file that does not validate stops the process (exit 64) |
| `AGENT_CODEX_RUNTIME` | `official` | What runs `harness_style: codex`: `official` (the Codex binary in the sandbox) or `port` (the Dart port) |
| `AGENT_CODEX_GATEWAY_URL` | none | The Codex Responses entry as sandboxes reach it, used when the supervisor's grant has none (local tests) |

The supervisor (`sandbox_supervisor`) reads:

| Variable | Default | Meaning |
|---|---|---|
| `SANDBOX_SUPERVISOR_KEY` | required | Bearer key of its API |
| `SANDBOX_AGENT_PEERS` | required | Comma-separated agent service container(s) attached to every sandbox network |
| `SANDBOX_PROXY_PEER` | none | The proxy container, attached at `.2` of every sandbox network; sandboxes get `HTTP(S)_PROXY=http://<.2>:SANDBOX_PROXY_PORT`. Without it sandboxes have no egress |
| `SANDBOX_PROXY_PORT` | `3128` | The proxy's port |
| `SANDBOX_COMPOSE_PROJECT` | none | Peers are compose service names of this project (labels `com.docker.compose.project`/`service`); without it, container names |
| `SANDBOX_SUBNET_POOL` | `10.213.0.0/16` | Split into one /28 per sandbox network; subnets of existing Docker networks are skipped. Must lie in 10/8, 172.16/12, 192.168/16 or 100.64/10 (refused by the proxy) and must not overlap host routes |
| `SANDBOX_SUPERVISOR_PORT` | `5060` | Listening port |
| `DOCKER_SOCKET` | `/var/run/docker.sock` | Docker Engine API socket (API v1.44) |
| `SANDBOX_IMAGE` | `langgenius/dify-agent-local-sandbox:1.17.1` | Sandbox image of the implicit `default` profile (must be present; never pulled) |
| `AGENT_EXECUTOR_PROFILES` | `/etc/dify-sf/executor-profiles.json` | The same profile file as the service's: each profile's image, binds, render nodes, egress and limits (missing limits: the `SANDBOX_*` values). With render nodes, bind `/dev/dri` read-only into the supervisor container (it reads the nodes' group and sysfs directory) |
| `SANDBOX_LABEL` | `dify-sf.agent-sandbox=1` | `key=value` on every sandbox and sandbox network; only objects with it and the execution label are listed, swept or removed |
| `SANDBOX_NAME_PREFIX` | `dify-sf-sandbox-` | Container and network names: prefix + 24 hex of SHA-256(execution key) |
| `SANDBOX_MEMORY_MB`, `SANDBOX_CPUS`, `SANDBOX_PIDS_LIMIT` | `1024`, `1`, `256` | Limits (memory includes the tmpfs) |
| `SANDBOX_HOME_MB`, `SANDBOX_WORKSPACE_MB` | `256`, `512` | tmpfs sizes of `/home/dify` and `/workspace` |
| `SANDBOX_UID`, `SANDBOX_GID` | `1000` | Owner of the tmpfs mounts (the image's `dify` user) |
| `SANDBOX_NO_PROXY` | `localhost,127.0.0.1` | `NO_PROXY` given to sandboxes |
| `SANDBOX_ADDRESS` | `name` | Sandbox URLs by container `name` (Docker DNS on the sandbox network) or `ip` |
| `SANDBOX_STATE_FILE` | none | Known sandboxes; without it a restart sweeps every labelled container and network |
| `SANDBOX_START_TIMEOUT` | `60` | Seconds to wait for a healthy shellctl |
| `SANDBOX_DISK_ROOT` | none | Disk workspaces (profiles with `workspace.backing: disk`; docs/agent-v2.md, "Disk workspaces"): the dedicated directory as the supervisor sees it (must exist as a real directory, mode 0700, owned by its user). Without it disk profiles stop the process |
| `SANDBOX_DISK_HOST_ROOT` | required with the root | The same directory on the Docker host (bind source of the helper) |
| `SANDBOX_DISK_TOOL_IMAGE` | required with the root | Helper image pinned by digest, with `python3`, `mke2fs` and `debugfs` (never pulled) |
| `SANDBOX_DISK_LOOP_DEVICES` | required with the root | Comma-separated `/dev/loopN` the supervisor may bind; one active disk execution per device |
| `SANDBOX_DISK_BUDGET_MB` | required with the root | Sum of all workspace images |
| `SANDBOX_DISK_MIN_FREE_MB` | `1024` | Free space that must remain on the root's filesystem after a new image |

`SIGTERM` stops the service: running operations end `failed` (`internal`) and their results are stored.

Both binaries accept `--healthcheck`: `GET /v1/health` on their own port with their own key, exit 0 on HTTP 200 (the
compose health checks; the image has no curl). The supervisor answers 200 only while the Docker socket answers.

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

The real sandbox test uses this machine's Docker and the local images `langgenius/dify-agent-local-sandbox:1.17.1`,
`dart:3.13` and `ubuntu/squid:latest` (never pulled). The host has no address on sandbox networks, so a relay container
(`test/it_relay.dart`, published on 127.0.0.1) is the agent peer and forwards the test's shellctl requests; a Squid
container with the repository's configuration is the proxy peer. Sandbox networks come from `AGENT_SANDBOX_IT_POOL`
(default `10.213.0.0/16`), the relay's network from `AGENT_SANDBOX_IT_RELAY_POOL` (default `10.214.0.0/16`). Everything
is labelled `dify-sf.test=<random>` and removed at the end:

```sh
AGENT_SANDBOX_IT=1 dart test -j 1 test/sandbox_integration_test.dart
```

## Compose smoke test

`tool/compose_smoke.sh` brings up `agent_service`, `sandbox_supervisor` and `agent_sandbox_proxy` from the root
`docker-compose.yml` under a random project name, with a scripted fake inner gateway compiled into a throwaway image,
and drives one operation through the HTTP API: the model runs `shell_run` (a workspace file, direct egress, `curl` and
`pip download` through the proxy, a refused domain) and `final_output`; then events, status, ack and
`DELETE /v1/executions/{id}`. It checks the sandbox network (internal, `inhibit_ipv4`, exactly the sandbox, the agent
service and the proxy), the owner of `/data`, and that the sandbox container and network are gone afterwards.

```sh
# SUBNET: a free private /28 for the project's default network (Docker's default pools may be exhausted);
# SANDBOX_POOL (optional, default 10.213.0.0/16): the supervisor's pool.
agent_service/tool/compose_smoke.sh 10.212.7.0/28 [10.213.0.0/16]
```

It needs the local images `dify-sf-agent-service:dev` (`docker build -t dify-sf-agent-service:dev agent_service`; or
`SMOKE_IMAGE`), the sandbox image, `ubuntu/squid:latest`, `dart:3.13` and `debian:bookworm-slim`, and network access for
the proxy checks (pypi.org). Everything it creates (containers, networks, volumes, the gateway image, sandboxes) carries
`dify-sf.test=<random>` and is removed on exit, also on failure; the last lines list what is left (must be none).
`SMOKE_KEEP_LOGS=DIR` keeps the compose logs.

## Running locally with the fake gateway

`bin/fake_gateway.dart` serves a scripted inner gateway (the script format is documented in
`lib/src/testing/scripted_gateway.dart`). For example, with a script `answer.json`:

```json
{"calls": [{"chunks": [{"text": "<think>easy</think>Hello!"},
                       {"usage": {"prompt_tokens": 3, "completion_tokens": 2}, "finish_reason": "stop"}]}]}
```

```sh
export AGENT_SERVICE_KEY=dev-key
dart run bin/fake_gateway.dart answer.json 5051 &   # [PORT [ADDRESS]], ADDRESS defaults to 127.0.0.1
AGENT_DATA_DIR=./.dart_tool/dev-data AGENT_INNER_URL=http://127.0.0.1:5051 dart run bin/agent_service.dart &

curl -s -H "Authorization: Bearer $AGENT_SERVICE_KEY" -H 'X-Agent-Run-Token: dev' \
  -H 'Content-Type: application/json' localhost:5050/v1/operations -d @operation.json
curl -N -H "Authorization: Bearer $AGENT_SERVICE_KEY" localhost:5050/v1/runs/<run_id>/events
```

`operation.json` is a `POST /v1/operations` body as in the contract (`test/support.dart` builds one).

## Contract fixtures

`fixtures/dify-sf-agent-1/` holds recorded exchanges of this service for each scenario of the contract (requests,
responses, event lists, and every inner-gateway request with the gateway's answer). They are generated by
`dart run tool/gen_fixtures.dart` and checked for drift by `test/fixtures_test.dart`; the format, the placeholders
and the scenario list are in [`fixtures/README.md`](fixtures/README.md).

## Executor profile images and the end-to-end test

```sh
# build, tag dify-sf/sandbox-colvalley-blender:<VERSION>, print the digest reference for the profile file
agent_service/tool/build_sandbox_image.sh colvalley-blender --build-context blender=DIR   # DIR: blender-5.2.3-linux-x64.tar.xz
```

`tool/profile_e2e.sh SUBNET CHECKOUT BLEND [POOL]` runs the profile `colvalley-blender` end to end with Docker: a
profile file with `default` and `colvalley-blender` (CHECKOUT, a colvalley-3d checkout made by its
`tools/board/prepare_checkout.sh`, bound read-only at `/opt/colvalley-3d`; the render node), the compose services
with the file mounted, a scripted model (`shell_run` of `render_board.sh` on the BLEND input file, `view_image` of the
board, `final_output` with the board as a declared file output). It checks the run, the sandbox container (image,
read-only checkout, render node and group, limits, no proxy, its network) and the cleanup, and prints the sandbox's
peak memory and CPU from its cgroup. Everything carries `dify-sf.test=<random>` and is removed. It needs the local
images `dart:3.13`, `debian:bookworm-slim`, `ubuntu/squid:latest`, the sandbox images and the render node.

## Fake agent service (for the Swift server's tests)

`bin/fake_agent_service.dart` (`lib/src/testing/fake_agent_service.dart`) speaks the same HTTP API with scripted runs
and fault injection. Validation (`OperationRequest.parse`), idempotency by digest, generations, leases, ack, cursor
expiry after ack and DELETE tombstones work as in the real service; it runs no model and needs no inner gateway.

```sh
dart run bin/fake_agent_service.dart --port 0 --key test-key \
  [--script script.json] [--fixtures fixtures/dify-sf-agent-1] [--address 127.0.0.1]
# stdout: {"port": 41234}   (the first line, once listening; --port 0 picks a free port)
```

`--key` defaults to `AGENT_SERVICE_KEY`, `--port` to 5050. For a test suite, compile it once
(`dart compile exe bin/fake_agent_service.dart -o fake_agent_service`), start it with `--port 0`, read the port from
the first stdout line, and switch scenarios with `PUT /_fake/script` (the script as body; clears all state).
`GET /_fake/requests` lists the requests it received with their answered status (`"connection_reset"` for a lost
response). Both need the bearer key.

Without a script every operation succeeds with `{"text": "Hello from the fake agent service."}` and a snapshot built
from the request (accepted again as a continuation). A script chooses per `operation_id` (or `default`):

| Option | Effect |
|---|---|
| `"fixture": "<name>"` (`"fixture_operation_id"`) | Emit that fixture run's events; its run ID too |
| `"events"`, `"result"` | Emit these events, ending with any terminal result (`{run_id}`, `{operation_id}`, `{execution_id}` substituted) |
| `"start_delay_ms"`, `"event_delay_ms"` | Pace the events |
| `"hold": true` | Stay `running` after the events, until cancel, DELETE or lease expiry (`failed` `cancel_lost`) |
| `"on_cancel": {"event", "data", "delay_ms"}` or `{"result": true, "delay_ms"}` | Cancel answers 202, then a late terminal result instead of `cancelled` |
| `"drop_stream_after": N`, `"drop_stream_times": K` | Reset the first K event streams after N events (no terminal event) |
| `"duplicate_terminal": true` | Write the terminal event twice |
| `"expire_cursors": true` | Once ended, any cursor before the end answers `410 cursor_expired` |
| `"lose_post_response": N` | Accept, then reset the connection without an answer, N times; the resend answers 200 |
| `"reject": {"status", "error", "message", "extra", "times"}` | Answer `POST /v1/operations` with that error (e.g. 409, 422, 400) |
| `"delays_ms": {"post", "status", "events", "ack", "cancel"}` | Delay those answers (also top-level defaults, and `lease`, `delete`) |

Per `execution_id` (or `default_execution`): `"delete_failures": N` answers N DELETEs with `503 cleanup_failed`
before the 200. Top level: `"snapshot_check"`: `"envelope"` (default: envelope, Genkit major and config snapshot),
`"full"` (the real check) or `"none"`; `"health"` overrides `GET /v1/health`. The full format is the doc comment of
`lib/src/testing/fake_agent_service.dart`. Example: the two-question flow of the fixtures, the first answer's POST
response lost, the second answer's stream dropped once after two events:

```json
{"operations": {
  "E1:0:0": {"fixture": "ask_human_two_questions"},
  "E1:0:1": {"fixture": "ask_human_two_questions", "lose_post_response": 1},
  "E1:0:2": {"fixture": "ask_human_two_questions", "drop_stream_after": 2}}}
```

## Container image

`Dockerfile` builds both AOT binaries with `dart:3.13` and runs them as a non-root user on `debian:bookworm-slim` with
CA certificates; mount a volume at `/data`. The default entrypoint is the agent service; the supervisor uses
`--entrypoint /usr/local/bin/sandbox_supervisor`, the Docker socket and the socket's group (see the root
`docker-compose.yml`, profile `agent`). The user and group are both 10001; `/data` is `0700` and owned by them, so a
bind-mounted host directory must be writable by uid 10001.

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
| `lib/src/testing/` | Scripted inner gateway, fake supervisor and shellctl, fake agent service; shared by tests, `bin/fake_gateway.dart` and `bin/fake_agent_service.dart` |
| `fixtures/dify-sf-agent-1/` | Contract fixtures (generated by `tool/gen_fixtures.dart`) |
| `tool/compose_smoke.sh` | The compose smoke test |
| `tool/gen_fixtures.dart` | The fixture generator |
| `test/it_relay.dart` | The integration test's relay into sandbox networks |
