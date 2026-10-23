# Runtime services

The Swift server owns workflow execution, state, streaming and persistence. It reuses Dify 1.17.1's peripheral services for models and code. The base stack leaves the three runtime URLs empty; enabling a Docker profile alone does not configure a running server.

## Start the complete profile

```sh
docker compose -f docker-compose.yml -f docker-compose.runtime.yml --profile runtime up -d --build
# Stop without removing persisted databases, installed plugins or uploads:
docker compose -f docker-compose.yml -f docker-compose.runtime.yml --profile runtime down
```

Use one project name consistently. Do not run these commands against another developer's stack or existing user volumes as a test fixture. Set private secrets through a protected environment file before a real deployment; the repository's development defaults are not production credentials. Preserve the existing `COLLAB_SECRETS_KEY`, PostgreSQL and upload volumes when upgrading an installation.

If an existing installation has no `COLLAB_SECRETS_KEY`, check its provider-credential and secret-variable stores before provisioning one. An empty store may receive a new base64-encoded 32-byte key, saved in the protected persistent deployment configuration; an existing encrypted store requires its original key. The file-signing key is separate and must remain unchanged. Do not assume that a key is present merely because file uploads work.

The overlay sets the server's daemon/sandbox/proxy URLs and waits for healthy dependencies. Daemon health means its HTTP service is ready, not that a particular model plugin has been installed or its credentials are valid. Validate installation with a controlled local model before offering that provider.

| Service | Pinned version | Memory cap | CPU cap | State |
|---|---|---:|---:|---|
| server | repository build | 1024 MiB | 1 | uploads volume; runs/credentials in PostgreSQL |
| postgres | PostgreSQL 15 Alpine digest | 512 MiB | 0.5 | application and development plugin databases |
| plugin_daemon | 0.6.10-local digest | 1024 MiB | 1 | `dify_plugin` database, `plugin_storage` |
| redis | Redis 6 Alpine digest | 64 MiB | 0.2 | daemon cache; persistence disabled |
| sandbox | 0.2.15 digest | 256 MiB | 0.5 | `sandbox_dependencies` |
| ssrf_proxy | Ubuntu Squid digest | 128 MiB | 0.2 | no cache; entrypoint forwards proxy-owned log files |

The complete development profile is capped at 3008 MiB and 3.4 CPUs, excluding a browser/build/test process. Swap is disabled for capped services. Images are pinned by digest in the compose file; do not silently replace `latest` or upgrade an existing PostgreSQL volume. Actual usage must also be measured for the installed plugin set. Extra plugins have their own Python processes and can require a larger reviewed budget.

The sandbox is only on the internal proxy network. The server and Squid bridge it to the application network; sandbox egress goes through Squid. Model plugins have their own application-network egress because model endpoints may intentionally be local. Daemon management is published only on localhost; the sandbox and proxy have no published ports.

## Configuration and readiness

| Server configuration | Meaning |
|---|---|
| `COLLAB_PLUGIN_DAEMON_URL` | e.g. `http://plugin_daemon:5002`; empty means no model service |
| `COLLAB_PLUGIN_DAEMON_KEY` | must match daemon `SERVER_KEY` |
| `COLLAB_PLUGIN_DAEMON_TENANT` | tenant where the provider plugin is installed; default `00000000-0000-0000-0000-000000000001` |
| `COLLAB_PLUGIN_DAEMON_TIMEOUT_SECONDS` | upper bound for a model daemon dispatch |
| `COLLAB_SANDBOX_URL` | e.g. `http://sandbox:8194`; empty means code/Jinja2 execution is unavailable |
| `COLLAB_SANDBOX_KEY` | must match sandbox `API_KEY` |
| `COLLAB_SANDBOX_{CONNECT,READ,WRITE}_TIMEOUT_SECONDS` | sandbox request deadlines |
| `COLLAB_SSRF_PROXY_URL` | e.g. `http://ssrf_proxy:3128`; empty retains the documented direct-HTTP mode, without SSRF protection |
| `COLLAB_REDIS_PASSWORD` | daemon Redis authentication |
| `COLLAB_PLUGIN_INNER_API_KEY` | reserved backwards-invocation credential; that API is not implemented |

Check PostgreSQL with `pg_isready`, Redis with authenticated `PING`, daemon `/health/check`, sandbox `/health`, and Squid's process/configuration check. A complete readiness check also performs a real local model invocation, code execution and HTTP request through the proxy; a listening port cannot prove those paths work.

Provider credentials remain in the server's encrypted store. The daemon key, sandbox key and model-provider key serve different purposes. Missing configuration, rejected credentials, unavailable dependencies and unsupported operations must show a real error. The remote client never substitutes a successful local run or simulated history; only the explicitly selected local demo uses mocks. Persistent Chatflow and unimplemented triggers/tools remain later phases.

## Provider plugin installation

