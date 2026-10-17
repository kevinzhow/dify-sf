// dify-spec: web/app/components/workflow/nodes/agent-v2/__tests__/default.spec.ts
// dify-spec: web/app/components/workflow/nodes/agent-v2/__tests__/hooks.spec.tsx
// dify-spec: web/app/components/workflow/nodes/agent-v2/components/__tests__/agent-roster-field.spec.tsx
// dify-spec: web/app/components/workflow/nodes/agent-v2/components/__tests__/edit-in-console-link.spec.tsx
// dify-spec: web/app/components/workflow/nodes/agent-v2/components/__tests__/save-inline-agent-to-roster-dialog.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/agent_v2_logic.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/agent_v2_roster.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/llm_bodies.dart' show isAgentV2NodeData;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../dify_test_i18n.dart';

/// default.spec's `t`: `required:<field>` and `Agent` for the roster label.
String _t(String ns, String key, [Map<String, Object?> params = const {}]) => switch (key) {
  'errorMsg.fieldRequired' => 'required:${params['field']}',
  'nodes.agent.roster.label' => 'Agent',
  _ => key,
};

Map<String, Object?> _payload([Map<String, Object?> overrides = const {}]) => {
  'title': 'Agent',
  'desc': '',
  'type': 'agent-v2',
  'agent_binding': {'binding_type': 'roster_agent', 'agent_id': 'agent-1'},
  'agent_node_kind': 'dify_agent',
  'version': '2',
  ...overrides,
};

Widget _app(Widget child) => MaterialApp(
  home: Material(
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 400, child: child),
    ),
  ),
);

const _inlineAgent = {
  'active_config_snapshot_id': 'snapshot-1',
  'description': 'Drafts tender clarifications.',
  'icon': '🤖',
  'icon_background': '#F5F3FF',
  'icon_type': 'emoji',
  'id': 'inline-agent-1',
  'name': 'Inline Tender Agent',
  'role': 'Tender Analyst',
};

