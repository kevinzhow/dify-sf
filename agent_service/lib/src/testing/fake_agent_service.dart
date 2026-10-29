/// A deterministic fake of the agent service for the Swift server's tests:
/// the same HTTP API (`dify-sf-agent/1`), with scripted runs and fault
/// injection. Request validation, idempotency, generations, leases, cursor
/// expiry after ack and tombstones behave as in the real service; what a
/// run emits comes from a script or from the contract fixtures
/// (`fixtures/dify-sf-agent-1/`). Used by `bin/fake_agent_service.dart`.
///
/// Script JSON (every key optional):
///
/// ```jsonc
/// {"operations": {"E1:0:0": <operation>},   // by operation_id
///  "default": <operation>,                  // every other operation
///  "executions": {"E1": <execution>},       // by execution_id
///  "default_execution": <execution>,
///  "delays_ms": {"post": 0, "status": 0, "events": 0, "ack": 0,
///                "cancel": 0, "lease": 0, "delete": 0,
///                "release": 0},             // defaults
///  "release_failures": 0,                   // POST /v1/workspaces/release
///                                           //   answering 503 cleanup_failed first
///  "snapshot_check": "envelope",            // or "full" (the real check), "none"
///  "health": {"status": "ok", "sandbox": "disabled"},
///  "profiles": [{"name": "default", "description": "…", "status": "ok",
///                "timeout_seconds_max": 1800, "max_turns_max": 50,
///                "env": ["BLENDER"]}]}
///                // GET /v1/profiles, health `profiles` and the checks of a
///                // shell operation (`env`: the names the profile sets).
///                // Default: only `default` (1800 s, 50 turns), status `unavailable`
///                // with sandbox `disabled`, else `ok`.
///
/// <operation> = {
///   "fixture": "ask_human_two_questions",   // events of this operation_id in
///   "fixture_operation_id": "E1:0:1",       //   that fixture (default: own id)
///   "events": [{"event": "thought", "data": {…}}, …],  // ids 1..n; or:
///   "result": {"event": "succeeded", "data": {…}},     // the terminal event
///   "start_delay_ms": 0, "event_delay_ms": 0,
///   "hold": false,            // stay running after the events (until cancel,
///                             //   DELETE or lease expiry)
///   "hold_after": 1,          // hold after this many events; the rest are
///                             //   written when the run ends (buffered
///                             //   reasoning flushed at cancel)
///   "on_cancel": {"event": "succeeded", "data": {…}, "delay_ms": 200},
///                             // a late result after cancel; {"result": true}
///                             //   uses the scripted terminal event; default
///                             //   `cancelled` at once
///   "drop_stream_after": 3,   // reset the event stream after 3 events …
///   "drop_stream_times": 1,   //   … on this many connections
///   "duplicate_terminal": false,  // write the terminal event twice
///   "expire_cursors": false,  // once ended, cursors before the end: 410
///   "lose_post_response": 0,  // reset this many POST connections after
///                             //   accepting (the resend answers 200)
///   "reject": {"status": 422, "error": "snapshot_incompatible",
///              "message": "…", "extra": {…}, "times": null},  // null = always
///   "delays_ms": {…}}         // per route, as above
///
/// <execution> = {"delete_failures": 1,     // DELETEs answering 503 first
///                "delete_failure_status": 503, "delays_ms": {"lease", "delete"}}
/// ```
///
/// An operation with `codex_session: {"retain": true}` is validated as the
/// real service with the official Codex runtime validates it (codex style,
/// `model.run_token`, `tools.shell`; the profile's disk workspace is not
/// checked), and its workspace key is remembered: `POST
/// /v1/workspaces/release` answers `released` with the number of those keys
/// of the workflow run (and forgets them).
///
/// Strings `{run_id}`, `{operation_id}` and `{execution_id}` in scripted
/// event data are replaced. Without a script an operation succeeds with
/// `{"text": "Hello from the fake agent service."}` and a snapshot built from
/// the request. Run IDs are the fixture's, else `run_ffff…<counter>`.
///
/// Control routes (same bearer key): `PUT /_fake/script` replaces the script
/// and clears all state; `GET /_fake/requests` lists the requests received.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:genkit/genkit.dart';

import '../executor_profiles.dart' show checkOperationProfile;
import '../loop.dart';
import '../protocol.dart';
import '../server.dart' show maxBodyBytes;

class FakeAgentService {
  FakeAgentService({
    required this.serviceKey,
    Map<String, Object?> script = const {},
    this.fixturesDir,
    this.log,
  }) {
    setScript(script);
  }

  final String serviceKey;

  /// Directory of the fixture JSON files (for `"fixture"` operations).
  final String? fixturesDir;
  final void Function(String message)? log;

