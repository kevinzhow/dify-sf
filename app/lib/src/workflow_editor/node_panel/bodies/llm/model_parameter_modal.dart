/// The model field of the model nodes (header/account-setting/model-provider-page/model-parameter-modal/**,
/// model-selector/**): the split trigger (model selector + settings button), the model list popup and the "Model
/// Settings" popover with the model's parameters.
library;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../../../../cards/model_chip.dart';
import '../../../../design/css_metrics.dart';
import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/model_catalog.dart';
import '../../../panel_fields/node_config.dart' show Json;
import '../../../panel_fields/var_picker_model.dart';
import '../../../prompt_editor/prompt_editor_types.dart' show WorkflowNodeInfo;
import 'group_host.dart';
import 'model_selector.dart';
import 'parameter_item.dart';

export 'model_selector.dart'
    show
        ModelPredicate,
        ModelSelector,
        ModelSelectorRoot,
        ModelSelectorShape,
        ModelSelectorSize,
        SplitModelSelector,
        modelProviderPluginId;
export 'parameter_item.dart' show ParameterItem, PresetsParameter, getSupportedPresetConfig;

/// What choosing a model reports (Dify's `setModel` argument): the provider and model, the model's mode
/// (`model_properties.mode`) and features.
typedef ModelChoice = ({String provider, String modelId, String? mode, List<String> features});

/// A model parameter rule (declarations.ts ModelParameterRule).
@immutable
class ModelParameterRule {
  const ModelParameterRule({
    required this.name,
    this.label = const {},
    this.type = 'string',
    this.help,
    this.required = false,
    this.defaultValue,
    this.min,
    this.max,
    this.precision,
    this.options = const [],
    this.allowCustomValue = false,
    this.optionsSource,
    this.tagPlaceholder,
  });

  factory ModelParameterRule.fromJson(Json j) => ModelParameterRule(
    name: '${j['name'] ?? ''}',
    label: _i18n(j['label']) ?? const {},
    type: '${j['type'] ?? 'string'}',
    help: _i18n(j['help']),
    required: j['required'] == true,
    defaultValue: j['default'],
    min: j['min'] is num ? j['min'] as num : null,
    max: j['max'] is num ? j['max'] as num : null,
    precision: j['precision'] is num ? (j['precision'] as num).toInt() : null,
    options: [for (final o in (j['options'] is List ? j['options'] as List : const [])) '$o'],
    allowCustomValue: j['allow_custom_value'] == true,
    optionsSource: j['options_source'] as String?,
    tagPlaceholder: _i18n(j['tagPlaceholder']),
  );

  static I18nText? _i18n(Object? v) => v is Map ? {for (final e in v.entries) '${e.key}': e.value?.toString()} : null;

  final String name;
  final I18nText label;

  /// `int`, `float`, `boolean`, `string`, `text`, `tag`.
  final String type;
  final I18nText? help;
  final bool required;
  final Object? defaultValue;
  final num? min, max;
  final int? precision;
  final List<String> options;
  final bool allowCustomValue;
  final String? optionsSource;
  final I18nText? tagPlaceholder;
}

/// `STOP_PARAMETER_RULE` (config/index.ts): advanced mode adds it after the model's rules.
const stopParameterRule = ModelParameterRule(
  name: 'stop',
  label: {'en_US': 'Stop sequences', 'zh_Hans': '停止序列'},
  type: 'tag',
  help: {
    'en_US':
        'Up to four sequences where the API will stop generating further tokens. The returned text will not contain '
        'the stop sequence.',
    'zh_Hans': '最多四个序列，API 将停止生成更多的 token。返回的文本将不包含停止序列。',
  },
  defaultValue: <String>[],
  tagPlaceholder: {'en_US': 'Enter sequence and press Tab', 'zh_Hans': '输入序列并按 Tab 键'},
);

