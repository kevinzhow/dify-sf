/// The HTTP Request node's data logic, ported from Dify 1.17.1 nodes/http: types.ts, default.ts (defaultValue),
/// utils.ts (`transformToBodyPayload`), hooks/use-key-value-list.ts (headers / params as `key:value` lines),
/// components/curl-parser.ts (`parseCurl`), edit-body (body type changes, supported variables) and use-config.ts (the
/// data-ready hydration and the cURL import). Data is Dify's plain JSON.
library;

import '../../../../../workflow/dify_json.dart';
import '../../../../../workflow/var_types.dart';

/// `Method`.
const httpMethods = ['get', 'post', 'head', 'patch', 'put', 'delete'];

/// `BodyType`, in the panel's order, with the labels edit-body shows (`bodyTextMap`).
const httpBodyTypes = [
  ('none', 'none'),
  ('form-data', 'form-data'),
  ('x-www-form-urlencoded', 'x-www-form-urlencoded'),
  ('json', 'JSON'),
  ('raw-text', 'raw'),
  ('binary', 'binary'),
];

/// form-data / x-www-form-urlencoded: bodies of `key: value` rows.
bool isKeyValueBody(Object? type) => type == 'form-data' || type == 'x-www-form-urlencoded';

/// default.ts `defaultValue`.
const httpDefaultValue = <String, Object?>{
  'variables': <Object?>[],
  'method': 'get',
  'url': '',
  'authorization': {'type': 'no-auth', 'config': null},
  'headers': '',
  'params': '',
  'body': {'type': 'none', 'data': <Object?>[]},
  'ssl_verify': true,
  'timeout': {'max_connect_timeout': 0, 'max_read_timeout': 0, 'max_write_timeout': 0},
  'retry_config': {'retry_enabled': true, 'max_retries': 3, 'retry_interval': 100},
};

/// `HTTP_BODY_VARIABLE_TYPES` (edit-body/supported-body-vars.ts): what raw-text / JSON bodies may reference.
const httpBodyVariableTypes = [
  VarType.string,
  VarType.number,
  VarType.secret,
  VarType.object,
  VarType.arrayNumber,
  VarType.arrayString,
  VarType.arrayObject,
];

/// `isSupportedHttpBodyVariable`.
bool isSupportedHttpBodyVariable(String? type) => httpBodyVariableTypes.contains(type);

/// The URL, header, param and API-key inputs' variables (`filterVar` of use-config / api-input / input-item).
const httpTextVariableTypes = {VarType.string, VarType.number, VarType.secret};

/// `transformToBodyPayload` (utils.ts): a legacy string body as BodyPayload.
List<Map<String, Object?>> transformToBodyPayload(String old, bool hasKey) {
  if (!hasKey) {
    return [
      {'type': 'text', 'value': old},
    ];
  }
  return [
    for (final item in old.split('\n'))
      () {
        final parts = item.split(':');
        return {'key': parts.first, 'type': 'text', 'value': parts.skip(1).join(':')};
      }(),
  ];
}

/// use-config's data-ready step: `{...defaultConfig, ...inputs}` with a legacy string `body.data` turned into a
/// BodyPayload and a missing one into `[]`. [defaultConfig] is the server's block default (`nodesDefaultConfigs`), the
/// node default when there is none.
Map<String, Object?> hydrateHttpInputs(Map<String, Object?> inputs, [Map<String, Object?>? defaultConfig]) {
  final next = {...(defaultConfig ?? httpDefaultValue), ...inputs};
  final body = next['body'];
  if (body is Map) {
    final data = body['data'];
    if (data is String) {
      next['body'] = {...body, 'data': transformToBodyPayload(data, isKeyValueBody(body['type']))};
    } else if (!jsTruthy(data)) {
      next['body'] = {...body, 'data': <Object?>[]};
    }
  }
  return next;
}

/// The body after choosing [type] (edit-body `handleTypeChange`): key-value types get one blank text row, the others
/// no data; the previous data is dropped.
Map<String, Object?> bodyOfType(String type, {String Function()? newId}) => {
  'type': type,
  'data': isKeyValueBody(type)
      ? [
          {'id': newId?.call() ?? keyValueId(), 'type': 'text', 'key': '', 'value': ''},
        ]
      : <Object?>[],
};

