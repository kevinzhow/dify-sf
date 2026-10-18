// dify-spec: web/app/components/workflow/__tests__/workflow-edge-events.spec.tsx
import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/canvas/canvas_input.dart' show ControlMode;
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/comment_icon.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/comment_input.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/comment_layer.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/comment_thread.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';
import 'comment_harness.dart';

/// index.tsx's comment parts, here the comment layer over the canvas.
void main() {
  late WorkflowStore store;
  late CommentsHarness h;
  late CanvasController canvas;

  setUp(() {
    useDifyTestTranslator();
    store = WorkflowStore()
      ..setControlMode(ControlMode.comment)
      ..setShowUserComments(true)
      ..setShowResolvedComments(false);
    h = CommentsHarness();
    canvas = identityCanvas();
  });
  tearDown(() {
    h.dispose();
    store.dispose();
    canvas.dispose();
  });

  Future<void> wait(WidgetTester t) async {
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await settle(t);
  }

  group('Workflow edge event wiring', () {
    testWidgets('should render comment overlays and execute comment actions in comment mode', (t) async {
      final second = h.seed(x: 300, y: 200, content: 'second');
      final first = h.seed(x: 100, y: 200, content: 'first');
      h.server.comments.reply(first, client: 'user-1', content: 'a reply');
      await pumpComments(
        t,
        Stack(
          children: [
            Positioned.fill(
              child: CommentLayer(canvas: canvas, formatTimeFromNow: (_) => 'now'),
            ),
          ],
        ),
        store: store,
        comments: h.store('user-1'),
      );
      await settle(t);

      // The comment cursor over the canvas.
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(600, 500));
      await mouse.moveTo(const Offset(650, 520));
      await t.pump();
      expect(find.byWidgetPredicate((w) => w is DifyIcon && w.name == 'public/other/comment'), findsOneWidget);

      // Placing from the pane menu: the box follows the pointer; a click places it.
      store.setCommentPlacing(true);
      await t.pump();
      expect(find.byWidgetPredicate((w) => w is CommentInput && w.disabled), findsOneWidget);
      await t.tapAt(const Offset(650, 520));
      await t.pump();
      expect(store.isCommentPlacing.value, isFalse);
      expect(find.byWidgetPredicate((w) => w is CommentInput && !w.disabled), findsOneWidget);
      store.setPendingComment(null);

      expect(find.byType(CommentIcon), findsNWidgets(2));
      await t.tap(find.byWidgetPredicate((w) => w is CommentIcon && w.comment.id == first));
      await wait(t);
      expect(find.byType(CommentThread), findsOneWidget);

      await t.tap(pressable('workflow.comments.aria.nextComment'));
      await wait(t);
      expect(store.activeCommentId.value, second);
      await t.tap(pressable('workflow.comments.aria.previousComment'));
      await wait(t);
      expect(store.activeCommentId.value, first);

      // Deleting a reply and the thread ask first.
      await mouse.moveTo(t.getCenter(find.text('a reply')));
      await t.pump();
      await t.tap(pressable('workflow.comments.aria.replyActions'));
      await t.pumpAndSettle();
      await t.tap(find.text('workflow.comments.actions.deleteReply'));
      await t.pump();
      await t.tap(find.text('common.operation.yes'));
      await wait(t);
      expect(h.api.callsOf('deleteReply').single['id'], first);

      await t.tap(pressable('workflow.comments.aria.deleteComment'));
      await t.pump();
      expect(find.text('workflow.comments.confirm.deleteThreadTitle'), findsOneWidget);
      await t.tap(find.text('common.operation.confirm'));
      await wait(t);
      expect(h.api.callsOf('delete').single['id'], first);
      expect(store.activeCommentId.value, second, reason: 'the next thread opens');
      expect(find.byType(CommentIcon), findsOneWidget);
    });
  });
}
