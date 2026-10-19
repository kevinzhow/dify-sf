// dify-spec: web/app/(commonLayout)/app/(appDetailLayout)/[appId]/overview/__tests__/chart-view.spec.tsx
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/app_detail/overview/overview_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Future<RecordingStatsApi> _render(WidgetTester t, List<String> keys) async {
  final stats = RecordingStatsApi();
  await renderOverview(
    t,
    ChartView(
      app: overviewApp(keys: keys).value,
      stats: stats,
      headerRight: TextButton(onPressed: () {}, child: const Text('header action')),
    ),
  );
  return stats;
}

void main() {
  group('ChartView monitor permission', () {
    group('Permissions', () {
      testWidgets('should not render monitoring charts when app monitor permission is missing', (t) async {
        final stats = await _render(t, const []);
        expect(find.text('common.appMenus.overview'), findsNothing);
        expect(find.text('header action'), findsNothing);
        expect(stats.calls, isEmpty);
      });

      testWidgets('should render monitoring charts when app monitor permission is granted', (t) async {
        final stats = await _render(t, const [AppPermissionKeys.monitor]);
        expect(find.text('common.appMenus.overview'), findsOneWidget);
        final heading = t.getSemantics(find.text('common.appMenus.overview'));
        expect(heading.flagsCollection.isHeader, isTrue);
        expect(find.text('header action'), findsOneWidget);
        expect(chartTitle('totalConversations'), findsOneWidget);
        expect(stats.calls.map((c) => c.stat), contains(AppStatistic.dailyConversations));
      });
    });
  });
}
