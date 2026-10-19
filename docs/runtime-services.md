# Runtime services (docker compose profile `runtime`)

The workflow runtime of dify-sf (graph engine, nodes, variable pool, streaming) is written in Swift. For what a Swift
reimplementation would only copy badly, the server calls Dify's own peripheral services over HTTP, the way Dify's api
does. They ship as an optional profile of `docker-compose.yml`:

```
COLLAB_PLUGIN_DAEMON_URL=http://plugin_daemon:5002 \
docker compose --profile runtime up -d          # Postgres + server + the four services below
docker compose --profile runtime down           # stop (volumes stay)
```

Without the profile the stack is Postgres + server, as before (editing, collaboration, everything but running models,
code and tools).

| service | image | what for | memory cap | storage |
|---|---|---|---|---|
| `plugin_daemon` | `langgenius/dify-plugin-daemon:0.6.10-local` | runs model and tool plugins (one Python process per plugin); the server invokes LLMs and tools through it (`POST /plugin/<tenant>/dispatch/llm/invoke`, ...) | 1 GiB | database `dify_plugin` in the Postgres above (created by the daemon on first start); installed plugins and their Python environments in volume `plugin_storage` |
| `redis` | `redis:6-alpine` | needed by the plugin daemon only (the server needs no Redis) | 64 MiB | none (`--save ""`) |
| `sandbox` | `langgenius/dify-sandbox:0.2.15` | Python / Node.js / Jinja2 execution for code and template nodes and Jinja2 prompts | 256 MiB | volume `sandbox_dependencies` |
| `ssrf_proxy` | `ubuntu/squid` | forward proxy refusing private, loopback and link-local destinations: the sandbox's only way out, and the proxy of HTTP request nodes | 128 MiB | none |

Networks: the sandbox is only on the internal network `ssrf_proxy_network` (no route out except through the proxy);
the server is on both networks.

## Configuration

| variable (compose) | default | meaning |
|---|---|---|
| `COLLAB_PLUGIN_DAEMON_KEY` | a development key | shared secret: daemon `SERVER_KEY` = the server's `X-Api-Key`. Set your own for any real deployment. |
| `COLLAB_PLUGIN_INNER_API_KEY` | a development key | the daemon's key for calls back into the server (plugin -> LLM/tool/app/file "backwards invocation"; not implemented by dify-sf yet, model providers do not need it) |
| `COLLAB_SANDBOX_KEY` | a development key | the sandbox's `API_KEY` = the server's `X-Api-Key` for it |
| `COLLAB_REDIS_PASSWORD` | a development password | Redis password (daemon only) |
| `COLLAB_PLUGIN_DAEMON_PORT` | 5002 | daemon published on 127.0.0.1 (for a server running outside docker, and for tests) |
| `PIP_MIRROR_URL` | empty | PyPI mirror for plugin and sandbox dependencies |

The server sees `COLLAB_PLUGIN_DAEMON_URL` (empty unless set: no model runtime; `http://plugin_daemon:5002` with the
profile), `COLLAB_PLUGIN_DAEMON_KEY`,
`COLLAB_SANDBOX_URL` (`http://sandbox:8194`), `COLLAB_SANDBOX_KEY` and `COLLAB_SSRF_PROXY_URL` (`http://ssrf_proxy:3128`).

## Plugins

The daemon verifies signatures (`FORCE_VERIFYING_SIGNATURE=true`): only packages signed by Dify (marketplace) install.
Installing a plugin needs the network once: the package (Dify marketplace, or a local `.difypkg`) and its Python wheels
(PyPI or `PIP_MIRROR_URL`); the result stays in `plugin_storage`. Installs are per tenant: dify-sf (one workspace per server) uses
`COLLAB_PLUGIN_DAEMON_TENANT` as the daemon's tenant id. `e2e/setup_ours.py` shows the whole path (upload, install, validate credentials, invoke) with
the pinned `langgenius/openai_api_compatible` 0.0.68 package (`e2e/plugins.lock.json`).

## Measured memory

Measured 2026-10-19 with `e2e/stack.sh mem` (each container's cgroup) after a plugin install and LLM invocations:
server 7, Postgres 11, plugin daemon with one plugin process 74, sandbox 6, Redis 2 MiB of process memory (~0.1 GiB
in total; ~0.5 GiB with page cache, which the sandbox fills up to its cap). Details: `docs/results/e2e-harness.md`.
