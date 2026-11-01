import 'dart:async';
import 'dart:math';

import '../client/comments_api.dart';
import '../client/transport.dart';
import '../wire/messages.dart';

/// One client's network, for the convergence runs: every request waits [base] ± [jitter] on the way out and again on
/// the way back, stream events arrive that late too (in order), now and then the stream stalls for a while and
/// delivers everything at once, and now and then it drops (the client reconnects as it would on a real network).
final class LatencyProfile {
  const LatencyProfile({
    required this.name,
    required this.base,
    this.jitter = Duration.zero,
    this.stallsPerMinute = 0,
    this.stall = Duration.zero,
    this.dropsPerMinute = 0,
  });

  /// No delay at all.
  static const none = LatencyProfile(name: 'none', base: Duration.zero);

  final String name;
  final Duration base;
  final Duration jitter;
  final double stallsPerMinute;
  final Duration stall;
  final double dropsPerMinute;

  /// One-way delays from 20 ms to over a second, as people on fibre, home wifi, mobile and a bad train connection.
  static const mix = [
    LatencyProfile(name: 'fibre', base: Duration(milliseconds: 20), jitter: Duration(milliseconds: 10)),
    LatencyProfile(name: 'home', base: Duration(milliseconds: 80), jitter: Duration(milliseconds: 40)),
    LatencyProfile(
      name: 'mobile',
      base: Duration(milliseconds: 250),
      jitter: Duration(milliseconds: 150),
      stallsPerMinute: 1,
      stall: Duration(seconds: 2),
    ),
    LatencyProfile(
      name: 'train',
      base: Duration(milliseconds: 700),
      jitter: Duration(milliseconds: 400),
      stallsPerMinute: 2,
      stall: Duration(seconds: 4),
      dropsPerMinute: 1.5,
    ),
  ];

  /// The profile of client [index] when [mix] is spread over the clients: 30% fibre, 40% home, 20% mobile, 10% train.
  static LatencyProfile forIndex(int index) {
    final r = (index * 37) % 10;
    return mix[r < 3
        ? 0
        : r < 7
        ? 1
        : r < 9
        ? 2
        : 3];
  }

  @override
  String toString() => name;
}

/// Wraps [inner] with [profile]. Nothing else changes: the client sees an ordinary, slow, unreliable transport.
class LatencyTransport implements CollabTransport {
  LatencyTransport(this.inner, this.profile, {Random? random}) : _rng = random ?? Random();

  final CollabTransport inner;
  final LatencyProfile profile;
  final Random _rng;

  Duration _oneWay() {
    final j = profile.jitter.inMicroseconds;
    final us = profile.base.inMicroseconds + (j == 0 ? 0 : _rng.nextInt(2 * j + 1) - j);
    return Duration(microseconds: max(0, us));
  }

  Future<T> _roundTrip<T>(Future<T> Function() call) async {
    await Future<void>.delayed(_oneWay());
    final result = await call();
    await Future<void>.delayed(_oneWay());
    return result;
  }

  @override
  Future<SubmitResponse> submit(SubmitRequest request, {required Duration timeout}) async {
    // The client's own timeout covers the whole slow exchange, as it would on a real network.
    final sw = Stopwatch()..start();
    return _roundTrip(() {
      final left = timeout - sw.elapsed;
      if (left <= Duration.zero) throw const TransportException('submit timed out', timeout: true);
      return inner.submit(request, timeout: left);
    }).timeout(timeout, onTimeout: () => throw const TransportException('submit timed out', timeout: true));
  }

  @override
  Stream<StreamEvent> openStream(StreamOpen open) {
    late StreamController<StreamEvent> out;
    StreamSubscription<StreamEvent>? sub;
    Timer? stallTimer, dropTimer;
    var due = DateTime.now();
    var stalledUntil = DateTime.fromMillisecondsSinceEpoch(0);
    var closed = false;

    void finish([Object? error]) {
      if (closed) return;
      closed = true;
      stallTimer?.cancel();
      dropTimer?.cancel();
      unawaited(sub?.cancel());
      if (error != null) out.addError(error);
      unawaited(out.close());
    }

    void schedule() {
      if (profile.stallsPerMinute > 0) {
        stallTimer = Timer(_poisson(profile.stallsPerMinute), () {
          stalledUntil = DateTime.now().add(profile.stall);
          schedule();
        });
      }
    }

    out = StreamController<StreamEvent>(
      onListen: () {
        // The request travels before anything comes back.
        Future<void>.delayed(_oneWay(), () {
          if (closed) return;
          sub = inner
              .openStream(open)
              .listen(
                (e) {
                  // Deliver in order: never before the previous event, and not while the network stalls.
                  final now = DateTime.now();
                  var at = now.add(_oneWay());
                  if (at.isBefore(due)) at = due;
                  if (at.isBefore(stalledUntil)) at = stalledUntil;
                  due = at;
                  Future<void>.delayed(at.difference(now), () {
                    if (!closed) out.add(e);
                  });
                },
                onError: (Object err) => Future<void>.delayed(_oneWay(), () => finish(err)),
                onDone: () => Future<void>.delayed(
                  due.difference(DateTime.now()).isNegative ? Duration.zero : due.difference(DateTime.now()),
                  finish,
                ),
              );
          schedule();
          if (profile.dropsPerMinute > 0) {
            dropTimer = Timer(_poisson(profile.dropsPerMinute), () => finish(const TransportException('connection dropped')));
          }
        });
      },
      onCancel: () => finish(),
    );
    return out.stream;
  }

  /// The wait until the next event of a Poisson process with [perMinute] events a minute.
  Duration _poisson(double perMinute) {
    final minutes = -log(1 - _rng.nextDouble()) / perMinute;
    return Duration(milliseconds: (minutes * 60000).round());
  }

  @override
  Future<String> issueClientId({String? name}) => _roundTrip(() => inner.issueClientId(name: name));

  @override
  Future<void> setClientName(String client, String name) => _roundTrip(() => inner.setClientName(client, name));

  @override
  Future<({String ref, String masked})> storeSecret(String value) => _roundTrip(() => inner.storeSecret(value));

  @override
  Future<void> putPresence(String client, PresenceReport report) => _roundTrip(() => inner.putPresence(client, report));

  @override
  Future<void> deletePresence(String client) => _roundTrip(() => inner.deletePresence(client));

  @override
  CommentsApi get comments => inner.comments;

  @override
  void close() => inner.close();
}
