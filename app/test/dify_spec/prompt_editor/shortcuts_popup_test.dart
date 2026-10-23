// dify-spec: web/app/components/base/prompt-editor/plugins/shortcuts-popup-plugin/__tests__/index.spec.tsx
//
// ShortcutsPopupPlugin is the editor's `shortcutPopups`: a hotkey pressed while the editor has focus opens a
// DifyFloating popup in the root overlay (Dify: a portal on document.body), at the caret or beside the workflow's
// right panel.
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Finder _empty() => find.text(shortcutsEmptyContent);

Future<void> _render(
  WidgetTester t, {
  Object hotkey = 'mod+/',
  ShortcutPopupDisplayMode displayMode = ShortcutPopupDisplayMode.selection,
  Widget Function(BuildContext, VoidCallback, ShortcutPopupInsertHandler)? builder,
  VoidCallback? onOpen,
  VoidCallback? onClose,
  Widget Function(Widget editor)? wrap,
}) async {
  final editor = DifyPromptEditor(
    shortcutPopups: [
      ShortcutPopup(hotkey: hotkey, displayMode: displayMode, builder: builder, onOpen: onOpen, onClose: onClose),
    ],
  );
  await render(t, wrap == null ? editor : wrap(editor));
}

/// Focuses the editor and presses [key] with [modifiers] held.
Future<void> _focusAndTrigger(
  WidgetTester t,
  LogicalKeyboardKey key, {
  List<LogicalKeyboardKey> modifiers = const [LogicalKeyboardKey.controlLeft],
  bool focus = true,
}) async {
  if (focus) await focusAt(t);
  for (final m in modifiers) {
    await t.sendKeyDownEvent(m);
  }
  await t.sendKeyEvent(key);
  for (final m in modifiers.reversed) {
    await t.sendKeyUpEvent(m);
  }
  await t.pump();
  await t.pump();
}

const _ctrl = [LogicalKeyboardKey.controlLeft];
const _meta = [LogicalKeyboardKey.metaLeft];

/// Renders with [hotkey], presses [key] with [modifiers] and says whether the popup opened.
Future<bool> _opens(
  WidgetTester t,
  Object hotkey,
  LogicalKeyboardKey key, [
  List<LogicalKeyboardKey> modifiers = _ctrl,
]) async {
  await _render(t, hotkey: hotkey);
  await _focusAndTrigger(t, key, modifiers: modifiers);
  return _empty().evaluate().isNotEmpty;
}

