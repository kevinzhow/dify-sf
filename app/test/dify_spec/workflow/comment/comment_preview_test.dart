// dify-spec: web/app/components/workflow/comment/comment-preview.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/comments/comment_icon.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/workflow_comment.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';
import 'comment_harness.dart';

/// Alice's comment with Bob among the participants (Bob replied), updated at 10 s.
Comment createComment() => Comment(
  id: 'comment-1',
  positionX: 0,
  positionY: 0,
  content: 'Hello',
  createdBy: 'user-1',
  createdByName: 'Alice',
  createdAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(10000, isUtc: true),
  replies: [
    CommentReply(
      id: 'reply-1',
      content: 'Hi',
      createdBy: 'user-2',
      createdByName: 'Bob',
      createdAt: DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true),
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

  Future<CommentsStore> render(WidgetTester t, {bool show = true}) async {
    final comments = h.store('user-1');
    await pumpComments(
      t,
      show
          ? Align(
              alignment: Alignment.topLeft,
              child: CommentPreview(comment: createComment(), source: comments, formatTimeFromNow: fakeTime),
            )
          : const SizedBox(),
      store: store,
      comments: comments,
    );
    await settle(t);
    return comments;
  }

  group('CommentPreview', () {
    testWidgets('orders participants with author first and formats time', (t) async {
      await render(t);
      final list = t.widget<UserAvatarList>(find.byType(UserAvatarList));
      expect([for (final u in list.users) u.id], ['user-1', 'user-2']);
      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('time:10000'), findsOneWidget);
    });

    testWidgets('updates hover state on enter and leave', (t) async {
      await render(t);
      final values = <bool>[];
      store.isCommentPreviewHovering.addListener(() => values.add(store.isCommentPreviewHovering.value));
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(1000, 700));
      await mouse.moveTo(t.getCenter(find.byType(CommentPreview)));
      await t.pump();
      await mouse.moveTo(const Offset(1000, 700));
      await t.pump();
      expect(values, [true, false]);
    });

    testWidgets('clears hover state on unmount', (t) async {
      final comments = await render(t);
      store.setCommentPreviewHovering(true);
      await pumpComments(t, const SizedBox(), store: store, comments: comments);
      await t.pump();
      expect(store.isCommentPreviewHovering.value, isFalse);
    });
  });
}
