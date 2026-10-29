# Dify SF for AI agents

This page is for an AI agent (or a script that an agent writes) that builds, checks, publishes and runs workflows on a
Dify SF server. It gives the exact requests. It links to the detailed contracts instead of copying them.

## What Dify SF is

Dify SF is a re-implementation of Dify 1.17.1's workflow studio: a Swift server (`server/`), a Flutter client (`app/`)
and a Dart agent service (`agent_service/`). It reads and writes Dify workflow files (DSL version `0.7.0`) and runs
workflows and chatflows on the server. As an agent you can: sign in to the console API, list and read apps, import a
DSL file as a new app or replace the draft of an app, run the editor checklist through the native client's read-only
MCP server, publish, and run a published workflow as an end user (upload files, stream the run, answer human-input
forms, read the outputs). Dify SF adds an inline **Agent node** (Agent v2): one workflow node that runs an LLM agent,
optionally with a sandbox shell and the official Codex CLI. There is no Dify SF command-line tool: use the HTTP API
and the MCP server.

## Ground rules

- Examples use placeholders: `https://<your-dify-sf-host>`, `<access_token>`, `<passport>`, `<app_id>`,
  `<web_code>`, `<run_id>`, `<file_id>`, `<form_token>`. All paths are under `/v1`.
- Request and response bodies are JSON unless stated. Errors are `{"error": {"code": "...", "message": "..."}}`
  (the import endpoint answers with Dify's `Import` object instead, see below).
- There are three credentials. Do not mix them. Do not print or log them.

| Credential | How you get it | Used for |
|---|---|---|
| Console access token | `POST /v1/auth/login` | Console API: apps, import, replace, publish, run logs |
| Web-app passport | `GET /v1/passport` with `X-App-Code: <web_code>` | Public API of one published app, as one end user |
| Service API key (`app-…`) | Created in the console (`POST /v1/apps/<app_id>/api-keys`) | Public API of one app; every call also sends `user` |

A console token is refused by the public API (`401`), and a passport is refused by the console API.

## 1. Check what the server offers

`GET /v1/system-features` (no token). Read these fields:

| Field | Meaning |
|---|---|
| `inline_agent` | `true`: the server runs Agent nodes (`COLLAB_AGENT_INLINE_ENABLED=true` and an agent service is configured) |
| `inline_agent_shell` | `true`: Agent nodes get a sandbox shell (`COLLAB_AGENT_SHELL_ENABLED=true` and the agent service reports an isolated sandbox) |
| `enable_file_upload` | File storage is configured |
| `workflow_runtime.published_run` | Published workflows can run through the public API |
| `workflow_runtime.human_input` | Human-input web forms are enabled |

`workflow_runtime.draft_run` lists the node types of console draft runs. It does not list `agent`; use `inline_agent`.

## 2. Sign in to the console API

```http
POST /v1/auth/login
{"email": "<email>", "password": "<password>"}
```

`200` answers `{"access_token", "refresh_token", "account": {"id", "email", "name", "role", ...}}`. Send
`Authorization: Bearer <access_token>` on every console request. The access token lasts 60 minutes by default.
`POST /v1/auth/refresh` with `{"refresh_token"}` gives a new pair; a refresh token works once.

- A wrong email or password is `401 invalid_credentials`.
- More than 5 failed sign-ins for one email within 24 hours lock it: `429 login_rate_limited`, also with the right
  password. Do not retry sign-in in a loop.
- Import, replace and publish need the role `owner`, `admin` or `editor`. The `normal` role is read-only (`403`).

## 3. Find and read apps

| Request | Answer |
|---|---|
| `GET /v1/apps?page=1&limit=20&mode=workflow&name=<text>` | `{"page", "limit", "total", "has_more", "data": [<app>]}` |
| `GET /v1/apps/<app_id>` | The app. `id` is also the document id. `site.code` is the web code; `enable_site` must be `true` for end users |
| `GET /v1/apps/<app_id>/workflows/publish` | The published version (`graph`, `features`, `version_number`, ...) or `null` |
| `GET /v1/apps/<app_id>/export` | `{"data": "<yaml>"}`: the draft as a DSL file. Secret values are `""` unless `?include_secret=true` (owner or admin) |
| `GET /v1/apps/<app_id>/workflows/draft/nodes/<node_id>/agent-composer` | The Agent node's private configuration: `agent_soul` (secret values masked), `node_job`, `binding` |
| `GET /v1/apps/<app_id>/agent-executor-profiles` | For a workflow app: `{"shell_enabled", "profiles": [{"name", "description", "status", "timeout_seconds_max", "max_turns_max"}]}`; `profiles` is `null` when the list could not be read |
| `GET /v1/workspace/models/model-types/llm` | The workspace's LLM providers and models |

The end-user page of a workflow app is `<app_base_url>/workflow/<web_code>`.

## 4. Deliver a workflow: import, check, publish

The order is fixed: **import (or replace) over HTTP, then check that same draft with the MCP checklist, then
publish**. Deliver only a draft whose check passed with 0 warnings.

### 4.1 Import a DSL file as a new app

```http
POST /v1/apps/imports
{"mode": "yaml-content", "yaml_content": "<the YAML text>", "name": "<optional app name>"}
```

The answer is Dify's `Import` object `{"id", "status", "app_id", "app_mode", "current_dsl_version",
"imported_dsl_version", "error", "warnings"}`:

- `200`, `status: completed` or `completed-with-warnings`: `app_id` is the new app.
- `202`, `status: pending`: the file's DSL version needs a confirmation. Send `POST /v1/apps/imports/<id>/confirm`
  (same account, within 10 minutes).
- `400`, `status: failed`: `error` gives the reason.

An import always creates a new app. A request with `app_id` is refused: to change an existing app, replace its draft
(4.2).

### 4.2 Replace the draft of an existing app

```http
POST /v1/docs/<app_id>/replace
{"yaml": "<the YAML text>", "client": "<client_id>", "cseq": 1, "confirm": true}
```

- `client` is your own client id (`[A-Za-z0-9_.:-]{1,64}`). Use a new random id for each replacement, then `cseq` is
  `1`. `POST /v1/docs/<app_id>/clients` also gives you a fresh id (`{"client": "s-…"}`).
- `200` answers `{"head", "ops", "nodes", "edges", "next_cseq", "replayed", "status", "renamed", ...}`. Sending the same
  request again is safe (`replayed: true`).
- `409 outstanding_ops`, `cseq_used` or `conflict`: nothing changed. `400 version_unconfirmed`: send `confirm: true`.
- The replacement changes the draft only. End users keep the published version until you publish again. The app keeps
  its mode and takes the file's name, description and icon.

### 4.3 Run the editor checklist (the MCP gate)

The Flutter Linux client can serve a read-only MCP server on `127.0.0.1`. It has two tools, `read_workflow` and
`check_workflow`, with the arguments `{"workflow_id": "<app_id>", "expected_revision": <int, optional>}`.
`check_workflow` reads one atomic server snapshot of the draft and runs the editor's own `computeChecklist` and
`checkBeforePublish`: the same result as the checklist in the editor. The MCP server has no edit, import, run or
publish tool. Setup details: [`tool/mcp/README.md`](../tool/mcp/README.md).

1. Build the client: `cd app && flutter pub get && flutter build linux --release`.
2. Sign in once, without a display:
   `cd packages/collab_client && dart run bin/login_profile.dart --server https://<your-dify-sf-host> --credentials-file <login.json> --profile <profile-dir>`.
   `login.json` is a `0600` file with exactly `email` and `password`; the profile directory gets mode `0700`.
