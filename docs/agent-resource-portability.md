# Inline Agent resource portability

This is a dify-sf extension around Dify's portable `agent_packages` / `agent_job` vocabulary. It applies to inline
Agent v2 workflow nodes. Agent Apps, roster bindings, workspace skills, external tool catalogs and model-checked
outputs remain outside this supported subset.

| Operation | Private identity | Files, model credentials and secrets |
| --- | --- | --- |
| Same-app Duplicate | Fresh agent, binding and snapshot for every copied node | Preserves the source node's owned references; no plaintext enters the shared graph or system clipboard |
| System clipboard / DSL / app copy | Fresh node-owned resources at import | Omits workspace file locators, model credential references and secret references/values; keeps explicit missing definitions |
| Restore an owned same-app version | Existing immutable owned binding | Validated against the same app and node; arbitrary foreign bindings are rejected |

Exports never include those private resource locators even when the ordinary DSL export includes environment
secrets. Portable file defaults become canonical missing-file markers, including file leaves nested in objects
and arrays. Import validates the raw package and node job before sanitizing omitted assets. Invalid unused packages
also reject the import. New private snapshots and graph additions share the existing database transaction, so a
failed private write cannot leave a partly imported graph. Local Duplicate reads the exact same-app source
snapshot and checks its identity again in the paste transaction.

The console extension endpoints are:

- `POST /v1/apps/{app}/workflows/draft/agent-clipboard/export` with `expected_seq` and `node_ids`. The response contains
  portable React Flow `nodes`, `edges` and `agent_packages`.
- `POST /v1/apps/{app}/workflows/draft/agent-clipboard/paste` with `expected_seq`, a UUID `idempotency_key`, those graph
  elements, packages and an `id_mapping`. Same-app Duplicate additionally supplies `local_sources` with the exact
  source node/agent/snapshot identities. These are edit-authorized requests, not public application APIs.

An uncertain paste retries the identical request and IDs. The client waits for collaborative delivery of the
returned document sequence and records one undo step without resending graph additions. Undo/redo preserves the
node-owned binding. An unsupported/disconnected clipboard path refuses the operation instead of carrying source
private IDs into a new shared node.
