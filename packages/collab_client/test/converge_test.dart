/// Convergence: many clients on very different networks build one planned workflow, fight over the same fields, and
/// the document they end with is exactly the plan (the small, always-run version of `build_demo --latency mix
/// --target`, against the self-hosted protocol server).
@TestOn('vm')
@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/storm.dart';
import 'package:collab_client/testing_io.dart';
import 'package:test/test.dart';

/// A plan like `make_plan.py --converge`, small: [lanes] chains of [perLane] nodes with links across lanes, one owner
/// per node; owners add, drag and connect their nodes; everyone reviews and nudges other people's nodes and, in
/// [bursts], writes the same field of the same node at the same moment; at [finalMs] the owners write the final
/// positions and descriptions. Returns the clients' steps and the target document.
({List<List<Map<String, Object?>>> steps, Map<String, Object?> target}) plan({
  required int clients,
  int lanes = 4,
  int perLane = 6,
  int finalMs = 13000,
  int seed = 3,
}) {
  final rnd = Random(seed);
  final contestEnd = finalMs - 4000;
  final nodes = <String, Map<String, Object?>>{};
  final edges = <String, Map<String, Object?>>{};
  final order = <String>[];
  for (var l = 0; l < lanes; l++) {
    for (var k = 0; k < perLane; k++) {
      final id = 'n$l-$k';
      order.add(id);
      nodes[id] = {'type': 'code', 'title': 'Step $l.$k', 'x': 200 + k * 300, 'y': l * 160};
      if (k > 0) {
        edges['e-n$l-${k - 1}-$id'] = {'source': 'n$l-${k - 1}', 'target': id};
      }
      if (l > 0 && k > 0 && k.isEven) {
        edges['e-x-n${l - 1}-${k - 1}-$id'] = {'source': 'n${l - 1}-${k - 1}', 'target': id};
      }
    }
  }
  String ownerName(int i) => 'c$i';
  final owner = {for (final (i, id) in order.indexed) id: i % clients};
  String desc(String id) => '${nodes[id]!['title']}: kept by ${ownerName(owner[id]!)}';
  Map<String, Object?> op(Map<String, Object?> o, {bool fin = false, bool contested = false}) => {
    'op': o,
    if (fin) 'final': true,
    if (contested) 'deadline_ms': contestEnd,
  };
  Map<String, Object?> setDesc(String id, String value) => {
    't': 'setField',
    'node': id,
    'field': {
      'k': 'config',
      'path': ['desc'],
    },
    'value': value,
  };
  final hot = [order[3], order[order.length ~/ 2], order.last];
  final steps = <List<Map<String, Object?>>>[];
  for (var i = 0; i < clients; i++) {
    final s = <Map<String, Object?>>[];
    for (final id in order.where((id) => owner[id] == i)) {
      final n = nodes[id]!;
      final deps = [
        for (final e in edges.values)
          if (e['target'] == id) e['source']! as String,
      ];
      s.add({'wait': deps});
      s.add(
        op({
          't': 'addNode',
          'node': {
            'id': id,
            'type': 'code',
            'title': n['title'],
            'x': 0,
            'y': 0,
            'config': {'desc': ''},
          },
        }),
      );
      for (var k = 1; k <= 3; k++) {
        s.add(op({'t': 'moveNode', 'node': id, 'x': (n['x']! as int) * k ~/ 3, 'y': (n['y']! as int) * k ~/ 3}));
      }
      for (final MapEntry(key: eid, value: e) in edges.entries) {
        if (e['target'] == id) {
          s.add(
            op({
              't': 'addEdge',
              'edge': {
                'id': eid,
                'source': e['source'],
                'sourceHandle': 'source',
                'target': id,
                'targetHandle': 'target',
              },
            }),
          );
        }
      }
    }
    for (var r = 0; r < 3; r++) {
      final target = order[rnd.nextInt(order.length)];
      final t = nodes[target]!;
      s
        ..add({'sleep_ms': 200 + rnd.nextInt(400)})
        ..add({
          'wait': [target],
        })
        ..add(op(setDesc(target, 'Reviewed by ${ownerName(i)}'), contested: true))
        ..add(
          op({
            't': 'moveNode',
            'node': target,
            'x': (t['x']! as int) + rnd.nextInt(80) - 40,
            'y': (t['y']! as int) + rnd.nextInt(60) - 30,
          }, contested: true),
        );
    }
    for (final (j, id) in hot.indexed) {
      s
        ..add({'at_ms': contestEnd - 3000 + j * 1000 + rnd.nextInt(60)})
        ..add(op(setDesc(id, '${ownerName(i)} was here (${j + 1})'), contested: true));
    }
    final mine = order.where((id) => owner[id] == i).toList();
    if (mine.isNotEmpty) {
      s.add({'at_ms': finalMs + rnd.nextInt(400)});
      for (final id in mine) {
        final n = nodes[id]!;
        s
          ..add(op({'t': 'moveNode', 'node': id, 'x': n['x'], 'y': n['y']}, fin: true))
          ..add(op(setDesc(id, desc(id)), fin: true));
      }
    }
    steps.add(s);
  }
  return (
    steps: steps,
    target: {
      'nodes': {
        for (final id in order)
          id: {
            'type': 'code',
            'title': nodes[id]!['title'],
            'x': nodes[id]!['x'],
            'y': nodes[id]!['y'],
            'desc': desc(id),
          },
      },
      'edges': {
        for (final MapEntry(key: id, value: e) in edges.entries)
          id: {'source': e['source'], 'sourceHandle': 'source', 'target': e['target'], 'targetHandle': 'target'},
      },
    },
  );
}

