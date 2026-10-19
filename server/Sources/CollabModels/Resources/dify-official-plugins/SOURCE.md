# Vendored model provider definitions

Data files copied unchanged from https://github.com/langgenius/dify-official-plugins (Apache License 2.0, see
LICENSE), commit `f2d7811364193f8d7069f24a299ee465c5519d3c` (2026-10-13), by `tool/refresh-model-providers.sh`. dify-sf reads them at startup
(`CollabModels`); every adaptation (parameter templates, positions, label fallbacks) happens in code, not here.

| plugin | version | provider |
|---|---|---|
| openai | 1.0.7 | langgenius/openai/openai |
| anthropic | 0.3.34 | langgenius/anthropic/anthropic |
| gemini | 0.9.11 | langgenius/gemini/google |
| azure_openai | 0.0.72 | langgenius/azure_openai/azure_openai |
| tongyi | 0.2.23 | langgenius/tongyi/tongyi |
| zhipuai | 0.0.35 | langgenius/zhipuai/zhipuai |
| moonshot | 0.1.13 | langgenius/moonshot/moonshot |
| deepseek | 0.0.24 | langgenius/deepseek/deepseek |
| ollama | 1.0.2 | langgenius/ollama/ollama |
| openai_api_compatible | 0.0.68 | langgenius/openai_api_compatible/openai_api_compatible |
