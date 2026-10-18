// dify-spec: web/app/components/workflow/comment/comment-movement.browser.spec.tsx
import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/comment_icon.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/comment_input.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/workflow_comment.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';
import 'comment_harness.dart';

/// Dify's fixture: an authored pin at (100, 100) that follows its moves and says when it opened, or a draft box.
class _Fixture extends StatefulWidget {
  const _Fixture({required this.source, required this.canvas, this.draft = false});
  final CommentsStore source;
  final CanvasController canvas;
  final bool draft;

  @override
  State<_Fixture> createState() => _FixtureState();
}

class _FixtureState extends State<_Fixture> {
  Comment current = Comment(
    id: 'comment',
    positionX: 100,
    positionY: 100,
    content: 'Comment',
    createdBy: 'author',
    createdByName: 'Alice',
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );
  Offset position = const Offset(100, 100);
  bool opened = false;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      if (widget.draft)
        Positioned(
          left: position.dx,
          top: position.dy,
          child: CommentInput(
            position: position,
            onSubmit: (_, _) async {},
            onCancel: () {},
            users: const [],
            currentUser: (id: 'author', name: 'Alice'),
            autoFocus: false,
            onPositionChange: (next) => setState(() => position = Offset(next.elementX, next.elementY)),
          ),
        )
      else
        CommentIcon(
          comment: current,
          source: widget.source,
          view: widget.canvas.view,
          onClick: () => setState(() => opened = true),
          onPositionUpdate: (next) =>
              setState(() => current = current.copyWith(positionX: next.dx, positionY: next.dy)),
        ),
      if (opened) const Positioned(left: 0, bottom: 0, child: Text('Comment opened')),
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
    h = CommentsHarness()..server.setClientName('author', 'Alice');
    canvas = identityCanvas(viewport: const Size(1000, 800));
  });
  tearDown(() {
    h.dispose();
    store.dispose();
    canvas.dispose();
  });

  Future<void> render(WidgetTester t, {bool draft = false}) async {
    final comments = h.store('author');
    await pumpComments(
      t,
      _Fixture(source: comments, canvas: canvas, draft: draft),
      store: store,
      comments: comments,
      size: const Size(1000, 800),
    );
    await settle(t);
  }

  testWidgets('keeps an authored comment focusable and draggable after adding keyboard movement', (t) async {
    await render(t);
    final marker = find.byType(CommentIcon);
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    final focus = FocusManager.instance.primaryFocus!;
    expect(focus.debugLabel, 'comment marker');
    final initial = t.getTopLeft(marker);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump();
    expect(t.getTopLeft(marker).dx, initial.dx + 5);

    await t.dragFrom(t.getCenter(marker), const Offset(200, 150));
    await t.pump();
    expect(t.getTopLeft(marker).dx, greaterThan(initial.dx + 5));
    expect(find.text('Comment opened'), findsNothing);
    await t.tap(marker);
    await t.pump();
    expect(find.text('Comment opened'), findsOneWidget);
  });

  testWidgets('preserves draft mouse dragging and lets keyboard users move the same handle', (t) async {
    final semantics = t.ensureSemantics();
    await render(t, draft: true);
    final handle = find.bySemanticsLabel('workflow.keyboard.moveDraftComment');
    final initial = t.getTopLeft(handle);
    await t.dragFrom(t.getCenter(handle), const Offset(200, 150));
    await t.pump();
    expect(t.getTopLeft(handle).dx, greaterThan(initial.dx));

    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    expect(FocusManager.instance.primaryFocus!.debugLabel, 'move draft comment');
    final dragged = t.getTopLeft(handle);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump();
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(t.getTopLeft(handle), dragged + const Offset(5, 20));
    expect(t.getSemantics(handle), isSemantics(isToggled: false));
    semantics.dispose();
  });
}
