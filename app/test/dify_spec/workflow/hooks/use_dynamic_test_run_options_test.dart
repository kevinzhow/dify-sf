// dify-spec: web/app/components/workflow/hooks/__tests__/use-dynamic-test-run-options.spec.tsx
//
// useDynamicTestRunOptions is testRunOptionsOf over the header's nodes. Its icons are drawn by the test run menu from
// each option's node type.
import 'package:dify_sf_app/src/workflow_editor/header/header_data.dart';
import 'package:dify_sf_app/src/workflow_editor/header/test_run_menu.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';

void main() {
  setUp(useDifyTestTranslator);

  group('useDynamicTestRunOptions', () {
    test('should build user input, trigger options, and a run-all option from workflow nodes', () {
      final result = testRunOptionsOf(const [
        HeaderNode(id: 'inset-s-1', type: 'start', title: 'User Input'),
        HeaderNode(id: 'schedule-1', type: 'trigger-schedule', title: 'Daily Schedule'),
        HeaderNode(id: 'webhook-1', type: 'trigger-webhook', title: 'Webhook Trigger'),
        HeaderNode(
          id: 'plugin-1',
          type: 'trigger-plugin',
          data: {'plugin_name': 'Plugin Trigger', 'provider_id': 'plugin-provider'},
        ),
      ]);

      final u = result.userInput!;
      expect(
        (u.id, u.type, u.name, u.nodeId, u.enabled),
        ('inset-s-1', TriggerType.userInput, 'User Input', 'inset-s-1', true),
      );
      expect(
        [for (final t in result.triggers) (t.id, t.type, t.name, t.nodeId)],
        [
          ('schedule-1', TriggerType.schedule, 'Daily Schedule', 'schedule-1'),
          ('webhook-1', TriggerType.webhook, 'Webhook Trigger', 'webhook-1'),
          ('plugin-1', TriggerType.plugin, 'Plugin Trigger', 'plugin-1'),
        ],
      );
      final all = result.runAll!;
      expect((all.id, all.type), ('run-all', TriggerType.all));
      expect(all.relatedNodeIds, ['schedule-1', 'webhook-1', 'plugin-1']);
    });

    test('should fall back to the workflow entry node and omit run-all when only one trigger exists', () {
      // Dify mocks getWorkflowEntryNode to return a Start node that is not among the nodes; the real entry node of a
      // graph without a Start node is its trigger, so no user input option is offered.
      final result = testRunOptionsOf(const [
        HeaderNode(id: 'webhook-1', type: 'trigger-webhook', title: 'Webhook Trigger'),
      ]);
      expect(result.userInput, isNull);
      expect(result.triggers, hasLength(1));
      expect(result.runAll, isNull);

      final untitled = testRunOptionsOf(const [HeaderNode(id: 'start', type: 'start')]);
      expect(untitled.userInput!.name, 'workflow.blocks.start');
    });
  });
}
