import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

class _Tokens implements TokenProvider {
  @override
  String? accessToken = 'expired';
  @override
  Future<bool> refresh({String? failedToken}) async {
    expect(failedToken, 'expired');
    accessToken = 'refreshed';
    return true;
  }
}

void main() {
  test('an auth refresh replays the exact CAS revision and idempotency key', () async {
    final sent = <http.Request>[];
    final api = HttpAgentComposerApi(
      Uri.parse('https://server.test/base'),
      auth: _Tokens(),
      client: MockClient((request) async {
        sent.add(request);
        if (sent.length == 1) return http.Response('{"error":{"code":"unauthorized","message":"expired"}}', 401);
        return http.Response(
          '{"document_seq":8,"agent_soul":{"env":{"secret_refs":[{"name":"KEY","value":"********"}]}},"binding":{"agent_id":"owned","current_snapshot_id":"snapshot"}}',
          200,
        );
      }),
    );
    addTearDown(api.close);
    final body = <String, Object?>{
      'variant': 'workflow',
      'expected_seq': 5,
      'idempotency_key': '481725aa-c99a-46ba-bb75-0b4eeb167ae1',
      'save_strategy': 'save_to_current_version',
      'node_job': {'workflow_prompt': 'Task'},
    };
    final result = await api.saveInlineAgent('app', 'node', body);
    expect(sent, hasLength(2));
    expect(sent.map((r) => r.headers['authorization']), ['Bearer expired', 'Bearer refreshed']);
    expect(sent.first.bodyBytes, sent.last.bodyBytes);
    expect(jsonDecode(sent.last.body), body);
    expect(sent.last.url.path, '/base/v1/apps/app/workflows/draft/nodes/node/agent-composer');
    expect(result['document_seq'], 8);
  });

  test('a collaboration conflict is surfaced without automatically rebasing the save', () async {
    var calls = 0;
    final api = HttpAgentComposerApi(
      Uri.parse('https://server.test'),
      client: MockClient((request) async {
        calls++;
        return http.Response('{"error":{"code":"agent_document_changed","message":"Reload before saving"}}', 409);
      }),
    );
    addTearDown(api.close);
    await expectLater(
      api.saveInlineAgent('app', 'node', {'expected_seq': 3}),
      throwsA(
        isA<TransportException>()
            .having((e) => e.statusCode, 'status', 409)
            .having((e) => e.code, 'code', 'agent_document_changed'),
      ),
    );
    expect(calls, 1);
  });

  test('historical reads carry the exact agent and snapshot identity', () async {
    final api = HttpAgentComposerApi(
      Uri.parse('https://server.test'),
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.queryParameters, {'snapshot_id': 'frozen-snapshot', 'agent_id': 'frozen-agent'});
        return http.Response('{"agent_soul":{"model":null},"document_seq":12}', 200);
      }),
    );
    addTearDown(api.close);
    final result = await api.readInlineAgent('app', 'node', agentId: 'frozen-agent', snapshotId: 'frozen-snapshot');
    expect(result['document_seq'], 12);
  });

  test('clipboard authentication retries preserve the exact atomic paste identity', () async {
    final sent = <http.Request>[];
    final api = HttpAgentComposerApi(
      Uri.parse('https://server.test/base'),
      auth: _Tokens(),
      client: MockClient((request) async {
        sent.add(request);
        if (sent.length == 1) {
          return http.Response('{"error":{"code":"unauthorized","message":"expired"}}', 401);
        }
        return http.Response('{"document_seq":11,"node_ids":["copy"]}', 200);
      }),
    );
    addTearDown(api.close);
    final body = <String, Object?>{
      'expected_seq': 8,
      'idempotency_key': '481725aa-c99a-46ba-bb75-0b4eeb167ae1',
      'nodes': [
        {
          'id': 'copy',
          'data': {'type': 'agent', 'version': '2'},
        },
      ],
      'edges': <Object?>[],
      'agent_packages': <String, Object?>{},
      'id_mapping': {'source': 'copy'},
      'local_sources': {
        'copy': {'node_id': 'source', 'agent_id': 'owned', 'snapshot_id': 'pinned'},
      },
    };
    final result = await api.pasteAgentClipboard('app', body);
    expect(sent, hasLength(2));
    expect(sent.every((request) => request.method == 'POST'), isTrue);
    expect(sent.last.url.path, '/base/v1/apps/app/workflows/draft/agent-clipboard/paste');
    expect(sent.map((request) => request.headers['authorization']), ['Bearer expired', 'Bearer refreshed']);
    expect(sent.first.bodyBytes, sent.last.bodyBytes);
    expect(jsonDecode(sent.last.body), body);
    expect(result['document_seq'], 11);
  });

  test('clipboard export conflicts are returned before any portable content is accepted', () async {
    var calls = 0;
    final api = HttpAgentComposerApi(
      Uri.parse('https://server.test'),
      client: MockClient((request) async {
        calls++;
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/apps/app/workflows/draft/agent-clipboard/export');
        expect(jsonDecode(request.body), {
          'expected_seq': 3,
          'node_ids': ['source'],
        });
        return http.Response('{"error":{"code":"agent_document_changed","message":"Reload before copying"}}', 409);
      }),
    );
    addTearDown(api.close);
    await expectLater(
      api.exportAgentClipboard('app', {
        'expected_seq': 3,
        'node_ids': ['source'],
      }),
      throwsA(isA<TransportException>().having((error) => error.statusCode, 'status', 409)),
    );
    expect(calls, 1);
  });
}
