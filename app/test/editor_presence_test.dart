import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/workflow_editor/collaboration/editor_presence.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('presence feeds the online users, cursors and node viewers, and reports the open panel', () async {
    final demo = DemoBackend(withBo: false);
    final opened = await demo.openSession('demo', clientId: 'me-abc123', journaled: false);
    await opened.session.start();
    final controller = EditorController(session: opened.session, docId: 'demo', journaled: false);
    final presence = EditorPresence(controller, self: 'me', selfName: 'Me', toasts: false);
    addTearDown(() async {
      presence.dispose();
      controller.dispose();
      await opened.close();
      await demo.dispose();
    });
    for (var i = 0; i < 50 && !controller.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(controller.ready, isTrue);

    // Before anyone else: only this user.
    expect(presence.onlineUsers.value.map((u) => u.userId), ['me']);

    var notified = 0;
    presence.addListener(() => notified++);
    final node = controller.doc.nodes.values.firstWhere((n) => n.type != 'start');
    opened.session.presence.apply(
      PresenceEvent(
        full: true,
        users: [
          const PresenceUser(account: 'me', name: 'Me', since: 1),
          PresenceUser(account: 'bo', name: 'Bo', cursor: const PresencePoint(10, 20), panels: [node.id], since: 3),
          const PresenceUser(account: 'maya', name: 'Maya', since: 2),
        ],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(notified, greaterThan(0));
    // This user first, then the others in the order they arrived; never this user among the others.
    expect(presence.onlineUsers.value.map((u) => u.username), ['Me', 'Maya', 'Bo']);
    expect(presence.others.map((u) => u.account), ['maya', 'bo']);
    expect(presence.cursorOf('bo'), const Offset(10, 20));
    expect(presence.cursorOf('maya'), isNull);
    expect(presence.viewersOf(node.id).map((u) => u.name), ['Bo']);

    // Selecting a node opens its panel: reported; deselecting closes it.
    final transport = opened.session.transport as FakeTransport;
    transport.presenceReports.clear();
    controller.selectNode(node.id);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    controller.selectNode(null);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final panels = [
      for (final (_, r) in transport.presenceReports)
        if (r != null && r.setsPanel) r.panel,
    ];
    expect(panels, [node.id, null]);

    // Dragging a node: reported with where the pointer holds it, then cleared.
    transport.presenceReports.clear();
    presence.drag((node.id, const Offset(40, 12)));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    presence.drag(null);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final drags = [
      for (final (_, r) in transport.presenceReports)
        if (r != null && r.setsDrag) r.drag,
    ];
    expect(drags, [PresenceDrag(node.id, 40, 12), null]);
  });
}
