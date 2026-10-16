import '../model/ops.dart';

/// One write-ahead journal entry.
final class JournalEntry {
  const JournalEntry({required this.cseq, required this.base, required this.op});

  factory JournalEntry.fromJson(Object? json) {
    final m = json! as Map<String, Object?>;
    return JournalEntry(cseq: m['cseq']! as int, base: m['base']! as int, op: Op.fromJson(m['op']));
  }

  final int cseq;
  final int base;
  final Op op;

  Map<String, Object?> toJson() => {'cseq': cseq, 'base': base, 'op': op.toJson()};
}

/// The part of client state that survives a crash/reload (a file, IndexedDB, ...).
///
/// [journal] is only written by journaled clients (write-ahead outbox); every client persists the two
/// counters, so even a volatile client can tell *which* ops it lost.
final class ClientDurable {
  const ClientDurable({
    required this.id,
    required this.nextCseq,
    required this.unresolvedFrom,
    this.journal = const [],
  });

  factory ClientDurable.fromJson(Object? json) {
    final m = json! as Map<String, Object?>;
    if (m['v'] != 1) throw FormatException('unsupported journal version ${m['v']}');
    return ClientDurable(
      id: m['id']! as String,
      nextCseq: m['nextCseq']! as int,
      unresolvedFrom: m['unresolvedFrom']! as int,
      journal: [for (final e in m['journal']! as List<Object?>) JournalEntry.fromJson(e)],
    );
  }

  final String id;
  final int nextCseq;
  final int unresolvedFrom;
  final List<JournalEntry> journal;

  Map<String, Object?> toJson() => {
        'v': 1,
        'id': id,
        'nextCseq': nextCseq,
        'unresolvedFrom': unresolvedFrom,
        'journal': [for (final e in journal) e.toJson()],
      };
}
