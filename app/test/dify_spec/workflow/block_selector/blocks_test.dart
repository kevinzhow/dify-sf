// dify-spec: web/app/components/workflow/block-selector/__tests__/blocks.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/blocks_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _dialog = 'agent-v-2.roster.nodeSelector.dialogLabel';

AgentOption _agent(String id, String name, {String role = 'Researcher', String? snapshot = 'version-1'}) => AgentOption(
  id: id,
  name: name,
  role: role,
  description: 'Clarification Drafter',
  icon: 'A',
  iconType: 'emoji',
  activeConfigSnapshotId: snapshot,
);

Widget _blocks(SelectRecorder rec, List<BlockMeta> blocks, List<String> types, {String search = ''}) => SizedBox(
  width: 400,
  child: BlocksPanel(searchText: search, onSelect: rec.call, availableBlocksTypes: types, blocks: blocks),
);

void main() {
  setUpBlockSelectorTests();

  group('Blocks', () {
    testWidgets('should render grouped blocks, filter duplicate knowledge-base nodes, and select a block', (t) async {
      final semantics = t.ensureSemantics();
      final rec = SelectRecorder();
      await pumpSelector(
        t,
        _blocks(
          rec,
          [
            block('llm', 'LLM'),
            block('loop-end', 'Exit Loop', classification: 'logic'),
            block('knowledge-index', 'Knowledge Retrieval'),
          ],
          const ['llm', 'loop-end', 'knowledge-index'],
        ),
        data: const BlockSelectorData(nodes: [(id: 'kb', type: 'knowledge-index')]),
      );
      final llm = t.getSemantics(find.bySemanticsLabel('LLM')).getSemanticsData();
      expect(llm.flagsCollection.isButton, isTrue);
      expect(llm.hint, 'LLM description');
      expect(find.text('Exit Loop'), findsOneWidget);
      expect(find.text('WORKFLOW.NODES.LOOP.LOOPNODE'), findsOneWidget);
      expect(find.text('Knowledge Retrieval'), findsNothing);

      await tapText(t, 'LLM');
      expect(rec.calls, [('llm', null)]);
      semantics.dispose();
    });

    testWidgets('should show the empty state when no block matches the search text', (t) async {
      await pumpSelector(t, _blocks(SelectRecorder(), [block('llm', 'LLM')], const ['llm'], search: 'missing'));
      expect(find.text('workflow.tabs.noResult'), findsOneWidget);
    });

    testWidgets('opens the agent selector on Agent block hover', (t) async {
      await pumpSelector(
        t,
        _blocks(SelectRecorder(), [block('agent-v2', 'Agent')], const ['agent-v2']),
        data: BlockSelectorData(searchAgents: (_) async => const []),
      );
      expect(find.text('COMMON.MENUS.STATUS'), findsOneWidget);
      await hover(t, find.text('Agent'));
      expect(dialogNamed(_dialog), findsOneWidget);
    });

    testWidgets('opens the agent selector from the Agent block and selects an agent', (t) async {
      final rec = SelectRecorder();
      final keywords = <String>[];
      await pumpSelector(
        t,
        _blocks(rec, [block('llm', 'LLM'), block('agent-v2', 'Agent', sort: 3)], const ['llm', 'agent-v2']),
        data: BlockSelectorData(
          searchAgents: (k) async {
            keywords.add(k);
            return [_agent('agent-1', 'Nadia')];
          },
        ),
      );
      expect(t.getTopLeft(find.text('Agent')).dy, lessThan(t.getTopLeft(find.text('LLM')).dy));

      await tapText(t, 'Agent');
      expect(dialogNamed(_dialog), findsOneWidget);
      expect(searchField('agent-v-2.roster.nodeSelector.searchPlaceholder'), findsOneWidget);
      expect(find.text('Nadia'), findsOneWidget);
      expect(find.text('Researcher'), findsOneWidget);

      await tapText(t, 'Nadia');
      expect(rec.calls.single.$1, 'agent-v2');
      expect(rec.calls.single.$2, {
        'agent_binding': {'binding_type': 'roster_agent', 'agent_id': 'agent-1'},
        'agent_node_kind': 'dify_agent',
        'version': '2',
      });
      expect(keywords, ['']);
    });

    testWidgets('should refresh Agent v2 roster options when the selector is reopened', (t) async {
      var calls = 0;
      await pumpSelector(
        t,
        _blocks(SelectRecorder(), [block('agent-v2', 'Agent', sort: 3)], const ['agent-v2']),
        data: BlockSelectorData(
          searchAgents: (_) async =>
              ++calls == 1 ? [_agent('agent-1', 'Nadia')] : [_agent('agent-2', 'Bruno', role: 'Planner')],
        ),
      );
      await tapText(t, 'Agent');
      expect(find.text('Nadia'), findsOneWidget);

      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t);
      expect(dialogNamed(_dialog), findsNothing);

      await tapText(t, 'Agent');
      expect(find.text('Bruno'), findsOneWidget);
      expect(find.text('Planner'), findsOneWidget);
      expect(calls, 2);
      expect(find.text('Nadia'), findsNothing);
    });

    testWidgets('does not select an Agent v2 roster agent without active config snapshot', (t) async {
      final rec = SelectRecorder();
      final errors = <String>[];
      await pumpSelector(
        t,
        _blocks(rec, [block('agent-v2', 'Agent', sort: 3)], const ['agent-v2']),
        data: BlockSelectorData(
          searchAgents: (_) async => [_agent('agent-1', 'Nadia', snapshot: null)],
          onError: errors.add,
        ),
      );
      await tapText(t, 'Agent');
      await tapText(t, 'Nadia');
      expect(errors, ['workflow.nodes.agent.modelNotSelected']);
      expect(rec.calls, isEmpty);
    });

    testWidgets('inserts an inline Agent v2 node from the selector start action', (t) async {
      final rec = SelectRecorder();
      await pumpSelector(
        t,
        _blocks(rec, [block('agent-v2', 'Agent', sort: 3)], const ['agent-v2']),
        data: BlockSelectorData(searchAgents: (_) async => const []),
      );
      await tapText(t, 'Agent');
      final link = find.ancestor(
        of: find.text('agent-v-2.roster.nodeSelector.manageInAgentConsole'),
        matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.link == true),
      );
      expect(t.widget<Semantics>(link.first).properties.linkUrl, Uri.parse('/agents'));

      await tapText(t, 'agent-v-2.roster.nodeSelector.startFromScratch');
      expect(rec.calls.single.$1, 'agent-v2');
      expect(rec.calls.single.$2, {
        'agent_binding': {'binding_type': 'inline_agent'},
        'agent_node_kind': 'dify_agent',
        'version': '2',
      });
    });

    testWidgets('closes the agent selector when Escape closes the combobox', (t) async {
      await pumpSelector(
        t,
        _blocks(SelectRecorder(), [block('agent-v2', 'Agent')], const ['agent-v2']),
        data: BlockSelectorData(searchAgents: (_) async => const []),
      );
      await tapText(t, 'Agent');
      expect(dialogNamed(_dialog), findsOneWidget);

      await t.tap(searchField('agent-v-2.roster.nodeSelector.searchPlaceholder'));
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t);
      expect(dialogNamed(_dialog), findsNothing);
    });
  });
}
