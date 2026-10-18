import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/canvas/canvas_graph.dart';
import 'package:dify_sf_app/src/canvas/live_card.dart';
import 'package:dify_sf_app/src/canvas/run_view.dart';
import 'package:dify_sf_app/src/canvas/scene_renderer.dart' show srgb;
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Scene frame and handle colors retain their alpha and dim with waiting nodes', () {
    for (final color in [
      DifyColors.componentsOptionCardOptionSelectedBorder,
      DifyColors.workflowLinkLineHandle,
      statusBorderColor('succeeded')!,
    ]) {
      final normal = srgb(NodeRunView.idle.tint(color));
      final waiting = srgb(const NodeRunView(waiting: true).tint(color));
      expect(waiting.a, closeTo(normal.a * 0.7, 1e-7));
      expect([waiting.r, waiting.g, waiting.b], [normal.r, normal.g, normal.b]);
    }
    expect(srgb(const Color(0x80000000)).a, closeTo(128 / 255, 1e-7));
  });

  testWidgets('live note dims without rebuilding its editor or losing overflow toolbar hits', (t) async {
    final graph = CanvasGraph(
      layoutOf: (_, _, {run = NodeRunView.idle, selected = false}) =>
          const CardLayout(card: Rect.fromLTWH(0, 0, 100, 100), underlay: true),
    );
    graph.sync(
      Document(
        nodes: [const Node(id: 'note', type: '', title: '', x: 100, y: 100)],
      ),
    );
    var builds = 0, clicks = 0, claimed = 0;
    final source = ValueNotifier<LiveCard?>(
      LiveCard(
        nodeId: 'note',
        builder: (_, _) {
          builds++;
          return OverflowHitStack(
            children: [
              const SizedBox(width: 100, height: 100, child: ColoredBox(color: Colors.blue)),
              Positioned(
                left: 0,
                top: -30,
                width: 80,
                height: 20,
                child: GestureDetector(
                  onTap: () => clicks++,
                  child: const ColoredBox(color: Colors.red),
                ),
              ),
            ],
          );
        },
      ),
    );
    final layer = LiveCardLayer(source: source, graph: graph, isTopAt: (_, _) => true, claim: (_) => claimed++);
    final node = graph['note']!;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(builder: (context) => OverflowHitStack(children: [layer.build(context, node)])),
      ),
    );
    for (final waiting in [false, true, false]) {
      node.run.value = NodeRunView(waiting: waiting);
      await t.pump();
      final render = t.renderObject<RenderOpacity>(find.byKey(const ValueKey('live-note')));
      expect(render.opacity, waiting ? 0.7 : 1);
      await t.tapAt(const Offset(110, 80));
      await t.pump();
    }
    expect(builds, 1);
    expect(clicks, 3);
    expect(claimed, 3);
    await t.pumpWidget(const SizedBox());
    source.dispose();
  });
}
