/// What the Question Classifier and Parameter Extractor panels share: their use-config model handling (the default
/// model, the vision follow-up of a model change, the completion role prefix), the model field and the instruction
/// editor.
library;

import 'package:flutter/widgets.dart';

import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../../workflow/model_catalog.dart';
import '../../../panel_fields/panel_fields.dart';
import '../../../prompt_editor/config_prompt.dart' show PromptEditorEnv;
import '../../../prompt_editor/prompt_blocks.dart' show checkHasQueryBlock;
import '../../../prompt_editor/prompt_editor_panel.dart';
import '../../node_panel_bodies.dart';
import 'group_host.dart';
import 'llm_config.dart' show jsonClone;
import 'model_common.dart';
import 'model_parameter_modal.dart';
import '../../panel_edit.dart';
import 'llm_vars.dart';

String _w(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);

/// The model and input handling QC's and PE's use-config share, on a panel State. [inputs] is Dify's inputRef:
/// handlers read it and [setInputs] moves it, so several handlers in a row build on each other.
mixin ModelNodeConfig<T extends StatefulWidget> on State<T> {
  NodePanelProps get props;

  LlmGroupServices services = LlmGroupServices.empty;

  /// `inputRef.current`.
  late Json inputs = props.data;

  /// PE's `defaultRolePrefix` state; injected into a memory that has none when [injectRolePrefix].
  Json defaultRolePrefix = const {'user': '', 'assistant': ''};
  bool get injectRolePrefix => false;

  bool _modelChanged = false;
  bool _adoptedDefault = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    services = LlmGroupScope.of(context);
  }

  void toast(LlmToastType type, String message) => services.toast?.call(type, message);

  /// setInputs (with PE's role prefix injection).
  void setNodeInputs(Json next) {
    var n = next;
    final memory = n['memory'];
    if (injectRolePrefix && memory is Map && memory['role_prefix'] == null) {
      n = jsonClone(n);
      (n['memory']! as Map)['role_prefix'] = {...defaultRolePrefix};
    }
    setInputs(props, n);
    inputs = n;
  }

  /// `produce(inputRef.current, f)` then setInputs.
  void produceInputs(void Function(Json draft) f) {
    final d = jsonClone(inputs);
    f(d);
    setNodeInputs(d);
  }

  Json get model => jsMap(inputs['model']);
  String get provider => jsStr(model['provider']) ?? '';
  String get modelName => jsStr(model['name']) ?? '';
  bool get isChatModel => model['mode'] == 'chat';

  /// Called by handleModelChanged before the change is written (PE appends its default prompt config).
  void beforeModelChange(Json draft, ModelChoice m) {}

  /// handleModelChanged: provider, name and mode (the completion params stay); the vision follow-up runs next.
  void handleModelChanged(ModelChoice m) {
    produceInputs((d) {
      final model = d['model'] is Map ? d['model']! as Map : (d['model'] = <String, Object?>{}) as Map;
      beforeModelChange(d, m);
      model['provider'] = m.provider;
      model['name'] = m.modelId;
      model['mode'] = m.mode;
    });
    _modelChanged = true;
  }

  void handleCompletionParamsChange(Json params) => produceInputs((d) {
    final model = d['model'] is Map ? d['model']! as Map : (d['model'] = <String, Object?>{}) as Map;
    model['completion_params'] = params;
  });

  void handleVisionEnabledChange(bool enabled) =>
      produceInputs((d) => d['vision'] = visionEnabledChange(jsMap(d['vision']), enabled, isChatMode: props.chatMode));

  void handleVisionConfigChange(Json config) =>
      produceInputs((d) => d['vision'] = {...jsMap(d['vision']), 'configs': config});

  /// `hasSetBlockStatus` of the instruction.
  BlockStatus get instructionBlockStatus => (
    history: false,
    query: props.chatMode && checkHasQueryBlock(jsStr(inputs['instruction'])),
    context: false,
  );

  /// The effects of use-config, after the frame (they write the document): the workspace default model for a node
  /// without one, the vision follow-up of a model change, and [moreEffects].
  void runEffects() {
    if (props.readOnly) return;
    final s = services;
    if (!_adoptedDefault && provider.isEmpty) {
      final d = s.defaultModels[ModelTypeEnum.textGeneration];
      final (:currentProvider, :currentModel) = getCurrentProviderAndModel(
        s.models.textGenerationModelList,
        d == null ? null : (provider: d.provider, model: d.model),
      );
      if (currentProvider != null && currentModel != null) {
        _adoptedDefault = true;
        _post(
          () => handleModelChanged((
            provider: currentProvider.provider,
            modelId: currentModel.model,
            mode: jsStr(currentModel.modelProperties['mode']),
            features: currentModel.features ?? const [],
          )),
        );
      }
    }
    if (_modelChanged) {
      _modelChanged = false;
      final next = visionAfterModelChange(
        jsMap(inputs['vision']),
        isVisionModel: isVisionModel(s, provider, modelName),
        isChatMode: props.chatMode,
      );
      if (next != null) _post(() => produceInputs((d) => d['vision'] = next));
    }
    moreEffects();
  }

  void moreEffects() {}

  void _post(VoidCallback f) => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) f();
  });

  /// Runs [f] after the frame while mounted.
  void afterFrame(VoidCallback f) => _post(f);
}

