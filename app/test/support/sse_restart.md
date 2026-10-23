# A run followed across a server restart (protocol 1.16), against a real server

This is how the client sees a server that restarts while it follows a paused run — the evidence Winnie asked for on the
run's own SSE connection (not only on a refused submission).

## What it does (`sse_restart.py`)

1. Imports a two-step workflow (`start → human-input → end`) and runs it; it pauses at the human node.
2. Opens the run's stream the way the editor does after a pause (`GET /v1/workflow/{run}/events` with
   `include_state_snapshot=true&continue_on_pause=true`) on a **separate connection**, and records every frame.
3. Restarts the server (`docker stop` — SIGTERM — then `docker start`) on the same database.
4. Answers the form over HTTP after the new process is up, and records what happened to the first connection.
5. Opens the stream again (the reconnect the editor makes once it sees a dead connection) and records it.
6. Reads the run's detail.

## What it showed (2026-10-21, this machine)

```
frames of the original follow: ['workflow_started', 'node_started', 'node_finished', 'human_input_required', 'workflow_paused']
frames of a follow after the restart: ['workflow_started', 'node_started', 'node_finished', 'workflow_started',
  'node_started', 'text_chunk', 'human_input_form_filled', 'node_finished', 'node_started', 'node_finished',
  'workflow_finished']
run status: succeeded    outputs: {'reply': 'yes'}
```

The first connection ended with a `ConnectionResetError` (the process it was attached to is gone); the run itself was
unharmed — the new process resumed it on the answer and a fresh follow replays the pause's records and then the resumed
round, ending with `workflow_finished`.

## Why the client needed a change for this

`WorkflowRunController.resume` opened exactly one stream. When a restart cut it, `listenRunEvents` reported `ErrorEvent`
and `_endCallbacks.onError` marked the run **failed** and cleared the listening state — so the run's real result never
came back to the panel even though the server had finished it. That is what `_followWithResume` (in
`lib/src/workflow_editor/run/workflow_run.dart`) fixes: a connection that ends without a terminal event is opened again
(0.5 s → 5 s backoff), and the panel follows the run to its real end.

## Running it

```
# server up on http://127.0.0.1:18080 with the account deepdesign-e2e@example.test (admin)
python3 sse_restart.py
```

The script stops and starts the container the server runs in (`difydesign-server-1`): run it where that is the server
under test, never against a stack someone else is using.
