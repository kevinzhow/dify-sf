/// The Code node's pure logic: code-parser.ts (`extractFunctionParams`, `extractReturnType`), use-config.ts's
/// signature sync and the single-run form params of the Code and Template nodes.
library;

import '../../../../workflow/dify_json.dart';
import '../../../../workflow/output_vars.dart' show VarType;

/// Dify's `OutputVar` entry for an output of type [type].
Map<String, Object?> outputVarOf(String type) => {'type': type, 'children': null};

/// `extractFunctionParams`: the parameter names of `main` (type annotations dropped); none for JSON.
List<String> extractFunctionParams(String code, String language) {
  final pattern = switch (language) {
    'python3' => RegExp(r'def\s+main\s*\((.*?)\)'),
    'javascript' => RegExp(r'function\s+main\s*\((.*?)\)'),
    _ => null,
  };
  final match = pattern?.firstMatch(code);
  final params = match?.group(1);
  if (params == null || params.isEmpty) return [];
  return [
    for (final p in params.split(',').map((p) => p.trim()))
      if (p.isNotEmpty) p.split(':').first.trim(),
  ];
}

/// `extractReturnType`: the keys of the first `return { ... }` object (JavaScript also `return ({ ... })`), nested
/// objects' keys left out, each a string output.
Map<String, Map<String, Object?>> extractReturnType(String code, String language) {
  final source = code.replaceFirst(RegExp(r'/\*\*[\s\S]*?\*/'), '');
  final returnIndex = source.indexOf('return');
  if (returnIndex == -1) return {};
  final after = source.substring(returnIndex);
  var start = after.indexOf('{');
  if (language == 'javascript' && start == -1) {
    final paren = after.indexOf('(');
    if (paren != -1) start = after.indexOf('{', paren);
  }
  if (start == -1) return {};
  var depth = 0, end = -1;
  for (var i = start; i < after.length; i++) {
    if (after[i] == '{') depth++;
    if (after[i] == '}') {
      depth--;
      if (depth == 0) {
        end = i + 1;
        break;
      }
    }
  }
  if (end == -1) return {};
  final content = after.substring(start + 1, end - 1);
  return {
    for (final m in RegExp(r'''['"]?(\w+)['"]?\s*:(?![^{]*\})''').allMatches(content))
      m.group(1)!: outputVarOf(VarType.string),
  };
}

/// handleSyncFunctionSignature's `generateSyncSignatureCode`: `main`'s parameters from [variables] (Dify's
/// `Variable[]`), Python with type hints by `value_type`; JSON code unchanged.
String syncFunctionSignature(String code, String? language, List<Object?> variables) {
  final names = [for (final v in variables) jsStr(jsGet(v, 'variable')) ?? ''];
  switch (language) {
    case 'javascript':
      final params = names.join(', ');
      return code.replaceAll(
        RegExp(r'function\s+main\b\s*\([\s\S]*?\)'),
        'function main(${params.isEmpty ? '' : '{$params}'})',
      );
    case 'python3':
      final params = [
        for (final (i, v) in variables.indexed)
          names[i] +
              switch (jsGet(v, 'value_type')) {
                VarType.string => ': str',
                VarType.number => ': float',
                VarType.object => ': dict',
                VarType.array => ': list',
                VarType.arrayNumber => ': list[float]',
                VarType.arrayString => ': list[str]',
                VarType.arrayObject => ': list[dict]',
                _ => '',
              },
      ];
      return code.replaceAll(RegExp(r'def\s+main\b\s*\([\s\S]*?\)'), 'def main(${params.join(', ')})');
  }
  return code;
}

/// One single-run form (Dify's `{inputs, values, onChange}`).
typedef SingleRunForm = ({
  List<Map<String, Object?>> inputs,
  Map<String, Object?> values,
  void Function(Map<String, Object?>) onChange,
});

/// use-single-run-form-params.ts of the Code and Template nodes: one form over the input variables
/// ([toVarInputs]), the run inputs as its values, and the input variables' selectors as the dependent vars.
({
  List<SingleRunForm> forms,
  List<List<String>> Function() getDependentVars,
  List<String>? Function(String variable) getDependentVar,
})
varSingleRunFormParams({
  required Map<String, Object?> payload,
  required Map<String, Object?> runInputData,
  required void Function(Map<String, Object?>) setRunInputData,
  required List<Map<String, Object?>> Function(List<Object?> variables) toVarInputs,
}) {
  final variables = jsList(payload['variables']);
  List<String> selector(Object? v) => [for (final e in jsList(jsGet(v, 'value_selector'))) jsKey(e)];
  return (
    forms: [
      (inputs: toVarInputs(variables), values: {...runInputData}, onChange: setRunInputData),
    ],
    getDependentVars: () => [for (final v in variables) selector(v)],
    getDependentVar: (name) {
      final v = variables.where((v) => jsGet(v, 'variable') == name).firstOrNull;
      return v == null ? null : selector(v);
    },
  );
}
