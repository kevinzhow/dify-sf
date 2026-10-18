// dify-spec: web/app/components/workflow/variable-inspect/__tests__/trigger.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/trigger.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'inspect_harness.dart';

void main() {
  setUp(useDifyTestTranslator);

  group('VariableInspectTrigger', () {
    late RecordingServices services;
    late InspectHarness h;

    setUp(() {
      services = RecordingServices();
      h = InspectHarness(services: services);
    });

    Future<void> renderTrigger(WidgetTester t) =>
        h.pump(t, const Center(child: VariableInspectTrigger()), width: 1300, height: 100);

    testWidgets('should stay hidden when the variable-inspect panel is already open', (t) async {
      h.store.setShowVariableInspectPanel(true);
      await renderTrigger(t);

      expect(find.text('WORKFLOW.DEBUG.VARIABLEINSPECT.TRIGGER.NORMAL'), findsNothing);
    });

    testWidgets('should open the panel from the normal trigger state', (t) async {
      await renderTrigger(t);

      await t.tap(find.text('WORKFLOW.DEBUG.VARIABLEINSPECT.TRIGGER.NORMAL'));

      expect(h.store.showVariableInspectPanel.value, isTrue);
    });

    testWidgets('should block opening while the workflow is read only', (t) async {
      h.store.setIsRestoring(true);
      await renderTrigger(t);

      await t.tap(find.text('WORKFLOW.DEBUG.VARIABLEINSPECT.TRIGGER.NORMAL'));

      expect(h.store.showVariableInspectPanel.value, isFalse);
    });

    testWidgets('should clear cached variables and reset the focused node', (t) async {
      h.store
        ..setConversationVariables([
          {'id': 'conversation-var', 'name': 'result', 'value_type': 'string', 'value': 'cached', 'description': ''},
        ])
        ..setCurrentFocusNodeId('node-2');
      await renderTrigger(t);

      await t.tap(find.text('workflow.debug.variableInspect.trigger.clear'));
      await t.pump();

      expect(find.text('workflow.debug.variableInspect.trigger.cached'), findsOneWidget);
      expect(services.calls, ['deleteAll']);
      expect(h.store.currentFocusNodeId.value, '');
    });

    testWidgets('should show the running state and open the panel while running', (t) async {
      h.store.setWorkflowRunningData({
        'result': {'status': 'running'},
      });
      await renderTrigger(t);

      await t.tap(find.text('workflow.debug.variableInspect.trigger.running'));

      expect(find.text('workflow.debug.variableInspect.trigger.clear'), findsNothing);
      expect(h.store.showVariableInspectPanel.value, isTrue);
    });
  });
}
