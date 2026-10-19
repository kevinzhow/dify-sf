/// ModelSelector (header/account-setting/model-provider-page/model-selector/index.tsx, model-selector-trigger.tsx,
/// popup.tsx, popup-item.tsx, popup-layout.tsx, popup-empty-state.tsx): the model trigger and the model list popup.
/// The provider credential popover reuses Model Provider settings. Marketplace, AI-credit sections and model
/// preview cards are outside this self-hosted selector.
library;

import 'dart:async';

import 'package:flutter/material.dart' show Material, MaterialType;
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../../../../cards/model_chip.dart';
import '../../../../design/css_metrics.dart';
import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/model_catalog.dart';
import '../../../../settings/model_provider/model_provider_env.dart';
import '../../../../settings/model_provider/provider_added_card.dart' show DropdownContent;
import 'group_host.dart';
import 'model_search.dart';

export 'model_search.dart' show ModelPredicate;

String _c(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

/// The trigger's accessible name (`plugin.detailPanel.configureModel`).
String get configureModelLabel => DifyI18n.tr('plugin', 'detailPanel.configureModel');

/// ModelSelector size (model-selector-trigger `size`): `small` is the cards' `h-6`, `medium` the panels' `h-8`.
enum ModelSelectorSize { small, medium }

/// The trigger's shape: on its own, or the left half of the model parameter modal's split trigger.
enum ModelSelectorShape { standalone, split }

/// What picking a model reports (Dify's `ModelSelectorValue`): the provider, the model and the provider's plugin.
typedef ModelSelectorValue = ({String provider, String model});

/// `getModelProviderPluginId`: `org/name` of a provider id, `langgenius/<provider>` for a bare one.
String modelProviderPluginId(String provider) {
  final parts = provider.split('/').where((p) => p.isNotEmpty).toList();
  if (parts.length >= 2) return '${parts[0]}/${parts[1]}';
  return provider.isEmpty ? '' : 'langgenius/$provider';
}

/// ModelSelector (standalone shape): the trigger for [value] among [models], opening the model list popup (search,
/// providers, models) below it; picking one reports it with [onChange] and closes. [scopeFeatures] keeps the models
/// having those features; [modelPredicate] hides incompatible ones (they can be revealed);
/// [modelSuggestionPredicate] marks recommended ones. [onHide] runs when the popup asks to close.
class ModelSelector extends StatelessWidget {
  const ModelSelector({
    super.key,
    required this.value,
    required this.models,
    this.onChange,
    this.disabled = false,
    this.size = ModelSelectorSize.medium,
    this.surface = ModelSelectorSurface.normal,
    this.showDeprecatedWarnIcon = true,
    this.showModelMeta = true,
    this.scopeFeatures = const [],
    this.modelPredicate,
    this.onHide,
    this.modelSuggestionPredicate,
    this.onConfigureEmptyState,
    this.hideProviderSettingsFooter = false,
  });

  final DefaultModel? value;
  final List<ProviderWithModels> models;
  final ValueChanged<({String provider, String model})>? onChange;
  final bool disabled, showDeprecatedWarnIcon, showModelMeta;
  final ModelSelectorSize size;
  final ModelSelectorSurface surface;
  final List<String> scopeFeatures;
  final bool Function(ProviderWithModels provider, ModelItem model)? modelPredicate;
  final VoidCallback? onHide;
  final bool Function(ProviderWithModels provider, ModelItem model)? modelSuggestionPredicate;

  /// The empty state's "Configure" (default: the services' model provider settings).
  final VoidCallback? onConfigureEmptyState;
  final bool hideProviderSettingsFooter;

  @override
  Widget build(BuildContext context) => ModelSelectorRoot(
    value: value,
    models: models,
    onChange: onChange,
    disabled: disabled,
    size: size,
    surface: surface,
    shape: ModelSelectorShape.standalone,
    showDeprecatedWarnIcon: showDeprecatedWarnIcon,
    showModelMeta: showModelMeta,
    scopeFeatures: scopeFeatures,
    modelPredicate: modelPredicate,
    modelSuggestionPredicate: modelSuggestionPredicate,
    onHide: onHide,
    onConfigureEmptyState: onConfigureEmptyState,
    hideProviderSettingsFooter: hideProviderSettingsFooter,
  );
}

/// SplitModelSelector: the medium selector as the left half of a split trigger (no chevron, right corners square).
class SplitModelSelector extends StatelessWidget {
  const SplitModelSelector({
    super.key,
    required this.value,
    required this.models,
    this.onChange,
    this.disabled = false,
    this.surface = ModelSelectorSurface.normal,
    this.showModelMeta = true,
    this.modelPredicate,
    this.modelSuggestionPredicate,
    this.popupWidth,
  });

  final DefaultModel? value;
  final List<ProviderWithModels> models;
  final ValueChanged<({String provider, String model})>? onChange;
  final bool disabled, showModelMeta;
  final ModelSelectorSurface surface;
  final ModelPredicate? modelPredicate, modelSuggestionPredicate;

  /// `modelSelectorPopupClassName` widths; the anchor's width by default.
  final double? popupWidth;

  @override
  Widget build(BuildContext context) => ModelSelectorRoot(
    value: value,
    models: models,
    onChange: onChange,
    disabled: disabled,
    surface: surface,
    shape: ModelSelectorShape.split,
    showModelMeta: showModelMeta,
    modelPredicate: modelPredicate,
    modelSuggestionPredicate: modelSuggestionPredicate,
    popupWidth: popupWidth,
  );
}

/// ModelSelectorRoot: the trigger and its popup; the search text is cleared whenever the popup closes.
class ModelSelectorRoot extends StatefulWidget {
  const ModelSelectorRoot({
    super.key,
    required this.value,
    required this.models,
    this.onChange,
    this.disabled = false,
    this.size = ModelSelectorSize.medium,
    this.surface = ModelSelectorSurface.normal,
    this.shape = ModelSelectorShape.standalone,
    this.showDeprecatedWarnIcon = true,
    this.showModelMeta = true,
    this.scopeFeatures = const [],
    this.modelPredicate,
    this.modelSuggestionPredicate,
    this.onHide,
    this.onConfigureEmptyState,
    this.hideProviderSettingsFooter = false,
    this.popupWidth,
  });

  final DefaultModel? value;
  final List<ProviderWithModels> models;
  final ValueChanged<({String provider, String model})>? onChange;
  final bool disabled, showDeprecatedWarnIcon, showModelMeta, hideProviderSettingsFooter;
  final ModelSelectorSize size;
  final ModelSelectorSurface surface;
  final ModelSelectorShape shape;
  final List<String> scopeFeatures;
  final ModelPredicate? modelPredicate, modelSuggestionPredicate;
  final VoidCallback? onHide, onConfigureEmptyState;
  final double? popupWidth;

  @override
  State<ModelSelectorRoot> createState() => _ModelSelectorRootState();
}

class _ModelSelectorRootState extends State<ModelSelectorRoot> {
  bool _open = false;
  String _input = '';
  double _anchorWidth = 0;

  void _setOpen(bool open) {
    if (widget.disabled && open) return;
    if (open && !_open) LlmGroupScope.of(context).refreshModels?.call();
    setState(() {
      _open = open;
      if (!open) _input = '';
    });
  }

  void _hide() {
    _setOpen(false);
    widget.onHide?.call();
  }

  @override
  void didUpdateWidget(ModelSelectorRoot old) {
    super.didUpdateWidget(old);
    if (widget.disabled && _open) _open = false;
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final services = LlmGroupScope.of(context);
    final (:currentProvider, :currentModel) = getCurrentProviderAndModel(w.models, w.value);
    final settings = services.openModelProviderSettings;
    final credentials = services.modelProviderEnv ?? ModelProviderScope.maybeOf(context);
    return DifyFloating(
      open: _open,
      onOpenChange: _setOpen,
      placement: DifyPlacement.bottomStart,
      sideOffset: 8,
      constrainHeight: true,
      builder: (context, controller) => LayoutBuilder(
        builder: (context, c) {
          if (c.maxWidth.isFinite) _anchorWidth = c.maxWidth;
          final trigger = ModelSelectorButton(
            currentProvider: currentProvider,
            currentModel: currentModel,
            defaultModel: w.value,
            catalog: services.models,
            disabled: w.disabled,
            size: w.size,
            surface: w.surface,
            shape: w.shape,
            open: _open,
            showDeprecatedWarnIcon: w.showDeprecatedWarnIcon,
            showModelMeta: w.showModelMeta,
            isModelCompatible: currentProvider != null && currentModel != null
                ? w.modelPredicate?.call(currentProvider, currentModel) ?? true
                : true,
            onPressed: controller.toggle,
          );
          return trigger;
        },
      ),
      popupBuilder: (context) {
        final popup = ModelSelectorPopupSurface(
          width: w.popupWidth ?? _anchorWidth,
          child: ModelSelectorPopup(
            defaultModel: w.value,
            inputValue: _input,
            modelList: w.models,
            catalog: services.models,
            scopeFeatures: w.scopeFeatures,
            modelPredicate: w.modelPredicate,
            modelSuggestionPredicate: w.modelSuggestionPredicate,
            onInputValueChange: (v) => setState(() => _input = v),
            onOpenProviderSettings: settings == null || w.hideProviderSettingsFooter
                ? null
                : () {
                    _hide();
                    settings();
                  },
            onConfigureEmptyState: () {
              _hide();
              (w.onConfigureEmptyState ?? settings)?.call();
            },
            onSelect: (provider, model) {
              _setOpen(false);
              w.onChange?.call((provider: provider, model: model.model));
            },
            onHide: _hide,
          ),
        );
        return credentials == null ? popup : ModelProviderScope(env: credentials, child: popup);
      },
    );
  }
}

/// PopoverContent of the selector: `flex max-h-[min(624px,var(--available-height))] w-(--anchor-width)
/// max-w-[min(28rem,var(--available-width))] flex-col rounded-xl border-[0.5px] bg-components-panel-bg shadow-lg`.
class ModelSelectorPopupSurface extends StatelessWidget {
  const ModelSelectorPopupSurface({super.key, required this.child, required this.width});
  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    role: SemanticsRole.dialog,
    label: configureModelLabel,
    explicitChildNodes: true,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: 624, maxWidth: 448, minWidth: width.clamp(0, 448)),
      child: SizedBox(
        width: width <= 0 ? 320 : width.clamp(0, 448),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: DifyColors.componentsPanelBg,
            border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
            borderRadius: BorderRadius.circular(DifyRadius.xl),
            boxShadow: DifyShadows.lg,
          ),
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    ),
  );
}

