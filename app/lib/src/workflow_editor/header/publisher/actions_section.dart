import 'package:flutter/widgets.dart';

import '../../../design/css_metrics.dart';
import '../../../design/dify_icon.dart';
import '../../../design/dify_tokens.g.dart';
import '../../../design/widgets/widgets.dart';
import '../../../i18n/dify_i18n.dart';
import 'suggested_action.dart';
import 'workflow_tool_action.dart';

String _w(String key) => DifyI18n.tr('workflow', key);

/// built-in-publisher/actions-section.tsx: the quick actions under the publish summary: Open web app (with the run
/// config button when the start node has hidden inputs), Access Point, Deploy, Publish to Marketplace and, for
/// workflow apps without trigger or human-input nodes, Workflow as Tool.
class PublisherActionsSection extends StatelessWidget {
  const PublisherActionsSection({
    super.key,
    this.appId,
    this.appMode,
    required this.appUrl,
    required this.canViewAccessPoint,
    required this.disabledFunctionButton,
    this.disabledFunctionTooltip,
    this.onOpenRunConfig,
    this.hasHumanInputNode = false,
    this.hasTriggerNode = false,
    this.marketplaceActionDisabled = false,
    this.publishedAt,
    this.publishingToMarketplace = false,
    this.showDeployAction = false,
    this.showMarketplaceAction = false,
    this.showRunConfig = false,
    this.toolPublished = false,
    this.workflowToolAvailable = true,
    required this.workflowToolIsLoading,
    this.workflowToolMessage,
    this.workflowToolOutdated = false,
    required this.onConfigureWorkflowTool,
    this.onPublishToMarketplace,
    this.onOpenLink,
  });

  final String? appId;
  final String? appMode;
  final String appUrl;
  final bool canViewAccessPoint;
  final bool disabledFunctionButton;
  final String? disabledFunctionTooltip;

  /// `handleOpenRunConfig(appURL)`.
  final ValueChanged<String>? onOpenRunConfig;
  final bool hasHumanInputNode;
  final bool hasTriggerNode;
  final bool marketplaceActionDisabled;
  final int? publishedAt;
  final bool publishingToMarketplace;
  final bool showDeployAction;
  final bool showMarketplaceAction;
  final bool showRunConfig;
  final bool toolPublished;
  final bool workflowToolAvailable;
  final bool workflowToolIsLoading;
  final String? workflowToolMessage;
  final bool workflowToolOutdated;
  final VoidCallback onConfigureWorkflowTool;
  final VoidCallback? onPublishToMarketplace;
  final PublisherLinkHandler? onOpenLink;

  @override
  Widget build(BuildContext context) {
    final hasPublishedVersion = publishedAt != null && publishedAt != 0;
    final showDeploy = showDeployAction && appId != null;
    final showWorkflowTool = appMode == 'workflow' && !hasHumanInputNode && !hasTriggerNode;
    final navigationDisabled = !hasPublishedVersion || appId == null;
    final workflowToolDisabled =
        !hasPublishedVersion || !workflowToolAvailable || (toolPublished && workflowToolIsLoading);
    final tooltip = disabledFunctionTooltip;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: DifyColors.dividerRegular, width: Css.hairline),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!hasTriggerNode)
            DifyTooltip(
              disabled: tooltip == null,
              content: DifyTextLine(tooltip ?? ''),
              child: SuggestedAction(
                label: _w('common.openWebApp'),
                disabled: disabledFunctionButton,
                description: disabledFunctionButton && tooltip != null ? tooltip : _w('common.openWebAppDescription'),
                external: true,
                focusableWhenDisabled: tooltip != null,
                link: appUrl,
                icon: const RemixIcon('planet-line'),
                onOpenLink: onOpenLink,
                actionButton: showRunConfig && onOpenRunConfig != null
                    ? SuggestedActionButton(
                        label: DifyI18n.tr('common', 'operation.config'),
                        icon: const RemixIcon('settings-2-line'),
                        onPressed: () => onOpenRunConfig!(appUrl),
                      )
                    : null,
              ),
            ),
          if (canViewAccessPoint)
            SuggestedAction(
              label: DifyI18n.tr('common', 'appMenus.accessPoint'),
              disabled: navigationDisabled,
              description: _w('common.accessPointDescription'),
              link: appId == null ? null : '/app/$appId/access-point',
              icon: const DifyIcon('vender/agent-v2/access-point'),
              onOpenLink: onOpenLink,
            ),
          if (showDeploy)
            SuggestedAction(
              label: DifyI18n.tr('common', 'appMenus.deploy'),
              disabled: navigationDisabled,
              description: _w('common.deployDescription'),
              link: '/app/$appId/deploy',
              icon: const RemixIcon('instance-line'),
              onOpenLink: onOpenLink,
            ),
          if (showMarketplaceAction)
            SuggestedAction(
              label: publishingToMarketplace ? _w('common.publishingToMarketplace') : _w('common.publishToMarketplace'),
              disabled: marketplaceActionDisabled || publishingToMarketplace || onPublishToMarketplace == null,
              description: _w('common.publishToMarketplaceDescription'),
              icon: const RemixIcon('store-2-line'),
              onPressed: onPublishToMarketplace,
            ),
          if (showWorkflowTool) ...[
            Container(margin: const EdgeInsets.all(4), height: 1, color: DifyColors.dividerSubtle),
            WorkflowToolAction(
              disabled: workflowToolDisabled,
              isLoading: workflowToolIsLoading,
              message: workflowToolMessage,
              outdated: workflowToolOutdated,
              published: toolPublished,
              onConfigure: onConfigureWorkflowTool,
              onOpenLink: onOpenLink,
            ),
          ],
        ],
      ),
    );
  }
}
