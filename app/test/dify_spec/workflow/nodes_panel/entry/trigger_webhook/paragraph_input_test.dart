// dify-spec: web/app/components/workflow/nodes/trigger-webhook/components/__tests__/paragraph-input.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_webhook/webhook_tables.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('trigger-webhook/paragraph-input', () {
    testWidgets('renders line numbers for multiline content and forwards text changes', (t) async {
      final calls = <String>[];
      await t.pumpWidget(
        wrap(ParagraphInput(value: 'line-1\nline-2\nline-3\nline-4', onChange: calls.add, placeholder: 'Body')),
      );

      expect(find.text('01'), findsOneWidget);
      expect(find.text('04'), findsOneWidget);
      expect(t.widget<TextField>(textboxes()).minLines, 4);

      await t.enterText(textboxes(), 'updated body');

      expect(calls, ['updated body']);
    });

    testWidgets('keeps the textarea disabled when requested', (t) async {
      await t.pumpWidget(wrap(ParagraphInput(value: '', onChange: (_) {}, disabled: true)));

      expect(t.widget<TextField>(textboxes()).enabled, isFalse);
      expect(find.text('03'), findsOneWidget);
    });
  });
}
