/// The Variable Aggregator node's panel (nodes/variable-assigner: panel.tsx, use-config.ts, use-config.helpers.ts,
/// hooks.ts, use-single-run-form-params.ts, components/var-group-item.tsx, components/var-list), also used for the
/// legacy `variable-assigner` type.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../../workflow/var_types.dart' show VarType;
import '../../../panel_fields/panel_fields.dart';
import '../../node_panel_bodies.dart';
import '../../panel_edit.dart';
import 'core_kit.dart';

typedef Json = Map<String, Object?>;

/// A deep copy of plain JSON (immer's draft).
Object? _clone(Object? v) => switch (v) {
  final Map m => {for (final e in m.entries) '${e.key}': _clone(e.value)},
  final List l => [for (final x in l) _clone(x)],
  _ => v,
};

Json _copy(Json m) => _clone(m)! as Json;

final _random = Random.secure();

/// uuid v4.
String uuid4() {
  final b = [for (var i = 0; i < 16; i++) _random.nextInt(256)];
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

List<Json> _groupsOf(Json inputs) => [
  for (final g in jsList(jsGet(inputs['advanced_settings'], 'groups')))
    if (g is Map) g.cast<String, Object?>(),
];

List<List<String>> _selectors(Object? v) => [for (final s in jsList(v)) selectorList(s)];

String _join(List<String> s) => s.join('.');

// ---- use-config.helpers.ts ---------------------------------------------------------------------------------------

/// `filterVarByType`.
bool Function(PickerVar v) filterVarByType(String? varType) =>
    (v) => varType == VarType.any || v.type == VarType.any || v.type == varType;

/// `updateRootVarGroupItem`.
Json updateRootVarGroupItem(Json inputs, Json payload) => {...inputs, ...payload};

Json? _settings(Json draft) => draft['advanced_settings'] is Map ? draft['advanced_settings']! as Json : null;

List<Object?> _groupList(Json settings) => settings['groups'] is List ? settings['groups']! as List<Object?> : [];

/// `updateNestedVarGroupItem`.
Json updateNestedVarGroupItem(Json inputs, String groupId, Json payload) {
  final draft = _copy(inputs);
  final s = _settings(draft);
  if (s == null) return draft;
  final groups = _groupList(s);
  final i = groups.indexWhere((g) => jsGet(g, 'groupId') == groupId);
  if (i < 0) return draft;
  groups[i] = {...(groups[i]! as Map).cast<String, Object?>(), ...payload};
  return draft;
}

/// `removeGroupByIndex`.
Json removeGroupByIndex(Json inputs, int index) {
  final draft = _copy(inputs);
  final s = _settings(draft);
  if (s == null) return draft;
  final groups = _groupList(s);
  if (index < 0 || index >= groups.length) return draft;
  groups.removeAt(index);
  return draft;
}

/// `toggleGroupEnabled`.
Json toggleGroupEnabled(Json inputs, {required bool enabled, String Function() uuid = uuid4}) {
  final draft = _copy(inputs);
  final s = _settings(draft) ?? (draft['advanced_settings'] = <String, Object?>{'group_enabled': false, 'groups': []});
  s['groups'] = _groupList(s);
  final groups = s['groups']! as List<Object?>;
  if (enabled) {
    if (groups.isEmpty) {
      s['groups'] = [
        {
          'output_type': draft['output_type'],
          'variables': draft['variables'],
          'group_name': 'Group1',
          'groupId': uuid(),
        },
      ];
    }
  } else if (groups.isNotEmpty) {
    draft['output_type'] = jsGet(groups.first, 'output_type');
    draft['variables'] = _clone(jsGet(groups.first, 'variables'));
  }
  s['group_enabled'] = enabled;
  return draft;
}

/// `addGroup`: `Group{max trailing number + 1}` (at least Group2), type any, no variables.
Json addGroup(Json inputs, {String Function() uuid = uuid4}) {
  var max = 1;
  for (final g in _groupsOf(inputs)) {
    final m = RegExp(r'(\d+)$').firstMatch(jsStr(g['group_name']) ?? '');
    if (m != null && int.parse(m[1]!) > max) max = int.parse(m[1]!);
  }
  final draft = _copy(inputs);
  final s = _settings(draft) ?? (draft['advanced_settings'] = <String, Object?>{'group_enabled': false, 'groups': []});
  s['groups'] = [
    ..._groupList(s),
    {'output_type': VarType.any, 'variables': <Object?>[], 'group_name': 'Group${max + 1}', 'groupId': uuid()},
  ];
  return draft;
}

/// `renameGroup`.
Json renameGroup(Json inputs, String groupId, String name) {
  final draft = _copy(inputs);
  final s = _settings(draft);
  if (s == null) return draft;
  final groups = _groupList(s);
  final i = groups.indexWhere((g) => jsGet(g, 'groupId') == groupId);
  if (i >= 0) (groups[i]! as Map)['group_name'] = name;
  return draft;
}

// ---- use-config.ts -----------------------------------------------------------------------------------------------

/// use-config.ts: the panel's handlers over [inputs] (read live) and [setInputs], with the workflow helpers Dify gets
/// from `useWorkflow` and `useInspectVarsCrud`. [onConfirmChange] is told when the remove confirm shows or hides.
class VariableAggregatorConfig {
  VariableAggregatorConfig({
    required this.id,
    required this.inputs,
    required this.setInputs,
    this.readOnly = false,
    required this.handleOutVarRenameChange,
    required this.isVarUsedInNodes,
    required this.removeUsedVarInNodes,
    this.deleteNodeInspectorVars,
    this.renameInspectVarName,
    this.onConfirmChange,
    this.uuid = uuid4,
    this.renameDebounce = const Duration(milliseconds: 500),
  });

  final String id;
  final Json Function() inputs;
  final ValueChanged<Json> setInputs;
  final bool readOnly;
  final void Function(String nodeId, List<String> oldSelector, List<String> newSelector) handleOutVarRenameChange;
  final bool Function(List<String> selector) isVarUsedInNodes;
  final void Function(List<String> selector) removeUsedVarInNodes;
  final ValueChanged<String>? deleteNodeInspectorVars;
  final void Function(String nodeId, String oldName, String newName)? renameInspectVarName;
  final ValueChanged<bool>? onConfirmChange;
  final String Function() uuid;

  /// Zero renames the inspect variable at once (Dify's tests mock the debounce away).
  final Duration renameDebounce;

  bool isShowRemoveVarConfirm = false;
  List<List<String>> _removedVars = const [];
  String _removeType = 'group';
  int _removedGroupIndex = -1;
  final _oldNames = <String, String>{};
  Timer? _renameTimer;

  bool get isEnableGroup => jsTruthy(jsGet(inputs()['advanced_settings'], 'group_enabled'));

  void _showConfirm(bool v) {
    isShowRemoveVarConfirm = v;
    onConfirmChange?.call(v);
  }

  void handleListOrTypeChange(Json payload) => setInputs(updateRootVarGroupItem(inputs(), payload));

  ValueChanged<Json> handleListOrTypeChangeInGroup(String groupId) =>
      (payload) => setInputs(updateNestedVarGroupItem(inputs(), groupId, payload));

  VoidCallback handleGroupRemoved(String groupId) => () {
    final groups = _groupsOf(inputs());
    final index = groups.indexWhere((g) => g['groupId'] == groupId);
    if (index < 0) return;
    final name = jsKey(groups[index]['group_name']);
    if (isVarUsedInNodes([id, name, 'output'])) {
      _removedVars = [
        [id, name, 'output'],
      ];
      _removeType = 'group';
      _removedGroupIndex = index;
      _showConfirm(true);
      return;
    }
    setInputs(removeGroupByIndex(inputs(), index));
  };

  void handleGroupEnabledChange(bool enabled) {
    final groups = _groupsOf(inputs());
    if (enabled && groups.isEmpty) handleOutVarRenameChange(id, [id, 'output'], [id, 'Group1', 'output']);
    if (!enabled && groups.isNotEmpty) {
      if (groups.length > 1) {
        final used = [
          for (final (i, g) in groups.indexed)
            if (i > 0 && isVarUsedInNodes([id, jsKey(g['group_name']), 'output'])) g,
        ];
        if (used.isNotEmpty) {
          _removedVars = [
            for (final g in used) [id, jsKey(g['group_name']), 'output'],
          ];
          _removeType = 'enableChanged';
          _showConfirm(true);
          return;
        }
      }
      handleOutVarRenameChange(id, [id, jsKey(groups.first['group_name']), 'output'], [id, 'output']);
    }
    setInputs(toggleGroupEnabled(inputs(), enabled: enabled, uuid: uuid));
    deleteNodeInspectorVars?.call(id);
  }

  void handleAddGroup() {
    setInputs(addGroup(inputs(), uuid: uuid));
    deleteNodeInspectorVars?.call(id);
  }

  void _renameInspect(String newName) {
    final old = _oldNames.remove(id);
    renameInspectVarName?.call(id, old!, newName);
  }

  ValueChanged<String> handleVarGroupNameChange(String groupId) => (name) {
    final groups = _groupsOf(inputs());
    final index = groups.indexWhere((g) => g['groupId'] == groupId);
    if (index < 0) return;
    final oldName = jsKey(groups[index]['group_name']);
    handleOutVarRenameChange(id, [id, oldName, 'output'], [id, name, 'output']);
    setInputs(renameGroup(inputs(), groupId, name));
    _oldNames.putIfAbsent(id, () => oldName);
    _renameTimer?.cancel();
    if (renameDebounce == Duration.zero) {
      _renameInspect(name);
    } else {
      _renameTimer = Timer(renameDebounce, () => _renameInspect(name));
    }
  };

  void hideRemoveVarConfirm() => _showConfirm(false);

  void onRemoveVarConfirm() {
    _removedVars.forEach(removeUsedVarInNodes);
    _showConfirm(false);
    if (_removeType == 'group') {
      if (_removedGroupIndex >= 0) setInputs(removeGroupByIndex(inputs(), _removedGroupIndex));
    } else {
      setInputs(toggleGroupEnabled(inputs(), enabled: false, uuid: uuid));
    }
  }

  void dispose() => _renameTimer?.cancel();
}

// ---- hooks.ts ----------------------------------------------------------------------------------------------------

/// `useVariableAssigner` over Dify's React Flow nodes (`{id, data}`): the canvas's ways of adding a variable to an
/// aggregator (its "+" popup, the popup after a connection) and the group hover state.
class VariableAssignerHooks {
  VariableAssignerHooks({
    required this.getNodes,
    required this.setNodes,
    required this.handleNodeDataUpdate,
    required this.setShowAssignVariablePopup,
    required this.setHoveringAssignVariableGroupId,
    required this.connectingNodePayload,
  });

  final List<Json> Function() getNodes;
  final ValueChanged<List<Json>> setNodes;
  final void Function({required String id, required Json data}) handleNodeDataUpdate;
  final VoidCallback setShowAssignVariablePopup;
  final ValueChanged<String?> setHoveringAssignVariableGroupId;
  final Object? Function() connectingNodePayload;

  void handleAssignVariableValueChange(String nodeId, List<String> value, PickerVar varDetail, [String? groupId]) {
    final node = getNodes().firstWhere((n) => n['id'] == nodeId);
    final data = (node['data']! as Map).cast<String, Object?>();
    final key = _join(value);
    Json payload;
    if (groupId != null && groupId != 'target') {
      final adv = (data['advanced_settings'] as Map?)?.cast<String, Object?>() ?? {};
      payload = {
        'advanced_settings': {
          ...adv,
          'groups': [
            for (final g in jsList(adv['groups']))
              if (jsGet(g, 'groupId') == groupId && !_selectors(jsGet(g, 'variables')).any((s) => _join(s) == key))
                {
                  ...(g! as Map).cast<String, Object?>(),
                  'variables': [...jsList(jsGet(g, 'variables')), value],
                  'output_type': varDetail.type,
                }
              else
                g,
          ],
        },
      };
    } else {
      if (_selectors(data['variables']).any((s) => _join(s) == key)) return;
      payload = {
        'variables': [...jsList(data['variables']), value],
        'output_type': varDetail.type,
      };
    }
    handleNodeDataUpdate(id: nodeId, data: payload);
  }

  void handleAddVariableInAddVariablePopupWithPosition(
    String nodeId,
    String variableAssignerNodeId,
    String variableAssignerNodeHandleId,
    List<String> value,
    PickerVar varDetail,
  ) {
    setNodes([
      for (final n in getNodes())
        if (n['id'] == nodeId || n['id'] == variableAssignerNodeId)
          {
            ...n,
            'data': {
              ...(n['data']! as Map).cast<String, Object?>(),
              '_showAddVariablePopup': false,
              '_holdAddVariablePopup': false,
            },
          }
        else
          n,
    ]);
    setShowAssignVariablePopup();
    handleAssignVariableValueChange(variableAssignerNodeId, value, varDetail, variableAssignerNodeHandleId);
  }

  void handleGroupItemMouseEnter(String groupId) => setHoveringAssignVariableGroupId(groupId);

  void handleGroupItemMouseLeave() {
    if (connectingNodePayload() != null) setHoveringAssignVariableGroupId(null);
  }
}

/// A React Flow node as `useGetAvailableVars` reads it.
typedef FlowNodeRef = ({String id, String? parentId});

/// `getNodeAvailableVars`'s arguments.
typedef NodeAvailableVarsQuery = ({
  FlowNodeRef? parentNode,
  List<FlowNodeRef> beforeNodes,
  bool isChatMode,
  bool hideEnv,
  bool hideChatVar,
  bool Function(PickerVar v) filterVar,
});

/// `filterSnippetSystemVars`: no `sys.` variables on a snippet canvas.
List<VarGroup> filterSnippetSystemVars(List<VarGroup> vars, {required bool isSnippetFlow}) => !isSnippetFlow
    ? vars
    : [
        for (final g in vars)
          if (g.vars.where((v) => !v.variable.startsWith('sys.')).toList() case final kept when kept.isNotEmpty)
            g.withVars(kept),
      ];

/// `useGetAvailableVars`: what the aggregator's "+" pickers offer for [nodeId]; with `hideEnv` neither environment
/// variables nor the Start node's `sys.*`, and no empty groups.
List<VarGroup> Function(String nodeId, String handleId, bool Function(PickerVar v) filterVar, [bool hideEnv])
useGetAvailableVars({
  required List<FlowNodeRef> nodes,
  required List<FlowNodeRef> Function(String nodeId) getBeforeNodesInSameBranchIncludeParent,
  required List<VarGroup> Function(NodeAvailableVarsQuery query) getNodeAvailableVars,
  bool isChatMode = false,
  bool isSnippetFlow = false,
}) => (nodeId, handleId, filterVar, [hideEnv = false]) {
  final current = nodes.where((n) => n.id == nodeId).firstOrNull;
  if (current == null) return const [];
  final seen = <String>{};
  final before = [
    for (final n in getBeforeNodesInSameBranchIncludeParent(nodeId))
      if (seen.add(n.id) && n.id != nodeId) n,
  ];
  final parent = nodes.where((n) => n.id == current.parentId).firstOrNull;
  final vars = getNodeAvailableVars((
    parentNode: parent,
    beforeNodes: before,
    isChatMode: isChatMode,
    hideEnv: hideEnv,
    hideChatVar: false,
    filterVar: filterVar,
  ));
  if (!hideEnv) return filterSnippetSystemVars(vars, isSnippetFlow: isSnippetFlow);
  return filterSnippetSystemVars([
    for (final g in vars)
      if ((g.isStartNode ? g.vars.where((v) => !v.variable.startsWith('sys.')).toList() : g.vars) case final kept
          when kept.isNotEmpty)
        g.withVars(kept),
  ], isSnippetFlow: isSnippetFlow);
};

/// The panel's `getAvailableVars(id, handle, filterVar, hideEnv = true)` over the node's [scope].
VarScope aggregatorAddScope(VarScope scope, bool Function(PickerVar v) filterVar) {
  final start = scope.start?.id;
  return scope.filtered(
    (v, sel) =>
        sel.first != 'env' && !(sel.first == start && start != null && v.variable.startsWith('sys.')) && filterVar(v),
  );
}

// ---- use-single-run-form-params.ts -------------------------------------------------------------------------------

/// use-single-run-form-params.ts: one form over every selector (the root's, or each group's), each input once and
/// optional; [getDependentVars] lists the selectors per group.
({
  List<({List<Json> inputs, Json values, ValueChanged<Json> onChange})> forms,
  List<List<List<String>>> Function() getDependentVars,
})
variableAggregatorSingleRunFormParams({
  required Json payload,
  required Json runInputData,
  required ValueChanged<Json> setRunInputData,
  required List<Json?> Function(List<List<String>> selectors) varSelectorsToVarInputs,
}) {
  final enabled = jsTruthy(jsGet(payload['advanced_settings'], 'group_enabled'));
  final all = <List<String>>[
    if (!enabled) ..._selectors(payload['variables']),
    if (enabled)
      for (final g in _groupsOf(payload)) ..._selectors(g['variables']),
  ];
  final seen = <String>{};
  final inputs = [
    for (final input in varSelectorsToVarInputs(all))
      if (input != null && seen.add('${input['variable']}')) {...input, 'required': false},
  ];
  return (
    forms: [
      (inputs: inputs, values: {...runInputData}, onChange: setRunInputData),
    ],
    getDependentVars: () => enabled
        ? [
            for (final g in _groupsOf(payload))
              if (g['variables'] != null) _selectors(g['variables']),
          ]
        : [_selectors(payload['variables'])],
  );
}

// ---- components --------------------------------------------------------------------------------------------------

/// components/var-list: one [VarReferencePicker] per selector with a remove button, or "Add the variables to be
/// assigned". [onChange] gets the new list and, for a replaced row, the selector chosen.
class AggregatorVarList extends StatelessWidget {
  const AggregatorVarList({
    super.key,
    required this.readonly,
    required this.list,
    required this.onChange,
    required this.scope,
    this.onOpen,
    this.filterVar,
  });

  final bool readonly;
  final List<List<String>> list;
  final void Function(List<List<String>> list, [List<String>? value]) onChange;
  final VarScope scope;
  final ValueChanged<int>? onOpen;
  final VarFilter? filterVar;

  @override
  Widget build(BuildContext context) {
    if (list.isEmpty) return ListNoDataPlaceholder(tw('nodes.variableAssigner.noVarTip'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        for (final (i, item) in list.indexed)
          Row(
            spacing: 4,
            children: [
              Expanded(
                child: VarReferencePicker(
                  readonly: readonly,
                  value: item,
                  scope: scope,
                  filterVar: filterVar,
                  defaultVarKindType: VarKindType.variable,
                  onOpen: (open) {
                    if (open) onOpen?.call(i);
                  },
                  onChange: (v, _) => onChange([for (final (j, s) in list.indexed) j == i ? v : s], v),
                ),
              ),
              if (!readonly)
                RemoveButton(
                  onPressed: () => onChange([
                    for (final (j, s) in list.indexed)
                      if (j != i) s,
                  ]),
                ),
            ],
          ),
      ],
    );
  }
}

/// components/var-group-item.tsx: a Field titled "Assign variables", or with groups the folder icon and the group
/// name (click to edit; spaces become `_`, invalid names are refused with [onError]) and, on hover, a remove icon.
/// The operations show the output type once a variable is set and the "+" picker over [addScope].
class VarGroupItem extends StatefulWidget {
  const VarGroupItem({
    super.key,
    required this.readOnly,
    required this.payload,
    required this.onChange,
    required this.groupEnabled,
    required this.scope,
    required this.addScope,
    this.onGroupNameChange,
    this.canRemove = false,
    this.onRemove,
    this.onError,
  });

  final bool readOnly;

  /// `{output_type, variables, group_name?}`.
  final Json payload;
  final ValueChanged<Json> onChange;
  final bool groupEnabled;

  /// The rows' variables, and the "+" picker's (Dify's `availableVars`).
  final VarScope scope, addScope;
  final ValueChanged<String>? onGroupNameChange;
  final bool canRemove;
  final VoidCallback? onRemove;
  final ValueChanged<String>? onError;

  @override
  State<VarGroupItem> createState() => _VarGroupItemState();
}

class _VarGroupItemState extends State<VarGroupItem> {
  bool _editName = false;
  bool _hovered = false;
  final _name = TextEditingController();
  final _nameFocus = FocusNode(debugLabel: 'group name');

  @override
  void initState() {
    super.initState();
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus && _editName) setState(() => _editName = false);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  String get _type => jsStr(widget.payload['output_type']) ?? VarType.any;
  List<List<String>> get _variables => _selectors(widget.payload['variables']);
  String get _groupName => jsStr(widget.payload['group_name']) ?? '';

  bool _filterVar(PickerVar v, [List<String> _ = const []]) => _type == VarType.any || v.type == _type;

  void _add(List<String> value, PickerVar? info) {
    if (_variables.any((s) => _join(s) == _join(value))) return;
    widget.onChange({
      ...widget.payload,
      'variables': [..._variables, value],
      if (info != null && info.type != VarType.any) 'output_type': info.type,
    });
  }

  void _listChange(List<List<String>> list, [List<String>? changed]) {
    if (changed != null && _variables.any((s) => _join(s) == _join(changed))) return;
    widget.onChange({...widget.payload, 'variables': list, if (list.isEmpty) 'output_type': VarType.any});
  }

  void _nameChange(String raw) {
    final value = raw.replaceAll(' ', '_');
    final bad = checkKeys([value]);
    if (bad != null) {
      widget.onError?.call(DifyI18n.tr('app-debug', 'varKeyError.${bad.error}', {'key': bad.key}));
      _name.value = TextEditingValue(
        text: _groupName,
        selection: TextSelection.collapsed(offset: _groupName.length),
      );
      return;
    }
    if (value != raw) {
      _name.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    }
    widget.onGroupNameChange?.call(value);
  }

  Widget _groupTitle() {
    final name = _groupName;
    final Widget label;
    if (_editName) {
      label = Container(
        height: 24,
        width: max(name.length, 1) * 8.0 + 10,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: DifyTailwind.white, // bg-white
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          border: Border.all(color: DifyColors.utilColorsGrayGray300),
        ),
        alignment: Alignment.centerLeft,
        child: DifyTextField(
          controller: _name,
          focusNode: _nameFocus,
          autofocus: true,
          maxLength: 30,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
          style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textPrimary),
          decoration: const DifyFieldDecoration.collapsed(hintText: '').copyWith(counterText: ''),
          onChanged: _nameChange,
        ),
      );
    } else {
      label = DifyPressable(
        semanticLabel: name,
        onPressed: () {
          _name.text = name;
          setState(() => _editName = true);
        },
        // `flex h-6 items-center px-1`: as wide as the name.
        builder: (context, hovered, focused) => Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: hovered ? DifyColors.utilColorsGrayGray100 : null,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
          ),
          child: Center(
            widthFactor: 1,
            child: MouseRegion(
              cursor: SystemMouseCursors.text,
              child: DifyText(name, DifyType.systemSmSemibold, color: DifyColors.textSecondary),
            ),
          ),
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.only(right: 2),
          child: DifyIcon('vender/line/files/folder', size: 14, color: DifyColors.textSecondary),
        ),
        Flexible(child: label),
        if (widget.canRemove && _hovered)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: DifyPressable(
              semanticLabel: tc('operation.remove'),
              onPressed: widget.onRemove,
              builder: (context, hovered, focused) => Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: hovered ? DifyColors.stateDestructiveHover : null,
                  borderRadius: BorderRadius.circular(DifyRadius.md),
                ),
                child: RemixIcon(
                  'delete-bin-line',
                  size: 16,
                  color: hovered ? DifyColors.textDestructive : DifyColors.textTertiary,
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final variables = _variables;
    final operations = SizedBox(
      height: 24,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          if (variables.isNotEmpty)
            Container(
              height: 18,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: DifyColors.dividerDeep),
              ),
              child: DifyText(_type, DifyType.system2xsMediumUppercase, color: DifyColors.textTertiary),
            ),
          if (!w.readOnly)
            VarReferencePicker(
              isAddBtnTrigger: true,
              value: const [],
              scope: w.addScope,
              defaultVarKindType: VarKindType.variable,
              filterVar: _filterVar,
              onChange: _add,
            ),
        ],
      ),
    );
    final list = AggregatorVarList(
      readonly: w.readOnly,
      list: variables,
      scope: w.scope,
      filterVar: _filterVar,
      onChange: _listChange,
    );
    if (!w.groupEnabled) {
      return Field(title: tw('nodes.variableAssigner.title'), operations: operations, child: list);
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Align(alignment: Alignment.centerLeft, child: _groupTitle()),
              ),
              operations,
            ],
          ),
          Padding(padding: const EdgeInsets.only(top: 4), child: list),
        ],
      ),
    );
  }
}

