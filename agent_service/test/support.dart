import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/testing.dart';
import 'package:http/http.dart' as http;

const testKey = 'test-service-key';
const runToken = 'test-run-token';
const testSupervisorKey = 'test-supervisor-key';

/// A server-sent event read from the agent service.
class Sse {
  Sse(this.id, this.event, this.data);
  final int id;
  final String event;
  final Map<String, Object?> data;
  @override
  String toString() => 'Sse($id $event ${jsonEncode(data)})';
}

/// Test data directories live under the package's `.dart_tool`, not /tmp.
Directory newDataDir() {
  final root = Directory(
    '${Directory.current.path}/.dart_tool/agent_service_test',
  )..createSync(recursive: true);
  return root.createTempSync('run-');
}

class Harness {
  Harness._(this.gateway, this.dataDir, this.clock);

  final ScriptedGateway gateway;
  final Directory dataDir;
  final TestClock clock;
  late AgentService service;
  final http.Client client = http.Client();
  String _supervisorKey = testSupervisorKey;
  ExecutorProfiles? _profiles;
  CodexRuntime _codexRuntime = CodexRuntime.port;
  String? _codexGatewayUrl;

  Uri get base => Uri.parse('http://127.0.0.1:${service.port}');

  /// The sandbox supervisor the service uses (none: shell disabled).
  Uri? supervisorUrl;

  static Future<Harness> start({
    List<ScriptedCall> calls = const [],
    Map<String, Map<String, Object?>> files = const {},
    Uri? supervisorUrl,
    String supervisorKey = testSupervisorKey,
    ExecutorProfiles? profiles,
    CodexRuntime codexRuntime = CodexRuntime.port,
    String? codexGatewayUrl,
  }) async {
    final gateway = ScriptedGateway(
      calls: calls,
      files: files,
      serviceKey: testKey,
    );
    await gateway.start();
    final h = Harness._(gateway, newDataDir(), TestClock())
      ..supervisorUrl = supervisorUrl
      .._supervisorKey = supervisorKey
      .._profiles = profiles
      .._codexRuntime = codexRuntime
      .._codexGatewayUrl = codexGatewayUrl;
    await h._startService();
    return h;
  }

  Future<void> _startService() async {
    service = AgentService(
      serviceKey: testKey,
      dataDir: dataDir.path,
      innerUrl: gateway.url,
      clock: clock.now,
      logLevel: LogLevel.error,
      supervisor: supervisorUrl == null
          ? null
          : SupervisorClient(supervisorUrl!, _supervisorKey),
      profiles: _profiles,
      profileStatusTtl: Duration.zero,
      // These suites test the Dart port unless a test asks for the official
      // runtime.
      codexRuntime: _codexRuntime,
      codexGatewayUrl: _codexGatewayUrl,
    );
    await service.start(address: '127.0.0.1', port: 0);
  }

  /// Stops this service instance and starts a new one on the same data dir.
  Future<void> restart() async {
    await service.stop();
    await _startService();
  }

  Future<void> close() async {
    await service.stop();
    client.close();
    await gateway.close();
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  }

  Map<String, String> headers({String? key = testKey, bool token = true}) => {
    'Content-Type': 'application/json',
    if (key != null) 'Authorization': 'Bearer $key',
    if (token) 'X-Agent-Run-Token': runToken,
  };

  Future<(int, Map<String, Object?>)> post(
    String path,
    Map<String, Object?> body, {
    String? key = testKey,
  }) async {
    final r = await client.post(
      base.resolve(path),
      headers: headers(key: key),
      body: jsonEncode(body),
    );
    return (r.statusCode, _decode(r.body));
  }

  Future<(int, Map<String, Object?>)> get(String path) async {
    final r = await client.get(base.resolve(path), headers: headers());
    return (r.statusCode, _decode(r.body));
  }

  Future<(int, Map<String, Object?>)> delete(
    String path,
    Map<String, Object?> body,
  ) async {
    final req = http.Request('DELETE', base.resolve(path))
      ..headers.addAll(headers())
      ..body = jsonEncode(body);
    final r = await http.Response.fromStream(await client.send(req));
    return (r.statusCode, _decode(r.body));
  }

  static Map<String, Object?> _decode(String body) => body.isEmpty
      ? const {}
      : (jsonDecode(body) as Map).cast<String, Object?>();

  /// Starts an operation; returns its run ID (expects 202).
  Future<String> startOperation(Map<String, Object?> body) async {
    final (status, json) = await post('/v1/operations', body);
    if (status != 202) {
      throw StateError('expected 202, got $status ${jsonEncode(json)}');
    }
    return json['run_id'] as String;
  }

