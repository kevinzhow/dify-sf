import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_service/supervisor.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

/// A fake Docker Engine API on a unix socket: containers, networks with
/// IPAM subnets and endpoints, connect and disconnect.
class FakeDocker {
  FakeDocker(this.socketPath);

  final String socketPath;
  HttpServer? _server;
  final Map<String, Map<String, Object?>> containers = {};
  final Map<String, Map<String, Object?>> networks = {};
  final Map<String, Map<String, Object?>> volumes = {};

  /// Image references present on this fake host.
  final Set<String> images = {'langgenius/dify-agent-local-sandbox:1.17.1'};
  final List<(String, String, Object?)> requests = [];
  final List<Map<String, Object?>> creates = [];
  final List<Map<String, Object?>> networkCreates = [];

  /// Subnets refused as overlapping although no listed network has them
  /// (taken concurrently by someone else).
  final Set<String> refuseSubnets = {};

  /// Container starts fail with HTTP 500.
  bool failStart = false;

  /// A barrier after an inspect snapshot was captured, before replying.
  Future<void> Function(String id)? afterContainerInspect;
  var _next = 0;

  Future<void> start() async {
    final server = _server = await HttpServer.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    server.listen((r) => unawaited(_handle(r)));
  }

  Future<void> close() async => _server?.close(force: true);

  /// The calls made, as `METHOD path` without the version prefix.
  List<String> get calls => [
    for (final r in requests)
      '${r.$1} ${Uri.parse(r.$2).path.replaceFirst('/v1.44', '')}',
  ];

  /// Adds a running container as if created by someone.
  String seed(String name, Map<String, String> labels, {bool running = true}) {
    final id = 'seed${++_next}'.padRight(64, '0');
    containers[id] = _container(id, name, labels, const [], running: running);
    return id;
  }

  /// Adds a network as if created by someone.
  String seedNetwork(
    String name, {
    String? subnet,
    Map<String, String> labels = const {},
  }) {
    final id = 'net${++_next}'.padRight(64, '0');
    networks[id] = {
      'Id': id,
      'Name': name,
      'Labels': labels,
      'Options': <String, String>{},
      'IPAM': {
        'Config': [
          if (subnet != null) {'Subnet': subnet},
        ],
      },
      'Containers': <String, Object?>{},
    };
    return id;
  }

  /// Endpoints of a network: container ID → IPv4 address.
  Map<String, String> endpoints(String nameOrId) => {
    for (final e
        in ((_net(nameOrId)!['Containers'] as Map).cast<String, Map>()).entries)
      e.key: e.value['IPv4Address'] as String,
  };

  Map<String, Object?> _container(
    String id,
    String name,
    Map<String, String> labels,
    List<Object?> env, {
    bool running = false,
    String network = 'bridge',
  }) => {
    'Id': id,
    'Name': '/$name',
    'Config': {'Labels': labels, 'Env': env},
    'HostConfig': {'NetworkMode': network},
    'State': {
      'Running': running,
      'Status': running ? 'running' : 'exited',
      'ExitCode': 0,
      'Health': {'Status': running ? 'healthy' : 'unhealthy'},
    },
    'NetworkSettings': {'Networks': <String, Object?>{}},
  };

  Map<String, Object?>? _find(String idOrName) =>
      containers[idOrName] ??
      containers.values.where((c) => c['Name'] == '/$idOrName').firstOrNull;

  Map<String, Object?>? _net(String idOrName) =>
      networks[idOrName] ??
      networks.values.where((n) => n['Name'] == idOrName).firstOrNull;

  static bool _matches(Map labels, List<String> wanted) => wanted.every((l) {
    final eq = l.indexOf('=');
    return eq < 0
        ? labels.containsKey(l)
        : labels[l.substring(0, eq)] == l.substring(eq + 1);
  });

  static (int, int) _range(String cidr) {
    final net = Ipv4Net.tryParse(cidr)!;
    return (net.base, net.last);
  }

  bool _overlapsAny(String cidr) {
    final (a, b) = _range(cidr);
    for (final n in networks.values) {
      for (final c in ((n['IPAM'] as Map)['Config'] as List).cast<Map>()) {
        final (x, y) = _range(c['Subnet'] as String);
        if (a <= y && x <= b) return true;
      }
    }
    return false;
  }

  void _attach(Map<String, Object?> net, String containerId, String? ip) {
    final c = containers[containerId]!;
    final subnet =
        (((net['IPAM'] as Map)['Config'] as List).first as Map)['Subnet']
            as String;
    final taken = endpoints(net['Id'] as String).values.toSet();
    var address = ip;
    if (address == null) {
      final range =
          (((net['IPAM'] as Map)['Config'] as List).first as Map)['IPRange']
              as String?;
      final (base, _) = _range(range ?? subnet);
      for (var h = range == null ? 2 : 0; address == null; h++) {
        final candidate = Ipv4Net.format(base + h);
        if (!taken.contains(candidate) &&
            !(net['Reserved'] as Set? ?? const {}).contains(candidate)) {
          address = candidate;
        }
      }
    }
    (net['Containers'] as Map)[containerId] = {'IPv4Address': address};
    ((c['NetworkSettings'] as Map)['Networks'] as Map)[net['Name']] = {
      'IPAddress': address,
    };
  }

