# Inline Agent process restart acceptance

`restart.py` runs two real `collab-server` processes against the same isolated PostgreSQL database, plus the real Dart
agent service, its sandbox supervisor and the official shell sandbox image. Model requests pass through the signed
`openai_api_compatible` plugin to `provider.py`, a deterministic local OpenAI fixture. There are no vendor requests.

The fixture first creates a shell workspace, increments a counter and writes an artifact. It pauses for a native human
question. Process A is stopped with SIGTERM; process B starts on the same database and adopts the unanswered pause. The
script waits 130 seconds, longer than the agent service's 120-second remote lease, before submitting the first answer.
The next shell command requires the persisted counter to remain exactly one. A second question, final output and nested
file upload then complete. Assertions check distinct process/container identities, generation fencing, five model
calls, an unchanged shell side-effect count, downloaded file bytes and drained ACK/cleanup work.

Build the Swift server and the two Dart executables with the repository's pinned toolchains. Prepare an isolated signed
provider-plugin fixture on a Docker network. Set:

```sh
export AGENT_E2E_OUT=/private/agent-acceptance/run-unique
export AGENT_E2E_TOOLS=/private/agent-acceptance/tools
export AGENT_E2E_BUILD=/private/agent-acceptance/swift-build
export AGENT_E2E_PREFIX=agent-restart-unique
export AGENT_E2E_NETWORK=agent-fixtures
python3 e2e/agent_runtime/restart.py
```

The tools directory supplies `agent-service-core-2395331` and `agent-supervisor-2395331` (the immutable recursive-output
protocol candidate used for the initial acceptance). Set `AGENT_E2E_CORE_BIN` and `AGENT_E2E_SUPERVISOR_BIN` to test newly built filenames without replacing executables used by another fixture. The build directory contains `release/collab-server` and its adjacent `DifySF_CollabModels.bundle` model definitions. The script defaults
to a prepared development image and the matching immutable Dart image; `AGENT_E2E_IMAGE`, `AGENT_E2E_DART_IMAGE` and
`AGENT_E2E_PORT` override them. The signed plugin fixture is named `winnie-agent-plugin-daemon` in the current harness,
with the synthetic daemon key/tenant shown in the script. Adapt those fixture constants together when running elsewhere.

All containers have explicit memory/CPU limits and owner/fixture labels. Only the supervisor receives the Docker socket.
The shell has a separate bounded workspace and no egress proxy. The script refuses existing container names. It stops
its own containers and saves logs/inspection records on exit, preserving database/files for a failed-run investigation.
Remove only this invocation's confirmed-idle labelled resources under the host's shared cleanup lock. This script does
not alter a deployment or enable the default-disabled Agent capability there.

The harness also asserts that live logs before the first question survive the process restart in the same order,
with a recoverable node identity, and that all final logs appear unchanged in completed node metadata with unique IDs.

Completed events queries intentionally return only the terminal workflow frame, matching Dify. The harness reads
finished node logs through the ordinary authenticated node-executions endpoint and compares them with the durable ledger.

The initial and restarted paused node-start data must also match exactly, including the custom fixture title,
index, timestamp and scope fields. Both paths use the same runtime encoder.

Before running a workflow, the harness waits for the scripted provider HTTP endpoint and the authenticated isolated
sandbox health response. Container creation alone is not treated as readiness.
