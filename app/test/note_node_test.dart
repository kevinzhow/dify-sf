// The note node in the editor: added from the control bar, edited in place (one write per typing pause), themed,
// resized, deleted, undone; its card on the canvas and its DSL shape.
import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/editor/undo_manager.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/clipboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/workflow/note_node/harness.dart';

String _tw(String key) => DifyI18n.tr('workflow', key);

void main() {
  testWidgets('Add Note: the note follows the pointer, a click places it selected, one undo step', (t) async {
    final h = await NoteHarness.start(t, const []);
    await t.tap(find.bySemanticsLabel(_tw('nodes.note.addNote')));
    await NoteHarness.settle(t);
    expect(find.byType(NoteCardView), findsOneWidget, reason: 'the candidate note follows the pointer');
    final at = h.canvas.view.toCanvas(const Offset(400, 300));
    await t.tapAt(const Offset(400, 300));
    await NoteHarness.settle(t);

    final added = h.doc.nodes.values.single;
    expect(isNoteCard(added), isTrue);
    expect((added.x, added.y), (at.dx.round(), at.dy.round()));
    expect(added.type, '');
    expect(NoteData.of(added).theme, NoteTheme.blue);
    expect(NoteData.of(added).size, const Size(240, 88));
    expect(NoteData.of(added).showAuthor, isTrue, reason: 'the stored preference is unset');
    expect(h.controller.selectedNodeId, added.id);
    expect(h.controller.undo.past.single.event, HistoryEvent.noteAdd);
    expect(h.overlayShown, isTrue, reason: 'the placed note is selected and editable');
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

    h.controller.undo.undo();
    await NoteHarness.settle(t);
    expect(h.doc.nodes, isEmpty);
    await h.dispose(t);
  });

  testWidgets('a note hidden author preference makes new notes without the author line', (t) async {
    final h = await NoteHarness.start(t, const []);
    h.preferences.workflowNoteShowAuthor.value = 'false';
    await t.tap(find.bySemanticsLabel(_tw('nodes.note.addNote')));
    await NoteHarness.settle(t);
    await t.tapAt(const Offset(400, 300));
    await NoteHarness.settle(t);
    expect(NoteData.of(h.doc.nodes.values.single).showAuthor, isFalse);
    await h.dispose(t);
  });

  group('editing a note in place', () {
    testWidgets('typing writes the Lexical state once per pause, against the version it began on', (t) async {
      final h = await NoteHarness.start(t, [note('n1', x: 300)]);
      await h.clickNote(t, 'n1');
      expect(h.overlayShown, isTrue);
      await t.enterText(find.byType(TextField), 'hello');
      await t.pump(const Duration(milliseconds: 300));
      await t.enterText(find.byType(TextField), 'hello world');
      await t.pump(const Duration(milliseconds: 300));
      expect(h.controller.writes, isEmpty, reason: 'still typing');
      await t.pump(const Duration(milliseconds: 800));
      expect([for (final (id, path) in h.controller.writes) '$id:${path.join('.')}'], ['n1:text']);
      final text = NoteData.of(h['n1']!).text;
      expect(NoteText.fromLexical(text).text, 'hello world');
      expect((jsonDecode(text) as Map)['root'], containsPair('type', 'root'));
      expect(h.controller.undo.past, isEmpty, reason: 'text is not in the workflow history, as in Dify');
      await h.dispose(t);
    });

    testWidgets('bold from the toolbar formats the selection', (t) async {
      final h = await NoteHarness.start(t, [note('n1', x: 300)]);
      await h.clickNote(t, 'n1');
      await t.enterText(find.byType(TextField), 'hello world');
      h.editor.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      await t.pump(Duration.zero);
      await t.tap(find.byKey(const ValueKey('note-command-bold')));
      await t.pump(const Duration(seconds: 1));
      final n = NoteText.fromLexical(NoteData.of(h['n1']!).text);
      expect(n.styles.first.has(NoteFormat.bold), isTrue);
      expect(n.styles.last.has(NoteFormat.bold), isFalse);
      await h.dispose(t);
    });

    testWidgets('the theme from the colour picker is one undo step', (t) async {
      final h = await NoteHarness.start(t, [note('n1', x: 300)]);
      await h.clickNote(t, 'n1', offset: const Offset(100, 4));
      await t.tap(find.bySemanticsLabel('blue'));
      await NoteHarness.settle(t);
      await t.tap(find.byKey(const ValueKey('note-theme-violet')));
      await NoteHarness.settle(t);
      expect(NoteData.of(h['n1']!).theme, NoteTheme.violet);
      expect(h.controller.undo.past.single.event, HistoryEvent.noteChange);
      h.controller.undo.undo();
      await NoteHarness.settle(t);
      expect(NoteData.of(h['n1']!).theme, NoteTheme.blue);
      await h.dispose(t);
    });

    testWidgets('dragging the corner resizes (at least 240 x 88), one undo step', (t) async {
      final h = await NoteHarness.start(t, [note('n1', x: 300)]);
      await h.clickNote(t, 'n1', offset: const Offset(100, 4));
      // The handle: 24 px, its bottom-right 1 px outside the card's.
      const corner = Offset(300 + 240 - 11, 100 + 88 - 11);
      await t.dragFrom(corner, const Offset(60, 40));
      await NoteHarness.settle(t);
      expect(NoteData.of(h['n1']!).size, const Size(300, 128));
      expect(h.controller.undo.past.single.event, HistoryEvent.nodeResize);
      await t.dragFrom(const Offset(300 + 300 - 11, 100 + 128 - 11), const Offset(-200, -200));
      await NoteHarness.settle(t);
      expect(NoteData.of(h['n1']!).size, const Size(240, 88));
      h.controller.undo.undo();
      h.controller.undo.undo();
      await NoteHarness.settle(t);
      expect(NoteData.of(h['n1']!).size, const Size(240, 88));
      expect(h.controller.undo.past, isEmpty);
      await h.dispose(t);
    });

    testWidgets('Delete from the "…" menu removes the note (NoteDelete); undo brings it back', (t) async {
      final h = await NoteHarness.start(t, [
        note('n1', x: 300, text: NoteText('keep', List.filled(4, NoteStyle.plain)).toLexical()),
      ]);
      await h.clickNote(t, 'n1', offset: const Offset(100, 4));
      await t.tap(find.bySemanticsLabel(DifyI18n.tr('common', 'operation.more')));
      await NoteHarness.settle(t);
      await t.tap(find.text(DifyI18n.tr('common', 'operation.delete')));
      await NoteHarness.settle(t);
      expect(h['n1'], isNull);
      expect(h.overlayShown, isFalse);
      expect(h.controller.undo.past.single.event, HistoryEvent.noteDelete);
      h.controller.undo.undo();
      await NoteHarness.settle(t);
      expect(NoteText.fromLexical(NoteData.of(h['n1']!).text).text, 'keep');
      await h.dispose(t);
    });

    testWidgets('the Delete key deletes the selected note while not typing', (t) async {
      final h = await NoteHarness.start(t, [note('n1', x: 300)]);
      await h.clickNote(t, 'n1', offset: const Offset(100, 4));
      await t.sendKeyEvent(LogicalKeyboardKey.delete);
      await NoteHarness.settle(t);
      expect(h['n1'], isNull);
      await h.dispose(t);
    });

    testWidgets('a click in the text of a note selects it and puts the caret there', (t) async {
      final h = await NoteHarness.start(t, [
        note('n1', x: 300, text: NoteText('hello world', List.filled(11, NoteStyle.plain)).toLexical()),
      ]);
      // The editor starts 13 px in and 19 px down; "hello world" in the 12 px test font is 12 px per character.
      await t.tapAt(const Offset(300 + 13 + 12 * 5 + 2, 100 + 19 + 6));
      await NoteHarness.settle(t);
      expect(h.controller.selectedNodeId, 'n1');
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'note editor');
      expect((h.editor.selection.isCollapsed, h.editor.selection.baseOffset), (true, 5));
      await h.dispose(t);
    });

    testWidgets('dragging a selected note by its strip moves it, the editor follows, one undo step', (t) async {
      final h = await NoteHarness.start(t, [note('n1', x: 300)]);
      await h.clickNote(t, 'n1', offset: const Offset(100, 4));
      final g = await t.startGesture(const Offset(400, 104));
      for (var i = 0; i < 5; i++) {
        await g.moveBy(const Offset(10, 6));
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(t.getTopLeft(find.byType(NoteNode)), const Offset(350, 130), reason: 'the live note follows the drag');
      await g.up();
      await NoteHarness.settle(t);
      expect((h['n1']!.x, h['n1']!.y), (350, 130));
      expect(h.controller.undo.past.single.event, HistoryEvent.nodeDragStop);
      expect(h.overlayShown, isTrue);
      await h.dispose(t);
    });

    testWidgets('another client\'s text comes in while nothing is pending', (t) async {
      final h = await NoteHarness.start(t, [note('n1', x: 300)]);
      await h.clickNote(t, 'n1', offset: const Offset(100, 4));
      h.controller.setConfig('n1', const [
        'text',
      ], VString(NoteText('remote', List.filled(6, NoteStyle.plain)).toLexical()));
      await NoteHarness.settle(t);
      expect(h.editor.text, 'remote');
      await h.dispose(t);
    });
  });

  group('note text (Lexical JSON)', () {
    test('reads paragraphs, bullet lists, links and font sizes, and writes them back as Lexical exports them', () {
      final value = lexical([
        ('Hi ', NoteStyle.plain),
        ('bold', const NoteStyle(format: NoteFormat.bold, fontSize: '14px')),
        ('\n', NoteStyle.plain),
        (noteBullet, NoteStyle.plain),
        ('docs', const NoteStyle(url: 'https://dify.ai')),
        ('\n', NoteStyle.plain),
        (noteBullet, NoteStyle.plain),
        ('two', NoteStyle.plain),
      ]);
      final root = (jsonDecode(value) as Map)['root'] as Map;
      final blocks = root['children'] as List;
      expect([for (final b in blocks) (b as Map)['type']], ['paragraph', 'list']);
      final bold = ((blocks[0] as Map)['children'] as List)[1] as Map;
      expect((bold['format'], bold['style'], bold['text']), (1, 'font-size: 14px;', 'bold'));
      final list = blocks[1] as Map;
      expect((list['listType'], list['tag']), ('bullet', 'ul'));
      final items = list['children'] as List;
      expect([for (final i in items) ((i as Map)['type'], i['value'])], [('listitem', 1), ('listitem', 2)]);
      final link = ((items[0] as Map)['children'] as List).single as Map;
      expect((link['type'], link['url'], link['rel']), ('link', 'https://dify.ai', 'noreferrer'));
      final back = NoteText.fromLexical(value);
      expect(back.text, 'Hi bold\n${noteBullet}docs\n${noteBullet}two');
      expect(back.toLexical(), value);
    });

    test('Enter continues a list, Enter in an empty item and Backspace at its start leave it', () {
      final c = NoteEditorController(value: lexical([(noteBullet, NoteStyle.plain), ('one', NoteStyle.plain)]));
      c.value = TextEditingValue(text: '${noteBullet}one\n', selection: const TextSelection.collapsed(offset: 5));
      expect(c.text, '${noteBullet}one\n$noteBullet');
      expect(c.selection.baseOffset, 6, reason: 'after the new marker');
      c.value = TextEditingValue(
        text: '${noteBullet}one\n$noteBullet\n',
        selection: const TextSelection.collapsed(offset: 7),
      );
      expect(c.text, '${noteBullet}one\n', reason: 'the empty item became a paragraph');
      c.value = const TextEditingValue(text: 'one', selection: TextSelection.collapsed(offset: 0));
      expect(c.text, 'one', reason: 'Backspace after the marker removes it');
      expect(c.store.selectedIsBullet, isFalse);
      c.dispose();
    });

    test('typed text takes the style before it, but not a link at its end', () {
      final c = NoteEditorController(
        value: lexical([('ab', const NoteStyle(format: NoteFormat.bold, url: 'u'))]),
      );
      c.value = const TextEditingValue(text: 'aXb', selection: TextSelection.collapsed(offset: 2));
      expect(c.styles[1], const NoteStyle(format: NoteFormat.bold, url: 'u'));
      c.value = const TextEditingValue(text: 'aXbY', selection: TextSelection.collapsed(offset: 4));
      expect(c.styles[3], const NoteStyle(format: NoteFormat.bold));
      c.dispose();
    });
  });
}
