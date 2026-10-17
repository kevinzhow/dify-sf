import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/workflow/block_selector/harness.dart';

void main() {
  setUpBlockSelectorTests();

  group('blockDefaults', () {
    test("is each block's default.ts defaultValue with its type and title", () {
      expect(blockDefaults('llm'), {
        'model': {
          'provider': '',
          'name': '',
          'mode': 'chat',
          'completion_params': {'temperature': 0.7},
        },
        'prompt_template': [
          {'role': 'system', 'text': ''},
        ],
        'context': {'enabled': false, 'variable_selector': <Object?>[]},
        'vision': {'enabled': false},
        'type': 'llm',
        'title': 'workflow.blocks.llm',
      });
      expect(blockDefaults('if-else')!['cases'], [
        {'case_id': 'true', 'logical_operator': 'and', 'conditions': <Object?>[]},
      ]);
      expect(blockDefaults('http-request')!['authorization'], {'type': 'no-auth', 'config': null});
      expect(blockDefaults('knowledge-retrieval')!['multiple_retrieval_config'], {
        'top_k': 4,
        'reranking_enable': false,
      });
      expect(blockDefaults('trigger-schedule')!['visual_config'], {
        'time': '12:00 AM',
        'weekdays': ['sun'],
        'on_minute': 0,
        'monthly_days': [1],
      });
      expect(
        (blockDefaults('trigger-webhook')!['variables']! as List).single,
        containsPair('variable', '_webhook_raw'),
      );
      expect(blockDefaults('code'), containsPair('code_language', 'python3'));
      expect(blockDefaults('iteration'), containsPair('error_handle_mode', 'terminated'));
      expect(blockDefaults('loop'), containsPair('loop_count', 10));
      expect(blockDefaults('human-input'), containsPair('timeout_unit', 'day'));
      expect(blockDefaults('list-operator')!['order_by'], {'enabled': false, 'key': '', 'value': 'asc'});
    });

    test('gives Agent v2 an agent node and the aggregator for the variable assigner', () {
      final agent = blockDefaults('agent-v2')!;
      expect(agent['type'], 'agent');
      expect(agent['title'], 'workflow.blocks.agent-v2');
      expect(agent['agent_binding'], {'binding_type': 'inline_agent'});
      expect(blockDefaults('variable-assigner')!['type'], 'variable-aggregator');
    });

    test('offers only the blocks of the mode', () {
      expect(blockDefaults('end'), isNotNull);
      expect(blockDefaults('answer'), isNull);
      expect(blockDefaults('end', chatMode: true), isNull);
      expect(blockDefaults('answer', chatMode: true), containsPair('answer', ''));
      expect(blockDefaults('trigger-webhook', chatMode: true), isNull);
      expect(blockDefaults('nope'), isNull);
    });

    test('returns fresh data each time', () {
      (blockDefaults('code')!['variables']! as List).add('x');
      expect(blockDefaults('code')!['variables'], isEmpty);
    });
  });

  group('availableNodeTypes', () {
    test('follows useAvailableNodesMetaData', () {
      final workflow = availableNodeTypes();
      expect(workflow, containsAll(['start', 'start-placeholder', 'end', 'trigger-plugin', 'agent']));
      expect(workflow, isNot(contains('answer')));
      expect(workflow, isNot(contains('agent-v2')));
      final chat = availableNodeTypes(chatMode: true, agentV2: true);
      expect(chat, containsAll(['start', 'answer', 'agent-v2']));
      expect(chat, isNot(contains('end')));
      expect(chat, isNot(contains('agent')));
    });
  });

  group('new nodes', () {
    test('number the title after the nodes of the same type', () {
      final d = blockDefaults('llm')!;
      expect(newNodeData('llm', d)['title'], 'workflow.blocks.llm');
      expect(
        newNodeData(
          'llm',
          d,
          existing: [
            {'type': 'llm'},
            {'type': 'llm'},
            {'type': 'code'},
          ],
        )['title'],
        'workflow.blocks.llm 3',
      );
      final v2 = blockDefaults('agent-v2')!;
      final existing = [
        {'type': 'agent'},
        {'type': 'agent', 'agent_node_kind': 'dify_agent', 'version': '2'},
      ];
      expect(newNodeData('agent-v2', v2, existing: existing)['title'], 'workflow.blocks.agent-v2 2');
      expect(
        newNodeData('tool', blockDefaults('tool')!, toolDefaultValue: {'title': 'Google Search'})['title'],
        'Google Search',
      );
    });

    test('give iterations and loops their start node, and candidates their flag', () {
      final it = generateNewNode(id: 'n1', data: blockDefaults('iteration')!, position: (x: 1, y: 2));
      expect(it.start!['id'], 'n1start');
      expect(it.start!['type'], 'custom-iteration-start');
      expect((it.node['data']! as Map)['start_node_id'], 'n1start');
      expect(it.node['position'], {'x': 1, 'y': 2});
      final exit = candidateNodeOf('loop-end', blockDefaults('loop-end')!, id: 'c');
      expect(exit['type'], 'custom-simple');
      expect((exit['data']! as Map)['_isCandidate'], isTrue);
    });
  });

  test('pinyin initials index hanzi titles', () {
    expect(pinyinInitial('中'), 'Z');
    expect(pinyinInitial('阿'), 'A');
    expect(pinyinInitial('x'), isNull);
  });

  testWidgets('opens at a rectangle for triggers that are not widgets', (t) async {
    final picked = <(String, Map<String, Object?>, Map<String, Object?>?)>[];
    late BuildContext anchor;
    await pumpSelector(
      t,
      Builder(
        builder: (context) {
          anchor = context;
          return const SizedBox(width: 16, height: 16);
        },
      ),
      data: const BlockSelectorData(chatMode: true),
    );
    final closed = BlockSelector(
      availableBlocksTypes: const ['answer', 'llm'],
      placement: DifyPlacement.left,
      onSelect: (type, defaults, {toolDefaultValue}) => picked.add((type, defaults, toolDefaultValue)),
    ).show(anchor, anchor: const Rect.fromLTWH(600, 300, 16, 16));
    var done = false;
    closed.then((_) => done = true);
    await settle(t);
    expect(rowText('workflow.blocks.answer'), findsOneWidget);
    expect(t.getTopRight(find.byType(BlockSelectorCard)).dx, lessThan(600));

    await t.tap(rowText('workflow.blocks.answer'));
    await settle(t);
    expect(picked.single.$1, 'answer');
    expect(picked.single.$2, containsPair('type', 'answer'));
    expect(find.byType(BlockSelectorCard), findsNothing);
    expect(done, isTrue);
  });

  testWidgets('closes the anchored selector on Escape', (t) async {
    late BuildContext anchor;
    await pumpSelector(
      t,
      Builder(
        builder: (context) => SizedBox.square(
          dimension: 10,
          child: Builder(
            builder: (c) {
              anchor = c;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    BlockSelector(availableBlocksTypes: const ['llm'], onSelect: (_, _, {toolDefaultValue}) {}).show(anchor);
    await settle(t);
    expect(find.byType(BlockSelectorCard), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(t);
    expect(find.byType(BlockSelectorCard), findsNothing);
  });

  testWidgets('hands tools their ToolDefaultValue with the tool defaults', (t) async {
    final picked = <(String, Map<String, Object?>, Map<String, Object?>?)>[];
    await pumpSelector(
      t,
      BlockSelector(
        open: true,
        defaultActiveTab: BlockSelectorTab.tools,
        onSelect: (type, defaults, {toolDefaultValue}) => picked.add((type, defaults, toolDefaultValue)),
      ),
      data: BlockSelectorData(buildInTools: [toolProvider()]),
    );
    await tapText(t, 'Provider One');
    await tapText(t, 'Tool A');
    final (type, defaults, tool) = picked.single;
    expect(type, 'tool');
    expect(defaults, containsPair('tool_node_version', '2'));
    expect(tool, containsPair('tool_name', 'tool-a'));
    expect(newNodeData(type, defaults, toolDefaultValue: tool)['title'], 'Tool A');
  });
}
