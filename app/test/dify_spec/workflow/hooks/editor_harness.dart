import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/session_factory.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/workflow_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

export '../context_menu/harness.dart' show node;

/// The workflow editor (canvas, menus, shortcuts, store) over a document of [nodes] and [edges] in an in-memory
/// session, 1200 x 800, the view at scale 1 with canvas (0, 0) at the screen's top-left.
class EditorHarness {
  EditorHarness._(this.demo, this.opened, this.controller);

  final DemoBackend demo;
  final OpenedSession opened;
  final EditorController controller;
  late CanvasController canvas;
  late WorkflowStore store;

  Document get doc => controller.doc;

  static Future<EditorHarness> start(
    WidgetTester t,
    List<Node> nodes, {
    List<Edge> edges = const [],
    bool canEdit = true,
    WorkflowMenuOptions options = const WorkflowMenuOptions(),
    Widget Function(Widget editor)? wrap,
  }) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final demo = DemoBackend(
      server: FakeServer(
        initial: Document(nodes: nodes, edges: edges),
      ),
      withBo: false,
    );
    final opened = await demo.openSession('demo', clientId: 'me-abc123', journaled: false);
    await opened.session.start();
    final h = EditorHarness._(demo, opened, EditorController(session: opened.session, docId: 'demo', journaled: false));
    for (var i = 0; i < 50 && !h.controller.ready; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    final editor = WorkflowEditor(controller: h.controller, canEdit: canEdit, menuOptions: options);
    await t.pumpWidget(MaterialApp(home: wrap == null ? editor : wrap(editor)));
    await t.pump();
    h.canvas = t.state<WorkflowCanvasState>(find.byType(WorkflowCanvas)).canvas;
    h.store = WorkflowStoreScope.of(t.element(find.byType(WorkflowCanvas)));
    h.canvas
      ..view.scale = 1
      ..view.center = const Offset(600, 400);
    await settle(t);
    return h;
  }

  /// Where canvas point [c] is on screen.
  Offset screen(Offset c) => canvas.view.toScreen(c);

  /// The middle of node [id]'s card, on screen.
  Offset nodeCenter(String id) => screen(canvas.graph![id]!.rect.center);

  /// The point of node [id]'s source handle [handle], on screen.
  Offset outPort(String id, [String handle = 'source']) => screen(canvas.graph![id]!.outPortFor(handle));

  /// A mouse drag from [from] to [to] (screen) in [steps] moves.
  Future<void> drag(WidgetTester t, Offset from, Offset to, {int steps = 8}) async {
    final g = await t.startGesture(from, kind: PointerDeviceKind.mouse);
    for (var i = 1; i <= steps; i++) {
      await g.moveTo(Offset.lerp(from, to, i / steps)!);
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await t.pump();
  }

  static Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> dispose(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    controller.dispose();
    await opened.close();
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  }
}
