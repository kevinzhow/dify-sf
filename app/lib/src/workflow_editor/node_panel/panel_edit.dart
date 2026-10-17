/// The one write path of the node panels: Dify's `setInputs` (useNodeCrud) as the fewest small ops on the shared
/// document, and the variables a node's pickers offer (`useAvailableVarList`) as one [VarScope] builder.
///
/// Public API (other editor parts, e.g. the variable panels, may use it; keep it stable):
/// - [setInputs] / [patchInputs] / [setInputPath]: a panel's write of Dify's new `data` (or one key / one nested
///   path) for its node; nothing while the panel is read-only.
/// - [PanelInputs]: `useNodeCrud` over the live data (`inputs`, `setInputs(next, textKey:, textBase:)`, `set`).
/// - [writeInputs]: the same diff for any node of an [EditorController] (no panel needed).
/// - [writeNodeConfig]: a document [Node] with an updated config (e.g. from `updateNodeVars`) as the fewest ops.
/// - [mergeValue] / [selectorValue]: Dify's plain JSON as a config [Value] (references kept / made).
/// - [NodeVars]: a node's variable scope (`NodeVars.of(props)`: `scope`, `filtered`, `nodesMap`, `beforeNodes`,
///   `parent`; `NodeVars.scopeOver` for an explicit node list).
///
/// A panel hands over Dify's whole new `data`; what differs from the node is written:
/// - a nested map member that changed is written alone, by its path (`vision.configs.detail`), so two people editing
///   different members of the same map both keep their edit. A map losing a member (Dify's `delete`) is written
///   whole, that map only: the protocol has no op that removes a map member.
/// - a keyed list (VItems) is edited item by item: elements carrying an id (`id`, `case_id`) are matched by it,
///   others by position; unchanged items keep their item ids. A reorder keeps the longest run in order and moves
///   the others as remove + insert (the protocol has no move; item ids are never reused).
/// - a value selector `[node, output]` naming an output of a node in the document is stored as a reference.
/// - Dify's `_` keys (UI state) are not written, except one the node already stores, which is updated.
/// - nothing is written while the panel is read-only (Dify's `handleNodeDataUpdate` checks `getNodesReadOnly`).
/// - every op carries `base`: the version the user saw when the edit began (typed text passes its draft's), so a write
///   someone else made meanwhile to the same field turns the edit into a conflict instead of being overwritten.
///
/// The diff is three-way: a field whose new value equals what the panel showed is left alone even when the document
/// has moved on since (another user's write, or the panel's own earlier write in the same handler), and list items
/// the panel never showed are never removed. So a panel computing `next` from a stale `data` cannot undo edits it did
/// not make.
library;

import 'package:collab_client/collab_client.dart';

import '../../editor/editor_controller.dart';
import '../../ids.dart';
import '../../workflow/dify_json.dart';
import '../../workflow/var_types.dart';
import '../../i18n/dify_i18n.dart';
import '../context_menu/workflow_actions.dart' show parentIdOf;
import '../header/checklist/use_checklist.dart' show difyGraphOf, getBeforeNodesInSameBranchIncludeParent;
import '../panel_fields/node_config.dart' show Json;
import '../panel_fields/var_picker_model.dart';
import '../prompt_editor/prompt_editor_panel.dart' show workflowNodesMapOf;
import '../prompt_editor/prompt_editor_types.dart' show WorkflowNodeInfo;
import 'node_panel_bodies.dart';

// ---- setInputs ---------------------------------------------------------------------------------------------------

/// Dify's `setInputs(next)` for [props]' node, where [next] was computed from the data the panel shows
/// (`props.data`, or the live data: both work). A top-level key [next] lacks, or sets to null, is cleared (null).
/// [base]: the version the edit began on (typed text); none, the latest.
void setInputs(NodePanelProps props, Json next, {int? base}) {
  if (props.readOnly) return;
  writeInputs(props.controller, props.id, next, shown: props.node, base: base);
}

/// `setInputs({...data, ...patch})`: [setInputs] of the node's data with [patch]'s keys replaced.
void patchInputs(NodePanelProps props, Json patch, {int? base}) =>
    setInputs(props, {...props.data, ...patch}, base: base);

/// Sets data at [path] (`['memory', 'window', 'size']`) to the plain JSON [value], written as [setInputs] would.
void setInputPath(NodePanelProps props, List<String> path, Object? value, {int? base}) {
  if (props.readOnly || path.isEmpty) return;
  final c = props.controller;
  final live = c.doc.nodes[props.id];
  if (live == null) return;
  _Writer(
    c,
    props.id,
    base,
  ).write(path, ConfigTree.get(props.node.config, path), ConfigTree.get(live.config, path), value);
}

