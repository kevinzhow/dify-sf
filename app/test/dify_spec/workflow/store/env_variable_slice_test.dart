// dify-spec: web/app/components/workflow/store/__tests__/env-variable-slice.spec.ts
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late WorkflowStore store;
  setUp(() => store = WorkflowStore());
  tearDown(() => store.dispose());

  group('Env Variable Slice', () {
    group('setShowEnvPanel', () {
      test('should hide other panels when opening', () {
        store.setShowDebugAndPreviewPanel(true);
        store.setShowChatVariablePanel(true);

        store.setShowEnvPanel(true);

        expect(store.showEnvPanel.value, true);
        expect(store.showDebugAndPreviewPanel.value, false);
        expect(store.showChatVariablePanel.value, false);
        expect(store.showGlobalVariablePanel.value, false);
      });

      test('should only close itself when setting false', () {
        store.setShowEnvPanel(true);

        store.setShowEnvPanel(false);

        expect(store.showEnvPanel.value, false);
      });
    });

    group('setEnvironmentVariables', () {
      test('should update environmentVariables', () {
        final vars = [
          <String, Object?>{
            'id': 'v1',
            'name': 'API_KEY',
            'value': 'secret',
            'value_type': 'string',
            'description': '',
          },
        ];
        store.setEnvironmentVariables(vars);
        expect(store.environmentVariables.value, vars);
      });
    });

    group('setEnvSecrets', () {
      test('should update envSecrets', () {
        store.setEnvSecrets({'API_KEY': '***'});
        expect(store.envSecrets.value, {'API_KEY': '***'});
      });
    });

    group('Sequential Panel Switching', () {
      test('should correctly switch between exclusive panels', () {
        store.setShowChatVariablePanel(true);
        expect(store.showChatVariablePanel.value, true);

        store.setShowEnvPanel(true);
        expect(store.showEnvPanel.value, true);
        expect(store.showChatVariablePanel.value, false);

        store.setShowGlobalVariablePanel(true);
        expect(store.showGlobalVariablePanel.value, true);
        expect(store.showEnvPanel.value, false);
      });
    });
  });
}
