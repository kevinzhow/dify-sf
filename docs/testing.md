# How dify-sf is tested

The goal: no edit a user saw accepted is ever lost or silently overwritten, under any interleaving, network fault or
crash, at 100 concurrent users on a 500-node workflow. Every layer below checks the same invariants against a ground
truth it keeps itself; none of them trusts the system under test to report its own success.

## Invariants (checked by every layer)

| | invariant | meaning |
|---|---|---|
| I1 | durability | every acknowledged edit is in the durable log, and the server state equals a replay of the log |
| I2 | no silent stale overwrite | no committed write replaced a newer value its author had not seen |
| I3 | convergence | at the end every client's confirmed state and view equal the server's |
| I4 | integrity | no live reference to a missing node or a missing declared output; no edge to a missing node |
| I5 | one outcome per edit | every edit ends committed, rejected with a reason, or reported lost (volatile client crashed before the ack) |
| I6 | same value is no conflict | a write of the value already there is never rejected as a conflict |
| I7 | undo is one's own | a committed `restoreNode` (1.6) undoes a delete made by the same client |

The conflict catalog reports the same as M1 (I1), M2 (I2), M3 (I3), M4 (I4), M5 (I5).

## Layers

| layer | what runs | faults | command |
|---|---|---|---|
| unit + Postgres | document rules, sequencer, wire format, store | - | `cd server && ./run-db-tests.sh` |
| Dify DSL round trip | Dify's own 24 sample workflows: import -> export gives the same file (parsed, ignoring UI selection), import(export) gives the same document; edits (also of variables and features, 1.7) show up in the export; secrets never enter the document and come back only with `include_secret` | - | part of the unit suite (`DSLTests`) |
| Dify acceptance | the same 24 samples through a real local Dify: Dify's reading of dify-sf's export equals its reading of the original; a workflow edited in dify-sf imports with the edits | - | `bench/dify-acceptance/roundtrip_via_dify.py` (docs/results/dify-dsl-acceptance.md) |
| named scenarios | 46 hand-scripted interleavings (S1-S13: stale tabs, crashes before/after commit, delete vs edit, lists, same value, undo of a delete and clients older than 1.6, document-level registers and clients older than 1.7) | scripted | `collab-sim --scenarios-only` |
| deterministic fuzz | random clients, ops and schedules in a simulated world (lossy reordering network, client/server crashes, long offline); users undo deletes (`restoreNode`) and edit the document-level registers (`$app`, 1.7), and up to 30% of the clients play pre-1.6 or pre-1.7 clients whose streams must never carry what they cannot decode | all, random | `collab-sim --runs 20000` |
| mutation tests | the same fuzz with a protocol defect switched on (skip stale check, skip broken markers, no dedup, early ack, restore without stamps, restore of edges to deleted nodes, restore by someone else, unversioned `$app` registers, ...) | defect | `collab-sim --runs 1000 --mutation <name>`: must find violations |
| conflict catalog | the 88 tier-A cases shared with the Dify measurements, 20 network seeds each | timing T1/T2 | `collab-sim --catalog bench/catalog/A-cases.json` |
| client conformance | the Dart client against the real server: endpoints, retransmits, gaps, reject reasons, same-value rule, CORS, resume, ordering, ids, names, declared outputs, restore, document-level registers and secrets | - | `DIFYSF_URL=http://127.0.0.1:8080 dart test test/conformance_test.dart` |
| client unit + randomized | the Dart state machine, journal, transport, seeded randomized runs with crashes and partitions | random | `cd packages/collab_client && dart test` |
| chaos (real processes) | real server, Postgres and client processes through a fault proxy; each run verified against the database and every client | server kill -9, client kill -9 / pause, connection cuts, Postgres cuts, duplicate POSTs | `bench/chaos/run.sh 330` |
| storm (real processes) | 100 clients on a 500-node workflow, 120 s per round, ground-truth ledger | 19 network profiles (latency, jitter, asymmetric, loss 1-15%, reorder/duplicate, 256 kbit/s, clean disconnects, half-open streams, flapping, long offline, slow server, lost POST responses, buffering proxy, stream lifetime cap) x mix b / mix c (+ process faults, server kill -9) | `bench/storm/run.sh sweep c` with `CLIENTS=100 DURATION=120` |
| formal model | TLA+ model of the protocol, exhaustive for small configurations, with injected defects to prove the checker | all interleavings | `research/formal` |

## Ground truth

The harness keeps its own ledger of every edit it issued (client, sequence, base, op, time) and every outcome a client
reported, then compares it with the database and every client's state after healing all faults and settling. Same-value
writes, deliberately conflicting writes and disjoint writes are classified when they are generated, so "lost",
"silently overwritten" and "refused with a notice" are told apart by construction.

## Results

* `docs/results/chaos-330-runs.md`, `docs/results/storm-100c-sweeps.md` (38/38 rounds, ~365k edits, 0 violations)
* `docs/results/catalog-A-difysf.md`, `docs/results/scorecard-A.md` (Dify 33/88 cases with a loss, dify-sf 0/88)
* `docs/results/dify-vs-difysf.md`: the whole comparison (real browser, code-level simulator, formula, dify-sf)

How Dify was measured (real browser, simulator running Dify's own code, formal models, formula): `research/README.md`.

## Running on a shared machine

Heavy runs (chaos, storm, the Dify simulator) cap their containers' memory and CPU (docker `--memory/--cpus`); run one at
a time. The harness waits for child processes with deadlines only, and every round heals all faults before checking.
