/// App notices (protocol 1.11, `event: app`; Dify's `app_meta_update`): the stream event (no id, ignored by the
/// document machine), the session's `appEvents` (a resync per reconnect), over HTTP and on the in-memory fakes, where
/// the app endpoints announce their changes.
@TestOn('vm')
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:collab_client/testing_io.dart';
import 'package:test/test.dart';

import 'support/helpers.dart';

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 10), String? what}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for ${what ?? 'condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

const _fast = ClientConfig(streamSilence: 900, reconnectBase: 40, reconnectMax: 300, retransmitAfter: 3000);

void main() {
  test('event: app parses (any data), and the machine treats it as liveness only', () {
    final msgs = SseParser().add('event: app\ndata: {"action":"updated"}\n\n');
    expect(StreamEvent.parse(msgs.single.event, msgs.single.data), const AppEvent());
    expect(StreamEvent.parse('app', '{}'), const AppEvent());
    final m = ClientMachine(id: 'c', journaled: false);
    m.tick(0);
    final gen = m.generation;
    m.receiveStream(SnapshotEvent(seq: 3, doc: baseDoc()), gen, 1);
    m.receiveStream(const ReadyEvent(3), gen, 2);
    expect(m.receiveStream(const AppEvent(), gen, 3), isEmpty);
    expect((m.lastSeq, m.streamReady), (3, true));
  });

  test('over HTTP: the session surfaces app notices and a resync per reconnect, not per first connect', () async {
    final srv = await HttpFakeServer.start(pingInterval: const Duration(milliseconds: 300));
    addTearDown(srv.close);
    srv.doc('d', template: 'empty');
    final s = CollabSession(
      clientId: 'alice',
      transport: HttpTransport(baseUrl: srv.url, docId: 'd'),
      journaled: false,
      config: _fast,
      tickInterval: const Duration(milliseconds: 25),
      postTimeout: const Duration(milliseconds: 500),
    );
    addTearDown(s.stop);
    final seen = <AppEvent>[];
    final sub = s.appEvents.listen(seen.add);
    addTearDown(sub.cancel);
    await s.start();
    await s.settled().timeout(const Duration(seconds: 10));
    expect(seen, isEmpty);
    srv.doc('d').announceApp();
    await until(() => seen.isNotEmpty, what: 'app event');
    expect(seen, [const AppEvent()]);
    srv.dropStreams();
    await until(() => seen.length == 2, what: 'resync');
    expect(seen.last, const AppEvent.resync());
  });

  test(
    'in memory: editing the app, its site or a switch notifies the open sessions; unchanged switches do not',
    () async {
      final apps = FakeAppsApi();
      final app = await apps.create(name: 'Bot', mode: AppModes.workflow);
      final s = CollabSession(
        clientId: 'alice',
        transport: FakeTransport(apps.server(app.id), network: FakeNetwork(random: Random(3))),
        journaled: false,
      );
      addTearDown(s.stop);
      final seen = <AppEvent>[];
      s.appEvents.listen(seen.add);
      await s.start();
      await s.settled().timeout(const Duration(seconds: 10));
      await apps.update(app.id, name: 'Renamed');
      await until(() => seen.length == 1, what: 'rename');
      final access = FakeAccessApi(apps);
      await access.setSiteEnabled(app.id, app.enableSite); // unchanged
      await access.setApiEnabled(app.id, !app.enableApi);
      await until(() => seen.length == 2, what: 'switch');
      await access.updateSite(app.id, const AppSiteUpdate(title: 'Site'));
      await until(() => seen.length == 3, what: 'site');
      expect(seen.every((e) => !e.resync), isTrue);
    },
  );
}
