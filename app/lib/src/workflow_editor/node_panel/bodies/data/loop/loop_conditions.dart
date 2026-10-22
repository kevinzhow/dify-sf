/// The Loop's termination-condition builder (nodes/loop/components: condition-wrap, condition-add,
/// condition-list/index, condition-item, condition-var-selector, condition-operator, condition-input,
/// condition-number-input): Dify's loop-specific copy of the IF/ELSE builder.
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../../workflow/var_types.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../../prompt_editor/prompt_editor.dart';
import '../data_common.dart';
import 'loop_config.dart';
import 'loop_utils.dart';

/// The handlers a condition list edits through (`handle*Condition`, `handle*SubVariableCondition`).
class ConditionHandlers {
  const ConditionHandlers({
    this.onAdd,
    this.onRemove,
    this.onUpdate,
    this.onToggle,
    this.onAddSub,
    this.onRemoveSub,
    this.onUpdateSub,
    this.onToggleSub,
  });

  /// The Loop panel's handlers.
  factory ConditionHandlers.of(LoopConfig c) => ConditionHandlers(
    onAdd: c.handleAddCondition,
    onRemove: c.handleRemoveCondition,
    onUpdate: c.handleUpdateCondition,
    onToggle: c.handleToggleConditionLogicalOperator,
    onAddSub: c.handleAddSubVariableCondition,
    onRemoveSub: c.handleRemoveSubVariableCondition,
    onUpdateSub: c.handleUpdateSubVariableCondition,
    onToggleSub: c.handleToggleSubVariableConditionLogicalOperator,
  );

  final void Function(List<String> selector, PickerVar variable)? onAdd;
  final void Function(String conditionId)? onRemove;
  final void Function(String conditionId, Json condition)? onUpdate;
  final VoidCallback? onToggle;
  final void Function(String conditionId, [String? key])? onAddSub;
  final void Function(String conditionId, String subConditionId)? onRemoveSub;
  final void Function(String conditionId, String subConditionId, Json condition)? onUpdateSub;
  final void Function(String conditionId)? onToggleSub;
}

/// Where the conditions' variables come from: [availableVars] to pick from, the nodes they belong to ([lookup] with
/// the Start node [start]; Dify's `availableNodes`), [numberVariables] for number comparisons against a variable and
/// [allNodes] for those (VariableTag without `availableNodes` looks in every node).
class ConditionVars {
  const ConditionVars({
    this.availableVars = const [],
    this.lookup = _none,
    this.start,
    this.numberVariables = const [],
    this.allNodes = _none,
    this.nodesMap = const {},
  });

  final List<VarGroup> availableVars;
  final Node? Function(String id) lookup;
  final Node? start;
  final List<VarGroup> numberVariables;
  final Node? Function(String id) allNodes;
  final Map<String, WorkflowNodeInfo> nodesMap;

  static Node? _none(String _) => null;
}

Widget _popupBox({required Widget child, double width = 296}) => Container(
  width: width,
  decoration: BoxDecoration(
    color: DifyColors.componentsPanelBgBlur,
    borderRadius: BorderRadius.circular(DifyRadius.lg),
    border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
    boxShadow: DifyShadows.lg,
  ),
  child: child,
);

/// condition-wrap.tsx: the condition list in its panel box, then "Add Condition" (or, for the sub-variable
/// conditions of [conditionId], "Sub Variable" over the file attributes).
class ConditionWrap extends StatelessWidget {
  const ConditionWrap({
    super.key,
    required this.conditions,
    required this.logicalOperator,
    required this.handlers,
    required this.vars,
    this.isSubVariable = false,
    this.conditionId,
    this.readOnly = false,
  });

