// dify-spec: web/app/components/workflow/nodes/_base/__tests__/node.helpers.spec.ts
import 'package:dify_sf_app/src/cards/node_helpers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('node helpers', () {
    test('should derive node border states from running status and selection state', () {
      expect(getNodeStatusBorders('running', false, false).showRunningBorder, true);
      expect(getNodeStatusBorders('succeeded', false, false).showSuccessBorder, true);
      expect(getNodeStatusBorders('failed', false, false).showFailedBorder, true);
      expect(getNodeStatusBorders('exception', false, false).showExceptionBorder, true);
      expect(getNodeStatusBorders('succeeded', false, true).showSuccessBorder, false);
    });

    test('should expose the correct loop translation key per running status', () {
      expect(getLoopIndexTextKey('running'), 'nodes.loop.currentLoopCount');
      expect(getLoopIndexTextKey('succeeded'), 'nodes.loop.totalLoopCount');
      expect(getLoopIndexTextKey('failed'), 'nodes.loop.totalLoopCount');
      expect(getLoopIndexTextKey('paused'), isNull);
    });

    test('should identify entry and container nodes', () {
      expect(isEntryWorkflowNode('start'), true);
      expect(isEntryWorkflowNode('start-placeholder'), true);
      expect(isEntryWorkflowNode('trigger-webhook'), true);
      expect(isEntryWorkflowNode('tool'), false);

      expect(isContainerNode('iteration'), true);
      expect(isContainerNode('loop'), true);
      expect(isContainerNode('tool'), false);
    });
  });
}
