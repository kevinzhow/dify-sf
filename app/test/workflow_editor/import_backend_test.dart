import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing_io.dart';
import 'package:dify_sf_app/src/session_factory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HTTP overwrite waits for pending edits and returns only after the replacement stream arrives', () async {
    final server = await HttpFakeServer.start();
    final backend = HttpBackend(server.url);
    await backend.prepare('doc', create: true);
    final session = CollabSession(
      transport: HttpTransport(baseUrl: server.url, docId: 'doc'),
      journaled: false,
      tickInterval: const Duration(milliseconds: 20),
    );
    try {
      await session.start();
      await session.settled().timeout(const Duration(seconds: 10));
      final old = session.view.nodes.values.first;
      session.edit(MoveNode(old.id, old.x + 10, old.y));
      final result = await backend
          .replaceDifyDsl('doc', '''
kind: app
version: 0.7.0
app: {name: Imported, mode: workflow}
workflow:
  graph:
    nodes:
      - id: replacement
        position: {x: 0, y: 0}
        data: {type: code, title: Imported Code, outputs: {}}
    edges: []
''', session)
          .timeout(const Duration(seconds: 10));
      expect(session.lastSeq, greaterThanOrEqualTo(result.head));
      expect(session.view.nodes.values.single.title, 'Imported Code');
      expect(session.pending, isEmpty);
      expect((await backend.docMeta('doc')).appName, 'Imported');
    } finally {
      await session.stop();
      await server.close();
    }
  });
}
