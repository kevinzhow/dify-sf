// The rig of the retained-session tests (codex_retain_test.dart,
// workspace_release_test.dart): one agent service with the fake supervisor's
// retained workspaces; each round is an operation with its own scripted
// app-server (codex_app_server_fake.dart). Each fake sandbox is a pair of
// local directories (its home, and the retained workspace shared by the
// node's rounds), so the runtime's sandbox scripts (find, cp, stat,
// sha256sum, head, base64) really run.
import 'dart:convert';
import 'dart:io';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/src/harness/codex/official.dart';
import 'package:agent_service/testing.dart';
import 'package:test/test.dart';

import 'codex_app_server_fake.dart';
import 'support.dart';

const thread = 'thr_root';
const rolloutRel =
    'sessions/2026/10/29/rollout-2026-10-29T00-00-00-$thread.jsonl';
final workspaceKey = canonicalJson(['T1', 'A1', 'W1', 'N1']);

/// The first line of a rollout: `session_meta` with [tools].
String sessionMetaLine(List<String> tools) =>
    '${jsonEncode({
      'type': 'session_meta',
      'payload': {
        'id': thread,
        'dynamic_tools': [
          for (final t in tools) {'name': t, 'description': 'd'},
        ],
      },
    })}\n';

/// The local directories of one fake sandbox.
class LocalBox {
  LocalBox(this.home, this.ws);
  final Directory home;
  final Directory ws;

  String rewrite(String script) => script
      .replaceAll('/home/dify/agent', home.path)
      .replaceAll("'/workspace", "'${ws.path}");

  /// Local path of a sandbox path.
  String local(String sandboxPath) => sandboxPath
      .replaceFirst('/home/dify/agent', home.path)
      .replaceFirst('/workspace', ws.path);

  /// Whether [script] is one this box runs (the session scripts, the run's
  /// CODEX_HOME setup and removal, file writes).
  static bool handles(String script) =>
      !script.contains('write_outside_workspace=') &&
      !script.contains('reap=ok') &&
      !script.contains('--version') &&
      !script.contains('debug models --bundled') &&
      !script.contains('app-server --listen') &&
      (script.contains("'/workspace") || script.contains('/home/dify/agent'));

  (int, String) runSync(String script) {
    final r = Process.runSync('bash', [
      '-c',
      rewrite(script),
    ], workingDirectory: ws.path);
    return (r.exitCode, '${r.stdout}');
  }

  Future<(int, String)> run(String script) async {
    final r = await Process.run('bash', [
      '-c',
      rewrite(script),
    ], workingDirectory: ws.path);
    return (r.exitCode, '${r.stdout}${r.stderr}');
  }
}

/// One agent service with the fake supervisor; rounds are operations with
/// a new scripted app-server each.
class RetainRig {
  RetainRig._(this.root);

  final Directory root;
  late final FakeSupervisor sup;
  late final Harness h;
  FakeCodexAppServer? current;

  /// The box of the latest app-server job.
  LocalBox? box;
  final Map<FakeShellctl, LocalBox> boxes = {};
  final List<FakeCodexAppServer> _fakes = [];

  /// Whether each CODEX_HOME removal came before its run's terminal result.
  final List<bool> homeRemovedBeforeResult = [];

  Directory workspaceDir(String id) =>
      Directory('${root.path}/ws-${id.substring(0, 12)}')
        ..createSync(recursive: true);

  /// The node's retained workspace directory.
  Directory get nodeWorkspace =>
      workspaceDir(FakeSupervisor.workspaceIdOf(workspaceKey));

  File get rolloutCopy =>
      File('${nodeWorkspace.path}/.dify-sf/codex/$thread.jsonl');

  RetainedWorkspace? get record =>
      h.service.store.retainedWorkspace(workspaceKey);

  static Future<RetainRig> start({
    String backing = 'disk',
    Duration supervisorWait = const Duration(seconds: 2),
  }) async {
    final rig = RetainRig._(Directory(newDataDir().resolveSymbolicLinksSync()));
    final profiles = ExecutorProfiles.parse({
      'version': 1,
      'profiles': {
        'default': {
          'image':
              'dify-sf/sandbox@sha256:'
              '1111111111111111111111111111111111111111111111111111111111111111',
          'mounts': [
            {'source': '/srv/codex', 'target': '/opt/codex'},
          ],
          'workspace': {'backing': backing},
        },
      },
    });
    rig.sup = FakeSupervisor(key: testSupervisorKey, configure: rig._configure)
      ..profiles = {
        for (final p in profiles.profiles.values)
          p.name: {'status': 'ok', 'digest': p.digest},
      };
    await rig.sup.start();
    rig.h = await Harness.start(
      supervisorUrl: rig.sup.url,
      profiles: profiles,
      codexRuntime: CodexRuntime.official,
      codexGatewayUrl: 'http://gw/inner/agent/codex/v1',
      supervisorWait: supervisorWait,
      supervisorRetry: const Duration(milliseconds: 50),
    );
    codexAppServerPortForTests = () => rig.current!.port;
    addTearDown(rig.close);
    return rig;
  }

