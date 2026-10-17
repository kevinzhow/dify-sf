// dify-spec: web/app/components/workflow/nodes/trigger-webhook/components/__tests__/parameter-table.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_webhook/webhook_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_webhook/webhook_tables.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('trigger-webhook/parameter-table', () {
    testWidgets('updates parameter types and required flags for json payloads', (t) async {
      final calls = <List<Json>>[];
      await t.pumpWidget(
        wrap(
          ParameterTable(
            title: 'Parameters',
            parameters: const [
              {'name': 'page', 'type': 'string', 'required': false},
            ],
            onChange: calls.add,
            contentType: 'application/json',
          ),
        ),
      );

      // The page row's select (the first; the trailing empty row has one too) shows "String"; the next option is
      // Number.
      final rowSelect = find.text('String').first;
      expect(rowSelect, findsOneWidget);
      await t.tap(rowSelect);
      await settle(t);
      await t.tap(find.text('Number'));
      await settle(t);
      expect(calls, [
        [
          {'name': 'page', 'type': 'number', 'required': false},
        ],
      ]);

      calls.clear();
      await t.tap(checkboxes().first);
      expect(calls, [
        [
          {'name': 'page', 'type': 'string', 'required': true},
        ],
      ]);
    });

    testWidgets('forces plain-text bodies to a single string parameter', (t) async {
      final calls = <List<Json>>[];
      await t.pumpWidget(
        wrap(
          ParameterTable(
            title: 'Body',
            parameters: const [
              {'name': 'message', 'type': 'number', 'required': false},
            ],
            onChange: calls.add,
            contentType: 'text/plain',
          ),
        ),
      );

      await t.tap(checkboxes().first);

      expect(calls, [
        [
          {'name': 'message', 'type': 'string', 'required': true},
        ],
      ]);
    });
  });
}
