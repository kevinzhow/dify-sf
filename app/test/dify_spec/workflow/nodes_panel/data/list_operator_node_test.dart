// dify-spec: web/app/components/workflow/nodes/list-operator/__tests__/node.spec.tsx
//
// The card body (cards/bodies/data_bodies.dart). The card writes its label in English ("Input Variable", upper-cased
// by its style) where Dify translates `nodes.listFilter.inputVar`.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/bodies/data_bodies.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

final answer = difyNode('answer-node', {'type': 'answer', 'title': 'Answer', 'answer': ''});
final start = difyNode('start-node', {'type': 'start', 'title': 'Start', 'variables': <Object?>[]});

Node listNode(List<String> variable) => difyNode(
  'list-node',
  {
    'type': 'list-operator',
    'title': 'List Operator',
    'variable': variable,
    'var_type': 'array[string]',
    'item_var_type': 'string',
  },
  others: [answer, start],
);

Future<void> renderListCard(WidgetTester t, Node node) => t.pumpWidget(
  MaterialApp(
    home: Material(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 238,
          child: Builder(
            builder: (c) => const ListOperatorBody().build(
              c,
              BodyContext(node, (id) => {'answer-node': answer, 'start-node': start}[id], start: start),
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  group('list-operator/node', () {
    testWidgets('renders the referenced node variable label', (t) async {
      await renderListCard(t, listNode(const ['answer-node', 'items']));
      expect(find.text('INPUT VARIABLE'), findsOneWidget);
      expect(find.text('Answer'), findsOneWidget);
      expect(find.text('items'), findsOneWidget);
    });

    testWidgets('resolves system variables through the start node', (t) async {
      await renderListCard(t, listNode(const ['sys', 'files']));
      expect(find.text('Start'), findsOneWidget);
      expect(find.text('files'), findsOneWidget);
    });

    testWidgets('returns null when no input variable is configured', (t) async {
      await renderListCard(t, listNode(const []));
      expect(find.byType(Text), findsNothing);
    });
  });
}
