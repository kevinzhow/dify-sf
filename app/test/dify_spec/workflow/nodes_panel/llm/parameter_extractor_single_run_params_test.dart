// dify-spec: web/app/components/workflow/nodes/parameter-extractor/__tests__/use-single-run-form-params.spec.ts
import 'package:dify_sf_app/src/workflow_editor/run/forms/query_vision_single_run.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/before_run_form.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../dify_test_i18n.dart';

const payload = {
  'query': ['node-1', 'query'],
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
  nodeType: 'parameter-extractor',
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
  group('parameter-extractor/use-single-run-form-params', () {
    test('builds variable and vision single-run forms and returns dependent vars', () {
      final calls = <Map<String, Object?>>[];
      final values = {
        'query': 'hello',
        '#context#': 'ctx',
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
        '#context#': 'ctx',
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
    test('skips malformed prompt variables when collecting dependent vars', () {
      final result = params(malformed: true);
      expect(result.getDependentVars(), [
        ['node-1', 'query'],
        ['node-3', 'image'],
      ]);
    });
  });
}
