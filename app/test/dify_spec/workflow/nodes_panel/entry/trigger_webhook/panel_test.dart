// dify-spec: web/app/components/workflow/nodes/trigger-webhook/__tests__/panel.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/header/header_data.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_webhook/trigger_webhook_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

Json inputs([Json overrides = const {}]) => {
  'method': 'POST',
  'webhook_url': 'https://example.com/webhook',
  'webhook_debug_url': '',
  'content_type': 'application/json',
  'headers': <Object?>[],
  'params': <Object?>[],
  'body': <Object?>[],
  'status_code': 200,
  'response_body': 'ok',
  'variables': <Object?>[],
  ...overrides,
};

/// The text field showing [text].
Finder fieldWith(String text) =>
    find.byWidgetPredicate((w) => w is TextField && w.controller?.text == text, description: 'field "$text"');

Finder get statusCodeInput => find.descendant(of: find.byType(StatusCodeField), matching: find.byType(TextField));

void main() {
  setUp(useDifyTestTranslator);

  group('WebhookTriggerPanel', () {
    group('Rendering', () {
      testWidgets('should render the real panel fields without generating a new webhook url when one already exists', (
        t,
      ) async {
        final h = await startWebhook(t, inputs());
        final fetched = <String>[];
        await t.pumpWidget(
          webhookPanel(
            h,
            fetch: (id) async {
              fetched.add(id);
              return (url: 'x', debugUrl: null);
            },
          ),
        );
        await settle(t);

        expect(fieldWith('https://example.com/webhook'), findsOneWidget);
        expect(find.text('application/json'), findsWidgets);
        expect(fieldWith('ok'), findsOneWidget);
        expect(fetched, isEmpty);
        await h.dispose(t);
      });

      testWidgets('should keep the content type selector aligned with the webhook url row width', (t) async {
        final h = await startWebhook(t, inputs());
        await t.pumpWidget(webhookPanel(h));
        await settle(t);

        final selects = find.byType(DifySelect<String>);
        final contentType = t.getRect(selects.at(1));
        final urlRow = t.getRect(find.ancestor(of: selects.at(0), matching: find.byType(Row)).first);
        expect(contentType.left, urlRow.left);
        expect(contentType.width, urlRow.width);
        await h.dispose(t);
      });

      testWidgets('should request a webhook url when the node is writable and missing one', (t) async {
        final h = await startWebhook(t, inputs({'webhook_url': ''}));
        final fetched = <String>[];
        await t.pumpWidget(
          webhookPanel(
            h,
            fetch: (id) async {
              fetched.add(id);
              return (url: 'https://example.com/new', debugUrl: 'https://example.com/debug');
            },
          ),
        );
        await settle(t);

        expect(fetched, ['n']);
        expect(dataOf(h)['webhook_url'], 'https://example.com/new');
        expect(dataOf(h)['webhook_debug_url'], 'https://example.com/debug');
        await h.dispose(t);
      });
    });

    group('Status Code Input', () {
      testWidgets('should update the status code when users enter a parseable value', (t) async {
        final h = await startWebhook(t, inputs());
        await t.pumpWidget(webhookPanel(h));
        await settle(t);

        // dify-ui commits as it parses; DifyNumberField commits on Enter / blur.
        await t.enterText(statusCodeInput, '201');
        await t.testTextInput.receiveAction(TextInputAction.done);
        await settle(t);

        expect(dataOf(h)['status_code'], 201);
        await h.dispose(t);
      });

      testWidgets('should ignore clear changes until the value is committed', (t) async {
        final h = await startWebhook(t, inputs({'status_code': 204}));
        await t.pumpWidget(webhookPanel(h));
        await settle(t);

        await t.enterText(statusCodeInput, '');
        await settle(t);
        expect(dataOf(h)['status_code'], 204);

        FocusManager.instance.primaryFocus?.unfocus();
        await settle(t);
        expect(dataOf(h)['status_code'], 200);
        await h.dispose(t);
      });
    });

    group('Interactions', () {
      testWidgets('should handle method, content type, table, response, and copy actions', (t) async {
        final h = await startWebhook(t, inputs());
        final toasts = <(HeaderToastType, String)>[];
        await t.pumpWidget(webhookPanel(h, toast: (type, m) => toasts.add((type, m))));
        await settle(t);

        await t.tap(buttonNamed('common.operation.copy'));
        await settle(t);
        expect(h.clipboard, 'https://example.com/webhook');
        expect(toasts, [(HeaderToastType.success, 'workflow.nodes.triggerWebhook.urlCopied')]);

        await t.tap(find.text('POST'));
        await settle(t);
        await t.tap(find.text('GET').last);
        await settle(t);
        expect(dataOf(h)['method'], 'GET');

        await t.tap(find.text('application/json'));
        await settle(t);
        await t.tap(find.text('text/plain').last);
        await settle(t);
        expect(dataOf(h)['content_type'], 'text/plain');

        // Query, header and body tables: type a name into each trailing row (fields: the URL, then the rows; each
        // named row brings a new trailing row).
        await t.enterText(find.byType(TextField).at(1), 'page');
        await settle(t);
        await t.enterText(find.byType(TextField).at(3), 'x-token');
        await settle(t);
        await t.enterText(find.byType(TextField).at(5), 'raw_text');
        await settle(t);
        expect(dataOf(h)['params'], [
          {'name': 'page', 'type': 'string', 'required': false},
        ]);
        expect(dataOf(h)['headers'], [
          {'name': 'x-token', 'required': false},
        ]);
        expect(dataOf(h)['body'], [
          {'name': 'raw_text', 'type': 'string', 'required': false},
        ]);
        expect(
          [for (final v in dataOf(h)['variables']! as List) '${v['label']}.${v['variable']}'],
          [
            'param.page',
            'header.x_token',
            'body.raw_text',
          ],
        );

        await t.enterText(fieldWith('ok'), 'updated body');
        await settle(t);
        expect(dataOf(h)['response_body'], 'updated body');

        expect(find.text('query_params.'), findsOneWidget);
        final title = find.text('workflow.nodes.common.outputVars'.toUpperCase());
        await t.ensureVisible(title);
        await t.tap(title);
        await settle(t);
        expect(find.text('query_params.'), findsNothing);
        await h.dispose(t);
      });

      testWidgets('should render the debug url card, copy it, and show the private-address warning', (t) async {
        final h = await startWebhook(t, inputs({'webhook_debug_url': 'http://127.0.0.1:8000/debug'}));
        await t.pumpWidget(webhookPanel(h));
        await settle(t);

        await t.tap(find.text('http://127.0.0.1:8000/debug'));
        await settle(t);

        expect(h.clipboard, 'http://127.0.0.1:8000/debug');
        expect(find.text('workflow.nodes.triggerWebhook.debugUrlPrivateAddressWarning'), findsOneWidget);
        await t.pump(const Duration(seconds: 3));
        await h.dispose(t);
      });
    });
  });
}
