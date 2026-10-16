import '../model/ops.dart';

/// What the UI should surface about the fate of the user's edits. Exactly one terminal event
/// ([OpCommitted], [OpRejected], [OpLost]) is reported per op, in cseq order (at-least-once across a
/// process crash: a crash between reporting and persisting repeats the same outcome).
sealed class ClientEvent {
  const ClientEvent();
}

/// The op is durably committed at global sequence [seq] and visible in the confirmed document.
final class OpCommitted extends ClientEvent {
  const OpCommitted({required this.cseq, required this.seq, this.op});
  final int cseq;
  final int seq;

  /// Null when the content was no longer known (an op resolved after a crash of a volatile client).
  final Op? op;
}

/// Not saved. [op] is included so the UI can offer "re-apply mine on top of the latest".
final class OpRejected extends ClientEvent {
  const OpRejected({required this.cseq, required this.op, required this.reason});
  final int cseq;
  final Op op;
  final RejectReason reason;
}

/// Not saved, and the content could not be recovered (a non-journaled client crashed before the server
/// handled the op).
final class OpLost extends ClientEvent {
  const OpLost({required this.cseq});
  final int cseq;
}

/// Early warning: a newer remote write already makes this pending op doomed. The terminal [OpRejected]
/// follows when the server confirms. The op is hidden from the local view meanwhile.
final class ConflictDetected extends ClientEvent {
  const ConflictDetected({required this.cseq, required this.op, required this.reason});
  final int cseq;
  final Op op;
  final RejectReason reason;
}

/// The edit was refused locally (e.g. the node is already gone); it never became an op.
final class LocalInvalid extends ClientEvent {
  const LocalInvalid({required this.op, required this.reason});
  final Op op;
  final RejectReason reason;
}
