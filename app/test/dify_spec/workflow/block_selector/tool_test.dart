// dify-spec: web/app/components/workflow/block-selector/tool/__tests__/tool.spec.tsx
import 'dart:ui' show Tristate;

import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/tools_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Widget _row(ToolProvider p, SelectRecorder rec, {void Function(String, List<Map<String, Object?>>)? multiple}) =>
    SizedBox(
      width: 400,
      child: ToolProviderRow(
        provider: p,
        viewType: ViewType.flat,
        hasSearchText: false,
        onSelect: rec.call,
        onSelectMultiple: multiple,
      ),
    );

Tristate _expanded(WidgetTester t, String label) =>
    t.getSemantics(find.bySemanticsLabel(label)).getSemanticsData().flagsCollection.isExpanded;

void main() {
  setUpBlockSelectorTests();

  group('Tool', () {
    testWidgets('keeps provider disclosures independently expanded', (t) async {
      final semantics = t.ensureSemantics();
      await pumpSelector(
        t,
        Column(
          children: [
            _row(toolProvider(), SelectRecorder()),
            _row(
              toolProvider(
                id: 'provider-2',
                name: 'provider-two',
                label: 'Provider Two',
                tools: [toolJson('tool-b', 'Tool B')],
              ),
              SelectRecorder(),
            ),
          ],
        ),
      );
      expect(_expanded(t, 'Provider One'), Tristate.isFalse);
      expect(_expanded(t, 'Provider Two'), Tristate.isFalse);

      await tapText(t, 'Provider One');
      await tapText(t, 'Provider Two');
      expect(_expanded(t, 'Provider One'), Tristate.isTrue);
      expect(_expanded(t, 'Provider Two'), Tristate.isTrue);
      expect(find.bySemanticsLabel('Tool A'), findsOneWidget);
      expect(find.bySemanticsLabel('Tool B'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('orders the provider, add-all, and action buttons without collapsing on add-all', (t) async {
      final multiple = <(String, List<Map<String, Object?>>)>[];
      await pumpSelector(
        t,
        _row(
          toolProvider(tools: [toolJson('tool-a', 'Tool A'), toolJson('tool-b', 'Tool B')]),
          SelectRecorder(),
          multiple: (type, tools) => multiple.add((type, tools)),
        ),
      );
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(t);
      expect(find.text('Tool A'), findsOneWidget);

      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await settle(t);
      final addAll = find.byWidgetPredicate(
        (w) => w is DifyButton && (w.child as DifyTextLine).data == 'workflow.tabs.addAll',
      );
      expect(hasFocusOn(t, addAll), isTrue);

      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(t);
      expect(find.text('Tool A'), findsOneWidget, reason: 'still expanded');
      expect(multiple.single.$1, 'tool');
      expect([for (final x in multiple.single.$2) x['tool_name']], ['tool-a', 'tool-b']);

      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(hasFocusOn(t, find.text('Tool A')), isTrue);
    });

    testWidgets('selects an expanded action item', (t) async {
      final rec = SelectRecorder();
      await pumpSelector(
        t,
        _row(toolProvider(tools: [toolJson('tool-a', 'Tool A'), toolJson('tool-b', 'Tool B')]), rec),
      );
      await tapText(t, 'Provider One');
      await tapText(t, 'Tool B');
      final (type, value) = rec.calls.single;
      expect(type, 'tool');
      expect(value, containsPair('provider_id', 'provider-1'));
      expect(value, containsPair('provider_name', 'provider-one'));
      expect(value, containsPair('tool_name', 'tool-b'));
      expect(value, containsPair('title', 'Tool B'));
    });

    testWidgets('selects workflow tools directly without expanding the provider', (t) async {
      final rec = SelectRecorder();
      await pumpSelector(
        t,
        _row(toolProvider(type: CollectionType.workflow, tools: [toolJson('workflow-tool', 'Workflow Tool')]), rec),
      );
      await tapText(t, 'Workflow Tool');
      expect(rec.calls.single.$2, containsPair('provider_type', 'workflow'));
      expect(rec.calls.single.$2, containsPair('tool_name', 'workflow-tool'));
      expect(rec.calls.single.$2, containsPair('tool_label', 'Workflow Tool'));
    });
  });
}
