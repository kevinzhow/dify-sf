# dify-sf

A Swift + Flutter reimplementation of Dify's workflow studio. Its core promise: **an edit the server acknowledged is never lost,
stale clients never silently overwrite newer data, and all clients converge.**

The server provides collaborative editing, accounts and workspace settings, application drafts and history, model
provider configuration, a Swift workflow runtime, and local file uploads with signed previews. The Flutter studio (`app/`) and pure-Dart libraries (`packages/`) live alongside the Swift server
on `main`. New delivery integrates on `main`; the completed `client/step1` and feature branches have been removed after merge. Workflow model calls use the optional Dify plugin daemon; code and HTTP execution
use the configured sandbox and SSRF proxy. Human-input web forms and email delivery have separate, default-off
rollout flags. Runtime files/vision and durable console Chatflow conversations reuse the same workflow engine and
storage. Built-in and published workflow tools, durable Chatflow and published workflow/Chatflow Web/API execution are available. Public end users and operational logs remain separate from console debug state. The sections below describe configuration and supported boundaries.

* [`docs/agents.md`](docs/agents.md) - **for AI agents**: how an agent uses Dify SF (sign in, import, MCP checklist,
  publish, run as an end user) and how the Agent node is defined and configured. Summary below.
* `docs/protocol.md` - the wire protocol (HTTP `POST` for ops, SSE for updates). Clients are written from this.
* `docs/architecture.md` - how the server works and why.
* [`docs/migration-plan.md`](docs/migration-plan.md) - remaining delivery sequence, dependencies and acceptance criteria.
* [`docs/five-step-delivery-20261024.md`](docs/five-step-delivery-20261024.md) - delivered HTTPS/tools/public runtime/helpers, clean-install and upgrade checks, complete 450-case visual results and remaining gaps.
* [`docs/agent-v2.md`](docs/agent-v2.md) - Agent v2 inline agents: scope, agent service protocol, sandbox isolation.
* [`agent_service/README.md`](agent_service/README.md) - the Agent v2 agent service (Dart, Genkit): running, configuration and tests.
* `docs/step1-report.md` - what was built, results, failures found, known limits.
* `server/` - the SwiftPM package (`CollabCore`, `CollabServer`, `CollabStore`, simulator, harness).
* `bench/` - chaos and storm runners.

## For AI agents

Dify SF has no command-line tool. An agent uses the console HTTP API and the native client's read-only MCP server.
[`docs/agents.md`](docs/agents.md) gives every request with its shape, a minimal working example and the known
pitfalls. In short:

1. Sign in: `POST /v1/auth/login` gives a console access token.
2. Deliver a DSL file: `POST /v1/apps/imports` (a new app) or `POST /v1/docs/{app}/replace` (the draft of an app).
3. Check that same draft with the MCP tool `check_workflow` ([`tool/mcp/README.md`](tool/mcp/README.md)). Deliver only
   when the answer has `complete: true` and `gate_passed: true` (0 warnings).
4. Publish: `POST /v1/apps/{app}/workflows/publish`.
5. Run as an end user: `GET /v1/passport` with `X-App-Code: <web code>`, `POST /v1/files/upload`,
   `POST /v1/workflows/run` (streaming), `GET /v1/workflow/{run}/events?continue_on_pause=true`, and
   `POST /v1/form/human_input/{token}` for human-input forms.
