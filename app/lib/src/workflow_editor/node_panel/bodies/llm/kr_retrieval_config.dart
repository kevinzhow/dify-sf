/// The Knowledge Retrieval panel's "Retrieval Setting" (nodes/knowledge-retrieval/components/retrieval-config.tsx
/// over app/configuration/dataset-config/params-config/config-content.tsx and weighted-score.tsx, with
/// base/param-item: ParamItem, TopKItem, ScoreThresholdItem).
library;

import 'package:flutter/widgets.dart';

import '../../../../cards/card_kit.dart';
import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../../workflow/model_catalog.dart';
import '../../../panel_fields/panel_fields.dart';
import 'group_host.dart';
import 'kr_config.dart';
import 'model_parameter_modal.dart';
import 'llm_vars.dart' show jsMap;

String _c(String key) => DifyI18n.tr('common', key);
String _w(String key) => DifyI18n.tr('workflow', key);
String _d(String key) => DifyI18n.tr('dataset', key);
String _ad(String key) => DifyI18n.tr('app-debug', key);

/// RetrievalConfig: the ghost "Retrieval Setting" button (disabled when [readonly]) and its popover (bottom-end,
/// `w-101 rounded-2xl px-4 pt-3 pb-4 shadow-xl`), open while [open]. ConfigContent's changes come back as the
/// multi-path config ([onMultipleRetrievalConfigChange]) or, for the legacy mode switch, [onRetrievalModeChange].
class RetrievalConfig extends StatelessWidget {
  const RetrievalConfig({
    super.key,
    required this.retrievalMode,
    required this.multipleRetrievalConfig,
    required this.onRetrievalModeChange,
    required this.onMultipleRetrievalConfigChange,
    required this.open,
    required this.onOpenChange,
    required this.selectedDatasets,
    this.singleRetrievalModelConfig,
    this.onSingleRetrievalModelChange,
    this.onSingleRetrievalModelParamsChange,
    this.readonly = false,
  });

  final String? retrievalMode;
  final Json? multipleRetrievalConfig;
  final ValueChanged<String> onRetrievalModeChange;
  final ValueChanged<Json> onMultipleRetrievalConfigChange;
  final bool open, readonly;
  final ValueChanged<bool> onOpenChange;
  final List<Json> selectedDatasets;
  final Json? singleRetrievalModelConfig;
  final ValueChanged<ModelChoice>? onSingleRetrievalModelChange;
  final ValueChanged<Json>? onSingleRetrievalModelParamsChange;

  void _change(Json configs, bool isRetrievalModeChange) {
    if (isRetrievalModeChange) return onRetrievalModeChange('${configs['retrieval_model']}');
    onMultipleRetrievalConfigChange(multipleConfigFromDatasetConfigs(configs, retrievalMode));
  }

  @override
  Widget build(BuildContext context) {
    final services = LlmGroupScope.of(context);
    return DifyFloating(
      open: open && !readonly,
      onOpenChange: (v) {
        if (!readonly) onOpenChange(v);
      },
      placement: DifyPlacement.bottomEnd,
      alignOffset: -2,
      builder: (context, c) => DifyButton(
        variant: DifyButtonVariant.ghost,
        size: DifyButtonSize.small,
        disabled: readonly,
        leading: const RemixIcon('equalizer-2-line', size: 14),
        onPressed: () => onOpenChange(!open),
        child: Text(_d('retrievalSettings')),
      ),
      popupBuilder: (context) => LlmGroupScope(
        services: services,
        child: Container(
          width: 404,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          decoration: BoxDecoration(
            color: DifyColors.componentsPanelBg,
            borderRadius: BorderRadius.circular(DifyRadius.xxl),
            border: Border.all(color: DifyColors.componentsPanelBorder),
            boxShadow: DifyShadows.xl,
          ),
          child: ConfigRetrievalContent(
            datasetConfigs: datasetConfigsOf(retrievalMode, multipleRetrievalConfig),
            onChange: _change,
            selectedDatasets: selectedDatasets,
            isInWorkflow: true,
            singleRetrievalModelConfig: singleRetrievalModelConfig,
            onSingleRetrievalModelChange: onSingleRetrievalModelChange,
            onSingleRetrievalModelParamsChange: onSingleRetrievalModelParamsChange,
          ),
        ),
      ),
    );
  }
}

