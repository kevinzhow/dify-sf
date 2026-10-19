/// model-provider-page/index.tsx and model-provider-page-body.tsx: the model provider page: the toolbar (provider
/// search, the "configure a default model" warning, the default models button) and the provider cards, configured
/// ones first (OpenAI, then Anthropic, ahead) and "Configuration required" below. Dify's marketplace section, plugin
/// auto-update settings and Cloud credit panel need plugins or Dify Cloud.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/model_catalog.dart';
import '../../workflow/workspace_models.dart';
import '../../workflow_editor/block_selector/selector_widgets.dart' show SelectorSearchInput;
import 'model_provider_env.dart';
import 'provider_added_card.dart';
import 'system_model_selector.dart';

String _t(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

/// FixedModelProvider: the providers listed first, in this order.
const fixedModelProviders = ['langgenius/openai/openai', 'langgenius/anthropic/anthropic'];

/// The page's split into its configured and not configured providers, the fixed providers first (a stable sort).
({List<Json> configured, List<Json> notConfigured}) splitProviders(List<Json> providers) {
  final configured = <Json>[], notConfigured = <Json>[];
  for (final p in providers) {
    (p['is_configured'] == true ? configured : notConfigured).add(p);
  }
  int rank(Json p) {
    final i = fixedModelProviders.indexOf('${p['provider']}');
    return i < 0 ? fixedModelProviders.length : i;
  }

  final indexed = [for (final (i, p) in configured.indexed) (i, p)]
    ..sort((a, b) {
      final r = rank(a.$2).compareTo(rank(b.$2));
      return r != 0 ? r : a.$1.compareTo(b.$1);
    });
  return (configured: [for (final e in indexed) e.$2], notConfigured: notConfigured);
}

/// The provider search: the provider id or any of its labels contains [text] (case-insensitive).
bool providerMatches(Json provider, String text) {
  final q = text.toLowerCase();
  if ('${provider['provider']}'.toLowerCase().contains(q)) return true;
  final label = provider['label'];
  return label is Map && label.values.any((v) => v is String && v.toLowerCase().contains(q));
}

/// SystemModelConfigStatus.
enum SystemModelConfigStatus { noProvider, noneConfigured, partiallyConfigured, fullyConfigured }

/// The configuration status of the default models.
SystemModelConfigStatus systemModelConfigStatus(int configuredDefaults, int configuredProviders) {
  if (configuredDefaults == 0 && configuredProviders == 0) return SystemModelConfigStatus.noProvider;
  if (configuredDefaults == 0) return SystemModelConfigStatus.noneConfigured;
  if (configuredDefaults < defaultModelTypes.length) return SystemModelConfigStatus.partiallyConfigured;
  return SystemModelConfigStatus.fullyConfigured;
}

/// ModelProviderPage: see the library comment. [layout] places the toolbar and the body (the integrations page puts
/// the toolbar in its header and scrolls the body); by default the toolbar is above the body. [searchText] /
/// [onSearchTextChange] make the search controlled; the filter follows it after 500 ms.
class ModelProviderPage extends StatefulWidget {
  const ModelProviderPage({
    super.key,
    this.layout,
    this.searchText,
    this.onSearchTextChange,
    this.stickyToolbar = false,
    this.hideSystemModelSelectorProviderSettingsFooter = false,
  });

  final Widget Function(BuildContext context, Widget toolbar, Widget body)? layout;
  final String? searchText;
  final ValueChanged<String>? onSearchTextChange;
  final bool stickyToolbar;
  final bool hideSystemModelSelectorProviderSettingsFooter;

  @override
  State<ModelProviderPage> createState() => _ModelProviderPageState();
}

class _ModelProviderPageState extends State<ModelProviderPage> {
  String _ownSearch = '';
  String _debounced = '';
  Timer? _debounce;
  ModelProviderEnv? _env;

  String get _search => widget.searchText ?? _ownSearch;

  @override
  void initState() {
    super.initState();
    _debounced = widget.searchText ?? '';
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final env = ModelProviderScope.of(context);
    if (_env?.models == env.models) {
      _env = env;
      return;
    }
    _env = env;
    // The page's queries: the summary, the LLM list (the default models button) and, for members who set plugin
    // preferences, the default models.
    final m = env.models;
    unawaited(m.refreshSummary());
    unawaited(m.updateModelList(ModelTypeEnum.textGeneration));
    if (env.canSetPluginPreferences) {
      for (final t in defaultModelTypes) {
        unawaited(m.invalidateDefaultModel(t));
      }
    }
  }

  @override
  void didUpdateWidget(ModelProviderPage old) {
    super.didUpdateWidget(old);
    if (widget.searchText != null && widget.searchText != old.searchText) _schedule(widget.searchText!);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _schedule(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _debounced = value);
    });
  }

  void _onSearch(String value) {
    if (widget.onSearchTextChange != null) {
      widget.onSearchTextChange!(value);
    } else {
      setState(() => _ownSearch = value);
      _schedule(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final env = ModelProviderScope.of(context);
    final models = env.models;
    return ListenableBuilder(
      listenable: models,
      builder: (context, _) {
        final canSet = env.canSetPluginPreferences;
        final loadingProviders = models.isLoadingProviders || models.summary == null;
        final defaultsLoading = canSet && models.isDefaultModelsLoading;
        final split = splitProviders(models.summary ?? const []);
        final configuredDefaults = canSet ? defaultModelTypes.where((t) => models.defaultModel(t) != null).length : 0;
        final status = systemModelConfigStatus(configuredDefaults, split.configured.length);
        final warning = status == SystemModelConfigStatus.noProvider || status == SystemModelConfigStatus.noneConfigured
            ? 'modelProvider.noneConfigured'
            : null;
        final showWarning = canSet && !loadingProviders && !defaultsLoading && warning != null;
        final filteredConfigured = [
          for (final p in split.configured)
            if (providerMatches(p, _debounced)) p,
        ];
        final filteredNotConfigured = [
          for (final p in split.notConfigured)
            if (providerMatches(p, _debounced)) p,
        ];
        final showEmptyProvider = !loadingProviders && split.configured.isEmpty;
        final showConfigured = !loadingProviders && filteredConfigured.isNotEmpty;
        final showNotConfigured = !loadingProviders && filteredNotConfigured.isNotEmpty;

        Widget? selector(bool compact) => canSet
            ? SystemModelSelector(
                notConfigured: showWarning,
                isLoading: defaultsLoading,
                compact: compact,
                hideProviderSettingsFooter: widget.hideSystemModelSelectorProviderSettingsFooter,
              )
            : null;

        final toolbar = Padding(
          padding: EdgeInsets.only(bottom: widget.layout == null ? 8 : 0),
          child: Row(
            children: [
              SizedBox(
                width: 200,
                child: SelectorSearchInput(
                  key: const ValueKey('model-provider-search'),
                  value: _search,
                  placeholder: _t('modelProvider.searchModels'),
                  onChanged: _onSearch,
                ),
              ),
              const SizedBox(width: 12),
              const Spacer(),
              if (showWarning)
                Flexible(
                  flex: 100,
                  child: _NoneConfiguredWarning(text: _t(warning), selector: selector(true)),
                )
              else
                ?selector(false),
            ],
          ),
        );

        final body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            if (loadingProviders) const ModelProviderListSkeleton(),
            if (showEmptyProvider) const EmptyProviderState(),
            if (showConfigured) _ProviderCardList(providers: filteredConfigured),
            if (showNotConfigured)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 8,
                  children: [
                    SizedBox(
                      height: 20,
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          _t('modelProvider.toBeConfigured'),
                          style: difyTextStyle(DifyType.systemMdSemibold, DifyColors.textPrimary),
                        ),
                      ),
                    ),
                    _ProviderCardList(providers: filteredNotConfigured, notConfigured: true),
                  ],
                ),
              ),
          ],
        );
        return widget.layout?.call(context, toolbar, body) ??
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [toolbar, body],
            );
      },
    );
  }
}

