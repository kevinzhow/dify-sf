/// Dart port of CollabCore's Client state machine (optimistic apply, rebase, retransmit).
/// Pure: no timers or sockets. Feed it server messages and ticks, send what it returns.
library;

import 'model.dart';

// ---- wire messages ---------------------------------------------------------------------------

class LogEntry {
  final int seq, cseq, base;
  final String client;
  final Op op;
  const LogEntry(this.seq, this.client, this.cseq, this.base, this.op);
  Stamp get stamp => Stamp(seq, client);
}

sealed class ClientMessage {}

class Hello extends ClientMessage {
  final String client;
  final int? lastSeq;
  final int willResendFrom;
  Hello(this.client, this.lastSeq, this.willResendFrom);
}

class Submit extends ClientMessage {
  final String client;
  final int cseq, base;
  final Op op;
  Submit(this.client, this.cseq, this.base, this.op);
}

sealed class ServerMessage {}

class Welcome extends ServerMessage {
  final int head, clientHigh;
  final Document? snapshotDoc; // non-null = snapshot present
  final int snapshotSeq;
  final Map<int, int> committedMine; // cseq -> seq, for ops inside the snapshot
  final List<LogEntry> entries;
  final Map<int, RejectReason> rejected;
  Welcome({
    required this.head,
    this.snapshotDoc,
    this.snapshotSeq = 0,
    this.committedMine = const {},
    this.entries = const [],
    this.clientHigh = 0,
    this.rejected = const {},
  });
}

class Committed extends ServerMessage {
  final List<LogEntry> entries;
  Committed(this.entries);
}

class Rejected extends ServerMessage {
  final int cseq;
  final RejectReason reason;
  Rejected(this.cseq, this.reason);
}

class Ack extends ServerMessage {
  final int cseq, seq;
  Ack(this.cseq, this.seq);
}

class ResyncRequired extends ServerMessage {}

// ---- events for the UI -----------------------------------------------------------------------

sealed class ClientEvent {}

class OpCommitted extends ClientEvent {
  final int cseq, seq;
  OpCommitted(this.cseq, this.seq);
}

/// Not saved. Carries the op so the UI can offer "re-apply mine on top of the latest".
class OpRejected extends ClientEvent {
  final int cseq;
  final Op op;
  final RejectReason reason;
  OpRejected(this.cseq, this.op, this.reason);
}

class OpLost extends ClientEvent {
  final int cseq;
  OpLost(this.cseq);
}

class ConflictDetected extends ClientEvent {
  final int cseq;
  final Op op;
  final RejectReason reason;
  ConflictDetected(this.cseq, this.op, this.reason);
}

class LocalInvalid extends ClientEvent {
  final Op op;
  final RejectReason reason;
  LocalInvalid(this.op, this.reason);
}

// ---- client ----------------------------------------------------------------------------------

class _Pending {
  final int cseq, base;
  final Op? op; // null = abandoned (content lost in a crash)
  int? sentAt;
  // Outcome: ('committed', seq) | ('rejected', reason) | ('lost')
  String? outcomeKind;
  int outcomeSeq = 0;
  RejectReason? outcomeReason;
  bool conflictNotified = false;
  _Pending(this.cseq, this.base, this.op);
  bool get sendable => op != null && outcomeKind == null;
}

class Client {
  final String id;
  final bool journaled;
  final int retransmitAfter, syncEvery;

  Document confirmed = Document();
  Document view = Document();
  int lastSeq = 0;
  bool hasState = false, connected = false, sessionOpen = false;
  int nextCseq = 1;
  final List<String> violations = [];

  final List<_Pending> _outbox = [];
  final Map<int, LogEntry> _buffered = {};
  final List<ClientEvent> _events = [];
  bool _wantsSync = false;
  int _lastHelloAt = -1000;

  Client(this.id, {this.journaled = true, this.retransmitAfter = 8, this.syncEvery = 12});

  int get unresolvedCount => _outbox.length;

