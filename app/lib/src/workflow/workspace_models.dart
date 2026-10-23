/// The workspace's model providers and models as the app keeps them (Dify's react-query caches for the console's
/// model provider endpoints: `model-providers/summary`, `model-providers`, `models/model-types/{type}`,
/// `default-model`, `model-providers/{p}/models`, parameter rules), loaded through collab_client's [ModelProvidersApi]
/// (protocol 1.9, Dify's console shapes) and
/// refreshed the way Dify's hooks invalidate them (useUpdateModelProviders, useUpdateModelList,
/// useInvalidateDefaultModel, useRefreshModel). The editor builds its model services from it ([catalog],
/// [defaultModelsMap], [parameterRules]); the Model Provider settings read and change it.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart' show DefaultModelSetting, ModelProvidersApi, TransportException;
import 'package:flutter/foundation.dart';

import '../cards/provider_icon_image.dart';
import '../i18n/dify_i18n.dart';
import '../workflow_editor/panel_fields/node_config.dart' show Json;
import 'model_catalog.dart';

export 'package:collab_client/collab_client.dart' show DefaultModelSetting, ModelProviderIcon, ModelProvidersApi;

export '../workflow_editor/panel_fields/node_config.dart' show Json;

/// The model types the editor loads lists of (useAllModel's order).
const allModelTypes = [
  ModelTypeEnum.textGeneration,
  ModelTypeEnum.textEmbedding,
  ModelTypeEnum.rerank,
  ModelTypeEnum.speech2text,
  ModelTypeEnum.moderation,
  ModelTypeEnum.tts,
];

/// The model types with a system default model (the system model settings' order).
const defaultModelTypes = [
  ModelTypeEnum.textGeneration,
  ModelTypeEnum.textEmbedding,
  ModelTypeEnum.rerank,
  ModelTypeEnum.speech2text,
  ModelTypeEnum.tts,
];

/// The message Dify's service layer would toast for a failed request: the server's message.
String apiErrorMessage(Object error) => error is TransportException ? error.message : '$error';

/// See the library comment. Requests may overlap; the latest answer of each query wins.
class WorkspaceModels extends ChangeNotifier {
  WorkspaceModels(this.api, {this.fixedLanguage});

  /// The server's API; null: no server (an empty workspace; writes fail).
  final ModelProvidersApi? api;

  ModelProvidersApi get _api => api ?? (throw StateError('no server'));

  /// The language texts are shown in; the app's when null.
  final String? fixedLanguage;
  bool _disposed = false;

  /// useLanguage: the language I18n texts are shown in (the app's, `en_US` style).
  String get language => fixedLanguage ?? languageOfLocale(currentDifyLanguage());

  // ----- summary (GET model-providers/summary) -----

  List<Json>? _summary;
  int _summarySeq = 0;
  bool _summaryLoading = false;

  /// Every provider (ModelProviderSummaryResponse JSON); null until loaded.
  List<Json>? get summary => _summary;
  bool get isLoadingProviders => _summary == null && _summaryLoading;

  /// The summary as the app's [ModelProvider]s.
  List<ModelProvider> get providers => [for (final p in _summary ?? const <Json>[]) ModelProvider.fromJson(p)];

  /// The summary entry of [provider].
  Json? summaryOf(String provider) => _summary?.where((p) => p['provider'] == provider).firstOrNull;

  Future<void> refreshSummary() async {
    final n = ++_summarySeq;
    _summaryLoading = true;
    try {
      final data = api == null ? const <Json>[] : await api!.summaries();
      if (n == _summarySeq) _summary = data;
    } on Object {
      if (n == _summarySeq) _summary ??= const [];
    } finally {
      if (n == _summarySeq) _summaryLoading = false;
      _notify();
    }
  }

  // ----- provider details (GET model-providers) -----

  List<Json>? _details;
  Future<List<Json>?>? _detailsFuture;
  int _detailsSeq = 0;

  /// The providers with their credential form schemas and custom models (ProviderResponse JSON), once loaded.
  List<Json>? get providerDetails => _details;

  /// `useModelProviderDetails` / `queryClient.query(modelProviderDetailsQueryOptions())`: the details, fetched once
  /// until invalidated; null when the request failed.
  Future<List<Json>?> loadProviderDetails() => _detailsFuture ??= _fetchDetails();

  Future<List<Json>?> _fetchDetails() async {
    final n = ++_detailsSeq;
    try {
      final data = api == null ? const <Json>[] : await api!.providers();
      if (n == _detailsSeq) {
        _details = data;
        _notify();
      }
      return data;
    } on Object {
      if (n == _detailsSeq) _detailsFuture = null;
      return null;
    }
  }

