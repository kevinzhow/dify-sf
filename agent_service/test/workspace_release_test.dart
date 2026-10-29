// POST /v1/workspaces/release (docs/agent-v2.md, "Codex session retained
// across rounds"): the retained workspaces of an ended workflow run are
// deleted through the supervisor and forgotten (retain_rig.dart).
import 'dart:convert';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/testing.dart';
import 'package:test/test.dart';

import 'codex_app_server_fake.dart';
import 'retain_rig.dart';

Future<(int, Map<String, Object?>)> release(
  RetainRig rig, {
  String run = 'W1',
  Map<String, Object?> extra = const {},
}) => rig.h.post('/v1/workspaces/release', {
  'protocol': protocolName,
  'tenant_id': 'T1',
  'app_id': 'A1',
  'workflow_run_id': run,
  ...extra,
});

void main() {
  group('POST /v1/workspaces/release', () {
    test('deletes every retained workspace of the workflow run, also one '
        'without a session, and forgets them; idempotent', () async {
      final rig = await RetainRig.start();
      // N1 succeeds (session), N2 fails (no session); W2 is another run.
      final run1 = await rig.round(
        FakeCodexAppServer(turn: codexTurn(rig)),
        retainOp(),
      );
      await rig.result(run1);
      await rig.deleteExecution('E1');
      final run2 = await rig.round(
        FakeCodexAppServer(turn: (s) async => s.fail('other', 'failed')),
        retainOp(executionId: 'E2', nodeId: 'N2'),
      );
      expect((await rig.result(run2))['error_type'], 'model_error');
      await rig.deleteExecution('E2');
      final other = retainOp(executionId: 'E3');
      (other['execution'] as Map)['workflow_run_id'] = 'W2';
      final run3 = await rig.round(
        FakeCodexAppServer(turn: codexTurn(rig)),
        other,
      );
      await rig.result(run3);
      await rig.deleteExecution('E3');
      expect(rig.sup.workspaces, hasLength(3));

      final (status, body) = await release(rig);
      expect(status, 200, reason: jsonEncode(body));
      expect(body, {
        'protocol': protocolName,
        'tenant_id': 'T1',
        'app_id': 'A1',
        'workflow_run_id': 'W1',
        'released': 2,
      });
      final w1 = FakeSupervisor.workspaceIdOf(workspaceKey);
      final w2 = FakeSupervisor.workspaceIdOf(
        canonicalJson(['T1', 'A1', 'W1', 'N2']),
      );
      expect(rig.sup.workspaceDeletes.toSet(), {w1, w2});
      expect(rig.sup.workspaces.keys, [
        FakeSupervisor.workspaceIdOf(canonicalJson(['T1', 'A1', 'W2', 'N1'])),
      ]);
      expect(rig.record, isNull);
      expect(
        rig.h.service.store.retainedWorkspacesOf(
          tenantId: 'T1',
          appId: 'A1',
          workflowRunId: 'W2',
        ),
        hasLength(1),
      );
      // Also after a restart: nothing left to release.
      await rig.h.restart();
      final (again, body2) = await release(rig);
      expect(again, 200);
      expect(body2['released'], 0);
      expect(rig.sup.workspaceDeletes, hasLength(2));
    });

    test('a workspace still in use (409) or a failed delete answers 503 '
        'cleanup_failed and stays recorded; a retry deletes it', () async {
      final rig = await RetainRig.start();
      final run1 = await rig.round(
        FakeCodexAppServer(turn: codexTurn(rig)),
        retainOp(),
      );
      await rig.result(run1);
      // E1's sandbox still mounts the workspace.
      final (busy, body) = await release(rig);
      expect(busy, 503, reason: jsonEncode(body));
      expect(body['error'], 'cleanup_failed');
      expect(body['message'], contains('workspace_in_use'));
      expect(body['failed'], 1);
      expect(rig.record?.session, isNotNull);
      await rig.deleteExecution('E1');
      rig.sup.failWorkspaceDelete = 500;
      final (failed, _) = await release(rig);
      expect(failed, 503);
      expect(rig.record, isNotNull);
      rig.sup.failWorkspaceDelete = null;
      final (ok, done) = await release(rig);
      expect(ok, 200);
      expect(done['released'], 1);
      expect(rig.record, isNull);
      expect(rig.sup.workspaces, isEmpty);
    });

    test(
      'a workspace the supervisor no longer knows (deleted: false) is released',
      () async {
        final rig = await RetainRig.start();
        final run1 = await rig.round(
          FakeCodexAppServer(turn: codexTurn(rig)),
          retainOp(),
        );
        await rig.result(run1);
        await rig.deleteExecution('E1');
        rig.sup.workspaces.clear();
        final (status, body) = await release(rig);
        expect(status, 200);
        expect(body['released'], 1);
        expect(rig.record, isNull);
      },
    );

    test('malformed requests', () async {
      final rig = await RetainRig.start();
      for (final (body, status) in [
        ({'protocol': protocolName, 'tenant_id': 'T1', 'app_id': 'A1'}, 400),
        (
          {
            'protocol': protocolName,
            'tenant_id': 'T1',
            'app_id': 'A1',
            'workflow_run_id': 'W1',
            'node_id': 'N1',
          },
          400,
        ),
        (
          {
            'protocol': 'other/1',
            'tenant_id': 'T1',
            'app_id': 'A1',
            'workflow_run_id': 'W1',
          },
          400,
        ),
      ]) {
        final (s, b) = await rig.h.post('/v1/workspaces/release', body);
        expect(s, status, reason: jsonEncode(b));
      }
      final (unauthorized, _) = await rig.h.post('/v1/workspaces/release', {
        'protocol': protocolName,
        'tenant_id': 'T1',
        'app_id': 'A1',
        'workflow_run_id': 'W1',
      }, key: 'wrong');
      expect(unauthorized, 401);
      final (method, _) = await rig.h.get('/v1/workspaces/release');
      expect(method, 405);
    });
  });

  group('the index is written before the acquire', () {
    test('the supervisor creates the disk and then fails: the workspace is '
        'indexed and the release deletes it', () async {
      final rig = await RetainRig.start();
      rig.sup.failAfterWorkspace = 503;
      final fake = FakeCodexAppServer(turn: codexTurn(rig));
      final run = await rig.round(fake, retainOp());
      final r = await rig.result(run);
      expect(r['error_type'], 'sandbox_unavailable', reason: jsonEncode(r));
      expect(fake.methods, isEmpty);
      final predicted = FakeSupervisor.workspaceIdOf(workspaceKey);
      expect(rig.sup.workspaces.keys, [predicted]);
      expect(rig.record!.workspaceId, predicted);
      expect(rig.record!.executionId, 'E1');
      final (status, body) = await release(rig);
      expect(status, 200, reason: jsonEncode(body));
      expect(body['released'], 1);
      expect(rig.sup.workspaceDeletes, [predicted]);
      expect(rig.sup.workspaces, isEmpty);
      expect(rig.record, isNull);
    });

    test('the first acquire fails before anything is created: the release '
        'still succeeds (the supervisor knows no such workspace)', () async {
      final rig = await RetainRig.start();
      rig.sup.failAcquire = 503;
      final run = await rig.round(
        FakeCodexAppServer(turn: codexTurn(rig)),
        retainOp(),
      );
      expect((await rig.result(run))['error_type'], 'sandbox_unavailable');
      expect(rig.sup.workspaces, isEmpty);
      expect(rig.record, isNotNull);
      final (status, body) = await release(rig);
      expect(status, 200, reason: jsonEncode(body));
      expect(body['released'], 1);
      expect(rig.record, isNull);
    });

    test('a grant naming another workspace ID is refused: sandbox_error '
        'naming both, the sandbox released (parked), the unknown ID never '
        'indexed or deleted', () async {
      final rig = await RetainRig.start();
      final other = FakeSupervisor.workspaceIdOf('["T9","A9","W9","N9"]');
      rig.sup.reportWorkspaceId = other;
      final fake = FakeCodexAppServer(turn: codexTurn(rig));
      final run = await rig.round(fake, retainOp());
      final r = await rig.result(run);
      final predicted = FakeSupervisor.workspaceIdOf(workspaceKey);
      expect(r['error_type'], 'sandbox_error');
      expect(r['message'], allOf(contains(other), contains(predicted)));
      expect(fake.methods, isEmpty);
      expect(rig.sup.deletes, hasLength(1));
      expect(rig.sup.sandboxes, isEmpty);
      expect(rig.record!.workspaceId, predicted);
      rig.sup.reportWorkspaceId = null;
      final (status, _) = await release(rig);
      expect(status, 200);
      expect(rig.sup.workspaceDeletes, [predicted]);
    });
  });
}
