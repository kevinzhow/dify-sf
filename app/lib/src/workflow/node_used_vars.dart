/// Which variables a node uses, and renaming one, ported from Dify 1.17.1
/// `web/app/components/workflow/nodes/_base/components/variable/utils.ts` (`getNodeUsedVars`, `updateNodeVars` and
/// their helpers `matchNotSystemVars`, `replaceOldVarInText`, `getPromptItemTexts`, `replaceOldVarInPromptItem`).
///
/// Both work on the node's Dify `data` (see [difyDataOf]) with JavaScript semantics; where Dify's code throws (it reads
/// a property of `undefined`, e.g. a question classifier without `classes`), they throw [StateError].
library;

import 'package:collab_client/collab_client.dart';

import 'dify_json.dart';
import '../agents/model_inputs.dart';

/// `VAR_REGEX` (web/config/index.ts).
final _varRegex = RegExp(r'\{\{(#[\w-]{1,50}(\.\d+)?(\.[a-z_]\w{0,29}){1,10}#)\}\}', caseSensitive: false);

/// `isSpecialVar` prefixes (variable/utils.ts).
const _specialPrefixes = {'sys', 'env', 'conversation', 'rag'};

/// `getNodeUsedVars` (variable/utils.ts): the value selectors [node] uses, from its selector fields and the
/// `{{#node.var#}}` references in its texts. Dify's list can hold `undefined` entries (an unset selector field); they
/// are left out.
List<List<String>> getNodeUsedVars(Node node) {
  try {
    return [
      for (final s in _usedVars(difyDataOf(node)))
        if (s is List) [for (final e in s) jsKey(e)],
    ];
  } on JsTypeError catch (e) {
    throw StateError('Dify cannot read the variables used by ${node.id}: $e');
  }
}

/// `updateNodeVars` (variable/utils.ts): [node] with its uses of [oldVarSelector] (selector fields and `{{#...#}}`
/// references) replaced by [newVarSelector].
///
/// The result keeps the document's forms: keyed-list item ids, and references. A replaced reference is written as a
/// reference again when the new selector names a node output, else as a list; other selector fields stay lists.
Node updateNodeVars(Node node, List<String> oldVarSelector, List<String> newVarSelector) {
  final data = difyDataOf(node);
  try {
    _updateVars(data, oldVarSelector, newVarSelector);
  } on JsTypeError catch (e) {
    throw StateError('Dify cannot update the variables of ${node.id}: $e');
  }
  data
    ..remove('type')
    ..remove('title');
  return node.copyWith(config: (_merge(VMap(node.config), data) as VMap).entries);
}

// ---- helpers -----------------------------------------------------------------------------------------------------

/// `matchNotSystemVars`: the selectors of the `{{#...#}}` references in [prompts] (non-strings skipped), unique.
List<List<String>> _matchNotSystemVars(List<Object?> prompts) {
  final all = <String>{};
  for (final p in prompts) {
    if (p is String) all.addAll(_varRegex.allMatches(p).map((m) => m[0]!));
  }
  return [for (final v in all) v.replaceAll('{{#', '').replaceFirst('#}}', '').split('.')];
}

/// `replaceOldVarInText`.
Object? _replaceOldVarInText(Object? text, List<String> oldVar, List<String> newVar) {
  if (!jsTruthy(text) || text is! String) return text;
  if (newVar.isEmpty) return text;
  return text.replaceAll('{{#${oldVar.join('.')}#}}', '{{#${newVar.join('.')}#}}');
}

/// `getPromptItemTexts`.
List<Object?> _promptItemTexts(Object? prompt) => [
  jsReq(prompt, 'text', 'prompt'),
  if (jsTruthy(jsGet(prompt, 'jinja2_text'))) jsGet(prompt, 'jinja2_text'),
].where(jsTruthy).toList();

/// `replaceOldVarInPromptItem`.
Map<String, Object?> _replaceOldVarInPromptItem(Object? prompt, List<String> oldVar, List<String> newVar) => {
  if (prompt is Map)
    for (final e in prompt.entries) '${e.key}': e.value,
  'text': _replaceOldVarInText(jsReq(prompt, 'text', 'prompt'), oldVar, newVar),
  if (prompt is Map && prompt['jinja2_text'] != null)
    'jinja2_text': _replaceOldVarInText(prompt['jinja2_text'], oldVar, newVar),
};

