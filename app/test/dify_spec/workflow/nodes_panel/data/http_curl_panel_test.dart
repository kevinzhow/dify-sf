// dify-spec: web/app/components/workflow/nodes/http/components/__tests__/curl-panel.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/data_common.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/http/http_dialogs.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/http/http_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../dify_test_i18n.dart';

/// Opens the cURL dialog (the panel's "Import from cURL" pill) and returns what it imported.
Future<List<Map<String, Object?>>> open(
  WidgetTester t,
  Toasts toasts, {
  ({Map<String, Object?>? node, String? error}) Function(String)? parse,
}) async {
  useDifyTestTranslator();
  final imported = <Map<String, Object?>>[];
  await t.pumpWidget(
    MaterialApp(
      home: DataPanelHost(
        toast: toasts.call,
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () => showCurlPanel(context, onImport: imported.add, parse: parse ?? parseCurl),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
  return imported;
}

class Toasts {
  final list = <(DataToastType, String)>[];
  void call(DataToastType type, String message) => list.add((type, message));
}

void main() {
  group('curl-panel', () {
    group('parseCurl', () {
      test('should parse method, headers, json body, and query params from a valid curl command', () {
        final (:node, :error) = parseCurl(
          'curl -X POST -H "Authorization: Bearer token" --json "{"name":"openai"}" https://example.com/users?page=1&size=2',
        );

        expect(error, isNull);
        expect(node, containsPair('method', 'post'));
        expect(node, containsPair('url', 'https://example.com/users'));
        expect(node, containsPair('headers', 'Authorization: Bearer token'));
        expect(node, containsPair('params', 'page: 1\nsize: 2'));
      });

      test('should return an error for invalid curl input', () {
        expect(parseCurl('fetch https://example.com').error, contains('Invalid cURL command'));
      });

      test('should parse form data and attach typed content headers', () {
        final (:node, :error) = parseCurl(
          'curl --request POST --form "file=@report.txt;type=text/plain" --form "name=openai" https://example.com/upload',
        );

        expect(error, isNull);
        expect(node, containsPair('method', 'post'));
        expect(node, containsPair('url', 'https://example.com/upload'));
        expect(node, containsPair('headers', 'Content-Type: text/plain'));
        expect(node!['body'], {'type': 'form-data', 'data': 'file:@report.txt\nname:openai'});
      });

      test('should parse raw payloads and preserve equals signs in the body value', () {
        final (:node, :error) = parseCurl('curl --data-binary "token=abc=123" https://example.com/raw');

        expect(error, isNull);
        expect(node!['body'], {
          'type': 'raw-text',
          'data': [
            {'type': 'text', 'value': 'token=abc=123'},
          ],
        });
      });

      test('should return a descriptive error for %s', () {
        const cases = [
          ('curl -X', 'Missing HTTP method after -X or --request.'),
          ('curl --header', 'Missing header value after -H or --header.'),
          ('curl --data-raw', 'Missing data value after -d, --data, --data-raw, or --data-binary.'),
          ('curl --form', 'Missing form data after -F or --form.'),
          ('curl --json', 'Missing JSON data after --json.'),
          ('curl --form "=broken" https://example.com/upload', 'Invalid form data format.'),
          ('curl -H "Accept: application/json"', 'Missing URL or url not start with http.'),
        ];
        for (final (command, expectedError) in cases) {
          final r = parseCurl(command);
          expect(r.node, isNull, reason: command);
          expect(r.error, expectedError, reason: command);
        }
      });
    });

    group('component actions', () {
      testWidgets('should import a parsed curl node and reselect the node after saving', (t) async {
        final toasts = Toasts();
        final imported = await open(t, toasts);

        await t.enterText(find.byType(TextField), 'curl https://example.com');
        await t.tap(find.text('common.operation.save'));
        await t.pumpAndSettle();

        // The dialog closed; the panel re-renders from the imported data (no reselect is needed).
        expect(find.byType(CurlPanel), findsNothing);
        expect(imported, hasLength(1));
        expect(imported.single, containsPair('method', 'get'));
        expect(imported.single, containsPair('url', 'https://example.com'));
      });

      testWidgets('should notify the user when the curl command is invalid', (t) async {
        final toasts = Toasts();
        await open(t, toasts);

        await t.enterText(find.byType(TextField), 'invalid');
        await t.tap(find.text('common.operation.save'));
        await t.pumpAndSettle();

        expect(toasts.list.single.$1, DataToastType.error);
        expect(toasts.list.single.$2, contains('Invalid cURL command'));
        expect(find.byType(CurlPanel), findsOneWidget);
      });

      testWidgets('should keep the panel open when parsing returns no node and no error', (t) async {
        final toasts = Toasts();
        final imported = await open(t, toasts, parse: (_) => (node: null, error: null));

        await t.tap(find.text('common.operation.save'));
        await t.pumpAndSettle();

        expect(find.byType(CurlPanel), findsOneWidget);
        expect(imported, isEmpty);
        expect(toasts.list, isEmpty);
      });
    });
  });
}
