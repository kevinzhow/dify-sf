// dify-spec: web/app/components/workflow/__tests__/trigger-status-sync.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Dify mocks `isTriggerNode`; each test sets it.
bool Function(String nodeType) isTriggerNode = (_) => true;

/// Like BaseNode: a trigger node shows its stored status, any other node 'enabled'.
class TestTriggerNode extends StatelessWidget {
  const TestTriggerNode({super.key, required this.nodeId, required this.nodeType, this.testId});
  final String nodeId, nodeType;
  final String? testId;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: WorkflowStoreScope.of(context).triggerStatus.triggerStatuses,
    builder: (context, statuses, _) {
      final status = isTriggerNode(nodeType) ? (statuses[nodeId] ?? EntryNodeStatus.disabled) : EntryNodeStatus.enabled;
      return Text(status.name, key: ValueKey(testId ?? 'node-$nodeId'));
    },
  );
}

/// Like TriggerCard: toggles and batch-updates statuses.
class TestTriggerController extends StatelessWidget {
  const TestTriggerController({super.key});

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context).triggerStatus;
    void handleToggle(String nodeId, bool enabled) =>
        store.setTriggerStatus(nodeId, enabled ? EntryNodeStatus.enabled : EntryNodeStatus.disabled);
    Widget button(String testId, String label, VoidCallback onTap) =>
        GestureDetector(key: ValueKey(testId), onTap: onTap, child: Text(label));
    return Column(
      children: [
        button('toggle-node-1', 'Enable Node 1', () => handleToggle('node-1', true)),
        button('toggle-node-2', 'Disable Node 2', () => handleToggle('node-2', false)),
        button(
          'batch-update',
          'Batch Update',
          () => store.setTriggerStatuses({
            'node-1': EntryNodeStatus.disabled,
            'node-2': EntryNodeStatus.enabled,
            'node-3': EntryNodeStatus.enabled,
          }),
        ),
      ],
    );
  }
}

