import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow/dify_json.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_schedule/trigger_schedule_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../node_panel/harness.dart';

export '../../../node_panel/harness.dart';

/// Dify's `createData` of the schedule specs: a daily 11:30 AM schedule in UTC.
Map<String, Object?> createScheduleData([Map<String, Object?> overrides = const {}]) => {
  'mode': 'visual',
  'frequency': 'daily',
  'timezone': 'UTC',
  'visual_config': {
    'time': '11:30 AM',
    'weekdays': ['mon'],
    'on_minute': 15,
    'monthly_days': [1],
  },
  ...overrides,
};

/// A schedule node with Dify [data] (null values are left out, as `undefined`).
Node scheduleNode(Map<String, Object?> data, {String id = 'node-1'}) => node(
  id,
  type: 'trigger-schedule',
  title: 'Schedule Trigger',
  config: {
    for (final e in data.entries)
      if (e.value != null) e.key: Value.of(e.value),
  },
);

/// The node's Dify data now.
Map<String, Object?> dataOf(Harness h, [String id = 'node-1']) => difyDataOf(h[id]!);

/// The schedule panel body of [id] on [h], rebuilt as the document changes, in a 1000 px panel on a 1400 x 1000
/// screen (the test font is wider and the test translator's keys longer than Dify's English).
Future<void> pumpSchedulePanel(
  WidgetTester t,
  Harness h, {
  String id = 'node-1',
  ScheduleClock clock = const ScheduleClock(),
  String? profileTimezone,
}) async {
  t.view.physicalSize = const Size(1400, 1000);
  final actions = h.actions();
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: ScheduleHost(
          profileTimezone: profileTimezone,
          clock: clock,
          child: Align(
            alignment: Alignment.topRight,
            child: SizedBox(
              width: 1000,
              child: ListenableBuilder(
                listenable: h.controller,
                builder: (context, _) => SingleChildScrollView(
                  child: triggerSchedulePanelBody(
                    context,
                    NodePanelProps(node: h[id]!, controller: h.controller, actions: actions),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.pump();
}

/// Taps the first time-picker option [label] after scrolling it into its list's view.
Future<void> tapOption(WidgetTester t, String label) async {
  final f = find.text(label).first;
  await t.ensureVisible(f);
  await t.pumpAndSettle();
  await t.tap(f);
  await t.pumpAndSettle();
}
