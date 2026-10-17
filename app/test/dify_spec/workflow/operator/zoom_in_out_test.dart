// dify-spec: web/app/components/workflow/operator/__tests__/zoom-in-out.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/operator/operator.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'operator_harness.dart';

void main() {
  group('workflow zoom controls', () {
    late WorkflowStore store;
    late TestCanvas canvas;
    var collaboration = true;
    var syncs = 0, miniMaps = 0, comments = 0, cursors = 0;

    setUp(() {
      store = WorkflowStore();
      canvas = TestCanvas();
      collaboration = true;
      syncs = miniMaps = comments = cursors = 0;
    });

    Future<void> render(WidgetTester t, {bool isCommentMode = false}) => pumpWithStore(
      t,
      store,
      ZoomInOut(
        canvas: canvas,
        options: OperatorOptions(collaborationEnabled: collaboration, onSyncDraft: () => syncs++),
        isCommentMode: isCommentMode,
        onToggleMiniMap: () => miniMaps++,
        onToggleUserComments: () => comments++,
        onToggleUserCursors: () => cursors++,
      ),
      align: Alignment.bottomRight, // where the operator puts it: the menu opens above
    );

    Finder label() => find.textContaining(RegExp(r'^\d+%$'));

    Finder menu() => find.byWidgetPredicate((w) => w is Semantics && w.properties.role == SemanticsRole.menu);

    Future<void> openMenu(WidgetTester t) async {
      await t.tap(label());
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
    }

    Future<void> choose(WidgetTester t, String text) async {
      await t.tap(find.descendant(of: menu(), matching: find.text(text)));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
    }

    testWidgets('zooms out and zooms in when the viewport is within the supported range', (t) async {
      await render(t);

      await t.tap(pressable('operator.zoomOut'));
      await t.tap(pressable('operator.zoomIn'));

      expect(canvas.zoomOuts, 1);
      expect(canvas.zoomIns, 1);
      expect(canvas.view.scale, closeTo(1, 1e-9));
    });

    testWidgets('zooms to a preset value and syncs the draft', (t) async {
      await render(t);

      await openMenu(t);
      await choose(t, '50%');

      expect(canvas.view.scale, 0.5);
      expect(syncs, 1);
    });

    testWidgets('zooms to %s and syncs the draft', (t) async {
      canvas.view.scale = 0.5;
      await render(t);
      for (final (text, zoom) in [('100%', 1.0), ('200%', 2.0)]) {
        syncs = 0;
        await openMenu(t);
        await choose(t, text);
        expect(canvas.view.scale, zoom);
        expect(syncs, 1);
      }
    });

    testWidgets('toggles collaboration options without syncing the draft', (t) async {
      await render(t);

      await openMenu(t);
      await choose(t, 'operator.showMiniMap');
      expect(miniMaps, 1);
      expect(syncs, 0);

      await openMenu(t);
      await choose(t, 'operator.showUserComments');
      expect(comments, 1);

      await openMenu(t);
      await choose(t, 'operator.showUserCursors');
      expect(cursors, 1);
    });

    testWidgets('keeps the show-user-comments action disabled in comment mode', (t) async {
      await render(t, isCommentMode: true);

      await openMenu(t);
      await t.tap(find.descendant(of: menu(), matching: find.text('operator.showUserComments')));
      await t.pump();

      expect(comments, 0);
    });

    testWidgets('does not open the menu when the workflow is read only', (t) async {
      store.setCanvasReadOnly(true);
      await render(t);

      await openMenu(t);

      expect(menu(), findsNothing);
    });

    testWidgets('blocks inline zooming out at the minimum viewport scale', (t) async {
      canvas.view.scale = 0.25;
      await render(t);

      await t.tap(pressable('operator.zoomOut'));
      expect(canvas.zoomOuts, 0);
    });

    testWidgets('blocks inline zooming in at the maximum viewport scale', (t) async {
      canvas.view.scale = 2;
      await render(t);

      await t.tap(pressable('operator.zoomIn'));
      expect(canvas.zoomIns, 0);
    });

    testWidgets('renders collaboration menu entries only when collaboration is enabled', (t) async {
      collaboration = false;
      await render(t);

      await openMenu(t);
      expect(find.descendant(of: menu(), matching: find.text('operator.showMiniMap')), findsOneWidget);
      expect(find.text('operator.showUserComments'), findsNothing);
      expect(find.text('operator.showUserCursors'), findsNothing);
    });
  });
}
