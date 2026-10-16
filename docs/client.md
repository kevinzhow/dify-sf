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
   completes when the op is on disk.
4. **Transport** (`transport/`). `CollabTransport` is two methods (`submit`, `openStream`). `HttpTransport` uses
   `package:http` (POST with an abort trigger on timeout; the SSE GET streamed through `fetch` on the web).
   `SseParser` is ~80 lines, chunk-boundary and CR/LF safe. Every inbound chunk is surfaced as a `PingEvent`, so
   the silence watchdog sees partial frames and keep-alive comments alike. The resume point goes in the
   `Last-Event-ID` header (VM) or the `lastEventId` query parameter (web: avoids a CORS preflight).
5. **Stores** (`store/`). `FileStore`: temp file + fsync + atomic rename, a corrupt file is an error (never an
   empty outbox). `LocalStorageStore` on the web (synchronous). `MemoryStore` for tests, with injectable latency and
   crash semantics (an in-flight write may land or vanish).
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

Client ids are `<name>-<6 hex>` (suffix chosen once per install). The name is shown to others ("Bo"); two windows
that edit the same document need different names.

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
flutter run -d linux --  --server http://127.0.0.1:8080 --doc demo1 --name Alice     # a second window: --name Bo
flutter run -d linux -- --demo                    # in-memory server with a simulated collaborator, no setup
flutter build linux && flutter build web          # both are checked in this branch
```

The web build must be served from the same origin as the server, or the server must answer CORS (see below).
Desktop journals live in the application-support directory (`journals/<doc>.<client>.json`); the web uses
`localStorage` (`dify-sf/<doc>.<client>`).

The Swift server's docker compose file needed two local patches to build and run at commit 16264c9 (see
"Protocol and server notes"); the numbers below were taken against that build.

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

All of the following pass (package: 96 tests with the real server configured, 77 without; app: 15), and `dart analyze` / `flutter analyze` report no issues.

| Suite | What it covers | Result |
|---|---|---|
| `model_test` (21) | stale-write, same-value, overlap, layout-LWW, delete cascade, tombstones, keyed lists, JSON shapes, round trips | pass |
| `scenarios_test` (31) | S1 (no overlap), S2 (same field both orders, overlapping paths, same value, 30 users same value, re-apply), S3 (stale tab by log and by snapshot), S4 (lost request, lost ack, 503 after commit, 40% loss both ways, half-open stream, lost stream event, server unreachable), S5 (journaled/volatile crash, commit-before-ack crash), S6 (fast edits then reload), S7 (stale delete, edit after delete, broken refs, dangling refs, double delete, edge to deleted node), keyed-list conflicts, batching, slow-edit base | pass |
| `random_test` | seeded simulation, 5 fault profiles (calm, lossy, flaky, crashy, chaos), 2-5 clients, journaled and volatile, slow disk, crashes racing writes; checks convergence (I3, including version metadata), I4, log hygiene, exactly-one-fate per op, committed ops in the log with identical content, rejected/lost not in the log, everything in the log known to its client (I5), promised ops resolved | pass; see below for run counts |
| `sse_test` (5), `store_test` (4) | SSE framing at every chunk size, CR/LF; atomic file journal, corrupt file | pass |
| `http_test` (9) | real sockets: convergence, byte-fragmented frames, cut stream resumes with `Last-Event-ID`, silent stream detected by the watchdog, swallowed answers, 503s, journal restart, dead server | pass |
| `storm_test` (2) | the CLI runner on real sockets, calm and with cuts/stalls/swallowed answers/503s/crashes | pass |
| `conformance_test` (19) | against the real Swift server: endpoints, idempotent retransmit, gap, reject reasons, conflict naming the winner, same-value rule, LWW layout, keyed lists, delete cascade, floor/resolveFrom, 100-op limit, snapshot/replay/beyond-head resume, ordering, pings within 11 s, two `CollabSession`s, a short storm | pass (server built from commit 16264c9) |
| app `home_test` (3) | start screen: id validation, settings remembered, well-formed client ids, command line options | pass |
| app `editor_test` (12) | widget tests on an in-memory server: status bar, node drag at 100% and zoomed out, connect by dragging handle to node, title/config edits are single `setField`s on paths, outputs list add/edit/remove, variable picker, delete dialog + broken refs, offline edit -> conflict notice -> re-apply / discard, volatile crash -> "lost" notice, journaled crash -> recovered and sent | pass |

Randomized simulation, `SIM_RUNS=1000` per profile (5000 runs, about 2 minutes):
1,815,385 intended edits, of which 1,612,652 committed, 129,717 rejected (68,365 conflict, 47,720 nodeDeleted,
6,370 edgeNotFound, 4,219 invalid, 2,024 danglingReference, 720 itemDeleted, 299 duplicateEdge), 65,909 reported
lost by volatile clients after 37,429 simulated crashes (every one of them confirmed absent from the log), 30,060
refused locally, 81,738 early conflict warnings, 23,347 re-applies, 20,089 partitions, 45,618 snapshot joins and
32,920 log replays. **0 violations.** Mutation checks were done by hand (each of these makes the suite fail within a few seeds): sending before the journal write
completed, not reconnecting on a stream hole, no `floor` after losing the outbox, not journaling the cseq counter
on edit, no silence watchdog, finishing ops on `ack` instead of on the stream.

Against the real server (docker compose from commit 16264c9, local patches), storm runner:

| Run | Result |
|---|---|
| 8 clients, 10 s, 8 edits/s each, crashes | 236 committed, 5 rejected, 0 violations |
| 20 clients, 30 s, 15 edits/s each, 4 crashes/min each, 30% volatile | 4991 committed, 94 rejected, 90 refused locally, 6 lost (volatile crashes), 28 crashes; latency p50 140 ms, p95 290 ms; 0 violations |
| same, seed 8 | 5590 commits observed live by the auditor and matched against the ledger; 0 violations |

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
* **One window per name.** The journal is keyed by the client id; two live instances with the same id would
  interleave cseqs. The app does not detect this (a lock file or server-assigned ids would).
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

Nothing here needed a protocol change to build the client; these are findings and questions.

1. **Web needs CORS (or same origin).** The server sends no `Access-Control-*` headers and does not answer
   `OPTIONS`. A browser app on another origin cannot POST `application/json` (preflight) or `PUT`, and
   `Last-Event-ID` as a header is also non-simple (the client therefore sends `?lastEventId=` on the web, which the
   spec allows). Needed: `Access-Control-Allow-Origin`, `Allow-Methods: GET, POST, PUT, OPTIONS`,
   `Allow-Headers: content-type, last-event-id`, a 204 on `OPTIONS`, and `Access-Control-Expose-Headers` is not
   required. Alternatively serve the Flutter web build from the server.
2. **`base` for slow edits.** Section 4 says `base` is what the client "had applied when the user made the edit".
   The app uses the version at the *start* of a typing draft, so one client's bases can go down (an older draft
   committed after a newer op). I believe this is safe: a client's own stamp can only hide a foreign write that
   the client already knew about when it made that earlier op (otherwise that op would have conflicted), but the
   comment in `Document.validate` argues "bases are non-decreasing". Worth stating in the spec that non-monotonic
   bases are legal, or that clients must not do this.
3. **Reporting after a crash.** Section 9 says an outcome "may be reported again" after a crash. A volatile client
   can report `rejected` first and `lost` after the restart (it only learns the verdict from `known.rejected`, not
   the op). Both mean "not saved"; the spec could say "the same outcome, or `lost` for a rejection".
4. **Integers on the web** (see gaps): consider limiting document integers to +-(2^53-1) or sending large ones as
   strings, so browser clients are lossless.
5. **Client id uniqueness.** Two tabs or processes sharing a client id silently corrupt each other's cseq stream
   (`gap` / rejected duplicates). A server-issued client id (or a documented rule that ids are per-process) would
   remove the need for client-side locks.
6. **Server image at 16264c9** (for whoever owns `docker/`): `docker compose up --build` fails twice. (a)
   `docker/Dockerfile.server` copies only `Package.swift`, `Vendor` and `Sources`, but `Package.swift` declares a
   test target, so `swift build` stops with "target 'CollabTests' has overlapping sources" (copy `server/Tests`
   too). (b) The resulting binary is built on `swift:6.4` (glibc 2.43) but the runtime stage is `ubuntu:24.04`:
   `GLIBC_2.43 not found` at start. I ran it with the runtime stage `FROM swift:6.4`. Both were patched only in a
   private copy under `/tmp`.
7. Everything else in the conformance suite matched the written protocol, including the `committed` map in
   snapshots, `known`, `floor`, `notCommitted`, the 100-op limit (`400`), the replay window, and keep-alive pings.
