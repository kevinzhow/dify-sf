// dify-spec: web/app/components/base/prompt-editor/plugins/hitl-input-block/__tests__/component-ui.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/hitl-input-block/__tests__/component.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/hitl-input-block/__tests__/hitl-input-block-replacement-block.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/hitl-input-block/__tests__/index.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/hitl-input-block/__tests__/node.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/hitl-input-block/__tests__/variable-block.spec.tsx
//
// The HITL input block of the prompt editor: a `{{#$output.name#}}` token is one block character drawn as the
// field's chip (InputFieldChip, Dify's HITLInputComponentUI) through HitlInputComponent. Dify's Lexical commands
// are the editor's own methods (runCommand); the block reads its props from the editor's `hitlInputBlock` config, so
// what Dify's node getters and UPDATE_WORKFLOW_NODES_MAP hand over is what the rendered chip receives.
import 'package:dify_sf_app/src/cards/variable_label.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/form_content.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/hitl_input_block.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workflow/nodes_panel/data/human_input_test_kit.dart';

const _nodes = {'node-2': WorkflowNodeInfo(title: 'Node 2', type: 'llm')};

Map<String, Object?> _paragraph({String name = 'customer_name', Map<String, Object?>? def}) => {
  'type': 'paragraph',
  'output_variable_name': name,
  'default': def ?? {'type': 'constant', 'selector': <Object?>[], 'value': 'John Doe'},
};

/// The recorded chip callbacks.
class _Chip {
  final changes = <Map<String, Object?>>[];
  final renames = <(Map<String, Object?>, String)>[];
  var removes = 0;
}

Widget _chip(
  _Chip calls, {
  Map<String, Object?>? formInput,
  List<String> unavailable = const [],
  Map<String, WorkflowNodeInfo> nodes = _nodes,
  bool readonly = false,
}) => InputFieldChip(
  varName: 'customer_name',
  formInput: formInput,
  unavailable: unavailable,
  nodesMap: nodes,
  scope: const VarScope(),
  readonly: readonly,
  onChange: calls.changes.add,
  onRename: (p, old) => calls.renames.add((p, old)),
  onRemove: () => calls.removes++,
);

Finder _editButton() => iconButton('common.operation.edit');
Finder _removeButton() => iconButton('common.operation.remove');

/// Hovers the chip (its actions show on hover) and opens the edit dialog.
Future<void> _openEdit(WidgetTester t) async {
  await hover(t, find.byType(InputFieldChip));
  await tapAndSettle(t, _editButton());
}

Finder _nameField() => inputNamed(hiKey('insertInputField.saveResponseAs'));

/// The block config of the tests, recording its callbacks.
class _Block {
  final changes = <List<Object?>>[];
  final removes = <String>[];
  final renames = <(Map<String, Object?>, String)>[];
  var inserts = 0, deletes = 0;

  HitlInputBlockConfig config({
    List<Object?>? formInputs = const [],
    List<VarGroup>? variables,
    bool readonly = false,
    PromptGetVarType? getVarType,
    Map<String, WorkflowNodeInfo> nodes = const {'node-1': WorkflowNodeInfo(title: 'First Node', type: 'start')},
    bool withInsert = true,
    bool withDelete = true,
  }) => HitlInputBlockConfig(
    show: true,
    nodeId: 'node-1',
    formInputs: formInputs,
    variables: variables,
    workflowNodesMap: nodes,
    getVarType: getVarType,
    readonly: readonly,
    onFormInputsChange: changes.add,
    onFormInputItemRemove: removes.add,
    onFormInputItemRename: (p, old) => renames.add((p, old)),
    onInsert: withInsert ? () => inserts++ : null,
    onDelete: withDelete ? () => deletes++ : null,
  );
}

Future<PromptEditorController> _editor(WidgetTester t, HitlInputBlockConfig config, {String value = ''}) async {
  final c = PromptEditorController();
  addTearDown(c.dispose);
  await pumpComponent(t, DifyPromptEditor(controller: c, value: value, hitlInputBlock: config));
  return c;
}

