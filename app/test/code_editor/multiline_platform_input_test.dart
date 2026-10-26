import 'package:dify_sf_app/src/workflow_editor/code_editor/code_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/code_editor/editor_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart' as re;

import '../support/code_editor_input.dart';

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
  testWidgets('canonical full-state replacement preserves multi-line tabs and undo', (t) async {
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
    await enterCodeEditorText(t, replacement);
    await t.pump();
    expect(view.text, replacement);
    native.controller!.undo();
    await t.pump();
    expect(view.text, original);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('replacement identical to the platform base line still replaces the selected document', (t) async {
    const original = 'first\nsecond';
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
    await enterCodeEditorText(t, 'first');
    await t.pump();
    expect(view.text, 'first');
    t.widget<re.CodeEditor>(find.byType(re.CodeEditor)).controller!.undo();
    await t.pump();
    expect(view.text, original);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('a focused editor keeps readonly selection and restores editing when readonly changes', (t) async {
    var readOnly = false;
    late StateSetter rebuild;
    await t.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return SizedBox(
              width: 320,
              height: 220,
              child: CodeEditorView(value: 'original', language: CodeLanguage.javascript, readOnly: readOnly),
            );
          },
        ),
      ),
    );
    final native = t.widget<re.CodeEditor>(find.byType(re.CodeEditor));
    native.focusNode!.requestFocus();
    await t.pump();
    expect(t.testTextInput.hasAnyClients, isTrue);
    rebuild(() => readOnly = true);
    await t.pump();
    expect(t.testTextInput.hasAnyClients, isTrue);
    expect(t.testTextInput.setClientArgs?['readOnly'], isTrue);
    t.testTextInput.updateEditingValue(const TextEditingValue(text: 'forbidden'));
    await t.pump();
    expect(t.state<CodeEditorViewState>(find.byType(CodeEditorView)).text, 'original');
    rebuild(() => readOnly = false);
    await t.pump();
    expect(t.testTextInput.hasAnyClients, isTrue);
    await enterCodeEditorText(t, 'restored');
    await t.pump();
    expect(t.state<CodeEditorViewState>(find.byType(CodeEditorView)).text, 'restored');
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
