// dify-spec: web/app/components/workflow/run/agent-log/__tests__/agent-log-item.spec.tsx
// dify-spec: web/app/components/workflow/run/agent-log/__tests__/agent-log-nav-more.spec.tsx
// dify-spec: web/app/components/workflow/run/agent-log/__tests__/agent-log-nav.spec.tsx
// dify-spec: web/app/components/workflow/run/agent-log/__tests__/agent-log-trigger.spec.tsx
// dify-spec: web/app/components/workflow/run/agent-log/__tests__/agent-result-panel.spec.tsx
// dify-spec: web/app/components/workflow/run/retry-log/__tests__/retry-log-trigger.spec.tsx
// dify-spec: web/app/components/workflow/run/retry-log/__tests__/retry-result-panel.spec.tsx
// dify-spec: web/app/components/workflow/run/loop-log/__tests__/loop-log-trigger.spec.tsx
// dify-spec: web/app/components/workflow/run/loop-log/__tests__/loop-result-panel.spec.tsx
// dify-spec: web/app/components/workflow/run/iteration-log/__tests__/iteration-log-trigger.spec.tsx
// dify-spec: web/app/components/workflow/run/iteration-log/__tests__/iteration-result-panel.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/code_editor/code_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/log_widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/run_logs.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/tracing_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart' show DifyJson;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'run_harness.dart';

DifyJson logItem([DifyJson o = const {}]) => {
  'message_id': 'message-1',
  'label': 'Planner',
  'children': <Object?>[],
  'status': 'succeeded',
  'node_execution_id': 'exec-1',
  'node_id': 'node-1',
  'data': <String, Object?>{},
  ...o,
};

DifyJson trace([DifyJson o = const {}]) => createNodeTracing({
  'title': 'Code',
  'outputs': <String, Object?>{},
  'error': '',
  'elapsed_time': 0.2,
  'created_at': 1710000000,
  'finished_at': 1710000001,
  ...o,
});

const _wide = Size(800, 2000);