DifyPromptEditorState _state(WidgetTester t) => t.state<DifyPromptEditorState>(find.byType(DifyPromptEditor));

int _hitlCount(PromptEditorController c) {
  var n = 0;
  for (var i = 0; i < c.text.length; i++) {
    if (c.blockAt(i)?.kind == PromptBlockKind.hitlInput) n++;
  }
  return n;
}

const _variables = [
  VarGroup(nodeId: 'env', title: 'Env', vars: [PickerVar('env.api_key', 'string')]),
  VarGroup(nodeId: 'conversation', title: 'Conversation', vars: [PickerVar('conversation.user_id', 'number')]),
  VarGroup(nodeId: 'rag', title: 'RAG', vars: [PickerVar('rag.shared.file_name', 'string', isRagVariable: true)]),
  VarGroup(
    nodeId: 'node-1',
    title: 'Node 1',
    vars: [PickerVar('node-1.ignore_me', 'string'), PickerVar('node-1.doc_name', 'string', isRagVariable: true)],
  ),
];

List<String> _names(List<PickerVar>? vars) => [for (final v in vars ?? const <PickerVar>[]) v.variable];

const _varNodes = {
  'node-1': WorkflowNodeInfo(title: 'Node One', type: 'llm'),
  'node-rag': WorkflowNodeInfo(title: 'Retriever', type: 'llm'),
};

/// The variable block's error state (Dify's warning icon).
Future<bool> _invalid(
  WidgetTester t,
  List<String> variables, {
  Map<String, WorkflowNodeInfo> nodes = const {},
  List<PickerVar>? env,
  List<PickerVar>? conversation,
  List<PickerVar>? rag,
}) async {
  await pumpComponent(
    t,
    HitlInputVariableBlock(
      variables: variables,
      workflowNodesMap: nodes,
      environmentVariables: env,
      conversationVariables: conversation,
      ragVariables: rag,
    ),
  );
  return t.widget<VariableLabel>(find.byType(VariableLabel)).errorMsg != null;
}

