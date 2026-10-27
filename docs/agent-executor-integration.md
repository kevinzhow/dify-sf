# Inline Agent executor profiles

A workflow's immutable Soul snapshot stores only `executor_profile`. An absent or empty name resolves to
`default`; importing a valid name from another server preserves it. The executor host owns the image, mounts,
devices, environment and resource policy. A workflow cannot override that policy or create a profile.

The existing inline composer uses the shared `DifySelect` for the environment. It displays the description and
availability, retains an unavailable imported name, and disables unavailable choices. The selector is shown while
Shell is enabled by server policy. Disabling Shell hides it without changing the saved selection.

`GET /v1/apps/:app/agent-executor-profiles` requires the same authenticated workflow read access as the composer.
It returns `shell_enabled` and `profiles`, which is either the safe list of names, descriptions, statuses and timeout
caps, or `null` when the list could not be checked. Images, mounts, device paths and environment values are omitted.
Concurrent reads share a probe and cache its success or failure for 15 seconds; editor health refreshes do not replace
an unsaved Soul or temporarily clear the current checks.

The editor and native read-only MCP use the same checks against the same pinned Soul. A known missing or unavailable
profile blocks a run. A failed catalog read instead shows an explicit warning and leaves the actual service response
authoritative for a run. MCP reports this check as incomplete and cannot authorize a publish/import gate. It never
reports an empty catalog or a successful zero-warning check for an unread catalog. Other configuration errors still
block when environment availability is unknown.

Swift sends the resolved name in every operation and requires its exact `run_started` echo before accepting an
operation's result. A missing or different echo cancels that run and reports `sandbox_unavailable`. Profile-specific
422 and 503 rejections are node failures, without a transport retry or declared-output retry. An expired event history
cannot substitute for a missing profile confirmation.

The existing node timeout is configured by `COLLAB_AGENT_TIMEOUT_SECONDS` (default 1800). The new server ceiling is
`COLLAB_AGENT_TIMEOUT_SECONDS_MAX` (default 86400, bounded to 1..86400). The effective active timeout is the minimum
of the node timeout, the selected profile's cap and the server ceiling; the same remaining budget drives Swift's
actual deadline and the operation limit. Previously recorded active time is deducted after a pause. The default
profile retains its 1800-second cap even when a deployment raises the node timeout for longer profiles. No per-node
timeout or turn-budget UI is introduced; `max_turns` remains 50.

Swift enables `tools.view_image` only when Shell is enabled and the selected model's schema declares `vision`.
The execution pins this capability alongside Shell. An older paused continuation keeps its original tool set.
Model names are not used to infer image support. Viewed images use the ordinary execution upload and scoped model
file path; the service attaches the image only to the next model call.

Deploy the service and supervisor with profile support and verify their catalog/echo before deploying the Swift
check. Deployments must retain existing service keys, persisted state and workspace data. The environment's prepared
read-only tools are an administrator-managed runtime input, separate from workflow prompts or evaluation data.
