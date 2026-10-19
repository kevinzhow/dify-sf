/// provider-added-card: a provider's card on the model provider page (index.tsx, list layout), its credential panel
/// (credential-panel.tsx, system-quota-card.tsx, use-credential-panel-state.ts), the credential dropdown
/// (model-auth-dropdown/: index, dropdown-content, api-key-section, button-config, use-activate-credential), the
/// custom model actions (lazy-custom-model-actions.tsx) and provider-icon. The credits, quota and priority parts are
/// Dify Cloud's (never shown outside it); plugin actions (update / remove) need plugins.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../cards/model_chip.dart' show ModelBadge;
import '../../cards/provider_icon_image.dart';
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/model_catalog.dart';
import '../../workflow/workspace_models.dart' show Json;
import '../../workflow_editor/node_panel/bodies/llm/model_selector.dart' show StatusDot, StatusDotKind;
import 'model_auth.dart';
import 'model_list.dart';
import 'model_provider_env.dart';
import 'provider_data.dart';

String _t(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

// ---- ProviderIcon --------------------------------------------------------------------------------------------------

/// provider-icon/index.tsx: Anthropic's wordmark (`h-2.5 w-22.5`, `py-1.75`), OpenAI's (`h-6`,
/// `text-text-inverted-dimmed`), else the provider's `icon_small` (24 px; the Group tile without one) and its label
/// (`system-md-semibold text-text-primary`).
class ProviderIcon extends StatelessWidget {
  const ProviderIcon({super.key, required this.provider, this.language = 'en_US'});

  final Json provider;
  final String language;

  @override
  Widget build(BuildContext context) {
    final name = provider.providerName;
    if (name == 'langgenius/anthropic/anthropic') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: SvgPicture.asset('assets/dify_icons/public/llm/Anthropic-dark.svg', width: 90, height: 10),
      );
    }
    if (name == 'langgenius/openai/openai') {
      return SvgPicture.asset(
        'assets/dify_icons/vender/other/openai.svg',
        height: 24,
        theme: SvgTheme(currentColor: DifyColors.textInvertedDimmed),
        colorFilter: ColorFilter.mode(DifyColors.textInvertedDimmed, BlendMode.srcIn),
      );
    }
    // provider-icon/index.tsx: `icon_small_dark` in the dark theme when the provider has one.
    final dark = DifyColors.isDark && provider.iconSmallDark != null
        ? renderI18nObject(provider.iconSmallDark, language)
        : '';
    final url = dark.isNotEmpty
        ? dark
        : provider.iconSmall == null
        ? ''
        : renderI18nObject(provider.iconSmall, language);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (url.isNotEmpty)
          ProviderIconImage(url, width: 24, height: 24)
        else
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: DifyColors.backgroundDefaultSubtle,
              borderRadius: BorderRadius.circular(DifyRadius.md),
              border: Border.all(color: DifyColors.componentsPanelBorderSubtle, width: Css.hairline),
            ),
            child: DifyIcon('vender/other/group', size: 16, color: DifyColors.textTertiary),
          ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            renderI18nObject(provider.label, language),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: difyTextStyle(DifyType.systemMdSemibold, DifyColors.textPrimary),
          ),
        ),
      ],
    );
  }
}

// ---- ProviderAddedCard ---------------------------------------------------------------------------------------------

/// provider-added-card/index.tsx (list layout): `rounded-xl border-[0.5px] border-divider-regular
/// bg-third-party-model-bg-default shadow-xs` (OpenAI's and Anthropic's own backgrounds): the provider icon and its
/// model types (`py-2 pr-2 pl-3`) with the credential panel at the right; below, either the collapsed bar ("Show
/// Models" / "N Models", the configure tip of unconfigured providers, the custom model actions) or the model list.
/// Members without `plugin.plugin_preferences` see neither the models nor the credentials.
class ProviderAddedCard extends StatefulWidget {
  const ProviderAddedCard({super.key, required this.provider, this.notConfigured = false});

