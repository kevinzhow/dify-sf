import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_service/supervisor.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

/// A fake Docker Engine API on a unix socket.
class FakeDocker {
  FakeDocker(this.socketPath);

  final String socketPath;
  HttpServer? _server;
  final Map<String, Map<String, Object?>> containers = {};
  final List<(String, String, Object?)> requests = [];
  final List<Map<String, Object?>> creates = [];
  var _next = 0;

  Future<void> start() async {
    final server = _server = await HttpServer.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    server.listen((r) => unawaited(_handle(r)));
  }

  Future<void> close() async => _server?.close(force: true);

  /// Adds a container as if created by someone.
  String seed(String name, Map<String, String> labels, {bool running = true}) {
    final id = 'seed${++_next}'.padRight(64, '0');
    containers[id] = _container(id, name, labels, const [], running: running);
    return id;
  }

  Map<String, Object?> _container(
    String id,
    String name,
    Map<String, String> labels,
    List<Object?> env, {
    bool running = false,
  }) => {
    'Id': id,
    'Name': '/$name',
    'Config': {'Labels': labels, 'Env': env},
    'State': {
      'Running': running,
      'Status': running ? 'running' : 'exited',
      'ExitCode': 0,
      'Health': {'Status': running ? 'healthy' : 'unhealthy'},
    },
    'NetworkSettings': {
      'Networks': {
        'sbx-net': {'IPAddress': '10.9.0.${_next + 1}'},
      },
    },
  };

  Map<String, Object?>? _find(String idOrName) =>
      containers[idOrName] ??
      containers.values.where((c) => c['Name'] == '/$idOrName').firstOrNull;

  Future<void> _handle(HttpRequest request) async {
    final res = request.response;
    final text = await utf8.decodeStream(request);
    final body = text.isEmpty ? null : jsonDecode(text);
    final path = request.uri.path;
    requests.add((request.method, request.uri.toString(), body));
    void reply(int status, [Object? json]) {
      res.statusCode = status;
      if (json != null) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(json));
      }
      unawaited(res.close());
    }

    final segments = request.uri.pathSegments;
    if (segments.first != 'v1.44') return reply(400, {'message': 'version'});
    switch ((request.method, segments.sublist(1))) {
      case ('GET', ['_ping']):
        return reply(200, 'OK');
      case ('GET', ['containers', 'json']):
        final filters =
            jsonDecode(request.uri.queryParameters['filters']!) as Map;
        final wanted = (filters['label'] as List).cast<String>();
        return reply(200, [
          for (final c in containers.values)
            if (wanted.every((l) {
              final labels = (c['Config'] as Map)['Labels'] as Map;
              final eq = l.indexOf('=');
              return labels[l.substring(0, eq)] == l.substring(eq + 1);
            }))
              {
                'Id': c['Id'],
                'Names': [c['Name']],
                'State': (c['State'] as Map)['Status'],
                'Labels': (c['Config'] as Map)['Labels'],
              },
        ]);
      case ('POST', ['containers', 'create']):
        final name = request.uri.queryParameters['name']!;
        if (_find(name) != null) return reply(409, {'message': 'conflict'});
        final payload = (body as Map).cast<String, Object?>();
        creates.add(payload);
        final id = 'c${++_next}'.padRight(64, 'f');
        containers[id] = _container(
          id,
          name,
          (payload['Labels'] as Map).cast<String, String>(),
          payload['Env'] as List,
        )..['State'] = {'Running': false, 'Status': 'created'};
        return reply(201, {'Id': id, 'Warnings': <Object?>[]});
      case ('POST', ['containers', final id, 'start']):
        final c = _find(id);
        if (c == null) return reply(404, {'message': 'no such container'});
        c['State'] = {
          'Running': true,
          'Status': 'running',
          'Health': {'Status': 'healthy'},
        };
        return reply(204);
      case ('GET', ['containers', final id, 'json']):
        final c = _find(id);
        return c == null
            ? reply(404, {'message': 'no such container'})
            : reply(200, c);
      case ('DELETE', ['containers', final id]):
        final c = _find(id);
        if (c == null) return reply(404, {'message': 'no such container'});
        containers.remove(c['Id']);
        return reply(204);
      default:
        return reply(404, {'message': 'no route $path'});
    }
  }
}

