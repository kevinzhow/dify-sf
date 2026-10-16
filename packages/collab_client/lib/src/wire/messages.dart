import 'dart:convert';

import '../model/document.dart';
import '../model/ops.dart';

/// Wire-level message types (JSON encoding specified in docs/protocol.md).

Map<String, Object?> _obj(Object? json, String what) =>
    json is Map<String, Object?> ? json : throw FormatException('bad $what: $json');

int _int(Map<String, Object?> m, String key) =>
    m[key] is int ? m[key]! as int : throw FormatException('missing integer $key in $m');

Map<int, V> _intMap<V>(Object? json, V Function(Object?) value) {
  if (json == null) return {};
  final m = _obj(json, 'map');
  return {
    for (final e in m.entries)
      (int.tryParse(e.key) ?? (throw FormatException('non-integer key ${e.key}'))): value(e.value),
  };
}

/// One committed op in the durable, totally ordered log.
final class LogEntry {
  const LogEntry({required this.seq, required this.client, required this.cseq, required this.base, required this.op});

  factory LogEntry.fromJson(Object? json) {
    final m = _obj(json, 'log entry');
    return LogEntry(
      seq: _int(m, 'seq'),
      client: m['client'] is String ? m['client']! as String : throw const FormatException('missing client'),
      cseq: _int(m, 'cseq'),
      base: _int(m, 'base'),
      op: Op.fromJson(m['op']),
    );
  }

  final int seq;
  final String client;
  final int cseq;
  final int base;
  final Op op;

  Stamp get stamp => Stamp(seq, client);

  Map<String, Object?> toJson() => {'seq': seq, 'client': client, 'cseq': cseq, 'base': base, 'op': op.toJson()};

  @override
  bool operator ==(Object other) =>
      other is LogEntry &&
      other.seq == seq &&
      other.client == client &&
      other.cseq == cseq &&
      other.base == base &&
      other.op == op;

  @override
  int get hashCode => Object.hash(seq, client, cseq, base, op);

  @override
  String toString() => 'LogEntry(#$seq $client/$cseq base=$base $op)';
}

/// An op as sent by a client. `(client, cseq)` is the idempotency key; [base] is the server version the
/// client had applied when the user made the edit (it never changes on retransmit).
final class OutgoingOp {
  const OutgoingOp({required this.cseq, required this.base, required this.op});
  final int cseq;
  final int base;
  final Op op;

  Map<String, Object?> toJson() => {'cseq': cseq, 'base': base, 'op': op.toJson()};
}

/// `POST /v1/docs/{doc}/ops`
final class SubmitRequest {
  const SubmitRequest({required this.client, this.floor, this.resolveFrom, this.ops = const []});

  final String client;

  /// "I will never send a cseq below this": used after losing the outbox.
  final int? floor;

  /// Ask for the fate of this client's cseqs in `[resolveFrom, high]`.
  final int? resolveFrom;
  final List<OutgoingOp> ops;

  Map<String, Object?> toJson() => {
    'client': client,
    if (floor != null) 'floor': floor,
    if (resolveFrom != null) 'resolveFrom': resolveFrom,
    'ops': [for (final o in ops) o.toJson()],
  };

  @override
  String toString() =>
      'SubmitRequest($client floor=$floor resolveFrom=$resolveFrom '
      'cseqs=${ops.map((o) => o.cseq).toList()})';
}

sealed class OpResult {
  const OpResult(this.cseq);

  factory OpResult.fromJson(Object? json) {
    final m = _obj(json, 'op result');
    final cseq = _int(m, 'cseq');
    return switch (m['status']) {
      'ack' => AckResult(cseq, _int(m, 'seq')),
      'reject' => RejectResult(cseq, RejectReason.fromJson(m['reason'])),
      'gap' => GapResult(cseq, _int(m, 'expected')),
      final other => throw FormatException('unknown status $other'),
    };
  }

  final int cseq;
  Map<String, Object?> toJson();
}

/// Committed (now or earlier) at global sequence [seq].
final class AckResult extends OpResult {
  const AckResult(super.cseq, this.seq);
  final int seq;
  @override
  Map<String, Object?> toJson() => {'cseq': cseq, 'status': 'ack', 'seq': seq};
}

final class RejectResult extends OpResult {
  const RejectResult(super.cseq, this.reason);
  final RejectReason reason;
  @override
  Map<String, Object?> toJson() => {'cseq': cseq, 'status': 'reject', 'reason': reason.toJson()};
}