  /// The summary entry (or the details) of the provider.
  final Json provider;
  final bool notConfigured;

  @override
  State<ProviderAddedCard> createState() => _ProviderAddedCardState();
}

class _ProviderAddedCardState extends State<ProviderAddedCard> {
  ModelProviderEnv? _env;
  bool _wasExpanded = false;

  String get _name => widget.provider.providerName;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final env = ModelProviderScope.of(context);
    if (_env?.models != env.models) {
      _env?.models.removeListener(_changed);
      env.models.addListener(_changed);
    }
    _env = env;
    _wasExpanded = env.models.isExpanded(_name);
    // A list that is expanded when the card appears is fetched (the query mounts enabled).
    if (_wasExpanded && env.canSetPluginPreferences) unawaited(env.models.fetchProviderModels(_name));
  }

  @override
  void dispose() {
    _env?.models.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final env = _env;
    if (env == null || !mounted) return;
    final expanded = env.models.isExpanded(_name);
    final opened = expanded && !_wasExpanded;
    _wasExpanded = expanded;
    // The query becomes enabled when the list expands (here or elsewhere: the atoms are shared).
    if (opened && env.canSetPluginPreferences) unawaited(env.models.fetchProviderModels(_name));
    setState(() {});
  }

  /// `handleOpenModelList`: expands the list, or refetches it when expanded; nothing while it loads.
  void _openModelList(ModelProviderEnv env) {
    if (env.models.isProviderModelsFetching(_name)) return;
    if (!env.models.isExpanded(_name)) {
      env.models.setExpanded(_name, true);
      return;
    }
    unawaited(env.models.fetchProviderModels(_name));
  }

  /// `refreshModelList`: the model list's onChange.
  void _refreshModelList(ModelProviderEnv env, String provider) {
    if (provider != _name) return;
    if (!env.models.isExpanded(_name)) env.models.setExpanded(_name, true);
    unawaited(env.models.fetchProviderModels(_name));
  }

  @override
  Widget build(BuildContext context) {
    final env = ModelProviderScope.of(context);
    final p = widget.provider;
    final models = env.models;
    final expanded = models.isExpanded(_name);
    final methods = p.configurateMethods;
    final supportsPredefined = methods.contains(ConfigurationMethodEnum.predefinedModel);
    final supportsCustomizable = methods.contains(ConfigurationMethodEnum.customizableModel);
    final modelList = models.providerModels(_name);
    final loading = models.isProviderModelsFetching(_name);
    final hasFetched = modelList != null;
    final hasModelList = hasFetched && modelList.isNotEmpty;
    final showCollapsed = !env.canSetPluginPreferences || !expanded || !hasFetched;
    // Hosted quota providers on Dify Cloud only.
    const showModelProvider = false;
    final canAccessCredentials = env.rbacEnabled
        ? env.canUseCredential || env.canCreateCredential || env.canManageCredential
        : env.canManageCredential;
    final showCredential = supportsPredefined && canAccessCredentials;
    final showCustomModelActions = supportsCustomizable && env.canConfigureModels;
    final background = switch (_name) {
      'langgenius/openai/openai' => DifyColors.thirdPartyModelBgOpenai,
      'langgenius/anthropic/anthropic' => DifyColors.thirdPartyModelBgAnthropic,
      _ => DifyColors.thirdPartyModelBgDefault,
    };
    final showModelsLabel = hasModelList
        ? _t('modelProvider.modelsNum', {'num': modelList.length})
        : _t('modelProvider.showModels');

    return Container(
      key: const ValueKey('provider-added-card'),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        border: Border.all(color: DifyColors.dividerRegular, width: Css.hairline),
        boxShadow: DifyShadows.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: ProviderIcon(provider: p, language: env.language),
                        ),
                        Wrap(
                          spacing: 2,
                          runSpacing: 2,
                          children: [for (final t in p.supportedModelTypes) ModelBadge.text(modelTypeFormat(t))],
                        ),
                      ],
                    ),
                  ),
                ),
                if (showCredential) CredentialPanel(provider: p),
              ],
            ),
          ),
          if (showCollapsed)
            Container(
              padding: const EdgeInsets.fromLTRB(8, 6, 11, 6),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
              ),
              child: Row(
                children: [
                  if (env.canSetPluginPreferences && (showModelProvider || !widget.notConfigured))
                    DifyPressable(
                      key: const ValueKey('provider-show-models'),
                      semanticLabel: _t('modelProvider.showModels'),
                      onPressed: () => _openModelList(env),
                      builder: (context, hovered, focused) => Container(
                        height: 24,
                        padding: const EdgeInsets.only(left: 4, right: 6),
                        decoration: BoxDecoration(
                          color: hovered ? DifyColors.componentsButtonGhostBgHover : null,
                          borderRadius: BorderRadius.circular(DifyRadius.lg),
                          border: focused ? Border.all(color: DifyColors.stateAccentSolid, width: 2) : null,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              showModelsLabel,
                              style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textTertiary),
                            ),
                            if (!loading) RemixIcon('arrow-right-s-line', size: 16, color: DifyColors.textTertiary),
                            if (loading)
                              Padding(
                                padding: EdgeInsets.only(left: 2),
                                child: DifySpinner(size: 12, color: DifyColors.textTertiary),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (!showModelProvider && widget.notConfigured)
                    Container(
                      height: 24,
                      padding: const EdgeInsets.only(left: 4, right: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: RemixIcon('information-2-fill', size: 16, color: DifyColors.textAccent),
                          ),
                          Text(
                            _t('modelProvider.configureTip'),
                            style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  if (showCustomModelActions)
                    Expanded(
                      child: Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: LazyCustomModelActions(provider: p),
                      ),
                    )
                  else
                    const Spacer(),
                ],
              ),
            ),
          if (!showCollapsed)
            ModelList(
              provider: p,
              models: modelList,
              onCollapse: () => models.setExpanded(_name, false),
              onChange: (provider) => _refreshModelList(env, provider),
            ),
        ],
      ),
    );
  }
}

