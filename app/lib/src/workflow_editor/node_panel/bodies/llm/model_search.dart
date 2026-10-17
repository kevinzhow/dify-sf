/// The model selector's search and filter (model-selector/model-search.ts). Fuse.js is replaced by what its options
/// amount to here: provider labels and keys match fuzzily (an approximate substring within a quarter of the query's
/// length in edits, Fuse's `threshold: 0.25` with `ignoreLocation`), model names and labels by normalized substring
/// (Fuse's extended include-match `'query`).
library;

import '../../../../workflow/model_catalog.dart';
import 'model_common.dart' show supportFunctionCall;

/// `ModelSelectorModelPredicate`.
typedef ModelPredicate = bool Function(ProviderWithModels provider, ModelItem model);

/// `normalizeModelSearchValue`: lower case, letters and digits only.
String normalizeModelSearchValue(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

/// `looksLikeModelQuery`: a query with a digit names a model, not a provider.
bool _looksLikeModelQuery(String value) => RegExp(r'\d').hasMatch(value);

/// `getLabelSearchValues`: the label in [language], else every distinct non-empty label.
List<String> _labelSearchValues(I18nText? label, String language) {
  if (label == null) return const [];
  final own = label[language];
  if (own != null && own.isNotEmpty) return [own];
  return {...label.values.whereType<String>().where((v) => v.isNotEmpty)}.toList();
}

/// `getProviderKeySearchValues`: the provider id's parts (without `langgenius`), raw and normalized.
List<String> _providerKeys(String provider) {
  final keys = provider.split('/').where((p) => p.isNotEmpty && p != 'langgenius').toList();
  return {...keys, ...keys.map(normalizeModelSearchValue)}.toList();
}

/// The fewest edits that turn [pattern] into a substring of [text] (Sellers' approximate matching).
int _substringDistance(String pattern, String text) {
  final m = pattern.length, n = text.length;
  if (m == 0) return 0;
  var prev = List<int>.filled(n + 1, 0);
  for (var i = 1; i <= m; i++) {
    final cur = List<int>.filled(n + 1, i);
    for (var j = 1; j <= n; j++) {
      final cost = pattern.codeUnitAt(i - 1) == text.codeUnitAt(j - 1) ? 0 : 1;
      final a = prev[j - 1] + cost, b = prev[j] + 1, c = cur[j - 1] + 1;
      cur[j] = a < b ? (a < c ? a : c) : (b < c ? b : c);
    }
    prev = cur;
  }
  var best = m;
  for (final d in prev) {
    if (d < best) best = d;
  }
  return best;
}

/// Fuse's match of [query] in [value] (case-insensitive, `threshold 0.25`, `minMatchCharLength 2`).
bool _fuzzy(String query, String value) {
  final q = query.toLowerCase(), v = value.toLowerCase();
  if (q.length < 2) return v.contains(q);
  return _substringDistance(q, v) / q.length <= 0.25;
}

String _modelKey(String provider, String model) => '$provider/$model';

/// `createModelSelectorSearchIndex(...).search(query)`: the providers and `provider/model` keys [query] matches.
({Set<String> providers, Set<String> models}) searchModels(
  List<ProviderWithModels> installed,
  String language,
  String query,
) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return (providers: const {}, models: const {});
  final normalized = normalizeModelSearchValue(trimmed);
  final providers = <String>{};
  if (!_looksLikeModelQuery(trimmed)) {
    for (final p in installed) {
      final values = [..._labelSearchValues(p.label, language), ..._providerKeys(p.provider)];
      if (values.any((v) => _fuzzy(trimmed, v))) providers.add(p.provider);
    }
  }
  final models = <String>{};
  if (normalized.isNotEmpty) {
    for (final p in installed) {
      for (final m in p.models) {
        final labels = {m.model, ..._labelSearchValues(m.label, language)}.map(normalizeModelSearchValue);
        if (labels.any((l) => l.contains(normalized))) models.add(_modelKey(p.provider, m.model));
      }
    }
  }
  return (providers: providers, models: models);
}

/// `modelSupportsScopeFeatures`.
bool modelSupportsScopeFeatures(ModelItem model, List<String> scopeFeatures) => scopeFeatures.every(
  (f) => f == ModelFeatureEnum.toolCall ? supportFunctionCall(model.features) : (model.features?.contains(f) ?? false),
);

/// `filterModelSelectorModels`: the providers with the models [inputValue], [scopeFeatures] and [modelPredicate]
/// keep (a provider the query names keeps all its models); empty providers go unless they can use AI credits.
/// The selected model's provider comes first.
List<ProviderWithModels> filterModelSelectorModels({
  required List<ProviderWithModels> installed,
  required String inputValue,
  required String language,
  DefaultModel? defaultModel,
  List<String> scopeFeatures = const [],
  ModelPredicate? modelPredicate,
  Set<String> aiCreditVisibleProviders = const {},
}) {
  final trimmed = inputValue.trim();
  final matches = searchModels(installed, language, trimmed);
  final out = <ProviderWithModels>[];
  for (final p in installed) {
    final providerMatched = matches.providers.contains(p.provider);
    final models = [
      for (final m in p.models)
        if ((trimmed.isEmpty || providerMatched || matches.models.contains(_modelKey(p.provider, m.model))) &&
            modelSupportsScopeFeatures(m, scopeFeatures) &&
            (modelPredicate?.call(p, m) ?? true))
          m,
    ];
    if ((trimmed.isNotEmpty && models.isEmpty) ||
        (trimmed.isEmpty && models.isEmpty && !aiCreditVisibleProviders.contains(p.provider))) {
      continue;
    }
    out.add(
      ProviderWithModels(
        provider: p.provider,
        label: p.label,
        iconSmall: p.iconSmall,
        iconSmallDark: p.iconSmallDark,
        status: p.status,
        models: models,
      ),
    );
  }
  final selected = defaultModel?.provider;
  if (selected != null && selected.isNotEmpty) {
    final first = [
      for (final p in out)
        if (p.provider == selected) p,
    ];
    return [
      ...first,
      for (final p in out)
        if (p.provider != selected) p,
    ];
  }
  return out;
}
