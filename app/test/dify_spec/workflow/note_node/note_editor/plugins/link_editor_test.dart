// dify-spec: web/app/components/workflow/note-node/note-editor/plugins/link-editor-plugin/__tests__/component.spec.tsx
// dify-spec: web/app/components/workflow/note-node/note-editor/plugins/link-editor-plugin/__tests__/hooks.spec.tsx
// dify-spec: web/app/components/workflow/note-node/note-editor/plugins/link-editor-plugin/__tests__/index.spec.tsx
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../dify_test_i18n.dart';
import '../../harness.dart';
import '../../../../../support/app_fonts.dart';

const _link = NoteStyle(url: 'https://dify.ai');

/// `hello` (a link to [url]) and ` world`, the caret in the link; [anchor] opens the popup on the link.
Future<NoteEditorController> _linkEditor(
  WidgetTester t, {
  String url = 'https://example.com',
  bool anchor = true,
}) async {
  final c = await pumpInEditor(
    t,
    Builder(
      builder: (context) {
        final s = NoteEditorScope.of(context);
        return ListenableBuilder(
          listenable: s.controller.store,
          builder: (context, _) => s.controller.store.linkAnchor == null
              ? const SizedBox()
              : NoteEditorScope(controller: s.controller, focusNode: s.focusNode, child: const LinkEditor()),
        );
      },
    ),
    value: lexical([('hello', NoteStyle(url: url)), (' world', NoteStyle.plain)]),
  );
  c.selection = const TextSelection.collapsed(offset: 2);
  await t.pump(Duration.zero);
  if (anchor) {
    c.store
      ..setLinkAnchor(const TextRange(start: 0, end: 5))
      ..setLinkOperatorShow(false);
  }
  await t.pump(Duration.zero);
  await t.pump(Duration.zero);
  return c;
}

bool _linked(NoteEditorController c, int at) => c.styles[at].url != null;

