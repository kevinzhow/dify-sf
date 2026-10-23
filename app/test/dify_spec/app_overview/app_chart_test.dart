// dify-spec: web/app/components/app/overview/__tests__/app-chart.spec.tsx
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/app_detail/overview/app_chart.dart';
import 'package:dify_sf_app/src/app_detail/overview/app_chart_canvas.dart';
import 'package:dify_sf_app/src/app_detail/overview/app_chart_utils.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('app-chart', () {
    group('Chart', () {
      testWidgets('should render cost summaries with token pricing details', (t) async {
        await renderOverview(
          t,
          const Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 600,
              child: AppChart(
                title: 'Cost title',
                explanation: 'Cost explanation',
                timePeriod: 'Last 7 days',
                chartType: ChartType.costs,
                statistics: [
                  {'date': 'Jan 1, 2024', 'count': 100, 'total_price': 1.25},
                  {'date': 'Jan 2, 2024', 'count': 200, 'total_price': 2.5},
                ],
              ),
            ),
          ),
        );
        final title = t.getSemantics(find.bySemanticsLabel('Cost title'));
        expect(title.tooltip, 'Cost title');
        expect(find.text('300'), findsOneWidget);
        expect(find.text('Last 7 days'), findsNothing);
        expect(find.textContaining(RegExp(r'\$3\.7500'), findRichText: true), findsOneWidget);
        expect(find.bySemanticsLabel('Chart'), findsOneWidget);
      });
    });

    group('MessagesChart', () {
      testWidgets('should render fallback chart data when the API returns no rows', (t) async {
        await renderOverview(
          t,
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 600,
              child: BizChart(
                config: BizCharts.messages,
                appId: 'app-1',
                period: (name: 'Last week', query: (start: 'Jan 1, 2024', end: 'Jan 4, 2024')),
                source: RecordingStatsApi(),
              ),
            ),
          ),
        );
        expect(chartTitle('totalMessages'), findsOneWidget);
        expect(find.text('0'), findsOneWidget);
        expect(find.bySemanticsLabel('Chart'), findsOneWidget);
        final options = t.widget<AppChartCanvas>(find.byType(AppChartCanvas)).options;
        expect(options.yMax, 500);
        expect(options.source, hasLength(3));
        expect(options.source.first, {'date': 'Jan 1, 2024', 'message_count': 0});
        expect(AppStatistic.dailyMessages.valueKey, 'message_count');
      });
    });
  });
}
