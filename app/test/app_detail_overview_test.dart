/// The Overview page beyond Dify's specs: the period picker drives the statistics queries, the mock series fills the
/// charts of each mode, the chart's tooltip, and ECharts' axis rules ported to the painter. With `SCREENSHOT_DIR` set
/// it also writes PNGs of the page (empty and with mock data) for eyeballing.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart' show FakeStatsApi;
import 'package:dify_sf_app/src/app_detail/overview/app_chart_canvas.dart';
import 'package:dify_sf_app/src/app_detail/overview/app_chart_utils.dart';
import 'package:dify_sf_app/src/app_detail/overview/overview_page.dart';
import 'package:dify_sf_app/src/app_detail/overview/time_range.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/app_overview/harness.dart';
import 'support/app_fonts.dart';

final _today = DateTime(2026, 10, 19, 15, 30);

Future<void> _page(WidgetTester t, {required String mode, required StatsApi stats, Key? key}) => renderOverview(
  t,
  RepaintBoundary(
    key: key,
    child: DefaultTextStyle.merge(
      style: const TextStyle(fontFamily: 'Noto Sans'),
      child: OverviewView(
        app: overviewApp(mode: mode, keys: const [AppPermissionKeys.monitor]),
        stats: stats,
        now: () => _today,
        openProviderSettings: (_) {},
      ),
    ),
  ),
);

void main() {
  group('ECharts axis rules', () {
    test('nice intervals and the fixed maximum as the last tick', () {
      expect(valueAxisTicks(500), [0, 100, 200, 300, 400, 500]);
      expect(valueAxisTicks(100), [0, 20, 40, 60, 80, 100]);
      expect(valueAxisTicks(1000), [0, 200, 400, 600, 800, 1000]);
      expect(valueAxisTicks(9), [0, 2, 4, 6, 8, 9]);
      expect(valueAxisTicks(0), [0, 0.2, 0.4, 0.6, 0.8, 1]);
      expect(valueAxisLabel(1000), '1,000');
    });

    test('the periods of the community picker', () {
      final m = timePeriodMapping(_today);
      expect(m['1']!.value, 0);
      expect(m['4']!.value, 92); // Jul 19 -> Oct 19
      expect(m['6']!.value, 18);
      expect(m['7']!.value, 18);
      expect(m['8']!.value, 291);
      expect(defaultOverviewPeriod(_today).query, (start: '2026-10-12 00:00', end: '2026-10-19 23:59'));
      expect(subtractMonths(DateTime(2026, 3, 31), 1), DateTime(2026, 2, 28));
    });

    test('empty rows end the day before today, as Dify (dayjs diff truncates)', () {
      final q = defaultOverviewPeriod(_today).query!;
      final rows = getDefaultChartData(start: q.start, end: q.end);
      expect(rows.map((r) => r['date']), [for (var d = 12; d <= 18; d++) 'Oct $d, 2026']);
    });
  });

  testWidgets('workflow charts follow the period picker', (t) async {
    final stats = RecordingStatsApi();
    await _page(t, mode: 'workflow', stats: stats);
    expect(stats.calls.map((c) => c.stat).toSet(), AppStatistic.forMode('workflow').toSet());
    expect(stats.calls.first.start, '2026-10-12 00:00');
    expect(find.byKey(const ValueKey('chart-summary')), findsNWidgets(4));
    stats.calls.clear();
    await t.tap(find.text('appLog.filter.period.last7days'));
    await settle(t);
    await t.tap(find.text('appLog.filter.period.allTime').last);
    await settle(t);
    expect(stats.calls, hasLength(4));
    expect(stats.calls.every((c) => c.start == null && c.end == null), isTrue);
  });

  testWidgets('chatflow charts with the mock series, and the tooltip of a point', (t) async {
    await useAppFonts();
    final stats = FakeStatsApi(mock: true, clock: () => _today, modeOf: (_) => AppModes.advancedChat);
    await _page(t, mode: AppModes.advancedChat, stats: stats);
    expect(find.byType(AppChartCanvas), findsNWidgets(7));
    final canvas = find.byType(AppChartCanvas).first;
    final options = t.widget<AppChartCanvas>(canvas).options;
    expect(options.source, isNotEmpty);
    final box = t.getRect(canvas);
    final layout = ChartLayout.of(options, box.size, chartLabelStyle('Noto Sans'));
    final i = layout.symbols.indexWhere((s) => s);
    final point = box.topLeft + layout.pointOf(i)!;
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(point);
    await t.pump();
    expect(find.text(options.formatXLabel('${options.source[i]['date']}')), findsOneWidget);
  });

  testWidgets('screenshots', (t) async {
    final out = Platform.environment['SCREENSHOT_DIR'];
    if (out == null) return;
    await useAppFonts();
    Future<void> shot(String name) async {
      final b = t.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
      final image = await t.runAsync(() => b.toImage());
      final png = await t.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
      File('$out/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(png!.buffer.asUint8List());
    }

    await _page(t, mode: 'workflow', stats: RecordingStatsApi(), key: const ValueKey('shot'));
    await shot('overview-empty');
    await _page(
      t,
      mode: AppModes.advancedChat,
      stats: FakeStatsApi(mock: true, clock: () => _today, modeOf: (_) => AppModes.advancedChat),
      key: const ValueKey('shot'),
    );
    await settle(t);
    await shot('overview-mock');
  });
}
