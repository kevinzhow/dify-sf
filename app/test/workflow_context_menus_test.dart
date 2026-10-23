import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The menus and shortcuts around the real canvas: hit testing on its cards, keys before its own handling.
void main() {
  testWidgets('menus, node control and shortcuts on the real canvas', (t) async {
    DifyI18n.current = KeyEchoTranslator();
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    String? clipboard;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String?;
      if (call.method == 'Clipboard.getData') return clipboard == null ? null : {'text': clipboard};
      return null;
    });
    final demo = DemoBackend(withBo: false);
    final opened = await demo.openSession('demo', clientId: 'me-abc123', journaled: false);
    await opened.session.start();
    final controller = EditorController(session: opened.session, docId: 'demo', journaled: false);
    final canvas = CanvasController();
    final store = WorkflowStore();
    await t.pumpWidget(
      MaterialApp(
        home: WorkflowStoreScope(
          store: store,
          child: WorkflowShortcuts(
            controller: controller,
            canvas: canvas,
            child: WorkflowContextMenus(
              controller: controller,
              canvas: canvas,
              child: WorkflowCanvas(controller: controller, canvas: canvas),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    final graph = canvas.graph!;
    final llm = graph['llm']!;
    final at = canvas.view.toScreen(llm.rect.center);

    // Right-click on a card: its node menu, and the node selected.
    await t.tapAt(at, buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(DifyMenuPopup), findsOneWidget);
    expect(find.text('panel.about'.toUpperCase()), findsOneWidget);
    expect(store.contextMenuTarget.value, const NodeContextMenuTarget('llm'));
    expect(canvas.selection.nodes, {llm.slot});

    // The selected node shows its control (run + more) above the card's top-right corner.
    expect(find.bySemanticsLabel('operation.more'), findsOneWidget);
    final bar = t.getRect(find.byType(NodeControl));
    final card = canvas.view.rectToScreen(llm.rect);
    expect(bar.right, closeTo(card.right - canvas.view.scale, 0.5));
    expect(bar.bottom, closeTo(card.top + canvas.view.scale - 4 * canvas.view.scale, 0.5));

    // Escape closes the menu; Ctrl+C copies the selected node, Ctrl+V pastes it at the pointer.
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(DifyMenuPopup), findsNothing);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyC);
    await t.sendKeyEvent(LogicalKeyboardKey.keyV);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump(const Duration(milliseconds: 300));
    expect(clipboard, contains('dify-workflow-clipboard'));
    final pasted = controller.doc.nodes.values.where((n) => n.title == 'Answer the question (1)').single;
    expect(Offset(pasted.x.toDouble(), pasted.y.toDouble()), canvas.view.toCanvas(at));

    // Delete goes through the menu actions (one undo step), not the canvas's own handler.
    final before = controller.doc.nodes.length;
    canvas.selection.selectNodes([graph[pasted.id]!.slot]);
    await t.sendKeyEvent(LogicalKeyboardKey.delete);
    await t.pump(const Duration(milliseconds: 300));
    expect(controller.doc.nodes.length, before - 1);
    expect(controller.doc.nodes.containsKey(pasted.id), isFalse);

    await t.pumpWidget(const SizedBox());
    controller.dispose();
    canvas.dispose();
    store.dispose();
    await opened.close();
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  });
}
