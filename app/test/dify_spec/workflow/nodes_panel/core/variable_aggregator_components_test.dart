// dify-spec: web/app/components/workflow/nodes/variable-assigner/components/__tests__/var-group-item.spec.tsx
// dify-spec: web/app/components/workflow/nodes/variable-assigner/components/__tests__/var-group-item.branches.spec.tsx
// dify-spec: web/app/components/workflow/nodes/variable-assigner/components/var-list/__tests__/index.spec.tsx
//
// Where Dify mocks the picker or the nested list, the widget's callbacks are called the way the mock's buttons do.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/variable_aggregator_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'variable_aggregator_helpers.dart';

typedef Json = Map<String, Object?>;

Json createPayload([Json overrides = const {}]) => {
  'group_name': 'Group_A',
  'output_type': 'any',
  'variables': <Object?>[],
  ...overrides,
};

Future<List<Json>> renderGroupItem(
  WidgetTester t, {
  Json? payload,
  ValueChanged<String>? onGroupNameChange,
  bool canRemove = false,
  VoidCallback? onRemove,
  ValueChanged<String>? onError,
}) async {
  final changes = <Json>[];
  await renderWidget(
    t,
    VarGroupItem(
      readOnly: false,
      payload: payload ?? createPayload(),
      onChange: changes.add,
      groupEnabled: true,
      scope: const VarScope(),
      addScope: const VarScope(),
      onGroupNameChange: onGroupNameChange,
      canRemove: canRemove,
      onRemove: onRemove,
      onError: onError,
    ),
  );
  return changes;
}

VarReferencePicker addPicker(WidgetTester t) =>
    t.widget<VarReferencePicker>(find.byWidgetPredicate((w) => w is VarReferencePicker && w.isAddBtnTrigger));

void main() {
  group('variable-assigner/var-group-item', () {
    testWidgets('renders the empty group and forwards group-name edits', (t) async {
      final names = <String>[];
      await renderGroupItem(t, onGroupNameChange: names.add);
      expect(find.text('workflow.nodes.variableAssigner.noVarTip'), findsOneWidget);
      await t.tap(find.text('Group_A'));
      await t.pump();
      await t.enterText(find.byType(TextField), 'Next_Group');
      expect(names, ['Next_Group']);
    });

    testWidgets('rejects invalid group names and forwards remove actions', (t) async {
      final errors = <String>[];
      var removed = 0;
      await renderGroupItem(
        t,
        onGroupNameChange: (_) {},
        canRemove: true,
        onRemove: () => removed++,
        onError: errors.add,
      );
      await t.tap(find.text('Group_A'));
      await t.pump();
      await t.enterText(find.byType(TextField), '1bad');
      expect(errors, isNotEmpty);

      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: t.getCenter(find.byType(TextField)));
      addTearDown(mouse.removePointer);
      await t.pump();
      await t.tap(buttonNamed('common.operation.remove'));
      expect(removed, 1);
    });
  });

  group('variable-assigner/var-group-item branches', () {
    testWidgets('adds a new typed variable and exposes permissive filtering when output type is any', (t) async {
      final changes = await renderGroupItem(t);
      final filterVar = addPicker(t).filterVar!;
      expect(filterVar(const PickerVar('answer', 'string'), const []), isTrue);
      expect(filterVar(const PickerVar('flag', 'boolean'), const []), isTrue);
      addPicker(t).onChange(['node-a', 'answer'], const PickerVar('answer', 'string'));
      expect(changes.single['variables'], [
        ['node-a', 'answer'],
      ]);
      expect(changes.single['output_type'], 'string');
    });

    testWidgets('ignores duplicate additions and only accepts matching types when the output type is fixed', (t) async {
      final changes = await renderGroupItem(
        t,
        payload: createPayload({
          'output_type': 'string',
          'variables': [
            ['node-a', 'answer'],
          ],
        }),
      );
      final filterVar = addPicker(t).filterVar!;
      expect(filterVar(const PickerVar('answer', 'string'), const []), isTrue);
      expect(filterVar(const PickerVar('flag', 'boolean'), const []), isFalse);
      addPicker(t).onChange(['node-a', 'answer'], const PickerVar('answer', 'string'));
      expect(changes, isEmpty);
    });

    testWidgets('ignores duplicate replacements from the nested variable list', (t) async {
      final changes = await renderGroupItem(
        t,
        payload: createPayload({
          'output_type': 'string',
          'variables': [
            ['node-a', 'answer'],
            ['node-a', 'flag'],
          ],
        }),
      );
      t
          .widget<AggregatorVarList>(find.byType(AggregatorVarList))
          .onChange(
            [
              ['node-a', 'flag'],
              ['node-a', 'flag'],
            ],
            ['node-a', 'flag'],
          );
      expect(changes, isEmpty);
    });

    testWidgets('resets the output type to any when the nested variable list becomes empty', (t) async {
      final changes = await renderGroupItem(
        t,
        payload: createPayload({
          'output_type': 'string',
          'variables': [
            ['node-a', 'answer'],
          ],
        }),
      );
      t.widget<AggregatorVarList>(find.byType(AggregatorVarList)).onChange([]);
      expect(changes.single['variables'], isEmpty);
      expect(changes.single['output_type'], 'any');
    });
  });

  group('variable-assigner/var-list', () {
    final sourceNode = difyNodes([
      difyNode('node-a', 'code', {
        'outputs': {
          'answer': {'type': 'string'},
        },
      }, 'Source Node'),
    ]).single;
    final scope = VarScope.of(beforeNodes: [sourceNode]);

    Future<(List<(List<List<String>>, List<String>?)>, List<int>)> renderVarList(
      WidgetTester t, {
      List<List<String>> list = const [],
    }) async {
      final changes = <(List<List<String>>, List<String>?)>[];
      final opens = <int>[];
      await renderWidget(
        t,
        AggregatorVarList(
          readonly: false,
          list: list,
          scope: scope,
          onChange: (l, [v]) => changes.add((l, v)),
          onOpen: opens.add,
        ),
      );
      return (changes, opens);
    }

    testWidgets('renders the empty placeholder when no variables are configured', (t) async {
      await renderVarList(t);
      expect(find.text('workflow.nodes.variableAssigner.noVarTip'), findsOneWidget);
    });

    testWidgets('opens the picker and removes an assigned variable', (t) async {
      final (changes, opens) = await renderVarList(
        t,
        list: [
          ['node-a', 'answer'],
        ],
      );
      await t.tap(find.text('answer'));
      await t.pumpAndSettle();
      expect(opens, [0]);
      await t.tapAt(const Offset(5, 5));
      await t.pumpAndSettle();
      await t.tap(buttonNamed('common.operation.remove'));
      expect(changes.last.$1, isEmpty);
      expect(changes.last.$2, isNull);
    });

    testWidgets('updates a selected variable through the reference picker', (t) async {
      final (changes, _) = await renderVarList(
        t,
        list: [
          ['node-a', 'answer'],
        ],
      );
      await t.tap(find.text('answer'));
      await t.pumpAndSettle();
      await t.tap(find.text('answer').last);
      await t.pumpAndSettle();
      expect(changes.last.$1, [
        ['node-a', 'answer'],
      ]);
      expect(changes.last.$2, ['node-a', 'answer']);
    });
  });
}
