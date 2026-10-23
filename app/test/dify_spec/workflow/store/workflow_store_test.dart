// dify-spec: web/app/components/workflow/store/__tests__/workflow-store.spec.ts
import 'package:dify_sf_app/src/canvas/canvas_input.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Dify's `testSetter`: on a fresh store, the setter's value is what the field then holds.
void expectSetter<T>(ValueListenable<T> Function(WorkflowStore s) field, void Function(WorkflowStore s) set, T value) {
  final store = WorkflowStore();
  set(store);
  expect(field(store).value, equals(value));
  store.dispose();
}

class _AppSliceStore extends WorkflowStore with _AppSlice {}

mixin _AppSlice on WorkflowStore {
  final appId = ValueNotifier<String?>(null);
}

void main() {
  group('createWorkflowStore', () {
    group('Initial State', () {
      test('should create a store with all slices merged', () {
        final store = WorkflowStore();
        expect(store.showSingleRunPanel.value, false);
        expect(store.controlMode.value, isNotNull);
        expect(store.nodes.value, isEmpty);
        expect(store.environmentVariables.value, isEmpty);
        expect(store.conversationVariables.value, isEmpty);
        expect(store.nodesWithInspectVars.value, isEmpty);
        expect(store.workflowCanvasWidth.value, isNull);
        expect(store.draftUpdatedAt.value, 0);
        expect(store.versionHistory.value, isEmpty);
        store.dispose();
      });
    });

    group('Workflow Slice Setters', () {
      test('should update %s', () {
        final running = <String, Object?>{
          'result': {
            'status': 'running',
            'inputs_truncated': false,
            'process_data_truncated': false,
            'outputs_truncated': false,
          },
        };
        expectSetter((s) => s.workflowRunningData, (s) => s.setWorkflowRunningData(running), running);
        expectSetter((s) => s.isListening, (s) => s.setIsListening(true), true);
        expectSetter(
          (s) => s.listeningTriggerType,
          (s) => s.setListeningTriggerType('trigger-webhook'),
          'trigger-webhook',
        );
        expectSetter((s) => s.listeningTriggerNodeId, (s) => s.setListeningTriggerNodeId('node-abc'), 'node-abc');
        expectSetter((s) => s.listeningTriggerNodeIds, (s) => s.setListeningTriggerNodeIds(['n1', 'n2']), ['n1', 'n2']);
        expectSetter((s) => s.listeningTriggerIsAll, (s) => s.setListeningTriggerIsAll(true), true);
        expectSetter((s) => s.clipboardElements, (s) => s.setClipboardElements([]), <DifyJson>[]);
        expectSetter((s) => s.clipboardEdges, (s) => s.setClipboardEdges([]), <DifyJson>[]);
        const box = (x1: 0.0, y1: 0.0, x2: 100.0, y2: 100.0);
        expectSetter((s) => s.selection, (s) => s.setSelection(box), box);
        expectSetter((s) => s.bundleNodeSize, (s) => s.setBundleNodeSize(const Size(200, 100)), const Size(200, 100));
        const mouse = (pageX: 10.0, pageY: 20.0, elementX: 5.0, elementY: 15.0);
        expectSetter((s) => s.mousePosition, (s) => s.setMousePosition(mouse), mouse);
        final ShowConfirm confirm = (title: 'Delete?', desc: null, onConfirm: () {});
        expectSetter((s) => s.showConfirm, (s) => s.setShowConfirm(confirm), confirm);
        expectSetter((s) => s.controlPromptEditorRerenderKey, (s) => s.setControlPromptEditorRerenderKey(42), 42);
        expectSetter((s) => s.showImportDSLModal, (s) => s.setShowImportDSLModal(true), true);
        final upload = <String, Object?>{
          'batch_count_limit': 5,
          'image_file_batch_limit': 10,
          'single_chunk_attachment_limit': 10,
          'attachment_image_file_size_limit': 2,
          'file_size_limit': 15,
          'file_upload_limit': 5,
        };
        expectSetter((s) => s.fileUploadConfig, (s) => s.setFileUploadConfig(upload), upload);
      });

      test('should update controlMode in the workflow store', () {
        final store = WorkflowStore();
        store.setControlMode(ControlMode.pointer);
        expect(store.controlMode.value, ControlMode.pointer);
        store.dispose();
      });

      test('should update clipboard nodes and edges with setClipboardData', () {
        final store = WorkflowStore();
        final nodes = [
          <String, Object?>{
            'id': 'n-1',
            'type': 'custom',
            'position': {'x': 0, 'y': 0},
            'data': {},
          },
        ];
        final edges = [
          <String, Object?>{'id': 'e-1', 'source': 'n-1', 'target': 'n-2', 'data': {}},
        ];
        store.setClipboardData(nodes: nodes, edges: edges);
        expect(store.clipboardElements.value, nodes);
        expect(store.clipboardEdges.value, edges);
        store.dispose();
      });
    });

    group('Node Slice Setters', () {
      test('should update %s', () {
        expectSetter((s) => s.showSingleRunPanel, (s) => s.setShowSingleRunPanel(true), true);
        expectSetter((s) => s.nodeAnimation, (s) => s.setNodeAnimation(true), true);
        expectSetter((s) => s.candidateNode, (s) => s.setCandidateNode(null), null);
        expectSetter((s) => s.showAssignVariablePopup, (s) => s.setShowAssignVariablePopup(null), null);
        expectSetter(
          (s) => s.hoveringAssignVariableGroupId,
          (s) => s.setHoveringAssignVariableGroupId('group-1'),
          'group-1',
        );
        const payload = (nodeId: 'n1', nodeType: 'llm', handleType: 'source', handleId: 'h1');
        expectSetter((s) => s.connectingNodePayload, (s) => s.setConnectingNodePayload(payload), payload);
        expectSetter((s) => s.enteringNodePayload, (s) => s.setEnteringNodePayload(null), null);
        expectSetter((s) => s.iterTimes, (s) => s.setIterTimes(5), 5);
        expectSetter((s) => s.loopTimes, (s) => s.setLoopTimes(10), 10);
        final logMap = <String, Map<String, List<DifyJson>>>{};
        expectSetter((s) => s.iterParallelLogMap, (s) => s.setIterParallelLogMap(logMap), logMap);
        const run = (nodeId: 'n1', action: SingleRunAction.run);
        expectSetter((s) => s.pendingSingleRun, (s) => s.setPendingSingleRun(run), run);
      });
    });

    group('Panel Slice Setters', () {
      test('should update %s', () {
        expectSetter((s) => s.showFeaturesPanel, (s) => s.setShowFeaturesPanel(true), true);
        expectSetter((s) => s.showWorkflowVersionHistoryPanel, (s) => s.setShowWorkflowVersionHistoryPanel(true), true);
        expectSetter((s) => s.showInputsPanel, (s) => s.setShowInputsPanel(true), true);
        expectSetter((s) => s.showDebugAndPreviewPanel, (s) => s.setShowDebugAndPreviewPanel(true), true);
        const target = EdgeContextMenuTarget('e1');
        expectSetter((s) => s.contextMenuTarget, (s) => s.setContextMenuTarget(target), target);
        expectSetter((s) => s.showVariableInspectPanel, (s) => s.setShowVariableInspectPanel(true), true);
        expectSetter((s) => s.initShowLastRunTab, (s) => s.setInitShowLastRunTab(true), true);
      });
    });

    group('Help Line Slice Setters', () {
      test('should update %s', () {
        const h = (top: 100.0, left: 0.0, width: 500.0);
        expectSetter((s) => s.helpLineHorizontal, (s) => s.setHelpLineHorizontal(h), h);
        const v = (top: 0.0, left: 200.0, height: 300.0);
        expectSetter((s) => s.helpLineVertical, (s) => s.setHelpLineVertical(v), v);
      });

      test('should clear helpLineHorizontal', () {
        final store = WorkflowStore();
        store.setHelpLineHorizontal((top: 100, left: 0, width: 500));
        store.setHelpLineHorizontal(null);
        expect(store.helpLineHorizontal.value, isNull);
        store.dispose();
      });
    });

    group('History Slice Setters', () {
      test('should update %s', () {
        final run = <String, Object?>{'id': 'run-1', 'status': 'succeeded'};
        expectSetter((s) => s.historyWorkflowData, (s) => s.setHistoryWorkflowData(run), run);
        expectSetter((s) => s.showRunHistory, (s) => s.setShowRunHistory(true), true);
        expectSetter((s) => s.versionHistory, (s) => s.setVersionHistory([]), <DifyJson>[]);
      });
    });

    group('Form Slice Setters', () {
      test('should update %s', () {
        const inputs = <String, Object>{'name': 'test', 'count': 42};
        expectSetter((s) => s.inputs, (s) => s.setInputs(inputs), inputs);
        expectSetter((s) => s.files, (s) => s.setFiles([]), <DifyJson>[]);
      });
    });

    group('Tool Slice Setters', () {
      test('should update %s', () {
        expectSetter((s) => s.toolPublished, (s) => s.setToolPublished(true), true);
        expectSetter((s) => s.lastPublishedHasUserInput, (s) => s.setLastPublishedHasUserInput(true), true);
      });
    });

    group('Layout Slice Setters', () {
      test('should update %s', () {
        expectSetter((s) => s.workflowCanvasWidth, (s) => s.setWorkflowCanvasWidth(1200), 1200.0);
        expectSetter((s) => s.workflowCanvasHeight, (s) => s.setWorkflowCanvasHeight(800), 800.0);
        expectSetter((s) => s.rightPanelWidth, (s) => s.setRightPanelWidth(500), 500.0);
        expectSetter((s) => s.nodePanelWidth, (s) => s.setNodePanelWidth(350), 350.0);
        expectSetter((s) => s.previewPanelWidth, (s) => s.setPreviewPanelWidth(450), 450.0);
        expectSetter((s) => s.otherPanelWidth, (s) => s.setOtherPanelWidth(380), 380.0);
        expectSetter((s) => s.bottomPanelWidth, (s) => s.setBottomPanelWidth(600), 600.0);
        expectSetter((s) => s.bottomPanelHeight, (s) => s.setBottomPanelHeight(500), 500.0);
        expectSetter((s) => s.variableInspectPanelHeight, (s) => s.setVariableInspectPanelHeight(250), 250.0);
      });
    });

    group('Static defaults and legacy maximize initialization', () {
      Future<void> stored(Map<String, Object> values) async {
        SharedPreferences.setMockInitialValues(values);
        await SharedPreferences.getInstance();
      }

      setUp(() => SharedPreferences.setMockInitialValues({}));

      test('should keep controlMode default in the store when localStorage has a value', () async {
        await stored({'workflow-operation-mode': 'hand'});
        expect(WorkflowStore().controlMode.value, ControlMode.pointer);
      });

      test('should default controlMode to pointer when localStorage has no value', () {
        expect(WorkflowStore().controlMode.value, ControlMode.pointer);
      });

      test('should keep panelWidth default in the store when localStorage has a value', () async {
        await stored({'workflow-node-panel-width': '500'});
        expect(WorkflowStore().panelWidth.value, 420);
      });

      test('should default panelWidth to 420 when localStorage is empty', () {
        expect(WorkflowStore().panelWidth.value, 420);
      });

      test('should keep nodePanelWidth default in the store when localStorage has a value', () async {
        await stored({'workflow-node-panel-width': '350'});
        expect(WorkflowStore().nodePanelWidth.value, 400);
      });

      test('should keep previewPanelWidth default in the store when localStorage has a value', () async {
        await stored({'debug-and-preview-panel-width': '450'});
        expect(WorkflowStore().previewPanelWidth.value, 400);
      });

      test('should keep variableInspectPanelHeight default in the store when localStorage has a value', () async {
        await stored({'workflow-variable-inpsect-panel-height': '200'});
        expect(WorkflowStore().variableInspectPanelHeight.value, 320);
      });
    });

    group('useStore hook', () {
      testWidgets('should read state via selector when wrapped in WorkflowContext', (t) async {
        final store = WorkflowStore()..setShowSingleRunPanel(true);
        addTearDown(store.dispose);
        bool? read;
        await t.pumpWidget(
          WorkflowStoreScope(
            store: store,
            child: Builder(
              builder: (context) => ValueListenableBuilder(
                valueListenable: WorkflowStoreScope.of(context).showSingleRunPanel,
                builder: (context, v, _) {
                  read = v;
                  return const SizedBox();
                },
              ),
            ),
          ),
        );
        expect(read, true);
      });

      testWidgets('should throw when used without WorkflowContext.Provider', (t) async {
        await t.pumpWidget(Builder(builder: (context) => Text('${WorkflowStoreScope.of(context).showSingleRunPanel}')));
        expect(
          t.takeException(),
          isA<StateError>().having((e) => e.message, 'message', 'Missing WorkflowStoreScope in the tree'),
        );
      });
    });

    group('useWorkflowStore hook', () {
      testWidgets('should return the store instance when wrapped in WorkflowContext', (t) async {
        final store = WorkflowStore();
        addTearDown(store.dispose);
        WorkflowStore? found;
        await t.pumpWidget(
          WorkflowStoreScope(
            store: store,
            child: Builder(
              builder: (context) {
                found = WorkflowStoreScope.of(context);
                return const SizedBox();
              },
            ),
          ),
        );
        expect(found, same(store));
      });
    });

    group('Injection', () {
      test('should support injecting additional slice', () {
        final store = _AppSliceStore();
        expect(store, isA<WorkflowStore>());
        expect(store.appId.value, isNull);
        store.dispose();
      });
    });
  });
}
