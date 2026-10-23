// dify-spec: web/app/components/workflow/panel/__tests__/index.spec.tsx
// dify-spec: web/app/components/workflow/panel/__tests__/panel-width-integration.spec.tsx
//
// Panel (panel/index.tsx) is dify-sf's WorkflowPanels: the selected node's panel, then the other panels (Dify's
// `components.right`, the version history panel, the variable panels), with the widths measured into the store.
// dify-sf has no `components.left` slot (Dify's RAG pipeline puts its input field panel there).
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_scope.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/run_panels.dart';
import 'package:dify_sf_app/src/workflow_editor/version_history/version_history_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../node_panel/harness.dart';

final _bodies = NodePanelBodies({'code': (context, props) => const Text('Selected node details')});

Future<void> _render(WidgetTester t, Harness h, List<Widget> others, {double width = 1600}) async {
  t.view.physicalSize = Size(width, 900);
  await t.pumpWidget(
    panelApp(h, WorkflowPanels(controller: h.controller, canvas: h.canvas, bodies: _bodies, others: others)),
  );
  await settle(t);
}

void main() {
  setUp(useDifyTestTranslator);

  group('Panel', () {
    testWidgets(
      'should render slots, selected node details, and secondary panels while constraining oversized preview widths',
      (t) async {
        final h = await Harness.start(t, [node('node-1', title: 'Selected Node')]);
        h.controller.selectNode('node-1');
        h.store
          ..setShowWorkflowVersionHistoryPanel(true)
          ..setWorkflowCanvasWidth(1000)
          ..setPreviewPanelWidth(520);
        await _render(t, h, [
          const SizedBox(width: 100, child: Text('right-slot')),
          const VersionHistoryPanelHost(data: VersionHistoryPanelData(latestVersionId: 'version-1')),
        ]);
        expect(find.text('right-slot'), findsOneWidget);
        expect(find.text('Selected node details'), findsOneWidget);
        expect(find.byType(VersionHistoryPanel), findsOneWidget);
        expect(t.widget<VersionHistoryPanel>(find.byType(VersionHistoryPanel)).data.latestVersionId, 'version-1');
        // A node panel is open: the preview may take the canvas less 800.
        expect(h.store.previewPanelWidth.value, 400);
        expect(h.store.rightPanelWidth.value, greaterThan(0));
        expect(h.store.otherPanelWidth.value, 100 + 268);
        await h.dispose(t);
      },
    );

    testWidgets('should skip node and auxiliary panels when there is no selected node or open side panel state', (
      t,
    ) async {
      final h = await Harness.start(t, [node('node-1', title: 'Selected Node')]);
      h.store.setPreviewPanelWidth(420);
      await _render(t, h, [
        const Text('right-only'),
        const VersionHistoryPanelHost(),
      ]);
      expect(find.text('right-only'), findsOneWidget);
      expect(find.text('Selected node details'), findsNothing);
      expect(find.byType(VersionHistoryPanel), findsNothing);
      expect(h.store.previewPanelWidth.value, 420);
      await h.dispose(t);
    });

    testWidgets(
      'should derive observer widths from border-box, content-rect, and fallback values and disconnect on unmount',
      (t) async {
        // The panel row reports its border-box width after each layout that changes it, and nothing once gone.
        final h = await Harness.start(t, [node('node-1')]);
        final width = ValueNotifier<double>(640);
        addTearDown(width.dispose);
        await _render(t, h, [
          ValueListenableBuilder(
            valueListenable: width,
            builder: (context, w, _) => SizedBox(width: w),
          ),
        ]);
        expect(h.store.rightPanelWidth.value, 640);
        expect(h.store.otherPanelWidth.value, 640);
        width.value = 720;
        await settle(t);
        expect(h.store.rightPanelWidth.value, 720);
        expect(h.store.otherPanelWidth.value, 720);
        width.value = 530;
        await settle(t);
        expect(h.store.rightPanelWidth.value, 530);
        expect(h.store.otherPanelWidth.value, 530);
        await t.pumpWidget(const SizedBox());
        h.store
          ..setRightPanelWidth(1)
          ..setOtherPanelWidth(1);
        await settle(t);
        expect(h.store.rightPanelWidth.value, 1);
        expect(h.store.otherPanelWidth.value, 1);
        await h.dispose(t);
      },
    );
  });

  group('preview width limits inside the workflow Panel', () {
    /// The editor with a selected node and the [chat] Debug & Preview panel (else the Test Run panel) open, in a
    /// 1400 px canvas with a 600 px node panel.
    Future<Harness> renderPanels(WidgetTester t, {required bool chat}) async {
      final h = await Harness.start(t, [node('node-1', title: 'Selected Node')]);
      h.controller.selectNode('node-1');
      h.store
        ..setWorkflowCanvasWidth(1400)
        ..setNodePanelWidth(600)
        ..setPreviewPanelWidth(400)
        ..setShowDebugAndPreviewPanel(true);
      await _render(t, h, [
        WorkflowRunHost(
          controller: h.controller,
          canvas: h.canvas,
          isChatMode: () => chat,
          child: RunPanels(controller: h.controller, isChatMode: chat),
        ),
      ], width: 2400);
      return h;
    }

    Future<void> key(WidgetTester t, LogicalKeyboardKey k) async {
      await t.sendKeyEvent(k);
      await t.pump();
    }

    /// Focuses the run panel's handle (the last separator).
    void focusHandle(WidgetTester t) => t
        .widget<Focus>(find.descendant(of: find.byType(ResizeHandle).last, matching: find.byType(Focus)).first)
        .focusNode!
        .requestFocus();

    ResizeHandle handle(WidgetTester t) => t.widget<ResizeHandle>(find.byType(ResizeHandle).last);

    // Dify runs this for the workflow run, snippet run and chat debug panels; dify-sf has no snippet run panel.
    testWidgets('%s exposes the reachable maximum and restores canvas space after deselection', (t) async {
      for (final chat in [false, true]) {
        final h = await renderPanels(t, chat: chat);
        expect(handle(t).max, 600, reason: 'chat: $chat');
        focusHandle(t);
        await t.pump();
        await key(t, LogicalKeyboardKey.end);
        await key(t, LogicalKeyboardKey.arrowLeft);
        expect(h.store.previewPanelWidth.value, 600);
        h.controller.selectNode(null);
        await settle(t);
        expect(find.text('Selected node details'), findsNothing);
        expect(handle(t).max, 1000);
        focusHandle(t);
        await t.pump();
        await key(t, LogicalKeyboardKey.end);
        expect(h.store.previewPanelWidth.value, 1000);
        await h.dispose(t);
      }
    });

    testWidgets('allows the debug panel to grow by pointer while the selected node panel is wider than its minimum', (
      t,
    ) async {
      final h = await renderPanels(t, chat: true);
      final at = t.getCenter(find.byType(ResizeHandle).last);
      final g = await t.startGesture(at);
      await g.moveBy(const Offset(-100, 0));
      await g.moveBy(const Offset(-100, 0));
      await g.up();
      await settle(t);
      expect(h.store.previewPanelWidth.value, 600);
      expect(handle(t).max, 600);
      await h.dispose(t);
    });

    testWidgets('%s keeps its size and ARIA range consistent when the canvas shrinks without a selected node', (
      t,
    ) async {
      for (final chat in [false, true]) {
        final h = await renderPanels(t, chat: chat);
        h.controller.selectNode(null);
        await settle(t);
        focusHandle(t);
        await t.pump();
        await key(t, LogicalKeyboardKey.end);
        expect(h.store.previewPanelWidth.value, 1000);
        h.store.setWorkflowCanvasWidth(1000);
        await settle(t);
        expect(h.store.previewPanelWidth.value, 600);
        expect(handle(t).max, 600);
        await key(t, LogicalKeyboardKey.arrowLeft);
        expect(h.store.previewPanelWidth.value, 600);
        await key(t, LogicalKeyboardKey.arrowRight);
        expect(h.store.previewPanelWidth.value, 592);
        await h.dispose(t);
      }
    });
  });
}
