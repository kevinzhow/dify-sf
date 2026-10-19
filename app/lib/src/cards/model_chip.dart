import 'package:flutter/material.dart';

import '../design/css_metrics.dart';

import 'package:flutter/rendering.dart';

import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../workflow/model_catalog.dart';
import 'provider_icon_image.dart';
import '../design/widgets/widgets.dart';

/// Remix icon per model feature (model-selector/feature-icon.tsx).
const featureIcons = {
  ModelFeatureEnum.vision: 'image-circle-ai-line',
  ModelFeatureEnum.document: 'file-text-line',
  ModelFeatureEnum.audio: 'voice-ai-fill',
  ModelFeatureEnum.video: 'film-ai-line',
};

/// OpenaiYellow is drawn in its own colours; this is the colour it is decoded with (see [IconCache]).
Color get openaiYellowColor => DifyColors.componentsInputTextFilled;

/// ModelBadge (model-badge/index.tsx): `inline-flex h-4.5 shrink-0 items-center justify-center rounded-[5px] border
/// border-divider-deep bg-components-badge-bg-dimm px-1.25 system-2xs-medium-uppercase text-text-tertiary`.
/// [width] with no padding: FeatureIcon's `w-4.5 justify-center px-0!`.
class ModelBadge extends StatelessWidget {
  const ModelBadge({super.key, required this.child, this.width});
  final Widget child;
  final double? width;

  /// A badge with [text].
  static Widget text(String text) => ModelBadge(
    child: DifyText(text, DifyType.system2xsMediumUppercase, color: DifyColors.textTertiary),
  );

  @override
  Widget build(BuildContext context) => Container(
    height: 18,
    width: width,
    padding: width == null ? const EdgeInsets.symmetric(horizontal: 5) : EdgeInsets.zero,
    alignment: width == null ? null : Alignment.center,
    decoration: BoxDecoration(
      color: DifyColors.componentsBadgeBgDimm,
      borderRadius: BorderRadius.circular(DifyRadius.badge),
      border: Border.all(color: DifyColors.dividerDeep),
    ),
    child: width == null ? Row(mainAxisSize: MainAxisSize.min, children: [child]) : child,
  );
}

/// FeatureIcon (model-selector/feature-icon.tsx): vision, document, audio and video as an icon badge, or icon +
/// label with [showFeaturesLabel]; other features draw nothing. (The "… supported" tooltip is left out.)
class FeatureIcon extends StatelessWidget {
  const FeatureIcon(this.feature, {super.key, this.showFeaturesLabel = false});
  final String feature;
  final bool showFeaturesLabel;

  static bool shows(String feature) => featureIcons.containsKey(feature);

  @override
  Widget build(BuildContext context) {
    final icon = featureIcons[feature];
    if (icon == null) return const SizedBox.shrink();
    final glyph = RemixIcon(icon, size: 12, color: DifyColors.textTertiary);
    if (!showFeaturesLabel) return ModelBadge(width: 18, child: glyph);
    return ModelBadge(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          glyph,
          const SizedBox(width: 2),
          DifyText(modelFeatureText[feature]!, DifyType.system2xsMediumUppercase, color: DifyColors.textTertiary),
        ],
      ),
    );
  }
}

/// ModelIcon (model-icon/index.tsx) with the trigger's `p-0.5`, 20 x 20: OpenaiYellow for OpenAI `o…` models, the
/// provider's `icon_small` (16 px inside the padding), or the fallback tile (`rounded-md border-[0.5px]
/// bg-background-default-subtle`, the Group icon at 35 % opacity).
class ModelIcon extends StatelessWidget {
  const ModelIcon({
    super.key,
    this.provider,
    this.iconSmall,
    this.iconSmallDark,
    this.modelName,
    this.language = 'en_US',
  });

  /// The provider's id (`provider.provider`) and `icon_small`; both null without a provider. [iconSmallDark]
  /// (`icon_small_dark`) replaces the icon in the dark theme where the provider has one.
  final String? provider;
  final I18nText? iconSmall, iconSmallDark;
  final String? modelName;
  final String language;