// ---- trigger -----------------------------------------------------------------------------------------------------

/// ModelSelectorTrigger in both sizes and shapes: the model's icon and name (with mode and feature badges while
/// active), the struck-through id of a model no longer listed, or "Configure model"; a warning badge for an unusable
/// status; the chevron for a standalone trigger that can open.
class ModelSelectorButton extends StatelessWidget {
  const ModelSelectorButton({
    super.key,
    this.currentProvider,
    this.currentModel,
    this.defaultModel,
    this.catalog = ModelCatalog.empty,
    this.disabled = false,
    this.size = ModelSelectorSize.medium,
    this.surface = ModelSelectorSurface.normal,
    this.shape = ModelSelectorShape.standalone,
    this.open = false,
    this.showDeprecatedWarnIcon = true,
    this.showModelMeta = true,
    this.isModelCompatible = true,
    this.onPressed,
  });

  final ProviderWithModels? currentProvider;
  final ModelItem? currentModel;
  final DefaultModel? defaultModel;
  final ModelCatalog catalog;
  final bool disabled, open, showDeprecatedWarnIcon, showModelMeta, isModelCompatible;
  final ModelSelectorSize size;
  final ModelSelectorSurface surface;

  /// `data-shape`.
  final ModelSelectorShape shape;
  final VoidCallback? onPressed;

