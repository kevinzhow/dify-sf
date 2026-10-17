# Client: architecture, how to run, results, gaps

This is the step 1 client for the protocol in `docs/protocol.md`: a pure-Dart package (`packages/collab_client`),
a Flutter editor (`app/`, Linux desktop and web), and a headless multi-client runner for storms. The promise it
has to keep, under latency, loss, disconnects, half-open connections and crashes: **acknowledged edits are never
lost, stale clients never silently overwrite newer data, and all clients converge.**

```
packages/collab_client/        pure Dart, no Flutter
  lib/src/model/               Value, Op, FieldKey, RejectReason, Document (validate/apply), Templates
  lib/src/wire/                protocol messages (JSON), stream events
  lib/src/client/              ClientMachine (pure state machine), CollabSession (driver), stores, transport interface
  lib/src/transport/           HttpTransport (POST + hand-written SSE), SseParser, DocsApi
  lib/src/store/               FileStore (VM), LocalStorageStore (web), platform factory
  lib/src/testing/             FakeServer, FakeTransport/FakeNetwork, HttpFakeServer (real sockets), RandomEditor
  lib/src/storm/               StormRunner + ledger (the library behind bin/storm.dart)
  bin/storm.dart               the headless CLI
  test/                        unit, scenario, randomized, HTTP, storm and conformance tests
app/                           Flutter app (Linux + web)
```

## Architecture

### Layers

1. **Model** (`model/`). A sealed-class port of the reference `CollabCore` types. `Document.validate` and
   `Document.apply` implement the conflict rules of protocol section 6 exactly as the server does (same-value
   rule, last-writer-wins layout, item-level list ops with stable ids, delete cascade to `$broken` markers,
   tombstones, `fieldStamps`/`touches`). Documents have value equality *including* the version metadata, which is
   how convergence is asserted. `toJson` is canonical (sorted keys): a replayed document and a server snapshot
   encode to identical strings.
2. **`ClientMachine`** (`client/machine.dart`). The optimistic client of protocol section 9 as a pure state
   machine: no timers, no I/O, time passed in as an integer. Inputs: `edit`, `tick`, `receiveStream`,
   `receiveResponse`, `streamClosed`, `submitFailed`, `networkAvailable`. Outputs: requests for the driver
   (`SubmitRequestAction`, `OpenStreamAction`) and `ClientEvent`s.
   * `confirmed` = the server document at `lastSeq`; `view` = `confirmed` + unresolved local ops that still
     validate (recomputed after every change: the rebase). A pending op that a newer remote commit made doomed is
     hidden and reported once as `ConflictDetected` (early warning) until the server's verdict arrives.
   * One POST in flight, batches of at most 50, idempotent resend of the same `(client, cseq, base)`.
   * `ack` for a seq the stream has not delivered yet is remembered (`ackedSeq`) and finished when the stream
     (or a snapshot) reaches it. Stream holes (`seq != lastSeq + 1`) reconnect from `lastSeq`. Snapshots are
     always adopted (also backwards). Silence watchdog: no byte for 30 s closes the stream. Backoff:
     `cap/2 + random(0..cap/2)`, `cap = min(15 s, 0.5 s * 2^attempts)`, reset at `ready` / on a POST answer.
   * Exactly one terminal event per op, in cseq order: `OpCommitted`, `OpRejected(op, reason)`, `OpLost`.
   * Journaled mode exposes `durable` (counters + the outbox) with a `durableRevision` so the driver persists
     before sending; volatile mode persists only the counters and reports `OpLost` after a crash unless the
     server committed the op (`floor` + `resolveFrom` handshake).
