/// web/app/components/base/features/new-feature-panel/annotation-reply: config-param-modal.tsx (the Annotation
/// Reply setup: score threshold and embedding model), config-param.tsx (`Item`) and score-slider (the 0-100 slider
/// shown as a 0.00-1.00 score).
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart' show AnnotationSetting;
import 'package:flutter/widgets.dart';

import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/model_catalog.dart';
import '../../workflow_editor/node_panel/bodies/llm/model_selector.dart';
import '../../workflow_editor/panel_fields/controls.dart' show DifySlider, Infotip;
import 'annotation_modals.dart' show AnnotationToast;
import 'annotation_overlays.dart';
import 'annotation_types.dart';

String _t(String ns, String key) => DifyI18n.tr(ns, key);

/// config-param.tsx `Item`: the title (`py-1 system-sm-semibold text-text-secondary`) with an Infotip, then [child].
class AnnotationConfigItem extends StatelessWidget {
  const AnnotationConfigItem({super.key, required this.title, required this.tooltip, required this.child});

  final String title, tooltip;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          spacing: 4,
          children: [
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(title, style: difyTextStyle(DifyType.systemSmSemibold, DifyColors.textSecondary)),
              ),
            ),
            Infotip(label: tooltip, width: 200, content: Text(tooltip)),
          ],
        ),
      ),
      child,
    ],
  );
}

/// ScoreSlider: [value] (0-100, clamped) on a slider named "Score Threshold" whose value text is the score
/// (`value / 100`, two decimals), the score floating above the thumb, and the "0.0 · Easy match" / "1.0 · Accurate
/// match" ends.
class AnnotationScoreSlider extends StatelessWidget {
  const AnnotationScoreSlider({super.key, required this.value, required this.onChange, this.topMargin = 0});

  final num value;
  final ValueChanged<int> onChange;

  /// A call site's `mt-*`.
  final double topMargin;

