/// The Steps view's text: a step card's one-line summary (what the canvas card shows of a node, as text) and the
/// labels of its lanes (as Dify labels the handles: the IF/ELIF condition, ELSE, the class, the action, the fail
/// branch, PARALLEL). Pure functions of the document; the strings are Dify's where Dify has them.
library;

import 'package:collab_client/collab_client.dart';

import '../../i18n/dify_i18n.dart';
import '../../workflow/dify_json.dart';
import 'steps_layout.dart';

String _wf(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);

/// A Dify translation, or [fallback] when the key has none (the translator answers with the key).
String _wfOr(String key, String fallback) {
  final t = _wf(key);
  return t == key || t.endsWith('.$key') || t.isEmpty ? fallback : t;
}

const _systemScopes = {'sys', 'env', 'conversation', 'rag'};

/// A value selector as the cards name it: `Node title / output.path`, `sys.query` for system and environment
/// variables; null when it is not a selector.
String? refLabel(Object? selector, Document doc) {
  final parts = [
    for (final p in jsList(selector))
      if (p is String) p,
  ];
  if (parts.length < 2) return null;
  final head = parts.first, path = parts.skip(1).join('.');
  if (_systemScopes.contains(head)) return '$head.$path';
  final title = doc.nodes[head]?.title;
  return '${title == null || title.isEmpty ? head : title} / $path';
}

Object? _config(Node n, String key) => plainOf(n.config[key]);

String _str(Object? v) => v is String ? v.trim() : (v == null ? '' : '$v');

String _firstLine(String s) {
  final line = s.trim().split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
  return line.trim();
}

/// `{{#node.output#}}` written as the cards write it: `{{output}}`, `{{sys.query}}`.
String _withVariables(String text) => text.replaceAllMapped(RegExp(r'\{\{#([^#]+)#\}\}'), (m) {
  final parts = m.group(1)!.split('.');
  return parts.first == 'sys' ? '{{${parts.join('.')}}}' : '{{${parts.skip(1).join('.')}}}';
});

String _names(Iterable<String> names) => names.where((s) => s.isNotEmpty).join(', ');

String _labelled(String label, String value) => value.isEmpty ? '' : '$label: $value';

String _codeLanguage(String lang) => switch (lang) {
  'python3' => 'Python 3',
  'javascript' => 'JavaScript',
  'json' => 'JSON',
  _ => lang,
};

/// The block's name (`blocks.<type>`), as the block selector shows it.
String blockName(String type) => _wfOr('blocks.$type', type);

/// A step card's one-line summary: what the node's canvas card shows (the model, the code language and outputs, the
/// inputs and outputs, the request, the input variable, …) as text; else the node's description; else the block's
/// name.
String stepSummary(Node n, Document doc) {
  final input = _wfOr('common.input', 'Input'), output = _wfOr('common.output', 'Output');
  List<Object?> list(String key) => jsList(_config(n, key));
  String ref(String key) => refLabel(_config(n, key), doc) ?? '';
  String model() => _str(jsGet(_config(n, 'model'), 'name'));
  final text = switch (n.type) {
    'start' => _labelled(input, _names([for (final v in list('variables')) _str(jsGet(v, 'variable'))])),
    'end' => _labelled(output, _names([for (final v in list('outputs')) _str(jsGet(v, 'variable'))])),
    'answer' => _firstLine(_withVariables(_str(_config(n, 'answer')))),
    'llm' || 'parameter-extractor' || 'question-classifier' => model(),
    'agent' =>
      _str(_config(n, 'agent_strategy_label')).isNotEmpty
          ? _str(_config(n, 'agent_strategy_label'))
          : _str(_config(n, 'agent_strategy_name')),
    'code' => [
      _codeLanguage(_str(_config(n, 'code_language'))),
      _labelled(output, _names(Document.declaredOutputs(n) ?? const {})),
    ].where((s) => s.isNotEmpty).join(' · '),
    'template-transform' => _firstLine(_withVariables(_str(_config(n, 'template')))),
    'http-request' => [
      _str(_config(n, 'method')).toUpperCase(),
      _withVariables(_str(_config(n, 'url'))),
    ].where((s) => s.isNotEmpty).join(' '),
    'tool' => [
      _str(_config(n, 'provider_name')),
      _str(_config(n, 'tool_label')).isNotEmpty ? _str(_config(n, 'tool_label')) : _str(_config(n, 'tool_name')),
    ].where((s) => s.isNotEmpty).join(' / '),
    'knowledge-retrieval' => _labelled(input, ref('query_variable_selector')),
    'iteration' => _labelled(input, ref('iterator_selector')),
    'document-extractor' => _labelled(input, ref('variable_selector')),
    'list-operator' => _labelled(input, ref('variable')),
    'variable-aggregator' || 'variable-assigner' => _names([
      for (final v in list('variables')) refLabel(v, doc) ?? '',
    ]),
    'assigner' => _names([for (final i in list('items')) refLabel(jsGet(i, 'variable_selector'), doc) ?? '']),
    'human-input' => _names([
      for (final a in list('user_actions'))
        _str(jsGet(a, 'title')).isNotEmpty ? _str(jsGet(a, 'title')) : _str(jsGet(a, 'id')),
    ]),
    'trigger-webhook' => _str(_config(n, 'method')).toUpperCase(),
    'trigger-schedule' =>
      _str(_config(n, 'mode')) == 'cron' ? _str(_config(n, 'cron_expression')) : _str(_config(n, 'frequency')),
    'trigger-plugin' =>
      _str(_config(n, 'event_name')).isNotEmpty ? _str(_config(n, 'event_name')) : _str(_config(n, 'provider_name')),
    'datasource' => _str(_config(n, 'datasource_label')),
    _ => '',
  };
  if (text.isNotEmpty) return text;
  final desc = _firstLine(_str(_config(n, 'desc')));
  return desc.isNotEmpty ? desc : blockName(n.type);
}

