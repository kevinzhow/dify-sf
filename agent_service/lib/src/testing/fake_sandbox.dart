/// In-process stand-ins for the sandbox supervisor and a sandbox's shellctl
/// daemon, for hermetic tests. The fake shellctl understands the service's
/// own control commands (probes, the reaper, file writes, stats and reads)
/// over an in-memory file map; user jobs are answered by [FakeShellctl.onJob].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// How a user job behaves.
class FakeJobSpec {
  FakeJobSpec({this.output = '', this.exitCode = 0, this.running = false});
  final String output;
  final int exitCode;

  /// Stays running until terminated.
  final bool running;
}

class FakeJob {
  FakeJob(this.id, this.mode, this.script, this.env);
  final String id;
  final String mode;
  final String script;
  final Map<String, String>? env;
  String output = '';
  int? exitCode;
  bool done = false;
  String status = 'running';
  final List<String> inputs = [];
}

class FakeShellctl {
  FakeShellctl({required this.token});

  final String token;
  HttpServer? _server;

  /// Workspace files by absolute path.
  final Map<String, List<int>> files = {};

  /// Symbolic links: absolute path → absolute target.
  final Map<String, String> symlinks = {};

  /// MIME type reported by `file` per absolute path (default text/plain).
  final Map<String, String> mimeTypes = {};

  /// Probe outcomes (`blocked` unless set to `reachable`).
  final Map<String, String> probes = {
    'write_outside_workspace': 'blocked',
    'daemon_records': 'blocked',
    'direct_internet': 'blocked',
    'host_reachable': 'blocked',
    'host_ipv6': 'blocked',
  };

  /// The latest probe script received.
  String? lastProbeScript;
  bool reapSucceeds = true;
  FakeJobSpec Function(String script)? onJob;

  /// Awaited before a user job starts (a test may hold jobs to observe
  /// concurrency).
  Future<void> Function(String script)? beforeJob;

  /// Answers a control script first (exit code and output); null passes it
  /// to the built-in handling (a test may run scripts in a local shell).
  Future<(int, String)?> Function(String script)? onControl;

  final Map<String, FakeJob> jobs = {};
  final List<Map<String, Object?>> runRequests = [];
  final List<String> terminated = [];
  final List<String> deleted = [];
  int reaps = 0;
  int probeRuns = 0;
  var _next = 0;

  Uri get url => Uri.parse('http://127.0.0.1:${_server!.port}');

  /// Runs of user (non-control) jobs.
  List<Map<String, Object?>> get userRuns => [
    for (final r in runRequests)
      if (r['mode'] != 'stdio') r,
  ];

  /// Jobs still running.
  List<FakeJob> get runningJobs => [
    for (final j in jobs.values)
      if (!j.done) j,
  ];

  Future<void> start() async {
    final server = _server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((r) => unawaited(_handle(r)));
  }

  Future<void> close() async => _server?.close(force: true);

  static String _unquote(String s) =>
      s.startsWith("'") && s.endsWith("'") ? s.substring(1, s.length - 1) : s;