// ---- CredentialPanel -----------------------------------------------------------------------------------------------

/// TEXT_LABEL_KEYS.
const _textLabelKeys = {
  CardVariant.creditsActive: 'modelProvider.card.aiCreditsInUse',
  CardVariant.creditsFallback: 'modelProvider.card.aiCreditsInUse',
  CardVariant.creditsExhausted: 'modelProvider.card.quotaExhausted',
  CardVariant.noUsage: 'modelProvider.card.noAvailableUsage',
  CardVariant.apiRequiredAdd: 'modelProvider.card.apiKeyRequired',
  CardVariant.apiRequiredConfigure: 'modelProvider.card.apiKeyRequired',
};

/// credential-panel.tsx: the [SystemQuotaCard] with the state's label (a text for the "required" / credit states,
/// else the current credential's status dot and name) over the credential dropdown.
class CredentialPanel extends StatelessWidget {
  const CredentialPanel({super.key, required this.provider});

  final Json provider;

  @override
  Widget build(BuildContext context) {
    final env = ModelProviderScope.of(context);
    final state = CredentialPanelState.of(
      ModelProvider.fromJson(provider),
      deploymentEdition: env.deploymentEdition,
      trialCredits: const TrialCredits(),
    );
    final variant = state.variant;
    final destructive = isDestructiveVariant(variant);
    final isTextLabel = _textLabelKeys.containsKey(variant);
    final labelColor = destructive ? DifyColors.textDestructive : DifyColors.textSecondary;
    return SystemQuotaCard(
      destructive: destructive,
      label: isTextLabel
          ? Row(
              children: [
                Flexible(
                  child: Text(
                    _t(_textLabelKeys[variant]!),
                    key: const ValueKey('credential-panel-label'),
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: difyTextStyle(DifyType.systemXsMedium, labelColor),
                  ),
                ),
                if (variant == CardVariant.creditsFallback)
                  Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: DifyIcon('vender/line/alertsAndFeedback/warning', size: 12, color: DifyColors.textWarning),
                  ),
              ],
            )
          : Row(
              children: [
                StatusDot(status: destructive ? StatusDotKind.error : StatusDotKind.success),
                const SizedBox(width: 4),
                Flexible(
                  child: DifyTooltip(
                    content: Text(state.credentialName ?? ''),
                    child: Text(
                      state.credentialName ?? '',
                      key: const ValueKey('credential-panel-label'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: difyTextStyle(DifyType.systemXsMedium, labelColor),
                    ),
                  ),
                ),
                if (variant == CardVariant.apiFallback) ...[
                  const Spacer(),
                  DifyIcon('vender/line/alertsAndFeedback/warning', size: 12, color: DifyColors.textWarning),
                ],
              ],
            ),
      actions: ModelAuthDropdown(provider: provider, state: state),
    );
  }
}

