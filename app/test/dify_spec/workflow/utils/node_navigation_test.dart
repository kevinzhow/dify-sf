// dify-spec: web/app/components/workflow/utils/__tests__/node-navigation.spec.ts
//
// Dify's node navigation is a DOM CustomEvent bus (`workflow:select-node` / `workflow:scroll-to-node`); dify-sf's
// header calls the canvas directly. The scroll itself (setupScrollToNodeListener's setCenter) is the header's
// ScrollToSelectedNodeButton when no `scrollToNode` is given.
import 'package:dify_sf_app/src/workflow_editor/header/header_buttons.dart';
import 'package:flutter_test/flutter_test.dart';

import '../header/harness.dart';

void main() {
  group('setupScrollToNodeListener', () {
    testWidgets('should call reactflow.setCenter when scroll event targets an existing node', (t) async {
      final canvas = canvasWith(['n0', 'n1'], selected: 'n1');
      addTearDown(canvas.dispose);
      canvas.view
        ..scale = 0.5
        ..center = Offset.zero;
      await renderWorkflowComponent(t, const ScrollToSelectedNodeButton(), canvas: canvas);
      await t.tap(find.text('workflow.panel.scrollToSelectedNode'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      // Still animating (`duration: 800`).
      expect(canvas.view.scale, inExclusiveRange(0.5, 1));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 16));
      final n = canvas.graph!['n1']!;
      // `zoom: 1`, the centre a quarter of the window right of and below the node's position.
      expect(canvas.view.scale, 1);
      expect(canvas.view.center.dx, greaterThan(n.x));
      expect(canvas.view.center.dy, greaterThan(n.y));
      expect(canvas.view.center, Offset(n.x + 2400 * 0.25, n.y + 1200 * 0.25));
    });
  });
}
