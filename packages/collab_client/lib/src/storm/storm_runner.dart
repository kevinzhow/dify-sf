import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../client/events.dart';
import '../client/machine.dart';
import '../client/session.dart';
import '../client/store.dart';
import '../model/ops.dart';
import '../store/file_store.dart';
import '../testing/random_edits.dart';
import '../transport/docs_api.dart';
import '../transport/http_transport.dart';
import '../wire/messages.dart';
import 'ledger.dart';

/// Settings of one storm run.
class StormConfig {
  StormConfig({
    required this.url,
    required this.doc,
    this.clients = 5,
    this.duration = const Duration(seconds: 20),
    this.ratePerClient = 5,
    this.seed = 1,
    this.journalDir,
    this.volatileFraction = 0.3,
    this.crashesPerClientPerMinute = 0,
    this.template = 'example',
    this.settleTimeout = const Duration(seconds: 60),
    this.reapplyRate = 0.5,
    this.verifyLog = true,
    this.clientConfig = const ClientConfig(),
    this.postTimeout = const Duration(seconds: 10),
  });

  final Uri url;
  final String doc;
  final int clients;
  final Duration duration;

  /// Intended edits per second per client.
  final double ratePerClient;
  final int seed;

  /// Where journals live (one file per client). null = a fresh temp directory.
  final String? journalDir;

  /// Share of clients running in volatile mode (no write-ahead journal).
  final double volatileFraction;
  final double crashesPerClientPerMinute;
  final String template;
  final Duration settleTimeout;

  /// Chance that a user re-applies an edit that lost a conflict.
  final double reapplyRate;

  /// After the run, replay the server's log from seq 0 (when it still can) and check the ledger against it.
  final bool verifyLog;
  final ClientConfig clientConfig;
  final Duration postTimeout;
}

/// The result of a run: the ledger plus verdicts.
class StormReport {
  StormReport({
    required this.config,
    required this.ledger,
    required this.violations,
    required this.notes,
    required this.headAtEnd,
    required this.elapsed,
    required this.crashes,
    required this.clientModes,
  });

  final StormConfig config;
  final List<LedgerEntry> ledger;

  /// Broken guarantees. Empty = the run upheld all of them.
  final List<String> violations;
  final List<String> notes;
  final int headAtEnd;
  final Duration elapsed;
  final int crashes;
  final Map<String, bool> clientModes;

  bool get ok => violations.isEmpty;

  Map<String, int> get counts {
    final c = <String, int>{};
    for (final e in ledger) {
      c[e.status.name] = (c[e.status.name] ?? 0) + 1;
    }
    return c;
  }

  /// Intent -> committed latency percentiles in ms.
  Map<String, int> get latencyMs {
    final xs = [
      for (final e in ledger)
        if (e.status == LedgerStatus.committed && e.outcomeMs != null) e.outcomeMs! - e.intentMs,
    ]..sort();
    if (xs.isEmpty) return const {};
    int at(double q) => xs[min(xs.length - 1, (xs.length * q).floor())];
    return {'p50': at(0.5), 'p95': at(0.95), 'p99': at(0.99), 'max': xs.last};
  }

  Map<String, Object?> toJson() => {
    'meta': {
      'url': config.url.toString(),
      'doc': config.doc,
      'clients': config.clients,
      'durationMs': config.duration.inMilliseconds,
      'ratePerClient': config.ratePerClient,
      'seed': config.seed,
      'volatileFraction': config.volatileFraction,
      'crashesPerClientPerMinute': config.crashesPerClientPerMinute,
      'elapsedMs': elapsed.inMilliseconds,
    },
    'clients': {for (final e in clientModes.entries) e.key: e.value ? 'journaled' : 'volatile'},
    'summary': {
      'ok': ok,
      'head': headAtEnd,
      'intended': ledger.length,
      'counts': counts,
      'crashes': crashes,
      'latencyMs': latencyMs,
      'violations': violations,
      'notes': notes,
    },
    'ledger': [for (final e in ledger) e.toJson()],
  };
}

/// N independent clients, one process: each with its own session, transport, journal file and random
/// editor. Every intended edit goes into a ledger together with its eventual outcome, then the final state
/// is verified against the server (and, when possible, against its full log).
class StormRunner {
  StormRunner(this.config, {void Function(String)? log, this.onEditingDone}) : _log = log ?? ((_) {});

