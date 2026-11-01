# Media in the README

Screenshots were taken from `main` (fd6915e), the build demo from the same code with presence (protocol 1.22), on a
fresh local server with demo data only: Chromium 1600x1000 at 2x (phone: 412x915 at 3x, Android user agent), English UI;
the demo in Chromium at 1500x1080.

## The build demo (`build-demo.mp4`, 97 s, 1080p, with sound)

The browser is "you": the ordinary dify-sf web editor, driven by a recording script (pointer, clicks, typing; your
pointer is drawn into the video, as screen captures leave it out). The 100 other people are processes using dify-sf's
client library, each signed in as its own editor account and driven by a plan, not people.

1. You open the workflow, which has only a Start and an End node, and look at the Start node's inputs. Nobody else is
   there.
2. People join one by one: a few seconds apart at first, then faster, all 100 after 42 seconds. Each reports its pointer,
   the node it drags and the node whose panel it has open (protocol 1.22 presence), so you see their cursors (riding on
   the nodes they drag), their avatars on the nodes they work on and in the header, and "… joined" notices.
3. Each adds the node it owns, drags it into place (a position every 125 ms, as the editor sends a drag) and connects it
   to the nodes it reads from, waiting for those nodes when someone else has not added them yet. The finished workflow
   compares two texts in ten lanes of code, template, IF/ELSE and variable aggregator nodes, with links across lanes:
   81 nodes added, 121 connections. Then they review each other's nodes by writing "Reviewed by ..." into a node's
   description; when two do so to the same node at the same moment, the later write is refused and its author told.
4. You open "Readability score"; Kai and Mila open it too (their avatars appear on it). You go offline and rename it;
   Kai renames it at the same time. Back online, your rename is refused and the editor tells you that Kai changed the
   title, with Re-apply and Discard; you discard, and Kai's title stays. (Kai's and Mila's part of this beat is sent
   through the API by the recording script at that moment.)
5. When editing stops, the demo checks, as the storm benchmark does, that every edit has an outcome, that every client
   ends with exactly the server's document and that every confirmed edit is in the server's log. In the recorded run
   1,198 edits were sent, 1,196 confirmed and 2 refused as conflicts; none was lost.
6. You start a test run with two hotel reviews: 79 nodes (two branch nodes are skipped) run in 3.6 s on the code
   sandbox, and the run panel shows the comparison report.

The counter panel on the right shows the demo's own numbers and checks. The camera moves with ordinary wheel input, one
step per frame (zooms about a fixed point). The music was synthesized for this video.

### Reproduce it

```sh
# a server with the code sandbox and its web client, then an owner account (README: "Run the server locally";
# the runtime profile in docs/runtime-services.md)
python3 tool/demo/build_storm/make_plan.py --out-dir /tmp/build-demo
# import /tmp/build-demo/start.yml as a new app (POST /v1/apps/imports, docs/agents.md 4.1), open it in the editor, then:
cd packages/collab_client
dart run collab_client:build_demo --url http://127.0.0.1:8080 --doc <app id> --plan /tmp/build-demo/plan.json \
    --accounts /tmp/build-demo/accounts.json --duration 52 --rate 3 --linger 45 \
    --email <owner email> --password <password> --ledger /tmp/build-ledger.json
```

Exit code 0 means every check held; the ledger file lists every edit and its outcome. Run the finished workflow from the
editor with the two texts in `tool/demo/build_storm/sample-inputs.json`.
