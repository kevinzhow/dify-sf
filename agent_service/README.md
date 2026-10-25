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

Not yet: the shell tool and its sandbox (phase 3; `tools.shell: true` fails with `sandbox_unavailable` and health
reports `"sandbox": "disabled"`), and uploads of declared file outputs (the upload-request client exists, nothing uses
it yet).

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `AGENT_SERVICE_KEY` | required | Bearer key every request must carry; also sent on inner calls |
| `AGENT_DATA_DIR` | required | Run store root |
| `AGENT_SERVICE_PORT` | `5050` | Listening port (all interfaces) |
| `AGENT_INNER_URL` | none | Base URL of the Swift server's inner endpoints; without it runs fail and health is `degraded` |
| `AGENT_LOG_LEVEL` | `info` | `debug`, `info`, `warning` or `error` |

`SIGTERM` stops the service: running operations end `failed` (`internal`) and their results are stored.

## Development

```sh
dart pub get
dart analyze
dart format --set-exit-if-changed .
dart test -j 2
```

The tests are hermetic: they start the service and a scripted inner gateway in-process on `127.0.0.1` and use no real
model. Test data goes to `.dart_tool/agent_service_test/`.

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

`Dockerfile` builds the AOT binary with `dart:3.13` and runs it as a non-root user on `debian:bookworm-slim` with CA
certificates; mount a volume at `/data`.

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
| `lib/src/testing/` | Scripted inner gateway shared by tests and `bin/fake_gateway.dart` |
