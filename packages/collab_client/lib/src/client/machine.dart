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

/// The client id is compromised (another process uses it, protocol 1.1): the driver must obtain a fresh id
/// (`POST /v1/docs/{doc}/clients`) and call [ClientMachine.adoptClientId]. Emitted once per compromise.
final class RequestClientIdAction extends ClientRequest {
  const RequestClientIdAction();
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

  /// A snapshot said the server committed `(client, cseq)` at this seq. For an op whose content we hold this is
  /// only a claim about the *id*, not about our op (if another process shares the id, the entry is theirs), so
  /// the op stays unresolved and is re-sent: the server answers a genuine duplicate with the original `ack` and a
  /// different one with `clientIdInUse`.
  int? claimedSeq;
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

  /// The client id. Changes at most when the id is found to be shared with another process
  /// ([adoptClientId]); never reused after that.
  String id;
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

  // Client id compromise (protocol 1.1, `clientIdInUse`)
  bool _idCompromised = false;
  bool _idRequested = false;
  int _catchUpTo = 0;

  /// The id is shared with another process: nothing is sent until a new id is adopted.
  bool get idCompromised => _idCompromised;

  // Refused submissions (protocol 1.8, `403 forbidden` on `POST /ops`)
  bool _forbidden = false;
  bool _forbiddenCatchUp = false;

  /// The next POST must carry `floor` = the oldest cseq still to be sent, so that the server stops waiting for cseqs this
  /// client finished locally without the server ever handling them (see [submitForbidden]). Cleared once a response
  /// shows the server's `high` at or past it.
  int? _floor;

  /// A `POST /ops` was refused with `403 forbidden` and [allowEdits] has not been called since: nothing is sent and new
  /// edits are refused locally (as [LocalInvalid] with [Forbidden]).
  bool get editsForbidden => _forbidden;

  // Replacing the document (`POST /replace`, docs/protocol.md section 9, "Replacing the document")
  bool _replacing = false;

