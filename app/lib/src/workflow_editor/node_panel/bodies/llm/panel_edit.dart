/// What the model-node panels (LLM, Question Classifier, Parameter Extractor, Knowledge Retrieval, Agent) share:
/// Dify's `setInputs` (useNodeCrud) as the fewest small ops on the shared document, and the variables a node's
/// pickers offer (useAvailableVarList).
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../../../../editor/editor_controller.dart';
import '../../../../workflow/dify_json.dart';
import '../../../../workflow/var_types.dart';
import '../../../header/checklist/use_checklist.dart'
    show DifyFlowEdge, DifyFlowNode, getBeforeNodesInSameBranchIncludeParent;
import '../../../panel_fields/node_config.dart' show Json;
import '../../../panel_fields/var_picker_model.dart';
import '../../../prompt_editor/prompt_editor_panel.dart' show workflowNodesMapOf;
import '../../../prompt_editor/prompt_editor_types.dart' show WorkflowNodeInfo;
import '../../../store/store.dart';
import '../../node_panel_bodies.dart';

/// `x` as a JSON object (an empty one for anything else).
Json jsMap(Object? x) => x is Map<String, Object?> ? x : (x is Map ? x.cast<String, Object?>() : const {});

/// `x` as a list of strings (a value selector).
List<String> jsSelector(Object? x) => [for (final e in jsList(x)) jsKey(e)];

// ---- setInputs ---------------------------------------------------------------------------------------------------

/// Keys of Dify's `data` that are not settings (the shell or React Flow owns them).
const _notSettings = {'type', 'title', 'selected', '_dify_node'};

/// Dify's `setInputs(next)`: writes what differs between the node's data now and [next], as deep as both sides are
/// maps (`vision.enabled` alone when only it changed, so concurrent edits of sibling fields merge; a map losing a
/// member is written whole), keyed lists (VItems) item by item. A top-level key [next] lacks, or sets to null, is
/// cleared (null). Every op is based on the version the
/// panel shows, so a write someone else made meanwhile turns the edit into a conflict instead of being overwritten.
void setInputs(NodePanelProps props, Json next) {
  final node = props.node;
  final base = props.controller.seenVersion;
  final keys = {...node.config.keys, ...next.keys}.where((k) => !_notSettings.contains(k) && !k.startsWith('_'));
  for (final key in keys) {
    _write(props, [key], node.config[key], next[key], base);
  }
}

/// Writes data at [path] (`['memory', 'window', 'size']`) to [value] when it differs (see [setInputs]).
void setInputPath(NodePanelProps props, List<String> path, Object? value) {
  Value? orig = VMap(props.node.config);
  for (final k in path) {
    orig = orig is VMap ? orig.entries[k] : null;
  }
  _write(props, path, orig, value, props.controller.seenVersion);
}

