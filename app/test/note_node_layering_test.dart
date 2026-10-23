// The selected note stays in the notes' layer, as in Dify (`.react-flow__node-custom-note { z-index: -1 }`): the
// edges and the other nodes lie over its live editor and toolbar, which take only the pointer events that land on
// them; the toolbar is drawn inside the canvas (clipped to it, under the editor's chrome).
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/canvas/canvas_graph.dart';
import 'package:dify_sf_app/src/canvas/live_card.dart';
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/cards/dify_cards.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/workflow/note_node/harness.dart';

Node code(String id, {required int x, required int y}) => Node(id: id, type: 'code', title: 'Code', x: x, y: y);

/// Whether a pointer at [at] lands on [finder]'s widget (or inside it).
bool hits(WidgetTester t, Offset at, Finder finder) {
  final r = HitTestResult();
  t.binding.hitTestInView(r, at, t.view.viewId);
  final box = t.renderObject(finder);
  bool inside(RenderObject o) {
    for (RenderObject? p = o; p != null; p = p.parent) {
      if (p == box) return true;
    }
    return false;
  }

  return r.path.any((e) => e.target is RenderObject && inside(e.target as RenderObject));
}

/// Whether a pointer at [at] lands in the live note's editor (its text field).
bool hitsEditor(WidgetTester t, Offset at) => hits(t, at, find.byType(TextField));

