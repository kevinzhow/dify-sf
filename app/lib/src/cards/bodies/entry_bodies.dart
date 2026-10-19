import 'dart:convert';
import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../card_kit.dart';
import '../node_body.dart';

List<Value> _items(Value? v) => switch (v) {
  VItems(:final items) => [for (final i in items) i.value],
  VList(:final items) => items,
  _ => const [],
};

String _str(Value? v) => v is VString ? v.value : '';

Value? _at(Value? map, String key) => map is VMap ? map.entries[key] : null;

/// Icons (asset, colour) the bodies in this file draw, for IconCache.preload.
List<(String, Color)> get entryBodyIcons => <(String, Color)>[
  ('assets/remix_icons/robot-2-fill.svg', DifyColors.textPrimaryOnSurface),
  ('assets/remix_icons/mail-send-fill.svg', DifyColors.textPrimaryOnSurface),
  ('assets/remix_icons/home-5-fill.svg', DifyColors.textPrimaryOnSurface),
  ('assets/remix_icons/add-line.svg', DifyColors.componentsButtonPrimaryText),
  ('assets/dify_icons/vender/solid/alertsAndFeedback/alert-triangle.svg', DifyColors.textWarning),
];

/// `text-2xs font-medium tracking-wide uppercase`; the line height is the inherited 1.5.
const _caption = DifyTextStyle(
  TextStyle(fontSize: 10, fontWeight: FontWeight.w500, height: 1.5, letterSpacing: 0.25),
  uppercase: true,
);

/// `mb-1 px-3 py-1` around [children] stacked `space-y-0.5`; [rows] of 24 px: py-1 + rows + mb-1.
double _rowsBlock(int rows) => 4 + rows * 24 + max(0, rows - 1) * 2 + 4 + 4;

Widget _rowsColumn(List<Widget> rows) => Padding(
  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final (i, r) in rows.indexed) ...[if (i > 0) const SizedBox(height: 2), r],
    ],
  ),
);

// MARK: - Human input

/// Human Input (nodes/human-input/node.tsx): the delivery methods (when there are any), then one right-aligned row
/// per user action (labelled with its id) and the Timeout row, each with its source handle (`<action id>`,
/// `__timeout`) centred on the row at the right edge. No default `source` handle.
class HumanInputBody extends NodeBody {
  const HumanInputBody();

  static List<String> _methods(BodyContext ctx) => [
    for (final m in _items(ctx['delivery_methods'])) _str(_at(m, 'type')),
  ];

  static List<String> _actions(BodyContext ctx) => [
    for (final a in _items(ctx['user_actions'])) _str(_at(a, 'id')),
  ];

  static bool _hasTile(String type) => type == 'webapp' || type == 'email';

  /// A method row: p-1 around the 20 px icon tile (p-0.5 + border + 14 px icon) or the 16 px label.
  static double _methodRow(String type) => _hasTile(type) ? 28 : 24;

  /// py-1, header (py-0.5 + 12), space-y-0.5, rows space-y-0.5, py-1.
  static double _deliveryHeight(List<String> methods) =>
      methods.isEmpty ? 0 : 4 + 16 + 2 + methods.fold(0.0, (a, t) => a + _methodRow(t)) + (methods.length - 1) * 2 + 4;

  @override
  double height(BodyContext ctx) {
    final n = _actions(ctx).length + 1;
    return _deliveryHeight(_methods(ctx)) + 4 + n * 24 + (n - 1) * 2 + 4;
  }

  @override
  Map<String, double> sources(BodyContext ctx) {
    final top = _deliveryHeight(_methods(ctx)) + 4;
    final ids = [..._actions(ctx), '__timeout'];
    return {for (final (i, id) in ids.indexed) id: top + i * 26 + 12};
  }

  static String _capitalize(String s) =>
      s.split(' ').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');

