import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart';

import '../model/document.dart';
import '../model/ops.dart';
import '../wire/messages.dart';
import 'display_name.dart';
import 'durable.dart';
import 'events.dart';
import 'machine.dart';
import 'replace.dart';
import 'store.dart';
import 'transport.dart';

/// Coarse connection state for the UI.
enum LinkState {
  /// First connection attempt, no document yet.
  connecting,

  /// The stream delivered everything up to the head and is live.
  live,

  /// The stream dropped; retrying.
  reconnecting,

  /// Several attempts failed in a row. Edits are kept and sent when the network is back.
  offline,
}

/// Snapshot of the numbers a status bar shows.
final class SessionStatus {
  const SessionStatus({
    required this.link,
    required this.pending,
    required this.lastSeq,
    required this.hasState,
    this.lastError,
  });

  final LinkState link;

  /// Unresolved (unacked or not yet visible) local ops.
  final int pending;
  final int lastSeq;
  final bool hasState;
  final String? lastError;
}

/// Returned by [CollabSession.edit].
final class EditTicket {
  const EditTicket({required this.cseq, required this.persisted, this.refusal});

  /// null if the edit was refused locally (a [LocalInvalid] event was emitted).
  final int? cseq;

  /// Why the edit was refused locally (set iff [cseq] is null).
  final RejectReason? refusal;

  /// Completes when the op is in the write-ahead journal (and may therefore be sent).
  final Future<void> persisted;
}

/// Drives a [ClientMachine] against a [CollabTransport]: timers, the POST loop, the event stream
/// subscription, and write-ahead persistence through a [DurableStore].
///
/// Write-ahead rule: a POST is only sent after the state that includes its ops (and the counters) has been
/// saved. A crash at any instant therefore leaves a journal that is a superset of what the server may have
/// seen.
class CollabSession {
  /// [clientId] is normally omitted: the session then uses the id saved in its journal, or asks the server for a
  /// fresh one (`POST /v1/docs/{doc}/clients`, protocol 1.1) when there is none. An explicit id is for tests and
  /// tools that manage ids themselves (it must match the journal's, if the journal has one).
  CollabSession({
    String? clientId,
    required this.transport,
    this.store,
    this.journaled = true,
    this.config = const ClientConfig(),
    this.tickInterval = const Duration(milliseconds: 200),
    this.postTimeout = const Duration(seconds: 10),
    String? displayName,
    Random? random,
    int Function()? clock,
  }) : _explicitId = clientId,
       displayName = displayName == null ? null : normalizeDisplayName(displayName),
       _random = random ?? Random(),
       _clock = clock ?? _monotonicClock();

  final String? _explicitId;

  /// Shown to others in conflict notices (protocol 1.3), already normalized; null = unnamed. Registered with a
  /// freshly issued id, or best-effort (`PUT /clients/{id}`) for an id that came from the journal or the caller.
  final String? displayName;

  /// The id this session sends under. Empty until [start] completes when it has to be issued by the server;
  /// can change once if the id turns out to be shared ([ClientIdReplaced]).
  String get clientId => _machine.id;

  final CollabTransport transport;
  final bool journaled;
  final ClientConfig config;
  final Duration tickInterval;
  final Duration postTimeout;

  /// Where the write-ahead journal lives; null = nothing is persisted (not even the counters).
  final DurableStore? store;
  final Random _random;
  final int Function() _clock;

  late ClientMachine _machine = ClientMachine(
    id: _explicitId ?? '',
    journaled: journaled,
    config: config,
    random: _random,
  );
  Timer? _ticker;
  StreamSubscription<StreamEvent>? _streamSub;
  int _postSeq = 0;
  bool _running = false;
  bool _everLive = false;
  String? _lastError;
  bool _appDeleted = false;

  final _events = StreamController<ClientEvent>.broadcast();
  final _comments = StreamController<CommentsEvent>.broadcast();
  final _changes = StreamController<void>.broadcast();
  bool _changeScheduled = false;
  final List<Completer<void>> _idleWaiters = [];

