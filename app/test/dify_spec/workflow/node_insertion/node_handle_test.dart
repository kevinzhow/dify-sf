// dify-spec: web/app/components/workflow/nodes/_base/components/__tests__/node-handle.spec.tsx
//
// NodeTargetHandle / NodeSourceHandle's add triggers are dify-sf's CanvasPlusButtons: the "+" on the handles of the
// hovered or selected node, opening the block selector (with its Start tab). Dify's data flags
// (`_connectedTargetHandleIds`, `selected`) are the document's edges and the canvas selection; the onboarding
// auto-open reads the store's `shouldAutoOpenStartNodeSelector`.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/canvas/canvas_graph.dart';
import 'package:dify_sf_app/src/cards/dify_cards.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector_data.dart';
import 'package:dify_sf_app/src/workflow_editor/canvas_plus/canvas_plus_buttons.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';
import '../context_menu/harness.dart';
import '../nodes_panel/core/harness.dart' show difyNode, difyNodes;

/// The editor's canvas "+" layer over [nodes] (with Dify's card layouts).
Future<Harness> _render(
  WidgetTester t,
  List<Node> nodes, {
  List<Edge> edges = const [],
  bool chatMode = false,
  void Function(WorkflowStore store)? init,
}) async {
  useDifyTestTranslator();
  final h = await Harness.start(t, nodes, edges: edges);
  final graph = CanvasGraph(layoutOf: const DifyCards().layoutOf)..sync(h.doc);
  h.controller.addListener(() => graph.sync(h.doc));
  h.canvas.graph = graph;
  init?.call(h.store);
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: WorkflowStoreScope(
          store: h.store,
          child: BlockSelectorScope(
            data: BlockSelectorData(
              chatMode: chatMode,
              nodes: [for (final n in h.doc.nodes.values) (id: n.id, type: n.type)],
            ),
            child: SizedBox.expand(
              child: CanvasPlusButtons(controller: h.controller, canvas: h.canvas),
            ),
          ),
        ),
      ),
    ),
  );
  await Harness.settle(t);
  return h;
}

int _slot(Harness h, String id) => h.canvas.graph![id]!.slot;

Finder _plus(String key) => find.byKey(ValueKey(key));

/// Whether the block selector is open (its tabs show).
bool _selectorOpen() => find.text('workflow.tabs.blocks').evaluate().isNotEmpty;

Future<void> _hover(WidgetTester t, Harness h, String id) async {
  h.canvas.selection.hover(_slot(h, id));
  await t.pump();
}

final _code = difyNode('node-1', 'code', {}, 'Node');

