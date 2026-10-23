// dify-spec: web/app/components/base/prompt-editor/__tests__/prompt-editor-content.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/__tests__/index.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/component-picker-block/__tests__/index.spec.tsx
//
// The editor with the agent output block, the HITL input block and shortcut popups.
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/agent_output_block.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/hitl_input_block.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Future<PromptEditorController> _editor(WidgetTester t, DifyPromptEditor Function(PromptEditorController c) build) =>
    renderWithController(t, build);

List<String> _outputBlocks(PromptEditorController c) => [
  for (var i = 0; i < c.text.length; i++)
    if (c.blockAt(i)?.kind == PromptBlockKind.agentOutput) c.blockAt(i)!.name,
];

Future<void> _ctrl(WidgetTester t, LogicalKeyboardKey key) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await t.sendKeyEvent(key);
  await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await t.pump();
  await t.pump();
}

HitlInputBlockConfig _hitl() =>
    HitlInputBlockConfig(show: true, nodeId: 'node-1', onFormInputItemRemove: (_) {}, onFormInputItemRename: (_, _) {});

void main() {
  group('PromptEditorContent', () {
    group('Rendering', () {
      testWidgets('should render adjacent agent output tokens as inline output blocks', (t) async {
        const initial =
            '[§output:ccc:ccc§][§output:output_3ggg:output_3ggg§][§output:ggg:ggg§][§output:output_3fdfdf:output_3fdfdf§]';
        final c = await _editor(
          t,
          (c) => DifyPromptEditor(
            controller: c,
            value: initial,
            agentOutputBlock: const AgentOutputBlockConfig(
              show: true,
              outputs: [
                {'name': 'ccc', 'type': 'string'},
                {'name': 'output_3ggg', 'type': 'string'},
                {'name': 'ggg', 'type': 'string'},
                {'name': 'output_3fdfdf', 'type': 'string'},
              ],
            ),
          ),
        );
        expect(_outputBlocks(c), ['ccc', 'output_3ggg', 'ggg', 'output_3fdfdf']);
        for (final name in ['ccc', 'output_3ggg', 'ggg', 'output_3fdfdf']) {
          expect(find.text(name), findsOneWidget);
        }
        expect(find.textContaining('[§output:ccc:ccc§]'), findsNothing);
        expect(c.prompt, initial);
      });

      testWidgets('should render file-name output tokens with the declared output type', (t) async {
        await _editor(
          t,
          (c) => DifyPromptEditor(
            controller: c,
            value: '[§output:qna_report.pdf:qna_report.pdf§]',
            agentOutputBlock: const AgentOutputBlockConfig(
              show: true,
              outputs: [
                {'name': 'qna_report.pdf', 'type': 'string'},
              ],
            ),
          ),
        );
        expect(find.text('qna_report.pdf'), findsOneWidget);
        expect(find.text('STRING'), findsOneWidget);
      });

      testWidgets('should update rendered output block type when declared output config changes', (t) async {
        final c = PromptEditorController();
        addTearDown(c.dispose);
        Widget editor(String type) => DifyPromptEditor(
          controller: c,
          value: '[§output:summary:summary§]',
          agentOutputBlock: AgentOutputBlockConfig(
            show: true,
            outputs: [
              {'name': 'summary', 'type': type},
            ],
          ),
        );
        await render(t, editor('string'));
        expect(find.text('summary'), findsOneWidget);
        expect(find.text('STRING'), findsOneWidget);
        await render(t, editor('file'));
        expect(find.text('FILE'), findsOneWidget);
        expect(find.text('STRING'), findsNothing);
      });

      testWidgets('should preserve committed output name selection state when refreshing output block props', (
        t,
      ) async {
        void initialOnChange(List<Map<String, Object?>> o, String? p) {}
        void nextOnChange(List<Map<String, Object?>> o, String? p) {}
        const nextOutputs = [
          {'name': 'summary', 'type': 'string'},
        ];
        final c = PromptEditorController();
        addTearDown(c.dispose);
        Widget editor(AgentOutputBlockConfig config) =>
            DifyPromptEditor(controller: c, value: '[§output:output:output§]', agentOutputBlock: config);
        await render(
          t,
          editor(
            AgentOutputBlockConfig(
              show: true,
              outputs: const [
                {'name': 'output', 'type': 'string'},
              ],
              onChange: initialOnChange,
            ),
          ),
        );
        expect(find.text('output'), findsOneWidget);
        // The node's setOutput (Dify's spec calls it on the Lexical node).
        final block = t.widget<AgentOutputBlockComponent>(find.byType(AgentOutputBlockComponent));
        expect(block.host.setOutput('summary', 'string', true, nextOutputs, false, true), isTrue);
        await t.pump();
        await render(t, editor(AgentOutputBlockConfig(show: true, outputs: [...nextOutputs], onChange: nextOnChange)));
        final refreshed = t.widget<AgentOutputBlockComponent>(find.byType(AgentOutputBlockComponent));
        expect(refreshed.name, 'summary');
        expect(refreshed.isEditing, isTrue);
        expect(refreshed.selectNameOnEdit, isFalse);
        expect(refreshed.openTypeSelectOnEdit, isTrue);
        expect(refreshed.onChange, same(nextOnChange));
      });

      testWidgets('should render optional blocks and open shortcut popups with the real editor runtime', (t) async {
        final inserted = <List<String>>[];
        await render(
          t,
          DifyPromptEditor(
            value: 'seed prompt',
            contextBlock: const ContextBlockConfig(show: true),
            queryBlock: const PromptBlockConfig(show: true),
            requestUrlBlock: const PromptBlockConfig(show: true),
            historyBlock: const HistoryBlockConfig(
              show: true,
              history: (user: 'user-role', assistant: 'assistant-role'),
            ),
            variableBlock: const VariableBlockConfig(show: true, variables: []),
            externalToolBlock: const ExternalToolBlockConfig(show: true, externalTools: []),
            workflowVariableBlock: const WorkflowVariableBlockConfig(show: true),
            hitlInputBlock: _hitl(),
            currentBlock: const CurrentBlockConfig(show: true),
            errorMessageBlock: const PromptBlockConfig(show: true),
            lastRunBlock: const PromptBlockConfig(show: true),
            isSupportFileVar: true,
            shortcutPopups: [
              ShortcutPopup(
                hotkey: 'ctrl+/',
                builder: (context, close, onInsert) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => onInsert(CallbackPromptEditorCommand(inserted.add, const ['from-shortcut'])),
                      child: const Text('Insert shortcut'),
                    ),
                    TextButton(onPressed: close, child: const Text('Close shortcut')),
                  ],
                ),
              ),
            ],
          ),
        );
        await focusAt(t);
        await _ctrl(t, LogicalKeyboardKey.slash);
        expect(find.text('Insert shortcut'), findsOneWidget);
        await t.tap(find.text('Insert shortcut'));
        await t.pump();
        expect(inserted, [
          ['from-shortcut'],
        ]);
        // Dify's OnChangePlugin also reports selection changes; the port's onChange reports text changes only.
        expect(find.text('Insert shortcut'), findsNothing);
      });
    });
  });

  group('PromptEditor', () {
    group('Props Typing', () {
      testWidgets('should accept typed shortcut popup configuration', (t) async {
        await render(
          t,
          DifyPromptEditor(
            shortcutPopups: [
              ShortcutPopup(
                hotkey: const ['mod', '/'],
                builder: (context, close, _) => TextButton(onPressed: close, child: const Text('close')),
              ),
            ],
          ),
        );
        expect(find.byType(DifyPromptEditor), findsOneWidget);
        await focusAt(t);
        await _ctrl(t, LogicalKeyboardKey.slash);
        await t.tap(find.text('close'));
        await t.pump();
        expect(find.text('close'), findsNothing);
      });

      testWidgets('should render multiple shortcutPopups', (t) async {
        await render(
          t,
          DifyPromptEditor(
            shortcutPopups: [
              ShortcutPopup(
                hotkey: 'ctrl+a',
                builder: (context, close, _) => TextButton(onPressed: close, child: const Text('A')),
              ),
              ShortcutPopup(
                hotkey: 'ctrl+b',
                builder: (context, close, _) => TextButton(onPressed: close, child: const Text('B')),
              ),
            ],
          ),
        );
        await focusAt(t);
        await _ctrl(t, LogicalKeyboardKey.keyA);
        expect(find.text('A'), findsOneWidget);
        expect(find.text('B'), findsNothing);
        await t.tap(find.text('A'));
        await t.pump();
        await focusAt(t);
        await _ctrl(t, LogicalKeyboardKey.keyB);
        expect(find.text('B'), findsOneWidget);
        expect(find.text('A'), findsNothing);
      });

      testWidgets('should render hitl block when show=true', (t) async {
        await render(t, DifyPromptEditor(value: '{{#\$output.user_name#}}', hitlInputBlock: _hitl()));
        expect(find.byType(HitlInputComponent), findsOneWidget);
        expect(t.widget<HitlInputComponent>(find.byType(HitlInputComponent)).varName, 'user_name');
      });
    });
  });

  group('ComponentPicker (component-picker-block/index.tsx)', () {
    testWidgets('clears slash trigger state after creating an agent output from the footer action', (t) async {
      final changes = <(List<Map<String, Object?>>, String?)>[];
      final c = await _editor(
        t,
        (c) => DifyPromptEditor(
          controller: c,
          workflowVariableBlock: const WorkflowVariableBlockConfig(
            show: true,
            variables: [
              VarGroup(nodeId: 'node-1', title: 'Node 1', vars: [PickerVar('output', 'string')]),
            ],
          ),
          agentOutputBlock: AgentOutputBlockConfig(show: true, onChange: (o, p) => changes.add((o, p))),
        ),
      );
      await focusAt(t);
      await typeText(t, '/');
      final action = find.text('workflow.nodes.agent.outputVars.newOutput');
      expect(action, findsOneWidget);
      await t.tap(action);
      await t.pump();
      // INSERT_AGENT_OUTPUT_BLOCK_COMMAND: a new output, its block where the trigger was.
      expect(changes.single.$1.single['name'], 'output');
      expect(changes.single.$2, '[§output:output:output§]');
      expect(c.prompt, isNot(contains('/')));
      expect(action, findsNothing);
      editorState(t).focusNode.requestFocus();
      await t.pump();
      expect(action, findsNothing);
    });
  });
}