  /// useLazyModelProviderDetail's `loadProviderDetail`: the details of [provider], or null.
  Future<Json?> loadProviderDetail(String provider) async =>
      (await loadProviderDetails())?.where((p) => p['provider'] == provider).firstOrNull;

  /// The loaded details of [provider], or null.
  Json? detailOf(String provider) => _details?.where((p) => p['provider'] == provider).firstOrNull;

  /// useUpdateModelProviders: refetches the summary and the details (the details only if they were loaded).
  Future<void> updateModelProviders() async {
    final hadDetails = _detailsFuture != null;
    _detailsFuture = null;
    await Future.wait([refreshSummary(), if (hadDetails) loadProviderDetails()]);
  }

  // ----- model lists (GET models/model-types/{type}) -----

  final _lists = <String, List<Json>>{};
  final _listSeq = <String, int>{};
  final _listLoading = <String>{};

  /// The models of [type] (ProviderWithModelsResponse JSON); empty until loaded.
  List<Json> modelListJson(String type) => _lists[type] ?? const [];
  bool isModelListLoaded(String type) => _lists.containsKey(type);
  bool isModelListLoading(String type) => _listLoading.contains(type) && !_lists.containsKey(type);

  List<ProviderWithModels> modelList(String type) => [
    for (final p in modelListJson(type)) ProviderWithModels.fromJson(p),
  ];

  /// useUpdateModelList(type): refetches the list of [type].
  Future<void> updateModelList(String type) async {
    final n = _listSeq[type] = (_listSeq[type] ?? 0) + 1;
    _listLoading.add(type);
    try {
      final data = api == null ? const <Json>[] : await api!.modelsOfType(type);
      if (_listSeq[type] == n) _lists[type] = data;
    } on Object {
      if (_listSeq[type] == n) _lists[type] ??= const [];
    } finally {
      if (_listSeq[type] == n) _listLoading.remove(type);
      _notify();
    }
  }

  /// Loads the list of [type] unless it is loaded or loading (a query becoming enabled).
  Future<void> ensureModelList(String type) async {
    if (_lists.containsKey(type) || _listLoading.contains(type)) return;
    await updateModelList(type);
  }

  // ----- default models (GET default-model) -----

  final _defaults = <String, Json?>{};
  final _defaultSeq = <String, int>{};
  final _defaultLoading = <String>{};

  /// useDefaultModel(type).data: null when unset (or not loaded).
  Json? defaultModel(String type) => _defaults[type];
  bool isDefaultModelLoading(String type) => _defaultLoading.contains(type) && !_defaults.containsKey(type);
  bool get isDefaultModelsLoading => defaultModelTypes.any(isDefaultModelLoading);

  /// useInvalidateDefaultModel(type): refetches the default model of [type].
  Future<void> invalidateDefaultModel(String type) async {
    final n = _defaultSeq[type] = (_defaultSeq[type] ?? 0) + 1;
    _defaultLoading.add(type);
    try {
      final data = api == null ? null : await api!.defaultModel(type);
      if (_defaultSeq[type] == n) _defaults[type] = data;
    } on Object {
      if (_defaultSeq[type] == n) _defaults.putIfAbsent(type, () => null);
    } finally {
      if (_defaultSeq[type] == n) _defaultLoading.remove(type);
      _notify();
    }
  }

  /// POST `default-model` with every type's setting, then refetches the defaults (and the lists of [changedTypes]).
  Future<void> updateDefaultModels(
    List<DefaultModelSetting> settings, {
    Iterable<String> changedTypes = const [],
  }) async {
    await _api.setDefaultModels(settings);
    unawaited(Future.wait([for (final t in defaultModelTypes) invalidateDefaultModel(t)]));
    for (final t in changedTypes) {
      unawaited(updateModelList(t));
    }
  }

  // ----- a provider's models (GET model-providers/{p}/models) -----

  final _providerModels = <String, List<ModelItem>>{};
  final _providerModelsSeq = <String, int>{};
  final _providerModelsLoading = <String>{};
  final _expanded = <String>{};

  /// The atoms' expanded state of a provider's model list.
  bool isExpanded(String provider) => _expanded.contains(provider);
  void setExpanded(String provider, bool expanded) {
    if (expanded ? _expanded.add(provider) : _expanded.remove(provider)) _notify();
  }