  @override
  Widget build(BuildContext context) {
    if (const ['openai', 'langgenius/openai/openai'].contains(provider) && (modelName?.startsWith('o') ?? false)) {
      return SizedBox.square(
        dimension: 20,
        child: Center(child: DifyIcon('public/llm/openai-yellow', size: 16, color: openaiYellowColor)),
      );
    }
    final dark = DifyColors.isDark && iconSmallDark != null ? renderI18nObject(iconSmallDark, language) : '';
    final url = dark.isNotEmpty ? dark : renderI18nObject(iconSmall, language);
    if (url.isNotEmpty) {
      return SizedBox.square(
        dimension: 20,
        child: Center(
          child: ProviderIconImage(url, width: 16, height: 16),
        ),
      );
    }
    return Container(
      width: 20,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: DifyColors.backgroundDefaultSubtle,
        borderRadius: BorderRadius.circular(DifyRadius.md),
        border: Border.all(color: DifyColors.componentsPanelBorderSubtle, width: Css.hairline),
      ),
      child: Opacity(
        opacity: 0.35,
        child: DifyIcon('vender/other/group', size: 12, color: DifyColors.textTertiary),
      ),
    );
  }
}

/// ModelName (model-name/index.tsx): `flex items-center gap-0.5 truncate system-sm-regular
/// text-components-input-text-filled`, the label (`truncate`, [lineThrough]: `line-through`) then the badges (model
/// type, mode, context size, features). Nothing without a model.
class ModelName extends StatelessWidget {
  const ModelName({
    super.key,
    required this.modelItem,
    this.language = 'en_US',
    this.lineThrough = false,
    this.showModelType = false,
    this.showMode = false,
    this.showContextSize = false,
    this.showFeatures = false,
    this.showFeaturesLabel = false,
    this.nameType = DifyType.systemSmRegular,
    this._nameColor,
  });
  final ModelItem? modelItem;

  /// The name's type and colour (a call site's `system-md-regular text-text-secondary`).
  final DifyTextStyle nameType;
  final Color? _nameColor;
  Color get nameColor => _nameColor ?? DifyColors.componentsInputTextFilled;
  final String language;
  final bool lineThrough;
  final bool showModelType;
  final bool showMode;
  final bool showContextSize;
  final bool showFeatures;
  final bool showFeaturesLabel;

  @override
  Widget build(BuildContext context) {
    final item = modelItem;
    if (item == null) return const SizedBox.shrink();
    final contextSize = item.modelProperties['context_size'];
    final badges = <Widget>[
      if (showModelType && item.modelType.isNotEmpty) ModelBadge.text(modelTypeFormat(item.modelType)),
      if (showMode && item.mode.isNotEmpty) ModelBadge.text(item.mode.toUpperCase()),
      if (showContextSize && contextSize is num && contextSize != 0) ModelBadge.text(sizeFormat(contextSize)),
      if (showFeatures)
        for (final f in item.features ?? const <String>[])
          if (FeatureIcon.shows(f)) FeatureIcon(f, showFeaturesLabel: showFeaturesLabel),
    ];
    // `truncate overflow-hidden`; the badge group is a flex item even when empty, so the gap is always there.
    return TruncatedRow(
      gap: 2,
      lead: ModelText(
        renderI18nObject(item.label, language),
        lineThrough: lineThrough,
        type: nameType,
        color: nameColor,
      ),
      trail: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, b) in badges.indexed) ...[if (i > 0) const SizedBox(width: 2), b],
        ],
      ),
    );
  }
}

/// A model name in `system-sm-regular text-components-input-text-filled`, cut with an ellipsis.
class ModelText extends StatelessWidget {
  const ModelText(
    this.text, {
    super.key,
    this.lineThrough = false,
    this._color,
    this.type = DifyType.systemSmRegular,
  });
  final String text;
  final bool lineThrough;
  final Color? _color;
  Color get color => _color ?? DifyColors.componentsInputTextFilled;
  final DifyTextStyle type;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.ellipsis,
    style: difyStyle(type, color).copyWith(
      decoration: lineThrough ? TextDecoration.lineThrough : null,
      decorationColor: color,
    ),
  );
}

/// The trigger's warning badge: `flex shrink-0 items-center gap-0.75 rounded-md border border-text-warning px-1.25
/// py-0.5` with `i-ri-alert-fill size-3` and the label in `system-xs-medium text-text-warning`; [dimm]:
/// `bg-components-badge-bg-dimm`, [minWidth]: credits-exhausted's `min-w-5 justify-center`. 22 px tall.
class ModelStatusBadge extends StatelessWidget {
  const ModelStatusBadge(this.label, {super.key, this.dimm = false, this.minWidth = false});
  final String label;
  final bool dimm;
  final bool minWidth;

