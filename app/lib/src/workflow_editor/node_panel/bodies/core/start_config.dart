/// The User Input (Start) node's panel logic (nodes/start/use-config.ts, use-single-run-form-params.ts), as pure Dart
/// over the node's Dify data with the hooks it uses passed in.
library;

import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import 'start_var_modal.dart';

/// `hasDuplicateStr` (utils/var.ts).
bool hasDuplicateStr(Iterable<String> strings) {
  final seen = <String>{};
  return strings.any((s) => !seen.add(s));
}

/// The list duplicate check of start/var-list.tsx and use-config.ts: the `varKeyError.keyAlreadyExists` message for a
/// repeated variable name, else for a repeated label; null when there is none.
String? startVarDuplicateError(List<Object?> list, StartTranslate t) {
  final String type;
  if (hasDuplicateStr([for (final v in list) jsKey(jsGet(v, 'variable'))])) {
    type = 'variableConfig.varName';
  } else if (hasDuplicateStr([for (final v in list) jsKey(jsGet(v, 'label'))])) {
    type = 'variableConfig.labelName';
  } else {
    return null;
  }
  return t('app-debug', 'varKeyError.keyAlreadyExists', {'key': t('app-debug', type)});
}

/// use-config.ts: the variables' edits, renames reaching the workflow's references, removals confirmed while a
/// variable is in use. [inputs] reads the node's data as it is now; the rest are Dify's hooks (`useWorkflow`,
/// `useInspectVarsCrud`, the toast). [onChanged] reports the confirm dialog opening or closing.
class StartConfig {
  StartConfig({
    required this.id,
    required this.inputs,
    required this.setInputs,
    this.readOnly = false,
    this.isChatMode = false,
    this.handleOutVarRenameChange,
    this.isVarUsedInNodes,
    this.removeUsedVarInNodes,
    this.nodesWithInspectVars = _noInspectVars,
    this.deleteInspectVar,
    this.deleteNodeInspectorVars,
    this.renameInspectVarName,
    this.toastError,
    this.t = DifyI18n.tr,
    this.onChanged,
  });

  final String id;
  final Map<String, Object?> Function() inputs;
  final void Function(Map<String, Object?> inputs) setInputs;
  final bool readOnly, isChatMode;
  final void Function(String nodeId, List<String> oldSelector, List<String> newSelector)? handleOutVarRenameChange;
  final bool Function(List<String> selector)? isVarUsedInNodes;
  final void Function(List<String> selector)? removeUsedVarInNodes;
  final List<Map<String, Object?>> Function() nodesWithInspectVars;
  final void Function(String nodeId, String varId)? deleteInspectVar;
  final void Function(String nodeId)? deleteNodeInspectorVars;
  final void Function(String nodeId, String oldName, String newName)? renameInspectVarName;
  final void Function(String message)? toastError;
  final StartTranslate t;
  final void Function()? onChanged;

  static List<Map<String, Object?>> _noInspectVars() => const [];

  bool isShowRemoveVarConfirm = false;
  List<String> _removedVar = const [];
  int _removedIndex = 0;

  List<Object?> get _variables => jsList(inputs()['variables']);

  /// handleVarListChange: [moreInfo] is the change at [index] (a rename or a removal), absent for other edits and
  /// reorders.
  void handleVarListChange(List<Object?> newList, [({int index, VarChange payload})? moreInfo]) {
    final change = moreInfo?.payload;
    if (change != null && change.isRemove) {
      final key = change.beforeKey ?? '';
      final varId = jsStr(
        jsGet(
          jsList(
            nodesWithInspectVars().where((n) => n['nodeId'] == id).firstOrNull?['vars'],
          ).where((v) => jsGet(v, 'name') == key).firstOrNull,
          'id',
        ),
      );
      if (varId != null) deleteInspectVar?.call(id, varId);
      if (isVarUsedInNodes?.call([id, key]) ?? false) {
        isShowRemoveVarConfirm = true;
        _removedVar = [id, key];
        _removedIndex = moreInfo!.index;
        onChanged?.call();
        return;
      }
    }
    final before = _variables;
    setInputs({...inputs(), 'variables': newList});
    if (change != null && change.isRename) {
      final i = moreInfo!.index;
      final oldName = jsKey(jsGet(before[i], 'variable'));
      final newName = jsKey(jsGet(newList[i], 'variable'));
      handleOutVarRenameChange?.call(id, [id, oldName], [id, newName]);
      renameInspectVarName?.call(id, oldName, newName);
    } else if (change == null || !change.isRemove) {
      deleteNodeInspectorVars?.call(id);
    }
  }

  void hideRemoveVarConfirm() {
    isShowRemoveVarConfirm = false;
    onChanged?.call();
  }

  /// onRemoveVarConfirm (removeVarInNode).
  void onRemoveVarConfirm() {
    final list = [..._variables];
    if (_removedIndex < list.length) list.removeAt(_removedIndex);
    setInputs({...inputs(), 'variables': list});
    removeUsedVarInNodes?.call(_removedVar);
    isShowRemoveVarConfirm = false;
    onChanged?.call();
  }

  /// handleAddVariable: false (after toasting why) when the name or label is taken.
  bool handleAddVariable(Map<String, Object?> payload) {
    final list = [..._variables, payload];
    final error = startVarDuplicateError(list, t);
    if (error != null) {
      toastError?.call(error);
      return false;
    }
    setInputs({...inputs(), 'variables': list});
    return true;
  }
}

/// One single-run form (before-run-form/form.tsx props): its label, inputs and values.
typedef StartRunForm = ({
  String label,
  List<Map<String, Object?>> inputs,
  Map<String, Object?> values,
  void Function(Map<String, Object?> values) onChange,
});

/// use-single-run-form-params.ts.
({
  List<StartRunForm> forms,
  List<List<String>> Function() getDependentVars,
  List<String> Function(String variable) getDependentVar,
})
startSingleRunFormParams({
  required String id,
  required Map<String, Object?> payload,
  required Map<String, Object?> runInputData,
  required void Function(Map<String, Object?> values) setRunInputData,
  bool isChatMode = false,
  StartTranslate t = DifyI18n.tr,
}) {
  final variables = jsList(payload['variables']);
  final inputs = <Map<String, Object?>>[
    for (final v in variables) {...(v as Map).cast<String, Object?>(), 'getVarValueFromDependent': true},
    if (isChatMode) {'label': 'sys.query', 'variable': '#sys.query#', 'type': 'text-input', 'required': true},
    {'label': 'sys.files', 'variable': '#sys.files#', 'type': 'file-list', 'required': false},
  ];
  return (
    forms: [
      (
        label: t('workflow', 'nodes.llm.singleRun.variable'),
        inputs: inputs,
        values: runInputData,
        onChange: setRunInputData,
      ),
    ],
    getDependentVars: () => [
      for (final v in variables) [id, jsKey(jsGet(v, 'variable'))],
      ['sys', 'files'],
      if (isChatMode) ['sys', 'query'],
    ],
    getDependentVar: (variable) => [id, variable],
  );
}
