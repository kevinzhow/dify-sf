// dify-spec: web/app/components/workflow/panel/global-variable-panel/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/global_variable_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

/// Text whose whole content is [text] (`getByText((_, node) => node?.textContent === text)`).
Finder textContent(String text) =>
    find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == text, description: 'text "$text"');

void main() {
  setUp(useDifyTestTranslator);

  Future<WorkflowStore> render(WidgetTester t, {required bool isChatMode, required bool isWorkflowPage}) async {
    final store = WorkflowStore()..setShowGlobalVariablePanel(true);
    addTearDown(store.dispose);
    await pumpPanel(
      t,
      GlobalVariablePanel(isChatMode: isChatMode, isWorkflowPage: isWorkflowPage),
      store: store,
    );
    return store;
  }

  group('global-variable-panel path', () {
    testWidgets('should render chat global variables and close the panel', (t) async {
      final store = await render(t, isChatMode: true, isWorkflowPage: false);

      expect(find.text('workflow.globalVar.title'), findsOneWidget);
      expect(textContent('sys.conversation_id'), findsOneWidget);
      expect(textContent('sys.dialog_count'), findsOneWidget);
      expect(textContent('sys.timestamp'), findsNothing);

      await tap(t, buttonNamed('common.operation.close'));

      expect(store.showGlobalVariablePanel.value, isFalse);
    });

    testWidgets('should render workflow trigger variables for non-chat workflow pages', (t) async {
      await render(t, isChatMode: false, isWorkflowPage: true);

      expect(textContent('sys.conversation_id'), findsNothing);
      expect(textContent('sys.dialog_count'), findsNothing);
      expect(textContent('sys.timestamp'), findsOneWidget);
      expect(find.text('workflow.globalVar.fieldsDescription.triggerTimestamp'), findsOneWidget);
    });
  });
}
