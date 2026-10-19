// dify-spec: web/app/(commonLayout)/app/(appDetailLayout)/[appId]/overview/__tests__/view.spec.tsx
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/app_detail/overview/overview_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Future<void> _render(WidgetTester t, List<String> keys) => renderOverview(
  t,
  OverviewView(
    app: overviewApp(keys: keys),
    stats: RecordingStatsApi(),
    tracingPanel: TextButton(onPressed: () {}, child: const Text('tracing')),
  ),
);

Finder get _panel => find.byKey(const ValueKey('apikey-info-panel'));
Finder get _chartView => find.byType(ChartView);
Finder get _tracing => find.text('tracing');

void main() {
  group('OverviewView monitor permission', () {
    group('Permissions', () {
      testWidgets('should not render overview page content when app monitor permission is missing', (t) async {
        await _render(t, const []);
        expect(_panel, findsNothing);
        expect(_chartView, findsNothing);
        expect(_tracing, findsNothing);
      });

      testWidgets(
        'should render overview page content without tracing entry when only app monitor permission is granted',
        (t) async {
          await _render(t, const [AppPermissionKeys.monitor]);
          expect(_panel, findsOneWidget);
          expect(_chartView, findsOneWidget);
          expect(t.widget<ChartView>(_chartView).app.id, 'app-1');
          expect(_tracing, findsNothing);
        },
      );

      testWidgets('should render tracing entry when app tracing config permission is granted with monitor access', (
        t,
      ) async {
        await _render(t, const [AppPermissionKeys.monitor, AppPermissionKeys.tracingConfig]);
        expect(_panel, findsOneWidget);
        expect(_chartView, findsOneWidget);
        expect(_tracing, findsOneWidget);
      });

      testWidgets('should not render overview page content when only app tracing config permission is granted', (
        t,
      ) async {
        await _render(t, const [AppPermissionKeys.tracingConfig]);
        expect(_panel, findsNothing);
        expect(_chartView, findsNothing);
        expect(_tracing, findsNothing);
      });
    });
  });
}