  late final _WriteBehind? _journal = store == null ? null : _WriteBehind(store!);

  static int Function() _monotonicClock() {
    final sw = clock.stopwatch()..start(); // `clock` is the system clock unless a test fakes time
    return () => sw.elapsedMilliseconds;
  }

  // ---- public surface ----------------------------------------------------------------------------

  /// Terminal outcomes and warnings for the user's edits (see [ClientEvent]). Broadcast.
  Stream<ClientEvent> get events => _events.stream;

  /// Canvas comment notifications (docs/protocol.md, "Comments"): every `event: comments` of the stream, plus a
  /// [CommentsAction.resync] each time the stream reaches `ready` (first connect and every reconnect), since
  /// notifications missed while disconnected are not replayed. Refetch on each (`transport.comments`). Broadcast.
  Stream<CommentsEvent> get comments => _comments.stream;

  /// Fires (coalesced) whenever the view, status or pending ops changed. Broadcast.
  Stream<void> get changes => _changes.stream;

  /// What the user sees: confirmed state plus unresolved local ops. Do not mutate; do not retain.
  Document get view => _machine.view;

  Document get confirmed => _machine.confirmed;

  int get lastSeq => _machine.lastSeq;

  bool get hasState => _machine.hasState;

  List<PendingOpInfo> get pending => _machine.pending;

  /// Protocol 1.10: the document's app was deleted (a `POST /ops` or the event stream answered `404 app_deleted`). The
  /// session then stops syncing for good (no retries; [changes] fires, [status] has the reason): its unsaved ops can never
  /// be committed. The app should tell the user, leave the editor (back to the Studio) and drop the document's journal.
  bool get appDeleted => _appDeleted;

  /// Diagnostic access to the state machine (tests, CLI).
  ClientMachine get machine => _machine;

  SessionStatus get status => SessionStatus(
    link: link,
    pending: _machine.unresolvedCount,
    lastSeq: _machine.lastSeq,
    hasState: _machine.hasState,
    lastError: _lastError,
  );

  LinkState get link {
    final m = _machine;
    if (m.streamReady) return LinkState.live;
    if (m.reconnectAttempts >= 3 || m.submitFailures >= 3) return LinkState.offline;
    if (!_everLive && !m.hasState) return LinkState.connecting;
    return LinkState.reconnecting;
  }

  /// Loads the journal (if any), then connects and starts syncing. When there is no journal and no explicit
  /// id, this asks the server for a client id first and throws a [TransportException] if that fails.
  Future<void> start() async {
    final saved = await store?.load();
    if (saved != null && _explicitId != null && saved.id != _explicitId) {
      throw StateError('journal belongs to client ${saved.id}, not $_explicitId');
    }
    final reused = saved?.id ?? _explicitId;
    final id = reused ?? await transport.issueClientId(name: displayName);
    _machine = saved == null
        ? ClientMachine(id: id, journaled: journaled, config: config, random: _random)
        : ClientMachine.restore(saved, journaled: journaled, config: config, random: _random);
    _running = true;
    _lastQueuedRevision = _machine.durableRevision;
    // Counters must be on disk before anything is sent, even when nothing changed since the last run.
    if (saved == null) _journal?.write(_machine.durable);
    _feed(() => _machine.tick(_clock()));
    _ticker = Timer.periodic(tickInterval, (_) => _feed(() => _machine.tick(_clock())));
    if (reused != null && displayName != null) unawaited(_registerName(reused, displayName!));
  }

  /// Names an id this session did not get from `POST /clients` just now. Retries while the server is unreachable;
  /// a refusal or a stopped session ends it. A missing name only affects how others see this client.
  Future<void> _registerName(String id, String name) async {
    var attempt = 0;
    while (_running && _machine.id == id) {
      try {
        await transport.setClientName(id, name);
        return;
      } on TransportException catch (e) {
        if (e.statusCode != null && e.statusCode! < 500) return;
        attempt++;
        await Future<void>.delayed(Duration(milliseconds: min(15000, 500 << min(attempt, 5))));
      } on Object {
        return;
      }
    }
  }

