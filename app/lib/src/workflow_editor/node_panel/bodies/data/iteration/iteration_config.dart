/// The Iteration panel's logic (iteration/use-config.ts) and the container limits the host may set.
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../../../../../workflow/dify_json.dart';
import '../../../../../workflow/var_types.dart';
import '../../../../header/checklist/node_validators.dart' as validators show loopNodeMaxCount;
import '../../../../panel_fields/panel_fields.dart';
import '../../../node_panel_bodies.dart';
import '../data_common.dart' show childrenOf, wf;
import '../../../panel_edit.dart' show NodeVars;
import '../../../panel_edit.dart' as edit;

/// `MIN_ITERATION_PARALLEL_NUM`.
const minIterationParallelNum = 1;

/// The deployment's `NEXT_PUBLIC_MAX_PARALLEL_LIMIT` (default 10) and `NEXT_PUBLIC_LOOP_NODE_MAX_COUNT` (default
/// 100) for the Iteration and Loop panels below it.
class ContainerLimits extends InheritedWidget {
  const ContainerLimits({
    super.key,
    this.maxParallelLimit = 10,
    this.loopNodeMaxCount = validators.loopNodeMaxCount,
    required super.child,
  });

  final int maxParallelLimit;
  final int loopNodeMaxCount;

  static const _defaults = ContainerLimits(child: SizedBox.shrink());

  static ContainerLimits of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ContainerLimits>() ?? _defaults;

  @override
  bool updateShouldNotify(ContainerLimits old) =>
      maxParallelLimit != old.maxParallelLimit || loopNodeMaxCount != old.loopNodeMaxCount;
}

/// `filterInputVar`: arrays only.
bool filterIterationInputVar(String? type) => const {
  VarType.array,
  VarType.arrayString,
  VarType.arrayBoolean,
  VarType.arrayNumber,
  VarType.arrayObject,
  VarType.arrayFile,
}.contains(type);

/// The `output_type` an output item type collects into (`handleOutputVarChange`); anything else is array[string].
String iterationOutputType(String? itemType) =>
    const {
      VarType.string: VarType.arrayString,
      VarType.number: VarType.arrayNumber,
      VarType.object: VarType.arrayObject,
      VarType.file: VarType.arrayFile,
      VarType.array: VarType.array,
      VarType.arrayFile: VarType.arrayFile,
      VarType.arrayString: VarType.arrayString,
      VarType.arrayNumber: VarType.arrayNumber,
      VarType.arrayObject: VarType.arrayObject,
    }[itemType] ??
    VarType.arrayString;

/// The error response modes (`ErrorHandleMode`) with their `nodes.iteration.ErrorMethod.*` names.
List<SelectOption<String>> iterationErrorModes() => [
  (value: 'terminated', label: wf('nodes.iteration.ErrorMethod.operationTerminated')),
  (value: 'continue-on-error', label: wf('nodes.iteration.ErrorMethod.continueOnError')),
  (value: 'remove-abnormal-output', label: wf('nodes.iteration.ErrorMethod.removeAbnormalOutput')),
];

/// useConfig of the Iteration node: [inputs] is the node's data, [setInputs] Dify's `setInputs`.
class IterationConfig {
  IterationConfig({
    required this.id,
    required this.inputs,
    required this.setInputs,
    this.readOnly = false,
    this.deleteNodeInspectorVars,
    this.iterationChildrenNodes = const [],
    this.childrenNodeVars = const VarScope(),
  });

  /// The panel's config for [props]' node: the output picker offers its children's variables only.
  factory IterationConfig.of(NodePanelProps props) {
    final children = childrenOf(props.controller.doc, props.id);
    return IterationConfig(
      id: props.id,
      inputs: props.data,
      setInputs: (next) => edit.setInputs(props, next),
      readOnly: props.readOnly,
      deleteNodeInspectorVars: props.actions.store.deleteNodeInspectVars,
      iterationChildrenNodes: children,
      childrenNodeVars: NodeVars.scopeOver(props, children, environment: false, conversation: false),
    );
  }

  final String id;
  final Map<String, Object?> inputs;
  final void Function(Map<String, Object?> next) setInputs;
  final bool readOnly;
  final void Function(String nodeId)? deleteNodeInspectorVars;
  final List<Node> iterationChildrenNodes;
  final VarScope childrenNodeVars;

  bool filterInputVar(PickerVar v) => filterIterationInputVar(v.type);

  void handleInputChange(List<String> input, [PickerVar? varInfo]) => setInputs({
    ...inputs,
    'iterator_selector': input,
    'iterator_input_type': varInfo?.type ?? VarType.arrayString,
  });

  void handleOutputVarChange(List<String> output, [PickerVar? varInfo]) {
    if (jsonEquals(inputs['output_selector'], output)) return;
    setInputs({...inputs, 'output_selector': output, 'output_type': iterationOutputType(varInfo?.type)});
    deleteNodeInspectorVars?.call(id);
  }

  void changeParallel(bool value) => setInputs({...inputs, 'is_parallel': value});
  void changeErrorResponseMode(String mode) => setInputs({...inputs, 'error_handle_mode': mode});
  void changeParallelNums(num value) => setInputs({...inputs, 'parallel_nums': value});
  void changeFlattenOutput(bool value) => setInputs({...inputs, 'flatten_output': value});
}
