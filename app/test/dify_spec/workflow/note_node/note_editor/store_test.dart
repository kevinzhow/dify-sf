// dify-spec: web/app/components/workflow/note-node/note-editor/__tests__/store.spec.tsx
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

void main() {
  group('note editor store', () {
    test('stores selection state and link metadata', () {
      final store = NoteEditorStore()
        ..setLinkOperatorShow(true)
        ..setSelectedIsBold(true)
        ..setSelectedIsItalic(true)
        ..setSelectedIsStrikeThrough(true)
        ..setSelectedLinkUrl('https://dify.ai')
        ..setSelectedIsLink(true)
        ..setSelectedIsBullet(true);
      expect(
        (
          store.linkOperatorShow,
          store.selectedIsBold,
          store.selectedIsItalic,
          store.selectedIsStrikeThrough,
          store.selectedLinkUrl,
          store.selectedIsLink,
          store.selectedIsBullet,
        ),
        (true, true, true, true, 'https://dify.ai', true, true),
      );
    });

    testWidgets('resolves the current selection parent as the link anchor element', (t) async {
      const link = TextRange(start: 2, end: 7);
      final store = NoteEditorStore(resolveAnchor: () => link);
      store.setLinkAnchor(true);
      expect(store.linkAnchor, isNull, reason: 'resolved after the update');
      await t.pump(Duration.zero);
      expect(store.linkAnchor, link);
      store.setLinkAnchor(false);
      expect(store.linkAnchor, isNull);
    });

    testWidgets('reads note editor state from context hooks', (t) async {
      final c = await pumpInEditor(
        t,
        Builder(
          builder: (context) {
            final store = NoteEditorScope.of(context).controller.store;
            return ListenableBuilder(
              listenable: store,
              builder: (context, _) => Text('${store.selectedIsBold}'),
            );
          },
        ),
      );
      c.store.setSelectedIsBold(true);
      await t.pump(Duration.zero);
      expect(find.text('true'), findsOneWidget);
      expect(NoteEditorScope.of(t.element(find.text('true'))).controller, same(c));
    });

    testWidgets('keeps a dismissed link closed when an earlier anchor request finishes', (t) async {
      const link = TextRange(start: 0, end: 4);
      final store = NoteEditorStore(resolveAnchor: () => link);
      store.setLinkAnchor(true);
      store.dismissLinkEditor();
      await t.pump(Duration.zero);
      expect(store.linkAnchor, isNull);
      expect(store.linkOperatorShow, isFalse);
      store.setLinkAnchor(link);
      expect(store.linkAnchor, link);
      expect(store.dismissedLinkKey, isNull);
    });

    testWidgets('throws when the note editor store provider is missing', (t) async {
      Object? error;
      await t.pumpWidget(
        Builder(
          builder: (context) {
            try {
              NoteEditorScope.of(context);
            } catch (e) {
              error = e;
            }
            return const SizedBox();
          },
        ),
      );
      expect(
        error,
        isA<StateError>().having((e) => e.message, 'message', 'Missing NoteEditorContext.Provider in the tree'),
      );
    });
  });
}
