# Inline Agent workflow persistence

The Swift workflow adapter is opt-in (`COLLAB_AGENT_INLINE_ENABLED`, default false). It calls the separate Dart agent
service described in [agent-v2.md](agent-v2.md); it does not depend on a browser or an SSE subscriber. This is a dify-sf
extension around the inline subset of Dify 1.17.1, not a complete Agent App/roster implementation.

An execution binds the workflow run, node execution, private agent and immutable configuration snapshot. Draft changes
cannot change a paused execution's prompt, model, credentials, contacts or file configuration. The private node session
stores a monotonically fenced ownership generation. Callbacks validate both the current operation and live database
ownership. Model credentials remain in Swift; secret environment values are reconstructed for a request and are not
written into the operation ledger.

## Commit and recovery order

1. Before starting a remote operation, persist its identity and request digest. Retrying an uncertain POST retains that
   identity; a new human answer or output retry gets its own identity.
2. Consume durable service events and confirm the terminal result independently from UI connections. Receiving a result
   is not a committed workflow pause.
3. For a question, commit the original execution's continuation, question identity, native form, pause snapshot and usage
   in one transaction. A later question is a new form on the same execution. Answering an older form cannot answer it.
4. For a final result, commit the node trace, accepted outputs and private outcome before returning completion to the
   graph engine. Downstream work cannot race an uncommitted result. Late empty finish stubs cannot overwrite it.
5. Those transactions add acknowledgement work to a persistent outbox. Cleanup waits for all acknowledgements of that
   execution and generation. Failed acknowledgements, cancellation and cleanup retry with bounded backoff; no fixed
   retry count silently discards work.

The database lease, remote control lease, recovery scan and outbox have independent loops, so a slow HTTP call cannot
block lease renewal. Paused sessions can be adopted after the previous lease expires. A worker lost during active work
fails the execution and schedules cancellation/cleanup; it does not replay commands with uncertain side effects.
Admission limits running operations and rechecks that limit on resume. A terminal workflow transaction prevents late
callback writes.

Native forms keep the original provider tool-call identity in the agent continuation. A question timeout becomes that
call's timeout result. It does not invent a workflow `__timeout` edge for an Agent node. Long native action identifiers
use dify-sf's existing SHA-256 shortened form identifiers, while the original action ID is restored for the agent.

Agent output file paths are handled by the Dart service. Swift accepts file outputs only through matching, completely
received upload receipts belonging to that execution. Nested objects and arrays are checked recursively. A bare model
file object or another execution's upload cannot become a native file. File persistence precedes the receipt, and the
receipt precedes result acknowledgement and sandbox cleanup.

## Regression coverage

`AgentRuntimeIntegrationTests` uses a real PostgreSQL database, Swift HTTP server, Dart agent service and signed official
model provider plugin with a synthetic model endpoint. It follows two consecutive native questions through the final
workflow event, checks one node-execution identity, preserved pinned configuration after a draft edit, cumulative
usage of 8/16/24 tokens, active elapsed time and durable tool logs in live, paused-reconnect and completed-node views.
It does not exercise a shell command in that scenario; the process restart harness below does.

`AgentExecutionStoreTests` exercises transaction rollback, ownership fencing, generation adoption and upload receipts.
`AgentOutboxTests` makes a real HTTP endpoint refuse acknowledgement once and verifies persistent retry and cleanup
ordering. `AgentEventTransportTests` covers shell health gating, interrupted SSE cursor recovery and explicit lost
history. `AgentQuestionTests` checks action mapping, labels and defaults. Ordinary human-input, event and chat-store
regressions run alongside the adapter tests.

Client configuration/checklist and resource portability are covered by the related client change; see
[client configuration](agent-inline-client.md) and [resource portability](agent-resource-portability.md). These isolated
checks do not establish production readiness. Merging this adapter does not deploy or enable it.

## Restart acceptance

The maintenance worker adopts expired unanswered pauses independently from form submission. This keeps the remote
workspace leased after a server restart while the user is still deciding. An active worker lost mid-operation is
failed without replaying shell effects. Cleanup has a persistent retry queue and waits behind committed result ACKs.

`e2e/agent_runtime/restart.py` uses two real server processes and a real sandbox. It verifies a new owner/generation,
waiting longer than the remote lease before answering, two native questions, a shell side effect occurring once and
a nested file output uploaded through the real receipt endpoint and downloaded byte-for-byte. The model is a local
scripted fixture behind the signed provider plugin. This is isolated process evidence, not a deployed feature or a
physical-device performance claim. It also compares logs received before the restart with the new process's paused
reconnect snapshot, then verifies the complete log remains in the finished node metadata with unique event IDs.

Output defaults are type-checked before model execution. Configured canonical file defaults resolve through the
ordinary scoped file runtime and pass the same declared file constraints; model candidates still require received
operation upload receipts. Configuration-file availability is projected on read without rewriting immutable snapshots.
Composer graph operations carry the authenticated editor's attribution in the same transaction.

## Inline runtime boundaries

Shell access requires both `COLLAB_AGENT_SHELL_ENABLED=true` and an authenticated agent-service health response
with `sandbox: "isolated"`. The switch defaults to false. An unavailable sandbox does not prevent a model-only
inline agent from running. `/v1/system-features` reports `inline_agent` and the effective `inline_agent_shell`;
`COLLAB_AGENT_INLINE_ENABLED` still defaults to false.

Only declared file leaves are interpreted as upload receipts. Missing or mismatched receipts become individual
output validation failures, including inside objects and arrays; they follow the declared retry/default/failure
policy. Ordinary object properties named `upload_id` remain ordinary data. Runtime output files still require a
received upload owned by that execution and generation; configured defaults use the existing scoped file resolver.

The Swift adapter consumes the service's durable SSE stream with `after=<last committed event>`. It stores event
projections and thought/tool/usage logs in the private execution ledger before broadcasting `agent_log` or advancing
the cursor. A result cannot enqueue its acknowledgement until the terminal cursor agrees with durable service
state. Replayed events have stable run/event identities and are deduplicated. A 410 is an explicit lost-history
failure, not an empty successful log. Final node metadata retains the log; paused reconnect snapshots reconstruct
it from the private execution ledger. Terminal service snapshots are not copied into the public log. Environment
values are redacted from event projections, and operation audit digests omit environment values.

The running admission budget excludes unanswered pauses. Resuming work checks the same database-wide running
budget. Paused execution ownership and remote workspace leases continue to renew independently of browser/SSE
connections. Active elapsed time accumulates across answering rounds and output retries, excluding time spent
waiting for a human. ACK/cancel/cleanup retries treat already removed or superseded remote work as resolved;
transient cleanup failures remain in the durable outbox.
