import 'package:dify_sf_app/src/workflow_editor/code_editor/editor_view.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart' as re;

/// Send replacement text through the native editor's real platform input client.
/// WidgetTester.enterText is only for EditableText; Re-Editor is its own client.
Future<void> enterCodeEditorText(WidgetTester tester, String text, {Finder? within}) async {
  final editor = within == null
      ? find.byType(CodeEditorView)
      : find.descendant(of: within, matching: find.byType(CodeEditorView));
  final state = tester.state<CodeEditorViewState>(editor);
  final native = tester.widget<re.CodeEditor>(find.descendant(of: editor, matching: find.byType(re.CodeEditor)));
  native.focusNode!.requestFocus();
  await tester.pump();
  state.controller.selection = TextSelection(baseOffset: 0, extentOffset: state.text.length);
  await tester.pump();
  final remote = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: remote.text.replaceRange(remote.selection.start, remote.selection.end, text),
      selection: TextSelection.collapsed(offset: remote.selection.start + text.length),
    ),
  );
  await tester.pump();
}

String codeEditorText(WidgetTester tester) => tester.state<CodeEditorViewState>(find.byType(CodeEditorView)).text;
