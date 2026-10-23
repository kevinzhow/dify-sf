// dify-spec: web/app/components/workflow/nodes/assigner/__tests__/use-config.helpers.spec.ts
// dify-spec: web/app/components/workflow/nodes/assigner/__tests__/use-config.spec.tsx
// dify-spec: web/app/components/workflow/nodes/assigner/__tests__/use-single-run-form-params.spec.ts
//
// The hooks as the pure Dart of AssignerConfig and assigner_utils.dart: Dify's mocked `useNodeCrud` setInputs and
// `getCurrentVariableType` are callbacks of the config. The single-run form is `assignerDependentVars` (the form
// itself, `varSelectorsToVarInputs`, is the host's).
import 'package:dify_sf_app/src/workflow/var_types.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/assigner_panel.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> createOperation([Map<String, Object?> overrides = const {}]) => {
  'variable_selector': ['conversation', 'count'],
  'input_type': AssignerNodeInputType.variable,
  'operation': WriteMode.overwrite,
  'value': ['node-1', 'value'],
  ...overrides,
};

Map<String, Object?> createInputs([String version = '1']) => {
  'title': 'Assigner',
  'desc': '',
  'type': 'assigner',
  'version': version,
  'items': [createOperation()],
};

void main() {
  group('assigner use-config helpers', () {
    test('filters vars and selectors by supported targets', () {
      expect(filterVarByType(VarType.any)(VarType.string), isTrue);
      expect(filterVarByType(VarType.number)(VarType.any), isTrue);
      expect(filterVarByType(VarType.number)(VarType.string), isFalse);
      expect(canAssignVar(['conversation', 'total']), isTrue);
      expect(canAssignVar(['sys', 'total']), isFalse);
    });

    test('normalizes assigned variable types for append and passthrough write modes', () {
      expect(normalizeAssignedVarType(VarType.arrayString, WriteMode.append), VarType.string);
      expect(normalizeAssignedVarType(VarType.arrayNumber, WriteMode.append), VarType.number);
      expect(normalizeAssignedVarType(VarType.arrayObject, WriteMode.append), VarType.object);
      expect(normalizeAssignedVarType(VarType.number, WriteMode.append), VarType.string);
      expect(normalizeAssignedVarType(VarType.number, WriteMode.increment), VarType.number);
      expect(normalizeAssignedVarType(VarType.string, WriteMode.clear), VarType.string);
    });

    test('validates assignment targets for append, arithmetic and fallback modes', () {
      expect(canAssignToVar(VarType.number, VarType.number, WriteMode.multiply), isTrue);
      expect(canAssignToVar(VarType.string, VarType.number, WriteMode.multiply), isFalse);
      expect(canAssignToVar(VarType.string, VarType.arrayString, WriteMode.append), isTrue);
      expect(canAssignToVar(VarType.number, VarType.arrayNumber, WriteMode.append), isTrue);
      expect(canAssignToVar(VarType.object, VarType.arrayObject, WriteMode.append), isTrue);
      expect(canAssignToVar(VarType.boolean, VarType.arrayString, WriteMode.append), isFalse);
      expect(canAssignToVar(VarType.string, VarType.string, WriteMode.set), isTrue);
    });

    test('ensures version 2 and replaces operation items immutably', () {
      final legacyInputs = createInputs('1');
      final nextItems = [
        {
          'variable_selector': ['conversation', 'total'],
          'input_type': AssignerNodeInputType.constant,
          'operation': WriteMode.clear,
          'value': '0',
        },
      ];

      expect(ensureAssignerVersion(legacyInputs)['version'], '2');
      expect(ensureAssignerVersion(createInputs('2'))['version'], '2');
      expect(updateOperationItems(legacyInputs, nextItems)['items'], nextItems);
      expect(legacyInputs['items'], hasLength(1));
    });

    test('sanitizes variable-selector items restored from collaboration payloads', () {
      final dirtyItems = [
        {
          'variable_selector': null,
          'input_type': AssignerNodeInputType.variable,
          'operation': WriteMode.overwrite,
          'value': null,
        },
      ];

      expect(updateOperationItems(createInputs('2'), dirtyItems)['items'], [
        {
          'variable_selector': <Object?>[],
          'input_type': AssignerNodeInputType.variable,
          'operation': WriteMode.overwrite,
          'value': <Object?>[],
        },
      ]);
    });
  });

  group('useConfig', () {
    Map<String, Object?> op([Map<String, Object?> overrides = const {}]) => createOperation({
      'variable_selector': ['conversation', 'count'],
      'value': ['node-2', 'result'],
      ...overrides,
    });
    Map<String, Object?> payload([Map<String, Object?> overrides = const {}]) => {
      ...createInputs('1'),
      'items': [op()],
      ...overrides,
    };
    late List<Map<String, Object?>> setInputs;
    AssignerConfig config(Map<String, Object?> payload) =>
        AssignerConfig(rawInputs: () => payload, setInputs: setInputs.add, varTypeOf: (_) => VarType.arrayString);

    setUp(() => setInputs = []);

    test('should normalize legacy payloads, expose write mode groups and derive assigned variable types', () {
      final result = config(payload());

      expect(result.readOnly, isFalse);
      expect(result.writeModeTypes, [WriteMode.overwrite, WriteMode.clear, WriteMode.set]);
      expect(result.writeModeTypesNum, writeModeTypesNum);
      expect(result.getAssignedVarType(['conversation', 'count']), VarType.arrayString);
      expect(result.getToAssignedVarType(VarType.arrayString, WriteMode.append), VarType.string);
      expect(result.filterVar(VarType.string)(VarType.any), isTrue);
    });

    test('should update operation lists with version 2 payloads and apply assignment filters', () {
      final result = config(payload());
      final nextItems = [
        op({'operation': WriteMode.append}),
      ];

      result.handleOperationListChanges(nextItems);

      expect(setInputs.single['version'], '2');
      expect(setInputs.single['items'], nextItems);
      expect(result.filterAssignedVar(true, ['node', 'value']), isTrue);
      expect(result.filterAssignedVar(false, ['conversation', 'name']), isTrue);
      expect(result.filterToAssignedVar(VarType.string, VarType.arrayString, WriteMode.append), isTrue);
      expect(result.filterToAssignedVar(VarType.number, VarType.arrayString, WriteMode.append), isFalse);
    });

    test('should normalize collaboration-restored null selectors before exposing inputs', () {
      final dirtyPayload = payload({
        'version': '2',
        'items': [
          op({'variable_selector': null, 'input_type': AssignerNodeInputType.variable, 'value': null}),
        ],
      });

      final result = config(dirtyPayload);

      expect(result.inputs['items'], [
        allOf(
          containsPair('variable_selector', <Object?>[]),
          containsPair('input_type', AssignerNodeInputType.variable),
          containsPair('operation', WriteMode.overwrite),
          containsPair('value', <Object?>[]),
        ),
      ]);
    });
  });

  group('assigner/use-single-run-form-params', () {
    test('exposes only variable-driven dependencies in the single-run form', () {
      Map<String, Object?> op([Map<String, Object?> o = const {}]) => createOperation({
        'variable_selector': ['node-1', 'target'],
        'value': ['node-2', 'result'],
        ...o,
      });
      final data = {
        ...createInputs('2'),
        'items': [
          op(),
          op({
            'operation': WriteMode.append,
            'value': ['node-3', 'items'],
          }),
          op({
            'operation': WriteMode.clear,
            'value': ['node-4', 'unused'],
          }),
          op({'operation': WriteMode.set, 'input_type': AssignerNodeInputType.constant, 'value': 'fixed'}),
          op({'operation': WriteMode.increment, 'input_type': AssignerNodeInputType.constant, 'value': 2}),
        ],
      };

      expect(assignerDependentVars(data), [
        ['node-2', 'result'],
        ['node-3', 'items'],
      ]);
    });
  });
}
