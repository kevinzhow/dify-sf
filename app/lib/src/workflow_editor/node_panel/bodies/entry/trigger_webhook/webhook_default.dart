/// The Webhook Trigger's data rules (nodes/trigger-webhook/default.ts, utils/raw-variable.ts,
/// utils/parameter-type-utils.ts) and `isPrivateOrLocalAddress` (web/utils/urlValidation.ts).
library;

import '../../../../header/checklist/node_validators.dart';

/// `WEBHOOK_RAW_VARIABLE_NAME`.
const webhookRawVariableName = '_webhook_raw';

/// `createWebhookRawVariable`: the raw request payload every webhook outputs.
Map<String, Object?> createWebhookRawVariable() => {
  'variable': webhookRawVariableName,
  'label': 'raw',
  'value_type': 'object',
  'value_selector': <Object?>[],
  'required': true,
};

/// `defaultValue` of default.ts.
Map<String, Object?> triggerWebhookDefaultValue() => {
  'webhook_url': '',
  'method': 'POST',
  'content_type': 'application/json',
  'headers': <Object?>[],
  'params': <Object?>[],
  'body': <Object?>[],
  'async_mode': true,
  'status_code': 200,
  'response_body': '',
  'variables': [createWebhookRawVariable()],
};

/// `DEFAULT_STATUS_CODE` / `MAX_STATUS_CODE` (use-config.ts).
const defaultStatusCode = 200;
const maxStatusCode = 399;

/// The HTTP methods of the method select.
const webhookHttpMethods = ['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD'];

/// The content types of the content type select.
const webhookContentTypes = [
  'application/json',
  'application/x-www-form-urlencoded',
  'text/plain',
  'application/octet-stream',
  'multipart/form-data',
];

const _basicTypes = ['string', 'number', 'boolean', 'object', 'file'];
const _arrayElementTypes = ['array[string]', 'array[number]', 'array[boolean]', 'array[object]'];
const _validParameterTypes = [..._basicTypes, ..._arrayElementTypes];

const _typeDisplayNames = {
  'string': 'String',
  'number': 'Number',
  'boolean': 'Boolean',
  'object': 'Object',
  'file': 'File',
  'array[string]': 'Array[String]',
  'array[number]': 'Array[Number]',
  'array[boolean]': 'Array[Boolean]',
  'array[object]': 'Array[Object]',
  'secret': 'Secret',
  'array': 'Array',
  'array[file]': 'Array[File]',
  'any': 'Any',
  'array[any]': 'Array[Any]',
  'integer': 'Integer',
};

const _contentTypeTypes = {
  'application/json': ['string', 'number', 'boolean', 'object', ..._arrayElementTypes],
  'text/plain': ['string'],
  'application/x-www-form-urlencoded': ['string', 'number', 'boolean'],
  'application/octet-stream': ['file'],
  'multipart/form-data': ['string', 'number', 'boolean', 'file'],
};

/// `isValidParameterType`.
bool isValidParameterType(Object? type) => _validParameterTypes.contains(type);

/// `normalizeParameterType`: a known type as is (case and spaces ignored), the legacy `array` as `array[string]`,
/// anything else `string`.
String normalizeParameterType(Object? input) {
  if (input is! String || input.isEmpty) return 'string';
  final t = input.trim().toLowerCase();
  if (t == 'array') return 'array[string]';
  return const {
        'array[string]',
        'array[number]',
        'array[boolean]',
        'array[object]',
        'number',
        'boolean',
        'object',
        'file',
      }.contains(t)
      ? t
      : 'string';
}

/// `createParameterTypeOptions`: the types a parameter of a body with [contentType] can have (query parameters,
/// without a content type: String, Number, Boolean; unknown content types: JSON's).
List<({String name, String value})> createParameterTypeOptions([String? contentType]) {
  final types = contentType == null || contentType.isEmpty
      ? const ['string', 'number', 'boolean']
      : _contentTypeTypes[contentType.toLowerCase()] ?? _contentTypeTypes['application/json']!;
  return [for (final t in types) (name: _typeDisplayNames[t]!, value: t)];
}

/// `checkValid` of default.ts: a webhook URL is required, and every query / body parameter needs a valid type.
String checkValidTriggerWebhook(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? moreData) {
  final url = data['webhook_url'];
  if (url is! String || url.trim().isEmpty) {
    return t('workflow', 'nodes.triggerWebhook.validation.webhookUrlRequired');
  }
  for (final param in [..._list(data['params']), ..._list(data['body'])]) {
    final p = param is Map ? param : const {};
    if (!isValidParameterType(p['type'])) {
      return t('workflow', 'nodes.triggerWebhook.validation.invalidParameterType', {
        'name': p['name'],
        'type': p['type'],
      });
    }
  }
  return '';
}

List<Object?> _list(Object? x) => x is List ? x.cast<Object?>() : const [];

final _ipv4 = RegExp(r'^(\d+)\.(\d+)\.(\d+)\.(\d+)$');

/// `isPrivateOrLocalAddress`: localhost, a private or link-local IPv4 address, or a `.local` host.
bool isPrivateOrLocalAddress(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return false;
  final host = uri.host.toLowerCase();
  if (host == 'localhost' || host == '127.0.0.1' || host == '::1') return true;
  final m = _ipv4.firstMatch(host);
  if (m != null) {
    final a = int.parse(m[1]!), b = int.parse(m[2]!);
    if (a == 10) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    if (a == 169 && b == 254) return true;
  }
  return host.endsWith('.local');
}
