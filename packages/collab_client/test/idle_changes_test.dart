/// A session at rest announces no changes: the periodic tick must not wake listeners (an editor would rebuild five
/// times a second).
library;

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import 'support/helpers.dart';

void main() {
  test('a live, settled session emits no change while nothing happens, and one when something does', () {
    fakeAsync((async) {
      final server = FakeServer(initial: baseDoc());
      final session = CollabSession(
        transport: FakeTransport(server),
        store: MemoryStore(),
        clock: () => async.elapsed.inMilliseconds,
      );
      var changes = 0;
      session.changes.listen((_) => changes++);
      session.start();
      async.elapse(const Duration(seconds: 2));
      expect(session.link, LinkState.live);

      changes = 0;
      async.elapse(const Duration(seconds: 10));
      expect(changes, 0, reason: '50 ticks at rest');

      session.edit(setPrompt('a', 'x'));
      async.elapse(const Duration(seconds: 2));
      expect(changes, greaterThan(0));
      expect(session.view.nodes['a']!.config['prompt'], VString('x'));

      changes = 0;
      async.elapse(const Duration(seconds: 10));
      expect(changes, 0, reason: 'settled again after the commit');
      session.stop();
      async.flushMicrotasks();
    });
  });
}