/// ConfigContent (`isInWorkflow`): the header and multi-path tip; the rerank settings (warnings by the datasets' mix,
/// Weighted Score / Rerank Model cards, the rerank switch and model, Top K and Score Threshold); a legacy single
/// mode is migrated to multiple on mount.
class ConfigRetrievalContent extends StatefulWidget {
  const ConfigRetrievalContent({
    super.key,
    required this.datasetConfigs,
    required this.onChange,
    this.selectedDatasets = const [],
    this.isInWorkflow = false,
    this.singleRetrievalModelConfig,
    this.onSingleRetrievalModelChange,
    this.onSingleRetrievalModelParamsChange,
  });

  final Json datasetConfigs;

  /// `onChange(configs, isRetrievalModeChange)`.
  final void Function(Json configs, bool isRetrievalModeChange) onChange;
  final List<Json> selectedDatasets;
  final bool isInWorkflow;
  final Json? singleRetrievalModelConfig;
  final ValueChanged<ModelChoice>? onSingleRetrievalModelChange;
  final ValueChanged<Json>? onSingleRetrievalModelParamsChange;

  @override
  State<ConfigRetrievalContent> createState() => _ConfigRetrievalContentState();
}

class _ConfigRetrievalContentState extends State<ConfigRetrievalContent> {
  @override
  void initState() {
    super.initState();
    _migrate();
  }

  @override
  void didUpdateWidget(ConfigRetrievalContent old) {
    super.didUpdateWidget(old);
    _migrate();
  }

