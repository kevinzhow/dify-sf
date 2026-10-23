// dify-spec: web/app/components/app/overview/__tests__/app-chart-utils.spec.ts
import 'package:dify_sf_app/src/app_detail/overview/app_chart_utils.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('app-chart-utils', () {
    group('getDefaultChartData', () {
      test('should build fallback rows for the requested date window', () {
        final rows = getDefaultChartData(start: 'Jan 1, 2024', end: 'Jan 4, 2024', key: 'interactions');
        expect(rows, hasLength(3));
        expect(rows[0], {'date': 'Jan 1, 2024', 'interactions': 0});
        expect(rows[2], {'date': 'Jan 3, 2024', 'interactions': 0});
      });
    });

    group('hasNonZeroChartData', () {
      test('should detect whether rows contain a non-zero chart value', () {
        expect(
          hasNonZeroChartData([
            {'date': 'Jan 1, 2024', 'count': 0},
            {'date': 'Jan 2, 2024', 'count': '0'},
          ], 'count'),
          isFalse,
        );
        expect(
          hasNonZeroChartData([
            {'date': 'Jan 1, 2024', 'count': 0},
            {'date': 'Jan 2, 2024', 'count': 1},
          ], 'count'),
          isTrue,
        );
      });
    });

    group('getSummaryValue', () {
      test('should average values when the chart is configured as an average', () {
        final summary = getSummaryValue(
          chartType: ChartType.conversations,
          statistics: [
            {'date': 'Jan 1, 2024', 'latency': 10},
            {'date': 'Jan 2, 2024', 'latency': 20},
          ],
          yField: 'latency',
          isAvg: true,
          unit: 'ms',
        );
        expect(summary, '15 ms');
      });

      test('should compress large cost totals with a k suffix', () {
        final summary = getSummaryValue(
          chartType: ChartType.costs,
          statistics: [
            {'date': 'Jan 1, 2024', 'count': 700},
            {'date': 'Jan 2, 2024', 'count': 800},
          ],
          yField: 'count',
        );
        expect(summary, '2k');
      });

      test('should keep small cost totals in their raw form', () {
        final summary = getSummaryValue(
          chartType: ChartType.costs,
          statistics: [
            {'date': 'Jan 1, 2024', 'count': 250},
            {'date': 'Jan 2, 2024', 'count': 300},
          ],
          yField: 'count',
        );
        expect(summary, '550');
      });
    });

    group('getChartValueField', () {
      test('should prefer the explicit value key and otherwise fall back to the count-like field', () {
        expect(
          getChartValueField([
            {'date': 'Jan 1, 2024', 'request_count': 2},
          ], 'total'),
          'total',
        );
        expect(
          getChartValueField([
            {'date': 'Jan 1, 2024', 'request_count': 2},
          ]),
          'request_count',
        );
        expect(
          getChartValueField([
            {'date': 'Jan 1, 2024', 'latency': 2},
          ]),
          'count',
        );
      });
    });

    group('getTokenSummary', () {
      test('should sum token costs using currency formatting', () {
        expect(
          getTokenSummary([
            {'date': 'Jan 1, 2024', 'count': 1, 'total_price': '1.25'},
            {'date': 'Jan 2, 2024', 'count': 2, 'total_price': '2.5'},
          ]),
          r'$3.7500',
        );
      });
    });

    group('buildChartOptions', () {
      test('should build line chart options with dataset and y-axis max', () {
        final options = buildChartOptions(
          statistics: [
            {'date': 'Jan 1, 2024', 'count': 5},
            {'date': 'Jan 2, 2024', 'count': 10},
          ],
          chartType: ChartType.messages,
          yField: 'count',
          yMax: 100,
        );
        expect(options.dimensions, ['date', 'count']);
        expect(options.source, hasLength(2));
        expect(options.grid.top, 16);
        expect(options.grid.left, 0);
        expect(options.grid.right, 0);
        expect(options.yMax, 100);
        expect(options.lineColor, const Color.fromRGBO(6, 148, 162, 1));
      });

      test('should build token-aware tooltip content and split-line intervals for cost charts', () {
        final options = buildChartOptions(
          statistics: [
            {'date': 'Jan 1, 2024', 'total_cost': 5, 'total_price': '1.25'},
            {'date': 'Jan 2, 2024', 'total_cost': 10, 'total_price': '2.50'},
            {'date': 'Jan 3, 2024', 'total_cost': 15, 'total_price': '3.75'},
          ],
          chartType: ChartType.costs,
          yField: 'total_cost',
        );
        expect(options.formatXLabel('Jan 2, 2024'), 'Jan 2, 2024');
        expect(options.outerSplitLine(0), isTrue);
        expect(options.outerSplitLine(1), isFalse);
        expect(options.innerSplitLine(0, ''), isFalse);
        expect(options.innerSplitLine(1, '1'), isTrue);
        expect(
          options.tooltip('Jan 2, 2024', {'total_cost': 10, 'total_price': '2.50'}).toString(),
          contains(r'~$2.50'),
        );
      });
    });
  });
}
