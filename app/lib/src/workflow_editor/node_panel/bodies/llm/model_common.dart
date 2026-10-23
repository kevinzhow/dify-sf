/// Model logic the LLM, Question Classifier and Parameter Extractor panels share: the current text generation model
/// and its features (useTextGenerationCurrentProviderAndModelAndModelList), vision (hooks/use-config-vision.ts) and
/// the workspace default model.
library;

import '../../../../workflow/dify_json.dart';
import '../../../../workflow/model_catalog.dart';
import '../../../panel_fields/node_config.dart' show Json;
import 'group_host.dart';
import 'llm_vars.dart' show jsMap;

/// `{provider, name}` of a node's `model` config.
({String provider, String name, String mode}) modelOf(Object? model) {
  final m = jsMap(model);
  return (provider: jsStr(m['provider']) ?? '', name: jsStr(m['name']) ?? '', mode: jsStr(m['mode']) ?? 'chat');
}

/// The text generation model [provider] / [name] names, if the workspace has it.
ModelItem? currentTextModel(LlmGroupServices s, String provider, String name) {
  final (:currentProvider, :currentModel) = getCurrentProviderAndModel(
    s.models.textGenerationModelList,
    provider.isEmpty && name.isEmpty ? null : (provider: provider, model: name),
  );
  return currentProvider == null ? null : currentModel;
}

/// The features of the current text generation model (empty when unknown).
List<String> currentModelFeatures(LlmGroupServices s, String provider, String name) =>
    currentTextModel(s, provider, name)?.features ?? const [];

/// `getIsVisionModel`.
bool isVisionModel(LlmGroupServices s, String provider, String name) =>
    currentModelFeatures(s, provider, name).contains(ModelFeatureEnum.vision);

/// `supportFunctionCall` (utils/tool-call.ts).
bool supportFunctionCall(List<String>? features) =>
    features != null &&
    features.any(
      (f) =>
          f == ModelFeatureEnum.toolCall || f == ModelFeatureEnum.multiToolCall || f == ModelFeatureEnum.streamToolCall,
    );

/// `handleVisionResolutionEnabledChange`: `vision` with [enabled] (in a chatflow, enabling presets high detail on
/// `sys.files`; disabling drops the configs).
Json visionEnabledChange(Json vision, bool enabled, {required bool isChatMode}) {
  final next = {...vision, 'enabled': enabled};
  if (enabled && isChatMode) {
    next['configs'] = {
      'detail': 'high',
      'variable_selector': ['sys', 'files'],
    };
  } else if (!enabled) {
    next.remove('configs');
  }
  return next;
}

/// `handleModelChanged` (after a model change): off for a model without vision; a vision model with vision on gets
/// fresh configs (high detail, no variable). Null: nothing to change.
Json? visionAfterModelChange(Json vision, {required bool isVisionModel, required bool isChatMode}) {
  if (!isVisionModel) return visionEnabledChange(vision, false, isChatMode: isChatMode);
  if (vision['enabled'] == true) {
    return {
      'enabled': true,
      'configs': {'detail': 'high', 'variable_selector': <String>[]},
    };
  }
  return null;
}

/// The workspace default text generation model as a node's `model` (provider, name, mode from its
/// model_properties; `chat` when unknown), keeping [current]'s completion params; null when there is none.
Json? defaultTextModel(LlmGroupServices s, Json current) {
  final d = s.defaultModels[ModelTypeEnum.textGeneration];
  if (d == null || d.provider.isEmpty) return null;
  return {...current, 'provider': d.provider, 'name': d.model, 'mode': d.mode ?? 'chat'};
}
