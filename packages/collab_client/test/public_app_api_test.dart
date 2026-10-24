import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('published API uses its own passport, public run paths and existing SSE decoder', () async {
    final requests = <http.Request>[];
    final api = HttpPublicAppApi(
      Uri.parse('https://fixture.invalid'),
      code: 'published-code',
      client: MockClient((r) async {
        requests.add(r);
        expect(r.headers['X-App-Code'], 'published-code');
        if (r.url.path == '/v1/passport') {
          expect(r.headers['Authorization'], isNull);
          return http.Response('{"access_token":"visitor-passport"}', 200);
        }
        expect(r.headers['Authorization'], 'Bearer visitor-passport');
        if (r.url.path == '/v1/workflows/run') {
          expect(jsonDecode(r.body), {
            'inputs': {'q': 'hello'},
            'response_mode': 'streaming',
          });
          return http.Response(
            'data: {"event":"workflow_started","workflow_run_id":"run"}\n\ndata: {"event":"workflow_finished","data":{"status":"succeeded"}}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        if (r.url.path == '/v1/site') return http.Response('{"name":"Public","mode":"workflow"}', 200);
        return http.Response('{}', 200);
      }),
    );
    addTearDown(api.close);
    expect(await api.establishPassport(), 'visitor-passport');
    expect((await api.definition())['name'], 'Public');
    expect(
      (await api.runPublished({
        'inputs': {'q': 'hello'},
      }).toList()).last['event'],
      'workflow_finished',
    );
    await api.submitHumanInputForm('form', {'inputs': {}, 'action': 'approve'});
    await api.stopPublished('run');
    expect(requests.any((r) => r.url.path.startsWith('/v1/apps/')), isFalse);
    expect(requests.last.url.path, '/v1/workflows/tasks/run/stop');
  });

  test('expired visitor passport can renew, while a reset app code remains unavailable', () async {
    var passports = 0;
    final api = HttpPublicAppApi(
      Uri.parse('https://fixture.invalid'),
      code: 'old-code',
      passport: 'expired-visitor',
      client: MockClient((r) async {
        passports++;
        if (passports == 1) {
          expect(r.headers['Authorization'], 'Bearer expired-visitor');
          return http.Response('{"error":{"code":"unauthorized","message":"Expired"}}', 401);
        }
        expect(r.headers['Authorization'], isNull);
        return http.Response('{"error":{"code":"not_found","message":"App unavailable"}}', 404);
      }),
    );
    addTearDown(api.close);
    await expectLater(
      api.establishPassport(),
      throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 404)),
    );
    expect(passports, 2);
  });
  test('message pages retain chronology across an older-history cursor', () async {
    var calls = 0;
    final api = HttpPublicAppApi(
      Uri.parse('https://fixture.invalid'),
      code: 'code',
      passport: 'visitor',
      client: MockClient((r) async {
        expect(r.url.queryParameters['limit'], '100');
        calls++;
        if (calls == 1) return http.Response('{"data":[{"id":"second"},{"id":"third"}],"has_more":true}', 200);
        expect(r.url.queryParameters['first_id'], 'second');
        return http.Response('{"data":[{"id":"first"}],"has_more":false}', 200);
      }),
    );
    addTearDown(api.close);
    expect((await api.publicMessages('conversation')).map((m) => m['id']), ['third', 'second', 'first']);
    expect(calls, 2);
  });
}
