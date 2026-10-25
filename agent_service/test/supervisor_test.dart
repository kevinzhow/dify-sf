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
  final List<(String, String, Object?)> requests = [];
  final List<Map<String, Object?>> creates = [];
  final List<Map<String, Object?>> networkCreates = [];

  /// Subnets refused as overlapping although no listed network has them
  /// (taken concurrently by someone else).
  final Set<String> refuseSubnets = {};

  /// Container starts fail with HTTP 500.
  bool failStart = false;
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
    switch ((request.method, segments.sublist(1))) {
      case ('GET', ['_ping']):
        return reply(200, 'OK');
      case ('GET', ['containers', 'json']):
        final runningOnly = request.uri.queryParameters['all'] == '0';
        return reply(200, [
          for (final c in containers.values)
            if (_matches((c['Config'] as Map)['Labels'] as Map, wanted) &&
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
        containers[id] = _container(
          id,
          name,
          (payload['Labels'] as Map).cast<String, String>(),
          payload['Env'] as List,
          network: network,
        )..['State'] = {'Running': false, 'Status': 'created'};
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
        return c == null
            ? reply(404, {'message': 'no such container'})
            : reply(200, c);
      case ('DELETE', ['containers', final id]):
        final c = _find(id);
        if (c == null) return reply(404, {'message': 'no such container'});
        for (final n in networks.values) {
          _detach(n, c['Id'] as String);
        }
        containers.remove(c['Id']);
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

  SupervisorConfig config({String? statePath, String pool = '10.213.0.0/16'}) =>
      SupervisorConfig(
        key: key,
        agentPeers: ['agent_service'],
        proxyPeer: 'agent_sandbox_proxy',
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
      );

  Future<void> startSupervisor({
    String? statePath,
    String pool = '10.213.0.0/16',
  }) async {
    supervisor = SandboxSupervisor(config(statePath: statePath, pool: pool));
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
        'HTTP_PROXY=http://10.213.0.2:3128',
        'HTTPS_PROXY=http://10.213.0.2:3128',
        'http_proxy=http://10.213.0.2:3128',
        'https_proxy=http://10.213.0.2:3128',
        'NO_PROXY=localhost,127.0.0.1',
        'no_proxy=localhost,127.0.0.1',
      ],
      'Labels': {'dify-sf.test': 'unit', executionLabel: hash},
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
