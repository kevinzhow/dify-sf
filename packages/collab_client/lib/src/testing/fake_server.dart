import 'dart:convert';

import '../model/document.dart';
import '../model/ops.dart';
import '../model/templates.dart';
import '../wire/messages.dart';

/// An in-memory implementation of the server side of docs/protocol.md for one document: the sequencer
/// rules (idempotency by `(client, cseq)`, gaps, floor/resolveFrom, stale-write validation), the committed
/// log, and the resume rules of the event stream. Used by tests, the headless CLI's self-hosted mode and
/// the app's demo mode. Deterministic and synchronous; network behaviour lives in `FakeTransport`.
class FakeServer {
  FakeServer({Document? initial, this.maxReplay = 2000}) : doc = initial ?? Templates.example();

  Document doc;
  int get head => log.length;
  final int maxReplay;

  /// The committed log; entry `i` has `seq == i + 1`.
  final List<LogEntry> log = [];

  final Map<String, int> _high = {};

  /// Fingerprint `(base, op)` of the first op stored under each `(client, cseq)` (protocol 1.1, section 4
  /// rule 5b): a duplicate with different content means two processes share the client id.
  final Map<String, Map<int, String>> _fingerprints = {};
  int _issued = 0;

  /// `POST /v1/docs/{doc}/clients`: a fresh id, `s-` plus 32 hex digits.
  String issueClientId() => 's-${(++_issued).toRadixString(16).padLeft(32, '0')}';
  final Map<String, Map<int, int>> _committed = {};
  final Map<String, Map<int, RejectReason>> _rejected = {};

  /// Called for every committed entry, after it is applied (the stream fan-out).
  final List<void Function(LogEntry)> _listeners = [];

  void addListener(void Function(LogEntry) l) => _listeners.add(l);
  void removeListener(void Function(LogEntry) l) => _listeners.remove(l);

  /// Counters for tests: how often a stream was opened with a snapshot / a log replay.
  int snapshotsServed = 0;
  int replaysServed = 0;

  int highOf(String client) => _high[client] ?? 0;

  /// Processes one batch. Mirrors `Sequencer.process` in the reference implementation.
  SubmitResponse submit(SubmitRequest req) {
    final client = req.client;
    var high = _high[client] ?? 0;
    final committed = _committed.putIfAbsent(client, () => {});
    final rejected = _rejected.putIfAbsent(client, () => {});
    final prints = _fingerprints.putIfAbsent(client, () => {});
    final floor = req.floor;
    if (floor != null && floor - 1 > high) high = floor - 1;
    final results = <OpResult>[];
    final entries = <LogEntry>[];
    for (final inc in req.ops) {
      final cseq = inc.cseq;
      final fingerprint = jsonEncode([inc.base, inc.op.toJson()]);
      if (cseq <= high) {
        final first = prints[cseq];
        if (first != null && first != fingerprint) {
          results.add(RejectResult(cseq, const ClientIdInUse())); // nothing applied
          continue;
        }
        // Retransmit of something already handled: answer from durable facts, never apply twice.
        final s = committed[cseq];
        results.add(s != null ? AckResult(cseq, s) : RejectResult(cseq, rejected[cseq] ?? const NotCommitted()));
        continue;
      }
      if (cseq > high + 1) {
        results.add(GapResult(cseq, high + 1));
        continue;
      }
      // A new op, in order. Whatever happens, it advances the client's cseq.
      prints[cseq] = fingerprint;
      RejectReason? bad;
      if (inc.base < 0 || inc.base > head) {
        bad = Invalid('base ${inc.base} is outside 0...$head');
      } else {
        bad = doc.validate(inc.op, base: inc.base, client: client);
      }
      if (bad == null) {
        final entry = LogEntry(seq: head + 1, client: client, cseq: cseq, base: inc.base, op: inc.op);
        log.add(entry);
        doc.apply(inc.op, entry.stamp);
        committed[cseq] = entry.seq;
        entries.add(entry);
        results.add(AckResult(cseq, entry.seq));
      } else {
        rejected[cseq] = bad;
        results.add(RejectResult(cseq, bad));
      }
      high = cseq;
    }
    _high[client] = high;
    KnownOutcomes? known;
    final from = req.resolveFrom;
    if (from != null) {
      known = KnownOutcomes(
        committed: {
          for (final e in committed.entries)
            if (e.key >= from && e.key <= high) e.key: e.value,
        },
        rejected: {
          for (final e in rejected.entries)
            if (e.key >= from && e.key <= high) e.key: e.value,
        },
      );
    }
    // Fan out after the "transaction": ack is visible to the stream only after commit.
    for (final e in entries) {
      for (final l in List.of(_listeners)) {
        l(e);
      }
    }
    return SubmitResponse(head: head, high: high, results: results, known: known);
  }

  /// What a newly opened stream receives first (catch-up), ending with `ready`.
  List<StreamEvent> catchUp({int? lastEventId, String? client, int? from}) {
    final n = lastEventId;
    if (n == null || n < 0 || n > head || head - n > maxReplay) {
      final committed = <int, int>{};
      if (client != null) {
        for (final e in (_committed[client] ?? const <int, int>{}).entries) {
          if (e.key >= (from ?? 1)) committed[e.key] = e.value;
        }
      }
      snapshotsServed++;
      return [SnapshotEvent(seq: head, doc: doc.clone(), committed: committed), ReadyEvent(head)];
    }
    replaysServed++;
    return [for (final e in log.skip(n)) CommitEvent(e), ReadyEvent(head)];
  }
}
