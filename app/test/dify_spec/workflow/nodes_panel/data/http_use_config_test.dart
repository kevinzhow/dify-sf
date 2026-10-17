// dify-spec: web/app/components/workflow/nodes/http/__tests__/use-config.spec.ts
//
// use-config's state lives in the document: its effects are read back from the node's data after acting on the
// panel; the pure parts (hydration, filters, key-value parsing) are called directly.
import 'package:dify_sf_app/src/workflow/var_types.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/http/http_dialogs.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/http/http_model.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/http/http_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Map<String, Object?> createPayload([Map<String, Object?> overrides = const {}]) => {
  'title': 'HTTP Request',
  'desc': '',
  'type': 'http-request',
  'variables': <Object?>[],
  'method': 'get',
  'url': 'https://api.example.com',
  'authorization': {'type': 'no-auth'},
  'headers': 'accept:application/json',
  'params': 'page:1',
  'body': {'type': 'json', 'data': '{"name":"alice"}'},
  'timeout': {'connect': 5, 'read': 10, 'write': 15},
  'ssl_verify': true,
  ...overrides,
};

final defaultConfig = createPayload({
  'method': 'post',
  'url': 'https://default.example.com',
  'headers': '',
  'params': '',
  'body': {'type': 'none', 'data': <Object?>[]},
  'timeout': {'connect': 1, 'read': 2, 'write': 3},
  'ssl_verify': false,
});

Future<void> type(WidgetTester t, Finder f, String text) async {
  await t.enterText(f, text);
  await t.pump();
  await blur(t);
}

void main() {
  group('http/use-config', () {
    testWidgets('hydrates defaults, normalizes body payloads, and exposes var-list and key-value helpers', (t) async {
      final hydrated = hydrateHttpInputs(createPayload(), defaultConfig);
      expect(hydrated['method'], 'get');
      expect(hydrated['url'], 'https://api.example.com');
      expect(hydrated['ssl_verify'], true);
      expect(hydrated['body'], {
        'type': 'json',
        'data': [
          {'type': 'text', 'value': '{"name":"alice"}'},
        ],
      });

      final h = await Harness.start(t, [difyNode('http-node', createPayload())]);
      await renderBody(
        t,
        h,
        'http-node',
        httpRequestPanelBody,
        width: 500,
        host: (child) => HttpPanelHost(defaultConfig: defaultConfig, child: child),
      );
      expect(dataOf(h, 'http-node')['body'], hydrated['body']);
      expect(dataOf(h, 'http-node')['method'], 'get');

      expect(strToKeyValueList('accept:application/json').map((i) => (i.key, i.value)), [
        ('accept', 'application/json'),
      ]);
      expect(httpTextVariableTypes.contains(VarType.string), isTrue);
      expect(httpTextVariableTypes.contains(VarType.number), isTrue);
      expect(httpTextVariableTypes.contains(VarType.secret), isTrue);
      expect(httpTextVariableTypes.contains(VarType.file), isFalse);
      await h.dispose(t);
    });

    testWidgets('initializes empty body data arrays when the payload body is missing', (t) async {
      final payload = createPayload({
        'body': {'type': 'form-data'},
      });
      expect(hydrateHttpInputs(payload)['body'], {'type': 'form-data', 'data': <Object?>[]});

      final h = await Harness.start(t, [difyNode('http-node', payload)]);
      await renderBody(t, h, 'http-node', httpRequestPanelBody, width: 500);

      expect(dataOf(h, 'http-node')['body'], {'type': 'form-data', 'data': <Object?>[]});
      await h.dispose(t);
    });

    testWidgets('updates request fields, authorization state, curl imports, and ssl verification', (t) async {
      final h = await Harness.start(t, [
        difyNode('http-node', createPayload({'headers': '', 'params': ''})),
      ]);
      await renderBody(t, h, 'http-node', httpRequestPanelBody, width: 500);
      Map<String, Object?> data() => dataOf(h, 'http-node');

      await t.tap(find.text('GET'));
      await Harness.settle(t);
      await t.tap(find.text('DELETE').last);
      await Harness.settle(t);
      expect(data()['method'], 'delete');

      await type(
        t,
        find.descendant(of: find.byType(ApiInput), matching: find.byType(TextField)),
        'https://changed.example.com',
      );
      expect(data()['url'], 'https://changed.example.com');

      await t.tap(find.textContaining('workflow.nodes.http.authorization.authorization'));
      await t.pumpAndSettle();
      expect(find.byType(AuthorizationModal), findsOneWidget);
      await t.tap(find.text('workflow.nodes.http.authorization.api-key'));
      await t.pumpAndSettle();
      await t.tap(find.text('workflow.nodes.http.authorization.bearer'));
      await t.pumpAndSettle();
      await t.enterText(
        find.descendant(of: find.byType(AuthorizationModal), matching: find.byType(TextField)).last,
        'secret',
      );
      await t.pump();
      await t.tap(find.text('common.operation.save'));
      await t.pumpAndSettle();
      expect(find.byType(AuthorizationModal), findsNothing);
      expect(data()['authorization'], {
        'type': 'api-key',
        'config': {'type': 'bearer', 'api_key': 'secret'},
      });

      await t.tap(find.textContaining('workflow.nodes.http.curl.title'));
      await t.pumpAndSettle();
      await t.enterText(
        find.descendant(of: find.byType(CurlPanel), matching: find.byType(TextField)),
        'curl -X PATCH -H "authorization:Bearer imported" --json \'{"ok":true}\' https://imported.example.com?debug=true',
      );
      await t.tap(find.text('common.operation.save'));
      await t.pumpAndSettle();
      expect(find.byType(CurlPanel), findsNothing);
      expect(data()['method'], 'patch');
      expect(data()['url'], 'https://imported.example.com');
      expect(data()['headers'], 'authorization:Bearer imported');
      expect(data()['params'], 'debug: true');
      expect(data()['body'], {
        'type': 'json',
        'data': [
          {'type': 'text', 'value': '{"ok":true}'},
        ],
      });
      // Authorization and the rest stay.
      expect((data()['authorization']! as Map)['type'], 'api-key');

      await t.ensureVisible(find.byType(DifySwitch));
      await t.tap(find.byType(DifySwitch));
      await Harness.settle(t);
      expect(data()['ssl_verify'], false);
      await h.dispose(t);
    });
  });
}
