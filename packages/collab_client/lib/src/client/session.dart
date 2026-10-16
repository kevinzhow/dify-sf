import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart';

import '../model/document.dart';
import '../model/ops.dart';
import '../wire/messages.dart';
import 'durable.dart';
import 'events.dart';
import 'machine.dart';
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
    Random? random,
    int Function()? clock,
  }) : _explicitId = clientId,
       _random = random ?? Random(),
       _clock = clock ?? _monotonicClock();

  final String? _explicitId;

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

  final _events = StreamController<ClientEvent>.broadcast();
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

  /// Fires (coalesced) whenever the view, status or pending ops changed. Broadcast.
  Stream<void> get changes => _changes.stream;

  /// What the user sees: confirmed state plus unresolved local ops. Do not mutate; do not retain.
  Document get view => _machine.view;

  Document get confirmed => _machine.confirmed;

  int get lastSeq => _machine.lastSeq;

  bool get hasState => _machine.hasState;

  List<PendingOpInfo> get pending => _machine.pending;

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
    final id = saved?.id ?? _explicitId ?? await transport.issueClientId();
    _machine = saved == null
        ? ClientMachine(id: id, journaled: journaled, config: config, random: _random)
        : ClientMachine.restore(saved, journaled: journaled, config: config, random: _random);
    _running = true;
    _lastQueuedRevision = _machine.durableRevision;
    // Counters must be on disk before anything is sent, even when nothing changed since the last run.
    if (saved == null) _journal?.write(_machine.durable);
    _feed(() => _machine.tick(_clock()));
    _ticker = Timer.periodic(tickInterval, (_) => _feed(() => _machine.tick(_clock())));
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

  /// The OS says connectivity is back: reconnect immediately and resend.
  void networkAvailable() => _feed(() => _machine.networkAvailable(_clock()));

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
    _scheduleChange();
  }

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
      _feed(() {
        _machine.streamClosed(gen, _clock());
        return const [];
      });
    }

    _streamSub = transport
        .openStream(open)
        .listen(
          (e) => _feed(() => _machine.receiveStream(e, gen, _clock())),
          onError: closed,
          onDone: () => closed(null),
          cancelOnError: true,
        );
  }

  /// The id is shared with another process: get a fresh one (retrying while the server is unreachable) and
  /// let the machine re-create the unsaved edits under it.
  Future<void> _replaceClientId() async {
    var attempt = 0;
    while (_running) {
      try {
        final id = await transport.issueClientId();
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
