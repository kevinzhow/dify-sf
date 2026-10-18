# dify-sf collaboration protocol, version 1.7

Status: stable for step 1. Breaking changes will be listed in the "Changes" section at the very top of this file.

This document is the contract between the server (`server/`) and any client (the Flutter app, the headless
Swift clients used by the chaos/storm harness). It is meant to be sufficient to write a client without
reading the server code. The reference client state machine is `server/Sources/CollabCore/Client.swift`;
section 9 describes the same algorithm in prose.

## Changes

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
* There is no WebSocket and no server-side session. Every request is self-contained; the only server memory about
  a client is durable (in Postgres).

Guarantees (the three promises of the product):

1. **No acknowledged edit is lost.** An op is acknowledged (`ack`) only after it is committed in the database.
2. **No silent overwrite of newer data.** A content write based on a stale version is rejected with a conflict
   notice unless it writes the value that is already there (section 6).
3. **All clients converge.** Every client that has applied the committed log up to `seq = N` has an identical
   document (including version metadata).

Transport conventions:

* Base URL: `http://host:port`. All paths are under `/v1` except `/healthz`.
* Bodies are UTF-8 JSON (`Content-Type: application/json`). Keys in server output are sorted, clients may send any order.
* Numbers in documents are **64-bit integers only**. Floating point is not representable (a float in a request makes
  that op invalid). Encode decimals as scaled integers or strings.
* `seq` is the global, gapless, per-document sequence number of committed ops: 1, 2, 3, ... Seq 0 is the seed
  document before any op.
* Identifiers: `doc`: `[A-Za-z0-9_-]{1,64}`. `client`: `[A-Za-z0-9_.:-]{1,64}` (a UUID is fine). Node, edge and
  list-item ids: non-empty strings up to 128 bytes, chosen by the client, **globally unique and never reused** (use
  UUIDs).

## 2. Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/healthz` | Liveness + database check. `200 {"status":"ok"}` or `503`. |
| POST | `/v1/docs` | Create a document with a server-generated id. Body optional: `{"template":"example"\|"empty"}`. `201 {"id","head":0,"created":true}`. |
| PUT | `/v1/docs/{doc}` | Create the document if absent (idempotent). Body optional as above. `201` if created, `200` if it existed: `{"id","head","created":bool}`. |
| GET | `/v1/docs/{doc}` | Metadata: `200 {"id","head"}`, `404` if unknown. |
| GET | `/v1/docs/{doc}/snapshot` | Full document at the current head: `200 {"seq":N,"doc":Document}`. For bootstrapping/debugging; the stream also delivers snapshots. |
| POST | `/v1/docs/{doc}/clients` | Issue a fresh unique client id: `201 {"client":"s-<32 hex>"}`, `404` if the document is unknown. Optional body `{"name":"Bo"}` registers a display name (1.3). Use one id per client *instance* (section 9). |
| PUT | `/v1/docs/{doc}/clients/{client}` | Name (or rename) a client id: body `{"name":"Bo"}` (1.3). |
| GET | `/v1/docs/{doc}/clients` | Name directory: `{"clients":{"<id>":"<name>"}}` (1.3). |
| GET | `/v1/docs/{doc}/meta` | Dify app metadata (mode, name, variables, features): `200 {...}` (below), `404` if unknown. Optional, additive. |
| GET, POST | `/v1/docs/{doc}/comments` | Canvas comments: list (`200 {"comments":[Comment...]}`), create (`201 Comment`). Additive (below). |
| GET, PUT, DELETE | `/v1/docs/{doc}/comments/{id}` | One comment: read, edit/move (author only), delete (author only, `204`). |
| POST | `/v1/docs/{doc}/comments/{id}/resolve` | Resolve (anyone, idempotent): `200 Comment`. |
| POST | `/v1/docs/{doc}/comments/{id}/replies` | Reply (anyone): `201 Reply`. |
| PUT, DELETE | `/v1/docs/{doc}/comments/{id}/replies/{rid}` | Edit (author only, `200 Reply`) or delete (author only, `204`) a reply. |
| POST | `/v1/docs/{doc}/secrets` | 1.7. Store the plaintext of a secret environment variable: body `{"value":"..."}` -> `201 {"ref":"sec-<32 hex>","masked":"..."}` (below); `400` without a string `value`, `404` if the document is unknown. |
| POST, PUT | `/v1/docs/import`, `/v1/docs/{doc}/import` | Create a document from a Dify workflow file (1.5). |
| GET | `/v1/docs/{doc}/export` | The document as a Dify workflow file (YAML, or `?format=json`); secret environment variables are `""` unless `?include_secret=true` (1.7). |
| POST | `/v1/docs/{doc}/ops` | Submit a batch of ops (section 4). |
| GET | `/v1/docs/{doc}/events` | SSE stream (section 5). |