  /// Reads events after [after] until the stream ends.
  Future<List<Sse>> events(String runId, {int? after, int? lastEventId}) async {
    final (status, events) = await eventsWithStatus(
      runId,
      after: after,
      lastEventId: lastEventId,
    );
    if (status != 200) throw StateError('events answered $status');
    return events;
  }

  Future<(int, List<Sse>)> eventsWithStatus(
    String runId, {
    int? after,
    int? lastEventId,
  }) async {
    final uri = base.replace(
      path: '/v1/runs/$runId/events',
      queryParameters: after == null ? null : {'after': '$after'},
    );
    final req = http.Request('GET', uri)..headers.addAll(headers());
    if (lastEventId != null) req.headers['Last-Event-ID'] = '$lastEventId';
    final res = await client.send(req);
    if (res.statusCode != 200) {
      await res.stream.drain<void>();
      return (res.statusCode, <Sse>[]);
    }
    final out = <Sse>[];
    await for (final block in _sseBlocks(res.stream)) {
      out.add(block);
    }
    return (200, out);
  }

  /// Opens an event stream and returns the subscription-like handle.
  Future<(http.StreamedResponse, Stream<Sse>)> openEvents(String runId) async {
    final req = http.Request('GET', base.resolve('/v1/runs/$runId/events'))
      ..headers.addAll(headers());
    final res = await http.Client().send(req);
    return (res, _sseBlocks(res.stream));
  }

  static Stream<Sse> _sseBlocks(Stream<List<int>> bytes) async* {
    int? id;
    String? event;
    final data = <String>[];
    await for (final line
        in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (event != null) {
          yield Sse(
            id ?? 0,
            event,
            (jsonDecode(data.join('\n')) as Map).cast<String, Object?>(),
          );
        }
        id = null;
        event = null;
        data.clear();
      } else if (line.startsWith('id: ')) {
        id = int.parse(line.substring(4));
      } else if (line.startsWith('event: ')) {
        event = line.substring(7);
      } else if (line.startsWith('data: ')) {
        data.add(line.substring(6));
      }
    }
  }

  /// Polls the status until the run ended.
  Future<Map<String, Object?>> waitEnded(
    String runId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final (status, json) = await get('/v1/runs/$runId');
      if (status != 200) throw StateError('status answered $status');
      if (json['status'] != 'running') return json;
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('run $runId did not end');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

class TestClock {
  Duration offset = Duration.zero;
  DateTime now() => DateTime.now().toUtc().add(offset);
}

/// An operation request body.
Map<String, Object?> operation({
  String executionId = 'E1',
  int outputAttempt = 0,
  int resumeSequence = 0,
  int generation = 1,
  String task = 'Plan a trip.',
  List<Map<String, Object?>>? taskParts,
  Map<String, Object?>? outputSchema,
  bool askHuman = true,
  bool shell = false,
  bool viewImage = false,
  String? executorProfile,
  Map<String, Object?> env = const {},
  List<Map<String, Object?>> files = const [],
  int maxTurns = 10,
  int timeoutSeconds = 60,
  Map<String, Object?>? continuation,
  String configSnapshotId = 'cfg-1',
  String protocol = protocolName,
}) => {
  'protocol': protocol,
  'operation_id': '$executionId:$outputAttempt:$resumeSequence',
  'generation': generation,
  'execution': {
    'tenant_id': 'T1',
    'app_id': 'A1',
    'workflow_run_id': 'W1',
    'node_id': 'N1',
    'execution_id': executionId,
    'agent_config_snapshot_id': configSnapshotId,
    'user_id': 'U1',
    'user_from': 'account',
    'invoke_from': 'debugger',
  },
  'model': {
    'provider': 'langgenius/openai_api_compatible/openai_api_compatible',
    'name': 'test-model',
    'parameters': {'temperature': 0.7},
  },
  'system_prompt': 'You are a helpful agent.',
  'task':
      taskParts ??
      [
        {'type': 'text', 'text': task},
      ],
  'output_schema': outputSchema,
  'tools': {
    'ask_human': askHuman,
    'shell': shell,
    'view_image': ?(viewImage ? true : null),
  },
  'env': env,
  'files': files,
  'limits': {'max_turns': maxTurns, 'timeout_seconds': timeoutSeconds},
  'continuation': continuation,
  'executor_profile': ?executorProfile,
};

Map<String, Object?> answer(
  Map<String, Object?> pausedResult,
  Map<String, Object?> values,
) => {
  'kind': 'answer',
  'question_id': pausedResult['question_id'],
  'snapshot': pausedResult['snapshot'],
  'result': {
    'status': 'submitted',
    'action': {'id': 'submit', 'label': 'Submit'},
    'values': values,
    'rendered_content': 'answered',
  },
};
