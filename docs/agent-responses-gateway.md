# Scoped native Responses gateway

The inline Agent Soul accepts `harness_style: dify | codex`; omission keeps the
existing Dify behavior. The editor saves this field in the immutable Soul. In an
exported workflow it is `agent_packages.<package_ref>.soul.harness_style`, not a
field on the graph node. `tools.update_plan` is an optional boolean for Codex.

For Codex, Swift selects `model.wire: responses` for the official OpenAI provider
or an OpenAI-compatible credential configured with `api_type: responses`.
Other providers use `model.wire: plugin`. The operation includes available
context and output capacities from the model schema; unknown capacities are
omitted. Credentials never enter the operation. The service must acknowledge
the selected harness and wire in `run_started` before its result is accepted.
The default Dify operation retains its existing shape.

## Request

`POST /inner/agent/responses` authenticates with the same service bearer key and
`X-Agent-Run-Token` as the plugin callback. It additionally takes:

| Header | Meaning |
| --- | --- |
| `X-Agent-Call-Index` | Positive model-call number, within the node's call budget |
| `X-Agent-Invocation-ID` | `<agent_run_id>:<call_index>`, stable across retries |
| `X-Agent-Attempt` | Physical attempt number, initially 1; defaults to 1 |

The body is Responses JSON, without a `caller` or `target` wrapper. The run token
supplies identity, model/provider, selected parameters, credential reference,
generation, expiry and accessible files. The current workflow must still be
running and the caller must still have app access. A plugin-only scope cannot
use this endpoint, and a Responses-only scope cannot switch to the plugin route.

Swift pins the selected model and reasoning effort, applies the configured output
budget, temperature and top-p, and resolves the server-owned provider connection.
The compatible provider's `endpoint_model_name` is its upstream model alias.
The connection URL is normalized to one `/v1/responses` suffix. Redirects are
disabled; client-supplied destinations, authentication headers, hosted tools,
`previous_response_id` and storage requests are refused.

The request is limited to 32 MiB. Files must use `dify-sf-file:<upload_id>`:

- `input_image.image_url` becomes a data URI with the stored MIME type.
- `input_file.file_id` becomes `file_data` plus the stored filename.
- The same rules apply inside a tool output's content list.

Each reference must belong to the execution's granted file set and pass normal
file ownership checks. Expanded files share a 20 MiB request budget, including
repeated references. Arbitrary image URLs, provider file IDs and inline client
file bytes are refused. Opaque reasoning items are retained as JSON items.

## Streaming, retry and observability

Successful provider responses retain their SSE bytes, event names, comments and
opaque fields, including encrypted reasoning. Swift observes usage without
converting the stream to Dify chunks. It forwards
`X-Dify-SF-Forwarded-Reasoning: <effort>` when an effort was written to the request.
This records request construction; a provider echo and the provider's internal
reasoning behavior are separate facts.

One response is limited to 8 MiB and one unfinished SSE frame to 2 MiB. The
operation's absolute deadline also covers an idle response body. Revocation and
downstream cancellation close the upstream stream. Provider credentials are
checked across chunk boundaries before bytes are released; reflected secrets
abort the stream. Raw request/response content and encrypted reasoning are not
written to logs.

Before a successful stream, upstream error statuses and bounded `Retry-After`
seconds are retained, with a sanitized error code/message. An unsuccessful or
interrupted attempt may be retried under the same invocation ID with a higher
attempt number. Admission permits up to 30 attempts per call (the Codex request
and stream retry limits combined); it rejects concurrent calls, changed
invocation IDs, stale completions and replay after success. Requests that never
reached admission need not leave an earlier attempt record. Retries consume one
logical call slot. Every known physical attempt's usage is accumulated.

Native usage maps `input_tokens`, `output_tokens`, `total_tokens`, cached input
tokens and reasoning output tokens to runtime usage. Reasoning and cached tokens
are subdivisions, not additions to the total; missing detail stays unknown.
The `commentary`, `plan` and `model_retry` events are persisted and projected into
the Agent activity log and running canvas.
