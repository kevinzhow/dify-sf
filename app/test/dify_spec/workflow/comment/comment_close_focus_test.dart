// dify-spec: web/app/components/workflow/comment/__tests__/comment-close-focus.spec.tsx
import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/comment_layer.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/comment_thread.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart' show TextField;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';
import 'comment_harness.dart';

void main() {
  late WorkflowStore store;
  late CommentsHarness h;
  late CanvasController canvas;

  setUp(() {
    useDifyTestTranslator();
    store = WorkflowStore()..setShowUserComments(true);
    h = CommentsHarness();
    canvas = identityCanvas();
  });
  tearDown(() {
    h.dispose();
    store.dispose();
    canvas.dispose();
  });

  Future<void> render(WidgetTester t) async {
    await pumpComments(
      t,
      Stack(
        children: [
          Positioned.fill(
            child: CommentLayer(canvas: canvas, formatTimeFromNow: (_) => 'just now'),
          ),
        ],
      ),
      store: store,
      comments: h.store('user-1'),
    );
    await settle(t);
  }

  /// Lets the view animation (600 ms) and the reply box's focus (100 ms) happen.
  Future<void> wait(WidgetTester t) async {
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await settle(t);
  }

  FocusNode? focused() => FocusManager.instance.primaryFocus;
  bool replyFocused(WidgetTester t) => t.widget<TextField>(find.byType(TextField)).focusNode!.hasPrimaryFocus;
  String? focusedMarker() => focused()?.debugLabel;

  group('Comment keyboard focus lifecycle', () {
    testWidgets('restores the current marker after \$open and \$close, so arrow keys still move it', (t) async {
      for (final (key, close) in [
        (LogicalKeyboardKey.enter, 'Escape'),
        (LogicalKeyboardKey.space, 'Escape'),
        (LogicalKeyboardKey.enter, 'close button'),
      ]) {
        h.server.comments
            .list()
            .map((c) => c['id']! as String)
            .toList()
            .forEach(
              (id) => h.server.comments.delete(id, client: 'user-1'),
            );
        final id = h.seed(content: 'Check this workflow');
        canvas.view
          ..center = const Offset(512, 384)
          ..scale = 1;
        await render(t);
        h.api.calls.clear();

        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        expect(focusedMarker(), 'comment marker $id');
        await t.sendKeyEvent(key);
        await wait(t);
        expect(find.byType(CommentThread), findsOneWidget);
        expect(replyFocused(t), isTrue);

        if (close == 'Escape') {
          await t.sendKeyEvent(LogicalKeyboardKey.escape);
        } else {
          await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await t.sendKeyEvent(LogicalKeyboardKey.tab);
          await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await t.pump();
          expect(
            focused()!.context!.findAncestorWidgetOfExactType<Semantics>()?.properties.label,
            'workflow.comments.aria.closeComment',
          );
          await t.sendKeyEvent(LogicalKeyboardKey.enter);
        }
        await wait(t);
        expect(find.byType(CommentThread), findsNothing);
        expect(focusedMarker(), 'comment marker $id');

        await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await settle(t);
        expect(h.api.callsOf('update').single, {'id': id, 'author': 'user-1', 'x': 15.0, 'y': 20.0});
        await t.pumpWidget(const SizedBox());
      }
    });

    testWidgets('restores the last viewed comment marker after navigating to another thread', (t) async {
      final other = h.seed(by: 'user-2', x: 200, content: 'Another comment');
      h.seed(content: 'Check this workflow');
      await render(t);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await wait(t);
      expect(replyFocused(t), isTrue);

      // Back over the close button to "next comment".
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await wait(t);
      expect(replyFocused(t), isTrue);
      expect(find.text('Another comment'), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await wait(t);

      expect(find.byType(CommentThread), findsNothing);
      expect(focusedMarker(), 'comment marker $other');
      expect(find.bySemanticsLabel(RegExp('openComment.*Bob')), findsOneWidget);
    });

    testWidgets('closes safely when comment markers have been hidden', (t) async {
      h.seed(content: 'Check this workflow');
      await render(t);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await wait(t);
      expect(replyFocused(t), isTrue);

      store.setShowUserComments(false);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await wait(t);

      expect(find.byType(CommentThread), findsNothing);
      expect(find.bySemanticsLabel(RegExp('keyboard.openComment')), findsNothing);
    });
  });
}
