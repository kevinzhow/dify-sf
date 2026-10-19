// dify-spec: web/app/components/workflow/nodes/http/__tests__/panel.spec.tsx
//
// The real panel over a document node instead of a mocked use-config and mocked children: the children's changes
// are made through the children and read back from the node's data.
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/http/http_dialogs.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/http/http_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/http/key_value.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/http/timeout.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

Map<String, Object?> createData([Map<String, Object?> overrides = const {}]) => {
  'type': 'http-request',
  'title': 'HTTP Request',
  'desc': '',
  'variables': <Object?>[],
  'method': 'get',
  'url': 'https://api.example.com',
  'authorization': {'type': 'api-key', 'config': null},
  'headers': 'accept:application/json',
  'params': 'page:1',
  'body': {'type': 'none', 'data': <Object?>[]},
  'timeout': {'connect': 5, 'read': 10, 'write': 15},
  'ssl_verify': true,
  ...overrides,
};

/// The text field of the [index]th text input inside [of].
Finder field(Finder of, [int index = 0]) => find.descendant(of: of, matching: find.byType(TextField)).at(index);

Future<void> type(WidgetTester t, Finder f, String text) async {
  await t.enterText(f, text);
  await t.pump();
  await blur(t);
}

void main() {
  group('http/panel', () {
    testWidgets('renders request fields, forwards child changes, and wires header operations', (t) async {
      final h = await Harness.start(t, [
        difyNode('http-node', createData({'headers': '', 'params': ''})),
      ]);
      await renderBody(t, h, 'http-node', httpRequestPanelBody, width: 500);

      expect(find.text('GET'), findsOneWidget);
      await t.ensureVisible(find.text('WORKFLOW.NODES.COMMON.OUTPUTVARS'));
      await t.tap(find.text('WORKFLOW.NODES.COMMON.OUTPUTVARS'));
      await Harness.settle(t);
      for (final (name, type) in [
        ('body', 'string'),
        ('status_code', 'number'),
        ('headers', 'object'),
        ('files', 'Array[File]'),
      ]) {
        expect(find.byWidgetPredicate((w) => w is VarItem && w.name == name && w.type == type), findsOneWidget);
      }

      await t.tap(find.text('GET'));
      await Harness.settle(t);
      await t.tap(find.text('POST').last);
      await Harness.settle(t);
      expect(dataOf(h, 'http-node')['method'], 'post');

      await type(t, field(find.byType(ApiInput)), 'https://changed.example.com');
      expect(dataOf(h, 'http-node')['url'], 'https://changed.example.com');

      final headers = find.byType(KeyValueLines).at(0), params = find.byType(KeyValueLines).at(1);
      await type(t, field(headers), 'x-token');
      await type(t, field(headers, 1), '123');
      expect(dataOf(h, 'http-node')['headers'], 'x-token:123');
      // Typing into the last row's value added a row.
      expect(find.descendant(of: headers, matching: find.byType(KeyValueRow)), findsNWidgets(2));

      await type(t, field(params), 'x-token');
      await type(t, field(params, 1), '123');
      expect(dataOf(h, 'http-node')['params'], 'x-token:123');
      expect(find.descendant(of: params, matching: find.byType(KeyValueRow)), findsNWidgets(2));

      await t.ensureVisible(find.text('JSON'));
      await t.tap(find.text('JSON'));
      await Harness.settle(t);
      expect(dataOf(h, 'http-node')['body'], {'type': 'json', 'data': <Object?>[]});

      await t.ensureVisible(find.text('WORKFLOW.NODES.HTTP.TIMEOUT.TITLE'));
      await t.tap(find.text('WORKFLOW.NODES.HTTP.TIMEOUT.TITLE'));
      await Harness.settle(t);
      await t.ensureVisible(find.byType(TimeoutField).first);
      await type(t, field(find.byType(TimeoutField).first), '9');
      expect(dataOf(h, 'http-node')['timeout'], {'connect': 9, 'read': 10, 'write': 15});

      await t.ensureVisible(find.textContaining('workflow.nodes.http.authorization.authorization'));
      await t.tap(find.textContaining('workflow.nodes.http.authorization.authorization'));
      await t.pumpAndSettle();
      expect(find.byType(AuthorizationModal), findsOneWidget);
      await t.tap(find.text('common.operation.cancel'));
      await t.pumpAndSettle();

      await t.ensureVisible(find.textContaining('workflow.nodes.http.curl.title'));
      await t.tap(find.textContaining('workflow.nodes.http.curl.title'));
      await t.pumpAndSettle();
      expect(find.byType(CurlPanel), findsOneWidget);
      await t.tap(find.text('common.operation.cancel'));
      await t.pumpAndSettle();

      await t.ensureVisible(find.byType(DifySwitch));
      await t.tap(find.byType(DifySwitch));
      await Harness.settle(t);
      expect(dataOf(h, 'http-node')['ssl_verify'], false);
      await h.dispose(t);
    });

    testWidgets('shows at once, a legacy string body normalised (no block defaults to wait for)', (t) async {
      final h = await Harness.start(t, [
        difyNode(
          'http-node',
          createData({
            'body': {'type': 'json', 'data': '{"a":1}'},
          }),
        ),
      ]);
      await renderBody(t, h, 'http-node', httpRequestPanelBody, width: 500);

      expect(find.byType(ApiInput), findsOneWidget);
      expect(dataOf(h, 'http-node')['body'], {
        'type': 'json',
        'data': [
          {'type': 'text', 'value': '{"a":1}'},
        ],
      });
      await h.dispose(t);
    });

    testWidgets('renders auth and curl panels only when writable and toggled on', (t) async {
      final h = await Harness.start(t, [difyNode('http-node', createData())]);
      await renderBody(t, h, 'http-node', httpRequestPanelBody, width: 500);

      await t.tap(find.textContaining('workflow.nodes.http.authorization.authorization'));
      await t.pumpAndSettle();
      expect(find.byType(AuthorizationModal), findsOneWidget);
      await t.tap(find.text('common.operation.cancel'));
      await t.pumpAndSettle();
      await t.tap(find.textContaining('workflow.nodes.http.curl.title'));
      await t.pumpAndSettle();
      expect(find.byType(CurlPanel), findsOneWidget);
      await t.tap(find.text('common.operation.cancel'));
      await t.pumpAndSettle();

      await renderBody(
        t,
        h,
        'http-node',
        httpRequestPanelBody,
        width: 500,
        options: const WorkflowMenuOptions(canEdit: false),
      );

      await t.tap(find.textContaining('workflow.nodes.http.authorization.authorization'));
      await t.pumpAndSettle();
      await t.tap(find.textContaining('workflow.nodes.http.curl.title'));
      await t.pumpAndSettle();
      expect(find.byType(AuthorizationModal), findsNothing);
      expect(find.byType(CurlPanel), findsNothing);
      expect(t.widget<DifySwitch>(find.byType(DifySwitch)).disabled, isTrue);
      await h.dispose(t);
    });
  });
}
