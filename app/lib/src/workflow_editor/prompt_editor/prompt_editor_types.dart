/// The block props of Dify's PromptEditor (base/prompt-editor/types.ts): which blocks the editor shows, whether the
/// picker may insert them, and their callbacks.
library;

import '../panel_fields/var_picker_model.dart';

/// QueryBlockType, RequestURLBlockType, ErrorMessageBlockType, LastRunBlockType: [show] turns the placeholder into
/// a block (and lists it in the picker); [selectable] lets the picker insert it.
class PromptBlockConfig {
  const PromptBlockConfig({this.show = false, this.selectable = false, this.onInsert, this.onDelete});
  final bool show;
  final bool selectable;
  final void Function()? onInsert;
  final void Function()? onDelete;
}

/// A knowledge base the context block lists (context-block `Dataset`).
class PromptDataset {
  const PromptDataset({required this.id, required this.name, this.type = 'dataset'});
  final String id;
  final String name;
  final String type;
}

/// ContextBlockType.
class ContextBlockConfig extends PromptBlockConfig {
  const ContextBlockConfig({
    super.show,
    super.selectable,
    super.onInsert,
    super.onDelete,
    this.datasets = const [],
    this.canNotAddContext = false,
    this.onAddContext,
  });
  final List<PromptDataset> datasets;
  final bool canNotAddContext;
  final void Function()? onAddContext;
}

/// history-block `RoleName`.
typedef PromptRoleName = ({String user, String assistant});

/// HistoryBlockType.
class HistoryBlockConfig extends PromptBlockConfig {
  const HistoryBlockConfig({
    super.show,
    super.selectable,
    super.onInsert,
    super.onDelete,
    this.history = (user: '', assistant: ''),
    this.onEditRole,
  });
  final PromptRoleName history;
  final void Function()? onEditRole;
}

/// `GeneratorType` of the current block (`current_prompt` / `current_code`).
enum PromptGeneratorType { prompt, code }

/// CurrentBlockType.
class CurrentBlockConfig extends PromptBlockConfig {
  const CurrentBlockConfig({
    super.show,
    super.onInsert,
    super.onDelete,
    this.generatorType = PromptGeneratorType.prompt,
  }) : super(selectable: true);
  final PromptGeneratorType generatorType;
}

/// An app variable the picker offers as `{{name}}` (types.ts `Option`).
typedef PromptOption = ({String value, String name});

/// VariableBlockType.
class VariableBlockConfig {
  const VariableBlockConfig({this.show = false, this.variables});
  final bool show;
  final List<PromptOption>? variables;
}

/// ExternalToolOption.
class ExternalToolOption {
  const ExternalToolOption({required this.name, required this.variableName, this.icon, this.iconBackground});
  final String name;
  final String variableName;
  final String? icon;
  final String? iconBackground;
}

/// ExternalToolBlockType.
class ExternalToolBlockConfig {
  const ExternalToolBlockConfig({this.show = false, this.externalTools, this.onAddExternalTool});
  final bool show;
  final List<ExternalToolOption>? externalTools;
  final void Function()? onAddExternalTool;
}

/// One entry of `WorkflowNodesMap`: what a variable block shows of the node it refers to.
class WorkflowNodeInfo {
  const WorkflowNodeInfo({required this.title, required this.type, this.modelProvider});
  final String title;
  final String type;

  /// The LLM node's model provider (`modelProvider`).
  final String? modelProvider;
}

/// The variable type for a value selector (`getVarType`).
typedef PromptGetVarType = String? Function(String nodeId, List<String> valueSelector);

/// WorkflowVariableBlockType. [onJumpToNode] is the block's click (Dify centres the canvas on the node);
/// [isModelPluginInstalled] answers `useLlmModelPluginInstalled` for a plugin id (`org/name`); null: installed.
class WorkflowVariableBlockConfig {
  const WorkflowVariableBlockConfig({
    this.show = false,
    this.variables = const [],
    this.workflowNodesMap = const {},
    this.onInsert,
    this.onDelete,
    this.getVarType,
    this.showManageInputField = false,
    this.onManageInputField,
    this.onJumpToNode,
    this.isModelPluginInstalled,
  });
  final bool show;

  /// The variables the picker offers (Dify's `variables`, `NodeOutPutVar[]`).
  final List<VarGroup> variables;
  final Map<String, WorkflowNodeInfo> workflowNodesMap;
  final void Function()? onInsert;
  final void Function()? onDelete;
  final PromptGetVarType? getVarType;
  final bool showManageInputField;
  final void Function()? onManageInputField;
  final void Function(String nodeId)? onJumpToNode;
  final bool Function(String pluginId)? isModelPluginInstalled;
}

/// `extractPluginId` (workflow/utils/plugin.ts).
String extractPluginId(String provider) {
  final parts = provider.split('/');
  return parts.length >= 2 ? '${parts[0]}/${parts[1]}' : provider;
}

/// AgentOutputBlockType: `[§output:name:name§]` tokens become output blocks; the `/` picker offers "New output".
/// [outputs] are Dify's DeclaredOutputConfig JSON; [onChange] gets the next outputs and the prompt with the change;
/// [onEdit] asks to edit a committed output (its name and type option value).
class AgentOutputBlockConfig {
  const AgentOutputBlockConfig({this.show = false, this.outputs = const [], this.onChange, this.onEdit});
  final bool show;
  final List<Map<String, Object?>> outputs;
  final void Function(List<Map<String, Object?>> outputs, String? prompt)? onChange;
  final void Function(String name, String outputType)? onEdit;
}

/// HITLInputBlockType: `{{#$output.name#}}` tokens become the human input node's form fields. [formInputs] are the
/// node's FormInputItem JSON; [variables] the workflow variables (env, conversation and RAG lists are taken from
/// them); [onFormInputsChange] gets the inputs with one edited in place.
class HitlInputBlockConfig {
  const HitlInputBlockConfig({
    this.show = false,
    required this.nodeId,
    this.formInputs,
    this.variables,
    this.workflowNodesMap = const {},
    this.getVarType,
    this.onFormInputsChange,
    required this.onFormInputItemRemove,
    required this.onFormInputItemRename,
    this.onInsert,
    this.onDelete,
    this.readonly = false,
    this.scope,
  });
  final bool show;
  final String nodeId;
  final List<Object?>? formInputs;
  final List<VarGroup>? variables;
  final Map<String, WorkflowNodeInfo> workflowNodesMap;
  final PromptGetVarType? getVarType;
  final void Function(List<Object?> inputs)? onFormInputsChange;
  final void Function(String varName) onFormInputItemRemove;
  final void Function(Map<String, Object?> payload, String oldName) onFormInputItemRename;
  final void Function()? onInsert;
  final void Function()? onDelete;
  final bool readonly;

  /// What the field editor's variable pickers offer (Dify's pickers read the workflow store); null: [variables].
  final VarScope? scope;
}