  @override
  Widget build(BuildContext context) => Container(
    constraints: BoxConstraints(minWidth: minWidth ? 20 : 0),
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
    decoration: BoxDecoration(
      color: dimm ? DifyColors.componentsBadgeBgDimm : null,
      borderRadius: BorderRadius.circular(DifyRadius.md),
      border: Border.all(color: DifyColors.textWarning),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        RemixIcon('alert-fill', size: 12, color: DifyColors.textWarning),
        const SizedBox(width: 3),
        Text(
          label,
          maxLines: 1,
          softWrap: false,
          style: difyStyle(DifyType.systemXsMedium, DifyColors.textWarning),
        ),
      ],
    ),
  );
}

/// A CSS `flex items-center overflow-hidden` row of a shrinkable [lead] (min-width 0) and an optional [trail] that
/// keeps its natural width (`shrink-0`), [gap] apart: the lead gets what the trail leaves (all of it with
/// [fillLead], `grow`), and when even the trail does not fit it is cut off at the row's end.
class TruncatedRow extends MultiChildRenderObjectWidget {
  TruncatedRow({super.key, required Widget lead, Widget? trail, this.gap = 0, this.fillLead = false})
    : hasTrail = trail != null,
      super(children: [lead, trail ?? const SizedBox.shrink()]);
  final double gap;
  final bool fillLead;
  final bool hasTrail;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderTruncatedRow(hasTrail ? gap : 0, fillLead);

  @override
  void updateRenderObject(BuildContext context, RenderTruncatedRow renderObject) => renderObject
    ..gap = hasTrail ? gap : 0
    ..fillLead = fillLead;
}

class TruncatedRowParentData extends ContainerBoxParentData<RenderBox> {}

class RenderTruncatedRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, TruncatedRowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, TruncatedRowParentData> {
  RenderTruncatedRow(this._gap, this._fillLead);

  double _gap;
  set gap(double v) {
    if (v == _gap) return;
    _gap = v;
    markNeedsLayout();
  }

  bool _fillLead;
  set fillLead(bool v) {
    if (v == _fillLead) return;
    _fillLead = v;
    markNeedsLayout();
  }

  final _clip = LayerHandle<ClipRectLayer>();

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! TruncatedRowParentData) child.parentData = TruncatedRowParentData();
  }

  @override
  void performLayout() {
    final lead = firstChild!, trail = childAfter(lead)!;
    final c = constraints;
    trail.layout(BoxConstraints(maxHeight: c.maxHeight), parentUsesSize: true);
    final avail = (c.maxWidth - trail.size.width - _gap).clamp(0.0, double.infinity);
    final fill = _fillLead && avail.isFinite;
    lead.layout(
      BoxConstraints(minWidth: fill ? avail : 0, maxWidth: avail, maxHeight: c.maxHeight),
      parentUsesSize: true,
    );
    final h = lead.size.height > trail.size.height ? lead.size.height : trail.size.height;
    size = c.constrain(Size(lead.size.width + _gap + trail.size.width, h));
    (lead.parentData! as TruncatedRowParentData).offset = Offset(0, (size.height - lead.size.height) / 2);
    (trail.parentData! as TruncatedRowParentData).offset = Offset(
      lead.size.width + _gap,
      (size.height - trail.size.height) / 2,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      defaultPaint,
      oldLayer: _clip.layer,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }
}

/// ModelSelector's `surface`.
enum ModelSelectorSurface { normal, workflow }

/// ModelSelectorTrigger (model-selector/model-selector-trigger.tsx), size small, standalone: what the trigger shows
/// for the selection the selector resolved. [resolvedProvider] is the installed provider of the selected or default
/// model (the summary query) and [credentialPanelOf] stands for useCredentialPanelState.
class ModelSelectorTrigger extends StatelessWidget {
  const ModelSelectorTrigger({
    super.key,
    this.currentProvider,
    this.currentModel,
    this.defaultModel,
    this.resolvedProvider,
    required this.credentialPanelOf,
    this.disabled = false,
    this.surface = ModelSelectorSurface.normal,
    this.showDeprecatedWarnIcon = true,
    this.showModelMeta = true,
    this.isModelCompatible = true,
    this.language = 'en_US',
  });

