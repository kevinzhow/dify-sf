// dify-spec: web/app/components/workflow/operator/__tests__/more-actions.spec.tsx
import 'dart:convert';

import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/operator/actions.dart';
import 'package:dify_sf_app/src/workflow_editor/operator/image_export.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../dify_spec/workflow/hooks/editor_harness.dart';
import '../support/app_fonts.dart';

CanvasImageExport fixture() => encodeCanvasImage(
  img.encodePng(img.Image(width: 8, height: 6)),
  const Size(8, 6),
  'Example',
  ExportImageFormat.png,
  wholeWorkflow: true,
);

void main() {
  setUp(() async {
    await useAppFonts();
    await DifyI18n.load('en-US');
  });
  group('MoreActions', () {
    testWidgets('shows a preview when exporting the whole workflow', (t) async {
      await t.pumpWidget(const MaterialApp(home: Material(child: Text('editor'))));
      final context = t.element(find.text('editor'));
      var saved = false;
      final done = performCanvasImageExport(
        appName: 'Example',
        readOnly: false,
        wholeWorkflow: true,
        capture: () async => fixture(),
        save: (_) async {
          saved = true;
        },
        preview: (image) => showCanvasImagePreview(context, image),
        onError: (e) => fail('$e'),
      );
      await t.pumpAndSettle();
      expect(saved, isTrue);
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('Example-whole-workflow.png'), findsOneWidget);
      await t.tap(find.byIcon(Icons.close));
      await t.pumpAndSettle();
      await done;
      expect(find.byType(Image), findsNothing);
    });
    test('returns early when there is no app or knowledge name', () async {
      var calls = 0;
      await performCanvasImageExport(
        appName: '',
        readOnly: false,
        wholeWorkflow: true,
        capture: () async {
          calls++;
          return fixture();
        },
        save: (_) async {
          calls++;
        },
        preview: (_) async {
          calls++;
        },
        onError: (_) {
          calls++;
        },
      );
      expect(calls, 0);
    });
    test('logs export failures and lets the preview close', () async {
      Object? error;
      var previews = 0;
      await performCanvasImageExport(
        appName: 'Example',
        readOnly: false,
        wholeWorkflow: true,
        capture: () async => throw const FormatException('capture failed'),
        save: (_) async {},
        preview: (_) async {
          previews++;
        },
        onError: (e) => error = e,
      );
      expect(error, isA<FormatException>());
      expect(previews, 0);
    });
  });

  test('all advertised formats contain their actual codec, and whole image names include the suffix', () {
    final png = img.encodePng(img.Image(width: 8, height: 6));
    for (final format in ExportImageFormat.values) {
      final result = encodeCanvasImage(png, const Size(8, 6), 'Example', format, wholeWorkflow: true);
      expect(result.name, 'Example-whole-workflow.${format.name}');
      if (format == ExportImageFormat.jpeg) {
        final jpeg = img.decodeJpg(result.bytes)!;
        expect((jpeg.width, jpeg.height), (8, 6));
      } else if (format == ExportImageFormat.svg) {
        final text = utf8.decode(result.bytes);
        expect(text, contains('<svg'));
        expect(text, contains('data:image/png;base64,${base64Encode(png)}'));
      } else {
        expect(img.decodePng(result.bytes)!.width, 8);
      }
    }
  });

  testWidgets('whole image captures offscreen nodes at full quality without moving the editor viewport', (t) async {
    final h = await EditorHarness.start(t, [node('near', x: 50, y: 100), node('far', x: 1500, y: 100)]);
    final before = h.canvas.view.center, zoom = h.canvas.view.scale;
    final context = t.element(find.byKey(const ValueKey('node-near')));
    final result = await t.runAsync(
      () => captureCanvasImage(context, h.doc, h.canvas, 'Example', ExportImageFormat.png, wholeWorkflow: true),
    );
    expect(result, isNotNull);
    final decoded = img.decodePng(result!.bytes)!;
    final bounds = h.canvas.graph!.bounds;
    expect(decoded.width, ((bounds.width + 100) * 2).ceil());
    expect(decoded.height, ((bounds.height + 100) * 2).ceil());
    final far = h.canvas.graph!['far']!;
    final pixel = decoded.getPixel(
      ((far.rect.left - bounds.left + 50 + 17) * 2).round(),
      ((far.rect.top - bounds.top + 50 + 17) * 2).round(),
    );
    expect(pixel.b, greaterThan(pixel.r), reason: 'the offscreen Code icon is drawn, rather than only the background');
    expect(h.canvas.view.center, before);
    expect(h.canvas.view.scale, zoom);
    expect(h.controller.undo.past, isEmpty);
    final focusNodes = FocusManager.instance.rootScope.descendants.length;
    final current = await t.runAsync(
      () => captureCanvasImage(context, h.doc, h.canvas, 'Example', ExportImageFormat.png, wholeWorkflow: false),
    );
    expect(img.decodePng(current!.bytes)!.width, h.canvas.view.viewport.width.toInt());
    expect(
      FocusManager.instance.rootScope.descendants.length,
      focusNodes,
      reason: 'the detached export tree is unmounted',
    );
    await h.dispose(t);
  });
}
