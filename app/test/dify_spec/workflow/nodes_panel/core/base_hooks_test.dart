// dify-spec: web/app/components/workflow/nodes/_base/components/__tests__/code-generator-button.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/hooks/__tests__/use-node-crud.spec.ts
//
// CodeGenerateBtn is the code panel's generator slot (CorePanelHostData.codeGenerator; GeneratorButton named
// "Automatic"); useNodeCrud's setInputs is panel_edit.dart's setInputs, which writes the node's data in the document.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/core_kit.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/panel_edit.dart' as edit;
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'code_harness.dart';

void main() {
  group('CodeGenerateBtn', () {
    testWidgets('should open the code generator from the named action', (t) async {
      final p = await openCodePanel(
        t,
        difyNodes([
          difyNode('node-1', 'code', {'code_language': 'python3', 'code': '', 'variables': <Object?>[]}),
        ]),
        'node-1',
        host: (p) => CorePanelHostData(
          codeGenerator: (context, nodeId, language, onGenerated) => GeneratorButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => Semantics(
                label: 'code generator',
                child: const Dialog(child: Text('generator')),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.bySemanticsLabel('app-debug.operation.automatic'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('generator'), findsOneWidget);
      await p.dispose(t);
    });
  });

  group('useNodeCrud', () {
    testWidgets('forwards node data updates with the current node id and latest updater', (t) async {
      final h = await Harness.start(
        t,
        difyNodes([
          difyNode('node-1', 'llm', {'value': 'initial'}, 'Test Node'),
        ]),
      );
      final actions = panelActions(h);
      NodePanelProps props() => NodePanelProps(node: h['node-1']!, controller: h.controller, actions: actions);
      edit.setInputs(props(), {...props().data, 'value': 'changed'});
      await t.pump();
      expect(difyDataOf(h['node-1']!)['value'], 'changed');
      // The node changed: the next write goes to the same node, from its latest data.
      edit.setInputs(props(), {...props().data, 'value': 'latest'});
      await t.pump();
      expect(difyDataOf(h['node-1']!)['value'], 'latest');
      expect(difyDataOf(h['node-1']!)['title'], 'Test Node');
      await h.dispose(t);
    });
  });
}
