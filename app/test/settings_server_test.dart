import 'package:dify_sf_app/src/launch_options.dart';
import 'package:dify_sf_app/src/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a fresh browser connects to the HTTPS application origin', () async {
    final settings = await AppSettings.load(defaultServerUrl: 'https://trial.example.ts.net');
    expect(settings.serverUrl, 'https://trial.example.ts.net');
    await settings.save();
    expect((await AppSettings.load()).serverUrl, 'https://trial.example.ts.net');
  });

  test('an existing connection is preserved and explicit launch options win', () async {
    SharedPreferences.setMockInitialValues({'serverUrl': 'https://saved.example'});
    final settings = await AppSettings.load(defaultServerUrl: 'https://trial.example.ts.net');
    expect(settings.serverUrl, 'https://saved.example');
    LaunchOptions.fromQuery({'server': 'https://chosen.example'}).applyTo(settings);
    expect(settings.serverUrl, 'https://chosen.example');
  });

  test('native clients retain the local development default', () async {
    expect((await AppSettings.load()).serverUrl, 'http://localhost:8080');
  });
}