  static Widget _row(String label) => SizedBox(
    height: 24,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Align(
        alignment: Alignment.centerRight,
        child: DifyText(label, DifyType.systemXsSemiboldUppercase, color: DifyColors.textSecondary),
      ),
    ),
  );

  @override
  Widget build(BuildContext context, BodyContext ctx) {
    final methods = _methods(ctx);
    final rows = [..._actions(ctx), 'Timeout'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (methods.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  child: DifyText(
                    'Delivery Method',
                    DifyType.system2xsMediumUppercase,
                    color: DifyColors.textTertiary,
                  ),
                ),
                const SizedBox(height: 2),
                for (final (i, type) in methods.indexed) ...[
                  if (i > 0) const SizedBox(height: 2),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Container(
                      height: _methodRow(type),
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: DifyColors.workflowBlockParmaBg,
                        borderRadius: BorderRadius.circular(DifyRadius.md),
                      ),
                      child: Row(
                        children: [
                          if (_hasTile(type)) ...[
                            Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: type == 'webapp'
                                    ? DifyColors.componentsIconBgIndigoSolid
                                    : DifyColors.componentsIconBgBlueSolid,
                                border: Border.all(color: DifyColors.dividerRegular),
                                borderRadius: BorderRadius.circular(DifyRadius.sm),
                              ),
                              child: RemixIcon(
                                type == 'webapp' ? 'robot-2-fill' : 'mail-send-fill',
                                size: 14,
                                color: DifyColors.textPrimaryOnSurface,
                              ),
                            ),
                            const SizedBox(width: 4),
                          ],
                          Flexible(
                            child: DifyText(
                              _capitalize(type),
                              DifyType.systemXsRegular,
                              color: DifyColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, label) in rows.indexed) ...[if (i > 0) const SizedBox(height: 2), _row(label)],
            ],
          ),
        ),
      ],
    );
  }
}

// MARK: - Triggers

/// The caption + value box of the schedule and webhook triggers: `mb-1 px-3 py-1`, caption `mb-1`, box `h-6.5
/// rounded-md bg-workflow-block-parma-bg px-2 text-xs text-text-secondary`, truncated.
class _CaptionValue extends StatelessWidget {
  const _CaptionValue(this.caption, this.value);
  final String caption;
  final String value;

  /// py-1 + caption 15 + mb-1 + box 26 + py-1 + mb-1.
  static const height = 4 + 15 + 4 + 26 + 4 + 4.0;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DifyText(caption, _caption, color: DifyColors.textTertiary),
        const SizedBox(height: 4),
        Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: DifyColors.workflowBlockParmaBg,
            borderRadius: BorderRadius.circular(DifyRadius.md),
          ),
          child: DifyText(value, DifyType.systemXsRegular, color: DifyColors.textSecondary),
        ),
      ],
    ),
  );
}

/// Schedule Trigger (nodes/trigger-schedule/node.tsx): "NEXT EXECUTION TIME" and the next run as
/// utils/execution-time-calculator.ts getNextExecutionTime computes it (en-US, no timezone suffix).
class TriggerScheduleBody extends NodeBody {
  const TriggerScheduleBody();

  @override
  bool get target => false;

  @override
  double height(BodyContext ctx) => _CaptionValue.height;

  @override
  Widget build(BuildContext context, BodyContext ctx) =>
      _CaptionValue('NEXT EXECUTION TIME', nextExecutionTime(ctx.node.config));

  static const _monthNames = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  static const _dayNames = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  static const _dayKeys = {'sun': 0, 'mon': 1, 'tue': 2, 'wed': 3, 'thu': 4, 'fri': 5, 'sat': 6};

