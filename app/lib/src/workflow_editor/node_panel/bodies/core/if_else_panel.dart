/// The IF/ELSE node's panel (nodes/if-else/panel.tsx and components/: condition-wrap, condition-list,
/// condition-item, condition-add, condition-operator, condition-var-selector, condition-input,
/// condition-number-input).
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../workflow/dify_json.dart';
import '../../../../workflow/var_types.dart';
import '../../../header/checklist/node_validators.dart' show comparisonOperatorNotRequireValue;
import '../../../panel_fields/panel_fields.dart';
import '../../../prompt_editor/prompt_editor.dart';
import '../../node_panel_bodies.dart';
import '../../panel_edit.dart';
import 'core_kit.dart';
import 'if_else_utils.dart';

export 'if_else_utils.dart';

const _p = 'nodes.ifElse';

/// What the condition widgets offer and call: the variables (all of them; number ones for the number input), the
/// nodes the prompt editor names, and the handlers of [IfElseConfig] (null ones do nothing).
class IfElseEnv {
  const IfElseEnv({
    this.scope = const VarScope(),
    this.availableNodes = const {},
    this.readOnly = false,
    this.varsIsVarFileAttribute = const {},
    this.onAddCondition,
    this.onRemoveCondition,
    this.onUpdateCondition,
    this.onToggleConditionLogicalOperator,
    this.onAddSubVariableCondition,
    this.onRemoveSubVariableCondition,
    this.onUpdateSubVariableCondition,
    this.onToggleSubVariableConditionLogicalOperator,
    this.onRemoveCase,
    this.onSortCase,
  });

  /// From [config] and the node's variables ([scope]; the prompt editor's [availableNodes]).
  factory IfElseEnv.of(
    IfElseConfig config,
    VarScope scope, [
    Map<String, WorkflowNodeInfo> availableNodes = const {},
  ]) => IfElseEnv(
    scope: scope,
    availableNodes: availableNodes,
    readOnly: config.readOnly,
    varsIsVarFileAttribute: config.varsIsVarFileAttribute,
    onAddCondition: config.handleAddCondition,
    onRemoveCondition: config.handleRemoveCondition,
    onUpdateCondition: config.handleUpdateCondition,
    onToggleConditionLogicalOperator: config.handleToggleConditionLogicalOperator,
    onAddSubVariableCondition: config.handleAddSubVariableCondition,
    onRemoveSubVariableCondition: config.handleRemoveSubVariableCondition,
    onUpdateSubVariableCondition: config.handleUpdateSubVariableCondition,
    onToggleSubVariableConditionLogicalOperator: config.handleToggleSubVariableConditionLogicalOperator,
    onRemoveCase: config.handleRemoveCase,
    onSortCase: config.handleSortCase,
  );

  final VarScope scope;
  final Map<String, WorkflowNodeInfo> availableNodes;
  final bool readOnly;
  final Map<String, bool> varsIsVarFileAttribute;
  final void Function(String caseId, List<String> selector, PickerVar v)? onAddCondition;
  final void Function(String caseId, String conditionId)? onRemoveCondition;
  final void Function(String caseId, String conditionId, Json condition)? onUpdateCondition;
  final void Function(String caseId)? onToggleConditionLogicalOperator;
  final void Function(String caseId, String conditionId, [String? key])? onAddSubVariableCondition;
  final void Function(String caseId, String conditionId, String subConditionId)? onRemoveSubVariableCondition;
  final void Function(String caseId, String conditionId, String subConditionId, Json condition)?
  onUpdateSubVariableCondition;
  final void Function(String caseId, String conditionId)? onToggleSubVariableConditionLogicalOperator;
  final void Function(String caseId)? onRemoveCase;
  final void Function(List<Json> cases)? onSortCase;

  List<VarGroup> get numberVars => scope.filtered((v, _) => filterNumberVars(v)).vars;
}

/// `useIsVarFileAttribute`: a 3-segment selector whose first two segments name a file.
bool Function(List<String>) isVarFileAttributeIn(VarScope scope) =>
    (s) => s.length == 3 && scope.typeOf?.call(s.sublist(0, 2)) == VarType.file;

