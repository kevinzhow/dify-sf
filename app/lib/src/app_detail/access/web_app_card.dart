/// The built-in Web App access point (Dify 1.17.1 app/access-point/built-in-access-points/web-app-card.tsx): the site
/// switch, the URL (copy, QR code, regenerate, open) and Configure / Embed / Customize / Settings. Web app access
/// control is enterprise-only (`webapp_auth`), so the access mode entry never shows.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../open_url.dart';
import '../../settings/settings_kit.dart' show showSettingsAlert;
import 'access_point_card.dart';
import 'access_point_utils.dart';
import 'customize_modal.dart';
import 'embedded_modal.dart';
import 'service_api_card.dart' show SerialSwitchMutation;
import 'site_settings_modal.dart';
import 'workflow_launch_dialog.dart';

String _t(String ns, String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr(ns, key, params);

/// WebAppAccessPointCard.
class WebAppAccessPointCard extends StatefulWidget {
  const WebAppAccessPointCard({
    super.key,
    required this.app,
    required this.availability,
    required this.canManageAccessPoint,
    required this.workflow,
    this.appListenable,
    this.api,
    this.canDeploy = false,
    this.canManageAccess = false,
    this.showAccessControl = false,
    this.highlighted = false,
    this.onRefreshApp,
    this.onSaveSiteConfig,
    this.onAppChanged,
    this.openUrl,
  });

  final AppInfo app;

  /// The app as it changes (the settings dialog follows it while open); [app] when null.
  final ValueListenable<AppInfo>? appListenable;
  final AccessPointAvailability availability;
  final bool canDeploy, canManageAccess, canManageAccessPoint, showAccessControl, highlighted;
  final PublishedWorkflow workflow;
  final AccessApi? api;

  /// Refetches the app (after a new access token).
  final Future<void> Function()? onRefreshApp;

  /// `useAccessPointActions().saveSiteConfig`.
  final Future<void> Function(SiteConfigParams params)? onSaveSiteConfig;

  /// The site switch stored a change (Dify's `setAppDetail`).
  final ValueChanged<AppInfo>? onAppChanged;

  /// `window.open(url, '_blank')`; the app's external opener by default.
  final void Function(String url)? openUrl;

  @override
  State<WebAppAccessPointCard> createState() => _WebAppAccessPointCardState();
}

class _WebAppAccessPointCardState extends State<WebAppAccessPointCard> {
  late final _toggle = SerialSwitchMutation(_send);
  bool _regenerating = false;

  AppInfo get _app => widget.app;

  Future<void> _send(bool enable) async {
    final api = widget.api;
    if (api == null) throw StateError('No server');
    final updated = await api.setSiteEnabled(_app.id, enable);
    if (!mounted) return;
    widget.onAppChanged?.call(
      AppInfo.fromJson({
        ..._app.json,
        'enable_site': updated.enableSite,
        if (updated.updatedAt != 0) 'updated_at': updated.updatedAt,
      }),
    );
  }

  @override
  void dispose() {
    _toggle.dispose();
    super.dispose();
  }

  void _open(String url) => (widget.openUrl ?? (u) => unawaited(openExternalUrl(u)))(url);

  Future<void> _confirmRegenerate() => showSettingsAlert(
    context,
    title: _t('appOverview', 'overview.appInfo.regenerate'),
    description: _t('appOverview', 'overview.appInfo.regenerateNotice'),
    onConfirm: () async {
      if (!widget.canManageAccessPoint || _regenerating) return;
      final api = widget.api;
      setState(() => _regenerating = true);
      try {
        if (api == null) throw StateError('No server');
        await api.resetAccessToken(_app.id);
        await widget.onRefreshApp?.call();
      } on Object catch (e) {
        notifyRequestError(e);
        toast.error(_t('common', 'actionMsg.generatedUnsuccessfully'));
      } finally {
        if (mounted) setState(() => _regenerating = false);
      }
    },
  );

  bool get _supportsEmbedded => _app.mode != 'completion' && _app.mode != AppModes.workflow;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _toggle,
    builder: (context, _) {
      final available = widget.availability == AccessPointAvailability.available;
      final optimistic = _toggle.optimistic(_app.enableSite);
      final running = available && optimistic;
      final actionsAvailable = running && !_toggle.isPending;
      final manage = widget.canManageAccessPoint;
      final hidden = hiddenStartInputs(widget.workflow);
      final webAppUrl = builtInAccessUrls(_app).webApp;
      final status = accessPointStatusOf(widget.availability, running);
      final site = _app.site;
      return AccessPointCard(
        title: _t('agent-v-2', 'agentDetail.access.webApp.title'),
        description: _t('deployments', 'studio.accessPoint.webAppDescription'),
        icon: DifyAppIcon(
          size: DifyAppIconSize.large,
          iconType: _app.iconType,
          icon: _app.icon,
          background: _app.iconBackground,
          imageUrl: _app.iconUrl,
        ),
        status: status,
        statusLabel: accessPointStatusLabel(status),
        highlighted: widget.highlighted,
        switchDisabled: !manage,
        switchLabel: _t('appOverview', 'overview.appInfo.title'),
        onEnabledChange: available
            ? (enabled) {
                if (manage) _toggle.mutate(enabled);
              }
            : null,
        actions: [
          if (hidden.isNotEmpty)
            DifyButton(
              key: const ValueKey('web-app-config'),
              paddingX: 12,
              disabled: !actionsAvailable || !manage,
              leading: const RemixIcon('settings-2-line', size: 16),
              onPressed: () => unawaited(
                showWorkflowLaunchDialog(context, hiddenVariables: hidden, targetUrl: webAppUrl, openUrl: _open),
              ),
              child: Text(_t('common', 'operation.config')),
            ),
          if (_supportsEmbedded)
            DifyButton(
              key: const ValueKey('web-app-embed'),
              paddingX: 12,
              disabled: !actionsAvailable || !manage,
              leading: const RemixIcon('window-line', size: 16),
              onPressed: () => unawaited(
                showEmbeddedModal(
                  context,
                  appBaseUrl: site?.appBaseUrl ?? '',
                  accessToken: site?.accessToken ?? '',
                  chatColorTheme: site?.chatColorTheme,
                  hiddenInputs: hidden,
                ),
              ),
              child: Text(_t('deployments', 'studio.accessPoint.embedIntoSite')),
            ),
          DifyButton(
            key: const ValueKey('web-app-customize'),
            paddingX: 12,
            disabled: !actionsAvailable || !manage,
            leading: const DifyIcon('vender/deploy/code-block', size: 16),
            onPressed: () => unawaited(
              showCustomizeModal(context, appId: _app.id, apiBaseUrl: _app.apiBaseUrl, mode: _app.mode),
            ),
            child: Text(_t('appOverview', 'overview.appInfo.customize.entry')),
          ),
          DifyButton(
            key: const ValueKey('web-app-settings'),
            paddingX: 12,
            disabled: !available || !manage,
            leading: const RemixIcon('equalizer-2-line', size: 16),
            onPressed: () => unawaited(
              showSiteSettingsModal(
                context,
                app: widget.appListenable ?? _Fixed(_app),
                isChat: _app.mode != 'completion' && _app.mode != AppModes.workflow,
                canDeploy: widget.canDeploy,
                onSave: (params) async => widget.onSaveSiteConfig?.call(params),
              ),
            ),
            child: Text(_t('common', 'settings.settings')),
          ),
        ],
        child: AccessPointUrl(
          label: _t('agent-v-2', 'agentDetail.access.webApp.accessUrl'),
          value: webAppUrl,
          enabled: running,
          loading: widget.availability == AccessPointAvailability.loading,
          unavailable: widget.availability == AccessPointAvailability.unavailable,
          unavailableLabel: _t('deployments', 'health.ENVIRONMENT_STATUS_FAILED'),
          showOpen: true,
          showQrCode: true,
          showRegenerate: true,
          openLabel: _t('deployments', 'studio.accessPoint.open'),
          openUrl: _app.enableSite && !_toggle.isPending ? webAppUrl : null,
          regenerateLabel: _t('appOverview', 'overview.appInfo.regenerate'),
          regenerateDisabled: !manage,
          regenerating: _regenerating,
          onRegenerate: () => unawaited(_confirmRegenerate()),
          onOpen: _open,
        ),
      );
    },
  );
}

/// A [ValueListenable] that never changes.
class _Fixed implements ValueListenable<AppInfo> {
  _Fixed(this.value);
  @override
  final AppInfo value;
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}
