# Inline Agent v2 configuration

The workflow composer uses the Dify 1.17.1 inline `agent_soul` / `node_job` shapes. It supports private workflow-only
agents rather than a workspace roster. Agent nodes run on the server ([Agent v2](agent-v2.md),
[workflow persistence](agent-runtime-durability.md)). Execution is opt-in: the server needs
`COLLAB_AGENT_INLINE_ENABLED=true` and a configured agent service (`COLLAB_AGENT_SERVICE_URL`,
`COLLAB_AGENT_SERVICE_KEY`); `GET /v1/system-features` then reports `inline_agent: true`.

`GET /v1/apps/{app}/workflows/draft/nodes/{node}/agent-composer` reads the exact snapshot named by that graph. An optional
`snapshot_id` can inspect another immutable snapshot belonging to that same app, node and agent. It cannot read a resource
from another workflow. Task and declared outputs come from the current graph, including collaboration edits and restores.

`PUT` accepts `variant: workflow`, `save_strategy` (`node_job_only`, `save_to_current_version`, `save_as_new_version`),
`agent_soul`, `node_job`, and the original optional binding/version fields. It additionally requires `expected_seq` and a
UUID `idempotency_key`. These two fields are dify-sf collaboration extensions. A stale document returns
`409 agent_document_changed`; the client reloads instead of overwriting another editor. Reusing a key with another payload
returns `409 agent_idempotency_conflict`. An identical retry returns the original masked response, including its original
sequence, even after later edits.

The document operations, private immutable snapshot, current draft pointer, encrypted environment values and retry receipt
commit in one transaction under the existing document revision fence. Every save creates an immutable internal snapshot;
`save_as_new_version` also advances the displayed version. Publication stores bindings from the exact frozen graph rather
than looking up the latest draft pointers. A paused or published execution can therefore keep its original config after
another editor changes the draft. Copied/imported graphs must materialize their own resources; a foreign snapshot ID fails
closed rather than gaining access to another app's configuration.

Secret environment values use the existing encrypted secret store. Composer reads and retry receipts contain a mask and an
opaque reference, never the plaintext. A masked edit may preserve only the original reference under the same variable name.
Fresh values require the server's secrets key. Model configuration contains credential references rather than provider keys.

The accepted Soul subset includes prompt, model selection/parameters, human contacts, named configuration files and shell
environment. Unsupported active tools, skills, knowledge, persistent memory, app features and sandbox overrides are rejected.
Files are resolved through the ordinary scoped file adapter; model images use stable IDs and are checked against the
conversation file budget before starting an agent operation. Per-field output type/failure policies are separate from the
node-wide error strategy: a field's explicit stop stops the node, and its fail branch selects the error edge.

The original Agent prompt markers and the name-based model compatibility filter are preserved. The filter alone does not
prove tool support; runtime model-schema checks and the shared editor/MCP checks are supplied by the execution/client layers.
