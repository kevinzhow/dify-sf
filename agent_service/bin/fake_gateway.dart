import 'dart:convert';
import 'dart:io';

import 'package:agent_service/testing.dart';

/// A scripted inner gateway for local manual runs.
///
/// `dart run bin/fake_gateway.dart SCRIPT.json [PORT]`
///
/// The script format is documented in lib/src/testing/scripted_gateway.dart.
/// If AGENT_SERVICE_KEY is set, requests must carry it as a bearer key.
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: fake_gateway.dart <script.json> [port]');
    exit(64);
  }
  final script = (jsonDecode(File(args[0]).readAsStringSync()) as Map)
      .cast<String, Object?>();
  final port = args.length > 1 ? int.parse(args[1]) : 5051;
  final key = Platform.environment['AGENT_SERVICE_KEY'];
  final gateway = ScriptedGateway.fromJson(
    script,
    serviceKey: key == null || key.isEmpty ? null : key,
    log: stderr.writeln,
  );
  final url = await gateway.start(port: port);
  stderr.writeln('fake inner gateway on $url');
  ProcessSignal.sigint.watch().listen((_) async {
    await gateway.close();
    exit(0);
  });
}
