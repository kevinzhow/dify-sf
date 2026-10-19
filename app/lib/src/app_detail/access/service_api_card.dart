/// The built-in Service API access point (Dify 1.17.1 app/access-point/built-in-access-points/service-api-card.tsx,
/// shared/service-api-card-view.tsx, shared/api-secret-key-button.tsx) and the switch mutation the cards share.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import 'access_point_card.dart';
import 'access_point_utils.dart';
import 'api_key_modal.dart';

String _t(String ns, String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr(ns, key, params);

/// A switch's `useMutation` with a `scope`: calls run one after another (a call waits for the previous one), and
/// while the latest is pending its value is the optimistic one ([optimistic]). A failure toasts Dify's
/// "modified unsuccessfully" and the switch falls back to the stored value; success is silent.
class SerialSwitchMutation extends ChangeNotifier {
  SerialSwitchMutation(this._send);

  final Future<void> Function(bool value) _send;
  Future<void> _chain = Future.value();
  int _calls = 0, _latest = 0;
  bool? _pendingValue;
  bool _disposed = false;

  /// The latest call's value while it is pending (`mutation.variables` while `isPending`).
  bool? get pendingValue => _pendingValue;
  bool get isPending => _pendingValue != null;

  /// [stored] unless a change is pending.
  bool optimistic(bool stored) => _pendingValue ?? stored;

  void mutate(bool value) {
    final id = _latest = ++_calls;
    _pendingValue = value;
    notifyListeners();
    _chain = _chain.then((_) async {
      try {
        await _send(value);
      } on Object catch (e) {
        // The request layer's toast (the server's message), then the mutation's onError.
        notifyRequestError(e);
        toast.error(_t('common', 'actionMsg.modifiedUnsuccessfully'));
      }
      if (id == _latest && !_disposed) {
        _pendingValue = null;
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// ApiSecretKeyButton: "API Secret key" with the key count badge (`rounded-[5px] border border-divider-deep
/// bg-components-badge-bg-dimm system-2xs-medium-uppercase`), opening [ApiKeyModal]. Keys are only requested with
/// [canManage]; the button is disabled without it, while [disabled] or while the keys load or failed to load.
class ApiSecretKeyButton extends StatefulWidget {
  const ApiSecretKeyButton({super.key, required this.appId, required this.canManage, this.api, this.disabled = false});

  final String appId;
  final bool canManage, disabled;

  /// The keys' backend; null: no server (no keys, disabled).
  final AccessApi? api;

  @override
  State<ApiSecretKeyButton> createState() => _ApiSecretKeyButtonState();
}

class _ApiSecretKeyButtonState extends State<ApiSecretKeyButton> {
  AppApiKeysQuery? _query;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(ApiSecretKeyButton old) {
    super.didUpdateWidget(old);
    if (old.api != widget.api || old.appId != widget.appId || old.canManage != widget.canManage) {
      _query?.dispose();
      _query = null;
      _bind();
    }
  }

  void _bind() {
    final api = widget.api;
    if (api == null || !widget.canManage) return;
    _query = AppApiKeysQuery(api: api, appId: widget.appId);
    unawaited(_query!.fetch());
  }

  @override
  void dispose() {
    _query?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query;
    Widget button() {
      final count = query?.data?.length ?? 0;
      final off = widget.disabled || !widget.canManage || query == null || query.isPending || query.isError;
      final label = _t('appApi', 'apiKeyModal.apiSecretKey');
      return DifyButton(
        key: const ValueKey('api-secret-key-button'),
        disabled: off,
        paddingX: 12,
        semanticLabel: '$label $count',
        onPressed: query == null
            ? null
            : () => unawaited(showApiKeyModal(context, query: query, canManage: widget.canManage)),
        leading: const RemixIcon('key-2-line', size: 16),
        trailing: Container(
          constraints: const BoxConstraints(minWidth: 16),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            color: DifyColors.componentsBadgeBgDimm,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: DifyColors.dividerDeep),
          ),
          child: Text(
            '$count',
            textAlign: TextAlign.center,
            style: difyTextStyle(
              DifyType.system2xsMediumUppercase,
              off ? DifyColors.textDisabled : DifyColors.textTertiary,
            ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
        child: Text(label),
      );
    }

    return query == null ? button() : ListenableBuilder(listenable: query, builder: (context, _) => button());
  }
}

/// ServiceApiCardView: the Service API card (`knowledge/api-aggregate` icon): the API's base URL, "API Secret key"
/// and the "API Reference" link (docs.dify.ai's reference for the app's mode; a disabled button while unavailable).
class ServiceApiCardView extends StatelessWidget {
  const ServiceApiCardView({
    super.key,
    required this.apiKeyButton,
    required this.apiUrl,
    required this.appMode,
    required this.available,
    required this.status,
    required this.switchDisabled,
    this.highlighted = false,
    this.onEnabledChange,
    this.switchLoading = false,
    this.onOpen,
  });

  final Widget apiKeyButton;
  final String apiUrl;
  final String? appMode;
  final bool available, switchDisabled, highlighted, switchLoading;
  final AccessPointStatus status;
  final ValueChanged<bool>? onEnabledChange;
  final void Function(String url)? onOpen;

  /// The API Reference URL for [appMode] (`useDocLink()(getAppApiReferencePath(mode))`).
  String? get apiReferenceUrl {
    final path = appMode == null ? null : appApiReferencePath(appMode!);
    return path == null ? null : difyDocLink(path);
  }

  @override
  Widget build(BuildContext context) {
    final docLabel = _t('appOverview', 'overview.apiInfo.doc');
    final url = apiReferenceUrl;
    return AccessPointCard(
      title: _t('agent-v-2', 'agentDetail.access.serviceApi.title'),
      description: _t('deployments', 'studio.accessPoint.apiDescription'),
      icon: 'vender/knowledge/api-aggregate',
      status: status,
      statusLabel: accessPointStatusLabel(status),
      highlighted: highlighted,
      switchDisabled: switchDisabled,
      switchLabel: _t('appOverview', 'overview.apiInfo.title'),
      onEnabledChange: onEnabledChange,
      switchLoading: switchLoading,
      actions: [
        apiKeyButton,
        if (available && url != null)
          ExternalLinkButton(
            key: const ValueKey('api-reference'),
            url: url,
            onOpen: onOpen,
            leading: const RemixIcon('book-open-line', size: 16),
            trailing: const RemixIcon('arrow-right-up-line', size: 14),
            child: Text(docLabel),
          )
        else
          DifyButton(
            key: const ValueKey('api-reference'),
            disabled: true,
            leading: const RemixIcon('book-open-line', size: 16),
            trailing: const RemixIcon('arrow-right-up-line', size: 14),
            child: Text(docLabel),
          ),
      ],
      child: AccessPointUrl(
        label: _t('appOverview', 'overview.apiInfo.accessibleAddress'),
        value: apiUrl,
        enabled: status == AccessPointStatus.inService,
        loading: status == AccessPointStatus.loading,
        unavailable: status == AccessPointStatus.unavailable,
        unavailableLabel: _t('deployments', 'health.ENVIRONMENT_STATUS_FAILED'),
      ),
    );
  }
}

/// ServiceApiAccessPointCard: the switch is `POST /apps/{id}/api-enable` (optimistic and serialised; only with
/// [canManage]); a stored change updates the app ([onAppChanged]).
class ServiceApiAccessPointCard extends StatefulWidget {
  const ServiceApiAccessPointCard({
    super.key,
    required this.app,
    required this.availability,
    required this.canManage,
    this.api,
    this.highlighted = false,
    this.onAppChanged,
    this.onOpen,
  });

  final AppInfo app;
  final AccessPointAvailability availability;
  final bool canManage, highlighted;
  final AccessApi? api;
  final ValueChanged<AppInfo>? onAppChanged;
  final void Function(String url)? onOpen;

  @override
  State<ServiceApiAccessPointCard> createState() => _ServiceApiAccessPointCardState();
}

class _ServiceApiAccessPointCardState extends State<ServiceApiAccessPointCard> {
  late final _toggle = SerialSwitchMutation(_send);

  Future<void> _send(bool enable) async {
    final api = widget.api;
    if (api == null) throw StateError('No server');
    final updated = await api.setApiEnabled(widget.app.id, enable);
    if (!mounted) return;
    widget.onAppChanged?.call(
      AppInfo.fromJson({
        ...widget.app.json,
        'enable_api': updated.enableApi,
        if (updated.updatedAt != 0) 'updated_at': updated.updatedAt,
      }),
    );
  }

  @override
  void dispose() {
    _toggle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _toggle,
    builder: (context, _) {
      final available = widget.availability == AccessPointAvailability.available;
      final running = available && _toggle.optimistic(widget.app.enableApi);
      return ServiceApiCardView(
        apiKeyButton: ApiSecretKeyButton(
          appId: widget.app.id,
          api: widget.api,
          canManage: widget.canManage,
          disabled: !available,
        ),
        apiUrl: builtInAccessUrls(widget.app).api,
        appMode: widget.app.mode,
        available: available,
        status: accessPointStatusOf(widget.availability, running),
        highlighted: widget.highlighted,
        switchDisabled: !widget.canManage,
        onEnabledChange: available
            ? (enabled) {
                if (widget.canManage) _toggle.mutate(enabled);
              }
            : null,
        onOpen: widget.onOpen,
      );
    },
  );
}