  List<ClientEvent> drainEvents() {
    final e = List.of(_events);
    _events.clear();
    return e;
  }

  /// What survives a crash (persist this after every change): counters + journal of unresolved ops.
  Map<String, Object?> get durable => {
        'id': id,
        'nextCseq': nextCseq,
        'unresolvedFrom': _outbox.isEmpty ? nextCseq : _outbox.first.cseq,
        'journal': journaled
            ? [for (final p in _outbox) if (p.op != null) (p.cseq, p.base, p.op)]
            : const [],
      };

  /// Boot after a crash. Non-journaled clients only learn *which* cseqs were in flight.
  Client.restoring(Map<String, Object?> d, {this.journaled = true, this.retransmitAfter = 8, this.syncEvery = 12})
      : id = d['id'] as String {
    nextCseq = d['nextCseq'] as int;
    final journal = (d['journal'] as List).cast<(int, int, Op?)>();
    for (final (c, b, op) in journal) {
      _outbox.add(_Pending(c, b, op));
    }
    final known = journal.map((j) => j.$1).toSet();
    for (var c = d['unresolvedFrom'] as int; c < nextCseq; c++) {
      if (!known.contains(c)) _outbox.add(_Pending(c, 0, null));
    }
    _outbox.sort((a, b) => a.cseq.compareTo(b.cseq));
  }

  // ---- user edits ----

  /// Optimistic local apply. Returns the cseq (null if refused locally) and messages to send.
  (int?, List<ClientMessage>) edit(Op op, int now) {
    if (!hasState) {
      _events.add(LocalInvalid(op, const RejectReason('invalid', 'not synced yet')));
      return (null, const []);
    }
    try {
      view.validate(op, base: lastSeq, by: id);
    } on RejectReason catch (r) {
      _events.add(LocalInvalid(op, r));
      return (null, const []);
    }
    final p = _Pending(nextCseq++, lastSeq, op);
    _outbox.add(p);
    view.apply(op, Stamp(1 << 62, id));
    final out = <ClientMessage>[];
    if (connected && sessionOpen) {
      p.sentAt = now;
      out.add(Submit(id, p.cseq, p.base, op));
    }
    return (p.cseq, out);
  }

  // ---- connection lifecycle ----

  List<ClientMessage> connect(int now) {
    connected = true;
    sessionOpen = false;
    return [_hello(now)];
  }

  void connectionLost() {
    connected = false;
    sessionOpen = false;
  }

  List<ClientMessage> tick(int now) {
    if (!connected) return const [];
    final out = <ClientMessage>[];
    if (!sessionOpen) {
      if (now - _lastHelloAt >= retransmitAfter) out.add(_hello(now));
      return out;
    }
    if (((_wantsSync || _buffered.isNotEmpty) && now - _lastHelloAt >= 2) || now - _lastHelloAt >= syncEvery) {
      out.add(_hello(now));
    }
    out.addAll(_retransmit(now, force: false));
    return out;
  }

  Hello _hello(int now) {
    _lastHelloAt = now;
    _wantsSync = false;
    final first = _outbox.where((p) => p.sendable).map((p) => p.cseq).followedBy([nextCseq]).first;
    return Hello(id, hasState ? lastSeq : null, first);
  }

  List<ClientMessage> _retransmit(int now, {required bool force}) {
    final out = <ClientMessage>[];
    for (final p in _outbox.where((p) => p.sendable)) {
      if (!force && p.sentAt != null && now - p.sentAt! < retransmitAfter) continue;
      p.sentAt = now;
      out.add(Submit(id, p.cseq, p.base, p.op!));
    }
    return out;
  }

  // ---- server messages ----

