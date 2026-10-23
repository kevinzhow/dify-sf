import 'dart:convert';

import '../auth/account.dart';
import '../client/transport.dart';
import '../providers/model_providers_api.dart';
import 'model_providers_fixture.dart';

/// An in-memory [ModelProvidersApi] with the server's rules (protocol 1.9) over a small fixture catalog cut from the
/// definitions the server vendors (`model_providers_fixture.dart`): OpenAI (predefined + customizable: GPT-4.1,
/// GPT-4o mini, an embedding, a TTS, a transcription and a moderation model), Anthropic (two Claude models), Ollama and
/// OpenAI-API-compatible (customizable only). Answers have the server's shapes; icon URLs are the server's relative URLs
/// and [icon] serves them.
///
/// Rules as the server: credential form check and filter (required fields, defaults, options, `show_on` with
/// `__model_type`), masks on read, the `[__HIDDEN__]` round trip, "API KEY n" names (unique, at most 30 characters),
/// the first credential becomes current, deleting the current one leaves none, deleting the last one unconfigures; custom
/// models join the list with their first credential; statuses `active` / `no-configure` / `disabled`; the default model
/// is the first active one and is kept once picked; parameter rules only with a usable credential. Custom models get a
/// generic schema here (temperature, top_p, max_tokens; mode and context size from the credentials); the server ports
/// the plugins' own schemas.
///
/// [role] is the caller's role (only `owner` and `admin` write, read credentials and validate; others get
/// `403 forbidden`; [asRole] gives another member's view of the same workspace). [validator] decides whether credentials are accepted (return the error message, or null to accept);
/// by default a secret value starting with `bad` is refused with "Incorrect API key provided". [secretsKeyMissing] makes
/// credential writes fail like a server without a secrets key (`503 secrets_key_missing`). [requests] counts calls.
class FakeModelProvidersApi implements ModelProvidersApi {
  FakeModelProvidersApi({this.role = AccountRole.owner, this.validator, this.secretsKeyMissing = false})
    : _s = _FakeState();

  FakeModelProvidersApi._shared(this._s, this.role, this.validator, this.secretsKeyMissing);

  /// The same workspace seen by a member with another [role] (shares every setting and credential with this one).
  FakeModelProvidersApi asRole(String role) => FakeModelProvidersApi._shared(_s, role, validator, secretsKeyMissing);

  String role;
  String? Function(String provider, Map<String, Object?> credentials)? validator;
  bool secretsKeyMissing;

  final _FakeState _s;

  /// Calls so far (of every role's view), by method name (`summaries`, `createProviderCredential`, ...).
  Map<String, int> get requests => _s.requests;

  List<Map<String, Object?>> get _catalog => _s.catalog;
  Map<String, List<_Cred>> get _providerCreds => _s.providerCreds;
  Set<String> get _configured => _s.configured;
  Map<String, String> get _current => _s.current;
  Map<String, List<_Cred>> get _modelCreds => _s.modelCreds;
  List<String> get _customModels => _s.customModels;
  Map<String, String> get _customCurrent => _s.customCurrent;
  Map<String, bool> get _settings => _s.settings;
  Map<String, ({String provider, String model})> get _defaults => _s.defaults;

  // ----- helpers -----

  void _count(String name) => requests[name] = (requests[name] ?? 0) + 1;

  static String _key(String provider, String model, String type) => '$provider\u0000$model\u0000$type';
  static ({String provider, String model, String type}) _unkey(String k) {
    final p = k.split('\u0000');
    return (provider: p[0], model: p[1], type: p[2]);
  }

  Never _fail(int status, String code, String message) =>
      throw TransportException(message, statusCode: status, code: code);

  void _privileged() {
    if (!AccountRole.isPrivileged(role)) _fail(403, 'forbidden', 'only the workspace owner or an admin may do this');
  }

  void _needKey() {
    if (secretsKeyMissing) {
      _fail(
        503,
        'secrets_key_missing',
        'the server has no secrets key (COLLAB_SECRETS_KEY), so it cannot store secrets',
      );
    }
  }

  Map<String, Object?> _def(String provider) => _catalog.firstWhere(
    (p) => p['provider'] == provider,
    orElse: () => _fail(404, 'not_found', 'Provider $provider does not exist.'),
  );

  void _type(String t) {
    if (!ModelProviderModelTypes.all.contains(t)) {
      _fail(400, 'bad_request', 'model_type must be one of ${ModelProviderModelTypes.all.join(', ')}');
    }
  }

