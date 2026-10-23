# Persistent console Chatflow (protocol 1.18)

Console Chatflow debug uses the existing Swift graph engine, model/plugin adapters, runtime files, human-input snapshots and SSE follower. It does not execute a parallel browser engine or replace a refused remote operation with demo data. Servers advertise `workflow_runtime.chatflow`; clients default that capability to false for older servers.

## Durable turns and isolation

`POST /v1/apps/{app}/advanced-chat/workflows/draft/run` accepts query, inputs, files, optional conversation ID and parent message ID. Conversation ownership is the authenticated account within an application. Reads, parent selection, variables, run records, node records and both stop routes enforce that scope; another workspace member cannot read or stop the creator's debug conversation.

A transaction locks the conversation and creates its run and message together. A conversation has at most one active turn, including while awaiting human input; a second send receives 409. A foreign or unknown parent is refused before execution. Initial Start inputs remain attached to the conversation and are restored with its history. Regenerating a reply follows the selected parent's thread, not all sibling branches.

Messages extend the existing `app_messages` identity, preserving feedback and annotation references. Repeatable migrations add columns and conversation tables; they do not reset existing accounts, credentials, application documents, history or uploads.

## Memory, variables and output

LLM memory uses the selected durable parent thread and configured window. It uses the model plugin's real `num_tokens` operation and Dify's context/output reserve and pruning rules, rather than a character estimate. Classifier and parameter-extractor history reuse that provider. Historical query/answer text is literal; text that resembles a variable expression is not interpreted again. Supported historical image files pass through the same scoped file resolver and aggregate image prompt limit.

Conversation-variable assignments persist as updates and become the next turn's initial pool. An assignment inside an iteration retains the graph engine's existing local scope for the current turn while persisting the conversation value for the next one.

Text, per-node reasoning, files and usage metadata are stored before publication. Reconnects return a full `message_replace` plus applicable workflow/form state; byte cursors prevent a chunk already in the durable snapshot from being appended again even if publication races the snapshot. Pause de-duplication retains the existing database generation identity. Terminal streams include `workflow_finished` followed by `message_end`.

A fresh page reloads the selected conversation using a server/account/application-scoped preference, restores the branch tree and Start inputs, and follows the existing run when needed. File cards obtain fresh signed previews from their durable records. The composer reuses the design system’s standard multiline text input, including its font metrics, single editable semantics node and native keyboard/focus lifecycle. Start file fields retain the picker’s upload ID; restored typed files retain their frozen record marker and reference.

## Stop, failures and restart

Stopping closes the active message, run, forms and conversation ownership atomically. A late node response or delayed resume-preparation failure cannot overwrite an already terminal Chatflow run. Restarting the chat panel first stops its accepted task before clearing the current conversation.

Client reconnection retries GET subscriptions with backoff; it never automatically repeats the initial POST. Human-input pauses resume the existing durable snapshot after a new server process starts, preserving submitted inputs and completed external effects.

An unpaused run killed during execution is different: its ownership lease expires after 30 seconds without renewal. The partial message is retained as an error and the conversation is released. The server does not automatically replay an uncertain model/HTTP/code side effect. The user can explicitly send another turn. A human-input pause has no running lease expiry; its existing human-input deadlines remain authoritative.

## Verification and boundaries

Server regressions are in `ChatRunTests.swift`, `ChatStoreTests.swift` and `ConversationMemoryTests.swift`, alongside existing run, form, file and graph trace suites. Client regressions cover durable restoration, account/server preference scope, branch selection, restart stop ordering, reconnect completion and editable web semantics.

`e2e/chatflow/acceptance.py` drives an isolated real server/database, the signed OpenAI-compatible plugin and a deterministic local model endpoint. It captures actual second-turn prompts and tests parent branches, failures/retry, concurrent pause rejection, new-process human-input recovery, a real SIGKILL during an HTTP call, lease expiry and durable stop. `browser.py` drives the formal Wasm page, two real model sends, light/dark fresh-page history, a real SSE-disconnecting process restart, retained human-input text, and a later-turn file preview. These scripts are restricted to explicit localhost fixture ports and require private fixture paths; credentials and deployment configuration must never be committed or attached as evidence.

`reference/sources.json` pins the Dify 1.17.1 / graphon 0.7.0 source image and individual source hashes. Parent-thread oracle cases are in `e2e/chatflow/reference`.

Message-level reasoning follows the engine’s visible response stream; reasoning from an LLM not referenced by a response remains in its node-execution output.

This slice is console debug only. Published applications, end-user identities, app API keys and real published-run analytics remain phase 16; tools remain phase 15. Classifier/extractor current-query vision, OCR/document extraction, audio/video model prompts and model-generated files are not added here. Email human-input delivery remains independently disabled. Local deterministic model acceptance demonstrates the real plugin boundary, not paid-provider quality or physical Android coverage.
