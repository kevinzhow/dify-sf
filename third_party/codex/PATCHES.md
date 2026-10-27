# OpenAI Codex in dify-sf: what is vendored, what is ported, what differs

Upstream: <https://github.com/openai/codex>, tag `rust-v0.163.0` (commit `83086188ae0614bd882818ff1aa23f3194962012`),
Apache License 2.0 (`LICENSE`, `NOTICE`). Used by the agent service's `harness_style: "codex"`
(`docs/agent-v2.md`, "Harness styles").

## Vendored verbatim (`upstream/`)

The files under `upstream/` are byte-identical to the upstream files (hashes in `UPSTREAM.json`), except the gpt-6-astra
template, which is the `instructions_template` string of the `gpt-6-astra` entry of `codex-rs/models-manager/models.json`,
written out unchanged. `agent_service/tool/gen_codex_vendor.dart` compiles them into
`agent_service/lib/src/harness/codex/vendored.g.dart` (the Docker build context is `agent_service/`); a test keeps the
two equal. `agent_service/third_party_licenses/codex/` holds copies of `LICENSE` and `NOTICE` for the image.

`upstream/codex-rs/apply-patch/tests/fixtures/scenarios/` are Codex's portable apply-patch scenarios; the Dart port
passes all 25 (`agent_service/test/codex_apply_patch_test.dart`).

Not vendored: `~/.codex/models_cache.json` (service output fetched from OpenAI, not part of the repository).

## Edits applied at run time to the vendored texts

1. **gpt-6 base instructions** (`prompts.dart`, `baseInstructions`): the gpt-6-astra template up to the line
   `# Using skills` (exclusive; the trailing blank line before it is dropped). That removes "# Using skills",
   "# Apps (Connectors)" and "# Plugins" (no skill, app or plugin catalogs here).
2. **Direct tools instead of code mode**: the two bullets of "# Rules for getting work done" that name
   `functions.exec` and `Promise.allSettled` are replaced by one bullet,
   `- Run independent read-only commands as parallel tool calls.` (phase 1 has no `exec` tool; phase 2, code mode, will
   keep them verbatim).
3. **`update_plan` guidance**: removed with Codex's own `without_update_plan_instructions` (ported) when
   `tools.update_plan` is off, as Codex does when the tool is disabled. Not an edit of ours, listed for completeness.
4. **Permissions**: `danger_full_access.md` with `{{ network_access }}` replaced by `enabled` (executor profile egress
   `allowlist`) or `restricted` (`none`), and `approval_policy/never.md`, wrapped as Codex wraps them
   (`<permissions instructions>` … `</permissions instructions>`, checked against a real 0.163.0 rollout).

## Deliberate differences from Codex 0.163.0 (ported code)

