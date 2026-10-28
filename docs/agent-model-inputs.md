# Agent model inputs

An inline Agent node can use workflow inputs to select a model name and reasoning effort for each run. For example,
give the Start node two required select inputs (`model` and `effort`), then use the variable controls in the Agent
node's **Model input** and **Reasoning effort input** fields. Choosing the fixed source uses the inline Agent's
existing configuration.

The workflow node stores the bindings alongside its task and declared outputs:

```yaml
agent_model:
  model: '{{#start.model#}}'
  reasoning_effort: '{{#start.effort#}}'
```

Each value must be one complete reference to a string variable. Missing, empty, non-string and secret values fail
before an Agent operation starts. The editor's checklist checks references and their types; renaming a variable also
updates these bindings. Single-node debugging includes both inputs in its variable mapping.

The inline Agent configuration still determines the provider, credential configuration, fixed defaults and remaining
model parameters. A model-name input must name an enabled, configured, tool-capable model within that provider.
When switching away from a model with a model-specific credential reference, the selected model's own configured
credential is used. Provider-level credential references continue to apply within the same provider. A workflow
variable cannot supply an endpoint or credential.

The server resolves the inputs when the node begins and validates the selected model and reasoning effort. It pins
that selection to the durable execution, so human-input resumes and output retries use the original values. The
resolved provider, model and parameters appear in the Agent's `run_started` event and node execution inputs.
Credential references remain internal. Existing workflows without `agent_model` continue to use their fixed settings.

Reasoning-effort validation follows the model settings policy. For OpenAI-compatible endpoints, a verified list
published by the model service is authoritative. Without that declaration, the plugin's built-in menu is a set of
suggestions and the service validates custom values. Other providers keep their schema restrictions. Suggested
values are not forwarded as an authoritative list of capabilities to the Agent harness.