/// `handleBodyValueChange`: raw-text / JSON text goes into `data[0].value` (a text entry is made when there is none).
Map<String, Object?> bodyWithValue(Map<String, Object?> body, String value) {
  final data = [
    for (final d in jsList(body['data'])) d is Map ? {...d} : d,
  ];
  if (data.isEmpty) data.add({'id': keyValueId(), 'type': 'text', 'key': '', 'value': ''});
  (data[0] as Map)['value'] = value;
  return {...body, 'data': data};
}

/// `handleFileChange`: the binary body's file selector goes into `data[0].file`.
Map<String, Object?> bodyWithFile(Map<String, Object?> body, List<String> file) {
  final data = [
    for (final d in jsList(body['data'])) d is Map ? {...d} : d,
  ];
  if (data.isEmpty) data.add({'id': keyValueId(), 'type': 'file'});
  (data[0] as Map)['file'] = file;
  return {...body, 'data': data};
}

/// The body's rows, `[]` for a legacy string (edit-body `bodyPayload`).
List<Map<String, Object?>> bodyPayloadOf(Object? body) => [
  for (final d in jsList(jsGet(body, 'data')))
    if (d is Map) d.cast<String, Object?>(),
];

// ---- key / value lists (use-key-value-list.ts) ------------------------------------------------------------------

var _uniqueId = 0;

/// `uniqueId('key-value-')`.
String keyValueId() => 'key-value-${++_uniqueId}';

/// A headers / params / form-data row (`KeyValue`): text rows have [value], form-data file rows [file].
final class KeyValueItem {
  KeyValueItem({String? id, this.key = '', this.value = '', this.type, this.file}) : id = id ?? keyValueId();

  factory KeyValueItem.fromJson(Map<String, Object?> json) => KeyValueItem(
    id: jsStr(json['id']),
    key: jsStr(json['key']) ?? '',
    value: jsStr(json['value']) ?? '',
    type: jsStr(json['type']),
    file: json['file'] is List ? [for (final s in jsList(json['file'])) '$s'] : null,
  );

  final String id;
  final String key, value;
  final String? type;
  final List<String>? file;

  KeyValueItem copyWith({String? key, String? value, String? type, List<String>? file}) => KeyValueItem(
    id: id,
    key: key ?? this.key,
    value: value ?? this.value,
    type: type ?? this.type,
    file: file ?? this.file,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'key': key,
    'type': ?type,
    if (type != 'file') 'value': value,
    'file': ?file,
  };

  @override
  String toString() => '$key:$value';
}

/// `strToKeyValueList`: `key:value` lines, split on the first colon, trimmed.
List<KeyValueItem> strToKeyValueList(String value) => [
  for (final line in value.split('\n'))
    () {
      final parts = line.split(':');
      return KeyValueItem(key: parts.first.trim(), value: parts.skip(1).join(':').trim());
    }(),
];

/// `stringifyList`: rows as `key:value` lines; rows missing a key or a value are dropped unless [noFilter].
String stringifyKeyValueList(List<KeyValueItem> items, {bool noFilter = false}) => [
  for (final i in items)
    if (noFilter || (i.key.isNotEmpty && i.value.isNotEmpty)) '${i.key}:${i.value}',
].join('\n');

// ---- cURL import (curl-parser.ts) -------------------------------------------------------------------------------

String _strip(String v) => v.replaceAll(RegExp(r'''^['"]|['"]$'''), '');

