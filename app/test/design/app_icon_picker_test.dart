import 'dart:async';

import 'package:dify_sf_app/src/design/widgets/app_icon_picker.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/design/widgets/toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../support/app_fonts.dart';

void main() {
  setUp(() => defaultToastManager.close());
  tearDown(() => defaultToastManager.close());
  setUp(() async {
    await useAppFonts();
    await DifyI18n.load('en-US');
    await EmojiCatalog.load();
  });
  String tr(String key) => DifyI18n.tr('app', 'iconPicker.$key');
  Future<void> open(
    WidgetTester t, {
    UploadAppIcon? upload,
    Future<IconFile?> Function()? pickFile,
    required ValueChanged<Map<String, Object?>?> result,
  }) async {
    await t.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result(
                    await showAppIconPicker(
                      context,
                      initialEmoji: (icon: '🤖', background: '#F5F3FF'),
                      upload: upload,
                      pickFile: pickFile,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
            const DifyToastHost(),
          ],
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
  }

  testWidgets('searches the original emoji catalog and confirms the chosen icon and color', (t) async {
    Map<String, Object?>? selected;
    await open(t, result: (value) => selected = value);
    await t.enterText(
      find.descendant(of: find.byKey(const ValueKey('icon-emoji-search')), matching: find.byType(EditableText)),
      'brain',
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('icon-emoji-brain')));
    await t.tap(find.byKey(const ValueKey('icon-color-#E0F2FE')));
    await t.tap(find.text(tr('ok')));
    await t.pumpAndSettle();
    expect(selected, {'type': 'emoji', 'icon': '🧠', 'background': '#E0F2FE'});
    expect(find.byType(AppIconPicker), findsNothing);
  });

  testWidgets('cancel preserves the source icon without emitting an edit', (t) async {
    var calls = 0;
    Map<String, Object?>? selected;
    await open(
      t,
      result: (value) {
        calls++;
        selected = value;
      },
    );
    expect(t.widget<AppIconPicker>(find.byType(AppIconPicker)).initialEmoji, (icon: '🤖', background: '#F5F3FF'));
    await t.tap(find.text(tr('cancel')));
    await t.pumpAndSettle();
    expect(calls, 1);
    expect(selected, isNull);
  });

  testWidgets('missing upload service reports the Dify failure and keeps the selected file', (t) async {
    final png = img.encodePng(img.Image(width: 10, height: 10));
    var selected = false;
    await open(t, pickFile: () async => (name: 'icon.png', bytes: png), result: (_) => selected = true);
    await t.tap(find.text(tr('image')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('app-icon-pick-image')));
    await t.pumpAndSettle();
    await t.tap(find.text(tr('ok')));
    await t.pumpAndSettle();
    expect(selected, isFalse);
    expect(find.byType(AppIconPicker), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text(DifyI18n.tr('common', 'imageUploader.uploadFromComputerUploadError')), findsOneWidget);
  });

  testWidgets('crops a file to a square and sends its uploaded id, guarding repeat submission', (t) async {
    final png = img.encodePng(img.Image(width: 20, height: 10)..clear(img.ColorRgb8(70, 80, 90)));
    final response = Completer<UploadedAppIcon>();
    final uploads = <IconFile>[];
    Map<String, Object?>? selected;
    await open(
      t,
      pickFile: () async => (name: 'icon.png', bytes: png),
      upload: (file) {
        uploads.add(file);
        return response.future;
      },
      result: (value) => selected = value,
    );
    await t.tap(find.text(tr('image')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('app-icon-pick-image')));
    await t.pumpAndSettle();
    await t.tap(find.text(tr('ok')));
    await t.pump();
    await t.tap(find.text(tr('ok')));
    await t.pump();
    expect(uploads, hasLength(1));
    final cropped = img.decodePng(uploads.single.bytes)!;
    expect((cropped.width, cropped.height), (10, 10));
    response.complete((fileId: 'uploaded-1', url: 'https://example.test/icon.png'));
    await t.pumpAndSettle();
    expect(selected, {'type': 'image', 'fileId': 'uploaded-1', 'url': 'https://example.test/icon.png'});
  });
}
