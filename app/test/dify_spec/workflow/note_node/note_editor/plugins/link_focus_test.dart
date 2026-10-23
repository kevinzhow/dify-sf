// dify-spec: web/app/components/workflow/note-node/note-editor/plugins/link-editor-plugin/__tests__/focus.browser.spec.tsx
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../dify_test_i18n.dart';
import '../../harness.dart';
import '../../../../../support/app_fonts.dart';

const _edit = 'common.operation.edit', _unlink = 'workflow.nodes.note.editor.unlink', _ok = 'common.operation.ok';

/// Dify's Harness: a note whose text is a link `hello` (and ` world`, a link to [secondLinkUrl]), with a button
/// outside it.
Future<NoteEditorController> _harness(WidgetTester t, {String? secondLinkUrl}) async {
  late NoteEditorController c;
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            NoteEditorProvider(
              value: lexical([
                ('hello', const NoteStyle(url: 'https://example.com')),
                if (secondLinkUrl != null) (' ', NoteStyle.plain),
                if (secondLinkUrl != null) ('world', NoteStyle(url: secondLinkUrl)),
              ]),
              child: Builder(
                builder: (context) {
                  c = NoteEditorScope.of(context).controller;
                  return editorBox;
                },
              ),
            ),
            const SizedBox(height: 100),
            TextButton(onPressed: () {}, child: const Text('Outside action')),
          ],
        ),
      ),
    ),
  );
  await t.pump(Duration.zero);
  return c;
}

/// Focuses the note with the caret at [offset] (Dify clicks the note and moves the caret with the keyboard).
Future<void> _caret(WidgetTester t, NoteEditorController c, int offset) async {
  await t.tap(find.byType(EditableText));
  await t.pump(Duration.zero);
  c.selection = TextSelection.collapsed(offset: offset);
  await t.pump(Duration.zero);
  await t.pump(Duration.zero);
}

FocusNode get _primary => FocusManager.instance.primaryFocus!;
bool _noteFocused(NoteEditorController c) => _primary.context?.findAncestorWidgetOfExactType<NoteEditor>() != null;
bool get _urlFocused => _primary.debugLabel == 'note link url';
bool get _urlInputShown =>
    find.text('workflow.nodes.note.editor.enterUrl').evaluate().isNotEmpty ||
    find.byType(LinkEditor).evaluate().isNotEmpty && find.text(_ok).evaluate().isNotEmpty;
bool get _operatorShown => find.text(_edit).evaluate().isNotEmpty;

Future<void> _key(WidgetTester t, LogicalKeyboardKey k) async {
  await t.sendKeyEvent(k);
  await t.pump(Duration.zero);
  await t.pump(Duration.zero);
}

void main() {
  setUp(useDifyTestTranslator);
  // Real text widths: the popup's labels are Dify's i18n keys here.
  setUpAll(useAppFonts);

  testWidgets('dismisses the entire link popup with Escape from the %s until explicitly reopened', (t) async {
    for (final target in ['URL input', 'confirm button', 'toolbar edit button']) {
      final c = await _harness(t);
      await _caret(t, c, 2);
      expect(_operatorShown, isTrue);
      if (target == 'toolbar edit button') {
        Focus.of(t.element(find.text(_edit))).requestFocus();
        await t.pump(Duration.zero);
      } else {
        await t.tap(find.text(_edit));
        await t.pump(Duration.zero);
        await t.pump(Duration.zero);
        expect(_urlFocused, isTrue, reason: 'the URL input');
        if (target == 'confirm button') {
          Focus.of(t.element(find.text(_ok))).requestFocus();
          await t.pump(Duration.zero);
        }
      }
      await _key(t, LogicalKeyboardKey.escape);
      expect(_noteFocused(c), isTrue, reason: target);
      expect(find.byType(LinkEditor), findsNothing, reason: target);
      // Typing keeps it closed.
      c.value = c.value.replaced(c.selection, 'X');
      await t.pump(Duration.zero);
      await t.pump(Duration.zero);
      expect(c.text, 'heXllo');
      expect(find.byType(LinkEditor), findsNothing, reason: target);
      // A click on the link reopens it.
      c.handleClick();
      await t.pump(Duration.zero);
      await t.pump(Duration.zero);
      expect(_operatorShown, isTrue, reason: target);
      await t.pumpWidget(const SizedBox());
    }
  });

  testWidgets('keeps focus on the outside action when it dismisses link editing', (t) async {
    final c = await _harness(t);
    await _caret(t, c, 2);
    await t.tap(find.text(_edit));
    await t.pump(Duration.zero);
    await t.pump(Duration.zero);
    expect(_urlInputShown, isTrue);
    await t.tap(find.text('Outside action'));
    await t.pump(Duration.zero);
    await t.pump(Duration.zero);
    expect(find.text(_ok), findsNothing);
    // Flutter buttons take no focus on a click: what counts is that the note does not pull it back.
    expect(_noteFocused(c), isFalse);
  });

  testWidgets('opens link editing with %s from the keyboard', (t) async {
    for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
      final c = await _harness(t);
      await _caret(t, c, 2);
      Focus.of(t.element(find.text(_edit))).requestFocus();
      await t.pump(Duration.zero);
      await _key(t, key);
      expect(_urlFocused, isTrue, reason: 'the URL input');
      expect(find.text(_ok), findsOneWidget);
      await _key(t, LogicalKeyboardKey.escape);
      expect(_noteFocused(c), isTrue);
      c.value = c.value.replaced(c.selection, 'X');
      expect(c.text, 'heXllo');
      await t.pumpWidget(const SizedBox());
    }
  });

  testWidgets('removes the selected link with %s from the keyboard', (t) async {
    for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
      final c = await _harness(t);
      await _caret(t, c, 2);
      Focus.of(t.element(find.text(_unlink))).requestFocus();
      await t.pump(Duration.zero);
      await _key(t, key);
      expect(c.styles.every((s) => s.url == null), isTrue);
      expect(_noteFocused(c), isTrue);
      c.value = c.value.replaced(c.selection, 'X');
      expect(c.text, 'heXllo');
      await t.pumpWidget(const SizedBox());
    }
  });

  testWidgets('opens a different link after dismissing the first when its URL is %s', (t) async {
    for (final second in ['https://second.example.com', 'https://example.com']) {
      final c = await _harness(t, secondLinkUrl: second);
      await _caret(t, c, 1);
      await t.tap(find.text(_edit));
      await t.pump(Duration.zero);
      await _key(t, LogicalKeyboardKey.escape);
      expect(_noteFocused(c), isTrue);
      expect(find.byType(LinkEditor), findsNothing);
      c.selection = TextSelection.collapsed(offset: c.text.length - 1);
      await t.pump(Duration.zero);
      await t.pump(Duration.zero);
      expect(_operatorShown, isTrue, reason: second);
      expect(c.store.selectedLinkUrl, second);
      await t.pumpWidget(const SizedBox());
    }
  });
}
