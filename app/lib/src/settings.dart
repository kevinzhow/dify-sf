import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// What the user chose on the start screen; remembered between runs.
class AppSettings {
  AppSettings({
    required this.serverUrl,
    required this.userName,
    required this.journaled,
    required this.lastDoc,
    required this.clientSuffix,
  });

  String serverUrl;
  String userName;

  /// Write-ahead journal on (default) or volatile mode.
  bool journaled;
  String lastDoc;

  /// Random part of the client id, generated once per install.
  final String clientSuffix;

  /// The collaboration client id: `<name>-<suffix>`. Stable across restarts, so a journal written by a
  /// crashed run is found and resent. Two windows editing the same document need different names.
  String get clientId {
    final slug = userName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    return '${slug.isEmpty ? 'user' : slug}-$clientSuffix';
  }

  static Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    var suffix = p.getString('clientSuffix');
    if (suffix == null) {
      suffix = List.generate(6, (_) => Random.secure().nextInt(16).toRadixString(16)).join();
      await p.setString('clientSuffix', suffix);
    }
    return AppSettings(
      serverUrl: p.getString('serverUrl') ?? 'http://localhost:8080',
      userName: p.getString('userName') ?? 'Me',
      journaled: p.getBool('journaled') ?? true,
      lastDoc: p.getString('lastDoc') ?? '',
      clientSuffix: suffix,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('serverUrl', serverUrl);
    await p.setString('userName', userName);
    await p.setBool('journaled', journaled);
    await p.setString('lastDoc', lastDoc);
  }
}