  void _name(String? name) {
    if (name != null && name.length > 30) _fail(400, 'bad_request', 'name must be at most 30 characters');
  }

  static List<Map<String, Object?>> _schemas(Map<String, Object?> def, {required bool model}) {
    final s = def[model ? 'model_credential_schema' : 'provider_credential_schema'];
    if (s is! Map<String, Object?>) return const [];
    return [for (final f in s['credential_form_schemas']! as List<Object?>) f! as Map<String, Object?>];
  }

  static Set<String> _secrets(Map<String, Object?> def, {required bool model}) => {
    for (final f in _schemas(def, model: model))
      if (f['type'] == 'secret-input') f['variable']! as String,
  };

  /// Dify's `obfuscated_token`.
  static String mask(String token) {
    final r = token.runes.toList();
    if (r.isEmpty) return token;
    if (r.length <= 8) return '*' * 20;
    return '${String.fromCharCodes(r.sublist(0, 6))}${'*' * 12}${String.fromCharCodes(r.sublist(r.length - 2))}';
  }

  static Map<String, Object?> _masked(Map<String, Object?> c, Set<String> secrets) => {
    for (final e in c.entries) e.key: secrets.contains(e.key) && e.value is String ? mask(e.value! as String) : e.value,
  };

  static bool _truthy(Object? v) =>
      !(v == null || v == false || v == '' || v == 0 || (v is List && v.isEmpty) || (v is Map && v.isEmpty));

  /// graphon's CommonValidator (see the server's `Credentials.validateAndFilter`).
  Map<String, Object?> _filter(Map<String, Object?> def, Map<String, Object?> input, {String? modelType}) {
    final model = modelType != null;
    if (def[model ? 'model_credential_schema' : 'provider_credential_schema'] == null) {
      _fail(
        400,
        'bad_request',
        'Provider ${def['provider']} does not have ${model ? 'model' : 'provider'}_credential_schema',
      );
    }
    final c = {...input, '__model_type': ?modelType};
    final out = <String, Object?>{};
    for (final f in _schemas(def, model: model)) {
      final variable = f['variable']! as String;
      final showOn = (f['show_on'] as List<Object?>?) ?? const [];
      final shown = showOn.every((s) {
        final m = s! as Map<String, Object?>;
        return c.containsKey(m['variable']) && c[m['variable']] == m['value'];
      });
      if (!shown) continue;
      final value = c[variable];
      if (!_truthy(value)) {
        if (f['required'] == true) _fail(400, 'bad_request', 'Variable $variable is required');
        final d = f['default'];
        if (d is String && d.isNotEmpty) out[variable] = d;
        continue;
      }
      if (value is! String) _fail(400, 'bad_request', 'Variable $variable should be string');
      final max = f['max_length'] as int? ?? 0;
      if (max > 0 && value.runes.length > max) {
        _fail(400, 'bad_request', 'Variable $variable length should not be greater than $max');
      }
      final type = f['type'];
      final options = (f['options'] as List<Object?>?) ?? const [];
      if ((type == 'select' || type == 'radio') &&
          options.isNotEmpty &&
          !options.any((o) => (o! as Map<String, Object?>)['value'] == value)) {
        _fail(400, 'bad_request', 'Variable $variable is not in options');
      }
      if (type == 'switch') {
        if (!['true', 'false'].contains(value.toLowerCase())) {
          _fail(400, 'bad_request', 'Variable $variable should be true or false');
        }
        out[variable] = value.toLowerCase() == 'true';
        continue;
      }
      out[variable] = value;
    }
    return out;
  }

  String? _check(String provider, Map<String, Object?> credentials, Set<String> secrets) {
    if (validator != null) return validator!(provider, credentials);
    for (final s in secrets) {
      final v = credentials[s];
      if (v is String && v.startsWith('bad')) return 'Incorrect API key provided (HTTP 401)';
    }
    return null;
  }

  Map<String, Object?> _checked(Map<String, Object?> def, Map<String, Object?> input, {String? modelType}) {
    final filtered = _filter(def, input, modelType: modelType);
    final reason = _check(def['provider']! as String, filtered, _secrets(def, model: modelType != null));
    if (reason != null) _fail(400, 'credential_validation_failed', reason);
    return filtered;
  }

