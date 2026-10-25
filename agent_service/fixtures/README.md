# Contract fixtures (`dify-sf-agent/1`)

Recorded exchanges of the real agent service, shared by the agent service and the Swift server so that both test
against the same examples. `dify-sf-agent-1/` holds one JSON file per scenario. The contract is
[`docs/agent-v2.md`](../../docs/agent-v2.md); where a fixture and the document disagree, the document wins and the
fixture is a bug.

The files are generated, never edited by hand:

```sh
dart run tool/gen_fixtures.dart            # rewrites fixtures/dify-sf-agent-1/
```

`tool/gen_fixtures.dart` runs the real service code (`AgentService`, in process) against the scripted inner gateway
(`lib/src/testing/scripted_gateway.dart`) and, for the shell, the fake supervisor and shellctl
(`lib/src/testing/fake_sandbox.dart`). `test/fixtures_test.dart` regenerates them into a temporary directory and fails
on any difference, so a change of the service's wire behaviour shows up as a fixture diff in the same pull request. A
new protocol version gets a new directory (`dify-sf-agent-2/`); existing files are not changed in meaning.

The fake agent service (`bin/fake_agent_service.dart`, see the agent service README) can serve the runs of these
fixtures (`{"fixture": "<name>"}`), and `test/fake_agent_service_test.dart` replays every fixture against it step for
step.

## File format

```jsonc
{
  "fixture": "plain_text",
  "protocol": "dify-sf-agent/1",
  "description": "…",
  "gateway_script": {…},      // the scripted gateway's input (format: scripted_gateway.dart)
  "sandbox": null,            // or {"job_output", "workspace_files"}: what the fake shellctl held
  "steps": [                  // requests to the agent service, in order
    {"step": "start",
     "request":  {"method": "POST", "path": "/v1/operations", "query"?: {…}, "headers": {…}, "body"?: {…}},
     "response": {"status": 202, "content_type": "application/json; charset=utf-8", "body": {…}}},
    {"step": "events",
     "request":  {"method": "GET", "path": "/v1/runs/<run_id>/events", "headers": {…}},
     "response": {"status": 200, "content_type": "text/event-stream; charset=utf-8",
                  "events": [{"id": 1, "event": "run_started", "data": {…}}, …]}}
  ],
  "inner": [                  // requests the agent service sent to the inner gateway, in arrival order
    {"step": "start",         // the step after which it was sent
     "request":  {"method", "path", "query"?, "headers", "body"?},
     "response": {"status": 200, "events": [<SSE data envelopes>], "closed_by_client": false}}
  ]
}
```

- `steps[].request` is exactly what was sent, including the headers (`Authorization`, `Content-Type`,
  `X-Agent-Run-Token`, `Last-Event-ID`). An event-stream response lists the parsed events; on the wire each is
  `id: <id>\nevent: <event>\ndata: <JSON>\n\n`. A non-200 events answer has a JSON `body` instead.
- `inner[].request.headers` keeps `authorization`, `x-agent-run-token`, `content-type` and `accept`.
  `inner[].response` is the gateway's answer: `events` (the `{"code", "message", "data"}` envelopes of a model call,
  as sent; `closed_by_client` tells whether the agent service closed the stream early), a JSON `body`, or for a file
  download the bytes as text. An upload `PUT` has its bytes as text in `request.body`.
- A run's full event list is the `events` step without `query` and without `Last-Event-ID`; its terminal event's
  data equals `result` of the following `status` step.

## Placeholders and stable values

| Value | In the fixtures | Real service |
|---|---|---|
| Run IDs | `run_` + 24 hex digits counting the scenario's runs from 1 (`run_000000000000000000000001`), also inside `invocation_id` and paths | `run_` + 24 random hex digits |
| Timestamps (`expires_at`, …) | `2026-01-01T00:00:00.000Z` | the current time |
| Inner gateway base URL (signed download and upload URLs) | `http://inner-gateway.invalid` | the Swift server's URL |
| Supervisor and sandbox URLs (only if they appear in a message) | `http://sandbox-supervisor.invalid`, `http://sandbox.invalid` | internal URLs |
| Tool call IDs generated for a provider call without one | `call_` + 12 digits from 1 | `call_` + 12 random hex digits |
| Service key, run token | `fixture-service-key`, `fixture-run-token` | secrets |