void main() {
  group('ShortcutsPopupPlugin', () {
    testWidgets('does not render popup when never opened', (t) async {
      await _render(t);
      expect(_empty(), findsNothing);
    });

    testWidgets('opens on hotkey when editor is focused', (t) async {
      await _render(t);
      await _focusAndTrigger(t, LogicalKeyboardKey.slash);
      expect(_empty(), findsOneWidget);
    });

    testWidgets('does not open when editor is not focused', (t) async {
      await _render(t);
      await _focusAndTrigger(t, LogicalKeyboardKey.slash, focus: false);
      expect(_empty(), findsNothing);
    });

    testWidgets('closes on Escape', (t) async {
      await _render(t);
      await _focusAndTrigger(t, LogicalKeyboardKey.slash);
      expect(_empty(), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      expect(_empty(), findsNothing);
    });

    testWidgets('closes on click outside', (t) async {
      await _render(t);
      await _focusAndTrigger(t, LogicalKeyboardKey.slash);
      expect(_empty(), findsOneWidget);
      // A press in the editor is outside the popup.
      await t.tapAt(t.getTopLeft(find.byType(DifyPromptEditor)) + const Offset(4, 4));
      await t.pump();
      expect(_empty(), findsNothing);
    });

    testWidgets('does not close on mousedown inside a Base UI portal overlay', (t) async {
      var picked = 0;
      await _render(
        t,
        builder: (context, close, _) => DifyDropdownMenu(
          builder: (context, c) => TextButton(onPressed: c.toggle, child: const Text('open menu')),
          children: [DifyMenuItem(onSelect: () => picked++, child: const Text('portal-child'))],
        ),
      );
      await _focusAndTrigger(t, LogicalKeyboardKey.slash);
      await t.tap(find.text('open menu'));
      await t.pump();
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      // The menu is a popup of its own in the overlay; a press in it is not outside the shortcut popup.
      await t.tap(find.text('portal-child'));
      await t.pump();
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(picked, 1);
      expect(find.text('open menu'), findsOneWidget);
    });

    testWidgets('falls back to document.body when container is not provided', (t) async {
      var pressed = 0;
      await _render(
        t,
        wrap: (editor) => ClipRect(child: SizedBox(width: 200, height: 30, child: editor)),
        builder: (context, close, _) => SizedBox(
          width: 300,
          height: 200,
          child: TextButton(onPressed: () => pressed++, child: const Text('inside popup')),
        ),
      );
      await _focusAndTrigger(t, LogicalKeyboardKey.slash);
      // The popup is in the window's overlay: not clipped by the editor's box, and it takes presses there.
      final popup = t.getRect(find.byKey(const Key('shortcuts-popup')));
      expect(popup.height, 200);
      expect(popup.bottom, greaterThan(30));
      await t.tapAt(Offset(popup.center.dx, popup.bottom - 10));
      expect(pressed, 1);
    });

    testWidgets('clips the popup viewport so child popups own their internal scrolling', (t) async {
      await _render(t);
      await _focusAndTrigger(t, LogicalKeyboardKey.slash);
      expect(
        find.descendant(of: find.byKey(const Key('shortcuts-popup')), matching: find.byType(ClipRRect)),
        findsOneWidget,
      );
    });

    testWidgets('can render fixed next to the workflow panel instead of following the cursor', (t) async {
      t.view.physicalSize = const Size(1200, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final panelKey = GlobalKey();
      await _render(
        t,
        displayMode: ShortcutPopupDisplayMode.workflowPanelAdjacentCenter,
        builder: (context, close, _) => const SizedBox(width: 300, height: 100),
        wrap: (editor) => WorkflowRightPanelScope(
          panelKey: panelKey,
          child: SizedBox(
            width: 1200,
            height: 900,
            child: Stack(
              children: [
                SizedBox(width: 400, child: editor),
                Positioned(
                  left: 800,
                  top: 56,
                  width: 400,
                  height: 840,
                  child: SizedBox(key: panelKey),
                ),
              ],
            ),
          ),
        ),
      );
      await _focusAndTrigger(t, LogicalKeyboardKey.slash);
      final popup = t.getRect(find.byKey(const Key('shortcuts-popup')));
      // `right: 404px` (the panel's left edge less 4), `top: 474px` with `translateY(-50%)`.
      expect(popup.right, 1200 - 404);
      expect(popup.center.dy, 474);
      final box = t.widget<ShortcutPopupBox>(find.byType(ShortcutPopupBox));
      expect(box.maxWidth, 400);
      expect(box.maxHeight, 836);
    });

    testWidgets('matches a string hotkey like "mod+/"', (t) async {
      expect(await _opens(t, 'mod+/', LogicalKeyboardKey.slash, _meta), isTrue);
    });

    testWidgets('matches ctrl+/ when hotkey is "mod+/" (mod matches ctrl or meta)', (t) async {
      expect(await _opens(t, 'mod+/', LogicalKeyboardKey.slash), isTrue);
    });

    testWidgets('matches when hotkey is a string array like ["mod", "/"]', (t) async {
      expect(await _opens(t, const ['mod', '/'], LogicalKeyboardKey.slash), isTrue);
    });

    testWidgets('matches when hotkey is a nested array (any combo matches)', (t) async {
      expect(
        await _opens(t, const [
          ['ctrl', 'k'],
          ['meta', 'j'],
        ], LogicalKeyboardKey.keyK),
        isTrue,
      );
    });

    testWidgets('matches the second combo in a nested array', (t) async {
      expect(
        await _opens(
          t,
          const [
            ['ctrl', 'k'],
            ['meta', 'j'],
          ],
          LogicalKeyboardKey.keyJ,
          _meta,
        ),
        isTrue,
      );
    });

    testWidgets('does not match nested array when no combo matches', (t) async {
      expect(
        await _opens(t, const [
          ['ctrl', 'k'],
          ['meta', 'j'],
        ], LogicalKeyboardKey.keyX),
        isFalse,
      );
    });

    testWidgets('matches when hotkey is a custom function returning true', (t) async {
      expect(await _opens(t, (HotkeyEvent e) => e.key == 'F1', LogicalKeyboardKey.f1, const []), isTrue);
    });

    testWidgets('does not match when custom function returns false', (t) async {
      expect(await _opens(t, (HotkeyEvent e) => false, LogicalKeyboardKey.f2, const []), isFalse);
    });

    testWidgets('matches meta/cmd/command aliases', (t) async {
      expect(await _opens(t, 'cmd+k', LogicalKeyboardKey.keyK, _meta), isTrue);
    });

    testWidgets('matches "command" alias for meta', (t) async {
      expect(await _opens(t, 'command+k', LogicalKeyboardKey.keyK, _meta), isTrue);
    });

    testWidgets('does not match meta alias when meta is not pressed', (t) async {
      expect(await _opens(t, 'cmd+k', LogicalKeyboardKey.keyK, const []), isFalse);
    });

    testWidgets('matches alt/option alias', (t) async {
      expect(await _opens(t, 'alt+a', LogicalKeyboardKey.keyA, const [LogicalKeyboardKey.altLeft]), isTrue);
    });

    testWidgets('does not match alt alias when alt is not pressed', (t) async {
      expect(await _opens(t, 'alt+a', LogicalKeyboardKey.keyA, const []), isFalse);
    });

    testWidgets('matches shift alias', (t) async {
      expect(await _opens(t, 'shift+s', LogicalKeyboardKey.keyS, const [LogicalKeyboardKey.shiftLeft]), isTrue);
    });

    testWidgets('does not match shift alias when shift is not pressed', (t) async {
      expect(await _opens(t, 'shift+s', LogicalKeyboardKey.keyS, const []), isFalse);
    });

    testWidgets('matches ctrl alias', (t) async {
      expect(await _opens(t, 'ctrl+b', LogicalKeyboardKey.keyB), isTrue);
    });

    testWidgets('does not match ctrl alias when ctrl is not pressed', (t) async {
      expect(await _opens(t, 'ctrl+b', LogicalKeyboardKey.keyB, const []), isFalse);
    });

    testWidgets('normalizes space key to "space" for matching', (t) async {
      expect(await _opens(t, 'ctrl+space', LogicalKeyboardKey.space), isTrue);
    });

    testWidgets('does not match when expected key does not match pressed key', (t) async {
      expect(await _opens(t, 'ctrl+z', LogicalKeyboardKey.keyX), isFalse);
    });

    testWidgets('renders children as ReactNode when provided', (t) async {
      await _render(t, builder: (context, close, insert) => const Text('My Content', key: Key('custom-content')));
      await _focusAndTrigger(t, LogicalKeyboardKey.slash);
      expect(find.byKey(const Key('custom-content')), findsOneWidget);
      expect(find.text('My Content'), findsOneWidget);
    });

    testWidgets('renders children as render function and provides close/onInsert', (t) async {
      VoidCallback? gotClose;
      ShortcutPopupInsertHandler? gotInsert;
      await _render(
        t,
        builder: (context, close, insert) {
          gotClose = close;
          gotInsert = insert;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(key: const Key('close-btn'), onPressed: close, child: const Text('close')),
              TextButton(key: const Key('insert-btn'), onPressed: () {}, child: const Text('insert')),
            ],
          );
        },
      );
      await _focusAndTrigger(t, LogicalKeyboardKey.slash);
      expect(find.byKey(const Key('close-btn')), findsOneWidget);
      expect(find.byKey(const Key('insert-btn')), findsOneWidget);
      expect(gotClose, isNotNull);
      expect(gotInsert, isNotNull);
    });

    testWidgets('renders SHORTCUTS_EMPTY_CONTENT when children is undefined', (t) async {
      await _render(t);
      await _focusAndTrigger(t, LogicalKeyboardKey.slash);
      expect(_empty(), findsOneWidget);
    });

    testWidgets('calls close after insert via children render function', (t) async {
      final inserted = <String>[];
      await _render(
        t,
        builder: (context, close, insert) => TextButton(
          key: const Key('insert-btn'),
          onPressed: () => insert(CallbackPromptEditorCommand(inserted.add, 'payload')),
          child: const Text('insert'),
        ),
      );
      await _focusAndTrigger(t, LogicalKeyboardKey.slash);
      await t.tap(find.byKey(const Key('insert-btn')));
      await t.pump();
      expect(inserted, ['payload']);
      expect(find.byKey(const Key('insert-btn')), findsNothing);
    });

    testWidgets('calls close via children render function close callback', (t) async {
      await _render(
        t,
        builder: (context, close, insert) =>
            TextButton(key: const Key('close-via-fn'), onPressed: close, child: const Text('close')),
      );
      await _focusAndTrigger(t, LogicalKeyboardKey.slash);
      await t.tap(find.byKey(const Key('close-via-fn')));
      await t.pump();
      expect(find.byKey(const Key('close-via-fn')), findsNothing);
    });

    testWidgets('calls onOpen when popup opens', (t) async {
      var opens = 0;
      await _render(t, onOpen: () => opens++);
      await _focusAndTrigger(t, LogicalKeyboardKey.slash);
      expect(opens, 1);
    });

    testWidgets('calls onClose when popup closes', (t) async {
      var closes = 0;
      await _render(t, onClose: () => closes++);
      await _focusAndTrigger(t, LogicalKeyboardKey.slash);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      expect(closes, 1);
    });

    testWidgets('does not close on mousedown inside the portal', (t) async {
      await _render(
        t,
        builder: (context, close, insert) =>
            const SizedBox(key: Key('portal-inner'), width: 120, height: 60, child: Text('inner')),
      );
      await _focusAndTrigger(t, LogicalKeyboardKey.slash);
      await t.tap(find.byKey(const Key('portal-inner')));
      await t.pump();
      expect(find.byKey(const Key('portal-inner')), findsOneWidget);
    });

    testWidgets('prevents default and stops propagation on Escape when open', (t) async {
      final outer = <LogicalKeyboardKey>[];
      await _render(
        t,
        wrap: (editor) => Focus(
          onKeyEvent: (_, e) {
            if (e is KeyDownEvent) outer.add(e.logicalKey);
            return KeyEventResult.ignored;
          },
          child: editor,
        ),
      );
      await _focusAndTrigger(t, LogicalKeyboardKey.slash);
      outer.clear();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      expect(_empty(), findsNothing);
      expect(outer, isNot(contains(LogicalKeyboardKey.escape)));
    });

    testWidgets('matches hotkey with multiple modifiers: ctrl+shift+k', (t) async {
      expect(
        await _opens(t, 'ctrl+shift+k', LogicalKeyboardKey.keyK, const [
          LogicalKeyboardKey.controlLeft,
          LogicalKeyboardKey.shiftLeft,
        ]),
        isTrue,
      );
    });

    testWidgets('matches "option" alias for alt', (t) async {
      expect(await _opens(t, 'option+o', LogicalKeyboardKey.keyO, const [LogicalKeyboardKey.altLeft]), isTrue);
    });

    testWidgets('does not match mod hotkey when neither ctrl nor meta is pressed', (t) async {
      expect(await _opens(t, 'mod+k', LogicalKeyboardKey.keyK, const []), isFalse);
    });

    testWidgets('does not crash when openPortal is called with null range', (t) async {
      // No selection to place the popup at (Dify: no DOM range and no saved one): it opens at the text's end.
      await _render(t);
      await focusAt(t);
      editorState(t).controller.selection = const TextSelection.collapsed(offset: -1);
      await _focusAndTrigger(t, LogicalKeyboardKey.slash, focus: false);
      expect(_empty(), findsOneWidget);
    });

    testWidgets('opens when hotkey is a modifier-only string (no key part)', (t) async {
      await _render(t, hotkey: 'ctrl');
      await focusAt(t);
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      await t.pump();
      expect(_empty(), findsOneWidget);
    });
  });
}