3. **`CollabSession`** (`client/session.dart`). The driver: a periodic tick (200 ms), the POST loop with a
   per-request timeout (10 s), the stream subscription (a new generation cancels the old one), a coalescing
   **write-behind journal** and the `LinkState` (connecting / live / reconnecting / offline) for the UI.
   *Write-ahead rule:* every POST awaits the journal write that contains its ops and the counters; a failed
   journal write means nothing is sent. `edit(op, {base})` returns an `EditTicket` whose `persisted` future
   completes when the op is on disk. **Client id (protocol 1.1):** the id is not chosen by the app: `start()` uses
   the id saved in the journal, or asks `POST /v1/docs/{doc}/clients` for a fresh one and saves it before anything
   is sent (an explicit `clientId:` exists for tests and tools). If the id turns out to be shared with another live
   process (`reject clientIdInUse`, or a commit under our `(client, cseq)` whose content differs from our pending
   op, which the stream shows even before the server answers us), the machine suspends sending, waits until the
   stream has caught up (so that any of its own ops that did commit under the old id are recognised), the session
   fetches a new id, and `adoptClientId` re-creates every unsaved op under it: same content and **same `base`**,
   cseq restarting at 1. Ops whose content was lost in a crash are reported `OpLost`. A `ClientIdReplaced` event
   carries the old-to-new cseq map; `clientIdInUse` never surfaces as an error or as a generic `Invalid`.
4. **Transport** (`transport/`). `CollabTransport` is three methods (`submit`, `openStream`, `issueClientId`). `HttpTransport` uses
   `package:http` (POST with an abort trigger on timeout; the SSE GET streamed through `fetch` on the web).
   `SseParser` is ~80 lines, chunk-boundary and CR/LF safe. Every inbound chunk is surfaced as a `PingEvent`, so
   the silence watchdog sees partial frames and keep-alive comments alike. The resume point goes in the
   `Last-Event-ID` header on every platform: since 1.1 the server answers CORS preflights and allows that header,
   so the `?lastEventId=` fallback (`HttpTransport(lastEventIdInQuery: true)`) is only for servers older than 1.1.
5. **Stores** (`store/`). `FileStore`: temp file + fsync + atomic rename, a corrupt file is an error (never an
   empty outbox). `LocalStorageStore` on the web (synchronous). `MemoryStore` for tests, with injectable latency and
   crash semantics (an in-flight write may land or vanish). **Journal slots:** because the client id lives in the
   journal and an id may be used by one live process only, a journal is claimed per instance
   (`acquirePlatformJournal`): on the VM the lowest free `<doc>.slot-<n>.json`, held by an exclusive OS lock on
   `<doc>.slot-<n>.lock` (a dead process's lock disappears, so a restarted window finds its crashed predecessor's
   journal); in the browser one `localStorage` entry per tab, named by an id kept in `sessionStorage`.
6. **Testing infrastructure** (`testing/`). `FakeServer` is an in-memory implementation of the server rules
   (sequencer with idempotency/gap/floor/resolveFrom, resume rules). `FakeTransport` + `FakeNetwork` add latency,
   request/response loss, 503 after commit, lost stream events, half-open streams, partitions. `HttpFakeServer`
   serves the same logic over real sockets with the same kinds of faults. `RandomEditor` makes plausible random
   edits.

### Decisions worth knowing

* **`base` is the version the user saw when they started editing.** A text field remembers `lastSeq` at the first
  keystroke of a draft and passes it as `edit(op, base: ...)`. If a remote write landed meanwhile, the stale-write
  rule refuses the edit on the spot (locally, as `LocalInvalid(Conflict)`), the notice shows the winner, and
  "Re-apply on latest" sends the same op with a fresh base. With `base = lastSeq` at send time the slow edit would
  silently overwrite the newer write. This makes a client's bases non-monotonic; see "Protocol notes".