  void _detach(Map<String, Object?> net, String containerId) {
    (net['Containers'] as Map).remove(containerId);
    final c = containers[containerId];
    if (c != null) {
      ((c['NetworkSettings'] as Map)['Networks'] as Map).remove(net['Name']);
    }
  }

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
    final filtersText = request.uri.queryParameters['filters'];
    final wanted = filtersText == null
        ? const <String>[]
        : ((jsonDecode(filtersText) as Map)['label'] as List).cast<String>();
    final volumeFilter = filtersText == null
        ? null
        : ((jsonDecode(filtersText) as Map)['volume'] as List?)?.cast<String>();
    bool usesVolume(Map c) =>
        volumeFilter == null ||
        ((c['Mounts'] as List?) ?? const []).any(
          (m) => m is Map && volumeFilter.contains(m['Source']),
        );
    switch ((request.method, segments.sublist(1))) {
      case ('GET', ['_ping']):
        return reply(200, 'OK');
      case ('GET', ['images', ...final name, 'json']):
        final ref = name.join('/');
        return images.contains(ref)
            ? reply(200, {
                'Id': 'sha256:${'0' * 64}',
                'RepoTags': [ref],
              })
            : reply(404, {'message': 'No such image: $ref'});
      case ('GET', ['containers', 'json']):
        final runningOnly = request.uri.queryParameters['all'] == '0';
        return reply(200, [
          for (final c in containers.values)
            if (_matches((c['Config'] as Map)['Labels'] as Map, wanted) &&
                usesVolume(c) &&
                (!runningOnly || (c['State'] as Map)['Running'] == true))
              {
                'Id': c['Id'],
                'Names': [c['Name']],
                'State': (c['State'] as Map)['Status'],
                'Labels': (c['Config'] as Map)['Labels'],
                'HostConfig': c['HostConfig'],
              },
        ]);
      case ('POST', ['containers', 'create']):
        final name = request.uri.queryParameters['name']!;
        if (_find(name) != null) return reply(409, {'message': 'conflict'});
        final payload = (body as Map).cast<String, Object?>();
        final network = (payload['HostConfig'] as Map)['NetworkMode'] as String;
        final net = _net(network);
        if (net == null) return reply(404, {'message': 'network not found'});
        creates.add(payload);
        final id = 'c${++_next}'.padRight(64, 'f');
        containers[id] =
            _container(
                id,
                name,
                (payload['Labels'] as Map).cast<String, String>(),
                payload['Env'] as List,
                network: network,
              )
              ..['State'] = {'Running': false, 'Status': 'created'}
              ..['Mounts'] = (payload['HostConfig'] as Map)['Mounts'];
        final endpoint =
            ((payload['NetworkingConfig'] as Map)['EndpointsConfig']
                as Map)[network];
        _attach(
          net,
          id,
          ((endpoint as Map?)?['IPAMConfig'] as Map?)?['IPv4Address']
              as String?,
        );
        return reply(201, {'Id': id, 'Warnings': <Object?>[]});
      case ('POST', ['containers', final id, 'start']):
        final c = _find(id);
        if (c == null) return reply(404, {'message': 'no such container'});
        if (failStart) return reply(500, {'message': 'scripted start failure'});
        c['State'] = {
          'Running': true,
          'Status': 'running',
          'Health': {'Status': 'healthy'},
        };
        return reply(204);
      case ('GET', ['containers', final id, 'json']):
        final c = _find(id);
        if (c == null) return reply(404, {'message': 'no such container'});
        final snapshot = jsonDecode(jsonEncode(c));
        await afterContainerInspect?.call(id);
        return reply(200, snapshot);
      case ('DELETE', ['containers', final id]):
        final c = _find(id);
        if (c == null) return reply(404, {'message': 'no such container'});
        for (final n in networks.values) {
          _detach(n, c['Id'] as String);
        }
        containers.remove(c['Id']);
        return reply(204);
      case ('POST', ['volumes', 'create']):
        final payload = (body as Map).cast<String, Object?>();
        volumes[payload['Name'] as String] = {
          'Name': payload['Name'],
          'Driver': payload['Driver'],
          'Options': payload['DriverOpts'],
          'Labels': payload['Labels'],
        };
        return reply(201, volumes[payload['Name']]);
      case ('GET', ['volumes']):
        return reply(200, {
          'Volumes': [
            for (final v in volumes.values)
              if (_matches(v['Labels'] as Map, wanted)) v,
          ],
        });
      case ('GET', ['volumes', final name]):
        final v = volumes[name];
        return v == null
            ? reply(404, {'message': 'no such volume'})
            : reply(200, v);
      case ('DELETE', ['volumes', final name]):
        if (volumes[name] == null) {
          return reply(404, {'message': 'no such volume'});
        }
        if (containers.values.any(
          (c) => ((c['Mounts'] as List?) ?? const []).any(
            (m) => m is Map && m['Source'] == name,
          ),
        )) {
          return reply(409, {'message': 'volume is in use'});
        }
        volumes.remove(name);
        return reply(204);
      case ('GET', ['networks']):
        return reply(200, [
          for (final n in networks.values)
            if (_matches(n['Labels'] as Map, wanted))
              {...n}..remove('Reserved'),
        ]);
      case ('POST', ['networks', 'create']):
        final payload = (body as Map).cast<String, Object?>();
        networkCreates.add(payload);
        final name = payload['Name'] as String;
        if (_net(name) != null) {
          return reply(409, {'message': 'network with name $name exists'});
        }
        final config = ((payload['IPAM'] as Map)['Config'] as List)
            .cast<Map>()
            .single;
        final subnet = config['Subnet'] as String;
        if (_overlapsAny(subnet) || refuseSubnets.contains(subnet)) {
          return reply(403, {
            'message':
                'invalid pool request: Pool overlaps with other one on this '
                'address space',
          });
        }
        final id = 'n${++_next}'.padRight(64, 'e');
        networks[id] = {
          'Id': id,
          'Name': name,
          'Labels': payload['Labels'],
          'Options': payload['Options'],
          'Internal': payload['Internal'],
          'IPAM': {
            'Config': [
              {
                'Subnet': subnet,
                'IPRange': config['IPRange'],
                'Gateway': config['Gateway'],
              },
            ],
          },
          'Reserved': {config['Gateway']},
          'Containers': <String, Object?>{},
        };
        return reply(201, {'Id': id});
      case ('GET', ['networks', final id]):
        final n = _net(id);
        return n == null
            ? reply(404, {'message': 'network not found'})
            : reply(200, {...n}..remove('Reserved'));
      case ('POST', ['networks', final id, 'connect']):
        final n = _net(id);
        final cid = (body as Map)['Container'] as String;
        final c = _find(cid);
        if (n == null || c == null) return reply(404, {'message': 'not found'});
        if ((n['Containers'] as Map).containsKey(c['Id'])) {
          return reply(403, {'message': 'endpoint already exists'});
        }
        final ip =
            ((body['EndpointConfig'] as Map?)?['IPAMConfig']
                    as Map?)?['IPv4Address']
                as String?;
        if (ip != null && endpoints(id).values.contains(ip)) {
          return reply(403, {'message': 'Address already in use'});
        }
        _attach(n, c['Id'] as String, ip);
        return reply(200);
      case ('POST', ['networks', final id, 'disconnect']):
        final n = _net(id);
        if (n == null) return reply(404, {'message': 'network not found'});
        _detach(n, (body as Map)['Container'] as String);
        return reply(200);
      case ('DELETE', ['networks', final id]):
        final n = _net(id);
        if (n == null) return reply(404, {'message': 'network not found'});
        if ((n['Containers'] as Map).isNotEmpty) {
          return reply(403, {'message': 'network has active endpoints'});
        }
        networks.remove(n['Id']);
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
  late String agent;
  late String proxy;
  const key = 'sup-key';

  Map<String, String> compose(String service) => {
    'com.docker.compose.project': 'proj',
    'com.docker.compose.service': service,
  };

  SupervisorConfig config({
    String? statePath,
    bool codexGateway = false,
    String pool = '10.213.0.0/16',
    ExecutorProfiles? profiles,
    DeviceInfo? Function(String)? device,
    DiskWorkspaceConfig? disk,
  }) => SupervisorConfig(
    key: key,
    agentPeers: ['agent_service'],
    proxyPeer: 'agent_sandbox_proxy',
    codexGateway: codexGateway,
    composeProject: 'proj',
    subnetPool: pool,
    dockerSocket: docker.socketPath,
    labelKey: 'dify-sf.test',
    labelValue: 'unit',
    memoryMb: 512,
    cpus: 0.5,
    pidsLimit: 128,
    homeMb: 64,
    workspaceMb: 128,
    statePath: statePath,
    startTimeout: const Duration(seconds: 2),
    profiles: profiles,
    device:
        device ??
        (p) => p == '/dev/dri/renderD128'
            ? (group: 990, sysfs: '/sys/devices/pci0000:00/0000:00:02.0')
            : null,
    disk: disk,
  );

  Future<void> startSupervisor({
    String? statePath,
    bool codexGateway = false,
    String pool = '10.213.0.0/16',
    ExecutorProfiles? profiles,
    DeviceInfo? Function(String)? device,
    DiskWorkspaceConfig? disk,
    DiskWorkspaces Function(DockerClient)? disks,
  }) async {
    supervisor = SandboxSupervisor(
      config(
        statePath: statePath,
        codexGateway: codexGateway,
        pool: pool,
        profiles: profiles,
        device: device,
        disk: disk,
      ),
      disks: disks,
    );
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

  Future<Map<String, Object?>> acquire(String executionKey) async {
    final (s, j) = await call(
      'POST',
      '/v1/sandboxes',
      body: {'execution_key': executionKey},
    );
    if (s != 200 && s != 201) throw StateError('$s ${jsonEncode(j)}');
    return j;
  }

  setUp(() async {
    dir = newDataDir();
    docker = FakeDocker('${dir.path}/d.sock');
    expect(docker.socketPath.length, lessThan(100));
    await docker.start();
    client = http.Client();
    agent = docker.seed('proj-agent_service-1', compose('agent_service'));
    proxy = docker.seed(
      'proj-agent_sandbox_proxy-1',
      compose('agent_sandbox_proxy'),
    );
  });

  tearDown(() async {
    client.close();
    await supervisor.stop();
    await docker.close();
    dir.deleteSync(recursive: true);
  });

  test('create: an internal inhibit_ipv4 network of its own, the fixed '
      'payload, then the proxy and agent attached; nothing else', () async {
    await startSupervisor();
    final a = await acquire('E1');
    expect(a['created'], true);
    final name = supervisor.containerName('E1');
    final hash = SandboxSupervisor.hashKey('E1');

    expect(docker.networkCreates.single, {
      'Name': name,
      'Driver': 'bridge',
      'Internal': true,
      'Attachable': false,
      'EnableIPv6': false,
      'IPAM': {
        'Driver': 'default',
        'Config': [
          {
            'Subnet': '10.213.0.0/28',
            'IPRange': '10.213.0.8/29',
            'Gateway': '10.213.0.1',
          },
        ],
      },
      'Options': {'com.docker.network.bridge.inhibit_ipv4': 'true'},
      'Labels': {'dify-sf.test': 'unit', executionLabel: hash},
    });

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
        'SHELLCTL_LANDLOCK_RO_PATHS=/usr,/bin,/sbin,/lib,/lib64,/etc,/proc,'
            '/opt/dify-agent-tools,/opt/homebrew,/snap,/opt',
        'SHELLCTL_LANDLOCK_RW_DEV_PATHS=/dev/null,/dev/zero,/dev/urandom,'
            '/dev/random,/dev/tty',
        'HTTP_PROXY=http://10.213.0.2:3128',
        'HTTPS_PROXY=http://10.213.0.2:3128',
        'http_proxy=http://10.213.0.2:3128',
        'https_proxy=http://10.213.0.2:3128',
        'NO_PROXY=localhost,127.0.0.1',
        'no_proxy=localhost,127.0.0.1',
      ],
      'Labels': {
        'dify-sf.test': 'unit',
        executionLabel: hash,
        profileLabel: 'default',
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
        'NetworkMode': name,
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
        'Sysctls': {
          'net.ipv6.conf.all.disable_ipv6': '1',
          'net.ipv6.conf.default.disable_ipv6': '1',
        },
        'RestartPolicy': {'Name': 'no'},
        'LogConfig': {
          'Type': 'json-file',
          'Config': {'max-size': '1m', 'max-file': '1'},
        },
      },
      'NetworkingConfig': {
        'EndpointsConfig': {
          name: {
            'IPAMConfig': {'IPv4Address': '10.213.0.3'},
          },
        },
      },
    });
    expect(a['url'], 'http://$name:5004');
    expect(a['gateway'], '10.213.0.1');

    // Order: peers resolved, network created, proxy at .2, container at .3,
    // agent attached, started.
    final mutations = docker.calls.where((c) => !c.startsWith('GET')).toList();
    expect(mutations, [
      'POST /networks/create',
      'POST /networks/$name/connect',
      'POST /containers/create',
      'POST /networks/$name/connect',
      'POST /containers/${a['sandbox_id']}/start',
    ]);
    final connects = [
      for (final r in docker.requests)
        if (r.$2.endsWith('/connect')) r.$3,
    ];
    expect(connects, [
      {
        'Container': proxy,
        'EndpointConfig': {
          'IPAMConfig': {'IPv4Address': '10.213.0.2'},
        },
      },
      {'Container': agent, 'EndpointConfig': <String, Object?>{}},
    ]);
    // Exactly the sandbox, the agent service and the proxy.
    expect(docker.endpoints(name), {
      proxy: '10.213.0.2',
      a['sandbox_id']: '10.213.0.3',
      agent: '10.213.0.8',
    });

    // Idempotent per execution key: same sandbox and token, nothing created.
    final again = await acquire('E1');
    expect(again['sandbox_id'], a['sandbox_id']);
    expect(again['token'], token);
    expect(again['created'], false);
    expect(docker.creates, hasLength(1));
    expect(docker.networkCreates, hasLength(1));

    // A second execution: its own network and subnet.
    final b = await acquire('E2');
    expect(b['token'], isNot(token));
    expect(b['sandbox_id'], isNot(a['sandbox_id']));
    expect(b['gateway'], '10.213.0.17');
    final nameB = supervisor.containerName('E2');
    expect(docker.endpoints(nameB).keys, {proxy, b['sandbox_id'], agent});
    expect(docker.endpoints(name), isNot(contains(b['sandbox_id'])));
  });

  test('subnets: first free /28, existing networks and refused subnets are '
      'skipped; an exhausted pool is 503 and leaves nothing', () async {
    docker.seedNetwork('foreign', subnet: '10.214.0.0/27');
    docker.seedNetwork('v6only');
    await startSupervisor(pool: '10.214.0.0/26');
    docker.refuseSubnets.add('10.214.0.32/28');
    final a = await acquire('A');
    expect(a['gateway'], '10.214.0.49');
    final refused = docker.networkCreates
        .map((n) => ((n['IPAM'] as Map)['Config'] as List).first['Subnet'])
        .toList();
    expect(refused, ['10.214.0.32/28', '10.214.0.48/28']);
    final (s, j) = await call(
      'POST',
      '/v1/sandboxes',
      body: {'execution_key': 'B'},
    );
    expect(s, 503);
    expect(j['error'], 'subnet_pool_exhausted');
    expect(docker.networks.values.map((n) => n['Name']), [
      'foreign',
      'v6only',
      supervisor.containerName('A'),
    ]);
    expect(docker.containers, hasLength(3)); // agent, proxy, sandbox A
  });

  test('delete removes the container, disconnects the peers, then removes '
      'the network; labelled sandboxes only', () async {
    final foreign = docker.seed('someone-else', {'app': 'db'});
    await startSupervisor();
    final a = await acquire('E1');
    final name = supervisor.containerName('E1');
    final (ls, list) = await call('GET', '/v1/sandboxes');
    expect(ls, 200);
    expect((list['sandboxes'] as List).map((s) => (s as Map)['sandbox_id']), [
      a['sandbox_id'],
    ]);
    final (s1, _) = await call('DELETE', '/v1/sandboxes/$foreign');
    expect(s1, 404);
    expect(docker.containers, contains(foreign));
    docker.requests.clear();
    final (s2, d) = await call('DELETE', '/v1/sandboxes/${a['sandbox_id']}');
    expect(s2, 200);
    expect(d['deleted'], true);
    final mutations = docker.calls.where((c) => !c.startsWith('GET')).toList();
    expect(mutations, [
      'DELETE /containers/${a['sandbox_id']}',
      startsWith('POST /networks/'),
      startsWith('POST /networks/'),
      startsWith('DELETE /networks/'),
    ]);
    expect(mutations[1], endsWith('/disconnect'));
    final disconnected = {
      for (final r in docker.requests)
        if (r.$2.endsWith('/disconnect')) (r.$3 as Map)['Container'],
    };
    expect(disconnected, {agent, proxy});
    expect(docker.networks.values.where((n) => n['Name'] == name), isEmpty);
    expect(docker.containers.keys, unorderedEquals([foreign, agent, proxy]));
    final deletes = docker.requests.where((r) => r.$1 == 'DELETE').toList();
    expect(deletes.first.$2, contains('force=1&v=1'));
    final (s3, d3) = await call('DELETE', '/v1/sandboxes/${a['sandbox_id']}');
    expect(s3, 200);
    expect(d3['deleted'], false);
  });

  test('peers come from configuration only: a missing agent is 503 before '
      'anything is created; a recreated peer is attached again', () async {
    await startSupervisor();
    docker.containers.remove(agent);
    final (s, j) = await call(
      'POST',
      '/v1/sandboxes',
      body: {'execution_key': 'E1'},
    );
    expect(s, 503);
    expect(j['error'], 'peer_unavailable');
    expect(docker.networkCreates, isEmpty);
    expect(docker.creates, isEmpty);

    // A container named like the agent but outside the compose project is
    // not a peer.
    docker.seed('agent_service', {'app': 'agent_service'});
    final (s2, _) = await call(
      'POST',
      '/v1/sandboxes',
      body: {'execution_key': 'E1'},
    );
    expect(s2, 503);

    final agent2 = docker.seed(
      'proj-agent_service-2',
      compose('agent_service'),
    );
    final a = await acquire('E1');
    final name = supervisor.containerName('E1');
    expect(docker.endpoints(name).keys, {proxy, a['sandbox_id'], agent2});

    // The agent and the proxy are recreated: the next acquire attaches the
    // new containers, the proxy again at its fixed address.
    docker.containers.remove(agent2);
    docker.containers.remove(proxy);
    final net = docker.networks.values.singleWhere((n) => n['Name'] == name);
    (net['Containers'] as Map)
      ..remove(agent2)
      ..remove(proxy);
    final agent3 = docker.seed(
      'proj-agent_service-3',
      compose('agent_service'),
    );
    final proxy2 = docker.seed(
      'proj-agent_sandbox_proxy-2',
      compose('agent_sandbox_proxy'),
    );
    final again = await acquire('E1');
    expect(again['created'], false);
    expect(docker.endpoints(name), {
      a['sandbox_id']: '10.213.0.3',
      proxy2: '10.213.0.2',
      agent3: '10.213.0.8',
    });
  });

  test(
    'the startup sweep removes unknown labelled containers and unused '
    'labelled networks; known, unlabelled and label-only objects stay',
    () async {
      final statePath = '${dir.path}/state.json';
      final foreign = docker.seed('someone-else', {'dify-sf.test': 'other'});
      // Carries the label but is no sandbox (no execution label), like a
      // compose service labelled the same way.
      final labelOnly = docker.seed('compose-svc', {'dify-sf.test': 'unit'});
      final orphan = docker.seed('orphan', {
        'dify-sf.test': 'unit',
        executionLabel: 'h1',
      });
      final known = docker.seed('known', {
        'dify-sf.test': 'unit',
        executionLabel: 'h2',
      });
      (docker.containers[known]!['HostConfig'] as Map)['NetworkMode'] =
          'known-net';
      docker.seedNetwork(
        'known-net',
        subnet: '10.213.0.0/28',
        labels: {'dify-sf.test': 'unit', executionLabel: 'h2'},
      );
      final orphanNet = docker.seedNetwork(
        'orphan-net',
        subnet: '10.213.0.16/28',
        labels: {'dify-sf.test': 'unit', executionLabel: 'h3'},
      );
      (docker.networks[orphanNet]!['Containers'] as Map)[agent] = {
        'IPv4Address': '10.213.0.20',
      };
      docker.seedNetwork(
        'label-only-net',
        subnet: '10.213.0.32/28',
        labels: {'dify-sf.test': 'unit'},
      );
      File(statePath).writeAsStringSync(
        jsonEncode({
          'sandboxes': {known: 'h2', 'gone': 'h'},
        }),
      );
      await startSupervisor(statePath: statePath);
      expect(
        docker.containers.keys,
        unorderedEquals([foreign, labelOnly, known, agent, proxy]),
      );
      expect(docker.containers, isNot(contains(orphan)));
      expect(docker.networks.values.map((n) => n['Name']), [
        'known-net',
        'label-only-net',
      ]);
      expect(
        docker.requests.where((r) => r.$2.endsWith('/disconnect')).single.$3,
        {'Container': agent, 'Force': true},
      );
      expect(supervisor.knownIds, {known});
      expect(
        (jsonDecode(File(statePath).readAsStringSync()) as Map)['sandboxes'],
        {known: 'h2'},
      );
    },
  );

  test('a stopped sandbox is replaced by a new one on a new network', () async {
    await startSupervisor();
    final a = await acquire('E1');
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
    expect(docker.networkCreates, hasLength(2));
    expect(docker.networks, hasLength(1));
  });

  test('a failed start removes the container and the network', () async {
    await startSupervisor();
    docker.failStart = true;
    final (s, j) = await call(
      'POST',
      '/v1/sandboxes',
      body: {'execution_key': 'E1'},
    );
    expect(s, 502, reason: '$j');
    expect(docker.creates, hasLength(1));
    expect(docker.networkCreates, hasLength(1));
    expect(docker.networks, isEmpty);
    expect(docker.containers.keys, unorderedEquals([agent, proxy]));
    expect(supervisor.knownIds, isEmpty);
  });

  test('names taken by unlabelled objects are never touched', () async {
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
    docker.seedNetwork(supervisor.containerName('E8'), subnet: '10.99.0.0/28');
    final (s2, j2) = await call(
      'POST',
      '/v1/sandboxes',
      body: {'execution_key': 'E8'},
    );
    expect(s2, 409);
    expect(j2['message'], contains('network'));
    expect(docker.networks, hasLength(1));
  });

  test(
    'a request cannot choose the image, network or peers; auth is required',
    () async {
      await startSupervisor();
      for (final extra in ['image', 'network', 'peers']) {
        final (s, j) = await call(
          'POST',
          '/v1/sandboxes',
          body: {'execution_key': 'E1', extra: 'evil'},
        );
        expect(s, 400);
        expect(j['message'], contains(extra));
      }
      final (s2, _) = await call(
        'POST',
        '/v1/sandboxes',
        body: {'execution_key': 'E1'},
        auth: 'wrong',
      );
      expect(s2, 401);
      expect(docker.creates, isEmpty);
      expect(docker.networkCreates, isEmpty);
    },
  );

  test('configuration from the environment', () {
    final base = {
      'SANDBOX_SUPERVISOR_KEY': 'k',
      'SANDBOX_AGENT_PEERS': 'agent_service, other',
    };
    final c = SupervisorConfig.fromEnv({
      ...base,
      'SANDBOX_LABEL': 'a.b=c',
      'SANDBOX_ADDRESS': 'ip',
      'SANDBOX_PROXY_PEER': 'agent_sandbox_proxy',
      'SANDBOX_COMPOSE_PROJECT': 'p',
      'SANDBOX_SUBNET_POOL': '172.30.64.0/20',
    });
    expect(c.labelKey, 'a.b');
    expect(c.labelValue, 'c');
    expect(c.addressByIp, isTrue);
    expect(c.memoryMb, 1024);
    expect(c.agentPeers, ['agent_service', 'other']);
    expect(c.proxyPeer, 'agent_sandbox_proxy');
    expect(c.proxyPort, 3128);
    expect(c.composeProject, 'p');
    expect('${c.subnetPool}', '172.30.64.0/20');
    expect('${SupervisorConfig.fromEnv(base).subnetPool}', '10.213.0.0/16');
    for (final bad in <Map<String, String>>[
      {'SANDBOX_SUPERVISOR_KEY': 'k'},
      {...base, 'SANDBOX_MEMORY_MB': '256'},
      {...base, 'SANDBOX_SUBNET_POOL': '10.213.0.0/29'},
      {...base, 'SANDBOX_SUBNET_POOL': '8.8.0.0/16'},
      {...base, 'SANDBOX_SUBNET_POOL': 'fd00::/64'},
      {...base, 'SANDBOX_NETWORK': 'shared'},
      {...base, 'SANDBOX_PROXY_URL': 'http://proxy:3128'},
    ]) {
      expect(
        () => SupervisorConfig.fromEnv(bad),
        throwsA(isA<SupervisorConfigError>()),
        reason: '$bad',
      );
    }
  });

  group('executor profiles', () {
    const blenderImage =
        'dify-sf/sandbox-colvalley-blender@sha256:'
        '2222222222222222222222222222222222222222222222222222222222222222';
    const defaultImage =
        'langgenius/dify-agent-local-sandbox@sha256:'
        'f4d404c9dcdf80bd72f65e84c3f2bbd1f3404fd4b363db837176da8aaf771b1d';
    Map<String, Object?> file({String egress = 'none'}) => {
      'version': 1,
      'profiles': {
        'default': {'image': defaultImage},
        'colvalley-blender': {
          'description': 'Blender',
          'image': blenderImage,
          'mounts': [
            {'source': '/srv/cv3d-2d97747', 'target': '/opt/colvalley-3d'},
          ],
          'network': {'egress': egress},
          'devices': ['/dev/dri/renderD128'],
          'limits': {
            'cpus': 4,
            'memory_mb': 6144,
            'pids': 1024,
            'workspace_mb': 1536,
            'home_mb': 512,
            'timeout_seconds_max': 10800,
          },
          'env': {'BLENDER': '/opt/blender/blender'},
        },
      },
    };

    Future<Map<String, Object?>> acquireWith(String key, String profile) async {
      final (s, j) = await call(
        'POST',
        '/v1/sandboxes',
        body: {'execution_key': key, 'profile': profile},
      );
      if (s != 200 && s != 201) throw StateError('$s ${jsonEncode(j)}');
      return j;
    }

    test('the profile sets image, read-only binds, render node and group, '
        'limits and tmpfs sizes; egress none attaches no proxy and sets no '
        'proxy variables', () async {
      docker.images.addAll([defaultImage, blenderImage]);
      await startSupervisor(profiles: ExecutorProfiles.parse(file()));
      final a = await acquireWith('E1', 'colvalley-blender');
      expect(a['profile'], 'colvalley-blender');
      expect(a['created'], true);
      final payload = docker.creates.single;
      final hc = payload['HostConfig'] as Map;
      expect(payload['Image'], blenderImage);
      expect(
        (payload['Env'] as List).where(
          (e) => '$e'.toLowerCase().contains('proxy'),
        ),
        isEmpty,
      );
      expect(payload['Env'], [
        startsWith('SHELLCTL_AUTH_TOKEN='),
        'SHELLCTL_LANDLOCK_RO_PATHS=/usr,/bin,/sbin,/lib,/lib64,/etc,/proc,'
            '/opt/dify-agent-tools,/opt/homebrew,/snap,/opt,/dev/dri,'
            '/sys/dev/char,/sys/devices/pci0000:00/0000:00:02.0',
        'SHELLCTL_LANDLOCK_RW_DEV_PATHS=/dev/null,/dev/zero,/dev/urandom,'
            '/dev/random,/dev/tty,/dev/dri/renderD128',
      ]);
      // Profile env goes to jobs through the agent service, not the container.
      expect(jsonEncode(payload), isNot(contains('BLENDER')));
      expect((payload['Labels'] as Map)[profileLabel], 'colvalley-blender');
      expect(hc['Memory'], 6144 * 1024 * 1024);
      expect(hc['MemorySwap'], 6144 * 1024 * 1024);
      expect(hc['NanoCpus'], 4000000000);
      expect(hc['PidsLimit'], 1024);
      expect(hc['Tmpfs'], {
        '/home/dify':
            'rw,exec,nosuid,nodev,size=512m,mode=0700,uid=1000,gid=1000',
        '/workspace':
            'rw,exec,nosuid,nodev,size=1536m,mode=0700,uid=1000,gid=1000',
      });
      expect(hc['Binds'], isEmpty);
      expect(hc['Mounts'], [
        {
          'Type': 'bind',
          'Source': '/srv/cv3d-2d97747',
          'Target': '/opt/colvalley-3d',
          'ReadOnly': true,
          'BindOptions': {'Propagation': 'rprivate'},
        },
      ]);
      expect(hc['Devices'], [
        {
          'PathOnHost': '/dev/dri/renderD128',
          'PathInContainer': '/dev/dri/renderD128',
          'CgroupPermissions': 'rw',
        },
      ]);
      expect(hc['GroupAdd'], ['990']);
      expect(hc['ReadonlyRootfs'], true);
      expect(hc['CapDrop'], ['ALL']);
      expect(hc['Privileged'], false);
      final name = supervisor.containerName('E1');
      // Exactly the sandbox and the agent service: no proxy endpoint.
      expect(docker.endpoints(name).keys.toSet(), {a['sandbox_id'], agent});
      expect(
        docker.calls.where((c) => c.startsWith('POST /networks/')).toList(),
        ['POST /networks/create', 'POST /networks/$name/connect'],
      );
      // Idempotent, and the proxy is not attached on a later acquire either.
      final again = await acquireWith('E1', 'colvalley-blender');
      expect(again['sandbox_id'], a['sandbox_id']);
      expect(again['created'], false);
      expect(docker.endpoints(name).keys, isNot(contains(proxy)));

      // The default profile in the same supervisor: its image, the
      // configuration's limits, the proxy, no binds or devices.
      final d = await acquire('E2');
      expect(d['profile'], 'default');
      final dp = docker.creates.last;
      final dhc = dp['HostConfig'] as Map;
      expect(dp['Image'], defaultImage);
      expect(dhc['Memory'], 512 * 1024 * 1024);
      expect(dhc['Mounts'], isEmpty);
      expect(dhc.containsKey('Devices'), isFalse);
      expect(dhc.containsKey('GroupAdd'), isFalse);
      expect(dp['Env'], contains('HTTPS_PROXY=http://10.213.0.18:3128'));
      expect(
        docker.endpoints(supervisor.containerName('E2')).keys,
        contains(proxy),
      );

      final (_, list) = await call('GET', '/v1/sandboxes');
      expect(
        {
          for (final x in (list['sandboxes'] as List).cast<Map>())
            x['sandbox_id']: x['profile'],
        },
        {a['sandbox_id']: 'colvalley-blender', d['sandbox_id']: 'default'},
      );
    });

    test('egress allowlist keeps the proxy', () async {
      docker.images.addAll([defaultImage, blenderImage]);
      await startSupervisor(
        profiles: ExecutorProfiles.parse(file(egress: 'allowlist')),
      );
      await acquireWith('E1', 'colvalley-blender');
      expect(
        docker.creates.single['Env'],
        contains('HTTPS_PROXY=http://10.213.0.2:3128'),
      );
      expect(
        docker.endpoints(supervisor.containerName('E1')).keys,
        contains(proxy),
      );
    });

    test(
      'the dedicated Codex endpoint is granted only to allowlist profiles',
      () async {
        docker.images.addAll([defaultImage, blenderImage]);
        final configured = file(egress: 'allowlist');
        (configured['profiles'] as Map)['default'] = {
          'image': defaultImage,
          'network': {'egress': 'none'},
        };
        await startSupervisor(
          profiles: ExecutorProfiles.parse(configured),
          codexGateway: true,
        );
        final allowed = await acquireWith('codex-fixture', 'colvalley-blender');
        expect(
          allowed['codex_gateway_url'],
          'http://10.213.0.2:3128/inner/agent/codex/v1',
        );
        final isolated = await acquireWith('default-fixture', 'default');
        expect(isolated.containsKey('codex_gateway_url'), false);
        expect(
          docker.endpoints(supervisor.containerName('default-fixture')).keys,
          isNot(contains(proxy)),
        );
      },
    );

    test(
      'a key keeps its profile: another profile is 409; an unknown one '
      'and other fields 400; a container without the label is default',
      () async {
        docker.images.addAll([defaultImage, blenderImage]);
        await startSupervisor(profiles: ExecutorProfiles.parse(file()));
        await acquireWith('E1', 'colvalley-blender');
        var (s, j) = await call(
          'POST',
          '/v1/sandboxes',
          body: {'execution_key': 'E1', 'profile': 'default'},
        );
        expect((s, j['error']), (409, 'profile_conflict'));
        (s, j) = await call(
          'POST',
          '/v1/sandboxes',
          body: {'execution_key': 'E1'},
        );
        expect((s, j['error']), (409, 'profile_conflict'));
        (s, j) = await call(
          'POST',
          '/v1/sandboxes',
          body: {'execution_key': 'E9', 'profile': 'nope'},
        );
        expect((s, j['error']), (400, 'unknown_profile'));
        (s, j) = await call(
          'POST',
          '/v1/sandboxes',
          body: {'execution_key': 'E9', 'profile': 7},
        );
        expect(s, 400);
        (s, j) = await call(
          'POST',
          '/v1/sandboxes',
          body: {
            'execution_key': 'E9',
            'profile': 'default',
            'image': blenderImage,
          },
        );
        expect(s, 400);
        expect(docker.creates, hasLength(1));
        expect(
          SandboxSupervisor.profileOf({
            'Config': {'Labels': <String, String>{}},
          }),
          'default',
        );
      },
    );

    test('a missing image or render node is 503 before anything is created; '
        'GET /v1/profiles reports both with the digests', () async {
      docker.images.add(defaultImage);
      var present = true;
      final profiles = ExecutorProfiles.parse(file());
      await startSupervisor(
        profiles: profiles,
        device: (_) => present ? (group: 990, sysfs: '/sys/devices/x') : null,
      );
      var (s, j) = await call(
        'POST',
        '/v1/sandboxes',
        body: {'execution_key': 'E1', 'profile': 'colvalley-blender'},
      );
      expect((s, j['error']), (503, 'image_missing'));
      expect(docker.networkCreates, isEmpty);
      expect(docker.creates, isEmpty);
      (s, j) = await call('GET', '/v1/profiles');
      expect(s, 200);
      expect(j, {
        'profiles': {
          'default': {'status': 'ok', 'digest': profiles['default']!.digest},
          'colvalley-blender': {
            'status': 'image_missing',
            'digest': profiles['colvalley-blender']!.digest,
          },
        },
      });
      docker.images.add(blenderImage);
      present = false;
      (s, j) = await call(
        'POST',
        '/v1/sandboxes',
        body: {'execution_key': 'E1', 'profile': 'colvalley-blender'},
      );
      expect((s, j['error']), (503, 'device_missing'));
      expect(
        ((await call('GET', '/v1/profiles')).$2['profiles']
            as Map)['colvalley-blender']['status'],
        'device_missing',
      );
      expect(docker.networkCreates, isEmpty);
      present = true;
      await acquireWith('E1', 'colvalley-blender');
    });

    test('profiles from AGENT_EXECUTOR_PROFILES; a bad file or limits that '
        'do not fit stop the supervisor', () {
      final dir = newDataDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/profiles.json')
        ..writeAsStringSync(jsonEncode(file()));
      final base = {
        'SANDBOX_SUPERVISOR_KEY': 'k',
        'SANDBOX_AGENT_PEERS': 'agent_service',
        'AGENT_EXECUTOR_PROFILES': f.path,
      };
      final c = SupervisorConfig.fromEnv(base);
      expect(c.profiles.names, ['default', 'colvalley-blender']);
      expect(c.imageOf(c.profiles['default']!), defaultImage);
      expect(c.limitsOf(c.profiles['default']!).memoryMb, 1024);
      expect(
        SupervisorConfig.fromEnv({...base}..remove('AGENT_EXECUTOR_PROFILES'))
            .profiles['default']!
            .image,
        isNull,
      );
      // The profile's tmpfs sizes do not fit the default memory.
      final tight = {
        ...file(),
        'profiles': {
          'default': {
            'image': defaultImage,
            'limits': {'workspace_mb': 900},
          },
        },
      };
      f.writeAsStringSync(jsonEncode(tight));
      expect(
        () => SupervisorConfig.fromEnv(base),
        throwsA(
          isA<SupervisorConfigError>().having(
            (e) => e.message,
            'message',
            contains('must be below memory_mb'),
          ),
        ),
      );
      f.writeAsStringSync(
        '{"version": 1, "profiles": {"default": {"image": "x:1"}}}',
      );
      expect(
        () => SupervisorConfig.fromEnv(base),
        throwsA(isA<SupervisorConfigError>()),
      );
      // The state file may not be mounted.
      f.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'profiles': {
            'default': {
              'image': defaultImage,
              'mounts': [
                {'source': '/srv/state', 'target': '/opt/state'},
              ],
            },
          },
        }),
      );
      expect(
        () => SupervisorConfig.fromEnv({
          ...base,
          'SANDBOX_STATE_FILE': '/srv/state/sandboxes.json',
        }),
        throwsA(isA<SupervisorConfigError>()),
      );
    });
  });

  group('disk workspaces', () {
    const image =
        'langgenius/dify-agent-local-sandbox@sha256:'
        'f4d404c9dcdf80bd72f65e84c3f2bbd1f3404fd4b363db837176da8aaf771b1d';
    const tool =
        'example/workspace-tools@sha256:'
        '3333333333333333333333333333333333333333333333333333333333333333';
    late FakeLoop loop;
    late String root;
    var boot = 'boot-1';
    final logs = <String>[];

    final profiles = ExecutorProfiles.parse({
      'version': 1,
      'profiles': {
        'default': {'image': image},
        'modelling': {
          'image': image,
          'network': {'egress': 'none'},
          'workspace': {'backing': 'disk'},
          // The deployment target: memory above the tmpfs home only.
          'limits': {'memory_mb': 2048, 'home_mb': 512, 'workspace_mb': 1536},
        },
      },
    });

    DiskWorkspaceConfig diskConfig({
      int budgetMb = 4096,
      List<String> devices = const ['/dev/loop13'],
    }) => DiskWorkspaceConfig(
      root: root,
      hostRoot: '/srv/dify-sf/workspaces',
      toolImage: tool,
      devices: devices,
      budgetMb: budgetMb,
      minFreeMb: 1024,
    );

    Future<void> start({
      int budgetMb = 4096,
      String? statePath,
      List<String> devices = const ['/dev/loop13'],
    }) async {
      final d = diskConfig(budgetMb: budgetMb, devices: devices);
      await startSupervisor(
        statePath: statePath,
        profiles: profiles,
        disk: d,
        disks: (docker) => DiskWorkspaces(
          d,
          docker: docker,
          helper: loop,
          labelKey: 'dify-sf.test',
          labelValue: 'unit',
          namePrefix: 'dify-sf-sandbox-',
          freeBytes: (_) async => 1 << 40,
          bootId: () => boot,
          log: logs.add,
        ),
      );
    }

    /// The workspace directories under the disk root (not the placeholders).
    List<String> leaseDirs() => [
      for (final e in Directory(root).listSync())
        if (e.uri.pathSegments.where((p) => p.isNotEmpty).last != 'hold')
          e.path,
    ];

    Future<(int, Map<String, Object?>)> acquireDisk(String key) => call(
      'POST',
      '/v1/sandboxes',
      body: {'execution_key': key, 'profile': 'modelling'},
    );

    setUp(() {
      docker.images.addAll([image, tool]);
      loop = FakeLoop();
      logs.clear();
      root = (Directory('${dir.path}/ws')..createSync()).path;
      expect(Process.runSync('chmod', ['700', root]).exitCode, 0);
      boot = 'boot-1';
    });

    test(
      'disk root rejects access by other host users before Docker calls',
      () async {
        expect(Process.runSync('chmod', ['755', root]).exitCode, 0);
        final before = docker.requests.length;
        await expectLater(start(), throwsA(isA<SupervisorConfigError>()));
        expect(docker.requests, hasLength(before));
      },
    );

    test('disk root rejects a symbolic link before Docker calls', () async {
      final link = Link('${dir.path}/ws-link')..createSync(root);
      root = link.path;
      final before = docker.requests.length;
      await expectLater(start(), throwsA(isA<SupervisorConfigError>()));
      expect(docker.requests, hasLength(before));
    });

    test('late delete with a stale inspection keeps the replacement network '
        'and disk workspace', () async {
      await start();
      final (_, first) = await acquireDisk('E1');
      final old = first['sandbox_id'] as String;
      (docker.containers[old]!['State'] as Map)['Running'] = false;
      final captured = Completer<void>();
      final release = Completer<void>();
      docker.afterContainerInspect = (id) async {
        if (id != old) return;
        docker.afterContainerInspect = null;
        captured.complete();
        await release.future;
      };
      final deleting = call('DELETE', '/v1/sandboxes/$old');
      await captured.future.timeout(const Duration(seconds: 2));
      late Map<String, Object?> replacement;
      try {
        final (status, value) = await acquireDisk('E1');
        expect(status, 201);
        replacement = value;
      } finally {
        release.complete();
      }
      expect((await deleting).$1, 200);
      final current = replacement['sandbox_id'] as String;
      expect(docker.containers.containsKey(current), isTrue);
      expect(
        docker.networks.values.any(
          (n) => (n['Containers'] as Map).containsKey(current),
        ),
        isTrue,
      );
      expect(docker.volumes, hasLength(1));
      expect(loop.bound, hasLength(1));
      expect((await acquireDisk('E1')).$2['sandbox_id'], current);
    });

    test(
      'a missing attached image keeps the lease and device for recovery',
      () async {
        await start();
        final (_, value) = await acquireDisk('E1');
        final disks = supervisor.disks!;
        final lease = disks.leases().single;
        final bound = Map.of(loop.bound);
        File('$root/${lease.hash}/workspace.img').deleteSync();
        expect(
          (await call('DELETE', '/v1/sandboxes/${value['sandbox_id']}')).$1,
          200,
        );
        expect(disks.leases().single.state, 'conflict');
        expect(loop.bound, bound);
        expect(docker.volumes, hasLength(1));
        expect(File('$root/${lease.hash}/lease.json').existsSync(), isTrue);
      },
    );

    test('the volume replaces the /workspace tmpfs, survives a replaced '
        'container and goes with the sandbox', () async {
      await start();
      final (s1, a) = await acquireDisk('E1');
      expect(s1, 201);
      expect(a['workspace'], 'disk');
      expect(a['workspace_kept_from'], isEmpty);
      final host = docker.creates.last['HostConfig'] as Map;
      expect((host['Tmpfs'] as Map).keys, ['/home/dify']);
      expect(host['Memory'], 2048 * 1024 * 1024);
      final volume = (host['Mounts'] as List).cast<Map>().single;
      expect(volume['Type'], 'volume');
      expect(volume['Target'], '/workspace');
      final v = docker.volumes[volume['Source']]!;
      expect(v['Options'], {
        'type': 'ext4',
        'device': '/dev/loop13',
        'o': 'rw,nosuid,nodev',
      });
      expect((v['Labels'] as Map)['dify-sf.sandbox.workspace'], hasLength(64));
      // At start the idle pool device was created (if gone) and held.
      expect(loop.ops, [
        'create /dev/loop13',
        'hold /dev/loop13',
        'prepare /dev/loop13',
      ]);
      expect(loop.held, isEmpty);
      expect(loop.args.single, [
        '${1536 * 1024 * 1024}',
        '${1024 * 1024 * 1024}',
        '1000',
        '1000',
      ]);

      // Stopped: replaced, the workspace kept after re-verifying the device.
      final first = a['sandbox_id'] as String;
      (docker.containers[first]!['State'] as Map)['Running'] = false;
      final (s2, b) = await acquireDisk('E1');
      expect(s2, 201);
      expect(b['sandbox_id'], isNot(first));
      expect(b['workspace_kept_from'], [first]);
      expect(loop.ops.last, 'attach /dev/loop13');
      expect(docker.volumes.keys, [volume['Source']]);

      // Removing the old ID again keeps the live sandbox's workspace.
      expect((await call('DELETE', '/v1/sandboxes/$first')).$1, 200);
      expect(docker.volumes, hasLength(1));

      final (s3, _) = await call('DELETE', '/v1/sandboxes/${b['sandbox_id']}');
      expect(s3, 200);
      expect(docker.volumes, isEmpty);
      expect(loop.ops.last, 'detach /dev/loop13');
      expect(loop.bound, isEmpty);
      expect(loop.held, {'/dev/loop13'});
      expect(leaseDirs(), isEmpty);
    });

    test(
      'an exhausted budget or a busy pool is 503 before anything is '
      'created; a device bound by someone else is never pre-empted',
      () async {
        await start(budgetMb: 3000);
        final (s1, a) = await acquireDisk('E1');
        expect(s1, 201);
        final networks = docker.networks.length;
        final (s2, j2) = await acquireDisk('E2');
        expect((s2, j2['error']), (503, 'disk_budget_exceeded'));
        expect(docker.networks, hasLength(networks));
        expect(leaseDirs(), hasLength(1));

        expect(
          (await call('DELETE', '/v1/sandboxes/${a['sandbox_id']}')).$1,
          200,
        );
        loop.bound['/dev/loop13'] = (dev: 1, ino: 2);
        final (s3, j3) = await acquireDisk('E3');
        expect((s3, j3['error']), (503, 'disk_pool_busy'));
        expect(loop.bound, {'/dev/loop13': (dev: 1, ino: 2)});
        expect(leaseDirs(), isEmpty);
        expect(docker.volumes, isEmpty);
        expect(docker.containers.keys, unorderedEquals([agent, proxy]));
      },
    );

    test('a workspace whose device holds another file in the same boot is '
        'not reused or detached; after a reboot it is re-attached', () async {
      await start();
      final (_, a) = await acquireDisk('E1');
      final first = a['sandbox_id'] as String;
      final own = loop.bound['/dev/loop13']!;
      (docker.containers[first]!['State'] as Map)['Running'] = false;

      // A reboot dropped the binding: re-attached, the files are kept.
      loop.bound.clear();
      loop.held.clear();
      boot = 'boot-2';
      final (s1, b) = await acquireDisk('E1');
      expect(s1, 201);
      expect(b['workspace_kept_from'], [first]);
      expect(loop.bound['/dev/loop13'], own);

      // Same boot, the device now holds another file: stop.
      (docker.containers[b['sandbox_id']]!['State'] as Map)['Running'] = false;
      loop.bound['/dev/loop13'] = (dev: 9, ino: 9);
      final (s2, j) = await acquireDisk('E1');
      expect((s2, j['error']), (503, 'disk_workspace_conflict'));
      expect(loop.bound['/dev/loop13'], (dev: 9, ino: 9));
      expect(supervisor.disks!.leases().single.state, 'conflict');
      expect(leaseDirs(), hasLength(1));
    });

    test('restart: an interrupted creation is released, a paused workspace '
        'without a sandbox stays', () async {
      final state = '${dir.path}/state.json';
      await start(statePath: state);
      final (_, a) = await acquireDisk('E1');
      // E1's container is gone (e.g. replaced and the supervisor died).
      docker.containers.remove(a['sandbox_id']);
      final disks = supervisor.disks!;
      final paused = disks.leases().single.hash;
      // A second execution crashed after the helper bound its image.
      final hash = 'a' * 64;
      Directory('$root/$hash').createSync();
      File('$root/$hash/workspace.img').writeAsStringSync('x');
      final id = (await DiskWorkspaces.statIdentity(
        '$root/$hash/workspace.img',
      ))!;
      final lease = DiskLease(
        hash: hash,
        state: 'preparing',
        sizeMb: 64,
        device: '/dev/loop14',
        volume: 'v',
        bootId: boot,
        dev: id.dev,
        ino: id.ino,
      );
      File('$root/$hash/lease.json')
          .writeAsStringSync(jsonEncode(lease.toJson()));
      loop.bound['/dev/loop14'] = id;
      await supervisor.stop();

      await start(statePath: state);
      expect(loop.bound.keys, ['/dev/loop13']);
      expect(Directory('$root/$hash').existsSync(), isFalse);
      expect(supervisor.disks!.leases().single.hash, paused);
      expect(supervisor.disks!.leases().single.state, 'ready');
      // The paused execution resumes on its workspace.
      final (s, b) = await acquireDisk('E1');
      expect(s, 201);
      expect(b['workspace_kept_from'], [a['sandbox_id']]);
    });

    test('idle pool devices stay bound to their placeholders; a device '
        'taken while swapping makes the next one be tried', () async {
      await start(devices: ['/dev/loop200', '/dev/loop201']);
      expect(loop.held, {'/dev/loop200', '/dev/loop201'});
      final holds = Directory('$root/hold').listSync().map((e) => e.path);
      expect(
        holds.map((p) => p.split('/').last),
        unorderedEquals(['loop200.img', 'loop201.img']),
      );
      expect(File('$root/hold/loop200.img').lengthSync(), 4096);
      expect(
        Process.runSync('stat', ['-c', '%a', '$root/hold']).stdout,
        '700\n',
      );
      expect(
        Process.runSync('stat', ['-c', '%a', '$root/hold/loop200.img']).stdout,
        '644\n',
      );

      // snapd binds loop200 in the moment between clear and bind.
      loop.onSwap = (d) {
        if (d == '/dev/loop200') {
          loop.foreign[d] = '/var/lib/snapd/snaps/example_1.snap';
        }
      };
      final (s1, a) = await acquireDisk('E1');
      expect(s1, 201, reason: '$a');
      expect(loop.bound.keys, ['/dev/loop201']);
      // The image was written on loop200: loop201 attaches it.
      expect(
        loop.ops.where(
          (o) => o.startsWith('prepare') || o.startsWith('attach'),
        ),
        ['prepare /dev/loop200', 'attach /dev/loop201'],
      );
      expect(loop.held, isEmpty);
      expect(
        logs,
        contains(
          'pool device /dev/loop200 was taken while swapping its placeholder '
          '(/var/lib/snapd/snaps/example_1.snap)',
        ),
      );
      expect(
        (await call('DELETE', '/v1/sandboxes/${a['sandbox_id']}')).$1,
        200,
      );
      expect(loop.held, {'/dev/loop201'});
    });

    test('after a reboot the pool devices are created before any lease is '
        'released or resumed', () async {
      final state = '${dir.path}/state.json';
      await start(statePath: state);
      final (_, a) = await acquireDisk('E1');
      docker.containers.remove(a['sandbox_id']);
      final paused = supervisor.disks!.leases().single.hash;
      // An interrupted creation on the second device.
      final hash = 'b' * 64;
      Directory('$root/$hash').createSync();
      File('$root/$hash/workspace.img').writeAsStringSync('x');
      final id = (await DiskWorkspaces.statIdentity(
        '$root/$hash/workspace.img',
      ))!;
      File('$root/$hash/lease.json').writeAsStringSync(
        jsonEncode(
          DiskLease(
            hash: hash,
            state: 'preparing',
            sizeMb: 64,
            device: '/dev/loop14',
            volume: 'v',
            bootId: boot,
            dev: id.dev,
            ino: id.ino,
          ).toJson(),
        ),
      );
      await supervisor.stop();

      // Reboot: no bindings, no device nodes above the preallocated ones.
      loop.bound.clear();
      loop.held.clear();
      loop.missing.addAll(['/dev/loop13', '/dev/loop14']);
      boot = 'boot-2';
      loop.ops.clear();
      await start(statePath: state, devices: ['/dev/loop13', '/dev/loop14']);
      expect(loop.ops.take(2), ['create /dev/loop13', 'create /dev/loop14']);
      expect(loop.missing, isEmpty);
      expect(Directory('$root/$hash').existsSync(), isFalse);
      expect(logs.where((l) => l.contains('not released')), isEmpty);
      // loop13 belongs to the paused execution's lease: not held.
      expect(loop.held, {'/dev/loop14'});
      // The paused execution resumes on its workspace.
      expect(supervisor.disks!.leases().single.hash, paused);
      final (s, b) = await acquireDisk('E1');
      expect(s, 201, reason: '$b');
      expect(b['workspace_kept_from'], [a['sandbox_id']]);
    });

    test('a pool device bound by something else at start is logged, never '
        'cleared, and its holder is named in disk_pool_busy', () async {
      loop.foreign['/dev/loop13'] = '/var/lib/snapd/snaps/example_1.snap';
      await start();
      expect(loop.held, isEmpty);
      expect(
        logs,
        contains(
          'pool device /dev/loop13 is not held: bound to '
          '/var/lib/snapd/snaps/example_1.snap (other)',
        ),
      );
      final (s, j) = await acquireDisk('E1');
      expect((s, j['error']), (503, 'disk_pool_busy'));
      expect(j['message'], contains('/var/lib/snapd/snaps/example_1.snap'));
      expect(leaseDirs(), isEmpty);

      // Freed again: the next start holds it; unholdPool gives it back.
      loop.foreign.clear();
      await supervisor.stop();
      await start();
      expect(loop.held, {'/dev/loop13'});
      await supervisor.disks!.unholdPool();
      expect(loop.held, isEmpty);
      expect(loop.ops.last, 'unhold /dev/loop13');
    });

    Future<(int, Map<String, Object?>)> retained(
      String execution,
      String workspace,
    ) => call(
      'POST',
      '/v1/sandboxes',
      body: {
        'execution_key': execution,
        'profile': 'modelling',
        'workspace_key': workspace,
      },
    );

    test('retained workspace parks, frees the only slot and resumes across restart', () async {
      final state = '${dir.path}/state.json';
      await start(statePath: state);
      final (status1, first) = await retained('round-1', 'scope-A');
      expect(status1, 201, reason: '$first');
      final workspace = first['workspace'] as Map;
      final hash = workspace['id'] as String;
      expect(workspace, {'retained': true, 'reused': false, 'id': hash});
      final file = File('$root/$hash/workspace.img');
      file.writeAsStringSync('retained payload');
      expect(
        (await retained('competing', 'scope-A')).$2['error'],
        'workspace_in_use',
      );
      expect(
        (await call('DELETE', '/v1/workspaces/$hash')).$2['error'],
        'workspace_in_use',
      );
      final released = await call(
        'DELETE',
        '/v1/sandboxes/${first['sandbox_id']}',
      );
      expect(released.$2['workspace'], 'parked');
      expect(supervisor.disks!.read(hash)!.state, 'parked');
      expect(loop.bound, isEmpty);
      expect(loop.held, {'/dev/loop13'});
      expect(docker.volumes, isEmpty);
      final (_, other) = await acquireDisk('other-workflow');
      // Final cleanup of a parked workspace must not detach another owner.
      final bound = Map.of(loop.bound);
      expect(
        (await call('DELETE', '/v1/sandboxes/${first['sandbox_id']}')).$1,
        200,
      );
      expect(loop.bound, bound);
      expect(file.readAsStringSync(), 'retained payload');
      await call('DELETE', '/v1/sandboxes/${other['sandbox_id']}');
      await supervisor.stop();
      await start(statePath: state);
      final (status, second) = await retained('round-2', 'scope-A');
      expect(status, 201);
      expect(second['workspace'], {
        'retained': true,
        'reused': true,
        'id': hash,
      });
      expect(file.readAsStringSync(), 'retained payload');
      expect(loop.held, isEmpty);
      final attached = Map.of(loop.bound);
      await call('DELETE', '/v1/sandboxes/${first['sandbox_id']}');
      expect(loop.bound, attached);
      expect(file.existsSync(), isTrue);
      await call('DELETE', '/v1/sandboxes/${second['sandbox_id']}');
      expect(
        (await call('DELETE', '/v1/workspaces/$hash')).$2['deleted'],
        isTrue,
      );
      expect(file.existsSync(), isFalse);
      expect(
        (await call('DELETE', '/v1/workspaces/$hash')).$2['deleted'],
        isFalse,
      );
    });

    test('parked final cleanup cannot detach another workflow and scope cannot change', () async {
      await start();
      final (status1, a) = await retained('r1', 'A');
      expect(status1, 201, reason: '$a');
      final hash = (a['workspace'] as Map)['id'];
      expect((await retained('r1', 'B')).$2['error'], 'workspace_conflict');
      await call('DELETE', '/v1/sandboxes/${a['sandbox_id']}');
      final (_, b) = await retained('r2', 'B');
      final bound = Map.of(loop.bound);
      await call('DELETE', '/v1/workspaces/$hash');
      expect(loop.bound, bound);
      expect(
        supervisor.disks!.leases().single.hash,
        (b['workspace'] as Map)['id'],
      );
    });

    test(
      'retained startup failure parks an indexed disk for terminal cleanup',
      () async {
        await start();
        docker.failStart = true;
        final (status, _) = await retained('failed-round', 'scope-failed');
        expect(status, 502);
        final hash = SandboxSupervisor.hashKey('retained:scope-failed');
        expect(supervisor.disks!.read(hash)!.state, 'parked');
        expect(loop.bound, isEmpty);
        expect(
          docker.containers.values.where(
            (c) => ((c['Config'] as Map)['Labels'] as Map).containsKey(
              'dify-sf.sandbox.execution',
            ),
          ),
          isEmpty,
        );
        expect(
          (await call('DELETE', '/v1/workspaces/$hash')).$2['deleted'],
          isTrue,
        );
        expect(supervisor.disks!.leases(), isEmpty);
      },
    );

    test(
      'retained workspace rejects tmpfs and malformed keys without allocating',
      () async {
        await start();
        final a = await call(
          'POST',
          '/v1/sandboxes',
          body: {
            'execution_key': 'a',
            'profile': 'default',
            'workspace_key': 'A',
          },
        );
        expect(a.$1, 400);
        expect(
          (await call(
            'POST',
            '/v1/sandboxes',
            body: {'execution_key': 'a', 'workspace_key': 42},
          )).$1,
          400,
        );
        expect(supervisor.disks!.leases(), isEmpty);
        expect(docker.creates, isEmpty);
      },
    );

    test('configuration: disk profiles need SANDBOX_DISK_*; only tmpfs '
        'directories count against memory', () {
      SupervisorConfig make(DiskWorkspaceConfig? d) => SupervisorConfig(
        key: 'k',
        agentPeers: ['a'],
        profiles: profiles,
        disk: d,
      );
      root = '/srv/ws';
      expect(make(diskConfig()).disk!.devices, ['/dev/loop13']);
      expect(
        () => make(null),
        throwsA(
          isA<SupervisorConfigError>().having(
            (e) => e.message,
            'message',
            contains('SANDBOX_DISK_ROOT'),
          ),
        ),
      );
      expect(
        () => make(diskConfig(budgetMb: 1024)),
        throwsA(isA<SupervisorConfigError>()),
      );
      final env = {
        'SANDBOX_SUPERVISOR_KEY': 'k',
        'SANDBOX_AGENT_PEERS': 'a',
        'SANDBOX_DISK_ROOT': '/data/workspaces',
        'SANDBOX_DISK_HOST_ROOT': '/srv/dify-sf/workspaces',
        'SANDBOX_DISK_TOOL_IMAGE': tool,
        'SANDBOX_DISK_LOOP_DEVICES': '/dev/loop13',
        'SANDBOX_DISK_BUDGET_MB': '8192',
      };
      final d = SupervisorConfig.fromEnv(env).disk!;
      expect(
        (d.root, d.hostRoot, d.budgetMb, d.minFreeMb),
        ('/data/workspaces', '/srv/dify-sf/workspaces', 8192, 1024),
      );
      for (final bad in [
        {...env, 'SANDBOX_DISK_TOOL_IMAGE': 'tools:latest'},
        {...env, 'SANDBOX_DISK_LOOP_DEVICES': '/dev/sda'},
        {...env, 'SANDBOX_DISK_LOOP_DEVICES': '/dev/loop13,/dev/loop13'},
        {...env, 'SANDBOX_DISK_HOST_ROOT': '/'},
        {...env}..remove('SANDBOX_DISK_BUDGET_MB'),
      ]) {
        expect(
          () => SupervisorConfig.fromEnv(bad),
          throwsA(isA<SupervisorConfigError>()),
          reason: '$bad',
        );
      }
    });
  });

  test('Ipv4Net', () {
    final pool = Ipv4Net.tryParse('10.213.0.0/16')!;
    expect('${pool.subnet(0, 28)}', '10.213.0.0/28');
    expect('${pool.subnet(4095, 28)}', '10.213.255.240/28');
    expect(pool.subnet(1, 28).host(1), '10.213.0.17');
    expect('${Ipv4Net.tryParse('10.213.7.9/28')}', '10.213.7.0/28');
    expect(
      Ipv4Net.tryParse('10.0.0.0/8')!.overlaps(pool.subnet(3, 28)),
      isTrue,
    );
    expect(pool.subnet(0, 28).overlaps(pool.subnet(1, 28)), isFalse);
    expect(Ipv4Net.tryParse('10.0.0.256/8'), isNull);
    expect(Ipv4Net.tryParse('fd00::/8'), isNull);
  });
}

