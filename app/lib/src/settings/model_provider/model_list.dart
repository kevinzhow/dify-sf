/// provider-added-card/model-list.tsx and model-list-item.tsx: a provider's expanded model list (every model with
/// its status), enable / disable and basic credential configuration. Balancing
/// pools and cooldowns are deferred independently of configuration and removal.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../cards/model_chip.dart' show ModelIcon, ModelName;
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/model_catalog.dart';
import '../../workflow/workspace_models.dart' show Json;
import 'model_auth.dart' show ModelAuth;
import 'model_credentials_action.dart';
import 'model_provider_env.dart';
import 'provider_added_card.dart' show LazyCustomModelActions;
import 'provider_data.dart';

String _t(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

/// `getModelKey`.
String modelKeyOf(ModelItem m) => '${m.model}-${m.modelType}-${m.fetchFrom}';

/// ModelList: `rounded-b-xl px-2 pb-2` around `rounded-lg bg-components-panel-bg py-1`: the "N Models" header (hover:
/// the collapse button) with the custom model actions, then a [ModelListItem] per model.
class ModelList extends StatelessWidget {
  const ModelList({super.key, required this.provider, required this.models, required this.onCollapse, this.onChange});

  final Json provider;
  final List<ModelItem> models;
  final VoidCallback onCollapse;

  /// After a model changed (with the provider's id).
  final ValueChanged<String>? onChange;

  @override
  Widget build(BuildContext context) {
    final env = ModelProviderScope.of(context);
    final methods = provider.configurateMethods.where((m) => m != ConfigurationMethodEnum.fetchFromRemote);
    final isConfigurable = methods.contains(ConfigurationMethodEnum.customizableModel);
    final count = _t('modelProvider.modelsNum', {'num': models.length});
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 3),
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: DifyPressable(
                      key: const ValueKey('model-list-collapse'),
                      semanticLabel: count,
                      onPressed: onCollapse,
                      builder: (context, hovered, focused) => Container(
                        height: 24,
                        padding: const EdgeInsets.only(left: 4, right: 6),
                        decoration: BoxDecoration(
                          color: hovered || focused ? DifyColors.stateBaseHover : null,
                          borderRadius: BorderRadius.circular(DifyRadius.lg),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            DifyTextLine(count, style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textTertiary)),
                            Padding(
                              padding: EdgeInsets.only(right: 2),
                              child: RotatedBox(
                                quarterTurns: 1,
                                child: RemixIcon('arrow-right-s-line', size: 16, color: DifyColors.textTertiary),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (isConfigurable && env.canConfigureModels)
                    Expanded(
                      child: Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: LazyCustomModelActions(provider: provider),
                      ),
                    ),
                ],
              ),
            ),
            for (final m in models)
              ModelListItem(
                key: ValueKey(modelKeyOf(m)),
                model: m,
                provider: provider,
                isConfigurable: isConfigurable,
                onChange: onChange,
              ),
          ],
        ),
      ),
    );
  }
}

/// ModelListItem: `group flex h-8 items-center rounded-lg pr-2.5 pl-2` (hover background when configurable, 60 %
/// opacity when deprecated): the model icon, its name with every badge, and the switch (`md`; members with
/// `plugin.model_config`), on for active models and usable only for active and disabled ones; a deprecated model shows
/// a disabled switch that explains why on hover. Toggling is debounced (500 ms), then refreshes the lists.
class ModelListItem extends StatefulWidget {
  const ModelListItem({
    super.key,
    required this.model,
    required this.provider,
    required this.isConfigurable,
    this.onChange,
  });

  final ModelItem model;
  final Json provider;
  final bool isConfigurable;
  final ValueChanged<String>? onChange;

  @override
  State<ModelListItem> createState() => _ModelListItemState();
}

class _ModelListItemState extends State<ModelListItem> {
  bool _hovered = false;
  bool _removing = false;
  Timer? _debounce;

  bool get _customModel => widget.isConfigurable && widget.model.fetchFrom == ConfigurationMethodEnum.customizableModel;

