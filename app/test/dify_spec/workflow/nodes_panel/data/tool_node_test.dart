// dify-spec: web/app/components/workflow/nodes/tool/__tests__/node.spec.tsx
//
// The canvas card (cards/bodies/data_bodies.dart ToolBody). The authorization warning needs the provider's
// collection, which the canvas does not have (see not_applicable.tsv).
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/bodies/data_bodies.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Node createNodeData({Map<String, Value> configs = const {}}) => Node(
  id: 'tool-node-1',
  type: 'tool',
  title: 'Google Search',
  config: {
    'provider_id': const VString('google_search'),
    'provider_type': const VString('builtin'),
    'tool_name': const VString('google_search'),
    'tool_parameters': const VMap({}),
    'tool_configurations': VMap(configs),
  },
);

Future<void> render(WidgetTester t, Node node) => t.pumpWidget(
  MaterialApp(
    home: Material(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 238,
          child: Builder(builder: (c) => const ToolBody().build(c, BodyContext(node, (_) => null))),
        ),
      ),
    ),
  ),
);

void main() {
  group('ToolNode', () {
    group('Authorization Warning', () {
      testWidgets('should render nothing when there are no configs, no install action and no authorization warning', (
        t,
      ) async {
        await render(t, createNodeData());
        expect(find.byType(ParamRow), findsNothing);
        expect(find.byType(Text), findsNothing);
      });
    });

    testWidgets('should render multi-select configuration values', (t) async {
      await render(
        t,
        createNodeData(
          configs: {
            'formats': const VMap({
              'type': VString('constant'),
              'value': VList([VString('png'), VString('svg')]),
            }),
          },
        ),
      );
      expect(find.text('png, svg'), findsOneWidget);
      expect(find.text('FORMATS'), findsOneWidget);
    });
  });
}