  /// "Sunday, October 19, 2026, 12:00 AM" (weekday only for visual weekly schedules).
  static String _format(DateTime d, bool weekday) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final date = '${_monthNames[d.month - 1]} ${d.day}, ${d.year}';
    final time = '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
    return '${weekday ? '${_dayNames[d.weekday % 7]}, ' : ''}$date, $time';
  }

  /// "Now" as wall-clock time in the schedule's timezone, held in a UTC DateTime (no DST arithmetic).
  static DateTime _wallNow(String timezone, DateTime? now) {
    final n = now ?? (const {'UTC', 'Etc/UTC', 'GMT'}.contains(timezone) ? DateTime.now().toUtc() : DateTime.now());
    return DateTime.utc(n.year, n.month, n.day, n.hour, n.minute, n.second);
  }

  /// "h:mm AM" as (hour 0-23, minute).
  static (int, int) _time(String s) {
    final words = s.split(' ');
    final period = words.length > 1 ? words[1] : '';
    final parts = words.first.split(':');
    var hour = int.tryParse(parts.first) ?? 0;
    final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    if (period == 'PM' && hour != 12) hour += 12;
    if (period == 'AM' && hour == 12) hour = 0;
    return (hour, minute);
  }

  /// The card's text (getNextExecutionTime); [now] for tests.
  static String nextExecutionTime(Map<String, Value> data, {DateTime? now}) {
    final mode = _str(data['mode']);
    final frequency = data['frequency'] is VString ? _str(data['frequency']) : null;
    final timezone = _str(data['timezone']);
    final weekday = mode == 'visual' && frequency == 'weekly';
    final current = _wallNow(timezone, now);
    final today = DateTime.utc(current.year, current.month, current.day);
    DateTime? next;
    if (mode == 'cron') {
      final cron = _Cron.parse(_str(data['cron_expression']));
      if (cron == null) return '--';
      next = cron.next(current);
    } else {
      final config = data['visual_config'];
      final (hour, minute) = _time(_str(_at(config, 'time')).isEmpty ? '12:00 AM' : _str(_at(config, 'time')));
      DateTime at(int dayOffset, [int? h, int? m]) =>
          DateTime.utc(today.year, today.month, today.day + dayOffset, h ?? hour, m ?? minute);
      switch (frequency) {
        case 'hourly':
          final onMinute = switch (_at(config, 'on_minute')) {
            VInt(:final value) => value,
            VDouble(:final value) => value.toInt(),
            _ => 0,
          };
          next = at(0, current.hour + (current.minute >= onMinute ? 1 : 0), onMinute);
        case 'daily':
          next = at(at(0).isAfter(current) ? 0 : 1);
        case 'weekly':
          // Dify takes the first listed weekday that is valid (count 1 stops the loop there), not the earliest.
          final days = _at(config, 'weekdays') is VList ? _items(_at(config, 'weekdays')) : [const VString('sun')];
          for (final d in days) {
            final target = _dayKeys[_str(d)];
            if (target == null) continue;
            var offset = (target - today.weekday % 7 + 7) % 7;
            if (offset == 0 && !at(0).isAfter(current)) offset = 7;
            next = at(offset);
            break;
          }
        case 'monthly':
          final listed = _items(_at(config, 'monthly_days'));
          final days = {
            for (final d in listed.isEmpty ? [const VInt(1)] : listed)
              if (d is VInt) d.value else if (_str(d) == 'last') -1,
          };
          // Dify loops until it finds one; a bound keeps impossible days (e.g. 40) from spinning.
          for (var month = 0; next == null && month < 48; month++) {
            final first = DateTime.utc(today.year, today.month + month);
            final length = DateTime.utc(first.year, first.month + 1, 0).day;
            final candidates = [
              for (final d in days)
                if (d <= length) DateTime.utc(first.year, first.month, d == -1 ? length : d, hour, minute),
            ]..sort();
            next = candidates.where((c) => c.isAfter(current)).firstOrNull;
          }
        default:
          next = today;
      }
    }
    return _format(next ?? DateTime.utc(today.year, today.month, today.day, 12), weekday);
  }
}

/// A 5-field cron expression (or an `@` macro) as cron-parser reads it: lists, ranges, steps, month and weekday
/// names, `L` (last day of month), `<weekday>L` and `<weekday>#<n>`; day of month OR day of week when both are set.
class _Cron {
  _Cron(this._minutes, this._hours, this._months, this._dom, this._dow);

