// dify-spec: web/app/components/base/prompt-editor/plugins/component-picker-block/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/var_reference_vars.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/component_picker.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_chips.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _contextTitle = 'common.promptEditor.context.item.title';
const _search = 'workflow.common.searchVar';

ContextBlockConfig _context() => const ContextBlockConfig(show: true, selectable: true);

WorkflowVariableBlockConfig _workflow(List<VarGroup> vars) => WorkflowVariableBlockConfig(show: true, variables: vars);

/// Renders an editor with the given blocks, focuses it and types [text].
Future<PromptEditorController> _open(
  WidgetTester t,
  String text, {
  ContextBlockConfig? contextBlock,
  PromptBlockConfig? queryBlock,
  VariableBlockConfig? variableBlock,
  WorkflowVariableBlockConfig? workflowVariableBlock,
  CurrentBlockConfig? currentBlock,
  PromptBlockConfig? errorMessageBlock,
  PromptBlockConfig? lastRunBlock,
  bool slashOnly = false,
}) async {
  await render(
    t,
    DifyPromptEditor(
      contextBlock: contextBlock,
      queryBlock: queryBlock,
      variableBlock: variableBlock,
      workflowVariableBlock: workflowVariableBlock,
      currentBlock: currentBlock,
      errorMessageBlock: errorMessageBlock,
      lastRunBlock: lastRunBlock,
      disableBracePicker: slashOnly,
      disableSlashPicker: !slashOnly,
    ),
  );
  await focusAt(t);
  await typeText(t, text);
  return editorState(t).controller;
}

Future<void> _retype(WidgetTester t, String text) async {
  final c = editorState(t).controller;
  c.selection = TextSelection.collapsed(offset: c.text.length);
  await t.pump();
  await typeText(t, text);
}

/// The variable rows' selected flags (`data-selected`).
bool _selected(WidgetTester t, String name) => t
    .widget<Semantics>(
      find
          .ancestor(
            of: find.text(name),
            matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.selected != null),
          )
          .first,
    )
    .properties
    .selected!;

/// Dify's test translator, except the "LAST OUTPUT" separator, whose key is wider than the 260 px menu.
class _Translator extends DifyTestTranslator {
  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) =>
      key == 'debug.lastOutput' ? 'LAST OUTPUT' : super.t(ns, key, params);
}

