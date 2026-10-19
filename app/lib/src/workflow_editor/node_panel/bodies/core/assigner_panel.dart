/// The Variable Assigner node's panel (nodes/assigner/panel.tsx, use-config.ts, components/var-list,
/// components/operation-selector.tsx).
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../workflow/dify_json.dart';
import '../../../../workflow/var_types.dart';
import '../../../code_editor/code_editor.dart';
import '../../../panel_fields/panel_fields.dart';
import '../../node_panel_bodies.dart';
import '../../panel_edit.dart';
import 'assigner_utils.dart';
import 'core_kit.dart';

export 'assigner_utils.dart';

/// use-config.ts: the panel works on [convertV1ToV2] of the node's data and every write is version 2. [varTypeOf]
/// is `getCurrentVariableType` over the upstream nodes (and the iteration the node is in).
class AssignerConfig {
  AssignerConfig({
    required this.rawInputs,
    required this.setInputs,
    this.readOnly = false,
    this.varTypeOf,
  });

  final Map<String, Object?> Function() rawInputs;
  final ValueChanged<Map<String, Object?>> setInputs;
  final bool readOnly;
  final String? Function(List<String> selector)? varTypeOf;

  Map<String, Object?> get inputs => convertV1ToV2(rawInputs());

  List<String> get writeModeTypes => _modes;
  List<String> get writeModeTypesArr => _arrModes;
  List<String> get writeModeTypesNum => _numModes;

  String? getAssignedVarType(List<String> selector) => varTypeOf?.call(selector);

  String getToAssignedVarType(String? assignedVarType, String? writeMode) =>
      normalizeAssignedVarType(assignedVarType, writeMode);

  void handleOperationListChanges(List<Object?> items) {
    if (readOnly) return; // handleNodeDataUpdateWithSyncDraft ignores read-only writes
    setInputs(ensureAssignerVersion(updateOperationItems(inputs, items)));
  }

  /// `filterAssignedVar`: loop variables, else conversation variables.
  bool filterAssignedVar(bool isLoopVariable, List<String> selector) => isLoopVariable || canAssignVar(selector);

  bool filterToAssignedVar(String? type, String? assignedVarType, String? writeMode) =>
      canAssignToVar(type, assignedVarType, writeMode);

  bool Function(String? type) filterVar(String varType) => filterVarByType(varType);
}

const _modes = writeModeTypes, _arrModes = writeModeTypesArr, _numModes = writeModeTypesNum;

String _opLabel(String name) => tw('nodes.assigner.operations.$name');

/// OperationSelector: the operation of one item, from [getOperationItems] for [assignedVarType]; a "Operation"
/// placeholder until one is chosen, disabled until the item has a variable.
class OperationSelector extends StatelessWidget {
  const OperationSelector({
    super.key,
    required this.value,
    required this.onSelect,
    this.disabled = false,
    this.assignedVarType,
    this.writeModeTypes,
    this.writeModeTypesArr,
    this.writeModeTypesNum,
  });

  final Object? value;
  final ValueChanged<OperationItem> onSelect;
  final bool disabled;
  final String? assignedVarType;
  final List<String>? writeModeTypes, writeModeTypesArr, writeModeTypesNum;

  @override
  Widget build(BuildContext context) {
    final items = getOperationItems(assignedVarType, writeModeTypes, writeModeTypesArr, writeModeTypesNum);
    final selected = items.where((i) => i.value == value && isOperationItem(i)).firstOrNull;
    final title = _opLabel('title');
    return DifyDropdownMenu(
      placement: DifyPlacement.bottomStart,
      width: 140,
      builder: (context, controller) => DifyPressable(
        semanticLabel: selected == null ? title : _opLabel(selected.name),
        disabled: disabled,
        onPressed: disabled ? null : controller.toggle,
        builder: (context, hovered, focused) {
          final open = controller.isOpen;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: disabled
                  ? DifyColors.componentsInputBgDisabled
                  : hovered || open
                  ? DifyColors.stateBaseHoverAlt
                  : DifyColors.componentsInputBgNormal,
              borderRadius: BorderRadius.circular(DifyRadius.lg),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 2,
              children: [
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Text(
                      selected == null ? title : _opLabel(selected.name),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: difyTextStyle(
                        DifyType.systemSmRegular,
                        selected == null
                            ? DifyColors.componentsInputTextDisabled
                            : DifyColors.componentsInputTextFilled,
                      ),
                    ),
                  ),
                ),
                RemixIcon(
                  'arrow-down-s-line',
                  size: 16,
                  color: disabled
                      ? DifyColors.componentsInputTextPlaceholder
                      : open
                      ? DifyColors.textSecondary
                      : DifyColors.textQuaternary,
                ),
              ],
            ),
          );
        },
      ),
      children: [
        DifyMenuGroupLabel(title),
        for (final item in items)
          if (!isOperationItem(item))
            const DifyMenuSeparator()
          else
            DifyMenuItem(
              onSelect: () => onSelect(item),
              trailing: item.value == value ? RemixIcon('check-line', size: 16, color: DifyColors.textAccent) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  _opLabel(item.name),
                  style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary),
                ),
              ),
            ),
      ],
    );
  }
}