  @override
  Widget build(BuildContext context) {
    final safe = value.isFinite ? value.clamp(0, 100).round() : 0;
    final score = (safe / 100).toStringAsFixed(2);
    final ends = difyTextStyle(DifyType.systemXsSemiboldUppercase, DifyColors.utilColorsCyanCyan500);
    // `flex space-x-1`: the three parts 4 px apart (a space is about as wide), truncated before overflowing.
    Widget end(String n, String key, Color color) => Flexible(
      child: Text(
        '$n · ${difyTransform(DifyType.systemXsSemiboldUppercase, _t('appDebug', key))}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ends.copyWith(color: color),
      ),
    );
    return Padding(
      padding: EdgeInsets.only(top: topMargin),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: LayoutBuilder(
              builder: (context, c) => Stack(
                clipBehavior: Clip.none,
                children: [
                  DifySlider(
                    value: safe,
                    min: 0,
                    max: 100,
                    step: 1,
                    semanticLabel: _t('appDebug', 'feature.annotation.scoreThreshold.title'),
                    valueText: (v) => (v / 100).toStringAsFixed(2),
                    onChanged: onChange,
                  ),
                  Positioned(
                    top: -16,
                    left: 4 + safe / 100 * (c.maxWidth - 8),
                    child: IgnorePointer(
                      child: FractionalTranslation(
                        translation: const Offset(-0.5, 0),
                        child: ExcludeSemantics(
                          child: Text(score, style: difyTextStyle(DifyType.systemSmSemibold, DifyColors.textPrimary)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                end('0.0', 'feature.annotation.scoreThreshold.easyMatch', DifyColors.utilColorsCyanCyan500),
                end('1.0', 'feature.annotation.scoreThreshold.accurateMatch', DifyColors.utilColorsBlueBlue500),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// ConfigParamModal: "Annotation Reply Initial Setup" ([isInit]) or "Annotation Reply Setup" (`mt-14 w-160 p-6`): the
/// score threshold (the config's, else [annotationDefaultScoreThreshold]) and the embedding model (the config's, else
/// the workspace default). Save refuses without a model, or with the default model when it is not usable
/// ([isDefaultModelValid]), toasting "Embedding model is required"; it calls [onSave] with the model and the score
/// and blocks closing until it completes.
class AnnotationConfigParamModal extends StatefulWidget {
  const AnnotationConfigParamModal({
    super.key,
    required this.isShow,
    required this.onHide,
    required this.onSave,
    required this.annotationConfig,
    this.isInit = false,
    this.embeddingModels = const [],
    this.defaultEmbeddingModel,
    this.isDefaultModelValid = false,
    this.toast,
    this.modelSelector,
  });

  final bool isShow;
  final VoidCallback onHide;
  final Future<void> Function(EmbeddingModelConfig embeddingModel, double score) onSave;
  final AnnotationSetting annotationConfig;
  final bool isInit;

  /// `useModelListAndDefaultModelAndCurrentProviderAndModel(ModelTypeEnum.textEmbedding)`: the models, the default
  /// model and whether it is among them (`currentModel`).
  final List<ProviderWithModels> embeddingModels;
  final DefaultModel? defaultEmbeddingModel;
  final bool isDefaultModelValid;
  final AnnotationToast? toast;

  /// Replaces the model selector (Dify's tests mock it): built with the value and its setter.
  final Widget Function(DefaultModel? value, ValueChanged<DefaultModel> onChange)? modelSelector;

  @override
  State<AnnotationConfigParamModal> createState() => _AnnotationConfigParamModalState();
}

class _AnnotationConfigParamModalState extends State<AnnotationConfigParamModal> {
  late double? _score = widget.annotationConfig.scoreThreshold;
  bool _loading = false;
  late DefaultModel? _embeddingModel = switch (embeddingModelOf(widget.annotationConfig)) {
    final m? => (provider: m.embeddingProviderName, model: m.embeddingModelName),
    null => widget.defaultEmbeddingModel,
  };

  void _hide() {
    if (!_loading) widget.onHide();
  }

  Future<void> _save() async {
    final m = _embeddingModel;
    if (m == null ||
        m.model.isEmpty ||
        (m.model == widget.defaultEmbeddingModel?.model && !widget.isDefaultModelValid)) {
      (widget.toast ?? difyToast)(DifyToastType.error, _t('common', 'modelProvider.embeddingModel.required'));
      return;
    }
    setState(() => _loading = true);
    try {
      await widget.onSave(
        (embeddingProviderName: m.provider, embeddingModelName: m.model),
        _score ?? annotationDefaultScoreThreshold,
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _t('appAnnotation', widget.isInit ? 'initSetup.title' : 'initSetup.configTitle');
    void setModel(DefaultModel v) => setState(() => _embeddingModel = v);
    return AnnotationDialog(
      open: widget.isShow,
      onClose: _hide,
      width: 640,
      top: 56,
      label: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(title, style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary)),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                AnnotationConfigItem(
                  title: _t('appDebug', 'feature.annotation.scoreThreshold.title'),
                  tooltip: _t('appDebug', 'feature.annotation.scoreThreshold.description'),
                  child: AnnotationScoreSlider(
                    topMargin: 4,
                    value: (_score ?? annotationDefaultScoreThreshold) * 100,
                    onChange: (v) => setState(() => _score = v / 100),
                  ),
                ),
                AnnotationConfigItem(
                  title: _t('common', 'modelProvider.embeddingModel.key'),
                  tooltip: _t('appAnnotation', 'embeddingModelSwitchTip'),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child:
                        widget.modelSelector?.call(_embeddingModel, setModel) ??
                        ModelSelector(value: _embeddingModel, models: widget.embeddingModels, onChange: setModel),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                DifyButton(onPressed: _hide, child: Text(_t('common', 'operation.cancel'))),
                DifyButton(
                  variant: DifyButtonVariant.primary,
                  loading: _loading,
                  onPressed: () => unawaited(_save()),
                  child: Text(
                    _t('appAnnotation', widget.isInit ? 'initSetup.confirmBtn' : 'initSetup.configConfirmBtn'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
