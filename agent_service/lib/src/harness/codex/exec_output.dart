// Portions derived from OpenAI Codex (https://github.com/openai/codex,
// rust-v0.163.0, codex-rs/core/src/tools/context.rs (`ExecCommandToolOutput`),
// codex-rs/core/src/tools/mod.rs (`format_exec_output_for_model`),
// codex-rs/core/src/unified_exec/{mod,head_tail_buffer}.rs), Copyright 2025
// OpenAI, licensed under the Apache License 2.0. Modified for dify-sf: ported
// to Dart; output comes from shellctl jobs.

/// The text Codex returns to the model for `exec_command`, `write_stdin` and
/// `apply_patch`.
library;

import 'dart:convert';
import 'dart:math';

import 'truncation.dart';

/// `DEFAULT_MAX_OUTPUT_TOKENS`.
const defaultMaxOutputTokens = 10000;

/// `UNIFIED_EXEC_OUTPUT_MAX_BYTES`: output collected per call (head and
/// tail halves).
const unifiedExecOutputMaxBytes = 1024 * 1024;

/// `MIN_YIELD_TIME_MS`, `MAX_YIELD_TIME_MS`, `MIN_EMPTY_YIELD_TIME_MS`,
/// `DEFAULT_MAX_BACKGROUND_TERMINAL_TIMEOUT_MS`.
const minYieldTimeMs = 250;
const maxYieldTimeMs = 30000;
const minEmptyYieldTimeMs = 5000;
const maxBackgroundTerminalTimeoutMs = 300000;

/// Default `yield_time_ms` of `exec_command` and of a non-empty
/// `write_stdin`.
const defaultExecYieldTimeMs = 10000;
const defaultWriteStdinYieldTimeMs = 250;

/// `MAX_UNIFIED_EXEC_PROCESSES`.
const maxUnifiedExecProcesses = 64;

/// `UNIFIED_EXEC_ENV`: set for every command.
const unifiedExecEnv = {
  'NO_COLOR': '1',
  'TERM': 'dumb',
  'LANG': 'C.UTF-8',
  'LC_CTYPE': 'C.UTF-8',
  'LC_ALL': 'C.UTF-8',
  'COLORTERM': '',
  'PAGER': 'cat',
  'GIT_PAGER': 'cat',
  'GH_PAGER': 'cat',
  'CODEX_CI': '1',
};

/// `clamp_yield_time` (not Windows).
int clampYieldTime(int ms) => ms.clamp(minYieldTimeMs, maxYieldTimeMs);

/// The yield of a `write_stdin`: empty polls wait at least 5 s and at most
/// the background timeout; writes at most 30 s.
int writeStdinYieldTime(int ms, {required bool empty}) {
  final t = max(ms, minYieldTimeMs);
  return empty
      ? t.clamp(minEmptyYieldTimeMs, maxBackgroundTerminalTimeoutMs)
      : min(t, maxYieldTimeMs);
}

/// `format_output_omission_marker`.
String outputOmissionMarker(int omittedBytes) =>
    '... $omittedBytes bytes omitted ...';

/// `generate_chunk_id`: six hex digits.
String generateChunkId([Random? random]) {
  final r = random ?? Random();
  return List.generate(6, (_) => r.nextInt(16).toRadixString(16)).join();
}

/// A `HeadTailBuffer` of [maxBytes]: the first half and the last half of
/// what was pushed, and how much was dropped between them.
class HeadTailBuffer {
  HeadTailBuffer({this.maxBytes = unifiedExecOutputMaxBytes});
  final int maxBytes;
  final List<int> _head = [];
  List<int> _tail = [];
  int omittedBytes = 0;

  int get _headBudget => maxBytes ~/ 2;
  int get _tailBudget => maxBytes - _headBudget;
  int get totalBytes => _head.length + _tail.length + omittedBytes;

  void push(List<int> chunk) {
    final int room = max(0, _headBudget - _head.length);
    final int toHead = min(room, chunk.length);
    _head.addAll(chunk.sublist(0, toHead));
    final rest = chunk.sublist(toHead);
    final int excess = max(
      0,
      rest.length - max<int>(0, _tailBudget - _tail.length),
    );
    omittedBytes += excess;
    if (excess <= _tail.length) {
      _tail = [..._tail.sublist(excess), ...rest];
    } else {
      _tail = rest.sublist(excess - _tail.length);
    }
  }

