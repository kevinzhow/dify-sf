// dify-spec: web/app/components/workflow/nodes/trigger-webhook/__tests__/node.spec.tsx
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/bodies/entry_bodies.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Node createNodeData([Map<String, Value> overrides = const {}]) => Node(
  id: 'node-1',
  type: 'trigger-webhook',
  title: 'Webhook Trigger',
  config: {
    'desc': const VString(''),
    'method': const VString('POST'),
    'content_type': const VString('application/json'),
    'headers': const VList([]),
    'params': const VList([]),
    'body': const VList([]),
    'async_mode': const VBool(false),
    'status_code': const VInt(200),
    'response_body': const VString(''),
    'variables': const VList([]),
    ...overrides,
  },
);

Future<void> renderNode(WidgetTester t, Node node) => t.pumpWidget(
  MaterialApp(
    home: Material(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 240,
          child: Builder(builder: (c) => const TriggerWebhookBody().build(c, BodyContext(node, (_) => null))),
        ),
      ),
    ),
  ),
);

void main() {
  group('TriggerWebhookNode', () {
    group('Rendering', () {
      testWidgets('should render the webhook url when it exists', (t) async {
        await renderNode(t, createNodeData({'webhook_url': const VString('https://example.com/webhook')}));

        expect(find.text('URL'), findsOneWidget);
        expect(find.text('https://example.com/webhook'), findsOneWidget);
      });

      testWidgets('should render the placeholder when the webhook url is empty', (t) async {
        await renderNode(t, createNodeData({'webhook_url': const VString('')}));

        expect(find.text('--'), findsOneWidget);
      });
    });
  });
}
