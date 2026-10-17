# Architecture (step 1: collaboration kernel)

## Modules (`server/Package.swift`)

| Target | Role | I/O |
|---|---|---|
| `CollabCore` | Document model, ops, conflict rules, JSON wire format, **sequencer** (server logic) and **client state machine**. Pure Swift, no I/O. | none |
| `CollabInvariants` | Independent oracle (flat path-keyed replay) + invariant checks I1-I6 over plain "evidence". | none |
| `CollabSim` | Deterministic simulator (seeded network with loss/reorder/duplication, client and server crashes), named scenarios, fuzz, mutation switches. Runs the *same* `Sequencer` and `Client` as production. | none |
| `CollabStore` | Postgres persistence with postgres-nio (plain SQL, no ORM). | Postgres |
| `CollabServer` | Vapor 5 app: routes, per-document sequencer actor, SSE hub, configuration (swift-configuration), lifecycle (ServiceLifecycle). | HTTP, Postgres |
| `CollabClientKit` | HTTP/SSE transport + driver that runs the pure `Client` against a real server. | HTTP |
| `CollabHarness` | Chaos/storm harness: worker processes, Toxiproxy/netem fault layer, ledgers, checks. | processes, HTTP |

Executables: `collab-server`, `collab-sim`, `collab-bench`.

The important property: **the simulator and the real server/clients share the same logic code.** The server is a thin
shell (HTTP, SQL, fan-out) around `Sequencer.process`; the client driver is a thin shell around `Client`. Everything that
decides correctness is in `CollabCore` and is fuzzed 10,000+ times in-process and then exercised with real processes.

## The commit path

```
POST /ops  --->  DocumentSequencer (actor, one batch at a time per document)
                   1. load state if needed (latest snapshot + replay of the log tail)
                   2. read durable facts for duplicates (committed seq / stored rejection)
                   3. Sequencer.process on a COPY of the state: validate each op in order, assign seqs
                   4. one Postgres transaction:
                        SELECT rev FROM documents WHERE id=$1 FOR UPDATE      -- fence
                        INSERT ops / rejections, UPSERT client_state.high, (INSERT snapshot)
                        UPDATE documents SET rev = rev+1, head = ...
                   5. only after COMMIT: adopt the copy, publish to SSE subscribers, answer the client
```

* **Ack = committed.** Step 5 happens strictly after step 4. A crash before COMMIT loses nothing that was acknowledged;
  a crash after COMMIT is repaired by the client's retry (idempotency key `(client, cseq)`), which is answered from the database.
* **In-doubt commit.** If the connection dies *during* COMMIT the outcome is unknown. The actor discards its in-memory state,
  answers `503`, and reloads from the database on the next request. The retry then sees whether the batch is there.
  postgres-nio's `PostgresTransactionError` tells "definitely not committed" (closure/rollback errors) from "unknown" (commit error).
* **Rejections are durable** (`rejections` table, `client_state.high`): a retransmit of a rejected op returns the original reason
  and the per-client cseq order survives restarts.

## Single writer per document: the choice

Within a process the writer is an actor plus an explicit async mutex (an actor alone is re-entrant at `await`, which would let two
batches interleave). Across processes (two servers on one database, or a stale process after a pause) I use **a row lock plus a
revision check** rather than an advisory lock:

* every write transaction starts with `SELECT rev ... FOR UPDATE` on the `documents` row and compares `rev` with the revision the
  actor's in-memory state was built from; every write bumps `rev`;
* on mismatch the transaction commits nothing, the actor reloads (snapshot + replay) and re-plans the batch;
* unique constraints `(doc_id, seq)` and `(doc_id, client_id, cseq)` are a second, independent line of defence.

Why not `pg_advisory_lock`: it is held per *connection*, so the lock would need a dedicated connection per document and its loss
(connection drop) would have to be detected by the actor; the row lock is released by the transaction itself, needs no session state,
survives pool reconnects, and fences stale writers even if they never noticed they lost ownership. The cost is one extra statement
per batch. Known limit: SSE fan-out is per process; a commit made through process B reaches process A's subscribers only when A next
touches the document (LISTEN/NOTIFY would fix that; not in step 1).

## Recovery

`Sequencer(snapshot:tail:)` = latest snapshot + replay of `ops` with `seq > snapshot.seq`. A snapshot (the full `Document` incl.
version stamps, JSON) is written inside the commit transaction every `snapshotEvery` ops (default 200); two are kept. The op log is never
truncated, so any client can be caught up from any point and the full history is available for audit.

## Streams

`GET /events` registers a subscriber atomically with the document's head (inside the sequencer's critical section), so catch-up
(read from the log, outside the lock) and the live feed join without gaps or duplicates. Live frames are pre-encoded once per commit.
A subscriber that cannot keep up (buffer of 2000 frames) is cut loose: its client reconnects with `Last-Event-ID` and is caught up
from the log. Keep-alive pings every 10 s let both sides detect dead connections.

## Conflict rules (summary; precise version in protocol.md)

Content registers (title, config paths, list items, node/edge existence) are stale-write protected; identical-value writes are
no-ops that succeed; layout is last-writer-wins; list items have stable ids so different items never conflict; deleting a node
rewrites references into explicit `$broken` markers; restoring it (1.6, undo) turns them back and counts as a write of the whole
node, so writes based on a version before the restore are stale.

## Testing strategy

1. `swift test`: unit tests, 42 named scenarios, 10,000 fuzz runs, mutation tests (the checkers must fail when bugs are injected).
2. `bench/chaos/run.sh`: hundreds of short runs with real processes (server, clients, Postgres, Toxiproxy) and injected faults,
   verified against the database and every client.
3. `bench/storm/run.sh`: the 100-client storm with a ground-truth ledger, across mixes and network profiles.