// ---- panel.tsx ---------------------------------------------------------------------------------------------------

Widget variableAggregatorPanelBody(BuildContext context, NodePanelProps props) =>
    VariableAggregatorPanel(key: ValueKey('variable-aggregator-${props.id}'), props: props);

class VariableAggregatorPanel extends StatefulWidget {
  const VariableAggregatorPanel({super.key, required this.props});
  final NodePanelProps props;

  @override
  State<VariableAggregatorPanel> createState() => _VariableAggregatorPanelState();
}

class _VariableAggregatorPanelState extends State<VariableAggregatorPanel> {
  late final VariableAggregatorConfig _config = VariableAggregatorConfig(
    id: widget.props.id,
    inputs: () => PanelInputs(widget.props).inputs,
    setInputs: (next) => PanelInputs(widget.props).setInputs(next),
    handleOutVarRenameChange: (_, o, n) => handleOutVarRenameChange(widget.props.controller, o, n),
    isVarUsedInNodes: (s) => isVarUsedInNodes(widget.props.controller, s),
    removeUsedVarInNodes: (s) => removeUsedVarInNodes(widget.props.controller, s),
    deleteNodeInspectorVars: widget.props.actions.store.deleteNodeInspectVars,
    renameInspectVarName: _renameInspectVar,
    onConfirmChange: _onConfirm,
  );