  static Map<String, Object?> _restoreHidden(
    Map<String, Object?> input,
    Map<String, Object?> stored,
    Set<String> secrets,
  ) => {
    for (final e in input.entries)
      e.key: secrets.contains(e.key) && e.value == hiddenSecret && stored.containsKey(e.key) ? stored[e.key] : e.value,
  };

  static String _nextName(Iterable<_Cred> creds) {
    final re = RegExp(r'^API KEY\s+(\d+)$');
    var max = 0;
    for (final c in creds) {
      final m = re.firstMatch(c.name.trim());
      if (m != null && int.parse(m.group(1)!) > max) max = int.parse(m.group(1)!);
    }
    return 'API KEY ${max + 1}';
  }

  String _newId() => '00000000-0000-4000-8000-${(++_s.ids).toString().padLeft(12, '0')}';

  Map<String, Object?>? _icons(Map<String, Object?> def, String kind) {
    final icons = def['icons']! as Map<String, Object?>;
    if (icons[kind] == null) return null;
    final prefix = '/v1/workspace/model-providers/${def['provider']}/$kind';
    return {'en_US': '$prefix/en_US', 'zh_Hans': '$prefix/zh_Hans'};
  }

  static List<Map<String, Object?>> _refs(List<_Cred> creds) => [
    for (final c in creds) {'credential_id': c.id, 'credential_name': c.name},
  ];

  Map<String, Object?>? _currentConfig(String provider) {
    final id = _current[provider];
    if (id == null) return null;
    for (final c in _providerCreds[provider] ?? const <_Cred>[]) {
      if (c.id == id) return c.config.isEmpty ? null : c.config;
    }
    return null;
  }

  Map<String, Object?>? _customConfig(String key) {
    final id = _customCurrent[key];
    if (id == null) return null;
    for (final c in _modelCreds[key] ?? const <_Cred>[]) {
      if (c.id == id) return c.config;
    }
    return null;
  }

  List<String> _unadded(String provider) => [
    for (final k in _modelCreds.keys.toList()..sort())
      if (_unkey(k).provider == provider && !_customModels.contains(k)) k,
  ];

  bool _hasCustom(String provider) =>
      _customModels.any((k) => _unkey(k).provider == provider) ||
      _modelCreds.keys.any((k) => _unkey(k).provider == provider);

  /// The generic custom-model schema of this fake.
  static Map<String, Object?>? _customSchema(String model, String type, Map<String, Object?>? c) {
    if (c == null || c.isEmpty) return null;
    final context = int.tryParse('${c['context_size'] ?? (type == 'llm' ? 4096 : 512)}');
    if (context == null) return null;
    Map<String, Object?> tmpl(String name, String template, [Map<String, Object?> extra = const {}]) =>
        _rule({'name': name, 'use_template': template, ...extra});
    return {
      'model': model,
      'label': {'en_US': model, 'zh_Hans': model},
      'model_type': type,
      'features': type == 'llm' ? <String>[] : null,
      'fetch_from': 'customizable-model',
      'model_properties': type == 'llm'
          ? {'mode': c['mode'] ?? 'chat', 'context_size': context}
          : {'context_size': context},
      'deprecated': false,
      'parameter_rules': type == 'llm'
          ? [
              tmpl('temperature', 'temperature'),
              tmpl('top_p', 'top_p'),
              tmpl('max_tokens', 'max_tokens', {
                if (c['max_tokens'] != null) 'max': double.tryParse('${c['max_tokens']}'),
              }),
            ]
          : <Map<String, Object?>>[],
    };
  }

  static const _templates = <String, Map<String, Object?>>{
    'temperature': {
      'label': {'en_US': 'Temperature', 'zh_Hans': '温度'},
      'type': 'float',
      'default': 0.0,
      'min': 0.0,
      'max': 1.0,
      'precision': 2,
    },
    'top_p': {
      'label': {'en_US': 'Top P', 'zh_Hans': 'Top P'},
      'type': 'float',
      'default': 1.0,
      'min': 0.0,
      'max': 1.0,
      'precision': 2,
    },
    'max_tokens': {
      'label': {'en_US': 'Max Tokens', 'zh_Hans': '最大标记'},
      'type': 'int',
      'default': 64,
      'min': 1.0,
      'max': 2048.0,
      'precision': 0,
    },
  };

