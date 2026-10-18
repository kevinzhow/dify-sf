/// The features store (base/features: store.ts, context.tsx, hooks.ts, types.ts) and the two shapes Dify converts
/// between: the panel's `Features` (keys `opening`, `suggested`, `file`, ...) and the server's `workflow.features`
/// (keys `opening_statement`, `suggested_questions_after_answer`, `file_upload`, ...), which the collaborative
/// document holds under `$app` (workflow-app/utils.ts `buildInitialFeatures` reads it, workflow/features.tsx writes
/// it back).
library;

import 'package:flutter/widgets.dart';

import '../prompt_editor/prompt_blocks.dart' show fileExts;

/// Dify's `Features` (and the server's `workflow.features`) as plain JSON.
typedef Features = Map<String, Object?>;

/// `OnFeaturesChange`: told after the store changed (some callers pass the new features).
typedef OnFeaturesChange = void Function([Features? features]);

/// FeatureEnum.
abstract final class FeatureEnum {
  static const moreLikeThis = 'moreLikeThis';
  static const opening = 'opening';
  static const suggested = 'suggested';
  static const text2speech = 'text2speech';
  static const speech2text = 'speech2text';
  static const citation = 'citation';
  static const moderation = 'moderation';
  static const file = 'file';
  static const annotationReply = 'annotationReply';
}

/// TransferMethod.
abstract final class TransferMethod {
  static const localFile = 'local_file';
  static const remoteUrl = 'remote_url';
  static const all = 'all';
}

/// TtsAutoPlay.
abstract final class TtsAutoPlay {
  static const enabled = 'enabled';
  static const disabled = 'disabled';
}

/// The member [key] of [m] as a map (empty when it is not one).
Map<String, Object?> featureMap(Object? m, String key) => switch (m is Map ? m[key] : null) {
  final Map<String, Object?> v => v,
  final Map v => {for (final e in v.entries) '${e.key}': e.value},
  _ => const {},
};

/// `features[key].enabled` is truthy.
bool featureEnabled(Features f, String key) => featureMap(f, key)['enabled'] == true;

/// `produce(features, draft => { draft[key] = {...draft[key], ...patch} })`.
Features withFeature(Features f, String key, Map<String, Object?> patch) => {
  ...f,
  key: {...featureMap(f, key), ...patch},
};

/// createFeaturesStore's DEFAULT_PROPS.
Features defaultFeatures() => {
  FeatureEnum.moreLikeThis: {'enabled': false},
  FeatureEnum.opening: {'enabled': false},
  FeatureEnum.suggested: {'enabled': false},
  FeatureEnum.text2speech: {'enabled': false},
  FeatureEnum.speech2text: {'enabled': false},
  FeatureEnum.citation: {'enabled': false},
  FeatureEnum.moderation: {'enabled': false},
  FeatureEnum.file: {
    'image': {
      'enabled': false,
      'detail': 'high',
      'number_limits': 3,
      'transfer_methods': [TransferMethod.localFile, TransferMethod.remoteUrl],
    },
  },
  FeatureEnum.annotationReply: {'enabled': false},
};

/// createFeaturesStore (store.ts): the panel's features ([features], replaced whole by [setFeatures]) and
/// `showFeaturesModal`.
///
/// Every edit is also remembered as a change from the features before it until [takeEdit] collects it: the panel's
/// `onChange` writes that change (and only that) to the document. [replace] puts what the document says without
/// counting as an edit.
class FeaturesStore {
  FeaturesStore({Features? features}) : features = ValueNotifier(features ?? defaultFeatures());

  final ValueNotifier<Features> features;
  final showFeaturesModal = ValueNotifier(false);
  Features? _editFrom;

  void setFeatures(Features next) {
    _editFrom ??= features.value;
    features.value = next;
  }

  void setShowFeaturesModal(bool v) => showFeaturesModal.value = v;

  /// The features before the edits made since the last call, and now; null when nothing was edited.
  ({Features from, Features to})? takeEdit() {
    final from = _editFrom;
    _editFrom = null;
    return from == null || identical(from, features.value) ? null : (from: from, to: features.value);
  }

  /// Shows [next] (the document's) without recording an edit.
  void replace(Features next) {
    _editFrom = null;
    features.value = next;
  }

  void dispose() {
    features.dispose();
    showFeaturesModal.dispose();
  }
}

/// FeaturesContext: hands a [FeaturesStore] down the tree.
class FeaturesScope extends InheritedWidget {
  const FeaturesScope({super.key, required this.store, required super.child});

  final FeaturesStore store;

  /// `useFeaturesStore()`: the store, or null outside a provider.
  static FeaturesStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FeaturesScope>()?.store;

