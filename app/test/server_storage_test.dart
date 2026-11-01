import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/auth/origin_token_store.dart';
import 'package:dify_sf_app/src/server_address.dart';
import 'package:flutter_test/flutter_test.dart';

class PlatformLikeStore extends MemoryTokenStore {
  @override
  Future<AuthTokens?> read(String server) => super.read(tokenStoreKey(server));
  @override
  Future<void> write(String server, AuthTokens value) => super.write(tokenStoreKey(server), value);
  @override
  Future<void> clear(String server) => super.clear(tokenStoreKey(server));
}

void main() {
  test('origins that collide in platform file names keep separate Android credentials', () async {
    const one = 'http://host:8080', two = 'http://host_8080';
    expect(tokenStoreKey(one), tokenStoreKey(two)); // The underlying platform naming collision.
    final inner = PlatformLikeStore();
    final store = OriginTokenStore(inner);
    const a = AuthTokens(accessToken: 'one-access', refreshToken: 'one-refresh');
    const b = AuthTokens(accessToken: 'two-access', refreshToken: 'two-refresh');
    await store.write(one, a);
    await store.write(two, b);
    expect((await store.read(one))?.accessToken, 'one-access');
    expect((await store.read(two))?.accessToken, 'two-access');
    await store.clear(two);
    expect(await store.read(two), isNull);
    expect((await store.read(one))?.accessToken, 'one-access');
  });

  test('canonical origins share a bounded namespace and scheme/port changes are distinct', () {
    expect(serverStorageKey('HTTPS://EXAMPLE.COM:443/'), serverStorageKey('https://example.com'));
    expect(serverStorageKey('http://example.com'), isNot(serverStorageKey('https://example.com')));
    expect(serverStorageKey('http://example.com:8080'), isNot(serverStorageKey('http://example.com:8081')));
    expect(serverStorageKey('https://example.com'), matches(RegExp(r'^origin-[0-9a-f]{64}$')));
  });

  test('the same account and document on a cloned server cannot share the Android outbox', () {
    const account = 'same-account-id', doc = 'same-document-id';
    final one = '${androidJournalNamespace('http://first.example', account)}/$doc';
    final two = '${androidJournalNamespace('http://second.example', account)}/$doc';
    expect(one, isNot(two));
    expect(
      androidJournalNamespace('http://first.example', 'another-account'),
      isNot(androidJournalNamespace('http://first.example', account)),
    );
  });
}