6. Agent node: a graph node with `type: agent`, `version: '2'` and an inline binding to a top-level `agent_packages`
   entry (system prompt, model, harness style `dify` or `codex`, executor profile, limits). See
   [the Agent node](docs/agents.md#6-the-agent-node-agent-v2).

<!-- features:begin -->
## Feature parity with Dify 1.17.1

305 features of Dify 1.17.1's workflow editor and the pages around it, tracked one by one in [docs/features.md](docs/features.md) (generated from `tool/features/features.yaml`):

| Status | Features |
|---|---|
| ported | 182 |
| partial | 57 |
| not ported | 30 |
| n/a | 17 |
| dify-sf only | 19 |

Per area, with the reason for everything not ported: [docs/features.md](docs/features.md).
<!-- features:end -->

## Build and test the Flutter client

Use Flutter 3.47.6 (pinned in `.fvmrc`). From this checkout:

```sh
cd app
flutter pub get
cd ..
tool/build_web.sh                         # full Dart Wasm + self-hosted skwasm
tool/test_control_typography.sh           # font/control checks and complete client suite
```

The app is in `app/`, collaboration/layout libraries in `packages/`, and vendored
client dependencies in `third_party/`. See the [client guide](docs/client.md),
[control typography regression](docs/control-typography-testing.md),
[design rules](tool/design/README.md) and [Android Web support](docs/mobile-support.md).
Run resource-intensive commands inside the host's normal build/test limits.

## Server requirements

Docker. Everything builds and runs in containers (Swift 6.4.1, PostgreSQL 15, Toxiproxy 2.12.0); nothing is installed on the host.

## Run the server locally

```sh
docker build -t dify-sf-dev:local -f docker/Dockerfile.dev docker   # toolchain image (once)
docker compose up --build                                           # Postgres + server on 127.0.0.1:8080 (COLLAB_PORT=... to change)
# protocol 1.8: install the owner once (or sign in: POST /v1/auth/login), then send the access token with every request
TOKEN=$(curl -s localhost:8080/v1/setup -d '{"email":"me@example.com","name":"Me","password":"change-me-1"}' | sed 's/.*"access_token":"\([^"]*\)".*/\1/')
curl -s -X PUT -H "Authorization: Bearer $TOKEN" localhost:8080/v1/docs/demo   # create a document with the example workflow
curl -N -H "Authorization: Bearer $TOKEN" localhost:8080/v1/docs/demo/events    # watch the event stream
```

Configuration is read with swift-configuration from environment variables or `--collab.*` arguments:
`COLLAB_HTTP_HOST` / `COLLAB_HTTP_PORT`, `COLLAB_DB_HOST` / `PORT` / `USER` / `PASSWORD` / `NAME`, `COLLAB_DB_POOL_SIZE`,
`COLLAB_CORS_ALLOWED_ORIGINS` (default: localhost dev origins), `COLLAB_SSE_PING_SECONDS` (10), `COLLAB_MAX_REPLAY` (2000), `COLLAB_SNAPSHOT_EVERY` (200), `COLLAB_LOG_LEVEL`,
accounts: `COLLAB_AUTH_ACCESS_TOKEN_MINUTES` (60), `COLLAB_AUTH_REFRESH_TOKEN_DAYS` (30), `COLLAB_AUTH_INVITE_EXPIRY_HOURS` (72),
`COLLAB_AUTH_LOGIN_MAX_FAILURES` (5), `COLLAB_AUTH_LOGIN_LOCKOUT_SECONDS` (86400);
secrets and model providers (protocol 1.9): `COLLAB_SECRETS_KEY` (base64 of 32 random bytes, `openssl rand -base64 32`; encrypts
model provider credentials and secret environment variables at rest; unset = the server refuses to store secrets; keep it: with
another key stored secrets cannot be read), `COLLAB_MODELS_VALIDATE` (true: check credentials with the provider before saving),
`COLLAB_MODELS_VALIDATE_TIMEOUT_SECONDS` (10);
runtime (protocols 1.13–1.16): `COLLAB_PLUGIN_DAEMON_URL` / `_KEY` / `_TENANT` (models), `COLLAB_SANDBOX_URL` / `_KEY`,
`COLLAB_SSRF_PROXY_URL`, `COLLAB_RUNTIME_MAX_WORKERS` (10) / `_MAX_STEPS` (500) / `_MAX_TIME_SECONDS` (3600), and human
input's `COLLAB_WEBAPP_BASE_URL` (the form link in the mail) and `COLLAB_HUMAN_INPUT_GLOBAL_TIMEOUT_SECONDS` (604800; 0
disables).

