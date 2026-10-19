# Differential-test harness (runtime phase P0)

dify-sf's workflow runtime is a Swift port of Dify's engine (graphon 0.7.0, as Dify 1.17.1 uses it). This directory
checks it against Dify itself, on three levels:

| level | what | where |
|---|---|---|
| golden traces | Dify's own engine runs Dify's 24 sample workflows (31 cases) with Dify's mock nodes; the normalized event traces are checked in; Swift tests replay the same graphs with the same mocks and compare | `traces/`, `../server/Tests/CollabTests/Fixtures/graphon-traces/` |
| live reference | a real Dify 1.17.1 (stack R) runs the same workflows against a deterministic stub LLM through the real plugin daemon and plugin | `stack.sh`, `setup_ref.py`, `compare.py` |
| live comparison | the same on dify-sf (stack P) and the diff of the two normalized traces | `compare.py --difysf` |

Everything is Python standard library only (`python3 -I`), no virtual environment.

## Pieces

* `llmstub/llmstub.py`: a deterministic OpenAI-compatible server (`/v1/chat/completions`, `/v1/completions`, streaming
  and not, fixed `usage`, `/v1/models`, `/echo` for HTTP nodes, `/stub/log` = the requests it got, `/stub/script` /
  `script.json` = scripted answers and failures). Answer without a script rule: `stub <h8>: <first 12 words of the last
  user message>`, h8 = SHA-256 of the canonical messages, so any difference in the assembled prompt shows in the
  output. Runs as compose project `difysf-llmstub` on the shared network `difysf_e2e` (alias `llmstub`, published on
  127.0.0.1:18000), on the plugin daemon image (no extra image).
* `difyref.override.yaml`: stack R = Dify's own `docker-compose.yaml` + this override, project `difyref`: only
  db_postgres, redis, api, worker (1 Celery worker), plugin_daemon, sandbox, ssrf_proxy (+ init_permissions), each with
  a memory cap (4.0 GiB in total), named volumes of its own (never Dify's `./volumes`), api on 127.0.0.1:15001, daemon
  on 127.0.0.1:15002; the daemon joins `difysf_e2e` to reach llmstub. Started with `--no-deps` in two steps (data
  services, then daemon/api/worker), which keeps agent_backend and its sandbox out (see "--no-deps" below).
* `runtime-e2e.override.yaml`: stack P = `../docker-compose.yml` with profile `runtime` (see
  `../docs/runtime-services.md`) as project `difysf-p` (server on 127.0.0.1:18080, daemon on 127.0.0.1:15102,
  Postgres on 127.0.0.1:55433); puts the server and its daemon on `difysf_e2e`.
* `plugins.lock.json` + `lib/plugins.py`: the pinned plugin package, `langgenius/openai_api_compatible` 0.0.68
  (`...@ba61c5ec...`, sha256 `3e134cc2...`), downloaded once from the marketplace into `.cache/plugins/` (git-ignored)
  and installed from there into both daemons. The daemons fetch the plugin's wheels from PyPI on the first install and
  keep them in their volume.
* `setup_ref.py`: Dify owner account, plugin install, stub model `stub-chat` (endpoint `http://llmstub:8000/v1`), then
  a probe: a single-node run of an LLM node through Dify -> daemon -> plugin -> llmstub.
* `setup_ours.py`: installs the same plugin into dify-sf's daemon (tenant `00000000-0000-0000-0000-000000000001`, the server's default `COLLAB_PLUGIN_DAEMON_TENANT`),
  validates the stub credentials and invokes the model through `dispatch/llm/invoke` exactly as the Swift runtime does;
  `--dify` repeats it against Dify's daemon. The streamed text must equal llmstub's answer.
* `traces/record.sh` + `traces/record_graphon.py` + `traces/cases.json`: the golden traces (below).
* `compare.py`: the live comparator (below).
* `lib/runtrace.py`: the normalized trace format and the comparison, shared by all of the above.
* `stack.sh`: `stub-up|ref-up|ours-up|...-down|down|mem|status`; `session.sh`: one whole session (up, setup, tests,
  memory, always down).
* `perf_draft_run.py` (`session.sh ... perf`): a 20-node draft run on dify-sf (LLM nodes on the stub, code and templates in
  the sandbox, two parallel branches), timed per run, with the server container's memory.
* `perf_iteration.py` (`session.sh ... perf`): a 100-round iteration with parallel 10 on dify-sf (per round an LLM node on
  the stub and a code node in the sandbox), timed per run, with the server container's memory.
* `cases/`: dify-sf's own live cases (`"fixture": "local/<file>"` in `traces/cases.json`, no golden): parallel iterations
  with the error handle modes, nested iterations with LLM nodes, loops with loop variables / break conditions / loop end,
  retries in a terminated iteration. Cases may also run iteration / loop single runs (`containers`) and compare the inner
  executions of parallel iterations as multisets (`unordered`: their rounds start in any order).
* `session.sh ... client`: the client's `ServerRunService` and run handlers against stack P (a Flutter test in the client
  checkout, `DIFYSF_CLIENT_DIR`).

## Running