void main() {
  setUp(useDifyTestTranslator);
  // Real text widths: the popup's labels are Dify's i18n keys here.
  setUpAll(useAppFonts);

  group('link editor component', () {
    testWidgets('cancels a newly created empty link when pressing Escape', (t) async {
      final c = await _linkEditor(t, url: '');
      expect(find.byType(EditableText), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump(Duration.zero);
      expect(_linked(c, 0), isFalse, reason: 'unlinked');
    });

    testWidgets('cancels a newly created empty link when clicking outside the editor', (t) async {
      final c = await _linkEditor(t, url: '');
      await t.tapAt(const Offset(5, 5));
      await t.pump(Duration.zero);
      expect(_linked(c, 0), isFalse);
    });

    testWidgets('renders the inline link editor and saves the edited url', (t) async {
      final c = await _linkEditor(t);
      expect(find.text('https://example.com'), findsOneWidget);
      await t.tap(find.text('common.operation.ok'));
      await t.pump(Duration.zero);
      expect(c.styles[0].url, 'https://example.com');
      // The caret is still in the link: its actions show (useOpenLink after the update).
      expect(c.store.linkOperatorShow, isTrue);
    });

    testWidgets('saves the edited url when pressing Enter', (t) async {
      final c = await _linkEditor(t);
      await t.enterText(find.byType(EditableText), 'https://dify.ai/docs');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump(Duration.zero);
      expect(c.styles[0].url, 'https://dify.ai/docs');
    });
  });

  group('link editor hooks', () {
    group('useOpenLink', () {
      testWidgets('should show the link operator when the current selection is a link with a URL', (t) async {
        final c = NoteEditorController(value: lexical([('dify', _link)]));
        c.selection = const TextSelection.collapsed(offset: 2);
        await t.pump(Duration.zero);
        expect(c.store.linkAnchor, const TextRange(start: 0, end: 4));
        expect(c.store.linkOperatorShow, isTrue);
        c.dispose();
      });

      testWidgets('should clear the link operator when the current selection is not a link', (t) async {
        final c = NoteEditorController(value: lexical([('dify', _link), (' text', NoteStyle.plain)]));
        c.selection = const TextSelection.collapsed(offset: 2);
        await t.pump(Duration.zero);
        c.selection = const TextSelection.collapsed(offset: 7);
        await t.pump(Duration.zero);
        expect(c.store.linkAnchor, isNull);
        expect(c.store.linkOperatorShow, isFalse);
        c.dispose();
      });

      testWidgets('should show the link operator immediately when clicking a link target', (t) async {
        final c = NoteEditorController(value: lexical([('docs', const NoteStyle(url: 'https://dify.ai/docs'))]));
        c.selection = const TextSelection.collapsed(offset: 2);
        await t.pump(Duration.zero);
        c.store.dismissLinkEditor();
        c.handleClick();
        await t.pump(Duration.zero);
        expect(c.store.selectedLinkUrl, 'https://dify.ai/docs');
        expect(c.store.selectedIsLink, isTrue);
        expect(c.store.linkAnchor, const TextRange(start: 0, end: 4));
        expect(c.store.linkOperatorShow, isTrue);
        c.dispose();
      });

      testWidgets('should open the selected link in a new tab on meta or ctrl click', (t) async {
        final opened = <String>[];
        final c = NoteEditorController(value: lexical([('dify', _link)]), openUrl: opened.add);
        c.selection = const TextSelection.collapsed(offset: 2);
        c.handleClick(meta: true);
        await t.pump(Duration.zero);
        expect(opened, ['https://dify.ai']);
        c.dispose();
      });
    });

    group('useLink', () {
      test('should reject invalid URLs and show an error toast', () {
        var toasts = 0;
        final c = NoteEditorController(
          value: lexical([('dify', const NoteStyle(url: ''))]),
          onInvalidUrl: () => toasts++,
        );
        c.selection = const TextSelection.collapsed(offset: 2);
        c.saveLink('not-a-valid-url');
        expect(toasts, 1);
        expect(c.styles[0].url, '');
        c.dispose();
      });

      test('should save a valid link and clear the anchor element', () {
        final c = NoteEditorController(value: lexical([('dify', const NoteStyle(url: ''))]));
        c.selection = const TextSelection.collapsed(offset: 2);
        c.store.setLinkAnchor(const TextRange(start: 0, end: 4));
        c.saveLink('https://dify.ai/docs');
        expect(c.styles.map((s) => s.url).toSet(), {'https://dify.ai/docs'});
        expect(c.store.linkAnchor, isNull);
        c.dispose();
      });

      test('should remove the current link and clear the anchor element', () {
        final c = NoteEditorController(value: lexical([('dify', _link)]));
        c.selection = const TextSelection.collapsed(offset: 2);
        c.store.setLinkAnchor(const TextRange(start: 0, end: 4));
        c.unlink();
        expect(c.styles.map((s) => s.url).toSet(), {null});
        expect(c.store.linkAnchor, isNull);
        c.dispose();
      });
    });
  });

  group('LinkEditorPlugin', () {
    group('Visibility', () {
      testWidgets('should render nothing when no link anchor is selected', (t) async {
        await pumpInEditor(t, editorBox, value: plain('plain'));
        expect(find.byType(LinkEditor), findsNothing);
      });

      testWidgets('should render the link editor when the store has an anchor element', (t) async {
        final c = await pumpInEditor(
          t,
          editorBox,
          value: lexical([('docs', const NoteStyle(url: 'https://example.com'))]),
        );
        c.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
        await t.pump(Duration.zero);
        c.store.setLinkOperatorShow(false);
        await t.pump(Duration.zero);
        await t.pump(Duration.zero);
        expect(find.byType(LinkEditor), findsOneWidget);
        expect(find.text('https://example.com'), findsOneWidget);
      });
    });
  });
}
