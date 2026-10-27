import 'package:collab_client/collab_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

class _Tokens implements TokenProvider {
  @override
  String? get accessToken => 'fixture-only';
  @override
  Future<bool> refresh({String? failedToken}) async => false;
}

void main() {
  test('profile call caps remain bounded and old catalogs default to fifty', () {
    Map<String, Object?> catalog(Object? limit, {bool omit = false}) => {'shell_enabled': true, 'profiles': [{
      'name': 'default', 'description': 'Default', 'status': 'ok', 'timeout_seconds_max': 1800,
      if (!omit) 'max_turns_max': limit,
    }]};
    expect(AgentExecutorContext.parse(catalog(null, omit: true)).named('default')!.maxTurnsMax, 50);
    expect(AgentExecutorContext.parse(catalog(200)).named('default')!.maxTurnsMax, 200);
    for (final limit in [0, -1, 1001, 1.5, '200', true, null]) {
      expect(() => AgentExecutorContext.parse(catalog(limit)), throwsFormatException);
    }
  });
  final entry = <String, Object?>{
    'name': 'default',
    'description': 'Default shell',
    'status': 'ok',
    'timeout_seconds_max': 1800,
  };
  test(
    'catalog retains unknown state and rejects malformed or duplicated entries',
    () {
      expect(
        AgentExecutorContext.parse({'shell_enabled': true, 'profiles': null})
            .unknown,
        true,
      );
      expect(
        AgentExecutorContext.parse({'shell_enabled': false, 'profiles': null})
            .unknown,
        false,
      );
      final parsed = AgentExecutorContext.parse({
        'shell_enabled': true,
        'profiles': [entry],
      });
      expect(parsed.named('default')?.timeoutSecondsMax, 1800);
      expect(parsed.named('imported-environment'), isNull);
      for (final entries in [
        [],
        [entry, entry],
        [
          {...entry, 'name': 'BAD'},
        ],
        [
          {...entry, 'status': 'new-status'},
        ],
        [
          {...entry, 'timeout_seconds_max': 1.5},
        ],
        [
          {...entry, 'timeout_seconds_max': 0},
        ],
        [
          {...entry, 'name': 'rendering'},
        ],
      ]) {
        expect(
          () => AgentExecutorContext.parse({
            'shell_enabled': true,
            'profiles': entries,
          }),
          throwsFormatException,
        );
      }
    },
  );
  test('catalog is read through the authenticated app endpoint', () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.headers['authorization'], 'Bearer fixture-only');
      expect(request.url.path, '/v1/apps/app-id/agent-executor-profiles');
      return http.Response(
        '{"shell_enabled":true,"profiles":null}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = HttpAgentComposerApi(
      Uri.parse('https://fixture.invalid'),
      auth: _Tokens(),
      client: client,
    );
    final context = await AgentExecutorContext.load(api, 'app-id');
    expect(context.unknown, true);
    api.close();
  });
}