class _ProviderCardList extends StatelessWidget {
  const _ProviderCardList({required this.providers, this.notConfigured = false});
  final List<Json> providers;
  final bool notConfigured;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 8,
    children: [
      for (final p in providers)
        ProviderAddedCard(key: ValueKey('${p['provider']}'), provider: p, notConfigured: notConfigured),
    ],
  );
}

/// The warning next to the default models button: `inline-flex gap-2 rounded-lg border-[0.5px]
/// border-components-panel-border bg-components-panel-bg-blur py-1 pr-1 pl-2.5 shadow-xs`, an orange wash, the
/// alert icon and the text, then the compact button.
class _NoneConfiguredWarning extends StatelessWidget {
  const _NoneConfiguredWarning({required this.text, this.selector});
  final String text;
  final Widget? selector;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('model-provider-none-configured'),
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: DifyColors.componentsPanelBgBlur,
      borderRadius: BorderRadius.circular(DifyRadius.lg),
      border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
      boxShadow: DifyShadows.xs,
    ),
    child: Stack(
      children: [
        const Positioned.fill(
          child: Opacity(
            opacity: 0.4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment(-0.88, -0.48),
                  end: Alignment(0.88, 0.48),
                  colors: [Color(0x40F79009), Color(0x00FFFFFF)],
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: [
              Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 4,
                  children: [
                    const RemixIcon('alert-fill', size: 16, color: DifyColors.textWarningSecondary),
                    Flexible(
                      child: Text(
                        text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textPrimary),
                      ),
                    ),
                  ],
                ),
              ),
              ?selector,
            ],
          ),
        ),
      ],
    ),
  );
}