  void _renameInspectVar(String nodeId, String oldName, String newName) {
    final store = widget.props.actions.store;
    final node = store.nodesWithInspectVars.value.where((n) => n['nodeId'] == nodeId).firstOrNull;
    final v = jsList(node?['vars']).where((v) => jsGet(v, 'name') == oldName).firstOrNull;
    final varId = jsStr(jsGet(v, 'id'));
    if (varId != null) store.renameInspectVarName(nodeId, varId, [nodeId, newName]);
  }

  void _onConfirm(bool show) {
    if (!show || !mounted) return;
    showRemoveEffectVarConfirm(context, onConfirm: _config.onRemoveVarConfirm, onCancel: _config.hideRemoveVarConfirm);
  }

  @override
  void dispose() {
    _config.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final props = widget.props;
    final c = _config;
    final readOnly = props.readOnly;
    final inputs = c.inputs();
    final enabled = c.isEnableGroup;
    final groups = _groupsOf(inputs);
    final scope = NodeVars.of(props).scope;
    final onError = CorePanelHost.of(context).toastError;
    VarScope addScope(Object? type) => aggregatorAddScope(scope, filterVarByType(jsStr(type)));

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: !enabled
                ? VarGroupItem(
                    readOnly: readOnly,
                    payload: {'output_type': inputs['output_type'], 'variables': inputs['variables'] ?? <Object?>[]},
                    onChange: c.handleListOrTypeChange,
                    groupEnabled: false,
                    scope: scope,
                    addScope: addScope(inputs['output_type']),
                    onError: onError,
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, g) in groups.indexed) ...[
                        // `my-4` after each group but the last; the groups' `space-y-2` collapses into it.
                        if (i > 0) const PanelSplit(margin: EdgeInsets.symmetric(vertical: 16)),
                        VarGroupItem(
                          key: ValueKey(g['groupId']),
                          readOnly: readOnly,
                          payload: g,
                          onChange: c.handleListOrTypeChangeInGroup(jsKey(g['groupId'])),
                          groupEnabled: true,
                          canRemove: !readOnly && groups.length > 1,
                          onRemove: c.handleGroupRemoved(jsKey(g['groupId'])),
                          onGroupNameChange: c.handleVarGroupNameChange(jsKey(g['groupId'])),
                          scope: scope,
                          addScope: addScope(g['output_type']),
                          onError: onError,
                        ),
                      ],
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: AddButton(text: tw('nodes.variableAssigner.addGroup'), onPressed: c.handleAddGroup),
                      ),
                    ],
                  ),
          ),
          const PanelSplit(),
          Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, enabled ? 16 : 8),
            child: Field(
              title: tw('nodes.variableAssigner.aggregationGroup'),
              tooltip: tw('nodes.variableAssigner.aggregationGroupTip'),
              operations: DifySwitch(
                checked: enabled,
                onCheckedChange: c.handleGroupEnabledChange,
                disabled: readOnly,
                semanticLabel: tw('nodes.variableAssigner.aggregationGroup'),
              ),
            ),
          ),
          if (enabled) ...[
            const PanelSplit(),
            OutputVars(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final g in groups)
                    VarItem(
                      name: '${jsKey(g['group_name'])}.output',
                      type: jsStr(g['output_type']) ?? '',
                      description: tw('nodes.variableAssigner.outputVars.varDescribe', {'groupName': g['group_name']}),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