/// Not processed: an earlier cseq of this client has not been handled yet. Resend from [expected].
final class GapResult extends OpResult {
  const GapResult(super.cseq, this.expected);
  final int expected;
  @override
  Map<String, Object?> toJson() => {'cseq': cseq, 'status': 'gap', 'expected': expected};
}

final class KnownOutcomes {
  const KnownOutcomes({this.committed = const {}, this.rejected = const {}});

  factory KnownOutcomes.fromJson(Object? json) {
    final m = _obj(json, 'known');
    return KnownOutcomes(
      committed: _intMap(m['committed'], (v) => v is int ? v : throw FormatException('bad seq $v')),
      rejected: _intMap(m['rejected'], RejectReason.fromJson),
    );
  }

  final Map<int, int> committed;
  final Map<int, RejectReason> rejected;

  Map<String, Object?> toJson() => {
    'committed': {for (final e in committed.entries) '${e.key}': e.value},
    'rejected': {for (final e in rejected.entries) '${e.key}': e.value.toJson()},
  };
}

final class SubmitResponse {
  const SubmitResponse({required this.head, required this.high, required this.results, this.known});

  factory SubmitResponse.fromJson(Object? json) {
    final m = _obj(json, 'submit response');
    final results = m['results'];
    if (results is! List<Object?>) throw const FormatException('missing results');
    return SubmitResponse(
      head: _int(m, 'head'),
      high: _int(m, 'high'),
      results: [for (final r in results) OpResult.fromJson(r)],
      known: m['known'] == null ? null : KnownOutcomes.fromJson(m['known']),
    );
  }

  /// Server head (last committed seq) after processing the batch.
  final int head;

  /// Highest cseq of this client the server has handled (committed, rejected or abandoned).
  final int high;
  final List<OpResult> results;

  /// Present iff the request had `resolveFrom`.
  final KnownOutcomes? known;

  Map<String, Object?> toJson() => {
    'head': head,
    'high': high,
    'results': [for (final r in results) r.toJson()],
    if (known != null) 'known': known!.toJson(),
  };
}

/// What the SSE stream carries.
sealed class StreamEvent {
  const StreamEvent();

  /// Parses one SSE message; null for unknown event names (ignored for forward compatibility).
  static StreamEvent? parse(String event, String data) {
    switch (event) {
      case 'commit':
        return CommitEvent(LogEntry.fromJson(jsonDecode(data)));
      case 'snapshot':
        final m = _obj(jsonDecode(data), 'snapshot');
        return SnapshotEvent(
          seq: _int(m, 'seq'),
          doc: Document.fromJson(m['doc']),
          committed: _intMap(m['committed'], (v) => v is int ? v : throw FormatException('bad seq $v')),
        );
      case 'ready':
        return ReadyEvent(_int(_obj(jsonDecode(data), 'ready'), 'head'));
      default:
        return null;
    }
  }
}

/// Full state at [seq], sent when a client cannot be caught up from the log (or has no state).
final class SnapshotEvent extends StreamEvent {
  const SnapshotEvent({required this.seq, required this.doc, this.committed = const {}});

  final int seq;
  final Document doc;

  /// cseq -> seq of the requesting client's ops committed at or before [seq] (cseq >= the `from` query).
  final Map<int, int> committed;
}

final class CommitEvent extends StreamEvent {
  const CommitEvent(this.entry);
  final LogEntry entry;
}

/// Catch-up finished; everything up to [head] (as of subscription) has been delivered.
final class ReadyEvent extends StreamEvent {
  const ReadyEvent(this.head);
  final int head;
}

/// Inbound bytes that did not complete an event: a keep-alive comment or a partial frame. Its only purpose
/// is to prove the connection is alive (the silence watchdog).
final class PingEvent extends StreamEvent {
  const PingEvent();
}

/// `GET /v1/docs/{doc}/events` parameters.
final class StreamOpen {
  const StreamOpen({this.client, this.lastEventId, this.from, this.generation = 0});

  final String? client;

  /// `Last-Event-ID`: the last seq the client applied. null = no state, the server sends a snapshot.
  final int? lastEventId;

  /// Lowest unresolved cseq of this client (limits the `committed` map of a snapshot event).
  final int? from;

  /// Client-side stream generation (not sent on the wire; lets drivers ignore events of dead streams).
  final int generation;

  @override
  String toString() => 'StreamOpen(client=$client lastEventId=$lastEventId from=$from gen=$generation)';
}