  /// A replacement is under way ([beginReplace]): new edits are refused locally.
  bool get replacing => _replacing;

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
        PendingOpInfo(
          cseq: p.cseq,
          op: p.op,
          acked: p.ackedSeq != null || p.claimedSeq != null,
          doomed: p.conflictNotified,
        ),
  ];

  /// Human-readable state, for diagnostics.
  List<String> get debug => [
    for (final p in _outbox)
      'cseq ${p.cseq} op=${p.op == null ? 'abandoned' : 'set'} acked=${p.ackedSeq} outcome=${p.outcome}',
    'lastSeq=$lastSeq hasState=$hasState streamActive=$streamActive ready=$streamReady '
        'inFlight=$_inFlightSince blockedUntil=$_submitBlockedUntil forbidden=$_forbidden floor=$_floor',
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
    if (_forbidden) {
      const reason = Forbidden();
      _events.add(LocalInvalid(op: op, reason: reason));
      return const EditResult(null, [], reason);
    }
    if (_replacing) {
      const reason = Invalid('the document is being replaced');
      _events.add(LocalInvalid(op: op, reason: reason));
      return const EditResult(null, [], reason);
    }
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

  // ---- replacing the document --------------------------------------------------------------------

  /// Starts replacing the document (`POST /v1/docs/{doc}/replace`): from now on new edits are refused locally (as
  /// [LocalInvalid]) until [finishReplace] or [abortReplace]. Send the request once [replaceCseq] is not null.
  void beginReplace() => _replacing = true;

  /// The cseq a replacement may reserve (= [nextCseq]) once the server has handled every cseq below it: no unresolved
  /// op, no pending `floor`, no POST in flight, synced, allowed to edit, the id not compromised. Null until then.
  int? get replaceCseq {
    if (!_replacing || _outbox.isNotEmpty || !hasState || _forbidden || _idCompromised || _floor != null) return null;
    if (_inFlightSince != null) return null;
    return nextCseq;
  }

  /// The replacement was committed (or replayed): continue at [next] (`next_cseq` of the answer) and accept edits again.
  void finishReplace(int next) {
    _replacing = false;
    if (next > nextCseq) {
      nextCseq = next;
      durableRevision++;
    }
  }

  /// The replacement was refused or given up: nothing was reserved; accept edits again.
  void abortReplace() => _replacing = false;

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

  /// The POST was refused with `403 forbidden` (protocol 1.8: the account's role cannot edit, e.g. after a role change,
  /// or the client id belongs to another account). Final, not a transport failure: nothing is resent and nothing new
  /// is sent until [allowEdits]; new edits are refused locally. Emits [EditingForbidden] (once per streak).
  ///
  /// The ops still waiting for a verdict are finished as rejected with the local reason [Forbidden] (not saved), but
  /// only once a stream opened after the refusal is `ready`: an earlier copy of the same POST (one that timed out) may
  /// have been committed before the refusal, and only a stream opened afterwards is sure to show that. Ops it shows
  /// committed are committed; content-less (abandoned) ops are lost. Returns the request that reopens the stream.
  List<ClientRequest> submitForbidden(int now) {
    _inFlightSince = null;
    submitFailures = 0;
    _submitBlockedUntil = 0;
    if (!_forbidden) {
      _forbidden = true;
      _events.add(const EditingForbidden());
    }
    if (!_outbox.any((p) => p.outcome == null && p.ackedSeq == null)) return const [];
    _forbiddenCatchUp = true;
    if (streamActive) _closeStream(now, backoff: false);
    return [_openStream(now)];
  }

  /// The account may edit again (the app re-read its role after [EditingForbidden]): new edits are accepted and
  /// sending resumes. Ops not finished yet (the stream had not caught up) are simply sent again. If some ops were
  /// finished as [Forbidden], the next POST (sent at once, possibly without ops) carries `floor`, so the server never
  /// waits for, nor later accepts, those cseqs.
  List<ClientRequest> allowEdits(int now) {
    if (!_forbidden) return const [];
    _forbidden = false;
    _forbiddenCatchUp = false;
    return _flushIfIdle(now);
  }

  /// The stream opened after a `403` is caught up, so whatever of ours the server committed before the refusal has
  /// been seen: finish everything else that still waits for a verdict.
  void _finishForbidden() {
    _forbiddenCatchUp = false;
    for (final p in _outbox) {
      if (p.outcome != null || p.ackedSeq != null) continue;
      final claimed = p.claimedSeq;
      if (p.op == null) {
        p.outcome = const _Lost();
      } else if (claimed != null) {
        // A snapshot said the server committed this (client, cseq); a resend can no longer confirm that it is our op,
        // so the server's word is all we have (as for abandoned ops, and as the Swift reference client always does).
        p.outcome = _Committed(claimed);
      } else {
        p.outcome = const _Rejected(Forbidden());
      }
    }
    // These cseqs were never handled by the server: tell it not to wait for them (its `high` is behind them).
    _floor = nextCseq;
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
    if (_forbidden) return const [];
    if (_idCompromised) return _maybeRequestNewId();
    if (_inFlightSince != null || now < _submitBlockedUntil) return const [];
    final abandoned = _outbox.any((p) => p.op == null && p.outcome == null);
    final batch = <OutgoingOp>[];
    for (final p in _outbox) {
      if (!p.sendable) continue;
      batch.add(OutgoingOp(cseq: p.cseq, base: p.base, op: p.op!));
      if (batch.length >= config.maxBatch) break;
    }
    if (!abandoned && batch.isEmpty && _floor == null) return const [];
    int? floor;
    int? resolveFrom;
    if (abandoned || _floor != null) {
      // We lost the content of some in-flight ops, or finished some without the server handling them (refused with
      // `403`): tell the server to stop waiting for them.
      floor = _firstUnsent;
    }
    if (abandoned) resolveFrom = _outbox.first.cseq; // ... and to report what it did with the lost ones
    _inFlightSince = now;
    return [
      SubmitRequestAction(SubmitRequest(client: id, floor: floor, resolveFrom: resolveFrom, ops: batch)),
    ];
  }

  /// The oldest cseq this client will still send.
  int get _firstUnsent => _outbox.where((p) => p.sendable).map((p) => p.cseq).firstOrNull ?? nextCseq;

  // ---- server -> client --------------------------------------------------------------------------

  /// A stream event of the given generation (stale generations are ignored).
  List<ClientRequest> receiveStream(StreamEvent event, int generation, int now) {
    if (generation != this.generation || !streamActive) return const [];
    _lastStreamActivity = now;
    final out = <ClientRequest>[];
    switch (event) {
      case PingEvent() || CommentsEvent():
        return const []; // liveness only (comments are the session's business, not the document's)
      case ReadyEvent():
        streamReady = true;
        reconnectAttempts = 0;
        if (_forbiddenCatchUp) _finishForbidden();
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
        case RejectResult(reason: ClientIdInUse()):
          // Not a verdict on the op: the id is shared. Keep the op, stop sending, replace the id.
          _compromise(response.head);
        case RejectResult(:final cseq, :final reason):
          _settle(cseq, _Rejected(reason));
        case GapResult(:final expected):
          // Resend from the front on the next flush (nothing was recorded). If the server waits for cseqs we finished
          // without it ever handling them (refused with `403`, then a restart before a `floor` got through), say so.
          if (expected < _firstUnsent) _floor = _firstUnsent;
      }
    }
    final f = _floor;
    if (f != null && response.high >= f - 1) _floor = null;
    final known = response.known;
    if (known != null) {
      for (final cseq in known.committed.keys.toList()..sort()) {
        _acked(cseq, known.committed[cseq]!);
      }
      for (final e in known.rejected.entries) {
        if (e.value is ClientIdInUse) {
          _compromise(response.head);
        } else {
          _settle(e.key, _Rejected(e.value));
        }
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
      if (seq > s.seq) continue;
      final mine = _find(cseq);
      if (mine != null && mine.op != null && mine.outcome == null) {
        mine.claimedSeq = seq; // verified by the server's answer to our re-send, see _Pending.claimedSeq
      } else {
        _settle(cseq, _Committed(seq)); // no content to compare (abandoned op): the server's word is all we have
      }
    }
  }

  void _ingest(LogEntry e) {
    final bad = _confirmed.validate(e.op, base: e.base, client: e.client, checkConflicts: false);
    if (bad != null) violations.add('committed entry ${e.seq} invalid on client: $bad');
    _confirmed.apply(e.op, e.stamp);
    lastSeq = e.seq;
    if (e.client == id) {
      final mine = _find(e.cseq);
      if (mine != null && mine.op != null && (mine.op != e.op || mine.base != e.base)) {
        // Someone else committed a different op under our (client, cseq): the id is shared.
        _compromise(e.seq);
      } else {
        _settle(e.cseq, _Committed(e.seq));
      }
    }
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

  // ---- client id compromise ----------------------------------------------------------------------

  void _compromise(int head) {
    _idCompromised = true;
    _catchUpTo = max(_catchUpTo, head);
  }

  /// Once the stream has caught up with everything committed so far (so that any of our own ops that did
  /// get committed under the old id have been recognised), ask the driver for a new id.
  List<ClientRequest> _maybeRequestNewId() {
    if (_idRequested) return const [];
    final settling = _outbox.any((p) => p.ackedSeq != null && p.outcome == null);
    if (!hasState || !streamReady || lastSeq < _catchUpTo || settling) return const [];
    _idRequested = true;
    return const [RequestClientIdAction()];
  }

  /// Switches to [newId] after a [RequestClientIdAction]: starts again at cseq 1 and re-creates every unsaved
  /// op (same content, same `base`, so stale-write protection is unchanged) as a new op. Ops whose content
  /// was lost in a crash cannot be re-created and are reported lost. Emits [ClientIdReplaced].
  List<ClientRequest> adoptClientId(String newId, int now) {
    _releaseResolved();
    final oldId = id;
    final renumbered = <int, int>{};
    final fresh = <_Pending>[];
    var next = 1;
    for (final p in _outbox) {
      if (p.outcome != null) continue;
      if (p.op == null) {
        _events.add(OpLost(cseq: p.cseq));
        continue;
      }
      renumbered[p.cseq] = next;
      fresh.add(_Pending(next++, p.base, p.op));
    }
    _outbox
      ..clear()
      ..addAll(fresh);
    id = newId;
    nextCseq = next;
    _idCompromised = false;
    _idRequested = false;
    _catchUpTo = 0;
    _floor = null; // the new id has no history on the server
    _inFlightSince = null;
    submitFailures = 0;
    _submitBlockedUntil = 0;
    durableRevision++;
    _events.add(ClientIdReplaced(oldId: oldId, newId: newId, renumbered: renumbered));
    _rebuildView();
    final out = <ClientRequest>[];
    // The stream carries `client` (for the snapshot's `committed` map): reopen it under the new id.
    if (streamActive) _closeStream(now, backoff: false);
    out.add(_openStream(now));
    return out..addAll(_flushIfIdle(now));
  }

  // ---- rebase ------------------------------------------------------------------------------------

  Stamp get _localStamp => Stamp(9007199254740991, id); // above any real seq: only used in the local view

  /// view = confirmed + every unresolved op that is still valid on top of it. Ops that became invalid
  /// (stale conflict, node deleted remotely, ...) are hidden; stale-based ones raise an early warning once.
  void _rebuildView() {
    // Ops the snapshot claims are already in `confirmed` are not applied again (nor warned about).
    final live = _outbox.where((p) => p.outcome == null && p.op != null && p.claimedSeq == null).toList();
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
