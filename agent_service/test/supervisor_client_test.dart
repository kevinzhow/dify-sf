import 'dart:async';
import 'dart:convert';

import 'package:agent_service/agent_service.dart';
import 'package:genkit/genkit.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  const busy = {'error': 'disk_pool_busy', 'message': 'all slots occupied'};
  final url = Uri.parse('http://supervisor.test');

  test('a following execution waits for the earlier disk release', () async {
    var occupied = true;
    final requests = <Map>[];
    final s = SupervisorClient(
      url,
      'fixture',
      diskSlotRetryInterval: const Duration(milliseconds: 10),
      client: MockClient((r) async {
        requests.add(jsonDecode(r.body) as Map);
        if (occupied) return http.Response(jsonEncode(busy), 503);
        return http.Response(
          jsonEncode({
            'sandbox_id': 'next',
            'url': 'http://sandbox.test',
            'token': 'fixture',
            'profile': 'modelling',
            'created': true,
          }),
          201,
        );
      }),
    );
    addTearDown(s.close);
    final grant = s.acquire('next-execution', profile: 'modelling');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(requests.length, greaterThan(1));
    occupied = false;
    expect((await grant).sandboxId, 'next');
    expect(
      requests.every(
        (r) =>
            r['execution_key'] == 'next-execution' &&
            r['profile'] == 'modelling',
      ),
      isTrue,
    );
  });

  for (final (status, code) in [
    (503, 'disk_budget_exceeded'),
    (503, 'disk_space_low'),
    (503, 'disk_workspace_conflict'),
    (503, 'disk_workspace_failed'),
    (503, 'image_missing'),
    (503, 'docker_error'),
    (409, 'disk_pool_busy'),
    (401, 'unauthorized'),
  ]) {
    test('$status $code fails immediately without retry', () async {
      var count = 0;
      final s = SupervisorClient(
        url,
        'fixture',
        client: MockClient((r) async {
          count++;
          return http.Response(jsonEncode({'error': code}), status);
        }),
      );
      addTearDown(s.close);
      await expectLater(
        s.acquire('next'),
        throwsA(
          isA<SandboxFailure>().having((e) => e.supervisorCode, 'code', code),
        ),
      );
      expect(count, 1);
    });
  }

  test('a permanently occupied slot has a bounded wait', () async {
    var count = 0;
    final s = SupervisorClient(
      url,
      'fixture',
      diskSlotWaitTimeout: const Duration(milliseconds: 80),
      diskSlotRetryInterval: const Duration(milliseconds: 10),
      client: MockClient((r) async {
        count++;
        return http.Response(jsonEncode(busy), 503);
      }),
    );
    addTearDown(s.close);
    final clock = Stopwatch()..start();
    await expectLater(
      s.acquire('next'),
      throwsA(
        isA<SandboxFailure>()
            .having((e) => e.supervisorCode, 'code', 'disk_pool_busy')
            .having(
              (e) => e.message,
              'message',
              allOf(contains('within 80 ms'), contains('all slots occupied')),
            ),
      ),
    );
    expect(clock.elapsedMilliseconds, inInclusiveRange(70, 1500));
    final endedCount = count;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(count, endedCount);
  });

  test(
    'cancel wakes the wait and never acquires a subsequently freed slot',
    () async {
      var count = 0;
      final firstRequest = Completer<void>();
      final cancel = CancellationController();
      final s = SupervisorClient(
        url,
        'fixture',
        diskSlotRetryInterval: const Duration(seconds: 30),
        client: MockClient((r) async {
          count++;
          firstRequest.complete();
          return http.Response(jsonEncode(busy), 503);
        }),
      );
      addTearDown(s.close);
      final pending = s.acquire('next', cancel: cancel.token);
      final ended = expectLater(pending, throwsA(isA<CancelledException>()));
      await firstRequest.future;
      final clock = Stopwatch()..start();
      cancel.cancel('cancel');
      await ended.timeout(const Duration(seconds: 1));
      expect(clock.elapsedMilliseconds, lessThan(1000));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(count, 1);
    },
  );

  test('already cancelled means no supervisor request', () async {
    var count = 0;
    final cancel = CancellationController()..cancel('timeout');
    final s = SupervisorClient(
      url,
      'fixture',
      client: MockClient((r) async {
        count++;
        return http.Response(jsonEncode(busy), 503);
      }),
    );
    addTearDown(s.close);
    await expectLater(
      s.acquire('next', cancel: cancel.token),
      throwsA(isA<CancelledException>()),
    );
    expect(count, 0);
  });

  group('retained workspaces', () {
    Map<String, Object?> answer({Object? workspace}) => {
      'sandbox_id': 'sbx1',
      'url': 'http://sandbox.test',
      'token': 'fixture',
      'profile': 'default',
      'created': true,
      'workspace': ?workspace,
    };

    test('workspace_key is sent and the workspace answer read', () async {
      final requests = <Map>[];
      final s = SupervisorClient(
        url,
        'fixture',
        client: MockClient((r) async {
          requests.add(jsonDecode(r.body) as Map);
          return http.Response(
            jsonEncode(
              answer(
                workspace: {'retained': true, 'reused': true, 'id': 'ws-1'},
              ),
            ),
            201,
          );
        }),
      );
      addTearDown(s.close);
      final key = canonicalJson(['T1', 'A1', 'W1', 'N1']);
      final grant = await s.acquire('E2', workspaceKey: key);
      expect(requests.single, {
        'execution_key': 'E2',
        'profile': 'default',
        'workspace_key': '["T1","A1","W1","N1"]',
      });
      expect(grant.retained?.id, 'ws-1');
      expect(grant.retained?.reused, isTrue);
    });

    test('without workspace_key nothing is sent and the string "disk" is no '
        'retained workspace', () async {
      final requests = <Map>[];
      final s = SupervisorClient(
        url,
        'fixture',
        client: MockClient((r) async {
          requests.add(jsonDecode(r.body) as Map);
          return http.Response(jsonEncode(answer(workspace: 'disk')), 201);
        }),
      );
      addTearDown(s.close);
      final grant = await s.acquire('E1');
      expect(requests.single.containsKey('workspace_key'), isFalse);
      expect(grant.retained, isNull);
    });

    test('malformed workspace answers are no retained workspace', () {
      for (final w in [
        {'retained': false, 'reused': true, 'id': 'ws'},
        {'retained': true, 'reused': 'yes', 'id': 'ws'},
        {'retained': true, 'reused': false, 'id': ''},
        {'retained': true, 'reused': false},
        'disk',
        null,
      ]) {
        expect(RetainedWorkspaceGrant.parse(w), isNull, reason: '$w');
      }
    });

    test('409 workspace_in_use is sandbox_unavailable naming the code, '
        'without retry', () async {
      var count = 0;
      final s = SupervisorClient(
        url,
        'fixture',
        client: MockClient((r) async {
          count++;
          return http.Response(
            jsonEncode({
              'error': 'workspace_in_use',
              'message': 'mounted by sbx1',
            }),
            409,
          );
        }),
      );
      addTearDown(s.close);
      await expectLater(
        s.acquire('E2', workspaceKey: '["T1","A1","W1","N1"]'),
        throwsA(
          isA<SandboxFailure>()
              .having((e) => e.errorType, 'type', 'sandbox_unavailable')
              .having((e) => e.supervisorCode, 'code', 'workspace_in_use')
              .having(
                (e) => e.message,
                'message',
                allOf(contains('409 workspace_in_use'), contains('in use')),
              ),
        ),
      );
      expect(count, 1);
    });

    group('409 workspace_in_use while the holder is released', () {
      const inUse = {
        'error': 'workspace_in_use',
        'message': 'workspace already has a sandbox',
      };
      final granted = {
        'sandbox_id': 'sbx2',
        'url': 'http://sandbox.test',
        'token': 'fixture',
        'profile': 'default',
        'created': true,
        'workspace': {'retained': true, 'reused': true, 'id': 'ws'},
      };

      SupervisorClient client(
        bool Function() free, {
        Duration timeout = const Duration(seconds: 5),
        void Function()? onRequest,
      }) => SupervisorClient(
        url,
        'fixture',
        diskSlotWaitTimeout: timeout,
        diskSlotRetryInterval: const Duration(milliseconds: 10),
        client: MockClient((r) async {
          onRequest?.call();
          return free()
              ? http.Response(jsonEncode(granted), 201)
              : http.Response(jsonEncode(inUse), 409);
        }),
      );

      test('retried while retryable, until the sandbox is granted', () async {
        var count = 0;
        var asked = 0;
        final s = client(() => count > 3, onRequest: () => count++);
        addTearDown(s.close);
        final grant = await s.acquire(
          'E2',
          workspaceKey: 'k',
          workspaceInUseRetryable: () {
            asked++;
            return true;
          },
        );
        expect(grant.sandboxId, 'sbx2');
        expect(count, 4);
        expect(asked, 3);
      });

      test('not retryable (holder running or unknown): one request', () async {
        var count = 0;
        final s = client(() => false, onRequest: () => count++);
        addTearDown(s.close);
        await expectLater(
          s.acquire(
            'E2',
            workspaceKey: 'k',
            workspaceInUseRetryable: () => false,
          ),
          throwsA(
            isA<SandboxFailure>().having(
              (e) => e.message,
              'message',
              contains('in use by another sandbox'),
            ),
          ),
        );
        expect(count, 1);
        // Without the callback (another caller) the same.
        await expectLater(
          s.acquire('E2', workspaceKey: 'k'),
          throwsA(isA<SandboxFailure>()),
        );
        expect(count, 2);
      });

      test('the holder starts to count as active: the wait stops', () async {
        var count = 0;
        final s = client(() => false, onRequest: () => count++);
        addTearDown(s.close);
        await expectLater(
          s.acquire(
            'E2',
            workspaceKey: 'k',
            workspaceInUseRetryable: () => count < 3,
          ),
          throwsA(isA<SandboxFailure>()),
        );
        expect(count, 3);
      });

      test('a bounded wait naming workspace_in_use', () async {
        final s = client(
          () => false,
          timeout: const Duration(milliseconds: 80),
        );
        addTearDown(s.close);
        await expectLater(
          s.acquire(
            'E2',
            workspaceKey: 'k',
            workspaceInUseRetryable: () => true,
          ),
          throwsA(
            isA<SandboxFailure>()
                .having((e) => e.errorType, 'type', 'sandbox_unavailable')
                .having((e) => e.supervisorCode, 'code', 'workspace_in_use')
                .having(
                  (e) => e.message,
                  'message',
                  allOf(
                    contains('after 80 ms'),
                    contains('409 workspace_in_use'),
                  ),
                ),
          ),
        );
      });

      test('cancel ends the wait', () async {
        final cancel = CancellationController();
        final s = client(() => false);
        addTearDown(s.close);
        final acquired = s.acquire(
          'E2',
          workspaceKey: 'k',
          workspaceInUseRetryable: () => true,
          cancel: cancel.token,
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));
        cancel.cancel('test');
        await expectLater(acquired, throwsA(isA<CancelledException>()));
      });
    });

    test('409 workspace_conflict names the code', () async {
      final s = SupervisorClient(
        url,
        'fixture',
        client: MockClient(
          (r) async => http.Response(
            jsonEncode({
              'error': 'workspace_conflict',
              'message': 'execution workspace scope changed',
            }),
            409,
          ),
        ),
      );
      addTearDown(s.close);
      await expectLater(
        s.acquire('E2', workspaceKey: '["T1","A1","W1","N1"]'),
        throwsA(
          isA<SandboxFailure>().having(
            (e) => e.message,
            'message',
            contains('409 workspace_conflict'),
          ),
        ),
      );
    });

    test('DELETE /v1/workspaces/{id}: 404 is already gone, 409 and other '
        'failures throw', () async {
      final seen = <String>[];
      var status = 200;
      final s = SupervisorClient(
        url,
        'fixture',
        client: MockClient((r) async {
          seen.add('${r.method} ${r.url.path}');
          return http.Response(
            jsonEncode(
              status == 200
                  ? {'id': 'a/b', 'deleted': true}
                  : {'error': 'workspace_in_use', 'message': 'busy'},
            ),
            status,
          );
        }),
      );
      addTearDown(s.close);
      await s.deleteWorkspace('a/b');
      status = 404;
      await s.deleteWorkspace('a/b');
      status = 409;
      await expectLater(
        s.deleteWorkspace('a/b'),
        throwsA(isA<SandboxFailure>().having((e) => e.httpStatus, 's', 409)),
      );
      status = 503;
      await expectLater(
        s.deleteWorkspace('a/b'),
        throwsA(isA<SandboxFailure>()),
      );
      expect(seen.first, 'DELETE /v1/workspaces/a%2Fb');
    });
  });
}