* **Small ops only.** The UI never writes an object it did not change: title = one `setField`, a config field = one
  `setField` on its path, an `outputs` item = `insertItem` / `updateItem` (the item's value, one register) /
  `removeItem`, a drag = throttled `moveNode` (about 8/s), a connection = `addEdge`, a variable pick = one
  `setField` with a `$ref`.
* **A snapshot's `committed` map is a claim about the id, not about our op.** For an op whose content the client
  holds, it is not taken as proof of commit: the op stays unresolved (and out of the view, so it is neither applied
  twice nor warned about) and is re-sent; the server answers a genuine duplicate with the original `ack` and a
  foreign one with `clientIdInUse`. Only ops whose content is gone (volatile restart) are settled from the map.
  This costs one extra POST after a journaled restart and closes the hole in which a process sharing the id would
  be told its edits were saved because the other process's were (found by the seeded shared-id test).
* **Volatile "rejected" after a crash is reported as `lost`.** If a volatile client crashes after a rejection was
  reported but before its counters were persisted, the restart learns the verdict from `known.rejected` but has no
  op content, so it reports `OpLost`. Both mean "not saved".
* **No state is cached on disk** (only counters and the outbox), so a journaled client that restarts offline cannot
  edit until the first snapshot arrives. The edits it did make before the crash are resent.

### The app

`EditorController` (a `ChangeNotifier`) is the only thing that talks to the session. UI pieces: `CanvasView`
(nodes, curves, drag, connect, pan, zoom/fit), `NodePanel` + `ConfigEditor` (generic editor for the config tree,
keyed lists, variable picker, broken references in red), `StatusBar` (link state, "N unsaved edits", seq, mode,
client id, "Reconnect now"), `NoticeOverlay` (non-modal notices). Notices:

* conflict: "Bo changed prompt just now — your change wasn't applied" with **Re-apply on latest** / **Discard**.
  The same notice first appears as an early warning ("Waiting for the server to confirm…", no buttons) and is
  upgraded in place when the verdict arrives.
* other refusals (node deleted, dangling reference, item removed...) in plain words, with Discard.
* lost writes: "N edits were lost — they had not reached the server when the app closed", with a note that volatile
  mode keeps no journal.
* recovery: "Recovered N unsent edits from your last session — sending them now."

Deleting a node asks first and lists the references it will break; afterwards the broken references are shown
explicitly (card badge, summary in the panel, red chip in the field with a picker to repair it).

Client ids come from the server (`s-` + 32 hex digits) and live in the journal slot, so any number of windows can
edit one document. They carry no user name, so notices say "User 3fa2 changed prompt just now..." (the demo's Bo uses
a `bo-<hex>` id and shows as "Bo"). If the server tells a window its id is shared, it switches ids by itself and says
so in a notice ("...switched to a new one and re-sent your N unsaved edits").

## How to run

Toolchain: Flutter 3.47.6 (Dart 3.13), pinned in `.fvmrc` (`fvm use` or put that SDK's `bin/` on `PATH`).

```sh
# package: analyze + tests (no server needed; ~1 minute)
cd packages/collab_client && dart analyze && dart test
SIM_RUNS=1000 dart test test/random_test.dart          # bigger randomized run (default 40 per profile)
SIM_SEED=17 SIM_PROFILE=chaos dart test test/random_test.dart   # reproduce one run

# conformance against a real server (skipped when DIFYSF_URL is unset)
DIFYSF_URL=http://127.0.0.1:8080 dart test test/conformance_test.dart

# headless storm: N clients in one process, ledger as JSON
dart run bin/storm.dart --url http://127.0.0.1:8080 --doc storm1 --clients 20 --duration 60 --rate 15 \
    --crashes-per-minute 4 --volatile-fraction 0.3 --seed 7 --ledger out/ledger.json
dart run bin/storm.dart --chaos --crashes-per-minute 6 -d 20      # no --url: self-hosted in-memory server with faults

# app
cd app && flutter analyze && flutter test
flutter run -d linux -- --server http://127.0.0.1:8080 --doc demo1     # start it twice for two collaborators
flutter run -d linux -- --demo                    # in-memory server with a simulated collaborator, no setup
flutter build linux && flutter build web          # both are checked in this branch
```

The web build talks to the server cross-origin; that relies on the server's CORS support (1.1: default allowed
origins are `http://localhost:*`, `http://127.0.0.1:*`, `http://[::1]:*`, configurable with
`COLLAB_CORS_ALLOWED_ORIGINS`). Desktop journals live in the application-support directory
(`journals/<doc>.slot-<n>.json`); the web uses `localStorage` (`dify-sf/<doc>/<tab slot>`).

The numbers below were taken against the server built from `9bfa9af` (docker compose from a clean
`git archive` of that commit, host ports moved to avoid clashes).

`bin/storm.dart` exit code: 0 = every guarantee held, 1 = violation(s) (listed in the summary), 2 = bad usage.
Each ledger entry: client, incarnation (process lifetime), cseq, the op, timestamps, `status`
(`committed(seq)` / `rejected(reason)` / `lost` / `localInvalid` / `unpersisted` = crashed before the journal had it,
i.e. never promised / `pending` = a bug), whether the early warning was shown, and `reappliesCseq` for re-applies.
After the run the runner checks: every entry has an outcome; each client's confirmed and view documents equal the
server snapshot byte for byte; the ledger against the server's *whole log* (recorded live by a read-only auditor):
committed ops are in the log at the stated seq with the same content, rejected/lost ones are not, nothing in the
log from the run's clients is missing from the ledger, and an op that was not in the journal at a crash never
reached the server.

## Test results

All of the following pass (package: 180 tests with the real server configured, 155 without; app: 16), and `dart analyze` / `flutter analyze` report no issues.

| Suite | What it covers | Result |
|---|---|---|
| `model_test` (21) | stale-write, same-value, overlap, layout-LWW, delete cascade, tombstones, keyed lists, JSON shapes, round trips | pass |
| `scenarios_test` (31) | S1 (no overlap), S2 (same field both orders, overlapping paths, same value, 30 users same value, re-apply), S3 (stale tab by log and by snapshot), S4 (lost request, lost ack, 503 after commit, 40% loss both ways, half-open stream, lost stream event, server unreachable), S5 (journaled/volatile crash, commit-before-ack crash), S6 (fast edits then reload), S7 (stale delete, edit after delete, broken refs, dangling refs, double delete, edge to deleted node), keyed-list conflicts, batching, slow-edit base | pass |
| `random_test` | seeded simulation, 5 fault profiles (calm, lossy, flaky, crashy, chaos), 2-5 clients, journaled and volatile, slow disk, crashes racing writes; checks convergence (I3, including version metadata), I4, log hygiene, exactly-one-fate per op, committed ops in the log with identical content, rejected/lost not in the log, everything in the log known to its client (I5), promised ops resolved | pass; see below for run counts |
| `sse_test` (5), `store_test` (4) | SSE framing at every chunk size, CR/LF; atomic file journal, corrupt file | pass |
| `http_test` (9) | real sockets: convergence, byte-fragmented frames, cut stream resumes with `Last-Event-ID`, silent stream detected by the watchdog, swallowed answers, 503s, journal restart, dead server | pass |
| `storm_test` (2) | the CLI runner on real sockets, calm and with cuts/stalls/swallowed answers/503s/crashes | pass |
| `client_ids_test` (72) | protocol 1.1 ids: `clientIdInUse` parsing and fake-server fingerprint check, server-issued ids saved in the journal and reused after a restart, offline restart with a journal id, two processes sharing an id (POST rejection, noticed from the stream alone, several edits keep order and bases, lost content reported lost), decreasing bases accepted, and 60 seeded runs of 2-3 tabs sharing an id plus others with crashes and partitions in which every promised edit must appear exactly once | pass |
| `conformance_test` (27) | against the real Swift server: endpoints, idempotent retransmit, gap, reject reasons, conflict naming the winner, same-value rule, LWW layout, keyed lists, delete cascade, floor/resolveFrom, 100-op limit, snapshot/replay/beyond-head resume, ordering, pings within 11 s, two `CollabSession`s, a short storm; 1.1: `POST /clients`, `clientIdInUse` (base is part of the fingerprint), CORS preflight and origin allow-list, decreasing bases, two sessions sharing an id; 1.2: the formal model's equal-value trace (stamp and touched set unchanged); 1.3: named ids, rename, directory, `byName` on conflicts (also a name registered after the first answer), invalid name refused; 1.4: reference to a missing output refused, removing an output breaks references | pass (server built from commit `2394dd9`) |
| app `home_test` (3) | start screen: id validation, settings remembered, the session gets a server-issued id, command line options | pass |
| app `editor_test` (13) | widget tests on an in-memory server: status bar, node drag at 100% and zoomed out, connect by dragging handle to node, title/config edits are single `setField`s on paths, outputs list add/edit/remove, variable picker, delete dialog + broken refs, offline edit -> conflict notice -> re-apply / discard, volatile crash -> "lost" notice, journaled crash -> recovered and sent, a second window with the same id -> id replaced, edit re-sent, notice | pass |

Randomized simulation, `SIM_RUNS=1000` per profile (5000 runs, about 3 minutes): 1,816,019 intended edits, of which 1,613,067 committed, 129,989 rejected (68,619 conflict, 47,640 nodeDeleted, 6,450 edgeNotFound, 4,195 invalid, 2,049 danglingReference, 726 itemDeleted, 310 duplicateEdge), 65,746 reported lost by volatile clients after 37,433 simulated crashes (every one confirmed absent from the log), 30,193 refused locally, 82,011 early conflict warnings, 23,242 re-applies, 20,115 partitions, 45,568 snapshot joins and 32,831 log replays. **0 violations.** Mutation checks were done by hand (each of these makes the suite fail within a few seeds): sending before the journal write
completed, not reconnecting on a stream hole, no `floor` after losing the outbox, not journaling the cseq counter
on edit, no silence watchdog, finishing ops on `ack` instead of on the stream.

Against the real server (docker compose from commit `9bfa9af`, group commit and protocol 1.2), storm runner with server-issued ids:

| Run | Result |
|---|---|
| 20 clients, 30 s, 15 edits/s each, 4 crashes/min each, 30% volatile | 6598 commits observed live by the auditor and matched against the ledger, 24 rejected, 154 refused locally, 1 lost (volatile crash), 29 crashes; latency p50 21 ms, p95 70 ms, p99 104 ms; 0 violations |
| 12 clients, 25 s, 12 edits/s each, 20 crashes/min each, 50% volatile | 2655 commits matched, 10 rejected, 88 crashes; p50 17 ms; 0 violations |

(With the previous server build, commit 16264c9: 4991 and 5590 commits, p50 140 ms, also 0 violations.)

Builds: `flutter build linux --release` and `flutter build web --release` succeed (a wasm dry run also succeeds).

## Known gaps

* **Web is built but not run.** There is no Chrome or Node on the build machine (the only Firefox is a snap that
  cannot use `dart test`'s temporary profile), so the web build compiles (also a wasm dry run) but the pure logic,
  `LocalStorageStore`, `fetch` streaming and CORS were never executed in a browser. `localStorage` is not IndexedDB: it survives reloads and tab crashes, not an OS crash before the browser
  flushes, and has a ~5 MB quota.
* **JSON numbers on the web.** The protocol says 64-bit integers; dart2js integers are 53-bit. Values beyond +-2^53
  lose precision in the browser client. Positions and seqs are far below that.
* **No offline start.** The last confirmed document is not cached, so a reload while offline shows nothing until a
  snapshot arrives (the journal still resends the unsent edits afterwards).
* **Shared ids are handled, not prevented, in the browser.** Desktop windows cannot share an id (journal slots are
  locked). A browser tab gets its slot from `sessionStorage`; a *duplicated* tab copies it and shares the journal key.
  The server's `clientIdInUse` check and the stream content check then make one of them move to a new id, but a
  Web Locks based claim would prevent it, and would also let a new tab adopt the journal of a closed tab (today the
  unsent edits of a closed browser tab stay in `localStorage` unclaimed). Not built: no browser here to test it.
* **A volatile client cannot detect a shared id for ops it lost.** After a crash it only has counters; if another
  process used the same cseqs, `known.committed` makes it believe those ops were its own and it reports them
  committed. Journaled clients compare content and are not fooled.
* **No names in conflict notices for real users** (see note 4 below).
* **Large documents.** Every stream event rebuilds the view (O(document) when there are pending ops) and snapshot
  JSON is decoded on the UI isolate. Fine for hundreds of nodes; a big-document run was not made.
* **UI.** No undo/redo, no multi-select, no minimap, one edge style, node types are plain strings with no schema
  (outputs are discovered from the `outputs`/`variables` keyed lists and `llm.text`), no keyboard shortcuts.
  Text fields debounce at 700 ms (and flush on blur); long text is replaced as a whole value (the protocol's
  register is the field).
* **Linux app was not driven in a real window.** The release bundle starts under Xvfb, creates the document on the
  real server and writes its journal; but the build machine has no window manager or screenshot tool that captures
  its GL surface (and no input injection), so layout and gestures were checked with widget tests and offscreen renders
  (`app/test/screenshot_test.dart`, `SCREENSHOT_DIR=... flutter test test/screenshot_test.dart`).
* **Clock.** `tick` is a 200 ms periodic timer; a backgrounded browser tab may throttle it to 1 s, which delays
  retransmits by up to that much but cannot break correctness.

## Protocol and server notes

Protocol 1.1 and 1.2 (as published in `protocol-ready.md`) resolved the items found while building step 1; they are
implemented and tested here. What is left:

1. **Resolved: CORS** (1.1). The web client now relies on it; the conformance suite checks preflight, allowed
   headers and that foreign origins get no headers. It was not exercised from a real browser.
2. **Resolved: non-monotone `base`** (1.1). Documented as legal in `ClientMachine.edit`; a conformance test sends
   decreasing bases.
3. **Resolved: `rejected`/`lost` wording** (1.1). The client matches it: a volatile client reports `lost` for what
   the server rejected before the crash.
4. **Open: user names.** Server-issued ids carry no name, so a conflict notice cannot say "Bo changed prompt"; it
   says "User 3fa2". Suggestion: let `POST /v1/docs/{doc}/clients` take an optional display name and either embed a
   sanitised form in the id (`bo-<hex>`, which the app already renders as "Bo") or serve a small
   `GET /v1/docs/{doc}/clients` directory. (The id syntax allows `bo-<hex>`; uniqueness stays the server's job.)
5. **Open: integers on the web** (see gaps): consider limiting document integers to +-(2^53-1) or sending large
   ones as strings, so browser clients are lossless.
6. **Resolved: client id uniqueness** (1.1, `POST /clients`, `clientIdInUse`), with the two limits listed under known
   gaps (duplicated browser tab, volatile client with lost ops).
7. **Resolved: same-value rule** (1.2). The Dart `Document.apply` already treated an equal-value write as a pure
   no-op; the formal model's three-step trace is a named regression test at the document level, through a
   `CollabSession` over the fake server, and against the real server.
8. **Resolved: docker build** (server commit after 16264c9 fixed both problems I reported).
9. **Resolved: display names** (1.3, server `4954ec4`). `CollabSession(displayName:)` normalizes the name
   (`normalizeDisplayName`: control characters to spaces, trimmed, at most 64 UTF-8 bytes), sends it with
   `POST /clients` for a fresh id and names a journal or explicit id with `PUT /clients/{id}` (best effort, retried
   while the server is unreachable). `Conflict.byName` carries the author's name; it is presentation only and does
   not take part in equality. `DocsApi.clientNames` reads the directory. The app has an optional "Your name" field
   (and `--name`), and conflict notices use `byName`, falling back to the short id tag.
10. **Resolved: declared outputs** (1.4). `Document` applies the same rules as the server: references must name a
   declared output (the `name` of an `outputs` item, or its id), removing or renaming an output breaks references to its
   name and conflicts with unseen writes to them; `integrityProblems` reports references to missing outputs. The app's
   notice for `danglingReference` now reads "The variable you picked from X no longer exists".