/// Operators Dify writes as symbols (no translation).
final _symbol = RegExp(r'^[=≠<>≥≤]+$');

String _operator(String op) => _symbol.hasMatch(op) ? op : _wfOr('nodes.ifElse.comparisonOperator.$op', op);

const _noValue = {'empty', 'not empty', 'null', 'not null', 'exists', 'not exists', 'is null', 'is not null'};

/// One IF/ELSE condition as the card's condition line reads: the variable, the operator, the value.
String _condition(Object? c, Document doc) {
  final selector = jsList(jsGet(c, 'variable_selector'));
  if (selector.isEmpty) return _wfOr('nodes.ifElse.conditionNotSetup', 'Condition NOT setup');
  final variable = [
    for (final p in selector.skip(_systemScopes.contains(selector.first) ? 0 : 1))
      if (p is String) p,
  ].join('.');
  final op = _str(jsGet(c, 'comparison_operator'));
  final raw = jsGet(c, 'value');
  final value = _noValue.contains(op)
      ? ''
      : switch (raw) {
          final String s => _withVariables(s),
          final bool b => b ? 'True' : 'False',
          final num v => '$v',
          final List l when l.isNotEmpty => _str(l.first),
          _ => '',
        };
  return [variable, _operator(op), value].where((s) => s.isNotEmpty).join(' ');
}

/// The label of a lane of [owner] (a [StepRowKind.laneHeader] row): `IF words > 0`, `ELIF …`, `ELSE`, a class
/// (`CLASS 2 · Billing`), a human-input action's title, `Timeout`, `Fail Branch`, `PARALLEL 2`.
String laneLabel(Node owner, StepRow row, Document doc) {
  final handle = row.handle ?? '';
  final index = row.laneIndex;
  switch (row.lane) {
    case StepLaneKind.ifCase:
      final cases = jsList(_config(owner, 'cases'));
      final at = cases.indexWhere((c) => _str(jsGet(c, 'case_id')) == handle);
      final c = at < 0 ? null : cases[at];
      final conditions = jsList(jsGet(c, 'conditions'));
      final joiner = _str(jsGet(c, 'logical_operator')) == 'or'
          ? _wfOr('nodes.ifElse.or', 'or')
          : _wfOr('nodes.ifElse.and', 'and');
      final keyword = at <= 0 ? 'IF' : 'ELIF';
      if (conditions.isEmpty) return '$keyword ${_wfOr('nodes.ifElse.conditionNotSetup', 'Condition NOT setup')}';
      return '$keyword ${[for (final cond in conditions) _condition(cond, doc)].join(' $joiner ')}';
    case StepLaneKind.elseCase:
      return 'ELSE';
    case StepLaneKind.classifierClass:
      final classes = jsList(_config(owner, 'classes'));
      final at = classes.indexWhere((c) => _str(jsGet(c, 'id')) == handle);
      final c = at < 0 ? null : classes[at];
      final label = _str(jsGet(c, 'label'));
      final name = _str(jsGet(c, 'name'));
      final shown = label.isNotEmpty
          ? label
          : _wf('nodes.questionClassifiers.defaultLabel', {'index': (at < 0 ? index : at) + 1});
      return name.isEmpty || name == label ? shown : '$shown · ${_firstLine(name)}';
    case StepLaneKind.humanAction:
      final actions = jsList(_config(owner, 'user_actions'));
      final a = actions.where((a) => _str(jsGet(a, 'id')) == handle).firstOrNull;
      final title = _str(jsGet(a, 'title'));
      return title.isNotEmpty ? title : handle;
    case StepLaneKind.timeout:
      return _wfOr('nodes.humanInput.timeout.title', 'Timeout');
    case StepLaneKind.failBranch:
      return _wfOr('nodes.common.errorHandle.failBranch.title', 'Fail Branch');
    case StepLaneKind.parallel:
      return '${_wfOr('common.parallel', 'PARALLEL')} ${index + 1}';
    case StepLaneKind.body || StepLaneKind.other || null:
      return handle;
  }
}

/// A run's time as the phone shows it on a step and in the run sheet (mockup 7's "1.2 s"): seconds with one decimal,
/// minutes and whole seconds from a minute on.
String formatStepSeconds(num seconds) {
  if (seconds < 60) return '${seconds.toStringAsFixed(1)} s';
  return '${seconds ~/ 60} m ${(seconds % 60).round()} s';
}

/// The time each step took in [workflowRunningData]'s tracing (the run's `node_finished` events: `elapsed_time` of
/// a finished node), by node id; the latest entry of a node wins (a loop's or a retried node's last round).
Map<String, num> stepTimesOf(Map<String, Object?>? workflowRunningData) {
  final out = <String, num>{};
  for (final t in jsList(workflowRunningData?['tracing'])) {
    if (t is! Map) continue;
    final id = t['node_id'], elapsed = t['elapsed_time'], status = t['status'];
    if (id is String && elapsed is num && status != 'running' && status != 'waiting') out[id] = elapsed;
  }
  return out;
}