  Future<void> _remove(ModelProviderEnv env) async {
    if (_removing || !_customModel || !env.canConfigureModels) return;
    _debounce?.cancel();
    setState(() => _removing = true);
    final m = widget.model;
    final auth = ModelAuth(
      env: env,
      provider: widget.provider,
      configurationMethod: ConfigurationMethodEnum.customizableModel,
      isModelCredential: true,
    );
    try {
      final removed = await auth.confirmDelete(
        context,
        model: (model: m.model, modelType: m.modelType),
        confirmLabel: _t('operation.remove'),
        description: env.language.startsWith('zh')
            ? '将「${m.model}」从可用模型列表移除。已保存的凭据会保留，可以重新添加此模型。使用此模型的工作流需要改选模型。'
            : 'Remove "${m.model}" from the available model list. Saved credentials remain, so you can add it again. Workflows using this model will need another model selected.',
        lockCancelWhileBusy: true,
      );
      if (removed) widget.onChange?.call(widget.provider.providerName);
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// `toggleModelEnablingStatus`.
  Future<void> _toggle(ModelProviderEnv env, bool enabled) async {
    final provider = widget.provider.providerName;
    try {
      await withRequestToast(() => env.models.setModelEnabled(provider, widget.model, enabled));
    } on Object {
      return;
    }
    unawaited(env.models.updateModelList(widget.model.modelType));
    widget.onChange?.call(provider);
  }

  @override
  Widget build(BuildContext context) {
    final env = ModelProviderScope.of(context);
    final m = widget.model;
    final usable = m.status == ModelStatusEnum.active || m.status == ModelStatusEnum.disabled;
    Widget row = Container(
      height: 32,
      padding: const EdgeInsets.only(left: 8, right: 10),
      decoration: BoxDecoration(
        color: widget.isConfigurable && _hovered ? DifyColors.componentsPanelOnPanelItemBgHover : null,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
      ),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ModelIcon(
              provider: widget.provider.providerName,
              iconSmall: widget.provider.iconSmall,
              iconSmallDark: widget.provider.iconSmallDark,
              modelName: m.model,
              language: env.language,
            ),
          ),
          Expanded(
            child: ModelName(
              modelItem: m,
              language: env.language,
              lineThrough: m.deprecated,
              showModelType: true,
              showMode: true,
              showContextSize: true,
              showFeatures: true,
              showFeaturesLabel: true,
              nameType: DifyType.systemMdRegular,
              nameColor: DifyColors.textSecondary,
            ),
          ),
          if (m.schemaStatus != 'ready')
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: DifyTooltip(
                content: DifyTextLine(
                  _t(
                    m.schemaError == 'plugin_not_installed'
                        ? 'modelProvider.plugins.missingTip'
                        : m.schemaError == 'model_schema_missing'
                        ? 'modelProvider.metadataMissingTip'
                        : 'modelProvider.metadataUnknownTip',
                  ),
                  style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textSecondary),
                ),
                child: DifyTextLine(
                  _t(
                    m.schemaError == 'plugin_not_installed'
                        ? 'modelProvider.plugins.missing'
                        : m.schemaError == 'model_schema_missing'
                        ? 'modelProvider.metadataMissing'
                        : 'modelProvider.metadataUnknown',
                  ),
                  style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textWarning),
                ),
              ),
            ),
          if (!m.deprecated &&
              usable &&
              env.canConfigureModels &&
              (env.canUseCredential || env.canManageCredential || env.canCreateCredential))
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: ModelCredentialsAction(provider: widget.provider, model: m),
            ),
          if (m.deprecated)
            DifyTooltip(
              content: DifyTextLine(
                _t('modelProvider.modelHasBeenDeprecated'),
                style: difyTextStyle(
                  DifyType.systemXsRegular,
                  DifyColors.textTertiary,
                ).copyWith(fontWeight: FontWeight.w600),
              ),
              child: const DifySwitch(checked: false, disabled: true, size: DifySwitchSize.md),
            )
          else if (env.canConfigureModels)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: DifySwitch(
                key: ValueKey('model-switch-${m.model}'),
                checked: m.status == ModelStatusEnum.active,
                disabled: !usable || _removing,
                size: DifySwitchSize.md,
                semanticLabel: m.model,
                onCheckedChange: (value) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 500), () => unawaited(_toggle(env, value)));
                },
              ),
            ),
          if (_customModel && env.canConfigureModels)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: DifyTooltip(
                content: DifyTextLine(
                  env.language.startsWith('zh') ? '移除模型' : 'Remove model',
                ),
                child: DifyIconButton(
                  key: ValueKey('model-remove-${m.model}'),
                  label: '${env.language.startsWith('zh') ? '移除模型' : 'Remove model'} ${m.model}',
                  icon: const RemixIcon('delete-bin-line', size: 16),
                  tone: DifyButtonTone.destructive,
                  disabled: _removing,
                  onPressed: () => unawaited(_remove(env)),
                ),
              ),
            ),
        ],
      ),
    );
    if (m.deprecated) row = Opacity(opacity: 0.6, child: row);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: row,
    );
  }
}