  Future<void> _handle(HttpRequest request) async {
    final res = request.response;
    try {
      final segments = request.uri.pathSegments;
      if (request.uri.path == '/healthz') {
        return _json(res, 200, {'status': 'ok'});
      }
      if (request.headers.value('authorization') != 'Bearer $token') {
        return _json(res, 401, {
          'error': {'code': 'unauthorized', 'message': 'Missing or invalid'},
        });
      }
      final text = await utf8.decodeStream(request);
      final body = text.isEmpty
          ? <String, Object?>{}
          : (jsonDecode(text) as Map).cast<String, Object?>();
      final limit =
          (body['output_limit'] as num?)?.toInt() ??
          int.tryParse(request.uri.queryParameters['output_limit'] ?? '') ??
          16384;
      switch ((request.method, segments)) {
        case ('POST', ['v1', 'jobs', 'run']):
          runRequests.add(body);
          final script = body['script'] as String;
          final isControl = body['mode'] == 'stdio' && _isControl(script);
          final custom = isControl ? await onControl?.call(script) : null;
          if (!isControl) await beforeJob?.call(script);
          final job = _start(body, custom);
          return _json(res, 200, _window(job, 0, limit));
        case ('POST', ['v1', 'jobs', final id, 'wait']):
          final job = jobs[id];
          if (job == null) return _notFound(res, id);
          if (!job.done) {
            final t = (body['timeout'] as num?)?.toDouble() ?? 0;
            await Future<void>.delayed(
              Duration(milliseconds: (t * 1000).clamp(0, 50).round()),
            );
          }
          return _json(
            res,
            200,
            _window(job, (body['offset'] as num?)?.toInt() ?? 0, limit),
          );
        case ('POST', ['v1', 'jobs', final id, 'input']):
          final job = jobs[id];
          if (job == null) return _notFound(res, id);
          if (job.mode == 'stdio') {
            return _json(res, 409, {
              'error': {
                'code': 'input_unsupported',
                'message': 'stdio jobs do not support input',
              },
            });
          }
          final input = body['text'] as String? ?? '';
          job.inputs.add(input);
          job.output += 'got: $input';
          return _json(
            res,
            200,
            _window(job, (body['offset'] as num?)?.toInt() ?? 0, limit),
          );
        case ('GET', ['v1', 'jobs', final id, 'log', 'tail']):
          final job = jobs[id];
          if (job == null) return _notFound(res, id);
          final bytes = utf8.encode(job.output);
          final start = bytes.length > limit ? bytes.length - limit : 0;
          return _json(res, 200, {
            ..._view(job),
            'output': utf8.decode(bytes.sublist(start), allowMalformed: true),
            'offset': bytes.length,
            'truncated': false,
            'output_path':
                '/home/dify/.local/share/shellctl/jobs/$id/output.log',
          });
        case ('GET', ['v1', 'jobs', final id]):
          final job = jobs[id];
          if (job == null) return _notFound(res, id);
          return _json(res, 200, _view(job));
        case ('POST', ['v1', 'jobs', final id, 'terminate']):
          final job = jobs[id];
          if (job == null) return _notFound(res, id);
          terminated.add(id);
          if (!job.done) {
            job
              ..done = true
              ..status = 'terminated'
              ..exitCode = 130;
          }
          return _json(res, 200, _view(job));
        case ('DELETE', ['v1', 'jobs', final id]):
          if (jobs.remove(id) == null) return _notFound(res, id);
          deleted.add(id);
          return _json(res, 200, {'job_id': id, 'deleted': true});
        default:
          return _json(res, 404, {
            'error': {'code': 'not_found', 'message': 'no route'},
          });
      }
    } catch (e) {
      try {
        _json(res, 500, {
          'error': {'code': 'internal', 'message': '$e'},
        });
      } catch (_) {}
    }
  }

  void _notFound(HttpResponse res, String id) => _json(res, 404, {
    'error': {'code': 'job_not_found', 'message': 'Job $id not found'},
  });

  Map<String, Object?> _view(FakeJob job) => {
    'job_id': job.id,
    'status': job.status,
    'done': job.done,
    'exit_code': job.exitCode,
    'offset': utf8.encode(job.output).length,
  };

  Map<String, Object?> _window(FakeJob job, int offset, int limit) {
    final bytes = utf8.encode(job.output);
    final start = offset.clamp(0, bytes.length);
    final end = (start + limit).clamp(0, bytes.length);
    return {
      ..._view(job),
      'output': utf8.decode(bytes.sublist(start, end), allowMalformed: true),
      'offset': end,
      'truncated': end < bytes.length,
      'output_path':
          '/home/dify/.local/share/shellctl/jobs/${job.id}/output.log',
    };
  }

