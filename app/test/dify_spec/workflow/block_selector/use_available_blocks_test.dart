// dify-spec: web/app/components/workflow/hooks/__tests__/use-available-blocks.spec.ts
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:flutter_test/flutter_test.dart';

const _types = [
  'start', 'start-placeholder', 'end', 'llm', 'code', 'if-else', 'iteration', 'loop', 'tool', 'datasource', //
  'knowledge-index', 'human-input', 'loop-end',
];

({List<String> prev, List<String> next}) _hook(String? type, {bool inContainer = false}) =>
    useAvailableBlocks(type, availableTypes: _types, inContainer: inContainer);

({List<String> prev, List<String> next}) _get(String? type, {bool inContainer = false}) =>
    getAvailableBlocks(type, availableTypes: _types, inContainer: inContainer);

void main() {
  group('useAvailableBlocks', () {
    group('availablePrevBlocks', () {
      test('should return empty array when nodeType is undefined', () => expect(_hook(null).prev, isEmpty));

      test('should return empty array for Start node', () => expect(_hook('start').prev, isEmpty));

      test(
        'should return empty array for StartPlaceholder node',
        () => expect(_hook('start-placeholder').prev, isEmpty),
      );

      test('should return empty array for trigger nodes', () {
        for (final t in ['trigger-plugin', 'trigger-webhook', 'trigger-schedule']) {
          expect(_hook(t).prev, isEmpty);
        }
      });

      test('should return empty array for DataSource node', () => expect(_hook('datasource').prev, isEmpty));

      test('should return all available nodes for regular block types', () {
        expect(_hook('llm').prev, isNotEmpty);
        expect(_hook('llm').prev, contains('code'));
      });
    });

    group('availableNextBlocks', () {
      test('should return empty array when nodeType is undefined', () => expect(_hook(null).next, isEmpty));

      test('should return available nodes for End node', () {
        expect(_hook('end').next, isNotEmpty);
        expect(_hook('end').next, contains('code'));
      });

      test('should return empty array for LoopEnd node', () => expect(_hook('loop-end').next, isEmpty));

      test('should return empty array for KnowledgeBase node', () => expect(_hook('knowledge-index').next, isEmpty));

      test(
        'should return empty array for StartPlaceholder node',
        () => expect(_hook('start-placeholder').next, isEmpty),
      );

      test('should return all available nodes for regular block types', () {
        expect(_hook('llm').next, isNotEmpty);
        expect(_hook('llm').next, isNot(contains('start-placeholder')));
      });
    });

    group('inContainer filtering', () {
      test('should allow HumanInput while excluding unsupported blocks when inContainer=true', () {
        final next = _hook('llm', inContainer: true).next;
        for (final t in ['iteration', 'loop', 'end', 'datasource', 'knowledge-index']) {
          expect(next, isNot(contains(t)));
        }
        expect(next, contains('human-input'));
      });

      test(
        'should exclude LoopEnd when not in container',
        () => expect(_hook('llm').next, isNot(contains('loop-end'))),
      );
    });

    group('getAvailableBlocks callback', () {
      test('should return prev and next blocks for a given node type', () {
        final b = _get('code');
        expect(b.prev, isNotEmpty);
        expect(b.next, isNotEmpty);
      });

      test('should return empty prevBlocks for Start node', () => expect(_get('start').prev, isEmpty));

      test('should return empty prevBlocks for DataSource node', () => expect(_get('datasource').prev, isEmpty));

      test('should return no blocks for StartPlaceholder node', () {
        expect(_get('start-placeholder').prev, isEmpty);
        expect(_get('start-placeholder').next, isEmpty);
      });

      test('should return empty nextBlocks for LoopEnd/KnowledgeBase and available nodes for End', () {
        expect(_get('end').next, isNotEmpty);
        expect(_get('end').next, contains('code'));
        expect(_get('loop-end').next, isEmpty);
        expect(_get('knowledge-index').next, isEmpty);
      });

      test('should filter by inContainer when provided', () {
        final b = _get('code', inContainer: true);
        expect(b.next, isNot(contains('iteration')));
        expect(b.next, isNot(contains('loop')));
      });
    });
  });
}
