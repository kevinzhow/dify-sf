/// The HTTP server of the `dify-sf-agent/1` protocol (plain `dart:io`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'leases.dart';
import 'loop.dart';
import 'protocol.dart';
import 'run_store.dart';

/// Request bodies are at most 8 MiB.
const maxBodyBytes = 8 * 1024 * 1024;

enum LogLevel { debug, info, warning, error }

class AgentService {
  AgentService({
    required this.serviceKey,
    required String dataDir,
    this.innerUrl,
    Clock? clock,
    Duration eventRetention = const Duration(hours: 24),
    this.logLevel = LogLevel.info,
    this.sweepInterval = const Duration(minutes: 1),
    this.keepAliveInterval = const Duration(seconds: 15),
  }) : store = RunStore(dataDir, clock: clock, eventRetention: eventRetention) {
    leases = LeaseManager(onExpired: _leaseExpired);
  }

  final String serviceKey;
  final Uri? innerUrl;
  final RunStore store;
  final LogLevel logLevel;
  final Duration sweepInterval;
  final Duration keepAliveInterval;
  late final LeaseManager leases;

  final Map<String, AgentRun> _live = {};
  HttpServer? _server;
  Timer? _sweeper;
  bool _stopping = false;

  /// Runs in flight, by run ID.
  Map<String, AgentRun> get liveRuns => Map.unmodifiable(_live);

  int get port => _server!.port;

  void _log(LogLevel level, String message) {
    if (level.index < logLevel.index) return;
    stderr.writeln(
      '${DateTime.now().toUtc().toIso8601String()} ${level.name} $message',
    );
  }

  Future<int> start({Object address = '0.0.0.0', int port = 5050}) async {
    store.load();
    final server = _server = await HttpServer.bind(address, port);
    server.autoCompress = false;
    _sweeper = Timer.periodic(sweepInterval, (_) => store.sweep());
    server.listen((request) {
      unawaited(_handle(request));
    });
    _log(LogLevel.info, 'agent service listening on port ${server.port}');
    return server.port;
  }