  bool get isSelected => currentProvider != null && currentModel != null;
  bool get isDeprecated => !isSelected && defaultModel != null;
  bool get isEmpty => !isSelected && defaultModel == null;

  @override
  Widget build(BuildContext context) {
    final providerId = isSelected ? currentProvider!.provider : defaultModel?.provider;
    final resolved = catalog.provider(providerId);
    final s = deriveModelStatus(
      isSelected ? currentModel!.model : defaultModel?.model,
      isSelected ? currentProvider!.provider : defaultModel?.provider,
      resolved,
      currentModel,
      catalog.credentialPanelState(resolved),
    );
    final isActive = s == DerivedModelStatus.active;
    final statusLabel = isModelCompatible && s.badge != null ? s.badge! : DerivedModelStatus.incompatibleLabel;
    final tooltipLabel = isModelCompatible && s.tooltip != null ? s.tooltip! : DerivedModelStatus.incompatibleTip;
    final meta = showModelMeta && isActive && isModelCompatible;
    final triggerTooltip = isDeprecated && showDeprecatedWarnIcon
        ? tooltipLabel
        : isSelected && ((!isActive && s.badge != null) || !isModelCompatible)
        ? tooltipLabel
        : null;
    final medium = size == ModelSelectorSize.medium;

    final Widget icon = isEmpty
        ? SizedBox.square(
            dimension: medium ? 24 : 20,
            child: Center(
              child: Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: DifyColors.backgroundDefaultSubtle,
                  borderRadius: BorderRadius.circular(DifyRadius.md),
                  border: Border.all(color: DifyColors.componentsPanelBorderSubtle, width: Css.hairline),
                ),
                child: RemixIcon('brain-2-line', size: 14, color: DifyColors.textQuaternary),
              ),
            ),
          )
        : ModelIcon(
            provider: isSelected ? currentProvider!.provider : resolved?.provider,
            iconSmall: isSelected ? currentProvider!.iconSmall : resolved?.iconSmall,
            iconSmallDark: isSelected ? currentProvider!.iconSmallDark : resolved?.iconSmallDark,
            modelName: isSelected ? currentModel!.model : defaultModel?.model,
            language: catalog.language,
          );
    final Widget name = isSelected
        ? ModelName(
            modelItem: currentModel,
            language: catalog.language,
            lineThrough: currentModel!.deprecated,
            showMode: meta,
            showFeatures: meta,
          )
        : isDeprecated
        ? ModelText(defaultModel!.model, lineThrough: true)
        : Text(
            configureModelLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, height: 20 / 13, color: DifyColors.componentsInputTextPlaceholder),
          );
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
        SizedBox(width: medium ? 2 : 1),
        Expanded(
          // As tall as its content (the 22 px badge and `py-0.75` make 28 px in the 24 px row), centred: it may
          // stand out of the row, as the flex item does.
          child: OverflowBox(
            minHeight: 0,
            maxHeight: double.infinity,
            child: Padding(
              padding: medium
                  ? const EdgeInsets.symmetric(horizontal: 4, vertical: 3)
                  : const EdgeInsets.symmetric(horizontal: 2),
              child: TruncatedRow(gap: 4, fillLead: true, lead: name, trail: badge),
            ),
          ),
        ),
      ],
    );
    if (surface == ModelSelectorSurface.workflow && isDeprecated) content = Opacity(opacity: 0.5, child: content);
    final showChevron = !disabled && shape != ModelSelectorShape.split && (isActive || isEmpty);
    final split = shape == ModelSelectorShape.split;
    final radius = medium ? DifyRadius.lg : DifyRadius.md;

    Color background(bool hovered) {
      if (surface == ModelSelectorSurface.workflow) return DifyColors.workflowBlockParmaBg;
      final usable = s == DerivedModelStatus.active || s == DerivedModelStatus.empty;
      if (disabled) return usable ? DifyColors.componentsInputBgNormal : DifyColors.componentsInputBgDisabled;
      if (!usable) return DifyColors.componentsInputBgDisabled;
      return hovered || open ? DifyColors.stateBaseHoverAlt : DifyColors.componentsInputBgNormal;
    }

    Widget trigger = DifyPressable(
      semanticLabel: configureModelLabel,
      disabled: disabled,
      onPressed: onPressed,
      builder: (context, hovered, focused) => Semantics(
        expanded: open,
        child: Container(
          height: medium ? 32 : 24,
          padding: EdgeInsets.all(medium ? 4 : 2),
          decoration: BoxDecoration(
            color: background(hovered),
            borderRadius: split
                ? BorderRadius.horizontal(left: Radius.circular(radius))
                : BorderRadius.circular(radius),
            border: focused ? Border.all(color: DifyColors.stateAccentSolid, width: 2) : null,
          ),
          child: Row(
            children: [
              Expanded(child: content),
              if (showChevron) ...[
                const SizedBox(width: 2),
                RemixIcon(
                  'arrow-down-s-line',
                  size: 16,
                  color: hovered || open ? DifyColors.textSecondary : DifyColors.textQuaternary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (triggerTooltip != null && !disabled) {
      trigger = DifyTooltip(content: Text(triggerTooltip), child: trigger);
    }
    return trigger;
  }
}

// ---- popup -------------------------------------------------------------------------------------------------------

/// Popup (popup.tsx): the search header, the scrollable list of providers and their models (with the empty state,
/// the "no model found" status, the compatible-only notice and the reveal of incompatible models) and the "Model
/// Provider Settings" footer.
class ModelSelectorPopup extends StatefulWidget {
  const ModelSelectorPopup({
    super.key,
    this.defaultModel,
    required this.inputValue,
    required this.modelList,
    this.catalog = ModelCatalog.empty,
    this.scopeFeatures = const [],
    this.modelPredicate,
    this.modelSuggestionPredicate,
    this.onOpenProviderSettings,
    this.onConfigureEmptyState,
    required this.onInputValueChange,
    required this.onSelect,
    required this.onHide,
  });

  final DefaultModel? defaultModel;
  final String inputValue;
  final List<ProviderWithModels> modelList;
  final ModelCatalog catalog;
  final List<String> scopeFeatures;
  final ModelPredicate? modelPredicate, modelSuggestionPredicate;
  final VoidCallback? onOpenProviderSettings, onConfigureEmptyState;
  final ValueChanged<String> onInputValueChange;
  final void Function(String provider, ModelItem model) onSelect;
  final VoidCallback onHide;

  @override
  State<ModelSelectorPopup> createState() => _ModelSelectorPopupState();
}

class _ModelSelectorPopupState extends State<ModelSelectorPopup> {
  bool _showIncompatible = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final installed = w.modelList;
    final filtered = filterModelSelectorModels(
      installed: installed,
      inputValue: w.inputValue,
      language: w.catalog.language,
      defaultModel: w.defaultModel,
      scopeFeatures: w.scopeFeatures,
      modelPredicate: _showIncompatible ? null : w.modelPredicate,
    );
    final status = filtered.isEmpty && installed.isNotEmpty
        ? _c('modelProvider.selector.noModelFoundForSearch', {'query': w.inputValue})
        : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: ModelSearchInput(value: w.inputValue, onChanged: w.onInputValueChange),
        ),
        Flexible(
          child: Semantics(
            container: true,
            label: _c('modelProvider.models'),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final p in filtered)
                          ModelSelectorPopupItem(
                            key: ValueKey(p.provider),
                            defaultModel: w.defaultModel,
                            model: p,
                            catalog: w.catalog,
                            modelPredicate: w.modelPredicate,
                            modelSuggestionPredicate: w.modelSuggestionPredicate,
                            onSelect: w.onSelect,
                            onHide: w.onHide,
                          ),
                      ],
                    ),
                  ),
                  if (filtered.isEmpty && installed.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: ModelSelectorEmptyState(onConfigure: w.onConfigureEmptyState ?? w.onHide),
                    ),
                  if (status != null)
                    Semantics(
                      liveRegion: true,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        child: Text(
                          status,
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, height: 18 / 12, color: DifyColors.textTertiary),
                        ),
                      ),
                    ),
                  if (w.scopeFeatures.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: DifyText(
                        _c('modelProvider.selector.onlyCompatibleModelsShown'),
                        DifyType.systemXsRegular,
                        color: DifyColors.textTertiary,
                        maxLines: null,
                      ),
                    ),
                  if (w.modelPredicate != null)
                    _GhostRow(
                      height: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      radius: 0,
                      label: _c(
                        _showIncompatible
                            ? 'modelProvider.selector.hideIncompatibleModels'
                            : 'modelProvider.selector.showIncompatibleModels',
                      ),
                      onPressed: () => setState(() => _showIncompatible = !_showIncompatible),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (w.onOpenProviderSettings != null)
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: DifyColors.dividerSubtle, width: Css.hairline),
              ),
            ),
            child: _GhostRow(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              radius: DifyRadius.lg,
              leading: RemixIcon('equalizer-2-line', size: 16, color: DifyColors.textTertiary),
              label: _c('modelProvider.selector.modelProviderSettings'),
              style: DifyType.systemXsMedium,
              onPressed: w.onOpenProviderSettings!,
            ),
          ),
      ],
    );
  }
}

