// dify-spec: web/app/components/workflow/note-node/__tests__/hooks.spec.tsx
import 'dart:convert';

import 'package:dify_sf_app/src/editor/undo_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('useNote', () {
    testWidgets('updates theme and author visibility while saving note history entries', (t) async {
      final h = await NoteHarness.start(t, [note('note-1', theme: 'yellow', showAuthor: false)]);
      final a = NoteActions(h.controller, 'note-1', preferences: h.preferences);
      a.themeChange(NoteTheme.blue);
      a.showAuthorChange(true);
      expect(NoteData.of(h['note-1']!).theme, NoteTheme.blue);
      expect(NoteData.of(h['note-1']!).showAuthor, isTrue);
      expect(
        [for (final s in h.controller.undo.past) (s.event, s.nodeId)],
        [
          (HistoryEvent.noteChange, 'note-1'),
          (HistoryEvent.noteChange, 'note-1'),
        ],
      );
      expect(h.preferences.workflowNoteShowAuthor.value, 'true');
      await h.dispose(t);
    });

    testWidgets('serializes non-empty editor state and clears empty editor state', (t) async {
      final h = await NoteHarness.start(t, [note('note-2')]);
      final a = NoteActions(h.controller, 'note-2');
      a.editorChange(NoteText.fromLexical(plain('hello')));
      final stored = NoteData.of(h['note-2']!).text;
      expect((jsonDecode(stored) as Map)['root'], containsPair('type', 'root'));
      expect(NoteText.fromLexical(stored).text, 'hello');
      a.editorChange(NoteText.empty);
      expect(NoteData.of(h['note-2']!).text, '');
      await h.dispose(t);
    });
  });
}