  /// Called when editing stops, before the run waits for everything to settle (e.g. to end fault injection).
  final void Function()? onEditingDone;

  final StormConfig config;
  final void Function(String) _log;
  final Stopwatch _clock = Stopwatch();
  final List<LedgerEntry> _ledger = [];
  final List<_StormClient> _clients = [];
  int _crashes = 0;

  int get _now => _clock.elapsedMilliseconds;

  Future<StormReport> run() async {
    _clock.start();
    final rng = Random(config.seed);
    final api = DocsApi(config.url);
    final info = await api.ensure(config.doc, template: config.template);
    _log('document ${info.id} at head ${info.head}');
    final auditor = config.verifyLog ? _LogAuditor(config.url, config.doc) : null;
    unawaited(auditor?.start());

    final dir = config.journalDir ?? Directory.systemTemp.createTempSync('collab_storm').path;
    final nonce = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    for (var i = 0; i < config.clients; i++) {
      final id = 's${config.seed}-$nonce-c$i';
      _clients.add(
        _StormClient(
          runner: this,
          id: id,
          journaled: rng.nextDouble() >= config.volatileFraction,
          store: FileStore('$dir/$id.json'),
          editor: RandomEditor(Random(rng.nextInt(1 << 31)), idPrefix: id),
          rng: Random(rng.nextInt(1 << 31)),
        ),
      );
    }
    for (final c in _clients) {
      await c.boot();
    }
    await Future.wait(_clients.map((c) => c.session!.settled().timeout(config.settleTimeout)));
    _log('${_clients.length} clients synced, storming for ${config.duration.inSeconds}s');

    const dt = Duration(milliseconds: 20);
    final end = _now + config.duration.inMilliseconds;
    var lastReport = _now;
    while (_now < end) {
      await Future<void>.delayed(dt);
      for (final c in _clients) {
        c.step(dt.inMilliseconds / 1000);
      }
      if (_now - lastReport >= 5000) {
        lastReport = _now;
        _log(
          't=${_now ~/ 1000}s intended=${_ledger.length} committed=${_count(LedgerStatus.committed)} '
          'rejected=${_count(LedgerStatus.rejected)} pending=${_clients.fold<int>(0, (a, c) => a + c.pending)}',
        );
      }
    }

    // Quiesce: everyone back up, wait until every op has an outcome.
    onEditingDone?.call();
    for (final c in _clients) {
      await c.ensureRunning();
    }
    final violations = <String>[];
    final notes = <String>[];
    try {
      await Future.wait(_clients.map((c) => c.session!.settled())).timeout(config.settleTimeout);
    } on TimeoutException {
      violations.add(
        'not settled within ${config.settleTimeout.inSeconds}s: '
        '${_clients.where((c) => c.pending > 0).map((c) => '${c.id} pending=${c.pending}').join(', ')}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 300)); // let the last events drain

    await _verify(api, auditor, violations, notes);
    final head = _clients.map((c) => c.session!.lastSeq).fold(0, max);
    for (final c in _clients) {
      await c.stop();
    }
    await auditor?.stop();
    api.close();
    return StormReport(
      config: config,
      ledger: _ledger,
      violations: violations,
      notes: notes,
      headAtEnd: head,
      elapsed: _clock.elapsed,
      crashes: _crashes,
      clientModes: {for (final c in _clients) c.id: c.journaled},
    );
  }

  int _count(LedgerStatus s) => _ledger.where((e) => e.status == s).length;

  // ---- verification ------------------------------------------------------------------------------

  Future<void> _verify(DocsApi api, _LogAuditor? auditor, List<String> violations, List<String> notes) async {
    // 1. Every ledger entry has a terminal outcome.
    for (final e in _ledger) {
      if (e.status == LedgerStatus.pending) {
        violations.add('${e.client}/${e.cseq} (${e.op}) has no outcome');
      }
    }
    // 2. Convergence with the server's snapshot (I3).
    final snap = await api.snapshot(config.doc);
    final server = jsonEncode(snap.doc.toJson());
    for (final c in _clients) {
      final s = c.session!;
      if (s.lastSeq != snap.seq) violations.add('${c.id} lastSeq ${s.lastSeq} != server head ${snap.seq}');
      if (jsonEncode(s.confirmed.toJson()) != server) {
        violations.add('${c.id} confirmed document differs from the server (I3)');
      }
      if (jsonEncode(s.view.toJson()) != server) {
        violations.add('${c.id} view differs from the server after settling (I3)');
      }
      if (s.machine.violations.isNotEmpty) violations.addAll(s.machine.violations.map((v) => '${c.id}: $v'));
    }
    final problems = snap.doc.integrityProblems;
    if (problems.isNotEmpty) violations.add('server document has integrity problems (I4): $problems');

    // 3. Ledger vs. the server's log (I1/I5): the auditor watched every commit of the run, live.
    if (auditor == null) return;
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (auditor.lastSeq < snap.seq && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (auditor.lastSeq < snap.seq) {
      notes.add('log verification skipped: the auditor stopped at seq ${auditor.lastSeq} of ${snap.seq}');
      return;
    }
    final log = auditor.log;
    final byKey = {for (final e in log) (e.client, e.cseq): e};
    for (final e in _ledger) {
      final entry = e.cseq == null ? null : byKey[(e.client, e.cseq!)];
      switch (e.status) {
        case LedgerStatus.committed:
          if (entry == null) {
            violations.add('${e.client}/${e.cseq} reported committed@${e.seq} but is not in the log (I1)');
          } else if (entry.seq != e.seq) {
            violations.add('${e.client}/${e.cseq} reported committed@${e.seq} but the log has it at ${entry.seq}');
          } else if (entry.op != e.op) {
            violations.add('${e.client}/${e.cseq} log entry differs from the edit the user made');
          }
        case LedgerStatus.rejected || LedgerStatus.lost:
          if (entry != null) {
            violations.add('${e.client}/${e.cseq} reported ${e.status.name} but is in the log at ${entry.seq} (I5)');
          }
        case LedgerStatus.unpersisted:
          // Never promised an outcome, so it must never have left the process (write-ahead rule).
          if (entry != null && entry.op == e.op) {
            violations.add(
              '${e.client}/${e.cseq} was not in the journal at the crash but reached the server (write-ahead)',
            );
          }
        case LedgerStatus.localInvalid || LedgerStatus.pending:
          break;
      }
    }
    final known = {
      for (final e in _ledger)
        if (e.cseq != null) (e.client, e.cseq!),
    };
    final mine = _clients.map((c) => c.id).toSet();
    for (final entry in log) {
      if (mine.contains(entry.client) && !known.contains((entry.client, entry.cseq))) {
        violations.add('log entry #${entry.seq} ${entry.client}/${entry.cseq} has no ledger entry');
      }
    }
    for (var i = 1; i < log.length; i++) {
      if (log[i].seq != log[i - 1].seq + 1) {
        violations.add('log has a gap or duplicate at seq ${log[i].seq}');
        break;
      }
    }
    notes.add('log verified: ${log.length} commits observed live (seq ${auditor.startSeq + 1}..${auditor.lastSeq})');
  }
}

/// A read-only observer that records every committed op of the run as it happens, reconnecting with
/// `Last-Event-ID` like any client. It is how the ledger is checked against the server's real log even when
/// the log is far longer than the server will replay.
class _LogAuditor {
  _LogAuditor(this.url, this.doc);

  final Uri url;
  final String doc;
  final List<LogEntry> log = [];
  int startSeq = 0;
  int lastSeq = 0;
  bool _stopped = false;
  bool _started = false;
  HttpTransport? _transport;

  Future<void> start() async {
    while (!_stopped) {
      final t = _transport = HttpTransport(baseUrl: url, docId: doc);
      try {
        await for (final e in t.openStream(StreamOpen(lastEventId: _started ? lastSeq : null))) {
          switch (e) {
            case SnapshotEvent(:final seq):
              if (!_started) {
                startSeq = lastSeq = seq;
                _started = true;
              } else {
                // Fell too far behind to be replayed: the observed log has a hole; the check will say so.
                lastSeq = seq;
              }
            case CommitEvent(:final entry):
              if (entry.seq == lastSeq + 1) {
                log.add(entry);
                lastSeq = entry.seq;
              }
            case ReadyEvent() || PingEvent():
              break;
          }
        }
      } on Object {
        // connection lost: resume below
      }
      t.close();
      if (!_stopped) await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> stop() async {
    _stopped = true;
    _transport?.close();
  }
}

class _StormClient {
  _StormClient({
    required this.runner,
    required this.id,
    required this.journaled,
    required this.store,
    required this.editor,
    required this.rng,
  });

  final StormRunner runner;
  final String id;
  final bool journaled;
  final DurableStore store;
  final RandomEditor editor;
  final Random rng;

  CollabSession? session;
  int incarnation = 0;
  int _downUntil = 0;

  /// The latest entry per cseq (cseqs outlive crashes: the counters are journaled).
  final Map<int, LedgerEntry> _byCseq = {};

  int get pending => session?.status.pending ?? 0;

  bool _booting = false;

  Future<void> boot() async {
    if (_booting) return;
    _booting = true;
    incarnation++;
    final s = CollabSession(
      clientId: id,
      transport: HttpTransport(baseUrl: runner.config.url, docId: runner.config.doc),
      store: store,
      journaled: journaled,
      config: runner.config.clientConfig,
      postTimeout: runner.config.postTimeout,
      random: Random(rng.nextInt(1 << 31)),
    );
    s.events.listen(_onEvent);
    await s.start();
    session = s;
    _booting = false;
  }

  Future<void> stop() async {
    await session?.stop();
    session = null;
  }

  Future<void> ensureRunning() async {
    while (_booting) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (session == null) await boot();
  }

  void step(double dtSeconds) {
    final now = runner._now;
    if (session == null) {
      if (now >= _downUntil && !_booting) unawaited(boot());
      return;
    }
    final cfg = runner.config;
    if (cfg.crashesPerClientPerMinute > 0 && rng.nextDouble() < cfg.crashesPerClientPerMinute / 60 * dtSeconds) {
      _crash(now);
      return;
    }
    if (!session!.hasState) return;
    if (rng.nextDouble() < cfg.ratePerClient * dtSeconds) _edit(editor.next(session!.view), null);
  }

  void _crash(int now) {
    runner._crashes++;
    final s = session!;
    session = null;
    // Edits whose journal write had not completed were never promised an outcome. (A write racing the crash
    // may still land; then the restarted client resolves the op and its event overwrites this status.)
    for (final e in _byCseq.values) {
      if (e.persistedMs == null && e.status == LedgerStatus.pending) e.status = LedgerStatus.unpersisted;
    }
    unawaited(s.stop());
    _downUntil = now + rng.nextInt(800);
    runner._log('$id crashed (${journaled ? 'journaled' : 'volatile'}), back in ${_downUntil - now}ms');
  }

  void _edit(Op? op, int? reapplies) {
    final s = session;
    if (op == null || s == null) return;
    final entry = LedgerEntry(
      client: id,
      incarnation: incarnation,
      op: op,
      intentMs: runner._now,
      reappliesCseq: reapplies,
    );
    runner._ledger.add(entry);
    final ticket = s.edit(op);
    if (ticket.cseq == null) {
      entry
        ..status = LedgerStatus.localInvalid
        ..reason = ticket.refusal
        ..outcomeMs = runner._now;
      return;
    }
    entry.cseq = ticket.cseq;
    _byCseq[ticket.cseq!] = entry;
    final inc = incarnation;
    unawaited(
      ticket.persisted.then((_) {
        if (inc == incarnation) entry.persistedMs = runner._now;
      }, onError: (Object _) {}),
    );
  }

  void _onEvent(ClientEvent e) {
    final now = runner._now;
    switch (e) {
      case OpCommitted(:final cseq, :final seq):
        final entry = _byCseq[cseq];
        if (entry == null) return;
        entry
          ..status = LedgerStatus.committed
          ..seq = seq
          ..outcomeMs = now;
      case OpRejected(:final cseq, :final reason, :final op):
        final entry = _byCseq[cseq];
        if (entry != null) {
          entry
            ..status = LedgerStatus.rejected
            ..reason = reason
            ..outcomeMs = now;
        }
        if (reason is Conflict && rng.nextDouble() < runner.config.reapplyRate) _edit(op, cseq);
      case OpLost(:final cseq):
        final entry = _byCseq[cseq];
        if (entry == null) return;
        entry
          ..status = LedgerStatus.lost
          ..outcomeMs = now;
      case ConflictDetected(:final cseq):
        _byCseq[cseq]?.warned = true;
      case LocalInvalid():
        break;
    }
  }
}
