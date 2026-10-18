// dify-spec: web/app/components/workflow/hooks/__tests__/use-workflow.spec.ts
//
// useIsChatMode is DocMeta.isChatflow (the app's mode); useWorkflowReadOnly / useNodesReadOnly are the store's
// workflowReadOnly / nodesReadOnlyOf (Dify's `accessControl.canEdit` passed in: the header data's, true by default);
// isValidConnection and useIsNodeInIteration / useIsNodeInLoop are hooks/use_workflow.dart over the document.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/header/header_data.dart';
import 'package:dify_sf_app/src/workflow_editor/hooks/use_workflow.dart';
import 'package:dify_sf_app/src/workflow_editor/operator/actions.dart' show OperatorReadOnly;
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../context_menu/harness.dart' show node;

/// `baseRunningData(overrides)`: a run, `running` unless [status] says otherwise.
DifyJson _running([String status = 'running', String taskId = 'task-1']) => {
  'task_id': taskId,
  'result': {'status': status},
  'tracing': <Object?>[],
};

void main() {
  late WorkflowStore store;
  setUp(() => store = WorkflowStore());
  tearDown(() => store.dispose());

  bool nodesReadOnly({bool? canEdit}) => nodesReadOnlyOf(store, canEdit: canEdit ?? const WorkflowHeaderData().canEdit);

  group('useIsChatMode', () {
    test('should return true when app mode is advanced-chat', () {
      expect(const DocMeta(appMode: 'advanced-chat').isChatflow, isTrue);
    });

    test('should return false when app mode is workflow', () {
      expect(const DocMeta(appMode: 'workflow').isChatflow, isFalse);
    });

    test('should return false when app mode is chat', () {
      expect(const DocMeta(appMode: 'chat').isChatflow, isFalse);
    });

    test('should return false when app mode is completion', () {
      expect(const DocMeta(appMode: 'completion').isChatflow, isFalse);
    });
  });

  group('useWorkflowReadOnly', () {
    test('should return workflowReadOnly true when status is Running', () {
      store.setWorkflowRunningData(_running());
      expect(store.workflowReadOnly, isTrue);
    });

    test('should return workflowReadOnly false when status is Succeeded', () {
      store.setWorkflowRunningData(_running('succeeded'));
      expect(store.workflowReadOnly, isFalse);
    });

    test('should return workflowReadOnly false when no running data', () {
      expect(store.workflowReadOnly, isFalse);
    });

    test('should return workflowReadOnly true when canvas is read only', () {
      store.setCanvasReadOnly(true);
      expect(store.workflowReadOnly, isTrue);
    });

    test('should expose getWorkflowReadOnly that reads from store state', () {
      expect(store.workflowReadOnly, isFalse);
      store.setWorkflowRunningData(_running('running', 'task-2'));
      expect(store.workflowReadOnly, isTrue);
    });
  });

  group('useNodesReadOnly', () {
    test('should use the default HooksStoreContext from the workflow test helper', () {
      expect(nodesReadOnly(), isFalse);
      expect(store.nodesReadOnly, isFalse);
    });

    test('should return true when explicit edit permission is denied before HooksStoreContext is available', () {
      expect(nodesReadOnly(canEdit: false), isTrue);
    });

    test('should return false when edit permission is allowed by HooksStoreContext', () {
      expect(nodesReadOnly(canEdit: true), isFalse);
    });

    test('should expose getNodesReadOnly that reads from store state', () {
      expect(nodesReadOnly(canEdit: true), isFalse);
      store.setIsRestoring(true);
      expect(nodesReadOnly(canEdit: true), isTrue);
    });

    test('should return true when status is Running', () {
      store.setWorkflowRunningData(_running());
      expect(nodesReadOnly(canEdit: true), isTrue);
      expect(store.nodesReadOnly, isTrue);
    });

    test('should return true when status is Paused', () {
      store.setWorkflowRunningData(_running('paused'));
      expect(nodesReadOnly(canEdit: true), isTrue);
      expect(store.nodesReadOnly, isTrue);
    });

    test('should return true when historyWorkflowData is present', () {
      store.setHistoryWorkflowData({'id': 'run-1', 'status': 'succeeded'});
      expect(nodesReadOnly(canEdit: true), isTrue);
      expect(store.nodesReadOnly, isTrue);
    });

    test('should return true when isRestoring is true', () {
      store.setIsRestoring(true);
      expect(nodesReadOnly(canEdit: true), isTrue);
      expect(store.nodesReadOnly, isTrue);
    });

    test('should return true when canvas is read only', () {
      store.setCanvasReadOnly(true);
      expect(nodesReadOnly(), isTrue);
      expect(store.nodesReadOnly, isTrue);
    });

    test('should return false when none of the conditions are met', () {
      expect(nodesReadOnly(canEdit: true), isFalse);
      expect(store.nodesReadOnly, isFalse);
    });

    test('should return true when edit permission is denied by HooksStoreContext', () {
      expect(nodesReadOnly(canEdit: false), isTrue);
    });
  });

  group('useWorkflow connection validation', () {
    test('should validate Agent V2 graph nodes against the Agent V2 catalog type', () {
      final doc = Document(
        nodes: [
          node(
            'agent-v2',
            type: 'agent',
            title: 'Agent',
            config: const {'agent_node_kind': VString('dify_agent'), 'version': VString('2')},
          ),
          node('code', title: 'Code'),
        ],
      );
      expect(getNodeCatalogType(doc.nodes['agent-v2']!), 'agent-v2');
      // The app's blocks hold Agent v2 (and Code), as Dify's availableNodesMetaData in the case.
      expect(isValidConnection(doc, source: 'agent-v2', sourceHandle: 'source', target: 'code', agentV2: true), isTrue);
    });
  });

  Document containerDoc(String type) => Document(
    nodes: [
      node('$type-1', type: type),
      node('child-1', parent: '$type-1'),
      node('grandchild-1', parent: 'child-1'),
      node('outside-1'),
    ],
  );

  group('useIsNodeInIteration', () {
    final doc = containerDoc('iter');

    test('should return true when node is a direct child of the iteration', () {
      expect(isNodeInContainer(doc, 'iter-1', 'child-1'), isTrue);
    });

    test('should return false for a grandchild (only checks direct parentId)', () {
      expect(isNodeInContainer(doc, 'iter-1', 'grandchild-1'), isFalse);
    });

    test('should return false when node is outside the iteration', () {
      expect(isNodeInContainer(doc, 'iter-1', 'outside-1'), isFalse);
    });

    test('should return false when node does not exist', () {
      expect(isNodeInContainer(doc, 'iter-1', 'nonexistent'), isFalse);
    });

    test('should return false when iteration id has no children', () {
      expect(isNodeInContainer(doc, 'no-such-iter', 'child-1'), isFalse);
    });
  });

  group('useIsNodeInLoop', () {
    final doc = containerDoc('loop');

    test('should return true when node is a direct child of the loop', () {
      expect(isNodeInContainer(doc, 'loop-1', 'child-1'), isTrue);
    });

    test('should return false for a grandchild (only checks direct parentId)', () {
      expect(isNodeInContainer(doc, 'loop-1', 'grandchild-1'), isFalse);
    });

    test('should return false when node is outside the loop', () {
      expect(isNodeInContainer(doc, 'loop-1', 'outside-1'), isFalse);
    });

    test('should return false when node does not exist', () {
      expect(isNodeInContainer(doc, 'loop-1', 'nonexistent'), isFalse);
    });

    test('should return false when loop id has no children', () {
      expect(isNodeInContainer(doc, 'no-such-loop', 'child-1'), isFalse);
    });
  });
}
