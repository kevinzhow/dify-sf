// A scripted `codex app-server` for the official Codex runtime's unit tests:
// the fake sandbox starts it when the run launches the app-server job, and it
// answers the JSON-RPC requests over a WebSocket on the job's port, then plays
// the test's transcript of notifications and server requests for the turn.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/src/harness/codex/official.dart';
import 'package:agent_service/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// One scripted app-server per test.
class FakeCodexAppServer {
  FakeCodexAppServer({
    this.threadModel,
    this.threadEffort,
    this.threadStartReply,
    required this.turn,
  });

  /// The `model` and `reasoningEffort` of the `thread/start` reply (default:
  /// what the operation asked for).
  final String? threadModel;
  final String? threadEffort;

  /// Replaces the whole `thread/start` reply.
  final Map<String, Object?>? threadStartReply;

  /// Plays the turn once `turn/start` is answered.
  final Future<void> Function(FakeCodexAppServer s) turn;

  /// Client requests and notifications in arrival order.
  final List<({String method, Map<String, Object?> params})> received = [];

  /// Answers of the client to the server requests sent with [request].
  final Map<int, Map<String, Object?>> answers = {};

  HttpServer? _http;
  WebSocket? _ws;
  FakeShellctl? _shellctl;
  int _nextId = 1000;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  bool _turnEnded = false;

  /// The model and effort the run asked for (from config.toml), set when
  /// the app-server starts.
  String? configModel;
  String? configEffort;

  static final _listen = RegExp(r'app-server --listen ws://0\.0\.0\.0:(\d+)');

  /// Methods received from the client.
  List<String> get methods => [for (final r in received) r.method];

  Map<String, Object?> paramsOf(String method) =>
      received.firstWhere((r) => r.method == method).params;

  /// The job script handler: starts the server for the app-server job.
  FakeJobSpec? onJob(String script) {
    final m = _listen.firstMatch(script);
    if (m == null) return null;
    unawaited(_start(int.parse(m.group(1)!)));
    return FakeJobSpec(running: true);
  }

  /// The written config.toml of the run (decoded from the setup script).
  void onSetup(String script) {
    final m = RegExp(
      r"base64 -d > '([^']*)' <<'DIFYSF_EOF'\n([\s\S]*?)\nDIFYSF_EOF",
    ).firstMatch(script);
    if (m == null || !m.group(1)!.endsWith('/config.toml')) return;
    final toml = utf8.decode(base64.decode(m.group(2)!.replaceAll('\n', '')));
    configModel = RegExp(
      r'^model = "(.*)"$',
      multiLine: true,
    ).firstMatch(toml)?.group(1);
    configEffort = RegExp(
      r'^model_reasoning_effort = "(.*)"$',
      multiLine: true,
    ).firstMatch(toml)?.group(1);
  }