  final List<int> _minutes, _hours;
  final Set<int> _months;
  final bool Function(DateTime)? _dom, _dow; // null: `*` / `?`

  static const _macros = {
    '@yearly': '0 0 1 1 *',
    '@annually': '0 0 1 1 *',
    '@monthly': '0 0 1 * *',
    '@weekly': '0 0 * * 0',
    '@daily': '0 0 * * *',
    '@midnight': '0 0 * * *',
    '@hourly': '0 * * * *',
    '@minutely': '* * * * *',
    '@weekdays': '0 0 * * 1-5',
    '@weekends': '0 0 * * 0,6',
  };
  static const _monthNames = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };
  static const _dayNames = {'sun': 0, 'mon': 1, 'tue': 2, 'wed': 3, 'thu': 4, 'fri': 5, 'sat': 6};

  static _Cron? parse(String expression) {
    final e = expression.trim();
    if (e.isEmpty) return null;
    final fields = (e.startsWith('@') ? _macros[e.toLowerCase()] ?? '' : e).split(RegExp(r'\s+'));
    if (fields.length != 5) return null;
    final minutes = _values(fields[0], 0, 59),
        hours = _values(fields[1], 0, 23),
        months = _values(fields[3], 1, 12, _monthNames);
    final dom = _day(fields[2], false), dow = _day(fields[4], true);
    if (minutes == null || hours == null || months == null || dom == null || dow == null) return null;
    return _Cron(
      minutes.toList()..sort(),
      hours.toList()..sort(),
      months,
      const {'*', '?'}.contains(fields[2]) ? null : dom,
      const {'*', '?'}.contains(fields[4]) ? null : dow,
    );
  }

  static int? _value(String s, int lo, int hi, Map<String, int> names) {
    final v = int.tryParse(s) ?? names[s.toLowerCase()];
    return v != null && v >= lo && v <= hi ? v : null;
  }

  static Set<int>? _values(String field, int lo, int hi, [Map<String, int> names = const {}]) {
    final out = <int>{};
    for (final part in field.split(',')) {
      final slash = part.split('/');
      if (slash.length > 2) return null;
      final step = slash.length == 2 ? int.tryParse(slash[1]) : 1;
      if (step == null || step < 1) return null;
      final range = slash[0];
      int? a, b;
      if (range == '*' || range == '?') {
        (a, b) = (lo, hi);
      } else {
        final ends = range.split('-');
        if (ends.length > 2) return null;
        a = _value(ends.first, lo, hi, names);
        b = ends.length == 2 ? _value(ends.last, lo, hi, names) : (slash.length == 2 ? hi : a);
      }
      if (a == null || b == null || a > b) return null;
      for (var v = a; v <= b; v += step) {
        out.add(v);
      }
    }
    return out;
  }

  static int _length(DateTime d) => DateTime.utc(d.year, d.month + 1, 0).day;

  static bool Function(DateTime)? _day(String field, bool weekday) {
    final special = <bool Function(DateTime)>[];
    final plain = <String>[];
    for (final part in field.split(',')) {
      final m = RegExp(r'^(\w+?)(L|#([1-5]))$', caseSensitive: false).firstMatch(part);
      if (!weekday && part.toUpperCase() == 'L') {
        special.add((d) => d.day == _length(d));
      } else if (weekday && m != null) {
        final w = _value(m[1]!, 0, 7, _dayNames);
        if (w == null) return null;
        final n = m[3] == null ? null : int.parse(m[3]!);
        special.add(
          (d) => d.weekday % 7 == w % 7 && (n == null ? d.day + 7 > _length(d) : (d.day - 1) ~/ 7 + 1 == n),
        );
      } else {
        plain.add(part);
      }
    }
    final values = plain.isEmpty
        ? <int>{}
        : _values(plain.join(','), weekday ? 0 : 1, weekday ? 7 : 31, weekday ? _dayNames : const {});
    if (values == null) return null;
    final set = weekday ? {for (final v in values) v % 7} : values;
    return (d) => set.contains(weekday ? d.weekday % 7 : d.day) || special.any((s) => s(d));
  }

  bool _dayMatches(DateTime d) => switch ((_dom, _dow)) {
    (null, null) => true,
    (final dom?, null) => dom(d),
    (null, final dow?) => dow(d),
    (final dom?, final dow?) => dom(d) || dow(d),
  };

  /// The first matching minute after [after] (wall-clock time), searched over eight years.
  DateTime? next(DateTime after) {
    final start = DateTime.utc(after.year, after.month, after.day, after.hour, after.minute + 1);
    final first = DateTime.utc(start.year, start.month, start.day);
    for (var i = 0; i < 366 * 8; i++) {
      final day = DateTime.utc(first.year, first.month, first.day + i);
      if (!_months.contains(day.month) || !_dayMatches(day)) continue;
      for (final h in _hours) {
        for (final m in _minutes) {
          final t = DateTime.utc(day.year, day.month, day.day, h, m);
          if (!t.isBefore(start)) return t;
        }
      }
    }
    return null;
  }
}