/// ModelParameterModal: [provider] / [modelId] with their [completionParams]. The trigger is the split model
/// selector (over [modelList], by default the services' active text generation models) and the "Model Settings"
/// button (enabled for an active, compatible selected model); a custom [trigger] opens the popover instead, with the
/// model selector at its top. The settings popover lists the model's parameter rules (from [LlmGroupScope]'s
/// `parameterRules`, plus "Stop sequences" in [isAdvancedMode]) with "Load Presets" for OpenAI and Azure OpenAI.
/// [readonly] disables both, [modelSelectorReadonly] only the selector. String and text parameters take variables
/// ([nodesOutputVars], [availableNodes]) in a workflow. The "Debug as Multiple Models" footer shows only when
/// [hideDebugWithMultipleModel] is false (the workflow panels hide it).
class ModelParameterModal extends StatefulWidget {
  const ModelParameterModal({
    super.key,
    required this.provider,
    required this.modelId,
    required this.completionParams,
    required this.onModelChange,
    required this.onCompletionParamsChange,
    this.isAdvancedMode = true,
    this.isInWorkflow = true,
    this.readonly = false,
    this.modelSelectorReadonly = false,
    this.modelList,
    this.modelPredicate,
    this.nodesOutputVars = const [],
    this.availableNodes = const {},
    this.popupWidth = 387,
    this.showModelMeta = true,
    this.trigger,
    this.placement,
    this.modelSuggestionPredicate,
    this.modelSelectorPopupWidth,
    this.hideDebugWithMultipleModel = true,
    this.debugWithMultipleModel = false,
    this.onDebugWithMultipleModelChange,
  });

  final String provider;
  final String modelId;
  final Json completionParams;
  final ValueChanged<ModelChoice> onModelChange;
  final ValueChanged<Json> onCompletionParamsChange;
  final bool isAdvancedMode, isInWorkflow, readonly, modelSelectorReadonly, showModelMeta;
  final List<ProviderWithModels>? modelList;
  final bool Function(ProviderWithModels provider, ModelItem model)? modelPredicate;
  final List<VarGroup> nodesOutputVars;
  final Map<String, WorkflowNodeInfo> availableNodes;

  /// `popupClassName="w-[387px]!"`.
  final double popupWidth;

  /// A custom trigger (Dify's `trigger` element): the popover then also holds the model selector.
  final DifyTriggerBuilder? trigger;

  /// The popover's placement (default: left in a workflow, bottom-end with a custom trigger, else left-start).
  final DifyPlacement? placement;
  final bool Function(ProviderWithModels provider, ModelItem model)? modelSuggestionPredicate;
  final double? modelSelectorPopupWidth;
  final bool hideDebugWithMultipleModel, debugWithMultipleModel;
  final VoidCallback? onDebugWithMultipleModelChange;

  @override
  State<ModelParameterModal> createState() => _ModelParameterModalState();
}

class _ModelParameterModalState extends State<ModelParameterModal> {
  bool _open = false;
  String? _rulesKey;
  List<ModelParameterRule> _rules = const [];
  bool _loading = false;

  LlmGroupServices get _services => LlmGroupScope.of(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadRules();
  }

  @override
  void didUpdateWidget(ModelParameterModal old) {
    super.didUpdateWidget(old);
    if (widget.readonly && _open) _open = false;
    _loadRules();
  }

  /// `useModelParameterRules(provider, modelId)`: fetched once per model.
  void _loadRules() {
    final w = widget, fetch = _services.parameterRules;
    final key = '${w.provider}\u0000${w.modelId}';
    if (key == _rulesKey) return;
    _rulesKey = key;
    _rules = const [];
    if (fetch == null || w.provider.isEmpty || w.modelId.isEmpty) {
      _loading = false;
      return;
    }
    _loading = true;
    fetch(w.provider, w.modelId).then(
      (rules) {
        if (!mounted || _rulesKey != key) return;
        setState(() {
          _rules = [for (final r in rules) ModelParameterRule.fromJson(r)];
          _loading = false;
        });
      },
      onError: (Object _) {
        if (mounted && _rulesKey == key) setState(() => _loading = false);
      },
    );
  }

  void _setOpen(bool open) {
    if (widget.readonly && open) return;
    setState(() => _open = open);
  }

