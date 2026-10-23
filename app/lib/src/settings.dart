import 'package:shared_preferences/shared_preferences.dart';

/// What the user chose on the start screen; remembered between runs. (Names come from the signed-in account.) (The collaboration client id is not a
/// setting: the server issues it and the journal remembers it, protocol 1.1.)
class AppSettings {
  AppSettings({required this.serverUrl, required this.journaled, required this.lastDoc});

  String serverUrl;

  /// Write-ahead journal on (default) or volatile mode.
  bool journaled;
  String lastDoc;

  static Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    return AppSettings(
      serverUrl: p.getString('serverUrl') ?? 'http://localhost:8080',
      journaled: p.getBool('journaled') ?? true,
      lastDoc: p.getString('lastDoc') ?? '',
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('serverUrl', serverUrl);
    await p.setBool('journaled', journaled);
    await p.setString('lastDoc', lastDoc);
  }
}
