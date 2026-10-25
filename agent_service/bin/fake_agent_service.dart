import 'dart:convert';
import 'dart:io';

import 'package:agent_service/testing.dart';

const usage = '''
usage: fake_agent_service.dart [--port N] [--address ADDR] [--key KEY]
                               [--script FILE] [--fixtures DIR]

  --port      listening port (default 5050; 0 picks a free one)
  --address   listening address (default 127.0.0.1)
  --key       bearer key of every request (default: AGENT_SERVICE_KEY)
  --script    the run script (JSON, see lib/src/testing/fake_agent_service.dart);
              without it every operation succeeds with a plain text answer
  --fixtures  directory of the contract fixtures used by "fixture" scripts
              (default: fixtures/dify-sf-agent-1 in the current directory,
              else next to this program's package)

Prints {"port": N} on stdout once listening. PUT /_fake/script replaces the
script and clears all state; GET /_fake/requests lists the requests received.
''';

/// A deterministic fake agent service with fault injection, for the Swift
/// server's tests.
Future<void> main(List<String> args) async {
  final options = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '-h' || a == '--help') {
      stdout.write(usage);
      exit(0);
    }
    const names = {'--port', '--address', '--key', '--script', '--fixtures'};
    if (!names.contains(a) || i + 1 >= args.length) {
      stderr.write(usage);
      exit(64);
    }
    options[a.substring(2)] = args[++i];
  }
  final key = options['key'] ?? Platform.environment['AGENT_SERVICE_KEY'];
  if (key == null || key.isEmpty) {
    stderr.writeln('--key or AGENT_SERVICE_KEY is required');
    exit(64);
  }
  final port = int.tryParse(options['port'] ?? '5050');
  if (port == null) {
    stderr.write(usage);
    exit(64);
  }
  final scriptPath = options['script'];
  final script = scriptPath == null
      ? <String, Object?>{}
      : (jsonDecode(File(scriptPath).readAsStringSync()) as Map)
            .cast<String, Object?>();
  final fixtures =
      options['fixtures'] ??
      (Directory('fixtures/dify-sf-agent-1').existsSync()
          ? 'fixtures/dify-sf-agent-1'
          : Platform.script
                .resolve('../fixtures/dify-sf-agent-1')
                .toFilePath());
  final fake = FakeAgentService(
    serviceKey: key,
    script: script,
    fixturesDir: fixtures,
    log: stderr.writeln,
  );
  final address = options['address'] ?? '127.0.0.1';
  final bound = await fake.start(address: address, port: port);
  stdout.writeln(jsonEncode({'port': bound}));
  stderr.writeln('fake agent service on $address:$bound');
  Future<void> stop(ProcessSignal _) async {
    await fake.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(stop);
  ProcessSignal.sigterm.watch().listen(stop);
}
