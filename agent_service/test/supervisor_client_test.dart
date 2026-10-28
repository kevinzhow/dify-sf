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
            .having((e) => e.message, 'message', contains('within 80 ms')),
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
}
