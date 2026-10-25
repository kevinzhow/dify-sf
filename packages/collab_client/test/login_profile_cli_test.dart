@TestOn('vm')
@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';
import 'dart:io';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:collab_client/testing_io.dart';
import 'package:test/test.dart';

const _email = 'cli-profile@example.test';
const _password = 'synthetic-cli-password-only';

void main() {
  late Directory root;
  late HttpFakeServer server;
  late File credentials;
  late String profile;

  Future<void> mode(String path, String value) async {
    final result = await Process.run('chmod', [value, path]);
    expect(result.exitCode, 0);
  }

  Future<ProcessResult> login({String? input, String? url, String? target, List<String>? arguments}) => Process.run(
    Platform.environment['DART_BIN'] ?? 'dart',
    [
      'run',
      'bin/login_profile.dart',
      ...?arguments,
      if (arguments == null) ...[
        '--server',
        url ?? '${server.url}',
        '--credentials-file',
        input ?? credentials.path,
        '--profile',
        target ?? profile,
      ],
    ],
    environment: {'DISPLAY': '', 'WAYLAND_DISPLAY': '', 'XDG_RUNTIME_DIR': '${root.path}/no-display'},
  );

  void noCredentials(ProcessResult result, [Iterable<String> more = const []]) {
    final text = '${result.stdout}${result.stderr}';
    for (final value in [_email, _password, ...more]) {
      expect(text.contains(value), isFalse, reason: 'CLI must not reflect credentials or remote error bodies');
    }
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('login-profile-');
    final accounts = FakeAccounts()..addMember(email: _email, password: _password);
    server = await HttpFakeServer.start(accounts: accounts);
    credentials = File('${root.path}/credentials.json');
    await credentials.writeAsString('');
    await mode(credentials.path, '600');
    await credentials.writeAsString(jsonEncode({'email': _email, 'password': _password}));
    profile = '${root.path}/profile';
  });
  tearDown(() async {
    await server.close();
    await root.delete(recursive: true);
  });

  test('no-display login writes private native profile; normal AuthSession restores it', () async {
    final result = await login();
    expect(result.exitCode, 0);
    expect((await Directory(profile).stat()).mode & 0x1ff, 0x1c0);
    final files = await Directory(profile).list().where((f) => f.path.endsWith('.json')).toList();
    expect(files.length, 1);
    expect((await files.single.stat()).mode & 0x1ff, 0x180);
    final api = HttpAuthApi(server.url);
    final auth = AuthSession(
      api: api,
      store: TokenStore.platform(directory: profile),
      server: '${server.url}',
    );
    try {
      expect(await auth.restore(), isTrue);
      expect(auth.currentAccount?.email == _email, isTrue);
      noCredentials(result, [auth.tokens!.accessToken, auth.tokens!.refreshToken]);
    } finally {
      await auth.dispose();
      api.close();
    }
  });

  test('failed login preserves a valid profile and never prints the password', () async {
    expect((await login()).exitCode, 0);
    final file = File('$profile/${tokenStoreKey('${server.url}')}.json');
    final before = await file.readAsString();
    const wrong = 'synthetic-wrong-password';
    await credentials.writeAsString(jsonEncode({'email': _email, 'password': wrong}));
    final result = await login();
    expect(result.exitCode, 1);
    expect(await file.readAsString() == before, isTrue);
    noCredentials(result, [wrong]);
  });

  test('public credentials are refused before login', () async {
    await mode(credentials.path, '644');
    final result = await login(url: 'http://127.0.0.1:1');
    expect(result.exitCode, 78);
    expect(await Directory(profile).exists(), isFalse);
    noCredentials(result);
  });

  test('credential symlinks and malformed JSON are refused without reflection', () async {
    final link = Link('${root.path}/credentials-link');
    await link.create(credentials.path);
    expect((await login(input: link.path)).exitCode, 78);
    await credentials.writeAsString('invalid $_password');
    final result = await login();
    expect(result.exitCode, 78);
    noCredentials(result);
  });

  test('nonprivate existing profile is refused without changing its permissions', () async {
    await Directory(profile).create();
    await mode(profile, '755');
    final result = await login(url: 'http://127.0.0.1:1');
    expect(result.exitCode, 78);
    expect((await Directory(profile).stat()).mode & 0x1ff, 0x1ed);
    expect(await Directory(profile).list().isEmpty, isTrue);
    noCredentials(result);
  });

  test('parser does not echo a credential accidentally supplied as an option', () async {
    final result = await login(arguments: ['--password=$_password']);
    expect(result.exitCode, 64);
    noCredentials(result);
  });

  test('reflected server password is not included in a failed sign-in message', () async {
    final remote = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    remote.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = 401;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'error': {'code': 'unauthorized', 'message': _password},
        }),
      );
      await request.response.close();
    });
    try {
      final result = await login(url: 'http://127.0.0.1:${remote.port}');
      expect(result.exitCode, 1);
      noCredentials(result);
    } finally {
      await remote.close(force: true);
    }
  });
}