/// The assigner's VarList (components/var-list/index.tsx): per operation, the assigned variable and the operation,
/// then what the operation needs: a variable to assign (over-write, append, extend), a constant (set: a number,
/// text, True / False or JSON by the variable's type), a number (`+=` ...), or nothing (clear, remove first / last).
class AssignerVarList extends StatelessWidget {
  const AssignerVarList({
    super.key,
    required this.readonly,
    required this.list,
    required this.onChange,
    required this.scope,
    this.onOpen,
    this.filterVar,
    this.filterToAssignedVar,
    this.getAssignedVarType,
    this.getToAssignedVarType,
    this.writeModeTypes,
    this.writeModeTypesArr,
    this.writeModeTypesNum,
  });

  final bool readonly;
  final List<Map<String, Object?>> list;

  /// The new list, and the value just picked or typed (Dify's second argument).
  final void Function(List<Map<String, Object?>> list, [Object? value]) onChange;
  final VarScope scope;
  final ValueChanged<int>? onOpen;
  final VarFilter? filterVar;
  final bool Function(String? type, String? assignedVarType, String? writeMode)? filterToAssignedVar;
  final String? Function(List<String> selector)? getAssignedVarType;
  final String Function(String? assignedVarType, String? writeMode)? getToAssignedVarType;
  final List<String>? writeModeTypes, writeModeTypesArr, writeModeTypesNum;

  List<Map<String, Object?>> _copy() => [
    for (final m in list) {...m},
  ];

  void _assignedVarChange(int index, List<String> value) {
    final next = _copy();
    next[index]
      ..['variable_selector'] = value
      ..['operation'] = WriteMode.overwrite
      ..['input_type'] = AssignerNodeInputType.variable
      ..['value'] = null;
    onChange(next, value);
  }

  void _operationChange(int index, String? varType, OperationItem item) {
    final next = _copy();
    final row = next[index]
      ..['operation'] = item.value
      ..['value'] = '';
    if (item.value == WriteMode.set || _numModes.contains(item.value)) {
      if (varType == VarType.boolean) row['value'] = false;
      row['input_type'] = AssignerNodeInputType.constant;
    } else {
      row['input_type'] = AssignerNodeInputType.variable;
    }
    onChange(next);
  }

  void _toAssignedVarChange(int index, Object? value) {
    final next = _copy();
    next[index]['value'] = value;
    onChange(next, value);
  }

  void _remove(int index) => onChange(_copy()..removeAt(index));

  VarFilter _filterToAssigned(int index) => (v, selector) {
    final item = list[index];
    final assigned = item['variable_selector'];
    final operation = jsStr(item['operation']);
    if (assigned == null || operation == null || filterToAssignedVar == null) return true;
    final sel = selectorList(assigned);
    final assignedVarType = getAssignedVarType?.call(sel);
    final isSame = assigned is List && sel.join('.') == selector.join('.');
    return !isSame && (assignedVarType == null || filterToAssignedVar!(v.type, assignedVarType, operation));
  };