Widget ifElsePanelBody(BuildContext context, NodePanelProps props) {
  final crud = PanelInputs(props);
  final vars = NodeVars.of(props);
  final config = IfElseConfig(
    nodeId: props.id,
    inputs: () => crud.inputs,
    setInputs: (next) => _write(crud, next),
    readOnly: props.readOnly,
    deleteBranch: props.actions.deleteBranch,
    isVarFileAttribute: isVarFileAttributeIn(vars.scope),
  );
  return IfElsePanel(config: config, env: IfElseEnv.of(config, vars.scope, vars.nodesMap));
}

/// Writes [next]; a reorder of the cases keeps each case's item (matched by `case_id`).
void _write(PanelInputs crud, Json next) {
  final node = crud.node;
  final items = switch (node.config['cases']) {
    VItems(:final items) => items,
    _ => null,
  };
  final cases = jsList(next['cases']);
  final ids = [for (final c in cases) jsGet(c, 'case_id')];
  final old = [for (final i in items ?? const <Item>[]) jsGet(plainOf(i.value), 'case_id')];
  final reordered =
      items != null &&
      ids.length == old.length &&
      ids.toSet().length == ids.length &&
      ids.toSet().containsAll(old) &&
      [for (var i = 0; i < ids.length; i++) ids[i] == old[i]].contains(false);
  if (!reordered) return crud.setInputs(next);
  final doc = crud.props.controller.doc;
  crud.props.controller.setConfig(
    node.id,
    const ['cases'],
    VItems([
      for (final c in cases)
        () {
          final i = items[old.indexOf(jsGet(c, 'case_id'))];
          return Item(i.id, mergeValue(i.value, c, doc));
        }(),
    ]),
  );
  crud.setInputs({...next, 'cases': plainOf(crud.node.config['cases'])});
}

/// panel.tsx.
class IfElsePanel extends StatelessWidget {
  const IfElsePanel({super.key, required this.config, required this.env});
  final IfElseConfig config;
  final IfElseEnv env;

