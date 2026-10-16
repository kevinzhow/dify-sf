import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import 'world.dart';

/// Fault profiles, as in the reference simulator.
enum Profile { calm, lossy, flaky, crashy, chaos }

class SimStats {
  int runs = 0;
  int edits = 0;
  int localInvalid = 0;
  int committed = 0;
  int rejected = 0;
  int lost = 0;
  int warnings = 0;
  int reapplied = 0;
  int crashes = 0;
  int partitions = 0;
  int snapshots = 0;
  int replays = 0;
  final Map<String, int> rejectedBy = {};

  void add(SimStats o) {
    runs += o.runs;
    edits += o.edits;
    localInvalid += o.localInvalid;
    committed += o.committed;
    rejected += o.rejected;
    lost += o.lost;
    warnings += o.warnings;
    reapplied += o.reapplied;
    crashes += o.crashes;
    partitions += o.partitions;
    snapshots += o.snapshots;
    replays += o.replays;
    o.rejectedBy.forEach((k, v) => rejectedBy[k] = (rejectedBy[k] ?? 0) + v);
  }

  @override
  String toString() => 'runs=$runs edits=$edits localInvalid=$localInvalid committed=$committed rejected=$rejected '
      '$rejectedBy lost=$lost earlyWarnings=$warnings reapplied=$reapplied crashes=$crashes '
      'partitions=$partitions snapshotJoins=$snapshots replays=$replays';
}

/// Runs one seeded simulation and checks the invariants. Throws (with the seed in the message) on violation.
SimStats runSim(int seed, Profile profile, {int? steps}) {
  final stats = SimStats()..runs = 1;
  try {
    fakeAsync((async) => _run(async, seed, profile, steps, stats));
  } on Object catch (e, st) {
    throw StateError('simulation failed: seed=$seed profile=${profile.name}\n$e\n$st');
  }
  return stats;
}