/// A full-width ghost button with a left-aligned label (`text-text-tertiary`).
class _GhostRow extends StatelessWidget {
  const _GhostRow({
    required this.label,
    required this.onPressed,
    required this.height,
    required this.padding,
    required this.radius,
    this.leading,
    this.style = DifyType.systemXsRegular,
  });
  final String label;
  final VoidCallback onPressed;
  final double height, radius;
  final EdgeInsets padding;
  final Widget? leading;
  final DifyTextStyle style;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: label,
    onPressed: onPressed,
    builder: (context, hovered, focused) => Container(
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        color: hovered ? DifyColors.componentsButtonGhostBgHover : null,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Row(
        spacing: 8,
        children: [
          ?leading,
          Flexible(child: DifyText(label, style, color: DifyColors.textTertiary)),
        ],
      ),
    ),
  );
}

/// DifySearchInput: an `h-8` input with the search icon and, once there is text, a clear button that keeps the focus.
class ModelSearchInput extends StatefulWidget {
  const ModelSearchInput({super.key, required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<ModelSearchInput> createState() => _ModelSearchInputState();
}

class _ModelSearchInputState extends State<ModelSearchInput> {
  final _focus = FocusNode(debugLabel: 'model search');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = DifyI18n.tr('dataset-settings', 'form.searchModel');
    return DifyInput(
      value: widget.value,
      onChanged: widget.onChanged,
      placeholder: label,
      semanticLabel: label,
      focusNode: _focus,
      height: 32,
      leading: Padding(
        padding: EdgeInsets.only(left: 8, right: 4),
        child: RemixIcon('search-line', size: 16, color: DifyColors.componentsInputTextPlaceholder),
      ),
      trailing: widget.value.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(right: 6, left: 4),
              child: DifyPressable(
                semanticLabel: _c('operation.clear'),
                onPressed: () {
                  widget.onChanged('');
                  _focus.requestFocus();
                },
                builder: (context, hovered, focused) => RemixIcon(
                  'close-circle-fill',
                  size: 16,
                  color: hovered ? DifyColors.textTertiary : DifyColors.textQuaternary,
                ),
              ),
            ),
    );
  }
}

