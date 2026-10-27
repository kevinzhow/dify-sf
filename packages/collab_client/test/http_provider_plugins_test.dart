import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test(
    'management calls preserve plugin identity, task state and installation id',
    () async {
      final calls = <http.Request>[];
      final api = HttpModelProvidersApi(
        Uri.parse('https://example.com/base'),
        client: MockClient((r) async {
          calls.add(r);
          if (r.url.path.endsWith('/model-provider-plugins')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {'plugin_id': 'langgenius/openai', 'status': 'unknown'},
                ],
              }),
              200,
            );
          }
          if (r.url.path.endsWith('/install')) {
            return http.Response('{"task_id":"task-1"}', 200);
          }
          if (r.url.path.contains('/tasks/')) {
            return http.Response('{"status":"success","error":null}', 200);
          }
          return http.Response('{"result":"success"}', 200);
        }),
      );
      addTearDown(api.close);
      expect((await api.providerPlugins()).single['status'], 'unknown');
      expect(
        (await api.installProviderPlugin('langgenius/openai'))['task_id'],
        'task-1',
      );
      expect((await api.providerPluginTask('task-1'))['status'], 'success');
      await api.uninstallProviderPlugin(
        'langgenius/openai',
        installationId: 'installation-7',
      );
      expect(calls.map((r) => '${r.method} ${r.url.path}'), [
        'GET /base/v1/workspace/model-provider-plugins',
        'POST /base/v1/workspace/model-provider-plugins/langgenius/openai/install',
        'GET /base/v1/workspace/model-provider-plugins/tasks/task-1',
        'POST /base/v1/workspace/model-provider-plugins/langgenius/openai/uninstall',
      ]);
      expect(jsonDecode(calls.last.body), {
        'installation_id': 'installation-7',
      });
      expect(calls.last.body, isNot(contains('credentials')));
    },
  );

  test(
    'a rejected management operation remains an actionable transport error',
    () async {
      final api = HttpModelProvidersApi(
        Uri.parse('https://example.com'),
        client: MockClient(
          (_) async => http.Response(
            '{"error":{"code":"forbidden","message":"Only an owner or admin can manage plugins"}}',
            403,
          ),
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.installProviderPlugin('langgenius/openai'),
        throwsA(
          isA<TransportException>().having((e) => e.code, 'code', 'forbidden'),
        ),
      );
    },
  );

  test(
    'a malformed list is not interpreted as an empty installation catalog',
    () async {
      final api = HttpModelProvidersApi(
        Uri.parse('https://example.com'),
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      addTearDown(api.close);
      await expectLater(
        api.providerPlugins(),
        throwsA(isA<TransportException>()),
      );
    },
  );
}