void main() {
  group('HITLInputComponentUI', () {
    group('Rendering', () {
      testWidgets('should render action buttons correctly', (t) async {
        await pumpComponent(t, _chip(_Chip()));
        await hover(t, find.byType(InputFieldChip));
        expect(_editButton(), findsOneWidget);
        expect(_removeButton(), findsOneWidget);
      });

      testWidgets('should render variable block when default type is variable', (t) async {
        await pumpComponent(
          t,
          _chip(
            _Chip(),
            formInput: _paragraph(
              def: {
                'type': 'variable',
                'selector': ['node-2', 'answer'],
                'value': '',
              },
            ),
          ),
        );
        expect(find.text('Node 2'), findsOneWidget);
        expect(find.text('answer'), findsOneWidget);
      });

      testWidgets('should hide action buttons when readonly is true', (t) async {
        await pumpComponent(t, _chip(_Chip(), readonly: true));
        await hover(t, find.byType(InputFieldChip));
        expect(_editButton(), findsNothing);
        expect(_removeButton(), findsNothing);
      });

      testWidgets('should close the edit modal when readonly becomes true', (t) async {
        final calls = _Chip();
        await pumpComponent(t, _chip(calls));
        await _openEdit(t);
        expect(_nameField(), findsOneWidget);
        await pumpComponent(t, _chip(calls, readonly: true));
        await t.pump(const Duration(milliseconds: 300));
        expect(_nameField(), findsNothing);
      });

      testWidgets('should render select option summary for constant options', (t) async {
        await pumpComponent(
          t,
          _chip(
            _Chip(),
            formInput: {
              'type': 'select',
              'output_variable_name': 'customer_name',
              'option_source': {
                'type': 'constant',
                'selector': <Object?>[],
                'value': ['alpha', 'beta'],
              },
            },
          ),
        );
        expect(find.text('alpha, beta'), findsOneWidget);
      });

      testWidgets('should render input type label after the summary content', (t) async {
        await pumpComponent(
          t,
          _chip(
            _Chip(),
            formInput: {
              'type': 'select',
              'output_variable_name': 'customer_name',
              'option_source': {
                'type': 'constant',
                'selector': <Object?>[],
                'value': ['alpha', 'beta'],
              },
            },
          ),
        );
        // `system-2xs-medium uppercase`.
        final label = find.text('APP-DEBUG.VARIABLECONFIG.SELECT');
        expect(label, findsOneWidget);
        expect(t.getTopLeft(label).dx, greaterThan(t.getTopRight(find.text('alpha, beta')).dx));
      });

      testWidgets('should render file-list placeholder instead of selected file details', (t) async {
        await pumpComponent(
          t,
          _chip(
            _Chip(),
            formInput: {
              'type': 'file-list',
              'output_variable_name': 'customer_name',
              'allowed_file_extensions': ['.pdf'],
              'allowed_file_types': ['document'],
              'allowed_file_upload_methods': ['local_file'],
              'number_limits': 4,
            },
          ),
        );
        expect(find.text('app-debug.variableConfig.multi-files'), findsOneWidget);
        expect(find.text('APP-DEBUG.VARIABLECONFIG.MULTI-FILES'), findsOneWidget);
        expect(find.textContaining('document'), findsNothing);
        expect(find.textContaining('4'), findsNothing);
      });

      testWidgets('should render single-file placeholder instead of selected file details', (t) async {
        await pumpComponent(
          t,
          _chip(
            _Chip(),
            formInput: {
              'type': 'file',
              'output_variable_name': 'customer_name',
              'allowed_file_extensions': ['.pdf'],
              'allowed_file_types': ['document'],
              'allowed_file_upload_methods': ['local_file'],
            },
          ),
        );
        expect(find.text('app-debug.variableConfig.single-file'), findsOneWidget);
        expect(find.text('APP-DEBUG.VARIABLECONFIG.SINGLE-FILE'), findsOneWidget);
        expect(find.textContaining('document'), findsNothing);
      });
    });

    group('Remove action', () {
      testWidgets('should call onRemove when remove button is clicked', (t) async {
        final block = _Block();
        await pumpComponent(t, HitlInputComponent(varName: 'customer_name', config: block.config()));
        await hover(t, find.byType(InputFieldChip));
        await t.tap(_removeButton());
        await t.pump();
        expect(block.removes, ['customer_name']);
      });
    });

    group('Edit flow', () {
      testWidgets('should close modal without update when cancel is clicked', (t) async {
        final calls = _Chip();
        await pumpComponent(t, _chip(calls, formInput: _paragraph()));
        await _openEdit(t);
        expect(_nameField(), findsOneWidget);
        await tapAndSettle(t, find.text('common.operation.cancel'));
        expect(calls.changes, isEmpty);
        expect(calls.renames, isEmpty);
        expect(_nameField(), findsNothing);
      });

      testWidgets('should prevent renaming to an existing variable name', (t) async {
        final calls = _Chip();
        await pumpComponent(t, _chip(calls, formInput: _paragraph(), unavailable: const ['existing_name']));
        await _openEdit(t);
        await t.enterText(_nameField(), 'existing_name');
        await t.pump();
        expect(find.text(hiKey('insertInputField.variableNameDuplicated')), findsOneWidget);
        final save = find.widgetWithText(DifyButton, 'common.operation.save');
        expect(t.widget<DifyButton>(save).disabled, isTrue);
        await t.tap(save);
        await t.pump();
        expect(calls.changes, isEmpty);
        expect(calls.renames, isEmpty);
      });
    });

    group('Default formInput', () {
      testWidgets('should open an empty default editor when formInput is undefined', (t) async {
        await pumpComponent(t, _chip(_Chip()));
        await _openEdit(t);
        expect(t.widget<EditableText>(_nameField()).controller.text, '');
        expect(t.widget<DifyButton>(find.widgetWithText(DifyButton, 'common.operation.save')).disabled, isTrue);
      });

      testWidgets('should render variable selector when workflowNodesMap fallback is used', (t) async {
        await pumpComponent(
          t,
          _chip(
            _Chip(),
            nodes: const {},
            formInput: _paragraph(
              def: {
                'type': 'variable',
                'selector': ['node-2', 'answer'],
                'value': '',
              },
            ),
          ),
        );
        expect(find.text('answer'), findsOneWidget);
      });
    });
  });

  group('HITLInputComponent', () {
    // Dify's spec mocks the chip and emits its onChange; here the real chip's onChange is called.
    Map<String, Object?> input([String name = 'user_name', String value = 'hello']) => _paragraph(
      name: name,
      def: {'type': 'constant', 'selector': <Object?>[], 'value': value},
    );

    Future<_Block> renderComponent(WidgetTester t, List<Object?> formInputs) async {
      final block = _Block();
      await pumpComponent(
        t,
        HitlInputComponent(
          varName: 'user_name',
          config: block.config(formInputs: formInputs),
        ),
      );
      return block;
    }

    void emit(WidgetTester t, Map<String, Object?> payload) =>
        t.widget<InputFieldChip>(find.byType(InputFieldChip)).onChange(payload);

    testWidgets('should append payload when matching form input does not exist', (t) async {
      final block = await renderComponent(t, const []);
      emit(t, input());
      expect(block.changes, hasLength(1));
      expect(block.changes.single, hasLength(1));
      expect((block.changes.single.single! as Map)['output_variable_name'], 'user_name');
    });

    testWidgets('should replace payload when variable name is renamed', (t) async {
      final block = await renderComponent(t, [input()]);
      emit(t, input('renamed_name'));
      expect(block.changes, hasLength(1));
      expect((block.changes.single.first! as Map)['output_variable_name'], 'renamed_name');
    });

    testWidgets('should ignore rename when the target variable name already exists', (t) async {
      final block = await renderComponent(t, [input(), input('renamed_name')]);
      emit(t, input('renamed_name'));
      expect(block.changes, isEmpty);
    });

    testWidgets('should update existing payload when variable name stays the same', (t) async {
      final block = await renderComponent(t, [input(), input('other_name', 'other')]);
      emit(t, input('user_name', 'updated'));
      expect(block.changes, hasLength(1));
      final next = block.changes.single.cast<Map<String, Object?>>();
      expect((next[0]['default']! as Map)['value'], 'updated');
      expect(next[0]['output_variable_name'], 'user_name');
      expect(next[1]['output_variable_name'], 'other_name');
      expect((next[1]['default']! as Map)['value'], 'other');
    });
  });

  group('HITLInputReplacementBlock', () {
    group('Replacement behavior', () {
      testWidgets(
        'should replace matched output token with hitl input node and map variables from all supported sources',
        (t) async {
          String? getVarType(String _, List<String> _) => 'string';
          final c = await _editor(
            t,
            _Block().config(
              formInputs: [_paragraph(name: 'user_name')],
              variables: _variables,
              readonly: true,
              getVarType: getVarType,
            ),
            value: 'before {{#\$output.user_name#}} after',
          );
          expect(_hitlCount(c), 1);
          expect(c.prompt, 'before {{#\$output.user_name#}} after');
          final component = t.widget<HitlInputComponent>(find.byType(HitlInputComponent));
          expect(component.varName, 'user_name');
          expect(component.config.nodeId, 'node-1');
          final chip = t.widget<InputFieldChip>(find.byType(InputFieldChip));
          expect(chip.getVarType, same(getVarType));
          expect(chip.readonly, isTrue);
          expect(_names(chip.environmentVariables), ['env.api_key']);
          expect(_names(chip.conversationVariables), ['conversation.user_id']);
          expect(_names(chip.ragVariables), ['rag.shared.file_name', 'node-1.doc_name']);
        },
      );

      testWidgets('should not replace text when no hitl output token exists', (t) async {
        final c = await _editor(
          t,
          _Block().config(variables: _variables),
          value: 'plain text without replacement token',
        );
        expect(_hitlCount(c), 0);
      });

      testWidgets(
        'should replace token with empty env conversation and rag lists when variables are not provided',
        (t) async {
          final c = await _editor(t, _Block().config(), value: '{{#\$output.user_name#}}');
          expect(_hitlCount(c), 1);
          final chip = t.widget<InputFieldChip>(find.byType(InputFieldChip));
          expect(chip.environmentVariables, isEmpty);
          expect(chip.conversationVariables, isEmpty);
          expect(chip.ragVariables, isEmpty);
          expect(chip.readonly, isFalse);
        },
      );

      testWidgets('should replace token with empty form inputs when formInputs is undefined', (t) async {
        final c = await _editor(t, _Block().config(formInputs: null), value: '{{#\$output.user_name#}}');
        expect(_hitlCount(c), 1);
        final chip = t.widget<InputFieldChip>(find.byType(InputFieldChip));
        expect(chip.formInput, isNull);
        expect(chip.unavailable, isEmpty);
      });
    });
  });

  group('HITLInputBlock', () {
    group('Workflow map command dispatch', () {
      testWidgets('should dispatch UPDATE_WORKFLOW_NODES_MAP when mounted', (t) async {
        const map = {'node-1': WorkflowNodeInfo(title: 'Map Node', type: 'start')};
        await _editor(t, _Block().config(nodes: map), value: '{{#\$output.user_name#}}');
        expect(t.widget<InputFieldChip>(find.byType(InputFieldChip)).nodesMap, same(map));
      });
    });

    group('Command handling', () {
      testWidgets('should insert hitl input block and call onInsert when insert command is dispatched', (t) async {
        final block = _Block();
        final c = await _editor(t, block.config());
        _state(t).runCommand(const InsertHitlInputBlockCommand('user_name'));
        await t.pump();
        expect(block.inserts, 1);
        expect(c.prompt, contains('{{#\$output.user_name#}}'));
        // INSERT_HITL_INPUT_BLOCK_COMMAND puts the field between line breaks.
        expect(c.prompt, '\n{{#\$output.user_name#}}\n');
        expect(_hitlCount(c), 1);
      });

      testWidgets('should insert hitl input block without onInsert callback', (t) async {
        final c = await _editor(t, _Block().config(withInsert: false));
        _state(t).runCommand(const InsertHitlInputBlockCommand('user_name'));
        await t.pump();
        expect(c.prompt, contains('{{#\$output.user_name#}}'));
        expect(_hitlCount(c), 1);
      });

      testWidgets('should update existing and newly inserted nodes when readonly changes', (t) async {
        final block = _Block();
        final c = PromptEditorController();
        addTearDown(c.dispose);
        Future<void> pumpWith(bool readonly) => pumpComponent(
          t,
          DifyPromptEditor(
            controller: c,
            hitlInputBlock: block.config(readonly: readonly),
          ),
        );
        List<bool> readonlyValues() => [
          for (final e in find.byType(InputFieldChip).evaluate()) (e.widget as InputFieldChip).readonly,
        ];
        await pumpWith(false);
        _state(t).runCommand(const InsertHitlInputBlockCommand('user_name'));
        await t.pump();
        expect(readonlyValues(), [false]);
        await pumpWith(true);
        expect(readonlyValues(), [true]);
        c.selection = TextSelection.collapsed(offset: c.text.length);
        _state(t).runCommand(const InsertHitlInputBlockCommand('user_name'));
        await t.pump();
        expect(readonlyValues(), [true, true]);
      });

      testWidgets('should call onDelete when delete command is dispatched', (t) async {
        final block = _Block();
        final c = await _editor(t, block.config(), value: '{{#\$output.user_name#}}');
        // useSelectOrDelete: the selected block deleted with Backspace.
        _state(t).focusNode.requestFocus();
        await t.pump();
        c.selection = const TextSelection(baseOffset: 0, extentOffset: 1);
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.backspace);
        await t.pump();
        expect(block.deletes, 1);
        expect(_hitlCount(c), 0);
      });

      testWidgets('should handle delete command without onDelete callback', (t) async {
        final c = await _editor(t, _Block().config(withDelete: false), value: '{{#\$output.user_name#}}');
        _state(t).focusNode.requestFocus();
        await t.pump();
        c.selection = const TextSelection(baseOffset: 0, extentOffset: 1);
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.backspace);
        await t.pump();
        expect(c.prompt, '');
      });
    });
  });

  group('HITLInputNode', () {
    testWidgets('should expose node metadata and configured properties through getters', (t) async {
      final block = _Block();
      String? getVarType(String _, List<String> _) => null;
      final inputs = [_paragraph(name: 'user_name')];
      const nodes = {'node-1': WorkflowNodeInfo(title: 'Node 1', type: 'start')};
      const variables = [
        VarGroup(nodeId: 'env', title: 'Env', vars: [PickerVar('env.var_a', 'string')]),
        VarGroup(nodeId: 'conversation', title: 'Conversation', vars: [PickerVar('conversation.var_b', 'number')]),
        VarGroup(nodeId: 'rag', title: 'RAG', vars: [PickerVar('rag.shared.var_c', 'string', isRagVariable: true)]),
      ];
      HitlInputBlockConfig config(bool readonly) => block.config(
        formInputs: inputs,
        variables: variables,
        nodes: nodes,
        getVarType: getVarType,
        readonly: readonly,
      );
      final c = PromptEditorController();
      addTearDown(c.dispose);
      await pumpComponent(
        t,
        DifyPromptEditor(controller: c, value: '{{#\$output.user_name#}}', hitlInputBlock: config(true)),
      );
      expect(PromptBlock.hitlInput('user_name').text, '{{#\$output.user_name#}}');
      expect(c.blockAt(0), PromptBlock.hitlInput('user_name'));
      final component = t.widget<HitlInputComponent>(find.byType(HitlInputComponent));
      expect(component.varName, 'user_name');
      expect(component.config.nodeId, 'node-1');
      expect(component.config.formInputs, inputs);
      var chip = t.widget<InputFieldChip>(find.byType(InputFieldChip));
      expect(chip.formInput, inputs.single);
      expect(chip.nodesMap, same(nodes));
      expect(chip.getVarType, same(getVarType));
      expect(_names(chip.environmentVariables), ['env.var_a']);
      expect(_names(chip.conversationVariables), ['conversation.var_b']);
      expect(_names(chip.ragVariables), ['rag.shared.var_c']);
      expect(chip.readonly, isTrue);
      // The chip's remove and rename reach the configured callbacks.
      chip.onRemove();
      chip.onRename!({..._paragraph(name: 'next')}, 'user_name');
      expect(block.removes, ['user_name']);
      expect(block.renames.single.$2, 'user_name');
      await pumpComponent(t, DifyPromptEditor(controller: c, hitlInputBlock: config(false)));
      chip = t.widget<InputFieldChip>(find.byType(InputFieldChip));
      expect(chip.readonly, isFalse);
      expect(c.prompt, '{{#\$output.user_name#}}');
    });

    test('should return default fallback values for optional properties', () {
      final sources = hitlVariableSources(null);
      expect(sources.environment, isEmpty);
      expect(sources.conversation, isEmpty);
      expect(sources.rag, isEmpty);
      expect(
        HitlInputBlockConfig(nodeId: 'n', onFormInputItemRemove: (_) {}, onFormInputItemRename: (_, _) {}).readonly,
        isFalse,
      );
    });

    testWidgets('should create and update DOM', (t) async {
      // `inline-flex w-[calc(100%-1px)] support-drag`: the field takes its line's width, and its line can be dragged.
      await pumpComponent(
        t,
        DifyPromptEditor(value: 'a\n{{#\$output.user_name#}}\nb', hitlInputBlock: _Block().config()),
      );
      final editorWidth = t.getSize(find.byType(DifyPromptEditor)).width;
      expect(t.getSize(find.byType(InputFieldChip)).width, closeTo(editorWidth, 2));
      final mouse = await hover(t, find.byType(InputFieldChip));
      expect(find.byKey(const Key('draggable-menu')), findsOneWidget);
      // The first line ("a") holds no field: no drag menu.
      await mouse.moveTo(t.getTopLeft(find.byType(DifyPromptEditor)) + const Offset(4, 10));
      await t.pump();
      expect(find.byKey(const Key('draggable-menu')), findsNothing);
    });
  });

  group('HITLInputVariableBlockComponent', () {
    group('Workflow map updates', () {
      testWidgets(
        'should update local workflow node map when UPDATE_WORKFLOW_NODES_MAP command is dispatched',
        (t) async {
          await pumpComponent(t, const HitlInputVariableBlock(variables: ['node-1', 'output']));
          expect(find.text('Node One'), findsNothing);
          expect(t.widget<VariableLabel>(find.byType(VariableLabel)).errorMsg, isNotNull);
          await pumpComponent(
            t,
            const HitlInputVariableBlock(variables: ['node-1', 'output'], workflowNodesMap: _varNodes),
          );
          expect(find.text('Node One'), findsOneWidget);
        },
      );
    });

    group('Validation branches', () {
      testWidgets('should show invalid state for env variable when environment list does not contain selector', (
        t,
      ) async {
        expect(await _invalid(t, ['env', 'api_key'], env: const []), isTrue);
      });

      testWidgets('should keep conversation variable valid when selector exists in conversation variables', (t) async {
        expect(
          await _invalid(
            t,
            ['conversation', 'session_id'],
            conversation: const [PickerVar('conversation.session_id', 'string')],
          ),
          isFalse,
        );
      });

      testWidgets('should show valid state when conversation variables array is undefined', (t) async {
        expect(await _invalid(t, ['conversation', 'session_id']), isFalse);
      });

      testWidgets('should show valid state when env variables array is undefined', (t) async {
        expect(await _invalid(t, ['env', 'api_key']), isFalse);
      });

      testWidgets('should show valid state when rag variables array is undefined', (t) async {
        expect(await _invalid(t, ['rag', 'node-rag', 'chunk'], nodes: _varNodes), isFalse);
      });

      testWidgets('should validate env variable when matching entry exists in multi-element array', (t) async {
        expect(
          await _invalid(
            t,
            ['env', 'api_key'],
            env: const [PickerVar('env.other_key', 'string'), PickerVar('env.api_key', 'string')],
          ),
          isFalse,
        );
      });

      testWidgets('should validate conversation variable when matching entry exists in multi-element array', (t) async {
        expect(
          await _invalid(
            t,
            ['conversation', 'session_id'],
            conversation: const [
              PickerVar('conversation.other', 'string'),
              PickerVar('conversation.session_id', 'string'),
            ],
          ),
          isFalse,
        );
      });

      testWidgets('should validate rag variable when matching entry exists in multi-element array', (t) async {
        expect(
          await _invalid(
            t,
            ['rag', 'node-rag', 'chunk'],
            nodes: _varNodes,
            rag: const [
              PickerVar('rag.node-rag.other', 'string', isRagVariable: true),
              PickerVar('rag.node-rag.chunk', 'string', isRagVariable: true),
            ],
          ),
          isFalse,
        );
      });

      testWidgets('should handle undefined indices in variables array gracefully', (t) async {
        expect(await _invalid(t, ['env'], env: const [PickerVar('env.', 'string')]), isFalse);
        expect(
          await _invalid(t, ['conversation'], conversation: const [PickerVar('conversation.', 'string')]),
          isFalse,
        );
        expect(
          await _invalid(
            t,
            ['rag', 'node-rag'],
            nodes: _varNodes,
            rag: const [PickerVar('rag.node-rag.', 'string', isRagVariable: true)],
          ),
          isFalse,
        );
      });

      testWidgets('should keep global system variable valid without workflow node mapping', (t) async {
        expect(await _invalid(t, ['sys', 'global_name']), isFalse);
        expect(find.text('sys.global_name'), findsOneWidget);
      });

      testWidgets('should format system variable names with sys. prefix correctly', (t) async {
        // `sys.query` is shown as "query"; it is not a global variable, so it needs the start node.
        expect(await _invalid(t, ['sys', 'query']), isTrue);
        expect(find.text('query'), findsOneWidget);
      });

      testWidgets('should apply exception styling for recognized exception variables', (t) async {
        await pumpComponent(
          t,
          const HitlInputVariableBlock(variables: ['node-1', 'error_message'], workflowNodesMap: _varNodes),
        );
        expect(find.text('error_message'), findsOneWidget);
        expect(t.widget<VariableLabel>(find.byType(VariableLabel)).isExceptionVariable, isTrue);
      });
    });

    group('Full-path preview payload', () {
      testWidgets('should resolve the rag node via isRagVar offset and skip the full-path preview', (t) async {
        var calls = 0;
        await pumpComponent(
          t,
          HitlInputVariableBlock(
            variables: const ['rag', 'node-rag', 'chunk'],
            workflowNodesMap: _varNodes,
            ragVariables: const [PickerVar('rag.node-rag.chunk', 'string', isRagVariable: true)],
            getVarType: (_, _) {
              calls++;
              return 'number';
            },
          ),
        );
        expect(find.text('chunk'), findsOneWidget);
        expect(t.widget<VariableLabel>(find.byType(VariableLabel)).errorMsg, isNull);
        // The variable's own name tooltip is part of the label; what a RAG variable must not get is the full-path
        // preview, which is a DifyTooltip carrying a VarFullPathPanel.
        expect(find.byType(DifyTooltip), findsOneWidget, reason: 'the name tooltip stays');
        expect(
          t.widgetList<DifyTooltip>(find.byType(DifyTooltip)).where((tip) => tip.content is VarFullPathPanel),
          isEmpty,
          reason: 'no full-path preview for a RAG variable',
        );
        expect(calls, 0);
      });

      testWidgets('should use shortened display name for deep non-rag selectors', (t) async {
        final calls = <(String, List<String>)>[];
        await pumpComponent(
          t,
          HitlInputVariableBlock(
            variables: const ['node-1', 'parent', 'child'],
            workflowNodesMap: _varNodes,
            getVarType: (node, sel) {
              calls.add((node, sel));
              return 'string';
            },
          ),
        );
        expect(find.text('child'), findsOneWidget);
        expect(find.text('parent.child'), findsNothing);
        expect(calls.single.$1, 'node-1');
        expect(calls.single.$2, ['node-1', 'parent', 'child']);
      });
    });

    group('Optional lists and selector fallbacks', () {
      testWidgets('should keep env variable valid when environmentVariables is not provided', (t) async {
        expect(await _invalid(t, ['env', 'api_key']), isFalse);
      });

      testWidgets('should evaluate env selector fallback when selector second segment is missing', (t) async {
        expect(await _invalid(t, ['env'], env: const [PickerVar('env.', 'string')]), isFalse);
      });

      testWidgets('should keep conversation variable valid when conversationVariables is not provided', (t) async {
        expect(await _invalid(t, ['conversation', 'session_id']), isFalse);
      });

      testWidgets('should evaluate conversation selector fallback when selector second segment is missing', (t) async {
        expect(
          await _invalid(t, ['conversation'], conversation: const [PickerVar('conversation.', 'string')]),
          isFalse,
        );
      });

      testWidgets('should keep rag variable valid when ragVariables is not provided', (t) async {
        expect(await _invalid(t, ['rag', 'node-rag', 'chunk'], nodes: _varNodes), isFalse);
      });

      testWidgets('should evaluate rag selector fallbacks when node and key segments are missing', (t) async {
        expect(await _invalid(t, ['rag'], rag: const [PickerVar('rag..', 'string', isRagVariable: true)]), isFalse);
      });
    });
  });
}
