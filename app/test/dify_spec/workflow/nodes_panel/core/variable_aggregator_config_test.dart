// dify-spec: web/app/components/workflow/nodes/variable-assigner/__tests__/use-config.spec.tsx
// dify-spec: web/app/components/workflow/nodes/variable-assigner/__tests__/hooks.spec.ts
// dify-spec: web/app/components/workflow/nodes/variable-assigner/__tests__/use-single-run-form-params.spec.ts
//
// The hooks as pure Dart: VariableAggregatorConfig (use-config.ts), VariableAssignerHooks and useGetAvailableVars
// (hooks.ts) and variableAggregatorSingleRunFormParams, with Dify's mocks as injected callbacks.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/variable_aggregator_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Json = Map<String, Object?>;

Json createPayload([Json overrides = const {}]) => {
  'title': 'Variable Assigner',
  'desc': '',
  'type': 'variable-assigner',
  'output_type': 'string',
  'variables': [
    ['source-node', 'initialVar'],
  ],
  'advanced_settings': {
    'group_enabled': true,
    'groups': [
      {
        'groupId': 'group-1',
        'group_name': 'Group1',
        'output_type': 'string',
        'variables': [
          ['source-node', 'initialVar'],
        ],
      },
      {'groupId': 'group-2', 'group_name': 'Group2', 'output_type': 'number', 'variables': <Object?>[]},
    ],
  },
  ...overrides,
};

/// `useConfig('assigner-node', payload)` with the spec's mocks.
class Mocks {
  final setInputs = <Json>[];
  final deleteNodeInspectorVars = <String>[];
  final renameInspectVarName = <List<String>>[];
  final handleOutVarRenameChange = <List<Object>>[];
  final removeUsedVarInNodes = <List<String>>[];
  bool Function(List<String>) isVarUsedInNodes = (_) => false;

  VariableAggregatorConfig config(Json payload) => VariableAggregatorConfig(
    id: 'assigner-node',
    inputs: () => payload,
    setInputs: setInputs.add,
    handleOutVarRenameChange: (id, o, n) => handleOutVarRenameChange.add([id, o, n]),
    isVarUsedInNodes: (s) => isVarUsedInNodes(s),
    removeUsedVarInNodes: removeUsedVarInNodes.add,
    deleteNodeInspectorVars: deleteNodeInspectorVars.add,
    renameInspectVarName: (id, o, n) => renameInspectVarName.add([id, o, n]),
    uuid: () => 'generated-group-id',
    renameDebounce: Duration.zero,
  );

  bool setWith(bool Function(Json) p) => setInputs.any(p);
}

List<Json> groupsOf(Json data) => [for (final g in (data['advanced_settings']! as Map)['groups'] as List) g as Json];

