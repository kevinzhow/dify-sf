// dify-spec: web/app/components/workflow/comment/__tests__/comment-thread-focus.spec.tsx
import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/comment_layer.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/comment_thread.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/workflow_comment.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart' show TextField;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';
import 'comment_harness.dart';

class _Navigating extends StatefulWidget {
  const _Navigating({required this.source, required this.comment});
  final CommentsStore source;
  final Comment comment;

  @override
  State<_Navigating> createState() => _NavigatingState();
}

class _NavigatingState extends State<_Navigating> {
  late Comment comment = widget.comment;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: CommentThread(
      comment: comment,
      source: widget.source,
      onClose: () {},
      onReply: (_, _) async {},
      canGoNext: true,
      onNext: () => setState(
        () => comment = Comment(
          id: 'comment-2',
          positionX: comment.positionX,
          positionY: comment.positionY,
          content: comment.content,
          createdBy: comment.createdBy,
          createdAt: comment.createdAt,
          updatedAt: comment.updatedAt,
        ),
      ),
    ),
  );
}

void main() {
  late WorkflowStore store;
  late CommentsHarness h;
  late CanvasController canvas;

  setUp(() {
    useDifyTestTranslator();
    store = WorkflowStore();
    h = CommentsHarness();
    canvas = identityCanvas();
  });
  tearDown(() {
    h.dispose();
    store.dispose();
    canvas.dispose();
  });

  Future<void> wait(WidgetTester t, [int ms = 800]) async {
    for (var i = 0; i < ms ~/ 100; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await settle(t);
  }

  bool replyFocused(WidgetTester t) => t.widget<TextField>(find.byType(TextField)).focusNode!.hasPrimaryFocus;

  group('Comment thread focus', () {
    testWidgets('keeps focus on the marker after saving a keyboard move with its thread open', (t) async {
      final id = h.seed(x: 120, y: 80, content: 'Move this comment');
      store.setShowUserComments(true);
      await pumpComments(
        t,
        Stack(
          children: [Positioned.fill(child: CommentLayer(canvas: canvas))],
        ),
        store: store,
        comments: h.store('user-1'),
      );
      await settle(t);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      final marker = FocusManager.instance.primaryFocus!;
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await wait(t);
      expect(replyFocused(t), isTrue);

      marker.requestFocus();
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(t);
      expect(h.api.callsOf('update').last, {'id': id, 'author': 'user-1', 'x': 125.0, 'y': 80.0});
      await wait(t, 100);
      expect(marker.hasPrimaryFocus, isTrue);

      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await settle(t);
      expect(h.api.callsOf('update').last, {'id': id, 'author': 'user-1', 'x': 125.0, 'y': 85.0});
      expect(h.api.callsOf('update'), hasLength(2));
    });

    testWidgets('focuses the reply input when navigating to another comment', (t) async {
      final comments = h.store('user-1');
      await pumpComments(
        t,
        _Navigating(
          source: comments,
          comment: Comment(
            id: 'comment-1',
            positionX: 120,
            positionY: 80,
            content: 'Move this comment',
            createdBy: 'user-1',
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
        ),
        store: store,
        comments: comments,
      );
      await wait(t, 100);
      expect(replyFocused(t), isTrue);

      await t.tap(pressable('workflow.comments.aria.nextComment'));
      await wait(t, 100);
      expect(replyFocused(t), isTrue);
    });
  });
}
