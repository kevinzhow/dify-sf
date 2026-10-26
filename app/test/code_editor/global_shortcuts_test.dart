import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/code_editor/editor_view.dart';
import 'package:dify_sf_app/src/workflow_editor/code_editor/language.dart';
import 'package:dify_sf_app/src/workflow_editor/header/hotkey.dart';
import 'package:dify_sf_app/src/workflow_editor/operator/operator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart' as re;

import '../dify_spec/workflow/context_menu/harness.dart';
import '../dify_spec/workflow/operator/operator_harness.dart';
import '../support/code_editor_input.dart';

void main() {
  for (final readOnly in [false, true]) {
    testWidgets('native editor owns global commands (readOnly=$readOnly)', (t) async {
      const source = '\t中文😀 e\u0301\n\t\tlast\n';
      final h = await Harness.start(t, [node('n1')]);
      final history = TestHistory(past: 1);
      var pageActions = 0;
      await t.pumpWidget(
        h.app(
          child: MaterialApp(
            home: OperatorShortcuts(
              history: history,
              child: OperatorShortcutsTarget(
                canvas: h.canvas,
                child: PageHotkey(
                  hotkey: 'Alt+R',
                  onPressed: () => pageActions++,
                  child: CodeEditorView(value: source, language: CodeLanguage.javascript, readOnly: readOnly),
                ),
              ),
            ),
          ),
        ),
      );
      h.select(['n1']);
      final native = t.widget<re.CodeEditor>(find.byType(re.CodeEditor));
      native.focusNode!.requestFocus();
      await t.pump();
      expect(difyFocusInTextInput(), isTrue);
      Future<void> ctrl(LogicalKeyboardKey key) async {
        await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await t.sendKeyEvent(key);
        await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await Harness.settle(t);
      }

      await ctrl(LogicalKeyboardKey.keyA);
      await ctrl(LogicalKeyboardKey.keyC);
      expect(h.clipboard, source);
      await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyR);
      await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      expect(pageActions, 0);
      await t.sendKeyEvent(LogicalKeyboardKey.delete);
      await Harness.settle(t);
      expect(h.doc.nodes.keys, ['n1']);
      if (!readOnly) {
        expect(codeEditorText(t), '');
        await ctrl(LogicalKeyboardKey.keyZ);
        expect(codeEditorText(t), source);
        h.clipboard = 'paste\n中文';
        await ctrl(LogicalKeyboardKey.keyA);
        await ctrl(LogicalKeyboardKey.keyV);
        expect(codeEditorText(t), 'paste\n中文');
      } else {
        expect(codeEditorText(t), source);
      }
      expect(history.past, hasLength(1));
      expect(h.doc.nodes.keys, ['n1']);
      expect(t.takeException(), isNull);
      await h.dispose(t);
      history.dispose();
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  }
}
