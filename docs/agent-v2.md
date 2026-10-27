# Agent v2 (inline agent)

Status: approved for the first phase; implementation in progress. This document is the contract between the Swift
server and the agent service. A change to either side that affects the contract changes this document in the same pull
request.

Reference: Dify 1.17.1 (`8387590`). Dify runs Agent v2 as three parts: the API (node, bindings, publishing, human input),
`agent_backend` (the agent loop, Python and pydantic-ai) and `local_sandbox` (a Go `shellctl` daemon with Landlock).
dify-sf keeps the split without Python:

| Dify 1.17.1 | dify-sf |
|---|---|
| API: Agent v2 node, Soul config and bindings, human-input pause | Swift server |
| `agent_backend` (pydantic-ai loop) | `agent_service/`: Dart with Genkit Dart 1.0.1, one AOT binary |
| `local_sandbox` (`langgenius/dify-agent-local-sandbox:1.17.1`) | the same image (phase 3, see [Sandbox](#sandbox)) |
| Inner gateway `/inner/api/agent/llm/invoke`, file requests | Swift inner endpoints for the agent service |

Model selection is unchanged from Dify: an agent uses the workspace's model providers, filtered by Dify's agent
compatibility list (matched against the model's `label.en_US`, as in Dify). A local model gateway is an ordinary
OpenAI-compatible provider. The agent service never holds model credentials; every model call goes back through the
Swift server, which resolves credentials, checks the caller and records usage.

Work runs on the server. Closing the browser or locking the phone does not stop or pause a run; reopening reads the
server's state.

## Scope of the first phase

In scope:

- Inline agents (`agent_binding.binding_type: inline_agent`) in workflows: model, prompt, files, environment
  variables, the human question tool and (phase 3) the shell tool.
- `agent_task` with upstream variable references and image inputs.
- Declared outputs (string, number, boolean, object, array, file) with Dify's per-output failure strategies.
- Human questions through human-input forms. A run can ask several questions in sequence; each question pauses the
  workflow and resumes the original pending tool call.
- Stop, cleanup, run records, publishing, DSL import/export, editor checklist and the native MCP checklist.

Out of scope: roster agents and the Agents pages, the agent configuration page, Build mode, skills, Dify tools and
knowledge bases inside an agent, CLI tool installation entries, Agent v2 in Chatflow, model-checked file outputs, cloud
quota plans. Agent v1 nodes, roster bindings and Chatflow agents are rejected explicitly, never run partially.

## Delivery phases

| Phase | Agent service | Swift server and client | Exit |
|---|---|---|---|
| 1 Contract and model bridge | Versioned protocol, Genkit model over the inner gateway, scripted provider | Run-context authentication, full message and stream mapping, usage, cancel propagation | Multi-turn tools, interleaved tool deltas, images, reasoning, cancel and errors through Swift and the plugin daemon |
| 2 One node end to end | Idempotent operations, status queries, session envelope, output candidates | Private config and bindings, version pinning, per-output strategies, final states and stop | Published runs, fail branch, default values and run records |
| 3 Questions and shell | Resume of the original tool call, kept workspaces, sandbox boundary | Several forms per execution, claimed decisions, atomic pause, file receipt, failure cleanup | Two questions, process restarts, repeated requests and answers, parallel executions |
| 4 Editing and delivery | Protocol fixtures, fault injection | Design-system panel, collaboration, DSL, editor and MCP checks, features and Dify comparison | The same config edits, publishes, checks, imports, exports and runs |

Both sides work in parallel against this contract in every phase.

## Components

```
browser / app ──▶ Swift server
                   │  AgentV2Node ──HTTP, internal network, service key──▶ agent service (Dart, Genkit)
                   │                                                         │  models: inner gateway llm/invoke
                   │  inner endpoints ◀───────────────────────────────────────┘  files:  inner file requests
                   │                                                            shell:  sandbox (phase 3)
                   └─ model providers → plugin daemon → model plugin → vendor API or local gateway
```

- The browser never calls the agent service.
- The agent service reaches only the Swift inner endpoints and, in phase 3, its sandboxes.

## Identities

| Identity | Meaning | Owner |
|---|---|---|
| Execution | `tenant_id`, `app_id`, `workflow_run_id`, `node_id`, `execution_id` (the engine's ID; every iteration or loop round has its own), plus the pinned `agent_config_snapshot_id` | Swift |
| Generation | Increases every time the Swift server (re)claims ownership of an execution, e.g. after a restart. A request or result of an older generation is rejected. | Swift |
| Operation | One call into the agent loop: the first run, each resume after an answer, each output retry. `operation_id = <execution_id>:<output_attempt>:<resume_sequence>` | Swift |
| Run | The agent service's record of one operation (`run_id`) | agent service |
| Model call | One model request inside a run: `invocation_id = <run_id>:<call_index>`, `call_index` from 1 | agent service |

`resume_sequence` counts answered questions (0 for the first run). `output_attempt` counts declared-output retries
(0 for the first run). Provider tool call IDs are kept unchanged but are not unique keys: kimi, for example, reuses
`ask_human:0` in different turns. Questions are identified by `resume_sequence` and the snapshot revision.

## Agent service protocol

Protocol name and version: `dify-sf-agent/1`, sent as `"protocol"` in every request and response body. A request with an
unknown version is rejected with `400 unsupported_protocol`. This protocol is a dify-sf design; its run lifecycle follows
Dify's `agent_backend` (`create run`, event stream, cancel, session snapshot), but its events and fields are not
Dify's wire format.

Authentication: `Authorization: Bearer <COLLAB_AGENT_SERVICE_KEY>`. JSON, UTF-8. Request bodies are at most 8 MiB.
Errors answer `{"protocol", "error": "<code>", "message", …}` with the status and code named below.

### `POST /v1/operations`

Starts one operation. Every operation is a separate request; there is no separate resume route.

```jsonc
{
  "protocol": "dify-sf-agent/1",
  "operation_id": "<execution_id>:<output_attempt>:<resume_sequence>",
  "generation": 3,
  "execution": {"tenant_id": "…", "app_id": "…", "workflow_run_id": "…", "node_id": "…", "execution_id": "…",
                "agent_config_snapshot_id": "…", "user_id": "…", "user_from": "account", "invoke_from": "debugger"},
  "model": {"provider": "langgenius/openai_api_compatible/openai_api_compatible", "name": "…",
            "parameters": {"temperature": 0.7}},
  "system_prompt": "…",
  "task": [{"type": "text", "text": "…"},
           {"type": "file", "file_id": "…", "mime_type": "image/png"}],
  "output_schema": null,
    "tools": {"ask_human": true, "shell": false, "view_image": false},
  "env": {"KEY": "value"},
  "files": [{"file_id": "…", "path": "files/spec.md"}],
  "limits": {"max_turns": 50, "timeout_seconds": 1800},
  "executor_profile": "default",
  "continuation": null
}
```

- `output_schema`: JSON Schema of the declared outputs plus `text`, or `null` when none are declared. As in Dify it
  must be an object schema whose `$ref`s are local `#/$defs/…` (`400 invalid_request` otherwise); its top-level
  `description` becomes the `final_output` tool description.
- `tools.ask_human` is derived by the Swift server from the inline agent's `human.contacts` (Dify's Soul config:
  questions are enabled only when contacts are configured). The agent service treats it as a plain flag; form
  delivery and recipients stay entirely in the Swift server. `tools.shell: true` gives the model Dify's shell tools
  (`shell_run`, `shell_wait`, `shell_input`, `shell_interrupt`: Dify's arguments, defaults, prompt and output text) and
  requires them: without an isolated sandbox the run fails with `sandbox_unavailable`. There is no optional shell.
  `tools.view_image: true` (a dify-sf extension, see [Viewing workspace images](#viewing-workspace-images)) adds the
  `view_image` tool and requires `tools.shell` (`400 invalid_request` otherwise). The Swift server sets it when the
  shell is on and the node's model declares the `vision` feature; it is not a Soul key.
- The `X-Agent-Run-Token` header is required for a new operation (`400 invalid_request` otherwise). The service keeps
  it in memory only.
- Files are referenced by stable `file_id`; snapshots and model requests never contain URLs. Model inputs carry
  `dify-sf-file:<file_id>` (see the inner gateway); only components that need the bytes (the sandbox) ask for a fresh
  signed URL. `files[].path` is relative to the workspace (`..`, absolute paths outside `/workspace` and repeats are
  `400 invalid_request`); a new sandbox gets each file at `/workspace/<path>`.
- `env` reaches only the sandbox environment and never a prompt. Reserved names (`HOME`, `PATH`, `TMPDIR`, `TMP`,
  `TEMP`, every `SHELLCTL_*`, `*_PROXY` and `NO_PROXY` in either case) are rejected with `400 reserved_env`, and
  refused again by the sandbox layer.
- `executor_profile` names the sandbox's executor profile (see [Executor profiles](#executor-profiles)); absent
  means `default`. It must match `^[a-z0-9][a-z0-9-]{0,63}$` (`400 invalid_request`, also for `""`: the Swift
  server sends the Soul's `""` as `default` or omits the field).
- Top-level fields other than the ones above are `400 invalid_request` ("unknown request fields: …").
- `continuation` is `null` for the first run. Otherwise it is one of:
  - `{"kind": "answer", "snapshot": <envelope>, "question_id": "…", "result": <ask_human result>}` after a question.
  - `{"kind": "output_retry", "snapshot": <envelope>, "feedback": [{"field": "score", "error": "…"}]}` after the Swift
    server decided to retry declared outputs.
  - `continuation` is `null` exactly when `operation_id` ends in `:0:0`. An answer's snapshot has the previous
    `resume_sequence` and the same `output_attempt`; an output retry's snapshot has the previous `output_attempt`, the
    same `resume_sequence` and no `pending`. Anything else is `422 snapshot_incompatible`.

Responses:

| Case | Status | Body |
|---|---|---|
| New operation accepted | `202` | `{"protocol", "run_id", "status": "running"}` |
| Same `operation_id`, same request digest | `200` | the existing run's status (see `GET`); nothing runs again |
| Same `operation_id`, different digest | `409 operation_conflict` | `{"run_id"}` |
| `generation` older than one already seen for the execution | `409 stale_generation` | |
| Snapshot of an unknown envelope version or a different config snapshot | `422 snapshot_incompatible` | |
| Execution already deleted (`DELETE /v1/executions/{id}`) | `410 execution_deleted` | |

The request digest is SHA-256 of the canonical JSON request without `generation`.

### Example requests

First run (`operation_id` `E1:0:0`, `continuation: null`). A network resend of the same body returns `200` with the
same `run_id`. The agent asks a question; the run ends `paused` with snapshot revision 1.

Answer (`operation_id` `E1:0:1`):

```jsonc
{"protocol": "dify-sf-agent/1", "operation_id": "E1:0:1", "generation": 3, "execution": {…}, "model": {…},
 "system_prompt": "…", "task": […], "output_schema": {…}, "tools": {…}, "env": {…}, "files": […], "limits": {…},
 "continuation": {"kind": "answer", "question_id": "E1:q1", "snapshot": {"revision": 1, …},
                  "result": {"status": "submitted", "action": {"id": "submit", "label": "Submit"},
                             "values": {"city": "Kyoto"}, "rendered_content": "…"}}}
```

Output retry after that run returned an invalid candidate (`operation_id` `E1:1:1`):

```jsonc
{"protocol": "dify-sf-agent/1", "operation_id": "E1:1:1", "generation": 3, "execution": {…}, …,
 "continuation": {"kind": "output_retry", "snapshot": {"revision": 2, …},
                  "feedback": [{"field": "score", "error": "expected number, got string"}]}}
```

### `GET /v1/runs/{run_id}`

```jsonc
{"protocol": "dify-sf-agent/1", "run_id": "…", "operation_id": "…", "status": "running",
 "last_event_id": 41, "result": null, "acknowledged": false}
```

`status` is `running`, `succeeded`, `paused`, `failed` or `cancelled`. Once final, `result` holds the terminal event's
data. The Swift server uses this after any lost connection before deciding anything; a lost connection never causes
a resend of a different operation.

### `GET /v1/runs/{run_id}/events?after=<event_id>`

Server-sent events with increasing integer `id`. `Last-Event-ID` and `after` are equivalent. Events are kept until the
run is acknowledged or 24 hours after it ended. A cursor older than the kept events returns `410 cursor_expired`; the
Swift server then reads `GET /v1/runs/{run_id}`.

| `event` | `data` |
|---|---|
| `run_started` | `{"model", "call_index_base", "executor_profile"}`; `call_index_base` is 0 (call indexes of the run start at 1); `executor_profile` is the resolved profile name |
| `thought` | `{"text"}`: reasoning of the model; never part of the answer. One per model call, written when the call ends (also when it is cancelled); reasoning longer than 16 KiB of UTF-8 is split into several, cut only between code points |
| `tool_call` | `{"id", "name", "phase": "started" \| "finished", "input"?, "output"?, "error"?}`; `id` is the provider's ID |
| `model_call` | `{"invocation_id", "usage"}` after each model call |
| `succeeded` | `{"candidate": {…}, "candidate_errors": […], "snapshot": <envelope>, "usage"}` |
| `paused` | `{"question_id", "tool_call_id", "question": <ask_human args>, "snapshot": <envelope>, "usage"}` |
| `failed` | `{"error_type", "message", "usage", "snapshot"?}` |
| `cancelled` | `{"usage", "snapshot"?}` |

Exactly one terminal event (`succeeded`, `paused`, `failed`, `cancelled`) per run, after which the stream ends. Its
data is also stored as the run's `result`. A terminal result is written to the service's run store before it is
streamed.

- `candidate` is the arguments of the model's `final_output` call (declared outputs with `text`); without declared
  outputs it is `{"text"}` from the final answer. `candidate_errors` lists JSON Schema violations per field as
  `{"field", "error"}` (`field` is the top-level property; `""` for the whole output). With declared outputs, a final
  answer that does not call `final_output` gives `candidate: null` and one error with `field: ""`. The agent service does not retry, default or branch on declared outputs; the Swift server decides
  (see [Declared outputs](#declared-outputs)).
- `usage` is summed over the run's model calls: `{"prompt_tokens", "completion_tokens", "total_tokens",
  "reasoning_tokens"}`. `reasoning_tokens` is `null` when the provider does not report it; it is a detail of
  `completion_tokens` when the provider counts it there, never added a second time.
- `error_type`: `model_error`, `model_quota`, `max_turns`, `timeout`, `ask_human_invalid`, `sandbox_unavailable`,
  `sandbox_error`, `file_error`, `cancel_lost`, `internal`.
- `paused`: `question_id` is `<execution_id>:q<resume_sequence + 1>`; `question` is the normalized ask_human arguments
  (Dify's default `Submit` action added when the model gave none).
- A run that was in flight when the service process ended is recorded as `failed` (`internal`), on a graceful stop or
  at the next start; it is never replayed.

### `POST /v1/runs/{run_id}/ack`

`{"protocol", "generation", "result_event_id"}`. The Swift server calls it after it has committed the terminal result
(and, for `paused`, the snapshot, form and workflow pause) in one transaction. Until then the run keeps its workspace
and result. Idempotent. An acknowledged run's events are no longer kept (its status and result are). A run that has
not ended answers `409 run_active`; a `result_event_id` that is not the terminal event answers `409 result_mismatch`.

### `POST /v1/runs/{run_id}/cancel`

`{"protocol", "generation"}`. Stops the model call in flight and the tool in flight, terminates the run's sandbox jobs
and kills the processes they left in the sandbox container (see [Sandbox](#sandbox)), then ends the run with
`cancelled`. Returns `202`; a run that already ended returns `409` with its
`result`. If the result of a cancelled run arrives late, the first committed terminal result in the Swift server wins.

### `POST /v1/executions/{execution_id}/lease`

`{"protocol", "generation", "ttl_seconds": 120}`. The Swift server renews the lease of every execution it is running or
has paused. If a running operation's lease expires, the service cancels it (`cancel_lost`). Paused executions only
hold kept files and workspaces, which expire with the human-input form's global deadline. When a lease expires, the
execution's sandbox is also released. Observing events is not a lease.

### `DELETE /v1/executions/{execution_id}`

`{"protocol", "generation"}`. Removes everything kept for the execution: its sandbox (workspace and home, through the
supervisor) and run records. The service derives every path and sandbox from its own records; nothing in the request
is used as a path. Idempotent. Running operations of the execution are cancelled first. If the supervisor fails, the
answer is `503 cleanup_failed`, the records stay and the Swift server retries. A tombstone remains, so a late operation or lease for it answers
`410 execution_deleted`. The Swift server calls
it once the execution's node reaches a final state, after output files were received.

### `GET /v1/runs?state=active`

Lists running and unacknowledged runs with their `operation_id`, `generation` and the identity of the execution they
were started for (`tenant_id`, `app_id`, `workflow_run_id`, `node_id`, `execution_id`). The Swift server uses it on
start-up to reconcile: it cancels or adopts every operation left from before its restart and writes a final state for it.
A Swift server touches only runs whose identity matches an execution in its own database; one agent service may serve
several. Runs recorded before the identity was kept list it as `null`.

### `GET /v1/health`

`{"protocol", "status": "ok" | "degraded", "sandbox": "isolated" | "unavailable" | "disabled", "version",
"profiles": {"<name>": <status>}}`. `sandbox` is `disabled` without a supervisor, `unavailable` after the latest probe
or supervisor call failed, else `isolated`. `profiles` holds each executor profile's status as in `GET /v1/profiles`.

### Other responses

Fixed while generating the fixtures (they record these exact bodies):

| Request | Answer |
|---|---|
| any, missing or wrong service key | `401 unauthorized` |
| unknown `run_id` | `404 run_not_found` |
| `events` with a malformed `after` / `Last-Event-ID` | `400 invalid_cursor` |
| `events` after ack | a cursor at the end answers `200` with no events; an older cursor `410 cursor_expired` |
| `POST /v1/operations` with an older generation | `409 stale_generation` with the current `generation` |
| `cancel` accepted | `202 {"protocol", "run_id", "status"}` |
| `lease` | `200 {"protocol", "expires_at"}` |
| `DELETE /v1/executions/{id}` | `200 {"protocol", "execution_id", "deleted": true}`; `503 cleanup_failed` to retry |
| `GET /v1/runs?state=active` | each run: `run_id`, `operation_id`, `execution_id`, `tenant_id`, `app_id`, `workflow_run_id`, `node_id`, `generation`, `status`, `acknowledged`, `last_event_id` |

`usage` of a `cancelled` or `cancel_lost` run counts only the model calls that finished; the gateway's own records are
authoritative for billing. Such runs carry no snapshot. An `answer` continuation needs only `result.status`;
`action`, `values` and `rendered_content` are present when the status is `submitted` (Dify's `AskHumanToolResult`).
For a gateway `413` only the status matters; its body is not read.

### Failure contract

| Situation | Behaviour |
|---|---|
| Browser closed, phone locked, no UI subscription | The run continues; reopening reads the server's state |
| Swift → agent event connection drops | The Swift server reads `GET /v1/runs/{id}` and resubscribes with its cursor; it never starts the operation again |
| Agent service process dies during a run | The run is lost. The Swift server's lease or status check finds it missing; the node fails with `internal`. Nothing is replayed from the old conversation, because shell commands and model calls may have side effects |
| Agent service restarts while an execution is paused | Nothing is lost: the committed snapshot is in the Swift database and kept files are on disk |
| Swift server restarts | On start-up it lists active runs, cancels or adopts them under a new generation and commits a final state for each |
| Stop races success | The first terminal result committed in the Swift server wins; a later result for the same execution generation is discarded |
| Transport failure, lost executor | Treated as a node error (the node's general error handling), never as a declared-output retry |

### Fixtures

[`agent_service/fixtures/dify-sf-agent-1/`](../agent_service/fixtures/README.md) holds one recorded scenario per file
of this protocol: every request and response, the full event lists, the run status, ack, cancel, lease and DELETE, and
every inner-gateway request with the gateway's answer (plain text, declared outputs and output retry, two questions,
both reasoning forms, interleaved and non-streamed tool calls, images, idempotency and the 4xx answers, cancel, lease
expiry, gateway errors, the shell with file outputs, failed cleanup). They are generated from the agent service's own
code against the scripted gateway; a change that alters them changes this document or is a bug. Volatile values (run
IDs, timestamps, URLs) are fixed placeholders described there. The fake agent service
(`agent_service/bin/fake_agent_service.dart`) serves the same API with scripted runs, including the fixtures' runs, and
fault injection (dropped streams, duplicate or late terminal events, lost POST responses, expired cursors, scripted
409/422/400 answers, failing DELETEs, delays) for the Swift server's tests.

## Session envelope

The snapshot passed back in `continuation` is a versioned envelope, not a bare Genkit history:

```jsonc
{"envelope": "dify-sf-agent-session/1", "revision": 2, "genkit": "1.0.1",
 "agent_config_snapshot_id": "…", "tool_definitions_digest": "…", "model": {"provider": "…", "name": "…", "parameters": {…}},
 "output_attempt": 0, "resume_sequence": 1,
 "pending": {"question_id": "E1:q2", "tool_call_id": "ask_human:0"},
  "file_ids": ["…"], "workspace_ref": "<sandbox_id> | null", "executor_profile": "default",
 "messages": [ /* Genkit Message JSON */ ]}
```

A snapshot whose envelope, Genkit major version, config snapshot or tool definitions differ from the request is
rejected (`422 snapshot_incompatible`), never resumed with a different configuration. `workspace_ref` is the
execution's sandbox (null until the shell is used); a resume whose sandbox was replaced fails with `sandbox_error`.
`executor_profile` is the operation's profile; a snapshot without it (taken before profiles) counts as `default`. A
continuation with the shell and a `workspace_ref` whose profile differs from the request's is `422
snapshot_incompatible`.

## Agent loop

Genkit Dart supplies the tool loop, streaming, interrupts and image input. The service adds:

| Concern | Behaviour |
|---|---|
| Model | A Genkit model that calls the inner gateway `POST /inner/agent/llm/invoke` with the run's execution and a fresh `invocation_id`. It holds a per-run HTTP client. |
| Reasoning | Reasoning arrives as `<think>…</think>` inside the content (Dify's convention for model plugins) or as `delta.message.reasoning_content`. It becomes `thought` events and is kept out of the answer text and the candidate. It stays in the session history as reasoning and is sent back on later calls and resumes the way it arrived for that call: `<think>\n…\n</think>` before the assistant content, or the assistant message's `reasoning_content`. |
| Declared outputs | As in Dify (pydantic-ai `ToolOutput`), the schema is exposed as the tool `final_output` (local `$defs` inlined, title `final_output`); there are no prompt instructions and no `response_format`. The tool is never executed: the first `final_output` call of a turn ends the run `succeeded` with its arguments as the candidate, checked against the schema for per-field errors. As with pydantic-ai's default `end_strategy='early'`, no other call of that turn is executed; the history answers them with pydantic-ai's texts (`Final result processed.`, `Output tool not used - a final result was already processed.`, `Tool not executed - a final result was already processed.`). No retries here. |
| Human question | Tool `ask_human` (Dify's arguments: `title`, `question`, `markdown`, `fields`, `actions`, `urgency`, with Dify's limits) returns a Genkit interrupt. Arguments outside the schema or limits go back to the model as a tool error, as Dify's `ModelRetry` does. The run ends `paused`. A resume answers the same tool call with Dify's tool result (`status`, `action`, `values`, `rendered_content`). As in Dify, a model turn with more than one `ask_human` call fails with `ask_human_invalid`. |
| Cancel | Closes the run's HTTP client (the Swift server then closes its connection to the plugin), interrupts tools and stops sandbox jobs. Whether the vendor stopped generating or billing cannot be observed and is not claimed. |
| Usage | Taken from each model call's final usage chunk, counted once per `invocation_id`. |
| Images of the workspace | `view_image` (dify-sf extension, with `tools.view_image`), see [Viewing workspace images](#viewing-workspace-images). The image goes to the next model call only. |
| Events | Tool starts and ends become `tool_call`. |
| Failures | Genkit reports model errors and the turn limit in `finishReason`, not as exceptions; both map to `failed`. |

### Viewing workspace images

A dify-sf extension: Dify's agent has no tool that shows the model a file it made. With `tools.view_image` the model
gets `view_image {"path", "detail"?}` (`path` relative to `/workspace` or absolute inside it; `detail` `high`, the
default, or `low`):

1. The service resolves the path in the sandbox (inside `/workspace` after symlinks, a regular file) and reads it. It
   must be a PNG, JPEG or WebP by its header. All images viewed in one model step together may have at most 3 MiB
   (the gateway's file budget per model request is 6 MiB, task images included).
2. It uploads the bytes as a file of the execution (`files/upload-request` and `PUT`; the Swift server grants a
   received upload to the run token's model files, `grantFiles`) and returns the tool result: a text with the path,
   type, dimensions and size, and the image as a multipart part (`dify-sf-file:<upload_id>`).
3. The model bridge sends the image only to the model call right after that tool result: after the tool messages
   (which carry text only) as a user message `view_image <path>:` plus the image part (`detail` as asked). Every later
   call, including a resume, sends the tool text alone. A viewed image is therefore paid for once; re-sending it with
   every turn grew one measured run to 206k tokens.

The snapshot keeps the reference, never the bytes. A missing file, a path outside the workspace, another format, the
step budget and a failed upload are tool errors the model can act on, not run failures. Viewed images are uploads of
the execution like file outputs, but they are not node outputs.

## Inner gateway (Swift server)

Authentication: the service key plus a run token. The Swift server issues a run token per operation (sent to the agent
service in the `POST /v1/operations` headers as `X-Agent-Run-Token`), bound to the execution, generation and
operation. Every inner call carries it; the Swift server checks the tenant, app, workflow run, execution, config
snapshot and that the operation is still running. A request body cannot choose a tenant or file owner.

### `POST /inner/agent/llm/invoke`

Mirrors Dify's `AgentLLMInvokeRequest`:

```jsonc
{"caller": {"invocation_id": "<run_id>:<call_index>", "run_id": "…", "call_index": 1, "operation_id": "…",
            "tenant_id": "…", "app_id": "…", "user_id": "…", "user_from": "account", "invoke_from": "debugger",
            "workflow_run_id": "…", "node_id": "…", "node_execution_id": "…", "agent_config_snapshot_id": "…"},
 "target": {"provider": "…", "model": "…", "prompt_messages": [ /* Dify PromptMessage JSON */ ],
            "model_parameters": {…}, "tools": [{"name", "description", "parameters"}], "stop": null, "stream": true}}
```

Response: `text/event-stream`, one event per chunk, `data: {"code": 0, "message": "", "data": <Dify LLMResultChunk>}`.
Tool call deltas follow Dify's chunk shape (`delta.message.tool_calls[]` with `index`, `id`, `type`, `function.name`,
`function.arguments`); deltas of several tool calls may interleave. A delta with `index` belongs to that index's call
(later deltas may carry only `index`); the first delta with an `id` sets the id; name and arguments concatenate in
arrival order per call; a delta with an id but no index matches by id. Reasoning may arrive as
`delta.message.reasoning_content` (string, streamed in pieces) or as `<think>…</think>` in `delta.message.content`;
an assistant history message carries prior reasoning back the same way (`reasoning_content` or the think tag). That
is all the agent service guarantees: what reaches the vendor is decided by the model plugin and is not guaranteed. For
example, the signed `openai_api_compatible` plugin 0.0.68 removes `<think>` blocks from earlier assistant messages, and
drops the think blocks it returns when the model declares no reasoning support. The last chunk carries `delta.usage` and `delta.finish_reason`. Errors end the stream with
`{"code": -429 | -500, "message": "{\"error_type\":…,\"message\":…}", "data": null}`, as in Dify. A repeated
`invocation_id` is rejected, so usage is recorded once. Closing the connection closes the gateway's connection to the plugin (see below).

The gateway may complete any call without streaming and return the result as one or a few complete chunks (full
`tool_calls` with `id`, reasoning, usage and finish reason in one delta). It does so today for every call that offers
tools: the signed `openai_api_compatible` plugin 0.0.68 drops `index` from streamed tool-call deltas, so interleaved
calls get mixed arguments, while the same request without streaming is correct. Closing the connection to the gateway
closes the gateway's HTTP connection to the plugin; it does not prove that the vendor stopped generating or billing.

Files in `prompt_messages` (Dify image/document content parts) carry `"url": "dify-sf-file:<file_id>"` and an empty
`base64_data`. The Swift server checks the file against the files of the run token's execution and reads it from
storage; a URL that is not a file of the execution is rejected before the stream starts with
`422 {"error": "file_error", "message"}`, which ends the run `failed` (`file_error`). Files of one request beyond the
gateway's byte budget answer `422 file_error` or `413`; both end the run `file_error`. The Swift server checks the
run's file budget before it starts the node. The model path never uses
`files/download-request`.

### File requests

- `POST /inner/agent/files/download-request` `{"file_id"}` → `{"url", "expires_at", "mime_type", "size"}`, for
  components that need the bytes (the sandbox). Only files that belong to the execution's inputs or uploads.
- `POST /inner/agent/files/upload-request` `{"filename", "mime_type", "size"}` → `{"url", "upload_id"}`; the agent
  service then `PUT`s the bytes to `url` with that `Content-Type` (any 2xx is success). The uploaded file belongs to
  the execution. The Swift server confirms receipt before the node succeeds; only then is the workspace
  removed.

## Declared outputs

The Swift server is the only place that decides declared-output strategies, following Dify's
`output_failure_orchestrator` and `output_type_checker`:

- It validates the candidate itself (types, file existence and tenant ownership; optional outputs not produced are
  `not_produced`).
- While a failed field has retry budget left, it starts an `output_retry` operation with per-field feedback.
- When budgets are spent, strategies combine as `fail_branch > stop > default_value`.

File outputs (a dify-sf choice; Dify's model uploads through its CLI instead): any schema node — a top-level property,
a property of an object output at any depth, or the `items` of an array — carrying `"x-dify-sf-file": {"extensions"?: ["csv"], "mime_types"?: ["text/csv", "image/*"]}`. The
keyword is removed from the schema the model sees. The model gives a path relative to the workspace. The agent service
checks that it stays inside `/workspace` after resolving symlinks, is a regular file of at most 64 MiB and meets the
constraints (MIME type by extension, else `file --mime-type`); otherwise that field gets a `candidate_errors` entry and
keeps the model's value. A good file is uploaded and replaced in the candidate by
`{"upload_id", "filename", "mime_type", "size"}` at the same place (each item of an array). `candidate_errors` names the
top-level property in `field` and the exact place in `error` (`bundle.pages[1]: …`); a field with any bad file keeps
the model's value and none of its files are uploaded. A failed upload ends the run `failed`
(`file_error`); the workspace is kept.

Node outputs follow Dify: `text` plus declared outputs; `process_data` carries `agent_id`, `agent_config_snapshot_id`
and `workflow_agent_binding_id`; `metadata.agent_log` is an object.

## Questions and forms

- A question creates a human-input form keyed by execution and `resume_sequence`, linked to `question_id`,
  `tool_call_id`, snapshot revision and a consumed flag. Ordinary Human Input nodes keep their single form per
  execution.
- The snapshot, form and workflow pause are committed in one transaction before the form is delivered. No form exists
  without its snapshot.
- The decision the engine claims is matched to the current pending form of the execution, never an older one. After
  a successful resume the sequence advances; a repeated answer or claim is consumed once.
- A timed-out form resumes the agent with `{"status": "timeout"}`. A globally expired form ends the run, as in Dify.

## Sandbox

The image is Dify's `langgenius/dify-agent-local-sandbox:1.17.1`. Dify itself shares one `shellctl` daemon between
executions, separating them by home and workspace directories under Landlock. That is not a hard boundary for dify-sf:
`shellctl` runs commands when Landlock cannot be enabled (it only warns), Landlock V1 rules leave `/proc` readable, and
the home and writable paths come from environment variables.

dify-sf therefore gives each execution that enables the shell its own container from that image:

- created on first shell use, removed with the execution (`DELETE /v1/executions/{id}`) or when its lease expires;
- its own internal network, shared with no other sandbox; egress only through the sandbox proxy, enforced by network
  rules, not by proxy variables;
- memory, CPU, PID and disk limits; at the end of a run the processes its jobs left in the container are killed;
- reserved environment variables cannot be set by users;
- containers are created by a small supervisor, the only component with access to the container runtime, which
  accepts only "create sandbox for execution X with the fixed image and limits" and "remove it".

Supervisor (`agent_service/bin/sandbox_supervisor.dart`, Docker Engine API on the unix socket, bearer key):
`POST /v1/sandboxes {"execution_key", "profile"}` → `{"sandbox_id", "url", "token", "gateway", "created", "profile"}`,
idempotent per key (a stopped container is replaced, with a new ID and network); `DELETE /v1/sandboxes/{id}`;
`GET /v1/sandboxes`; `GET /v1/profiles`. Any other request field is `400`. Image, limits, binds, devices and egress
come from the named executor profile (see [Executor profiles](#executor-profiles)). Containers and networks carry its label and the execution label; only objects with both are
listed, swept at start (labelled but unknown containers, and labelled networks no known container uses) or removed.
Each container gets a fresh random `SHELLCTL_AUTH_TOKEN` and, from the supervisor's configuration only:

| Concern | Docker option |
|---|---|
| Memory (tmpfs pages count here too), no swap | `Memory` = `MemorySwap` (default 1024 MiB) |
| CPU | `NanoCpus` (default 1 CPU) |
| Processes | `PidsLimit` (default 256) |
| Disk | `ReadonlyRootfs`; `Tmpfs` `/home/dify` (256 MiB) and `/workspace` (512 MiB), `rw,exec,nosuid,nodev,mode=0700` |
| Privileges | `CapDrop: ["ALL"]`, `SecurityOpt: ["no-new-privileges:true"]`, not privileged; no binds or mounts except the executor profile's read-only binds under `/opt`, no devices except its render nodes (see [Executor profiles](#executor-profiles)) |
| Landlock (shellctl) | `SHELLCTL_LANDLOCK_RO_PATHS` = shellctl's defaults plus `/opt`; with render nodes also `/dev/dri`, `/sys/dev/char` and each GPU's sysfs directory (`/sys/dev/char/<major>:<minor>/device` resolved; K17 `/sys/devices/pci0000:00/0000:00:02.0`), which Mesa needs to identify the GPU (without them it falls back to llvmpipe). `SHELLCTL_LANDLOCK_RW_DEV_PATHS` = the defaults plus the render nodes. Set in the container's environment, which jobs inherit; a node cannot set `SHELLCTL_*` |
| Network | `NetworkMode` = its own network (below), fixed address `.3`; IPv6 off (`Sysctls` `disable_ipv6`) |
| Readiness | a Docker health check on shellctl `/healthz`; the supervisor waits for `healthy` |

Per-sandbox networks. For each sandbox the supervisor, in this order:

1. resolves the peers from its configuration, never from a request: `SANDBOX_AGENT_PEERS` (the agent service) and
   `SANDBOX_PROXY_PEER`, as compose services of `SANDBOX_COMPOSE_PROJECT` (labels `com.docker.compose.project` and
   `com.docker.compose.service`, running containers only, sandboxes excluded) or as container names. A missing peer
   is `503` before anything is created;
2. allocates the first /28 of `SANDBOX_SUBNET_POOL` (default `10.213.0.0/16`, 4096 networks) that overlaps no existing
   Docker network (`GET /networks`, every network on the host, IPv4 subnets), serialized within the supervisor; a
   subnet Docker still refuses as overlapping (taken concurrently) is skipped. The pool must lie inside the ranges the
   proxy refuses as destinations (10/8, 172.16/12, 192.168/16, 100.64/10);
3. `POST /networks/create` with `Name` = the container name, `Driver: bridge`, `Internal: true`, `EnableIPv6: false`,
   `Options: {"com.docker.network.bridge.inhibit_ipv4": "true"}`, `IPAM` subnet, gateway `.1` (reserved, never
   assigned) and `IPRange` = the upper /29 (dynamic addresses), and both labels;
4. connects the proxy at the fixed address `.2` (sandboxes get `HTTP(S)_PROXY=http://<.2>:3128`, so no DNS name is
   needed), creates the container on the network at `.3`, connects the agent service container(s) (dynamic, `.8`+),
   starts it and waits for `healthy`. Any failure removes the container and the network.

A later acquire of a running sandbox connects peers missing from its network (e.g. a recreated agent service or proxy
container; the proxy gets `.2` again). Removal is: force-remove the container, disconnect the remaining endpoints (the
peers), remove the network. The network has exactly three kinds of endpoint: the sandbox, the agent service and the
proxy; two sandboxes share no network, so one cannot even open a connection to another's shellctl port (observed:
"Network is unreachable", curl exit 7), and the proxy refuses private destinations (403). The host has no address on
the bridge (`inhibit_ipv4`): on an internal network without it, the host's bridge address and every host service
listening on all interfaces (observed: port 22) were reachable from a sandbox. Inside its network a sandbox can still
reach the agent service's port (protected by its key) and the proxy. The proxy (Squid) allows only the domains in its
allowlist (default: the npm and PyPI registries) and refuses private addresses.

Jobs run with `HOME=/home/dify/agent` and `cwd=/workspace`, so shellctl's own state (`/home/dify/.local/share/shellctl`)
is outside the paths Landlock grants. Landlock stays as an additional layer. Before the first command in each process
the service runs probes, each of which must fail: write outside the workspace and job home (`/home/dify`, `/tmp`,
`/var/tmp`, `/dev/shm`, `/`), read the daemon's state or another process's environment, connect to 1.1.1.1:443 or
8.8.8.8:443, reach the host (`host_reachable`: TCP, in parallel with 3 s each, to the network's gateway address
reported by the supervisor, Docker's default bridge address 172.17.0.1, and `host.docker.internal` /
`gateway.docker.internal` when they resolve, on ports 22, 53, 80, 443, 2375, 2376, 3000, 5000, 5432, 6379, 8000, 8080,
8443 and 11434), or have IPv6 on any interface but `lo` (`host_ipv6`). A probe that succeeds makes the sandbox
`unavailable`: it is removed and the run fails with `sandbox_unavailable`. The probes check the setup; they do not
replace the container boundary, and a closed port proves nothing about a port not in the list.

At the end of every run (succeeded, paused, failed or cancelled) the service terminates and deletes the run's jobs and
then kills every remaining process in the container except the shellctl daemon (shellctl's terminate alone leaves
`setsid` and `nohup` descendants running). If that cannot be done, e.g. with the PID limit exhausted, the sandbox is
removed. Observed in the integration test: after a cancel no `sleep` started directly, with `setsid`, with `nohup` or
under `sh -c` remained. This covers processes inside the container only; what a command already did outside it
(e.g. a request through the proxy) is not undone, and nothing beyond the container is claimed.

## Executor profiles

Status: implemented in the agent service and the supervisor (2026-10-27, branch `alice/executor-profiles`); the Swift
server's part is open. MVP: one profile besides `default`, used only by the built-in agent loop and its shell tools.

An executor profile is a named sandbox environment defined by an administrator on the executor host (the agent
service and the sandbox supervisor). A node names a profile. A node, a DSL file or a request never carries an image,
mount, network rule, limit or credential, so an import or an edit cannot run an arbitrary image or read host files.
Dify's own Soul `sandbox.config` (image, working directory, environment, CPU) stays refused, as today.

### Profile file

One JSON file, `AGENT_EXECUTOR_PROFILES` (default `/etc/dify-sf/executor-profiles.json`). It is mounted read-only into
the agent service and the supervisor, and read at start; a change needs a restart. A file that does not validate
stops the process. Without a file at the default path there is one profile, `default`: today's image
(`SANDBOX_IMAGE`), limits and network; a path set explicitly must exist. A file must define `default`; unknown fields
anywhere are refused. Names match `^[a-z0-9][a-z0-9-]{0,63}$`.

```jsonc
{"version": 1,
 "profiles": {
   "default": {"description": "Dify's shell sandbox",
               "image": "langgenius/dify-agent-local-sandbox@sha256:…"},
   "colvalley-blender": {
     "description": "Blender 5.2.3, colvalley-3d (read-only) and its board renderer",
     "image": "dify-sf/sandbox-colvalley-blender@sha256:…",
     "mounts": [{"source": "/srv/dify-sf/checkouts/colvalley-3d-77b81f5", "target": "/opt/colvalley-3d"}],
     "network": {"egress": "none"},
     "devices": ["/dev/dri/renderD128"],
     "limits": {"cpus": 4, "memory_mb": 6144, "pids": 1024, "workspace_mb": 1536, "home_mb": 512,
                "timeout_seconds_max": 10800},
          "env": {"BLENDER": "/opt/blender/blender", "CV3D_PYTHON": "/opt/cv3d-venv/bin/python",
             "FS_IMPORTER": "/opt/colvalley-3d/.cv3d-prepared/fs_importer"}}}}
```

| Field | Rule |
|---|---|
| `image` | Pinned by digest (`name@sha256:…`); a tag alone stops the process at load. Images are built from `agent_service/sandbox-images/<name>/` (Dockerfile and `VERSION`) in this repository. Every image keeps shellctl (they derive from `langgenius/dify-agent-local-sandbox:1.17.1`), because the service's probes, file staging, output files and process cleanup use it. |
| `mounts` | Read-only bind mounts only (`Mounts` of type `bind`, `ReadOnly`; a missing source fails, it is never created). The source is an absolute, normalized host path (no `.`, `..`, `//`, trailing `/`, `:` or `,`); it must not be `/` and must not be, contain or lie inside the Docker socket (`/var/run/docker.sock`, `/run/docker.sock`, the configured one), Docker's or containerd's state (`/var/lib/docker`, `/var/lib/containerd`, `/run/containerd`), `/proc`, `/sys`, `/dev`, the service's data directory, the supervisor's state file or the profile file. The target is under `/opt` (not `/opt` itself), never `/workspace` or the home; targets do not nest. This replaces the sandbox rule "no binds or mounts" with "only the profile's read-only binds". Symlinks in the source are resolved by Docker on the host. |
| `network.egress` | `none`: the proxy is not connected, so there is no egress. `allowlist`: the proxy as today, with its default domains. Per-profile domain lists come later. Default `allowlist`. |
| `limits` | `cpus`, `memory_mb` (the tmpfs pages of `/workspace` and the home count here; `workspace_mb + home_mb` must be below it), `pids`, `workspace_mb`, `home_mb`. `timeout_seconds_max` (1..86400, default 1800) is the largest `limits.timeout_seconds` a run of this profile may have. Another missing value takes the supervisor's current default (`SANDBOX_*`). |
| `devices` | Optional GPU access: host device nodes passed into the container (`Devices`, `rw`). Only DRI render nodes (`/dev/dri/renderD<n>`) are accepted, without `/dev/dri/card*` (no display or modesetting); the container gets the node's group ID on the host (K17: `render`, 990) as a supplementary group (`GroupAdd`), and the Landlock paths of the [Sandbox](#sandbox) table. The supervisor reads the group with `stat` and the GPU's sysfs directory from `/sys/dev/char`, so a containerized supervisor needs `/dev/dri` bound read-only (it opens nothing there). Anything else stops the process at load. NVIDIA (`--gpus`) is out of the MVP: the executor host K17 has an Intel GPU only. |
| `env` | Fixed variables for the sandbox's commands, set by the administrator. They are not secrets and are not shown to the model. The reserved names are refused at load. A node's `env` cannot override them (`400 reserved_env`, compared case-insensitively). The agent service adds them to every shell job under the node's `env`; they are not in the container's environment. |
| `description` | Optional, at most 200 characters; shown by `GET /v1/profiles`. |

### Protocol

- `POST /v1/operations` gains `"executor_profile": "<name>"`. Absent means `default`. The profile is used only when
  `tools.shell` is true; otherwise it is not checked at all and only echoed. It is part of the request digest.
- With the shell, in this order: an unknown name answers `422 executor_profile_unknown`; a `limits.timeout_seconds`
  above the profile's `timeout_seconds_max` answers `422 invalid_request`; a node `env` name the profile sets answers
  `400 reserved_env`; a profile whose status (below) is known and not `ok` answers `503
  executor_profile_unavailable` with `"status"`. When the supervisor cannot be asked, the operation is accepted and
  the run fails, if at all, with `sandbox_unavailable`. A resend of an accepted operation answers `200` with its run
  before any of these checks.
- From this version the service refuses unknown top-level request fields (`400 invalid_request`). An older service
  ignores `executor_profile` and would use the default image. To catch that, `run_started` gains
  `"executor_profile"` (the resolved name). If the echo is missing or different, the Swift server cancels the run and
  fails the node with `sandbox_unavailable`.
- A continuation must name the profile of the snapshot's sandbox (`workspace_ref`). Otherwise it answers
  `422 snapshot_incompatible`. The Soul snapshot pins the name, so this happens only when the configuration was
  changed outside the snapshot.
- Supervisor: `POST /v1/sandboxes {"execution_key", "profile"}` (absent: `default`). The supervisor resolves the name
  from its own copy of the file; an unknown name is `400 unknown_profile`. The same key with a different profile is
  `409 profile_conflict` (a container without the profile label counts as `default`). A sandbox keeps its profile
  for its lifetime (label `dify-sf.sandbox.profile`). A missing image or render node is `503 image_missing` /
  `503 device_missing` before anything is created; images are never pulled. The answer echoes `"profile"`; the agent
  service fails the run with `sandbox_unavailable` when it is missing or different (a supervisor that ignores
  profiles). `GET /v1/sandboxes` lists each sandbox's profile. `GET /v1/profiles` → `{"profiles": {"<name>":
  {"status", "digest"}}}`, `digest` the SHA-256 of the profile's canonical JSON definition.
- Profile status, in `GET /v1/profiles` and `GET /v1/health`: `ok`, `image_missing` or `device_missing` as the
  supervisor reports them, or `unavailable`: no supervisor, the supervisor could not be asked, or its copy of the
  profile differs from the service's (digest). The service caches it for 15 seconds. The Swift server treats every
  status but `ok` as not available.
- Timeouts: the Swift server's own run timer stays authoritative. It uses the smaller of the node's timeout, the
  profile's `timeout_seconds_max` and the server-wide cap, and sends that value as `limits.timeout_seconds`, so the
  agent service never runs longer than Swift waits. `default` keeps 1800 s.
- `limits.max_turns` stays 50 in the MVP. A node setting with a per-profile and server-wide cap is added only if real
  modelling runs need more.
- Rollout order: the agent service with the echo ships first; the Swift echo check goes live after it. Otherwise an
  older service (no echo) would fail every run, including runs on `default`. The supervisor ships with the agent
  service (same image): an older supervisor refuses the `profile` field with `400`.

`GET /v1/profiles` (new) lists what the Swift server needs for the editor and the checklist:

```jsonc
{"protocol": "dify-sf-agent/1",
 "profiles": [{"name": "default", "description": "Dify's shell sandbox", "status": "ok", "timeout_seconds_max": 1800},
              {"name": "colvalley-blender", "description": "…", "status": "ok", "timeout_seconds_max": 10800}]}
```

It never lists images, mounts, network rules or environment values.

If the Swift server cannot read the list (agent service down, timeout, bad answer), the state is **unknown**, never
an empty list and never "only `default`". The editor shows the saved name with an "availability unknown" mark and
keeps it; the checklist reports "executor profiles could not be checked" instead of "not available"; a run is still
attempted and fails, if at all, with the service's own answer.

### Node configuration and DSL

- A dify-sf extension of the Soul: the key `executor_profile` (a string; absent or `""` means `default`). It is
  stored in the immutable Soul snapshot and pinned when publishing, like the rest of the Soul.
- The editor shows a profile select (from `GET /v1/profiles`, through the Swift server) only when the shell is on.
  Turning the shell off keeps the chosen name; turning it on again uses it.
- Workflows can only pick a name from the server's list. They never supply an image or mounts, and nodes cannot add
  profiles. On the trial every workspace shares the server's list; existing node access rules still apply.
- The DSL exports the name only. An import keeps the name even when this server does not know it; the import never
  fails or silently changes it to `default`. A name the server does not know, or whose status is not `ok`, is a
  checklist error ("Executor profile `colvalley-blender` is not available on this server"), and the node cannot
  run. The native MCP checklist reports the same.
- Out of the MVP: a profile administration UI (it will write the same file format), per-profile egress domain lists,
  and choosing profiles per workspace or tenant.

### Profile `colvalley-blender` (MVP)

Built and checked on K17 on 2026-10-27: image `dify-sf/sandbox-colvalley-blender@sha256:438f4d80139973fe258beaffbd28346c931db841e8a676ed0eb9bbfcfce7e9b3`
(`agent_service/sandbox-images/colvalley-blender/`, VERSION 1), colvalley-3d `alice/board-readonly` 26ea1f4.

| Part | Where | Content |
|---|---|---|
| Base | Image | `langgenius/dify-agent-local-sandbox:1.17.1` pinned by digest (Debian 12, glibc 2.36, GLib 2.74; shellctl, Python 3.12, Node, git) |
| Blender | Image | The official 5.2.3 Linux x64 archive (`blender-5.2.3-linux-x64.tar.xz`, SHA-256 from Blender's published list, checked in the build; given to the build as a named context, never downloaded there) at `/opt/blender`; used with `-b` |
| Renderer runtime | Image | Weston 10, D-Bus, GTK 3, fonts (DejaVu, Noto Sans CJK for the board's labels) and Mesa 25.0.7 from bookworm-backports: Debian 12's Mesa 22.3 cannot drive K17's Lunar Lake GPU on the `xe` kernel driver (it would fall back to llvmpipe). With the render node the board renders with `FS_RENDERER=gl` (MSAA effective, the reference path on K17); without it, `pixman` |
| GPU | Profile | K17's Intel render node `/dev/dri/renderD128` (group `render` 990): Weston gl (`GL renderer: Mesa Intel(R) Graphics (LNL)`), the Flutter client (`iris`), and EEVEE/Workbench in Blender `-b` through EGL (`gpu.platform`: OPENGL, INTEL, `Mesa Intel(R) Graphics (LNL)`; EEVEE 640x480 8.6 s vs 45 s on llvmpipe). shellctl's Landlock must grant the node and the GPU's sysfs (see [Sandbox](#sandbox)) |
| Python tools | Image | `/opt/cv3d-venv` with numpy 2.5.4, scipy 1.18.1, trimesh 5.2.0, rtree 1.4.1, Pillow 13.0.0 (pinned in `requirements.txt`), because there is no egress |
| colvalley-3d | Mount `/opt/colvalley-3d` | A checkout made by colvalley-3d's `tools/board/prepare_checkout.sh <commit> <dir>` on the executor host (below) |
| Env | Profile | `BLENDER=/opt/blender/blender`, `CV3D_PYTHON=/opt/cv3d-venv/bin/python`, `FS_IMPORTER=/opt/colvalley-3d/.cv3d-prepared/fs_importer` |
| Limits | Profile | 4 CPUs, 6 GiB memory (1.5 GiB of it the `/workspace` tmpfs, 512 MiB the home), 1024 PIDs, up to 3 hours, one run at a time. K17 has 15 GiB and 8 CPUs shared with the whole trial. Measured (below): one board run peaks at MEASURED_PEAK; the limits stay at the MVP ceiling until a real modelling run is measured (never below 2 GiB memory) |

colvalley-3d `alice/board-readonly` makes the board tool (`tools/board/render_board.sh`) run from a read-only checkout:

1. `--work-dir DIR` (or `CV3D_WORK`): every write goes under it: outputs (default `-o DIR/board/<time>`), the baseline
   cache, Weston scratch, `TMPDIR`, the D-Bus session socket (the stock session bus listens in `/tmp`, read-only in a
   sandbox), Python bytecode caches and the uv cache. `-o`, `CV3D_BOARD_CACHE`, `FS_TMP` or the work dir inside the
   checkout are refused; `git status` runs without optional locks and without the LFS filter process (both write
   into `.git`).
2. `FS_IMPORTER`: the scene importer compiled ahead of time (`dart compile exe` of flutter_scene's `bin/import.dart`
   with `app/`'s package config), used instead of `dart run flutter_scene:import` in `app/`; no Flutter SDK in the
   image. The importer self-check stays and passes. (`app/.dart_tool/package_config.json` holds absolute host paths,
   so `dart run` could not work in a sandbox anyway; the copy-`app/` fallback was not needed.)
3. `CV3D_PYTHON`: an interpreter with the packages installed, used instead of `uv run --with …`.
4. The Linux runner is built for Debian 12 although K17 builds it (glibc 2.43, GLib 2.8x): `g_ascii_strtoll` instead of
   `atoi` (no `__isoc23_strtol@GLIBC_2.38`) and `GLIB_VERSION_MIN_REQUIRED/MAX_ALLOWED` 2.74 (no
   `g_once_init_enter_pointer`). `run_linux.sh` gives Weston 10 `--use-gl` / `--use-pixman` (no `--renderer=` before
   Weston 12).

`tools/board/prepare_checkout.sh <commit> <dir>` clones the commit with its LFS files, runs `flutter pub get
--enforce-lockfile` and `flutter build linux --profile` (Flutter 3.47.6) and compiles the importer, then checks: every
LFS file present, a clean index, glibc ≤ 2.36 for the bundle and the importer, every symbol resolving in
`CV3D_CHECK_IMAGE` (`ldd -r` in a throwaway container of the sandbox image) and the importer self-check; it writes
`.cv3d-prepared/checkout.txt`. The image depends on no colvalley-3d commit; a new commit needs a new checkout directory
and a profile change, not a new image.

Boards compared on K17 (fujiya, r6 `.blend`, collection `Model`): the reference from a writable clone run twice
differs in 240 pixels (0.010 %, largest channel difference 12): the known K17 gl noise. The read-only mode on the host
differs from the reference in 151 pixels (max 12); inside the sandbox image in 269 pixels (0.011 %, max 18; Mesa 25.0
in the image, 26.0 on the host). The exported `.glb`, the `.fsceneb` and the measurements are byte-identical in all
three.

Measured end to end (`agent_service/tool/profile_e2e.sh`: the agent service, the supervisor and the profile file in
compose, a scripted model running `render_board.sh --object fujiya` on the r6 `.blend` given as an input file, then
`view_image` and `final_output` with the board as a declared file output): MEASURED_E2E.

## Swift server summary

- `AgentV2Node` implements `RuntimeNode`; the factory builds it only for `type: agent`, `version: "2"`,
  `agent_node_kind: dify_agent` with an inline binding.
- Run capabilities are reported separately (Agent v2, inline, workflow, ask_human, shell), not by adding `agent` to the
  supported node types, so Agent v1 nodes are not shown as runnable.
- Inline configuration uses Dify's minimal tables (workflow-only `agents`, immutable config snapshots, drafts,
  per-version node bindings) and Dify's node composer endpoints, under the existing revision and conflict checks.
  Publishing pins the graph, binding and snapshot together; edits, rollbacks, copies or imports during a pause do not
  change the configuration of that run.
- The editor checklist and the native read-only MCP read the same binding, snapshot and model catalog. Until that
  context exists, MCP reports agent nodes as incomplete.
- DSL export removes secrets and file locators and carries file contents as resources; import checks them. Settings
  outside the first phase are rejected, never silently dropped.
- Run records (thoughts, tool calls, usage) are stored by the server and shown when the node ends (a dify-sf
  extension). They are truncated at 256 KB on a UTF-8 boundary with a marker and a reference to the full record file;
  credentials are removed first.

- Executor profiles (see [Executor profiles](#executor-profiles)): the Soul's `executor_profile` key
  (validation, snapshot pinning, DSL name only, checklist and MCP checks against `GET /v1/profiles`), the editor's
  profile select, `executor_profile` in the operation (`""` sent as `default`), the `run_started` echo check, the new
  `422`/`503` answers as node errors, and the timeout capped by the profile's `timeout_seconds_max`.
- `tools.view_image` set when the shell is on and the model declares `vision` (see
  [Viewing workspace images](#viewing-workspace-images)); viewed images arrive as ordinary agent uploads.

## Tests that must stay

1. A run completes with no UI subscription; reopening shows the same state and record.
2. A `POST` whose response was lost does not run again; same key with a different body conflicts; cursor resume and
   status agree.
3. Ask A, answer, ask B, answer; same-second questions, repeated provider tool IDs and parallel iterations never reuse
   an old answer.
4. Fault injection at each step of the pause commit leaves no answerable form without its snapshot; a resume in a new
   process continues the original question.
5. Restarting Swift and Dart during an active and a paused execution: the active one fails without replaying side
   effects, the paused one resumes, cleanup is recorded.
6. Declared outputs: default value with retries disabled, different budgets and strategies per output, optional output
   missing, file of another tenant or a dead reference.
7. Cancel at three points (before the first chunk, mid-stream, during a tool) through Genkit → Swift → plugin daemon →
   scripted provider; upstream connection and child processes checked; late results do not overwrite the final state.
8. Sandbox: two executions (no shared network), daemon state and control port, reserved env, isolation unavailable,
   host reachability, direct egress,
   descendant processes and disk limits.
9. Input URLs refetched after expiry; failed uploads keep the workspace; files survive a pause; failed cleanup retries.
10. Collaboration conflicts and publish pinning, copy and DSL round trip, editor and MCP on the same snapshot; an
    unconfigured service or an out-of-scope feature is refused.

## Evidence so far

A feasibility check of Genkit Dart (scripted OpenAI-compatible host, and one real model over `genkit_openai`) passed:
tool loop with streaming, JSON-schema output, interrupt and resume of the original tool call in a new process, cancel
during streaming, image input. It did not exercise the Genkit → Swift → plugin daemon path; phase 1 does.
