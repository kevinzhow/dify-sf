// Portions derived from OpenAI Codex (https://github.com/openai/codex,
// rust-v0.163.0, codex-rs/core/src/unified_exec/{mod,process_manager,errors}.rs
// and codex-rs/core/src/tools/handlers/unified_exec/*.rs), Copyright 2025
// OpenAI, licensed under the Apache License 2.0. Modified for dify-sf: the
// processes are shellctl jobs of the execution's sandbox; approvals,
// sandbox overrides and network denial are not ported (danger-full-access
// with approval `never`). See third_party/codex/PATCHES.md.

/// `exec_command` and `write_stdin` (Codex's unified exec) over shellctl.
library;

import 'dart:convert';
import 'dart:math';

import '../../sandbox/paths.dart' show shellQuote;
import '../../sandbox/shellctl.dart';
import 'apply_patch.dart' show resolvePatchPath;
import 'exec_output.dart';
import 'truncation.dart';

/// A tool result: the text for the model, and whether it is an error
/// (`RespondToModel`).
typedef ToolText = ({String text, bool error});

class _Process {
  _Process(this.jobId, this.tty, this.offset);
  final String jobId;
  final bool tty;
  int offset;
  int lastUsed = 0;
}

/// The shellctl operations the exec tools use (a [ShellctlClient] in
/// production).
abstract class ExecBackend {
  Future<JobResult> run(
    String script, {
    required String cwd,
    required Map<String, String> env,
    required num timeout,
    required String mode,
  });
  Future<JobResult> wait(
    String jobId, {
    required int offset,
    required num timeout,
  });
  Future<JobResult> input(
    String jobId,
    String text, {
    required int offset,
    required num timeout,
  });
  Future<JobResult> terminate(String jobId);
}

class ShellctlExecBackend implements ExecBackend {
  ShellctlExecBackend(this.client);
  final ShellctlClient client;

  @override
  Future<JobResult> run(
    String script, {
    required String cwd,
    required Map<String, String> env,
    required num timeout,
    required String mode,
  }) => client.run(script, cwd: cwd, env: env, timeout: timeout, mode: mode);

  @override
  Future<JobResult> wait(
    String jobId, {
    required int offset,
    required num timeout,
  }) => client.wait(jobId, offset: offset, timeout: timeout);

  @override
  Future<JobResult> input(
    String jobId,
    String text, {
    required int offset,
    required num timeout,
  }) => client.input(jobId, text, offset: offset, timeout: timeout);

  @override
  Future<JobResult> terminate(String jobId) =>
      client.terminate(jobId, graceSeconds: 0);
}

/// The unified exec process manager of one run.
class UnifiedExec {
  UnifiedExec(
    this.backend, {
    required this.env,
    required this.truncationPolicy,
    required this.track,
    this.workspace = '/workspace',
    Random? random,
    DateTime Function()? now,
  }) : _random = random ?? Random(),
       _now = now ?? DateTime.now;

  final ExecBackend backend;

  /// The job environment (profile and user env, `HOME`).
  final Map<String, String> env;
  final TruncationPolicy truncationPolicy;

  /// Called for every job and offset (the shell session terminates and
  /// deletes them when the run ends).
  final void Function(String jobId, int offset, bool done) track;
  final String workspace;
  final Random _random;
  final DateTime Function() _now;
  final Map<int, _Process> _processes = {};
  int _clock = 0;

  /// Session IDs in use (for tests).
  Iterable<int> get sessionIds => _processes.keys;

  int _allocateId() {
    while (true) {
      final id = 1000 + _random.nextInt(99000);
      if (!_processes.containsKey(id)) return id;
    }
  }

  static num? _num(Object? v) => v is num ? v : null;

  /// Prunes the least recently used process when the table is full.
  Future<void> _prune() async {
    if (_processes.length < maxUnifiedExecProcesses) return;
    final victim = _processes.entries.reduce(
      (a, b) => a.value.lastUsed <= b.value.lastUsed ? a : b,
    );
    _processes.remove(victim.key);
    try {
      await backend.terminate(victim.value.jobId);
    } on ShellctlException {
      // Already gone.
    }
  }

  /// Reads output from [first] on until the job ended or [deadline]
  /// passed; all of it into a head/tail buffer.
  Future<(JobResult, HeadTailBuffer)> _collect(
    JobResult first,
    DateTime deadline,
  ) async {
    final buffer = HeadTailBuffer();
    var r = first;
    buffer.push(utf8.encode(r.output));
    while (true) {
      final remaining = deadline.difference(_now());
      final more = r.truncated;
      if (!more && (r.done || remaining <= Duration.zero)) break;
      r = await backend.wait(
        r.jobId,
        offset: r.offset,
        timeout: more || r.done ? 0 : max(0, remaining.inMilliseconds) / 1000,
      );
      buffer.push(utf8.encode(r.output));
    }
    return (r, buffer);
  }

