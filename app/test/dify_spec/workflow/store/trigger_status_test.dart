// dify-spec: web/app/components/workflow/store/__tests__/trigger-status.spec.ts
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

const enabled = EntryNodeStatus.enabled, disabled = EntryNodeStatus.disabled;

void main() {
  late TriggerStatusStore store;
  setUp(() => store = TriggerStatusStore());
  tearDown(() => store.dispose());

  group('useTriggerStatusStore', () {
    group('Initial State', () {
      test('should initialize with empty trigger statuses', () {
        expect(store.triggerStatuses.value, isEmpty);
      });

      test('should return "disabled" for non-existent trigger status', () {
        expect(store.getTriggerStatus('non-existent-id'), disabled);
      });
    });

    group('setTriggerStatus', () {
      test('should set trigger status for a single node', () {
        store.setTriggerStatus('node-1', enabled);

        expect(store.triggerStatuses.value['node-1'], enabled);
        expect(store.getTriggerStatus('node-1'), enabled);
      });

      test('should update existing trigger status', () {
        store.setTriggerStatus('node-1', enabled);
        expect(store.getTriggerStatus('node-1'), enabled);

        store.setTriggerStatus('node-1', disabled);
        expect(store.getTriggerStatus('node-1'), disabled);
      });

      test('should handle multiple nodes independently', () {
        store.setTriggerStatus('node-1', enabled);
        store.setTriggerStatus('node-2', disabled);

        expect(store.getTriggerStatus('node-1'), enabled);
        expect(store.getTriggerStatus('node-2'), disabled);
      });
    });

    group('setTriggerStatuses', () {
      test('should set multiple trigger statuses at once', () {
        final statuses = {'node-1': enabled, 'node-2': disabled, 'node-3': enabled};

        store.setTriggerStatuses(statuses);

        expect(store.triggerStatuses.value, statuses);
        expect(store.getTriggerStatus('node-1'), enabled);
        expect(store.getTriggerStatus('node-2'), disabled);
        expect(store.getTriggerStatus('node-3'), enabled);
      });

      test('should replace existing statuses completely', () {
        store.setTriggerStatuses({'node-1': enabled, 'node-2': disabled});

        store.setTriggerStatuses({'node-3': enabled, 'node-4': disabled});

        expect(store.triggerStatuses.value, {'node-3': enabled, 'node-4': disabled});
        expect(store.getTriggerStatus('node-1'), disabled);
        expect(store.getTriggerStatus('node-2'), disabled);
      });

      test('should handle empty object', () {
        store.setTriggerStatus('node-1', enabled);

        store.setTriggerStatuses({});

        expect(store.triggerStatuses.value, isEmpty);
        expect(store.getTriggerStatus('node-1'), disabled);
      });
    });

    group('getTriggerStatus', () {
      test('should return the correct status for existing nodes', () {
        store.setTriggerStatuses({'enabled-node': enabled, 'disabled-node': disabled});

        expect(store.getTriggerStatus('enabled-node'), enabled);
        expect(store.getTriggerStatus('disabled-node'), disabled);
      });

      test('should return "disabled" as default for non-existent nodes', () {
        expect(store.getTriggerStatus('non-existent'), disabled);
        expect(store.getTriggerStatus(''), disabled);
        expect(store.getTriggerStatus('undefined-node'), disabled);
      });
    });

    group('clearTriggerStatuses', () {
      test('should clear all trigger statuses', () {
        store.setTriggerStatuses({'node-1': enabled, 'node-2': disabled, 'node-3': enabled});
        expect(store.triggerStatuses.value.keys, hasLength(3));

        store.clearTriggerStatuses();

        expect(store.triggerStatuses.value, isEmpty);
        expect(store.getTriggerStatus('node-1'), disabled);
        expect(store.getTriggerStatus('node-2'), disabled);
        expect(store.getTriggerStatus('node-3'), disabled);
      });

      test('should not throw when clearing empty statuses', () {
        expect(store.clearTriggerStatuses, returnsNormally);
        expect(store.triggerStatuses.value, isEmpty);
      });
    });

    group('Store Reactivity', () {
      test('should notify subscribers when status changes', () {
        final initialTriggerStatuses = store.triggerStatuses.value;
        var notified = 0;
        store.triggerStatuses.addListener(() => notified++);

        store.setTriggerStatus('reactive-node', enabled);

        expect(store.triggerStatuses.value, isNot(same(initialTriggerStatuses)));
        expect(store.triggerStatuses.value['reactive-node'], enabled);
        expect(notified, 1);
      });

      test('should maintain immutability when updating statuses', () {
        store.setTriggerStatus('node-1', enabled);
        final firstSnapshot = store.triggerStatuses.value;

        store.setTriggerStatus('node-2', disabled);
        final secondSnapshot = store.triggerStatuses.value;

        expect(firstSnapshot, isNot(same(secondSnapshot)));
        expect(secondSnapshot['node-1'], enabled);
        expect(secondSnapshot['node-2'], disabled);
      });
    });

    group('Edge Cases', () {
      test('should handle rapid consecutive updates', () {
        store.setTriggerStatus('rapid-node', enabled);
        store.setTriggerStatus('rapid-node', disabled);
        store.setTriggerStatus('rapid-node', enabled);

        expect(store.getTriggerStatus('rapid-node'), enabled);
      });

      test('should handle setting the same status multiple times', () {
        store.setTriggerStatus('same-node', enabled);
        final firstSnapshot = store.triggerStatuses.value;

        store.setTriggerStatus('same-node', enabled);
        final secondSnapshot = store.triggerStatuses.value;

        expect(store.getTriggerStatus('same-node'), enabled);
        expect(firstSnapshot, isNot(same(secondSnapshot)));
      });

      test('should handle special node ID formats', () {
        const specialNodeIds = [
          'node-with-dashes',
          'node_with_underscores',
          'nodeWithCamelCase',
          'node123',
          'node-123-abc',
        ];

        for (final (index, nodeId) in specialNodeIds.indexed) {
          store.setTriggerStatus(nodeId, index.isEven ? enabled : disabled);
        }

        for (final (index, nodeId) in specialNodeIds.indexed) {
          expect(store.getTriggerStatus(nodeId), index.isEven ? enabled : disabled);
        }
      });
    });
  });
}
