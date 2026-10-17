// dify-spec: web/app/components/workflow/note-node/note-editor/plugins/format-detector-plugin/__tests__/hooks.spec.tsx
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../harness.dart';

const _bold = NoteStyle(format: NoteFormat.bold);

void main() {
  group('format detector hook', () {
    group('Formatting Detection', () {
      test('should sync bold, italic, strikethrough, link, and bullet state from the current selection', () {
        // A list item: bold + strikethrough text inside a link.
        final c = NoteEditorController(
          value: lexical([
            (noteBullet, NoteStyle.plain),
            ('dify', const NoteStyle(format: NoteFormat.bold | NoteFormat.strikethrough, url: 'https://dify.ai')),
          ]),
        );
        c.selection = const TextSelection.collapsed(offset: 3);
        final s = c.store;
        expect(
          (s.selectedIsBold, s.selectedIsItalic, s.selectedIsStrikeThrough, s.selectedLinkUrl, s.selectedIsLink),
          (true, false, true, 'https://dify.ai', true),
        );
        expect(s.selectedIsBullet, isTrue);
        c.dispose();
      });

      test('should clear link and bullet state for a plain text selection triggered by selectionchange', () {
        final c = NoteEditorController(
          value: lexical([
            (noteBullet, NoteStyle.plain),
            ('link', const NoteStyle(url: 'https://dify.ai')),
            ('\nplain', NoteStyle.plain),
          ]),
        );
        c.selection = const TextSelection.collapsed(offset: 3);
        expect(c.store.selectedIsLink, isTrue);
        c.selection = const TextSelection.collapsed(offset: 8);
        expect((c.store.selectedLinkUrl, c.store.selectedIsLink, c.store.selectedIsBullet), ('', false, false));
        c.dispose();
      });

      test('should ignore format detection while the editor is composing', () {
        final c = NoteEditorController(value: lexical([('plain ', NoteStyle.plain), ('bold', _bold)]));
        c.selection = const TextSelection.collapsed(offset: 2);
        c.value = c.value.copyWith(
          selection: const TextSelection.collapsed(offset: 8),
          composing: const TextRange(start: 6, end: 8),
        );
        expect(c.store.selectedIsBold, isFalse);
        c.dispose();
      });

      test('should react to lexical update events', () {
        final c = NoteEditorController(value: plain('hello'));
        c.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
        expect(c.store.selectedIsBold, isFalse);
        c.formatText(NoteFormat.bold);
        expect(c.store.selectedIsBold, isTrue);
        expect(c.store.selectedIsItalic, isFalse);
        c.dispose();
      });
    });
  });
}
