import 'account.dart';
import 'token_store_io.dart' if (dart.library.js_interop) 'token_store_web.dart' as impl;

/// Where signed-in sessions' tokens survive a restart (protocol 1.8), one entry per server (key: the server's base URL).
///
/// * Desktop and CLI: `FileTokenStore` (`dart:io`): one JSON file per server under a directory (the app passes its
///   support directory), created with permissions `0600` (owner only) on Linux and macOS.
/// * Web: `LocalStorageTokenStore`, `localStorage`. Dify keeps its tokens in HttpOnly cookies, which page scripts cannot
///   read; dify-sf uses bearer tokens (one mechanism for every platform, no cookies, no CSRF tokens), so in the browser the
///   tokens are readable by scripts of the app's origin. The trade-off: an XSS bug in the app could steal them (the
///   refresh token lasts 30 days); in exchange there is no cross-site request forgery, since the browser never attaches
///   the token by itself. Keep the app free of injected script.
/// * Tests and demos: [MemoryTokenStore].
abstract interface class TokenStore {
  /// The saved tokens for [server], or null when nobody is signed in there.
  Future<AuthTokens?> read(String server);

  Future<void> write(String server, AuthTokens tokens);

  /// Sign-out: forgets the tokens for [server].
  Future<void> clear(String server);

  /// The platform's persistent store: files under [directory] on the VM (default: the user's config directory, e.g.
  /// `~/.config/dify-sf/tokens` on Linux), `localStorage` in the browser ([directory] is ignored there).
  factory TokenStore.platform({String? directory}) => impl.platformTokenStore(directory: directory);
}

/// Tokens in memory only (tests, demos, a CLI that signs in every run).
class MemoryTokenStore implements TokenStore {
  final Map<String, AuthTokens> tokens = {};

  @override
  Future<AuthTokens?> read(String server) async => tokens[server];

  @override
  Future<void> write(String server, AuthTokens t) async => tokens[server] = t;

  @override
  Future<void> clear(String server) async => tokens.remove(server);
}

/// A file or storage key for [server] (letters, digits, `-`, `_` and `.` kept, everything else `_`).
String tokenStoreKey(String server) => server.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