void main() {
  setUp(() => DifyI18n.current = _Translator());

  group('ComponentPicker (component-picker-block/index.tsx)', () {
    testWidgets(
      'does not render a menu when there are no options and workflowVariableBlock is not shown (renderMenu returns null)',
      (t) async {
        await _open(t, '{');
        expect(menuOpen(), isFalse);
        expect(find.text(_contextTitle), findsNothing);
      },
    );

    testWidgets(
      'renders prompt options in a portal and removes the trigger TextNode when selecting a normal option (nodeToRemove && key truthy)',
      (t) async {
        final c = await _open(
          t,
          '{',
          contextBlock: _context(),
          queryBlock: const PromptBlockConfig(show: true, selectable: true),
        );
        expect(find.text(_contextTitle), findsOneWidget);
        expect(find.text('common.promptEditor.query.item.title'), findsOneWidget);
        await t.tap(find.text(_contextTitle));
        await t.pump();
        expect(c.prompt, '{{#context#}}');
        expect(find.byType(ContextChip), findsOneWidget);
      },
    );

    testWidgets('does not remove the trigger when selecting an option with an empty key (nodeToRemove && key falsy)', (
      t,
    ) async {
      final c = await _open(
        t,
        '{',
        variableBlock: const VariableBlockConfig(show: true, variables: [(value: '', name: 'empty')]),
      );
      expect(find.text('common.promptEditor.variable.modal.add', findRichText: true), findsOneWidget);
      await t.tap(find.byType(VariableMenuItem).first);
      await t.pump();
      expect(c.prompt, contains('{'));
    });

    testWidgets(
      'handles workflow variable selection: flat vars (current/error_message/last_run) and closes on Escape from search input',
      (t) async {
        final c = await _open(
          t,
          '{',
          workflowVariableBlock: _workflow(const [
            VarGroup(
              nodeId: 'custom-flat',
              title: 'custom-flat',
              isFlat: true,
              vars: [PickerVar('custom_flat', 'string')],
            ),
            VarGroup(nodeId: 'node-output', title: 'Node Output', vars: [PickerVar('output', 'string')]),
          ]),
          currentBlock: const CurrentBlockConfig(show: true),
          errorMessageBlock: const PromptBlockConfig(show: true),
          lastRunBlock: const PromptBlockConfig(show: true),
        );
        await t.tap(find.text('current_prompt'));
        await t.pump();
        expect(c.prompt, '{{#current#}}');
        await _retype(t, '{');
        await t.tap(find.text('error_message'));
        await t.pump();
        expect(c.prompt, '{{#current#}}{{#error_message#}}');
        await _retype(t, '{');
        await t.tap(find.text('last_run'));
        await t.pump();
        expect(c.prompt, '{{#current#}}{{#error_message#}}{{#last_run#}}');

        await _retype(t, '{');
        expect(menuOpen(), isTrue);
        await t.tap(find.byType(EditableText).last);
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pump();
        expect(menuOpen(), isFalse);

        await _retype(t, ' {');
        await t.tap(find.text('custom_flat'));
        await t.pump();
        expect(c.prompt, '{{#current#}}{{#error_message#}}{{#last_run#}}{ ');
      },
    );

    testWidgets('handles workflow variable selection for nested fields: sys.query, sys.files, and normal paths', (
      t,
    ) async {
      final c = await _open(
        t,
        '{',
        workflowVariableBlock: _workflow(const [
          VarGroup(
            nodeId: 'node-1',
            title: 'Node 1',
            vars: [
              PickerVar('sys.query', 'object', children: [PickerVar('q', 'string')]),
              PickerVar('sys.files', 'object', children: [PickerVar('f', 'string')]),
              PickerVar('output', 'object', children: [PickerVar('x', 'string')]),
            ],
          ),
        ]),
      );
      Future<void> pick(String variable, String field) async {
        await t.tap(
          find
              .descendant(
                of: find.ancestor(of: find.text(variable), matching: find.byType(Row)).first,
                matching: find.byType(GestureDetector),
              )
              .last,
        );
        await t.pumpAndSettle();
        await t.tap(find.text(field));
        await t.pump();
      }

      await pick('query', 'q');
      expect(c.prompt, '{{#sys.query#}}');
      await _retype(t, '{');
      await pick('files', 'f');
      expect(c.prompt, '{{#sys.query#}}{{#sys.files#}}');
      await _retype(t, '{');
      await pick('output', 'x');
      expect(c.prompt, '{{#sys.query#}}{{#sys.files#}}{{#node-1.output.x#}}');
    });

    testWidgets('filters workflow variables from slash input and matches child paths', (t) async {
      final c = await _open(
        t,
        '/child',
        slashOnly: true,
        contextBlock: _context(),
        workflowVariableBlock: _workflow(const [
          VarGroup(
            nodeId: 'node-1',
            title: 'Node 1',
            vars: [
              PickerVar('payload', 'object', children: [PickerVar('child_name', 'string')]),
              PickerVar('other_value', 'string'),
            ],
          ),
        ]),
      );
      expect(find.text(_search), findsNothing);
      expect(find.text('payload'), findsOneWidget);
      expect(find.text('other_value'), findsNothing);
      await t.tap(
        find
            .descendant(
              of: find.ancestor(of: find.text('payload'), matching: find.byType(Row)).first,
              matching: find.byType(GestureDetector),
            )
            .last,
      );
      await t.pumpAndSettle();
      await t.tap(find.text('child_name'));
      await t.pump();
      expect(c.prompt, '{{#node-1.payload.child_name#}}');
    });

    testWidgets(
      'filters workflow variables on the first character after slash and does not highlight context by default',
      (
        t,
      ) async {
        final c = await _open(
          t,
          '/c',
          slashOnly: true,
          contextBlock: _context(),
          workflowVariableBlock: _workflow(const [
            VarGroup(
              nodeId: 'node-1',
              title: 'Node 1',
              vars: [PickerVar('child_value', 'string'), PickerVar('other_value', 'string')],
            ),
          ]),
        );
        expect(find.text('child_value'), findsOneWidget);
        expect(find.text('other_value'), findsNothing);
        expect(t.widget<PromptMenuItem>(find.byType(PromptMenuItem)).isSelected, isFalse);
        expect(c.prompt, '/c');
      },
    );

    testWidgets('defaults to the first workflow variable and removes the full slash query when selecting by keyboard', (
      t,
    ) async {
      final c = await _open(
        t,
        '/e',
        slashOnly: true,
        contextBlock: _context(),
        workflowVariableBlock: _workflow(const [
          VarGroup(
            nodeId: 'node-1',
            title: 'Node 1',
            vars: [PickerVar('first_value', 'string'), PickerVar('second_value', 'string')],
          ),
        ]),
      );
      expect(_selected(t, 'first_value'), isTrue);
      expect(_selected(t, 'second_value'), isFalse);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pump();
      expect(_selected(t, 'first_value'), isFalse);
      expect(_selected(t, 'second_value'), isTrue);
      expect(c.prompt, '/e');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(c.prompt, '{{#node-1.second_value#}}');
    });

    testWidgets('skips removing the trigger when selection is null (needRemove is null) and still dispatches', (
      t,
    ) async {
      final c = await _open(
        t,
        '{',
        workflowVariableBlock: _workflow(const [
          VarGroup(nodeId: 'current', title: 'current_prompt', isFlat: true, vars: [PickerVar('current', 'string')]),
        ]),
      );
      // Dify nulls the selection and clicks in one act; here the list's callback runs with no caret.
      // A focused field always has a caret (EditableText puts it back), so the editor blurs first.
      final list = t.widget<VarReferenceVars>(find.byType(VarReferenceVars));
      editorState(t).focusNode.unfocus();
      await t.pump();
      c.selection = const TextSelection.collapsed(offset: -1);
      list.onChange(['current'], const PickerVar('current', 'string'));
      await t.pump();
      expect(c.prompt, '{{{#current#}}');
    });

    testWidgets('renders the workflow-variable divider when workflowVariableBlock is shown and options are non-empty', (
      t,
    ) async {
      await _open(
        t,
        '{',
        contextBlock: _context(),
        workflowVariableBlock: _workflow(const [
          VarGroup(nodeId: 'node-1', title: 'Node 1', vars: [PickerVar('output', 'string')]),
        ]),
      );
      expect(find.text(_search), findsOneWidget);
      expect(find.text(_contextTitle), findsOneWidget);
      final dividers = find.descendant(
        of: find.byType(ComponentPickerMenu),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.color == DifyColors.dividerSubtle &&
              w.margin == const EdgeInsets.symmetric(vertical: 4),
        ),
      );
      expect(dividers, findsOneWidget);
    });

    group('blur/focus menu visibility', () {
      Future<FocusNode> openThenBlur(WidgetTester t) async {
        final other = FocusNode();
        addTearDown(other.dispose);
        await render(
          t,
          Column(
            children: [
              DifyPromptEditor(contextBlock: _context(), disableSlashPicker: true),
              Focus(focusNode: other, child: const SizedBox(height: 10)),
            ],
          ),
        );
        await focusAt(t);
        await typeText(t, '{');
        expect(find.text(_contextTitle), findsOneWidget);
        other.requestFocus();
        await t.pump();
        return other;
      }

      testWidgets('hides the menu after a 200ms delay when blur-sm command is dispatched', (t) async {
        await openThenBlur(t);
        expect(find.text(_contextTitle), findsOneWidget);
        await t.pump(const Duration(milliseconds: 200));
        await t.pump();
        expect(find.text(_contextTitle), findsNothing);
      });

      testWidgets('restores menu visibility when focus command is dispatched after blur-sm hides it', (t) async {
        await openThenBlur(t);
        await t.pump(const Duration(milliseconds: 200));
        await t.pump();
        expect(find.text(_contextTitle), findsNothing);
        editorState(t).focusNode.requestFocus();
        await t.pump();
        await _retype(t, '{');
        expect(find.text(_contextTitle), findsOneWidget);
      });

      testWidgets('cancels the blur-sm timer when focus arrives before the 200ms timeout', (t) async {
        await openThenBlur(t);
        editorState(t).focusNode.requestFocus();
        await t.pump(const Duration(milliseconds: 200));
        await t.pump();
        expect(find.text(_contextTitle), findsOneWidget);
      });

      testWidgets('cancels a pending blur-sm timer when a subsequent blur-sm targets var-search-input', (t) async {
        final other = FocusNode();
        addTearDown(other.dispose);
        await render(
          t,
          Column(
            children: [
              DifyPromptEditor(contextBlock: _context(), workflowVariableBlock: testVarBlock, disableSlashPicker: true),
              Focus(focusNode: other, child: const SizedBox(height: 10)),
            ],
          ),
        );
        await focusAt(t);
        await typeText(t, '{');
        other.requestFocus();
        await t.pump();
        await t.tap(find.byType(EditableText).last);
        await t.pump(const Duration(milliseconds: 200));
        await t.pump();
        expect(find.text(_contextTitle), findsOneWidget);
      });

      testWidgets('does not hide the menu when blur-sm target is var-search-input', (t) async {
        await _open(t, '{', contextBlock: _context(), workflowVariableBlock: testVarBlock);
        await t.tap(find.byType(EditableText).last);
        await t.pump(const Duration(milliseconds: 200));
        await t.pump();
        expect(find.text(_contextTitle), findsOneWidget);
      });

      testWidgets('does not hide the menu when focus moves into a variable child popup', (t) async {
        await _open(
          t,
          '/',
          slashOnly: true,
          workflowVariableBlock: _workflow(const [
            VarGroup(
              nodeId: 'node-1',
              title: 'Node 1',
              vars: [
                PickerVar('payload', 'object', children: [PickerVar('child', 'string')]),
              ],
            ),
          ]),
        );
        final g = await t.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(g.removePointer);
        await g.addPointer(location: Offset.zero);
        await g.moveTo(t.getCenter(find.text('payload')));
        await t.pumpAndSettle();
        await g.moveTo(t.getCenter(find.text('child')));
        await t.pump(const Duration(milliseconds: 200));
        await t.pump();
        expect(find.text('payload'), findsWidgets);
        expect(menuOpen(), isTrue);
        expect(editorState(t).focusNode.hasFocus, isTrue);
      });
    });
  });
}