void main() {
  group('node-handle', () {
    group('NodeTargetHandle', () {
      testWidgets('should show the start tab when adding a node before the target node', (t) async {
        final h = await _render(t, difyNodes([_code]));
        await _hover(t, h, 'node-1');
        await t.tap(_plus('in-node-1'));
        await Harness.settle(t);
        expect(find.text('workflow.tabs.start'), findsOneWidget);
        await h.dispose(t);
      });

      testWidgets('should toggle the target add trigger', (t) async {
        final h = await _render(t, difyNodes([_code]));
        // Hidden until the node is hovered or selected (`opacity-0`).
        expect(_plus('in-node-1'), findsNothing);
        await _hover(t, h, 'node-1');
        expect(_plus('in-node-1'), findsOneWidget);
        await t.tap(_plus('in-node-1'));
        await Harness.settle(t);
        expect(_selectorOpen(), isTrue);
        // A second click on the handle closes it.
        await t.tapAt(t.getCenter(_plus('in-node-1')));
        await Harness.settle(t);
        expect(_selectorOpen(), isFalse);
        await h.dispose(t);
      });

      testWidgets('should not render the target add trigger when the handle is already connected', (t) async {
        final nodes = difyNodes([difyNode('node-0', 'code', {}, 'Before'), _code]);
        final h = await _render(
          t,
          nodes,
          edges: [const Edge(id: 'e', source: 'node-0', target: 'node-1')],
        );
        await _hover(t, h, 'node-1');
        expect(_plus('in-node-1'), findsNothing);
        await h.dispose(t);
      });

      testWidgets('should hide the target handle for workflow entry nodes', (t) async {
        final h = await _render(t, difyNodes([difyNode('trigger', 'trigger-plugin', {}, 'Trigger')]));
        expect(h.canvas.graph!['trigger']!.layout.target, isFalse);
        await _hover(t, h, 'trigger');
        expect(_plus('in-trigger'), findsNothing);
        await h.dispose(t);
      });

      testWidgets('should keep the target add trigger visible when the node is selected', (t) async {
        final h = await _render(t, difyNodes([_code]));
        h.canvas.selection.selectNodes([_slot(h, 'node-1')]);
        await t.pump();
        expect(_plus('in-node-1'), findsOneWidget);
        await h.dispose(t);
      });
    });

    group('NodeSourceHandle', () {
      testWidgets('should show the start tab when adding a node after the source node', (t) async {
        final h = await _render(t, difyNodes([_code]));
        await _hover(t, h, 'node-1');
        await t.tap(_plus('out-node-1-source'));
        await Harness.settle(t);
        expect(find.text('workflow.tabs.start'), findsOneWidget);
        await h.dispose(t);
      });

      testWidgets('should toggle the source add trigger', (t) async {
        final h = await _render(t, difyNodes([_code]));
        expect(_plus('out-node-1-source'), findsNothing);
        await _hover(t, h, 'node-1');
        await t.tap(_plus('out-node-1-source'));
        await Harness.settle(t);
        expect(_selectorOpen(), isTrue);
        await t.tapAt(t.getCenter(_plus('out-node-1-source')));
        await Harness.settle(t);
        expect(_selectorOpen(), isFalse);
        await h.dispose(t);
      });

      testWidgets('should keep the source add trigger visible when the node is selected', (t) async {
        final h = await _render(t, difyNodes([_code]));
        h.canvas.selection.selectNodes([_slot(h, 'node-1')]);
        await t.pump();
        expect(_plus('out-node-1-source'), findsOneWidget);
        await h.dispose(t);
      });
    });

    group('NodeSourceHandle auto-open', () {
      testWidgets('should auto-open immediately for %s nodes', (t) async {
        for (final type in ['start', 'trigger-schedule', 'trigger-webhook', 'trigger-plugin']) {
          final h = await _render(
            t,
            difyNodes([difyNode('entry', type, {}, 'Entry')]),
            init: (s) => s
              ..setShouldAutoOpenStartNodeSelector(true)
              ..setHasSelectedStartNode(true),
          );
          expect(_selectorOpen(), isTrue, reason: type);
          expect(h.store.shouldAutoOpenStartNodeSelector.value, isFalse);
          expect(h.store.hasSelectedStartNode.value, isFalse);
          await h.dispose(t);
        }
      });

      testWidgets('should skip source auto-open in chat mode and only reset the start selector flag', (t) async {
        final h = await _render(
          t,
          difyNodes([difyNode('entry', 'start', {}, 'Start')]),
          chatMode: true,
          init: (s) => s
            ..setShouldAutoOpenStartNodeSelector(true)
            ..setHasSelectedStartNode(true),
        );
        expect(_selectorOpen(), isFalse);
        expect(h.store.shouldAutoOpenStartNodeSelector.value, isFalse);
        expect(h.store.hasSelectedStartNode.value, isTrue);
        await h.dispose(t);
      });

      testWidgets('should not auto-open when the node type is not a workflow entry node', (t) async {
        final h = await _render(
          t,
          difyNodes([_code]),
          init: (s) => s
            ..setShouldAutoOpenStartNodeSelector(true)
            ..setHasSelectedStartNode(true),
        );
        expect(_selectorOpen(), isFalse);
        expect(h.store.shouldAutoOpenStartNodeSelector.value, isTrue);
        expect(h.store.hasSelectedStartNode.value, isTrue);
        await h.dispose(t);
      });
    });
  });
}
