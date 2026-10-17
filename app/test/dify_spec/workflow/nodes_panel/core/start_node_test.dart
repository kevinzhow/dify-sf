// dify-spec: web/app/components/workflow/nodes/start/__tests__/node.spec.tsx
//
// The canvas card is dify-sf's StartBody. Its "required" marker is Dify's `nodes.start.required` text in English
// (the card does not go through the translator), shown upper-cased by `system-2xs-regular-uppercase`.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/bodies/basic_bodies.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Node createNodeData(List<Map<String, Object?>> variables) => difyNodes([
  difyNode('start', 'start', {'variables': variables}, 'Start'),
]).single;

Future<void> renderNode(WidgetTester t, Node node) => t.pumpWidget(
  MaterialApp(
    home: Material(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 242,
          child: Builder(builder: (c) => const StartBody().build(c, BodyContext(node, (_) => null))),
        ),
      ),
    ),
  ),
);

void main() {
  group('StartNode', () {
    group('Rendering', () {
      testWidgets('should render configured input variables and required markers', (t) async {
        await renderNode(
          t,
          createNodeData([
            {'label': 'Question', 'variable': 'query', 'type': 'text-input', 'required': true},
            {'label': 'Count', 'variable': 'count', 'type': 'number', 'required': false},
          ]),
        );
        expect(find.text('query'), findsOneWidget);
        expect(find.text('count'), findsOneWidget);
        expect(find.text('REQUIRED'), findsOneWidget);
      });

      testWidgets('should render nothing when there are no start variables', (t) async {
        await renderNode(t, createNodeData([]));
        expect(find.byType(Text), findsNothing);
        expect(const StartBody().height(BodyContext(createNodeData([]), (_) => null)), 0);
      });
    });
  });
}
