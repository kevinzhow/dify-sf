// dify-spec: web/app/components/workflow/variable-inspect/__tests__/panel.spec.tsx
// dify-spec: web/app/components/workflow/variable-inspect/__tests__/listening.spec.tsx
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/panel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'inspect_harness.dart';

void main() {
  setUp(useDifyTestTranslator);

  group('VariableInspect Panel', () {
    testWidgets('should render the listening state and stop the workflow on demand', (t) async {
      final h = InspectHarness();
      h.store
        ..setIsListening(true)
        ..setListeningTriggerType('trigger-webhook')
        ..setShowVariableInspectPanel(true);
      await h.pump(t, const InspectPanel());

      await t.tap(find.text('workflow.debug.variableInspect.listening.stopButton'));

      expect(find.text('workflow.debug.variableInspect.listening.title'), findsOneWidget);
      expect(h.stops, 1);

      await t.tap(pressable('common.operation.close'));
      expect(h.store.showVariableInspectPanel.value, isFalse);
    });

    testWidgets('should render the empty state and close the panel from the header action', (t) async {
      final h = InspectHarness()..store.setShowVariableInspectPanel(true);
      await h.pump(t, const InspectPanel());

      await t.tap(pressable('common.operation.close'));

      expect(find.text('workflow.debug.variableInspect.emptyTip'), findsOneWidget);
      expect(h.store.showVariableInspectPanel.value, isFalse);
    });

    testWidgets('should select an environment variable and show its details in the right panel', (t) async {
      final h = InspectHarness();
      h.store
        ..setEnvironmentVariables([
          {'id': 'env-1', 'name': 'API_KEY', 'value': 'env-value', 'value_type': 'string', 'description': ''},
        ])
        ..setBottomPanelWidth(560);
      // Room for the segmented control's untranslated labels.
      await h.pump(t, const InspectPanel(), width: 1300);

      await t.tap(find.text('API_KEY'));
      await t.pump();

      expect(find.text('API_KEY'), findsAtLeastNWidgets(2));
      expect(find.text('WORKFLOW.DEBUG.VARIABLEINSPECT.ENVNODE'), findsOneWidget);
      expect(find.text('string'), findsAtLeastNWidgets(1));
      expect(find.text('env-value'), findsOneWidget);
    });
  });

  group('variable inspect listening', () {
    testWidgets('renders the listening message and forwards the stop action', (t) async {
      var stops = 0;
      final h = InspectHarness(
        nodes: [
          Node(
            id: 'trigger-1',
            type: 'trigger-webhook',
            title: 'Webhook Trigger',
            config: {
              'title': Value.of('Webhook Trigger'),
              'webhook_debug_url': Value.of('https://example.com/debug'),
            },
          ),
        ],
      );
      h.store
        ..setListeningTriggerType('trigger-webhook')
        ..setListeningTriggerNodeId('trigger-1')
        ..setListeningTriggerNodeIds(const [])
        ..setListeningTriggerIsAll(false);
      await h.pump(t, Listening(onStop: () => stops++, message: 'Waiting for webhook payload'));

      expect(find.text('Waiting for webhook payload'), findsOneWidget);

      await t.tap(find.text('workflow.debug.variableInspect.listening.stopButton'));

      expect(stops, 1);
    });
  });
}