  /// Stops accepting requests, ends every running operation (`failed`,
  /// `internal`) and closes the server.
  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
    _sweeper?.cancel();
    leases.close();
    final runs = _live.values.toList();
    for (final run in runs) {
      run.stop(StopReason.shutdown);
    }
    await Future.wait(runs.map((r) => r.done))
        .timeout(const Duration(seconds: 5), onTimeout: () => const []);
    await _server?.close(force: true);
  }

  void _leaseExpired(String executionId) {
    for (final run in _live.values.toList()) {
      if (run.record.executionId == executionId) {
        _log(LogLevel.warning, 'lease of ${run.runId} expired; cancelling');
        run.stop(StopReason.cancelLost);
      }
    }
  }

  // ---- request handling ---------------------------------------------------

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (!_authorized(request)) {
        response.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Bearer');
        throw ApiError(401, 'unauthorized', 'missing or invalid service key');
      }
      final segments = request.uri.pathSegments;
      if (segments.length < 2 || segments[0] != 'v1') {
        throw ApiError(404, 'not_found', 'no such route');
      }
      final method = request.method;
      final route = segments.sublist(1);
      switch (route) {
        case ['health'] when method == 'GET':
          return _json(response, 200, _health());
        case ['operations'] when method == 'POST':
          return await _postOperation(request);
        case ['runs'] when method == 'GET':
          return _listRuns(request);
        case ['runs', final id] when method == 'GET':
          return _json(response, 200, _run(id).statusJson());
        case ['runs', final id, 'events'] when method == 'GET':
          return await _events(request, _run(id));
        case ['runs', final id, 'ack'] when method == 'POST':
          return await _ack(request, _run(id));
        case ['runs', final id, 'cancel'] when method == 'POST':
          return await _cancel(request, _run(id));
        case ['executions', final id, 'lease'] when method == 'POST':
          return await _lease(request, id);
        case ['executions', final id] when method == 'DELETE':
          return await _deleteExecution(request, id);
        case ['health'] ||
            ['operations'] ||
            ['runs'] ||
            ['runs', _] ||
            ['runs', _, 'events' || 'ack' || 'cancel'] ||
            ['executions', _, 'lease'] ||
            ['executions', _]:
          throw ApiError(405, 'method_not_allowed', '$method is not allowed');
        default:
          throw ApiError(404, 'not_found', 'no such route');
      }
    } on ApiError catch (e) {
      await _safeJson(response, e.status, e.toJson());
    } catch (e, st) {
      _log(LogLevel.error, 'request ${request.uri.path} failed: $e\n$st');
      await _safeJson(
        response,
        500,
        ApiError(500, 'internal', 'internal error').toJson(),
      );
    }
  }

  bool _authorized(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header == null || !header.startsWith('Bearer ')) return false;
    return _constantTimeEquals(header.substring(7), serviceKey);
  }

  static bool _constantTimeEquals(String a, String b) {
    final x = utf8.encode(a);
    final y = utf8.encode(b);
    var diff = x.length ^ y.length;
    for (var i = 0; i < x.length; i++) {
      diff |= x[i] ^ y[i % (y.isEmpty ? 1 : y.length)];
    }
    return diff == 0 && y.isNotEmpty;
  }

  Future<Map<String, Object?>> _body(HttpRequest request) async {
    if (request.contentLength > maxBodyBytes) {
      throw ApiError(413, 'body_too_large', 'request body exceeds 8 MiB');
    }
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
    requireProtocol(body);
    return body;
  }

  static int _generation(Map<String, Object?> body) {
    final g = body['generation'];
    if (g is! int || g < 0) {
      throw invalidRequest('generation must be a non-negative integer');
    }
    return g;
  }

  RunRecord _run(String id) {
    final run = store.run(id);
    if (run == null) throw ApiError(404, 'run_not_found', 'no run $id');
    return run;
  }

  Map<String, Object?> _health() => {
    'protocol': protocolName,
    'status': innerUrl == null ? 'degraded' : 'ok',
    'sandbox': 'disabled',
    'version': serviceVersion,
  };

  Future<void> _postOperation(HttpRequest request) async {
    final body = await _body(request);
    final op = OperationRequest.parse(body);
    final executionId = op.execution.executionId;
    if (_stopping) {
      throw ApiError(503, 'shutting_down', 'the agent service is stopping');
    }
    // Everything below is synchronous: no other request interleaves between
    // the lookups and the write of the new run.
    final x = store.execution(executionId);
    if (x?.deletedAt != null) {
      throw ApiError(
        410,
        'execution_deleted',
        'execution $executionId was deleted',
      );
    }
    store.checkGeneration(executionId, op.generation);
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
      final run = store.run(existing.runId);
      if (run != null) {
        store.observeGeneration(executionId, op.generation);
        return _json(request.response, 200, run.statusJson());
      }
    }
    verifyContinuation(op);
    final runToken = request.headers.value('x-agent-run-token');
    if (runToken == null || runToken.isEmpty) {
      throw invalidRequest('the X-Agent-Run-Token header is required');
    }
    final record = store.createRun(op, digest);
    final run = AgentRun(
      record: record,
      request: op,
      store: store,
      innerBase: innerUrl,
      serviceKey: serviceKey,
      runToken: runToken,
      log: (m) => _log(LogLevel.error, m),
    );
    _live[record.runId] = run;
    unawaited(run.done.whenComplete(() => _live.remove(record.runId)));
    _log(LogLevel.info, 'run ${record.runId} started');
    // Start after the 202 is queued.
    Timer.run(() => unawaited(run.start()));
    return _json(request.response, 202, {
      'protocol': protocolName,
      'run_id': record.runId,
      'status': 'running',
    });
  }

  void _listRuns(HttpRequest request) {
    final state = request.uri.queryParameters['state'];
    if (state != 'active') {
      throw invalidRequest('state must be "active"');
    }
    final runs = [
      for (final r in store.runs)
        if (!r.isEnded || !r.acknowledged)
          {
            'run_id': r.runId,
            'operation_id': r.operationId,
            'execution_id': r.executionId,
            'generation': r.generation,
            'status': r.status,
            'acknowledged': r.acknowledged,
            'last_event_id': r.lastEventId,
          },
    ];
    _json(request.response, 200, {'protocol': protocolName, 'runs': runs});
  }

  Future<void> _events(HttpRequest request, RunRecord run) async {
    final afterText =
        request.uri.queryParameters['after'] ??
        request.headers.value('last-event-id');
    final after = afterText == null ? 0 : int.tryParse(afterText.trim());
    if (after == null) throw invalidRequest('after must be an integer');
    final stored = store.eventsAfter(run, after);
    final response = request.response
      ..statusCode = 200
      ..bufferOutput = false;
    response.headers
      ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
      ..set(HttpHeaders.cacheControlHeader, 'no-cache')
      ..set('X-Accel-Buffering', 'no');

    var lastSent = after;
    var closed = false;
    final finished = Completer<void>();
    StreamSubscription<RunEvent>? sub;
    Timer? keepAlive;

    void end() {
      if (finished.isCompleted) return;
      keepAlive?.cancel();
      unawaited(sub?.cancel());
      finished.complete();
    }

    void write(RunEvent e) {
      if (closed || e.id <= lastSent) return;
      lastSent = e.id;
      try {
        response.write(
          'id: ${e.id}\nevent: ${e.event}\ndata: ${jsonEncode(e.data)}\n\n',
        );
      } catch (_) {
        closed = true;
        end();
        return;
      }
      if (e.isTerminal) end();
    }

    // Subscribe and replay synchronously so no event falls in between.
    final live = _live[run.runId];
    if (live != null && !live.isEnded) {
      sub = live.events.listen(write, onDone: end);
    }
    for (final e in stored) {
      write(e);
    }
    if (sub == null && !finished.isCompleted) end();
    if (!finished.isCompleted) {
      keepAlive = Timer.periodic(keepAliveInterval, (_) {
        if (closed) return;
        try {
          response.write(': keep-alive\n\n');
        } catch (_) {
          closed = true;
          end();
        }
      });
      unawaited(
        response.done.then((_) {}, onError: (_) {}).whenComplete(() {
          closed = true;
          end();
        }),
      );
    }
    await finished.future;
    try {
      await response.close();
    } catch (_) {
      // The subscriber went away; the run is unaffected.
    }
  }

  Future<void> _ack(HttpRequest request, RunRecord run) async {
    final body = await _body(request);
    final generation = _generation(body);
    final resultEventId = body['result_event_id'];
    if (resultEventId is! int) {
      throw invalidRequest('result_event_id must be an integer');
    }
    store.checkGeneration(run.executionId, generation);
    if (!run.isEnded) {
      throw ApiError(409, 'run_active', 'run ${run.runId} has not ended');
    }
    if (resultEventId != run.result!.id) {
      throw ApiError(
        409,
        'result_mismatch',
        'result_event_id $resultEventId is not the terminal event ${run.result!.id}',
      );
    }
    store.acknowledge(run);
    _json(request.response, 200, run.statusJson());
  }

  Future<void> _cancel(HttpRequest request, RunRecord run) async {
    final body = await _body(request);
    store.checkGeneration(run.executionId, _generation(body));
    final live = _live[run.runId];
    if (run.isEnded || live == null) {
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
    live.stop(StopReason.cancel);
    _json(request.response, 202, {
      'protocol': protocolName,
      'run_id': run.runId,
      'status': run.status,
    });
  }

  Future<void> _lease(HttpRequest request, String executionId) async {
    final body = await _body(request);
    final generation = _generation(body);
    final ttl = body['ttl_seconds'] ?? 120;
    if (ttl is! int || ttl < 1 || ttl > 3600) {
      throw invalidRequest('ttl_seconds must be an integer in 1..3600');
    }
    if (store.execution(executionId)?.deletedAt != null) {
      throw ApiError(
        410,
        'execution_deleted',
        'execution $executionId was deleted',
      );
    }
    store.checkGeneration(executionId, generation);
    store.observeGeneration(executionId, generation);
    final expiresAt = leases.renew(executionId, Duration(seconds: ttl));
    _json(request.response, 200, {
      'protocol': protocolName,
      'execution_id': executionId,
      'generation': generation,
      'expires_at': expiresAt.toIso8601String(),
    });
  }

  Future<void> _deleteExecution(HttpRequest request, String executionId) async {
    final body = await _body(request);
    final generation = _generation(body);
    store.checkGeneration(executionId, generation);
    final running = _live.values
        .where((r) => r.record.executionId == executionId)
        .toList();
    for (final r in running) {
      r.stop(StopReason.cancel);
    }
    await Future.wait(running.map((r) => r.done))
        .timeout(const Duration(seconds: 5), onTimeout: () => const []);
    leases.remove(executionId);
    store.deleteExecution(executionId);
    _json(request.response, 200, {
      'protocol': protocolName,
      'execution_id': executionId,
      'deleted': true,
    });
  }

  void _json(HttpResponse response, int status, Map<String, Object?> body) {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    unawaited(response.close().then((_) {}, onError: (_) {}));
  }

  Future<void> _safeJson(
    HttpResponse response,
    int status,
    Map<String, Object?> body,
  ) async {
    try {
      _json(response, status, body);
    } catch (_) {
      // Headers already sent (an event stream); nothing more to say.
    }
  }
}
