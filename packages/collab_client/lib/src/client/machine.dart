import 'dart:math';

import '../model/document.dart';
import '../model/ops.dart';
import '../wire/messages.dart';
import 'durable.dart';
import 'events.dart';

/// Requests the pure machine asks its driver to perform.
sealed class ClientRequest {
  const ClientRequest();
}

/// `POST /v1/docs/{doc}/ops`. At most one is outstanding at a time.
final class SubmitRequestAction extends ClientRequest {
  const SubmitRequestAction(this.request);
  final SubmitRequest request;
}

/// `GET /v1/docs/{doc}/events`. Supersedes (and implicitly cancels) any older stream.
final class OpenStreamAction extends ClientRequest {
  const OpenStreamAction(this.open);
  final StreamOpen open;
}

/// Timing knobs, in whatever unit the caller's `now` uses (simulator ticks, or milliseconds).
final class ClientConfig {
  const ClientConfig({
    this.retransmitAfter = 12000,
    this.streamSilence = 30000,
    this.reconnectBase = 500,
    this.reconnectMax = 15000,
    this.maxBatch = 50,
  });

  /// Resend the outstanding POST if it has not been answered after this long (backstop: the driver's
  /// per-request timeout normally fires first and reports [ClientMachine.submitFailed]).
  final int retransmitAfter;

  /// Reopen the stream if nothing (not even a ping) arrived for this long.
  final int streamSilence;

  /// Reconnect backoff: delay = half..full of `min(reconnectMax, reconnectBase * 2^attempts)`.
  final int reconnectBase;
  final int reconnectMax;
  final int maxBatch;

  ClientConfig copyWith({int? maxBatch}) => ClientConfig(
    retransmitAfter: retransmitAfter,
    streamSilence: streamSilence,
    reconnectBase: reconnectBase,
    reconnectMax: reconnectMax,
    maxBatch: maxBatch ?? this.maxBatch,
  );
}

/// Final fate of one client op.
sealed class _Outcome {
  const _Outcome();
}

final class _Committed extends _Outcome {
  const _Committed(this.seq);
  final int seq;
}

final class _Rejected extends _Outcome {
  const _Rejected(this.reason);
  final RejectReason reason;
}

final class _Lost extends _Outcome {
  const _Lost();
}

class _Pending {
  _Pending(this.cseq, this.base, this.op);
  final int cseq;
  final int base;

  /// null = abandoned (content lost in a crash).
  final Op? op;
  int? ackedSeq;
  _Outcome? outcome;
  bool conflictNotified = false;

  bool get sendable => op != null && outcome == null && ackedSeq == null;
}

/// Read-only view of an unresolved op for the UI ("N edits pending").
final class PendingOpInfo {
  const PendingOpInfo({required this.cseq, required this.op, required this.acked, required this.doomed});
  final int cseq;

  /// null when the content was lost in a crash.
  final Op? op;

  /// The server acknowledged it (committed) but the stream has not delivered it yet.
  final bool acked;

  /// A newer remote write already makes this op fail on the server; it is hidden from the view.
  final bool doomed;
}

final class EditResult {
  const EditResult(this.cseq, this.requests, [this.refusal]);

  /// null if the edit was refused locally (a [LocalInvalid] event was queued).
  final int? cseq;
  final List<ClientRequest> requests;

  /// Why the edit was refused locally (set iff [cseq] is null).
  final RejectReason? refusal;
}

/// Optimistic client state machine (docs/protocol.md section 9).
///
/// `confirmed` mirrors the server at `lastSeq`; `view` = confirmed + pending ops (re-derived on every
/// change, which is the "rebase"). Pure: time is passed in, requests are returned, nothing is awaited.
///
/// Driver contract: perform the returned [ClientRequest]s, feed back [receiveStream] for stream events,
/// [receiveResponse] for POST responses, [streamClosed] when the stream ends, [submitFailed] when a POST
/// errors, and call [tick] regularly.
class ClientMachine {
  ClientMachine({
    required this.id,
    this.journaled = true,
    this.config = const ClientConfig(),
    Random? random,
  }) : _random = random ?? Random();

