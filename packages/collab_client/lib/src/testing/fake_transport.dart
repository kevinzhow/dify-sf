import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart';

import '../client/comments_api.dart';
import '../client/transport.dart';
import '../wire/messages.dart';
import 'fake_comments.dart';
import 'fake_server.dart';

/// Network conditions between one client and a [FakeServer]. All randomness comes from [random], so a
/// seeded run is reproducible. Mutate the fields at any time to inject faults.
class FakeNetwork {
  FakeNetwork({Random? random}) : random = random ?? Random(1);

  final Random random;

  /// One-way latency range.
  Duration minLatency = const Duration(milliseconds: 5);
  Duration maxLatency = const Duration(milliseconds: 40);

  /// Probability that a POST request / its response is silently lost (the caller sees a timeout).
  double dropRequest = 0;
  double dropResponse = 0;

  /// Probability that a POST is answered `503` (outcome unknown to the caller; the commit may or may not
  /// have happened: decided by [commitBefore503]).
  double serverError = 0;
  double commitBefore503 = 0.5;

  /// Probability that one stream event is lost while the connection stays up (a buggy proxy). The client
  /// must notice the hole in the sequence numbers.
  double holeRate = 0;

  /// Everything is blackholed: new requests hang, open streams go silent (half-open: no error, no pings).
  bool partitioned = false;

  /// Only the event streams are blackholed (POSTs still work): the stream half-opens or never connects.
  bool blockStreams = false;

  /// The server is unreachable (connection refused): requests fail fast, streams fail to open.
  bool refused = false;

  /// Server keep-alive interval on streams.
  Duration pingInterval = const Duration(seconds: 10);

  final List<_FakeStream> _streams = [];

  Duration latency() {
    final span = maxLatency.inMicroseconds - minLatency.inMicroseconds;
    return minLatency + Duration(microseconds: span <= 0 ? 0 : random.nextInt(span + 1));
  }

  bool chance(double p) => p > 0 && random.nextDouble() < p;

  /// Abruptly ends every open stream with an error (connection reset).
  void cutStreams() {
    for (final s in List.of(_streams)) {
      s.fail(const TransportException('connection reset'));
    }
  }

  int get openStreams => _streams.length;
}

/// A [CollabTransport] that talks to an in-memory [FakeServer] through a simulated [FakeNetwork].
class FakeTransport implements CollabTransport {
  FakeTransport(this.server, {FakeNetwork? network}) : network = network ?? FakeNetwork();

  final FakeServer server;
  final FakeNetwork network;

  final Set<Timer> _timers = {};

  /// A timer that [close] cancels, so a closed client leaves nothing pending (widget tests insist).
  Timer _timer(Duration d, void Function() f) {
    late final Timer t;
    t = Timer(d, () {
      _timers.remove(t);
      f();
    });
    _timers.add(t);
    return t;
  }

  /// Number of POSTs that reached the server (for assertions about retransmits).
  int postsReceived = 0;

  /// Number of streams the client opened.
  int streamsOpened = 0;

  @override
  Future<SubmitResponse> submit(SubmitRequest request, {required Duration timeout}) {
    final done = Completer<SubmitResponse>();
    final timers = <Timer>[];
    void fail(TransportException e) {
      if (!done.isCompleted) done.completeError(e);
      for (final t in timers) {
        t.cancel();
      }
    }

    timers.add(_timer(timeout, () => fail(const TransportException('POST timed out', timeout: true))));
    if (network.partitioned) return done.future;
    if (network.refused) {
      timers.add(_timer(network.latency(), () => fail(const TransportException('connection refused'))));
      return done.future;
    }
    if (network.chance(network.dropRequest)) return done.future;
    timers.add(
      _timer(network.latency(), () {
        if (done.isCompleted) return; // the client gave up before the request arrived: it never reaches the server
        if (network.chance(network.serverError)) {
          if (network.chance(network.commitBefore503)) {
            postsReceived++;
            server.submit(request);
          }
          timers.add(
            _timer(
              network.latency(),
              () => fail(const TransportException('unavailable', statusCode: 503, code: 'unavailable')),
            ),
          );
          return;
        }
        postsReceived++;
        final response = server.submit(request);
        if (network.partitioned || network.chance(network.dropResponse)) return;
        timers.add(
          _timer(network.latency(), () {
            if (network.partitioned || done.isCompleted) return;
            done.complete(response);
            for (final t in timers) {
              t.cancel();
            }
          }),
        );
      }),
    );
    return done.future;
  }

  @override
  late final CommentsApi comments = FakeCommentsApi(server, network: network);

