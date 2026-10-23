// dify-spec: web/app/components/workflow/run/__tests__/result-panel.spec.tsx
// dify-spec: web/app/components/workflow/run/__tests__/result-text.spec.tsx
// dify-spec: web/app/components/workflow/run/__tests__/output-panel.spec.tsx
// dify-spec: web/app/components/workflow/run/__tests__/special-result-panel.spec.tsx
// dify-spec: web/app/components/workflow/run/__tests__/index.spec.tsx
import 'dart:convert';

import 'package:dify_sf_app/src/design/widgets/toast.dart';
import 'package:dify_sf_app/src/design/widgets/loading.dart' show DifyLoadingAnim;
import 'package:dify_sf_app/src/workflow_editor/code_editor/code_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/node_config.dart' show ErrorHandleTip, ErrorHandleType;
import 'package:dify_sf_app/src/workflow_editor/run/ui/log_widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/markdown.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/result_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/run_logs.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/run_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/run_widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/status.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart' show DifyJson;
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/value_content.dart' show LargeDataAlert;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'run_harness.dart';

DifyJson nodeInfo([DifyJson o = const {}]) => createNodeTracing({
  'id': 'trace-node-1',
  'title': 'Code',
  'created_by': {'id': 'user-1', 'name': 'User', 'email': 'user@example.com'},
  'finished_at': 1,
  ...o,
});

DifyJson logDetail(String id) => nodeInfo({'id': 'trace-$id', 'node_id': id, 'title': id});

DifyJson agentLog(String label) => {
  'node_execution_id': 'execution-$label',
  'message_id': 'message-$label',
  'node_id': 'node-$label',
  'label': label,
  'status': 'success',
  'data': <String, Object?>{},
  'metadata': <String, Object?>{},
  'children': <Object?>[],
};

List<String> editorValues(WidgetTester t) => [
  for (final e in t.widgetList<DifyCodeEditor>(find.byType(DifyCodeEditor))) '${e.value}',
];

String markdownText(WidgetTester t) =>
    t.widgetList<DifyMarkdown>(find.byType(DifyMarkdown)).map((m) => m.content).join();

