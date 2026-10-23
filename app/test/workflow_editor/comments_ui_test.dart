import 'package:dify_sf_app/src/canvas/canvas_input.dart' show ControlMode;
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/comment_icon.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/comment_input.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/comment_layer.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/comment_thread.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/comments_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_spec/dify_test_i18n.dart';
import '../support/app_fonts.dart';

import 'package:dify_sf_app/src/design/widgets/toast.dart' show DifyToastHost;

const _me = 'me-abc123';

/// The whole editor over the in-memory demo server: comment mode, placing, replying, resolving, author-only edits
/// and moves, and another client's comment arriving through the store.
void main() {
  late DemoBackend demo;

  Future<void> frames(WidgetTester t, [int n = 10]) async {
    await t.pump();
    await t.pump();
    for (var i = 0; i < n; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<WorkflowStore> open(WidgetTester t) async {
    useDifyTestTranslator();
    await useAppFonts();
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    demo = DemoBackend(withBo: false);
    demo.server
      ..setClientName(_me, 'Me')
      ..setClientName('bob', 'Bob');
    await t.pumpWidget(
      MaterialApp(
        home: EditorPage(backend: demo, docId: 'demo', clientId: _me, displayName: 'Me', journaled: false),
        builder: (context, child) => Stack(children: [child!, const DifyToastHost()]),
      ),
    );
    await frames(t, 20);
    return WorkflowStoreScope.of(t.element(find.byType(CommentLayer)));
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  }

  /// A spot on empty canvas.
  const empty = Offset(700, 650);

  Finder pin(String content) => find.byWidgetPredicate((w) => w is CommentIcon && w.comment.content == content);

  Future<void> hover(WidgetTester t, TestGesture mouse, Offset at) async {
    await mouse.moveTo(at);
    await t.pump(const Duration(milliseconds: 50));
  }

  testWidgets('comment mode: place a comment, reply, resolve; the list follows', (t) async {
    final store = await open(t);
    // The control bar's comment mode button.
    await t.tap(find.bySemanticsLabel('workflow.common.commentMode'));
    await t.pump();
    expect(store.controlMode.value, ControlMode.comment);
    expect(find.byType(CommentsPanelBody), findsOneWidget, reason: 'the list opens on the right');

    // A click on the canvas opens the new comment's box there; Enter sends it.
    await t.tapAt(empty);
    await frames(t, 2);
    expect(find.byType(CommentInput), findsOneWidget);
    await t.enterText(find.descendant(of: find.byType(CommentInput), matching: find.byType(TextField)), 'Why gpt-4o?');
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await frames(t, 5);
    expect(find.byType(CommentInput), findsNothing);
    final saved = demo.server.comments.list().single;
    expect((saved['content'], saved['created_by'], saved['created_by_name']), ('Why gpt-4o?', _me, 'Me'));
    expect(pin('Why gpt-4o?'), findsOneWidget);
    // The pin is centred where the click was.
    expect(t.getCenter(pin('Why gpt-4o?')), offsetMoreOrLessEquals(empty, epsilon: 0.5));
    expect(find.descendant(of: find.byType(CommentsPanelBody), matching: find.text('Why gpt-4o?')), findsOneWidget);

    // Opening it centres the view and shows the thread; a reply goes to the server.
    await t.tap(pin('Why gpt-4o?'));
    await frames(t, 8);
    expect(find.byType(CommentThread), findsOneWidget);
    await t.enterText(find.descendant(of: find.byType(CommentThread), matching: find.byType(TextField)), 'cheaper');
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await frames(t, 5);
    expect((demo.server.comments.list().single['replies']! as List).single, containsPair('content', 'cheaper'));
    expect(find.descendant(of: find.byType(CommentThread), matching: find.text('cheaper')), findsOneWidget);
    expect(find.text('1 workflow.comments.reply'), findsOneWidget);

    // Resolve: the thread goes with the pin (resolved comments are hidden by default).
    await t.tap(find.bySemanticsLabel('workflow.comments.aria.resolveComment').first);
    await frames(t, 5);
    expect(demo.server.comments.list().single['resolved'], isTrue);
    expect(find.byType(CommentThread), findsNothing);
    expect(pin('Why gpt-4o?'), findsNothing);

    // Leaving comment mode closes the list.
    await t.tap(find.bySemanticsLabel('workflow.common.pointerMode'));
    await t.pump();
    expect(find.byType(CommentsPanelBody), findsNothing);
    await close(t);
  });

  testWidgets("another client's comment arrives; only your own can be edited, deleted or moved", (t) async {
    final store = await open(t);
    store.setControlMode(ControlMode.comment);
    final bobs = demo.server.comments.create(client: 'bob', x: 200, y: 300, content: 'from Bob')['id']! as String;
    await frames(t, 5);
    expect(pin('from Bob'), findsOneWidget, reason: 'the stream announced it, the store refetched');
    final mine = demo.server.comments.create(client: _me, x: 600, y: 300, content: 'mine')['id']! as String;
    await frames(t, 5);

    // Bob's pin does not move when dragged: the drag is a click that opens it.
    final bobAt = t.getCenter(pin('from Bob'));
    await t.dragFrom(bobAt, const Offset(80, 40));
    await frames(t, 8);
    expect(demo.server.comments.get(bobs)['position_x'], 200);
    expect(find.byType(CommentThread), findsOneWidget);
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await hover(
      t,
      mouse,
      t.getCenter(find.descendant(of: find.byType(CommentThread), matching: find.text('from Bob'))),
    );
    expect(find.bySemanticsLabel('workflow.comments.aria.commentActions'), findsNothing, reason: 'not the author');
    // Bob's reply to his own thread has no actions for this client either.
    demo.server.comments.reply(bobs, client: 'bob', content: 'reply from Bob');
    await frames(t, 5);
    await hover(t, mouse, t.getCenter(find.text('reply from Bob')));
    expect(find.bySemanticsLabel('workflow.comments.aria.replyActions'), findsNothing);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(t, 2);
    expect(find.byType(CommentThread), findsNothing);

    // Your own pin follows a drag; the server gets the canvas point.
    final myAt = t.getCenter(pin('mine'));
    await t.dragFrom(myAt, const Offset(100, 50));
    await frames(t, 5);
    final moved = demo.server.comments.get(mine);
    expect(moved['position_x'], isNot(600));
    expect(t.getCenter(pin('mine')), offsetMoreOrLessEquals(myAt + const Offset(100, 50), epsilon: 0.5));
    expect(find.byType(CommentThread), findsNothing, reason: 'a drag does not open it');

    // Your own thread offers edit; the edit reaches the server.
    await t.tap(pin('mine'));
    await frames(t, 8);
    await hover(t, mouse, t.getCenter(find.descendant(of: find.byType(CommentThread), matching: find.text('mine'))));
    await t.tap(find.bySemanticsLabel('workflow.comments.aria.commentActions'));
    await frames(t, 2);
    await t.tap(find.text('workflow.comments.actions.editComment'));
    await frames(t, 2);
    await t.enterText(
      find.descendant(of: find.byType(CommentThread), matching: find.byType(TextField)).first,
      'mine, edited',
    );
    await t.tap(find.text('common.operation.save'));
    await frames(t, 5);
    expect(demo.server.comments.get(mine)['content'], 'mine, edited');

    // Deleting your own thread asks first, then the next comment's thread opens.
    await t.tap(find.bySemanticsLabel('workflow.comments.aria.deleteComment'));
    await frames(t, 2);
    await t.tap(find.text('common.operation.confirm'));
    await frames(t, 8);
    expect(demo.server.comments.length, 1);
    expect(find.descendant(of: find.byType(CommentThread), matching: find.text('from Bob')), findsOneWidget);

    // Deleting someone else's thread: the button is there (as in Dify), the server refuses, and a toast says why.
    await t.tap(find.bySemanticsLabel('workflow.comments.aria.deleteComment'));
    await frames(t, 2);
    await t.tap(find.text('common.operation.confirm'));
    await frames(t, 8);
    expect(demo.server.comments.length, 1);
    expect(find.text('Only the author can delete this thread'), findsOneWidget);
    await close(t);
  });
}