/// `parseCurl`: the node a cURL command describes (method, url, headers, params, body), or the error.
({Map<String, Object?>? node, String? error}) parseCurl(String curl) {
  if (!curl.trim().toLowerCase().startsWith('curl')) {
    return (node: null, error: 'Invalid cURL command. Command must start with "curl".');
  }
  final node = <String, Object?>{
    'title': 'HTTP Request',
    'desc': 'Imported from cURL',
    'method': null,
    'url': '',
    'headers': '',
    'params': '',
    'body': <String, Object?>{'type': 'none', 'data': ''},
  };
  final args = [for (final m in RegExp(r'''(?:[^\s"']|"[^"]*"|'[^']*')+''').allMatches(curl)) m[0]!];
  var hasData = false;
  String? next(int i) => i + 1 >= args.length ? null : _strip(args[i + 1]);
  void addHeader(String h) =>
      node['headers'] = '${node['headers']}${(node['headers']! as String).isEmpty ? '' : '\n'}$h';

  for (var i = 1; i < args.length; i++) {
    final arg = _strip(args[i]);
    if (arg == '-X' || arg == '--request') {
      final v = next(i);
      if (v == null) return (node: null, error: 'Missing HTTP method after -X or --request.');
      node['method'] = v.isEmpty ? 'get' : v.toLowerCase();
      hasData = true;
      i++;
    } else if (arg == '-H' || arg == '--header') {
      final v = next(i);
      if (v == null) return (node: null, error: 'Missing header value after -H or --header.');
      addHeader(v);
      i++;
    } else if (const {'-d', '--data', '--data-raw', '--data-binary'}.contains(arg)) {
      final v = next(i);
      if (v == null) {
        return (node: null, error: 'Missing data value after -d, --data, --data-raw, or --data-binary.');
      }
      node['body'] = {
        'type': 'raw-text',
        'data': [
          {'type': 'text', 'value': v},
        ],
      };
      i++;
    } else if (arg == '-F' || arg == '--form') {
      final v = next(i);
      if (v == null) return (node: null, error: 'Missing form data after -F or --form.');
      if (jsGet(node['body'], 'type') != 'form-data') node['body'] = <String, Object?>{'type': 'form-data', 'data': ''};
      final parts = v.split('=');
      final key = parts.first;
      if (key.isEmpty) return (node: null, error: 'Invalid form data format.');
      var value = parts.skip(1).join('=');
      final typed = RegExp(r'^(.+?);type=(.+)$').firstMatch(value);
      if (typed != null) {
        value = typed[1]!;
        addHeader('Content-Type: ${typed[2]}');
      }
      final body = node['body']! as Map<String, Object?>;
      final data = jsStr(body['data']) ?? '';
      body['data'] = '$data${data.isEmpty ? '' : '\n'}$key:$value';
      i++;
    } else if (arg == '--json') {
      final v = next(i);
      if (v == null) return (node: null, error: 'Missing JSON data after --json.');
      node['body'] = {'type': 'json', 'data': v};
      i++;
    } else if (arg.startsWith('http') && (node['url']! as String).isEmpty) {
      node['url'] = arg;
    }
  }
  node['method'] ??= hasData ? 'post' : 'get';
  final url = node['url']! as String;
  if (url.isEmpty) return (node: null, error: 'Missing URL or url not start with http.');
  final parts = url.split('?');
  if (parts.length > 1) {
    node['url'] = parts[0];
    node['params'] = parts[1].replaceAll('&', '\n').replaceAll('=', ': ');
  }
  return (node: node, error: null);
}

/// `handleCurlImport`: the fields a cURL import overwrites (authorization, timeout and SSL stay).
Map<String, Object?> curlImportPatch(Map<String, Object?> imported) => {
  for (final k in const ['method', 'url', 'headers', 'params', 'body']) k: imported[k],
};

// ---- authorization (components/authorization) -------------------------------------------------------------------

/// `handleAuthTypeChange`: the type, with a basic API-key config made when choosing api-key without one (switching
/// back to none keeps the config).
Map<String, Object?> authorizationWithType(Map<String, Object?> auth, String type) => {
  ...auth,
  'type': type,
  if (type == 'api-key' && !jsTruthy(auth['config'])) 'config': {'type': 'basic', 'api_key': ''},
};

/// `handleAuthAPITypeChange` / `handleAPIKeyOrHeaderChange` / `handleAPIKeyChange`: sets `config.<key>` (a basic
/// config is made when there is none).
Map<String, Object?> authorizationWithConfig(Map<String, Object?> auth, String key, String value) {
  final config = auth['config'] is Map
      ? {...(auth['config']! as Map).cast<String, Object?>()}
      : <String, Object?>{'type': 'basic', 'api_key': ''};
  config[key] = value;
  return {...auth, 'config': config};
}