  final ProviderWithModels? currentProvider;
  final ModelItem? currentModel;
  final DefaultModel? defaultModel;
  final ModelProvider? resolvedProvider;
  final CredentialPanelState Function(ModelProvider? provider) credentialPanelOf;
  final bool disabled;
  final ModelSelectorSurface surface;
  final bool showDeprecatedWarnIcon;
  final bool showModelMeta;
  final bool isModelCompatible;
  final String language;

  /// `data-[size=small]:h-6`, whatever the state.
  static const height = 24.0;

  /// "Configure model" (plugin `detailPanel.configureModel`): the empty state's placeholder and the trigger's label.
  static const configureModel = 'Configure model';

  bool get isSelected => currentProvider != null && currentModel != null;
  bool get isDeprecated => !isSelected && defaultModel != null;
  bool get isEmpty => !isSelected && defaultModel == null;

  DerivedModelStatus get status => deriveModelStatus(
    isSelected ? currentModel!.model : defaultModel?.model,
    isSelected ? currentProvider!.provider : defaultModel?.provider,
    resolvedProvider,
    currentModel,
    credentialPanelOf(resolvedProvider),
  );

  /// The trigger's background: `bg-components-input-bg-normal`, `bg-components-input-bg-disabled` for the unusable
  /// statuses, and `bg-workflow-block-parma-bg` on the workflow surface; disabled, active and empty are forced back to
  /// the normal background, the workflow surface to its own.
  Color background(DerivedModelStatus s) {
    if (surface == ModelSelectorSurface.workflow) return DifyColors.workflowBlockParmaBg;
    if (s == DerivedModelStatus.active || s == DerivedModelStatus.empty) return DifyColors.componentsInputBgNormal;
    return DifyColors.componentsInputBgDisabled;
  }

  @override
  Widget build(BuildContext context) {
    final s = status;
    final isActive = s == DerivedModelStatus.active;
    final statusLabel = isModelCompatible && s.badge != null ? s.badge! : DerivedModelStatus.incompatibleLabel;
    final tooltipLabel = isModelCompatible && s.tooltip != null ? s.tooltip! : DerivedModelStatus.incompatibleTip;
    final shouldShowModelMeta = showModelMeta && isActive && isModelCompatible;
    final triggerTooltip = isDeprecated && showDeprecatedWarnIcon
        ? tooltipLabel
        : isSelected && ((!isActive && s.badge != null) || !isModelCompatible)
        ? tooltipLabel
        : null;

    final Widget icon = isEmpty
        ? Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: DifyColors.backgroundDefaultSubtle,
              borderRadius: BorderRadius.circular(DifyRadius.md),
              border: Border.all(color: DifyColors.componentsPanelBorderSubtle, width: Css.hairline),
            ),
            child: RemixIcon('brain-2-line', size: 14, color: DifyColors.textQuaternary),
          )
        : ModelIcon(
            provider: isSelected ? currentProvider!.provider : resolvedProvider?.provider,
            iconSmall: isSelected ? currentProvider!.iconSmall : resolvedProvider?.iconSmall,
            iconSmallDark: isSelected ? currentProvider!.iconSmallDark : resolvedProvider?.iconSmallDark,
            modelName: isSelected ? currentModel!.model : defaultModel?.model,
            language: language,
          );

    final Widget name = isSelected
        ? ModelName(
            modelItem: currentModel,
            language: language,
            lineThrough: currentModel!.deprecated,
            showMode: shouldShowModelMeta,
            showFeatures: shouldShowModelMeta,
          )
        : isDeprecated
        ? ModelText(defaultModel!.model, lineThrough: true)
        : ModelText(configureModel, color: DifyColors.componentsInputTextPlaceholder);
    final Widget? badge = isSelected && !disabled && ((!isActive && s.badge != null) || !isModelCompatible)
        ? ModelStatusBadge(
            statusLabel,
            dimm: s == DerivedModelStatus.creditsExhausted,
            minWidth: s == DerivedModelStatus.creditsExhausted,
          )
        : isDeprecated && showDeprecatedWarnIcon
        ? ModelStatusBadge(statusLabel, dimm: true)
        : null;

    Widget content = Row(
      children: [
        icon,
        const SizedBox(width: 2),
        Expanded(
          // `flex grow items-center gap-1 truncate px-0.5`: the name grows, the badge keeps its width.
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: TruncatedRow(gap: 4, fillLead: true, lead: name, trail: badge),
          ),
        ),
      ],
    );
    // `data-[surface=workflow]:data-deprecated:[&>span]:opacity-50`.
    if (surface == ModelSelectorSurface.workflow && isDeprecated) content = Opacity(opacity: 0.5, child: content);

    Widget trigger = Semantics(
      button: true,
      enabled: !disabled,
      label: configureModel,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(color: background(s), borderRadius: BorderRadius.circular(DifyRadius.md)),
        child: Row(
          children: [
            Expanded(child: content),
            if (!disabled && (isActive || isEmpty)) ...[
              const SizedBox(width: 1),
              RemixIcon('arrow-down-s-line', size: 16, color: DifyColors.textQuaternary),
            ],
          ],
        ),
      ),
    );
    if (triggerTooltip != null && !disabled) {
      trigger = Tooltip(message: triggerTooltip, preferBelow: false, child: trigger);
    }
    return trigger;
  }
}

