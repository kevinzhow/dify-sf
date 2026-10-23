/// The Webhook Trigger's edits (nodes/trigger-webhook/use-config.helpers.ts and use-config.ts) as pure functions
/// from the node's Dify data to the next data, and `removeUsedVarInNodes` (hooks/use-workflow.ts) on the document.
library;

import 'package:flutter/foundation.dart' show ValueChanged;

import '../../../../../editor/editor_controller.dart';
import '../../../../../i18n/dify_i18n.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../../workflow/node_used_vars.dart';
import '../../../../panel_fields/node_config.dart' show Json;
import '../../../../panel_fields/var_picker_model.dart' show checkKeys;

export '../../../../panel_fields/node_config.dart' show Json;
import 'webhook_default.dart';

/// `isVarUsedInNodes` / `removeUsedVarInNodes` over a `[nodeId, variable]` selector.
typedef VarSelectorTest = bool Function(List<String> selector);
typedef VarSelectorAction = void Function(List<String> selector);

/// Reports a name error with its i18n key (`variableConfig.varName`, `varKeyError.<x>` or the clashing name).
typedef NotifyError = void Function(String key);

/// Immer's draft: a deep copy to change.
Json cloneJson(Json m) => _clone(m) as Json;

Object? _clone(Object? v) => switch (v) {
  final Map m => <String, Object?>{for (final e in m.entries) '${e.key}': _clone(e.value)},
  final List l => [for (final e in l) _clone(e)],
  _ => v,
};

List<Json> _maps(Object? x) => [
  for (final e in (x is List ? x : const []))
    if (e is Map) e.cast<String, Object?>(),
];

String _name(Json item) => item['name'] is String ? item['name']! as String : '';

/// `sanitizeEntryName`: header names have `-` as `_`.
String _sanitized(Json item, String sourceType) =>
    sourceType == 'header' ? _name(item).replaceAll('-', '_') : _name(item);

/// `syncVariables`: rebuilds [draft]'s `variables` of [sourceType] (`param`, `header`, `body`) from [newData], after
/// checking the names (the raw variable's name, a name another group has, duplicates, `checkKeys`); false (and
/// [notifyError]) on the first bad name, [draft] then unchanged. Variables taken away are removed from the nodes
/// that use them.
bool syncVariables({
  required Json draft,
  required String id,
  required List<Json> newData,
  required String sourceType,
  required NotifyError notifyError,
  required VarSelectorTest isVarUsedInNodes,
  required VarSelectorAction removeUsedVarInNodes,
}) {
  draft['variables'] ??= <Object?>[];
  final variables = _maps(draft['variables']);
  final entries = [for (final item in newData) (item: item, name: _sanitized(item, sourceType))];
  if (entries.any((e) => e.name == webhookRawVariableName)) {
    notifyError('variableConfig.varName');
    return false;
  }
  final others = {
    for (final v in variables)
      if (v['label'] != sourceType && v['variable'] != webhookRawVariableName) v['variable'],
  };
  final conflict = entries.where((e) => others.contains(e.name)).firstOrNull;
  if (conflict != null) {
    notifyError(conflict.name);
    return false;
  }
  final names = [for (final e in entries) e.name];
  if (names.toSet().length != names.length) {
    notifyError('variableConfig.varName');
    return false;
  }
  for (final name in names) {
    final bad = checkKeys([name]);
    if (bad != null) {
      notifyError('varKeyError.${bad.error}');
      return false;
    }
  }
  final next = names.toSet();
  for (final v in variables) {
    final name = v['variable'];
    if (v['label'] == sourceType && name is String && !next.contains(name) && isVarUsedInNodes([id, name])) {
      removeUsedVarInNodes([id, name]);
    }
  }
  final kept = [
    for (final v in variables)
      if (v['label'] != sourceType || next.contains(v['variable'])) v,
  ];
  for (final e in entries) {
    final variable = <String, Object?>{
      'value_type': e.item.containsKey('type') ? e.item['type'] : 'string',
      'label': sourceType,
      'variable': e.name,
      'value_selector': <Object?>[],
      'required': e.item['required'],
    };
    final i = kept.indexWhere((v) => v['variable'] == e.name);
    if (i >= 0) {
      kept[i] = variable;
    } else {
      kept.add(variable);
    }
  }
  draft['variables'] = kept;
  return true;
}

