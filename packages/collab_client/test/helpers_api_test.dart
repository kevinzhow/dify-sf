import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('generation and voices/audio use the authenticated server boundary and preserve provider bytes', () async {
    final calls = <String>[];
    final api = HelpersApi(
      Uri.parse('https://fixture.invalid/prefix'),
      client: MockClient((r) async {
        calls.add(r.url.path);
        if (r.url.path.endsWith('/rule-code-generate')) {
          expect(jsonDecode(r.body), {
            'instruction': 'code',
            'model_config': {'provider': 'p', 'name': 'm'},
          });
          return http.Response('{"code":"function main() {}","error":""}', 200);
        }
        if (r.url.path.endsWith('/voices')) return http.Response('[{"name":"Voice","value":"alloy"}]', 200);
        expect(jsonDecode(r.body), {'text': 'Hello', 'voice': 'alloy'});
        return http.Response.bytes([82, 73, 70, 70], 200, headers: {'content-type': 'audio/wav'});
      }),
    );
    addTearDown(api.close);
    expect(
      (await api.generate('rule-code-generate', {
        'instruction': 'code',
        'model_config': {'provider': 'p', 'name': 'm'},
      }))['code'],
      contains('main'),
    );
    expect((await api.voices('app', 'en-US')).single.value, 'alloy');
    final audio = await api.audio('app', text: 'Hello', voice: 'alloy');
    expect(audio.bytes, [82, 73, 70, 70]);
    expect(audio.mimeType, 'audio/wav');
    expect(calls, everyElement(startsWith('/prefix/v1/')));
  });
  test('a failed generation envelope and non-audio response remain failures', () async {
    final api = HelpersApi(
      Uri.parse('https://fixture.invalid'),
      client: MockClient((r) async => http.Response('{"error":"Model refused","output":""}', 200)),
    );
    addTearDown(api.close);
    await expectLater(
      api.generate('rule-structured-output-generate', {'instruction': 'schema'}),
      throwsA(isA<TransportException>()),
    );
    await expectLater(api.audio('a', text: 'Hello'), throwsA(isA<TransportException>()));
  });
  test('URL import sends the URL to the server without browser downloading', () async {
    final api = HttpAppsApi(
      Uri.parse('https://fixture.invalid'),
      client: MockClient((r) async {
        expect(r.url.path, '/v1/apps/imports');
        expect(jsonDecode(r.body), {'mode': 'yaml-url', 'yaml_url': 'https://origin.invalid/app.yml'});
        return http.Response(
          '{"id":"job","status":"pending","current_dsl_version":"0.7.0","imported_dsl_version":"0.8.0"}',
          202,
        );
      }),
    );
    addTearDown(api.close);
    expect((await api.importDslUrl('https://origin.invalid/app.yml')).status, AppImportStatus.pending);
  });
}
