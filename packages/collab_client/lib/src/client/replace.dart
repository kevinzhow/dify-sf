import 'transport.dart';

/// The answer of `POST /v1/docs/{id}/replace` ([DocsApi.replaceDocument]; docs/protocol.md section 2, "Replacing a
/// document").
final class ReplaceResult {
  const ReplaceResult({
    required this.head,
    required this.ops,
    required this.nodes,
    required this.edges,
    required this.nextCseq,
    this.replayed = false,
    this.status = 'completed',
    this.importedDslVersion = '',
    this.currentDslVersion = '',
    this.renamedNodes = const {},
    this.renamedEdges = const {},
  });

  factory ReplaceResult.fromJson(Map<String, Object?> json) {
    final renamed = json['renamed'] is Map<String, Object?> ? json['renamed']! as Map<String, Object?> : const {};
    Map<String, String> ids(Object? v) => {
      if (v is Map<String, Object?>)
        for (final e in v.entries)
          if (e.value is String) e.key: e.value! as String,
    };
    return ReplaceResult(
      head: json['head']! as int,
      ops: json['ops']! as int,
      nodes: json['nodes'] as int? ?? 0,
      edges: json['edges'] as int? ?? 0,
      nextCseq: json['next_cseq']! as int,
      replayed: json['replayed'] as bool? ?? false,
      status: json['status'] as String? ?? 'completed',
      importedDslVersion: json['imported_dsl_version'] as String? ?? '',
      currentDslVersion: json['current_dsl_version'] as String? ?? '',
      renamedNodes: ids(renamed['nodes']),
      renamedEdges: ids(renamed['edges']),
    );
  }

  /// The head after the replacement (its ops are on the stream up to here).
  final int head;

  /// How many ops it committed (the client's cseqs `cseq ... nextCseq - 1`).
  final int ops;

  /// Node and edge counts of the document after it.
  final int nodes;
  final int edges;

  /// The client's next cseq: the session continues from here.
  final int nextCseq;

  /// A retry of a replacement that was committed already (nothing was written now).
  final bool replayed;

  /// Dify's import status: `completed`, `completed-with-warnings` (show Dify's "DSL version difference may affect certain
  /// features"), `pending` (a confirmed version mismatch).
  final String status;
  final String importedDslVersion;
  final String currentDslVersion;

  /// File ids that could not be kept (tombstoned, or of another type): file id -> id in the document.
  final Map<String, String> renamedNodes;
  final Map<String, String> renamedEdges;

  bool get hasWarnings => status == 'completed-with-warnings';
}

/// `POST /replace` refused a file whose DSL version needs the user's confirmation (Dify's pending import:
/// `400 version_unconfirmed`). Show Dify's version dialog, then repeat with `confirm: true`.
class DslVersionUnconfirmed extends TransportException {
  const DslVersionUnconfirmed(super.message, {required this.importedVersion, required this.currentVersion})
    : super(statusCode: 400, code: 'version_unconfirmed');

  final String importedVersion;
  final String currentVersion;
}
