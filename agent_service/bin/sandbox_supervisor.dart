import 'dart:async';
import 'dart:io';

import 'package:agent_service/supervisor.dart';

/// The sandbox supervisor (see `lib/src/supervisor/supervisor.dart` and
/// README.md for the `SANDBOX_*` configuration).
Future<void> main() async {
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
    log('cannot start: $e');
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
