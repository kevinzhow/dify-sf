/// nodes/trigger-schedule default.ts (defaultValue, checkValid) and use-config.ts (the frontend defaults and the
/// change handlers) as pure functions over Dify's node `data`: each handler returns the data `setInputs` writes.
library;

import '../../../../header/checklist/node_validators.dart' show ChecklistTranslate;
import 'cron_parser.dart';
import 'execution_time_calculator.dart';
import 'schedule_timezone.dart';

typedef Json = Map<String, Object?>;

/// getDefaultVisualConfig (constants.ts).
Json getDefaultVisualConfig() => {
  'time': '12:00 AM',
  'weekdays': ['sun'],
  'on_minute': 0,
  'monthly_days': [1],
};

/// The node's defaultValue (getDefaultScheduleConfig + an empty cron expression).
Json triggerScheduleDefaultValue() => {
  'mode': 'visual',
  'frequency': 'daily',
  'visual_config': getDefaultVisualConfig(),
  'cron_expression': '',
};

bool _truthy(Object? v) => v != null && v != false && v != '' && v != 0;

// ---- use-config.ts --------------------------------------------------------------------------------------------

/// `frontendPayload`: [data] with mode, frequency, timezone (the account's [profileTimezone], else UTC) and the
/// visual config filled in. This is the `inputs` every handler spreads, so the defaults are stored on the first edit.
Json scheduleInputs(Json data, {String? profileTimezone}) => {
  ...data,
  'mode': _truthy(data['mode']) ? data['mode'] : 'visual',
  'frequency': _truthy(data['frequency']) ? data['frequency'] : 'daily',
  'timezone': _truthy(data['timezone'])
      ? data['timezone']
      : (profileTimezone != null && profileTimezone.isNotEmpty ? profileTimezone : 'UTC'),
  'visual_config': {...getDefaultVisualConfig(), ..._map(data['visual_config'])},
};

Json _map(Object? v) => v is Map<String, Object?> ? v : const {};

Json handleModeChange(Json inputs, String mode) => {...inputs, 'mode': mode};

Json handleFrequencyChange(Json inputs, String frequency) {
  final config = _map(inputs['visual_config']);
  return {
    ...inputs,
    'frequency': frequency,
    'visual_config': {
      ...config,
      if (frequency == 'hourly') 'on_minute': config['on_minute'] ?? 0,
    },
    'cron_expression': null,
  };
}

Json handleCronExpressionChange(Json inputs, String value) => {
  ...inputs,
  'cron_expression': value,
  'frequency': null,
  'visual_config': null,
};

Json _visual(Json inputs, String key, Object? value, {bool clearCron = true}) => {
  ...inputs,
  'visual_config': {..._map(inputs['visual_config']), key: value},
  if (clearCron) 'cron_expression': null,
};

Json handleWeekdaysChange(Json inputs, List<String> weekdays) => _visual(inputs, 'weekdays', weekdays);
Json handleTimeChange(Json inputs, String time) => _visual(inputs, 'time', time);
Json handleOnMinuteChange(Json inputs, int onMinute) => _visual(inputs, 'on_minute', onMinute);

/// The panel's monthly-days change: it does not clear the cron expression.
Json handleMonthlyDaysChange(Json inputs, List<Object> days) => _visual(inputs, 'monthly_days', days, clearCron: false);

// ---- default.ts checkValid ------------------------------------------------------------------------------------

final _timeRegex = RegExp(r'^(0?\d|1[0-2]):[0-5]\d (AM|PM)$');

bool _isValidTimeFormat(String time) {
  if (!_timeRegex.hasMatch(time)) return false;
  final [timePart, period] = time.split(' ');
  final [hour, minute] = timePart.split(':');
  final h = int.parse(hour), m = int.parse(minute);
  return h >= 1 && h <= 12 && m >= 0 && m <= 59 && (period == 'AM' || period == 'PM');
}

String _required(ChecklistTranslate t, String fieldKey) =>
    t('workflow', 'errorMsg.fieldRequired', {'field': t('workflow', 'nodes.triggerSchedule.$fieldKey')});

String _hourly(Json config, ChecklistTranslate t) {
  final m = config['on_minute'];
  // `undefined`, or a number out of range (JavaScript compares null as 0).
  if (!config.containsKey('on_minute') || (m is num && (m < 0 || m > 59))) {
    return t('workflow', 'nodes.triggerSchedule.invalidOnMinute');
  }
  return '';
}

String _daily(Json config, ChecklistTranslate t) {
  final time = config['time'];
  if (!_truthy(time)) return _required(t, 'time');
  if (time is! String || !_isValidTimeFormat(time)) return t('workflow', 'nodes.triggerSchedule.invalidTimeFormat');
  return '';
}

String _weekly(Json config, ChecklistTranslate t) {
  final daily = _daily(config, t);
  if (daily.isNotEmpty) return daily;
  final days = config['weekdays'];
  if (days is! List || days.isEmpty) return _required(t, 'weekdays');
  for (final day in days) {
    if (!const ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'].contains(day)) {
      return t('workflow', 'nodes.triggerSchedule.invalidWeekday', {'weekday': day});
    }
  }
  return '';
}

String _monthly(Json config, ChecklistTranslate t) {
  final daily = _daily(config, t);
  if (daily.isNotEmpty) return daily;
  final days = config['monthly_days'];
  if (days is! List || days.isEmpty) return _required(t, 'monthlyDay');
  for (final day in days) {
    if (day != 'last' && (day is! num || day < 1 || day > 31)) {
      return t('workflow', 'nodes.triggerSchedule.invalidMonthlyDay');
    }
  }
  return '';
}

String _visualConfig(Json payload, ChecklistTranslate t) {
  final config = payload['visual_config'];
  if (config is! Map<String, Object?>) return _required(t, 'visualConfig');
  return switch (payload['frequency']) {
    'hourly' => _hourly(config, t),
    'daily' => _daily(config, t),
    'weekly' => _weekly(config, t),
    'monthly' => _monthly(config, t),
    _ => t('workflow', 'nodes.triggerSchedule.invalidFrequency'),
  };
}

/// checkValid of the schedule trigger (NodeCheckValid): the first problem of [payload], '' when valid. [clock] is
/// for tests (the last check computes the next run).
String checkValidTriggerSchedule(
  Json payload,
  ChecklistTranslate t,
  Json? moreData, {
  ScheduleClock clock = const ScheduleClock(),
}) {
  var error = '';
  if (!_truthy(payload['mode'])) error = _required(t, 'mode');
  final timezone = payload['timezone'];
  if (error.isEmpty && _truthy(timezone) && (timezone is! String || !isKnownTimezone(timezone))) {
    error = t('workflow', 'nodes.triggerSchedule.invalidTimezone');
  }
  if (error.isEmpty) {
    if (payload['mode'] == 'cron') {
      final cron = payload['cron_expression'];
      if (cron is! String || cron.trim().isEmpty) {
        error = _required(t, 'cronExpression');
      } else if (!isValidCronExpression(cron)) {
        error = t('workflow', 'nodes.triggerSchedule.invalidCronExpression');
      }
    } else if (payload['mode'] == 'visual') {
      error = !_truthy(payload['frequency']) ? _required(t, 'frequencyLabel') : _visualConfig(payload, t);
    }
  }
  if (error.isEmpty) {
    try {
      if (getNextExecutionTimes(payload, 1, clock).isEmpty) {
        error = t('workflow', 'nodes.triggerSchedule.noValidExecutionTime');
      }
    } on Object {
      error = t('workflow', 'nodes.triggerSchedule.executionTimeCalculationError');
    }
  }
  return error;
}
