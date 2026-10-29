# Extensible reasoning levels for OpenAI-compatible services

The signed OpenAI-compatible 0.0.68 plugin presents a fixed reasoning-effort menu. An arbitrary service may support newer or different values. A plugin recommendation cannot establish the service's supported enum.

The shared model-schema policy uses bounded `reasoning_levels` from an authenticated model-discovery receipt when the provider declares them. The editor shows that enum, and execution validates the same enum. If it is absent or invalid, the original plugin options remain suggestions and the shared select permits a custom string. The provider decides whether that value is supported. Editing the connection invalidates its previous declaration. No model-name cases or mapping between effort values are used.

This separately versioned daemon image loads a host SDK policy through Python's standard startup hook. It preserves the distribution's existing hook. It does not change signed plugin packages or their SDK files, weaken signature checks, or expand daemon environment inheritance. In particular, daemon 0.6.11's secret-excluding environment allowlist stays unchanged.

The policy is restricted to the pinned compatible plugin's class and source hash. Its schema path applies the provider enum. Its validation path delegates every other field to the original SDK, then accepts a bounded custom reasoning string when there is no enum. The original plugin performs the HTTP conversion: Responses uses `reasoning.effort`; Chat Completions uses its existing thinking-mode rules. The policy does not add fields to models with no reasoning parameter. Other providers retain their own parameter rules.

Build with `--build-arg DAEMON_BASE=<immutable original daemon image>`. Run `test_reasoning.py` in an isolated plugin venv with the original package as cwd; this exercises the real lazy loader and validator. Also exercise schema RPCs and outgoing requests against a synthetic provider, including its 400 refusal, before deployment. Transport success does not establish reasoning quality or support for a particular effort at a real gateway.

Remove the host layer after the upstream plugin/SDK provides equivalent extensible-enum support and the same checks pass. Review the source-hash guard whenever upgrading that package; an unknown source is left untouched.

## Official reasoning models and sampling

For the exact official OpenAI API endpoint and the documented GPT-6 model IDs, the host validator also removes sampling parameters when reasoning is enabled, including the model default. This prevents a new workflow's default temperature from producing an unsupported-parameter error. The policy uses the effective endpoint model alias, preserves an explicit `reasoning_effort: none`, and leaves other models and compatible services unchanged. It never changes the selected reasoning effort or retries a request.

The dated compatibility reference is [OpenAI's GPT-6 guide](https://developers.openai.com/api/docs/guides/latest-model), checked 2026-10-29. Unknown model IDs are left to their provider. Tests intercept the original plugin's Responses request before any network call and check that reasoning and output budgets survive while incompatible sampling fields do not.
