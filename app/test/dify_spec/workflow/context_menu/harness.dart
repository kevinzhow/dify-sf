import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/canvas/canvas_graph.dart';
import 'package:dify_sf_app/src/canvas/edge_curve.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/session_factory.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Dify's global i18n mock: `<ns>.<key>`.
class NsKeyTranslator implements Translator {
  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) => '$ns.$key';
}

/// A node as Dify's fixtures make it (`createNode`): a code node at [x], [y], [w] x [h] (React Flow's size).
Node node(
  String id, {
  String type = 'code',
  String? title,
  int x = 0,
  int y = 0,
  int w = 80,
  int h = 40,
  String? parent,
  String rfType = 'custom',
  Map<String, Value> config = const {},
}) => Node(
  id: id,
  type: type,
  title: title ?? 'Node $id',
  x: x,
  y: y,
  config: {
    'desc': const VString(''),
    ...config,
    '_dify_node': VMap({
      'type': VString(rfType),
      'width': VInt(w),
      'height': VInt(h),
      if (parent != null) 'parentId': VString(parent),
    }),
  },
);

/// An 800 x 600 editor area whose canvas coordinates are its screen coordinates: a document in an in-memory
/// session, the canvas's graph and selection (no canvas widget), the store, the system clipboard.
class Harness {
  Harness._(this.demo, this.opened, this.controller);

  final DemoBackend demo;
  final OpenedSession opened;
  final EditorController controller;
  final canvas = CanvasController();
  final store = WorkflowStore();
  late final graph = CanvasGraph(
    layoutOf: (n, d) {
      final size = switch (n.config['_dify_node']) {
        VMap(:final entries) => switch ((entries['width'], entries['height'])) {
          (VInt(value: final w), VInt(value: final h)) => Size(w.toDouble(), h.toDouble()),
          _ => const Size(80, 40),
        },
        _ => const Size(80, 40),
      };
      return CardLayout(
        card: size.isEmpty ? Rect.zero : Rect.fromLTWH(1, 1, size.width - 2, size.height - 2),
        sources: const {'source': 17, 'branch-a': 10, 'branch-b': 30},
      );
    },
  );

  /// The system clipboard's text.
  String? clipboard;
  bool clipboardFails = false;

  Document get doc => controller.doc;
  Node? operator [](String id) => doc.nodes[id];

  static Future<Harness> start(WidgetTester t, List<Node> nodes, {List<Edge> edges = const []}) async {
    t.view.physicalSize = const Size(800, 600);
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
    final h = Harness._(demo, opened, EditorController(session: opened.session, docId: 'demo', journaled: false));
    h.canvas
      ..graph = h.graph
      ..view.viewport = const Size(800, 600)
      ..view.center = const Offset(400, 300);
    for (var i = 0; i < 50 && !h.controller.ready; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    h.graph.sync(h.doc);
    h.controller.addListener(() => h.graph.sync(h.doc));
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') h.clipboard = (call.arguments as Map)['text'] as String?;
      if (call.method == 'Clipboard.getData') {
        if (h.clipboardFails) throw PlatformException(code: 'denied');
        return h.clipboard == null ? null : {'text': h.clipboard};
      }
      return null;
    });
    return h;
  }

  WorkflowActions actions([WorkflowMenuOptions options = const WorkflowMenuOptions()]) =>
      WorkflowActions(controller: controller, canvas: canvas, store: store, options: options);

  /// The editor area with the menus (and the shortcuts) around [child].
  Widget app({WorkflowMenuOptions options = const WorkflowMenuOptions(), Widget child = const SizedBox.expand()}) =>
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(800, 600)),
          child: Overlay(
            initialEntries: [
              OverlayEntry(
                builder: (context) => WorkflowStoreScope(
                  store: store,
                  child: WorkflowShortcuts(
                    controller: controller,
                    canvas: canvas,
                    options: options,
                    child: WorkflowContextMenus(controller: controller, canvas: canvas, options: options, child: child),
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  /// Hosts [child] (a menu, the node control) in the store's scope.
  Widget host(Widget child) => Directionality(
    textDirection: TextDirection.ltr,
    child: Overlay(
      initialEntries: [
        OverlayEntry(
          builder: (context) => WorkflowStoreScope(
            store: store,
            child: Align(alignment: Alignment.topLeft, child: child),
          ),
        ),
      ],
    ),
  );

  void select(List<String> ids) => canvas.selection.selectNodes([for (final id in ids) graph[id]!.slot]);

  /// A point on an edge's curve, [at] of the way along (the middle by default).
  Offset edgePoint(String edgeId, {double at = 0.5}) {
    final e = doc.edges[edgeId]!;
    final pts = edgeCurve(graph[e.source]!.outPortFor(e.sourceHandle), graph[e.target]!.inPort);
    return pts[((pts.length - 1) * at).round()];
  }

  Offset nodePoint(String id) => graph[id]!.rect.center;

  Future<void> rightClick(WidgetTester t, Offset at) async {
    await t.tapAt(at, buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await settle(t);
  }

  Future<void> tapText(WidgetTester t, String text) async {
    await t.tap(find.text(text));
    await settle(t);
  }

  Future<void> key(WidgetTester t, LogicalKeyboardKey k) async {
    await t.sendKeyEvent(k);
    await settle(t);
  }

  static Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  bool get menuOpen => find.byType(DifyMenuPopup).evaluate().isNotEmpty;

  Future<void> dispose(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    controller.dispose();
    canvas.dispose();
    store.dispose();
    await opened.close();
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  }
}
