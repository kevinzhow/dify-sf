// dify-spec: web/app/components/workflow/comment/comment-icon.spec.tsx
import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/comment_icon.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/workflow_comment.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';
import 'comment_harness.dart';

Comment createComment({double x = 0, double y = 0}) => Comment(
  id: 'comment-1',
  positionX: x,
  positionY: y,
  content: 'Hello',
  createdBy: 'user-1',
  createdByName: 'Alice',
  createdAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true),
);

/// A pin whose comment follows its position updates (the store's optimistic move).
class _Movable extends StatefulWidget {
  const _Movable({required this.source, required this.view, required this.onClick, required this.onPositionUpdate});
  final CommentsStore source;
  final CanvasController view;
  final VoidCallback onClick;
  final ValueChanged<Offset> onPositionUpdate;

  @override
  State<_Movable> createState() => _MovableState();
}

class _MovableState extends State<_Movable> {
  Comment comment = createComment();

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      CommentIcon(
        comment: comment,
        source: widget.source,
        view: widget.view.view,
        onClick: widget.onClick,
        onPositionUpdate: (p) {
          widget.onPositionUpdate(p);
          setState(() => comment = comment.copyWith(positionX: p.dx, positionY: p.dy));
        },
      ),
    ],
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

  Finder marker() => find.bySemanticsLabel(RegExp('workflow.keyboard.openComment'));
  FocusNode focused() => FocusManager.instance.primaryFocus!;

  Future<CommentsStore> render(WidgetTester t, Widget Function(CommentsStore s) build, {String user = 'user-1'}) async {
    final comments = h.store(user);
    await pumpComments(t, build(comments), store: store, comments: comments);
    await settle(t);
    return comments;
  }

  group('CommentIcon', () {
    testWidgets('opens with the keyboard and moves an authored comment in canvas coordinates', (t) async {
      final semantics = t.ensureSemantics();
      var clicks = 0;
      final updates = <Offset>[];
      await render(
        t,
        (s) => _Movable(source: s, view: canvas, onClick: () => clicks++, onPositionUpdate: updates.add),
      );
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(marker(), findsOneWidget);
      final node = focused();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(clicks, 1);

      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.pump();
      expect(updates.last, const Offset(5, 20));
      expect(focused(), node);

      updates.clear();
      await t.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      expect(updates, isEmpty);
      await t.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      expect(updates, [const Offset(20, 20)]);
      semantics.dispose();
    });

    testWidgets("allows opening another author's comment but does not move it with arrow keys", (t) async {
      var clicks = 0;
      final updates = <Offset>[];
      await render(
        t,
        user: 'user-2',
        (s) => _Movable(source: s, view: canvas, onClick: () => clicks++, onPositionUpdate: updates.add),
      );
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(updates, isEmpty);
      expect(clicks, 1);
    });

    testWidgets('toggles preview on hover when inactive', (t) async {
      await render(
        t,
        (s) => Stack(
          children: [
            CommentIcon(comment: createComment(x: 200, y: 300), source: s, view: canvas.view, onClick: () {}),
          ],
        ),
      );
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(900, 700));
      await mouse.moveTo(const Offset(200, 300));
      await t.pump();
      expect(find.byType(CommentPreview), findsOneWidget);
      await mouse.moveTo(const Offset(900, 700));
      await t.pump();
      expect(find.byType(CommentPreview), findsNothing);
    });

    testWidgets('calls onPositionUpdate after dragging by author', (t) async {
      var clicks = 0;
      final updates = <Offset>[];
      await render(
        t,
        (s) => Stack(
          children: [
            CommentIcon(
              comment: createComment(),
              source: s,
              view: canvas.view,
              onClick: () => clicks++,
              onPositionUpdate: updates.add,
            ),
          ],
        ),
      );
      final g = await t.startGesture(const Offset(5, 5));
      await g.moveTo(const Offset(15, 15));
      await t.pump();
      await g.up();
      await t.pump();
      expect(updates, [const Offset(10, 10)]);
      expect(clicks, 0);
    });

    testWidgets('calls onClick for non-author clicks', (t) async {
      var clicks = 0;
      await render(
        t,
        user: 'user-2',
        (s) => Stack(
          children: [
            CommentIcon(comment: createComment(x: 50, y: 60), source: s, view: canvas.view, onClick: () => clicks++),
          ],
        ),
      );
      await t.tapAt(const Offset(50, 60));
      expect(clicks, 1);
    });
  });
}
