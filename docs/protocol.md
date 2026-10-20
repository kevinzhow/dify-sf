# dify-sf collaboration protocol, version 1.16

Status: stable for step 1. Breaking changes will be listed in the "Changes" section at the very top of this file.

This document is the contract between the server (`server/`) and any client (the Flutter app, the headless
Swift clients used by the chaos/storm harness). It is meant to be sufficient to write a client without
reading the server code. The reference client state machine is `server/Sources/CollabCore/Client.swift`;
section 9 describes the same algorithm in prose.

## Changes

* 1.16 (additive; clients older than 1.16 are unaffected): **human input** (section 2, "Human input (1.16)"). A
  `human-input` node pauses the run (`human_input_required` per form, then `workflow_paused`), the run answers unauthored
  forms through `GET/POST /v1/form/human_input/{token}`, and `GET /v1/workflow/{runId}/events` rebuilds a paused run's
  state from its records and follows it across the resume (Dify's `handleResume`). The node's own form, for the panel's
  "Run this step", is rendered and submitted by `.../workflows/draft/human-input/nodes/{node}/form/{preview,run}`. Forms
  whose node enables an email delivery method are mailed after the pause is durable.
  * `system-features`' `workflow_runtime`: `protocol_version` `1.16`; `human_input` `true`; `draft_run` adds
    `human-input` (`single_node_run` does not: its form endpoints replace a plain run).

* 1.15 (additive; clients older than 1.15 are unaffected): **iterations and loops** (section 2, "Iterations and loops
  (1.15)"), and the rest of Dify's error handling around them.
  * Node types `iteration`, `iteration-start`, `loop`, `loop-start` and `loop-end` run in draft runs (graphs with them were
    refused with `unsupported_node_type`): sequential and parallel iterations (`parallel_nums`), `error_handle_mode`
    (`terminated`, `continue-on-error`, `remove-abnormal-output`), `flatten_output`, the `item` / `index` variables,
    loops with loop variables, break conditions and loop-end nodes, nesting; retries, error strategies, stop and the
    execution limits inside them.
  * The draft run's stream gains Dify's `iteration_started`, `iteration_next`, `iteration_completed`, `loop_started`,
    `loop_next`, `loop_completed` events; nodes inside a container carry its id in `iteration_id` / `loop_id` and in
    `execution_metadata` (with `iteration_index` / `loop_index`); the container nodes themselves have no `node_started` /
    `node_finished` frames (as Dify); an answer inside a container streams its answer when it finishes.
  * `POST /v1/apps/{app}/workflows/draft/iteration/nodes/{node}/run` and `.../draft/loop/nodes/{node}/run` (edit; workflow
    apps) `{"inputs": {...}}`: Dify's iteration / loop single run, the same SSE stream; recorded as a debugging run. The
    plain single node run refuses these nodes as Dify does (`400 invalid_param`).
  * Retried attempts are kept (Dify's retry history): `GET .../workflow-runs/{run}/node-executions` lists each failed
    attempt before its execution (`status` `retry`, `retry_index`).
  * `system-features`' `workflow_runtime`: `protocol_version` `1.15`; `draft_run` adds the five types, `single_node_run`
    adds `iteration` and `loop` (run through their own endpoints).
* 1.14 (additive; clients older than 1.14 are unaffected): **whole draft runs** (section 2, "Draft runs (1.14)"), the
  workflow runtime's engine and the node types Dify's workflows use most, **draft variables** ("Draft variables (1.14)").
  * `POST /v1/apps/{app}/workflows/draft/run` (edit; workflow apps) `{"inputs": {...}, "files": []}`: Dify's draft run, an
    SSE stream of Dify 1.17.1's events (`workflow_started`, `node_started`, `text_chunk`, `node_retry`, `node_finished`,
    `reasoning_chunk`, `workflow_finished`; `event: ping` while idle). The run reads the document at one seq and writes no
    ops: `workflow_runs` and `workflow_node_executions` hold it.
  * `POST /v1/apps/{app}/workflow-runs/tasks/{task}/stop` (edit): Dify's stop. `GET /v1/apps/{app}/workflow-runs` (member):
    the run history; `GET .../workflow-runs/{run}` and `.../workflow-runs/{run}/node-executions` now answer real runs.
    `GET .../workflows/draft/nodes/{node}/last-run` also finds a node's execution within a whole run.
  * Node types (draft runs and single node runs): `start`, `end`, `answer`, `llm`, `if-else`, `variable-aggregator`
    (and the legacy `variable-assigner`), `assigner` (variable assigner v1 / v2), `template-transform`, `code`,
    `http-request`, `list-operator`, `parameter-extractor`, `question-classifier`; error strategies (fail branch, default
    value), retries, execution limits. Iteration and loop (1.15), human input (P4), files (P5), tools, knowledge and agents
    are not run yet: a graph with them is refused (`unsupported_node_type`).
  * Draft variables: Dify's `/workflows/draft/variables...`, `/nodes/{node}/variables`, `/conversation-variables`,
    `/system-variables`, `/environment-variables`; single node runs read missing values from them.
  * `GET /v1/system-features`' `workflow_runtime` becomes `{"protocol_version": "1.14", "single_node_run": [...],
    "draft_run": [...]}` (still only with a model runtime). New configuration: `COLLAB_RUNTIME_MAX_WORKERS`,
    `COLLAB_RUNTIME_MAX_STEPS`, `COLLAB_RUNTIME_MAX_TIME_SECONDS` (and the code sandbox / SSRF proxy keys, "Draft runs").
    New error code `runtime_service_not_configured` (400).
  * Dify files written as JSON with UTF-16 surrogate-pair escapes (`"\uD83E\uDD16"`) import (they were refused).
* 1.13 (additive; clients older than 1.13 are unaffected): **workflow runtime, single node run** (section 2, "Runtime
  (1.13)"): the first part of the Swift workflow runtime (a port of graphon 0.7.0, Dify 1.17.1's engine), with models
  invoked through Dify's plugin daemon.
  * `POST /v1/apps/{app}/workflows/draft/nodes/{node}/run` (edit) `{"inputs": {...}}`: Dify's single node run ("run this
    step") of the draft, answering Dify's `WorkflowRunNodeExecutionResponse` (`200` also when the node failed). The run
    reads the document at its current seq in one consistent read and **writes no ops**: its record goes to
    `workflow_node_executions`, beside the document. In 1.13 only `llm` nodes run.
  * `GET /v1/apps/{app}/workflows/draft/nodes/{node}/last-run` (member): the node's newest execution (Dify's "Last run"),
    `404` without one.
  * `GET /v1/system-features` gains `workflow_runtime` `{"protocol_version": "1.13", "single_node_run": ["llm"]}` (dify-sf
    only) when the server has a model runtime; absent otherwise. Clients run the listed node types on the server and keep
    their local stand-in for the rest.
  * New configuration: `COLLAB_PLUGIN_DAEMON_URL`, `COLLAB_PLUGIN_DAEMON_KEY`, `COLLAB_PLUGIN_DAEMON_TENANT`,
    `COLLAB_PLUGIN_DAEMON_TIMEOUT_SECONDS`. New error codes: `invalid_param`, `unsupported_node_type`,
    `model_runtime_not_configured` (400). Streams are unchanged.
* 1.12 (additive; clients older than 1.12 are unaffected): **account settings** (section 2, "Account settings (1.12)"):
  Dify 1.17.1's account page and Preferences.
  * `PATCH /v1/account/profile` (member, one's own account): `name`, `interface_language` (Dify's 24 languages) and
    `timezone` (an IANA name), Dify's `AccountProfilePatchPayload` (other members, nulls, `avatar` and `interface_theme`:
    `400`). Answers the account.
  * **Changing the email** with six-digit codes by mail, Dify's `/account/change-email` flow: a code to the current
    address, then (with that token) to the new one, then the change: `POST /v1/account/change-email`,
    `.../validity`, `.../reset`, and `.../check-email-unique` for the page's live check. Dify's 5-minute tokens (one
    current token per account), its mail limit (1 per address per minute; the per-IP limit is shared with forgot password)
    and its wrong-code lockout. Needs mail: `GET /v1/system-features` gains `enable_change_email` (true when mail is
    configured).
  * New error codes: `email_already_in_use` (400), `email_change_rate_limit_exceeded`, `email_change_limit` (429). New
    configuration: `COLLAB_AUTH_CHANGE_EMAIL_TOKEN_MINUTES`, `..._SEND_INTERVAL_SECONDS`, `..._MAX_FAILURES`,
    `..._LOCKOUT_SECONDS`. Streams are unchanged.
  * Not part of 1.12: avatars (no file storage; `avatar_url` stays unset and clients show Dify's initial fallback) and
    deleting the account (Dify Cloud only).
* 1.11 (additive; clients older than 1.11 are unaffected): **app detail pages** (section 2, "App detail pages (1.11)"):
  Dify 1.17.1's console API for the pages inside an app, under `/v1/apps/{app}`, with Dify's paths and shapes.
  * **Access Point**: every app has a Web App **site** (created with the app; apps of older servers get theirs at the first
    1.11 start) and the Web App / Service API switches; the app object now carries real `enable_site`, `enable_api`,
    `api_base_url` and `site` (Dify's `AppDetailWithSite`). New: site settings (`POST .../site`), a new site code
    (`POST .../site/access-token-reset`), the switches (`POST .../site-enable`, `.../api-enable`) and **Service API keys**
    (`GET`/`POST .../api-keys`, `DELETE .../api-keys/{key}`; at most 10). Keys are **encrypted at rest** with the secrets key
    and stored with their SHA-256 (Dify stores them in plaintext); the list answers the full key, as Dify's app-key list.
  * **Annotations** (chatflows): list, count, export, create, edit, delete, batch delete, clear, CSV batch import with status
    polling, the Annotation Reply setting and its enable / disable jobs, hit histories. dify-sf stores the setting; nothing
    is embedded or matched (no runtime), and the jobs complete at once.
  * **Publish and versions**: `GET`/`POST .../workflows/publish`, the version list `GET .../workflows` (Dify's draft first,
    pages, `named_only`, `user_id`), one version with its document (`GET .../workflows/{id}`, dify-sf only), one version's
    file (`GET .../export?workflow_id=`, Dify's), rename (`PATCH .../workflows/{id}`), delete, and **restore**
    (`POST .../workflows/{id}/restore` with the caller's `client` and `cseq`): the version replaces the document exactly like
    `POST /replace`, as ordinary ops of the caller's client. A version is a snapshot of the document at head; the newest is
    the published one.
  * **Overview statistics and logs**: Dify's statistic, workflow-log, run, conversation and message endpoints, answering
    Dify's empty shapes (dify-sf has no runtime yet, and Dify never logs debugger runs).
  * **Message feedback** (amendment, still 1.11): `POST .../feedbacks` `{"message_id", "rating": "like"|"dislike"|null,
    "content"}` (member), Dify's like / dislike of a message in the logs: creates, updates or (with `null`) removes the
    member's feedback on the message. The server stores messages and feedback in Dify's shape for a future runtime; until
    one exists there are no messages, so the call answers `404` "Message Not Exists.".
  * **`event: app`** (amendment, still 1.11): the document's event stream carries a best-effort `event: app`
    `{"action":"updated"}` (no `id:`, like `comments`) after a change to what `GET /v1/apps/{app}` answers: edit info, site
    settings, site code reset, a switch that changed, publish (section 5). Dify's editors send `app_meta_update` to their
    peers after Edit Info; dify-sf's server announces it. Clients refetch the app.
  * Roles are Dify's community-edition decorators, **quirks included**: an editor may change the site and the site switch
    and create keys, but not regenerate the site code, switch the API or delete keys (`403`, while Dify's UI shows those
    controls enabled to editors). Reading the published version and the version list needs edit, as in Dify.
  * New error codes: `max_keys_exceeded` (400), `app_not_found` (404: an endpoint of another app mode, Dify's wrong-mode
    error), `no_file_uploaded`, `too_many_files` (400). New configuration: `COLLAB_WEBAPP_BASE_URL`,
    `COLLAB_SERVICE_API_URL`. Streams gain only the best-effort `event: app` (above).
* 1.10 (additive; clients older than 1.10 are unaffected, except that a deleted app's document is gone): **apps** (section 2,
  "Apps (1.10)"): Dify 1.17.1's Studio console API under `/v1/apps`. An **app is a document** (app id = document id); every
  document has exactly one app row with Dify's `name`, `description`, `mode`, icon, `use_icon_as_answer_icon`,
  `max_active_requests`, creator and times (documents of older servers get theirs at the first 1.10 start: name from the
  imported file, else the document id). New endpoints: the app list (`GET /v1/apps`: Dify's pagination, `mode`, `name`,
  `sort_by`, `creator_ids`, `is_created_by_me`; `tag_ids` accepted and ignored), one app (`GET /v1/apps/{app}`), create blank
  (`POST /v1/apps`, workflow or chatflow, seeded like Dify's), import a Dify file as a new app (`POST /v1/apps/imports`,
  `.../{import}/confirm`: Dify's `Import` answers and version confirmation), edit info (`PUT`), duplicate (`POST .../copy`,
  secrets re-encrypted for the copy), delete (`DELETE`, soft), export (`GET .../export`, Dify's `{data}`), stars per account
  (`POST`/`DELETE .../star`, `GET /v1/apps/starred`).
  * The app row is the source of truth for name, description and icon: `GET /meta` and the export write the `app` section
    from it, and an overwrite from a file (`POST /replace`) takes the file's name, description and icon, as Dify does.
    These are plain REST writes (last write wins, as in Dify), not ops.
  * **Deleting an app** makes its document answer `404 app_deleted` on every `/v1/docs/{doc}/...` call; its open event
    streams end (the reconnect gets the 404). Clients that see `app_deleted` should stop retrying and drop their journal.
  * "Last modified" (`updated_at`, the list's default sort) also moves with every committed op (a documented deviation from
    Dify, whose draft saves do not touch the app row).
  * New error codes: `app_deleted` (404), `unsupported_app_mode` (400). Streams accept `proto=1.10` (as 1.9).
* 1.9 (additive; clients older than 1.9 are unaffected): **model providers** (section 2, "Model providers (1.9)"): Dify 1.17.1's
  console API for the workspace's LLM providers, under `/v1/workspace/`: the provider catalog (`GET model-providers/summary`,
  `GET model-providers`), the active models per type for the selectors (`GET models/model-types/{type}`), default models
  (`GET`/`POST default-model`; without a stored default the first active model is picked **and stored**, as in Dify), parameter
  rules (`GET model-providers/{provider}/models/parameter-rules`), a provider's model list with statuses and enable/disable,
  provider credentials (several per provider, one current: create, update, delete, switch, validate), custom models and their
  credentials, and public provider icons. Shapes are Dify's (the `data` envelopes, `custom_configuration`, statuses
  `active`/`no-configure`/`disabled`/`credential-removed`); provider ids are Dify's long form `org/plugin/provider`, three path
  segments. Provider definitions are the official ones (langgenius/dify-official-plugins, vendored at a pinned commit).
  Documents and ops are unchanged (an LLM node's `model` stays in its config). A client that gets `404` from an older server
  has no providers.
  * **Secrets at rest** are encrypted from 1.9 on (AES-256-GCM with the server's `COLLAB_SECRETS_KEY`): model provider
    credentials and the 1.7 secret environment variables (plaintext rows of older servers are encrypted at startup). A server
    without a key refuses to store any secret (`503 secrets_key_missing`) instead of storing plaintext; this also applies to
    `POST /secrets`, and to imports and replacements of files with secret values. Credentials are never sent back in clear:
    reads mask secret fields with Dify's mask, and an update may send `[__HIDDEN__]` for a secret that stays as it is.
  * Saving credentials checks them with **one cheap request to the provider** (switch: `COLLAB_MODELS_VALIDATE`).
  * Writes, credential reads and validation need **privileged** (owner, admin); reads any member; icons are public.
  * New error codes: `credential_validation_failed` (400), `credential_name_exists` (409), `secrets_key_missing` (503). CORS
    also allows `PATCH`. Streams accept `proto=1.9` (as 1.8).
* Additive, no version change: **password reset** (section 2, "Password reset"): Dify 1.17.1's forgot-password flow with a
  six-digit code by mail (`POST /v1/forgot-password`, `/v1/forgot-password/validity`, `/v1/forgot-password/resets`), the
  system features the sign-in page reads (`GET /v1/system-features`: `is_email_setup`), the server's SMTP configuration,
  and, dify-sf only, owners' and admins' one-time reset links for servers without mail
  (`POST /v1/workspace/members/{id}/reset-password-link`). Setting a password this way revokes every session of the account.
  New error codes: `mail_not_configured`, `invalid_email`, `email_code_error`, `password_mismatch`, `account_not_found` (400),
  `email_send_ip_limit`, `password_reset_rate_limit_exceeded`, `email_password_reset_limit` (429).
* Additive, no version change: **replacing a document from a Dify workflow file**, `POST /v1/docs/{doc}/replace` (Dify's
  "Import DSL" in the editor, which overwrites the open app's draft; section 2, "Replacing a document"). The server commits
  the replacement as ordinary ops of the caller's client id (cseqs reserved by the caller, section 9, "Replacing the
  document"), all in one transaction; other clients see ordinary commits. The op vocabulary is unchanged. New error codes:
  `version_unconfirmed` (400), `conflict`, `outstanding_ops`, `cseq_used` (409).
* Clarification, no version change: **a `403 forbidden` on `POST /ops` is final** (section 9, "Refused submissions"): the
  client finishes the waiting ops as rejected with the local reason `forbidden` (not saved, dropped from the journal),
  stops sending until its account may edit again, and then sends `floor` first. The server is unchanged.
* 1.8 (**breaking: every client must sign in; old clients get `401`**): **accounts** (email + password, Dify 1.17.1's
  community edition: one workspace per server). Server and clients of this repository are updated together; there is no
  compatibility mode for clients older than 1.8.
  * New endpoints (section 2, "Accounts"): `GET`/`POST /v1/setup` (Dify's install: the first account is the workspace
    owner), `POST /v1/auth/login`, `/v1/auth/refresh`, `/v1/auth/logout`, `GET /v1/account`, `PUT /v1/account/name`,
    `PUT /v1/account/password`, `GET /v1/workspace/members`, `POST /v1/workspace/members/invite-email`,
    `PUT /v1/workspace/members/{id}/update-role`, `DELETE /v1/workspace/members/{id}`, `POST /v1/activate/check`,
    `POST /v1/activate`. New error codes: `unauthorized` (401), `invalid_credentials` (401), `forbidden` (403),
    `account_banned` (403), `setup_done` (409), `email_taken` (409), `login_rate_limited` (429), `invalid_password` (400),
    `invalid_token` (400), `invalid_role` (400), `cannot_operate_self` (400).
  * **Every other `/v1` endpoint requires `Authorization: Bearer <access token>`** (else `401 unauthorized`); `/healthz`,
    setup, login, refresh and activation do not. The event stream also accepts `?access_token=` (for the browser's native
    `EventSource`, which cannot set headers). Tokens are opaque; access tokens live 60 minutes, refresh tokens 30 days and
    rotate on use. CORS allows the `Authorization` header.
  * **Roles** (Dify's): `owner`, `admin`, `editor` may write (ops, document creation and import, secrets, comment writes);
    `normal` and `dataset_operator` only read (snapshot, stream, export, meta, comments): their `POST /ops` is refused as a
    whole with `403 forbidden`. Only `owner` and `admin` export with `include_secret=true` and manage members.
  * **Client ids belong to accounts.** `POST /v1/docs/{doc}/clients` binds the issued id to the caller's account; a client
    id the client chose itself is bound to the first account that uses it (`POST /ops` or `PUT /clients/{client}`). Ops under
    a client id bound to another account are refused as a whole with `403 forbidden`, and so is a stream opened with such a
    `client`. A `name` in `POST /clients` is ignored and `PUT /clients/{client}` no longer names anything (it binds, see
    section 2); names are the accounts' names. The directory changes shape: `GET /clients` answers
    `{"clients":{"<client id>":{"account":"<account id>","name":"Bo","avatar_url":"..."?}}}`. `byName` in conflict notices is
    the author's account name.
  * **Comments are by accounts**: `created_by`, `resolved_by` and mentions are account ids (with `_name` and `_avatar_url`
    members); bodies no longer carry `client` (the author is the caller); mentions are sent as `mentioned_user_ids` (Dify's
    name) and filtered to workspace members; mention entries are `{"account","name"?,"avatar_url"?}`. Any of the author's
    clients and sessions may edit. Writes need the edit role (Dify's `edit_permission_required`), reads any member. New
    `GET /v1/docs/{doc}/comments/mention-users` (Dify's mention candidates: the members).
  * Unchanged: ops, commits, snapshots, the stream's events, the conflict rules. `restoreNode` stays "only the deleter" **per
    client id**, not per account (undo stacks belong to one app instance; section 9). Streams accept `proto=1.8` (as 1.7).
* Additive, no version change: **canvas comments** (Dify's workflow comments): `/v1/docs/{doc}/comments` endpoints beside
  the document (section 2, "Comments") and a best-effort stream event `comments` without an `id:` (section 5). Clients that do
  not use comments are unaffected (they ignore the unknown event). CORS now also allows `DELETE`.
* 1.7 (additive; clients older than 1.7 are unaffected): **document-level registers** (`app`): Dify's environment
  variables, conversation variables and features live in the collaborative document instead of read-only import metadata.
  * The document gains a map `app` of registers (snapshot key `"app"`, omitted when empty). Ops address it through the
    reserved node id **`$app`**, which always exists: `setField` with a `config` field, `insertItem`, `removeItem` and
    `updateItem` work on it exactly as on a node's config, under the same conflict rules (stale-write rule, same-value rule,
    overlap rules, item tombstones). Everything else naming `$app` (`removeNode`, `moveNode`, `restoreNode`, a `title` field,
    an edge endpoint) is `invalid`, and so is a node id starting with `$` in `addNode`/`restoreNode`. Values in `$app` contain
    no references (`$ref`/`$broken`: `invalid`). Exact rules: section 6, "Document-level registers".
  ```json
  {"t":"insertItem","node":"$app","path":["environment_variables"],"item":{"id":"6f1c...","value":{"id":"6f1c...","name":"region","value":"eu","value_type":"string","description":""}},"after":null}
  {"t":"setField","node":"$app","field":{"k":"config","path":["features","opening_statement"]},"value":"Hello"}
  ```
  * The Dify mapping (import/export) uses three keys: `environment_variables` and `conversation_variables` (keyed lists,
    item id = the variable's `id`, item value = the Dify variable object unchanged) and `features` (a map, Dify's
    `workflow.features` unchanged). Import moves them from the file into `app`; export writes them from the document.
    `GET /v1/docs/{doc}/meta` keeps its shape and serves them from the document at head.
  * **Secret environment variables** never put their value into ops, the log, snapshots or the stream. New endpoint
    `POST /v1/docs/{doc}/secrets` `{"value":"..."}` -> `201 {"ref":"sec-<32 hex>","masked":"<mask>"}` stores the plaintext on the
    server; the client then writes the variable with ordinary item ops, with `"value": "<mask>"` and an extra member
    `"secret_ref": "<ref>"`. Export blanks secrets unless `?include_secret=true` (section 2).
  * Streams: a commit that writes `$app` is protocol 1.7. A stream opened without `proto` >= `1.7` never carries one (snapshot
    instead of replay, live stream ended), exactly like `restoreNode` for streams below 1.6. Clients send `proto=1.7`. A
    snapshot always has its `app` key (when non-empty) whatever the stream's `proto`: decoders ignore keys they do not know,
    and the `fieldStamps` rows under node `$app` and the item tombstones are rows of the 1.6 shape (section 3).
* Additive, no version change: **`GET /v1/docs/{doc}/meta`**, the Dify app metadata of a document (section 2).
* 1.6 (additive; clients older than 1.6 are unaffected): **restoring a deleted node** (undo of a delete).
  * New op `restoreNode`: `{"t":"restoreNode","node":Node,"edges":[Edge,...]}` carries the node as it was before the delete
    (id, type, title, position, config; the config may contain `$broken` markers) and the edges the delete removed, with their
    original ids (`edges` may be empty or omitted). The node id and those edge ids leave the tombstones, and `$broken` references
    to the node turn back into references. **Only the client whose delete made the tombstone may restore the node** (undo is
    only of one's own operations); anyone else gets the new reject reason `notDeleter`. Exact rules: section 6, "Restore";
    reasons: section 7.
  * The event stream takes a new query parameter `proto` (the protocol version the client implements, `1.6`). A stream opened
    without it, or with a lower version, **never carries a `restoreNode` commit**: if its catch-up range contains one, it gets a
    `snapshot` at head instead of the replay; if one is committed while it is live, the server ends the stream (the client
    reconnects and gets that snapshot). Both are behaviours every client already has (section 5). Clients that send `proto=1.6`
    must decode and apply `restoreNode` (clients that pre-check locally, e.g. the Dart port, run its validation too).
  * Documents keep the 1.5 shape. A restore adds no new kind of field: the stamp it puts on the whole config is an ordinary
    FieldKey `{"k":"config","path":[]}`, which 1.5 decoders read and whose overlap rule (a prefix of every path) they already apply.
* 1.5 (additive; clients that decode values must accept it): **fractional numbers.** A config value may be a JSON number
  with a fractional part (Dify settings such as `temperature: 0.7`). Every number has one form: integral numbers are
  integers (on the wire `2.0` is the number 2 and is stored and served as `2`); a fractional number is a finite double.
  Encoders write the shortest representation that reads back to the same double.
* 1.4 (**stricter validation; clients that pre-check locally, e.g. the Dart port, must apply it**): **declared outputs are
  part of reference integrity.** A node's declared outputs are the names of the items of its `outputs` keyed list (an
  item's `name`, or its id if it has none); a node without an `outputs` list accepts references to any output name.
  * Writing a live reference to a node with declared outputs that names none of them is refused with `danglingReference`
    (the same reason as a reference to a missing node).
  * Removing an output item, or renaming it (`updateItem` changing its `name`), takes its name away unless another item
    still declares it. Like a node delete, this rewrites every reference to that name into a `$broken` marker in the same
    commit, and it conflicts with any other client's write, after the op's `base`, to a field it would rewrite.
  * Invariant I4 (no dangling references) covers declared outputs too.
* 1.3 (additive and optional; old clients are unaffected): **display names**.
  * `POST /v1/docs/{doc}/clients` accepts an optional body `{"name":"Bo"}` (1-64 bytes, no control characters) and answers
    `201 {"client":"s-...","name":"Bo"}` (`name` only if given).
  * `PUT /v1/docs/{doc}/clients/{client}` with `{"name":"Bo"}` names (or renames) a client id the client chose itself:
    `200 {"client","name"}`. `GET /v1/docs/{doc}/clients` returns the directory `200 {"clients":{"<client id>":"<name>", ...}}`
    (only clients that registered a name; refetch it when you see an unknown author id).
  * `conflict` reject reasons gain an optional field `byName` (the author's display name, present only when `by` registered one at
    the time the response is produced: a retransmit may carry a name that was registered later). `by` is unchanged.
  * Commit events keep carrying only the client id; resolve names through the directory.
* 1.2 (**clarification of the same-value rule; clients that keep their own conflict tracking, e.g. the Dart port, must apply it**):
  An accepted equal-value write is a **pure no-op for conflict tracking**. It is committed (acked, it gets a `seq`, it is in the log)
  but applying it changes *nothing* in the document's version metadata: no register stamp, no last-writer, no per-client "touched"
  entry. Exactly: when applying `setField` (title or config path), `updateItem`, the current value of that register equals the
  new value -> return before stamping. (Reason, found by the TLA+ model: if the equal-value write took over the stamp, the same
  client's NEXT stale write to the register would be exempt as "last writer is me" and silently overwrite a value it never saw.
  Trace: c1 sends f:=v1 then f:=v2, both base 0; c2 concurrently sends f:=v1 and is sequenced first; c1's first write is
  equal-valued and acked; c1's second write must still be rejected with `conflict` naming c2.) The server and `CollabCore`
  already behaved this way; this entry makes the rule explicit. Regression scenario: S9d in the simulator.
* 1.1 (additive; no existing field or behaviour changed for conforming clients):
  * **CORS** is supported (section 2).
  * **`base` may be non-monotone**: successive ops of one client may carry decreasing bases (a typing draft keeps the version it
    started from). This is explicitly legal and the server does not assume otherwise (section 4).
  * **Outcome semantics** for crashed/volatile clients are spelled out: `rejected` and `lost` both mean "not saved"; which one a
    client reports is defined in section 9 ("Finishing").
  * **Client id collisions**: new `POST /v1/docs/{doc}/clients` issues unique client ids, and the server now refuses a retransmit whose
    content differs from the op first stored under the same `(client, cseq)` with the new reject reason `clientIdInUse`
    (sections 2, 4, 7, 9). Existing clients are unaffected (a genuine retransmit is byte-identical).
* 1.0: initial version.

## 1. Overview

One **document** (a workflow graph) is edited by many clients at once.

* Clients send **ops** (small edits) with `POST /v1/docs/{doc}/ops`. The response says, per op, whether it was
  committed (`ack` with its global sequence number) or `reject`ed (with a reason).
* The server publishes every committed op, in global order, on a **Server-Sent Events** stream
  `GET /v1/docs/{doc}/events`. The SSE event id is the global sequence number (`seq`). A reconnecting client sends
  `Last-Event-ID` and resumes exactly where it stopped. A client that is too far behind (or has no state) gets a
  `snapshot` event instead.
* There is no WebSocket and no server-side session state per connection. Every request is self-contained and carries
  its bearer token (1.8); the only server memory about a client is durable (in Postgres).

Guarantees (the three promises of the product):

1. **No acknowledged edit is lost.** An op is acknowledged (`ack`) only after it is committed in the database.
2. **No silent overwrite of newer data.** A content write based on a stale version is rejected with a conflict
   notice unless it writes the value that is already there (section 6).
3. **All clients converge.** Every client that has applied the committed log up to `seq = N` has an identical
   document (including version metadata).

Transport conventions:

* Base URL: `http://host:port`. All paths are under `/v1` except `/healthz`.
* Authentication (1.8): every `/v1` request except setup, login, refresh and activation sends
  `Authorization: Bearer <access token>` (section 2, "Accounts").
* Bodies are UTF-8 JSON (`Content-Type: application/json`). Keys in server output are sorted, clients may send any order.
* Numbers in documents are **64-bit integers only**. Floating point is not representable (a float in a request makes
  that op invalid). Encode decimals as scaled integers or strings.
* `seq` is the global, gapless, per-document sequence number of committed ops: 1, 2, 3, ... Seq 0 is the seed
  document before any op.
* Identifiers: `doc`: `[A-Za-z0-9_-]{1,64}`. `client`: `[A-Za-z0-9_.:-]{1,64}` (a UUID is fine). Node, edge and
  list-item ids: non-empty strings up to 128 bytes, chosen by the client, **globally unique and never reused** (use
  UUIDs).

## 2. Endpoints

Access (1.8): **public** = no token; **member** = any signed-in member of the workspace; **edit** = the `owner`, `admin` or
`editor` role; **privileged** = `owner` or `admin`. Without a valid access token a non-public endpoint answers `401 unauthorized`;
with a role that is not enough, `403 forbidden` (section "Accounts").

| Method | Path | Access | Purpose |
|---|---|---|---|
| GET | `/healthz` | public | Liveness + database check. `200 {"status":"ok"}` or `503`. |
| GET, POST | `/v1/setup` | public | Install: is there a workspace yet; create the owner (1.8, "Accounts"). |
| POST | `/v1/auth/login`, `/v1/auth/refresh` | public | Sign in; new token pair (1.8). |
| POST | `/v1/auth/logout` | member | Revoke the session's tokens (1.8). |
| GET | `/v1/account` | member | The caller's account (1.8). `PUT /v1/account/name`, `PUT /v1/account/password` change it. |
| PATCH, POST | `/v1/account/profile`, `/v1/account/change-email...` | member | 1.12: one's own name, language, time zone; changing one's email ("Account settings"). |
| GET | `/v1/workspace/members` | member | The members (1.8). |
| POST, PUT, DELETE | `/v1/workspace/members/...` | privileged | Invite, change a role, remove (1.8). |
| POST | `/v1/activate/check`, `/v1/activate` | public | Accept an invitation (1.8). |
| GET | `/v1/system-features` | public | Sign-in options; whether the server sends mail ("Password reset"). |
| POST | `/v1/forgot-password`, `/v1/forgot-password/validity`, `/v1/forgot-password/resets` | public | Reset a forgotten password with a code by mail ("Password reset"). |
| POST | `/v1/workspace/members/{id}/reset-password-link` | privileged | dify-sf only: a one-time reset link for a member ("Password reset"). |
| POST | `/v1/docs` | edit | Create a document with a server-generated id. Body optional: `{"template":"example"\|"empty"}`. `201 {"id","head":0,"created":true}`. |
| PUT | `/v1/docs/{doc}` | edit | Create the document if absent (idempotent). Body optional as above. `201` if created, `200` if it existed: `{"id","head","created":bool}`. |
| GET | `/v1/docs/{doc}` | member | Metadata: `200 {"id","head"}`, `404` if unknown. |
| GET | `/v1/docs/{doc}/snapshot` | member | Full document at the current head: `200 {"seq":N,"doc":Document}`. For bootstrapping/debugging; the stream also delivers snapshots. |
| POST | `/v1/docs/{doc}/clients` | member | Issue a fresh unique client id bound to the caller's account: `201 {"client":"s-<32 hex>","account":"<account id>","name":"<account name>"}`, `404` if the document is unknown. A body is ignored (1.3's `name`; 1.8: names are the accounts'). Use one id per client *instance* (section 9). |
| PUT | `/v1/docs/{doc}/clients/{client}` | member | 1.8: binds a client id the client chose itself to the caller's account if nobody has it yet: `200 {"client","account","name"}`; `403 forbidden` if it belongs to another account. A body is ignored (it named the id in 1.3). |
| GET | `/v1/docs/{doc}/clients` | member | Directory of bound client ids: `{"clients":{"<client id>":{"account":"<account id>","name":"Bo","avatar_url":"..."?}}}` (1.8). |
| GET | `/v1/docs/{doc}/meta` | member | Dify app metadata (mode, name, variables, features): `200 {...}` (below), `404` if unknown. Optional, additive. |
| GET | `/v1/docs/{doc}/comments`, `/comments/{id}`, `/comments/mention-users` | member | Canvas comments: list, one, mention candidates (below). |
| POST, PUT, DELETE | `/v1/docs/{doc}/comments/...` | edit | Create, edit/move (author only), delete (author only), resolve, reply (below). |
| POST | `/v1/docs/{doc}/secrets` | edit | 1.7. Store the plaintext of a secret environment variable: body `{"value":"..."}` -> `201 {"ref":"sec-<32 hex>","masked":"..."}` (below); `400` without a string `value`, `404` if the document is unknown. |
| POST, PUT | `/v1/docs/import`, `/v1/docs/{doc}/import` | edit | Create a document from a Dify workflow file (1.5). |
| POST | `/v1/docs/{doc}/replace` | edit | Overwrite the document with a Dify workflow file, as ops of the caller's client (below). |
| GET | `/v1/docs/{doc}/export` | member | The document as a Dify workflow file (YAML, or `?format=json`); secret environment variables are `""` unless `?include_secret=true` (1.7), which needs **privileged** (1.8; `403 forbidden` otherwise). |
| POST | `/v1/docs/{doc}/ops` | edit | Submit a batch of ops (section 4). 1.8: the whole batch is `403 forbidden` for a read-only role or a client id bound to another account. |
| GET | `/v1/docs/{doc}/events` | member | SSE stream (section 5). The token may also come as `?access_token=`. |
| GET | `/v1/workspace/model-providers`, `.../summary`, `/v1/workspace/models/model-types/{type}`, `/v1/workspace/default-model`, `.../{provider}/models`, `.../{provider}/models/parameter-rules` | member | 1.9: providers, models, default models, parameter rules ("Model providers"). |
| POST, PUT, PATCH, DELETE | `/v1/workspace/default-model`, `.../{provider}/credentials...`, `.../{provider}/models...` | privileged | 1.9: default models, credentials, custom models, enable/disable ("Model providers"); credential reads too. |
| GET | `/v1/workspace/model-providers/{provider}/{icon_type}/{lang}` | public | 1.9: a provider icon (SVG/PNG). |
| GET | `/v1/apps`, `/v1/apps/starred`, `/v1/apps/{app}` | member | 1.10: the app list, the caller's starred apps, one app ("Apps"). |
| POST, DELETE | `/v1/apps/{app}/star` | member | 1.10: star / unstar for the caller (idempotent). |
| POST, PUT, DELETE | `/v1/apps`, `/v1/apps/imports`, `/v1/apps/imports/{import}/confirm`, `/v1/apps/{app}`, `/v1/apps/{app}/copy` | edit | 1.10: create, import, confirm an import, edit info, delete, duplicate ("Apps"). |
| GET | `/v1/apps/{app}/export` | edit | 1.10: the app as a Dify file, `{"data":"<yaml>"}`; `?include_secret=true` needs **privileged**. |
| POST | `/v1/apps/{app}/site`, `/v1/apps/{app}/site-enable` | edit | 1.11: Web App settings; the Web App switch ("App detail pages"). |
| POST | `/v1/apps/{app}/site/access-token-reset`, `/v1/apps/{app}/api-enable` | privileged | 1.11: a new site code; the Service API switch. |
| GET, POST | `/v1/apps/{app}/api-keys` | edit | 1.11: list / create Service API keys. |
| DELETE | `/v1/apps/{app}/api-keys/{key}` | privileged | 1.11: delete a key (the app is looked up first: `404` before `403`). |
| GET, POST, DELETE | `/v1/apps/{app}/annotations...`, `/v1/apps/{app}/annotation-setting`, `.../annotation-reply/...`, `.../annotation-settings/{id}` | edit | 1.11: annotations (chatflows) and the Annotation Reply setting; `GET .../annotations/count` is **member**. |
| GET, POST, PATCH, DELETE | `/v1/apps/{app}/workflows`, `.../workflows/publish`, `.../workflows/{id}`, `.../workflows/{id}/restore` | edit | 1.11: publish, versions (one version with its document: dify-sf only), restore; `GET /v1/apps/{app}/export?workflow_id=` exports one version. |
| GET | `/v1/apps/{app}/statistics/...`, `/v1/apps/{app}/workflow/statistics/...`, `/v1/apps/{app}/workflow-app-logs` | member | 1.11: Overview statistics and workflow logs (empty until published runs exist). |
| POST | `/v1/apps/{app}/workflows/draft/run` | edit | 1.14: a draft run, Dify's SSE events ("Draft runs"). |
| POST | `/v1/apps/{app}/workflow-runs/tasks/{task}/stop` | edit | 1.14: stop a draft run. |
| GET | `/v1/apps/{app}/workflow-runs`, `.../workflow-runs/{run}`, `.../workflow-runs/{run}/node-executions` | member | 1.14: run history, a run, its node executions ("Draft runs"). |
| POST | `/v1/apps/{app}/workflows/draft/iteration/nodes/{node}/run`, `.../draft/loop/nodes/{node}/run` | edit | 1.15: an iteration / loop single run, Dify's SSE events ("Iterations and loops"). |
| GET, PATCH, PUT, DELETE | `/v1/apps/{app}/workflows/draft/variables...`, `.../draft/nodes/{node}/variables`, `.../draft/{conversation,system,environment}-variables` | edit | 1.14: draft variables ("Draft variables"). |
| GET | `/v1/apps/{app}/chat-conversations...`, `/v1/apps/{app}/chat-messages` | edit | 1.11: chat logs (empty until a runtime exists). |
| POST | `/v1/apps/{app}/feedbacks` | member | 1.11: a member's like / dislike of a message in the logs ("Overview statistics and logs"). |
| POST | `/v1/apps/{app}/workflows/draft/nodes/{node}/run` | edit | 1.13: run one node of the draft ("Runtime"). |
| GET | `/v1/apps/{app}/workflows/draft/nodes/{node}/last-run` | member | 1.13: the node's last run ("Runtime"). |

The `example` template is a small workflow: `start` -> `llm` -> `code` -> `answer`, with a variable reference from the
LLM prompt/code node to the start node and a keyed list (`outputs`) on the code node. `empty` has a single `start`
node.

### Accounts (1.8)

Email + password accounts as in Dify 1.17.1's community edition: **one workspace per server**, created by the install
(`POST /v1/setup`); everyone else joins by invitation. No email-code sign-in, no third-party sign-in; mail is optional and
only resets passwords ("Password reset").

**Accounts and roles.** An account has an `id` (a UUID), an `email` (unique ignoring case), a `name`, an optional
`avatar_url`, a `status` (`active`; `pending` = invited, not activated; `banned`), optional `interface_language` and
`timezone`, `created_at` and `last_login_at`. Each member has one role (Dify's `TenantAccountRole`):

| role | edits workflows (ops, create, import, secrets, comment writes) | members, `include_secret` | reads, streams, exports, comments |
|---|---|---|---|
| `owner` (exactly one: the installer) | yes | yes | yes |
| `admin` | yes | yes | yes |
| `editor` | yes | no | yes |
| `normal`, `dataset_operator` | no (`403 forbidden`; the editor is read-only, Dify's `nodesReadOnly`) | no | yes |

**Passwords** follow Dify's rule `^(?=.*[a-zA-Z])(?=.*\d).{8,}$` (at least 8 characters with a letter and a digit; else `400
invalid_password` with Dify's message) and Dify's storage (PBKDF2-HMAC-SHA256, 10000 iterations, 16-byte random salt,
base64), so accounts can move between Dify and dify-sf.

**Tokens.** Sign-in answers a pair of opaque tokens (32 random bytes, base64url; the server keeps only their SHA-256):

* the **access token** (60 minutes) goes into every request: `Authorization: Bearer <access token>`;
* the **refresh token** (30 days) gets a new pair from `POST /v1/auth/refresh`. Refreshing **rotates**: the refresh token is
  spent (a second use is `401`); the old access token keeps working until it expires. Every token of one sign-in belongs to
  one session; `POST /v1/auth/logout` revokes all of them (other sign-ins of the same account stay).
* A request with no, an unknown, an expired or a revoked access token gets `401 unauthorized`. Clients refresh once and repeat
  the request; if the refresh is refused too, the user is signed out. (`401` never means anything else: wrong passwords at
  login are `401 invalid_credentials` from an endpoint that takes no token.)

Responses that sign someone in (`setup`, `login`, `activate`) are
`{"access_token":"...","refresh_token":"...","account":Account}`; `refresh` answers `{"access_token","refresh_token"}`.
`Account` = `{"id","email","name","avatar_url"?,"role","interface_language"?,"timezone"?,"created_at"}` (times are ISO-8601 UTC
with milliseconds; absent members are unset).

| Method | Path | Body | Answer |
|---|---|---|---|
| GET | `/v1/setup` | - | `200 {"step":"not_started"\|"finished"}` (Dify's `/console/api/setup`) |
| POST | `/v1/setup` | `{"email","name","password","interface_language"?,"timezone"?}` | `201` signed in as the **owner**; only while no account exists, else `409 setup_done`. `name`: 1-30 characters. `language` is accepted for `interface_language` (Dify's name) |
| POST | `/v1/auth/login` | `{"email","password","remember_me"?,"invite_token"?}` | `200` signed in. `401 invalid_credentials` for an unknown email and for a wrong password alike (same body); `429 login_rate_limited` (below); `403 account_banned`; `403 forbidden` for an account that is no longer a member. `remember_me` is accepted and ignored (the refresh token lasts 30 days anyway). `invite_token`: Dify's way in for an invited account without a password: the password given becomes its password |
| POST | `/v1/auth/refresh` | `{"refresh_token"}` | `200 {"access_token","refresh_token"}`; `401 unauthorized` if it is unknown, spent, expired, or the account was removed |
| POST | `/v1/auth/logout` | - | `204`; revokes the session |
| GET | `/v1/account` | - | `200 Account` |
| PUT | `/v1/account/name` | `{"name"}` | `200 Account`; 3-30 characters (Dify) |
| PUT | `/v1/account/password` | `{"password","new_password","repeat_new_password"}` | `204`; `400 invalid_password` if the current password is wrong, the new ones differ, or the new one breaks the rule |
| GET | `/v1/workspace/members` | - | `200 {"accounts":[{"id","name","email","avatar_url"?,"role","status","last_login_at"?,"created_at"}]}`, owner first |
| POST | `/v1/workspace/members/invite-email` | `{"emails":[...],"role"}` | `201 {"invitation_results":[{"email","status":"success","url":"/activate?email=...&token=..."} \| {"email","status":"already_member","message"} \| {"email","status":"failed","message"}]}`; privileged; `role` any but `owner` (`400 invalid_role`); 1-100 emails |
| PUT | `/v1/workspace/members/{id}/update-role` | `{"role"}` | `200 {"result":"success"}`; privileged; not `owner` (`400 invalid_role`); not oneself (`400 cannot_operate_self`); never the owner (`403 forbidden`); `404` for a non-member |
| DELETE | `/v1/workspace/members/{id}` | - | `200 {"result":"success"}`; privileged; not oneself, never the owner; revokes the member's sessions. A never-activated (pending) account is deleted; an active one stays (its comments keep their author) but cannot sign in to the workspace until invited again |
| POST | `/v1/activate/check` | `{"token"}` | `200 {"is_valid":true,"data":{"email","workspace_name","account_status":"pending","requires_setup":true}}` or `{"is_valid":false}` (also `GET /v1/activate/check?token=`, Dify's form; the last two members are Dify's and always these values for a valid link) |
| POST | `/v1/activate` | `{"token","name","password","interface_language"?,"timezone"?}` | `200` signed in; sets the invited account's name and password and activates it. `400 invalid_token` for an unknown, expired (72 hours) or used token |

* **Invitations.** Invitations are not mailed: as Dify does when mail is not configured, the answer carries each activation link
  (relative to the web app; the app builds `/activate?token=...` into its own URL). Inviting a new email creates a `pending`
  account with the role; inviting an existing account that is no longer a member makes it a member again (it signs in with
  its old password; its link is not valid for activation). The workspace's name is `"<owner name>'s Workspace"` (Dify's default).
* **Login rate limit** (Dify's `login_error_rate_limit`): every failed sign-in for an email counts and renews a 24-hour window;
  with **more than 5** failures in the window the email is locked: `429 login_rate_limited`, even with the right password,
  until the window passes. A successful sign-in clears the count. The count is kept per server process
  (`COLLAB_AUTH_LOGIN_MAX_FAILURES`, `COLLAB_AUTH_LOGIN_LOCKOUT_SECONDS`).
* **Configuration**: `COLLAB_AUTH_ACCESS_TOKEN_MINUTES` (60), `COLLAB_AUTH_REFRESH_TOKEN_DAYS` (30),
  `COLLAB_AUTH_INVITE_EXPIRY_HOURS` (72).
* **Token in the URL** (`?access_token=`) is accepted by `GET /v1/docs/{doc}/events` only, for the native `EventSource`. The
  server never logs query strings; clients that can set headers (all of ours: they read the stream with `fetch`/HTTP streaming)
  send the header.
* **Client ids and identity.** A client id belongs to one account: the one that obtained it (`POST /clients`) or, for an id
  the client chose itself, the first one that used it (`POST /ops`, `PUT /clients/{client}`). Ops under someone else's client
  id are refused as a whole (`403 forbidden`, nothing applied): nobody can act as another account. Several client ids of one
  account (tabs, devices) are one user: the directory maps them to the account, comments and presence are per account. A
  stream's `client` parameter must be the caller's own id or an unbound one (`403` otherwise; an unbound id stays unbound).
* **Test harnesses** use real accounts: the chaos/storm harness installs a test account on its fresh database
  (`POST /v1/setup`) or signs in with it; all its clients share that account, each with its own client id. There is no
  test-only switch that turns authentication off.

### Password reset

Additive (no protocol version change). Dify 1.17.1's forgot-password flow (`/console/api/forgot-password`, its web app's
`/reset-password` pages): a six-digit code by mail, then a new password. Servers without mail answer `400 mail_not_configured`
to the first step and say so in the system features, where the sign-in page disables "Forgot your password?"; there, owners
and admins hand out one-time reset links instead (dify-sf only; Dify's community edition resets passwords on its command line).

| Method | Path | Body | Answer |
|---|---|---|---|
| GET | `/v1/system-features` | - | `200 {"enable_email_code_login":false,"enable_email_password_login":true,"is_allow_register":false,"is_email_setup":bool}` (the members of Dify's `/console/api/system-features` the sign-in page reads). `is_email_setup`: mail is configured; 1.12: `enable_change_email` (the account page offers changing the email: mail is configured) |
| POST | `/v1/forgot-password` | `{"email","language"?}` | `200 {"result":"success","data":"<token>"}`: a code went to the email. **The same answer for an email without an account** (that address gets Dify's "not associated with any account" mail instead; no code). `language`: `zh-Hans` mails in Chinese, anything else in English. `400 bad_request` for an invalid email, `400 mail_not_configured` without mail, `429 email_send_ip_limit`, `429 password_reset_rate_limit_exceeded` (below) |
| POST | `/v1/forgot-password/validity` | `{"email","code","token"}` | `200 {"is_valid":true,"email":"<lower-cased>","token":"<reset token>"}`: the code was right; `token` is spent and the answer's token resets the password. `400 invalid_token` (unknown, used, replaced by a newer code, or expired), `400 invalid_email` (not the token's email), `400 email_code_error` (wrong code; counts, below), `429 email_password_reset_limit` |
| POST | `/v1/forgot-password/resets` | `{"token","new_password","password_confirm"}` | `200 {"result":"success"}`: the password is set, **every session of the account is revoked**, the token and every other reset token or link of the account are spent, and an invited account that had not activated yet becomes active (its invitation link is then spent). `400 invalid_password` (Dify's rule, both fields), `400 password_mismatch`, `400 invalid_token` (unknown, used or expired reset token or link), `400 account_not_found` |
| POST | `/v1/workspace/members/{id}/reset-password-link` | - | **dify-sf only.** `201 {"url":"/reset-password/set-password?email=...&token=...","expires_at"}`: a one-time link (relative to the web app, like invitation links) whose token goes to `/forgot-password/resets`. Privileged; any member but the owner, and the owner for itself only (`403 forbidden`); `404` for a non-member. A new link replaces the member's earlier one; email codes do not affect links. Works without mail. Admins never set or see another member's password |

* **Codes and tokens** (Dify's `RESET_PASSWORD_TOKEN_EXPIRY_MINUTES`): six random digits, valid **5 minutes**, as is the reset
  token after a right code. A new code for an email replaces its earlier code and reset token (Dify's one current token per
  account). Tokens are 32 random bytes (base64url); the server stores only their SHA-256, and for a code only the SHA-256 of
  token and code. Admin links are valid 24 hours.
* **Rate limits** (Dify's, kept per server process like the login limit): **one mail per address per 60 seconds**
  (`429 password_reset_rate_limit_exceeded`, "Please try again in 1 minutes."), for addresses with and without an account
  alike; **mails per IP**: more than 50 within a minute of each other are refused (`429 email_send_ip_limit`), and a second
  excess within 10 minutes blocks the IP for an hour (the IP is the `Forwarded` / `X-Forwarded-For` client, else the peer, as
  Dify); **wrong codes**: every wrong code for an email counts and renews a 24-hour window; with **more than 5** the email is
  locked (`429 email_password_reset_limit`, even with the right code) until the window passes; a right code clears the count.
* **Mail** (Dify's `MAIL_TYPE=smtp`): `COLLAB_MAIL_SMTP_HOST`, `COLLAB_MAIL_SMTP_PORT` (default by TLS mode: 465, 587, 25),
  `COLLAB_MAIL_SMTP_TLS` (`ssl` = implicit TLS, the default; `starttls` = STARTTLS required; `none`),
  `COLLAB_MAIL_SMTP_USERNAME` and `COLLAB_MAIL_SMTP_PASSWORD` (authenticates only when both are set), `COLLAB_MAIL_FROM`
  (`Name <address>` or an address), `COLLAB_MAIL_TIMEOUT_SECONDS` (10). Mail is configured when host and sender are set. Mails
  are Dify's templates (English and Chinese) and go out in the background: answers do not wait for the mail server, and
  failures are only logged.
* **Configuration**: `COLLAB_AUTH_RESET_PASSWORD_TOKEN_MINUTES` (5), `COLLAB_AUTH_RESET_PASSWORD_SEND_INTERVAL_SECONDS` (60),
  `COLLAB_AUTH_FORGOT_PASSWORD_MAX_FAILURES` (5), `COLLAB_AUTH_FORGOT_PASSWORD_LOCKOUT_SECONDS` (86400),
  `COLLAB_AUTH_EMAIL_SEND_IP_LIMIT_PER_MINUTE` (50), `COLLAB_AUTH_RESET_LINK_HOURS` (24).

### Account settings (1.12)

Dify 1.17.1's account page (`/account`) and the settings' Preferences tab (api/controllers/console/workspace/account.py).
Every call needs a signed-in member and works on the caller's own account, whatever its role. `Account` is the shape of
section "Accounts".

| Method | Path | Body | Answer |
|---|---|---|---|
| PATCH | `/v1/account/profile` | `{"name"?,"interface_language"?,"timezone"?}` | `200 Account` with the members given set (none given: unchanged). `name`: 3-30 characters (trimmed); `interface_language`: one of Dify's languages (`en-US`, `zh-Hans`, `zh-Hant`, `pt-BR`, `es-ES`, `fr-FR`, `de-DE`, `ja-JP`, `ko-KR`, `lo-LA`, `ru-RU`, `it-IT`, `uk-UA`, `vi-VN`, `ro-RO`, `pl-PL`, `hi-IN`, `tr-TR`, `fa-IR`, `sl-SI`, `th-TH`, `id-ID`, `ar-TN`, `nl-NL`); `timezone`: `UTC` or an IANA `Area/Location` name (`Asia/Kolkata`, `Etc/GMT+5`, every value of Dify's time zone list). Otherwise `400 bad_request` (Dify's messages: "en is not a valid language.", "Mars/Olympus is not a valid timezone."). Like Dify's payload (`extra="forbid"`), a null or any other member is `400`; Dify's `avatar` and `interface_theme` are `400` too (dify-sf stores neither) |
| POST | `/v1/account/change-email` | `{"email","language"?,"phase"?,"token"?}` | `200 {"result":"success","data":"<token>"}`: a code went out. Without `phase` (or any value but `new_email`) the code goes to the account's own address, which `email` must name (ignoring case; else `400 invalid_email`). With `"phase":"new_email"` and the `token` of a right code for the old address, it goes to the new address `email` (`400 invalid_token` otherwise). `language`: `zh-Hans` mails in Chinese, else English. `400 bad_request` (invalid email), `400 mail_not_configured`, `429 email_send_ip_limit`, `429 email_change_rate_limit_exceeded` ("Please try again in 1 minutes.") |
| POST | `/v1/account/change-email/validity` | `{"email","code","token"}` | `200 {"is_valid":true,"email":"<lower-cased>","token":"<next token>"}`: the code was right; `token` is spent. `400 invalid_token` (unknown, another account's, spent, replaced, expired, or already a verified token), `400 invalid_email` (not the address the code went to), `400 email_code_error` (wrong code; counts), `429 email_change_limit` |
| POST | `/v1/account/change-email/reset` | `{"new_email","token"}` | `200 Account` with the new email (stored lower-cased, as Dify): `token` must be the caller's token of a right code for `new_email`, else `400 invalid_token`. `400 email_already_in_use` if another account has the address by now (the token stays), `400 account_not_found` if the account's address changed meanwhile. The new address gets Dify's "Your login email has been changed" mail. Sessions stay (Dify's page signs out afterwards); reset codes and links of the account are spent |
| POST | `/v1/account/change-email/check-email-unique` | `{"email"}` | `200 {"result":"success"}` when no account has the address (ignoring case), else `400 email_already_in_use`. Dify's needs no sign-in; dify-sf's does (strangers do not learn which addresses have accounts) |

* **Tokens** (Dify's `CHANGE_EMAIL_TOKEN_EXPIRY_MINUTES`, `COLLAB_AUTH_CHANGE_EMAIL_TOKEN_MINUTES`, 5): every step's token is
  valid 5 minutes, and **one token per account is current**: each new token (a sent code or a right code) replaces the
  account's earlier ones. Tokens are 32 random bytes (base64url); the server stores their SHA-256 and, for a code, the
  SHA-256 of token and code. The steps are `old_email` -> `old_email_verified` -> `new_email` -> `new_email_verified`.
* **Limits** (Dify's, per server process): one mail per address per 60 seconds
  (`COLLAB_AUTH_CHANGE_EMAIL_SEND_INTERVAL_SECONDS`); the per-IP mail limit of "Password reset"; every wrong code for an
  address counts and renews a 24-hour window, and with **more than 5** the address is locked (`429 email_change_limit`,
  even with the right code; `COLLAB_AUTH_CHANGE_EMAIL_MAX_FAILURES`, `COLLAB_AUTH_CHANGE_EMAIL_LOCKOUT_SECONDS`); a right
  code clears the count.
* **Mails**: Dify's templates (`change_mail_confirm_old/new`, `change_mail_completed`), in the background like the reset
  mails.
* **Not offered**: avatars (Dify uploads a file; dify-sf has no file storage, so `avatar_url` stays unset and clients show
  Dify's initial avatar), deleting the account (Dify Cloud only), the education programme (Dify Cloud only).

### Dify app metadata: `GET /v1/docs/{doc}/meta`

Additive and optional (clients that do not use it are unaffected). A document imported from a Dify workflow file
(`POST /v1/docs/import`, `PUT /v1/docs/{doc}/import`) keeps the file's app-level parts, which its export
(`GET /v1/docs/{doc}/export`) writes back; since 1.7 its variables and features are part of the document itself
(document-level registers, section 3). This endpoint serves them as JSON, without the graph:

```json
{"app": {"name": "My chat", "mode": "advanced-chat", "icon": "🤖", "icon_background": "#FFEAD5", "description": "", ...},
 "kind": "app", "version": "0.3.1", "dependencies": [...],
 "environment_variables": [{"id": "...", "name": "api_key", "value": "", "value_type": "secret", ...}, ...],
 "conversation_variables": [{"id": "...", "name": "str", "value": "default", "value_type": "string", ...}, ...],
 "features": {...}}
```

* `app` is Dify's `app` section as imported (`mode` is `workflow` for a workflow, `advanced-chat` for a chatflow).
  `environment_variables`, `conversation_variables` and `features` are the document's (1.7: the registers of the same names
  at head, items as plain lists, so the response follows every edit), in Dify's shape: a **secret** environment variable
  (`value_type: secret`) carries its mask as `value`, never the plaintext, and no `secret_ref`. `kind` and `version` are
  present when the file had them; the lists and `features` are always present (empty if absent).
* Documents imported before 1.7 still keep their variables and features in the import metadata and have no registers for
  them; for such a document the entries come from the metadata, with a secret's `value` replaced by `""`.
* A document that was not imported gets the defaults its export uses: `app` `{"name": "<doc id>", "mode": "workflow", ...}`, no
  variables, `features` `{}`.
* The rest of the metadata (`app`, `kind`, `version`, `dependencies`) is fixed at import: ops do not change it. Variables and
  features change with ops on `$app` (1.7). Since 1.10 the `app` section's `name`, `description`, `icon_type`, `icon`,
  `icon_background` and `use_icon_as_answer_icon` are the app row's ("Apps (1.10)"), which `PUT /v1/apps/{app}` changes.

### Secrets: `POST /v1/docs/{doc}/secrets` (1.7)

Secret environment variables (`value_type: secret`) are edited like any other variable, but their plaintext never enters
an op, the log, a snapshot or the event stream:

1. `POST /v1/docs/{doc}/secrets` with `{"value":"sk-..."}` stores the plaintext on the server (by document and reference) and
   answers `201 {"ref":"sec-<32 hex>","masked":"<mask>"}`. `<mask>` is Dify's `formatSecret`: for a value longer than 8
   (UTF-16 code units), its first 6 characters, twelve `*` and its last 2; otherwise twenty `*`.
2. The client writes the variable with ordinary item ops on `$app` (`insertItem`/`updateItem` on `environment_variables`), the
   item value being the Dify variable object with `"value": "<mask>"` and an extra member `"secret_ref": "<ref>"`.

Importing a Dify file stores each non-empty secret value the same way (the item gets the mask and a `secret_ref`); an empty
secret stays `""` without a reference. `GET /v1/docs/{doc}/export` never writes `secret_ref`; a secret's `value` is `""`
(Dify's default) unless `?include_secret=true` (Dify's option of the same name), which writes the stored plaintext (`""` for an
unknown or missing reference) and, since 1.8, is for the owner and admins only (`403 forbidden` for everyone else; Dify lets
every editor export secrets, dify-sf keeps plaintext secrets to the privileged roles). Stored secrets are never deleted, also not when the variable is removed.
Since 1.9 the server stores them encrypted and refuses to store one without a secrets key (`503 secrets_key_missing`; section
"Secrets at rest").

### Replacing a document: `POST /v1/docs/{doc}/replace`

Dify 1.17.1's "Import DSL" in the workflow editor (back up, choose a file, "Overwrite and Import"): the open document gets the
content of a Dify workflow file. Unlike `import`, which creates a document, `replace` changes an existing one **with ordinary
ops**: they are committed under the caller's client id, appear on every stream as `commit` events (no snapshot reset), carry
stamps like any edit (so stale writes of others conflict with them, naming the caller) and leave tombstones. The op vocabulary
is unchanged.

Request (edit role): the body is the YAML (any content type), or JSON `{"yaml": "...", "client": "...", "cseq": N,
"confirm": bool}`. `client`, `cseq` and `confirm` may also be query parameters (`?client=...&cseq=N&confirm=true`; JSON members
win).

* `client` (required): the caller's own client id (`403 forbidden` if it belongs to another account; an unbound id is bound).
* `cseq` (required): the client's **next cseq**. The replacement's ops get the cseqs `cseq, cseq + 1, ...` of that client, so
  the client must have no unresolved ops and must not create ops until the answer arrives (section 9, "Replacing the
  document").
* `confirm`: Dify's confirmation of a file whose DSL version needs it (below).

Checks, in Dify's order (`AppDslService.import_app` with an `app_id`, and the editor's `validateDSLContent`); every refusal is
`400` with Dify's message where Dify has one, and changes nothing:

| Problem | `error.message` |
|---|---|
| not YAML | `Invalid YAML format: ...` |
| not a mapping | `Invalid YAML format: content must be a mapping` |
| `version` not a string | `Invalid version type, expected str, got <class 'float'>` |
| `version` not a version | `Invalid DSL version: ...` (Dify imports such a file and reports `failed`; dify-sf refuses it) |
| no `app` | `Missing app data in YAML content` |
| newer than `0.7.0` (Dify 1.17.1's DSL version) or an older major version, without `confirm` | code **`version_unconfirmed`**; the error also carries `imported_dsl_version` and `current_dsl_version` (Dify's "pending" import: show its version dialog, then repeat with `confirm=true`) |
| no `app.mode` / an unknown mode | `loss app mode` / `'x' is not a valid AppMode` |
| a mode other than `workflow` and `advanced-chat` | `Only workflow or advanced chat apps can be overwritten (...)` |
| no `workflow` | `Missing workflow data for workflow/advanced chat app` |
| node types the open app's mode cannot run (an `answer` node in a `workflow` app; `end`, `trigger-webhook`, `trigger-schedule`, `trigger-plugin` in an `advanced-chat` app) | `Import Failed: ...` |
| not an importable workflow (as `import`), or content ops cannot write (below) | `not an importable Dify workflow: ...` / `the workflow cannot be applied to this document: ...` |

**The app keeps its mode** (as in Dify, which never changes an app's mode on overwrite): a `workflow` file without `answer`
nodes may replace a chatflow and stays a chatflow. The rest of the import metadata (`app` name, description, icon, `kind`,
`version`, `dependencies`, layout and edge extras; `GET /meta`) becomes the file's, in the same transaction as the ops.

The file is imported exactly as `import` does (same mapping, same secret handling: each non-empty secret environment variable is
stored server-side and the document gets its mask and a `secret_ref`; a secret whose plaintext equals what the document's
variable of the same id already references keeps that reference). Then the server computes the ops that turn the document at
head into the imported one, with `base` = that head:

1. `removeEdge` for every live edge the file does not have (or has with other endpoints or handles), `removeNode` for every live
   node it does not have;
2. the document-level registers (`$app`: environment and conversation variables, features), new nodes (`addNode`; config
   entries that reference other nodes are written right after every node exists), titles (`setField` title), positions
   (`moveNode`), config entries (`setField`; `outputs` first) and new edges (`addEdge`).

Keyed lists (node lists and `$app` variables) are reconciled item by item (`removeItem`, `updateItem`, `insertItem`) when the
items both sides have keep their order, no new item id is tombstoned and some item is unchanged (or one op suffices);
otherwise the entry is written whole with one `setField`. Unchanged registers get no op: replacing a document with its own
export writes nothing. A reference the file has to a missing output (imported as `$broken`, which clients cannot write) is
written as the plain `[node, output]` pair Dify writes for it; exports are the same.

**Ids.** Node and edge ids of the file are kept, except where the op vocabulary forbids it (ids are never reused, a node's type
cannot change, a config key cannot be removed, edges are immutable):

* a node id that is **tombstoned**, or live with **another type** or with **a config key the file's node lacks**, gets a fresh
  id (Dify's style: the current time in milliseconds, incremented until unused); the live node, if any, is removed;
* an edge id that is tombstoned, or live with other endpoints or handles, and every edge of a renamed node, gets a fresh id in
  Dify's format `<source>-<sourceHandle>-<target>-<targetHandle>` (with `-1`, `-2`, ... if that is taken);
* everything in the file that names a renamed node follows it: edge endpoints, selectors (`[node, output, ...]`, references),
  `parentId`, `iteration_id`, `loop_id`, `start_node_id`, and `{{#node.output#}}` in every string.

The answer lists the renamings; the export is then the file with those ids renamed.

**Atomicity.** The whole replacement is one transaction: every op is committed, together with the new metadata and secrets, or
nothing is. It is computed and committed under the document's single sequencer, so no other op can commit in between (several
server processes: the revision check of the commit refuses a stale computation, and the server computes it again on fresh
state). Concurrent edits of others are serialised before or after it; one based on a version before the replacement that
writes a register the replacement wrote is a stale write and is rejected with `conflict` (`by` = the caller's client,
`byName` = its account's name), as against any edit (section 6).

Answer `200`:

```json
{"head": 57, "ops": 57, "nodes": 6, "edges": 4, "next_cseq": 58, "replayed": false,
 "status": "completed-with-warnings", "imported_dsl_version": "0.3.1", "current_dsl_version": "0.7.0",
 "renamed": {"nodes": {"1754683430480": "1760870000000"}, "edges": {"...": "..."}}}
```

* `head`: the head after the replacement; `ops`: how many ops it committed (cseqs `cseq ... next_cseq - 1`); `nodes`, `edges`:
  the document's counts; `next_cseq`: the client's next cseq (= `cseq + ops`).
* `status`: Dify's import status: `completed`, `completed-with-warnings` (an older minor DSL version: Dify's "DSL version
  difference may affect certain features"), or `pending` (confirmed with `confirm`).
* `replayed: true`: a retry of a replacement that was committed already (`cseq <= high` and the client's cseqs `cseq ... high`
  are all committed ops): nothing was computed or written now; `ops`, `next_cseq` describe the earlier one. So a retry after a
  timeout or `503` is safe.
* `409` (nothing changed): `outstanding_ops`: `cseq` is beyond the client's next cseq (the server has not handled ops of this
  client yet: wait until they are resolved); `cseq_used`: `cseq` was used by an ordinary op; `conflict`: the sequencer refused
  an op of the replacement (cannot happen with a correct server; the message says `0 ops committed`).

### Comments: `/v1/docs/{doc}/comments`

Additive and optional (added without a protocol version change; authors became accounts in 1.8). Canvas comments mirror Dify
1.17.1's workflow comments (pins on the canvas with a thread of replies and @-mentions). They are a server resource **beside**
the document: not part of it, not in the op log, snapshots, the stream's commits or the export (`GET /export`), and not undoable.

Identity (1.8): the **author** of a comment or reply is the **account** that created it (the caller); its name and avatar are
the account's, looked up when the comment is read (so a rename shows everywhere). "Only the creator may edit or delete" means:
the same account, from any of its clients or sessions. Mentions are account ids of workspace members; the candidates are
`GET /comments/mention-users`. Reading needs any member; every write needs the edit role (Dify's `edit_permission_required`:
a `normal` or `dataset_operator` member gets `403 forbidden`).

| Method | Path | Body | Answer |
|---|---|---|---|
| GET | `/comments` | - | `200 {"comments":[Comment...]}`: all of them, resolved ones included, newest first (Dify's order) |
| GET | `/comments/{id}` | - | `200 Comment` |
| GET | `/comments/mention-users` | - | `200 {"users":[{"id","name","email","avatar_url"?,"role"}]}`: the workspace members (Dify's mention candidates) |
| POST | `/comments` | `{"position_x","position_y","content","mentioned_user_ids"?:[...]}` | `201 Comment` |
| PUT | `/comments/{id}` | `{"content"?,"position_x"?,"position_y"?,"mentioned_user_ids"?}` | `200 Comment`; author only |
| DELETE | `/comments/{id}` | - | `204`; author only; its replies go with it |
| POST | `/comments/{id}/resolve` | - | `200 Comment`; any editor |
| POST | `/comments/{id}/replies` | `{"content","mentioned_user_ids"?:[...]}` | `201 Reply`; any editor, also on a resolved comment |
| PUT | `/comments/{id}/replies/{rid}` | `{"content","mentioned_user_ids"?}` | `200 Reply`; author only |
| DELETE | `/comments/{id}/replies/{rid}` | - | `204`; author only |

```json
{"id": "0192f3a1-...", "position_x": 412.5, "position_y": 180, "content": "Should this be gpt-4o?",
 "created_by": "6c1f...", "created_by_name": "Alice", "created_by_avatar_url": "https://...", "created_at": "2026-10-18T09:12:03.512Z",
 "updated_at": "2026-10-18T09:12:03.512Z",
 "resolved": true, "resolved_by": "9d02...", "resolved_by_name": "Bo", "resolved_at": "2026-10-18T09:20:44.020Z",
 "mentions": [{"account": "9d02...", "name": "Bo"}],
 "replies": [{"id": "0192f3a4-...", "content": "Yes", "created_by": "9d02...", "created_by_name": "Bo",
              "created_at": "...", "updated_at": "...", "mentions": []}],
 "reply_count": 1}
```

* Field names follow Dify's `WorkflowCommentDetail` (`position_x`, `position_y`, `created_by`, `resolved_by`, ...). Positions are
  canvas (flow) coordinates, JSON numbers (fractions allowed; this is not a document value). Times are ISO-8601 UTC with
  milliseconds. Members ending in `_name`/`_avatar_url` and `name`/`avatar_url` are present when the account exists (and has an
  avatar); `resolved_by`, `resolved_by_name` and `resolved_at` only on a resolved comment. Replies are oldest first. Comments
  written before 1.8 keep their client-id authors: no account matches them (no name, nobody may edit them).
* Ids are server-generated UUIDs (version 7, as Dify).
* `content`: Dify's rule: not blank (after trimming whitespace) and at most 1000 characters (Unicode scalars). Otherwise
  `400 bad_request`; so is a missing position on create, or a body of the wrong shape. A `client` member in a body is ignored.
* `mentioned_user_ids`: ids that are not workspace members and duplicates are dropped (Dify's
  `_filter_valid_mentioned_user_ids`: members only, once, in order).
* `PUT /comments/{id}`: omitted fields stay as they are. Only the author may change anything, **also the position** (Dify lets
  only the creator drag a pin); `content` may be omitted for a move (Dify always sends it). `mentioned_user_ids` omitted keeps
  the mentions, a list (also `[]`) replaces them (Dify). `updated_at` changes.
* `PUT /replies/{rid}`: `content` is required; the mentions are replaced by the list given, **an omitted list clears them**
  (Dify's behaviour).
* Resolve is idempotent as Dify's: resolving a resolved comment answers `200` with the comment unchanged (the first resolver
  and time stay). There is no "unresolve" (Dify has none). Resolving changes `updated_at`.
* Errors: `404 not_found` for an unknown document, comment or reply (a reply id is looked up within its comment); `403` with
  code **`not_author`** when another account edits, moves or deletes a comment or reply:
  `{"error":{"code":"not_author","message":"only the author may change or delete this comment"}}`; `403 forbidden` for a write
  by a read-only role.

**Live updates.** After every change (create, edit/move, delete, resolve that changed something, reply created, edited or
deleted) the server sends an `event: comments` on the document's event stream (section 5) to every stream of the document
connected to the same server process. It is a notification only: clients refetch `GET /comments` (or the one comment). The
REST list is the truth; clients must also refetch after every (re)connect of the stream, since notifications are not replayed.

### Apps (1.10)

Dify 1.17.1's Studio (`api/controllers/console/app/app.py`, `app_import.py`) under **`/v1/apps`**, with Dify's paths and
shapes, so a client that ports Dify's web code parses the answers unchanged. **An app is a document**: the app id is the
document id, and the editor opens it with the document endpoints. Every document has exactly one app row, created in the same
transaction as the document by every creating path (`POST /v1/docs`, `PUT /v1/docs/{doc}`, the imports, and the endpoints
below): name, description, mode, icon, creator, times. dify-sf runs workflows and chatflows only (`workflow`,
`advanced-chat`): those are the only modes an app can have.

**Roles** (Dify's community edition with RBAC off): every member lists and reads every app and stars for themselves; creating,
importing, editing info, duplicating, exporting and deleting need **edit** (`owner`, `admin`, `editor`; Dify's
`edit_permission_required`): **any** editor may change **any** app, as in Dify; the export with secrets needs **privileged**
(1.8). Each app carries `permission_keys`, Dify's legacy per-app keys of the **caller's** role (`rbac_service.py`
`_LEGACY_APP_*_KEYS`): owner and admin `app.acl.preview`, `view_layout`, `test_and_run`, `edit`, `import_export_dsl`, `delete`,
`release_and_version`, `monitor`, `access_config`, `tracing_config`, `log_and_annotation`, `access_point_manage`,
`access_point_view`; editor the same without `tracing_config`; `normal` `app.acl.monitor`, `app.acl.access_point_view`;
`dataset_operator` `app.acl.access_point_view`. (As Dify's `getRedirectionPath`, a client opens an app on its Overview page
for `normal` members and on its Access Point for `dataset_operator`s: the app detail pages, 1.11.)

**The app object** (Dify's `AppPartial` and `AppDetailWithSite` in one; every answer below that returns an app):

```json
{"id": "<doc id>", "name": "Support bot", "description": "", "mode": "advanced-chat",
 "icon_type": "emoji", "icon": "🤖", "icon_background": "#FFEAD5", "icon_url": null, "use_icon_as_answer_icon": false,
 "max_active_requests": null, "created_by": "<account id>", "created_at": 1760000000, "updated_by": "<account id>",
 "updated_at": 1760000500, "author_name": "Olivia", "create_user_name": "Olivia", "tags": [], "permission_keys": ["..."],
 "is_starred": false, "workflow": {"id": "<doc id>", "created_by": "...", "created_at": 1760000000, "updated_by": "...",
 "updated_at": 1760000500}, "model_config": null, "access_mode": null, "maintainer": null, "bound_agent_id": null,
 "has_draft_trigger": false, "enable_site": true, "enable_api": true, "site": {...}, "api_base_url": "https://host/v1",
 "deleted_tools": [], "tracing": null}
```

Times are epoch **seconds**. `author_name` is the creator's account name (an app of unknown origin, created before accounts
existed or by a harness, counts as the workspace owner's). **`updated_at` is "last modified"**: the later of the app row's last
change (create, edit info) and the document's last committed op. This is a deviation from Dify, where draft saves only touch
the workflow row and the Studio's "Edited" time would never move without publishing. `updated_by` is the account of the last
app-row change. `tags` is always empty (dify-sf has no tags yet), `icon_url` always null (no file storage), and the members
of features dify-sf does not have (tracing, agents, triggers) have their empty values. `enable_site`, `enable_api`,
`api_base_url` and `site` are real since 1.11 ("App detail pages (1.11)"; a 1.10 server sends `false`, `false`, `null`,
`null`).

**`GET /v1/apps`** (member): query `page` (1-99999, default 1), `limit` (1-100, default 20), `mode` (`all`, default, or one of
Dify's `completion`, `chat`, `advanced-chat`, `workflow`, `agent-chat`, `agent`, `channel`: modes dify-sf cannot have match
nothing), `name` (case-insensitive substring of the name; only its first 30 characters count, as in Dify), `sort_by`
(`last_modified`, default: `updated_at` descending; `recently_created`; `earliest_created`; ties by id), `creator_ids`
(repeated: `creator_ids=a&creator_ids=b`; apps created by any of them), `is_created_by_me` (boolean), `tag_ids` (accepted,
ignored). Deleted apps are never listed. Answer: Dify's `AppPagination`
`{"page", "limit", "total", "has_more", "data": [app, ...]}` (`has_more` = `page * limit < total`); a page past the end is
`200` with `data: []`. Values outside the ranges, an unknown `mode` or `sort_by`: `400 bad_request`.

**`GET /v1/apps/starred`** (member): the apps the caller starred, same query and answer (Dify's starred row asks for
`limit=100`). **`POST /v1/apps/{app}/star`**, **`DELETE /v1/apps/{app}/star`** (member): `200 {"result":"success"}`, idempotent;
stars are per account.

**`GET /v1/apps/{app}`** (member): the app.

**`POST /v1/apps`** (edit): Dify's `CreateAppPayload` `{"name", "description"?, "mode", "icon_type"?, "icon"?,
"icon_background"?}`: `name` 1+ characters (trimmed), `description` at most 400 characters, `mode` one of Dify's `chat`,
`agent-chat`, `advanced-chat`, `workflow`, `completion` (else `400 bad_request`) and one dify-sf has (`workflow`,
`advanced-chat`; else `400 unsupported_app_mode`), `icon_type` `emoji` (default), `image` or `link`; icon defaults `🤖` on
`#FFEAD5`. `201` with the app. The document is seeded as a Dify file would be imported: a **chatflow** gets Dify's chatflow
template (User Input -> LLM `llm` -> Answer `answer` `{{#llm.text#}}`, features `retriever_resource` on); a **workflow** one
User Input (`start`) node (Dify's blank workflow has no node and shows a local start placeholder instead).

**`PUT /v1/apps/{app}`** (edit): Dify's `UpdateAppPayload` `{"name", "description"?, "icon_type"?, "icon"?, "icon_background"?,
"use_icon_as_answer_icon"?, "max_active_requests"?}`: `name` is required (1+ characters); members left out (or null) keep
their value (Dify resets them; its web app always sends them all). `max_active_requests` (a non-negative integer) is stored
and unused. Answer: the app.

**`POST /v1/apps/{app}/copy`** (edit): Dify's `CopyAppPayload` `{"name"?, "description"?, "icon_type"?, "icon"?,
"icon_background"?}` (left out = the original's). As in Dify the app is exported with its secrets and imported as a new app:
the copy has the original's document at head (graph, variables, features), mode and settings, new ids for its secret
references, its secrets **encrypted for the new document**, the caller as creator, no stars. `201` with the new app. A server
without a secrets key refuses to copy an app that has secrets (`503 secrets_key_missing`).

**`DELETE /v1/apps/{app}`** (edit): `204`, a **soft delete**: the app leaves every list, and its document is gone for every
client: every `/v1/docs/{doc}/...` call, `GET`/`PUT`/`copy`/`export`/`star`/`DELETE` of the app answer
**`404 app_deleted`** (an unknown id stays `404 not_found`). The document's sequencer stops, and the event streams open on it
end; a reconnect gets the `404`. A client should then tell the user, leave the editor and drop the document's journal: its
ops can never be committed. (The rows stay in the database; there is no undelete endpoint.)

**`GET /v1/apps/{app}/export`** (edit; `?include_secret=true` privileged): Dify's `{"data": "<yaml>"}`, the same file as
`GET /v1/docs/{doc}/export` (secret values `""` without `include_secret`). Dify asks before exporting secrets: a client reads
the app's environment variables (`GET /meta`) and, if one is `value_type: secret`, offers the choice.

**`POST /v1/apps/imports`** (edit): Dify's `AppImportPayload` `{"mode": "yaml-content", "yaml_content", "name"?,
"description"?, "icon_type"?, "icon"?, "icon_background"?}` creates a new app from a Dify file (the overrides replace the
file's `app` values). The answer is always Dify's `Import` object `{"id", "status", "app_id", "app_mode",
"current_dsl_version", "imported_dsl_version", "error", "warnings": []}`, with the HTTP status:

* `200`, `status` `completed` (or `completed-with-warnings` for an older minor version): `app_id` is the new app;
* `202`, `status` `pending`: the file's version is newer than the server's (`0.7.0`) or of an older major version and needs
  the user's confirmation; nothing is created yet. **`POST /v1/apps/imports/{id}/confirm`** (same account, within 10 minutes,
  once) creates the app (`200`, `completed`); afterwards, or for another account, `404 not_found`;
* `400`, `status` `failed`, `error` Dify's message: not a mapping, a bad or missing version, no `app` section, a mode
  dify-sf cannot run, nodes the mode cannot run (`answer` in a workflow; `end` or triggers in a chatflow), a file that does
  not import, `yaml-url` (dify-sf does not fetch URLs: upload the content), an `app_id` (overwriting goes through the editor,
  `POST /v1/docs/{doc}/replace`), content over 10 MB.

Import, copy and blank create are the same import underneath: identical documents, metadata and secret handling as
`POST /v1/docs/import` (1.5, 1.7, 1.9).

**Migration.** At its first start a 1.10 server gives every document without an app row one (idempotent, every start): name,
mode, description and icon from the imported file's `app` section, else the document id, `workflow` and Dify's defaults;
the creator is the account of the document's earliest client id (none: the workspace owner); created at the document's
creation; last modified at its last commit.

### App detail pages (1.11)

Dify 1.17.1's pages inside an app, under **`/v1/apps/{app}`** with Dify's console paths and shapes
(`api/controllers/console/app/site.py`, `app.py`, `apikey.py`, `annotation.py`, `message.py`, `workflow.py`, `statistic.py`,
`workflow_statistic.py`, `workflow_app_log.py`, `conversation.py`, `workflow_run.py`). Unknown apps answer `404 not_found`,
deleted ones `404 app_deleted`; an endpoint of another app mode answers Dify's wrong-mode error, **`404 app_not_found`**
"App mode is not in the supported list: {...}". The role column is checked first (as Dify's decorators run before the app is
looked up), except for key deletes.

**Roles** (Dify's community-edition decorators, RBAC off, **quirks kept**):

| | owner, admin | editor | normal, dataset_operator |
|---|---|---|---|
| site settings, Web App switch, list / create keys | yes | yes | `403` |
| site code reset, Service API switch, delete keys | yes | **`403`** | `403` |
| annotations, reply setting, publish, versions, restore, chat logs | yes | yes | `403` |
| annotation count, statistics, workflow logs and runs, message feedback, reading the app (with its site) | yes | yes | yes |

Dify's UI shows the API switch, regenerate and key delete enabled to editors; the server refuses them and the UI shows its
error toast. Reading the published version (`GET .../workflows/publish`) needs edit, as in Dify.

#### Access Point: the site, the switches, Service API keys

Every app has a **site** (Dify's `sites` row), created with the app (title and icon from the app, the creator's interface
language if Dify knows it, else `en-US`; `customize_token_strategy` `not_allow`; `show_workflow_steps` true) and a **code**:
16 letters and digits (Dify's `Site.generate_code(16)`), the last segment of the Web App URL
`{app_base_url}/{chat|workflow}/{code}` (`chat` for chatflows). A copy gets a new site (the copy's name, a new code) and no
keys; a deleted app keeps its rows. The app object (any app answer, 1.10) carries:

```json
{"enable_site": true, "enable_api": true, "api_base_url": "https://host/v1",
 "site": {"app_id": "<app>", "access_token": "<code>", "code": "<code>", "title": "Support bot", "icon_type": "emoji",
          "icon": "🤖", "icon_background": "#FFEAD5", "description": null, "default_language": "en-US",
          "chat_color_theme": null, "chat_color_theme_inverted": false, "customize_domain": null, "copyright": null,
          "privacy_policy": null, "input_placeholder": null, "custom_disclaimer": "", "customize_token_strategy": "not_allow",
          "prompt_public": false, "show_workflow_steps": true, "use_icon_as_answer_icon": false, "app_base_url": "https://host",
          "created_by": "<account>", "updated_by": "<account>", "created_at": 1760000000, "updated_at": 1760000000}}
```

`app_base_url` is `COLLAB_WEBAPP_BASE_URL` (Dify's `APP_WEB_URL`), else the request's origin (`X-Forwarded-Proto` /
`X-Forwarded-Host` of a proxy in front), else the server's own address; `api_base_url` is `COLLAB_SERVICE_API_URL` (Dify's
`SERVICE_API_URL`) or the same origin, ending in `/v1`. **The URLs lead nowhere yet**: dify-sf has no web-app or service-API
runtime; 1.11 stores what a runtime will use.

* **`POST .../site`** (edit): Dify's `AppSiteUpdatePayload`, every member optional, nulls and absent members keep their value:
  `title`, `icon_type` (`emoji`, `image`, `link`), `icon`, `icon_background`, `description`, `default_language` (Dify's 24
  languages, else `400` "xx is not a valid language."), `chat_color_theme` (`#RGB` / `#RRGGBB` or `""`),
  `chat_color_theme_inverted`, `customize_domain`, `copyright`, `privacy_policy` (an `http://` / `https://` URL or `""`),
  `input_placeholder` (at most 64 characters), `custom_disclaimer` (at most 512), `customize_token_strategy` (`must`,
  `allow`, `not_allow`), `prompt_public`, `show_workflow_steps`, `use_icon_as_answer_icon`. Answer: the site (dify-sf answers
  every member of the site object; Dify's `AppSiteResponse` has a subset). The colour, URL and placeholder checks are the
  web's own rules applied on the server too.
* **`POST .../site/access-token-reset`** (privileged): a new code; the old URL stops working. Answer: the site.
* **`POST .../site-enable`** `{"enable_site": bool}` (edit), **`POST .../api-enable`** `{"enable_api": bool}` (privileged):
  answer the app. A change sets the app's `updated_by` / `updated_at` (Dify); the same value changes nothing.
* **`GET .../api-keys`** (edit): Dify's `{"data": [{"id", "type": "app", "token", "dataset_ids": [], "last_used_at",
  "created_at"}]}`, oldest first, with the **full** token (Dify does not mask app keys; its modal shows `first 3...last 20`).
  `last_used_at` stays null until a runtime uses keys.
* **`POST .../api-keys`** (edit): `201` with a new key, `app-` + 24 letters and digits. At most **10** per app:
  `400 max_keys_exceeded` "Cannot create more than 10 API keys for this resource type.".
* **`DELETE .../api-keys/{key}`** -> `204`: as Dify, the app is looked up first (`404`), then the role (owner or admin, else
  `403`, also for editors); an unknown key is `404` "API key not found".

**Keys at rest (deviation, hardening).** Dify stores app keys in plaintext. dify-sf stores each key **encrypted** with the
server's secrets key (AES-256-GCM, context `app_api_key:<app>:<key id>`, the 1.9 `v1:` format) plus its **SHA-256** (hex),
which is how a future service-API runtime finds the key of a request without decrypting anything. Without a secrets key
`POST .../api-keys` answers `503 secrets_key_missing`; with another key than the one they were sealed with, stored keys are
listed with `token` `""` (and still found by their hash). Deleting a key or the app makes the hash lookup fail.

#### Annotations (chatflows)

Dify's `annotation.py`. Dify's server accepts these calls for any app and its web app offers them for chat apps only; dify-sf
answers them for chatflows (`advanced-chat`) only: a workflow app gets Dify's wrong-mode error (`404 app_not_found`). An
annotation is `{"id", "question", "answer", "hit_count": 0, "created_at"}`.

* **`GET .../annotations?page&limit&keyword`** (edit): Dify's `{"data", "has_more", "limit", "total", "page"}`, newest first;
  `keyword` matches question or answer (case-insensitive substring); at most 100 rows per page; `has_more` is Dify's
  `len(data) == limit` (a full last page says `true`).
* **`GET .../annotations/count`** (member): `{"count"}`. **`GET .../annotations/export`** (edit): `{"data": [...]}`, every
  annotation, newest first; Dify's web writes the CSV (with a BOM) or the JSONL file from it.
* **`POST .../annotations`** `{"question", "answer"}` (or `content` for the answer) (edit): `201` the annotation. A missing
  answer is `400` "Either 'answer' or 'content' must be provided", a missing question `400` "'question' is required when
  'message_id' is not provided"; a `message_id` is `404` "Message Not Exists." (no messages without a runtime).
* **`POST .../annotations/{id}`** `{"question", "answer"}` (edit): both required (Dify's messages); `404` "Annotation not
  found". **`DELETE .../annotations/{id}`**: `204` / `404`. **`DELETE .../annotations?annotation_id=a&annotation_id=b`**:
  `204`, deletes those (unknown ids ignored; an empty id is `400`); **without ids it clears every annotation** (Dify).
* **`POST .../annotations/batch-import`** (edit): `multipart/form-data` with one file part `file` whose name ends in `.csv`
  (else `400 no_file_uploaded` "Please upload your file.", `400 too_many_files`, `400` "Invalid file type. Only CSV files are
  allowed", `400` "The uploaded file is empty", `413` over 2 MB). The CSV is read as Dify's pandas `read_csv`: the first row
  is the header, the first two columns are question and answer (stripped; rows with an empty or `nan` value skipped; rows
  with more fields than the header skipped), 1-10000 usable rows, question at most 2000 and answer at most 10000 characters.
  A refused file is **`200 {"error_msg": "<Dify's message>"}`** (no `job_id`), as in Dify. Otherwise the annotations are
  stored at once and the answer is Dify's `{"job_id", "job_status": "waiting", "record_count"}`;
  **`GET .../annotations/batch-import-status/{job}`** then answers `{"job_id", "job_status": "completed", "error_msg": ""}`
  (`400` "The job does not exist." for an unknown or expired job; jobs are kept 10 minutes, as Dify's Redis keys). Dify's
  per-workspace import rate limits are not applied.
* **`GET .../annotation-setting`** (edit): `{"enabled": false}` or `{"id", "enabled": true, "score_threshold",
  "embedding_model": {"embedding_provider_name", "embedding_model_name"}}`.
* **`POST .../annotation-reply/enable`** `{"score_threshold", "embedding_provider_name", "embedding_model_name"}` (all
  required) and **`POST .../annotation-reply/disable`** (edit): Dify's `{"job_id", "job_status": "waiting"}`; the setting is
  created or updated (its id kept) / removed **at once**; **`GET .../annotation-reply/{action}/status/{job}`** answers
  `completed`. dify-sf **stores the setting only**: nothing is embedded and no reply is ever matched until a runtime exists.
* **`POST .../annotation-settings/{id}`** `{"score_threshold"}` (edit): the setting; `404` "App annotation not found".
* **`GET .../annotations/{id}/hit-histories`** (edit): always an empty page (hits come from a runtime).

#### Publish and versions

The **draft** is the document itself (its `WorkflowResponse` id is the app id). **`POST .../workflows/publish`**
`{"marked_name"?, "marked_comment"?}` (edit; at most 20 and 100 characters) stores a **version**: the document at head and
its Dify metadata with the app row, i.e. exactly what the export renders at that moment (graph, features, environment and
conversation variables; secret variables keep their references, so the version renders its own secret values on the
server). Answer: Dify's `{"result": "success", "created_at"}`. The **newest version is the published one** (Dify's
`app.workflow_id`); publishing also bumps the app's `updated_at`. Version numbers count per app from 1 and are never reused
(Dify's `version_number`). A version is Dify's `WorkflowResponse`:

```json
{"id": "<version id>", "graph": {"nodes": [...], "edges": [...], "viewport": {...}}, "features": {...},
 "hash": "<sha-256 of graph and features>", "version": "2026-10-19 08:12:03.123456", "version_number": 3,
 "marked_name": "v3", "marked_comment": "", "created_by": {"id", "name", "email"}, "created_at": 1760000000,
 "updated_by": {"id", "name", "email"}, "updated_at": 1760000000, "tool_published": false,
 "environment_variables": [...], "conversation_variables": [...], "rag_pipeline_variables": []}
```

`graph`, `features` and the variables are the export's (`GET /export?format=json`), secret values `""`; `version` is the
publish time in UTC as Dify's `str(datetime)`. The draft has `"version": "draft"`, `version_number` null, no name, the app's
creator and creation time, and the last change as `updated_at`.

* **`GET .../workflows/publish`** (edit): the published version, or **`null`** (the JSON literal) if the app was never
  published: Dify's "unpublished" state (the Access Point's "Go to publish" banner for workflow apps).
* **`GET .../workflows?page&limit&user_id&named_only`** (edit): Dify's `{"items", "page", "limit", "has_more"}`; `page`
  1-99999, `limit` 1-100 (default 10). Dify's order: **the draft first**, then the versions newest first; filters apply to the
  draft too (`named_only=true` drops it; `user_id` keeps it only if the app's creator is that account). `user_id` must be the
  caller's own id (else `403`). An app that was never published lists nothing, not even the draft (Dify).
* **`GET .../workflows/{id}`** (edit; **dify-sf only**, Dify has no such read): the version (the app id: the draft) as
  above plus **`doc`**, the document in the snapshot format (section 3, "Document"), so a client can preview a version on its
  canvas without reading a Dify file; `404` for an unknown version.
* **`GET /v1/apps/{app}/export?workflow_id={id}`** (edit; `include_secret=true` privileged): Dify's export of one version,
  `{"data": "<yaml>"}`: the version's graph, features and variables (its own secret values with `include_secret`) under the
  app's current name and icon; the app id exports the draft; an unknown version is `404`.
* **`PATCH .../workflows/{id}`** `{"marked_name"?, "marked_comment"?}` (edit): the version; neither member: `400` "No valid
  fields to update"; unknown (or the draft): `404`.
* **`DELETE .../workflows/{id}`** (edit): `204`; the draft: `400` "Cannot delete draft workflow versions"; the published
  version: `400` "Cannot delete workflow that is currently in use by app '<app>'"; unknown: `404`.
* **`POST .../workflows/{id}/restore`** `{"client", "cseq", "confirm"?}` (edit): **restores the version into the draft
  through the replacement path**: the server renders the version as a Dify file (with its secret values, which never leave
  the server) and replaces the document with it exactly as `POST /v1/docs/{doc}/replace` does ("Replacing a document": the
  same ops of the caller's `client` from `cseq`, the same `409 outstanding_ops` / `cseq_used` / `conflict`, the same
  **replayed** answer to a retry, secrets whose plaintext is unchanged keep their references). Unlike `/replace` the app row
  (name, description, icon) is not changed, and the published version stays (Dify's restore writes the draft only). Answer:
  the replacement's answer plus Dify's `"result": "success"`, `"hash"` (the version's) and `"updated_at"`. The draft's id is
  refused with `400` "source workflow must be published"; an unknown version is `404`. A live editor calls it through its
  replacement procedure (section 9, "Replacing the document"), with its own client id and next cseq.

#### Overview statistics and logs (empty until a runtime exists)

dify-sf runs workflows only in the editor's debugger, and Dify never logs debugger runs: there is nothing to count or list.
These endpoints answer Dify's shapes for an app nobody has used, so clients call the real paths now:

* Statistics (member; query `start`, `end` as `YYYY-MM-DD HH:MM`, else `400`; `start` after `end`: `400`): `{"data": []}`
  for `.../statistics/daily-messages`, `daily-conversations`, `daily-end-users`, `token-costs`, `user-satisfaction-rate`,
  `tokens-per-second`, `average-session-interactions` (chat modes only), `average-response-time` (completion apps only: always
  `404 app_not_found` here), `.../workflow/statistics/daily-conversations` (runs), `daily-terminals`, `token-costs`,
  `average-app-interactions` (workflow apps only). Dify's charts fill the days without a row with zeros.
* **`GET .../workflow-app-logs`** (member; workflow apps; `page` 1-99999, `limit` 1-100, `status`, `keyword`,
  `created_at__before` / `__after` ISO times, `detail`): `{"page", "limit", "total": 0, "has_more": false, "data": []}`.
  Runs: see "Draft runs (1.14)" (`GET .../workflow-runs/{run}` answers `404` "Workflow run not found" for an unknown run,
  `.../node-executions` `{"data": []}`, as Dify).
* **`GET .../chat-conversations`** (edit; chat modes; `page`, `limit`, `keyword`, `start`, `end`, `annotation_status`
  `annotated` / `not_annotated` / `all`, `sort_by` `created_at` / `-created_at` / `updated_at` / `-updated_at`): an empty
  page. **`GET .../chat-conversations/{id}`** and **`GET .../chat-messages?conversation_id=`** (edit): `404` "Conversation Not
  Exists." (`conversation_id` is required: `400`).
* **`POST .../feedbacks`** (member, every app mode; Dify's `MessageFeedbackApi`): the member's ("admin") rating of a message
  in the logs. Body `{"message_id": "<uuid>", "rating": "like" | "dislike" | null, "content": "<text>" | null}` (`rating`
  and `content` may be absent = null). Answer `200 {"result": "success"}`. A message has at most one admin feedback, as in
  Dify:
  * a rating and no feedback yet: created (`from_source` `admin`, by the caller);
  * a rating and a feedback: its rating and content are replaced (the content becomes null if absent; the author stays);
  * `null` and a feedback: removed;
  * `null` and no feedback: `400 bad_request` "rating cannot be None when feedback not exists" (Dify's `invalid_param`).

  `message_id` must be a UUID (`400` "{value} is not a valid uuid."; absent: `400`); another `rating` or a non-string
  `content`: `400`. A message that is not one of this app's: **`404 not_found` "Message Not Exists."** (until a runtime
  exists, every message). Unknown app `404 not_found`, deleted app `404 app_deleted`. The server keeps Dify's
  `message_feedbacks` shape (rating, content, `from_source` `user` / `admin`, the account or end user, times) so that a runtime
  can answer the feedback statistics and a message's `feedbacks`.

**Live updates.** After a successful change to what `GET /v1/apps/{app}` answers (`PUT /v1/apps/{app}` edit info, the
app section an overwrite `POST /replace` adopts, `POST .../site`, `.../site/access-token-reset`, a `site-enable` /
`api-enable` that changed the value, `POST .../workflows/publish`) the server sends `event: app` on the document's event stream
(section 5) to the streams connected to the same server process. Nothing is sent for refused, failed or no-op requests. It is
a notification only (Dify's peer-to-peer `app_meta_update`): clients refetch `GET /v1/apps/{app}`, and also after every
(re)connect of the stream, since notifications are not replayed.

**Migration.** At its first start a 1.11 server gives every app without a site one (deleted apps included; idempotent), and
the new `apps` columns start as Dify's defaults (`enable_site`, `enable_api` true).

### Runtime (1.13)

The workflow runtime runs Dify workflows in the server: a Swift port of graphon 0.7.0 (Dify 1.17.1's engine, Apache-2.0;
`server/Sources/CollabRuntime`, attribution in its `NOTICE.md`), with Dify's paths and shapes. Models are not called by
dify-sf itself: every model invocation goes through **Dify's plugin daemon** (0.6.10), which runs the provider plugins,
exactly as Dify's api calls it (`POST /plugin/{tenant}/dispatch/llm/invoke`, `.../model/schema`), with the workspace's
credentials (protocol 1.9, decrypted per call). 1.13 has the **single node run of `llm` nodes**; whole runs, the other node
types, streaming and history follow in later versions.

**Configuration.** `COLLAB_PLUGIN_DAEMON_URL` (e.g. `http://plugin_daemon:5002`; empty = no model runtime),
`COLLAB_PLUGIN_DAEMON_KEY` (the daemon's `SERVER_KEY`), `COLLAB_PLUGIN_DAEMON_TENANT` (the workspace's tenant in the daemon,
under which plugins are installed; default `00000000-0000-0000-0000-000000000001`), `COLLAB_PLUGIN_DAEMON_TIMEOUT_SECONDS`
(600). The daemon needs the providers' plugins installed for that tenant (for example `langgenius/openai_api_compatible`).

**Discovery.** `GET /v1/system-features` carries `"workflow_runtime": {"protocol_version": "1.13", "single_node_run":
["llm"]}` when `COLLAB_PLUGIN_DAEMON_URL` is set, else no `workflow_runtime` member. A client runs the node types listed in
`single_node_run` with the endpoints below and keeps whatever it did before (Dify's UI over a local stand-in) for the others.

**`POST /v1/apps/{app}/workflows/draft/nodes/{node}/run`** (edit; workflow and chatflow apps, else `404 app_not_found`).
Body: Dify's `DraftWorkflowNodeRunPayload`, `{"inputs": {...}}` (`query` and `files` are for start nodes, which do not run
in 1.13). `inputs` holds the values the node reads that are not in the run, keyed as Dify's single-run form sends them:
`"#node.var#"` (or `"<this node>.#node.var#"`), `"#context#"` for the LLM's context variable. A value the node needs that
is missing is `400 invalid_param` "Variable key {node}.#x.y# not found in user inputs.".

* **Consistency.** The server reads the document at its current seq N (the committed state, in one read), renders it as
  Dify's graph (as the export does, secret environment variables with their values) and runs the node on that. Edits that
  arrive during the run do not affect it. The run writes **no ops**: its record is a row of `workflow_node_executions`
  (Dify's columns plus `doc_seq` = N), beside the document, never in its log, snapshots or export.
* **Answer** `200`: Dify's `WorkflowRunNodeExecutionResponse`, member order as Dify: `id`, `index` (1),
  `predecessor_node_id` (null), `node_id`, `node_type`, `title`, `inputs`, `process_data`, `outputs`, `status`
  (`succeeded`, `failed`, or `exception` when an error strategy turned a failure into outputs), `error`, `elapsed_time`
  (seconds), `execution_metadata` (`total_tokens`, `total_price`, `currency`), `extras` (`{}`), `created_at`,
  `created_by_role` (`account`), `created_by_account` (`{id, name, email}`), `created_by_end_user` (null), `finished_at`,
  `inputs_truncated`, `outputs_truncated`, `process_data_truncated` (false). A node that **failed** is also `200`, with
  `status: "failed"`, `error` and null `inputs`, `process_data`, `outputs` (as Dify stores it).
* **LLM node** (graphon's `LLMNode`): the prompt is built from the node's templates (chat messages or the completion
  prompt, `{{#node.var#}}` references and `{{#context#}}`) and sent to the model as one streaming invocation; outputs
  `text`, `reasoning_content` (`reasoning_format: separated` splits `<think>` blocks off), `usage` (Dify's `LLMUsage`,
  prices as decimal strings) and `finish_reason`; `process_data` has `model_mode`, `prompts` (`[{role, text, files}]`),
  `usage`, `finish_reason`, `model_provider`, `model_name`; `inputs` has `model_provider`, `model_name` and `#context#`.
  Not yet in 1.13: structured output and Jinja2 prompts (the node fails with a message saying so; Jinja2 needs the code
  sandbox), and files (vision reads none: there are no file values before file storage). Single runs have no conversation
  memory (as in Dify).
* **Errors before the run** (Dify raises these out of the request): `400 invalid_param` for missing inputs, invalid node
  data, and a model that cannot be prepared, with Dify's message (`Provider X does not exist.`, `Model X not exist.`, `Model
  is not configured`, `Model is disabled`, `Model X credentials is not initialized.`, or the daemon's error when it cannot
  give the model's schema); `400 unsupported_node_type` for a node type the server does not run yet; `400
  model_runtime_not_configured` without `COLLAB_PLUGIN_DAEMON_URL`; `404 not_found` for an unknown node.

**`GET /v1/apps/{app}/workflows/draft/nodes/{node}/last-run`** (member): the node's newest execution in this app (single
runs now, runs of the whole draft later), in the shape above; `404 not_found` "last run not found" without one.

**Deviations from Dify.** Large values are never offloaded (`*_truncated` are always false). (1.14: single node runs of every
node type the runtime has, except start nodes; they read values missing from `inputs` from the caller's draft variables
and write their outputs back to them, as Dify.)

### Draft runs (1.14)

A draft run runs the whole draft as Dify's debugger does ("Test run"), on the Swift engine (`server/Sources/CollabRuntime/
Engine`, a port of graphon 0.7.0's `GraphEngine`: ready queue and parallel branches, edge traversal and skip propagation,
error strategies, retries, the execution limits layer, and Dify's response stream filter that orders the answer / end
streams). Models go through the plugin daemon as in 1.13; code and Jinja2 through Dify's code sandbox; HTTP requests
through Dify's SSRF proxy.

**`POST /v1/apps/{app}/workflows/draft/run`** (edit; workflow apps, else `404 app_not_found`). Body: Dify's
`{"inputs": {...}, "files": []}` (`inputs` required; files are not supported yet: a non-empty list is `400 invalid_param`).

* **Consistency.** The server reads the document at its current seq N in one read and renders it as Dify's graph (as the
  export, secret environment variables with their values); edits during the run do not affect it. It writes **no ops**: a
  `workflow_runs` row (Dify's columns plus `doc_seq` = N, the graph it ran, the inputs) and one `workflow_node_executions`
  row per node execution (`triggered_from` `workflow-run`; `index` 1, 2, ... in start order).
* **Inputs** are checked as Dify's `_prepare_user_inputs`: one value per start variable in the start node's order (missing
  optional ones take their default or null), required ones present, `number` parsed from text (`"1.5"` -> 1.5, `"7"` -> 7),
  `select` among the options, text `max_length`, `checkbox` from `true/1/yes/on`, `json_object` an object; NUL characters
  removed. `sys.*` are Dify's: `files`, `user_id` (the account), `app_id`, `timestamp`, `workflow_id` (the app id: the draft's
  id), `workflow_run_id`.
* **Refused before streaming** (no run is recorded): `400 invalid_param` (inputs, node data, a model that cannot be
  prepared, an invalid graph), `400 unsupported_node_type` (a node type not run yet: see the changes above; the graph is
  built whole, as Dify builds it), `400 model_runtime_not_configured`, `400 runtime_service_not_configured`.
* **Answer** `200`, `Content-Type: text/event-stream`: Dify's frames, `data: {...}\n\n`, each `{"event", "workflow_run_id",
  "task_id", "data"}` (Dify's member order; `task_id` is the run id in dify-sf), and `event: ping\n\n` after 10 s without a
  frame. Events and `data` as Dify 1.17.1's `WorkflowResponseConverter`:
  * `workflow_started` `{id, workflow_id, inputs (inputs + sys.*), created_at, reason: "initial"}`;
  * `node_started` `{id (the node execution), node_id, node_type, title, index (1), predecessor_node_id (null), inputs (null),
    inputs_truncated, created_at, extras, iteration_id, loop_id, agent_strategy}`;
  * `text_chunk` `{text, from_variable_selector}`: the answer / end templates streamed in order (an end node streams its
    outputs joined by newlines; an LLM's tokens as they come when its text is the next part of the template);
  * `reasoning_chunk` `{message_id: null, reasoning, node_id, is_final}` (separated reasoning shown by a template);
  * `node_retry` (a failed attempt that is retried: `status` `retry`, `retry_index`) and `node_finished` `{id, node_id,
    node_type, title, index, predecessor_node_id, inputs, inputs_truncated, process_data, process_data_truncated, outputs
    (a start node's are its inputs), outputs_truncated, status (succeeded | failed | exception), error, elapsed_time,
    execution_metadata (null when empty), created_at, finished_at, files, iteration_id, loop_id}`;
  * `workflow_finished` `{id, workflow_id, status (succeeded | partial-succeeded | failed | stopped), outputs, error,
    elapsed_time, total_tokens, total_steps, created_by {id, name, email}, created_at, finished_at, exceptions_count,
    files}`; the stream ends after it.
* **Engine rules** (graphon's): nodes run as soon as all their incoming edges are decided and one was taken (joins wait,
  skipped branches propagate), up to `COLLAB_RUNTIME_MAX_WORKERS` (10) at once; a branch node (if-else, question classifier,
  any node with the fail-branch strategy) takes the edges of its handle. A failed node with `retry_config.retry_enabled`
  (LLM, code, HTTP request) is retried after `retry_interval` ms up to `max_retries`; then its `error_strategy`: none fails
  the run with the node's error, `fail-branch` continues on the `fail-branch` edge with outputs `error_message`,
  `error_type`, `default-value` continues with the default values plus those. Every failed attempt counts in
  `exceptions_count`, and a run with any ends `partial-succeeded` (as graphon). Limits: `COLLAB_RUNTIME_MAX_STEPS` (500 node
  starts) and `COLLAB_RUNTIME_MAX_TIME_SECONDS` (3600) stop the run (`stopped`, "Aborted: Maximum execution steps exceeded:
  501 > 500").
* The run continues when the client goes away; **`POST /v1/apps/{app}/workflow-runs/tasks/{task}/stop`** (edit; workflow
  and chatflow apps) stops it: `workflow_finished` with `status` `stopped`, `error` "Aborted: User requested stop"; nodes
  still running are recorded `failed` with that error (Dify's persistence). Answers `{"result": "success"}`, also for
  unknown or finished tasks (as Dify).

**`GET /v1/apps/{app}/workflow-runs`** (member; workflow and chatflow apps): Dify's `WorkflowRunPaginationResponse`
`{"limit", "has_more", "data": [{id, version ("draft"), status, elapsed_time, total_tokens, total_steps,
created_by_account {id, name, email}, created_at, finished_at, exceptions_count, retry_index (null)}]}`, newest first;
query `limit` (1-100, 20), `last_id` (a run id: the page after it; unknown: `400 invalid_param` "Last workflow run not
exists"), `status`, `triggered_from` (`debugging`, the default, or `app-run`, empty until published runs exist).
**`GET .../workflow-runs/{run}`**: Dify's `WorkflowRunDetailResponse` (`id, version, graph, inputs, status, outputs, error,
elapsed_time, total_tokens, total_steps, created_by_role, created_by_account, created_by_end_user, created_at,
finished_at, exceptions_count`). **`GET .../workflow-runs/{run}/node-executions`**: `{"data": [...]}`, the run's node
executions oldest first, in the single node run's shape (1.13).

**Node types** (graphon's semantics; mocked nodes are never used outside tests):
* `start`, `end`, `answer`: inputs into the pool under the start node; an end node's outputs are the run's outputs; answers
  concatenate into `outputs.answer` (chatflows: P6).
* `if-else`: Dify's cases and conditions (`contains`, `not contains`, `start with`, `end with`, `is`, `is not`, `empty`,
  `not empty`, `in`, `not in`, `all of`, `=`, `≠`, `>`, `<`, `≥`, `≤`, `null`, `not null`, `exists`, `not exists`) with
  Python's comparisons and graphon's errors; the legacy `conditions` shape; `selected_case_id` / handle `false` otherwise.
* `variable-aggregator` / `variable-assigner` (legacy): the first existing variable (per group when grouping is on).
* `assigner` (variable assigner; data `version` "1" = v1, otherwise v2, as Dify picks the class): v1 overwrites, appends to or
  clears `assigned_variable_selector` from `input_variable_selector`; v2 applies `items` in order (`over-write`, `clear`,
  `append`, `extend`, `set`, `+=`, `-=`, `*=`, `/=`, `remove-first`, `remove-last`), each item seeing the earlier ones,
  with graphon's checks of operations, input types and values. Writes keep the variable's type and reach the pool before
  later nodes (or a streaming answer that shows the variable) continue; `process_data` has the new values and
  `__updated_variables`.
* `list-operator`: on an array of strings, numbers or booleans: filter (templates allowed in values), extract the n-th item,
  order (stable, Python's ordering), limit (Python's slice: `size` -1 drops the last item); outputs `result`,
  `first_record`, `last_record`.
* `template-transform` (Jinja2), `code` (`python3`, `javascript`) and the Jinja2 prompts of LLM nodes run in Dify's code
  sandbox (`dify-sandbox` 0.2.15, `POST /v1/sandbox/run`, Dify's runner scripts byte for byte, inputs as base64 JSON, the
  result between `<<RESULT>>` markers). Configuration: `COLLAB_SANDBOX_URL` (empty = no sandbox: such nodes are refused with
  `runtime_service_not_configured`), `COLLAB_SANDBOX_KEY`, `COLLAB_SANDBOX_{CONNECT,READ,WRITE}_TIMEOUT_SECONDS`, and Dify's
  limits `COLLAB_CODE_MAX_*` / `COLLAB_CODE_MIN_NUMBER`, `COLLAB_TEMPLATE_TRANSFORM_MAX_LENGTH`. Code outputs are validated
  as graphon does (declared types, depth 5, string / array / number / precision limits, NUL removal) with Dify's messages
  and `error_type` (`OutputValidationError`, `DepthLimitError`, `CodeNodeError`, `CodeExecutionError`).
* `http-request` calls out through the SSRF proxy (`COLLAB_SSRF_PROXY_URL`, Dify's Squid; empty = direct calls, without
  protection) with Dify's `COLLAB_HTTP_REQUEST_*` timeouts, size limits and SSL default; a destination the proxy refuses
  fails the node with Dify's "blocked by SSRF protection" message. Requests are built as graphon builds them (templates in
  URL, params, headers, auth and body; httpx 0.28's body encoding); `process_data.request` is the raw request with secrets
  and the auth header masked. A non-2xx answer fails the node (`HTTPResponseCodeError`) only with a retry or an error
  strategy. Deviations: no files (a `binary` body fails "cannot fetch file", form-data file fields are skipped, a file
  response fails the node); JSON bodies are not repaired (Dify runs `json_repair`); no `traceparent` header; responses are
  decoded by their charset or as UTF-8.
* `question-classifier` (a branch node): one model call with Dify's classification prompt (chat: a system prompt and two
  worked examples before the query; completion: one prompt); the answer's JSON names the class, whose edge (`class_id`)
  is taken; outputs `class_name` (references rendered), `class_label` (default `CLASS n`), `class_id`, `usage`. An unknown
  class id selects the first class; an answer without JSON fails the node (`could not find json block in the output.`).
* `parameter-extractor`: with a model that can call tools and `reasoning_mode: function_call`, the model calls
  `extract_parameters` with the parameters' JSON schema; otherwise Dify's JSON prompt (chat or completion); invoked with
  `stream: false`. Outputs: each parameter normalized to its type (numbers parsed from text, the type's default when
  missing or unusable) plus `__is_success`, `__reason`, `__usage`; a failed model call fails the node with `__is_success:
  0`, `__reason: "Failed to invoke model"`, `__error`.
* `llm` structured output (`structured_output_enabled` + `structured_output.schema`): models with the `structured-output`
  feature get the schema natively (`json_schema`, and `response_format: json_schema` when offered); other models a JSON
  `response_format` when offered and Dify's schema system prompt. The answer is parsed into `structured_output`; an answer
  that is not a JSON object fails the node ("Failed to parse structured output: ..."). Deviations: a malformed answer is
  repaired only by stripping code fences and taking the first complete JSON object (Dify uses `json_repair`); no
  conversation memory or vision files; no token count before the call.

**Deviations from Dify.** Chatflow debug runs (`/advanced-chat/workflows/draft/run`, conversations, messages, memory)
come with P6. Files are not supported (P5). Values are never offloaded (`*_truncated` false). Dify's `index` of a
`node_started` / `node_finished` frame is always 1 (its FIXME); dify-sf sends the same. A run's `task_id` is its run id.
Node executions are stored when they end (Dify also stores the start). (1.15: retried attempts are kept as Dify keeps
them; iteration and loop nodes run: "Iterations and loops".)

### Iterations and loops (1.15)

Iteration and loop nodes are graphon 0.7.0's containers: the container node only suspends; the engine runs each round in
a child **frame** (the whole graph from the container's start node, with its own node and edge states) whose tasks share
the run's ready queue and workers, then resumes the container with more rounds or its outcome.

* **Iteration** (`iterator_selector` must be a list; null or empty completes at once with `output` `[]`): round *i* runs on
  a copy of the pool with `{iteration}.item` and `{iteration}.index`; `is_parallel` runs up to `parallel_nums` rounds at
  once (else one); `output` collects each round's `output_selector` value in index order; with `flatten_output` (default)
  a list of lists becomes one list. A round with a failed node (no error strategy, retries exhausted): `terminated`
  (default) lets running rounds finish, starts no new one and fails the iteration with the first error;
  `continue-on-error` puts `null` in its place; `remove-abnormal-output` leaves it out. Outputs `output`; `inputs`
  `{iterator_selector}`; `execution_metadata` `{total_tokens, total_price, currency, iteration_duration_map}`.
* **Loop**: the loop variables (`constant`, or `variable` = a selector) are written to `{loop}.{label}`; each round runs on
  the loop's own pool (values of the nodes inside are cleared first); after a round the loop ends when a loop-end node ran
  in it, the `break_conditions` hold (`logical_operator`), or `loop_count` rounds ran; break conditions that hold before
  the first round end it with no round. Outputs: the loop variables and `loop_round`; `inputs` `{loop_count, <variables>}`;
  `execution_metadata` `{total_tokens, total_price, currency, loop_duration_map, loop_variable_map}`.
* A container's LLM usage is its rounds' (in `total_tokens`); `total_steps` and the run's own outputs count only nodes
  outside containers, while the execution limits count every node start. A failure inside a round counts in
  `exceptions_count`; so does the container's own failure. Answers inside a container add to `outputs.answer` (the last
  iteration round's; every loop round's). Containers nest (a loop in an iteration, ...).
* **Stream** (Dify 1.17.1's): `iteration_started` / `loop_started` `{id (the node id), node_id, node_type, title,
  created_at, extras, metadata ({iteration_length} / {loop_length}), inputs, inputs_truncated}`; `iteration_next`
  `{id, node_id, node_type, title, index, created_at, extras}` before each round (an iteration's first rounds at once; a
  loop's from round 1: none before round 0) and `loop_next` with `pre_loop_output` `{}`; `iteration_completed` /
  `loop_completed` `{id, node_id, node_type, title, outputs, outputs_truncated, created_at, extras, inputs,
  inputs_truncated, status (succeeded | failed), error (null), elapsed_time, total_tokens, execution_metadata (a loop's
  with `completed_reason`: loop_break | loop_completed | error), finished_at, steps (the list's length / loop_count)}`.
  The container nodes have no `node_started` / `node_finished` / `node_retry` frames; nodes inside have `iteration_id` /
  `loop_id` (the innermost container of each kind) and those plus `iteration_index` / `loop_index` in
  `execution_metadata`; the rounds' start nodes are not sent. An answer node inside a container sends its answer as a
  `text_chunk` when it finishes.
* **Records**: every node execution, the containers' and each round's, is stored (`index` in start order); nodes inside a
  container save no draft variables (but a variable assigner's conversation variables), as Dify.
* **Retry history**: each failed attempt before a retry is kept in the execution's `process_data.__dify_retry_history`;
  `GET .../workflow-runs/{run}/node-executions` lists it as its own entries before the execution (`id`
  `{execution}:retry:{n}`, `status` `retry`, `retry_index` n, the attempt's inputs, outputs, error, times), whose
  `process_data` then omits the key.

**`POST /v1/apps/{app}/workflows/draft/iteration/nodes/{node}/run`** and **`.../draft/loop/nodes/{node}/run`** (edit;
workflow apps) `{"inputs": {...}}` (`inputs` required: `400 invalid_param` "inputs is required"): Dify's iteration / loop
single run. The graph is the container, the nodes whose `data.iteration_id` / `data.loop_id` is it, and its start node,
rooted at the container; the pool has the default system variables, the environment, the draft variables the nodes read
and `inputs` keyed as Dify's mapping (`{iteration}.input_selector` for the list; `{node}.{key}` of the inner nodes'
references; `{loop}.{label}` for variable loop variables). Errors before streaming as a draft run (`400 invalid_param`
for a missing input or a node of the other kind, `404 not_found` for an unknown node). The answer is a draft run's
stream; it is recorded as a debugging run (run history) whose node executions are `single-step`. The plain single node
run (`.../draft/nodes/{node}/run`) refuses iteration and loop nodes: `400 invalid_param` "Loop and Iteration nodes must use
their engine-backed debug endpoints".

**Deviations from Dify.** graphon builds every node again for each round; dify-sf builds the graph once (same
semantics; a node's model is prepared once). The loop node's first loop-variable values are written by the engine when
the loop starts its rounds (graphon's node writes them while it runs). graphon's dispatcher sleeps the retry interval;
dify-sf waits without blocking other nodes.

### Human input (1.16)

A `human-input` node pauses the whole run and waits for a person. It is a **draft run** node type (`draft_run` lists it);
it has no plain single node run — the panel's own form has its own endpoints, below.

* **The pause.** A waiting form's **select options that come from a variable** are resolved from the pause's own
  variable pool into `option_source.value` (`human_input_policy.resolve_variable_select_input_options`): the live frame,
  the reconnect snapshot and `GET /v1/form/human_input/{token}` all carry the list, while the stored definition keeps the
  source as written. The node's own preview form does not resolve them (Dify's preview entry does not either).
* The node creates the forms of this round (or reuses the waiting one of the same execution), and the run
  records a pause (the run's inputs, the engine snapshot, the node executions in flight and the round's forms) — all
  durable **before** the stream publishes anything. The stream then sends one `human_input_required` per waiting form
  (`{form_id, node_id, node_title, form_content, inputs, actions, display_in_ui, form_token, approval_channels,
  resolved_default_values, expiration_time}`; `form_content` is the **rendered** content — runtime references replaced,
  the form's own `{{#$output.x#}}` placeholders kept, as Dify's `_enrich_hitl_required`) and one `workflow_paused` (`{outputs, paused_nodes,
  reasons, workflow_run_id, elapsed_time, ...}`). The run's `status` is `paused`. The draft run's own stream **ends**
  with `workflow_paused`, as Dify's; the run's channel stays open for the round the answer resumes, which a client follows
  on [the reconnect endpoint](#reconnecting). At most one pause of a run is open at a time: a resume that pauses again records a new pause with the next
  `generation`, and a resume consumes only the decisions its claim took.
* **The form.** `GET /v1/form/human_input/{token}` (any account of the workspace; `404` for an unknown token and for one
  of a surface the console API does not serve — a web app's form until published runs exist, `412`
  `human_input_form_submitted` / `human_input_form_expired`) answers Dify's FormDefinition: `form_content`, `inputs`,
  `user_actions`, `rendered_content`, `expiration_time` (Unix seconds), `default_values`, `node_title`, `display_in_ui`.
  `POST` with Dify's `{inputs, action}` checks the form is still open first (`404`/`412`), then validates with the node's
  own rules (`400 invalid_form_data`: a missing field, a value outside a select's options, an unknown action) and wakes
  the run; the answer is `{}`. Forms are one-shot: the first submission wins.
* **The resume.** A wake claims the pause atomically (`paused → running`) and continues the run from the engine snapshot:
  the answers become the node's outputs (`__action_id`, `__action_value`, `__rendered_content`), `workflow_started`
  (`reason: resumption`) and the names of the decisions the claim consumed (`human_input_form_filled`) are published,
  and the rest of the run follows on the same stream. A run another process holds (after a restart, or a second server on
  the same database) re-attaches from its records the same way.
* **No replay.** A resume continues from the pause's engine snapshot: a node that ran before the pause does not run
  again, so its side effects (a model call, an HTTP request, code) happen once per run. A reconnect reads records and
  publishes no node execution's effects at all.
* **Reconnecting.** `GET /v1/workflow/{runId}/events` (the account that created the run; `404` otherwise) subscribes to
  the live channel first, then rebuilds the state from the records: the run's `workflow_started` (the run's original
  `created_at`), `node_started` + `node_finished` per execution so far, the waiting forms' `human_input_required`, and
  `workflow_paused` (with the pause's `generation` as its identity). Frames published after the mark are streamed live,
  dropping only those the snapshot already described (matched by node execution id and by the pause's `generation` —
  never by timestamp). `include_state_snapshot` (default false) asks for the snapshot; `continue_on_pause` (default
  false) keeps the stream open across a pause instead of ending it at one. A run that already ended answers one
  `workflow_finished` and closes.
* **Timeouts.** The node's `timeout` / `timeout_unit` (`hour`, `day`) ends its wait through the node's `__timeout` branch
  (`human_input_form_timeout`); `COLLAB_HUMAN_INPUT_GLOBAL_TIMEOUT_SECONDS` (default 7 days; 0 disables) expires a run
  that waits longer and stops it. The scan that does both is a task of the server (`HumanInputTimeouts`,
  `COLLAB_HUMAN_INPUT_SCAN_SECONDS`, default 5): once at startup (a stopped server leaves deadlines behind) and then
  periodically; it goes through the same resume and stop paths an answer does.
* **Ending without an engine.** A stop of a paused run, an app deletion, a global timeout and every resume that fails
  after its claim end the run through one entry: the durable row, then exactly one `workflow_finished` on the run's
  channel, then the channel is released — a connection that is already attached never waits for frames nobody will send.
* **Keep-alives.** The ping belongs to the run's channel, not to a round: a run that waits for a person keeps sending
  `event: ping` while it waits (Dify's queue pings regardless of what is running).
* **Numbering.** A resumed round continues the run's execution numbering from the highest stored `index` (Dify's
  `persistence.py`), so no index repeats and the history keeps its order. A pause's `workflow_paused` carries the
  **round's** start as `created_at` and this round's time as `elapsed_time`, live and after a reconnect; the pause row
  keeps both, with the run's outputs so far. Stopping a paused run closes its pause and its waiting forms; deleting the app closes
  its waiting runs the same way.
* **Delivery.** After the pause is durable, each form whose node enables an `email` delivery method (in the node's
  `delivery_methods`) is mailed to that method's recipients, one message per address, with the node's `subject` and
  `body` (its `{{#url#}}` replaced) and the form's link `COLLAB_WEBAPP_BASE_URL` + `/form/{token}` (without that setting
  the mail is skipped and logged). A mail failure is logged and never unwinds the pause. `display_in_ui` follows
  `human_input_adapter`: true in the console, and for a published run only when a `webapp` delivery method is enabled.
* **The node's own form** (the panel's "Run this step"):
  `POST /v1/apps/{app}/workflows/draft/human-input/nodes/{node}/form/preview` (edit; the app of the route's mode —
  `/workflows/...` a workflow app, `/advanced-chat/workflows/...` a chatflow, another mode `404 app_not_found`) with
  `{"inputs": {...}}` answers `{form_id, node_id, node_title, form_content (rendered with `inputs` and the account's
  draft variables), inputs, actions, display_in_ui: null, form_token: null, resolved_default_values, expiration_time:
  null}`. `.../form/run` with `{form_inputs, inputs, action}` (all required) validates the submission and answers the
  outputs it makes (`__action_id`, `__action_value`, `__rendered_content` included), recorded as the node's draft
  variables — no workflow run happens, as in Dify. A node of another type is `400 bad_request`; an unknown node `404
  not_found`. The panel's delivery test (`.../delivery-test`) is not served: it needs a form a test can own, and a form
  here requires a run.

**Deviations from Dify.** The email link carries the form's own token, not a per-recipient one (Dify mints one access
token per recipient); the body goes out as text in a `<pre>` (this server has no markdown/HTML sanitiser); a
human-input preview/run of a node of another type answers `400` where Dify raises a `ValueError` (a 500).

### Draft variables (1.14)

Dify 1.17.1's draft variable API under `/v1/apps/{app}/workflows/draft/...` (edit; workflow and chatflow apps). Draft
variables are **per account and app** (as Dify), written by draft runs and single node runs with Dify's `DraftVariableSaver`
rules (an LLM's `finish_reason` is not saved; a start node's `sys.` values; the variable assigner saves the conversation
variables it wrote; nodes inside an iteration or loop save nothing; `__dummy__` marks nodes without other outputs), stored
in `workflow_draft_variables` beside the document (with the doc seq and node execution they came from), never ops.

* `GET .../draft/variables?page=1..100000&limit=1..100` -> `{items, total}` without values: `{id, type (node | sys |
  conversation), name, description, selector, value_type (integer and float shown as number), edited, visible,
  is_truncated: false}`, newest first; `total` on page 1 only (else null). `DELETE` (204) removes all.
* `GET` / `DELETE .../draft/nodes/{node}/variables` -> `{items}` with values (`value`, `full_content: null`); node `sys` or
  `conversation`: `400 invalid_param` (Dify's message).
* `GET` / `PATCH {name?, value?}` / `DELETE .../draft/variables/{id}`: another account's id or not a UUID: `404 not_found`
  "variable not found, id=..."; `PATCH` marks `edited`, the value must fit the stored type.
* `PUT .../draft/variables/{id}/reset`: a conversation variable back to the draft's default; a node or `sys` variable back
  to its node execution's stored outputs; `204` when the variable is gone.
* `GET .../draft/conversation-variables` (filled from the document first, existing values kept), `.../system-variables`,
  `.../environment-variables` (from the document at its current seq; secret values masked) -> `{items}`.
* Single node runs (1.13) read values their `inputs` lack from the caller's draft variables (Dify's variable loader).

Deviations: `PATCH` of a non-editable variable, a type mismatch or a rename onto an existing name, and resetting a
non-editable system variable answer `400 invalid_param` (Dify: 500). Values are never offloaded. No `POST` for environment
or conversation variables: in dify-sf those are document edits (protocol 1.7). Environment secrets are masked (Dify
returns the stored value).

### Model providers (1.9)

Dify 1.17.1's model provider settings (`/console/api/workspaces/current/...`, `api/controllers/console/workspace/
model_providers.py` and `models.py`), under **`/v1/workspace/`**, for the one workspace. Answers have Dify's shapes, so a
client that ports Dify's web code parses them unchanged; the differences are listed at the end. There is no model runtime:
dify-sf stores settings and credentials and serves the catalog; it calls a provider only to check credentials.

**Providers.** The catalog is fixed per server build: the official provider definitions of
[langgenius/dify-official-plugins](https://github.com/langgenius/dify-official-plugins) (Apache-2.0), vendored unchanged at a
pinned commit (`server/Sources/CollabModels/Resources/dify-official-plugins/SOURCE.md`, refreshed by
`tool/refresh-model-providers.sh <commit>`): OpenAI, Anthropic, Gemini (`langgenius/gemini/google`), Azure OpenAI, Tongyi,
Zhipu AI, Moonshot, DeepSeek, Ollama, OpenAI-API-compatible, in that display order. A provider id is
`organization/plugin/provider` (Dify's long form, as in workflow files; `langgenius/openai/openai`) and is **three path
segments** in every URL below (`{provider}`); an unknown provider is `404`.

**Statuses.** A provider is configured when it has a usable current credential (predefined models) or custom models. A
predefined model is `active` while its provider has a current credential, else `no-configure`; `disabled` when switched off
(`PATCH .../models/disable`). A custom model is `active` with its current credential. dify-sf only: models of a provider whose
current credential cannot be decrypted (the server's key changed) are `credential-removed` (Dify uses the status for custom
models whose credential was deleted). Lists sort a provider's models by model type, then by the plugin's `_position.yaml`
(looked up by the type value, so as in Dify only types without a hyphen are ordered), then by file name; deprecated models
are left out of the selector lists.

**Credentials.** A provider has any number of named credentials and at most one current one; so has each custom model.
Names are at most 30 characters and unique per provider (per model); without a name the server picks Dify's `API KEY <n>`.
The first credential of a provider becomes its current one; deleting the current one leaves the provider without a current
credential (its models `no-configure`) until a switch; deleting the last one unconfigures the provider. A custom model joins
the model list with its first credential and leaves it with its last.

* **Form rules** (graphon's credential schema validator): only fields whose `show_on` conditions hold are kept (custom models:
  `__model_type` is the model type); an empty required field is `400`, an empty optional one takes the field's default; values
  are strings, `select`/`radio` values must be options, `switch` values `true`/`false` (stored as booleans); other keys are
  dropped. Form errors are `400 bad_request` with Dify's message (`Variable api_key is required`).
* **Check on save**: creating or updating a credential sends one inexpensive authenticated request to the provider, with a
  10-second timeout (`COLLAB_MODELS_VALIDATE_TIMEOUT_SECONDS`): `GET {base}/models` (OpenAI, DeepSeek, Moonshot, Zhipu AI,
  Tongyi in compatible mode), Anthropic's `GET /v1/models`, Gemini's `GET /v1beta/models` (key in a header), Ollama's
  `POST /api/show {"model"}`, Azure OpenAI's `GET /openai/models` (API-key auth), and for OpenAI-API-compatible `GET
  {endpoint}/models` with a 1-token chat (or completion) request when that is `404`/`405`. Base URLs come from the
  credentials (`openai_api_base`, `endpoint_url`, `base_url`, ...). A refusal or an unreachable provider is `400
  credential_validation_failed` with a short reason (the provider's own message, secrets replaced by `***`). Providers or
  configurations without a check (Azure with Entra ID) are saved unchecked; `COLLAB_MODELS_VALIDATE=false` switches checks
  off (`validate` then always succeeds). Only the privileged roles can make the server send these requests.
* **Secrets** (`secret-input` fields) are never sent back: reads mask them with Dify's mask (the first 6 characters, twelve `*`,
  the last 2; twenty `*` for 8 characters or fewer). On update, a secret sent as **`[__HIDDEN__]`** keeps its stored value (the
  web form sends that for an untouched field); if the stored credential cannot be decrypted that is `400` (enter it again).
* **At rest** the whole credential is encrypted (AES-256-GCM, `COLLAB_SECRETS_KEY`, see "Secrets at rest" below). Without a key
  every credential write is `503 secrets_key_missing`; the catalog works, with every provider unconfigured.

| Method | Path (under `/v1/workspace`) | Body / query | Answer |
|---|---|---|---|
| GET | `/model-providers/summary` | - | `200 {"data":[ModelProviderSummary...],"plugins":{}}`: every provider (below) |
| GET | `/model-providers` | `?model_type=` (optional) | `200 {"data":[Provider...]}`: every provider, or those supporting the type |
| GET | `/models/model-types/{type}` | - | `200 {"data":[{"provider","label","icon_small","icon_small_dark","status":"active","models":[Model...]}]}`: only active, non-deprecated models, only providers that have one |
| GET | `/default-model` | `?model_type=` | `200 {"data": null \| {"model","model_type","provider":{"provider","provider_name":"","label","icon_small","icon_small_dark":null,"supported_model_types","models":[]}}}`. Without a stored default the first active model of the type (providers in display order, models in list order) becomes the default and is stored (Dify's `get_default_model`); `null` when there is none |
| POST | `/default-model` | `{"model_settings":[{"model_type","provider"?,"model"?}]}` | `200 {"result":"success"}`; entries without `provider` are skipped; the model must be an active model of the type (`400 Model x does not exist.`) |
| GET | `/model-providers/{provider}/models` | - | `200 {"data":[Model + "provider":{"provider","provider_name":"","label","icon_small","icon_small_dark","supported_model_types","models":[]}...]}`: every model of the provider, every status |
| PATCH | `/model-providers/{provider}/models/enable`, `/disable` | `{"model","model_type"}` | `200 {"result":"success"}` |
| GET | `/model-providers/{provider}/models/parameter-rules` | `?model=` | `200 {"data":[ParameterRule...]}` of an LLM; `[]` without a usable credential or for an unknown model; `400 Model x is disabled.` |
| POST | `/model-providers/{provider}/models` | `{"model","model_type","config_from"?,"credential_id"?,"load_balancing"?}` | `200 {"result":"success"}`; with `config_from: "custom-model"` the custom model (in the list) gets `credential_id` as its current credential (required); load balancing is ignored |
| DELETE | `/model-providers/{provider}/models` | `{"model","model_type"}` | `204`: the custom model leaves the list (its credentials stay: `can_added_models`) |
| GET | `/model-providers/{provider}/credentials` | `?credential_id=` (optional) | `200 {"credentials":{...}}`: that credential's values, or the current one's (`{}` if none), secrets masked |
| POST | `/model-providers/{provider}/credentials` | `{"credentials":{...},"name"?}` | `201 {"result":"success"}` after the check |
| PUT | `/model-providers/{provider}/credentials` | `{"credential_id","credentials":{...},"name"?}` | `200 {"result":"success"}` after the check; `[__HIDDEN__]` keeps a stored secret |
| DELETE | `/model-providers/{provider}/credentials` | `{"credential_id"}` | `204` |
| POST | `/model-providers/{provider}/credentials/switch` | `{"credential_id"}` | `200 {"result":"success"}`: the provider's current credential |
| POST | `/model-providers/{provider}/credentials/validate` | `{"credentials":{...}}` | `200 {"result":"success"}` or `200 {"result":"error","error":"<reason>"}`; stores nothing |
| GET | `/model-providers/{provider}/models/credentials` | `?model=&model_type=[&config_from=][&credential_id=]` | `200 {"credentials":{...},"current_credential_id","current_credential_name","load_balancing":{"enabled":false,"configs":[]},"available_credentials":[{"credential_id","credential_name"}]}`; with `config_from=predefined-model` the available credentials are the provider's, else the model's |
| POST | `/model-providers/{provider}/models/credentials` | `{"model","model_type","credentials":{...},"name"?}` | `201`; the model joins the list if it is not there (`400` for a provider without custom models) |
| PUT | `/model-providers/{provider}/models/credentials` | `{"model","model_type","credential_id","credentials":{...},"name"?}` | `200` |
| DELETE | `/model-providers/{provider}/models/credentials` | `{"model","model_type","credential_id"}` | `204` |
| POST | `/model-providers/{provider}/models/credentials/switch` | `{"model","model_type","credential_id"}` | `200`: adds the model to the list with this credential, or makes it the model's current one (`400 Can't add same credential` if it already is) |
| POST | `/model-providers/{provider}/models/credentials/validate` | `{"model","model_type","credentials":{...}}` | as `credentials/validate` |
| GET | `/model-providers/{provider}/{icon_type}/{lang}` | - | **public**. `icon_type`: `icon_small`, `icon_small_dark`; `lang`: `zh_Hans` (any case) or anything else for `en_US`. The image (mostly `image/svg+xml`), `404` if the provider has none |

Access: reads need any member; everything else, including credential reads and both `validate` calls, needs **privileged**
(owner, admin; Dify's `is_admin_or_owner_required`; Dify lets members validate). Errors: `404 not_found` (unknown provider,
credential, custom model), `400 bad_request` (malformed body, unknown `model_type`, form errors, a name over 30 characters),
`400 credential_validation_failed`, `409 credential_name_exists`, `503 secrets_key_missing`.

Shapes (all i18n objects are `{"en_US","zh_Hans"}`, `zh_Hans` defaulting to `en_US`):

* `ModelProviderSummary` = `{"provider","plugin_id","label","description","icon_small","icon_small_dark","supported_model_types",
  "configurate_methods","preferred_provider_type":"custom","is_configured","custom_configuration":{"status":"active"|"no-configure",
  "has_custom_models","available_credentials":[{"credential_id","credential_name"}],"current_credential_id","current_credential_name",
  "current_credential_usable"},"system_configuration":{"enabled":false}}`. Credentials are listed newest first.
* `Provider` = the summary's provider fields + `"background","help":{"title","url"},"provider_credential_schema":{"credential_form_schemas":[...]},
  "model_credential_schema":{"model":{"label","placeholder"},"credential_form_schemas":[...]}` and
  `"custom_configuration":{"status","current_credential_id","current_credential_name","available_credentials","custom_models":[{"model",
  "model_type","credentials":null,"current_credential_id","current_credential_name","available_model_credentials","unadded_to_model_list"}],
  "can_added_models":[{"model","model_type"}]}`, `"system_configuration":{"enabled":false,"current_quota_type":null,"quota_configurations":[]}`.
  A form field is graphon's `{"variable","label","type","required","default","options":[{"label","value","show_on"}],"placeholder",
  "max_length","show_on":[{"variable","value"}]}` (the plugin YAML's `help` and `url` are not part of it, as in Dify).
* `Model` = `{"model","label","model_type","features","fetch_from":"predefined-model"|"customizable-model","model_properties":{"mode",
  "context_size",...},"deprecated","status","load_balancing_enabled":false,"has_invalid_load_balancing_configs":false}`.
* `ParameterRule` = `{"name","use_template","label","type","help","required","default","min","max","precision","options":[...]}`.
  **Templates** (`use_template`: temperature, top_p, top_k, presence_penalty, frequency_penalty, max_tokens, response_format,
  json_schema) resolve as in Dify, where the plugin SDK builds the schema (`ParameterRule.validate_label`): the template's
  fields with the rule's own keys laid over them (whole values: an own `label` replaces the template's), and `{en_US: name}`
  only when neither has a label. So a rule `{name: temperature, use_template: temperature}` has the label
  `{"en_US":"Temperature","zh_Hans":"温度"}`, type `float`, `0`..`1`, default `0`, precision `2`.
* **Custom models** compute their schema from their credentials, as the plugins' Python does (`get_customizable_model_schema`):
  ported for Ollama and OpenAI-API-compatible (features, `mode` and `context_size`, their parameter rules); the other providers
  with custom models (OpenAI, Anthropic, Tongyi, Moonshot, Azure OpenAI) get a generic schema: temperature, top_p and
  max_tokens from the templates (`max` from the credentials' `max_tokens`), `mode` (default `chat`) and `context_size`
  (default 4096) from the credentials. Azure OpenAI's base-model table (Python in the plugin) is not ported yet. A custom
  model whose credentials the plugin could not read (an OpenAI-API-compatible model without a completion mode) is left out,
  as in Dify.

Differences from Dify: no `tenant_id` members; icon URLs are relative to the server
(`/v1/workspace/model-providers/{provider}/icon_small/en_US`; clients resolve them against the server, as invitation links);
`plugins` is `{}`; no hosted quota (`system_configuration.enabled` is false, `preferred_provider_type` always `custom`); no load
balancing; no per-credential visibility; no plugin installation (the catalog is fixed); no model invocation.

### Secrets at rest (1.9)

Secrets are stored encrypted with **AES-256-GCM** and the server's key `COLLAB_SECRETS_KEY` (base64 of 32 random bytes,
`openssl rand -base64 32`): model provider credentials (the whole credential) and secret environment variables (1.7). A stored
value is `v1:` + base64(nonce | ciphertext | tag); the row it belongs to (credential id, document and reference) is the
associated data, so a value cannot be moved to another row. Keys never appear in logs or answers.

* **No key**: the server starts (and says so in its log) but refuses to store any secret: `503 secrets_key_missing` from
  credential writes, `POST /secrets`, and imports and replacements of Dify files that carry secret values. It never stores a
  secret in plaintext. Sealed secrets cannot be read without the key.
* **A malformed key** (not base64 of 32 bytes) stops the server at startup.
* **Older databases**: secret environment variables that a server before 1.9 stored in plaintext are encrypted at startup once a
  key is configured (idempotent; without a key the server logs how many are still plaintext and keeps reading them).
* **Losing or changing the key** makes the stored secrets unreadable: provider credentials then show as not usable (models
  `credential-removed`, masked reads empty) and must be entered again; secret environment variables export as `""`. There is no
  key rotation yet (the `v1:` prefix leaves room for it). The development compose file sets a fixed development key.

### CORS

Browser clients on another origin are supported. The server answers `OPTIONS` preflights itself and adds
`Access-Control-Allow-Origin: <origin>` (never `*` unless configured so) and `Vary: Origin` to every response for an allowed origin.
Allowed methods: `GET, POST, PUT, PATCH, DELETE, OPTIONS` (`PATCH` since 1.9: enabling and disabling models); allowed request headers: `Content-Type, Accept, Authorization, Last-Event-ID,
Cache-Control` (so `fetch`-based SSE with `Authorization` and `Last-Event-ID` works; the native `EventSource` cannot send custom
headers, use `?lastEventId=` and `?access_token=`);
exposed response headers: `Content-Type`; preflight cache `Access-Control-Max-Age: 600`. Allowed origins are configured with
`COLLAB_CORS_ALLOWED_ORIGINS` (comma separated; entries are exact origins, `scheme://host:*` for any port, or `*`). The default is
`http://localhost:*,http://127.0.0.1:*,http://[::1]:*` (local development). Requests from other origins get no CORS headers, so the
browser blocks them. There are no cookies in this protocol: credentials are bearer tokens in the `Authorization` header (1.8).

### Error responses

Non-2xx responses carry `{"error":{"code":"...","message":"..."}}`.

| HTTP | code | Meaning | Client action |
|---|---|---|---|
| 400 | `bad_request` | Malformed JSON, bad ids, `ops` not strictly increasing in `cseq`, more than 100 ops, bad `Last-Event-ID`, invalid comment content, invalid email or name. | Bug in the client; do not retry the same body. |
| 400 | `invalid_password`, `invalid_token`, `invalid_role`, `cannot_operate_self` | Accounts (1.8): a password that breaks the rule or a wrong current password; an unknown, used or expired activation token; a role that cannot be given; a member action on oneself. | Tell the user. |
| 401 | `unauthorized` | 1.8: no, unknown, expired or revoked access token (or refresh token at `/auth/refresh`). | Refresh once and repeat; if that fails, sign out. |
| 401 | `invalid_credentials` | 1.8, login: unknown email or wrong password (one answer for both). | Tell the user. |
| 403 | `forbidden` | 1.8: the role does not allow it (writes by `normal`/`dataset_operator`, member management or `include_secret` by non-privileged), a client id of another account, the owner as target, a removed member signing in. | Tell the user; do not retry. On `POST /ops`: section 9, "Refused submissions". |
| 403 | `account_banned` | 1.8, login: the account is banned. | Tell the user. |
| 403 | `not_author` | A comment or reply edited, moved or deleted by someone other than its author (comments). | Tell the user; do not retry. |
| 404 | `not_found` | Unknown document (or comment, reply). | `PUT` it (if creation is intended) or give up. |
| 404 | `app_deleted` | 1.10: the document's app was deleted (every document call, the app endpoints). | Tell the user, leave the editor, drop the journal; do not retry. |
| 400 | `unsupported_app_mode` | 1.10, `POST /v1/apps`: a Dify mode dify-sf does not have (`chat`, `agent-chat`, `completion`). | Offer workflow or chatflow. |
| 404 | `app_not_found` | 1.11: an app endpoint of another app mode (Dify's wrong-mode error: annotations of a workflow app, workflow logs of a chatflow, ...). | Do not offer the page for that mode. |
| 400 | `max_keys_exceeded` | 1.11, `POST .../api-keys`: the app has 10 Service API keys. | Delete one first. |
| 400 | `no_file_uploaded`, `too_many_files` | 1.11, annotation import: no `file` part; more than one file. | Send one CSV file. |
| 409 | `setup_done`, `email_taken` | 1.8: `POST /setup` after the install; an email in use. | Sign in instead. |
| 409 | `outstanding_ops`, `cseq_used`, `conflict` | `POST /replace`: the client has unresolved ops; the `cseq` is used; an op of the replacement was refused (nothing committed). | Resolve the ops, then retry with the next cseq. |
| 400 | `version_unconfirmed` | `POST /replace`: the file's DSL version needs the user's confirmation (Dify's pending import). | Ask, then repeat with `confirm=true`. |
| 400 | `credential_validation_failed` | 1.9: the model provider refused the credentials (or could not be reached) when saving them; the message is the short reason. | Tell the user; fix the credentials. |
| 400 | `invalid_param`, `unsupported_node_type`, `model_runtime_not_configured`, `runtime_service_not_configured` | 1.13 / 1.14, single node and draft runs: missing or invalid inputs, invalid node data or a model that cannot be prepared (Dify's message); a node type the server does not run yet; no plugin daemon configured; no code sandbox / HTTP proxy configured for a node that needs one. | Tell the user. |
| 409 | `credential_name_exists` | 1.9: a credential name in use for this provider (or custom model). | Pick another name. |
| 503 | `secrets_key_missing` | 1.9: the server has no secrets key, so it refuses to store secrets (credentials, secret environment variables). | Tell the operator (set `COLLAB_SECRETS_KEY`); do not retry. |
| 413 | `payload_too_large` | Body over 1 MiB. | Split the batch. |
| 429 | `login_rate_limited` | 1.8: too many failed sign-ins for this email (Dify's rule). | Wait (24 hours by default). |
| 400 | `mail_not_configured`, `invalid_email`, `email_code_error`, `password_mismatch`, `account_not_found` | Password reset: no mail on this server; not the code's email; a wrong code; the new passwords differ; the account is gone. | Tell the user. |
| 429 | `email_send_ip_limit`, `password_reset_rate_limit_exceeded`, `email_password_reset_limit` | Password reset: too many mails from this IP; a mail for this address in the last minute; too many wrong codes. | Wait. |
| 503 | `unavailable` | Database unavailable, or the commit outcome was uncertain. | Retry the identical request with backoff. **Safe**: ops are idempotent. |
| 500 | `internal` | Server bug. | Retry with backoff. |

Per-op problems (conflicts, invalid ops, missing nodes...) are **not** HTTP errors: they are `reject` results inside a
`200` response (section 4), so one bad op can never wedge a client's queue.

## 3. Data model

### Value

A config value. Plain JSON maps onto it directly:

| JSON | Meaning |
|---|---|
| `null`, `true`/`false`, integer, string | scalars |
| `[v, ...]` | **atomic list**: replaced as a whole; concurrent edits to it conflict |
| `{ "k": v, ... }` | map (config subtree). Keys must **not** start with `$` |
| `{"$ref": {"node": "n1", "output": "text"}}` | reference to another node's output variable |
| `{"$broken": {"node": "n1", "output": "text"}}` | a reference whose node was deleted. **Server-written only**: clients may not send it, except inside the node of a `restoreNode` (1.6) |
| `{"$items": [{"id": "i1", "value": v}, ...]}` | **keyed list**: ordered items with stable ids, edited with item ops (never conflict across different items) |

### Node, Edge

```json
{"id":"n1","type":"llm","title":"Summarize","x":120,"y":80,"config":{"prompt":"...","model":{"name":"gpt-4o"}}}
{"id":"e1","source":"n1","sourceHandle":"out","target":"n2","targetHandle":"in"}
```

`x`, `y` are integers (layout). `config` is a map of Values.

### Document (as carried by snapshots)

```json
{
  "nodes":  [Node, ...],                      // sorted by id
  "edges":  [Edge, ...],                      // sorted by id
  "app":    {"key": Value, ...},              // 1.7: document-level registers (sorted keys); omitted when empty
  "deletedNodes": {"id": {"seq":9,"client":"c1"}},   // tombstones: ids are never reused
  "deletedEdges": {"id": Stamp},
  "deletedItems": {"id": Stamp},
  "fieldStamps": [{"node":"n1","field":FieldKey,"seq":7,"client":"c2"}],   // last content write per register
  "touches":     [{"node":"n1","client":"c2","seq":7}]                    // last content change per (node, client)
}
```

`app` (1.7) holds the **document-level registers**: a map of Values like a node's config, addressed by ops through the
reserved node id `$app` (section 6, "Document-level registers"). Absent or `{}` means empty. Its stamps are ordinary
`fieldStamps` rows with `"node":"$app"`; removed items are ordinary `deletedItems` tombstones; it has no `touches`.
Decoders must ignore top-level keys they do not know: a snapshot carries `app` whatever `proto` the stream was opened with
(a client older than 1.7 keeps a document without it, and never receives an op that writes it).

`fieldStamps`, `touches` and the tombstones are **part of the document**: the conflict rules (section 6) are
decided by running `validate`/`apply` on this state, on the server and on every client alike. A client that wants
early conflict warnings must keep and update them; a read-only viewer may ignore them. Two clients at the same
`seq` have equal documents *including* these fields.

### FieldKey (a content register)

```json
{"k":"title"}
{"k":"config","path":["model","name"]}
{"k":"item","path":["outputs"],"id":"i42"}      // one element of the keyed list at path
```

### Ops

Every op is an object with a `t` discriminator:

| `t` | Fields | Notes |
|---|---|---|
| `addNode` | `node: Node` | New unique id required. |
| `removeNode` | `node: id` | Deletes edges attached to the node and turns references to it into `$broken` (cascade, applied identically everywhere). |
| `moveNode` | `node, x, y` | Layout. Last writer wins (section 6). |
| `setField` | `node, field: FieldKey, value: Value` | `field` is `{"k":"title"}` (value must be a string) or `{"k":"config","path":[...]}`. |
| `addEdge` | `edge: Edge` | Both endpoints must exist. No duplicate (source, handle, target, handle). |
| `removeEdge` | `edge: id` | |
| `insertItem` | `node, path:[...], item:{"id","value"}, after: id\|null` | Inserts into the keyed list at `path` after item `after` (`null` = front). If `after` no longer exists the item is appended. Creates the list if absent. |
| `removeItem` | `node, path, itemId` | |
| `updateItem` | `node, path, itemId, value` | Replaces one item's value. |
| `restoreNode` | `node: Node, edges: [Edge]` | 1.6. Brings back a deleted node (undo of a delete) with the edges its delete removed, original ids. `edges` may be omitted (= `[]`). Section 6, "Restore". |

`node` may be `$app` (1.7) in `setField` (config fields only), `insertItem`, `removeItem` and `updateItem`: the write goes to the
document-level registers. Node ids starting with `$` are reserved: `addNode`/`restoreNode` of one is `invalid`.

Examples:

```json
{"t":"setField","node":"n1","field":{"k":"config","path":["prompt"]},"value":"Hello {{#start.q#}}"}
{"t":"moveNode","node":"n1","x":300,"y":120}
{"t":"insertItem","node":"code","path":["outputs"],"item":{"id":"7c1e","value":{"name":"result","type":"string"}},"after":null}
{"t":"removeNode","node":"n3"}
{"t":"restoreNode","node":{"id":"n3","type":"code","title":"Parse","x":40,"y":80,"config":{"in":{"$broken":{"node":"n1","output":"text"}}}},"edges":[{"id":"e7","source":"n1","sourceHandle":"out","target":"n3","targetHandle":"in"}]}
{"t":"updateItem","node":"$app","path":["environment_variables"],"itemId":"6f1c","value":{"id":"6f1c","name":"api_key","value":"sk-abc************yz","value_type":"secret","secret_ref":"sec-0123456789abcdef0123456789abcdef","description":""}}
```

## 4. Submitting ops: `POST /v1/docs/{doc}/ops`

Request:

```json
{
  "client": "c-9f2e",
  "floor": 12,                       // optional, see "Abandoning ops"
  "resolveFrom": 5,                  // optional, see "Resolving unknown fates"
  "ops": [
    {"cseq": 12, "base": 340, "op": { ...Op... }},
    {"cseq": 13, "base": 340, "op": { ...Op... }}
  ]
}
```

* `client` + `cseq` is the **idempotency key**. `cseq` starts at 1 for a client id and increases by exactly 1 per op.
  Ops in one request must have strictly increasing `cseq`. At most 100 ops per request.
* `base` is the server `seq` the client had applied (its `lastSeq`) when the user made the edit - or, for an edit that grows out
  of a longer-lived draft, the version the draft *started* from (older bases make stale writes easier to detect, never harder).
  It **never changes on retransmission**; it is what the stale-write rule compares against. **Bases need not be monotone**: a
  client's later op may carry a smaller `base` than an earlier one. The only constraint is `0 <= base <= head`.

Response `200`:

```json
{
  "head": 345,                       // server head after processing this batch
  "high": 13,                        // highest cseq of this client the server has handled
  "results": [
    {"cseq": 12, "status": "ack",    "seq": 341},
    {"cseq": 13, "status": "reject", "reason": {"type":"conflict","node":"n1","field":{"k":"config","path":["prompt"]},"seq":339,"by":"c-77aa"}}
  ],
  "known": {"committed": {"5": 330}, "rejected": {"6": {"type":"nodeDeleted","node":"n9"}}}   // only if resolveFrom was sent
}
```

Result statuses:

* `ack`: the op is committed in the database at global `seq`. This is a promise: it will never be lost.
  A duplicate request for an already committed op returns the same `ack` with the same `seq`.
* `reject`: the op was refused and had **no effect**. `reason` is one of the codes in section 7. A duplicate request
  returns the same reason (rejections are stored durably).
* `gap`: not processed because an earlier `cseq` of this client has not been handled yet (`expected` = the cseq the
  server wants next). Cannot happen with a client that follows section 9 (one POST in flight, resend from the oldest
  unresolved op); if it does, resend starting at `expected`.

Processing rules (server):

1. The server processes the request's ops **in order**, one request at a time per document (a single sequencer).
2. For `cseq <= high` (already handled): answer from the durable record (`ack` with the original seq, or the original
   `reject`; if neither exists the op was abandoned below a `floor` and the answer is `reject notCommitted`). Nothing
   is applied twice.
3. For `cseq == high + 1`: validate against the current document. If valid: assign the next global `seq`, append to
   the log, apply. If invalid: record the rejection. **Either way `high` advances** (a rejected op still consumes
   its `cseq`).
4. For `cseq > high + 1`: `gap`.
5. `base` must satisfy `0 <= base <= head`; otherwise `reject invalid`.
5b. A duplicate (`cseq <= high`) is recognised by the idempotency key *and* a fingerprint of `(base, op)`. If the same
   `(client, cseq)` arrives with a different op than the one first stored, it is answered `reject clientIdInUse` and nothing is
   applied: it means two processes are using one client id (see section 9, "Client ids").
6. The whole request is committed in **one database transaction** (log rows, rejections, `high`). The response is
   sent only after the transaction committed. Retrying after any failure (timeout, 5xx, connection reset) is safe
   and returns the original outcome.

Ack vs. stream: the `ack` can arrive before the corresponding `commit` event on the stream. The op is *visible in
the confirmed document* once the client has applied that event (section 9).

### Abandoning ops (`floor`)

A client that lost the **content** of in-flight ops (it crashed without a journal) must not leave the server waiting
for them. `floor: N` means "I will never send a `cseq` below N": the server treats every `cseq < N` it has not handled as
abandoned (`high` becomes at least N-1) and answers any late arrival of those as `reject notCommitted`.

### Resolving unknown fates (`resolveFrom`)

With `resolveFrom: M` the response contains `known` for every `cseq` in `[M, high]`: `committed` maps cseq -> seq,
`rejected` maps cseq -> reason. A cseq in that range that appears in neither was abandoned (never applied). A client
that lost its outbox sends `{"client", "floor": nextCseq, "resolveFrom": firstUnresolved, "ops": []}` and then
reports each op as committed / rejected / lost accordingly.

## 5. The event stream: `GET /v1/docs/{doc}/events`

Query parameters (all optional):

* `access_token` (1.8): the access token, for clients that cannot set the `Authorization` header (the browser's native
  `EventSource`). The header wins if both are present. No valid token: `401 unauthorized` (before the stream starts).
* `client`: the client id. Needed for `committed` in snapshot events. 1.8: it must be the caller's own client id or one not
  bound to any account (`403 forbidden` otherwise); naming it here does not bind it.
* `from`: the client's lowest unresolved `cseq`. Snapshot events then include `committed` for `cseq >= from`.
* `lastEventId`: same as the `Last-Event-ID` header (for clients that cannot set headers). The header wins if both are present.
* `proto` (1.6): the protocol version the client implements, `major.minor` (e.g. `1.8`); anything else is `400 bad_request`.
  Without it (or below `1.6`) the stream never carries a `restoreNode` commit; below `1.7` it never carries a commit that
  writes `$app` (see the resume rules below).

Request header `Last-Event-ID: N`: "I have applied everything up to and including seq N." Omit it if you have no
state.

Response: `200`, `Content-Type: text/event-stream`, `Cache-Control: no-store`, `X-Accel-Buffering: no`. The body is a
standard SSE stream (`id:`, `event:`, `data:` lines, blank line terminator). First line: `retry: 1000`.

Event types:

```
id: 341
event: commit
data: {"seq":341,"client":"c-9f2e","cseq":12,"base":340,"op":{...Op...}}

id: 400
event: snapshot
data: {"seq":400,"doc":Document,"committed":{"12":341}}

event: ready
data: {"head":400}

event: comments
data: {"action":"created","comment":"0192f3a1-..."}

event: app
data: {"action":"updated"}

: ping
```

* `commit`: one committed op. `id` = its `seq`. Delivered in strictly increasing, gapless `seq` order.
* `snapshot`: the full document at `seq`; `id` = `seq`. The client **replaces** its confirmed state with it and sets
  `lastSeq = seq`; later `commit` events continue from `seq + 1`. `committed` maps the requesting client's
  `cseq` (>= `from`) -> `seq` for ops committed at or before the snapshot.
* `ready`: no `id`. Sent once after the catch-up part (snapshot or replay) has been delivered. `head` is the server head at
  subscription time. Everything after it is live.
* `comments` (additive, no version change): no `id`. A canvas comment changed (section 2, "Comments"); `comment` is its id,
  `action` one of `created`, `updated` (edited or moved), `deleted`, `resolved`, `reply` (a reply was created, edited or
  deleted). It can arrive at any point, also before `ready`, and does not move the resume point: `Last-Event-ID` and `seq` are
  unaffected, and hole detection ignores it. Best-effort: notifications are not stored or replayed, and reach only streams on
  the server process that handled the change. Clients that do not use comments ignore it, as any unknown event name (SSE).
* `app` (1.11 amendment, no version change): no `id`. What `GET /v1/apps/{app}` answers for the document's app changed
  (section 2, "App detail pages (1.11)", "Live updates"); `action` is `updated`. Same rules as `comments`: any point, also
  before `ready`; does not move the resume point; best-effort (not stored or replayed, only streams on the server process that
  handled the change). Clients refetch `GET /v1/apps/{app}`, and also after every (re)connect. Clients that do not show app
  info ignore it.
* `: ping`: an SSE comment line, sent every **10 s** of silence (and regardless of traffic every 10 s). It keeps NATs and
  proxies open and lets the client detect dead connections (below). Clients ignore its content.

Resume rules (decided by the server when the stream opens, with `head` = current head):

| Situation | Server sends |
|---|---|
| No `Last-Event-ID` | `snapshot` at head, `ready` |
| `0 <= N <= head` and `head - N <= maxReplay` | `commit` for every seq in `(N, head]`, `ready` |
| `head - N > maxReplay` (default 2000) | `snapshot` at head, `ready` |
| `N > head` (the server lost data, or wrong document) | `snapshot` at head, `ready`. The client must adopt it even though it goes backwards. |
| replay case, no `proto` >= `1.6`, and `(N, head]` contains a `restoreNode` | `snapshot` at head, `ready` (1.6) |
| replay case, no `proto` >= `1.7`, and `(N, head]` contains a commit that writes `$app` | `snapshot` at head, `ready` (1.7) |

Live part (1.6, 1.7): when a `restoreNode` is committed, the server ends every stream opened without `proto` >= `1.6` instead of
sending it the commit; when a commit that writes `$app` is committed, every stream opened without `proto` >= `1.7`. Such a
client sees the stream end, reconnects with its `Last-Event-ID` and is caught up with a snapshot (previous rows).

A snapshot can therefore arrive on **any** (re)connect; clients must always handle it. After the catch-up the server
streams new `commit` events as they are committed.

**Hole detection:** the stream is gapless. If a `commit` arrives with `seq != lastSeq + 1` (and `seq > lastSeq`), the client
must drop the connection and reconnect with `Last-Event-ID: lastSeq`. Events with `seq <= lastSeq` are duplicates and
are ignored.

### Heartbeat, timeouts and backoff (recommended values; the reference client uses these)

| Parameter | Value |
|---|---|
| Server ping interval | 10 s (`COLLAB_SSE_PING_SECONDS`) |
| Client stream silence watchdog | no byte (event or ping) for **30 s** -> close and reconnect. Required: this is how half-open connections (peer gone, socket still "open") are detected |
| POST timeout | 10 s; on timeout resend the same body (idempotent) |
| Reconnect / retry backoff | `delay = cap/2 + random(0 ... cap/2)` with `cap = min(15 s, 0.5 s * 2^attempts)`; `attempts` resets when a stream reaches `ready` or a POST gets a response |
| "Network is back" hint (OS connectivity event) | skip the backoff and reconnect immediately |
| Max ops per POST | 100 (reference client: 50) |
| Server `maxReplay` | 2000 (`COLLAB_MAX_REPLAY`) |

## 6. Conflict rules

Rules are evaluated by the **server at commit time** against the current document, and by clients locally (for
early warnings) with identical code. "Content" means everything except node position.

**Stale-write rule.** A content write to a register is *stale* if another client wrote an overlapping register after the
op's `base`. A stale write is **rejected** with `conflict` (naming the newer write: node, field, its `seq`, its author) **unless it
writes the value that is already there**, in which case it is a success (see below). A client never conflicts with its own
earlier writes.

Registers: `title`; each config path (`model` and `model.name` overlap, `model.name` and `model.temp` do not); each list item
(`{"k":"item","path":[...],"id":...}`). A config write at `path` overlaps all items of lists located at or below it, so a
stale whole-list replace conflicts with newer item inserts instead of silently deleting them.

**Same-value rule.** If the new value equals the register's current value, the write is accepted even on a stale base.
It is committed as a normal log entry and acked, but it is a no-op: it changes nothing, **including the version metadata**: no stamp,
no last-writer, no "touched" entry. This matters in both directions: it does not make anyone else's later write stale, and it does not
let its author's *next* stale write pass as "my own last write". Same for removing an already-removed item or title/field writes of
the current value. *Only different values on a stale base are conflicts.*

**Layout (`moveNode`) is last-writer-wins.** Applied in server order, never rejected for staleness, and it does not count
as a content change (a drag never blocks someone's delete). After convergence a node's position is that of the last
committed `moveNode`. Moving a deleted node is `reject nodeDeleted`.

**Lists.** Different items of a keyed list never conflict: `insertItem` is never stale-checked (the id is new), `updateItem`/`removeItem`
are checked per item. Concurrent inserts after the same anchor both succeed and are ordered by server order. Editing a removed item
is `reject itemDeleted`; removing an already removed item succeeds (same-value rule).

**Delete.** `removeNode` conflicts with any content change to that node, or to a field that references it, made by another client after `base`
(the delete would destroy work the user has not seen). Editing a deleted node is `reject nodeDeleted`. A delete rewrites references to the node
into `$broken` markers and removes its edges, identically on every replica. New references to a deleted node are `reject danglingReference`.

**Add/remove edge.** Not stale-checked; existence rules apply (`edgeNotFound`, `duplicateEdge`, endpoints must exist).

**Restore (1.6).** `restoreNode` brings back a node a `removeNode` deleted; it is how a client undoes its own delete, and only
that: **undo is only of one's own operations**, so only the client whose delete made the tombstone (the tombstone stamp's
`client`) may restore the node. The client sends the node as it saw it just before the delete and the edges attached to it then.

Validation, in this order (the first failing check is the reason):

1. `node.id` is empty: `invalid`.
2. The node exists: `nodeExists`. It was never created: `nodeNotFound`.
3. The tombstone was made by another client: `notDeleter` (with `node` and `by` = the deleter), whatever the `base`. This is a
   validity rule, not a staleness rule: replicas apply it to committed entries too. Typical case: a client's delete lost a race
   (it was refused `nodeDeleted` because someone else deleted the node first) and its undo, already sent, would undo the other
   client's delete.
4. A config key starts with `$`, or a value is malformed (as for `addNode`): `invalid`. `$broken` markers *are* allowed in the
   restored config, and references are not checked against the document (they are normalised, below).
5. An edge has an empty id, is listed twice, or has neither `source` nor `target` equal to `node.id`: `invalid`. Nothing else
   about an edge makes the op fail (see "skipped" below).
6. The tombstone is the restorer's own write, so it is never stale for it: an undo may be sent with any `base`, even before its
   delete is confirmed.
7. Like a delete, a restore rewrites fields of other nodes (`$broken` -> `$ref`, below). It conflicts with any other client's
   write, after `base`, to one of those fields: `conflict` naming that write.

Effect (identical on every replica):

* The id leaves `deletedNodes` and the node is added with every reference in its config **normalised**: a reference (`$ref` or
  `$broken`) is `$ref` if its target node exists (or is the restored node itself) and accepts the output name (declares it, or
  declares no outputs), and `$broken` otherwise. A reference to a node deleted in the meantime therefore comes back broken.
* Each listed edge is re-created with its id, and leaves `deletedEdges`, if and only if this very delete removed it (its tombstone
  stamp equals the node's), both endpoints exist, and no live edge has the same `(source, sourceHandle, target, targetHandle)`.
  Otherwise the edge is **skipped**: it stays deleted and the rest of the restore still holds. The typical case is an edge whose
  other end was deleted meanwhile; it is skipped, never re-created dangling.
* In every other node, a `$broken` marker that points to the restored node and to an output name it accepts becomes `$ref` again.
  Markers of output names the restored node does not declare stay broken.
* Version metadata: the restore is a content write by its author at its `seq` of the restored node's title and of its **whole
  config**: stamps on `{"k":"title"}` and `{"k":"config","path":[]}` (the empty path overlaps every config path and every list
  item), and a touch of the node. Every rewritten field of another node is stamped and that node touched. Each re-created edge
  touches both endpoints (as `addEdge`).

Consequences for concurrent ops:

* A content write (`setField`, `updateItem`, `removeItem`) to the restored node by another client whose `base` is before the
  restore is a `conflict` naming the restore (`field` `{"k":"config","path":[]}` or `{"k":"title"}`), unless it writes the value
  that is there (same-value rule). This rule is conservative: it also refuses such a write to a field that the restored node does
  not have. The delete removed the node's version metadata, and without this rule a stale writer could overwrite content it never
  saw. A `removeNode` of it with such a `base` is a `conflict` as well. `moveNode` (last writer wins) and `insertItem` (never
  stale-checked) are unaffected, as everywhere.
* Ops on the node sequenced while it was deleted were rejected (`nodeDeleted`) and stay rejected. After the restore the node
  accepts ops again (clients drop the early "doomed" warning when their view validates the op again).
* Two restores of one node (by its deleter, e.g. a retried undo sent as a new op): the first wins, and the second is
  `nodeExists`. If the node was deleted again in between, by someone else, the second is `notDeleter`. A restore and a delete of an edge's other endpoint:
  the server order decides. If the endpoint's delete is first, the edge is skipped. If the restore is first, the endpoint's delete
  removes the edge like any other edge.
* A restore cannot bring back an edge that a `removeEdge` deleted, nor an edge that a different delete removed (for example the
  earlier delete of the other endpoint). Undo in reverse order (last delete first) restores everything.

**Replacing the document (`POST /replace`).** The replacement's ops are this client's ops, under cseqs the client reserves:
1. Wait until the outbox is empty (every op committed or rejected), and refuse new edits locally until step 3.
2. Send `POST /v1/docs/{doc}/replace` with `client` = this client's id and `cseq` = `nextCseq`. On a transport error, a timeout or
   a `503`, repeat the identical request (a committed replacement is answered `replayed`).
3. On `200`, set `nextCseq = next_cseq` (persist it like any counter) and accept edits again. The replacement arrives on the
   stream as commits of this client whose cseqs are in no outbox entry; they are applied like any commit. On a `4xx`, nothing
   was written: `nextCseq` stays.
A client that crashes between steps 2 and 3 restarts with `nextCseq` = the reserved cseq: if the replacement was committed, its
next op is answered `clientIdInUse` and the client moves to a new id (above), re-sending its unsaved edits. The replacement is
not an entry of the editor's undo history; clear the history after it (Dify reloads the draft and starts a new one), since
entries recorded before it may no longer apply.

**Document-level registers (1.7).** The document's `app` map is written through the reserved node id `$app`, which always
exists (never `nodeNotFound`/`nodeDeleted`). Allowed: `setField` with a `config` field, `insertItem`, `removeItem`, `updateItem`;
validation and effect are those of the same op on a node whose config is `app`, with the same conflict rules: each config path
and each list item is a register, stamped in `fieldStamps` under node `$app` (stale-write rule, same-value rule, the overlap
rules above, removed items tombstoned in `deletedItems`). Item ids share the document's tombstones (`itemExists` for an id used
anywhere before). Differences:

* `$app` has no title, position, edges or touches: `setField` with `{"k":"title"}`, `moveNode`, `removeNode`, `restoreNode` and an
  edge with `$app` as `source` or `target` are `invalid` (`"title is not allowed on $app"`, `"moveNode is not allowed on $app"`,
  `"removeNode is not allowed on $app"`, `"edge endpoint is not allowed on $app"`). Nothing deletes it, so there is no
  delete-vs-edit rule for it.
* Node ids starting with `$` are reserved: `addNode` and `restoreNode` of such an id are `invalid` (`"node id $x is reserved
  (ids starting with $)"`). Any other op naming a `$` id other than `$app` is `nodeNotFound`.
* Values written to `$app` contain no references: a `$ref` is `invalid` (`"references are not allowed in $app"`), a `$broken`
  is `invalid` as everywhere. (Dify's selectors of environment and conversation variables, `["env","x"]` and
  `["conversation","x"]`, are plain lists in node configs, not references.)

## 7. Reject reasons

`reason` is an object with a `type`:

| `type` | Extra fields | Meaning |
|---|---|---|
| `conflict` | `node`, `field` (FieldKey or `null` = whole node), `seq`, `by`, optional `byName` | Stale write with a different value; the newer write at `seq` by `by` (a client id) is kept; `byName` is the name of the account `by` belongs to (1.8; 1.3: its display name), when it belongs to one. UI: show the winning value and offer "re-apply mine" (re-send as a new op based on the latest version). |
| `nodeDeleted` | `node` | The node was deleted. |
| `nodeNotFound` | `node` | Unknown node id. |
| `nodeExists` | `node` | Node id already used (even if deleted). |
| `edgeNotFound` / `edgeExists` / `duplicateEdge` | `edge` | |
| `danglingReference` | `node` | The value references a node that does not exist. |
| `itemNotFound` | `item` | Unknown list item. |
| `itemDeleted` | `item` | The item was removed. |
| `itemExists` | `item` | Item id already used (even if removed). |
| `notDeleter` | `node`, `by` | 1.6, `restoreNode` only: the node was deleted by `by`, not by you; only the deleter may undo a delete. |
| `invalid` | `message` | Malformed op / bad path / forbidden value (e.g. `$broken`, reserved key, float) / an op `$app` does not take or a reserved `$` node id (1.7). |
| `notCommitted` | none | The cseq was handled (abandoned below a `floor`) but never committed. |
| `clientIdInUse` | none | This `(client, cseq)` was already used for a *different* op: another process shares your client id. Nothing was applied. Stop using this id (section 9). |

`forbidden` (1.8) is not a server reason: clients finish ops whose `POST /ops` was refused with `403 forbidden` as rejected
with this local reason (section 9, "Refused submissions").

`restoreNode` (1.6) uses `invalid`, `nodeExists` (the node is not deleted, e.g. restored already), `nodeNotFound` (no such node
ever), `notDeleter` (someone else deleted it) and `conflict` (a field the restore would rewrite in another node).
A `conflict` whose `field` is `{"k":"config","path":[]}` names a restore: the stale op's node was restored after its `base`.

`conflict`, `nodeDeleted`, `danglingReference`, `itemDeleted`, `notDeleter` are *stale-based*: they will certainly repeat on the server, so a
client may warn the user as soon as a newer remote commit makes a pending op doomed (and hide it from the local view) before the
server confirms.

## 8. Durability and recovery (what a client may rely on)

* `ack` is sent after the database transaction (ops + rejections + per-client `high`) committed. Killing the server at any
  instant never loses an acked op.
* A server restart loses no state. Streams are cut; clients reconnect with `Last-Event-ID` and get the catch-up.
* If the server cannot tell whether a commit happened (connection lost mid-commit) it answers `503`; the retry is answered
  from the database.
* Several server processes may run against one database; a per-document row lock + revision check makes sure only one
  sequences at a time (architecture.md).

## 9. Client algorithm (normative)

State: `confirmed` (document at `lastSeq`), `outbox` (unresolved ops in cseq order), `view` = `confirmed` + outbox ops that still
validate on top of it (recomputed after every change: this is the rebase).

**Local edit.** Validate against `view`; if invalid report `localInvalid` and stop. Otherwise assign `cseq = nextCseq++`,
`base = lastSeq`, apply to `view`, append to `outbox`. If you keep a write-ahead journal (recommended), persist the outbox and
`nextCseq` **before** sending.

**Sending.** Keep **at most one POST outstanding**. Send the oldest unresolved ops (up to 50) that are not yet acked. When the
response arrives, process it and, if unsent ops remain, send the next batch. If no response within 10 s (or a transport/5xx error),
resend the same ops after backoff. Duplicate responses are harmless.

**Response handling.** `ack(seq)`: if `seq <= lastSeq` the op is committed now; otherwise remember `ackedSeq = seq`, keep the op in
the view, do not resend it, and finish it when the stream delivers `seq` (or a snapshot at/after `seq`). `reject(reason)`: the op is
finished as rejected: remove it from the view, tell the user (with the op, so they can re-apply it). `gap`: resend from the oldest unresolved op.

**Signing in (1.8).** Before anything else the client needs an access token (`POST /v1/auth/login`, or setup/activation) and
sends it with every request. On a `401 unauthorized` from any request (a POST, the stream, the comments, ...) it refreshes once
(`POST /v1/auth/refresh`, one refresh at a time even when several requests fail together) and repeats the request with the new
token; if the refresh is refused, the session is over: sign the user out (keep the journal: the same account may resume it
after signing in again). A `401` is not a transport failure to back off from, and a `403 forbidden` on `POST /ops` is not
either: see "Refused submissions".

**Refused submissions (1.8).** `403 forbidden` on `POST /ops` (the account's role cannot edit, typically because it was changed
while the editor is open; or the client id belongs to another account) refuses the whole batch and applies nothing. It is
final, not a transport failure:
* Do not resend the batch and send no other ops; refuse new edits locally (reason `forbidden`, like any `localInvalid`) until
  the client learns that it may edit again. Tell the user once ("You don't have permission to edit this workflow - your changes
  were not saved") and show the editor read-only.
* Finish every op that still waits for a verdict (not acked) as **`rejected` with the local reason `forbidden`**
  (`{"type":"forbidden"}`; the server never sends it as a per-op reason): not saved, removed from the view and from the journal,
  so a restart does not resend it. First open a new stream and wait for its `ready`: an earlier copy of the same ops (a POST
  that timed out) may have been committed before the refusal, and only a stream opened after the refusal is sure to deliver
  that commit. Ops it shows committed are `committed`; an op a snapshot listed in `committed` is committed (it cannot be
  re-sent to verify it); an op whose content was lost is `lost`. Outcomes stay in cseq order, as always.
* Re-read the account (`GET /v1/account`) to learn its role; while the role cannot edit, re-read it now and then (the reference
  app: every 30 s and when its window comes back). When it can edit again, resume. The server never handled the cseqs finished
  as `forbidden` (its `high` is below them), so the next POST, sent at once (with `"ops": []` if there is nothing else to send),
  carries `floor` = the oldest cseq the client will still send; a late copy of a refused op is then answered `notCommitted`.
* A client that restarted before such a `floor` got through cannot know it from its journal: when the server answers `gap`
  with an `expected` below the oldest cseq the client will still send, the client sends `floor` = that cseq with the batch.

**Stream handling.** Open the stream with `Last-Event-ID = lastSeq` (omit if no state) and `client`, `from = oldest unresolved cseq`,
`proto` = the protocol version you implement (1.8).
Apply `commit` events in order to `confirmed`; if the commit is your own (`client`, `cseq` match an outbox op) the op is finished as
committed. On `snapshot`, replace `confirmed`, set `lastSeq`, finish ops listed in `committed`. After every change recompute `view`;
a pending op that no longer validates because of a newer remote commit raises an early `conflictDetected` warning (once) and is hidden
until the server's verdict arrives. On stream error/EOF, silence watchdog, or a hole: reconnect with backoff.

**Finishing.** Report each op's outcome exactly once, in cseq order: `committed(seq)`, `rejected(reason)`, or `lost`.
`rejected` and `lost` **both mean "not saved"**; the UI should treat them alike (`lost` just cannot offer "re-apply", because the
content is gone). Which one is reported is deterministic: a client that still has the op's content reports `rejected(reason)` when
the server says so; a client that lost the content (volatile crash) reports `lost` for everything the server did not commit
- including ops the server had rejected (it has no content to show with the reason). An op never changes from `committed` to anything
else, and never from `rejected` to `committed`: the server's durable record is the single source of truth and the same query always
returns the same answer. After a process crash an outcome may be reported again (at-least-once); a journaled client repeats the same
outcome, a volatile client may turn an earlier `rejected` into `lost` (still "not saved"). Never treat `lost`/`rejected` as final
for the *user's intent*: only `committed` means saved.

**Crash recovery.**
* *Journaled client:* reload `outbox`/`nextCseq` from the journal, open the stream (no state: you get a snapshot with `committed` for your
  `from`), resend the outbox. Idempotency makes duplicates safe; ops the server already committed come back as `ack`.
* *Volatile client:* persist only `nextCseq` and the oldest unresolved cseq. After a crash send `{"client","floor":nextCseq,"resolveFrom":oldestUnresolved,"ops":[]}`;
  from `known` report committed ops as committed and everything else in the range as `lost`.

**Client ids.** A client id names one cseq stream, so it must be used by exactly one live process at a time. Two browser tabs
or two app instances must not share an id (they would overwrite each other's counters and acknowledge each other's ops). Recommended:
call `POST /v1/docs/{doc}/clients` once per client *instance* (tab/process start) and keep the id (and its counters/journal) in
per-instance storage; or generate a UUID yourself. With a shared store (e.g. IndexedDB), guard the id with a lock (Web Locks API)
and take a new id if the lock is held. The server detects most violations: if an op arrives with a `(client, cseq)` that is already
used for a *different* op it answers `reject clientIdInUse` (and applies nothing). On `clientIdInUse` the client must stop using the id:
obtain a new one, start again at `cseq = 1`, and re-create (re-send as new ops) the user's unsaved edits.

**Never** reuse a `cseq` for a different op, and never reuse a client id after losing its counters (use a new id instead).

**Client ids and accounts (1.8).** A client id belongs to the account that obtained it (or first used it); a journal therefore
belongs to an account too. When a different account signs in on the same device, start with a new client id (the old one's
ops would be `403`). The unit of identity for people is the account (names, comments, presence: several tabs of one account
are one user); the unit of the op stream, of idempotency and of undo stays the client id.

**Undo of a delete (1.6).** Before submitting `removeNode`, keep the node and its edges as the view shows them. To undo, submit
`restoreNode` with them (as a new op, `base = lastSeq` as usual). Only undo your own deletes: a restore of a node someone else
deleted is `notDeleter`. "Own" means the same **client id**, also since 1.8: undo stacks live in one app instance (Dify's
workflow history is per browser tab too), and a second tab of the same account has not seen the delete in its history, so it
has nothing to undo; restoring by account would let one tab silently revive what another tab deleted. If it is rejected with `conflict`, the document changed in a way the undo would overwrite; show it like any
conflict.

**Document-level registers (1.7).** Edit variables and features with item and config ops on node `$app`, like node config;
conflicts are reported the same way. To set a secret environment variable, first `POST /v1/docs/{doc}/secrets` with the
plaintext, then write the variable with `value` = the returned mask and `secret_ref` = the returned reference; keep the
`secret_ref` of a secret variable when you edit its other members. Dify does not put variable edits into the workflow
history; the reference client's undo does not record writes of `$app` either.

## 10. Examples

Create and use a document (1.8: every request below carries `Authorization: Bearer <access token>`, obtained first):

```
POST /v1/auth/login {"email":"alice@example.com","password":"alice-pass-1"}
                             -> 200 {"access_token":"q3Rk...","refresh_token":"Zp0a...","account":{...,"role":"owner"}}
PUT /v1/docs/demo            -> 201 {"id":"demo","head":0,"created":true}
GET /v1/docs/demo/events     -> snapshot (seq 0), ready
POST /v1/docs/demo/ops {"client":"a","ops":[{"cseq":1,"base":0,"op":{"t":"moveNode","node":"llm","x":10,"y":20}}]}
                             -> {"head":1,"high":1,"results":[{"cseq":1,"status":"ack","seq":1}]}
(stream)                     <- id: 1 / event: commit / data: {"seq":1,"client":"a","cseq":1,"base":0,"op":{...}}
```

Two users write the same field concurrently (both based on version 0), different values:

```
A: POST ... {"cseq":1,"base":0,"op":{"t":"setField","node":"llm","field":{"k":"config","path":["prompt"]},"value":"A"}}  -> ack seq 1
B: POST ... {"cseq":1,"base":0,"op":{"t":"setField","node":"llm","field":{"k":"config","path":["prompt"]},"value":"B"}}  -> reject conflict {node:"llm", field:{...}, seq:1, by:"A"}
```

Same values: B's write of `"A"` would have been `ack` (seq 2, no-op).
