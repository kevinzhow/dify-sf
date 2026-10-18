import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

import 'auth/auth_controller.dart';

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
  /// [displayName] is registered for the id (protocol 1.3); null = unnamed.
  Future<OpenedSession> openSession(String docId, {String? clientId, required bool journaled, String? displayName});

  /// Creates a document with a server-generated id.
  Future<String> createDocument();

  /// Whether this backend converts Dify workflow files (the conversion runs on the server).
  bool get supportsDifyDsl;

  /// Creates a document from a Dify workflow file (YAML); returns its id.
  Future<String> importDifyDsl(String yaml);

  /// The document's current state as a Dify workflow file (YAML).
  Future<String> exportDifyDsl(String docId);

  /// The document's Dify app metadata (mode, name, environment and conversation variables).
  Future<DocMeta> docMeta(String docId);
}

class HttpBackend implements Backend {
  HttpBackend(this.baseUrl, {this.auth});

  final Uri baseUrl;

  /// The signed-in session: its access token goes with every request (protocol 1.8), refreshed once on a 401; a
  /// session the server no longer accepts brings the sign-in page back.
  final AuthController? auth;

  @override
  String get label => baseUrl.toString();

  @override
  Future<String> prepare(String docId, {required bool create}) async {
    final api = DocsApi(baseUrl, auth: auth?.session);
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
    final api = DocsApi(baseUrl, auth: auth?.session);
    try {
      return (await api.create(template: 'example')).id;
    } finally {
      api.close();
    }
  }

  @override
  bool get supportsDifyDsl => true;

  @override
  Future<String> importDifyDsl(String yaml) async {
    final api = DocsApi(baseUrl, auth: auth?.session);
    try {
      return (await api.importDifyDsl(yaml)).id;
    } finally {
      api.close();
    }
  }

  @override
  Future<String> exportDifyDsl(String docId) async {
    final api = DocsApi(baseUrl, auth: auth?.session);
    try {
      return await api.exportDifyDsl(docId);
    } finally {
      api.close();
    }
  }

  @override
  Future<DocMeta> docMeta(String docId) async {
    final api = DocsApi(baseUrl, auth: auth?.session);
    try {
      return await api.meta(docId);
    } finally {
      api.close();
    }
  }

  @override
  Future<OpenedSession> openSession(
    String docId, {
    String? clientId,
    required bool journaled,
    String? displayName,
  }) async {
    // One journal per live window: the id inside it is used by exactly one process at a time (protocol 1.1). And one
    // set per account (protocol 1.8 binds a client id to the account that got it: another account signing in on this
    // device must not reuse it, or its ops are refused with 403).
    final who = journalKeyOf(auth?.account?.id);
    final dir = kIsWeb ? null : '${(await getApplicationSupportDirectory()).path}/journals/$who';
    final slot = await acquirePlatformJournal(kIsWeb ? '$who/$docId' : docId, directory: dir);
    return OpenedSession(
      CollabSession(
        clientId: clientId,
        transport: HttpTransport(baseUrl: baseUrl, docId: docId, auth: auth?.session),
        store: slot,
        journaled: journaled,
        displayName: displayName,
      ),
      slot.release,
    );
  }
}

/// The journals' namespace of an account (file and storage-key safe); `anonymous` without accounts.
String journalKeyOf(String? accountId) =>
    accountId == null || accountId.isEmpty ? 'anonymous' : accountId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
