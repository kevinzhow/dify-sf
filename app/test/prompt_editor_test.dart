// Behaviour of the prompt editor beyond Dify's own specs (test/dify_spec/prompt_editor): atomic blocks, clipboard,
// undo, typed tokens, the Editor chrome.
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:dify_sf_app/src/workflow_editor/code_editor/editor_view.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/form_content.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_chips.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/prompt_editor/harness.dart';
import 'dify_spec/workflow/nodes_panel/data/human_input_test_kit.dart' show pumpComponent;
import 'support/app_fonts.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

void main() {
  group('PromptEditorController', () {
    test('keeps one character per block and the prompt as Dify stores it', () {
      final c = PromptEditorController(
        prompt: 'Hi {{#n1.text#}} and {{#context#}}\n{{#sys.query#}}',
        blocks: const PromptBlockSet({PromptBlockKind.workflowVariable, PromptBlockKind.context}),
      );
      addTearDown(c.dispose);
      expect(c.text.length, 'Hi  and \n'.length + 3);
      expect(c.prompt, 'Hi {{#n1.text#}} and {{#context#}}\n{{#sys.query#}}');
      expect(c.blockAt(3), const PromptBlock.variable(['n1', 'text']));
    });

    test('leaves tokens of disabled blocks as text, and converts them once enabled', () {
      final c = PromptEditorController(prompt: 'a {{#context#}}');
      addTearDown(c.dispose);
      expect(c.text, 'a {{#context#}}');
      c.blocks = const PromptBlockSet({PromptBlockKind.context});
      expect(c.text.length, 3);
      expect(c.prompt, 'a {{#context#}}');
    });

    test('keeps private-use characters of the prompt as text', () {
      final c = PromptEditorController(prompt: 'xy', blocks: const PromptBlockSet({PromptBlockKind.context}));
      addTearDown(c.dispose);
      expect(c.prompt, 'xy');
    });

    test('puts the caret after an inserted block', () {
      final c = PromptEditorController(prompt: 'ab', blocks: const PromptBlockSet({PromptBlockKind.query}));
      addTearDown(c.dispose);
      c.selection = const TextSelection.collapsed(offset: 1);
      c.insertBlock(const PromptBlock(PromptBlockKind.query));
      expect(c.prompt, 'a{{#query#}}b');
      expect(c.selection, const TextSelection.collapsed(offset: 2));
      c.selection = const TextSelection(baseOffset: 0, extentOffset: 1);
      c.insertText('{{#query#}}x');
      expect(c.prompt, '{{#query#}}x{{#query#}}b');
      expect(c.selection, const TextSelection.collapsed(offset: 2));
    });

    test('serialises a selection with its blocks as text', () {
      final c = PromptEditorController(prompt: 'a{{#query#}}b', blocks: const PromptBlockSet({PromptBlockKind.query}));
      addTearDown(c.dispose);
      c.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
      expect(c.selectedPrompt, 'a{{#query#}}');
    });
  });

  group('DifyPromptEditor', () {
    const blocks = WorkflowVariableBlockConfig(show: true, variables: testVars, workflowNodesMap: testNodes);

    testWidgets('steps over a block in one caret move', (t) async {
      await render(t, const DifyPromptEditor(value: 'a{{#llm1.text#}}b', workflowVariableBlock: blocks));
      await focusAt(t, 1);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      expect(editorState(t).controller.selection.baseOffset, 2);
    });

    testWidgets('turns a typed reference into a block, caret after it', (t) async {
      final changes = <String>[];
      await render(t, DifyPromptEditor(onChange: changes.add, workflowVariableBlock: blocks));
      await focusAt(t);
      await typeText(t, 'x {{#llm1.text#}}');
      final c = editorState(t).controller;
      expect(c.text.length, 3);
      expect(c.selection.baseOffset, 3);
      expect(changes.last, 'x {{#llm1.text#}}');
      expect(find.byType(WorkflowVariableChip), findsOneWidget);
    });

    testWidgets('copies blocks as their text', (t) async {
      String? copied;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      await render(t, const DifyPromptEditor(value: 'a{{#llm1.text#}}', workflowVariableBlock: blocks));
      await focusAt(t);
      editorState(t).controller.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyC);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      expect(copied, 'a{{#llm1.text#}}');
    });

    testWidgets('brings a deleted block back on undo', (t) async {
      await render(t, const DifyPromptEditor(value: 'a{{#llm1.text#}}', workflowVariableBlock: blocks));
      final c = editorState(t).controller;
      await focusAt(t);
      await t.pump(const Duration(milliseconds: 600));
      await t.sendKeyEvent(LogicalKeyboardKey.backspace);
      await t.pump(const Duration(milliseconds: 600));
      expect(c.prompt, 'a');
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      expect(c.prompt, 'a{{#llm1.text#}}');
    });

    testWidgets('marks a reference to a variable that is not on offer', (t) async {
      await render(t, const DifyPromptEditor(value: '{{#llm1.gone#}}', workflowVariableBlock: blocks));
      final s = workflowVariableState(['llm1', 'gone'], blocks);
      expect(s.errorMsg, 'workflow.errorMsg.invalidVariable');
      expect(find.byType(WorkflowVariableChip), findsOneWidget);
    });
  });

  group('DifyPromptEditorPanel', () {
    testWidgets('shows the title, the count and copies the prompt', (t) async {
      String? copied;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      await render(t, DifyPromptEditorPanel(title: 'Prompt', required: true, value: 'hello', onChange: (_) {}));
      expect(find.text('PROMPT'), findsOneWidget);
      expect(find.text('*'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
      await t.tap(find.bySemanticsLabel('common.operation.copy'));
      await t.pump();
      expect(copied, 'hello');
    });

    testWidgets('switches to Jinja and shows the code editor', (t) async {
      var edition = PromptEditionType.basic;
      Widget panel() => DifyPromptEditorPanel(
        title: 'Prompt',
        value: '{{ x }}',
        onChange: (_) {},
        isSupportJinja: true,
        editionType: edition,
        onEditionTypeChange: (e) => edition = e,
      );
      await render(t, panel());
      expect(find.byType(DifyPromptEditor), findsOneWidget);
      await t.tap(find.bySemanticsLabel('workflow.common.enableJinja').last);
      await t.pump();
      expect(edition, PromptEditionType.jinja2);
      await render(t, panel());
      expect(find.byType(CodeEditorView), findsOneWidget);
      expect(find.byType(DifyPromptEditor), findsNothing);
    });

    testWidgets('expands over the panel and back', (t) async {
      await render(t, DifyPromptEditorPanel(title: 'Prompt', value: 'x', onChange: (_) {}));
      await t.tap(find.bySemanticsLabel('share.chat.expand'));
      await t.pump();
      expect(find.bySemanticsLabel('share.chat.collapse'), findsOneWidget);
      await t.tap(find.bySemanticsLabel('share.chat.collapse'));
      await t.pump();
      expect(find.bySemanticsLabel('share.chat.expand'), findsOneWidget);
      expect(find.byType(DifyPromptEditor), findsOneWidget);
    });
  });

  group('DifyPromptEditor lines', () {
    // Human input form content (form-content.tsx): a 24 px line keeps its height around a variable chip next to a
    // form field, whose line is the field's 48 px (`pt-3`, the 32 px chip, `pb-1`), as in Chrome.
    testWidgets('a chip keeps its line next to a form field', (t) async {
      final family = cardFontFamily;
      addTearDown(() => cardFontFamily = family);
      await useAppFonts();
      Future<double> chipTop({required bool fields}) async {
        await pumpComponent(
          t,
          DifyPromptEditor(
            key: ValueKey(fields),
            value: '## Draft\n\n{{#llm1.text#}}\n\nNote:\n\n{{#\$output.note#}}',
            workflowVariableBlock: testVarBlock,
            hitlInputBlock: HitlInputBlockConfig(
              show: fields,
              nodeId: 'n',
              onFormInputItemRemove: (_) {},
              onFormInputItemRename: (_, _) {},
            ),
          ),
        );
        return t.getTopLeft(find.byType(VariableLabel).first).dy - t.getTopLeft(find.byType(EditableText)).dy;
      }

      // Without fields the strut is forced: every line is 24 px.
      final forced = await chipTop(fields: false);
      expect(forced, inInclusiveRange(48, 72 - 18));
      expect(await chipTop(fields: true), closeTo(forced, 0.01));
      final top = t.getTopLeft(find.byType(EditableText)).dy;
      expect(t.getTopLeft(find.byType(InputFieldChip)).dy - top, 6 * 24 + 12);
      expect(t.getSize(find.byType(EditableText)).height, 6 * 24 + 48);
    });
  });
}
