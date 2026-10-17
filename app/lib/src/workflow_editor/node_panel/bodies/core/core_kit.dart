/// What the core node panels share: the host's data and services ([CorePanelHost]), Dify's `useNodeCrud` over the
/// collaborative document ([PanelInputs]: a node's `data` in, the smallest ops out), the variables a node may
/// reference ([panelScope]) and the variable-usage helpers of hooks/use-workflow.ts.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../editor/editor_controller.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../ids.dart';
import '../../../../workflow/dify_json.dart';
import '../../../../workflow/var_types.dart';
import '../../../context_menu/workflow_actions.dart' show parentIdOf;
import '../../../header/checklist/use_checklist.dart';
import '../../../panel_fields/panel_fields.dart';
import '../../../prompt_editor/prompt_editor.dart' show WorkflowNodeInfo;
import '../../../prompt_editor/prompt_editor_panel.dart' show workflowNodesMapOf;
import '../../node_panel_bodies.dart';

String tw(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);
String tc(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

// ---- the host ----------------------------------------------------------------------------------------------------

/// Builds the code generator button of the Code panel's editor (Dify's CodeGeneratorButton); [onGenerated] takes
/// the generated code.
typedef CodeGeneratorBuilder = Widget Function(
  BuildContext context,
  String nodeId,
  String language,
  ValueChanged<String> onGenerated,
);

/// What the core panels need from the app that the document does not hold: Dify's toast, the backend's node
/// default configs (`nodesDefaultConfigs`, `fetchNodeDefault` per code language), the file upload limits, the
/// code generator. Everything has a working default.
@immutable
class CorePanelHostData {
  const CorePanelHostData({
    this.toastError,
    this.nodesDefaultConfigs = builtinNodesDefaultConfigs,
    this.codeLanguageDefaults = builtinCodeLanguageDefaults,
    this.workflowFileUploadLimit = 10,
    this.codeGenerator,
  });

  /// `toast.error(message)`; absent, errors are not shown.
  final ValueChanged<String>? toastError;

  /// `GET /apps/{id}/workflows/default-workflow-block-configs`, by node type.
  final Map<String, Map<String, Object?>> nodesDefaultConfigs;

  /// `.../default-workflow-block-configs/code?q={"code_language": ...}`, by language.
  final Map<String, Map<String, Object?>> codeLanguageDefaults;

  /// `fileUploadConfig.workflow_file_upload_limit`.
  final int workflowFileUploadLimit;
  final CodeGeneratorBuilder? codeGenerator;
}

/// The backend's code defaults (api/core/helper/code_executor/*_code_provider.py).
const builtinCodeLanguageDefaults = <String, Map<String, Object?>>{
  'python3': {
    'code_language': 'python3',
    'code': 'def main(arg1: str, arg2: str):\n    return {\n        "result": arg1 + arg2,\n    }\n',
    'variables': [
      {'variable': 'arg1', 'value_selector': <Object?>[]},
      {'variable': 'arg2', 'value_selector': <Object?>[]},
    ],
    'outputs': {
      'result': {'type': 'string', 'children': null},
    },
  },
  'javascript': {
    'code_language': 'javascript',
    'code': 'function main({arg1, arg2}) {\n    return {\n        result: arg1 + arg2\n    }\n}\n',
    'variables': [
      {'variable': 'arg1', 'value_selector': <Object?>[]},
      {'variable': 'arg2', 'value_selector': <Object?>[]},
    ],
    'outputs': {
      'result': {'type': 'string', 'children': null},
    },
  },
};

/// The backend's `default-workflow-block-configs` for the core nodes.
const builtinNodesDefaultConfigs = <String, Map<String, Object?>>{
  'code': {
    'code_language': 'python3',
    'code': 'def main(arg1: str, arg2: str):\n    return {\n        "result": arg1 + arg2,\n    }\n',
    'variables': [
      {'variable': 'arg1', 'value_selector': <Object?>[]},
      {'variable': 'arg2', 'value_selector': <Object?>[]},
    ],
    'outputs': {
      'result': {'type': 'string', 'children': null},
    },
  },
  'template-transform': {
    'template': '{{ arg1 }}',
    'variables': [
      {'variable': 'arg1', 'value_selector': <Object?>[]},
    ],
  },
};

/// Provides [data] to the core panels below.
class CorePanelHost extends InheritedWidget {
  const CorePanelHost({super.key, required this.data, required super.child});
  final CorePanelHostData data;

  static CorePanelHostData of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CorePanelHost>()?.data ?? const CorePanelHostData();

  @override
  bool updateShouldNotify(CorePanelHost old) => old.data != data;
}

// ---- useNodeCrud ---------------------------------------------------------------------------------------------------

/// Dify's `useNodeCrud` for one node: [inputs] is its `data` as it is now (read live, like `inputsRef.current`),
/// [setInputs] writes a whole new `data` as the few ops that change what differs, so concurrent edits to other
/// fields or other items of a keyed list merge.
class PanelInputs {
  PanelInputs(this.props);
  final NodePanelProps props;

  EditorController get _c => props.controller;
  Node get node => _c.doc.nodes[props.id] ?? props.node;
  Map<String, Object?> get inputs => difyDataOf(node);

  /// Writes [next] (Dify's data) over the node's config; nothing while the panel is read-only (Dify's
  /// `handleNodeDataUpdate` checks `getNodesReadOnly`). When only [textKey] changed, it is written with [base] (typed
  /// text).
  void setInputs(Map<String, Object?> next, {String? textKey, int Function()? base}) {
    if (props.readOnly) return;
    if (textKey != null && base != null) {
      final now = inputs;
      final changed = [
        for (final e in next.entries)
          if (!jsonEquals(now[e.key], e.value)) e.key,
      ];
      if (changed.length == 1 && changed.single == textKey) return set(textKey, next[textKey], base: base());
    }
    writeNodeData(_c, node, next);
  }

  /// Sets one top-level key (typed text passes [base]).
  void set(String key, Object? value, {int? base}) {
    if (props.readOnly) return;
    final n = node;
    _c.setConfig(n.id, [key], docValue(value, _c.doc, n.config[key]), base: base);
  }
}

/// (node type, key): the config keys kept as keyed lists (as the DSL import makes them; `*` = any type).
const _keyedLists = {('*', 'variables'), ('end', 'outputs'), ('code', 'outputs'), ('if-else', 'cases')};

bool _isKeyed(String type, String key) => _keyedLists.contains(('*', key)) || _keyedLists.contains((type, key));

/// Writes Dify's [data] for [node]: each top-level key that changed, keyed lists item by item.
void writeNodeData(EditorController c, Node node, Map<String, Object?> data) {
  for (final MapEntry(:key, :value) in data.entries) {
    if (key == 'type' || key == 'title' || key == 'selected' || key.startsWith('_')) continue;
    final orig = node.config[key];
    if (orig == null && value == null) continue;
    if (orig != null && jsonEquals(plainOf(orig), value)) continue;
    if (orig is! VItems && value is List && _isKeyed(node.type, key)) {
      // A keyed list from scratch (or from an atomic list), so its items merge from now on.
      c.setConfig(node.id, [key], VItems([for (final v in value) Item(newId('i'), docValue(v, c.doc))]));
      continue;
    }
    _writeKey(c, node.id, [key], orig, value);
  }
}

/// Writes [next] (a document [Node] with an updated config, from `updateNodeVars`) over [orig].
void writeNodeConfig(EditorController c, Node orig, Node next) {
  for (final MapEntry(:key, :value) in next.config.entries) {
    final o = orig.config[key];
    if (o == value) continue;
    if (o is VItems && value is VItems && _sameIds(o.items, value.items)) {
      for (final (i, item) in value.items.indexed) {
        if (item.value != o.items[i].value) c.updateItem(orig.id, [key], item.id, item.value);
      }
    } else {
      c.setConfig(orig.id, [key], value);
    }
  }
}

bool _sameIds(List<Item> a, List<Item> b) =>
    a.length == b.length && [for (var i = 0; i < a.length; i++) a[i].id == b[i].id].every((x) => x);

/// Writes [next] at [path]: a map that keeps all its members member by member (only what changed, at its own path,
/// so concurrent edits of sibling members merge; a map losing a member is written whole), a keyed list item by item.
void _writeKey(EditorController c, String nodeId, List<String> path, Value? orig, Object? next) {
  final doc = c.doc;
  if (orig is VMap && next is Map && orig.entries.keys.every(next.containsKey)) {
    for (final MapEntry(:key, :value) in next.entries) {
      final o = orig.entries['$key'];
      if (o == null && value == null) continue;
      if (o != null && jsonEquals(plainOf(o), value)) continue;
      _writeKey(c, nodeId, [...path, '$key'], o, value);
    }
    return;
  }
  if (orig is VItems && next is List) {
    final old = orig.items;
    final plain = [for (final i in old) plainOf(i.value)];
    bool eq(int i, int j) => jsonEquals(plain[i], next[j]);
    // One item changed in place, or a pure reorder.
    if (next.length == old.length) {
      final changed = [
        for (var i = 0; i < old.length; i++)
          if (!eq(i, i)) i,
      ];
      final reorder = _permutation(plain, next);
      if (reorder != null && changed.isNotEmpty) {
        c.setConfig(nodeId, path, VItems([for (final i in reorder) old[i]]));
        return;
      }
      for (final i in changed) {
        c.updateItem(nodeId, path, old[i].id, docValue(next[i], doc, old[i].value));
      }
      return;
    }
    // One item added.
    if (next.length == old.length + 1) {
      for (var k = 0; k < next.length; k++) {
        if ([for (var i = 0; i < old.length; i++) eq(i, i < k ? i : i + 1)].every((x) => x)) {
          c.insertItem(nodeId, path, docValue(next[k], doc), after: k == 0 ? null : old[k - 1].id);
          return;
        }
      }
    }
    // One item removed.
    if (next.length == old.length - 1) {
      for (var k = 0; k < old.length; k++) {
        if ([for (var j = 0; j < next.length; j++) eq(j < k ? j : j + 1, j)].every((x) => x)) {
          c.removeItem(nodeId, path, old[k].id);
          return;
        }
      }
    }
    // Anything else: the whole list, keeping the ids of the items that stay.
    final used = <String>{};
    final items = <Item>[];
    for (final (j, v) in next.indexed) {
      final i = [
        for (var i = 0; i < old.length; i++)
          if (!used.contains(old[i].id) && eq(i, j)) i,
      ].firstOrNull;
      if (i != null) {
        used.add(old[i].id);
        items.add(old[i]);
      } else {
        final id = j < old.length && !used.contains(old[j].id) ? old[j].id : newId('i');
        used.add(id);
        items.add(Item(id, docValue(v, doc, j < old.length ? old[j].value : null)));
      }
    }
    c.setConfig(nodeId, path, VItems(items));
    return;
  }
  c.setConfig(nodeId, path, docValue(next, doc, orig));
}

/// The order of [a]'s elements in [b] when [b] is a permutation of [a], else null.
List<int>? _permutation(List<Object?> a, List<Object?> b) {
  final used = <int>{};
  final out = <int>[];
  for (final x in b) {
    final i = [
      for (var i = 0; i < a.length; i++)
        if (!used.contains(i) && jsonEquals(a[i], x)) i,
    ].firstOrNull;
    if (i == null) return null;
    used.add(i);
    out.add(i);
  }
  return out;
}

/// Dify's plain JSON [v] as a document value, keeping [orig]'s forms where the JSON did not change (references,
/// keyed-list ids). A new `[node, output]` pair naming an output of a node in [doc] becomes a reference.
Value docValue(Object? v, Document doc, [Value? orig]) {
  if (orig != null && jsonEquals(plainOf(orig), v)) return orig;
  switch ((orig, v)) {
    case (VItems(:final items), final List l) when l.length == items.length:
      return VItems([for (final (i, item) in items.indexed) Item(item.id, docValue(l[i], doc, item.value))]);
    case (VList(:final items), final List l) when l.length == items.length:
      return VList([for (final (i, item) in items.indexed) docValue(l[i], doc, item)]);
    case (VMap(:final entries), final Map m):
      return VMap({
        for (final e in m.entries)
          if (e.value != null || entries.containsKey('${e.key}'))
            '${e.key}': docValue(e.value, doc, entries['${e.key}']),
      });
  }
  if (v is List) {
    if (refOf(v, doc) case final ref?) return VRef(ref);
    return VList([for (final i in v) docValue(i, doc)]);
  }
  if (v is Map) return VMap({for (final e in v.entries) '${e.key}': docValue(e.value, doc)});
  if (v is double) return Value.number(v);
  return Value.fromJson(v);
}

/// The reference [selector] makes in [doc]: `[node, output]` of an existing node that declares that output.
OutputRef? refOf(List<Object?> selector, Document doc) {
  if (selector.length != 2 || selector[0] is! String || selector[1] is! String) return null;
  final target = doc.nodes[selector[0]];
  if (target == null) return null;
  final outs = Document.declaredOutputs(target);
  if (outs != null && !outs.contains(selector[1])) return null;
  return OutputRef(selector[0]! as String, selector[1]! as String);
}

/// The value selector at `data[key]` (plain JSON) as strings; empty when unset.
List<String> selectorList(Object? v) => [for (final e in jsList(v)) jsKey(e)];

// ---- typed text --------------------------------------------------------------------------------------------------

/// The document version a burst of typing into one field began on (each keystroke is written at once, with this
/// base): taken at the first keystroke, kept while keystrokes come less than a second apart.
class TypingBase {
  TypingBase(this.currentVersion);
  final int Function() currentVersion;
  int? _base;
  DateTime _last = DateTime(0);

  int call() {
    final now = DateTime.now();
    if (_base == null || now.difference(_last) > const Duration(seconds: 1)) _base = currentVersion();
    _last = now;
    return _base!;
  }
}

// ---- the variables on offer --------------------------------------------------------------------------------------

/// What a node's pickers offer ([scope]) and the nodes the prompt editor's variable blocks name ([availableNodes]).
typedef PanelVars = ({VarScope scope, Map<String, WorkflowNodeInfo> availableNodes, List<Node> beforeNodes});

/// `useAvailableVarList(id)`: the upstream nodes in the same branch (and the container), Dify's
/// `getBeforeNodesInSameBranchIncludeParent`, with the environment and (in a chatflow) conversation variables.
PanelVars panelVars(NodePanelProps props) {
  final doc = props.controller.doc;
  final graph = difyGraphOf(doc);
  final before = [
    for (final n in getBeforeNodesInSameBranchIncludeParent(props.id, graph.nodes, graph.edges)) ?n.node,
  ];
  final parentId = parentIdOf(props.node);
  final parent = parentId == null ? null : doc.nodes[parentId];
  final store = props.actions.store;
  VarScope scope;
  try {
    scope = VarScope.of(
      beforeNodes: before,
      parent: parent,
      chatMode: props.chatMode,
      environmentVariables: DeclaredVar.listOf(store.environmentVariables.value),
      conversationVariables: props.chatMode ? DeclaredVar.listOf(store.conversationVariables.value) : const [],
      currentIterationTitle: tw('nodes.iteration.currentIteration'),
    );
  } on StateError {
    scope = const VarScope();
  }
  final start = doc.nodes.values.where((n) => n.type == 'start');
  return (scope: scope, availableNodes: workflowNodesMapOf([...before, ...start]), beforeNodes: before);
}

// ---- hooks/use-workflow.ts ---------------------------------------------------------------------------------------

/// `getAfterNodesInSameBranch`: [nodeId] and every node downstream of it.
List<Node> afterNodesInSameBranch(Document doc, String nodeId) {
  final current = doc.nodes[nodeId];
  if (current == null) return const [];
  final seen = <String>{nodeId};
  final list = [current];
  void traverse(String id) {
    for (final e in doc.edges.values) {
      if (e.source != id) continue;
      final n = doc.nodes[e.target];
      if (n == null || !seen.add(n.id)) continue;
      list.add(n);
      traverse(n.id);
    }
  }

  traverse(nodeId);
  return list;
}

/// `findUsedVarNodes`.
List<Node> findUsedVarNodes(List<String> selector, Iterable<Node> nodes) {
  final key = selector.join('.');
  return [
    for (final n in nodes)
      if (_usedVars(n).any((v) => v.join('.') == key)) n,
  ];
}

List<List<String>> _usedVars(Node n) {
  try {
    return getNodeUsedVars(n);
  } on StateError {
    return const [];
  }
}

/// `isVarUsedInNodes`.
bool isVarUsedInNodes(EditorController c, List<String> selector) =>
    findUsedVarNodes(selector, afterNodesInSameBranch(c.doc, selector.first)).isNotEmpty;

/// `removeUsedVarInNodes`: the downstream uses of [selector] are cleared.
void removeUsedVarInNodes(EditorController c, List<String> selector) {
  for (final n in findUsedVarNodes(selector, afterNodesInSameBranch(c.doc, selector.first))) {
    _rewrite(c, n, selector, const []);
  }
}

/// `handleOutVarRenameChange`: every use of [oldSelector] in the workflow now names [newSelector].
void handleOutVarRenameChange(EditorController c, List<String> oldSelector, List<String> newSelector) {
  for (final n in findUsedVarNodes(oldSelector, c.doc.nodes.values)) {
    _rewrite(c, n, oldSelector, newSelector);
  }
}

void _rewrite(EditorController c, Node n, List<String> oldSelector, List<String> newSelector) {
  try {
    writeNodeConfig(c, n, updateNodeVars(n, oldSelector, newSelector));
  } on StateError {
    // Dify's code would throw on this node's data; leave it.
  }
}

// ---- small widgets -----------------------------------------------------------------------------------------------

/// The `+` of a Field's operations (`cursor-pointer rounded-md p-1 hover:bg-state-base-hover`, `i-ri-add-line size-4
/// text-text-tertiary`), named "Add `field`".
class FieldAddButton extends StatelessWidget {
  const FieldAddButton({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: label,
    onPressed: onPressed,
    builder: (context, hovered, focused) => Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: hovered ? DifyColors.stateBaseHover : null,
        borderRadius: BorderRadius.circular(DifyRadius.md),
        border: focused ? Border.all(color: DifyColors.componentsInputBorderActive) : null,
      ),
      child: const RemixIcon('add-line', size: 16, color: DifyColors.textTertiary),
    ),
  );
}