  /// Boot after a crash or reload. Journaled clients get their unsent ops back; others only learn *that*
  /// cseqs in `[unresolvedFrom, nextCseq)` were in flight and will report them lost or committed once the
  /// server has answered.
  factory ClientMachine.restore(
    ClientDurable d, {
    bool journaled = true,
    ClientConfig config = const ClientConfig(),
    Random? random,
  }) {
    final m = ClientMachine(id: d.id, journaled: journaled, config: config, random: random);
    m.nextCseq = d.nextCseq;
    if (journaled) {
      final known = {for (final e in d.journal) e.cseq};
      m._outbox
        ..addAll(d.journal.map((e) => _Pending(e.cseq, e.base, e.op)))
        ..addAll([
          for (var c = d.unresolvedFrom; c < d.nextCseq; c++)
            if (!known.contains(c)) _Pending(c, 0, null),
        ])
        ..sort((a, b) => a.cseq.compareTo(b.cseq));
    } else {
      m._outbox.addAll([for (var c = d.unresolvedFrom; c < d.nextCseq; c++) _Pending(c, 0, null)]);
    }
    return m;
  }

  final String id;
  final bool journaled;
  ClientConfig config;

  Document _confirmed = Document();
  Document _view = Document();
  int lastSeq = 0;
  bool hasState = false;
  int nextCseq = 1;

  /// Anything that indicates a bug in the protocol implementation (checked by tests).
  final List<String> violations = [];

  // Stream state
  int generation = 0;
  bool streamActive = false;
  bool streamReady = false;
  int _lastStreamActivity = 0;
  int _nextOpenAt = 0;
  int reconnectAttempts = 0;

  // POST state
  int? _inFlightSince;
  int _submitBlockedUntil = 0;
  int submitFailures = 0;

  final List<_Pending> _outbox = [];
  final List<ClientEvent> _events = [];
  final Random _random;

  /// Bumped whenever the durable state ([durable]) changed and should be persisted before anything is sent.
  int durableRevision = 0;

  /// Bumped whenever [view] changed (for UI invalidation).
  int viewRevision = 0;

  /// The document at [lastSeq], as the server has it.
  Document get confirmed => _confirmed;

  /// The document the user sees: [confirmed] plus unresolved local ops. A live object: do not retain it
  /// across calls and never mutate it.
  Document get view => _view;

  int get unresolvedCount => _outbox.length;

  bool get isQuiescent => _outbox.isEmpty && hasState && streamActive && streamReady;

  List<PendingOpInfo> get pending => [
    for (final p in _outbox)
      if (p.outcome == null)
        PendingOpInfo(cseq: p.cseq, op: p.op, acked: p.ackedSeq != null, doomed: p.conflictNotified),
  ];

  /// Human-readable state, for diagnostics.
  List<String> get debug => [
    for (final p in _outbox)
      'cseq ${p.cseq} op=${p.op == null ? 'abandoned' : 'set'} acked=${p.ackedSeq} outcome=${p.outcome}',
    'lastSeq=$lastSeq hasState=$hasState streamActive=$streamActive ready=$streamReady '
        'inFlight=$_inFlightSince blockedUntil=$_submitBlockedUntil',
  ];

  // ---- persistence -------------------------------------------------------------------------------

  ClientDurable get durable => ClientDurable(
    id: id,
    nextCseq: nextCseq,
    unresolvedFrom: _outbox.isEmpty ? nextCseq : _outbox.first.cseq,
    journal: journaled
        ? [
            for (final p in _outbox)
              if (p.op != null) JournalEntry(cseq: p.cseq, base: p.base, op: p.op!),
          ]
        : const [],
  );

