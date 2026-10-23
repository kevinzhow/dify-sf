// dify-spec: web/app/components/workflow/block-selector/tool/tool-list-tree-view/__tests__/list.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/tools_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUpBlockSelectorTests();

  group('ToolListTreeView', () {
    testWidgets('renders author names and translates category groups', (t) async {
      await pumpSelector(
        t,
        SizedBox(
          width: 400,
          child: ToolsList(
            viewType: ViewType.tree,
            onSelect: (_, [_]) {},
            tools: [
              toolProvider(author: 'BuiltIn', label: 'Built In Provider'),
              toolProvider(id: 'custom-provider', type: CollectionType.custom, label: 'Custom Provider'),
              toolProvider(id: 'mcp-provider', type: CollectionType.mcp, label: 'MCP Provider'),
              toolProvider(id: 'workflow-provider', type: CollectionType.workflow, label: 'Workflow Provider'),
              toolProvider(id: 'data-source-provider', type: 'local_file', label: 'Data Source Provider'),
            ],
          ),
        ),
      );
      expect(find.text('BuiltIn'), findsOneWidget);
      expect(find.text('workflow.tabs.customTool'), findsOneWidget);
      expect(find.text('MCP'), findsOneWidget);
      expect(find.text('workflow.tabs.workflowTool'), findsOneWidget);
      expect(find.text('workflow.tabs.sources'), findsOneWidget);
      expect(find.text('Built In Provider'), findsOneWidget);
      expect(find.text('Custom Provider'), findsOneWidget);
      expect(find.text('MCP Provider'), findsOneWidget);
    });
  });
}
