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
  "tools": {"ask_human": true, "shell": false, "view_image": false, "report_progress": false},
  "env": {"KEY": "value"},
  "files": [{"file_id": "…", "path": "files/spec.md"}],
  "limits": {"max_turns": 50, "timeout_seconds": 1800},
  "executor_profile": "default",
  "harness_style": "dify",
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
  `tools.report_progress: true` (a dify-sf extension, see [Progress previews](#progress-previews)) adds the
  `report_progress` tool and requires `tools.shell` (`400 invalid_request` otherwise). Proposal: the Swift server sets
  it whenever the shell is on (the image never goes to the model, so no `vision` is needed); it is not a Soul key.
- `limits.max_turns` is the most model calls of this operation (Genkit's `maxTurns`; default 50). With the shell it
  must not exceed the executor profile's `max_turns_max` (`422 invalid_request`, see
  [Executor profiles](#executor-profiles)). When the calls or the time left are only what finishing needs, the
  service tells the model to finish (see [Near-budget submit](#near-budget-submit)).
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
- `harness_style` selects how the agent loop is built: `"dify"` (absent means `dify`; the behaviour described in the
  rest of this document) or `"codex"` (a port of the OpenAI Codex CLI harness, see [Harness styles](#harness-styles)).
  Another string is `422 unsupported_harness_style`, a non-string `400 invalid_request`. It is part of the request
  digest and is echoed in `run_started`. `tools.update_plan: true` (default false) needs `"codex"` (`400
  invalid_request` otherwise). With `"codex"`, `model.parameters.reasoning_effort` must be one of `none`, `minimal`,
  `low`, `medium`, `high`, `xhigh`, `max`; `ultra`, `persistent` and anything else are `422
  unsupported_reasoning_effort` (`{"reasoning_effort"}` in the body; see [Reasoning levels](#reasoning-levels)).
  `model.api_type` (optional string, e.g. `"responses"`) is the credential's API mode; the `codex` style chooses its
  model wire from it (see [Model wire](#model-wire)).
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
| `harness_style` not supported | `422 unsupported_harness_style` | |
| `codex` style with a refused `reasoning_effort` | `422 unsupported_reasoning_effort` | `{"reasoning_effort"}` |

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
| `run_started` | `{"model", "call_index_base", "executor_profile", "harness_style", "model_wire"?, "runtime"?}`; `call_index_base` is 0 (call indexes of the run start at 1); `executor_profile` is the resolved profile name; `harness_style` is `dify` or `codex`; with the official Codex runtime `model_wire.wire` is `responses` and `runtime` is `{"name": "codex-cli", "version": "0.163.0", "sha256", "skills"?, "context_window", "context_window_source", "model", "reasoning_effort", "request_reasoning_effort"?}`; `context_window` is the catalog entry's and `context_window_source` `operation`, `bundled` or `fallback` (see [Codex runtime](#codex-runtime)); `skills` (names, sorted) when the profile declares `codex.skills_dirs`; `model` and `reasoning_effort` as Codex's `thread/start` answered them, `request_reasoning_effort` the level Codex sends when it differs (`ultra`). With the official runtime `run_started` is written once Codex has started the thread, still before any other event; a run that fails earlier writes it without these fields (see [Codex runtime](#codex-runtime)) |
| `thought` | `{"text"}`: reasoning of the model; never part of the answer. One per model call, written when the call ends (also when it is cancelled); reasoning longer than 16 KiB of UTF-8 is split into several, cut only between code points |
| `tool_call` | `{"id", "name", "phase": "started" \| "finished", "input"?, "output"?, "error"?}`; `id` is the provider's ID |
| `model_call` | `{"invocation_id", "usage", "prompt"}` after each model call; `prompt` is `{"messages", "prefix_stable", "first_changed_message"}` (see [Prompt cache](#prompt-cache)). Not emitted by the official Codex runtime: the Swift server records those calls from its gateway |
| `budget_notice` | `{"reason": "max_turns" \| "timeout", "call_index", "remaining_calls", "remaining_seconds"?}`: the model was told to finish (see [Near-budget submit](#near-budget-submit)); at most one per run, before the model call it went with |
| `progress` | `{"file": {"upload_id", "filename", "mime_type", "size"}, "caption", "call_index"}`: a preview from `report_progress` (see [Progress previews](#progress-previews)), between the tool's `started` and `finished` `tool_call` events |
| `commentary` | `codex` style: `{"text", "call_index"}`, the assistant text of a response that also calls tools (Codex's `phase: commentary`); it stays in the history |
| `plan` | `codex` style with `tools.update_plan`: `{"explanation", "plan": [{"step", "status"}], "call_index"}` |
| `compaction` | Official Codex runtime: `{"phase": "started" \| "finished", "call_index"}` around Codex's compaction of the conversation (a `contextCompaction` item of the root thread) |
| `model_retry` | `codex` style: `{"call_index", "attempt", "layer": "request" \| "stream", "kind", "message", "delay_ms"}` before a retried model call (see [Harness styles](#harness-styles)); the official Codex runtime sends `"layer": "codex"`, `kind` = Codex's error code, `attempt` and `delay_ms` null |
| `succeeded` | `{"candidate": {…}, "candidate_errors": […], "snapshot": <envelope>, "usage", "partial"}`; `partial` is `null`, or `{"reason", "notice_call_index"}` when the result came after a budget notice |
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
  "reasoning_tokens", "prompt_cache_hit_tokens", "prompt_cache_miss_tokens"}`. `reasoning_tokens` is `null` when the
  provider does not report it; it is a detail of `completion_tokens` when the provider counts it there, never added a
  second time. The two cache counters are details of `prompt_tokens` (never added to it): hits are read from
  DeepSeek's `prompt_cache_hit_tokens`, the Swift server's `cached_tokens` or OpenAI's
  `prompt_tokens_details.cached_tokens`; misses from `prompt_cache_miss_tokens`, else `prompt_tokens` minus the hits.
  Both are `null` when no hit count is reported, which is the case for every provider today (see
  [Prompt cache](#prompt-cache)). Summed counters (reasoning and cache) are the sums of the values that were
  reported.
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
execution's sandbox (null until the shell is used); a resume whose sandbox was replaced fails with `sandbox_error`,
unless the new sandbox keeps the disk workspace (`workspace_kept_from`, see [Disk workspaces](#disk-workspaces)).
`executor_profile` is the operation's profile; a snapshot without it (taken before profiles) counts as `default`. A
continuation with the shell and a `workspace_ref` whose profile differs from the request's is `422
snapshot_incompatible`. A snapshot of the `codex` style carries `"harness_style": "codex"`, `"codex": {"upstream",
"model_family", "wire"}` and `"items"` (Responses API items, see [Harness styles](#harness-styles)) instead of `genkit`
and `messages`; a snapshot without `harness_style` is a `dify` snapshot. A continuation whose `harness_style` differs
from its snapshot's is `422 snapshot_incompatible`.

## Agent loop

Genkit Dart supplies the tool loop, streaming, interrupts and image input. The service adds:

| Concern | Behaviour |
|---|---|
| Model | A Genkit model that calls the inner gateway `POST /inner/agent/llm/invoke` with the run's execution and a fresh `invocation_id`. It holds a per-run HTTP client. |
| Reasoning | Reasoning arrives as `<think>…</think>` inside the content (Dify's convention for model plugins) or as `delta.message.reasoning_content`. It becomes `thought` events and is kept out of the answer text and the candidate. It stays in the session history as reasoning and is sent back on later calls and resumes the way it arrived for that call: `<think>\n…\n</think>` before the assistant content, or the assistant message's `reasoning_content`. |
| Declared outputs | As in Dify (pydantic-ai `ToolOutput`), the schema is exposed as the tool `final_output` (local `$defs` inlined, title `final_output`); there are no prompt instructions and no `response_format`. The tool is never executed: the first `final_output` call of a turn ends the run `succeeded` with its arguments as the candidate, checked against the schema for per-field errors. As with pydantic-ai's default `end_strategy='early'`, no other call of that turn is executed; the history answers them with pydantic-ai's texts (`Final result processed.`, `Output tool not used - a final result was already processed.`, `Tool not executed - a final result was already processed.`). No retries here. |
| Human question | Tool `ask_human` (Dify's arguments: `title`, `question`, `markdown`, `fields`, `actions`, `urgency`, with Dify's limits) returns a Genkit interrupt. Arguments outside the schema or limits go back to the model as a tool error, as Dify's `ModelRetry` does. The run ends `paused`. A resume answers the same tool call with Dify's tool result (`status`, `action`, `values`, `rendered_content`). As in Dify, a model turn with more than one `ask_human` call fails with `ask_human_invalid`. |
| Cancel | Closes the run's HTTP client (the Swift server then closes its connection to the plugin), interrupts tools and stops sandbox jobs. Whether the vendor stopped generating or billing cannot be observed and is not claimed. |
| Usage | Taken from each model call's final usage chunk, counted once per `invocation_id`, with the cache counters when reported. |
| History | Append-only: every model request is the previous request of the operation plus what came after it, byte for byte, so a provider's prefix cache can serve it (see [Prompt cache](#prompt-cache)). Nothing earlier is removed, reordered or re-serialized differently. |
| Images of the workspace | `view_image` (dify-sf extension, with `tools.view_image`), see [Viewing workspace images](#viewing-workspace-images). The image stays in the conversation. |
| Budget | Near the end of `max_turns` or `timeout_seconds` the model is told to finish now, see [Near-budget submit](#near-budget-submit). |
| Progress | `report_progress` (dify-sf extension, with `tools.report_progress`), see [Progress previews](#progress-previews). |
| Events | Tool starts and ends become `tool_call`. |
| Failures | Genkit reports model errors and the turn limit in `finishReason`, not as exceptions; both map to `failed`. |

### Viewing workspace images

A dify-sf extension: Dify's agent has no tool that shows the model a file it made. With `tools.view_image` the model
gets `view_image {"path", "detail"?}` (`path` relative to `/workspace` or absolute inside it; `detail` `high`, the
default, or `low`):

1. The service resolves the path in the sandbox (inside `/workspace` after symlinks, a regular file) and reads it. It
   must be a PNG, JPEG or WebP by its header. All images viewed in one conversation together may have at most 16 MiB
   (the gateway's file budget per model request is 6 MiB, task images included).
2. It uploads the bytes as a file of the execution (`files/upload-request` and `PUT`; the Swift server grants a
   received upload to the run token's model files, `grantFiles`) and returns the tool result: a text with the path,
   type, dimensions and size, and the image as a multipart part (`dify-sf-file:<upload_id>`).
3. The model bridge sends the image after that tool result, after the tool messages (which carry text only), as a
   user message `view_image <path>:` plus the image part (`detail` as asked), in the call right after the tool ran
   and in every later call, resumes and output retries included: the image stays in the conversation and the
   request stays append-only (see [Prompt cache](#prompt-cache)). The same bytes viewed again (SHA-256) are not
   attached a second time; the tool answers that they are already in the conversation.
4. Budget: kept images are sent with every model call, and the Swift gateway accepts at most 20 MiB of files per
   model request (task images included). The viewed images of one conversation (the execution's snapshot history
   plus this run) may therefore have at most 16 MiB together, leaving 4 MiB of the gateway budget for the task's
   images. A view beyond it is a tool error that names what is used and asks for a smaller copy; the tool
   description asks the model to view small JPEG copies. A larger budget needs a larger gateway budget first.

Keeping viewed images in later calls preserves the earlier request prefix and lets the model refer back to them.
This can allow a provider's prompt cache to reuse earlier input, but byte stability alone does not establish a
cache hit, a token count or a price. Only counters reported by the provider establish observed cache usage.

### Progress previews

A dify-sf extension: Dify's agent has nothing like it. With `tools.report_progress` the model gets
`report_progress {"path", "caption"}`: an image of the workspace (PNG, JPEG or WebP by its header, at most 3 MiB) and
a caption (1 to 200 characters), for the people following the run.

1. The image is checked like a `view_image` file (inside `/workspace` after symlinks, a regular file) and uploaded as
   a file of the execution through `files/upload-request` and `PUT`, the same mechanism and receipt as viewed images
   and file outputs.
2. The service emits `progress` `{"file": {"upload_id", "filename", "mime_type", "size"}, "caption", "call_index"}`
   (`file` as for a file output's receipt; `call_index`: the model call that asked for it) and answers the model
   with a short text.
   The run never waits for anyone, and the image never enters the model's context (the request prefix is not
   affected).
3. At most 20 previews per operation (at most 60 MiB a run can store); a preview beyond that, a bad caption, a file
   that is not an image or is too large, and a failed upload are tool errors; the run goes on.
4. Retention: the `progress` events are kept like every event (until the ack, or 24 hours after the run ended); the
   uploaded files belong to the execution like viewed images. They are not node outputs.

The Swift server checks that `file.upload_id` is a received upload of this execution and turns it into a file the
client can preview (no separate download URL in the event). To show it in the run log, it must project `progress`
into an `agent_log` entry (today only `thought`, `tool_call`, `model_call` and `error` are projected; other events
are recorded but not published). A client of the public run stream (`GET /v1/workflow/{run_id}/events`, with
`include_state_snapshot=true` and `continue_on_pause=true` for a driver that follows the whole run) then reads
`event: agent_log` frames whose `data.metadata.event` is `progress`; once the run has ended, that stream answers only
`workflow_finished`, and the previews are in the node's `metadata.agent_log`.

### Near-budget submit

A dify-sf extension: Dify fails the node when the agent reaches its limits. Here the model is told to finish with
what it has before the limit is reached:

- Finishing needs one model call: the one that calls `final_output` (or, without declared outputs, gives the final
  answer as text). When the schema declares file outputs and the shell is on, it needs two: one step to write the
  files into the workspace, then `final_output`. This number is the reserve; it is derived from what finishing
  needs, not tuned.
- Before each model call the service compares what is left with the reserve. Calls: `max_turns - call_index + 1`
  (this call included) `<=` the reserve. Time: the time left of `timeout_seconds` `<=` the reserve times the longest
  step of this run so far (a step: from one model call's start to the next one's, its tools included); before the
  first step has ended there is no estimate and no time notice.
- The first time either holds, it appends one user message to the history, the budget notice ("this run has N model
  calls (this one included) [and about S seconds] left. Stop exploring. Call final_output now …"), emits
  `budget_notice`, and sends the call. The notice stays in the history where it was added (append-only, also in the
  snapshot); a later operation (an answer or an output retry) gets a new budget and no new notice unless it runs low
  again.
- A result after the notice is `succeeded` as usual, with `partial: {"reason", "notice_call_index"}`. The Swift server
  should mark the node's outputs partial (for example in `process_data` or the run record); the outputs are still
  checked as usual.
- The last model call the operation may make (`call_index == max_turns`) must finish: if it calls tools and none is
  `final_output` or `ask_human`, those tools are not run (no call is left to read their results) and the run fails
  `max_turns` at once, with "the model was told to finish at call N" in the message. The time limit stays a hard
  stop: `timeout` as before.

### Prompt cache

Long agent runs re-send their history with every model call. The service keeps unchanged earlier messages and
tools byte-stable and appends new messages. Cache policies, image tokenization and pricing remain provider-specific;
see the provider's documentation, such as the [DeepSeek context caching guide](https://api-docs.deepseek.com/guides/kv_cache).
The service reports cache counters only when they reach it; missing counters stay unknown.

The protocol path (the installed plugin and daemon determine which optional usage fields reach the gateway):

| Component | Byte-stable? | Cache counters |
|---|---|---|
| Agent service | Yes, from this version: `toPromptMessages` depends on the history only and every request extends the previous one. Before it, `view_image` sent an image with the next call only and removed it afterwards: the one rewrite of earlier history. Reasoning parts, tool arguments (`dify_sf_arguments`, the provider's raw text), tool outputs and the snapshot round trip are kept unchanged | Reads them when reported (above) |
| Swift gateway | Yes. `dify-sf-file:<id>` becomes `base64_data` read from storage on every call: the same bytes each time, no signed or expiring URL in the model path. `JSONObject` keeps key order, so tool schemas keep theirs. It calls the plugin without streaming when tools are offered (no effect on the bytes) | Passes `cached_tokens` / `prompt_tokens_details.cached_tokens` through (`LLMUsage.cachedTokens`) when the daemon sends them |
| Plugin daemon 0.6.x | Passes the request through | Its `LLMUsage` is a typed struct without a cache field: anything extra is dropped |
| deepseek plugin 0.0.24 | Deterministic: merges consecutive same-role messages (a pure function of the list), turns `<think>\n<!--dify-deepseek-reasoning-->…\n</think>` back into `reasoning_content`, sends images as `image_url` data URLs, adds a fixed `user_id` | Reads only `prompt_tokens` and `completion_tokens` (dify_plugin's OpenAI-compatible base; Dify's `LLMUsage` has no cache field) |

So the only prefix break was the agent service's `view_image`, and the cache counters are lost twice, in the plugin
and in the daemon: no change in Swift or the agent service can surface them without a plugin that reports them and a
daemon that passes them (both outside dify-sf; Dify itself has no such field). Until then:

- `model_call.prompt` shows what the service controls: `prefix_stable` is `true` when the call's request repeats the
  previous call's tools and messages unchanged before appending, `false` with `first_changed_message` (`-1`: the
  tools changed) otherwise, `null` for an operation's first call.
- `tool/cache_probe.dart proxy` is a logging pass-through for the DeepSeek credential's `endpoint_url`: one line per
  chat completion with the message count, images, request size, `prefix_stable` against the previous request of the
  same conversation, and the provider's `usage` (hits and misses). It logs no headers, texts or image bytes.
- The provider's own usage page shows hit and miss tokens per key and day.

## Harness styles

`harness_style` (operation field, absent = `dify`) decides five things: the tool set, the prompt assembly, the loop
policy, context compaction and the reasoning round trip. It is independent of the model. `dify` is everything above
and stays as it is. `codex` runs the **official Codex CLI** `rust-v0.163.0` in the run's sandbox (Kevin, 2026-10-28;
see [Codex runtime](#codex-runtime)). The Dart port of Codex described after that section (Apache-2.0, vendored and
recorded in `third_party/codex/`: `LICENSE`, `NOTICE`, `UPSTREAM.json`, `PATCHES.md`; ported Dart files carry an
attribution header) is no longer extended; it runs only with `AGENT_CODEX_RUNTIME=port` and will be removed once the
official runtime has passed its acceptance runs.

### Codex runtime

`harness_style: codex` (default `AGENT_CODEX_RUNTIME=official`) runs the released Codex binary as `codex app-server` in
the execution's sandbox. One operation is one Codex turn. Codex calls the model itself, through the Swift gateway's
Codex entry; agent_service drives Codex over its app-server JSON-RPC protocol (v2) and turns its notifications into the
events of this protocol.

**Binary.** `rust-v0.163.0`, the static musl Linux x86_64 build, `sha256
399ff69c431c066e40de318fba45c2b07f45a76b19939d247ee4828fc70c4215`. The executor profile mounts the directory that holds
it read-only at `/opt/codex` (`"mounts": [{"source": "<dir with codex>", "target": "/opt/codex"}]`; no supervisor
change). Before the first run in a sandbox agent_service checks `codex --version` and the sha256; a missing or other
binary ends the run `sandbox_error`.

**Operation fields.**

| Field | Meaning |
|---|---|
| `model.run_token` | Required (`400 invalid_request` without it). The gateway token Codex sends as `Authorization: Bearer`. A secret: removed from the request before the digest, the run store and the snapshot; given only to the Codex process (`DIFYSF_RUN_TOKEN`), never to the commands it runs |
| `model.name` | Codex's `model`; the gateway checks it against the run's model configuration |
| `model.parameters.reasoning_effort` | `none` … `max`, or `ultra` (Codex resolves it from the catalog: the model's `multi_agent_reasoning_effort` or `max`, and turns on sub-agents for that run only). `persistent` is refused (`422`) |
| `model.context_window`, `model.reasoning_efforts`, `model.input_modalities` | Optional; written into Codex's catalog entry (context window; supported levels; `["text", "image"]` or `["text"]`) |
| `tools.shell`, `tools.view_image`, `tools.update_plan`, `tools.report_progress` | Codex's shell and `apply_patch`, `view_image`, `update_plan`; `report_progress` as a Codex dynamic tool. `tools.ask_human` is ignored: no question tool in this step |

**Per-run setup** in the sandbox (`CODEX_HOME=/home/dify/agent/.codex-runs/<run_id>`, removed after the run):
`config.toml` (provider `difysf`: `base_url` = the Codex entry, `wire_api = "responses"`, `env_key =
"DIFYSF_RUN_TOKEN"`, `supports_websockets = false`; `approval_policy = "never"`, `sandbox_mode = "danger-full-access"`
(the container is the sandbox), `web_search = "disabled"`; `shell_environment_policy` without Codex's KEY/SECRET/TOKEN
filter but excluding `DIFYSF_RUN_TOKEN` and `SHELLCTL_*`; request_user_input, skills (unless the profile declares
them, below), bundled skills, the skill MCP-dependency install prompt, goals, apps, plugins, memories, image generation
and analytics off; `instant_interrupt = false`, so input sent during a turn waits for the next model
request instead of discarding a response the gateway already counted; `[projects."/workspace"] trust_level = "untrusted"`:
Codex would otherwise trust its cwd at `thread/start` (danger-full-access) and load `/workspace/.codex/config.toml`,
its hooks and exec policies and `/workspace/AGENTS.md`, which an earlier operation of the execution may have written
(a planted `shell_environment_policy` handed the run token to the commands); untrusted, none of them is read, and the
provider, sandbox, approval and skill settings come only from this file and `thread/start`), `models.json` (`model_catalog_json`: one entry,
see below) and `AGENTS.md` = the node's `system_prompt` (Codex puts it in its `# AGENTS.md instructions` user message).
The base URL is the grant's `codex_gateway_url` (the supervisor gives it only to profiles with network egress
`allowlist`; without it the run ends `sandbox_unavailable`), else `AGENT_CODEX_GATEWAY_URL` (local tests). Codex runs
with `NO_PROXY=*` (it calls the gateway route directly); the commands it runs keep the sandbox's own `NO_PROXY`.

**Skills.** A profile may declare `"codex": {"skills_dirs": ["/opt/colvalley-3d/tools/skills"]}` (see [Executor
profiles](#executor-profiles)); without it skills stay off. Codex 0.163.0 reads a skill from `<dir>/<name>/SKILL.md`
with YAML front matter between `---` lines: `description` required, `name` optional (default: the directory name, at
most 64 characters). At run start agent_service resolves each directory in the sandbox (`readlink -f`; missing, or
resolved outside the profile's mounts: `sandbox_error`), sets `skills.include_instructions = true`, sends
`skills/extraRoots/set` with the directories and `skills/list` for `/workspace`, and starts the thread with every other
skill Codex found (`/workspace/.agents/skills`, `/workspace/.codex/skills`, the home's `.agents/skills`) disabled
through `thread/start`'s `config` (`skills.config` path rules), so a run offers exactly the profile's skills. Codex
puts them in a `<skills_instructions>` developer message (name, description, path; the model reads `SKILL.md` with
its shell). Skills add no tool, network or approval: there are no approvals (`approval_policy = "never"`), and the
MCP-dependency prompt is off. Skills whose `SKILL.md` Codex could not parse are logged and left out;
`run_started.runtime.skills` lists the names offered.

**Catalog entry.** Codex's bundled catalog is read from the binary (`codex debug models --bundled`). The entry is the
one Codex itself would pick (longest slug prefix, then after one `namespace/` segment), else `gpt-6-astra` for
`gpt-6*` names (as the port did), else Codex's fallback metadata (`prompt.md`, `unified_exec`); renamed to `model.name`,
with the operation's facts above, Direct tools (`tool_mode` unset: the code-mode host is not installed), no
Responses-lite request shape, no WebSocket preference, no service tiers, and `apply_patch` as Codex's freeform tool
(with the shell; DeepSeek accepts no other custom tool). The context window Codex compacts by and stops at is
`model.context_window`, else the bundled entry's, else Codex's fallback of 272000 tokens whatever the model has: that
fallback is kept (configs without the field keep working) but logged, and `run_started.runtime` names the window and
its source (`operation`, `bundled`, `fallback`); the Swift server should send `model.context_window` for models outside
Codex's bundled catalog.

**Transport.** `codex app-server --listen ws://0.0.0.0:<random port> --ws-auth capability-token --ws-token-sha256
<sha256>` runs as a shellctl `stdio` job of the run (Landlock applies to Codex and its commands as to every job), and
agent_service connects over the sandbox network with the matching bearer token (32 random bytes, per run). Not
`stdio://`: shellctl is Dify's daemon, and its stdio jobs refuse input (`409 input_unsupported`) while a PTY rewrites
JSON. The connection then sends `initialize` (`experimentalApi: true` for dynamic tools; `optOutNotificationMethods`:
the streaming deltas `item/agentMessage/delta`, `item/plan/delta`, `item/reasoning/summaryTextDelta`,
`item/reasoning/summaryPartAdded`, `item/reasoning/textDelta`, `item/commandExecution/outputDelta`,
`item/fileChange/outputDelta`, `item/fileChange/patchUpdated`, and `turn/diff/updated`, `account/rateLimits/updated`,
which the runtime does not read; `tool/codex_e2e.sh` checks the names against the binary's schema), `thread/start` (`cwd:
/workspace`, approval never, danger-full-access, `ephemeral`, `dynamicTools: [report_progress]`) and `turn/start` (the
task; task files are written to `/workspace/.dify-sf/task-files/` and given as `localImage` (images, which Codex sends
as data URLs) or by path; with declared outputs `outputSchema` = the model-facing schema, made strict-compatible
because Codex always sends `strict: true`: every property required, optional ones nullable, the `null`s removed from
the answer).

**Thread settings.** The `thread/start` answer's `model` and `reasoningEffort` must be the operation's `model.name`
and `reasoning_effort` (any effort when the operation gives none; `ultra` is Codex's to resolve: it answers `ultra`
and sends the catalog entry's `multi_agent_reasoning_effort`, else `max`, else the last supported level). Another
model or effort ends the run `internal` ("Codex started the thread with model …, not the requested …") before the
turn starts: the gateway would refuse each such request, so failing early gives the clear message. A
`thread/settings/updated` of the root thread is checked the same way (the turn is interrupted, the run ends `internal`
"Codex changed the thread to …"); `model/rerouted` is only logged. The run log has Codex's model and effort; so has
`run_started.runtime` (`model`, `reasoning_effort`, `request_reasoning_effort` when it differs).

**Events.**

| Codex | dify-sf |
|---|---|
| `item/started`, `item/completed` of `commandExecution`, `fileChange`, `imageView`, `dynamicToolCall` | `tool_call` `started` / `finished`, names `exec_command`, `apply_patch`, `view_image`, `report_progress`; `input` `{command, cwd}`, `{changes: [{path, kind}]}`, `{path}` or the arguments; `output` `{exit_code, duration_ms, output}` (64 KiB, head and tail), `{changes: [{path, kind, diff}]}`, text; `error` for failed patches, declined commands and failed dynamic calls |
| `agentMessage` with `phase: commentary` (or without a phase or with `partial_answer`, followed by a tool call) | `commentary` |
| `reasoning` (summary and content) | `thought` |
| `turn/plan/updated` | `plan` (`inProgress` written `in_progress`) |
| `error` with `willRetry` | `model_retry` |
| `item/started`, `item/completed` of `contextCompaction` (and the deprecated `thread/compacted`, which 0.163.0 does not send) | `compaction` `started` / `finished` |
| `item/tool/call` `report_progress` | `progress`, as for the other styles; Codex gets the tool text |
| `thread/tokenUsage/updated` | no event: summed into the terminal `usage` and logged; the Swift server records `model_call`s from its gateway |
| `turn/completed` | `completed`: the final answer is the turn's last agent message when Codex lists the turn's items, else the last `final_answer` message, else the last message without a phase or with `partial_answer` that no tool call followed (providers do not always send a phase) (as in the port: `{"text"}`, or the JSON object of the declared outputs, checked and its file outputs uploaded); `failed` with `usageLimitExceeded`: `max_turns` only for the gateway's own call limit (below), else `model_quota` with Codex's message; `contextWindowExceeded`: `model_error` "the conversation no longer fits the model's context window (<window> tokens, <source>) and Codex could not compact it enough: Codex: …"; other failures `model_error` with Codex's message and error code |

The snapshot of `succeeded` is `{"envelope", "revision", "harness_style": "codex", "codex": {"runtime": "official",
"version", "final_answer"}, …}`. An output retry starts a new Codex thread in the same workspace with the task, the
previous final answer and the feedback (the conversation itself is not resumed in this step). A continuation of
`kind: answer` is `422 snapshot_incompatible`.

**Near-budget notice.** agent_service does not see the gateway's call numbers. It counts Codex's finished model calls
(one token-usage notification each, sub-agents included) and, when the calls left reach what finishing needs (or the
time left, as in [Near-budget submit](#near-budget-submit)), sends the notice text with `turn/steer` and emits
`budget_notice`. Codex retries and refused attempts count at the gateway but not here, so the notice can come late; the
gateway's limit is the hard stop.

**Stop.** `cancel`, lease loss, timeout and shutdown send `turn/interrupt`, close the connection, terminate the job and
kill every process the run left (the shell session's reap): Codex and its commands end, and Codex's open model stream
is closed (checked by `tool/codex_e2e.sh`).

**Codex gone mid-turn.** When the app-server process exits or its connection closes before `turn/completed`, the tool
calls Codex started and did not finish get `tool_call` `finished` with `error` "the Codex app-server ended before the
tool finished", and the run fails: `sandbox_error` "Codex ended mid-turn: codex app-server exited (<status> <exit
code>): <the last 4000 characters of its output and stderr>" once the job is seen ended (polled for 3 s), else
`internal` "Codex ended mid-turn: the connection to the Codex app-server closed and the process still runs" (checked by
`tool/codex_e2e.sh` with a killed Codex).

**Gateway entry** (Swift server; contract agreed with Winnie, 2026-10-28): `POST <codex_gateway_url>/responses` with
`Authorization: Bearer <model.run_token>`; the body is Codex's Responses request as it is (`model`, `instructions`,
`input`, `tools` with the freeform `apply_patch`, `tool_choice`, `parallel_tool_calls`, `reasoning: {effort,
summary}`, `store: false`, `stream: true`, `include: ["reasoning.encrypted_content"]`, `prompt_cache_key`,
`text.format`, `client_metadata`); headers besides the token (`originator: dify_sf`, `session-id`, `thread-id`,
`x-codex-*`) are not forwarded. The gateway numbers every POST of the run from 1 (sub-agents share the count), records
model, effort, `include` and usage per call, enforces the node's output-token budget, passes `include` through
unchanged (also to DeepSeek, for now), refuses images that are not inline data URLs, never retries (Codex does), and
beyond `max_turns` answers `429 {"error": {"type": "usage_limit_reached", "code": "agent_call_limit", ...}}` (Codex
stops only on that type) with the header `x-codex-promo-message: dify-sf-agent-call-limit`. The token is bound to the
execution, generation and deadline and revoked at the run's end.

**Call limit or quota.** Codex reports every usage, quota and billing refusal as `usageLimitExceeded` and drops the
body's `code` and `message` of a `usage_limit_reached` 429, so the gateway marks its own call limit with
`x-codex-promo-message: dify-sf-agent-call-limit`, which Codex 0.163.0 puts into the turn error's message ("You’ve hit
your usage limit. dify-sf-agent-call-limit, or try again later."); the gateway forwards no provider header but
`Retry-After`, so a provider cannot send the mark, and it must not pass a provider's own `usage_limit_reached` type
through as is (both still to be done in the Swift gateway as of 2026-10-28). agent_service ends the run `max_turns` when the mark is in the
message, or when an unmarked `usage_limit_reached` ("You’ve hit your usage limit…") comes after at least `max_turns`
model calls it saw (finished calls, `thread/tokenUsage/updated`, plus the attempts Codex announced it retries, `error`
with `willRetry`, every thread); every other `usageLimitExceeded` ends it `model_quota` with Codex's message (a
provider quota, "Quota exceeded…", a billing or plan limit, or an unmarked refusal before `max_turns` calls). Codex's
silent request retries count at the gateway but are not seen here: until the gateway sends the mark, a call limit
reached through such retries is reported `model_quota`.

### What agent_service expects in the operation

The rest of this chapter describes the Dart port (`AGENT_CODEX_RUNTIME=port`); the official runtime is described in
[Codex runtime](#codex-runtime).

For the Swift server's harness selector, model channel and context-capacity fields:

| Field | Values | Meaning and checks |
|---|---|---|
| `harness_style` (top level) | `"dify"` \| `"codex"`; absent = `dify` | Another string `422 unsupported_harness_style`; not a string `400 invalid_request`. In the request digest; echoed in `run_started.harness_style`. The node selector maps to it; nothing else of the editor reaches the service |
| `tools.update_plan` | boolean, default false | `codex` only (`400 invalid_request` with `dify`) |
| `model.parameters.reasoning_effort` | `none` … `max` | With `codex`: `ultra`, `persistent`, other strings or non-strings `422 unsupported_reasoning_effort`. Forwarded unchanged on the plugin wire (the gateway's byte-equality check still holds), sent as `reasoning.effort` on the native wire |
| `model.wire` | `"plugin"` \| `"responses"`, optional | The channel the Swift server chose; wins over the automatic choice. `"responses"` needs `codex` (`400 invalid_request`); another value `400 invalid_request` |
| `model.api_type` | string, optional (e.g. `"responses"`) | The credential's API mode; used for the automatic choice when `model.wire` is absent |
| `model.context_window`, `model.max_output_tokens` | integers ≥ 1, optional | From the model schema; checked (`400 invalid_request`) and kept in the request; used by compaction in a later step |

The resolved channel is echoed in `run_started.model_wire` (`codex` only). The Swift server should check that the
echo matches its choice, as it does for `executor_profile`.

### Tools (`codex`)

| Tool | When | As in Codex | dify-sf differences |
|---|---|---|---|
| `exec_command` `{cmd, workdir?, tty?, yield_time_ms?, max_output_tokens?, login?}` | `tools.shell` | Codex's schema and output (`Chunk ID`, `Wall time`, `Process exited with code N` or `Process running with session ID N`, `Original token count`, `Output:`); yield 10 s default, clamped to 250-30000 ms; output collected up to 1 MiB (head and tail) and truncated with the model's policy | No `shell`, `environment_id` or approval parameters (danger-full-access, approval `never`). A shellctl job `exec bash -lc <cmd>` in `/workspace` (or `workdir`); `tty: false` (default) is a pipe job without stdin, `tty: true` a PTY job. Codex's `NO_COLOR=1 TERM=dumb PAGER=cat …` are set; the profile's and the operation's `env` win |
| `write_stdin` `{session_id, chars?, yield_time_ms?, max_output_tokens?}` | `tools.shell` | Codex's schema, defaults (writes 250 ms, max 30 s; empty polls 5-300 s) and errors (`write_stdin failed: Unknown process id N`, `stdin is closed for this session; rerun exec_command with tty=true …`) | At most 64 sessions, the least recently used terminated |
| `apply_patch` | `tools.shell` | Codex's patch grammar, lenient parser, fuzzy matching, line endings and messages; every hunk is checked before anything is written; the result is formatted like an exec (`Exit code: 0`, `Wall time`, `Output:`, `Success. Updated the following files:` …) | A Dart port (not the binary; reasons in `PATCHES.md`), on the sandbox through shellctl control commands, files up to 16 MiB. On the plugin wire a function tool `{input: string}` with the Lark grammar in its description (Dify's `PromptMessageTool` cannot carry freeform tools); Codex's freeform tool on the Responses wire |
| `view_image` `{path, detail?}` | `tools.view_image` | Codex's schema (`detail: high \| original` only for models with original detail) and messages | The image is uploaded as an execution file; on the plugin wire it follows the tool message as a user message (`original` sent as `high`); no client-side resizing; 16 MiB of viewed images per conversation |
| `update_plan` | `tools.update_plan` (default false, as in Codex 0.163.0) | Codex's schema; answers `Plan updated` | Emits a `plan` event |
| `ask_human`, `report_progress` | as for `dify` | | dify-sf tools, unchanged definitions |

There is no `final_output` tool and no shell tool of Dify's.

### Prompt (`codex`)

The history is a list of Responses API items, in Codex's layout:

1. `developer`: the base instructions. Models are matched as Codex matches its catalog (longest slug prefix, then the
   same after one simple `namespace/` segment): `gpt-6*` (for example `codex/gpt-6.1-terra`) gets the bundled
   `gpt-6-astra` template up to "# Using skills", with the two code-mode bullets replaced by "Run independent
   read-only commands as parallel tool calls."; every other model gets Codex's fallback `prompt.md`. The `update_plan`
   guidance is removed unless `tools.update_plan` is on (Codex's own filter).
2. `developer`: `<permissions instructions>` for danger-full-access and approval `never` (network `enabled` with
   egress `allowlist`, `restricted` with `none`), with the shell; then the ask_human hint (with `tools.ask_human`); then,
   with declared outputs, a dify-sf section "# Final answer format" holding the model-facing output schema.
3. `user`: `# AGENTS.md instructions for /workspace` with the node's `system_prompt` in `<INSTRUCTIONS>`, and
   `<environment_context>` (`cwd`, `shell`, `current_date`, `timezone` UTC and the filesystem element; without the
   shell only the date and time zone).
4. `user`: the task.

On the plugin wire `developer` messages become `system` messages (the plugin maps them to `developer` for the
Responses API); a user message with several parts is sent as a list of text parts. Dify's shell prompt is not used.

### Loop (`codex`)

- A step samples once; the run ends at the first response without tool calls (its assistant text is the answer). The
  assistant text of a response with tool calls is commentary (a `commentary` event) and stays in the history.
- All tool calls of a response run before the next call: consecutive parallel-safe calls (`exec_command`,
  `write_stdin`, `view_image`) together, every other call alone; the outputs are appended in call order.
- `max_turns`, the near-budget notice (text adapted: finish with the final answer) and the last-call rule stay
  (dify-sf limits; Codex has no cap).
- Declared outputs: the final answer is the candidate; it must be a JSON object (a code fence around it is accepted),
  checked against the schema and file outputs resolved as with `final_output`; anything else gives `candidate: null`
  and one error with `field: ""`. An output retry appends the feedback as a user message and continues the items.
- `ask_human`: one valid call per response pauses the run after the other calls of that response ran; the answer is
  put where that call's output belongs. Invalid arguments are a tool error; two calls in one response are
  `ask_human_invalid`.
- `finish_reason` `length` (output cut off) and `content_filter` end the run `model_error`.
- **Retries** (Codex's rules): a request layer retries HTTP 5xx answers and connection failures up to 4 times; a stream
  layer retries retryable failures up to 5 times (each again with the request layer); the delay is the server's
  `Retry-After`, else 200 ms × 2^(n-1) with ±10% jitter; an overload (`503 server_is_overloaded`) only with
  `Retry-After`. Terminal: the gateway's own refusals (400, 401, 403, 404, 409, 410, 413, 422; 429 is its call limit),
  Dify envelopes with a quota type, `InvokeAuthorizationError`, `InvokeBadRequestError`,
  `CredentialsValidateFailedError`, and -429 without a rate-limit type. Each retry repeats the call: the same
  `invocation_id` and `call_index` with the next attempt number (see [the gateway](#post-inneragentllminvoke)); a
  `model_retry` event announces it. A gateway that refuses a retry (400 or 409) ends the run with the first failure.
  Only the successful attempt's usage counts.

### Reasoning levels

`model.parameters.reasoning_effort` is forwarded unchanged (the plugin wire) or sent as `reasoning.effort` (the
Responses wire, later). Codex 0.163.0 knows `none … xhigh, max, ultra, persistent`. `ultra` is not "more than max": for
gpt-6 models Codex sends `effort: xhigh` and turns on proactive delegation to sub-agents, which this harness does not
run, so `ultra` is refused rather than silently weakened (use `max`). `persistent` is an interactive mode and is
refused too. Whether the plugin accepts `max` is up to the plugin (0.0.68 offers up to `xhigh`); the Swift server
should check the level against the model's supported levels before it starts the node.

Every `model_call` event of the `codex` style carries `"harness_style": "codex"`, `"wire"` and `"reasoning"`:

```jsonc
{"effort_requested": "xhigh",   // model.parameters.reasoning_effort (null when absent)
 "effort_sent": "xhigh",        // what this request carried
 "effort_sent_by": "plugin",    // who built the vendor request: "plugin" | "agent_service"
 "effort_echoed": null,         // the provider's echo (Responses `reasoning.effort`); null on the plugin wire
 "effort_echoed_null_reason": "the plugin wire returns no provider response object",
 "effort_forwarded": "xhigh",   // native wire only: X-Dify-SF-Forwarded-Reasoning
 "summary_sent": null, "encrypted_items_in": 0, "encrypted_items_out": 0,
 "reasoning_tokens": null, "reasoning_tokens_source": null,
 "reasoning_tokens_null_reason": "the plugin wire reports no reasoning token count (Dify LLMUsage has no such field)"}
```

On the plugin wire the effort is therefore recorded but not provable; on the native wire it is (the body is built
here, the Swift server reports what it forwarded, the provider echoes it and reports
`output_tokens_details.reasoning_tokens`).

### Model wire

A `codex` run uses one of two wires, chosen when the operation starts and recorded in `run_started` as
`"model_wire": {"wire": "responses" | "plugin", "reason", "reduced_fidelity"}`:

- `model.wire`, when the Swift server sends it, decides. Otherwise:
- **`responses`** (native): when the provider speaks the OpenAI Responses API: `model.provider` is
  `…/openai_api_compatible/openai_api_compatible` with `model.api_type: "responses"`, or `langgenius/openai/openai`.
  `model.api_type` is an optional operation field the Swift server sets from the credential's API mode (no secret);
  it is part of the request digest. agent_service builds the request Codex builds and sends it through
  `POST /inner/agent/responses` (below).
- **`plugin`**: every other model, through `POST /inner/agent/llm/invoke`, with `reduced_fidelity: true`: no encrypted
  reasoning round trip (reasoning goes back as `<think>` or `reasoning_content`), `apply_patch` as a function tool,
  viewed images after the tool message, declared outputs described in the prompt, and neither an effort echo nor
  reasoning or cache token counts.

The wire is fixed for the execution: a continuation whose wire differs from its snapshot's (`codex.wire`) is `422
snapshot_incompatible`.

On the native wire the history items are sent verbatim (annotation keys `dify_sf_*` removed): reasoning items keep
their `encrypted_content` in the history and in snapshots and go back on every later request, as Codex does with
`store: false`.

#### `POST /inner/agent/responses` (as agent_service uses it)

Authentication as for `llm/invoke`: the service key and the run token (`X-Agent-Run-Token`), which carry the
identity and scope. The call is described by request headers:

| Header | Value |
|---|---|
| `X-Agent-Call-Index` | the model call's index in the run (1, 2, …) |
| `X-Agent-Invocation-ID` | `<run_id>:<call_index>`, the same for every attempt of the call |
| `X-Agent-Attempt` | `1`, one more for each retry of the same call |

The body is the raw Responses API request, as Codex 0.163.0 builds it; the Swift server forwards it unchanged to the
credential's endpoint (URL rule as the plugin's: `endpoint_url` plus `/responses`, `/v1` not doubled):

```jsonc
{"model": "<operation model name>",
 "input": [ /* items */ ], "tools": [ /* function and custom (freeform) tools */ ],
 "tool_choice": "auto", "parallel_tool_calls": true,
 "reasoning": {"effort": "max", "summary": "auto"?},
 "store": false, "stream": true, "include": ["reasoning.encrypted_content"],
 "prompt_cache_key": "<execution_id>",
 "text": {"format": {"type": "json_schema", "name": "codex_output_schema", "strict": false, "schema": {…}}}?}
```

- `model` is the operation's `model.name`. Open question for the Swift server: whether the credential's
  `endpoint_model_name` replaces it (the plugin uses `endpoint_model_name` when set).
- `strict` is `true` only when the schema already meets OpenAI's strict rules (every object closed, every property
  required); the schema is not rewritten.
- Files appear as `"image_url": "dify-sf-file:<file_id>"` (`input_image`, in user messages and inside
  `function_call_output` content) and `"file_id": "dify-sf-file:<file_id>"` (`input_file`). The Swift server checks
  them against the execution's files and replaces them with data URLs (`file_data` for `input_file`) within the file
  budget, as for `llm/invoke` (`422 file_error`, `413`).
- Response: `200 text/event-stream`, the provider's Responses events unchanged (`event: <type>` and `data: <json>`).
  agent_service reads `response.output_item.done` (the output items), `response.reasoning_summary_text.delta` and
  `response.reasoning_text.delta` (`thought`), `response.completed` (usage and the `reasoning.effort` echo),
  `response.incomplete` (`max_output_tokens` ends the run `model_error`), `response.failed` and `error`. A stream
  that ends without `response.completed` is a retryable stream error.
- Response header `X-Dify-SF-Forwarded-Reasoning: <effort>`: the effort the Swift server forwarded; recorded as
  `model_call.reasoning.effort_forwarded`, so a rewrite on the way shows.
- Errors before the stream: a status and `{"error", "message"}` (or an OpenAI-style `{"error": {"code"}}`) as for
  `llm/invoke` (classified for retries as in
  [Loop](#loop-codex)). `response.failed` codes: `rate_limit_exceeded` and `slow_down` are retried,
  `server_is_overloaded` only with `Retry-After`, `insufficient_quota` and usage limits end the run `model_quota`,
  `context_length_exceeded`, `invalid_prompt` and `invalid_request_error` end it `model_error`, other codes are retried.
- Usage from `response.completed`: `input_tokens` → `prompt_tokens`, `output_tokens` → `completion_tokens`,
  `output_tokens_details.reasoning_tokens` → `reasoning_tokens`, `input_tokens_details.cached_tokens` →
  `prompt_cache_hit_tokens` (misses: the difference).
- A retry repeats the same `X-Agent-Call-Index` and `X-Agent-Invocation-ID` with the next `X-Agent-Attempt`.

`model_call.reasoning` on this wire: `"effort_sent_by": "agent_service"`, `effort_forwarded` (the header),
`effort_echoed` (the provider's `response.reasoning.effort`), `summary_sent` (none for gpt-6 models, `auto` for the
fallback, Codex's defaults), `encrypted_items_in`/`out` (reasoning items with `encrypted_content` sent and received),
and `reasoning_tokens` with `"reasoning_tokens_source": "provider"`.

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
`invocation_id` is rejected, so usage is recorded once. The `codex` style retries a failed call (see
[Harness styles](#harness-styles)) with the same `invocation_id` and `call_index` and `caller.attempt` 2, 3, … (absent
on the first attempt, which means 1), as `X-Agent-Attempt` on the Responses route. Proposal for the Swift server:
accept such a retry when the earlier attempts of that `call_index` failed (today it answers `409 duplicate_invocation`,
and the run then fails with the first error). Closing the connection closes the gateway's connection to the plugin (see below).

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
`POST /v1/sandboxes {"execution_key", "profile"}` → `{"sandbox_id", "url", "token", "gateway", "created", "profile"}`
(with a disk workspace also `"workspace": "disk", "workspace_kept_from": [<earlier sandbox IDs>]`),
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
| Disk | `ReadonlyRootfs`; `Tmpfs` `/home/dify` (256 MiB) and `/workspace` (512 MiB), `rw,exec,nosuid,nodev,mode=0700`; a profile with `workspace.backing: disk` gets `/workspace` as a volume instead (see [Disk workspaces](#disk-workspaces)) |
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

### Disk workspaces

Status: implemented in the supervisor (2026-10-28); verified end to end on K17 in isolation. A profile with
`"workspace": {"backing": "disk"}` gets a `/workspace` of `limits.workspace_mb` on the host's disk. Its files persist
on disk rather than occupying tmpfs; reclaimable filesystem cache still counts toward the container's memory
usage. The home stays tmpfs. At startup the supervisor requires `SANDBOX_DISK_ROOT` to be a real directory, mode
0700, owned by its effective user; a symlink or unverified owner is refused before any Docker calls. Per execution,
the supervisor:

1. checks the budget (sum of all images plus the new one ≤ `SANDBOX_DISK_BUDGET_MB`), the free space on the root (size
   plus `SANDBOX_DISK_MIN_FREE_MB`) and picks a pool device no lease holds; otherwise `503 disk_budget_exceeded`,
   `disk_space_low` or `disk_pool_busy`, before any network or container exists;
2. creates `<SANDBOX_DISK_ROOT>/<sha256(execution key)>/` (0700) with `lease.json` (written atomically, state
   `preparing`) and an empty `workspace.img` (0666, reachable only through the directory), and records the image's
   device and inode;
3. runs a short-lived helper container from `SANDBOX_DISK_TOOL_IMAGE` (pinned): root, `CapDrop ALL` + `CapAdd
   SYS_ADMIN`, `no-new-privileges`, read-only root, no network, no Docker socket, no host PID namespace; it sees only
   this image (single-file bind from `SANDBOX_DISK_HOST_ROOT`) and one pool device. It refuses a file whose device and
   inode differ from the recorded ones and a device that is already bound (`LOOP_SET_FD` is atomic; no pre-emption),
   checks the free space, `posix_fallocate`s the size, runs `mke2fs -t ext4 -m 0 -E nodiscard,root_owner=1000:1000`,
   removes `lost+found`, sets the root to 0700, binds the device and checks the binding with `LOOP_GET_STATUS64`
   (device and inode, never the backing file name: it shows `/` with single-file bind mounts);
4. creates the Docker local volume `<prefix>ws-<24 hex>` (`type=ext4`, `device=/dev/loopN`, `o=rw,nosuid,nodev`,
   labels: the supervisor's and `dify-sf.sandbox.workspace=<sha256>`), marks the lease `ready` and mounts the volume
   at `/workspace` (`NoCopy`). The sandbox itself gets no capability.

A failure rolls back what was done. A sandbox that is replaced (stopped, unhealthy) keeps the workspace: before a new
container mounts it, the helper re-verifies the binding (re-binds it when it is gone, e.g. after a reboot, using
another free pool device if the old one was taken, and replaces an own volume that points at the old device), and the
answer lists the earlier sandbox IDs in `workspace_kept_from`. The agent service accepts a snapshot's `workspace_ref`
found there (no `sandbox_error`) and does not materialize `files[]` again.

Release (`DELETE /v1/sandboxes/{id}`; the agent service calls it only after artifact collection and the result
acknowledgement): remove the sandbox and its network, check that no container uses the volume and remove it, detach
the device only when `LOOP_GET_STATUS64` shows this image's device and inode, delete the image, the lease, the
directory. A repeated or late `DELETE` of an earlier sandbox ID re-inspects that immutable ID under the execution
lock: if a concurrent acquire has replaced it, the replacement's network is left alone and the workspace is released
only when no sandbox of the execution exists. At start the sweep removes leftover helpers, finishes leases in `preparing` or `releasing`, releases
the workspaces of the unknown sandboxes it removed and own volumes without a lease; a `ready` lease without a sandbox
(a paused execution) stays. A device that holds another file while the lease says it was bound in this boot, or an
image that was replaced, puts the lease in `conflict`: nothing is detached, deleted or reused, the execution answers
`503 disk_workspace_conflict` and an operator resolves it (leases in `conflict` still count against the budget). If
an image is missing but has a recorded device/inode, or its identity is incomplete, release keeps the lease and volume in
`conflict`: unlinking an image does not detach an open loop device. With
one pool device (K17: `/dev/loop13`) at most one disk execution is active at a time. A disk profile's status is
`image_missing` also when the tool image is absent.

## Executor profiles

Status: implemented in the agent service and the supervisor (2026-10-27); the Swift/editor integration is described
in [Inline Agent executor profiles](agent-executor-integration.md). MVP: one profile besides `default`, used only by the built-in agent loop and its shell tools.

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
   "rendering": {
     "description": "Prepared rendering tools (read-only)",
     "image": "example/rendering-sandbox@sha256:…",
     "mounts": [{"source": "/srv/dify-sf/checkouts/rendering-tools-v1", "target": "/opt/rendering-tools"}],
     "network": {"egress": "none"},
     "devices": ["/dev/dri/renderD128"],
     "limits": {"cpus": 4, "memory_mb": 6144, "pids": 1024, "workspace_mb": 1536, "home_mb": 512,
                "timeout_seconds_max": 10800, "max_turns_max": 200},
          "env": {"BLENDER": "/opt/blender/blender", "RENDER_PYTHON": "/opt/render-venv/bin/python",
             "FS_IMPORTER": "/opt/rendering-tools/bin/importer"}}}}
```

| Field | Rule |
|---|---|
| `image` | Pinned by digest (`name@sha256:…`); a tag alone stops the process at load. Images are built from `agent_service/sandbox-images/<name>/` (Dockerfile and `VERSION`) in this repository. Every image keeps shellctl (they derive from `langgenius/dify-agent-local-sandbox:1.17.1`), because the service's probes, file staging, output files and process cleanup use it. |
| `mounts` | Read-only bind mounts only (`Mounts` of type `bind`, `ReadOnly`; a missing source fails, it is never created). The source is an absolute, normalized host path (no `.`, `..`, `//`, trailing `/`, `:` or `,`); it must not be `/` and must not be, contain or lie inside the Docker socket (`/var/run/docker.sock`, `/run/docker.sock`, the configured one), Docker's or containerd's state (`/var/lib/docker`, `/var/lib/containerd`, `/run/containerd`), `/proc`, `/sys`, `/dev`, the service's data directory, the supervisor's state file or the profile file. The target is under `/opt` (not `/opt` itself), never `/workspace` or the home; targets do not nest. This replaces the sandbox rule "no binds or mounts" with "only the profile's read-only binds". Symlinks in the source are resolved by Docker on the host. |
| `network.egress` | `none`: the proxy is not connected, so there is no egress. `allowlist`: the proxy as today, with its default domains. Per-profile domain lists come later. Default `allowlist`. |
| `workspace` | Optional `{"backing": "tmpfs"}` or `{"backing": "disk"}`, default `tmpfs`. `disk` needs the supervisor's `SANDBOX_DISK_*` settings (see [Disk workspaces](#disk-workspaces)); `workspace_mb` must not exceed its budget. |
| `limits` | `cpus`, `memory_mb` (the tmpfs pages of `/workspace` and the home count here; `workspace_mb + home_mb` must be below it, `home_mb` alone with a disk workspace), `pids`, `workspace_mb`, `home_mb`. `timeout_seconds_max` (1..86400, default 1800) is the largest `limits.timeout_seconds` a run of this profile may have. `max_turns_max` (1..1000, default 50) is the largest `limits.max_turns`. Another missing value takes the supervisor's current default (`SANDBOX_*`). |
| `devices` | Optional GPU access: host device nodes passed into the container (`Devices`, `rw`). Only DRI render nodes (`/dev/dri/renderD<n>`) are accepted, without `/dev/dri/card*` (no display or modesetting); the container gets the node's group ID on the host (K17: `render`, 990) as a supplementary group (`GroupAdd`), and the Landlock paths of the [Sandbox](#sandbox) table. The supervisor reads the group with `stat` and the GPU's sysfs directory from `/sys/dev/char`, so a containerized supervisor needs `/dev/dri` bound read-only (it opens nothing there). Anything else stops the process at load. NVIDIA (`--gpus`) is out of the MVP: the executor host K17 has an Intel GPU only. |
| `env` | Fixed variables for the sandbox's commands, set by the administrator. They are not secrets and are not shown to the model. The reserved names are refused at load. A node's `env` cannot override them (`400 reserved_env`, compared case-insensitively). The agent service adds them to every shell job under the node's `env`; they are not in the container's environment. |
| `codex` | Optional `{"skills_dirs": [<path>, …]}` (1 to 16): directories in the sandbox, each a mount target or inside one, normalized, no repeats, whose skills the official Codex runtime offers (see [Codex runtime](#codex-runtime)). Absent: no Codex skills. Ignored by the other runtimes. |
| `description` | Optional, at most 200 characters; shown by `GET /v1/profiles`. |

### Protocol

- `POST /v1/operations` gains `"executor_profile": "<name>"`. Absent means `default`. The profile is used only when
  `tools.shell` is true; otherwise it is not checked at all and only echoed. It is part of the request digest.
- With the shell, in this order: an unknown name answers `422 executor_profile_unknown`; a `limits.timeout_seconds`
  above the profile's `timeout_seconds_max`, then a `limits.max_turns` above its `max_turns_max`, answer
  `422 invalid_request`; a node `env` name the profile sets answers
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
- `limits.max_turns`: the node's setting (Swift, default 50), capped by the profile's `max_turns_max`; a larger value
  is refused with `422 invalid_request` as for the timeout. Without the shell the profile is not checked, as for
  every other profile rule. The Swift gateway's own per-operation call limit (`AgentModelScope.maxCalls`)
  uses the same configured number. The gateway permits at most 8192 messages per model request; provider context
  windows and byte limits still apply.
- Rollout of `max_turns_max`: the service and the supervisor (same image) ship before a profile file that sets it:
  an older one refuses the unknown field at load.
- Rollout order: the agent service with the echo ships first; the Swift echo check goes live after it. Otherwise an
  older service (no echo) would fail every run, including runs on `default`. The supervisor ships with the agent
  service (same image): an older supervisor refuses the `profile` field with `400`.

`GET /v1/profiles` (new) lists what the Swift server needs for the editor and the checklist:

```jsonc
{"protocol": "dify-sf-agent/1",
 "profiles": [{"name": "default", "description": "Dify's shell sandbox", "status": "ok", "timeout_seconds_max": 1800,
               "max_turns_max": 50},
              {"name": "colvalley-blender", "description": "…", "status": "ok", "timeout_seconds_max": 10800,
               "max_turns_max": 200}]}
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

### Rendering profile example

A rendering environment can combine a pinned sandbox image, a read-only prepared tool checkout, an optional render
device and explicit resource limits. Build tools and importers for the sandbox's runtime libraries, place all task
writes under the execution workspace and keep mounted checkouts immutable. Validate image/device availability,
file hashes, no-egress behavior and cleanup on the executor host before enabling a profile. Business inputs,
operational mount paths and per-run measurements belong in the deployment's private evidence.

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
- Run records (thoughts, tool calls, usage) are stored by the server and shown live and retained when the node ends (a dify-sf
  extension). They are truncated at 256 KB on a UTF-8 boundary with a marker and a reference to the full record file;
  credentials are removed first.

- Executor profiles (see [Executor profiles](#executor-profiles)): the Soul's `executor_profile` key
  (validation, snapshot pinning, DSL name only, checklist and MCP checks against `GET /v1/profiles`), the editor's
  profile select, `executor_profile` in the operation (`""` sent as `default`), the `run_started` echo check, the new
  `422`/`503` answers as node errors, and the timeout capped by the profile's `timeout_seconds_max`.
- `tools.view_image` set when the shell is on and the model declares `vision` (see
  [Viewing workspace images](#viewing-workspace-images)); viewed images arrive as ordinary agent uploads.
- Progress and budgets: `tools.report_progress` is pinned for new executions with the shell enabled; completed
  upload receipts are normalized to scoped preview files in live `agent_log` events. The node's `limits.max_turns`
  is checked against the environment and used by the gateway. Partial submissions are labeled explicitly.
- The model gateway allows at most 8192 messages, 20 MiB of decoded files and 32 MiB after normalization per request;
  `view_image` retains at most 16 MiB per conversation. Missing cache-hit statistics remain unknown.

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