  /// Applies a user edit locally (optimistic) and queues it for the server. [base] is the version the user
  /// saw when they began the edit (see [ClientMachine.edit]); omit it for instantaneous edits.
  EditTicket edit(Op op, {int? base}) {
    final r = _machine.edit(op, _clock(), base: base);
    _afterMachine();
    // Nothing to persist for an edit that never became an op; and a caller that ignores `persisted` must not
    // turn a failed journal write into an uncaught error (the write failure already blocks the send).
    final persisted = r.cseq == null ? Future<void>.value() : _persistedFuture()
      ..ignore();
    _execute(r.requests);
    return EditTicket(cseq: r.cseq, persisted: persisted, refusal: r.refusal);
  }

  /// A `POST /ops` was refused with `403 forbidden` (protocol 1.8): nothing is sent and new edits are refused until
  /// [allowEdits]. [EditingForbidden] announced it; show the editor read-only.
  bool get editsForbidden => _machine.editsForbidden;

  /// The account may edit again (after [EditingForbidden] the app re-read it, `GET /v1/account`, and its role is an
  /// edit role): accept edits and resume sending.
  void allowEdits() => _feed(() => _machine.allowEdits(_clock()));

  /// The OS says connectivity is back: reconnect immediately and resend.
  void networkAvailable() => _feed(() => _machine.networkAvailable(_clock()));

  /// Replaces the document with a Dify workflow file (`POST /v1/docs/{doc}/replace`, docs/protocol.md section 9, "Replacing
  /// the document"): refuses new edits, waits until every local op is resolved, then calls [send] with this session's
  /// client id and the cseq to reserve (typically `(id, cseq) => api.replaceDocument(doc, yaml, id, cseq: cseq)`), and
  /// continues at the answer's `next_cseq`. A timeout, a transport error or a `5xx` is retried with the identical
  /// request (the server answers a committed replacement as `replayed`); any other failure is rethrown with nothing
  /// changed. Completes once the stream has delivered the replacement (or after [settleTimeout]), so [view] shows it.
  /// Edits are accepted again afterwards, also after a failure. Throws [TimeoutException] if the local ops do not
  /// resolve within [readyTimeout].
  Future<ReplaceResult> replaceDocument(
    Future<ReplaceResult> Function(String clientId, int cseq) send, {
    Duration readyTimeout = const Duration(seconds: 30),
    Duration settleTimeout = const Duration(seconds: 10),
  }) async {
    if (!_running) throw StateError('the session is not running');
    if (_machine.replacing) throw StateError('a replacement is already under way');
    _machine.beginReplace();
    _afterMachine();
    try {
      final ready = Stopwatch()..start();
      int? cseq;
      while ((cseq = _machine.replaceCseq) == null) {
        if (!_running) throw StateError('the session stopped');
        if (_machine.editsForbidden) {
          throw const TransportException('editing is not allowed', statusCode: 403, code: 'forbidden');
        }
        if (ready.elapsed > readyTimeout) throw TimeoutException('local edits did not resolve', readyTimeout);
        await _nextChange(tickInterval);
      }
      final id = _machine.id;
      ReplaceResult result;
      var attempt = 0;
      while (true) {
        try {
          result = await send(id, cseq!);
          break;
        } on DslVersionUnconfirmed {
          rethrow;
        } on TransportException catch (e) {
          final uncertain = e.timeout || e.statusCode == null || e.statusCode! >= 500;
          if (!uncertain || !_running || ++attempt >= 4) rethrow;
          await Future<void>.delayed(Duration(milliseconds: 500 << attempt));
        }
      }
      _machine.finishReplace(result.nextCseq);
      _afterMachine();
      await _persistedFuture();
      final settle = Stopwatch()..start();
      while (_running && _machine.lastSeq < result.head && settle.elapsed < settleTimeout) {
        await _nextChange(tickInterval);
      }
      return result;
    } finally {
      if (_machine.replacing) {
        _machine.abortReplace();
        _afterMachine();
      }
    }
  }