/// ModelSelectorEmptyState: the brain tile, "No Model Provider configured", its description and "Configure".
class ModelSelectorEmptyState extends StatelessWidget {
  const ModelSelectorEmptyState({super.key, required this.onConfigure});
  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 8),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(10),
      gradient: LinearGradient(colors: [DifyColors.stateBaseHover, DifyColors.backgroundGradientMaskTransparent]),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
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
          child: RemixIcon('brain-2-line', size: 20, color: DifyColors.textTertiary),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            DifyText(
              _c('modelProvider.selector.noProviderConfigured'),
              DifyType.systemSmMedium,
              color: DifyColors.textSecondary,
              maxLines: null,
            ),
            DifyText(
              _c('modelProvider.selector.noProviderConfiguredDesc'),
              DifyType.systemXsRegular,
              color: DifyColors.textTertiary,
              maxLines: null,
            ),
          ],
        ),
        SizedBox(
          width: 108,
          child: DifyButton(
            variant: DifyButtonVariant.primary,
            semanticLabel: _c('modelProvider.selector.configure'),
            onPressed: onConfigure,
            trailing: const RemixIcon('arrow-right-line', size: 16),
            child: Text(_c('modelProvider.selector.configure')),
          ),
        ),
      ],
    ),
  );
}

/// PopupItem: one provider (nothing when it is not installed): its collapsible header with the credential status,
/// then its models (selectable when active; the selected one checked).
class ModelSelectorPopupItem extends StatefulWidget {
  const ModelSelectorPopupItem({
    super.key,
    this.defaultModel,
    required this.model,
    required this.catalog,
    this.modelPredicate,
    this.modelSuggestionPredicate,
    required this.onSelect,
    this.onHide,
  });

