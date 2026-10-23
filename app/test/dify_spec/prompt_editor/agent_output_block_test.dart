// dify-spec: web/app/components/base/prompt-editor/plugins/agent-output-block/__tests__/component.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/agent-output-block/__tests__/node.spec.tsx
//
// The agent output block. Dify's spec mocks the Lexical editor and node the component reaches by key; here the
// component's [AgentOutputBlockHost] is a recording fake with the same calls (setOutput, selectNext, focus).
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/agent_output_block.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workflow/nodes_panel/data/human_input_test_kit.dart' show hover, pumpComponent, tapAndSettle;

class _Host implements AgentOutputBlockHost {
  _Host({this.prompt = '[§output:summary:summary§]'});

  @override
  String prompt;
  bool replaced = false;
  final setOutputs = <List<Object?>>[];
  var selectNexts = 0, focuses = 0;
  final openTypeSelects = <bool>[];

  @override
  bool setOutput(
    String name,
    String outputType,
    bool isEditing,
    List<Map<String, Object?>> outputs,
    bool selectNameOnEdit,
    bool openTypeSelectOnEdit,
  ) {
    if (replaced) return false;
    setOutputs.add([name, outputType, isEditing, outputs, selectNameOnEdit, openTypeSelectOnEdit]);
    return true;
  }

  @override
  void selectNext() => selectNexts++;

  @override
  void focusEditor() => focuses++;

  @override
  void setOpenTypeSelectOnEdit(bool value) => openTypeSelects.add(value);
}

const _outputs = [
  {'name': 'output', 'type': 'string', 'required': false},
];

/// The recorded `onChange(outputs, prompt)` calls.
typedef _Changes = List<(List<Map<String, Object?>>, String?)>;

Future<void> _render(
  WidgetTester t,
  _Host host, {
  String name = 'output',
  String outputType = 'string',
  bool isEditing = true,
  bool? selectNameOnEdit,
  bool openTypeSelectOnEdit = false,
  _Changes? changes,
  void Function(String, String)? onEdit,
}) async {
  await pumpComponent(
    t,
    Align(
      alignment: Alignment.topLeft,
      child: AgentOutputBlockComponent(
        host: host,
        name: name,
        outputType: outputType,
        isEditing: isEditing,
        selectNameOnEdit: selectNameOnEdit,
        openTypeSelectOnEdit: openTypeSelectOnEdit,
        outputs: _outputs,
        onChange: changes == null ? null : (o, p) => changes.add((o, p)),
        onEdit: onEdit,
      ),
    ),
  );
  await t.pump();
}

Finder _nameInput() => find.descendant(of: find.byType(AgentOutputBlockComponent), matching: find.byType(EditableText));
AgentOutputBlockComponentState _state(WidgetTester t) =>
    t.state<AgentOutputBlockComponentState>(find.byType(AgentOutputBlockComponent));

/// Whether the type select's list is open (its options are shown).
bool _typeSelectOpen() => find.text('array[boolean]').evaluate().isNotEmpty;

Matcher _outputNamed(String name, [String type = 'string']) =>
    contains(predicate<Map<String, Object?>>((o) => o['name'] == name && o['type'] == type, '$name: $type'));