/// Null-valued members count as absent when comparing (JSON `null` and a missing member read the same in Dify's
/// code); a null in [next] is still written as null (JSON null), a missing member is removed.
bool _same(Object? a, Object? b) {
  if (a is Map && b is Map) {
    final keys = {...a.keys, ...b.keys};
    return keys.every((k) => _same(a[k], b[k]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_same(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a == b;
  return a == b;
}

void _write(NodePanelProps props, List<String> path, Value? orig, Object? plain, int base) {
  final c = props.controller, doc = c.doc;
  if (_same(plainOf(orig), plain)) return;
  if (plain == null) {
    if (orig != null && orig is! VNull) c.setConfig(props.id, path, const VNull(), base: base);
    return;
  }
  if (orig is VMap && plain is Map) {
    // A member taken away (Dify's `delete`) rewrites the map, so the key goes rather than turning null.
    final removes = orig.entries.entries.any((e) => e.value is! VNull && !plain.containsKey(e.key));
    if (!removes) {
      for (final k in {...orig.entries.keys, ...plain.keys.map((k) => '$k')}) {
        _write(props, [...path, k], orig.entries[k], plain[k], base);
      }
      return;
    }
  }
  if (orig is VItems && plain is List) {
    _editItems(props, path, orig, plain, doc, base);
    return;
  }
  c.setConfig(props.id, path, mergeValue(orig, plain, doc), base: base);
}

/// [plain] as a config [Value] over [orig]: unchanged parts keep their form (references, keyed-list ids); new
/// two-part selectors naming an output of a node in [doc] become references.
Value mergeValue(Value? orig, Object? plain, Document doc) {
  switch ((orig, plain)) {
    case (VRef(:final ref) || VBroken(:final ref), final List l)
        when l.length == 2 && l[0] == ref.node && l[1] == ref.output:
      return orig!;
    case (VItems(:final items), final List l) when l.length == items.length:
      return VItems([for (final (i, item) in items.indexed) Item(item.id, mergeValue(item.value, l[i], doc))]);
    case (VList(:final items), final List l) when l.length == items.length:
      return VList([for (final (i, item) in items.indexed) mergeValue(item, l[i], doc)]);
    case (VMap(:final entries), final Map m):
      return VMap({for (final e in m.entries) '${e.key}': mergeValue(entries['${e.key}'], e.value, doc)});
  }
  if (plain is List && plain.length == 2 && plain.every((e) => e is String)) {
    return selectorValue([for (final e in plain) e as String], doc);
  }
  if (plain is List) return VList([for (final e in plain) mergeValue(null, e, doc)]);
  if (plain is Map) return VMap({for (final e in plain.entries) '${e.key}': mergeValue(null, e.value, doc)});
  if (plain is double) return Value.number(plain);
  return Value.of(plain);
}

/// A value selector as the document stores it: a reference when it names an output of a node in [doc] (any output
/// when the node declares none), else the plain list (sys / env / conversation variables, deeper paths).
Value selectorValue(List<String> selector, Document doc) {
  if (selector.length == 2) {
    final target = doc.nodes[selector[0]];
    final outs = target == null ? null : Document.declaredOutputs(target);
    if (target != null && (outs == null || outs.contains(selector[1]))) {
      return VRef(OutputRef(selector[0], selector[1]));
    }
  }
  return VList([for (final s in selector) VString(s)]);
}

/// The id a keyed-list element carries in Dify's data (`id`, or `variable` for variable lists).
String? _plainId(Object? v) => switch (v) {
  {'id': final String id} when id.isNotEmpty => id,
  _ => null,
};

/// Edits the keyed list at [path] from [orig] to [next] with item ops. When the elements carry ids (a prompt's
/// `id`), they are matched by them: removed ones go, the longest run already in order stays and is updated in place,
/// the others are inserted where they now are (a moved one is taken out and put back as a new item: item ids are
/// never reused). Otherwise the lists are compared by position (one look ahead for a single insert or removal).
void _editItems(NodePanelProps props, List<String> path, VItems orig, List<Object?> next, Document doc, int base) {
  final c = props.controller;
  final items = orig.items;
  final byId = <String, Item>{for (final i in items) _plainId(plainOf(i.value)) ?? i.id: i};
  final ids = [for (final v in next) _plainId(v)];
  final keyed = ids.every((id) => id != null) && ids.toSet().length == ids.length;
  if (keyed && byId.length == items.length && ids.any(byId.containsKey)) {
    final wanted = ids.toSet();
    final kept = [
      for (final e in byId.entries)
        if (wanted.contains(e.key)) e.key,
    ];
    final stay = _lcs(kept, [
      for (final id in ids)
        if (byId.containsKey(id)) id!,
    ]).toSet();
    for (final e in byId.entries) {
      if (!stay.contains(e.key)) c.removeItem(props.id, path, e.value.id);
    }
    String? last;
    for (final (j, id) in ids.indexed) {
      final want = next[j];
      final item = byId[id];
      if (item != null && stay.contains(id)) {
        if (!_same(plainOf(item.value), want)) {
          c.updateItem(props.id, path, item.id, mergeValue(item.value, want, doc), base: base);
        }
        last = item.id;
      } else {
        c.insertItem(props.id, path, mergeValue(item?.value, want, doc), after: last);
        last = _lastInserted(c, props.id, path, last);
      }
    }
    return;
  }
  var i = 0;
  String? last; // the item new ones go after (null: the front)
  final pending = <Value>[];
  void flush() {
    for (final v in pending.reversed) {
      c.insertItem(props.id, path, v, after: last);
    }
    pending.clear();
  }

  for (var j = 0; j < next.length; j++) {
    final want = next[j];
    bool same(int k, Object? v) => k < items.length && _same(plainOf(items[k].value), v);
    if (same(i, want)) {
      flush();
      last = items[i++].id;
    } else if (same(i + 1, want)) {
      flush();
      c.removeItem(props.id, path, items[i].id);
      last = items[i + 1].id;
      i += 2;
    } else if (i < items.length && !(j + 1 < next.length && same(i, next[j + 1]))) {
      flush();
      c.updateItem(props.id, path, items[i].id, mergeValue(items[i].value, want, doc), base: base);
      last = items[i++].id;
    } else {
      pending.add(mergeValue(null, want, doc));
    }
  }
  flush();
  for (; i < items.length; i++) {
    c.removeItem(props.id, path, items[i].id);
  }
}

/// The id of the item just inserted after [after] at [path] (the local document applies edits at once).
String? _lastInserted(EditorController c, String nodeId, List<String> path, String? after) {
  final list = ConfigTree.list(c.doc.nodes[nodeId]?.config ?? const {}, path);
  if (list is! ListFound) return after;
  final at = after == null ? 0 : list.items.indexWhere((i) => i.id == after) + 1;
  return at >= 0 && at < list.items.length ? list.items[at].id : after;
}

/// The longest common subsequence of [a] and [b].
List<String> _lcs(List<String> a, List<String> b) {
  final n = a.length, m = b.length;
  final t = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      t[i][j] = a[i] == b[j] ? t[i + 1][j + 1] + 1 : (t[i + 1][j] > t[i][j + 1] ? t[i + 1][j] : t[i][j + 1]);
    }
  }
  final out = <String>[];
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      out.add(a[i]);
      i++;
      j++;
    } else if (t[i + 1][j] >= t[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return out;
}

// ---- the variables on offer --------------------------------------------------------------------------------------

/// What a node's pickers and prompt editors work on (useAvailableVarList): the upstream nodes in the same branch
/// (and the container), as a [VarScope] and as the prompt editor's nodes map.
class NodeVars {
  NodeVars._(this.scope, this.beforeNodes, this.parent);

  /// The scope of [props]' node in its document, with the store's environment and (in a chatflow) conversation
  /// variables.
  factory NodeVars.of(BuildContext context, NodePanelProps props) {
    final doc = props.controller.doc;
    final flow = [for (final n in doc.nodes.values) DifyFlowNode.of(n)];
    final edges = [for (final e in doc.edges.values) DifyFlowEdge.of(e)];
    List<Node> before;
    try {
      before = [for (final b in getBeforeNodesInSameBranchIncludeParent(props.id, flow, edges)) ?b.node];
    } on StateError {
      before = const [];
    }
    final parentId = flow.where((n) => n.id == props.id).firstOrNull?.parentId;
    final parent = parentId == null ? null : doc.nodes[parentId];
    final store = context.getInheritedWidgetOfExactType<WorkflowStoreScope>()?.store;
    final env = DeclaredVar.listOf(store?.environmentVariables.value ?? const []);
    final conv = props.chatMode
        ? DeclaredVar.listOf(store?.conversationVariables.value ?? const [])
        : const <DeclaredVar>[];
    VarScope scope;
    try {
      scope = VarScope.of(
        beforeNodes: [
          for (final n in before)
            if (n.id != parent?.id) n,
        ],
        parent: parent,
        chatMode: props.chatMode,
        environmentVariables: env,
        conversationVariables: conv,
      );
    } on Object {
      scope = const VarScope();
    }
    return NodeVars._(scope, before, parent);
  }

  final VarScope scope;
  final List<Node> beforeNodes;
  final Node? parent;

  /// The prompt editors' `availableNodes` map (titles and types; `sys` as the Start node).
  late final Map<String, WorkflowNodeInfo> nodesMap = workflowNodesMapOf([...beforeNodes, ?parent]);

  /// The variables [filter] accepts (Dify's `filterVar` option of useAvailableVarList).
  VarScope filtered(VarFilter filter) => scope.filtered(filter);
}

// ---- filters (llm/panel.tsx, utils) ------------------------------------------------------------------------------

bool _typeIn(PickerVar v, Set<String> types) => types.contains(v.type);

/// `filterInputVar` (LLM prompt).
bool filterInputVar(PickerVar v, List<String> _) => _typeIn(v, const {
  VarType.number,
  VarType.string,
  VarType.secret,
  VarType.arrayString,
  VarType.arrayNumber,
  VarType.file,
  VarType.arrayFile,
});

/// `filterJinja2InputVar`.
bool filterJinja2InputVar(PickerVar v, List<String> _) => _typeIn(v, const {
  VarType.number,
  VarType.string,
  VarType.secret,
  VarType.arrayString,
  VarType.arrayNumber,
  VarType.arrayBoolean,
  VarType.arrayObject,
  VarType.object,
  VarType.array,
  VarType.boolean,
});

/// `filterMemoryPromptVar` (the LLM context, the agent's variables).
bool filterMemoryPromptVar(PickerVar v, List<String> _) => _typeIn(v, const {
  VarType.arrayObject,
  VarType.array,
  VarType.number,
  VarType.string,
  VarType.secret,
  VarType.arrayString,
  VarType.arrayNumber,
  VarType.file,
  VarType.arrayFile,
});

/// `filterVar` of string-only pickers (query variables).
bool filterStringVar(PickerVar v, List<String> _) => v.type == VarType.string;

/// Number and string variables (the model parameters' and instructions' variable lists).
bool filterNumberStringVar(PickerVar v, List<String> _) => v.type == VarType.number || v.type == VarType.string;

/// `filterFileVar`.
bool filterFileVar(PickerVar v, List<String> _) => v.type == VarType.file || v.type == VarType.arrayFile;
