import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/design/widgets/toast.dart';
import 'package:dify_sf_app/src/i18n/app_locale.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_test_i18n.dart';

/// Renders [child] in an app with Dify's test translations (`<ns>.<key>`) and the toast host.
Future<void> renderDetail(WidgetTester t, Widget child, {Size size = const Size(1440, 900)}) async {
  useDifyTestTranslator();
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(child: child),
      builder: (context, c) => AppLocaleScope(
        locale: AppLocale('en-US'),
        child: Stack(
          fit: StackFit.expand,
          children: [
            c!,
            const DifyToastHost(timeout: Duration.zero),
          ],
        ),
      ),
    ),
  );
  await settle(t);
}

Future<void> settle(WidgetTester t, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// The app of Dify's sidebar specs.
AppInfo testApp({String mode = 'chat', List<String> keys = const [], String name = 'Test App'}) => AppInfo(
  id: 'app-1',
  name: name,
  mode: mode,
  iconType: 'emoji',
  icon: '🤖',
  iconBackground: '#FFFFFF',
  permissionKeys: keys,
);
