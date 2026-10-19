/// system-model-selector/index.tsx: the "Default Models" button and its dialog, choosing the workspace's default
/// model per type (system reasoning, embedding, rerank, speech-to-text, text-to-speech); hooks.ts
/// `useSystemDefaultModelAndModelList`.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../cards/provider_icon_image.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/model_catalog.dart';
import '../../workflow/workspace_models.dart';
import '../../workflow_editor/node_panel/bodies/llm/group_host.dart';
import '../../workflow_editor/node_panel/bodies/llm/model_selector.dart' show ModelSelector;
import 'model_provider_env.dart';

String _t(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

/// useSystemDefaultModelAndModelList's current value: the default model of [defaultModel] (a DefaultModelResponse)
/// when [modelList] has it, else null.
DefaultModel? systemDefaultModelOf(Json? defaultModel, List<ProviderWithModels> modelList) {
  final providerName = (defaultModel?['provider'] as Map?)?['provider'];
  final provider = modelList.where((p) => p.provider == providerName).firstOrNull;
  final model = provider?.models.where((m) => m.model == defaultModel?['model']).firstOrNull;
  return provider != null && model != null ? (provider: provider.provider, model: model.model) : null;
}

/// useSystemDefaultModelAndModelList: the selected default of one type, starting at the current default and kept
/// while that default stays the same (a changed default resets the selection).
class SystemDefaultModelState {
  DefaultModel? _state;
  String _sourceKey = '';
  bool _touched = false;

  static String _key(DefaultModel? m) => m == null ? '' : '${m.provider}:${m.model}';

  /// The selection for [current] (the default in the list).
  DefaultModel? selected(DefaultModel? current) => _touched && _sourceKey == _key(current) ? _state : current;

  /// `handleDefaultModelChange`.
  void change(DefaultModel? current, DefaultModel model) {
    _sourceKey = _key(current);
    _state = model;
    _touched = true;
  }
}

typedef _Row = ({String type, String labelKey, String tipKey});

const _rows = <_Row>[
  (
    type: ModelTypeEnum.textGeneration,
    labelKey: 'modelProvider.systemReasoningModel.key',
    tipKey: 'modelProvider.systemReasoningModel.tip',
  ),
  (
    type: ModelTypeEnum.textEmbedding,
    labelKey: 'modelProvider.embeddingModel.key',
    tipKey: 'modelProvider.embeddingModel.tip',
  ),
  (type: ModelTypeEnum.rerank, labelKey: 'modelProvider.rerankModel.key', tipKey: 'modelProvider.rerankModel.tip'),
  (
    type: ModelTypeEnum.speech2text,
    labelKey: 'modelProvider.speechToTextModel.key',
    tipKey: 'modelProvider.speechToTextModel.tip',
  ),
  (type: ModelTypeEnum.tts, labelKey: 'modelProvider.ttsModel.key', tipKey: 'modelProvider.ttsModel.tip'),
];

/// SystemModel: the button (`primary` while nothing is configured, else `secondary`; a spinner while the defaults
/// load; [compact]: the warning's `h-6 px-1.5 text-xs`) opening the dialog (`w-120`): the title and description, a
/// labelled [ModelSelector] per type (`gap-4`; the lists other than the LLM's load when it opens) and Cancel / Save
/// (members without `plugin.model_config` cannot save).
class SystemModelSelector extends StatefulWidget {
  const SystemModelSelector({
    super.key,
    required this.notConfigured,
    this.isLoading = false,
    this.compact = false,
    this.hideProviderSettingsFooter = false,
  });

  final bool notConfigured, isLoading, compact, hideProviderSettingsFooter;

  @override
  State<SystemModelSelector> createState() => _SystemModelSelectorState();
}

class _SystemModelSelectorState extends State<SystemModelSelector> {
  Future<void> _open(ModelProviderEnv env) async {
    for (final r in _rows.skip(1)) {
      unawaited(env.models.updateModelList(r.type));
    }
    await showDifyDialog<void>(
      context,
      builder: (context) => ModelProviderScope(
        env: env,
        child: SystemModelDialog(hideProviderSettingsFooter: widget.hideProviderSettingsFooter),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final env = ModelProviderScope.of(context);
    return DifyButton(
      key: const ValueKey('system-model-selector-button'),
      variant: widget.notConfigured ? DifyButtonVariant.primary : DifyButtonVariant.secondary,
      size: DifyButtonSize.small,
      disabled: widget.isLoading,
      paddingX: widget.compact ? 6 : 12,
      onPressed: () => unawaited(_open(env)),
      leading: widget.isLoading
          ? DifySpinner(size: 14, color: DifyColors.textTertiary)
          : const RemixIcon('brain-2-line', size: 14),
      child: Text(
        _t('modelProvider.systemModelSettings'),
        style: widget.compact
            ? null
            : difyTextStyle(
                DifyType.systemSmMedium,
                widget.notConfigured
                    ? DifyColors.componentsButtonPrimaryText
                    : DifyColors.componentsButtonSecondaryText,
              ),
      ),
    );
  }
}

/// The system model settings dialog (see [SystemModelSelector]).
class SystemModelDialog extends StatefulWidget {
  const SystemModelDialog({super.key, this.hideProviderSettingsFooter = false});

  final bool hideProviderSettingsFooter;

  @override
  State<SystemModelDialog> createState() => _SystemModelDialogState();
}

class _SystemModelDialogState extends State<SystemModelDialog> {
  final _states = {for (final r in _rows) r.type: SystemDefaultModelState()};
  final _changed = <String>[];
  bool _saving = false;

  void _close() => Navigator.of(context).maybePop();

  Future<void> _save(ModelProviderEnv env, Map<String, DefaultModel?> current) async {
    final models = env.models;
    if (_rows.skip(1).any((r) => models.isModelListLoading(r.type)) || _saving) return;
    _saving = true;
    try {
      await withRequestToast(
        () => models.updateDefaultModels([
          for (final r in _rows)
            DefaultModelSetting(
              modelType: r.type,
              provider: _states[r.type]!.selected(current[r.type])?.provider,
              model: _states[r.type]!.selected(current[r.type])?.model,
            ),
        ], changedTypes: _changed),
      );
      toast.success(_t('actionMsg.modifiedSuccessfully'));
      if (mounted) _close();
    } on Object {
      // Toasted.
    } finally {
      _saving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final env = ModelProviderScope.of(context);
    final models = env.models;
    return ListenableBuilder(
      listenable: models,
      builder: (context, _) {
        final loading = _rows.skip(1).any((r) => models.isModelListLoading(r.type));
        final lists = {for (final r in _rows) r.type: models.modelList(r.type)};
        final current = {
          for (final r in _rows) r.type: systemDefaultModelOf(models.defaultModel(r.type), lists[r.type]!),
        };
        return LlmGroupScope(
          services: LlmGroupServices(models: models.catalog),
          child: ProviderIconScope(
            source: models.icons,
            child: DifyDialogSurface(
              label: _t('modelProvider.systemModelSettingsTitle'),
              width: 480,
              bordered: true,
              maxHeight: MediaQuery.sizeOf(context).height - 32,
              child: Stack(
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 24, 56, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _t('modelProvider.systemModelSettingsTitle'),
                              style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                _t('modelProvider.systemModelSettingsDesc'),
                                style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Flexible(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          child: loading
                              ? Semantics(
                                  container: true,
                                  label: _t('loading'),
                                  child: SizedBox(
                                    height: 192,
                                    child: Center(child: DifySpinner(size: 20, color: DifyColors.textTertiary)),
                                  ),
                                )
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  spacing: 16,
                                  children: [
                                    for (final r in _rows)
                                      Column(
                                        key: ValueKey('system-model-${r.type}'),
                                        crossAxisAlignment: CrossAxisAlignment.stretch,
                                        spacing: 4,
                                        children: [
                                          Container(
                                            constraints: const BoxConstraints(minHeight: 24),
                                            alignment: AlignmentDirectional.centerStart,
                                            child: Row(
                                              children: [
                                                Flexible(
                                                  child: Text(
                                                    _t(r.labelKey),
                                                    style: difyTextStyle(
                                                      DifyType.systemSmMedium,
                                                      DifyColors.textSecondary,
                                                    ).copyWith(fontSize: 13),
                                                  ),
                                                ),
                                                Padding(
                                                  padding: const EdgeInsets.only(left: 2),
                                                  child: Infotip(
                                                    label: _t(r.tipKey),
                                                    width: 261,
                                                    content: Text(_t(r.tipKey)),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          ModelSelector(
                                            value: _states[r.type]!.selected(current[r.type]),
                                            models: lists[r.type]!,
                                            hideProviderSettingsFooter: widget.hideProviderSettingsFooter,
                                            onConfigureEmptyState: _close,
                                            showModelMeta: false,
                                            onChange: (model) => setState(() {
                                              _states[r.type]!.change(current[r.type], model);
                                              if (!_changed.contains(r.type)) _changed.add(r.type);
                                            }),
                                          ),
                                        ],
                                      ),
                                  ],
                                ),
                        ),
                      ),
                      Container(
                        height: 76,
                        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                        alignment: AlignmentDirectional.centerEnd,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 8,
                          children: [
                            ConstrainedBox(
                              constraints: const BoxConstraints(minWidth: 72),
                              child: DifyButton(
                                key: const ValueKey('system-model-cancel'),
                                onPressed: _close,
                                child: Text(_t('operation.cancel')),
                              ),
                            ),
                            ConstrainedBox(
                              constraints: const BoxConstraints(minWidth: 72),
                              child: DifyButton(
                                key: const ValueKey('system-model-save'),
                                variant: DifyButtonVariant.primary,
                                disabled: !env.canConfigureModels || loading,
                                onPressed: () => unawaited(_save(env, current)),
                                child: Text(_t('operation.save')),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Positioned(
                    top: 20,
                    right: 20,
                    child: DifyIconButton(
                      key: const ValueKey('system-model-close'),
                      label: _t('operation.close'),
                      size: DifyIconButtonSize.lg,
                      icon: const RemixIcon('close-line', size: 16),
                      onPressed: _close,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