/// `updateMethod`.
Json updateMethod(Json inputs, String method) => cloneJson(inputs)..['method'] = method;

/// `updateSimpleField` (`async_mode`, `status_code`, `response_body`).
Json updateSimpleField(Json inputs, String key, Object? value) => cloneJson(inputs)..[key] = value;

/// `updateContentType`: a different content type clears the body parameters and their variables (and their uses).
Json updateContentType({
  required Json inputs,
  required String id,
  required String contentType,
  required VarSelectorTest isVarUsedInNodes,
  required VarSelectorAction removeUsedVarInNodes,
}) {
  final draft = cloneJson(inputs);
  final previous = draft['content_type'];
  draft['content_type'] = contentType;
  if (previous == contentType) return draft;
  draft['body'] = <Object?>[];
  if (draft['variables'] == null) return draft;
  final variables = _maps(draft['variables']);
  for (final v in variables) {
    final name = v['variable'];
    if (v['label'] == 'body' && name is String && isVarUsedInNodes([id, name])) removeUsedVarInNodes([id, name]);
  }
  draft['variables'] = [
    for (final v in variables)
      if (v['label'] != 'body') v,
  ];
  return draft;
}

/// `updateSourceFields`: writes `params` / `headers` / `body` (always, even when a name is refused) and syncs the
/// variables.
Json updateSourceFields({
  required Json inputs,
  required String id,
  required String sourceType,
  required List<Json> nextData,
  required NotifyError notifyError,
  required VarSelectorTest isVarUsedInNodes,
  required VarSelectorAction removeUsedVarInNodes,
}) {
  final draft = cloneJson(inputs);
  draft[switch (sourceType) {
        'param' => 'params',
        'header' => 'headers',
        _ => 'body',
      }] =
      nextData;
  syncVariables(
    draft: draft,
    id: id,
    newData: nextData,
    sourceType: sourceType,
    notifyError: notifyError,
    isVarUsedInNodes: isVarUsedInNodes,
    removeUsedVarInNodes: removeUsedVarInNodes,
  );
  return draft;
}

/// `updateWebhookUrls`: a missing [webhookDebugUrl] clears the debug URL.
Json updateWebhookUrls(Json inputs, String webhookUrl, [String? webhookDebugUrl]) => cloneJson(inputs)
  ..['webhook_url'] = webhookUrl
  ..['webhook_debug_url'] = webhookDebugUrl;

/// `notifyVarError` of use-config.ts: the toast text for [key]. Dify passes the `varKeyError.<x>` key itself as the
/// field label, so the message starts with it.
String varErrorMessage(String key) {
  final label = key == 'variableConfig.varName' ? DifyI18n.tr('app-debug', 'variableConfig.varName') : key;
  const known = {
    'varKeyError.canNoBeEmpty',
    'varKeyError.keyAlreadyExists',
    'varKeyError.notStartWithNumber',
    'varKeyError.notValid',
    'varKeyError.tooLong',
  };
  return DifyI18n.tr('app-debug', known.contains(key) ? key : 'varKeyError.keyAlreadyExists', {'key': label});
}

bool _uses(List<List<String>> used, List<String> selector) => used.any((s) => jsonEquals(s, selector));

/// `isVarUsedInNodes`: whether a node of the document other than the selector's own uses [selector] (Dify looks
/// at the nodes after it in its branch; only those can reference it).
bool isVarUsedInNodes(EditorController controller, List<String> selector) {
  for (final n in controller.doc.nodes.values) {
    if (n.id == selector.first) continue;
    try {
      if (_uses(getNodeUsedVars(n), selector)) return true;
    } on StateError {
      continue;
    }
  }
  return false;
}