  /// The legacy single path becomes multiple as soon as the settings show.
  void _migrate() {
    if (widget.datasetConfigs['retrieval_model'] != RetrieveType.oneWay) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.datasetConfigs['retrieval_model'] != RetrieveType.oneWay) return;
      widget.onChange({...widget.datasetConfigs, 'retrieval_model': RetrieveType.multiWay}, widget.isInWorkflow);
    });
  }

  Json get _configs => widget.datasetConfigs;
  void _set(Map<String, Object?> patch) => widget.onChange({..._configs, ...patch}, false);

  @override
  Widget build(BuildContext context) {
    final services = LlmGroupScope.of(context);
    final toast = services.toast;
    final mode = getSelectedDatasetsMode(widget.selectedDatasets);
    final type = _configs['retrieval_model'];
    final rerankList = services.models.modelList(ModelTypeEnum.rerank);
    final def = services.defaultModels[ModelTypeEnum.rerank];
    final (currentProvider: defProvider, currentModel: defModel) = getCurrentProviderAndModel(
      rerankList,
      def == null ? null : (provider: def.provider, model: def.model),
    );
    final rm = jsMap(_configs['reranking_model']);
    final providerName = jsStr(rm['reranking_provider_name']) ?? '';
    final modelName = jsStr(rm['reranking_model_name']) ?? '';
    final (currentProvider: _, currentModel: currentRerankModel) = getCurrentProviderAndModel(rerankList, (
      provider: providerName.isNotEmpty ? providerName : (defProvider?.provider ?? ''),
      model: modelName.isNotEmpty ? modelName : (defModel?.model ?? ''),
    ));
    final showWeightedScore = mode.allHighQuality && !mode.inconsistentEmbeddingModel;
    final weights = _configs['weights'];
    final showWeightedScorePanel =
        showWeightedScore && _configs['reranking_mode'] == RerankingMode.weightedScore && weights is Map;
    final selectedRerankMode = jsStr(_configs['reranking_mode']) ?? RerankingMode.rerankingModel;
    final canManuallyToggleRerank = (mode.allInternal && mode.allEconomic) || mode.allExternal;
    final showRerankModel = !canManuallyToggleRerank || _configs['reranking_enable'] == true;
    final topK = (_configs['top_k'] as num?)?.toInt() ?? DatasetDefault.topK;
    final threshold = _configs['score_threshold'] as num?;
    final thresholdEnabled = _configs['score_threshold_enabled'] == true;

    Widget warning(String key) => Padding(
      padding: const EdgeInsets.only(top: 16),
      child: DifyText(_d(key), DifyType.systemXsMedium, color: DifyColors.textWarning, maxLines: null),
    );

    final topKItem = TopKItem(value: topK, onChange: (v) => _set({'top_k': v}));
    final thresholdItem = ScoreThresholdItem(
      value: threshold,
      enable: thresholdEnabled,
      hasSwitch: true,
      onChange: (v) => _set({'score_threshold': v}),
      onSwitchChange: (on) => _set({'score_threshold_enabled': on}),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        DifyText(_d('retrievalSettings'), DifyType.systemXlSemibold),
        DifyText(_d('defaultRetrievalTip'), DifyType.systemXsRegular, color: DifyColors.textTertiary, maxLines: null),
        if (type == RetrieveType.multiWay) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              children: [
                DifyText(_d('rerankSettings'), DifyType.systemXsSemiboldUppercase, color: DifyColors.textSecondary),
                const SizedBox(height: 8),
                Container(
                  height: 1,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(colors: [DifyColors.dividerRegular, Color(0x00FFFFFF)]),
                  ),
                ),
              ],
            ),
          ),
          if (mode.inconsistentEmbeddingModel) warning('inconsistentEmbeddingModelTip'),
          if (mode.mixtureInternalAndExternal) warning('mixtureInternalAndExternalTip'),
          if (mode.allExternal) warning('allExternalTip'),
          if (mode.mixtureHighQualityAndEconomic) warning('mixtureHighQualityAndEconomicTip'),
          if (showWeightedScore)
            Row(
              spacing: 8,
              children: [
                for (final (value, label, tips) in [
                  (RerankingMode.weightedScore, _d('weightedScore.title'), _d('weightedScore.description')),
                  (
                    RerankingMode.rerankingModel,
                    _c('modelProvider.rerankModel.key'),
                    _c('modelProvider.rerankModel.tip'),
                  ),
                ])
                  Expanded(
                    child: _RerankModeCard(
                      label: label,
                      tips: tips,
                      selected: selectedRerankMode == value,
                      onTap: () {
                        if (value == _configs['reranking_mode']) return;
                        if (value == RerankingMode.rerankingModel && currentRerankModel == null) {
                          toast?.call(LlmToastType.error, _w('errorMsg.rerankModelRequired'));
                        }
                        _set({'reranking_mode': value});
                      },
                    ),
                  ),
              ],
            ),
          if (!showWeightedScorePanel)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      if (canManuallyToggleRerank)
                        DifySwitch(
                          checked: showRerankModel,
                          semanticLabel: _c('modelProvider.rerankModel.key'),
                          onCheckedChange: (on) {
                            if (currentRerankModel == null && on) {
                              toast?.call(LlmToastType.error, _w('errorMsg.rerankModelRequired'));
                            }
                            _set({'reranking_enable': on});
                          },
                        ),
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 4, right: 4),
                          child: SizedBox(
                            height: 32,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: DifyText(
                                _c('modelProvider.rerankModel.key'),
                                DifyType.systemSmSemibold,
                                color: DifyColors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Infotip(
                        label: _c('modelProvider.rerankModel.tip'),
                        width: 200,
                        content: Text(_c('modelProvider.rerankModel.tip')),
                      ),
                    ],
                  ),
                  if (showRerankModel)
                    ModelSelector(
                      value: (provider: providerName, model: modelName),
                      models: rerankList,
                      onChange: (v) => _set({
                        'reranking_model': {'reranking_provider_name': v.provider, 'reranking_model_name': v.model},
                      }),
                    ),
                ],
              ),
            ),
          if (showWeightedScorePanel)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: [
                  WeightedScore(
                    semantic: (jsGet(weights['vector_setting'], 'vector_weight') as num?)?.toDouble() ?? 0,
                    keyword: (jsGet(weights['keyword_setting'], 'keyword_weight') as num?)?.toDouble() ?? 0,
                    onChange: (semantic, keyword) => _set({
                      'weights': {
                        ...jsMap(weights),
                        'vector_setting': {...jsMap(weights['vector_setting']), 'vector_weight': semantic},
                        'keyword_setting': {'keyword_weight': keyword},
                      },
                    }),
                  ),
                  topKItem,
                  thresholdItem,
                ],
              ),
            ),
          if (!showWeightedScorePanel)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: [topKItem, if (showRerankModel) thresholdItem],
              ),
            ),
        ],
        if (widget.isInWorkflow && type == RetrieveType.oneWay)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  spacing: 2,
                  children: [
                    Flexible(
                      child: Text(
                        _c('modelProvider.systemReasoningModel.key'),
                        style: const TextStyle(
                          fontSize: 13,
                          height: 32 / 13,
                          fontWeight: FontWeight.w500,
                          color: DifyColors.textPrimary,
                        ),
                      ),
                    ),
                    Infotip(
                      label: _c('modelProvider.systemReasoningModel.tip'),
                      content: Text(_c('modelProvider.systemReasoningModel.tip')),
                    ),
                  ],
                ),
                ModelParameterModal(
                  provider: jsStr(widget.singleRetrievalModelConfig?['provider']) ?? '',
                  modelId: jsStr(widget.singleRetrievalModelConfig?['name']) ?? '',
                  completionParams: jsMap(widget.singleRetrievalModelConfig?['completion_params']),
                  onModelChange: widget.onSingleRetrievalModelChange ?? (_) {},
                  onCompletionParamsChange: widget.onSingleRetrievalModelParamsChange ?? (_) {},
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The rerank mode option: `h-8 rounded-lg border system-sm-medium`, selected `border-[1.5px]` in the option-card
/// selected colours, with its infotip.
class _RerankModeCard extends StatelessWidget {
  const _RerankModeCard({required this.label, required this.tips, required this.selected, required this.onTap});
  final String label, tips;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: label,
    onPressed: onTap,
    builder: (context, hovered, focused) => Semantics(
      selected: selected,
      child: Container(
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? DifyColors.componentsOptionCardOptionSelectedBg : DifyColors.componentsOptionCardOptionBg,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          border: Border.all(
            color: selected
                ? DifyColors.componentsOptionCardOptionSelectedBorder
                : DifyColors.componentsOptionCardOptionBorder,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: DifyText(
                label,
                DifyType.systemSmMedium,
                color: selected ? DifyColors.textPrimary : DifyColors.textSecondary,
              ),
            ),
            const SizedBox(width: 2),
            Infotip(label: tips, width: 200, iconSize: 14, content: Text(tips)),
          ],
        ),
      ),
    ),
  );
}