  /// The models of [provider] with every status; null until fetched.
  List<ModelItem>? providerModels(String provider) => _providerModels[provider];
  bool isProviderModelsFetching(String provider) => _providerModelsLoading.contains(provider);

  /// Fetches the models of [provider] (the model list query's fetch / refetch).
  Future<void> fetchProviderModels(String provider) async {
    final n = _providerModelsSeq[provider] = (_providerModelsSeq[provider] ?? 0) + 1;
    _providerModelsLoading.add(provider);
    _notify();
    try {
      final data = api == null ? const <Json>[] : await api!.providerModels(provider);
      if (_providerModelsSeq[provider] == n) {
        _providerModels[provider] = [for (final m in data) ModelItem.fromJson(m)];
      }
    } on Object {
      // The query keeps its last data.
    } finally {
      if (_providerModelsSeq[provider] == n) _providerModelsLoading.remove(provider);
      _notify();
    }
  }

  /// useRefreshModel's `handleRefreshModel`: refetches the providers and the provider's model lists; with
  /// [refreshModelList] and an active provider, expands its model list and refetches it.
  Future<void> refreshModel(Json provider, {String? modelType, bool refreshModelList = false}) async {
    final name = '${provider['provider']}';
    final work = <Future<void>>[
      updateModelProviders(),
      for (final t in (provider['supported_model_types'] as List? ?? const [])) updateModelList('$t'),
    ];
    final custom = provider['custom_configuration'];
    if (refreshModelList && custom is Map && custom['status'] == 'active') {
      setExpanded(name, true);
      work.add(fetchProviderModels(name));
      if (modelType != null) work.add(updateModelList(modelType));
    }
    await Future.wait(work);
  }

  // ----- parameter rules -----

  final _rules = <(String, String), Future<List<Json>>>{};

  /// useModelParameterRules(provider, model), cached per model.
  Future<List<Json>> parameterRules(String provider, String model) => _rules[(provider, model)] ??=
      (api?.parameterRules(provider, model) ?? Future.value(const <Json>[])).catchError((Object _) {
        _rules.remove((provider, model));
        return const <Json>[];
      });

  // ----- everything the editor needs -----

  /// Loads the summary, every model list and every default model (the editor's start).
  Future<void> load() => Future.wait([
    refreshSummary(),
    for (final t in allModelTypes) updateModelList(t),
    for (final t in defaultModelTypes) invalidateDefaultModel(t),
  ]);

  DateTime? _listsRefreshedAt;

  /// Refetches the summary and every model list (a model selector opening), at most every few seconds.
  Future<void> refreshModelLists() async {
    final now = DateTime.now();
    final last = _listsRefreshedAt;
    if (last != null && now.difference(last) < const Duration(seconds: 5)) return;
    _listsRefreshedAt = now;
    await Future.wait([refreshSummary(), for (final t in allModelTypes) updateModelList(t)]);
  }

  /// Refetches what [load] loaded (after the settings closed).
  Future<void> reload() {
    _rules.clear();
    return Future.wait([updateModelProviders(), load()]);
  }

  /// The workspace's providers and model lists for the model selector.
  ModelCatalog get catalog => ModelCatalog(
    providers: providers,
    modelLists: {for (final t in allModelTypes) t: modelList(t)},
    language: language,
  );

  /// The editor's default model per model type, `mode` from the model's properties in its list.
  Map<String, ({String provider, String model, String? mode})> get defaultModelsMap {
    final out = <String, ({String provider, String model, String? mode})>{};
    for (final t in defaultModelTypes) {
      final d = _defaults[t];
      if (d == null) continue;
      final provider = (d['provider'] as Map?)?['provider'];
      final model = d['model'];
      if (provider is! String || model is! String) continue;
      final item = getCurrentProviderAndModel(modelList(t), (provider: provider, model: model)).currentModel;
      final mode = item?.mode;
      out[t] = (provider: provider, model: model, mode: mode == null || mode.isEmpty ? null : mode);
    }
    return out;
  }

  // ----- writes (the settings) -----

  /// PATCH `models/enable` / `disable`.
  Future<void> setModelEnabled(String provider, ModelItem model, bool enabled) => enabled
      ? _api.enableModel(provider, model: model.model, modelType: model.modelType)
      : _api.disableModel(provider, model: model.model, modelType: model.modelType);

  /// The credential API (owner/admin): see [ModelProvidersApi].
  ModelProvidersApi get credentials => _api;

  // ----- icons -----

  /// The provider icons (fetched through the API, once).
  late final ProviderIconSource icons = CachedProviderIconSource((url) async => api?.icon(url));

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
