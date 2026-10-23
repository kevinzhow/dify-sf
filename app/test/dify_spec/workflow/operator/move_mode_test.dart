// dify-spec: web/app/components/workflow/hooks/__tests__/use-workflow-panel-interactions.spec.tsx
import 'package:dify_sf_app/src/canvas/canvas_input.dart' show ControlMode;
import 'package:dify_sf_app/src/workflow_editor/operator/operator.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'operator_harness.dart';

void main() {
  group('useWorkflowMoveMode', () {
    late WorkflowStore store;
    late TestCanvas canvas;
    late OperatorActions actions;

    setUp(() {
      store = WorkflowStore();
      canvas = TestCanvas();
      actions = OperatorActions(canvas, store, options: const OperatorOptions(collaborationEnabled: true));
      // A box selection (Dify's bundled nodes), which handleSelectionCancel drops.
      canvas.selection.selectNodes([1, 2]);
    });

    test('switches between hand and pointer modes when editable', () {
      actions.modeHand();
      expect(store.controlMode.value, ControlMode.hand);
      expect(canvas.selection.nodes, isEmpty);

      actions.modePointer();
      expect(store.controlMode.value, ControlMode.pointer);
    });

    test('does not switch modes when nodes are read-only', () {
      store.setCanvasReadOnly(true);
      actions
        ..modeHand()
        ..modePointer();

      expect(store.controlMode.value, ControlMode.pointer);
      expect(canvas.selection.nodes, {1, 2});
    });

    test('switches to comment mode when nodes are read-only', () {
      store.setCanvasReadOnly(true);
      actions.modeComment();

      expect(store.controlMode.value, ControlMode.comment);
      expect(canvas.selection.nodes, isEmpty);
      expect(actions.canUseCommentMode, isTrue);
    });

    test('does not switch to comment mode while workflow operation is blocked', () {
      store.setWorkflowRunningData({
        'result': {'status': 'running'},
      });
      actions.modeComment();

      expect(actions.canUseCommentMode, isFalse);
      expect(store.controlMode.value, ControlMode.pointer);
      expect(canvas.selection.nodes, {1, 2});
    });
  });
}