  final List<Json> conditions;
  final String? logicalOperator;
  final ConditionHandlers handlers;
  final ConditionVars vars;
  final bool isSubVariable;
  final String? conditionId;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final n = conditions.length;
    final footer = Padding(
      padding: EdgeInsets.only(
        right: 30,
        top: n == 0 ? (isSubVariable ? 8 : 4) : 0,
        left: n > 1 && !isSubVariable ? 60 : 0,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: isSubVariable
            ? DifyDropdownMenu(
                placement: DifyPlacement.bottomStart,
                width: 165,
                builder: (context, c) => DifyButton(
                  size: DifyButtonSize.small,
                  disabled: readOnly,
                  onPressed: c.toggle,
                  leading: const RemixIcon('add-line', size: 14),
                  child: Text(wf('nodes.ifElse.addSubVariable')),
                ),
                children: [
                  DifyMenuRadioGroup<String>(
                    value: null,
                    onValueChange: (v) => handlers.onAddSub?.call(conditionId!, v),
                    children: [
                      for (final k in subVariables) DifyMenuRadioItem(value: k, closeOnClick: true, child: Text(k)),
                    ],
                  ),
                ],
              )
            : ConditionAdd(
                disabled: readOnly,
                variables: vars.availableVars,
                onSelectVariable: (sel, v) => handlers.onAdd?.call(sel, v),
              ),
      ),
    );
    return Container(
      constraints: BoxConstraints(minHeight: isSubVariable ? 0 : 40),
      padding: isSubVariable
          ? const EdgeInsets.symmetric(horizontal: 4, vertical: 8)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(color: DifyColors.componentsPanelBg, borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (n > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ConditionList(
                disabled: readOnly,
                conditionId: conditionId,
                conditions: conditions,
                logicalOperator: logicalOperator,
                handlers: handlers,
                vars: vars,
                isSubVariable: isSubVariable,
              ),
            ),
          footer,
        ],
      ),
    );
  }
}

/// condition-add.tsx: a small "Add Condition" button opening the variable list (w-74, file variables included).
class ConditionAdd extends StatefulWidget {
  const ConditionAdd({super.key, required this.variables, required this.onSelectVariable, this.disabled = false});
  final List<VarGroup> variables;
  final void Function(List<String> selector, PickerVar variable) onSelectVariable;
  final bool disabled;

  @override
  State<ConditionAdd> createState() => _ConditionAddState();
}

class _ConditionAddState extends State<ConditionAdd> {
  final _popup = DifyFloatingController();
  final _search = FocusNode(debugLabel: 'condition add search');

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DifyPopover(
    controller: _popup,
    placement: DifyPlacement.bottomStart,
    sideOffset: 4,
    surface: false,
    initialFocus: _search,
    builder: (context, c) => DifyButton(
      size: DifyButtonSize.small,
      disabled: widget.disabled,
      onPressed: c.toggle,
      leading: const RemixIcon('add-line', size: 14),
      child: Text(wf('nodes.ifElse.addCondition')),
    ),
    content: _popupBox(
      child: VarReferenceVars(
        vars: widget.variables,
        isSupportFileVar: true,
        searchFocusNode: _search,
        onClose: _popup.close,
        onChange: (sel, v) {
          widget.onSelectVariable(sel, v);
          _popup.close();
        },
      ),
    ),
  );
}

/// condition-list/index.tsx: the conditions, with the AND / OR bracket and toggle when there are several.
class ConditionList extends StatelessWidget {
  const ConditionList({
    super.key,
    required this.conditions,
    required this.handlers,
    required this.vars,
    this.logicalOperator,
    this.conditionId,
    this.isSubVariable = false,
    this.disabled = false,
  });

  final List<Json> conditions;
  final ConditionHandlers handlers;
  final ConditionVars vars;
  final String? logicalOperator;
  final String? conditionId;
  final bool isSubVariable, disabled;

