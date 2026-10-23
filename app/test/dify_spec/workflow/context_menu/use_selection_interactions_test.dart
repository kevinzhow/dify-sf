// dify-spec: web/app/components/workflow/hooks/__tests__/use-selection-interactions.spec.ts
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('useSelectionInteractions', () {
    testWidgets('handleSelectionContextMenu should set menu only when clicking on selection rect', (t) async {
      final h = await Harness.start(t, [node('n1'), node('n2', x: 100, y: 100)]);
      final a = h.actions();
      h.store.setContextMenuTarget(const NodeContextMenuTarget('n1'));
      expect(a.handleSelectionContextMenu(onSelectionRect: false), isFalse);
      expect(h.store.contextMenuTarget.value, const NodeContextMenuTarget('n1'));
      expect(a.handleSelectionContextMenu(onSelectionRect: true), isTrue);
      expect(h.store.contextMenuTarget.value, WorkflowContextMenuTarget.selection);
      await h.dispose(t);
    });
  });
}
