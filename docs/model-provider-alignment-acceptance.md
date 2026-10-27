# Model provider metadata and runtime acceptance

Unknown custom model names previously received generic metadata, including a 4096-token context, and the initial/edit forms could lose the model-type context that reveals provider-specific fields. The provider cards also did not establish whether their Python execution plugins were installed. This change uses each original signed plugin's schema for custom models and selected-model parameters, preserves the form context and masked credentials, and adds a curated runtime manager for all ten bundled providers.

The manager installs only the server's reviewed official packages. It preserves credentials and workflow documents on removal, checks the current installation identity, distinguishes unavailable status from an empty catalog, and restricts writes to owners/admins. Daemon 0.6.11 includes the upstream shared-runtime reinstall fix; the previous daemon could report a successful reinstall before an old runtime stopped.

## Validation

- All ten provider form definitions and signed package pins agree. Twelve actual schema cases cover every provider, known/custom models, unsupported aliases and capability/parameter preservation. At 1024 MiB / 1 CPU, the daemon reached 677,310,464 bytes with no OOM events. These are local metadata checks, with no vendor invocation.
- The 558-test, 129-suite server run found one old cancellation fixture missing the newly required schema endpoint. Completing that fixture recovered both cancellation arguments; 15 related tests in six suites then passed. Product sources were unchanged during that recovery.
- The app run passed 6,411 tests with four optional skips and five old mock-run fixture failures. Those mock fixtures were updated to declare their intentional preflight bypass; the product's checklist validation remains enabled. All five recovered in the 371-test related run, with analysis clean. Package tests passed 304 with two optional skips; 28 auth/transport checks and the final 21 model-dialog/icon checks also passed. Analysis remained clean. Linux release and the final Web Wasm build completed.
- The actual backend, PostgreSQL and signed plugins passed nine API acceptance checks: metadata, hidden-key edit, selector capabilities, deterministic Responses workflow, removal/reinstall with credentials retained, and editor read/403 write behavior.
- Browser interaction verified real removal and signed-package installation, controlled install failure/retry, catalog failure with rows retained, refresh recovery, read-only controls and the complete local Responses workflow. The model edit kept its masked key, Responses protocol, context, output and vision settings. Manager captures cover light/dark at 1440 and 390 pixels; narrow captures resize an already opened dialog and are not physical-device tests.
- Design checks pass with 414 existing allowlisted hits in 117 rows, no new business Material controls, 15 pinned reference files, and 304 feature entries. The one added SC core glyph passed the existing subset certification; glyph outlines and metrics remain unchanged.

## Actual interface comparison

Reference: Dify 1.17.1, source `8387590ace4a094de812b7847fc6a4c3a27cd52b`, design package `@langgenius/dify-ui` 0.0.1. Both sides use Chromium, 1440 × 900, device scale 1, English, matching themes and disposable model values. The original React screen receives declared model-response fixtures and the original pinned icon assets; it does not modify the original workspace's plugin installations or invoke a model. The Flutter screen uses the real isolated backend and signed plugins. No screenshot pixels or styles are altered.

| Theme | Original Dify | Flutter Web |
|---|---|---|
| Light | [Original](evidence/model-providers/original.light.png) | [Flutter](evidence/model-providers/flutter.light.png) |
| Dark | [Original](evidence/model-providers/original.dark.png) | [Flutter](evidence/model-providers/flutter.dark.png) |

The comparison caught the dialog's missing workspace icon source and lowercase type badge; both were corrected through the existing icon scope and badge component. Remaining visual differences include the model icon's effective scaling, text rasterization and surrounding navigation/settings features. The curated plugin manager is an extension with shared Dify controls, not a reproduction of the complete marketplace. These captures do not establish overall visual parity or close the separate visual/device work.

## Limits and configuration

An arbitrary alias such as `codex/gpt-6.1-terra` is not a recognized base model in the pinned OpenAI plugin. The compatible plugin accepts an explicitly configured custom endpoint and API type, including Responses. Installation does not move an existing model, copy its key or change its workflow provider. Capability limits must describe that endpoint; its model name is insufficient evidence.

The runtime workflow checks used a deterministic local Responses server. They do not validate a user's endpoint, account, paid provider, image reasoning quality or model output quality. No actual-user login or paid vendor call was part of this acceptance.
