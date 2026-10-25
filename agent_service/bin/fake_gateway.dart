import 'dart:convert';
import 'dart:io';

import 'package:agent_service/testing.dart';

/// A scripted inner gateway for local manual runs.
///
/// `dart run bin/fake_gateway.dart SCRIPT.json [PORT [ADDRESS]]`
///
/// ADDRESS defaults to 127.0.0.1; a container uses 0.0.0.0 so that the agent
/// service can reach it (see tool/compose_smoke.sh).
///
/// The script format is documented in lib/src/testing/scripted_gateway.dart.
/// If AGENT_SERVICE_KEY is set, requests must carry it as a bearer key.
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: fake_gateway.dart <script.json> [port [address]]');
    exit(64);
  }
  final script = (jsonDecode(File(args[0]).readAsStringSync()) as Map)
      .cast<String, Object?>();
  final port = args.length > 1 ? int.parse(args[1]) : 5051;
  final address = args.length > 2 ? args[2] : '127.0.0.1';
  final key = Platform.environment['AGENT_SERVICE_KEY'];
  final gateway = ScriptedGateway.fromJson(
    script,
    serviceKey: key == null || key.isEmpty ? null : key,
    log: stderr.writeln,
  );
  await gateway.start(address: address, port: port);
  stderr.writeln('fake inner gateway on $address:$port');
  Future<void> stop(ProcessSignal _) async {
    await gateway.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(stop);
  ProcessSignal.sigterm.watch().listen(stop);
}