/// Webhook Trigger (nodes/trigger-webhook/node.tsx): "URL" and the webhook URL, or "--".
class TriggerWebhookBody extends NodeBody {
  const TriggerWebhookBody();

  @override
  bool get target => false;

  @override
  double height(BodyContext ctx) => _CaptionValue.height;

  @override
  Widget build(BuildContext context, BodyContext ctx) {
    final url = _str(ctx['webhook_url']);
    return _CaptionValue('URL', url.isEmpty ? '--' : url);
  }
}

/// Plugin Trigger (nodes/trigger-plugin/node.tsx): without a subscription the "Disconnect" warning (NodeStatus),
/// otherwise one row per `config` key (key, formatted value; values mentioning "secret" masked).
class TriggerPluginBody extends NodeBody {
  const TriggerPluginBody();

  @override
  bool get target => false;

  /// The subscription list comes from the backend; a set `subscription_id` counts as valid.
  static bool _subscribed(BodyContext ctx) => _str(ctx['subscription_id']).isNotEmpty;

  static Map<String, Value> _config(BodyContext ctx) =>
      ctx['config'] is VMap ? (ctx['config']! as VMap).entries : const {};

  @override
  double height(BodyContext ctx) => _subscribed(ctx) ? _rowsBlock(_config(ctx).length) : _rowsBlock(1);

  /// formatConfigValue: scalars as text, arrays joined with '.', `{value}` unwrapped (other objects as JSON).
  static String format(Value? v, {bool unwrap = true}) => switch (v) {
    null || VNull() => '',
    VString(:final value) => value,
    VInt(:final value) => '$value',
    VDouble(:final value) => '$value',
    VBool(:final value) => '$value',
    VList(:final items) => items.map((i) => format(i, unwrap: false)).join('.'),
    VRef(:final ref) || VBroken(:final ref) => '${ref.node}.${ref.output}',
    VMap(:final entries) when unwrap => switch (entries['value']) {
      final VMap m => jsonEncode(m.toJson()),
      final inner => format(inner, unwrap: false),
    },
    final Value other => jsonEncode(other.toJson()),
  };

