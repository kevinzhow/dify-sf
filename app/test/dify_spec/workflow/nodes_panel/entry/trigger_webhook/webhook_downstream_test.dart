// Not a Dify spec: the panel's variable sync clears downstream uses through the document.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_webhook/webhook_default.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUp(useDifyTestTranslator);

  testWidgets('changing the content type clears the body variables used downstream', (t) async {
    final h = await startWebhook(
      t,
      {
        ...triggerWebhookDefaultValue(),
        'webhook_url': 'https://hook',
        'body': [
          {'name': 'payload', 'type': 'string', 'required': true},
        ],
        'variables': [
          createWebhookRawVariable(),
          {'variable': 'payload', 'label': 'body', 'value_type': 'string', 'value_selector': [], 'required': true},
        ],
      },
      others: [
        node(
          'end',
          type: 'end',
          config: {
            'outputs': Value.of([
              {
                'variable': 'out',
                'value_selector': ['n', 'payload'],
              },
            ]),
          },
        ),
      ],
    );
    await t.pumpWidget(webhookPanel(h));
    await settle(t);

    await t.tap(find.text('application/json'));
    await settle(t);
    await t.tap(find.text('text/plain').last);
    await settle(t);

    expect(dataOf(h)['body'], isEmpty);
    expect([for (final v in dataOf(h)['variables']! as List) v['variable']], [webhookRawVariableName]);
    final outputs = h['end']!.config['outputs'];
    expect((outputs! as VList).items.single, isA<VMap>());
    expect(((outputs as VList).items.single as VMap).entries['value_selector'], const VList([]));
    await h.dispose(t);
  });

  testWidgets('a read-only panel generates no URL and shows the read-only tables', (t) async {
    final h = await startWebhook(t, {...triggerWebhookDefaultValue()});
    var fetched = 0;
    await t.pumpWidget(
      webhookPanel(
        h,
        readOnly: true,
        fetch: (_) async {
          fetched++;
          return (url: 'x', debugUrl: null);
        },
      ),
    );
    await settle(t);

    expect(fetched, 0);
    expect(find.text('workflow.nodes.triggerWebhook.noQueryParameters'), findsOneWidget);
    expect(find.text('workflow.nodes.triggerWebhook.noHeaders'), findsOneWidget);
    expect(find.text('workflow.nodes.triggerWebhook.noBodyParameters'), findsOneWidget);
    expect(find.text('payload.'), findsOneWidget);
    await h.dispose(t);
  });
}
