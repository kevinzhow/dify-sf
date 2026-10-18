// The Flutter Scene canvas draws only while something changes. It used to render every frame: on the web each frame
// also reads the scene back and re-rasterizes the page, which kept the page so busy that menus and toasts showed
// seconds late (the visual case toast-publish). Needs Flutter GPU, so it runs on a desktop:
//   xvfb-run -a -s "-screen 0 1600x1000x24" flutter test integration_test/scene_idle_test.dart -d linux
import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/canvas/renderer_choice.dart';
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' show SceneView;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// pumpAndSettle with time for the captures (on a software rasterizer).
Future<void> settle(WidgetTester t) =>
    t.pumpAndSettle(const Duration(milliseconds: 16), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 30));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the Flutter Scene canvas stops drawing at rest, and draws again after a change', (t) async {
    final doc = Document(
      nodes: [
        Node(id: 'start', type: 'start', title: 'Start'),
        Node(id: 'llm', type: 'llm', title: 'LLM', x: 400),
      ],
      edges: [Edge(id: 'e', source: 'start', target: 'llm')],
    );
    final backend = DemoBackend(server: FakeServer(initial: doc), withBo: false);
    await t.pumpWidget(
      MaterialApp(
        home: EditorPage(backend: backend, docId: 'idle', journaled: false, create: true),
      ),
    );
    final canvas = find.byType(WorkflowCanvas);
    bool loaded() => canvas.evaluate().isNotEmpty && t.state<WorkflowCanvasState>(canvas).graph.length == 2;
    for (var i = 0; i < 300 && !loaded(); i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    final state = t.state<WorkflowCanvasState>(canvas);
    expect(state.kind, CanvasRendererKind.scene, reason: 'Flutter GPU is needed (the canvas fell back to widgets)');

    // A scene rendering every frame keeps a frame scheduled for ever: pumpAndSettle would time out.
    bool rendersEveryFrame() => TickerMode.valuesOf(t.element(find.byType(SceneView))).enabled;
    await settle(t);
    expect(rendersEveryFrame(), isFalse);

    state.widget.controller.moveNode('llm', 440, 40);
    await t.pump();
    expect(rendersEveryFrame(), isTrue, reason: 'a change wakes the scene');
    await settle(t);
    expect(rendersEveryFrame(), isFalse);

    await t.pumpWidget(const SizedBox());
    await backend.dispose();
  });
}
