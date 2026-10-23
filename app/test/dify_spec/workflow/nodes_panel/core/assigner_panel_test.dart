// dify-spec: web/app/components/workflow/nodes/assigner/__tests__/panel.spec.tsx
// dify-spec: web/app/components/workflow/nodes/assigner/__tests__/integration.spec.tsx
// dify-spec: web/app/components/workflow/nodes/assigner/__tests__/node.spec.tsx
// dify-spec: web/app/components/workflow/nodes/assigner/components/__tests__/operation-selector.spec.tsx
// dify-spec: web/app/components/workflow/nodes/assigner/components/var-list/__tests__/index.spec.tsx
// dify-spec: web/app/components/workflow/nodes/assigner/components/var-list/__tests__/branches.spec.tsx
//
// Dify mocks the variable reference picker, the operation selector and the code editor; here the real widgets run
// over a variable scope of the nodes the specs name, and the panel over a document in an in-memory session. The
// canvas card (node.spec) is dify-sf's AssignerBody, whose labels are English text, not i18n keys.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/bodies/data_bodies.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:dify_sf_app/src/workflow/var_types.dart';
import 'package:dify_sf_app/src/workflow_editor/code_editor/code_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/assigner_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../panel_fields/harness.dart' show render, scopeOf;
import 'harness.dart';

Map<String, Object?> createOperation([Map<String, Object?> overrides = const {}]) => {
  'variable_selector': ['node-1', 'count'],
  'input_type': AssignerNodeInputType.variable,
  'operation': WriteMode.overwrite,
  'value': ['node-2', 'result'],
  ...overrides,
};

/// var-list specs' operations (`node-a`).
Map<String, Object?> opA([Map<String, Object?> overrides = const {}]) => createOperation({
  'variable_selector': ['node-a', 'flag'],
  'value': ['node-a', 'answer'],
  ...overrides,
});

final _scope = scopeOf(
  [
    VarGroup(nodeId: 'node-1', title: 'Answer', vars: const [PickerVar('count', 'string')]),
    VarGroup(
      nodeId: 'node-2',
      title: 'Code',
      vars: const [PickerVar('result', 'string'), PickerVar('other', 'string')],
    ),
    VarGroup(
      nodeId: 'node-a',
      title: 'Answer Node',
      vars: const [PickerVar('answer', 'string'), PickerVar('flag', 'boolean')],
    ),
    VarGroup(nodeId: 'node-b', title: 'Node B', vars: const [PickerVar('total', 'number')]),
  ],
  nodes: [
    const Node(id: 'node-1', type: 'answer', title: 'Answer'),
    const Node(id: 'node-2', type: 'code', title: 'Code'),
    const Node(id: 'node-a', type: 'answer', title: 'Answer Node'),
    const Node(id: 'node-b', type: 'code', title: 'Node B'),
  ],
);

/// The `onChange(list, value?)` calls and `onOpen(index)` calls of a rendered var list.
class VarListCalls {
  final changes = <(List<Map<String, Object?>>, Object?)>[];
  final opens = <int>[];
  (List<Map<String, Object?>>, Object?) get last => changes.last;
}

Future<VarListCalls> renderVarList(
  WidgetTester t, {
  List<Map<String, Object?>> list = const [],
  String? assignedType = VarType.string,
  String toAssignedType = VarType.string,
  List<String> writeModeTypesNum = const [WriteMode.increment],
  VarListCalls? calls,
}) async {
  final c = calls ?? VarListCalls();
  await render(
    t,
    AssignerVarList(
      readonly: false,
      list: list,
      scope: _scope,
      onChange: (l, [v]) => c.changes.add((l, v)),
      onOpen: c.opens.add,
      filterVar: (_, _) => true,
      filterToAssignedVar: (_, _, _) => true,
      getAssignedVarType: (_) => assignedType,
      getToAssignedVarType: (_, _) => toAssignedType,
      writeModeTypes: const [WriteMode.overwrite, WriteMode.clear, WriteMode.set],
      writeModeTypesArr: const [WriteMode.overwrite, WriteMode.clear],
      writeModeTypesNum: writeModeTypesNum,
    ),
    width: 420,
  );
  await settle(t);
  return c;
}

/// Dify's `toHaveBeenLastCalledWith(list, value)`.
void expectCall(VarListCalls c, (List<Map<String, Object?>>, Object?) expected) {
  expect(c.last.$1, expected.$1);
  expect(c.last.$2, expected.$2);
}

String op(String name) => 'workflow.nodes.assigner.operations.$name';

Future<void> tapText(WidgetTester t, String text) async {
  await t.tap(find.text(text).last);
  await settle(t);
}

