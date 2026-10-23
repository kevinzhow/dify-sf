// Real Linux UI -> HTTP upload/profile/app -> Postgres and filesystem.
// Only the operating-system chooser is substituted; crop, upload, save and image fetch are real.
// Set DIFYSF_FILES_SERVER/EMAIL/PASSWORD and DIFYSF_FILES_EVIDENCE from the isolated runner.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/design/widgets/app_icon_picker.dart';
import 'package:dify_sf_app/src/design/widgets/button.dart';
import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/settings.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Chooser extends FileSelectorPlatform {
  int calls = 0;
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    calls++;
    final image = img.Image(width: 24, height: 12)..clear(img.ColorRgb8(50, 130, 200));
    final path = '${Platform.environment['DIFYSF_FILES_EVIDENCE']!}/native-source.png';
    await File(path).writeAsBytes(img.encodePng(image));
    return XFile(path, mimeType: 'image/png');
  }
}

Future<void> _settle(WidgetTester t, [int ms = 1500]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _until(WidgetTester t, bool Function() ready) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pump(const Duration(milliseconds: 50));
  }
  if (!ready()) {
    debugPrint('visible UI: ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data ?? '').join(' | ')}');
    final buttons = find.byType(DifyButton).evaluate().map((e) => e.widget as DifyButton);
    debugPrint('loading buttons: ${buttons.where((w) => w.loading).length}');
  }
  expect(ready(), isTrue);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final url = env['DIFYSF_FILES_SERVER'] ?? '';
  testWidgets('native avatar crop and image app persist through actual server APIs', (t) async {
    SharedPreferences.setMockInitialValues({});
    await DifyI18n.load('en-US');
    final semantics = t.ensureSemantics();
    try {
      final oldChooser = FileSelectorPlatform.instance, chooser = _Chooser();
      FileSelectorPlatform.instance = chooser;
      addTearDown(() => FileSelectorPlatform.instance = oldChooser);
      final auth = AuthController.on(server: url, api: HttpAuthApi(Uri.parse(url)), store: MemoryTokenStore());
      await auth.start();
      await auth.signIn(email: env['DIFYSF_FILES_EMAIL']!, password: env['DIFYSF_FILES_PASSWORD']!);
      addTearDown(auth.dispose);
      expect(auth.systemFeatures.fileUpload, isTrue);
      final boundary = GlobalKey();
      await t.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: buildApp(
            AppSettings(serverUrl: url, journaled: false, lastDoc: ''),
            auth: auth,
            studioPollInterval: null,
          ),
        ),
      );
      await _settle(t);
      await t.tap(find.bySemanticsLabel('File Test Owner Account'));
      await _settle(t, 300);
      await t.tap(find.text('Account').last);
      await _settle(t);
      await t.tap(find.byKey(const ValueKey('account-edit-avatar')));
      await _settle(t, 300);
      await t.tap(find.byKey(const ValueKey('app-icon-pick-image')));
      await _settle(t, 300);
      await t.tap(find.text('OK'));
      await _until(t, () => find.byType(DifyAppIconPicker).evaluate().isEmpty);
      expect(find.byType(DifyAppIconPicker), findsNothing);
      final account = await auth.session.account();
      expect(account.avatarUrl, isNotNull);
      final response = await http.get(Uri.parse(account.avatarUrl!));
      expect(response.statusCode, 200);
      final pixels = img.decodePng(response.bodyBytes)!;
      expect(pixels.width, pixels.height);
      await _settle(t);
      final out = env['DIFYSF_FILES_EVIDENCE'];
      if (out != null) {
        final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$out/native-avatar.png').writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      }
      await _until(t, () => find.byKey(const ValueKey('account-header-home')).hitTestable().evaluate().isNotEmpty);
      await t.tap(find.byKey(const ValueKey('account-header-home')));
      await _settle(t, 500);
      await t.tap(find.text('Create from Blank'));
      await _settle(t, 400);
      await t.enterText(
        find.descendant(of: find.byKey(const ValueKey('create-app-name')), matching: find.byType(EditableText)),
        'Native Image App',
      );
      await t.tap(find.byKey(const ValueKey('create-app-icon')));
      await _settle(t, 300);
      await t.tap(find.text('Image'));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('app-icon-pick-image')));
      await _settle(t, 300);
      await t.tap(find.text('OK'));
      await _until(t, () => find.byType(DifyAppIconPicker).evaluate().isEmpty);
      await t.tap(find.byWidgetPredicate((w) => w is DifyButton && w.semanticLabel == 'Create').hitTestable());
      await _settle(t, 2500);
      final api = HttpAppsApi(Uri.parse(url), auth: auth.session);
      addTearDown(api.close);
      final apps = await api.list(const AppListQuery(name: 'Native Image App'));
      expect(apps.data, hasLength(1));
      final app = apps.data.single;
      expect(app.iconType, 'image');
      expect((await http.get(Uri.parse(app.iconUrl!))).statusCode, 200);
      expect(chooser.calls, 2);
      await t.pumpWidget(const SizedBox());
    } finally {
      semantics.dispose();
    }
  }, skip: url.isEmpty);
}
