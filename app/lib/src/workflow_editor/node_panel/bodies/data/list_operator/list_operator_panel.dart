/// The List Operator's panel (nodes/list-operator/panel.tsx with use-config.ts): the input array, the filter
/// condition, "Extract the N item", "Top N", the order and the output variables.
library;

import 'package:flutter/widgets.dart';

import '../../../../../workflow/dify_json.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../node_panel_bodies.dart';
import '../data_common.dart';
import 'list_operator_model.dart';
import 'list_operator_widgets.dart';
import '../../../panel_edit.dart';

/// What the panel derives from the node (use-config.ts): the input's type, its item type and how that shows.
typedef ListOperatorTypes = ({String? varType, String itemVarType, String itemVarTypeShowName, bool hasSubVariable});

/// `getType()` and the values use-config.ts derives from it, for [data] in [scope].
ListOperatorTypes listOperatorTypes(Map<String, Object?> data, VarScope scope) {
  final selector = [for (final s in jsList(data['variable'])) jsKey(s)];
  final varType = scope.typeOf?.call(selector);
  final item = getItemVarType(varType);
  return (
    varType: varType,
    itemVarType: item,
    // `!!inputs.variable`: an empty selector still counts.
    itemVarTypeShowName: getItemVarTypeShowName(item, data['variable'] != null),
    hasSubVariable: supportsSubVariable(varType),
  );
}

/// The panel body.
Widget listOperatorPanelBody(BuildContext context, NodePanelProps props) => _ListOperatorPanel(props: props);

class _ListOperatorPanel extends StatelessWidget {
  const _ListOperatorPanel({required this.props});
  final NodePanelProps props;

  @override
  Widget build(BuildContext context) {
    final p = props;
    final data = p.data;
    final readOnly = p.readOnly;
    final scope = NodeVars.of(p).scope;
    final nodesMap = NodeVars.of(p).nodesMap;
    final version = versionOf(p);
    final types = listOperatorTypes(data, scope);
    void set(Map<String, Object?> next, [int? base]) => setInputs(p, next, base: base);
    Map<String, Object?> section(String key) => switch (data[key]) {
      final Map<String, Object?> m => m,
      _ => const {},
    };
    final filterBy = section('filter_by'), extractBy = section('extract_by'), orderBy = section('order_by');
    final limit = data['limit'] is Map<String, Object?> ? data['limit']! as Map<String, Object?> : null;

    Widget toggle(Object? checked, ValueChanged<bool> onChange) =>
        DifySwitch(checked: jsTruthy(checked), disabled: readOnly, onCheckedChange: onChange);

    final orderCards = [
      for (final (value, key) in const [(OrderBy.asc, 'asc'), (OrderBy.desc, 'desc')])
        OptionCard(
          title: wf('nodes.listFilter.$key'),
          selected: orderBy['value'] == value,
          onSelect: () => set(updateOrderByType(data, value)),
        ),
    ];

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 16,
              children: [
                Field(
                  title: wf('nodes.listFilter.inputVar'),
                  required: true,
                  child: VarReferencePicker(
                    readonly: readOnly,
                    value: [for (final s in jsList(data['variable'])) jsKey(s)],
                    scope: scope,
                    filterVar: (v, _) => canFilterVariable(v.type),
                    isSupportFileVar: false,
                    typePlaceHolder: 'Array',
                    onChange: (selector, _) {
                      final varType = scope.typeOf?.call(selector);
                      set(
                        updateListFilterVariable(
                          data,
                          variable: selector,
                          varType: varType,
                          itemVarType: getItemVarType(varType),
                        ),
                      );
                    },
                  ),
                ),
                Field(
                  title: wf('nodes.listFilter.filterCondition'),
                  operations: toggle(filterBy['enabled'], (v) => set(updateFilterEnabled(data, v))),
                  child: jsTruthy(filterBy['enabled'])
                      ? FilterCondition(
                          condition: switch (jsGet(filterBy['conditions'], '0')) {
                            final Map<String, Object?> m => m,
                            _ => null,
                          },
                          varType: types.itemVarType,
                          hasSubVariable: types.hasSubVariable,
                          readOnly: readOnly,
                          scope: scope,
                          nodesMap: nodesMap,
                          version: version,
                          onChange: (c, base) => set(updateFilterCondition(data, c), base),
                        )
                      : null,
                ),
                const PanelSplit(),
                Field(
                  title: wf('nodes.listFilter.extractsCondition'),
                  operations: toggle(extractBy['enabled'], (v) => set(updateExtractEnabled(data, v))),
                  child: jsTruthy(extractBy['enabled'])
                      ? Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ExtractInput(
                            value: jsKey(extractBy['serial'] ?? ''),
                            readOnly: readOnly,
                            scope: scope,
                            nodesMap: nodesMap,
                            version: version,
                            onChange: (text, base) => set(updateExtractSerial(data, text), base),
                          ),
                        )
                      : null,
                ),
                const PanelSplit(),
                LimitConfig(config: limit, readonly: readOnly, onChange: (l) => set(updateLimit(data, l))),
                const PanelSplit(),
                Field(
                  title: wf('nodes.listFilter.orderBy'),
                  operations: toggle(
                    orderBy['enabled'],
                    (v) => set(updateOrderByEnabled(data, v, types.hasSubVariable)),
                  ),
                  child: !jsTruthy(orderBy['enabled'])
                      ? null
                      : types.hasSubVariable
                      ? LayoutBuilder(
                          builder: (context, c) => Row(
                            children: [
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: SubVariablePicker(
                                    value: jsStr(orderBy['key']) ?? '',
                                    disabled: readOnly,
                                    onChange: (k) => set(updateOrderByKey(data, k)),
                                  ),
                                ),
                              ),
                              // shrink-0 beside the key; scaled down only when the labels cannot fit.
                              ConstrainedBox(
                                constraints: BoxConstraints(maxWidth: c.maxWidth * 0.6),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Row(spacing: 4, children: orderCards),
                                ),
                              ),
                            ],
                          ),
                        )
                      : Row(
                          spacing: 4,
                          children: [for (final card in orderCards) Expanded(child: card)],
                        ),
                ),
                const PanelSplit(),
              ],
            ),
          ),
          OutputVars(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                VarItem(
                  name: 'result',
                  type: 'Array[${types.itemVarTypeShowName}]',
                  description: wf('nodes.listFilter.outputVars.result'),
                ),
                VarItem(
                  name: 'first_record',
                  type: types.itemVarTypeShowName,
                  description: wf('nodes.listFilter.outputVars.first_record'),
                ),
                VarItem(
                  name: 'last_record',
                  type: types.itemVarTypeShowName,
                  description: wf('nodes.listFilter.outputVars.last_record'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
