import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/testing.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../tool/gen_fixtures.dart';

const key = fixtureServiceKey;

class Client {
  Client(this.fake);
  final FakeAgentService fake;
  final http.Client http_ = http.Client();

  Uri uri(String path, [Map<String, String>? query]) => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: fake.port,
    path: path,
    queryParameters: query,
  );

  Map<String, String> headers({bool token = true}) => {
    'Authorization': 'Bearer $key',
    'Content-Type': 'application/json',
    if (token) 'X-Agent-Run-Token': fixtureRunToken,
  };

  Future<(int, Map<String, Object?>)> send(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    Map<String, String>? headers,
  }) async {
    final req = http.Request(method, uri(path, query))
      ..headers.addAll(headers ?? this.headers());
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(await http_.send(req));
    return (
      res.statusCode,
      res.body.isEmpty
          ? <String, Object?>{}
          : (jsonDecode(res.body) as Map).cast<String, Object?>(),
    );
  }

  /// Reads an event stream; a reset connection ends the list
  /// (`dropped: true`).
  Future<({int status, List<Map<String, Object?>> events, bool dropped})>
  events(String runId, {int? after, Map<String, String>? headers}) async {
    final req = http.Request(
      'GET',
      uri('/v1/runs/$runId/events', after == null ? null : {'after': '$after'}),
    )..headers.addAll(headers ?? this.headers());
    final res = await http_.send(req);
    if (res.statusCode != 200) {
      await res.stream.drain<void>();
      return (
        status: res.statusCode,
        events: <Map<String, Object?>>[],
        dropped: false,
      );
    }
    final events = <Map<String, Object?>>[];
    var dropped = false;
    try {
      await for (final e in eventBlocks(res.stream)) {
        events.add(e);
      }
    } on http.ClientException {
      dropped = true;
    }
    // A reset may also look like a short stream without a terminal event.
    if (events.isEmpty || !terminalEvents.contains(events.last['event'])) {
      dropped = true;
    }
    return (status: 200, events: events, dropped: dropped);
  }

  void close() => http_.close();
}

Future<Client> startFake(Map<String, Object?> script) async {
  final fake = FakeAgentService(
    serviceKey: key,
    script: script,
    fixturesDir: fixturesPath,
  );
  await fake.start();
  final c = Client(fake);
  addTearDown(() async {
    c.close();
    await fake.close();
  });
  return c;
}

Map<String, Object?> body(Map<String, Object?> json, String key) =>
    (json[key] as Map).cast<String, Object?>();