/// Keys of Dify's `data` that are not settings (the shell or React Flow owns them).
const _notSettings = {'type', 'title', 'selected', '_dify_node'};

/// Writes Dify's [next] data over node [nodeId] in [c]'s document: what differs from the node now, and was changed
/// relative to [shown] (the node [next] was computed from; none: the node now), as described in this library's doc.
void writeInputs(EditorController c, String nodeId, Json next, {Node? shown, int? base}) {
  final live = c.doc.nodes[nodeId];
  if (live == null) return;
  final seen = shown ?? live;
  final w = _Writer(c, nodeId, base);
  final keys = {...seen.config.keys, ...live.config.keys, ...next.keys};
  for (final key in keys) {
    if (_notSettings.contains(key)) continue;
    // Dify's `_` keys are UI state, derived (`_targetBranches`) or transient (`_isSingleRun`); one the document
    // stores (`_dataSourceStartToAdd`, set when the block was added) is updated, never created or removed.
    if (key.startsWith('_') && !(live.config.containsKey(key) && next.containsKey(key))) continue;
    final orig = live.config[key];
    final plain = next[key];
    if (orig is! VItems && plain is List && _isKeyedList(live.type, key) && !_same(plainOf(orig), plain)) {
      // A keyed list from scratch (or from an atomic list), so its items merge from now on.
      if (_same(plainOf(seen.config[key]), plain)) continue;
      c.setConfig(
        nodeId,
        [key],
        VItems([for (final v in plain) Item(newId('i'), mergeValue(null, v, c.doc))]),
        base: base,
      );
      continue;
    }
    w.write([key], seen.config[key], orig, plain);
  }
}

/// (node type, key): the config keys kept as keyed lists, as the DSL import makes them (`*` = any type).
const _keyedLists = {
  ('*', 'variables'),
  ('end', 'outputs'),
  ('code', 'outputs'),
  ('if-else', 'cases'),
  ('llm', 'prompt_template'),
  ('loop', 'loop_variables'),
  ('loop', 'break_conditions'),
};

bool _isKeyedList(String type, String key) => _keyedLists.contains(('*', key)) || _keyedLists.contains((type, key));