- **Model routing**: a table of our own. `gpt-6*` (after one simple `namespace/` segment, Codex's rule) uses the
  gpt-6-astra template and the catalog metadata of the gpt-6 entries (tokens 10000, original image detail). Offline,
  real Codex finds no catalog entry for `gpt-6.1-terra` and uses the fallback; with ChatGPT auth it uses a remote
  template whose first 151 lines equal astra's (port plan, section 1.1). Every other model uses the fallback
  (`prompt.md`, bytes 10000), as in Codex.
- **`exec_command`**: no `shell`, `environment_id`, `sandbox_permissions`, `justification` or `prefix_rule` parameters
  (one environment; danger-full-access with approval `never`, under which Codex rejects escalations). `login` and
  `tty` are kept. A command runs as the shellctl job `exec bash -lc <cmd>` (`-c` with `login: false`): `tty: false`
  is a shellctl `stdio` job (no stdin, as Codex's pipes), `tty: true` a `pty` job. Codex's `UNIFIED_EXEC_ENV` is set;
  the executor profile's and the operation's `env` win over it. Session IDs are random in 1000-99999; at 64 sessions
  the least recently used one is terminated (Codex prefers exited processes and protects the 8 most recent).
- **`apply_patch`**: ported to Dart rather than shipping the `apply_patch` binary: the crate depends on tokio,
  tree-sitter and `codex-exec-server`, there is no Rust toolchain in this repository's builds, and the default sandbox
  image is Dify's upstream image, which we do not build. The parser, the fuzzy matching (`seek_sequence`), the line
  endings (`SourceFile`) and the messages are ported; streaming events, applied-patch deltas and unified diffs are not.
  Files are read and written through bounded shellctl control commands (at most 16 MiB per file). The tool verifies
  every hunk before writing (Codex's tool path); the standalone semantics (partial application) are kept for the
  fixtures. On the plugin wire the tool is a function with one `input` string and the Lark grammar in its description
  (Dify's `PromptMessageTool` has no freeform tools); on the Responses wire it is Codex's freeform tool. It is offered
  whenever the shell is on, also for fallback models (Codex offers none to models without `apply_patch_tool_type`).
  `apply_patch <<'EOF'` inside `exec_command` is not intercepted.
- **`view_image`**: Codex's schema (`detail` only for models with original detail) and messages; no client-side
  resizing yet (the provider resizes). The image is uploaded as a file of the execution and kept in the tool output as
  a `dify-sf-file:` reference; on the plugin wire it follows the tool message as a user message, with `original` sent
  as `high`. At most 16 MiB of viewed images per conversation (dify-sf).
- **Output truncation**: ported exactly (`truncate_text`, `formatted_truncate_text`, `ExecCommandToolOutput.
  response_text`, the 1 MiB head/tail collection). The second truncation when history is recorded (policy × 1.2) is
  not applied: `response_text` already fits that budget for exec output, and other tool outputs are short.
- **Environment context**: `<cwd>/workspace</cwd>`, `<shell>bash</shell>`, the date and `<timezone>UTC</timezone>` of
  the agent service, and the filesystem element of a disabled permission profile (as a danger-full-access rollout
  shows); no `<network>` element (the proxy's domain list is not known to the service). Without the shell only the
  date and time zone remain.
- **Loop**: one operation is one Codex turn; it ends at the first response without tool calls. Tool calls run as
  Codex's `RwLock` schedules them (consecutive parallel-safe calls together, every other call alone, outputs in call
  order). dify-sf keeps `max_turns`, the near-budget notice, `ask_human` pauses and declared outputs.
- **Declared outputs**: as `codex exec --output-schema`, the final message is the result. The plugin wire cannot send
  `text.format`, so the schema is given in a dify-sf section ("# Final answer format") of the second developer message;
  the Responses wire will send `text.format` json_schema instead.
- **Retries**: Codex's two layers and numbers (request: 4 retries of HTTP 5xx and transport failures; stream: 5
  retries of retryable errors; 200 ms × 2^(n-1) ± 10%; `Retry-After` first; overload only with `Retry-After`). The
  errors are the inner gateway's: its own refusals (400, 401, 403, 404, 409, 410, 413, 422, 429 `agent_call_limit`)
  are terminal; Dify error envelopes are classified by `error_type` (`*RateLimit*` retried, `*Quota*`,
  `InvokeAuthorizationError`, `InvokeBadRequestError`, `CredentialsValidateFailedError` terminal, -429 without a rate
  limit type terminal, the rest retried). A stream that ends without usage and finish reason is a `Stream` error.
- **Model wire**: on the native wire the request body is Codex's (`client.rs`: `store: false`,
  `include: ["reasoning.encrypted_content"]`, `prompt_cache_key`, `parallel_tool_calls`, freeform tools, `text.format`)
  and goes through the Swift server (`POST /inner/agent/responses`), which owns the credential; HTTP transport, not
  WebSockets; no `Responses-Lite` (`additional_tools`, `reasoning.context`). `text.format` is `strict` only when the
  schema already meets the strict rules. Models without the Responses API use the plugin wire (reduced fidelity).
- **Not ported in this step**: code mode (`exec`/`wait`), compaction, sub-agents (`ultra` is refused), web search,
  `request_user_input`, hooks, approvals.
