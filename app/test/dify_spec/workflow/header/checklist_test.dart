// dify-spec: web/app/components/workflow/header/checklist/__tests__/index.spec.tsx
// dify-spec: web/app/components/workflow/header/checklist/__tests__/node-group.spec.tsx
// dify-spec: web/app/components/workflow/header/checklist/__tests__/plugin-group.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/header/checklist/checklist.dart';
import 'package:dify_sf_app/src/workflow_editor/header/checklist/checklist_item.dart';
import 'package:dify_sf_app/src/workflow_editor/header/header_data.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _plugin = ChecklistItem(
  id: 'plugin-1',
  type: 'tool',
  title: 'Missing Plugin',
  canNavigate: false,
  isPluginMissing: true,
);
const _broken = ChecklistItem(
  id: 'node-1',
  type: 'llm',
  title: 'Broken Node',
  errorMessages: ['Needs configuration'],
  canNavigate: true,
);

void main() {
  group('WorkflowChecklist', () {
    late List<String> selected;
    WorkflowHeaderData data() {
      selected = [];
      return WorkflowHeaderData(handleNodeSelect: (id, {cancelSelection = false}) => selected.add(id));
    }

    testWidgets(
      'should split checklist items into plugin and node groups and delegate clicks to node selection by default',
      (t) async {
        final s = await renderWorkflowComponent(
          t,
          const WorkflowChecklist(disabled: false, items: [_plugin, _broken]),
          data: data(),
        );
        expect(find.text('2'), findsOneWidget);
        await t.tap(find.bySemanticsLabel('workflow.panel.checklist'));
        await settle(t);
        expect(find.byType(ChecklistPluginGroup), findsOneWidget);
        expect(find.text('Missing Plugin'), findsOneWidget);
        await t.tap(find.text('Needs configuration'));
        expect(selected, ['node-1']);
        expect(s.openInlineAgentPanelNodeId.value, isNull);
      },
    );

    testWidgets('should use the custom item click handler when provided', (t) async {
      final clicked = <ChecklistItem>[];
      await renderWorkflowComponent(
        t,
        WorkflowChecklist(disabled: false, items: const [_plugin, _broken], onItemClick: clicked.add),
        data: data(),
      );
      await t.tap(find.bySemanticsLabel('workflow.panel.checklist'));
      await settle(t);
      await t.tap(find.text('Needs configuration'));
      expect(clicked.single.id, 'node-1');
      expect(selected, isEmpty);
    });

    testWidgets('should open the inline agent editor after selecting an inline agent reference warning', (t) async {
      final inline = _broken.copyWith(type: 'agent-v2', title: 'Inline Agent', openInlineAgentPanel: true);
      final s = await renderWorkflowComponent(
        t,
        WorkflowChecklist(disabled: false, items: [_plugin, inline]),
        data: data(),
      );
      await t.tap(find.bySemanticsLabel('workflow.panel.checklist'));
      await settle(t);
      await t.tap(find.text('Needs configuration'));
      expect(selected, ['node-1']);
      expect(s.openInlineAgentPanelNodeId.value, 'node-1');
    });

    testWidgets('should render the resolved state when there are no checklist warnings', (t) async {
      await renderWorkflowComponent(t, const WorkflowChecklist(disabled: false, items: []), data: data());
      await t.tap(find.bySemanticsLabel('workflow.panel.checklist'));
      await settle(t);
      expect(find.text('workflow.panel.checklistResolved'), findsOneWidget);
    });

    testWidgets('should ignore popover open changes when the checklist is disabled', (t) async {
      await renderWorkflowComponent(
        t,
        const WorkflowChecklist(disabled: true, items: [_plugin, _broken]),
        data: data(),
      );
      expect(find.text('2'), findsOneWidget);
      expect(isEnabled(t, 'workflow.panel.checklist'), isFalse);
      await t.tap(find.text('2'), warnIfMissed: false);
      await settle(t);
      expect(find.text('workflow.panel.checklistDescription'), findsNothing);
    });
  });

  group('ChecklistNodeGroup', () {
    testWidgets('should render errors and the connection warning, and allow navigation when go-to is enabled', (
      t,
    ) async {
      final clicked = <ChecklistItem>[];
      await renderWorkflowComponent(
        t,
        SizedBox(
          width: 400,
          child: ChecklistNodeGroup(
            item: const ChecklistItem(
              id: 'node-1',
              type: 'llm',
              title: 'Broken Node',
              errorMessages: ['Needs configuration'],
              canNavigate: true,
              unConnected: true,
            ),
            showGoTo: true,
            onItemClick: clicked.add,
          ),
        ),
      );
      expect(find.text('Needs configuration'), findsOneWidget);
      expect(find.text('workflow.common.needConnectTip'), findsOneWidget);
      expect(find.text('workflow.panel.goToFix'), findsNWidgets(2));
      expect(isButton(t, find.text('Needs configuration')), isTrue);
      await t.tap(find.text('Needs configuration'));
      expect(clicked.single.id, 'node-1');
    });

    testWidgets('should not allow navigation when go-to is disabled', (t) async {
      final clicked = <ChecklistItem>[];
      await renderWorkflowComponent(
        t,
        SizedBox(
          width: 400,
          child: ChecklistNodeGroup(
            item: const ChecklistItem(
              id: 'node-1',
              type: 'llm',
              title: 'Broken Node',
              errorMessages: ['Needs configuration'],
              canNavigate: true,
              disableGoTo: true,
            ),
            showGoTo: true,
            onItemClick: clicked.add,
          ),
        ),
      );
      await t.tap(find.text('Needs configuration'));
      expect(clicked, isEmpty);
      expect(find.text('workflow.panel.goToFix'), findsNothing);
      expect(isButton(t, find.text('Needs configuration')), isFalse);
    });
  });

  group('ChecklistPluginGroup', () {
    ChecklistItem item(String id, String? identifier) => ChecklistItem(
      id: id,
      type: 'tool',
      title: 'Tool Node',
      canNavigate: false,
      isPluginMissing: true,
      pluginUniqueIdentifier: identifier,
    );
    late PluginDependencyStore store;
    Future<void> render(WidgetTester t, List<ChecklistItem> items) async {
      store = PluginDependencyStore();
      addTearDown(store.dispose);
      await renderWorkflowComponent(
        t,
        SizedBox(
          width: 800,
          child: ChecklistPluginGroup(items: items, dependencies: store),
        ),
      );
    }

    testWidgets('should set marketplace dependencies when install button is clicked', (t) async {
      await render(t, [
        item('node-1', 'langgenius/test-plugin:1.0.0@sha256'),
        item('node-2', 'langgenius/test-plugin:1.0.0@sha256'),
        item('node-3', 'langgenius/another-plugin:2.0.0@sha256'),
      ]);
      await t.tap(find.text('workflow.nodes.agent.pluginInstaller.install'));
      expect(store.dependencies.value, [
        {
          'type': 'marketplace',
          'value': {
            'marketplace_plugin_unique_identifier': 'langgenius/test-plugin:1.0.0@sha256',
            'plugin_unique_identifier': 'langgenius/test-plugin:1.0.0@sha256',
            'version': '1.0.0',
          },
        },
        {
          'type': 'marketplace',
          'value': {
            'marketplace_plugin_unique_identifier': 'langgenius/another-plugin:2.0.0@sha256',
            'plugin_unique_identifier': 'langgenius/another-plugin:2.0.0@sha256',
            'version': '2.0.0',
          },
        },
      ]);
    });

    testWidgets('should keep install button disabled when no identifier is available', (t) async {
      await render(t, [item('node-1', null)]);
      expect(isEnabled(t, 'workflow.nodes.agent.pluginInstaller.install'), isFalse);
      await t.tap(find.text('workflow.nodes.agent.pluginInstaller.install'), warnIfMissed: false);
      expect(store.dependencies.value, isEmpty);
    });

    testWidgets('should omit the version when the marketplace identifier does not include one', (t) async {
      await render(t, [item('node-1', 'langgenius/test-plugin@sha256')]);
      await t.tap(find.text('workflow.nodes.agent.pluginInstaller.install'));
      expect(store.dependencies.value, [
        {
          'type': 'marketplace',
          'value': {
            'marketplace_plugin_unique_identifier': 'langgenius/test-plugin@sha256',
            'plugin_unique_identifier': 'langgenius/test-plugin@sha256',
            'version': null,
          },
        },
      ]);
    });
  });
}