3. Create a local MCP key: `umask 077; openssl rand -hex 32 > <mcp.key>`.
4. Start the client under headless Weston 14:
   `DIFYSF_CLIENT_BINARY=app/build/linux/x64/release/bundle/dify_sf_app DIFYSF_MCP_RUNTIME_ROOT=<0700-dir> tool/mcp/run_headless.sh --server https://<your-dify-sf-host> --volatile --lang en-US --mcp-profile <profile-dir> --mcp-port 39391 --mcp-token-file <mcp.key>`.
5. Check: `python3 tool/mcp/check_workflow.py --endpoint http://127.0.0.1:39391/mcp --token-file <mcp.key> <app_id>`.
   Exit `0`: clean. `1`: warnings, a publish error, incomplete context or a changed revision. `2`: connection,
   authentication or protocol failure. Exit `2` also happens while the client is still restoring its sign-in: wait and
   retry.
6. Stop the client with `SIGTERM`.

The result:

```json
{"workflow_id": "<app_id>", "draft_revision": 42, "complete": true, "unavailable_context": [],
 "warning_count": 0, "items": [], "publish_error": null, "gate_passed": true, "rules": "dify-sf/editor-checklist"}
```

**A check passes only when `complete` is `true` AND `gate_passed` is `true`.** `gate_passed` also needs no items and no
`publish_error`. When a catalog could not be read, `complete` is `false`, `warning_count` is `null` and
`partial_warning_count` counts what was found: that is never a clean result. Use `expected_revision` (or
`--revision`) to check exactly the revision you imported. After any later edit, check again.

For Agent nodes the check reads the private configuration and tests, among other things: the configuration exists, the
model is configured and supports tool calls, the model passes Dify's agent compatibility filter, and the executor
profile exists with status `ok`. If the profile list cannot be read, `unavailable_context` contains
`agent_executor_profiles` and the check is incomplete.

**Example delivery scripts.** The colvalley-3d project delivers its workflows with `workflows/tools/import_apps.py`
and `workflows/tools/mcp_gate.sh`:

1. `import_apps.py --precheck-local` first runs the editor checklist on the YAML files as a Flutter test inside a
   Dify SF checkout (`workflows/checklist/run_checklist.sh`) and stops on any item. This local precheck is an
   approximation (it does not run the Agent checks). It is not the gate.
2. It imports each file as a new app (`POST /v1/apps/imports`, with the confirm step when `pending`). With
   `--replace <app_id>` it replaces that app's draft instead (`POST /v1/docs/<app_id>/replace`).
