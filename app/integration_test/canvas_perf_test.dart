// Canvas performance at 500 nodes, widget renderer (the integration-test binding settles between steps, which a
// Flutter Scene view that ticks every frame never does; Flutter Scene is measured with real frames instead).
// Run in profile mode on a real (virtual) display:
//   DIFYSF_CANVAS=widgets xvfb-run -s "-screen 0 1600x1000x24" flutter drive --profile -d linux \
//     --driver=test_driver/perf_driver.dart --target=integration_test/canvas_perf_test.dart
// Writes build/perf/canvas_perf.json (frame timing summaries per interaction, load time, memory).
import 'dart:io';
import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// A workflow of [n] nodes (default 500) on a 25-wide grid: start/llm/code/answer nodes, a chain plus a fan-out every 7 nodes (~570 edges),
/// code nodes with output lists, llm prompts referencing the previous node.
Document bigDocument({int n = 500}) {
  const types = ['llm', 'code', 'answer', 'llm', 'code'];
  final nodes = <Node>[];
  final edges = <Edge>[];
  for (var i = 0; i < n; i++) {
    final type = i == 0 ? 'start' : types[i % types.length];
    nodes.add(
      Node(
        id: 'n$i',
        type: type,
        title: '$type $i',
        x: (i % 25) * 300,
        y: (i ~/ 25) * 180,
        config: {
          if (type == 'llm') 'prompt': VString('Summarise {{#n${max(0, i - 1)}.text#}} for step $i'),
          if (type == 'llm') 'model': const VMap({'name': VString('gpt-4o'), 'temperature': VDouble(0.7)}),
          if (type == 'code') 'code': VString('def main(x):\n    return {"result": x * $i}'),
          if (type == 'code')
            'outputs': VItems([
              Item('o$i', const VMap({'name': VString('result'), 'type': VString('string')})),
            ]),
          if (i > 0) 'input': VRef(OutputRef('n${i - 1}', 'text')),
        },
      ),
    );
    if (i > 0) edges.add(Edge(id: 'e$i', source: 'n${i - 1}', target: 'n$i'));
    if (i % 7 == 0 && i + 25 < n) edges.add(Edge(id: 'f$i', source: 'n$i', target: 'n${i + 25}'));
  }
  return Document(nodes: nodes, edges: edges);
}

int rssMb() => ProcessInfo.currentRss ~/ (1024 * 1024);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('large canvas', (t) async {
    final doc = bigDocument(n: const int.fromEnvironment('NODES', defaultValue: 500));
    final server = FakeServer(initial: doc);
    final backend = DemoBackend(server: server, withBo: false);
    final rssBefore = rssMb();
    final sw = Stopwatch()..start();
    await t.pumpWidget(
      MaterialApp(
        home: EditorPage(backend: backend, docId: 'perf', journaled: false, create: true),
      ),
    );
    bool loaded() {
      final canvas = find.byType(WorkflowCanvas);
      return canvas.evaluate().isNotEmpty &&
          t.state<WorkflowCanvasState>(canvas).graph.length == doc.nodes.length;
    }

    while (!loaded() && sw.elapsed < const Duration(seconds: 60)) {
      await t.pump(const Duration(milliseconds: 16));
    }
    final loadMs = sw.elapsedMilliseconds;
    await t.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    binding.reportData = {
      'nodes': doc.nodes.length,
      'edges': doc.edges.length,
      'loadMs': loadMs,
      'rssBeforeMb': rssBefore,
      'rssLoadedMb': rssMb(),
    };

    final bg = find.byKey(const Key('canvas-background'));
    final center = t.getCenter(bg);

    await binding.watchPerformance(() async {
      // Middle-button drag pans (a left-button drag on empty canvas draws a selection box, as in Dify).
      final g = await t.startGesture(center, kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
      for (var i = 0; i < 120; i++) {
        await g.moveBy(Offset(i.isEven ? 6 : -5, 3));
        await t.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await t.pumpAndSettle();
    }, reportKey: 'pan');

    // zoom through the zoom buttons (the same _zoom path as Ctrl + wheel), 15 steps in and 15 out
    await binding.watchPerformance(() async {
      for (var i = 0; i < 30; i++) {
        await t.tap(find.byKey(Key(i < 15 ? 'zoom-in' : 'zoom-out')));
        await t.pump(const Duration(milliseconds: 16));
        await t.pump(const Duration(milliseconds: 16));
      }
      await t.pumpAndSettle();
    }, reportKey: 'zoom');

    final node = find.byKey(const ValueKey('node-n0'));
    await binding.watchPerformance(() async {
      final g = await t.startGesture(t.getCenter(node));
      for (var i = 0; i < 90; i++) {
        await g.moveBy(const Offset(4, 2));
        await t.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await t.pumpAndSettle();
    }, reportKey: 'dragNode');

    // Another user edits titles at ~20 commits/s while this canvas is idle.
    final bo = CollabSession(
      clientId: 'bo-perf',
      transport: FakeTransport(server, network: FakeNetwork(random: Random(1))),
      store: MemoryStore(),
    );
    await bo.start();
    await binding.watchPerformance(() async {
      for (var i = 0; i < 100; i++) {
        bo.edit(SetField('n${(i * 37) % doc.nodes.length}', const TitleKey(), VString('edited $i')));
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.pumpAndSettle();
    }, reportKey: 'remoteEdits');
    await bo.stop();
    binding.reportData!['rssEndMb'] = rssMb();

    await t.pumpWidget(const SizedBox());
    await backend.dispose();
  });
}