  void _toggle() {
    if (isSubVariable && conditionId != null) {
      handlers.onToggleSub?.call(conditionId!);
    } else {
      handlers.onToggle?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = conditions.length;
    final and = logicalOperator == 'and';
    final itemPadding = isSubVariable && n > 1 ? (and ? 51.0 : 42.0) : 0.0;
    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, c) in conditions.indexed)
          Padding(
            key: ValueKey(c['id']),
            padding: EdgeInsets.only(left: itemPadding, bottom: i == n - 1 ? 0 : 4),
            child: ConditionItem(
              disabled: disabled,
              conditionId: isSubVariable ? conditionId! : '${c['id']}',
              condition: c,
              isValueFieldShort: isSubVariable && n > 1,
              isSubVariableKey: isSubVariable,
              handlers: handlers,
              vars: vars,
            ),
          ),
      ],
    );
    if (n < 2) return list;
    final left = isSubVariable ? (and ? -10.0 : -18.0) : 0.0;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: EdgeInsets.only(left: isSubVariable ? 0 : 60),
          child: list,
        ),
        Positioned(
          top: 0,
          bottom: 0,
          left: left,
          width: 60,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                top: 16,
                bottom: 16,
                left: 46,
                width: 10,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.horizontal(left: Radius.circular(8)),
                    border: Border(
                      top: BorderSide(color: DifyColors.dividerDeep),
                      left: BorderSide(color: DifyColors.dividerDeep),
                      bottom: BorderSide(color: DifyColors.dividerDeep),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: Center(child: Container(width: 16, height: 29, color: DifyColors.componentsPanelBg)),
              ),
              Positioned(
                right: 4,
                top: 0,
                bottom: 0,
                child: Center(
                  child: Semantics(
                    button: true,
                    label: logicalOperator?.toUpperCase(),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: _toggle,
                        child: Container(
                          height: 21,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(
                            color: DifyColors.componentsButtonSecondaryBg,
                            borderRadius: BorderRadius.circular(DifyRadius.md),
                            border: Border.all(color: DifyColors.componentsButtonSecondaryBorder, width: 0.5),
                            boxShadow: DifyShadows.xs,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                logicalOperator?.toUpperCase() ?? '',
                                style: difyTextStyle(
                                  DifyType.system2xsSemiboldUppercase,
                                  DifyColors.textAccentSecondary,
                                ),
                              ),
                              const SizedBox(width: 2),
                              RemixIcon('loop-left-line', size: 12, color: DifyColors.textAccentSecondary),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// condition-item.tsx: one condition (the variable or, for a sub-variable condition, the file attribute; the
/// operator; the value editor for its type) with a delete button that tints the row while hovered.
class ConditionItem extends StatefulWidget {
  const ConditionItem({
    super.key,
    required this.conditionId,
    required this.condition,
    required this.handlers,
    required this.vars,
    this.disabled = false,
    this.fileKey,
    this.isSubVariableKey = false,
    this.isValueFieldShort = false,
  });

  /// The condition's id; for a sub-variable condition its parent's.
  final String conditionId;
  final Json condition;
  final ConditionHandlers handlers;
  final ConditionVars vars;
  final bool disabled;
  final String? fileKey;
  final bool isSubVariableKey, isValueFieldShort;

  @override
  State<ConditionItem> createState() => _ConditionItemState();
}

class _ConditionItemState extends State<ConditionItem> {
  final _varPopup = DifyFloatingController();
  bool _deleteHovered = false;

  Json get _c => widget.condition;
  String get _id => '${_c['id']}';
  String? get _op => jsStr(_c['comparison_operator']);
  String? get _varType => jsStr(_c['varType']);

  void _update(Json next) {
    if (widget.isSubVariableKey) {
      widget.handlers.onUpdateSub?.call(widget.conditionId, _id, next);
    } else {
      widget.handlers.onUpdate?.call(_id, next);
    }
  }

  void _remove() {
    if (widget.isSubVariableKey) {
      widget.handlers.onRemoveSub?.call(widget.conditionId, _id);
    } else {
      widget.handlers.onRemove?.call(_id);
    }
  }

  String? get _fileKey => widget.fileKey ?? (widget.isSubVariableKey ? jsStr(_c['key']) ?? '' : null);
  bool get _isArrayValue => _fileKey == 'transfer_method' || _fileKey == 'type';

  void _updateValue(Object value) {
    final current = _c['value'];
    if (value == current || (_isArrayValue && value == jsGet(current, '0'))) return;
    _update({
      ..._c,
      'value': _isArrayValue ? [value] : value,
    });
  }

  /// `handleVarChange`: a new variable resets the type, value and operator.
  void _varChange(List<String> selector, PickerVar v) {
    _update({
      for (final e in _c.entries)
        if (!const {'key', 'sub_variable_condition', 'numberVarType'}.contains(e.key)) e.key: e.value,
      'variable_selector': selector,
      'varType': v.type,
      'value': v.type == VarType.boolean ? false : '',
      'comparison_operator': getOperators(v.type).firstOrNull,
    });
    _varPopup.close();
  }

  void _subKeyChange(String key) => widget.handlers.onUpdateSub?.call(widget.conditionId, _id, {
    ..._c,
    'key': key,
    'varType': key == 'size' ? VarType.number : VarType.string,
    'value': '',
    'comparison_operator': getOperators(null, fileKey: key).firstOrNull,
  });

  @override
  Widget build(BuildContext context) {
    final w = widget, op = _op, varType = _varType, fileKey = _fileKey;
    final needsValue = !comparisonOperatorNotRequireValue(op);
    final isSubVariable =
        varType == VarType.arrayFile && const {CmpOp.contains, CmpOp.notContains, CmpOp.allOf}.contains(op);
    final isSelect = op == CmpOp.in_ || op == CmpOp.notIn;
    final isNotInput = isSelect || isSubVariable;
    final selectOptions = !isSelect
        ? const <SelectOption<String>>[]
        : fileKey == 'type' || op == CmpOp.allOf
        ? [for (final (v, k) in fileTypeOptions) (value: v, label: wf('nodes.ifElse.optionName.$k'))]
        : fileKey == 'transfer_method'
        ? [for (final (v, k) in transferMethodOptions) (value: v, label: wf('nodes.ifElse.optionName.$k'))]
        : const <SelectOption<String>>[];
    final selectValue = _isArrayValue ? jsStr(jsGet(_c['value'], '0')) : jsStr(_c['value']);
    final selector = [for (final s in jsList(_c['variable_selector'])) '$s'];
    final canChooseOperator = !w.disabled && (!w.isSubVariableKey || jsTruthy(_c['key']));
    final divider = Border(top: BorderSide(color: DifyColors.dividerSubtle));

    final head = Padding(
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          Expanded(
            child: w.isSubVariableKey
                ? _SubVarSelect(value: jsStr(_c['key']), onChange: _subKeyChange)
                : ConditionVarSelector(
                    controller: _varPopup,
                    valueSelector: selector,
                    varType: varType,
                    vars: w.vars,
                    onChange: _varChange,
                  ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: 1,
            height: 12,
            color: DifyColors.dividerRegular,
          ),
          ConditionOperator(
            disabled: !canChooseOperator,
            varType: varType,
            fileKey: fileKey,
            value: op,
            onSelect: (v) => _update({..._c, 'comparison_operator': v}),
          ),
        ],
      ),
    );
    final body = Container(
      decoration: BoxDecoration(
        color: _deleteHovered ? DifyColors.stateDestructiveHover : DifyColors.componentsInputBgNormal,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          head,
          if (needsValue && !isNotInput && varType != VarType.number && varType != VarType.boolean)
            Container(
              constraints: const BoxConstraints(maxHeight: 100),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(border: divider),
              child: SingleChildScrollView(
                child: ConditionInput(
                  disabled: w.disabled,
                  value: jsStr(_c['value']) ?? '',
                  nodesMap: w.vars.nodesMap,
                  onChange: _updateValue,
                ),
              ),
            ),
          if (needsValue && varType == VarType.boolean)
            Padding(
              padding: const EdgeInsets.all(4),
              child: BoolValue(value: _c['value'] == true || _c['value'] == 'true', onChange: _updateValue),
            ),
          if (needsValue && !isNotInput && varType == VarType.number)
            Container(
              padding: const EdgeInsets.fromLTRB(8, 3, 8, 4),
              decoration: BoxDecoration(border: divider),
              child: ConditionNumberInput(
                numberVarType: jsStr(_c['numberVarType']) ?? 'constant',
                onNumberVarTypeChange: (t) => _update({..._c, 'numberVarType': t, 'value': ''}),
                value: jsStr(_c['value']) ?? '',
                onValueChange: _updateValue,
                variables: w.vars.numberVariables,
                lookup: w.vars.allNodes,
                start: w.vars.start,
                isShort: w.isValueFieldShort,
                unit: fileKey == 'size' ? 'Byte' : null,
              ),
            ),
          if (needsValue && isSelect)
            Container(
              decoration: BoxDecoration(border: divider),
              child: DifySelect<String>(
                value: selectOptions.any((o) => o.value == selectValue) ? selectValue : null,
                options: selectOptions,
                placeholder: cm('placeholder.select'),
                paddingX: 8,
                textStyle: DifyType.systemXsRegular.style,
                onChanged: _updateValue,
              ),
            ),
          if (needsValue && isSubVariable)
            Padding(
              padding: const EdgeInsets.all(4),
              child: ConditionWrap(
                isSubVariable: true,
                conditions: [
                  for (final s in jsList(jsGet(_c['sub_variable_condition'], 'conditions')))
                    if (s is Map) s.cast<String, Object?>(),
                ],
                logicalOperator: jsStr(jsGet(_c['sub_variable_condition'], 'logical_operator')),
                conditionId: w.conditionId,
                readOnly: w.disabled,
                handlers: w.handlers,
                vars: w.vars,
              ),
            ),
        ],
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: body),
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 4),
          child: MouseRegion(
            onEnter: (_) => setState(() => _deleteHovered = true),
            onExit: (_) => setState(() => _deleteHovered = false),
            child: DifyIconButton(
              label: cm('operation.delete'),
              size: DifyIconButtonSize.sm,
              tone: DifyButtonTone.destructive,
              onPressed: _remove,
              icon: const RemixIcon('delete-bin-line', size: 16),
            ),
          ),
        ),
      ],
    );
  }
}

