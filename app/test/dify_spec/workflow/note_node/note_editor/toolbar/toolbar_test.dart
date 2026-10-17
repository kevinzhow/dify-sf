// dify-spec: web/app/components/workflow/note-node/note-editor/toolbar/__tests__/color-picker.spec.tsx
// dify-spec: web/app/components/workflow/note-node/note-editor/toolbar/__tests__/command.spec.tsx
// dify-spec: web/app/components/workflow/note-node/note-editor/toolbar/__tests__/font-size-selector.spec.tsx
// dify-spec: web/app/components/workflow/note-node/note-editor/toolbar/__tests__/hooks.spec.tsx
// dify-spec: web/app/components/workflow/note-node/note-editor/toolbar/__tests__/index.spec.tsx
// dify-spec: web/app/components/workflow/note-node/note-editor/toolbar/__tests__/operator.spec.tsx
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/controls.dart' show DifySwitch;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../dify_test_i18n.dart';
import '../../harness.dart';

const _small = 'workflow.nodes.note.editor.small',
    _medium = 'workflow.nodes.note.editor.medium',
    _large = 'workflow.nodes.note.editor.large',
    _more = 'common.operation.more';

Finder _option(NoteTheme t) => find.byKey(ValueKey('note-theme-${t.name}'));

Color? _commandBg(WidgetTester t, NoteCommandType type) =>
    (t
                .widget<Container>(
                  find
                      .descendant(
                        of: find.byKey(ValueKey('note-command-${type.name}')),
                        matching: find.byType(Container),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration?)
        ?.color;

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 3; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(useDifyTestTranslator);

  group('NoteEditor ColorPicker', () {
    testWidgets('should open the palette and apply the selected theme', (t) async {
      final picked = <NoteTheme>[];
      await pumpInEditor(t, NoteColorPicker(theme: NoteTheme.blue, onThemeChange: picked.add));
      await t.tap(find.bySemanticsLabel('blue'));
      await _settle(t);
      expect(
        find.byType(DifyPopoverSurface).evaluate().length +
            NoteTheme.values.where((x) => _option(x).evaluate().isNotEmpty).length,
        6,
      );
      await t.tap(_option(NoteTheme.values[5]));
      await _settle(t);
      expect(picked, [NoteTheme.violet]);
      expect(_option(NoteTheme.violet), findsNothing);
    });
  });

  group('NoteEditor Command', () {
    testWidgets('should highlight the active command and dispatch it on click', (t) async {
      final c = await pumpInEditor(
        t,
        const NoteCommand(NoteCommandType.bold),
        value: lexical([('bold', const NoteStyle(format: NoteFormat.bold))]),
      );
      c.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
      await t.pump(Duration.zero);
      expect(_commandBg(t, NoteCommandType.bold), DifyColors.stateAccentActive);
      await t.tap(find.byType(NoteCommand));
      await t.pump(Duration.zero);
      expect(c.styles.any((s) => s.has(NoteFormat.bold)), isFalse, reason: 'FORMAT_TEXT_COMMAND bold toggled it off');
    });

    testWidgets('should keep inactive commands unhighlighted', (t) async {
      final c = await pumpInEditor(t, const NoteCommand(NoteCommandType.link), value: plain('text'));
      c.selection = const TextSelection.collapsed(offset: 2);
      await t.pump(Duration.zero);
      expect(_commandBg(t, NoteCommandType.link), isNull);
    });
  });

  group('NoteEditor FontSizeSelector', () {
    testWidgets('should show the current font size label and request opening when clicked', (t) async {
      await pumpInEditor(t, const NoteFontSizeSelector(), value: plain('text'));
      await t.tap(find.text(_small));
      await _settle(t);
      expect(find.text(_medium), findsOneWidget, reason: 'the sizes are open');
    });

    testWidgets('should select a new font size and close the popup', (t) async {
      final c = await pumpInEditor(
        t,
        const NoteFontSizeSelector(),
        value: lexical([('text', const NoteStyle(fontSize: '14px'))]),
      );
      c.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
      await t.pump(Duration.zero);
      await t.tap(find.text(_medium));
      await _settle(t);
      expect(find.text(_medium), findsNWidgets(2), reason: 'the trigger and its option');
      await t.tap(find.text(_large));
      await _settle(t);
      expect(c.styles.map((s) => s.fontSize).toSet(), {'16px'});
      expect(find.text(_small), findsNothing, reason: 'closed');
    });

    testWidgets('should fall back to the small label when current font size is unknown', (t) async {
      final c = await pumpInEditor(
        t,
        const NoteFontSizeSelector(),
        value: lexical([('text', const NoteStyle(fontSize: '18px'))]),
      );
      c.selection = const TextSelection.collapsed(offset: 2);
      await t.pump(Duration.zero);
      expect(c.fontSize, '18px');
      expect(find.text(_small), findsOneWidget);
    });
  });

  group('note toolbar hooks', () {
    group('useCommand', () {
      test('should dispatch text formatting commands directly', () {
        final c = NoteEditorController(value: plain('hello'));
        c.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
        c
          ..formatText(NoteFormat.bold)
          ..formatText(NoteFormat.italic)
          ..formatText(NoteFormat.strikethrough);
        expect(c.styles.first.format, NoteFormat.bold | NoteFormat.italic | NoteFormat.strikethrough);
        c.dispose();
      });

      testWidgets('should open link editing when current selection is not already a link', (t) async {
        final c = NoteEditorController(value: plain('hello world'));
        c.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
        c.toggleLink();
        expect(c.styles.take(5).map((s) => s.url).toSet(), {''});
        await t.pump(Duration.zero);
        await t.pump(Duration.zero);
        expect(c.store.linkAnchor, const TextRange(start: 0, end: 5));
        expect(c.store.linkOperatorShow, isFalse, reason: 'the URL input');
        c.dispose();
      });

      test('should remove the link when the current selection is already within a link node', () {
        final c = NoteEditorController(value: lexical([('dify', const NoteStyle(url: 'https://dify.ai'))]));
        c.selection = const TextSelection.collapsed(offset: 2);
        c.toggleLink();
        expect(c.styles.map((s) => s.url).toSet(), {null});
        expect(c.store.linkAnchor, isNull);
        c.dispose();
      });

      test('should ignore link commands when the selection is not a range', () {
        final c = NoteEditorController(value: plain('hello'));
        c.selection = const TextSelection.collapsed(offset: -1);
        c.toggleLink();
        c.selection = const TextSelection.collapsed(offset: 2);
        c.toggleLink();
        expect(c.styles.map((s) => s.url).toSet(), {null});
        expect(c.store.linkAnchor, isNull);
        c.dispose();
      });

      test('should toggle bullet formatting on and off', () {
        final c = NoteEditorController(value: plain('item'));
        c.selection = const TextSelection.collapsed(offset: 2);
        c.toggleBullet();
        expect(c.text, '${noteBullet}item');
        expect(c.store.selectedIsBullet, isTrue);
        c.toggleBullet();
        expect(c.text, 'item');
        c.dispose();
      });
    });

    group('useFontSize', () {
      test('should expose font size state and update selection styling', () {
        final c = NoteEditorController(value: lexical([('text', const NoteStyle(fontSize: '16px'))]));
        c.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
        expect(c.fontSize, '16px');
        c.setFontSize('20px');
        expect(c.styles.map((s) => s.fontSize).toSet(), {'20px'});
        c.dispose();
      });

      testWidgets('should preserve the current selection when opening the selector', (t) async {
        final c = await pumpInEditor(t, const NoteFontSizeSelector(), value: plain('hello'));
        const sel = TextSelection(baseOffset: 1, extentOffset: 4);
        c.selection = sel;
        await t.pump(Duration.zero);
        await t.tap(find.text(_small));
        await _settle(t);
        expect(c.selection, sel);
      });

      test('should keep the default font size and avoid patching styles when the selection is not a range', () {
        final c = NoteEditorController(value: plain('text'));
        c.selection = const TextSelection.collapsed(offset: -1);
        expect(c.fontSize, '12px');
        c.setFontSize('20px');
        expect(c.styles.map((s) => s.fontSize).toSet(), {null});
        c.dispose();
      });
    });
  });

  group('NoteEditor Toolbar', () {
    testWidgets('should compose the toolbar controls and forward callbacks from color and operator actions', (t) async {
      final themes = <NoteTheme>[];
      var copies = 0, deletes = 0, duplicates = 0, authorChanges = 0;
      final c = await pumpInEditor(
        t,
        NoteEditorToolbar(
          theme: NoteTheme.blue,
          onThemeChange: themes.add,
          onCopy: () => copies++,
          onDuplicate: () => duplicates++,
          onDelete: () => deletes++,
          showAuthor: false,
          onShowAuthorChange: (_) => authorChanges++,
        ),
        value: lexical([('text', const NoteStyle(fontSize: '14px'))]),
      );
      c.selection = const TextSelection.collapsed(offset: 2);
      await t.pump(Duration.zero);
      expect(find.text(_medium), findsOneWidget);
      await t.tap(find.bySemanticsLabel('blue'));
      await _settle(t);
      await t.tap(_option(NoteTheme.values.last));
      await _settle(t);
      expect(themes, [NoteTheme.violet]);
      await t.tap(find.bySemanticsLabel(_more));
      await _settle(t);
      await t.tap(find.text('workflow.common.copy'));
      await _settle(t);
      expect(copies, 1);
      expect(find.byType(DifyMenuPopup), findsNothing);
      expect((deletes, duplicates, authorChanges), (0, 0, 0));
    });
  });

  group('NoteEditor Toolbar Operator', () {
    Future<List<String>> operator(WidgetTester t, {bool showAuthor = false}) async {
      final calls = <String>[];
      await pumpInEditor(
        t,
        NoteOperator(
          onCopy: () => calls.add('copy'),
          onDuplicate: () => calls.add('duplicate'),
          onDelete: () => calls.add('delete'),
          showAuthor: showAuthor,
          onShowAuthorChange: (v) => calls.add('showAuthor:$v'),
        ),
      );
      return calls;
    }

    testWidgets('triggers copy, duplicate, and delete from the opened menu', (t) async {
      final calls = await operator(t);
      for (final label in ['workflow.common.copy', 'workflow.common.duplicate', 'common.operation.delete']) {
        await t.tap(find.bySemanticsLabel(_more));
        await _settle(t);
        await t.tap(find.text(label));
        await _settle(t);
      }
      expect(calls, ['copy', 'duplicate', 'delete']);
    });

    testWidgets('keeps the menu open when toggling show author', (t) async {
      final calls = await operator(t, showAuthor: true);
      await t.tap(find.bySemanticsLabel(_more));
      await _settle(t);
      await t.tap(find.byType(DifySwitch));
      await _settle(t);
      expect(calls, ['showAuthor:false']);
      expect(find.text('workflow.nodes.note.editor.showAuthor'), findsOneWidget);
    });
  });
}
