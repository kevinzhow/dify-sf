# Compatible model discovery

New OpenAI-API-compatible language models can be added with a Base URL and API Key. The original complete plugin form remains available under Advanced and is still used for editing existing credentials.

Fetching models makes one authenticated `GET <base>/models`. It does not invoke a model, follow redirects, paginate or fall back to a paid request. A successful list may omit a callable model: enter that exact model ID manually. A failed list can be retried, explicitly probed, or configured through the complete manual form.

Facts distinguish provider declarations, observed behavior and unknown values. The model's context/output capacities are separate from the application's configured usage budgets. When capacities are unknown, the starting budgets are 4096 and 1024 tokens; these numbers do not establish model capacities. Model aliases do not establish capabilities, pricing or limits.

Capability probing requires separate confirmation because it makes up to seven short requests. It checks a nonce response, adversarial strict JSON, synthetic image recognition, a tool call/result round trip, real SSE deltas and an ignored output-token limit. HTTP 200 alone proves none of those behaviors. Inconclusive checks stay unknown. A low token count does not prove the actual output ceiling.

Advanced overrides are retained per selected model when the list is refreshed. Reset restores current declared/observed defaults. Changing the connection, endpoint model mapping or API type invalidates incompatible probe observations. Saving uses an owner-bound, connection-bound discovery/probe receipt and the original plugin's form and schema checks; it does not trigger an implicit paid credential-check fallback. A receipt establishes neither every model's availability nor the correctness of manual settings.

Source records use the existing encrypted credential storage. They contain bounded, allowlisted metadata, not the API key or raw provider responses, and are removed before plugin/runtime invocation. Old credentials remain valid and retain the original validation path. Receipts are memory-only, expire after 30 minutes and must be fetched again after server restart.

The authenticated console endpoints are owner/admin operations:

- `POST /v1/workspace/model-providers/<provider>/models/discover`
- `POST /v1/workspace/model-providers/<provider>/models/probe` with explicit `consent: true`
- `POST /v1/workspace/model-providers/<provider>/models/autofill`

Only `langgenius/openai_api_compatible/openai_api_compatible` supports this discovery adapter. It reuses the installed official plugin rather than creating a separate provider implementation. Direct configured-endpoint access follows the existing privileged model-credential transport boundary.
