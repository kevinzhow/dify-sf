# Agent execution progress in workflows

Inline Agent configurations may set `limits.max_turns`. Older configurations keep 50. The setting must be an integer from 1 to 1000 and cannot exceed the selected execution environment's `max_turns_max`; older catalogs default to 50. Both preparation and execution validate the pinned configuration, and the model gateway uses that exact call budget.

While a workflow runs, its Agent card shows completed model calls, the current activity summary, and the latest reported preview. The activity button opens the existing Agent log presentation and keeps receiving new entries. Preview images use the existing scoped upload receipts and signed file transport, with enlargement and an explicit unavailable/expired placeholder. No arbitrary event URL becomes an image. Client run state stays outside the collaborative document and does not invalidate captured card textures when only live content changes.

The server accepts `progress` only after resolving a completed upload receipt belonging to the execution, checking its filename, MIME type and size. PNG, JPEG and WebP previews are bounded to 3 MiB; captions retain at most 200 Unicode scalar values. Invalid/missing previews do not fail the workflow. Immutable event IDs support reconnect deduplication and the existing authorized JSONL archive.

When the service submits work after a call/time budget notice, `agent_partial` is retained in execution metadata and the canvas and tracing detail explicitly label the result as partial. Declared outputs still pass through the normal output validation/retry/failure policy. Missing provider cache-hit statistics remain unknown; the interface never substitutes an estimate.

Long, append-only model histories are bounded to 8192 messages, 20 MiB of decoded file content and 32 MiB after file normalization. Repeated image references count at every actual payload position. These are transport limits, not a promise that a model's context window accepts every possible run. Image normalization keeps unchanged earlier messages byte-stable and retains file ownership checks.

Upgrade the Agent service and sandbox supervisor before adding the new profile field. Existing paused snapshots keep their original tool definitions: progress reporting is pinned for new executions with the shell capability and is not introduced into old snapshots.