3. `mcp_gate.sh <app_id>...` starts the headless client (`run_headless.sh`), waits for the port, runs
   `check_workflow.py` for each app (it retries exit `2` for up to 90 seconds while the sign-in is restored), stops
   the client and checks that no process, port or runtime directory is left. Exit `0`: every app passed. `1`: an app
   failed. `2`: setup failure. `3`: cleanup failure.
4. When the gate fails, the new apps are deleted (`DELETE /v1/apps/<app_id>`); a replaced draft stays unpublished.
5. When the gate passes and `--publish` is given, each app is published.

### 4.4 Publish

```http
POST /v1/apps/<app_id>/workflows/publish
{"marked_name": "<at most 20 characters>", "marked_comment": "<at most 100 characters>"}
```

`200` answers `{"result": "success", "created_at"}`. The newest version is the published one. End users always run
the published version, never the draft. Publishing also pins each Agent node's configuration snapshot.

## 5. Run a published workflow as an end user

### 5.1 Get a passport

```http
GET /v1/passport
X-App-Code: <web_code>
```

`200` answers `{"access_token": "<passport>"}`. Each new passport is a new end user. Send
`Authorization: Bearer <passport>` on every public request; you can also send `X-App-Code`, which must then match
(`404` otherwise). A passport lasts 30 days. To keep the same end user, send `GET /v1/passport` again with the code and
`Authorization: Bearer <passport>`: it answers the same passport. A new site code, a disabled site or a deleted app
ends all passports.

With a service API key instead: `Authorization: Bearer app-…`, and a non-empty `user` (at most 256 bytes) in every
call: in the JSON body for writes, in the query for reads, as a multipart field for uploads.

### 5.2 Read the inputs

`GET /v1/parameters` answers `{"user_input_form": [{"<type>": {"variable", "label", "required", ...}}], "file_upload",
...}`. The types are the Start node's: `text-input`, `paragraph`, `select`, `number`, `file`, `file-list`, ...
`GET /v1/info` adds the app's name, mode and published version id.

### 5.3 Upload files

```sh
curl -s https://<your-dify-sf-host>/v1/files/upload \
  -H "Authorization: Bearer <passport>" -H "X-App-Code: <web_code>" -F "file=@photo.png"
```

`201` answers the upload: `{"id": "<file_id>", "name", "size", "extension", "mime_type", "reference", "preview_url",
"user_id", ...}`. Send exactly one multipart part named `file`. `429 upload_busy`: retry shortly.
`GET /v1/files/upload` gives the size limits in MiB (defaults: 15 for files, 10 for images, 50 for audio, 100 for video).

Pass a file input as `{"type": "image", "transfer_method": "local_file", "upload_file_id": "<file_id>"}`. A
`file-list` input takes a list of these. The server takes the name, type and size from the stored upload; the Start
field's allowed types still apply.

### 5.4 Start the run

```http
POST /v1/workflows/run
{"inputs": {"subject": "a red bicycle", "image": {"type": "image", "transfer_method": "local_file", "upload_file_id": "<file_id>"}},
 "response_mode": "streaming"}
```

The answer is a Server-Sent Events stream. Each frame is `data: {"event", "workflow_run_id", "task_id", "data"}`:

| `event` | Important `data` fields |
|---|---|
| `workflow_started` | `id` (the run id) |
| `node_started`, `node_finished` | `node_id`, `node_type`, `status`, `outputs`, `error`, `execution_metadata` |
| `loop_*`, `iteration_*` | container progress |
| `agent_log` | Agent activity, see [6.11](#611-progress-and-logs) |
| `human_input_required` | `form_token`, `inputs`, `actions`, `expiration_time` |
| `workflow_paused` | `paused_nodes`, `reasons` |
| `human_input_form_filled` | the answer that resumed the run |
| `workflow_finished` | `status`, `outputs`, `error`, `elapsed_time`, `total_tokens` |

The server also sends `event: ping` keep-alives. **This response ends at `workflow_paused` or `workflow_finished`.**
Closing it does not stop the run. `response_mode: blocking` answers once, with `{"task_id", "workflow_run_id",
"data"}`, when the run finished or paused. Stop a run with `POST /v1/workflows/tasks/<run_id>/stop`.

### 5.5 Follow a run

```http
GET /v1/workflow/<run_id>/events?continue_on_pause=true&include_state_snapshot=true
```

Use the same passport. `continue_on_pause=true` keeps the stream open across pauses. `include_state_snapshot=true`
first replays the run's state (`workflow_started`, `node_started` and `node_finished` of each execution so far, the
waiting forms, `workflow_paused`); use it after every reconnect. A run that already ended answers one
`workflow_finished` and closes. Another end user's run is `404`. `GET /v1/workflows/run/<run_id>` answers the run's
`status`, `outputs` and `error` without a stream.

### 5.6 Answer a human-input form

`human_input_required` gives `form_token`, `inputs` (each with `output_variable_name` and `type`; a select's options
are in `option_source.value`) and `actions` (each with `id` and `title`). `GET /v1/form/human_input/<form_token>`
reads the same form, but names the action list **`user_actions`** (Dify's FormDefinition: `form_content`, `inputs`,
`user_actions`, `rendered_content`, `expiration_time`, `default_values`, `node_title`, `display_in_ui`). Read
`actions` from the event and `user_actions` from the GET; the action ids are the same
(`RunStreamEncoder+HumanInput.swift`, `HumanInputRoutes.formDefinitionJSON`).