/// The sub-variable key select of a sub-variable condition: the chosen attribute as an accent chip, or "Select".
class _SubVarSelect extends StatelessWidget {
  const _SubVarSelect({required this.value, required this.onChange});
  final String? value;
  final ValueChanged<String> onChange;

  @override
  Widget build(BuildContext context) {
    final selected = subVariables.contains(value) ? value : null;
    return DifyDropdownMenu(
      placement: DifyPlacement.bottomStart,
      width: 165,
      builder: (context, c) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: c.toggle,
        child: SizedBox(
          height: 24,
          child: Align(
            alignment: Alignment.centerLeft,
            child: selected == null
                ? DifyText(
                    cm('placeholder.select'),
                    DifyType.systemSmRegular,
                    color: DifyColors.componentsInputTextPlaceholder,
                  )
                : Container(
                    height: 24,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      color: DifyColors.componentsBadgeWhiteToDark,
                      borderRadius: BorderRadius.circular(DifyRadius.md),
                      border: Border.all(color: DifyColors.componentsPanelBorderSubtle, width: 0.5),
                      boxShadow: DifyShadows.xs,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DifyIcon('vender/solid/development/variable-02', size: 14, color: DifyColors.textAccent),
                        const SizedBox(width: 2),
                        Flexible(child: DifyText(selected, DifyType.systemXsMedium, color: DifyColors.textAccent)),
                      ],
                    ),
                  ),
          ),
        ),
      ),
      children: [
        DifyMenuRadioGroup<String>(
          value: selected,
          onValueChange: onChange,
          children: [
            for (final k in subVariables)
              DifyMenuRadioItem(
                value: k,
                closeOnClick: true,
                leading: DifyIcon('vender/solid/development/variable-02', size: 14, color: DifyColors.textAccent),
                child: Text(k),
              ),
          ],
        ),
      ],
    );
  }
}

