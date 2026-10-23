// dify-spec: web/app/components/workflow/run/utils/format-log/__tests__/index.spec.ts
// dify-spec: web/app/components/workflow/run/utils/format-log/agent/__tests__/index.spec.ts
// dify-spec: web/app/components/workflow/run/utils/format-log/human-input/__tests__/index.spec.ts
// dify-spec: web/app/components/workflow/run/utils/format-log/iteration/__tests__/index.spec.ts
// dify-spec: web/app/components/workflow/run/utils/format-log/loop/__tests__/index.spec.ts
// dify-spec: web/app/components/workflow/run/utils/format-log/parallel/__tests__/index.spec.ts
// dify-spec: web/app/components/workflow/run/utils/format-log/retry/__tests__/index.spec.ts
import 'package:dify_sf_app/src/workflow_editor/run/ui/format_log.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart' show DifyJson;
import 'package:flutter_test/flutter_test.dart';

DifyJson createTrace({
  String? id,
  int index = 0,
  String nodeId = 'node-1',
  String nodeType = 'tool',
  String title = 'Node',
  String status = 'succeeded',
  String? error,
  DifyJson? executionMetadata,
  Map<String, Object?> extra = const {},
}) => {
  'id': id ?? nodeId,
  'index': index,
  'predecessor_node_id': '',
  'node_id': nodeId,
  'node_type': nodeType,
  'title': title,
  'inputs': <String, Object?>{},
  'status': status,
  'error': ?error,
  'elapsed_time': 1,
  'execution_metadata': executionMetadata ?? {'total_tokens': 0, 'total_price': 0, 'currency': 'USD'},
  'created_at': 0,
  'finished_at': 1,
  ...extra,
};

DifyJson meta(Map<String, Object?> overrides) => {'total_tokens': 0, 'total_price': 0, 'currency': 'USD', ...overrides};

/// `expect.objectContaining`.
Matcher containing(Map<String, Object?> fields) => predicate<Object?>(
  (v) => v is Map && fields.entries.every((e) => _deepEq(v[e.key], e.value)),
  'contains $fields',
);

bool _deepEq(Object? a, Object? b) {
  if (b is Matcher) return b.matches(a, {});
  return const DeepCollectionEquality().equals(a, b);
}

