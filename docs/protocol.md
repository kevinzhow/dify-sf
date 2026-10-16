# dify-sf collaboration protocol, version 1

Status: stable for step 1. Breaking changes will be listed in the "Changes" section at the very top of this file.

This document is the contract between the server (`server/`) and any client (the Flutter app, the headless
Swift clients used by the chaos/storm harness). It is meant to be sufficient to write a client without
reading the server code. The reference client state machine is `server/Sources/CollabCore/Client.swift`;
section 9 describes the same algorithm in prose.

## Changes

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
| POST | `/v1/docs/{doc}/ops` | Submit a batch of ops (section 4). |
| GET | `/v1/docs/{doc}/events` | SSE stream (section 5). |

The `example` template is a small workflow: `start` -> `llm` -> `code` -> `answer`, with a variable reference from the
LLM prompt/code node to the start node and a keyed list (`outputs`) on the code node. `empty` has a single `start`
node.

### Error responses

Non-2xx responses carry `{"error":{"code":"...","message":"..."}}`.

| HTTP | code | Meaning | Client action |
|---|---|---|---|
| 400 | `bad_request` | Malformed JSON, bad ids, `ops` not strictly increasing in `cseq`, more than 100 ops, bad `Last-Event-ID`. | Bug in the client; do not retry the same body. |
| 404 | `not_found` | Unknown document. | `PUT` it (if creation is intended) or give up. |
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
| `{"$broken": {"node": "n1", "output": "text"}}` | a reference whose node was deleted. **Server-written only**: clients may not send it |
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
  "deletedNodes": {"id": {"seq":9,"client":"c1"}},   // tombstones: ids are never reused
  "deletedEdges": {"id": Stamp},
  "deletedItems": {"id": Stamp},
  "fieldStamps": [{"node":"n1","field":FieldKey,"seq":7,"client":"c2"}],   // last content write per register
  "touches":     [{"node":"n1","client":"c2","seq":7}]                    // last content change per (node, client)
}
```

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

Examples:

```json
{"t":"setField","node":"n1","field":{"k":"config","path":["prompt"]},"value":"Hello {{#start.q#}}"}
{"t":"moveNode","node":"n1","x":300,"y":120}
{"t":"insertItem","node":"code","path":["outputs"],"item":{"id":"7c1e","value":{"name":"result","type":"string"}},"after":null}
{"t":"removeNode","node":"n3"}
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
* `base` is the server `seq` the client had applied (its `lastSeq`) when the user made the edit. It **never changes on
  retransmission**; it is what the stale-write rule compares against.

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

: ping
```

* `commit`: one committed op. `id` = its `seq`. Delivered in strictly increasing, gapless `seq` order.
* `snapshot`: the full document at `seq`; `id` = `seq`. The client **replaces** its confirmed state with it and sets
  `lastSeq = seq`; later `commit` events continue from `seq + 1`. `committed` maps the requesting client's
  `cseq` (>= `from`) -> `seq` for ops committed at or before the snapshot.
* `ready`: no `id`. Sent once after the catch-up part (snapshot or replay) has been delivered. `head` is the server head at
  subscription time. Everything after it is live.
* `: ping`: an SSE comment line, sent every **10 s** of silence (and regardless of traffic every 10 s). It keeps NATs and
  proxies open and lets the client detect dead connections (below). Clients ignore its content.

Resume rules (decided by the server when the stream opens, with `head` = current head):

| Situation | Server sends |
|---|---|
| No `Last-Event-ID` | `snapshot` at head, `ready` |
| `0 <= N <= head` and `head - N <= maxReplay` | `commit` for every seq in `(N, head]`, `ready` |
| `head - N > maxReplay` (default 2000) | `snapshot` at head, `ready` |
| `N > head` (the server lost data, or wrong document) | `snapshot` at head, `ready`. The client must adopt it even though it goes backwards. |

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
It is committed as a normal log entry and acked, but it is a no-op: it changes nothing, including the version metadata
(so it does not make anyone else's later write stale). Same for removing an already-removed item or title/field writes of
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

## 7. Reject reasons

`reason` is an object with a `type`:

| `type` | Extra fields | Meaning |
|---|---|---|
| `conflict` | `node`, `field` (FieldKey or `null` = whole node), `seq`, `by` | Stale write with a different value; the newer write at `seq` by `by` is kept. UI: show the winning value and offer "re-apply mine" (re-send as a new op based on the latest version). |
| `nodeDeleted` | `node` | The node was deleted. |
| `nodeNotFound` | `node` | Unknown node id. |
| `nodeExists` | `node` | Node id already used (even if deleted). |
| `edgeNotFound` / `edgeExists` / `duplicateEdge` | `edge` | |
| `danglingReference` | `node` | The value references a node that does not exist. |
| `itemNotFound` | `item` | Unknown list item. |
| `itemDeleted` | `item` | The item was removed. |
| `itemExists` | `item` | Item id already used (even if removed). |
| `invalid` | `message` | Malformed op / bad path / forbidden value (e.g. `$broken`, reserved key, float). |
| `notCommitted` | none | The cseq was handled (abandoned below a `floor`) but never committed. |

`conflict`, `nodeDeleted`, `danglingReference`, `itemDeleted` are *stale-based*: they will certainly repeat on the server, so a
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

**Stream handling.** Open the stream with `Last-Event-ID = lastSeq` (omit if no state) and `client`, `from = oldest unresolved cseq`.
Apply `commit` events in order to `confirmed`; if the commit is your own (`client`, `cseq` match an outbox op) the op is finished as
committed. On `snapshot`, replace `confirmed`, set `lastSeq`, finish ops listed in `committed`. After every change recompute `view`;
a pending op that no longer validates because of a newer remote commit raises an early `conflictDetected` warning (once) and is hidden
until the server's verdict arrives. On stream error/EOF, silence watchdog, or a hole: reconnect with backoff.

**Finishing.** Report each op's outcome exactly once, in cseq order: `committed(seq)`, `rejected(reason)`, or `lost`. (After a process
crash the same outcome may be reported again: reporting is at-least-once across crashes.)

**Crash recovery.**
* *Journaled client:* reload `outbox`/`nextCseq` from the journal, open the stream (no state: you get a snapshot with `committed` for your
  `from`), resend the outbox. Idempotency makes duplicates safe; ops the server already committed come back as `ack`.
* *Volatile client:* persist only `nextCseq` and the oldest unresolved cseq. After a crash send `{"client","floor":nextCseq,"resolveFrom":oldestUnresolved,"ops":[]}`;
  from `known` report committed ops as committed and everything else in the range as `lost`.

**Never** reuse a `cseq` for a different op, and never reuse a client id after losing its counters (use a new id instead).

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
