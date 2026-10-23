/// Shared use-single-run-form-params for Parameter Extractor and Question Classifier. Both ask for a query,
/// instruction references and optional vision files; their query selector and reserved input keys differ.
library;

import '../../../i18n/dify_i18n.dart';
import '../../node_panel/bodies/llm/llm_vars.dart' show jsMap, jsSelector;
import '../../store/workflow_store.dart' show DifyJson;
import '../ui/before_run_form.dart' show InputVarType, RunFormProps;

class QueryVisionSingleRunParams {
  QueryVisionSingleRunParams({
    required this.nodeType,
    required this.payload,
    required this.values,
    required this.onChange,
    required List<DifyJson> Function(List<String>) getInputVars,
    required this.isVisionModel,
    required DifyJson? Function(List<String>) resolveVisionInput,
    Map<String, Object?> Function()? currentValues,
  }) : _currentValues = currentValues ?? (() => values) {
    varInputs = getInputVars(['${payload['instruction'] ?? ''}']);
    final vision = jsMap(payload['vision']), configs = jsMap(vision['configs']);
    final selector = configs['variable_selector'];
    _visionSelector = isVisionModel && vision['enabled'] == true && selector is List ? jsSelector(selector) : null;
    _visionInput = _visionSelector == null ? null : resolveVisionInput(_visionSelector);
  }

  final String nodeType;
  final DifyJson payload, values;
  final void Function(DifyJson) onChange;
  final bool isVisionModel;
  final DifyJson Function() _currentValues;
  late final List<DifyJson> varInputs;
  late final List<String>? _visionSelector;
  late final DifyJson? _visionInput;

  bool get _extractor => nodeType == 'parameter-extractor';
  List<String> get _query => jsSelector(payload[_extractor ? 'query' : 'query_variable_selector']);
  List<String> get _reserved => [if (_extractor) '#context#', '#files#'];

  List<RunFormProps> get forms => [
    RunFormProps(
      label: DifyI18n.tr('workflow', 'nodes.llm.singleRun.variable'),
      inputs: [
        {
          'label': DifyI18n.tr(
            'workflow',
            _extractor ? 'nodes.parameterExtractor.inputVar' : 'nodes.questionClassifiers.inputVars',
          ),
          'variable': 'query',
          'type': InputVarType.paragraph,
          'required': true,
        },
        ...varInputs,
      ],
      values: {
        for (final e in values.entries)
          if (!_reserved.contains(e.key)) e.key: e.value,
      },
      onChange: (next) => onChange({...next, for (final key in _reserved) key: _currentValues()[key]}),
    ),
    if (_visionSelector != null)
      RunFormProps(
        label: DifyI18n.tr('workflow', 'nodes.llm.vision'),
        inputs: [
          {'label': _visionInput?['label'], 'variable': '#files#', 'type': _visionInput?['type'], 'required': false},
        ],
        values: {'#files#': values['#files#']},
        onChange: (next) => onChange({..._currentValues(), '#files#': next['#files#']}),
      ),
  ];

  /// Prompt inputs can be malformed while nodes are being configured. Do not turn a missing variable into a selector.
  List<List<String>> getDependentVars() => [
    _query,
    for (final input in varInputs)
      if (input['variable'] case final String variable when variable.length > 2)
        variable.substring(1, variable.length - 1).split('.'),
    ?_visionSelector,
  ];

  List<String>? getDependentVar(String variable) => queryVisionDependentVar(nodeType, payload, variable);
}

/// Named fields of the specialized query/vision form resolve to the configured selector, while instruction
/// references already carry their selector in the #node.variable# field name.
List<String>? queryVisionDependentVar(String nodeType, DifyJson payload, String variable) => switch (variable) {
  'query' => jsSelector(payload[nodeType == 'parameter-extractor' ? 'query' : 'query_variable_selector']),
  '#files#' => jsSelector(jsMap(jsMap(payload['vision'])['configs'])['variable_selector']),
  _ => null,
};