void _run(FakeAsync async, int seed, Profile profile, int? stepsOverride, SimStats stats) {
  final rng = Random(seed * 7919 + profile.index);
  final nodes = 2 + rng.nextInt(5);
  final initial = Document(
    nodes: [for (var i = 0; i < nodes; i++) Node(id: 'n$i', type: 'llm', title: 'node $i', x: i * 100)],
    edges: [if (nodes > 2) const Edge(id: 'e0', source: 'n0', target: 'n1')],
  );
  final w = World(async, initial: initial, maxReplay: 6 + rng.nextInt(120));
  final clientCount = 2 + rng.nextInt(4);
  final ps = [
    for (var i = 0; i < clientCount; i++)
      w.add('c$i', journaled: rng.nextDouble() > 0.4, seed: seed * 31 + i),
  ];
  for (final p in ps) {
    p.store.latency = () => Duration(milliseconds: rng.nextInt(40));
  }
  w.settle();

  final steps = stepsOverride ?? 150 + rng.nextInt(300);
  final lossy = profile == Profile.lossy || profile == Profile.chaos;
  final flaky = profile == Profile.flaky || profile == Profile.chaos;
  final crashy = profile == Profile.crashy || profile == Profile.chaos;
  if (lossy || crashy) {
    for (final p in ps) {
      p.net
        ..dropRequest = lossy ? rng.nextDouble() * 0.25 : 0
        ..dropResponse = lossy ? rng.nextDouble() * 0.25 : 0
        ..holeRate = lossy ? rng.nextDouble() * 0.05 : 0
        ..serverError = crashy ? rng.nextDouble() * 0.1 : 0
        ..maxLatency = Duration(milliseconds: 20 + rng.nextInt(600));
    }
  }

  var fresh = 0;
  final seen = {for (final p in ps) p.id: 0};
  final offlineUntil = {for (final p in ps) p.id: Duration.zero};
  final downUntil = {for (final p in ps) p.id: Duration.zero};

  Op? randomEdit(Participant p) {
    final v = p.session.view;
    final ids = v.nodes.keys.toList()..sort();
    if (ids.isEmpty) return null;
    String pick(List<String> xs) => xs[rng.nextInt(xs.length)];
    final r = rng.nextInt(100);
    final n = pick(ids);
    final node = v.nodes[n]!;
    if (r < 25) return MoveNode(n, rng.nextInt(2000), rng.nextInt(2000));
    if (r < 45) return SetField(n, const ConfigKey(['prompt']), VString(pick(['x', 'y', 'z'])));
    if (r < 50) return SetField(n, const TitleKey(), VString(pick(['t1', 't2', 't3'])));
    if (r < 56) return SetField(n, ConfigKey(['model', pick(['name', 'temp'])]), VString(pick(['m1', 'm2'])));
    if (r < 60) return SetField(n, const ConfigKey(['model']), VString(pick(['m1', 'm2'])));
    final items = node.config['outs'] is VItems ? (node.config['outs']! as VItems).items : const <Item>[];
    if (r < 68) {
      final after = items.isEmpty || rng.nextBool() ? null : pick([for (final i in items) i.id]);
      return InsertItem(n, const ['outs'], Item('i${fresh++}', VString(pick(['a', 'b']))), after);
    }
    if (r < 73 && items.isNotEmpty) {
      return UpdateItem(n, const ['outs'], pick([for (final i in items) i.id]), VString(pick(['a', 'b', 'c'])));
    }
    if (r < 76 && items.isNotEmpty) return RemoveItem(n, const ['outs'], pick([for (final i in items) i.id]));
    if (r < 80) {
      return AddNode(Node(id: 'x${fresh++}', type: 'code', title: 'new', x: rng.nextInt(500), y: rng.nextInt(500)));
    }
    if (r < 82 && ids.length > 1) return RemoveNode(n);
    if (r < 88 && ids.length > 1) {
      return AddEdge(Edge(id: 'ed${fresh++}', source: n, target: pick(ids), sourceHandle: pick(['out', 'out2'])));
    }
    if (r < 91 && v.edges.isNotEmpty) return RemoveEdge(pick(v.edges.keys.toList()..sort()));
    if (r < 96) return SetField(n, ConfigKey(['in', pick(['p', 'q'])]), VRef(OutputRef(pick(ids), 'o')));
    return SetField(n, const ConfigKey(['prompt']), VString(pick(['x', 'y'])));
  }

  for (var step = 0; step < steps; step++) {
    w.elapse(Duration(milliseconds: rng.nextInt(400)));
    final now = async.elapsed;
    for (final p in ps) {
      // Per-participant fault lifecycle.
      if (flaky) {
        if (p.net.partitioned && now >= offlineUntil[p.id]!) {
          p.net.partitioned = false;
          if (p.running && rng.nextBool()) p.session.networkAvailable(); // the OS connectivity hint
        } else if (!p.net.partitioned && rng.nextDouble() < 0.03) {
          p.net.partitioned = true;
          stats.partitions++;
          final long = rng.nextDouble() < 0.2;
          offlineUntil[p.id] = now + Duration(seconds: long ? 60 + rng.nextInt(150) : 1 + rng.nextInt(15));
        }
        if (rng.nextDouble() < 0.02) p.net.cutStreams();
      }
      if (crashy) {
        if (!p.running && now >= downUntil[p.id]!) p.start();
        if (p.running && rng.nextDouble() < 0.02) {
          p.crash();
          stats.crashes++;
          downUntil[p.id] = now + Duration(milliseconds: rng.nextInt(5000));
          if (rng.nextBool()) {
            // sometimes the process comes back at once, before anything else happens
            p.start();
          }
        }
        if (rng.nextDouble() < 0.01) {
          p.net.refused = !p.net.refused;
        }
      }
      // React to what the user was told.
      final evs = p.events;
      for (; seen[p.id]! < evs.length; seen[p.id] = seen[p.id]! + 1) {
        final e = evs[seen[p.id]!];
        if (e is OpRejected && e.reason is Conflict && p.running && rng.nextDouble() < 0.6) {
          p.edit(e.op);
          stats.reapplied++;
        }
      }
      if (p.running && rng.nextDouble() < 0.35) {
        final burst = rng.nextDouble() < 0.1 ? 2 + rng.nextInt(4) : 1;
        for (var i = 0; i < burst; i++) {
          final op = randomEdit(p);
          if (op == null) continue;
          stats.edits++;
          if (p.edit(op) == null) stats.localInvalid++;
        }
      }
    }
  }

  // Quiesce: heal everything, bring everyone back, wait for convergence.
  for (final p in ps) {
    p.heal();
    p.net.maxLatency = const Duration(milliseconds: 50);
    if (!p.running) p.start();
  }
  w.settle(limit: const Duration(minutes: 30));
  _check(w, ps, stats);
}