/// `isAgentV2NodeData` (nodes/agent-v2/types.ts).
bool _isAgentV2(Map<String, Object?> data) =>
    (data['type'] == 'agent' || data['type'] == 'agent-v2') &&
    data['agent_node_kind'] == 'dify_agent' &&
    data['version'] == '2';

/// `x.map(...)` / `x.flatMap(...)`: [x] must be an array.
List<Object?> _arr(Object? x, String what) =>
    x is List ? x.cast<Object?>() : throw JsTypeError('$what.map is not a function');

/// `x?.map(...)`.
List<Object?>? _arrOpt(Object? x, String what) => x == null ? null : _arr(x, what);

/// `Object.keys(x)` of a parameter map (throws for undefined).
List<String> _keys(Object? x, String what) => switch (x) {
  null => throw JsTypeError('Object.keys($what): cannot convert undefined to object'),
  final Map m => [for (final k in m.keys) '$k'],
  _ => const [],
};

Map<String, Object?> _map(Object? x) => x is Map ? {for (final e in x.entries) '${e.key}': e.value} : {};

// ---- getNodeUsedVars ---------------------------------------------------------------------------------------------

List<Object?> _usedVars(Map<String, Object?> data) {
  List<Object?> paramVars(String field) {
    final params = data[field];
    final keys = _keys(params, field);
    Object? param(String k) => jsGet(params, k);
    final mixVars = _matchNotSystemVars([
      for (final k in keys)
        if (jsReq(param(k), 'type', '$field.$k') == 'mixed') jsGet(param(k), 'value'),
    ]);
    final vars = [
      for (final k in keys)
        if (jsReq(param(k), 'type', '$field.$k') == 'variable') jsGet(param(k), 'value'),
    ];
    return [...mixVars, ...vars];
  }

  switch (data['type']) {
    case 'end':
      return [for (final o in _arrOpt(data['outputs'], 'outputs') ?? const []) jsReq(o, 'value_selector', 'output')];

    case 'answer':
      return _matchNotSystemVars([data['answer']]);

    case 'llm':
      final isChatModel = jsGet(data['model'], 'mode') == 'chat';
      final List<Object?> prompts;
      if (isChatModel) {
        prompts = [
          for (final p in _arrOpt(data['prompt_template'], 'prompt_template') ?? const []) ..._promptItemTexts(p),
        ];
        final query = jsGet(data['memory'], 'query_prompt_template');
        if (jsTruthy(query)) prompts.add(query);
      } else {
        prompts = _promptItemTexts(data['prompt_template']);
      }
      final contextVar = jsGet(data['context'], 'variable_selector');
      final modelSelector = data['model_selector'];
      return [
        ..._matchNotSystemVars(prompts),
        if (jsTruthy(contextVar)) contextVar,
        if (jsGet(modelSelector, '0') == 'env') modelSelector,
      ];

    case 'knowledge-retrieval':
      return [data['query_variable_selector'], data['query_attachment_selector'] ?? const <String>[]];

    case 'if-else':
      final cases = data['cases'];
      final conditions = [
        for (final c in jsTruthy(cases) ? _arr(cases, 'cases') : const [])
          ...switch (jsReq(c, 'conditions', 'case')) {
            final List l => l,
            final x when jsTruthy(x) => [x],
            _ => const [],
          },
      ];
      return [
        for (final c in conditions) ...[
          if (jsTruthy(jsReq(c, 'variable_selector', 'condition'))) jsGet(c, 'variable_selector'),
          if (jsGet(c, 'sub_variable_condition') case final sub
              when jsTruthy(sub) && jsTruthy(jsGet(sub, 'conditions')))
            for (final s in _arr(jsGet(sub, 'conditions'), 'sub_variable_condition.conditions'))
              if (jsReq(s, 'variable_selector', 'sub condition') case final List sel when sel.isNotEmpty) sel,
        ],
      ];

    case 'code' || 'template-transform':
      return [for (final v in _arrOpt(data['variables'], 'variables') ?? const []) jsReq(v, 'value_selector', 'var')];

    case 'question-classifier':
      return [
        data['query_variable_selector'],
        ..._matchNotSystemVars([jsTruthy(data['instruction']) ? data['instruction'] : '']),
        ..._matchNotSystemVars([for (final c in _arr(data['classes'], 'classes')) jsReq(c, 'name', 'class')]),
      ];

    case 'http-request':
      final body = jsReq(data['body'], 'data', 'body');
      return _matchNotSystemVars([
        data['url'],
        data['headers'],
        data['params'],
        if (body is String)
          body
        else
          [for (final d in _arr(body, 'body.data')) jsReq(d, 'value', 'body item')]
              .map((v) => v == null ? '' : jsKey(v))
              .join(),
      ]);

    case 'tool':
      return paramVars('tool_parameters');

    case 'agent' when _isAgentV2(data):
      return [..._matchNotSystemVars([jsTruthy(data['agent_task']) ? data['agent_task'] : '']),
        ...agentModelInputSelectors(data['agent_model'])];

    case 'agent':
      final params = data['agent_parameters'];
      if (!jsTruthy(params)) return const [];
      return [
        for (final k in _keys(params, 'agent_parameters'))
          if (jsReq(jsGet(params, k), 'value', 'agent_parameters.$k') case final String value)
            ..._matchNotSystemVars([value]),
      ];

    case 'agent-v2':
      return [..._matchNotSystemVars([jsTruthy(data['agent_task']) ? data['agent_task'] : '']),
        ...agentModelInputSelectors(data['agent_model'])];

    case 'datasource':
      return paramVars('datasource_parameters');

    case 'variable-assigner' || 'variable-aggregator':
      return jsList(data['variables']);

    case 'parameter-extractor':
      return [
        data['query'],
        ..._matchNotSystemVars([jsTruthy(data['instruction']) ? data['instruction'] : '']),
      ];

    case 'iteration':
      return [data['iterator_selector']];

    case 'loop':
      return [
        for (final c in _arrOpt(data['break_conditions'], 'break_conditions') ?? const [])
          jsTruthy(jsReq(c, 'variable_selector', 'break condition')) ? jsGet(c, 'variable_selector') : const <String>[],
      ];

    case 'list-operator':
      return [data['variable']];

    case 'human-input':
      final mailTemplates = [
        for (final method in _arr(data['delivery_methods'], 'delivery_methods'))
          if (jsReq(method, 'type', 'delivery method') == 'email' && jsTruthy(jsGet(method, 'config')))
            jsGet(jsGet(method, 'config'), 'body'),
      ];
      final inputSelectors = [
        for (final input in _arr(data['inputs'], 'inputs'))
          if (jsReq(input, 'type', 'input') == 'paragraph' &&
              jsReq(jsGet(input, 'default'), 'type', 'input.default') == 'variable')
            jsGet(jsGet(input, 'default'), 'selector')
          else if (jsGet(input, 'type') == 'select' &&
              jsReq(jsGet(input, 'option_source'), 'type', 'input.option_source') == 'variable')
            jsGet(jsGet(input, 'option_source'), 'selector'),
      ];
      return [
        ..._matchNotSystemVars([data['form_content'], ...mailTemplates]),
        ...inputSelectors,
      ];
  }
  return const [];
}

