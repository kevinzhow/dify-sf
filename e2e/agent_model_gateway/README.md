# Agent model bridge process test

The ordinary Swift `AgentModel` suites are hermetic and use a fake daemon. The optional process test also traverses
the fixed Dart service/Genkit adapter, Swift callback, official signed OpenAI-compatible plugin and deterministic
OpenAI HTTP fixture. It makes no vendor-model requests and uses fresh test accounts and Postgres schemas.

Use the agent service from the companion Agent v2 core change. Build its executable and the probe with its locked
package configuration, and compile the small test launcher (Swift's async runner can otherwise leave signals blocked
in a subprocess):

```sh
dart compile exe agent_service/bin/agent_service.dart -o /your/fixture/agent-service
# After dart pub get in agent_service:
dart compile exe --packages=agent_service/.dart_tool/package_config.json \
  e2e/agent_model_gateway/tool_loop_probe.dart -o /your/fixture/tool-probe
cc -Os e2e/agent_model_gateway/exec_unblocked.c -o /your/fixture/exec-unblocked
```

Run `provider.py` in the same isolated fixture network as a plugin daemon with the pinned package from
`e2e/plugins.lock.json`; mount its synthetic request records at `/evidence`. The provider listens on port 8000. It
never calls an upstream service. The daemon must have that plugin installed for test tenant
`00000000-0000-0000-0000-000000000001`, with server key `fixture-daemon-key`.

Expose these paths/URLs to the Swift test process (container paths when running tests in a container):

```sh
export TEST_DB_HOST=your-test-postgres
export AGENT_SERVICE_BINARY=/your/fixture/agent-service
export AGENT_TEST_EXEC=/your/fixture/exec-unblocked
export AGENT_TOOL_DRIVER=/your/fixture/tool-probe
export AGENT_PLUGIN_DAEMON_URL=http://your-test-daemon:5002
export AGENT_MODEL_PROVIDER_URL=http://your-test-provider:8000/v1
export AGENT_PROVIDER_RECORDS=/your/shared-evidence/requests.jsonl
cd server
swift test --filter AgentModel --no-parallel
```

The process test binds 21305 and 21306 inside its test network namespace. Run one copy per namespace. It explicitly
enables tool calling on its fresh fixture model credential, sends a real stored PNG, validates field output and file
scope, then executes a two-tool Genkit loop and checks both original IDs and the returned tool arguments. A retried
operation must keep one run and one provider call. Separate transport tests cancel both before and after the first
model chunk, and require the upstream TCP stream to close.

The test service's data, logs and uploaded pixel remain under `TMPDIR` for failure inspection. Set that variable to
a disk-backed fixture directory; the helper itself does not remove evidence or touch a running deployment.
