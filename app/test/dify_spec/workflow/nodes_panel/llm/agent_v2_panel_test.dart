// dify-spec: web/app/components/workflow/nodes/agent-v2/__tests__/panel.spec.tsx
//
// The Agent v2 panel over a document in an in-memory session. Dify's mocked hooks become the services: the roster
// detail (`fetchRosterAgent`), the inline composer (`fetchInlineAgent`), inline creation, copy and save to roster,
// the invite options, and the inline workspace (a builder with Dify's mock buttons). Dify's setInputs and
// handleNodeDataUpdateWithSyncDraft both write the document; the cases read the node's data.
import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/agent_v2_logic.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/agent_v2_outputs.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/agent_v2_roster.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/llm_bodies.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Map<String, Object?> _data([Map<String, Object?> overrides = const {}]) => {
  'agent_binding': {'binding_type': 'roster_agent', 'agent_id': 'agent-1'},
  'agent_node_kind': 'dify_agent',
  'version': '2',
  ...overrides,
};

const _nadia = {
  'id': 'agent-1',
  'name': 'Nadia',
  'description': 'Clarification Drafter',
  'icon': 'N',
  'icon_background': '#E9D7FE',
  'icon_type': 'emoji',
  'permission_keys': ['agent.acl.edit'],
  'role': 'Researcher',
};

const _inline = {
  'binding_type': 'inline_agent',
  'agent_id': 'inline-agent-1',
  'current_snapshot_id': 'snapshot-1',
};

Map<String, Object?> _composer(String agentId, {String name = 'Workflow Agent 1'}) => {
  'agent': {'id': agentId, 'name': name, 'description': '', 'scope': 'workflow_only', 'status': 'active'},
};

/// The recorded service calls.
class _Calls {
  final opened = <String>[];
  final created = <String>[];
  final copied = <(String, String)>[];
  final inlineFetches = <(String, String)>[];
  final saved = <Map<String, Object?>>[];
}

LlmGroupServices _services(
  _Calls calls, {
  Map<String, Object?>? roster = _nadia,
  FutureOr<Map<String, Object?>?> Function(String node, String agent)? inline,
  Map<String, Object?>? created,
  List<Map<String, Object?>> invite = const [],
  Widget Function(BuildContext, InlineAgentWorkspaceArgs)? workspace,
}) => LlmGroupServices(
  fetchRosterAgent: (id) async => roster == null ? null : {...roster, 'id': id},
  fetchInlineAgent: (node, agent) async {
    calls.inlineFetches.add((node, agent));
    return inline == null ? _composer(agent) : await inline(node, agent);
  },
  createInlineAgent: (node) async {
    calls.created.add(node);
    return created;
  },
  copyFromRoster: (node, source) async {
    calls.copied.add((node, source));
    return {
      'binding': {
        'id': 'binding-1',
        'binding_type': 'inline_agent',
        'agent_id': 'inline-copy-agent',
        'current_snapshot_id': 'inline-copy-snapshot',
      },
    };
  },
  saveToRoster: (node, form) async {
    calls.saved.add(form);
    return 'saved-roster-agent';
  },
  canCreateAgents: true,
  agentInviteOptions: (_) async => invite,
  inlineAgentWorkspaceBuilder: workspace,
);

Widget _workspace(BuildContext context, InlineAgentWorkspaceArgs args) => Column(
  children: [
    TextButton(onPressed: args.onSaveInlineToRoster, child: const Text('Inline workspace more')),
    TextButton(
      onPressed: () => args.onSaved({
        'binding_type': 'inline_agent',
        'agent_id': 'inline-agent-1',
        'current_snapshot_id': 'latest-snapshot-2',
      }),
      child: const Text('Autosave inline workspace'),
    ),
  ],
);

Finder _byLabel(Pattern label) => find.bySemanticsLabel(label);
final _openPanel = RegExp(r'^workflow\.nodes\.agent\.roster\.openPanel');

