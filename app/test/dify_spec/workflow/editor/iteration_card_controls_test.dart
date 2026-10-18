// dify-spec: web/app/components/workflow/nodes/iteration/__tests__/integration.spec.tsx
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/bodies/entry_bodies.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/node_insertion/insert_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../hooks/editor_harness.dart';
import '../../../support/app_fonts.dart';

List<Node> nodes({bool candidate = false}) => [
  node(
    'iteration',
    type: 'iteration',
    x: 100,
    y: 100,
    w: 600,
    h: 300,
    config: {
      'start_node_id': const VString('start'),
      'is_parallel': const VBool(true),
      if (candidate) '_isCandidate': const VBool(true),
    },
  ),
  node(
    'start',
    type: 'iteration-start',
    x: 16,
    y: 65,
    parent: 'iteration',
    config: {'isInIteration': const VBool(true)},
  ),
];

void main() {
  setUp(() async {
    await useAppFonts();
    await DifyI18n.load('en-US');
  });
  group('iteration path', () {
    testWidgets('should render candidate iteration nodes and show the parallel warning once', (t) async {
      final h = await EditorHarness.start(
        t,
        nodes(candidate: true),
        wrap: (editor) => Stack(children: [editor, const DifyToastHost()]),
      );
      expect(find.byType(ContainerStartNodeDumb), findsOneWidget);
      expect(find.byKey(const ValueKey('iteration-add-start')), findsOneWidget);
      final actions = WorkflowActions(controller: h.controller, canvas: h.canvas, store: h.store);
      actions.addNodeAt(const InsertAfter('start'), 'tool', blockDefaults('tool'));
      await EditorHarness.settle(t);
      final warning = DifyI18n.tr('workflow', 'nodes.iteration.answerNodeWarningDesc');
      expect(find.text(warning), findsOneWidget);
      expect(h.canvas.parallelWarnings, {'iteration'});
      toast.dismiss();
      await t.pump(const Duration(milliseconds: 300));
      actions.addNodeAt(const InsertAfter('start'), 'tool', blockDefaults('tool'));
      await EditorHarness.settle(t);
      expect(find.text(warning), findsNothing);
      await h.dispose(t);
    });
  });

  testWidgets('iteration Add Node opens the constrained selector and inserts after its start as one undo step', (
    t,
  ) async {
    final h = await EditorHarness.start(t, nodes());
    await t.tap(find.byKey(const ValueKey('iteration-add-start')));
    await EditorHarness.settle(t);
    expect(find.byType(BlockSelectorCard), findsOneWidget);
    final selector = find.byType(BlockSelectorCard);
    expect(
      find.descendant(of: selector, matching: find.text(DifyI18n.tr('workflow', 'blocks.iteration'))),
      findsNothing,
    );
    await t.tap(find.descendant(of: selector, matching: find.text(DifyI18n.tr('workflow', 'blocks.code'))));
    await EditorHarness.settle(t);
    final added = h.doc.nodes.values.singleWhere((n) => n.type == 'code');
    expect(h.doc.edges.values.where((e) => e.source == 'start' && e.target == added.id), hasLength(1));
    expect(h.controller.undo.past, hasLength(1));
    expect(find.byKey(const ValueKey('iteration-add-start')), findsNothing);
    h.controller.undo.undo();
    await EditorHarness.settle(t);
    expect(find.byKey(const ValueKey('iteration-add-start')), findsOneWidget);
    await h.dispose(t);
  });

  testWidgets('iteration Add Node is disabled in a read-only editor', (t) async {
    final h = await EditorHarness.start(t, nodes(), canEdit: false);
    final button = find.byKey(const ValueKey('iteration-add-start'));
    expect(t.widget<DifyButton>(button).disabled, isTrue);
    await t.tap(button);
    await EditorHarness.settle(t);
    expect(find.byType(BlockSelectorCard), findsNothing);
    await h.dispose(t);
  });
}