  FakeJob _start(Map<String, Object?> body, [(int, String)? custom]) {
    final script = body['script'] as String;
    final mode = body['mode'] as String? ?? 'pty';
    final env = (body['env'] as Map?)?.cast<String, String>();
    final job = FakeJob('job${++_next}', mode, script, env);
    jobs[job.id] = job;
    if (mode == 'stdio' && (custom != null || _isControl(script))) {
      final (code, out) = custom ?? _control(script);
      job
        ..output = out
        ..exitCode = code
        ..done = true
        ..status = 'exited';
      return job;
    }
    final spec = onJob?.call(script) ?? FakeJobSpec();
    job.output = spec.output;
    if (!spec.running) {
      job
        ..exitCode = spec.exitCode
        ..done = true
        ..status = 'exited';
    }
    return job;
  }

  /// The service's own control scripts (as opposed to a user job in
  /// `stdio` mode).
  static bool _isControl(String script) =>
      script.startsWith('{\n') || script.startsWith('dd if=');

  (int, String) _control(String script) {
    if (script.contains('write_outside_workspace=')) {
      probeRuns++;
      lastProbeScript = script;
      return (
        0,
        [for (final e in probes.entries) '${e.key}=${e.value}'].join('\n'),
      );
    }
    if (script.contains('reap=ok')) {
      reaps++;
      return reapSucceeds
          ? (0, 'reap=ok rounds=0\n')
          : (1, 'reap=incomplete 99\n');
    }
    final dd = RegExp(r"dd if=('[^']*') bs=(\d+) skip=(\d+)")
        .firstMatch(script);
    if (dd != null) {
      final data = files[_unquote(dd.group(1)!)] ?? const <int>[];
      final bs = int.parse(dd.group(2)!);
      final start = (int.parse(dd.group(3)!) * bs).clamp(0, data.length);
      final end = (start + bs).clamp(0, data.length);
      return (0, base64.encode(data.sublist(start, end)));
    }
    if (script.contains('realpath -e')) {
      final p = _unquote(RegExp(r"p=('[^']*')").firstMatch(script)!.group(1)!);
      final real = symlinks[p] ?? p;
      if (!files.containsKey(real)) return (0, 'missing\n');
      if (!real.startsWith('/workspace/')) return (0, 'escape\n');
      return (
        0,
        'ok ${files[real]!.length} ${mimeTypes[real] ?? 'text/plain'}\n$real\n',
      );
    }
    var out = '';
    final append = RegExp(
      r"base64 -d >> ('[^']*') <<'DIFYSF_EOF'\n([\s\S]*?)\nDIFYSF_EOF",
    ).firstMatch(script);
    if (append != null) {
      final part = _unquote(append.group(1)!);
      files[part] = [
        ...?files[part],
        ...base64.decode(append.group(2)!.replaceAll('\n', '')),
      ];
      return (0, out);
    }
    final create = RegExp(r": > ('[^']*')").firstMatch(script);
    if (create != null) {
      files[_unquote(create.group(1)!)] = [];
      return (0, out);
    }
    final mv = RegExp(r"mv -f -- ('[^']*') ('[^']*')").firstMatch(script);
    if (mv != null) {
      final from = _unquote(mv.group(1)!);
      files[_unquote(mv.group(2)!)] = files.remove(from) ?? [];
      return (0, out);
    }
    out = 'unknown control command\n';
    return (127, out);
  }

  static void _json(HttpResponse res, int status, Object body) {
    res
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    unawaited(res.close().then((_) {}, onError: (_) {}));
  }
}

/// A fake supervisor: one [FakeShellctl] per execution key.
class FakeSupervisor {
  FakeSupervisor({required this.key, this.configure});

  final String key;

  /// Called for every new sandbox (to set probes, jobs, files).
  final void Function(FakeShellctl shellctl)? configure;
  HttpServer? _server;

  /// Live sandboxes by ID.
  final Map<String, FakeShellctl> sandboxes = {};
  final Map<String, String> _idByKey = {};
  final List<String> acquires = [];
  final List<String> created = [];
  final List<String> deletes = [];

  /// The `gateway` reported for every sandbox.
  String gateway = '10.213.0.1';

