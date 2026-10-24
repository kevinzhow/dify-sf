import 'dart:convert';
import 'package:collab_client/collab_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('installed declarations, per-node credential and dynamic options use console routes', () async {
    final calls = <http.Request>[];
    final api = ToolsApi(Uri.parse('https://trial.invalid'), client: MockClient((req) async {
      calls.add(req);
      if (req.url.path.endsWith('/tool-providers')) {
        return http.Response(jsonEncode([{'id': 'fixture/tools/echo', 'tools': [{'name': 'echo'}]}]), 200);
      }
      if (req.url.path.endsWith('/dynamic-options')) {
        expect(jsonDecode(req.body), {'tool': 'echo', 'parameter': 'mode', 'credential_id': 'selected'});
        return http.Response('[{"value":"real","label":{"en_US":"Real"}}]', 200);
      }
      if (req.url.path.endsWith('/credentials')) return http.Response('[{"id":"selected","name":"Private"}]', 200);
      expect(req.method, 'POST');
      expect(jsonDecode(req.body), {'name': 'Private', 'credentials': {'api_key': 'write-only'}, 'is_team_authorization': false});
      return http.Response('{"result":"success","id":"selected"}', 200);
    }));
    expect((await api.providers()).single['id'], 'fixture/tools/echo');
    await api.saveCredential('fixture/tools/echo', name: 'Private', credentials: {'api_key': 'write-only'});
    expect((await api.credentials('fixture/tools/echo')).single.containsKey('credentials'), false);
    expect((await api.dynamicOptions('fixture/tools/echo', 'echo', 'mode', credentialId: 'selected')).single['value'], 'real');
    expect(calls.every((r) => r.url.scheme == 'https' && r.url.host == 'trial.invalid'), true);
    api.close();
  });
  test('a denied credential stays an error so the form can retry', () async {
    var attempt = 0;
    final api = ToolsApi(Uri.parse('https://trial.invalid'), client: MockClient((req) async {
      if (++attempt == 1) return http.Response('{"error":{"code":"credential_validation_failed","message":"Rejected"}}', 400);
      return http.Response('{"id":"new"}', 200);
    }));
    await expectLater(api.saveCredential('fixture/tools/echo', name: 'Private', credentials: {'api_key':'a'}),
      throwsA(isA<TransportException>().having((e) => e.code, 'code', 'credential_validation_failed')));
    await api.saveCredential('fixture/tools/echo', name: 'Private', credentials: {'api_key':'b'});
    expect(attempt, 2);
    api.close();
  });
}
