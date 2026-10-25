# Internal Agent model bridge

This layer connects the Dart agent loop to the existing Swift model runtime and signed Dify provider plugins. It
adds no browser-accessible execution capability; the Agent node remains unavailable until the following layers
provide private configuration, durable execution, human input, sandboxing and client integration.

An internal callback needs the configured service key and an opaque operation token minted by the Swift workflow
runtime. The token binds the workspace, app, workflow run, node execution, pinned config snapshot, operation and
ownership generation. No public route can create it. Each invocation has a positive call index and a unique
`invocation_id = run_id:call_index`; an accepted invocation is never retried as another provider call. Only one
model call may be active per token. Stop, deletion, expiry, revocation and ownership replacement prevent later calls.

Credentials stay in Swift and use the existing workspace model selection. Multipart images resolve only from
execution-scoped stable file references; arbitrary model-side URLs are rejected. Image bytes come from local
storage after the ordinary file checks. Requests and complete streamed responses are each bounded to 8 MiB.

The callback retains tool IDs, raw stream indices, argument fragments, separate reasoning content and provider
usage. Optional reasoning/cache token details remain unknown when the provider does not report them; reasoning
is a subset of completion tokens and is never added to total tokens. Provider errors are projected to a generic
error instead of reflecting credentials or prompt content.

The service transport uses idempotent operation creation and durable status queries. Closing a client stream does
not recreate an operation. An acknowledgement is separate from receiving a result: the runtime must first commit
the workflow result or whole pause before acknowledging the agent service.

Configuration uses `COLLAB_AGENT_SERVICE_URL` and `COLLAB_AGENT_SERVICE_KEY`, in addition to the existing plugin
runtime configuration. Neither has a production default. The operation token is an additional capability; the
service key alone does not authorize a workflow or file.

Tests cover message mapping, forged scope fields, generation replacement, duplicate invocation accounting,
provider-error projection and physical cancellation of the upstream HTTP connection. The optional process test
also uses the fixed Dart service, a real signed `openai_api_compatible` provider plugin, and a deterministic local
OpenAI fixture to exercise images and the `final_output` tool without a vendor model or user account.

Tool calls use a compatibility path: Swift asks the provider plugin for a complete response and returns it over the
same SSE callback. This avoids the pinned OpenAI-compatible plugin 0.0.68 / SDK 0.10.2 losing stream tool indices
before Swift can see them. Plain calls without tools remain streamed. Thought/tool content for complete responses
appears when the model turn finishes; the workflow's downstream output and first-phase process records already wait
for node completion. Cancelling closes the plugin HTTP connection; it does not guarantee that a remote provider
immediately stops generation or billing.

Reasoning is also subject to the selected provider plugin's policy. The pinned OpenAI-compatible plugin removes thought
blocks when its credential says thinking is unsupported. With thinking enabled, reasoning reaches the callback and Genkit,
and the local conversation reconstructs it for the next Swift request. That plugin independently strips previous assistant
`<think>` blocks before sending history to its vendor. The bridge does not bypass or modify a signed plugin to undo this
policy; vendor-side reasoning-history retention is therefore not promised by this layer.