  HttpServer? _server;
  Map<String, Object?> _script = const {};
  final Map<String, _Run> _runs = {};
  final Map<String, _Execution> _executions = {};
  final Map<String, Map<String, Object?>> _fixtures = {};
  final Map<String, int> _rejections = {};
  final Map<String, int> _lostPosts = {};

  /// Retained workspace keys of accepted operations, with the workflow run.
  final Map<String, ExecutionRef> _retained = {};
  int _releaseFailures = 0;

  /// Requests received: method, path, query, body and the answered status.
  final List<Map<String, Object?>> requests = [];
  var _counter = 0;

  int get port => _server!.port;

  /// Replaces the script and clears every run, execution and log.
  void setScript(Map<String, Object?> script) {
    for (final r in _runs.values) {
      r.dispose();
    }
    for (final x in _executions.values) {
      x.lease?.cancel();
    }
    _script = script;
    _runs.clear();
    _executions.clear();
    _rejections.clear();
    _lostPosts.clear();
    _retained.clear();
    _releaseFailures = 0;
    requests.clear();
  }

  Future<int> start({Object address = '127.0.0.1', int port = 0}) async {
    final server = _server = await HttpServer.bind(address, port);
    server.autoCompress = false;
    server.listen((r) => unawaited(_handle(r)));
    return server.port;
  }

  Future<void> close() async {
    setScript(const {});
    await _server?.close(force: true);
  }

  // ---- script lookups -----------------------------------------------------

  Map<String, Object?> _map(Object? v) =>
      v is Map ? v.cast<String, Object?>() : const {};

  Map<String, Object?> _operationScript(String operationId) {
    final ops = _map(_script['operations']);
    return ops.containsKey(operationId)
        ? _map(ops[operationId])
        : _map(_script['default']);
  }

  Map<String, Object?> _executionScript(String executionId) {
    final xs = _map(_script['executions']);
    return xs.containsKey(executionId)
        ? _map(xs[executionId])
        : _map(_script['default_execution']);
  }

  int _delay(String route, Map<String, Object?> scoped) =>
      (_map(scoped['delays_ms'])[route] ??
              _map(_script['delays_ms'])[route] ??
              0)
          as int;

  Future<void> _sleep(int ms) async {
    if (ms > 0) await Future<void>.delayed(Duration(milliseconds: ms));
  }

  _Execution _execution(String id) => _executions.putIfAbsent(
    id,
    () =>
        _Execution(id, (_executionScript(id)['delete_failures'] as int?) ?? 0),
  );

  // ---- fixtures -----------------------------------------------------------

  /// The scripted executor profiles, defaults filled in.
  List<Map<String, Object?>> get _profiles {
    final raw = _script['profiles'];
    final disabled =
        (_map(_script['health'])['sandbox'] ?? 'disabled') == 'disabled';
    final list = raw is List
        ? [for (final p in raw) _map(p)]
        : [
            {'name': 'default', 'description': "Dify's shell sandbox"},
          ];
    return [
      for (final p in list)
        {
          'name': p['name'],
          'description': p['description'] ?? '',
          'status': p['status'] ?? (disabled ? 'unavailable' : 'ok'),
          'timeout_seconds_max': p['timeout_seconds_max'] ?? 1800,
          'max_turns_max': p['max_turns_max'] ?? 50,
          'env': p['env'] ?? const <String>[],
        },
    ];
  }