```http
POST /v1/form/human_input/<form_token>
{"inputs": {"<output_variable_name>": "<value>"}, "action": "<action id>"}
```

`200` answers `{}` and the run resumes. `400 invalid_form_data`: a missing field, a value outside the options or an
unknown action. `412 human_input_form_submitted` or `human_input_form_expired`: the form is closed. The first answer
wins. Then follow the run with the events stream (5.5): the original run stream has already ended. In a published run,
an end user sees a Human Input node's form only when the node enables the `webapp` delivery method.

### 5.7 Read results and node executions

- The workflow outputs are in `workflow_finished.data.outputs` (the End node's variables).
- With the console token: `GET /v1/apps/<app_id>/workflow-runs?triggered_from=app-run` lists published runs (the
  default is `debugging`). `GET /v1/apps/<app_id>/workflow-runs/<run_id>` gives the run's `graph`, `inputs`,
  `outputs`, `status` and `error`. `GET /v1/apps/<app_id>/workflow-runs/<run_id>/node-executions` answers
  `{"data": [{"id", "node_id", "node_type", "title", "status", "inputs", "outputs", "process_data",
  "execution_metadata", "error", "elapsed_time", ...}]}`, oldest first.
- An Agent node execution has: `outputs` = `text` plus the declared outputs; `inputs` = `task`, `model` (the resolved
  provider, model and parameters), `retain_session`; `process_data` = `agent_id`, `agent_config_snapshot_id`,
  `workflow_agent_binding_id`, `agent_output_checks` (and `agent_session` with a retained session);
  `execution_metadata` = `total_tokens`, `agent_active_elapsed_time`, `agent_partial`, `agent_log` (bounded to 256 KiB).
- The full redacted Agent record: `GET /v1/apps/<app_id>/workflow-runs/<run_id>/agent-records/<node_execution_id>.jsonl`
  (NDJSON, one `{"event_key", "event", "data"}` per line).

### 5.8 File ownership

- A file uploaded with a passport (or with an API key and `user`) belongs to that end user. An end user belongs to one
  app. A run can use only files of its own end user. Another end user's file fails as "File not found".
- Console uploads belong to no end user: public runs refuse them, and console runs refuse end-user uploads.
- To use a file in another app, upload it again with that app's passport and use the new `<file_id>`.
- Files that an Agent node produces belong to the run's end user.

## 6. The Agent node (Agent v2)

Contract: [`agent-v2.md`](agent-v2.md). Composer and checks: [`agent-inline-config.md`](agent-inline-config.md),
[`agent-inline-client.md`](agent-inline-client.md).

### 6.1 Two parts: the node and its package

A DSL file defines an Agent node in two places:

- The graph node (`type: agent`) holds what this workflow asks: the task, the declared outputs, the error strategy, the
  run-time model inputs and the session setting.
- The top-level `agent_packages.<package_ref>` holds the agent itself: its Soul (system prompt, model, harness style,
  executor profile, limits).

On import or replace the server stores the Soul as an immutable private snapshot and rewrites the node's
`agent_binding` to `{binding_type: inline_agent, agent_id, current_snapshot_id}`. Publishing pins that snapshot with the
graph; a paused or published run keeps its configuration when the draft changes. An export writes the packages back
as `agent_1`, `agent_2`, ... and adds Dify's `agent_job` to each node.

Only inline Agent v2 nodes in workflow apps run. Agent v1 nodes, roster bindings and Agent v2 in chatflows are refused.

### 6.2 The node

```yaml
- id: reviewer
  type: custom
  position: {x: 420, y: 300}
  data:
    type: agent
    title: Reviewer
    version: '2'                     # a string
    agent_node_kind: dify_agent
    agent_binding: {binding_type: inline_agent, package_ref: reviewer}
    agent_task: |-
      Check the image against the subject.
      Subject: {{#start.subject#}}
      Image: {{#start.image#}}
    agent_declared_outputs: [...]    # 6.5
    agent_model:                     # optional, 6.6
      model: '{{#start.model#}}'
      reasoning_effort: '{{#start.effort#}}'
    agent_session: {enabled: true}   # optional, 6.9
    error_strategy: fail-branch      # optional, 6.5
```

### 6.3 The package and its Soul

```yaml
agent_packages:
  reviewer:
    schema_version: 1
    metadata: {name: Reviewer, description: '', role: ''}
    soul:
      schema_version: 1
      prompt:
        system_prompt: |
          You review one image ...
      model:
        plugin_id: langgenius/openai_api_compatible
        model_provider: openai_api_compatible
        model: <model-name>
        credential_ref: null
        model_settings: {reasoning_effort: high, max_tokens: 32768}
      harness_style: codex           # dify (default) or codex, 6.7
      executor_profile: <profile>    # absent or '' = default, 6.8
      limits: {max_turns: 30}        # 1..1000, default 50, 6.12
      tools: {dify_tools: [], cli_tools: []}
      human: {contacts: [], tools: []}
      env: {variables: [], secret_refs: []}
      config_files: []
      knowledge: {sets: []}
      config_skills: []
    omitted_assets: []
    workspace_skills: []
```

- `prompt.system_prompt`: the agent's instructions (at most 256 KiB). With Codex it becomes the run's `AGENTS.md`.
- `model`: a model of the workspace's providers. The server keeps the credentials; the agent never sees them.
- Tools are not listed in the Soul. The server gives them: the shell (when the server enables it), `view_image` (shell,
  and the model declares `vision`), `report_progress` (shell), `ask_human` (when `human.contacts` is set; `dify` harness
  only) and the output tool for declared outputs. `tools.dify_tools`, `tools.cli_tools`, `knowledge.sets`,
  `config_skills` and `human.tools` must be empty. `tools.update_plan` (a boolean) is accepted only with
  `harness_style: codex`.
- Skills: the Soul has none. With Codex, an executor profile can offer skills; the administrator sets them.
- `env.variables`: plain environment variables for the sandbox commands, never in a prompt. `env.secret_refs`: secrets;
  an export keeps only their names. Reserved names (`HOME`, `PATH`, `TMPDIR`, `TMP`, `TEMP`, `NO_PROXY`, `*_PROXY`,
  `SHELLCTL_*`) are refused.
- `config_files`: named files, in the sandbox at `/workspace/files/<name>`. An export does not carry them: after an
  import they are missing until someone uploads them in the editor.
- A Soul key that the server does not know is refused.

### 6.4 The task and its inputs

- `agent_task` is the task text (at most 256 KiB). Each `{{#node.variable#}}` selector names an upstream value. The
  selector text stays in the task as written. The server appends a block `Workflow context loaded for this run:` with
  one line per selector, for example `- start.subject: a red bicycle`. A file shows as `file_id=<id>`.
- Files in those values (also inside lists and objects) and `sys.files` are input files. With the shell, each one is
  at `/workspace/inputs/<file_id>` in the sandbox (no file extension). Images are also attached to the first (task)
  message. At most 128 input files.
- A selector whose value does not exist fails the node (`MissingPreviousNodeOutput`).

### 6.5 Declared outputs and failures

```yaml
agent_declared_outputs:
- name: verdict
  type: string                       # string, number, boolean, object, array or file
  description: ok or needs_fix
  required: true
  failure_strategy:
    retry: {enabled: true, max_retries: 1, retry_interval_ms: 0}
    on_failure: fail_branch          # stop (default), default_value or fail_branch
- name: board
  type: file
  description: The final board image (a path under /workspace)
  required: true
  file: {extensions: [png], mime_types: [image/png]}
```

- The node always has `text` as well. Names match `^[A-Za-z_][A-Za-z0-9_]*$`; `text`, `switch` and `_session` are
  reserved. `object` uses `children`, `array` uses `array_item`. Model-checked outputs (`check.enabled`) are refused.
- For a `file` output the agent writes the file under `/workspace` and gives its path. The agent service uploads it
  and the output becomes a workflow file.
- The server checks every field. While a failed field has retries left, it runs the agent again with per-field
  feedback. After that: `fail_branch` wins over `stop`, `stop` wins over `default_value`.
- A field with `on_failure: fail_branch` takes the node's `fail-branch` edge. `error_strategy: fail-branch` on the node
  also routes every other failure (model error, timeout, sandbox, call limit) to that edge. Connect it with an edge whose
  `sourceHandle` is `fail-branch`. The node then has the outputs `error_type` and `error_message`.
- A field with `on_failure: stop` that still fails stops the node and the run, also with `error_strategy: fail-branch`.
- `error_type` values: `model_error`, `model_quota`, `max_turns`, `timeout`, `sandbox_unavailable`, `sandbox_error`,
  `file_error`, `session_restore_failed`, `ask_human_invalid`, `cancel_lost`, `internal`,
  `output_type_check_failed_fail_branch`, or a configuration code such as `executor_profile_unknown`.

### 6.6 Model and reasoning effort at run time

`agent_model` binds the model name and the reasoning effort to workflow variables, usually two required `select`
inputs of the Start node. Each value must be one complete reference to a string variable. The provider, credentials
and other parameters still come from the Soul. The model name must be an enabled, configured, tool-capable model of
that provider. The server resolves the values when the node starts and pins them for resumes and retries. Details:
[`agent-model-inputs.md`](agent-model-inputs.md).

### 6.7 Harness styles

| `harness_style` | What runs |
|---|---|
| `dify` (default) | Dify SF's agent loop in the agent service (Genkit Dart), with Dify's tools and prompts. Works without the shell. Can ask people questions (`ask_human`) |
| `codex` | The official Codex CLI (`rust-v0.163.0`, pinned SHA-256) runs as `codex app-server` inside the run's sandbox. One node operation is one Codex turn. Codex calls the model through the server's gateway with a run token |

Requirements of `codex`:

- The shell is on, and the executor profile mounts the Codex binary at `/opt/codex` and has network egress
  `allowlist` (only then the sandbox reaches the gateway). Otherwise the run fails (`sandbox_unavailable` or
  `sandbox_error`).
- The model is on the Responses wire: the OpenAI provider, the DeepSeek provider, or an OpenAI-compatible credential
  with `api_type: responses`.
- `model_settings.reasoning_effort` is one of `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`.
- Codex does not pause for questions: `ask_human` is not available.

Details: [`agent-v2.md`, "Harness styles" and "Codex runtime"](agent-v2.md#harness-styles).

### 6.8 Executor profiles

An executor profile is a named sandbox environment. The administrator defines it on the executor host: the image,
read-only mounts under `/opt`, GPU render devices, network egress (`none` or `allowlist`), CPU, memory and workspace
limits (tmpfs or disk), `timeout_seconds_max`, `max_turns_max`, fixed environment variables and Codex skill
directories. A DSL file names a profile; it cannot define or change one. The profile is used only when the shell is on.

- List the profiles: `GET /v1/apps/<app_id>/agent-executor-profiles`.
- A name that the server does not know (or whose status is not `ok`) is a checklist error, and the node fails
  (`executor_profile_unknown`, `executor_profile_unavailable`). An import keeps such a name unchanged.

Details: [`agent-executor-integration.md`](agent-executor-integration.md), [`agent-v2.md`, "Executor
profiles"](agent-v2.md#executor-profiles).

### 6.9 Retained sessions

`agent_session: {enabled: true}` on the node keeps the agent's workspace and Codex conversation within one workflow run.
The next execution of the same node in the same run (for example the next round of a loop) resumes the Codex thread in
the kept `/workspace`. The new input files are written into it. Only a round that succeeded is continued; a failed
round changes nothing. The server deletes the workspace when the workflow run ends.

- Requirements: `harness_style: codex`, the official runtime, the shell, the Responses wire and an executor profile
  with a disk workspace. Otherwise the node fails when it starts, before any model call.
- You see it in `run_started.runtime.session` (`{"resumed", "thread_id", "turns_before"}`) and in the node's
  `process_data.agent_session` (`{"saved", "thread_id", "turns"}`). A session that cannot be resumed fails the node with
  `session_restore_failed`; it never silently starts a new thread.

Details: [`agent-v2.md`, "Codex session retained across rounds"](agent-v2.md#codex-session-retained-across-rounds).

### 6.10 Model transport (Codex)

- HTTP (the default): one POST to the gateway's Codex entry per model call, each with the whole conversation.
- Responses WebSocket: used when the server's WebSocket listener is on (`COLLAB_AGENT_CODEX_WEBSOCKET_PORT`) and the
  credential's endpoint resolves to the official `https://api.openai.com/v1/responses`. Codex keeps one socket. Each
  request after the first carries `previous_response_id` and only the new input items.
- A WebSocket run never falls back to HTTP: an HTTP request of that run is refused (`400 incremental_required`), and a
  reconnect that lost its context is refused (`400 agent_incremental_context_lost`). The run then fails with
  `model_error`.
- `run_started.runtime.transport` shows `http` or `websocket`. The WebSocket saves network payload. Earlier input
  tokens are still billed under the provider's rules.

Details: [`agent-v2.md`, "Codex over the Responses WebSocket"](agent-v2.md#codex-over-the-responses-websocket) and
[the paired gateway](agent-v2.md#api-side-paired-websocket-gateway).

### 6.11 Progress and logs

While the node runs, the run stream carries `agent_log` frames:
`data: {"message_id", "node_id", "label", "status", "data", "metadata": {"event", "event_id"}}`. `metadata.event` is one
of `run_started`, `thought`, `tool_call`, `model_call`, `commentary`, `plan`, `progress`, `budget_notice`,
`model_retry`, `compaction`, `error`.

- `run_started.data` names the `harness_style`, `executor_profile`, `max_turns`, `resolved_model`, `model_wire` and,
  for Codex, `runtime` (`name`, `version`, `transport`, `context_window`, ...).
- `progress` comes from the agent's `report_progress` tool (shell on): `data` is `{"caption", "call_index", "file"}`,
  and `file.url` is a signed preview link. At most 20 previews per operation. Previews never enter the model's
  context.
- After the node ends, the log is in `execution_metadata.agent_log`. The full record is the `agent-records` file (5.7).

### 6.12 Limits

- Model calls: `limits.max_turns` (1 to 1000, default 50), at most the profile's `max_turns_max` (50 when the shell is
  off or the profile list is unknown); a larger value fails the node before the agent starts. With Codex every model
  request counts: Codex's own retries and sub-agent calls too. At the limit the gateway answers `429 agent_call_limit`
  and the node fails with `max_turns`. Near the limit the agent is told to finish (`budget_notice`); such a result is
  marked `agent_partial`.
- Time: the smallest of the server's node timeout (`COLLAB_AGENT_TIMEOUT_SECONDS`, default 1800), the profile's
  `timeout_seconds_max` and the server ceiling (`COLLAB_AGENT_TIMEOUT_SECONDS_MAX`, default 86400). Time spent waiting
  for a person does not count. The `default` profile keeps 1800 seconds.
- Size: task at most 256 KiB; at most 128 input files. Outside Codex's Responses route, the images of one task may have
  at most 6 MiB together.
- Concurrency: the server runs a bounded number of agent operations at once (default 2); others wait.

## 7. Minimal working example

A workflow with one Agent node that checks one image. It is a simplified form of a review app that runs on a Dify SF
server. Replace `<model-name>` with a tool-capable model of your workspace before the import (see
`GET /v1/workspace/models/model-types/llm`).

```yaml
app:
  name: Image review (example)
  mode: workflow
  icon: 🔎
  icon_background: '#E0EAFF'
  description: One inline Agent node checks an image against a description.
  use_icon_as_answer_icon: false
kind: app
version: 0.7.0
dependencies: []
workflow:
  conversation_variables: []
  environment_variables: []
  features: {}
  graph:
    nodes:
    - id: start
      type: custom
      position: {x: 0, y: 300}
      data:
        type: start
        title: Start
        desc: ''
        variables:
        - variable: subject
          label: What the image must show
          type: paragraph
          required: true
          max_length: null
          options: []
        - variable: image
          label: The image to check
          type: file
          required: true
          allowed_file_types: [image]
          allowed_file_extensions: []
          allowed_file_upload_methods: [local_file]
          options: []
    - id: reviewer
      type: custom
      position: {x: 420, y: 300}
      data:
        type: agent
        title: Reviewer
        desc: ''
        version: '2'
        agent_node_kind: dify_agent
        agent_binding:
          binding_type: inline_agent
          package_ref: reviewer
        agent_task: |-
          Check the image against the subject.
          Subject: {{#start.subject#}}
          Image: {{#start.image#}}
        agent_declared_outputs:
        - name: verdict
          type: string
          description: ok (nothing to fix) or needs_fix; only these two words
          required: true
          failure_strategy:
            retry: {enabled: true, max_retries: 1, retry_interval_ms: 0}
            on_failure: fail_branch
        - name: findings
          type: string
          description: Markdown, one numbered item per problem; none when the verdict is ok
          required: true
          failure_strategy:
            retry: {enabled: true, max_retries: 1, retry_interval_ms: 0}
            on_failure: fail_branch
        error_strategy: fail-branch
        isInLoop: false
        isInIteration: false
    - id: end
      type: custom
      position: {x: 860, y: 200}
      data:
        type: end
        title: Result
        desc: ''
        outputs:
        - {variable: verdict, value_selector: [reviewer, verdict], value_type: string}
        - {variable: findings, value_selector: [reviewer, findings], value_type: string}
    - id: end_failed
      type: custom
      position: {x: 860, y: 460}
      data:
        type: end
        title: Review failed
        desc: ''
        outputs:
        - {variable: error_type, value_selector: [reviewer, error_type], value_type: string}
        - {variable: error_message, value_selector: [reviewer, error_message], value_type: string}
    edges:
    - id: start-source-reviewer-target
      source: start
      sourceHandle: source
      target: reviewer
      targetHandle: target
      type: custom
      zIndex: 0
      data: {sourceType: start, targetType: agent, isInIteration: false, isInLoop: false}
    - id: reviewer-source-end-target
      source: reviewer
      sourceHandle: source
      target: end
      targetHandle: target
      type: custom
      zIndex: 0
      data: {sourceType: agent, targetType: end, isInIteration: false, isInLoop: false}
    - id: reviewer-fail-branch-end_failed-target
      source: reviewer
      sourceHandle: fail-branch
      target: end_failed
      targetHandle: target
      type: custom
      zIndex: 0
      data: {sourceType: agent, targetType: end, isInIteration: false, isInLoop: false}
    viewport: {x: 0, y: 0, zoom: 0.8}
agent_packages:
  reviewer:
    schema_version: 1
    metadata: {name: Reviewer, description: Checks one image, role: ''}
    soul:
      schema_version: 1
      prompt:
        system_prompt: |
          You review one image. Compare it with the subject in the task.
          Report only what you can point at in the image.
          Give `verdict` (ok or needs_fix) and `findings` (Markdown).
      model:
        plugin_id: langgenius/openai_api_compatible
        model_provider: openai_api_compatible
        model: '<model-name>'
        credential_ref: null
        model_settings:
          max_tokens: 8192
      config_files: []
      human: {contacts: [], tools: []}
      env: {variables: [], secret_refs: []}
      tools: {dify_tools: [], cli_tools: []}
      knowledge: {sets: []}
      config_skills: []
      limits: {max_turns: 20}
    omitted_assets: []
    workspace_skills: []
```

To use the official Codex CLI instead, add `harness_style: codex` and `executor_profile: <profile>` to the Soul (a
profile from `GET /v1/apps/<app_id>/agent-executor-profiles` that has the Codex binary), use a model on the Responses
wire and set `model_settings.reasoning_effort` (6.7).

Save the file as `image-review.yml`. Then import, check, publish and run it (the commands use `curl` and `jq`):

```sh
HOST=https://<your-dify-sf-host>

# 1. Sign in.
TOKEN=$(curl -s "$HOST/v1/auth/login" -H 'Content-Type: application/json' \
  -d '{"email":"<email>","password":"<password>"}' | jq -r .access_token)

# 2. Import as a new app. Expect "status": "completed"; keep "app_id".
jq -n --rawfile y image-review.yml '{mode: "yaml-content", yaml_content: $y}' |
  curl -s "$HOST/v1/apps/imports" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d @-

# 3. Check the draft (start the MCP client first, section 4.3). Expect exit 0,
#    "complete": true and "gate_passed": true. Otherwise fix the file, replace the draft (4.2) and check again.
python3 tool/mcp/check_workflow.py --endpoint http://127.0.0.1:39391/mcp --token-file <mcp.key> <app_id>

# 4. Publish, then read the web code.
curl -s -X POST "$HOST/v1/apps/<app_id>/workflows/publish" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"marked_name": "v1"}'
curl -s "$HOST/v1/apps/<app_id>" -H "Authorization: Bearer $TOKEN" | jq -r .site.code

# 5. Run as an end user: passport, upload, streaming run.
PASS=$(curl -s "$HOST/v1/passport" -H "X-App-Code: <web_code>" | jq -r .access_token)
FILE=$(curl -s "$HOST/v1/files/upload" -H "Authorization: Bearer $PASS" -F "file=@photo.png" | jq -r .id)
curl -sN "$HOST/v1/workflows/run" -H "Authorization: Bearer $PASS" -H 'Content-Type: application/json' \
  -d '{"inputs": {"subject": "a red bicycle",
                  "image": {"type": "image", "transfer_method": "local_file", "upload_file_id": "'"$FILE"'"}},
       "response_mode": "streaming"}'
# The stream ends with workflow_finished; its data.outputs has verdict and findings
# (or error_type and error_message from the fail branch).
```

## 8. Pitfalls

- **0 warnings before delivery.** Deliver only a draft whose `check_workflow` answered `complete: true` and
  `gate_passed: true`. An incomplete check (`complete: false`) is not clean, even with 0 items.
- **Default temperature with reasoning models.** A new LLM node has a default `temperature`. Some reasoning models
  refuse sampling parameters. The host model compatibility layer (`tool/model_compat/`) now removes `temperature`,
  `top_p`, `logprobs` and `top_logprobs` when reasoning is on, but only for the official endpoint
  `https://api.openai.com/v1` and the GPT-6 model ids `gpt-6-astra`, `gpt-6-sol`, `gpt-6-luna`, `gpt-6.1-sol`,
  `gpt-6.1-terra`. Other endpoints and models get the parameters as set.
- **Files belong to one app's end user.** Upload the file again with the passport of the app that runs it (5.8).
- **A streaming run stops streaming at a pause.** The `POST /v1/workflows/run` response ends at `workflow_paused`.
  Answer the form (5.6), then follow the run with `GET /v1/workflow/<run_id>/events?continue_on_pause=true`. Do not
  start a new run.
- **Codex counts every model request against `max_turns`**, its retries and sub-agent calls too. Leave a margin, and
  stay within the profile's `max_turns_max`.
- **Codex has no question tool**, needs a Responses-wire model and a profile with the Codex binary (6.7).
- **A retained session needs Codex, Responses, the shell and a disk-workspace profile** (6.9).
- **An invalid Agent package fails the import with `400` and `status: failed`**, including after version confirmation.
  Read the Import object's `error` and fix the file before retrying. Service/configuration failures, such as a missing
  server secrets key, remain `503` errors.
  Servers built before [the import-error fix](https://github.com/kevinzhow/dify-sf/commit/09c99ca203301adf994b42ca98b1855a3ae00e18)
  may instead return `503 unavailable` with the original `400 invalid_param` in the message. Correct the file before
  retrying that validation failure.
- **Edit both task copies in an exported file.** An export writes `agent_job` next to `agent_task` and
  `agent_declared_outputs`. On import, `agent_job.workflow_prompt` and `agent_job.declared_outputs` win. Edit them
  together, or remove `agent_job`.
- **Exports do not carry config files or secret values.** After an import, upload the Soul's config files again and
  set the secrets, or the check reports them and the node fails.
- **Image budget of the `dify` harness.** Outside Codex's Responses route, the task's images may have at most 6 MiB
  together (`AgentFileBudgetExceeded`).
- **`version: '2'` is a string**, and `agent_node_kind` must be `dify_agent`.
- **Wrong credential.** A console token on the public API is `401`. An `X-App-Code` that does not match the passport
  is `404`.

## 9. Further reading

- [`protocol.md`](protocol.md): the HTTP protocol ("Accounts", "Apps", "Publish and versions", "Human input",
  "Published Web and service API").
- [`agent-v2.md`](agent-v2.md): the Agent v2 contract (agent service protocol, harness styles, Codex runtime, sandbox,
  executor profiles, retained sessions, WebSocket transport).
- [`agent-model-inputs.md`](agent-model-inputs.md), [`agent-executor-integration.md`](agent-executor-integration.md),
  [`agent-responses-gateway.md`](agent-responses-gateway.md), [`agent-codex-client-gateway.md`](agent-codex-client-gateway.md),
  [`agent-model-gateway.md`](agent-model-gateway.md), [`agent-runtime-durability.md`](agent-runtime-durability.md).
- [`runtime-files.md`](runtime-files.md): files in workflows.
- [`tool/mcp/README.md`](../tool/mcp/README.md): the read-only MCP server.
- [`agent_service/README.md`](../agent_service/README.md): running the agent service.