void main() {
  group('AgentLogItem', () {
    testWidgets('expands to show action logs and data, then routes nested log clicks', (t) async {
      final shown = <DifyJson?>[];
      final child = logItem({'message_id': 'child', 'label': 'Tool Call'});
      final item = logItem({
        'data': {'thought': 'inspect data'},
        'metadata': {'elapsed_time': 1.234},
        'children': [child],
      });
      await renderRun(
        t,
        SingleChildScrollView(
          child: AgentLogItem(item: item, onShowAgentOrToolLog: ([d]) => shown.add(d)),
        ),
        size: _wide,
      );
      expect(find.text('PLANNER'), findsOneWidget);
      expect(find.text('1.234s'), findsOneWidget);
      await t.tap(find.text('PLANNER'));
      await t.pump();
      expect(find.text('1 Action Logs'), findsOneWidget);
      expect('${t.widget<DifyCodeEditor>(find.byType(DifyCodeEditor)).value}', contains('inspect data'));
      await t.tap(find.text('1 Action Logs'));
      expect(shown.single, item);
    });
  });

  group('AgentLogNavMore', () {
    testWidgets('renders nested options in the real menu and routes selection clicks', (t) async {
      final shown = <DifyJson?>[];
      final option = logItem({'message_id': 'mid', 'label': 'Intermediate Tool'});
      await renderRun(
        t,
        Align(
          alignment: Alignment.topLeft,
          child: AgentLogNavMore(options: [option], onShowAgentOrToolLog: ([d]) => shown.add(d)),
        ),
      );
      await t.tap(find.bySemanticsLabel('common.operation.more'));
      await t.pumpAndSettle();
      expect(find.text('Intermediate Tool'), findsOneWidget);
      await t.tap(find.text('Intermediate Tool'));
      await t.pumpAndSettle();
      expect(shown.single, option);
    });
  });

  group('AgentLogNav', () {
    testWidgets('navigates back, opens intermediate entries, and shows the tail label', (t) async {
      final calls = <List<DifyJson?>>[];
      final stack = [
        logItem({'message_id': 'root', 'label': 'Strategy'}),
        logItem({'message_id': 'mid', 'label': 'Tool A'}),
        logItem({'message_id': 'tail', 'label': 'Tool B'}),
      ];
      await renderRun(
        t,
        AgentLogNav(
          agentOrToolLogItemStack: stack,
          onShowAgentOrToolLog: ([d]) => calls.add([?d]),
        ),
        size: _wide,
      );
      await t.tap(find.text('AGENT'));
      await t.tap(find.text('workflow.nodes.agent.strategy.label'));
      await t.tap(find.bySemanticsLabel('common.operation.more'));
      await t.pumpAndSettle();
      await t.tap(find.text('Tool A'));
      await t.pumpAndSettle();
      expect(calls[0], isEmpty);
      expect(calls[1], [stack[0]]);
      expect(calls[2], [stack[1]]);
      expect(find.text('TOOL B'), findsOneWidget);
    });
  });

  group('AgentLogTrigger', () {
    DifyJson agentTrace([DifyJson o = const {}]) => trace({
      'node_type': 'agent',
      'title': 'Agent',
      'execution_metadata': executionMetadata({
        'tool_info': {'agent_strategy': 'Plan and execute'},
      }),
      'agentLog': [
        logItem({'label': 'Step 1'}),
      ],
      ...o,
    });

    group('User Interactions', () {
      testWidgets('should show the legacy agent strategy and pass the log payload on click', (t) async {
        final shown = <DifyJson?>[];
        final log = [logItem()];
        await renderRun(
          t,
          AgentLogTrigger(nodeInfo: agentTrace({'agentLog': log}), onShowAgentOrToolLog: ([d]) => shown.add(d)),
        );
        expect(find.text('WORKFLOW.NODES.AGENT.STRATEGY.LABEL'), findsOneWidget);
        expect(find.text('Plan and execute'), findsOneWidget);
        expect(find.text('RUN-LOG.DETAIL'), findsOneWidget);
        await t.tap(find.text('Plan and execute'));
        expect(shown.single, {'message_id': 'trace-1', 'children': log});
      });

      testWidgets('should open the detail view when execution metadata is unavailable', (t) async {
        var count = 0;
        await renderRun(
          t,
          AgentLogTrigger(
            nodeInfo: agentTrace({'execution_metadata': executionMetadata()}),
            onShowAgentOrToolLog: ([d]) => count++,
          ),
        );
        await t.tap(find.text('RUN-LOG.DETAIL'));
        expect(count, 1);
      });
    });
  });

  group('AgentResultPanel', () {
    testWidgets('renders the real child items, shows the circular warning, and opens nested action logs', (t) async {
      final shown = <DifyJson?>[];
      final grandchild = logItem({'message_id': 'grandchild', 'label': 'Tool Call'});
      final child = logItem({
        'message_id': 'child',
        'label': 'Child Tool',
        'children': [grandchild],
      });
      final top = logItem({'message_id': 'top', 'label': 'Top', 'hasCircle': true});
      await renderRun(
        t,
        SingleChildScrollView(
          child: AgentResultPanel(
            agentOrToolLogItemStack: [top],
            agentOrToolLogListMap: {
              'top': [child],
            },
            onShowAgentOrToolLog: ([d]) => shown.add(d),
          ),
        ),
        size: _wide,
      );
      expect(find.text('run-log.circularInvocationTip'), findsOneWidget);
      await t.tap(find.text('CHILD TOOL'));
      await t.pump();
      await t.tap(find.text('1 Action Logs'));
      expect(shown.single, child);
    });
  });

  group('RetryLogTrigger', () {
    group('User Interactions', () {
      testWidgets('should forward retry details and stop parent clicks', (t) async {
        final shown = <NodeTracingList>[];
        var parent = 0;
        final retryDetail = [
          trace({'id': 'retry-1'}),
          trace({'id': 'retry-2'}),
        ];
        await renderRun(
          t,
          GestureDetector(
            onTap: () => parent++,
            child: RetryLogTrigger(nodeInfo: trace({'retryDetail': retryDetail}), onShowRetryResultList: shown.add),
          ),
          size: _wide,
        );
        await t.tap(find.text('workflow.nodes.common.retry.retries:{"num":2}'));
        expect(shown.single, retryDetail);
        expect(parent, 0);
      });

      testWidgets('should fall back to an empty retry list when details are missing', (t) async {
        final shown = <NodeTracingList>[];
        await renderRun(
          t,
          RetryLogTrigger(nodeInfo: trace(), onShowRetryResultList: shown.add),
          size: _wide,
        );
        await t.tap(find.byType(RetryLogTrigger));
        expect(shown.single, isEmpty);
      });
    });
  });

  group('RetryResultPanel', () {
    testWidgets('should render every retry attempt with its details', (t) async {
      final attempts = [
        trace({
          'id': 'retry-1',
          'status': 'retry',
          'inputs': {'attempt': 1},
          'process_data': {'request': 'attempt-1'},
          'outputs': {'status_code': 500},
          'error': 'first failure',
          'expand': true,
        }),
        trace({
          'id': 'retry-2',
          'status': 'retry',
          'inputs': {'attempt': 2},
          'process_data': {'request': 'attempt-2'},
          'outputs': {'status_code': 503},
          'error': 'second failure',
          'expand': true,
        }),
      ];
      await renderRun(
        t,
        SingleChildScrollView(
          child: RetryResultPanel(list: attempts, onBack: () {}),
        ),
        size: const Size(800, 4000),
      );
      expect(find.text('WORKFLOW.NODES.COMMON.RETRY.RETRY 1'), findsOneWidget);
      expect(find.text('WORKFLOW.NODES.COMMON.RETRY.RETRY 2'), findsOneWidget);
      expect(find.text('first failure'), findsOneWidget);
      expect(find.text('second failure'), findsOneWidget);
      final values = [for (final e in t.widgetList<DifyCodeEditor>(find.byType(DifyCodeEditor))) '${e.value}'].join();
      for (final s in ['attempt-1', 'attempt-2', '500', '503']) {
        expect(values, contains(s));
      }
    });

    testWidgets('should trigger the back action when back is clicked', (t) async {
      var back = 0;
      await renderRun(t, RetryResultPanel(list: const [], onBack: () => back++));
      await t.tap(find.text('workflow.singleRun.back'));
      expect(back, 1);
    });
  });

  group('LoopLogTrigger', () {
    DifyJson loopTrace([DifyJson o = const {}]) => trace({
      'node_id': 'loop-node',
      'node_type': 'loop',
      'title': 'Loop',
      'execution_metadata': executionMetadata(),
      ...o,
    });

    group('Structured Detail Handling', () {
      testWidgets('should pass existing loop details, durations, and variables to the callback', (t) async {
        final calls = <(List<NodeTracingList>, DurationMap, Map<String, Object?>)>[];
        final details = [
          [
            loopTrace({'id': 'loop-1-step-1', 'status': 'succeeded'}),
          ],
          [
            loopTrace({'id': 'loop-2-step-1', 'status': 'failed'}),
          ],
        ];
        const durations = {'0': 1.2, '1': 2.5};
        const variables = {
          '1': {'item': 'alpha'},
        };
        await renderRun(
          t,
          LoopLogTrigger(
            nodeInfo: loopTrace({
              'details': details,
              'loopDurationMap': durations,
              'execution_metadata': executionMetadata({'loop_duration_map': durations, 'loop_variable_map': variables}),
            }),
            onShowLoopResultList: (l, d, v) => calls.add((l, d, v)),
          ),
          size: _wide,
        );
        final label = t.widget<Text>(find.textContaining('workflow.nodes.loop.loop')).data!;
        expect(label, contains('workflow.nodes.loop.error'));
        await t.tap(find.byType(LoopLogTrigger));
        expect(calls.single.$1, details);
        expect(calls.single.$2, durations);
        expect(calls.single.$3, variables);
      });

      testWidgets('should reconstruct loop detail groups from execution metadata when details are absent', (t) async {
        final calls = <(List<NodeTracingList>, DurationMap, Map<String, Object?>)>[];
        const durations = {'parallel-1': 1.5, '2': 2.2};
        final all = [
          loopTrace({
            'id': 'parallel-child',
            'execution_metadata': executionMetadata({'parallel_mode_run_id': 'parallel-1'}),
          }),
          loopTrace({
            'id': 'serial-child',
            'execution_metadata': executionMetadata({'loop_id': 'loop-node', 'loop_index': 2}),
          }),
        ];
        await renderRun(
          t,
          LoopLogTrigger(
            nodeInfo: loopTrace({
              'execution_metadata': executionMetadata({'loop_duration_map': durations, 'loop_variable_map': const {}}),
            }),
            allExecutions: all,
            onShowLoopResultList: (l, d, v) => calls.add((l, d, v)),
          ),
          size: _wide,
        );
        await t.tap(find.byType(LoopLogTrigger));
        expect(calls, hasLength(1));
        expect(calls.single.$1, hasLength(2));
        expect(
          calls.single.$1,
          containsAll([
            [all[0]],
            [all[1]],
          ]),
        );
        expect(calls.single.$2, durations);
        expect(calls.single.$3, isEmpty);
      });
    });
  });

  group('LoopResultPanel', () {
    DifyJson step(String id, [DifyJson o = const {}]) => trace({
      'id': id,
      'node_id': 'node-$id',
      'title': 'Loop Step $id',
      'execution_metadata': executionMetadata({'loop_index': 0}),
      ...o,
    });

    testWidgets(
      'shows loop duration in the header, expands loop variables, renders tracing details, and calls onBack',
      (t) async {
        var back = 0;
        await renderRun(
          t,
          SingleChildScrollView(
            child: ContainerResultPanel(
              loop: true,
              list: [
                [step('1')],
              ],
              onBack: () => back++,
              durationMap: const {'0': 1.2},
              variableMap: const {
                '0': {'item': 'alpha'},
              },
            ),
          ),
          size: _wide,
        );
        expect(find.text('1.20s'), findsOneWidget);
        expect(t.widget<AnimatedRotation>(find.byType(AnimatedRotation).last).turns, 0);
        await t.tap(find.text('WORKFLOW.SINGLERUN.LOOP 1'));
        await t.pumpAndSettle();
        expect(t.widget<AnimatedRotation>(find.byType(AnimatedRotation).first).turns, 0.25);
        expect(t.widget<DifyCodeEditor>(find.byType(DifyCodeEditor)).value, {'item': 'alpha'});
        expect(t.widget<TracingPanel>(find.byType(TracingPanel)).list.single['title'], 'Loop Step 1');
        await t.tap(find.text('workflow.singleRun.back'));
        expect(back, 1);
      },
    );

    group('Loop Variable Resolution', () {
      testWidgets('should read loop variables by the actual loop index when rows are compacted', (t) async {
        await renderRun(
          t,
          SingleChildScrollView(
            child: ContainerResultPanel(
              loop: true,
              list: [
                [
                  step('loop-2-step-1', {
                    'execution_metadata': executionMetadata({'loop_index': 2}),
                  }),
                ],
              ],
              onBack: () {},
              variableMap: const {
                '2': {'item': 'alpha'},
              },
            ),
          ),
          size: _wide,
        );
        await t.tap(find.text('WORKFLOW.SINGLERUN.LOOP 1'));
        await t.pump();
        expect(t.widget<DifyCodeEditor>(find.byType(DifyCodeEditor)).value, {'item': 'alpha'});
      });

      testWidgets('should read loop variables by parallel run id when available', (t) async {
        await renderRun(
          t,
          SingleChildScrollView(
            child: ContainerResultPanel(
              loop: true,
              list: [
                [
                  step('parallel-step-1', {
                    'execution_metadata': executionMetadata({'loop_index': 0, 'parallel_mode_run_id': 'parallel-1'}),
                  }),
                ],
              ],
              onBack: () {},
              variableMap: const {
                'parallel-1': {'item': 'beta'},
              },
            ),
          ),
          size: _wide,
        );
        await t.tap(find.text('WORKFLOW.SINGLERUN.LOOP 1'));
        await t.pump();
        expect(t.widget<DifyCodeEditor>(find.byType(DifyCodeEditor)).value, {'item': 'beta'});
      });
    });
  });

  group('IterationLogTrigger', () {
    DifyJson iterTrace([DifyJson o = const {}]) =>
        trace({'node_id': 'iteration-node', 'node_type': 'iteration', 'title': 'Iteration', ...o});

    group('Structured Detail Handling', () {
      testWidgets(
        'should reconstruct structured iteration groups from execution metadata and include failed missing details',
        (t) async {
          final calls = <(List<NodeTracingList>, DurationMap)>[];
          const durations = {'parallel-1': 1.1, '1': 2.2};
          final missingFailed = [
            iterTrace({
              'id': 'failed-step',
              'status': 'failed',
              'execution_metadata': executionMetadata({'iteration_index': 2}),
            }),
          ];
          final all = [
            iterTrace({
              'id': 'parallel-step',
              'execution_metadata': executionMetadata({'parallel_mode_run_id': 'parallel-1'}),
            }),
            iterTrace({
              'id': 'serial-step',
              'execution_metadata': executionMetadata({'iteration_id': 'iteration-node', 'iteration_index': 1}),
            }),
          ];
          await renderRun(
            t,
            IterationLogTrigger(
              nodeInfo: iterTrace({
                'details': [missingFailed],
                'execution_metadata': executionMetadata({'iteration_duration_map': durations}),
              }),
              allExecutions: all,
              onShowIterationResultList: (l, d) => calls.add((l, d)),
            ),
            size: _wide,
          );
          await t.tap(find.byType(IterationLogTrigger));
          expect(calls.single.$1, [
            [all[0]],
            [all[1]],
            missingFailed,
          ]);
          expect(calls.single.$2, durations);
        },
      );

      testWidgets('should fall back to details and metadata length when duration map is unavailable', (t) async {
        final calls = <(List<NodeTracingList>, DurationMap)>[];
        final details = [
          [
            iterTrace({'id': 'detail-1'}),
          ],
        ];
        await renderRun(
          t,
          IterationLogTrigger(
            nodeInfo: iterTrace({
              'details': details,
              'metadata': {'iterator_length': 3, 'iterator_index': 0, 'loop_length': 0, 'loop_index': 0},
            }),
            onShowIterationResultList: (l, d) => calls.add((l, d)),
          ),
          size: _wide,
        );
        expect(find.textContaining('workflow.nodes.iteration.iteration'), findsOneWidget);
        await t.tap(find.byType(IterationLogTrigger));
        expect(calls.single.$1, details);
        expect(calls.single.$2, isEmpty);
      });

      testWidgets('should return an empty structured list when duration map exists without executions', (t) async {
        final calls = <(List<NodeTracingList>, DurationMap)>[];
        const durations = {'orphaned': 1.5};
        await renderRun(
          t,
          IterationLogTrigger(
            nodeInfo: iterTrace({
              'execution_metadata': executionMetadata({'iteration_duration_map': durations}),
            }),
            onShowIterationResultList: (l, d) => calls.add((l, d)),
          ),
          size: _wide,
        );
        await t.tap(find.byType(IterationLogTrigger));
        expect(calls.single.$1, isEmpty);
        expect(calls.single.$2, durations);
      });

      testWidgets('should count failed iterations from allExecutions and ignore unmatched duration map keys', (
        t,
      ) async {
        final calls = <(List<NodeTracingList>, DurationMap)>[];
        const durations = {'orphaned': 0.6, '1': 1.1};
        final all = [
          iterTrace({
            'id': 'failed-serial-step',
            'status': 'failed',
            'execution_metadata': executionMetadata({'iteration_id': 'iteration-node', 'iteration_index': 1}),
          }),
        ];
        await renderRun(
          t,
          IterationLogTrigger(
            nodeInfo: iterTrace({
              'details': [
                [
                  iterTrace({'id': 'detail-success'}),
                ],
              ],
              'execution_metadata': executionMetadata({'iteration_duration_map': durations}),
            }),
            allExecutions: all,
            onShowIterationResultList: (l, d) => calls.add((l, d)),
          ),
          size: _wide,
        );
        expect(find.textContaining('workflow.nodes.iteration.error'), findsOneWidget);
        await t.tap(find.byType(IterationLogTrigger));
        expect(calls.single.$1, [
          [all[0]],
        ]);
        expect(calls.single.$2, durations);
      });
    });
  });

  group('IterationResultPanel', () {
    testWidgets('shows iteration duration, toggles tracing details, and calls onBack', (t) async {
      var back = 0;
      await renderRun(
        t,
        SingleChildScrollView(
          child: ContainerResultPanel(
            loop: false,
            list: [
              [
                trace({
                  'id': '1',
                  'node_id': 'node-1',
                  'title': 'Iteration Step 1',
                  'execution_metadata': executionMetadata({'iteration_index': 0, 'parallel_mode_run_id': 'iter-1'}),
                }),
              ],
            ],
            onBack: () => back++,
            durationMap: const {'iter-1': 1.2},
          ),
        ),
        size: _wide,
      );
      expect(find.text('1.20s'), findsOneWidget);
      expect(find.byType(TracingPanel), findsNothing);
      await t.tap(find.text('WORKFLOW.SINGLERUN.ITERATION 1'));
      await t.pumpAndSettle();
      expect(t.widget<AnimatedRotation>(find.byType(AnimatedRotation).first).turns, 0.25);
      expect(find.byType(TracingPanel), findsOneWidget);
      await t.tap(find.text('workflow.singleRun.back'));
      expect(back, 1);
    });
  });
}