  final DefaultModel? defaultModel;
  final ProviderWithModels model;
  final ModelCatalog catalog;
  final ModelPredicate? modelPredicate, modelSuggestionPredicate;
  final void Function(String provider, ModelItem model) onSelect;
  final VoidCallback? onHide;

  @override
  State<ModelSelectorPopupItem> createState() => _ModelSelectorPopupItemState();
}

class _ModelSelectorPopupItemState extends State<ModelSelectorPopupItem> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final current = w.catalog.provider(w.model.provider);
    if (current == null) return const SizedBox.shrink();
    final language = w.catalog.language;
    final label = renderI18nObject(w.model.label, language);
    final state = w.catalog.credentialPanelState(current);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: 22),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            color: DifyColors.componentsPanelBg,
            child: LayoutBuilder(
              builder: (context, constraints) => Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: DifyPressable(
                      semanticLabel: label,
                      onPressed: () => setState(() => _open = !_open),
                      builder: (context, hovered, focused) => Semantics(
                        expanded: _open,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 16 / 12,
                                  fontWeight: FontWeight.w500,
                                  color: DifyColors.textTertiary,
                                ),
                              ),
                            ),
                            AnimatedRotation(
                              turns: _open ? 0 : -0.25,
                              duration: difyTransitionDuration,
                              child: DifyIcon(
                                'vender/solid/general/arrow-down-round-fill',
                                size: 16,
                                color: DifyColors.textQuaternary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: constraints.maxWidth / 2),
                    child: _ProviderCredentialDropdown(provider: current.provider, state: state, onHide: w.onHide),
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final m in w.model.models)
                    ModelSelectorModelRow(
                      key: ValueKey(m.model),
                      provider: w.model,
                      model: m,
                      language: language,
                      selected: w.defaultModel?.model == m.model && w.defaultModel?.provider == current.provider,
                      compatible: w.modelPredicate?.call(w.model, m) ?? true,
                      suggested: w.modelSuggestionPredicate?.call(w.model, m) ?? false,
                      onSelect: () => w.onSelect(w.model.provider, m),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// PopupItem's credential Popover: lazy-load the provider's full definition before opening, then use the same
/// DropdownContent as the Model Provider settings. Adding/editing closes both popovers; switching keeps them open.
class _ProviderCredentialDropdown extends StatefulWidget {
  const _ProviderCredentialDropdown({required this.provider, required this.state, this.onHide});
  final String provider;
  final CredentialPanelState state;
  final VoidCallback? onHide;

  @override
  State<_ProviderCredentialDropdown> createState() => _ProviderCredentialDropdownState();
}

class _ProviderCredentialDropdownState extends State<_ProviderCredentialDropdown> {
  bool _open = false;
  bool _loading = false;

  Future<void> _change(ModelProviderEnv env, bool open) async {
    if (!open) {
      setState(() => _open = false);
      return;
    }
    if (_loading) return;
    _loading = true;
    final detail = await env.models.loadProviderDetail(widget.provider);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _open = detail != null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final env = ModelProviderScope.maybeOf(context);
    final canOpen = env != null && (env.canUseCredential || env.canCreateCredential || env.canManageCredential);
    return DifyFloating(
      open: _open,
      onOpenChange: (open) {
        if (canOpen) unawaited(_change(env, open));
      },
      placement: DifyPlacement.bottomEnd,
      sideOffset: 8,
      builder: (context, controller) => canOpen
          ? DifyButton(
              semanticLabel: widget.state.credentialName ?? _c('modelProvider.selector.configureRequired'),
              variant: DifyButtonVariant.ghost,
              size: DifyButtonSize.small,
              paddingX: 6,
              onPressed: controller.toggle,
              child: _CredentialStatus(state: widget.state, showArrow: true),
            )
          : _CredentialStatus(state: widget.state),
      popupBuilder: (context) => ModelProviderScope(
        env: env!,
        child: ListenableBuilder(
          listenable: env.models,
          builder: (context, _) {
            final provider = env.models.detailOf(widget.provider);
            final summary = env.models.catalog.provider(widget.provider);
            return DifyPopoverSurface(
              child: provider == null
                  ? const SizedBox.shrink()
                  : DropdownContent(
                      provider: provider,
                      state: env.models.catalog.credentialPanelState(summary),
                      onClose: () {
                        setState(() => _open = false);
                        widget.onHide?.call();
                      },
                    ),
            );
          },
        ),
      ),
    );
  }
}

/// The provider header's credential label (the dropdown trigger's content, without the dropdown): AI credits or
/// "Credits exhausted" for a provider on credits, else the credential's name with its status dot, or "Configure
/// required".
class _CredentialStatus extends StatelessWidget {
  const _CredentialStatus({required this.state, this.showArrow = false});
  final bool showArrow;
  final CredentialPanelState state;

  @override
  Widget build(BuildContext context) {
    final usingCredits = state.priority == UsagePriority.credits;
    final apiActive = state.variant == CardVariant.apiActive || state.variant == CardVariant.apiFallback;
    final name = state.credentialName;
    final (Widget lead, String text, Color color) = usingCredits
        ? !state.isCreditsExhausted
              ? (
                  const DifyIcon('vender/line/financeAndECommerce/credits-coin', size: 12),
                  _c('modelProvider.selector.aiCredits'),
                  DifyColors.textTertiary,
                )
              : (
                  RemixIcon('alert-fill', size: 12, color: DifyColors.textWarningSecondary),
                  _c('modelProvider.selector.creditsExhausted'),
                  DifyColors.textWarning,
                )
        : name != null && name.isNotEmpty
        ? (
            DifyStatusDot(
              size: DifyStatusDotSize.small,
              status: apiActive ? DifyStatusDotStatus.success : DifyStatusDotStatus.error,
            ),
            name,
            DifyColors.textTertiary,
          )
        : (
            const DifyStatusDot(size: DifyStatusDotSize.small, status: DifyStatusDotStatus.disabled),
            _c('modelProvider.selector.configureRequired'),
            DifyColors.textTertiary,
          );
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        lead,
        const SizedBox(width: 4),
        Flexible(child: DifyText(text, DifyType.systemXsMedium, color: color)),
        if (showArrow)
          Transform.translate(
            offset: const Offset(0, 1),
            child: RemixIcon('arrow-down-s-line', size: 14, color: DifyColors.textTertiary),
          ),
      ],
    );
    if (showArrow) return content;
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: content,
    );
  }
}

