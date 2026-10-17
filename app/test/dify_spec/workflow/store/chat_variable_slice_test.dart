// dify-spec: web/app/components/workflow/store/__tests__/chat-variable-slice.spec.ts
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late WorkflowStore store;
  setUp(() => store = WorkflowStore());
  tearDown(() => store.dispose());

  group('Chat Variable Slice', () {
    group('setShowChatVariablePanel', () {
      test('should hide other panels when opening', () {
        store.setShowDebugAndPreviewPanel(true);
        store.setShowEnvPanel(true);

        store.setShowChatVariablePanel(true);

        expect(store.showChatVariablePanel.value, true);
        expect(store.showDebugAndPreviewPanel.value, false);
        expect(store.showEnvPanel.value, false);
        expect(store.showGlobalVariablePanel.value, false);
      });

      test('should only close itself when setting false', () {
        store.setShowChatVariablePanel(true);

        store.setShowChatVariablePanel(false);

        expect(store.showChatVariablePanel.value, false);
      });
    });

    group('setShowGlobalVariablePanel', () {
      test('should hide other panels when opening', () {
        store.setShowDebugAndPreviewPanel(true);
        store.setShowChatVariablePanel(true);

        store.setShowGlobalVariablePanel(true);

        expect(store.showGlobalVariablePanel.value, true);
        expect(store.showDebugAndPreviewPanel.value, false);
        expect(store.showChatVariablePanel.value, false);
        expect(store.showEnvPanel.value, false);
      });

      test('should only close itself when setting false', () {
        store.setShowGlobalVariablePanel(true);
        store.setShowGlobalVariablePanel(false);

        expect(store.showGlobalVariablePanel.value, false);
      });
    });

    group('setConversationVariables', () {
      test('should update conversationVariables', () {
        final vars = [
          <String, Object?>{'id': 'cv1', 'name': 'history', 'value': [], 'value_type': 'string', 'description': ''},
        ];
        store.setConversationVariables(vars);
        expect(store.conversationVariables.value, vars);
      });
    });
  });
}