/// The picker of [popupFor] (`assigned` / `toAssigned`).
VarReferencePicker picker(WidgetTester t, String popupFor) =>
    t.widget<VarReferencePicker>(find.byWidgetPredicate((w) => w is VarReferencePicker && w.popupFor == popupFor));

Future<void> renderOperationSelector(
  WidgetTester t, {
  required ValueChanged<OperationItem> onSelect,
  bool disabled = false,
  String assignedVarType = VarType.number,
  List<String> writeModeTypes = const [WriteMode.overwrite, WriteMode.clear, WriteMode.set],
  List<String>? writeModeTypesArr = const [WriteMode.overwrite, WriteMode.clear],
  List<String>? writeModeTypesNum = const [WriteMode.increment],
}) async {
  await render(
    t,
    Align(
      alignment: Alignment.topLeft,
      child: OperationSelector(
        value: WriteMode.overwrite,
        onSelect: onSelect,
        disabled: disabled,
        assignedVarType: assignedVarType,
        writeModeTypes: writeModeTypes,
        writeModeTypesArr: writeModeTypesArr,
        writeModeTypesNum: writeModeTypesNum,
      ),
    ),
  );
  await settle(t);
}

// ---- the canvas card ---------------------------------------------------------------------------------------------

final _cardNodes = difyNodes([
  difyNode('node-1', 'answer', {}, 'Answer'),
  difyNode('start-node', 'start', {'variables': <Object?>[]}, 'Start'),
]);

Future<void> renderCard(WidgetTester t, Map<String, Object?> data) async {
  final node = difyNodes([
    ..._cardNodes.map((n) => difyNode(n.id, n.type, {}, n.title)),
    difyNode('assigner-node', 'assigner', data, 'Assigner'),
  ]).last;
  final byId = {for (final n in _cardNodes) n.id: n};
  final ctx = BodyContext(node, (id) => byId[id], start: byId['start-node']);
  useDifyTestTranslator();
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 238, child: Builder(builder: (c) => const AssignerBody().build(c, ctx))),
        ),
      ),
    ),
  );
}

Map<String, Object?> v2(List<Map<String, Object?>> items) => {'version': '2', 'items': items};
Map<String, Object?> legacy(List<String> selector, String writeMode) => {
  'assigned_variable_selector': selector,
  'write_mode': writeMode,
};

/// A variable label of the card: its node title and variable name.
void expectLabel(String title, String variable) {
  expect(find.text(title), findsOneWidget);
  expect(find.text(variable), findsOneWidget);
}

// ---- the panel ---------------------------------------------------------------------------------------------------

/// openCorePanel with the assigner's body (whatever the core registry holds).
Future<CorePanel> openAssignerPanel(
  WidgetTester t,
  List<Node> nodes,
  String nodeId, {
  List<Edge> edges = const [],
}) => openCorePanel(t, nodes, nodeId, edges: edges);

/// node-1 is a loop with the `count` and `updated` loop variables (assignable), node-2 a code node with `result`.
Future<CorePanel> openAssigner(WidgetTester t, {List<Map<String, Object?>>? items}) => openAssignerPanel(
  t,
  difyNodes([
    difyNode('node-2', 'code', {
      'outputs': {
        'result': {'type': 'string'},
      },
    }, 'Code'),
    difyNode('node-1', 'loop', {
      'loop_variables': [
        {'id': 'lv1', 'label': 'count', 'var_type': 'string', 'value_type': 'constant', 'value': ''},
        {'id': 'lv2', 'label': 'updated', 'var_type': 'string', 'value_type': 'constant', 'value': ''},
      ],
    }, 'Loop'),
    difyNode('assigner-node', 'assigner', {
      'version': '2',
      'items': items ?? [createOperation()],
    }, 'Assigner'),
  ]),
  'assigner-node',
  edges: const [
    Edge(id: 'e1', source: 'node-2', target: 'node-1'),
    Edge(id: 'e2', source: 'node-1', target: 'assigner-node'),
  ],
);

final _blank = {
  'variable_selector': <Object?>[],
  'input_type': AssignerNodeInputType.variable,
  'operation': WriteMode.overwrite,
  'value': <Object?>[],
};

