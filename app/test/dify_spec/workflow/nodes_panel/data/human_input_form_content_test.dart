// dify-spec: web/app/components/workflow/nodes/human-input/components/__tests__/form-content.spec.tsx
//
// The real editor: Mod + / opens the input field dialog, Insert adds the input and its token in one edit (Dify's
// deferred form-input sync).
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/form_content.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

void main() {
  late List<(Map<String, Object?>, String)> inserts;
  late List<String> changes;

  setUp(() {
    inserts = [];
    changes = [];
  });

  Widget content({List<Object?> formInputs = const [], bool readonly = false, String value = 'Initial content'}) =>
      FormContent(
        nodeId: 'node-2',
        value: value,
        formInputs: formInputs,
        readonly: readonly,
        scope: const VarScope(),
        nodesMap: const {
          'node-1': WorkflowNodeInfo(title: 'Start', type: 'start'),
          'sys': WorkflowNodeInfo(title: 'workflow.blocks.start', type: 'start'),
          'node-2': WorkflowNodeInfo(title: 'Classifier', type: 'code'),
        },
        actions: FormContentActions(
          onChange: (v, _) => changes.add(v),
          onInsert: (p, c) => inserts.add((p, c)),
          onInputChange: (_) {},
          onRename: (_, _) {},
          onRemove: (_) {},
        ),
      );

  Finder editor() => find.descendant(of: find.byType(DifyPromptEditor).first, matching: find.byType(EditableText));

  Future<void> focusEditor(WidgetTester t) async {
    await t.tap(editor());
    await t.pump();
  }

  Future<void> modSlash(WidgetTester t) async {
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.slash);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump(const Duration(milliseconds: 300));
  }

  Finder nameField() => inputNamed(hiKey('insertInputField.saveResponseAs'));

  group('FormContent', () {
    testWidgets(
      'should build workflow node maps, show the hotkey tip on focus, and defer form-input sync until value changes',
      (t) async {
        await pumpComponent(t, content());
        final config = t.widget<DifyPromptEditor>(find.byType(DifyPromptEditor).first).workflowVariableBlock!;
        expect(config.workflowNodesMap.keys, containsAll(['node-1', 'node-2', 'sys']));

        await focusEditor(t);
        expect(find.textContaining(hiKey('formContent.hotkeyTip')), findsOneWidget);

        await modSlash(t);
        await t.enterText(nameField(), 'approval');
        await t.pump();
        await t.tap(find.text(hiKey('insertInputField.insert')));
        await t.pump(const Duration(milliseconds: 300));

        expect(inserts, hasLength(1));
        expect(inserts.single.$1['output_variable_name'], 'approval');
        expect(inserts.single.$2, contains('{{#\$output.approval#}}'));
      },
    );

    testWidgets('should disable editing helpers in readonly mode', (t) async {
      await pumpComponent(t, content(readonly: true));
      expect(t.widget<DifyPromptEditor>(find.byType(DifyPromptEditor).first).editable, isFalse);
      expect(
        find.ancestor(
          of: find.byType(DifyPromptEditor).first,
          matching: find.byWidgetPredicate((w) => w is IgnorePointer && w.ignoring),
        ),
        findsWidgets,
      );
      expect(find.text(hiKey('insertInputField.title')), findsNothing);
    });

    testWidgets('should not insert a new input when the variable name already exists', (t) async {
      await pumpComponent(
        t,
        content(
          formInputs: [
            {
              'type': 'paragraph',
              'output_variable_name': 'approval',
              'default': {'type': 'constant', 'selector': <Object?>[], 'value': ''},
            },
          ],
        ),
      );
      await focusEditor(t);
      await modSlash(t);
      await t.enterText(nameField(), 'approval');
      await t.pump();
      expect(find.text(hiKey('insertInputField.variableNameDuplicated')), findsOneWidget);
      await t.tap(find.text(hiKey('insertInputField.insert')));
      await t.pump();

      expect(inserts, isEmpty);
    });

    testWidgets('should render the mac hotkey hint when focused on macOS', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await pumpComponent(t, content());
      // Dify's spec renders the Trans components; here the English text has them.
      DifyI18n.current = _EnglishHotkeyTip();
      await focusEditor(t);

      expect(find.text('⌘'), findsOneWidget);
      expect(find.text('/'), findsWidgets);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('should preserve add-input draft state across parent rerenders', (t) async {
      await pumpComponent(t, content());
      await focusEditor(t);
      await modSlash(t);
      await t.enterText(nameField(), 'approval_name');
      await t.pump();

      await pumpComponent(t, content());

      expect(t.widget<EditableText>(nameField()).controller.text, 'approval_name');
    });
  });
}

class _EnglishHotkeyTip extends DifyTestTranslator {
  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) =>
      key == 'nodes.humanInput.formContent.hotkeyTip'
      ? 'Press <Key/> to insert variable, <CtrlKey/><Key/> to insert input field'
      : super.t(ns, key, params);
}