  Map<String, Object?> _fixture(String name) => _fixtures.putIfAbsent(name, () {
    final dir = fixturesDir;
    if (dir == null || name.contains('/') || name.contains('..')) {
      throw StateError('fixture "$name" needs a fixtures directory');
    }
    final file = File('$dir/$name.json');
    return (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();
  });

  /// The run ID and full event list of [operationId] in fixture [name].
  (String, List<Map<String, Object?>>) fixtureRun(
    String name,
    String operationId,
  ) {
    final steps = (_fixture(name)['steps'] as List).cast<Map>();
    String? runId;
    for (final s in steps) {
      final req = _map(s['request']);
      final res = _map(s['response']);
      if (req['method'] == 'POST' &&
          req['path'] == '/v1/operations' &&
          res['status'] == 202 &&
          _map(req['body'])['operation_id'] == operationId) {
        runId = _map(res['body'])['run_id'] as String;
        break;
      }
    }
    if (runId == null) {
      throw StateError('fixture $name has no run of $operationId');
    }
    for (final s in steps) {
      final req = _map(s['request']);
      final res = _map(s['response']);
      if (req['method'] == 'GET' &&
          req['path'] == '/v1/runs/$runId/events' &&
          req['query'] == null &&
          !_map(req['headers']).containsKey('Last-Event-ID') &&
          res['status'] == 200) {
        return (runId, [for (final e in res['events'] as List) _map(e)]);
      }
    }
    throw StateError('fixture $name has no event list of $runId');
  }

  // ---- requests -----------------------------------------------------------

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final entry = <String, Object?>{
      'method': request.method,
      'path': request.uri.path,
      if (request.uri.queryParameters.isNotEmpty)
        'query': request.uri.queryParameters,
    };
    requests.add(entry);
    try {
      if (!_authorized(request)) {
        throw ApiError(401, 'unauthorized', 'missing or invalid service key');
      }
      final segments = request.uri.pathSegments;
      final method = request.method;
      if (segments.length == 2 && segments[0] == '_fake') {
        switch ((method, segments[1])) {
          case ('PUT', 'script'):
            final body = await _body(request, entry, protocol: false);
            setScript(body);
            entry['status'] = 200;
            return _json(response, 200, {'ok': true});
          case ('GET', 'requests'):
            entry['status'] = 200;
            return _json(response, 200, {
              'requests': requests.sublist(0, requests.length - 1),
            });
        }
        throw ApiError(404, 'not_found', 'no such route');
      }
      if (segments.length < 2 || segments[0] != 'v1') {
        throw ApiError(404, 'not_found', 'no such route');
      }
      switch (segments.sublist(1)) {
        case ['health'] when method == 'GET':
          final h = _map(_script['health']);
          return _ok(entry, response, 200, {
            'protocol': protocolName,
            'status': h['status'] ?? 'ok',
            'sandbox': h['sandbox'] ?? 'disabled',
            'version': h['version'] ?? serviceVersion,
            'profiles': {for (final p in _profiles) p['name']: p['status']},
          });
        case ['profiles'] when method == 'GET':
          return _ok(entry, response, 200, {
            'protocol': protocolName,
            'profiles': [
              for (final p in _profiles)
                {
                  'name': p['name'],
                  'description': p['description'],
                  'status': p['status'],
                  'timeout_seconds_max': p['timeout_seconds_max'],
                  'max_turns_max': p['max_turns_max'],
                },
            ],
          });
        case ['operations'] when method == 'POST':
          return await _postOperation(request, entry);
        case ['runs'] when method == 'GET':
          if (request.uri.queryParameters['state'] != 'active') {
            throw invalidRequest('state must be "active"');
          }
          return _ok(entry, response, 200, {
            'protocol': protocolName,
            'runs': [
              for (final r in _runs.values)
                if (!r.isEnded || !r.acknowledged)
                  {
                    'run_id': r.runId,
                    'operation_id': r.operationId,
                    'execution_id': r.executionId,
                    ...r.identity,
                    'generation': r.generation,
                    'status': r.status,
                    'acknowledged': r.acknowledged,
                    'last_event_id': r.lastEventId,
                  },
            ],
          });
        case ['runs', final id] when method == 'GET':
          final run = _run(id);
          await _sleep(_delay('status', run.script));
          return _ok(entry, response, 200, run.statusJson());
        case ['runs', final id, 'events'] when method == 'GET':
          return await _events(request, entry, _run(id));
        case ['runs', final id, 'ack'] when method == 'POST':
          return await _ack(request, entry, _run(id));
        case ['runs', final id, 'cancel'] when method == 'POST':
          return await _cancel(request, entry, _run(id));
        case ['executions', final id, 'lease'] when method == 'POST':
          return await _lease(request, entry, id);
        case ['executions', final id] when method == 'DELETE':
          return await _delete(request, entry, id);
        case ['workspaces', 'release'] when method == 'POST':
          return await _release(request, entry);
      }
      throw ApiError(404, 'not_found', 'no such route');
    } on ApiError catch (e) {
      entry['status'] = e.status;
      _json(response, e.status, e.toJson());
    } on _Detached {
      entry['status'] = 'connection_reset';
    } catch (e, st) {
      log?.call('fake agent service: ${request.uri.path} failed: $e\n$st');
      entry['status'] = 500;
      try {
        _json(response, 500, ApiError(500, 'internal', '$e').toJson());
      } catch (_) {}
    }
  }

  bool _authorized(HttpRequest request) =>
      request.headers.value(HttpHeaders.authorizationHeader) ==
      'Bearer $serviceKey';

