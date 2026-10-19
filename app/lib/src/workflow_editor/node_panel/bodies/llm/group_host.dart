/// What the model-node panels need from the host that the document does not hold: the workspace's models and their
/// parameter rules, the backend's default node configs, knowledge bases, agent strategies, the Agent v2 roster, and
/// the toasts Dify shows. Everything defaults to an empty workspace with no backend (lists empty, loaders absent),
/// so the panels work, read-only where they would need a service.
library;

import 'package:flutter/widgets.dart';

import '../../../../workflow/model_catalog.dart';
import '../../../../design/widgets/toast.dart';
import '../../../panel_fields/node_config.dart' show Json;
import '../../../prompt_editor/prompt_editor_types.dart' show extractPluginId;

/// dify-ui's toast types.
typedef LlmToastType = DifyToastType;

/// One page of a paged list (`{data, has_more}`).
typedef LlmPage = ({List<Json> data, bool hasMore});

/// The host's services for the model-node panels (see the library comment). Absent loaders mean "no backend": the
/// controls that need them are hidden or show their empty state.
@immutable
class LlmGroupServices {
  const LlmGroupServices({
    this.models = ModelCatalog.empty,
    this.defaultModels = const {},
    this.parameterRules,
    this.nodesDefaultConfigs = const {},
    this.toast = difyToast,
    this.openModelProviderSettings,
    this.refreshModels,
    this.flowType,
    this.fetchDatasets,
    this.fetchDatasetPage,
    this.canCreateDataset = false,
    this.openCreateDataset,
    this.updateDatasetsDetail,
    this.editDataset,
    this.canEditDataset,
    this.strategyProviders,
    this.fetchStrategy,
    this.agentInviteOptions,
    this.fetchRosterAgent,
    this.fetchInlineAgent,
    this.createInlineAgent,
    this.copyFromRoster,
    this.saveToRoster,
    this.openInlineAgentWorkspace,
    this.inlineAgentWorkspaceBuilder,
    this.rosterAgentContentBuilder,
    this.canCreateAgents = false,
    this.generatePrompt,
    this.generateJsonSchema,
  });

  static const empty = LlmGroupServices();

  // ----- models -----

  /// The workspace's providers and model lists.
  final ModelCatalog models;

  /// The workspace default model per model type (`ModelTypeEnum` value: `llm`, `rerank`, ...), Dify's
  /// `useModelListAndDefaultModelAndCurrentProviderAndModel(type).defaultModel`; `mode` from its model_properties.
  final Map<String, ({String provider, String model, String? mode})> defaultModels;

  /// `useModelParameterRules(provider, model)`: the rules (`ModelParameterRule` JSON) of a model; null without a
  /// backend (no parameters are listed).
  final Future<List<Json>> Function(String provider, String model)? parameterRules;

  /// `nodesDefaultConfigs` (the backend's default block configs, by node type): the LLM's prompt templates per model
  /// mode and the completion role prefixes.
  final Map<String, Json> nodesDefaultConfigs;

  /// Shows a toast (dify-ui `toast.*`); the app's toast host by default.
  final void Function(LlmToastType type, String message)? toast;

  /// The model selector footer's "Model Provider Settings" (and the empty state's "Configure").
  final VoidCallback? openModelProviderSettings;

  /// Refetches the workspace's providers and model lists: called when a model selector opens (Dify's model list
  /// queries refetch when the selector mounts them), so a model added elsewhere shows up.
  final VoidCallback? refreshModels;

  /// `configsMap.flowType` (`appFlow`, `ragPipeline`, `snippet`).
  final String? flowType;

  bool get isSnippetFlow => flowType == 'snippet';

  // ----- knowledge retrieval -----

  /// `fetchDatasets({ids})`: the details (Dify `DataSet` JSON) of the given knowledge bases.
  final Future<List<Json>> Function(List<String> ids)? fetchDatasets;

  /// `useInfiniteDatasets`: one page (1-based) of the workspace's knowledge bases for the "Select reference
  /// Knowledge" dialog.
  final Future<LlmPage> Function(int page)? fetchDatasetPage;

  /// `dataset.create_and_management` permission, and the dialog's "Go to create" link.
  final bool canCreateDataset;
  final VoidCallback? openCreateDataset;

  /// The datasets-detail store's `updateDatasetsDetail` (the canvas cards show the selected knowledge bases).
  final void Function(List<Json> datasets)? updateDatasetsDetail;