  List<ClientEvent> drainEvents() {
    final out = List.of(_events);
    _events.clear();
    return out;
  }

  // ---- user edits --------------------------------------------------------------------------------

  /// Optimistically applies a local edit and queues it.
  ///
  /// [base] is the server version the user was looking at when they *started* the edit (a text draft that
  /// took seconds to type); it defaults to [lastSeq] and is clamped to it. Using the older version is what
  /// keeps a slow edit from silently overwriting a write that landed meanwhile: the stale-write rule then
  /// refuses it (locally at once, as [LocalInvalid] with a [Conflict]).
  EditResult edit(Op op, int now, {int? base}) {
    if (!hasState) {
      const reason = Invalid('not synced yet');
      _events.add(LocalInvalid(op: op, reason: reason));
      return const EditResult(null, [], reason);
    }
    final editBase = base == null ? lastSeq : max(0, min(base, lastSeq));
    final bad = _view.validate(op, base: editBase, client: id);
    if (bad != null) {
      _events.add(LocalInvalid(op: op, reason: bad));
      return EditResult(null, const [], bad);
    }
    final cseq = nextCseq++;
    _outbox.add(_Pending(cseq, editBase, op));
    durableRevision++;
    if (identical(_view, _confirmed)) _view = _confirmed.clone();
    _view.apply(op, _localStamp);
    viewRevision++;
    return EditResult(cseq, _flushIfIdle(now));
  }

  // ---- timers and transport signals --------------------------------------------------------------

  /// Call regularly (and once at boot). Opens/reopens the stream, runs the silence watchdog, and
  /// (re)sends the outstanding POST.
  List<ClientRequest> tick(int now) {
    final out = <ClientRequest>[];
    if (streamActive && now - _lastStreamActivity >= config.streamSilence) {
      // Half-open or stalled connection: no events and no pings for too long.
      _closeStream(now, backoff: true);
    }
    if (!streamActive && now >= _nextOpenAt) out.add(_openStream(now));
    final t = _inFlightSince;
    if (t != null && now - t >= config.retransmitAfter) {
      _inFlightSince = null; // the POST (or its response) is presumed lost; resend below
    }
    return out..addAll(_flushIfIdle(now));
  }

  /// The platform says connectivity is back (or the server restarted): reconnect right away instead of
  /// waiting out the backoff, and resend the outstanding POST.
  List<ClientRequest> networkAvailable(int now) {
    reconnectAttempts = 0;
    submitFailures = 0;
    _submitBlockedUntil = 0;
    _inFlightSince = null;
    if (streamActive) _closeStream(now, backoff: false);
    return [_openStream(now), ..._flushIfIdle(now)];
  }

  /// The transport saw the stream of [generation] end (EOF, error, cut).
  void streamClosed(int generation, int now) {
    if (generation != this.generation || !streamActive) return;
    _closeStream(now, backoff: true);
  }

  /// The POST failed at the transport level (connect error, timeout, 5xx). Safe to resend: idempotent.
  void submitFailed(int now) {
    _inFlightSince = null;
    submitFailures++;
    _submitBlockedUntil = now + _backoffDelay(submitFailures);
  }

  /// The server said the body was too large: send smaller batches from now on.
  void shrinkBatch() {
    config = config.copyWith(maxBatch: max(1, config.maxBatch ~/ 2));
  }

  void _closeStream(int now, {required bool backoff}) {
    streamActive = false;
    streamReady = false;
    generation++; // events of the old stream are now ignored
    if (backoff) {
      reconnectAttempts++;
      _nextOpenAt = now + _backoffDelay(reconnectAttempts);
    } else {
      _nextOpenAt = now;
    }
  }

  OpenStreamAction _openStream(int now) {
    streamActive = true;
    streamReady = false;
    generation++;
    _lastStreamActivity = now;
    return OpenStreamAction(
      StreamOpen(
        client: id,
        lastEventId: hasState ? lastSeq : null,
        from: _outbox.isEmpty ? null : _outbox.first.cseq,
        generation: generation,
      ),
    );
  }

