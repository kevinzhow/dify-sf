import '../model/ops.dart';

/// How one intended edit ended, from the user's point of view.
enum LedgerStatus {
  /// No terminal outcome has been reported (a violation once the run has settled).
  pending,

  /// Committed at [LedgerEntry.seq]: durable on the server.
  committed,

  /// Refused by the server; had no effect.
  rejected,

  /// A volatile client crashed before the server handled it; the content is gone (and the user was told).
  lost,

  /// Refused locally; it never became an op.
  localInvalid,

  /// The process crashed before the write-ahead journal had the op: the user was never promised anything.
  unpersisted,
}

/// Ground truth about one intended edit.
class LedgerEntry {
  LedgerEntry({
    required this.client,
    required this.wireClient,
    required this.incarnation,
    required this.op,
    required this.intentMs,
    this.cseq,
    this.reappliesCseq,
  });

  /// The logical client (stable across crashes).
  final String client;

  /// The protocol client id the op was sent under (server-issued; can change after a crash that lost the
  /// journal, or when the id turned out to be shared).
  String wireClient;

  /// Which process lifetime of the client issued it (bumped on every simulated crash).
  final int incarnation;
  final Op op;
  final int intentMs;
  int? cseq;

  /// Set when this edit re-applies a rejected one (the user clicked "re-apply on latest").
  final int? reappliesCseq;

  LedgerStatus status = LedgerStatus.pending;
  int? seq;
  RejectReason? reason;
  int? outcomeMs;
  int? persistedMs;

  /// The client showed the early conflict warning for it.
  bool warned = false;

  Map<String, Object?> toJson() => {
    'client': client,
    'incarnation': incarnation,
    'cseq': cseq,
    'op': op.toJson(),
    'intentMs': intentMs,
    if (persistedMs != null) 'persistedMs': persistedMs,
    'status': status.name,
    if (seq != null) 'seq': seq,
    if (reason != null) 'reason': reason!.toJson(),
    if (outcomeMs != null) 'outcomeMs': outcomeMs,
    if (warned) 'warned': true,
    if (reappliesCseq != null) 'reappliesCseq': reappliesCseq,
  };
}
