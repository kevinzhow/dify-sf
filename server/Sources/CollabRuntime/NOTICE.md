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