  List<ProviderWithModels> get _selectable => widget.modelList ?? _services.models.activeTextGenerationModelList;

  void _changeModel(({String provider, String model}) v) {
    final target = _selectable.where((p) => p.provider == v.provider).firstOrNull;
    final item = target?.models.where((m) => m.model == v.model).firstOrNull;
    final mode = item?.modelProperties['mode'];
    widget.onModelChange((
      provider: v.provider,
      modelId: v.model,
      mode: mode is String ? mode : null,
      features: [...?item?.features],
    ));
  }

  void _param(String key, Object? value) => widget.onCompletionParamsChange({...widget.completionParams, key: value});

  void _switch(String key, bool on, Object? assign) {
    if (!on) {
      widget.onCompletionParamsChange({...widget.completionParams}..remove(key));
    } else {
      widget.onCompletionParamsChange({...widget.completionParams, key: assign});
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final services = _services;
    final hasModel = w.provider.isNotEmpty && w.modelId.isNotEmpty;
    final value = hasModel ? (provider: w.provider, model: w.modelId) : null;
    final (:currentProvider, :currentModel) = getCurrentProviderAndModel(
      services.models.textGenerationModelList,
      value,
    );
    final canConfigure =
        !w.readonly &&
        hasModel &&
        currentProvider != null &&
        currentModel != null &&
        currentModel.status == ModelStatusEnum.active &&
        (w.modelPredicate?.call(currentProvider, currentModel) ?? true);
    final surface = w.isInWorkflow ? ModelSelectorSurface.workflow : ModelSelectorSurface.normal;
    return DifyFloating(
      open: _open,
      onOpenChange: _setOpen,
      placement:
          w.placement ??
          (w.isInWorkflow
              ? DifyPlacement.left
              : w.trigger != null
              ? DifyPlacement.bottomEnd
              : DifyPlacement.leftStart),
      sideOffset: 4,
      constrainHeight: true,
      builder: (context, controller) =>
          w.trigger?.call(context, controller) ??
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 296),
            child: SizedBox(
              height: 32,
              child: Row(
                children: [
                  Expanded(
                    child: SplitModelSelector(
                      value: value,
                      models: _selectable,
                      disabled: w.readonly || w.modelSelectorReadonly,
                      showModelMeta: w.showModelMeta,
                      surface: surface,
                      modelPredicate: w.modelPredicate,
                      modelSuggestionPredicate: w.modelSuggestionPredicate,
                      popupWidth: w.modelSelectorPopupWidth,
                      onChange: _changeModel,
                    ),
                  ),
                  const SizedBox(width: 1),
                  ModelSettingsTrigger(disabled: !canConfigure, surface: surface, onPressed: controller.toggle),
                ],
              ),
            ),
          ),
      popupBuilder: (context) => _content(value),
    );
  }

  Widget _content(DefaultModel? value) {
    final w = widget;
    final rules = _rules;
    final loading = _loading && w.provider.isNotEmpty && w.modelId.isNotEmpty;
    final names = [for (final r in rules) r.name];
    final title = DifyI18n.tr('common', 'modelProvider.modelSettings');
    return Semantics(
      container: true,
      role: SemanticsRole.dialog,
      label: title,
      explicitChildNodes: true,
      child: Container(
        width: w.popupWidth,
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
          borderRadius: BorderRadius.circular(DifyRadius.xxl),
          boxShadow: DifyShadows.lg,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 44, 4),
                  child: DifyText(title, DifyType.systemXlSemibold),
                ),
                Positioned(
                  top: 10,
                  right: 10,
                  child: DifyIconButton(
                    label: DifyI18n.tr('common', 'operation.close'),
                    size: DifyIconButtonSize.lg,
                    icon: const RemixIcon('close-line', size: 16),
                    onPressed: () => _setOpen(false),
                  ),
                ),
              ],
            ),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (w.trigger != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          child: ModelSelector(
                            value: value,
                            models: _selectable,
                            disabled: w.modelSelectorReadonly,
                            onChange: _changeModel,
                            onHide: () => _setOpen(false),
                          ),
                        ),
                      if (rules.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                          decoration: w.trigger != null
                              ? BoxDecoration(
                                  border: Border(
                                    top: BorderSide(color: DifyColors.dividerSubtle, width: Css.hairline),
                                  ),
                                )
                              : null,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            spacing: 8,
                            children: [
                              Row(
                                spacing: 4,
                                children: [
                                  Expanded(
                                    child: DifyText(
                                      DifyI18n.tr('common', 'modelProvider.parameters'),
                                      DifyType.systemSmSemiboldUppercase,
                                      color: DifyColors.textSecondary,
                                    ),
                                  ),
                                  if (providerWithPresetTone.contains(w.provider))
                                    Flexible(
                                      child: PresetsParameter(
                                        supportedParameterNames: names,
                                        onSelect: (tone) => w.onCompletionParamsChange({
                                          ...w.completionParams,
                                          ...getSupportedPresetConfig(tone, names),
                                        }),
                                      ),
                                    ),
                                ],
                              ),
                              if (loading)
                                const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: DifyLoading())
                              else
                                for (final r in [...rules, if (w.isAdvancedMode) stopParameterRule])
                                  ParameterItem(
                                    key: ValueKey('${w.modelId}-${r.name}'),
                                    parameterRule: r,
                                    value: w.completionParams[r.name],
                                    onChange: (v) => _param(r.name, v),
                                    onSwitch: (on, assign) => _switch(r.name, on, assign),
                                    isInWorkflow: w.isInWorkflow,
                                    nodesOutputVars: w.isInWorkflow ? w.nodesOutputVars : null,
                                    availableNodes: w.availableNodes,
                                  ),
                            ],
                          ),
                        ),
                      if (rules.isEmpty && loading)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                          child: DifyLoading(),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (!w.hideDebugWithMultipleModel)
              DifyPressable(
                semanticLabel: DifyI18n.tr(
                  'app-debug',
                  w.debugWithMultipleModel ? 'debugAsSingleModel' : 'debugAsMultipleModel',
                ),
                onPressed: () => w.onDebugWithMultipleModelChange?.call(),
                builder: (context, hovered, focused) => Container(
                  height: 50,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: DifyColors.dividerSubtle, width: Css.hairline),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: DifyText(
                          DifyI18n.tr(
                            'app-debug',
                            w.debugWithMultipleModel ? 'debugAsSingleModel' : 'debugAsMultipleModel',
                          ),
                          DifyType.systemSmRegular,
                          color: DifyColors.textAccent,
                        ),
                      ),
                      RemixIcon('arrow-right-line', size: 12, color: DifyColors.textAccent),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// ModelSettingsTrigger: the split trigger's right half, an `lg` tertiary icon button (`i-ri-equalizer-2-line`) with
