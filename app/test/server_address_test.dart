import 'dart:async';

import 'package:dify_sf_app/src/server_address.dart';
import 'package:dify_sf_app/src/server_connection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('origins are canonical and keep an explicit non-default port', () {
    expect(normalizeServerAddress('  HTTPS://EXAMPLE.COM/  '), 'https://example.com');
    expect(normalizeServerAddress('https://example.com:443/'), 'https://example.com');
    expect(normalizeServerAddress('https://example.com:8443/'), 'https://example.com:8443');
    expect(normalizeServerAddress('http://[::1]:8080/'), 'http://[::1]:8080');
  });

  for (final value in [
    '',
    'example.com',
    'ftp://example.com',
    'https://',
    'https://example.com/v1',
    'https://user:pass@example.com',
    'https://example.com?q=1',
    'https://example.com#section',
    'https://exa mple.com',
    'http://localhost:0',
    'http://localhost:65536',
    'http://192.168.1.999',
    'http://1.2.3',
    'http://123',
    'http://010.0.0.1',
    'http://0x7f.0.0.1',
    'http://dify.0x7f',
    'http://[1]',
    'http://[::::]',
  ]) {
    test('refuses a server choice that is not an origin: $value', () {
      expect(() => normalizeServerAddress(value), throwsA(isA<ServerAddressException>()));
    });
  }

  test('HTTP and HTTPS are both available for user-selected self-hosted servers', () {
    for (final host in ['localhost', '127.0.0.1', '10.0.2.2', 'example.com', '192.168.1.1']) {
      for (final scheme in ['http', 'https']) {
        expect(normalizeServerAddress('$scheme://$host:8080'), '$scheme://$host:8080');
      }
    }
  });

  test('a new Android installation asks for an address; a build can supply its own default', () {
    expect(nativeDefaultServer(android: true, configured: ''), '');
    expect(nativeDefaultServer(android: false, configured: ''), 'http://localhost:8080');
    expect(nativeDefaultServer(android: true, configured: ' https://own.example '), 'https://own.example');
  });

  test('a failed change keeps the current connection and launch generation', () async {
    final c = ServerConnectionController(server: 'https://one.example');
    c.bind((_) async => throw StateError('storage unavailable'));
    await expectLater(c.select('https://two.example'), throwsStateError);
    expect(c.server, 'https://one.example');
    expect(c.generation, 0);
    expect(c.busy, isFalse);
    c.dispose();
  });

  test('two simultaneous choices cannot race the remembered server or its session', () async {
    final c = ServerConnectionController(server: 'https://one.example');
    final done = Completer<void>();
    final calls = <String>[];
    c.bind((s) {
      calls.add(s);
      return done.future;
    });
    final first = c.select('https://two.example/');
    expect(c.busy, isTrue);
    await expectLater(c.select('https://three.example'), throwsStateError);
    done.complete();
    await first;
    expect(calls, ['https://two.example']);
    expect(c.server, 'https://two.example');
    expect(c.generation, 1);
    c.dispose();
  });

  test('an in-flight choice can finish after the app closes without notifying disposed listeners', () async {
    final c = ServerConnectionController(server: 'https://one.example');
    final done = Completer<void>();
    c.bind((_) => done.future);
    final changed = c.select('https://two.example');
    c.dispose();
    done.complete();
    await changed;
  });
}