void _check(World w, List<Participant> ps, SimStats stats) {
  final server = w.server;
  expect(server.doc.integrityProblems, isEmpty, reason: 'I4: no dangling references on the server');

  // I3: convergence, including version metadata.
  for (final p in ps) {
    final s = p.session;
    expect(s.lastSeq, server.head, reason: '${p.id} lastSeq');
    expect(s.confirmed, server.doc, reason: '${p.id} confirmed != server (I3)');
    expect(s.view, server.doc, reason: '${p.id} view != server (I3)');
    expect(s.machine.violations, isEmpty, reason: '${p.id} protocol violations');
    expect(s.view.integrityProblems, isEmpty, reason: '${p.id} I4');
  }

  // Log hygiene: gapless seq, strictly increasing cseq per client.
  final lastCseq = <String, int>{};
  for (var i = 0; i < server.log.length; i++) {
    final e = server.log[i];
    expect(e.seq, i + 1);
    expect(e.cseq, greaterThan(lastCseq[e.client] ?? 0), reason: 'cseq must increase per client');
    lastCseq[e.client] = e.cseq;
  }

  final byKey = {for (final e in server.log) (e.client, e.cseq): e};
  for (final p in ps) {
    // Exactly one fate per op (identical repeats are allowed: reporting is at-least-once across crashes).
    final fates = <int, Object>{};
    void fate(int cseq, Object f, String what) {
      final prev = fates[cseq];
      expect(prev == null || prev == f, isTrue, reason: '${p.id} cseq $cseq reported twice with different fates: $prev vs $what');
      fates[cseq] = f;
    }

    for (final e in p.events) {
      switch (e) {
        case OpCommitted(:final cseq, :final seq, :final op):
          fate(cseq, 'committed@$seq', 'committed@$seq');
          final entry = byKey[(p.id, cseq)];
          expect(entry, isNotNull, reason: '${p.id}/$cseq told committed but not in the log (I5)');
          expect(entry!.seq, seq, reason: '${p.id}/$cseq committed seq');
          if (op != null) expect(entry.op, op, reason: '${p.id}/$cseq committed op differs from what the user did');
          stats.committed++;
        case OpRejected(:final cseq, :final op, :final reason):
          fate(cseq, 'rejected', 'rejected $reason');
          expect(byKey.containsKey((p.id, cseq)), isFalse, reason: '${p.id}/$cseq told rejected ($reason) but it is in the log: $op');
          stats.rejected++;
          stats.rejectedBy[reason.name] = (stats.rejectedBy[reason.name] ?? 0) + 1;
        case OpLost(:final cseq):
          fate(cseq, 'lost', 'lost');
          expect(p.journaled, isFalse, reason: '${p.id} journaled client reported a lost op');
          expect(byKey.containsKey((p.id, cseq)), isFalse, reason: '${p.id}/$cseq told lost but it is in the log (I5)');
          stats.lost++;
        case ConflictDetected():
          stats.warnings++;
        case LocalInvalid():
          break;
      }
    }
    // Everything the server has from this client, the client knows is saved.
    for (final e in server.log.where((e) => e.client == p.id)) {
      expect(fates[e.cseq], 'committed@${e.seq}', reason: '${p.id}/${e.cseq} is in the log but the client never reported it saved (I5)');
    }
    // Every edit the user was promised an outcome for got one.
    for (final cseq in p.promised.keys) {
      expect(fates.containsKey(cseq), isTrue, reason: '${p.id}/$cseq was promised but has no outcome');
      final entry = byKey[(p.id, cseq)];
      if (entry != null) expect(entry.op, p.promised[cseq], reason: '${p.id}/$cseq committed a different op than promised');
    }
  }
  stats.snapshots += server.snapshotsServed;
  stats.replays += server.replaysServed;
}