  /// `delay = cap/2 + random(0 ... cap/2)` with `cap = min(reconnectMax, reconnectBase * 2^attempts)`.
  int _backoffDelay(int attempts) {
    final cap = min(config.reconnectMax, config.reconnectBase << min(attempts, 20));
    return cap ~/ 2 + _random.nextInt(cap - cap ~/ 2 + 1);
  }

  // ---- submitting --------------------------------------------------------------------------------

  List<ClientRequest> _flushIfIdle(int now) {
    if (_inFlightSince != null || now < _submitBlockedUntil) return const [];
    final abandoned = _outbox.any((p) => p.op == null && p.outcome == null);
    final batch = <OutgoingOp>[];
    for (final p in _outbox) {
      if (!p.sendable) continue;
      batch.add(OutgoingOp(cseq: p.cseq, base: p.base, op: p.op!));
      if (batch.length >= config.maxBatch) break;
    }
    if (!abandoned && batch.isEmpty) return const [];
    int? floor;
    int? resolveFrom;
    if (abandoned) {
      // We lost the content of some in-flight ops: tell the server to stop waiting for them and report
      // what it did with them.
      floor = _outbox.where((p) => p.sendable).map((p) => p.cseq).firstOrNull ?? nextCseq;
      resolveFrom = _outbox.first.cseq;
    }
    _inFlightSince = now;
    return [
      SubmitRequestAction(SubmitRequest(client: id, floor: floor, resolveFrom: resolveFrom, ops: batch)),
    ];
  }

  // ---- server -> client --------------------------------------------------------------------------

  /// A stream event of the given generation (stale generations are ignored).
  List<ClientRequest> receiveStream(StreamEvent event, int generation, int now) {
    if (generation != this.generation || !streamActive) return const [];
    _lastStreamActivity = now;
    final out = <ClientRequest>[];
    switch (event) {
      case PingEvent():
        return const [];
      case ReadyEvent():
        streamReady = true;
        reconnectAttempts = 0;
      case SnapshotEvent():
        _adopt(event);
      case CommitEvent(:final entry):
        if (!hasState) break;
        if (entry.seq <= lastSeq) break; // duplicate
        if (entry.seq != lastSeq + 1) {
          // A hole in the stream: reconnect and resume from lastSeq.
          _closeStream(now, backoff: false);
          out.add(_openStream(now));
          break;
        }
        _ingest(entry);
    }
    _settleAckedUpToLastSeq();
    _rebuildView();
    _releaseResolved();
    return out..addAll(_flushIfIdle(now));
  }

  /// The answer to a POST (possibly a stale one from an earlier retransmit; that is harmless).
  List<ClientRequest> receiveResponse(SubmitResponse response, int now) {
    _inFlightSince = null;
    submitFailures = 0;
    _submitBlockedUntil = 0;
    for (final r in response.results) {
      switch (r) {
        case AckResult(:final cseq, :final seq):
          _acked(cseq, seq);
        case RejectResult(:final cseq, :final reason):
          _settle(cseq, _Rejected(reason));
        case GapResult():
          break; // resend from the front on the next flush (nothing was recorded)
      }
    }
    final known = response.known;
    if (known != null) {
      for (final cseq in known.committed.keys.toList()..sort()) {
        _acked(cseq, known.committed[cseq]!);
      }
      for (final e in known.rejected.entries) {
        _settle(e.key, _Rejected(e.value));
      }
      // Abandoned ops the server handled but never committed or rejected: definitively not saved.
      for (final p in _outbox) {
        if (p.op == null && p.outcome == null && p.ackedSeq == null && p.cseq <= response.high) {
          p.outcome = const _Lost();
        }
      }
    }
    _settleAckedUpToLastSeq();
    _rebuildView();
    _releaseResolved();
    return _flushIfIdle(now);
  }

