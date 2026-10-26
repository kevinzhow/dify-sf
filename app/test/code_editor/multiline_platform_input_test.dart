import 'package:dify_sf_app/src/workflow_editor/code_editor/code_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/code_editor/editor_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart' as re;

void main() {
  testWidgets('platform selection changes never replace a multi-line document', (t) async {
    const original = 'first\nsecond\nthird';
    await t.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 320,
          height: 220,
          child: CodeEditorView(value: original, language: CodeLanguage.javascript),
        ),
      ),
    );
    final view = t.state<CodeEditorViewState>(find.byType(CodeEditorView));
    final native = t.widget<re.CodeEditor>(find.byType(re.CodeEditor));
    native.focusNode!.requestFocus();
    native.controller!.selectAll();
    await t.pump();
    final remote = TextEditingValue.fromJSON(t.testTextInput.editingState!);
    t.testTextInput.updateEditingValue(remote.copyWith(selection: TextSelection.collapsed(offset: remote.text.length)));
    await t.pump();
    expect(view.text, original);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('platform full-state replacement preserves multi-line tabs and undo', (t) async {
    const original = 'first\nsecond';
    const replacement = '\t中文😀 e\u0301\n\t\tlast\n';
    await t.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 320,
          height: 220,
          child: CodeEditorView(value: original, language: CodeLanguage.javascript),
        ),
      ),
    );
    final view = t.state<CodeEditorViewState>(find.byType(CodeEditorView));
    final native = t.widget<re.CodeEditor>(find.byType(re.CodeEditor));
    native.focusNode!.requestFocus();
    native.controller!.selectAll();
    await t.pump();
    t.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: replacement,
        selection: TextSelection.collapsed(offset: replacement.length),
      ),
    );
    await t.pump();
    expect(view.text, replacement);
    native.controller!.undo();
    await t.pump();
    expect(view.text, original);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
