// dify-spec: web/app/components/workflow/__tests__/hotkeys.spec.ts
//
// shouldPreventWorkflowBrowserDefault, on both platforms' Mod (Cmd on a Mac, Ctrl elsewhere). WorkflowShortcuts
// handles the browser-only keys (Mod+S, Mod+D) so the web page does not see them.
import 'package:dify_sf_app/src/workflow_editor/context_menu/workflow_shortcuts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'context_menu/harness.dart';

bool _guard(LogicalKeyboardKey key, {required bool mac, bool mod = true, bool shift = false}) =>
    shouldPreventWorkflowBrowserDefault(
      key: key,
      control: mod && !mac,
      meta: mod && mac,
      shift: shift,
      mac: mac,
    );

void main() {
  group('workflow browser default hotkeys', () {
    for (final key in [
      LogicalKeyboardKey.keyD,
      LogicalKeyboardKey.keyZ,
      LogicalKeyboardKey.keyY,
      LogicalKeyboardKey.keyS,
    ]) {
      test('matches the exact Mod+%s browser guard', () {
        expect(_guard(key, mac: false), isTrue);
        expect(_guard(key, mac: true), isTrue);
      });
    }

    test('matches the alternate redo hotkey', () {
      expect(_guard(LogicalKeyboardKey.keyZ, mac: false, shift: true), isTrue);
      expect(_guard(LogicalKeyboardKey.keyZ, mac: true, shift: true), isTrue);
    });

    test('does not match plain or over-modified keys', () {
      expect(_guard(LogicalKeyboardKey.keyS, mac: false, mod: false), isFalse);
      expect(_guard(LogicalKeyboardKey.keyS, mac: false, shift: true), isFalse);
      // Ctrl on a Mac is not Mod.
      expect(shouldPreventWorkflowBrowserDefault(key: LogicalKeyboardKey.keyS, control: true, mac: true), isFalse);
    });
  });

  group('the editor suppresses the browser-only keys', () {
    testWidgets('Mod+S and Mod+D are handled, also while typing; Mod+Z is left to a text field', (t) async {
      final h = await Harness.start(t, [node('n1')]);
      await t.pumpWidget(
        h.app(
          child: Localizations(
            locale: const Locale('en'),
            delegates: const [DefaultMaterialLocalizations.delegate, DefaultWidgetsLocalizations.delegate],
            child: const Material(
              child: Align(alignment: Alignment.bottomCenter, child: TextField()),
            ),
          ),
        ),
      );
      await t.tap(find.byType(TextField));
      await Harness.settle(t);
      Future<bool> ctrl(LogicalKeyboardKey k) async {
        await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        final handled = await t.sendKeyEvent(k);
        await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        return handled;
      }

      expect(await ctrl(LogicalKeyboardKey.keyS), isTrue);
      expect(await ctrl(LogicalKeyboardKey.keyD), isTrue);
      expect(h.doc.nodes, hasLength(1)); // nothing duplicated while typing
      await h.dispose(t);
    });
  });
}
