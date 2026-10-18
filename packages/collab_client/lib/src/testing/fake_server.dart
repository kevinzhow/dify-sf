import 'dart:convert';

import '../model/app_registers.dart';
import '../model/document.dart';
import '../model/ops.dart';
import '../model/templates.dart';
import '../wire/messages.dart';
import 'fake_accounts.dart';
import 'fake_comments.dart';

/// An in-memory implementation of the server side of docs/protocol.md for one document: the sequencer
/// rules (idempotency by `(client, cseq)`, gaps, floor/resolveFrom, stale-write validation), the committed
/// log, and the resume rules of the event stream. Used by tests, the headless CLI's self-hosted mode and
/// the app's demo mode. Deterministic and synchronous; network behaviour lives in `FakeTransport`.
///
/// Accounts (protocol 1.8): with [accounts], every request needs a signed-in member (the transports send their
/// `TokenProvider`'s token; see [FakeAccounts]), writes need the edit role, client ids belong to the account that got or
/// first used them ([clientAccounts]), names come from the accounts and comments are by account. Without [accounts]
/// (the default) nothing is checked and names are the clients' display names, as before 1.8.
class FakeServer {
  FakeServer({Document? initial, this.maxReplay = 2000, this.accounts}) : doc = initial ?? Templates.example();

  /// The workspace's accounts; null = no authentication (pre-1.8 behaviour).
  final FakeAccounts? accounts;

  /// client id -> account id (protocol 1.8; with [accounts] only).
  final Map<String, String> clientAccounts = {};

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

  /// Display names by client id (protocol 1.3; without [accounts]).
  final Map<String, String> names = {};

  /// The document's canvas comments (`/comments`), beside the document (not in it, not in the log). With [accounts] the
  /// authors are accounts; without, client ids.
  late final FakeComments comments = FakeComments(
    () => accounts == null
        ? {for (final e in names.entries) e.key: (name: e.value, avatarUrl: null)}
        : {for (final a in accounts!.byId.values) a.id: (name: a.name, avatarUrl: a.avatarUrl)},
    members: () => accounts?.byId.values.where((a) => a.role != null).map((a) => a.id).toSet(),
  );

  /// The name shown for [client]: its account's name (1.8), else its display name (1.3).
  String? nameOf(String client) {
    final a = accounts;
    if (a == null) return names[client];
    final id = clientAccounts[client];
    return id == null ? null : a.byId[id]?.name;
  }

  /// `GET /clients` (protocol 1.8 shape): client id -> `{"account","name","avatar_url"?}`. Without [accounts], every named
  /// client id is its own "account".
  Map<String, Map<String, Object?>> directory() {
    final a = accounts;
    if (a == null) {
      return {
        for (final e in names.entries) e.key: {'account': e.key, 'name': e.value},
      };
    }
    return {
      for (final e in clientAccounts.entries)
        if (a.byId[e.value] != null)
          e.key: {'account': e.value, 'name': a.byId[e.value]!.name, 'avatar_url': ?a.byId[e.value]!.avatarUrl},
    };
  }

  /// Protocol 1.8: [client] must belong to [account]; a free id is bound to it ([bind]) or left alone. Throws
  /// `403 forbidden` for someone else's id.
  void requireOwnClient(String client, String account, {bool bind = true}) {
    final owner = clientAccounts[client];
    if (owner == null) {
      if (bind) clientAccounts[client] = account;
      return;
    }
    if (owner != account) throw FakeAuthError(403, 'forbidden', 'client id $client belongs to another account');
  }

  /// Plaintext of secret environment variables by reference (protocol 1.7, `POST /v1/docs/{doc}/secrets`).
  final Map<String, String> secrets = {};
  int _secretsIssued = 0;

  /// `POST /v1/docs/{doc}/secrets`: stores [value] aside and returns its reference (`sec-` plus 32 hex digits) and
  /// Dify's mask. The plaintext never enters the document.
  ({String ref, String masked}) storeSecret(String value) {
    final ref = 'sec-${(++_secretsIssued).toRadixString(16).padLeft(32, '0')}';
    secrets[ref] = value;
    return (ref: ref, masked: AppRegisters.maskSecret(value));
  }

  /// `POST /v1/docs/{doc}/clients`: a fresh id, `s-` plus 32 hex digits. With [account] (1.8) it is bound to it and
  /// [name] is ignored; without, [name] registers a display name (protocol 1.3).
  String issueClientId({String? name, String? account}) {
    final id = 's-${(++_issued).toRadixString(16).padLeft(32, '0')}';
    if (account != null) {
      clientAccounts[id] = account;
    } else if (name != null) {
      names[id] = name;
    }
    return id;
  }

  /// `PUT /v1/docs/{doc}/clients/{client}`: with [account] (1.8) it binds a free id (`403` for someone else's) and
  /// ignores [name]; without, it names the id (protocol 1.3).
  void setClientName(String client, String name, {String? account}) {
    if (account != null) {
      requireOwnClient(client, account);
    } else {
      names[client] = name;
    }
  }

  /// Fills in `byName` at answer time, like the reference server: a retransmit may carry a name registered later.
  RejectReason _named(RejectReason r) => switch (r) {
    Conflict(:final node, :final field, :final seq, :final by) when nameOf(by) != null => Conflict(
      node: node,
      field: field,
      seq: seq,
      by: by,
      byName: nameOf(by),
    ),
    _ => r,
  };
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
        results.add(
          s != null ? AckResult(cseq, s) : RejectResult(cseq, _named(rejected[cseq] ?? const NotCommitted())),
        );
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
        results.add(RejectResult(cseq, _named(bad)));
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
            if (e.key >= from && e.key <= high) e.key: _named(e.value),
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

  /// What a newly opened stream receives first (catch-up), ending with `ready`. A stream opened with an older [proto]
  /// gets a snapshot instead of a replay that contains a commit it cannot decode ([StreamCompat]).
  List<StreamEvent> catchUp({int? lastEventId, String? client, int? from, String? proto = protocolVersion}) {
    final n = lastEventId;
    if (n == null ||
        n < 0 ||
        n > head ||
        head - n > maxReplay ||
        log.skip(n).any((e) => !StreamCompat.streamCarries(e.op, proto))) {
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