Keep signature verification enabled. `e2e/plugins.lock.json` pins the signed `langgenius/openai_api_compatible` 0.0.68 package and SHA256; `e2e/lib/plugins.py` verifies downloaded/cached bytes, and `e2e/lib/daemon.py` uploads and installs them for a tenant. `e2e/setup_ours.py` exercises install, model schema/credential validation and a streamed invocation against the local deterministic test provider. It is a test setup command, not a command to run with a user's paid credentials.

A warm package/virtual-environment volume survives restarts. For offline/restricted-network setups, supply the exact signed package from a trusted cache and verify the lock's digest; do not disable signatures to work around download errors. The first install also needs its Python dependencies, from PyPI or `PIP_MIRROR_URL`. Installing the compatible-provider plugin does not automatically install every provider listed by the settings catalog. Other providers require their own trusted, pinned plugin before invocation.

## HTTP transport and protection

AsyncHTTPClient 1.35.0's proxy API always uses CONNECT, including for clear HTTP. Squid correctly refuses CONNECT on a normal HTTP endpoint. HTTP request nodes therefore reuse system libcurl through a small C binding; model and sandbox clients keep their existing adapters. HTTP uses forward-proxy requests, HTTPS uses CONNECT. The server never shells out, puts request credentials in process arguments or writes request temporary files. [AsyncHTTPClient's proxy contract](https://github.com/swift-server/async-http-client/blob/4603a8036d921ea999fadb742931546c341f4bd7/Sources/AsyncHTTPClient/HTTPClient%2BProxy.swift), [libcurl proxy configuration](https://curl.se/libcurl/c/CURLOPT_PROXY.html).

An explicit proxy applies to every destination, ignoring inherited `NO_PROXY`; an invalid proxy is an error, never a direct-request fallback. Protocols and redirects are limited to HTTP/HTTPS. Redirects retain the httpx method/header policy and one overall budget. libcurl manages redirect cookies in an isolated per-request jar; cookies never persist across unrelated workflow requests. At most 16 native transfers run concurrently; queueing counts against the deadline. Response bytes/headers are bounded, TLS verification follows node configuration, and cancellation interrupts the real transfer. A proxy denial is distinguished from an upstream server's ordinary 403. [libcurl NO_PROXY semantics](https://curl.se/libcurl/c/CURLOPT_NOPROXY.html).

Private/loopback/link-local/multicast destinations and unsafe ports remain denied. CONNECT remains restricted to port 443. The isolated HTTP capture fixture allows only its named local origins before the private-address rule; that exception is never installed in the trial/normal profile. Do not loosen the production proxy to make a test pass.

## Reproducible checks

`e2e/runtime_services/matrix.md` defines the phase-1 exit. `origin.py` extends the existing deterministic model server with HTTP capture, redirects, statuses, size and stalled-response endpoints. `smoke.py --base ... --stub ... --out ...` requires a dedicated empty fixture database/account; it never uses the real trial account. Its `private/` directory contains fixture login state and must not be published.

`RuntimeProxyIntegrationTests` runs against actual Squid and the fixture when `TEST_RUNTIME_PROXY_URL`, `TEST_RUNTIME_ORIGIN_URL`, and `TEST_RUNTIME_OTHER_URL` are provided. It checks forward HTTP, real body bytes, ordinary 403 versus denial, HTTP/HTTPS private destinations, redirects and credential isolation, size, timeout and cancellation. Existing golden traces and runtime unit/integration tests continue to cover the engine; local deterministic model results do not claim external-provider quality or paid-provider validation.

The additional `acceptance.py` and `faults.py` checks target the dedicated `winnie-runtime-check` fixture on localhost ports 19092/19094. They are not deployment or user-account setup tools. The matrix invokes structured LLM output, classification and extraction through the signed plugin, exercises Python/JavaScript/Jinja2 errors, reuses the recorded Dify iteration/loop cases, counts real HTTP retries, and stops a running upstream request before any downstream node can execute. The parallel iteration sample intentionally ends `partial-succeeded` because two invalid numeric outputs exercise its error policies.

Configuration-failure checks recreate only that fixture's server, preserve its PostgreSQL/upload volumes and encryption key, and restore the original configuration in `finally`. They use short explicit test dispatch deadlines rather than waiting the default 600-second model timeout. A new process must read the previously completed run with identical stored details. Never substitute these tests for the formal browser-to-service-to-persistence check, or run them against the populated trial.

## Browser result regression

`OutputPanel` passes JSON values directly to the shared code editor, which performs serialization once. Both object responses and stored JSON-text responses are covered by assertions against the rendered/copied editor text, including nested HTTP JSON strings that must stay strings. The phase-1 browser check runs the frozen Wasm client against isolated real services: missing-daemon refusal creates no fake run, restored configuration produces an actual local-model request and persisted outputs, and a new backend process exposes the stored history. The populated trial is checked without signing into a user account or creating fixture data there.