  static Map<String, Object?> _rule(Map<String, Object?> raw) {
    final d = {...?_templates[raw['use_template']], ...raw};
    return {
      'name': d['name'],
      'use_template': d['use_template'],
      'label': d['label'] ?? {'en_US': d['name'], 'zh_Hans': d['name']},
      'type': d['type'],
      'help': d['help'],
      'required': d['required'] ?? false,
      'default': d['default'],
      'min': d['min'],
      'max': d['max'],
      'precision': d['precision'],
      'options': d['options'] ?? <String>[],
    };
  }

  /// The server's `modelEntries`: (model JSON without status, status), sorted by (type, position).
  List<(Map<String, Object?>, String)> _models(Map<String, Object?> def, {String? type}) {
    final provider = def['provider']! as String;
    final supported = [for (final t in def['supported_model_types']! as List<Object?>) t! as String];
    final types = type == null ? supported : [type];
    final config = _currentConfig(provider);
    final out = <(Map<String, Object?>, String)>[];
    for (final t in types) {
      if (!supported.contains(t)) continue;
      for (final m in def['models']! as List<Object?>) {
        final model = m! as Map<String, Object?>;
        if (model['model_type'] != t) continue;
        var status = config != null ? 'active' : 'no-configure';
        if (_settings[_key(provider, model['model']! as String, t)] == false) status = 'disabled';
        out.add((model, status));
      }
    }
    for (final k in _customModels) {
      final key = _unkey(k);
      if (key.provider != provider || !types.contains(key.type)) continue;
      final schema = _customSchema(key.model, key.type, _customConfig(k));
      if (schema == null) continue;
      out.add((schema, _settings[k] == false ? 'disabled' : 'active'));
    }
    final positions = (def['positions']! as Map<String, Object?>);
    int pos((Map<String, Object?>, String) e) {
      final list = (positions[e.$1['model_type']] as List<Object?>?) ?? const [];
      final i = list.indexOf(e.$1['model']);
      return i < 0 ? list.length : i;
    }

    final indexed = out.indexed.toList()
      ..sort((a, b) {
        final ta = a.$2.$1['model_type']! as String, tb = b.$2.$1['model_type']! as String;
        if (ta != tb) return ta.compareTo(tb);
        final pa = pos(a.$2), pb = pos(b.$2);
        return pa != pb ? pa.compareTo(pb) : a.$1.compareTo(b.$1);
      });
    return [for (final e in indexed) e.$2];
  }

  Map<String, Object?> _modelJson((Map<String, Object?>, String) e, {Map<String, Object?>? provider}) => {
    'model': e.$1['model'],
    'label': e.$1['label'],
    'model_type': e.$1['model_type'],
    'features': e.$1['features'],
    'fetch_from': e.$1['fetch_from'],
    'model_properties': e.$1['model_properties'],
    'deprecated': e.$1['deprecated'] ?? false,
    'status': e.$2,
    'load_balancing_enabled': false,
    'has_invalid_load_balancing_configs': false,
    if (provider != null) 'provider': _simpleProvider(provider),
  };

  Map<String, Object?> _simpleProvider(Map<String, Object?> def, {bool dark = true}) => {
    'provider': def['provider'],
    'provider_name': '',
    'label': def['label'],
    'icon_small': _icons(def, 'icon_small'),
    'icon_small_dark': dark ? _icons(def, 'icon_small_dark') : null,
    'supported_model_types': def['supported_model_types'],
    'models': <Object?>[],
  };

  _Cred _providerCred(String provider, String id) => (_providerCreds[provider] ?? const <_Cred>[]).firstWhere(
    (c) => c.id == id,
    orElse: () => _fail(404, 'not_found', 'Credential record not found.'),
  );

  _Cred _modelCred(String key, String id) => (_modelCreds[key] ?? const <_Cred>[]).firstWhere(
    (c) => c.id == id,
    orElse: () => _fail(404, 'not_found', 'Credential record not found.'),
  );

  // ----- reads -----

  @override
  Future<List<Map<String, Object?>>> summaries() async {
    _count('summaries');
    return [
      for (final def in _catalog) _summary(def),
    ];
  }