void main() {
  group('AgentOutputBlockComponent', () {
    testWidgets('focuses and selects the output name while editing a newly inserted output block', (t) async {
      await _render(t, _Host());
      final s = _state(t);
      expect(s.nameFocus.hasFocus, isTrue);
      expect(s.draft.selection, const TextSelection(baseOffset: 0, extentOffset: 6));
    });

    testWidgets('focuses without selecting the output name after an edited output name is committed', (t) async {
      await _render(t, _Host(), name: 'summary', selectNameOnEdit: false);
      final s = _state(t);
      expect(s.nameFocus.hasFocus, isTrue);
      expect(s.draft.selection, const TextSelection.collapsed(offset: 7));
    });

    testWidgets('keeps the type select open after the edited output block is remounted', (t) async {
      await _render(t, _Host(), name: 'summary', selectNameOnEdit: false, openTypeSelectOnEdit: true);
      await t.pump(const Duration(milliseconds: 300));
      expect(_typeSelectOpen(), isTrue);
    });

    testWidgets('does not update the Lexical node while typing an output name and commits on blur', (t) async {
      final host = _Host();
      final changes = _Changes.empty(growable: true);
      await _render(t, host, changes: changes);
      await t.enterText(_nameInput(), 'summary');
      await t.pump();
      expect(_state(t).draft.text, 'summary');
      expect(host.setOutputs, isEmpty);
      expect(changes, isEmpty);
      _state(t).nameFocus.unfocus();
      await t.pump();
      expect(host.setOutputs, hasLength(1));
      final call = host.setOutputs.single;
      expect(call[0], 'summary');
      expect(call[1], 'string');
      expect(call[2], isFalse);
      expect(call[3], _outputNamed('summary'));
      expect(call.sublist(4), [false, false]);
      expect(host.focuses, 0);
      expect(changes.single.$1, _outputNamed('summary'));
      expect(changes.single.$2, '[§output:summary:summary§]');
    });

    testWidgets(
      'syncs the output name and moves the editor selection after the output block when committing with Enter',
      (t) async {
        final host = _Host(prompt: 'Generate [§output:output:output§]');
        final changes = _Changes.empty(growable: true);
        await _render(t, host, changes: changes);
        await t.enterText(_nameInput(), 'summary');
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await t.pump();
        expect(host.setOutputs.single.sublist(0, 3), ['summary', 'string', false]);
        expect(host.setOutputs.single.sublist(4), [false, false]);
        expect(host.selectNexts, 1);
        expect(_typeSelectOpen(), isFalse);
        expect(changes.single.$1, _outputNamed('summary'));
        expect(changes.single.$2, 'Generate [§output:summary:summary§]');
        expect(host.focuses, 1);
      },
    );

    testWidgets('syncs the output name and opens the type select when committing with Tab', (t) async {
      final host = _Host(prompt: 'Generate [§output:output:output§]');
      final changes = _Changes.empty(growable: true);
      await _render(t, host, changes: changes);
      await t.enterText(_nameInput(), 'summary');
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(host.setOutputs.single.sublist(0, 3), ['summary', 'string', true]);
      expect(host.setOutputs.single.sublist(4), [false, true]);
      expect(host.selectNexts, 0);
      expect(_typeSelectOpen(), isTrue);
      final s = _state(t);
      expect(s.nameFocus.hasFocus, isFalse);
      expect(s.draft.selection, const TextSelection.collapsed(offset: 7));
      expect(changes.single.$2, 'Generate [§output:summary:summary§]');
    });

    testWidgets('commits the input DOM value on Enter even before React state rerenders', (t) async {
      final host = _Host();
      await _render(t, host, changes: _Changes.empty(growable: true));
      // The field's text, not a rebuilt widget state, is what Enter commits.
      _state(t).draft.text = 'summary';
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(host.setOutputs.single[0], 'summary');
      expect(host.selectNexts, 1);
    });

    testWidgets('does not commit output names containing dots', (t) async {
      final host = _Host();
      final changes = _Changes.empty(growable: true);
      await _render(t, host, changes: changes);
      await t.enterText(_nameInput(), 'qna_report.pdf');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(host.setOutputs, isEmpty);
      expect(host.selectNexts, 0);
      expect(changes, isEmpty);
    });

    testWidgets('does not commit the name blur before selecting an output type', (t) async {
      final host = _Host();
      final changes = _Changes.empty(growable: true);
      await _render(t, host, changes: changes);
      await t.enterText(_nameInput(), 'summary');
      await t.pump();
      await tapAndSettle(t, find.byKey(const Key('agent-output-type-trigger')));
      expect(changes, isEmpty);
      await tapAndSettle(t, find.text('file'));
      expect(host.setOutputs.single.sublist(0, 3), ['summary', 'file', false]);
      expect(host.setOutputs.single[3], _outputNamed('summary', 'file'));
      expect(host.setOutputs.single.sublist(4), [false, false]);
    });

    testWidgets('does not save stale output data when the Lexical node has already been replaced', (t) async {
      final host = _Host()..replaced = true;
      final changes = _Changes.empty(growable: true);
      await _render(t, host, changes: changes);
      await t.enterText(_nameInput(), 'summary');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(host.setOutputs, isEmpty);
      expect(changes, isEmpty);
      expect(host.focuses, 0);
    });

    testWidgets('renders the committed output block as non-editable adaptive text', (t) async {
      await _render(t, _Host(), name: 'qna_report_pdf', outputType: 'file', isEditing: false);
      expect(_nameInput(), findsNothing);
      expect(find.byKey(const Key('agent-output-type-trigger')), findsNothing);
      expect(find.text('qna_report_pdf'), findsOneWidget);
      // `system-2xs-medium-uppercase`.
      expect(find.text('FILE'), findsOneWidget);
    });

    testWidgets('requests the output editor when clicking a committed output block', (t) async {
      final edits = <(String, String)>[];
      await _render(
        t,
        _Host(),
        name: 'qna_report_pdf',
        outputType: 'file',
        isEditing: false,
        onEdit: (n, ty) => edits.add((n, ty)),
      );
      await hover(t, find.text('qna_report_pdf'));
      // `cursor-pointer`, and the edit icon in place of the variable icon.
      expect(
        find.byWidgetPredicate((w) => w is MouseRegion && w.cursor == SystemMouseCursors.click),
        findsWidgets,
      );
      expect(find.byWidgetPredicate((w) => w is RemixIcon && w.name == 'edit-2-line'), findsOneWidget);
      expect(edits, isEmpty);
      await t.tap(find.text('qna_report_pdf'));
      expect(edits, [('qna_report_pdf', 'file')]);
    });
  });

  group('AgentOutputBlockNode', () {
    test('should persist output tokens with bracket wrappers', () {
      expect(PromptBlock.agentOutput('summary').text, '[§output:summary:summary§]');
      expect(getAgentOutputToken('summary'), '[§output:summary:summary§]');
    });

    test('should select the output name only for newly inserted editing nodes', () {
      AgentOutputBlockComponent block({bool? selectName, bool openTypeSelect = false}) => AgentOutputBlockComponent(
        host: _Host(),
        name: 'output',
        outputType: 'string',
        isEditing: true,
        selectNameOnEdit: selectName,
        openTypeSelectOnEdit: openTypeSelect,
      );
      expect(block().selectNameOnEdit, isTrue);
      expect(block(selectName: false).selectNameOnEdit, isFalse);
      expect(block(selectName: false, openTypeSelect: true).openTypeSelectOnEdit, isTrue);
    });

    test('should parse bracketed output tokens and legacy bare tokens', () {
      expect(parseAgentOutputToken('before [§output:summary:summary§] after'), (name: 'summary', start: 7, end: 33));
      expect(parseAgentOutputToken('before §output:summary:summary§ after'), (name: 'summary', start: 7, end: 31));
      expect(parseAgentOutputToken('[§skill:summary:summary§]'), isNull);
    });

    test('should extract output names from bracketed and legacy tokens', () {
      expect(extractAgentOutputNames('A [§output:summary:summary§] B §output:final_summary:final_summary§').toList(), [
        'summary',
        'final_summary',
      ]);
    });

    test('should replace only matching output token names', () {
      expect(
        replaceAgentOutputName('Use [§output:summary:summary§] and §output:other:other§', 'summary', 'final_summary'),
        'Use [§output:final_summary:final_summary§] and §output:other:other§',
      );
      expect(
        replaceAgentOutputName('Generate [§output:output:output§] and §output:output:output§', 'output', 'summary'),
        'Generate [§output:summary:summary§] and §output:summary:summary§',
      );
    });

    test('should create node with helper and support type guard checks', () {
      final block = PromptBlock.agentOutput('result');
      expect(block.kind, PromptBlockKind.agentOutput);
      expect(block.text, '[§output:result:result§]');
      final c = PromptEditorController(
        prompt: 'a [§output:result:result§]',
        blocks: PromptBlockSet(const {PromptBlockKind.agentOutput}),
      );
      addTearDown(c.dispose);
      expect(c.blockAt(2)?.kind, PromptBlockKind.agentOutput);
      expect(c.blockAt(0), isNull);
      expect(c.blockAt(-1), isNull);
      expect(c.blockAt(3), isNull);
    });
  });
}
