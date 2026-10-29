# Retain operations when deferring a component

Dify 1.17.1 puts basic model configuration, credential selection and model removal inside its load-balancing configuration components. The Flutter port deferred those components as a group. That also removed the ordinary configuration and removal entry points, although the existing model APIs already supported them. Tests of isolated authorization widgets and the existence of a test with the same name did not establish that the real settings page could reach these operations.

The audit also found two related access problems: credential editing depended on hover, and re-adding the first model used the provider's stale unconfigured status to skip refreshing the visible list. Credential actions now appear on keyboard focus and narrow screens, and an explicitly requested model-list refresh is no longer gated by that stale status.

The model list now exposes configuration independently of load balancing and gives custom models a visible removal action. It reuses the authorization menu, masked edit forms, permission checks and existing APIs. Removing a model retains its credentials; the confirmation explains this and identifies the model. A settings-page interaction test switches credentials, removes the model, verifies that the credentials remain and adds the model back.

## Scope and evidence

- Exclude individual behavior, not every action belonging to a deferred component. Load-balancing pools and cooldowns remain deferred; basic configuration and removal do not require them.
- Record relocated behavior in `tool/dify_spec/retained_actions.json`, with the pinned upstream case, the local interaction test and an explanation of the difference. The inventory and feature checks reject exclusions that overlap these retained operations, missing tests and reference-version changes.
- A static test inventory is not execution evidence. Run the interaction tests with Flutter's `--machine` reporter and pass the result to `ledger.py --results`. Missing, skipped and failed actions do not pass that check.
- Cover the path from the actual page to the saved result, including cancellation, failed reads, retry, permissions and credentials retained after model removal. Isolated callbacks and button rendering complement this evidence.
- Revisit earlier “service unavailable” exclusions when a backend service is added. A replacement entry point needs its own interaction evidence and an explicit scope description; it does not automatically make the original component fully ported.

Example validation:

```sh
flutter test --machine test/model_providers_settings_flow_test.dart test/dify_spec/model_provider/provider_added_card/model_list_item_test.dart test/dify_spec/model_provider/provider_added_card/model_credentials_action_test.dart > interaction-results.jsonl
python3 tool/dify_spec/ledger.py /path/to/pinned-dify --results interaction-results.jsonl
python3 tool/features/gen.py --check
python3 -m unittest discover -s tool/dify_spec -p 'test_*.py'
```

The retained-action mappings are deliberately small. They protect the reviewed operations; they do not prove that every unrelated feature or deferred component has been reviewed or behaves identically.

The model-provider exclusions were reviewed by behavior group. Outdated claims that no plugin runtime or model-settings service exists were corrected. The unverified unconfigured-model Add path in the workflow selector is now recorded as TODO rather than not applicable; the selector feature remains partial. Marketplace management, balancing pools, Cloud credits and browser URL state remain separately scoped exclusions.
