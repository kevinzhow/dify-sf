# Tool execution

Installed built-in tools and workflow tools use the existing Swift graph engine, node retry/error strategies, cancellation, run records and file store. The editor loads tool declarations from the configured Dify plugin daemon and uses the existing selector and tool form. Model/tool credentials are never written into a collaboration document.

## Authorization and declarations

Tool credentials are encrypted with the server's existing `COLLAB_SECRETS_KEY`. A private credential is available only to its creator. An administrator can share a credential with the workspace; other members can use it but cannot edit, delete or read its values. Only the creator can manage an existing credential. A node may explicitly select a credential; a missing, deleted or inaccessible selected ID fails instead of falling back. Without an explicit ID, the newest visible credential is used.

The daemon's normalized `credentials_schema` array is converted into the existing authorization form. Credential validation and invocation go through the authenticated daemon boundary. Reads return secret placeholders only to the creator; updates restore unchanged placeholders before validation. The existing form-schema validator handles required fields, defaults, conditional visibility and allowed options.

Static declarations, runtime declarations and dynamic option lists use the node's selected credential. Changing the selection invalidates that panel's runtime fields and options without overwriting another node's schema. Errors remain visible and retryable; a failed save retains the user's input.

## Execution and files

Tool nodes resolve variable, mixed and constant bindings using graphon's conventions. They collect real text, JSON, streamed variables and file messages. Blob chunks are checked for sequence, declared length and completion, then saved through the existing bounded file service and signed download routes. File references keep their structured identity for subsequent nodes. Resource limits bound JSON/text/variables, concurrent blobs, file count and total file bytes.

Provider refusals and timeouts fail the node. Retries, failure branches and defaults are handled by the existing graph engine. Stop cancels the caller's in-flight transport and prevents subsequent nodes from proceeding; it cannot undo side effects already accepted by a remote tool. Execution does not replace a failed or unavailable remote tool with simulated output.

## Workflow as Tool

The existing Publish menu opens configuration for the **published** graph, not the editor's current draft. Tool input types, defaults, requiredness and output schema come from that snapshot. Users configure the machine name, label, description and each input's description and method (inference parameter or fixed tool configuration).

Registration stores the published version ID. Editing or publishing a newer draft does not silently alter an existing tool; reconfiguration explicitly repins it. Configuration validates unique, non-reserved outputs and rejects triggers and human-input nodes. Runtime recursion is rejected and the call chain is bounded to five workflows including the root. A parent cancellation reaches the child engine.

Child workflow runs and node executions use the same database tables, marked `workflow-tool`. The caller records the child run and version IDs, and child token usage is included in the parent tool result. These are internal calls and do not require the public application API.

## Scope and reproducible checks

This slice supports credential-free and API-key tools, selected private/shared credentials and published workflow tools. OAuth, custom API/MCP provider services, marketplace installation and plugin callbacks to Dify's inner model/app/file APIs remain unsupported. A plugin requiring an unsupported callback fails explicitly. Existing model calls inside workflow tools use the configured model runtime.

`e2e/tool_fixture` contains a controlled local plugin pinned to `dify-plugin==0.10.2`, plus a real HTTP acceptance script. The fixture is installed only in an isolated daemon with signature verification explicitly disabled; verification on the user trial daemon stays enabled. No fixture plugin, account, key or paid model call is introduced into the user trial.

SDK 0.10.2 retains the deprecated runtime-parameter executor but omits its route registration. The controlled fixture explicitly registers that legacy route to test its host contract; dynamic-select requests use the SDK's unchanged route. The host treats an empty legacy response as an error. This fixture accommodation is not a claim that every third-party plugin using the deprecated API works unchanged.

The broader UI ledger remains partial: canvas provider-icon/authorization projection, the context-menu host link and the full upstream icon/tag/privacy-policy editor are not completed by this runtime slice. Functional checks do not imply that every existing Dify visual case passes.
