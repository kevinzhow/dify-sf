import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/llm_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/model_parameter_modal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('changing models retains custom effort when recommendations are open', () {
    final result = mergeValidCompletionParams({'reasoning_effort': 'vendor-next-level', 'temperature': 999}, [
      ModelParameterRule.fromJson({
        'name': 'reasoning_effort', 'type': 'string', 'options': ['low', 'xhigh'], 'allow_custom_value': true,
      }),
      const ModelParameterRule(name: 'temperature', type: 'float', min: 0, max: 2),
    ]);
    expect(result.params, {'reasoning_effort': 'vendor-next-level'});
    expect(result.removedDetails.keys, ['temperature']);
  });

  test('provider-declared enum still removes unsupported values on model change', () {
    final result = mergeValidCompletionParams({'reasoning_effort': 'max'}, [
      ModelParameterRule.fromJson({'name': 'reasoning_effort', 'type': 'string', 'options': ['low', 'high']}),
    ]);
    expect(result.params, isEmpty);
    expect(result.removedDetails, {'reasoning_effort': 'unsupported option'});
  });
}
