// dify-spec: web/app/components/workflow/note-node/__tests__/index.spec.tsx
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';
import 'harness.dart';

const _small = 'workflow.nodes.note.editor.small';

Future<void> _pumpNote(WidgetTester t, NoteData data) async {
  await t.pumpWidget(
    MaterialApp(
      home: Center(child: NoteNode(data: data, selected: true)),
    ),
  );
  await t.pump(Duration.zero);
}

void main() {
  setUp(useDifyTestTranslator);

  group('NoteNode', () {
    testWidgets('should render the toolbar and author for a selected persistent note', (t) async {
      await _pumpNote(t, const NoteData(author: 'Alice'));
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text(_small), findsOneWidget);
      expect(find.ancestor(of: find.text(_small), matching: find.byType(NoteEditorToolbar)), findsOneWidget);
    });

    testWidgets('should hide the toolbar for temporary notes', (t) async {
      await _pumpNote(t, const NoteData(author: 'Alice', showAuthor: false, temp: true));
      expect(find.text(_small), findsNothing);
      expect(find.text('Alice'), findsNothing);
    });

    testWidgets('should clear the selected state when clicking outside the note', (t) async {
      final h = await NoteHarness.start(t, [note('note-1', x: 300)]);
      await h.clickNote(t, 'note-1');
      expect(h.controller.selectedNodeId, 'note-1');
      expect(h.overlayShown, isTrue);
      await t.tapAt(const Offset(150, 450));
      await NoteHarness.settle(t);
      expect(h.controller.selectedNodeId, isNull);
      expect(h.canvas.selection.nodes, isEmpty);
      expect(h.overlayShown, isFalse);
      await h.dispose(t);
    });
  });
}
