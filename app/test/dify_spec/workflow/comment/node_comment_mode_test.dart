// dify-spec: web/app/components/workflow/nodes/_base/__tests__/node.spec.tsx
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'canvas_harness.dart';

void main() {
  group('BaseNode', () {
    testWidgets('should not select the node from the title button while in comment mode', (t) async {
      final semantics = t.ensureSemantics();
      final h = await CommentModeCanvas.start(t);
      final button = find.bySemanticsLabel(RegExp(r'llm node'));
      expect(button, findsOneWidget);
      t.getSemantics(button).owner!.performAction(t.getSemantics(button).id, SemanticsAction.tap);
      await t.pump(const Duration(milliseconds: 300));
      expect(h.canvas.selection.nodes, isEmpty);
      expect(h.controller.selectedNodeId, isNull);
      await h.dispose(t);
      semantics.dispose();
    });
  });
}
