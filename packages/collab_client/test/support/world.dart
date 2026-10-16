import 'dart:async';
import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:fake_async/fake_async.dart';

/// One simulated user: a [CollabSession] over a [FakeTransport] with its own network conditions and its own
/// journal. Survives (simulated) crashes: [crash] drops the in-memory state, [restart] boots a new session
/// from whatever the store holds.
class Participant {
  Participant(this.world, this.id, {required this.journaled, Random? random, this.wireId, this.serverIssuedId = false})
    : net = FakeNetwork(random: random ?? Random(id.hashCode)),
      _random = random ?? Random(id.hashCode ^ 0x5bd1) {
    transport = FakeTransport(world.server, network: net);
  }

  final World world;
  final String id;
  final bool journaled;

  /// The protocol client id to use, when it should differ from [id] (two "tabs" sharing one id). `null` = [id]
  /// as the explicit id.
  final String? wireId;

  /// Let the session get its id from the server (protocol 1.1) instead of passing one.
  final bool serverIssuedId;
  final FakeNetwork net;
  final Random _random;
  final MemoryStore store = MemoryStore();
  late FakeTransport transport;
  late CollabSession session;
  bool running = false;
  int incarnation = 0;

  /// Every event this participant ever received, across restarts.
  final List<ClientEvent> events = [];

  /// Intended edits whose journal write completed (the user was promised an outcome), keyed by cseq.
  final Map<int, Op> promised = {};

  /// Edits that were accepted locally but never became durable before a crash.
  int unpersistedAtCrash = 0;
  final Set<int> _awaitingPersist = {};

  void start() {
    incarnation++;
    transport = FakeTransport(world.server, network: net);
    session = CollabSession(
      clientId: serverIssuedId ? null : (wireId ?? id),
      transport: transport,
      store: store,
      journaled: journaled,
      random: _random,
      clock: world.clock,
    );
    session.events.listen(events.add);
    running = true;
    unawaited(session.start());
    world.async.flushMicrotasks();
  }

  /// Process death: no flushing, no goodbye. In-flight journal writes of [MemoryStore] complete only if
  /// microtasks ran, exactly like a real crash racing a disk write.
  void crash() {
    if (!running) return;
    running = false;
    store.crash(landInFlight: _random.nextBool());
    unawaited(session.stop());
    unpersistedAtCrash += _awaitingPersist.length;
    _awaitingPersist.clear();
  }

  void restart() {
    crash();
    start();
  }

  /// Applies a user edit; records the promise once the journal write is done.
  int? edit(Op op) {
    if (!running) return null;
    final t = session.edit(op);
    final cseq = t.cseq;
    if (cseq == null) return null;
    _awaitingPersist.add(cseq);
    final inc = incarnation;
    unawaited(
      t.persisted.then((_) {
        if (inc != incarnation) return;
        promised[cseq] = op;
        _awaitingPersist.remove(cseq);
      }, onError: (Object _) {}),
    );
    return cseq;
  }

  void heal() {
    net
      ..partitioned = false
      ..blockStreams = false
      ..refused = false
      ..dropRequest = 0
      ..dropResponse = 0
      ..serverError = 0
      ..holeRate = 0;
  }

  Iterable<OpCommitted> get committed => events.whereType<OpCommitted>();
  Iterable<OpRejected> get rejected => events.whereType<OpRejected>();
  Iterable<OpLost> get lost => events.whereType<OpLost>();
  Iterable<ConflictDetected> get warnings => events.whereType<ConflictDetected>();
}

/// A fake-time world: one [FakeServer], any number of participants, time moves only through [elapse].
class World {
  World(this.async, {Document? initial, int maxReplay = 2000})
    : server = FakeServer(initial: initial, maxReplay: maxReplay);

  final FakeAsync async;
  final FakeServer server;
  final Map<String, Participant> participants = {};

  int clock() => async.elapsed.inMilliseconds;

  Participant add(String id, {bool journaled = true, int? seed, String? wireId, bool serverIssuedId = false}) {
    final p = Participant(
      this,
      id,
      journaled: journaled,
      random: seed == null ? null : Random(seed),
      wireId: wireId,
      serverIssuedId: serverIssuedId,
    );
    participants[id] = p;
    p.start();
    return p;
  }

  /// Lets queued microtasks (event deliveries, journal writes) run.
  void flush() => async.flushMicrotasks();

  void elapse(Duration d) {
    async.elapse(d);
    async.flushMicrotasks();
  }

  /// Runs fake time until every running participant is settled and has applied the server head, or fails.
  void settle({Duration limit = const Duration(minutes: 10)}) {
    final end = async.elapsed + limit;
    while (async.elapsed < end) {
      elapse(const Duration(milliseconds: 500));
      if (isSettled) {
        elapse(const Duration(seconds: 1));
        if (isSettled) return;
      }
    }
    throw StateError('not settled after $limit:\n${describe()}');
  }

  bool get isSettled => participants.values
      .where((p) => p.running)
      .every(
        (p) =>
            p.session.machine.isQuiescent && p.session.lastSeq == server.head && p.session.machine.unresolvedCount == 0,
      );

  String describe() => [
    'server head ${server.head}',
    for (final p in participants.values)
      '${p.id} running=${p.running} ${p.running ? p.session.machine.debug.join(' | ') : ''}',
  ].join('\n');
}

/// Runs [body] inside fake time.
void inWorld(void Function(World w) body, {Document? initial, int maxReplay = 2000}) {
  fakeAsync((async) {
    body(World(async, initial: initial, maxReplay: maxReplay));
  });
}
