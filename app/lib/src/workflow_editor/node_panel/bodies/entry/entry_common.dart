/// What the entry-node panels (triggers, start placeholder, knowledge pipeline) share: Dify's `setInputs` of
/// `useNodeCrud` as one small op per changed top-level key, and selectors written as references.
library;

import 'package:collab_client/collab_client.dart';

import '../../../../workflow/dify_json.dart';
import '../../node_panel_bodies.dart';

/// Keys of Dify's `data` that are not settings: the shell or React Flow owns them.
const _notSettings = {'type', 'title', 'selected', '_dify_node'};

/// Dify's `setInputs(next)` (useNodeCrud): writes the top-level keys of [next] that differ from the node's data now,
/// one op each; a key [next] lacks or sets to null is cleared. Unchanged references and keyed-list item ids are kept;
/// a keyed list (VItems) is edited item by item so concurrent edits of other items merge. Typed text passes the
/// version its draft began on as [base].
void setInputs(NodePanelProps props, Map<String, Object?> next, {int? base}) {
  final node = props.node;
  final doc = props.controller.doc;
  final keys = {...node.config.keys, ...next.keys}.where((k) => !_notSettings.contains(k));
  for (final key in keys) {
    final orig = node.config[key];
    final plain = next[key];
    if (jsonEquals(plainOf(orig), plain)) continue;
    if (plain == null) {
      if (orig != null && orig is! VNull) props.setData(key, null);
      continue;
    }
    if (orig is VItems && plain is List) {
      _editItems(props, [key], orig, plain, doc, base);
      continue;
    }
    props.setData(key, mergeValue(orig, plain, doc), base: base);
  }
}

/// [plain] as a config [Value] over [orig]: unchanged parts keep their form (references, keyed-list ids), new
/// two-part selectors to an existing node's output become references (see [selectorValue]).
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
      return VMap({
        for (final e in m.entries)
          if (e.value != null || entries.containsKey(e.key)) '${e.key}': mergeValue(entries['${e.key}'], e.value, doc),
      });
  }
  if (plain is List && plain.length == 2 && plain.every((e) => e is String)) {
    return selectorValue([for (final e in plain) e as String], doc);
  }
  if (plain is List) return VList([for (final e in plain) mergeValue(null, e, doc)]);
  if (plain is Map) {
    return VMap({
      for (final e in plain.entries)
        if (e.value != null) '${e.key}': mergeValue(null, e.value, doc),
    });
  }
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

/// Edits the keyed list at [path] from [orig] to [next] with item ops: items equal on both sides stay, a removed or
/// inserted item is found by looking one ahead, everything else is an update in place.
void _editItems(NodePanelProps props, List<String> path, VItems orig, List<Object?> next, Document doc, int? base) {
  final c = props.controller;
  final items = orig.items;
  var i = 0;
  String? last; // the item new ones go after (null: the front)
  final pending = <Value>[];
  void flush() {
    // Each insert goes right after [last], so a run of them is inserted last first.
    for (final v in pending.reversed) {
      c.insertItem(props.id, path, v, after: last);
    }
    pending.clear();
  }

  for (var j = 0; j < next.length; j++) {
    final want = next[j];
    bool same(int k, Object? v) => k < items.length && jsonEquals(plainOf(items[k].value), v);
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
