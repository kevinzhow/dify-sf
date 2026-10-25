/// Client of one sandbox's shellctl daemon (Dify's `shellctl` HTTP API, as
/// used by `dify_agent/adapters/shell/shellctl.py` and the shellctl SDK).
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Output window of the shellctl client (Dify's adapter default, 16 KiB).
const shellctlOutputLimitBytes = 16 * 1024;

/// The SDK's idle flush.
const shellctlIdleFlushSeconds = 0.5;

/// HTTP grace on top of a shell wait budget (the SDK's).
const _httpGrace = Duration(seconds: 10);

/// A shellctl failure: an API error (`status` set) or a transport failure
/// (`request_error`, `timeout`).
class ShellctlException implements Exception {
  ShellctlException(this.code, this.message, {this.status});

  final String code;
  final String message;
  final int? status;

  /// The text Dify's shell tools return to the model
  /// (`f"{code}: {exc}"` with the SDK's `"{code} ({status}): {message}"`).
  String get toolText =>
      status == null ? '$code: $message' : '$code: $code ($status): $message';

  @override
  String toString() => 'ShellctlException($toolText)';
}

/// `JobResult` / `JobStatusView` of the shellctl API.
class JobResult {
  JobResult({
    required this.jobId,
    required this.status,
    required this.done,
    required this.exitCode,
    this.output = '',
    this.offset = 0,
    this.truncated = false,
    this.outputPath,
  });

  final String jobId;
  final String status;
  final bool done;
  final int? exitCode;
  final String output;
  final int offset;
  final bool truncated;
  final String? outputPath;

  static JobResult fromJson(Map<String, Object?> j) => JobResult(
    jobId: j['job_id'] as String? ?? '',
    status: j['status'] as String? ?? '',
    done: j['done'] == true,
    exitCode: (j['exit_code'] as num?)?.toInt(),
    output: j['output'] as String? ?? '',
    offset: (j['offset'] as num?)?.toInt() ?? 0,
    truncated: j['truncated'] == true,
    outputPath: (j['output_path'] as String?)?.isEmpty ?? true
        ? null
        : j['output_path'] as String,
  );
}

class ShellctlClient {
  ShellctlClient(
    this.baseUrl,
    this.token, {
    this.outputLimit = shellctlOutputLimitBytes,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final Uri baseUrl;
  final String token;
  final int outputLimit;
  final http.Client _client;
  bool _closed = false;

  bool get isClosed => _closed;

  /// Aborts every request in flight.
  void close() {
    if (_closed) return;
    _closed = true;
    _client.close();
  }

  Uri _url(String path, [Map<String, String>? query]) {
    final base = baseUrl.toString().replaceFirst(RegExp(r'/+$'), '');
    return Uri.parse('$base$path').replace(queryParameters: query);
  }

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  Future<Map<String, Object?>> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 40),
    bool auth = true,
  }) async {
    final request = http.Request(method, _url(path, query));
    if (auth) request.headers.addAll(_headers);
    if (body != null) request.body = jsonEncode(body);
    final http.Response response;
    try {
      response = await http.Response.fromStream(await _client.send(request))
          .timeout(timeout);
    } on TimeoutException {
      throw ShellctlException('timeout', 'shellctl $path timed out');
    } on http.ClientException catch (e) {
      throw ShellctlException('request_error', e.message);
    } catch (e) {
      throw ShellctlException('request_error', '$e');
    }
    Object? decoded;
    try {
      decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    } on FormatException {
      decoded = null;
    }
    if (response.statusCode >= 300) {
      final error = decoded is Map ? decoded['error'] : null;
      if (error is Map) {
        throw ShellctlException(
          '${error['code'] ?? 'http_error'}',
          '${error['message'] ?? ''}',
          status: response.statusCode,
        );
      }
      throw ShellctlException(
        'http_error',
        'HTTP ${response.statusCode}',
        status: response.statusCode,
      );
    }
    if (decoded is! Map) {
      throw ShellctlException('invalid_response', 'shellctl $path: not JSON');
    }
    return decoded.cast<String, Object?>();
  }

  static Duration _budget(num seconds) =>
      Duration(milliseconds: (seconds * 1000).round()) + _httpGrace;

  Future<Map<String, Object?>> health() => _send(
    'GET',
    '/healthz',
    auth: false,
    timeout: const Duration(seconds: 5),
  );

  Future<JobResult> run(
    String script, {
    String? cwd,
    Map<String, String>? env,
    num timeout = 30,
    String mode = 'pty',
  }) async => JobResult.fromJson(
    await _send(
      'POST',
      '/v1/jobs/run',
      body: {
        'script': script,
        'cwd': ?cwd,
        'env': ?env,
        'mode': mode,
        'timeout': timeout,
        'output_limit': outputLimit,
        'idle_flush_seconds': shellctlIdleFlushSeconds,
      },
      timeout: _budget(timeout),
    ),
  );

  Future<JobResult> wait(
    String jobId, {
    required int offset,
    num timeout = 30,
  }) async => JobResult.fromJson(
    await _send(
      'POST',
      '/v1/jobs/${Uri.encodeComponent(jobId)}/wait',
      body: {
        'offset': offset,
        'timeout': timeout,
        'output_limit': outputLimit,
        'idle_flush_seconds': shellctlIdleFlushSeconds,
      },
      timeout: _budget(timeout),
    ),
  );

  Future<JobResult> input(
    String jobId,
    String text, {
    required int offset,
    num timeout = 30,
  }) async => JobResult.fromJson(
    await _send(
      'POST',
      '/v1/jobs/${Uri.encodeComponent(jobId)}/input',
      body: {
        'text': text,
        'offset': offset,
        'timeout': timeout,
        'output_limit': outputLimit,
        'idle_flush_seconds': shellctlIdleFlushSeconds,
      },
      timeout: _budget(timeout),
    ),
  );

  Future<JobResult> tail(String jobId) async => JobResult.fromJson(
    await _send(
      'GET',
      '/v1/jobs/${Uri.encodeComponent(jobId)}/log/tail',
      query: {'output_limit': '$outputLimit'},
    ),
  );

  Future<JobResult> status(String jobId) async => JobResult.fromJson(
    await _send('GET', '/v1/jobs/${Uri.encodeComponent(jobId)}'),
  );

  Future<JobResult> terminate(String jobId, {num graceSeconds = 10}) async =>
      JobResult.fromJson(
        await _send(
          'POST',
          '/v1/jobs/${Uri.encodeComponent(jobId)}/terminate',
          body: {'grace_seconds': graceSeconds},
          timeout: _budget(graceSeconds),
        ),
      );

  /// Deletes a job's artifacts; a missing job is not an error.
  Future<void> delete(String jobId, {bool force = false, num? grace}) async {
    try {
      await _send(
        'DELETE',
        '/v1/jobs/${Uri.encodeComponent(jobId)}',
        query: {'force': '$force', 'grace_seconds': ?grace?.toString()},
        timeout: _budget(grace ?? 10),
      );
    } on ShellctlException catch (e) {
      if (e.code == 'job_not_found') return;
      rethrow;
    }
  }
}
