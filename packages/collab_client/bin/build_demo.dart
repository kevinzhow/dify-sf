/// The build demo: clients join one by one and build a workflow together, from a plan made by
/// `tool/demo/build_storm/make_plan.py` (each client adds its nodes, moves them into place, connects them, then reviews
/// other people's nodes). It runs on the storm runner, so every edit is in the ledger and the end is verified as in
/// `storm`: every edit has an outcome, every client ends with the server's document, every confirmed edit is in the
/// server's log.
///
///     dart run collab_client:build_demo --url http://127.0.0.1:8080 --doc <app id> --plan plan.json \
///         --duration 60 --rate 3 --progress /tmp/progress.json --ledger out/ledger.json
///
/// Every client signs in as --email / --password (the owner of the demo server). Exit code 0 = all guarantees held,
/// 1 = a violation was found, 2 = bad usage.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:collab_client/collab_client.dart';
import 'package:collab_client/storm.dart';

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('url', help: 'Server base URL.', mandatory: true)
    ..addOption('doc', help: 'Id of the workflow to build (made from the plan\'s start.yml).', mandatory: true)
    ..addOption('plan', help: 'The plan (make_plan.py).', mandatory: true)
    ..addOption('duration', abbr: 'd', help: 'Seconds of editing, from the start.', defaultsTo: '60')
    ..addOption('rate', abbr: 'r', help: 'Intended edits per second per client.', defaultsTo: '3')
    ..addOption('seed', defaultsTo: '1')
    ..addOption('settle-timeout', help: 'Seconds to wait for all outcomes after the editing.', defaultsTo: '60')
    ..addOption('progress', help: 'Rewrite this JSON file with the counts about every 500 ms.')
    ..addOption('ledger', help: 'Write the full ground-truth ledger (JSON) to this file.')
    ..addOption('email', help: 'The owner\'s account (signs in to create the people\'s accounts).')
    ..addOption('password', help: 'Its password.')
    ..addOption(
      'accounts',
      help:
          'JSON file with one account per client (created on first use, as editors named after the plan). '
          'Without it every client is the owner and presence shows one user.',
    )
    ..addFlag('presence', help: 'Report pointers and open panels (protocol 1.22).', defaultsTo: true)
    ..addOption('linger', help: 'Seconds the clients stay connected after the checks.', defaultsTo: '0')
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
    stdout.writeln('Usage: dart run collab_client:build_demo [options]\n${parser.usage}');
    return;
  }

  final url = Uri.parse(args['url'] as String);
  final plan = jsonDecode(File(args['plan'] as String).readAsStringSync()) as Map<String, Object?>;
  final clients = [
    for (final c in plan['clients']! as List<Object?>) (c! as Map<String, Object?>),
  ];
  final env = Platform.environment;
  final email = args['email'] as String? ?? env['DIFYSF_EMAIL'];
  final password = args['password'] as String? ?? env['DIFYSF_PASSWORD'];
  if (email == null || password == null) {
    stderr.writeln('--email and --password (or DIFYSF_EMAIL / DIFYSF_PASSWORD) are required');
    exit(2);
  }
  final auth = AuthSession(api: HttpAuthApi(url));
  try {
    await auth.login(email: email, password: password);
  } on TransportException catch (e) {
    stderr.writeln('cannot sign in as $email: $e');
    exit(2);
  }

  // One account per client: invited as editors and activated once, then reused (a local demo server only).
  final accountsPath = args['accounts'] as String?;
  final people = <TokenProvider>[];
  if (accountsPath != null) {
    final file = File(accountsPath);
    final known = file.existsSync()
        ? [for (final a in jsonDecode(file.readAsStringSync()) as List<Object?>) (a! as Map<String, Object?>)]
        : <Map<String, Object?>>[];
    // A file written by an older version may still be readable by others: owner only from now on.
    if (file.existsSync() && (Platform.isLinux || Platform.isMacOS)) await Process.run('chmod', ['600', file.path]);
    final rng = Random.secure();
    for (var i = known.length; i < clients.length; i++) {
      final name = clients[i]['name']! as String;
      final email = '${name.toLowerCase()}.${i + 1}@people.demo.example';
      final invited = await auth.invite(emails: [email], role: 'editor');
      final link = invited.single.url;
      if (link == null) {
        stderr.writeln('cannot invite $email: ${invited.single.status} ${invited.single.message ?? ''}');
        exit(2);
      }
      final token = Uri.parse(link).queryParameters['token']!;
      final password = 'demo${List.generate(16, (_) => rng.nextInt(36).toRadixString(36)).join()}7';
      await auth.api.activate(token: token, name: name, password: password);
      known.add({'email': email, 'password': password, 'name': name});
      await writePrivate(file, const JsonEncoder.withIndent(' ').convert(known));
    }
    for (final a in known.take(clients.length)) {
      final s = AuthSession(api: HttpAuthApi(url));
      await s.login(email: a['email']! as String, password: a['password']! as String);
      people.add(s);
    }
    stderr.writeln('${people.length} accounts signed in');
  }

  final progressPath = args['progress'] as String?;
  void writeProgress(Map<String, Object?> p) {
    if (progressPath == null) return;
    File('$progressPath.tmp')
      ..writeAsStringSync(jsonEncode(p))
      ..renameSync(progressPath);
  }

  late final StormRunner runner;
  final config = StormConfig(
    url: url,
    doc: args['doc'] as String,
    clients: clients.length,
    duration: Duration(seconds: int.parse(args['duration'] as String)),
    ratePerClient: double.parse(args['rate'] as String),
    seed: int.parse(args['seed'] as String),
    volatileFraction: 0,
    settleTimeout: Duration(seconds: int.parse(args['settle-timeout'] as String)),
    reapplyRate: 0,
    auth: auth,
    joinAfter: (i) => Duration(milliseconds: clients[i]['join_ms']! as int),
    authFor: people.isEmpty ? null : (i) => people[i],
    presence: args['presence'] as bool,
    linger: Duration(seconds: int.parse(args['linger'] as String)),
    editorFor: (i, id, rng) => PlanEditor(
      [for (final s in clients[i]['steps']! as List<Object?>) (s! as Map<String, Object?>)],
      onPresence: ({setsCursor = false, cursor, setsDrag = false, drag, setsPanel = false, panel}) =>
          runner.reportPresence(
            i,
            setsCursor: setsCursor,
            cursor: cursor,
            setsDrag: setsDrag,
            drag: drag,
            setsPanel: setsPanel,
            panel: panel,
          ),
    ).next,
  );
  runner = StormRunner(config, log: (m) => stderr.writeln(m), onProgress: writeProgress);
  final report = await runner.run();
  final summary = report.toJson()['summary']! as Map<String, Object?>;
  writeProgress({
    'phase': 'verified',
    'clients': clients.length,
    'online': clients.length,
    'intended': report.ledger.length,
    ...report.counts,
    'ok': report.ok,
    'violations': report.violations.length,
  });

  final ledgerPath = args['ledger'] as String?;
  if (ledgerPath != null) {
    File(ledgerPath)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(const JsonEncoder.withIndent(' ').convert(report.toJson()));
    stderr.writeln('ledger written to $ledgerPath');
  }
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(summary));
  exit(report.ok ? 0 : 1);
}

/// Writes [text] to [file] readable by the owner only (it holds passwords): a 0600 temporary file, then renamed over
/// [file], as the token store does.
Future<void> writePrivate(File file, String text) async {
  final tmp = File('${file.path}.tmp');
  await tmp.parent.create(recursive: true);
  await tmp.writeAsString('');
  if (Platform.isLinux || Platform.isMacOS) {
    final r = await Process.run('chmod', ['600', tmp.path]);
    if (r.exitCode != 0) throw FileSystemException('chmod 600 failed: ${r.stderr}', tmp.path);
  }
  await tmp.writeAsString(text, flush: true);
  await tmp.rename(file.path);
}