void main() {
  setUp(useDifyTestTranslator);

  group('agent/default', () {
    test('requires a roster agent id', () {
      final r = checkValidAgentV2(
        _payload({
          'agent_binding': {'binding_type': 'roster_agent', 'agent_id': ''},
        }),
        _t,
      );
      expect(r, (isValid: false, errorMessage: 'required:Agent'));
    });

    test('requires a roster agent binding', () {
      expect(checkValidAgentV2(_payload({'agent_binding': null}), _t), (
        isValid: false,
        errorMessage: 'required:Agent',
      ));
    });

    test('passes validation when a roster agent binding is selected', () {
      expect(checkValidAgentV2(_payload(), _t), (isValid: true, errorMessage: ''));
    });

    test('requires complete inline agent binding', () {
      final r = checkValidAgentV2(
        _payload({
          'agent_binding': {'binding_type': 'inline_agent'},
        }),
        _t,
      );
      expect(r, (isValid: false, errorMessage: 'required:Agent'));
    });

    test('passes validation for complete inline agent binding', () {
      final r = checkValidAgentV2(
        _payload({
          'agent_binding': {
            'binding_type': 'inline_agent',
            'agent_id': 'inline-agent-1',
            'current_snapshot_id': 'inline-snapshot-1',
          },
        }),
        _t,
      );
      expect(r, (isValid: true, errorMessage: ''));
    });

    test('creates Agent v2 graph data by default', () {
      expect(agentV2DefaultValue, {
        'agent_binding': {'binding_type': 'inline_agent'},
        'agent_node_kind': 'dify_agent',
        'version': '2',
      });
    });

    test('links directly to the New Agent section of the shared agent node document', () {
      expect(agentV2HelpLinkUri, 'agent#new-agent');
    });

    test('identifies version 2 agent data as Agent v2', () {
      expect(isAgentV2NodeData(_payload({'type': 'agent'})), isTrue);
      expect(isAgentV2NodeData({'title': 'Agent', 'desc': '', 'type': 'agent', 'version': '2'}), isFalse);
    });
  });

  group('useWorkflowInlineAgentDetail', () {
    testWidgets('polls until a copied inline agent composer is created for the new node', (t) async {
      var calls = 0;
      final q = InlineAgentQuery(
        fetch: () async {
          calls++;
          return calls == 1
              ? {'agent': null}
              : {
                  'agent': {'id': 'app-agent'},
                };
        },
        onChange: () {},
      )..pollUntilReady = true;
      await q.refetch();
      await t.pump(const Duration(milliseconds: 1100));
      await t.pump();
      expect(calls, 2);
      expect(q.data, {
        'agent': {'id': 'app-agent'},
      });
      // Ready: no further polling.
      await t.pump(const Duration(milliseconds: 1500));
      expect(calls, 2);
      q.dispose();
    });

    testWidgets('retries five times and stops polling when loading the copied inline agent composer fails', (
      t,
    ) async {
      var calls = 0;
      final q = InlineAgentQuery(
        fetch: () async {
          calls++;
          throw Exception('Agent composer was not created');
        },
        onChange: () {},
      )..pollUntilReady = true;
      await q.refetch();
      await t.pump(const Duration(milliseconds: 1200));
      expect(q.isError, isTrue);
      expect(calls, 6);
      q.dispose();
    });
  });

  group('AgentRosterField', () {
    Future<List<String>> renderDetail(WidgetTester t, [List<String> permissionKeys = const ['agent.acl.edit']]) async {
      final urls = <String>[];
      await t.pumpWidget(
        _app(
          AgentRosterField(
            agent: {
              'id': 'roster-agent-1',
              'name': 'Roster Agent',
              'permission_keys': permissionKeys,
              'role': 'Shared roster agent',
            },
            onChange: (_) {},
            onMakeCopy: () {},
            onOpenUrl: urls.add,
          ),
        ),
      );
      await t.pumpAndSettle();
      return urls;
    }

    testWidgets('shows Make Copy in the roster detail panel', (t) async {
      await renderDetail(t);
      await t.tap(find.bySemanticsLabel(RegExp(r'^workflow\.nodes\.agent\.roster\.openPanel')));
      await t.pumpAndSettle();
      expect(find.text('workflow.nodes.agent.roster.makeCopy'), findsOneWidget);
    });

    testWidgets('does not offer editing for a preview-only Agent', (t) async {
      await renderDetail(t, ['agent.acl.preview']);
      await t.tap(find.bySemanticsLabel(RegExp(r'^workflow\.nodes\.agent\.roster\.openPanel')));
      await t.pumpAndSettle();
      expect(find.text('workflow.nodes.agent.roster.editInConsole'), findsNothing);
      expect(find.text('workflow.nodes.agent.roster.makeCopy'), findsOneWidget);
    });

    testWidgets('returns focus to the inline setup trigger when the dialog closes with Escape', (t) async {
      await t.pumpWidget(
        _app(
          AgentRosterField(
            agent: const {'id': 'inline-agent-1', 'name': 'Inline Workspace', 'role': 'Workflow-only agent'},
            isInlineSetup: true,
            panelBody: (_) => TextButton(onPressed: () {}, child: const Text('Inline workspace action')),
            onChange: (_) {},
          ),
        ),
      );
      await t.pumpAndSettle();
      final trigger = find.bySemanticsLabel(RegExp(r'^workflow\.nodes\.agent\.roster\.openPanel'));
      await t.tap(trigger);
      await t.pumpAndSettle();
      expect(find.bySemanticsLabel('Inline Workspace'), findsOneWidget);
      expect(find.text('Inline workspace action'), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('Inline workspace action'), findsNothing);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'agent roster trigger');
    });
  });

  group('EditInConsoleLink', () {
    testWidgets('renders a link to the agent console without a workspace preview gate', (t) async {
      final urls = <String>[];
      await t.pumpWidget(_app(EditInConsoleLink(agentId: 'agent-1', onOpenUrl: urls.add)));
      expect(const EditInConsoleLink(agentId: 'agent-1', onOpenUrl: print).href, '/agents/agent-1/configure');
      final node = t.getSemantics(find.byType(EditInConsoleLink));
      expect(node.flagsCollection.isLink, isTrue);
      await t.tap(find.text('workflow.nodes.agent.roster.editInConsole'));
      expect(urls, ['/agents/agent-1/configure']);
    });
  });

  group('SaveInlineAgentToRosterDialog', () {
    Future<({List<Map<String, Object?>> bodies, List<String> saved})> renderDialog(
      WidgetTester t, [
      Map<String, Object?> agent = _inlineAgent,
    ]) async {
      final bodies = <Map<String, Object?>>[];
      final saved = <String>[];
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSaveInlineAgentToRosterDialog(
                context,
                initialAgent: agent,
                save: (body) async {
                  bodies.add(body);
                  return 'roster-agent-1';
                },
                onSaved: saved.add,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      return (bodies: bodies, saved: saved);
    }

    Future<void> typeName(WidgetTester t, String name) async {
      await t.enterText(
        find.descendant(of: find.byKey(const ValueKey('roster-name')), matching: find.byType(EditableText)),
        name,
      );
      await t.pump();
    }

    testWidgets('initializes the roster name empty while keeping the other inline agent metadata', (t) async {
      final r = await renderDialog(t);
      expect(find.bySemanticsLabel('agent-v-2.roster.saveToRosterDialog.title'), findsWidgets);
      EditableText field(String key) => t.widget<EditableText>(
        find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(EditableText)),
      );
      expect(field('roster-name').controller.text, '');
      expect(field('roster-role').controller.text, 'Tender Analyst');
      expect(field('roster-description').controller.text, 'Drafts tender clarifications.');
      await typeName(t, 'Roster Tender Agent');
      await t.tap(find.text('common.operation.save'));
      await t.pumpAndSettle();
      expect(r.bodies.single, {
        'variant': 'workflow',
        'save_strategy': 'save_to_roster',
        'new_agent_name': 'Roster Tender Agent',
        'description': 'Drafts tender clarifications.',
        'role': 'Tender Analyst',
        'icon_type': 'emoji',
        'icon': '🤖',
        'icon_background': '#F5F3FF',
      });
    });

    testWidgets('submits the visible default icon when the inline agent has no icon metadata', (t) async {
      final r = await renderDialog(t, {..._inlineAgent, 'icon': null, 'icon_background': null, 'icon_type': null});
      expect(find.text('🧸'), findsOneWidget);
      await typeName(t, 'Roster Tender Agent');
      await t.tap(find.text('common.operation.save'));
      await t.pumpAndSettle();
      expect(r.bodies.single, containsPair('icon', '🧸'));
      expect(r.bodies.single, containsPair('icon_background', '#F5F3FF'));
      expect(r.bodies.single, containsPair('icon_type', 'emoji'));
    });

    testWidgets('returns only the saved roster agent id after a successful save', (t) async {
      final r = await renderDialog(t);
      await typeName(t, 'Roster Tender Agent');
      await t.tap(find.text('common.operation.save'));
      await t.pumpAndSettle();
      expect(r.saved, ['roster-agent-1']);
      expect(find.bySemanticsLabel('agent-v-2.roster.saveToRosterDialog.title'), findsNothing);
    });
  });
}