  /// The dataset settings drawer (SettingsModal): the edited dataset, or null when cancelled. No edit button
  /// without it.
  final Future<Json?> Function(Json dataset)? editDataset;

  /// `getDatasetACLCapabilities(...).canEdit` of a dataset (true when absent).
  final bool Function(Json dataset)? canEditDataset;

  // ----- agent (classic) -----

  /// `useStrategyProviders`: the agent strategy providers (Dify's `StrategyPluginDetail` JSON); null while unknown.
  final List<Json>? strategyProviders;

  /// `useStrategyProviderDetail(provider)`: one provider's detail (`{declaration: {strategies: [...]}}`).
  final Future<Json?> Function(String provider)? fetchStrategy;

  // ----- agent v2 -----

  /// `agent.inviteOptions` (`{limit: 8, page: 1, keyword}`): the roster agents the selector lists.
  final Future<List<Json>> Function(String keyword)? agentInviteOptions;

  /// GET `agent/{id}`: a roster agent's detail (`{id, name, role, description, icon, icon_type, icon_background}`).
  final Future<Json?> Function(String agentId)? fetchRosterAgent;

  /// GET the draft node's `agentComposer`: the inline agent of a node (`{agent: {...}}`).
  final Future<Json?> Function(String nodeId, String agentId)? fetchInlineAgent;

  /// PUT the draft node's `agentComposer` (node_job_only with the default soul): the new inline binding
  /// (`{binding_type: inline_agent, agent_id, current_snapshot_id}`), or null when it failed.
  final Future<Json?> Function(String nodeId)? createInlineAgent;

  /// POST `agentComposer/copyFromRoster`: the inline binding copied from a roster agent.
  final Future<Json?> Function(String nodeId, String sourceAgentId)? copyFromRoster;

  /// POST `agentComposer/saveToRoster`: the new roster agent id.
  final Future<String?> Function(String nodeId, Json form)? saveToRoster;

  /// Opens the inline agent configure workspace (Dify's AgentRosterInlineConfigureDialog) for a node.
  final void Function(String nodeId, Json binding)? openInlineAgentWorkspace;

  /// The body of the inline agent configure dialog (Dify's WorkflowInlineAgentConfigureWorkspace: orchestrate panel,
  /// build / preview chat); an empty panel when absent. [onSaved] takes the composer's new binding (autosave),
  /// [onSaveInlineToRoster] opens "Save to Agents" (null when not allowed).
  final Widget Function(BuildContext context, InlineAgentWorkspaceArgs args)? inlineAgentWorkspaceBuilder;

  /// The roster drawer's body (Dify's read-only WorkflowRosterAgentOrchestratePanelContent for an agent id); an
  /// empty panel when absent.
  final Widget Function(BuildContext context, String agentId)? rosterAgentContentBuilder;

  /// `useCanCreateAgents`.
  final bool canCreateAgents;

  // ----- generators -----

  /// The prompt generator (GetAutomaticResModal): the generated prompt for the instruction, or null.
  final Future<String?> Function(String nodeId, String currentPrompt)? generatePrompt;

  /// The JSON Schema generator: the generated schema for the instruction, or null.
  final Future<Json?> Function(String instruction)? generateJsonSchema;
}

/// What [LlmGroupServices.inlineAgentWorkspaceBuilder] gets.
typedef InlineAgentWorkspaceArgs = ({
  String nodeId,
  String? agentId,
  Json? composerState,
  VoidCallback onClose,
  ValueChanged<Json> onSaved,
  VoidCallback? onSaveInlineToRoster,
});

/// useLlmModelPluginInstalled over [catalog]: whether one of its providers comes from the plugin [pluginId]
/// (`org/name`).
bool Function(String pluginId) modelPluginInstalledIn(ModelCatalog catalog) =>
    (pluginId) => catalog.providers.any((p) => extractPluginId(p.provider) == pluginId);

/// Hands [services] to the model-node panels below it.
class LlmGroupScope extends InheritedWidget {
  const LlmGroupScope({super.key, required this.services, required super.child});

  final LlmGroupServices services;

  /// The nearest services, or [LlmGroupServices.empty].
  static LlmGroupServices of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LlmGroupScope>()?.services ?? LlmGroupServices.empty;

  @override
  bool updateShouldNotify(LlmGroupScope oldWidget) => services != oldWidget.services;
}
