// dify-spec: web/app/components/workflow/block-selector/__tests__/tools.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/tools_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Widget _tools(List<ToolProvider> tools, ViewType view) => SizedBox(
  width: 400,
  child: ToolsList(tools: tools, onSelect: (_, [_]) {}, viewType: view),
);

void main() {
  setUpBlockSelectorTests();

  group('Tools', () {
    testWidgets('shows the empty state when there are no tools and no search text', (t) async {
      await pumpSelector(t, _tools(const [], ViewType.flat));
      expect(find.text('No tools available'), findsOneWidget);
    });

    testWidgets('renders tree groups for built-in and custom providers', (t) async {
      await pumpSelector(
        t,
        _tools([
          toolProvider(id: 'built-in-provider', author: 'Built In', label: 'Built In Provider'),
          toolProvider(id: 'custom-provider', type: CollectionType.custom, label: 'Custom Provider'),
        ], ViewType.tree),
      );
      expect(find.text('Built In'), findsOneWidget);
      expect(find.text('workflow.tabs.customTool'), findsOneWidget);
      expect(find.text('Built In Provider'), findsOneWidget);
      expect(find.text('Custom Provider'), findsOneWidget);
    });

    testWidgets('shows the alphabetical index in flat view when enough tools are present', (t) async {
      await pumpSelector(
        t,
        SizedBox(
          height: 900,
          child: SingleChildScrollView(
            child: _tools([
              for (var i = 0; i < 11; i++)
                toolProvider(id: 'provider-$i', label: '${String.fromCharCode(65 + i)} Provider'),
            ], ViewType.flat),
          ),
        ),
      );
      expect(find.byType(IndexBar), findsOneWidget);
      expect(find.descendant(of: find.byType(IndexBar), matching: find.text('A')), findsOneWidget);
      expect(find.descendant(of: find.byType(IndexBar), matching: find.text('K')), findsOneWidget);
      expect(find.text('A Provider'), findsOneWidget);
      expect(find.text('K Provider'), findsOneWidget);
    });
  });
}
