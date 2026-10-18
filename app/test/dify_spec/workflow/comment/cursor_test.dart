// dify-spec: web/app/components/workflow/comment/cursor.spec.tsx
import 'package:dify_sf_app/src/canvas/canvas_input.dart' show ControlMode;
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/comment_layer.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'comment_harness.dart';

void main() {
  late WorkflowStore store;
  late CommentsHarness h;

  setUp(() {
    store = WorkflowStore()..setMousePosition((pageX: 10, pageY: 20, elementX: 10, elementY: 20));
    h = CommentsHarness();
  });
  tearDown(() {
    h.dispose();
    store.dispose();
  });

  final icon = find.byWidgetPredicate((w) => w is DifyIcon && w.name == 'public/other/comment');

  Future<void> render(WidgetTester t) => pumpComments(
    t,
    const Stack(children: [CommentCursor()]),
    store: store,
    comments: h.store('user-1'),
  );

  group('CommentCursor', () {
    testWidgets('renders nothing when not in comment mode', (t) async {
      store.setControlMode(ControlMode.pointer);
      await render(t);
      expect(icon, findsNothing);
    });

    testWidgets('renders at current mouse position when in comment mode', (t) async {
      store
        ..setControlMode(ControlMode.comment)
        ..setCommentPlacing(false);
      await render(t);
      // `left: elementX, top: elementY, translate(-50%, -50%)`: centred on the pointer.
      expect(t.getCenter(icon), const Offset(10, 20));
    });

    testWidgets('renders nothing when comment is in placing mode', (t) async {
      store
        ..setControlMode(ControlMode.comment)
        ..setCommentPlacing(true);
      await render(t);
      expect(icon, findsNothing);
    });
  });
}