/// condition-var-selector.tsx: the condition's variable as a short tag, opening the variable list (w-74, file
/// variables included) through [controller].
class ConditionVarSelector extends StatefulWidget {
  const ConditionVarSelector({
    super.key,
    required this.valueSelector,
    required this.varType,
    required this.vars,
    required this.onChange,
    this.controller,
  });

  final List<String> valueSelector;
  final String? varType;
  final ConditionVars vars;
  final void Function(List<String> selector, PickerVar variable) onChange;
  final DifyFloatingController? controller;

  @override
  State<ConditionVarSelector> createState() => _ConditionVarSelectorState();
}

class _ConditionVarSelectorState extends State<ConditionVarSelector> {
  final _own = DifyFloatingController();
  final _search = FocusNode(debugLabel: 'condition var search');

  DifyFloatingController get _popup => widget.controller ?? _own;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DifyPopover(
    controller: _popup,
    placement: DifyPlacement.bottomStart,
    sideOffset: 4,
    surface: false,
    initialFocus: _search,
    builder: (context, c) => MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: c.toggle,
        child: Align(
          alignment: Alignment.centerLeft,
          child: VariableTag(
            valueSelector: widget.valueSelector,
            varType: widget.varType,
            lookup: widget.vars.lookup,
            start: widget.vars.start,
            isShort: true,
          ),
        ),
      ),
    ),
    content: _popupBox(
      child: VarReferenceVars(
        vars: widget.vars.availableVars,
        isSupportFileVar: true,
        searchFocusNode: _search,
        onClose: _popup.close,
        onChange: widget.onChange,
      ),
    ),
  );
}

