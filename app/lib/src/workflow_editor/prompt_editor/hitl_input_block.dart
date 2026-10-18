/// The human input form field block of the prompt editor (base/prompt-editor/plugins/hitl-input-block: component.tsx,
/// variable-block.tsx and the variable lists of hitl-input-block-replacement-block.tsx). The chip itself
/// (component-ui.tsx) and the field editor (input-field.tsx, pre-populate.tsx, type-switch.tsx, tag-label.tsx) are
/// [InputFieldChip] and [InputFieldEditor] of the Human Input panel.
///
/// A field is one block character of the editor text (`{{#$output.name#}}`), drawn full width in its line
/// (`inline-flex w-[calc(100%-1px)] align-middle`); the editor inserts it in a line of its own.
library;

import 'package:flutter/widgets.dart';

import '../../cards/variable_label.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/var_types.dart' show VarType;
import '../node_panel/bodies/data/human_input/form_content.dart' show InputFieldChip;
import '../node_panel/bodies/data/human_input/human_input_model.dart' show inputNameOf;
import '../panel_fields/var_picker_model.dart';
import '../panel_fields/var_reference_vars.dart' show VarFullPathPanel;
import 'prompt_chips.dart' show isExceptionVariable;
import 'prompt_editor_types.dart';

/// The variable lists the replacement block hands each field: the `env` and `conversation` groups' variables, and
/// the RAG variables (the `rag` group's, then every other group's `isRagVariable` ones).
({List<PickerVar> environment, List<PickerVar> conversation, List<PickerVar> rag}) hitlVariableSources(
  List<VarGroup>? variables,
) {
  final vars = variables ?? const <VarGroup>[];
  return (
    environment: vars.where((g) => g.nodeId == 'env').firstOrNull?.vars ?? const [],
    conversation: vars.where((g) => g.nodeId == 'conversation').firstOrNull?.vars ?? const [],
    rag: [
      for (final g in vars) ...(g.nodeId == 'rag' ? g.vars : g.vars.where((v) => v.isRagVariable)),
    ],
  );
}

/// HITLInputComponent's `handleChange`: [formInputs] with the field [varName] set to [payload] (appended when it has
/// no input yet, replaced in place when renamed); null when the new name is another field's.
List<Object?>? hitlInputsChange(List<Object?> formInputs, String varName, Map<String, Object?> payload) {
  final newName = inputNameOf(payload);
  final unavailable = [
    for (final x in formInputs)
      if (inputNameOf(x) != varName) inputNameOf(x),
  ];
  if (newName != varName && unavailable.contains(newName)) return null;
  final index = formInputs.indexWhere((x) => inputNameOf(x) == varName);
  if (index < 0) return [...formInputs, payload];
  return [for (final (i, x) in formInputs.indexed) i == index ? payload : x];
}

/// HITLInputVariableBlockComponent's checks for [variables]: the node it shows (the RAG node for `rag.*`), whether
/// only the last segment is shown, the exception colour and whether the reference is valid. An env, conversation or
/// RAG reference is checked against its list when one is given; a global system variable is always valid; any other
/// needs its node.
({WorkflowNodeInfo? node, bool showAPart, bool isException, bool valid}) hitlVariableState(
  List<String> variables, {
  Map<String, WorkflowNodeInfo> workflowNodesMap = const {},
  List<PickerVar>? environmentVariables,
  List<PickerVar>? conversationVariables,
  List<PickerVar>? ragVariables,
}) {
  final isRag = isRagVariableVar(variables);
  final showAPart = variables.length > 2 && !isRag;
  String at(int i) => i < variables.length ? variables[i] : '';
  final name = '${isSystemVar(variables) ? 'sys.' : ''}${variables.isEmpty ? '' : variables.last}';
  final node = workflowNodesMap[at(isRag ? 1 : 0)];
  final valid = () {
    if (isGlobalVar(variables)) return true;
    if (isEnvVar(variables)) {
      return environmentVariables?.any((v) => v.variable == '${at(0)}.${at(1)}') ?? true;
    }
    if (isConversationVar(variables)) {
      return conversationVariables?.any((v) => v.variable == '${at(0)}.${at(1)}') ?? true;
    }
    if (isRag) return ragVariables?.any((v) => v.variable == '${at(0)}.${at(1)}.${at(2)}') ?? true;
    return node != null;
  }();
  return (node: node, showAPart: showAPart, isException: isExceptionVariable(name, node?.type), valid: valid);
}