void main() {
  group('useConfig', () {
    late Mocks m;
    setUp(() => m = Mocks());

    test('should update root and grouped variable payloads', () {
      final c = m.config(createPayload());
      c.handleListOrTypeChange({
        'output_type': 'number',
        'variables': [
          ['source-node', 'changed'],
        ],
      });
      c.handleListOrTypeChangeInGroup('group-1')({
        'output_type': 'boolean',
        'variables': [
          ['source-node', 'groupVar'],
        ],
      });
      expect(
        m.setWith(
          (d) =>
              d['output_type'] == 'number' && (d['variables']! as List).single.toString() == '[source-node, changed]',
        ),
        isTrue,
      );
      expect(
        m.setWith((d) {
          final g = groupsOf(d);
          return g.length == 2 &&
              g[0]['groupId'] == 'group-1' &&
              g[0]['output_type'] == 'boolean' &&
              g[0]['variables'].toString() == '[[source-node, groupVar]]';
        }),
        isTrue,
      );
    });

    test('should add and remove groups and toggle group mode', () {
      final c = m.config(createPayload());
      c.handleAddGroup();
      c.handleGroupRemoved('group-2')();
      c.handleGroupEnabledChange(false);
      expect(
        m.setWith((d) => groupsOf(d).any((g) => g['groupId'] == 'generated-group-id' && g['group_name'] == 'Group3')),
        isTrue,
      );
      expect(m.setWith((d) => groupsOf(d).map((g) => g['groupId']).join() == 'group-1'), isTrue);
      expect(
        m.setWith(
          (d) =>
              (d['advanced_settings']! as Map)['group_enabled'] == false &&
              d['output_type'] == 'string' &&
              d['variables'].toString() == '[[source-node, initialVar]]',
        ),
        isTrue,
      );
      expect(m.deleteNodeInspectorVars, contains('assigner-node'));
      expect(m.handleOutVarRenameChange, [
        [
          'assigner-node',
          ['assigner-node', 'Group1', 'output'],
          ['assigner-node', 'output'],
        ],
      ]);
    });

    test('should rename groups and remove used vars after confirmation', () {
      final c = m.config(createPayload());
      c.handleVarGroupNameChange('group-1')('Renamed');
      c.onRemoveVarConfirm();
      expect(
        m.setWith((d) {
          final g = groupsOf(d);
          return g.length == 2 && g[0]['groupId'] == 'group-1' && g[0]['group_name'] == 'Renamed';
        }),
        isTrue,
      );
      expect(m.handleOutVarRenameChange, [
        [
          'assigner-node',
          ['assigner-node', 'Group1', 'output'],
          ['assigner-node', 'Renamed', 'output'],
        ],
      ]);
      expect(m.renameInspectVarName, [
        ['assigner-node', 'Group1', 'Renamed'],
      ]);
    });

    test('should confirm removing a used group before deleting it', () {
      m.isVarUsedInNodes = (s) => s[1] == 'Group2';
      final c = m.config(createPayload());
      c.handleGroupRemoved('group-2')();
      expect(c.isShowRemoveVarConfirm, isTrue);
      expect(m.setInputs, isEmpty);
      c.onRemoveVarConfirm();
      expect(m.removeUsedVarInNodes, [
        ['assigner-node', 'Group2', 'output'],
      ]);
      expect(m.setWith((d) => groupsOf(d).map((g) => g['groupId']).join() == 'group-1'), isTrue);
    });

    test('should enable empty groups and confirm disabling when downstream vars are used', () {
      m
          .config(
            createPayload({
              'advanced_settings': {'group_enabled': false, 'groups': <Object?>[]},
            }),
          )
          .handleGroupEnabledChange(true);
      expect(m.handleOutVarRenameChange.single, [
        'assigner-node',
        ['assigner-node', 'output'],
        ['assigner-node', 'Group1', 'output'],
      ]);

      m.isVarUsedInNodes = (s) => s[1] == 'Group2';
      final c = m.config(createPayload());
      c.handleGroupEnabledChange(false);
      c.onRemoveVarConfirm();
      expect(m.removeUsedVarInNodes, [
        ['assigner-node', 'Group2', 'output'],
      ]);
      expect(m.setWith((d) => (d['advanced_settings']! as Map)['group_enabled'] == false), isTrue);
    });

    test('should not throw when enabling groups with missing advanced settings', () {
      final c = m.config(createPayload()..remove('advanced_settings'));
      expect(() => c.handleGroupEnabledChange(true), returnsNormally);
      expect(m.handleOutVarRenameChange.single, [
        'assigner-node',
        ['assigner-node', 'output'],
        ['assigner-node', 'Group1', 'output'],
      ]);
      expect(
        m.setWith((d) {
          final s = d['advanced_settings']! as Map;
          return s['group_enabled'] == true && groupsOf(d).single['group_name'] == 'Group1';
        }),
        isTrue,
      );
      expect(m.deleteNodeInspectorVars, ['assigner-node']);
    });
  });

  group('variable-assigner/hooks', () {
    late List<Json> nodes;
    late List<({String id, Json data})> updates;
    late List<List<Json>> setNodes;
    late int popupClosed;
    late List<String?> hovering;

    VariableAssignerHooks hooks() => VariableAssignerHooks(
      getNodes: () => nodes,
      setNodes: setNodes.add,
      handleNodeDataUpdate: ({required id, required data}) => updates.add((id: id, data: data)),
      setShowAssignVariablePopup: () => popupClosed++,
      setHoveringAssignVariableGroupId: hovering.add,
      connectingNodePayload: () => {'id': 'connecting-node'},
    );

    setUp(() {
      updates = [];
      setNodes = [];
      popupClosed = 0;
      hovering = [];
      nodes = [
        {
          'id': 'assigner-1',
          'data': {
            'variables': [
              ['start', 'foo'],
            ],
            'output_type': 'string',
            'advanced_settings': {
              'groups': [
                {'groupId': 'group-1', 'variables': <Object?>[], 'output_type': 'string'},
              ],
            },
          },
        },
      ];
    });

    test('should append target variables, ignore duplicates, and update grouped variables', () {
      final h = hooks();
      h.handleAssignVariableValueChange('assigner-1', ['start', 'bar'], const PickerVar('', 'number'));
      h.handleAssignVariableValueChange('assigner-1', ['start', 'foo'], const PickerVar('', 'number'));
      h.handleAssignVariableValueChange(
        'assigner-1',
        [
          'start',
          'grouped',
        ],
        const PickerVar('', 'array[string]'),
        'group-1',
      );
      expect(updates, hasLength(2));
      expect(updates[0].id, 'assigner-1');
      expect(updates[0].data, {
        'variables': [
          ['start', 'foo'],
          ['start', 'bar'],
        ],
        'output_type': 'number',
      });
      expect(updates[1].data, {
        'advanced_settings': {
          'groups': [
            {
              'groupId': 'group-1',
              'variables': [
                ['start', 'grouped'],
              ],
              'output_type': 'array[string]',
            },
          ],
        },
      });
    });

    test('should close the popup and add variables through the positioned add-variable flow', () {
      nodes = [
        {
          'id': 'source-node',
          'data': {'_showAddVariablePopup': true, '_holdAddVariablePopup': true},
        },
        {
          'id': 'assigner-1',
          'data': {
            'variables': <Object?>[],
            'advanced_settings': {
              'groups': [
                {'groupId': 'group-1', 'variables': <Object?>[]},
              ],
            },
            '_showAddVariablePopup': true,
            '_holdAddVariablePopup': true,
          },
        },
      ];
      hooks().handleAddVariableInAddVariablePopupWithPosition('source-node', 'assigner-1', 'group-1', [
        'start',
        'output',
      ], const PickerVar('', 'object'));
      final set = setNodes.single;
      expect(set.map((n) => n['id']), ['source-node', 'assigner-1']);
      for (final n in set) {
        expect(n['data'], containsPair('_showAddVariablePopup', false));
        expect(n['data'], containsPair('_holdAddVariablePopup', false));
      }
      expect(popupClosed, 1);
      expect(updates.single.data, {
        'advanced_settings': {
          'groups': [
            {
              'groupId': 'group-1',
              'variables': [
                ['start', 'output'],
              ],
              'output_type': 'object',
            },
          ],
        },
      });
    });

    test('should update the hovered group state on enter and leave', () {
      final h = hooks();
      h.handleGroupItemMouseEnter('group-1');
      h.handleGroupItemMouseLeave();
      expect(hovering, ['group-1', null]);
    });

    List<(bool, String)> shape(List<VarGroup> groups) => [
      for (final g in groups) (g.isStartNode, [for (final v in g.vars) v.variable].join(',')),
    ];

    test('should collect available vars and filter start-node env vars when hideEnv is enabled', () {
      final answers = [
        [
          const VarGroup(
            nodeId: 'start',
            title: 'Start',
            isStartNode: true,
            vars: [PickerVar('sys.user_id', null), PickerVar('foo', null)],
          ),
          const VarGroup(nodeId: 'n', title: 'N', vars: []),
        ],
        [
          const VarGroup(nodeId: 'n', title: 'N', vars: [PickerVar('bar', null)]),
        ],
      ];
      final queries = <NodeAvailableVarsQuery>[];
      final get = useGetAvailableVars(
        nodes: const [
          (id: 'current-node', parentId: 'parent-node'),
          (id: 'before-1', parentId: null),
          (id: 'parent-node', parentId: null),
        ],
        getBeforeNodesInSameBranchIncludeParent: (_) => const [
          (id: 'before-1', parentId: null),
          (id: 'before-1', parentId: null),
        ],
        getNodeAvailableVars: (q) {
          queries.add(q);
          return answers[queries.length - 1];
        },
      );
      expect(shape(get('current-node', 'target', (_) => true, true)), [
        (true, 'foo'),
      ]);
      expect(shape(get('current-node', 'target', (_) => true, false)), [
        (false, 'bar'),
      ]);
      expect(get('missing-node', 'target', (_) => true), isEmpty);
      expect(queries.first.beforeNodes, [(id: 'before-1', parentId: null)]);
      expect(queries.first.parentNode?.id, 'parent-node');
      expect(queries.first.hideEnv, isTrue);
    });

    test('should filter system variables when the current flow is a snippet', () {
      final get = useGetAvailableVars(
        nodes: const [(id: 'current-node', parentId: null), (id: 'before-1', parentId: null)],
        getBeforeNodesInSameBranchIncludeParent: (_) => const [(id: 'before-1', parentId: null)],
        getNodeAvailableVars: (_) => const [
          VarGroup(nodeId: 'n', title: 'N', vars: [PickerVar('sys.user_id', null), PickerVar('answer', null)]),
        ],
        isSnippetFlow: true,
      );
      expect(shape(get('current-node', 'target', (_) => true, false)), [
        (false, 'answer'),
      ]);
    });
  });

  group('variable-assigner/use-single-run-form-params', () {
    test('deduplicates grouped variable inputs and marks them optional for single run', () {
      final runs = <Json>[];
      final calls = <List<List<String>>>[];
      final r = variableAggregatorSingleRunFormParams(
        payload: {
          ...createPayload(),
          'variables': [
            ['source-node', 'rootVar'],
          ],
          'advanced_settings': {
            'group_enabled': true,
            'groups': [
              {
                'groupId': 'group-1',
                'group_name': 'Group1',
                'output_type': 'string',
                'variables': [
                  ['source-node', 'sharedVar'],
                  ['source-node', 'uniqueVar'],
                ],
              },
              {
                'groupId': 'group-2',
                'group_name': 'Group2',
                'output_type': 'number',
                'variables': [
                  ['source-node', 'sharedVar'],
                ],
              },
            ],
          },
        },
        runInputData: {'sharedVar': 'hello'},
        setRunInputData: runs.add,
        varSelectorsToVarInputs: (s) {
          calls.add(s);
          return [
            {'label': 'Shared', 'variable': 'sharedVar', 'type': 'text-input', 'required': true},
            {'label': 'Unique', 'variable': 'uniqueVar', 'type': 'number', 'required': true},
            {'label': 'Shared duplicate', 'variable': 'sharedVar', 'type': 'text-input', 'required': true},
          ];
        },
      );
      expect(calls.single, [
        ['source-node', 'sharedVar'],
        ['source-node', 'uniqueVar'],
        ['source-node', 'sharedVar'],
      ]);
      expect(r.forms.first.inputs, [
        {'label': 'Shared', 'variable': 'sharedVar', 'type': 'text-input', 'required': false},
        {'label': 'Unique', 'variable': 'uniqueVar', 'type': 'number', 'required': false},
      ]);
      r.forms.first.onChange({'sharedVar': 'updated'});
      expect(runs.single, {'sharedVar': 'updated'});
      expect(r.getDependentVars(), [
        [
          ['source-node', 'sharedVar'],
          ['source-node', 'uniqueVar'],
        ],
        [
          ['source-node', 'sharedVar'],
        ],
      ]);
    });

    test('returns root variables directly when grouping is disabled', () {
      final r = variableAggregatorSingleRunFormParams(
        payload: createPayload({
          'advanced_settings': {'group_enabled': false, 'groups': <Object?>[]},
          'variables': [
            ['source-node', 'rootVar'],
          ],
        }),
        runInputData: {},
        setRunInputData: (_) {},
        varSelectorsToVarInputs: (_) => [],
      );
      expect(r.getDependentVars(), [
        [
          ['source-node', 'rootVar'],
        ],
      ]);
    });
  });
}