/// Loop devices in memory: device → bound image identity.
class FakeLoop implements LoopHelper {
  /// Workspace bindings; placeholder bindings are in [held].
  final Map<String, ({int dev, int ino})> bound = {};
  final Set<String> held = {};

  /// Devices bound by someone else (snapd): neither ours nor free.
  final Map<String, String> foreign = {};

  /// Images the helper wrote (`prepare` refuses them, `attach` needs them).
  final Set<({int dev, int ino})> formatted = {};

  /// Device nodes that do not exist (after a reboot) until `create`.
  final Set<String> missing = {};
  final List<String> ops = [];
  final List<List<String>> args = [];

  /// Called between clearing the placeholder and binding the image.
  void Function(String device)? onSwap;

  @override
  Future<LoopResult> run(
    String hash,
    String op,
    String device,
    ({int dev, int ino})? identity, {
    List<String> args = const [],
    ({int dev, int ino})? hold,
  }) async {
    ops.add('$op $device');
    if (op == 'prepare') this.args.add(args);
    if (op == 'create') {
      missing.remove(device);
    } else if (missing.contains(device)) {
      // Docker refuses a helper whose device does not exist.
      throw SupervisorError(503, 'disk_workspace_failed', 'no $device');
    }
    final cur = bound[device];
    LoopResult r(
      int code,
      String state, [
      Map<String, Object?> more = const {},
    ]) => (
      exitCode: code,
      out: {
        'state': state,
        if (identity != null) 'dev': identity.dev,
        if (identity != null) 'ino': identity.ino,
        ...more,
      },
    );
    final other = foreign[device];
    if (other != null && op != 'create') {
      return switch (op) {
        'detach' => r(5, 'other'),
        'unhold' => r(0, 'other'),
        _ => r(3, op == 'hold' ? 'other' : 'busy', {'holder': other}),
      };
    }
    switch (op) {
      case 'create':
        return r(0, 'exists');
      case 'hold':
        if (cur != null) return r(3, 'other', {'holder': ''});
        held.add(device);
        return r(0, 'held');
      case 'unhold':
        if (cur != null) return r(0, 'other');
        held.remove(device);
        return r(0, 'free');
      case 'prepare' || 'attach':
        if (cur == identity && op == 'attach') return r(0, 'attached');
        if (cur != null || (held.contains(device) && hold == null)) {
          return r(3, 'busy');
        }
        if (op == 'prepare' && formatted.contains(identity)) {
          return r(5, 'not_empty');
        }
        if (op == 'attach' && !formatted.contains(identity)) {
          return r(6, 'not_formatted');
        }
        if (op == 'prepare') formatted.add(identity!);
        final swapped = held.remove(device);
        if (swapped) {
          onSwap?.call(device);
          final thief = foreign[device];
          if (thief != null) {
            return r(3, 'busy', {
              'holder': thief,
              'lost_hold': true,
              'formatted': op == 'prepare',
            });
          }
        }
        bound[device] = identity!;
        return r(0, 'attached');
      case 'detach':
        if (cur == null) {
          if (hold != null) held.add(device);
          return r(0, 'free', {'held': hold != null});
        }
        if (cur != identity) return r(5, 'other');
        bound.remove(device);
        if (hold != null) held.add(device);
        return r(0, 'detached', {'held': hold != null});
    }
    return r(2, 'unknown_op');
  }
}