  Map<String, Object?> _summary(Map<String, Object?> def) {
    final p = def['provider']! as String;
    final creds = _providerCreds[p] ?? const <_Cred>[];
    final configured = (_configured.contains(p) && creds.isNotEmpty) || _hasCustom(p);
    final currentId = _current[p];
    final current = creds.where((c) => c.id == currentId).firstOrNull;
    return {
      'provider': p,
      'plugin_id': p.split('/').take(2).join('/'),
      'label': def['label'],
      'description': def['description'],
      'icon_small': _icons(def, 'icon_small'),
      'icon_small_dark': _icons(def, 'icon_small_dark'),
      'supported_model_types': def['supported_model_types'],
      'configurate_methods': def['configurate_methods'],
      'preferred_provider_type': 'custom',
      'is_configured': configured,
      'custom_configuration': {
        'status': configured ? 'active' : 'no-configure',
        'has_custom_models': _hasCustom(p),
        'available_credentials': _refs(creds),
        'current_credential_id': currentId,
        'current_credential_name': current?.name,
        'current_credential_usable': current != null,
      },
      'system_configuration': {'enabled': false},
    };
  }

  @override
  Future<List<Map<String, Object?>>> providers({String? modelType}) async {
    _count('providers');
    if (modelType != null) _type(modelType);
    return [
      for (final def in _catalog)
        if (modelType == null || (def['supported_model_types']! as List<Object?>).contains(modelType)) _provider(def),
    ];
  }

  Map<String, Object?> _provider(Map<String, Object?> def) {
    final p = def['provider']! as String;
    final creds = _providerCreds[p] ?? const <_Cred>[];
    final record = _configured.contains(p);
    final custom = [
      for (final k in _customModels)
        if (_unkey(k).provider == p) (k, false),
      for (final k in _unadded(p)) (k, true),
    ];
    final currentId = _current[p];
    return {
      'provider': p,
      'label': def['label'],
      'description': def['description'],
      'icon_small': _icons(def, 'icon_small'),
      'icon_small_dark': _icons(def, 'icon_small_dark'),
      'background': def['background'],
      'help': def['help'],
      'supported_model_types': def['supported_model_types'],
      'configurate_methods': def['configurate_methods'],
      'provider_credential_schema': def['provider_credential_schema'],
      'model_credential_schema': def['model_credential_schema'],
      'preferred_provider_type': 'custom',
      'custom_configuration': {
        'status': (record && creds.isNotEmpty) || custom.isNotEmpty ? 'active' : 'no-configure',
        'current_credential_id': record ? currentId : null,
        'current_credential_name': creds.where((c) => c.id == currentId).firstOrNull?.name,
        'available_credentials': record ? _refs(creds) : <Object?>[],
        'custom_models': [
          for (final (k, unadded) in custom)
            {
              'model': _unkey(k).model,
              'model_type': _unkey(k).type,
              'credentials': null,
              'current_credential_id': unadded ? null : _customCurrent[k],
              'current_credential_name': unadded
                  ? null
                  : (_modelCreds[k] ?? const <_Cred>[]).where((c) => c.id == _customCurrent[k]).firstOrNull?.name,
              'available_model_credentials': _refs(_modelCreds[k] ?? const []),
              'unadded_to_model_list': unadded,
            },
        ],
        'can_added_models': [
          for (final (k, unadded) in custom)
            if (unadded) {'model': _unkey(k).model, 'model_type': _unkey(k).type},
        ],
      },
      'system_configuration': {'enabled': false, 'current_quota_type': null, 'quota_configurations': <Object?>[]},
    };
  }

  @override
  Future<List<Map<String, Object?>>> modelsOfType(String modelType) async {
    _count('modelsOfType');
    _type(modelType);
    final out = <Map<String, Object?>>[];
    for (final def in _catalog) {
      final list = [
        for (final e in _models(def, type: modelType))
          if (e.$2 == 'active' && e.$1['deprecated'] != true) e,
      ];
      if (list.isEmpty) continue;
      out.add({
        'provider': def['provider'],
        'label': def['label'],
        'icon_small': _icons(def, 'icon_small'),
        'icon_small_dark': _icons(def, 'icon_small_dark'),
        'status': 'active',
        'models': [for (final e in list) _modelJson(e)],
      });
    }
    return out;
  }

  @override
  Future<Map<String, Object?>?> defaultModel(String modelType) async {
    _count('defaultModel');
    _type(modelType);
    var chosen = _defaults[modelType];
    if (chosen == null) {
      for (final def in _catalog) {
        final first = _models(def, type: modelType).where((e) => e.$2 == 'active').firstOrNull;
        if (first != null) {
          chosen = _defaults[modelType] = (provider: def['provider']! as String, model: first.$1['model']! as String);
          break;
        }
      }
    }
    if (chosen == null) return null;
    return {
      'model': chosen.model,
      'model_type': modelType,
      'provider': _simpleProvider(_def(chosen.provider), dark: false),
    };
  }

