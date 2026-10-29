import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Bounded local run state, separate from the collaborative workflow document.
@immutable
class AgentProgressView {
  const AgentProgressView({
    required this.run,
    required this.cursor,
    this.calls = 0,
    this.maximum = 50,
    this.summary = '',
    this.imageJson,
    this.partialReason,
  });
  final String run, summary;
  final int cursor, calls, maximum;
  final String? imageJson, partialReason;
  static Map<String, Object?> map(Object? value) => value is Map ? value.cast<String, Object?>() : const {};
  factory AgentProgressView.parse(Map<String, Object?> value) => AgentProgressView(
    run: '${value['run'] ?? ''}',
    cursor: value['cursor'] as int? ?? 0,
    calls: value['calls'] as int? ?? 0,
    maximum: value['maximum'] as int? ?? 50,
    summary: '${value['summary'] ?? ''}',
    imageJson: value['image_json'] as String?,
    partialReason: value['partial_reason'] as String?,
  );
  Map<String, Object?> get json => {
    'run': run,
    'cursor': cursor,
    'calls': calls,
    'maximum': maximum,
    'summary': summary,
    if (imageJson != null) 'image_json': imageJson,
    if (partialReason != null) 'partial_reason': partialReason,
  };
  Map<String, Object?>? get image => imageJson == null ? null : map(jsonDecode(imageJson!));
  double get height => imageJson == null ? 104 : 236;
  AgentProgressView get forLayout => AgentProgressView(run: '', cursor: 0, imageJson: imageJson == null ? null : '{}');

  static AgentProgressView? advance(AgentProgressView? old, Map<String, Object?> log) {
    final key = log['message_id'];
    if (key is! String || key.length > 256) return old;
    final separator = key.lastIndexOf(':');
    if (separator <= 0) return old;
    final run = key.substring(0, separator), cursor = int.tryParse(key.substring(separator + 1));
    if (cursor == null || cursor < 0 || old?.run == run && cursor <= old!.cursor) return old;
    final kind = map(log['metadata'])['event'], data = map(log['data']);
    if (!const {
      'run_started',
      'thought',
      'commentary',
      'plan',
      'model_retry',
      'tool_call',
      'model_call',
      'progress',
      'budget_notice',
      'error',
    }.contains(kind)) {
      return old;
    }
    var calls = old?.run == run ? old!.calls : 0;
    var maximum = old?.maximum ?? 50;
    var summary = old?.summary ?? '';
    var image = old?.imageJson;
    String bounded(Object? value, [int max = 240]) {
      final s = value is String ? value : '';
      return s.runes.take(max).map(String.fromCharCode).join();
    }

    if (kind == 'run_started') {
      final n = data['max_turns'];
      if (n is int && n >= 1 && n <= 1000) maximum = n;
      summary = '';
    } else if (kind == 'model_call') {
      final index = data['call_index'];
      calls = index is int && index > 0 && index <= 1000 ? index : calls + 1;
    } else if (kind == 'thought' || kind == 'commentary') {
      summary = bounded(data['text']);
    } else if (kind == 'plan') {
      final plan = data['plan'];
      final steps = plan is List ? plan.map(map).toList() : const <Map<String, Object?>>[];
      final active = steps.where((step) => step['status'] == 'in_progress');
      summary = bounded(active.isNotEmpty ? active.first['step'] : data['explanation']);
    } else if (kind == 'model_retry') {
      summary = bounded(data['message']);
    } else if (kind == 'tool_call') {
      final name = bounded(data['name'], 64), input = map(data['input']);
      final command = bounded(input['script'] ?? input['command'], 120).split('\n').first;
      summary = '$name${command.isEmpty ? '' : ': $command'}';
    } else if (kind == 'error') {
      summary = bounded(data['message'] ?? data['error_type']);
    } else if (kind == 'progress') {
      summary = bounded(data['caption'] ?? data['message']);
      image = data['file_unavailable'] == true ? jsonEncode({'url': '', 'name': 'Progress image'}) : null;
      final file = map(data['file']);
      final url = Uri.tryParse('${file['url'] ?? ''}'), mime = file['mime_type'];
      if (file['dify_model_identity'] == '__dify__file__' &&
          mime is String &&
          const {'image/png', 'image/jpeg', 'image/webp'}.contains(mime) &&
          url != null &&
          const {'http', 'https'}.contains(url.scheme) &&
          url.host.isNotEmpty &&
          url.userInfo.isEmpty &&
          '${file['url']}'.length <= 8192) {
        // Only the server-normalized file shape is accepted, never an event's
        // raw upload receipt, host path or arbitrary remote image URL.
        image = jsonEncode({
          'url': file['url'],
          'name': file['filename'] ?? file['name'] ?? 'Progress image',
          'mime_type': mime,
          'id': file['related_id'] ?? file['upload_file_id'],
        });
      }
    }
    return AgentProgressView(
      run: run,
      cursor: cursor,
      calls: calls.clamp(0, 1000),
      maximum: maximum,
      summary: summary,
      imageJson: image,
    );
  }

  static AgentProgressView? finished(AgentProgressView? old, Map<String, Object?> metadata) {
    var view = old;
    final logs = metadata['agent_log'];
    if (logs is List) {
      for (final log in logs.whereType<Map>()) {
        view = advance(view, log.cast<String, Object?>());
      }
    }
    if (map(metadata['agent_session'])['saved'] == false) {
      return AgentProgressView(
        run: view?.run ?? '',
        cursor: view?.cursor ?? 0,
        calls: view?.calls ?? 0,
        maximum: view?.maximum ?? 50,
        summary: view?.summary ?? '',
        imageJson: view?.imageJson,
        partialReason: 'session_save_failed',
      );
    }
    final reason = map(metadata['agent_partial'])['reason'];
    if (!const {'max_turns', 'timeout'}.contains(reason)) return view;
    return AgentProgressView(
      run: view?.run ?? '',
      cursor: view?.cursor ?? 0,
      calls: view?.calls ?? 0,
      maximum: view?.maximum ?? 50,
      summary: view?.summary ?? '',
      imageJson: view?.imageJson,
      partialReason: reason as String,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AgentProgressView &&
      run == other.run &&
      cursor == other.cursor &&
      calls == other.calls &&
      maximum == other.maximum &&
      summary == other.summary &&
      imageJson == other.imageJson &&
      partialReason == other.partialReason;
  @override
  int get hashCode => Object.hash(run, cursor, calls, maximum, summary, imageJson, partialReason);
}
