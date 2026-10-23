// dify-spec: web/app/components/workflow/hooks/__tests__/use-helpline.spec.ts
//
// useHelpline().handleSetHelpline is handleSetHelpline over the canvas's nodes (React Flow's `getNodes()`); the
// dragging node is passed in. The drag on the canvas is in workflow_editor_drag_test.dart.
import 'package:dify_sf_app/src/workflow_editor/hooks/use_helpline.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

HelplineNode _node(
  String id, {
  double x = 0,
  double y = 0,
  double width = 240,
  double height = 100,
  String type = 'llm',
  bool inContainer = false,
}) => (id: id, type: type, x: x, y: y, width: width, height: height, inContainer: inContainer);

List<String> _ids(List<HelplineNode> nodes) => [for (final n in nodes) n.id];

void main() {
  late WorkflowStore store;
  setUp(() => store = WorkflowStore());
  tearDown(() => store.dispose());

  group('useHelpline', () {
    test('should return empty arrays for nodes in iteration', () {
      final out = handleSetHelpline(store, [_node('n1'), _node('n2')], _node('n1', inContainer: true));
      expect(out.showHorizontalHelpLineNodes, isEmpty);
      expect(out.showVerticalHelpLineNodes, isEmpty);
    });

    test('should return empty arrays for nodes in loop', () {
      final out = handleSetHelpline(store, [_node('n1')], _node('n1', inContainer: true));
      expect(out.showHorizontalHelpLineNodes, isEmpty);
      expect(out.showVerticalHelpLineNodes, isEmpty);
    });

    test('should detect horizontally aligned nodes (same y ±5px)', () {
      final out = handleSetHelpline(store, [
        _node('n1', y: 100),
        _node('n2', x: 300, y: 103),
        _node('n3', x: 600, y: 500),
      ], _node('n1', y: 100));
      expect(_ids(out.showHorizontalHelpLineNodes), contains('n2'));
      expect(_ids(out.showHorizontalHelpLineNodes), isNot(contains('n3')));
    });

    test('should detect vertically aligned nodes (same x ±5px)', () {
      final out = handleSetHelpline(store, [
        _node('n1', x: 100),
        _node('n2', x: 102, y: 200),
        _node('n3', x: 500, y: 400),
      ], _node('n1', x: 100));
      expect(_ids(out.showVerticalHelpLineNodes), contains('n2'));
      expect(_ids(out.showVerticalHelpLineNodes), isNot(contains('n3')));
    });

    test('should apply entry node offset for Start nodes', () {
      const entryOffsetY = 21.0;
      final out = handleSetHelpline(store, [
        _node('start', x: 100, y: 100, type: 'start'),
        _node('n2', x: 300, y: 100 + entryOffsetY),
        _node('far', x: 300, y: 500),
      ], _node('start', x: 100, y: 100, type: 'start'));
      expect(_ids(out.showHorizontalHelpLineNodes), contains('n2'));
      expect(_ids(out.showHorizontalHelpLineNodes), isNot(contains('far')));
    });

    test('should apply entry node offset for Trigger nodes', () {
      const entryOffsetY = 21.0;
      final out = handleSetHelpline(store, [
        _node('trigger', x: 100, y: 100, type: 'trigger-webhook'),
        _node('n2', x: 300, y: 100 + entryOffsetY),
      ], _node('trigger', x: 100, y: 100, type: 'trigger-webhook'));
      expect(_ids(out.showHorizontalHelpLineNodes), contains('n2'));
    });

    test('should not detect alignment when positions differ by more than 5px', () {
      final out = handleSetHelpline(store, [
        _node('n1', x: 100, y: 100),
        _node('n2', x: 300, y: 106),
        _node('n3', x: 106, y: 300),
      ], _node('n1', x: 100, y: 100));
      expect(out.showHorizontalHelpLineNodes, isEmpty);
      expect(out.showVerticalHelpLineNodes, isEmpty);
    });

    test('should exclude child nodes in iteration', () {
      final out = handleSetHelpline(store, [
        _node('n1', x: 100, y: 100),
        _node('child', x: 300, y: 100, inContainer: true),
      ], _node('n1', x: 100, y: 100));
      expect(_ids(out.showHorizontalHelpLineNodes), isNot(contains('child')));
    });

    test('should set helpLineHorizontal in store when aligned nodes found', () {
      handleSetHelpline(store, [_node('n1', y: 100), _node('n2', x: 300, y: 100)], _node('n1', y: 100));
      expect(store.helpLineHorizontal.value, isNotNull);
    });

    test('should clear helpLineHorizontal when no aligned nodes', () {
      store.setHelpLineHorizontal((top: 1, left: 1, width: 1));
      handleSetHelpline(store, [_node('n1', y: 100), _node('n2', x: 300, y: 500)], _node('n1', y: 100));
      expect(store.helpLineHorizontal.value, isNull);
    });

    test('should extend horizontal helpline when dragging node is before the first aligned node', () {
      handleSetHelpline(store, [
        _node('a', x: 300, y: 100),
        _node('b', x: 600, y: 100),
      ], _node('dragging', x: 100, y: 100));
      expect(store.helpLineHorizontal.value, (top: 100.0, left: 100.0, width: 440.0));
    });

    test('should extend vertical helpline when dragging node is below the aligned nodes', () {
      handleSetHelpline(store, [
        _node('a', x: 120, y: 100),
        _node('b', x: 120, y: 260),
      ], _node('dragging', x: 120, y: 420));
      expect(store.helpLineVertical.value, (top: 100.0, left: 120.0, height: 420.0));
    });

    test('should extend horizontal helpline using entry node width when a start node is after the aligned nodes', () {
      handleSetHelpline(store, [
        _node('aligned', x: 100, y: 100),
      ], _node('start-node', x: 500, y: 79, type: 'start'));
      expect(store.helpLineHorizontal.value, (top: 100.0, left: 100.0, width: 640.0));
    });
  });
}