  @override
  Future<List<Map<String, Object?>>> parameterRules(String provider, String model) async {
    _count('parameterRules');
    final def = _def(provider);
    final key = _key(provider, model, 'llm');
    if (_settings[key] == false) _fail(400, 'bad_request', 'Model $model is disabled.');
    final custom = _customModels.contains(key) ? _customConfig(key) : null;
    final credentials = (custom != null && custom.isNotEmpty) ? custom : _currentConfig(provider);
    if (credentials == null) return [];
    for (final m in def['models']! as List<Object?>) {
      final mm = m! as Map<String, Object?>;
      if (mm['model'] == model && mm['model_type'] == 'llm') {
        return [for (final r in mm['parameter_rules']! as List<Object?>) r! as Map<String, Object?>];
      }
    }
    final schema = custom == null ? null : _customSchema(model, 'llm', custom);
    return schema == null
        ? []
        : [for (final r in schema['parameter_rules']! as List<Object?>) r! as Map<String, Object?>];
  }

  @override
  Future<List<Map<String, Object?>>> providerModels(String provider) async {
    _count('providerModels');
    final def = _def(provider);
    return [for (final e in _models(def)) _modelJson(e, provider: def)];
  }

  // ----- writes -----

  @override
  Future<void> setDefaultModels(List<DefaultModelSetting> settings) async {
    _count('setDefaultModels');
    _privileged();
    for (final s in settings) {
      _type(s.modelType);
      final provider = s.provider;
      if (provider == null) continue;
      if (!_catalog.any((p) => p['provider'] == provider)) {
        _fail(400, 'bad_request', 'Provider $provider does not exist.');
      }
      final active = [
        for (final def in _catalog)
          for (final e in _models(def, type: s.modelType))
            if (e.$2 == 'active') e.$1['model'],
      ];
      if (s.model == null || !active.contains(s.model)) {
        _fail(400, 'bad_request', 'Model ${s.model ?? ''} does not exist.');
      }
      _defaults[s.modelType] = (provider: provider, model: s.model!);
    }
  }

  @override
  Future<void> enableModel(String provider, {required String model, required String modelType}) async {
    _count('enableModel');
    _privileged();
    _def(provider);
    _type(modelType);
    _settings[_key(provider, model, modelType)] = true;
  }

  @override
  Future<void> disableModel(String provider, {required String model, required String modelType}) async {
    _count('disableModel');
    _privileged();
    _def(provider);
    _type(modelType);
    _settings[_key(provider, model, modelType)] = false;
  }

  @override
  Future<Map<String, Object?>> providerCredentials(String provider, {String? credentialId}) async {
    _count('providerCredentials');
    _privileged();
    final def = _def(provider);
    final values = credentialId != null
        ? _providerCred(provider, credentialId).config
        : (_currentConfig(provider) ?? const {});
    return _masked(values, _secrets(def, model: false));
  }

  @override
  Future<void> createProviderCredential(
    String provider, {
    required Map<String, Object?> credentials,
    String? name,
  }) async {
    _count('createProviderCredential');
    _privileged();
    final def = _def(provider);
    _name(name);
    _needKey();
    final creds = _providerCreds.putIfAbsent(provider, () => []);
    if (name != null && name.isNotEmpty && creds.any((c) => c.name == name)) {
      _fail(409, 'credential_name_exists', "Credential with name '$name' already exists.");
    }
    final checked = _checked(def, credentials);
    final cred = _Cred(_newId(), name == null || name.isEmpty ? _nextName(creds) : name, checked, ++_s.clock);
    creds.insert(0, cred);
    _configured.add(provider);
    _current.putIfAbsent(provider, () => cred.id);
  }

  @override
  Future<void> updateProviderCredential(
    String provider, {
    required String credentialId,
    required Map<String, Object?> credentials,
    String? name,
  }) async {
    _count('updateProviderCredential');
    _privileged();
    final def = _def(provider);
    _name(name);
    _needKey();
    final cred = _providerCred(provider, credentialId);
    if (name != null &&
        name.isNotEmpty &&
        _providerCreds[provider]!.any((c) => c.name == name && c.id != credentialId)) {
      _fail(409, 'credential_name_exists', "Credential with name '$name' already exists.");
    }
    cred.config = _checked(def, _restoreHidden(credentials, cred.config, _secrets(def, model: false)));
    if (name != null && name.isNotEmpty) cred.name = name;
  }

