// dify-spec: web/app/components/workflow/nodes/code/__tests__/use-config.spec.ts
// dify-spec: web/app/components/workflow/nodes/code/__tests__/use-single-run-form-params.spec.ts
//
// CodeConfig is use-config.ts (with useVarList and useOutputVarList) over plain data: the mocked useNodeCrud is a
// fixed `inputs` and a recording `setInputs`, the fetched per-language defaults are `allLanguageDefault`.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/code_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/code_parser.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> variable(String name, [String type = 'string']) => {
  'variable': name,
  'value_selector': ['start', name],
  'value_type': type,
};

Map<String, Object?> outputsOf([String name = 'result', String type = 'string']) => {
  name: {'type': type, 'children': null},
};

Map<String, Object?> createData([Map<String, Object?> overrides = const {}]) => {
  'title': 'Code',
  'desc': '',
  'type': 'code',
  'code_language': 'javascript',
  'code': 'function main({ foo }) { return { result: foo } }',
  'variables': [variable('foo')],
  'outputs': outputsOf(),
  ...overrides,
};

void main() {
  group('code/use-config', () {
    late List<Map<String, Object?>> setInputs;
    late Map<String, Object?> currentInputs;
    late Map<String, Object?> javaScriptConfig, pythonConfig, defaultConfig;

    setUp(() {
      setInputs = [];
      javaScriptConfig = createData({
        'code_language': 'javascript',
        'code': 'function main({ query }) { return { result: query } }',
        'variables': [variable('query')],
        'outputs': outputsOf('result'),
      });
      pythonConfig = createData({
        'code_language': 'python3',
        'code': 'def main(name: str):\n    return {"result": name}',
        'variables': [variable('name')],
        'outputs': outputsOf('result'),
      });
      currentInputs = createData();
      defaultConfig = createData({
        'code_language': 'javascript',
        'code': 'function main() { return { default_result: "" } }',
        'variables': <Object?>[],
        'outputs': outputsOf('default_result'),
      });
    });

    CodeConfig config({Map<String, Map<String, Object?>>? allLanguageDefault}) => CodeConfig(
      id: 'code-node',
      inputs: () => currentInputs,
      setInputs: setInputs.add,
      defaultConfig: defaultConfig,
      allLanguageDefault: allLanguageDefault,
    );

    test('hydrates node defaults when the code payload is empty and syncs output key order', () {
      currentInputs = createData({'code': '', 'variables': <Object?>[], 'outputs': <String, Object?>{}});
      final c = config()..init();
      expect(setInputs.single, containsPair('code', defaultConfig['code']));
      expect(setInputs.single, containsPair('outputs', defaultConfig['outputs']));
      expect(c.outputKeyOrders, ['default_result']);
      expect(CodeConfig.filterVar('file'), isTrue);
      expect(CodeConfig.filterVar('secret'), isTrue);
    });

    test('fetches app and pipeline defaults, switches language, and updates code and output vars together', () {
      final c = config(allLanguageDefault: {'javascript': javaScriptConfig, 'python3': pythonConfig})..init();
      setInputs.clear();
      c
        ..handleCodeLanguageChange('python3')
        ..handleCodeChange('function main({ bar }) { return { result: bar } }')
        ..handleCodeAndVarsChange(
          'function main({ amount }) { return { total: amount } }',
          [variable('amount', 'number')],
          outputsOf('total', 'number'),
        );
      expect(setInputs[0], containsPair('code_language', 'python3'));
      expect(setInputs[0], containsPair('code', pythonConfig['code']));
      expect(setInputs[0], containsPair('variables', pythonConfig['variables']));
      expect(setInputs[0], containsPair('outputs', pythonConfig['outputs']));
      expect(setInputs[1], containsPair('code', 'function main({ bar }) { return { result: bar } }'));
      expect(setInputs[2], containsPair('code', 'function main({ amount }) { return { total: amount } }'));
      expect((setInputs[2]['variables']! as List).single, containsPair('variable', 'amount'));
      expect(setInputs[2], containsPair('outputs', outputsOf('total', 'number')));
      expect(c.outputKeyOrders, ['total']);
    });

    test('syncs javascript and python function signatures and keeps json code unchanged', () {
      currentInputs = createData({
        'code_language': 'javascript',
        'code': 'function main() { return { result: "" } }',
        'variables': [variable('foo'), variable('bar')],
      });
      final c = config()..handleSyncFunctionSignature();
      expect(setInputs.last, containsPair('code', 'function main({foo, bar}) { return { result: "" } }'));

      currentInputs = createData({
        'code_language': 'python3',
        'code': 'def main():\n    return {"result": ""}',
        'variables': [
          variable('text', 'string'),
          variable('score', 'number'),
          variable('payload', 'object'),
          variable('items', 'array'),
          variable('numbers', 'array[number]'),
          variable('names', 'array[string]'),
          variable('records', 'array[object]'),
        ],
      });
      c.handleSyncFunctionSignature();
      expect(
        setInputs.last,
        containsPair(
          'code',
          'def main(text: str, score: float, payload: dict, items: list, numbers: list[float], names: list[str], '
              'records: list[dict]):\n    return {"result": ""}',
        ),
      );

      currentInputs = createData({'code_language': 'json', 'code': '{"result": true}'});
      c.handleSyncFunctionSignature();
      expect(setInputs.last, containsPair('code', '{"result": true}'));
    });

    test('keeps language changes local when no fetched default exists and preserves existing output order', () {
      currentInputs = createData({
        'outputs': {
          'summary': {'type': 'string', 'children': null},
          'count': {'type': 'number', 'children': null},
        },
      });
      final c = config()..init();
      expect(c.outputKeyOrders, ['summary', 'count']);
      setInputs.clear();
      c.handleCodeLanguageChange('python3');
      expect(setInputs.single, {...currentInputs, 'code_language': 'python3'});
    });
  });

  group('code/use-single-run-form-params', () {
    test('builds a single form, updates run input values, and exposes dependent vars', () {
      final runInputs = <Map<String, Object?>>[];
      final payload = createData({
        'variables': [
          {
            'variable': 'amount',
            'value_selector': ['start', 'amount'],
            'value_type': 'number',
          },
        ],
      });
      final r = varSingleRunFormParams(
        payload: payload,
        runInputData: {'amount': 1},
        setRunInputData: runInputs.add,
        toVarInputs: (variables) => [
          for (final v in variables.cast<Map<String, Object?>>())
            {'type': 'number', 'label': v['variable'], 'variable': v['variable'], 'required': false},
        ],
      );
      expect(r.forms, hasLength(1));
      expect(r.forms.single.inputs, [
        {'type': 'number', 'label': 'amount', 'variable': 'amount', 'required': false},
      ]);
      expect(r.forms.single.values, {'amount': 1});
      r.forms.single.onChange({'amount': 3});
      expect(runInputs.single, {'amount': 3});
      expect(r.getDependentVars(), [
        ['start', 'amount'],
      ]);
      expect(r.getDependentVar('amount'), ['start', 'amount']);
      expect(r.getDependentVar('missing'), isNull);
    });
  });
}
