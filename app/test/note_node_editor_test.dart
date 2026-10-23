// The note node wired into the editor (dify_editor.dart): the control bar's Add Note places a note, selected and
// editable in place.
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/editor/undo_manager.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/clipboard.dart';
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/note_node/note_node.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_fonts.dart';

String _tw(String key) => DifyI18n.tr('workflow', key);

void main() {
  testWidgets('Add Note in the editor: a click places the note, selected and editable; undo removes it', (t) async {
    await useAppFonts();
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final demo = DemoBackend(withBo: false);
    await t.pumpWidget(
      MaterialApp(
        home: EditorPage(backend: demo, docId: 'demo', clientId: 'me-abc123', journaled: false),
      ),
    );
    Future<void> settle([int ms = 1500]) async {
      for (var i = 0; i < ms ~/ 100; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    await settle(2000);
    final c = t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor)).controller;
    final before = c.doc.nodes.length;
    await t.tap(find.bySemanticsLabel(_tw('nodes.note.addNote')));
    await settle(300);
    await t.tapAt(const Offset(700, 760));
    await settle(600);

    final added = c.doc.nodes.values.where(isNoteCard).single;
    expect(c.doc.nodes.length, before + 1);
    expect(added.type, '');
    expect(added.title, '');
    expect(NoteData.of(added).theme, NoteTheme.blue);
    expect(NoteData.of(added).size, const Size(240, 88));
    expect(c.selectedNodeId, added.id);
    expect(c.undo.past.last.event, HistoryEvent.noteAdd);
    expect(find.byType(NoteNode), findsOneWidget, reason: 'the placed note is selected and editable');
    // Dify's DSL shape: React Flow type custom-note, data.type '' with the note's fields.
    final dsl = difyNodeOf(added);
    expect(dsl['type'], 'custom-note');
    expect(dsl['data'], {
      'desc': '',
      'text': '',
      'theme': 'blue',
      'author': '',
      'showAuthor': true,
      'width': 240,
      'height': 88,
      'type': '',
      'title': '',
    });

    c.undo.undo();
    await settle(300);
    expect(c.doc.nodes.values.where(isNoteCard), isEmpty);

    await t.pumpWidget(const SizedBox());
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  });
}