/// `removeUsedVarInNodes`: clears [selector] wherever another node uses it (`updateNodeVars(node, selector, [])`),
/// one op per changed config key.
void removeUsedVarInNodes(EditorController controller, List<String> selector) {
  for (final n in controller.doc.nodes.values.toList()) {
    if (n.id == selector.first) continue;
    try {
      if (!_uses(getNodeUsedVars(n), selector)) continue;
      final updated = updateNodeVars(n, selector, const []);
      for (final e in updated.config.entries) {
        if (n.config[e.key] != e.value) controller.setConfig(n.id, [e.key], e.value);
      }
    } on StateError {
      continue;
    }
  }
}

/// Dify's `setInputs`; [typed] marks text typed into a field (its write carries the typing draft's base).
typedef WebhookSetInputs = void Function(Json next, {bool typed});

/// The webhook URLs the backend generates for a node.
typedef WebhookUrls = ({String url, String? debugUrl});

/// `useConfig` (use-config.ts): the panel's handlers over the node's [inputs] (read at each call).
class WebhookTriggerConfig {
  const WebhookTriggerConfig({
    required this.id,
    required this.inputs,
    required this.setInputs,
    required this.isVarUsedInNodes,
    required this.removeUsedVarInNodes,
    required this.notifyError,
    this.readOnly = false,
    this.fetchWebhookUrl,
  });

  final String id;
  final Json Function() inputs;
  final WebhookSetInputs setInputs;
  final VarSelectorTest isVarUsedInNodes;
  final VarSelectorAction removeUsedVarInNodes;

  /// `toast.error` with the message.
  final ValueChanged<String> notifyError;
  final bool readOnly;

  /// `fetchWebhookUrl({ appId, nodeId })`; null without an app (no URL is generated then).
  final Future<WebhookUrls> Function(String nodeId)? fetchWebhookUrl;

  void _notify(String key) => notifyError(varErrorMessage(key));

  void handleMethodChange(String method) => setInputs(updateMethod(inputs(), method));

  void handleContentTypeChange(String contentType) => setInputs(
    updateContentType(
      inputs: inputs(),
      id: id,
      contentType: contentType,
      isVarUsedInNodes: isVarUsedInNodes,
      removeUsedVarInNodes: removeUsedVarInNodes,
    ),
  );

  void _source(String sourceType, List<Json> data) => setInputs(
    updateSourceFields(
      inputs: inputs(),
      id: id,
      sourceType: sourceType,
      nextData: data,
      notifyError: _notify,
      isVarUsedInNodes: isVarUsedInNodes,
      removeUsedVarInNodes: removeUsedVarInNodes,
    ),
    typed: true,
  );

  void handleParamsChange(List<Json> params) => _source('param', params);
  void handleHeadersChange(List<Json> headers) => _source('header', headers);
  void handleBodyChange(List<Json> body) => _source('body', body);

  void handleAsyncModeChange(bool asyncMode) => setInputs(updateSimpleField(inputs(), 'async_mode', asyncMode));

  void handleStatusCodeChange(num statusCode) => setInputs(updateSimpleField(inputs(), 'status_code', statusCode));

  void handleResponseBodyChange(String body) =>
      setInputs(updateSimpleField(inputs(), 'response_body', body), typed: true);

  /// `generateWebhookUrl`: nothing when there is a URL or no app; else the generated URLs, or an empty URL when the
  /// request fails (written over the data as it is when the answer comes).
  Future<void> generateWebhookUrl() async {
    final url = inputs()['webhook_url'];
    if (url is String && url.isNotEmpty) return;
    final fetch = fetchWebhookUrl;
    if (fetch == null) return;
    WebhookUrls? r;
    try {
      r = await fetch(id);
    } catch (_) {
      r = null;
    }
    setInputs(r == null ? updateWebhookUrls(inputs(), '') : updateWebhookUrls(inputs(), r.url, r.debugUrl));
  }
}
