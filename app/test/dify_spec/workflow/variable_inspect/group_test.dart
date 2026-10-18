// dify-spec: web/app/components/workflow/variable-inspect/__tests__/group.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/inspect_vars.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import 'inspect_harness.dart';

DifyJson createVar([DifyJson overrides = const {}]) => createVariable({
  'name': 'message',
  'selector': ['node-1', 'message'],
  'value': 'hello',
  ...overrides,
});

void main() {
  setUp(useDifyTestTranslator);

  group('VariableInspect Group', () {
    testWidgets('should mask secret environment variables before selecting them', (t) async {
      final selected = <DifyJson>[];
      await InspectHarness().pump(
        t,
        InspectGroup(
          varType: VarInInspectType.environment,
          varList: [
            createVar({
              'id': 'env-secret',
              'type': VarInInspectType.environment,
              'name': 'API_KEY',
              'value_type': 'secret',
              'value': 'plain-secret',
            }),
          ],
          handleSelect: selected.add,
        ),
      );

      await t.tap(find.text('API_KEY'));

      expect(find.text('WORKFLOW.DEBUG.VARIABLEINSPECT.ENVNODE'), findsOneWidget);
      expect(selected.single, containsPair('id', 'env-secret'));
      expect(selected.single, containsPair('type', VarInInspectType.environment));
      expect(selected.single, containsPair('value', '******************'));
    });

    testWidgets('should hide invisible variables and collapse the list when the group header is clicked', (t) async {
      await InspectHarness().pump(
        t,
        InspectGroup(
          nodeData: createNodeWithVar(),
          varType: VarInInspectType.node,
          varList: [
            createVar({'id': 'visible-var', 'name': 'visible_var'}),
            createVar({'id': 'hidden-var', 'name': 'hidden_var', 'visible': false}),
          ],
          handleSelect: (_) {},
        ),
      );

      expect(find.text('visible_var'), findsOneWidget);
      expect(find.text('hidden_var'), findsNothing);

      await t.tap(pressable('Code'));
      await t.pump();

      expect(find.text('visible_var'), findsNothing);
    });

    testWidgets('should expose node view and clear actions for node groups', (t) async {
      var views = 0, clears = 0;
      await InspectHarness().pump(
        t,
        InspectGroup(
          nodeData: createNodeWithVar(),
          varType: VarInInspectType.node,
          varList: [createVar()],
          handleSelect: (_) {},
          handleView: () => views++,
          handleClear: () => clears++,
        ),
      );
      // `group-hover:flex`: the actions show while the pointer is over the group.
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: t.getCenter(pressable('Code')));
      await t.pump();

      await t.tap(pressable('workflow.debug.variableInspect.view'));
      await t.tap(pressable('workflow.debug.variableInspect.clearNode'));

      expect(views, 1);
      expect(clears, 1);
      await mouse.removePointer();
    });
  });
}
