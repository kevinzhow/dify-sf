// dify-spec: web/app/components/workflow/nodes/end/__tests__/panel.spec.tsx
// dify-spec: web/app/components/workflow/nodes/end/__tests__/use-config.spec.ts
//
// The panel over a document in an in-memory session: what Dify's mocked use-config would be called with is read back
// from the document.
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

final _end = difyNode('end-node', 'end', {'outputs': <Object?>[]}, 'End');

void main() {
  group('EndPanel', () {
    testWidgets('should show the output field and allow adding output variables when writable', (t) async {
      final p = await openCorePanel(t, difyNodes([_end]), 'end-node');
      expect(findTitle('workflow.nodes.end.output.variable'), findsOneWidget);
      await t.tap(buttonNamed('common.operation.add workflow.nodes.end.output.variable'));
      await settle(t);
      expect(p.data['outputs'], [
        {'variable': '', 'value_selector': <Object?>[]},
      ]);
      await p.dispose(t);
    });

    testWidgets('should hide the add action when the node is read-only', (t) async {
      final p = await openCorePanel(t, difyNodes([_end]), 'end-node', readOnly: true);
      expect(buttonNamed('common.operation.add workflow.nodes.end.output.variable'), findsNothing);
      await p.dispose(t);
    });
  });

  group('end/use-config', () {
    testWidgets('should build var-list handlers against outputs and surface the readonly state', (t) async {
      final nodes = difyNodes([
        difyNode('start', 'start', {
          'variables': [
            {'variable': 'query', 'type': 'text-input', 'label': 'Query', 'required': true},
          ],
        }),
        _end,
      ]);
      final p = await openCorePanel(t, nodes, 'end-node', edges: chain(['start', 'end-node']));
      await t.tap(buttonNamed('common.operation.add workflow.nodes.end.output.variable'));
      await settle(t);
      // The row's picker lists the upstream Start variable; choosing it names the row after it.
      await t.tap(find.text('workflow.common.setVarValuePlaceholder'));
      await settle(t);
      await t.tap(find.text('query').last);
      await settle(t);
      expect(p.data['outputs'], [
        {
          'variable': 'query',
          'value_selector': ['start', 'query'],
          'value_type': 'string',
        },
      ]);
      expect(p.node.config['outputs'].toString(), contains('{{start.query}}'));
      await p.dispose(t);
    });
  });
}