/// square left corners, named and tooltipped "Model Settings"; on the workflow surface `bg-workflow-block-parma-bg`.
class ModelSettingsTrigger extends StatelessWidget {
  const ModelSettingsTrigger({
    super.key,
    this.disabled = false,
    this.surface = ModelSelectorSurface.normal,
    this.onPressed,
  });

  final bool disabled;
  final ModelSelectorSurface surface;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final label = DifyI18n.tr('common', 'modelProvider.modelSettings');
    final button = DifyPressable(
      semanticLabel: label,
      disabled: disabled,
      onPressed: onPressed,
      builder: (context, hovered, focused) {
        final look = difyButtonLook(
          DifyButtonVariant.tertiary,
          DifyButtonTone.normal,
          hovered: hovered,
          disabled: disabled,
        );
        return Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: surface == ModelSelectorSurface.workflow ? DifyColors.workflowBlockParmaBg : look.background,
            borderRadius: const BorderRadius.horizontal(right: Radius.circular(DifyRadius.lg)),
            border: focused ? Border.all(color: DifyColors.stateAccentSolid, width: 2) : null,
          ),
          child: RemixIcon('equalizer-2-line', size: 16, color: look.foreground),
        );
      },
    );
    return DifyTooltip(disabled: disabled, content: DifyTextLine(label), child: button);
  }
}
