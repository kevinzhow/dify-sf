import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const provider = 'langgenius/openai_api_compatible/openai_api_compatible';
const connection = {'endpoint_url': 'https://gateway.example/v1', 'api_key': 'fixture-only'};

void main() {
  test('discovery, explicit consent probe and save are distinct authenticated-console operations', () async {
    final requests = <http.Request>[];
    final api = HttpModelProvidersApi(
      Uri.parse('https://console.example'),
      client: MockClient((request) async {
        requests.add(request);
        expect(request.method, 'POST');
        expect(request.url.query, isEmpty);
        expect(request.headers['content-type'], 'application/json');
        if (request.url.path.endsWith('/discover')) {
          return http.Response(jsonEncode({'discovery_id': 'receipt', 'models': []}), 200);
        }
        if (request.url.path.endsWith('/probe')) {
          return http.Response(jsonEncode({'probe_id': 'probe', 'fields': {}}), 200);
        }
        return http.Response('{"result":"success"}', 201);
      }),
    );
    addTearDown(api.close);
    final discovery = await api.discoverModels(provider, credentials: connection);
    expect(discovery['discovery_id'], 'receipt');
    expect(requests.length, 1);
    expect(requests.single.url.path, '/v1/workspace/model-providers/$provider/models/discover');
    expect(jsonDecode(requests.single.body), {'credentials': connection});
    await api.probeModel(provider, credentials: connection, model: 'not/listed', apiType: 'responses', consent: true);
    expect(jsonDecode(requests[1].body), {
      'credentials': connection,
      'model': 'not/listed',
      'api_type': 'responses',
      'consent': true,
    });
    await api.createAutofilledModel(
      provider,
      model: 'not/listed',
      credentials: {...connection, 'context_size': '4096'},
      discoveryId: 'receipt',
      probeId: 'probe',
    );
    final saved = jsonDecode(requests.last.body) as Map;
    expect(saved['discovery_id'], 'receipt');
    expect(saved['probe_id'], 'probe');
    expect(saved['model'], 'not/listed');
    expect(requests.length, 3);
  });
  test('discovery failure remains actionable and never falls back to paid model requests', () async {
    var count = 0;
    final api = HttpModelProvidersApi(
      Uri.parse('https://console.example'),
      client: MockClient((request) async {
        count++;
        expect(request.url.path.endsWith('/models/discover'), isTrue);
        return http.Response(
          '{"error":{"code":"model_discovery_auth_failed","message":"Check the address and API Key."}}',
          502,
        );
      }),
    );
    addTearDown(api.close);
    await expectLater(
      api.discoverModels(provider, credentials: connection),
      throwsA(isA<TransportException>().having((error) => error.code, 'code', 'model_discovery_auth_failed')),
    );
    expect(count, 1);
  });
}
