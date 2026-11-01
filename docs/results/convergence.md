# 120 people on different networks build one planned workflow

The storm benchmark ([storm-100c-sweeps.md](storm-100c-sweeps.md)) checks that nobody's edit is lost silently and that
every client ends with the server's document. This run checks one more thing: that the document everyone ends with is
**the workflow they meant to build**, after many people on very different networks have edited it at the same time,
including fighting over the same fields.

Server: this branch on a local dify-sf with Postgres, 2026-11-01. Clients: 120 client sessions of dify-sf's client
library in one Dart process (`packages/collab_client`, `bin/build_demo.dart`), each signed in as its own editor account
and driven by a plan.

## The plan

`tool/demo/build_storm/make_plan.py --clients 120 --converge 100000` writes the plan and `target.json`, the workflow the
run must end with: the 81 nodes and 121 connections of the build demo (code, template, IF/ELSE and variable aggregator
nodes in ten lanes with links across lanes), each node at a fixed position with a fixed description.

1. People join over 42 seconds. Each owner adds its node, drags it into place (a position every 125 ms, as the editor
   sends a drag) and connects it to the nodes it reads from, waiting for those that do not exist yet.
2. Everyone reviews other people's nodes: writes "Reviewed by ..." into a node's description and nudges it a little.
3. Three bursts: at the same moment, all 120 write the description of the same node (twice a comparison node, once the
   report). These edits stop 15 s before step 4.
4. At 100 s every owner writes the final position and description of its node. A final write that loses a conflict is
   applied again on the latest version until the server confirms it, as a person who must get this value in would.

## The networks

Each client's transport adds its own delays (`LatencyTransport`, `--latency mix`): every request waits on the way out
and back, stream events arrive that late too, in order.

| network | clients | one-way delay | stalls | dropped connections |
|---|---|---|---|---|
| fibre | 36 | 20 ± 10 ms | - | - |
| home wifi | 48 | 80 ± 40 ms | - | - |
| mobile | 24 | 250 ± 150 ms | 2 s, about once a minute | - |
| train | 12 | 700 ± 400 ms | 4 s, about twice a minute | about 1.5 a minute (the client reconnects) |

## Result

| edits sent | confirmed | refused as conflicts (author told) | lost | pending at the end |
|---|---|---|---|---|
| 2015 | 1638 | 377 (322 of them in the three bursts) | 0 | 0 |

* Every client ended with exactly the server's document, and every confirmed edit is in the server's log (the storm
  checks).
* **The server's workflow is exactly `target.json`**: all 83 nodes (the 81 built plus Start and End) with their type,
  title, position and description, the 81 built nodes with their whole configuration (code, inputs, outputs), all 121
  connections with both ends, nothing missing and nothing extra.
* The final values of all 81 nodes were confirmed (162 writes: position and description).
* Time from an edit to its outcome, all clients: median 209 ms, 95th percentile 3.4 s, 99th 5.4 s, longest 9.0 s (the
  slow numbers are the mobile and train clients during stalls).

## Run it

```sh
python3 tool/demo/build_storm/make_plan.py --clients 120 --converge 100000 --out-dir /tmp/converge
# import /tmp/converge/start.yml as a new app (POST /v1/apps/imports), then:
cd packages/collab_client
dart run collab_client:build_demo --url http://127.0.0.1:8080 --doc <app id> --plan /tmp/converge/plan.json \
    --accounts /tmp/converge/accounts.json --duration 115 --rate 3 --latency mix \
    --target /tmp/converge/target.json --ledger /tmp/converge/ledger.json --email <owner> --password <password>
```

Exit code 0: the storm checks held and the workflow matched the target; the mismatches are printed otherwise. The
small version runs with the client tests: `test/converge_test.dart` (12 clients, the same four networks scaled down,
against the self-hosted protocol server, about 17 s).