/// condition-operator.tsx: a ghost small button with the operator ("Select" at half opacity when none) opening
/// the operators for the type (or file attribute) at `bottom-end`.
class ConditionOperator extends StatelessWidget {
  const ConditionOperator({
    super.key,
    required this.varType,
    required this.onSelect,
    this.value,
    this.fileKey,
    this.disabled = false,
  });

  final String? varType;
  final String? value;
  final String? fileKey;
  final bool disabled;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final options = getOperators(varType, fileKey: fileKey);
    final selected = options.contains(value) ? value : null;
    return DifyDropdownMenu(
      builder: (context, c) => Opacity(
        opacity: selected == null ? 0.5 : 1,
        child: DifyButton(
          size: DifyButtonSize.small,
          variant: DifyButtonVariant.ghost,
          disabled: disabled,
          onPressed: c.toggle,
          trailing: const RemixIcon('arrow-down-s-line', size: 14),
          child: Text(selected == null ? wf('nodes.ifElse.select') : operatorLabel(selected)),
        ),
      ),
      children: [
        DifyMenuRadioGroup<String>(
          value: selected,
          onValueChange: onSelect,
          children: [
            for (final o in options) DifyMenuRadioItem(value: o, closeOnClick: true, child: Text(operatorLabel(o))),
          ],
        ),
      ],
    );
  }
}

/// condition-input.tsx: a compact prompt editor ("Enter value") whose variable blocks show the loop's nodes; its
/// `/` list is empty, as in Dify.
class ConditionInput extends StatelessWidget {
  const ConditionInput({
    super.key,
    required this.value,
    required this.onChange,
    this.nodesMap = const {},
    this.disabled = false,
  });

  final String value;
  final ValueChanged<String> onChange;
  final Map<String, WorkflowNodeInfo> nodesMap;
  final bool disabled;

  @override
  Widget build(BuildContext context) => DifyPromptEditor(
    compact: true,
    value: value,
    placeholder: wf('nodes.ifElse.enterValue'),
    editable: !disabled,
    onChange: onChange,
    workflowVariableBlock: WorkflowVariableBlockConfig(show: true, workflowNodesMap: nodesMap),
  );
}

/// condition-number-input.tsx: Variable / Constant, then a number variable (written `{{#node.var#}}`) or a bare
/// number input ("Enter value", [unit] at the right while unfocused).
class ConditionNumberInput extends StatefulWidget {
  const ConditionNumberInput({
    super.key,
    required this.value,
    required this.onValueChange,
    required this.onNumberVarTypeChange,
    this.numberVarType = 'constant',
    this.variables = const [],
    this.lookup = _none,
    this.start,
    this.isShort = false,
    this.unit,
  });

  final String numberVarType;
  final ValueChanged<String> onNumberVarTypeChange;
  final String value;
  final ValueChanged<String> onValueChange;
  final List<VarGroup> variables;
  final Node? Function(String id) lookup;
  final Node? start;
  final bool isShort;
  final String? unit;

  static Node? _none(String _) => null;

  @override
  State<ConditionNumberInput> createState() => _ConditionNumberInputState();
}

