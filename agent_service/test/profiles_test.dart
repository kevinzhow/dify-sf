import 'dart:convert';
import 'dart:io';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

const blenderImage =
    'dify-sf/sandbox-colvalley-blender@sha256:'
    '1111111111111111111111111111111111111111111111111111111111111111';
const defaultImage =
    'langgenius/dify-agent-local-sandbox@sha256:'
    'f4d404c9dcdf80bd72f65e84c3f2bbd1f3404fd4b363db837176da8aaf771b1d';

Map<String, Object?> blenderProfile({
  Object? image = blenderImage,
  Object? mounts,
  Object? devices,
  Object? limits,
  Object? env,
  Object? network,
}) => {
  'description':
      'Blender 5.2.3, colvalley-3d (read-only) and its board renderer',
  'image': image,
  'mounts':
      mounts ??
      [
        {
          'source': '/srv/dify-sf/checkouts/colvalley-3d-2d97747',
          'target': '/opt/colvalley-3d',
        },
      ],
  'network': network ?? {'egress': 'none'},
  'devices': devices ?? ['/dev/dri/renderD128'],
  'limits':
      limits ??
      {
        'cpus': 4,
        'memory_mb': 6144,
        'pids': 1024,
        'workspace_mb': 1536,
        'home_mb': 512,
        'timeout_seconds_max': 10800,
      },
  'env':
      env ??
      {
        'BLENDER': '/opt/blender/blender',
        'CV3D_PYTHON': '/opt/cv3d-venv/bin/python',
      },
};

Map<String, Object?> profileFile([Map<String, Object?>? blender]) => {
  'version': 1,
  'profiles': {
    'default': {'description': "Dify's shell sandbox", 'image': defaultImage},
    'colvalley-blender': blender ?? blenderProfile(),
  },
};

ExecutorProfiles parse(
  Map<String, Object?> json, {
  List<String> forbidden = const [],
}) => ExecutorProfiles.parse(json, forbiddenSources: forbidden);

Matcher refused(String fragment) => throwsA(
  isA<ProfileLoadError>().having(
    (e) => e.message,
    'message',
    contains(fragment),
  ),
);

/// A fake supervisor that reports every profile of [profiles] `ok`.
Future<(Harness, FakeSupervisor)> startWithProfiles(
  List<ScriptedCall> calls, {
  ExecutorProfiles? profiles,
  void Function(FakeShellctl)? configure,
}) async {
  final p = profiles ?? parse(profileFile());
  final sup = FakeSupervisor(key: testSupervisorKey, configure: configure)
    ..profiles = {
      for (final x in p.profiles.values)
        x.name: {'status': 'ok', 'digest': x.digest},
    };
  await sup.start();
  final h = await Harness.start(
    calls: calls,
    supervisorUrl: sup.url,
    profiles: p,
  );
  addTearDown(() async {
    await h.close();
    await sup.close();
  });
  return (h, sup);
}

Map<String, Object?> blenderOp({
  String executionId = 'E1',
  Map<String, Object?> env = const {},
  int timeoutSeconds = 7200,
  bool shell = true,
  Map<String, Object?>? continuation,
  int resumeSequence = 0,
  int outputAttempt = 0,
  String profile = 'colvalley-blender',
}) => operation(
  executionId: executionId,
  shell: shell,
  askHuman: false,
  env: env,
  timeoutSeconds: timeoutSeconds,
  executorProfile: profile,
  continuation: continuation,
  resumeSequence: resumeSequence,
  outputAttempt: outputAttempt,
);

