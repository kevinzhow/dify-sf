// dify-spec: web/app/components/workflow/hooks/__tests__/use-workflow-comment.spec.ts
import 'package:collab_client/collab_client.dart' show CommentsAction, CommentsEvent;
import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/canvas/canvas_input.dart' show ControlMode;
import 'package:dify_sf_app/src/workflow_editor/comments/workflow_comment.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';
import 'comment_harness.dart';

/// dify-sf's comments store does the requests and keeps the list (Dify's hook does both); these run the hook's
/// handlers ([WorkflowComments]) over the real store and an in-memory server whose requests are recorded.
void main() {
  late CommentsHarness h;
  late WorkflowStore store;
  late CanvasController canvas;
  late CommentsStore comments;
  late WorkflowComments hook;

  setUp(() {
    useDifyTestTranslator();
    h = CommentsHarness();
    store = WorkflowStore();
    canvas = identityCanvas();
  });

  /// The store and the hook, made inside the test (their requests run on the test's clock).
  void start() {
    comments = h.store('user-1');
    hook = WorkflowComments(source: comments, store: store, canvas: canvas);
    addTearDown(hook.dispose);
  }

  tearDown(() {
    h.dispose();
    store.dispose();
    canvas.dispose();
  });

  /// Awaits [f] while the in-memory requests run.
  Future<T> run<T>(WidgetTester t, Future<T> f) async {
    final v = await pumpUntil(t, f);
    await settle(t);
    return v;
  }

  /// Runs the view animation (setCenter's 600 ms) to its end.
  Future<void> animate(WidgetTester t) async {
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  group('useWorkflowComment', () {
    testWidgets('loads comment list on mount when collaboration is enabled', (t) async {
      start();
      h.seed();
      final fresh = h.store('user-1');
      await settle(t);
      expect(h.api.callsOf('list'), isNotEmpty);
      expect(fresh.comments.single.content, 'hello');
      expect(fresh.loading, isFalse);
    });

    testWidgets('creates a comment, updates local cache, and emits collaboration sync', (t) async {
      start();
      await settle(t);
      final announced = <CommentsEvent>[];
      h.server.comments.addListener(announced.add);
      store
        ..setPendingComment((pageX: 100, pageY: 200, elementX: 10, elementY: 20))
        ..setCommentQuickAdd(true);

      await run(t, hook.submit('new message', ['user-2']));

      expect(h.api.callsOf('create').single, {
        'author': 'user-1',
        'x': 10.0,
        'y': 20.0,
        'content': 'new message',
        'mentions': ['user-2'],
      });
      expect(announced.single.action, CommentsAction.created);
      final c = comments.comments.single;
      expect((c.content, c.positionX, c.positionY, c.mentions.length, c.replyCount), ('new message', 10, 20, 1, 0));
      expect([for (final u in participantsOf(comments, c)) u.id], ['user-1', 'user-2']);
      expect(store.pendingComment.value, isNull);
      expect(store.isCommentQuickAdd.value, isFalse);
    });

    testWidgets('normalizes ISO timestamps and keeps unresolved mentions as null', (t) async {
      start();
      await settle(t);
      store
        ..setPendingComment((pageX: 100, pageY: 200, elementX: 10, elementY: 20))
        ..setCommentQuickAdd(true);

      await run(t, hook.submit('new message', ['missing-user']));

      final c = comments.comments.single;
      expect(c.createdAt.isUtc, isTrue);
      expect(c.updatedAt, c.createdAt);
      // An unknown client's mention has no name (Dify: no account); only known users are participants.
      expect(c.mentions.single.client, 'missing-user');
      expect(c.mentions.single.name, isNull);
      expect(participantsOf(comments, c), [(id: 'user-1', name: 'Alice')]);
    });

    testWidgets('rolls back optimistic position update when API update fails', (t) async {
      start();
      final id = h.seed();
      await settle(t);
      store.setActiveCommentId(id);
      final announced = <CommentsEvent>[];
      h.server.comments.addListener(announced.add);
      h.api.failNext.add('update');

      final done = hook.move(id, const Offset(300, 400));
      expect((comments.byId(id)!.positionX, comments.byId(id)!.positionY), (300, 400), reason: 'optimistic');
      await run(t, done);

      expect(h.api.callsOf('update').single, {'id': id, 'author': 'user-1', 'x': 300.0, 'y': 400.0});
      expect(announced, isEmpty);
      expect((comments.byId(id)!.positionX, comments.byId(id)!.positionY), (10, 20));
      expect((hook.activeComment!.positionX, hook.activeComment!.positionY), (10, 20));
    });

    testWidgets('refreshes comments and active detail when collaboration update event arrives', (t) async {
      start();
      final id = h.seed();
      await settle(t);
      store.setActiveCommentId(id);
      final lists = h.api.callsOf('list').length;
      // Another user's change, made behind this client's back, then announced.
      h.server.comments.reply(id, client: 'user-2', content: 'updated by another user');
      await settle(t);

      expect(h.api.callsOf('list').length, greaterThan(lists));
      expect(hook.activeComment!.replies.single.content, 'updated by another user');

      h.disposeStore(comments);
      expect(h.hasEventListeners, isFalse);
      h.notify();
      await settle(t);
      final after = h.api.callsOf('list').length;
      h.notify();
      await settle(t);
      expect(h.api.callsOf('list').length, after, reason: 'unsubscribed once disposed');
    });

    testWidgets('focuses comment thread, loads detail, and updates navigation/create/close states', (t) async {
      start();
      final b = h.seed(x: 50, y: 80, content: 'second');
      final a = h.seed();
      await settle(t);
      expect([for (final c in comments.comments) c.id], [a, b], reason: 'newest first');
      store
        ..setRightPanelWidth(800)
        ..setNodePanelWidth(300)
        ..setControlMode(ControlMode.comment)
        ..setActiveCommentId(a)
        ..setPendingComment((pageX: 1, pageY: 2, elementX: 3, elementY: 4));
      final withSelectedNode = WorkflowComments(
        source: comments,
        store: store,
        canvas: canvas,
        hasSelectedNode: () => true,
      );
      addTearDown(withSelectedNode.dispose);

      withSelectedNode.navigate(true);
      await animate(t);

      expect(store.activeCommentId.value, b);
      expect(store.pendingComment.value, isNull);
      // min(220 + max(800, 300 + 420) / 2, 1024 / 2 - 60) = 452 to the right of the pin, at zoom 1.
      expect((canvas.view.center, canvas.view.scale), (const Offset(502, 80), 1.0));

      withSelectedNode.createAt((pageX: 300, pageY: 400, elementX: 30, elementY: 40));
      expect(store.pendingComment.value, (pageX: 300.0, pageY: 400.0, elementX: 30.0, elementY: 40.0));

      withSelectedNode.close();
      expect(store.activeCommentId.value, isNull);
      expect(withSelectedNode.activeComment, isNull);
      expect(store.activeCommentDetailLoading.value, isFalse);
    });

    testWidgets('runs resolve, delete, and reply lifecycle handlers with collaboration sync', (t) async {
      start();
      final b = h.seed(x: 33, y: 55, content: 'fallback');
      final a = h.seed();
      await settle(t);
      store.setActiveCommentId(a);
      final announced = <CommentsEvent>[];
      h.server.comments.addListener(announced.add);

      await run(t, hook.resolve(a));
      expect(h.api.callsOf('resolve').single, {'id': a, 'author': 'user-1'});

      await run(t, hook.reply(a, '  new reply  ', ['user-2']));
      final replyId = comments.byId(a)!.replies.single.id;
      await run(t, hook.updateReply(a, replyId, '  edited reply  ', ['user-2']));
      await run(t, hook.deleteReply(a, replyId));

      expect(h.api.callsOf('reply').single, {
        'id': a,
        'author': 'user-1',
        'content': 'new reply',
        'mentions': ['user-2'],
      });
      expect(h.api.callsOf('editReply').single, {
        'id': a,
        'replyId': replyId,
        'author': 'user-1',
        'content': 'edited reply',
        'mentions': ['user-2'],
      });
      expect(h.api.callsOf('deleteReply').single, {'id': a, 'replyId': replyId, 'author': 'user-1'});

      await run(t, hook.delete(a));
      expect(h.api.callsOf('delete').single, {'id': a, 'author': 'user-1'});
      expect(store.activeCommentId.value, b, reason: 'the next comment opens');
      expect(announced, isNotEmpty);
      await animate(t);
    });

    testWidgets('does not update a reply when the content is blank', (t) async {
      start();
      await run(t, hook.updateReply('comment-1', 'reply-1', '   '));
      expect(h.api.callsOf('editReply'), isEmpty);
    });

    testWidgets('resets reply submit loading when creation fails', (t) async {
      start();
      final id = h.seed();
      await settle(t);
      h.api.failNext.add('reply');
      final done = hook.reply(id, 'new reply');
      expect(store.replySubmitting.value, isTrue);
      await run(t, done);
      expect(h.api.callsOf('reply').single, {'id': id, 'author': 'user-1', 'content': 'new reply', 'mentions': []});
      expect(store.replySubmitting.value, isFalse);
    });

    testWidgets('resets reply update loading when update fails', (t) async {
      start();
      h.api.failNext.add('editReply');
      await run(t, hook.updateReply('comment-1', 'reply-1', 'updated reply'));
      expect(h.api.callsOf('editReply').single, {
        'id': 'comment-1',
        'replyId': 'reply-1',
        'author': 'user-1',
        'content': 'updated reply',
        'mentions': [],
      });
      expect(store.replyUpdating.value, isFalse);
    });

    testWidgets('resets reply delete loading when deletion fails', (t) async {
      start();
      h.api.failNext.add('deleteReply');
      await run(t, hook.deleteReply('comment-1', 'reply-1'));
      expect(h.api.callsOf('deleteReply').single, {'id': 'comment-1', 'replyId': 'reply-1', 'author': 'user-1'});
      expect(store.activeCommentDetailLoading.value, isFalse);
    });

    testWidgets('ignores navigation when no active comment or active comment is absent from the list', (t) async {
      start();
      h.seed();
      await settle(t);
      final before = canvas.view.center;
      hook.navigate(true);
      await animate(t);
      expect(canvas.view.center, before);

      final missing = comments.comments.single.copyWith();
      hook.open(_withId(missing, 'missing-comment'));
      await animate(t);
      final after = canvas.view.center;
      hook.navigate(true);
      await animate(t);
      expect(canvas.view.center, after);
    });

    testWidgets('clears a pending comment when comment mode is left outside quick add', (t) async {
      start();
      store
        ..setControlMode(ControlMode.pointer)
        ..setCommentQuickAdd(false)
        ..setPendingComment((pageX: 1, pageY: 2, elementX: 3, elementY: 4));
      hook.syncPending();
      expect(store.pendingComment.value, isNull);
    });

    testWidgets('does not overwrite the active comment when a different comment is resolved/refreshed', (t) async {
      start();
      final b = h.seed(x: 50, y: 80, content: 'second');
      final a = h.seed();
      await settle(t);
      store.setActiveCommentId(b);

      await run(t, hook.resolve(a));
      await settle(t);

      expect(store.activeCommentId.value, b);
      expect(hook.activeComment!.id, b);
      expect(hook.activeComment!.content, 'second');
    });

    testWidgets('still refreshes the active comment', (t) async {
      start();
      final a = h.seed(content: 'stale content');
      await settle(t);
      store.setActiveCommentId(a);
      h.server.comments.update(a, client: 'user-1', content: 'refreshed content');
      await run(t, comments.refresh());
      expect(hook.activeComment!.id, a);
      expect(hook.activeComment!.content, 'refreshed content');
    });
  });
}

/// [c] under another id (a comment the list does not have).
Comment _withId(Comment c, String id) => Comment(
  id: id,
  positionX: c.positionX,
  positionY: c.positionY,
  content: c.content,
  createdBy: c.createdBy,
  createdAt: c.createdAt,
  updatedAt: c.updatedAt,
);
