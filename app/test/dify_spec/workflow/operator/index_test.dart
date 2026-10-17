// dify-spec: web/app/components/workflow/operator/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/operator/operator.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'operator_harness.dart';

/// The operator as the editor mounts it: across the bottom of an 800 px wide canvas, inside `px-1`.
Future<void> _render(WidgetTester t, WorkflowStore store) async {
  await t.pumpWidget(
    MaterialApp(
      home: WorkflowStoreScope(
        store: store,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: WorkflowOperator(canvas: TestCanvas(), history: TestHistory()),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await t.pump();
}

void main() {
  group('Operator', () {
    testWidgets('should keep the operator width on the 400px floor when the available width is smaller', (t) async {
      final store = WorkflowStore()
        ..setWorkflowCanvasWidth(620)
        ..setRightPanelWidth(350);
      await _render(t, store);

      expect(store.bottomPanelWidth.value, 400);
      expect(t.getSize(find.byType(UndoRedo)).width, lessThan(400));
    });

    testWidgets('should fall back to auto width before layout metrics are ready', (t) async {
      final store = WorkflowStore();
      await _render(t, store);

      expect(store.bottomPanelWidth.value, 800);
    });

    testWidgets(
      'should sync the observed panel size back into the workflow store and disconnect on unmount',
      (t) async {
        final store = WorkflowStore()
          ..setWorkflowCanvasWidth(900)
          ..setRightPanelWidth(260);
        await _render(t, store);

        expect(store.bottomPanelWidth.value, 640);
        // The bar (37 px undo pill and pb-2), without the minimap above it.
        expect(store.bottomPanelHeight.value, closeTo(45, 1));

        await t.pumpWidget(const SizedBox());
        store.setBottomPanelHeight(1);
        await t.pump();
        expect(store.bottomPanelHeight.value, 1);
      },
    );
  });
}
