import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/run/mock_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_scope.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_stream.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_types.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/app_fonts.dart';

void main() {
  testWidgets('a mock run in the editor: the cards show each node\'s status in order, no document ops are sent', (
    t,
  ) async {
    await useAppFonts();
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final demo = DemoBackend(withBo: false);
    await t.pumpWidget(
      MaterialApp(
        home: EditorPage(backend: demo, docId: 'demo', clientId: 'me-abc123', journaled: false),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    final editor = t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor));
    final c = editor.controller;
    final canvasState = t.state<WorkflowCanvasState>(find.byType(WorkflowCanvas));
    final scope = WorkflowRunScope.of(t.element(find.byType(WorkflowCanvas)));
    final store = WorkflowStoreScope.of(t.element(find.byType(WorkflowCanvas)));
    expect(scope.service, isA<MockWorkflowRunService>());

    // Every card's status as it changes.
    final seen = <String, List<String>>{};
    final last = {for (final n in canvasState.graph.nodes) n.id: n.status};
    for (final n in canvasState.graph.nodes) {
      n.run.addListener(() {
        if (last[n.id] == n.status) return;
        last[n.id] = n.status;
        (seen[n.id] ??= []).add(n.status);
      });
    }
    final opsBefore = demo.server.head;
    final docBefore = c.doc.toJson().toString();

    final starts = <String>[];
    await scope.run.handleRun(
      {
        'inputs': {'query': 'What is dify-sf?'},
      },
      callback: RunCallbacks(onNodeStarted: (e) => starts.add(e.nodeId!)),
    );
    expect(runningStatusOf(store.workflowRunningData.value), WorkflowRunningStatus.running);
    for (var i = 0; i < 80; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(runningStatusOf(store.workflowRunningData.value), WorkflowRunningStatus.succeeded);
    expect(starts, ['start', 'llm', 'code', 'answer']);
    expect(tracingOf(store.workflowRunningData.value).map((e) => e['node_id']), ['start', 'llm', 'code', 'answer']);
    for (final id in ['start', 'llm', 'code', 'answer']) {
      expect(seen[id], ['running', 'succeeded'], reason: id);
      expect(canvasState.graph[id]!.status, 'succeeded');
    }
    // The variable inspect panel got the run's values (each node's last outputs).
    final inspected = {for (final n in store.nodesWithInspectVars.value) n['nodeId']: n['vars'] as List};
    expect(inspected.keys, containsAll(['start', 'llm', 'code', 'answer']));
    expect(inspected['llm']!.map((v) => (v as Map)['name']), contains('text'));
    // Run state is local view state: nothing was written to the document or sent.
    expect(demo.server.head, opsBefore);
    expect(c.status.pending, 0);
    expect(c.doc.toJson().toString(), docBefore);
    expect(c.undo.past, isEmpty);

    // Closing the run (Dify's handleCancelDebugAndPreviewPanel) clears the statuses; nodes with inspect variables
    // keep the success border and icon (getNodeStatusBorders' `hasVarValue && !runningStatus`).
    scope.run.handleCancelDebugAndPreviewPanel();
    await t.pump();
    expect(canvasState.graph['llm']!.run.value.runningStatus, isNull);
    expect(canvasState.graph['llm']!.status, 'succeeded');
    expect(demo.server.head, opsBefore);

    await t.pumpWidget(const SizedBox());
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  });
}
