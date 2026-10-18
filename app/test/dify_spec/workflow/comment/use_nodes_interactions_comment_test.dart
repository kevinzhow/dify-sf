// dify-spec: web/app/components/workflow/hooks/__tests__/use-nodes-interactions.spec.ts
import 'package:flutter_test/flutter_test.dart';

import 'canvas_harness.dart';

void main() {
  group('useNodesInteractions', () {
    testWidgets('ignores node click selection in comment control mode', (t) async {
      final h = await CommentModeCanvas.start(t);
      final llm = h.canvas.graph!['llm']!;
      final before = (llm.x, llm.y);
      await t.tapAt(h.canvas.view.toScreen(llm.rect.center));
      await t.dragFrom(h.canvas.view.toScreen(llm.rect.center), const Offset(80, 40));
      await t.pump(const Duration(milliseconds: 300));
      expect(h.canvas.selection.nodes, isEmpty);
      expect(h.controller.selectedNodeId, isNull);
      expect((llm.x, llm.y), before, reason: 'nodes do not drag in comment mode');
      await h.dispose(t);
    });
  });
}
