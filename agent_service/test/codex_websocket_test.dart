// The official Codex runtime with `model.transport: websocket` against a
// scripted app-server (codex_app_server_fake.dart): Codex is configured for
// the Responses WebSocket, its log is followed, and a fallback to HTTP, seen
// as Codex's `warning` notification or its log line, ends the run. The real
// binary is covered by codex_websocket_binary_test.dart.
import 'dart:async';
import 'dart:convert';

import 'package:agent_service/src/harness/codex/official.dart';
import 'package:test/test.dart';

import 'codex_app_server_fake.dart';

void main() {
  Map<String, Object?> wsOp({String? transport = 'websocket'}) {
    final o = officialCodexOp();
    return {
      ...o,
      'model': {...o['model'] as Map<String, Object?>, 'transport': ?transport},
    };
  }

  Future<(Map<String, Object?>, List<String>, List<Map<String, Object?>>)> ran(
    FakeCodexAppServer fake, {
    Map<String, Object?>? op,
  }) async {
    final (h, run, _) = await fake.startRun(op ?? wsOp());
    final status = await h.waitEnded(run, timeout: const Duration(seconds: 30));
    final events = await h.events(run);
    return (
      (status['result'] as Map).cast<String, Object?>(),
      [for (final e in events) e.event],
      [for (final e in events) e.data],
    );
  }

  void answer(FakeCodexAppServer s) => s
    ..usage()
    ..message('Done.', phase: 'final_answer')
    ..complete({'status': 'completed'});

  test('Codex is configured for the WebSocket; the turn starts once its '
      'startup handshake is answered', () async {
    final fake = FakeCodexAppServer(turn: (s) async => answer(s));
    final (result, names, data) = await ran(fake);
    expect(names.last, 'succeeded', reason: jsonEncode(result));
    expect(result['candidate'], {'text': 'Done.'});
    expect((data.first['runtime'] as Map)['transport'], 'websocket');
    final toml = fake.configToml!;
    expect(toml, contains('supports_websockets = true\n'));
    expect(toml, contains('websocket_connect_timeout_ms = 15000\n'));
    expect(
      toml,
      contains('http_headers = { "X-DifySF-Require-Incremental" = "v1" }\n'),
    );
    expect(
      toml,
      contains(
        'exclude = ["DIFYSF_RUN_TOKEN", "SHELLCTL_*", "RUST_LOG", '
        '"LOG_FORMAT"]',
      ),
    );
    // The app-server logs its WebSocket state as JSON lines.
    final env = fake.appServerEnv!;
    expect(env['RUST_LOG'], codexWebsocketLogEnv['RUST_LOG']);
    expect(env['LOG_FORMAT'], 'json');
    expect(fake.methods, containsAllInOrder(['thread/start', 'turn/start']));
  });

  test(
    'without model.transport nothing changes: HTTP, no log settings',
    () async {
      final fake = FakeCodexAppServer(turn: (s) async => answer(s));
      final (result, names, data) = await ran(fake, op: wsOp(transport: null));
      expect(names.last, 'succeeded', reason: jsonEncode(result));
      expect((data.first['runtime'] as Map)['transport'], 'http');
      expect(fake.configToml, contains('supports_websockets = false\n'));
      expect(fake.configToml, isNot(contains('RUST_LOG')));
      expect(fake.appServerEnv!.containsKey('RUST_LOG'), isFalse);
      expect(fake.appServerEnv!.containsKey('LOG_FORMAT'), isFalse);
    },
  );

  test('a 426 at the startup handshake ends the run before the turn: '
      'nothing went over HTTP', () async {
    final fake = FakeCodexAppServer(
      websocketStartup: [
        FakeCodexAppServer.wsFailed('HTTP error: 426 Upgrade Required'),
        FakeCodexAppServer.wsFallback(),
      ],
      turn: (s) async => answer(s),
    );
    final (result, names, data) = await ran(fake);
    expect(names, ['run_started', 'failed'], reason: jsonEncode(result));
    expect((data.first['runtime'] as Map)['transport'], 'websocket');
    expect(result['error_type'], 'model_error');
    expect(
      result['message'],
      'Codex fell back from WebSockets to HTTP: the WebSocket handshake '
      'failed (HTTP error: 426 Upgrade Required); the run ended before its '
      'turn started: no request went over HTTP',
    );
    expect(fake.methods, isNot(contains('turn/start')));
  });

  test('a failed startup handshake without a fallback: Codex retries in the '
      'turn, which runs', () async {
    final fake = FakeCodexAppServer(
      websocketStartup: [
        FakeCodexAppServer.wsFailed('IO error: Connection reset by peer'),
      ],
      turn: (s) async {
        s.log(FakeCodexAppServer.wsConnected());
        answer(s);
      },
    );
    final (result, names, _) = await ran(fake);
    expect(names.last, 'succeeded', reason: jsonEncode(result));
    expect(fake.methods, contains('turn/start'));
  });

  test('Codex\'s fallback warning during the turn interrupts it; the run '
      'ends model_error and says the request went over HTTP', () async {
    final interrupted = Completer<void>();
    final fake = FakeCodexAppServer(
      turn: (s) async {
        s
          ..item('started', {
            'type': 'commandExecution',
            'id': 'c1',
            'command': 'make',
            'cwd': '/workspace',
          })
          ..usage()
          ..notify('error', {
            'threadId': 'thr_root',
            'turnId': 'turn_1',
            'willRetry': true,
            'error': {
              'message': 'Reconnecting... 2/2',
              'codexErrorInfo': 'responseStreamDisconnected',
            },
          })
          ..notify('warning', {
            'threadId': 'thr_root',
            'message':
                '$codexWebsocketFallbackWarning stream disconnected before '
                'completion: websocket closed by server before '
                'response.completed',
          });
        // The run interrupts the turn (the fake then ends it).
        while (!s.methods.contains('turn/interrupt')) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        interrupted.complete();
      },
    );
    final (result, names, data) = await ran(fake);
    expect(interrupted.isCompleted, isTrue);
    expect(names.last, 'failed', reason: jsonEncode(result));
    expect(result['error_type'], 'model_error');
    expect(
      result['message'],
      'Codex fell back from WebSockets to HTTP: the model request kept '
      'failing on the WebSocket and Codex\'s stream retries (2) were used '
      'up: stream disconnected before completion: websocket closed by '
      'server before response.completed; Codex sends the model request it '
      'was making over HTTP right after switching (the whole conversation, '
      'marked X-DifySF-Require-Incremental for the gateway to refuse); the '
      'turn was interrupted',
    );
    // The command Codex started is closed with the run's error.
    final finished = data.lastWhere(
      (d) => d['id'] == 'c1' && d['phase'] == 'finished',
    );
    expect(finished['error'], startsWith('the run ended: Codex fell back'));
    expect(names, contains('model_retry'));
  });

  test('a fallback only in Codex\'s log (a 426 on a reconnect sends no '
      'notification) interrupts the turn too', () async {
    final fake = FakeCodexAppServer(
      turn: (s) async {
        s
          ..usage()
          ..log(FakeCodexAppServer.wsFailed('HTTP error: 426 Upgrade Required'))
          ..log(FakeCodexAppServer.wsFallback());
        while (!s.methods.contains('turn/interrupt')) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      },
    );
    final (result, names, _) = await ran(fake);
    expect(names.last, 'failed', reason: jsonEncode(result));
    expect(result['error_type'], 'model_error');
    expect(
      result['message'],
      startsWith(
        'Codex fell back from WebSockets to HTTP: the WebSocket handshake '
        'failed (HTTP error: 426 Upgrade Required); Codex sends the model '
        'request it was making over HTTP',
      ),
    );
  });

  test('a fallback logged during a turn that completes at once still ends '
      'the run', () async {
    final fake = FakeCodexAppServer(
      turn: (s) async {
        s
          ..log(FakeCodexAppServer.wsFallback())
          ..usage()
          ..message('Answered over HTTP.', phase: 'final_answer')
          ..complete({'status': 'completed'});
      },
    );
    final (result, names, _) = await ran(fake);
    expect(names.last, 'failed', reason: jsonEncode(result));
    expect(
      result['message'],
      startsWith(
        'Codex fell back from WebSockets to HTTP: the model request kept '
        'failing on the WebSocket; Codex s',
      ),
    );
  });

  test('the gateway\'s refusal of an HTTP model call (a fallback the log '
      'did not show) is the same failure', () async {
    const body =
        '{"error":{"type":"invalid_request_error","code":'
        '"incremental_required","message":"HTTP model calls are refused"}}';
    final fake = FakeCodexAppServer(
      turn: (s) async => s.fail('badRequest', body),
    );
    final (result, names, _) = await ran(fake);
    expect(names.last, 'failed', reason: jsonEncode(result));
    expect(result['error_type'], 'model_error');
    expect(
      result['message'],
      'Codex fell back from WebSockets to HTTP: the gateway refused its HTTP '
      'model request (X-DifySF-Require-Incremental, incremental_required); '
      'Codex: $body',
    );
    // Over HTTP the same answer is only Codex's error.
    final http = FakeCodexAppServer(
      turn: (s) async => s.fail('badRequest', body),
    );
    final (other, _, _) = await ran(http, op: wsOp(transport: null));
    expect(other['message'], 'Codex: $body ("badRequest")');
  });

  test('a 426 on a reconnect logged as the gateway\'s refusal ends the turn: '
      'the fallback error says the request was refused', () async {
    const body =
        '{"error":{"type":"invalid_request_error","code":'
        '"incremental_required","message":"HTTP model calls are refused"}}';
    final fake = FakeCodexAppServer(
      turn: (s) async {
        s
          ..fail('badRequest', body)
          ..log(FakeCodexAppServer.wsFailed('HTTP error: 426 Upgrade Required'))
          ..log(FakeCodexAppServer.wsFallback());
      },
    );
    final (result, names, _) = await ran(fake);
    expect(names.last, 'failed', reason: jsonEncode(result));
    const why =
        'Codex fell back from WebSockets to HTTP: the WebSocket handshake '
        'failed (HTTP error: 426 Upgrade Required); ';
    // Read after the turn's end (usually), or while it ends.
    expect(
      result['message'],
      anyOf(
        '${why}Codex sent the model request it was making over HTTP (the '
        'whole conversation, marked X-DifySF-Require-Incremental) and the '
        'gateway refused it (incremental_required); the turn ended',
        startsWith('${why}Codex sends the model request'),
      ),
    );
  });

  test('the fallback warning of an HTTP run is only logged', () async {
    final fake = FakeCodexAppServer(
      turn: (s) async {
        s.notify('warning', {
          'threadId': 'thr_root',
          'message': '$codexWebsocketFallbackWarning boom',
        });
        answer(s);
      },
    );
    final (result, names, _) = await ran(fake, op: wsOp(transport: 'http'));
    expect(names.last, 'succeeded', reason: jsonEncode(result));
  });
}
