// dify-spec: web/app/components/workflow/run/__tests__/node.spec.tsx
// dify-spec: web/app/components/workflow/run/__tests__/tracing-panel.spec.tsx
// dify-spec: web/app/components/workflow/run/__tests__/hooks.spec.ts
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/log_widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/run_logs.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/tracing_node.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/tracing_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart' show DifyJson;
import 'package:flutter/material.dart';

import 'dart:ui' show Tristate;

import 'package:flutter_test/flutter_test.dart';

import 'run_harness.dart';

DifyJson info([DifyJson o = const {}]) => createNodeTracing({
  'id': 'trace-node-1',
  'title': 'Code Node',
  'inputs': null,
  'process_data': null,
  'elapsed_time': 1.25,
  'execution_metadata': executionMetadata({'total_tokens': 64}),
  'finished_at': 1,
  ...o,
});

const _wide = Size(800, 2000);

void main() {
  group('Run NodePanel', () {
    testWidgets('renders the running state in the header without the finished summary', (t) async {
      await renderRun(t, RunNodePanel(nodeInfo: info({'status': 'running'})), size: _wide);
      expect(find.text('Running'), findsOneWidget);
      expect(find.textContaining('1.250 s'), findsNothing);
    });

    testWidgets('shows the stopped reason when the panel is expanded from tracing state', (t) async {
      await renderRun(t, RunNodePanel(nodeInfo: info({'expand': true, 'status': 'stopped'})), size: _wide);
      expect(find.textContaining('Alice'), findsOneWidget);
    });

    testWidgets('forwards iteration details through the real iteration trigger', (t) async {
      final calls = <(List<NodeTracingList>, DurationMap)>[];
      final details = [
        [
          info({
            'id': 'iter-trace-1',
            'node_id': 'iter-node-1',
            'execution_metadata': executionMetadata({'total_tokens': 8, 'iteration_index': 0}),
          }),
        ],
      ];
      await renderRun(
        t,
        RunNodePanel(
          nodeInfo: info({
            'expand': true,
            'node_type': 'iteration',
            'details': details,
            'iterDurationMap': {'0': 1.2},
          }),
          onShowIterationDetail: (l, d) => calls.add((l, d)),
        ),
        size: _wide,
      );
      await t.tap(find.byType(IterationLogTrigger));
      expect(calls.single.$1, details);
      expect(calls.single.$2, {'0': 1.2});
    });

    testWidgets('forwards retry details through the real retry trigger', (t) async {
      final calls = <NodeTracingList>[];
      final retryDetail = [
        info({'id': 'retry-trace-1', 'node_id': 'retry-node-1', 'retry_index': 1, 'status': 'failed'}),
      ];
      await renderRun(
        t,
        RunNodePanel(
          nodeInfo: info({'expand': true, 'retryDetail': retryDetail, 'status': 'failed'}),
          onShowRetryDetail: calls.add,
        ),
        size: _wide,
      );
      await t.tap(find.byType(RetryLogTrigger));
      expect(calls.single, retryDetail);
    });
  });

  group('TracingPanel', () {
    testWidgets('should render formatted nodes, preserve branch labels, and collapse parallel groups', (t) async {
      var parent = 0;
      await renderRun(
        t,
        GestureDetector(
          onTap: () => parent++,
          child: TracingPanel(
            list: const [
              {'id': 'raw-node'},
            ],
            hideNodeInfo: true,
            hideNodeProcessDetail: true,
            formatNodeList: (_) => [
              {
                'id': 'parallel-1',
                'parallelDetail': {
                  'isParallelStartNode': true,
                  'parallelTitle': 'Parallel Group',
                  'children': [
                    {
                      'id': 'child-1',
                      'title': 'Child Node',
                      'parallelDetail': {'branchTitle': 'Branch A'},
                    },
                  ],
                },
              },
              {
                'id': 'node-2',
                'title': 'Standalone Node',
                'parallelDetail': {'branchTitle': 'Branch B'},
              },
            ],
          ),
        ),
        size: _wide,
      );
      expect(find.text('PARALLEL GROUP'), findsOneWidget);
      expect(find.text('BRANCH A'), findsOneWidget);
      expect(find.text('BRANCH B'), findsOneWidget);
      final rows = t.widgetList<RunNodePanel>(find.byType(RunNodePanel)).toList();
      expect(rows.map((r) => r.nodeInfo['id']), ['child-1', 'node-2']);
      expect(rows.every((r) => r.hideInfo && r.hideProcessDetail), isTrue);
      // Taps inside never reach the parent.
      await t.tap(find.text('STANDALONE NODE'));
      expect(parent, 0);
      // Hovering the group highlights its toggle (the arrow) and the branch line.
      await hover(t, find.text('PARALLEL GROUP'));
      expect(find.byWidgetPredicate((w) => w is RemixIcon && w.name == 'arrow-down-s-line'), findsOneWidget);
      // The toggle collapses and expands the group.
      final toggle = find.bySemanticsLabel('Parallel Group');
      expect(t.getSemantics(toggle).flagsCollection.isExpanded, Tristate.isTrue);
      await t.tap(toggle);
      await t.pump();
      expect(t.getSemantics(toggle).flagsCollection.isExpanded, Tristate.isFalse);
      expect(find.text('CHILD NODE'), findsNothing);
      await t.tap(toggle);
      await t.pump();
      expect(t.getSemantics(toggle).flagsCollection.isExpanded, Tristate.isTrue);
      expect(find.text('CHILD NODE'), findsOneWidget);
    });

    testWidgets('should switch to the special result panel when the log state requests it', (t) async {
      final logs = RunLogs()
        ..handleShowRetryResultList([
          createNodeTracing({'id': 'retry-1'}),
        ]);
      await renderRun(
        t,
        TracingPanel(list: const [], logs: logs),
        size: _wide,
      );
      expect(find.byType(SpecialResultPanel), findsOneWidget);
      expect(find.byType(RetryResultPanel), findsOneWidget);
    });
  });

  group('useLogs', () {
    DifyJson agentLog(String id, [List<DifyJson> children = const []]) => {
      'node_execution_id': 'execution-$id',
      'node_id': 'node-$id',
      'label': id,
      'status': 'success',
      'data': <String, Object?>{},
      'metadata': <String, Object?>{},
      'message_id': id,
      'children': children,
    };

    test('should manage retry, iteration, and loop detail panels', () {
      final logs = RunLogs();
      final retry = [
        createNodeTracing({'id': 'retry-node'}),
      ];
      final iteration = [
        [
          createNodeTracing({'id': 'iteration-node'}),
        ],
      ];
      final loop = [
        [
          createNodeTracing({'id': 'loop-node'}),
        ],
      ];
      expect(logs.showSpecialResultPanel, isFalse);
      logs.handleShowRetryResultList(retry);
      expect(logs.showRetryDetail, isTrue);
      expect(logs.retryResultList, retry);
      expect(logs.showSpecialResultPanel, isTrue);
      logs
        ..setShowRetryDetailFalse()
        ..handleShowIterationResultList(iteration, const {'iteration-node': 2})
        ..handleShowLoopResultList(
          loop,
          const {'loop-node': 3},
          const {
            'loop-node': {'item': 'value'},
          },
        );
      expect(logs.showRetryDetail, isFalse);
      expect(logs.showIteratingDetail, isTrue);
      expect(logs.iterationResultList, iteration);
      expect(logs.iterationResultDurationMap, {'iteration-node': 2});
      expect(logs.showLoopingDetail, isTrue);
      expect(logs.loopResultList, loop);
      expect(logs.loopResultDurationMap, {'loop-node': 3});
      expect(logs.loopResultVariableMap, {
        'loop-node': {'item': 'value'},
      });
    });

    test('should push, trim, and clear agent/tool log navigation state', () {
      final logs = RunLogs();
      final child = agentLog('child-log');
      final root = agentLog('root-log', [child]);
      final sibling = agentLog('sibling-log');
      logs.handleShowAgentOrToolLog(root);
      expect(logs.agentOrToolLogItemStack, [root]);
      expect(logs.agentOrToolLogListMap, {
        'root-log': [child],
      });
      expect(logs.showSpecialResultPanel, isTrue);
      logs.handleShowAgentOrToolLog(sibling);
      expect(logs.agentOrToolLogItemStack, [root, sibling]);
      logs.handleShowAgentOrToolLog(root);
      expect(logs.agentOrToolLogItemStack, [root]);
      logs.handleShowAgentOrToolLog();
      expect(logs.agentOrToolLogItemStack, isEmpty);
    });
  });
}
