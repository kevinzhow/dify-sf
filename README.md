# dify-sf

A Swift + Flutter reimplementation of Dify's workflow studio. Its core promise: **an edit the server acknowledged is never lost,
stale clients never silently overwrite newer data, and all clients converge.**

This repository currently contains step 1: the server-side collaboration kernel and its test/chaos/benchmark harness.

* `docs/protocol.md` - the wire protocol (HTTP `POST` for ops, SSE for updates). Clients are written from this.
* `docs/architecture.md` - how the server works and why.
* `docs/step1-report.md` - what was built, results, failures found, known limits.
* `server/` - the SwiftPM package (`CollabCore`, `CollabServer`, `CollabStore`, simulator, harness).
* `bench/` - chaos and storm runners.

## Requirements

Docker. Everything builds and runs in containers (Swift 6.4.1, PostgreSQL 15, Toxiproxy 2.12.0); nothing is installed on the host.

## Run the server locally

```sh
docker build -t dify-sf-dev:local -f docker/Dockerfile.dev docker   # toolchain image (once)
docker compose up --build                                           # Postgres + server on 127.0.0.1:8080 (COLLAB_PORT=... to change)
curl -s -X PUT localhost:8080/v1/docs/demo                          # create a document with the example workflow
curl -N localhost:8080/v1/docs/demo/events                          # watch the event stream
```

Configuration is read with swift-configuration from environment variables or `--collab.*` arguments:
`COLLAB_HTTP_HOST` / `COLLAB_HTTP_PORT`, `COLLAB_DB_HOST` / `PORT` / `USER` / `PASSWORD` / `NAME`, `COLLAB_DB_POOL_SIZE`,
`COLLAB_CORS_ALLOWED_ORIGINS` (default: localhost dev origins), `COLLAB_SSE_PING_SECONDS` (10), `COLLAB_MAX_REPLAY` (2000), `COLLAB_SNAPSHOT_EVERY` (200), `COLLAB_LOG_LEVEL`.

## Test

```sh
cd server
./run-swift.sh test -c release -Xswiftc -enable-testing     # unit + 34 scenarios + 10,000 fuzz runs + mutation tests (~1 min)
./run-swift.sh run -c release collab-sim --runs 20000       # standalone simulator: scenarios + fuzz
./run-swift.sh run -c release collab-sim --runs 1000 --mutation skipStaleCheck   # prove the checkers can fail
```

## Chaos (real processes)

```sh
bench/chaos/run.sh 300          # 300 short runs: server kill -9, client kill -9/pause (journaled + volatile), connection cuts,
                                # Postgres connection cuts, duplicate POSTs; each run verified against the DB and every client
```

## Storm benchmark (100 clients, 500-node workflow)

```sh
bench/storm/run.sh mix-a        # disjoint edits only
bench/storm/run.sh mix-b        # 40% disjoint / 30% same value / 30% different values
bench/storm/run.sh mix-c        # mix b + faults (drops, client kills, duplicate POSTs, server kill -9)
bench/storm/run.sh ladder       # 10 -> 25 -> 50 -> 100 clients
bench/storm/run.sh sweep        # every network profile (latency, jitter, loss, reorder, bandwidth cap, half-open, ...)
```

Results (JSON + markdown) are written to `bench/*/results/<timestamp>/`.
