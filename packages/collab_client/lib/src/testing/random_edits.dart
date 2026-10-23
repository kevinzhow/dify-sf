import 'dart:math';

import '../model/document.dart';
import '../model/ops.dart';
import '../model/value.dart';

/// Generates plausible random user edits against what a client currently sees (its view): drags, text
/// edits drawn from a tiny pool (so same-value writes happen), list edits, node/edge creation and deletion,
/// variable references, undo of its own deletes (protocol 1.6 `restoreNode`) and, with [appEdits], edits of the
/// document-level registers (protocol 1.7 `$app`: a variable list and a features map). Used by the randomized tests
/// and the headless storm CLI.
class RandomEditor {
  RandomEditor(this.rng, {required this.idPrefix, this.appEdits = false});

  final Random rng;

  /// Also edit the document-level registers (about one edit in ten).
  final bool appEdits;

  /// Prefix of every id this editor invents. Must be unique per (client, run): ids are never reused.
  final String idPrefix;
  int _fresh = 0;

  String _id(String kind) => '$idPrefix-$kind${_fresh++}';

  /// Nodes this editor deleted, as it saw them just before (with their edges): what an undo restores.
  final Map<String, ({Node node, List<Edge> edges})> _deleted = {};

  T _pick<T>(List<T> xs) => xs[rng.nextInt(xs.length)];

  /// The next edit, or null if the view is empty.
  Op? next(Document view) {
    final undoable = [
      for (final id in _deleted.keys.toList()..sort())
        if (!view.nodes.containsKey(id) && view.deletedNodes.containsKey(id)) id,
    ];
    if (undoable.isNotEmpty && rng.nextInt(100) < 6) {
      final d = _deleted.remove(_pick(undoable))!;
      return RestoreNode(d.node, d.edges);
    }
    if (appEdits && rng.nextInt(100) < 10) return _appEdit(view);
    final ids = view.nodes.keys.toList()..sort();
    if (ids.isEmpty) return null;
    final r = rng.nextInt(100);
    final n = _pick(ids);
    final node = view.nodes[n]!;
    if (r < 25) return MoveNode(n, rng.nextInt(2000), rng.nextInt(2000));
    if (r < 45) return SetField(n, const ConfigKey(['prompt']), VString(_pick(['x', 'y', 'z'])));
    if (r < 50) return SetField(n, const TitleKey(), VString(_pick(['t1', 't2', 't3'])));
    if (r < 56) {
      return SetField(
        n,
        ConfigKey([
          'model',
          _pick(['name', 'temp']),
        ]),
        VString(_pick(['m1', 'm2'])),
      );
    }
    if (r < 60) return SetField(n, const ConfigKey(['model']), VString(_pick(['m1', 'm2'])));
    final outs = node.config['outs'];
    final items = outs is VItems ? outs.items : const <Item>[];
    if (r < 68) {
      final after = items.isEmpty || rng.nextBool() ? null : _pick([for (final i in items) i.id]);
      return InsertItem(n, const ['outs'], Item(_id('i'), VString(_pick(['a', 'b']))), after);
    }
    if (r < 73 && items.isNotEmpty) {
      return UpdateItem(n, const ['outs'], _pick([for (final i in items) i.id]), VString(_pick(['a', 'b', 'c'])));
    }
    if (r < 76 && items.isNotEmpty) return RemoveItem(n, const ['outs'], _pick([for (final i in items) i.id]));
    if (r < 80) {
      return AddNode(Node(id: _id('n'), type: 'code', title: 'new', x: rng.nextInt(500), y: rng.nextInt(500)));
    }
    if (r < 82 && ids.length > 1) {
      _deleted[n] = (
        node: node,
        edges: [
          for (final e in view.edges.values)
            if (e.source == n || e.target == n) e,
        ]..sort((a, b) => a.id.compareTo(b.id)),
      );
      return RemoveNode(n);
    }
    if (r < 88 && ids.length > 1) {
      return AddEdge(Edge(id: _id('e'), source: n, target: _pick(ids), sourceHandle: _pick(['out', 'out2'])));
    }
    if (r < 91 && view.edges.isNotEmpty) return RemoveEdge(_pick(view.edges.keys.toList()..sort()));
    if (r < 96) {
      return SetField(
        n,
        ConfigKey([
          'in',
          _pick(['p', 'q']),
        ]),
        VRef(OutputRef(_pick(ids), 'o')),
      );
    }
    return SetField(n, const ConfigKey(['prompt']), VString(_pick(['x', 'y'])));
  }

  /// An edit of `$app`: variables inserted, updated (from a tiny pool, so same-value writes happen) and removed, feature
  /// members and the whole features map written.
  Op _appEdit(Document view) {
    const app = Document.appNode;
    const path = ['vars'];
    final vars = switch (view.app['vars']) {
      VItems(:final items) => items,
      _ => const <Item>[],
    };
    VMap variable(String id) => VMap({
      'id': VString(id),
      'value': VString(_pick(['a', 'b', 'c'])),
    });
    final r = rng.nextInt(100);
    if (r < 35 || vars.isEmpty) {
      final id = _id('v');
      final after = vars.isEmpty || rng.nextBool() ? null : _pick([for (final i in vars) i.id]);
      return InsertItem(app, path, Item(id, variable(id)), after);
    }
    final v = _pick([for (final i in vars) i.id]);
    if (r < 65) return UpdateItem(app, path, v, variable(v));
    if (r < 75) return RemoveItem(app, path, v);
    final member = _pick(['p', 'q']), text = _pick(['x', 'y']);
    if (r < 93) return SetField(app, ConfigKey(['features', member]), VString(text));
    return SetField(app, const ConfigKey(['features']), VMap({member: VString(text)}));
  }
}