  List<int> toBytesWithOmissionMarker() {
    if (omittedBytes == 0) return [..._head, ..._tail];
    return [
      ..._head,
      0x0a,
      ...utf8.encode(outputOmissionMarker(omittedBytes)),
      0x0a,
      ..._tail,
    ];
  }
}

/// `ExecCommandToolOutput` as the model sees it (`response_text`).
class ExecCommandOutput {
  ExecCommandOutput({
    required this.chunkId,
    required this.wallTime,
    required this.rawOutput,
    required this.truncationPolicy,
    this.maxOutputTokens,
    this.processId,
    this.exitCode,
    this.originalTokenCount,
    this.outputOmittedBytes,
  });

  final String chunkId;
  final Duration wallTime;
  final List<int> rawOutput;

  /// The model's policy (`model_info.truncation_policy`).
  final TruncationPolicy truncationPolicy;
  final int? maxOutputTokens;

  /// The session ID while the process runs.
  final int? processId;
  final int? exitCode;
  final int? originalTokenCount;
  final int? outputOmittedBytes;

  String get _text => utf8.decode(rawOutput, allowMalformed: true);

  TruncationPolicy get _modelOutputPolicy {
    final requested = TruncationPolicy.tokens(
      maxOutputTokens ?? defaultMaxOutputTokens,
    );
    return requested.byteBudget < truncationPolicy.byteBudget
        ? requested
        : truncationPolicy;
  }

  String _truncatedWith(TruncationPolicy policy) {
    final text = _text;
    final omitted = outputOmittedBytes;
    if (omitted == null || omitted == 0) {
      return formattedTruncateText(text, policy);
    }
    final marker = outputOmissionMarker(omitted);
    if (utf8.encode(text).length <= policy.byteBudget) {
      return text.contains(marker) ? text : '$marker\n$text';
    }
    final original = originalTokenCount ?? approxTokenCount(text);
    final truncated = truncateText(text, policy);
    final notice = truncated.contains(marker) ? '' : '$marker\n';
    return 'Warning: truncated output (original token count: $original)\n'
        '$notice\n$truncated';
  }

  String get header {
    final sections = <String>[
      if (chunkId.isNotEmpty) 'Chunk ID: $chunkId',
      'Wall time: ${(wallTime.inMicroseconds / 1e6).toStringAsFixed(4)} seconds',
      if (exitCode != null) 'Process exited with code $exitCode',
      if (processId != null) 'Process running with session ID $processId',
      if (originalTokenCount != null)
        'Original token count: $originalTokenCount',
      'Output:',
    ];
    return sections.join('\n');
  }

  /// `response_text`: the header and the output, truncated so the whole
  /// fits the serialization budget (no second truncation in history).
  String responseText() {
    final h = header;
    final budget = max(
      0,
      withSerializationAllowance(truncationPolicy).byteBudget -
          (utf8.encode(h).length + 1),
    );
    var policy = _modelOutputPolicy;
    var output = _truncatedWith(policy);
    while (utf8.encode(output).length > budget && policy.byteBudget > 0) {
      final excess = utf8.encode(output).length - budget;
      policy = policy.tokens
          ? TruncationPolicy.tokens(
              max(0, policy.limit - TruncationPolicy.bytes(excess).tokenBudget),
            )
          : TruncationPolicy.bytes(max(0, policy.limit - excess));
      output = _truncatedWith(policy);
    }
    return '$h\n$output';
  }
}

/// Rust's `{}` for an `f32` rounded to one decimal (`1.0` prints `1`).
String _rustShortDecimal(double v) {
  final r = (v * 10).round() / 10;
  return r == r.truncateToDouble() ? '${r.toInt()}' : '$r';
}

/// `format_exec_output_for_model`: exit code, wall time (one decimal), the
/// line count when truncation changed it, and the truncated output.
String formatExecOutputForModel({
  required int exitCode,
  required Duration duration,
  required String output,
  required TruncationPolicy policy,
}) {
  final total = rustLineCount(output);
  final formatted = truncateText(output, policy);
  return [
    'Exit code: $exitCode',
    'Wall time: ${_rustShortDecimal(duration.inMicroseconds / 1e6)} seconds',
    if (total != rustLineCount(formatted)) 'Total output lines: $total',
    'Output:',
    formatted,
  ].join('\n');
}