  void _acked(int cseq, int seq) {
    final p = _find(cseq);
    if (p == null || p.outcome != null) return;
    if (seq <= lastSeq && hasState) {
      _settle(cseq, _Committed(seq));
    } else {
      p.ackedSeq = seq;
    }
  }

  void _adopt(SnapshotEvent s) {
    _confirmed = s.doc;
    lastSeq = s.seq;
    hasState = true;
    reconnectAttempts = 0;
    for (final cseq in s.committed.keys.toList()..sort()) {
      final seq = s.committed[cseq]!;
      if (seq <= s.seq) _settle(cseq, _Committed(seq));
    }
  }

  void _ingest(LogEntry e) {
    final bad = _confirmed.validate(e.op, base: e.base, client: e.client, checkConflicts: false);
    if (bad != null) violations.add('committed entry ${e.seq} invalid on client: $bad');
    _confirmed.apply(e.op, e.stamp);
    lastSeq = e.seq;
    if (e.client == id) _settle(e.cseq, _Committed(e.seq));
  }

  /// An acked op whose entry we have since passed is committed (covers snapshot joins).
  void _settleAckedUpToLastSeq() {
    if (!hasState) return;
    for (final p in _outbox) {
      final s = p.ackedSeq;
      if (p.outcome == null && s != null && s <= lastSeq) p.outcome = _Committed(s);
    }
  }

  _Pending? _find(int cseq) {
    for (final p in _outbox) {
      if (p.cseq == cseq) return p;
    }
    return null;
  }

  void _settle(int cseq, _Outcome outcome) {
    final p = _find(cseq);
    if (p == null) return;
    var o = outcome;
    if (p.op == null && o is _Rejected) o = const _Lost(); // content already gone
    switch ((p.outcome, o)) {
      case (null, _):
        p.outcome = o;
      case (_Committed(seq: final a), _Committed(seq: final b)) when a == b:
        break;
      case (_Committed(), _Rejected()):
        break; // late duplicate answer; commit wins
      case (_Rejected(), _Committed()):
        violations.add('cseq $cseq committed after being reported rejected');
      default:
        break;
    }
  }

  // ---- rebase ------------------------------------------------------------------------------------

  Stamp get _localStamp => Stamp(9007199254740991, id); // above any real seq: only used in the local view

  /// view = confirmed + every unresolved op that is still valid on top of it. Ops that became invalid
  /// (stale conflict, node deleted remotely, ...) are hidden; stale-based ones raise an early warning once.
  void _rebuildView() {
    final live = _outbox.where((p) => p.outcome == null && p.op != null).toList();
    if (live.isEmpty) {
      _view = _confirmed;
      viewRevision++;
      return;
    }
    final d = _confirmed.clone();
    for (final p in live) {
      final op = p.op!;
      final bad = d.validate(op, base: p.base, client: id);
      if (bad == null) {
        d.apply(op, _localStamp);
      } else if (bad.isStaleBased && !p.conflictNotified) {
        p.conflictNotified = true;
        _events.add(ConflictDetected(cseq: p.cseq, op: op, reason: bad));
      }
    }
    _view = d;
    viewRevision++;
  }

  /// Reports outcomes strictly in cseq order so the persisted "unresolved from" pointer stays contiguous.
  void _releaseResolved() {
    var released = false;
    while (_outbox.isNotEmpty && _outbox.first.outcome != null) {
      final first = _outbox.removeAt(0);
      released = true;
      switch (first.outcome!) {
        case _Committed(:final seq):
          _events.add(OpCommitted(cseq: first.cseq, seq: seq, op: first.op));
        case _Rejected(:final reason):
          _events.add(OpRejected(cseq: first.cseq, op: first.op!, reason: reason));
        case _Lost():
          _events.add(OpLost(cseq: first.cseq));
      }
    }
    if (released) durableRevision++;
  }
}