/// EmptyProviderState: `rounded-[10px] bg-workflow-process-bg p-4`, the brain icon in a card tile, "Model provider
/// not set up" and the tip.
class EmptyProviderState extends StatelessWidget {
  const EmptyProviderState({super.key});

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('model-provider-empty'),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      gradient: DifyGradients.workflowProcessBg,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: DifyColors.componentsCardBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: DifyColors.componentsCardBorder, width: Css.hairline),
            boxShadow: DifyShadows.lg,
          ),
          child: const RemixIcon('brain-2-line', size: 20, color: DifyColors.textPrimary),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _t('modelProvider.emptyProviderTitle'),
            style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            _t('modelProvider.emptyProviderTip'),
            style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
          ),
        ),
      ],
    ),
  );
}

/// ModelProviderListSkeleton: three card placeholders (`role=status`, named "Loading").
class ModelProviderListSkeleton extends StatelessWidget {
  const ModelProviderListSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label: _t('loading'),
    child: Column(
      key: const ValueKey('model-provider-skeleton'),
      spacing: 8,
      children: [for (var i = 0; i < 3; i++) const _CardSkeleton()],
    ),
  );
}

class _CardSkeleton extends StatelessWidget {
  const _CardSkeleton();

  static Widget _bar({double? width, required double height, double radius = DifyRadius.sm, double? factor}) {
    final bar = Opacity(
      opacity: 0.2,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(color: DifyColors.textQuaternary, borderRadius: BorderRadius.circular(radius)),
      ),
    );
    return factor == null
        ? bar
        : FractionallySizedBox(widthFactor: factor, alignment: AlignmentDirectional.centerStart, child: bar);
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: DifyColors.componentsCardBg,
      borderRadius: BorderRadius.circular(DifyRadius.xl),
      border: Border.all(color: DifyColors.componentsCardBorder, width: Css.hairline),
      boxShadow: DifyShadows.xs,
    ),
    child: SizedBox(
      height: 96,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            spacing: 8,
            children: [
              _bar(width: 40, height: 40, radius: DifyRadius.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 4,
                  children: [_bar(height: 16, factor: 0.4), _bar(height: 12, factor: 0.25)],
                ),
              ),
              _bar(width: 96, height: 32, radius: DifyRadius.lg),
            ],
          ),
          const SizedBox(height: 16),
          _bar(height: 12),
          const SizedBox(height: 8),
          _bar(height: 12, factor: 0.75),
        ],
      ),
    ),
  );
}