  @override
  Future<void> deleteProviderCredential(String provider, {required String credentialId}) async {
    _count('deleteProviderCredential');
    _privileged();
    _def(provider);
    final creds = _providerCreds[provider] ?? [];
    _providerCred(provider, credentialId);
    final wasLast = creds.length <= 1;
    creds.removeWhere((c) => c.id == credentialId);
    if (wasLast) {
      _configured.remove(provider);
      _current.remove(provider);
    } else if (_current[provider] == credentialId) {
      _current.remove(provider);
    }
  }

  @override
  Future<void> switchProviderCredential(String provider, {required String credentialId}) async {
    _count('switchProviderCredential');
    _privileged();
    _def(provider);
    _providerCred(provider, credentialId);
    if (!_configured.contains(provider)) _fail(404, 'not_found', 'Provider record not found.');
    _current[provider] = credentialId;
  }

  @override
  Future<CredentialValidation> validateProviderCredentials(
    String provider, {
    required Map<String, Object?> credentials,
  }) async {
    _count('validateProviderCredentials');
    _privileged();
    final def = _def(provider);
    final filtered = _filter(def, credentials);
    final reason = _check(provider, filtered, _secrets(def, model: false));
    return reason == null ? const CredentialValidation.success() : CredentialValidation.failure(reason);
  }

  @override
  Future<Map<String, Object?>> modelCredentials(
    String provider, {
    required String model,
    required String modelType,
    String? configFrom,
    String? credentialId,
  }) async {
    _count('modelCredentials');
    _privileged();
    final def = _def(provider);
    _type(modelType);
    final key = _key(provider, model, modelType);
    Map<String, Object?> values = const {};
    String? currentId, currentName;
    if (credentialId != null) {
      final c = _modelCred(key, credentialId);
      values = c.config;
      currentId = c.id;
      currentName = c.name;
    } else if (_customModels.contains(key) && (_customConfig(key)?.isNotEmpty ?? false)) {
      values = _customConfig(key)!;
      currentId = _customCurrent[key];
      currentName = _modelCreds[key]!.firstWhere((c) => c.id == currentId).name;
    }
    return {
      'credentials': _masked(values, _secrets(def, model: true)),
      'current_credential_id': currentId,
      'current_credential_name': currentName,
      'load_balancing': {'enabled': false, 'configs': <Object?>[]},
      'available_credentials': _refs(
        configFrom == ModelConfigFrom.predefinedModel
            ? (_providerCreds[provider] ?? const [])
            : (_modelCreds[key] ?? const []),
      ),
    };
  }

  @override
  Future<void> createModelCredential(
    String provider, {
    required String model,
    required String modelType,
    required Map<String, Object?> credentials,
    String? name,
  }) async {
    _count('createModelCredential');
    _privileged();
    final def = _def(provider);
    _type(modelType);
    _name(name);
    _needKey();
    final key = _key(provider, model, modelType);
    final creds = _modelCreds[key] ?? [];
    if (name != null && name.isNotEmpty && creds.any((c) => c.name == name)) {
      _fail(409, 'credential_name_exists', "Model credential with name '$name' already exists for $model.");
    }
    final checked = _checked(def, credentials, modelType: modelType);
    final cred = _Cred(_newId(), name == null || name.isEmpty ? _nextName(creds) : name, checked, ++_s.clock);
    _modelCreds[key] = [cred, ...creds];
    if (!_customModels.contains(key)) {
      _customModels.add(key);
      _customCurrent[key] = cred.id;
    }
  }

  @override
  Future<void> updateModelCredential(
    String provider, {
    required String model,
    required String modelType,
    required String credentialId,
    required Map<String, Object?> credentials,
    String? name,
  }) async {
    _count('updateModelCredential');
    _privileged();
    final def = _def(provider);
    _type(modelType);
    _name(name);
    _needKey();
    final key = _key(provider, model, modelType);
    final cred = _modelCred(key, credentialId);
    if (name != null && name.isNotEmpty && _modelCreds[key]!.any((c) => c.name == name && c.id != credentialId)) {
      _fail(409, 'credential_name_exists', "Model credential with name '$name' already exists for $model.");
    }
    cred.config = _checked(
      def,
      _restoreHidden(credentials, cred.config, _secrets(def, model: true)),
      modelType: modelType,
    );
    if (name != null && name.isNotEmpty) cred.name = name;
  }

