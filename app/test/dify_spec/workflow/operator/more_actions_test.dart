// dify-spec: web/app/components/workflow/operator/__tests__/more-actions.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/operator/operator.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'operator_harness.dart';

void main() {
  group('MoreActions', () {
    late WorkflowStore store;
    late List<(ExportImageFormat, bool)> exports;

    setUp(() {
      store = WorkflowStore();
      exports = [];
    });

    // MoreActions as the control bar mounts it: disabled while the nodes are read-only.
    Future<void> render(WidgetTester t) => pumpWithStore(
      t,
      store,
      ListenableBuilder(
        listenable: store.readOnlyChanges,
        builder: (context, _) => MoreActions(
          disabled: store.nodesReadOnly,
          onExportImage: (format, {required wholeWorkflow}) => exports.add((format, wholeWorkflow)),
        ),
      ),
    );

    Future<void> openMenu(WidgetTester t) async {
      await t.tap(pressable('common.moreActions'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
    }

    Future<void> choose(WidgetTester t, String label, int index) async {
      await t.tap(find.text(label).at(index));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
    }

    testWidgets('opens the menu and exports the current view as png', (t) async {
      await render(t);
      await openMenu(t);
      await choose(t, 'common.exportPNG', 0);

      expect(exports, [(ExportImageFormat.png, false)]);
      expect(find.text('common.exportImage'), findsNothing);
    });

    testWidgets('does not open the menu when the workflow is read only', (t) async {
      store.setCanvasReadOnly(true);
      await render(t);

      expect(await focusButton(t, 'common.moreActions'), isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump(const Duration(milliseconds: 200));

      expect(find.text('common.exportImage'), findsNothing);
    });

    testWidgets('exports the current view with %s', (t) async {
      for (final (label, format) in [
        ('common.exportJPEG', ExportImageFormat.jpeg),
        ('common.exportSVG', ExportImageFormat.svg),
      ]) {
        exports.clear();
        await render(t);
        await openMenu(t);
        await choose(t, label, 0);
        expect(exports, [(format, false)]);
      }
    });

    testWidgets('exports the whole workflow as svg', (t) async {
      await render(t);
      await openMenu(t);
      expect(find.text('common.currentWorkflow'), findsOneWidget);
      await choose(t, 'common.exportSVG', 1);

      expect(exports, [(ExportImageFormat.svg, true)]);
    });

    testWidgets('returns early when the workflow becomes read only before exporting', (t) async {
      await render(t);
      await openMenu(t);
      store.setCanvasReadOnly(true);
      await t.tap(find.text('common.exportJPEG').first);
      await t.pump(const Duration(milliseconds: 200));

      expect(exports, isEmpty);
    });
  });
}
