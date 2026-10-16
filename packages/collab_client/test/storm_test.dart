/// The headless multi-client runner against the self-hosted protocol server over real sockets.
@TestOn('vm')
@Timeout(Duration(seconds: 90))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/storm.dart';
import 'package:collab_client/testing_io.dart';
import 'package:test/test.dart';

void main() {
  late HttpFakeServer srv;
  late Directory dir;

  setUp(() async {
    srv = await HttpFakeServer.start(pingInterval: const Duration(milliseconds: 300));
    dir = Directory.systemTemp.createTempSync('storm_test');
  });
  tearDown(() async {
    await srv.close();
    dir.deleteSync(recursive: true);
  });

  StormConfig config({int seed = 1, double crashes = 0, double volatile = 0.3}) => StormConfig(
        url: srv.url,
        doc: 'storm',
        clients: 5,
        duration: const Duration(seconds: 3),
        ratePerClient: 12,
        seed: seed,
        journalDir: dir.path,
        crashesPerClientPerMinute: crashes,
        volatileFraction: volatile,
        settleTimeout: const Duration(seconds: 30),
        clientConfig: const ClientConfig(streamSilence: 1200, reconnectBase: 50, reconnectMax: 400),
        postTimeout: const Duration(seconds: 1),
      );

  test('a calm storm ends with every edit accounted for and all clients converged', () async {
    final report = await StormRunner(config()).run();
    expect(report.violations, isEmpty);
    final counts = report.counts;
    expect(counts['pending'], isNull);
    expect(counts['committed'], greaterThan(50));
    expect(report.headAtEnd, srv.doc('storm').head);
    // The ledger is valid JSON with one record per intended edit.
    final json = jsonDecode(jsonEncode(report.toJson())) as Map<String, Object?>;
    expect((json['ledger']! as List<Object?>).length, report.ledger.length);
    expect(report.notes, contains('log verified: ${srv.doc('storm').head} entries'));
  });

  test('crashes, cut and stalled streams, swallowed answers and 503s: still no violation', () async {
    final rng = Random(5);
    var chaosOn = true;
    Future<void> chaos() async {
      while (chaosOn) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        switch (rng.nextInt(4)) {
          case 0:
            srv.dropStreams();
          case 1:
            srv.stallStreams = true;
            Future<void>.delayed(const Duration(milliseconds: 1500), () => srv.stallStreams = false);
          case 2:
            srv.swallowResponses = true;
            Future<void>.delayed(const Duration(milliseconds: 1200), () => srv.swallowResponses = false);
          case 3:
            srv.failNextPosts += 2;
        }
      }
    }

    final done = chaos();
    final report = await StormRunner(
      config(seed: 2, crashes: 30, volatile: 0.5),
      onEditingDone: () {
        chaosOn = false;
        srv
          ..stallStreams = false
          ..swallowResponses = false;
      },
    ).run();
    await done;
    expect(report.violations, isEmpty);
    expect(report.crashes, greaterThan(0));
    expect(report.counts['pending'], isNull);
  });
}
