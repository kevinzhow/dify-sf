// dify-spec: web/app/components/workflow/node-actions-menu/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUp(() => DifyI18n.current = NsKeyTranslator());

  group('NodeActionsDropdown', () {
    Future<Harness> open(WidgetTester t, {bool showHelpLink = true, void Function(bool)? onOpenChange}) async {
      final h = await Harness.start(t, [node('node-1', title: 'Code Node')]);
      await t.pumpWidget(
        h.host(
          NodeActionsDropdown(
            actions: h.actions(WorkflowMenuOptions(openUrl: (_) {})),
            node: h['node-1']!,
            showHelpLink: showHelpLink,
            onOpenChange: onOpenChange,
          ),
        ),
      );
      return h;
    }

    Future<void> tapMore(WidgetTester t) async {
      await t.tap(find.bySemanticsLabel('common.operation.more'));
      await Harness.settle(t);
    }

    testWidgets('should open the dropdown and trigger single-run actions', (t) async {
      final changes = <bool>[];
      final h = await open(t, onOpenChange: changes.add);
      await tapMore(t);
      expect(changes, [true]);
      expect(find.text('workflow.panel.runThisStep'), findsOneWidget);
      expect(find.text('workflow.blocksAbout.code'), findsOneWidget);
      await h.tapText(t, 'workflow.panel.runThisStep');
      expect(h.controller.selectedNodeId, 'node-1');
      expect(h.store.initShowLastRunTab.value, isTrue);
      expect(h.store.pendingSingleRun.value, (nodeId: 'node-1', action: SingleRunAction.run));
      await h.dispose(t);
    });

    testWidgets('should hide single-run actions when nodes are readonly', (t) async {
      final h = await open(t);
      h.store.setCanvasReadOnly(true);
      await tapMore(t);
      expect(find.text('workflow.panel.runThisStep'), findsNothing);
      await h.dispose(t);
    });

    testWidgets('should hide the help link when showHelpLink is false', (t) async {
      final h = await open(t, showHelpLink: false);
      await tapMore(t);
      expect(find.text('workflow.panel.helpLink'), findsNothing);
      expect(find.text('workflow.blocksAbout.code'), findsOneWidget);
      await h.dispose(t);
    });
  });
}
