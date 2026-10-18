// dify-spec: web/app/components/workflow/hooks/__tests__/use-shortcuts.spec.ts
//
// The canvas shortcuts (useWorkflowHotkeys) are WorkflowShortcuts: Delete removes the selection (handleNodesDelete,
// then handleEdgeDelete), Ctrl/Cmd+C copies the selected (bundled) nodes; neither while a text field has the focus.
// The other cases are in operator/shortcuts_test.dart.
import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../context_menu/harness.dart';

const _edges = [Edge(id: 'e1', source: 'n1', sourceHandle: 'source', target: 'n2', targetHandle: 'target')];

/// [child] at the bottom of the editor area (with Material's localizations); the area itself has the focus, as
/// the canvas has after a click.
Widget _material(Widget child) => Localizations(
  locale: const Locale('en'),
  delegates: const [DefaultMaterialLocalizations.delegate, DefaultWidgetsLocalizations.delegate],
  child: Material(
    type: MaterialType.transparency,
    child: Stack(
      children: [
        const Positioned.fill(child: Focus(autofocus: true, child: SizedBox.expand())),
        Align(alignment: Alignment.bottomCenter, child: child),
      ],
    ),
  ),
);

void main() {
  group('useShortcuts', () {
    testWidgets('deletes selected nodes and edges only outside editable inputs', (t) async {
      final h = await Harness.start(t, [node('n1'), node('n2', x: 300), node('n3', x: 600)], edges: _edges);
      await t.pumpWidget(h.app(child: _material(const TextField())));
      await Harness.settle(t);

      h.canvas.selection.selectEdge('e1');
      await h.key(t, LogicalKeyboardKey.delete);
      expect(h.doc.edges, isEmpty);
      h.select(['n1', 'n2']);
      await h.key(t, LogicalKeyboardKey.delete);
      expect(h.doc.nodes.keys, ['n3']);

      // Typing in a field: Delete is the field's.
      await t.tap(find.byType(TextField));
      await Harness.settle(t);
      h.select(['n3']);
      h.controller.selectNode('n3');
      await h.key(t, LogicalKeyboardKey.delete);
      expect(h.doc.nodes.keys, ['n3']);
      await h.dispose(t);
    });

    testWidgets('copies bundled nodes even when an incidental text selection exists outside the workflow canvas', (
      t,
    ) async {
      final h = await Harness.start(t, [node('n1'), node('n2', x: 300)]);
      // Text elsewhere on the page, selectable but not focused.
      await t.pumpWidget(h.app(child: _material(const SelectableText('Selected browser text'))));
      await Harness.settle(t);
      h.select(['n1', 'n2']);
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyC);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await Harness.settle(t);
      expect(h.clipboard, isNotNull);
      expect(h.clipboard, contains('n1'));
      expect(h.clipboard, contains('n2'));
      await h.dispose(t);
    });
  });
}