void main() {
  late WorkflowStore workflowStore;
  setUp(() {
    workflowStore = WorkflowStore();
    isTriggerNode = (_) => true;
  });
  tearDown(() => workflowStore.dispose());

  Future<void> render(WidgetTester t, List<Widget> children) => t.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: WorkflowStoreScope(
        store: workflowStore,
        child: Column(children: children),
      ),
    ),
  );

  String status(WidgetTester t, String testId) => t.widget<Text>(find.byKey(ValueKey(testId))).data!;

  Future<void> click(WidgetTester t, String testId) => t.tap(find.byKey(ValueKey(testId)));

  group('Trigger Status Synchronization Integration', () {
    group('Real-time Status Synchronization', () {
      testWidgets('should sync status changes between trigger controller and nodes', (t) async {
        await render(t, const [
          TestTriggerController(),
          TestTriggerNode(nodeId: 'node-1', nodeType: 'trigger-webhook'),
          TestTriggerNode(nodeId: 'node-2', nodeType: 'trigger-schedule'),
        ]);

        expect(status(t, 'node-node-1'), 'disabled');
        expect(status(t, 'node-node-2'), 'disabled');

        await click(t, 'toggle-node-1');
        await t.pump();

        expect(status(t, 'node-node-1'), 'enabled');
        expect(status(t, 'node-node-2'), 'disabled');

        await click(t, 'toggle-node-2');
        await t.pump();

        expect(status(t, 'node-node-1'), 'enabled');
        expect(status(t, 'node-node-2'), 'disabled');
      });

      testWidgets('should handle batch status updates correctly', (t) async {
        await render(t, const [
          TestTriggerController(),
          TestTriggerNode(nodeId: 'node-1', nodeType: 'trigger-webhook'),
          TestTriggerNode(nodeId: 'node-2', nodeType: 'trigger-schedule'),
          TestTriggerNode(nodeId: 'node-3', nodeType: 'trigger-plugin'),
        ]);

        expect(status(t, 'node-node-1'), 'disabled');
        expect(status(t, 'node-node-2'), 'disabled');
        expect(status(t, 'node-node-3'), 'disabled');

        await click(t, 'batch-update');
        await t.pump();

        expect(status(t, 'node-node-1'), 'disabled');
        expect(status(t, 'node-node-2'), 'enabled');
        expect(status(t, 'node-node-3'), 'enabled');
      });

      testWidgets('should handle mixed node types (trigger vs non-trigger)', (t) async {
        isTriggerNode = (nodeType) => nodeType.startsWith('trigger-');
        await render(t, const [
          TestTriggerController(),
          TestTriggerNode(nodeId: 'node-1', nodeType: 'trigger-webhook'),
          TestTriggerNode(nodeId: 'node-2', nodeType: 'start'),
          TestTriggerNode(nodeId: 'node-3', nodeType: 'llm'),
        ]);

        expect(status(t, 'node-node-1'), 'disabled');
        expect(status(t, 'node-node-2'), 'enabled');
        expect(status(t, 'node-node-3'), 'enabled');

        await click(t, 'toggle-node-1');
        await t.pump();

        expect(status(t, 'node-node-1'), 'enabled');
        expect(status(t, 'node-node-2'), 'enabled');
        expect(status(t, 'node-node-3'), 'enabled');
      });
    });

    group('Store State Management', () {
      testWidgets('should maintain state consistency across multiple components', (t) async {
        await render(t, const [
          TestTriggerController(),
          TestTriggerNode(nodeId: 'shared-node', nodeType: 'trigger-webhook'),
        ]);

        await click(t, 'toggle-node-1'); // updates node-1, not shared-node
        await t.pump();

        await render(t, const [
          TestTriggerController(),
          TestTriggerNode(nodeId: 'shared-node', nodeType: 'trigger-webhook'),
          TestTriggerNode(nodeId: 'shared-node', nodeType: 'trigger-webhook'),
        ]);

        final nodes = find.byKey(const ValueKey('node-shared-node'));
        expect(nodes, findsNWidgets(2));
        for (final text in t.widgetList<Text>(nodes)) {
          expect(text.data, 'disabled');
        }
      });

      testWidgets('should handle rapid status changes correctly', (t) async {
        await render(t, const [
          TestTriggerController(),
          TestTriggerNode(nodeId: 'node-1', nodeType: 'trigger-webhook'),
        ]);

        await click(t, 'toggle-node-1');
        await click(t, 'toggle-node-2');
        await click(t, 'toggle-node-1');
        await t.pump();

        expect(status(t, 'node-node-1'), 'enabled');
      });
    });

    group('Error Scenarios', () {
      testWidgets('should handle non-existent node IDs gracefully', (t) async {
        await render(t, const [TestTriggerNode(nodeId: 'non-existent-node', nodeType: 'trigger-webhook')]);

        expect(status(t, 'node-non-existent-node'), 'disabled');
      });

      testWidgets('should handle component unmounting gracefully', (t) async {
        await render(t, const [
          TestTriggerController(),
          TestTriggerNode(nodeId: 'node-1', nodeType: 'trigger-webhook'),
        ]);

        await click(t, 'toggle-node-1');
        await t.pump();

        await t.pumpWidget(const SizedBox());
        expect(t.takeException(), isNull);

        expect(workflowStore.triggerStatus.triggerStatuses.value['node-1'], EntryNodeStatus.enabled);
      });
    });

    group('Performance Optimization', () {
      testWidgets('should work correctly with optimized selector using useCallback', (t) async {
        isTriggerNode = (nodeType) => nodeType == 'trigger-webhook';
        await render(t, const [
          TestTriggerNode(nodeId: 'node-1', nodeType: 'trigger-webhook', testId: 'optimized-node-node-1'),
          TestTriggerNode(nodeId: 'node-2', nodeType: 'start', testId: 'optimized-node-node-2'),
          TestTriggerController(),
        ]);

        expect(status(t, 'optimized-node-node-1'), 'disabled');
        expect(status(t, 'optimized-node-node-2'), 'enabled');

        await click(t, 'toggle-node-1');
        await t.pump();

        expect(status(t, 'optimized-node-node-1'), 'enabled');
        expect(status(t, 'optimized-node-node-2'), 'enabled');
      });

      testWidgets('should handle selector dependency changes correctly', (t) async {
        isTriggerNode = (nodeType) => nodeType == 'trigger-webhook';
        Widget testComponent(String nodeType) =>
            TestTriggerNode(nodeId: 'test-node', nodeType: nodeType, testId: 'test-component');

        await render(t, [testComponent('trigger-webhook')]);
        expect(status(t, 'test-component'), 'disabled');

        workflowStore.triggerStatus.setTriggerStatus('test-node', EntryNodeStatus.enabled);
        await t.pump();
        expect(status(t, 'test-component'), 'enabled');

        await render(t, [testComponent('start')]);
        expect(status(t, 'test-component'), 'enabled');
      });
    });
  });
}