class _ConditionNumberInputState extends State<ConditionNumberInput> {
  final _popup = DifyFloatingController();
  final _search = FocusNode(debugLabel: 'condition number var search');
  late final _text = TextEditingController(text: widget.value);
  late final _focus = FocusNode()..addListener(() => setState(() {}));

  @override
  void didUpdateWidget(ConditionNumberInput old) {
    super.didUpdateWidget(old);
    if (_text.text != widget.value) _text.text = widget.value;
  }

  @override
  void dispose() {
    _search.dispose();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// `variableTransformer`: `{{#a.b#}}` and back.
  static List<String> _selectorOf(String v) => templateToSelector(v);

  @override
  Widget build(BuildContext context) {
    final w = widget;
    String cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
    final placeholder = difyTextStyle(DifyTw.text13, DifyColors.componentsInputTextPlaceholder);
    return Row(
      children: [
        DifyDropdownMenu(
          placement: DifyPlacement.bottomStart,
          sideOffset: 2,
          width: 112,
          builder: (context, c) => DifyButton(
            size: DifyButtonSize.small,
            variant: DifyButtonVariant.ghost,
            onPressed: c.toggle,
            trailing: const RemixIcon('arrow-down-s-line', size: 14),
            child: Text(cap(w.numberVarType)),
          ),
          children: [
            DifyMenuRadioGroup<String>(
              value: w.numberVarType,
              onValueChange: w.onNumberVarTypeChange,
              children: [
                for (final o in const ['variable', 'constant'])
                  DifyMenuRadioItem(value: o, closeOnClick: true, child: Text(cap(o))),
              ],
            ),
          ],
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: 1,
          height: 16,
          color: DifyColors.dividerRegular,
        ),
        const SizedBox(width: 2),
        Expanded(
          child: w.numberVarType == 'variable'
              ? DifyPopover(
                  controller: _popup,
                  placement: DifyPlacement.bottomStart,
                  sideOffset: 2,
                  surface: false,
                  initialFocus: _search,
                  builder: (context, c) => Semantics(
                    button: true,
                    label: w.value.isEmpty ? wf('nodes.ifElse.selectVariable') : null,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      excludeFromSemantics: true,
                      onTap: c.toggle,
                      child: w.value.isNotEmpty
                          ? Align(
                              alignment: Alignment.centerLeft,
                              child: VariableTag(
                                valueSelector: _selectorOf(w.value),
                                varType: VarType.number,
                                lookup: w.lookup,
                                start: w.start,
                                isShort: w.isShort,
                              ),
                            )
                          : Container(
                              height: 24,
                              padding: const EdgeInsets.all(4),
                              child: Row(
                                children: [
                                  DifyIcon(
                                    'vender/solid/development/variable-02',
                                    size: 16,
                                    color: DifyColors.componentsInputTextPlaceholder,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      wf('nodes.ifElse.selectVariable'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: placeholder,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ),
                  content: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: _popupBox(
                      width: w.isShort ? 200 : 296,
                      child: VarReferenceVars(
                        vars: w.variables,
                        searchFocusNode: _search,
                        onClose: _popup.close,
                        onChange: (sel, _) {
                          w.onValueChange(selectorToTemplate(sel));
                          _popup.close();
                        },
                      ),
                    ),
                  ),
                )
              : Stack(
                  alignment: Alignment.centerRight,
                  children: [
                    DifyTextField(
                      controller: _text,
                      focusNode: _focus,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.eE+-]'))],
                      style: difyTextStyle(DifyTw.text13, DifyColors.componentsInputTextFilled),
                      cursorWidth: 1,
                      decoration: DifyFieldDecoration(
                        contentPadding: EdgeInsets.fromLTRB(8, 4, w.unit == null ? 8 : 24, 4),
                        hintText: wf('nodes.ifElse.enterValue'),
                        hintStyle: placeholder,
                      ),
                      onChanged: w.onValueChange,
                    ),
                    if (!_focus.hasFocus && w.unit != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: DifyText(w.unit!, DifyType.systemSmRegular, color: DifyColors.textTertiary),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