void main() {
  group('ResultPanel', () {
    testWidgets('should render status, editors, alerts, error strategy tip, and metadata', (t) async {
      await renderRun(
        t,
        SingleChildScrollView(
          child: ResultPanel(
            nodeInfo: nodeInfo(),
            inputs: '{"topic":"AI"}',
            inputsTruncated: true,
            processData: '{"step":1}',
            processDataTruncated: true,
            outputs: const {'answer': 'done'},
            outputsTruncated: true,
            outputsFullContent: const {'download_url': 'https://example.com/output.json'},
            status: 'succeeded',
            error: 'boom',
            elapsedTime: 2.5,
            totalTokens: 42,
            createdAt: 1710000000,
            createdBy: 'Alice',
            steps: 3,
            exceptionCounts: 1,
            // Dify's spec passes an unknown strategy to a mocked tip; the tip shows for real strategies.
            executionMetadata: const {'error_strategy': 'default-value'},
            isListening: true,
            workflowRunId: 'run-1',
          ),
        ),
        size: const Size(800, 2400),
      );
      expect(find.byType(StatusPanel), findsOneWidget);
      expect(find.text('WORKFLOW.COMMON.INPUT'), findsOneWidget);
      expect(find.text('WORKFLOW.COMMON.PROCESSDATA'), findsOneWidget);
      expect(find.text('WORKFLOW.COMMON.OUTPUT'), findsOneWidget);
      expect(find.byType(DifyCodeEditor), findsNWidgets(3));
      expect(find.byType(LargeDataAlert), findsNWidgets(3));
      expect(t.widget<ErrorHandleTip>(find.byType(ErrorHandleTip)).type, ErrorHandleType.defaultValue);
      expect(find.byType(RunMetaData), findsOneWidget);
      final status = t.widget<StatusPanel>(find.byType(StatusPanel));
      expect(
        (status.status, status.time, status.tokens, status.error, status.exceptionCounts, status.isListening),
        ('succeeded', 2.5, 42, 'boom', 1, true),
      );
      expect(status.workflowRunId, 'run-1');
      final meta = t.widget<RunMetaData>(find.byType(RunMetaData));
      expect(
        (meta.status, meta.executor, meta.startTime, meta.time, meta.tokens, meta.steps, meta.showSteps),
        ('succeeded', 'Alice', 1710000000, 2.5, 42, 3, true),
      );
      expect(
        t.widgetList<LargeDataAlert>(find.byType(LargeDataAlert)).last.downloadUrl,
        'https://example.com/output.json',
      );
    });

    testWidgets('should render and invoke iteration and loop triggers only when their handlers are provided', (
      t,
    ) async {
      final iterationCalls = <(List<NodeTracingList>, DurationMap)>[];
      final loopCalls = <(List<NodeTracingList>, DurationMap)>[];
      final details = [
        [logDetail('iter-1')],
      ];
      Widget panel(DifyJson info) => SingleChildScrollView(
        child: ResultPanel(
          nodeInfo: info,
          status: 'running',
          handleShowIterationResultList: (l, d) => iterationCalls.add((l, d)),
          handleShowLoopResultList: (l, d, v) => loopCalls.add((l, d)),
        ),
      );
      await renderRun(
        t,
        panel(
          nodeInfo({
            'node_type': 'iteration',
            'details': details,
            'iterDurationMap': {'0': 3},
          }),
        ),
        size: const Size(800, 2000),
      );
      await t.tap(find.byType(IterationLogTrigger));
      expect(iterationCalls.single.$1, details);
      expect(iterationCalls.single.$2, {'0': 3});
      await renderRun(
        t,
        panel(
          nodeInfo({
            'node_type': 'loop',
            'details': details,
            'loopDurationMap': {'0': 5},
          }),
        ),
        size: const Size(800, 2000),
      );
      await t.tap(find.byType(LoopLogTrigger));
      expect(loopCalls.single.$1, details);
      expect(loopCalls.single.$2, {'0': 5});
    });

    testWidgets('should render retry and agent/tool triggers when the node shape supports them', (t) async {
      final retries = <NodeTracingList>[];
      final agentCalls = <DifyJson?>[];
      final retryDetail = [logDetail('retry-1')];
      final log = [agentLog('tool-call')];
      Widget panel(DifyJson info) => SingleChildScrollView(
        child: ResultPanel(
          nodeInfo: info,
          status: 'succeeded',
          onShowRetryDetail: retries.add,
          handleShowAgentOrToolLog: ([d]) => agentCalls.add(d),
        ),
      );
      await renderRun(
        t,
        panel(nodeInfo({'node_type': 'code', 'retryDetail': retryDetail})),
        size: const Size(800, 2000),
      );
      await t.tap(find.byType(RetryLogTrigger));
      expect(retries.single, retryDetail);
      await renderRun(t, panel(nodeInfo({'node_type': 'agent', 'agentLog': log})), size: const Size(800, 2000));
      await t.tap(find.byType(AgentLogTrigger));
      expect(agentCalls.last, {'message_id': 'trace-node-1', 'children': log});
      await renderRun(t, panel(nodeInfo({'node_type': 'agent-v2', 'agentLog': log})), size: const Size(800, 2000));
      expect(find.byType(AgentLogTrigger), findsNothing);
      await renderRun(t, panel(nodeInfo({'node_type': 'tool', 'agentLog': log})), size: const Size(800, 2000));
      await t.tap(find.byType(AgentLogTrigger));
      expect(agentCalls, hasLength(2));
      expect(agentCalls.last?['children'], log);
    });

    testWidgets('should still render the output editor while the node is running even without outputs', (t) async {
      await renderRun(
        t,
        SingleChildScrollView(
          child: ResultPanel(nodeInfo: nodeInfo(), inputs: '{}', status: 'running'),
        ),
        size: const Size(800, 2000),
      );
      expect(find.text('WORKFLOW.COMMON.OUTPUT'), findsOneWidget);
    });
  });

  group('ResultText', () {
    testWidgets('renders the loading animation while waiting for a text result', (t) async {
      await renderRun(t, const ResultText(isRunning: true));
      expect(find.byType(DifyLoadingAnim), findsOneWidget);
    });

    testWidgets('renders the error state when the run fails', (t) async {
      await renderRun(t, const ResultText(error: 'Run failed'));
      expect(t.widget<StatusContainer>(find.byType(StatusContainer)).status, 'failed');
      expect(find.text('Run failed'), findsOneWidget);
    });

    testWidgets('renders the empty-state call to action and forwards clicks', (t) async {
      var clicks = 0;
      await renderRun(t, ResultText(onClick: () => clicks++));
      expect(find.text('run-log.resultEmpty.title'), findsOneWidget);
      await t.tap(find.text('run-log.resultEmpty.link'));
      expect(clicks, 1);
    });

    testWidgets('does not render the empty state for paused runs', (t) async {
      await renderRun(t, const ResultText(isPaused: true));
      expect(find.text('run-log.resultEmpty.title'), findsNothing);
    });

    testWidgets('renders markdown content when text outputs are available', (t) async {
      await renderRun(t, const ResultText(outputs: 'hello workflow'));
      expect(markdownText(t), 'hello workflow');
    });

    testWidgets('renders file groups when file outputs are available', (t) async {
      await renderRun(
        t,
        const ResultText(
          allFiles: [
            {
              'varName': 'attachments',
              'list': [
                {
                  'id': 'file-1',
                  'name': 'report.pdf',
                  'size': 128,
                  'type': 'application/pdf',
                  'progress': 100,
                  'transferMethod': 'local_file',
                  'supportFileType': 'document',
                },
              ],
            },
          ],
        ),
      );
      expect(find.text('attachments'), findsOneWidget);
      expect(textContent(t, find.byType(RunFileList)), contains('report.pdf'));
    });
  });

  group('OutputPanel', () {
    DifyJson fileOutput([DifyJson o = const {}]) => {
      'dify_model_identity': '__dify__file__',
      'related_id': 'file-1',
      'extension': 'pdf',
      'filename': 'report.pdf',
      'size': 128,
      'mime_type': 'application/pdf',
      'transfer_method': 'local_file',
      'type': 'document',
      'url': 'https://example.com/report.pdf',
      'upload_file_id': 'upload-1',
      'remote_url': '',
      ...o,
    };

    testWidgets('renders the loading animation while the workflow is running', (t) async {
      await renderRun(t, const OutputPanel(isRunning: true));
      expect(find.byType(DifyLoadingAnim), findsOneWidget);
    });

    testWidgets('renders the failed status container when there is an error', (t) async {
      await renderRun(t, const OutputPanel(error: 'Execution failed'));
      final c = t.widget<StatusContainer>(find.byType(StatusContainer));
      expect((c.status, c.copyContent), ('failed', 'Execution failed'));
      expect(find.text('Execution failed'), findsOneWidget);
    });

    testWidgets('renders the no-output placeholder when there are no outputs', (t) async {
      await renderRun(t, const OutputPanel());
      expect(markdownText(t), 'No Output');
    });

    testWidgets('renders a plain text output as markdown', (t) async {
      await renderRun(t, const OutputPanel(outputs: {'answer': 'Hello Dify'}));
      expect(markdownText(t), 'Hello Dify');
    });

    testWidgets('renders array text outputs as joined markdown content', (t) async {
      await renderRun(
        t,
        const OutputPanel(
          outputs: {
            'answer': ['Line 1', 'Line 2'],
          },
        ),
      );
      expect(markdownText(t), 'Line 1\nLine 2');
    });

    testWidgets('renders a file list for a single file output', (t) async {
      await renderRun(t, OutputPanel(outputs: {'attachment': fileOutput()}));
      expect(textContent(t, find.byType(RunFileList)), contains('report.pdf'));
    });

    testWidgets('renders a file list for an array of file outputs', (t) async {
      await renderRun(
        t,
        OutputPanel(
          outputs: {
            'attachments': [
              fileOutput(),
              fileOutput({
                'related_id': 'file-2',
                'filename': 'summary.md',
                'extension': 'md',
                'mime_type': 'text/markdown',
                'type': 'custom',
                'upload_file_id': 'upload-2',
                'url': 'https://example.com/summary.md',
              }),
            ],
          },
        ),
      );
      final text = textContent(t, find.byType(RunFileList));
      expect(text, allOf(contains('report.pdf'), contains('summary.md')));
    });

    testWidgets('renders structured outputs inside the code editor when height is available', (t) async {
      await renderRun(t, const OutputPanel(height: 200, outputs: {'answer': 'hello', 'score': 1}));
      final editor = t.widget<DifyCodeEditor>(find.byType(DifyCodeEditor));
      expect(editor.language, CodeLanguage.json);
      expect(editor.height, 92);
      // Check the text actually rendered and copied, not just the parent's editor input.
      final text = t.widget<CodeEditorBase>(find.byType(CodeEditorBase)).value;
      expect(jsonDecode(text), {'answer': 'hello', 'score': 1});
      expect(text, '{\n  "answer": "hello",\n  "score": 1\n}');
    });

    testWidgets('renders stored JSON outputs once and preserves strings inside the object', (t) async {
      final outputs = {'answer': 'hello\nworld', 'http': '{"body":"hello"}'};
      await renderRun(t, OutputPanel(height: 200, outputs: jsonEncode(outputs)));
      final text = t.widget<CodeEditorBase>(find.byType(CodeEditorBase)).value;
      expect(jsonDecode(text), outputs);
      expect((jsonDecode(text) as Map)['http'], isA<String>());
    });

    testWidgets('keeps the non-interactive output title out of the tab order', (t) async {
      await renderRun(t, const OutputPanel(height: 200, outputs: {'answer': 'hello', 'score': 1}));
      expect(find.ancestor(of: find.text('Output'), matching: find.byType(ExcludeFocus)), findsOneWidget);
    });

    testWidgets('skips the code editor when structured outputs have no positive height', (t) async {
      await renderRun(t, const OutputPanel(height: 0, outputs: {'answer': 'hello', 'score': 1}));
      expect(find.byType(DifyCodeEditor), findsNothing);
    });
  });

  group('SpecialResultPanel', () {
    DifyJson agentItem() => {
      'node_execution_id': 'exec-1',
      'message_id': 'message-1',
      'node_id': 'node-1',
      'label': 'Step 1',
      'data': <String, Object?>{},
      'status': 'succeeded',
      'children': <Object?>[],
    };

    group('Event Isolation', () {
      testWidgets('should stop click propagation at the wrapper level', (t) async {
        // The tracing panel's opaque tap catcher wraps the special panel (Flutter taps go to one target).
        var parent = 0;
        final logs = RunLogs();
        await renderRun(
          t,
          GestureDetector(
            onTap: () => parent++,
            child: Column(children: [SpecialResultPanel(logs: logs)]),
          ),
        );
        expect(parent, 0);
      });
    });

    group('Conditional Panels', () {
      testWidgets('should render retry, iteration, loop, and agent panels when their data is provided', (t) async {
        final logs = RunLogs()
          ..handleShowRetryResultList([createNodeTracing()])
          ..handleShowIterationResultList([
            [
              createNodeTracing({'id': 'iter-1'}),
            ],
          ], const {})
          ..handleShowLoopResultList(
            [
              [
                createNodeTracing({'id': 'loop-1'}),
              ],
            ],
            const {},
            const {},
          )
          ..handleShowAgentOrToolLog({
            ...agentItem(),
            'children': [agentItem()],
          });
        await renderRun(
          t,
          SingleChildScrollView(child: SpecialResultPanel(logs: logs)),
          size: const Size(420, 3000),
        );
        expect(find.byType(RetryResultPanel), findsOneWidget);
        expect(find.byWidgetPredicate((w) => w is ContainerResultPanel && !w.loop), findsOneWidget);
        expect(find.byWidgetPredicate((w) => w is ContainerResultPanel && w.loop), findsOneWidget);
        expect(find.byType(AgentResultPanel), findsOneWidget);
      });

      testWidgets('should keep panels hidden when required guards are missing', (t) async {
        final logs = RunLogs()
          ..showRetryDetail = true
          ..showIteratingDetail = true
          ..showLoopingDetail = true;
        await renderRun(t, SpecialResultPanel(logs: logs));
        expect(find.byType(RetryResultPanel), findsNothing);
        expect(find.byType(ContainerResultPanel), findsNothing);
        expect(find.byType(AgentResultPanel), findsNothing);
      });
    });
  });

  group('RunPanel', () {
    DifyJson runDetail([DifyJson o = const {}]) => {
      'id': 'run-1',
      'version': '1',
      'graph': {'nodes': <Object?>[], 'edges': <Object?>[]},
      'inputs': '{"topic":"workflow"}',
      'inputs_truncated': false,
      'status': 'succeeded',
      'outputs': 'workflow output',
      'outputs_truncated': false,
      'elapsed_time': 1.25,
      'total_tokens': 24,
      'total_steps': 2,
      'created_by_role': 'account',
      'created_by_account': {'id': 'account-1', 'name': 'Alice', 'email': 'alice@example.com'},
      'created_at': 1710000000,
      'finished_at': 1710000001,
      ...o,
    };
    DifyJson tracingNode() => createNodeTracing({
      'title': 'Trace Node',
      'elapsed_time': 0.5,
      'execution_metadata': executionMetadata({'total_tokens': 12}),
    });

    testWidgets('loads run detail and tracing data on mount, then renders the result tab', (t) async {
      final detailCalls = <String>[], tracingCalls = <String>[], results = <DifyJson>[];
      final detail = runDetail();
      await renderRun(
        t,
        RunPanel(
          runId: 'run-1',
          getResultCallback: results.add,
          fetchRunDetail: (id) async {
            detailCalls.add(id);
            return detail;
          },
          fetchTracingList: (id) async {
            tracingCalls.add(id);
            return [tracingNode()];
          },
        ),
      );
      await t.pump();
      expect(detailCalls, ['run-1']);
      expect(tracingCalls, ['run-1']);
      expect(results, [detail]);
      expect(editorValues(t).single, contains('workflow output'));
    });

    testWidgets('switches between detail, tracing, and result tabs with real child panels', (t) async {
      var detailCalls = 0;
      await renderRun(
        t,
        RunPanel(
          runId: 'run-2',
          fetchRunDetail: (id) async {
            detailCalls++;
            return runDetail();
          },
          fetchTracingList: (id) async => [tracingNode()],
        ),
        initialStoreState: (s) => s.isListening.value = true,
        size: const Size(800, 900),
      );
      await t.pump();
      // Listening opens DETAIL.
      expect(find.text('SUCCESS'), findsWidgets);
      await t.tap(find.text('RUN-LOG.TRACING'));
      await t.pump();
      expect(find.text('TRACE NODE'), findsOneWidget);
      await t.tap(find.text('RUN-LOG.RESULT'));
      await t.pump();
      expect(detailCalls, 2);
      expect(editorValues(t).single, contains('workflow output'));
    });

    testWidgets('reports run-detail and tracing failures through toast.error', (t) async {
      final toasts = <String>[];
      await renderRun(
        t,
        RunPanel(
          runId: 'run-3',
          toast: (type, m) {
            if (type == DifyToastType.error) toasts.add(m);
          },
          fetchRunDetail: (id) async => throw Exception('detail boom'),
          fetchTracingList: (id) async => throw Exception('tracing boom'),
        ),
      );
      await t.pump();
      expect(toasts, ['Exception: detail boom', 'Exception: tracing boom']);
    });
  });
}