final _timestamp = RegExp(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z');

Object? normalized(Object? v) => switch (v) {
  final String s => s.replaceAll(_timestamp, fixtureTimestamp),
  final Map<Object?, Object?> m => {
    for (final e in m.entries) e.key: normalized(e.value),
  },
  final List<Object?> l => [for (final x in l) normalized(x)],
  _ => v,
};

void main() {
  group('the fake replays every fixture step for step', () {
    final files =
        Directory(fixturesPath)
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final fixture = (jsonDecode(file.readAsStringSync()) as Map)
          .cast<String, Object?>();
      final name = fixture['fixture'] as String;
      test(name, () async {
        final steps = (fixture['steps'] as List).cast<Map>();
        // Runs that the real service ended from outside are held.
        final held = {'cancel_mid_stream', 'lease_expiry_cancel_lost'};
        final operations = <String, Object?>{
          for (final s in steps)
            if ((s['request'] as Map)['path'] == '/v1/operations' &&
                (s['response'] as Map)['status'] == 202)
              ((s['request'] as Map)['body'] as Map)['operation_id'] as String:
                  {'fixture': name, if (held.contains(name)) 'hold': true},
        };
        final c = await startFake({
          'operations': operations,
          'snapshot_check': 'full',
          'default_execution': {
            if (name == 'delete_cleanup_failed') 'delete_failures': 1,
          },
        });
        for (final step in steps) {
          final req = (step['request'] as Map).cast<String, Object?>();
          final want = (step['response'] as Map).cast<String, Object?>();
          final headers = (req['headers'] as Map).cast<String, String>();
          final path = req['path'] as String;
          final query = (req['query'] as Map?)?.cast<String, String>();
          final what = '$name/${step['step']}';
          if (want.containsKey('events')) {
            final got = await c.events(
              path.split('/')[3],
              after: query == null ? null : int.parse(query['after']!),
              headers: headers,
            );
            expect(got.status, 200, reason: what);
            expect(got.events, want['events'], reason: what);
            continue;
          }
          final (status, json) = await c.send(
            req['method'] as String,
            path,
            body: (req['body'] as Map?)?.cast<String, Object?>(),
            query: query,
            headers: headers,
          );
          expect(status, want['status'], reason: what);
          expect(normalized(json), want['body'], reason: what);
          if (step['step'] == 'cancel') {
            // The fake ends a cancelled run at once; wait like the real one.
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }
      });
    }
  });

  test('a stream dropped after N events resumes with the cursor', () async {
    final c = await startFake({
      'default': {'drop_stream_after': 2},
    });
    final (s, j) = await c.send('POST', '/v1/operations', body: operation());
    expect(s, 202);
    final run = j['run_id'] as String;
    final first = await c.events(run);
    expect(first.dropped, isTrue);
    expect(first.events.map((e) => e['id']), [1, 2]);
    final rest = await c.events(run, after: 2);
    expect(rest.dropped, isFalse);
    expect(rest.events.map((e) => e['event']), ['succeeded']);
    expect(rest.events.single['id'], 3);
  });

  test('the terminal event can be sent twice', () async {
    final c = await startFake({
      'default': {'duplicate_terminal': true},
    });
    final (_, j) = await c.send('POST', '/v1/operations', body: operation());
    final got = await c.events(j['run_id'] as String);
    final terminal = got.events.where((e) => e['event'] == 'succeeded');
    expect(terminal, hasLength(2));
    expect(terminal.first, terminal.last);
  });

  test('a late terminal result after cancel', () async {
    final c = await startFake({
      'default': {
        'events': [
          {
            'event': 'run_started',
            'data': {'model': {}, 'call_index_base': 0},
          },
        ],
        'result': {
          'event': 'succeeded',
          'data': {
            'candidate': {'text': 'too late'},
            'candidate_errors': <Object?>[],
            'usage': <String, Object?>{},
          },
        },
        'hold': true,
        'on_cancel': {'result': true, 'delay_ms': 100},
      },
    });
    final (_, j) = await c.send('POST', '/v1/operations', body: operation());
    final run = j['run_id'] as String;
    final (cs, cj) = await c.send(
      'POST',
      '/v1/runs/$run/cancel',
      body: {'protocol': protocolName, 'generation': 1},
    );
    expect(cs, 202);
    expect(cj['status'], 'running');
    final got = await c.events(run);
    expect(got.events.last['event'], 'succeeded');
    final (_, status) = await c.send('GET', '/v1/runs/$run');
    expect(status['status'], 'succeeded');
  });

  test('expired cursors answer 410; the end cursor is still 200', () async {
    final c = await startFake({
      'default': {'expire_cursors': true},
    });
    final (_, j) = await c.send('POST', '/v1/operations', body: operation());
    final run = j['run_id'] as String;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect((await c.events(run)).status, 410);
    final atEnd = await c.events(run, after: 3);
    expect(atEnd.status, 200);
    expect(atEnd.events, isEmpty);
  });

  test('scripted rejections, then acceptance', () async {
    final c = await startFake({
      'operations': {
        'E1:0:0': {
          'reject': {
            'status': 409,
            'error': 'stale_generation',
            'message': 'scripted',
            'extra': {'generation': 7},
            'times': 1,
          },
        },
      },
    });
    final (s1, j1) = await c.send('POST', '/v1/operations', body: operation());
    expect(s1, 409);
    expect(j1['error'], 'stale_generation');
    expect(j1['generation'], 7);
    final (s2, _) = await c.send('POST', '/v1/operations', body: operation());
    expect(s2, 202);
  });

  test('requests are validated like the real service', () async {
    final c = await startFake({});
    final (s1, j1) = await c.send(
      'POST',
      '/v1/operations',
      body: operation(env: {'NO_PROXY': '*'}),
    );
    expect((s1, j1['error']), (400, 'reserved_env'));
    final (s2, j2) = await c.send(
      'POST',
      '/v1/operations',
      body: operation(),
      headers: c.headers(token: false),
    );
    expect((s2, j2['error']), (400, 'invalid_request'));
    final (s3, j3) = await c.send(
      'POST',
      '/v1/operations',
      body: operation(),
      headers: {'Authorization': 'Bearer nope'},
    );
    expect((s3, j3['error']), (401, 'unauthorized'));
  });

  test(
    'a lost POST response: the resend answers 200 with the same run',
    () async {
      final c = await startFake({
        'default': {'lose_post_response': 1},
      });
      await expectLater(
        c.send('POST', '/v1/operations', body: operation()),
        throwsA(isA<http.ClientException>()),
      );
      final (s, j) = await c.send('POST', '/v1/operations', body: operation());
      expect(s, 200);
      expect(j['operation_id'], 'E1:0:0');
      final (_, log) = await c.send('GET', '/_fake/requests');
      final posts = (log['requests'] as List)
          .cast<Map>()
          .where((r) => r['path'] == '/v1/operations')
          .toList();
      expect(posts.map((r) => r['status']), ['connection_reset', 200]);
    },
  );

  test('delays and DELETE failures', () async {
    final c = await startFake({
      'delays_ms': {'post': 200},
      'executions': {
        'E1': {'delete_failures': 2},
      },
    });
    final sw = Stopwatch()..start();
    final (s, _) = await c.send('POST', '/v1/operations', body: operation());
    expect(s, 202);
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(200));
    final delete = {'protocol': protocolName, 'generation': 1};
    final statuses = [
      for (var i = 0; i < 3; i++)
        (await c.send('DELETE', '/v1/executions/E1', body: delete)).$1,
    ];
    expect(statuses, [503, 503, 200]);
  });

  test('the default snapshot resumes; the script can be replaced', () async {
    final c = await startFake({'snapshot_check': 'full'});
    final (_, j) = await c.send('POST', '/v1/operations', body: operation());
    final run = j['run_id'] as String;
    final got = await c.events(run);
    final result = body(got.events.last, 'data');
    expect(result['candidate'], {'text': 'Hello from the fake agent service.'});
    final (s2, _) = await c.send(
      'POST',
      '/v1/operations',
      body: operation(
        outputAttempt: 1,
        continuation: {
          'kind': 'output_retry',
          'snapshot': result['snapshot'],
          'feedback': [
            {'field': '', 'error': 'again'},
          ],
        },
      ),
    );
    expect(s2, 202);
    final (ps, _) = await c.send('PUT', '/_fake/script', body: {});
    expect(ps, 200);
    final (gs, _) = await c.send('GET', '/v1/runs/$run');
    expect(gs, 404);
  });
}