  @override
  Future<void> deleteModelCredential(
    String provider, {
    required String model,
    required String modelType,
    required String credentialId,
  }) async {
    _count('deleteModelCredential');
    _privileged();
    _def(provider);
    _type(modelType);
    final key = _key(provider, model, modelType);
    _modelCred(key, credentialId);
    final creds = _modelCreds[key]!;
    final wasLast = creds.length <= 1;
    creds.removeWhere((c) => c.id == credentialId);
    if (wasLast) {
      _modelCreds.remove(key);
      _customModels.remove(key);
      _customCurrent.remove(key);
    } else if (_customCurrent[key] == credentialId) {
      _customCurrent.remove(key);
    }
  }

  @override
  Future<void> switchModelCredential(
    String provider, {
    required String model,
    required String modelType,
    required String credentialId,
  }) async {
    _count('switchModelCredential');
    _privileged();
    _def(provider);
    _type(modelType);
    final key = _key(provider, model, modelType);
    _modelCred(key, credentialId);
    if (!_customModels.contains(key)) {
      _customModels.add(key);
    } else if (_customCurrent[key] == credentialId) {
      _fail(400, 'bad_request', "Can't add same credential");
    }
    _customCurrent[key] = credentialId;
  }

  @override
  Future<CredentialValidation> validateModelCredentials(
    String provider, {
    required String model,
    required String modelType,
    required Map<String, Object?> credentials,
  }) async {
    _count('validateModelCredentials');
    _privileged();
    final def = _def(provider);
    _type(modelType);
    final filtered = _filter(def, credentials, modelType: modelType);
    final reason = _check(provider, filtered, _secrets(def, model: true));
    return reason == null ? const CredentialValidation.success() : CredentialValidation.failure(reason);
  }

  @override
  Future<void> addCustomModel(
    String provider, {
    required String model,
    required String modelType,
    required String credentialId,
  }) async {
    _count('addCustomModel');
    _privileged();
    _def(provider);
    _type(modelType);
    final key = _key(provider, model, modelType);
    _modelCred(key, credentialId);
    if (!_customModels.contains(key)) _fail(404, 'not_found', 'The custom model record not found.');
    _customCurrent[key] = credentialId;
  }

  @override
  Future<void> removeCustomModel(String provider, {required String model, required String modelType}) async {
    _count('removeCustomModel');
    _privileged();
    _def(provider);
    _type(modelType);
    final key = _key(provider, model, modelType);
    _customModels.remove(key);
    _customCurrent.remove(key);
  }

  // ----- icons -----

  @override
  Uri iconUrl(String url) => Uri.parse('http://fake.invalid').resolve(url);

  @override
  Future<ModelProviderIcon?> icon(String url) async {
    final m = RegExp(r'^/v1/workspace/model-providers/([^/]+/[^/]+/[^/]+)/(icon_small|icon_small_dark)/[^/]+$')
        .firstMatch(Uri.parse(url).path);
    if (m == null) return null;
    final def = _catalog.where((p) => p['provider'] == m.group(1)).firstOrNull;
    final svg = (def?['icons'] as Map<String, Object?>?)?[m.group(2)];
    if (svg is! String) return null;
    return ModelProviderIcon(bytes: utf8.encode(svg), contentType: 'image/svg+xml');
  }
}

class _FakeState {
  final List<Map<String, Object?>> catalog = [
    for (final p in (jsonDecode(modelProvidersFixtureJson) as Map<String, Object?>)['providers']! as List<Object?>)
      p! as Map<String, Object?>,
  ];
  final Map<String, int> requests = {};
  final Map<String, List<_Cred>> providerCreds = {};
  final Set<String> configured = {};
  final Map<String, String> current = {};
  final Map<String, List<_Cred>> modelCreds = {};
  final List<String> customModels = [];
  final Map<String, String> customCurrent = {};
  final Map<String, bool> settings = {};
  final Map<String, ({String provider, String model})> defaults = {};
  int ids = 0;
  int clock = 0;
}

class _Cred {
  _Cred(this.id, this.name, this.config, this.created);
  final String id;
  String name;
  Map<String, Object?> config;
  final int created;
}
