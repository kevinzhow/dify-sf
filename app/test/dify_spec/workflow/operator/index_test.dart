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
    testWidgets('desktop panels keep undo, variables and zoom on one row at the 400px floor', (t) async {
      final store = WorkflowStore()
        ..setWorkflowCanvasWidth(620)
        ..setRightPanelWidth(350);
      await t.pumpWidget(
        MaterialApp(
          home: WorkflowStoreScope(
            store: store,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: SizedBox(
                width: 392,
                child: WorkflowOperator(
                  canvas: TestCanvas(),
                  history: TestHistory(),
                  variableTrigger: const SizedBox(key: Key('variables'), width: 140, height: 24),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pump();
      expect(t.takeException(), isNull);
      final undo = t.getTopLeft(find.byType(UndoRedo));
      final zoom = t.getTopLeft(find.byType(ZoomInOut));
      final variables = t.getRect(find.byKey(const Key('variables')));
      expect(zoom.dy, undo.dy);
      expect(variables.top, greaterThanOrEqualTo(undo.dy));
      expect(variables.bottom, lessThanOrEqualTo(undo.dy + 37));
      expect(store.bottomPanelHeight.value, closeTo(45, 1));
    });

    testWidgets('long desktop labels remain reachable horizontally without wrapping or overflow', (t) async {
      final store = WorkflowStore()
        ..setWorkflowCanvasWidth(620)
        ..setRightPanelWidth(350);
      await t.pumpWidget(
        MaterialApp(
          home: WorkflowStoreScope(
            store: store,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: SizedBox(
                width: 392,
                child: WorkflowOperator(
                  canvas: TestCanvas(),
                  history: TestHistory(),
                  variableTrigger: const SizedBox(width: 500, height: 24, child: Text('Long translated variables')),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pump();
      expect(t.takeException(), isNull);
      final scroll = find.descendant(of: find.byType(WorkflowOperator), matching: find.byType(SingleChildScrollView));
      expect(scroll, findsOneWidget);
      await t.drag(scroll, const Offset(-500, 0));
      await t.pumpAndSettle();
      expect(t.getRect(find.byType(ZoomInOut)).right, lessThanOrEqualTo(392));
      expect(t.takeException(), isNull);
    });

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