Everything else is literal output of the service: messages, snapshot envelopes (`tool_definitions_digest` is the
real digest of the tool definitions), Genkit message JSON, usage, upload IDs (`up<N>`, the scripted gateway's) and
shellctl job IDs. Object keys are sorted at every level and the files are indented with two spaces, so a diff shows
only real changes; key order carries no meaning in the protocol. The generator refuses to write a fixture that
contains `127.0.0.1`, `localhost`, a local path or the user's name.

## Scenarios

| File | What it shows |
|---|---|
| `plain_text.json` | Health; a streamed text answer; events, cursor resume by `after=2` and `Last-Event-ID: 3`; status; ack; `410 cursor_expired` after the ack; the (empty) active list; DELETE |
| `operation_responses.json` | 401; `400 unsupported_protocol`, `invalid_request` (no run token), `reserved_env`; 202; the idempotent resend (200 with the result); `409 operation_conflict`; a lease of generation 2, then `409 stale_generation`; `422 snapshot_incompatible` (unknown envelope; answer to a snapshot without a pending question); `404 run_not_found`; `400 invalid_cursor`; ack; DELETE; `410 execution_deleted` for an operation and a lease |
| `declared_output_valid.json` | `final_output` with valid arguments: the candidate, no errors; the tool's schema in the model request |
| `declared_output_retry.json` | An invalid candidate (`candidate_errors` for `score`), then the `output_retry` operation `E1:1:0` with feedback and its valid candidate; the retry's model request with the full history and the feedback message |
| `ask_human_two_questions.json` | Pause `E1:q1`, answer `E1:0:1`, pause `E1:q2` with the reused provider id `ask_human:0`, answer `E1:0:2`, success; snapshots revision 1, 2, 3 |
| `reasoning_think_tag.json` | `<think>` split across chunks → `thought` events; an invalid ask_human call answered with a tool error; the second request sends the reasoning back as `<think>\n…\n</think>`; `reasoning_tokens` |
| `reasoning_content.json` | `reasoning_content` in pieces, then a pause; the answer's model request carries the assistant message's `reasoning_content` |
| `interleaved_tool_deltas.json` | Two tool calls interleaved by `index`, later deltas with the index only; the merged calls in the snapshot; `final_output` ends the turn and ask_human is not executed |
| `non_streamed_complete_chunk.json` | One complete chunk: reasoning, two tool calls without `index`, usage and finish reason |
| `image_input.json` | An image task part as `dify-sf-file:F1` with empty `base64_data`; no download request |
| `cancel_mid_stream.json` | While streaming: resend (200 `running`), status, active list, `409 run_active` ack; cancel 202; `cancelled`; the gateway stream closed by the client; `409 run_ended` for a second cancel; `409 result_mismatch` |
| `lease_expiry_cancel_lost.json` | A 1-second lease that is not renewed: `failed` `cancel_lost`; the gateway stream closed |
| `gateway_error_quota.json` | A `-429` error envelope → `failed` `model_quota` |
| `gateway_error_model.json` | A chunk, then a `-500` envelope → `failed` `model_error` |
| `gateway_http_413.json` | HTTP 413 from the gateway → `failed` `file_error` |
| `gateway_http_422_file_error.json` | A task file that is not the execution's: `422 {"error": "file_error"}` → `failed` `file_error` |
| `shell_file_output.json` | `files[]` materialized (download-request and the signed GET), `shell_run`, declared file outputs uploaded (upload-request and PUT each): top-level `report`, the array `bundle.pages` nested in an object; a missing nested file is a `candidate_errors` entry for `extra` (`extra.notes: …`) |
| `delete_cleanup_failed.json` | A shell run, then DELETE with a failing supervisor: `503 cleanup_failed`, records kept; retry 200; DELETE again 200; `410 execution_deleted` for a lease and an operation |
