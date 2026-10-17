// dify-spec: web/app/components/workflow/nodes/trigger-schedule/__tests__/node.spec.tsx
import 'package:dify_sf_app/src/cards/bodies/entry_bodies.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:dify_sf_app/src/workflow/dify_json.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_schedule/execution_time_calculator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'schedule_harness.dart';

Map<String, Object?> createNodeData([Map<String, Object?> overrides = const {}]) => {
  'mode': 'visual',
  'frequency': 'daily',
  'timezone': 'UTC',
  'visual_config': {'time': '11:30 AM'},
  ...overrides,
};

Future<void> renderNodeComponent(WidgetTester t, Map<String, Object?> data) async {
  final n = scheduleNode(data);
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 240,
            child: Builder(builder: (c) => const TriggerScheduleBody().build(c, BodyContext(n, (_) => null))),
          ),
        ),
      ),
    ),
  );
}

void main() {
  // The node is the canvas card (lib/src/cards/bodies/entry_bodies.dart, TriggerScheduleBody); its caption is
  // Dify's English text rather than the i18n key, and its value must be what the panel's calculator gives.
  group('TriggerScheduleNode', () {
    group('Rendering', () {
      testWidgets('should render the next execution label and computed execution time', (t) async {
        final data = createNodeData();
        await renderNodeComponent(t, data);
        expect(find.text('NEXT EXECUTION TIME'), findsOneWidget);
        expect(find.text(getNextExecutionTime(difyDataOf(scheduleNode(data)))), findsOneWidget);
      });

      testWidgets('should render the placeholder when cron mode has an invalid expression', (t) async {
        await renderNodeComponent(t, createNodeData({'mode': 'cron', 'cron_expression': 'invalid cron'}));
        expect(find.text('--'), findsOneWidget);
      });
    });
  });
}
