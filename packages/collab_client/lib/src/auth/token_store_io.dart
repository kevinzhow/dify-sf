import 'dart:convert';
import 'dart:io';

import 'account.dart';
import 'token_store.dart';

TokenStore platformTokenStore({String? directory}) => FileTokenStore(directory ?? _defaultDirectory());

String _defaultDirectory() {
  final env = Platform.environment;
  if (Platform.isWindows) return '${env['APPDATA'] ?? '.'}\\dify-sf\\tokens';
  if (Platform.isMacOS) return '${env['HOME'] ?? '.'}/Library/Application Support/dify-sf/tokens';
  final config = env['XDG_CONFIG_HOME'] ?? '${env['HOME'] ?? '.'}/.config';
  return '$config/dify-sf/tokens';
}

/// [AuthTokens] in one JSON file per server under [directory], readable by the owner only (`0600` on Linux and macOS;
/// Windows keeps the user profile's ACLs). Written atomically: a temp file that gets the permissions before the tokens
/// go into it, then a rename.
class FileTokenStore implements TokenStore {
  FileTokenStore(this.directory);

  final String directory;

  File _file(String server) => File('$directory/${tokenStoreKey(server)}.json');

  @override
  Future<AuthTokens?> read(String server) async {
    final file = _file(server);
    if (!file.existsSync()) return null;
    try {
      return AuthTokens.fromJson(jsonDecode(await file.readAsString()));
    } on FormatException {
      return null; // unreadable: signed out (the user signs in again)
    }
  }

  @override
  Future<void> write(String server, AuthTokens tokens) async {
    final file = _file(server);
    final tmp = File('${file.path}.tmp');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsString('');
    if (Platform.isLinux || Platform.isMacOS) {
      final r = await Process.run('chmod', ['600', tmp.path]);
      if (r.exitCode != 0) throw FileSystemException('chmod 600 failed: ${r.stderr}', tmp.path);
    }
    final raf = await tmp.open(mode: FileMode.write);
    try {
      await raf.writeFrom(utf8.encode(jsonEncode(tokens.toJson())));
      await raf.flush();
    } finally {
      await raf.close();
    }
    await tmp.rename(file.path);
  }

  @override
  Future<void> clear(String server) async {
    final file = _file(server);
    if (file.existsSync()) await file.delete();
  }
}

/// Only in the browser.
class LocalStorageTokenStore implements TokenStore {
  LocalStorageTokenStore({this.prefix = 'dify-sf/tokens/'});

  final String prefix;

  static Never _web() => throw UnsupportedError('localStorage is only available in the browser');

  @override
  Future<AuthTokens?> read(String server) async => _web();

  @override
  Future<void> write(String server, AuthTokens tokens) async => _web();

  @override
  Future<void> clear(String server) async => _web();
}
