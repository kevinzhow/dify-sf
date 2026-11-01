import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

/// A transport whose presence calls can fail.
class _Refusing extends FakeTransport {
  _Refusing(super.server, this.status);
  final int status;
  int calls = 0;

  @override
  Future<void> putPresence(String client, PresenceReport report) async {
    calls++;
    throw TransportException('nope', statusCode: status);
  }
}

/// A transport whose next presence report can fail once or be held, recording what reached the "server" in order.
class _Flaky extends FakeTransport {
  _Flaky(super.server);
  bool failNext = false;
  Completer<void>? hold;
  final calls = <String>[];
  String? panel;

  @override
  Future<void> putPresence(String client, PresenceReport report) async {
    if (failNext) {
      failNext = false;
      throw const TransportException('temporarily unavailable', statusCode: 503);
    }
    if (hold != null) await hold!.future;
    if (report.setsPanel) panel = report.panel;
    calls.add('PUT ${report.toJson(client)}');
  }

  @override
  Future<void> deletePresence(String client) async => calls.add('DELETE');
}

void main() {
  test('parses event: presence (full and delta)', () {
    final full =
        StreamEvent.parse(
              'presence',
              '{"full":true,"left":[],"users":[{"account":"a1","avatar_url":null,"cursor":{"x":1.5,"y":-2},"name":"Maya",'
                  '"drag":{"node":"llm","x":3,"y":4},"panels":["llm"],"since":5}]}',
            )!
            as PresenceEvent;
    expect(full.full, isTrue);
    expect(
      full.users.single,
      const PresenceUser(
        account: 'a1',
        name: 'Maya',
        cursor: PresencePoint(1.5, -2),
        drag: PresenceDrag('llm', 3, 4),
        panels: ['llm'],
        since: 5,
      ),
    );
    final delta = StreamEvent.parse('presence', '{"full":false,"left":["a1"],"users":[]}')! as PresenceEvent;
    expect(delta.full, isFalse);
    expect(delta.left, ['a1']);
  });

  test('applies full and delta events and reports who joined, changed and left', () {
    final p = SessionPresence(FakeTransport(FakeServer()), () => 'c1');
    final changes = <PresenceChange>[];
    p.changes.listen(changes.add);
    fakeAsync((async) {
      const maya = PresenceUser(account: 'm', name: 'Maya', since: 1);
      const bo = PresenceUser(account: 'b', name: 'Bo', since: 2);
      p.apply(const PresenceEvent(full: true, users: [maya, bo]));
      p.apply(
        const PresenceEvent(
          full: false,
          users: [PresenceUser(account: 'b', name: 'Bo', cursor: PresencePoint(3, 4), since: 2)],
        ),
      );
      p.apply(const PresenceEvent(full: false, left: ['m']));
      p.apply(const PresenceEvent(full: false, left: ['nobody'])); // nothing changed: no change event
      // A reconnect's full event: Bo still there (unchanged), Cy new.
      p.apply(
        const PresenceEvent(
          full: true,
          users: [
            PresenceUser(account: 'b', name: 'Bo', cursor: PresencePoint(3, 4), since: 2),
            PresenceUser(account: 'c', name: 'Cy', since: 3),
          ],
        ),
      );
      async.flushMicrotasks();
    });
    expect(changes.map((c) => c.joined.map((u) => u.name).toList()).toList(), [
      ['Maya', 'Bo'],
      [],
      [],
      ['Cy'],
    ]);
    expect(changes[1].updated.single.cursor, const PresencePoint(3, 4));
    expect(changes[2].left.single.name, 'Maya');
    expect(p.users.keys.toSet(), {'b', 'c'});
  });

  test('throttles the pointer like Dify (300 ms, minimum move) and sends the resting position', () {
    fakeAsync((async) {
      final t = FakeTransport(FakeServer());
      final p = SessionPresence(t, () => 'c1', now: () => DateTime.utc(2026).add(async.elapsed));
      p.moveCursor(const PresencePoint(0, 0)); // before enable: remembered, not sent
      expect(t.presenceReports, isEmpty);
      p.enable();
      async.flushMicrotasks();
      expect(t.presenceReports.single.$2!.toJson('c1'), {
        'client': 'c1',
        'cursor': {'x': 0.0, 'y': 0.0},
        'drag': null,
        'panel': null,
      });
      p.moveCursor(const PresencePoint(50, 0), minMove: 10);
      async.flushMicrotasks();
      expect(t.presenceReports.length, 2); // the first pointer report goes at once
      p.moveCursor(const PresencePoint(55, 0), minMove: 10); // too small a move: ignored
      p.moveCursor(const PresencePoint(80, 0), minMove: 10); // within 300 ms: waits
      p.moveCursor(const PresencePoint(90, 0), minMove: 10);
      async.elapse(const Duration(milliseconds: 100));
      expect(t.presenceReports.length, 2);
      async.elapse(const Duration(milliseconds: 250));
      expect(t.presenceReports.length, 3);
      expect(t.presenceReports.last.$2!.cursor, const PresencePoint(90, 0)); // the latest, not the first waiting one
      // Leaving the canvas is sent at once; a panel too.
      p.moveCursor(null);
      p.openPanel('llm');
      async.flushMicrotasks();
      expect(t.presenceReports.map((r) => r.$2!.toJson('c1')).skip(3).toList(), [
        {'client': 'c1', 'cursor': null},
        {'client': 'c1', 'panel': 'llm'},
      ]);
      // A heartbeat every 10 s.
      final before = t.presenceReports.length;
      async.elapse(const Duration(seconds: 10));
      expect(t.presenceReports.length, before + 1);
      expect(t.presenceReports.last.$2!.toJson('c1'), {'client': 'c1'});
    });
  });

  test('a drag is sent at once with the pointer, and again after a reconnect', () {
    fakeAsync((async) {
      final t = FakeTransport(FakeServer());
      final p = SessionPresence(t, () => 'c1', now: () => DateTime.utc(2026).add(async.elapsed));
      p.enable();
      p.moveCursor(const PresencePoint(100, 100));
      async.flushMicrotasks();
      final before = t.presenceReports.length;
      p.moveCursor(const PresencePoint(120, 100)); // within 300 ms: waits for the trailing report
      p.setDrag(const PresenceDrag('llm', 40, 20));
      async.flushMicrotasks();
      expect(t.presenceReports.skip(before).map((r) => r.$2!.toJson('c1')), [
        {
          'client': 'c1',
          'cursor': {'x': 120.0, 'y': 100.0},
          'drag': {'node': 'llm', 'x': 40.0, 'y': 20.0},
        },
      ]);
      async.elapse(const Duration(milliseconds: 400)); // the waiting pointer report went with the drag
      expect(t.presenceReports.length, before + 1);
      p.setDrag(const PresenceDrag('llm', 40, 20)); // unchanged: nothing
      p.onReady();
      async.flushMicrotasks();
      expect(t.presenceReports.last.$2!.drag, const PresenceDrag('llm', 40, 20));
      p.moveCursor(const PresencePoint(300, 180));
      p.setDrag(null);
      async.flushMicrotasks();
      expect(t.presenceReports.last.$2!.toJson('c1'), {
        'client': 'c1',
        'cursor': {'x': 300.0, 'y': 180.0},
        'drag': null,
      });
    });
  });

  test('a report lost to a 503 goes with the next report or heartbeat, never over a newer value', () {
    fakeAsync((async) {
      final t = _Flaky(FakeServer());
      final p = SessionPresence(t, () => 'c1', now: () => DateTime.utc(2026).add(async.elapsed));
      p.enable();
      async.flushMicrotasks();
      t.failNext = true;
      p.openPanel('llm');
      async.flushMicrotasks();
      expect(t.panel, isNull);
      // Nothing else happens: the heartbeat carries it.
      async.elapse(const Duration(seconds: 10));
      expect(t.panel, 'llm');
      // Lost again, then a newer panel: the newer one is what the server ends with.
      t.failNext = true;
      p.openPanel('code');
      async.flushMicrotasks();
      p.openPanel('answer');
      async.flushMicrotasks();
      expect(t.panel, 'answer');
      async.elapse(const Duration(seconds: 10));
      expect(t.panel, 'answer');
    });
  });

  test('closing waits for a report in flight, so the goodbye arrives last', () async {
    final t = _Flaky(FakeServer());
    final p = SessionPresence(t, () => 'c1')..enable();
    await Future<void>.delayed(Duration.zero);
    t.hold = Completer<void>();
    p.openPanel('llm');
    await Future<void>.delayed(Duration.zero);
    final closing = p.close();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(t.calls.where((c) => c == 'DELETE'), isEmpty);
    t.hold!.complete();
    await closing;
    expect(t.calls.last, 'DELETE');
    expect(t.calls[t.calls.length - 2], contains('llm'));
  });

  test('a report stuck in flight holds the goodbye up for at most a second', () {
    fakeAsync((async) {
      final t = _Flaky(FakeServer());
      final p = SessionPresence(t, () => 'c1')..enable();
      async.flushMicrotasks();
      t.hold = Completer<void>();
      p.openPanel('llm');
      async.flushMicrotasks();
      var closed = false;
      unawaited(p.close().then((_) => closed = true));
      async.elapse(const Duration(milliseconds: 900));
      expect(closed, isFalse);
      async.elapse(const Duration(milliseconds: 200));
      expect(closed, isTrue);
      expect(t.calls.last, 'DELETE');
    });
  });

  test('a server without presence (404) or a read-only role (403) stops reporting', () {
    for (final status in [404, 403]) {
      fakeAsync((async) {
        final t = _Refusing(FakeServer(), status);
        final p = SessionPresence(t, () => 'c1');
        p.enable();
        async.flushMicrotasks();
        expect(p.enabled, isFalse);
        p.openPanel('x');
        async.elapse(const Duration(seconds: 30));
        expect(t.calls, 1);
      });
    }
  });

  test('close says goodbye once', () async {
    final t = FakeTransport(FakeServer());
    final p = SessionPresence(t, () => 'c1')..enable();
    await Future<void>.delayed(Duration.zero);
    await p.close();
    await p.close();
    expect(t.presenceReports.where((r) => r.$2 == null).length, 1);
  });
}