  List<ClientMessage> receive(ServerMessage m, int now) {
    final out = <ClientMessage>[];
    switch (m) {
      case Committed(:final entries):
        if (hasState) _ingest(entries);
      case Welcome w:
        if (!hasState && w.snapshotDoc == null) return const [];
        _handleWelcome(w);
        sessionOpen = true;
        out.addAll(_retransmit(now, force: true));
      case Rejected(:final cseq, :final reason):
        _settle(cseq, 'rejected', reason: reason);
      case Ack(:final seq):
        if (seq > lastSeq) _wantsSync = true;
      case ResyncRequired():
        sessionOpen = false;
        out.add(_hello(now));
    }
    _rebuildView();
    _releaseResolved();
    return out;
  }

  void _handleWelcome(Welcome w) {
    if (w.snapshotDoc != null && (!hasState || w.snapshotSeq > lastSeq)) {
      confirmed = w.snapshotDoc!.clone();
      lastSeq = w.snapshotSeq;
      hasState = true;
      _buffered.removeWhere((seq, _) => seq <= w.snapshotSeq);
      for (final e in w.committedMine.entries) {
        _settle(e.key, 'committed', seq: e.value);
      }
    }
    _ingest(w.entries);
    if (lastSeq < w.head) return;
    // Every commit of ours with cseq <= clientHigh is now known; anything without an outcome was not saved.
    for (final p in _outbox.where((p) => p.outcomeKind == null && p.cseq <= w.clientHigh)) {
      if (p.op == null) {
        p.outcomeKind = 'lost';
      } else {
        p.outcomeKind = 'rejected';
        p.outcomeReason = w.rejected[p.cseq] ?? const RejectReason('notCommitted');
      }
    }
  }

  void _ingest(List<LogEntry> entries) {
    for (final e in entries.where((e) => e.seq > lastSeq)) {
      _buffered[e.seq] = e;
    }
    while (_buffered.containsKey(lastSeq + 1)) {
      final e = _buffered.remove(lastSeq + 1)!;
      try {
        confirmed.validate(e.op, base: e.base, by: e.client, checkConflicts: false);
      } on RejectReason catch (r) {
        violations.add('committed entry ${e.seq} invalid on client: $r');
      }
      confirmed.apply(e.op, e.stamp);
      lastSeq = e.seq;
      if (e.client == id) _settle(e.cseq, 'committed', seq: e.seq);
    }
    if (_buffered.isNotEmpty) _wantsSync = true;
  }

  void _settle(int cseq, String kind, {int seq = 0, RejectReason? reason}) {
    final i = _outbox.indexWhere((p) => p.cseq == cseq);
    if (i < 0) return;
    final p = _outbox[i];
    if (p.op == null && kind == 'rejected') kind = 'lost';
    if (p.outcomeKind == null) {
      p.outcomeKind = kind;
      p.outcomeSeq = seq;
      p.outcomeReason = reason;
    } else if (p.outcomeKind == 'rejected' && kind == 'committed') {
      violations.add('cseq $cseq committed after being reported rejected');
    }
  }

  /// view = confirmed + every unresolved op that is still valid on top of it (the "rebase").
  void _rebuildView() {
    final d = confirmed.clone();
    for (final p in _outbox.where((p) => p.outcomeKind == null && p.op != null)) {
      try {
        d.validate(p.op!, base: p.base, by: id);
        d.apply(p.op!, Stamp(1 << 62, id));
      } on RejectReason catch (r) {
        if (r.staleBased && !p.conflictNotified) {
          p.conflictNotified = true;
          _events.add(ConflictDetected(p.cseq, p.op!, r));
        }
      }
    }
    view = d;
  }

  /// Outcomes are reported strictly in cseq order, exactly once each.
  void _releaseResolved() {
    while (_outbox.isNotEmpty && _outbox.first.outcomeKind != null) {
      final p = _outbox.removeAt(0);
      switch (p.outcomeKind) {
        case 'committed':
          _events.add(OpCommitted(p.cseq, p.outcomeSeq));
        case 'rejected':
          _events.add(OpRejected(p.cseq, p.op!, p.outcomeReason!));
        default:
          _events.add(OpLost(p.cseq));
      }
    }
  }
}
