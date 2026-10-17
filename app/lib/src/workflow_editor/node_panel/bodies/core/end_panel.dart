/// The Output (End) node's panel (nodes/end/panel.tsx, use-config.ts).
library;

import 'package:flutter/widgets.dart';

import '../../../panel_fields/panel_fields.dart';
import '../../node_panel_bodies.dart';
import 'core_kit.dart';

/// use-config.ts with `useVarList({varKey: 'outputs'})`.
class EndConfig {
  EndConfig(this.crud, {required this.readOnly});
  final PanelInputs crud;
  final bool readOnly;

  Map<String, Object?> get inputs => crud.inputs;

  void handleVarListChange(List<Object?> list) => crud.setInputs({...inputs, 'outputs': list});

  void handleAddVariable() => crud.setInputs({
    ...inputs,
    'outputs': [
      ...jsonListOf(inputs['outputs']),
      {'variable': '', 'value_selector': <Object?>[]},
    ],
  });
}

List<Object?> jsonListOf(Object? x) => x is List ? [...x] : [];

Widget endPanelBody(BuildContext context, NodePanelProps props) {
  final config = EndConfig(PanelInputs(props), readOnly: props.readOnly);
  final outputs = config.inputs['outputs'];
  final title = tw('nodes.end.output.variable');
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    child: Field(
      title: title,
      required: true,
      operations: config.readOnly
          ? null
          : FieldAddButton(label: '${tc('operation.add')} $title', onPressed: config.handleAddVariable),
      child: VarList(
        readonly: config.readOnly,
        list: varListItemsOf(outputs),
        scope: panelVars(props).scope,
        onChange: (rows) => config.handleVarListChange(varListDataOf(rows, outputs)),
        onError: CorePanelHost.of(context).toastError,
      ),
    ),
  );
}
