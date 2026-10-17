import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../store/workflow_store.dart';
import '../store/workflow_store_scope.dart';
import 'header_data.dart';
import 'publisher/app_publisher.dart';

/// The host's publishing services (what features-trigger.tsx gets from its hooks and queries).
@immutable
class WorkflowPublishHooks {
  const WorkflowPublishHooks({
    this.checkBeforePublish,
    this.syncWorkflowDraft,
    this.publishWorkflow,
    this.onPublished,
  });

  /// useChecklistBeforePublish's handleCheckBeforePublish: false (after toasting why) refuses to publish.
  final Future<bool> Function()? checkBeforePublish;

  /// The draft-save barrier (handleSyncWorkflowDraft(true)): false refuses to publish.
  final Future<bool> Function()? syncWorkflowDraft;

  /// Publishes the draft as a new version; returns the published workflow (Dify's response, with `created_at` in
  /// seconds), or null when nothing was published.
  final Future<DifyJson?> Function({String title, String releaseNotes})? publishWorkflow;

  /// After a successful publish: refresh what depends on it (Dify invalidates the published workflow, reloads the
  /// app detail, the app's triggers).
  final VoidCallback? onPublished;
}

/// workflow-app/components/workflow-header/features-trigger.tsx: the Features button (chatflows) and the Publish
/// button with its panel ([AppPublisher]). Publishing refuses while the checklist has items, then runs the checks
/// before publishing, waits for the draft to be saved, publishes, and updates the store (publishedAt,
/// lastPublishedHasUserInput) and the version history. Goes in [WorkflowHeaderData.middle].
class FeaturesTrigger extends StatelessWidget {
  const FeaturesTrigger({
    super.key,
    this.hooks = const WorkflowPublishHooks(),
    this.app,
    this.publishedWorkflow,
    this.capabilities = const PublisherCapabilities(),
    this.onOpenLink,
    this.onOpenRunConfig,
    this.onConfigureWorkflowTool,
    this.onPublishToMarketplace,
    this.onUpdateVersionInfo,
  });

  final WorkflowPublishHooks hooks;

  /// Passed to [AppPublisher].
  final PublisherAppInfo? app;
  final PublishedWorkflowInfo? publishedWorkflow;
  final PublisherCapabilities capabilities;
  final PublisherLinkHandler? onOpenLink;
  final ValueChanged<String>? onOpenRunConfig;
  final Future<void> Function()? onPublishToMarketplace;
  final Future<void> Function(VersionInfoUpdate update)? onUpdateVersionInfo;

  /// Opens the workflow tool configuration with the tool's inputs (the Start node's variables) and outputs (every
  /// End node's outputs with their `source`), as Dify's WorkflowToolDrawer gets them.
  final void Function(List<DifyJson> inputs, List<DifyJson> outputs)? onConfigureWorkflowTool;

  /// The Start node's variables (features-trigger.tsx `variables`, without the image input: dify-sf has no features).
  static List<DifyJson> workflowToolInputsOf(List<HeaderNode> nodes) {
    final start = nodes.where((n) => n.type == 'start').firstOrNull;
    return [...?(start?.data['variables'] as List?)?.whereType<DifyJson>()];
  }

  /// Every End node's outputs, each with `source: {nodeId, nodeTitle, outputIndex}` (features-trigger.tsx
  /// `endVariables`).
  static List<DifyJson> workflowToolOutputsOf(List<HeaderNode> nodes) => [
    for (final n in nodes)
      if (n.type == 'end')
        for (final (i, o) in ((n.data['outputs'] as List?) ?? const []).whereType<DifyJson>().indexed)
          {
            ...o,
            'source': {'nodeId': n.id, 'nodeTitle': n.title, 'outputIndex': i},
          },
  ];

  static bool _isTrigger(String type) => type.startsWith('trigger-');

