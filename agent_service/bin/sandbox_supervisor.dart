import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_service/supervisor.dart';

/// The sandbox supervisor (see `lib/src/supervisor/supervisor.dart` and
/// README.md for the `SANDBOX_*` configuration).
Future<void> main(List<String> args) async {
  if (args.contains('--healthcheck')) {
    await healthcheck(
      'SANDBOX_SUPERVISOR_KEY',
      'SANDBOX_SUPERVISOR_PORT',
      5060,
    );
  }
  final SupervisorConfig config;
  try {
    config = SupervisorConfig.fromEnv(Platform.environment);
  } on SupervisorConfigError catch (e) {
    stderr.writeln(e.message);
    exit(64);
  }
  void log(String m) =>
      stderr.writeln('${DateTime.now().toUtc().toIso8601String()} $m');
  final supervisor = SandboxSupervisor(config, log: log);
  try {
    await supervisor.start(address: InternetAddress.anyIPv4);
  } on DockerException catch (e) {
    log(
      'cannot start: $e. The supervisor needs read-write access to the '
      'Docker socket: run it with the socket\'s group (compose: DOCKER_GID='
      '\$(stat -c %g /var/run/docker.sock)).',
    );
    exit(69);
  }
  var stopping = false;
  Future<void> shutdown(ProcessSignal signal) async {
    if (stopping) return;
    stopping = true;
    log('received $signal; stopping (sandboxes are kept)');
    await supervisor.stop();
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
