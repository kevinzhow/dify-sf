# Official Codex client gateway

The official Codex process can use a custom Responses provider through
`POST /inner/agent/codex/v1/responses`. Its only credential is the temporary
`model.run_token` in the operation sent to the Agent service. The server binds
this capability to one execution, generation, provider, model and deadline,
and revokes it when the operation ends. Provider credentials stay in the server.
This follows the [official Codex app-server integration](https://developers.openai.com/codex/app-server/).

The process uses `wire_api = "responses"`, `supports_websockets = false`, and
an `env_key` referring to the temporary token. No client `X-Agent-*` headers
are required. The service and sandbox must exclude the token from digests,
logs, snapshots and command environment inheritance. The server also excludes
it from its operation digest and redacts it from Agent trace events.

## Request and accounting boundary

Every validated POST consumes a new call number, including Codex retries and
child-agent calls. Up to eight calls may be active within one execution;
they share its `max_turns` budget. At the limit, the server responds with:

```json
{"error":{"type":"usage_limit_reached","code":"agent_call_limit","message":"Agent model call limit reached"}}
```

The gateway never retries. It returns the provider's HTTP status, bounded
error type and code, and Retry-After; error messages are sanitized to avoid
reflecting credentials or inputs. Successful SSE bytes and opaque reasoning
items are not translated into the plugin protocol. Redirects are disabled.

Requests keep Codex's instructions, tool definitions, namespaces, input items,
cache key and metadata. The provider model name is resolved from the bound
workspace credential. The workflow's fixed reasoning setting and output token
budget remain authoritative; an omitted output limit is supplied by the gateway.
Hosted tools that can fetch ungranted remote resources are refused.

Codex may send images read from its execution workspace as inline data. The
same 20 MiB aggregate media and 32 MiB request limits apply. Remote media URLs
and ungranted provider file IDs are refused. Existing platform file references
still require the original execution's upload grants.

The gateway records each actual request's model, reasoning effort, include and
output limit as a `model_call` event, followed by the known input, cached,
output and reasoning token usage. The Agent service must not duplicate these
gateway-owned model-call events. Raw prompts and encrypted reasoning are not
written to these records.

The native DeepSeek provider uses its configured endpoint (default
`https://api.deepseek.com/responses`). Its [Responses compatibility documentation](https://api-docs.deepseek.com/guides/responses_api/)
states that unsupported parameters are ignored. The gateway preserves `include`;
an accepted field alone does not prove that DeepSeek implements its semantics.

## Restricted sandbox network

Configure a dedicated reverse-proxy peer using
`agent_service/deploy/codex-gateway.conf.template`. Replace only the literal
`${CODEX_UPSTREAM}` placeholders with the trusted API service's host and port;
do not expand nginx's own variables. Run without host ports or provider keys,
attached to the API network and supervisor-owned internal sandbox networks.

Set `SANDBOX_PROXY_PEER` to that peer, `SANDBOX_PROXY_PORT=3128`, and
`SANDBOX_CODEX_GATEWAY=true`. Only an executor profile explicitly using
`network.egress = "allowlist"` receives it. Its SandboxGrant includes
`codex_gateway_url`, exposed to the service as `codexGatewayUrl`, ending in
`/inner/agent/codex/v1`. Use that as the Codex provider base URL. A process may
set `NO_PROXY=*` to connect directly to this address rather than reusing its
inherited HTTP proxy settings.

The proxy forwards only POST requests at this exact path. Other paths, query
strings, CONNECT and arbitrary external destinations are refused. The host
still has no address on the sandbox bridge, and the supervisor removes that
network when the sandbox ends. Existing `egress: none` profiles retain their
isolation and do not receive a Codex gateway URL.
