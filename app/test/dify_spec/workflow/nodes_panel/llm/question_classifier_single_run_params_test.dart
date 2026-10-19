// dify-spec: web/app/components/workflow/nodes/question-classifier/__tests__/use-single-run-form-params.spec.ts
import 'package:dify_sf_app/src/workflow_editor/run/forms/query_vision_single_run.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/before_run_form.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../dify_test_i18n.dart';

const payload = {
  'query_variable_selector': ['node-1', 'query'],
  'instruction': 'Process {{#node-2.answer#}}',
  'vision': {
    'enabled': true,
    'configs': {
      'variable_selector': ['node-3', 'image'],
    },
  },
};

QueryVisionSingleRunParams params({
  Map<String, Object?> values = const {},
  void Function(Map<String, Object?>)? onChange,
  Map<String, Object?> Function()? currentValues,
  bool vision = true,
  bool malformed = false,
}) => QueryVisionSingleRunParams(
  nodeType: 'question-classifier',
  payload: payload,
  values: values,
  onChange: onChange ?? (_) {},
  currentValues: currentValues,
  isVisionModel: vision,
  getInputVars: (texts) {
    expect(texts, [payload['instruction']]);
    return [
      {
        'label': 'Answer',
        'variable': malformed ? null : '#node-2.answer#',
        'type': InputVarType.textInput,
        'required': true,
      },
    ];
  },
  resolveVisionInput: (selector) {
    expect(selector, ['node-3', 'image']);
    return {'label': 'image', 'type': InputVarType.singleFile};
  },
);

void main() {
  setUp(useDifyTestTranslator);
  group('question-classifier/use-single-run-form-params', () {
    test('builds variable and vision forms and exposes dependent variables', () {
      final calls = <Map<String, Object?>>[];
      final values = {
        'query': 'hello',
        '#files#': ['file-1'],
      };
      final result = params(values: values, onChange: calls.add);
      expect(result.forms, hasLength(2));
      expect(result.forms.first.inputs.first, containsPair('variable', 'query'));
      expect(result.forms.first.inputs.first, containsPair('type', InputVarType.paragraph));
      expect(result.forms.first.inputs[1], containsPair('variable', '#node-2.answer#'));
      expect(result.forms[1].inputs, [
        {'label': 'image', 'variable': '#files#', 'type': InputVarType.singleFile, 'required': false},
      ]);
      expect(result.forms.first.values, {'query': 'hello'});
      result.forms[0].onChange({'query': 'updated'});
      result.forms[1].onChange({
        '#files#': ['file-2'],
      });
      expect(calls[0], {
        'query': 'updated',
        '#files#': ['file-1'],
      });
      expect(calls[1], {
        ...values,
        '#files#': ['file-2'],
      });
      expect(result.getDependentVars(), [
        ['node-1', 'query'],
        ['node-2', 'answer'],
        ['node-3', 'image'],
      ]);
      expect(result.getDependentVar('query'), ['node-1', 'query']);
      expect(result.getDependentVar('#files#'), ['node-3', 'image']);
      expect(result.getDependentVar('unknown'), isNull);
    });
    test('omits the vision form when the selected model does not support vision', () {
      final result = params(vision: false);
      expect(result.forms, hasLength(1));
      expect(result.getDependentVars(), [
        ['node-1', 'query'],
        ['node-2', 'answer'],
      ]);
    });
    test('skips malformed prompt variables when collecting dependent vars', () {
      final result = params(malformed: true);
      expect(result.getDependentVars(), [
        ['node-1', 'query'],
        ['node-3', 'image'],
      ]);
    });
  });
}
