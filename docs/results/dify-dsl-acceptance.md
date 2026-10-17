# Dify workflow files: dify-sf's export is read by Dify exactly like the original

`bench/dify-acceptance/roundtrip_via_dify.py`, against a local Dify 1.17.1 (docker compose) and the dify-sf server built
from this commit, for Dify's own 24 sample workflows (`server/Tests/CollabTests/Fixtures/dify`):

* **D1** = the original imported into Dify and exported back by Dify.
* **D2** = the original imported into dify-sf, exported by dify-sf, imported into Dify and exported back by Dify.

D1 and D2 must have the same `workflow` section (graph, features, variables), compared after parsing with nodes and edges
by id and UI selection ignored. Both imports report the same Dify status (`completed-with-warnings`: the samples use an
older DSL version than the instance). A second check edits a workflow in dify-sf first (rename, new output variable,
move) and confirms Dify imports it with the edits.

Result of the run:

```
OK   answer_end_with_text.yml (completed-with-warnings/completed-with-warnings)
OK   array_iteration_formatting_workflow.yml (completed-with-warnings/completed-with-warnings)
OK   basic_chatflow.yml (completed-with-warnings/completed-with-warnings)
OK   basic_llm_chat_workflow.yml (completed-with-warnings/completed-with-warnings)
OK   chatflow_time_tool_static_output_workflow.yml (completed-with-warnings/completed-with-warnings)
OK   conditional_hello_branching_workflow.yml (completed-with-warnings/completed-with-warnings)
OK   conditional_parallel_code_execution_workflow.yml (completed-with-warnings/completed-with-warnings)
OK   conditional_streaming_vs_template_workflow.yml (completed-with-warnings/completed-with-warnings)
OK   dual_switch_variable_aggregator_workflow.yml (completed-with-warnings/completed-with-warnings)
OK   end_node_without_value_type_field_workflow.yml (completed-with-warnings/completed-with-warnings)
OK   http_request_with_json_tool_workflow.yml (completed-with-warnings/completed-with-warnings)
OK   increment_loop_with_break_condition_workflow.yml (completed-with-warnings/completed-with-warnings)
OK   iteration_flatten_output_disabled_workflow.yml (completed-with-warnings/completed-with-warnings)
OK   iteration_flatten_output_enabled_workflow.yml (completed-with-warnings/completed-with-warnings)
OK   loop_contains_answer.yml (completed-with-warnings/completed-with-warnings)
OK   multilingual_parallel_llm_streaming_workflow.yml (completed-with-warnings/completed-with-warnings)
OK   response_stream_filter_issue_170_workflow.yml (completed-with-warnings/completed-with-warnings)
OK   search_dify_from_2023_to_2025.yml (completed-with-warnings/completed-with-warnings)
OK   simple_passthrough_workflow.yml (completed-with-warnings/completed-with-warnings)
OK   test-answer-order.yml (completed-with-warnings/completed-with-warnings)
OK   test_complex_branch.yml (completed-with-warnings/completed-with-warnings)
OK   test_streaming_conversation_variables.yml (completed-with-warnings/completed-with-warnings)
OK   test_streaming_conversation_variables_v1_overwrite.yml (completed-with-warnings/completed-with-warnings)
OK   update-conversation-variable-in-iteration.yml (completed-with-warnings/completed-with-warnings)
24/24 workflows read identically by Dify
OK   edited in dify-sf, imported by Dify (completed-with-warnings): rename, new output variable, move
```

Not covered yet: documents created from scratch in dify-sf's own editor, whose node configs are not in Dify's shapes
until the editor is aligned with Dify's node panels.
