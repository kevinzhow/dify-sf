import 'package:collab_client/collab_client.dart' show Node;
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart' show DifyBlurredBox;
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/resize_handle.dart';
import 'package:dify_sf_app/src/workflow_editor/operator/operator.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dify_spec/workflow/variable_inspect/inspect_harness.dart';
import 'support/app_fonts.dart';

String _tw(String key) => DifyI18n.tr('workflow', key);

void main() {
  testWidgets('the panel in the editor: opens from the trigger under the operator bar, resizes, closes', (t) async {
    await useAppFonts();
    SharedPreferences.setMockInitialValues({});
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final demo = DemoBackend(withBo: false);
    await t.pumpWidget(
      MaterialApp(
        home: EditorPage(backend: demo, docId: 'demo', clientId: 'me-abc123', journaled: false),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    final store = WorkflowStoreScope.of(t.element(find.byType(WorkflowOperator)));
    final barTop = t.getTopLeft(find.byType(UndoRedo)).dy;
    final closedHeight = store.bottomPanelHeight.value;

    final normal = find.text(_tw('debug.variableInspect.trigger.normal').toUpperCase());
    await t.tap(normal.evaluate().isNotEmpty ? normal : find.text(_tw('debug.variableInspect.trigger.cached')));
    await t.pump();
    await t.pump();

    // The panel opens under the bar (the trigger hides); the bar and the reported bottom height grow with it.
    expect(find.byType(InspectPanel), findsOneWidget);
    expect(normal, findsNothing);
    final height = store.variableInspectPanelHeight.value;
    expect(t.getTopLeft(find.byType(UndoRedo)).dy, closeTo(barTop - height - 4, 1));
    expect(store.bottomPanelHeight.value, closeTo(closedHeight + height + 4, 1));

    // Dragging the top edge up makes it taller.
    final drag = await t.startGesture(t.getCenter(find.byType(ResizeHandle)));
    await drag.moveBy(const Offset(0, -30));
    await drag.moveBy(const Offset(0, -30));
    await drag.up();
    await t.pump();
    expect(store.variableInspectPanelHeight.value, height + 60);

    await t.tap(
      find.descendant(of: find.byType(InspectPanel), matching: pressable(DifyI18n.tr('common', 'operation.close'))),
    );
    await t.pump();
    await t.pump();
    expect(find.byType(InspectPanel), findsNothing);
    expect(t.getTopLeft(find.byType(UndoRedo)).dy, closeTo(barTop, 1));

    await t.pumpWidget(const SizedBox());
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  });

  group('the panel', () {
    setUp(useDifyTestTranslator);

    testWidgets('shows the empty state when there is nothing to inspect', (t) async {
      final h = InspectHarness()..store.setShowVariableInspectPanel(true);
      await h.pump(t, const InspectPanel());

      expect(find.text('workflow.debug.variableInspect.emptyTip'), findsOneWidget);
      expect(find.byType(InspectLeft), findsNothing);
    });

    testWidgets('lists the store\'s environment and conversation variables, the system ones and each node\'s', (
      t,
    ) async {
      final h = InspectHarness(
        services: RecordingServices(
          systemVars: [
            for (final name in ['query', 'files', 'user_id'])
              createVariable({
                'id': 'sys-$name',
                'type': 'sys',
                'name': name,
                'selector': ['sys', name],
              }),
          ],
        ),
        nodes: const [Node(id: 'start-1', type: 'start', title: 'Start')],
      );
      h.store
        ..setEnvironmentVariables([
          {'id': 'env-1', 'name': 'API_KEY', 'value': 'abc', 'value_type': 'secret', 'description': ''},
        ])
        ..setConversationVariables([
          {'id': 'conv-1', 'name': 'memory', 'value': 'hi', 'value_type': 'string', 'description': ''},
        ])
        ..setBottomPanelWidth(1300)
        ..setNodesWithInspectVars([
          createNodeWithVar(
            nodeId: 'start-1',
            type: 'start',
            title: 'Start',
            vars: [
              createVariable({'name': 'q'}),
            ],
          ),
          createNodeWithVar(
            vars: [
              createVariable({'id': 'var-2', 'name': 'out'}),
            ],
          ),
        ]);
      await h.crud.invalidateSysVarValues();
      await h.pump(t, const InspectPanel(), width: 1300);

      for (final title in ['ENVNODE', 'CHATNODE', 'SYSTEMNODE']) {
        expect(find.text('WORKFLOW.DEBUG.VARIABLEINSPECT.$title'), findsOneWidget);
      }
      expect(find.text('START'), findsOneWidget);
      expect(find.text('CODE'), findsOneWidget);
      // `query` and `files` join the Start node's group; the other system variables have their own.
      for (final name in ['API_KEY', 'memory', 'user_id', 'q', 'query', 'files', 'out']) {
        expect(find.text(name), findsOneWidget, reason: name);
      }
      expect(
        t.getTopLeft(find.text('query')).dy,
        greaterThan(t.getTopLeft(find.text('START')).dy),
        reason: 'under Start',
      );
      expect(t.getTopLeft(find.text('query')).dy, lessThan(t.getTopLeft(find.text('CODE')).dy));

      // A secret's value is masked and not copied.
      await t.tap(find.text('API_KEY'));
      await t.pump();
      expect(find.text('******************'), findsOneWidget);
      expect(pressable('app-overview.overview.appInfo.embedded.copy'), findsNothing);
    });

    testWidgets('edits a node variable\'s JSON and resets it to the last run value', (t) async {
      final h = InspectHarness();
      h.store
        ..setBottomPanelWidth(1300)
        ..setNodesWithInspectVars([
          createNodeWithVar(
            vars: [
              createVariable({
                'name': 'payload',
                'value_type': 'object',
                'value': {'foo': 1},
              }),
            ],
          ),
        ]);
      await h.pump(t, const InspectPanel(), width: 1300);
      await t.tap(find.text('payload'));
      await t.pump();

      await t.enterText(find.byType(EditableText), '{"foo": 2}');
      await t.pump(const Duration(milliseconds: 600));

      DifyJson stored() => (h.store.nodesWithInspectVars.value.single['vars']! as List).single as DifyJson;
      expect(stored()['value'], {'foo': 2});
      expect(stored()['edited'], isTrue);
      expect(find.text('WORKFLOW.DEBUG.VARIABLEINSPECT.EDITED'), findsOneWidget);

      // Invalid JSON is not kept, and says why.
      await t.enterText(find.byType(EditableText), '{"foo": ');
      await t.pump(const Duration(milliseconds: 600));
      expect(stored()['value'], {'foo': 2});
      expect(find.text('Unexpected end of JSON input'), findsOneWidget);

      await t.tap(pressable('workflow.debug.variableInspect.reset'));
      await t.pump();
      expect(stored()['value'], {'foo': 1});
      expect(stored()['edited'], isFalse);
      expect(find.text('WORKFLOW.DEBUG.VARIABLEINSPECT.EDITED'), findsNothing);
    });

    testWidgets('edits a conversation variable\'s draft value, never its declaration', (t) async {
      final h = InspectHarness();
      final declaration = {'id': 'conv-1', 'name': 'memory', 'value': 'hi', 'value_type': 'string', 'description': ''};
      h.store
        ..setBottomPanelWidth(1300)
        ..setConversationVariables([declaration]);
      await h.pump(t, const InspectPanel(), width: 1300);
      await t.tap(find.text('memory'));
      await t.pump();

      await t.enterText(find.byType(TextField), 'bye');
      await t.pump(const Duration(milliseconds: 600));

      expect(h.crud.conversationEdits.value, {'conv-1': 'bye'});
      expect(h.store.conversationVariables.value, [declaration]);
      expect(h.crud.conversationVars.single, containsPair('edited', true));

      await t.tap(pressable('workflow.debug.variableInspect.resetConversationVar'));
      await t.pump();
      expect(h.crud.conversationEdits.value, isEmpty);
      expect(find.text('hi'), findsOneWidget);
    });

    testWidgets('below 488 px the list is a popup opened from the menu button', (t) async {
      final h = InspectHarness();
      h.store
        ..setBottomPanelWidth(440)
        ..setEnvironmentVariables([
          {'id': 'env-1', 'name': 'HOST', 'value': 'x', 'value_type': 'string', 'description': ''},
        ]);
      await h.pump(t, const InspectPanel(), width: 440);

      expect(t.getSize(find.ancestor(of: find.byType(InspectLeft), matching: find.byType(DifyBlurredBox))).width, 217);
      // A click beside the popup closes it; the menu button opens it again.
      await t.tapAt(t.getTopLeft(find.byType(InspectPanel)) + const Offset(400, 200));
      await t.pump();
      expect(find.byType(InspectLeft), findsNothing);
      await t.tap(pressable('workflow.debug.variableInspect.title'));
      await t.pump();
      expect(find.byType(InspectLeft), findsOneWidget);
    });
  });
}
