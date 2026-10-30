# Agent model inputs

An inline Agent node can use workflow inputs to select a provider, model and reasoning effort for each run. For example,
give the Start node two required select inputs (`model` and `effort`), then use the variable controls in the Agent
node's **Model input** and **Reasoning effort input** fields. Choosing the fixed source uses the inline Agent's
existing configuration.

The workflow node stores the bindings alongside its task and declared outputs:

```yaml
agent_model:
  selection: '{{#start.model#}}'
  reasoning_effort: '{{#start.effort#}}'
```

Each value must be one complete reference to a string variable. Missing, empty, non-string and secret values fail
before an Agent operation starts. The editor's checklist checks references and their types; renaming a variable also
updates these bindings. Single-node debugging includes both inputs in its variable mapping.

The `model` dropdown's option values are complete selections in the form `organization/plugin/provider::model-name`.
For example, `langgenius/openai/openai::gpt-6.1-terra` and `langgenius/deepseek/deepseek::deepseek-flash` can be options
in the same dropdown. Use the actual configured provider identifier, including for OpenAI-compatible connections;
the server does not infer a provider from the model name. Model names may contain `/` or further `::` characters.

The selected model must be enabled, configured and tool-capable. Its connection, schema, input modalities, context
window and transport are read from that provider's saved configuration. Only official OpenAI connections can use
the Codex WebSocket gateway; DeepSeek uses HTTP Responses. This selection does not change a provider's capabilities.
Workflow values cannot supply an endpoint or credential.

When the full selection changes provider or model, fixed model parameters are cleared before applying an explicit
reasoning-effort binding. Foreign provider credential references and old model credential references are dropped;
the selected model's configured credential is used. An unchanged full selection keeps its fixed settings, and a
provider-level credential reference may continue within that provider.

Legacy `agent_model.model` bindings continue to accept a model name within the inline Agent's fixed provider and
preserve their existing parameter behavior. They are mutually exclusive with `selection`. Existing editor bindings
remain in that mode; switch the model input to fixed and then back to variable to create a complete selection binding.

The server resolves the inputs when the node begins and validates the selected model and reasoning effort. It pins
that selection to the durable execution, so human-input resumes and output retries use the original values. The
resolved provider, model and parameters appear in the Agent's `run_started` event and node execution inputs.
Credential references remain internal. Existing workflows without `agent_model` continue to use their fixed settings.

Reasoning-effort validation follows the model settings policy. For OpenAI-compatible endpoints, a verified list
published by the model service is authoritative. Without that declaration, the plugin's built-in menu is a set of
suggestions and the service validates custom values. Other providers keep their schema restrictions. Suggested
values are not forwarded as an authoritative list of capabilities to the Agent harness.
