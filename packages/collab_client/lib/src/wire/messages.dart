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
      case 'comments':
        return CommentsEvent.fromJson(jsonDecode(data));
      case 'app':
        return const AppEvent();
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

/// What changed in a [CommentsEvent].
enum CommentsAction {
  created,
  updated,
  deleted,
  resolved,

  /// A reply of the comment was created, edited or deleted.
  reply,

  /// Never sent by the server: `CollabSession.comments` emits it whenever the event stream (re)connected (on `ready`).
  /// Notifications are not replayed, so anything may have changed meanwhile: refetch everything.
  resync,

  /// An action this client does not know (sent by a newer server): treat as "this comment changed".
  unknown;

  static CommentsAction parse(Object? s) =>
      values.firstWhere((a) => a.name == s && a != resync && a != unknown, orElse: () => unknown);
}

/// `event: comments` (canvas comments, additive): comment [comment] changed. A best-effort notification without an SSE
/// `id`: it does not move the resume point, and the machine treats it as liveness only. Refetch the comments
/// (`GET /comments`) on it; the REST list is the truth.
final class CommentsEvent extends StreamEvent {
  const CommentsEvent({required this.comment, required this.action});

  /// The local "stream (re)connected" signal ([CommentsAction.resync]); [comment] is empty.
  const CommentsEvent.resync() : comment = '', action = CommentsAction.resync;

  factory CommentsEvent.fromJson(Object? json) {
    final m = _obj(json, 'comments');
    final id = m['comment'];
    if (id is! String) throw FormatException('comments event without a comment id: $json');
    return CommentsEvent(comment: id, action: CommentsAction.parse(m['action']));
  }

  final String comment;
  final CommentsAction action;

  @override
  bool operator ==(Object other) => other is CommentsEvent && other.comment == comment && other.action == action;

  @override
  int get hashCode => Object.hash(comment, action);

  @override
  String toString() => 'CommentsEvent(${action.name}, $comment)';
}

/// `event: app` (protocol 1.11, additive): the document's app changed (what `GET /v1/apps/{app}` answers: name, icon,
/// description, site, switches). A notification only, like [CommentsEvent]: no `id`, not replayed; clients refetch the
/// app (Dify's `app_meta_update`).
final class AppEvent extends StreamEvent {
  const AppEvent({this.resync = false});

  /// The local "stream (re)connected" signal: changes missed while disconnected are not replayed, so refetch too.
  const AppEvent.resync() : resync = true;

  final bool resync;

  @override
  bool operator ==(Object other) => other is AppEvent && other.resync == resync;

  @override
  int get hashCode => resync.hashCode;

  @override
  String toString() => resync ? 'AppEvent(resync)' : 'AppEvent()';
}

/// The protocol version this package implements (docs/protocol.md). Sent as `proto` when opening the event stream, so
/// the server includes ops added in 1.6 (`restoreNode`) and 1.7 (writes of the document-level registers, `$app`) in it.
const protocolVersion = '1.7';

/// Which commits a stream opened with a given `proto` may carry (mirrors `StreamCompat` in the Swift core). A stream
/// without `proto`, or below 1.6, never carries a `restoreNode`; one below 1.7 never carries a write of `$app`. The
/// server answers such a stream with a snapshot instead of a replay containing one, and ends it instead of sending one
/// live.
abstract final class StreamCompat {
  /// Parses `major.minor`; null when [proto] is not a version (the server answers 400).
  static (int, int)? parse(String proto) {
    final m = RegExp(r'^([0-9]+)\.([0-9]+)$').firstMatch(proto);
    if (m == null) return null;
    return (int.parse(m[1]!), int.parse(m[2]!));
  }

  static bool _atLeast(String? proto, int minor) {
    final p = proto == null ? null : parse(proto);
    if (p == null) return false;
    return p.$1 > 1 || (p.$1 == 1 && p.$2 >= minor);
  }

  /// True when a stream opened with [proto] may carry `restoreNode` commits (1.6).
  static bool acceptsRestore(String? proto) => _atLeast(proto, 6);

  /// True when a stream opened with [proto] may carry writes of the document-level registers (1.7).
  static bool acceptsApp(String? proto) => _atLeast(proto, 7);

  /// True when [op] may be sent as a commit event on a stream opened with [proto].
  static bool streamCarries(Op op, String? proto) {
    if (op is RestoreNode) return acceptsRestore(proto);
    if (op.touchesApp) return acceptsApp(proto);
    return true;
  }
}

/// `GET /v1/docs/{doc}/events` parameters.
final class StreamOpen {
  const StreamOpen({this.client, this.lastEventId, this.from, this.generation = 0, this.proto = protocolVersion});

  final String? client;

  /// `Last-Event-ID`: the last seq the client applied. null = no state, the server sends a snapshot.
  final int? lastEventId;

  /// Lowest unresolved cseq of this client (limits the `committed` map of a snapshot event).
  final int? from;

  /// Client-side stream generation (not sent on the wire; lets drivers ignore events of dead streams).
  final int generation;

  /// `proto` query parameter (protocol 1.6). null plays a client older than 1.6: the server never sends it a commit it
  /// cannot decode (it gets a snapshot instead), see [StreamCompat].
  final String? proto;

  @override
  String toString() => 'StreamOpen(client=$client lastEventId=$lastEventId from=$from gen=$generation proto=$proto)';
}