/// ListNoDataPlaceholder (list-no-data-placeholder.tsx): `flex min-h-10.5 w-full items-center justify-center
/// rounded-[10px] bg-background-section system-xs-regular text-text-tertiary`.
class ListNoDataPlaceholder extends StatelessWidget {
  const ListNoDataPlaceholder(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 42),
    alignment: Alignment.center,
    decoration: BoxDecoration(color: DifyColors.backgroundSection, borderRadius: BorderRadius.circular(10)),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
    ),
  );
}

/// RemoveEffectVarConfirm (remove-effect-var-confirm.tsx): the "Remove Variable" alert dialog over the screen.
Future<void> showRemoveEffectVarConfirm(
  BuildContext context, {
  required VoidCallback onConfirm,
  VoidCallback? onCancel,
}) async {
  final ok = await showDifyConfirm(
    context,
    title: tw('common.effectVarConfirm.title'),
    content: tw('common.effectVarConfirm.content'),
  );
  (ok ? onConfirm : onCancel)?.call();
}

/// dify-ui's AlertDialog with Cancel / Confirm (`w-120 rounded-2xl p-6`, title `title-2xl-semi-bold`, content
/// `system-md-regular text-text-tertiary`, actions right aligned): true when confirmed.
Future<bool> showDifyConfirm(BuildContext context, {required String title, String? content}) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  final done = Completer<bool>();
  late final OverlayEntry entry;
  void close(bool v) {
    entry.remove();
    done.complete(v);
  }

  entry = OverlayEntry(
    builder: (context) => _ConfirmDialog(title: title, content: content, onClose: close),
  );
  overlay.insert(entry);
  return done.future;
}

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({required this.title, required this.content, required this.onClose});
  final String title;
  final String? content;
  final ValueChanged<bool> onClose;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: GestureDetector(
          onTap: () => onClose(false),
          child: const ColoredBox(color: DifyColors.backgroundOverlay),
        ),
      ),
      Center(
        child: Container(
          width: 480,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: DifyColors.componentsPanelBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
            boxShadow: DifyShadows.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary)),
              if (content != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(content!, style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textTertiary)),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    DifyButton(onPressed: () => onClose(false), child: Text(tc('operation.cancel'))),
                    DifyButton(
                      variant: DifyButtonVariant.primary,
                      tone: DifyButtonTone.destructive,
                      onPressed: () => onClose(true),
                      child: Text(tc('operation.confirm')),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

// ---- variable lists (Dify's `Variable[]`) ------------------------------------------------------------------------

/// The rows of a [VarList] for Dify's `Variable[]` [list]; each row's id is its index in [list].
List<VarListItem> varListItemsOf(Object? list) => [
  for (final (i, v) in jsList(list).indexed)
    VarListItem(
      variable: jsStr(jsGet(v, 'variable')) ?? '',
      valueSelector: selectorList(jsGet(v, 'value_selector')),
      valueType: jsStr(jsGet(v, 'value_type')),
      variableType: switch (jsGet(v, 'variable_type')) {
        'constant' => VarKindType.constant,
        'variable' => VarKindType.variable,
        _ => null,
      },
      value: jsStr(jsGet(v, 'value')),
      id: '$i',
    ),
];

/// [rows] back as Dify's `Variable[]`, each over the variable of [list] it came from (its other fields kept).
List<Map<String, Object?>> varListDataOf(List<VarListItem> rows, Object? list) {
  final orig = jsList(list);
  return [
    for (final r in rows)
      () {
        final i = int.tryParse(r.id ?? '');
        final o = i != null && i < orig.length && orig[i] is Map ? (orig[i]! as Map).cast<String, Object?>() : null;
        final m = {...?o, 'variable': r.variable, 'value_selector': r.valueSelector};
        if (r.valueType != null) {
          m['value_type'] = r.valueType;
        } else if (!jsonEquals(o?['value_selector'], r.valueSelector)) {
          m.remove('value_type');
        }
        if (r.variableType != null) m['variable_type'] = r.variableType!.name;
        if (r.value != null) m['value'] = r.value;
        return m;
      }(),
  ];
}