  /// The store for `useFeatures(selector)`; throws outside a provider, as Dify's hook does.
  static FeaturesStore of(BuildContext context) =>
      maybeOf(context) ?? (throw StateError('Missing FeaturesContext.Provider in the tree'));

  @override
  bool updateShouldNotify(FeaturesScope oldWidget) => store != oldWidget.store;
}

/// FeaturesProvider (context.tsx): one store for its lifetime, created from [features] (Dify's initial props: they
/// replace the defaults whole).
class FeaturesProvider extends StatefulWidget {
  const FeaturesProvider({super.key, this.features, required this.child});
  final Features? features;
  final Widget child;

  @override
  State<FeaturesProvider> createState() => _FeaturesProviderState();
}

class _FeaturesProviderState extends State<FeaturesProvider> {
  late final store = FeaturesStore(features: widget.features);

  @override
  void dispose() {
    store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FeaturesScope(store: store, child: widget.child);
}

/// Rebuilds with `useFeatures(selector)`: [builder] gets the store's features (it rebuilds on every change).
class FeaturesBuilder extends StatelessWidget {
  const FeaturesBuilder({super.key, required this.builder});
  final Widget Function(BuildContext context, Features features) builder;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: FeaturesScope.of(context).features,
    builder: (context, features, _) => builder(context, features),
  );
}

// ---- the server's shape ------------------------------------------------------------------------------------------

/// workflow-app/utils.ts `buildInitialFeatures`: the panel's features from the server's `workflow.features`
/// ([server]) and the system's file upload config.
Features buildInitialFeatures(Map<String, Object?> server, {Map<String, Object?>? fileUploadConfig}) {
  final fileUpload = featureMap(server, 'file_upload');
  final image = featureMap(fileUpload, 'image');
  List<Object?>? list(Object? v) => v is List ? v : null; // JS `||`: an empty array is kept
  Object? or(Object? v, Object? fallback) => (v == null || v == false || v == 0 || v == '') ? fallback : v;
  const methods = [TransferMethod.localFile, TransferMethod.remoteUrl];
  Object? feature(String key) => server[key] ?? {'enabled': false};
  final statement = server['opening_statement'];
  return {
    FeatureEnum.file: {
      'image': {
        'enabled': image['enabled'] == true,
        'number_limits': or(image['number_limits'], 3),
        'transfer_methods': list(image['transfer_methods']) ?? methods,
      },
      'enabled': fileUpload['enabled'] == true || image['enabled'] == true,
      'allowed_file_types': list(fileUpload['allowed_file_types']) ?? const ['image'],
      'allowed_file_extensions':
          list(fileUpload['allowed_file_extensions']) ?? [for (final e in fileExts['image']!) '.$e'],
      'allowed_file_upload_methods':
          list(fileUpload['allowed_file_upload_methods']) ?? list(image['transfer_methods']) ?? methods,
      'number_limits': or(fileUpload['number_limits'], or(image['number_limits'], 3)),
      'fileUploadConfig': ?fileUploadConfig,
    },
    FeatureEnum.opening: {
      'enabled': statement is String && statement.isNotEmpty,
      'opening_statement': statement,
      'suggested_questions': server['suggested_questions'],
    },
    FeatureEnum.suggested: feature('suggested_questions_after_answer'),
    FeatureEnum.speech2text: feature('speech_to_text'),
    FeatureEnum.text2speech: feature('text_to_speech'),
    FeatureEnum.citation: feature('retriever_resource'),
    FeatureEnum.moderation: feature('sensitive_word_avoidance'),
  };
}

/// workflow/features.tsx `handleFeaturesChange` (and the draft sync): the server's `workflow.features` for the panel's
/// [features]. The file upload's `fileUploadConfig` (the system's limits, not a setting of the app) is left out.
Features serverFeatures(Features features) {
  final opening = featureMap(features, FeatureEnum.opening);
  final on = opening['enabled'] == true;
  final file = features[FeatureEnum.file];
  return {
    'opening_statement': on ? (opening['opening_statement'] as String? ?? '') : '',
    'suggested_questions': on ? (opening['suggested_questions'] ?? const <Object?>[]) : const <Object?>[],
    'suggested_questions_after_answer': features[FeatureEnum.suggested],
    'text_to_speech': features[FeatureEnum.text2speech],
    'speech_to_text': features[FeatureEnum.speech2text],
    'retriever_resource': features[FeatureEnum.citation],
    'sensitive_word_avoidance': features[FeatureEnum.moderation],
    'file_upload': file is Map ? ({...file}..remove('fileUploadConfig')) : file,
  };
}

/// Deep equality of plain JSON, a null member counting as absent (as in Dify's code) and numbers by value.
bool featuresEqual(Object? a, Object? b) {
  if (a is Map && b is Map) {
    for (final k in {...a.keys, ...b.keys}) {
      if (!featuresEqual(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!featuresEqual(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