  @override
  Widget build(BuildContext context) {
    final cases = [
      for (final c in jsList(config.inputs()['cases']))
        if (c is Map) c.cast<String, Object?>(),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IfElseConditionWrap(cases: cases, env: env),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
            child: DifyButton(
              variant: DifyButtonVariant.tertiary,
              semanticLabel: 'ELIF',
              disabled: env.readOnly,
              onPressed: config.handleAddCase,
              leading: const RemixIcon('add-line', size: 16),
              child: const Text('ELIF'),
            ),
          ),
          const Padding(padding: EdgeInsets.only(left: 4), child: _Divider()),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
            child: Field(
              title: tw('$_p.else'),
              child: Text(
                tw('$_p.elseDescription'),
                style: const TextStyle(fontSize: 12, height: 18 / 12, color: DifyColors.textTertiary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `mx-3 my-2 h-px bg-divider-subtle`.
class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) => Container(
    height: 1,
    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    color: DifyColors.dividerSubtle,
  );
}

/// condition-wrap.tsx: the cases (reordered by their drag handles), or with [subVariable] the one sub-variable case
/// of the condition [conditionId] of [caseId].
class IfElseConditionWrap extends StatefulWidget {
  const IfElseConditionWrap({
    super.key,
    required this.cases,
    required this.env,
    this.subVariable = false,
    this.caseId,
    this.conditionId,
  });

  final List<Json> cases;
  final IfElseEnv env;
  final bool subVariable;
  final String? caseId, conditionId;

  @override
  State<IfElseConditionWrap> createState() => _IfElseConditionWrapState();
}

class _IfElseConditionWrapState extends State<IfElseConditionWrap> {
  String _willDelete = '';
  String? _hovered;

  Widget _case(int index, Json item) {
    final w = widget, env = w.env;
    final caseId = jsKey(item['case_id']);
    final conditions = jsList(item['conditions']);
    final n = w.cases.length;
    final listCaseId = w.subVariable ? w.caseId! : caseId;
    final footer = Padding(
      padding: EdgeInsets.only(
        left: w.subVariable ? 0 : 60,
        right: 30,
        top: conditions.isNotEmpty ? 0 : (w.subVariable ? 8 : 4),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (w.subVariable)
            Flexible(
              child: _SubVariableAdd(
                disabled: env.readOnly,
                onSelect: (key) => env.onAddSubVariableCondition?.call(w.caseId!, w.conditionId!, key),
              ),
            )
          else
            Flexible(
              child: IfElseConditionAdd(
                caseId: caseId,
                variables: env.scope.vars,
                disabled: env.readOnly,
                onSelectVariable: (c, s, v) => env.onAddCondition?.call(c, s, v),
              ),
            ),
          if (index > 0 || n > 1)
            Flexible(
              child: MouseRegion(
                onEnter: (_) => setState(() => _willDelete = caseId),
                onExit: (_) => setState(() => _willDelete = ''),
                child: DifyButton(
                  size: DifyButtonSize.small,
                  variant: DifyButtonVariant.ghost,
                  tone: _willDelete == caseId ? DifyButtonTone.destructive : DifyButtonTone.normal,
                  disabled: env.readOnly,
                  onPressed: () => env.onRemoveCase?.call(caseId),
                  leading: const RemixIcon('delete-bin-line', size: 14),
                  child: Text(tc('operation.remove')),
                ),
              ),
            ),
        ],
      ),
    );
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (conditions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: IfElseConditionList(
              caseId: listCaseId,
              conditionId: w.conditionId,
              caseItem: item,
              env: env,
              subVariable: w.subVariable,
            ),
          ),
        footer,
      ],
    );
    final box = Container(
      constraints: BoxConstraints(minHeight: w.subVariable ? 0 : 40),
      padding: w.subVariable
          ? const EdgeInsets.symmetric(horizontal: 4, vertical: 8)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: _willDelete == caseId ? DifyColors.stateDestructiveHover : DifyColors.componentsPanelBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: w.subVariable
          ? body
          : Stack(
              clipBehavior: Clip.none,
              children: [
                body,
                Positioned(
                  left: 4,
                  top: n == 1 ? 6 : 0,
                  child: IgnorePointer(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          index == 0 ? 'IF' : 'ELIF',
                          style: const TextStyle(
                            fontSize: 13,
                            height: 16 / 13,
                            fontWeight: FontWeight.w600,
                            color: DifyColors.textSecondary,
                          ),
                        ),
                        if (n > 1)
                          Text(
                            'CASE${index + 1}',
                            style: const TextStyle(
                              fontSize: 10,
                              height: 12 / 10,
                              fontWeight: FontWeight.w500,
                              color: DifyColors.textTertiary,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
    return MouseRegion(
      key: ValueKey(caseId),
      onEnter: (_) => setState(() => _hovered = caseId),
      onExit: (_) => setState(() => _hovered = _hovered == caseId ? null : _hovered),
      child: w.subVariable
          ? box
          : Stack(
              children: [
                // The block sits 4 px in, so the handle (`-left-2` over the panel's `p-1`) stays hit-testable.
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [box, const _Divider()]),
                ),
                if (!env.readOnly && n > 1)
                  Positioned(
                    left: 0,
                    top: 4,
                    child: Opacity(
                      opacity: _hovered == caseId ? 1 : 0,
                      child: ReorderableDragStartListener(
                        index: index,
                        child: const MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: SizedBox.square(
                            dimension: 24,
                            child: Center(child: RemixIcon('draggable', size: 12, color: DifyColors.textTertiary)),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    if (w.cases.isEmpty) {
      if (!w.subVariable) return const SizedBox.shrink();
      return Align(
        alignment: Alignment.centerLeft,
        child: DifyButton(
          size: DifyButtonSize.small,
          disabled: w.env.readOnly,
          onPressed: () => w.env.onAddSubVariableCondition?.call(w.caseId!, w.conditionId!),
          leading: const RemixIcon('add-line', size: 14),
          child: Text(tw('$_p.addSubVariable')),
        ),
      );
    }
    if (w.subVariable) return _case(0, w.cases.first);
    return ReorderableList(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: w.cases.length,
      itemBuilder: (context, i) => _case(i, w.cases[i]),
      proxyDecorator: (child, _, _) => Material(color: DifyColors.componentsPanelBg, child: child),
      onReorderItem: (from, to) {
        if (from == to) return;
        final list = [...w.cases];
        list.insert(to, list.removeAt(from));
        w.env.onSortCase?.call([
          for (final c in list) {...c, 'id': c['case_id']},
        ]);
      },
    );
  }
}

/// The "Sub Variable" button choosing the attribute of a new sub-condition (a Select over SUB_VARIABLES).
class _SubVariableAdd extends StatelessWidget {
  const _SubVariableAdd({required this.disabled, required this.onSelect});
  final bool disabled;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) => DifyDropdownMenu(
    placement: DifyPlacement.bottomStart,
    width: 165,
    builder: (context, controller) => DifyButton(
      size: DifyButtonSize.small,
      disabled: disabled,
      onPressed: controller.toggle,
      leading: const RemixIcon('add-line', size: 14),
      child: Text(tw('$_p.addSubVariable')),
    ),
    children: [
      for (final k in subVariables) DifyMenuItem(onSelect: () => onSelect(k), child: Text(k)),
    ],
  );
}

/// condition-add.tsx: the "Add Condition" button and its variable list (all variables, files included).
class IfElseConditionAdd extends StatelessWidget {
  const IfElseConditionAdd({
    super.key,
    required this.caseId,
    required this.variables,
    required this.onSelectVariable,
    this.disabled = false,
  });

  final String caseId;
  final List<VarGroup> variables;
  final void Function(String caseId, List<String> selector, PickerVar v) onSelectVariable;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final label = tw('$_p.addCondition');
    return _VarPopover(
      vars: variables,
      isSupportFileVar: true,
      onChange: (s, v) => onSelectVariable(caseId, s, v),
      trigger: (context, toggle) => DifyButton(
        size: DifyButtonSize.small,
        disabled: disabled,
        semanticLabel: label,
        onPressed: toggle,
        leading: const RemixIcon('add-line', size: 14),
        child: Text(label),
      ),
    );
  }
}

/// A Popover (`bottom-start`, 4 px) with [VarReferenceVars] in a `w-74 rounded-lg border-[0.5px]
/// bg-components-panel-bg-blur shadow-lg` box; choosing closes it.
class _VarPopover extends StatefulWidget {
  const _VarPopover({
    required this.vars,
    required this.onChange,
    required this.trigger,
    this.isSupportFileVar = false,
    this.width = 296,
  });
  final List<VarGroup> vars;
  final VarSelected onChange;
  final Widget Function(BuildContext context, VoidCallback toggle) trigger;
  final bool isSupportFileVar;
  final double width;

  @override
  State<_VarPopover> createState() => _VarPopoverState();
}

class _VarPopoverState extends State<_VarPopover> {
  final _controller = DifyFloatingController();
  final _search = FocusNode(debugLabel: 'if-else var search');
  final _group = Object();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DifyPopover(
    controller: _controller,
    placement: DifyPlacement.bottomStart,
    sideOffset: 4,
    surface: false,
    initialFocus: _search,
    builder: (context, controller) => widget.trigger(context, controller.toggle),
    content: Container(
      width: widget.width,
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBgBlur,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
        border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
        boxShadow: DifyShadows.lg,
      ),
      child: VarReferenceVars(
        vars: widget.vars,
        isSupportFileVar: widget.isSupportFileVar,
        searchFocusNode: _search,
        tapRegionGroup: _group,
        onClose: () => _controller.close(),
        onChange: (s, v) {
          widget.onChange(s, v);
          _controller.close();
        },
      ),
    ),
  );
}

/// condition-list/index.tsx: the conditions of [caseItem], with the AND / OR switch on a bracket when there are
/// several.
class IfElseConditionList extends StatelessWidget {
  const IfElseConditionList({
    super.key,
    required this.caseId,
    required this.caseItem,
    required this.env,
    this.conditionId,
    this.subVariable = false,
  });

  final String caseId;
  final String? conditionId;
  final Json caseItem;
  final IfElseEnv env;
  final bool subVariable;

  @override
  Widget build(BuildContext context) {
    final conditions = [
      for (final c in jsList(caseItem['conditions']))
        if (c is Map) c.cast<String, Object?>(),
    ];
    final op = jsStr(caseItem['logical_operator']) ?? 'and';
    final itemPadding = !subVariable || conditions.length < 2 ? 0.0 : (op == 'and' ? 51.0 : 42.0);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: EdgeInsets.only(left: subVariable ? 0 : 60),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, c) in conditions.indexed)
                Padding(
                  key: ValueKey(c['id']),
                  padding: EdgeInsets.only(left: itemPadding, bottom: i == conditions.length - 1 ? 0 : 4),
                  child: IfElseConditionItem(
                    caseId: caseId,
                    conditionId: subVariable ? conditionId! : jsKey(c['id']),
                    condition: c,
                    env: env,
                    subVariableKey: subVariable,
                    isValueFieldShort: subVariable && conditions.length > 1,
                    fileKey: env.varsIsVarFileAttribute[jsKey(c['id'])] == true
                        ? jsKey(jsList(c['variable_selector']).lastOrNull)
                        : null,
                  ),
                ),
            ],
          ),
        ),
        if (conditions.length > 1)
          Positioned(
            top: 0,
            bottom: 0,
            left: !subVariable ? 0 : (op == 'and' ? -10 : -18),
            width: 60,
            child: Stack(
              children: [
                Positioned(
                  top: 16,
                  bottom: 16,
                  left: 46,
                  width: 10,
                  child: Container(
                    decoration: const BoxDecoration(
                      border: Border(
                        left: BorderSide(color: DifyColors.dividerDeep),
                        top: BorderSide(color: DifyColors.dividerDeep),
                        bottom: BorderSide(color: DifyColors.dividerDeep),
                      ),
                      borderRadius: BorderRadius.horizontal(left: Radius.circular(8)),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Container(width: 16, height: 29, color: DifyColors.componentsPanelBg),
                  ),
                ),
                Positioned.fill(
                  right: 4,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: () => subVariable
                          ? env.onToggleSubVariableConditionLogicalOperator?.call(caseId, conditionId!)
                          : env.onToggleConditionLogicalOperator?.call(caseId),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
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
                                op.toUpperCase(),
                                style: const TextStyle(
                                  fontSize: 10,
                                  height: 12 / 10,
                                  fontWeight: FontWeight.w600,
                                  color: DifyColors.textAccentSecondary,
                                ),
                              ),
                              const SizedBox(width: 2),
                              const RemixIcon('loop-left-line', size: 12, color: DifyColors.textAccentSecondary),
                            ],
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

/// condition-item.tsx: one condition (or, with [subVariableKey], one sub-condition of the condition
/// [conditionId]): its variable (or file attribute), operator and value, and the delete icon.
class IfElseConditionItem extends StatefulWidget {
  const IfElseConditionItem({
    super.key,
    required this.caseId,
    required this.conditionId,
    required this.condition,
    required this.env,
    this.fileKey,
    this.subVariableKey = false,
    this.isValueFieldShort = false,
  });

  final String caseId, conditionId;
  final Json condition;
  final IfElseEnv env;
  final String? fileKey;
  final bool subVariableKey, isValueFieldShort;

  @override
  State<IfElseConditionItem> createState() => _IfElseConditionItemState();
}

class _IfElseConditionItemState extends State<IfElseConditionItem> {
  bool _hovered = false;

  Json get _c => widget.condition;
  String get _id => jsKey(_c['id']);
  String? get _varType => jsStr(_c['varType']);
  String? get _operator => jsStr(_c['comparison_operator']);

  void _update(Json next) {
    final w = widget;
    if (w.subVariableKey) {
      w.env.onUpdateSubVariableCondition?.call(w.caseId, w.conditionId, _id, next);
    } else {
      w.env.onUpdateCondition?.call(w.caseId, _id, next);
    }
  }

  String? get _fileKey => widget.fileKey ?? (widget.subVariableKey ? jsStr(_c['key']) : null);
  bool get _isArrayValue => _fileKey == 'transfer_method' || _fileKey == 'type';

  void _setValue(Object value) {
    final current = _c['value'];
    if (value == current || (_isArrayValue && value == jsGet(current, '0'))) return;
    _update({
      ..._c,
      'value': _isArrayValue ? [value] : value,
    });
  }

  void _setVar(List<String> selector, PickerVar item) {
    final type = widget.env.scope.typeOf?.call(selector) ?? item.type;
    final next = <String, Object?>{..._c}
      ..['variable_selector'] = selector
      ..['varType'] = type
      ..['value'] = type == VarType.boolean ? false : ''
      ..['comparison_operator'] = getOperators(type).firstOrNull
      ..remove('key')
      ..remove('sub_variable_condition')
      ..remove('numberVarType');
    _update(next);
  }

  void _setSubVarKey(String key) =>
      widget.env.onUpdateSubVariableCondition?.call(widget.caseId, widget.conditionId, _id, {
        ..._c,
        'key': key,
        'varType': key == 'size' ? VarType.number : VarType.string,
        'value': '',
        'comparison_operator': getOperators(null, fileKey: key).firstOrNull,
      });

  void _remove() {
    final w = widget;
    if (w.subVariableKey) {
      w.env.onRemoveSubVariableCondition?.call(w.caseId, w.conditionId, _id);
    } else {
      w.env.onRemoveCondition?.call(w.caseId, _id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget, env = w.env;
    final disabled = env.readOnly;
    final op = _operator;
    final type = _varType;
    final isSubVariable = type == VarType.arrayFile && const ['contains', 'not contains', 'all of'].contains(op);
    final isSelect = op == 'in' || op == 'not in';
    final selectOptions = !isSelect
        ? const <SelectOption<String>>[]
        : _fileKey == 'type' || op == 'all of'
        ? [for (final (v, k) in fileTypeOptions) (value: v, label: tw('$_p.optionName.$k'))]
        : _fileKey == 'transfer_method'
        ? [for (final (v, k) in transferMethodOptions) (value: v, label: tw('$_p.optionName.$k'))]
        : const <SelectOption<String>>[];
    final needsValue = !comparisonOperatorNotRequireValue(op);
    final isNotInput = isSelect || isSubVariable;
    final showBoolean =
        type == VarType.boolean || (type == VarType.arrayBoolean && const ['contains', 'not contains'].contains(op));
    final value = _c['value'];
    const top = Border(top: BorderSide(color: DifyColors.dividerSubtle));

    final head = Padding(
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          Expanded(
            child: w.subVariableKey
                ? _SubVarKeySelect(value: jsStr(_c['key']), onChange: _setSubVarKey)
                : _VarPopover(
                    vars: env.scope.vars,
                    isSupportFileVar: true,
                    onChange: _setVar,
                    trigger: (context, toggle) => GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: toggle,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: VariableTag.inScope(
                            valueSelector: [for (final s in jsList(_c['variable_selector'])) jsKey(s)],
                            varType: type,
                            scope: env.scope,
                            isShort: true,
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          Container(
            width: 1,
            height: 12,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: DifyColors.dividerRegular,
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: IfElseConditionOperator(
              disabled: disabled || (w.subVariableKey && !jsTruthy(_c['key'])),
              varType: type,
              fileKey: _fileKey,
              value: op,
              onSelect: (v) => _update({..._c, 'comparison_operator': v}),
            ),
          ),
        ],
      ),
    );
    final selected = _isArrayValue ? jsStr(jsGet(value, '0')) : jsStr(value);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: _hovered ? DifyColors.stateDestructiveHover : DifyColors.componentsInputBgNormal,
              borderRadius: BorderRadius.circular(DifyRadius.lg),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                head,
                if (needsValue && !isNotInput && type != VarType.number && !showBoolean)
                  Container(
                    constraints: const BoxConstraints(maxHeight: 100),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: const BoxDecoration(border: top),
                    child: SingleChildScrollView(
                      child: DifyPromptEditor(
                        compact: true,
                        value: value is String ? value : '',
                        placeholder: tw('$_p.enterValue'),
                        editable: !disabled,
                        workflowVariableBlock: WorkflowVariableBlockConfig(
                          show: true,
                          variables: env.scope.vars,
                          workflowNodesMap: env.availableNodes,
                        ),
                        onChange: _setValue,
                      ),
                    ),
                  ),
                if (needsValue && !isNotInput && showBoolean)
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: Row(
                      spacing: 4,
                      children: [
                        for (final b in const [true, false])
                          Expanded(
                            child: OptionCard(
                              title: b ? 'True' : 'False',
                              selected: b ? value == true : value != true,
                              onSelect: () => _setValue(b),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (needsValue && !isNotInput && type == VarType.number)
                  Container(
                    padding: const EdgeInsets.fromLTRB(8, 3, 8, 4),
                    decoration: const BoxDecoration(border: top),
                    child: IfElseConditionNumberInput(
                      numberVarType: jsStr(_c['numberVarType']) == 'variable'
                          ? VarKindType.variable
                          : VarKindType.constant,
                      onNumberVarTypeChange: (t) => _update({..._c, 'numberVarType': t.name, 'value': ''}),
                      value: value is String ? value : (value == null ? '' : jsKey(value)),
                      onValueChange: _setValue,
                      variables: env.numberVars,
                      scope: env.scope,
                      isShort: w.isValueFieldShort,
                      unit: _fileKey == 'size' ? 'Byte' : null,
                    ),
                  ),
                if (needsValue && isSelect)
                  Container(
                    decoration: const BoxDecoration(border: top),
                    child: DifySelect<String>(
                      value: selectOptions.any((o) => o.value == selected) ? selected : null,
                      options: selectOptions,
                      placeholder: tc('placeholder.select'),
                      paddingX: 8,
                      textStyle: const TextStyle(fontSize: 12),
                      onChanged: _setValue,
                    ),
                  ),
                if (needsValue && isSubVariable)
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: IfElseConditionWrap(
                      subVariable: true,
                      caseId: w.caseId,
                      conditionId: w.conditionId,
                      cases: [if (_c['sub_variable_condition'] case final Map s) s.cast<String, Object?>()],
                      env: env,
                    ),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 4),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: DifyPressable(
              semanticLabel: tc('operation.remove'),
              onPressed: _remove,
              builder: (context, hovered, focused) => Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: hovered ? DifyColors.stateDestructiveHover : null,
                  borderRadius: BorderRadius.circular(DifyRadius.lg),
                ),
                child: Center(
                  child: RemixIcon(
                    'delete-bin-line',
                    size: 16,
                    color: hovered ? DifyColors.textDestructive : DifyColors.textTertiary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The sub-condition's attribute Select: the chosen key in an accent chip, else "Please select".
class _SubVarKeySelect extends StatelessWidget {
  const _SubVarKeySelect({required this.value, required this.onChange});
  final String? value;
  final ValueChanged<String> onChange;

  @override
  Widget build(BuildContext context) {
    final selected = subVariables.contains(value) ? value : null;
    return DifyDropdownMenu(
      placement: DifyPlacement.bottomStart,
      width: 165,
      builder: (context, controller) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: controller.toggle,
        child: SizedBox(
          height: 24,
          child: Align(
            alignment: Alignment.centerLeft,
            child: selected == null
                ? Text(
                    tc('placeholder.select'),
                    style: difyTextStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextPlaceholder),
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
                        const DifyIcon('vender/solid/development/variable-02', size: 14, color: DifyColors.textAccent),
                        const SizedBox(width: 2),
                        Text(selected, style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textAccent)),
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
              DifyMenuRadioItem<String>(
                value: k,
                closeOnClick: true,
                leading: const DifyIcon('vender/solid/development/variable-02', size: 14, color: DifyColors.textAccent),
                child: Text(k),
              ),
          ],
        ),
      ],
    );
  }
}

/// condition-operator.tsx: a small ghost button with the operator (or "Select", faded) opening the operators of
/// the type ([fileKey]: of the file attribute).
class IfElseConditionOperator extends StatelessWidget {
  const IfElseConditionOperator({
    super.key,
    required this.varType,
    required this.onSelect,
    this.value,
    this.fileKey,
    this.disabled = false,
  });

  final String? varType, value, fileKey;
  final ValueChanged<String> onSelect;
  final bool disabled;

  static String labelOf(String o) => isComparisonOperatorNeedTranslate(o) ? tw('$_p.comparisonOperator.$o') : o;

  @override
  Widget build(BuildContext context) {
    final options = getOperators(varType, fileKey: fileKey);
    final selected = options.contains(value) ? value : null;
    final label = selected == null ? tw('$_p.select') : labelOf(selected);
    return DifyDropdownMenu(
      placement: DifyPlacement.bottomEnd,
      builder: (context, controller) => Opacity(
        opacity: selected == null ? 0.5 : 1,
        child: DifyButton(
          size: DifyButtonSize.small,
          variant: DifyButtonVariant.ghost,
          disabled: disabled,
          semanticLabel: label,
          onPressed: controller.toggle,
          trailing: const RemixIcon('arrow-down-s-line', size: 14),
          child: Text(label),
        ),
      ),
      children: [
        DifyMenuRadioGroup<String>(
          value: selected,
          onValueChange: onSelect,
          children: [
            for (final o in options) DifyMenuRadioItem<String>(value: o, closeOnClick: true, child: Text(labelOf(o))),
          ],
        ),
      ],
    );
  }
}

String _capitalize(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1).toLowerCase()}';

/// condition-number-input.tsx: Variable / Constant, then a number typed in (with [unit] while unfocused) or a
/// number variable stored as `{{#node.var#}}`.
class IfElseConditionNumberInput extends StatefulWidget {
  const IfElseConditionNumberInput({
    super.key,
    this.numberVarType = VarKindType.constant,
    required this.onNumberVarTypeChange,
    required this.value,
    required this.onValueChange,
    required this.variables,
    this.scope = const VarScope(),
    this.isShort = false,
    this.unit,
  });

  final VarKindType numberVarType;
  final ValueChanged<VarKindType> onNumberVarTypeChange;
  final String value;
  final ValueChanged<String> onValueChange;
  final List<VarGroup> variables;
  final VarScope scope;
  final bool isShort;
  final String? unit;

  @override
  State<IfElseConditionNumberInput> createState() => _IfElseConditionNumberInputState();
}

class _IfElseConditionNumberInputState extends State<IfElseConditionNumberInput> {
  late final _text = TextEditingController(text: widget.value);
  final _focus = FocusNode(debugLabel: 'if-else number');

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(IfElseConditionNumberInput old) {
    super.didUpdateWidget(old);
    if (_text.text != widget.value) _text.text = widget.value;
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final kind = _capitalize(w.numberVarType.name);
    const style = TextStyle(fontSize: 13, height: 18 / 13, color: DifyColors.componentsInputTextFilled);
    final Widget field;
    if (w.numberVarType == VarKindType.variable) {
      final selector = templateToSelector(w.value);
      field = _VarPopover(
        vars: w.variables,
        width: w.isShort ? 200 : 296,
        onChange: (s, _) => w.onValueChange(selectorToTemplate(s)),
        trigger: (context, toggle) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: toggle,
          child: Align(
            alignment: Alignment.centerLeft,
            child: w.value.isNotEmpty
                ? VariableTag.inScope(
                    valueSelector: selector,
                    varType: VarType.number,
                    scope: w.scope,
                    isShort: w.isShort,
                  )
                : Container(
                    height: 24,
                    padding: const EdgeInsets.all(4),
                    child: Row(
                      children: [
                        const DifyIcon(
                          'vender/solid/development/variable-02',
                          size: 16,
                          color: DifyColors.componentsInputTextPlaceholder,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            tw('$_p.selectVariable'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: style.copyWith(color: DifyColors.componentsInputTextPlaceholder),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      );
    } else {
      field = Stack(
        alignment: Alignment.centerRight,
        children: [
          TextField(
            controller: _text,
            focusNode: _focus,
            onChanged: w.onValueChange,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            style: style,
            cursorWidth: 1,
            decoration: InputDecoration(
              isCollapsed: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.fromLTRB(8, 3, w.unit == null ? 8 : 24, 3),
              hintText: tw('$_p.enterValue'),
              hintStyle: style.copyWith(color: DifyColors.componentsInputTextPlaceholder),
            ),
          ),
          if (!_focus.hasFocus && w.unit != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: IgnorePointer(
                child: Text(w.unit!, style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textTertiary)),
              ),
            ),
        ],
      );
    }
    return Row(
      children: [
        DifyDropdownMenu(
          placement: DifyPlacement.bottomStart,
          sideOffset: 2,
          width: 112,
          builder: (context, controller) => DifyButton(
            size: DifyButtonSize.small,
            variant: DifyButtonVariant.ghost,
            semanticLabel: kind,
            onPressed: controller.toggle,
            trailing: const RemixIcon('arrow-down-s-line', size: 14),
            child: Text(kind),
          ),
          children: [
            DifyMenuRadioGroup<VarKindType>(
              value: w.numberVarType,
              onValueChange: w.onNumberVarTypeChange,
              children: [
                for (final o in const [VarKindType.variable, VarKindType.constant])
                  DifyMenuRadioItem<VarKindType>(value: o, closeOnClick: true, child: Text(_capitalize(o.name))),
              ],
            ),
          ],
        ),
        Container(
          width: 1,
          height: 16,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          color: DifyColors.dividerRegular,
        ),
        const SizedBox(width: 2),
        Expanded(child: field),
      ],
    );
  }
}
