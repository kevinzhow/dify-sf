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
  "tools": {"ask_human": true, "shell": false},
  "env": {"KEY": "value"},
  "files": [{"file_id": "…", "path": "files/spec.md"}],
  "limits": {"max_turns": 50, "timeout_seconds": 1800},
  "continuation": null
}
```

- `output_schema`: JSON Schema of the declared outputs plus `text`, or `null` when none are declared. As in Dify it
  must be an object schema whose `$ref`s are local `#/$defs/…` (`400 invalid_request` otherwise); its top-level
  `description` becomes the `final_output` tool description.
- `tools.ask_human` is derived by the Swift server from the inline agent's `human.contacts` (Dify's Soul config:
  questions are enabled only when contacts are configured). The agent service treats it as a plain flag; form
  delivery and recipients stay entirely in the Swift server. `tools.shell: true` fails the run with
  `sandbox_unavailable` until the sandbox exists (phase 3).
- The `X-Agent-Run-Token` header is required for a new operation (`400 invalid_request` otherwise). The service keeps
  it in memory only.
- Files are referenced by stable `file_id`; snapshots and model requests never contain URLs. Model inputs carry
  `dify-sf-file:<file_id>` (see the inner gateway); only components that need the bytes (the sandbox) ask for a fresh
  signed URL.
- `env` reaches only the sandbox environment and never a prompt. Reserved names (`HOME`, `PATH`, `TMPDIR`, `TMP`,
  `TEMP`, every `SHELLCTL_*`, `*_PROXY` and `NO_PROXY` in either case) are rejected with `400 reserved_env`.
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
| `run_started` | `{"model", "call_index_base"}`; `call_index_base` is 0 (call indexes of the run start at 1) |
| `thought` | `{"text"}`: reasoning of the model; never part of the answer |
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

`{"protocol", "generation"}`. Stops the model call in flight, the tool in flight and the run's sandbox jobs including
their descendants, then ends the run with `cancelled`. Returns `202`; a run that already ended returns `409` with its
`result`. If the result of a cancelled run arrives late, the first committed terminal result in the Swift server wins.

### `POST /v1/executions/{execution_id}/lease`

`{"protocol", "generation", "ttl_seconds": 120}`. The Swift server renews the lease of every execution it is running or
has paused. If a running operation's lease expires, the service cancels it (`cancel_lost`). Paused executions only
hold kept files and workspaces, which expire with the human-input form's global deadline. Observing events is not a
lease.

### `DELETE /v1/executions/{execution_id}`

`{"protocol", "generation"}`. Removes everything kept for the execution: workspaces, homes and run records. The service
derives every path from its own records; nothing in the request is used as a path. Idempotent. Running operations of
the execution are cancelled first. A tombstone remains, so a late operation or lease for it answers
`410 execution_deleted`. The Swift server calls
it once the execution's node reaches a final state, after output files were received.

### `GET /v1/runs?state=active`

Lists running and unacknowledged runs with their `operation_id` and `generation`. The Swift server uses it on start-up to
reconcile: it cancels or adopts every operation left from before its restart and writes a final state for it.

### `GET /v1/health`

`{"protocol", "status": "ok" | "degraded", "sandbox": "isolated" | "unavailable" | "disabled", "version"}`.

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

## Session envelope

The snapshot passed back in `continuation` is a versioned envelope, not a bare Genkit history:

```jsonc
{"envelope": "dify-sf-agent-session/1", "revision": 2, "genkit": "1.0.1",
 "agent_config_snapshot_id": "…", "tool_definitions_digest": "…", "model": {"provider": "…", "name": "…", "parameters": {…}},
 "output_attempt": 0, "resume_sequence": 1,
 "pending": {"question_id": "E1:q2", "tool_call_id": "ask_human:0"},
 "file_ids": ["…"], "workspace_ref": "…",
 "messages": [ /* Genkit Message JSON */ ]}
```

A snapshot whose envelope, Genkit major version, config snapshot or tool definitions differ from the request is
rejected (`422 snapshot_incompatible`), never resumed with a different configuration.

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
| Events | Tool starts and ends become `tool_call`. |
| Failures | Genkit reports model errors and the turn limit in `finishReason`, not as exceptions; both map to `failed`. |

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
an assistant history message carries prior reasoning back the same way (`reasoning_content` or the think tag). The last chunk carries `delta.usage` and `delta.finish_reason`. Errors end the stream with
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
`422 {"error": "file_error", "message"}`, which ends the run `failed` (`file_error`). The model path never uses
`files/download-request`.

### File requests

- `POST /inner/agent/files/download-request` `{"file_id"}` → `{"url", "expires_at", "mime_type", "size"}`, for
  components that need the bytes (the sandbox). Only files that belong to the execution's inputs or uploads.
- `POST /inner/agent/files/upload-request` `{"filename", "mime_type", "size"}` → `{"url", "upload_id"}`; the uploaded
  file belongs to the execution. The Swift server confirms receipt before the node succeeds; only then is the workspace
  removed.

## Declared outputs

The Swift server is the only place that decides declared-output strategies, following Dify's
`output_failure_orchestrator` and `output_type_checker`:

- It validates the candidate itself (types, file existence and tenant ownership; optional outputs not produced are
  `not_produced`).
- While a failed field has retry budget left, it starts an `output_retry` operation with per-field feedback.
- When budgets are spent, strategies combine as `fail_branch > stop > default_value`.

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

Phase 3. The image is Dify's `langgenius/dify-agent-local-sandbox:1.17.1`. Dify itself shares one `shellctl` daemon
between executions, separating them by home and workspace directories under Landlock. That is not a hard boundary for
dify-sf: `shellctl` runs commands when Landlock cannot be enabled, Landlock V1 rules leave `/proc` readable, and the
home and writable paths come from environment variables.

dify-sf therefore gives each execution that enables the shell its own container from that image:

- created on first shell use, removed with the execution (`DELETE /v1/executions/{id}`);
- internal network only; egress through the sandbox proxy, enforced by network rules, not by proxy variables;
- memory, CPU, PID and disk limits; stop kills every descendant process;
- reserved environment variables cannot be set by users;
- containers are created by a small supervisor, the only component with access to the container runtime, which
  accepts only "create sandbox for execution X with the fixed image and limits" and "remove it".

Landlock stays as an additional layer inside the container. Before the first command the service runs probes (write
outside the workspace, read the daemon's job records, reach the internet directly). A failed probe makes the sandbox
`unavailable`; the run then has no shell tool, or fails with `sandbox_unavailable` if the node requires the shell.
The probes check the setup; they do not replace the container boundary.

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
8. Sandbox: two executions, daemon state and control port, reserved env, isolation unavailable, direct egress,
   descendant processes and disk limits.
9. Input URLs refetched after expiry; failed uploads keep the workspace; files survive a pause; failed cleanup retries.
10. Collaboration conflicts and publish pinning, copy and DSL round trip, editor and MCP on the same snapshot; an
    unconfigured service or an out-of-scope feature is refused.

## Evidence so far

A feasibility check of Genkit Dart (scripted OpenAI-compatible host, and one real model over `genkit_openai`) passed:
tool loop with streaming, JSON-schema output, interrupt and resume of the original tool call in a new process, cancel
during streaming, image input. It did not exercise the Genkit → Swift → plugin daemon path; phase 1 does.
