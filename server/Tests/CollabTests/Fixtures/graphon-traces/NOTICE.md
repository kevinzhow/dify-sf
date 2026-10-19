Golden run traces of Dify's 24 sample workflows (`../dify/`, 31 cases in `e2e/traces/cases.json`), recorded by
`e2e/traces/record.sh`: Dify 1.17.1's own workflow engine, graphon 0.7.0 (https://github.com/langgenius/graphon,
Apache License 2.0), driven by Dify's test table runner and mock node factory (`api/tests/unit_tests/core/workflow/
graph_engine/`, https://github.com/langgenius/dify, Apache License 2.0 with Dify's additional conditions), inside the
`langgenius/dify-api:1.17.1` image. The files hold only normalized engine events (schema `dify-sf-trace/1`, see
`e2e/README.md`); no Dify code. Used as the expected behaviour of dify-sf's Swift runtime.
