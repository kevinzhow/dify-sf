// dify-spec: web/app/components/workflow/comment/thread.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/comments/comment_thread.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/workflow_comment.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show Align, Alignment, TextField;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';
import 'comment_harness.dart';

DateTime _at(int s) => DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true);

Comment createComment() => Comment(
  id: 'comment-1',
  positionX: 120,
  positionY: 80,
  content: '@Alice original comment',
  createdBy: 'user-1',
  createdByName: 'Alice',
  createdAt: _at(1),
  updatedAt: _at(2),
  replies: [
    CommentReply(
      id: 'reply-1',
      content: 'first reply',
      createdBy: 'user-1',
      createdByName: 'Alice',
      createdAt: _at(2),
      updatedAt: _at(2),
    ),
  ],
);

void main() {
  late WorkflowStore store;
  late CommentsHarness h;

  setUp(() {
    useDifyTestTranslator();
    store = WorkflowStore();
    h = CommentsHarness();
  });
  tearDown(() {
    h.dispose();
    store.dispose();
  });

  Future<void> render(WidgetTester t, CommentThread Function(CommentsStore s) build) async {
    final comments = h.store('user-1');
    await pumpComments(
      t,
      Align(alignment: Alignment.topLeft, child: build(comments)),
      store: store,
      comments: comments,
    );
    await settle(t);
    await t.pump(const Duration(milliseconds: 150)); // the reply box takes focus after 100 ms
  }

  Future<TestGesture> mouseAt(WidgetTester t, Offset at) async {
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: at);
    await t.pump();
    return mouse;
  }

  group('CommentThread', () {
    testWidgets('triggers header actions and closes on Escape', (t) async {
      var closes = 0, deletes = 0, resolves = 0, prevs = 0, nexts = 0;
      await render(
        t,
        (s) => CommentThread(
          comment: createComment(),
          source: s,
          onClose: () => closes++,
          onDelete: () => deletes++,
          onResolve: () => resolves++,
          onPrev: () => prevs++,
          onNext: () => nexts++,
          canGoPrev: true,
          canGoNext: true,
          formatTimeFromNow: (_) => 'just now',
        ),
      );
      for (final label in ['deleteComment', 'resolveComment', 'previousComment', 'nextComment', 'closeComment']) {
        await t.tap(pressable('workflow.comments.aria.$label'));
      }
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      expect((deletes, resolves, prevs, nexts, closes), (1, 1, 1, 1, 2));
      await t.pump(const Duration(milliseconds: 500));
    });

    testWidgets('does not nest header action buttons inside tooltip trigger buttons', (t) async {
      final semantics = t.ensureSemantics();
      await render(
        t,
        (s) => CommentThread(
          comment: createComment(),
          source: s,
          onClose: () {},
          onDelete: () {},
          onResolve: () {},
          onPrev: () {},
          onNext: () {},
          canGoPrev: true,
          canGoNext: true,
        ),
      );
      bool nestedButton(SemanticsNode n) {
        var found = false;
        n.visitChildren((c) {
          found |= c.getSemanticsData().flagsCollection.isButton || nestedButton(c);
          return !found;
        });
        return found;
      }

      for (final label in ['deleteComment', 'resolveComment', 'previousComment', 'nextComment', 'closeComment']) {
        final node = t.getSemantics(find.bySemanticsLabel('workflow.comments.aria.$label'));
        expect(node.getSemanticsData().flagsCollection.isButton, isTrue);
        expect(nestedButton(node), isFalse, reason: label);
      }
      semantics.dispose();
    });

    testWidgets('supports editing the root comment when the current user owns the thread', (t) async {
      final edits = <(String, List<String>)>[];
      await render(
        t,
        (s) => CommentThread(
          comment: createComment(),
          source: s,
          onClose: () {},
          onCommentEdit: (c, ids) async => edits.add((c, ids)),
        ),
      );
      await mouseAt(t, t.getCenter(find.text('@Alice original comment')));
      await t.tap(pressable('workflow.comments.aria.commentActions'));
      await t.pumpAndSettle();
      await t.tap(find.text('workflow.comments.actions.editComment'));
      await t.pump();
      await t.tap(find.text('common.operation.save'));
      await t.pump();
      expect(edits.single.$1, '@Alice original comment');
      expect(edits.single.$2, isEmpty);
      await t.pump(const Duration(milliseconds: 500));
    });

    testWidgets('submits reply and updates preview hovering state on mouse enter/leave', (t) async {
      final replies = <(String, List<String>)>[];
      await render(
        t,
        (s) => CommentThread(
          comment: createComment(),
          source: s,
          onClose: () {},
          onReply: (c, ids) async => replies.add((c, ids)),
        ),
      );
      final values = <bool>[];
      store.isCommentPreviewHovering.addListener(() => values.add(store.isCommentPreviewHovering.value));
      final mouse = await mouseAt(t, const Offset(900, 700));
      await mouse.moveTo(const Offset(100, 100));
      await t.pump();
      await mouse.moveTo(const Offset(900, 700));
      await t.pump();
      expect(values, [true, false]);

      await t.enterText(find.byType(TextField), 'content:workflow.comments.placeholder.reply');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(replies.single.$1, 'content:workflow.comments.placeholder.reply');
      expect(replies.single.$2, isEmpty);
      await t.pump(const Duration(milliseconds: 500));
    });

    testWidgets('supports editing and direct deleting an existing reply', (t) async {
      final edits = <(String, String, List<String>)>[];
      final deleted = <String>[];
      await render(
        t,
        (s) => CommentThread(
          comment: createComment(),
          source: s,
          onClose: () {},
          onReplyEdit: (id, c, ids) async => edits.add((id, c, ids)),
          onReplyDeleteDirect: deleted.add,
        ),
      );
      final mouse = await mouseAt(t, t.getCenter(find.text('first reply')));
      await t.tap(pressable('workflow.comments.aria.replyActions'));
      await t.pumpAndSettle();
      await t.tap(find.text('workflow.comments.actions.editReply'));
      await t.pump();
      await t.tap(find.text('common.operation.save'));
      await t.pump();
      expect((edits.single.$1, edits.single.$2), ('reply-1', 'first reply'));
      expect(edits.single.$3, isEmpty);

      await t.pumpAndSettle();
      await mouse.moveTo(const Offset(900, 700));
      await mouse.moveTo(t.getCenter(find.text('first reply')));
      await t.pump();
      await t.tap(pressable('workflow.comments.aria.replyActions'));
      await t.pumpAndSettle();
      await t.tap(find.text('workflow.comments.actions.deleteReply'));
      await t.pump();
      await t.tap(find.text('common.operation.yes'));
      await t.pumpAndSettle();
      expect(deleted, ['reply-1']);
    });
  });
}