/// system-quota-card.tsx: `relative ml-1 flex w-32 flex-col justify-between rounded-lg border-[0.5px] p-1 shadow-xs`
/// (`border-components-panel-border bg-white/18`, destructive `border-state-destructive-border
/// bg-state-destructive-hover`) over the faint grid; the label (`px-1.5 pt-1 system-xs-medium`) and the actions.
class SystemQuotaCard extends StatelessWidget {
  const SystemQuotaCard({super.key, required this.label, required this.actions, this.destructive = false});

  final Widget label, actions;
  final bool destructive;

  @override
  Widget build(BuildContext context) => Container(
    width: 128,
    margin: const EdgeInsets.only(left: 4),
    decoration: BoxDecoration(
      color: destructive ? DifyColors.stateDestructiveHover : const Color(0x2EFFFFFF),
      borderRadius: BorderRadius.circular(DifyRadius.lg),
      border: Border.all(
        color: destructive ? DifyColors.stateDestructiveBorder : DifyColors.componentsPanelBorder,
        width: Css.hairline,
      ),
      boxShadow: DifyShadows.xs,
    ),
    child: CustomPaint(
      painter: const _GridPainter(),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
              child: SizedBox(
                height: 18,
                child: Align(alignment: AlignmentDirectional.centerStart, child: label),
              ),
            ),
            const SizedBox(height: 4),
            actions,
          ],
        ),
      ),
    ),
  );
}

/// quota-panel.module.css `gridBg`: 0.5 px `divider-subtle` lines every 4 px, faded out from the centre.
class _GridPainter extends CustomPainter {
  const _GridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.saveLayer(rect, Paint());
    final line = Paint()
      ..color = DifyColors.dividerSubtle
      ..strokeWidth = Css.hairline;
    for (var x = 0.25; x < size.width; x += 4) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (var y = 0.25; y < size.height; y += 4) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
    final mask = Paint()
      ..blendMode = BlendMode.dstIn
      ..shader = const RadialGradient(
        colors: [Color(0x99000000), Color(0x00000000)],
        stops: [0, 0.7],
      ).createShader(rect);
    canvas.drawRect(rect, mask);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GridPainter oldDelegate) => false;
}

// ---- ModelAuthDropdown ---------------------------------------------------------------------------------------------

/// button-config.ts `getButtonConfig`: "Add API Key" (primary) to add the first key, "Config" (primary) when one
/// must be chosen, else a secondary "Config" / "Add API Key".
({String text, DifyButtonVariant variant}) getButtonConfig(CardVariant variant, bool hasCredentials) {
  if (variant == CardVariant.apiRequiredAdd) {
    return (text: _t('modelProvider.auth.addApiKey'), variant: DifyButtonVariant.primary);
  }
  if (variant == CardVariant.apiRequiredConfigure) {
    return (text: _t('operation.config'), variant: DifyButtonVariant.primary);
  }
  return (
    text: hasCredentials ? _t('operation.config') : _t('modelProvider.auth.addApiKey'),
    variant: DifyButtonVariant.secondary,
  );
}