/// A model row: `mx-1 h-8 rounded-lg px-3 py-1.5`, the icon, the name (`system-sm-medium text-text-secondary`;
/// quaternary when incompatible, faded when not selectable, struck through when deprecated), the recommendation
/// mark, and the check on the selected one. Only active models can be picked.
class ModelSelectorModelRow extends StatelessWidget {
  const ModelSelectorModelRow({
    super.key,
    required this.provider,
    required this.model,
    required this.onSelect,
    this.language = 'en_US',
    this.selected = false,
    this.compatible = true,
    this.suggested = false,
  });

  final ProviderWithModels provider;
  final ModelItem model;
  final VoidCallback onSelect;
  final String language;
  final bool selected, compatible, suggested;

  bool get selectable => model.status == ModelStatusEnum.active;

  @override
  Widget build(BuildContext context) {
    final label = renderI18nObject(model.label, language);
    final tip = _c('modelProvider.selector.suggestionTip');
    return DifyPressable(
      semanticLabel: suggested ? '$label $tip' : label,
      disabled: !selectable,
      onPressed: onSelect,
      builder: (context, hovered, focused) => Semantics(
        selected: selected,
        child: Container(
          height: 32,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: hovered ? (selectable ? DifyColors.stateBaseHover : DifyColors.stateBaseHoverAlt) : null,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
          ),
          child: Row(
            spacing: 4,
            children: [
              Expanded(
                child: Row(
                  spacing: 8,
                  children: [
                    ModelIcon(
                      provider: provider.provider,
                      iconSmall: provider.iconSmall,
                      iconSmallDark: provider.iconSmallDark,
                      modelName: model.model,
                      language: language,
                    ),
                    Flexible(
                      child: Opacity(
                        opacity: selectable ? 1 : 0.6,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 2,
                          children: [
                            Flexible(
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: difyStyle(
                                  DifyType.systemSmMedium,
                                  compatible ? DifyColors.textSecondary : DifyColors.textQuaternary,
                                ).copyWith(decoration: model.deprecated ? TextDecoration.lineThrough : null),
                              ),
                            ),
                            if (suggested)
                              DifyTooltip(
                                content: Text(tip),
                                child: RemixIcon(
                                  'shield-star-line',
                                  size: 14,
                                  color: DifyColors.textAccentSecondary,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (selected) DifyIcon('vender/line/general/check', size: 16, color: DifyColors.textAccent),
            ],
          ),
        ),
      ),
    );
  }
}