  Future<Map<String, Object?>> _body(
    HttpRequest request,
    Map<String, Object?> entry, {
    bool protocol = true,
  }) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
      if (builder.length > maxBodyBytes) {
        throw ApiError(413, 'body_too_large', 'request body exceeds 8 MiB');
      }
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(builder.takeBytes()));
    } on FormatException {
      throw ApiError(400, 'invalid_json', 'request body is not UTF-8 JSON');
    }
    if (decoded is! Map) {
      throw ApiError(400, 'invalid_json', 'request body must be an object');
    }
    final body = decoded.cast<String, Object?>();
    entry['body'] = body;
    if (protocol) requireProtocol(body);
    return body;
  }

  static int _generation(Map<String, Object?> body) {
    final g = body['generation'];
    if (g is! int || g < 0) {
      throw invalidRequest('generation must be a non-negative integer');
    }
    return g;
  }

  _Run _run(String id) {
    final run = _runs[id];
    if (run == null) throw ApiError(404, 'run_not_found', 'no run $id');
    return run;
  }

  void _checkGeneration(String executionId, int generation) {
    final max = _executions[executionId]?.maxGeneration ?? 0;
    if (generation < max) {
      throw ApiError(
        409,
        'stale_generation',
        'generation $generation is older than $max for this execution',
        extra: {'generation': max},
      );
    }
  }

  void _observeGeneration(String executionId, int generation) {
    final x = _execution(executionId);
    if (generation > x.maxGeneration) x.maxGeneration = generation;
  }

  void _ok(
    Map<String, Object?> entry,
    HttpResponse response,
    int status,
    Map<String, Object?> body,
  ) {
    entry['status'] = status;
    _json(response, status, body);
  }

  void _json(HttpResponse response, int status, Map<String, Object?> body) {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    unawaited(response.close().then((_) {}, onError: (_) {}));
  }

  /// Resets the connection without an answer.
  Future<Never> _reset(HttpRequest request) async {
    final socket = await request.response.detachSocket(writeHeaders: false);
    socket.destroy();
    throw const _Detached();
  }

  bool _loseResponse(String operationId, Map<String, Object?> script) {
    final raw = script['lose_post_response'];
    final limit = raw == true ? 1 : (raw is int ? raw : 0);
    final used = _lostPosts[operationId] ?? 0;
    if (used >= limit) return false;
    _lostPosts[operationId] = used + 1;
    return true;
  }

  Future<void> _postOperation(
    HttpRequest request,
    Map<String, Object?> entry,
  ) async {
    final body = await _body(request, entry);
    // codex_session exists only with the official Codex runtime.
    final op = OperationRequest.parse(
      body,
      officialCodex: body['codex_session'] != null,
    );
    final script = _operationScript(op.operationId);
    await _sleep(_delay('post', script));
    final reject = _map(script['reject']);
    if (reject.isNotEmpty) {
      final times = reject['times'] as int?;
      final used = _rejections[op.operationId] ?? 0;
      if (times == null || used < times) {
        _rejections[op.operationId] = used + 1;
        throw ApiError(
          reject['status'] as int? ?? 422,
          reject['error'] as String? ?? 'snapshot_incompatible',
          reject['message'] as String? ?? 'scripted rejection',
          extra: _map(reject['extra']),
        );
      }
    }
    final executionId = op.execution.executionId;
    final x = _executions[executionId];
    if (x?.deleted ?? false) {
      throw ApiError(
        410,
        'execution_deleted',
        'execution $executionId was deleted',
      );
    }
    _checkGeneration(executionId, op.generation);
    final digest = op.digest;
    final existing = x?.operations[op.operationId];
    if (existing != null) {
      if (existing.digest != digest) {
        throw ApiError(
          409,
          'operation_conflict',
          'operation ${op.operationId} exists with a different request',
          extra: {'run_id': existing.runId},
        );
      }
      _observeGeneration(executionId, op.generation);
      if (_loseResponse(op.operationId, script)) await _reset(request);
      return _ok(
        entry,
        request.response,
        200,
        _runs[existing.runId]!.statusJson(),
      );
    }
    if (op.shell) {
      final p = _profiles
          .where((p) => p['name'] == op.executorProfile)
          .firstOrNull;
      checkOperationProfile(
        op,
        p == null
            ? null
            : (
                timeoutSecondsMax: p['timeout_seconds_max'] as int,
                maxTurnsMax: p['max_turns_max'] as int,
                envNames: (p['env'] as List).cast<String>(),
              ),
        p?['status'] as String?,
      );
    }
    _checkSnapshot(op);
    final token = request.headers.value('x-agent-run-token');
    if (token == null || token.isEmpty) {
      throw invalidRequest('the X-Agent-Run-Token header is required');
    }
    final run = _createRun(op, digest, script);
    final workspaceKey = op.workspaceKey;
    if (workspaceKey != null) _retained[workspaceKey] = op.execution;
    if (_loseResponse(op.operationId, script)) await _reset(request);
    return _ok(entry, request.response, 202, {
      'protocol': protocolName,
      'run_id': run.runId,
      'status': 'running',
    });
  }

  /// `POST /v1/workspaces/release` (see the library comment).
  Future<void> _release(HttpRequest request, Map<String, Object?> entry) async {
    final body = await _body(request, entry);
    await _sleep(_delay('release', const {}));
    const fields = {'protocol', 'tenant_id', 'app_id', 'workflow_run_id'};
    final unknown = body.keys.where((k) => !fields.contains(k));
    if (unknown.isNotEmpty) {
      throw invalidRequest('unknown request fields: ${unknown.join(', ')}');
    }
    String field(String key) {
      final v = body[key];
      if (v is String && v.isNotEmpty) return v;
      throw invalidRequest('$key must be a non-empty string');
    }

    final tenantId = field('tenant_id');
    final appId = field('app_id');
    final workflowRunId = field('workflow_run_id');
    final failures = _script['release_failures'];
    if (failures is int && _releaseFailures < failures) {
      _releaseFailures++;
      throw ApiError(
        503,
        'cleanup_failed',
        'scripted failure',
        extra: {'released': 0, 'failed': 1},
      );
    }
    final keys = [
      for (final e in _retained.entries)
        if (e.value.tenantId == tenantId &&
            e.value.appId == appId &&
            e.value.workflowRunId == workflowRunId)
          e.key,
    ];
    keys.forEach(_retained.remove);
    return _ok(entry, request.response, 200, {
      'protocol': protocolName,
      'tenant_id': tenantId,
      'app_id': appId,
      'workflow_run_id': workflowRunId,
      'released': keys.length,
    });
  }

  void _checkSnapshot(OperationRequest op) {
    final c = op.continuation;
    if (c == null) return;
    switch (_script['snapshot_check'] ?? 'envelope') {
      case 'none':
        return;
      case 'full':
        verifyContinuation(op);
        return;
    }
    final s = c.snapshot;
    final genkit = s['genkit'];
    final why = s['envelope'] != envelopeName
        ? 'snapshot envelope ${jsonEncode(s['envelope'])} is not $envelopeName'
        : genkit is! String ||
              genkit.split('.').first != genkitVersion.split('.').first
        ? 'snapshot Genkit version ${jsonEncode(genkit)} is not compatible'
        : s['agent_config_snapshot_id'] != op.execution.agentConfigSnapshotId
        ? 'snapshot belongs to a different agent_config_snapshot_id'
        : null;
    if (why != null) throw ApiError(422, 'snapshot_incompatible', why);
  }

  String _newRunId() =>
      'run_ffff${(++_counter).toRadixString(16).padLeft(20, '0')}';

  _Run _createRun(
    OperationRequest op,
    String digest,
    Map<String, Object?> script,
  ) {
    List<Map<String, Object?>> events;
    String runId;
    final fixture = script['fixture'];
    if (fixture is String) {
      final (fixtureRunId, list) = fixtureRun(
        fixture,
        script['fixture_operation_id'] as String? ?? op.operationId,
      );
      runId = _runs.containsKey(fixtureRunId) ? _newRunId() : fixtureRunId;
      events = [
        for (final e in list)
          {
            'event': e['event'],
            'data': _replace(e['data'], {fixtureRunId: runId}),
          },
      ];
    } else {
      runId = _newRunId();
      final vars = {
        '{run_id}': runId,
        '{operation_id}': op.operationId,
        '{execution_id}': op.execution.executionId,
      };
      events = script.containsKey('events') || script.containsKey('result')
          ? [
              for (final e in (script['events'] as List?) ?? const [])
                {
                  'event': _map(e)['event'],
                  'data': _replace(_map(e)['data'], vars),
                },
              if (script['result'] case final Map r)
                {'event': r['event'], 'data': _replace(r['data'], vars)},
            ]
          : _defaultEvents(op, runId);
    }
    final terminalAt = events.indexWhere(
      (e) => terminalEvents.contains(e['event']),
    );
    final run = _Run(
      runId: runId,
      operationId: op.operationId,
      executionId: op.execution.executionId,
      identity: {
        'tenant_id': op.execution.tenantId,
        'app_id': op.execution.appId,
        'workflow_run_id': op.execution.workflowRunId,
        'node_id': op.execution.nodeId,
      },
      generation: op.generation,
      script: script,
      steps: terminalAt < 0 ? events : events.sublist(0, terminalAt),
      terminal: terminalAt < 0 ? null : events[terminalAt],
    );
    _runs[runId] = run;
    final x = _execution(op.execution.executionId);
    if (op.generation > x.maxGeneration) x.maxGeneration = op.generation;
    x.operations[op.operationId] = (runId: runId, digest: digest);
    unawaited(_play(run));
    return run;
  }

  static Object? _replace(Object? v, Map<String, String> vars) => switch (v) {
    final String s => vars.entries.fold<String>(
      s,
      (out, e) => out.replaceAll(e.key, e.value),
    ),
    final Map<Object?, Object?> m => {
      for (final e in m.entries) e.key as String: _replace(e.value, vars),
    },
    final List<Object?> l => [for (final x in l) _replace(x, vars)],
    _ => v,
  };

  static Map<String, Object?> _zeroUsage() => {
    'prompt_tokens': 0,
    'completion_tokens': 0,
    'total_tokens': 0,
    'reasoning_tokens': null,
    'prompt_cache_hit_tokens': null,
    'prompt_cache_miss_tokens': null,
  };

  /// A plain success with a snapshot built from the request.
  List<Map<String, Object?>> _defaultEvents(OperationRequest op, String runId) {
    const answer = 'Hello from the fake agent service.';
    final usage = {
      'prompt_tokens': 10,
      'completion_tokens': 5,
      'total_tokens': 15,
      'reasoning_tokens': null,
      'prompt_cache_hit_tokens': null,
      'prompt_cache_miss_tokens': null,
    };
    final previous = op.continuation?.snapshot;
    final messages = <Map<String, Object?>>[
      if (previous != null)
        for (final m in (previous['messages'] as List? ?? const [])) _map(m)
      else ...[
        if (op.systemPrompt.isNotEmpty)
          Message(
            role: Role.system,
            content: [TextPart(text: op.systemPrompt)],
          ).toJson(),
        Message(
          role: Role.user,
          content: [
            for (final p in op.task)
              switch (p) {
                TaskText() => TextPart(text: p.text),
                TaskFile() => MediaPart(
                  media: Media(
                    url: 'dify-sf-file:${p.fileId}',
                    contentType: p.mimeType,
                  ),
                ),
              },
          ],
        ).toJson(),
      ],
      Message(
        role: Role.model,
        content: [TextPart(text: answer)],
      ).toJson(),
    ];
    return [
      {
        'event': 'run_started',
        'data': {
          'model': {'provider': op.model.provider, 'name': op.model.name},
          'call_index_base': 0,
          'executor_profile': op.executorProfile,
        },
      },
      {
        'event': 'model_call',
        'data': {'invocation_id': '$runId:1', 'usage': usage},
      },
      {
        'event': 'succeeded',
        'data': {
          'candidate': op.outputSchema == null ? {'text': answer} : null,
          'candidate_errors': [
            if (op.outputSchema != null)
              {
                'field': '',
                'error': 'the model answered without calling final_output',
              },
          ],
          'snapshot': {
            'envelope': envelopeName,
            'revision': ((previous?['revision'] as int?) ?? 0) + 1,
            'genkit': genkitVersion,
            'agent_config_snapshot_id': op.execution.agentConfigSnapshotId,
            'tool_definitions_digest': toolDefinitionsDigest(op),
            'model': op.model.json,
            'output_attempt': op.outputAttempt,
            'resume_sequence': op.resumeSequence,
            'pending': null,
            'file_ids': {
              for (final p in op.task)
                if (p is TaskFile) p.fileId,
              ...op.fileIds,
            }.toList(),
            'workspace_ref': previous?['workspace_ref'],
            'executor_profile': op.executorProfile,
            'messages': messages,
          },
          'usage': usage,
        },
      },
    ];
  }

  /// Emits the scripted events of [run] in order.
  Future<void> _play(_Run run) async {
    final script = run.script;
    await _sleep(script['start_delay_ms'] as int? ?? 0);
    final gap = script['event_delay_ms'] as int? ?? 0;
    final holdAfter = script['hold_after'] as int?;
    final playing = holdAfter == null
        ? run.steps.length
        : holdAfter.clamp(0, run.steps.length);
    for (var i = 0; i < playing; i++) {
      if (run.isEnded || run.stopping) return;
      if (i > 0) await _sleep(gap);
      if (run.isEnded || run.stopping) return;
      run.playNext();
    }
    if (script['hold'] == true || holdAfter != null || run.terminal == null) {
      return;
    }
    if (run.steps.isNotEmpty) await _sleep(gap);
    if (run.isEnded || run.stopping) return;
    run.finish(run.terminal!['event'] as String, _map(run.terminal!['data']));
  }

  Future<void> _events(
    HttpRequest request,
    Map<String, Object?> entry,
    _Run run,
  ) async {
    final afterText =
        request.uri.queryParameters['after'] ??
        request.headers.value('last-event-id');
    final after = afterText == null ? 0 : int.tryParse(afterText.trim());
    if (after == null) throw invalidRequest('after must be an integer');
    if (after < 0 || after > run.lastEventId) {
      throw ApiError(
        400,
        'invalid_cursor',
        'cursor $after is outside 0..${run.lastEventId}',
      );
    }
    final expired =
        run.isEnded &&
        (run.acknowledged || run.script['expire_cursors'] == true);
    if (expired && after < run.lastEventId) {
      throw ApiError(
        410,
        'cursor_expired',
        'events of run ${run.runId} are no longer kept; read the run status',
        extra: {'run_id': run.runId},
      );
    }
    await _sleep(_delay('events', run.script));
    entry['status'] = 200;
    final response = request.response
      ..statusCode = 200
      ..headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      )
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-cache')
      ..headers.chunkedTransferEncoding = true
      ..headers.persistentConnection = false;
    final socket = await response.detachSocket(writeHeaders: true);
    final dropAfter = run.script['drop_stream_after'] as int?;
    final drop = dropAfter != null && run.dropsLeft > 0;
    if (drop) run.dropsLeft--;
    var written = 0;
    var lastSent = after;
    var closed = false;
    final done = Completer<void>();
    StreamSubscription<_Event>? sub;
    Timer? keepAlive;

    void end({bool reset = false}) {
      if (closed) return;
      closed = true;
      keepAlive?.cancel();
      unawaited(sub?.cancel());
      if (reset) {
        socket.destroy();
      } else {
        try {
          socket.write('0\r\n\r\n');
        } catch (_) {}
        unawaited(socket.close().then((_) {}, onError: (_) {}));
      }
      if (!done.isCompleted) done.complete();
    }

    void chunk(String text) {
      final bytes = utf8.encode(text);
      socket
        ..write('${bytes.length.toRadixString(16)}\r\n')
        ..add(bytes)
        ..write('\r\n');
    }

    void write(_Event e) {
      if (closed || e.id <= lastSent) return;
      lastSent = e.id;
      final block =
          'id: ${e.id}\nevent: ${e.event}\ndata: ${jsonEncode(e.data)}\n\n';
      try {
        chunk(block);
        if (e.isTerminal && run.script['duplicate_terminal'] == true) {
          chunk(block);
        }
      } catch (_) {
        return end(reset: true);
      }
      written++;
      if (drop && written >= dropAfter) return end(reset: true);
      if (e.isTerminal) end();
    }

    socket.listen(
      (_) {},
      onDone: () => end(reset: true),
      onError: (_) => end(reset: true),
      cancelOnError: true,
    );
    if (drop && dropAfter <= 0) {
      end(reset: true);
    } else {
      if (!run.isEnded) sub = run.live.stream.listen(write);
      for (final e in List.of(run.events)) {
        write(e);
      }
      if (run.isEnded) end();
      if (!closed) {
        keepAlive = Timer.periodic(const Duration(seconds: 15), (_) {
          try {
            chunk(': keep-alive\n\n');
          } catch (_) {
            end(reset: true);
          }
        });
      }
    }
    await done.future;
  }

  Future<void> _ack(
    HttpRequest request,
    Map<String, Object?> entry,
    _Run run,
  ) async {
    final body = await _body(request, entry);
    final generation = _generation(body);
    final resultEventId = body['result_event_id'];
    if (resultEventId is! int) {
      throw invalidRequest('result_event_id must be an integer');
    }
    await _sleep(_delay('ack', run.script));
    _checkGeneration(run.executionId, generation);
    if (!run.isEnded) {
      throw ApiError(409, 'run_active', 'run ${run.runId} has not ended');
    }
    if (resultEventId != run.result!.id) {
      throw ApiError(
        409,
        'result_mismatch',
        'result_event_id $resultEventId is not the terminal event '
            '${run.result!.id}',
      );
    }
    run.acknowledged = true;
    _ok(entry, request.response, 200, run.statusJson());
  }

  Future<void> _cancel(
    HttpRequest request,
    Map<String, Object?> entry,
    _Run run,
  ) async {
    final body = await _body(request, entry);
    final generation = _generation(body);
    await _sleep(_delay('cancel', run.script));
    _checkGeneration(run.executionId, generation);
    if (run.isEnded) {
      throw ApiError(
        409,
        'run_ended',
        'run ${run.runId} already ended',
        extra: {
          'run_id': run.runId,
          'status': run.status,
          'result': run.result?.data,
        },
      );
    }
    _ok(entry, request.response, 202, {
      'protocol': protocolName,
      'run_id': run.runId,
      'status': run.status,
    });
    // A second cancel while a late result is pending is a no-op, as in the
    // real service.
    if (!run.stopping) _stop(run, _map(run.script['on_cancel']));
  }

  /// Stops [run]: `cancelled` at once, or the scripted late result.
  void _stop(_Run run, Map<String, Object?> onCancel) {
    run.stopping = true;
    final delay = onCancel['delay_ms'] as int? ?? 0;
    Map<String, Object?>? late;
    if (onCancel['result'] == true) {
      late = run.terminal;
    } else if (onCancel['event'] is String) {
      late = onCancel;
    }
    void finish() {
      if (late != null) {
        run.finish(late['event'] as String, _map(late['data']));
      } else {
        run.finish('cancelled', {'usage': _zeroUsage()});
      }
    }

    if (delay <= 0) return finish();
    run.timers.add(Timer(Duration(milliseconds: delay), finish));
  }

  Future<void> _lease(
    HttpRequest request,
    Map<String, Object?> entry,
    String executionId,
  ) async {
    final body = await _body(request, entry);
    final generation = _generation(body);
    final ttl = body['ttl_seconds'] ?? 120;
    if (ttl is! int || ttl < 1 || ttl > 3600) {
      throw invalidRequest('ttl_seconds must be an integer in 1..3600');
    }
    await _sleep(_delay('lease', _executionScript(executionId)));
    if (_executions[executionId]?.deleted ?? false) {
      throw ApiError(
        410,
        'execution_deleted',
        'execution $executionId was deleted',
      );
    }
    _checkGeneration(executionId, generation);
    _observeGeneration(executionId, generation);
    final x = _execution(executionId);
    x.lease?.cancel();
    x.lease = Timer(Duration(seconds: ttl), () {
      x.lease = null;
      for (final run in _runs.values.toList()) {
        if (run.executionId != executionId || run.isEnded) continue;
        run.stopping = true;
        run.finish('failed', {
          'error_type': 'cancel_lost',
          'message': 'the execution lease expired; the run was cancelled',
          'usage': _zeroUsage(),
        });
      }
    });
    _ok(entry, request.response, 200, {
      'protocol': protocolName,
      'execution_id': executionId,
      'generation': generation,
      'expires_at': DateTime.now()
          .toUtc()
          .add(Duration(seconds: ttl))
          .toIso8601String(),
    });
  }

  Future<void> _delete(
    HttpRequest request,
    Map<String, Object?> entry,
    String executionId,
  ) async {
    final body = await _body(request, entry);
    final generation = _generation(body);
    final xs = _executionScript(executionId);
    await _sleep(_delay('delete', xs));
    _checkGeneration(executionId, generation);
    for (final run in _runs.values.toList()) {
      if (run.executionId == executionId && !run.isEnded) {
        run.stopping = true;
        run.finish('cancelled', {'usage': _zeroUsage()});
      }
    }
    final x = _execution(executionId);
    if (!x.deleted && x.deleteFailuresLeft > 0) {
      x.deleteFailuresLeft--;
      throw ApiError(
        xs['delete_failure_status'] as int? ?? 503,
        'cleanup_failed',
        'the supervisor answered HTTP 503: scripted failure',
      );
    }
    for (final run in _runs.values.toList()) {
      if (run.executionId == executionId) {
        run.dispose();
        _runs.remove(run.runId);
      }
    }
    x
      ..deleted = true
      ..operations.clear()
      ..lease?.cancel()
      ..lease = null;
    _ok(entry, request.response, 200, {
      'protocol': protocolName,
      'execution_id': executionId,
      'deleted': true,
    });
  }
}