  void _configure(FakeShellctl s) {
    final id = s.retainedWorkspaceId;
    final box = boxes[s] = LocalBox(
      root.createTempSync('home-'),
      id == null ? root.createTempSync('ws-') : workspaceDir(id),
    );
    s
      ..onControl = (script) async {
        if (script.contains('--version')) {
          return (
            0,
            'version codex-cli $officialCodexVersion\n'
                'sha256 $officialCodexSha256\n',
          );
        }
        if (!LocalBox.handles(script)) return null;
        if (script.contains('rm -rf -- ') && script.contains('.codex-runs/')) {
          final runId = RegExp(r'\.codex-runs/(run_[0-9a-f]+)')
              .firstMatch(script)!
              .group(1)!;
          homeRemovedBeforeResult.add(
            !(h.service.store.run(runId)?.isEnded ?? true),
          );
        }
        return box.run(script);
      }
      ..onJob = (script) {
        final fake = current!;
        fake.onSetup(script);
        final appServer = fake.onJob(script);
        if (appServer != null) {
          fake.attach(s);
          this.box = box;
          return appServer;
        }
        if (LocalBox.handles(script)) {
          final (code, out) = box.runSync(script);
          return FakeJobSpec(output: out, exitCode: code);
        }
        return FakeJobSpec(
          output: script.contains('debug models --bundled')
              ? '{"models": []}'
              : script.contains('NO_PROXY')
              ? '\n\n'
              : '',
        );
      };
  }

  /// Starts [op] with [fake] as its app-server; returns the run ID.
  Future<String> round(FakeCodexAppServer fake, Map<String, Object?> op) async {
    current = fake;
    _fakes.add(fake);
    await fake.start();
    return h.startOperation(op);
  }

  Future<Map<String, Object?>> result(String run) async {
    final status = await h.waitEnded(run, timeout: const Duration(seconds: 30));
    return (status['result'] as Map).cast<String, Object?>();
  }

  /// What the Swift server does once a round's node ended.
  Future<void> deleteExecution(String executionId) async {
    final (status, body) = await h.delete('/v1/executions/$executionId', {
      'protocol': protocolName,
      'generation': 1,
    });
    expect(status, 200, reason: jsonEncode(body));
  }

  Future<void> close() async {
    codexAppServerPortForTests = null;
    for (final f in _fakes) {
      await f.close();
    }
    await h.close();
    await sup.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

/// A retaining operation of the official runtime with the shell and
/// report_progress.
Map<String, Object?> retainOp({
  String executionId = 'E1',
  String nodeId = 'N1',
  String? effort,
  String model = 'test-model',
  String systemPrompt = 'You are a helpful agent.',
  bool reportProgress = true,
  int outputAttempt = 0,
  Map<String, Object?>? continuation,
  Object? session = const {'retain': true},
}) {
  final o = officialCodexOp(effort: effort);
  return {
    ...o,
    'operation_id': '$executionId:$outputAttempt:0',
    'execution': {
      ...o['execution'] as Map<String, Object?>,
      'execution_id': executionId,
      'node_id': nodeId,
    },
    'model': {...o['model'] as Map<String, Object?>, 'name': model},
    'system_prompt': systemPrompt,
    'tools': {'shell': true, 'report_progress': reportProgress},
    'continuation': continuation,
    'codex_session': session,
  };
}

/// Plays a turn as Codex would for the retained thread: the rollout of the
/// root thread in CODEX_HOME (written when new, else appended), then the
/// answer. [before] sees the box and the local CODEX_HOME first;
/// [sparseSize] extends the rollout (sparse) to that size.
Future<void> Function(FakeCodexAppServer) codexTurn(
  RetainRig rig, {
  String answer = 'Done.',
  List<String> tools = const ['report_progress'],
  int? sparseSize,
  void Function(LocalBox box, String home)? before,
}) => (s) async {
  final box = rig.box!;
  final home = box.local(s.codexHome);
  before?.call(box, home);
  final f = File('$home/$rolloutRel');
  if (!f.existsSync()) {
    f
      ..createSync(recursive: true)
      ..writeAsStringSync(sessionMetaLine(tools));
  }
  f.writeAsStringSync(
    '{"type":"turn","answer":"$answer"}\n',
    mode: FileMode.append,
  );
  if (sparseSize != null) {
    final raf = f.openSync(mode: FileMode.append);
    raf.truncateSync(sparseSize);
    raf.closeSync();
  }
  s
    ..usage()
    ..message(answer, phase: 'final_answer')
    ..complete({'status': 'completed'});
};

Future<Map<String, Object?>> runStarted(Harness h, String run) async {
  final first = (await h.events(run)).first;
  expect(first.event, 'run_started');
  return first.data;
}