/// model-auth-dropdown/index.tsx: the card's small button (`i-ri-equalizer-2-line` and the config text) opening the
/// credential popover (`bottom-end`); a summary provider's details load first (a spinner, or "Action failed" and
/// Retry).
class ModelAuthDropdown extends StatefulWidget {
  const ModelAuthDropdown({super.key, required this.provider, required this.state});

  final Json provider;
  final CredentialPanelState state;

  @override
  State<ModelAuthDropdown> createState() => _ModelAuthDropdownState();
}

class _ModelAuthDropdownState extends State<ModelAuthDropdown> {
  bool _open = false;
  bool _detailError = false;
  bool _loadingDetail = false;

  bool get _isFull => !widget.provider.isSummary;

  void _close() {
    setState(() {
      _open = false;
      _detailError = false;
    });
  }

  Future<void> _loadDetail(ModelProviderEnv env) async {
    setState(() {
      _detailError = false;
      _loadingDetail = true;
    });
    final detail = await env.models.loadProviderDetail(widget.provider.providerName);
    if (!mounted) return;
    setState(() {
      _loadingDetail = false;
      if (detail == null) _detailError = true;
    });
  }

  void _openChange(ModelProviderEnv env, bool open) {
    if (!open) return _close();
    setState(() => _open = true);
    final loaded = env.models.detailOf(widget.provider.providerName) != null;
    if (!_isFull && !(loaded && !_loadingDetail)) unawaited(_loadDetail(env));
  }