/// Null-valued members count as absent when comparing (JSON `null` and a missing member read the same in Dify's
/// code); numbers compare by value.
bool _same(Object? a, Object? b) {
  if (a is Map && b is Map) {
    for (final k in {...a.keys, ...b.keys}) {
      if (!_same(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_same(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

class _Writer {
  _Writer(this.c, this.nodeId, this.base);
  final EditorController c;
  final String nodeId;
  final int? base;

  Document get doc => c.doc;

  /// Writes [plain] at [path], where the panel showed [shown] and the document now holds [live].
  void write(List<String> path, Value? shown, Value? live, Object? plain) {
    final shownPlain = plainOf(shown);
    if (_same(shownPlain, plain)) return; // not changed by this edit
    if (_same(plainOf(live), plain)) return; // already so
    if (plain == null) {
      if (live != null && live is! VNull) c.setConfig(nodeId, path, const VNull(), base: base);
      return;
    }
    if (live is VMap && plain is Map) return _writeMap(path, shown is VMap ? shown.entries : null, live, plain);
    if (live is VItems && plain is List) return _editItems(path, shown is VItems ? shown.items : null, live, plain);
    c.setConfig(nodeId, path, mergeValue(live, plain, doc), base: base);
  }

  void _writeMap(List<String> path, Map<String, Value>? shown, VMap live, Map<Object?, Object?> plain) {
    final s = shown ?? live.entries;
    bool present(Value? v) => v != null && v is! VNull;
    final removed = {
      for (final MapEntry(:key, :value) in live.entries.entries)
        if (present(value) && present(s[key]) && !plain.containsKey(key)) key,
    };
    final keys = {...live.entries.keys, for (final k in plain.keys) '$k'};
    if (removed.isEmpty) {
      for (final k in keys) {
        write([...path, k], s[k], live.entries[k], plain[k]);
      }
      return;
    }
    // A member taken away rewrites this map (only), keeping what others put there that this edit did not touch.
    final out = <String, Value>{};
    for (final k in keys) {
      if (removed.contains(k)) continue;
      final l = live.entries[k];
      if (!plain.containsKey(k) || _same(plainOf(s[k]), plain[k])) {
        if (l != null) out[k] = l;
      } else {
        out[k] = mergeValue(l, plain[k], doc);
      }
    }
    c.setConfig(nodeId, path, VMap(out), base: base);
  }

  /// Edits the keyed list at [path] from [live] to [next] with item ops. Items the panel did not show ([shown] lacks
  /// them: someone else's) are never removed, and elements of [next] that are shown items deleted since are not put
  /// back. When the elements carry ids (a prompt's `id`, a case's `case_id`) they are matched by them: removed ones go,
  /// the longest run already in order stays and is updated in place, the others are inserted where they now are (a
  /// moved one is taken out and put back as a new item: item ids are never reused). Otherwise the lists are compared
  /// by position (one look ahead for a single insert or removal).
  void _editItems(List<String> path, List<Item>? shown, VItems live, List<Object?> nextIn) {
    final shownById = shown == null ? null : {for (final i in shown) i.id: i};
    final liveIds = {for (final i in live.items) i.id};
    final foreign = [
      for (final i in live.items)
        if (shownById != null && !shownById.containsKey(i.id)) i,
    ];
    final gone = [
      for (final i in shown ?? const <Item>[])
        if (!liveIds.contains(i.id)) i,
    ];

    /// The panel's own version of a live item, when it showed it.
    Object? shownPlain(Item i) => shownById?[i.id] == null ? null : plainOf(shownById![i.id]!.value);
    bool untouched(Item i, Object? want) => shownById?[i.id] != null && _same(shownPlain(i), want);

    final next = [...nextIn];
    final keyed = _keyedMode(live.items, next);
    if (!keyed) {
      // Elements that are items the panel did not show are already there; shown items deleted since stay deleted.
      for (final pool in [foreign, gone]) {
        final left = [...pool];
        next.removeWhere((v) {
          final k = left.indexWhere((i) => _same(plainOf(i.value), v));
          if (k < 0) return false;
          left.removeAt(k);
          return true;
        });
      }
    } else {
      final goneIds = {for (final i in gone) _plainId(plainOf(i.value)) ?? i.id};
      next.removeWhere((v) => goneIds.contains(_plainId(v)));
    }
    final foreignIds = {for (final i in foreign) i.id};

    void update(Item item, Object? want) {
      if (_same(plainOf(item.value), want) || untouched(item, want)) return;
      c.updateItem(nodeId, path, item.id, mergeValue(item.value, want, doc), base: base);
    }

    void remove(Item item) {
      if (!foreignIds.contains(item.id)) c.removeItem(nodeId, path, item.id);
    }

    if (keyed) {
      final byId = <String, Item>{for (final i in live.items) _plainId(plainOf(i.value)) ?? i.id: i};
      return _reorder(path, byId, [for (final v in next) _plainId(v)!], next, foreignIds, update);
    }

    final items = [
      for (final i in live.items)
        if (!foreignIds.contains(i.id)) i,
    ];
    if (_permutation(items, next) case final order?) {
      // A pure reorder: the longest run already in order stays, the others are moved.
      return _reorder(
        path,
        {for (final i in items) i.id: i},
        [for (final k in order) items[k].id],
        next,
        foreignIds,
        update,
      );
    }
    var i = 0;
    String? last; // the item new ones go after (null: the front)
    final pending = <Value>[];
    void flush() {
      for (final v in pending) {
        last = c.insertItem(nodeId, path, v, after: last);
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
        remove(items[i]);
        last = items[i + 1].id;
        i += 2;
      } else if (i < items.length && !(j + 1 < next.length && same(i, next[j + 1]))) {
        flush();
        update(items[i], want);
        last = items[i++].id;
      } else {
        pending.add(mergeValue(null, want, doc));
      }
    }
    flush();
    for (; i < items.length; i++) {
      remove(items[i]);
    }
  }

  /// Puts the items of [byId] (by key) in the order of [ids], the keys of [next]'s elements: items whose key is gone
  /// are removed (unless someone else's: [foreignIds]), the longest run already in order stays and is updated in
  /// place, the others are inserted where they now are (a moved one is taken out and put back as a new item: the
  /// protocol has no move, and item ids are never reused).
  void _reorder(
    List<String> path,
    Map<String, Item> byId,
    List<String> ids,
    List<Object?> next,
    Set<String> foreignIds,
    void Function(Item item, Object? want) update,
  ) {
    final wanted = ids.toSet();
    final kept = [
      for (final e in byId.entries)
        if (wanted.contains(e.key)) e.key,
    ];
    final stay = _lcs(kept, [
      for (final id in ids)
        if (byId.containsKey(id)) id,
    ]).toSet();
    for (final e in byId.entries) {
      if (!stay.contains(e.key) && (wanted.contains(e.key) || !foreignIds.contains(e.value.id))) {
        // Moved (taken out to be put back) or removed; someone else's items stay.
        c.removeItem(nodeId, path, e.value.id);
      }
    }
    String? last;
    for (final (j, id) in ids.indexed) {
      final want = next[j];
      final item = byId[id];
      if (item != null && stay.contains(id)) {
        update(item, want);
        last = item.id;
      } else {
        last = c.insertItem(nodeId, path, mergeValue(item?.value, want, doc), after: last);
      }
    }
  }
}

/// The positions of [items] in the order of [next] when [next] is a reordering of their values (not the same
/// order), else null.
List<int>? _permutation(List<Item> items, List<Object?> next) {
  if (items.length != next.length || items.length < 2) return null;
  final plain = [for (final i in items) plainOf(i.value)];
  final used = <int>{};
  final order = <int>[];
  for (final v in next) {
    var k = -1;
    for (var i = 0; i < plain.length; i++) {
      if (!used.contains(i) && _same(plain[i], v)) {
        k = i;
        break;
      }
    }
    if (k < 0) return null;
    used.add(k);
    order.add(k);
  }
  for (var i = 0; i < order.length; i++) {
    if (order[i] != i) return order;
  }
  return null;
}

/// Whether [items] and [next] are matched by the ids their elements carry: every element of [next] has a distinct
/// one, every item a distinct key (its element's id, else its item id), and some element names an item.
bool _keyedMode(List<Item> items, List<Object?> next) {
  final ids = [for (final v in next) _plainId(v)];
  if (ids.any((id) => id == null) || ids.toSet().length != ids.length) return false;
  final keys = {for (final i in items) _plainId(plainOf(i.value)) ?? i.id};
  return keys.length == items.length && ids.any(keys.contains);
}

/// The id a keyed-list element carries in Dify's data (a prompt's `id`, an if-else case's `case_id`). Not
/// `variable`: a variable is renamed in place.
String? _plainId(Object? v) => switch (v) {
  {'id': final String id} when id.isNotEmpty => id,
  {'case_id': final String id} when id.isNotEmpty => id,
  _ => null,
};

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

// ---- values ------------------------------------------------------------------------------------------------------

/// Dify's plain JSON [plain] as a config [Value] over [orig]: unchanged parts keep their form (references, live or
/// broken; keyed-list item ids); a new `[node, output]` pair naming an output of a node in [doc] becomes a reference.
Value mergeValue(Value? orig, Object? plain, Document doc) {
  if (orig != null && _same(plainOf(orig), plain) && (plain != null || orig is VNull)) return orig;
  switch ((orig, plain)) {
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
  if (plain is num) return Value.number(plain);
  return Value.of(plain);
}

/// A value selector as the document stores it: a reference when it names an output of a node in [doc] (any output
/// when the node declares none), else the plain list (sys / env / conversation / rag variables, deeper paths).
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

/// Writes [next] (a document [Node] with an updated config, e.g. from `updateNodeVars`) over [orig] with the fewest
/// ops: nested map members by path, keyed-list items by id when the list keeps its items in order.
void writeNodeConfig(EditorController c, Node orig, Node next, {int? base}) {
  void write(List<String> path, Value? o, Value n) {
    if (o == n) return;
    if (o is VMap && n is VMap && o.entries.keys.every(n.entries.containsKey)) {
      for (final MapEntry(:key, :value) in n.entries.entries) {
        write([...path, key], o.entries[key], value);
      }
      return;
    }
    if (o is VItems && n is VItems && o.items.length == n.items.length) {
      final sameIds = [for (var i = 0; i < o.items.length; i++) o.items[i].id == n.items[i].id].every((x) => x);
      if (sameIds) {
        for (final (i, item) in n.items.indexed) {
          if (item.value != o.items[i].value) c.updateItem(orig.id, path, item.id, item.value, base: base);
        }
        return;
      }
    }
    c.setConfig(orig.id, path, n, base: base);
  }

  for (final MapEntry(:key, :value) in next.config.entries) {
    write([key], orig.config[key], value);
  }
}

// ---- useNodeCrud over the live data ------------------------------------------------------------------------------

/// Dify's `useNodeCrud` for one node, reading the data live (like `inputsRef.current`): [inputs] is the node's data
/// as it is now, [setInputs] writes a whole new data computed from it.
class PanelInputs {
  PanelInputs(this.props);
  final NodePanelProps props;

  EditorController get _c => props.controller;
  Node get node => _c.doc.nodes[props.id] ?? props.node;
  Json get inputs => difyDataOf(node);

  /// Writes [next] (computed from [inputs]); nothing while the panel is read-only. When only [textKey] changed, the
  /// edit is typed text, based on [textBase] (the version its typing began on); else on [base].
  void setInputs(Json next, {int? base, String? textKey, int Function()? textBase}) {
    if (props.readOnly) return;
    var b = base;
    if (textKey != null && textBase != null) {
      final now = inputs;
      final changed = [
        for (final k in {...now.keys, ...next.keys})
          if (!_same(now[k], next[k])) k,
      ];
      if (changed.length == 1 && changed.single == textKey) b = textBase();
    }
    writeInputs(_c, props.id, next, base: b);
  }

  /// Sets one top-level key (typed text passes [base]).
  void set(String key, Object? value, {int? base}) {
    if (props.readOnly) return;
    writeInputs(_c, props.id, {...inputs, key: value}, base: base);
  }
}

// ---- the variables on offer --------------------------------------------------------------------------------------

/// What a node's pickers and prompt editors work on (useAvailableVarList): the upstream nodes in the same branch and
/// the iteration / loop the node sits in ([beforeNodes] includes it, as Dify's
/// `getBeforeNodesInSameBranchIncludeParent`), as a [VarScope] with the environment, (in a chatflow) conversation and
/// (in a pipeline) rag variables, and as the prompt editor's nodes map.
class NodeVars {
  NodeVars._(this.scope, this.beforeNodes, this.parent, this._doc);

  /// The scope of [props]' node in its document, with the store's environment and conversation variables (unless
  /// [environment] / [conversation] are off) and [ragVariables]. Built once per [props] with the default options.
  factory NodeVars.of(
    NodePanelProps props, {
    List<RagVariable> ragVariables = const [],
    bool environment = true,
    bool conversation = true,
  }) {
    final doc = props.controller.doc;
    final plain = ragVariables.isEmpty && environment && conversation;
    // The shell makes new props on each build; props kept longer see a new scope once their node changed.
    final fresh = identical(doc.nodes[props.id], props.node);
    if (plain && fresh) {
      if (_cache[props] case final v?) return v;
    }
    List<Node> before;
    try {
      final g = difyGraphOf(doc);
      before = [for (final b in getBeforeNodesInSameBranchIncludeParent(props.id, g.nodes, g.edges)) ?b.node];
    } on StateError {
      before = const [];
    }
    final parentId = parentIdOf(props.node);
    final parent = parentId == null ? null : doc.nodes[parentId];
    final v = NodeVars._(
      scopeOver(
        props,
        before,
        parent: parent,
        environment: environment,
        conversation: conversation,
        ragVariables: ragVariables,
      ),
      before,
      parent,
      doc,
    );
    if (plain && fresh) _cache[props] = v;
    return v;
  }

  static final _cache = Expando<NodeVars>('NodeVars');

  /// The scope over [nodes] (Dify's `passedInAvailableNodes` / `toNodeOutputVars(nodes, …)`) seen from inside
  /// [parent]; empty where Dify's code would throw on the data.
  static VarScope scopeOver(
    NodePanelProps props,
    List<Node> nodes, {
    Node? parent,
    bool environment = true,
    bool conversation = true,
    List<RagVariable> ragVariables = const [],
  }) {
    final store = props.actions.store;
    try {
      return VarScope.of(
        beforeNodes: nodes,
        parent: parent,
        chatMode: props.chatMode,
        environmentVariables: environment ? DeclaredVar.listOf(store.environmentVariables.value) : const [],
        conversationVariables: conversation && props.chatMode
            ? DeclaredVar.listOf(store.conversationVariables.value)
            : const [],
        ragVariables: ragVariables,
        currentIterationTitle: DifyI18n.tr('workflow', 'nodes.iteration.currentIteration'),
      );
    } on Object {
      return const VarScope();
    }
  }

  final VarScope scope;

  /// The upstream nodes in the same branch, the container ([parent]) included.
  final List<Node> beforeNodes;
  final Node? parent;
  final Document _doc;

  /// The prompt editors' `availableNodes` map (titles and types; `sys` as the Start node): [beforeNodes], the
  /// container and the Start nodes.
  late final Map<String, WorkflowNodeInfo> nodesMap = workflowNodesMapOf([
    ...beforeNodes,
    ?parent,
    ..._doc.nodes.values.where((n) => n.type == 'start'),
  ]);

  /// The variables [filter] accepts (Dify's `filterVar` option of useAvailableVarList).
  VarScope filtered(VarFilter filter) => scope.filtered(filter);
}
