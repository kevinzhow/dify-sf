import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

/// Where an editor session comes from. The real one talks HTTP/SSE to a server and keeps its journal on
/// disk; the demo one (lib/src/demo) runs against an in-memory server.
abstract interface class Backend {
  String get label;

  /// Makes sure the document exists, returns its id.
  Future<String> prepare(String docId, {required bool create});

  /// A new, not yet started session for [docId].
  Future<CollabSession> openSession(String docId, {required String clientId, required bool journaled});

  /// Creates a document with a server-generated id.
  Future<String> createDocument();
}

class HttpBackend implements Backend {
  HttpBackend(this.baseUrl);

  final Uri baseUrl;

  @override
  String get label => baseUrl.toString();

  @override
  Future<String> prepare(String docId, {required bool create}) async {
    final api = DocsApi(baseUrl);
    try {
      if (create) {
        await api.ensure(docId, template: 'example');
      } else if (await api.info(docId) == null) {
        throw TransportException('Document "$docId" does not exist on $label', statusCode: 404, code: 'not_found');
      }
      return docId;
    } finally {
      api.close();
    }
  }

  @override
  Future<String> createDocument() async {
    final api = DocsApi(baseUrl);
    try {
      return (await api.create(template: 'example')).id;
    } finally {
      api.close();
    }
  }

  @override
  Future<CollabSession> openSession(String docId, {required String clientId, required bool journaled}) async {
    final dir = kIsWeb ? null : '${(await getApplicationSupportDirectory()).path}/journals';
    return CollabSession(
      clientId: clientId,
      transport: HttpTransport(baseUrl: baseUrl, docId: docId),
      store: createPlatformStore(name: '$docId.$clientId', directory: dir),
      journaled: journaled,
    );
  }
}