  @override
  Widget build(BuildContext context) {
    final env = ModelProviderScope.of(context);
    final config = getButtonConfig(widget.state.variant, widget.state.hasCredentials);
    return DifyFloating(
      open: _open,
      onOpenChange: (open) => _openChange(env, open),
      placement: DifyPlacement.bottomEnd,
      sideOffset: 8,
      builder: (context, controller) => DifyTooltip(
        content: Text(config.text),
        child: DifyButton(
          key: const ValueKey('model-auth-dropdown-trigger'),
          size: DifyButtonSize.small,
          variant: config.variant,
          loading: _loadingDetail,
          semanticLabel: config.text,
          paddingX: 8,
          onPressed: controller.toggle,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const RemixIcon('equalizer-2-line', size: 14),
              const SizedBox(width: 4),
              Flexible(child: Text(config.text, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
          ),
        ),
      ),
      popupBuilder: (context) => ModelProviderScope(
        env: env,
        child: ListenableBuilder(
          listenable: env.models,
          builder: (context, _) {
            final current = _isFull ? widget.provider : env.models.detailOf(widget.provider.providerName);
            return DifyPopoverSurface(
              child: current != null
                  ? DropdownContent(provider: current, state: widget.state, onClose: _close)
                  : _detailError
                  ? Container(
                      width: 320,
                      padding: const EdgeInsets.all(16),
                      child: Semantics(
                        container: true,
                        liveRegion: true,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          spacing: 12,
                          children: [
                            Text(
                              _t('api.actionFailed'),
                              style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textPrimary),
                            ),
                            DifyButton(
                              size: DifyButtonSize.small,
                              onPressed: () => unawaited(_loadDetail(env)),
                              child: Text(_t('operation.retry')),
                            ),
                          ],
                        ),
                      ),
                    )
                  : Container(
                      width: 320,
                      padding: const EdgeInsets.all(16),
                      child: Semantics(
                        container: true,
                        liveRegion: true,
                        label: _t('loading'),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          spacing: 8,
                          children: [
                            DifySpinner(size: 16, color: DifyColors.textTertiary),
                            Text(
                              _t('loading'),
                              style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ),
            );
          },
        ),
      ),
    );
  }
}

/// dropdown-content.tsx: `w-[320px]`, the API key section; deleting asks first ("Delete").
class DropdownContent extends StatefulWidget {
  const DropdownContent({super.key, required this.provider, required this.state, required this.onClose});

  final Json provider;
  final CredentialPanelState state;
  final VoidCallback onClose;

  @override
  State<DropdownContent> createState() => _DropdownContentState();
}

class _DropdownContentState extends State<DropdownContent> {
  ModelAuth? _auth;
  late final _activate = ActivateCredential(
    onChanged: () {
      if (mounted) setState(() {});
    },
  );

  @override
  Widget build(BuildContext context) {
    final env = ModelProviderScope.of(context);
    final p = widget.provider;
    final auth = _auth ??= ModelAuth(
      env: env,
      provider: p,
      configurationMethod: ConfigurationMethodEnum.predefinedModel,
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
    void handleEdit(Credential? credential) {
      if (credential != null ? !env.canManageCredential : !env.canCreateCredential) return;
      auth.handleOpenModal(context, credential: credential);
      widget.onClose();
    }

    void handleDelete(Credential? credential) {
      if (!env.canManageCredential || credential == null) return;
      unawaited(
        auth.confirmDelete(
          context,
          credential: credential,
          confirmLabel: _t('operation.delete'),
          lockCancelWhileBusy: true,
        ),
      );
    }

    void handleAdd() {
      if (!env.canCreateCredential) return;
      auth.handleOpenModal(context);
      widget.onClose();
    }

    return SizedBox(
      width: 320,
      child: ApiKeySection(
        provider: p,
        credentials: p.availableCredentials,
        selectedCredentialId: _activate.selectedCredentialId(p),
        isActivating: _activate.isActivating,
        onItemClick: (c) => unawaited(_activate.activate(env, p, c)),
        onEdit: handleEdit,
        onDelete: handleDelete,
        onAdd: handleAdd,
      ),
    );
  }
}

/// use-activate-credential.ts: picking a credential makes it current at once (optimistically), toasts "Action
/// succeeded" and refreshes the providers and model lists; a failure reverts it ("Modified unsuccessfully").
class ActivateCredential {
  ActivateCredential({this.onChanged});

  final VoidCallback? onChanged;
  String? _optimisticId;
  bool _pending = false;

  bool get isActivating => _pending;

  String? selectedCredentialId(Json provider) => _optimisticId ?? provider.currentCredentialId;

  Future<void> activate(ModelProviderEnv env, Json provider, Credential credential) async {
    if (credential.credentialId == selectedCredentialId(provider)) return;
    _optimisticId = credential.credentialId;
    _pending = true;
    onChanged?.call();
    try {
      await env.models.credentials.switchProviderCredential(
        provider.providerName,
        credentialId: credential.credentialId,
      );
      toast.success(_t('api.actionSuccess'));
      unawaited(env.models.updateModelProviders());
      for (final t in provider.supportedModelTypes) {
        unawaited(env.models.updateModelList(t));
      }
    } on Object {
      _optimisticId = null;
      toast.error(_t('actionMsg.modifiedUnsuccessfully'));
    } finally {
      _pending = false;
      onChanged?.call();
    }
  }
}

/// api-key-section.tsx: without credentials, the "No API keys configured yet" card and "Add API Key"; otherwise
/// "API KEYS" (`pt-3 pr-2 pb-1 pl-7 system-xs-medium-uppercase`), the credentials (`max-h-50`, the current one
/// checked) and "Add API Key". Members who cannot use credentials cannot pick one; who cannot manage them, neither
/// edit nor delete.
class ApiKeySection extends StatelessWidget {
  const ApiKeySection({
    super.key,
    required this.provider,
    required this.credentials,
    required this.selectedCredentialId,
    required this.onItemClick,
    required this.onEdit,
    required this.onDelete,
    required this.onAdd,
    this.isActivating = false,
  });

  final Json provider;
  final List<Credential> credentials;
  final String? selectedCredentialId;
  final bool isActivating;
  final ValueChanged<Credential> onItemClick;
  final ValueChanged<Credential?> onEdit, onDelete;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final env = ModelProviderScope.of(context);
    final notAllowCustomCredential = !provider.allowCustomToken;
    final addButton = !notAllowCustomCredential && env.canCreateCredential
        ? DifyButton(
            key: const ValueKey('api-key-section-add'),
            onPressed: onAdd,
            child: Text(_t('modelProvider.auth.addApiKey')),
          )
        : null;
    if (credentials.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                gradient: LinearGradient(colors: [DifyColors.stateBaseHover, Color(0x00FFFFFF)]),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Text(
                    _t('modelProvider.card.noApiKeysTitle'),
                    style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary),
                  ),
                  Text(
                    _t('modelProvider.card.noApiKeysDescription'),
                    style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                  ),
                ],
              ),
            ),
            ?addButton,
          ],
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 12, 8, 4),
                  child: Text(
                    difyTransform(DifyType.systemXsMediumUppercase, _t('modelProvider.auth.apiKeys')),
                    style: difyTextStyle(DifyType.systemXsMediumUppercase, DifyColors.textTertiary),
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final c in credentials)
                          CredentialItem(
                            key: ValueKey(c.credentialId),
                            credential: c,
                            disabled: isActivating,
                            showSelectedIcon: true,
                            selectedCredentialId: selectedCredentialId,
                            onItemClick: env.canUseCredential ? onItemClick : null,
                            onEdit: onEdit,
                            onDelete: onDelete,
                            disableEdit: !env.canManageCredential,
                            disableDelete: !env.canManageCredential,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (addButton != null) Padding(padding: const EdgeInsets.all(8), child: addButton),
        ],
      ),
    );
  }
}

