import '../client/store.dart';
import 'platform_store_io.dart' if (dart.library.js_interop) 'platform_store_web.dart' as impl;

/// The right persistent store for the current platform: a file under [directory] on the VM (desktop, CLI),
/// `localStorage` in the browser (where [directory] is ignored). [name] identifies the client + document.
DurableStore createPlatformStore({required String name, String? directory}) =>
    impl.create(name: name, directory: directory);

/// Claims the journal of this client instance for [docId]: a locked file slot under [directory] on the VM, a
/// per-tab `localStorage` entry in the browser. Release it when the session is closed for good.
Future<JournalSlot> acquirePlatformJournal(String docId, {String? directory}) =>
    impl.acquireJournal(docId: docId, directory: directory);
