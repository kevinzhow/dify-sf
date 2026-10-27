# Workflow preflight and rejected chat turns

Preview sends and workflow runs now use the existing WorkflowRunValidation over a freshly recomputed checklist before creating running state. Errors include each node title and its missing configuration or connection, and select the first navigable problem. The checklist retains its existing Go to fix actions.

When a server advertises Chatflow but cannot execute a graph's node types, the error identifies the affected nodes instead of claiming that Chatflow itself is unavailable. Explicit demo runtimes retain their configured fallback.

A request rejected before a server message is allocated leaves a local answer placeholder. Subsequent sends now resolve that placeholder through the original question to the last accepted parent, or no parent for the first turn. Server UUID validation remains unchanged; accepted turns and regeneration retain their branches.

Reference: Dify 1.17.1 `web/app/components/workflow/hooks/use-checklist.ts` (`useWorkflowRunValidation`) and the existing header checklist implementation.

Validation: five original regressions fail against the previous client; all six current regressions pass with the fix, covering rejected first turns, follow-up recovery/regeneration, chat and workflow preflight, and unsupported graph types. The related run, durable chat, checklist and header suite passes 244 tests; Flutter analysis has no issues. Browser verification is recorded separately after the release build.

Review follow-up: run-time validation and header rendering share the original checklist implementation. The header binding recomputes against the current document and configuration on demand; a stale displayed checklist cannot reject a freshly corrected graph or admit a newly invalid one. Detailed errors and node selection are documented as intentional improvements in features.yaml.