The complete, digest-pinned runtime profile and its readiness/resource checks are described in
[Runtime services](docs/runtime-services.md). Start it with both `docker-compose.yml` and
`docker-compose.runtime.yml`; the base stack leaves runtime dependencies unconfigured.

[Persistent console Chatflow](docs/chatflow-runtime.md) documents protocol 1.18, durable parent-thread memory,
conversation isolation, reconnect and restart behavior. [Published Web/API](docs/protocol.md#published-web-and-service-api-120) adds immutable published revisions, independent visitors/API callers, files/forms, recovery and real monitoring; it shares the existing engine. [Published runtime acceptance](docs/runtime-public-acceptance.md) records real service/browser checks and their limits.

## Test

```sh
cd server
./run-swift.sh test -c release -Xswiftc -enable-testing     # unit + 35 scenarios + 10,000 fuzz runs + mutation tests (~1 min)
./run-swift.sh run -c release collab-sim --runs 20000       # standalone simulator: scenarios + fuzz
./run-swift.sh run -c release collab-sim --runs 1000 --mutation skipStaleCheck   # prove the checkers can fail
```

Every test layer, its faults and its invariants: [`docs/testing.md`](docs/testing.md). The conflict catalog shared with
the Dify measurements: `collab-sim --catalog bench/catalog/A-cases.json`.

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

## Dify comparison

[`docs/results/dify-vs-difysf.md`](docs/results/dify-vs-difysf.md) compares Dify 1.17.1 and dify-sf from four sources (real
browser, a simulator running Dify's own collaboration code, a closed-form formula, dify-sf's own tests). The methods and
raw results for the Dify side are in [`research/`](research/README.md).

### Local files and image icons (M2a)

The console can upload originals, download/preview through expiring signed links, and save cropped images as
app/site icons or account avatars. Enable this with COLLAB_FILES_SIGNING_KEY (a separately generated secret of at
least 32 UTF-8 bytes) and COLLAB_FILES_URL (the HTTP(S) server address the browser reaches). No signing key is
provided by default; supply it through configuration/environment, keep it out of Git and retain it across restarts.
COLLAB_FILES_INTERNAL_URL optionally chooses a separate internal address. Docker Compose keeps originals in the
file_uploads volume; back it up together with Postgres. Standalone servers set COLLAB_FILES_DIRECTORY to a
persistent private directory writable by the server user. Configure COLLAB_CORS_ALLOWED_ORIGINS when the client
runs on another origin.

Default size limits are 15 MiB for ordinary files, 10 MiB for images, 50 MiB for audio and 100 MiB for video.
The account/app image controls retain their 3 MiB image limit and square crop. An account may use only its own
uploaded image; app/site icons can share ready images in the workspace. Missing storage configuration hides
avatar editing and refuses uploads explicitly.

Runtime files (M2b) support persisted file values, model vision, HTTP file bodies/responses, and human-input files.
UTF-8 plain text has a 3000-codepoint preview. PDF/Office extraction and the document-extractor runtime
remain unported and outside M2; original files can still be stored and downloaded. See docs/protocol.md for the
HTTP contract, security boundaries and recovery behavior.

Human input rollout: `COLLAB_HUMAN_INPUT_WEB_ENABLED=false` and `COLLAB_HUMAN_INPUT_EMAIL_ENABLED=false` by default.
Enable web forms separately from outbound email. Email delivery remains a separate acceptance workstream; keep
its flag off until that work is complete. Web-only workflows can run without a model daemon; LLM execution
is not advertised in that configuration. Periodic recovery starts after migration/startup work and retries accepted
answers after transient database failures. See the [protocol](docs/protocol.md#human-input-116).

UI visual acceptance: [Raft Visual Testing policy and source/case inventory](tool/visual/UI_TESTING.md). Use the unchanged pinned framework, original screenshot pairs and its Pixel/RGB report; unit tests do not establish visual parity.
