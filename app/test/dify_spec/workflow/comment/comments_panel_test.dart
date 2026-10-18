// dify-spec: web/app/components/workflow/panel/comments-panel/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/canvas/canvas_input.dart' show ControlMode;
import 'package:dify_sf_app/src/workflow_editor/comments/comments_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/controls.dart' show DifySwitch;
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';
import 'comment_harness.dart';

void main() {
  late WorkflowStore store;
  late CommentsHarness h;
  late CanvasController canvas;
  late String mine, others;

  setUp(() {
    useDifyTestTranslator();
    store = WorkflowStore()
      ..setControlMode(ControlMode.comment)
      ..setShowResolvedComments(true);
    h = CommentsHarness();
    canvas = identityCanvas();
    // c-1: my open thread with two replies; c-2: someone else's resolved thread.
    mine = h.seed(content: 'my open thread');
    h.server.comments
      ..reply(mine, client: 'user-2', content: 'a')
      ..reply(mine, client: 'user-1', content: 'b');
    others = h.seed(by: 'user-2', x: 30, y: 40, content: 'others resolved thread');
    h.server.comments.resolve(others, client: 'user-2');
  });
  tearDown(() {
    h.dispose();
    store.dispose();
    canvas.dispose();
  });

  Future<void> render(WidgetTester t) async {
    await pumpComments(
      t,
      Align(
        alignment: Alignment.topRight,
        child: SizedBox(
          height: 700,
          child: CommentsPanel(canvas: canvas, formatTimeFromNow: (_) => 'just now'),
        ),
      ),
      store: store,
      comments: h.store('user-1'),
    );
    await settle(t);
  }

  Future<void> wait(WidgetTester t) async {
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await settle(t);
  }

  group('CommentsPanel', () {
    testWidgets('filters comments and selects a thread', (t) async {
      await render(t);
      expect(find.text('my open thread'), findsOneWidget);
      expect(find.text('others resolved thread'), findsOneWidget);
      expect(find.text('2 workflow.comments.reply'), findsOneWidget);

      await t.tap(pressable('workflow.comments.aria.filterComments'));
      await t.pump();
      await t.tap(find.text('workflow.comments.filter.onlyYourThreads'));
      await t.pump();
      expect(find.text('others resolved thread'), findsNothing);
      expect(find.text('my open thread'), findsOneWidget);

      await t.tap(find.text('my open thread'));
      await wait(t);
      expect(store.activeCommentId.value, mine);
    });

    testWidgets('resolves a comment and syncs list refresh', (t) async {
      await render(t);
      await t.tap(find.bySemanticsLabel('workflow.comments.aria.resolveComment'));
      await settle(t);
      expect(h.api.callsOf('resolve').single, {'id': mine, 'author': 'user-1'});
      expect(store.activeCommentId.value, mine);
    });

    testWidgets('toggles show-resolved state from filter panel switch', (t) async {
      await render(t);
      await t.tap(pressable('workflow.comments.aria.filterComments'));
      await t.pump();
      await t.tap(find.byType(DifySwitch));
      await t.pump();
      expect(store.showResolvedComments.value, isFalse);
      expect(find.text('others resolved thread'), findsNothing);
    });
  });
}
