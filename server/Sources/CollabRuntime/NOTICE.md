# CollabRuntime: attribution

The workflow runtime is a Swift port of the semantics of **graphon 0.7.0** (https://github.com/langgenius/graphon, PyPI
`graphon==0.7.0`, wheel SHA-256 `6f7608aaaa65607c4935735137ed4b7029b1e6ca80202cbe829af3370cf4404e`), the graph engine of
Dify 1.17.1, Copyright LangGenius, Inc., licensed under the Apache License, Version 2.0 (copy: `LICENSE-graphon.txt`).
Files that port graphon logic say so in their header and name the Python modules they follow. The code is rewritten in
Swift (types, concurrency, errors), not translated line by line; behaviour, names of errors and output shapes follow
graphon.

Some files also follow the Dify 1.17.1 glue around graphon (https://github.com/langgenius/dify, `api/core/workflow/`,
`api/core/plugin/impl/`, `api/services/workflow_service.py`, `api/core/prompt/utils/`), licensed under the Apache License
2.0 with Dify's additional conditions; those headers name the Dify files.

Changes: everything is a re-implementation; see each file's header for what is not ported yet.

Tool execution (protocol 1.19): `Nodes/Tool` and `Services/ToolRuntime` port graphon 0.7.0
`nodes/tool/tool_node.py`, `entities.py` from the same pinned release. Server plugin dispatch,
credential handling and published Workflow-as-Tool follow Dify 1.17.1 commit
8387590ace4a094de812b7847fc6a4c3a27cd52b, `api/core/plugin/impl/tool.py`,
`api/core/tools/plugin_tool/tool.py`, `api/core/tools/workflow_as_tool/tool.py` and
`api/controllers/console/workspace/tool_providers.py`. Existing licenses above apply.
The Swift boundary additionally bounds output/blob allocations and keeps credentials write-only.