class _Detached implements Exception {
  const _Detached();
}

class _Event {
  _Event(this.id, this.event, this.data);
  final int id;
  final String event;
  final Map<String, Object?> data;
  bool get isTerminal => terminalEvents.contains(event);
}

class _Execution {
  _Execution(this.executionId, this.deleteFailuresLeft);
  final String executionId;
  int maxGeneration = 0;
  final Map<String, ({String runId, String digest})> operations = {};
  bool deleted = false;
  int deleteFailuresLeft;
  Timer? lease;
}

class _Run {
  _Run({
    required this.runId,
    required this.operationId,
    required this.executionId,
    required this.identity,
    required this.generation,
    required this.script,
    required this.steps,
    required this.terminal,
  }) : dropsLeft = script['drop_stream_times'] as int? ?? 1;

  final String runId;
  final String operationId;
  final String executionId;

  /// `tenant_id`, `app_id`, `workflow_run_id` and `node_id` of the execution.
  final Map<String, Object?> identity;
  final int generation;
  final Map<String, Object?> script;

  /// Scripted non-terminal events and the terminal one (null: none).
  final List<Map<String, Object?>> steps;
  final Map<String, Object?>? terminal;

  final List<_Event> events = [];
  final StreamController<_Event> live = StreamController.broadcast(sync: true);
  final List<Timer> timers = [];
  String status = 'running';
  _Event? result;
  bool acknowledged = false;
  bool stopping = false;
  int dropsLeft;

  /// How many of [steps] are written.
  int played = 0;

  bool get isEnded => status != 'running';
  int get lastEventId => events.isEmpty ? 0 : events.last.id;

  void playNext() {
    final step = steps[played++];
    final data = step['data'];
    append(
      step['event'] as String,
      data is Map ? data.cast<String, Object?>() : const {},
    );
  }

  void append(String event, Map<String, Object?> data) {
    if (isEnded) return;
    final e = _Event(lastEventId + 1, event, data);
    events.add(e);
    live.add(e);
  }

  void finish(String event, Map<String, Object?> data) {
    if (isEnded) return;
    if (script['hold_after'] != null) {
      while (played < steps.length) {
        playNext();
      }
    }
    final e = _Event(lastEventId + 1, event, data);
    events.add(e);
    result = e;
    status = event;
    live.add(e);
    unawaited(live.close());
  }

  Map<String, Object?> statusJson() => {
    'protocol': protocolName,
    'run_id': runId,
    'operation_id': operationId,
    'status': status,
    'last_event_id': lastEventId,
    'result': result?.data,
    'acknowledged': acknowledged,
  };

  void dispose() {
    for (final t in timers) {
      t.cancel();
    }
    if (!live.isClosed) unawaited(live.close());
  }
}