class DeepCollectionEquality {
  const DeepCollectionEquality();
  bool equals(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length && a.keys.every((k) => b.containsKey(k) && _deepEq(a[k], b[k]));
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_deepEq(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }
}

String t(String key) => key;

void main() {
  group('formatToTracingNodeList', () {
    late List<List<DifyJson>> agentCalls, humanCalls, retryCalls;
    late List<List<DifyJson>> agentResults, humanResults;
    late List<(DifyJson, List<DifyJson>)> loopCalls, iterationCalls;
    late List<List<DifyJson>> parallelCalls;
    late FormatLogPipeline pipeline;

    setUp(() {
      agentCalls = [];
      humanCalls = [];
      retryCalls = [];
      agentResults = [];
      humanResults = [];
      loopCalls = [];
      iterationCalls = [];
      parallelCalls = [];
      pipeline = FormatLogPipeline(
        agent: (list) {
          agentCalls.add(list);
          agentResults.add(list);
          return list;
        },
        humanInput: (list) {
          humanCalls.add(list);
          humanResults.add(list);
          return list;
        },
        retry: (list) {
          retryCalls.add(list);
          return list;
        },
        loop: (item, children) {
          loopCalls.add((item, children));
          return {
            ...item,
            'loopChildren': [for (final c in children) c['node_id']],
            'details': [
              [
                {'id': 'loop-detail-row'},
              ],
            ],
          };
        },
        iteration: (item, children) {
          iterationCalls.add((item, children));
          return {
            ...item,
            'iterationChildren': [for (final c in children) c['node_id']],
            'details': [
              [
                {'id': 'iteration-detail-row'},
              ],
            ],
          };
        },
        parallel: (list, [tr]) {
          parallelCalls.add(list);
          return [
            for (final item in list) {...item, 'parallelFormatted': true},
          ];
        },
      );
    });

    test('should sort the input by index and run the formatter pipeline in order', () {
      final traces = [
        createTrace(id: 'b', nodeId: 'b', title: 'B', index: 2),
        createTrace(id: 'a', nodeId: 'a', title: 'A', index: 0),
        createTrace(id: 'c', nodeId: 'c', title: 'C', index: 1),
      ];
      final result = formatToTracingNodeList(traces, t, pipeline);
      expect(agentCalls.single, [
        containing({'node_id': 'a'}),
        containing({'node_id': 'c'}),
        containing({'node_id': 'b'}),
      ]);
      expect(identical(humanCalls.single, agentResults.single), isTrue);
      expect(identical(retryCalls.single, humanResults.single), isTrue);
      expect(parallelCalls.last, isA<List<DifyJson>>());
      expect(result, [
        containing({'node_id': 'a', 'parallelFormatted': true}),
        containing({'node_id': 'c', 'parallelFormatted': true}),
        containing({'node_id': 'b', 'parallelFormatted': true}),
      ]);
    });

    test('should collapse loop and iteration children into parent nodes and propagate child failures', () {
      final loopParent = createTrace(id: 'loop-parent', nodeId: 'loop-parent', nodeType: 'loop', index: 0);
      final loopChild = createTrace(
        id: 'loop-child',
        nodeId: 'loop-child',
        index: 1,
        status: 'failed',
        error: 'loop child failed',
        executionMetadata: meta({'loop_id': 'loop-parent'}),
      );
      final iterationParent = createTrace(
        id: 'iteration-parent',
        nodeId: 'iteration-parent',
        nodeType: 'iteration',
        index: 2,
      );
      final iterationChild = createTrace(
        id: 'iteration-child',
        nodeId: 'iteration-child',
        index: 3,
        status: 'failed',
        error: 'iteration child failed',
        executionMetadata: meta({'iteration_id': 'iteration-parent'}),
      );
      final result = formatToTracingNodeList([loopParent, loopChild, iterationParent, iterationChild], t, pipeline);
      expect(
        loopCalls.single.$1,
        containing({'node_id': 'loop-parent', 'status': 'failed', 'error': 'loop child failed'}),
      );
      expect(loopCalls.single.$2, [
        containing({'node_id': 'loop-child'}),
      ]);
      expect(
        iterationCalls.single.$1,
        containing({'node_id': 'iteration-parent', 'status': 'failed', 'error': 'iteration child failed'}),
      );
      expect(iterationCalls.single.$2, [
        containing({'node_id': 'iteration-child'}),
      ]);
      expect(parallelCalls, hasLength(3));
      expect(result, [
        containing({
          'node_id': 'loop-parent',
          'loopChildren': ['loop-child'],
          'parallelFormatted': true,
        }),
        containing({
          'node_id': 'iteration-parent',
          'iterationChildren': ['iteration-child'],
          'parallelFormatted': true,
        }),
      ]);
    });
  });

  group('agent format log', () {
    DifyJson agentTrace(List<DifyJson> agentLog, [String nodeType = 'agent']) => {
      'node_id': 'agent-node',
      'node_type': nodeType,
      'execution_metadata': {'agent_log': agentLog},
    };
    DifyJson log(String messageId, [String? parentId]) => {'message_id': messageId, 'parent_id': ?parentId};

    test('should transform flat agent logs into a tree', () {
      final result = formatAgentNode([
        agentTrace([log('root'), log('child-1', 'root'), log('child-2', 'root'), log('grandchild', 'child-1')]),
      ]).first;
      expect(result['agentLog'], [
        containing({
          'message_id': 'root',
          'children': [
            containing({
              'message_id': 'child-1',
              'children': [
                containing({'message_id': 'grandchild'}),
              ],
            }),
            containing({'message_id': 'child-2'}),
          ],
        }),
      ]);
    });

    test('should remove one-step circle log entries', () {
      final result = formatAgentNode([
        agentTrace([log('root'), log('root', 'root')]),
      ]).first;
      expect(result['agentLog'], [
        containing({'message_id': 'root', 'hasCircle': true, 'children': <Object?>[]}),
      ]);
    });

    test('should not attach agent logs to unsupported node types', () {
      final result = formatAgentNode([
        agentTrace([log('root')], 'start'),
      ]).first;
      expect(result['agentLog'], isEmpty);
    });
  });

  group('formatHumanInputNode', () {
    test('keeps only the latest human-input log for each node and preserves other logs', () {
      final list = [
        createTrace(id: 'trace-1', index: 1, nodeId: 'human-1', nodeType: 'human-input', title: 'Human Input'),
        createTrace(id: 'trace-2', index: 2, nodeId: 'code-1', nodeType: 'code'),
        createTrace(id: 'trace-3', index: 3, nodeId: 'human-1', nodeType: 'human-input', title: 'Human Input Latest'),
      ];
      expect(formatHumanInputNode(list), [list[2], list[1]]);
    });

    test('returns the original list when there are no human-input nodes', () {
      final list = [createTrace(nodeType: 'code')];
      expect(formatHumanInputNode(list), list);
    });
  });

  group('iteration format log', () {
    DifyJson trace(String nodeId, [Map<String, Object?> m = const {}]) => {
      'node_id': nodeId,
      'execution_metadata': meta(m),
    };

    test('should place the first child of a new iteration at a new record when its index is missing', () {
      final parent = trace('iteration');
      final child = trace('code', {'iteration_id': 'iteration', 'iteration_index': 0});
      final streamingChild = trace('code', {'iteration_id': 'iteration'});
      expect(addChildrenToIterationNode(parent, [child, streamingChild])['details'], [
        [child],
        [streamingChild],
      ]);
    });

    test('should keep missing iteration index items in the current record when the node has not restarted', () {
      final parent = trace('iteration');
      final first = trace('code', {'iteration_id': 'iteration', 'iteration_index': 0});
      final second = trace('code', {'iteration_id': 'iteration', 'iteration_index': 1});
      final streaming = trace('tool', {'iteration_id': 'iteration'});
      expect(addChildrenToIterationNode(parent, [first, second, streaming])['details'], [
        [first],
        [second, streaming],
      ]);
    });

    test('should not move an earlier missing iteration index item into the latest record', () {
      final parent = trace('iteration');
      final first = trace('code', {'iteration_id': 'iteration', 'iteration_index': 0});
      final streaming = trace('tool', {'iteration_id': 'iteration'});
      final second = trace('code', {'iteration_id': 'iteration', 'iteration_index': 1});
      expect(addChildrenToIterationNode(parent, [first, streaming, second])['details'], [
        [first, streaming],
        [second],
      ]);
    });
  });

  group('loop format log', () {
    DifyJson trace(String nodeId, [Map<String, Object?> m = const {}]) => {
      'node_id': nodeId,
      'execution_metadata': meta(m),
    };

    test('should place the first child of a new loop at a new record when its index is missing', () {
      final parent = trace('loop');
      final child = trace('code', {'loop_id': 'loop', 'loop_index': 0});
      final streaming = trace('code', {'loop_id': 'loop'});
      expect(addChildrenToLoopNode(parent, [child, streaming])['details'], [
        [child],
        [streaming],
      ]);
    });

    test('should keep missing loop index items in the current record when the node has not restarted', () {
      final parent = trace('loop');
      final first = trace('code', {'loop_id': 'loop', 'loop_index': 0});
      final second = trace('code', {'loop_id': 'loop', 'loop_index': 1});
      final streaming = trace('tool', {'loop_id': 'loop'});
      expect(addChildrenToLoopNode(parent, [first, second, streaming])['details'], [
        [first],
        [second, streaming],
      ]);
    });

    test('should group loop children by parallel run id before loop index', () {
      final parent = trace('loop');
      final a = trace('code', {'loop_id': 'loop', 'loop_index': 0, 'parallel_mode_run_id': 'parallel-a'});
      final b = trace('tool', {'loop_id': 'loop', 'loop_index': 0, 'parallel_mode_run_id': 'parallel-b'});
      expect(addChildrenToLoopNode(parent, [a, b])['details'], [
        [a],
        [b],
      ]);
    });
  });

  group('formatParallel', () {
    String tp(String key) => switch (key) {
      'common.parallel' => 'Parallel',
      'common.branch' => 'Branch',
      _ => key,
    };

    test('groups parallel nodes into a titled tree and preserves branch titles', () {
      final result = formatParallelNode([
        createTrace(
          id: 'parallel-start',
          nodeId: 'parallel-start',
          nodeType: 'code',
          title: 'Parallel Start',
          extra: {
            'parallel_id': 'parallel-1',
            'parallel_start_node_id': 'parallel-start',
            'parallelDetail': {'isParallelStartNode': true, 'children': <Object?>[]},
          },
        ),
        createTrace(
          id: 'branch-a',
          nodeId: 'branch-a',
          nodeType: 'code',
          title: 'Branch A',
          extra: {'parallel_id': 'parallel-1', 'parallel_start_node_id': 'branch-a'},
        ),
        createTrace(
          id: 'branch-child',
          nodeId: 'branch-child',
          nodeType: 'code',
          title: 'Branch Child',
          extra: {'parallel_id': 'parallel-1', 'parallel_start_node_id': 'branch-a'},
        ),
      ], tp);
      expect(result, isNotEmpty);
      expect(result.any((n) => n['parallelDetail'] != null), isTrue);
      expect(result.any((n) => ((n['parallelDetail'] as Map?)?['children'] as List?)?.isNotEmpty ?? false), isTrue);
    });

    test('ignores nodes outside parallel groups', () {
      final standalone = createTrace(nodeId: 'standalone', nodeType: 'code', title: 'Standalone');
      expect(formatParallelNode([standalone], tp), [standalone]);
    });
  });

  group('retry format log', () {
    DifyJson trace(String nodeId, String status, [Map<String, Object?> m = const {}]) => {
      'node_id': nodeId,
      'status': status,
      'execution_metadata': meta(m),
    };

    test('should remove retry status nodes and attach them to the matching node', () {
      final one = trace('code', 'retry'), two = trace('code', 'retry'), finalRun = trace('code', 'succeeded');
      expect(formatRetryNode([one, two, finalRun]), [
        containing({
          'node_id': 'code',
          'status': 'succeeded',
          'retryDetail': [one, two],
        }),
      ]);
    });

    test('should match retry nodes by loop index inside loop runs', () {
      final previous = trace('tool', 'retry', {'loop_id': 'loop', 'loop_index': 0});
      final current = trace('tool', 'retry', {'loop_id': 'loop', 'loop_index': 1});
      final finalRun = trace('tool', 'succeeded', {'loop_id': 'loop', 'loop_index': 1});
      expect(formatRetryNode([previous, current, finalRun]), [
        containing({
          'retryDetail': [current],
        }),
      ]);
    });
  });
}