/// weighted-score.tsx `formatNumber`: `0.x`, `1.0`, `0`.
String formatWeight(double v) {
  if (v > 0 && v < 1) return '0.${(v * 10).round()}';
  if (v == 1) return '1.0';
  return v == v.roundToDouble() ? '${v.toInt()}' : '$v';
}

/// WeightedScore: a 0..1 slider (step 0.1) over the teal track with the blue-light range; SEMANTIC x on the left,
/// x KEYWORD on the right, keyword = 1 - semantic.
class WeightedScore extends StatelessWidget {
  const WeightedScore({
    super.key,
    required this.semantic,
    required this.keyword,
    required this.onChange,
    this.readonly = false,
  });
  final double semantic, keyword;
  final void Function(double semantic, double keyword) onChange;
  final bool readonly;

  void _step(int by) {
    final steps = ((semantic * 10).round() + by).clamp(0, 10);
    onChange(steps / 10, (10 - steps) / 10);
  }

  void _set(double dx, double width) {
    if (readonly || width <= 0) return;
    final steps = ((dx / width).clamp(0.0, 1.0) * 10).round();
    onChange(steps / 10, (10 - steps) / 10);
  }

  @override
  Widget build(BuildContext context) {
    final sem = _d('weightedScore.semantic'), kw = _d('weightedScore.keyword');
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 20, 12, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(DifyRadius.lg),
        border: Border.all(color: DifyColors.componentsPanelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            slider: true,
            label: sem,
            value: '$sem: ${formatWeight(semantic)}, $kw: ${formatWeight(keyword)}',
            onIncrease: readonly ? null : () => _step(1),
            onDecrease: readonly ? null : () => _step(-1),
            child: LayoutBuilder(
              builder: (context, c) {
                final width = c.maxWidth;
                final f = semantic.clamp(0.0, 1.0);
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _set(d.localPosition.dx, width),
                  onHorizontalDragUpdate: (d) => _set(d.localPosition.dx, width),
                  child: SizedBox(
                    height: 20,
                    child: Stack(
                      alignment: Alignment.centerLeft,
                      children: [
                        Container(
                          height: 4,
                          decoration: BoxDecoration(
                            color: DifyColors.utilColorsTealTeal500,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        Container(
                          width: width * f,
                          height: 4,
                          decoration: BoxDecoration(
                            color: DifyColors.utilColorsBlueLightBlueLight500,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        Positioned(
                          left: (width * f - 4).clamp(0.0, width - 8),
                          child: Container(
                            width: 8,
                            height: 20,
                            decoration: BoxDecoration(
                              color: DifyColors.componentsSliderKnob,
                              borderRadius: BorderRadius.circular(3),
                              border: Border.all(color: DifyColors.componentsSliderKnobBorder, width: 0.5),
                              boxShadow: DifyShadows.sm,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              SizedBox(
                width: 90,
                child: Row(
                  children: [
                    Flexible(
                      child: DifyText(
                        sem.toUpperCase(),
                        DifyType.systemXsSemiboldUppercase,
                        color: DifyColors.utilColorsBlueLightBlueLight500,
                      ),
                    ),
                    const SizedBox(width: 4),
                    DifyText(
                      formatWeight(semantic),
                      DifyType.systemXsSemiboldUppercase,
                      color: DifyColors.utilColorsBlueLightBlueLight500,
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 90,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    DifyText(
                      formatWeight(keyword),
                      DifyType.systemXsSemiboldUppercase,
                      color: DifyColors.utilColorsTealTeal500,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: DifyText(
                        kw.toUpperCase(),
                        DifyType.systemXsSemiboldUppercase,
                        color: DifyColors.utilColorsTealTeal500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// ParamItem (base/param-item): the optional switch, the name and infotip, then a number field (`w-18`) and a slider
/// (on a ×100 scale when [max] < 5), both disabled unless [enable].
class ParamItem extends StatelessWidget {
  const ParamItem({
    super.key,
    required this.name,
    required this.value,
    required this.max,
    required this.enable,
    required this.onChange,
    this.tip,
    this.min = 0,
    this.step = 0.1,
    this.disabled = false,
    this.hasSwitch = false,
    this.onSwitchChange,
  });

  final String name;
  final String? tip;
  final num value, min, max, step;
  final bool enable, disabled, hasSwitch;
  final ValueChanged<num> onChange;
  final ValueChanged<bool>? onSwitchChange;

  @override
  Widget build(BuildContext context) {
    final scale = max < 5 ? 100 : 1;
    final off = disabled || !enable;
    return Semantics(
      container: true,
      label: name,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 24,
            child: Row(
              children: [
                if (hasSwitch)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: DifySwitch(
                      checked: enable,
                      disabled: disabled,
                      semanticLabel: name,
                      onCheckedChange: onSwitchChange,
                    ),
                  ),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: DifyText(name, DifyType.systemSmSemibold, color: DifyColors.textSecondary),
                  ),
                ),
                if (tip != null && tip!.isNotEmpty) Infotip(label: tip!, width: 200, content: Text(tip!)),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              SizedBox(
                width: 72,
                child: DifyNumberField(
                  value: value,
                  min: min,
                  max: max,
                  step: step,
                  disabled: off,
                  semanticLabel: name,
                  onChanged: (v) => onChange(v ?? min),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DifySlider(
                  value: (value * scale).round(),
                  min: (min < 1 ? min * 100 : min).round(),
                  max: (max * scale).round(),
                  disabled: off,
                  semanticLabel: name,
                  valueText: scale == 100 ? (v) => '${v / 100}' : null,
                  onChanged: (v) => onChange(v / scale),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// TopKItem: 1 to [topKMaxValue], step 1, the value rounded and clamped; no switch.
class TopKItem extends StatelessWidget {
  const TopKItem({super.key, required this.value, required this.onChange, this.disabled = false});
  final num value;
  final ValueChanged<int> onChange;
  final bool disabled;

  @override
  Widget build(BuildContext context) => ParamItem(
    name: _ad('datasetConfig.top_k'),
    tip: _ad('datasetConfig.top_kTip'),
    value: value,
    min: 1,
    max: topKMaxValue,
    step: 1,
    enable: true,
    disabled: disabled,
    onChange: (v) => onChange(v.toDouble().round().clamp(1, topKMaxValue)),
  );
}

/// `normalizeScoreThreshold`: 0.7 when not a number, rounded to 2 decimals, within 0..1.
double normalizeScoreThreshold(num? value) {
  final v = value != null && value.isFinite ? value.toDouble() : 0.7;
  return double.parse(v.toStringAsFixed(2)).clamp(0.0, 1.0);
}

/// ScoreThresholdItem: 0 to 1, step 0.01, with its switch.
class ScoreThresholdItem extends StatelessWidget {
  const ScoreThresholdItem({
    super.key,
    required this.value,
    required this.enable,
    required this.onChange,
    this.hasSwitch = false,
    this.onSwitchChange,
    this.disabled = false,
  });
  final num? value;
  final bool enable, hasSwitch, disabled;
  final ValueChanged<double> onChange;
  final ValueChanged<bool>? onSwitchChange;

  @override
  Widget build(BuildContext context) => ParamItem(
    name: _ad('datasetConfig.score_threshold'),
    tip: _ad('datasetConfig.score_thresholdTip'),
    value: normalizeScoreThreshold(value),
    min: 0,
    max: 1,
    step: 0.01,
    enable: enable,
    disabled: disabled,
    hasSwitch: hasSwitch,
    onSwitchChange: onSwitchChange,
    onChange: (v) => onChange(normalizeScoreThreshold(v)),
  );
}