  Future<void> _start(int port) async {
    final http = _http = await HttpServer.bind('127.0.0.1', port);
    http.listen((req) async {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        req.response.statusCode = 400;
        await req.response.close();
        return;
      }
      final ws = _ws = await WebSocketTransformer.upgrade(req);
      ws.listen((frame) => _onFrame(frame as String));
    });
  }

  void _send(Map<String, Object?> m) => _ws?.add(jsonEncode(m));

  void notify(String method, Map<String, Object?> params) =>
      _send({'method': method, 'params': params});

  /// A server request; completes with the client's answer (`result` or
  /// `error`).
  Future<Map<String, Object?>> request(
    String method,
    Map<String, Object?> params,
  ) {
    final id = _nextId++;
    final c = Completer<Map<String, Object?>>();
    _pending[id] = c;
    _send({'id': id, 'method': method, 'params': params});
    return c.future;
  }

  void _onFrame(String frame) {
    final m = (jsonDecode(frame) as Map).cast<String, Object?>();
    final method = m['method'];
    if (method is! String) {
      final c = _pending.remove(m['id']);
      c?.complete(m);
      return;
    }
    final params = (m['params'] as Map?)?.cast<String, Object?>() ?? {};
    received.add((method: method, params: params));
    final id = m['id'];
    if (id == null) return;
    void reply(Object? result) => _send({'id': id, 'result': result});
    switch (method) {
      case 'thread/start':
        reply(
          threadStartReply ??
              {
                'thread': {'id': 'thr_root'},
                'model': threadModel ?? configModel,
                'modelProvider': codexProviderId,
                'reasoningEffort': threadEffort ?? configEffort,
                'cwd': '/workspace',
                'approvalPolicy': 'never',
                'approvalsReviewer': 'user',
                'sandbox': {'type': 'dangerFullAccess'},
              },
        );
      case 'turn/start':
        reply({
          'turn': {
            'id': 'turn_1',
            'items': <Object?>[],
            'status': 'inProgress',
          },
        });
        unawaited(Future<void>.delayed(Duration.zero, () => turn(this)));
      case 'turn/interrupt':
        reply(<String, Object?>{});
        complete({'status': 'interrupted'});
      default:
        reply(<String, Object?>{});
    }
  }

  // ---- transcript helpers --------------------------------------------------

  void item(String phase, Map<String, Object?> item, {String? thread}) =>
      notify('item/$phase', {
        'threadId': thread ?? 'thr_root',
        'turnId': 'turn_1',
        'item': item,
      });

  void message(String text, {String? phase, String id = 'msg'}) => item(
    'completed',
    {'type': 'agentMessage', 'id': id, 'text': text, 'phase': phase},
  );

  void usage({String thread = 'thr_root'}) =>
      notify('thread/tokenUsage/updated', {
        'threadId': thread,
        'turnId': 'turn_1',
        'tokenUsage': {
          'last': {
            'inputTokens': 100,
            'cachedInputTokens': 0,
            'outputTokens': 10,
            'reasoningOutputTokens': 0,
            'totalTokens': 110,
          },
        },
      });

  /// `turn/completed` for the root turn (once).
  void complete(Map<String, Object?> turn) {
    if (_turnEnded) return;
    _turnEnded = true;
    notify('turn/completed', {
      'threadId': 'thr_root',
      'turn': {'id': 'turn_1', 'items': <Object?>[], ...turn},
    });
  }

  void fail(String info, String message, {String? details}) => complete({
    'status': 'failed',
    'error': {
      'message': message,
      'codexErrorInfo': info,
      'additionalDetails': details,
    },
  });

  /// The process ends: the connection closes and the job is done with
  /// [output] (its stderr is merged into it).
  Future<void> exit({required int exitCode, String output = ''}) async {
    final job = _shellctl!.jobs.values.firstWhere(
      (j) => j.script.contains('app-server --listen'),
    );
    job
      ..output = output
      ..exitCode = exitCode
      ..done = true
      ..status = 'exited';
    await _ws?.close();
    await _http?.close(force: true);
  }

  Future<void> close() async {
    await _ws?.close();
    await _http?.close(force: true);
  }

  /// A harness with a sandbox whose app-server job is this fake; returns
  /// the harness, the run ID and the fake sandbox.
  Future<(Harness, String, FakeShellctl)> startRun(
    Map<String, Object?> op,
  ) async {
    final profiles = ExecutorProfiles.parse({
      'version': 1,
      'profiles': {
        'default': {
          'image':
              'dify-sf/sandbox@sha256:'
              '1111111111111111111111111111111111111111111111111111111111111111',
          'mounts': [
            {'source': '/srv/codex', 'target': '/opt/codex'},
          ],
        },
      },
    });
    final shellctl = Completer<FakeShellctl>();
    final sup =
        FakeSupervisor(
            key: testSupervisorKey,
            configure: (s) {
              _shellctl = s;
              if (!shellctl.isCompleted) shellctl.complete(s);
              s
                ..onControl = ((script) async => script.contains('--version')
                    ? (
                        0,
                        'version codex-cli $officialCodexVersion\n'
                            'sha256 $officialCodexSha256\n',
                      )
                    : null)
                ..onJob = (script) {
                  onSetup(script);
                  return onJob(script) ??
                      FakeJobSpec(
                        output: script.contains('debug models --bundled')
                            ? '{"models": []}'
                            : script.contains('NO_PROXY')
                            ? '\n\n'
                            : '',
                      );
                };
            },
          )
          ..profiles = {
            for (final p in profiles.profiles.values)
              p.name: {'status': 'ok', 'digest': p.digest},
          };
    await sup.start();
    final h = await Harness.start(
      supervisorUrl: sup.url,
      profiles: profiles,
      codexRuntime: CodexRuntime.official,
      codexGatewayUrl: 'http://gw/inner/agent/codex/v1',
    );
    addTearDown(() async {
      await close();
      await h.close();
      await sup.close();
    });
    final run = await h.startOperation(op);
    final s = await shellctl.future;
    return (h, run, s);
  }
}

/// An operation of the official runtime.
Map<String, Object?> officialCodexOp({
  Object? effort,
  int maxTurns = 10,
  Map<String, Object?>? outputSchema,
  int? contextWindow,
}) {
  final o = operation(maxTurns: maxTurns, outputSchema: outputSchema);
  final model = Map.of(o['model'] as Map<String, Object?>)
    ..['run_token'] = 'secret-run-token';
  if (effort != null) model['parameters'] = {'reasoning_effort': effort};
  if (contextWindow != null) model['context_window'] = contextWindow;
  return {...o, 'harness_style': 'codex', 'model': model};
}
