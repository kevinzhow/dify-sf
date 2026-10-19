import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../members/harness.dart';

export '../members/harness.dart';

/// An app of [mode] whose caller holds [keys].
ValueNotifier<AppInfo> overviewApp({String mode = 'chat', List<String> keys = const []}) =>
    ValueNotifier(AppInfo(id: 'app-1', name: 'App', mode: mode, permissionKeys: keys));

/// A statistics API answering [rows] (by statistic; none: an empty series) and recording the calls.
class RecordingStatsApi implements StatsApi {
  RecordingStatsApi([this.rows = const {}]);

  final Map<AppStatistic, List<Map<String, Object?>>> rows;
  final calls = <({String appId, AppStatistic stat, String? start, String? end})>[];

  @override
  Future<List<StatisticRow>> statistic(String appId, AppStatistic stat, {String? start, String? end}) async {
    calls.add((appId: appId, stat: stat, start: start, end: end));
    return [for (final r in rows[stat] ?? const <Map<String, Object?>>[]) StatisticRow.fromJson(r, stat.valueKey)];
  }
}

/// Renders [child] in the members harness (Dify's test i18n, 1440 x 900).
Future<void> renderOverview(WidgetTester t, Widget child) => renderMembers(t, child);

/// The chart titles shown (their semantics labels, `appOverview.analysis.*.title`).
Finder chartTitle(String key) => find.bySemanticsLabel('appOverview.analysis.$key.title');
