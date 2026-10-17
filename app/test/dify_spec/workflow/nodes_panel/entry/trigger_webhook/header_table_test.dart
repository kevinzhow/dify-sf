// dify-spec: web/app/components/workflow/nodes/trigger-webhook/components/__tests__/header-table.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_webhook/webhook_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_webhook/webhook_tables.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('trigger-webhook/header-table', () {
    testWidgets('updates header names and required flags through the real generic table', (t) async {
      final calls = <List<Json>>[];
      await t.pumpWidget(
        wrap(
          HeaderTable(
            headers: const [
              {'name': 'x-request-id', 'required': false},
            ],
            onChange: calls.add,
          ),
        ),
      );

      await t.enterText(textboxes().first, 'Auth Token');
      expect(calls.last, [
        {'name': 'Auth_Token', 'required': false},
      ]);

      calls.clear();
      // The field shows what the (unchanged) parent passes again.
      await t.pumpWidget(
        wrap(
          HeaderTable(
            headers: const [
              {'name': 'x-request-id', 'required': false},
            ],
            onChange: calls.add,
          ),
        ),
      );
      await t.tap(checkboxes().first);

      expect(calls, [
        [
          {'name': 'x-request-id', 'required': true},
        ],
      ]);
    });

    testWidgets('renders readonly rows without the trailing editable row', (t) async {
      await t.pumpWidget(
        wrap(
          HeaderTable(
            readonly: true,
            headers: const [
              {'name': 'authorization', 'required': true},
            ],
            onChange: (_) {},
          ),
        ),
      );

      final field = t.widget<TextField>(textboxes());
      expect(field.controller!.text, 'authorization');
      expect(field.enabled, isFalse);
      expect(checkboxes(), findsOneWidget);
    });
  });
}