/// ModelSelector (model-selector/index.tsx) as the workflow cards render it: `size="small"`, disabled by default.
/// The selection is looked up in [models] (the list the node passes: text generation models for LLM, Question
/// Classifier and Parameter Extractor) and the provider in [catalog]'s installed providers.
class ModelChip extends StatelessWidget {
  const ModelChip({
    super.key,
    required this.value,
    required this.models,
    this.catalog = ModelCatalog.empty,
    this.disabled = true,
    this.surface = ModelSelectorSurface.normal,
    this.showDeprecatedWarnIcon = true,
    this.showModelMeta = true,
    this.modelPredicate,
  });

  final DefaultModel? value;
  final List<ProviderWithModels> models;
  final ModelCatalog catalog;
  final bool disabled;
  final ModelSelectorSurface surface;
  final bool showDeprecatedWarnIcon;
  final bool showModelMeta;
  final bool Function(ProviderWithModels provider, ModelItem model)? modelPredicate;

  static const height = ModelSelectorTrigger.height;

  ModelSelectorTrigger get trigger {
    final (:currentProvider, :currentModel) = getCurrentProviderAndModel(models, value);
    final providerId = currentProvider != null && currentModel != null ? currentProvider.provider : value?.provider;
    return ModelSelectorTrigger(
      currentProvider: currentProvider,
      currentModel: currentModel,
      defaultModel: value,
      resolvedProvider: catalog.provider(providerId),
      credentialPanelOf: catalog.credentialPanelState,
      disabled: disabled,
      surface: surface,
      showDeprecatedWarnIcon: showDeprecatedWarnIcon,
      showModelMeta: showModelMeta,
      isModelCompatible: currentProvider != null && currentModel != null
          ? modelPredicate?.call(currentProvider, currentModel) ?? true
          : true,
      language: catalog.language,
    );
  }

  @override
  Widget build(BuildContext context) => trigger;
}

/// The agent node's ModelBar (nodes/agent/components/model-bar.tsx): a disabled small ModelSelector on the workflow
/// surface without the deprecated badge, looked up in every model type's list, with an error StatusDot at the top
/// right (`-top-0.5 -right-0.5`) when no model is selected or the model is not installed.
class ModelBar extends StatelessWidget {
  const ModelBar({super.key, this.value, this.catalog = ModelCatalog.empty});

  /// `{provider, model}`; null for a required model parameter that is not set.
  final DefaultModel? value;
  final ModelCatalog catalog;

  static const height = ModelSelectorTrigger.height;
  static const notSelected = 'Model not selected';
  static const notInstalled = 'This model is not installed';

  @override
  Widget build(BuildContext context) {
    final v = value;
    final models = v == null ? const <ProviderWithModels>[] : catalog.allModelList;
    final installed =
        v != null && models.any((p) => p.provider == v.provider && p.models.any((m) => m.model == v.model));
    final warn = v == null ? notSelected : (installed ? null : notInstalled);
    return Semantics(
      label: warn,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ModelChip(
            value: v,
            models: models,
            catalog: catalog,
            surface: ModelSelectorSurface.workflow,
            showDeprecatedWarnIcon: false,
          ),
          if (warn != null)
            const Positioned(top: -2, right: -2, child: DifyStatusDot(status: DifyStatusDotStatus.error)),
        ],
      ),
    );
  }
}
