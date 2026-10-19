These workflow files are copied unchanged from Dify 1.17.1 (`api/tests/fixtures/workflow/`),
https://github.com/langgenius/dify, licensed under the Apache License 2.0 (with Dify's additional conditions).
They are used only as test input for the DSL import/export round trip.

The following files were authored for this project (not copied from Dify). They follow the
Dify 1.17.1 workflow DSL format (`version: 0.7.0`) and are used as visual-test fixtures:

- `sf_classify_extract_workflow.yml`
- `sf_retrieval_human_workflow.yml`
- `sf_triggers_workflow.yml`
- `sf_run_workflow.yml` (no models: start, code, template, end; environment variables; a note)
- `sf_chat_preview.yml` (no models: chatflow start, template, answer; conversation variables)

- `sf_model_credentials.yml` adapts `basic_llm_chat_workflow.yml` to the official OpenAI provider ID, for the credential popup comparison. The two `model-provider-*.json` responses are synthetic fixtures (no API keys). The icon is from dify-official-plugins f2d7811364193f8d7069f24a299ee465c5519d3c, Apache-2.0; its license is in `model-provider-icon.LICENSE`.