  @override
  Widget build(BuildContext context) {
    if (list.isEmpty) return ListNoDataPlaceholder(tw('nodes.assigner.noVarTip'));
    final num = writeModeTypesNum ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        for (final (index, item) in list.indexed)
          () {
            final selector = selectorList(item['variable_selector']);
            final operation = jsStr(item['operation']);
            final assignedVarType = item['variable_selector'] != null ? getAssignedVarType?.call(selector) : null;
            final toAssignedVarType = assignedVarType != null && operation != null && getToAssignedVarType != null
                ? getToAssignedVarType!(assignedVarType, operation)
                : null;
            final value = item['value'];
            void set(Object? v) => _toAssignedVarChange(index, v);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 4,
                    children: [
                      // The operation keeps its width (it shrinks only if it is wider than the row); the picker
                      // (`w-full`) takes the rest.
                      JustifyBetween(
                        leadShare: 0.5,
                        lead: VarReferencePicker(
                          readonly: readonly,
                          value: selector,
                          scope: scope,
                          onChange: (sel, _) => _assignedVarChange(index, sel),
                          onOpen: (open) {
                            if (open) onOpen?.call(index);
                          },
                          filterVar: filterVar,
                          placeholder: tw('nodes.assigner.selectAssignedVariable'),
                          minWidth: 352,
                          popupFor: 'assigned',
                        ),
                        trail: Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: OperationSelector(
                              value: operation,
                              disabled: selector.isEmpty,
                              onSelect: (op) => _operationChange(index, assignedVarType, op),
                              assignedVarType: assignedVarType,
                              writeModeTypes: writeModeTypes,
                              writeModeTypesArr: writeModeTypesArr,
                              writeModeTypesNum: writeModeTypesNum,
                            ),
                          ),
                        ),
                      ),
                      if (operationTakesVariable(operation) && !num.contains(operation))
                        VarReferencePicker(
                          readonly: readonly || !jsTruthy(item['variable_selector']) || !jsTruthy(item['operation']),
                          value: selectorList(value),
                          scope: scope,
                          onChange: (sel, _) => set(sel),
                          filterVar: _filterToAssigned(index),
                          valueTypePlaceHolder: toAssignedVarType,
                          placeholder: tw('nodes.assigner.setParameter'),
                          minWidth: 352,
                          popupFor: 'toAssigned',
                        ),
                      if (operation == WriteMode.set && assignedVarType != null)
                        switch (assignedVarType) {
                          'number' => _NumberInput(value: value, onChanged: set),
                          'string' => DifyTextarea(
                            semanticLabel: selector.isNotEmpty ? selector.join('.') : tw('nodes.assigner.setParameter'),
                            value: value is String ? value : '${value ?? ''}',
                            onChanged: set,
                          ),
                          'boolean' => BoolValue(value: value == true, onChange: set),
                          'object' => DifyCodeEditor(
                            value: value is String ? value : '${value ?? ''}',
                            language: CodeLanguage.json,
                            onChange: set,
                            readOnly: readonly,
                          ),
                          _ => const SizedBox.shrink(),
                        },
                      if (num.contains(operation))
                        _NumberInput(value: value, onChanged: set, placeholder: 'Enter number value...'),
                    ],
                  ),
                ),
                DifyIconButton(
                  label: tc('operation.remove'),
                  size: DifyIconButtonSize.lg,
                  tone: DifyButtonTone.destructive,
                  onPressed: () => _remove(index),
                  icon: const RemixIcon('delete-bin-line', size: 16),
                ),
              ],
            );
          }(),
      ],
    );
  }
}

String _numText(Object? v) => switch (v) {
  final double d when d == d.truncateToDouble() && d.isFinite => '${d.toInt()}',
  final num n => '$n',
  null => '',
  _ => '$v',
};

/// `Input type="number"`: every edit reports `Number(text)` (0 when empty); the text is kept while it means the
/// value.
class _NumberInput extends StatefulWidget {
  const _NumberInput({required this.value, required this.onChanged, this.placeholder});
  final Object? value;
  final ValueChanged<num> onChanged;
  final String? placeholder;

  @override
  State<_NumberInput> createState() => _NumberInputState();
}

class _NumberInputState extends State<_NumberInput> {
  late String _text = _numText(widget.value);

  static num _parse(String s) => num.tryParse(s.trim()) ?? 0;

  @override
  void didUpdateWidget(_NumberInput old) {
    super.didUpdateWidget(old);
    if (widget.value is! num || _parse(_text) != widget.value) _text = _numText(widget.value);
  }

  @override
  Widget build(BuildContext context) => DifyInput(
    value: _text,
    placeholder: widget.placeholder,
    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
    formatters: [FilteringTextInputFormatter.allow(RegExp(r'[-+0-9.eE]'))],
    onChanged: (s) {
      _text = s;
      widget.onChanged(_parse(s));
    },
  );
}

/// panel.tsx.
Widget assignerPanelBody(BuildContext context, NodePanelProps props) {
  final crud = PanelInputs(props);
  final vars = NodeVars.of(props);
  final scope = vars.scope;
  final config = AssignerConfig(
    rawInputs: () => crud.inputs,
    setInputs: crud.setInputs,
    readOnly: props.readOnly,
    varTypeOf: scope.typeOf,
  );
  final items = [
    for (final i in jsList(config.inputs['items']))
      if (i is Map) i.cast<String, Object?>(),
  ];
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 4,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              Expanded(
                child: Text(
                  tw('nodes.assigner.variables').toUpperCase(),
                  style: difyTextStyle(DifyType.systemSmSemiboldUppercase, DifyColors.textSecondary),
                ),
              ),
              DifyIconButton(
                label: tc('operation.add'),
                onPressed: () =>
                    config.handleOperationListChanges(handleAddOperationItem(config.inputs['items'] as List)),
                icon: RemixIcon('add-line', size: 16, color: DifyColors.textTertiary),
              ),
            ],
          ),
          AssignerVarList(
            readonly: config.readOnly,
            list: items,
            scope: scope,
            onChange: (list, [_]) => config.handleOperationListChanges(list),
            filterVar: (v, sel) => config.filterAssignedVar(scope.lookup(sel.first)?.type == 'loop', sel),
            filterToAssignedVar: config.filterToAssignedVar,
            getAssignedVarType: config.getAssignedVarType,
            getToAssignedVarType: config.getToAssignedVarType,
            writeModeTypes: config.writeModeTypes,
            writeModeTypesArr: config.writeModeTypesArr,
            writeModeTypesNum: config.writeModeTypesNum,
          ),
        ],
      ),
    ),
  );
}
