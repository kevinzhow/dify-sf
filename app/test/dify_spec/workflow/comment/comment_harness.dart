import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/comments_store.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A comments API over the in-memory server that records the calls (Dify's tests assert the console client's calls)
/// and fails the next call of a kind on request.
class RecordingCommentsApi implements CommentsApi {
  RecordingCommentsApi(this.inner);
  final FakeCommentsApi inner;

  /// `(method, args)` in call order.
  final calls = <(String, Map<String, Object?>)>[];

  /// Methods whose next call throws (once each).
  final failNext = <String>{};

  Iterable<Map<String, Object?>> callsOf(String method) => [
    for (final (m, a) in calls)
      if (m == method) a,
  ];

  Future<T> _call<T>(String method, Map<String, Object?> args, Future<T> Function() run) async {
    calls.add((method, args));
    if (failNext.remove(method)) {
      await Future<void>.delayed(Duration.zero);
      throw TransportException('$method failed', statusCode: 500, code: 'internal');
    }
    return run();
  }

  @override
  Future<List<Comment>> list() => _call('list', const {}, inner.list);

  @override
  Future<Comment> get(String id) => _call('get', {'id': id}, () => inner.get(id));

  @override
  Future<Comment> create({
    required String author,
    required double x,
    required double y,
    required String content,
    List<String> mentions = const [],
  }) => _call(
    'create',
    {'author': author, 'x': x, 'y': y, 'content': content, 'mentions': mentions},
    () => inner.create(author: author, x: x, y: y, content: content, mentions: mentions),
  );

  @override
  Future<Comment> update(
    String id, {
    required String author,
    String? content,
    double? x,
    double? y,
    List<String>? mentions,
  }) => _call(
    'update',
    {'id': id, 'author': author, 'content': ?content, 'x': ?x, 'y': ?y, 'mentions': ?mentions},
    () => inner.update(id, author: author, content: content, x: x, y: y, mentions: mentions),
  );

  @override
  Future<void> delete(String id, {required String author}) =>
      _call('delete', {'id': id, 'author': author}, () => inner.delete(id, author: author));

  @override
  Future<Comment> resolve(String id, {required String author}) =>
      _call('resolve', {'id': id, 'author': author}, () => inner.resolve(id, author: author));

  @override
  Future<CommentReply> reply(
    String id, {
    required String author,
    required String content,
    List<String> mentions = const [],
  }) => _call(
    'reply',
    {'id': id, 'author': author, 'content': content, 'mentions': mentions},
    () => inner.reply(id, author: author, content: content, mentions: mentions),
  );

  @override
  Future<CommentReply> editReply(
    String id,
    String replyId, {
    required String author,
    required String content,
    List<String> mentions = const [],
  }) => _call(
    'editReply',
    {'id': id, 'replyId': replyId, 'author': author, 'content': content, 'mentions': mentions},
    () => inner.editReply(id, replyId, author: author, content: content, mentions: mentions),
  );

  @override
  Future<void> deleteReply(String id, String replyId, {required String author}) => _call(
    'deleteReply',
    {'id': id, 'replyId': replyId, 'author': author},
    () => inner.deleteReply(id, replyId, author: author),
  );

  @override
  Future<Map<String, String>> clientNames() => _call('clientNames', const {}, inner.clientNames);
}

/// An in-memory comments server shared by the clients of a test, with Dify's test users (`user-1` Alice, `user-2`
/// Bob) registered; each client's [CommentsStore] refetches on the server's `comments` notifications, as the session
/// would.
class CommentsHarness {
  CommentsHarness() {
    server
      ..setClientName('user-1', 'Alice')
      ..setClientName('user-2', 'Bob');
    server.comments.addListener(_events.add);
  }

  final server = FakeServer();
  final _events = StreamController<CommentsEvent>.broadcast();
  late final api = RecordingCommentsApi(FakeCommentsApi(server));
  final _stores = <CommentsStore>[];

  Stream<CommentsEvent> get events => _events.stream;
  bool get hasEventListeners => _events.hasListener;

  /// A notification as the stream would deliver it (another tab's change, a reconnect).
  void notify([CommentsEvent e = const CommentsEvent.resync()]) => _events.add(e);

  CommentsStore store(String clientId) {
    final s = CommentsStore(api: api, events: _events.stream, clientId: () => clientId);
    _stores.add(s);
    return s;
  }

  /// A comment made on the server by [by] (its id).
  String seed({
    String by = 'user-1',
    double x = 10,
    double y = 20,
    String content = 'hello',
    List<String> mentions = const [],
  }) => server.comments.create(client: by, x: x, y: y, content: content, mentions: mentions)['id']! as String;

  /// Disposes [s] now (as the editor does when it goes away).
  void disposeStore(CommentsStore s) {
    _stores.remove(s);
    s.dispose();
  }

  void dispose() {
    for (final s in _stores) {
      s.dispose();
    }
    _stores.clear();
    unawaited(_events.close());
  }
}

/// Lets the in-memory requests (each one zero-delay timer) and the store's refetches finish.
Future<void> settle(WidgetTester t, [int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await t.pump(Duration.zero);
  }
}

/// A canvas 1024 × 768 whose canvas coordinates are its screen coordinates (React Flow's identity viewport).
CanvasController identityCanvas({Size viewport = const Size(1024, 768)}) {
  final c = CanvasController();
  c.view
    ..viewport = viewport
    ..center = Offset(viewport.width / 2, viewport.height / 2);
  return c;
}

/// [child] in an app page with the editor's [store] and the [comments] store in scope, at the top-left.
Future<void> pumpComments(
  WidgetTester t,
  Widget child, {
  required WorkflowStore store,
  required CommentsStore comments,
  Size size = const Size(1024, 768),
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(
        child: WorkflowStoreScope(
          store: store,
          child: CommentsScope(store: comments, child: child),
        ),
      ),
    ),
  );
  await t.pump();
}

/// The pressable (button) named [label].
Finder pressable(String label) => find.byWidgetPredicate((w) => w is DifyPressable && w.semanticLabel == label);

/// A Dify-shaped time formatter (`time:<ms>`), as Dify's tests mock useFormatTimeFromNow.
String fakeTime(int ms) => 'time:$ms';

/// Pumps until [f] completes (the in-memory requests are zero-delay timers), then returns its value.
Future<T> pumpUntil<T>(WidgetTester t, Future<T> f, {int maxPumps = 200}) async {
  var done = false;
  late T value;
  Object? error;
  f.then(
    (v) {
      value = v;
      done = true;
    },
    onError: (Object e) {
      error = e;
      done = true;
    },
  );
  for (var i = 0; i < maxPumps && !done; i++) {
    await t.pump(Duration.zero);
  }
  if (!done) fail('the future did not complete');
  if (error != null) throw error!;
  return value;
}