/// The model field: a required Field with the ModelParameterModal (advanced mode, in the workflow); number and
/// string variables for the parameters.
class ModelField extends StatelessWidget {
  const ModelField({
    super.key,
    required this.title,
    required this.model,
    required this.readOnly,
    required this.env,
    required this.onModelChange,
    required this.onCompletionParamsChange,
  });

  final String title;
  final Json model;
  final bool readOnly;
  final PromptEditorEnv env;
  final ValueChanged<ModelChoice> onModelChange;
  final ValueChanged<Json> onCompletionParamsChange;

  @override
  Widget build(BuildContext context) => Field(
    title: title,
    required: true,
    child: ModelParameterModal(
      provider: jsStr(model['provider']) ?? '',
      modelId: jsStr(model['name']) ?? '',
      completionParams: jsMap(model['completion_params']),
      onModelChange: onModelChange,
      onCompletionParamsChange: onCompletionParamsChange,
      readonly: readOnly,
      nodesOutputVars: env.nodesOutputVars,
      availableNodes: env.availableNodes,
    ),
  );
}

/// The Instruction editor (advanced-setting.tsx / panel.tsx): the uppercase title with its `w-[120px]` infotip, no
/// context block.
class InstructionEditor extends StatelessWidget {
  const InstructionEditor({
    super.key,
    required this.i18nPrefix,
    required this.value,
    required this.onChange,
    required this.readOnly,
    required this.isChatModel,
    required this.isChatApp,
    required this.hasSetBlockStatus,
    required this.env,
  });

  final String i18nPrefix;
  final String value;
  final ValueChanged<String> onChange;
  final bool readOnly, isChatModel, isChatApp;
  final BlockStatus hasSetBlockStatus;
  final PromptEditorEnv env;

  @override
  Widget build(BuildContext context) {
    final tip = _w('$i18nPrefix.instructionTip');
    return DifyPromptEditorPanel(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          Flexible(
            child: DifyTextLine(
              _w('$i18nPrefix.instruction').toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: difyTextStyle(DifyType.systemXsSemiboldUppercase, DifyColors.textSecondary),
            ),
          ),
          DifyInfotip(label: tip, width: 120, iconSize: 14, content: DifyTextLine(tip)),
        ],
      ),
      value: value,
      onChange: onChange,
      readOnly: readOnly,
      isChatModel: isChatModel,
      isChatApp: isChatApp,
      hasSetBlockStatus: hasSetBlockStatus,
      nodesOutputVars: env.nodesOutputVars,
      availableNodes: env.availableNodes,
      getVarType: env.getVarType,
      onOpenUrl: env.onOpenUrl,
    );
  }
}

/// The Field operations' add button (`rounded-md p-1 hover:bg-state-base-hover`, `i-ri-add-line size-4`).
class AddIconButton extends StatelessWidget {
  const AddIconButton({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => DifyIconButton(
    label: label,
    icon: RemixIcon('add-line', size: 16, color: DifyColors.textTertiary),
    onPressed: onPressed,
  );
}