void main() {
  group('assigner/operation-selector', () {
    testWidgets('shows numeric write modes and emits the selected operation', (t) async {
      final selected = <OperationItem>[];
      await renderOperationSelector(t, onSelect: selected.add);

      await tapText(t, op('over-write'));

      expect(find.text(op('title').toUpperCase()), findsOneWidget);
      expect(find.text(op('clear')), findsOneWidget);
      expect(find.text(op('set')), findsOneWidget);
      expect(find.text(op('+=')), findsOneWidget);

      await tapText(t, op('+='));

      expect(selected, [(value: WriteMode.increment, name: WriteMode.increment)]);
    });

    testWidgets('does not open when the selector is disabled', (t) async {
      await renderOperationSelector(
        t,
        onSelect: (_) {},
        disabled: true,
        assignedVarType: VarType.string,
        writeModeTypes: const [WriteMode.overwrite],
        writeModeTypesArr: null,
        writeModeTypesNum: null,
      );

      await tapText(t, op('over-write'));

      expect(find.text(op('title').toUpperCase()), findsNothing);
    });
  });

  group('assigner/var-list', () {
    testWidgets('renders the empty placeholder when no operations are configured', (t) async {
      await renderVarList(t);

      expect(find.text('workflow.nodes.assigner.noVarTip'), findsOneWidget);
    });

    testWidgets('switches a boolean assignment to constant mode and updates the selected value', (t) async {
      final calls = await renderVarList(
        t,
        list: [opA()],
        assignedType: VarType.boolean,
        toAssignedType: VarType.boolean,
      );

      await tapText(t, op('over-write'));
      await tapText(t, op('set'));

      expect(calls.last.$1, [
        opA({'operation': WriteMode.set, 'input_type': AssignerNodeInputType.constant, 'value': false}),
      ]);

      await renderVarList(
        t,
        list: [
          opA({'operation': WriteMode.set, 'input_type': AssignerNodeInputType.constant, 'value': false}),
        ],
        assignedType: VarType.boolean,
        toAssignedType: VarType.boolean,
        calls: calls,
      );

      await tapText(t, 'True');

      expect(calls.last.$1, [
        opA({'operation': WriteMode.set, 'input_type': AssignerNodeInputType.constant, 'value': true}),
      ]);
    });

    testWidgets('opens the assigned-variable picker and removes an operation', (t) async {
      final calls = await renderVarList(t, list: [opA()]);

      await t.tap(find.byType(VarReferencePicker).first);
      await settle(t);
      expect(calls.opens, [0]);
      await t.tapAt(Offset.zero);
      await settle(t);

      await t.tap(buttonNamed('common.operation.remove'));
      await settle(t);

      expect(calls.last.$1, isEmpty);
    });
  });

  group('assigner/var-list branches', () {
    testWidgets('resets operation metadata when the assigned variable changes', (t) async {
      final calls = await renderVarList(
        t,
        list: [
          opA({'operation': WriteMode.set, 'input_type': AssignerNodeInputType.constant, 'value': 'stale'}),
        ],
      );

      await t.tap(find.byType(VarReferencePicker).first);
      await settle(t);
      await tapText(t, 'total');

      expect(calls.opens, [0]);
      expectCall(calls, (
        [
          opA({
            'variable_selector': ['node-b', 'total'],
            'operation': WriteMode.overwrite,
            'input_type': AssignerNodeInputType.variable,
            'value': null,
          }),
        ],
        ['node-b', 'total'],
      ));
    });

    testWidgets('switches back to variable mode when the selected operation no longer requires a constant', (t) async {
      final calls = await renderVarList(
        t,
        list: [
          opA({'operation': WriteMode.set, 'input_type': AssignerNodeInputType.constant, 'value': 'hello'}),
        ],
      );

      await tapText(t, op('set'));
      await tapText(t, op('over-write'));

      expectCall(calls, (
        [
          opA({'operation': WriteMode.overwrite, 'input_type': AssignerNodeInputType.variable, 'value': ''}),
        ],
        null,
      ));
    });

    testWidgets('updates string and number constant inputs through the inline editors', (t) async {
      final setOp = {'operation': WriteMode.set, 'input_type': AssignerNodeInputType.constant};
      final calls = await renderVarList(
        t,
        list: [
          opA({...setOp, 'value': 1}),
        ],
        assignedType: VarType.number,
        toAssignedType: VarType.number,
      );

      await t.enterText(find.byType(TextField), '2');
      await settle(t);

      expectCall(calls, (
        [
          opA({...setOp, 'value': 2}),
        ],
        2,
      ));

      await renderVarList(
        t,
        list: [
          opA({...setOp, 'value': 'hello'}),
        ],
        calls: calls,
      );

      await t.enterText(find.byType(TextField), 'updated');
      await settle(t);

      expectCall(calls, (
        [
          opA({...setOp, 'value': 'updated'}),
        ],
        'updated',
      ));
    });

    testWidgets('updates numeric write-mode inputs through the dedicated number field', (t) async {
      final calls = await renderVarList(
        t,
        list: [
          opA({'operation': WriteMode.increment, 'value': 2}),
        ],
        assignedType: VarType.number,
        toAssignedType: VarType.number,
      );

      await t.enterText(find.byType(TextField), '5');
      await settle(t);

      expectCall(calls, (
        [
          opA({'operation': WriteMode.increment, 'value': 5}),
        ],
        5,
      ));
    });
  });

  group('assigner/node', () {
    testWidgets('renders the empty-state hint when no assignable variable is configured', (t) async {
      await renderCard(
        t,
        v2([
          createOperation({'variable_selector': <Object?>[]}),
        ]),
      );

      expect(find.text('Variable NOT Set'), findsOneWidget);
    });

    testWidgets('renders both version 2 and legacy previews with resolved node labels', (t) async {
      await renderCard(t, v2([createOperation()]));

      expectLabel('Answer', 'count');
      expect(find.text('OVERWRITE'), findsOneWidget);

      await renderCard(t, legacy(['sys', 'query'], WriteMode.append));

      expectLabel('Start', 'query');
      expect(find.text('APPEND'), findsOneWidget);

      await renderCard(t, legacy([], WriteMode.append));

      expect(find.byType(Text), findsNothing);
    });

    testWidgets('skips empty v2 operations and resolves system variables through the start node', (t) async {
      await renderCard(
        t,
        v2([
          createOperation({'variable_selector': <Object?>[]}),
          createOperation({
            'variable_selector': ['sys', 'query'],
            'operation': WriteMode.append,
          }),
        ]),
      );

      expectLabel('Start', 'query');
      expect(find.text('Variable NOT Set'), findsNothing);
    });
  });

  group('assigner/panel', () {
    testWidgets(
      'passes the resolved config to the variable list and appends operations through the add button',
      (t) async {
        final p = await openAssigner(t);

        expect(find.text('workflow.nodes.assigner.variables'.toUpperCase()), findsOneWidget);
        expect(find.text('count'), findsOneWidget);
        final list = t.widget<AssignerVarList>(find.byType(AssignerVarList));
        expect(list.readonly, isFalse);
        expect(list.list, [createOperation()]);

        await t.tap(buttonNamed('common.operation.add'));
        await settle(t);

        expect(p.data['version'], '2');
        expect(p.data['items'], [createOperation(), _blank]);

        await t.tap(find.text('count'));
        await settle(t);
        await tapText(t, 'updated');

        expect((p.data['items']! as List).first, {
          ...createOperation({
            'variable_selector': ['node-1', 'updated'],
          }),
          'value': <Object?>[],
        });
        await p.dispose(t);
      },
    );
  });

  group('assigner path', () {
    group('Path Integration', () {
      testWidgets('should open the operation selector and choose number operations', (t) async {
        final selected = <OperationItem>[];
        await renderOperationSelector(t, onSelect: selected.add);

        await tapText(t, op('over-write'));
        expect(find.text(op('clear')), findsOneWidget);
        expect(find.text(op('set')), findsOneWidget);
        expect(find.text(op('+=')), findsOneWidget);

        await tapText(t, op('+='));
        expect(selected, [(value: WriteMode.increment, name: WriteMode.increment)]);
      });

      testWidgets('should not open a disabled operation selector', (t) async {
        await renderOperationSelector(
          t,
          onSelect: (_) {},
          disabled: true,
          assignedVarType: VarType.string,
          writeModeTypes: const [WriteMode.overwrite],
          writeModeTypesArr: null,
          writeModeTypesNum: null,
        );

        await tapText(t, op('over-write'));
        expect(find.text(op('title').toUpperCase()), findsNothing);
      });

      testWidgets('should render empty and populated variable lists across constant editors', (t) async {
        final calls = await renderVarList(t, writeModeTypesNum: writeModeTypesNum);
        expect(find.text('workflow.nodes.assigner.noVarTip'), findsOneWidget);

        Future<void> rerender(Map<String, Object?> item, String type) => renderVarList(
          t,
          list: [item],
          assignedType: type,
          toAssignedType: type,
          writeModeTypesNum: writeModeTypesNum,
          calls: calls,
        );

        await rerender(createOperation({'variable_selector': <Object?>[], 'value': <Object?>[]}), VarType.string);
        await tapText(t, 'workflow.nodes.assigner.selectAssignedVariable');
        await tapText(t, 'count');
        expect(calls.opens, [0]);
        expectCall(calls, (
          [
            {
              'variable_selector': ['node-1', 'count'],
              'operation': WriteMode.overwrite,
              'input_type': AssignerNodeInputType.variable,
              'value': null,
            },
          ],
          ['node-1', 'count'],
        ));

        // The to-assign picker leaves out the assigned variable itself.
        await rerender(createOperation(), VarType.boolean);
        final filter = picker(t, 'toAssigned').filterVar!;
        expect(filter(const PickerVar('count', 'string'), ['node-1', 'count']), isFalse);
        expect(filter(const PickerVar('other', 'string'), ['node-2', 'other']), isTrue);
        await tapText(t, op('over-write'));
        await tapText(t, op('set'));
        expect(calls.last.$1, [
          createOperation({'operation': WriteMode.set, 'input_type': AssignerNodeInputType.constant, 'value': false}),
        ]);

        await t.tap(find.text('result'));
        await settle(t);
        await tapText(t, 'other');
        expectCall(calls, (
          [
            createOperation({
              'value': ['node-2', 'other'],
            }),
          ],
          ['node-2', 'other'],
        ));

        final setOp = {'operation': WriteMode.set};
        await rerender(createOperation({...setOp, 'value': 'hello'}), VarType.string);
        await t.enterText(find.byType(TextField), 'updated text');
        await settle(t);
        expectCall(calls, (
          [
            createOperation({...setOp, 'value': 'updated text'}),
          ],
          'updated text',
        ));

        await rerender(createOperation({...setOp, 'value': 3}), VarType.number);
        expect(find.text('3'), findsOneWidget);
        await t.enterText(find.byType(TextField), '5');
        await settle(t);
        expectCall(calls, (
          [
            createOperation({...setOp, 'value': 5}),
          ],
          5,
        ));

        await rerender(createOperation({...setOp, 'value': false}), VarType.boolean);
        await tapText(t, 'True');
        expectCall(calls, (
          [
            createOperation({...setOp, 'value': true}),
          ],
          true,
        ));

        await rerender(createOperation({...setOp, 'value': '{"a":1}'}), VarType.object);
        t.widget<DifyCodeEditor>(find.byType(DifyCodeEditor)).onChange!('{"a":2}');
        expectCall(calls, (
          [
            createOperation({...setOp, 'value': '{"a":2}'}),
          ],
          '{"a":2}',
        ));

        await rerender(createOperation({'operation': WriteMode.increment, 'value': 2}), VarType.number);
        expect(find.text('2'), findsOneWidget);
        await t.enterText(find.byType(TextField), '4');
        await settle(t);
        expectCall(calls, (
          [
            createOperation({'operation': WriteMode.increment, 'value': 4}),
          ],
          4,
        ));

        await t.tap(buttonNamed('common.operation.remove'));
        await settle(t);
        expect(calls.last.$1, isEmpty);
      });

      testWidgets('should render version 2 and legacy node previews', (t) async {
        await renderCard(
          t,
          v2([
            createOperation({'variable_selector': <Object?>[]}),
          ]),
        );
        expect(find.text('Variable NOT Set'), findsOneWidget);

        await renderCard(t, v2([createOperation()]));
        expectLabel('Answer', 'count');
        expect(find.text('OVERWRITE'), findsOneWidget);

        await renderCard(t, legacy(['sys', 'query'], WriteMode.append));
        expectLabel('Start', 'query');
        expect(find.text('APPEND'), findsOneWidget);
      });

      testWidgets('should skip empty version 2 items and resolve system variables without an operation badge', (
        t,
      ) async {
        await renderCard(
          t,
          v2([
            createOperation({'variable_selector': <Object?>[]}),
            {
              ...createOperation({
                'variable_selector': ['sys', 'query'],
              }),
            }..remove('operation'),
          ]),
        );

        expectLabel('Start', 'query');
        expect(find.text('OVERWRITE'), findsNothing);
      });

      testWidgets(
        'should return null for legacy nodes without assigned variables and resolve non-system legacy vars',
        (t) async {
          await renderCard(t, legacy([], WriteMode.append));
          expect(find.text('APPEND'), findsNothing);
          expect(find.text('count'), findsNothing);

          await renderCard(t, legacy(['node-1', 'count'], WriteMode.append));
          expectLabel('Answer', 'count');
          expect(find.text('APPEND'), findsOneWidget);
        },
      );

      testWidgets('should add panel operations with the real variable list inside the panel', (t) async {
        final p = await openAssigner(t);

        await t.tap(buttonNamed('common.operation.add'));
        await settle(t);

        expect(p.data['items'], [createOperation(), _blank]);
        expect(find.text('workflow.nodes.assigner.variables'.toUpperCase()), findsOneWidget);
        expect(find.text('count'), findsOneWidget);
        await p.dispose(t);
      });
    });
  });
}