  @override
  Future<String> issueClientId({String? name}) async {
    if (network.refused || network.partitioned) throw const TransportException('connection refused');
    return server.issueClientId(name: name);
  }

  @override
  Future<({String ref, String masked})> storeSecret(String value) async {
    if (network.refused || network.partitioned) throw const TransportException('connection refused');
    return server.storeSecret(value);
  }

  @override
  Future<void> setClientName(String client, String name) async {
    if (network.refused || network.partitioned) throw const TransportException('connection refused');
    server.setClientName(client, name);
  }

  @override
  Stream<StreamEvent> openStream(StreamOpen open) {
    streamsOpened++;
    final stream = _FakeStream(this, open);
    return stream.controller.stream;
  }

  @override
  void close() {
    for (final t in List.of(_timers)) {
      t.cancel();
    }
    _timers.clear();
    for (final s in List.of(network._streams)) {
      s.close();
    }
  }
}

class _FakeStream {
  _FakeStream(this.transport, this.open) {
    controller = StreamController<StreamEvent>(onListen: _start, onCancel: close);
  }

  final FakeTransport transport;
  final StreamOpen open;
  late final StreamController<StreamEvent> controller;
  Timer? _pingTimer;
  Timer? _openTimer;
  bool _closed = false;
  bool _connected = false;

  /// After losing real events to a partition the connection delivers nothing more (half-open) until the
  /// client's watchdog closes it.
  bool _dead = false;
  bool get _blackholed => net.partitioned || net.blockStreams;
  DateTime? _lastDelivery;
  late final void Function(LogEntry) _listener = _onCommit;
  late final void Function(CommentsEvent) _commentsListener = _onComments;

  FakeNetwork get net => transport.network;
  FakeServer get server => transport.server;

  void _start() {
    net._streams.add(this);
    if (net.partitioned || net.blockStreams) {
      return; // half-open before it even connected: the client's watchdog must fire
    }
    if (net.refused) {
      _openTimer = transport._timer(net.latency(), () => fail(const TransportException('connection refused')));
      return;
    }
    _openTimer = transport._timer(net.latency(), _connect);
  }

  void _connect() {
    if (_closed) return;
    if (net.partitioned || net.blockStreams) return;
    _connected = true;
    final events = server.catchUp(
      lastEventId: open.lastEventId,
      client: open.client,
      from: open.from,
      proto: open.proto,
    );
    server.addListener(_listener);
    server.comments.addListener(_commentsListener);
    for (final e in events) {
      _deliver(e);
    }
    _pingTimer = Timer.periodic(net.pingInterval, (_) {
      if (!_blackholed && !_dead) _deliver(const PingEvent());
    });
  }

  void _onCommit(LogEntry e) {
    if (!_connected || _closed) return;
    if (!StreamCompat.streamCarries(e.op, open.proto)) {
      // An older client cannot decode this op: the server ends its stream (it reconnects and gets a snapshot).
      unawaited(close());
      return;
    }
    if (_blackholed) {
      _dead = true;
      return;
    }
    if (net.chance(net.holeRate)) return; // lost on the way, connection stays up
    _deliver(CommitEvent(e));
  }

  /// Comment notifications: best-effort (no seq), so a blackholed stream just loses them.
  void _onComments(CommentsEvent e) {
    if (!_connected || _closed || _blackholed || _dead) return;
    _deliver(e);
  }

  /// In-order delivery with latency (TCP never reorders).
  void _deliver(StreamEvent e) {
    if (_closed) return;
    final now = clock.now();
    var at = now.add(net.latency());
    final last = _lastDelivery;
    if (last != null && at.isBefore(last)) at = last;
    _lastDelivery = at;
    transport._timer(at.difference(now), () {
      if (_closed || _dead) return;
      if (_blackholed) {
        // Bytes vanished into the blackhole. A real TCP connection would stall and eventually reset; until
        // then the client sees silence, and it must not see later events with a gap before them.
        if (e is! PingEvent) _dead = true;
        return;
      }
      if (!controller.isClosed) controller.add(e);
    });
  }

  void fail(Object error) {
    if (_closed) return;
    _teardown();
    if (!controller.isClosed) {
      controller.addError(error);
      unawaited(controller.close());
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _teardown();
    // Not awaited: this runs inside the controller's own onCancel, whose completion `close()` would wait for.
    if (!controller.isClosed) unawaited(controller.close());
  }

  void _teardown() {
    _closed = true;
    _pingTimer?.cancel();
    _openTimer?.cancel();
    server.removeListener(_listener);
    server.comments.removeListener(_commentsListener);
    net._streams.remove(this);
  }
}
