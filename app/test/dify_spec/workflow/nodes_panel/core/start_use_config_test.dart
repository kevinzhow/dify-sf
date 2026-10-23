// dify-spec: web/app/components/workflow/nodes/start/__tests__/use-config.spec.ts
// dify-spec: web/app/components/workflow/nodes/start/__tests__/use-single-run-form-params.spec.ts
//
// StartConfig is use-config.ts with Dify's mocked hooks passed in; the calls they record are checked the same way.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/start_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/start_var_modal.dart';
import 'package:flutter_test/flutter_test.dart';

/// `withSelectorKey((key) => key)`: the key alone.
String t(String ns, String key, [Map<String, Object?> params = const {}]) => key;

Map<String, Object?> createInputVar([Map<String, Object?> overrides = const {}]) => {
  'label': 'Question',
  'variable': 'query',
  'type': 'text-input',
  'required': true,
  ...overrides,
};

Map<String, Object?> createPayload([Map<String, Object?> overrides = const {}]) => {
  'title': 'Start',
  'desc': '',
  'type': 'start',
  'variables': [
    createInputVar(),
    createInputVar({'label': 'Age', 'variable': 'age', 'type': 'number', 'required': false}),
  ],
  ...overrides,
};

void main() {
  group('start/use-config', () {
    late Map<String, Object?> currentInputs;
    late List<Map<String, Object?>> setInputs;
    late List<List<Object?>> renames, removedUses, inspectRenames, inspectDeletes;
    late List<String> nodeInspectorDeletes, toasts;
    late bool used;

    StartConfig useConfig() => StartConfig(
      id: 'start-node',
      inputs: () => currentInputs,
      setInputs: setInputs.add,
      handleOutVarRenameChange: (id, o, n) => renames.add([id, o, n]),
      isVarUsedInNodes: (_) => used,
      removeUsedVarInNodes: removedUses.add,
      nodesWithInspectVars: () => [
        {
          'nodeId': 'start-node',
          'vars': [
            {'id': 'inspect-query', 'name': 'query'},
          ],
        },
      ],
      deleteInspectVar: (n, v) => inspectDeletes.add([n, v]),
      deleteNodeInspectorVars: nodeInspectorDeletes.add,
      renameInspectVarName: (n, o, nn) => inspectRenames.add([n, o, nn]),
      toastError: toasts.add,
      t: t,
    );

    setUp(() {
      currentInputs = createPayload();
      setInputs = [];
      renames = [];
      removedUses = [];
      inspectRenames = [];
      inspectDeletes = [];
      nodeInspectorDeletes = [];
      toasts = [];
      used = false;
    });

    test('should rename variables and sync downstream variable references', () {
      final result = useConfig();
      final renamedList = [
        createInputVar({'label': 'Question', 'variable': 'prompt'}),
        createInputVar({'label': 'Age', 'variable': 'age', 'type': 'number', 'required': false}),
      ];
      result.handleVarListChange(renamedList, (
        index: 0,
        payload: const VarChange('changeVarName', beforeKey: 'query'),
      ));
      expect(setInputs.single['variables'], renamedList);
      expect(renames, [
        [
          'start-node',
          ['start-node', 'query'],
          ['start-node', 'prompt'],
        ],
      ]);
      expect(inspectRenames, [
        ['start-node', 'query', 'prompt'],
      ]);
      expect(result.readOnly, isFalse);
      expect(result.isChatMode, isFalse);
    });

    test('should block removal when the variable is still in use and confirm the deletion later', () {
      used = true;
      final result = useConfig();
      final nextList = [(currentInputs['variables']! as List)[1]];
      result.handleVarListChange(nextList, (index: 0, payload: const VarChange.remove('query')));
      expect(inspectDeletes, [
        ['start-node', 'inspect-query'],
      ]);
      expect(setInputs, isEmpty);
      expect(result.isShowRemoveVarConfirm, isTrue);

      result.onRemoveVarConfirm();
      expect((setInputs.single['variables']! as List).map((v) => (v as Map)['variable']), ['age']);
      expect(removedUses, [
        ['start-node', 'query'],
      ]);
      expect(result.isShowRemoveVarConfirm, isFalse);
    });

    test('should validate duplicate variables and labels before adding a new variable', () {
      final result = useConfig();
      expect(result.handleAddVariable(createInputVar({'label': 'Different Label', 'variable': 'query'})), isFalse);
      expect(toasts, ['varKeyError.keyAlreadyExists']);

      setInputs.clear();
      expect(
        result.handleAddVariable(createInputVar({'label': 'Locale', 'variable': 'locale', 'required': false})),
        isTrue,
      );
      expect((setInputs.single['variables']! as List).map((v) => (v as Map)['variable']), contains('locale'));
    });

    test('should clear inspector vars for non-remove list updates and reject duplicate labels', () {
      final result = useConfig();
      final typeEditedList = [
        createInputVar({'label': 'Question', 'variable': 'query', 'type': 'paragraph'}),
        (currentInputs['variables']! as List)[1],
      ];
      result.handleVarListChange(typeEditedList);
      expect(setInputs.single['variables'], typeEditedList);
      expect(nodeInspectorDeletes, ['start-node']);

      toasts.clear();
      expect(result.handleAddVariable(createInputVar({'label': 'Age', 'variable': 'new_age'})), isFalse);
      expect(toasts, ['varKeyError.keyAlreadyExists']);
    });
  });

  group('start/use-single-run-form-params', () {
    final payload = {
      'title': 'Start',
      'desc': '',
      'type': 'start',
      'variables': [
        {'label': 'Question', 'variable': 'query', 'type': 'text-input', 'required': true},
      ],
    };

    test('should include sys.query and sys.files dependencies for chat mode', () {
      final runs = <Map<String, Object?>>[];
      final result = startSingleRunFormParams(
        id: 'start-node',
        payload: payload,
        runInputData: {'query': 'hello'},
        setRunInputData: runs.add,
        isChatMode: true,
        t: t,
      );
      expect(result.forms, hasLength(1));
      expect(result.forms[0].label, 'nodes.llm.singleRun.variable');
      final inputs = result.forms[0].inputs;
      expect(inputs.any((i) => i['variable'] == 'query'), isTrue);
      expect(inputs.any((i) => i['variable'] == '#sys.query#' && i['required'] == true), isTrue);
      expect(inputs.any((i) => i['variable'] == '#sys.files#' && i['required'] == false), isTrue);

      result.forms[0].onChange({'query': 'updated'});
      expect(runs, [
        {'query': 'updated'},
      ]);
      expect(result.getDependentVars(), [
        ['start-node', 'query'],
        ['sys', 'files'],
        ['sys', 'query'],
      ]);
      expect(result.getDependentVar('query'), ['start-node', 'query']);
    });

    test('should omit sys.query when the workflow is not in chat mode', () {
      final result = startSingleRunFormParams(
        id: 'start-node',
        payload: payload,
        runInputData: {},
        setRunInputData: (_) {},
        t: t,
      );
      expect(result.forms[0].inputs.any((i) => i['variable'] == '#sys.query#'), isFalse);
      expect(result.getDependentVars(), [
        ['start-node', 'query'],
        ['sys', 'files'],
      ]);
    });
  });
}