/// Networks for a short run: the same shapes as [LatencyProfile.mix], scaled down.
const _networks = [
  LatencyProfile(name: 'fibre', base: Duration(milliseconds: 5), jitter: Duration(milliseconds: 3)),
  LatencyProfile(name: 'home', base: Duration(milliseconds: 40), jitter: Duration(milliseconds: 20)),
  LatencyProfile(
    name: 'mobile',
    base: Duration(milliseconds: 120),
    jitter: Duration(milliseconds: 80),
    stallsPerMinute: 6,
    stall: Duration(milliseconds: 700),
  ),
  LatencyProfile(
    name: 'train',
    base: Duration(milliseconds: 300),
    jitter: Duration(milliseconds: 200),
    stallsPerMinute: 6,
    stall: Duration(milliseconds: 1500),
    dropsPerMinute: 8,
  ),
];

void main() {
  late HttpFakeServer srv;
  late Directory dir;

  setUp(() async {
    srv = await HttpFakeServer.start(pingInterval: const Duration(milliseconds: 300));
    dir = Directory.systemTemp.createTempSync('converge_test');
  });
  tearDown(() async {
    await srv.close();
    dir.deleteSync(recursive: true);
  });

  test('12 clients on fibre, wifi, mobile and a train end with exactly the planned workflow', () async {
    const clients = 12;
    final p = plan(clients: clients);
    final epoch = DateTime.now();
    final editors = <int, PlanEditor>{};
    final config = StormConfig(
      url: srv.url,
      doc: 'converge',
      template: 'empty',
      clients: clients,
      duration: const Duration(seconds: 17),
      ratePerClient: 8,
      seed: 9,
      journalDir: dir.path,
      volatileFraction: 0,
      reapplyRate: 0,
      settleTimeout: const Duration(seconds: 40),
      clientConfig: const ClientConfig(streamSilence: 2500, reconnectBase: 50, reconnectMax: 400),
      postTimeout: const Duration(seconds: 3),
      joinAfter: (i) => Duration(milliseconds: i * 250),
      wrapTransport: (i, t) => LatencyTransport(t, _networks[i % _networks.length], random: Random(i)),
      mustLand: (i, op) => editors[i]?.finals.contains(op) ?? false,
      editorFor: (i, id, rng) => (editors[i] = PlanEditor(p.steps[i], epoch: epoch)).next,
    );
    final report = await StormRunner(config).run();
    expect(report.violations, isEmpty);
    expect(report.counts['pending'], isNull);
    // The bursts made people lose conflicts (each one told: that is the ledger's "rejected").
    expect(report.counts['rejected'] ?? 0, greaterThan(5));
    // The template's own nodes (its Start) are part of the planned document as they are.
    final want = p.target['nodes']! as Map<String, Object?>;
    for (final n in Templates.empty().toJson()['nodes']! as List<Object?>) {
      final m = n! as Map<String, Object?>;
      want[m['id']! as String] = {
        'type': m['type'],
        'title': m['title'],
        'x': m['x'],
        'y': m['y'],
        'desc': ((m['config'] as Map?) ?? const {})['desc'] ?? '',
      };
    }
    final api = DocsApi(srv.url);
    final snap = await api.snapshot('converge');
    api.close();
    expect(targetMismatches(jsonDecode(jsonEncode(snap.doc.toJson())) as Map<String, Object?>, p.target), isEmpty);
  });
}