void main() {
  group('the selected note lies under the other nodes and the edges', () {
    testWidgets('a click on a node lying over the selected note selects that node', (t) async {
      final h = await NoteHarness.start(t, [note('n1', x: 100, y: 100), code('c1', x: 200, y: 120)]);
      await h.clickNote(t, 'n1', offset: const Offset(30, 40));
      expect(h.controller.selectedNodeId, 'n1');
      expect(h.overlayShown, isTrue);
      expect(hitsEditor(t, const Offset(130, 140)), isTrue, reason: 'the editor where nothing covers it');
      expect(hitsEditor(t, const Offset(260, 150)), isFalse, reason: 'the code node covers the editor here');

      await t.tapAt(const Offset(260, 150));
      await NoteHarness.settle(t);

      expect(h.controller.selectedNodeId, 'c1');
      expect(h.overlayShown, isFalse);
      await h.dispose(t);
    });

    testWidgets('the live note is painted before (under) the node over it', (t) async {
      final h = await NoteHarness.start(t, [note('n1', x: 100, y: 100), code('c1', x: 200, y: 120)]);
      await h.clickNote(t, 'n1', offset: const Offset(30, 40));
      final stack = t.widget<OverflowHitStack>(
        find.ancestor(of: find.byType(NoteNode), matching: find.byType(OverflowHitStack)).last,
      );
      final keys = [for (final c in stack.children) c.key];
      final live = keys.indexOf(const ValueKey('live-n1'));
      final card = stack.children.indexWhere(
        (c) => find
            .descendant(of: find.byWidget(c), matching: find.byKey(const ValueKey('node-c1')))
            .evaluate()
            .isNotEmpty,
      );
      expect(live, greaterThanOrEqualTo(0));
      expect(card, greaterThan(live));
      await h.dispose(t);
    });

    testWidgets('a later note over the selected one takes the click', (t) async {
      final h = await NoteHarness.start(t, [note('n1', x: 100, y: 100), note('n2', x: 250, y: 140)]);
      await h.clickNote(t, 'n1', offset: const Offset(30, 40));
      expect(h.controller.selectedNodeId, 'n1');

      await t.tapAt(const Offset(300, 170));
      await NoteHarness.settle(t);

      expect(h.controller.selectedNodeId, 'n2');
      await h.dispose(t);
    });

    testWidgets('a click on an edge crossing the selected note selects the edge', (t) async {
      final h = await NoteHarness.start(
        t,
        [code('a', x: 0, y: 300), code('b', x: 700, y: 300), note('n1', x: 300, y: 280, w: 240, h: 88)],
        edges: [const Edge(id: 'e1', source: 'a', target: 'b')],
      );
      await h.clickNote(t, 'n1', offset: const Offset(30, 60));
      expect(h.controller.selectedNodeId, 'n1');
      final g = h.canvas.graph!;
      final y = g['a']!.outPortFor('source').dy;
      expect(y, inInclusiveRange(300, 368), reason: 'the edge crosses the note');
      final onEdge = Offset(420, y);
      expect(hitsEditor(t, onEdge), isFalse);

      await t.tapAt(onEdge);
      await NoteHarness.settle(t);

      expect(h.controller.selectedEdgeId, 'e1');
      await h.dispose(t);
    });

    testWidgets('the toolbar is part of the canvas (clipped to it) and under a node lying over it', (t) async {
      final h = await NoteHarness.start(t, [note('n1', x: 100, y: 200), code('c1', x: 0, y: 120)]);
      await h.clickNote(t, 'n1', offset: const Offset(200, 40));
      expect(h.controller.selectedNodeId, 'n1');
      final toolbar = find.byType(NoteEditorToolbar);
      expect(find.descendant(of: find.byType(WorkflowCanvas), matching: toolbar), findsOneWidget);
      expect(find.ancestor(of: toolbar, matching: find.byType(ClipRect)), findsWidgets);

      final bar = t.getRect(toolbar);
      final covered = h.canvas.graph!['c1']!.rect.intersect(bar);
      expect(covered.isEmpty, isFalse, reason: 'the code node lies over part of the toolbar');
      bool hitsToolbar(Offset at) => hits(t, at, toolbar);

      expect(hitsToolbar(covered.center), isFalse);
      expect(hitsToolbar(Offset(bar.right - 4, bar.center.dy)), isTrue);
      await h.dispose(t);
    });
  });

  group('typing in the selected note', () {
    testWidgets('Backspace deletes a character, not the note', (t) async {
      final h = await NoteHarness.start(t, [
        note('n1', x: 300, text: NoteText('hello', List.filled(5, NoteStyle.plain)).toLexical()),
      ]);
      await t.tapAt(const Offset(300 + 13 + 12 * 5 + 2, 100 + 19 + 6));
      await NoteHarness.settle(t);
      expect(h.editor.selection.baseOffset, 5);

      await t.sendKeyEvent(LogicalKeyboardKey.backspace);
      await NoteHarness.settle(t);

      expect(h['n1'], isNotNull);
      expect(h.editor.text, 'hell');
      await h.dispose(t);
    });

    testWidgets('Ctrl/Cmd+U toggles Lexical underline on the selection (kept in the note, not drawn)', (t) async {
      final h = await NoteHarness.start(t, [
        note('n1', x: 300, text: NoteText('hello', List.filled(5, NoteStyle.plain)).toLexical()),
      ]);
      await h.clickNote(t, 'n1');
      h.editor.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      await t.pump();
      final meta = defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.iOS;
      await t.sendKeyDownEvent(meta ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyU);
      await t.sendKeyUpEvent(meta ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft);
      await t.pump();

      expect(h.editor.styles.every((s) => s.has(NoteFormat.underline)), isTrue);
      expect(noteRunStyle(const NoteStyle(format: NoteFormat.underline)).decoration, isNull);
      await h.dispose(t);
    });

    testWidgets('an invalid link URL is refused with an error toast', (t) async {
      final h = await NoteHarness.start(t, [note('n1', x: 300)]);
      await h.clickNote(t, 'n1');
      h.editor.saveLink('not a url');
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));

      expect(find.text(DifyI18n.tr('workflow', 'nodes.note.editor.invalidUrl')), findsOneWidget);
      await t.pump(const Duration(seconds: 6));
      await h.dispose(t);
    });
  });

  test('a renderer drawing the live note as a widget under its scene takes the notes below it it overlaps along', () {
    final graph = CanvasGraph(layoutOf: const DifyCards().layoutOf);
    graph.sync(
      Document(
        nodes: [
          note('a', x: 0, y: 0), // under b, which is under the live note
          note('b', x: 200, y: 50),
          note('live', x: 400, y: 100),
          note('above', x: 450, y: 120), // later: stays above
          note('apart', x: 2000, y: 0),
          code('c', x: 420, y: 110),
        ],
      ),
    );
    final layer = LiveCardLayer(
      source: ValueNotifier(LiveCard(nodeId: 'live', builder: (_, _) => const SizedBox())),
      graph: graph,
      isTopAt: (_, _) => true,
      claim: (_) {},
    );
    expect([for (final n in layer.underlayStack(graph['live']!)) n.id], ['a', 'b', 'live']);
  });
}
