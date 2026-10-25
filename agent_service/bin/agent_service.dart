import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_service/agent_service.dart';

/// Environment:
///   AGENT_SERVICE_KEY  required; bearer key of every request
///   AGENT_DATA_DIR     required; run store root
///   AGENT_SERVICE_PORT default 5050
///   AGENT_INNER_URL    base URL of the Swift server's inner endpoints
///   AGENT_LOG_LEVEL    debug | info | warning | error (default info)
///   AGENT_SANDBOX_SUPERVISOR_URL / AGENT_SANDBOX_SUPERVISOR_KEY
///                      the sandbox supervisor; unset = no shell
Future<void> main(List<String> args) async {
  if (args.contains('--healthcheck')) {
    await healthcheck('AGENT_SERVICE_KEY', 'AGENT_SERVICE_PORT', 5050);
  }
  final env = Platform.environment;
  String? required(String name) {
    final v = env[name];
    if (v == null || v.isEmpty) {
      stderr.writeln('$name is required');
      return null;
    }
    return v;
  }

  final key = required('AGENT_SERVICE_KEY');
  final dataDir = required('AGENT_DATA_DIR');
  if (key == null || dataDir == null) exit(64);
  final port = int.tryParse(env['AGENT_SERVICE_PORT'] ?? '') ?? 5050;
  final innerText = env['AGENT_INNER_URL'];
  final inner = innerText == null || innerText.isEmpty
      ? null
      : Uri.parse(innerText);
  final level =
      LogLevel.values
          .where((l) => l.name == (env['AGENT_LOG_LEVEL'] ?? '').toLowerCase())
          .firstOrNull ??
      LogLevel.info;
  if (inner == null) {
    stderr.writeln(
      'AGENT_INNER_URL is not set: runs will fail (health: degraded)',
    );
  }

  final supervisorText = env['AGENT_SANDBOX_SUPERVISOR_URL'] ?? '';
  final supervisorKey = env['AGENT_SANDBOX_SUPERVISOR_KEY'] ?? '';
  if (supervisorText.isNotEmpty && supervisorKey.isEmpty) {
    stderr.writeln('AGENT_SANDBOX_SUPERVISOR_KEY is required with the URL');
    exit(64);
  }
  final supervisor = supervisorText.isEmpty
      ? null
      : SupervisorClient(Uri.parse(supervisorText), supervisorKey);
  if (supervisor == null) {
    stderr.writeln(
      'AGENT_SANDBOX_SUPERVISOR_URL is not set: the shell is disabled',
    );
  }

  final service = AgentService(
    serviceKey: key,
    dataDir: dataDir,
    innerUrl: inner,
    logLevel: level,
    supervisor: supervisor,
  );
  await service.start(address: InternetAddress.anyIPv4, port: port);

  var stopping = false;
  Future<void> shutdown(ProcessSignal signal) async {
    if (stopping) return;
    stopping = true;
    stderr.writeln('received $signal; stopping');
    await service.stop();
    exit(0);
  }

  ProcessSignal.sigterm.watch().listen(shutdown);
  ProcessSignal.sigint.watch().listen(shutdown);
}

/// `--healthcheck`: GET /v1/health on this container's own port with its own
/// key (for the compose health check; the image has no curl). Exit 0 on 200.
Future<Never> healthcheck(
  String keyVariable,
  String portVariable,
  int port,
) async {
  final env = Platform.environment;
  final p = int.tryParse(env[portVariable] ?? '') ?? port;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client.get('127.0.0.1', p, '/v1/health');
    request.headers.set('Authorization', 'Bearer ${env[keyVariable] ?? ''}');
    final response = await request.close().timeout(const Duration(seconds: 5));
    final body = await utf8.decodeStream(response);
    stdout.writeln('${response.statusCode} $body');
    exit(response.statusCode == 200 ? 0 : 1);
  } catch (e) {
    stdout.writeln('unhealthy: $e');
    exit(1);
  }
}
