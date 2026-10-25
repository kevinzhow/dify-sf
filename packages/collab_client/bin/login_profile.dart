/// One-time headless sign-in. Credentials stay in an owner-only input file;
/// AuthSession writes the normal private token profile. No Flutter/display or
/// MCP tool is involved, and no account details or credentials are printed.
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:collab_client/collab_client.dart';

const _maxCredentialBytes = 64 * 1024;

Future<void> main(List<String> argv) async {
  exitCode = await loginProfile(argv);
}

Future<int> loginProfile(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('server', help: 'The same server URL passed to the native client.')
    ..addOption('credentials-file', help: '0600 JSON file containing email and password.')
    ..addOption('profile', help: 'Private directory for the normal native token store.')
    ..addFlag('help', abbr: 'h', negatable: false);
  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on Object {
    // Parser messages can echo supplied arguments. Never reflect them.
    stderr.writeln('Invalid login options. Use --help.');
    return 64;
  }
  if (args['help'] as bool) {
    stdout.writeln('One-time headless profile login (dify-sf extension).\n${parser.usage}');
    return 0;
  }

  final String server;
  final Uri uri;
  final String profile;
  final String email;
  final String password;
  try {
    if (!(Platform.isLinux || Platform.isMacOS) || args.rest.isNotEmpty) throw const FormatException();
    server = args['server'] as String;
    uri = Uri.parse(server);
    if (!const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException();
    }
    final file = File(args['credentials-file'] as String);
    if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) {
      throw const FormatException();
    }
    final stat = await file.stat();
    if (stat.mode & 0x1ff != 0x180 || stat.size > _maxCredentialBytes) throw const FormatException();
    final json = jsonDecode(await file.readAsString());
    if (json is! Map<String, Object?> || json.length != 2) throw const FormatException();
    email = (json['email'] as String).trim();
    password = json['password'] as String;
    if (email.isEmpty || password.isEmpty) throw const FormatException();
    profile = args['profile'] as String;
    if (profile.isEmpty) throw const FormatException();
    final type = await FileSystemEntity.type(profile, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await Directory(profile).create(recursive: true);
      final chmod = await Process.run('chmod', ['700', profile]);
      if (chmod.exitCode != 0) throw const FormatException();
    } else if (type != FileSystemEntityType.directory) {
      throw const FormatException();
    }
    if ((await Directory(profile).stat()).mode & 0x1ff != 0x1c0) throw const FormatException();
  } on Object {
    stderr.writeln('Login configuration invalid. Use a 0600 credentials file and a private 0700 profile directory.');
    return 78;
  }

  final api = HttpAuthApi(uri);
  final session = AuthSession(
    api: api,
    store: TokenStore.platform(directory: profile),
    server: server,
  );
  try {
    await session.login(email: email, password: password, rememberMe: true);
    stdout.writeln('Private login profile saved.');
    return 0;
  } on Object {
    // HTTP errors may reflect passwords, addresses or remote payloads. The
    // operator can retry without overwriting a previously valid profile.
    stderr.writeln('Sign-in failed. Check credentials or server availability.');
    return 1;
  } finally {
    await session.dispose();
    api.close();
  }
}