  ExecCommandOutput _output(
    JobResult r,
    HeadTailBuffer buffer,
    Duration wall,
    int? processId,
    int? maxOutputTokens,
  ) => ExecCommandOutput(
    chunkId: generateChunkId(_random),
    wallTime: wall,
    rawOutput: buffer.toBytesWithOmissionMarker(),
    truncationPolicy: truncationPolicy,
    maxOutputTokens: maxOutputTokens,
    processId: r.done ? null : processId,
    exitCode: r.done ? (r.exitCode ?? -1) : null,
    originalTokenCount: approxTokensFromByteCount(buffer.totalBytes),
    outputOmittedBytes: buffer.omittedBytes == 0 ? null : buffer.omittedBytes,
  );

  /// `exec_command`: `bash -lc <cmd>` (or `-c` with `login: false`) in
  /// `workdir` (default the workspace); waits `yield_time_ms` (10 s,
  /// 250-30000) or until it exits.
  Future<ToolText> execCommand(Map<String, Object?> args) async {
    final cmd = args['cmd'];
    if (cmd is! String) {
      return (
        text: 'failed to parse function arguments: missing field `cmd`',
        error: true,
      );
    }
    final workdir = args['workdir'];
    final cwd = workdir is String && workdir.isNotEmpty
        ? resolvePatchPath(workspace, workdir)
        : workspace;
    final tty = args['tty'] == true;
    final login = args['login'] is bool ? args['login'] as bool : true;
    final yieldMs = clampYieldTime(
      (_num(args['yield_time_ms']) ?? defaultExecYieldTimeMs).toInt(),
    );
    final maxTokens = _num(args['max_output_tokens'])?.toInt();
    final start = _now();
    final deadline = start.add(Duration(milliseconds: yieldMs));
    await _prune();
    final script = 'exec bash ${login ? '-lc' : '-c'} ${shellQuote(cmd)}';
    try {
      final first = await backend.run(
        script,
        cwd: cwd,
        env: {...unifiedExecEnv, ...env},
        timeout: yieldMs / 1000,
        mode: tty ? 'pty' : 'stdio',
      );
      final (r, buffer) = await _collect(first, deadline);
      track(r.jobId, r.offset, r.done);
      int? id;
      if (!r.done) {
        id = _allocateId();
        _processes[id] = _Process(r.jobId, tty, r.offset)..lastUsed = ++_clock;
      }
      final out = _output(r, buffer, _now().difference(start), id, maxTokens);
      return (text: out.responseText(), error: false);
    } on ShellctlException catch (e) {
      return (text: 'exec_command failed: ${e.toolText}', error: true);
    }
  }

  /// `write_stdin`: writes `chars` (a PTY session only) and returns the
  /// output since the last call; an empty `chars` polls.
  Future<ToolText> writeStdin(Map<String, Object?> args) async {
    final rawId = _num(args['session_id']);
    if (rawId == null) {
      return (
        text: 'failed to parse function arguments: missing field `session_id`',
        error: true,
      );
    }
    final id = rawId.toInt();
    final chars = args['chars'] is String ? args['chars'] as String : '';
    final p = _processes[id];
    if (p == null) {
      return (text: 'write_stdin failed: Unknown process id $id', error: true);
    }
    if (chars.isNotEmpty && !p.tty) {
      return (
        text:
            'write_stdin failed: stdin is closed for this session; rerun '
            'exec_command with tty=true to keep stdin open',
        error: true,
      );
    }
    p.lastUsed = ++_clock;
    final yieldMs = writeStdinYieldTime(
      (_num(args['yield_time_ms']) ?? defaultWriteStdinYieldTimeMs).toInt(),
      empty: chars.isEmpty,
    );
    final maxTokens = _num(args['max_output_tokens'])?.toInt();
    final start = _now();
    final deadline = start.add(Duration(milliseconds: yieldMs));
    try {
      final first = chars.isEmpty
          ? await backend.wait(
              p.jobId,
              offset: p.offset,
              timeout: yieldMs / 1000,
            )
          : await backend.input(
              p.jobId,
              chars,
              offset: p.offset,
              timeout: yieldMs / 1000,
            );
      final (r, buffer) = await _collect(first, deadline);
      p.offset = r.offset;
      track(r.jobId, r.offset, r.done);
      if (r.done) _processes.remove(id);
      final out = _output(r, buffer, _now().difference(start), id, maxTokens);
      return (text: out.responseText(), error: false);
    } on ShellctlException catch (e) {
      return (text: 'write_stdin failed: ${e.toolText}', error: true);
    }
  }
}
