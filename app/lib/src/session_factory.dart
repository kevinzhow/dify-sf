import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

/// Where an editor session comes from. The real one talks HTTP/SSE to a server and keeps its journal on
/// disk; the demo one (lib/src/demo) runs against an in-memory server.
/// A session plus whatever has to be given back when it is closed for good (the journal slot).
class OpenedSession {
  OpenedSession(this.session, [this._release]);

  final CollabSession session;
  final Future<void> Function()? _release;

  /// Stops the session and releases its journal, so another window or a restart can claim it.
  Future<void> close() async {
    await session.stop();
    await _release?.call();
  }
}

abstract interface class Backend {
  String get label;

  /// Makes sure the document exists, returns its id.
  Future<String> prepare(String docId, {required bool create});

  /// A new, not yet started session for [docId]. Normally [clientId] is null: the session takes the id from its
  /// journal or gets a fresh one from the server (protocol 1.1). An explicit id is for tests and demos.
  Future<OpenedSession> openSession(String docId, {String? clientId, required bool journaled});

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
  Future<OpenedSession> openSession(String docId, {String? clientId, required bool journaled}) async {
    // One journal per live window: the id inside it is used by exactly one process at a time (protocol 1.1).
    final dir = kIsWeb ? null : '${(await getApplicationSupportDirectory()).path}/journals';
    final slot = await acquirePlatformJournal(docId, directory: dir);
    return OpenedSession(
      CollabSession(
        clientId: clientId,
        transport: HttpTransport(baseUrl: baseUrl, docId: docId),
        store: slot,
        journaled: journaled,
      ),
      slot.release,
    );
  }
}
