// dify-spec: web/app/components/workflow/hooks/__tests__/use-workflow-mode.spec.ts
import 'package:dify_sf_app/src/workflow_editor/header/header_data.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late WorkflowStore store;
  setUp(() => store = WorkflowStore());
  tearDown(() => store.dispose());

  group('useWorkflowMode', () {
    test('should return normal mode when no history data and not restoring', () {
      expect(workflowModeOf(store), (normal: true, restoring: false, viewHistory: false));
    });

    test('should return restoring mode when isRestoring is true', () {
      store.setIsRestoring(true);
      expect(workflowModeOf(store), (normal: false, restoring: true, viewHistory: false));
    });

    test('should return viewHistory mode when historyWorkflowData exists', () {
      store.setHistoryWorkflowData({'id': 'v1', 'status': 'succeeded'});
      expect(workflowModeOf(store), (normal: false, restoring: false, viewHistory: true));
    });

    test('should prioritize restoring over viewHistory when both are set', () {
      store
        ..setIsRestoring(true)
        ..setHistoryWorkflowData({'id': 'v1', 'status': 'succeeded'});
      final mode = workflowModeOf(store);
      expect(mode.restoring, isTrue);
      expect(mode.normal, isFalse);
    });
  });
}
