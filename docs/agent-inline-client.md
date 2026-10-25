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

## Review follow-up

The model picker and both checks use the same pinned upstream name compatibility filter as the Swift adapter,
in addition to tool-call capabilities. Roster bindings are explicitly rejected. An unloaded model catalog reports
that context as unavailable rather than claiming that an otherwise compatible model lacks tools. Transient private
configuration reads retry a bounded number of times; permanently unsupported contexts do not poll forever.

Composer saves send `expected_node` with the pinned binding, task and declared outputs. Unrelated graph edits do
not reject a save; a change to this node does. Older callers without that baseline retain strict `expected_seq`
checking. Reload after a conflict updates the baseline while preserving the local prompt, attachments and version
note. Uncertain saves retain the exact request and remain explicitly retryable.

Local `inline.*` messages live in `app/assets/extension_i18n`, outside the upstream translation generator's output.
Configure controls use shared Dify text/button/input primitives. The opt-in screenshot test covers English and
Simplified Chinese, light/dark and 360/560 widths. For native `flutter_tester`, its optional OpenType font fixtures
must be lossless decompressions of the bundled pinned WOFF2 glyphs; they do not change production fonts or metrics.
These are native layout checks, not a claim of pixel parity with Dify or physical-device browser performance.

See [resource portability](agent-resource-portability.md) for clipboard/import boundaries and atomic paste.


The pinned model-name exclusion patterns have one source, `tool/agent/model_compatibility.json` (Dify 8387590).
`gen_model_compatibility.py --check` verifies both generated Swift and Dart lists. The runtime, picker and shared
editor/MCP checklist apply the filter to the catalog's English model label, independently of tool-call support.
An omitted English label uses the model identifier consistently in each path.

Reloading a conflicting private form overlays only sections edited locally onto the latest configuration. Plain and
secret environment sections and task attachments are tracked independently; untouched model/config/job fields come
from the new baseline. A confirmed save clears those edit markers. Uncertain saves and pastes retain their exact
receipt; a different clipboard source cannot silently retry an older pending paste.
