// dify-spec: web/app/components/workflow/persistence/__tests__/local-storage-bridge.spec.tsx
import 'package:dify_sf_app/src/canvas/canvas_input.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('WorkflowLocalStorageBridge', () {
    test('hydrates workflow preferences from localStorage', () async {
      SharedPreferences.setMockInitialValues({
        'workflow-node-panel-width': '460',
        'debug-and-preview-panel-width': '520',
        'workflow-variable-inpsect-panel-height': '240',
        'workflow-operation-mode': ControlMode.hand.name,
      });

      final store = WorkflowStore();
      final preferences = WorkflowPreferences();
      final bridge = WorkflowLocalStorageBridge(store, preferences);
      await preferences.loaded;

      expect(store.nodePanelWidth.value, 460);
      expect(store.panelWidth.value, 460);
      expect(store.previewPanelWidth.value, 520);
      expect(store.variableInspectPanelHeight.value, 240);
      expect(store.controlMode.value, ControlMode.hand);

      bridge.dispose();
      preferences.dispose();
      store.dispose();
    });

    test('persists control mode updates from the workflow store', () async {
      final store = WorkflowStore();
      final preferences = WorkflowPreferences();
      final bridge = WorkflowLocalStorageBridge(store, preferences);
      await preferences.loaded;

      store.setControlMode(ControlMode.comment);

      await pumpEventQueue();
      final stored = await SharedPreferences.getInstance();
      expect(stored.getString('workflow-operation-mode'), ControlMode.comment.name);

      bridge.dispose();
      preferences.dispose();
      store.dispose();
    });
  });
}