  /// Waits for the next announced change, at most [max].
  Future<void> _nextChange(Duration max) =>
      _changes.stream.first.timeout(max, onTimeout: () {}).catchError((Object _) {});

  /// Completes when every local op has a terminal outcome and the stream is live.
  Future<void> settled() {
    if (_isSettled) return Future.value();
    final c = Completer<void>();
    _idleWaiters.add(c);
    return c.future;
  }

  bool get _isSettled => _machine.isQuiescent;

  /// Stops timers and connections. State already in the store stays there (use for a clean shutdown or to
  /// simulate a crash: nothing further is flushed).
  Future<void> stop() async {
    _running = false;
    _ticker?.cancel();
    await _streamSub?.cancel();
    _streamSub = null;
    transport.close();
    await _events.close();
    await _comments.close();
    await _changes.close();
  }

  // ---- driver ------------------------------------------------------------------------------------

  int _lastQueuedRevision = 0;

  void _feed(List<ClientRequest> Function() step) {
    if (!_running) return;
    final requests = step();
    _afterMachine();
    _execute(requests);
  }

  void _afterMachine() {
    if (_machine.durableRevision != _lastQueuedRevision) {
      _lastQueuedRevision = _machine.durableRevision;
      _journal?.write(_machine.durable);
    }
    for (final e in _machine.drainEvents()) {
      if (!_events.isClosed) _events.add(e);
    }
    if (!_machine.streamActive) _cancelStream();
    if (_machine.streamReady) _everLive = true;
    if (_isSettled) {
      for (final c in _idleWaiters) {
        c.complete();
      }
      _idleWaiters.clear();
    }
    // The periodic tick runs the machine every [tickInterval]; only announce a change when something a listener can
    // observe moved (a steady editor must not rebuild five times a second).
    final fingerprint = Object.hash(
      _machine.viewRevision,
      _machine.durableRevision,
      link,
      _machine.unresolvedCount,
      _machine.lastSeq,
      _machine.hasState,
      _lastError,
    );
    if (fingerprint == _lastFingerprint) return;
    _lastFingerprint = fingerprint;
    _scheduleChange();
  }

  int? _lastFingerprint;

  void _scheduleChange() {
    if (_changeScheduled || _changes.isClosed) return;
    _changeScheduled = true;
    scheduleMicrotask(() {
      _changeScheduled = false;
      if (!_changes.isClosed) _changes.add(null);
    });
  }

  Future<void> _persistedFuture() => _journal?.flushed() ?? Future.value();

  void _execute(List<ClientRequest> requests) {
    for (final r in requests) {
      switch (r) {
        case OpenStreamAction(:final open):
          _openStream(open);
        case SubmitRequestAction(:final request):
          unawaited(_runSubmit(request));
        case RequestClientIdAction():
          unawaited(_replaceClientId());
      }
    }
  }

  void _cancelStream() {
    final sub = _streamSub;
    _streamSub = null;
    if (sub != null) unawaited(sub.cancel());
  }

  void _openStream(StreamOpen open) {
    _cancelStream();
    final gen = open.generation;
    void closed(Object? error) {
      if (error != null) _lastError = '$error';
      if (_isAppDeleted(error)) return _onAppDeleted();
      _feed(() {
        _machine.streamClosed(gen, _clock());
        return const [];
      });
    }

    _streamSub = transport
        .openStream(open)
        .listen(
          (e) {
            _feed(() => _machine.receiveStream(e, gen, _clock()));
            if (_comments.isClosed || !_running || gen != _machine.generation) return;
            if (e is CommentsEvent) {
              _comments.add(e);
            } else if (e is ReadyEvent) {
              _comments.add(const CommentsEvent.resync());
            }
          },
          onError: closed,
          onDone: () => closed(null),
          cancelOnError: true,
        );
  }

