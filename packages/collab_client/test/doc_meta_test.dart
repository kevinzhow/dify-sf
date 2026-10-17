import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('DocsApi.meta reads the app mode, name and variables', () async {
    Uri? asked;
    final api = DocsApi(
      Uri.parse('http://server.test/base/'),
      client: MockClient((req) async {
        asked = req.url;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'app': {'name': 'Chat ✓', 'mode': 'advanced-chat', 'icon': '🤖'},
              'kind': 'app',
              'dependencies': <Object?>[],
              'environment_variables': [
                {'id': 'e1', 'name': 'api_key', 'value': '', 'value_type': 'secret'},
              ],
              'conversation_variables': [
                {'id': 'c1', 'name': 'str', 'value': 'default', 'value_type': 'string'},
              ],
              'features': {'opening_statement': 'hi'},
            }),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final m = await api.meta('d1');
    expect(asked!.path, '/base/v1/docs/d1/meta');
    expect(m.appMode, 'advanced-chat');
    expect(m.isChatflow, isTrue);
    expect(m.appName, 'Chat ✓');
    expect(m.environmentVariables.single['value_type'], 'secret');
    expect(m.conversationVariables.single['name'], 'str');
    expect((m.raw['features']! as Map)['opening_statement'], 'hi');
  });

  test('missing parts read as the defaults; errors are TransportExceptions', () async {
    expect(DocMeta.fromJson(const {}).appMode, 'workflow');
    expect(DocMeta.fromJson(const {'app': 'x', 'environment_variables': 'y'}).environmentVariables, isEmpty);
    expect(const DocMeta().isChatflow, isFalse);
    final api = DocsApi(
      Uri.parse('http://server.test'),
      client: MockClient(
        (_) async => http.Response('{"error":{"code":"not_found","message":"unknown document"}}', 404),
      ),
    );
    await expectLater(
      api.meta('nope'),
      throwsA(
        isA<TransportException>().having((e) => e.statusCode, 'status', 404).having((e) => e.code, 'code', 'not_found'),
      ),
    );
  });
}
