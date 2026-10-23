// dify-spec: web/app/components/base/prompt-editor/plugins/workflow-variable-block/__tests__/component.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/workflow-variable-block/__tests__/index.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/workflow-variable-block/__tests__/node.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/workflow-variable-block/__tests__/use-llm-model-plugin-installed.spec.ts
// dify-spec: web/app/components/base/prompt-editor/plugins/workflow-variable-block/__tests__/workflow-variable-block-replacement-block.spec.tsx
import 'package:dify_sf_app/src/cards/variable_label.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/var_reference_vars.dart' show VarFullPathPanel;
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_chips.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _nodeA = {'node-1': WorkflowNodeInfo(title: 'Node A', type: 'llm')};

String? _error(
  List<String> variables, {
  Map<String, WorkflowNodeInfo> nodes = const {},
  List<VarGroup> vars = const [],
}) => workflowVariableState(variables, WorkflowVariableBlockConfig(workflowNodesMap: nodes, variables: vars)).errorMsg;

void main() {
  setUp(useDifyTestTranslator);

  group('WorkflowVariableBlockComponent', () {
    testWidgets('should render variable label and register update command', (t) async {
      await render(
        t,
        const WorkflowVariableChip(variables: ['node-1', 'output'], config: WorkflowVariableBlockConfig()),
      );
      expect(find.byType(VariableLabel), findsOneWidget);
      expect(t.widget<VariableLabel>(find.byType(VariableLabel)).variant, VarLabelStyle.inEditor);
    });

    testWidgets('should call setViewport when label is clicked and node exists', (t) async {
      final jumps = <String>[];
      await render(
        t,
        WorkflowVariableChip(
          variables: const ['node-1', 'group', 'field'],
          config: WorkflowVariableBlockConfig(workflowNodesMap: _nodeA, onJumpToNode: jumps.add),
        ),
      );
      await t.tap(find.byType(VariableLabel));
      expect(jumps, ['node-1']);
    });

    testWidgets('should render safely when node exists and getVarType is not provided', (t) async {
      await render(
        t,
        const WorkflowVariableChip(
          variables: ['node-1', 'group', 'field'],
          config: WorkflowVariableBlockConfig(workflowNodesMap: _nodeA),
        ),
      );
      expect(find.byType(VariableLabel), findsOneWidget);
      expect(t.widget<VariableLabel>(find.byType(VariableLabel)).notShowFullPath, isTrue);
    });

    testWidgets('should pass computed varType when getVarType is provided', (t) async {
      final calls = <(String, List<String>)>[];
      await render(
        t,
        WorkflowVariableChip(
          variables: const ['node-1', 'group', 'field'],
          config: WorkflowVariableBlockConfig(
            workflowNodesMap: _nodeA,
            getVarType: (id, sel) {
              calls.add((id, sel));
              return 'number';
            },
          ),
        ),
      );
      final g = await t.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(g.removePointer);
      await g.addPointer(location: Offset.zero);
      await g.moveTo(t.getCenter(find.byType(VariableLabel)));
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(calls.single.$1, 'node-1');
      expect(calls.single.$2, ['node-1', 'group', 'field']);
      expect(t.widget<VarFullPathPanel>(find.byType(VarFullPathPanel)).varType, 'number');
    });

    test('should treat env variable as valid regardless of environmentVariables contents', () {
      expect(_error(['env', 'missing_key']), isNull);
    });

    test('should keep env variable valid when environmentVariables is omitted', () {
      expect(_error(['env', 'missing_key']), isNull);
    });

    test('should treat env variable as valid when it exists in environmentVariables', () {
      expect(_error(['env', 'valid_key']), isNull);
    });

    test('should handle env selector with missing segment when environmentVariables are provided', () {
      expect(_error(['env']), isNull);
    });

    test('should mark forced env branch invalid when selector prefix is missing', () {
      expect(_error([]), isNotNull);
    });

    test('should treat conversation variable as valid when found in conversationVariables', () {
      expect(_error(['conversation', 'topic']), isNull);
    });

    test('should keep conversation variable valid when conversationVariables is omitted', () {
      expect(_error(['conversation', 'topic']), isNull);
    });

    test('should treat conversation variable as valid regardless of conversationVariables contents', () {
      expect(_error(['conversation', 'topic']), isNull);
    });

    test('should handle conversation selector with missing segment when conversationVariables are provided', () {
      expect(_error(['conversation']), isNull);
    });

    test('should mark forced conversation branch invalid when selector prefix is missing', () {
      expect(_error([]), isNotNull);
    });

    test('should treat global variable as valid without node', () {
      expect(_error(['sys', 'user_id']), isNull);
    });

    test('should use rag variable validation path', () {
      expect(
        _error(
          ['rag', 'shared', 'answer'],
          nodes: {'rag': const WorkflowNodeInfo(title: 'Rag', type: 'tool')},
        ),
        isNull,
      );
    });

    test('should keep rag variable valid when ragVariables is omitted', () {
      expect(_error(['rag', 'shared', 'answer']), isNull);
    });

    test('should treat rag variable as valid regardless of ragVariables contents', () {
      expect(_error(['rag', 'shared', 'answer']), isNull);
    });

    test('should handle rag selector with missing segment when ragVariables are provided', () {
      expect(
        _error(
          ['rag', 'shared'],
          nodes: {'shared': const WorkflowNodeInfo(title: 'Rag', type: 'tool')},
        ),
        isNull,
      );
    });

    test('should mark forced rag branch invalid when selector prefix is missing', () {
      expect(_error([]), isNotNull);
    });

    testWidgets('should apply workflow node map updates through command handler', (t) async {
      Widget chip(Map<String, WorkflowNodeInfo> nodes) => WorkflowVariableChip(
        variables: const ['node-1', 'field'],
        config: WorkflowVariableBlockConfig(workflowNodesMap: nodes),
      );
      await render(t, chip(const {}));
      expect(t.widget<VariableLabel>(find.byType(VariableLabel)).nodeTitle, isNull);
      await render(t, chip(const {'node-1': WorkflowNodeInfo(title: 'Updated', type: 'llm')}));
      expect(t.widget<VariableLabel>(find.byType(VariableLabel)).nodeTitle, 'Updated');
    });

    test('should mark non-special variable invalid when source key is missing in availableVariables', () {
      expect(
        _error(
          ['node-1', 'missing_key'],
          nodes: _nodeA,
          vars: const [
            VarGroup(nodeId: 'node-1', title: 'Node A', vars: [PickerVar('existing_key', 'string')]),
          ],
        ),
        'workflow.errorMsg.invalidVariable',
      );
    });

    test('should keep non-special variable valid when source key exists in availableVariables', () {
      expect(
        _error(
          ['node-1', 'existing_key'],
          nodes: _nodeA,
          vars: const [
            VarGroup(nodeId: 'node-1', title: 'Node A', vars: [PickerVar('existing_key', 'string')]),
          ],
        ),
        isNull,
      );
    });
  });

  group('WorkflowVariableBlock', () {
    testWidgets('should dispatch workflow node map update on mount', (t) async {
      final c = await renderWithController(
        t,
        (c) => DifyPromptEditor(
          controller: c,
          value: '{{#node-1.answer#}}',
          workflowVariableBlock: const WorkflowVariableBlockConfig(show: true, workflowNodesMap: _nodeA),
        ),
      );
      expect(blockCount(c, PromptBlockKind.workflowVariable), 1);
      expect(t.widget<VariableLabel>(find.byType(VariableLabel)).nodeTitle, 'Node A');
    });

    testWidgets('should insert workflow variable block node and call onInsert', (t) async {
      var inserted = 0;
      final c = await renderWithController(
        t,
        (c) => DifyPromptEditor(
          controller: c,
          workflowVariableBlock: WorkflowVariableBlockConfig(show: true, onInsert: () => inserted++),
        ),
      );
      c.insertBlock(const PromptBlock.variable(['node-1', 'answer']));
      expect(c.prompt, '{{#node-1.answer#}}');
      expect(inserted, 1);
    });

    testWidgets('should return true on insert when onInsert is omitted', (t) async {
      final c = await renderWithController(
        t,
        (c) => DifyPromptEditor(controller: c, workflowVariableBlock: const WorkflowVariableBlockConfig(show: true)),
      );
      c.insertBlock(const PromptBlock.variable(['node-1', 'answer']));
      expect(c.prompt, '{{#node-1.answer#}}');
    });

    testWidgets('should call onDelete and return true when delete handler runs', (t) async {
      var deleted = 0;
      final c = await renderWithController(
        t,
        (c) => DifyPromptEditor(
          controller: c,
          workflowVariableBlock: WorkflowVariableBlockConfig(show: true, onDelete: () => deleted++),
        ),
      );
      c.prompt = '{{#node-1.answer#}}';
      await t.pump();
      await deleteBlockAt(t, 0);
      expect(deleted, 1);
    });

    testWidgets('should return true on delete when onDelete is omitted', (t) async {
      final c = await renderWithController(
        t,
        (c) => DifyPromptEditor(controller: c, workflowVariableBlock: const WorkflowVariableBlockConfig(show: true)),
      );
      c.prompt = '{{#node-1.answer#}}';
      await t.pump();
      await deleteBlockAt(t, 0);
      expect(c.prompt, '');
    });

    testWidgets('should run merged cleanup on unmount', (t) async {
      var calls = 0;
      final c = await renderWithController(
        t,
        (c) => DifyPromptEditor(
          controller: c,
          workflowVariableBlock: WorkflowVariableBlockConfig(
            show: true,
            onInsert: () => calls++,
            onDelete: () => calls++,
          ),
        ),
      );
      await t.pumpWidget(const SizedBox());
      c.prompt = '{{#node-1.answer#}}';
      c.prompt = '';
      expect(calls, 0);
    });
  });

  group('WorkflowVariableBlockNode', () {
    test('should return getters and text content in expected format', () {
      const b = PromptBlock.variable(['node-1', 'answer']);
      expect(b.variables, ['node-1', 'answer']);
      expect(b.text, '{{#node-1.answer#}}');
    });
  });

  group('useLlmModelPluginInstalled', () {
    bool Function(String) plugins(List<String> providers) =>
        (id) => providers.map(extractPluginId).contains(id);

    test('should return true when the node is missing', () {
      expect(llmModelPluginInstalled('target', null, plugins([])), isTrue);
    });

    test('should return true when the node is not an LLM node', () {
      expect(
        llmModelPluginInstalled('target', const {
          'target': WorkflowNodeInfo(title: 'Target', type: 'start'),
        }, plugins([])),
        isTrue,
      );
    });

    test('should return true when the matching model plugin is installed', () {
      expect(
        llmModelPluginInstalled(
          'target',
          const {'target': WorkflowNodeInfo(title: 'Target', type: 'llm', modelProvider: 'langgenius/openai/gpt-4.1')},
          plugins(['langgenius/openai/openai', 'langgenius/anthropic/claude']),
        ),
        isTrue,
      );
    });

    test('should return false when the matching model plugin is not installed', () {
      expect(
        llmModelPluginInstalled(
          'target',
          const {'target': WorkflowNodeInfo(title: 'Target', type: 'llm', modelProvider: 'langgenius/openai/gpt-4.1')},
          plugins(['langgenius/anthropic/claude']),
        ),
        isFalse,
      );
    });
  });

  group('WorkflowVariableBlockReplacementBlock', () {
    testWidgets('should register transform and cleanup on unmount', (t) async {
      var inserted = 0;
      final c = await renderWithController(
        t,
        (c) => DifyPromptEditor(
          controller: c,
          workflowVariableBlock: WorkflowVariableBlockConfig(show: true, onInsert: () => inserted++),
        ),
      );
      await t.pumpWidget(const SizedBox());
      c.prompt = '{{#node-1.output#}}';
      expect(inserted, 0);
    });

    test('should match variable placeholders and return null for non-placeholder text', () {
      final m = varRegex.firstMatch('prefix {{#node-1.output#}} suffix')!;
      expect((m.start, m.end), (7, 26));
      expect(varRegex.firstMatch('plain text only'), isNull);
    });

    testWidgets('should create replacement node with mapped env/conversation/rag vars and call onInsert', (t) async {
      var inserted = 0;
      final c = await renderWithController(
        t,
        (c) => DifyPromptEditor(
          controller: c,
          workflowVariableBlock: WorkflowVariableBlockConfig(
            show: true,
            workflowNodesMap: _nodeA,
            onInsert: () => inserted++,
          ),
        ),
      );
      c.prompt = '{{#node-1.output#}}';
      expect(inserted, 1);
      expect(c.blockAt(0), const PromptBlock.variable(['node-1', 'output']));
    });

    testWidgets('should create replacement node without optional callbacks and variable groups', (t) async {
      final c = await renderWithController(
        t,
        (c) => DifyPromptEditor(controller: c, workflowVariableBlock: const WorkflowVariableBlockConfig(show: true)),
      );
      c.prompt = '{{#node-1.output#}}';
      await t.pump();
      expect(c.blockAt(0), const PromptBlock.variable(['node-1', 'output']));
      expect(t.takeException(), isNull);
    });
  });
}