// ---- updateNodeVars ----------------------------------------------------------------------------------------------

void _updateVars(Map<String, Object?> data, List<String> oldVar, List<String> newVar) {
  final old = oldVar.join('.');
  List<Object?> next() => List<Object?>.of(newVar);
  Object? rep(Object? text) => _replaceOldVarInText(text, oldVar, newVar);

  /// `if (x.<key>.join('.') === old) x.<key> = new` over a list of maps.
  void renameIn(Object? list, String what, String key) {
    for (final item in _arr(list, what)) {
      if (jsJoin(jsReq(item, key, what), '$what.$key') == old) (item! as Map)[key] = next();
    }
  }

  void renameField(Map<String, Object?> m, String key, {bool optional = false}) {
    final hit = optional ? jsJoinOpt(m[key], key) == old : jsJoin(m[key], key) == old;
    if (hit) m[key] = next();
  }

  void renameParams(String field) {
    final params = data[field];
    final keys = _keys(params, field);
    for (final k in keys) {
      jsReq(jsGet(params, k), 'type', '$field.$k'); // the filter reads every type
    }
    for (final k in keys) {
      final value = jsGet(params, k);
      final type = jsGet(value, 'type');
      if (type == 'variable' && jsJoin(jsGet(value, 'value'), '$field.$k.value') == old) {
        (params! as Map)[k] = {..._map(value), 'value': next()};
      }
      if (type == 'mixed') (params! as Map)[k] = {..._map(value), 'value': rep(jsGet(jsGet(params, k), 'value'))};
    }
  }

  void replaceAgentTask() => data['agent_task'] = rep(jsTruthy(data['agent_task']) ? data['agent_task'] : '');

  void replaceMemoryQuery() {
    final memory = data['memory'];
    if (jsTruthy(jsGet(memory, 'query_prompt_template'))) {
      (memory! as Map)['query_prompt_template'] = rep(jsGet(memory, 'query_prompt_template'));
    }
  }

  switch (data['type']) {
    case 'end':
      if (jsTruthy(data['outputs'])) renameIn(data['outputs'], 'outputs', 'value_selector');

    case 'answer':
      data['answer'] = rep(data['answer']);
      if (jsTruthy(data['variables'])) renameIn(data['variables'], 'variables', 'value_selector');

    case 'llm':
      if (jsGet(data['model'], 'mode') == 'chat') {
        data['prompt_template'] = [
          for (final p in _arr(data['prompt_template'], 'prompt_template'))
            _replaceOldVarInPromptItem(p, oldVar, newVar),
        ];
        replaceMemoryQuery();
      } else {
        data['prompt_template'] = _replaceOldVarInPromptItem(data['prompt_template'], oldVar, newVar);
      }
      final context = data['context'];
      if (jsJoinOpt(jsGet(context, 'variable_selector'), 'context.variable_selector') == old) {
        (context! as Map)['variable_selector'] = next();
      }
      final modelSelector = data['model_selector'];
      if (jsGet(modelSelector, '0') == 'env' && jsJoin(modelSelector, 'model_selector') == old) {
        data['model_selector'] = next();
      }

    case 'knowledge-retrieval':
      renameField(data, 'query_variable_selector');
      renameField(data, 'query_attachment_selector', optional: true);

    case 'if-else':
      if (!jsTruthy(data['cases'])) break;
      for (final caseItem in _arr(data['cases'], 'cases')) {
        final conditions = jsReq(caseItem, 'conditions', 'case');
        if (!jsTruthy(conditions)) continue;
        for (final c in _arr(conditions, 'conditions')) {
          if (jsJoinOpt(jsReq(c, 'variable_selector', 'condition'), 'variable_selector') == old) {
            (c! as Map)['variable_selector'] = next();
          }
          final sub = jsGet(c, 'sub_variable_condition');
          if (jsTruthy(sub) && jsTruthy(jsGet(sub, 'conditions'))) {
            for (final s in _arr(jsGet(sub, 'conditions'), 'sub_variable_condition.conditions')) {
              if (jsJoinOpt(jsReq(s, 'variable_selector', 'sub condition'), 'variable_selector') == old) {
                (s! as Map)['variable_selector'] = next();
              }
            }
          }
        }
      }

    case 'code' || 'template-transform':
      if (jsTruthy(data['variables'])) renameIn(data['variables'], 'variables', 'value_selector');

    case 'question-classifier':
      renameField(data, 'query_variable_selector');
      data['instruction'] = rep(data['instruction']);
      data['classes'] = [
        for (final topic in _arr(data['classes'], 'classes'))
          {..._map(topic), 'name': rep(jsReq(topic, 'name', 'class'))},
      ];

    case 'http-request':
      data['url'] = rep(data['url']);
      data['headers'] = rep(data['headers']);
      data['params'] = rep(data['params']);
      final body = data['body'];
      final bodyData = jsReq(body, 'data', 'body');
      (body! as Map)['data'] = bodyData is String
          ? rep(bodyData)
          : [
              for (final d in _arr(bodyData, 'body.data'))
                {
                  ..._map(d),
                  'value': rep(jsTruthy(jsReq(d, 'value', 'body item')) ? jsGet(d, 'value') : ''),
                },
            ];

    case 'tool':
      renameParams('tool_parameters');

    case 'agent' when _isAgentV2(data):
      replaceAgentTask();
      if (data['agent_model'] case final Map settings) {
        data['agent_model'] = {for (final e in settings.entries) e.key: rep(e.value)};
      }

    case 'agent':
      final params = data['agent_parameters'];
      if (jsTruthy(params)) {
        for (final k in _keys(params, 'agent_parameters')) {
          final value = jsGet(params, k);
          final type = jsReq(value, 'type', 'agent_parameters.$k');
          final v = jsGet(value, 'value');
          if (type == 'variable' && v is List && jsJoin(v, 'value') == old) {
            (params! as Map)[k] = {..._map(value), 'value': next()};
          }
          if (type == 'mixed' && v is String) (params! as Map)[k] = {..._map(value), 'value': rep(v)};
        }
      }
      replaceMemoryQuery();

    case 'agent-v2':
      replaceAgentTask();
      if (data['agent_model'] case final Map settings) {
        data['agent_model'] = {for (final e in settings.entries) e.key: rep(e.value)};
      }

    case 'datasource':
      renameParams('datasource_parameters');

    case 'variable-assigner' || 'variable-aggregator':
      if (jsTruthy(data['variables'])) {
        data['variables'] = [
          for (final v in _arr(data['variables'], 'variables')) jsJoin(v, 'variable') == old ? next() : v,
        ];
      }

    case 'parameter-extractor':
      renameField(data, 'query');
      data['instruction'] = rep(data['instruction']);

    case 'iteration':
      renameField(data, 'iterator_selector');

    case 'loop':
      if (!jsTruthy(data['break_conditions'])) break;
      for (final c in _arr(data['break_conditions'], 'break_conditions')) {
        if (jsJoinOpt(jsReq(c, 'variable_selector', 'break condition'), 'variable_selector') == old) {
          (c! as Map)['variable_selector'] = next();
        }
      }

    case 'list-operator':
      renameField(data, 'variable');

    case 'human-input':
      data['form_content'] = rep(data['form_content']);
      data['delivery_methods'] = [
        for (final method in _arr(data['delivery_methods'], 'delivery_methods'))
          if (jsReq(method, 'type', 'delivery method') != 'email' || !jsTruthy(jsGet(method, 'config')))
            method
          else
            {
              ..._map(method),
              'config': {..._map(jsGet(method, 'config')), 'body': rep(jsGet(jsGet(method, 'config'), 'body'))},
            },
      ];
      for (final input in _arr(data['inputs'], 'inputs')) {
        final type = jsReq(input, 'type', 'input');
        for (final (inputType, field) in const [('paragraph', 'default'), ('select', 'option_source')]) {
          if (type != inputType) continue;
          final source = jsGet(input, field);
          if (jsReq(source, 'type', 'input.$field') == 'variable' &&
              jsJoin(jsGet(source, 'selector'), 'input.$field.selector') == old) {
            (source! as Map)['selector'] = next();
          }
        }
      }
  }
}

/// Writes Dify's updated [plain] data back over [orig]: unchanged references (live or broken) and keyed-list item ids
/// stay, keys Dify left `undefined` (null here, absent before) are not added.
Value _merge(Value? orig, Object? plain) {
  switch ((orig, plain)) {
    case (VRef(:final ref) || VBroken(:final ref), final List l):
      if (l.length == 2 && l[0] == ref.node && l[1] == ref.output) return orig!;
      if (l.length == 2 && l.every((e) => e is String) && !_specialPrefixes.contains(l[0])) {
        return VRef(OutputRef(l[0] as String, l[1] as String));
      }
    case (VItems(:final items), final List l) when l.length == items.length:
      return VItems([for (final (i, item) in items.indexed) Item(item.id, _merge(item.value, l[i]))]);
    case (VList(:final items), final List l) when l.length == items.length:
      return VList([for (final (i, item) in items.indexed) _merge(item, l[i])]);
    case (VMap(:final entries), final Map m):
      return VMap({
        for (final e in m.entries)
          if (e.value != null || entries.containsKey(e.key)) '${e.key}': _merge(entries['${e.key}'], e.value),
      });
  }
  return Value.of(plain);
}