void main() {
  group('profile file', () {
    test('a valid file: default first, every field read, digests stable', () {
      final p = parse(profileFile());
      expect(p.names, ['default', 'colvalley-blender']);
      final b = p['colvalley-blender']!;
      expect(b.image, blenderImage);
      expect(
        b.mounts.single.source,
        '/srv/dify-sf/checkouts/colvalley-3d-2d97747',
      );
      expect(b.mounts.single.target, '/opt/colvalley-3d');
      expect(b.egress, Egress.none);
      expect(b.devices, ['/dev/dri/renderD128']);
      expect(b.limits.cpus, 4.0);
      expect(b.limits.memoryMb, 6144);
      expect(b.limits.pids, 1024);
      expect(b.limits.workspaceMb, 1536);
      expect(b.limits.homeMb, 512);
      expect(b.timeoutSecondsMax, 10800);
      expect(b.env, {
        'BLENDER': '/opt/blender/blender',
        'CV3D_PYTHON': '/opt/cv3d-venv/bin/python',
      });
      final d = p['default']!;
      expect(d.egress, Egress.allowlist);
      expect(d.timeoutSecondsMax, defaultTimeoutSecondsMax);
      expect(d.limits.memoryMb, isNull);
      // Same definition, same digest; key order does not matter.
      final again = parse(
        jsonDecode(jsonEncode(profileFile())) as Map<String, Object?>,
      );
      expect(again['colvalley-blender']!.digest, b.digest);
      expect(d.digest, isNot(b.digest));
    });

    test('no file at the default path: the implicit default; a named file '
        'must exist', () {
      final implicit = ExecutorProfiles.implicit();
      expect(implicit.names, ['default']);
      expect(implicit['default']!.image, isNull);
      expect(implicit['default']!.timeoutSecondsMax, 1800);
      expect(
        () => ExecutorProfiles.load('/nonexistent/executor-profiles.json'),
        refused('does not exist'),
      );
      final dir = newDataDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/p.json')..writeAsStringSync('{nope');
      expect(() => ExecutorProfiles.load(f.path), refused('is not JSON'));
      f.writeAsStringSync(jsonEncode(profileFile()));
      expect(ExecutorProfiles.load(f.path).names, hasLength(2));
      expect(ExecutorProfiles.load(f.path).path, f.path);
    });

    test('images must be pinned by digest', () {
      for (final image in [
        'dify-sf/sandbox-colvalley-blender:1',
        'dify-sf/sandbox-colvalley-blender',
        'dify-sf/sandbox-colvalley-blender@sha256:abc',
        'Dify/X@sha256:${'1' * 64}',
        42,
        null,
      ]) {
        expect(
          () => parse(profileFile(blenderProfile(image: image))),
          refused('pinned by digest'),
          reason: '$image',
        );
      }
      for (final image in [
        'x@sha256:${'a' * 64}',
        'dify-sf/sandbox-colvalley-blender:1@sha256:${'a' * 64}',
        'registry.local:5000/a/b@sha256:${'a' * 64}',
      ]) {
        expect(
          parse(
            profileFile(blenderProfile(image: image)),
          )['colvalley-blender']!.image,
          image,
        );
      }
    });

    test('mounts: read-only binds of normalized absolute host paths into '
        '/opt only, never the socket, the data dir or the profile file', () {
      Map<String, Object?> m(String source, [String target = '/opt/x']) =>
          profileFile(
            blenderProfile(
              mounts: [
                {'source': source, 'target': target},
              ],
            ),
          );
      final forbidden = [
        '/srv/agent-data',
        '/etc/dify-sf/executor-profiles.json',
      ];
      for (final (source, why) in [
        ('/', 'must not be /'),
        ('relative/path', 'absolute path'),
        ('/srv/a/../b', 'normalized'),
        ('/srv/a/', 'normalized'),
        ('/srv//a', 'normalized'),
        ('/srv/a:/opt/b', '":"'),
        ('/var/run/docker.sock', 'docker.sock'),
        ('/run', '/run/docker.sock'), // contains the socket
        ('/var', '/var/run/docker.sock'),
        ('/var/lib/docker/volumes/x', '/var/lib/docker'),
        ('/proc/1', '/proc'),
        ('/dev/dri', '/dev'),
        ('/srv/agent-data', '/srv/agent-data'),
        ('/srv/agent-data/runs', '/srv/agent-data'),
        ('/srv', '/srv/agent-data'),
        ('/etc', 'executor-profiles.json'),
      ]) {
        expect(
          () => parse(m(source), forbidden: forbidden),
          refused(why),
          reason: source,
        );
      }
      for (final (target, why) in [
        ('/workspace/x', 'under /opt'),
        ('/home/dify/x', 'under /opt'),
        ('/opt', 'under /opt'),
        ('/optx', 'under /opt'),
        ('opt/x', 'absolute path'),
      ]) {
        expect(() => parse(m('/srv/x', target)), refused(why), reason: target);
      }
      expect(
        () => parse(
          profileFile(
            blenderProfile(
              mounts: [
                {'source': '/srv/a', 'target': '/opt/a'},
                {'source': '/srv/b', 'target': '/opt/a/b'},
              ],
            ),
          ),
        ),
        refused('overlaps'),
      );
      expect(
        () => parse(
          profileFile(
            blenderProfile(
              mounts: [
                {'source': '/srv/a', 'target': '/opt/a', 'read_only': false},
              ],
            ),
          ),
        ),
        refused('unknown fields read_only'),
      );
      // The data dir known to the process is refused when given.
      expect(parse(m('/srv/ok')).profiles, hasLength(2));
    });

    test('devices: DRI render nodes only', () {
      for (final d in [
        '/dev/dri/card0',
        '/dev/dri',
        '/dev/sda',
        '/dev/dri/renderD128/../card0',
        '/dev/nvidia0',
        'renderD128',
      ]) {
        expect(
          () => parse(profileFile(blenderProfile(devices: [d]))),
          refused('render nodes'),
          reason: d,
        );
      }
      expect(
        () => parse(
          profileFile(
            blenderProfile(
              devices: ['/dev/dri/renderD128', '/dev/dri/renderD128'],
            ),
          ),
        ),
        refused('repeats'),
      );
      expect(
        parse(
          profileFile(blenderProfile(devices: ['/dev/dri/renderD129'])),
        )['colvalley-blender']!.devices,
        ['/dev/dri/renderD129'],
      );
    });

    test('env: reserved and malformed names are refused', () {
      for (final name in [
        'PATH',
        'home',
        'TMPDIR',
        'SHELLCTL_AUTH_TOKEN',
        'https_proxy',
        'NO_PROXY',
      ]) {
        expect(
          () => parse(profileFile(blenderProfile(env: {name: 'x'}))),
          refused('reserved'),
          reason: name,
        );
      }
      for (final name in ['1X', 'A-B', 'A=B', '']) {
        expect(
          () => parse(profileFile(blenderProfile(env: {name: 'x'}))),
          refused('not a valid variable name'),
          reason: name,
        );
      }
      expect(
        () => parse(profileFile(blenderProfile(env: {'X': 1}))),
        refused('must be a string'),
      );
    });

    test('limits, network, names, version and unknown fields', () {
      expect(
        () => parse(
          profileFile(
            blenderProfile(
              limits: {'memory_mb': 2048, 'workspace_mb': 1536, 'home_mb': 512},
            ),
          ),
        ),
        refused('must be below limits.memory_mb'),
      );
      expect(
        () => parse(profileFile(blenderProfile(limits: {'cpus': 0}))),
        refused('limits.cpus'),
      );
      expect(
        () => parse(profileFile(blenderProfile(limits: {'pids': 4}))),
        refused('limits.pids'),
      );
      expect(
        () => parse(
          profileFile(blenderProfile(limits: {'timeout_seconds_max': 100000})),
        ),
        refused('timeout_seconds_max'),
      );
      expect(
        () => parse(profileFile(blenderProfile(limits: {'gpus': 1}))),
        refused('unknown fields gpus'),
      );
      expect(
        () => parse(profileFile(blenderProfile(network: {'egress': 'open'}))),
        refused('network.egress'),
      );
      expect(
        () => parse(
          profileFile(
            blenderProfile(network: {'egress': 'none', 'domains': []}),
          ),
        ),
        refused('unknown fields domains'),
      );
      expect(
        () => parse({...profileFile(), 'version': 2}),
        refused('"version" must be 1'),
      );
      expect(
        () => parse({...profileFile(), 'extra': true}),
        refused('unknown fields extra'),
      );
      expect(
        () => parse(profileFile({...blenderProfile(), 'privileged': true})),
        refused('unknown fields privileged'),
      );
      expect(
        () => parse({
          'version': 1,
          'profiles': {'colvalley-blender': blenderProfile()},
        }),
        refused('must define "default"'),
      );
      expect(
        () => parse({
          'version': 1,
          'profiles': {
            'default': {'image': defaultImage},
            'Colvalley': blenderProfile(),
          },
        }),
        refused('profile name "Colvalley"'),
      );
    });
  });

  group('service', () {
    test('GET /v1/profiles lists names, descriptions, statuses and caps only; '
        'health has the statuses', () async {
      final (h, _) = await startWithProfiles(const []);
      final (s, list) = await h.get('/v1/profiles');
      expect(s, 200);
      expect(list, {
        'protocol': protocolName,
        'profiles': [
          {
            'name': 'default',
            'description': "Dify's shell sandbox",
            'status': 'ok',
            'timeout_seconds_max': 1800,
          },
          {
            'name': 'colvalley-blender',
            'description': 'Blender 5.2.3, colvalley-3d (read-only) and its board renderer',
            'status': 'ok',
            'timeout_seconds_max': 10800,
          },
        ],
      });
      final text = jsonEncode(list);
      for (final secret in ['sha256', '/srv/', '/dev/dri', 'BLENDER', 'none']) {
        expect(text, isNot(contains(secret)));
      }
      final (_, health) = await h.get('/v1/health');
      expect(health['profiles'], {'default': 'ok', 'colvalley-blender': 'ok'});
      expect((await h.post('/v1/profiles', {})).$1, 405);
    });

    test('statuses come from the supervisor; a profile it does not know or '
        'defines differently, or a supervisor that cannot be asked, is '
        'unavailable', () async {
      final (h, sup) = await startWithProfiles(const []);
      sup.profiles!['colvalley-blender'] = {
        'status': 'image_missing',
        'digest': sup.profiles!['colvalley-blender']!['digest'],
      };
      expect((await h.get('/v1/health')).$2['profiles'], {
        'default': 'ok',
        'colvalley-blender': 'image_missing',
      });
      sup.profiles!['colvalley-blender'] = {'status': 'ok', 'digest': 'other'};
      expect((await h.get('/v1/health')).$2['profiles'], {
        'default': 'ok',
        'colvalley-blender': 'unavailable',
      });
      sup.profiles!.remove('colvalley-blender');
      expect(
        ((await h.get('/v1/health')).$2['profiles']
            as Map)['colvalley-blender'],
        'unavailable',
      );
      sup.profiles = null; // an older supervisor: 404
      expect((await h.get('/v1/health')).$2['profiles'], {
        'default': 'unavailable',
        'colvalley-blender': 'unavailable',
      });
    });

    test('the profile status is cached for its TTL', () async {
      final p = parse(profileFile());
      final sup = FakeSupervisor(key: testSupervisorKey)
        ..profiles = {
          for (final x in p.profiles.values)
            x.name: {'status': 'ok', 'digest': x.digest},
        };
      await sup.start();
      addTearDown(sup.close);
      final manager = SandboxManager(
        supervisor: SupervisorClient(sup.url, testSupervisorKey),
        store: RunStore(newDataDir().path),
        profiles: p,
        profileStatusTtl: const Duration(hours: 1),
      );
      expect(
        (await manager.profileStatuses()).statuses['colvalley-blender'],
        'ok',
      );
      sup.profiles!['colvalley-blender']!['status'] = 'image_missing';
      expect(
        (await manager.profileStatuses()).statuses['colvalley-blender'],
        'ok',
      );
      manager.close();
    });

    test('operation answers: unknown profile 422, timeout above the cap 422, '
        'a variable the profile sets 400, image missing 503, unknown fields '
        '400, an empty name 400', () async {
      final (h, sup) = await startWithProfiles(const []);
      Future<(int, Map<String, Object?>)> post(Map<String, Object?> body) =>
          h.post('/v1/operations', body);

      var (s, j) = await post(blenderOp(profile: 'nope'));
      expect((s, j['error']), (422, 'executor_profile_unknown'));
      (s, j) = await post(blenderOp(timeoutSeconds: 10801));
      expect((s, j['error']), (422, 'invalid_request'));
      expect(j['message'], contains('10800'));
      (s, j) = await post(blenderOp(env: {'blender': '/usr/bin/blender'}));
      expect((s, j['error']), (400, 'reserved_env'));
      (s, j) = await post({...blenderOp(), 'image': 'evil@sha256:${'0' * 64}'});
      expect((s, j['error']), (400, 'invalid_request'));
      expect(j['message'], 'unknown request fields: image');
      (s, j) = await post({...blenderOp(), 'executor_profile': ''});
      expect((s, j['error']), (400, 'invalid_request'));
      (s, j) = await post({...blenderOp(), 'executor_profile': 7});
      expect((s, j['error']), (400, 'invalid_request'));
      final digest = sup.profiles!['colvalley-blender']!['digest'];
      sup.profiles!['colvalley-blender'] = {
        'status': 'device_missing',
        'digest': digest,
      };
      (s, j) = await post(blenderOp());
      expect(s, 503);
      expect(j, {
        'protocol': protocolName,
        'error': 'executor_profile_unavailable',
        'message':
            'executor profile colvalley-blender is not available on this '
            'host (device_missing)',
        'status': 'device_missing',
      });
      // The default timeout cap applies to the default profile too.
      (s, j) = await post(blenderOp(profile: 'default', timeoutSeconds: 1801));
      expect((s, j['error']), (422, 'invalid_request'));
      expect(sup.acquires, isEmpty);
    });

    test('an accepted operation resent after the image went missing answers '
        '200 with its run, not 503', () async {
      final (h, sup) = await startWithProfiles([ScriptedCall.text('ok')]);
      final body = blenderOp();
      final run = await h.startOperation(body);
      await h.waitEnded(run);
      sup.profiles!['colvalley-blender']!['status'] = 'image_missing';
      final (s, j) = await h.post('/v1/operations', body);
      expect(s, 200);
      expect(j['run_id'], run);
    });

    test('a supervisor that cannot be asked does not refuse the operation; '
        'the run then fails on the sandbox', () async {
      final (h, sup) = await startWithProfiles([
        ScriptedCall.toolCall('c1', 'shell_run', {'script': 'true'}),
        ScriptedCall.text('done'),
      ]);
      sup.profiles = null;
      sup.failAcquire = 503;
      final run = await h.startOperation(blenderOp());
      final s = await h.waitEnded(run);
      expect(s['status'], 'failed');
      expect((s['result'] as Map)['error_type'], 'sandbox_unavailable');
    });

    test('a shell run acquires its sandbox with the profile, echoes it in '
        'run_started and the snapshot, and gives jobs the profile env under '
        'the node env', () async {
      final (h, sup) = await startWithProfiles([
        ScriptedCall.toolCall('c1', 'shell_run', {'script': r'echo $BLENDER'}),
        ScriptedCall.text('done'),
      ], configure: (s) => s.onJob = (_) => FakeJobSpec(output: 'ok\r\n'));
      final run = await h.startOperation(blenderOp(env: {'API_KEY': 'k'}));
      final status = await h.waitEnded(run);
      expect(status['status'], 'succeeded', reason: jsonEncode(status));
      expect(sup.acquiredProfiles, ['colvalley-blender']);
      final events = await h.events(run);
      expect(events.first.event, 'run_started');
      expect(events.first.data['executor_profile'], 'colvalley-blender');
      final snapshot = (status['result'] as Map)['snapshot'] as Map;
      expect(snapshot['executor_profile'], 'colvalley-blender');
      expect(snapshot['workspace_ref'], 'sbx1');
      expect(sup.sandboxOf('E1')!.userRuns.single['env'], {
        'BLENDER': '/opt/blender/blender',
        'CV3D_PYTHON': '/opt/cv3d-venv/bin/python',
        'API_KEY': 'k',
        'HOME': '/home/dify/agent',
      });
    });

    test('without the shell the profile is not checked, only echoed; absent '
        'means default', () async {
      final (h, sup) = await startWithProfiles([
        ScriptedCall.text('a'),
        ScriptedCall.text('b'),
      ]);
      final run = await h.startOperation(
        blenderOp(
          shell: false,
          profile: 'not-on-this-server',
          timeoutSeconds: 99999,
        ),
      );
      await h.waitEnded(run);
      expect(
        (await h.events(run)).first.data['executor_profile'],
        'not-on-this-server',
      );
      final run2 = await h.startOperation(
        operation(executionId: 'E2', askHuman: false),
      );
      await h.waitEnded(run2);
      expect((await h.events(run2)).first.data['executor_profile'], 'default');
      expect(sup.acquires, isEmpty);
    });

    test('a supervisor that ignores the profile (no echo) or answers another '
        'one fails the run with sandbox_unavailable', () async {
      for (final report in ['', 'default']) {
        final (h, sup) = await startWithProfiles([
          ScriptedCall.toolCall('c1', 'shell_run', {'script': 'true'}),
          ScriptedCall.text('done'),
        ]);
        sup.reportProfile = report;
        final run = await h.startOperation(blenderOp());
        final s = await h.waitEnded(run);
        expect(s['status'], 'failed', reason: report);
        final result = s['result'] as Map;
        expect(result['error_type'], 'sandbox_unavailable');
        expect(result['message'], contains('not colvalley-blender'));
      }
    });

    test('a continuation must name the profile of its sandbox', () async {
      final (h, _) = await startWithProfiles([
        ScriptedCall.toolCall('c1', 'shell_run', {'script': 'true'}),
        ScriptedCall.text('first'),
        ScriptedCall.text('retried'),
      ], configure: (s) => s.onJob = (_) => FakeJobSpec(output: 'ok\r\n'));
      final run = await h.startOperation(blenderOp());
      final result = (await h.waitEnded(run))['result'] as Map;
      final snapshot = (result['snapshot'] as Map).cast<String, Object?>();
      expect(snapshot['workspace_ref'], isNotNull);
      final retry = {
        'kind': 'output_retry',
        'snapshot': snapshot,
        'feedback': [
          {'field': 'text', 'error': 'too short'},
        ],
      };
      final (s, j) = await h.post(
        '/v1/operations',
        blenderOp(
          profile: 'default',
          timeoutSeconds: 600,
          continuation: retry,
          outputAttempt: 1,
        ),
      );
      expect((s, j['error']), (422, 'snapshot_incompatible'));
      expect(j['message'], contains('"colvalley-blender"'));
      // A snapshot from before profiles (no field) belongs to `default`.
      final old = Map<String, Object?>.of(snapshot)..remove('executor_profile');
      final (s2, j2) = await h.post(
        '/v1/operations',
        blenderOp(continuation: {...retry, 'snapshot': old}, outputAttempt: 1),
      );
      expect((s2, j2['error']), (422, 'snapshot_incompatible'));
      final run2 = await h.startOperation(
        blenderOp(continuation: retry, outputAttempt: 1),
      );
      expect((await h.waitEnded(run2))['status'], 'succeeded');
    });

    test('the sandbox layer refuses a node variable the profile sets', () {
      final sandbox = ExecutionSandbox(
        executionId: 'E1',
        grant: SandboxGrant('s', Uri.parse('http://x'), 't', created: true),
      );
      expect(
        () => sandbox.jobEnv({'Blender': 'x'}, profileEnv: {'BLENDER': 'y'}),
        throwsA(isA<SandboxFailure>()),
      );
      expect(
        () => sandbox.jobEnv({}, profileEnv: {'PATH': '/x'}),
        throwsA(isA<SandboxFailure>()),
      );
      expect(sandbox.jobEnv({'A': '1'}, profileEnv: {'B': '2'}), {
        'B': '2',
        'A': '1',
        'HOME': '/home/dify/agent',
      });
    });
  });
}