// ---- LazyCustomModelActions ----------------------------------------------------------------------------------------

/// lazy-custom-model-actions.tsx: "Manage Credentials" (when the provider has custom models) and "Add Model"; the
/// provider's details load on the first click, then the real [ManageCustomModelCredentials] and [AddCustomModel]
/// take over (opened by that click).
class LazyCustomModelActions extends StatefulWidget {
  const LazyCustomModelActions({super.key, required this.provider});

  final Json provider;

  @override
  State<LazyCustomModelActions> createState() => _LazyCustomModelActionsState();
}

class _LazyCustomModelActionsState extends State<LazyCustomModelActions> {
  bool _addOpen = false;
  bool _manageOpen = false;
  bool _loading = false;

  Future<Json?> _load(ModelProviderEnv env) async {
    setState(() => _loading = true);
    try {
      return await env.models.loadProviderDetail(widget.provider.providerName);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add(ModelProviderEnv env) async {
    final detail = await _load(env);
    if (detail == null || !mounted) return;
    if (detail.canAddedModels.isNotEmpty) {
      setState(() => _addOpen = true);
      return;
    }
    ModelAuth(
      env: env,
      provider: detail,
      configurationMethod: ConfigurationMethodEnum.customizableModel,
      isModelCredential: true,
      mode: ModelModalModeEnum.configCustomModel,
    ).handleOpenModal(context);
  }

  Future<void> _manage(ModelProviderEnv env) async {
    final detail = await _load(env);
    if (detail == null || !mounted) return;
    setState(() => _manageOpen = true);
  }

  @override
  Widget build(BuildContext context) {
    final env = ModelProviderScope.of(context);
    final detail = env.models.detailOf(widget.provider.providerName);
    final hasCustomModels = widget.provider.hasCustomModels;
    if (detail != null) {
      return Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (hasCustomModels)
            ManageCustomModelCredentials(
              provider: detail,
              isOpen: _manageOpen,
              onOpenChange: (open) => setState(() => _manageOpen = open),
            ),
          AddCustomModel(
            provider: detail,
            configurationMethod: ConfigurationMethodEnum.customizableModel,
            open: _addOpen,
            onOpenChange: (open) => setState(() => _addOpen = open),
          ),
        ],
      );
    }
    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (hasCustomModels) ManageCredentialsButton(loading: _loading, onPressed: () => unawaited(_manage(env))),
        AddModelButton(loading: _loading, onPressed: () => unawaited(_add(env))),
      ],
    );
  }
}
