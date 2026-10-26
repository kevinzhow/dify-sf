import 'dart:ui' show SemanticsAction, Tristate;

import 'package:dify_sf_app/src/workflow_editor/code_editor/code_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/code_editor/editor_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final readOnly in [false, true]) {
    testWidgets('native editor exposes original UTF16 text, selection and readonly=$readOnly', (t) async {
      final semantics = t.ensureSemantics();
      try {
        final changes = <String>[];
        await t.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 320,
              height: 220,
              child: CodeEditorView(
                value: '\t中文😀\nnext',
                language: CodeLanguage.javascript,
                readOnly: readOnly,
                onChanged: changes.add,
              ),
            ),
          ),
        );
        final finder = find.byType(CodeEditorView);
        final state = t.state<CodeEditorViewState>(finder);
        final field = find.bySemanticsIdentifier('dify-code-editor-input');
        var node = t.getSemantics(field);
        var data = node.getSemanticsData();
        expect(data.flagsCollection.isTextField, isTrue);
        expect(data.flagsCollection.isEnabled, Tristate.isTrue);
        expect(data.flagsCollection.isMultiline, isTrue);
        expect(data.flagsCollection.isReadOnly, readOnly);
        expect(data.value, '\t中文😀\nnext');
        node.owner!.performAction(node.id, SemanticsAction.tap);
        await t.pump();
        node = t.getSemantics(field);
        node.owner!.performAction(node.id, SemanticsAction.setSelection, {'base': 1, 'extent': 5});
        await t.pump();
        expect(state.controller.selection, const TextSelection(baseOffset: 1, extentOffset: 5));
        data = t.getSemantics(field).getSemanticsData();
        expect(data.textSelection, const TextSelection(baseOffset: 1, extentOffset: 5));
        expect(data.hasAction(SemanticsAction.copy), isTrue);
        expect(data.hasAction(SemanticsAction.cut), !readOnly);
        expect(data.hasAction(SemanticsAction.setText), !readOnly);
        if (!readOnly) {
          node = t.getSemantics(field);
          node.owner!.performAction(node.id, SemanticsAction.setText, '\t更新😀\n');
          await t.pump();
          expect(state.text, '\t更新😀\n');
          expect(changes, ['\t更新😀\n']);
          expect(t.getSemantics(field).getSemanticsData().value, state.text);
        }
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      } finally {
        semantics.dispose();
      }
    });
  }
}
