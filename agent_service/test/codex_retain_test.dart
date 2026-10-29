// Codex session retained across rounds (docs/agent-v2.md): the request
// field, the retained workspace's record in the store, and rounds of the
// official runtime against the scripted app-server and the fake
// supervisor's retained workspaces (retain_rig.dart). The real binary is
// covered by codex_retain_binary_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/src/harness/codex/official.dart';
import 'package:agent_service/src/harness/codex/retained_session.dart';
import 'package:agent_service/testing.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'codex_app_server_fake.dart';
import 'retain_rig.dart';
import 'support.dart';

void main() {
  group('codex_session in the request', () {
    Map<String, Object?> op({
      Object? session = const {'retain': true},
      bool codex = true,
      bool shell = true,
    }) {
      final o = officialCodexOp();
      return {
        ...o,
        if (!codex) 'harness_style': 'dify',
        'tools': {'shell': shell},
        'codex_session': session,
      };
    }

    test('accepted with the codex style, the official runtime and the '
        'shell; the workspace key is the canonical JSON identity', () {
      final r = OperationRequest.parse(op(), officialCodex: true);
      expect(r.retainsSession, isTrue);
      expect(r.workspaceKey, '["T1","A1","W1","N1"]');
      final none = OperationRequest.parse(
        op(session: null),
        officialCodex: true,
      );
      expect(none.retainsSession, isFalse);
      expect(none.workspaceKey, isNull);
    });

    test('the key cannot collide through a separator in the values', () {
      ExecutionRef e(String app, String run) => ExecutionRef({
        'tenant_id': 'T',
        'app_id': app,
        'workflow_run_id': run,
        'node_id': 'N',
        'execution_id': 'E',
        'agent_config_snapshot_id': 'c',
      });
      expect(
        retainedWorkspaceKey(e('a/b', 'c')),
        isNot(retainedWorkspaceKey(e('a', 'b/c'))),
      );
      expect(retainedWorkspaceKey(e('a"', 'b')), '["T","a\\"","b","N"]');
    });

    test('refused without the codex style, the official runtime or the '
        'shell', () {
      for (final (body, official, message) in [
        (op(codex: false), true, 'needs harness_style "codex"'),
        (op(), false, 'needs the official Codex runtime'),
        (op(shell: false), true, 'needs tools.shell'),
      ]) {
        expect(
          () => OperationRequest.parse(body, officialCodex: official),
          throwsA(
            isA<ApiError>()
                .having((e) => e.status, 'status', 400)
                .having((e) => e.code, 'code', 'invalid_request')
                .having((e) => e.message, 'message', contains(message)),
          ),
        );
      }
    });

    test('malformed values', () {
      for (final bad in [
        true,
        'retain',
        <String, Object?>{},
        {'retain': false},
        {'retain': 'yes'},
        {'retain': true, 'resume': null},
      ]) {
        expect(
          () => OperationRequest.parse(op(session: bad), officialCodex: true),
          throwsA(isA<ApiError>().having((e) => e.status, 'status', 400)),
          reason: jsonEncode(bad),
        );
      }
    });

    test('part of the request digest', () {
      final a = OperationRequest.parse(op(), officialCodex: true);
      final b = OperationRequest.parse(op(session: null), officialCodex: true);
      expect(a.digest, isNot(b.digest));
    });

    test('needs an executor profile with a disk workspace', () async {
      final rig = await RetainRig.start(backing: 'tmpfs');
      final (status, body) = await rig.h.post('/v1/operations', retainOp());
      expect(status, 400, reason: jsonEncode(body));
      expect(body['error'], 'invalid_request');
      expect(body['message'], contains('disk workspace'));
      final (ok, _) = await rig.h.post(
        '/v1/operations',
        retainOp(session: null),
      );
      expect(ok, 202);
    });
  });

  group('the retained workspace record', () {
    late Directory dir;
    setUp(() => dir = newDataDir());
    tearDown(() => dir.deleteSync(recursive: true));

    ExecutionRef exec(String node, {String run = 'W1'}) => ExecutionRef({
      'tenant_id': 'T1',
      'app_id': 'A1',
      'workflow_run_id': run,
      'node_id': node,
      'execution_id': 'E-$node',
      'agent_config_snapshot_id': 'c',
    });

    CodexSessionRecord session(int turns) => CodexSessionRecord(
      threadId: thread,
      sha256: '0' * 64,
      size: 10,
      turns: turns,
      model: 'm',
      systemPromptSha256: '1' * 64,
      codexSha256: officialCodexSha256,
      rolloutPath: rolloutRel,
      runId: 'run_1',
      recordedAt: DateTime.utc(2026, 10, 29),
    );

    test('written at acquire, the session apart; both survive a restart; '
        'listed by workflow run; removed', () {
      final store = RunStore(dir.path)..load();
      final k1 = retainedWorkspaceKey(exec('N1'));
      final k2 = retainedWorkspaceKey(exec('N2'));
      final k3 = retainedWorkspaceKey(exec('N1', run: 'W2'));
      store
        ..prepareRetainedWorkspace(k1, exec('N1'))
        ..prepareRetainedWorkspace(k2, exec('N2'))
        ..prepareRetainedWorkspace(k3, exec('N1', run: 'W2'));
      expect(store.setCodexSession(k1, session(1)), isTrue);
      // A later round keeps the session and, until its grant, the holder.
      store.prepareRetainedWorkspace(k1, exec('N1', run: 'W1'));
      expect(store.retainedWorkspace(k1)!.session, isNotNull);
      expect(store.setCodexSession('unknown', session(1)), isFalse);

      final again = RunStore(dir.path)..load();
      final w1 = again.retainedWorkspace(k1)!;
      // The supervisor's hashKey("retained:" + key).
      expect(
        w1.workspaceId,
        sha256.convert(utf8.encode('retained:$k1')).toString(),
      );
      expect(w1.nodeId, 'N1');
      expect(w1.executionId, 'E-N1');
      expect(w1.sessionState, SessionState.saved);
      expect(w1.session!.toJson(), session(1).toJson());
      expect(again.retainedWorkspace(k2)!.sessionState, SessionState.none);
      expect(again.retainedWorkspace(k2)!.session, isNull);
      expect(
        [
          for (final w in again.retainedWorkspacesOf(
            tenantId: 'T1',
            appId: 'A1',
            workflowRunId: 'W1',
          ))
            w.nodeId,
        ]..sort(),
        ['N1', 'N2'],
      );
      expect(again.setSessionSaveFailed(k1, 'too large'), isTrue);
      expect(again.setSessionSaveFailed('unknown', 'x'), isFalse);
      again.removeRetainedWorkspace(k2);
      final third = RunStore(dir.path)..load();
      final w1b = third.retainedWorkspace(k1)!;
      expect(w1b.sessionState, SessionState.saveFailed);
      expect(w1b.saveError, 'too large');
      expect(w1b.session, isNull);
      expect(third.retainedWorkspace(k2), isNull);
      expect(third.retainedWorkspace(k3)!.workflowRunId, 'W2');
    });

    test('the holder decides whether workspace_in_use is waited for: an '
        'ended or deleted earlier execution yes; a running, unknown or the '
        'same one no', () {
      final store = RunStore(dir.path)..load();
      final key = retainedWorkspaceKey(exec('N1'));
      store.prepareRetainedWorkspace(key, exec('N1'));
      expect(store.retainedWorkspaceHolderEnded(key, 'E2'), isFalse);
      final op = OperationRequest.parse(operation(executionId: 'E-N1'));
      final run = store.createRun(op, op.digest);
      expect(store.retainedWorkspaceHolderEnded(key, 'E2'), isFalse);
      store.finish(run, 'succeeded', {'candidate': null});
      expect(store.retainedWorkspaceHolderEnded(key, 'E2'), isTrue);
      expect(store.retainedWorkspaceHolderEnded(key, 'E-N1'), isFalse);
      store.deleteExecution('E-N1');
      expect(store.retainedWorkspaceHolderEnded(key, 'E2'), isTrue);
      expect(store.retainedWorkspaceHolderEnded('other', 'E2'), isFalse);
    });
  });

  group('rounds', () {
    test('round 1 starts a thread and keeps the session; round 2 resumes '
        'it in the re-used workspace: thread/resume with the model and '
        'effort, never thread/start', () async {
      final rig = await RetainRig.start();
      // ---- round 1
      final fake1 = FakeCodexAppServer(turn: codexTurn(rig));
      final run1 = await rig.round(fake1, retainOp(effort: 'low'));
      final r1 = await rig.result(run1);
      expect(r1['candidate'], {'text': 'Done.'}, reason: jsonEncode(r1));
      expect(rig.sup.workspaceKeys, [workspaceKey]);
      expect(fake1.paramsOf('thread/start')['ephemeral'], isFalse);
      expect(r1['session'], {'saved': true, 'thread_id': thread, 'turns': 1});
      expect(fake1.methods, isNot(contains('thread/resume')));
      final started1 = await runStarted(rig.h, run1);
      expect((started1['runtime'] as Map)['session'], {
        'resumed': false,
        'thread_id': thread,
        'turns_before': 0,
      });
      final copy = rig.rolloutCopy.readAsBytesSync();
      expect(utf8.decode(copy), contains('"answer":"Done."'));
      final w = rig.record!;
      expect(w.workspaceId, FakeSupervisor.workspaceIdOf(workspaceKey));
      expect(
        [w.tenantId, w.appId, w.workflowRunId, w.nodeId],
        ['T1', 'A1', 'W1', 'N1'],
      );
      final s1 = w.session!;
      expect(s1.threadId, thread);
      expect(s1.sha256, sha256.convert(copy).toString());
      expect(s1.size, copy.length);
      expect(s1.turns, 1);
      expect(s1.model, 'test-model');
      expect(
        s1.systemPromptSha256,
        sha256.convert(utf8.encode('You are a helpful agent.')).toString(),
      );
      expect(s1.codexSha256, officialCodexSha256);
      expect(s1.rolloutPath, rolloutRel);
      expect(s1.runId, run1);
      // The run's CODEX_HOME is gone, removed before the result.
      expect(
        Directory('${rig.box!.home.path}/.codex-runs').listSync(),
        isEmpty,
      );
      expect(rig.homeRemovedBeforeResult, [true]);
      await rig.deleteExecution('E1');

      // ---- round 2: a new execution of the node
      String? restored;
      final fake2 = FakeCodexAppServer(
        turn: codexTurn(
          rig,
          answer: 'Round 2 done.',
          before: (box, home) =>
              restored = File('$home/$rolloutRel').readAsStringSync(),
        ),
      );
      final run2 = await rig.round(
        fake2,
        retainOp(executionId: 'E2', effort: 'high'),
      );
      final r2 = await rig.result(run2);
      expect(r2['candidate'], {
        'text': 'Round 2 done.',
      }, reason: jsonEncode(r2));
      // Codex's replay of round 1's usage at the resume is no model call of
      // this round.
      expect((r2['usage'] as Map)['total_tokens'], 110);
      expect(r2['session'], {'saved': true, 'thread_id': thread, 'turns': 2});
      expect(fake2.methods, contains('thread/resume'));
      expect(fake2.methods, isNot(contains('thread/start')));
      expect(fake2.paramsOf('thread/resume'), {
        'threadId': thread,
        'cwd': '/workspace',
        'approvalPolicy': 'never',
        'sandbox': 'danger-full-access',
        'model': 'test-model',
        'excludeTurns': true,
        'config': {'model_reasoning_effort': 'high'},
      });
      // The rollout was in the new CODEX_HOME before Codex started.
      expect(restored, utf8.decode(copy));
      final started2 = await runStarted(rig.h, run2);
      final runtime2 = started2['runtime'] as Map;
      expect(runtime2['session'], {
        'resumed': true,
        'thread_id': thread,
        'turns_before': 1,
      });
      expect(runtime2['reasoning_effort'], 'high');
      final s2 = rig.record!.session!;
      final copy2 = rig.rolloutCopy.readAsStringSync();
      expect(copy2, contains('"answer":"Done."'));
      expect(copy2, contains('"answer":"Round 2 done."'));
      expect(s2.turns, 2);
      expect(s2.sha256, sha256.convert(utf8.encode(copy2)).toString());
      expect(s2.runId, run2);
      expect(rig.homeRemovedBeforeResult, [true, true]);
    });

    test('without a reasoning effort the resume sends no config', () async {
      final rig = await RetainRig.start();
      final run1 = await rig.round(
        FakeCodexAppServer(turn: codexTurn(rig)),
        retainOp(),
      );
      expect((await rig.result(run1))['candidate'], isNotNull);
      await rig.deleteExecution('E1');
      final fake2 = FakeCodexAppServer(turn: codexTurn(rig));
      final run2 = await rig.round(fake2, retainOp(executionId: 'E2'));
      expect((await rig.result(run2))['candidate'], isNotNull);
      expect(fake2.paramsOf('thread/resume').containsKey('config'), isFalse);
    });

    test('the record survives a restart of the agent service', () async {
      final rig = await RetainRig.start();
      final run1 = await rig.round(
        FakeCodexAppServer(turn: codexTurn(rig)),
        retainOp(),
      );
      expect((await rig.result(run1))['candidate'], isNotNull);
      await rig.deleteExecution('E1');
      await rig.h.restart();
      final fake2 = FakeCodexAppServer(turn: codexTurn(rig, answer: 'Again.'));
      final run2 = await rig.round(fake2, retainOp(executionId: 'E2'));
      final r2 = await rig.result(run2);
      expect(r2['candidate'], {'text': 'Again.'}, reason: jsonEncode(r2));
      expect(fake2.methods, contains('thread/resume'));
      expect(rig.record!.session!.turns, 2);
    });

    test('round 2 gets its files[] in the re-used workspace (the new '
        'inputs win; the rest of the workspace stays)', () async {
      final rig = await RetainRig.start();
      rig.h.gateway.files['F1'] = {'content': 'spec v1'};
      final run1 = await rig.round(
        FakeCodexAppServer(
          turn: codexTurn(
            rig,
            before: (box, _) {
              File('${box.ws.path}/out/result.txt')
                ..createSync(recursive: true)
                ..writeAsStringSync('round 1');
            },
          ),
        ),
        {
          ...retainOp(),
          'files': [
            {'file_id': 'F1', 'path': 'in/spec.md'},
          ],
        },
      );
      expect((await rig.result(run1))['candidate'], isNotNull);
      expect(
        File('${rig.nodeWorkspace.path}/in/spec.md').readAsStringSync(),
        'spec v1',
      );
      await rig.deleteExecution('E1');
      rig.h.gateway.files['F1'] = {'content': 'spec v2'};
      String? seen;
      final fake2 = FakeCodexAppServer(
        turn: codexTurn(
          rig,
          before: (box, _) =>
              seen = File('${box.ws.path}/in/spec.md').readAsStringSync(),
        ),
      );
      final run2 = await rig.round(fake2, {
        ...retainOp(executionId: 'E2'),
        'files': [
          {'file_id': 'F1', 'path': 'in/spec.md'},
        ],
      });
      expect((await rig.result(run2))['candidate'], isNotNull);
      expect(seen, 'spec v2');
      expect(
        File('${rig.nodeWorkspace.path}/out/result.txt').readAsStringSync(),
        'round 1',
      );
      expect(fake2.methods, contains('thread/resume'));
    });

    test('an output retry of the same execution resumes the thread in its '
        'running sandbox', () async {
      final rig = await RetainRig.start();
      final run1 = await rig.round(
        FakeCodexAppServer(turn: codexTurn(rig)),
        retainOp(),
      );
      final r1 = await rig.result(run1);
      final fake2 = FakeCodexAppServer(turn: codexTurn(rig, answer: 'Fixed.'));
      final run2 = await rig.round(
        fake2,
        retainOp(
          outputAttempt: 1,
          continuation: {
            'kind': 'output_retry',
            'snapshot': r1['snapshot'],
            'feedback': [
              {'field': 'text', 'error': 'too short'},
            ],
          },
        ),
      );
      final r2 = await rig.result(run2);
      expect(r2['candidate'], {'text': 'Fixed.'}, reason: jsonEncode(r2));
      // The supervisor answered reused: false for its running sandbox
      // (created: false): the workspace is the one round 1 used.
      expect(rig.sup.created, hasLength(1));
      expect(fake2.methods, contains('thread/resume'));
      expect(rig.record!.session!.turns, 2);
    });

    test('a failed first round: the next round starts a new thread in the '
        'kept workspace (no earlier round succeeded)', () async {
      final rig = await RetainRig.start();
      final fake1 = FakeCodexAppServer(
        turn: (s) async {
          File('${rig.box!.ws.path}/notes.txt').writeAsStringSync('r1');
          s.fail('other', 'the provider failed');
        },
      );
      final run1 = await rig.round(fake1, retainOp());
      final r1 = await rig.result(run1);
      expect(r1['error_type'], 'model_error');
      expect(r1.containsKey('session'), isFalse);
      // Indexed at acquire, no session.
      expect(rig.record, isNotNull);
      expect(rig.record!.sessionState, SessionState.none);
      expect(
        Directory('${rig.box!.home.path}/.codex-runs').listSync(),
        isEmpty,
      );
      await rig.deleteExecution('E1');
      String? kept;
      final fake2 = FakeCodexAppServer(
        turn: codexTurn(
          rig,
          before: (box, _) =>
              kept = File('${box.ws.path}/notes.txt').readAsStringSync(),
        ),
      );
      final run2 = await rig.round(fake2, retainOp(executionId: 'E2'));
      final r2 = await rig.result(run2);
      expect(r2['candidate'], {'text': 'Done.'}, reason: jsonEncode(r2));
      expect(fake2.methods, contains('thread/start'));
      expect(fake2.methods, isNot(contains('thread/resume')));
      expect(kept, 'r1');
      final runtime = (await runStarted(rig.h, run2))['runtime'] as Map;
      expect(runtime['session'], {
        'resumed': false,
        'thread_id': thread,
        'turns_before': 0,
        'reason': 'no earlier round succeeded',
      });
      expect(r2['session'], {'saved': true, 'thread_id': thread, 'turns': 1});
      expect(rig.record!.sessionState, SessionState.saved);
    });

    test('a failed later round keeps the saved session: the next round '
        'resumes the last good one', () async {
      final rig = await RetainRig.start();
      final run1 = await rig.round(
        FakeCodexAppServer(turn: codexTurn(rig)),
        retainOp(),
      );
      await rig.result(run1);
      final saved = rig.record!.session!.toJson();
      await rig.deleteExecution('E1');
      final fake2 = FakeCodexAppServer(
        turn: (s) async => s.fail('other', 'the provider failed'),
      );
      final run2 = await rig.round(fake2, retainOp(executionId: 'E2'));
      expect((await rig.result(run2))['error_type'], 'model_error');
      expect(fake2.methods, contains('thread/resume'));
      expect(rig.record!.sessionState, SessionState.saved);
      expect(rig.record!.session!.toJson(), saved);
      await rig.deleteExecution('E2');
      final fake3 = FakeCodexAppServer(turn: codexTurn(rig));
      final run3 = await rig.round(fake3, retainOp(executionId: 'E3'));
      final r3 = await rig.result(run3);
      expect(r3['session'], {'saved': true, 'thread_id': thread, 'turns': 2});
      final runtime = (await runStarted(rig.h, run3))['runtime'] as Map;
      expect((runtime['session'] as Map)['turns_before'], 1);
    });

    group('409 workspace_in_use', () {
      int acquiresOf(RetainRig rig, String execution) =>
          rig.sup.acquires.where((k) => k == execution).length;

      test('held by the previous round, whose run ended: the next round '
          'waits until its sandbox is deleted, then resumes', () async {
        final rig = await RetainRig.start(
          supervisorWait: const Duration(seconds: 20),
        );
        final run1 = await rig.round(
          FakeCodexAppServer(turn: codexTurn(rig)),
          retainOp(),
        );
        await rig.result(run1);
        // The Swift server's queue has not deleted E1's sandbox yet.
        final fake2 = FakeCodexAppServer(turn: codexTurn(rig, answer: 'R2.'));
        final run2 = await rig.round(fake2, retainOp(executionId: 'E2'));
        while (acquiresOf(rig, 'E2') < 3) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect((await rig.h.get('/v1/runs/$run2')).$2['status'], 'running');
        await rig.deleteExecution('E1');
        final r2 = await rig.result(run2);
        expect(r2['candidate'], {'text': 'R2.'}, reason: jsonEncode(r2));
        expect(fake2.methods, contains('thread/resume'));
        expect(rig.record!.executionId, 'E2');
      });

      test('held by a run that is still running: immediate failure', () async {
        final rig = await RetainRig.start(
          supervisorWait: const Duration(seconds: 20),
        );
        final gate = Completer<void>();
        final turn = codexTurn(rig);
        final run1 = await rig.round(
          FakeCodexAppServer(
            turn: (s) async {
              await gate.future;
              await turn(s);
            },
          ),
          retainOp(),
        );
        while (rig.box == null) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final clock = Stopwatch()..start();
        final fake2 = FakeCodexAppServer(turn: codexTurn(rig));
        final run2 = await rig.round(fake2, retainOp(executionId: 'E2'));
        final r2 = await rig.result(run2);
        expect(r2['error_type'], 'sandbox_unavailable');
        expect(r2['message'], contains('409 workspace_in_use'));
        expect(r2['message'], contains('in use by another sandbox'));
        expect(acquiresOf(rig, 'E2'), 1);
        expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
        expect(fake2.methods, isEmpty);
        gate.complete();
        expect((await rig.result(run1))['candidate'], isNotNull);
      });

      test('held by an execution agent_service does not know: immediate '
          'failure', () async {
        final rig = await RetainRig.start(
          supervisorWait: const Duration(seconds: 20),
        );
        final run1 = await rig.round(
          FakeCodexAppServer(turn: codexTurn(rig)),
          retainOp(),
        );
        await rig.result(run1);
        // A record of an execution with no runs here (e.g. another agent
        // service instance).
        rig.h.service.store.retainedWorkspaceGranted(
          workspaceKey,
          'E-elsewhere',
        );
        final run2 = await rig.round(
          FakeCodexAppServer(turn: codexTurn(rig)),
          retainOp(executionId: 'E2'),
        );
        final r2 = await rig.result(run2);
        expect(r2['error_type'], 'sandbox_unavailable');
        expect(acquiresOf(rig, 'E2'), 1);
      });

      test('the previous round\'s sandbox is never deleted: a clear failure '
          'after the wait, naming workspace_in_use', () async {
        final rig = await RetainRig.start(
          supervisorWait: const Duration(milliseconds: 600),
        );
        final run1 = await rig.round(
          FakeCodexAppServer(turn: codexTurn(rig)),
          retainOp(),
        );
        await rig.result(run1);
        final fake2 = FakeCodexAppServer(turn: codexTurn(rig));
        final run2 = await rig.round(fake2, retainOp(executionId: 'E2'));
        final r2 = await rig.result(run2);
        expect(r2['error_type'], 'sandbox_unavailable');
        expect(
          r2['message'],
          allOf(
            contains('still in use by the previous round'),
            contains('after 600 ms'),
            contains('409 workspace_in_use'),
          ),
        );
        expect(acquiresOf(rig, 'E2'), greaterThan(2));
        expect(fake2.methods, isEmpty);
      });
    });

    test('a rollout over 128 MiB is not saved: the round succeeds and says '
        'so; the next round fails instead of resuming an older turn', () async {
      final rig = await RetainRig.start();
      final run1 = await rig.round(
        FakeCodexAppServer(turn: codexTurn(rig)),
        retainOp(),
      );
      await rig.result(run1);
      expect(rig.record!.session, isNotNull);
      await rig.deleteExecution('E1');
      final run2 = await rig.round(
        FakeCodexAppServer(
          turn: codexTurn(rig, sparseSize: codexSessionMaxBytes + 1),
        ),
        retainOp(executionId: 'E2'),
      );
      final r2 = await rig.result(run2);
      expect(r2['candidate'], {'text': 'Done.'}, reason: jsonEncode(r2));
      final saved = r2['session'] as Map;
      expect(saved['saved'], isFalse);
      expect((saved['error'] as Map)['code'], 'save_failed');
      expect(
        (saved['error'] as Map)['message'],
        contains('more than $codexSessionMaxBytes'),
      );
      expect(rig.record!.sessionState, SessionState.saveFailed);
      expect(rig.record!.session, isNull);
      expect(rig.rolloutCopy.lengthSync(), lessThan(1024));
      await rig.deleteExecution('E2');
      final fake3 = FakeCodexAppServer(turn: codexTurn(rig));
      final run3 = await rig.round(fake3, retainOp(executionId: 'E3'));
      final r3 = await rig.result(run3);
      expect(r3['error_type'], 'session_restore_failed');
      expect(
        r3['message'],
        contains("(record): the previous round's session was not saved: "),
      );
      expect(r3['message'], contains('more than'));
      expect(fake3.methods, isEmpty);
    });
  });

  group('a session that cannot be resumed fails the run '
      'session_restore_failed, never a new thread', () {
    /// Round 1 (recorded), then round 2 with [change] applied first.
    Future<(Map<String, Object?>, FakeCodexAppServer)> failing({
      void Function(RetainRig rig)? change,
      Map<String, Object?>? op,
      List<String> tools = const ['report_progress'],
      Map<String, Object?>? resumeError,
      String? threadResumeId,
      String? threadModel,
      String? threadEffort,
    }) async {
      final rig = await RetainRig.start();
      final run1 = await rig.round(
        FakeCodexAppServer(turn: codexTurn(rig, tools: tools)),
        retainOp(effort: 'low'),
      );
      expect((await rig.result(run1))['candidate'], isNotNull);
      await rig.deleteExecution('E1');
      change?.call(rig);
      final fake = FakeCodexAppServer(
        threadResumeError: resumeError,
        threadResumeId: threadResumeId,
        threadModel: threadModel,
        threadEffort: threadEffort,
        turn: codexTurn(rig),
      );
      final run2 = await rig.round(
        fake,
        op ?? retainOp(executionId: 'E2', effort: 'low'),
      );
      final r = await rig.result(run2);
      expect(r['error_type'], 'session_restore_failed', reason: jsonEncode(r));
      expect(fake.methods, isNot(contains('thread/start')));
      expect(fake.methods, isNot(contains('turn/start')));
      // The session stays recorded for a later attempt.
      expect(rig.record?.session, isNotNull);
      return (r, fake);
    }

    test('a record without a re-used workspace', () async {
      final (r, fake) = await failing(
        change: (rig) => rig.sup.workspaces.clear(),
      );
      expect(r['message'], contains('(workspace)'));
      expect(r['message'], contains('reused: false'));
      expect(fake.methods, isEmpty);
    });

    test('the rollout copy is missing', () async {
      final (r, _) = await failing(
        change: (rig) => rig.rolloutCopy.deleteSync(),
      );
      expect(r['message'], contains('(rollout)'));
      expect(r['message'], contains('is missing'));
    });

    test('the rollout copy changed', () async {
      final (r, _) = await failing(
        change: (rig) => rig.rolloutCopy.writeAsStringSync(
          '{"type":"turn","answer":"forged"}\n',
          mode: FileMode.append,
        ),
      );
      expect(r['message'], contains('(rollout)'));
      expect(r['message'], contains('changed since the session was kept'));
    });

    test('another Codex binary wrote the session', () async {
      final (r, _) = await failing(
        change: (rig) {
          final s = rig.record!.session!;
          rig.h.service.store.setCodexSession(
            workspaceKey,
            CodexSessionRecord(
              threadId: s.threadId,
              sha256: s.sha256,
              size: s.size,
              turns: s.turns,
              model: s.model,
              systemPromptSha256: s.systemPromptSha256,
              codexSha256: 'f' * 64,
              rolloutPath: s.rolloutPath,
              runId: s.runId,
              recordedAt: s.recordedAt,
            ),
          );
        },
      );
      expect(r['message'], contains('(record)'));
      expect(r['message'], contains('Codex binary'));
    });

    test('another model', () async {
      final (r, _) = await failing(
        op: retainOp(executionId: 'E2', model: 'other-model'),
      );
      expect(r['message'], contains('(record)'));
      expect(r['message'], contains('"other-model"'));
    });

    test('another system prompt', () async {
      final (r, _) = await failing(
        op: retainOp(executionId: 'E2', systemPrompt: 'Be terse.'),
      );
      expect(r['message'], contains('system prompt changed'));
    });

    test('Codex refuses thread/resume', () async {
      final (r, _) = await failing(
        resumeError: {'code': -32600, 'message': 'no rollout found for thread'},
      );
      expect(
        r['message'],
        contains('(thread/resume): Codex refused thread/resume: no rollout'),
      );
    });

    test('Codex resumes another thread', () async {
      final (r, _) = await failing(threadResumeId: 'thr_other');
      expect(r['message'], contains('"thr_other", not $thread'));
    });

    test('Codex resumes with another model or effort', () async {
      final (r, _) = await failing(threadEffort: 'medium');
      expect(r['message'], contains('(thread/resume)'));
      expect(r['message'], contains('resumed the thread with reasoning'));
      final (m, _) = await failing(threadModel: 'gpt-x');
      expect(m['message'], contains('resumed the thread with model "gpt-x"'));
    });

    test('report_progress missing after resume', () async {
      final (r, _) = await failing(tools: const []);
      expect(r['message'], contains('report_progress is missing'));
    });

    test('without tools.report_progress the same session resumes', () async {
      final rig = await RetainRig.start();
      final run1 = await rig.round(
        FakeCodexAppServer(turn: codexTurn(rig, tools: const [])),
        retainOp(reportProgress: false),
      );
      expect((await rig.result(run1))['candidate'], isNotNull);
      await rig.deleteExecution('E1');
      final run2 = await rig.round(
        FakeCodexAppServer(turn: codexTurn(rig)),
        retainOp(executionId: 'E2', reportProgress: false),
      );
      expect((await rig.result(run2))['candidate'], {'text': 'Done.'});
    });
  });
}