void main() {
  late List<String> urls;

  setUp(() {
    useDifyTestTranslator();
    urls = [];
  });

  Future<Harness> render(
    WidgetTester t, {
    Map<String, Object?> data = const {},
    LlmGroupServices? services,
    String? openInlineId,
  }) async {
    final h = await startPanel(t, [('agent-node', 'agent', _data(data))], pump: false);
    if (openInlineId != null) h.store.setOpenInlineAgentPanelNodeId(openInlineId);
    await t.pumpWidget(
      panelApp(
        h,
        LlmGroupScope(
          services: services ?? _services(_Calls()),
          child: ListenableBuilder(
            listenable: h.controller,
            builder: (context, _) => WorkflowNodePanel(
              key: const ValueKey('agent-node'),
              node: h['agent-node']!,
              actions: panelActions(h, options: WorkflowMenuOptions(openUrl: urls.add)),
              bodies: const NodePanelBodies(llmPanelBodies),
            ),
          ),
        ),
      ),
    );
    await settle(t);
    return h;
  }

  Map<String, Object?> binding(Harness h) => (dataOf(h, 'agent-node')['agent_binding']! as Map).cast();

  Future<void> expandOutputs(WidgetTester t) async {
    await t.tap(find.text('WORKFLOW.NODES.COMMON.OUTPUTVARS'));
    await settle(t);
  }

  Finder taskEditor() => find.descendant(of: find.byType(DifyPromptEditor), matching: find.byType(EditableText));

  Future<void> addOutput(WidgetTester t, String name, {String? description}) async {
    await t.tap(_byLabel('workflow.nodes.agent.outputVars.newOutput'));
    await settle(t);
    await t.enterText(
      find.descendant(of: find.byKey(const ValueKey('output-name')), matching: find.byType(TextField)),
      name,
    );
    if (description != null) {
      await t.enterText(
        find.descendant(of: find.byKey(const ValueKey('output-description')), matching: find.byType(TextField)),
        description,
      );
    }
    await t.pump();
  }

  group('agent/panel', () {
    testWidgets('renders selected roster agent trigger and default Agent v2 output vars', (t) async {
      final h = await render(t);
      expect(find.text('WORKFLOW.NODES.AGENT.ROSTER.LABEL'), findsOneWidget);
      expect(find.text('Nadia'), findsOneWidget);
      expect(find.text('WORKFLOW.NODES.AGENT.TASK.LABEL'), findsOneWidget);
      expect(_byLabel('workflow.nodes.agent.task.tooltip'), findsOneWidget);
      expect(_byLabel(RegExp(r'workflow\.nodes\.agent\.task\.label')), findsWidgets);
      expect(find.text('workflow.nodes.agent.advancedSetting'), findsNothing);
      await expandOutputs(t);
      expect(find.text('text'), findsOneWidget);
      expect(find.text('workflow.nodes.agent.outputVars.text'), findsOneWidget);
      expect(find.text('usage'), findsNothing);
      expect(find.text('files'), findsNothing);
      expect(find.text('json'), findsNothing);
      expect(_byLabel('workflow.nodes.agent.outputVars.newOutput'), findsOneWidget);
      await h.dispose(t);
    });

    testWidgets('links the Agent task explanation to its documentation', (t) async {
      final h = await render(t);
      await t.tap(_byLabel('workflow.nodes.agent.task.tooltip'));
      await settle(t);
      await t.tap(_byLabel('workflow.nodes.agent.task.learnMore'));
      await settle(t);
      expect(urls, ['https://docs.dify.ai/en/self-host/use-dify/nodes/agent#give-it-a-task']);
      await h.dispose(t);
    });

    testWidgets('opens and closes the roster agent layered panel', (t) async {
      final h = await render(t);
      await t.tap(_byLabel(_openPanel));
      await settle(t);
      final panel = find.bySemanticsLabel('Nadia');
      expect(find.byType(AgentRosterDrawer), findsOneWidget);
      expect(panel, findsWidgets);
      final drawer = find.byType(AgentRosterDrawer);
      expect(find.descendant(of: drawer, matching: find.text('Researcher')), findsOneWidget);
      await t.tap(find.descendant(of: drawer, matching: find.text('workflow.nodes.agent.roster.editInConsole')));
      expect(urls, ['/agents/agent-1/configure']);
      expect(find.descendant(of: drawer, matching: find.text('workflow.nodes.agent.roster.makeCopy')), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t);
      expect(find.byType(AgentRosterDrawer), findsNothing);
      await h.dispose(t);
    });

    testWidgets('copies a roster agent from the drawer into an inline agent for this node', (t) async {
      final calls = _Calls();
      final h = await render(t, services: _services(calls));
      await t.tap(_byLabel(_openPanel));
      await settle(t);
      await t.tap(find.text('workflow.nodes.agent.roster.makeCopy'));
      await settle(t);
      expect(calls.copied, [('agent-node', 'agent-1')]);
      expect(h.store.openInlineAgentPanelNodeId.value, 'agent-node');
      expect(binding(h), {
        'binding_type': 'inline_agent',
        'agent_id': 'inline-copy-agent',
        'current_snapshot_id': 'inline-copy-snapshot',
      });
      await h.dispose(t);
    });

    testWidgets('renders a required roster state when no roster agent is selected', (t) async {
      final h = await render(t, data: {'agent_binding': null});
      expect(find.text('WORKFLOW.NODES.AGENT.ROSTER.LABEL'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^workflow\.errorMsg\.fieldRequired')), findsOneWidget);
      expect(find.text('WORKFLOW.NODES.AGENT.TASK.LABEL'), findsOneWidget);
      await expandOutputs(t);
      expect(find.text('text'), findsOneWidget);
      expect(find.text('workflow.nodes.agent.outputVars.text'), findsOneWidget);
      await h.dispose(t);
    });

    testWidgets('renders a pending inline agent state while the binding is being created', (t) async {
      final h = await render(
        t,
        data: {
          'agent_binding': {'binding_type': 'inline_agent'},
        },
        openInlineId: 'agent-node',
        services: _services(_Calls(), workspace: _workspace),
      );
      expect(find.textContaining(RegExp(r'^workflow\.errorMsg\.fieldRequired')), findsNothing);
      expect(find.byKey(const ValueKey('agent-roster-loading')), findsOneWidget);
      final change = t.widget<DifyPressable>(
        find.byWidgetPredicate((w) => w is DifyPressable && w.semanticLabel == 'workflow.nodes.agent.roster.change'),
      );
      expect(change.disabled, isTrue);
      expect(find.bySemanticsLabel('workflow.nodes.agent.roster.inlineSetup.name'), findsWidgets);
      expect(find.text('Inline workspace more'), findsOneWidget);
      expect(find.text('workflow.nodes.agent.roster.editInConsole'), findsNothing);
      expect(find.text('workflow.nodes.agent.roster.makeCopy'), findsNothing);
      await t.tapAt(const Offset(1, 1));
      await h.dispose(t);
    });

    testWidgets('opens a pending inline agent modal and creates the inline agent before rendering details', (
      t,
    ) async {
      final calls = _Calls();
      final h = await render(
        t,
        data: {
          'agent_binding': {'binding_type': 'inline_agent'},
        },
        services: _services(calls, workspace: _workspace),
      );
      await t.tap(_byLabel(_openPanel));
      await settle(t);
      expect(h.store.openInlineAgentPanelNodeId.value, 'agent-node');
      expect(calls.created, ['agent-node']);
      expect(find.text('Inline workspace more'), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-roster-loading')), findsOneWidget);
      await h.dispose(t);
    });

    testWidgets('renders inline agent detail from workflow composer state and opens the inline panel', (t) async {
      final calls = _Calls();
      final h = await render(
        t,
        data: {'agent_binding': _inline},
        openInlineId: 'agent-node',
        services: _services(calls, workspace: _workspace),
      );
      expect(calls.inlineFetches.first, ('agent-node', 'inline-agent-1'));
      expect(find.bySemanticsLabel('Workflow Agent 1'), findsWidgets);
      expect(find.text('workflow.nodes.agent.roster.inlineSetup.name'), findsOneWidget);
      expect(find.text('workflow.nodes.agent.roster.inlineSetup.type'), findsOneWidget);
      expect(find.byKey(const ValueKey('inline-setup-avatar')), findsOneWidget);
      expect(find.text('Inline workspace more'), findsOneWidget);
      expect(find.text('workflow.nodes.agent.roster.editInConsole'), findsNothing);
      expect(find.text('workflow.nodes.agent.roster.makeCopy'), findsNothing);
      await h.dispose(t);
    });

    testWidgets('does not open copied inline agent configuration before its composer is created', (t) async {
      var ready = false;
      final h = await render(
        t,
        data: {
          'agent_binding': {
            'binding_type': 'inline_agent',
            'agent_id': 'source-inline-agent',
            'current_snapshot_id': 'source-inline-snapshot',
          },
        },
        openInlineId: 'agent-node',
        services: _services(
          _Calls(),
          workspace: _workspace,
          inline: (_, _) => ready
              ? {
                  ..._composer('cloned-inline-agent', name: 'Cloned Workflow Agent'),
                  'binding': {
                    'binding_type': 'inline_agent',
                    'agent_id': 'cloned-inline-agent',
                    'current_snapshot_id': 'cloned-inline-snapshot',
                  },
                }
              : {'agent': null},
        ),
      );
      expect(find.byKey(const ValueKey('agent-roster-loading')), findsOneWidget);
      expect(_byLabel(_openPanel), findsNothing);
      expect(find.text('Inline workspace more'), findsNothing);
      ready = true;
      await t.pump(const Duration(milliseconds: 1100));
      await settle(t);
      expect(find.bySemanticsLabel('Cloned Workflow Agent'), findsWidgets);
      expect(find.text('Inline workspace more'), findsOneWidget);
      await h.dispose(t);
    });

    testWidgets('uses the detail header when opening an existing inline agent from the roster trigger', (t) async {
      final calls = _Calls();
      final h = await render(
        t,
        data: {'agent_binding': _inline},
        services: _services(calls, workspace: _workspace),
      );
      final fetches = calls.inlineFetches.length;
      await t.tap(_byLabel(_openPanel));
      await settle(t);
      expect(h.store.openInlineAgentPanelNodeId.value, 'agent-node');
      expect(calls.inlineFetches.length, greaterThan(fetches));
      expect(find.bySemanticsLabel('Workflow Agent 1'), findsWidgets);
      expect(find.text('workflow.nodes.agent.roster.editInConsole'), findsNothing);
      expect(find.text('workflow.nodes.agent.roster.makeCopy'), findsNothing);
      expect(find.text('Inline workspace more'), findsOneWidget);
      await h.dispose(t);
    });

    testWidgets('keeps the inline roster trigger stable while opening refetches composer state', (t) async {
      var first = true;
      final refetch = Completer<Map<String, Object?>?>();
      final h = await render(
        t,
        data: {'agent_binding': _inline},
        services: _services(
          _Calls(),
          workspace: _workspace,
          inline: (_, agent) {
            if (first) {
              first = false;
              return _composer(agent);
            }
            return refetch.future;
          },
        ),
      );
      await t.tap(_byLabel(_openPanel));
      await settle(t);
      expect(find.byKey(const ValueKey('agent-roster-loading')), findsNothing);
      expect(find.text('workflow.nodes.agent.roster.inlineSetup.name'), findsOneWidget);
      expect(find.text('workflow.nodes.agent.roster.inlineSetup.type'), findsOneWidget);
      expect(find.text('Inline workspace more'), findsOneWidget);
      refetch.complete(_composer('inline-agent-1'));
      await settle(t);
      await h.dispose(t);
    });

    testWidgets(
      'opens save-to-roster action from the inline workspace menu and rebinds to the saved roster agent',
      (t) async {
        final calls = _Calls();
        final h = await render(
          t,
          data: {'agent_binding': _inline},
          openInlineId: 'agent-node',
          services: _services(calls, workspace: _workspace),
        );
        expect(find.text('workflow.nodes.agent.roster.more'), findsNothing);
        await t.tap(find.text('Inline workspace more'));
        await settle(t);
        await t.enterText(
          find.descendant(of: find.byKey(const ValueKey('roster-name')), matching: find.byType(EditableText)),
          'Roster Agent',
        );
        await t.tap(find.text('common.operation.save'));
        await settle(t);
        expect(calls.saved.single['new_agent_name'], 'Roster Agent');
        expect(h.store.openInlineAgentPanelNodeId.value, isNull);
        expect(binding(h), {'binding_type': 'roster_agent', 'agent_id': 'saved-roster-agent'});
        await h.dispose(t);
      },
    );

    testWidgets('updates the inline binding snapshot from the inline workspace autosave response', (t) async {
      final h = await render(
        t,
        data: {'agent_binding': _inline},
        openInlineId: 'agent-node',
        services: _services(_Calls(), workspace: _workspace),
      );
      await t.tap(find.text('Autosave inline workspace'));
      await settle(t);
      expect(binding(h), {
        'binding_type': 'inline_agent',
        'agent_id': 'inline-agent-1',
        'current_snapshot_id': 'latest-snapshot-2',
      });
      expect(h.store.openInlineAgentPanelNodeId.value, 'agent-node');
      await h.dispose(t);
    });

    testWidgets('does not show start from scratch for an existing inline agent binding', (t) async {
      final h = await render(t, data: {'agent_binding': _inline});
      await t.tap(_byLabel('workflow.nodes.agent.roster.change'));
      await settle(t);
      expect(find.text('agent-v-2.roster.nodeSelector.startFromScratch'), findsNothing);
      expect(find.text('agent-v-2.roster.nodeSelector.manageInAgentConsole'), findsOneWidget);
      await h.dispose(t);
    });

    testWidgets('keeps the inline panel closed while workflow composer state is still loading', (t) async {
      final calls = _Calls();
      final h = await render(
        t,
        data: {'agent_binding': _inline},
        openInlineId: 'agent-node',
        services: _services(calls, workspace: _workspace, inline: (_, _) => Completer<Map<String, Object?>?>().future),
      );
      expect(calls.inlineFetches.single, ('agent-node', 'inline-agent-1'));
      expect(find.byKey(const ValueKey('agent-roster-loading')), findsOneWidget);
      expect(_byLabel(_openPanel), findsNothing);
      expect(find.text('Inline workspace more'), findsNothing);
      await h.dispose(t);
    });

    testWidgets('shows a retry action when loading the inline agent composer fails', (t) async {
      final calls = _Calls();
      final h = await render(
        t,
        data: {'agent_binding': _inline},
        services: _services(calls, inline: (_, _) => throw Exception('failed')),
      );
      expect(find.byKey(const ValueKey('agent-roster-loading')), findsNothing);
      expect(find.text('agent-v-2.roster.nodeSelector.createInlineFailed'), findsOneWidget);
      final before = calls.inlineFetches.length;
      await t.tap(find.text('common.operation.retry'));
      await settle(t);
      expect(calls.inlineFetches.length, greaterThan(before));
      await h.dispose(t);
    });

    testWidgets('updates roster agent binding from the selector', (t) async {
      final h = await render(
        t,
        services: _services(
          _Calls(),
          invite: [
            {
              'id': 'agent-2',
              'name': 'Mara',
              'description': 'Tender Analyst',
              'icon': 'M',
              'icon_background': '#D1E9FF',
              'icon_type': 'emoji',
              'role': 'Analyst',
              'active_config_snapshot_id': 'snap',
            },
          ],
        ),
      );
      await t.tap(_byLabel('workflow.nodes.agent.roster.change'));
      await settle(t);
      await t.tap(find.text('Mara'));
      await settle(t);
      expect(binding(h), {'binding_type': 'roster_agent', 'agent_id': 'agent-2'});
      await h.dispose(t);
    });

    testWidgets('switches a roster agent to a workflow-only inline agent from the selector', (t) async {
      final calls = _Calls();
      final h = await render(
        t,
        data: {
          'agent_task': 'Keep this task',
          'agent_declared_outputs': [
            {'name': 'summary', 'type': 'string'},
          ],
        },
        services: _services(
          calls,
          created: {
            'binding_type': 'inline_agent',
            'agent_id': 'inline-agent-1',
            'current_snapshot_id': 'inline-snapshot-1',
          },
        ),
      );
      await t.tap(_byLabel('workflow.nodes.agent.roster.change'));
      await settle(t);
      await t.tap(find.text('agent-v-2.roster.nodeSelector.startFromScratch'));
      await settle(t);
      expect(h.store.openInlineAgentPanelNodeId.value, 'agent-node');
      expect(calls.created, ['agent-node']);
      final d = dataOf(h, 'agent-node');
      expect(d['agent_binding'], {
        'binding_type': 'inline_agent',
        'agent_id': 'inline-agent-1',
        'current_snapshot_id': 'inline-snapshot-1',
      });
      expect(d['agent_task'], 'Keep this task');
      expect(d['agent_declared_outputs'], [
        {'name': 'summary', 'type': 'string'},
      ]);
      await t.tapAt(const Offset(1, 1));
      await h.dispose(t);
    });

    testWidgets('does not fall back to the roster agent description when role is empty', (t) async {
      final h = await render(t, services: _services(_Calls(), roster: {..._nadia, 'role': ''}));
      expect(find.text('Nadia'), findsOneWidget);
      expect(find.text('Clarification Drafter'), findsNothing);
      await h.dispose(t);
    });

    testWidgets('updates agent task and opens prompt insertion shortcuts', (t) async {
      final h = await render(t, data: {'agent_task': 'Graph task'});
      expect(find.text('Graph task', findRichText: true), findsWidgets);
      expect(_byLabel('workflow.nodes.agent.task.insert'), findsNothing);
      await t.enterText(taskEditor(), 'Clarify');
      await settle(t);
      expect(dataOf(h, 'agent-node')['agent_task'], 'Clarify');
      expect(_byLabel('workflow.nodes.agent.task.insert'), findsOneWidget);
      expect(find.text('workflow.nodes.agent.task.mention'), findsNothing);
      await t.tap(_byLabel('workflow.nodes.agent.task.insert'));
      await settle(t);
      expect(dataOf(h, 'agent-node')['agent_task'], endsWith('/'));
      await h.dispose(t);
    });

    testWidgets('keeps output variables synced when prompt text rename arrives before output block data', (t) async {
      final h = await render(
        t,
        data: {
          'agent_task': 'Generate [§output:qna_report:qna_report§]',
          'agent_declared_outputs': [
            {'name': 'qna_report', 'type': 'string', 'required': false, 'description': 'Old report'},
          ],
        },
      );
      await t.enterText(taskEditor(), 'Generate [§output:final_report:final_report§]');
      await settle(t);
      final d = dataOf(h, 'agent-node');
      expect(d['agent_task'], 'Generate [§output:final_report:final_report§]');
      expect(d['agent_declared_outputs'], [
        {'name': 'final_report', 'type': 'string', 'required': false, 'description': 'Old report'},
      ]);
      await expandOutputs(t);
      // The task's output block shows the name too.
      expect(
        find.descendant(of: find.byType(AgentOutputVariables), matching: find.text('final_report')),
        findsOneWidget,
      );
      await h.dispose(t);
    });

    testWidgets('keeps the latest local task draft when outputs change before rerender', (t) async {
      final h = await render(t);
      await t.enterText(taskEditor(), 'Draft before output');
      await expandOutputs(t);
      await addOutput(t, 'summary');
      await t.tap(_byLabel('workflow.nodes.agent.outputVars.confirm'));
      await settle(t);
      final d = dataOf(h, 'agent-node');
      expect(d['agent_task'], 'Draft before output');
      expect(d['agent_declared_outputs'], [
        {'name': 'summary', 'type': 'string', 'required': false},
      ]);
      await h.dispose(t);
    });

    testWidgets('saves agent task to workflow draft node data', (t) async {
      final h = await render(t);
      await t.enterText(taskEditor(), 'Use the previous result');
      await settle(t);
      expect(dataOf(h, 'agent-node')['agent_task'], 'Use the previous result');
      await h.dispose(t);
    });

    testWidgets('removes declared outputs when their prompt output token is deleted', (t) async {
      final h = await render(
        t,
        data: {
          'agent_task': 'Use [§output:summary:summary§] and [§output:manual:manual§]',
          'agent_declared_outputs': [
            {'name': 'summary', 'type': 'string', 'required': false},
            {'name': 'manual', 'type': 'string', 'required': false},
          ],
        },
      );
      await t.enterText(taskEditor(), 'Use [§output:manual:manual§]');
      await settle(t);
      final d = dataOf(h, 'agent-node');
      expect(d['agent_task'], 'Use [§output:manual:manual§]');
      expect(d['agent_declared_outputs'], [
        {'name': 'manual', 'type': 'string', 'required': false},
      ]);
      await h.dispose(t);
    });

    testWidgets('does not remove prompt output tokens when declared outputs are changed from the output list', (
      t,
    ) async {
      final h = await render(
        t,
        data: {
          'agent_task': 'Use [§output:summary:summary§]',
          'agent_declared_outputs': [
            {'name': 'summary', 'type': 'string', 'required': false},
          ],
        },
      );
      await expandOutputs(t);
      await t.tap(_byLabel('workflow.nodes.agent.outputVars.delete:{"name":"summary"}'));
      await settle(t);
      final d = dataOf(h, 'agent-node');
      expect(d['agent_task'], 'Use [§output:summary:summary§]');
      expect(d['agent_declared_outputs'], isEmpty);
      await h.dispose(t);
    });

    testWidgets(
      'renames prompt output tokens when a referenced declared output is renamed from the output list',
      (t) async {
        final h = await render(
          t,
          data: {
            'agent_task': 'Use [§output:summary:summary§] and §output:other:other§',
            'agent_declared_outputs': [
              {'name': 'summary', 'type': 'string', 'required': false},
              {'name': 'other', 'type': 'string', 'required': false},
            ],
          },
        );
        await expandOutputs(t);
        await t.tap(
          find.descendant(
            of: find.byType(AgentOutputVariables),
            matching: _byLabel('workflow.nodes.agent.outputVars.edit:{"name":"summary"}'),
          ),
        );
        await settle(t);
        await t.enterText(
          find.descendant(of: find.byKey(const ValueKey('output-name')), matching: find.byType(TextField)),
          'final_summary',
        );
        await t.pump();
        await t.tap(_byLabel('workflow.nodes.agent.outputVars.confirm'));
        await settle(t);
        final d = dataOf(h, 'agent-node');
        // The panel renames only `summary`; the task editor then shows the new task, and its output blocks write
        // the legacy `other` token in the bracketed form (Dify's editor does the same on value sync; its spec mocks
        // the editor).
        expect(d['agent_task'], 'Use [§output:final_summary:final_summary§] and [§output:other:other§]');
        expect([for (final o in d['agent_declared_outputs']! as List) (o as Map)['name']], ['final_summary', 'other']);
        await h.dispose(t);
      },
    );

    testWidgets('renders declared outputs from workflow draft graph data', (t) async {
      final h = await render(
        t,
        data: {
          'agent_declared_outputs': [
            {'name': 'summary', 'type': 'string', 'description': 'Short summary'},
            {
              'name': 'attachments',
              'type': 'array',
              'description': 'Generated files',
              'array_item': {'type': 'file'},
            },
          ],
        },
      );
      await expandOutputs(t);
      expect(find.text('summary'), findsOneWidget);
      expect(find.text('Short summary'), findsOneWidget);
      expect(find.text('attachments'), findsOneWidget);
      expect(find.text('array[file]'), findsOneWidget);
      expect(find.text('Generated files'), findsOneWidget);
      expect(find.text('workflow.nodes.agent.outputVars.text'), findsOneWidget);
      await h.dispose(t);
    });

    testWidgets('adds custom output %s to workflow draft node data', (t) async {
      for (final name in ['summary', 'files', 'json']) {
        final h = await render(t);
        await expandOutputs(t);
        await addOutput(t, name, description: 'Short summary');
        await t.tap(_byLabel('workflow.nodes.agent.outputVars.confirm'));
        await settle(t);
        expect(dataOf(h, 'agent-node')['agent_declared_outputs'], [
          {'name': name, 'type': 'string', 'required': false, 'description': 'Short summary'},
        ]);
        await h.dispose(t);
      }
    });

    testWidgets('submits the output editor with a scoped Mod+Enter shortcut', (t) async {
      final h = await render(t);
      await expandOutputs(t);
      await addOutput(t, 'summary');
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(t);
      expect(dataOf(h, 'agent-node')['agent_declared_outputs'], isNull);
      await t.tap(find.descendant(of: find.byKey(const ValueKey('output-name')), matching: find.byType(TextField)));
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(t);
      expect(dataOf(h, 'agent-node')['agent_declared_outputs'], [
        {'name': 'summary', 'type': 'string', 'required': false},
      ]);
      await h.dispose(t);
    });

    testWidgets('cancels the output editor with a scoped Escape shortcut', (t) async {
      final h = await render(t);
      await expandOutputs(t);
      await addOutput(t, 'summary');
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t);
      expect(find.bySemanticsLabel('workflow.nodes.agent.outputVars.nameLabel'), findsOneWidget);
      await t.tap(find.descendant(of: find.byKey(const ValueKey('output-name')), matching: find.byType(TextField)));
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t);
      expect(find.bySemanticsLabel('workflow.nodes.agent.outputVars.nameLabel'), findsNothing);
      expect(_byLabel('workflow.nodes.agent.outputVars.newOutput'), findsOneWidget);
      expect(dataOf(h, 'agent-node')['agent_declared_outputs'], isNull);
      await h.dispose(t);
    });

    testWidgets('reveals output editor advanced options with the collapsible trigger', (t) async {
      final h = await render(t);
      await expandOutputs(t);
      await t.tap(_byLabel('workflow.nodes.agent.outputVars.newOutput'));
      await settle(t);
      expect(find.byKey(const ValueKey('output-default')), findsNothing);
      final trigger = _byLabel('workflow.nodes.agent.outputVars.showAdvancedOptions');
      expect(t.getSemantics(trigger).flagsCollection.isExpanded, Tristate.isFalse);
      await t.tap(trigger);
      await settle(t);
      expect(t.getSemantics(trigger).flagsCollection.isExpanded, Tristate.isTrue);
      expect(find.byKey(const ValueKey('output-default')), findsOneWidget);
      await h.dispose(t);
    });

    testWidgets('does not show name validation error before the user enters a name', (t) async {
      final h = await render(t);
      await expandOutputs(t);
      await t.tap(_byLabel('workflow.nodes.agent.outputVars.newOutput'));
      await settle(t);
      expect(find.text('workflow.nodes.agent.outputVars.nameInvalid'), findsNothing);
      final confirm = t.widget<DifyButton>(
        find.byWidgetPredicate((w) => w is DifyButton && w.semanticLabel == 'workflow.nodes.agent.outputVars.confirm'),
      );
      expect(confirm.disabled, isTrue);
      await h.dispose(t);
    });
  });

  group('agent/panel', () {
    test('reconciles inline prompt output renames with the existing declared output row', () {
      final data = _data({
        'agent_task': 'Generate [§output:qna_report:qna_report§]',
        'agent_declared_outputs': [
          {'name': 'qna_report', 'type': 'string', 'required': false, 'description': 'Old report'},
        ],
      });
      final r = agentDeclaredOutputsChange(
        data,
        [
          {'name': 'qna_report', 'type': 'string', 'required': false, 'description': 'Old report'},
          {'name': 'final_report', 'type': 'string', 'required': false},
        ],
        agentTask: 'Generate [§output:final_report:final_report§]',
        promptOutputNames: {'qna_report'},
      );
      expect(r.inputs['agent_task'], 'Generate [§output:final_report:final_report§]');
      expect(r.inputs['agent_declared_outputs'], [
        {'name': 'final_report', 'type': 'string', 'required': false},
      ]);
    });

    AgentOutputBlockConfig outputBlock(WidgetTester t) =>
        t.widget<DifyPromptEditor>(find.byType(DifyPromptEditor)).agentOutputBlock!;
    Finder floatingName() => find.descendant(
      of: find.bySemanticsLabel('workflow.nodes.agent.outputVars.editorLabel'),
      matching: find.descendant(of: find.byKey(const ValueKey('output-name')), matching: find.byType(TextField)),
    );

    testWidgets('opens the output variable editor from an agent task output token hover', (t) async {
      final h = await render(
        t,
        data: {
          'agent_task': 'Generate [§output:summary:summary§]',
          'agent_declared_outputs': [
            {'name': 'summary', 'type': 'string', 'required': false, 'description': 'Short summary'},
          ],
        },
      );
      expect(find.text('workflow.nodes.agent.outputVars.text'), findsNothing);
      // The task's output block (a click on it is the block's onEdit).
      await t.tap(
        find.descendant(
          of: find.byType(DifyPromptEditor),
          matching: _byLabel('workflow.nodes.agent.outputVars.edit:{"name":"summary"}'),
        ),
      );
      await settle(t);
      expect(find.text('workflow.nodes.agent.outputVars.text'), findsOneWidget);
      expect(find.bySemanticsLabel('workflow.nodes.agent.outputVars.editorLabel'), findsOneWidget);
      expect(t.widget<TextField>(floatingName()).controller!.text, 'summary');
      await h.dispose(t);
    });

    testWidgets('expands output variables when an agent task output token changes declared outputs', (t) async {
      final h = await render(t);
      expect(find.text('workflow.nodes.agent.outputVars.text'), findsNothing);
      outputBlock(t).onChange!([
        {'name': 'summary', 'type': 'string', 'required': false},
      ], 'Generate [§output:summary:summary§]');
      await settle(t);
      expect(find.text('workflow.nodes.agent.outputVars.text'), findsOneWidget);
      await h.dispose(t);
    });

    testWidgets('opens the output variable editor for a prompt token missing from declared outputs', (t) async {
      final h = await render(t);
      outputBlock(t).onEdit!('qna_report', 'string');
      await settle(t);
      expect(find.bySemanticsLabel('workflow.nodes.agent.outputVars.editorLabel'), findsOneWidget);
      expect(t.widget<TextField>(floatingName()).controller!.text, 'qna_report');
      await t.tap(
        find.descendant(
          of: find.bySemanticsLabel('workflow.nodes.agent.outputVars.editorLabel'),
          matching: _byLabel('workflow.nodes.agent.outputVars.confirm'),
        ),
      );
      await settle(t);
      final outputs = dataOf(h, 'agent-node')['agent_declared_outputs']! as List;
      expect(outputs.any((o) => (o as Map)['name'] == 'qna_report' && o['type'] == 'string'), isTrue);
      await h.dispose(t);
    });

    testWidgets('renames the current prompt output token instead of creating a separate output', (t) async {
      final h = await render(t, data: {'agent_task': 'Generate [§output:qna_report:qna_report§]'});
      outputBlock(t).onEdit!('qna_report', 'string');
      await settle(t);
      await t.enterText(floatingName(), 'final_report');
      await t.pump();
      await t.tap(
        find.descendant(
          of: find.bySemanticsLabel('workflow.nodes.agent.outputVars.editorLabel'),
          matching: _byLabel('workflow.nodes.agent.outputVars.confirm'),
        ),
      );
      await settle(t);
      final d = dataOf(h, 'agent-node');
      expect(d['agent_task'], 'Generate [§output:final_report:final_report§]');
      final names = [for (final o in d['agent_declared_outputs']! as List) (o as Map)['name']];
      expect(names, contains('final_report'));
      expect(names, isNot(contains('qna_report')));
      expect(find.text('final_report'), findsWidgets);
      await h.dispose(t);
    });

    test('syncs declared outputs created from the agent task editor', () {
      final r = agentDeclaredOutputsChange(
        _data(),
        [
          agentV2SystemTextOutput,
          {'name': 'summary', 'type': 'string', 'required': false},
        ],
        agentTask: 'Use [§output:summary:summary§]',
        promptOutputNames: const {},
      );
      expect(r.inputs['agent_task'], 'Use [§output:summary:summary§]');
      expect(r.inputs['agent_declared_outputs'], [
        {'name': 'summary', 'type': 'string', 'required': false},
      ]);
    });
  });
}
