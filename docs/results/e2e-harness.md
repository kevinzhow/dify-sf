# Differential-test harness (runtime P0): first results, 2026-10-19

Machine: a shared development machine (15 GiB, 8 cores). Every session ran inside the heavy-job wrapper and ended with all stacks down.
How it works: `e2e/README.md`.

## Golden traces (Dify's own engine, mock nodes)

`e2e/traces/record.sh`: graphon 0.7.0 inside `langgenius/dify-api:1.17.1` (no network, 1 GiB), Dify's table runner and
mock node factory, one engine worker. 31 cases over the 24 sample workflows (branches covered both ways: if-else
true/false, both switches of the aggregator sample in 4 combinations, both answers of the complex branch). All 31 runs
end `succeeded`; every case gives byte-identical normalized traces over 3 repeats. Traces:
`server/Tests/CollabTests/Fixtures/graphon-traces/` (~200 KB).

One sample (`search_dify_from_2023_to_2025`) needs a per-node mock (its tool's `text` output); without it graphon
raises from `GraphEngine.run()` instead of ending with a failed-run event (the recorder records such a crash as an
`engine_raised` event).

## Live reference: Dify 1.17.1 against itself

`e2e/session.sh ref compare self`: 28 live cases (3 skipped: they need tool plugins or the internet), each draft-run
twice on Dify against llmstub through the real plugin daemon and `openai_api_compatible` 0.0.68; the two normalized
traces (and the prompts llmstub received) compared. **28/28 equal** once the timings of LLM `usage` objects (`latency`,
`time_to_first_token`, `time_to_generate`, which Dify puts into the LLM node's *outputs*) are normalized away. So the
normalization removes all run-to-run noise and the comparator is ready for dify-sf.

The probe of `setup_ref.py` (single-node run of an LLM node: Dify -> daemon -> plugin -> llmstub) answers
`stub a6ac2467: probe hello`, the stub's deterministic answer for that prompt.

## dify-sf's plugin daemon (stack P)

`setup_ours.py --dify`: the pinned plugin installs into dify-sf's daemon (own database `dify_plugin` in dify-sf's
Postgres, created by the daemon) for tenant `00000000-0000-0000-0000-000000000001`; credentials validate; a streamed
`dispatch/llm/invoke` returns 5 chunks `stub a6ac2467: probe hello` with usage 6/4/10 — identical through Dify's daemon
and through ours.

## Dify vs dify-sf

`compare.py --difysf`: the rewritten sample graphs import into dify-sf (`POST /v1/apps/imports`, the Dify draft graph as
a JSON document); dify-sf's server image of this date has no draft-run endpoint yet, so every case reports
`dify-sf: draft run unavailable (HTTP 404)`. The comparison runs as soon as the runtime (P1/P2) serves
`POST /v1/apps/{app}/workflows/draft/run` and `.../draft/nodes/{node}/run`.

## --no-deps

Stack R starts with `--no-deps` and without agent_backend: api and worker migrate, serve and run every live case
(setup, plugin install, credentials, draft runs, single-node runs). Agent v2 nodes are the only thing that would need
agent_backend.

## Memory (MiB; `e2e/stack.sh mem`, each container's cgroup)

anon = memory of the processes; current/peak include page cache (reclaimable). Stacks R and P running together, after
the Dify setup, the plugin install into both daemons and the comparison of all live cases:

| container | anon | current | peak | cap |
|---|---|---|---|---|
| R api (gunicorn, 1 gevent worker) | 412 | 557 | 564 | 1024 |
| R worker (1 Celery worker) | 406 | 522 | 523 | 1228 |
| R plugin_daemon (+ 1 plugin process) | 79 | 83 | 88 | 1024 |
| R db_postgres | 22 | 52 | 59 | 384 |
| R sandbox | 7 | 226 | 256 | 256 |
| R ssrf_proxy | 20 | 27 | 28 | 128 |
| R redis | 2 | 4 | 10 | 64 |
| P server (dify-sf) | 7 | 12 | 13 | 1536 |
| P postgres (collab + dify_plugin) | 11 | 99 | 107 | 1536 |
| P plugin_daemon (+ 1 plugin process) | 74 | 163 | 169 | 1024 |
| P sandbox | 6 | 251 | 256 | 256 |
| P redis | 2 | 2 | 5 | 64 |
| llmstub | 9 | 11 | 12 | 64 |
| **total** | **1057** | **2009** | **2090** | |

Stack R alone, idle after start: anon 873, current 1405. The design's estimates (R ~4.1 GiB, P 2.5-3 GiB) were caps; real
use is R ~0.9 GiB anon / 1.5 GiB with cache, P (server + Postgres + daemon + sandbox + Redis) ~0.1 GiB anon / 0.5 GiB with
cache. Host MemAvailable stayed above 9.5 GiB during the session. The sandboxes' page cache fills their 256 MiB cap at
start (anon stays < 10 MiB); harmless (reclaimable), but a code-heavy run needing more anon memory would need a larger cap.

## Client conformance with the server in docker

`e2e/session.sh ours conformance` (client `c12dce1`, server image of `50072ec`): 46/46, including the model provider
group, with `DIFYSF_STUB_HOST=host.docker.internal` — `docker-compose.yml` now maps `host.docker.internal` to the host
(`extra_hosts: host-gateway`), so the server in the container reaches the stub provider the test process serves.
