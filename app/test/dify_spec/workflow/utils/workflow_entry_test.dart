// dify-spec: web/app/components/workflow/utils/__tests__/workflow-entry.spec.ts
import 'package:dify_sf_app/src/cards/node_helpers.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/human_input_model.dart'
    show isTriggerWorkflow;
import 'package:flutter_test/flutter_test.dart';

typedef _N = ({String id, String type});

String? _entry(List<_N> nodes) => getWorkflowEntryNode(nodes, (n) => n.type)?.id;

void main() {
  group('getWorkflowEntryNode', () {
    test('should return the trigger node when present', () {
      expect(
        _entry([(id: 'start', type: 'start'), (id: 'trigger', type: 'trigger-webhook'), (id: 'code', type: 'code')]),
        'trigger',
      );
    });

    test('should return the start node when no trigger node exists', () {
      expect(_entry([(id: 'start', type: 'start'), (id: 'code', type: 'code')]), 'start');
    });

    test('should return undefined when no entry node exists', () {
      expect(_entry([(id: 'code', type: 'code')]), isNull);
    });

    test('should prefer trigger node over start node', () {
      expect(_entry([(id: 'start', type: 'start'), (id: 'schedule', type: 'trigger-schedule')]), 'schedule');
    });
  });

  group('isWorkflowEntryNode', () {
    test('should return true for Start', () {
      expect(isWorkflowEntryNode('start'), isTrue);
    });

    for (final type in ['trigger-schedule', 'trigger-webhook', 'trigger-plugin']) {
      test('should return true for %s', () {
        expect(isWorkflowEntryNode(type), isTrue);
      });
    }

    test('should return false for non-entry types', () {
      expect(isWorkflowEntryNode('code'), isFalse);
      expect(isWorkflowEntryNode('llm'), isFalse);
      expect(isWorkflowEntryNode('end'), isFalse);
    });
  });

  group('isTriggerWorkflow', () {
    test('should return true when nodes contain a trigger node', () {
      expect(isTriggerWorkflow(['start', 'trigger-webhook']), isTrue);
    });

    test('should return false when no trigger nodes exist', () {
      expect(isTriggerWorkflow(['start', 'code']), isFalse);
    });

    test('should return false for empty nodes', () {
      expect(isTriggerWorkflow([]), isFalse);
    });
  });
}