  @override
  Widget build(BuildContext context, BodyContext ctx) {
    if (!_subscribed(ctx)) {
      return _rowsColumn([
        Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: DifyColors.stateWarningHover,
            borderRadius: BorderRadius.circular(DifyRadius.md),
          ),
          child: Row(
            children: [
              DifyIcon('vender/solid/alertsAndFeedback/alert-triangle', size: 14, color: DifyColors.textWarning),
              SizedBox(width: 4),
              DifyText('Disconnect', DifyType.systemXsMedium, color: DifyColors.textWarning),
            ],
          ),
        ),
      ]);
    }
    return _rowsColumn([
      for (final MapEntry(:key, :value) in _config(ctx).entries)
        ParamRow(
          child: Row(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 100),
                child: DifyText(key, DifyType.systemXsMediumUppercase, color: DifyColors.textTertiary),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: DifyText(
                  format(value).contains('secret') ? '********' : format(value),
                  DifyType.systemXsRegular,
                  color: DifyColors.textSecondary,
                  align: TextAlign.right,
                ),
              ),
            ],
          ),
        ),
    ]);
  }
}

// MARK: - Knowledge pipeline

/// Data Source (nodes/data-source/node.tsx): no body (Dify only shows an install button for a missing plugin, which
/// needs the backend's plugin state). The "DATA SOURCE" tab behind the card is chrome.
class DataSourceBody extends NodeBody {
  const DataSourceBody();

  @override
  double height(BodyContext ctx) => 0;

  @override
  Widget build(BuildContext context, BodyContext ctx) => const SizedBox.shrink();
}

/// Empty Data Source (nodes/data-source-empty/index.tsx, its own React Flow node type, not BaseNode): the whole
/// card is `p-3` around a full-width primary "+ Add Data Source" button; no header, no handles.
class DataSourceEmptyBody extends NodeBody {
  const DataSourceEmptyBody();

  @override
  CardChrome get chrome => CardChrome.bodyOnly;

  @override
  bool get target => false;

  @override
  Map<String, double> sources(BodyContext ctx) => const {};

  @override
  double height(BodyContext ctx) => 12 + 32 + 12;

