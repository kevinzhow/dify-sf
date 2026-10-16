import '../client/store.dart';
import 'platform_store_io.dart' if (dart.library.js_interop) 'platform_store_web.dart' as impl;

/// The right persistent store for the current platform: a file under [directory] on the VM (desktop, CLI),
/// `localStorage` in the browser (where [directory] is ignored). [name] identifies the client + document.
DurableStore createPlatformStore({required String name, String? directory}) =>
    impl.create(name: name, directory: directory);
