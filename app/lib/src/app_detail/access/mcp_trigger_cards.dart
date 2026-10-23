/// The built-in MCP server and Trigger access points (Dify 1.17.1 app/access-point/built-in-access-points/mcp-card.tsx
/// and trigger-card.tsx) without their runtimes: dify-sf serves no MCP server (the card stays unavailable) and runs
/// no triggers (the Trigger card's list is empty).
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../design/dify_icon.dart';
import '../../i18n/dify_i18n.dart';
import '../../open_url.dart';
import 'access_point_card.dart';
import 'access_point_utils.dart';

String _t(String ns, String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr(ns, key, params);

/// MCPAccessPointCard: "MCP Server" with its masked URL (`***********`) and "Add description". With no MCP server
/// runtime the card is unavailable (loading while the published workflow loads), its actions disabled.
class MCPAccessPointCard extends StatelessWidget {
  const MCPAccessPointCard({
    super.key,
    required this.canManageAccessPoint,
    required this.workflowLoading,
    required this.triggerModeDisabled,
    this.highlighted = false,
  });

  final bool canManageAccessPoint, workflowLoading, triggerModeDisabled, highlighted;

  AccessPointStatus get status => workflowLoading ? AccessPointStatus.loading : AccessPointStatus.unavailable;

  @override
  Widget build(BuildContext context) {
    final loading = status == AccessPointStatus.loading;
    return AccessPointCard(
      title: _t('tools', 'mcp.server.title'),
      description: _t('deployments', 'studio.accessPoint.mcpDescription'),
      icon: 'vender/integrations/mcp',
      status: status,
      statusLabel: accessPointStatusLabel(status),
      highlighted: highlighted,
      switchDisabled: !canManageAccessPoint,
      switchLabel: _t('tools', 'mcp.server.title'),
      actions: [
        DifyButton(
          key: const ValueKey('mcp-edit'),
          paddingX: 12,
          disabled: true,
          leading: const RemixIcon('draft-line', size: 16),
          child: DifyTextLine(_t('tools', 'mcp.server.addDescription')),
        ),
      ],
      child: AccessPointUrl(
        label: _t('tools', 'mcp.server.url'),
        value: '***********',
        enabled: false,
        copyDisabled: true,
        loading: loading,
        unavailable: !loading,
        unavailableLabel: _t('deployments', 'health.ENVIRONMENT_STATUS_FAILED'),
        showRegenerate: true,
        regenerateLabel: _t('appOverview', 'overview.appInfo.regenerate'),
        regenerateDisabled: true,
      ),
    );
  }
}

/// TriggerAccessPointCard (workflow apps): the published workflow's triggers. dify-sf runs no triggers, so the list
/// is empty: Dify's empty content ("Triggers appear here after you publish." and the docs link), the status shown
/// unless the point is active.
class TriggerAccessPointCard extends StatelessWidget {
  const TriggerAccessPointCard({
    super.key,
    required this.availability,
    required this.canManageAccessPoint,
    this.highlighted = false,
    this.openUrl,
  });

  final AccessPointAvailability availability;
  final bool canManageAccessPoint, highlighted;
  final void Function(String url)? openUrl;

  bool get loading => availability == AccessPointAvailability.loading;
  bool get active => availability == AccessPointAvailability.available && !loading;

  AccessPointStatus get status => loading
      ? AccessPointStatus.loading
      : active
      ? AccessPointStatus.inService
      : AccessPointStatus.unavailable;

  @override
  Widget build(BuildContext context) {
    final docs = difyDocLink('/use-dify/nodes/trigger/overview');
    return AccessPointCard(
      title: _t('common', 'settings.trigger'),
      description: _t('deployments', 'studio.accessPoint.triggerDescription'),
      icon: 'vender/integrations/trigger',
      status: status,
      statusLabel: accessPointStatusLabel(status),
      highlighted: highlighted,
      showStatus: !active,
      child: loading
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 160),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 16,
                  children: [
                    DifySkeletonRectangle(width: 96, radius: 4, margin: EdgeInsets.zero, pulse: true),
                    DifySkeletonRectangle(height: 40, opacity: 0.1, radius: 8, margin: EdgeInsets.zero, pulse: true),
                    DifySkeletonRectangle(height: 40, opacity: 0.1, radius: 8, margin: EdgeInsets.zero, pulse: true),
                  ],
                ),
              ),
            )
          : AccessPointEmptyContent(
              child: DifyTextLine.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '${_t('appOverview', 'overview.triggerInfo.triggerStatusDescription')} '),
                    TextSpan(
                      text: _t('appOverview', 'overview.triggerInfo.learnAboutTriggers'),
                      style: TextStyle(color: DifyColors.textAccent),
                      recognizer: TapGestureRecognizer()
                        ..onTap = () => (openUrl ?? (u) => unawaited(openExternalUrl(u)))(docs),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