  @override
  Widget build(BuildContext context, BodyContext ctx) => Padding(
    padding: const EdgeInsets.all(12),
    child: Container(
      height: 32,
      decoration: BoxDecoration(
        color: DifyColors.componentsButtonPrimaryBg,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
        border: Border.all(color: DifyColors.componentsButtonPrimaryBorder, width: Css.hairline),
        boxShadow: DifyShadows.primaryButton,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          RemixIcon('add-line', size: 16, color: DifyColors.componentsButtonPrimaryText),
          const SizedBox(width: 4),
          Text(
            'Add Data Source',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              height: 16 / 13,
              color: DifyColors.componentsButtonPrimaryText,
              fontFamily: cardFontFamily,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Knowledge Base (nodes/knowledge-base/node.tsx): without a chunk structure one warning row; otherwise Chunks,
/// Index Method, Embedding Model (high quality only) and Retrieval Method rows, the one the first validation issue
/// (utils.ts getKnowledgeBaseValidationIssue) concerns in warning style with the issue's message.
class KnowledgeIndexBody extends NodeBody {
  const KnowledgeIndexBody();

  static const _settings = {
    'high_quality': 'High Quality',
    'economy': 'Economical',
    'semantic_search': 'Vector Search',
    'full_text_search': 'Full-Text Search',
    'hybrid_search': 'Hybrid Search',
    'keyword_search': 'Inverted Index',
  };

  /// The last segment of the chunks selector, null when it is empty.
  static String? _chunks(BodyContext ctx) => switch (ctx['index_chunk_variable_selector']) {
    VRef(:final ref) || VBroken(:final ref) => ref.output,
    VList(:final items) when items.isNotEmpty => _str(items.last),
    _ => null,
  };

  /// The first validation issue's message, '' for none. Model lists come from the backend: a configured embedding
  /// or rerank model counts as available.
  static String _issue(BodyContext ctx) {
    final retrieval = ctx['retrieval_model'];
    final rerank = _at(retrieval, 'reranking_model');
    if (_str(ctx['chunk_structure']).isEmpty) return 'Chunk structure is required';
    if (_chunks(ctx) == null) return 'Chunks variable is required';
    if (_str(ctx['indexing_technique']).isEmpty) return 'Index method is required';
    if (_str(ctx['indexing_technique']) == 'high_quality' &&
        (_str(ctx['embedding_model']).isEmpty || _str(ctx['embedding_model_provider']).isEmpty)) {
      return 'Embedding model not configured';
    }
    if (_str(_at(retrieval, 'search_method')).isEmpty) return 'Retrieval setting is required';
    if (_at(retrieval, 'reranking_enable') case VBool(value: true)
        when _str(_at(rerank, 'reranking_provider_name')).isEmpty ||
            _str(_at(rerank, 'reranking_model_name')).isEmpty) {
      return 'Reranking model is required';
    }
    return '';
  }

  static bool _highQuality(BodyContext ctx) => _str(ctx['indexing_technique']) == 'high_quality';

  @override
  double height(BodyContext ctx) {
    if (_str(ctx['chunk_structure']).isEmpty) return _rowsBlock(1);
    return _rowsBlock(_highQuality(ctx) ? 4 : 3);
  }

  static BoxDecoration _decoration(bool warning) => BoxDecoration(
    color: warning ? DifyColors.stateWarningHover : DifyColors.workflowBlockParmaBg,
    border: warning ? Border.all(color: DifyColors.stateWarningActive, width: Css.hairline) : null,
    borderRadius: BorderRadius.circular(DifyRadius.md),
  );

  static Widget _row(String label, String value, {bool warning = false}) => Container(
    height: 24,
    padding: const EdgeInsets.symmetric(horizontal: 6),
    decoration: _decoration(warning),
    child: Row(
      children: [
        DifyText(label, DifyType.systemXsMediumUppercase, color: DifyColors.textTertiary),
        const SizedBox(width: 8),
        Expanded(
          child: DifyText(
            value,
            DifyType.systemXsMedium,
            color: warning ? DifyColors.textWarning : DifyColors.textSecondary,
            align: TextAlign.right,
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context, BodyContext ctx) {
    final issue = _issue(ctx);
    if (_str(ctx['chunk_structure']).isEmpty) {
      return _rowsColumn([
        Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: _decoration(true),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 4,
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  color: DifyColors.textWarningSecondary,
                  borderRadius: BorderRadius.circular(DifyRadius.xs),
                ),
              ),
              Expanded(child: DifyText(issue, DifyType.systemXsMedium, color: DifyColors.textWarning)),
            ],
          ),
        ),
      ]);
    }
    final chunksWarning = issue == 'Chunks variable is required';
    final indexWarning = issue == 'Index method is required';
    final retrievalWarning = const {
      'Retrieval setting is required',
      'Reranking model is required',
    }.contains(issue);
    final model = _str(ctx['embedding_model']);
    final modelSet = model.isNotEmpty && _str(ctx['embedding_model_provider']).isNotEmpty;
    return _rowsColumn([
      _row('Chunks', chunksWarning ? issue : _chunks(ctx) ?? '-', warning: chunksWarning),
      _row(
        'Index Method',
        indexWarning ? issue : _settings[_str(ctx['indexing_technique'])] ?? '-',
        warning: indexWarning,
      ),
      if (_highQuality(ctx)) _row('Embedding Model', modelSet ? model : 'Configure model', warning: !modelSet),
      _row(
        'Retrieval Method',
        retrievalWarning ? issue : _settings[_str(_at(ctx['retrieval_model'], 'search_method'))] ?? '-',
        warning: retrievalWarning,
      ),
    ]);
  }
}

// MARK: - Start placeholder, container children

/// Workflow start placeholder (nodes/start-placeholder/node.tsx): a parameter box with the collapsed hint. No
/// handles at all.
class StartPlaceholderBody extends NodeBody {
  const StartPlaceholderBody();

  /// Dify shows "Pick a start node from the right panel" while the node is selected; the body has no selection.
  static const text = 'Click to configure the start node';

  // Card 240 - border 2 - px-2.5 20 - px-1.5 12.
  static const _textWidth = 206.0;

  @override
  bool get target => false;

  @override
  Map<String, double> sources(BodyContext ctx) => const {};

  /// py-1 + py-1.25 + text + py-1.25 + py-1.
  @override
  double height(BodyContext ctx) =>
      4 + 5 + textHeight(text, difyStyle(DifyType.systemXsRegular, DifyColors.textTertiary), _textWidth) + 5 + 4;

  @override
  Widget build(BuildContext context, BodyContext ctx) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      decoration: BoxDecoration(
        color: DifyColors.workflowBlockParmaBg,
        borderRadius: BorderRadius.circular(DifyRadius.md),
      ),
      child: DifyText(text, DifyType.systemXsRegular, color: DifyColors.textTertiary, maxLines: null),
    ),
  );
}

/// Exit Loop (simple-node/index.tsx, the `custom-simple` node, not BaseNode): header only, no body, no description,
/// a target handle and no source handle.
class LoopEndBody extends NodeBody {
  const LoopEndBody();

  @override
  CardChrome get chrome => CardChrome.simple;

  @override
  Map<String, double> sources(BodyContext ctx) => const {};

  @override
  double height(BodyContext ctx) => 0;

  @override
  Widget build(BuildContext context, BodyContext ctx) => const SizedBox.shrink();
}

/// The content of the 44 x 44 start node inside an iteration or loop (inside its 1 px border): the 24 px blue-brand
/// circle with RiHome5Fill; the `source` handle centred on the right edge, no target.
abstract class _ContainerStartBody extends NodeBody {
  const _ContainerStartBody();

  @override
  bool get target => false;

  @override
  Map<String, double> sources(BodyContext ctx) => const {'source': 21};

  @override
  double height(BodyContext ctx) => 42;

  @override
  Widget build(BuildContext context, BodyContext ctx) =>
      const SizedBox(height: 42, child: Center(child: ContainerStartIcon()));
}

/// The start node's 24 px blue-brand circle with RiHome5Fill (iteration-start / loop-start's TooltipTrigger).
class ContainerStartIcon extends StatelessWidget {
  const ContainerStartIcon({super.key});

  @override
  Widget build(BuildContext context) => Container(
    width: 24,
    height: 24,
    decoration: BoxDecoration(
      color: DifyColors.utilColorsBlueBrandBlueBrand500,
      shape: BoxShape.circle,
      border: Border.all(color: DifyColors.componentsPanelBorderSubtle, width: Css.hairline),
    ),
    child: Center(child: RemixIcon('home-5-fill', size: 12, color: DifyColors.textPrimaryOnSurface)),
  );
}

/// IterationStartNodeDumb / LoopStartNodeDumb: the start node drawn inside a container that is not on the canvas
/// yet (the candidate being placed): `relative top-5.25 left-4.25 size-11 rounded-2xl border
/// border-workflow-block-border bg-workflow-block-bg`, no shadow and no source handle.
class ContainerStartNodeDumb extends StatelessWidget {
  const ContainerStartNodeDumb({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 17, top: 21),
    child: Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: DifyColors.workflowBlockBg,
        borderRadius: BorderRadius.circular(DifyRadius.xxl),
        border: Border.all(color: DifyColors.workflowBlockBorder),
      ),
      alignment: Alignment.center,
      child: const ContainerStartIcon(),
    ),
  );
}

/// Iteration Start (nodes/iteration-start/index.tsx, `custom-iteration-start`): see [_ContainerStartBody]; the card
/// has shadow-xs.
class IterationStartBody extends _ContainerStartBody {
  const IterationStartBody();

  @override
  CardChrome get chrome => CardChrome.marker;
}

/// Loop Start (nodes/loop-start/index.tsx, `custom-loop-start`): see [_ContainerStartBody]; the card has no shadow.
class LoopStartBody extends _ContainerStartBody {
  const LoopStartBody();

  @override
  CardChrome get chrome => CardChrome.flatMarker;
}
