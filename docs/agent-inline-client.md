# Inline Agent workflow configuration

The editor can create and configure the private inline subset of Agent v2. It reuses the model selector and parameter
modal, existing uploads and shared Dify design controls. The node panel owns the shared task and output declarations;
the private form owns the prompt, model, configuration files, environment variables/secrets and human contacts. Agent
Apps, roster binding, Build, knowledge and extra tool catalogs are outside this subset.

Saving waits for pending collaborative operations, preserves the latest shared task/output edits, and commits the
private snapshot and graph binding at one document revision. A private binding changed in another session requires a
reload. An uncertain HTTP outcome retains the exact request ID and payload for a retry; a confirmed refusal keeps the
input editable. The client waits until the committed binding arrives through collaboration before reporting success.
Read-only members can inspect the masked configuration but cannot save or upload.

The editor and native read-only MCP use the same checklist functions. The private half of a frozen graph is fetched by
both agent ID and configuration snapshot ID, including when the mutable draft has since removed the node. Responses
must match both IDs. Missing private configuration, models, files or environment secrets prevent publishing; unsupported
active contexts or unavailable catalogs make MCP checks incomplete rather than a false clean result. The model must
support tool-call or multi-tool-call; this additional diagnostic is a dify-sf extension. MCP responses contain checklist
issues, not private prompts or secret references.

These changes do not enable Agent execution in a deployment. The server's `COLLAB_AGENT_INLINE_ENABLED` switch defaults
to false. Full original UI/pixel parity is not claimed; this form uses explicit save actions, while a broader Agent App
editor would also require its own permissions, publishing and configuration lifecycle.
