import 'auth_api.dart';
import '../server_address.dart';

/// The Android app's new storage starts with exact origin namespaces. Underlying
/// platform stores sanitize file names, which alone would make host:port and
/// host_port collide. The digest also keeps unusually long origins bounded.
class OriginTokenStore implements TokenStore {
  const OriginTokenStore(this.inner);
  final TokenStore inner;

  @override
  Future<AuthTokens?> read(String server) => inner.read(serverStorageKey(server));

  @override
  Future<void> write(String server, AuthTokens tokens) => inner.write(serverStorageKey(server), tokens);

  @override
  Future<void> clear(String server) => inner.clear(serverStorageKey(server));
}