  /// features-trigger.tsx `onPublish`: throws when publishing is refused or fails (the publisher then stays
  /// unlocked).
  static Future<void> publish({
    required WorkflowStore store,
    required WorkflowHeaderData data,
    required WorkflowPublishHooks hooks,
    String title = '',
    String releaseNotes = '',
    bool showSuccessToast = true,
  }) async {
    final facts = data.facts;
    if (facts.checklist.isNotEmpty) {
      data.toast?.call(HeaderToastType.error, DifyI18n.tr('workflow', 'panel.checklistTip'));
      throw StateError('Checklist has unresolved items');
    }
    if (!(await hooks.checkBeforePublish?.call() ?? true)) throw StateError('Checklist failed');
    if (!(await hooks.syncWorkflowDraft?.call() ?? true)) throw StateError('Workflow draft sync failed');
    final res = await hooks.publishWorkflow?.call(title: title, releaseNotes: releaseNotes);
    if (res == null) return;
    if (showSuccessToast) data.toast?.call(HeaderToastType.success, DifyI18n.tr('common', 'api.actionSuccess'));
    hooks.onPublished?.call();
    store
      ..setPublishedAt((res['created_at'] as num?)?.toInt() ?? 0)
      ..setLastPublishedHasUserInput(facts.hasUserInputNode);
    data.resetWorkflowVersionHistory?.call();
  }

  @override
  Widget build(BuildContext context) {
    final data = WorkflowHeaderScope.of(context);
    final store = WorkflowStoreScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([
        ?data.graph,
        nodesReadOnlyListenable(store),
        store.publishedAt,
        store.draftUpdatedAt,
        store.toolPublished,
        store.lastPublishedHasUserInput,
      ]),
      builder: (context, _) {
        final nodes = data.facts.nodes;
        final readOnly = nodesReadOnlyOf(store, canEdit: data.canEdit);
        final hasNodes = nodes.isNotEmpty;
        final publishedAt = store.publishedAt.value, draftUpdatedAt = store.draftUpdatedAt.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            if (data.isChatMode)
              DifyButton(
                onPressed: () {
                  if (nodesReadOnlyOf(store, canEdit: data.canEdit) && !store.isRestoring.value) return;
                  store.setShowFeaturesPanel(!store.showFeaturesPanel.value);
                },
                leading: const RemixIcon('apps-2-add-line', size: 16, color: DifyColors.componentsButtonSecondaryText),
                child: Text(DifyI18n.tr('workflow', 'common.features')),
              ),
            AppPublisher(
              publishedAt: publishedAt == 0 ? null : publishedAt,
              draftUpdatedAt: draftUpdatedAt == 0 ? null : draftUpdatedAt,
              disabled: readOnly || !hasNodes || !data.canReleaseAndVersion,
              publishDisabled: !hasNodes || !data.canReleaseAndVersion,
              toolPublished: store.toolPublished.value,
              workflowToolAvailable: store.lastPublishedHasUserInput.value,
              crossAxisOffset: 4,
              missingStartNode: !nodes.any((n) => n.type == 'start'),
              hasTriggerNode: nodes.any((n) => _isTrigger(n.type)),
              hasHumanInputNode: nodes.any((n) => n.type == 'human-input'),
              onPublish: () => publish(store: store, data: data, hooks: hooks),
              onToggle: (open) {
                if (open) hooks.syncWorkflowDraft?.call();
              },
              app: app,
              publishedWorkflow: publishedWorkflow,
              capabilities: capabilities,
              onOpenLink: onOpenLink,
              onOpenRunConfig: onOpenRunConfig,
              onConfigureWorkflowTool: onConfigureWorkflowTool == null
                  ? null
                  : () => onConfigureWorkflowTool!(workflowToolInputsOf(nodes), workflowToolOutputsOf(nodes)),
              onPublishToMarketplace: onPublishToMarketplace,
              onUpdateVersionInfo: onUpdateVersionInfo,
              onToast: data.toast == null
                  ? null
                  : (type, m) => data.toast!(
                      type == PublisherToastType.success ? HeaderToastType.success : HeaderToastType.error,
                      m,
                    ),
              formatTimeFromNow: data.formatters.formatTimeFromNow,
            ),
          ],
        );
      },
    );
  }
}