  /// Answer acquires with this status instead (e.g. 503).
  int? failAcquire;
  String failAcquireCode = 'sandbox_start_failed';

  /// Workspaces live on disk: a sandbox replacing a gone one of the same
  /// key keeps its files and reports `workspace_kept_from`.
  bool diskWorkspaces = false;
  final Map<String, List<(String, FakeShellctl)>> _history = {};

  /// Answer deletes with this status instead.
  int? failDelete;

  /// `GET /v1/profiles`: per profile `{"status", "digest"}`; null answers
  /// 404 (a supervisor without profiles).
  Map<String, Map<String, Object?>>? profiles;

  /// The profile named in each acquire (null when the request named none).
  final List<String?> acquiredProfiles = [];

  /// The profile reported back; null reports the requested one, `''` none
  /// (a supervisor that ignores profiles).
  String? reportProfile;
  var _next = 0;

  Uri get url => Uri.parse('http://127.0.0.1:${_server!.port}');

  FakeShellctl? sandboxOf(String executionKey) =>
      sandboxes[_idByKey[executionKey]];

  Future<void> start() async {
    final server = _server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((r) => unawaited(_handle(r)));
  }

  Future<void> close() async {
    for (final s in sandboxes.values) {
      await s.close();
    }
    await _server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final res = request.response;
    if (request.headers.value('authorization') != 'Bearer $key') {
      return FakeShellctl._json(res, 401, {'error': 'unauthorized'});
    }
    final text = await utf8.decodeStream(request);
    final segments = request.uri.pathSegments;
    switch ((request.method, segments)) {
      case ('POST', ['v1', 'sandboxes']):
        final body = jsonDecode(text) as Map;
        final k = body['execution_key'] as String;
        acquires.add(k);
        acquiredProfiles.add(body['profile'] as String?);
        if (failAcquire != null) {
          return FakeShellctl._json(res, failAcquire!, {
            'error': failAcquireCode,
            'message': 'scripted failure',
          });
        }
        var id = _idByKey[k];
        final isNew = id == null || !sandboxes.containsKey(id);
        if (isNew) {
          id = 'sbx${++_next}';
          final s = FakeShellctl(token: 'tok-$id');
          configure?.call(s);
          await s.start();
          final history = _history.putIfAbsent(k, () => []);
          if (diskWorkspaces && history.isNotEmpty) {
            s.files.addAll(history.last.$2.files);
          }
          history.add((id, s));
          sandboxes[id] = s;
          _idByKey[k] = id;
          created.add(id);
        }
        final s = sandboxes[id]!;
        return FakeShellctl._json(res, isNew ? 201 : 200, {
          'sandbox_id': id,
          'url': '${s.url}',
          'token': s.token,
          'gateway': gateway,
          'created': isNew,
          if (reportProfile != '')
            'profile': reportProfile ?? body['profile'] ?? 'default',
          if (diskWorkspaces) ...{
            'workspace': 'disk',
            'workspace_kept_from': [
              for (final (old, _) in _history[k]!)
                if (old != id) old,
            ],
          },
        });
      case ('DELETE', ['v1', 'sandboxes', final id]):
        deletes.add(id);
        if (failDelete != null) {
          return FakeShellctl._json(res, failDelete!, {
            'error': 'docker_error',
            'message': 'scripted failure',
          });
        }
        final s = sandboxes.remove(id);
        await s?.close();
        return FakeShellctl._json(res, 200, {
          'sandbox_id': id,
          'deleted': s != null,
        });
      case ('GET', ['v1', 'profiles']):
        final p = profiles;
        if (p == null) {
          return FakeShellctl._json(res, 404, {'error': 'not_found'});
        }
        return FakeShellctl._json(res, 200, {'profiles': p});
      case ('GET', ['v1', 'sandboxes']):
        return FakeShellctl._json(res, 200, {
          'sandboxes': [
            for (final id in sandboxes.keys) {'sandbox_id': id},
          ],
        });
      default:
        return FakeShellctl._json(res, 404, {'error': 'not_found'});
    }
  }
}