The `example` template is a small workflow: `start` -> `llm` -> `code` -> `answer`, with a variable reference from the
LLM prompt/code node to the start node and a keyed list (`outputs`) on the code node. `empty` has a single `start`
node.

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
  features change with ops on `$app` (1.7).

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
unknown or missing reference). Stored secrets are never deleted, also not when the variable is removed.

### Comments: `/v1/docs/{doc}/comments`

Additive and optional (no protocol version change; clients that do not use it are unaffected). Canvas comments mirror Dify
1.17.1's workflow comments (pins on the canvas with a thread of replies and @-mentions). They are a server resource **beside**
the document: not part of it, not in the op log, snapshots, the stream's commits or the export (`GET /export`), and not undoable.

Identity: there are no accounts. The **author** of a comment or reply is the client id that created it (`client` in the
body, or `?client=` for `DELETE`); its name is the client's registered display name (1.3, `GET /clients`), looked up when the
comment is read (so a rename shows everywhere). "Only the creator may edit or delete" means: the same client id. Mentions are
client ids; the candidates are the name directory (`GET /clients`).

| Method | Path | Body | Answer |
|---|---|---|---|
| GET | `/comments` | - | `200 {"comments":[Comment...]}`: all of them, resolved ones included, newest first (Dify's order) |
| GET | `/comments/{id}` | - | `200 Comment` |
| POST | `/comments` | `{"client","position_x","position_y","content","mentioned_client_ids"?:[...]}` | `201 Comment` |
| PUT | `/comments/{id}` | `{"client","content"?,"position_x"?,"position_y"?,"mentioned_client_ids"?}` | `200 Comment`; author only |
| DELETE | `/comments/{id}?client=...` | - | `204`; author only; its replies go with it |
| POST | `/comments/{id}/resolve` | `{"client"}` | `200 Comment`; anyone |
| POST | `/comments/{id}/replies` | `{"client","content","mentioned_client_ids"?:[...]}` | `201 Reply`; anyone, also on a resolved comment |
| PUT | `/comments/{id}/replies/{rid}` | `{"client","content","mentioned_client_ids"?}` | `200 Reply`; author only |
| DELETE | `/comments/{id}/replies/{rid}?client=...` | - | `204`; author only |

```json
{"id": "0192f3a1-...", "position_x": 412.5, "position_y": 180, "content": "Should this be gpt-4o?",
 "created_by": "s-3f9a...", "created_by_name": "Alice", "created_at": "2026-10-18T09:12:03.512Z", "updated_at": "2026-10-18T09:12:03.512Z",
 "resolved": true, "resolved_by": "s-77c1...", "resolved_by_name": "Bo", "resolved_at": "2026-10-18T09:20:44.020Z",
 "mentions": [{"client": "s-77c1...", "name": "Bo"}],
 "replies": [{"id": "0192f3a4-...", "content": "Yes", "created_by": "s-77c1...", "created_by_name": "Bo",
              "created_at": "...", "updated_at": "...", "mentions": []}],
 "reply_count": 1}
```

* Field names follow Dify's `WorkflowCommentDetail` (`position_x`, `position_y`, `created_by`, `resolved_by`, ...). Positions are
  canvas (flow) coordinates, JSON numbers (fractions allowed; this is not a document value). Times are ISO-8601 UTC with
  milliseconds. Members ending in `_name` and `name` are present only when the client registered a display name; `resolved_by`,
  `resolved_by_name` and `resolved_at` only on a resolved comment. Replies are oldest first.
* Ids are server-generated UUIDs (version 7, as Dify).
* `content`: Dify's rule: not blank (after trimming whitespace) and at most 1000 characters (Unicode scalars). Otherwise
  `400 bad_request`; so is a missing or invalid `client`, a missing position on create, or a body of the wrong shape.
* `mentioned_client_ids`: entries that are not valid client ids and duplicates are dropped (Dify keeps only valid ids, once,
  in order); ids need not be in the directory (`name` is then absent).
* `PUT /comments/{id}`: omitted fields stay as they are. Only the author may change anything, **also the position** (Dify lets
  only the creator drag a pin); `content` may be omitted for a move (Dify always sends it). `mentioned_client_ids` omitted keeps
  the mentions, a list (also `[]`) replaces them (Dify). `updated_at` changes.
* `PUT /replies/{rid}`: `content` is required; the mentions are replaced by the list given, **an omitted list clears them**
  (Dify's behaviour).
* Resolve is idempotent as Dify's: resolving a resolved comment answers `200` with the comment unchanged (the first resolver
  and time stay). There is no "unresolve" (Dify has none). Resolving changes `updated_at`.
* Errors: `404 not_found` for an unknown document, comment or reply (a reply id is looked up within its comment); `403` with
  code **`not_author`** when someone other than the author edits, moves or deletes a comment or reply:
  `{"error":{"code":"not_author","message":"only the author may change or delete this comment"}}`.

**Live updates.** After every change (create, edit/move, delete, resolve that changed something, reply created, edited or
deleted) the server sends an `event: comments` on the document's event stream (section 5) to every stream of the document
connected to the same server process. It is a notification only: clients refetch `GET /comments` (or the one comment). The
REST list is the truth; clients must also refetch after every (re)connect of the stream, since notifications are not replayed.

### CORS

Browser clients on another origin are supported. The server answers `OPTIONS` preflights itself and adds
`Access-Control-Allow-Origin: <origin>` (never `*` unless configured so) and `Vary: Origin` to every response for an allowed origin.
Allowed methods: `GET, POST, PUT, DELETE, OPTIONS`; allowed request headers: `Content-Type, Accept, Last-Event-ID, Cache-Control`
(so `fetch`-based SSE with `Last-Event-ID` works; the native `EventSource` cannot send custom headers, use `?lastEventId=`);
exposed response headers: `Content-Type`; preflight cache `Access-Control-Max-Age: 600`. Allowed origins are configured with
`COLLAB_CORS_ALLOWED_ORIGINS` (comma separated; entries are exact origins, `scheme://host:*` for any port, or `*`). The default is
`http://localhost:*,http://127.0.0.1:*,http://[::1]:*` (local development). Requests from other origins get no CORS headers, so the
browser blocks them. There are no cookies or credentials in this protocol.

### Error responses

Non-2xx responses carry `{"error":{"code":"...","message":"..."}}`.

| HTTP | code | Meaning | Client action |
|---|---|---|---|
| 400 | `bad_request` | Malformed JSON, bad ids, `ops` not strictly increasing in `cseq`, more than 100 ops, bad `Last-Event-ID`, invalid comment content. | Bug in the client; do not retry the same body. |
| 403 | `not_author` | A comment or reply edited, moved or deleted by someone other than its author (comments). | Tell the user; do not retry. |
| 404 | `not_found` | Unknown document (or comment, reply). | `PUT` it (if creation is intended) or give up. |
| 413 | `payload_too_large` | Body over 1 MiB. | Split the batch. |
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

* `client`: the client id. Needed for `committed` in snapshot events.
* `from`: the client's lowest unresolved `cseq`. Snapshot events then include `committed` for `cseq >= from`.
* `lastEventId`: same as the `Last-Event-ID` header (for clients that cannot set headers). The header wins if both are present.
* `proto` (1.6): the protocol version the client implements, `major.minor` (e.g. `1.7`); anything else is `400 bad_request`.
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
| `conflict` | `node`, `field` (FieldKey or `null` = whole node), `seq`, `by`, optional `byName` | Stale write with a different value; the newer write at `seq` by `by` is kept. UI: show the winning value and offer "re-apply mine" (re-send as a new op based on the latest version). |
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

**Stream handling.** Open the stream with `Last-Event-ID = lastSeq` (omit if no state) and `client`, `from = oldest unresolved cseq`,
`proto` = the protocol version you implement (1.7).
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

**Undo of a delete (1.6).** Before submitting `removeNode`, keep the node and its edges as the view shows them. To undo, submit
`restoreNode` with them (as a new op, `base = lastSeq` as usual). Only undo your own deletes: a restore of a node someone else
deleted is `notDeleter`. If it is rejected with `conflict`, the document changed in a way the undo would overwrite; show it like any
conflict.

**Document-level registers (1.7).** Edit variables and features with item and config ops on node `$app`, like node config;
conflicts are reported the same way. To set a secret environment variable, first `POST /v1/docs/{doc}/secrets` with the
plaintext, then write the variable with `value` = the returned mask and `secret_ref` = the returned reference; keep the
`secret_ref` of a secret variable when you edit its other members. Dify does not put variable edits into the workflow
history; the reference client's undo does not record writes of `$app` either.

## 10. Examples

Create and use a document:

```
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