  static bool _isAppDeleted(Object? e) => e is TransportException && e.statusCode == 404 && e.code == 'app_deleted';

  /// Protocol 1.10: the app is gone for good. Stop everything that would retry, tell the app once.
  void _onAppDeleted() {
    if (_appDeleted || !_running) return;
    _appDeleted = true;
    _running = false;
    _lastError = 'the app was deleted';
    _ticker?.cancel();
    _cancelStream();
    _scheduleChange();
  }

  /// The id is shared with another process: get a fresh one (retrying while the server is unreachable) and
  /// let the machine re-create the unsaved edits under it.
  Future<void> _replaceClientId() async {
    var attempt = 0;
    while (_running) {
      try {
        final id = await transport.issueClientId(name: displayName);
        if (!_running) return;
        _feed(() => _machine.adoptClientId(id, _clock()));
        return;
      } on Object catch (e) {
        _lastError = 'could not get a new client id: $e';
        attempt++;
        await Future<void>.delayed(Duration(milliseconds: min(15000, 500 << min(attempt, 5))));
      }
    }
  }

  Future<void> _runSubmit(SubmitRequest request) async {
    final id = ++_postSeq;
    try {
      // Write-ahead: the journal must contain these ops before they leave the process.
      await _persistedFuture();
      if (!_running || id != _postSeq) return;
      final response = await transport.submit(request, timeout: postTimeout);
      if (!_running || id != _postSeq) return;
      _lastError = null;
      _feed(() => _machine.receiveResponse(response, _clock()));
    } on Object catch (e) {
      if (!_running || id != _postSeq) return;
      _lastError = '$e';
      if (_isAppDeleted(e)) return _onAppDeleted();
      if (e is TransportException && e.forbidden) {
        // Final for these ops (read-only role, or another account's client id): not retried, see submitForbidden.
        _feed(() => _machine.submitForbidden(_clock()));
        return;
      }
      _feed(() {
        if (e is TransportException && e.payloadTooLarge) _machine.shrinkBatch();
        _machine.submitFailed(_clock());
        return const [];
      });
    }
  }
}

/// Coalescing write-behind for the journal: always writes the latest state, never reorders, and lets
/// callers wait until everything requested so far is durable.
class _WriteBehind {
  _WriteBehind(this._store);

  final DurableStore _store;
  ClientDurable? _latest;
  bool _writing = false;

  /// Waiting for the save that is currently in flight / for the next save.
  List<Completer<void>> _inFlight = [];
  final List<Completer<void>> _next = [];

  void write(ClientDurable state) {
    _latest = state;
    _kick();
  }

  /// Completes when the latest requested state is durable; completes with an error if saving failed.
  Future<void> flushed() {
    if (_latest == null && !_writing) return Future.value();
    final c = Completer<void>();
    // If nothing newer than the in-flight save was requested, that save covers the caller.
    (_latest == null ? _inFlight : _next).add(c);
    _kick();
    return c.future;
  }

  void _kick() {
    if (_writing) return;
    _writing = true;
    unawaited(_loop());
  }

  Future<void> _loop() async {
    while (_latest != null) {
      final state = _latest!;
      _latest = null;
      _inFlight = List.of(_next);
      _next.clear();
      try {
        await _store.save(state);
        for (final w in _inFlight) {
          w.complete();
        }
        _inFlight = [];
      } on Object catch (e) {
        // Not saved: keep it as the pending state (unless something newer arrived) and fail the waiters, so
        // the driver does not send. The next flushed() call retries the write.
        _latest ??= state;
        for (final w in _inFlight) {
          w.completeError(e);
        }
        _inFlight = [];
        _writing = false;
        return;
      }
    }
    _writing = false;
  }
}
