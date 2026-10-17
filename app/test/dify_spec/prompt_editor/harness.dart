import 'package:dify_sf_app/src/workflow_editor/panel_fields/var_picker_model.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/component_picker.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dify_sf_app/src/i18n/dify_i18n.dart';

import '../dify_test_i18n.dart';

export '../dify_test_i18n.dart';

export 'package:dify_sf_app/src/workflow_editor/panel_fields/var_picker_model.dart' show VarGroup, PickerVar;

/// Renders [w] at the top-left of a 800 px wide page with Dify's test translator.
Future<void> render(WidgetTester t, Widget w, {double width = 600}) async {
  if (DifyI18n.current is! DifyTestTranslator) useDifyTestTranslator();
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, child: w),
        ),
      ),
    ),
  );
  await t.pump();
}

/// The editor's state.
DifyPromptEditorState editorState(WidgetTester t) => t.state<DifyPromptEditorState>(find.byType(DifyPromptEditor));

/// Focuses the editor and puts the caret at [offset] (the end by default).
Future<void> focusAt(WidgetTester t, [int? offset]) async {
  final s = editorState(t);
  s.focusNode.requestFocus();
  await t.pump();
  s.controller.selection = TextSelection.collapsed(offset: offset ?? s.controller.text.length);
  await t.pump();
}

/// Types [text] at the caret as the keyboard would.
Future<void> typeText(WidgetTester t, String text) async {
  final c = editorState(t).controller;
  for (final ch in text.split('')) {
    final sel = c.selection.isValid ? c.selection : TextSelection.collapsed(offset: c.text.length);
    t.testTextInput.updateEditingValue(
      TextEditingValue(
        text: c.text.replaceRange(sel.start, sel.end, ch),
        selection: TextSelection.collapsed(offset: sel.start + 1),
      ),
    );
    await t.pump();
  }
}

/// Workflow variables for the picker: an LLM node with `text` and a Start node with `query`.
const testVars = [
  VarGroup(nodeId: 'llm1', title: 'LLM', vars: [PickerVar('text', 'string')]),
  VarGroup(nodeId: 'start1', title: 'Start', vars: [PickerVar('query', 'string'), PickerVar('sys.query', 'string')]),
];

const testNodes = {
  'llm1': WorkflowNodeInfo(title: 'LLM', type: 'llm'),
  'start1': WorkflowNodeInfo(title: 'Start', type: 'start'),
  'sys': WorkflowNodeInfo(title: 'Start', type: 'start'),
};

/// The workflow variable block with [testVars].
const testVarBlock = WorkflowVariableBlockConfig(show: true, variables: testVars, workflowNodesMap: testNodes);

/// Whether the component picker menu is open.
bool menuOpen() => find.byType(ComponentPickerMenu).evaluate().isNotEmpty;

/// Renders [editor] around an own controller (for prompt changes that report block inserts and deletes).
Future<PromptEditorController> renderWithController(
  WidgetTester t,
  DifyPromptEditor Function(PromptEditorController c) editor,
) async {
  final c = PromptEditorController();
  addTearDown(c.dispose);
  await render(t, editor(c));
  return c;
}

/// Counts the blocks of [kind] in the editor text.
int blockCount(PromptEditorController c, PromptBlockKind kind) {
  var n = 0;
  for (var i = 0; i < c.text.length; i++) {
    if (c.blockAt(i)?.kind == kind) n++;
  }
  return n;
}

/// Selects the block at [offset] and deletes it with Backspace.
Future<void> deleteBlockAt(WidgetTester t, int offset) async {
  final s = editorState(t);
  s.focusNode.requestFocus();
  await t.pump();
  s.controller.selection = TextSelection(baseOffset: offset, extentOffset: offset + 1);
  await t.pump();
  await t.sendKeyEvent(LogicalKeyboardKey.backspace);
  await t.pump();
}
