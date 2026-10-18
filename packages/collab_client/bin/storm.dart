/// Headless storm client: N independent clients in one process make random edits against a server and keep
/// a ground-truth ledger of every intended edit and its outcome.
///
///     dart run collab_client:storm --url http://localhost:8080 --doc storm1 --clients 20 --duration 60 \
///         --rate 10 --crashes-per-minute 2 --ledger out/ledger.json
///
/// Without --url, a self-hosted in-memory protocol server on loopback is used (add --chaos to make its
/// network misbehave). Exit code 0 = all guarantees held, 1 = a violation was found, 2 = bad usage.
///
/// Against a real server (protocol 1.8) every client signs in as --email / --password (default: the environment's
/// DIFYSF_EMAIL / DIFYSF_PASSWORD, else a test account); on a fresh server that account is installed as the owner.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:collab_client/collab_client.dart';
import 'package:collab_client/storm.dart';
import 'package:collab_client/testing_io.dart';

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('url', help: 'Server base URL. Omit to self-host an in-memory server.')
    ..addOption('doc', help: 'Document id (created if absent).', defaultsTo: 'storm')
    ..addOption('template', help: 'Template for a new document.', defaultsTo: 'example', allowed: ['example', 'empty'])
    ..addOption('clients', abbr: 'n', defaultsTo: '5')
    ..addOption('duration', abbr: 'd', help: 'Seconds of editing.', defaultsTo: '20')
    ..addOption('rate', abbr: 'r', help: 'Intended edits per second per client.', defaultsTo: '5')
    ..addOption('seed', defaultsTo: '1')
    ..addOption('volatile-fraction', help: 'Share of clients without a write-ahead journal.', defaultsTo: '0.3')
    ..addOption('crashes-per-minute', help: 'Simulated process crashes per client per minute.', defaultsTo: '0')
    ..addOption('settle-timeout', help: 'Seconds to wait for all outcomes after the storm.', defaultsTo: '60')
    ..addOption('journal-dir', help: 'Directory for journals (default: a temp dir).')
    ..addOption('ledger', help: 'Write the full ground-truth ledger (JSON) to this file.')
    ..addOption('email', help: 'Account to sign in with (real servers, protocol 1.8).')
    ..addOption('password', help: 'Its password.')
    ..addFlag('chaos', help: 'Self-hosted server only: inject cut/stalled streams, lost answers and 503s.')
    ..addFlag('no-verify-log', help: 'Skip replaying the server log to check the ledger against it.')
    ..addFlag('quiet', abbr: 'q')
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr
      ..writeln(e.message)
      ..writeln(parser.usage);
    exit(2);
  }
  if (args['help'] as bool) {
    stdout.writeln('Usage: dart run collab_client:storm [options]\n${parser.usage}');
    return;
  }

  HttpFakeServer? hosted;
  Uri url;
  if (args['url'] != null) {
    url = Uri.parse(args['url'] as String);
  } else {
    hosted = await HttpFakeServer.start(pingInterval: const Duration(seconds: 2));
    url = hosted.url;
    stderr.writeln('self-hosting an in-memory server at $url');
  }
  final quiet = args['quiet'] as bool;
  final seed = int.parse(args['seed'] as String);
  final doc = args['doc'] as String;

  AuthSession? auth;
  if (hosted == null) {
    final env = Platform.environment;
    final email = args['email'] as String? ?? env['DIFYSF_EMAIL'] ?? 'storm@example.com';
    final password = args['password'] as String? ?? env['DIFYSF_PASSWORD'] ?? 'storm-pass-1';
    auth = AuthSession(api: HttpAuthApi(url));
    try {
      if (await auth.api.setupStatus() == SetupStatus.notStarted) {
        await auth.setup(email: email, name: 'Storm', password: password);
      } else {
        await auth.login(email: email, password: password);
      }
    } on TransportException catch (e) {
      stderr.writeln('cannot sign in as $email: $e');
      exit(2);
    }
  }

  final config = StormConfig(
    url: url,
    doc: doc,
    template: args['template'] as String,
    clients: int.parse(args['clients'] as String),
    duration: Duration(seconds: int.parse(args['duration'] as String)),
    ratePerClient: double.parse(args['rate'] as String),
    seed: seed,
    journalDir: args['journal-dir'] as String?,
    volatileFraction: double.parse(args['volatile-fraction'] as String),
    crashesPerClientPerMinute: double.parse(args['crashes-per-minute'] as String),
    settleTimeout: Duration(seconds: int.parse(args['settle-timeout'] as String)),
    verifyLog: !(args['no-verify-log'] as bool),
    // Hosted servers ping every 2 s, so a 10 s silence watchdog still has margin; real servers use 30 s.
    clientConfig: hosted == null ? const ClientConfig() : const ClientConfig(streamSilence: 10000),
    postTimeout: hosted == null ? const Duration(seconds: 10) : const Duration(seconds: 3),
    auth: auth,
  );

  Timer? chaos;
  if (hosted != null && args['chaos'] as bool) chaos = _startChaos(hosted, Random(seed), quiet);

  final report = await StormRunner(
    config,
    log: quiet ? null : (m) => stderr.writeln(m),
    onEditingDone: () {
      chaos?.cancel();
      hosted
        ?..stallStreams = false
        ..swallowResponses = false
        ..postDelay = Duration.zero;
    },
  ).run();
  await hosted?.close();

  final ledgerPath = args['ledger'] as String?;
  if (ledgerPath != null) {
    File(ledgerPath)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(const JsonEncoder.withIndent(' ').convert(report.toJson()));
    stderr.writeln('ledger written to $ledgerPath');
  }
  final summary = (report.toJson()['summary']! as Map<String, Object?>);
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(summary));
  exit(report.ok ? 0 : 1);
}

Timer _startChaos(HttpFakeServer srv, Random rng, bool quiet) {
  void say(String s) {
    if (!quiet) stderr.writeln('chaos: $s');
  }

  return Timer.periodic(const Duration(milliseconds: 1500), (_) {
    switch (rng.nextInt(5)) {
      case 0:
        say('cutting all streams');
        srv.dropStreams();
      case 1:
        say('stalling streams (half-open)');
        srv.stallStreams = true;
        Timer(Duration(milliseconds: 1000 + rng.nextInt(2500)), () => srv.stallStreams = false);
      case 2:
        say('swallowing answers');
        srv.swallowResponses = true;
        Timer(Duration(milliseconds: 500 + rng.nextInt(2000)), () => srv.swallowResponses = false);
      case 3:
        say('503 after commit x${2}');
        srv.failNextPosts += 2;
      case 4:
        say('slow answers');
        srv.postDelay = Duration(milliseconds: 100 + rng.nextInt(900));
        Timer(const Duration(seconds: 2), () => srv.postDelay = Duration.zero);
    }
  });
}
