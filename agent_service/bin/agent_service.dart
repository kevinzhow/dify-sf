import 'dart:async';
import 'dart:io';

import 'package:agent_service/agent_service.dart';

/// Environment:
///   AGENT_SERVICE_KEY  required; bearer key of every request
///   AGENT_DATA_DIR     required; run store root
///   AGENT_SERVICE_PORT default 5050
///   AGENT_INNER_URL    base URL of the Swift server's inner endpoints
///   AGENT_LOG_LEVEL    debug | info | warning | error (default info)
Future<void> main() async {
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

  final service = AgentService(
    serviceKey: key,
    dataDir: dataDir,
    innerUrl: inner,
    logLevel: level,
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
