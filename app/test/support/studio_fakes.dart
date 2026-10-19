import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/session_factory.dart';

/// The editor's backend for the apps of a [FakeAppsApi]: each app's document is its [FakeAppsApi.server] (a deleted
/// app's requests answer `404 app_deleted`, as the server's).
class FakeAppsBackend implements Backend {
  FakeAppsBackend(this.apps);

  final FakeAppsApi apps;
  final _servers = <String, FakeServer>{};

  FakeServer _server(String id) => _servers[id] ??= apps.server(id);

  @override
  String get label => 'fake apps server';

  @override
  Future<String> prepare(String docId, {required bool create}) async {
    _server(docId);
    return docId;
  }

  @override
  Future<OpenedSession> openSession(
    String docId, {
    String? clientId,
    required bool journaled,
    String? displayName,
  }) async => OpenedSession(
    CollabSession(
      clientId: clientId,
      transport: FakeTransport(_server(docId)),
      store: MemoryStore(),
      journaled: journaled,
      displayName: displayName,
      tickInterval: const Duration(milliseconds: 100),
      postTimeout: const Duration(seconds: 3),
    ),
  );

  @override
  Future<String> createDocument() => throw UnsupportedError('apps are created through the apps API');

  @override
  bool get supportsDifyDsl => true;

  @override
  Future<String> importDifyDsl(String yaml) async => (await apps.importDsl(yaml)).appId!;

  @override
  Future<String> exportDifyDsl(String docId, {bool includeSecret = false}) =>
      apps.exportDsl(docId, includeSecret: includeSecret);

  @override
  Future<DocMeta> docMeta(String docId) async {
    final app = await apps.get(docId);
    return DocMeta(appMode: app.mode, appName: app.name);
  }

  @override
  Future<ReplaceResult> replaceDifyDsl(String docId, String yaml, CollabSession session, {bool confirm = false}) =>
      throw UnsupportedError('not needed by the Studio tests');
}