Whole sessions only; on a shared machine wrap each in your heavy-job wrapper (`<wrap>` below: one job at a time, so
stacks never overlap), and nothing stays up afterwards:

```
DIFY_DOCKER_DIR=<Dify 1.17.1>/docker <wrap> e2e/session.sh ref compare self     # Dify vs Dify
DIFY_DOCKER_DIR=<Dify 1.17.1>/docker <wrap> e2e/session.sh ref ours compare difysf
<wrap> e2e/session.sh ours                    # dify-sf's runtime services + plugin + invoke via daemon
DIFY_SRC=<Dify 1.17.1 checkout> <wrap> e2e/traces/record.sh     # re-record the golden traces
```

`ours` uses the image `dify-sf-server` (`docker compose build server` first after server changes). Logs and
measurements go to `e2e/.out/` (git-ignored): `mem.tsv`, `compare/` (normalized and raw traces per case,
`report.json`), `compare.log`.

## Trace format (`dify-sf-trace/1`)

```
{"schema": "dify-sf-trace/1", "case": "...", "source": "dify" | "dify-sf" | "graphon-0.7.0+dify-1.17.1-mock",
 "edges": [[from, to], ...],
 "events": [{"event": "workflow_started"},
            {"event": "node_started", "exec": "llm#1", "node_id": "llm", "node_type": "llm", "in"?: "<iteration/loop node>"},
            {"event": "text_chunk", "selector": ["llm", "text"], "text": "..."},           (consecutive chunks merged)
            {"event": "node_finished", "exec": "llm#1", "status": "succeeded", "inputs", "process_data", "outputs", "error"},
            {"event": "iteration_started" | "iteration_next" | "iteration_completed" | "loop_*", "node_id", ...},
            {"event": "workflow_finished", "status", "outputs", "error", "exceptions_count"}],
 "llm_requests": [{"path", "body"}]          (live only: what llmstub received, sorted; `user` dropped)
 "meta": {...}}                               (goldens: fixture, inputs, query, mocks, engine, workers)
```

Normalization drops execution ids, timestamps, durations, task/run/message/conversation ids and latency; replaces any
UUID string by `"<uuid>"` and the per-run `sys.*` ids by `"<volatile>"`; numbers with an integral value become ints and
other floats are rounded to 12 significant digits (Python repr vs Swift); keys are sorted. `exec` labels number the
starts of a node (`<node>#<n>`).

Comparison (`runtrace.compare`): run result equal; the same executions with equal status, inputs, process_data,
outputs, error; each container's iteration / loop events equal in order; each text stream and the whole streamed answer
equal; LLM requests equal; and order by branch: for
two executions whose nodes are graph ancestor and descendant, "the first finished before the second started" must
agree. The total order of parallel branches is not compared.

Comparator output (stdout; `report.json` holds the same as data):

```
PASS  conditional_hello_branching.true  dify=succeeded  compared: dify~dify, dify~dify-sf
DIFF  basic_llm_chat_workflow  dify~dify-sf  2 differences
  exec[llm_node#1].outputs.text:
    dify: "stub 1a2b3c4d: Tell me about Dify"
    dify-sf: "stub 5e6f7a8b: Tell me about Dify"
  llm_requests[0].body.messages[0].content: ...
SKIP  chatflow_time_tool_static_output  needs the time tool plugin
```

## Golden traces

`traces/record.sh` runs `record_graphon.py` inside `langgenius/dify-api:1.17.1` (its environment pins graphon 0.7.0;
nothing is downloaded): `--network none`, 1 GiB, read-only mounts, `python -I`. Dify's own table runner builds each
graph with `MockNodeFactory` (Dify's mocks for LLM, tool, HTTP, code, template, question classifier, parameter
extractor, ...; the real graphon start/end/answer/if-else/aggregator/assigner/iteration/loop nodes) and runs
`GraphEngine` with one worker through Dify's response stream filter. Each case runs 3 times; all 31 traces are
identical across repeats. Mock semantics a replay must reproduce (Dify's `test_mock_nodes.py`): LLM -> text "This is a
mocked LLM response" streamed word by word (leading spaces), usage 10/5/15; code -> per declared output type (`string`
-> `mocked_<name>`, `number` -> 42, `object` -> `{"key": "value"}`, arrays -> fixed lists); tool -> `{"result":
"mocked tool output"}`; HTTP -> `{"status_code": 200, "body": "mocked response", "headers": {}}`; template transform
-> real Jinja2 rendering; per-case overrides in `cases.json` (`mock`).

## --no-deps (verified)

Dify's api and worker `depends_on` agent_backend (Agent v2). Starting stack R with `--no-deps` and without
agent_backend works: api and worker start, migrate and serve; setup, plugin install, model credentials, draft runs and
single-node runs succeed (`docs/results/e2e-harness.md`). Only Agent v2 nodes would need agent_backend.

## Licenses

The sample workflows are Dify's (`../server/Tests/CollabTests/Fixtures/dify/NOTICE.md`); the golden traces are
produced by Dify's engine and test helpers (Apache-2.0 with Dify's conditions, graphon Apache-2.0), see the NOTICE.