/// HITLInputVariableBlockComponent: the variable a field pre-fills from or takes its options from, as
/// VariableLabelInEditor, with the full path on hover for paths over two segments.
class HitlInputVariableBlock extends StatelessWidget {
  const HitlInputVariableBlock({
    super.key,
    required this.variables,
    this.workflowNodesMap = const {},
    this.getVarType,
    this.environmentVariables,
    this.conversationVariables,
    this.ragVariables,
  });

  final List<String> variables;
  final Map<String, WorkflowNodeInfo> workflowNodesMap;
  final PromptGetVarType? getVarType;
  final List<PickerVar>? environmentVariables, conversationVariables, ragVariables;

  @override
  Widget build(BuildContext context) {
    final s = hitlVariableState(
      variables,
      workflowNodesMap: workflowNodesMap,
      environmentVariables: environmentVariables,
      conversationVariables: conversationVariables,
      ragVariables: ragVariables,
    );
    final node = s.node;
    final label = VariableLabel(
      variant: VarLabelStyle.inEditor,
      variables: variables,
      nodeType: node?.type,
      nodeTitle: node?.title,
      isExceptionVariable: s.isException,
      errorMsg: s.valid ? null : DifyI18n.tr('workflow', 'errorMsg.invalidVariable'),
      notShowFullPath: s.showAPart,
    );
    if (node == null || !s.showAPart) return label;
    return DifyTooltip(
      surface: false,
      placement: DifyPlacement.bottom,
      sideOffset: 8,
      delay: const Duration(milliseconds: 300),
      content: VarFullPathPanel(
        nodeName: node.title,
        nodeType: node.type,
        path: variables.sublist(1),
        varType: getVarType == null ? VarType.string : getVarType!(variables[0], variables) ?? VarType.string,
      ),
      child: label,
    );
  }
}

/// HITLInputComponent: the field's chip (`w-full pt-3 pb-1`) for [varName], with its input from [formInputs] and the
/// other fields' names as the names it may not take. An edit keeping the name updates the inputs
/// ([HitlInputBlockConfig.onFormInputsChange]); a rename goes to `onFormInputItemRename`.
class HitlInputComponent extends StatelessWidget {
  const HitlInputComponent({super.key, required this.varName, required this.config, this.selected = false});

  final String varName;
  final HitlInputBlockConfig config;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = config;
    final formInputs = c.formInputs ?? const [];
    final payload = switch (formInputs.where((x) => inputNameOf(x) == varName).firstOrNull) {
      final Map<String, Object?> m => m,
      _ => null,
    };
    final sources = hitlVariableSources(c.variables);
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: InputFieldChip(
        varName: varName,
        formInput: payload,
        unavailable: [
          for (final x in formInputs)
            if (inputNameOf(x) != varName) inputNameOf(x),
        ],
        scope: c.scope ?? VarScope(vars: c.variables ?? const []),
        nodesMap: c.workflowNodesMap,
        getVarType: c.getVarType,
        environmentVariables: sources.environment,
        conversationVariables: sources.conversation,
        ragVariables: sources.rag,
        readonly: c.readonly,
        onChange: (p) {
          final next = hitlInputsChange(formInputs, varName, p);
          if (next != null) c.onFormInputsChange?.call(next);
        },
        onRename: c.onFormInputItemRename,
        onRemove: () => c.onFormInputItemRemove(varName),
      ),
    );
  }
}