void main() {
  late Directory dir;
  late FakeDocker docker;
  late SandboxSupervisor supervisor;
  late http.Client client;
  const key = 'sup-key';

  SupervisorConfig config({String? statePath}) => SupervisorConfig(
    key: key,
    network: 'sbx-net',
    dockerSocket: docker.socketPath,
    labelKey: 'dify-sf.test',
    labelValue: 'unit',
    memoryMb: 512,
    cpus: 0.5,
    pidsLimit: 128,
    homeMb: 64,
    workspaceMb: 128,
    proxyUrl: 'http://proxy:3128',
    statePath: statePath,
    startTimeout: const Duration(seconds: 2),
  );

  Future<void> startSupervisor({String? statePath}) async {
    supervisor = SandboxSupervisor(config(statePath: statePath));
    await supervisor.start(address: '127.0.0.1', port: 0);
  }

  Future<(int, Map<String, Object?>)> call(
    String method,
    String path, {
    Object? body,
    String auth = key,
  }) async {
    final request = http.Request(
      method,
      Uri.parse('http://127.0.0.1:${supervisor.port}$path'),
    )..headers['Authorization'] = 'Bearer $auth';
    if (body != null) request.body = jsonEncode(body);
    final r = await http.Response.fromStream(await client.send(request));
    return (r.statusCode, (jsonDecode(r.body) as Map).cast<String, Object?>());
  }

  setUp(() async {
    dir = newDataDir();
    docker = FakeDocker('${dir.path}/d.sock');
    expect(docker.socketPath.length, lessThan(100));
    await docker.start();
    client = http.Client();
  });

  tearDown(() async {
    client.close();
    await supervisor.stop();
    await docker.close();
    dir.deleteSync(recursive: true);
  });

  test('create sends the fixed payload: image, limits, labels, network, no '
      'binds, all capabilities dropped, a random token', () async {
    await startSupervisor();
    final (s1, a) = await call(
      'POST',
      '/v1/sandboxes',
      body: {'execution_key': 'E1'},
    );
    expect(s1, 201);
    expect(a['created'], true);
    final payload = docker.creates.single;
    final env = (payload['Env'] as List).cast<String>();
    expect(env.first, startsWith('SHELLCTL_AUTH_TOKEN='));
    final token = env.first.substring('SHELLCTL_AUTH_TOKEN='.length);
    expect(token, a['token']);
    expect(token.length, greaterThanOrEqualTo(43));
    expect(payload, {
      'Image': 'langgenius/dify-agent-local-sandbox:1.17.1',
      'Env': [
        'SHELLCTL_AUTH_TOKEN=$token',
        'HTTP_PROXY=http://proxy:3128',
        'HTTPS_PROXY=http://proxy:3128',
        'http_proxy=http://proxy:3128',
        'https_proxy=http://proxy:3128',
        'NO_PROXY=localhost,127.0.0.1',
        'no_proxy=localhost,127.0.0.1',
      ],
      'Labels': {
        'dify-sf.test': 'unit',
        executionLabel: SandboxSupervisor.hashKey('E1'),
      },
      'Healthcheck': {
        'Test': ['CMD', 'curl', '-fsS', 'http://127.0.0.1:5004/healthz'],
        'Interval': 30000000000,
        'Timeout': 5000000000,
        'Retries': 3,
        'StartPeriod': 2000000000,
        'StartInterval': 500000000,
      },
      'HostConfig': {
        'NetworkMode': 'sbx-net',
        'Memory': 512 * 1024 * 1024,
        'MemorySwap': 512 * 1024 * 1024,
        'NanoCpus': 500000000,
        'PidsLimit': 128,
        'ReadonlyRootfs': true,
        'Tmpfs': {
          '/home/dify':
              'rw,exec,nosuid,nodev,size=64m,mode=0700,uid=1000,gid=1000',
          '/workspace':
              'rw,exec,nosuid,nodev,size=128m,mode=0700,uid=1000,gid=1000',
        },
        'CapDrop': ['ALL'],
        'SecurityOpt': ['no-new-privileges:true'],
        'Privileged': false,
        'Binds': <Object?>[],
        'Mounts': <Object?>[],
        'IpcMode': 'private',
        'RestartPolicy': {'Name': 'no'},
        'LogConfig': {
          'Type': 'json-file',
          'Config': {'max-size': '1m', 'max-file': '1'},
        },
      },
      'NetworkingConfig': {
        'EndpointsConfig': {'sbx-net': <String, Object?>{}},
      },
    });
    expect(a['url'], 'http://${supervisor.containerName('E1')}:5004');

    // Idempotent per execution key: same sandbox and token, nothing created.
    final (s2, again) = await call(
      'POST',
      '/v1/sandboxes',
      body: {'execution_key': 'E1'},
    );
    expect(s2, 200);
    expect(again['sandbox_id'], a['sandbox_id']);
    expect(again['token'], token);
    expect(again['created'], false);
    expect(docker.creates, hasLength(1));

    final (_, b) = await call(
      'POST',
      '/v1/sandboxes',
      body: {'execution_key': 'E2'},
    );
    expect(b['token'], isNot(token));
    expect(b['sandbox_id'], isNot(a['sandbox_id']));
  });

  test(
    'a request cannot choose the image or limits; auth is required',
    () async {
      await startSupervisor();
      final (s, j) = await call(
        'POST',
        '/v1/sandboxes',
        body: {'execution_key': 'E1', 'image': 'evil'},
      );
      expect(s, 400);
      expect(j['message'], contains('image'));
      final (s2, _) = await call(
        'POST',
        '/v1/sandboxes',
        body: {'execution_key': 'E1'},
        auth: 'wrong',
      );
      expect(s2, 401);
      expect(docker.creates, isEmpty);
    },
  );

  test(
    'delete removes labelled sandboxes only; list shows labelled ones',
    () async {
      final foreign = docker.seed('someone-else', {'app': 'db'});
      await startSupervisor();
      final (_, a) = await call(
        'POST',
        '/v1/sandboxes',
        body: {'execution_key': 'E1'},
      );
      final (ls, list) = await call('GET', '/v1/sandboxes');
      expect(ls, 200);
      expect((list['sandboxes'] as List).map((s) => (s as Map)['sandbox_id']), [
        a['sandbox_id'],
      ]);
      final (s1, _) = await call('DELETE', '/v1/sandboxes/$foreign');
      expect(s1, 404);
      expect(docker.containers, contains(foreign));
      final (s2, d) = await call('DELETE', '/v1/sandboxes/${a['sandbox_id']}');
      expect(s2, 200);
      expect(d['deleted'], true);
      expect(docker.containers.keys, [foreign]);
      final (s3, d3) = await call('DELETE', '/v1/sandboxes/${a['sandbox_id']}');
      expect(s3, 200);
      expect(d3['deleted'], false);
      final deletes = docker.requests.where((r) => r.$1 == 'DELETE').toList();
      expect(deletes.single.$2, contains('force=1&v=1'));
    },
  );

  test('the startup sweep removes unknown labelled containers and keeps '
      'known and unlabelled ones', () async {
    final statePath = '${dir.path}/state.json';
    final foreign = docker.seed('someone-else', {'dify-sf.test': 'other'});
    final orphan = docker.seed('orphan', {'dify-sf.test': 'unit'});
    final known = docker.seed('known', {'dify-sf.test': 'unit'});
    File(statePath).writeAsStringSync(
      jsonEncode({
        'sandboxes': {known: 'h', 'gone': 'h'},
      }),
    );
    await startSupervisor(statePath: statePath);
    expect(docker.containers.keys, unorderedEquals([foreign, known]));
    expect(docker.containers, isNot(contains(orphan)));
    expect(supervisor.knownIds, {known});
    expect(
      (jsonDecode(File(statePath).readAsStringSync()) as Map)['sandboxes'],
      {known: 'h'},
    );
  });

  test('a stopped sandbox is replaced by a new one', () async {
    await startSupervisor();
    final (_, a) = await call(
      'POST',
      '/v1/sandboxes',
      body: {'execution_key': 'E1'},
    );
    (docker.containers[a['sandbox_id']]!['State'] as Map)
      ..['Running'] = false
      ..['Status'] = 'exited';
    final (s, b) = await call(
      'POST',
      '/v1/sandboxes',
      body: {'execution_key': 'E1'},
    );
    expect(s, 201);
    expect(b['sandbox_id'], isNot(a['sandbox_id']));
    expect(docker.containers, isNot(contains(a['sandbox_id'])));
  });

  test('a name taken by an unlabelled container is never touched', () async {
    await startSupervisor();
    final foreign = docker.seed(supervisor.containerName('E9'), {'x': 'y'});
    final (s, j) = await call(
      'POST',
      '/v1/sandboxes',
      body: {'execution_key': 'E9'},
    );
    expect(s, 409);
    expect(j['error'], 'name_conflict');
    expect(docker.containers, contains(foreign));
  });

  test('configuration from the environment', () {
    final c = SupervisorConfig.fromEnv({
      'SANDBOX_SUPERVISOR_KEY': 'k',
      'SANDBOX_NETWORK': 'n',
      'SANDBOX_LABEL': 'a.b=c',
      'SANDBOX_ADDRESS': 'ip',
    });
    expect(c.labelKey, 'a.b');
    expect(c.labelValue, 'c');
    expect(c.addressByIp, isTrue);
    expect(c.memoryMb, 1024);
    expect(
      () => SupervisorConfig.fromEnv({'SANDBOX_SUPERVISOR_KEY': 'k'}),
      throwsA(isA<SupervisorConfigError>()),
    );
    expect(
      () => SupervisorConfig.fromEnv({
        'SANDBOX_SUPERVISOR_KEY': 'k',
        'SANDBOX_NETWORK': 'n',
        'SANDBOX_MEMORY_MB': '256',
      }),
      throwsA(isA<SupervisorConfigError>()),
    );
  });
}
