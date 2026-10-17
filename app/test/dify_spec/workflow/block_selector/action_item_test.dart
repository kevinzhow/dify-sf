// dify-spec: web/app/components/workflow/block-selector/tool/__tests__/action-item.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/tools_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUpBlockSelectorTests();

  group('ToolActionItem', () {
    testWidgets('should select tools with default params and track the selection', (t) async {
      final semantics = t.ensureSemantics();
      final rec = SelectRecorder();
      await pumpSelector(
        t,
        SizedBox(
          width: 400,
          child: ToolActionItem(
            provider: toolProvider(),
            action: ToolAction.fromJson(toolJson('search', 'Search Tool')),
            onSelect: rec.call,
          ),
        ),
      );
      expect(t.getSemantics(find.bySemanticsLabel('Search Tool')).getSemanticsData().hint, 'Search Tool description');
      await tapText(t, 'Search Tool');
      final (type, value) = rec.calls.single;
      expect(type, 'tool');
      expect(value, containsPair('provider_id', 'provider-1'));
      expect(value, containsPair('tool_name', 'search'));
      expect(value, containsPair('tool_label', 'Search Tool'));
      expect(value!['params'], <String, Object?>{});
      semantics.dispose();
    });

    testWidgets('should not select disabled tools and should show added state', (t) async {
      final rec = SelectRecorder();
      await pumpSelector(
        t,
        SizedBox(
          width: 400,
          child: ToolActionItem(
            provider: toolProvider(),
            action: ToolAction.fromJson(toolJson('search', 'Search Tool')),
            onSelect: rec.call,
            disabled: true,
            isAdded: true,
          ),
        ),
      );
      expect(find.text('tools.addToolModal.added'), findsOneWidget);
      await tapText(t, 'Search Tool');
      expect(rec.calls, isEmpty);
    });
  });
}
